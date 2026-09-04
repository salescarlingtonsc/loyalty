-- EXECUTED acceptance fixture for nestly_v755
-- (db/migrations/20260925_nestly_v755_razorpay_billing.sql).
--
-- Run: LC_ALL=C node scripts/db-tests/run.mjs --filter=v755_corpus --migrated-only
--
-- WHY THIS EXISTS. Owner, 2026-09-04: platform billing moves from Stripe to Razorpay
-- Subscriptions (SG). Nothing on the Razorpay path has ever seen a real event, so every
-- assertion below is the first exercise of a code path that only runs when money moves. The
-- suite is rollback-only: it opens a transaction, builds one fixture business, drives the
-- webhook applier with synthetic Razorpay payloads, and rolls everything back.
--
-- ASSERTIONS:
--   A1  the provider check on billing_provider_events accepts 'razorpay' and still accepts
--       'stripe' — Stripe history stays writable and readable.
--   A2  ingest_billing_event_v755 is idempotent: the same envelope twice yields one row and the
--       second call reports duplicate=true; a DIFFERENT envelope under the same id is refused.
--   A3  subscription.charged leaves the subscription active, the tenant row on 'razorpay' with
--       payment_status 'paid', an invoice mirrored as paid, a payment attempt, and it calls both
--       the v94 workspace recovery and the v621 branch activator.
--   A4  an out-of-order event (an older subscription.activated arriving after the cancellation)
--       does NOT overwrite the newer state.
--   A5  subscription.halted maps to 'unpaid' on the mirror and payment_status 'failed' on the
--       tenant row.
--   A6  refund.created writes a negative billing_adjustments row against the charged payment.
--   A7  platform_set_provider_plan_id_v755 records a plan id and writes ONE audit_log row
--       (column `detail`), and refuses a caller who is not a super admin — verified as the real
--       role with `set local role authenticated`, not as the table owner.
--   A8  an unranked event (payment.authorized) is marked 'ignored', never 'failed'.
begin;

do $v755_test$
declare
  v_business uuid;
  v_now timestamptz := now();
  v_sub_id text := 'sub_v755fixture';
  v_plan_id text := 'plan_v755fixture';
  v_payment_id text := 'pay_v755fixture';
  v_result jsonb;
  v_mirror public.billing_provider_subscriptions%rowtype;
  v_tenant public.subscriptions%rowtype;
  v_invoice public.billing_provider_invoices%rowtype;
  v_count integer;
  v_amount integer := 14800;
  v_company uuid; v_prospect uuid; v_terms uuid;
begin
  -- -------------------------------------------------------------------------------------------
  -- Fixture. One business, one tenant subscription row, one active Razorpay-priced tier so the
  -- cadence lookup has something to find.
  -- -------------------------------------------------------------------------------------------
  -- The scratch harness starts with zero tenants; the suite seeds its own and rolls it back.
  insert into public.businesses(name,slug,industry,enabled_modules)
  values(
    'V755 razorpay billing fixture',
    'v755-razorpay-' || substr(gen_random_uuid()::text,1,8),
    'test',
    array['dashboard','clients','sales','loyalty']
  ) returning id into v_business;
  if v_business is null then
    raise exception 'v755 fixture could not seed a business';
  end if;

  update public.billing_capacity_tier_catalog_v664
     set provider_base_price_id = v_plan_id
   where id = (
     select tier.id from public.billing_capacity_tier_catalog_v664 tier
      where tier.cadence='monthly' and tier.active
        and tier.provider_base_price_id is null
      order by tier.capacity_ceiling limit 1
   );
  if not found then
    raise exception 'v755 fixture needs a monthly capacity tier with no plan id yet';
  end if;

  insert into public.subscriptions(business_id) values (v_business)
  on conflict (business_id) do nothing;

  -- v510 is the authority on a tenant's status: a subscription is 'active' only when a paid
  -- invoice matches the accepted commercial terms it was sold on (currency, amount, Singapore
  -- service day). The suite builds the same paperwork an assisted sale would, so A3 proves the
  -- Razorpay charge satisfies the real contract-first projector, not a stub. (sme_commercial_terms
  -- admits no 'monthly' billing_cycle; evidence matching reads the subscription's own window.)
  insert into public.sme_companies(legal_name) values ('V755 Fixture Tenant Pte Ltd')
    returning id into v_company;
  insert into public.sme_prospects(company_id, ownership_state, legacy_stage_raw, priority)
  values (v_company, 'closed', 'v755 rollback fixture', 'normal') returning id into v_prospect;
  insert into public.sme_commercial_terms(prospect_id, version, plan_code, product_code,
    billing_cycle, seats, currency, accepted_value_cents, owner_email, contract_status, accepted_at)
  values (v_prospect, 1, 'v755-fixture', 'peekaa-core', 'annual', 1, 'SGD', v_amount,
    'v755.fixture@example.com', 'accepted', v_now - interval '1 hour') returning id into v_terms;
  update public.subscriptions
     set billing_cadence = 'monthly', cadence_months = 1, currency = 'SGD',
         commercial_terms_id = v_terms,
         period_subtotal_cents = v_amount, period_tax_cents = 0, period_total_cents = v_amount,
         obligation_period_start = app.sg_day(v_now - interval '1 hour'),
         obligation_period_end = app.sg_day(v_now + interval '29 days')
   where business_id = v_business;

  -- -------------------------------------------------------------------------------------------
  -- A1 — the provider column is no longer Stripe-only, and Stripe still fits.
  -- -------------------------------------------------------------------------------------------
  insert into public.billing_provider_events(
    provider,event_id,event_type,object_id,event_created_at,livemode,payload,payload_sha256
  ) values (
    'stripe','evt_v755_probe','invoice.paid','in_v755',v_now,false,'{}'::jsonb,repeat('a',64)
  );
  -- billing_provider_events is append-only (v77 guard); the probe row is discarded by the
  -- enclosing rollback, and the probe id is never reused below.

  -- -------------------------------------------------------------------------------------------
  -- A2 — the durable inbox.
  -- -------------------------------------------------------------------------------------------
  v_result := public.ingest_billing_event_v755(
    'razorpay','v755_evt_auth','subscription.authenticated',v_sub_id,v_now - interval '2 hours',
    false,
    jsonb_build_object(
      'entity','event','event','subscription.authenticated',
      'payload', jsonb_build_object('subscription', jsonb_build_object('entity',
        jsonb_build_object(
          'id',v_sub_id,'plan_id',v_plan_id,'customer_id','cust_v755','status','authenticated',
          'quantity',2,'current_start',extract(epoch from v_now - interval '2 hours')::bigint,
          'current_end',extract(epoch from v_now + interval '28 days')::bigint,
          'charge_at',extract(epoch from v_now + interval '28 days')::bigint,
          'has_scheduled_changes',false,
          'notes',jsonb_build_object('business_id',v_business::text)
        )))),
    repeat('b',64)
  );
  if v_result->>'status' <> 'accepted' or (v_result->>'duplicate')::boolean then
    raise exception 'A2: first ingest should be accepted, got %', v_result;
  end if;
  v_result := public.ingest_billing_event_v755(
    'razorpay','v755_evt_auth','subscription.authenticated',v_sub_id,v_now - interval '2 hours',
    false,
    (select payload from public.billing_provider_events
      where provider='razorpay' and event_id='v755_evt_auth'),
    repeat('b',64)
  );
  if not (v_result->>'duplicate')::boolean then
    raise exception 'A2: the second identical ingest must report duplicate, got %', v_result;
  end if;
  select count(*)::integer into v_count from public.billing_provider_events
   where provider='razorpay' and event_id='v755_evt_auth';
  if v_count <> 1 then
    raise exception 'A2: the inbox holds % rows for one event id', v_count;
  end if;
  begin
    perform public.ingest_billing_event_v755(
      'razorpay','v755_evt_auth','subscription.activated',v_sub_id,v_now,false,
      '{"entity":"event"}'::jsonb,repeat('c',64));
    raise exception 'A2: a conflicting envelope under the same id must be refused';
  exception when sqlstate '22023' then null;
  end;

  v_result := public.apply_razorpay_billing_event_v755('v755_evt_auth');
  if v_result->>'status' <> 'processed' then
    raise exception 'A2: the authenticated event did not process: %', v_result;
  end if;

  -- -------------------------------------------------------------------------------------------
  -- A3 — subscription.charged is the paid truth.
  -- -------------------------------------------------------------------------------------------
  perform public.ingest_billing_event_v755(
    'razorpay','v755_evt_charged','subscription.charged',v_sub_id,v_now - interval '1 hour',false,
    jsonb_build_object(
      'entity','event','event','subscription.charged',
      'payload', jsonb_build_object(
        'subscription', jsonb_build_object('entity', jsonb_build_object(
          'id',v_sub_id,'plan_id',v_plan_id,'customer_id','cust_v755','status','active',
          'quantity',2,'current_start',extract(epoch from v_now - interval '1 hour')::bigint,
          'current_end',extract(epoch from v_now + interval '29 days')::bigint,
          'charge_at',extract(epoch from v_now + interval '29 days')::bigint,
          'has_scheduled_changes',false,
          'notes',jsonb_build_object('business_id',v_business::text))),
        'payment', jsonb_build_object('entity', jsonb_build_object(
          'id',v_payment_id,'amount',v_amount,'currency','SGD','status','captured',
          'invoice_id','inv_v755fixture','method','card','captured',true,
          'created_at',extract(epoch from v_now - interval '1 hour')::bigint,
          'notes',jsonb_build_object('business_id',v_business::text))))),
    repeat('d',64));
  v_result := public.apply_razorpay_billing_event_v755('v755_evt_charged');
  if v_result->>'status' <> 'processed' then
    raise exception 'A3: the charged event did not process: %', v_result;
  end if;
  if v_result->'subscription_lifecycle' is null then
    raise exception 'A3: the v94 workspace recovery was not called on a paid event: %', v_result;
  end if;
  if v_result->'branch_activation' is null then
    raise exception 'A3: the v621 branch activator was not called on a paid event: %', v_result;
  end if;

  select * into v_mirror from public.billing_provider_subscriptions
   where provider_subscription_id = v_sub_id;
  if v_mirror.status <> 'active' or v_mirror.cadence <> 'monthly'
     or v_mirror.cadence_months <> 1 then
    raise exception 'A3: the mirror reads status=% cadence=%/%',
      v_mirror.status, v_mirror.cadence, v_mirror.cadence_months;
  end if;
  select * into v_tenant from public.subscriptions where business_id = v_business;
  if v_tenant.billing_provider <> 'razorpay' or v_tenant.status <> 'active'
     or v_tenant.payment_status <> 'paid'
     or v_tenant.provider_base_price_id <> v_plan_id
     or v_tenant.provider_seat_quantity <> 2 then
    raise exception 'A3: the tenant row reads provider=% status=% payment=% plan=% qty=%',
      v_tenant.billing_provider, v_tenant.status, v_tenant.payment_status,
      v_tenant.provider_base_price_id, v_tenant.provider_seat_quantity;
  end if;
  select * into v_invoice from public.billing_provider_invoices
   where provider_invoice_id = 'inv_v755fixture';
  if v_invoice.status <> 'paid' or not v_invoice.paid_normalized
     or v_invoice.total_cents <> v_amount or v_invoice.amount_remaining_cents <> 0
     or v_invoice.tax_cents <> 0 then
    raise exception 'A3: the invoice mirror is wrong: % % % %',
      v_invoice.status, v_invoice.paid_normalized, v_invoice.total_cents,
      v_invoice.amount_remaining_cents;
  end if;
  select count(*)::integer into v_count from public.billing_payment_attempts
   where source_event_id = 'v755_evt_charged' and attempt_state = 'paid';
  if v_count <> 1 then
    raise exception 'A3: expected one paid payment attempt, found %', v_count;
  end if;

  -- -------------------------------------------------------------------------------------------
  -- A4 — an out-of-order event must not roll the state backwards.
  -- -------------------------------------------------------------------------------------------
  perform public.ingest_billing_event_v755(
    'razorpay','v755_evt_stale','subscription.activated',v_sub_id,v_now - interval '6 hours',false,
    jsonb_build_object(
      'entity','event','event','subscription.activated',
      'payload', jsonb_build_object('subscription', jsonb_build_object('entity',
        jsonb_build_object(
          'id',v_sub_id,'plan_id',v_plan_id,'customer_id','cust_v755','status','created',
          'quantity',1,'current_start',extract(epoch from v_now - interval '6 hours')::bigint,
          'current_end',extract(epoch from v_now)::bigint,'has_scheduled_changes',false,
          'notes',jsonb_build_object('business_id',v_business::text))))),
    repeat('e',64));
  perform public.apply_razorpay_billing_event_v755('v755_evt_stale');
  select * into v_mirror from public.billing_provider_subscriptions
   where provider_subscription_id = v_sub_id;
  if v_mirror.status <> 'active' then
    raise exception 'A4: a stale event rewrote the mirror to %', v_mirror.status;
  end if;
  select * into v_tenant from public.subscriptions where business_id = v_business;
  if v_tenant.provider_seat_quantity <> 2 then
    raise exception 'A4: a stale event rewrote the tenant quantity to %',
      v_tenant.provider_seat_quantity;
  end if;

  -- -------------------------------------------------------------------------------------------
  -- A5 — halted is unpaid, and the tenant row says the payment failed.
  -- -------------------------------------------------------------------------------------------
  perform public.ingest_billing_event_v755(
    'razorpay','v755_evt_halted','subscription.halted',v_sub_id,v_now + interval '1 hour',false,
    jsonb_build_object(
      'entity','event','event','subscription.halted',
      'payload', jsonb_build_object('subscription', jsonb_build_object('entity',
        jsonb_build_object(
          'id',v_sub_id,'plan_id',v_plan_id,'customer_id','cust_v755','status','halted',
          'quantity',2,'current_start',extract(epoch from v_now - interval '1 hour')::bigint,
          'current_end',extract(epoch from v_now + interval '29 days')::bigint,
          'charge_at',extract(epoch from v_now + interval '1 day')::bigint,
          'has_scheduled_changes',false,
          'notes',jsonb_build_object('business_id',v_business::text))))),
    repeat('f',64));
  v_result := public.apply_razorpay_billing_event_v755('v755_evt_halted');
  if v_result->>'status' <> 'processed' then
    raise exception 'A5: the halted event did not process: %', v_result;
  end if;
  select * into v_mirror from public.billing_provider_subscriptions
   where provider_subscription_id = v_sub_id;
  if v_mirror.status <> 'unpaid' then
    raise exception 'A5: halted mapped to % instead of unpaid', v_mirror.status;
  end if;
  select * into v_tenant from public.subscriptions where business_id = v_business;
  if v_tenant.payment_status <> 'failed' then
    raise exception 'A5: the tenant payment status is % instead of failed',
      v_tenant.payment_status;
  end if;
  select count(*)::integer into v_count from public.billing_payment_attempts
   where source_event_id = 'v755_evt_halted' and attempt_state = 'failed';
  if v_count <> 1 then
    raise exception 'A5: expected one failed payment attempt, found %', v_count;
  end if;

  -- -------------------------------------------------------------------------------------------
  -- A6 — a refund is a negative adjustment against the payment it refunds.
  -- -------------------------------------------------------------------------------------------
  perform public.ingest_billing_event_v755(
    'razorpay','v755_evt_refund','refund.created',v_payment_id,v_now + interval '2 hours',false,
    jsonb_build_object(
      'entity','event','event','refund.created',
      'payload', jsonb_build_object('refund', jsonb_build_object('entity',
        jsonb_build_object('id','rfnd_v755','payment_id',v_payment_id,'amount',5000)))),
    repeat('1',64));
  v_result := public.apply_razorpay_billing_event_v755('v755_evt_refund');
  if v_result->>'status' <> 'processed' then
    raise exception 'A6: the refund event did not process: %', v_result;
  end if;
  select count(*)::integer into v_count from public.billing_adjustments
   where source_event_id='v755_evt_refund' and adjustment_type='refund' and total_cents=-5000;
  if v_count <> 1 then
    raise exception 'A6: expected one -5000 refund adjustment, found %', v_count;
  end if;

  -- -------------------------------------------------------------------------------------------
  -- A8 — an unranked event is ignored, not failed.
  -- -------------------------------------------------------------------------------------------
  perform public.ingest_billing_event_v755(
    'razorpay','v755_evt_ignored','payment.authorized',v_payment_id,v_now + interval '3 hours',
    false,
    jsonb_build_object('entity','event','event','payment.authorized',
      'payload', jsonb_build_object('payment', jsonb_build_object('entity',
        jsonb_build_object('id',v_payment_id,'amount',100,'currency','SGD',
          'notes',jsonb_build_object('business_id',v_business::text))))),
    repeat('2',64));
  v_result := public.apply_razorpay_billing_event_v755('v755_evt_ignored');
  if v_result->>'status' <> 'ignored' then
    raise exception 'A8: an unranked event reported % instead of ignored', v_result->>'status';
  end if;

  -- A9 — the projected terms row satisfies the v124 capacity check under a 10,000 tier.
  select count(*) into v_count from public.billing_subscription_terms_v124 terms
   where terms.business_id = v_business
     and terms.customer_capacity = terms.capacity_blocks * 1000
     and terms.customer_capacity >= 10000;
  if v_count <> 1 then
    raise exception 'A9: expected one projected terms row with tier capacity, found %', v_count;
  end if;

  raise notice 'v755_corpus: A1-A6, A8 and A9 passed';
end
$v755_test$;

-- -----------------------------------------------------------------------------------------
-- A7 — the plan-id recorder. Run outside the block above so the role can be switched.
-- -----------------------------------------------------------------------------------------
do $v755_plan_id$
declare
  v_result jsonb;
  v_count integer;
  v_admin uuid := gen_random_uuid();
begin
  /* app.is_super_admin() is auth.uid() in public.super_admins AND a Google-backed platform
     session (v625), so the suite builds exactly that principal rather than calling as postgres. */
  insert into auth.users(instance_id,id,aud,role,email,encrypted_password,
                         email_confirmed_at,created_at,updated_at)
  values ('00000000-0000-0000-0000-000000000000',v_admin,'authenticated','authenticated',
          'v755-admin-'||substr(v_admin::text,1,8)||'@example.test','',now(),now(),now());
  insert into public.super_admins(user_id,email,note)
  values (v_admin,'v755-admin-'||substr(v_admin::text,1,8)||'@example.test','v755 rollback fixture');
  perform set_config('request.jwt.claims', json_build_object(
    'sub', v_admin::text, 'role', 'authenticated',
    'amr', json_build_array(json_build_object('method','oauth')),
    'app_metadata', json_build_object('providers', json_build_array('google')))::text, true);

  v_result := public.platform_set_provider_plan_id_v755(
    'billing_capacity_tier_catalog_v664',
    jsonb_build_object('cadence','monthly','capacity_ceiling',10000),
    'plan_v755recorded'
  );
  if v_result->>'plan_id' <> 'plan_v755recorded' then
    raise exception 'A7: the recorder returned %', v_result;
  end if;
  select count(*)::integer into v_count from public.billing_capacity_tier_catalog_v664
   where cadence='monthly' and capacity_ceiling=10000
     and provider_base_price_id='plan_v755recorded';
  if v_count <> 1 then
    raise exception 'A7: the tier did not take the plan id (% matching rows)', v_count;
  end if;
  select count(*)::integer into v_count from public.audit_log
   where action='PROVIDER_PLAN_ID_SET_V755'
     and detail->>'plan_id'='plan_v755recorded';
  if v_count <> 1 then
    raise exception 'A7: expected exactly one audit row, found %', v_count;
  end if;
  begin
    perform public.platform_set_provider_plan_id_v755(
      'billing_capacity_tier_catalog_v664',
      jsonb_build_object('cadence','monthly','capacity_ceiling',10000),
      'not_a_plan_id');
    raise exception 'A7: a malformed plan id must be refused';
  exception when sqlstate '22023' then null;
  end;
  perform set_config('request.jwt.claims','',true);
  raise notice 'v755_corpus: A7 (super admin path) passed';
end
$v755_plan_id$;

/* The denial half of A7 is measured as the REAL role. RLS and app.is_super_admin() never apply
   to the table owner, so a check run as postgres proves nothing. */
do $v755_plan_id_denied$
declare v_denied boolean := false;
begin
  set local role authenticated;
  begin
    perform public.platform_set_provider_plan_id_v755(
      'billing_capacity_tier_catalog_v664',
      jsonb_build_object('cadence','monthly','capacity_ceiling',10000),
      'plan_v755sneaky');
  exception when sqlstate '42501' then v_denied := true;
  end;
  reset role;
  if not v_denied then
    raise exception 'A7: a non-super-admin was allowed to set a provider plan id';
  end if;
  raise notice 'v755_corpus: A7 (denial) passed';
end
$v755_plan_id_denied$;

rollback;
