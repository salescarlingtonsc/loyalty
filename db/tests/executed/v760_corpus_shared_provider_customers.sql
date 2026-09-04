-- EXECUTED acceptance fixture for nestly_v760
-- (db/migrations/20260929_nestly_v760_shared_provider_customers.sql).
--
-- Run: LC_ALL=C node scripts/db-tests/run.mjs --filter=v760_corpus --migrated-only
--
-- WHY THIS EXISTS. Observed live in Razorpay test mode, 2026-09-05: Razorpay keys a customer by
-- contact details, so one `cust_...` id is reused for every subscription created against the same
-- phone/email. An owner running two businesses on Peekaa therefore has ONE Razorpay customer id
-- across both tenants. v77 declared `provider_customer_id text not null unique` and the v755
-- applier enforced the same assumption in code, so every event for the SECOND business failed
-- ('Razorpay customer is already linked to another business') and that tenant never became paid.
--
-- ASSERTIONS:
--   E1  two businesses that share one Razorpay customer id both process a subscription.charged
--       and both end payment_status='paid', each with its own billing_provider_customers row.
--   E2  a business whose stored customer id differs from the incoming one is RELINKED to the
--       incoming id, and an audit_log row (column `detail`) records
--       action='PROVIDER_CUSTOMER_RELINKED_V760' naming the previous id.
--   E3  the SUBSCRIPTION guard is untouched: a subscription already mirrored against another
--       business still refuses, leaving the event processing_status='failed'.
--   E4  redrive_razorpay_billing_events_v760 re-applies that failed event once the collision is
--       gone, reports it processed, and refuses to re-run an already-processed event.
--   E5  the global unique constraint on provider_customer_id is gone, the non-unique
--       (provider, provider_customer_id) lookup index is present, one row per business is still
--       enforced, and subscriptions_provider_customer_uk — the same assumption stated a second
--       time on the tenant table — is gone while the subscription-level unique index survives.
begin;

do $v760_test$
declare
  v_now timestamptz := now();
  v_amount integer := 14800;
  v_plan_id text := 'plan_v760fixture';

  v_a uuid; v_b uuid; v_c uuid; v_d uuid; v_other uuid;
  v_shared_customer constant text := 'cust_v760shared';

  v_result jsonb;
  v_redrive jsonb;
  v_row public.billing_provider_customers%rowtype;
  v_tenant public.subscriptions%rowtype;
  v_status text;
  v_count integer;
  v_detail jsonb;
begin
  perform set_config('request.jwt.claims','',true);

  -- ===========================================================================================
  -- Fixture · five tenants, all self-serve (no commercial terms), all Razorpay, all SGD.
  --   A, B  share one Razorpay customer id (the live defect).
  --   C     is relinked to a new customer id.
  --   D     collides on a subscription id that already belongs to `other`.
  -- ===========================================================================================
  insert into public.businesses(name,slug,industry,enabled_modules) values
    ('V760 shared customer A','v760-a-'||substr(gen_random_uuid()::text,1,8),'test',array['dashboard']),
    ('V760 shared customer B','v760-b-'||substr(gen_random_uuid()::text,1,8),'test',array['dashboard']),
    ('V760 relinked C','v760-c-'||substr(gen_random_uuid()::text,1,8),'test',array['dashboard']),
    ('V760 collision D','v760-d-'||substr(gen_random_uuid()::text,1,8),'test',array['dashboard']),
    ('V760 collision owner','v760-o-'||substr(gen_random_uuid()::text,1,8),'test',array['dashboard']);
  select id into v_a from public.businesses where name='V760 shared customer A';
  select id into v_b from public.businesses where name='V760 shared customer B';
  select id into v_c from public.businesses where name='V760 relinked C';
  select id into v_d from public.businesses where name='V760 collision D';
  select id into v_other from public.businesses where name='V760 collision owner';

  insert into public.subscriptions(business_id) values (v_a),(v_b),(v_c),(v_d),(v_other)
    on conflict (business_id) do nothing;

  /* The commercial-terms-free self-serve shape (v756): the charged event's own paid invoice is
     the evidence, so the v510 projector leaves payment_status='paid' standing. */
  update public.subscriptions
     set billing_provider='razorpay', billing_cadence='monthly', cadence_months=1, currency='SGD',
         commercial_terms_id=null,
         period_subtotal_cents=v_amount, period_tax_cents=0, period_total_cents=v_amount
   where business_id in (v_a,v_b,v_c,v_d,v_other);

  /* One monthly capacity tier carries the fixture's plan id so the applier can resolve cadence
     without the client asserting it. */
  update public.billing_capacity_tier_catalog_v664
     set provider_base_price_id = v_plan_id
   where id = (
     select tier.id from public.billing_capacity_tier_catalog_v664 tier
      where tier.cadence='monthly' and tier.active and tier.provider_base_price_id is null
      order by tier.capacity_ceiling limit 1
   );
  if not found then
    raise exception 'v760 fixture needs a monthly capacity tier with no plan id yet';
  end if;

  -- ===========================================================================================
  -- E1 — two businesses, ONE Razorpay customer id, both charged, both paid.
  -- ===========================================================================================
  perform public.ingest_billing_event_v755(
    'razorpay','v760_evt_a_charged','subscription.charged','sub_v760_a',
    v_now - interval '2 hours', false,
    jsonb_build_object('entity','event','event','subscription.charged',
      'payload', jsonb_build_object(
        'subscription', jsonb_build_object('entity', jsonb_build_object(
          'id','sub_v760_a','plan_id',v_plan_id,'customer_id',v_shared_customer,
          'status','active','quantity',1,
          'current_start',extract(epoch from v_now - interval '2 hours')::bigint,
          'current_end',extract(epoch from v_now + interval '28 days')::bigint,
          'charge_at',extract(epoch from v_now + interval '28 days')::bigint,
          'has_scheduled_changes',false,
          'notes',jsonb_build_object('business_id',v_a::text))),
        'payment', jsonb_build_object('entity', jsonb_build_object(
          'id','pay_v760_a','amount',v_amount,'currency','SGD','status','captured',
          'invoice_id','inv_v760_a','method','card','captured',true,
          'created_at',extract(epoch from v_now - interval '2 hours')::bigint,
          'notes',jsonb_build_object('business_id',v_a::text))))),
    repeat('a',64));
  v_result := public.apply_razorpay_billing_event_v755('v760_evt_a_charged');
  if v_result->>'status' <> 'processed' then
    raise exception 'E1: the first tenant''s charged event did not process: %', v_result;
  end if;

  /* The SAME customer id, a different business. Before v760 this raised. */
  perform public.ingest_billing_event_v755(
    'razorpay','v760_evt_b_charged','subscription.charged','sub_v760_b',
    v_now - interval '1 hour', false,
    jsonb_build_object('entity','event','event','subscription.charged',
      'payload', jsonb_build_object(
        'subscription', jsonb_build_object('entity', jsonb_build_object(
          'id','sub_v760_b','plan_id',v_plan_id,'customer_id',v_shared_customer,
          'status','active','quantity',1,
          'current_start',extract(epoch from v_now - interval '1 hour')::bigint,
          'current_end',extract(epoch from v_now + interval '29 days')::bigint,
          'charge_at',extract(epoch from v_now + interval '29 days')::bigint,
          'has_scheduled_changes',false,
          'notes',jsonb_build_object('business_id',v_b::text))),
        'payment', jsonb_build_object('entity', jsonb_build_object(
          'id','pay_v760_b','amount',v_amount,'currency','SGD','status','captured',
          'invoice_id','inv_v760_b','method','card','captured',true,
          'created_at',extract(epoch from v_now - interval '1 hour')::bigint,
          'notes',jsonb_build_object('business_id',v_b::text))))),
    repeat('b',64));
  v_result := public.apply_razorpay_billing_event_v755('v760_evt_b_charged');
  if v_result->>'status' <> 'processed' then
    raise exception
      'E1: the second business sharing the customer id was rejected: %', v_result;
  end if;

  select count(*) into v_count
    from public.billing_provider_customers
   where provider_customer_id = v_shared_customer and business_id in (v_a,v_b);
  if v_count <> 2 then
    raise exception 'E1: expected two tenant rows on one customer id, found %', v_count;
  end if;

  select * into v_tenant from public.subscriptions where business_id=v_a;
  if v_tenant.payment_status <> 'paid' then
    raise exception 'E1: tenant A is % instead of paid', v_tenant.payment_status;
  end if;
  select * into v_tenant from public.subscriptions where business_id=v_b;
  if v_tenant.payment_status <> 'paid' then
    raise exception 'E1: tenant B is % instead of paid', v_tenant.payment_status;
  end if;
  raise notice 'E1 passed: two businesses share % and both are paid', v_shared_customer;

  -- ===========================================================================================
  -- E2 — a new customer id for the same business relinks, and says so in the audit log.
  -- ===========================================================================================
  perform public.ingest_billing_event_v755(
    'razorpay','v760_evt_c_first','subscription.authenticated','sub_v760_c',
    v_now - interval '3 hours', false,
    jsonb_build_object('entity','event','event','subscription.authenticated',
      'payload', jsonb_build_object('subscription', jsonb_build_object('entity',
        jsonb_build_object('id','sub_v760_c','plan_id',v_plan_id,'customer_id','cust_v760_c_old',
          'status','authenticated','quantity',1,
          'current_start',extract(epoch from v_now - interval '3 hours')::bigint,
          'current_end',extract(epoch from v_now + interval '27 days')::bigint,
          'charge_at',extract(epoch from v_now + interval '27 days')::bigint,
          'has_scheduled_changes',false,
          'notes',jsonb_build_object('business_id',v_c::text))))),
    repeat('c',64));
  v_result := public.apply_razorpay_billing_event_v755('v760_evt_c_first');
  if v_result->>'status' <> 'processed' then
    raise exception 'E2 fixture: the first C event did not process: %', v_result;
  end if;

  perform public.ingest_billing_event_v755(
    'razorpay','v760_evt_c_relink','subscription.activated','sub_v760_c',
    v_now - interval '1 hour', false,
    jsonb_build_object('entity','event','event','subscription.activated',
      'payload', jsonb_build_object('subscription', jsonb_build_object('entity',
        jsonb_build_object('id','sub_v760_c','plan_id',v_plan_id,'customer_id','cust_v760_c_new',
          'status','active','quantity',1,
          'current_start',extract(epoch from v_now - interval '1 hour')::bigint,
          'current_end',extract(epoch from v_now + interval '29 days')::bigint,
          'charge_at',extract(epoch from v_now + interval '29 days')::bigint,
          'has_scheduled_changes',false,
          'notes',jsonb_build_object('business_id',v_c::text))))),
    repeat('d',64));
  v_result := public.apply_razorpay_billing_event_v755('v760_evt_c_relink');
  if v_result->>'status' <> 'processed' then
    raise exception 'E2: the relinking event did not process: %', v_result;
  end if;

  select * into v_row from public.billing_provider_customers where business_id=v_c;
  if v_row.provider_customer_id <> 'cust_v760_c_new' then
    raise exception 'E2: the tenant still points at % instead of the new customer id',
      v_row.provider_customer_id;
  end if;

  select count(*) into v_count
    from public.audit_log audit
   where audit.business_id = v_c
     and audit.action = 'PROVIDER_CUSTOMER_RELINKED_V760';
  if v_count <> 1 then
    raise exception 'E2: expected exactly one relink audit row, found %', v_count;
  end if;
  select audit.detail into v_detail
    from public.audit_log audit
   where audit.business_id = v_c
     and audit.action = 'PROVIDER_CUSTOMER_RELINKED_V760'
   limit 1;
  if v_detail->>'previous_customer_id' <> 'cust_v760_c_old'
     or v_detail->>'customer_id' <> 'cust_v760_c_new'
     or v_detail->>'event_id' <> 'v760_evt_c_relink' then
    raise exception 'E2: the relink audit detail reads %', v_detail;
  end if;
  raise notice 'E2 passed: relinked cust_v760_c_old -> cust_v760_c_new, audited once';

  -- ===========================================================================================
  -- E3 — the subscription guard, deliberately untouched, still refuses a cross-tenant claim.
  -- ===========================================================================================
  insert into public.billing_provider_subscriptions(
    business_id,provider_customer_id,provider_subscription_id,status,currency,
    livemode,provider_event_created_at,provider_event_rank,last_event_id)
  values (
    v_other,'cust_v760_other','sub_v760_d','active','SGD',
    false,v_now - interval '10 hours',30,'v760_seed_other');

  perform public.ingest_billing_event_v755(
    'razorpay','v760_evt_d_blocked','subscription.activated','sub_v760_d',
    v_now - interval '30 minutes', false,
    jsonb_build_object('entity','event','event','subscription.activated',
      'payload', jsonb_build_object('subscription', jsonb_build_object('entity',
        jsonb_build_object('id','sub_v760_d','plan_id',v_plan_id,'customer_id',v_shared_customer,
          'status','active','quantity',1,
          'current_start',extract(epoch from v_now - interval '30 minutes')::bigint,
          'current_end',extract(epoch from v_now + interval '29 days')::bigint,
          'charge_at',extract(epoch from v_now + interval '29 days')::bigint,
          'has_scheduled_changes',false,
          'notes',jsonb_build_object('business_id',v_d::text))))),
    repeat('e',64));
  v_result := public.apply_razorpay_billing_event_v755('v760_evt_d_blocked');
  if v_result->>'status' <> 'failed' then
    raise exception
      'E3: a subscription already owned by another business was accepted: %', v_result;
  end if;
  if position('subscription is already linked to another business' in coalesce(v_result->>'error','')) = 0 then
    raise exception 'E3: the refusal names the wrong reason: %', v_result->>'error';
  end if;

  select processing_status into v_status
    from public.billing_provider_events
   where provider='razorpay' and event_id='v760_evt_d_blocked';
  if v_status <> 'failed' then
    raise exception 'E3: the blocked event is % instead of failed', v_status;
  end if;
  raise notice 'E3 passed: tenant isolation still lives on the subscription guard';

  -- ===========================================================================================
  -- E4 — the operator replays the failed event once the collision is gone.
  -- ===========================================================================================
  delete from public.billing_provider_subscriptions
   where provider_subscription_id='sub_v760_d' and business_id=v_other;

  v_redrive := public.redrive_razorpay_billing_events_v760(
    array['v760_evt_d_blocked','v760_evt_a_charged','v760_evt_missing']
  );
  if (v_redrive->>'processed')::integer <> 1
     or (v_redrive->>'skipped')::integer <> 2
     or (v_redrive->>'failed')::integer <> 0 then
    raise exception 'E4: the redrive summary reads %', v_redrive;
  end if;
  if v_redrive->'events'->0->>'status' <> 'processed' then
    raise exception 'E4: the failed event was not replayed: %', v_redrive->'events'->0;
  end if;
  if v_redrive->'events'->1->>'status' <> 'skipped'
     or v_redrive->'events'->1->>'processing_status' <> 'processed' then
    raise exception 'E4: an already-processed event was re-run: %', v_redrive->'events'->1;
  end if;
  if v_redrive->'events'->2->>'status' <> 'not_found' then
    raise exception 'E4: an unknown event id was not reported: %', v_redrive->'events'->2;
  end if;

  select processing_status into v_status
    from public.billing_provider_events
   where provider='razorpay' and event_id='v760_evt_d_blocked';
  if v_status <> 'processed' then
    raise exception 'E4: the redriven event is % instead of processed', v_status;
  end if;

  select count(*) into v_count
    from public.audit_log
   where action='RAZORPAY_EVENTS_REDRIVEN_V760';
  if v_count <> 1 then
    raise exception 'E4: the redrive left % audit rows instead of one', v_count;
  end if;
  raise notice 'E4 passed: redrive replayed one failed event and skipped the rest';

  -- ===========================================================================================
  -- E5 — the shape the fix rests on.
  -- ===========================================================================================
  select count(*) into v_count
    from pg_catalog.pg_constraint con
   where con.conrelid = 'public.billing_provider_customers'::regclass
     and con.contype = 'u'
     and (
       select array_agg(att.attname::text order by att.attname::text)
         from unnest(con.conkey) as key(attnum)
         join pg_catalog.pg_attribute att
           on att.attrelid = con.conrelid and att.attnum = key.attnum
     ) = array['provider_customer_id'];
  if v_count <> 0 then
    raise exception 'E5: provider_customer_id is still globally unique';
  end if;

  select count(*) into v_count
    from pg_catalog.pg_indexes
   where schemaname='public'
     and tablename='billing_provider_customers'
     and indexname='billing_provider_customers_provider_customer_idx';
  if v_count <> 1 then
    raise exception 'E5: the (provider, provider_customer_id) lookup index is missing';
  end if;

  select count(*) into v_count
    from pg_catalog.pg_constraint con
   where con.conrelid = 'public.billing_provider_customers'::regclass
     and con.contype = 'u'
     and (
       select array_agg(att.attname::text order by att.attname::text)
         from unnest(con.conkey) as key(attnum)
         join pg_catalog.pg_attribute att
           on att.attrelid = con.conrelid and att.attnum = key.attnum
     ) = array['business_id'];
  if v_count <> 1 then
    raise exception 'E5: one row per business is no longer enforced';
  end if;

  select count(*) into v_count
    from pg_catalog.pg_indexes
   where schemaname='public' and tablename='subscriptions'
     and indexname='subscriptions_provider_customer_uk';
  if v_count <> 0 then
    raise exception
      'E5: subscriptions still declares one tenant per Razorpay customer id';
  end if;
  select count(*) into v_count
    from pg_catalog.pg_indexes
   where schemaname='public' and tablename='subscriptions'
     and indexname='subscriptions_provider_subscription_uk';
  if v_count <> 1 then
    raise exception 'E5: one tenant per SUBSCRIPTION is no longer enforced';
  end if;
  raise notice 'E5 passed: global uniqueness gone, lookup index present, tenant key intact';

  raise notice 'v760 corpus passed: E1-E5';
end
$v760_test$;

rollback;
