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
recurring unbuilt->studio). PS-1C, stored-value financial execution, and the
production rollout are NOT yet authorized. Do not edit the AUTHORIZED PHASES table
without a written owner instruction quoting the phase being authorized.

PS-1B authorizes the `## EXECUTOR ARTIFACTS` mapped to PS-1B below. STILL forbidden
and tripwired: `checkout_evaluations` (PS-1C), `sv_*` (PS-2), every EXECUTOR
LEDGER-GUARD SCOPE (all DEFERRED to PS-1C — PS-1B moves no customer value, so it
adds NO ledger scope), and `captured_messages` may NEVER hold a non-synthetic
recipient. The only sanctioned authority-lifecycle transitions are referral
legacy->shadow and recurring unbuilt->studio; execution_authority itself is never
mutated.

## AUTHORIZED PHASES

| phase  | authorized |
|--------|------------|
| PS-0   | yes        |
| PS-1A  | yes        |
| PS-1B  | yes        |
| PS-1C  | no         |
| PS-2   | no         |
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
| sv_lots                     | PS-2              |
| sv_lot_movements            | PS-2              |
| sv_plans                    | PS-2              |
| sv_plan_versions            | PS-2              |

## EXECUTOR LEDGER-GUARD SCOPES (must be absent until PS-1C)

The `app.loyalty_ledger_write_guard()` scope enum must NOT contain any of the
following studio-executor scopes until their phase is authorized (architecture §17,
finding S3). **PS-1B DELIBERATELY ADDS NONE**: it moves no customer value, so an
unused ledger scope would only weaken the guard's "every scope has a validated
route" story. All studio ledger scopes are therefore deferred to PS-1C, where a
live discount/tender route consumes them.

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
