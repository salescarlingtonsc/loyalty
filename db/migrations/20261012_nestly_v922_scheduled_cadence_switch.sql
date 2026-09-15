-- nestly_v922 — a manual firm can be switched between billing cycles from a future date.
--
-- OWNER, 2026-09-15: "can i change a user from monthly to yearly starting from next month (vice
-- versa)". Today the answer is no, three times over:
--
--   1. public.subscriptions has carried the scheduled-change block since v765 (scheduled_cadence,
--      scheduled_plan_id, scheduled_effective_at, scheduled_amount_cents) but its only writer,
--      public.record_billing_schedule_v764, is granted to service_role ONLY, has ZERO callers
--      anywhere in the database, and ZERO references in app/platform-console.js. It was built for
--      the reconciler to MIRROR a provider-side plan change; no human path ever reached it.
--   2. NOTHING applies the block. Every reader of scheduled_effective_at (get_business_billing_v758
--      / v786 and the v764 writer pair) only displays or writes it. The effective date arriving
--      changed nothing, so even a hand-written row would have been decoration.
--   3. The one editor that does exist — platform_set_billing_schedule_v883 — rewrites
--      current_period_start the instant you save. Setting a future start day therefore ERASES the
--      period the firm is still inside: a firm mid-way through a monthly period that is switched
--      to annual from the 1st loses the record that the current month is still owed.
--
-- OWNER RULINGS, 2026-09-15, both recorded so they are not re-litigated:
--   A. MANUAL FIRMS ONLY. A stripe/razorpay subscription's cycle is owned by the provider and our
--      row is a mirror of it (v77/v755/v791 overwrite it on every event). Writing a switch only
--      into our table would show "yearly" in the console while the provider kept charging monthly
--      — a lie with a payment attached. Those firms keep v883's read-only panel, which already
--      says to change the plan at the provider. Pushing a real plan change INTO the provider is a
--      separate, larger piece of work and is deliberately NOT started here.
--   B. KEEP THE CURRENT PERIOD, SWITCH AFTER IT. The pending switch does not touch
--      current_period_start / current_period_end / next_payment_at at all. The period the firm is
--      in runs to its end and stays due; the new cadence begins on the effective day. That is what
--      "starting from next month" means, and it is the exact defect in (3) above.
--
-- WHAT THIS ADDS
--   public.platform_schedule_cadence_change_v922(business, cadence, effective_on, reason)
--   public.platform_cancel_cadence_change_v922(business, reason)
--     Super-admin, manual-provider only. The first records the pending switch; the second clears
--     it. Both audit. Neither touches the live period, status, payment_status or last_paid_at —
--     v879's rule stands: "paid" is flipped only by an evidenced payment, and a scheduled switch
--     says what the NEXT period will cost, not that anything arrived.
--
--   app.apply_due_cadence_changes_v922(limit)
--     The applier that was missing. On/after scheduled_effective_at it rolls a MANUAL subscription
--     onto the new cadence: billing_cadence, cadence_months, and a fresh period running from the
--     effective day to one new cadence later, then clears the scheduled block. Idempotent (the
--     clear is in the same UPDATE as the switch, so a row is picked up exactly once) and
--     concurrency-safe (skip locked).
--
--   public.platform_get_billing_schedule_v883 is patched in place, additively, to report the
--     pending switch. A new sibling getter would have meant two authorities for one fact; the
--     console reads this one function and now sees three more keys. No existing key changes
--     meaning, so every current reader is unaffected.
--
-- WHY A NEW CRON JOB IS FINE HERE, when v765 refused one. v765's refusal was specific: the work it
-- needed done (a provider cancel) had to go through the JWT-gated edge command function, and
-- public.billing_commands.requested_by is NOT NULL, so a cron would have had to forge a human's
-- user id. This applier is pure SQL over our own rows — the same shape as the fourteen other
-- plain pg_cron jobs already in this database (run_points_expiry, run_membership_renewals,
-- run_subscription_lifecycle_v94 …). It authenticates as nobody because it needs to.
--
-- It runs every 15 minutes rather than nightly on purpose: public.platform_record_subscription_
-- payment_v664 rolls a manual period forward BY THE CURRENT CADENCE, so a payment recorded after
-- the effective day but before the applier ran would advance the period by the old cycle. Fifteen
-- minutes bounds that window; the query is a partial-index lookup over ~14 manual subscriptions.
--
-- WHY REUSING THE v765 COLUMNS IS SAFE. record_billing_schedule_v764 writes them only for
-- PROVIDER subscriptions (it is the reconciler's mirror of a provider-side change, service_role
-- only). This applier and both RPCs are hard-filtered to billing_provider = 'manual', so the two
-- uses never see each other's rows, and a provider firm's recorded intent is never applied or
-- cleared by us.
--
--
-- NAME TWIN, recorded so nobody reconciles two unrelated things. A parallel session landed
-- tests/business-ui/v922-realtime-rejoin.test.mjs on main under the same semantic number while
-- this migration was being written and applied. They share a number and nothing else. The DB
-- objects below keep _v922 because they are already applied to production under that name — the
-- same call the repo made for v850/_v832 — and renaming applied production functions to tidy a
-- filename would be the riskier half of the trade.
-- Rollback suite: db/tests/v922_scheduled_cadence_switch.sql

begin;

-- ---------------------------------------------------------------------------------------------
-- 1. The scheduled cadence may be any cadence the live column already accepts.
--
-- v765 constrained scheduled_cadence to ('monthly','annual') because a provider plan change was
-- the only thing that wrote it. The v883 editor offers four frequencies, so scheduling only two of
-- them would mean a firm could be SET to quarterly but never SWITCHED to it. Widening a CHECK can
-- never invalidate an existing row.
-- ---------------------------------------------------------------------------------------------
alter table public.subscriptions
  drop constraint if exists subscriptions_scheduled_cadence_ck;
alter table public.subscriptions
  add constraint subscriptions_scheduled_cadence_ck
  check (scheduled_cadence is null
         or scheduled_cadence in ('monthly','quarterly','half_yearly','annual'));

-- The applier's only predicate, so it stays a lookup rather than a scan as firms are added.
create index if not exists subscriptions_pending_cadence_switch_v922
  on public.subscriptions (scheduled_effective_at)
  where scheduled_cadence is not null and scheduled_effective_at is not null;

-- ---------------------------------------------------------------------------------------------
-- 2. Record a pending switch.
-- ---------------------------------------------------------------------------------------------
create or replace function public.platform_schedule_cadence_change_v922(
  p_business uuid,
  p_cadence text,
  p_effective_on date,
  p_reason text
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_actor uuid := auth.uid();
  v_sub public.subscriptions%rowtype;
  v_months smallint;
  v_effective timestamptz;
  v_earliest date;
begin
  if v_actor is null or not app.is_super_admin() then
    raise exception 'super_admin_required' using errcode = '42501';
  end if;
  if length(btrim(coalesce(p_reason, ''))) not between 3 and 1000 then
    raise exception 'cadence_change_reason_required' using errcode = '22023';
  end if;
  v_months := case p_cadence
    when 'monthly' then 1 when 'quarterly' then 3 when 'half_yearly' then 6 when 'annual' then 12
    else null end;
  if v_months is null then
    raise exception 'billing_cadence_invalid' using errcode = '22023';
  end if;

  select * into v_sub from public.subscriptions where business_id = p_business for update;
  if v_sub.business_id is null then
    raise exception 'no subscription exists for this business' using errcode = '42704';
  end if;
  if v_sub.billing_provider <> 'manual' then
    raise exception 'provider_owns_schedule' using errcode = '22023';
  end if;
  -- Ruling B needs a current period to switch AFTER. A firm with no schedule at all should be
  -- given one (platform_set_billing_schedule_v883) rather than a change to something absent.
  if v_sub.billing_cadence is null or v_sub.next_payment_at is null then
    raise exception 'billing_schedule_not_set_yet' using errcode = '22023';
  end if;
  if v_sub.billing_cadence = p_cadence then
    raise exception 'cadence_unchanged' using errcode = '22023';
  end if;

  -- The earliest a switch may land is the day the current period is paid up to: anything sooner
  -- would cut the current period short, which is exactly what ruling B forbids.
  v_earliest := greatest(app.sg_day(v_sub.next_payment_at), app.sg_today());
  if p_effective_on is null then
    raise exception 'cadence_change_effective_day_required' using errcode = '22023';
  end if;
  if p_effective_on < v_earliest then
    raise exception 'cadence_change_before_period_end' using errcode = '22023';
  end if;
  if p_effective_on > app.sg_today() + interval '3 years' then
    raise exception 'cadence_change_out_of_range' using errcode = '22023';
  end if;

  v_effective := (p_effective_on::timestamp) at time zone 'Asia/Singapore';

  update public.subscriptions
     set scheduled_cadence = p_cadence,
         scheduled_effective_at = v_effective,
         scheduled_plan_id = null,
         scheduled_amount_cents = null,
         updated_at = now()
   where business_id = p_business;

  insert into public.audit_log (business_id, actor, action, entity, entity_id, detail)
  values (p_business, v_actor, 'billing_cadence_change_scheduled', 'subscription', p_business,
    jsonb_build_object(
      'source', 'platform_console_v922',
      'reason', btrim(p_reason),
      'from_cadence', v_sub.billing_cadence,
      'to_cadence', p_cadence,
      'effective_at', v_effective,
      'current_period_end', v_sub.current_period_end,
      'next_payment_at', v_sub.next_payment_at));

  return public.platform_get_billing_schedule_v883(p_business);
end
$$;

comment on function public.platform_schedule_cadence_change_v922(uuid, text, date, text) is
  'nestly_v922: super-admin records a future billing-cycle switch for a MANUAL subscription. The current period is left intact and still due; the new cadence starts on the effective day. Refuses provider-owned schedules.';

-- ---------------------------------------------------------------------------------------------
-- 3. Cancel a pending switch.
-- ---------------------------------------------------------------------------------------------
create or replace function public.platform_cancel_cadence_change_v922(
  p_business uuid,
  p_reason text
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_actor uuid := auth.uid();
  v_sub public.subscriptions%rowtype;
begin
  if v_actor is null or not app.is_super_admin() then
    raise exception 'super_admin_required' using errcode = '42501';
  end if;
  if length(btrim(coalesce(p_reason, ''))) not between 3 and 1000 then
    raise exception 'cadence_change_reason_required' using errcode = '22023';
  end if;

  select * into v_sub from public.subscriptions where business_id = p_business for update;
  if v_sub.business_id is null then
    raise exception 'no subscription exists for this business' using errcode = '42704';
  end if;
  if v_sub.billing_provider <> 'manual' then
    raise exception 'provider_owns_schedule' using errcode = '22023';
  end if;
  if v_sub.scheduled_cadence is null then
    raise exception 'no_cadence_change_scheduled' using errcode = '22023';
  end if;

  update public.subscriptions
     set scheduled_cadence = null,
         scheduled_effective_at = null,
         scheduled_plan_id = null,
         scheduled_amount_cents = null,
         updated_at = now()
   where business_id = p_business;

  insert into public.audit_log (business_id, actor, action, entity, entity_id, detail)
  values (p_business, v_actor, 'billing_cadence_change_cancelled', 'subscription', p_business,
    jsonb_build_object(
      'source', 'platform_console_v922',
      'reason', btrim(p_reason),
      'cancelled_cadence', v_sub.scheduled_cadence,
      'cancelled_effective_at', v_sub.scheduled_effective_at));

  return public.platform_get_billing_schedule_v883(p_business);
end
$$;

comment on function public.platform_cancel_cadence_change_v922(uuid, text) is
  'nestly_v922: super-admin clears a pending billing-cycle switch on a MANUAL subscription. Never touches the live period.';

-- ---------------------------------------------------------------------------------------------
-- 4. The applier — the half that v765 never built.
-- ---------------------------------------------------------------------------------------------
create or replace function app.apply_due_cadence_changes_v922(p_limit integer default 200)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_row record;
  v_months smallint;
  v_start timestamptz;
  v_next timestamptz;
  v_applied integer := 0;
begin
  for v_row in
    select business_id, billing_cadence, scheduled_cadence, scheduled_effective_at,
           current_period_start, current_period_end, next_payment_at
    from public.subscriptions
    where billing_provider = 'manual'
      and scheduled_cadence is not null
      and scheduled_effective_at is not null
      and scheduled_effective_at <= now()
    order by scheduled_effective_at
    limit greatest(coalesce(p_limit, 200), 1)
    for update skip locked
  loop
    v_months := case v_row.scheduled_cadence
      when 'monthly' then 1 when 'quarterly' then 3
      when 'half_yearly' then 6 when 'annual' then 12 else null end;
    -- A cadence the CHECK no longer allows cannot appear, but an unrecognised one must never be
    -- silently turned into a period of NULL months. Leave it pending and visible instead.
    if v_months is null then
      continue;
    end if;

    -- The new period starts on the effective day, in Singapore terms, and runs one new cadence.
    -- Month-end is clamped exactly the way Postgres adds an interval of months, which is the same
    -- arithmetic the console previews and v883 writes.
    v_start := v_row.scheduled_effective_at;
    v_next := ((app.sg_day(v_row.scheduled_effective_at) + make_interval(months => v_months))
                ::date::timestamp) at time zone 'Asia/Singapore';

    update public.subscriptions
       set billing_cadence = v_row.scheduled_cadence,
           cadence_months = v_months,
           current_period_start = v_start,
           current_period_end = v_next,
           next_payment_at = v_next,
           scheduled_cadence = null,
           scheduled_effective_at = null,
           scheduled_plan_id = null,
           scheduled_amount_cents = null,
           updated_at = now()
     where business_id = v_row.business_id;

    insert into public.audit_log (business_id, actor, action, entity, entity_id, detail)
    values (v_row.business_id, null, 'billing_cadence_change_applied', 'subscription',
      v_row.business_id,
      jsonb_build_object(
        'source', 'app.apply_due_cadence_changes_v922',
        'from_cadence', v_row.billing_cadence,
        'to_cadence', v_row.scheduled_cadence,
        'effective_at', v_row.scheduled_effective_at,
        'previous_period_end', v_row.current_period_end,
        'previous_next_payment_at', v_row.next_payment_at,
        'period_start', v_start,
        'period_end', v_next,
        'next_payment_at', v_next));

    v_applied := v_applied + 1;
  end loop;

  return jsonb_build_object('applied', v_applied, 'ran_at', now());
end
$$;

comment on function app.apply_due_cadence_changes_v922(integer) is
  'nestly_v922: rolls every due MANUAL subscription onto its scheduled billing cycle and clears the pending block. Idempotent, skip-locked, provider subscriptions untouched.';

-- ---------------------------------------------------------------------------------------------
-- 5. The pending switch becomes visible to the console. Additive: no existing key changes.
-- ---------------------------------------------------------------------------------------------
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
      -- nestly_v922
      'can_schedule_switch', false, 'scheduled_cadence', null,
      'scheduled_effective_day', null, 'scheduled_effective_at', null,
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
    -- nestly_v922: a switch can only be scheduled once there IS a period to switch after, and
    -- only for a manual subscription. scheduled_* is reported for every provider, because the
    -- reconciler records a provider's own pending plan change in the same columns (v765) and the
    -- console should show that too — read-only, since 'editable' is already false there.
    'can_schedule_switch', v_sub.billing_provider = 'manual'
                           and v_sub.billing_cadence is not null
                           and v_sub.next_payment_at is not null,
    'scheduled_cadence', v_sub.scheduled_cadence,
    'scheduled_effective_day', app.sg_day(v_sub.scheduled_effective_at),
    'scheduled_effective_at', v_sub.scheduled_effective_at,
    'cadences', jsonb_build_array('monthly', 'quarterly', 'half_yearly', 'annual'));
end
$$;

comment on function public.platform_get_billing_schedule_v883(uuid) is
  'nestly_v883 + v922: super-admin read of one firm''s billing schedule (cadence, period start, computed next payment), whether the console may edit it (manual provider only), and any pending cycle switch.';

-- ---------------------------------------------------------------------------------------------
-- 6. Grants. Restated verbatim from the live proacl for the replaced function; the new RPCs get
--    the same shape as their v883 siblings, and the applier is cron/service only.
-- ---------------------------------------------------------------------------------------------
revoke all on function public.platform_get_billing_schedule_v883(uuid) from public, anon;
grant execute on function public.platform_get_billing_schedule_v883(uuid) to authenticated, service_role;

revoke all on function public.platform_schedule_cadence_change_v922(uuid, text, date, text) from public, anon;
grant execute on function public.platform_schedule_cadence_change_v922(uuid, text, date, text) to authenticated, service_role;

revoke all on function public.platform_cancel_cadence_change_v922(uuid, text) from public, anon;
grant execute on function public.platform_cancel_cadence_change_v922(uuid, text) to authenticated, service_role;

revoke all on function app.apply_due_cadence_changes_v922(integer) from public, anon, authenticated;
grant execute on function app.apply_due_cadence_changes_v922(integer) to service_role;

-- ---------------------------------------------------------------------------------------------
-- 7. The applier runs. Unschedule-then-schedule, guarded, so replaying this migration leaves
--    exactly one job (the v557 idiom). Fifteen minutes, for the payment-race reason in the header.
-- ---------------------------------------------------------------------------------------------
do $cron$
begin
  if to_regnamespace('cron') is not null
     and to_regprocedure('cron.schedule(text,text,text)') is not null then
    if exists (select 1 from cron.job where jobname = 'nestly-v922-cadence-switch') then
      perform cron.unschedule('nestly-v922-cadence-switch');
    end if;
    perform cron.schedule(
      'nestly-v922-cadence-switch',
      '*/15 * * * *',
      $command$select app.apply_due_cadence_changes_v922(200)$command$);
  end if;
exception when others then null;
end $cron$;

commit;
