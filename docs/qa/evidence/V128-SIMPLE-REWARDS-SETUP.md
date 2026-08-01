# V128 simple rewards setup acceptance

Date: 2026-08-01
Branch: `codex/v128-simple-rewards-setup`
Requirement: `REWARD-SETUP-001`
Production-component source hash: `438a10a11c3cac1e7f8c5ac396a38c8a378449e181faaaf6ce9a08317ce4e71e`

## Owner complaint reproduced

The supplied screenshot shows four equal-weight Trigger/Who/Reward/Result
cards, separate edit actions, the rewards journey and a large profitability
empty state without one obvious starting action. The newer V127 source still
had the same hierarchy plus a second Guided setup disclosure. The red-first
V128 regression failed 6/6 before implementation.

## Accepted local behavior

- The writable owner sees exactly one dominant **Set up rewards
  automatically** action.
- The complete published **Rewards overview** is immediately below the hero
  and before **More reward settings**.
- Journey anatomy, profitability, optional growth tools and technical editors
  begin collapsed under that secondary disclosure.
- The setup action opens an accessible three-step dialog: goal, the exact
  governed business inputs Nestly will use, and a draft-only safety review.
- The popup does not mislabel the currently published earning rule as the new
  recommendation and explicitly says product costs are not used by automatic
  setup; profitability remains an owner review step under More reward settings.
- Opening, Escape and Cancel perform zero recommendation writes. Escape returns
  focus to the initiating action.
- Confirmation calls `generate_retention_recommendation` once, creates an
  editable draft and invokes no publication writer.
- Governed `facial` and `massage` sector keys select `points_tiers`; the
  business-row lock serializes stale tabs, and a second key resumes the current
  editable draft without another run or draft.
- The RPC requires effective owner Loyalty-write access before both fresh and
  existing-draft paths; read-only, disabled, cross-tenant and anonymous calls
  are rejected without mutation or draft disclosure.
- A failed/lost response keeps the dialog retryable and reuses the same
  `p_idempotency_key`.
- An existing draft shows **Open editable draft**, performs zero recommendation
  writes and is not replaced.
- A read-only manager sees the published overview and receives neither the
  automatic setup action nor any reward edit control.
- The 390px bottom sheet has no horizontal overflow and every action retains a
  44px layout target.

## Evidence

- Red-first/static regression:
  `tests/business-ui/v128-simple-rewards-setup.test.mjs` — 8/8 passing.
- Existing reward-overview regression:
  `tests/business-ui/reward-overview-owner.test.mjs` — 6/6 passing.
- Production-component Chromium acceptance:
  `tests/browser/verify-reward-overview-owner.mjs` — PASS at 1440px and 390px,
  including cancel/zero-write, retry/same-key, existing-draft/zero-write,
  stale-tab resume, governed facial model, stable-record routing and read-only
  manager checks.
- Disposable database authority regression after the complete canonical chain:
  `db/tests/v128_simple_rewards_recommender.sql` — `NOTICE: V128 SIMPLE REWARDS
  RECOMMENDER SUITE PASS`; 167/167 migrations applied, then rollback left
  `businesses=0` and `auth_users=0`.
- Browser artifacts:
  - `reward-overview-owner-browser/owner-automatic-setup-popup-desktop-1440.png`
  - `reward-overview-owner-browser/owner-automatic-setup-mobile-390.png`
  - `reward-overview-owner-browser/owner-automatic-setup-draft-desktop-1440.png`
  - `reward-overview-owner-browser/manager-read-only-mobile-390.png`
- Complete gate with
  `EXPECTED_SUPABASE_PROJECT_REF=gadpooereceldfpfxsod npm run validate`:
  1,362/1,362 tests, quality/runtime/migration checks and static build pass.
- Shared production-style fixtures for V104 promotions and V105 administration
  were mechanically regenerated; the V104 Chromium metrics were recaptured and
  its visual fixture checks pass.

## Evidence limits

This is deterministic local production-component browser and disposable
database evidence. It does not prove an authenticated target database
before/after record, linked staff and customer projection after explicit
publication, or production behavior. No
production migration, data, secret or deployment was changed. Commit, push,
merge and deployment remain release-gated.

## Independent review

Sol independently accepted staged candidate
`10fb9a1871c926174e4a77460074301d235f9c29` with no remaining P0, P1 or P2
findings. The review recomputed the exact hash; reran focused tests plus
manifest/canonical checks; confirmed byte-identical migration mirrors and
browser provenance `438a10a…`; and reviewed owner desktop, 390px and read-only
manager visuals. The acceptance is limited to local browser and disposable
database evidence, not target or production proof.
