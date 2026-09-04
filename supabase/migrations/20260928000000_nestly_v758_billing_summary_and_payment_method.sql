-- nestly_v758 — the billing page answers four questions without a click (2026-09-04).
--
-- OWNER DIRECTIVE (2026-09-04): "just show me what I subscribed to, how many branches, how much
-- in total, and the renew date." Plus: show the last 4 digits of the card that will be charged.
--
-- The Settings -> Billing page currently computes its own totals in the browser from
-- get_business_billing_v125's raw parts (terms, capacity_tiers, billable_branch_count) and reads
-- `billing.payment_method.brand` / `.last4` — keys NOTHING has ever written. So the card line has
-- always been blank, and the money on screen is arithmetic the client invented. Both are fixed
-- here, in the database, so the page renders a server-computed answer instead of deriving one.
--
-- WHAT THIS MIGRATION DOES
--   1. public.billing_provider_customers gains five nullable payment-method columns. They are
--      DISPLAY truth, never payment truth: no charge, entitlement or reconciliation reads them.
--      `payment_method_last4` is checked to exactly four digits, so a PAN or an expiry can never
--      be parked there by a careless writer. Nothing else about a card is stored — no token, no
--      expiry, no holder name.
--   2. public.apply_razorpay_billing_event_v755 learns to record the card from the event it
--      already has. Razorpay's `subscription.charged` payload carries
--      payload.payment.entity.method='card' and (usually) payment.entity.card.{last4,network}.
--      The applier is PATCHED IN PLACE by extract-and-diff (the v174/v664/v755 idiom): the live
--      body is read with pg_get_functiondef, one asserted-unique needle is replaced, and the
--      result is executed. A body that has drifted fails this migration instead of being
--      silently retyped from an out-of-date copy — and the webhook keeps calling the same name.
--      When the payload has no card block the columns are left ALONE (not nulled): the edge
--      reconciler backfills them from GET /v1/payments/:id?expand[]=card.
--   3. public.set_billing_payment_method_v758 — service_role only, for that backfill. Validates
--      last4 against '^[0-9]{4}$' and the kind against card|paynow|other, and refuses a business
--      that has no provider customer row.
--   4. public.get_business_billing_v758 — the owner-facing read. It DELEGATES to
--      get_business_billing_v125 (so the tenant guard, the GST assertion and every existing key
--      are inherited unchanged, not re-implemented) and adds exactly two keys:
--        `payment_method` — {kind,brand,last4,updated_at} or null.
--        `summary`       — the four answers, computed here from the same rows the browser was
--                          adding up: units = 1 included + every branch in pending_payment or
--                          active; total = the capacity tier's amount x units.
--      Grants are restated verbatim from the live proacl of v125 (postgres, service_role,
--      authenticated) — no grant v125 does not have.
--
-- NOT DONE HERE, deliberately: get_business_billing_v125 is not altered and not deprecated. It
-- is the delegate, and every existing caller keeps working.
--
-- Rollback suite: db/tests/v758_billing_summary_and_payment_method.sql
-- Executed acceptance: db/tests/executed/v758_corpus_billing_summary.sql

begin;

-- =============================================================================================
-- 1 · The card the tenant will be charged on, for display only.
-- =============================================================================================
alter table public.billing_provider_customers
  add column if not exists payment_method_kind text,
  add column if not exists payment_method_brand text,
  add column if not exists payment_method_last4 text,
  add column if not exists payment_method_updated_at timestamptz,
  add column if not exists payment_method_source_payment_id text;

alter table public.billing_provider_customers
  drop constraint if exists billing_provider_customers_pm_kind_ck;
alter table public.billing_provider_customers
  add constraint billing_provider_customers_pm_kind_ck
  check (payment_method_kind is null
         or payment_method_kind in ('card','paynow','other'));

/* Exactly four digits. The point of the check is not tidiness: it is that a full card number can
   never be written into a column the owner-facing RPC returns. */
alter table public.billing_provider_customers
  drop constraint if exists billing_provider_customers_pm_last4_ck;
alter table public.billing_provider_customers
  add constraint billing_provider_customers_pm_last4_ck
  check (payment_method_last4 is null or payment_method_last4 ~ '^[0-9]{4}$');

comment on column public.billing_provider_customers.payment_method_last4 is
  'Display-only last four digits of the card Razorpay charges. Never payment truth.';

-- =============================================================================================
-- 2 · The charged event records the card it was charged on (extract-and-diff, name preserved).
-- =============================================================================================
do $v758_applier_card$
declare
  v_definition text := pg_get_functiondef(
    'public.apply_razorpay_billing_event_v755(text)'::regprocedure
  );
  v_needle constant text := E'      v_paid := true;\n    end if;';
  v_replacement constant text :=
       E'      if lower(coalesce(v_payment->>''method'','''')) = ''card''\n'
    || E'         and coalesce(v_payment->''card''->>''last4'','''') ~ ''^[0-9]{4}$'' then\n'
    || E'        update public.billing_provider_customers\n'
    || E'           set payment_method_kind=''card'',\n'
    || E'               payment_method_brand=nullif(v_payment->''card''->>''network'',''''),\n'
    || E'               payment_method_last4=v_payment->''card''->>''last4'',\n'
    || E'               payment_method_updated_at=v_event.event_created_at,\n'
    || E'               payment_method_source_payment_id=v_payment->>''id'',\n'
    || E'               updated_at=now()\n'
    || E'         where business_id=v_business;\n'
    || E'      end if;\n'
    || E'      v_paid := true;\n    end if;';
  v_occurrences integer;
begin
  v_occurrences := (length(v_definition) - length(replace(v_definition, v_needle, '')))
                   / length(v_needle);
  if v_occurrences <> 1 then
    raise exception
      'v758 expected exactly one paid-truth marker in apply_razorpay_billing_event_v755, found %',
      v_occurrences using errcode = '55000';
  end if;
  if position('payment_method_last4' in v_definition) > 0 then
    raise exception 'v758 applier patch has already been applied' using errcode = '55000';
  end if;
  execute replace(v_definition, v_needle, v_replacement);
end
$v758_applier_card$;

revoke all on function public.apply_razorpay_billing_event_v755(text)
  from public, anon, authenticated;
grant execute on function public.apply_razorpay_billing_event_v755(text) to service_role;

-- =============================================================================================
-- 3 · The reconcile backfill's writer. Service role only; never a payment decision.
-- =============================================================================================
create or replace function public.set_billing_payment_method_v758(
  p_business uuid,
  p_payment_id text,
  p_kind text,
  p_brand text,
  p_last4 text
) returns jsonb
language plpgsql
volatile
security definer
set search_path = pg_catalog, public, app, pg_temp
as $fn$
declare
  v_kind text := lower(nullif(btrim(coalesce(p_kind,'')),''));
  v_last4 text := nullif(btrim(coalesce(p_last4,'')),'');
  v_brand text := nullif(btrim(coalesce(p_brand,'')),'');
  v_updated integer;
begin
  if p_business is null then
    raise exception 'a business id is required' using errcode = '22023';
  end if;
  if v_kind is null or v_kind not in ('card','paynow','other') then
    raise exception 'payment method kind must be card, paynow or other' using errcode = '22023';
  end if;
  if v_kind = 'card' then
    if v_last4 is null or v_last4 !~ '^[0-9]{4}$' then
      raise exception 'a card payment method needs exactly four digits' using errcode = '22023';
    end if;
  elsif v_last4 is not null and v_last4 !~ '^[0-9]{4}$' then
    raise exception 'a card payment method needs exactly four digits' using errcode = '22023';
  end if;

  update public.billing_provider_customers
     set payment_method_kind = v_kind,
         payment_method_brand = v_brand,
         payment_method_last4 = v_last4,
         payment_method_updated_at = now(),
         payment_method_source_payment_id = nullif(btrim(coalesce(p_payment_id,'')),''),
         updated_at = now()
   where business_id = p_business;
  get diagnostics v_updated = row_count;
  if v_updated = 0 then
    raise exception 'this business has no billing provider customer row' using errcode = '22023';
  end if;

  return jsonb_build_object(
    'status','ok','business_id',p_business,'kind',v_kind,'brand',v_brand,'last4',v_last4
  );
end
$fn$;

revoke all on function public.set_billing_payment_method_v758(uuid,text,text,text,text)
  from public, anon, authenticated;
grant execute on function public.set_billing_payment_method_v758(uuid,text,text,text,text)
  to service_role;

-- =============================================================================================
-- 4 · The owner-facing read: v125 plus the card and the four answers.
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
begin
  if jsonb_typeof(v_terms) = 'object' then
    v_cadence := nullif(v_terms->>'cadence','');
    v_capacity := nullif(v_terms->>'customer_capacity','')::integer;
  end if;
  v_plan_label := case v_cadence when 'annual' then 'Annual'
                                 when 'monthly' then 'Monthly' else null end;

  select s.trial_ends_at into v_trial_ends_at
    from public.subscriptions s where s.business_id = p_business;

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
      when v_cancel_at_period_end then 'canceling'
      when v_payment_status = 'failed' then 'past_due'
      when v_status = 'trialing' then 'trial'
      when v_status = 'active' then 'active'
      else 'none' end;
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
      'cancel_at_period_end', v_cancel_at_period_end
    )
  );
end
$fn$;

/* Restated from the live proacl of get_business_billing_v125:
   {postgres=X/postgres,service_role=X/postgres,authenticated=X/postgres}. */
revoke all on function public.get_business_billing_v758(uuid) from public, anon;
grant execute on function public.get_business_billing_v758(uuid) to authenticated, service_role;

commit;
