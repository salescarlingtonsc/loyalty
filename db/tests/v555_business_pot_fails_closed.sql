-- Rollback-only acceptance for nestly_v555 — an untrustworthy pot shows NO balance, never a
-- merged one (LOYALTY-008, owner ruling: fail-closed).
-- Run: supabase db query --linked -f db/tests/v555_business_pot_fails_closed.sql
-- Any row whose value starts with FAIL is a failure. Nothing is committed.
--
-- This runs against PRODUCTION, where all 8 live businesses with points_ledger rows currently
-- resolve app.programme_balance_scope_v312 to 'programme_pot' — nobody is on the fail-closed
-- path today. So this acceptance is about the healthy path (nothing moved for a healthy tenant)
-- plus proving the merge branch is structurally gone, not about exercising business_pot against
-- real data (that behaviour is covered by the executed golden fixture
-- db/tests/executed/v555_business_pot_fails_closed.sql, seeded and rolled back).
--
--   01  for every business with points_ledger rows, app.programme_balance_scope_v312 still
--       reads 'programme_pot' — report any business that flipped to business_pot, since that
--       would mean a REAL tenant is now fail-closed and the owner needs to know before this
--       migration is treated as routine.
--   02  the five known production customers (Cubbly 268cb96d-*, Hougang 6dc64db0-*, Kopi Lab
--       05ca41be-*, Cubbly b6454672-*, Hougang 7f2d3288-*) still resolve
--       app.client_points_balance_v409 equals an independent live-pot recomputation — the
--       fail-closed change must not move any healthy number.
--   03  none of the seven scope-reading functions' prosrc contains "<> 'programme_pot'" any
--       more — the merge-on-inconsistency branch is gone everywhere, not just in the five sites
--       this migration named.
--   04  app.client_points_balance_v409(null, <any uuid>) returns 0 without raising — a null
--       business is a business_pot case by construction (no live programme can be resolved),
--       so fail-closed means a quiet 0, not an error.
--
-- ROLLBACK: reverting v555 means restoring the OR form quoted in the migration header —
--
--     (v_scope <> 'programme_pot' or <row>.programme_id is not distinct from v_live)
--
-- — across the five sites app.client_points_balance_v409,
-- public.staff_get_customer_actionable_loyalty_v145 (both the ledger and the batches branch),
-- public.staff_list_customers_v155, and public.staff_list_customers_v129 (inline-call form).
-- That is only appropriate if the owner reverses LOYALTY-008 and decides an untrustworthy pot
-- should merge every unit into one number again — the exact defect nestly_v544/v545 exist to
-- correct. Do not roll this back to fix a support ticket without that explicit reversal.

begin;

create temp table _r(check_id text, value text) on commit drop;

-- 01 — no real tenant flipped to business_pot
do $scope$
declare
  flipped text;
begin
  select string_agg(format('%s(business=%s)', b.name, left(b.id::text,8)), ', ') into flipped
    from public.businesses b
   where exists (select 1 from public.points_ledger pl where pl.business_id = b.id)
     and app.programme_balance_scope_v312(b.id) is distinct from 'programme_pot';

  insert into _r values ('01 every business with ledger rows still resolves programme_pot',
    case when flipped is null then 'PASS'
      else pg_catalog.format('FAIL these businesses are now fail-closed: %s', flipped) end);
end
$scope$;

-- 02 — for EVERY customer with ledger rows, the primitive equals an independent live-pot
--      recomputation. The first draft hardcoded five customers' balances as measured at v544
--      time; these are live demo tenants whose balances move with daily activity, so the suite
--      failed on fresh, correct numbers (6dc64db0 800, b6454672 400 — both verified equal to
--      the raw live-pot sum). A balance suite for live data must carry its oracle, not a
--      snapshot of yesterday.
do $customers$
declare r record; got integer; want integer; bad integer := 0; note text := '';
begin
  for r in
    select distinct pl.business_id, pl.client_id
      from public.points_ledger pl
     where pl.client_id is not null
  loop
    got := app.client_points_balance_v409(r.business_id, r.client_id);
    select coalesce(sum(pl.points),0) into want
      from public.points_ledger pl
     where pl.business_id = r.business_id and pl.client_id = r.client_id
       and app.programme_balance_scope_v312(r.business_id) = 'programme_pot'
       and pl.programme_id is not distinct from app.live_balance_programme_v381(r.business_id);
    if got is distinct from want then
      bad := bad + 1;
      note := note || pg_catalog.format('[%s@%s: v409=%s independent=%s] ',
        left(r.client_id::text,8), left(r.business_id::text,8), got, want);
    end if;
  end loop;
  insert into _r values ('02 every customer balance equals the independent live-pot oracle',
    case when bad = 0 then 'PASS' else pg_catalog.format('FAIL %s: %s', bad, note) end);
end
$customers$;

-- 03 — the merge-on-inconsistency branch is gone from every scope-reading function
do $branch$
declare
  bad text;
begin
  select string_agg(n.nspname||'.'||p.proname, ', ') into bad
    from pg_proc p join pg_namespace n on n.oid=p.pronamespace
   where n.nspname in ('public','app')
     and p.prosrc like '%programme_balance_scope_v312%'
     and p.prosrc like '%<> ''programme_pot''%';

  insert into _r values ('03 no scope-reading function still contains the merge branch',
    case when bad is null then 'PASS'
      else pg_catalog.format('FAIL a merge-on-inconsistency branch survives in: %s', bad) end);
end
$branch$;

-- 04 — a null business is fail-closed to a quiet 0, never an error
do $nullcase$
declare
  bal integer;
  errored boolean := false;
  errmsg text := '';
begin
  begin
    select app.client_points_balance_v409(null, gen_random_uuid()) into bal;
  exception when others then
    errored := true;
    errmsg := sqlerrm;
  end;

  insert into _r values ('04 v409(null business, any uuid) returns 0 without error',
    case
      when errored then pg_catalog.format('FAIL raised: %s', errmsg)
      when bal is distinct from 0 then pg_catalog.format('FAIL returned %s, expected 0', bal)
      else 'PASS'
    end);
end
$nullcase$;

select check_id, value from _r order by check_id;

rollback;
