# Unified owner rewards overview acceptance

Date: 2026-08-01
Requirement: `REWARD-OVERVIEW-001`
Baseline commit: `f61cc7d9453f164781813aa58f5fe9d62173eb99`
Production-component source SHA-256: `0182cb17b13417c9a89de0165374554857fbf001c22cb3a1903aa32ad4b2a33e`

## Owner requirement and reproduced gap

The owner requires birthday, the published points/stamps programme, and every
configured reward in one view, with a click on a specific reward opening that
exact reward's editor.

The V122 implementation was reproduced as incomplete before this change:

- it showed only active catalogue milestone text and a birthday sentence;
- classic points earning/redemption was absent;
- milestone and birthday containers were not interactive;
- the only overview action targeted generic `rwAdd` rather than a stable reward
  ID;
- a draft reward could expose `reward_id` while the editor matched only `id`.

The red-first regression `tests/business-ui/reward-overview-owner.test.mjs`
failed all four tests against that predecessor.

## Implemented local behavior

- **Rewards overview** is rendered for any role with Loyalty read access.
- It shows the published earning model and rate, the classic points redemption
  promise when applicable, every active catalogue reward, paused/archived
  rewards in a labelled disclosure, and the configured or unconfigured
  birthday state.
- A classic programme does not falsely present leftover catalogue rows as
  customer-unlockable; those rows are labelled as not used by the current
  Simple points programme.
- Paused programmes, future reward windows and ended claim windows remain
  visible for owner review but are explicitly unavailable rather than phrased
  as something customers can currently earn or unlock.
- Owner edit cards carry the stable reward UUID. Draft and published payloads
  normalize `reward_id || id`, so duplicate customer-facing names cannot select
  the wrong record.
- Earning, classic redemption, birthday, Add reward, and catalogue clicks all
  use the protected draft-first Grow path. An exact reward absent from the
  current draft produces a specific warning instead of opening a different
  record.
- A manager with read access sees the same published truth as non-interactive
  articles with zero writer controls.
- Published birthday copy is loaded by `get_active_birthday_program`, now a
  tenant-scoped effective-Loyalty-read RPC. The private
  `birthday_program_versions` table and owner-only draft writer remain closed.
- The same RPC supplies an authoritative server `as_of` instant used to decide
  whether the programme and reward claim windows are current; a wrong owner
  device clock cannot make a future or ended reward appear available.
- Exact-reward routing keeps keyboard focus in the opened editor rather than
  moving it back to the containing Grow panel.
- Partial loyalty/reward/birthday reads show an explicit incomplete warning and
  Retry action rather than a false complete overview.

A reviewed local V127 migration replaces only that published reader contract.
It grants no table access, exposes no customer date of birth or entitlement,
and changes no production data, secret, provider setting, or draft writer.

## Automated evidence

Focused tests:

```text
node --test \
  tests/business-ui/reward-overview-owner.test.mjs \
  tests/business-ui/v122-owner-seven-workflows.test.mjs

13 tests passed, 0 failed
```

The pure regression covers:

- 10 points per SGD 1 and classic 1,000 points -> SGD 10;
- SGD 5 per café stamp and incremental 5/10-stamp milestones;
- duplicate display names with distinct UUIDs;
- paused programmes plus future and ended reward claim windows;
- archived rewards, missing birthday, read-only and recoverable states;
- stable-ID exact editor routing and draft-first setup.

Database authority regression:

```text
psql ... -f db/tests/v127_rewards_overview_birthday_reader.sql
NOTICE: V127 REWARDS OVERVIEW BIRTHDAY READER SUITE PASS
```

The rollback-only suite published synthetic **Birthday Glow** through the
existing owner draft path on a disposable local Supabase clone. It proved the
owner and a Loyalty-read manager receive the same published programme, while a
denied manager, cross-tenant owner and anonymous caller are rejected. Direct
table SELECT and manager draft access remain denied. The fixture rolled back;
the temporary database was removed.

Independent Sol review accepted exact source hash `0182cb17…` with no P0, P1,
or P2 findings. The review reran the focused 13/13 suite, regenerated the exact
browser fixture hash, and confirmed the server-time propagation, editor-focus
retention, migration mirror identity and scoped diff check.

Complete repository gate:

```text
EXPECTED_SUPABASE_PROJECT_REF=gadpooereceldfpfxsod npm run validate

quality, runtime configuration, migration manifests, canonical migration check,
1,354/1,354 Node tests, and static build passed on the isolated V127 branch.
```

## Real-browser evidence

Generator: `tests/browser/generate-reward-overview-owner-visual.mjs`
Verifier: `tests/browser/verify-reward-overview-owner.mjs`

The verifier executes the exact production `growOverviewSnapshot`, `growPage`,
`ownerRewardJourneyV122`, `growStatus`, and production CSS against a mocked
Supabase transport with synthetic `SPA-GLOW` records. Chromium passed:

- owner desktop at 1440px: duplicate **Signature reward** cards retained two
  UUIDs and clicking the second opened
  `22222222-2222-4222-8222-222222222222`, with focus retained in the reward
  name input;
- owner mobile at 390 x 844: `clientWidth === scrollWidth === 390`, every
  overview card was at least 44px tall, and Birthday Glow opened the birthday
  editor;
- manager mobile at 390 x 844: the overview remained visible, all cards were
  semantic `article` elements, edit-control count was zero, the production
  snapshot adapter made one birthday RPC call and made zero direct birthday
  table reads;
- every run had meaningful content and zero browser or captured window errors.

Artifacts:

- `reward-overview-owner-browser/owner-exact-reward-editor-desktop-1440.png`
- `reward-overview-owner-browser/owner-birthday-editor-mobile-390.png`
- `reward-overview-owner-browser/manager-read-only-mobile-390.png`

## Evidence boundary

The embedded Loyalty editor in this visual harness remains a deterministic
interaction stub; it proves that the production overview sends the exact UUID
and birthday action into the editor bridge, not an authenticated editor save.

This is `VERIFIED_BROWSER`, not `CLOSED` or production proof. Still required:

- an authenticated non-production owner save -> explicit publish -> refresh
  using the real Supabase draft RPCs;
- database before/after evidence for an exact catalogue reward UUID;
- linked-customer refresh proving only the published version is projected;
- save-conflict/lost-response and disabled-module authenticated acceptance;
- a later version-scoped owner release approval before commit, push, migration,
  or production deployment.
