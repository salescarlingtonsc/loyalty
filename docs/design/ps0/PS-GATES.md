# Program Studio — phase authorization gates (machine-readable marker)

This file is the **single source of truth** for which Program Studio phases are
authorized to land **financial-execution schema and executor scopes** in the
production migration set. The static guard
`tests/program-studio/ps0-no-executor.test.mjs` reads this file and FAILS the moment
executor schema for an *un-authorized* phase appears in `supabase/migrations/` or
`db/migrations/`. Landing that schema therefore requires flipping the phase to
`authorized: yes` here in the same change — a deliberate, reviewed, auditable act.

Owner approval of record (2026-07-24, `PROGRAM_STUDIO_ARCHITECTURE.md` header +
PS-1A/PS-1B authorization): **PS-0, PS-1A and PS-1B are approved.** PS-1A =
authoring/projection/validation (no executor). PS-1B = the event envelope,
non-checkout entitlement execution (PROMISES only — no customer-value movement),
the NEW delivery-state outbox with a synthetic-only capture provider, the
fulfilment registry + budgets, and the referral shadow (referral legacy->shadow;
recurring unbuilt->studio).

Owner approval of record (2026-07-24, PS-1C authorization): **PS-1C is approved** —
ONE authoritative server-owned checkout kernel: the `checkout_evaluations`
evaluation token, atomic revalidation, the synchronous apply of Studio
apply_discount_pct / apply_discount_amount effects (the ONLY live discount path;
the executor keeps shadow-logging them), per-effect discount provenance
(`checkout_discount_lines`), budget commit/release on the v56 counters, and the
exact compensating reversal. PS-1C moves discount value (it reduces
sales.amount_cents) but writes NO credit/points ledger — the ledger write-guard is
untouched and no studio ledger scope is added. Stored-value financial execution
(PS-2+) and the production rollout are NOT yet authorized. Do not edit the
AUTHORIZED PHASES table without a written owner instruction quoting the phase being
authorized.

PS-1B/PS-1C authorize the `## EXECUTOR ARTIFACTS` mapped to them below. STILL
forbidden and tripwired: `sv_*` (PS-2); the `sv_spend` / `sv_refund` guard scopes
(PS-2); and `captured_messages` may NEVER hold a non-synthetic recipient. The
sanctioned authority-lifecycle transitions are referral legacy->shadow, recurring
unbuilt->studio, and (PS-1C) checkout unbuilt->studio; execution_authority itself is
never mutated. The kernel finaliser (`record_cart_sale` WITH an evaluation token) is
the ONLY writer of `checkout_discount_lines`.

PS-1C.2 (v60, truthfulness + control increment under the standing PS-1C authorization —
no new phase, no new financial-execution engine): the studio-rule execution state is now
SERVER-DERIVED from the effect's real execution engine. Because the checkout and recurring
families genuinely execute since PS-1C, a published studio rule may now truthfully read
**live / partially_live / shadow_testing / ready_for_activation / paused / retired** (the
PS-1A "NEVER claim a studio rule is operating" posture is SUPERSEDED for the studio-
authoritative families ONLY — the state is the server's `execution_state`, never a browser-
computed label). PS-1C.2 also adds the NON-executor control table
`public.studio_rule_emergency_pauses` (an owner-only, write-once/lift-once pause that stops
a live rule from producing NEW effects inside `app.ps1c_plan_checkout` and
`app.ps1b_execute_event` while deleting NO historical value row). It is a control surface,
not a financial-execution artifact, so it is deliberately NOT in the `## EXECUTOR ARTIFACTS`
table below; it moves no value and adds no ledger/guard scope.

PS-2A (v61, stored-value FOUNDATION under a new owner authorization 2026-07-24, per
`docs/design/ps2/PS2A_STORED_VALUE_CONTRACT.md` and the frozen
`docs/design/ps0/STORED_VALUE_CONTRACT.md`): PS-2 is flipped to `yes` for the INCREMENT-A
FOUNDATION ONLY — sv_accounts / sv_plans / sv_plan_versions / immutable sv_lots /
append-only sv_lot_movements authority / the sv_operations idempotency envelope /
derived-balance functions / the dedicated `sv_authority` table shipped at 'unbuilt' for
every tenant, plus the owner-only mint RPCs `sv_topup` / `sv_grant` and the read RPC
`get_sv_account`. NO stored value is spendable and NO customer value moves: `sv_authority`
never reaches 'live' (no function can set 'live' or 'ready_for_cutover', and its guard
rejects those transitions unconditionally), so `get_sv_account.spendable` is always false.
There is NO spend / redeem / reserve / reverse / refund / expire path (Increments B/C/D), NO
cutover, NO real communications, and NO UI in Increment A. The checkout kernel is unmodified.
The tripwire (`tests/program-studio/ps0-no-executor.test.mjs`) is re-scoped, not deleted:
`sv_spend_allocation` and `refund_sv_operation` stay forbidden (Increment C, not built), and
two new assertions forbid any function setting `sv_authority` to live/ready_for_cutover and
any sv table carrying a mutable `balance`/`balance_cents` column.

PS-2A Increment B (v62, shadow operations + reconciliation under the same PS-2 authorization —
no new phase, no spendable value): adds the append-only shadow log `sv_shadow_evaluations`
(a PROPOSED/would-be movement plan, computed without asserting authority and writing ZERO value
rows), the reconciliation evidence tables `sv_reconciliation_snapshots` /
`sv_reconciliation_discrepancies`, and the owner-only RPCs `set_sv_authority_state`
(safe-subset transitions only — a hard CHECK forbids naming `live`/`ready_for_cutover`, 22023),
`run_sv_reconciliation` (reads `gift_cards` READ-ONLY — never INSERT/UPDATE/DELETEs a gift-card
row — writes only evidence, auto-corrects nothing, tolerance 0, and drives
`reconciliation_blocked` on any discrepancy) and `get_sv_reconciliation`. `get_sv_account` gains
`shadow_testing` + a `disclaimer` field so the future UI never presents shadow value as
spendable. Still NO spend/refund path (`sv_spend_allocation` / `refund_sv_operation` stay
forbidden, Increment C), NO cutover, NO customer value movement, NO real comms, NO UI. The
tripwire adds an assertion that `run_sv_reconciliation` contains no DML against `gift_cards`.

PS-2A Increment C (v63, redemption/spend/reverse/refund/expiry mechanics under the same PS-2
authorization — still no new phase, no cutover, no spendable value): builds the COMPLETE
redemption machinery and its exact PS-0 §3–§6 arithmetic, but every value-moving path is
HARD-GATED so it can only ever run when `sv_authority.state = 'live'`, which is UNREACHABLE in
PS-2A. Adds the append-only hold ledger `sv_reservations`; the PURE (authority-free, no-DML)
planners `app.sv_allocate_spend` (aggregate-proportional cross-op FEFO) / `app.sv_plan_refund`
(SF2 per-op refund) / `app.sv_checkout_quote` (inert shadow tender quote); and the owner-only,
authority=live-gated RPCs `sv_reserve` / `sv_release` / `sv_spend` / `sv_reverse_spend` /
`refund_sv_operation` / `sv_expire_due`. `app.sv_available_balance` now nets active holds. The
spend/refund names that were forbidden in Increment B (`sv_spend_allocation` /
`refund_sv_operation`) are now BUILT and removed from the tripwire's forbidden set; in their
place the tripwire ADDS an assertion that no value RPC lacks the `authority='live'`
(`sv_not_live`) gate, plus an assertion that the PS-1C checkout kernel (`record_cart_sale` /
`ps1c_plan_checkout` / `evaluate_checkout`) is byte-UNCHANGED by every PS-2 increment. Still NO
cutover, NO customer value movement (default tenant is `unbuilt` → all value RPCs refuse), NO
real comms, NO UI. Tested via the pure planners directly + the gated RPCs under a rolled-back
`authority='live'` shim (trigger-disable inside BEGIN/ROLLBACK — never in a migration, never
persisted).

PS-2A Increment D (v64, pause/kill controls + cutover PREVIEW under the same PS-2 authorization —
still no new phase, no cutover action, no spendable value, no real comms; the first stored-value
UI lands in app/index.html): adds the DEDICATED append-only, write-once pause table
`sv_pauses` (scope `all`/`earn`/`redeem`, one active per (business,asset,scope)), distinct from
the rule pause `studio_rule_emergency_pauses`; the owner-only audited RPCs `sv_pause` /
`sv_lift_pause` (idempotent, no implicit lift); and the gate helper `app.sv_pause_active`. It gives
the pause TEETH by CREATE OR REPLACE-ing the Increment-A/C value RPCs to add ONLY a second,
independent pause gate (the v63 `sv_not_live` gate stays first): an `all`/`earn` pause blocks
`sv_topup`/`sv_grant`/`refund_sv_operation`; an `all`/`redeem` pause blocks
`sv_spend`/`sv_reserve`/`sv_reverse_spend`; an `all` pause alone blocks `sv_expire_due`. Pinned
policy (contract §8): an `earn` pause does NOT block spend (`sv_release` is likewise not gated — it
returns held value, the redeem family's undo). Adds owner reads `get_sv_authority_overview`
(`can_cutover` HARDCODED false) and `preview_sv_cutover` (`ready` HARDCODED false, enumerating the
real blockers). NO function performs a cutover; `sv_authority` is only READ (never transitioned).
The tripwire keeps forbidding a real cutover function + the live-setter / mutable-balance-column /
gift_cards-read-only assertions, and ADDS: an sv pause is lifted ONLY by `sv_lift_pause` (no
implicit lift by config publish), and `can_cutover` / `ready` are false. Tested via the pure gate
helper + the gated RPCs under the rolled-back `authority='live'` shim.

## AUTHORIZED PHASES

| phase  | authorized |
|--------|------------|
| PS-0   | yes        |
| PS-1A  | yes        |
| PS-1B  | yes        |
| PS-1C  | yes        |
| PS-2   | yes        |
| PS-3   | no         |
| PS-4   | no         |
| PS-5   | no         |

## AUTHORING ARTIFACTS (table / identifier → introducing phase)

These are PS-1A authoring/projection/validation surfaces. They move NO customer
value and contain NO executor. They MAY land once PS-1A is `authorized: yes`.

| artifact                | introducing_phase |
|-------------------------|-------------------|
| program_rules           | PS-1A             |
| program_rules_compiled  | PS-1A             |
| benefit_registry        | PS-1A             |
| rule_schema_versions    | PS-1A             |
| rule_condition_allowlist| PS-1A             |
| rule_effect_allowlist   | PS-1A             |

## EXECUTOR ARTIFACTS (table / identifier → introducing phase)

Each artifact below is a Program-Studio financial-EXECUTION surface that must NOT
exist in the migration set until its introducing phase is `authorized: yes` above.
The introducing phase follows §3 / §17 of the architecture. The PS-1A authoring
artifacts are NOT in this table (they are execution-free) — see `## AUTHORING
ARTIFACTS`. Everything below is PS-1B or later and stays forbidden while PS-1A is
the highest authorized phase.

| artifact                    | introducing_phase |
|-----------------------------|-------------------|
| domain_events               | PS-1B             |
| rule_effect_log             | PS-1B             |
| event_outbox                | PS-1B             |
| benefit_fulfilments         | PS-1B             |
| budget_periods              | PS-1B             |
| budget_reservations         | PS-1B             |
| program_entitlements        | PS-1B             |
| program_entitlement_operations | PS-1B          |
| benefit_shadow_evaluations  | PS-1B             |
| captured_messages           | PS-1B             |
| domain_event_execution      | PS-1B             |
| checkout_evaluations        | PS-1C             |
| checkout_evaluation_operations | PS-1C          |
| checkout_discount_lines     | PS-1C             |
| budget_commitment_releases  | PS-1C             |
| sv_lots                     | PS-2              |
| sv_lot_movements            | PS-2              |
| sv_plans                    | PS-2              |
| sv_plan_versions            | PS-2              |
| sv_accounts                 | PS-2              |
| sv_operations               | PS-2              |
| sv_authority                | PS-2              |
| sv_shadow_evaluations       | PS-2              |
| sv_reconciliation_snapshots | PS-2              |
| sv_reconciliation_discrepancies | PS-2          |
| sv_reservations             | PS-2              |
| sv_pauses                   | PS-2              |

## EXECUTOR LEDGER-GUARD SCOPES (kept out of the guard through PS-1C)

The `app.loyalty_ledger_write_guard()` scope enum must NOT contain any of the
following studio-executor scopes until their phase is authorized (architecture §17,
finding S3). **PS-1B and PS-1C DELIBERATELY ADD NONE**: PS-1B moves no customer
value, and PS-1C moves discount value by *reducing `sales.amount_cents`* (so points/
retention/referral earn on the discounted total) — it writes NO `credit_ledger` /
`points_ledger` row, so it needs no studio ledger scope and the write-guard stays
untouched. `sv_spend` / `sv_refund` remain forbidden until PS-2 introduces a real
stored-value tender route that consumes them. (Because PS-1C is authorized, the
`studio_executor` / `studio_discount` rows below no longer gate anything; they are
retained as documentation of the never-added scopes.)

| scope           | introducing_phase |
|-----------------|-------------------|
| studio_executor | PS-1C             |
| studio_discount | PS-1C             |
| sv_spend        | PS-2              |
| sv_refund       | PS-2              |

## Change protocol

1. An owner writes the authorization for a specific phase (quoting the phase id).
2. The implementer flips that phase to `authorized: yes` in AUTHORIZED PHASES **in
   the same commit** that lands the phase's executor schema.
3. The static guard then permits exactly that phase's artifacts and no others.

Nothing in this file authorizes moving customer value. It authorizes *schema landing*
under the standing release gate; production apply still requires the owner's
`RELEASE APPROVED` phrase per `CLAUDE.md`.
