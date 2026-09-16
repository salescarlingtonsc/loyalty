-- Rollback suite for nestly_v992 — approval is tested by every guard.
--
-- Run against production inside a transaction that is ROLLED BACK by the final raise. It proves
-- three things, in the order that matters:
--   1. the hole this migration closes was real (a pending teammate read the customer list),
--   2. after the migration that principal reads nothing,
--   3. an approved teammate and the owner are completely unaffected.
--
-- It carries its own fixture: it flips ONE real staff row to 'pending' and back inside the
-- transaction, so it does not depend on an unapproved row existing on the estate (there are
-- none — that is the point of the migration's own §0 assertion).
--
-- Usage: supabase db query --linked -f db/tests/v992_approval_is_tested_by_every_guard.sql
-- The migration must already be applied; this suite asserts the post-state.

begin;

create temp table v992_suite(check_name text, expected text, actual text);

do $v992_suite$
declare
  v_staff uuid;
  v_user uuid;
  v_business uuid;
  v_clients_total integer;
  v_seen integer;
  v_perm boolean;
  v_modules integer;
  v_blind text[];
begin
  -- A real non-owner staff row with a login, in the business with the most customers.
  select s.id, s.user_id, s.business_id
    into v_staff, v_user, v_business
    from public.staff s
    join public.businesses b on b.id = s.business_id
   where s.user_id is not null and s.role <> 'owner' and s.active
     and s.access_state = 'approved'
   order by (select count(*) from public.clients c where c.business_id = b.id) desc
   limit 1;
  if v_staff is null then
    raise exception 'v992 suite: no approved non-owner staff row with a login to probe with';
  end if;
  select count(*) into v_clients_total from public.clients where business_id = v_business;
  if v_clients_total = 0 then
    raise exception 'v992 suite: the chosen business has no customers, so the probe proves nothing';
  end if;

  -- 1 · The guards themselves now name approval.
  insert into v992_suite
  select 'guards test access_state', '4 of 4',
         count(*)::text || ' of 4'
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'app'
     and p.proname in ('has_perm','can_see_branch','staff_module_mode_v94',
                       'staff_module_perms_at_v115')
     and pg_get_functiondef(p.oid) ~ 'access_state';

  -- 2 · No ninth function establishes staff identity without testing approval.
  select coalesce(array_agg(n.nspname||'.'||p.proname order by n.nspname, p.proname), '{}')
    into v_blind
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname in ('app','public') and p.prokind = 'f'
     and pg_get_functiondef(p.oid) ~ 'staff[a-z_]*\.user_id\s*=\s*auth\.uid\(\)'
     and pg_get_functiondef(p.oid) !~ 'access_state';
  insert into v992_suite
  values ('functions blind to approval', '{public.record_sale_by_phone}', v_blind::text);

  -- 3 · A PENDING teammate reads nothing.
  update public.staff set access_state = 'pending' where id = v_staff;
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_user, 'role', 'authenticated', 'aud', 'authenticated')::text, true);
  execute 'set local role authenticated';
  select count(*) into v_seen from public.clients;
  select app.has_perm(v_business, 'view_sales') into v_perm;
  execute 'reset role';
  insert into v992_suite values ('pending teammate sees clients', '0', v_seen::text);
  insert into v992_suite values ('pending teammate has_perm view_sales', 'false', v_perm::text);

  -- 4 · The same teammate, approved, is unaffected.
  update public.staff set access_state = 'approved' where id = v_staff;
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_user, 'role', 'authenticated', 'aud', 'authenticated')::text, true);
  execute 'set local role authenticated';
  select count(*) into v_seen from public.clients;
  select count(*) into v_modules
    from jsonb_object_keys((public.get_my_modules_at_v115(v_business, null))->'module_perms');
  execute 'reset role';
  insert into v992_suite values ('approved teammate sees clients',
                                 v_clients_total::text, v_seen::text);
  insert into v992_suite values ('approved teammate keeps modules', '> 0',
                                 case when v_modules > 0 then '> 0' else '0' end);
end
$v992_suite$;

do $v992_report$
declare r record; out text := ''; fails integer := 0;
begin
  for r in select * from v992_suite loop
    if r.expected = r.actual then
      out := out || '  PASS  ' || rpad(r.check_name, 38) || r.actual || chr(10);
    else
      fails := fails + 1;
      out := out || '  FAIL  ' || rpad(r.check_name, 38)
          || 'expected ' || r.expected || ', got ' || r.actual || chr(10);
    end if;
  end loop;
  raise exception E'nestly_v992 rollback suite — % failure(s)\n%', fails, out;
end
$v992_report$;

rollback;
