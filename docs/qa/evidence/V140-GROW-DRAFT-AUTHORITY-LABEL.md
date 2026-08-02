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

The earlier V139 approval did not authorize a V140 commit, push, merge or
production deployment. The owner subsequently supplied the separate scoped
V140 approval recorded below.

## Production release evidence

The owner subsequently approved the scoped V140 release. Commit `e086a91` was
pushed, PR #15 was merged into `main` as `370c5bfcc3507765d87c4a7b3e96cfe75d67723c`,
and Vercel production deployment `dpl_8GDnyWe6UrhVbed3qF4gy7fENdMY` reached
**Ready** with `www.peekaa.asia` and the canonical Peekaa aliases attached.

Read-only production checks found:

- bare `peekaa.asia/business` returns HTTP 308 to canonical
  `https://www.peekaa.asia/business`;
- `/api/build` reports production commit `370c5bfcc350`;
- canonical HTML contains `loyaltyAuthorityActionV140` and **Editable draft**
  and no longer contains the old combined authority/draft ternary;
- authenticated Cubbly Earn renders one visible **Editable draft**, one enabled
  **Save draft**, one enabled **Review & publish**, and no visible Birthday
  sibling editor;
- the deployment log query returned no runtime errors.

The authenticated verification was deliberately non-mutating: no draft was
saved, no programme was published and no customer record was changed.
