-- Rollback-only v53 suite: visit feedback & service recovery.
-- Run after the complete canonical chain through v53 in a disposable rehearsal DB.
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

do $v53$
declare
  v_biz_a uuid; v_owner_a uuid; v_client_a uuid; v_slug_a text;
  v_biz_b uuid; v_client_b uuid; v_slug_b text;
  v_mgr uuid := gen_random_uuid(); v_fd uuid := gen_random_uuid(); v_lo uuid := gen_random_uuid();
  v_cust1 uuid := gen_random_uuid(); v_cust2 uuid := gen_random_uuid();
  v_id1 uuid := gen_random_uuid(); v_id2 uuid := gen_random_uuid();
  v_link1 uuid := gen_random_uuid(); v_link2 uuid := gen_random_uuid();
  v_client_other uuid := gen_random_uuid();
  v_sale_a uuid; v_sale_other uuid;
  v_k1 uuid := gen_random_uuid(); v_k2 uuid := gen_random_uuid();
  v_k3 uuid := gen_random_uuid(); v_k4 uuid := gen_random_uuid();
  v_res jsonb; v_replay jsonb; v_fb1 uuid; v_gen uuid; v_url text;
begin
  reset role;
  select b.id, s.user_id, b.slug into v_biz_a, v_owner_a, v_slug_a
    from public.businesses b
    join public.staff s on s.business_id = b.id and s.role = 'owner' and s.active and s.user_id is not null
   where b.name = 'Pristine chain fixture A';
  select b.id, b.slug into v_biz_b, v_slug_b from public.businesses b where b.name = 'Pristine chain fixture B';
  select id into v_client_a from public.clients where business_id = v_biz_a and email = 'pristine-a@example.test';
  select id into v_client_b from public.clients where business_id = v_biz_b and email = 'pristine-b@example.test';
  if v_biz_a is null or v_biz_b is null or v_client_a is null or v_client_b is null then
    raise exception 'v53 suite requires the pristine A/B fixture';
  end if;

  -- Staff: a manager (refund_sales), a frontdesk (no refund_sales), a loyalty-only staff.
  insert into auth.users(instance_id, id, aud, role, email, encrypted_password, email_confirmed_at, created_at, updated_at)
  values
    ('00000000-0000-0000-0000-000000000000', v_mgr, 'authenticated','authenticated','v53-mgr-'||substr(v_mgr::text,1,8)||'@example.test','',now(),now(),now()),
    ('00000000-0000-0000-0000-000000000000', v_fd, 'authenticated','authenticated','v53-fd-'||substr(v_fd::text,1,8)||'@example.test','',now(),now(),now()),
    ('00000000-0000-0000-0000-000000000000', v_lo, 'authenticated','authenticated','v53-lo-'||substr(v_lo::text,1,8)||'@example.test','',now(),now(),now()),
    ('00000000-0000-0000-0000-000000000000', v_cust1, 'authenticated','authenticated','v53-c1-'||substr(v_cust1::text,1,8)||'@example.test','',now(),now(),now()),
    ('00000000-0000-0000-0000-000000000000', v_cust2, 'authenticated','authenticated','v53-c2-'||substr(v_cust2::text,1,8)||'@example.test','',now(),now(),now());
  insert into public.staff(business_id, user_id, role, full_name, active) values
    (v_biz_a, v_mgr, 'manager', 'V53 Manager', true),
    (v_biz_a, v_fd, 'frontdesk', 'V53 Frontdesk', true);
  insert into public.staff(business_id, user_id, role, full_name, active, modules)
    values (v_biz_a, v_lo, 'manager', 'V53 Loyalty-only', true, array['loyalty']);

  -- Sales: one for the customer's client, one for a different client (not on account).
  insert into public.sales(business_id, client_id, kind, amount_cents)
    values (v_biz_a, v_client_a, 'quick_sale', 5000) returning id into v_sale_a;
  insert into public.clients(id, business_id, full_name) values (v_client_other, v_biz_a, 'V53 Other');
  insert into public.sales(business_id, client_id, kind, amount_cents)
    values (v_biz_a, v_client_other, 'quick_sale', 3000) returning id into v_sale_other;

  -- Customer identities + verified wallet links (customer1 -> A, customer2 -> B).
  insert into public.customer_identities(id, auth_user_id, status, created_via) values
    (v_id1, v_cust1, 'active', 'wallet_start'),
    (v_id2, v_cust2, 'active', 'wallet_start');
  perform set_config('app.customer_link_insert_id', v_link1::text, true);
  insert into public.customer_links(id, business_id, identity_id, auth_user_id, client_id, state, verification_method, verified_at)
    values (v_link1, v_biz_a, v_id1, v_cust1, v_client_a, 'verified', 'phone_claim', now());
  perform set_config('app.customer_link_insert_id', v_link2::text, true);
  insert into public.customer_links(id, business_id, identity_id, auth_user_id, client_id, state, verification_method, verified_at)
    values (v_link2, v_biz_b, v_id2, v_cust2, v_client_b, 'verified', 'phone_claim', now());
  perform set_config('app.customer_link_insert_id', '', true);

  -- ========================================================================
  -- 1. Customer submits feedback on their own visit -> open recovery case.
  -- ========================================================================
  perform pg_temp.as_user(v_cust1);
  v_res := public.customer_submit_visit_feedback(v_slug_a, v_sale_a, 2, 'Slow service', v_k1);
  perform pg_temp.assert_eq(v_res->>'recovery_status', 'open', 'rating<=3 opens a recovery case');
  perform pg_temp.assert_eq((v_res->>'rating')::int, 2, 'rating stored');
  v_fb1 := (v_res->>'id')::uuid;

  -- 2. Idempotent replay: same key + payload returns the same row.
  v_replay := public.customer_submit_visit_feedback(v_slug_a, v_sale_a, 2, 'Slow service', v_k1);
  perform pg_temp.assert_eq(v_replay->>'id', v_res->>'id', 'replay returns the same feedback');

  -- 3. Duplicate feedback for the same visit (different key) is rejected.
  perform pg_temp.expect_state(
    format('select public.customer_submit_visit_feedback(%L,%L::uuid,3,%L,%L::uuid)',
      v_slug_a, v_sale_a, 'again', v_k2),
    'duplicate feedback for a visit rejected', '23505');

  -- 4. General (no-sale) feedback, high rating -> auto-closed.
  v_res := public.customer_submit_visit_feedback(v_slug_a, null, 5, 'Lovely, thanks', v_k3);
  perform pg_temp.assert_eq(v_res->>'recovery_status', 'closed', 'rating>=4 is auto-closed');
  v_gen := (v_res->>'id')::uuid;

  -- 5. A second general note per (identity, business) is rejected (anti-flood rule).
  perform pg_temp.expect_state(
    format('select public.customer_submit_visit_feedback(%L,null,4,%L,%L::uuid)',
      v_slug_a, 'second general', v_k4),
    'second general feedback rejected', '23505');

  -- 6. Cross-identity / no link: customer2 has no verified link to business A.
  perform pg_temp.as_user(v_cust2);
  perform pg_temp.expect_state(
    format('select public.customer_submit_visit_feedback(%L,null,5,null,%L::uuid)', v_slug_a, gen_random_uuid()),
    'customer without a verified link to A denied', '42501');

  -- 7. Not-on-account: customer1 cannot attach a different client's sale.
  perform pg_temp.as_user(v_cust1);
  perform pg_temp.expect_state(
    format('select public.customer_submit_visit_feedback(%L,%L::uuid,5,null,%L::uuid)',
      v_slug_a, v_sale_other, gen_random_uuid()),
    'attaching another client''s sale denied', '42501');

  -- 8. Anonymous submit is denied (execute revoked for anon).
  perform pg_temp.as_anon();
  perform pg_temp.expect_state(
    format('select public.customer_submit_visit_feedback(%L,null,5,null,%L::uuid)', v_slug_a, gen_random_uuid()),
    'anon submit denied', '42501');

  -- 9. Customer lists only their own feedback (bounded).
  perform pg_temp.as_user(v_cust1);
  v_res := public.customer_list_my_feedback(v_slug_a);
  perform pg_temp.assert_eq(jsonb_array_length(v_res->'feedback'), 2, 'customer sees their two feedback rows');
  v_res := public.customer_list_my_feedback(null, 1);
  perform pg_temp.assert_eq(jsonb_array_length(v_res->'feedback'), 1, 'global list honours the limit');

  -- ========================================================================
  -- STAFF SIDE.
  -- ========================================================================
  -- 10. Manager (clients read) sees the queue.
  perform pg_temp.as_user(v_mgr);
  v_res := public.staff_list_visit_feedback(v_biz_a);
  perform pg_temp.assert_eq(jsonb_array_length(v_res->'feedback'), 2, 'staff queue lists both rows');
  v_res := public.staff_list_visit_feedback(v_biz_a, 'open');
  perform pg_temp.assert_eq(jsonb_array_length(v_res->'feedback'), 1, 'status filter narrows the queue');

  -- 11. Loyalty-only staff (no clients module) cannot read the queue.
  perform pg_temp.as_user(v_lo);
  perform pg_temp.expect_state(
    format('select public.staff_list_visit_feedback(%L::uuid)', v_biz_a),
    'staff without clients-module read denied', '42501');

  -- 12. Frontdesk (no refund_sales) cannot resolve.
  perform pg_temp.as_user(v_fd);
  perform pg_temp.expect_state(
    format('select public.staff_resolve_feedback(%L::uuid,%L::uuid,%L,null,null)', v_biz_a, v_fb1, 'acknowledged'),
    'frontdesk cannot resolve (no refund_sales)', '42501');

  -- 13. Manager advances the lifecycle open -> acknowledged -> resolved.
  perform pg_temp.as_user(v_mgr);
  v_res := public.staff_resolve_feedback(v_biz_a, v_fb1, 'acknowledged', 'Called the guest', null);
  perform pg_temp.assert_eq(v_res->>'recovery_status', 'acknowledged', 'open -> acknowledged');
  v_res := public.staff_resolve_feedback(v_biz_a, v_fb1, 'resolved', 'Comped next visit', null);
  perform pg_temp.assert_eq(v_res->>'recovery_status', 'resolved', 'acknowledged -> resolved');
  perform pg_temp.assert_true(v_res->>'resolved_by' is not null and v_res->>'resolved_at' is not null,
    'resolution stamps resolver and time');

  -- 14. Idempotent resolve: resolving to the same status is a no-op.
  v_res := public.staff_resolve_feedback(v_biz_a, v_fb1, 'resolved', null, null);
  perform pg_temp.assert_eq(v_res->>'recovery_status', 'resolved', 'repeat resolve is idempotent');

  -- 15. Illegal transitions are rejected.
  perform pg_temp.expect_state(
    format('select public.staff_resolve_feedback(%L::uuid,%L::uuid,%L,null,null)', v_biz_a, v_fb1, 'acknowledged'),
    'resolved -> acknowledged rejected', '22023');
  perform pg_temp.expect_state(
    format('select public.staff_resolve_feedback(%L::uuid,%L::uuid,%L,null,null)', v_biz_a, v_gen, 'acknowledged'),
    'closed (positive) feedback cannot be resolved', '22023');

  -- ========================================================================
  -- 16. Append-only guards: no direct customer/staff UPDATE or DELETE.
  -- ========================================================================
  reset role;
  perform pg_temp.expect_state(
    format('update public.visit_feedback set rating = 1 where id = %L::uuid', v_fb1),
    'direct UPDATE without the resolve token denied', '42501');
  perform pg_temp.expect_state(
    format('delete from public.visit_feedback where id = %L::uuid', v_fb1),
    'DELETE refused (append-only)', '23001');

  -- ========================================================================
  -- 17. Review link-out: owner-settable, https-only, not settable by others.
  -- ========================================================================
  perform pg_temp.as_user(v_owner_a);
  update public.businesses set review_url = 'https://g.page/r/pristine-a' where id = v_biz_a;
  reset role;
  select review_url into v_url from public.businesses where id = v_biz_a;
  perform pg_temp.assert_eq(v_url, 'https://g.page/r/pristine-a', 'owner set the review link');
  perform pg_temp.as_user(v_owner_a);
  perform pg_temp.expect_state(
    format('update public.businesses set review_url = %L where id = %L::uuid', 'http://insecure', v_biz_a),
    'non-https review link rejected', '23514');
  -- A customer cannot change another business setting (RLS blocks; the row is unchanged).
  perform pg_temp.as_user(v_cust1);
  update public.businesses set review_url = 'https://evil.example' where id = v_biz_a;
  reset role;
  select review_url into v_url from public.businesses where id = v_biz_a;
  perform pg_temp.assert_eq(v_url, 'https://g.page/r/pristine-a', 'a customer cannot rewrite the review link');
end $v53$;

rollback;
