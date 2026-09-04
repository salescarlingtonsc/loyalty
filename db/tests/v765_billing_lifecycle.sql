-- EXECUTED acceptance fixture for nestly_v765
-- (db/migrations/20261001_nestly_v765_billing_lifecycle.sql).
--
-- Run: LC_ALL=C node scripts/db-tests/run.mjs --filter=v765_corpus --migrated-only
--
-- WHY THIS EXISTS. The five owner rulings of 2026-09-05 all turn on the SAME failure mode: the
-- billing page telling the owner something the provider will not honour. A pro-rata figure that
-- is not what gets charged; a Resume button after the cancel has already gone out; a cycle change
-- with no date on it; a payments history that says "Subscription" for a branch charge. Every
-- assertion below exercises a path that only runs when money moves, so none of it has ever been
-- observed in production. The suite is rollback-only: it builds its own tenants, drives the real
-- Razorpay applier with synthetic payloads, and rolls everything back.
--
-- ASSERTIONS:
--   E1  preview_branch_addition_v764's proration is calendar days in Singapore, end-inclusive:
--       a mid-year day of a 365-day annual period prices at that fraction of the unit; a period
--       spanning 29 February has 366 days and prices against 366; and on the LAST day of the
--       period the preview is exactly one day, never zero and never negative.
--   E2  the renewal intent is set, cleared and re-set freely while it is local; once
--       mark_renewal_cancel_sent_v764 has run, BOTH directions of set_renewal_intent_v764 are
--       refused (22023) and cancel_at_period_end is true. mark_..._sent refuses a subscription
--       that never asked (fail closed).
--   E3  record_billing_schedule_v764 stores the cycle change with its effective date and price;
--       clear_billing_schedule_v764 reports cleared=true once and cleared=false on a repeat.
--   E4  a subscription.charged payload whose payment notes carry {reason,branch_id,branch_name,
--       covers_until} records them on billing_provider_invoices; a payload with NO notes takes
--       'initial' for the subscription's first invoice and 'renewal' for the next one.
--   E5  request_billing_command_v124 accepts 'update_card' and 'refresh_payment_method' for a
--       tenant WITH a provider subscription, and refuses both (22023) for one without.
--   E6  get_business_billing_v758 reports state='canceling' from the moment the intent is set
--       (not from the moment it is sent), carries renewal_cancel_final_after = period end minus
--       48 hours, exposes the scheduled_change block, and every invoices[] row carries the two
--       new keys.
--   E7  measured AS THE REAL ROLE: a signed-out caller and a caller who owns a DIFFERENT tenant
--       are both refused 42501 by preview_branch_addition_v764, set_renewal_intent_v764 and
--       refresh_payment_method_request_v764.

begin;

do $v765_test$
declare
  v_now timestamptz := now();
  v_biz uuid;
  v_owner uuid := gen_random_uuid();
  v_other_biz uuid;
  v_other_owner uuid := gen_random_uuid();
  v_bare_biz uuid;
  v_bare_owner uuid := gen_random_uuid();

  v_sub_id text := 'sub_v765fixture';
  v_plan_id text := 'plan_v765fixture';
  v_tier_amount integer;

  v_preview jsonb;
  v_result jsonb;
  v_payload jsonb;
  v_summary jsonb;
  v_invoice public.billing_provider_invoices%rowtype;
  v_subscription public.subscriptions%rowtype;
  v_expected integer;
  v_caught boolean;
  v_count integer;
  v_invoices jsonb;
begin
  -- ===========================================================================================
  -- Fixture · one priced, dated, card-bearing tenant.
  -- ===========================================================================================
  insert into public.businesses(name,slug,industry,enabled_modules)
  values('V765 lifecycle fixture','v765-life-'||substr(gen_random_uuid()::text,1,8),'test',
         array['dashboard','clients','sales','loyalty'])
  returning id into v_biz;
  insert into auth.users(id,email)
  values(v_owner,'v765-owner-'||substr(v_owner::text,1,8)||'@example.test')
  on conflict (id) do nothing;
  insert into public.staff(business_id,user_id,role,full_name,active,access_state)
  values(v_biz,v_owner,'owner','V765 owner',true,'approved');

  insert into public.subscriptions(business_id) values(v_biz)
  on conflict (business_id) do nothing;

  select tier.amount_cents into v_tier_amount
    from public.billing_capacity_tier_catalog_v664 tier
   where tier.currency='SGD' and tier.active and tier.cadence='annual'
     and tier.capacity_ceiling=10000
     and tier.effective_from <= now()
     and (tier.effective_to is null or tier.effective_to > now());
  if v_tier_amount is null then
    raise exception 'fixture: the annual 10,000 SGD tier is missing from the catalogue';
  end if;

  insert into public.billing_subscription_terms_v124(
    business_id,provider_subscription_id,cadence,customer_capacity,capacity_blocks,
    provider_base_price_id,provider_event_created_at,last_event_id
  ) values (
    v_biz,v_sub_id,'annual',10000,10,v_plan_id,v_now,'v765_fixture'
  );

  insert into public.billing_provider_customers(
    business_id,provider,provider_customer_id,currency,livemode,
    provider_event_created_at,provider_event_rank,last_event_id,
    payment_method_kind,payment_method_brand,payment_method_last4,payment_method_updated_at
  ) values (
    v_biz,'razorpay','cust_v765','SGD',false,v_now,1,'v765_fixture',
    'card','MasterCard','9037',v_now
  );

  -- ===========================================================================================
  -- E1 — the proration is calendar days, end-inclusive, and leap years are not special-cased.
  -- ===========================================================================================
  perform set_config('request.jwt.claims',
    json_build_object('sub',v_owner::text,'role','authenticated')::text, true);

  /* (a) A 365-day annual period whose end is 100 days away. 100 days remain COUNTING TODAY, so
     the fraction is 100/365 — the owner is charged for the day they switch the branch on. */
  perform set_config('request.jwt.claims','',true);
  update public.subscriptions
     set status='active', payment_status='paid', billing_cadence='annual', cadence_months=12,
         current_period_start = ((now() at time zone 'Asia/Singapore')::date - 265)
                                 ::timestamp at time zone 'Asia/Singapore',
         current_period_end = ((now() at time zone 'Asia/Singapore')::date + 99)
                                 ::timestamp at time zone 'Asia/Singapore',
         next_payment_at = ((now() at time zone 'Asia/Singapore')::date + 99)
                                 ::timestamp at time zone 'Asia/Singapore',
         provider_subscription_id = v_sub_id, provider_customer_id='cust_v765',
         billing_provider='razorpay', currency='SGD'
   where business_id=v_biz;
  perform set_config('request.jwt.claims',
    json_build_object('sub',v_owner::text,'role','authenticated')::text, true);

  v_preview := public.preview_branch_addition_v764(v_biz,'East Coast');
  if v_preview->>'status' <> 'ok' then
    raise exception 'E1a: the preview is unavailable: %', v_preview;
  end if;
  if (v_preview->>'period_days')::integer <> 364 then
    raise exception 'E1a: expected a 364-day span from -265 to +99, got %',
      v_preview->>'period_days';
  end if;
  if (v_preview->>'days_remaining')::integer <> 100 then
    raise exception 'E1a: expected 100 days remaining (end-inclusive), got %',
      v_preview->>'days_remaining';
  end if;
  v_expected := round(v_tier_amount::numeric * 100 / 364)::integer;
  if (v_preview->>'prorata_cents')::integer <> v_expected then
    raise exception 'E1a: pro-rata is % but 100/364 of % is %',
      v_preview->>'prorata_cents', v_tier_amount, v_expected;
  end if;
  if v_preview->'card'->>'last4' <> '9037'
     or v_preview->'card'->>'brand' <> 'MasterCard' then
    raise exception 'E1a: the confirmation would not name the card: %', v_preview->'card';
  end if;
  if coalesce((v_preview->>'estimate')::boolean,false) is not true then
    raise exception 'E1a: the preview does not declare itself an estimate';
  end if;
  if v_preview->>'branch_name' <> 'East Coast' then
    raise exception 'E1a: the branch name did not survive: %', v_preview->>'branch_name';
  end if;

  /* (b) A period that spans 29 February 2028 really has 366 days in it. The proration divides by
     the period's OWN length, so a leap year is arithmetic rather than a special case. */
  perform set_config('request.jwt.claims','',true);
  update public.subscriptions
     set current_period_start = timestamp '2027-06-01 00:00' at time zone 'Asia/Singapore',
         current_period_end = timestamp '2028-06-01 00:00' at time zone 'Asia/Singapore'
   where business_id=v_biz;
  perform set_config('request.jwt.claims',
    json_build_object('sub',v_owner::text,'role','authenticated')::text, true);
  v_preview := public.preview_branch_addition_v764(v_biz,'Leap');
  if (v_preview->>'period_days')::integer <> 366 then
    raise exception 'E1b: a period across 29 Feb 2028 measured % days',
      v_preview->>'period_days';
  end if;

  /* (c) On the LAST day of the period the answer is one day. Zero would mean a free branch and
     a negative number would mean a refund; both have been shipped by other billing systems. */
  perform set_config('request.jwt.claims','',true);
  update public.subscriptions
     set current_period_start = ((now() at time zone 'Asia/Singapore')::date - 364)
                                 ::timestamp at time zone 'Asia/Singapore',
         current_period_end = ((now() at time zone 'Asia/Singapore')::date)
                                 ::timestamp at time zone 'Asia/Singapore'
   where business_id=v_biz;
  perform set_config('request.jwt.claims',
    json_build_object('sub',v_owner::text,'role','authenticated')::text, true);
  v_preview := public.preview_branch_addition_v764(v_biz,'Last day');
  if (v_preview->>'days_remaining')::integer <> 1 then
    raise exception 'E1c: the last day of the period priced % days',
      v_preview->>'days_remaining';
  end if;
  v_expected := round(v_tier_amount::numeric * 1 / 364)::integer;
  if (v_preview->>'prorata_cents')::integer <> v_expected then
    raise exception 'E1c: the last day costs % rather than %',
      v_preview->>'prorata_cents', v_expected;
  end if;
  raise notice 'E1 passed: 100/364, leap 366, last day 1';

  -- Put the tenant back on a normal forward-looking period for the rest of the suite.
  perform set_config('request.jwt.claims','',true);
  update public.subscriptions
     set current_period_start = v_now - interval '65 days',
         current_period_end = v_now + interval '300 days',
         next_payment_at = v_now + interval '300 days'
   where business_id=v_biz;

  -- ===========================================================================================
  -- E2 — the intent is local and reversible, until it is not.
  -- ===========================================================================================
  perform set_config('request.jwt.claims',
    json_build_object('sub',v_owner::text,'role','authenticated')::text, true);

  v_result := public.set_renewal_intent_v764(v_biz,true);
  if v_result->>'cancel_requested' <> 'true'
     or v_result->>'renewal_cancel_requested_at' is null then
    raise exception 'E2: the cancel intent did not stick: %', v_result;
  end if;
  /* Asking twice is not an error and does not move the timestamp. */
  v_result := public.set_renewal_intent_v764(v_biz,true);
  if v_result->>'unchanged' <> 'true' then
    raise exception 'E2: a repeated cancel was treated as a change: %', v_result;
  end if;
  v_result := public.set_renewal_intent_v764(v_biz,false);
  if v_result->>'cancel_requested' <> 'false'
     or v_result->>'renewal_cancel_requested_at' is not null then
    raise exception 'E2: Resume did not clear the intent: %', v_result;
  end if;
  select * into v_subscription from public.subscriptions where business_id=v_biz;
  if v_subscription.renewal_cancel_sent_at is not null then
    raise exception 'E2: a purely local intent reached the provider';
  end if;

  /* Nothing may be marked sent that was never asked for. */
  perform set_config('request.jwt.claims','',true);
  v_caught := false;
  begin
    perform public.mark_renewal_cancel_sent_v764(v_biz,'rzp_test');
  exception when sqlstate '22023' then v_caught := true;
  end;
  if not v_caught then
    raise exception 'E2: a cancel was marked sent for a tenant that never asked';
  end if;

  perform set_config('request.jwt.claims',
    json_build_object('sub',v_owner::text,'role','authenticated')::text, true);
  perform public.set_renewal_intent_v764(v_biz,true);
  perform set_config('request.jwt.claims','',true);
  v_result := public.mark_renewal_cancel_sent_v764(v_biz,'rzp_cancel_ref');
  if v_result->>'unchanged' <> 'false' or v_result->>'renewal_cancel_sent_at' is null then
    raise exception 'E2: the send was not recorded: %', v_result;
  end if;
  select * into v_subscription from public.subscriptions where business_id=v_biz;
  if v_subscription.cancel_at_period_end is not true then
    raise exception 'E2: a sent cancel left cancel_at_period_end at %',
      v_subscription.cancel_at_period_end;
  end if;
  /* Sending twice is idempotent, not a second audit event. */
  v_result := public.mark_renewal_cancel_sent_v764(v_biz,'rzp_cancel_ref');
  if v_result->>'unchanged' <> 'true' then
    raise exception 'E2: a repeated send was treated as new: %', v_result;
  end if;

  /* And now BOTH directions are refused: the provider cannot undo it, so neither can we. */
  perform set_config('request.jwt.claims',
    json_build_object('sub',v_owner::text,'role','authenticated')::text, true);
  v_caught := false;
  begin
    perform public.set_renewal_intent_v764(v_biz,false);
  exception when sqlstate '22023' then v_caught := true;
  end;
  if not v_caught then
    raise exception 'E2: Resume was accepted after the cancel had been sent';
  end if;
  v_caught := false;
  begin
    perform public.set_renewal_intent_v764(v_biz,true);
  exception when sqlstate '22023' then v_caught := true;
  end;
  if not v_caught then
    raise exception 'E2: the intent was still writable after the cancel had been sent';
  end if;

  select count(*)::integer into v_count from public.audit_log
   where business_id=v_biz and action='RENEWAL_CANCEL_SENT_V764';
  if v_count <> 1 then
    raise exception 'E2: expected exactly one send audit row, found %', v_count;
  end if;
  raise notice 'E2 passed: local intent reversible, sent intent final, audited once';

  -- ===========================================================================================
  -- E3 — the scheduled cycle change, stored so the page can name the date and the price.
  -- ===========================================================================================
  perform set_config('request.jwt.claims','',true);
  v_result := public.record_billing_schedule_v764(
    v_biz,'cadence','monthly','plan_v765monthly', v_now + interval '300 days', 29600
  );
  if v_result->>'status' <> 'ok' then
    raise exception 'E3: the schedule was not recorded: %', v_result;
  end if;
  select * into v_subscription from public.subscriptions where business_id=v_biz;
  if v_subscription.scheduled_cadence <> 'monthly'
     or v_subscription.scheduled_plan_id <> 'plan_v765monthly'
     or v_subscription.scheduled_amount_cents <> 29600
     or v_subscription.scheduled_effective_at is null then
    raise exception 'E3: the stored schedule reads %/%/%/%',
      v_subscription.scheduled_cadence, v_subscription.scheduled_plan_id,
      v_subscription.scheduled_amount_cents, v_subscription.scheduled_effective_at;
  end if;

  v_caught := false;
  begin
    perform public.record_billing_schedule_v764(
      v_biz,'cadence','fortnightly',null,v_now + interval '10 days',100
    );
  exception when sqlstate '22023' then v_caught := true;
  end;
  if not v_caught then
    raise exception 'E3: an unsellable cadence was scheduled';
  end if;
  v_caught := false;
  begin
    perform public.record_billing_schedule_v764(
      v_biz,'capacity','monthly',null,v_now + interval '10 days',100
    );
  exception when sqlstate '22023' then v_caught := true;
  end;
  if not v_caught then
    raise exception 'E3: a non-cadence schedule kind was accepted';
  end if;

  v_result := public.clear_billing_schedule_v764(v_biz,'owner kept the annual cycle');
  if v_result->>'cleared' <> 'true' then
    raise exception 'E3: the first clear reported %', v_result;
  end if;
  v_result := public.clear_billing_schedule_v764(v_biz,'again');
  if v_result->>'cleared' <> 'false' then
    raise exception 'E3: clearing nothing reported a change: %', v_result;
  end if;
  select count(*)::integer into v_count from public.audit_log
   where business_id=v_biz and action='BILLING_SCHEDULE_CLEARED_V764';
  if v_count <> 1 then
    raise exception 'E3: expected one clear audit row, found %', v_count;
  end if;
  raise notice 'E3 passed: schedule recorded, refused, cleared once';

  -- ===========================================================================================
  -- E4 — an invoice says what it was for, from the provider's own notes.
  -- ===========================================================================================
  /* First invoice of this subscription, no notes at all -> 'initial'. */
  perform public.ingest_billing_event_v755(
    'razorpay','v765_evt_first','subscription.charged',v_sub_id,v_now - interval '3 hours',false,
    jsonb_build_object('entity','event','event','subscription.charged',
      'payload', jsonb_build_object(
        'subscription', jsonb_build_object('entity', jsonb_build_object(
          'id',v_sub_id,'plan_id',v_plan_id,'customer_id','cust_v765','status','active',
          'quantity',1,
          'current_start',extract(epoch from v_now - interval '3 hours')::bigint,
          'current_end',extract(epoch from v_now + interval '300 days')::bigint,
          'charge_at',extract(epoch from v_now + interval '300 days')::bigint,
          'has_scheduled_changes',false,
          'notes',jsonb_build_object('business_id',v_biz::text))),
        'payment', jsonb_build_object('entity', jsonb_build_object(
          'id','pay_v765_first','amount',v_tier_amount,'currency','SGD','status','captured',
          'invoice_id','inv_v765_first','method','card','captured',true,
          'card',jsonb_build_object('last4','9037','network','MasterCard','type','credit'),
          'created_at',extract(epoch from v_now - interval '3 hours')::bigint)))),
    repeat('1',64));
  v_result := public.apply_razorpay_billing_event_v755('v765_evt_first');
  if v_result->>'status' <> 'processed' then
    raise exception 'E4: the first charged event did not process: %', v_result;
  end if;
  select * into v_invoice from public.billing_provider_invoices
   where provider_invoice_id='inv_v765_first';
  if v_invoice.reason <> 'initial' then
    raise exception 'E4: a subscription''s first invoice reads reason=%', v_invoice.reason;
  end if;
  if v_invoice.detail->>'covers_until' is null then
    raise exception 'E4: the first invoice does not say what it covers: %', v_invoice.detail;
  end if;

  /* Second invoice, still no notes -> 'renewal', because it is no longer the first. */
  perform public.ingest_billing_event_v755(
    'razorpay','v765_evt_second','subscription.charged',v_sub_id,v_now - interval '2 hours',false,
    jsonb_build_object('entity','event','event','subscription.charged',
      'payload', jsonb_build_object(
        'subscription', jsonb_build_object('entity', jsonb_build_object(
          'id',v_sub_id,'plan_id',v_plan_id,'customer_id','cust_v765','status','active',
          'quantity',1,
          'current_start',extract(epoch from v_now - interval '2 hours')::bigint,
          'current_end',extract(epoch from v_now + interval '300 days')::bigint,
          'charge_at',extract(epoch from v_now + interval '300 days')::bigint,
          'has_scheduled_changes',false,
          'notes',jsonb_build_object('business_id',v_biz::text))),
        'payment', jsonb_build_object('entity', jsonb_build_object(
          'id','pay_v765_second','amount',v_tier_amount,'currency','SGD','status','captured',
          'invoice_id','inv_v765_second','method','card','captured',true,
          'created_at',extract(epoch from v_now - interval '2 hours')::bigint)))),
    repeat('2',64));
  v_result := public.apply_razorpay_billing_event_v755('v765_evt_second');
  if v_result->>'status' <> 'processed' then
    raise exception 'E4: the second charged event did not process: %', v_result;
  end if;
  select * into v_invoice from public.billing_provider_invoices
   where provider_invoice_id='inv_v765_second';
  if v_invoice.reason <> 'renewal' then
    raise exception 'E4: the second invoice reads reason=%', v_invoice.reason;
  end if;

  /* And an update invoice, whose notes say exactly which branch was added and until when. */
  perform public.ingest_billing_event_v755(
    'razorpay','v765_evt_branch','subscription.charged',v_sub_id,v_now - interval '1 hour',false,
    jsonb_build_object('entity','event','event','subscription.charged',
      'payload', jsonb_build_object(
        'subscription', jsonb_build_object('entity', jsonb_build_object(
          'id',v_sub_id,'plan_id',v_plan_id,'customer_id','cust_v765','status','active',
          'quantity',2,
          'current_start',extract(epoch from v_now - interval '65 days')::bigint,
          'current_end',extract(epoch from v_now + interval '300 days')::bigint,
          'charge_at',extract(epoch from v_now + interval '300 days')::bigint,
          'has_scheduled_changes',false,
          'notes',jsonb_build_object('business_id',v_biz::text))),
        'payment', jsonb_build_object('entity', jsonb_build_object(
          'id','pay_v765_branch','amount',40000,'currency','SGD','status','captured',
          'invoice_id','inv_v765_branch','method','card','captured',true,
          'created_at',extract(epoch from v_now - interval '1 hour')::bigint,
          'notes',jsonb_build_object(
            'reason','branch_added',
            'branch_id','11111111-2222-3333-4444-555555555555',
            'branch_name','East Coast',
            'covers_from','2027-03-05',
            'covers_until','2027-09-04'))))),
    repeat('3',64));
  v_result := public.apply_razorpay_billing_event_v755('v765_evt_branch');
  if v_result->>'status' <> 'processed' then
    raise exception 'E4: the branch charge did not process: %', v_result;
  end if;
  select * into v_invoice from public.billing_provider_invoices
   where provider_invoice_id='inv_v765_branch';
  if v_invoice.reason <> 'branch_added' then
    raise exception 'E4: the branch invoice reads reason=%', v_invoice.reason;
  end if;
  if v_invoice.detail->>'branch_name' <> 'East Coast'
     or v_invoice.detail->>'covers_until' <> '2027-09-04'
     or v_invoice.detail->>'covers_from' <> '2027-03-05'
     or v_invoice.detail->>'branch_id' <> '11111111-2222-3333-4444-555555555555' then
    raise exception 'E4: the payments-history line would read %', v_invoice.detail;
  end if;

  /* A hostile or unknown reason string is never trusted through to the column. */
  perform public.ingest_billing_event_v755(
    'razorpay','v765_evt_junk','subscription.charged',v_sub_id,v_now - interval '30 minutes',
    false,
    jsonb_build_object('entity','event','event','subscription.charged',
      'payload', jsonb_build_object(
        'subscription', jsonb_build_object('entity', jsonb_build_object(
          'id',v_sub_id,'plan_id',v_plan_id,'customer_id','cust_v765','status','active',
          'quantity',2,
          'current_start',extract(epoch from v_now - interval '65 days')::bigint,
          'current_end',extract(epoch from v_now + interval '300 days')::bigint,
          'has_scheduled_changes',false,
          'notes',jsonb_build_object('business_id',v_biz::text))),
        'payment', jsonb_build_object('entity', jsonb_build_object(
          'id','pay_v765_junk','amount',100,'currency','SGD','status','captured',
          'invoice_id','inv_v765_junk','method','card','captured',true,
          'created_at',extract(epoch from v_now - interval '30 minutes')::bigint,
          'notes',jsonb_build_object('reason','free_money_please'))))),
    repeat('4',64));
  v_result := public.apply_razorpay_billing_event_v755('v765_evt_junk');
  if v_result->>'status' <> 'processed' then
    raise exception 'E4: the junk-note charge did not process: %', v_result;
  end if;
  select * into v_invoice from public.billing_provider_invoices
   where provider_invoice_id='inv_v765_junk';
  if v_invoice.reason <> 'renewal' then
    raise exception 'E4: an unrecognised note produced reason=%', v_invoice.reason;
  end if;
  raise notice 'E4 passed: initial, renewal, branch_added from notes, junk rejected';

  -- ===========================================================================================
  -- E5 — the two new command types.
  -- ===========================================================================================
  perform set_config('request.jwt.claims',
    json_build_object('sub',v_owner::text,'role','authenticated')::text, true);
  v_result := public.request_billing_command_v124(
    v_biz,'update_card',null,null,gen_random_uuid()
  );
  if v_result->>'command_type' <> 'update_card' or v_result->>'command_id' is null then
    raise exception 'E5: update_card was not accepted: %', v_result;
  end if;
  v_result := public.request_billing_command_v124(
    v_biz,'refresh_payment_method',null,null,gen_random_uuid()
  );
  if v_result->>'command_type' <> 'refresh_payment_method' then
    raise exception 'E5: refresh_payment_method was not accepted: %', v_result;
  end if;

  /* A tenant with no provider subscription is refused HERE, not after being sent to a sheet. */
  perform set_config('request.jwt.claims','',true);
  insert into public.businesses(name,slug,industry,enabled_modules)
  values('V765 bare fixture','v765-bare-'||substr(gen_random_uuid()::text,1,8),'test',
         array['dashboard','clients'])
  returning id into v_bare_biz;
  insert into auth.users(id,email)
  values(v_bare_owner,'v765-bare-'||substr(v_bare_owner::text,1,8)||'@example.test')
  on conflict (id) do nothing;
  insert into public.staff(business_id,user_id,role,full_name,active,access_state)
  values(v_bare_biz,v_bare_owner,'owner','V765 bare owner',true,'approved');
  insert into public.subscriptions(business_id) values(v_bare_biz)
  on conflict (business_id) do nothing;

  perform set_config('request.jwt.claims',
    json_build_object('sub',v_bare_owner::text,'role','authenticated')::text, true);
  v_caught := false;
  begin
    perform public.request_billing_command_v124(
      v_bare_biz,'update_card',null,null,gen_random_uuid()
    );
  exception when sqlstate '22023' then v_caught := true;
  end;
  if not v_caught then
    raise exception 'E5: update_card was accepted with no provider subscription';
  end if;
  v_caught := false;
  begin
    perform public.request_billing_command_v124(
      v_bare_biz,'refresh_payment_method',null,null,gen_random_uuid()
    );
  exception when sqlstate '22023' then v_caught := true;
  end;
  if not v_caught then
    raise exception 'E5: refresh_payment_method was accepted with no provider subscription';
  end if;
  raise notice 'E5 passed: both new command types accepted, and refused without a subscription';

  -- ===========================================================================================
  -- E6 — the page can now say all of it.
  -- ===========================================================================================
  perform set_config('request.jwt.claims','',true);
  perform public.record_billing_schedule_v764(
    v_biz,'cadence','monthly','plan_v765monthly', v_now + interval '300 days', 29600
  );
  perform set_config('request.jwt.claims',
    json_build_object('sub',v_owner::text,'role','authenticated')::text, true);
  v_payload := public.get_business_billing_v758(v_biz);
  v_summary := v_payload->'summary';

  if v_summary->>'state' <> 'canceling' then
    raise exception 'E6: a cancelled renewal reads state=%', v_summary->>'state';
  end if;
  if v_summary->>'renewal_cancel_requested_at' is null
     or v_summary->>'renewal_cancel_sent_at' is null
     or v_summary->>'renewal_cancel_is_final' <> 'true' then
    raise exception 'E6: the renewal state is not reported: %', v_summary;
  end if;
  if (v_summary->>'renewal_cancel_final_after')::timestamptz
     <> (v_payload->>'current_period_end')::timestamptz - interval '48 hours' then
    raise exception 'E6: the final-after date is % against a period end of %',
      v_summary->>'renewal_cancel_final_after', v_payload->>'current_period_end';
  end if;
  if v_summary->'scheduled_change'->>'cadence' <> 'monthly'
     or (v_summary->'scheduled_change'->>'amount_cents')::integer <> 29600
     or v_summary->'scheduled_change'->>'effective_at' is null
     or v_summary->'scheduled_change'->>'plan_label' <> 'Monthly' then
    raise exception 'E6: the scheduled change would not render: %',
      v_summary->'scheduled_change';
  end if;

  v_invoices := v_payload->'invoices';
  if jsonb_typeof(v_invoices) <> 'array' or jsonb_array_length(v_invoices) < 4 then
    raise exception 'E6: expected the four fixture invoices, got %', v_invoices;
  end if;
  select count(*)::integer into v_count
    from jsonb_array_elements(v_invoices) row_json
   where row_json ? 'reason' and row_json ? 'detail';
  if v_count <> jsonb_array_length(v_invoices) then
    raise exception 'E6: only % of % invoice rows carry reason and detail',
      v_count, jsonb_array_length(v_invoices);
  end if;
  if not exists(
    select 1 from jsonb_array_elements(v_invoices) row_json
     where row_json->>'reason' = 'branch_added'
       and row_json->'detail'->>'branch_name' = 'East Coast'
  ) then
    raise exception 'E6: the branch charge is not identifiable in the payments history';
  end if;

  /* The digit refresh blanks the four digits and keeps the kind, so the page still says card. */
  v_result := public.refresh_payment_method_request_v764(v_biz);
  if v_result->>'refresh_requested' <> 'true' then
    raise exception 'E6: the refresh request was not accepted: %', v_result;
  end if;
  v_payload := public.get_business_billing_v758(v_biz);
  if v_payload->'payment_method'->>'kind' <> 'card'
     or v_payload->'payment_method'->>'last4' is not null then
    raise exception 'E6: after a refresh request the card reads %',
      v_payload->'payment_method';
  end if;
  raise notice 'E6 passed: canceling state, final-after date, scheduled change, invoice reasons';

  -- ===========================================================================================
  -- E7 fixture · a second tenant with its own owner, for the cross-tenant denial below.
  -- ===========================================================================================
  perform set_config('request.jwt.claims','',true);
  insert into public.businesses(name,slug,industry,enabled_modules)
  values('V765 other fixture','v765-other-'||substr(gen_random_uuid()::text,1,8),'test',
         array['dashboard','clients'])
  returning id into v_other_biz;
  insert into auth.users(id,email)
  values(v_other_owner,'v765-other-'||substr(v_other_owner::text,1,8)||'@example.test')
  on conflict (id) do nothing;
  insert into public.staff(business_id,user_id,role,full_name,active,access_state)
  values(v_other_biz,v_other_owner,'owner','V765 other owner',true,'approved');
  insert into public.subscriptions(business_id) values(v_other_biz)
  on conflict (business_id) do nothing;

  /* The other tenant's owner is a real, signed-in owner — of somewhere else. */
  perform set_config('request.jwt.claims',
    json_build_object('sub',v_other_owner::text,'role','authenticated')::text, true);
  v_caught := false;
  begin
    perform public.preview_branch_addition_v764(v_biz,'Not mine');
  exception when sqlstate '42501' then v_caught := true;
  end;
  if not v_caught then
    raise exception 'E7: another tenant''s owner previewed this tenant''s pricing';
  end if;
  v_caught := false;
  begin
    perform public.set_renewal_intent_v764(v_biz,true);
  exception when sqlstate '42501' then v_caught := true;
  end;
  if not v_caught then
    raise exception 'E7: another tenant''s owner cancelled this tenant''s renewal';
  end if;
  v_caught := false;
  begin
    perform public.refresh_payment_method_request_v764(v_biz);
  exception when sqlstate '42501' then v_caught := true;
  end;
  if not v_caught then
    raise exception 'E7: another tenant''s owner blanked this tenant''s card';
  end if;
  perform set_config('request.jwt.claims','',true);
  raise notice 'E7 passed: cross-tenant owner refused on all three owner RPCs';

  raise notice 'v765_corpus: E1-E7 passed';
end
$v765_test$;

/* And once more AS THE REAL ROLE. A guard checked only as the table owner proves nothing: RLS
   and SECURITY DEFINER both behave differently for the role that actually calls in. */
do $v765_denied$
declare
  v_denied boolean;
  v_biz uuid;
begin
  select id into v_biz from public.businesses order by created_at desc limit 1;

  set local role authenticated;
  v_denied := false;
  begin
    perform public.preview_branch_addition_v764(v_biz,'signed out');
  exception
    when sqlstate '42501' then v_denied := true;
    when sqlstate '22023' then v_denied := true;
  end;
  reset role;
  if not v_denied then
    raise exception 'E7b: a signed-out caller priced a branch for another tenant';
  end if;

  set local role authenticated;
  v_denied := false;
  begin
    perform public.set_renewal_intent_v764(v_biz,true);
  exception
    when sqlstate '42501' then v_denied := true;
    when sqlstate '22023' then v_denied := true;
  end;
  reset role;
  if not v_denied then
    raise exception 'E7b: a signed-out caller cancelled a renewal';
  end if;

  /* The service-role writers are not reachable from the browser roles at all. */
  set local role authenticated;
  v_denied := false;
  begin
    perform public.mark_renewal_cancel_sent_v764(v_biz,null);
  exception when others then v_denied := true;
  end;
  reset role;
  if not v_denied then
    raise exception 'E7b: an authenticated caller marked a renewal cancel sent';
  end if;

  set local role authenticated;
  v_denied := false;
  begin
    perform public.list_due_renewal_cancels_v764();
  exception when others then v_denied := true;
  end;
  reset role;
  if not v_denied then
    raise exception 'E7b: an authenticated caller read the due renewal-cancel list';
  end if;

  raise notice 'v765_corpus: E7b (denial as the real role) passed';
end
$v765_denied$;

rollback;
