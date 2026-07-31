# v116 forward identity, module and redemption acceptance

Date: 2026-07-30
Environment: local Supabase and local static application
Release state: local candidate only; no production migration or data change

## Scope ruling

Historical demo and test sign-ins are excluded. This acceptance uses only the
forward-created synthetic `SPA-GLOW` tenant, its current owner/front-desk
identities, and the current `CUS-NEW` customer. No historical login is accepted
as proof.

## Effective module evidence

`Glow Atelier Spa` keeps the older broad `businesses.enabled_modules` array only
as compatibility input. Current platform overrides explicitly set `giftcards`
and `inventory` to `disabled`.

Authenticated `get_my_modules_at_v115` results for Orchard Road were:

- owner: 18 effective modules, with neither Gift cards nor Inventory;
- front desk: Appointments, Clients (read), Loyalty (write), Sales (write),
  Services (read), and Till (write);
- both responses identify the selected Orchard Road branch and the same current
  business;
- the resolver calls were wrapped in a transaction and rolled back.

The browser reads this effective result before rendering navigation or Quick
Earn. Direct-route and write denials are exercised by the v115 regression and
database suites.

## Forward redemption and synchronization evidence

The current linked customer started the exercised redemption sequence with
1,280 points. A realistic SGD 110 Glow Facial sale added 1,100 points. Two
distinct classic 1,000-point rewards were then prepared by the customer and
confirmed by the Orchard front desk.

Final persistent local state:

- 380 customer points;
- exactly two `-1000` points-ledger entries;
- exactly two completed canonical `loyalty_operations` redemption operations,
  with distinct idempotency keys;
- SGD 20 total customer credit;
- two completed redemption intents and one deliberately expired intent;
- replaying an already completed QR displayed **Redemption already confirmed**
  and changed none of those counts.

The customer observed the pending state, merchant completion, refreshed
balance, and both History entries. The staff receipt scanner supplied the
selected Orchard branch. A missing branch now fails before the RPC.

## Browser artifacts

- `docs/qa/evidence/v116-forward-customer-desktop.png`
- `docs/qa/evidence/v116-forward-customer-mobile-390.png`
- `docs/qa/evidence/v116-forward-staff-redemption-desktop.png`
- `docs/qa/evidence/v116-forward-staff-redemption-mobile-390.png`

The 390px viewport checks show zero document overflow, the staff rail hidden,
a 354px frontline card, four 88px customer navigation tracks, and the
branch-scoped redemption workflow remaining usable.

## Automated gate

Command:

`EXPECTED_SUPABASE_PROJECT_REF=gadpooereceldfpfxsod npm run validate`

Result:

- quality baseline: pass;
- runtime configuration: pass;
- source migration manifest: pass;
- canonical migration chain: pass;
- Node regression suite: 1,276 passed, 0 failed;
- static build validation: pass.

Focused database suites:

- `db/tests/v115_effective_module_projection.sql`: pass and rollback;
- `db/tests/v116_classic_reward_projection.sql`: pass and rollback.

Focused application suites include:

- `tests/customer-modules/v115-effective-module-projection.test.mjs`;
- `tests/customer-modules/v93-branch-scoped-redemption.test.mjs`;
- `tests/customer-wallet/v116-classic-reward-projection.test.mjs`.

## Independent Sol verdict

Sol rejected closure on 2026-07-30. No historical login evidence was
considered. The forward positive path and its economic rows were independently
confirmed, but the candidate failed the required negative matrix:

- v93 checked Loyalty at firm scope and could be called directly at an
  assigned branch whose Loyalty override was disabled;
- customer capability/action/preparation read the raw sector module array and
  ignored a v94 firm-level Loyalty disable;
- null-branch route entry could hide a branch-only enable, while a branchless
  gift-card writer could bypass a branch disable;
- the claimed existing $50 gift-liability acceptance had no matching fixture;
- browser captures and the evidence index did not prove every narrative claim,
  and the local intent set contained an extra expired-but-still-pending row.

The affected rows are therefore reopened as `REPRODUCED`. This document is
historical reproduction evidence, not release acceptance.

## Remaining authority

A corrected hash-pinned local candidate, complete database/browser evidence,
and a new independent Sol review are required. Production migration,
deployment, data changes and production smoke remain separately release-gated.
