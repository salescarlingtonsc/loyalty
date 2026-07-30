# v117 effective Loyalty, branch scanner and gift-liability acceptance

Date: 2026-07-31
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
  (`7b868c2f6ec2b095da223fd84df80ac8aa3541da396596909a7a6161ecca30ff`)
- `docs/design/ps0/writer-registry.json`
  (`746b61d5cb425d3457c9d9a79a344a45f635141a13dd2203ba077459b74eb92b`)

## Database boundary evidence

The rehearsal database was created from exact `origin/main`
`2263702e5b1f5bf4c33533e875a46f4e45229fd0` in the disposable local Supabase
project `nestly-v117-pristine`. Its canonical v105 chain was applied first.
Only the source v115, v116 and v117 migrations from this candidate were then
applied, in order, using `psql -X -v ON_ERROR_STOP=1`. This proves that the
release migrations apply to the current production baseline without relying on
unreleased v106-v114 state.

All SQL acceptance suites used `psql -X -v ON_ERROR_STOP=1` against that exact
rehearsal database and ended in `ROLLBACK`. The v116 suite now explicitly
enables the `customer_wallet` feature in its disposable fixture instead of
depending on cumulative local state.

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
   fallback, and received a server receipt for Alicia Tan, 1,000 points
   spent, SGD 10 store credit and operation
   `85a3b55b-4fac-439e-8a91-6e91633b1b0e`.
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

- intent `d904a39e-f2db-416b-a4b5-fd9025bfd00e` is `completed`;
- canonical operation
  `85a3b55b-4fac-439e-8a91-6e91633b1b0e` is `completed`;
- idempotency key is
  `v117:d904a39e-f2db-416b-a4b5-fd9025bfd00e`;
- completion branch is the enabled Orchard branch
  `11700000-0000-4000-8000-000000000011`;
- result is exactly `{"credit_cents":1000,"points_spent":1000}`;
- the persistent points balance is exactly 80;
- exactly one `loyalty_earn` credit-ledger row adds SGD 10;
- the intent has exactly one `intent_created` and one `scan_completed` event.

The browser served the exact candidate `app/index.html` SHA listed above. Its
production Supabase origin was intercepted only at the browser transport layer
and fulfilled by the pristine local API, so the application bytes were not
rewritten. The customer, front-desk and business records were synthetic and
existed only in the disposable rehearsal database.

Artifacts:

- `docs/qa/evidence/v117-customer-pending-desktop.jpg`
  (`41526081dafca28e6dbe42d24cab43ddf7aa55a0fd50cd52fe1534123f97f013`)
- `docs/qa/evidence/v117-staff-completed-desktop.jpg`
  (`5f764c5148ccc8ebf3a6bc6bfd02016ada8efd4a36ec137716c9f9e6d02a07fc`)
- `docs/qa/evidence/v117-customer-completed-desktop.jpg`
  (`91d680bf77e6124b9fedbae4b42fca40729b4f7f54e47dfe314b5550a4c74fae`)
- `docs/qa/evidence/v117-customer-completed-mobile-390-top.jpg`
  (`d9a05e7b1847e2b63a584eb509f83b8d9877b0c35cdf5aca454fff199af079f4`;
  true 390 x 844 viewport; compact 80-point balance)
- `docs/qa/evidence/v117-customer-completed-mobile-390-history.jpg`
  (`e14f0dc4c5ac55e6366625fa25e3ca09cc06f39ae115a603896813d7533a00fc`;
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
- Node regression suite: 1,090 passed, 0 failed;
- static build validation: pass.

The full `npm test` run independently reports 1,090 passed and 0 failed.
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
