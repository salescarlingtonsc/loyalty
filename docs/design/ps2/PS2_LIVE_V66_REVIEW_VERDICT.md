# PS-2 LIVE v66 (staff-assisted top-up sale + Till) — Independent Review Verdict

## VERDICT: `PASS V66`

Independent adversarial review of the exact frozen commit (SHA-256 of bytes + full-catalog prosrc
inspection + execution of the acceptance, concurrency and atomicity suites).

- **Frozen commit:** `fbd5833b93a7d2bd562cc34190cd5c5df6bdad7e`
- **Canonical:** `db/migrations/20260724_frenly_v66_ps2live_topup_sale.sql`
- **Mirror:** `supabase/migrations/20260725030000_frenly_v66_ps2live_topup_sale.sql`
- **SHA-256 (both, byte-identical):** `b42388eafbc5d5a51b0ac5470bf1ae36b46910254760e24f57612481bd20204c` — **MATCHED**

## What v66 delivers (contract: PS2_LIVE_V66_TOPUP_SALE_CONTRACT.md rev 3)
`record_sv_topup_sale` — the single authoritative staff-assisted mint of a paid stored-value lot
(+ optional bonus lot), gated by authority state, keyed for idempotency, with an append-only payment
record. Plus: structural `is_synthetic` markers on businesses/clients (SA-only writes,
unmark-with-evidence blocked); the v61 `sv_topup`/`sv_grant` browser paths retired to fail-closed
raising stubs (execute revoked); a dedicated `sell_topups` permission; the current-sellable-version
projection; append-only `sv_topup_payments` + `sv_topup_payment_events`; and `preview_sv_topup_sale`.

## Verified (independent probes)
- **Mint-path closure (correction 1):** `record_sv_topup_sale/6` is the ONLY discovered value writer for
  stored value; `sv_topup`/`sv_grant` raise `22023` and have `EXECUTE` revoked from anon/authenticated;
  the writer-registry tripwire test fails if any alternate mint reappears.
- **Authority-state gate + TOCTOU:** `unbuilt` refuses; `shadow_testing`/`ready_for_cutover` accept ONLY
  synthetic-biz + synthetic-client + `method='test'`; `live` refuses any synthetic entity and the `test`
  method. The gate is re-validated **after** the account lock (finalisation re-check of both authority
  state and current-sellable-version), closing the check-then-act window.
- **Append-only payments:** `UPDATE`/`DELETE` on `sv_topup_payments` and `sv_topup_payment_events` raise
  (`23001`); non-cash reference uniqueness enforced by partial unique index.
- **Corrections 4–10:** dedicated `sell_topups` permission (distinct from generic module perms);
  current-sellable-version enforcement; TOTAL-outstanding max-balance check; synthetic marker lifecycle;
  complete idempotency hash + non-cash reference uniqueness; currency validation; preview parity.
- **Phase boundaries:** `topup_purchase_earns_points=true` → `policy_not_yet_supported` (no points on
  top-up in this pilot); cash is recorded as `cash_collected`/liability, never a revenue `sales` row.
- **Reinstate fixture:** `db/tests/fixtures/sv_mint_reinstate.psql` confirmed rollback-only + byte-identical
  to the pre-v66 `sv_topup`/`sv_grant`, so the v61–v64 suites still validate on the v66 chain; it is NOT a
  masked regression (the migration itself leaves the stubs fail-closed).
- **Concurrency + atomicity:** two-connection idempotency race → 1 op / 1 lot / 1 payment; capacity race →
  single winner; per-write-step failure injection rolls the whole op back atomically.
- **Suites:** V66 acceptance suite + `npm run validate` green; migration mints zero rows on apply.

## Post-apply addendum (found by me during prod verification; NOT a v66-review finding)
After applying v66 to prod, the Supabase **security advisor** flagged
`security_definer_view: public.v_business_billing` at **ERROR**. Root cause: v66's
`create or replace view public.v_business_billing as …` (which correctly added `where b.is_synthetic =
false`) also **reset the view's reloptions**, silently dropping the `security_invoker = true` it had
carried since introduction. Because the view is granted SELECT to `anon`/`authenticated`, it briefly ran
with the view owner's privileges, bypassing caller RLS on `businesses`/`subscriptions` — a cross-tenant
billing read. This was contained by **v66a** (`ALTER VIEW … SET (security_invoker=true)`; reloption-only,
definition untouched) — advisor ERROR cleared, behavioural RLS re-proven. See
`PS2_LIVE_V66A_REVIEW_VERDICT.md`. The v66 review did not exercise the reloption on `create or replace
view`; this is now covered by the v66a behavioural suite.

## Defects (v66 itself)
None blocking. Three LOW non-blocking notes: (1) v66 suite line ~213 comment says "synthetic customer
refused" but inserts `is_synthetic=false` (test-cosmetic; the migration is correct — probe P2 proved it);
(2) forward-watch — `app.sv_total_outstanding` = `sum(sv_lot_movements.cents)` is gross today but becomes
NET once v67 adds spend/reserve movements; v67 must keep reservations out of that sum; (3) contract §9's
optional `unsupported_currency` label is unimplemented (only `currency_mismatch` is raised).
