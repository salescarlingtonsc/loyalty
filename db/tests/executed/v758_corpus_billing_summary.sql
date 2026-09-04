-- EXECUTED acceptance fixture for nestly_v758
-- (db/migrations/20260928_nestly_v758_billing_summary_and_payment_method.sql).
--
-- Run: LC_ALL=C node scripts/db-tests/run.mjs --filter=v758_corpus --migrated-only
--
-- WHY THIS EXISTS. Owner, 2026-09-04: "just show me what I subscribed to, how many branches, how
-- much in total, and the renew date" — and show the card. Until v758 the money on the billing
-- page was arithmetic the BROWSER invented from get_business_billing_v125's raw parts, and
-- `billing.payment_method.last4` was read by the client but written by nothing at all. Every
-- assertion below exercises a path that only runs when money moves, so none of it has ever been
-- observed in production. The suite is rollback-only: it builds its own tenants, drives the real
-- Razorpay applier with synthetic payloads, and rolls everything back.
--
-- ASSERTIONS:
--   D1  a tenant with 1 included + 1 active + 1 canceling branch summarises as units=2 and
--       total = tier amount x 2 — the included branch is NOT in the billable set, and the
--       canceling one is reported as stopping rather than silently billed.
--   D2  a subscription.charged payload carrying payment.entity.card.last4 records the card on
--       billing_provider_customers, and a charged payload with NO card block leaves it alone
--       (the edge reconciler owns that backfill) rather than nulling it.
--   D3  set_billing_payment_method_v758 refuses a malformed last4 and refuses a card with none,
--       but accepts kind='paynow' with brand and last4 both NULL (the edge contract).
--   D4  get_business_billing_v758 returns every key get_business_billing_v125 returns, plus
--       exactly `payment_method` and `summary` — it delegates, it does not re-implement.
--   D5  a tenant with no terms and a future trial end summarises as state='trial' with
--       plan_label null; past the trial end with no terms it is 'none'.

begin;

do $v758_test$
declare
  v_now timestamptz := now();
  -- D1 tenant
  v_biz uuid;
  v_owner uuid := gen_random_uuid();
  -- D2 tenant (its own business: the applier links a Razorpay customer per business)
  v_rz_biz uuid;
  v_rz_owner uuid := gen_random_uuid();
  v_sub_id text := 'sub_v758fixture';
  v_plan_id text := 'plan_v758fixture';
  v_payment_id text := 'pay_v758fixture';
  v_company uuid; v_prospect uuid; v_terms_id uuid;
  v_amount integer := 14800;
  -- D5 tenant
  v_trial_biz uuid;
  v_trial_owner uuid := gen_random_uuid();

  v_tier_amount integer;
  v_payload jsonb;
  v_summary jsonb;
  v_pm jsonb;
  v_customer public.billing_provider_customers%rowtype;
  v_result jsonb;
  v_count integer;
  v_caught boolean;
  v_missing text;
  v_extra text;
  v_third uuid;
  v_v125 jsonb;
begin
  -- ===========================================================================================
  -- Fixture · D1 tenant: one owner, one subscription, three branches in three different states.
  -- ===========================================================================================
  insert into public.businesses(name,slug,industry,enabled_modules)
  values('V758 summary fixture','v758-summary-'||substr(gen_random_uuid()::text,1,8),'test',
         array['dashboard','clients','sales','loyalty'])
  returning id into v_biz;

  insert into auth.users(id,email)
  values(v_owner,'v758-owner-'||substr(v_owner::text,1,8)||'@example.test')
  on conflict (id) do nothing;
  insert into public.staff(business_id,user_id,role,full_name,active,access_state)
  values(v_biz,v_owner,'owner','V758 owner',true,'approved');

  insert into public.subscriptions(business_id) values(v_biz)
  on conflict (business_id) do nothing;
  /* None of these columns is watched by subscriptions_payment_link_v510, so the fixture states
     the tenant's billing shape without dragging the whole contract-first projector in. */
  update public.subscriptions
     set status='active', payment_status='paid', billing_cadence='annual', cadence_months=12,
         cancel_at_period_end=false, next_payment_at=v_now + interval '300 days',
         current_period_end=v_now + interval '300 days'
   where business_id=v_biz;

  /* D1 stops a branch through the REAL v665 owner path, and that path needs an open workspace
     (v94 approval + lifecycle) or it refuses for a billing reason and D1 passes vacuously. */
  insert into public.business_workspace_controls_v94
    (business_id, approval_status, decided_at, decision_reason)
  values (v_biz,'approved',v_now,'v758 billing summary fixture')
  on conflict (business_id) do update
    set approval_status='approved', decided_at=v_now,
        decision_reason='v758 billing summary fixture';
  insert into public.business_subscription_lifecycle_v94(business_id,state,workspace_paused)
  values (v_biz,'current',false)
  on conflict (business_id) do update set state='current', workspace_paused=false;

  /* The first branch inserted for a business becomes 'included' by ab_branches_billing_state_v665
     — that is the base unit the plan already pays for. */
  insert into public.branches(business_id,name) values(v_biz,'V758 first');
  insert into public.branches(business_id,name,billing_state)
  values(v_biz,'V758 second','active');
  insert into public.branches(business_id,name,billing_state)
  values(v_biz,'V758 third','active') returning id into v_third;
  /* Stopped through public.business_unsubscribe_branch_v665 — the owner-facing path — not by
     writing billing_state directly, which the v621 authority guard refuses anyway. */
  perform set_config('request.jwt.claims',
    json_build_object('sub',v_owner::text,'role','authenticated')::text, true);
  v_result := public.business_unsubscribe_branch_v665(v_biz,v_third,gen_random_uuid());
  if v_result->>'billing_state' <> 'canceling' then
    raise exception 'D1 fixture: the unsubscribe left the branch at %', v_result;
  end if;
  perform set_config('request.jwt.claims','',true);

  select count(*)::integer into v_count from public.branches
   where business_id=v_biz and billing_state='included';
  if v_count <> 1 then
    raise exception 'D1 fixture: expected exactly one included branch, found %', v_count;
  end if;

  select tier.amount_cents into v_tier_amount
    from public.billing_capacity_tier_catalog_v664 tier
   where tier.currency='SGD' and tier.active and tier.cadence='annual'
     and tier.capacity_ceiling=10000
     and tier.effective_from <= now()
     and (tier.effective_to is null or tier.effective_to > now());
  if v_tier_amount is null then
    raise exception 'D1 fixture: the annual 10,000 SGD tier is missing from the catalogue';
  end if;

  insert into public.billing_subscription_terms_v124(
    business_id,provider_subscription_id,cadence,customer_capacity,capacity_blocks,
    provider_base_price_id,provider_event_created_at,last_event_id
  ) values (
    v_biz,'sub_v758summary','annual',10000,10,'plan_v758summary',v_now,'v758_fixture'
  );

  -- ===========================================================================================
  -- D1 — the four answers, computed server-side.
  -- ===========================================================================================
  perform set_config('request.jwt.claims',
    json_build_object('sub',v_owner::text,'role','authenticated')::text, true);
  v_payload := public.get_business_billing_v758(v_biz);
  v_summary := v_payload->'summary';

  if v_summary is null or jsonb_typeof(v_summary) <> 'object' then
    raise exception 'D1: v758 returned no summary object';
  end if;
  if (v_summary->>'branches_total')::integer <> 3
     or (v_summary->>'branches_included')::integer <> 1
     or (v_summary->>'branches_billable')::integer <> 1
     or (v_summary->>'branches_stopping')::integer <> 1
     or (v_summary->>'branches_lapsed')::integer <> 0
     or (v_summary->>'branches_unsubscribed')::integer <> 0 then
    raise exception 'D1: the branch counts read %', v_summary;
  end if;
  if (v_summary->>'units')::integer <> 2 then
    raise exception 'D1: expected units=2 (1 included + 1 billable), got %',
      v_summary->>'units';
  end if;
  if (v_summary->>'unit_amount_cents')::integer <> v_tier_amount then
    raise exception 'D1: unit amount is % but the tier charges %',
      v_summary->>'unit_amount_cents', v_tier_amount;
  end if;
  if (v_summary->>'total_cents')::integer <> v_tier_amount * 2 then
    raise exception 'D1: total is % but 2 units of % is %',
      v_summary->>'total_cents', v_tier_amount, v_tier_amount * 2;
  end if;
  if v_summary->>'plan_label' <> 'Annual' or (v_summary->>'capacity')::integer <> 10000 then
    raise exception 'D1: the plan reads %/%',
      v_summary->>'plan_label', v_summary->>'capacity';
  end if;
  if v_summary->>'state' <> 'active' then
    raise exception 'D1: state is % instead of active', v_summary->>'state';
  end if;
  if v_summary->>'renews_at' is null then
    raise exception 'D1: the renew date is missing';
  end if;
  /* The card line is the fourth answer and this tenant has never been charged: it must be an
     explicit null, not an absent key the client would render as undefined. */
  if v_payload->'payment_method' <> 'null'::jsonb then
    raise exception 'D1: an uncharged tenant reported a payment method: %',
      v_payload->'payment_method';
  end if;
  raise notice 'D1 passed: units=2, total=% cents, state=active', v_tier_amount * 2;

  -- ===========================================================================================
  -- Fixture · D2 tenant: the real Razorpay applier, driven with a synthetic charged payload.
  -- ===========================================================================================
  perform set_config('request.jwt.claims','',true);

  insert into public.businesses(name,slug,industry,enabled_modules)
  values('V758 razorpay fixture','v758-razorpay-'||substr(gen_random_uuid()::text,1,8),'test',
         array['dashboard','clients','sales','loyalty'])
  returning id into v_rz_biz;
  insert into auth.users(id,email)
  values(v_rz_owner,'v758-rz-'||substr(v_rz_owner::text,1,8)||'@example.test')
  on conflict (id) do nothing;
  insert into public.staff(business_id,user_id,role,full_name,active,access_state)
  values(v_rz_biz,v_rz_owner,'owner','V758 razorpay owner',true,'approved');

  update public.billing_capacity_tier_catalog_v664
     set provider_base_price_id = v_plan_id
   where id = (
     select tier.id from public.billing_capacity_tier_catalog_v664 tier
      where tier.cadence='monthly' and tier.active and tier.provider_base_price_id is null
      order by tier.capacity_ceiling limit 1
   );
  if not found then
    raise exception 'D2 fixture needs a monthly capacity tier with no plan id yet';
  end if;

  insert into public.subscriptions(business_id) values(v_rz_biz)
  on conflict (business_id) do nothing;
  /* v510 is the authority on a tenant's status: 'active' only when a paid invoice matches the
     accepted commercial terms. The fixture builds the same paperwork an assisted sale would, so
     the charged event below runs through the real projector rather than a stub. */
  insert into public.sme_companies(legal_name) values('V758 Fixture Tenant Pte Ltd')
    returning id into v_company;
  insert into public.sme_prospects(company_id,ownership_state,legacy_stage_raw,priority)
  values(v_company,'closed','v758 rollback fixture','normal') returning id into v_prospect;
  insert into public.sme_commercial_terms(prospect_id,version,plan_code,product_code,
    billing_cycle,seats,currency,accepted_value_cents,owner_email,contract_status,accepted_at)
  values(v_prospect,1,'v758-fixture','peekaa-core','annual',1,'SGD',v_amount,
    'v758.fixture@example.com','accepted',v_now - interval '1 hour') returning id into v_terms_id;
  update public.subscriptions
     set billing_cadence='monthly', cadence_months=1, currency='SGD',
         commercial_terms_id=v_terms_id,
         period_subtotal_cents=v_amount, period_tax_cents=0, period_total_cents=v_amount,
         obligation_period_start=app.sg_day(v_now - interval '1 hour'),
         obligation_period_end=app.sg_day(v_now + interval '29 days')
   where business_id=v_rz_biz;

  perform public.ingest_billing_event_v755(
    'razorpay','v758_evt_auth','subscription.authenticated',v_sub_id,v_now - interval '2 hours',
    false,
    jsonb_build_object('entity','event','event','subscription.authenticated',
      'payload', jsonb_build_object('subscription', jsonb_build_object('entity',
        jsonb_build_object('id',v_sub_id,'plan_id',v_plan_id,'customer_id','cust_v758',
          'status','authenticated','quantity',1,
          'current_start',extract(epoch from v_now - interval '2 hours')::bigint,
          'current_end',extract(epoch from v_now + interval '28 days')::bigint,
          'charge_at',extract(epoch from v_now + interval '28 days')::bigint,
          'has_scheduled_changes',false,
          'notes',jsonb_build_object('business_id',v_rz_biz::text))))),
    repeat('a',64));
  v_result := public.apply_razorpay_billing_event_v755('v758_evt_auth');
  if v_result->>'status' <> 'processed' then
    raise exception 'D2 fixture: the authenticated event did not process: %', v_result;
  end if;

  -- ===========================================================================================
  -- D2 — the charged event records the card it was charged on.
  -- ===========================================================================================
  perform public.ingest_billing_event_v755(
    'razorpay','v758_evt_charged','subscription.charged',v_sub_id,v_now - interval '1 hour',false,
    jsonb_build_object('entity','event','event','subscription.charged',
      'payload', jsonb_build_object(
        'subscription', jsonb_build_object('entity', jsonb_build_object(
          'id',v_sub_id,'plan_id',v_plan_id,'customer_id','cust_v758','status','active',
          'quantity',1,
          'current_start',extract(epoch from v_now - interval '1 hour')::bigint,
          'current_end',extract(epoch from v_now + interval '29 days')::bigint,
          'charge_at',extract(epoch from v_now + interval '29 days')::bigint,
          'has_scheduled_changes',false,
          'notes',jsonb_build_object('business_id',v_rz_biz::text))),
        'payment', jsonb_build_object('entity', jsonb_build_object(
          'id',v_payment_id,'amount',v_amount,'currency','SGD','status','captured',
          'invoice_id','inv_v758fixture','method','card','captured',true,
          'card',jsonb_build_object('last4','4242','network','Visa','type','credit'),
          'created_at',extract(epoch from v_now - interval '1 hour')::bigint,
          'notes',jsonb_build_object('business_id',v_rz_biz::text))))),
    repeat('b',64));
  v_result := public.apply_razorpay_billing_event_v755('v758_evt_charged');
  if v_result->>'status' <> 'processed' then
    raise exception 'D2: the charged event did not process: %', v_result;
  end if;

  select * into v_customer from public.billing_provider_customers
   where business_id=v_rz_biz;
  if v_customer.payment_method_kind is distinct from 'card'
     or v_customer.payment_method_last4 is distinct from '4242'
     or v_customer.payment_method_brand is distinct from 'Visa'
     or v_customer.payment_method_source_payment_id is distinct from v_payment_id
     or v_customer.payment_method_updated_at is null then
    raise exception 'D2: the card was not recorded: kind=% brand=% last4=% payment=%',
      v_customer.payment_method_kind, v_customer.payment_method_brand,
      v_customer.payment_method_last4, v_customer.payment_method_source_payment_id;
  end if;

  /* A later charge with NO card block must LEAVE the card alone — nulling it here would blank
     the owner's card line every time Razorpay omits the expansion, and the edge reconciler is
     the thing that fills a genuinely-unknown card in. */
  perform public.ingest_billing_event_v755(
    'razorpay','v758_evt_charged_nocard','subscription.charged',v_sub_id,
    v_now + interval '30 days',false,
    jsonb_build_object('entity','event','event','subscription.charged',
      'payload', jsonb_build_object(
        'subscription', jsonb_build_object('entity', jsonb_build_object(
          'id',v_sub_id,'plan_id',v_plan_id,'customer_id','cust_v758','status','active',
          'quantity',1,
          'current_start',extract(epoch from v_now + interval '29 days')::bigint,
          'current_end',extract(epoch from v_now + interval '59 days')::bigint,
          'has_scheduled_changes',false,
          'notes',jsonb_build_object('business_id',v_rz_biz::text))),
        'payment', jsonb_build_object('entity', jsonb_build_object(
          'id','pay_v758nocard','amount',v_amount,'currency','SGD','status','captured',
          'invoice_id','inv_v758nocard','method','card','captured',true,
          'created_at',extract(epoch from v_now + interval '30 days')::bigint,
          'notes',jsonb_build_object('business_id',v_rz_biz::text))))),
    repeat('c',64));
  v_result := public.apply_razorpay_billing_event_v755('v758_evt_charged_nocard');
  if v_result->>'status' <> 'processed' then
    raise exception 'D2: the second charged event did not process: %', v_result;
  end if;
  select * into v_customer from public.billing_provider_customers where business_id=v_rz_biz;
  if v_customer.payment_method_last4 is distinct from '4242'
     or v_customer.payment_method_source_payment_id is distinct from v_payment_id then
    raise exception 'D2: a card-less charge overwrote the stored card (last4=% payment=%)',
      v_customer.payment_method_last4, v_customer.payment_method_source_payment_id;
  end if;

  /* And the owner-facing read surfaces it. */
  perform set_config('request.jwt.claims',
    json_build_object('sub',v_rz_owner::text,'role','authenticated')::text, true);
  v_pm := public.get_business_billing_v758(v_rz_biz)->'payment_method';
  if v_pm->>'last4' <> '4242' or v_pm->>'brand' <> 'Visa' or v_pm->>'kind' <> 'card' then
    raise exception 'D2: v758 reported payment_method %', v_pm;
  end if;
  perform set_config('request.jwt.claims','',true);
  raise notice 'D2 passed: Visa ending 4242 captured from the charged payload and held';

  -- ===========================================================================================
  -- D3 — the reconcile backfill validates what it is given.
  -- ===========================================================================================
  v_caught := false;
  begin
    perform public.set_billing_payment_method_v758(
      v_rz_biz,'pay_v758backfill','card','Visa','42');
  exception when sqlstate '22023' then v_caught := true;
  end;
  if not v_caught then
    raise exception 'D3: a two-digit last4 was accepted';
  end if;

  v_caught := false;
  begin
    perform public.set_billing_payment_method_v758(
      v_rz_biz,'pay_v758backfill','card','Visa','4242424242424242');
  exception when sqlstate '22023' then v_caught := true;
  end;
  if not v_caught then
    raise exception 'D3: a full card number was accepted into last4';
  end if;

  v_caught := false;
  begin
    perform public.set_billing_payment_method_v758(
      v_rz_biz,'pay_v758backfill','card','Visa',null);
  exception when sqlstate '22023' then v_caught := true;
  end;
  if not v_caught then
    raise exception 'D3: a card with no last4 was accepted';
  end if;

  v_caught := false;
  begin
    perform public.set_billing_payment_method_v758(
      v_rz_biz,'pay_v758backfill','crypto','Visa','4242');
  exception when sqlstate '22023' then v_caught := true;
  end;
  if not v_caught then
    raise exception 'D3: an unknown payment method kind was accepted';
  end if;

  /* The edge reconciler calls with brand and last4 both SQL NULL for a non-card method. That is
     the contract, and it must be accepted, not refused. */
  v_result := public.set_billing_payment_method_v758(
    v_rz_biz,'pay_v758paynow','paynow',null,null);
  if v_result->>'status' <> 'ok' or v_result->>'kind' <> 'paynow' then
    raise exception 'D3: paynow with null brand/last4 was refused: %', v_result;
  end if;
  select * into v_customer from public.billing_provider_customers where business_id=v_rz_biz;
  if v_customer.payment_method_kind <> 'paynow'
     or v_customer.payment_method_last4 is not null
     or v_customer.payment_method_brand is not null then
    raise exception 'D3: the paynow write left card debris: % % %',
      v_customer.payment_method_kind, v_customer.payment_method_brand,
      v_customer.payment_method_last4;
  end if;

  /* A business with no provider customer row cannot have a card recorded against it. */
  v_caught := false;
  begin
    perform public.set_billing_payment_method_v758(v_biz,'pay_v758orphan','card','Visa','4242');
  exception when sqlstate '22023' then v_caught := true;
  end;
  if not v_caught then
    raise exception 'D3: a business with no provider customer row accepted a card';
  end if;
  raise notice 'D3 passed: malformed last4 refused, paynow with nulls accepted';

  -- ===========================================================================================
  -- D4 — v758 is v125 plus exactly two keys.
  -- ===========================================================================================
  perform set_config('request.jwt.claims',
    json_build_object('sub',v_owner::text,'role','authenticated')::text, true);
  v_payload := public.get_business_billing_v758(v_biz);
  /* Both readings are taken under the SAME owner session, once each, and compared as data —
     re-calling v125 inside a per-row qual re-enters a SECURITY DEFINER under a plan that need
     not carry the session claims, and that is a property of the test, not of the RPC. */
  v_v125 := public.get_business_billing_v125(v_biz);

  select string_agg(k,',' order by k) into v_missing
    from jsonb_object_keys(v_v125) k
   where not v_payload ? k;
  if v_missing is not null then
    raise exception 'D4: v758 dropped v125 key(s): %', v_missing;
  end if;

  select string_agg(k,',' order by k) into v_extra
    from jsonb_object_keys(v_payload) k
   where not (v_v125 ? k);
  if v_extra is distinct from 'payment_method,summary' then
    raise exception 'D4: v758 adds % instead of payment_method,summary', v_extra;
  end if;
  raise notice 'D4 passed: every v125 key present, plus payment_method and summary';

  -- ===========================================================================================
  -- D5 — a trial tenant has no plan to name.
  -- ===========================================================================================
  perform set_config('request.jwt.claims','',true);
  insert into public.businesses(name,slug,industry,enabled_modules)
  values('V758 trial fixture','v758-trial-'||substr(gen_random_uuid()::text,1,8),'test',
         array['dashboard','clients'])
  returning id into v_trial_biz;
  insert into auth.users(id,email)
  values(v_trial_owner,'v758-trial-'||substr(v_trial_owner::text,1,8)||'@example.test')
  on conflict (id) do nothing;
  insert into public.staff(business_id,user_id,role,full_name,active,access_state)
  values(v_trial_biz,v_trial_owner,'owner','V758 trial owner',true,'approved');
  insert into public.subscriptions(business_id) values(v_trial_biz)
  on conflict (business_id) do nothing;
  update public.subscriptions set trial_ends_at = v_now + interval '10 days'
   where business_id=v_trial_biz;

  perform set_config('request.jwt.claims',
    json_build_object('sub',v_trial_owner::text,'role','authenticated')::text, true);
  v_summary := public.get_business_billing_v758(v_trial_biz)->'summary';
  if v_summary->>'state' <> 'trial' then
    raise exception 'D5: a tenant inside its trial reads state=%', v_summary->>'state';
  end if;
  if v_summary->'plan_label' <> 'null'::jsonb then
    raise exception 'D5: a tenant with no terms named a plan: %', v_summary->'plan_label';
  end if;
  if (v_summary->>'total_cents')::integer <> 0
     or v_summary->'unit_amount_cents' <> 'null'::jsonb then
    raise exception 'D5: a tenant with no terms was priced: % / %',
      v_summary->>'total_cents', v_summary->'unit_amount_cents';
  end if;
  if (v_summary->>'units')::integer <> 1 then
    raise exception 'D5: a branch-less tenant reported % units', v_summary->>'units';
  end if;

  /* Past the trial end, with still no terms, there is nothing to show — 'none', not 'trial'. */
  perform set_config('request.jwt.claims','',true);
  update public.subscriptions set trial_ends_at = v_now - interval '1 day'
   where business_id=v_trial_biz;
  perform set_config('request.jwt.claims',
    json_build_object('sub',v_trial_owner::text,'role','authenticated')::text, true);
  v_summary := public.get_business_billing_v758(v_trial_biz)->'summary';
  if v_summary->>'state' <> 'none' then
    raise exception 'D5: an expired trial with no terms reads state=%', v_summary->>'state';
  end if;
  perform set_config('request.jwt.claims','',true);
  raise notice 'D5 passed: trial then none, with no plan named either way';

  raise notice 'v758_corpus: D1-D5 passed';
end
$v758_test$;

/* The owner-facing read is measured as the REAL role too. get_business_billing_v758 delegates
   its tenant guard to v125, and a guard checked only as the table owner proves nothing. */
do $v758_denied$
declare
  v_denied boolean := false;
  v_biz uuid;
begin
  select id into v_biz from public.businesses order by created_at desc limit 1;
  set local role authenticated;
  begin
    perform public.get_business_billing_v758(v_biz);
  exception
    when sqlstate '42501' then v_denied := true;
    when sqlstate '22023' then v_denied := true;
  end;
  reset role;
  if not v_denied then
    raise exception 'D6: a signed-out caller read another tenant''s billing';
  end if;
  raise notice 'v758_corpus: D6 (denial) passed';
end
$v758_denied$;

rollback;
