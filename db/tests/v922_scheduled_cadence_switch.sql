-- nestly_v922 rollback suite — a manual firm switches billing cycle from a future date.
--
-- Run inside a transaction against production and ROLLED BACK. Impersonates a real super admin
-- (public.super_admins) with the v625 Google-OAuth-shaped claims. Three synthetic tenants:
--   M  billing_provider='manual', monthly, next payment in the future — the switchable shape.
--   U  billing_provider='manual', no cadence at all      — ruling B has nothing to switch after.
--   P  billing_provider='stripe'                         — the provider owns the cycle; refuse.
--
-- The two rulings under test (2026-09-15):
--   A. manual firms only;
--   B. the current period is kept and still due — scheduling a switch must not move
--      current_period_start / current_period_end / next_payment_at by so much as a second.

\set ON_ERROR_STOP on

begin;

do $suite$
declare
  sa uuid; owner_uid uuid := gen_random_uuid();
  biz_m uuid := gen_random_uuid(); biz_u uuid := gen_random_uuid(); biz_p uuid := gen_random_uuid();
  got jsonb; before_row public.subscriptions%rowtype; after_row public.subscriptions%rowtype;
  n integer := 0; period_end timestamptz; switch_day date; applied jsonb; audit_n integer;
begin
  select user_id into sa from public.super_admins limit 1;
  if sa is null then raise exception 'A0 failed: no super admin to impersonate'; end if;

  insert into public.businesses(id,name,slug,industry,join_enabled,enabled_modules) values
    (biz_m,'V922 manual fixture','v922-m-'||substr(biz_m::text,1,8),'test',true,array['dashboard','clients']),
    (biz_u,'V922 unset fixture','v922-u-'||substr(biz_u::text,1,8),'test',true,array['dashboard','clients']),
    (biz_p,'V922 stripe fixture','v922-p-'||substr(biz_p::text,1,8),'test',true,array['dashboard','clients']);
  delete from public.subscriptions where business_id in (biz_m,biz_u,biz_p);

  -- M is mid-period: it started a month ago and the next payment is 40 days out, so "switch after
  -- the current period" has a real boundary to respect.
  period_end := ((app.sg_today() + 40)::timestamp) at time zone 'Asia/Singapore';
  insert into public.subscriptions(business_id,billing_provider,status,payment_status,currency,
      billing_cadence,cadence_months,current_period_start,current_period_end,next_payment_at)
  values (biz_m,'manual','active','paid','SGD','monthly',1,
      ((app.sg_today() - 10)::timestamp) at time zone 'Asia/Singapore', period_end, period_end);
  insert into public.subscriptions(business_id,billing_provider,status,payment_status,currency)
  values (biz_u,'manual','trialing','not_collected','SGD');
  insert into public.subscriptions(business_id,billing_provider,status,payment_status,currency,
      billing_cadence,cadence_months,current_period_end,next_payment_at)
  values (biz_p,'stripe','active','paid','SGD','monthly',1,period_end,period_end);

  switch_day := app.sg_day(period_end);

  -- ------------------------------------------------------------------ authorisation
  perform set_config('request.jwt.claims', jsonb_build_object('sub',owner_uid,'role','authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', owner_uid::text, true);

  n := n + 1;
  begin
    perform public.platform_schedule_cadence_change_v922(biz_m,'annual',switch_day,'suite');
    raise exception 'A% failed: non-super-admin could schedule a cycle switch', n;
  exception when insufficient_privilege then null; end;

  n := n + 1;
  begin
    perform public.platform_cancel_cadence_change_v922(biz_m,'suite');
    raise exception 'A% failed: non-super-admin could cancel a cycle switch', n;
  exception when insufficient_privilege then null; end;

  -- Super admin from here on (nestly_v625 claims shape: app.is_super_admin() demands a
  -- Google-OAuth session as well as the super_admins row).
  perform set_config('request.jwt.claims', jsonb_build_object(
    'sub', sa, 'role', 'authenticated',
    'amr', jsonb_build_array(jsonb_build_object('method', 'oauth')),
    'app_metadata', jsonb_build_object('providers', jsonb_build_array('google')))::text, true);
  perform set_config('request.jwt.claim.sub', sa::text, true);

  -- ------------------------------------------------------------------ refusals
  n := n + 1;
  begin
    perform public.platform_schedule_cadence_change_v922(biz_p,'annual',switch_day,'suite');
    raise exception 'A% failed: a stripe subscription accepted a cycle switch', n;
  exception when sqlstate '22023' then null; end;

  n := n + 1;
  begin
    perform public.platform_schedule_cadence_change_v922(biz_u,'annual',switch_day,'suite');
    raise exception 'A% failed: a firm with no schedule accepted a cycle switch', n;
  exception when sqlstate '22023' then null; end;

  n := n + 1;
  begin
    perform public.platform_schedule_cadence_change_v922(biz_m,'monthly',switch_day,'suite');
    raise exception 'A% failed: a no-op switch to the current cadence was accepted', n;
  exception when sqlstate '22023' then null; end;

  -- Ruling B, stated as a refusal: a day inside the current period cuts it short.
  n := n + 1;
  begin
    perform public.platform_schedule_cadence_change_v922(biz_m,'annual',switch_day - 1,'suite');
    raise exception 'A% failed: a switch before the period end was accepted', n;
  exception when sqlstate '22023' then null; end;

  n := n + 1;
  begin
    perform public.platform_schedule_cadence_change_v922(biz_m,'fortnightly',switch_day,'suite');
    raise exception 'A% failed: an invalid cadence was accepted', n;
  exception when sqlstate '22023' then null; end;

  n := n + 1;
  begin
    perform public.platform_schedule_cadence_change_v922(biz_m,'annual',switch_day,'  ');
    raise exception 'A% failed: a cycle switch was accepted with no reason', n;
  exception when sqlstate '22023' then null; end;

  -- ------------------------------------------------------------------ the happy path
  select * into before_row from public.subscriptions where business_id=biz_m;
  got := public.platform_schedule_cadence_change_v922(biz_m,'annual',switch_day,'suite: monthly to annual');
  select * into after_row from public.subscriptions where business_id=biz_m;

  n := n + 1;
  if after_row.scheduled_cadence <> 'annual' then
    raise exception 'A% failed: scheduled_cadence is % not annual', n, after_row.scheduled_cadence; end if;

  n := n + 1;
  if app.sg_day(after_row.scheduled_effective_at) <> switch_day then
    raise exception 'A% failed: effective day is % not %', n, app.sg_day(after_row.scheduled_effective_at), switch_day; end if;

  -- RULING B, the load-bearing assertion: the live period did not move.
  n := n + 1;
  if after_row.billing_cadence is distinct from before_row.billing_cadence
     or after_row.cadence_months is distinct from before_row.cadence_months
     or after_row.current_period_start is distinct from before_row.current_period_start
     or after_row.current_period_end is distinct from before_row.current_period_end
     or after_row.next_payment_at is distinct from before_row.next_payment_at then
    raise exception 'A% failed: scheduling a switch moved the live period', n; end if;

  -- v879: money state is never touched by a schedule.
  n := n + 1;
  if after_row.status is distinct from before_row.status
     or after_row.payment_status is distinct from before_row.payment_status
     or after_row.last_paid_at is distinct from before_row.last_paid_at then
    raise exception 'A% failed: scheduling a switch touched payment state', n; end if;

  n := n + 1;
  if (got->>'scheduled_cadence') <> 'annual' or (got->>'scheduled_effective_day') <> switch_day::text
     or (got->>'can_schedule_switch') <> 'true' then
    raise exception 'A% failed: the getter did not report the pending switch: %', n, got; end if;

  n := n + 1;
  if not exists(select 1 from public.audit_log where business_id=biz_m
                and action='billing_cadence_change_scheduled') then
    raise exception 'A% failed: no audit row for the scheduled switch', n; end if;

  -- ------------------------------------------------------------------ the applier
  n := n + 1;
  applied := app.apply_due_cadence_changes_v922(200);
  select * into after_row from public.subscriptions where business_id=biz_m;
  if after_row.scheduled_cadence is null or after_row.billing_cadence <> 'monthly' then
    raise exception 'A% failed: a switch that is not due yet was applied', n; end if;

  -- Bring the effective moment into the past, exactly as the clock would.
  update public.subscriptions
     set scheduled_effective_at = now() - interval '1 minute' where business_id=biz_m;
  select * into before_row from public.subscriptions where business_id=biz_m;

  n := n + 1;
  applied := app.apply_due_cadence_changes_v922(200);
  if (applied->>'applied')::int < 1 then
    raise exception 'A% failed: a due switch was not applied: %', n, applied; end if;

  select * into after_row from public.subscriptions where business_id=biz_m;

  n := n + 1;
  if after_row.billing_cadence <> 'annual' or after_row.cadence_months <> 12 then
    raise exception 'A% failed: cadence after apply is %/%', n, after_row.billing_cadence, after_row.cadence_months; end if;

  n := n + 1;
  if after_row.current_period_start is distinct from before_row.scheduled_effective_at then
    raise exception 'A% failed: the new period did not start on the effective moment', n; end if;

  n := n + 1;
  if app.sg_day(after_row.next_payment_at)
     <> (app.sg_day(before_row.scheduled_effective_at) + interval '12 months')::date then
    raise exception 'A% failed: next payment is % after a switch to annual', n, app.sg_day(after_row.next_payment_at); end if;

  n := n + 1;
  if after_row.current_period_end is distinct from after_row.next_payment_at then
    raise exception 'A% failed: period end and next payment disagree after apply', n; end if;

  n := n + 1;
  if after_row.scheduled_cadence is not null or after_row.scheduled_effective_at is not null then
    raise exception 'A% failed: the pending block survived the apply', n; end if;

  n := n + 1;
  if after_row.status is distinct from before_row.status
     or after_row.payment_status is distinct from before_row.payment_status
     or after_row.last_paid_at is distinct from before_row.last_paid_at then
    raise exception 'A% failed: applying a switch touched payment state', n; end if;

  n := n + 1;
  if not exists(select 1 from public.audit_log where business_id=biz_m
                and action='billing_cadence_change_applied') then
    raise exception 'A% failed: no audit row for the applied switch', n; end if;

  -- Idempotence: the block is cleared in the same UPDATE, so a second pass has nothing to do.
  n := n + 1;
  select count(*) into audit_n from public.audit_log
   where business_id=biz_m and action='billing_cadence_change_applied';
  applied := app.apply_due_cadence_changes_v922(200);
  if (applied->>'applied')::int <> 0 then
    raise exception 'A% failed: re-running the applier applied % more', n, applied->>'applied'; end if;
  if (select count(*) from public.audit_log
       where business_id=biz_m and action='billing_cadence_change_applied') <> audit_n then
    raise exception 'A% failed: re-running the applier wrote another audit row', n; end if;

  -- ------------------------------------------------------------------ provider rows are inert
  -- v765 records a PROVIDER's own pending plan change in the same columns. The applier must never
  -- touch those: the provider applies them and the reconciler syncs the result.
  update public.subscriptions
     set scheduled_cadence='annual', scheduled_effective_at=now() - interval '1 day'
   where business_id=biz_p;
  n := n + 1;
  applied := app.apply_due_cadence_changes_v922(200);
  select * into after_row from public.subscriptions where business_id=biz_p;
  if after_row.scheduled_cadence is null or after_row.billing_cadence <> 'monthly' then
    raise exception 'A% failed: the applier changed a provider-owned subscription', n; end if;

  -- ------------------------------------------------------------------ cancel
  -- after_row still holds the STRIPE fixture from the check above; re-read M before using its
  -- dates, or the second switch is measured against the wrong firm's period.
  select * into after_row from public.subscriptions where business_id=biz_m;
  got := public.platform_schedule_cadence_change_v922(biz_m,'monthly',app.sg_day(after_row.next_payment_at),'suite: back to monthly');
  n := n + 1;
  if (select scheduled_cadence from public.subscriptions where business_id=biz_m) <> 'monthly' then
    raise exception 'A% failed: the second switch was not recorded', n; end if;

  select * into before_row from public.subscriptions where business_id=biz_m;
  got := public.platform_cancel_cadence_change_v922(biz_m,'suite: cancel');
  select * into after_row from public.subscriptions where business_id=biz_m;

  n := n + 1;
  if after_row.scheduled_cadence is not null or after_row.scheduled_effective_at is not null then
    raise exception 'A% failed: cancel left a pending switch', n; end if;

  n := n + 1;
  if after_row.billing_cadence is distinct from before_row.billing_cadence
     or after_row.current_period_end is distinct from before_row.current_period_end
     or after_row.next_payment_at is distinct from before_row.next_payment_at then
    raise exception 'A% failed: cancel moved the live period', n; end if;

  n := n + 1;
  begin
    perform public.platform_cancel_cadence_change_v922(biz_m,'suite: nothing pending');
    raise exception 'A% failed: cancel succeeded with nothing scheduled', n;
  exception when sqlstate '22023' then null; end;

  n := n + 1;
  if not exists(select 1 from public.audit_log where business_id=biz_m
                and action='billing_cadence_change_cancelled') then
    raise exception 'A% failed: no audit row for the cancelled switch', n; end if;

  -- ------------------------------------------------------------------ the getter, unset firm
  n := n + 1;
  got := public.platform_get_billing_schedule_v883(biz_u);
  if (got->>'can_schedule_switch') <> 'false' then
    raise exception 'A% failed: a firm with no schedule offered a switch', n; end if;

  n := n + 1;
  got := public.platform_get_billing_schedule_v883(biz_p);
  if (got->>'editable') <> 'false' or (got->>'can_schedule_switch') <> 'false' then
    raise exception 'A% failed: a stripe firm was offered an editable switch', n; end if;

  raise notice 'v922 suite: % assertions passed', n;
end
$suite$;

rollback;
