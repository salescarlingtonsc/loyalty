# V140 Grow draft authority label

Date: 2026-08-02
Issue: `GROW-AUTHORITY-LABEL-001`
Fixture: authenticated Cubbly owner production reproduction plus source-bound
`SPA-GLOW` owner/manager browser states.
Production-component source SHA-256:
`501f65ed9f290deab2cc36cfbff18910e4af834ed05fd70f0336ef1076055130`.

## Complaint and reproduced cause

The final V139 production walkthrough showed an editable owner draft with the
header pill **Read only**. The controls themselves were writable. The renderer
used one ternary that returned **Read only** whenever a draft already existed,
regardless of the owner's actual write authority.

The red-first V140 regression failed 0/4 before implementation because the
permission/draft state helper did not exist and the production renderer still
used the misleading ternary.

## Acceptance and evidence

- Authorized owner with an existing draft sees **Editable draft**, not **Read
  only**, and retains the exact editor.
- Authorized owner without a draft sees **Create recommended draft**.
- Manager/read-only role sees **Read only** for both draft states and receives
  no draft action.
- The source-bound Chromium suite passes the exact owner Earn route at desktop
  and the manager state at 390px with no horizontal overflow.
- Focused V138–V140 regression passes 20/20.
- Source-bound Chromium acceptance passes with the production-component hash
  above and refreshed evidence under
  `docs/qa/evidence/reward-overview-owner-browser/`.
  - `owner-editable-draft-authority-desktop-1440.png`
  - `manager-read-only-draft-authority-mobile-390.png`
- The complete release gate passes 1,438/1,438 tests, static quality, runtime
  configuration, migration-manifest/canonical checks and the production build.

## Release boundary

This patch changes display copy only. It does not publish a programme, mutate a
customer record, modify a production migration, or weaken a permission check.
Sol independently accepted the frozen candidate with P0/P1/P2 all zero. The
review reran 1,438/1,438 tests plus build, focused V138–V140 20/20, related
V41/V128 22/22 and source-bound Chromium; it confirmed no migration, data,
function, configuration, security or production change. Frozen reviewed
content-manifest digest:
`6f7e98c7bcc16a414934a2e9bf6fa74c4ef6b990d3b682727d5012def5688b75`.

No V140 commit, push, merge or production deployment is authorized by the
earlier V139 approval. A subsequent scoped owner approval remains required.
