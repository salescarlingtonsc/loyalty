-- EXECUTED acceptance fixture for nestly_v763
-- (db/migrations/20260930_nestly_v763_self_serve_activation_by_tier.sql).
--
-- Run: LC_ALL=C node scripts/db-tests/run.mjs --filter=v763_corpus --migrated-only
--
-- WHY THIS EXISTS. Observed live in Razorpay test mode, 2026-09-05: business Cafe2U paid
-- (sub_TY2TBGS2P1WeKX, invoice inv_TY2TCG4HIs73yU, 118800 SGD cents, subscriptions
-- payment_status='paid') and self_serve_business_onboarding_v130.status stayed 'payment_pending',
-- so the workspace never opened. app.activate_self_serve_paid_v130() compared the subscription
-- TERMS against public.billing_plan_catalog_v124, whose provider price ids have been NULL since
-- v755 — prices moved to public.billing_capacity_tier_catalog_v664 in v664 — so the predicate
-- could never be true and the trigger returned silently.
--
-- Every assertion drives the REAL trigger path (an insert into billing_first_paid_evidence_v144)
-- or the operator function; none calls the predicate in isolation.
--
-- ASSERTIONS:
--   F1  a paid self-serve tenant whose terms carry the v664 TIER plan activates: onboarding
--       status 'active', activation_invoice_id set, workspace approval_status 'approved'.
--   F2  a tenant identical in every other way whose terms carry a DIFFERENT plan id stays
--       'payment_pending' — this is not a widening.
--   F3  app.activate_self_serve_paid_now_v763 is idempotent: re-run on the activated tenant
--       reports activated=false, reason='no_payment_pending_onboarding', and leaves the row
--       alone; a business with no first-paid evidence reports 'no_first_paid_evidence'.
--   F4  a non-service role calling the operator function is denied with 42501.
begin;

do $v763_test$
declare
  v_now timestamptz := date_trunc('second', now());
  v_tier public.billing_capacity_tier_catalog_v664%rowtype;
  v_catalog uuid;
  v_bundle uuid;
  v_sector text;
  v_amount integer := 118800;

  v_a uuid; v_b uuid; v_c uuid;
  v_owner_a uuid := gen_random_uuid();
  v_owner_b uuid := gen_random_uuid();
  v_staff_a uuid; v_staff_b uuid;
  v_branch_a uuid; v_branch_b uuid;

  v_onboarding public.self_serve_business_onboarding_v130%rowtype;
  v_control public.business_workspace_controls_v94%rowtype;
  v_result jsonb;
  v_before bigint;
  v_state text;
begin
  perform set_config('request.jwt.claims','',true);

  v_tier := app.billing_tier_for_capacity_v664('annual', 1000);
  if v_tier.capacity_ceiling is null then
    raise exception
      'v763 fixture: no annual capacity tier is published — the v664 catalogue is empty';
  end if;
  /* v755 retired the Stripe price ids from the tier catalogue; on production a Super Admin has
     since written the Razorpay plan id back through the v755 catalogue path. The fixture stands
     the tier up the same way, because a tier with no plan id is not sellable self-serve. */
  if v_tier.provider_base_price_id is null then
    update public.billing_capacity_tier_catalog_v664
       set provider_base_price_id='plan_v763tier'
     where currency=v_tier.currency and cadence=v_tier.cadence
       and capacity_ceiling=v_tier.capacity_ceiling
       and effective_from=v_tier.effective_from;
    v_tier := app.billing_tier_for_capacity_v664('annual', 1000);
  end if;
  if v_tier.provider_base_price_id is null then
    raise exception 'v763 fixture: could not give the annual tier a provider plan id';
  end if;

  /* v132 requires the onboarding row to name a PUBLISHED, Loyalty-capable bundle whose
     sector_key matches the onboarding's own sector_key. */
  select id, sector_key into v_bundle, v_sector
    from public.sector_bundle_versions
   where status = 'published' and 'loyalty' = any(modules)
   order by created_at limit 1;
  if v_bundle is null then
    raise exception 'v763 fixture: no published Loyalty-capable sector bundle in the harness schema';
  end if;

  -- The v124 catalog row the onboarding points at. Its provider price ids are NULL exactly as
  -- they are on production since v755 — that is the whole point of the defect.
  insert into public.billing_plan_catalog_v124(
    currency, cadence, cadence_months, provider, provider_base_price_id,
    provider_capacity_price_id, base_amount_cents, included_customer_capacity,
    capacity_block_size, capacity_block_amount_cents, compare_at_monthly_cents,
    tax_behavior, active, effective_from
  ) values (
    'SGD','annual',12,'razorpay',null,null,v_amount,1000,1000,12000,16800,
    'exclusive',true, v_now - interval '30 days'
  ) returning id into v_catalog;

  -- -------------------------------------------------------------------------------------------
  -- Fixture · two self-serve tenants, identical apart from the plan id on their terms.
  -- -------------------------------------------------------------------------------------------
  insert into public.businesses(name,slug,industry,enabled_modules) values
    ('V763 tier tenant','v763-a-'||substr(gen_random_uuid()::text,1,8),'test',array['dashboard']),
    ('V763 wrong plan','v763-b-'||substr(gen_random_uuid()::text,1,8),'test',array['dashboard']),
    ('V763 no evidence','v763-c-'||substr(gen_random_uuid()::text,1,8),'test',array['dashboard']);
  select id into v_a from public.businesses where name='V763 tier tenant';
  select id into v_b from public.businesses where name='V763 wrong plan';
  select id into v_c from public.businesses where name='V763 no evidence';

  insert into auth.users(
    instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at
  ) values
    ('00000000-0000-0000-0000-000000000000',v_owner_a,'authenticated','authenticated',
     'zz-v763-a-'||substr(v_owner_a::text,1,8)||'@example.test','',v_now,v_now,v_now),
    ('00000000-0000-0000-0000-000000000000',v_owner_b,'authenticated','authenticated',
     'zz-v763-b-'||substr(v_owner_b::text,1,8)||'@example.test','',v_now,v_now,v_now);

  insert into public.staff(business_id,user_id,role,active)
  values (v_a,v_owner_a,'owner',true) returning id into v_staff_a;
  insert into public.staff(business_id,user_id,role,active)
  values (v_b,v_owner_b,'owner',true) returning id into v_staff_b;

  select id into v_branch_a from public.branches where business_id=v_a order by created_at limit 1;
  if v_branch_a is null then
    insert into public.branches(business_id,name,is_default,active)
    values (v_a,'V763 A main',true,true) returning id into v_branch_a;
  end if;
  select id into v_branch_b from public.branches where business_id=v_b order by created_at limit 1;
  if v_branch_b is null then
    insert into public.branches(business_id,name,is_default,active)
    values (v_b,'V763 B main',true,true) returning id into v_branch_b;
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
         gen_random_uuid(), repeat('7',64), 'V763 Owner', b.email, b.name, b.slug,
         v_sector, 'annual', 1000, v_catalog, v_now - interval '1 hour', 'payment_pending'
    from (values
      (v_a, v_owner_a, v_staff_a, v_branch_a, 'zz-v763-a@example.test',
       'V763 tier tenant', (select slug from public.businesses where id=v_a)),
      (v_b, v_owner_b, v_staff_b, v_branch_b, 'zz-v763-b@example.test',
       'V763 wrong plan', (select slug from public.businesses where id=v_b))
    ) as b(business_id, owner_user_id, owner_staff_id, branch_id, email, name, slug);

  -- Terms: A carries the tier's plan id (what a v664 checkout really subscribes to);
  -- B carries a plan id that is not the tier's.
  insert into public.billing_subscription_terms_v124(
    business_id, provider_subscription_id, pricing_model, cadence, customer_capacity,
    capacity_blocks, provider_base_price_id, provider_capacity_item_id,
    provider_capacity_price_id, provider_event_created_at, last_event_id
  ) values
    (v_a,'sub_v763_a','v124_customer_capacity','annual',v_tier.capacity_ceiling,
     v_tier.capacity_ceiling/1000, v_tier.provider_base_price_id, null, null, v_now,'evt_v763_a'),
    (v_b,'sub_v763_b','v124_customer_capacity','annual',v_tier.capacity_ceiling,
     v_tier.capacity_ceiling/1000, 'plan_v763_not_the_tier', null, null, v_now,'evt_v763_b');

  insert into public.billing_provider_invoices(
    business_id,provider_customer_id,provider_subscription_id,provider_invoice_id,currency,status,
    paid_normalized,subtotal_ex_tax_cents,tax_cents,total_cents,amount_due_cents,amount_paid_cents,
    amount_remaining_cents,period_start,period_end,paid_at,livemode,provider_event_created_at,
    provider_event_rank,last_event_id
  ) values
    (v_a,'cust_v763_a','sub_v763_a','inv_v763_a','SGD','paid',
     true,v_amount,0,v_amount,v_amount,v_amount,0,v_now,v_now+interval '365 days',v_now,false,
     v_now,10,'evt_v763_a'),
    (v_b,'cust_v763_b','sub_v763_b','inv_v763_b','SGD','paid',
     true,v_amount,0,v_amount,v_amount,v_amount,0,v_now,v_now+interval '365 days',v_now,false,
     v_now,10,'evt_v763_b');

  -- ===========================================================================================
  -- F1 — the real trigger path activates the tier tenant. Mirroring the paid invoice above is
  -- what production does: v144/v756 record first-paid evidence, and the insert on
  -- billing_first_paid_evidence_v144 fires app.activate_self_serve_paid_v130. The evidence row is
  -- immutable, so this is the ONE chance the trigger gets — which is why the live defect was
  -- unrecoverable without an operator path.
  -- ===========================================================================================
  if not exists (
    select 1 from public.billing_first_paid_evidence_v144 evidence
     where evidence.business_id=v_a and evidence.first_paid_invoice_id='inv_v763_a'
       and evidence.first_paid_at is not null
  ) then
    raise exception
      'v763 fixture: mirroring the paid invoice did not record first-paid evidence for v_a';
  end if;

  select * into v_onboarding from public.self_serve_business_onboarding_v130
   where business_id=v_a;
  if v_onboarding.status <> 'active' then
    raise exception 'F1: onboarding status is % instead of active', v_onboarding.status;
  end if;
  if v_onboarding.activation_invoice_id is distinct from 'inv_v763_a' then
    raise exception 'F1: activation_invoice_id is % instead of inv_v763_a',
      coalesce(v_onboarding.activation_invoice_id,'<null>');
  end if;
  if v_onboarding.activated_at is null then
    raise exception 'F1: activated_at was not set';
  end if;
  select * into v_control from public.business_workspace_controls_v94 where business_id=v_a;
  if v_control.approval_status <> 'approved' then
    raise exception 'F1: workspace approval_status is % instead of approved',
      v_control.approval_status;
  end if;
  if not exists (
    select 1 from public.audit_log
     where business_id=v_a and action='SELF_SERVICE_PAYMENT_CONFIRMED'
       and detail->>'provider_invoice_id'='inv_v763_a'
  ) then
    raise exception 'F1: no SELF_SERVICE_PAYMENT_CONFIRMED audit row (column detail)';
  end if;

  -- ===========================================================================================
  -- F2 — a terms row whose plan is not the tier's plan does NOT activate.
  -- ===========================================================================================
  if not exists (
    select 1 from public.billing_first_paid_evidence_v144 evidence
     where evidence.business_id=v_b and evidence.first_paid_invoice_id='inv_v763_b'
       and evidence.first_paid_at is not null
  ) then
    raise exception
      'v763 fixture: mirroring the paid invoice did not record first-paid evidence for v_b';
  end if;

  select * into v_onboarding from public.self_serve_business_onboarding_v130
   where business_id=v_b;
  if v_onboarding.status <> 'payment_pending' then
    raise exception 'F2: a non-tier plan id activated the workspace (status %)',
      v_onboarding.status;
  end if;
  select * into v_control from public.business_workspace_controls_v94 where business_id=v_b;
  if v_control.approval_status <> 'pending' then
    raise exception 'F2: workspace approval_status moved to % on a non-tier plan',
      v_control.approval_status;
  end if;

  v_result := app.activate_self_serve_paid_now_v763(v_b);
  if coalesce((v_result->>'activated')::boolean,true) then
    raise exception 'F2: the operator function activated the non-tier tenant';
  end if;
  if v_result->>'reason' <> 'paid_evidence_does_not_match_tier_terms' then
    raise exception 'F2: operator reason is % instead of paid_evidence_does_not_match_tier_terms',
      v_result->>'reason';
  end if;

  -- Correcting the plan id to the tier's plan makes the SAME evidence activate — proving F2
  -- failed for the plan id and nothing else.
  update public.billing_subscription_terms_v124
     set provider_base_price_id=v_tier.provider_base_price_id where business_id=v_b;
  v_result := app.activate_self_serve_paid_now_v763(v_b);
  if not coalesce((v_result->>'activated')::boolean,false) then
    raise exception 'F2b: the corrected tier plan still did not activate (reason %)',
      v_result->>'reason';
  end if;

  -- ===========================================================================================
  -- F3 — the operator function is idempotent and says why it did nothing.
  -- ===========================================================================================
  select version into v_before from public.self_serve_business_onboarding_v130 where business_id=v_a;
  v_result := app.activate_self_serve_paid_now_v763(v_a);
  if coalesce((v_result->>'activated')::boolean,true) then
    raise exception 'F3: re-running the operator on an active tenant reported activated=true';
  end if;
  if v_result->>'reason' <> 'no_payment_pending_onboarding' then
    raise exception 'F3: reason is % instead of no_payment_pending_onboarding',
      v_result->>'reason';
  end if;
  if (v_result->>'business_id')::uuid <> v_a then
    raise exception 'F3: the operator response did not name the business';
  end if;
  select status into v_state from public.self_serve_business_onboarding_v130 where business_id=v_a;
  if v_state <> 'active'
     or (select version from public.self_serve_business_onboarding_v130 where business_id=v_a)
        <> v_before then
    raise exception 'F3: the idempotent re-run mutated the onboarding row';
  end if;

  v_result := app.activate_self_serve_paid_now_v763(v_c);
  if v_result->>'reason' <> 'no_first_paid_evidence' then
    raise exception 'F3: a business with no evidence reported %', v_result->>'reason';
  end if;

  -- ===========================================================================================
  -- F4 — the operator function is service_role only.
  -- ===========================================================================================
  begin
    set local role authenticated;
    perform app.activate_self_serve_paid_now_v763(v_a);
    reset role;
    raise exception 'F4: a non-service role executed activate_self_serve_paid_now_v763';
  exception
    when insufficient_privilege then
      reset role;
    when others then
      reset role;
      if sqlstate <> '42501' then raise; end if;
  end;

  raise notice 'v763 corpus: F1-F4 passed';
end
$v763_test$;

rollback;
