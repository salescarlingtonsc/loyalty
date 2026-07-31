-- Rollback-only v95 customer Web Push acceptance.
begin;
\ir fixtures/pristine_chain_fixture.psql

create or replace function pg_temp.as_v95_user(p_uid uuid) returns void
language plpgsql as $$
begin
  execute 'set local role authenticated';
  perform set_config('request.jwt.claim.sub',p_uid::text,true);
  perform set_config('request.jwt.claims',
    jsonb_build_object('sub',p_uid,'role','authenticated')::text,true);
end
$$;
grant execute on function pg_temp.as_v95_user(uuid) to public;

do $v95$
declare
  v_business uuid; v_customer_a uuid:=gen_random_uuid(); v_customer_b uuid:=gen_random_uuid();
  v_identity_a uuid:=gen_random_uuid(); v_identity_b uuid:=gen_random_uuid();
  v_client_a uuid:=gen_random_uuid(); v_client_b uuid:=gen_random_uuid();
  v_link_a uuid:=gen_random_uuid(); v_link_b uuid:=gen_random_uuid();
  v_event uuid:=gen_random_uuid(); v_queued_event uuid:=gen_random_uuid();
  v_historical_event uuid:=gen_random_uuid(); v_optout_event uuid:=gen_random_uuid();
  v_quiet_event uuid:=gen_random_uuid(); v_ineligible_event uuid:=gen_random_uuid();
  v_worker uuid:=gen_random_uuid(); v_wrong_worker uuid:=gen_random_uuid();
  v_register_key uuid:=gen_random_uuid(); v_unregister_key uuid:=gen_random_uuid();
  v_report_key uuid:=gen_random_uuid(); v_subscription uuid; v_delivery uuid; v_lease uuid;
  v_response jsonb; v_claim jsonb;
  v_endpoint text:='https://fcm.googleapis.com/wp/'||replace(gen_random_uuid()::text,'-','');
  v_p256dh text:=repeat('A',87); v_auth text:=repeat('B',22);
  v_i integer;
begin
  reset role;
  select id into v_business from public.businesses order by created_at,id limit 1;
  if v_business is null then raise exception 'v95 requires one pristine business'; end if;
  insert into auth.users(instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at)
  values
    ('00000000-0000-0000-0000-000000000000',v_customer_a,'authenticated','authenticated','v95-a@example.test','',now(),now(),now()),
    ('00000000-0000-0000-0000-000000000000',v_customer_b,'authenticated','authenticated','v95-b@example.test','',now(),now(),now());
  insert into public.customer_identities(id,auth_user_id,status,created_via)
  values(v_identity_a,v_customer_a,'active','wallet_start'),
        (v_identity_b,v_customer_b,'active','wallet_start');
  insert into public.clients(id,business_id,full_name)
  values(v_client_a,v_business,'V95 customer A'),(v_client_b,v_business,'V95 customer B');
  perform set_config('app.customer_link_insert_id',v_link_a::text,true);
  insert into public.customer_links(
    id,business_id,identity_id,auth_user_id,client_id,state,verification_method,verified_at
  ) values(v_link_a,v_business,v_identity_a,v_customer_a,v_client_a,'verified','firm_invitation',now());
  perform set_config('app.customer_link_insert_id',v_link_b::text,true);
  insert into public.customer_links(
    id,business_id,identity_id,auth_user_id,client_id,state,verification_method,verified_at
  ) values(v_link_b,v_business,v_identity_b,v_customer_b,v_client_b,'verified','firm_invitation',now());
  perform set_config('app.customer_link_insert_id','',true);

  if not app.customer_push_endpoint_supported_v95('https://fcm.googleapis.com/wp/chrome_token_123')
     or not app.customer_push_endpoint_supported_v95('https://fcm.googleapis.com/fcm/send/legacy_chrome_token')
     or not app.customer_push_endpoint_supported_v95('https://updates.push.services.mozilla.com/wpush/v2/firefox_token')
     or not app.customer_push_endpoint_supported_v95('https://web.push.apple.com/QH_safari_token')
     or app.customer_push_endpoint_supported_v95('https://attacker.example.test/collect')
     or app.customer_push_endpoint_supported_v95('https://fcm.googleapis.com.attacker.test/wp/token')
     or app.customer_push_endpoint_supported_v95('https://attacker@fcm.googleapis.com/wp/token')
     or app.customer_push_endpoint_supported_v95('https://fcm.googleapis.com:443/wp/token')
     or app.customer_push_endpoint_supported_v95('http://fcm.googleapis.com/wp/token') then
    raise exception 'v95 supported browser push-service boundary drifted';
  end if;

  perform pg_temp.as_v95_user(v_customer_a);
  v_response:=public.customer_register_push_subscription_v95(
    v_endpoint,v_p256dh,v_auth,v_register_key
  );
  v_subscription:=(v_response->>'subscription_id')::uuid;
  if v_subscription is null or v_response->>'status'<>'active'
     or v_response ? 'endpoint' or v_response ? 'p256dh' or v_response ? 'auth' then
    raise exception 'v95 registration response exposed secret material or missed identity';
  end if;
  if public.customer_register_push_subscription_v95(
       v_endpoint,v_p256dh,v_auth,v_register_key
     ) is distinct from v_response then
    raise exception 'v95 exact registration replay drifted';
  end if;
  begin
    perform public.customer_register_push_subscription_v95(
      'https://fcm.googleapis.com/wp/changed_'||replace(gen_random_uuid()::text,'-',''),
      v_p256dh,v_auth,v_register_key
    );
    raise exception 'v95 registration idempotency mismatch was accepted';
  exception when data_exception then null;
  end;
  begin
    perform 1 from public.customer_push_subscriptions_v95;
    raise exception 'v95 customer read raw push endpoints';
  exception when insufficient_privilege then null;
  end;

  perform pg_temp.as_v95_user(v_customer_b);
  begin
    perform public.customer_register_push_subscription_v95(
      v_endpoint,v_p256dh,v_auth,gen_random_uuid()
    );
    raise exception 'v95 cross-customer endpoint takeover succeeded';
  exception when unique_violation then null;
  end;

  reset role;
  insert into public.customer_notification_preferences(
    business_id,identity_id,auth_user_id,link_id,client_id,channel,topic,opted_in,
    consent_at,quiet_hours_timezone,quiet_hours_start,quiet_hours_end
  ) values(
    v_business,v_identity_a,v_customer_a,v_link_a,v_client_a,'in_app','reward_ready',
    true,now(),null,null,null
  ),(
    v_business,v_identity_a,v_customer_a,v_link_a,v_client_a,'in_app','visit_progress',
    false,now(),null,null,null
  ),(
    v_business,v_identity_a,v_customer_a,v_link_a,v_client_a,'in_app','value_expiry',
    true,now(),'UTC',
    (timezone('UTC',statement_timestamp())-interval '1 hour')::time,
    (timezone('UTC',statement_timestamp())+interval '1 hour')::time
  );
  insert into public.customer_in_app_inbox_events(
    id,business_id,identity_id,auth_user_id,link_id,client_id,source_kind,topic,
    route_key,source_fingerprint,dedupe_key,title,body,created_at
  ) values(
    v_event,v_business,v_identity_a,v_customer_a,v_link_a,v_client_a,
    'c44_actionable_wallet','reward_ready','wallet_business',
    repeat('a',64),repeat('b',64),'Reward unlocked!',
    'Open this programme to view and redeem your reward.',clock_timestamp()
  ),(
    v_queued_event,v_business,v_identity_a,v_customer_a,v_link_a,v_client_a,
    'c44_actionable_wallet','reward_ready','wallet_business',
    repeat('e',64),repeat('f',64),'Reward unlocked!',
    'Open this programme to view and redeem your reward.',clock_timestamp()+interval '1 millisecond'
  ),(
    v_historical_event,v_business,v_identity_a,v_customer_a,v_link_a,v_client_a,
    'c44_actionable_wallet','reward_ready','wallet_business',
    repeat('1',64),repeat('2',64),'Reward unlocked!',
    'Open this programme to view and redeem your reward.',
    (select created_at-interval '1 second' from public.customer_push_subscriptions_v95 where id=v_subscription)
  ),(
    v_optout_event,v_business,v_identity_a,v_customer_a,v_link_a,v_client_a,
    'c44_actionable_wallet','visit_progress','wallet_business',
    repeat('3',64),repeat('4',64),'Quest almost complete',
    'One qualifying visit remains before your next reward.',clock_timestamp()
  ),(
    v_quiet_event,v_business,v_identity_a,v_customer_a,v_link_a,v_client_a,
    'c44_actionable_wallet','value_expiry','wallet_business',
    repeat('5',64),repeat('6',64),'Points expire within 3 days',
    'Open this programme now to review your expiring points.',clock_timestamp()
  ),(
    v_ineligible_event,v_business,v_identity_a,v_customer_a,v_link_a,v_client_a,
    'c44_actionable_wallet','booking_updates','wallet_business',
    repeat('c',64),repeat('d',64),'Appointment request received',
    'Open this business wallet to review your appointment request.',clock_timestamp()
  );
  if not app.customer_push_event_eligible_v95('c44_actionable_wallet','reward_ready')
     or app.customer_push_event_eligible_v95('c44_actionable_wallet','booking_updates')
     or app.customer_push_event_eligible_v95('promotion','marketing') then
    raise exception 'v95 finite six-event eligibility allowlist drifted';
  end if;

  set local role service_role;
  v_claim:=public.internal_customer_push_claim_v95(v_worker,1,60);
  if jsonb_array_length(v_claim)<>1
     or (v_claim->0->>'event_id')::uuid not in (v_event,v_queued_event)
     or v_claim->0->>'endpoint'<>v_endpoint
     or v_claim->0->>'business_slug' is null
     or v_claim->0 ? 'customer_name' or v_claim->0 ? 'phone' or v_claim->0 ? 'email' then
    raise exception 'v95 service claim did not return exactly one eligible delivery: %',v_claim;
  end if;
  v_delivery:=(v_claim->0->>'delivery_id')::uuid;
  v_lease:=(v_claim->0->>'lease_token')::uuid;
  begin
    perform public.internal_customer_push_report_v95(
      v_delivery,v_lease,v_wrong_worker,'sent',201,null,null,gen_random_uuid()
    );
    raise exception 'v95 wrong worker completed another lease';
  exception when serialization_failure then null;
  end;
  v_response:=public.internal_customer_push_report_v95(
    v_delivery,v_lease,v_worker,'sent',201,null,null,v_report_key
  );
  if v_response->>'status'<>'sent'
     or public.internal_customer_push_report_v95(
       v_delivery,v_lease,v_worker,'sent',201,null,null,v_report_key
     ) is distinct from v_response then
    raise exception 'v95 delivery result/replay is incorrect';
  end if;
  begin
    perform public.internal_customer_push_report_v95(
      v_delivery,v_lease,v_worker,'failed',400,'changed',null,v_report_key
    );
    raise exception 'v95 delivery result idempotency mismatch was accepted';
  exception when data_exception then null;
  end;

  -- The second eligible fact is already queued. A current opt-out must prevent
  -- it from being leased, just as opt-out and quiet hours prevented new rows.
  reset role;
  update public.customer_notification_preferences
     set opted_in=false,updated_at=now()
   where business_id=v_business and link_id=v_link_a
     and channel='in_app' and topic='reward_ready';
  set local role service_role;
  if jsonb_array_length(public.internal_customer_push_claim_v95(v_worker,10,60))<>0 then
    raise exception 'v95 leased queued work after the current topic opt-out';
  end if;

  reset role;
  perform pg_temp.as_v95_user(v_customer_b);
  if public.customer_unregister_push_subscription_v95(
       v_subscription,gen_random_uuid()
     )->>'status'<>'not_found' then
    raise exception 'v95 cross-customer unregister disclosed or changed the subscription';
  end if;
  perform pg_temp.as_v95_user(v_customer_a);
  v_response:=public.customer_unregister_push_subscription_v95(
    v_subscription,v_unregister_key
  );
  if v_response->>'status'<>'revoked'
     or public.customer_unregister_push_subscription_v95(
       v_subscription,v_unregister_key
     ) is distinct from v_response then
    raise exception 'v95 unregister/replay is incorrect';
  end if;

  -- Five active browser devices are retained. Registering a sixth atomically
  -- evicts the deterministic oldest `(updated_at,created_at,id)` subscription.
  for v_i in 1..6 loop
    v_response:=public.customer_register_push_subscription_v95(
      'https://updates.push.services.mozilla.com/wpush/v2/'||
        v_i::text||replace(gen_random_uuid()::text,'-',''),
      v_p256dh,v_auth,gen_random_uuid()
    );
  end loop;
  reset role;
  if (select count(*) from public.customer_push_subscriptions_v95
       where identity_id=v_identity_a and status='active')<>5
     or v_response->>'evicted_subscription_id' is null
     or not exists(
       select 1 from public.customer_push_subscriptions_v95
        where id=(v_response->>'evicted_subscription_id')::uuid and status='revoked'
     ) then
    raise exception 'v95 deterministic five-device cap failed: %',v_response;
  end if;
  perform pg_temp.as_v95_user(v_customer_a);
  for v_i in 1..12 loop
    perform public.customer_unregister_push_subscription_v95(
      gen_random_uuid(),gen_random_uuid()
    );
  end loop;
  begin
    perform public.customer_unregister_push_subscription_v95(
      gen_random_uuid(),gen_random_uuid()
    );
    raise exception 'v95 subscription operation abuse bypassed the bounded rate';
  exception when program_limit_exceeded then null;
  end;

  reset role;
  if has_function_privilege(
       'anon','public.customer_register_push_subscription_v95(text,text,text,uuid)','execute'
     )
     or has_function_privilege(
       'anon','public.customer_unregister_push_subscription_v95(uuid,uuid)','execute'
     )
     or has_function_privilege(
       'authenticated','public.internal_customer_push_claim_v95(uuid,integer,integer)','execute'
     )
     or not has_function_privilege(
       'service_role','public.internal_customer_push_claim_v95(uuid,integer,integer)','execute'
     )
     or not exists(
       select 1 from public.customer_push_delivery_results_v95
        where delivery_id=v_delivery and result='sent'
     )
     or exists(
       select 1 from public.customer_push_deliveries_v95
        where event_id in (v_historical_event,v_optout_event,v_quiet_event,v_ineligible_event)
     ) then
    raise exception 'v95 ACL, evidence, backfill, consent, quiet-hours, or eligibility contract failed';
  end if;
  raise notice 'v95 customer Web Push suite: ALL PASS';
end
$v95$;

rollback;
