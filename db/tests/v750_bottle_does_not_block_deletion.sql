-- nestly_v750 rollback suite — a kept bottle no longer blocks a customer from deleting their
-- account; outstanding stored value (real money) still does.
--
-- Runs inside ONE transaction ending in ROLLBACK, so it is safe against production.
--
-- WHAT IT PROVES
--   01  public.customer_delete_account_v749's function source now names sv_lots (the one
--       refusal that stays) and no longer names bar_bottles (the refusal v750 drops).
--   02  grants are unchanged since v749: authenticated (and service_role) yes, anon no.
--   03  end to end: the fixture customer (auth 253de8ef-b08c-40fa-b435-5723a6123a9d, identity
--       2fbdc1af-a8cf-4662-9ba7-2b08e9005c83) has a stored bar bottle at Bistro 999 and 8
--       verified links, and NO stored value anywhere. Deletion succeeds (status='deleted', not
--       'refused'). After: the Bistro 999 bar_bottles row survives untouched, still pointing at
--       the same (now-anonymised) client id, status still 'stored' — the business keeps its
--       property record; the client row is anonymised; zero verified links remain; the identity
--       is disabled; the auth user is banned.
--   04  a replay with the same idempotency key returns the recorded outcome instead of
--       re-running.

begin;

create temp table _v750(id int generated always as identity, check_name text, ok boolean, detail text) on commit drop;
grant all on _v750 to public;

do $$
declare
  v_actor uuid := '253de8ef-b08c-40fa-b435-5723a6123a9d';
  v_identity uuid := '2fbdc1af-a8cf-4662-9ba7-2b08e9005c83';
  v_bistro_business uuid := 'a3b7acb1-c2c6-46fb-a8cf-36b190a61b0a';
  v_bistro_client uuid := 'b6841243-dec8-40b4-ab60-91f432b58d2b';
  v_bottle_id uuid;
  v_bottle_status_before text;
  v_bottle_status_after text;
  v_bottle_client_after uuid;
  v_src text;
  v_result jsonb;
  v_links_left integer;
  v_client record;
  v_auth record;
  v_key text := 'suite-key-00750';
begin
  -- 01 — function source: sv_lots stays, bar_bottles is gone.
  select pg_get_functiondef(p.oid) into v_src
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'customer_delete_account_v749';
  insert into _v750(check_name, ok, detail) values (
    '01 function source contains sv_lots and no longer contains bar_bottles',
    v_src like '%sv_lots%' and v_src not like '%bar_bottles%',
    'sv_lots present=' || (v_src like '%sv_lots%')::text ||
      ' bar_bottles present=' || (v_src like '%bar_bottles%')::text);

  -- 02 — grants unchanged.
  insert into _v750(check_name, ok, detail)
  select '02 customer_delete_account_v749 is granted to authenticated, not to anon',
         coalesce(p.proacl::text,'') ~ 'authenticated=X' and coalesce(p.proacl::text,'') !~ 'anon=X',
         coalesce(p.proacl::text,'(default)')
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'customer_delete_account_v749';

  -- Fixture sanity, before we touch anything.
  select status into v_bottle_status_before from public.bar_bottles
   where id = (select id from public.bar_bottles
                where business_id = v_bistro_business and client_id = v_bistro_client
                  and status = 'stored' limit 1);
  select id into v_bottle_id from public.bar_bottles
   where business_id = v_bistro_business and client_id = v_bistro_client and status = 'stored'
   limit 1;
  if v_bottle_id is null then
    insert into _v750(check_name, ok, detail) values
      ('03 fixture', false, 'no stored bar_bottles row found at Bistro 999 for the fixture client — cannot exercise the end-to-end path');
  else
    -- 03 — end to end deletion succeeds despite the stored bottle.
    perform set_config('request.jwt.claims',
      json_build_object('sub', v_actor::text, 'role','authenticated')::text, true);
    set local role authenticated;
    v_result := public.customer_delete_account_v749('DELETE', v_key);
    reset role;

    insert into _v750(check_name, ok, detail) values (
      '03a the deletion succeeds despite the kept bottle (status=deleted, not refused)',
      v_result->>'status' = 'deleted', coalesce(v_result::text,'null'));

    select status, client_id into v_bottle_status_after, v_bottle_client_after
      from public.bar_bottles where id = v_bottle_id;
    insert into _v750(check_name, ok, detail) values (
      '03b the Bistro 999 bar_bottles row survives untouched (still stored, same client id)',
      v_bottle_status_after = 'stored' and v_bottle_client_after = v_bistro_client,
      'status=' || coalesce(v_bottle_status_after,'null') || ' client_id=' || coalesce(v_bottle_client_after::text,'null'));

    select full_name, phone, email into v_client
      from public.clients where id = v_bistro_client and business_id = v_bistro_business;
    insert into _v750(check_name, ok, detail) values (
      '03c the Bistro 999 client row is anonymised',
      v_client.full_name = 'Erased customer' and v_client.phone is null and v_client.email is null,
      'full_name=' || coalesce(v_client.full_name,'null'));

    select count(*)::integer into v_links_left
      from public.customer_links l where l.identity_id = v_identity and l.state = 'verified';
    insert into _v750(check_name, ok, detail) values (
      '03d no verified links remain for the erased identity',
      v_links_left = 0, v_links_left::text || ' verified links remain');

    insert into _v750(check_name, ok, detail)
    select '03e the customer_identities row is disabled', ci.status = 'disabled', ci.status
      from public.customer_identities ci where ci.id = v_identity;

    select u.banned_until, u.deleted_at into v_auth from auth.users u where u.id = v_actor;
    insert into _v750(check_name, ok, detail) values (
      '03f auth.users is banned to infinity and soft-deleted',
      v_auth.banned_until = 'infinity'::timestamptz and v_auth.deleted_at is not null,
      'banned_until=' || coalesce(v_auth.banned_until::text,'null') ||
      ' deleted_at=' || coalesce(v_auth.deleted_at::text,'null'));

    -- 04 — replay with the same idempotency key returns the recorded outcome.
    perform set_config('request.jwt.claims',
      json_build_object('sub', v_actor::text, 'role','authenticated')::text, true);
    set local role authenticated;
    begin
      v_result := public.customer_delete_account_v749('DELETE', v_key);
      insert into _v750(check_name, ok, detail) values (
        '04 a replay with the same key returns duplicate_ignored, nothing re-run',
        v_result->>'status' = 'duplicate_ignored', coalesce(v_result::text,'null'));
    exception when others then
      insert into _v750(check_name, ok, detail) values (
        '04 a replay with the same key returns duplicate_ignored, nothing re-run',
        false, sqlstate || ' ' || sqlerrm);
    end;
    reset role;
  end if;

  reset role;
exception when others then
  reset role;
  insert into _v750(check_name, ok, detail) values ('!! aborted', false, sqlstate || ' ' || sqlerrm);
end $$;

select check_name, case when ok then 'PASS' else 'FAIL' end as result, detail from _v750 order by id;
select count(*) filter (where not ok) as failures, count(*) as checks from _v750;

rollback;
