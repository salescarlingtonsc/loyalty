-- Rollback-only v81 customer relationship synchronization and history suite.
-- Covers exact linking, ambiguous matches, historical link evidence, idempotency,
-- cross-business isolation, pagination, standalone points without double-count,
-- raw table denial, and final v89 browser-route denial.
begin;
-- The v79 dual-table trigger dereferences branches.active on a businesses
-- record during the shared fixture's harmless timestamp normalization. Use its
-- documented system-transition seam only while seeding; v81 itself never uses it.
select set_config('app.v79_system_transition', 'on', true);
\ir fixtures/pristine_chain_fixture.psql
select set_config('app.v79_system_transition', '', true);

create or replace function pg_temp.as_v81_user(
  p_uid uuid,
  p_role text default 'authenticated'
) returns void language plpgsql as $$
begin
  execute format('set local role %I', p_role);
  perform set_config('request.jwt.claim.sub', coalesce(p_uid::text, ''), true);
  perform set_config('request.jwt.claims', json_build_object(
    'sub', p_uid, 'role', p_role
  )::text, true);
end
$$;
grant execute on function pg_temp.as_v81_user(uuid,text) to public;

do $v81_test$
declare
  v_user uuid := gen_random_uuid();
  v_business uuid;
  v_business_slug text;
  v_owner uuid;
  v_other_business uuid;
  v_other_slug text;
  v_ambiguous_business uuid;
  v_historical_business uuid;
  v_historical_slug text;
  v_exact_client uuid;
  v_already_client uuid;
  v_historical_client uuid;
  v_identity uuid;
  v_link uuid;
  v_historical_link uuid;
  v_response jsonb;
  v_replay jsonb;
  v_sale_result jsonb;
  v_sale uuid;
  v_reversal jsonb;
  v_page_one jsonb;
  v_page_two jsonb;
  v_history_text text;
  v_before jsonb;
  v_link_count integer;
begin
  reset role;
  select business.id, business.slug, owner_staff.user_id
    into v_business, v_business_slug, v_owner
    from public.businesses business
    join public.staff owner_staff
      on owner_staff.business_id = business.id
     and owner_staff.role = 'owner'
     and owner_staff.active
     and owner_staff.user_id is not null
   order by business.created_at, business.id
   limit 1;
  select business.id, business.slug
    into v_other_business, v_other_slug
    from public.businesses business
   where business.id <> v_business
   order by business.created_at, business.id
   limit 1;
  if v_business is null or v_other_business is null or v_owner is null then
    raise exception 'v81 suite requires the pristine two-business owner fixture';
  end if;

  update app.platform_feature_flags
     set enabled = true, changed_at = now()
   where feature_key in (
     'customer_claims', 'customer_phone_claims',
     'customer_phone_registration', 'customer_wallet'
   );

  insert into auth.users (
    instance_id, id, aud, role, email, phone, encrypted_password,
    email_confirmed_at, phone_confirmed_at, created_at, updated_at
  ) values (
    '00000000-0000-0000-0000-000000000000',
    v_user, 'authenticated', 'authenticated',
    'v81-customer@example.test', '+6581000081', '',
    now(), now(), now(), now()
  );
  insert into public.customer_identities(auth_user_id, status, created_via)
  values(v_user, 'active', 'phone_registration')
  returning id into v_identity;

  insert into public.clients(business_id, full_name, phone)
  values(v_business, 'V81 exact phone customer', '+65 8100 0081')
  returning id into v_exact_client;
  insert into public.clients(business_id, full_name, email)
  values(v_other_business, 'V81 already linked customer', 'v81-customer@example.test')
  returning id into v_already_client;

  insert into public.businesses(name, slug, industry)
  values(
    'V81 ambiguous fixture',
    'v81-ambiguous-' || substr(gen_random_uuid()::text, 1, 8),
    'test'
  ) returning id into v_ambiguous_business;
  insert into public.clients(business_id, full_name, email) values
    (v_ambiguous_business, 'V81 ambiguous A', 'v81-customer@example.test'),
    (v_ambiguous_business, 'V81 ambiguous B', 'v81-customer@example.test');

  insert into public.businesses(name, slug, industry)
  values(
    'V81 historical fixture',
    'v81-historical-' || substr(gen_random_uuid()::text, 1, 8),
    'test'
  ) returning id, slug into v_historical_business, v_historical_slug;
  insert into public.clients(business_id, full_name, email)
  values(v_historical_business, 'V81 historical client', 'v81-customer@example.test')
  returning id into v_historical_client;

  v_link := gen_random_uuid();
  perform set_config('app.customer_link_insert_id', v_link::text, true);
  insert into public.customer_links(
    id, business_id, identity_id, auth_user_id, client_id, state,
    verification_method, verified_at
  ) values (
    v_link, v_other_business, v_identity, v_user, v_already_client,
    'verified', 'email_claim', now()
  );
  perform set_config('app.customer_link_insert_id', '', true);

  v_historical_link := gen_random_uuid();
  perform set_config('app.customer_link_insert_id', v_historical_link::text, true);
  insert into public.customer_links(
    id, business_id, identity_id, auth_user_id, client_id, state,
    verification_method, verified_at
  ) values (
    v_historical_link, v_historical_business, v_identity, v_user,
    v_historical_client, 'verified', 'email_claim', now()
  );
  perform set_config('app.customer_link_insert_id', '', true);
  perform set_config('app.customer_link_transition_id', v_historical_link::text, true);
  update public.customer_links
     set state = 'unlinked',
         unlinked_at = now(),
         unlinked_by_auth_user_id = v_user
   where id = v_historical_link;
  perform set_config('app.customer_link_transition_id', '', true);

  -- v89 removes this legacy self-link route from authenticated browsers. Keep
  -- exercising the historical implementation through the service-only ACL,
  -- then assert the final browser denial below.
  perform pg_temp.as_v81_user(v_user, 'service_role');
  v_response := public.customer_sync_verified_relationships_v81(
    'v81-sync-idempotency'
  );
  reset role;
  if v_response->>'outcome' is distinct from 'synchronized'
     or (v_response->>'linked_count')::integer <> 1
     or (v_response->>'already_linked_count')::integer <> 1
     or (v_response->>'ambiguous_count')::integer <> 1
     or (v_response->>'matched_business_count')::integer <> 3 then
    raise exception 'exact/ambiguous/historical reconciliation result is wrong: %',
      v_response;
  end if;
  if not exists (
    select 1 from public.customer_links link
     where link.business_id = v_business
       and link.identity_id = v_identity
       and link.client_id = v_exact_client
       and link.state = 'verified'
       and link.verification_method = 'phone_claim'
  ) then
    raise exception 'verified exact phone relationship was not linked';
  end if;
  if exists (
    select 1 from public.customer_links link
     where link.business_id = v_ambiguous_business
       and link.identity_id = v_identity
       and link.state = 'verified'
  ) then
    raise exception 'ambiguous business was linked';
  end if;
  if exists (
    select 1 from public.customer_links link
     where link.id = v_historical_link and link.state <> 'unlinked'
  ) or exists (
    select 1 from public.customer_links link
     where link.business_id = v_historical_business
       and link.identity_id = v_identity
       and link.state = 'verified'
  ) then
    raise exception 'historical unlinked evidence was reassigned';
  end if;

  select count(*) into v_link_count
    from public.customer_links link
   where link.identity_id = v_identity;
  perform pg_temp.as_v81_user(v_user, 'service_role');
  v_replay := public.customer_sync_verified_relationships_v81(
    'v81-sync-idempotency'
  );
  reset role;
  if v_replay is distinct from v_response
     or (select count(*) from public.customer_links link
          where link.identity_id = v_identity) <> v_link_count then
    raise exception 'idempotency replay changed relationship evidence';
  end if;

  perform pg_temp.as_v81_user(v_owner);
  v_sale_result := public.record_quick_sale(
    v_business, 2580, 'cash', v_exact_client, null, null,
    'V81 customer history sale', 'v81-history-sale', true
  )::jsonb;
  reset role;
  v_sale := (v_sale_result#>>'{sale,id}')::uuid;
  if v_sale is null then
    raise exception 'history sale fixture was not recorded: %', v_sale_result;
  end if;

  perform pg_temp.as_v81_user(v_owner);
  perform public.adjust_points(
    v_business, v_exact_client, 7, 'v81 standalone adjustment'
  );
  v_reversal := public.reverse_sale(
    v_business, v_sale, 'V81 confirmed correction',
    'v81-history-reversal', 'V81 test reversal', 'none'
  )::jsonb;
  reset role;
  if nullif(v_reversal->>'reversal_sale_id', '') is null then
    raise exception 'history reversal fixture was not recorded: %', v_reversal;
  end if;

  perform pg_temp.as_v81_user(v_user);
  v_page_one := public.customer_get_transaction_history_v81(
    v_business_slug, jsonb_build_object('limit', 2)
  );
  v_before := v_page_one->'next_cursor';
  if v_before is null then
    raise exception 'history pagination did not return next_cursor: %', v_page_one;
  end if;
  v_page_two := public.customer_get_transaction_history_v81(
    v_business_slug, v_before
  );
  reset role;

  if jsonb_array_length(v_page_one->'items')
       + jsonb_array_length(v_page_two->'items') <> 3 then
    raise exception 'history pages did not contain sale, reversal, and standalone points: %, %',
      v_page_one, v_page_two;
  end if;
  v_history_text := (v_page_one->'items')::text || (v_page_two->'items')::text;
  if v_history_text not like '%' || v_sale::text || '%'
     or v_history_text not like '%"status": "reversed"%'
     or v_history_text not like '%"status": "reversal"%'
     or v_history_text not like '%"source_kind": "points_ledger"%'
     or v_history_text not like '%"points_earned": 7%' then
    raise exception 'history projection omitted required status/point facts: %',
      v_history_text;
  end if;
  if (
    select count(*)
      from (
        select item
          from jsonb_array_elements(v_page_one->'items') item
        union all
        select item
          from jsonb_array_elements(v_page_two->'items') item
      ) listed
     where listed.item->>'source_kind' = 'points_ledger'
  ) <> 1 then
    raise exception 'sale-linked earn was double-counted as standalone points';
  end if;
  if v_history_text ~* '(client_id|business_id|auth_user_id|actor)' then
    raise exception 'customer history leaked an internal scope key';
  end if;

  -- Cross-business scope: an unlinked historical firm is indistinguishable
  -- from any unavailable business to this customer reader.
  begin
    perform pg_temp.as_v81_user(v_user);
    perform public.customer_get_transaction_history_v81(
      v_historical_slug, '{}'::jsonb
    );
    reset role;
    raise exception 'cross-business historical reader unexpectedly succeeded';
  exception when insufficient_privilege then
    reset role;
  end;

  -- Raw table reads remain denied to browser roles.
  begin
    perform pg_temp.as_v81_user(v_user);
    perform 1 from public.customer_links;
    reset role;
    raise exception 'raw table read unexpectedly succeeded';
  exception when insufficient_privilege then
    reset role;
  end;

  -- v89 is authoritative: neither authenticated customers nor anon may execute
  -- the legacy contact-based self-link route.
  begin
    perform pg_temp.as_v81_user(v_user, 'authenticated');
    perform public.customer_sync_verified_relationships_v81('v81-anon-denied');
    reset role;
    raise exception 'authenticated legacy relationship sync unexpectedly succeeded';
  exception when insufficient_privilege then
    reset role;
  end;
  if has_function_privilege(
       'anon',
       'public.customer_sync_verified_relationships_v81(text)',
       'execute'
     ) then
    raise exception 'anon relationship sync unexpectedly remained executable';
  end if;
end
$v81_test$;

rollback;
