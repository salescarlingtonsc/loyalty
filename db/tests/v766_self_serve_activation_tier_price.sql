-- EXECUTED acceptance fixture for nestly_v766
-- (db/migrations/20261002_nestly_v766_self_serve_activation_tier_price.sql).
--
-- Run: LC_ALL=C node scripts/db-tests/run.mjs --filter=v766 --migrated-only
--
-- WHY THIS EXISTS. Observed live 2026-09-05: "Cafe Only" paid 118,800 SGD cents for the annual
-- up-to-10,000 tier; the webhook processed, subscriptions went active/paid, the first-paid
-- trigger fired — and the onboarding stayed payment_pending because the v763 predicate priced
-- the invoice with the retired v124 formula (226,800 for 10,000 customers). v763's own fixture
-- used a 1,000-customer capacity, the one point where the two formulas agree, so it passed.
--
-- This fixture deliberately uses a capacity where the two formulas DISAGREE, and asserts that
-- they disagree, so it can never pass for the v763 reason again.
--
-- ASSERTIONS:
--   F0  the retired v124 formula and the tier disagree for the fixture capacity (non-vacuity).
--   F1  the real trigger path activates a tenant paid at the TIER amount for a capacity above
--       1,000: onboarding 'active', activation_invoice_id set, workspace 'approved', and the
--       SELF_SERVICE_PAYMENT_CONFIRMED audit row names the tier amount.
--   F2  a tenant paid at the WRONG amount stays 'payment_pending' AND an audit row
--       SELF_SERVICE_ACTIVATION_SKIPPED records reason paid_evidence_does_not_match_tier_terms
--       with the expected amount — the refusal is no longer silent.
--   F3  the sweep heals a stranded tenant: once F2's terms are corrected to a correctly-priced
--       invoice, app.sweep_stranded_self_serve_activations_v766 activates it and writes
--       SELF_SERVE_ACTIVATED_BY_SWEEP_V766; a second run activates nothing.
--   F4  the sweep is service_role only (authenticated → 42501), and the cron job is scheduled.
begin;

do $v766_test$
declare
  v_now timestamptz := date_trunc('second', now());
  v_tier public.billing_capacity_tier_catalog_v664%rowtype;
  v_catalog uuid;
  v_catalog_row public.billing_plan_catalog_v124%rowtype;
  v_bundle uuid;
  v_sector text;
  v_capacity integer := 10000;
  v_amount integer;
  v_wrong_amount integer;
  v_v130_total integer;

  v_a uuid; v_b uuid;
  v_owner_a uuid := gen_random_uuid();
  v_owner_b uuid := gen_random_uuid();
  v_staff_a uuid; v_staff_b uuid;
  v_branch_a uuid; v_branch_b uuid;

  v_onboarding public.self_serve_business_onboarding_v130%rowtype;
  v_control public.business_workspace_controls_v94%rowtype;
  v_result jsonb;
  v_detail jsonb;
begin
  perform set_config('request.jwt.claims','',true);

  -- A published annual tier covering 10,000 customers, with a plan id. Stand one up if the
  -- harness catalogue has none (production has: plan_TXsSez20bSui76 @ 118800 in test mode).
  v_tier := app.billing_tier_for_capacity_v664('annual', v_capacity);
  if v_tier.capacity_ceiling is null then
    insert into public.billing_capacity_tier_catalog_v664(
      currency,cadence,cadence_months,provider,capacity_ceiling,amount_cents,
      provider_base_price_id,tax_behavior,sales_assisted_above,active,effective_from
    ) values ('SGD','annual',12,'razorpay',v_capacity,118800,'plan_v766tier',
      'exclusive',false,true,v_now - interval '30 days');
    v_tier := app.billing_tier_for_capacity_v664('annual', v_capacity);
  end if;
  if v_tier.provider_base_price_id is null then
    update public.billing_capacity_tier_catalog_v664
       set provider_base_price_id='plan_v766tier'
     where currency=v_tier.currency and cadence=v_tier.cadence
       and capacity_ceiling=v_tier.capacity_ceiling
       and effective_from=v_tier.effective_from;
    v_tier := app.billing_tier_for_capacity_v664('annual', v_capacity);
  end if;
  if v_tier.provider_base_price_id is null or v_tier.amount_cents is null then
    raise exception 'v766 fixture: could not stand up an annual tier for % customers', v_capacity;
  end if;
  v_amount := v_tier.amount_cents;
  v_wrong_amount := v_amount + 12000;

  select id, sector_key into v_bundle, v_sector
    from public.sector_bundle_versions
   where status = 'published' and 'loyalty' = any(modules)
   order by created_at limit 1;
  if v_bundle is null then
    raise exception 'v766 fixture: no published Loyalty-capable sector bundle in the harness schema';
  end if;

  -- The v124 catalogue row the onboarding still points at (its shape is what v763 priced from).
  insert into public.billing_plan_catalog_v124(
    currency, cadence, cadence_months, provider, provider_base_price_id,
    provider_capacity_price_id, base_amount_cents, included_customer_capacity,
    capacity_block_size, capacity_block_amount_cents, compare_at_monthly_cents,
    tax_behavior, active, effective_from
  ) values (
    'SGD','annual',12,'razorpay',null,null,118800,1000,1000,12000,16800,
    'exclusive',true, v_now - interval '30 days'
  ) returning id into v_catalog;

  -- ===========================================================================================
  -- F0 — non-vacuity: for this capacity the retired formula and the tier disagree.
  -- ===========================================================================================
  select * into v_catalog_row from public.billing_plan_catalog_v124 where id=v_catalog;
  v_v130_total := app.self_serve_plan_total_v130(v_catalog_row, v_capacity);
  if v_v130_total = v_amount then
    raise exception
      'F0: the v124 formula (%) equals the tier amount (%) for % customers — pick a capacity where they differ',
      v_v130_total, v_amount, v_capacity;
  end if;

  -- -------------------------------------------------------------------------------------------
  -- Fixture · two self-serve tenants; A is paid at the tier amount, B at the wrong amount.
  -- -------------------------------------------------------------------------------------------
  insert into public.businesses(name,slug,industry,enabled_modules) values
    ('V766 tier priced','v766-a-'||substr(gen_random_uuid()::text,1,8),'test',array['dashboard']),
    ('V766 wrong amount','v766-b-'||substr(gen_random_uuid()::text,1,8),'test',array['dashboard']);
  select id into v_a from public.businesses where name='V766 tier priced';
  select id into v_b from public.businesses where name='V766 wrong amount';

  insert into auth.users(
    instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at
  ) values
    ('00000000-0000-0000-0000-000000000000',v_owner_a,'authenticated','authenticated',
     'zz-v766-a-'||substr(v_owner_a::text,1,8)||'@example.test','',v_now,v_now,v_now),
    ('00000000-0000-0000-0000-000000000000',v_owner_b,'authenticated','authenticated',
     'zz-v766-b-'||substr(v_owner_b::text,1,8)||'@example.test','',v_now,v_now,v_now);

  insert into public.staff(business_id,user_id,role,active)
  values (v_a,v_owner_a,'owner',true) returning id into v_staff_a;
  insert into public.staff(business_id,user_id,role,active)
  values (v_b,v_owner_b,'owner',true) returning id into v_staff_b;

  select id into v_branch_a from public.branches where business_id=v_a order by created_at limit 1;
  if v_branch_a is null then
    insert into public.branches(business_id,name,is_default,active)
    values (v_a,'V766 A main',true,true) returning id into v_branch_a;
  end if;
  select id into v_branch_b from public.branches where business_id=v_b order by created_at limit 1;
  if v_branch_b is null then
    insert into public.branches(business_id,name,is_default,active)
    values (v_b,'V766 B main',true,true) returning id into v_branch_b;
  end if;

  insert into public.business_workspace_controls_v94(business_id,approval_status)
  values (v_a,'pending'),(v_b,'pending')
  on conflict (business_id) do update set approval_status='pending', decided_at=null,
    decided_by=null, decision_reason=null;

  insert into public.self_serve_business_onboarding_v130(
    business_id, owner_user_id, owner_staff_id, default_branch_id, bundle_version_id,
    setup_idempotency_key, request_hash, owner_name, owner_email, business_name, business_slug,
    sector_key, selected_cadence, selected_customer_capacity, billing_catalog_id_v124,
    legal_accepted_at, status
  )
  select b.business_id, b.owner_user_id, b.owner_staff_id, b.branch_id, v_bundle,
         gen_random_uuid(), repeat('6',64), 'V766 Owner', b.email, b.name, b.slug,
         v_sector, 'annual', v_capacity, v_catalog, v_now - interval '1 hour', 'payment_pending'
    from (values
      (v_a, v_owner_a, v_staff_a, v_branch_a, 'zz-v766-a@example.test',
       'V766 tier priced', (select slug from public.businesses where id=v_a)),
      (v_b, v_owner_b, v_staff_b, v_branch_b, 'zz-v766-b@example.test',
       'V766 wrong amount', (select slug from public.businesses where id=v_b))
    ) as b(business_id, owner_user_id, owner_staff_id, branch_id, email, name, slug);

  -- Both carry the tier's plan id and capacity on their terms — exactly what production had.
  insert into public.billing_subscription_terms_v124(
    business_id, provider_subscription_id, pricing_model, cadence, customer_capacity,
    capacity_blocks, provider_base_price_id, provider_capacity_item_id,
    provider_capacity_price_id, provider_event_created_at, last_event_id
  ) values
    (v_a,'sub_v766_a','v124_customer_capacity','annual',v_tier.capacity_ceiling,
     v_tier.capacity_ceiling/1000, v_tier.provider_base_price_id, null, null, v_now,'evt_v766_a'),
    (v_b,'sub_v766_b','v124_customer_capacity','annual',v_tier.capacity_ceiling,
     v_tier.capacity_ceiling/1000, v_tier.provider_base_price_id, null, null, v_now,'evt_v766_b');

  -- Mirroring the paid invoice is what fires the v144 trigger (v144/v756 evidence recording).
  insert into public.billing_provider_invoices(
    business_id,provider_customer_id,provider_subscription_id,provider_invoice_id,currency,status,
    paid_normalized,subtotal_ex_tax_cents,tax_cents,total_cents,amount_due_cents,amount_paid_cents,
    amount_remaining_cents,period_start,period_end,paid_at,livemode,provider_event_created_at,
    provider_event_rank,last_event_id
  ) values
    (v_a,'cust_v766_a','sub_v766_a','inv_v766_a','SGD','paid',
     true,v_amount,0,v_amount,v_amount,v_amount,0,v_now,v_now+interval '365 days',v_now,false,
     v_now,10,'evt_v766_a'),
    (v_b,'cust_v766_b','sub_v766_b','inv_v766_b','SGD','paid',
     true,v_wrong_amount,0,v_wrong_amount,v_wrong_amount,v_wrong_amount,0,v_now,
     v_now+interval '365 days',v_now,false,v_now,10,'evt_v766_b');

  -- ===========================================================================================
  -- F1 — the trigger path activates the tier-priced tenant above 1,000 customers.
  -- ===========================================================================================
  if not exists (
    select 1 from public.billing_first_paid_evidence_v144 evidence
     where evidence.business_id=v_a and evidence.first_paid_invoice_id='inv_v766_a'
  ) then
    raise exception 'v766 fixture: mirroring the paid invoice did not record first-paid evidence for v_a';
  end if;
  select * into v_onboarding from public.self_serve_business_onboarding_v130 where business_id=v_a;
  if v_onboarding.status <> 'active' then
    raise exception 'F1: onboarding status is % instead of active (the v763 defect)', v_onboarding.status;
  end if;
  if v_onboarding.activation_invoice_id is distinct from 'inv_v766_a' or v_onboarding.activated_at is null then
    raise exception 'F1: activation invoice/at not recorded';
  end if;
  select * into v_control from public.business_workspace_controls_v94 where business_id=v_a;
  if v_control.approval_status <> 'approved' then
    raise exception 'F1: workspace approval_status is % instead of approved', v_control.approval_status;
  end if;
  select detail into v_detail from public.audit_log
   where business_id=v_a and action='SELF_SERVICE_PAYMENT_CONFIRMED' order by created_at desc limit 1;
  if v_detail is null or (v_detail->>'tier_amount_cents')::integer <> v_amount then
    raise exception 'F1: SELF_SERVICE_PAYMENT_CONFIRMED does not name the tier amount (%)', v_detail;
  end if;
  if exists (select 1 from public.audit_log where business_id=v_a and action='SELF_SERVICE_ACTIVATION_SKIPPED') then
    raise exception 'F1: an activated tenant carries a SKIPPED audit row';
  end if;

  -- ===========================================================================================
  -- F2 — the wrong amount stays pending, and says so.
  -- ===========================================================================================
  select * into v_onboarding from public.self_serve_business_onboarding_v130 where business_id=v_b;
  if v_onboarding.status <> 'payment_pending' then
    raise exception 'F2: a wrongly-priced invoice activated the workspace (status %)', v_onboarding.status;
  end if;
  select detail into v_detail from public.audit_log
   where business_id=v_b and action='SELF_SERVICE_ACTIVATION_SKIPPED' order by created_at desc limit 1;
  if v_detail is null then
    raise exception 'F2: the refused activation left no SELF_SERVICE_ACTIVATION_SKIPPED audit row (silent again)';
  end if;
  if v_detail->>'reason' <> 'paid_evidence_does_not_match_tier_terms' then
    raise exception 'F2: skip reason is % instead of paid_evidence_does_not_match_tier_terms', v_detail->>'reason';
  end if;
  if (v_detail->>'expected_amount_cents')::integer <> v_amount
     or v_detail->>'provider_invoice_id' <> 'inv_v766_b' then
    raise exception 'F2: the skip row does not name the expected amount and invoice (%)', v_detail;
  end if;

  -- ===========================================================================================
  -- F3 — the sweep heals a stranded tenant once its invoice is right.
  -- The evidence row is immutable, so production cannot re-fire the trigger; the sweep is the
  -- only self-healing path. Simulate the provider correcting the invoice (a re-mirrored
  -- amount) and the subscription being paid, then run the sweep.
  -- ===========================================================================================
  update public.billing_provider_invoices
     set subtotal_ex_tax_cents=v_amount,total_cents=v_amount,amount_due_cents=v_amount,
         amount_paid_cents=v_amount
   where business_id=v_b and provider_invoice_id='inv_v766_b';
  insert into public.subscriptions(business_id,status,currency,base_price_cents,included_seats,
    per_seat_price_cents,billing_provider,payment_status)
  values (v_b,'active','SGD',v_amount,1,0,'razorpay','paid')
  on conflict (business_id) do update set payment_status='paid', status='active';

  v_result := app.sweep_stranded_self_serve_activations_v766(50);
  if coalesce((v_result->>'activated')::integer,0) < 1 then
    raise exception 'F3: the sweep activated nothing (%)', v_result;
  end if;
  select * into v_onboarding from public.self_serve_business_onboarding_v130 where business_id=v_b;
  if v_onboarding.status <> 'active' or v_onboarding.activation_invoice_id <> 'inv_v766_b' then
    raise exception 'F3: the sweep did not open the stranded workspace (status %)', v_onboarding.status;
  end if;
  if not exists (select 1 from public.audit_log where business_id=v_b and action='SELF_SERVE_ACTIVATED_BY_SWEEP_V766') then
    raise exception 'F3: no SELF_SERVE_ACTIVATED_BY_SWEEP_V766 audit row';
  end if;
  v_result := app.sweep_stranded_self_serve_activations_v766(50);
  if exists (
    select 1 from jsonb_array_elements(coalesce(v_result->'skipped_reasons','[]'::jsonb)) r
     where (r->>'business_id')::uuid in (v_a, v_b)
  ) or (select count(*) from public.audit_log where business_id=v_b and action='SELF_SERVE_ACTIVATED_BY_SWEEP_V766') <> 1 then
    raise exception 'F3: the sweep is not idempotent (%)', v_result;
  end if;

  -- ===========================================================================================
  -- F4 — the sweep is service_role only, and it is scheduled.
  -- ===========================================================================================
  begin
    set local role authenticated;
    perform app.sweep_stranded_self_serve_activations_v766(1);
    reset role;
    raise exception 'F4: a non-service role executed the sweep';
  exception
    when insufficient_privilege then
      reset role;
    when others then
      reset role;
      if sqlstate <> '42501' then raise; end if;
  end;
  if not exists (
    select 1 from cron.job where jobname='nestly-v766-self-serve-activation-sweep' and active
  ) then
    raise exception 'F4: cron job nestly-v766-self-serve-activation-sweep is not scheduled';
  end if;

  raise notice 'v766 corpus: F0-F4 passed';
end
$v766_test$;

rollback;
