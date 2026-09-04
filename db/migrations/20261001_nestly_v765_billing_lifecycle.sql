-- nestly_v765 — the billing page runs the subscription's life, not just its shape (2026-09-05).
--
-- OWNER RULINGS (2026-09-05, five of them, recorded in the wave spec):
--   1. Adding a branch mid-period says the pro-rata price and the date it covers until BEFORE
--      the owner confirms, charges immediately, and the payments history afterwards says WHICH
--      branch, how much, and until when.
--   2. Removing a branch is "Switch off": it keeps working until the paid period ends. (Copy
--      only; the v665 RPCs already do this and are not touched here.)
--   3. A billing-cycle change takes effect on the renewal date, and the page SAYS the date and
--      the new price.
--   4. "Cancel renewal" keeps the workspace working until the period ends, and Resume re-enables
--      it — until the cancel has actually been sent to the provider.
--   5. "Update card" opens the provider's card-change sheet and the digits on the page refresh.
--
-- ---------------------------------------------------------------------------------------------
-- WHY v765 AND NOT v764 (read this before renaming anything)
-- ---------------------------------------------------------------------------------------------
-- This wave was specified as "v764". While it was being written, a PARALLEL session shipped and
-- APPLIED `nestly_v764_birthday_rejoin_guard_and_tombstone_ban` to production. A semantic version
-- is a claim about what is in the database, so this migration takes the next free number, v765.
--
-- The RPC NAMES below deliberately keep their `_v764` suffix. Two other builders (the edge
-- functions and the browser client) were already coding against those exact identifiers, and a
-- function name is a cross-process contract, not a version claim. Renaming them here would break
-- both callers to fix a cosmetic inconsistency. The names are frozen as published; the FILE is
-- v765. Nothing in the v764 birthday migration shares a single identifier with this one.
--
-- ---------------------------------------------------------------------------------------------
-- WHY THE RENEWAL CANCEL IS NOT A CRON-DRIVEN COMMAND (the design decision this wave turned on)
-- ---------------------------------------------------------------------------------------------
-- Razorpay's `cancel_at_cycle_end=1` CANNOT be undone — once sent, the subscription ends at the
-- cycle end and cannot be reactivated. So "Cancel renewal" must be a LOCAL INTENT that is only
-- transmitted to the provider shortly before the renewal, leaving the owner a window to change
-- their mind. Something therefore has to send it.
--
-- The obvious shape was a nightly cron that inserts a `cancel_at_period_end` billing_commands row
-- and posts to the razorpay-billing-command edge function the way
-- app.run_billing_reconcile_call_v624() posts to the reconciler. That shape DOES NOT WORK, and
-- the reason is structural rather than a matter of taste:
--
--   * public.billing_commands.requested_by is NOT NULL, so there is no such thing as a
--     system-actor command row. A cron would have to forge a human's user id.
--   * public.claim_billing_command_v124(p_command, p_actor) — which v130 delegates to — selects
--     `where id=p_command and requested_by=p_actor` and raises 42501 when that does not match.
--     The command function's contract IS "the user who asked is the user who claims".
--   * The edge command function is JWT-gated. The reconciler is not: it authenticates with
--     x-nestly-reconciliation-secret out of the vault, which is exactly why v624 can call it
--     from cron.
--
-- So the enforcement is RECONCILE-DRIVEN. This migration exposes
-- public.list_due_renewal_cancels_v764() (service_role) and
-- public.mark_renewal_cancel_sent_v764() (service_role); the already-scheduled nightly
-- `nestly-v624-billing-reconcile` job (30 19 * * *, secret-authenticated, no user JWT) reads the
-- due list, performs the provider cancel, and marks it sent. NO NEW CRON JOB IS CREATED HERE —
-- adding one would mean a second nightly billing sweep with no way to authenticate.
--
-- ---------------------------------------------------------------------------------------------
-- WHAT THIS MIGRATION DOES
--   1. public.billing_provider_invoices gains `reason` and `detail`. The Razorpay applier is
--      PATCHED IN PLACE by extract-and-diff (the v174/v664/v755/v758 idiom: read the live body,
--      assert each needle appears exactly once, replace, execute) so it reads the payment's
--      `notes` — {reason, branch_id, branch_name, covers_from, covers_until} — into them. With no
--      usable note the reason defaults to 'initial' for a subscription's FIRST invoice and
--      'renewal' for every one after it. public.get_business_billing_v77 is patched the same way
--      so both keys reach every reader that already renders `invoices[]`, rather than a second
--      invoice projection being written somewhere downstream.
--   2. public.subscriptions gains the scheduled-change block (scheduled_cadence,
--      scheduled_plan_id, scheduled_effective_at, scheduled_amount_cents) and the renewal-cancel
--      intent pair (renewal_cancel_requested_at, renewal_cancel_sent_at). Every RPC below that
--      changes any of them writes public.audit_log.
--   3. Six new RPCs (see the signature list in section 4) plus the service-role due-list reader.
--   4. public.get_business_billing_v758 reports the new subscription state: summary.state becomes
--      'canceling' while an intent is set, summary.renewal_cancel_final_after says when Resume
--      stops being offered (period end minus 48h — the window the reconciler sends in), and
--      summary.scheduled_change carries the cycle change with its effective date and price.
--   5. public.billing_commands accepts two more command types, 'update_card' and
--      'refresh_payment_method', and public.request_billing_command_v124 (extract-and-diff again)
--      allows them — but only for a tenant that actually has a provider subscription, since both
--      are meaningless without one.
--   6. LEGACY TRUTH, one row: Cafe2U (ded721a7-6b3c-426f-8842-6ecf56725e01). Two earlier billing
--      commands really did send cancel_at_cycle_end=1 to Razorpay for sub_TY2TBGS2P1WeKX, so that
--      subscription is irrevocably ending at its cycle end. The page must say so instead of
--      offering a Resume that cannot work, so the intent is recorded as already SENT, with an
--      audit row naming why.
--
-- NOT DONE HERE, deliberately:
--   * No cron job (see above).
--   * The v665 branch switch-off RPCs are untouched — owner ruling 2 is copy, not behaviour.
--   * `preview_branch_addition_v764` is an ESTIMATE and says so. Razorpay computes its own daily
--      proration; the amount actually charged is whatever the provider invoice says, and that
--      invoice is the recorded truth. The preview exists so the owner is not asked to confirm a
--      charge of unknown size.
--
-- Rollback suite: db/tests/v765_billing_lifecycle.sql
-- Executed acceptance: db/tests/executed/v765_corpus_billing_lifecycle.sql
--   Run: LC_ALL=C node scripts/db-tests/run.mjs --filter=v765_corpus --migrated-only

begin;

-- =============================================================================================
-- 1 · An invoice says what it was for.
-- =============================================================================================
alter table public.billing_provider_invoices
  add column if not exists reason text,
  add column if not exists detail jsonb;

alter table public.billing_provider_invoices
  drop constraint if exists billing_provider_invoices_reason_ck;
alter table public.billing_provider_invoices
  add constraint billing_provider_invoices_reason_ck
  check (reason is null or reason in
         ('initial','renewal','branch_added','plan_changed','card_change','other'));

comment on column public.billing_provider_invoices.reason is
  'Why this invoice exists. Read from the provider payment notes; defaults to initial for a '
  'subscription''s first invoice and renewal thereafter. Display truth, never billing truth.';
comment on column public.billing_provider_invoices.detail is
  'Optional {branch_id,branch_name,covers_from,covers_until} for the payments-history line.';

-- =============================================================================================
-- 2 · The applier reads the payment notes (extract-and-diff; the webhook keeps calling v755).
-- =============================================================================================
do $v765_applier_reason$
declare
  v_definition text := pg_get_functiondef(
    'public.apply_razorpay_billing_event_v755(text)'::regprocedure
  );
  /* Declarations. */
  v_needle_a constant text := E'  v_paid boolean := false;';
  v_patch_a constant text := $patch_a$  v_notes jsonb;
  v_reason text;
  v_detail jsonb;
  v_paid boolean := false;$patch_a$;
  /* The invoice identity line, immediately after which the reason is resolved. */
  v_needle_b constant text :=
    E'      v_invoice := coalesce(nullif(v_payment->>''invoice_id'',''''),v_payment->>''id'');';
  v_patch_b constant text := $patch_b$      v_invoice := coalesce(nullif(v_payment->>'invoice_id',''),v_payment->>'id');
      /* v765: why this invoice exists. Razorpay carries our own words back in the payment
         notes; an absent or unrecognised note falls back to position in the cycle sequence —
         the first invoice a subscription ever produced is the initial payment, the rest are
         renewals. An unknown string is never trusted through to the constraint. */
      v_notes := case when jsonb_typeof(v_payment->'notes') = 'object'
                      then v_payment->'notes' else '{}'::jsonb end;
      v_reason := lower(nullif(btrim(coalesce(v_notes->>'reason','')),''));
      if v_reason is null or v_reason not in
         ('initial','renewal','branch_added','plan_changed','card_change','other') then
        v_reason := case when exists(
                           select 1 from public.billing_provider_invoices prior_invoice
                            where prior_invoice.provider_subscription_id = v_subscription_id
                              and prior_invoice.provider_invoice_id <> v_invoice
                         ) then 'renewal' else 'initial' end;
      end if;
      v_detail := jsonb_strip_nulls(jsonb_build_object(
        'branch_id', nullif(btrim(coalesce(v_notes->>'branch_id','')),''),
        'branch_name', nullif(btrim(coalesce(v_notes->>'branch_name','')),''),
        'covers_from', coalesce(
          nullif(btrim(coalesce(v_notes->>'covers_from','')),''),
          to_char(v_period_start at time zone 'Asia/Singapore','YYYY-MM-DD')),
        'covers_until', coalesce(
          nullif(btrim(coalesce(v_notes->>'covers_until','')),''),
          to_char(v_period_end at time zone 'Asia/Singapore','YYYY-MM-DD'))
      ));$patch_b$;
  /* The invoice insert's column list (net_cash_ex_tax_cents appears in no other insert). */
  v_needle_c constant text :=
       E'        net_cash_ex_tax_cents,period_start,period_end,paid_at,finalized_at,\n'
    || E'        livemode,provider_event_created_at,provider_event_rank,last_event_id\n'
    || E'      ) values (';
  v_patch_c constant text :=
       E'        net_cash_ex_tax_cents,period_start,period_end,paid_at,finalized_at,\n'
    || E'        livemode,provider_event_created_at,provider_event_rank,last_event_id,\n'
    || E'        reason,detail\n'
    || E'      ) values (';
  /* Its values list, pinned by the conflict target that follows it. */
  v_needle_d constant text :=
       E'        v_event.livemode,v_event.event_created_at,v_rank,v_event.event_id\n'
    || E'      )\n'
    || E'      on conflict(provider_invoice_id) do update';
  v_patch_d constant text :=
       E'        v_event.livemode,v_event.event_created_at,v_rank,v_event.event_id,\n'
    || E'        v_reason,v_detail\n'
    || E'      )\n'
    || E'      on conflict(provider_invoice_id) do update';
  /* And the replay path: a re-delivered event must be able to fill a reason in, but must never
     erase one a later, better-informed event already recorded. */
  v_needle_e constant text :=
    E'            paid_at=excluded.paid_at,finalized_at=excluded.finalized_at,';
  v_patch_e constant text :=
       E'            paid_at=excluded.paid_at,finalized_at=excluded.finalized_at,\n'
    || E'            reason=coalesce(excluded.reason,billing_provider_invoices.reason),\n'
    || E'            detail=coalesce(excluded.detail,billing_provider_invoices.detail),';

  v_needles text[] := array[v_needle_a,v_needle_b,v_needle_c,v_needle_d,v_needle_e];
  v_needle text;
  v_occurrences integer;
begin
  if position('v_reason' in v_definition) > 0 then
    raise exception 'v765 applier patch has already been applied' using errcode = '55000';
  end if;
  foreach v_needle in array v_needles loop
    v_occurrences := (length(v_definition) - length(replace(v_definition, v_needle, '')))
                     / length(v_needle);
    if v_occurrences <> 1 then
      raise exception
        'v765 expected exactly one occurrence of a needle in apply_razorpay_billing_event_v755, '
        'found % for %', v_occurrences, left(v_needle, 60) using errcode = '55000';
    end if;
  end loop;
  v_definition := replace(v_definition, v_needle_a, v_patch_a);
  v_definition := replace(v_definition, v_needle_b, v_patch_b);
  v_definition := replace(v_definition, v_needle_c, v_patch_c);
  v_definition := replace(v_definition, v_needle_d, v_patch_d);
  v_definition := replace(v_definition, v_needle_e, v_patch_e);
  execute v_definition;
end
$v765_applier_reason$;

/* Restated from the live proacl: {postgres=X/postgres,service_role=X/postgres}. */
revoke all on function public.apply_razorpay_billing_event_v755(text)
  from public, anon, authenticated;
grant execute on function public.apply_razorpay_billing_event_v755(text) to service_role;

-- =============================================================================================
-- 3 · The reader that already projects invoices[] carries the two new keys (extract-and-diff).
--     Patching v77 rather than re-projecting invoices in v758 keeps ONE invoice projection.
-- =============================================================================================
do $v765_v77_invoices$
declare
  v_definition text := pg_get_functiondef(
    'public.get_business_billing_v77(uuid)'::regprocedure
  );
  v_needle constant text :=
    E'        select provider_invoice_id,number,status,paid_normalized,currency,';
  v_patch constant text :=
    E'        select provider_invoice_id,number,status,paid_normalized,currency,reason,detail,';
  v_occurrences integer;
begin
  if position('currency,reason,detail,' in v_definition) > 0 then
    raise exception 'v765 v77 invoice patch has already been applied' using errcode = '55000';
  end if;
  v_occurrences := (length(v_definition) - length(replace(v_definition, v_needle, '')))
                   / length(v_needle);
  if v_occurrences <> 1 then
    raise exception
      'v765 expected exactly one invoice select list in get_business_billing_v77, found %',
      v_occurrences using errcode = '55000';
  end if;
  execute replace(v_definition, v_needle, v_patch);
end
$v765_v77_invoices$;

/* Restated from the live proacl of get_business_billing_v77. */
revoke all on function public.get_business_billing_v77(uuid) from public, anon;
grant execute on function public.get_business_billing_v77(uuid) to authenticated, service_role;

-- =============================================================================================
-- 4 · The subscription remembers what it has been asked to do next.
-- =============================================================================================
alter table public.subscriptions
  add column if not exists scheduled_cadence text,
  add column if not exists scheduled_plan_id text,
  add column if not exists scheduled_effective_at timestamptz,
  add column if not exists scheduled_amount_cents integer,
  add column if not exists renewal_cancel_requested_at timestamptz,
  add column if not exists renewal_cancel_sent_at timestamptz;

alter table public.subscriptions
  drop constraint if exists subscriptions_scheduled_cadence_ck;
alter table public.subscriptions
  add constraint subscriptions_scheduled_cadence_ck
  check (scheduled_cadence is null or scheduled_cadence in ('monthly','annual'));

alter table public.subscriptions
  drop constraint if exists subscriptions_scheduled_amount_ck;
alter table public.subscriptions
  add constraint subscriptions_scheduled_amount_ck
  check (scheduled_amount_cents is null or scheduled_amount_cents >= 0);

/* A cancel cannot have been SENT to the provider without having been ASKED for first. This is
   the invariant that keeps the page honest: renewal_cancel_sent_at is what disables Resume, and
   it may never appear on its own. */
alter table public.subscriptions
  drop constraint if exists subscriptions_renewal_cancel_order_ck;
alter table public.subscriptions
  add constraint subscriptions_renewal_cancel_order_ck
  check (renewal_cancel_sent_at is null or renewal_cancel_requested_at is not null);

comment on column public.subscriptions.renewal_cancel_requested_at is
  'The owner asked not to renew. LOCAL INTENT ONLY - nothing has been sent to the provider yet, '
  'so Resume still works. Cleared by set_renewal_intent_v764(business,false).';
comment on column public.subscriptions.renewal_cancel_sent_at is
  'The cancel was transmitted to the provider and is irreversible there. Resume is refused from '
  'this moment on. Written only by mark_renewal_cancel_sent_v764 (service_role).';
comment on column public.subscriptions.scheduled_effective_at is
  'When a scheduled billing-cycle change takes effect - the current period end, not now.';

-- =============================================================================================
-- 5 · preview_branch_addition_v764 — what adding a branch today costs, before the owner confirms.
-- =============================================================================================
create or replace function public.preview_branch_addition_v764(
  p_business uuid,
  p_branch_name text default null
) returns jsonb
language plpgsql
stable
security definer
set search_path = pg_catalog, public, app, pg_temp
as $fn$
declare
  /* The guard is character-for-character the one get_business_billing_v124 uses. A pricing
     preview names the tenant's plan, period and card, so it is exactly as sensitive as the
     billing page itself and gets exactly the same door. */
  v_subscription public.subscriptions%rowtype;
  v_cadence text;
  v_capacity integer;
  v_unit_amount_cents integer;
  v_period_start_day date;
  v_period_end_day date;
  v_today date := (now() at time zone 'Asia/Singapore')::date;
  v_period_days integer;
  v_days_remaining integer;
  v_prorata_cents integer;
  v_card jsonb;
begin
  if auth.uid() is null
     or not (app.is_billing_owner_v620(p_business) or app.is_super_admin()) then
    raise exception 'active owner or super-admin access is required'
      using errcode = '42501';
  end if;

  select * into v_subscription from public.subscriptions
   where business_id = p_business;
  if not found then
    raise exception 'billing subscription was not found' using errcode = '22023';
  end if;

  select terms.cadence, terms.customer_capacity
    into v_cadence, v_capacity
    from public.billing_subscription_terms_v124 terms
   where terms.business_id = p_business;

  if v_cadence is not null and v_capacity is not null then
    select tier.amount_cents into v_unit_amount_cents
      from public.billing_capacity_tier_catalog_v664 tier
     where tier.currency = 'SGD' and tier.active
       and tier.cadence = v_cadence
       and tier.capacity_ceiling = v_capacity
       and tier.effective_from <= now()
       and (tier.effective_to is null or tier.effective_to > now())
     order by tier.effective_from desc
     limit 1;
  end if;

  select jsonb_build_object(
           'brand', customer.payment_method_brand,
           'last4', customer.payment_method_last4
         )
    into v_card
    from public.billing_provider_customers customer
   where customer.business_id = p_business
     and customer.payment_method_kind is not null;

  /* Without a priced plan and a dated period there is no honest number to show, and inventing
     one would put a figure in a confirmation dialog that nothing can stand behind. */
  if v_unit_amount_cents is null
     or v_subscription.current_period_start is null
     or v_subscription.current_period_end is null then
    return jsonb_build_object(
      'status','unavailable',
      'reason', case when v_unit_amount_cents is null then 'no_priced_plan'
                     else 'no_billing_period' end,
      'branch_name', nullif(btrim(coalesce(p_branch_name,'')),''),
      'currency','SGD',
      'card', v_card
    );
  end if;

  /* Calendar days in Singapore, the day the owner is actually looking at the screen. The period
     end day is INCLUSIVE: a branch switched on on the last day of the period is paid for that
     one day, never for zero. Date arithmetic makes leap years fall out for free - a period
     spanning 29 Feb simply has 366 days in it. */
  v_period_start_day := (v_subscription.current_period_start
                          at time zone 'Asia/Singapore')::date;
  v_period_end_day := (v_subscription.current_period_end
                        at time zone 'Asia/Singapore')::date;
  v_period_days := greatest(v_period_end_day - v_period_start_day, 1);
  v_days_remaining := least(greatest((v_period_end_day - v_today) + 1, 1), v_period_days);
  v_prorata_cents := round(
    v_unit_amount_cents::numeric * v_days_remaining::numeric / v_period_days::numeric
  )::integer;

  return jsonb_build_object(
    'status','ok',
    'branch_name', nullif(btrim(coalesce(p_branch_name,'')),''),
    'currency','SGD',
    'cadence', v_cadence,
    'capacity', v_capacity,
    'unit_amount_cents', v_unit_amount_cents,
    'period_start', v_subscription.current_period_start,
    'period_end', v_subscription.current_period_end,
    'period_days', v_period_days,
    'days_remaining', v_days_remaining,
    'prorata_cents', v_prorata_cents,
    'covers_until', to_char(v_period_end_day,'YYYY-MM-DD'),
    'card', v_card,
    /* Said plainly so no caller renders this as the amount that will be taken. */
    'estimate', true
  );
end
$fn$;

revoke all on function public.preview_branch_addition_v764(uuid,text) from public, anon;
grant execute on function public.preview_branch_addition_v764(uuid,text)
  to authenticated, service_role;

-- =============================================================================================
-- 6 · set_renewal_intent_v764 — the local, reversible half of "Cancel renewal".
-- =============================================================================================
create or replace function public.set_renewal_intent_v764(
  p_business uuid,
  p_cancel boolean
) returns jsonb
language plpgsql
volatile
security definer
set search_path = pg_catalog, public, app, pg_temp
as $fn$
declare
  v_actor uuid := auth.uid();
  v_subscription public.subscriptions%rowtype;
  v_now timestamptz := now();
begin
  if v_actor is null
     or not (app.is_billing_owner_v620(p_business) or app.is_super_admin()) then
    raise exception 'active owner or super-admin access is required'
      using errcode = '42501';
  end if;
  if p_cancel is null then
    raise exception 'a renewal intent is required' using errcode = '22023';
  end if;

  select * into v_subscription from public.subscriptions
   where business_id = p_business for update;
  if not found then
    raise exception 'billing subscription was not found' using errcode = '22023';
  end if;

  /* Once the cancel has reached the provider it cannot be taken back there, so it must not be
     takeable back here either. A page that offered Resume after this point would be lying. */
  if v_subscription.renewal_cancel_sent_at is not null then
    raise exception 'the renewal cancel has already been sent and cannot be changed'
      using errcode = '22023';
  end if;

  if p_cancel and v_subscription.renewal_cancel_requested_at is not null then
    return jsonb_build_object(
      'status','ok','business_id',p_business,'cancel_requested',true,'unchanged',true,
      'renewal_cancel_requested_at',v_subscription.renewal_cancel_requested_at,
      'current_period_end',v_subscription.current_period_end
    );
  end if;
  if not p_cancel and v_subscription.renewal_cancel_requested_at is null then
    return jsonb_build_object(
      'status','ok','business_id',p_business,'cancel_requested',false,'unchanged',true,
      'renewal_cancel_requested_at',null,
      'current_period_end',v_subscription.current_period_end
    );
  end if;

  update public.subscriptions
     set renewal_cancel_requested_at = case when p_cancel then v_now else null end,
         updated_at = v_now
   where business_id = p_business
   returning * into v_subscription;

  insert into public.audit_log(business_id,actor,action,entity,entity_id,detail)
  values (
    p_business, v_actor,
    case when p_cancel then 'RENEWAL_CANCEL_REQUESTED_V764'
         else 'RENEWAL_CANCEL_WITHDRAWN_V764' end,
    'subscriptions', p_business,
    jsonb_build_object(
      'cancel_requested', p_cancel,
      'renewal_cancel_requested_at', v_subscription.renewal_cancel_requested_at,
      'current_period_end', v_subscription.current_period_end,
      'provider_subscription_id', v_subscription.provider_subscription_id
    )
  );

  return jsonb_build_object(
    'status','ok','business_id',p_business,'cancel_requested',p_cancel,'unchanged',false,
    'renewal_cancel_requested_at',v_subscription.renewal_cancel_requested_at,
    'current_period_end',v_subscription.current_period_end
  );
end
$fn$;

revoke all on function public.set_renewal_intent_v764(uuid,boolean) from public, anon;
grant execute on function public.set_renewal_intent_v764(uuid,boolean)
  to authenticated, service_role;

-- =============================================================================================
-- 7 · record_billing_schedule_v764 / clear_billing_schedule_v764 — the provider's queued change,
--     mirrored so the page can name the date and the new price without calling out.
-- =============================================================================================
create or replace function public.record_billing_schedule_v764(
  p_business uuid,
  p_kind text,
  p_target_cadence text,
  p_target_plan_id text,
  p_effective_at timestamptz,
  p_amount_cents integer
) returns jsonb
language plpgsql
volatile
security definer
set search_path = pg_catalog, public, app, pg_temp
as $fn$
declare
  v_kind text := lower(nullif(btrim(coalesce(p_kind,'')),''));
  v_cadence text := lower(nullif(btrim(coalesce(p_target_cadence,'')),''));
  v_plan text := nullif(btrim(coalesce(p_target_plan_id,'')),'');
  v_subscription public.subscriptions%rowtype;
begin
  if p_business is null then
    raise exception 'a business id is required' using errcode = '22023';
  end if;
  /* Only the billing cycle is schedulable today. A future kind gets its own columns and its own
     rendering rather than being smuggled through these. */
  if v_kind is distinct from 'cadence' then
    raise exception 'only a cadence schedule can be recorded' using errcode = '22023';
  end if;
  if v_cadence is null or v_cadence not in ('monthly','annual') then
    raise exception 'a scheduled cadence must be monthly or annual' using errcode = '22023';
  end if;
  if p_effective_at is null then
    raise exception 'a scheduled change needs the date it takes effect' using errcode = '22023';
  end if;
  if p_amount_cents is not null and p_amount_cents < 0 then
    raise exception 'a scheduled amount cannot be negative' using errcode = '22023';
  end if;

  update public.subscriptions
     set scheduled_cadence = v_cadence,
         scheduled_plan_id = v_plan,
         scheduled_effective_at = p_effective_at,
         scheduled_amount_cents = p_amount_cents,
         updated_at = now()
   where business_id = p_business
   returning * into v_subscription;
  if not found then
    raise exception 'billing subscription was not found' using errcode = '22023';
  end if;

  insert into public.audit_log(business_id,actor,action,entity,entity_id,detail)
  values (
    p_business, null, 'BILLING_SCHEDULE_RECORDED_V764', 'subscriptions', p_business,
    jsonb_build_object(
      'kind', v_kind,
      'scheduled_cadence', v_cadence,
      'scheduled_plan_id', v_plan,
      'scheduled_effective_at', p_effective_at,
      'scheduled_amount_cents', p_amount_cents,
      'provider_subscription_id', v_subscription.provider_subscription_id
    )
  );

  return jsonb_build_object(
    'status','ok','business_id',p_business,'kind',v_kind,
    'scheduled_cadence',v_cadence,'scheduled_plan_id',v_plan,
    'scheduled_effective_at',p_effective_at,'scheduled_amount_cents',p_amount_cents
  );
end
$fn$;

revoke all on function public.record_billing_schedule_v764(
  uuid,text,text,text,timestamptz,integer) from public, anon, authenticated;
grant execute on function public.record_billing_schedule_v764(
  uuid,text,text,text,timestamptz,integer) to service_role;

create or replace function public.clear_billing_schedule_v764(
  p_business uuid,
  p_reason text default null
) returns jsonb
language plpgsql
volatile
security definer
set search_path = pg_catalog, public, app, pg_temp
as $fn$
declare
  v_subscription public.subscriptions%rowtype;
  v_had boolean;
begin
  if p_business is null then
    raise exception 'a business id is required' using errcode = '22023';
  end if;
  select * into v_subscription from public.subscriptions
   where business_id = p_business for update;
  if not found then
    raise exception 'billing subscription was not found' using errcode = '22023';
  end if;
  v_had := v_subscription.scheduled_cadence is not null
           or v_subscription.scheduled_effective_at is not null;

  update public.subscriptions
     set scheduled_cadence = null, scheduled_plan_id = null,
         scheduled_effective_at = null, scheduled_amount_cents = null,
         updated_at = now()
   where business_id = p_business;

  /* Clearing nothing is not an event. Only a schedule that actually existed is audited, so the
     log records changes rather than the reconciler's heartbeat. */
  if v_had then
    insert into public.audit_log(business_id,actor,action,entity,entity_id,detail)
    values (
      p_business, null, 'BILLING_SCHEDULE_CLEARED_V764', 'subscriptions', p_business,
      jsonb_build_object(
        'reason', nullif(btrim(coalesce(p_reason,'')),''),
        'previous_scheduled_cadence', v_subscription.scheduled_cadence,
        'previous_scheduled_plan_id', v_subscription.scheduled_plan_id,
        'previous_scheduled_effective_at', v_subscription.scheduled_effective_at,
        'previous_scheduled_amount_cents', v_subscription.scheduled_amount_cents
      )
    );
  end if;

  return jsonb_build_object('status','ok','business_id',p_business,'cleared',v_had);
end
$fn$;

revoke all on function public.clear_billing_schedule_v764(uuid,text)
  from public, anon, authenticated;
grant execute on function public.clear_billing_schedule_v764(uuid,text) to service_role;

-- =============================================================================================
-- 8 · The reconcile-driven enforcement pair (see the header for why it is not a cron command).
-- =============================================================================================
create or replace function public.list_due_renewal_cancels_v764()
returns jsonb
language plpgsql
stable
security definer
set search_path = pg_catalog, public, app, pg_temp
as $fn$
declare
  v_rows jsonb;
begin
  select coalesce(jsonb_agg(to_jsonb(due) order by due.current_period_end), '[]'::jsonb)
    into v_rows
    from (
      select s.business_id,
             s.provider_subscription_id,
             s.billing_provider,
             s.current_period_end,
             s.renewal_cancel_requested_at
        from public.subscriptions s
       where s.renewal_cancel_requested_at is not null
         and s.renewal_cancel_sent_at is null
         and s.provider_subscription_id is not null
         and s.current_period_end is not null
         /* The 48h window is the promise the page makes: Resume works until here. Sending
            earlier would break that promise; sending later risks missing the renewal. */
         and s.current_period_end < now() + interval '48 hours'
         and coalesce(s.status,'') not in ('canceled','incomplete_expired')
    ) due;
  return jsonb_build_object('status','ok','due',v_rows);
end
$fn$;

revoke all on function public.list_due_renewal_cancels_v764()
  from public, anon, authenticated;
grant execute on function public.list_due_renewal_cancels_v764() to service_role;

create or replace function public.mark_renewal_cancel_sent_v764(
  p_business uuid,
  p_provider_reference text default null
) returns jsonb
language plpgsql
volatile
security definer
set search_path = pg_catalog, public, app, pg_temp
as $fn$
declare
  v_subscription public.subscriptions%rowtype;
  v_now timestamptz := now();
begin
  if p_business is null then
    raise exception 'a business id is required' using errcode = '22023';
  end if;
  select * into v_subscription from public.subscriptions
   where business_id = p_business for update;
  if not found then
    raise exception 'billing subscription was not found' using errcode = '22023';
  end if;
  /* Fail closed: a "sent" mark with no intent behind it would silently disable Resume for a
     tenant who never asked to cancel. The table constraint says the same thing. */
  if v_subscription.renewal_cancel_requested_at is null then
    raise exception 'this subscription has no renewal cancel to send' using errcode = '22023';
  end if;
  if v_subscription.renewal_cancel_sent_at is not null then
    return jsonb_build_object(
      'status','ok','business_id',p_business,'unchanged',true,
      'renewal_cancel_sent_at',v_subscription.renewal_cancel_sent_at
    );
  end if;

  update public.subscriptions
     set renewal_cancel_sent_at = v_now,
         cancel_at_period_end = true,
         updated_at = v_now
   where business_id = p_business
   returning * into v_subscription;

  insert into public.audit_log(business_id,actor,action,entity,entity_id,detail)
  values (
    p_business, null, 'RENEWAL_CANCEL_SENT_V764', 'subscriptions', p_business,
    jsonb_build_object(
      'renewal_cancel_requested_at', v_subscription.renewal_cancel_requested_at,
      'renewal_cancel_sent_at', v_now,
      'current_period_end', v_subscription.current_period_end,
      'provider_subscription_id', v_subscription.provider_subscription_id,
      'provider_reference', nullif(btrim(coalesce(p_provider_reference,'')),'')
    )
  );

  return jsonb_build_object(
    'status','ok','business_id',p_business,'unchanged',false,
    'renewal_cancel_sent_at',v_now,
    'current_period_end',v_subscription.current_period_end
  );
end
$fn$;

revoke all on function public.mark_renewal_cancel_sent_v764(uuid,text)
  from public, anon, authenticated;
grant execute on function public.mark_renewal_cancel_sent_v764(uuid,text) to service_role;

-- =============================================================================================
-- 9 · refresh_payment_method_request_v764 — "I have just changed my card, go and look again."
-- =============================================================================================
create or replace function public.refresh_payment_method_request_v764(p_business uuid)
returns jsonb
language plpgsql
volatile
security definer
set search_path = pg_catalog, public, app, pg_temp
as $fn$
declare
  v_actor uuid := auth.uid();
  v_updated integer;
begin
  if v_actor is null
     or not (app.is_billing_owner_v620(p_business) or app.is_super_admin()) then
    raise exception 'active owner or super-admin access is required'
      using errcode = '42501';
  end if;

  /* Nulling the digits IS the backfill flag. The kind is deliberately kept, so the page keeps
     saying "card" and only the four digits go blank for the seconds it takes the reconciler (or
     the refresh_payment_method command) to fetch the new ones. Showing the OLD digits next to a
     card the owner has just replaced would be worse than showing none. */
  update public.billing_provider_customers
     set payment_method_brand = null,
         payment_method_last4 = null,
         payment_method_source_payment_id = null,
         payment_method_updated_at = now(),
         updated_at = now()
   where business_id = p_business;
  get diagnostics v_updated = row_count;
  if v_updated = 0 then
    raise exception 'this business has no billing provider customer row' using errcode = '22023';
  end if;

  insert into public.audit_log(business_id,actor,action,entity,entity_id,detail)
  values (
    p_business, v_actor, 'PAYMENT_METHOD_REFRESH_REQUESTED_V764',
    'billing_provider_customers', p_business,
    jsonb_build_object('cleared_last4', true)
  );

  return jsonb_build_object('status','ok','business_id',p_business,'refresh_requested',true);
end
$fn$;

revoke all on function public.refresh_payment_method_request_v764(uuid) from public, anon;
grant execute on function public.refresh_payment_method_request_v764(uuid)
  to authenticated, service_role;

-- =============================================================================================
-- 10 · Two more command types: the card-change sheet, and the digit refetch behind it.
-- =============================================================================================
alter table public.billing_commands
  drop constraint if exists billing_commands_command_type_check;
alter table public.billing_commands
  add constraint billing_commands_command_type_check
  check (command_type = any (array[
    'create_checkout','create_portal','change_cadence','change_capacity',
    'change_branches','cancel_at_period_end','resume',
    'update_card','refresh_payment_method'
  ]));

do $v765_command_allowlist$
declare
  v_definition text := pg_get_functiondef(
    'public.request_billing_command_v124(uuid,text,text,integer,uuid)'::regprocedure
  );
  v_needle constant text :=
       E'      ''create_checkout'',''create_portal'',''change_cadence'',''change_capacity'',\n'
    || E'      ''change_branches'',''cancel_at_period_end'',''resume''\n'
    || E'    ) or p_idempotency_key is null then\n'
    || E'    raise exception ''invalid billing command'' using errcode=''22023'';\n'
    || E'  end if;';
  v_patch constant text := $patch$      'create_checkout','create_portal','change_cadence','change_capacity',
      'change_branches','cancel_at_period_end','resume',
      'update_card','refresh_payment_method'
    ) or p_idempotency_key is null then
    raise exception 'invalid billing command' using errcode='22023';
  end if;
  /* v765: both new types act ON a provider subscription - one opens the card-change sheet for
     it, the other refetches the card it was last charged on. Without one there is nothing to
     act on, and the edge function would discover that only after the owner had been sent to a
     checkout page. Refuse here instead. */
  if p_command_type in ('update_card','refresh_payment_method')
     and not exists(
       select 1 from public.subscriptions provider_subscription
        where provider_subscription.business_id = p_business
          and provider_subscription.provider_subscription_id is not null
     ) then
    raise exception 'this business has no provider subscription to update'
      using errcode='22023';
  end if;$patch$;
  v_occurrences integer;
begin
  if position('refresh_payment_method' in v_definition) > 0 then
    raise exception 'v765 command allowlist patch has already been applied'
      using errcode = '55000';
  end if;
  v_occurrences := (length(v_definition) - length(replace(v_definition, v_needle, '')))
                   / length(v_needle);
  if v_occurrences <> 1 then
    raise exception
      'v765 expected exactly one command allowlist in request_billing_command_v124, found %',
      v_occurrences using errcode = '55000';
  end if;
  execute replace(v_definition, v_needle, v_patch);
end
$v765_command_allowlist$;

/* Restated from the live proacl:
   {postgres=X/postgres,service_role=X/postgres,authenticated=X/postgres}. */
revoke all on function public.request_billing_command_v124(uuid,text,text,integer,uuid)
  from public, anon;
grant execute on function public.request_billing_command_v124(uuid,text,text,integer,uuid)
  to authenticated, service_role;

-- =============================================================================================
-- 11 · get_business_billing_v758 reports the lifecycle, not only the shape.
-- =============================================================================================
create or replace function public.get_business_billing_v758(p_business uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = pg_catalog, public, app, pg_temp
as $fn$
declare
  /* Delegating is the tenant guard: v125 -> v124 -> v77 all raise 42501 unless the caller is the
     active billing owner or a super admin, and v125 asserts the payload carries no GST claim. */
  v_payload jsonb := public.get_business_billing_v125(p_business);
  v_terms jsonb := v_payload->'terms';
  v_cadence text;
  v_capacity integer;
  v_unit_amount_cents integer;
  v_total integer := 0;
  v_included integer := 0;
  v_billable integer := 0;
  v_stopping integer := 0;
  v_lapsed integer := 0;
  v_unsubscribed integer := 0;
  v_branches_total integer := 0;
  v_units integer := 1;
  v_state text;
  v_trial_ends_at timestamptz;
  v_cancel_at_period_end boolean := coalesce((v_payload->>'cancel_at_period_end')::boolean,false);
  v_status text := v_payload->>'status';
  v_payment_status text := v_payload->>'payment_status';
  v_plan_label text;
  v_payment_method jsonb;
  /* v765 */
  v_subscription public.subscriptions%rowtype;
  v_renewal_cancel_final_after timestamptz;
  v_scheduled_change jsonb;
begin
  if jsonb_typeof(v_terms) = 'object' then
    v_cadence := nullif(v_terms->>'cadence','');
    v_capacity := nullif(v_terms->>'customer_capacity','')::integer;
  end if;
  v_plan_label := case v_cadence when 'annual' then 'Annual'
                                 when 'monthly' then 'Monthly' else null end;

  select * into v_subscription from public.subscriptions s where s.business_id = p_business;
  v_trial_ends_at := v_subscription.trial_ends_at;

  /* The same counts the browser was doing by hand. `included` is its own state, so the first
     branch is never in the billable set — units is 1 (the included one) plus every branch the
     tenant is actually being charged for. */
  select count(*)::integer,
         count(*) filter (where branch.billing_state = 'included')::integer,
         count(*) filter (where branch.billing_state in ('pending_payment','active'))::integer,
         count(*) filter (where branch.billing_state = 'canceling')::integer,
         count(*) filter (where branch.billing_state = 'suspended')::integer,
         count(*) filter (where branch.billing_state = 'unsubscribed')::integer
    into v_branches_total, v_included, v_billable, v_stopping, v_lapsed, v_unsubscribed
    from public.branches branch
   where branch.business_id = p_business;
  v_units := 1 + v_billable;

  if v_cadence is not null and v_capacity is not null then
    select tier.amount_cents into v_unit_amount_cents
      from public.billing_capacity_tier_catalog_v664 tier
     where tier.currency = 'SGD' and tier.active
       and tier.cadence = v_cadence
       and tier.capacity_ceiling = v_capacity
       and tier.effective_from <= now()
       and (tier.effective_to is null or tier.effective_to > now())
     order by tier.effective_from desc
     limit 1;
  end if;
  v_total := coalesce(v_unit_amount_cents,0) * v_units;

  if v_terms is null or jsonb_typeof(v_terms) <> 'object' then
    v_state := case when v_trial_ends_at is not null and v_trial_ends_at > now()
                    then 'trial' else 'none' end;
  else
    v_state := case
      when v_status = 'canceled' then 'canceled'
      when v_status = 'unpaid' then 'unpaid'
      /* v765: a renewal the owner has asked to stop reads 'canceling' from the moment they ask,
         not from the moment the provider is told. The intent is what the tenant experiences. */
      when v_subscription.renewal_cancel_requested_at is not null then 'canceling'
      when v_cancel_at_period_end then 'canceling'
      when v_payment_status = 'failed' then 'past_due'
      when v_status = 'trialing' then 'trial'
      when v_status = 'active' then 'active'
      else 'none' end;
  end if;

  /* Resume is offered right up to the moment the reconciler transmits the cancel, which is
     inside the last 48 hours of the period. Saying the date is the whole point of ruling 4. */
  if v_subscription.renewal_cancel_requested_at is not null
     and v_subscription.current_period_end is not null then
    v_renewal_cancel_final_after := v_subscription.current_period_end - interval '48 hours';
  end if;

  if v_subscription.scheduled_cadence is not null
     or v_subscription.scheduled_effective_at is not null then
    v_scheduled_change := jsonb_build_object(
      'kind','cadence',
      'cadence', v_subscription.scheduled_cadence,
      'plan_label', case v_subscription.scheduled_cadence
                      when 'annual' then 'Annual'
                      when 'monthly' then 'Monthly' else null end,
      'plan_id', v_subscription.scheduled_plan_id,
      'effective_at', v_subscription.scheduled_effective_at,
      'amount_cents', v_subscription.scheduled_amount_cents
    );
  end if;

  select jsonb_build_object(
           'kind', customer.payment_method_kind,
           'brand', customer.payment_method_brand,
           'last4', customer.payment_method_last4,
           'updated_at', customer.payment_method_updated_at
         )
    into v_payment_method
    from public.billing_provider_customers customer
   where customer.business_id = p_business
     and customer.payment_method_kind is not null;

  return v_payload || jsonb_build_object(
    'payment_method', v_payment_method,
    'summary', jsonb_build_object(
      'plan_label', v_plan_label,
      'capacity', v_capacity,
      'branches_total', v_branches_total,
      'branches_included', v_included,
      'branches_billable', v_billable,
      'branches_stopping', v_stopping,
      'branches_lapsed', v_lapsed,
      'branches_unsubscribed', v_unsubscribed,
      'unit_amount_cents', v_unit_amount_cents,
      'units', v_units,
      'total_cents', v_total,
      'renews_at', coalesce(v_payload->>'next_payment_at', v_payload->>'current_period_end'),
      'state', v_state,
      'trial_ends_at', v_trial_ends_at,
      'cancel_at_period_end', v_cancel_at_period_end,
      /* v765 */
      'renewal_cancel_requested_at', v_subscription.renewal_cancel_requested_at,
      'renewal_cancel_sent_at', v_subscription.renewal_cancel_sent_at,
      'renewal_cancel_final_after', v_renewal_cancel_final_after,
      'renewal_cancel_is_final', v_subscription.renewal_cancel_sent_at is not null,
      'scheduled_change', v_scheduled_change
    )
  );
end
$fn$;

/* Restated from the live proacl of get_business_billing_v758:
   {postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}. */
revoke all on function public.get_business_billing_v758(uuid) from public, anon;
grant execute on function public.get_business_billing_v758(uuid) to authenticated, service_role;

-- =============================================================================================
-- 12 · Legacy truth, one tenant. Cafe2U's Razorpay subscription sub_TY2TBGS2P1WeKX was really
--      cancelled at cycle end by two earlier billing commands, and Razorpay cannot undo that.
--      The page must say "renewal cancelled, access until the period end", not offer a Resume
--      that would fail. Recorded as already SENT, which is what it is.
-- =============================================================================================
do $v765_cafe2u$
declare
  v_business constant uuid := 'ded721a7-6b3c-426f-8842-6ecf56725e01';
  v_now timestamptz := now();
  v_subscription public.subscriptions%rowtype;
begin
  select * into v_subscription from public.subscriptions where business_id = v_business;
  if not found then
    raise notice 'v765: Cafe2U is not present in this database; legacy backfill skipped';
    return;
  end if;
  if v_subscription.renewal_cancel_sent_at is not null then
    raise notice 'v765: Cafe2U already carries a sent renewal cancel; left alone';
    return;
  end if;

  update public.subscriptions
     set renewal_cancel_requested_at = coalesce(renewal_cancel_requested_at, v_now),
         renewal_cancel_sent_at = v_now,
         cancel_at_period_end = true,
         updated_at = v_now
   where business_id = v_business
   returning * into v_subscription;

  insert into public.audit_log(business_id,actor,action,entity,entity_id,detail)
  values (
    v_business, null, 'RENEWAL_CANCEL_SENT_V764', 'subscriptions', v_business,
    jsonb_build_object(
      'source','nestly_v765_legacy_backfill',
      'why','two earlier billing commands sent cancel_at_cycle_end=1 to Razorpay for this '
            'subscription before the v764 local-intent design existed; Razorpay cannot undo it',
      'provider_subscription_id', v_subscription.provider_subscription_id,
      'current_period_end', v_subscription.current_period_end,
      'renewal_cancel_sent_at', v_now
    )
  );
  raise notice 'v765: Cafe2U renewal cancel recorded as sent (sub %)',
    v_subscription.provider_subscription_id;
end
$v765_cafe2u$;

commit;
