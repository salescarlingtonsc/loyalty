-- v229 acceptance — one use for points: redemption or tier membership.
-- Rolled back at the end. Checked-in form of the chain run against production (7/7).
-- Set v229.business to a tenant with a loyalty programme and v229.owner to its owner auth user.

begin;

do $suite$
declare
  v_biz uuid := current_setting('v229.business', true)::uuid;
  v_owner uuid := current_setting('v229.owner', true)::uuid;
  v_mode text; v_n int;
  v_pass int:=0; v_fail int:=0; v_log text:='';
begin
  if v_biz is null or v_owner is null then
    raise exception 'set v229.business and v229.owner before running this suite';
  end if;

  -- Backfill shape: programme firms start at redeem (their live behaviour), others stay unchosen.
  select count(*) into v_n from public.businesses b
  where b.points_mode is distinct from 'redeem'
    and exists(select 1 from public.loyalty_programs p where p.business_id=b.id);
  if v_n=0 then v_pass:=v_pass+1; v_log:=v_log||E'\nPASS 1  every programme firm backfilled to redeem';
  else v_fail:=v_fail+1; v_log:=v_log||E'\nFAIL 1  '||v_n||' programme firms not redeem'; end if;
  select count(*) into v_n from public.businesses b
  where b.points_mode is not null
    and not exists(select 1 from public.loyalty_programs p where p.business_id=b.id);
  if v_n=0 then v_pass:=v_pass+1; v_log:=v_log||E'\nPASS 2  programme-less firms stay unchosen';
  else v_fail:=v_fail+1; v_log:=v_log||E'\nFAIL 2  '||v_n||' got a mode without a programme'; end if;

  perform set_config('request.jwt.claims', json_build_object('sub', v_owner::text, 'role','authenticated')::text, true);
  perform set_config('role','authenticated', true);

  update public.businesses set points_mode='tiers' where id=v_biz;
  select points_mode into v_mode from public.businesses where id=v_biz;
  if v_mode='tiers' then v_pass:=v_pass+1; v_log:=v_log||E'\nPASS 3  the owner can choose tiers';
  else v_fail:=v_fail+1; v_log:=v_log||E'\nFAIL 3  mode='||coalesce(v_mode,'null'); end if;

  -- In tiers mode the redemption door refuses, with wording a customer can read.
  begin
    perform public.customer_create_redemption_intent_v89(v_biz, null, gen_random_uuid(), 'classic_points');
    v_fail:=v_fail+1; v_log:=v_log||E'\nFAIL 4  redemption intent allowed in tiers mode';
  exception when others then
    if sqlerrm like '%count toward membership tiers and cannot be redeemed%'
      then v_pass:=v_pass+1; v_log:=v_log||E'\nPASS 4  tiers mode refuses redemption';
      else v_fail:=v_fail+1; v_log:=v_log||E'\nFAIL 4  wrong error: '||sqlerrm; end if;
  end;

  -- Back to redeem: the same call passes the gate and fails on the LATER identity check,
  -- proving the gate was what fired above.
  update public.businesses set points_mode='redeem' where id=v_biz;
  begin
    perform public.customer_create_redemption_intent_v89(v_biz, null, gen_random_uuid(), 'classic_points');
    v_fail:=v_fail+1; v_log:=v_log||E'\nFAIL 5  intent creation should still need a customer identity';
  exception when others then
    if sqlerrm not like '%membership tiers%'
      then v_pass:=v_pass+1; v_log:=v_log||E'\nPASS 5  redeem mode passes the gate';
      else v_fail:=v_fail+1; v_log:=v_log||E'\nFAIL 5  gate fired in redeem mode'; end if;
  end;

  -- A stranger's update touches nothing (RLS).
  perform set_config('request.jwt.claims', json_build_object('sub', gen_random_uuid()::text, 'role','authenticated')::text, true);
  update public.businesses set points_mode='tiers' where id=v_biz;
  perform set_config('role','postgres', true);
  select points_mode into v_mode from public.businesses where id=v_biz;
  if v_mode='redeem' then v_pass:=v_pass+1; v_log:=v_log||E'\nPASS 6  a stranger cannot set another firm''s mode';
  else v_fail:=v_fail+1; v_log:=v_log||E'\nFAIL 6  mode became '||coalesce(v_mode,'null'); end if;

  -- The vocabulary is closed.
  begin
    update public.businesses set points_mode='both' where id=v_biz;
    v_fail:=v_fail+1; v_log:=v_log||E'\nFAIL 7  an unknown mode was accepted';
  exception when check_violation then
    v_pass:=v_pass+1; v_log:=v_log||E'\nPASS 7  only redeem, tiers or unchosen are storable';
  end;

  raise notice 'V229 acceptance: % passed, % failed%', v_pass, v_fail, v_log;
  if v_fail > 0 then
    raise exception 'V229 acceptance failed: % of %%', v_fail, v_pass+v_fail, v_log;
  end if;
end $suite$;

rollback;
