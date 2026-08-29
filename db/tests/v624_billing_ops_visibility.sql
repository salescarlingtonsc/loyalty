-- Rollback-only acceptance for NESTLY v624 — billing operations become visible.
--
-- Proves, at the server boundary only:
--   · the manual-payment queue finally has a reader, and it names the firm;
--   · app.detect_billing_alerts_v624 raises CORRELATED alerts (a completed checkout with no
--     paid truth after 24h; a tenant's manual-payment request open for a day) and dedupes —
--     a second detection run inserts nothing;
--   · the alert table is server-only (RLS on, no grants) and the console reads it through
--     RPCs whose gate is a platform role;
--   · v625 bites the platform readers: the same super admin on a PASSWORD session is refused;
--   · resolving an alert is an audited platform action.
--
-- Self-contained fixtures (gen_random_uuid), alert evidence measured as a DELTA, and one
-- transaction that ends in rollback — safe to run against production.
begin;

create or replace function pg_temp.as_v624_session(
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
grant execute on function pg_temp.as_v624_session(uuid,text,text) to public;

do $v624_main$
declare
  v_super uuid:=gen_random_uuid();
  v_owner uuid:=gen_random_uuid();
  v_business uuid:=gen_random_uuid();
  v_checkout_object text:='cs_test_v624_'||substr(gen_random_uuid()::text,1,8);
  v_request uuid:=gen_random_uuid();
  v_alert uuid;
  v_alerts_before bigint;
  v_alerts_after bigint;
  v_inserted integer;
  v_result jsonb;
  v_resolved timestamptz;
begin
  reset role;

  -- E1 · the alert store is server-only: RLS on, and no browser grant of any kind.
  if not coalesce((
    select c.relrowsecurity from pg_class c join pg_namespace n on n.oid=c.relnamespace
    where n.nspname='public' and c.relname='platform_billing_alerts_v624'
  ),false) then
    raise exception 'v624 E1: platform_billing_alerts_v624 is missing or has RLS disabled';
  end if;
  if has_table_privilege('authenticated','public.platform_billing_alerts_v624','SELECT')
     or has_table_privilege('anon','public.platform_billing_alerts_v624','SELECT') then
    raise exception 'v624 E2: the alert store is directly browser-readable';
  end if;

  -- E3 · the RPC ACLs are fail-closed and detection is not callable from a session.
  if has_function_privilege(
       'anon','public.platform_list_manual_payment_requests_v624(text)','EXECUTE')
     or has_function_privilege(
       'anon','public.platform_list_billing_alerts_v624(boolean)','EXECUTE')
     or has_function_privilege(
       'anon','public.platform_resolve_billing_alert_v624(uuid,text)','EXECUTE')
     or has_function_privilege('authenticated','app.detect_billing_alerts_v624()','EXECUTE')
     or not has_function_privilege(
       'authenticated','public.platform_list_billing_alerts_v624(boolean)','EXECUTE') then
    raise exception 'v624 E3: billing-ops ACLs are not fail-closed';
  end if;

  insert into auth.users(
    instance_id,id,aud,role,email,encrypted_password,
    email_confirmed_at,created_at,updated_at
  ) select
    '00000000-0000-0000-0000-000000000000',user_id,
    'authenticated','authenticated',email,'',now(),now(),now()
  from (values
    (v_super,'v624-super-'||substr(v_super::text,1,8)||'@example.test'),
    (v_owner,'v624-owner-'||substr(v_owner::text,1,8)||'@example.test')
  ) fixture(user_id,email);
  insert into public.super_admins(user_id,email,note)
  values(
    v_super,'v624-super-'||substr(v_super::text,1,8)||'@example.test',
    'rollback-only v624 fixture'
  );

  insert into public.businesses(id,name,slug,industry,enabled_modules)
  values(
    v_business,'V624 billing ops fixture',
    'v624-'||substr(v_business::text,1,8),'test',
    array['dashboard','clients','sales','loyalty','retention','reports']
  );
  insert into public.staff(business_id,user_id,role,full_name,active)
  values(v_business,v_owner,'owner','V624 Owner',true);
  insert into public.branches(business_id,name,is_default,active)
  values(v_business,'Primary',true,true);
  update public.business_workspace_controls_v94
     set approval_status='approved',version=version+1,
         decided_at=clock_timestamp(),
         decision_reason='rollback-only v624 acceptance fixture',
         updated_at=clock_timestamp()
   where business_id=v_business;
  insert into public.subscriptions(
    business_id,status,payment_status,trial_ends_at,
    current_period_start,current_period_end
  ) values(
    v_business,'trialing','not_collected',now()+interval '10 days',
    now(),now()+interval '30 days'
  );

  -- A Checkout URL was minted two days ago and nothing paid truth ever followed it.
  insert into public.billing_commands(
    business_id,command_type,status,provider_object_id,idempotency_key,
    request_fingerprint,requested_by,requested_at
  ) values(
    v_business,'create_checkout','completed',v_checkout_object,gen_random_uuid(),
    repeat('a',64),v_owner,now()-interval '2 days'
  );
  -- And the tenant asked to pay by hand two days ago.
  insert into public.business_manual_payment_requests_v542(
    id,business_id,requested_by,idempotency_key,contact_phone,note,status,created_at
  ) values(
    v_request,v_business,v_owner,gen_random_uuid(),'+6598240001',
    'v624 acceptance manual payment request','open',now()-interval '2 days'
  );

  select count(*) into v_alerts_before from public.platform_billing_alerts_v624;

  -- E4 · detection raises both correlated alerts.
  v_inserted:=app.detect_billing_alerts_v624();
  select count(*) into v_alerts_after from public.platform_billing_alerts_v624;
  if v_alerts_after-v_alerts_before<2 then
    raise exception 'v624 E4: detection raised % new alerts, expected at least 2',
      v_alerts_after-v_alerts_before;
  end if;
  if not exists(
    select 1 from public.platform_billing_alerts_v624 alert
    where alert.kind='checkout_unresolved' and alert.object_id=v_checkout_object
      and alert.business_id=v_business and alert.resolved_at is null
  ) then
    raise exception 'v624 E5: an abandoned checkout raised no checkout_unresolved alert';
  end if;
  if not exists(
    select 1 from public.platform_billing_alerts_v624 alert
    where alert.kind='manual_request_open' and alert.object_id=v_request::text
      and alert.business_id=v_business and alert.resolved_at is null
  ) then
    raise exception 'v624 E6: a day-old manual payment request raised no alert';
  end if;

  -- E7 · detection is deduped while the alert is unresolved.
  v_inserted:=app.detect_billing_alerts_v624();
  if v_inserted<>0 then
    raise exception 'v624 E7: a repeated detection run inserted % duplicate alerts',v_inserted;
  end if;

  -- E8 · the manual-payment queue finally has a reader, and it names the firm.
  perform pg_temp.as_v624_session(v_super,'oauth');
  v_result:=public.platform_list_manual_payment_requests_v624('open');
  if not exists(
    select 1 from jsonb_array_elements(v_result) item
    where (item->>'id')::uuid=v_request
      and item->>'business_name'='V624 billing ops fixture'
      and item->>'status'='open'
  ) then
    raise exception 'v624 E8: the open manual payment request was not readable: %',v_result;
  end if;

  -- E9 · an unknown status filter is refused rather than silently ignored.
  begin
    perform public.platform_list_manual_payment_requests_v624('nonsense');
    raise exception 'v624 E9: an unknown manual-request status filter was accepted';
  exception when sqlstate '22023' then null;
  end;

  -- E10 · the console reads alerts on a Google session.
  v_result:=public.platform_list_billing_alerts_v624(false);
  if not exists(
    select 1 from jsonb_array_elements(v_result) item
    where item->>'kind'='checkout_unresolved'
      and item->>'object_id'=v_checkout_object
      and item->>'business_name'='V624 billing ops fixture'
  ) then
    raise exception 'v624 E10: the billing alert list did not surface the fixture alert';
  end if;

  -- E11 · v625 bites the platform readers: the SAME super admin on a password session is
  -- refused, because a password session carries no platform authority at all.
  perform pg_temp.as_v624_session(v_super,'password');
  begin
    perform public.platform_list_billing_alerts_v624(false);
    raise exception 'v624 E11: a password-session super admin read the billing alerts';
  exception when sqlstate '42501' then null;
  end;

  reset role;
  select id into v_alert from public.platform_billing_alerts_v624
   where kind='checkout_unresolved' and object_id=v_checkout_object;

  -- E12 · resolving needs a note.
  perform pg_temp.as_v624_session(v_super,'oauth');
  begin
    perform public.platform_resolve_billing_alert_v624(v_alert,'x');
    raise exception 'v624 E12: an alert was resolved without a note';
  exception when sqlstate '22023' then null;
  end;

  -- E13 · an unknown alert is a clean not-found, not a silent success.
  begin
    perform public.platform_resolve_billing_alert_v624(
      gen_random_uuid(),'v624 unknown alert probe'
    );
    raise exception 'v624 E13: resolving an unknown alert succeeded';
  exception when sqlstate '42704' then null;
  end;

  -- E14 · resolution closes the alert and is audited.
  begin
    perform public.platform_resolve_billing_alert_v624(
      v_alert,'v624 acceptance resolution'
    );
  exception when others then
    raise exception 'v624 E14: resolving a billing alert failed [%]: %',sqlstate,sqlerrm;
  end;
  reset role;
  select resolved_at into v_resolved
    from public.platform_billing_alerts_v624 where id=v_alert;
  if v_resolved is null then
    raise exception 'v624 E15: the resolved alert kept an open resolved_at';
  end if;
  if not exists(
    select 1 from public.audit_log log_row
    where log_row.business_id=v_business
      and log_row.action='BILLING_ALERT_RESOLVED_V624'
      and log_row.detail->>'kind'='checkout_unresolved'
  ) then
    raise exception 'v624 E16: alert resolution left no audit evidence';
  end if;

  -- E17 · detection and reconciliation are scheduled, not aspirational.
  if to_regnamespace('cron') is not null then
    if not exists(
      select 1 from cron.job where jobname='nestly-v624-billing-alert-detect'
    ) or not exists(
      select 1 from cron.job where jobname='nestly-v624-billing-reconcile'
    ) then
      raise exception 'v624 E17: the v624 billing schedules are missing';
    end if;
  end if;

  perform pg_temp.as_v624_session(null);
  raise notice 'v624 billing ops visibility suite: ALL PASS';
end
$v624_main$;

reset role;
rollback;
