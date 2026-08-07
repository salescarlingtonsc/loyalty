-- v230 acceptance — the mode reaches the customer portal readers.
-- Rolled back at the end. Checked-in form of the production chain (verified via a real
-- verified customer link). Set v230.business and v230.customer (an auth user with a verified
-- customer_link at that business).

begin;

do $suite$
declare
  v_biz uuid := current_setting('v230.business', true)::uuid;
  v_cust uuid := current_setting('v230.customer', true)::uuid;
  v_tier jsonb; v_before text;
  v_pass int:=0; v_fail int:=0; v_log text:='';
begin
  if v_biz is null or v_cust is null then
    raise exception 'set v230.business and v230.customer before running this suite';
  end if;
  select points_mode into v_before from public.businesses where id=v_biz;

  perform set_config('request.jwt.claims', json_build_object('sub', v_cust::text, 'role','authenticated')::text, true);
  perform set_config('role','authenticated', true);

  v_tier := public.customer_get_effective_tier_v143(v_biz);
  if v_tier->'tier'->>'points_mode' is not distinct from v_before
    then v_pass:=v_pass+1; v_log:=v_log||E'\nPASS 1  the tier payload carries the firm''s current mode';
    else v_fail:=v_fail+1; v_log:=v_log||E'\nFAIL 1  payload='||coalesce(v_tier->'tier'->>'points_mode','null')||' stored='||coalesce(v_before,'null'); end if;

  -- The owner's flip reaches the customer INSTANTLY — no publish step in between. That is the
  -- point: mode is an operational switch, publish governs numbers.
  perform set_config('role','postgres', true);
  update public.businesses set points_mode=case when v_before='tiers' then 'redeem' else 'tiers' end where id=v_biz;
  perform set_config('role','authenticated', true);
  v_tier := public.customer_get_effective_tier_v143(v_biz);
  if v_tier->'tier'->>'points_mode' is distinct from v_before
    then v_pass:=v_pass+1; v_log:=v_log||E'\nPASS 2  a mode flip reaches the portal reader instantly';
    else v_fail:=v_fail+1; v_log:=v_log||E'\nFAIL 2  payload did not move'; end if;

  if position('points_mode' in (select pg_get_functiondef(p.oid) from pg_proc p
      join pg_namespace n on n.oid=p.pronamespace
      where n.nspname='public' and p.proname='customer_get_reward_catalog')) > 0
    then v_pass:=v_pass+1; v_log:=v_log||E'\nPASS 3  the reward catalogue payload includes the mode';
    else v_fail:=v_fail+1; v_log:=v_log||E'\nFAIL 3  catalogue not patched'; end if;

  raise notice 'V230 acceptance: % passed, % failed%', v_pass, v_fail, v_log;
  if v_fail > 0 then
    raise exception 'V230 acceptance failed: % of %%', v_fail, v_pass+v_fail, v_log;
  end if;
end $suite$;

rollback;
