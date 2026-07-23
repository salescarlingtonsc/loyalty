-- Rollback-only v56 PS-1B events / entitlement-execution / outbox / shadow suite.
-- Run after v56 in a disposable rehearsal database. Covers the owner's list:
-- replay, idempotency, permission, dead-letter, promise-preservation,
-- double-fulfilment, synthetic-recipient CHECK, shadow-never-writes, comparator.
begin;
\ir fixtures/pristine_chain_fixture.psql

create or replace function pg_temp.as_v56_principal(p_uid uuid, p_role text)
returns void language plpgsql as $$
begin
  execute 'reset role';
  perform set_config('request.jwt.claim.sub','',true);
  perform set_config('request.jwt.claims','',true);
  if p_role='anon' then
    execute 'set local role anon';
    perform set_config('request.jwt.claims',json_build_object('role','anon')::text,true);
  elsif p_role='authenticated' and p_uid is not null then
    execute 'set local role authenticated';
    perform set_config('request.jwt.claim.sub',p_uid::text,true);
    perform set_config('request.jwt.claims',json_build_object('sub',p_uid,'role','authenticated')::text,true);
  else
    raise exception 'unsupported v56 principal';
  end if;
end $$;
grant execute on function pg_temp.as_v56_principal(uuid,text) to authenticated, anon;

do $v56_test$
declare
  v_business uuid; v_owner uuid; v_owner_staff uuid; v_client uuid; v_client2 uuid; v_branch uuid;
  v_biz_b uuid; v_owner_b uuid; v_base uuid; v_service uuid;
  v_draft uuid; v_hash text; v_rule uuid; v_result jsonb; v_ent uuid; v_ent2 uuid;
  v_evt uuid; v_evt2 uuid; v_evt3 uuid; v_ob uuid; v_dupkey text; v_n integer; v_before text; v_after text;
  v_shadow_before integer; v_manager uuid := gen_random_uuid(); v_cmp jsonb; v_xten uuid := gen_random_uuid();
begin
  reset role;
  select s.business_id,s.user_id,s.id into v_business,v_owner,v_owner_staff
    from public.staff s join public.businesses b on b.id=s.business_id
   where s.role='owner' and s.active and s.user_id is not null and b.name='Pristine chain fixture A'
   order by s.created_at limit 1;
  select s.business_id,s.user_id into v_biz_b,v_owner_b
    from public.staff s join public.businesses b on b.id=s.business_id
   where s.role='owner' and s.active and s.user_id is not null and b.name='Pristine chain fixture B'
   order by s.created_at limit 1;
  if v_business is null or v_biz_b is null then raise exception 'v56 needs both fixture businesses'; end if;
  select id into v_client from public.clients where business_id=v_business order by created_at limit 1;
  select id into v_branch from public.branches where business_id=v_business and active order by is_default desc, created_at limit 1;
  select active_config_version_id into v_base from public.businesses where id=v_business;
  insert into public.clients(business_id,full_name,phone) values(v_business,'v56 second','+6590000055') returning id into v_client2;
  insert into public.services(business_id,name,price_cents,duration_min) values(v_business,'v56 free service',1500,30) returning id into v_service;

  -- ---- 1. Registry transitions applied (authority NEVER changed). ----
  if (select cutover_status from public.benefit_registry where business_id=v_business and source_engine='referral')<>'shadow'
     or (select execution_authority from public.benefit_registry where business_id=v_business and source_engine='referral')<>'legacy_trigger' then
    raise exception 'referral did not enter shadow with legacy authority preserved';
  end if;
  if (select cutover_status from public.benefit_registry where business_id=v_business and source_engine='recurring')<>'studio'
     or (select execution_authority from public.benefit_registry where business_id=v_business and source_engine='recurring')<>'studio_executor' then
    raise exception 'recurring did not become studio-active with studio authority preserved';
  end if;
  begin
    update public.benefit_registry set execution_authority='studio_executor'
      where business_id=v_business and source_engine='referral';
    raise exception 'referral execution authority was mutable';
  exception when restrict_violation then null; end;

  -- ---- 2. Author + publish a studio rule (grant_free_item, cap = one grant). ----
  perform pg_temp.as_v56_principal(v_owner,'authenticated');
  v_draft := (public.create_loyalty_config_draft(v_business,v_base,'v56_rule')::jsonb->>'version_id')::uuid;
  select snapshot_hash into v_hash from public.firm_config_versions where id=v_draft;
  v_rule := gen_random_uuid();
  perform public.save_program_rule_draft(v_draft, v_rule, jsonb_build_object(
    'name','Free service on visit','when_event','sale.completed','active',true,
    'if_conditions', jsonb_build_array(jsonb_build_object('field','amount_cents','op','gte','value',100)),
    'then_effects', jsonb_build_array(
       jsonb_build_object('effect_type','grant_free_item','catalog_kind','service','catalog_id',v_service),
       jsonb_build_object('effect_type','send_notification','note','enjoy')),
    'with_params', jsonb_build_object('budget_cap_cents',1500,'budget_period','monthly','entitlement_expiry_days',30)), v_hash);
  perform public.publish_loyalty_config(v_draft);
  if not exists(select 1 from public.program_rules_compiled where rule_id=v_rule and config_version_id=v_draft and when_event='sale.completed') then
    raise exception 'rule did not compile into the executor surface';
  end if;

  -- ---- 3. Producer + replay: a sale emits sale.completed once, re-emit swallowed. ----
  perform public.record_quick_sale(v_business,5000,'cash',v_client,v_owner_staff,v_branch,'v56 c1','v56-c1-'||substr(md5(clock_timestamp()::text),1,10),true);
  select event_id into v_evt from public.domain_events where business_id=v_business and event_type='sale.completed' and subject_client_id=v_client order by recorded_at desc limit 1;
  if v_evt is null then raise exception 'sale.completed event was not produced'; end if;
  reset role;
  if app.emit_domain_event(v_business,'sale.completed', (select source_operation_id from public.domain_events where event_id=v_evt), v_client, null, now(), v_base, '{}'::jsonb) is not null then
    raise exception 'event re-emit was not swallowed by producer identity';
  end if;
  if (select count(*) from public.domain_events where event_id=v_evt)<>1 then raise exception 'duplicate event row'; end if;

  -- ---- 4. Executor materialises the entitlement + fulfilment; replay is a no-op. ----
  perform app.run_studio_executor(500);
  select id into v_ent from public.program_entitlements where business_id=v_business and client_id=v_client and rule_id=v_rule;
  if v_ent is null then raise exception 'executor did not materialise the claimable entitlement'; end if;
  if not exists(select 1 from public.benefit_fulfilments f where f.business_id=v_business and f.source_engine='recurring' and f.client_id=v_client) then
    raise exception 'executor did not write the fulfilment registry row';
  end if;
  if not exists(select 1 from public.rule_effect_log where event_id=v_evt and rule_id=v_rule and outcome='fulfilled') then
    raise exception 'executor did not log a fulfilled effect';
  end if;
  if not exists(select 1 from public.event_outbox where event_id=v_evt and consumer='comms') then
    raise exception 'send_notification did not enqueue an outbox row';
  end if;
  select count(*) into v_n from public.rule_effect_log where event_id=v_evt;
  perform app.run_studio_executor(500);   -- replay
  if (select count(*) from public.rule_effect_log where event_id=v_evt)<>v_n then
    raise exception 'effect (event,rule,effect_index) replay was not swallowed';
  end if;

  -- ---- 5. Promise preservation: exhaust the cap, a NEW grant is refused, the ----
  --         issued entitlement stays redeemable.
  perform public.record_quick_sale(v_business,5000,'cash',v_client2,v_owner_staff,v_branch,'v56 c2','v56-c2-'||substr(md5(clock_timestamp()::text),1,10),true);
  select event_id into v_evt2 from public.domain_events where business_id=v_business and event_type='sale.completed' and subject_client_id=v_client2 order by recorded_at desc limit 1;
  perform app.run_studio_executor(500);
  if exists(select 1 from public.program_entitlements where business_id=v_business and client_id=v_client2 and rule_id=v_rule) then
    raise exception 'a NEW grant was issued past the exhausted budget';
  end if;
  if not exists(select 1 from public.rule_effect_log where event_id=v_evt2 and rule_id=v_rule and outcome='budget_exhausted') then
    raise exception 'budget exhaustion was not logged';
  end if;
  if (select status from public.program_entitlements where id=v_ent)<>'available' then
    raise exception 'the issued promise lost its availability when the budget exhausted';
  end if;
  if (select committed_cents from public.budget_periods where business_id=v_business and rule_id=v_rule)<>1500 then
    raise exception 'budget counter does not reconcile to the single issued reservation';
  end if;
  if (select coalesce(sum(amount_cents),0) from public.budget_reservations br join public.budget_periods bp on bp.id=br.budget_period_id where bp.business_id=v_business and bp.rule_id=v_rule)<>1500 then
    raise exception 'reservation rows do not reconcile to the counter';
  end if;

  -- ---- 6. Double-fulfilment fails at the constraint (studio path AND legacy path). ----
  select canonical_benefit_key into v_dupkey from public.benefit_fulfilments where business_id=v_business and source_engine='recurring' limit 1;
  reset role;
  begin
    insert into public.benefit_fulfilments(business_id,canonical_benefit_key,source_engine,fulfilment_kind,client_id,detail_ref,face_value_cents,estimated_cost_cents,cost_basis,cost_confidence,config_version_id,occurred_at)
    values(v_business,v_dupkey,'recurring','recurring_perk',v_client,gen_random_uuid(),1500,1500,'catalog_cost','medium',v_base,now());
    raise exception 'double-fulfilment via the studio path succeeded';
  exception when unique_violation then null; end;
  begin
    insert into public.benefit_fulfilments(business_id,canonical_benefit_key,source_engine,fulfilment_kind,client_id,detail_ref,face_value_cents,estimated_cost_cents,cost_basis,cost_confidence,config_version_id,occurred_at)
    values(v_business,v_dupkey,'referral','referral_reward',v_client,gen_random_uuid(),500,500,'credit_face','high',v_base,now());
    raise exception 'cross-engine double-fulfilment on one canonical key succeeded';
  exception when unique_violation then null; end;

  -- ---- 7. Entitlement redeem (staff) + idempotent replay. ----
  perform pg_temp.as_v56_principal(v_owner,'authenticated');
  v_result := public.redeem_program_entitlement(v_ent, gen_random_uuid());
  if v_result->>'status'<>'redeemed' then raise exception 'redeem did not flip the entitlement'; end if;
  v_result := public.redeem_program_entitlement(v_ent, (select idempotency_key from public.program_entitlement_operations where entitlement_id=v_ent and operation_type='redeem' limit 1));
  if coalesce((v_result->>'replayed')::boolean,false) is not true then raise exception 'redeem replay was not idempotent'; end if;
  -- 7b. Reusing the key for a DIFFERENT entitlement is an error, not a replay.
  reset role;
  select entitlement_id into v_ent2 from app.ps1b_materialise_entitlement(
    v_business, v_client2, v_rule, v_base, 'v56-manual', 'free_item', '{}'::jsonb,
    now(), now()+interval '30 days', 0, null, now(), now()+interval '1 month');
  if v_ent2 is null then raise exception 'manual second entitlement did not materialise'; end if;
  perform pg_temp.as_v56_principal(v_owner,'authenticated');
  begin
    perform public.redeem_program_entitlement(v_ent2, (select idempotency_key from public.program_entitlement_operations where entitlement_id=v_ent and operation_type='redeem' limit 1));
    raise exception 'an idempotency key was reusable across entitlements';
  exception when sqlstate '22023' then null; end;
  -- 7c. The owner reverses the REDEEMED entitlement (mistaken-scan correction;
  --     the lifecycle guard must sanction redeemed -> reversed).
  v_result := public.reverse_program_entitlement(v_ent, 'v56 mis-scan correction', gen_random_uuid());
  if v_result->>'status'<>'reversed' then raise exception 'owner could not reverse a redeemed entitlement'; end if;
  if (select status from public.program_entitlements where id=v_ent)<>'reversed' then
    raise exception 'redeemed->reversed did not persist';
  end if;

  -- ---- 8. Successful capture writes a SYNTHETIC recipient (no real delivery). ----
  reset role;
  perform app.run_outbox_sweep(200);   -- the queued send_notification rows deliver cleanly
  if not exists(select 1 from public.captured_messages c where c.business_id=v_business and c.recipient like 'synthetic:%') then
    raise exception 'capture provider did not write a synthetic captured message';
  end if;

  -- ---- 9. Dead-letter on a fresh, isolated event: forced outage backs off to ----
  --         dead_letter, is surfaced, and never rolls back the source event.
  v_evt3 := app.emit_domain_event(v_business,'points.redeemed','loyalty_op:v56dl',v_client,null,now(),null,'{}'::jsonb);
  insert into public.event_outbox(business_id,event_id,consumer) values(v_business,v_evt3,'comms') returning id into v_ob;
  perform set_config('app.ps1b_capture_fail','1',true);
  for v_n in 1..6 loop
    update public.event_outbox set next_attempt_at=now() where id=v_ob and delivery_status in ('pending','failed');
    perform app.run_outbox_sweep(200);
  end loop;
  perform set_config('app.ps1b_capture_fail','',true);
  if (select delivery_status from public.event_outbox where id=v_ob)<>'dead_letter' then
    raise exception 'repeated failure did not reach dead_letter (got %)', (select delivery_status from public.event_outbox where id=v_ob);
  end if;
  if not exists(select 1 from public.domain_events where event_id=v_evt3) then
    raise exception 'a delivery failure rolled back the source event';
  end if;
  -- the dead-lettered outbox row never captured a message; a REAL recipient is uninsertable.
  begin
    insert into public.captured_messages(business_id,event_id,outbox_id,channel,recipient,template_key,rendered)
    values(v_business,v_evt3,v_ob,'email','victim@gmail.com','x','{}'::jsonb);
    raise exception 'a REAL recipient was insertable into captured_messages';
  exception when check_violation then null; end;
  perform pg_temp.as_v56_principal(v_owner,'authenticated');
  if jsonb_array_length((public.get_studio_dead_letters(v_business))->'dead_letters')<1 then
    raise exception 'dead letters are not surfaced to the owner';
  end if;

  -- ---- 10. Shadow never writes value tables; comparator flags a seeded divergence. ----
  reset role;   -- internal app.* surfaces are browser-revoked; drive them as postgres
  select count(*) into v_shadow_before from public.benefit_shadow_evaluations where business_id=v_business and source_engine='referral';
  v_before := md5(coalesce((select string_agg(to_jsonb(f)::text,'' order by f.id::text) from public.benefit_fulfilments f where f.business_id=v_business),'')
                || coalesce((select string_agg(to_jsonb(e)::text,'' order by e.id::text) from public.program_entitlements e where e.business_id=v_business),'')
                || coalesce((select string_agg(to_jsonb(cl)::text,'' order by cl.id::text) from public.credit_ledger cl where cl.business_id=v_business),''));
  perform app.emit_domain_event(v_business,'referral.qualified','referral_qualify:v56shadow',v_client,null,now(),null,
    jsonb_build_object('referral_id','v56shadow','referrer_client_id',v_client::text,'reward_cents',500));
  perform app.run_referral_shadow(500);
  v_after := md5(coalesce((select string_agg(to_jsonb(f)::text,'' order by f.id::text) from public.benefit_fulfilments f where f.business_id=v_business),'')
               || coalesce((select string_agg(to_jsonb(e)::text,'' order by e.id::text) from public.program_entitlements e where e.business_id=v_business),'')
               || coalesce((select string_agg(to_jsonb(cl)::text,'' order by cl.id::text) from public.credit_ledger cl where cl.business_id=v_business),''));
  if v_before<>v_after then raise exception 'the shadow evaluator mutated a value table'; end if;
  if (select count(*) from public.benefit_shadow_evaluations where business_id=v_business and source_engine='referral')<=v_shadow_before then
    raise exception 'the shadow evaluator did not write its shadow log';
  end if;
  -- seed a matched pair and a divergence
  insert into public.benefit_fulfilments(business_id,canonical_benefit_key,source_engine,fulfilment_kind,client_id,detail_ref,face_value_cents,estimated_cost_cents,cost_basis,cost_confidence,config_version_id,occurred_at)
  values(v_business,'referral:v56match','referral','referral_reward',v_client,gen_random_uuid(),500,500,'credit_face','high',v_base,now()),
        (v_business,'referral:v56div','referral','referral_reward',v_client,gen_random_uuid(),500,500,'credit_face','high',v_base,now());
  insert into public.domain_events(business_id,event_type,source_operation_id,subject_client_id,occurred_at,config_version_id,payload,payload_hash)
  values(v_business,'referral.qualified','referral_qualify:v56match',v_client,now(),null,'{}'::jsonb,repeat('a',64)),
        (v_business,'referral.qualified','referral_qualify:v56div',v_client,now(),null,'{}'::jsonb,repeat('b',64));
  insert into public.benefit_shadow_evaluations(business_id,event_id,source_engine,would_be_canonical_key,client_id,fulfilment_kind,face_value_cents,estimated_cost_cents,cost_basis,cost_confidence)
  select v_business,event_id,'referral','referral:v56match',v_client,'referral_reward',500,500,'credit_face','high' from public.domain_events where business_id=v_business and source_operation_id='referral_qualify:v56match';
  insert into public.benefit_shadow_evaluations(business_id,event_id,source_engine,would_be_canonical_key,client_id,fulfilment_kind,face_value_cents,estimated_cost_cents,cost_basis,cost_confidence)
  select v_business,event_id,'referral','referral:v56div',v_client,'referral_reward',999,999,'credit_face','high' from public.domain_events where business_id=v_business and source_operation_id='referral_qualify:v56div';
  v_cmp := app.compare_shadow_vs_live(v_business,'referral');
  if (v_cmp->>'clean')::boolean then raise exception 'comparator missed the seeded divergence'; end if;
  if (v_cmp->>'mismatches')::integer < 1 then raise exception 'comparator did not count the face-value mismatch'; end if;

  -- ---- 11. Permission: owner/staff/anon/cross-tenant fail closed. ----
  reset role;
  insert into auth.users(instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at)
  values('00000000-0000-0000-0000-000000000000',v_manager,'authenticated','authenticated','v56-mgr-'||substr(v_manager::text,1,8)||'@example.test','',now(),now(),now());
  insert into public.staff(business_id,user_id,role,full_name,active) values(v_business,v_manager,'frontdesk','v56 frontdesk',true);
  perform pg_temp.as_v56_principal(v_manager,'authenticated');
  begin perform public.reverse_program_entitlement(v_ent,'nope',gen_random_uuid()); raise exception 'non-owner reversed an entitlement'; exception when insufficient_privilege then null; end;
  begin perform public.get_studio_dead_letters(v_business); raise exception 'non-owner read dead letters'; exception when insufficient_privilege then null; end;
  perform pg_temp.as_v56_principal(null,'anon');
  begin perform public.get_program_entitlements(v_business); raise exception 'anon read entitlements'; exception when insufficient_privilege then null; end;
  begin perform public.redeem_program_entitlement(v_ent,gen_random_uuid()); raise exception 'anon redeemed an entitlement'; exception when insufficient_privilege then null; end;
  -- v_owner_b is deliberately a super_admin in the pristine fixture (sa_read
  -- coverage), and SA read access is the sanctioned v14 scope — so cross-tenant
  -- denial needs a fresh NON-SA owner of business B.
  reset role;
  insert into auth.users(instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at)
  values('00000000-0000-0000-0000-000000000000',v_xten,'authenticated','authenticated','v56-xten-'||substr(v_xten::text,1,8)||'@example.test','',now(),now(),now());
  insert into public.staff(business_id,user_id,role,full_name,active) values(v_biz_b,v_xten,'owner','v56 xten owner',true);
  perform pg_temp.as_v56_principal(v_xten,'authenticated');
  begin perform public.get_program_entitlements(v_business); raise exception 'cross-tenant read of entitlements'; exception when insufficient_privilege then null; end;
  begin perform public.get_shadow_comparison(v_business); raise exception 'cross-tenant shadow comparison'; exception when insufficient_privilege then null; end;
  -- and the fixture SA does read cross-tenant (v14 read-everything scope holds)
  perform pg_temp.as_v56_principal(v_owner_b,'authenticated');
  if (public.get_program_entitlements(v_business)->>'business_id') is null then
    raise exception 'super admin read-everything scope regressed';
  end if;

  -- ---- 12. Append-only guards + browser ACL contract. ----
  reset role;
  begin update public.domain_events set payload='{}'::jsonb where event_id=v_evt; raise exception 'domain_events was mutable'; exception when restrict_violation then null; end;
  begin delete from public.benefit_fulfilments where business_id=v_business and canonical_benefit_key=v_dupkey; raise exception 'benefit_fulfilments was deletable'; exception when restrict_violation then null; end;
  if has_table_privilege('authenticated','public.domain_events','insert')
     or has_table_privilege('authenticated','public.benefit_fulfilments','insert')
     or has_table_privilege('authenticated','public.program_entitlements','insert')
     or has_table_privilege('authenticated','public.event_outbox','insert')
     or has_table_privilege('authenticated','public.captured_messages','insert') then
    raise exception 'browser roles retain direct writes to PS-1B execution tables';
  end if;
  if not has_function_privilege('authenticated','public.redeem_program_entitlement(uuid,uuid)','execute')
     or has_function_privilege('anon','public.redeem_program_entitlement(uuid,uuid)','execute') then
    raise exception 'v56 RPC ACL contract is incorrect';
  end if;

  raise notice 'v56 PS-1B events/execution/outbox/shadow suite: ALL PASS';
end $v56_test$;

reset role;
rollback;
