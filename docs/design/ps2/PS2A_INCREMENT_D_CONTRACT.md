# PS-2A Increment D — Pause/Kill Controls + Owner UI + Cutover Preview (PINNED)

Builds on Increments A (v61) + B (v62) + C (v63). Migration **v64** (DB) + the first stored-value UI in
app/index.html. **Still forbidden:** production cutover, real value movement, real comms, `live`/
`ready_for_cutover`. Build-only gate: no UAT apply/deploy without separate owner word.

## 1. sv_pauses — dedicated stored-value pause (NOT the rule pause)
`studio_rule_emergency_pauses` is keyed on rule_id with rule-engine semantics; ledger authority needs
business/asset scope + operation-family granularity (contract §8). New `public.sv_pauses`:
- columns: id, business_id, asset, scope text CHECK in ('all','earn','redeem'), actor, reason (btrim≥3),
  paused_at, lifted_at, lifted_by; append-only lift-once (write-once guard, entitlement-guard pattern).
- partial unique: one ACTIVE pause per (business, asset, scope) where lifted_at is null.
- RLS owner+sa read; browser writes revoked; composite tenant FK.
- RPCs (owner-only, audited): `sv_pause(business, asset, scope, reason)`, `sv_lift_pause(business, asset,
  scope, reason)`. Idempotent (active pause returned; lift-of-none is a no-op). Audit SV_PAUSE / SV_PAUSE_LIFTED.

**Enforcement (teeth) in the Increment-C value RPCs** — CREATE OR REPLACE each, adding ONLY a pause check
(byte-diff must show only the added guard):
- an active `all` OR `earn` pause blocks sv_topup + sv_grant (new grants/earns) → 22023 `sv_paused`.
- an active `all` OR `redeem` pause blocks sv_spend + sv_reserve → 22023 `sv_paused`.
- **Pinned policy (contract §8): an `earn` pause does NOT block spend** — customers keep spending held
  value; only a `redeem`/`all` pause stops spend. Prove this exact matrix in tests.
- refund/reverse/expire: an `all` pause blocks them; document earn/redeem mapping (reversal of a spend is
  a redeem-family correction → blocked by redeem/all; refund is an earn-family correction → blocked by
  earn/all — pin precisely and test). Historical rows are never touched by any pause.
- Since every value RPC already hard-refuses unless authority=live (unreachable), the pause is a
  second, independent gate; test both gates independently.
- **No implicit lift:** publishing a loyalty config version cannot lift an sv pause (they are unrelated
  surfaces) — assert.

## 2. Reconciliation/authority read for the UI
Reuse B's `get_sv_reconciliation` + the extended `get_sv_account`. Add `public.get_sv_authority_overview(
business)` → `{asset, authority_state, spendable:(state='live'), shadow_testing, reconciliation:{has_run,
status, discrepancy_count}, active_pauses:[{scope,reason,actor,paused_at}], can_cutover:false}`. `can_cutover`
is **hardcoded false in PS-2A** (no cutover action exists) — the UI shows a disabled preview only.

## 3. Cutover PREVIEW only — no cutover action
`public.preview_sv_cutover(business)` → owner-only read: what cutover WOULD require and its current
blockers — `{authority_state, reconciliation_status, discrepancy_count, blocking_reasons:[...],
ready:false}`. `ready` is **always false in PS-2A** (authority can't reach ready_for_cutover; the RPC
states the blockers: "cutover is a future authorized phase", "reconciliation must be clean", etc.). NO
function that performs a cutover exists — the tripwire continues to assert none does.

## 4. UI (app/index.html) — the first stored-value surface, owner-only, truthful
A new owner-only "Stored value" area (under the Grow/Insights grouping or Settings — match the existing
nav idiom). It must:
- render `authority_state` and reconciliation status **verbatim** from the server; never infer.
- **never present stored value as spendable while authority ≠ live** — since it's always `unbuilt`/
  `shadow_testing` in PS-2A, every balance shown carries the server `disclaimer` ("simulated — not
  spendable"); the word "spendable"/"available to spend" never appears for a non-live asset.
- show the authority-state chip (unbuilt/shadow_testing/reconciliation_blocked/paused — never live in
  PS-2A), the reconciliation panel (discrepancies shown, never hidden, with categories in plain words),
  and pause status + scope + reason.
- owner controls: run reconciliation; enter/lift shadow_testing (set_sv_authority_state); pause/lift
  (all/earn/redeem) with a mandatory reason; a **disabled** "Cutover" affordance showing the preview
  blockers. Dangerous actions require explicit confirmation.
- **fail closed:** if get_sv_authority_overview / get_sv_reconciliation errors, show an error state and
  disable every control — never assume live/clean.
- controls hidden from non-owners (the RPCs are owner-only server-side regardless).
- No spend/topup/grant UI that moves real value (those RPCs refuse anyway; the UI must not imply a
  customer can spend). A shadow "simulate" affordance may show what an operation WOULD do, clearly
  labelled simulated.

## Adversarial tests (owner's 9–11 + UI truthfulness 19/20 continued)
9. pausing grants (earn/all) prevents new sv_topup/sv_grant → 22023 sv_paused, but history preserved
   (prior movements intact).
10. pausing redemptions (redeem/all) blocks sv_spend/sv_reserve; and — the pinned policy — an `earn`
    pause does NOT block spend (spend still works under earn pause when authority=live shim).
11. lifting a pause restores only the intended operation family (lift earn → grants work again, redeem
    still blocked if separately paused).
Plus: pause idempotent; lift-of-none no-op; one-active-per-scope; no implicit lift by config publish;
sv_pauses append-only + write-once; owner-only (frontdesk/anon 42501); cross-tenant denied; can_cutover
false; preview_sv_cutover ready=false with blockers; the value RPCs' pause-guard byte-diff is ONLY the
added check (kernel/other logic unchanged); UI: grep-prove no client-side "spendable" for non-live +
chip renders server state verbatim; validate stays green (lints app/index.html).

## House rules
Canonical + byte-identical mirror; RLS/ACL/definer/revoke; append-only/write-once guards; composite FKs;
integer cents; writers 0/0; PS-GATES note; tripwire keeps forbidding a real cutover function + keeps the
live-setter/balance-column/gift_cards-read-only assertions, and ADDS: no sv_pause lifts implicitly, and
`can_cutover`/`ready` are false. Manifests 97→98 / db 95→96. Checkout kernel + executor + prior phases
byte-unchanged.
