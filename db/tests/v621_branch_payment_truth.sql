-- Rollback-only acceptance for NESTLY v621 — a branch is paid for by an invoice.
--
-- Proves, at the server boundary only:
--   · the checkout-URL activator (v202 trigger + function) is retired;
--   · app.activate_pending_branches_on_paid_v621 activates the OLDEST pending branches only
--     up to the billable units the provider subscription actually carries, and converges
--     (a second call activates nothing);
--   · the structural guard refuses a browser flipping billing_state, and refuses switching
--     an unpaid branch on, while deactivating and re-enabling a PAID/included branch stay free;
--   · the reaper suspends inactive pending_payment shells older than 7 days and never touches
--     a branch that is riding the trial with active=true.
--
-- Self-contained fixtures (gen_random_uuid), count deltas rather than absolute counts, and
-- one transaction that ends in rollback — safe to run against production.
begin;

create or replace function pg_temp.as_v621_session(
  p_uid uuid,
  p_method text default 'password',
  p_role text default 'authenticated'
) returns void language plpgsql as $fn$
begin
  execute 'reset role';
  perform set_config('request.jwt.claim.sub','',true);
  perform set_config('request.jwt.claims','{}',true);
  if p_uid is null then
    return;
  end if;
  if p_role is not null then
    execute format('set local role %I',p_role);
  end if;
  perform set_config('request.jwt.claim.sub',p_uid::text,true);
  perform set_config(
    'request.jwt.claims',
    jsonb_build_object(
      'sub',p_uid,
      'role',coalesce(p_role,'authenticated'),
      'amr',jsonb_build_array(
        jsonb_build_object('method',p_method,'timestamp',1756500000)
      ),
      'app_metadata',case when p_method='oauth'
        then jsonb_build_object(
          'provider','google','providers',jsonb_build_array('email','google'))
        else jsonb_build_object(
          'provider','email','providers',jsonb_build_array('email')) end
    )::text,
    true
  );
end
$fn$;
grant execute on function pg_temp.as_v621_session(uuid,text,text) to public;

do $v621_main$
declare
  v_owner_a uuid:=gen_random_uuid();
  v_owner_b uuid:=gen_random_uuid();
  v_biz_a uuid:=gen_random_uuid();
  v_biz_b uuid:=gen_random_uuid();
  v_sub_a text:='sub_test_v621_a_'||substr(gen_random_uuid()::text,1,8);
  v_sub_b text:='sub_test_v621_b_'||substr(gen_random_uuid()::text,1,8);
  v_p1 uuid:=gen_random_uuid();
  v_p2 uuid:=gen_random_uuid();
  v_q1 uuid:=gen_random_uuid();
  v_q2 uuid:=gen_random_uuid();
  v_stale_inactive uuid:=gen_random_uuid();
  v_stale_active uuid:=gen_random_uuid();
  v_default_b uuid:=gen_random_uuid();
  v_result jsonb;
  v_rows integer;
  v_state text;
  v_active boolean;
begin
  reset role;

  -- B1 · the checkout-URL activator is gone in both halves.
  if exists(
    select 1 from pg_trigger
    where tgrelid='public.billing_commands'::regclass
      and tgname='activate_branch_on_paid_command_v202'
  ) or exists(
    select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='app' and p.proname='activate_branch_on_paid_command_v202'
  ) then
    raise exception 'v621 B1: checkout-URL branch activation was not retired';
  end if;

  -- B2 · the structural guard is attached and server-only.
  if not exists(
    select 1 from pg_trigger
    where tgrelid='public.branches'::regclass
      and tgname='zz_guard_branch_billing_v621'
      and tgenabled<>'D'
  ) or has_function_privilege(
       'authenticated','app.activate_pending_branches_on_paid_v621(uuid,text)','EXECUTE')
    or has_function_privilege(
       'authenticated','app.reap_stale_pending_branches_v621()','EXECUTE') then
    raise exception 'v621 B2: branch billing guard or activation ACLs are not fail-closed';
  end if;

  insert into auth.users(
    instance_id,id,aud,role,email,encrypted_password,
    email_confirmed_at,created_at,updated_at
  ) select
    '00000000-0000-0000-0000-000000000000',user_id,
    'authenticated','authenticated',email,'',now(),now(),now()
  from (values
    (v_owner_a,'v621-owner-a-'||substr(v_owner_a::text,1,8)||'@example.test'),
    (v_owner_b,'v621-owner-b-'||substr(v_owner_b::text,1,8)||'@example.test')
  ) fixture(user_id,email);

  insert into public.businesses(id,name,slug,industry,enabled_modules)
  values
    (v_biz_a,'V621 branch truth A','v621-a-'||substr(v_biz_a::text,1,8),'test',
      array['dashboard','clients','sales','loyalty','retention','reports']),
    (v_biz_b,'V621 branch truth B','v621-b-'||substr(v_biz_b::text,1,8),'test',
      array['dashboard','clients','sales','loyalty','retention','reports']);
  insert into public.staff(business_id,user_id,role,full_name,active)
  values
    (v_biz_a,v_owner_a,'owner','V621 Owner A',true),
    (v_biz_b,v_owner_b,'owner','V621 Owner B',true);
  update public.business_workspace_controls_v94
     set approval_status='approved',version=version+1,
         decided_at=clock_timestamp(),
         decision_reason='rollback-only v621 acceptance fixture',
         updated_at=clock_timestamp()
   where business_id in(v_biz_a,v_biz_b);
  insert into public.subscriptions(
    business_id,status,payment_status,trial_ends_at,
    current_period_start,current_period_end,
    provider_subscription_id,provider_covers_base_unit
  ) values
    (v_biz_a,'trialing','not_collected',now()+interval '10 days',
      now(),now()+interval '30 days',v_sub_a,true),
    (v_biz_b,'trialing','not_collected',now()+interval '10 days',
      now(),now()+interval '30 days',v_sub_b,true);

  -- Firm A carries three billable base units (one of which the provider counts as the base
  -- unit itself), so two paid branch slots exist. Firm B carries two, so exactly one does.
  insert into public.billing_provider_subscriptions(
    business_id,provider_customer_id,provider_subscription_id,status,livemode,
    provider_event_created_at,provider_event_rank,last_event_id
  ) values
    (v_biz_a,'cus_'||v_sub_a,v_sub_a,'active',true,now(),1,'evt_p_'||v_sub_a),
    (v_biz_b,'cus_'||v_sub_b,v_sub_b,'active',true,now(),1,'evt_p_'||v_sub_b);

  insert into public.billing_provider_subscription_items(
    provider_subscription_id,provider_item_id,item_role,provider_price_id,quantity,
    provider_event_created_at,provider_event_rank,last_event_id
  ) values
    (v_sub_a,'si_'||v_sub_a,'base','price_v621_test',3,now(),1,'evt_'||v_sub_a),
    (v_sub_b,'si_'||v_sub_b,'base','price_v621_test',2,now(),1,'evt_'||v_sub_b);

  insert into public.branches(id,business_id,name,is_default,active,billing_state,created_at)
  values
    (gen_random_uuid(),v_biz_a,'A Primary',true,true,'included',now()-interval '10 minutes'),
    (v_p1,v_biz_a,'A Pending One',false,false,'pending_payment',now()-interval '2 minutes'),
    (v_p2,v_biz_a,'A Pending Two',false,false,'pending_payment',now()-interval '1 minute'),
    (v_default_b,v_biz_b,'B Primary',true,true,'included',now()-interval '10 minutes'),
    (v_q1,v_biz_b,'B Pending One',false,false,'pending_payment',now()-interval '2 minutes'),
    (v_q2,v_biz_b,'B Pending Two',false,false,'pending_payment',now()-interval '1 minute');

  -- B3 · firm A: two covered slots, nothing active yet, so BOTH pending branches activate.
  v_result:=app.activate_pending_branches_on_paid_v621(v_biz_a,'v621-test-invoice-a');
  if coalesce((v_result->>'activated')::integer,-1)<>2 then
    raise exception 'v621 B3: covered-unit activation count is wrong: %',v_result;
  end if;
  if (select count(*) from public.branches
      where id in(v_p1,v_p2) and billing_state='active' and active)<>2 then
    raise exception 'v621 B4: paid activation did not switch both covered branches on';
  end if;

  -- B5 · replay converges: a second invoice.paid activates nothing new.
  v_result:=app.activate_pending_branches_on_paid_v621(v_biz_a,'v621-test-invoice-a-replay');
  if coalesce((v_result->>'activated')::integer,-1)<>0 then
    raise exception 'v621 B5: activation was not idempotent on replay: %',v_result;
  end if;

  -- B6 · firm B: exactly one covered slot, so only the OLDEST pending branch activates.
  v_result:=app.activate_pending_branches_on_paid_v621(v_biz_b,'v621-test-invoice-b');
  if coalesce((v_result->>'activated')::integer,-1)<>1 then
    raise exception 'v621 B6: single-slot activation count is wrong: %',v_result;
  end if;
  select billing_state,active into v_state,v_active from public.branches where id=v_q1;
  if v_state<>'active' or not v_active then
    raise exception 'v621 B7: the oldest pending branch was not the one activated';
  end if;
  select billing_state,active into v_state,v_active from public.branches where id=v_q2;
  if v_state<>'pending_payment' or v_active then
    raise exception 'v621 B8: an uncovered branch was activated without payment';
  end if;

  -- B9 · the browser cannot move billing_state at all.
  perform pg_temp.as_v621_session(v_owner_b,'password');
  begin
    update public.branches set billing_state='active' where id=v_q2;
    raise exception 'v621 B9: an owner rewrote branch billing_state directly';
  exception when sqlstate '42501' then null;
  end;

  -- B10 · nor switch an unpaid branch on through the Edit form's Active checkbox.
  begin
    update public.branches set active=true where id=v_q2;
    raise exception 'v621 B10: an owner switched an unpaid branch on';
  exception when sqlstate '42501' then null;
  end;

  -- B11 · deactivating an included/paid branch stays free (the v510 refund path needs it).
  update public.branches set active=false where id=v_default_b;
  get diagnostics v_rows=row_count;
  if v_rows<>1 then
    raise exception 'v621 B11: deactivating an included branch was blocked';
  end if;
  select active into v_active from public.branches where id=v_default_b;
  if v_active then
    raise exception 'v621 B12: the included branch was not actually deactivated';
  end if;

  -- B13 · and re-enabling that same paid-for branch stays free.
  update public.branches set active=true where id=v_default_b;
  get diagnostics v_rows=row_count;
  select active into v_active from public.branches where id=v_default_b;
  if v_rows<>1 or not v_active then
    raise exception 'v621 B13: re-enabling an included branch was blocked';
  end if;

  perform pg_temp.as_v621_session(null);

  -- B14 · the reaper: inactive pending shells older than 7 days are suspended, while a
  -- pending branch that is riding the trial with active=true is never touched.
  insert into public.branches(
    id,business_id,name,is_default,active,billing_state,created_at,updated_at
  ) values
    (v_stale_inactive,v_biz_a,'A Stale Shell',false,false,'pending_payment',
      now()-interval '30 days',now()-interval '8 days'),
    (v_stale_active,v_biz_a,'A Trial Rider',false,true,'pending_payment',
      now()-interval '30 days',now()-interval '8 days');
  perform app.reap_stale_pending_branches_v621();
  select billing_state into v_state from public.branches where id=v_stale_inactive;
  if v_state<>'suspended' then
    raise exception 'v621 B14: a stale pending shell was not suspended (state %)',v_state;
  end if;
  select billing_state,active into v_state,v_active from public.branches where id=v_stale_active;
  if v_state<>'pending_payment' or not v_active then
    raise exception 'v621 B15: the reaper suspended a branch that was riding the trial';
  end if;
  select billing_state into v_state from public.branches where id=v_q2;
  if v_state<>'pending_payment' then
    raise exception 'v621 B16: the reaper touched a fresh pending branch';
  end if;

  -- B17 · the exit from pending_payment is scheduled, not aspirational.
  if to_regnamespace('cron') is not null then
    if not exists(
      select 1 from cron.job where jobname='nestly-v621-branch-reaper'
    ) then
      raise exception 'v621 B17: the branch reaper has no schedule';
    end if;
  end if;

  raise notice 'v621 branch payment truth suite: ALL PASS';
end
$v621_main$;

reset role;
rollback;
