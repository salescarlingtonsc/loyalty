# Program Studio — phase authorization gates (machine-readable marker)

This file is the **single source of truth** for which Program Studio phases are
authorized to land **financial-execution schema and executor scopes** in the
production migration set. The static guard
`tests/program-studio/ps0-no-executor.test.mjs` reads this file and FAILS the moment
executor schema for an *un-authorized* phase appears in `supabase/migrations/` or
`db/migrations/`. Landing that schema therefore requires flipping the phase to
`authorized: yes` here in the same change — a deliberate, reviewed, auditable act.

Owner approval of record (2026-07-23, `PROGRAM_STUDIO_ARCHITECTURE.md` header):
**PS-0 is approved. PS-1A / PS-1B / PS-1C, stored-value financial execution, and the
production rollout are NOT yet authorized.** Do not edit the AUTHORIZED PHASES table
without a written owner instruction quoting the phase being authorized.

## AUTHORIZED PHASES

| phase  | authorized |
|--------|------------|
| PS-0   | yes        |
| PS-1A  | no         |
| PS-1B  | no         |
| PS-1C  | no         |
| PS-2   | no         |
| PS-3   | no         |
| PS-4   | no         |
| PS-5   | no         |

## EXECUTOR ARTIFACTS (table / identifier → introducing phase)

Each artifact below is a Program-Studio financial-execution surface that must NOT
exist in the migration set until its introducing phase is `authorized: yes` above.
The introducing phase follows §3 / §17 of the architecture.

| artifact              | introducing_phase |
|-----------------------|-------------------|
| program_rules         | PS-1A             |
| program_rules_compiled| PS-1A             |
| benefit_registry      | PS-1A             |
| domain_events         | PS-1B             |
| rule_effect_log       | PS-1B             |
| event_outbox          | PS-1B             |
| benefit_fulfilments   | PS-1B             |
| budget_periods        | PS-1B             |
| program_entitlements  | PS-1B             |
| checkout_evaluations  | PS-1C             |
| sv_lots               | PS-2              |
| sv_lot_movements      | PS-2              |
| sv_plans              | PS-2              |
| sv_plan_versions      | PS-2              |

## EXECUTOR LEDGER-GUARD SCOPES (must be absent until PS-1B/1C)

The `app.loyalty_ledger_write_guard()` scope enum must NOT contain any of the
following studio-executor scopes until PS-1B/PS-1C is authorized (architecture §17,
finding S3):

| scope           | introducing_phase |
|-----------------|-------------------|
| studio_executor | PS-1B             |
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
