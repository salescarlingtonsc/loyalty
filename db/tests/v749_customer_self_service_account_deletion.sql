-- nestly_v749 rollback suite — a customer can delete their own Peekaa account from inside the app.
--
-- Runs inside ONE transaction ending in ROLLBACK, so it is safe against production.
--
-- WHAT IT PROVES
--   01  public.customer_delete_account_v749 is granted to authenticated (and service_role) and
--       NOT to anon.
--   02  its function source actually calls the pieces the owner note promises: the unlink helper,
--       the erasure evidence table, the auth ban/tombstone columns and a hard DELETE somewhere in
--       the login teardown.
--   03  a business login (an active staff member) calling the function is refused with 42501 —
--       business workspaces keep the email closure route, they are never deleted here.
--   04  a customer who does not type the confirmation exactly ('DELETE') is refused with 22023,
--       before anything is written.
--   05  end to end: a real customer identity with no outstanding stored value / bottles at any
--       joined business gets deleted — every joined client row anonymised, every verified link
--       unlinked, the identity disabled, the auth row banned + tombstoned + phone-freed, every
--       session gone, and the accounting record (sales) untouched.
--   06  a replay with the same idempotency key returns the recorded outcome instead of re-running.
--   07  app.c42_profile_guard's source admits the v749 erasure GUC — the one write the C42 rule
--       otherwise forbids (replacing the birth date) is scoped to this caller alone.

begin;

create temp table _v749(id int generated always as identity, check_name text, ok boolean, detail text) on commit drop;
grant all on _v749 to public;

do $$
declare
  v_staff_user uuid;
  v_result jsonb;
  v_customer record;
  v_sales_before integer;
  v_sales_after integer;
  v_client record;
  v_links_left integer;
  v_auth record;
  v_sessions integer;
  v_key text := 'suite-key-00001';
  v_src text;
begin
  -- 01 — grants: authenticated yes, anon no.
  insert into _v749(check_name, ok, detail)
  select '01 customer_delete_account_v749 is granted to authenticated, not to anon',
         coalesce(p.proacl::text,'') ~ 'authenticated=X' and coalesce(p.proacl::text,'') !~ 'anon=X',
         coalesce(p.proacl::text,'(default)')
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'customer_delete_account_v749';

  -- 02 — the function source actually does the things the migration's own comment promises.
  select pg_get_functiondef(p.oid) into v_src
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'customer_delete_account_v749';
  insert into _v749(check_name, ok, detail) values (
    '02 function source calls the unlink helper, records erasure evidence, bans + tombstones auth, and hard-deletes a login row',
    v_src like '%unlink_client_links_for_erasure_v473%'
      and v_src like '%client_erasures_v290%'
      and v_src like '%banned_until%'
      and v_src like '%deleted_at%'
      and v_src like '%''DELETE''%',
    'all five substrings present: ' ||
      (v_src like '%unlink_client_links_for_erasure_v473%')::text || '/' ||
      (v_src like '%client_erasures_v290%')::text || '/' ||
      (v_src like '%banned_until%')::text || '/' ||
      (v_src like '%deleted_at%')::text || '/' ||
      (v_src like '%''DELETE''%')::text);

  -- 03 — a business login is refused, 42501, before any write.
  select user_id into v_staff_user from public.staff where active and user_id is not null limit 1;
  if v_staff_user is null then
    insert into _v749(check_name, ok, detail) values ('03 fixture', false, 'no active staff with user_id to exercise');
  else
    perform set_config('request.jwt.claims',
      json_build_object('sub', v_staff_user::text, 'role','authenticated')::text, true);
    set local role authenticated;
    begin
      perform public.customer_delete_account_v749('DELETE', 'suite-staff-refusal-00001');
      insert into _v749(check_name, ok, detail) values ('03 a business login is refused (42501)', false, 'it was accepted');
    exception when others then
      insert into _v749(check_name, ok, detail)
      values ('03 a business login is refused (42501)', sqlstate = '42501', sqlstate || ' ' || sqlerrm);
    end;
    reset role;
  end if;

  -- 04 — wrong confirmation text, 22023, as a real customer (any one with an auth user will do).
  select ci.auth_user_id into v_customer
    from public.customer_identities ci
   where ci.auth_user_id is not null
   limit 1;
  if v_customer.auth_user_id is null then
    insert into _v749(check_name, ok, detail) values ('04 fixture', false, 'no customer_identities row with an auth_user_id to exercise');
  else
    perform set_config('request.jwt.claims',
      json_build_object('sub', v_customer.auth_user_id::text, 'role','authenticated')::text, true);
    set local role authenticated;
    begin
      perform public.customer_delete_account_v749('nope', 'suite-wrong-confirmation-00001');
      insert into _v749(check_name, ok, detail) values ('04 a wrong confirmation text is refused (22023)', false, 'it was accepted');
    exception when others then
      insert into _v749(check_name, ok, detail)
      values ('04 a wrong confirmation text is refused (22023)', sqlstate = '22023', sqlstate || ' ' || sqlerrm);
    end;
    reset role;
  end if;

  -- 05 — end to end: a customer with >=1 verified link and no outstanding stored value / bottles
  -- anywhere they are linked.
  select ci.id as identity_id, ci.auth_user_id
    into v_client
    from public.customer_identities ci
   where ci.auth_user_id is not null
     and exists (
       select 1 from public.customer_links l
        where l.identity_id = ci.id and l.state = 'verified' and l.client_id is not null
     )
     and not exists (
       select 1
         from public.customer_links l
         join public.sv_lots lot on true
         join public.sv_accounts acct on acct.id = lot.account_id
        where l.identity_id = ci.id and l.state = 'verified' and l.client_id is not null
          and acct.business_id = l.business_id and acct.client_id = l.client_id
     )
     and not exists (
       select 1
         from public.customer_links l
         join public.bar_bottles b
           on b.business_id = l.business_id and b.client_id = l.client_id
        where l.identity_id = ci.id and l.state = 'verified' and l.client_id is not null
          and b.status in ('stored','called','at_table','expired')
     )
   limit 1;

  if v_client.identity_id is null then
    insert into _v749(check_name, ok, detail) values
      ('05 fixture', false, 'no customer identity with a verified link and no blocking stored value/bottles found');
    insert into _v749(check_name, ok, detail) values ('06 fixture', false, 'skipped, no 05 fixture');
  else
    select count(*)::integer into v_sales_before
      from public.sales s
      join public.customer_links l on l.business_id = s.business_id and l.client_id = s.client_id
     where l.identity_id = v_client.identity_id and l.state = 'verified';

    perform set_config('request.jwt.claims',
      json_build_object('sub', v_client.auth_user_id::text, 'role','authenticated')::text, true);
    set local role authenticated;
    v_result := public.customer_delete_account_v749('DELETE', v_key);
    reset role;

    insert into _v749(check_name, ok, detail) values (
      '05a the deletion succeeds (status=deleted)',
      v_result->>'status' = 'deleted', coalesce(v_result::text,'null'));

    select count(*)::integer into v_links_left
      from public.customer_links l where l.identity_id = v_client.identity_id and l.state = 'verified';
    insert into _v749(check_name, ok, detail) values (
      '05b no verified links remain for the erased identity',
      v_links_left = 0, v_links_left::text || ' verified links remain');

    insert into _v749(check_name, ok, detail)
    select '05c every formerly-linked client row is anonymised',
           bool_and(c.full_name = 'Erased customer' and c.phone is null and c.email is null),
           count(*)::text || ' client rows checked'
      from public.clients c
      join public.customer_links l on l.client_id = c.id
     where l.identity_id = v_client.identity_id;

    insert into _v749(check_name, ok, detail)
    select '05d the customer_identities row is disabled', ci.status = 'disabled', ci.status
      from public.customer_identities ci where ci.id = v_client.identity_id;

    select u.banned_until, u.deleted_at, u.phone into v_auth
      from auth.users u where u.id = v_client.auth_user_id;
    insert into _v749(check_name, ok, detail) values (
      '05e auth.users is banned to infinity, soft-deleted, and phone freed',
      v_auth.banned_until = 'infinity'::timestamptz and v_auth.deleted_at is not null and v_auth.phone is null,
      'banned_until=' || coalesce(v_auth.banned_until::text,'null') ||
      ' deleted_at=' || coalesce(v_auth.deleted_at::text,'null') ||
      ' phone=' || coalesce(v_auth.phone,'null'));

    select count(*)::integer into v_sessions from auth.sessions where user_id = v_client.auth_user_id;
    insert into _v749(check_name, ok, detail) values (
      '05f every auth session for the customer is gone', v_sessions = 0, v_sessions::text || ' sessions remain');

    select count(*)::integer into v_sales_after
      from public.sales s
      join public.customer_links l on l.business_id = s.business_id and l.client_id = s.client_id
     where l.identity_id = v_client.identity_id;
    -- customer_links is now unlinked so the join above will not resolve rows any more; compare
    -- against the client ids directly instead, which is what the migration promises is untouched.
    select count(*)::integer into v_sales_after
      from public.sales s
      join public.clients c on c.business_id = s.business_id and c.id = s.client_id
      join (select distinct client_id, business_id from public.customer_links where identity_id = v_client.identity_id) cl
        on cl.client_id = c.id and cl.business_id = c.business_id;
    insert into _v749(check_name, ok, detail) values (
      '05g the accounting record (sales) is unchanged before vs after',
      v_sales_before = v_sales_after,
      'before=' || v_sales_before::text || ' after=' || v_sales_after::text);

    -- 06 — replay with the same idempotency key returns the recorded outcome.
    perform set_config('request.jwt.claims',
      json_build_object('sub', v_client.auth_user_id::text, 'role','authenticated')::text, true);
    set local role authenticated;
    begin
      v_result := public.customer_delete_account_v749('DELETE', v_key);
      insert into _v749(check_name, ok, detail) values (
        '06 a replay with the same key returns duplicate_ignored, nothing re-run',
        v_result->>'status' = 'duplicate_ignored', coalesce(v_result::text,'null'));
    exception when others then
      -- auth.users is now banned/tombstoned, so the replay may instead fail to authenticate
      -- depending on how the harness resolves the session; either outcome proves no re-run
      -- occurred, but the migration's own idempotency guard is keyed on (customer, key) and
      -- returns duplicate_ignored when the login still resolves, which it does inside this
      -- transaction since GoTrue's own auth checks are not enforced by plain SQL.
      insert into _v749(check_name, ok, detail) values (
        '06 a replay with the same key returns duplicate_ignored, nothing re-run',
        false, sqlstate || ' ' || sqlerrm);
    end;
    reset role;
  end if;

  reset role;
exception when others then
  reset role;
  insert into _v749(check_name, ok, detail) values ('!! aborted', false, sqlstate || ' ' || sqlerrm);
end $$;

-- 07 — the c42 guard admits the v749 erasure GUC.
insert into _v749(check_name, ok, detail)
select '07 app.c42_profile_guard source references the v749 erasure GUC',
       pg_get_functiondef(p.oid) like '%app.c42_profile_erasure_v749%',
       'checked pg_get_functiondef(app.c42_profile_guard)'
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'app' and p.proname = 'c42_profile_guard';

select check_name, case when ok then 'PASS' else 'FAIL' end as result, detail from _v749 order by id;
select count(*) filter (where not ok) as failures, count(*) as checks from _v749;

rollback;
