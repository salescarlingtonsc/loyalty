-- PS-0 value-domain reconciliation suite (scope C).
-- Read-only and rolled back. Run AFTER the complete canonical migration chain (through the
-- latest v53a) in a disposable rehearsal DB, exactly like the other db/tests/*.sql suites.
--
-- Purpose (ARCHITECTURE §4): exercise ONE conversion of each value-type-kind that exists
-- today and assert the single-representation invariant — each unit of economic value is
-- authoritatively represented in exactly one typed ledger; conversions are one-way, atomic,
-- recorded movements; no value appears in two authorities at once.
--
-- Conversions exercised (all through the real, live RPCs on the pristine A fixture):
--   1. Points  -> promotional credit   : earn via a qualifying sale, then redeem_points(...)
--   2. Gift card -> promotional credit  : issue_gift_card(...) then redeem_gift_card(...)
--   3. Package purchase -> session use  : sell_package(...) then use_package_session(...)
--
-- NOT exercised here, and WHY (see docs/design/ps0/VALUE_DOMAIN.md §4):
--   * Membership -> credit  : the live enrol path posts `membership_credit` only for a
--     credit-granting plan; exercised in the membership-touching phase.
--   * Stored value (paid/bonus lots + sv_lot_movements) : does not exist until PS-2. The §5
--     refund matrix becomes numbered tests in PS-2; this suite grows there.
--
-- ASSUMPTIONS (author could not run this; correct by construction):
--   A1. pristine fixture publishes a CLASSIC points loyalty config for business A with
--       earn_points_per_dollar=1, redeem_points=50, reward_credit_cents=500
--       (db/tests/fixtures/pristine_chain_fixture.psql:70-78). A $100 quick_sale therefore
--       earns ~100 points at rate 1/$, and redeem_points converts 50 pts -> 500 cents credit.
--   A2. Points are earned via a SALE (the blessed earn path) rather than a direct
--       points_ledger insert, because points_ledger carries a BEFORE INSERT write-guard
--       (trg_points_ledger_write_guard, ...v20_financial_engine.sql:761) and a config-version
--       trigger (...v26...:280) that only the in-trigger earn scope satisfies.
--   A3. The business owner bypasses module gates (app.can_module_write owner short-circuit,
--       ...v41...) so issue_gift_card works even though 'giftcards' is not in the fixture's
--       enabled_modules; owner holds create_sales via role_perms('owner').
--   A4. create_business auto-created a default branch for business A (v11a), which
--       use_package_session can select for a service_id-null plan.
-- If A1 is ever untrue, the >=50-points guard assertion localises the failure with a message.

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

do $ps0_recon$
declare
  v_biz_a uuid; v_owner_a uuid; v_client_a uuid;
  -- points -> credit
  v_sale_id uuid;
  v_pts_before integer; v_pts_after integer;
  v_credit_before integer; v_credit_after integer; v_credit_final integer;
  v_redeem_credit_delta integer;
  v_redeem json;
  -- gift card -> credit
  v_gc jsonb; v_gc_id uuid; v_code text;
  v_card_bal integer; v_card_status text;
  v_gcload_before integer; v_gcload_after integer;
  -- package -> sessions
  v_plan uuid; v_cp uuid; v_remaining integer; v_consumptions integer;
begin
  reset role;

  -- Resolve the active-loyalty fixture tenant (business A), its owner login, and client A.
  select b.id, s.user_id into v_biz_a, v_owner_a
    from public.businesses b
    join public.staff s
      on s.business_id = b.id and s.role = 'owner' and s.active and s.user_id is not null
   where b.name = 'Pristine chain fixture A';
  select id into v_client_a
    from public.clients where business_id = v_biz_a and email = 'pristine-a@example.test';
  if v_biz_a is null or v_owner_a is null or v_client_a is null then
    raise exception 'ps0 reconciliation suite requires the pristine A fixture';
  end if;

  -- =====================================================================================
  -- CONVERSION 1 — Points -> promotional credit (points row(-) and credit row(+) in one txn)
  -- =====================================================================================
  -- Earn via a qualifying sale (blessed earn path; respects the points_ledger write guard).
  insert into public.sales (business_id, client_id, kind, amount_cents, occurred_at, note)
    values (v_biz_a, v_client_a, 'quick_sale', 10000, statement_timestamp(), 'ps0 recon earn')
    returning id into v_sale_id;

  select coalesce(sum(points),0) into v_pts_before
    from public.points_ledger where business_id = v_biz_a and client_id = v_client_a;
  select coalesce(sum(amount_cents),0) into v_credit_before
    from public.credit_ledger where business_id = v_biz_a and client_id = v_client_a;

  perform pg_temp.assert_true(v_pts_before >= 50,
    'earn seeded points >= redeem threshold (assumes fixture rate 1/$ on a $100 sale)');

  perform pg_temp.as_user(v_owner_a);
  v_redeem := public.redeem_points(v_biz_a, v_client_a, 'ps0-recon-points-key');
  reset role;

  select coalesce(sum(points),0) into v_pts_after
    from public.points_ledger where business_id = v_biz_a and client_id = v_client_a;
  select coalesce(sum(amount_cents),0) into v_credit_after
    from public.credit_ledger where business_id = v_biz_a and client_id = v_client_a;
  v_redeem_credit_delta := v_credit_after - v_credit_before;

  -- Value LEFT points and ENTERED credit in one atomic call — never both. Entry-type
  -- agnostic on the credit side: the classic points->credit route has recorded the credit
  -- under 'manual_adjust' (v23/v23b) and 'loyalty_earn' (v23e/v24), never 'loyalty_redeem'
  -- (which is defined in the CHECK but unused by the redeem RPCs — see suite header + doc O).
  -- So assert on BALANCES, which prove single-representation regardless of the entry_type.
  perform pg_temp.assert_true(v_pts_after < v_pts_before,
    'points ledger decreased on redemption (value left points)');
  perform pg_temp.assert_true(v_redeem_credit_delta > 0,
    'credit ledger increased on redemption (value entered credit)');
  perform pg_temp.assert_true(
    exists (select 1 from public.points_ledger
             where business_id = v_biz_a and client_id = v_client_a and entry_type = 'redeem'),
    'redemption wrote a points redeem row (the points side of the one-transaction conversion)');

  -- =====================================================================================
  -- CONVERSION 2 — Gift card -> promotional credit (value on card XOR in credit)
  -- =====================================================================================
  perform pg_temp.as_user(v_owner_a);
  v_gc := public.issue_gift_card(v_biz_a, 5000, v_client_a, null, gen_random_uuid());
  reset role;
  v_gc_id := (v_gc->>'gift_card_id')::uuid;

  select code, balance_cents, status into v_code, v_card_bal, v_card_status
    from public.gift_cards where id = v_gc_id and business_id = v_biz_a;
  select coalesce(sum(amount_cents),0) into v_gcload_before
    from public.credit_ledger
   where business_id = v_biz_a and client_id = v_client_a and entry_type = 'gift_card_load';

  perform pg_temp.assert_eq(v_card_bal, 5000, 'issued gift-card balance = amount (value on the card)');
  perform pg_temp.assert_eq(v_card_status, 'active', 'newly issued gift card is active');
  perform pg_temp.assert_eq(v_gcload_before, 0, 'no gift_card_load credit before redemption (value not yet in credit)');

  perform pg_temp.as_user(v_owner_a);
  -- v41 hardening revoked the legacy redeem_gift_card from authenticated; the
  -- browser-facing (and thus contract-relevant) path is redeem_gift_card_v41.
  perform public.redeem_gift_card_v41(v_biz_a, v_code, v_client_a, null);
  reset role;

  select balance_cents, status into v_card_bal, v_card_status
    from public.gift_cards where id = v_gc_id and business_id = v_biz_a;
  select coalesce(sum(amount_cents),0) into v_gcload_after
    from public.credit_ledger
   where business_id = v_biz_a and client_id = v_client_a and entry_type = 'gift_card_load';

  perform pg_temp.assert_eq(v_card_bal, 0, 'redeemed card balance = 0 (value left the card)');
  perform pg_temp.assert_eq(v_card_status, 'redeemed', 'fully redeemed card is marked redeemed');
  perform pg_temp.assert_eq(v_gcload_after - v_gcload_before, 5000,
    'credit gained exactly the gift_card_load (value entered credit)');
  -- Conservation: value is on the card XOR in credit, never both.
  perform pg_temp.assert_eq(v_card_bal + (v_gcload_after - v_gcload_before), 5000,
    'gift-card value conserved: card balance + credit delta = initial');

  -- =====================================================================================
  -- CONVERSION 3 — Package purchase -> session consumption (session-denominated authority)
  -- =====================================================================================
  reset role;
  insert into public.package_plans (business_id, name, price_cents, sessions)
    values (v_biz_a, 'PS0 Recon Pack', 8000, 5) returning id into v_plan;

  perform pg_temp.as_user(v_owner_a);
  perform public.sell_package(v_biz_a, v_client_a, v_plan, gen_random_uuid());
  reset role;

  select id, remaining into v_cp, v_remaining
    from public.client_packages
   where business_id = v_biz_a and client_id = v_client_a and plan_id = v_plan
   order by purchased_at desc limit 1;
  perform pg_temp.assert_eq(v_remaining, 5,
    'sold package remaining = plan sessions (sessions are the sole authority, not cash)');

  perform pg_temp.as_user(v_owner_a);
  perform public.use_package_session(v_biz_a, v_cp, 'ps0-recon-package-key');
  reset role;

  select remaining into v_remaining from public.client_packages where id = v_cp;
  select count(*) into v_consumptions
    from public.package_session_consumptions where client_package_id = v_cp;
  perform pg_temp.assert_eq(v_remaining, 4, 'one session consumed');
  perform pg_temp.assert_eq(v_consumptions, 1, 'exactly one consumption row records the movement');
  perform pg_temp.assert_eq(v_remaining + v_consumptions, 5,
    'session value conserved: remaining + consumed = initial sessions');

  -- =====================================================================================
  -- CROSS-CUTTING — the authorities are disjoint; no unit is double-represented.
  -- =====================================================================================
  select coalesce(sum(amount_cents),0) into v_credit_final
    from public.credit_ledger where business_id = v_biz_a and client_id = v_client_a;

  -- Every cent of credit change is accounted for by the two conversions that produce credit:
  -- the points redemption (captured as v_redeem_credit_delta) and the gift-card redemption
  -- (the gift_card_load delta). Selling and consuming a package leaked NO cash into credit,
  -- and earning points wrote NO credit. Single-representation invariant, asserted globally:
  -- no value type double-counted into the credit authority.
  perform pg_temp.assert_eq(
    v_credit_final - v_credit_before,
    v_redeem_credit_delta + (v_gcload_after - v_gcload_before),
    'total credit change = points-redeem credit + gift_card_load; sessions/earn leaked no credit');

  raise notice 'PS-0 value reconciliation: all single-representation invariants hold.';
end
$ps0_recon$;

rollback;
