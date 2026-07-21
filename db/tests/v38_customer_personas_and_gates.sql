-- Rollback-only v38 customer personas and private gates suite.
begin;

do $v38_test$
declare
  v_owner uuid;
  v_business uuid;
  v_business_slug text;
  v_payload jsonb;
  v_capabilities jsonb;
  v_identity_count integer;
  v_client uuid;
  v_invitation jsonb;
  v_claim jsonb;
  v_customer_only uuid := gen_random_uuid();
  v_restricted_staff uuid := gen_random_uuid();
  v_customer_client uuid;
  v_other_business uuid;
  v_other_slug text;
begin
  select s.business_id, s.user_id, b.slug into v_business, v_owner, v_business_slug
    from public.staff s
    join public.businesses b on b.id = s.business_id
    join auth.users u on u.id = s.user_id and u.email_confirmed_at is not null
   where s.role = 'owner' and s.active and s.user_id is not null
     and not exists (
       select 1 from public.customer_links l
        where l.auth_user_id = s.user_id and l.business_id = s.business_id and l.state = 'verified'
     )
   order by s.created_at
   limit 1;
  if v_owner is null then
    raise exception 'v38 suite requires an active owner';
  end if;
  select b.id, b.slug into v_other_business, v_other_slug
    from public.businesses b where b.id <> v_business order by b.created_at limit 1;
  if v_other_business is null then
    raise exception 'v38 suite requires two businesses for persona isolation';
  end if;

  perform set_config('request.jwt.claims', json_build_object('sub', v_owner, 'role', 'authenticated')::text, true);
  update app.platform_feature_flags set enabled = false, changed_at = now()
   where feature_key like 'customer_%';

  v_capabilities := public.get_customer_feature_capabilities();
  if v_capabilities <> jsonb_build_object(
    'customer_identity', false, 'customer_claims', false, 'customer_wallet', false,
    'customer_actions', false, 'customer_notifications', false, 'customer_email_otp', false
  ) then
    raise exception 'disabled customer capabilities were not fail closed: %', v_capabilities;
  end if;

  select count(*) into v_identity_count from public.customer_identities;
  begin
    perform public.customer_create_identity('v38-disabled-identity');
    raise exception 'disabled customer identity gate allowed a write';
  exception when sqlstate '0A000' then null;
  end;
  begin
    perform public.customer_claim_link_by_email(v_business_slug, 'v38-disabled-claim');
    raise exception 'disabled customer claims gate resolved identity or business state';
  exception when sqlstate '0A000' then null;
  end;
  if (select count(*) from public.customer_identities) <> v_identity_count then
    raise exception 'disabled customer gate changed identity state';
  end if;

  v_payload := public.get_my_personas();

  if jsonb_typeof(v_payload->'staff') <> 'array'
     or jsonb_typeof(v_payload->'customer') <> 'array'
     or v_payload ? 'client_id'
     or v_payload ? 'phone'
     or v_payload ? 'email'
     or v_payload ? 'balance'
     or v_payload::text ~ '"(client_id|phone|email|balance_cents|points_balance)"' then
    raise exception 'persona payload exposes unsafe shape: %', v_payload;
  end if;
  if jsonb_array_length(v_payload->'staff') < 1 then
    raise exception 'staff persona missing for active owner';
  end if;
  if v_payload->>'default_route' is distinct from '#/workspace/' || v_business_slug || '/dashboard' then
    raise exception 'staff default route is not workspace scoped: %', v_payload->>'default_route';
  end if;
  if v_payload->'staff'->0 ? 'client_id'
     or v_payload->'staff'->0 ? 'email'
     or v_payload->'staff'->0 ? 'phone'
     or v_payload->'staff'->0 ? 'balance' then
    raise exception 'staff persona leaked private fields: %', v_payload->'staff'->0;
  end if;

  -- Enable the three local journey gates and prove a dual-role invitation can
  -- appear, then disappears immediately after an audited unlink. This remains
  -- inside the rollback transaction and never changes production state.
  update app.platform_feature_flags set enabled = true, changed_at = now()
   where feature_key in ('customer_identity', 'customer_claims', 'customer_wallet');
  v_payload := public.get_my_personas();
  if jsonb_array_length(v_payload->'staff') < 1
     or jsonb_array_length(v_payload->'customer') <> 0 then
    raise exception 'enabled staff-only persona was not isolated: %', v_payload;
  end if;
  perform public.customer_create_identity('v38-dual-identity');
  insert into public.clients(business_id, full_name, email)
  select v_business, 'V38 invitation target', lower(btrim(u.email))
    from auth.users u where u.id = v_owner
  returning id into v_client;
  v_invitation := public.customer_issue_link_invitation(
    v_business, v_client, 'v38-dual-invitation', 30
  )::jsonb;
  if nullif(v_invitation->>'token', '') is null then
    raise exception 'dual-role invitation did not return its one-time secret';
  end if;
  v_claim := public.customer_claim_link_invitation(
    v_invitation->>'token', 'v38-dual-claim'
  )::jsonb;
  if v_claim->>'outcome' is distinct from 'linked' then
    raise exception 'dual-role invitation did not create a verified link: %', v_claim;
  end if;
  v_payload := public.get_my_personas();
  if jsonb_array_length(v_payload->'staff') < 1
     or jsonb_array_length(v_payload->'customer') <> 1 then
    raise exception 'dual-role persona arrays are incomplete: %', v_payload;
  end if;
  if public.customer_unlink_business_link(v_business_slug, 'v38-dual-unlink')->>'outcome'
       is distinct from 'unlinked' then
    raise exception 'dual-role unlink did not succeed';
  end if;
  v_payload := public.get_my_personas();
  if jsonb_array_length(v_payload->'customer') <> 0
     or not exists (select 1 from public.clients where id = v_client and business_id = v_business)
     or not exists (
       select 1 from public.customer_link_unlink_events e
        where e.business_id = v_business and e.client_id = v_client
     ) then
    raise exception 'unlink did not revoke authority while retaining client and audit history';
  end if;

  -- A customer-only principal sees exactly its linked business, never an
  -- unrelated business or a staff workspace.
  reset role;
  insert into auth.users(instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at)
  values ('00000000-0000-0000-0000-000000000000', v_customer_only,
          'authenticated','authenticated','v38-customer-only@example.test','',now(),now(),now());
  insert into public.clients(business_id,full_name,email)
  values (v_business,'V38 customer only','v38-customer-only@example.test')
  returning id into v_customer_client;
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner, 'role', 'authenticated')::text, true);
  v_invitation := public.customer_issue_link_invitation(
    v_business, v_customer_client, 'v38-customer-invitation', 30
  )::jsonb;
  perform set_config('request.jwt.claims', json_build_object('sub', v_customer_only, 'role', 'authenticated')::text, true);
  perform public.customer_create_identity('v38-customer-identity');
  if public.customer_claim_link_invitation(v_invitation->>'token', 'v38-customer-claim')->>'outcome'
       is distinct from 'linked' then
    raise exception 'customer-only invitation claim failed';
  end if;
  v_payload := public.get_my_personas();
  if jsonb_array_length(v_payload->'staff') <> 0
     or jsonb_array_length(v_payload->'customer') <> 1
     or v_payload->>'default_route' is distinct from '#/wallet'
     or position(v_other_slug in v_payload::text) > 0 then
    raise exception 'customer-only or cross-business persona isolation failed: %', v_payload;
  end if;

  -- Restricted modules use the deployed staff.modules array and remain
  -- intersected with firm-enabled modules.
  reset role;
  insert into auth.users(instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at)
  values ('00000000-0000-0000-0000-000000000000', v_restricted_staff,
          'authenticated','authenticated','v38-restricted-staff@example.test','',now(),now(),now());
  update public.businesses
     set enabled_modules = case
       when 'clients' = any(coalesce(enabled_modules, '{}'::text[])) then enabled_modules
       else array_append(coalesce(enabled_modules, '{}'::text[]), 'clients') end
   where id = v_business;
  insert into public.staff(business_id,user_id,role,full_name,active,modules)
  values (v_business,v_restricted_staff,'staff','V38 restricted staff',true,array['clients']);
  perform set_config('request.jwt.claims', json_build_object('sub', v_restricted_staff, 'role', 'authenticated')::text, true);
  v_payload := public.get_my_personas();
  if jsonb_array_length(v_payload->'staff') <> 1
     or jsonb_array_length(v_payload->'customer') <> 0
     or v_payload->'staff'->0->'modules' is distinct from '["clients"]'::jsonb
     or position(v_other_slug in v_payload::text) > 0 then
    raise exception 'restricted modules or staff cross-business isolation failed: %', v_payload;
  end if;

  if (select count(*) from app.platform_feature_flags
     where feature_key in ('customer_identity','customer_claims','customer_wallet',
                           'customer_actions','customer_notifications','customer_email_otp')
  ) <> 6 then
    raise exception 'missing v38 private feature gates';
  end if;

  if has_table_privilege('authenticated', 'app.platform_feature_flags', 'select')
     or has_table_privilege('anon', 'app.platform_feature_flags', 'select') then
    raise exception 'private customer feature table is browser-readable';
  end if;

  if not has_function_privilege('authenticated', 'public.get_my_personas()', 'execute')
     or has_function_privilege('anon', 'public.get_my_personas()', 'execute')
     or not has_function_privilege('authenticated', 'public.get_customer_feature_capabilities()', 'execute')
     or has_function_privilege('anon', 'public.get_customer_feature_capabilities()', 'execute') then
    raise exception 'v38 public RPC ACL is incorrect';
  end if;

  if (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public'
       and p.proname in ('get_my_personas', 'get_customer_feature_capabilities')
       and p.prosecdef
       and p.proconfig @> array['search_path=pg_catalog, public, app, pg_temp']
  ) <> 2 then
    raise exception 'v38 security-definer search_path contract is incorrect';
  end if;

  raise notice 'v38 customer personas and gates suite: ALL PASS';
end $v38_test$;

rollback;
