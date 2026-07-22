-- Rollback-only v41 transactional customer-module smoke/reconciliation suite.
-- Run after the complete canonical chain through v41.
begin;
\ir fixtures/pristine_chain_fixture.psql

-- Keep this suite reproducible on a freshly materialized canonical database.
-- The synthetic tenant is transaction-local because the suite always rolls back.
create temporary table pg_temp.v41_hardening_fixture (
  business_id uuid primary key,
  owner_id uuid not null unique
) on commit drop;

do $v41_fixture$
declare
  v_owner uuid := gen_random_uuid();
  v_business uuid;
begin
  insert into auth.users (
    instance_id, id, aud, role, email, encrypted_password,
    email_confirmed_at, created_at, updated_at
  ) values (
    '00000000-0000-0000-0000-000000000000', v_owner,
    'authenticated', 'authenticated',
    'v41-hardening-owner-' || substr(v_owner::text, 1, 8) || '@example.test',
    '', now(), now(), now()
  );
  insert into public.businesses (name, slug, industry, enabled_modules)
  values (
    'V41 hardening fixture',
    'v41-hardening-' || substr(v_owner::text, 1, 8),
    'test',
    array['dashboard','clients','sales','loyalty','referrals','memberships','giftcards']
  ) returning id into v_business;
  insert into public.staff (
    business_id, user_id, role, full_name, active, modules, module_perms
  ) values (
    v_business, v_owner, 'owner', 'V41 hardening owner', true, null, null
  );
  insert into pg_temp.v41_hardening_fixture(business_id, owner_id)
  values (v_business, v_owner);
end
$v41_fixture$;

do $v41_test$
declare
  v_business uuid;
  v_owner uuid;
  v_override_user uuid := gen_random_uuid();
  v_override_staff uuid;
  v_create_key uuid := gen_random_uuid();
  v_consent_key uuid := gen_random_uuid();
  v_gift_key uuid := gen_random_uuid();
  v_create jsonb;
  v_replay jsonb;
  v_consent jsonb;
  v_gift jsonb;
  v_client uuid;
  v_before integer;
  v_blocked boolean;
  v_signature text;
begin
  select f.business_id, f.owner_id into v_business, v_owner
    from pg_temp.v41_hardening_fixture f;
  if v_business is null then
    raise exception 'v41 suite requires one active owner fixture';
  end if;
  perform set_config('request.jwt.claim.sub', v_owner::text, true);
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_owner, 'role', 'authenticated')::text, true);

  foreach v_signature in array array[
    'staff_create_client(uuid,uuid,text,text,text,date,text,boolean,text,text)',
    'staff_set_marketing_consent(uuid,uuid,uuid,boolean,text)',
    'issue_gift_card(uuid,integer,uuid,text,uuid)',
    'staff_list_gift_cards(uuid,integer)',
    'save_referral_program(uuid,boolean,integer,integer)',
    'save_membership_plan(uuid,uuid,text,integer,text,integer,numeric,boolean)',
    'set_membership_status(uuid,uuid,text)',
    'enroll_membership_v41(uuid,uuid,uuid)',
    'redeem_gift_card_v41(uuid,text,uuid,integer)'
  ] loop
    if to_regprocedure('public.' || v_signature) is null then
      raise exception 'missing v41 RPC %', v_signature;
    end if;
    if has_function_privilege('anon', to_regprocedure('public.' || v_signature), 'execute')
       or not has_function_privilege('authenticated', to_regprocedure('public.' || v_signature), 'execute') then
      raise exception 'v41 RPC ACL is not authenticated-only: %', v_signature;
    end if;
  end loop;
  if has_function_privilege('authenticated',
       'public.issue_gift_card(uuid,integer,uuid,text)'::regprocedure, 'execute')
     or has_function_privilege('authenticated',
       'public.quick_add_client(uuid,text,text,boolean)'::regprocedure, 'execute') then
    raise exception 'legacy customer or gift-card browser execution remains';
  end if;

  select count(*) into v_before from public.clients where business_id = v_business;
  v_create := public.staff_create_client(
    v_business, v_create_key, 'V41 Atomic Customer', '+65 8111 2233',
    'v41-atomic@example.test', null, null, false, null, 'v41 rollback suite');
  v_replay := public.staff_create_client(
    v_business, v_create_key, 'V41 Atomic Customer', '+65 8111 2233',
    'v41-atomic@example.test', null, null, false, null, 'v41 rollback suite');
  if v_replay is distinct from v_create
     or (select count(*) from public.clients where business_id = v_business) <> v_before + 1
     or (select count(*) from public.consents
          where id = (v_create->>'consent_event_id')::uuid) <> 1 then
    raise exception 'exact create-client replay duplicated or changed the completed result';
  end if;
  v_client := (v_create->>'client_id')::uuid;
  v_blocked := false;
  begin
    perform public.staff_create_client(
      v_business, v_create_key, 'V41 Changed Customer', '+65 8111 2233',
      'v41-atomic@example.test', null, null, false, null, 'v41 rollback suite');
  exception when unique_violation then
    v_blocked := true;
  end;
  if not v_blocked then
    raise exception 'changed create-client request did not raise SQLSTATE 23505';
  end if;

  v_consent := public.staff_set_marketing_consent(
    v_business, v_client, v_consent_key, true, 'v41 rollback suite');
  if public.staff_set_marketing_consent(
       v_business, v_client, v_consent_key, true, 'v41 rollback suite') is distinct from v_consent
     or (select count(*) from public.consents
          where id = (v_consent->>'consent_event_id')::uuid) <> 1
     or not (select marketing_consent from public.clients where id = v_client) then
    raise exception 'exact consent replay duplicated its event or lost the client flag';
  end if;

  v_gift := public.issue_gift_card(
    v_business, 2500, v_client, 'gift@example.test', v_gift_key);
  if public.issue_gift_card(
       v_business, 2500, v_client, 'gift@example.test', v_gift_key) is distinct from v_gift
     or (select count(*) from public.gift_cards
          where id = (v_gift->>'gift_card_id')::uuid) <> 1
     or (select count(*) from public.sales
          where id = (v_gift->>'sale_id')::uuid and kind = 'gift_card' and amount_cents = 2500) <> 1 then
    raise exception 'exact gift-card replay did not reconcile to one card and one sale';
  end if;
  v_blocked := false;
  begin
    perform public.issue_gift_card(
      v_business, 2600, v_client, 'gift@example.test', v_gift_key);
  exception when unique_violation then
    v_blocked := true;
  end;
  if not v_blocked then
    raise exception 'changed gift-card request did not raise SQLSTATE 23505';
  end if;
  if public.staff_list_gift_cards(v_business, 100)::text like '%"code":"%'
     or public.staff_list_gift_cards(v_business, 100)::text like '%gift@example.test%' then
    raise exception 'bounded gift-card projection leaked a full bearer code or recipient PII';
  end if;

  if has_table_privilege('authenticated', 'public.clients', 'insert')
     or has_table_privilege('authenticated', 'public.clients', 'update')
     or has_table_privilege('authenticated', 'public.consents', 'insert')
     or has_table_privilege('authenticated', 'public.referrals', 'insert')
     or has_table_privilege('authenticated', 'public.referral_programs', 'update')
     or has_table_privilege('authenticated', 'public.gift_cards', 'select')
     or has_table_privilege('authenticated', 'public.gift_cards', 'insert')
     or has_table_privilege('authenticated', 'public.membership_plans', 'insert')
     or has_table_privilege('authenticated', 'public.memberships', 'update') then
    raise exception 'raw browser customer-module write or gift-card read privilege remains';
  end if;
  if has_table_privilege('authenticated', 'public.customer_staff_operations', 'select')
     or has_table_privilege('authenticated', 'public.gift_card_issue_operations', 'select') then
    raise exception 'private operation request hashes/results are browser-readable';
  end if;

  insert into auth.users (
    instance_id, id, aud, role, email, encrypted_password,
    email_confirmed_at, created_at, updated_at
  ) values (
    '00000000-0000-0000-0000-000000000000', v_override_user,
    'authenticated', 'authenticated',
    'v41-override-' || substr(v_override_user::text, 1, 8) || '@example.test',
    '', now(), now(), now()
  );
  insert into public.staff (
    business_id, user_id, role, full_name, active, modules, module_perms
  ) values (
    v_business, v_override_user, 'manager', 'V41 override staff', true,
    array['inventory'], '{"clients":"rw","loyalty":"rw"}'::jsonb
  ) returning id into v_override_staff;
  perform set_config('request.jwt.claim.sub', v_override_user::text, true);
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_override_user, 'role', 'authenticated')::text, true);
  if app.can_module(v_business, 'clients')
     or not app.can_module_read(v_business, 'clients')
     or not app.can_module_write(v_business, 'clients')
     or not app.can_module_read(v_business, 'loyalty')
     or not app.can_module_write(v_business, 'loyalty')
     or not ('clients' = any(app.staff_modules(v_business))) then
    raise exception 'clients:rw and loyalty:rw overrides did not supersede the legacy modules allowlist';
  end if;
  if public.lookup_client_by_phone(v_business, '+65 8111 2233')::jsonb->>'status' <> 'found' then
    raise exception 'rw client override could not use the Till customer lookup';
  end if;
  update public.staff set module_perms = '{"clients":"r","loyalty":"r"}'::jsonb where id = v_override_staff;
  if not app.can_module_read(v_business, 'clients')
     or app.can_module_write(v_business, 'clients')
     or not app.can_module_read(v_business, 'loyalty')
     or app.can_module_write(v_business, 'loyalty') then
    raise exception 'explicit clients:r and loyalty:r overrides did not remain read-only';
  end if;
  if public.lookup_client_by_phone(v_business, '+65 8111 2233')::jsonb->>'status' <> 'found' then
    raise exception 'read-only client override could not use the Till customer lookup';
  end if;
  begin
    perform public.record_sale_by_phone(
      v_business,'+65 8111 2233',0,'quick_sale',null,null,
      'v41-readonly-invalid',null,'cash'
    );
    raise exception 'read-only client override unexpectedly accepted an invalid sale';
  exception when sqlstate '22023' then null;
  end;
  update public.staff set module_perms = '{}'::jsonb where id = v_override_staff;
  if app.can_module_read(v_business, 'clients')
     or app.can_module_write(v_business, 'clients')
     or 'clients' = any(app.staff_modules(v_business)) then
    raise exception 'absent module override key did not fail closed';
  end if;
  v_blocked := false;
  begin
    perform public.lookup_client_by_phone(v_business, '+65 8111 2233');
  exception when insufficient_privilege then
    v_blocked := true;
  end;
  if not v_blocked then
    raise exception 'sales-only staff bypassed clients RLS through Till lookup';
  end if;
  v_blocked := false;
  begin
    perform public.record_sale_by_phone(
      v_business,'+65 8111 2233',100,'quick_sale',null,null,
      'v41-sales-only-denied',null,'cash'
    );
  exception when insufficient_privilege then
    v_blocked := true;
  end;
  if not v_blocked then
    raise exception 'sales-only staff bypassed clients RLS through Till sale response';
  end if;

  raise notice 'v41 customer-module hardening suite: ALL PASS';
end
$v41_test$;

rollback;
