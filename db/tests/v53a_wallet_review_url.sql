-- Rollback-only v53a suite: the wallet business projection surfaces review_url.
-- Run after the complete canonical chain through v53a in a disposable rehearsal DB.
begin;
\ir fixtures/pristine_chain_fixture.psql

create or replace function pg_temp.as_user(p_uid uuid) returns void language plpgsql as $$
begin
  execute 'reset role';
  execute 'set local role authenticated';
  perform set_config('request.jwt.claim.sub', p_uid::text, true);
  perform set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated')::text, true);
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

grant execute on function pg_temp.as_user(uuid) to public;
grant execute on function pg_temp.assert_true(boolean, text) to public;
grant execute on function pg_temp.assert_eq(anyelement, anyelement, text) to public;

do $v53a$
declare
  v_biz_a uuid; v_owner_a uuid; v_client_a uuid; v_slug_a text;
  v_cust1 uuid := gen_random_uuid(); v_id1 uuid := gen_random_uuid(); v_link1 uuid := gen_random_uuid();
  v_def text; v_summary jsonb; v_business jsonb;
begin
  reset role;
  select b.id, s.user_id, b.slug into v_biz_a, v_owner_a, v_slug_a
    from public.businesses b
    join public.staff s on s.business_id = b.id and s.role = 'owner' and s.active and s.user_id is not null
   where b.name = 'Pristine chain fixture A';
  select id into v_client_a from public.clients where business_id = v_biz_a and email = 'pristine-a@example.test';
  if v_biz_a is null or v_client_a is null then raise exception 'v53a suite requires pristine tenant A'; end if;

  -- The wallet is fail-closed by deploy default; enable it only inside this rolled-back test.
  update app.platform_feature_flags set enabled = true where feature_key = 'customer_wallet';

  -- A verified customer identity + link to tenant A's client.
  insert into auth.users(instance_id, id, aud, role, email, encrypted_password, email_confirmed_at, created_at, updated_at)
  values ('00000000-0000-0000-0000-000000000000', v_cust1, 'authenticated','authenticated',
          'v53a-c1-'||substr(v_cust1::text,1,8)||'@example.test','',now(),now(),now());
  insert into public.customer_identities(id, auth_user_id, status, created_via)
  values (v_id1, v_cust1, 'active', 'wallet_start');
  perform set_config('app.customer_link_insert_id', v_link1::text, true);
  insert into public.customer_links(id, business_id, identity_id, auth_user_id, client_id, state, verification_method, verified_at)
  values (v_link1, v_biz_a, v_id1, v_cust1, v_client_a, 'verified', 'phone_claim', now());
  perform set_config('app.customer_link_insert_id', '', true);

  -- ========================================================================
  -- CATALOG: the live projection carries review_url on both business-object sites.
  -- ========================================================================
  v_def := pg_get_functiondef('public.customer_get_business_summary(text)'::regprocedure);
  perform pg_temp.assert_eq(
    (length(v_def) - length(replace(v_def,
      '(select b.review_url from public.businesses b where b.id = v_context.business_id)', '')))
      / length('(select b.review_url from public.businesses b where b.id = v_context.business_id)'),
    2, 'both business projections read review_url');

  -- ========================================================================
  -- BEHAVIORAL: business with no review_url -> null key; siblings unchanged.
  -- ========================================================================
  perform pg_temp.as_user(v_cust1);
  v_summary := public.customer_get_business_summary(v_slug_a);
  v_business := v_summary->'business';
  perform pg_temp.assert_true((v_business ? 'review_url'), 'review_url key is present');
  perform pg_temp.assert_true(v_business->>'review_url' is null, 'unset review_url projects as null (UI: no link)');
  perform pg_temp.assert_eq((select count(*)::int from jsonb_object_keys(v_business)), 5,
    'business object still has exactly five keys');
  perform pg_temp.assert_true(
    (v_business ? 'slug') and (v_business ? 'name') and (v_business ? 'industry') and (v_business ? 'currency'),
    'the four sibling keys are unchanged');

  -- ========================================================================
  -- BEHAVIORAL: owner sets the link -> it surfaces to the wallet.
  -- ========================================================================
  perform pg_temp.as_user(v_owner_a);
  update public.businesses set review_url = 'https://g.page/r/pristine-a' where id = v_biz_a;
  perform pg_temp.as_user(v_cust1);
  v_summary := public.customer_get_business_summary(v_slug_a);
  perform pg_temp.assert_eq(v_summary->'business'->>'review_url', 'https://g.page/r/pristine-a',
    'the owner-set review link surfaces in the wallet business object');
  perform pg_temp.assert_eq((select count(*)::int from jsonb_object_keys(v_summary->'business')), 5,
    'still exactly five keys after the link is set');
end $v53a$;

rollback;
