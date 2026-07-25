# PS-2 LIVE v68b (Lift SV-Settlement Refusals + Net Accounting Legs) — Independent Review Verdict

## VERDICT: `PASS V68B` — **APPLIED TO PRODUCTION 2026-07-25**

- **Frozen commit:** `1503d41ea2a2773898bed311d404e2639a01f492`
- **Canonical:** `db/migrations/20260724_frenly_v68b_sv_reversal_netting.sql`
- **Mirror:** `supabase/migrations/20260725080000_frenly_v68b_sv_reversal_netting.sql`
- **SHA-256 (both, byte-identical):** `55a95c0598278d89b0dac04257843f97570344ddd3eb539b6fb7f236ee42a124`
- **Applied via:** Supabase CLI `db push --linked` at canonical `20260725080000`. Dry-run gate showed
  exactly one pending migration, zero mismatches. **Both §11a splice needles were validated against
  production's live catalog BEFORE the independent review** (1 occurrence each; target unpatched) —
  the v67 rev-4 lesson applied in the correct order.

## What v68b delivers (directive §6 part 2 — the coupled increment)
All three coupled changes atomically: (1) coherent restitution — `app.sv_reverse_spend_core` (v64 body
minus owner check + synthetic/currency/TOCTOU gates + chargeback fail-closed refusal), restore-then-
expire preserved, PS-0 case (f) cents-exact; (2) netting of BOTH §10 legs —
`sale_balance.sv_tender_totals` and `get_revenue_summary.v_sv_cash` net via NOT EXISTS against the new
append-only `checkout_sv_tender_reversals` marker (NOT via `s.reversal_of`, the v67 trap); (3) the lift
of §11a (splice: refusal deleted + restitution hook) and §11b (full replace: owner-check → core →
marker). The v67 tender state machine and F2 settlement-uniqueness indexes are untouched — the builder
correctly rejected a `consumed→reversed` transition because it would move rows out of the F2 partial
indexes and reopen the double-settlement hole.

## Independent verification highlights
- **Reviewer-measured netting deltas** (own probes): door A SV-only → revenue_cash −5000,
  cash_collected unmoved, balance 0/paid; door A split → revenue_cash −8000, cash_collected −3000 with
  EXACTLY one refund payment; door B (spend reversed, sale stands) → revenue_cash −5000, balance
  reopens 5000/unpaid A/R.
- **Door-B accounting adjudicated CORRECT:** customer holds goods + restored value ⇒ the sale is an
  outstanding receivable; anything else would recreate the v67 double-spend.
- **C1 no unpaid-for value:** A→B refused (over-reversal), B→A skipped (already_reversed), concurrent
  A-vs-B one winner + once-only restitution, chargeback ordering both ways safe (no resurrection,
  no over-void), case (f) trail exact, no path exceeds minted_cents.
- **C2 no double cash-out:** split refunds exactly once across replay / refund-after-reverse / B-then-A.
- Both splices proven fail-closed under drift (whole-migration rollback); suite edits (v67 §11 + v68a
  §11) adjudicated surgical and honest — the v68a edit exceeded the contract's literal one-suite
  sanction but was unavoidable and disclosed (DOC-1).
- Gates: 472/472 validate; 21 suites + 3 concurrency harnesses + extended prod-shape harness green;
  registry machine-checks 11/11; catalog sweep clean; clean-chain apply writes zero value rows.

## Post-apply production state (verified)
Ledger `20260725080000`; marker table present (0 rows, RLS, immutable, browser-DML revoked); §11a
refusal GONE + restitution hook present; §11b refusal GONE + delegator shape; both §10 surfaces netted;
`security_invoker=on` preserved on sale_balance; v21 search_path preserved on get_revenue_summary.
Security advisor **0 ERROR**. All real businesses `sv_authority='unbuilt'`; 0 real value rows; canary
unchanged (shadow_testing, 2 lots / 2 movements / 1 payment).

## Findings (non-blocking, tracked)
- **LOW-1:** concurrent door-A-vs-door-B reversal resolves via deadlock detection (40P01) for the loser
  rather than a typed refusal — money invariants fully hold (one winner, once-only restitution).
  **→ v69 contract: add a defensive lock-ordering note** (advisory-lock-first in the sale core, or
  document 40P01 as an acceptable retriable outcome).
- **DOC-1:** contract §7 said "the ONE sanctioned prior-suite edit"; two were needed (v67 + v68a).
  Wording corrected here for the record.

## Directive §6 status: COMPLETE (v68a + v68b)
Refund/reversal/chargeback/expiry matrix is now whole: chargeback + bad debt + corrections + refund
caps (v68a) and coherent SV-settled reversal with truthful accounting (v68b). Remaining before any real
payment: **v69** controlled cutover (**hard requirements: wire SV cron — expiry / tender-release /
reconciliation — none scheduled today; lock-ordering note from LOW-1**) → **v70** legacy gift-card/
credit non-overlap → synthetic canary journey → ONE owner-accepted pilot business.
