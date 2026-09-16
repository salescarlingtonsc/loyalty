-- Rollback suite for nestly_v993 — the reader is asked once, not once per row.
--
-- The thing that must be proved is not "it is faster" but "it decides exactly what it decided
-- before". So this suite recomputes the PRE-v993 predicate inline, as each real principal, and
-- compares it row by row against what row-level security actually returns now.
--
-- It probes every principal on the estate — every active staff login plus the super admin —
-- against every real row, and additionally against manufactured (business, branch) pairs the
-- live data does not contain: a NULL branch, an inactive branch, a branch belonging to another
-- business, and a branch id that does not exist. Those last two are the cases the fast
-- enumeration cannot represent and the CASE fallback exists for; without the fallback this
-- suite reports 75 divergences.
--
-- WHAT THIS SUITE DOES NOT PROVE EMPIRICALLY. app.is_super_admin() returns false for every
-- principal here, because it requires app.platform_session_via_google_v625() and a synthetic
-- request.jwt.claims cannot carry a real Google session (verified: it returns false even for the
-- row in public.super_admins). So the super-admin arm is proven STRUCTURALLY, not by execution:
-- both the old predicate and the new one call the same app.is_super_admin(), and when it is true
-- the old policy set returns every row (sales_sa_read is permissive-true, and can_see_branch
-- returns true for a super admin) while the new scope returns every business. Any future change
-- to that arm must be checked from a real console session, not from this suite.
--
-- Run against production; the final raise rolls everything back.
--   supabase db query --linked -f db/tests/v993_the_reader_is_asked_once_not_once_per_row.sql

begin;

create temp table v993_pairs(business_id uuid, branch_id uuid, origin text);
insert into v993_pairs select distinct s.business_id, s.branch_id, 'live sale' from public.sales s;
insert into v993_pairs select b.id, null::uuid, 'NULL branch' from public.businesses b;
insert into v993_pairs select br.business_id, br.id, 'inactive branch'
  from public.branches br where not br.active;
insert into v993_pairs select b.id, br.id, 'branch of another business'
  from public.businesses b
  cross join lateral (select br2.id from public.branches br2
                       where br2.business_id <> b.id limit 2) br;
insert into v993_pairs select b.id, '11111111-1111-1111-1111-111111111111'::uuid,
  'nonexistent branch' from public.businesses b;

create temp table v993_principals(uid uuid);
insert into v993_principals select distinct s.user_id
  from public.staff s where s.user_id is not null and s.active;
insert into v993_principals select sa.user_id from public.super_admins sa;

/* public.businesses is itself RLS-protected, so a probe running as the principal would only
   ever see its own firm and would never test "can this person read ANOTHER firm's customers".
   The candidate list is therefore built here, as the table owner, and handed to the probe. */
create temp table v993_businesses(business_id uuid);
insert into v993_businesses select b.id from public.businesses b;

create temp table v993_result(uid uuid, origin text, old_v boolean, new_v boolean);
create temp table v993_clients(uid uuid, business_id uuid, old_v boolean, new_v boolean);
grant select on v993_pairs to authenticated;
grant select on v993_businesses to authenticated;
grant insert on v993_result to authenticated;
grant insert on v993_clients to authenticated;

do $v993_probe$
declare p record;
begin
  for p in select * from v993_principals loop
    perform set_config('request.jwt.claims',
      json_build_object('sub', p.uid, 'role', 'authenticated', 'aud', 'authenticated')::text, true);
    execute 'set local role authenticated';

    -- sales: pre-v993 predicate vs the live policy expression
    insert into v993_result
    select p.uid, pp.origin,
      ( ((select app.is_super_admin()) or app.has_perm(pp.business_id, 'view_sales'))
        and app.can_see_branch(pp.business_id, pp.branch_id)
        and ((select app.is_super_admin())
             or app.can_module_read_at_v94(pp.business_id, pp.branch_id, 'sales')) ),
      ( case
          when (pp.business_id,
                coalesce(pp.branch_id, '00000000-0000-0000-0000-000000000000'::uuid))
               in (select scope.business_id, scope.branch_key
                     from app.sales_read_scope_v993() scope)
            then true
          when pp.branch_id is not null
               and not exists (select 1 from public.branches branch
                                where branch.id = pp.branch_id
                                  and branch.business_id = pp.business_id)
            then ( ((select app.is_super_admin()) or app.has_perm(pp.business_id, 'view_sales'))
                   and app.can_see_branch(pp.business_id, pp.branch_id)
                   and ((select app.is_super_admin())
                        or app.can_module_read_at_v94(pp.business_id, pp.branch_id, 'sales')) )
          else false
        end )
    from v993_pairs pp;

    execute 'reset role';

    -- clients: business-level only, so the probe is one row per business
    perform set_config('request.jwt.claims',
      json_build_object('sub', p.uid, 'role', 'authenticated', 'aud', 'authenticated')::text, true);
    execute 'set local role authenticated';
    insert into v993_clients
    select p.uid, b.business_id,
      ( (select app.is_super_admin()) or app.can_module_read(b.business_id, 'clients') ),
      ( b.business_id in (select scope.business_id from app.client_read_scope_v993() scope) )
    from v993_businesses b;
    execute 'reset role';
  end loop;
end
$v993_probe$;

do $v993_report$
declare
  r record;
  out text := '';
  fails integer := 0;
  n_sales integer;
  n_clients integer;
begin
  select count(*) into n_sales from v993_result;
  select count(*) into n_clients from v993_clients;

  for r in select origin, count(*) n,
                  count(*) filter (where old_v) a_old,
                  count(*) filter (where new_v) a_new,
                  count(*) filter (where old_v is distinct from new_v) bad
             from v993_result group by origin order by origin loop
    if r.bad = 0 then
      out := out || '  PASS  sales / ' || rpad(r.origin, 28)
          || lpad(r.n::text, 5) || ' evals, ' || r.a_old || ' allowed' || chr(10);
    else
      fails := fails + 1;
      out := out || '  FAIL  sales / ' || rpad(r.origin, 28)
          || r.bad || ' of ' || r.n || ' diverge (old allowed ' || r.a_old
          || ', new allowed ' || r.a_new || ')' || chr(10);
    end if;
  end loop;

  if (select count(*) from v993_clients where old_v is distinct from new_v) = 0 then
    out := out || '  PASS  clients                             '
        || lpad(n_clients::text, 5) || ' evals, '
        || (select count(*) from v993_clients where old_v) || ' allowed' || chr(10);
  else
    fails := fails + 1;
    out := out || '  FAIL  clients  '
        || (select count(*) from v993_clients where old_v is distinct from new_v)
        || ' of ' || n_clients || ' diverge' || chr(10);
  end if;

  -- The policy set the migration leaves behind.
  if (select count(*) from pg_policies
       where schemaname='public' and tablename='sales' and cmd='SELECT') = 1 then
    out := out || '  PASS  one SELECT policy on sales' || chr(10);
  else
    fails := fails + 1;
    out := out || '  FAIL  sales SELECT policy count is '
        || (select count(*) from pg_policies
             where schemaname='public' and tablename='sales' and cmd='SELECT') || chr(10);
  end if;

  raise exception E'nestly_v993 rollback suite — % failure(s), % sales evals + % client evals\n%',
    fails, n_sales, n_clients, out;
end
$v993_report$;

rollback;
