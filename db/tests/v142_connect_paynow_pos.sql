-- V142 rollback-only financial-writer acceptance. Run after the complete
-- canonical chain in a disposable database. This executes tenant authority,
-- mode promotion, idempotency, provider envelopes, event order, one-sale
-- finalisation, QR lifetime and asynchronous refund terminal states.
begin;
\ir fixtures/pristine_chain_fixture.psql

create or replace function pg_temp.as_v142_user(
  p_uid uuid,
  p_role text default 'authenticated'
) returns void language plpgsql as $$
begin
  execute 'reset role';
  perform set_config('request.jwt.claim.sub','',true);
  perform set_config('request.jwt.claims','{}',true);
  execute format('set local role %I',p_role);
  perform set_config('request.jwt.claim.sub',coalesce(p_uid::text,''),true);
  perform set_config('request.jwt.claims',json_build_object(
    'sub',p_uid,'role',p_role
  )::text,true);
end
$$;
grant execute on function pg_temp.as_v142_user(uuid,text)
  to authenticated,service_role,anon;

do $v142_contract$
declare
  v_business uuid; v_other_business uuid; v_owner uuid; v_other_owner uuid;
  v_staff uuid; v_branch uuid; v_other_branch uuid; v_client uuid; v_service uuid;
  v_eval jsonb; v_command jsonb; v_attempt jsonb; v_replay jsonb; v_result jsonb;
  v_attempt_id uuid; v_eval_id uuid; v_sale uuid; v_key uuid; v_event_time timestamptz;
  v_initial_expiry timestamptz;
  v_pi text; v_event text; v_refund text; v_payload jsonb;
  v_denied boolean:=false; v_conflict boolean:=false; v_reserved boolean:=false;
  v_sales_before integer; v_points_before integer;
  browser_table_grants integer; service_only_failures integer;
begin
  reset role;
  select s.business_id,s.user_id,s.id into v_business,v_owner,v_staff
    from public.staff s join public.businesses b on b.id=s.business_id
   where b.name='Pristine chain fixture A' and s.role='owner' and s.active limit 1;
  select s.business_id,s.user_id into v_other_business,v_other_owner
    from public.staff s join public.businesses b on b.id=s.business_id
   where b.name='Pristine chain fixture B' and s.role='owner' and s.active limit 1;
  select id into v_branch from public.branches
   where business_id=v_business and active order by is_default desc,created_at limit 1;
  select id into v_other_branch from public.branches
   where business_id=v_other_business and active order by is_default desc,created_at limit 1;
  select id into v_client from public.clients where business_id=v_business order by created_at limit 1;
  insert into public.services(business_id,name,price_cents,duration_min,active)
  values(v_business,'Harbour lunch set',1000,30,true) returning id into v_service;
  if v_business is null or v_other_business is null or v_owner is null or v_staff is null
     or v_branch is null or v_other_branch is null or v_client is null then
    raise exception 'V142 realistic merchant fixtures are incomplete';
  end if;

  -- Browser roles never receive raw provider/event tables. Only bounded readers exist.
  select count(*) into browser_table_grants
    from information_schema.role_table_grants
   where table_schema='public'
     and table_name in ('merchant_payment_accounts_v142','merchant_payment_commands_v142',
                        'pos_payment_attempts_v142','stripe_connect_event_inbox_v142')
     and grantee in ('anon','authenticated');
  assert browser_table_grants=0,
    'V142 provider account, payment attempt or webhook tables leaked to a browser role';
  select count(*) into service_only_failures
    from information_schema.role_routine_grants
   where routine_schema='public'
     and routine_name in ('begin_merchant_connect_command_v142','complete_merchant_connect_command_v142',
       'sync_merchant_payment_account_v142','begin_pos_paynow_attempt_v142',
       'attach_pos_paynow_intent_v142','activate_pos_paynow_qr_v142','ingest_stripe_connect_event_v142',
       'apply_stripe_connect_payment_event_v142','apply_stripe_connect_refund_event_v142',
       'mark_pos_paynow_refund_state_v142')
     and grantee in ('anon','authenticated');
  assert service_only_failures=0,'V142 provider mutation authority leaked to a browser role';

  -- Test mode can be rehearsed, then explicitly promoted to a new live object.
  perform pg_temp.as_v142_user(null,'service_role');
  v_command:=public.begin_merchant_connect_command_v142(v_business,v_owner,gen_random_uuid(),false);
  assert v_command->>'provider_account_id' is null and not (v_command->>'livemode')::boolean,
    'first test-mode command unexpectedly reused an account';
  perform public.complete_merchant_connect_command_v142(
    (v_command->>'command_id')::uuid,'acct_v142testA',false,true,true,true,'active','[]','[]',null);
  v_command:=public.begin_merchant_connect_command_v142(v_business,v_owner,gen_random_uuid(),true);
  assert v_command->>'provider_account_id' is null and (v_command->>'livemode')::boolean,
    'live command attempted to retrieve a test-mode Stripe object';
  perform public.complete_merchant_connect_command_v142(
    (v_command->>'command_id')::uuid,'acct_v142liveA',true,true,true,true,'active','[]','[]',null);
  reset role;
  assert (select livemode and provider_account_id='acct_v142liveA'
            from public.merchant_payment_accounts_v142 where business_id=v_business),
    'guarded test-to-live account promotion did not bind the live object';
  perform pg_temp.as_v142_user(null,'service_role');
  begin
    perform public.begin_merchant_connect_command_v142(v_business,v_owner,gen_random_uuid(),false);
  exception when unique_violation then v_conflict:=true;
  end;
  reset role;
  assert v_conflict,'a live merchant binding was downgraded to a test account';

  -- Owner A prices an exact SGD 10 service; service authority mints one PayNow
  -- snapshot that lasts beyond Stripe's documented one-hour QR lifetime.
  perform pg_temp.as_v142_user(v_owner);
  v_eval:=public.evaluate_checkout(v_business,v_branch,v_client,jsonb_build_array(
    jsonb_build_object('catalog_kind','service','catalog_id',v_service,'qty',1)),gen_random_uuid());
  v_eval_id:=(v_eval->>'evaluation_id')::uuid; v_key:=gen_random_uuid();
  perform pg_temp.as_v142_user(null,'service_role');
  v_attempt:=public.begin_pos_paynow_attempt_v142(
    v_business,v_branch,v_client,v_staff,v_eval_id,v_owner,v_key,true);
  v_attempt_id:=(v_attempt->>'attempt_id')::uuid;
  v_initial_expiry:=(v_attempt->>'expires_at')::timestamptz;
  assert (v_attempt->>'amount_cents')::integer=1000 and v_attempt->>'currency'='SGD',
    'PayNow attempt did not freeze the server-authoritative SGD 10 total';
  assert (v_attempt->>'expires_at')::timestamptz between now()+interval '60 minutes'
                                                  and now()+interval '62 minutes',
    'PayNow evaluation does not cover the provider QR lifetime';
  v_replay:=public.begin_pos_paynow_attempt_v142(
    v_business,v_branch,v_client,v_staff,v_eval_id,v_owner,v_key,true);
  assert v_replay->>'attempt_id'=v_attempt->>'attempt_id',
    'same POS idempotency key created another payment attempt';
  v_replay:=public.begin_pos_paynow_attempt_v142(
    v_business,v_branch,v_client,v_staff,v_eval_id,v_owner,gen_random_uuid(),true);
  assert v_replay->>'attempt_id'=v_attempt->>'attempt_id',
    'lost local retry key created another attempt for the same checkout evaluation';
  reset role;
  assert (select count(*) from public.pos_payment_attempts_v142
           where evaluation_id=v_eval_id)=1,
    'one checkout evaluation minted more than one PayNow attempt';
  assert (select e.expires_at=a.expires_at and e.total_cents=1000
            from public.pos_payment_attempts_v142 a
            join public.checkout_evaluations e on e.id=a.evaluation_id
           where a.id=v_attempt_id),
    'PayNow reservation does not hold the original immutable amount/lifetime';

  -- After provider checkout begins, the original evaluation is reserved.
  -- A second staff tab cannot finalize it as cash while the QR is payable.
  select count(*) into v_sales_before from public.sales where business_id=v_business;
  select count(*) into v_points_before from public.points_ledger
   where business_id=v_business and client_id=v_client;
  perform pg_temp.as_v142_user(v_owner);
  begin
    perform public.record_cart_sale(v_business,v_client,v_branch,v_staff,'cash',
      'v142-direct-race-'||v_attempt_id::text,null,v_eval_id,true);
  exception when restrict_violation then v_reserved:=true;
  end;
  reset role;
  assert v_reserved,'provider-reserved checkout was still consumable from another sale path';
  assert (select count(*) from public.sales where business_id=v_business)=v_sales_before,
    'blocked direct finalization left a sale or loyalty side effect';
  assert (select count(*) from public.points_ledger
           where business_id=v_business and client_id=v_client)=v_points_before,
    'blocked direct finalization left a points-ledger side effect';

  -- Cross-tenant staff/branch authority is denied before provider creation.
  perform pg_temp.as_v142_user(null,'service_role');
  begin
    perform public.begin_pos_paynow_attempt_v142(
      v_business,v_other_branch,v_client,v_staff,v_eval_id,v_other_owner,gen_random_uuid(),true);
  exception when insufficient_privilege then v_denied:=true;
  end;
  reset role;
  assert v_denied,'another tenant could mint a merchant payment attempt';

  -- A signed exact provider success creates one sale and loyalty ledger effect.
  v_pi:='pi_v142exactA'; v_event:='evt_v142exactA'; v_event_time:=now();
  perform pg_temp.as_v142_user(null,'service_role');
  perform public.attach_pos_paynow_intent_v142(v_attempt_id,'acct_v142liveA',v_pi,'requires_action');
  perform pg_sleep(0.02);
  v_result:=public.activate_pos_paynow_qr_v142(v_attempt_id,'acct_v142liveA',v_pi);
  assert (v_result->>'expires_at')::timestamptz>v_initial_expiry
     and (select qr_activated_at is not null from public.pos_payment_attempts_v142 where id=v_attempt_id),
    'delayed provider QR observation did not refresh the held evaluation lifetime';
  v_payload:=jsonb_build_object('data',jsonb_build_object('object',jsonb_build_object(
    'id',v_pi,'amount',1000,'currency','sgd','status','succeeded','metadata',jsonb_build_object(
      'peekaa_pos_attempt_id',v_attempt_id,'peekaa_business_id',v_business))));
  v_result:=public.ingest_stripe_connect_event_v142(v_event,'acct_v142liveA',
    'payment_intent.succeeded',v_pi,true,v_event_time,v_payload,repeat('a',64));
  assert not (v_result->>'duplicate')::boolean,'first signed payment event was labelled duplicate';
  v_result:=public.apply_stripe_connect_payment_event_v142(v_event);
  v_sale:=(v_result->>'sale_id')::uuid;
  reset role;
  assert v_result->>'status'='succeeded' and v_sale is not null,
    'matching payment success did not produce a receipt sale';
  assert (select count(*) from public.sales where id=v_sale and amount_cents=1000)=1,
    'matching payment success did not persist exactly one SGD 10 sale';
  assert (select count(*) from public.sale_items where sale_id=v_sale)>0,
    'receipt sale did not persist its item projection';
  assert (select count(*) from public.points_ledger
           where business_id=v_business and client_id=v_client)=v_points_before+1
     and (select coalesce(sum(points),0) from public.points_ledger where sale_id=v_sale)=10,
    'matching payment success did not persist exactly one 10-point earn effect';

  -- Exact duplicate and older event cannot add a second sale or ledger effect.
  select count(*) into v_sales_before from public.sales where business_id=v_business;
  perform pg_temp.as_v142_user(null,'service_role');
  v_result:=public.ingest_stripe_connect_event_v142(v_event,'acct_v142liveA',
    'payment_intent.succeeded',v_pi,true,v_event_time,v_payload,repeat('a',64));
  assert (v_result->>'duplicate')::boolean,'same signed event was not recognized as duplicate';
  perform public.apply_stripe_connect_payment_event_v142(v_event);
  perform public.ingest_stripe_connect_event_v142('evt_v142olderA','acct_v142liveA',
    'payment_intent.processing',v_pi,true,v_event_time-interval '1 second',
    jsonb_build_object('data',jsonb_build_object('object',jsonb_build_object(
      'id',v_pi,'amount',1000,'currency','sgd','status','processing','metadata',jsonb_build_object(
      'peekaa_pos_attempt_id',v_attempt_id,'peekaa_business_id',v_business)))),repeat('b',64));
  perform public.apply_stripe_connect_payment_event_v142('evt_v142olderA');
  reset role;
  assert (select count(*) from public.sales where business_id=v_business)=v_sales_before,
    'duplicate or out-of-order provider event created another sale';
  assert (select status from public.pos_payment_attempts_v142 where id=v_attempt_id)='succeeded',
    'older provider event downgraded a succeeded payment';

  -- A mismatched paid envelope never creates a receipt. Refund creation remains
  -- pending until a later signed refund.updated confirms terminal success.
  perform pg_temp.as_v142_user(v_owner);
  v_eval:=public.evaluate_checkout(v_business,v_branch,v_client,jsonb_build_array(
    jsonb_build_object('catalog_kind','service','catalog_id',v_service,'qty',1)),gen_random_uuid());
  v_eval_id:=(v_eval->>'evaluation_id')::uuid;
  perform pg_temp.as_v142_user(null,'service_role');
  v_attempt:=public.begin_pos_paynow_attempt_v142(
    v_business,v_branch,v_client,v_staff,v_eval_id,v_owner,gen_random_uuid(),true);
  v_attempt_id:=(v_attempt->>'attempt_id')::uuid; v_pi:='pi_v142refundA'; v_event:='evt_v142refundA';
  perform public.attach_pos_paynow_intent_v142(v_attempt_id,'acct_v142liveA',v_pi,'requires_action');
  v_payload:=jsonb_build_object('data',jsonb_build_object('object',jsonb_build_object(
    'id',v_pi,'amount',999,'currency','sgd','status','succeeded','metadata',jsonb_build_object(
      'peekaa_pos_attempt_id',v_attempt_id,'peekaa_business_id',v_business))));
  perform public.ingest_stripe_connect_event_v142(v_event,'acct_v142liveA',
    'payment_intent.succeeded',v_pi,true,now(),v_payload,repeat('c',64));
  v_result:=public.apply_stripe_connect_payment_event_v142(v_event);
  assert v_result->>'status'='refund_required','mismatched paid amount was not quarantined for refund';
  v_refund:='re_v142pendingA';
  v_result:=public.mark_pos_paynow_refund_state_v142(
    v_attempt_id,v_event,v_refund,'pending',null);
  assert v_result->>'status'='refund_pending','asynchronous refund was falsely marked complete';
  perform public.ingest_stripe_connect_event_v142('evt_v142refundUpdatedA','acct_v142liveA',
    'refund.updated',v_refund,true,now()+interval '1 second',jsonb_build_object(
      'data',jsonb_build_object('object',jsonb_build_object('id',v_refund,'amount',1000,
      'currency','sgd','status','succeeded','payment_intent',v_pi,'metadata',jsonb_build_object(
      'peekaa_pos_attempt_id',v_attempt_id)))),repeat('d',64));
  v_result:=public.apply_stripe_connect_refund_event_v142('evt_v142refundUpdatedA');
  reset role;
  assert v_result->>'status'='refunded'
     and (select status from public.pos_payment_attempts_v142 where id=v_attempt_id)='refunded',
    'signed refund.updated success did not become the only refunded truth';
  assert (select sale_id is null from public.pos_payment_attempts_v142 where id=v_attempt_id),
    'mismatched provider payment produced a sale before refund';

  -- A signed refund.failed remains manual-action truth; it is never shown as refunded.
  perform pg_temp.as_v142_user(v_owner);
  v_eval:=public.evaluate_checkout(v_business,v_branch,v_client,jsonb_build_array(
    jsonb_build_object('catalog_kind','service','catalog_id',v_service,'qty',1)),gen_random_uuid());
  v_eval_id:=(v_eval->>'evaluation_id')::uuid;
  perform pg_temp.as_v142_user(null,'service_role');
  v_attempt:=public.begin_pos_paynow_attempt_v142(
    v_business,v_branch,v_client,v_staff,v_eval_id,v_owner,gen_random_uuid(),true);
  v_attempt_id:=(v_attempt->>'attempt_id')::uuid; v_pi:='pi_v142refundFail'; v_event:='evt_v142refundFail';
  perform public.attach_pos_paynow_intent_v142(v_attempt_id,'acct_v142liveA',v_pi,'requires_action');
  v_payload:=jsonb_build_object('data',jsonb_build_object('object',jsonb_build_object(
    'id',v_pi,'amount',999,'currency','sgd','status','succeeded','metadata',jsonb_build_object(
      'peekaa_pos_attempt_id',v_attempt_id,'peekaa_business_id',v_business))));
  perform public.ingest_stripe_connect_event_v142(v_event,'acct_v142liveA',
    'payment_intent.succeeded',v_pi,true,now(),v_payload,repeat('e',64));
  perform public.apply_stripe_connect_payment_event_v142(v_event);
  v_refund:='re_v142failedA';
  perform public.mark_pos_paynow_refund_state_v142(v_attempt_id,v_event,v_refund,'pending',null);
  perform public.ingest_stripe_connect_event_v142('evt_v142refundFailedA','acct_v142liveA',
    'refund.failed',v_refund,true,now()+interval '1 second',jsonb_build_object(
      'data',jsonb_build_object('object',jsonb_build_object('id',v_refund,'amount',1000,
      'currency','sgd','status','failed','failure_reason','lost_or_stolen_card',
      'payment_intent',v_pi,'metadata',jsonb_build_object('peekaa_pos_attempt_id',v_attempt_id)))),repeat('f',64));
  v_result:=public.apply_stripe_connect_refund_event_v142('evt_v142refundFailedA');
  perform public.mark_pos_paynow_refund_state_v142(
    v_attempt_id,v_event,v_refund,'pending',null);
  reset role;
  assert v_result->>'status'='refund_failed'
     and (select status from public.pos_payment_attempts_v142 where id=v_attempt_id)='refund_failed'
     and (select refund_failure_reason from public.pos_payment_attempts_v142 where id=v_attempt_id)
       ='lost_or_stolen_card',
    'delayed refunds.create response downgraded a signed refund failure';

  -- A success timestamp after the held QR/evaluation window is quarantined,
  -- proving event time (not processing time) controls late-payment handling.
  perform pg_temp.as_v142_user(v_owner);
  v_eval:=public.evaluate_checkout(v_business,v_branch,v_client,jsonb_build_array(
    jsonb_build_object('catalog_kind','service','catalog_id',v_service,'qty',1)),gen_random_uuid());
  v_eval_id:=(v_eval->>'evaluation_id')::uuid;
  perform pg_temp.as_v142_user(null,'service_role');
  v_attempt:=public.begin_pos_paynow_attempt_v142(
    v_business,v_branch,v_client,v_staff,v_eval_id,v_owner,gen_random_uuid(),true);
  v_attempt_id:=(v_attempt->>'attempt_id')::uuid; v_pi:='pi_v142lateA';
  perform public.attach_pos_paynow_intent_v142(v_attempt_id,'acct_v142liveA',v_pi,'requires_action');
  reset role;
  update public.pos_payment_attempts_v142 set expires_at=now()-interval '1 second' where id=v_attempt_id;
  perform pg_temp.as_v142_user(null,'service_role');
  v_payload:=jsonb_build_object('data',jsonb_build_object('object',jsonb_build_object(
    'id',v_pi,'amount',1000,'currency','sgd','status','succeeded','metadata',jsonb_build_object(
      'peekaa_pos_attempt_id',v_attempt_id,'peekaa_business_id',v_business))));
  perform public.ingest_stripe_connect_event_v142('evt_v142lateA','acct_v142liveA',
    'payment_intent.succeeded',v_pi,true,now(),v_payload,repeat('1',64));
  v_result:=public.apply_stripe_connect_payment_event_v142('evt_v142lateA');
  reset role;
  assert v_result->>'status'='refund_required'
     and (select sale_id is null from public.pos_payment_attempts_v142 where id=v_attempt_id),
    'provider success after the held window created a sale instead of refund quarantine';

  -- Bounded reader is tenant-safe.
  v_denied:=false;
  perform pg_temp.as_v142_user(v_other_owner);
  begin
    perform public.get_pos_paynow_attempt_v142(v_attempt_id);
  exception when insufficient_privilege then v_denied:=true;
  end;
  reset role;
  assert v_denied,'another tenant read a private merchant payment attempt';
end
$v142_contract$;

rollback;
