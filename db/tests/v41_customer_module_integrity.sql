-- Rollback-only v41 customer-module integrity adversarial suite.
-- Run after the complete v20-v41 chain. This suite mutates only synthetic rows
-- inside this transaction and intentionally forces consent-event failures.
begin;
\ir fixtures/pristine_chain_fixture.psql

-- Keep this suite reproducible on a freshly materialized canonical database.
-- Both synthetic tenants are transaction-local because the suite rolls back.
create temporary table pg_temp.v41_integrity_fixture (
  business_id uuid primary key,
  owner_id uuid not null unique,
  other_business_id uuid not null unique,
  branch_id uuid not null unique
) on commit drop;

do $v41_fixture$
declare
  v_owner uuid := gen_random_uuid();
  v_business uuid;
  v_other_business uuid;
  v_branch uuid;
begin
  insert into auth.users (
    instance_id, id, aud, role, email, encrypted_password,
    email_confirmed_at, created_at, updated_at
  ) values (
    '00000000-0000-0000-0000-000000000000', v_owner,
    'authenticated', 'authenticated',
    'v41-integrity-owner-' || substr(v_owner::text, 1, 8) || '@example.test',
    '', now(), now(), now()
  );
  insert into public.businesses (name, slug, industry, enabled_modules)
  values (
    'V41 integrity fixture',
    'v41-integrity-' || substr(v_owner::text, 1, 8),
    'test',
    array['dashboard','clients','sales','loyalty','referrals','memberships','giftcards']
  ) returning id into v_business;
  insert into public.staff (
    business_id, user_id, role, full_name, active, modules, module_perms
  ) values (
    v_business, v_owner, 'owner', 'V41 integrity owner', true, null, null
  );
  insert into public.branches(business_id,name,is_default,active)
  values(v_business,'V41 integrity main',true,true)
  returning id into v_branch;
  insert into public.businesses (name, slug, industry, enabled_modules)
  values (
    'V41 integrity other tenant',
    'v41-integrity-other-' || substr(gen_random_uuid()::text, 1, 8),
    'test',
    array['dashboard','clients']
  ) returning id into v_other_business;
  insert into pg_temp.v41_integrity_fixture(business_id,owner_id,other_business_id,branch_id)
  values (v_business,v_owner,v_other_business,v_branch);
end
$v41_fixture$;

create or replace function pg_temp.as_v41_user(
  p_uid uuid,
  p_role text default 'authenticated'
) returns void language plpgsql as $$
begin
  execute format('set local role %I', p_role);
  perform set_config('request.jwt.claim.sub', coalesce(p_uid::text, ''), true);
  perform set_config('request.jwt.claims', json_build_object(
    'sub', p_uid, 'role', p_role
  )::text, true);
end;
$$;
grant execute on function pg_temp.as_v41_user(uuid,text) to public;

create or replace function pg_temp.expect_v41_denied(
  p_sql text,
  p_label text,
  p_sqlstate text default '42501'
) returns void language plpgsql as $$
declare v_state text;
begin
  begin
    execute p_sql;
  exception when others then
    get stacked diagnostics v_state = returned_sqlstate;
    if v_state = p_sqlstate then return; end if;
    raise exception '% returned SQLSTATE %, expected %', p_label, v_state, p_sqlstate;
  end;
  raise exception '% unexpectedly succeeded', p_label;
end;
$$;
grant execute on function pg_temp.expect_v41_denied(text,text,text) to public;

create or replace function pg_temp.force_v41_consent_failure()
returns trigger language plpgsql as $$
begin
  if new.source in ('v41-force-failure', 'v41-force-create-failure') then
    raise exception 'forced consent event failure';
  end if;
  return new;
end;
$$;

create trigger trg_v41_force_consent_failure
before insert on public.consents
for each row execute function pg_temp.force_v41_consent_failure();

do $v41_test$
declare
  v_business uuid;
  v_other_business uuid;
  v_branch uuid;
  v_owner uuid;
  v_restricted uuid := gen_random_uuid();
  v_readonly uuid := gen_random_uuid();
  v_rw uuid := gen_random_uuid();
  v_legacy uuid := gen_random_uuid();
  v_inactive uuid := gen_random_uuid();
  v_other_client uuid;
  v_client uuid;
  v_toggle_client uuid;
  v_failure_client uuid;
  v_phone_client uuid;
  v_phone text := '89994141';
  v_referrer uuid;
  v_referred uuid;
  v_referral_program uuid;
  v_referral_code text;
  v_plan uuid;
  v_membership uuid;
  v_create_key uuid := gen_random_uuid();
  v_create_false_key uuid := gen_random_uuid();
  v_create_failure_key uuid := gen_random_uuid();
  v_grant_key uuid := gen_random_uuid();
  v_withdraw_key uuid := gen_random_uuid();
  v_failure_key uuid := gen_random_uuid();
  v_gift_key uuid := gen_random_uuid();
  v_first jsonb;
  v_replay jsonb;
  v_result jsonb;
  v_personas jsonb;
  v_list jsonb;
  v_code text;
  v_card uuid;
  v_sale uuid;
  v_before_cards integer;
  v_before_sales integer;
  v_before_clients integer;
  v_before_consents integer;
  v_before_referrals integer;
  v_till_sales_before integer;
  v_before_liability bigint;
  v_after_cards integer;
  v_after_sales integer;
  v_after_liability bigint;
  v_count integer;
  v_credit_before bigint;
  v_table text;
  v_proc regprocedure;
begin
  reset role;
  select f.business_id,f.owner_id,f.other_business_id,f.branch_id
    into v_business,v_owner,v_other_business,v_branch
    from pg_temp.v41_integrity_fixture f;
  if v_business is null or v_owner is null or v_other_business is null then
    raise exception 'v41 suite requires an active owner and two businesses';
  end if;
  update public.businesses
     set enabled_modules = case
       when 'clients'=any(coalesce(enabled_modules,'{}'::text[])) then enabled_modules
       else array_append(coalesce(enabled_modules,'{}'::text[]),'clients') end
   where id=v_business;

  -- Public SECURITY DEFINER entry points are authenticated-only and legacy
  -- keyless issuance is no longer executable by a browser role.
  foreach v_proc in array array[
    to_regprocedure('public.staff_create_client(uuid,uuid,text,text,text,date,text,boolean,text,text)'),
    to_regprocedure('public.staff_set_marketing_consent(uuid,uuid,uuid,boolean,text)'),
    to_regprocedure('public.issue_gift_card(uuid,integer,uuid,text,uuid)'),
    to_regprocedure('public.staff_list_gift_cards(uuid,integer)'),
    to_regprocedure('public.save_referral_program(uuid,boolean,integer,integer)'),
    to_regprocedure('public.save_membership_plan(uuid,uuid,text,integer,text,integer,numeric,boolean)'),
    to_regprocedure('public.set_membership_status(uuid,uuid,text)'),
    to_regprocedure('public.enroll_membership_v41(uuid,uuid,uuid)'),
    to_regprocedure('public.redeem_gift_card_v41(uuid,text,uuid,integer)'),
    to_regprocedure('public.lookup_client_by_phone(uuid,text)'),
    to_regprocedure('public.record_sale_by_phone(uuid,text,integer,text,text,uuid,text,uuid,text)')
  ] loop
    if v_proc is null then raise exception 'missing v41 RPC'; end if;
    if has_function_privilege('anon', v_proc, 'EXECUTE')
       or not has_function_privilege('authenticated', v_proc, 'EXECUTE') then
      raise exception 'v41 RPC ACL is not authenticated-only: %', v_proc;
    end if;
  end loop;
  if has_function_privilege(
       'authenticated',
       'public.issue_gift_card(uuid,integer,uuid,text)'::regprocedure,
       'EXECUTE'
     ) then
    raise exception 'legacy keyless gift-card issuance remains executable';
  end if;

  foreach v_table in array array[
    'customer_staff_operations', 'gift_card_issue_operations'
  ] loop
    if to_regclass('public.' || v_table) is null then
      raise exception 'missing private operation table %', v_table;
    end if;
    if has_table_privilege('authenticated', 'public.' || v_table, 'SELECT')
       or has_table_privilege('authenticated', 'public.' || v_table, 'INSERT')
       or has_table_privilege('anon', 'public.' || v_table, 'SELECT') then
      raise exception 'operation table is browser-readable/writable: %', v_table;
    end if;
  end loop;
  if exists (
    select 1 from information_schema.columns c
     where c.table_schema='public'
       and (
         (c.table_name='customer_staff_operations' and c.column_name in
           ('request_payload','result','full_name','phone','email','birth_date','gender','referrer_code'))
         or
         (c.table_name='gift_card_issue_operations' and c.column_name in
           ('request_payload','result','recipient_email','code'))
       )
  ) then
    raise exception 'immutable operation tables duplicate PII, request JSON, response JSON, or bearer code';
  end if;

  -- Raw authenticated writes are denied even to a same-business owner. All
  -- customer financial/configuration changes must cross an audited RPC.
  foreach v_table in array array[
    'clients', 'consents', 'referrals', 'referral_programs', 'gift_cards',
    'membership_plans', 'memberships'
  ] loop
    if has_table_privilege('authenticated', 'public.' || v_table, 'INSERT')
       or has_table_privilege('authenticated', 'public.' || v_table, 'UPDATE')
       or has_table_privilege('authenticated', 'public.' || v_table, 'DELETE')
       or has_table_privilege('authenticated', 'public.' || v_table, 'TRUNCATE') then
      raise exception 'raw table writes remain granted on %', v_table;
    end if;
  end loop;
  if has_table_privilege('authenticated', 'public.gift_cards', 'SELECT') then
    raise exception 'raw gift code is readable by authenticated';
  end if;

  insert into auth.users(
    instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at
  ) values
    ('00000000-0000-0000-0000-000000000000',v_restricted,
     'authenticated','authenticated','v41-restricted-' || substr(v_restricted::text,1,8) || '@example.test','',now(),now(),now()),
    ('00000000-0000-0000-0000-000000000000',v_readonly,
     'authenticated','authenticated','v41-readonly-' || substr(v_readonly::text,1,8) || '@example.test','',now(),now(),now()),
    ('00000000-0000-0000-0000-000000000000',v_rw,
     'authenticated','authenticated','v41-rw-' || substr(v_rw::text,1,8) || '@example.test','',now(),now(),now()),
    ('00000000-0000-0000-0000-000000000000',v_legacy,
     'authenticated','authenticated','v41-legacy-' || substr(v_legacy::text,1,8) || '@example.test','',now(),now(),now()),
    ('00000000-0000-0000-0000-000000000000',v_inactive,
     'authenticated','authenticated','v41-inactive-' || substr(v_inactive::text,1,8) || '@example.test','',now(),now(),now());
  insert into public.staff(business_id,user_id,role,full_name,active,modules,module_perms)
  values
    (v_business,v_restricted,'staff','V41 override-denied staff',true,array['clients'],'{}'::jsonb),
    (v_business,v_readonly,'staff','V41 clients and loyalty read-only staff',true,array['clients'],'{"clients":"r","loyalty":"r"}'::jsonb),
    (v_business,v_rw,'staff','V41 clients and loyalty read-write override',true,array['inventory'],'{"clients":"rw","loyalty":"rw"}'::jsonb),
    (v_business,v_legacy,'staff','V41 legacy clients staff',true,array['clients'],null),
    (v_business,v_inactive,'manager','V41 inactive manager',false,null,null);
  insert into public.staff_branches(business_id,staff_id,branch_id)
  select v_business,s.id,v_branch from public.staff s
   where s.business_id=v_business and s.active
  on conflict do nothing;
  insert into public.clients(business_id,full_name)
  values(v_other_business,'V41 other-tenant purchaser') returning id into v_other_client;

  -- Atomic add + consent: exact create-client replay returns the same identifiers,
  -- creates exactly one client and exactly one consent event, while changed input
  -- under the same key is a 23505 conflict.
  perform pg_temp.as_v41_user(v_owner);
  v_first := public.staff_create_client(
    v_business,v_create_key,'V41 atomic opted-in client',null,
    'v41-atomic@example.test','1990-01-01','other',true,null,'v41-create-consent'
  );
  v_client := (v_first->>'client_id')::uuid;
  -- Privileged test-only mutation proves replay does not depend on mutable PII
  -- and that the immutable operation response stores safe facts only.
  reset role;
  update public.clients set full_name='V41 mutable PII changed after completion'
   where id=v_client and business_id=v_business;
  perform pg_temp.as_v41_user(v_owner);
  v_replay := public.staff_create_client(
    v_business,v_create_key,'V41 atomic opted-in client',null,
    'v41-atomic@example.test','1990-01-01','other',true,null,'v41-create-consent'
  );
  if v_client is null
     or (v_replay->>'client_id')::uuid <> v_client
     or (v_replay->>'consent_event_id')::uuid is distinct from
        (v_first->>'consent_event_id')::uuid
     or v_replay is distinct from v_first then
    raise exception 'exact create-client replay did not return original identifiers: %, %',v_first,v_replay;
  end if;
  select count(*) into v_count from public.clients
   where business_id=v_business and id=v_client and marketing_consent;
  if v_count <> 1 then raise exception 'exact create-client replay duplicated or lost the client'; end if;
  select count(*) into v_count from public.consents
   where business_id=v_business and client_id=v_client
     and action='granted' and source='v41-create-consent';
  if v_count <> 1 then raise exception 'exactly one consent event was not retained for create replay'; end if;
  perform pg_temp.expect_v41_denied(format(
    'select public.staff_create_client(%L::uuid,%L::uuid,%L,null,%L,%L::date,%L,true,null,%L)',
    v_business,v_create_key,'V41 changed create-client request','v41-atomic@example.test',
    '1990-01-01','other','v41-create-consent'
  ),'changed create-client request','23505');

  -- Create an initially opted-out client and exercise grant/withdraw. Replays
  -- return the same event identifiers and never append a second event.
  v_result := public.staff_create_client(
    v_business,v_create_false_key,'V41 consent transition client',null,
    'v41-transition@example.test',null,null,false,null,'v41-create-opt-out'
  );
  v_toggle_client := (v_result->>'client_id')::uuid;
  v_first := public.staff_set_marketing_consent(
    v_business,v_toggle_client,v_grant_key,true,'v41-grant'
  );
  v_replay := public.staff_set_marketing_consent(
    v_business,v_toggle_client,v_grant_key,true,'v41-grant'
  );
  if (v_replay->>'client_id')::uuid <> v_toggle_client
     or (v_replay->>'consent_event_id')::uuid is distinct from
        (v_first->>'consent_event_id')::uuid
     or v_replay is distinct from v_first then
    raise exception 'exact consent replay did not return original identifiers: %, %',v_first,v_replay;
  end if;
  select count(*) into v_count from public.consents
   where business_id=v_business and client_id=v_toggle_client
     and action='granted' and source='v41-grant';
  if v_count <> 1 then raise exception 'exactly one consent event was not retained for grant replay'; end if;
  perform pg_temp.expect_v41_denied(format(
    'select public.staff_set_marketing_consent(%L::uuid,%L::uuid,%L::uuid,false,%L)',
    v_business,v_toggle_client,v_grant_key,'v41-grant'
  ),'changed consent request','23505');
  v_result := public.staff_set_marketing_consent(
    v_business,v_toggle_client,v_withdraw_key,false,'v41-withdraw'
  );
  v_replay := public.staff_set_marketing_consent(
    v_business,v_toggle_client,v_withdraw_key,false,'v41-withdraw'
  );
  if (select marketing_consent from public.clients where id=v_toggle_client)
     or (select count(*) from public.consents
          where client_id=v_toggle_client and action='withdrawn' and source='v41-withdraw') <> 1
     or (v_replay->>'consent_event_id')::uuid is distinct from
        (v_result->>'consent_event_id')::uuid
     or v_replay is distinct from v_result then
    raise exception 'exact withdraw replay did not preserve flag and one original event';
  end if;

  -- Forced consent event failure on an existing client must roll back the flag.
  v_result := public.staff_create_client(
    v_business,gen_random_uuid(),'V41 forced transition failure',null,
    'v41-transition-failure@example.test',null,null,false,null,'v41-create-failure-fixture'
  );
  v_failure_client := (v_result->>'client_id')::uuid;
  begin
    perform public.staff_set_marketing_consent(
      v_business,v_failure_client,v_failure_key,true,'v41-force-failure'
    );
    raise exception 'forced consent event failure unexpectedly succeeded';
  exception when sqlstate 'P0001' then
    if sqlerrm <> 'forced consent event failure' then raise; end if;
  end;
  if (select marketing_consent from public.clients where id=v_failure_client)
     or exists(select 1 from public.consents where client_id=v_failure_client and source='v41-force-failure') then
    raise exception 'forced consent event failure left marketing_consent changed';
  end if;

  -- Forced event failure during create-client must leave no client and no event.
  begin
    perform public.staff_create_client(
      v_business,v_create_failure_key,'V41 forced create failure',null,
      'v41-create-failure@example.test',null,null,true,null,'v41-force-create-failure'
    );
    raise exception 'forced create-client consent event failure unexpectedly succeeded';
  exception when sqlstate 'P0001' then
    if sqlerrm <> 'forced consent event failure' then raise; end if;
  end;
  if exists(select 1 from public.clients where email='v41-create-failure@example.test')
     or exists(select 1 from public.consents where source='v41-force-create-failure') then
    raise exception 'forced create-client consent failure left a client or consent event';
  end if;

  -- Effective module truth table: a non-null override is complete. A missing
  -- clients key hides legacy clients access; r reads but cannot mutate; rw grants
  -- read/write even when legacy modules excludes clients; NULL preserves legacy;
  -- and owners retain the business-enabled module list. get_my_modules and
  -- get_my_personas must publish exactly the same effective truth to the app.
  perform pg_temp.as_v41_user(v_restricted);
  select count(*) into v_count from public.clients where business_id=v_business;
  v_result := public.get_my_modules(v_business)::jsonb;
  v_personas := public.get_my_personas();
  if v_count <> 0 or (v_result->'modules') ? 'clients'
     or (v_personas->'staff'->0->'modules') ? 'clients' then
    raise exception 'missing module_perms key did not override legacy clients access: %, %',v_result,v_personas;
  end if;

  perform pg_temp.as_v41_user(v_readonly);
  select count(*) into v_count from public.clients where business_id=v_business;
  v_result := public.get_my_modules(v_business)::jsonb;
  v_personas := public.get_my_personas();
  if v_count < 1 or not ((v_result->'modules') ? 'clients')
     or not ((v_personas->'staff'->0->'modules') ? 'clients')
     or not app.can_module_read(v_business,'loyalty')
     or app.can_module_write(v_business,'loyalty') then
    raise exception 'r override did not grant effective clients read/discovery: %, %',v_result,v_personas;
  end if;
  perform pg_temp.expect_v41_denied(format(
    'select public.staff_create_client(%L::uuid,%L::uuid,%L,null,null,null,null,false,null,%L)',
    v_business,gen_random_uuid(),'V41 readonly denied','v41-readonly-denied'
  ),'r override client mutation','42501');
  perform pg_temp.expect_v41_denied(
    'update public.clients set full_name=full_name where false',
    'r override raw client DML','42501'
  );
  perform pg_temp.expect_v41_denied(format(
    'select public.redeem_points(%L::uuid,%L::uuid,%L)',
    v_business,v_client,gen_random_uuid()::text
  ),'loyalty r classic redemption','42501');
  perform pg_temp.expect_v41_denied(format(
    'select public.redeem_reward(%L::uuid,%L::uuid,%L::uuid,%L)',
    v_business,v_client,gen_random_uuid(),gen_random_uuid()::text
  ),'loyalty r catalog redemption','42501');
  perform pg_temp.expect_v41_denied(format(
    'select public.redeem_reward_at_context(%L::uuid,%L::uuid,%L::uuid,%L,null,null,null)',
    v_business,v_client,gen_random_uuid(),gen_random_uuid()::text
  ),'loyalty r contextual redemption','42501');

  perform pg_temp.as_v41_user(v_rw);
  v_result := public.get_my_modules(v_business)::jsonb;
  v_personas := public.get_my_personas();
  if not ((v_result->'modules') ? 'clients')
     or not ((v_personas->'staff'->0->'modules') ? 'clients')
     or not app.can_module_read(v_business,'loyalty')
     or not app.can_module_write(v_business,'loyalty') then
    raise exception 'rw override omitted clients from effective discovery: %, %',v_result,v_personas;
  end if;
  v_result := public.staff_create_client(
    v_business,gen_random_uuid(),'V41 rw override succeeds',null,null,null,null,
    false,null,'v41-rw-override'
  );
  if (v_result->>'client_id')::uuid is null then
    raise exception 'rw override could not mutate clients excluded from legacy modules';
  end if;

  -- Client creation itself belongs to clients:rw, but a nonblank referrer code
  -- crosses into referrals and therefore requires referrals:rw. Both a missing
  -- key and r-only access must fail atomically; referrals:rw permits the link.
  reset role;
  select referral_code into v_referral_code from public.clients where id=v_client;
  select count(*) into v_before_clients from public.clients where business_id=v_business;
  select count(*) into v_before_consents from public.consents where business_id=v_business;
  select count(*) into v_before_referrals from public.referrals where business_id=v_business;

  perform pg_temp.as_v41_user(v_rw);
  perform pg_temp.expect_v41_denied(format(
    'select public.staff_create_client(%L::uuid,%L::uuid,%L,null,%L,null,null,false,%L,%L)',
    v_business,gen_random_uuid(),'V41 clients-only referrer denied',
    'v41-clients-only-referrer@example.test',v_referral_code,'v41-clients-only-referrer-link'
  ),'clients-only referrer link','42501');
  reset role;
  if (select count(*) from public.clients where business_id=v_business) <> v_before_clients
     or (select count(*) from public.consents where business_id=v_business) <> v_before_consents
     or (select count(*) from public.referrals where business_id=v_business) <> v_before_referrals then
    raise exception 'clients-only referrer denial was not atomic';
  end if;

  update public.staff set module_perms='{"clients":"rw","referrals":"r"}'::jsonb
   where business_id=v_business and user_id=v_rw;
  perform pg_temp.as_v41_user(v_rw);
  perform pg_temp.expect_v41_denied(format(
    'select public.staff_create_client(%L::uuid,%L::uuid,%L,null,%L,null,null,false,%L,%L)',
    v_business,gen_random_uuid(),'V41 referrals r referrer denied',
    'v41-referrals-r-referrer@example.test',v_referral_code,'v41-referrals-r-referrer-link'
  ),'referrals r referrer link','42501');
  reset role;
  if (select count(*) from public.clients where business_id=v_business) <> v_before_clients
     or (select count(*) from public.consents where business_id=v_business) <> v_before_consents
     or (select count(*) from public.referrals where business_id=v_business) <> v_before_referrals then
    raise exception 'referrals r referrer denial was not atomic';
  end if;

  update public.staff set module_perms='{"clients":"rw","referrals":"rw"}'::jsonb
   where business_id=v_business and user_id=v_rw;
  perform pg_temp.as_v41_user(v_rw);
  v_result := public.staff_create_client(
    v_business,gen_random_uuid(),'V41 referrals rw linked client',null,
    'v41-referrals-rw-linked@example.test',null,null,false,v_referral_code,
    'v41-referrals-rw-atomic-link'
  );
  v_referred := (v_result->>'client_id')::uuid;
  reset role;
  if (v_result->>'referral_id') is null
     or not exists(select 1 from public.referrals
                    where id=(v_result->>'referral_id')::uuid
                      and business_id=v_business
                      and referrer_client_id=v_client
                      and referred_client_id=v_referred)
     or (select count(*) from public.clients where business_id=v_business) <> v_before_clients + 1
     or (select count(*) from public.consents where business_id=v_business) <> v_before_consents + 1
     or (select count(*) from public.referrals where business_id=v_business) <> v_before_referrals + 1 then
    raise exception 'referrals rw atomic link did not create exactly one client, consent, and referral: %',v_result;
  end if;
  update public.staff set module_perms='{"clients":"rw"}'::jsonb
   where business_id=v_business and user_id=v_rw;

  perform pg_temp.as_v41_user(v_legacy);
  v_result := public.get_my_modules(v_business)::jsonb;
  v_personas := public.get_my_personas();
  if not ((v_result->'modules') ? 'clients')
     or not ((v_personas->'staff'->0->'modules') ? 'clients') then
    raise exception 'NULL module_perms did not preserve legacy clients discovery: %, %',v_result,v_personas;
  end if;
  v_result := public.staff_create_client(
    v_business,gen_random_uuid(),'V41 legacy fallback succeeds',null,null,null,null,
    false,null,'v41-legacy-fallback'
  );
  if (v_result->>'client_id')::uuid is null then
    raise exception 'NULL module_perms did not preserve legacy write access';
  end if;

  perform pg_temp.as_v41_user(v_owner);
  v_result := public.get_my_modules(v_business)::jsonb;
  v_personas := public.get_my_personas();
  if not ((v_result->'modules') ? 'clients')
     or not ((v_personas->'staff'->0->'modules') ? 'clients') then
    raise exception 'owner lost enabled clients module discovery: %, %',v_result,v_personas;
  end if;

  -- SECURITY DEFINER till paths must not turn create_sales into client-data
  -- access. Missing-key staff has create_sales through the staff role but gets
  -- no PII and no sale; clients r can lookup/record a sale but still cannot
  -- create/update a client; clients rw retains the complete workflow.
  v_result := public.staff_create_client(
    v_business,gen_random_uuid(),'V41 till phone fixture',v_phone,null,null,null,
    false,null,'v41-till-phone-fixture'
  );
  v_phone_client := (v_result->>'client_id')::uuid;
  reset role;
  select count(*) into v_till_sales_before from public.sales
   where business_id=v_business and client_id=v_phone_client;

  perform pg_temp.as_v41_user(v_restricted);
  perform pg_temp.expect_v41_denied(format(
    'select public.lookup_client_by_phone(%L::uuid,%L)',v_business,v_phone
  ),'missing clients key phone lookup PII','42501');
  perform pg_temp.expect_v41_denied(format(
    'select public.record_sale_by_phone(%L::uuid,%L,100,%L,%L,null,%L,%L::uuid,%L)',
    v_business,v_phone,'quick_sale','v41 denied till sale','v41-denied-till-sale',v_branch,'cash'
  ),'missing clients key record sale by phone','42501');
  reset role;
  if (select count(*) from public.sales
       where business_id=v_business and client_id=v_phone_client) <> v_till_sales_before then
    raise exception 'missing clients key created a till sale despite denial';
  end if;

  perform pg_temp.as_v41_user(v_readonly);
  v_result := public.lookup_client_by_phone(v_business,v_phone)::jsonb;
  if v_result->>'status' <> 'found' or (v_result->>'client_id')::uuid <> v_phone_client then
    raise exception 'clients r phone lookup failed: %',v_result;
  end if;
  v_result := public.record_sale_by_phone(
    v_business,v_phone,100,'quick_sale','v41 readonly till sale',null,
    'v41-readonly-till-sale',v_branch,'cash'
  )::jsonb;
  if v_result->>'status' <> 'ok' or (v_result->>'client_id')::uuid <> v_phone_client then
    raise exception 'clients r could not record authorized till sale: %',v_result;
  end if;
  v_first := v_result;
  v_replay := public.record_sale_by_phone(
    v_business,v_phone,100,'quick_sale','v41 readonly till sale',null,
    'v41-readonly-till-sale',v_branch,'cash'
  )::jsonb;
  if v_replay->>'status' <> 'duplicate_ignored'
     or v_replay->>'sale_id' is distinct from v_first->>'sale_id'
     or v_replay->>'client_id' is distinct from v_first->>'client_id' then
    raise exception 'exact Till replay did not return the original sale identity: %, %',
      v_first,v_replay;
  end if;
  perform pg_temp.expect_v41_denied(format(
    'select public.record_sale_by_phone(%L::uuid,%L,101,%L,%L,null,%L,%L::uuid,%L)',
    v_business,v_phone,'quick_sale','v41 readonly till sale','v41-readonly-till-sale',v_branch,'cash'
  ),'changed Till request under one key','23505');
  perform pg_temp.expect_v41_denied(format(
    'select public.staff_create_client(%L::uuid,%L::uuid,%L,null,null,null,null,false,null,%L)',
    v_business,gen_random_uuid(),'V41 readonly still denied','v41-readonly-still-denied'
  ),'clients r still cannot create client','42501');

  perform pg_temp.as_v41_user(v_rw);
  v_result := public.lookup_client_by_phone(v_business,v_phone)::jsonb;
  if v_result->>'status' <> 'found' or (v_result->>'client_id')::uuid <> v_phone_client then
    raise exception 'clients rw phone lookup failed: %',v_result;
  end if;
  v_result := public.record_sale_by_phone(
    v_business,v_phone,200,'quick_sale','v41 rw till sale',null,
    'v41-rw-till-sale',v_branch,'cash'
  )::jsonb;
  if v_result->>'status' <> 'ok' or (v_result->>'client_id')::uuid <> v_phone_client then
    raise exception 'clients rw till workflow failed: %',v_result;
  end if;
  reset role;
  if (select count(*) from public.sales
       where business_id=v_business and client_id=v_phone_client) - v_till_sales_before <> 2 then
    raise exception 'authorized r/rw till sale reconciliation is not exactly two rows';
  end if;
  perform pg_temp.as_v41_user(v_owner);

  -- Wrong tenant, inactive staff, restricted staff without the clients module,
  -- and anon are denied. Restricted legacy modules still include clients, but
  -- the non-null override intentionally omits it.
  perform pg_temp.expect_v41_denied(format(
    'select public.staff_set_marketing_consent(%L::uuid,%L::uuid,%L::uuid,true,%L)',
    v_other_business,v_other_client,gen_random_uuid(),'v41-wrong-tenant'
  ),'wrong tenant consent','42501');
  perform pg_temp.expect_v41_denied(format(
    'select public.staff_set_marketing_consent(%L::uuid,%L::uuid,%L::uuid,true,%L)',
    v_business,v_other_client,gen_random_uuid(),'v41-cross-tenant-client'
  ),'wrong tenant consent client reference','22023');
  perform pg_temp.expect_v41_denied(format(
    'select public.staff_create_client(%L::uuid,%L::uuid,%L,null,null,null,null,false,null,%L)',
    v_other_business,gen_random_uuid(),'V41 wrong tenant create','v41-wrong-tenant-create'
  ),'wrong tenant create-client consent','42501');
  perform pg_temp.as_v41_user(v_restricted);
  perform pg_temp.expect_v41_denied(format(
    'select public.staff_create_client(%L::uuid,%L::uuid,%L,null,null,null,null,false,null,%L)',
    v_business,gen_random_uuid(),'V41 restricted denied','v41-restricted'
  ),'restricted staff consent','42501');
  perform pg_temp.as_v41_user(v_inactive);
  perform pg_temp.expect_v41_denied(format(
    'select public.staff_set_marketing_consent(%L::uuid,%L::uuid,%L::uuid,true,%L)',
    v_business,v_toggle_client,gen_random_uuid(),'v41-inactive'
  ),'inactive staff consent','42501');
  perform pg_temp.expect_v41_denied(format(
    'select public.staff_create_client(%L::uuid,%L::uuid,%L,null,null,null,null,false,null,%L)',
    v_business,gen_random_uuid(),'V41 inactive create','v41-inactive-create'
  ),'inactive staff create-client consent','42501');
  perform pg_temp.as_v41_user(null,'anon');
  perform pg_temp.expect_v41_denied(format(
    'select public.staff_set_marketing_consent(%L::uuid,%L::uuid,%L::uuid,true,%L)',
    v_business,v_toggle_client,gen_random_uuid(),'v41-anon'
  ),'anon consent','42501');
  perform pg_temp.expect_v41_denied(format(
    'select public.staff_create_client(%L::uuid,%L::uuid,%L,null,null,null,null,false,null,%L)',
    v_business,gen_random_uuid(),'V41 anon create','v41-anon-create'
  ),'anon create-client consent','42501');

  -- One issuance key represents one card liability and one sale. Replaying after
  -- a hypothetical lost response returns the original identifiers/code; changed
  -- payload conflicts and liability remains unchanged.
  reset role;
  select count(*),coalesce(sum(balance_cents),0) into v_before_cards,v_before_liability
    from public.gift_cards where business_id=v_business;
  select count(*) into v_before_sales from public.sales
   where business_id=v_business and kind='gift_card';
  perform pg_temp.as_v41_user(v_owner);
  v_first := public.issue_gift_card(v_business,5000,v_client,'v41-gift@example.test',v_gift_key);
  v_replay := public.issue_gift_card(v_business,5000,v_client,'v41-gift@example.test',v_gift_key);
  v_card := (v_first->>'gift_card_id')::uuid;
  v_sale := (v_first->>'sale_id')::uuid;
  v_code := v_first->>'code';
  if (v_replay->>'gift_card_id')::uuid <> v_card
     or (v_replay->>'sale_id')::uuid <> v_sale
     or v_replay->>'code' <> v_code
     or v_replay is distinct from v_first then
    raise exception 'exact gift-card replay did not return original card/sale/code: %, %',v_first,v_replay;
  end if;
  -- Lost-response replay: the caller receives no first response and retries the
  -- same key; the database still returns the same completed logical issuance.
  v_result := public.issue_gift_card(v_business,5000,v_client,'v41-gift@example.test',v_gift_key);
  if (v_result->>'gift_card_id')::uuid <> v_card or v_result->>'code' <> v_code then
    raise exception 'lost-response replay did not reconcile to the original issuance';
  end if;
  reset role;
  select count(*),coalesce(sum(balance_cents),0) into v_after_cards,v_after_liability
    from public.gift_cards where business_id=v_business;
  select count(*) into v_after_sales from public.sales
   where business_id=v_business and kind='gift_card';
  if v_after_cards-v_before_cards <> 1
     or v_after_sales-v_before_sales <> 1
     or v_after_liability-v_before_liability <> 5000 then
    raise exception 'liability unchanged contract failed on replay: cards %, sales %, liability %',
      v_after_cards-v_before_cards,v_after_sales-v_before_sales,v_after_liability-v_before_liability;
  end if;
  if (select initial_cents from public.gift_cards where id=v_card) <> 5000
     or (select balance_cents from public.gift_cards where id=v_card) <> 5000
     or (select amount_cents from public.sales where id=v_sale and kind='gift_card') <> 5000 then
    raise exception 'gift-card sale reconciliation failed';
  end if;
  perform pg_temp.as_v41_user(v_owner);
  perform pg_temp.expect_v41_denied(format(
    'select public.issue_gift_card(%L::uuid,6000,%L::uuid,%L,%L::uuid)',
    v_business,v_client,'v41-gift@example.test',v_gift_key
  ),'changed gift-card request','23505');
  perform pg_temp.expect_v41_denied(format(
    'select public.issue_gift_card(%L::uuid,5000,%L::uuid,null,%L::uuid)',
    v_business,v_other_client,gen_random_uuid()
  ),'wrong-tenant purchaser','22023');

  perform pg_temp.as_v41_user(v_inactive);
  perform pg_temp.expect_v41_denied(format(
    'select public.issue_gift_card(%L::uuid,5000,null,null,%L::uuid)',
    v_business,gen_random_uuid()
  ),'inactive staff gift','42501');
  perform pg_temp.as_v41_user(v_restricted);
  perform pg_temp.expect_v41_denied(format(
    'select public.issue_gift_card(%L::uuid,5000,null,null,%L::uuid)',
    v_business,gen_random_uuid()
  ),'restricted staff gift','42501');
  perform pg_temp.as_v41_user(null,'anon');
  perform pg_temp.expect_v41_denied(format(
    'select public.issue_gift_card(%L::uuid,5000,null,null,%L::uuid)',
    v_business,gen_random_uuid()
  ),'anon gift','42501');

  -- The authorized list projection is bounded and masks the bearer code. Raw
  -- SELECT remains denied even to the same-business owner.
  perform pg_temp.as_v41_user(v_owner);
  v_list := public.staff_list_gift_cards(v_business,5000);
  if v_list::text like '%' || v_code || '%'
     or v_list::text not like '%' || right(v_code,4) || '%' then
    raise exception 'full bearer code leaked or suffix missing from gift-card list: %',v_list;
  end if;
  perform pg_temp.expect_v41_denied(
    'select code from public.gift_cards limit 1',
    'raw table full bearer code','42501'
  );

  -- Authorized financial wrapper success preserves the gift-card liability and
  -- credit-ledger reconciliation. It exposes no raw table write path.
  reset role;
  select coalesce(sum(amount_cents),0) into v_credit_before from public.credit_ledger
   where business_id=v_business and client_id=v_toggle_client;
  perform pg_temp.as_v41_user(v_owner);
  v_result := public.redeem_gift_card_v41(v_business,v_code,v_toggle_client,1000)::jsonb;
  reset role;
  if (v_result->>'loaded_cents')::integer <> 1000
     or (v_result->>'remaining_cents')::integer <> 4000
     or (select balance_cents from public.gift_cards where id=v_card) <> 4000
     or (select coalesce(sum(amount_cents),0) from public.credit_ledger
          where business_id=v_business and client_id=v_toggle_client) - v_credit_before <> 1000 then
    raise exception 'gift-card credit ledger reconciliation failed: %',v_result;
  end if;
  if not exists(
    select 1 from public.audit_log
     where business_id=v_business and entity='credit_ledger' and action='INSERT'
  ) then raise exception 'gift-card credit ledger audit evidence is missing'; end if;
  perform pg_temp.as_v41_user(v_owner);
  v_replay := public.issue_gift_card(
    v_business,5000,v_client,'v41-gift@example.test',v_gift_key
  );
  if (v_replay->>'gift_card_id')::uuid <> v_card
     or (v_replay->>'sale_id')::uuid <> v_sale
     or v_replay->>'code' <> v_code
     or (v_replay->>'initial_cents')::integer <> 5000
     or (v_replay->>'balance_cents')::integer <> 5000 then
    raise exception 'issuance replay depended on mutable redeemed balance: %',v_replay;
  end if;

  -- Authorized referral/membership RPC success, including referral provenance,
  -- membership audit evidence, and one reconciled membership sale.
  v_result := public.save_referral_program(v_business,true,700,1000);
  v_referral_program := (v_result->>'program_id')::uuid;
  v_result := public.staff_create_client(
    v_business,gen_random_uuid(),'V41 referral source',null,null,null,null,
    false,null,'v41-referral-source'
  );
  v_referrer := (v_result->>'client_id')::uuid;
  select referral_code into v_referral_code from public.clients where id=v_referrer;
  v_result := public.staff_create_client(
    v_business,gen_random_uuid(),'V41 referral target',null,null,null,null,
    false,v_referral_code,'v41-referral-target'
  );
  v_referred := (v_result->>'client_id')::uuid;
  if (v_result->>'referral_id') is null
     or not exists(select 1 from public.referrals
                    where id=(v_result->>'referral_id')::uuid
                      and referrer_client_id=v_referrer and referred_client_id=v_referred) then
    raise exception 'authorized client RPC did not preserve referral provenance: %',v_result;
  end if;
  v_result := public.save_membership_plan(
    v_business,null,'V41 module plan',2500,'monthly',1000,0,true
  );
  v_plan := (v_result->>'plan_id')::uuid;
  v_result := public.enroll_membership_v41(v_business,v_referred,v_plan)::jsonb;
  v_membership := (v_result->>'id')::uuid;
  v_result := public.set_membership_status(v_business,v_membership,'paused');
  if v_result->>'membership_status' <> 'paused'
     or (select status from public.memberships where id=v_membership) <> 'paused'
     or not exists(select 1 from public.sales
                    where business_id=v_business and client_id=v_referred
                      and kind='membership' and amount_cents=2500)
     or not exists(select 1 from public.audit_log
                    where business_id=v_business and entity='memberships'
                      and entity_id=v_membership and action='UPDATE') then
    raise exception 'membership RPC sale/audit reconciliation failed: %',v_result;
  end if;

  -- Prove module boundaries for missing-key and read-only clients overrides,
  -- then authorized owner reads.
  perform pg_temp.as_v41_user(v_restricted);
  if exists(select 1 from public.clients where business_id=v_business)
     or exists(select 1 from public.consents where business_id=v_business)
     or exists(select 1 from public.referrals where business_id=v_business)
     or exists(select 1 from public.referral_programs where business_id=v_business)
     or exists(select 1 from public.membership_plans where business_id=v_business)
     or exists(select 1 from public.memberships where business_id=v_business) then
    raise exception 'missing-key module boundary exposed customer-module rows';
  end if;

  perform pg_temp.as_v41_user(v_readonly);
  select count(*) into v_count from public.consents where business_id=v_business;
  if v_count < 1 or not exists(select 1 from public.clients where business_id=v_business) then
    raise exception 'r clients override could not read clients and consent evidence';
  end if;
  if exists(select 1 from public.consents where business_id=v_other_business)
     or exists(select 1 from public.referrals where business_id=v_business)
     or exists(select 1 from public.referral_programs where business_id=v_business)
     or exists(select 1 from public.membership_plans where business_id=v_business)
     or exists(select 1 from public.memberships where business_id=v_business) then
    raise exception 'r clients override crossed tenant, referrals, or memberships module boundary';
  end if;
  perform pg_temp.expect_v41_denied(
    'update public.consents set source=source where false',
    'same-business raw table consent write','42501'
  );
  perform pg_temp.expect_v41_denied(
    'update public.referral_programs set enabled=enabled where false',
    'same-business raw table referral-program write','42501'
  );
  perform pg_temp.expect_v41_denied(
    'update public.referrals set status=status where false',
    'same-business raw table referral write','42501'
  );
  perform pg_temp.expect_v41_denied(
    'update public.membership_plans set active=active where false',
    'same-business raw table membership-plan write','42501'
  );
  perform pg_temp.expect_v41_denied(
    'update public.memberships set status=status where false',
    'same-business raw table membership write','42501'
  );

  perform pg_temp.as_v41_user(v_owner);
  if not exists(select 1 from public.referrals where business_id=v_business and referred_client_id=v_referred)
     or not exists(select 1 from public.referral_programs where id=v_referral_program)
     or not exists(select 1 from public.membership_plans where id=v_plan)
     or not exists(select 1 from public.memberships where id=v_membership) then
    raise exception 'authorized RPC/read module owner could not read seeded customer-module state';
  end if;

  -- Simultaneous same-key serialization contract is inspected statically by the
  -- Node suite; sequential exact/lost-response calls above prove one card+sale.
  raise notice 'v41 customer module integrity suite: ALL PASS';
end $v41_test$;

rollback;
