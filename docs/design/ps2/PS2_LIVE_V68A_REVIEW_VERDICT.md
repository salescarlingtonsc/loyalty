# PS-2 LIVE v68a (Chargeback, Bad Debt, Correction, Refund Caps) — Independent Review Verdict

## VERDICT: `PASS V68A` — **APPLIED TO PRODUCTION 2026-07-25**

- **Frozen commit:** `291cc0dfcb18f6eb7369a7383861a94b1b1bf8ad` (rev 2)
- **Canonical:** `db/migrations/20260724_frenly_v68a_chargeback_correction.sql`
- **Mirror:** `supabase/migrations/20260725070000_frenly_v68a_chargeback_correction.sql`
- **SHA-256 (both, byte-identical):** `4f83bd5b21e72cc538b6602e43be1002c7f1e054c07ee92e35272490f62680bc`
- **Applied via:** Supabase CLI `db push --linked` (one transaction, exact bytes) at canonical
  version `20260725070000`; no ledger normalisation required. Dry-run gate showed exactly one
  pending migration; zero history mismatches; no `--include-all`.

## What v68a delivers (directive §6, part 1 of 2)
Completes the PS-0 §6 "other operations" surface on the v63 engine: `sv_chargeback_topup` (void all
remaining via negative `correction`; bad debt = Σspend−Σreversal on the paid lot, recorded as a
zero-balance-effect `bad_debt` movement + `sv_chargebacks.bad_debt_cents`); owner-gated `sv_correct_lot`
(reason mandatory, both directions, bounded); refund cash-cap + no-arbitrage + `unused_only`; expiry
matrix hardening. It does NOT lift v67's §11a/§11b refusals (that is v68b) and asserts them as tripwires.

## Review arc
rev 1 `1359c7b`: independent review found D1 (MEDIUM, blocker) fail-open cash cap; D2 (MEDIUM)
registry-truth staleness; D3 (LOW) inert `full_unused`; D4/D5/D6 (INFO). rev 2 `291cc0d` closed them;
independent delta re-review returned **PASS V68A** with no new defects.

## rev-2 fixes verified by the independent reviewer
- **D1:** `minted_paid_fallback` deleted; `refund_sv_operation` refuses `sv_no_payment_evidence` before
  the locks AND re-asserts under them (TOCTOU); `CHECK (cash_basis='payment_evidence')`; post-condition
  asserts no function body contains the fallback (teeth-tested with a planted decoy). The **A10 attack**
  (payment-less paid lot on a real business forced live) is now REFUSED on whole refund, partial refund,
  AND chargeback — zero movements, zero cap rows, no idempotency key reserved. The cap was NOT relaxed;
  the rollback-only fixture supplies real payment evidence.
- **D2:** `ps0-writer-registry.test.mjs` now machine-checks `latest_file` + `rows_written` against the
  discovery tool (teeth-tested by re-injecting the stale entry); 4 pre-existing mismatches corrected
  individually (not mass-rewritten); discovery identity set + value_impact flags + counts unchanged.
- **D3:** `full_unused` → typed `sv_refund_policy_unimplemented` (fail-closed; refuses both unspent and
  post-spend cases); v65 catalog enum untouched.
- **D4:** non-`topup` target refused. **D6:** concurrency round B3 added; B/B2/B3 all exercised.
- **v55 test regression (from v66b's `security_invoker` flip, my earlier miss):** fixed test-only — §3
  routes through a rollback-only definer helper reproducing the sanctioned RPC path; cross-tenant
  isolation assertion keeps its teeth; no v55 migration byte changed.

## Post-apply production state (verified)
Ledger row at `20260725070000` (exactly one); `sv_chargebacks` + `sv_topup_cash_refunds` tables present
(RLS, owner/SA read, immutability guard); `sv_chargeback_topup` + `sv_correct_lot` present; refund carries
the evidence gate; fallback absent; `CHECK (cash_basis='payment_evidence')` in place. Security advisor
**0 ERROR** (+2 expected authenticated-SECDEF WARNs for the 2 new RPCs). **Zero value moved:** all real
businesses `sv_authority='unbuilt'`; 0 real lots/movements/payments; 0 chargebacks; 0 cash-refunds.
Synthetic canary unchanged (`shadow_testing`, 2 lots / 2 movements / 1 payment).

## Open (non-blocking, tracked)
- `writer-registry.json.value_table_registry` is a stale generated snapshot (no test consumes it) →
  regenerate in a cleanup increment.
- `full_unused` now fail-closed until an owner ruling on its intended meaning (no real business affected).
- ⚖️ bad-debt accounting treatment (write-off vs contra-revenue, GST) — owner + accountant.
- Pinned safe default (owner-ratifiable): prior-refund-then-chargeback reports `cash_already_refunded_cents`
  and recovers nothing.

## NOT launch-ready — remaining gates
v68a does not make real top-ups launch-ready. Remaining: **v68b** (lift §11a/§11b + net both settlement
legs, atomically) → **v69** controlled cutover (**must wire SV expiry/tender-release/reconciliation to
cron — none exist today**) → **v70** legacy gift-card/credit non-overlap → synthetic canary → one
owner-accepted pilot business.
