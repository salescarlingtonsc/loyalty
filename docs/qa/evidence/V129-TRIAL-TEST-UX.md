# V129 trial and test workflow acceptance

Date: 2026-08-01
Branch: `codex/v129-trial-test`
Requirements: `CUSTPROFILE-001`, `CUSTINACTIVE-001`, `APPT-WHATSAPP-001`, `RECORDSALE-001`
Actual-renderer browser hash: `da0b0a3d1df50285a67c82a1431a3744f1fb4ce3c1340f5338c3edb0fd8d1c92`

## Reproduction and root cause

The live-main source reproduced all four complaints: gender appeared as an
optional selector, table column and “gender not set” profile suffix; the
customer loyalty card exposed engine-oriented controls before explaining the
customer's balance and next reward; the activity feed was named Timeline; the
Customers page had no trustworthy last-valid-visit projection; the same sale
workflow used the ambiguous Quick Earn name across several staff entry points;
and appointment detail had no WhatsApp action.

The inactivity feature could not be implemented safely as a client-only filter:
raw customer pages do not contain a reversal-aware visit fact, and filtering one
page would produce incorrect totals and pagination. V129 therefore adds one
bounded, tenant- and permission-authorised database reader.

## Accepted local behaviour

- Gender is absent from the ordinary add-customer, customer import, customer
  list, staff profile and dashboard demographic surfaces. Historical backend
  values are not deleted.
- **Rewards** first explains the balance, earn rule, next unlock and milestones
  in ordinary language. Audited owner correction begins collapsed.
- The unified profile feed is named **Sales history**.
- Customers offers All, 30+, 60+ and 90+ day filters. A valid visit is an
  original sale snapshot that counts as a visit, occurred by the server cutoff,
  and has not been reversed. This includes canonical SGD 0 package-session use
  and partially refunded visits; restoring a package session or fully reversing
  a sale removes that visit. Singapore calendar dates determine the inclusive
  threshold; Never visited is explicit and included.
- Staff-facing sale entry points say **Record sale** while `#/till`, permissions,
  atomic writers and analytics event keys remain stable.
- A valid Singapore mobile exposes **Message on WhatsApp** with a factual draft.
  The UI says staff must review and press Send in WhatsApp and that Nestly has
  not recorded sent/delivered status. Customer notes are omitted.

## Automated and database evidence

- Red-first regression: `tests/business-ui/v129-trial-test-ux.test.mjs` failed
  4/4 before implementation and passes 4/4 after it.
- Compatibility coverage includes the reporting-scale, v41, v47, v97, v122,
  C45 privacy, V123 module/button, canonical-order and writer-registry suites.
- `tests/browser/v129-trial-test-visual.test.mjs` proves the checked-in harness
  embeds and executes the current production `clientsPage`, `clientDetail`,
  appointment-detail and `tillPage` renderers plus the production Customer UI;
  it does not recreate their visible surfaces by hand.
- The V129 source and canonical migrations are byte-identical and included in
  both deterministic manifests.
- A fresh local PostgreSQL 17 database replayed all 168 canonical migrations.
  `db/tests/v129_trial_test_ux.sql` then passed through `ROLLBACK` for active,
  exact-30-, 60-, 90-day, never-visited, fully-reversed, canonical SGD 0 package,
  restored-package, partially-refunded and non-visit-sale customers; combined
  search; invalid 45-day/oversized-page input; cross-tenant access; and staff
  without Clients read. Final counts were `businesses=0`, `auth.users=0`.
- `EXPECTED_SUPABASE_PROJECT_REF=gadpooereceldfpfxsod npm run validate`
  passed quality, runtime configuration, both migration manifests, all
  1,367 Node tests and the static application build.

## Browser evidence

The browser-verification skill was used with agent-browser against the actual
production renderers with synthetic Supabase responses. At 1440px and 390px it
reported meaningful content, no framework overlay, no JavaScript errors and
body `scrollWidth === clientWidth`. The Customers table scrolls internally at
390px (`336px` client width, `445px` content width) instead of widening the page.
All visible actions/selectors measured 44px.

- The inclusive 30-day filter showed the exact-30, exact-60, exact-90 and Never
  rows. The 60-day filter showed three rows; the inclusive 90-day filter showed
  exact-90 and Never. The recent canonical package user appeared in All with a
  real last visit and appeared in none of the inactivity filters.
- Empty state, one failed load followed by successful **Try again**, read-only
  Clients access with no Add button, and denied Clients access were exercised.
- The actual profile renderer showed Mei Lin, ordinary-language Rewards and
  Sales history, kept owner correction collapsed, and showed no gender.
- The actual denied-role `tillPage` rendered **Record sale** and no write path.
- The actual appointment-detail renderer produced a `wa.me/6581234567` draft
  with the correct customer, business, service, 3 Aug 2026 2:00 pm Singapore
  time, Orchard branch, Olivia Tan and completed status, plus the explicit-send
  disclaimer.

Screenshots are under `docs/qa/evidence/v129-trial-test-browser/`:

- `customers-60-days-desktop-1440.png`
- `customer-profile-desktop-1440.png`
- `appointment-whatsapp-desktop-1440.png`
- `customers-90-days-mobile-390.png`
- `customer-profile-mobile-390.png`
- `appointment-whatsapp-mobile-390.png`

## Evidence limits

This is local automated, disposable-database and actual-production-renderer browser
evidence, not authenticated target or production proof. Automatic WhatsApp
delivery is not claimed: an approved WhatsApp Business provider/account,
sender, message templates, consent policy and delivery receipts are still
required. No production migration, data, secret or deployment was changed.

## Independent review status

Sol's first review correctly rejected the candidate because the original reader
excluded zero-value package visits and the first browser artifact was a
handcrafted facsimile. Both P1 findings are now corrected with the database and
actual-renderer evidence above.

Sol independently re-reviewed the corrected candidate on 2026-08-01 and
returned **ACCEPT** with no P0, P1, P2 or blocking P3 findings. The review
independently passed the complete 1,367-test gate and static build, an 88-test
compatibility/security/manifest set, the transactional V129 database suite,
and the actual-renderer browser evidence. It confirmed the source/deploy
migration SHA-256 as
`cf979f415fa2839074bafa99200ce5e8efe85d60a9a64c8f3b04717615223074`.
A synthetic 1,000-customer/5,000-sale scale check returned in approximately
4.35 ms unfiltered and 2.48 ms filtered after fixture setup.

This verdict makes V129 eligible for a subsequent scoped owner release
approval. It is not target or production proof, and no commit, push,
production migration or deployment was performed as part of the review.
