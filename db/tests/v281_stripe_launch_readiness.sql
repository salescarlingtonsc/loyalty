-- Rollback-only acceptance for V281 — Stripe launch readiness.
--
-- Runs against the REAL production schema inside ONE transaction and ends in ROLLBACK: nothing it
-- writes survives. Sections 4 and 5 are read-only assertions about state the migration COMMITTED
-- (the bar bundle publication and the duplicate-reward removal are real changes, not rehearsals);
-- sections 1-3 build synthetic fixtures and undo them.
--
-- What this proves, in order:
--   1  THE DUNNING DEFECT, REPRODUCED AND FIXED, on a synthetic charge_automatically invoice with
--      due_at NULL — the exact shape Stripe produces for every Checkout subscription. Before
--      V281 the anchor was NULL and the invoice could not enter the overdue set; after it, the
--      anchor is finalized_at and a 20-day-old unpaid invoice is 20 days overdue, i.e. past the
--      day-14 pause. A send_invoice invoice with a real due_at still anchors on due_at, so no
--      existing tenant's clock moves. Both null still yields null, so the sweep cannot invent an
--      overdue state out of missing evidence.
--   2  THE OUT-OF-ORDER WEBHOOK. A paid invoice is stored BEFORE the subscription terms exist
--      (the interleaving Stripe is free to deliver). The invoice-side capture correctly writes
--      nothing. Inserting the terms row then performs the capture. Three fixtures: 2a a tenant
--      with no self-service onboarding row (the documented NULL branch -> money-back window),
--      2b a real self-service tenant on the current legal version (-> first-paid evidence, which
--      is what app.activate_self_serve_paid_v130 hangs off, and which is shown to open the
--      workspace), 2c an ATTRIBUTION control with the V281 trigger disabled.
--
--      CORRECTION (2026-08-12, found by running this suite against production after V281 was
--      applied). As originally written this section could never pass, and would not have
--      attributed the behaviour it claimed. Both faults are in the SCAFFOLDING, not in V281:
--        C1  The fixture created no public.self_serve_business_onboarding_v130 row, so
--            v_legal_version is NULL, `null >= '2026-08-03'` is NULL, and the branch copied
--            verbatim from app.capture_money_back_window_v124 takes its documented ELSE path:
--            billing_money_back_windows_v124, NOT billing_first_paid_evidence_v144. The original
--            assertion on billing_first_paid_evidence_v144 was therefore unsatisfiable. 2a now
--            asserts the true documented behaviour and 2b builds the onboarding row (auth.users
--            + branch + staff + a loyalty-capable published bundle + an active SGD annual
--            catalogue row) so the evidence branch is genuinely exercised.
--        C2  The suite could not tell V281's new trigger from the PRE-EXISTING
--            public.billing_subscription_terms_money_backfill_v124, which is also an AFTER INSERT
--            OR UPDATE OF provider_subscription_id trigger on the same table and which already
--            carries BOTH branches. 2c runs the same fixture with
--            billing_terms_first_paid_replay_v281 disabled. MEASURED RESULT against production:
--            the evidence is still captured (evidence=1) and the workspace still activates, i.e.
--            DEFECT 2 WAS ALREADY CLOSED by the incumbent v124 backfill and V281's trigger is
--            redundant rather than load-bearing. It is harmless (same branch, idempotent
--            on-conflict shape) and it additionally fires on UPDATE OF provider_event_created_at,
--            which the incumbent does not. This is recorded, not asserted away.
--        C3  The 2b/2c fixtures are pinned to sector 'other'. Section 4 asserts GLOBALLY over
--            every tenant assigned to the bar v2 bundle, so a fixture that borrowed the bar
--            bundle contaminated it (the fixture business is created with a deliberately narrow
--            enabled_modules and would be reported as "a bar tenant on v2 without packages").
--
--      HARNESS NOTE. Executed against production through the Supabase MCP execute_sql, which
--      takes one statement batch, so the six sections were run as nested blocks of a single DO
--      with an accumulating v_log and a terminal
--      `raise exception 'V281_RESULT ALL PASS -- %', v_log` in place of the ROLLBACK below. The
--      raise rolls the whole batch back exactly as `rollback;` does here. The psql form is kept
--      canonical.
--   3  THE ACTIVATION GATE. app.activate_self_serve_paid_v130 now carries the same
--      app.c45_owner_loyalty_write predicate V277 put on the two super-admin paths, so a preset
--      that cannot be written skips instead of raising out of the invoice.paid transaction. The
--      impersonation, the seed and the audit row it already had are asserted intact.
--   4  BAR GAINED PACKAGES without losing anything: v2 is the published bundle, v1 is retired
--      with a retired_at, v2 = v1 + packages exactly, and no assignment still points at v1.
--   5  THE DUPLICATE REWARD IS GONE, its surviving twin is untouched, no customer history
--      referenced it, and the snapshot rewrite it caused is evidenced in audit_log.
--   6  THE REDRIVE is bounded and refuses an out-of-range limit.

begin;

create or replace function pg_temp.v281_anchor(p_due timestamptz, p_final timestamptz)
returns timestamptz
language plpgsql as $$
declare v_row public.billing_provider_invoices%rowtype;
begin
  v_row.due_at := p_due;
  v_row.finalized_at := p_final;
  return app.billing_due_anchor_v281(v_row);
end
$$;

-- =================================================================================================
-- 1. The dunning anchor.
-- =================================================================================================
do $v281_1$
declare
  v_now constant timestamptz := now();
  v_sweep constant text := pg_get_functiondef('app.run_subscription_lifecycle_v94(date)'::regprocedure);
  v_recon constant text := pg_get_functiondef(
    'app.reconcile_subscription_payment_v94(uuid,text,text,uuid,boolean)'::regprocedure);
begin
  -- The defect: Stripe leaves due_date null for charge_automatically, so the old predicate
  -- `invoice.due_at is not null` excluded every card subscription from the overdue set.
  if pg_temp.v281_anchor(null, v_now - interval '20 days') is null then
    raise exception 'v281.1: a charge_automatically invoice still has no overdue anchor';
  end if;
  if (pg_temp.v281_anchor(null, v_now - interval '20 days') at time zone 'Asia/Singapore')::date
     <> ((v_now - interval '20 days') at time zone 'Asia/Singapore')::date then
    raise exception 'v281.1: the finalization anchor does not resolve to the finalization day';
  end if;

  -- due_at still wins wherever Stripe supplies it: a send_invoice tenant's clock does not move.
  if pg_temp.v281_anchor(v_now - interval '3 days', v_now - interval '20 days')
     <> v_now - interval '3 days' then
    raise exception 'v281.1: the anchor overrode a real Stripe due date';
  end if;

  -- Fail-safe: no evidence at all still means no dunning.
  if pg_temp.v281_anchor(null, null) is not null then
    raise exception 'v281.1: the anchor invented an overdue date from nothing';
  end if;

  -- Both live-path functions must go through the anchor, and neither may retain a raw due_at.
  if position('app.billing_due_anchor_v281(invoice)' in v_sweep) = 0 then
    raise exception 'v281.1: the daily sweep does not use the V281 anchor';
  end if;
  if position('invoice.due_at' in v_sweep) > 0 then
    raise exception 'v281.1: the daily sweep still carries a raw due_at reference';
  end if;
  if position('app.billing_due_anchor_v281(invoice)' in v_recon) = 0 then
    raise exception 'v281.1: the payment reconciler does not use the V281 anchor';
  end if;
  if position('invoice.due_at' in v_recon) > 0 then
    raise exception 'v281.1: the payment reconciler still carries a raw due_at reference';
  end if;

  -- The rest of the sweep is untouched: the day-14 pause and the notice ladder still exist.
  if position('v_day>=14' in v_sweep) = 0
     or position('''workspace_paused''' in v_sweep) = 0 then
    raise exception 'v281.1: the day-14 pause was disturbed';
  end if;
end
$v281_1$;

-- =================================================================================================
-- 2. The out-of-order webhook repair, on synthetic provider rows.
-- =================================================================================================
do $v281_2$
declare
  -- CORRECTION C3: pinned to 'other'. Section 4 asserts globally over every tenant on the bar v2
  -- bundle, so these fixtures must never borrow a bar-sector bundle.
  v_sector constant text := 'other';
  v_bundle uuid;
  v_catalog uuid;
  v_price text;
  v_paid_at constant timestamptz := now() - interval '1 hour';
  v_business uuid;
  v_user uuid;
  v_branch uuid;
  v_staff uuid;
  v_customer text;
  v_subscription text;
  v_invoice text;
  v_event text;
  v_captured integer;
  v_money_back integer;
  v_control integer;
  v_first_paid timestamptz;
begin
  select bundle.id into v_bundle
    from public.sector_bundle_versions bundle
   where bundle.status='published' and bundle.sector_key=v_sector
     and bundle.modules @> array['loyalty']::text[];
  select catalog.id, catalog.provider_base_price_id into v_catalog, v_price
    from public.billing_plan_catalog_v124 catalog
   where catalog.currency='SGD' and catalog.cadence='annual' and catalog.active
   order by catalog.effective_from desc limit 1;
  if v_price is null or v_bundle is null then
    raise exception 'v281.2: no active annual SGD catalogue entry / loyalty bundle for the fixture';
  end if;

  -- ============================================================================================
  -- 2a. No self-service onboarding row. CORRECTION C1: v_legal_version is NULL here, so the
  -- branch copied verbatim from capture_money_back_window_v124 takes its documented ELSE path.
  -- Asserting billing_first_paid_evidence_v144 on this fixture (as this suite originally did)
  -- was unsatisfiable. The money-back window is the correct outcome and is asserted instead.
  -- ============================================================================================
  insert into public.businesses(name, slug, industry, enabled_modules)
  values('V281 Fixture A', 'v281-fixture-a-' || replace(gen_random_uuid()::text, '-', ''),
         'other', array['dashboard','clients']::text[])
  returning id into v_business;

  v_customer := 'cus_v281a_' || replace(gen_random_uuid()::text, '-', '');
  v_subscription := 'sub_v281a_' || replace(gen_random_uuid()::text, '-', '');
  v_invoice := 'in_v281a_' || replace(gen_random_uuid()::text, '-', '');
  v_event := 'evt_v281a_' || replace(gen_random_uuid()::text, '-', '');

  insert into public.billing_provider_customers(
    business_id, provider_customer_id, currency, livemode,
    provider_event_created_at, provider_event_rank, last_event_id
  ) values(v_business, v_customer, 'SGD', false, v_paid_at, 100, v_event);

  -- THE INTERLEAVING STRIPE IS FREE TO DELIVER: the paid invoice lands with no terms row yet.
  insert into public.billing_provider_invoices(
    business_id, provider_customer_id, provider_subscription_id, provider_invoice_id,
    currency, collection_method, status, paid_normalized, subtotal_ex_tax_cents, tax_cents,
    total_cents, amount_due_cents, amount_paid_cents, amount_remaining_cents,
    net_cash_ex_tax_cents, paid_at, finalized_at, livemode,
    provider_event_created_at, provider_event_rank, last_event_id
  ) values(
    v_business, v_customer, v_subscription, v_invoice, 'SGD', 'charge_automatically', 'paid',
    true, 118800, 0, 118800, 118800, 118800, 0, 118800, v_paid_at, v_paid_at, false,
    v_paid_at, 100, v_event
  );

  select count(*)::integer into v_captured
    from public.billing_first_paid_evidence_v144 where business_id=v_business;
  select count(*)::integer into v_money_back
    from public.billing_money_back_windows_v124 where business_id=v_business;
  if v_captured <> 0 or v_money_back <> 0 then
    raise exception 'v281.2a: a capture happened before the subscription terms existed (ev=% mb=%)',
      v_captured, v_money_back;
  end if;

  insert into public.billing_subscription_terms_v124(
    business_id, provider_subscription_id, cadence, customer_capacity, capacity_blocks,
    provider_base_price_id, provider_event_created_at, last_event_id
  ) values(
    v_business, v_subscription, 'annual', 1000, 1, v_price, v_paid_at, v_event
  );

  select count(*)::integer into v_captured
    from public.billing_first_paid_evidence_v144 where business_id=v_business;
  select count(*)::integer into v_money_back
    from public.billing_money_back_windows_v124
   where business_id=v_business and first_paid_invoice_id=v_invoice
     and first_paid_at=v_paid_at;
  if v_money_back <> 1 then
    raise exception 'v281.2a: the terms-side replay did not capture into the money-back window';
  end if;
  if v_captured <> 0 then
    raise exception 'v281.2a: a business with no onboarding row wrote first-paid evidence';
  end if;

  -- ============================================================================================
  -- 2b. CORRECTION C1: the branch that actually matters. A real self-service tenant on the
  -- current legal version, whose billing_first_paid_evidence_v144 row is what
  -- app.activate_self_serve_paid_v130 hangs off. The activation is asserted, not assumed.
  -- ============================================================================================
  v_user := gen_random_uuid();
  insert into auth.users(id) values(v_user);

  insert into public.businesses(name, slug, industry, enabled_modules)
  values('V281 Fixture B', 'v281-fixture-b-' || replace(gen_random_uuid()::text, '-', ''),
         v_sector, array['dashboard','clients']::text[])
  returning id into v_business;

  select branch.id into v_branch from public.branches branch
   where branch.business_id=v_business limit 1;
  if v_branch is null then
    insert into public.branches(business_id, name) values(v_business, 'Main')
    returning id into v_branch;
  end if;
  insert into public.staff(business_id, role, user_id) values(v_business, 'owner', v_user)
  returning id into v_staff;

  insert into public.self_serve_business_onboarding_v130(
    business_id, owner_user_id, owner_staff_id, default_branch_id, bundle_version_id,
    setup_idempotency_key, request_hash, owner_name, owner_email, business_name, business_slug,
    sector_key, selected_cadence, selected_customer_capacity, billing_catalog_id_v124,
    legal_accepted_at
  ) values(
    v_business, v_user, v_staff, v_branch, v_bundle, gen_random_uuid(), repeat('a',64),
    'V281 Owner', 'v281b@example.com', 'V281 Fixture B', 'v281-fixture-b',
    v_sector, 'annual', 1000, v_catalog, now()
  );

  v_customer := 'cus_v281b_' || replace(gen_random_uuid()::text, '-', '');
  v_subscription := 'sub_v281b_' || replace(gen_random_uuid()::text, '-', '');
  v_invoice := 'in_v281b_' || replace(gen_random_uuid()::text, '-', '');
  v_event := 'evt_v281b_' || replace(gen_random_uuid()::text, '-', '');

  insert into public.billing_provider_customers(
    business_id, provider_customer_id, currency, livemode,
    provider_event_created_at, provider_event_rank, last_event_id
  ) values(v_business, v_customer, 'SGD', false, v_paid_at, 100, v_event);
  insert into public.billing_provider_invoices(
    business_id, provider_customer_id, provider_subscription_id, provider_invoice_id,
    currency, collection_method, status, paid_normalized, subtotal_ex_tax_cents, tax_cents,
    total_cents, amount_due_cents, amount_paid_cents, amount_remaining_cents,
    net_cash_ex_tax_cents, paid_at, finalized_at, livemode,
    provider_event_created_at, provider_event_rank, last_event_id
  ) values(
    v_business, v_customer, v_subscription, v_invoice, 'SGD', 'charge_automatically', 'paid',
    true, 118800, 0, 118800, 118800, 118800, 0, 118800, v_paid_at, v_paid_at, false,
    v_paid_at, 100, v_event
  );

  select count(*)::integer into v_captured
    from public.billing_first_paid_evidence_v144 where business_id=v_business;
  if v_captured <> 0 then
    raise exception 'v281.2b: first-paid evidence appeared before the subscription terms existed';
  end if;

  insert into public.billing_subscription_terms_v124(
    business_id, provider_subscription_id, cadence, customer_capacity, capacity_blocks,
    provider_base_price_id, provider_event_created_at, last_event_id
  ) values(
    v_business, v_subscription, 'annual', 1000, 1, v_price, v_paid_at, v_event
  );

  select count(*)::integer into v_captured
    from public.billing_first_paid_evidence_v144
   where business_id=v_business and first_paid_invoice_id=v_invoice
     and first_paid_at=v_paid_at;
  if v_captured <> 1 then
    raise exception 'v281.2b: the terms-side replay did not capture the first paid invoice';
  end if;
  if not exists(
    select 1 from public.self_serve_business_onboarding_v130 onboarding
     where onboarding.business_id=v_business and onboarding.status='active'
       and onboarding.activated_at is not null
  ) then
    raise exception 'v281.2b: the capture did not open the paid workspace';
  end if;

  -- The one write shape ONLY the V281 trigger listens to: the incumbent v124 backfill fires on
  -- UPDATE OF provider_subscription_id, V281 also on provider_event_created_at. The evidence is
  -- immutable (app.guard_first_paid_evidence_v144 raises on any rewrite), so it must be a no-op.
  select evidence.first_paid_at into v_first_paid
    from public.billing_first_paid_evidence_v144 evidence
   where evidence.business_id=v_business;
  update public.billing_subscription_terms_v124
     set provider_event_created_at = v_paid_at + interval '1 minute'
   where business_id = v_business;

  select count(*)::integer into v_captured
    from public.billing_first_paid_evidence_v144
   where business_id=v_business and first_paid_invoice_id=v_invoice
     and first_paid_at=v_first_paid;
  if v_captured <> 1 then
    raise exception 'v281.2b: replaying the capture disturbed the first-paid evidence';
  end if;

  -- ============================================================================================
  -- 2c. CORRECTION C2 — ATTRIBUTION. Repeat 2b with billing_terms_first_paid_replay_v281
  -- disabled. If the capture still happens, the PRE-EXISTING
  -- public.billing_subscription_terms_money_backfill_v124 (app.backfill_money_back_window_v124,
  -- AFTER INSERT OR UPDATE OF provider_subscription_id on the same table, carrying BOTH
  -- branches) was already closing defect 2 and V281's trigger is redundant. Reported, not
  -- asserted away: whichever way it lands, the fact belongs in the release evidence.
  -- MEASURED against production 2026-08-12: evidence=1 with V281 disabled.
  -- ============================================================================================
  alter table public.billing_subscription_terms_v124
    disable trigger billing_terms_first_paid_replay_v281;

  v_user := gen_random_uuid();
  insert into auth.users(id) values(v_user);
  insert into public.businesses(name, slug, industry, enabled_modules)
  values('V281 Fixture C', 'v281-fixture-c-' || replace(gen_random_uuid()::text, '-', ''),
         v_sector, array['dashboard','clients']::text[])
  returning id into v_business;
  select branch.id into v_branch from public.branches branch
   where branch.business_id=v_business limit 1;
  if v_branch is null then
    insert into public.branches(business_id, name) values(v_business, 'Main')
    returning id into v_branch;
  end if;
  insert into public.staff(business_id, role, user_id) values(v_business, 'owner', v_user)
  returning id into v_staff;
  insert into public.self_serve_business_onboarding_v130(
    business_id, owner_user_id, owner_staff_id, default_branch_id, bundle_version_id,
    setup_idempotency_key, request_hash, owner_name, owner_email, business_name, business_slug,
    sector_key, selected_cadence, selected_customer_capacity, billing_catalog_id_v124,
    legal_accepted_at
  ) values(
    v_business, v_user, v_staff, v_branch, v_bundle, gen_random_uuid(), repeat('b',64),
    'V281 Owner', 'v281c@example.com', 'V281 Fixture C', 'v281-fixture-c',
    v_sector, 'annual', 1000, v_catalog, now()
  );

  v_customer := 'cus_v281c_' || replace(gen_random_uuid()::text, '-', '');
  v_subscription := 'sub_v281c_' || replace(gen_random_uuid()::text, '-', '');
  v_invoice := 'in_v281c_' || replace(gen_random_uuid()::text, '-', '');
  v_event := 'evt_v281c_' || replace(gen_random_uuid()::text, '-', '');

  insert into public.billing_provider_customers(
    business_id, provider_customer_id, currency, livemode,
    provider_event_created_at, provider_event_rank, last_event_id
  ) values(v_business, v_customer, 'SGD', false, v_paid_at, 100, v_event);
  insert into public.billing_provider_invoices(
    business_id, provider_customer_id, provider_subscription_id, provider_invoice_id,
    currency, collection_method, status, paid_normalized, subtotal_ex_tax_cents, tax_cents,
    total_cents, amount_due_cents, amount_paid_cents, amount_remaining_cents,
    net_cash_ex_tax_cents, paid_at, finalized_at, livemode,
    provider_event_created_at, provider_event_rank, last_event_id
  ) values(
    v_business, v_customer, v_subscription, v_invoice, 'SGD', 'charge_automatically', 'paid',
    true, 118800, 0, 118800, 118800, 118800, 0, 118800, v_paid_at, v_paid_at, false,
    v_paid_at, 100, v_event
  );
  insert into public.billing_subscription_terms_v124(
    business_id, provider_subscription_id, cadence, customer_capacity, capacity_blocks,
    provider_base_price_id, provider_event_created_at, last_event_id
  ) values(
    v_business, v_subscription, 'annual', 1000, 1, v_price, v_paid_at, v_event
  );

  select count(*)::integer into v_control
    from public.billing_first_paid_evidence_v144
   where business_id=v_business and first_paid_invoice_id=v_invoice;

  alter table public.billing_subscription_terms_v124
    enable trigger billing_terms_first_paid_replay_v281;

  raise notice 'v281.2c ATTRIBUTION: with billing_terms_first_paid_replay_v281 DISABLED, evidence=% (1 => the pre-existing billing_subscription_terms_money_backfill_v124 already closes defect 2 and the V281 trigger is redundant)', v_control;

  raise notice 'v281.2: out-of-order capture verified (rolled back)';
end
$v281_2$;

-- =================================================================================================
-- 3. The activation gate.
-- =================================================================================================
do $v281_3$
declare
  v_source constant text := pg_get_functiondef('app.activate_self_serve_paid_v130()'::regprocedure);
begin
  if position('if app.c45_owner_loyalty_write(new.business_id) then' in v_source) = 0 then
    raise exception 'v281.3: the activation seed is still ungated';
  end if;
  -- The gate must sit around the seed, not replace it, and the V277-shaped impersonation and the
  -- confirmation audit row must both survive.
  if position('insert into public.loyalty_programs(' in v_source) = 0 then
    raise exception 'v281.3: the loyalty preset was lost';
  end if;
  if position('if app.c45_owner_loyalty_write(new.business_id) then' in v_source)
     > position('insert into public.loyalty_programs(' in v_source) then
    raise exception 'v281.3: the gate does not precede the seed it is meant to guard';
  end if;
  if position('request.jwt.claim.sub' in v_source) = 0 then
    raise exception 'v281.3: the owner impersonation was lost';
  end if;
  if position('SELF_SERVICE_PAYMENT_CONFIRMED' in v_source) = 0 then
    raise exception 'v281.3: the activation audit row was lost';
  end if;
  -- The gate is only meaningful if the predicate it names still exists with that signature.
  perform 'app.c45_owner_loyalty_write(uuid)'::regprocedure;
end
$v281_3$;

-- =================================================================================================
-- 4. Bar gained packages (read-only assertion about a committed change).
-- =================================================================================================
do $v281_4$
declare
  v_v1 public.sector_bundle_versions%rowtype;
  v_v2 public.sector_bundle_versions%rowtype;
  v_stranded integer;
begin
  select * into strict v_v1 from public.sector_bundle_versions
   where sector_key='bar' and version=1;
  select * into strict v_v2 from public.sector_bundle_versions
   where sector_key='bar' and version=2;

  if v_v1.status <> 'retired' or v_v1.retired_at is null then
    raise exception 'v281.4: bar v1 is not retired with a retired_at';
  end if;
  if v_v2.status <> 'published' then
    raise exception 'v281.4: bar v2 is not the published bundle';
  end if;
  if not v_v2.modules @> array['packages']::text[] then
    raise exception 'v281.4: bar v2 does not carry packages';
  end if;
  -- A bundle bump must ADD only. Nothing a bar tenant already had may disappear.
  if not v_v2.modules @> v_v1.modules then
    raise exception 'v281.4: bar v2 dropped a module bar v1 carried';
  end if;
  if array_length(v_v2.modules,1) <> array_length(v_v1.modules,1) + 1 then
    raise exception 'v281.4: bar v2 changed more than the packages entitlement';
  end if;

  select count(*)::integer into v_stranded
    from public.business_sector_assignments assignment
   where assignment.bundle_version_id = v_v1.id
     and assignment.override_version_id is null;
  if v_stranded <> 0 then
    raise exception 'v281.4: % tenant(s) are still assigned to the retired bar v1', v_stranded;
  end if;

  if exists(
    select 1 from public.businesses business
    join public.business_sector_assignments assignment on assignment.business_id=business.id
   where assignment.bundle_version_id = v_v2.id
     and not business.enabled_modules @> array['packages']::text[]
  ) then
    raise exception 'v281.4: a bar tenant is on v2 without the packages entitlement';
  end if;
end
$v281_4$;

-- =================================================================================================
-- 5. The retired duplicate reward (read-only assertion about a committed change).
-- =================================================================================================
do $v281_5$
declare
  v_reward constant uuid := '95f12d05-2d00-443c-9844-e7a5d62a2423';
  v_business constant uuid := '8492e8d6-8888-4383-ada0-7e1ed69f0caa';
begin
  if exists(select 1 from public.loyalty_rewards where id=v_reward) then
    raise exception 'v281.5: the duplicate reward is still present';
  end if;
  if exists(select 1 from public.loyalty_reward_versions where reward_id=v_reward) then
    raise exception 'v281.5: version rows of the duplicate reward survived';
  end if;
  -- The point was to remove a duplicate, not a reward: the twin the owner keeps must be intact.
  if not exists(
    select 1 from public.loyalty_rewards
     where id='749c9f59-caa4-48e0-9fc5-b2faca244237'
       and business_id=v_business and active and cost_points=150
  ) then
    raise exception 'v281.5: the surviving twin reward is missing or changed';
  end if;
  -- Removing a member from a published configuration rewrites its snapshot. That must be
  -- evidenced, with both the before and the after hashes, not silent.
  if not exists(
    select 1 from public.audit_log
     where business_id=v_business
       and action='LOYALTY_REWARD_DUPLICATE_REMOVED_V281'
       and detail ? 'config_snapshots_before'
       and detail ? 'config_snapshots_after'
       and (detail->>'reward_id')::uuid = v_reward
  ) then
    raise exception 'v281.5: the removal is not evidenced in audit_log';
  end if;
  -- The immutability guard is back on: this was a scoped suspension, not a removal.
  if not exists(
    select 1 from pg_trigger trigger_row
     where trigger_row.tgrelid='public.loyalty_reward_versions'::regclass
       and trigger_row.tgname='trg_loyalty_reward_versions_immutable'
       and trigger_row.tgenabled <> 'D'
  ) then
    raise exception 'v281.5: the reward version immutability guard is still disabled';
  end if;
end
$v281_5$;

-- =================================================================================================
-- 6. The redrive.
-- =================================================================================================
do $v281_6$
declare
  v_result jsonb;
begin
  v_result := app.v281_redrive_failed_billing_events(1);
  if v_result->>'attempted' is null then
    raise exception 'v281.6: the redrive did not report an attempt count';
  end if;
  begin
    perform app.v281_redrive_failed_billing_events(0);
    raise exception 'v281.6: the redrive accepted an out-of-range limit';
  exception when invalid_parameter_value then null;
  end;
  begin
    perform app.v281_redrive_failed_billing_events(5000);
    raise exception 'v281.6: the redrive accepted an unbounded limit';
  exception when invalid_parameter_value then null;
  end;
  -- It must be unreachable from the browser: it replays provider events as the definer.
  if has_function_privilege('authenticated',
       'app.v281_redrive_failed_billing_events(integer)','execute')
     or has_function_privilege('anon',
       'app.v281_redrive_failed_billing_events(integer)','execute') then
    raise exception 'v281.6: the redrive is callable by a browser role';
  end if;
end
$v281_6$;

do $v281_done$
begin
  raise notice 'v281: all assertions passed (every fixture write is undone by ROLLBACK)';
end
$v281_done$;

rollback;
