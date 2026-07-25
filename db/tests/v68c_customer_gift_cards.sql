-- Rollback-only v68c suite: public.customer_get_gift_cards — customer-facing gift-card balance view.
-- Run after the complete canonical chain through v68c in a disposable rehearsal DB.
--
-- What it proves (contract §4):
--   * a verified customer sees ONLY the cards their own linked client purchased, at that business;
--   * a second client in the SAME tenant is invisible (not just a cross-tenant check);
--   * a second TENANT's cards are invisible, and its slug is a flat 42501;
--   * recipient_email is NOT a matching key — a card addressed to the caller's own e-mail but bought
--     by someone else stays invisible (the security defect the contract explicitly forbids);
--   * the bearer CODE never appears anywhere in the returned jsonb (full-code scan on every card);
--   * an active identity with no verified link, a staff-only login, and anon are all denied;
--   * the empty case returns the zero shape, never a null-shaped error;
--   * count/total equal the visible cards and the sum of their balances;
--   * the release gate (customer_wallet) is honoured, and the ACL is authenticated-only.
begin;
\ir fixtures/pristine_chain_fixture.psql

create or replace function pg_temp.as_user(p_uid uuid) returns void language plpgsql as $$
begin
  execute 'reset role';
  execute 'set local role authenticated';
  perform set_config('request.jwt.claim.sub', p_uid::text, true);
  perform set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated')::text, true);
end $$;

create or replace function pg_temp.as_anon() returns void language plpgsql as $$
begin
  execute 'reset role';
  execute 'set local role anon';
  perform set_config('request.jwt.claim.sub', '', true);
  perform set_config('request.jwt.claims', json_build_object('role', 'anon')::text, true);
end $$;

create or replace function pg_temp.assert_true(p_ok boolean, p_message text) returns void language plpgsql as $$
begin
  if not coalesce(p_ok, false) then raise exception 'ASSERTION FAILED: %', p_message; end if;
end $$;

create or replace function pg_temp.assert_eq(p_actual anyelement, p_expected anyelement, p_message text)
returns void language plpgsql as $$
begin
  if p_actual is distinct from p_expected then
    raise exception 'ASSERTION FAILED: % (actual %, expected %)', p_message, p_actual, p_expected;
  end if;
end $$;

create or replace function pg_temp.expect_state(p_sql text, p_label text, p_state text)
returns void language plpgsql as $$
begin
  execute p_sql;
  raise exception '% unexpectedly succeeded', p_label;
exception when others then
  if sqlstate <> p_state then
    raise exception '% failed with %, expected %: %', p_label, sqlstate, p_state, sqlerrm;
  end if;
end $$;

grant execute on function pg_temp.as_user(uuid) to public;
grant execute on function pg_temp.as_anon() to public;
grant execute on function pg_temp.assert_true(boolean, text) to public;
grant execute on function pg_temp.assert_eq(anyelement, anyelement, text) to public;
grant execute on function pg_temp.expect_state(text, text, text) to public;

do $v68c$
declare
  v_biz_a uuid; v_owner_a uuid; v_slug_a text; v_client_a uuid;
  v_biz_b uuid; v_owner_b uuid; v_slug_b text; v_client_b uuid;
  v_client_a2 uuid := gen_random_uuid();   -- another client of tenant A (a different buyer)
  v_client_a3 uuid := gen_random_uuid();   -- a client of tenant A who bought nothing
  v_cust_a uuid := gen_random_uuid();      -- verified customer of A (owns two cards)
  v_cust_b uuid := gen_random_uuid();      -- verified customer of B (owns one card)
  v_cust_empty uuid := gen_random_uuid();  -- verified customer of A with zero cards
  v_cust_nolink uuid := gen_random_uuid(); -- active identity, no verified link at all
  v_id_a uuid := gen_random_uuid(); v_id_b uuid := gen_random_uuid();
  v_id_empty uuid := gen_random_uuid(); v_id_nolink uuid := gen_random_uuid();
  v_link_a uuid := gen_random_uuid(); v_link_b uuid := gen_random_uuid();
  v_link_empty uuid := gen_random_uuid();
  v_email_a text; v_code_a1 text; v_code_a2 text; v_code_other text; v_code_b text;
  v_res jsonb; v_card jsonb; v_code text; v_visible_total bigint;
begin
  reset role;
  select b.id, s.user_id, b.slug into v_biz_a, v_owner_a, v_slug_a
    from public.businesses b
    join public.staff s on s.business_id = b.id and s.role = 'owner' and s.active and s.user_id is not null
   where b.name = 'Pristine chain fixture A';
  select b.id, s.user_id, b.slug into v_biz_b, v_owner_b, v_slug_b
    from public.businesses b
    join public.staff s on s.business_id = b.id and s.role = 'owner' and s.active and s.user_id is not null
   where b.name = 'Pristine chain fixture B';
  select id into v_client_a from public.clients where business_id = v_biz_a and email = 'pristine-a@example.test';
  select id into v_client_b from public.clients where business_id = v_biz_b and email = 'pristine-b@example.test';
  if v_biz_a is null or v_biz_b is null or v_owner_a is null or v_owner_b is null
     or v_client_a is null or v_client_b is null then
    raise exception 'v68c suite requires the pristine A/B fixture with both owners';
  end if;

  v_email_a := 'v68c-cust-a-' || substr(v_cust_a::text, 1, 8) || '@example.test';
  insert into auth.users(instance_id, id, aud, role, email, encrypted_password, email_confirmed_at, created_at, updated_at)
  values
    ('00000000-0000-0000-0000-000000000000', v_cust_a, 'authenticated', 'authenticated',
      v_email_a, '', now(), now(), now()),
    ('00000000-0000-0000-0000-000000000000', v_cust_b, 'authenticated', 'authenticated',
      'v68c-cust-b-' || substr(v_cust_b::text, 1, 8) || '@example.test', '', now(), now(), now()),
    ('00000000-0000-0000-0000-000000000000', v_cust_empty, 'authenticated', 'authenticated',
      'v68c-cust-e-' || substr(v_cust_empty::text, 1, 8) || '@example.test', '', now(), now(), now()),
    ('00000000-0000-0000-0000-000000000000', v_cust_nolink, 'authenticated', 'authenticated',
      'v68c-cust-n-' || substr(v_cust_nolink::text, 1, 8) || '@example.test', '', now(), now(), now());

  insert into public.clients(id, business_id, full_name) values
    (v_client_a2, v_biz_a, 'V68c other buyer in A'),
    (v_client_a3, v_biz_a, 'V68c customer with no cards');

  -- Gift cards issued through the real staff route (v41 issue_gift_card), never by direct INSERT.
  --   A: two cards bought by the caller's own client (one later redeemed to zero)
  --   A: one card bought by ANOTHER client, addressed to the caller's own verified e-mail
  --   B: one card in the other tenant
  perform pg_temp.as_user(v_owner_a);
  v_code_a1 := public.issue_gift_card(v_biz_a, 5000, v_client_a, null, gen_random_uuid())->>'code';
  v_code_a2 := public.issue_gift_card(v_biz_a, 2500, v_client_a, null, gen_random_uuid())->>'code';
  v_code_other := public.issue_gift_card(v_biz_a, 9999, v_client_a2, v_email_a, gen_random_uuid())->>'code';
  perform public.redeem_gift_card_v41(v_biz_a, v_code_a2, v_client_a);
  perform pg_temp.as_user(v_owner_b);
  v_code_b := public.issue_gift_card(v_biz_b, 7777, v_client_b, null, gen_random_uuid())->>'code';

  reset role;
  insert into public.customer_identities(id, auth_user_id, status, created_via) values
    (v_id_a, v_cust_a, 'active', 'wallet_start'),
    (v_id_b, v_cust_b, 'active', 'wallet_start'),
    (v_id_empty, v_cust_empty, 'active', 'wallet_start'),
    (v_id_nolink, v_cust_nolink, 'active', 'wallet_start');
  perform set_config('app.customer_link_insert_id', v_link_a::text, true);
  insert into public.customer_links(id, business_id, identity_id, auth_user_id, client_id, state, verification_method, verified_at)
    values (v_link_a, v_biz_a, v_id_a, v_cust_a, v_client_a, 'verified', 'phone_claim', now());
  perform set_config('app.customer_link_insert_id', v_link_b::text, true);
  insert into public.customer_links(id, business_id, identity_id, auth_user_id, client_id, state, verification_method, verified_at)
    values (v_link_b, v_biz_b, v_id_b, v_cust_b, v_client_b, 'verified', 'phone_claim', now());
  perform set_config('app.customer_link_insert_id', v_link_empty::text, true);
  insert into public.customer_links(id, business_id, identity_id, auth_user_id, client_id, state, verification_method, verified_at)
    values (v_link_empty, v_biz_a, v_id_empty, v_cust_empty, v_client_a3, 'verified', 'phone_claim', now());
  perform set_config('app.customer_link_insert_id', '', true);

  -- ========================================================================
  -- 1. The private release gate, not a frontend constant, opens this surface.
  -- ========================================================================
  reset role;
  perform pg_temp.assert_true(
    exists (select 1 from app.platform_feature_flags where feature_key = 'customer_wallet' and not enabled),
    'v68c fixture expects the customer_wallet gate to start closed');
  perform pg_temp.as_user(v_cust_a);
  perform pg_temp.expect_state(
    format('select public.customer_get_gift_cards(%L)', v_slug_a),
    'closed customer_wallet gate refuses the gift-card reader', '0A000');
  reset role;
  update app.platform_feature_flags set enabled = true, changed_at = now()
   where feature_key = 'customer_wallet';

  -- ========================================================================
  -- 2. The verified customer sees exactly their OWN cards at that business.
  -- ========================================================================
  perform pg_temp.as_user(v_cust_a);
  v_res := public.customer_get_gift_cards(v_slug_a);
  perform pg_temp.assert_eq(jsonb_typeof(v_res->'cards'), 'array', 'cards is an array');
  perform pg_temp.assert_eq(jsonb_array_length(v_res->'cards'), 2, 'customer A sees exactly their two cards');
  perform pg_temp.assert_eq((v_res->>'count')::int, 2, 'count matches the visible cards');
  perform pg_temp.assert_eq((v_res->>'total_balance_cents')::bigint, 5000::bigint,
    'total is the sum of visible balances (5000 active + 0 redeemed)');
  perform pg_temp.assert_eq((v_res->>'truncated')::boolean, false, 'a two-card wallet is not truncated');
  select coalesce(sum((c->>'balance_cents')::bigint), 0) into v_visible_total
    from jsonb_array_elements(v_res->'cards') c;
  perform pg_temp.assert_eq((v_res->>'total_balance_cents')::bigint, v_visible_total,
    'total_balance_cents equals the sum of the balances actually listed');
  perform pg_temp.assert_eq(v_res #>> '{business,slug}', v_slug_a, 'business projection is the linked firm');
  perform pg_temp.assert_true((v_res->'business') ? 'name' and (v_res->'business') ? 'currency',
    'business projection carries name and currency');
  perform pg_temp.assert_true(
    (select count(*) from jsonb_object_keys(v_res->'business') k) = 3,
    'business projection is exactly {slug,name,currency}');
  perform pg_temp.assert_true(
    exists (select 1 from jsonb_array_elements(v_res->'cards') c
             where (c->>'initial_cents')::int = 5000 and (c->>'balance_cents')::int = 5000
               and c->>'status' = 'active'),
    'the un-redeemed card is reported active at full value');
  perform pg_temp.assert_true(
    exists (select 1 from jsonb_array_elements(v_res->'cards') c
             where (c->>'initial_cents')::int = 2500 and (c->>'balance_cents')::int = 0
               and c->>'status' = 'redeemed'),
    'the fully-redeemed card is reported redeemed at zero');

  -- ========================================================================
  -- 3. The bearer CODE is never returned, in any form, on any card.
  -- ========================================================================
  foreach v_code in array array[v_code_a1, v_code_a2, v_code_other, v_code_b] loop
    perform pg_temp.assert_true(v_code is not null and length(v_code) > 4, 'fixture codes are real codes');
    perform pg_temp.assert_true(position(v_code in v_res::text) = 0,
      'the full gift-card code must never appear in the customer output: ' || v_code);
  end loop;
  for v_card in select c from jsonb_array_elements(v_res->'cards') c loop
    perform pg_temp.assert_true(not (v_card ? 'code'), 'no card exposes a code key');
    perform pg_temp.assert_true(not (v_card ? 'recipient_email'), 'no card exposes recipient_email');
    perform pg_temp.assert_true(not (v_card ? 'purchaser_client_id'), 'no card exposes purchaser_client_id');
    perform pg_temp.assert_eq(length(v_card->>'code_suffix'), 4, 'the display hint is a 4-character suffix');
  end loop;
  perform pg_temp.assert_true(
    v_res::text !~* '"(code|recipient_email|purchaser_client_id|email|phone|auth_user_id|client_id)"',
    'the payload carries no bearer, PII or internal key');

  -- ========================================================================
  -- 4. Same tenant, different buyer — invisible, even when the card is
  --    addressed to the caller's OWN verified e-mail. recipient_email is
  --    unverified free text and must never be a matching key.
  -- ========================================================================
  perform pg_temp.assert_true(
    not exists (select 1 from jsonb_array_elements(v_res->'cards') c
                 where (c->>'initial_cents')::int = 9999),
    'a card bought by another client of the same tenant is invisible');
  reset role;
  perform pg_temp.assert_true(
    exists (select 1 from public.gift_cards g
             where g.business_id = v_biz_a and g.code = v_code_other
               and g.recipient_email = v_email_a and g.purchaser_client_id = v_client_a2),
    'the fixture really does address that card to the calling customer''s own e-mail');

  -- ========================================================================
  -- 5. Cross-tenant isolation, both directions.
  -- ========================================================================
  perform pg_temp.as_user(v_cust_a);
  perform pg_temp.expect_state(
    format('select public.customer_get_gift_cards(%L)', v_slug_b),
    'customer A has no verified link to tenant B', '42501');
  perform pg_temp.as_user(v_cust_b);
  v_res := public.customer_get_gift_cards(v_slug_b);
  perform pg_temp.assert_eq(jsonb_array_length(v_res->'cards'), 1, 'customer B sees only their own tenant-B card');
  perform pg_temp.assert_eq((v_res->>'total_balance_cents')::bigint, 7777::bigint, 'tenant B total is its own card');
  perform pg_temp.assert_true(position(v_code_a1 in v_res::text) = 0 and position(v_code_b in v_res::text) = 0,
    'no code from either tenant leaks into tenant B output');
  perform pg_temp.expect_state(
    format('select public.customer_get_gift_cards(%L)', v_slug_a),
    'customer B has no verified link to tenant A', '42501');

  -- ========================================================================
  -- 6. The empty case is the zero shape, never a null-shaped error.
  -- ========================================================================
  perform pg_temp.as_user(v_cust_empty);
  v_res := public.customer_get_gift_cards(v_slug_a);
  perform pg_temp.assert_eq(v_res->'cards', '[]'::jsonb, 'no cards yields an empty array');
  perform pg_temp.assert_eq((v_res->>'count')::int, 0, 'empty count is zero');
  perform pg_temp.assert_eq((v_res->>'total_balance_cents')::bigint, 0::bigint, 'empty total is zero');
  perform pg_temp.assert_eq((v_res->>'truncated')::boolean, false, 'an empty wallet is not truncated');
  perform pg_temp.assert_eq(v_res #>> '{business,slug}', v_slug_a, 'the empty case still names the firm');

  -- ========================================================================
  -- 7. No verified link, a staff-only login, an unknown slug, and anon.
  -- ========================================================================
  perform pg_temp.as_user(v_cust_nolink);
  perform pg_temp.expect_state(
    format('select public.customer_get_gift_cards(%L)', v_slug_a),
    'an active identity with no verified link is denied', '42501');
  perform pg_temp.as_user(v_owner_a);
  perform pg_temp.expect_state(
    format('select public.customer_get_gift_cards(%L)', v_slug_a),
    'a staff login is not a customer identity', '42501');
  perform pg_temp.as_user(v_cust_a);
  perform pg_temp.expect_state(
    'select public.customer_get_gift_cards(''v68c-no-such-business'')',
    'an unknown slug is indistinguishable from an unlinked one', '42501');
  perform pg_temp.as_anon();
  perform pg_temp.expect_state(
    format('select public.customer_get_gift_cards(%L)', v_slug_a),
    'anon cannot execute the reader', '42501');

  -- ========================================================================
  -- 8. ACL and blast radius: authenticated-only, no PUBLIC grant, no new
  --    direct access to gift_cards, and the v32 resolver stays internal.
  -- ========================================================================
  reset role;
  perform pg_temp.assert_true(
    has_function_privilege('authenticated', 'public.customer_get_gift_cards(text)', 'execute'),
    'authenticated may execute the reader');
  perform pg_temp.assert_true(
    not has_function_privilege('anon', 'public.customer_get_gift_cards(text)', 'execute'),
    'anon may not execute the reader');
  perform pg_temp.assert_true(
    not exists (
      select 1 from pg_proc p
      cross join lateral aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) acl
       where p.oid = 'public.customer_get_gift_cards(text)'::regprocedure
         and acl.grantee = 0 and acl.privilege_type = 'EXECUTE'),
    'the default PUBLIC execute grant is revoked');
  perform pg_temp.assert_true(
    (select prosecdef from pg_proc where oid = 'public.customer_get_gift_cards(text)'::regprocedure)
      and (select array_to_string(proconfig, ',') from pg_proc
            where oid = 'public.customer_get_gift_cards(text)'::regprocedure)
          = 'search_path=pg_catalog, public, app, pg_temp',
    'the reader is SECURITY DEFINER with the v21-canonical pinned search_path');
  perform pg_temp.assert_true(
    not has_table_privilege('authenticated', 'public.gift_cards', 'select')
      and not has_table_privilege('anon', 'public.gift_cards', 'select'),
    'gift_cards is still unreadable directly by any browser role');
  perform pg_temp.assert_eq(
    (select count(*)::int from pg_policies where schemaname = 'public' and tablename = 'gift_cards'),
    1, 'the gift_cards policy set is unchanged (definer RPC is the only access path)');
  perform pg_temp.assert_true(
    not has_function_privilege('authenticated', 'app.v32_customer_wallet_context(text)', 'execute'),
    'the v32 scope resolver stays closed to the browser');
  perform pg_temp.as_user(v_cust_a);
  perform pg_temp.expect_state(
    'select 1 from public.gift_cards',
    'a verified customer cannot read the raw gift_cards table', '42501');

  reset role;
  raise notice 'V68C SUITE PASS';
end
$v68c$;

rollback;
