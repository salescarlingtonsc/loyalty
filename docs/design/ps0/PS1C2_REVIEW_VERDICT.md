# PS-1C.2 Independent Review Verdict — truthful execution state + emergency pause (v60)

Reviewer: independent adversarial reviewer (not the author). Scope: the exact frozen commit
`ade72e1` (delta `git diff fe7feba..ade72e1`). Single-verdict gate: on PASS the owner has
pre-authorised UAT apply + deploy.

## Formal verdict: **PASS PS-1C.2**

v60 replaces the false placeholder execution-state with a server-derived 9-state model that
matches actual execution, and adds an emergency-pause control with real teeth — implemented
by adding **exactly one predicate** to each live engine (byte-verified) and touching no
financial-execution logic. Every owner requirement is met, all house invariants hold
(machine-verified), no forbidden surface appears, and the suite (independently re-run) plus my
own adversarial probes confirm both the fix and the safety property. No findings.

---

## Frozen state
HEAD `ade72e1`; parent `fe7feba` (PS-1C.1 verdict); `git status` clean. v60 migration hash
`dcc3c185ca76feab172f8a76312da08ceb604d7ecace02edbe617854e0fd99fa` matches both manifests; the
supabase mirror `20260724190000_*` is **byte-identical** (`cmp` clean). Diff = 19 files, all in
scope. PS-GATES documents PS-1C.2 as a truthfulness/control increment under the standing PS-1C
authorization — **no new phase**, the AUTHORIZED PHASES table is unchanged, and the emergency-pause
table is explicitly classified as a control surface (not an EXECUTOR ARTIFACT; moves no value, adds
no ledger/guard scope).

## The critical safety verification — the two live engines changed by ONLY the pause predicate
I extracted each function and byte-diffed it against its true predecessor:
- **`app.ps1b_execute_event`** (v57 → v60): the *only* delta is the added
  `and not exists (…studio_rule_emergency_pauses… lifted_at is null)` predicate on the
  compiled-rule loop's WHERE clause. Everything else byte-identical (v58/v59 do not redefine it,
  so v57 is the correct predecessor).
- **`app.ps1c_plan_checkout`** (v59 → v60): the *only* delta is the same predicate on the
  candidate-gather loop's WHERE clause. Custom-line handling, price rejection, discount
  gathering/application, budget projection, GST extraction, and the typed zero-total result are
  byte-identical.
This proves the pause "stops NEW effects" by *removing the rule from the loop*, with zero
regression to the money/execution paths.

## Independent verification performed (local cluster, `frenly_freeze` = fresh 94-chain replay)
- **Suite re-run**: `v60_ps1c2_execution_state.sql` → ALL PASS.
- **Per-effect state contract, live**: `apply_discount_pct`/`grant_free_item`/`display_perk` →
  `live`; `grant_credit`/`earn_bonus_points` → `shadow`; `tier_multiplier` → `unbuilt`;
  `send_notification` → `unbuilt`; unknown → `unbuilt` — exactly the pinned contract.
- **`ps1b_effect_family` NOT mutated** (0 redefinitions); the new `ps1c2_effect_family`
  classifies `send_notification`→`comms` while `ps1b_effect_family` still returns
  `points_loyalty` (executor shadow-log behaviour untouched), exactly as the contract requires.
- **Bookkeeping machine-verified**: phase0-foundation `node --test` → 18/18, including "every
  newly created public table has RLS and an explicit browser-role ACL" (covers
  `studio_rule_emergency_pauses`) and "pending SECURITY DEFINER RPCs pin search_path and revoke
  default execution" (covers all six v60 RPCs).

## Requirement-by-requirement

**(§1 defect fixed / server-derived states).** `app.ps1c2_rule_state` derives the 9-state
aggregate from config status + active + validation + per-effect family/engine + registry cutover +
active emergency pause. The suite proves the fix end-to-end: a published `apply_discount_amount`
rule reads **`live`** *and* the kernel actually drops 5000→4000 and finalises the discount; a
published `grant_free_item` reads **`live`** *and* the executor materialises the fulfilment; a
published `grant_credit` reads **`shadow_testing`** *and* writes NO studio `points_loyalty`
fulfilment (legacy authoritative). No published studio-authoritative executing rule can still
report `ready_for_activation`. The old `app.ps1a_studio_rule_state` is kept (revoked, unused) as
history; both callers (`get_programs_overview`, `get_program_rules_draft`) are repointed.

**(§2 per-effect truth).** `get_programs_overview` studio rows now carry `aggregate_state`,
`effect_states:[{effect_index,effect_type,family,state}]`, and `emergency_pause`, with
`execution_state` == `aggregate_state` for back-compat. A mixed `apply_discount_amount +
tier_multiplier` rule → `partially_live` with `effect_states` `[live checkout, unbuilt tier]`; a
partially executing rule never shows a bare `live`. `points_loyalty` → `shadow_testing` with zero
studio points/credit writes.

**(§3 publish preview + confirmation).** `preview_publish_impact` returns per-rule + per-effect
`state_after_publish`, `financial`/`customer_facing`, `aggregate_state_after_publish`, and
top-level `will_activate_live_financial` / `will_activate_customer_facing` /
`requires_confirmation` (true iff an **active** rule has a live financial/customer-facing effect —
sound: an inactive rule never executes because both engine loops filter on `active`). The UI calls
it before publish, renders the impact, and when `requires_confirmation` **disables Publish until
the owner types "PUBLISH"** (explicit typed confirmation); a preview error blocks publish entirely
(fail-safe).

**(§4 pause — both kinds, with teeth).** `set_studio_rule_active` is the normal pause/resume: it
clones the active published config to a draft, flips only this rule's `active` flag, and publishes
a new version through the immutable lifecycle (never mutating a published version); owner-only,
audited, no-op creates no version. `emergency_pause_studio_rule` / `lift_emergency_pause` write the
owner-only, write-once/lift-once `studio_rule_emergency_pauses` (one active pause per logical rule
via a partial-unique index; append-only guard; RLS owner+SA read; browser writes revoked; audited).
The pause keys on the **logical** `rule_id`, so it spans config versions — a paused rule cannot be
silently un-paused by re-publishing; it must be explicitly lifted. The suite proves: an
emergency-paused checkout rule stops discounting at `evaluate_checkout` while **all prior
`checkout_discount_lines` / `benefit_fulfilments` / budget rows survive**; a paused recurring rule
materialises nothing; lifting restores execution in both engines; re-pause is idempotent.

**(§5 proof on the synthetic tenant).** The suite exercises all nine states, both pause kinds,
history preservation, superseded→retired, draft state transitions, and owner-only permission
(anon + non-owner frontdesk denied) — on the pristine fixture. Re-run green.

**(§6 permission honesty).** Custom pricing is labelled **"Owner and manager only"** in the till
UI and in `CHECKOUT_KERNEL_PATHS.md` (Option A), with the honest note that `custom_price_lines` is
carried by exactly those two roles and granting it means promoting a login to manager — not an
individual grant.

**(Scope / forbidden).** No stored value, no real comms (`send_notification` still only reaches the
synthetic capture provider; comms state is `unbuilt`), no new customer-value effect. No
`credit_ledger`/`points_ledger` writes in the diff; the ledger write-guard is untouched; no
`benefit_registry.execution_authority` mutation. The v60 SECURITY DEFINER functions pin search_path
and revoke from public/anon/authenticated; the four owner RPCs grant execute to authenticated; the
`app.*` helpers stay revoked.

## UI truthfulness (§1/§2)
`studioStateChip` renders the server `execution_state` **verbatim** across all nine states (the
chip is fed `item.execution_state`; the comment states the browser never derives state — the old
PS-1A "never claim operating" posture is legitimately superseded for the studio-authoritative
families). `studioShouldBreakdown` shows the per-effect breakdown for `partially_live` /
`shadow_testing` / mixed rules. The RPC output shapes are consumed defensively and fail safe when a
field is absent (`effect_states` → `[]`, `emergency_pause` → null, preview error → publish blocked).

## Suite-strengthening legitimacy
The v55 §7 edit is a legitimate correction, not a weakening: a published `earn_bonus_points` rule
now asserts the truthful `shadow_testing` (was the placeholder `ready_for_activation`), while the
core invariant — a shadow-only rule never falsely reports `live`/`active` — is preserved (reworded,
not removed). The tripwire's single-writer and phase gates are unaffected; the writer-registry adds
four truthful browser.rpc bindings (all "moves NO customer value"); v21's forward scan now includes
v60 so its four new authenticated RPCs are allowlist-covered. Manifests coherent (db 90→91 ➜
actually 91→… items / canonical 93→94; hash matches).

## Builder-flagged items — judgment
- **v60 suite static-only at build time**: I ran it live on `frenly_freeze` → ALL PASS. Resolved.
- **`will_activate_*` gated on `rule.active`**: sound — an inactive rule never executes (both the
  executor and the plan loop filter on `active`), so publishing it activates no value and correctly
  requires no confirmation.

## To confirm on UAT during apply/deploy (belt-and-suspenders; not gate conditions)
1. Apply v60 over the real v59 chain and confirm the `get_programs_overview` /
   `get_program_rules_draft` replacements and the two engine replacements install cleanly, and that
   every existing published studio rule now reports a truthful state (spot-check a live checkout
   rule reads `live`, a shadow-only points rule reads `shadow_testing`).
2. On the live app, emergency-pause a real live checkout rule and confirm the next checkout stops
   discounting while the historical discount/fulfilment/budget rows are intact, then lift and
   confirm the discount resumes; confirm the paused chip shows actor/reason/time.
3. Confirm the publish dialog forces the typed "PUBLISH" confirmation when activating a live
   financial rule and skips it for an unbuilt-only draft.
