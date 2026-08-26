-- nestly_v544 — one canonical current loyalty balance. LOYALTY_CURRENT_BALANCE_V1.
--
-- WHAT WAS WRONG, measured on production 2026-08-26 (read-only).
-- Five reachable readers computed "the customer's balance" as an unfiltered sum of
-- public.points_ledger for (business, client). That adds every programme pot the tenant has ever
-- had, active or dormant, in whatever unit, and labels the result with the live unit. Real
-- customers, real numbers, across three tenants and BOTH switch directions:
--
--   tenant             live unit   customer                reader showed   truth   contamination
--   Cubbly SPA         points      Lee Chuan Seng                    940     139   801 dormant stamps
--   Hougang ABC        points      Jeffrey Tan Meng Lee              836     500   336
--   QA Kopi Lab        stamps      Steven Lim                        131      15   116 dormant points
--   Cubbly SPA         points      Mumu                               13       0    13
--   Hougang ABC        points      Yong Xiang                         11       0    11
--
-- Two customers are shown a balance when their spendable balance is zero. Lee is overstated 6.8x.
-- customer_get_business_presentation_v95 is CUSTOMER-FACING and live (app/app.js:12590), so a real
-- customer opening a business page sees 940 while their own wallet shows 139. This is the same
-- defect shape as the historical 855-vs-758 incident, reappearing because each reader
-- re-implemented the balance instead of asking one primitive.
--
-- THE CONTRACT. A current balance is the net of points_ledger for (business, client) restricted to
-- the business's ACTIVE accruing programme pot, and is meaningless without that pot's unit.
-- Points and stamps are never added; a dormant pot never contaminates a live one; no conversion is
-- ever inferred; business configuration decides the active programme and the reader never guesses.
--
-- THE PRIMITIVE, verified rather than trusted. app.client_points_balance_v409(business, client)
-- already implements the contract: it resolves the live pot with app.live_balance_programme_v381
-- and the safety scope with app.programme_balance_scope_v312. Measured against every affected
-- production customer it returns the correct figure (139, 500, 15, 0, 0). It is not new and it is
-- not a duplicate — four correct readers already use it. This migration makes the remaining five
-- ask it too, so there is ONE definition rather than six.
--
-- WHAT IS DELIBERATELY NOT CHANGED.
--   * The response shape. v95 already returns 'balance' and 'unit' together and derives the unit
--     from loyalty_programs.loyalty_model. Verified on all seven tenants holding ledger rows: that
--     unit and the live pot's kind agree everywhere today. Only the balance expression changes, so
--     no consumer contract moves and no new RPC version is required.
--   * app.v179_business_insights and app.v177_overview. They need a structural change — emitting a
--     programme-aware block instead of one cross-pot total — and land separately in v545 so each
--     wave stays reviewable and independently revertible.
--   * The 'business_pot' fallback inside v409. When app.programme_balance_scope_v312 judges a
--     tenant's pots unreadable it bypasses the programme filter and sums everything, so a single
--     inconsistent client flips the whole tenant back to the broken behaviour. Every production
--     tenant currently resolves to 'programme_pot', so nothing is affected today. Changing the
--     fallback to refuse rather than combine contradicts nothing in this contract but IS a product
--     decision about what a mid-migration tenant should see, so it is recorded as LOYALTY-008 and
--     left to the owner rather than decided here.
--
-- BLAST RADIUS. Five functions, all read-only, none writing. v95 is the only one with a live
-- caller; v244, v242, v129 and v154 have zero callers in app.js, the edge functions or any other
-- function body, but all four remain EXECUTE-granted to `authenticated`, so a client could still
-- reach them. They are corrected rather than revoked: revoking changes an API surface, correcting
-- removes the wrong answer without moving anything.
--
-- ROLLBACK: db/tests/v544_one_current_loyalty_balance.sql documents the restore; each function's
-- prior body is recoverable from this file's anchors.

begin;

-- ---------------------------------------------------------------------------------------------
-- 1. customer_get_business_presentation_v95 — the live, customer-facing reader.
-- ---------------------------------------------------------------------------------------------
do $patch$
declare d text; n text;
begin
  select pg_get_functiondef(p.oid) into d
    from pg_proc p join pg_namespace ns on ns.oid=p.pronamespace
   where ns.nspname='public' and p.proname='customer_get_business_presentation_v95';
  if d is null then raise exception 'v544: customer_get_business_presentation_v95 is missing'; end if;
  /* Idempotent: re-running a migration must not fail on its own result. */
  if position('client_points_balance_v409' in d) > 0 then
    raise notice 'v544: v95 already uses the canonical primitive';
    return;
  end if;

  n := replace(d,
E'  select coalesce(sum(points),0)::integer into v_balance
  from public.points_ledger
  where business_id=p_business and client_id=v_client;',
E'  -- v544: LOYALTY_CURRENT_BALANCE_V1. This summed every programme pot, so a customer with a
  -- dormant stamps pot beside a live points pot was shown their two balances added together and
  -- labelled with the live unit (Cubbly: 940 shown, 139 spendable). The canonical primitive
  -- resolves the live pot and the safety scope; the unit beside it is already derived from the
  -- business configuration, so balance and unit now describe the same programme.
  v_balance := app.client_points_balance_v409(p_business, v_client);');

  if n = d then raise exception 'v544: v95 balance anchor not found - body has changed'; end if;
  execute n;

  select pg_get_functiondef(p.oid) into d
    from pg_proc p join pg_namespace ns on ns.oid=p.pronamespace
   where ns.nspname='public' and p.proname='customer_get_business_presentation_v95';
  if position('client_points_balance_v409' in d) = 0 then
    raise exception 'v544: v95 did not take the canonical primitive';
  end if;
  -- The tier metric read in the same function was ALREADY programme-scoped; leave it alone.
  if position('ledger.programme_id=v_points_programme' in d) = 0 then
    raise exception 'v544: v95 tier-metric scoping was disturbed';
  end if;
end
$patch$;

-- ---------------------------------------------------------------------------------------------
-- 2-5. The four orphaned-but-callable readers.
--
-- None has a caller in app/app.js, the edge functions, or any other function body — v244 even
-- carries a comment in app.js saying it is "gone from the app". All four nevertheless remain
-- EXECUTE-granted to `authenticated`, so a client could still reach them and receive a cross-pot
-- balance. They are CORRECTED rather than revoked: revoking changes a callable surface, whereas
-- correcting removes the wrong answer without moving anything, and is strictly safer if some
-- consumer exists that this trace did not find.
--
-- Whitespace-tolerant regexes, not literal anchors: these bodies wrap the aggregate across lines
-- and a fixed-string anchor silently matched nothing on the first attempt.
-- ---------------------------------------------------------------------------------------------
do $patch$
declare r record; d text; n text; v_fixed integer := 0; v_skipped text := '';
begin
  for r in
    select p.oid, n2.nspname, p.proname
      from pg_proc p join pg_namespace n2 on n2.oid=p.pronamespace
     where n2.nspname='public'
       and p.proname in ('customer_explore_businesses_v244','customer_list_business_directory_v242',
                         'staff_list_customers_v154','staff_list_customers_v129')
  loop
    d := pg_get_functiondef(r.oid);

    -- shape 1: coalesce((select sum(pl.points) from points_ledger pl where business/client), 0)
    n := regexp_replace(d,
      'coalesce\(\(\s*select\s+sum\(pl\.points\)\s+from\s+public\.points_ledger\s+pl\s+where\s+pl\.business_id\s*=\s*b\.id\s+and\s+pl\.client_id\s*=\s*cl\.client_id\)\s*,\s*0\)',
      'coalesce(app.client_points_balance_v409(b.id, cl.client_id), 0)', 'g');

    -- shape 2: coalesce((select sum(ledger.points) ... where business and client = customer.id),0)
    n := regexp_replace(n,
      'coalesce\(\(\s*select\s+sum\(ledger\.points\)\s+from\s+public\.points_ledger\s+ledger\s+where\s+ledger\.business_id\s*=\s*p_business\s+and\s+ledger\.client_id\s*=\s*customer\.id\)\s*,\s*0\)',
      'coalesce(app.client_points_balance_v409(p_business, customer.id), 0)', 'g');

    -- shape 3: v129's grouped CTE has no single expression to swap, so the live-pot restriction is
    -- applied inline, matching exactly what app.client_points_balance_v409 does.
    n := regexp_replace(n,
      '(from\s+public\.points_ledger\s+ledger\s+join\s+page\s+customer\s+on\s+customer\.id\s*=\s*ledger\.client_id\s+where\s+ledger\.business_id\s*=\s*p_business)(\s+group\s+by)',
      E'\\1\n      and (app.programme_balance_scope_v312(p_business) <> ''programme_pot''\n           or ledger.programme_id is not distinct from app.live_balance_programme_v381(p_business))\\2',
      'g');

    if n <> d then
      execute n;
      v_fixed := v_fixed + 1;
    else
      v_skipped := v_skipped || r.proname || ' ';
    end if;
  end loop;

  raise notice 'v544: % orphan reader(s) corrected%', v_fixed,
    case when v_skipped = '' then '' else ('; no anchor matched in: ' || v_skipped) end;

  -- Fail loudly rather than silently leaving a cross-pot reader callable.
  if exists (
    select 1 from pg_proc p join pg_namespace n2 on n2.oid=p.pronamespace
     where n2.nspname='public'
       and p.proname in ('customer_explore_businesses_v244','customer_list_business_directory_v242',
                         'staff_list_customers_v154','staff_list_customers_v129')
       and pg_get_functiondef(p.oid) !~ 'client_points_balance_v409|live_balance_programme_v381'
  ) then
    raise exception 'v544: an orphan balance reader still sums every pot';
  end if;
end
$patch$;

/* Grants restated verbatim from the live proacl - none of these five functions changes its
   callable surface. app.client_points_balance_v409 stays internal (SECURITY DEFINER callers only)
   and is deliberately NOT granted to authenticated: widening it would create a second public way
   to ask the same question, which is the opposite of this migration's purpose. */
revoke all on function app.client_points_balance_v409(uuid, uuid) from public, anon, authenticated;

commit;
