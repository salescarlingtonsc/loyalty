# v117 effective Loyalty, branch scanner and gift-liability acceptance

Date: 2026-07-30
Environment: local Supabase and local static application
Release state: local candidate only; no production migration, production data
change, commit, push or deployment

## Scope ruling

Historical demo and test logins are excluded by the owner's 2026-07-30 ruling.
This acceptance continues with the forward-created synthetic `SPA-GLOW`
workspace, its current owner and Orchard front-desk access, and the current
`CUS-NEW` customer. It tests current login, role, module, branch and database
behavior; it does not use an old login as proof.

## Candidate identity

The source and canonical deployment migration are byte-identical:

- `db/migrations/20260730_nestly_v117_effective_loyalty_boundaries.sql`
- `supabase/migrations/20260730140000_nestly_v117_effective_loyalty_boundaries.sql`
- SHA-256:
  `737bbf97c7dcd83684d938480ce92c6b2b29a051d2a269cdd48fa441f1f65f20`

Regression evidence:

- `db/tests/v117_effective_loyalty_boundaries.sql`
  (`4110375e48e344b1323c7c5bf4493a8043e34c8b7f5e5f07bae3df919453c747`)
- `tests/customer-modules/v117-effective-loyalty-boundaries.test.mjs`
  (`d1fd2c257d6ed21cd70cada85caca0de9993db8d4da133c69b82f0f2cc7afb06`)
- `tests/browser/v117-effective-loyalty-mobile.html`
  (`631f358a943af494f1a2537a9caa4475b71bc0ef3e7c2b0aac56b492af727197`)
- `app/index.html`
  (`dd01a25bf1a8f019bbc4824d31b3727b3d5e848647ef5a6cfa7d2042bb3cfde2`)
- `docs/design/ps0/writer-registry.json`
  (`f095e5ea45cc49fbf68a47d9bef1351ef17ef5dc6cde6076141233f5d6e09043`)

## Database boundary evidence

All database acceptance commands used `psql -X -v ON_ERROR_STOP=1`, ran against
the local database, and ended in `ROLLBACK`.

Passing suites:

- `db/tests/v115_effective_module_projection.sql`
- `db/tests/v116_classic_reward_projection.sql`
- `db/tests/v117_effective_loyalty_boundaries.sql`

The v117 suite proves the following persistent boundaries:

1. With firm-level Loyalty disabled while the older sector array still contains
   Loyalty, customer capability is false, the customer action is absent,
   preparation is denied, and intent, points-ledger, loyalty-operation and
   credit counts do not change.
2. A branch-only Loyalty enable projects at that exact branch without enabling
   the comparison branch.
3. A direct scan at an assigned but Loyalty-disabled branch is denied and
   leaves the pending intent and every economic count unchanged.
4. A scan at the enabled Orchard branch completes exactly once. Replaying the
   same stable idempotency key creates no second economic effect.
5. The obsolete v89/v93 browser execution paths are not executable by an
   authenticated or anonymous client. The exact four-argument v117 scanner
   requires a branch and a stable idempotency key, and calls only the private
   canonical redemption writers after authorization. The distinct v117
   gift-card redemption boundary has six arguments.
6. Gift-card issuance is denied at a Giftcards-disabled branch and creates no
   new gift row.
7. A synthetic pre-existing SGD 50 gift liability remains visible with Till and
   Clients access after Giftcards is disabled. Applying SGD 10 transfers that
   liability to exactly one customer-credit `gift_card_load`, creates exactly
   one immutable keyed receipt, and leaves SGD 40 without reopening issuance.
   Replaying the same key returns the recorded result and creates no second
   liability reduction, credit row or receipt.
8. An unassigned front-desk identity receives no firm or branch module
   projection. Its two explicit branch assignments are restored before the
   enabled/disabled comparison is exercised.

The staff and customer projections are read from the same persistent local
relationship, points ledger, loyalty operation, credit and gift-value records.

## Browser acceptance

The current forward `CUS-NEW` identity and Orchard front desk were exercised
sequentially in the rendered local application so that each role used its own
fresh password session. No historical login was used as proof.

The exact customer -> staff -> customer chain was:

1. Customer opened **Glow Atelier Spa** with 1,080 points and one eligible
   **Redeem 1000 points** reward.
2. **Redeem now** created a pending QR. The dialog explicitly stated that no
   points are redeemed until the business scans and confirms it; the visible
   balance remained 1,080.
3. Orchard front desk signed in, opened Quick Earn -> **Scan customer QR**,
   pasted the freshly decoded QR content through the documented camera
   fallback, and received a server receipt for Mei Lin Fresh, 1,000 points
   spent, SGD 10 store credit and operation
   `d9fba096-9e96-4aed-8dce-c4ecc681d2f7`.
4. The customer signed in again and re-opened the programme. The balance was
   80, the reward changed to **More points needed**, and History showed the
   newest completed **Points redeemed** event with `-1000 points redeemed`.
5. The completed customer programme was rendered again with an explicit
   390 x 844 CSS-pixel viewport override. The first viewport visibly shows the
   compact 80-point balance. A second 390 x 844 viewport after ordinary
   vertical scrolling visibly shows **More points needed**, opened History and
   the newest completed `-1000 points redeemed` event. Both measurements
   reported `innerWidth = clientWidth = scrollWidth = 390`, `scrollX = 0`, so
   neither capture has horizontal overflow. The override was reset after
   capture.

The same operation was verified read-only in local Postgres:

- intent `c4ce6613-db60-42d5-81cd-26db7143cccf` is `completed`;
- canonical operation
  `d9fba096-9e96-4aed-8dce-c4ecc681d2f7` is `completed`;
- idempotency key is
  `v117:c4ce6613-db60-42d5-81cd-26db7143cccf`;
- result is exactly `{"credit_cents":1000,"points_spent":1000}`.

Artifacts:

- `docs/qa/evidence/v117-customer-pending-desktop.jpg`
  (`621c6eb2928ecc201b950ecdee144347ebbad0ecb687e7e696bac542132a9491`)
- `docs/qa/evidence/v117-staff-completed-desktop.jpg`
  (`20b8438ebba90805401aa1b3e13687df26442d41f3471e6eded716356b4e5073`)
- `docs/qa/evidence/v117-customer-completed-desktop.jpg`
  (`08f3a2eaa2782d818ab860271193fb4fad693d1ed87c2ae9ce087ab677599f6f`)
- `docs/qa/evidence/v117-customer-completed-mobile-390-top.jpg`
  (`8dc55091dbe8fa39aa25948aeb769dfc325617be5f686f8d38f34c4b10afe671`;
  true 390 x 844 viewport; compact 80-point balance)
- `docs/qa/evidence/v117-customer-completed-mobile-390-history.jpg`
  (`9d20d6f6ce2c0b188f269bcfca71d98883feda2668d0708cd410a9007d93a1c2`;
  true 390 x 844 viewport; ineligible reward and newest completed
  `-1000 points redeemed` History event)

## Automated repository gate

Command:

`EXPECTED_SUPABASE_PROJECT_REF=gadpooereceldfpfxsod npm run validate`

Result:

- quality baseline: pass;
- runtime configuration: pass;
- source migration manifest: pass;
- canonical migration chain: pass;
- Node regression suite: 1,284 passed, 0 failed;
- static build validation: pass.

The full `npm test` run independently reports 1,284 passed and 0 failed.
`git diff --check` passes.

## Evidence limits and release authority

This is local database and browser proof for the named forward fixture. It does
not prove provider-side OTP accounting, native iPhone passkeys, a production
migration, production data or production smoke.

The affected rows remain `VERIFIED_DATABASE`, not `CLOSED`: this file now
contains current desktop/mobile browser and database synchronization proof, but
independent Sol review is still required and production proof does not exist.
Any production migration, commit, push or deployment remains prohibited until
Sol accepts this exact candidate and the owner subsequently gives the
applicable phase release approval.
