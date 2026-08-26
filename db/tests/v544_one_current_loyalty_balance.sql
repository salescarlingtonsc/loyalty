-- Rollback-only acceptance for nestly_v544 — one canonical current loyalty balance.
-- Run: supabase db query --linked -f db/tests/v544_one_current_loyalty_balance.sql
-- Any row whose value starts with FAIL is a failure. Nothing is committed.
--
-- v544 pointed every current-balance reader at app.client_points_balance_v409, which restricts the
-- ledger to the live programme pot. Before it, five readers summed every pot: a real Cubbly SPA
-- customer was shown 940 (139 live points + 801 dormant stamps) by the customer-facing
-- customer_get_business_presentation_v95 while their own wallet showed 139.
--
--   01  no reachable balance reader still sums the ledger without a programme restriction
--   02  the canonical primitive matches a hand-computed live-pot sum for every affected customer
--   03  the five previously-affected production customers now read their live-pot balance
--   04  a customer whose pots were never split is unchanged (the fix moved only what was wrong)
--   05  the primitive is not granted to anon or authenticated — one public way to ask, not two
--   06  cross-tenant: the primitive answers per (business, client) and never spans businesses
--
-- ROLLBACK OF THE MIGRATION ITSELF: each patched function's prior body is a single expression,
-- recorded in the migration file. To revert, replace app.client_points_balance_v409(...) with the
-- original correlated sum over public.points_ledger filtered only by business_id and client_id.
-- Reverting restores the defect and is only appropriate if the primitive itself is found faulty.

begin;

create temp table _r(k text, v text) on commit drop;

-- 01 — no reachable reader sums the ledger unscoped
insert into _r
select '01 no unscoped balance reader remains',
  case when count(*) = 0 then 'PASS'
       else 'FAIL — still unscoped: ' || string_agg(proname, ', ') end
from (
  select p.proname
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public'
     and p.proname in ('customer_get_business_presentation_v95','customer_explore_businesses_v244',
                       'customer_list_business_directory_v242','staff_list_customers_v154',
                       'staff_list_customers_v129')
     and pg_get_functiondef(p.oid) !~ 'client_points_balance_v409|live_balance_programme_v381'
) x;

-- 02 — the primitive equals an independent live-pot computation, for every client of every tenant
insert into _r
select '02 primitive matches an independent live-pot sum',
  case when count(*) filter (where mismatch) = 0
       then 'PASS (' || count(*) || ' client rows checked)'
       else 'FAIL — ' || count(*) filter (where mismatch) || ' client(s) disagree' end
from (
  select app.client_points_balance_v409(c.business_id, c.id)
         is distinct from
         coalesce((select sum(pl.points) from public.points_ledger pl
                    where pl.business_id = c.business_id and pl.client_id = c.id
                      and (app.programme_balance_scope_v312(c.business_id) <> 'programme_pot'
                           or pl.programme_id is not distinct from
                              app.live_balance_programme_v381(c.business_id))), 0) as mismatch
    from public.clients c
   where exists (select 1 from public.points_ledger pl
                  where pl.business_id = c.business_id and pl.client_id = c.id)
) x;

-- 03 — the five customers the audit measured now read their live-pot balance, not the merged one.
--      Clients are pinned by ID, not by name: Cubbly holds TWO rows called "Lee Chuan Seng" (the
--      real customer 268cb96d and an empty duplicate a88f18a6 at 0), and a name join matched both,
--      producing a spurious FAIL on the first run of this suite.
insert into _r
select '03 ' || x.label,
  case when app.client_points_balance_v409(x.bid, x.cid) = x.expected
       then 'PASS (' || x.expected || ', was ' || x.merged || ')'
       else 'FAIL — primitive says ' || app.client_points_balance_v409(x.bid, x.cid)
            || ', expected ' || x.expected end
from (values
  ('8492e8d6-8888-4383-ada0-7e1ed69f0caa'::uuid,'268cb96d-e6cc-4217-99f6-884b006ba7a3'::uuid,'Cubbly SPA / Lee Chuan Seng',      139, 940),
  ('53677cf5-abb8-4a41-a17b-17cdc0bc06d4'::uuid,'6dc64db0-2370-490c-9e3f-fafe58a67fd4'::uuid,'Hougang ABC / Jeffrey Tan Meng Lee',500, 836),
  ('8ad4a375-2d42-4e0d-b509-b0e4ed6ccf8c'::uuid,'05ca41be-60d9-4f1f-8f8f-d9532c41066a'::uuid,'QA Kopi Lab / Steven Lim',           15, 131),
  ('8492e8d6-8888-4383-ada0-7e1ed69f0caa'::uuid,'b6454672-38a8-49cb-af4f-8e98fafae2ed'::uuid,'Cubbly SPA / Mumu',                   0,  13),
  ('53677cf5-abb8-4a41-a17b-17cdc0bc06d4'::uuid,'7f2d3288-fe17-45ca-80c9-7429230a1bd8'::uuid,'Hougang ABC / Yong Xiang',            0,  11)
) x(bid, cid, label, expected, merged);

-- 04 — a customer whose only pot is the LIVE one must be untouched by the fix.
--      The first draft asserted this of any single-pot customer, which is wrong: a customer whose
--      sole pot is DORMANT should move to 0, and Yong Xiang (Hougang ABC, 11 dormant) duly did.
--      That is the fix working, not a regression, so the population is narrowed to live-pot-only.
insert into _r
select '04 live-pot-only customers unchanged',
  case when count(*) filter (where moved) = 0
       then 'PASS (' || count(*) || ' live-pot-only clients checked)'
       else 'FAIL — the fix moved ' || count(*) filter (where moved) || ' client(s) it should not have' end
from (
  select app.client_points_balance_v409(c.business_id, c.id)
         is distinct from
         coalesce((select sum(pl.points) from public.points_ledger pl
                    where pl.business_id = c.business_id and pl.client_id = c.id), 0) as moved
    from public.clients c
   where 1 = (select count(distinct pl.programme_id) from public.points_ledger pl
               where pl.business_id = c.business_id and pl.client_id = c.id)
     and exists (select 1 from public.points_ledger pl
                  where pl.business_id = c.business_id and pl.client_id = c.id
                    and pl.programme_id is not distinct from app.live_balance_programme_v381(c.business_id))
) x;

-- 05 — the primitive stays internal; widening it would create a second public way to ask
insert into _r
select '05 primitive not publicly granted',
  case when not has_function_privilege('authenticated', p.oid, 'EXECUTE')
        and not has_function_privilege('anon', p.oid, 'EXECUTE')
       then 'PASS' else 'FAIL — app.client_points_balance_v409 is callable by a client role' end
from pg_proc p join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'app' and p.proname = 'client_points_balance_v409';

-- 06 — the same person in two businesses gets two independent answers
insert into _r
select '06 cross-business isolation',
  case when count(*) = 0 then 'PASS (no shared-phone customer holds a merged balance)'
       else 'FAIL — ' || count(*) || ' shared-phone customer(s) read the same balance in two businesses' end
from (
  select c1.phone_norm
    from public.clients c1
    join public.clients c2
      on c2.phone_norm = c1.phone_norm and c2.business_id <> c1.business_id
   where c1.phone_norm is not null
     and app.client_points_balance_v409(c1.business_id, c1.id) <> 0
     and app.client_points_balance_v409(c1.business_id, c1.id)
         = app.client_points_balance_v409(c1.business_id, c2.id)
) x;

select k, v from _r order by k;

rollback;
