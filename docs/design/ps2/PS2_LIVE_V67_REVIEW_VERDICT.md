# PS-2 LIVE v67 (Stored Value as Checkout-Kernel Tender) — Independent Review Verdict

## VERDICT: `PASS V67` — **APPLIED TO PRODUCTION 2026-07-25**

- **Frozen commit:** `9f476bb47b3a32cec7c9e057701e41b585e94759` (rev 5)
- **Canonical:** `db/migrations/20260724_frenly_v67_ps2live_checkout_tender.sql`
- **Mirror:** `supabase/migrations/20260725060000_frenly_v67_ps2live_checkout_tender.sql`
- **SHA-256 (both, byte-identical):** `71423f959b3dd1892b32c5f637a25de9cbab5e3b5f67a033df1268efec2eb959`
- **Applied via:** Supabase CLI `db push --linked` (one transaction, exact file bytes — higher fidelity
  than `apply_migration`, which condenses comments). Recorded once at the canonical version
  `20260725060000`; no ledger normalisation required.

## Review history — five revisions, four independent rounds
| Rev | Outcome | What the round found |
|---|---|---|
| rev 1 `305f17b` | orchestrator CHANGES REQUIRED | writer-registry misclassification chain (a comment apostrophe desynced the discovery scanner, hiding the kernel finaliser); unproven `p_paid=false` accounting |
| rev 2 `ecb5590` | independent CHANGES REQUIRED | **D1 (HIGH)** reversing an SV-settled sale destroyed customer value silently; **D2** `get_revenue_summary` search_path regression; **D3** registry |
| rev 3 `b386d5a` | independent CHANGES REQUIRED | **D-A (HIGH)** `sv_reverse_spend` reversed the *settlement* around the sale gate — customer kept goods **and** got value back while books showed paid/realised; D-B guard blind to `app.*`; D-C tender guard ACL-dependent; D-D stale registry |
| rev 4 `703da58` | **PASS V67** (but unappliable) | pre-apply prod probe: §11b needle matched **0×** in prod — anchored on comment text that MCP applies had stripped |
| rev 5 `9f476bb` | **PASS V67** (applied) | needle re-anchored comment-free (**1×** in prod, verified); F2 settlement-uniqueness indexes; F3 discovery coverage |

## What v67 delivers
Stored value as a tender inside the existing PS-1C checkout kernel, driving the existing v63 spend
engine — no new spend arithmetic, no new mint path, no cutover. `checkout_sv_tenders` binds an
evaluation token to one reservation and, at finalisation, to the `sv_spend` that consumes it.
`app.sv_reserve_core` / `sv_spend_core` / `sv_release_core` are verbatim extractions of the v64/v63
bodies minus the owner check, so the owner RPCs and the till path drive one engine. §10 makes a
`consumed` tender the settlement marker read by `sale_balance` + `get_revenue_summary` (balance nets to
zero, `revenue_cash` includes the settlement, `cash_collected` excludes it — spending stored value
collects no new cash). §11a and §11b refuse unwinding an SV settlement from **both** directions.

## Independent verification highlights (rev 5)
- **Prod-shape fidelity proven by hash:** the rehearsal body with full-line comments stripped is
  **md5-identical** to production's live `sv_reverse_spend` (`2fbbdf9481b35f8a7af0b469c2694612`) —
  the parity harness reproduces prod exactly and is not self-confirming.
- **Completeness re-derived from scratch:** every route that could restore settled value or disarm a
  gate was enumerated and, where plausible, executed. All refused. `refund_sv_operation` on a
  partially-spent top-up cannot reach settled cents; `sv_expire_due`, the sweeps and the cores are
  closed to browsers and to `service_role`; movement kinds `correction`/`bad_debt` have no writer.
- **Both splices:** pure insertions, zero other bytes changed; drift tests and already-gated tripwires
  each raise and roll back the whole migration.
- **F2 negative control:** dropping the two settlement indexes reproduces the inflation
  (`sv_settled_cents` 5000→10000, and a plain cash sale reading `overpaid`); with them, both refused.
- **Gates:** 17 SQL suites + concurrency harness + prod-shape harness green; `npm run validate` 469/0.

## Production state after apply (verified)
Tender table + 6 unique indexes (incl. both F2 settlement indexes) + guard trigger + RLS with 3
policies; 6 new `app.*` and 2 new `public.*` functions; **both patches installed**; both predecessors
retain `search_path=pg_catalog, public, app, pg_temp`; `reverse_sale_v20_base` still closed to
`authenticated`, `sv_reverse_spend` still closed to `anon`. Security advisor **0 ERROR**.
**Zero value moved:** every real business `sv_authority='unbuilt'`; 0 real lots / movements / payments;
0 tenders; 0 reservations. Synthetic canary unchanged (`shadow_testing`, 2 lots / 2 movements /
1 payment). Legacy `gift_cards`/`credit_ledger`/`points_ledger` unchanged at 3/4/12.

## Open (INFO, non-blocking)
1. GUARD 3 catches accidental comment-anchored needles (the rev-4 pattern) but not deliberate evasion
   (`chr(45)||chr(45)`) or non-`replace()` splice idioms. Contract §9.1 keeps the mandatory pre-freeze
   **prod catalog read** as the real gate.
2. `service_role` holds `TRUNCATE` on every money table chain-wide (no `BEFORE TRUNCATE` guards exist
   anywhere); `checkout_sv_tenders` is exactly as protected as `payments`. Pre-existing, chain-wide.
3. Registry `counts` / `value_table_registry` blocks are stale snapshots needing a deliberate re-sync.
4. Suite prose cites the F2 inflation as 5000→6000; the reviewer reproduced 5000→10000 on that
   fixture. Cosmetic — mechanism and fix verified.

## NOT launch-ready — remaining gates
v67 does **not** make real top-ups launch-ready. Required path: **V68** refund/reversal/chargeback/
expiry → **V69** controlled cutover → **V70** legacy gift-card/credit non-overlap → synthetic canary →
one owner-accepted pilot business. No real payment may be accepted and no real business activated
before those pass. Lifting either §11 refusal in v68 **requires** netting the settlement legs out of
`sale_balance.sv_tender_totals` AND `get_revenue_summary.v_sv_cash` in the same increment.
