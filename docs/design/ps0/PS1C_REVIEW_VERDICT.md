# PS-1C Independent Review Verdict — the unified checkout kernel (v58)

Reviewer: independent adversarial reviewer (not the author). Scope: the exact frozen
commit `3e1c894` (delta `git diff 318199a..3e1c894`). Single-verdict gate: on PASS the
owner has pre-authorised UAT apply + deploy without further approval.

## Formal verdict: **PASS PS-1C**

The v58 migration implements one authoritative, server-owned checkout kernel that meets
every owner requirement, holds all house invariants, introduces no forbidden surface, and
is proven by an ALL-PASS suite (independently re-run), a genuine two-connection concurrency
harness, and my own adversarial probes. The findings below are non-blocking recommendations
for the UAT journey, not gate conditions.

---

## Frozen state
HEAD `3e1c894` (the reviewed commit); parent `318199a` (PS-1B.1 round-2 verdict); `git
status` clean. Migration byte-hash `55b042ed04948d5e61ae92b3eea81b7df573535a5b18801e6f6ec07d69fb0fb7`
matches both manifests; the supabase mirror `20260724170000_*` is **byte-identical** (`cmp`
clean). Diff = 21 files: the migration + mirror, two test artifacts, the paths doc,
PS-GATES + tripwire, writer-registry, discover-writers, and manifest/phase0 bookkeeping —
no source file outside PS-1C scope is touched.

## Independent verification performed
- **Suite re-run** on the local cluster (`127.0.0.1:5499`, `frenly_freeze` = fresh 92-chain
  replay of this commit): `db/tests/v58_ps1c_checkout_kernel.sql` → **ALL PASS**. v58 objects
  present (checkout_evaluations / checkout_discount_lines / budget_commitment_releases /
  evaluate_checkout).
- **Adversarial probes** (rolled back) against `app.ps1c_plan_checkout` / `record_quick_sale`:
  a line carrying `unit_price_cents` → `client_priced`; a line carrying `discount` →
  `client_priced`; null config → `ok` with `discount_total_cents=0`; missing catalog row →
  `price_error` (no silent zero); `record_quick_sale(…,0,…)` → P0001 "a quick sale must have
  a positive amount".
- **Code trace** of the finaliser: `p_lines` appears only in the signature, never in the
  body — the token's `server_lines` are the sole pricing input. Executor
  (`ps1b_execute_event`), `on_sale_recorded`, and `loyalty_ledger_write_guard` have **0**
  redefinitions in v58.

## Requirement-by-requirement (owner mandate)

1. **Nothing client-priceable.** `ps1c_plan_checkout` hard-rejects any of
   `unit_price_cents / price_cents / amount_cents / line_total_cents / unit_cents / discount`
   on any line (`status:client_priced`, migration L467-471). Every price is resolved through
   the v57 typed `app.ps1b_catalog_price`; non-`ok` → `price_error` (L484-489). The finaliser
   re-resolves every server line and recomputes `cart_hash` **inside the sale txn** (L854-875),
   any drift → `stale_evaluation` (P0001). Token binds business/branch/client/config
   (request_hash + stored `config_version_id`); TTL 10 min (`expires_at`, L748); single-use is
   a write-once guard on `consumed_at/consumed_sale_id` plus the finaliser's `FOR UPDATE`
   (L160-191, L812, L978-982). Verified live.

2. **Money order of operations (§9).** Line discounts (level `desc` = line before bill) then
   bill discounts, each in deterministic `(rule_id, effect_index)` order (L553-557). Stacking
   suppression is recorded with a reason (`stacking` / `no_target` / `budget_exhausted`,
   L558-636). Clamping: `v_d` clamped to base, never negative; bill base = running
   `subtotal − Σdiscount`, so `total ≥ 0` (L588-597). GST-inclusive extraction is
   informational, total unchanged (L641-647). Integer-cent rounding is half-up (Postgres
   `round(numeric)` = half-away-from-zero on positive operands; both discount and GST use
   numeric operands). `Σ sale_items = sales.amount_cents` asserted byte-for-byte (suite §3/§5);
   `record_quick_sale` writes **no** sale_items (v20 L1649-1908), so the kernel is the sole
   itemiser — no double count.

3. **Budget.** Projected (not reserved) at evaluation against `committed + running per-rule
   projection` (L599-614). At finalisation, capped rules are re-checked and committed under a
   deterministic `(rule_id, period_start)` `FOR UPDATE` lock taken in sorted order (L877-902,
   L966-974) — deadlock-free, and the loser re-reads the winner's increment. The
   `budget_reservations` ALTER makes `entitlement_id` nullable but adds a one-owner XOR CHECK
   and a *partial* unique index on `discount_fulfilment_id`, leaving the v56
   `(budget_period_id, entitlement_id)` uniqueness and the append-only guard intact — the
   PS-1B entitlement path is not weakened. `committed = Σreservations − Σreleases ≥ 0` is
   asserted (suite §11); releases are exactly-once via `UNIQUE(reservation_id)` + a
   RETURNING-only CTE (L1063-1078).

4. **Reversal.** `reverse_sale(6)` is renamed to `reverse_sale_v40_base` (body preserved by
   rename; the v20 money core is reached through the intact v40→v34→v20 chain, verified in the
   migration history). The new wrapper delegates the entire existing reversal, then per
   `checkout_discount_lines` row writes a compensating **negative** fulfilment keyed
   `discount_reversal:{reversal_sale}:{rule}:{effect}` with `reverses_fulfilment_id`, and
   releases the budget once. A replayed reversal (same key → same `reversal_sale_id`) is a
   strict no-op via the fulfilment canonical-key conflict + the release uniqueness (suite §11,
   `v_n == v_released`).

5. **Sole live discount path.** The executor is unchanged (0 redefinitions) and keeps
   shadow-logging `apply_discount_*`; suite §14 asserts `run_studio_executor` produces **no**
   checkout-family fulfilment. `checkout_discount_lines`' only writer is the token finaliser —
   enforced by browser revocation, the append-only guard, and a NEW, non-tautological tripwire
   that scans the corpus and asserts every `insert into checkout_discount_lines` lives inside
   `record_cart_sale` in the v58 file (never in `evaluate_checkout` or elsewhere). No-token
   paths structurally cannot produce discounts; the classification doc covers every sale/tender
   writer with an honest "why".

6. **Forbidden absent.** No `credit_ledger` / `points_ledger` writes anywhere in the diff; the
   ledger write-guard is untouched and gains no studio scope. No `sv_*` / top-ups; `tier` and
   `stored_value` stay `unbuilt` (asserted by the re-strengthened v55). No tier financial
   rewards; no real comms. `on_sale_recorded` is unmodified — a discount reduces
   `sales.amount_cents` **before** it fires, so points/retention/referral earn on the
   **discounted** total. This is the correct reading of "legacy engines remain authoritative":
   the legacy accrual engine sees the true amount the customer paid, and the kernel adds no
   parallel ledger. Suite §4 asserts the discounted-total earn (4500, strictly below 5000).

7. **sale_items sign constraint.** `amount_sign_check` permits negatives only for
   `item_type='studio_discount'` and requires `line_cents = qty*unit_cents` for all rows; the
   original `line_cents = qty*unit_cents` invariant means every pre-existing row satisfies the
   new predicate; the pattern-drop removes only the three intended CHECKs (the `qty>0` check is
   preserved, FKs are `contype='f'`). v51 regression suites pass in the matrix.

8. **Owner test list.** Every item maps to a concrete assertion: replay (§2), double-click
   (§3), two-connection finalisation (concurrency harness race1), stale expired/price/config
   (§7/§8/§9), budget cap suppression + commit (§10), reversal + release + Σ-invariant +
   idempotent replay (§11), unpaid/partial/later-paid (§12), one-cent half-up + GST (§5),
   failure injection with whole-txn rollback + reusable token (§13), cross-tenant + anon +
   SA-read (§15), report reconciliation + CSV (§16), browser-write ACL (§17). Kernel-surface
   replay exercises quick-sale, no-token cart (v51/7), phone till, and gift-card issue+redeem
   with **zero** discount lines. Package/membership/appointment are classified but not
   runtime-exercised — see F3; sufficient because the single-writer guarantee is structural
   and tripwired.

9. **Bookkeeping.** db manifest 89→90 items / 75→76 executable / 20260724 count 3→4; supabase
   canonical 91→92 items / 46→47 pending; sha256 identical across mirrors and matching the
   file; all phase0 count tests and the materialiser updated coherently; the v21 security test
   adds v57+v58 to the authenticated-RPC forward-coverage (a real check the new public RPCs are
   allowlisted). Writer-registry +3 (`evaluate_checkout/5`, `record_cart_sale/9`,
   `reverse_sale_v40_base/6`) plus honest reclassification of `record_cart_sale/7` (SAFE
   WRAPPER) and `reverse_sale/6` (now a 4-layer stack). The v55 re-strengthening is a genuine
   tightening (now pins exactly 2 unbuilt: tier + stored_value, checkout→studio) — it would
   catch any accidental tier/sv advance.

10. **Known fixes sound.** Reversal-replay lookup uses the ORIGINAL sale id (sale_reversal op
    rows store the original id) — verified against the suite §11 query. Gift-card code is taken
    from `issue_gift_card`'s return (suite §14). The harness `mint | tail -n 1` correctly
    discards the `set_config` rows that pollute `-qAt` output.

## House invariants
All 12 v58 functions pin `search_path`; 10 are SECURITY DEFINER (the two exceptions —
`ps1c_cart_hash`, `ps1c_period_bounds` — are pure helpers with no table access). Every
function is revoked from public/anon/authenticated (13 revokes incl. the renamed
`reverse_sale_v40_base`, which gets **no** grant and stays internal-only); the four public
RPCs grant execute to authenticated. All new tables carry append-only / write-once guards
and owner+SA-only RLS with no browser write.

## Builder open items — judgment
- **(a) Fully-discounted (total=0) carts — ACCEPTED, non-blocking (F1).** They fail at
  `record_quick_sale` (P0001, positive-amount) with the whole txn rolled back and the token
  unconsumed/reusable. Fail-SAFE: no money moves, no double-sell, no silent zero. Acceptable
  for PS-1C — the mandate does not require completing a 100%-off sale.
- **(b) `checkout_evaluations.config_version_id` nullable — SOUND.** A no-config business
  prices with zero discounts; `null` config on the token vs `null` active config is *not*
  distinct, so no false stale; a later `null→non-null` config correctly forces re-evaluation
  (verified live).
- **(c) GST informational extraction — SOUND, ⚖️ appropriately flagged.** Inclusive extraction
  with the total unchanged is the correct model for SG GST-inclusive pricing; leaving the
  classification map to counsel is the conservative choice.

## Non-blocking findings / recommendations for the UAT journey
- **F1 (LOW) — 100%-off P0001 ambiguity.** A total=0 cart raises P0001 with a message distinct
  from `stale_evaluation` but the *same* SQLSTATE, so a client that auto-re-evaluates on P0001
  will loop on a genuine "first-visit-free"-style 100% checkout discount. Recommend a distinct
  SQLSTATE/status (or reject total=0 at evaluation, or model "free" as a PS-1B `grant_free_item`).
  `docs/design/ps0/CHECKOUT_KERNEL_PATHS.md` behaviour is otherwise correct.
- **F2 (TRIVIAL) — doc header wording.** `CHECKOUT_KERNEL_PATHS.md` §"SAFE WRAPPER —
  server-priced" includes `record_cart_sale/7`, which the same row honestly describes as
  client-priced. The safety property (no token ⇒ no studio discount) is correct and enforced;
  only the section header's blanket "server-priced" is imprecise. Recommend a wording fix.
- **F3 (LOW) — legacy-path runtime coverage.** package/membership/appointment sale paths are
  classified but not runtime-exercised (unlike the four paths in §14). Sufficient today because
  `checkout_discount_lines` has exactly one structural writer (tripwired), so those paths cannot
  produce a discount even in principle; a belt-and-suspenders "zero discount lines" assertion
  over those three would fully match §9's exit-test language. Recommend adding it when convenient.

## To confirm on UAT during apply/deploy (belt-and-suspenders; not gate conditions)
1. Apply v58 over the real v57 chain and confirm the `sale_items` sign-constraint rebuild and
   the `budget_reservations` ALTER succeed against **non-empty** existing rows (fresh replay is
   empty; production has history — the invariant `line_cents = qty*unit_cents` should make this
   clean, but confirm).
2. Confirm the checkout-family registry row flips `unbuilt→studio` for every existing tenant
   and that `tier` / `stored_value` remain `unbuilt` (the v55 assertion covers new tenants;
   confirm the one-time UPDATE covered pre-existing ones).
3. Run one real kernel checkout with a capped discount + its reversal on a synthetic UAT tenant
   and confirm `committed = Σreservations − Σreleases = 0` after reversal, with the compensating
   negative fulfilment persisted.
4. Re-run the concurrency harness against a disposable UAT-schema clone (never the live DB) to
   re-confirm one-winner token + budget-slot semantics.
