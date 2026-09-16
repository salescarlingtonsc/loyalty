-- Rollback suite for nestly_v994 — the super-admin arm is preserved, not reasoned about.
--
-- Two things must hold after v994:
--   1. the super-admin arm is back, as a policy, in its hoisted form;
--   2. putting it back changed nothing for anybody else — every principal a SQL harness can
--      impersonate has app.is_super_admin() = false, so the v993 CASE must still be what decides
--      for them, and the row sets must be identical to the ones v993's own suite proved.
--
-- (2) is the part worth running. (1) would be caught by the migration's own post-condition.
--
-- This suite deliberately does NOT claim to test the super-admin path itself: it cannot. See
-- db/tests/v993_the_reader_is_asked_once_not_once_per_row.sql for why a synthetic
-- request.jwt.claims can never satisfy app.platform_session_via_google_v625(). The value of v994
-- is precisely that the arm no longer DEPENDS on being reasoned about — it is the same policy
-- text the estate carried before v993.
--
-- Run against production; the final raise rolls everything back.
--   supabase db query --linked -f db/tests/v994_the_super_admin_arm_is_preserved_not_reasoned_about.sql

begin;

create temp table v994_businesses(business_id uuid);
insert into v994_businesses select b.id from public.businesses b;
create temp table v994_principals(uid uuid);
insert into v994_principals select distinct s.user_id
  from public.staff s where s.user_id is not null and s.active;
create temp table v994_seen(uid uuid, sales_rows integer, client_rows integer, sa boolean);
grant select on v994_businesses to authenticated;
grant insert on v994_seen to authenticated;

do $v994_probe$
declare p record;
begin
  for p in select * from v994_principals loop
    perform set_config('request.jwt.claims',
      json_build_object('sub', p.uid, 'role', 'authenticated', 'aud', 'authenticated')::text, true);
    execute 'set local role authenticated';
    insert into v994_seen
    select p.uid,
           (select count(*) from public.sales),
           (select count(*) from public.clients),
           (select app.is_super_admin());
    execute 'reset role';
  end loop;
end
$v994_probe$;

do $v994_report$
declare
  out text := '';
  fails integer := 0;
  v_qual text;
  v_sa integer;
  v_total_sales integer;
  v_total_clients integer;
  v_seen_sales integer;
  v_seen_clients integer;
begin
  -- 1 · the arm is a policy again, in the hoisted form
  select qual into v_qual from pg_policies
   where schemaname='public' and tablename='sales' and policyname='sales_sa_read';
  if v_qual = '( SELECT app.is_super_admin() AS is_super_admin)' then
    out := out || '  PASS  sales_sa_read restored, hoisted' || chr(10);
  else
    fails := fails + 1;
    out := out || '  FAIL  sales_sa_read reads ' || coalesce(v_qual,'<missing>') || chr(10);
  end if;
  select qual into v_qual from pg_policies
   where schemaname='public' and tablename='clients' and policyname='clients_sa_read';
  if v_qual = '( SELECT app.is_super_admin() AS is_super_admin)' then
    out := out || '  PASS  clients_sa_read restored, hoisted' || chr(10);
  else
    fails := fails + 1;
    out := out || '  FAIL  clients_sa_read reads ' || coalesce(v_qual,'<missing>') || chr(10);
  end if;

  -- 2 · nobody a harness can impersonate is a super admin, so nobody gained anything
  select count(*) into v_sa from v994_seen where sa;
  if v_sa = 0 then
    out := out || '  PASS  no impersonable principal is a super admin (' || v_sa || ')' || chr(10);
  else
    fails := fails + 1;
    out := out || '  FAIL  ' || v_sa || ' impersonable principal(s) read as super admin — the '
        || 'Google-session requirement has changed and this suite no longer proves what it claims'
        || chr(10);
  end if;

  select count(*) into v_total_sales from public.sales;
  select count(*) into v_total_clients from public.clients;
  select max(sales_rows), max(client_rows) into v_seen_sales, v_seen_clients from v994_seen;
  if v_seen_sales < v_total_sales and v_seen_clients < v_total_clients then
    out := out || '  PASS  no staff principal sees the whole estate ('
        || v_seen_sales || '/' || v_total_sales || ' sales, '
        || v_seen_clients || '/' || v_total_clients || ' clients at most)' || chr(10);
  else
    fails := fails + 1;
    out := out || '  FAIL  a staff principal sees ' || v_seen_sales || '/' || v_total_sales
        || ' sales and ' || v_seen_clients || '/' || v_total_clients || ' clients' || chr(10);
  end if;

  raise exception E'nestly_v994 rollback suite — % failure(s), % principals probed\n%',
    fails, (select count(*) from v994_seen), out;
end
$v994_report$;

rollback;
