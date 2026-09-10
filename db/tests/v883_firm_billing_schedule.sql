-- nestly_v883 rollback suite — a manual firm's billing schedule from one start day + one cadence.
--
-- Run inside a transaction against production and ROLLED BACK. Impersonates a real super admin
-- (public.super_admins) with the v625 Google-OAuth-shaped claims. Two synthetic tenants:
--   M  billing_provider='manual'  — the shape of every live manual tenant (cadence NULL).
--   P  billing_provider='stripe'  — the provider owns the schedule; the RPC must refuse.

\set ON_ERROR_STOP on

begin;

do $suite$
declare
  sa uuid; owner_uid uuid := gen_random_uuid();
  biz_m uuid := gen_random_uuid(); biz_p uuid := gen_random_uuid(); biz_none uuid := gen_random_uuid();
  got jsonb; before_row public.subscriptions%rowtype; after_row public.subscriptions%rowtype;
  n integer := 0; sqlstate_seen text;
begin
  select user_id into sa from public.super_admins limit 1;
  if sa is null then raise exception 'A0 failed: no super admin to impersonate'; end if;

  insert into public.businesses(id,name,slug,industry,join_enabled,enabled_modules) values
    (biz_m,'V881 manual fixture','v883-m-'||substr(biz_m::text,1,8),'test',true,array['dashboard','clients']),
    (biz_p,'V881 stripe fixture','v883-p-'||substr(biz_p::text,1,8),'test',true,array['dashboard','clients']),
    (biz_none,'V881 no-subscription fixture','v883-n-'||substr(biz_none::text,1,8),'test',true,array['dashboard','clients']);
  delete from public.subscriptions where business_id in (biz_m,biz_p,biz_none);
  insert into public.subscriptions(business_id,billing_provider,status,payment_status,currency)
  values (biz_m,'manual','trialing','not_collected','SGD'),
         (biz_p,'stripe','active','paid','SGD');
  update public.subscriptions set billing_cadence='monthly',cadence_months=1,
         next_payment_at=timestamptz '2026-12-06 07:38:43+00',current_period_end=timestamptz '2026-12-06 07:38:43+00'
   where business_id=biz_p;

  -- A1: an ordinary authenticated user (not a super admin) is refused on both RPCs.
  perform set_config('request.jwt.claims', jsonb_build_object('sub',owner_uid,'role','authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', owner_uid::text, true);
  n := n + 1;
  begin
    perform public.platform_get_billing_schedule_v883(biz_m);
    raise exception 'A% failed: non-super-admin could read the schedule', n;
  exception when insufficient_privilege then null; end;
  n := n + 1;
  begin
    perform public.platform_set_billing_schedule_v883(biz_m, date '2026-10-01', 'monthly', 'suite');
    raise exception 'A% failed: non-super-admin could set the schedule', n;
  exception when insufficient_privilege then null; end;

  -- Super admin from here on (nestly_v625 claims shape).
  perform set_config('request.jwt.claims', jsonb_build_object(
    'sub', sa, 'role', 'authenticated',
    'amr', jsonb_build_array(jsonb_build_object('method', 'oauth')),
    'app_metadata', jsonb_build_object('providers', jsonb_build_array('google')))::text, true);
  perform set_config('request.jwt.claim.sub', sa::text, true);

  -- A3: the manual tenant reads as editable with nothing scheduled.
  n := n + 1;
  got := public.platform_get_billing_schedule_v883(biz_m);
  if not (got->>'editable')::boolean or got->>'provider' <> 'manual' or got->>'cadence' is not null
     or got->>'next_payment_day' is not null then
    raise exception 'A% failed: manual tenant read %', n, got;
  end if;

  -- A4: monthly from 1 Oct 2026 — next payment 1 Nov 2026, Singapore midnight, status untouched.
  select * into before_row from public.subscriptions where business_id=biz_m;
  got := public.platform_set_billing_schedule_v883(biz_m, date '2026-10-01', 'monthly', 'starts on the first, monthly');
  select * into after_row from public.subscriptions where business_id=biz_m;
  n := n + 1;
  if after_row.billing_cadence <> 'monthly' or after_row.cadence_months <> 1
     or after_row.current_period_start <> timestamptz '2026-10-01 00:00:00+08'
     or after_row.next_payment_at <> timestamptz '2026-11-01 00:00:00+08'
     or after_row.current_period_end <> after_row.next_payment_at then
    raise exception 'A% failed: monthly schedule wrote start % next %', n, after_row.current_period_start, after_row.next_payment_at;
  end if;
  n := n + 1;
  if got->>'next_payment_day' <> '2026-11-01' or got->>'period_start_day' <> '2026-10-01' or got->>'cadence' <> 'monthly' then
    raise exception 'A% failed: readback % ', n, got;
  end if;
  n := n + 1;
  if after_row.status is distinct from before_row.status
     or after_row.payment_status is distinct from before_row.payment_status
     or after_row.last_paid_at is distinct from before_row.last_paid_at
     or after_row.obligation_period_start is distinct from before_row.obligation_period_start then
    raise exception 'A% failed: the schedule write touched paid state (v879 rule)', n;
  end if;
  n := n + 1;
  if not exists (select 1 from public.audit_log where business_id=biz_m and action='billing_schedule_set'
                   and detail->>'reason'='starts on the first, monthly' and detail->'after'->>'cadence'='monthly') then
    raise exception 'A% failed: no audit row for the schedule write', n;
  end if;

  -- A8-A10: quarterly, half-yearly and annual each advance exactly one cadence; month-end clamps.
  n := n + 1;
  got := public.platform_set_billing_schedule_v883(biz_m, date '2026-11-30', 'quarterly', 'quarterly from 30 Nov');
  if got->>'next_payment_day' <> '2027-02-28' or (got->>'cadence_months')::int <> 3 then
    raise exception 'A% failed: quarterly readback %', n, got;
  end if;
  n := n + 1;
  got := public.platform_set_billing_schedule_v883(biz_m, date '2026-08-31', 'half_yearly', 'half-yearly from 31 Aug');
  if got->>'next_payment_day' <> '2027-02-28' or (got->>'cadence_months')::int <> 6 then
    raise exception 'A% failed: half-yearly readback %', n, got;
  end if;
  n := n + 1;
  got := public.platform_set_billing_schedule_v883(biz_m, date '2028-02-29', 'annual', 'annual from a leap day');
  if got->>'next_payment_day' <> '2029-02-28' or (got->>'cadence_months')::int <> 12 then
    raise exception 'A% failed: annual readback %', n, got;
  end if;

  -- A11-A13: bad cadence, short reason and out-of-range start are refused with 22023.
  n := n + 1;
  begin
    perform public.platform_set_billing_schedule_v883(biz_m, date '2026-10-01', 'weekly', 'weekly is not a cadence');
    raise exception 'A% failed: weekly cadence accepted', n;
  exception when invalid_parameter_value then null; end;
  n := n + 1;
  begin
    perform public.platform_set_billing_schedule_v883(biz_m, date '2026-10-01', 'monthly', 'ab');
    raise exception 'A% failed: two-character reason accepted', n;
  exception when invalid_parameter_value then null; end;
  n := n + 1;
  begin
    perform public.platform_set_billing_schedule_v883(biz_m, date '2023-12-31', 'monthly', 'too far back');
    raise exception 'A% failed: 2023 start accepted', n;
  exception when invalid_parameter_value then null; end;

  -- A14-A15: a provider-owned schedule is refused and left byte-identical; the read says not editable.
  select * into before_row from public.subscriptions where business_id=biz_p;
  n := n + 1;
  begin
    perform public.platform_set_billing_schedule_v883(biz_p, date '2026-10-01', 'annual', 'trying to override stripe');
    raise exception 'A% failed: stripe schedule was overwritten', n;
  exception when invalid_parameter_value then
    get stacked diagnostics sqlstate_seen = message_text;
    if sqlstate_seen <> 'provider_owns_schedule' then raise exception 'A% failed: wrong refusal %', n, sqlstate_seen; end if;
  end;
  select * into after_row from public.subscriptions where business_id=biz_p;
  if to_jsonb(after_row) <> to_jsonb(before_row) then
    raise exception 'A% failed: stripe row changed after a refusal', n;
  end if;
  n := n + 1;
  got := public.platform_get_billing_schedule_v883(biz_p);
  if (got->>'editable')::boolean or got->>'provider' <> 'stripe' or got->>'next_payment_day' <> '2026-12-06' then
    raise exception 'A% failed: stripe read %', n, got;
  end if;

  -- A16: a business with no subscription row reads exists=false and cannot be scheduled.
  n := n + 1;
  got := public.platform_get_billing_schedule_v883(biz_none);
  if (got->>'exists')::boolean or (got->>'editable')::boolean then
    raise exception 'A% failed: missing subscription read %', n, got;
  end if;
  begin
    perform public.platform_set_billing_schedule_v883(biz_none, date '2026-10-01', 'monthly', 'no subscription here');
    raise exception 'A% failed: scheduled a business with no subscription', n;
  exception when undefined_object then null; end;

  -- A17: anon holds no execute on either function.
  n := n + 1;
  if has_function_privilege('anon','public.platform_get_billing_schedule_v883(uuid)','execute')
     or has_function_privilege('anon','public.platform_set_billing_schedule_v883(uuid,date,text,text)','execute') then
    raise exception 'A% failed: anon can execute a v883 function', n;
  end if;

  raise notice 'nestly_v883 suite: % assertions passed', n;
end
$suite$;

rollback;
