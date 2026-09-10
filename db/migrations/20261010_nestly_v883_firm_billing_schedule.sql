-- nestly_v883 — a manual firm's billing schedule is set from the firm record.
--
-- OWNER, 2026-09-10: "I need to either manually input the start date (select frequency) and auto
-- next payment date is furnish." Fifteen live manual subscriptions carry billing_cadence NULL and
-- next_payment_at NULL: the daily due-day buckets (v793) and reminders (v156/v685) have nothing to
-- read, so a manually-billed firm never surfaces as due. The only writer that sets a cadence today
-- is platform_record_subscription_payment_v664 — recording a payment is the wrong verb for
-- "this firm starts on the 1st and pays quarterly".
--
-- WHAT THIS ADDS. Two super-admin RPCs:
--   platform_get_billing_schedule_v883(business)  — the schedule as the console shows it, plus
--                                                    whether it is editable here.
--   platform_set_billing_schedule_v883(business, start_day, cadence, reason)
--     writes billing_cadence / cadence_months / current_period_start / current_period_end /
--     next_payment_at from ONE start day (Singapore midnight) and ONE frequency; the next payment
--     is start + one cadence, computed here, never typed.
--
-- WHAT IT REFUSES. A subscription whose billing_provider is stripe or razorpay — the provider owns
-- that schedule and the reconcilers (v77/v755/v791) overwrite it; hand-editing it would be
-- overwritten on the next event and lie in between. The RPC raises provider_owns_schedule and the
-- console shows the provider's dates read-only.
--
-- WHAT IT NEVER TOUCHES. status, payment_status, last_paid_at, obligation_period_*, the initial
-- payment evidence. v879's rule stands: "paid" is flipped only by an evidenced payment. Setting a
-- schedule says when money is expected, not that it arrived.

begin;

create or replace function public.platform_get_billing_schedule_v883(p_business uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_sub public.subscriptions%rowtype;
begin
  if auth.uid() is null or not app.is_super_admin() then
    raise exception 'super_admin_required' using errcode = '42501';
  end if;
  select * into v_sub from public.subscriptions where business_id = p_business;
  if not found then
    return jsonb_build_object(
      'business_id', p_business, 'exists', false, 'editable', false,
      'provider', null, 'cadence', null, 'cadence_months', null,
      'period_start_day', null, 'next_payment_day', null,
      'period_start', null, 'period_end', null, 'next_payment_at', null,
      'last_paid_at', null, 'status', null, 'payment_status', null,
      'cadences', jsonb_build_array('monthly', 'quarterly', 'half_yearly', 'annual'));
  end if;
  return jsonb_build_object(
    'business_id', p_business, 'exists', true,
    'editable', v_sub.billing_provider = 'manual',
    'provider', v_sub.billing_provider,
    'cadence', v_sub.billing_cadence, 'cadence_months', v_sub.cadence_months,
    'period_start_day', app.sg_day(v_sub.current_period_start),
    'next_payment_day', app.sg_day(v_sub.next_payment_at),
    'period_start', v_sub.current_period_start, 'period_end', v_sub.current_period_end,
    'next_payment_at', v_sub.next_payment_at, 'last_paid_at', v_sub.last_paid_at,
    'status', v_sub.status, 'payment_status', v_sub.payment_status,
    'updated_at', v_sub.updated_at,
    'cadences', jsonb_build_array('monthly', 'quarterly', 'half_yearly', 'annual'));
end
$$;

comment on function public.platform_get_billing_schedule_v883(uuid) is
  'nestly_v883: super-admin read of one firm''s billing schedule (cadence, period start, computed next payment) and whether the console may edit it (manual provider only).';

create or replace function public.platform_set_billing_schedule_v883(
  p_business uuid,
  p_start_day date,
  p_cadence text,
  p_reason text
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_actor uuid := auth.uid();
  v_before public.subscriptions%rowtype;
  v_after public.subscriptions%rowtype;
  v_months smallint;
  v_start timestamptz;
  v_next timestamptz;
begin
  if v_actor is null or not app.is_super_admin() then
    raise exception 'super_admin_required' using errcode = '42501';
  end if;
  if length(btrim(coalesce(p_reason, ''))) not between 3 and 1000 then
    raise exception 'billing_schedule_reason_required' using errcode = '22023';
  end if;
  v_months := case p_cadence
    when 'monthly' then 1 when 'quarterly' then 3 when 'half_yearly' then 6 when 'annual' then 12
    else null end;
  if v_months is null then
    raise exception 'billing_cadence_invalid' using errcode = '22023';
  end if;
  if p_start_day is null
     or p_start_day < date '2024-01-01'
     or p_start_day > app.sg_today() + interval '3 years' then
    raise exception 'billing_start_out_of_range' using errcode = '22023';
  end if;

  select * into v_before from public.subscriptions where business_id = p_business for update;
  if v_before.business_id is null then
    raise exception 'no subscription exists for this business' using errcode = '42704';
  end if;
  if v_before.billing_provider <> 'manual' then
    raise exception 'provider_owns_schedule' using errcode = '22023';
  end if;

  -- Singapore midnight on the chosen day; the next payment is exactly one cadence later.
  v_start := (p_start_day::timestamp) at time zone 'Asia/Singapore';
  v_next  := ((p_start_day + make_interval(months => v_months))::date::timestamp) at time zone 'Asia/Singapore';

  update public.subscriptions
     set billing_cadence = p_cadence,
         cadence_months = v_months,
         current_period_start = v_start,
         current_period_end = v_next,
         next_payment_at = v_next,
         updated_at = now()
   where business_id = p_business
  returning * into v_after;

  insert into public.audit_log (business_id, actor, action, entity, entity_id, detail)
  values (p_business, v_actor, 'billing_schedule_set', 'subscription', p_business, jsonb_build_object(
    'source', 'platform_console_v883',
    'reason', btrim(p_reason),
    'before', jsonb_build_object(
      'cadence', v_before.billing_cadence, 'period_start', v_before.current_period_start,
      'period_end', v_before.current_period_end, 'next_payment_at', v_before.next_payment_at),
    'after', jsonb_build_object(
      'cadence', v_after.billing_cadence, 'period_start', v_after.current_period_start,
      'period_end', v_after.current_period_end, 'next_payment_at', v_after.next_payment_at)));

  return public.platform_get_billing_schedule_v883(p_business);
end
$$;

comment on function public.platform_set_billing_schedule_v883(uuid, date, text, text) is
  'nestly_v883: super-admin write of a MANUAL subscription''s start day + cadence; next payment = start + one cadence. Refuses provider-owned (stripe/razorpay) schedules. Never touches status/payment_status (v879).';

revoke all on function public.platform_get_billing_schedule_v883(uuid) from public, anon;
grant execute on function public.platform_get_billing_schedule_v883(uuid) to authenticated, service_role;
revoke all on function public.platform_set_billing_schedule_v883(uuid, date, text, text) from public, anon;
grant execute on function public.platform_set_billing_schedule_v883(uuid, date, text, text) to authenticated, service_role;

commit;
