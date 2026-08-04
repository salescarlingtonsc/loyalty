# V143 effective reward and tier boundaries

## Candidate

- Branch: `codex/v143-effective-reward-tier-boundaries`
- Base: `c22eb21`
- `app/index.html`: `fb05bfeb2fbf9aed73c2cd65dc8058b9c1de05efbf3243e4af6b76431be94343`
- Source/deployment migration: `bf5492b7430dcb8f2013b197048e6fa93757b0de4b1524e064176ceb21cf943d`
- SQL acceptance: `19bbbf0a2c6094b87e86af0d1e511b85e90e5aa40fe75a2da67eed539e664ab8`
- Two-session concurrency harness: `3d7591ee6c60ca3331665f2841ba3a4e12d1c81a346a378102fb8c00c8b62c27`
- Loyalty authoring regression: `9cd51693793251f3895979165d05434bf31bc65ded1f8b9dd87f4539f2af46dd`
- Browser fixture: `128124180d5f9d3f2346e1420a0193fadda8a0395c3dcf666e49644c2000c8c1`

No commit, push, merge, deployment, production migration, production data write, or release action was performed.

## Automated evidence

`EXPECTED_SUPABASE_PROJECT_REF=gadpooereceldfpfxsod npm run validate`

- Static quality, runtime config, migration manifest, canonical materialization, and build passed.
- Node test result: 1,442 passed, 0 failed.
- Focused V143 reward/tier integration result: 13 passed, 0 failed.

The repository rehearsal bootstrap was applied to a fresh disposable PostgreSQL 17 database, followed by all 175 manifest-ordered migrations and `db/tests/v143_effective_reward_tier_boundaries.sql` with `ON_ERROR_STOP=1`. The suite returned `ROLLBACK`; post-suite counts were `businesses=0` and `auth_users=0`. `db/tests/v143_tier_defaults_concurrency.sh` then ran two genuine sessions with different operation keys: one transaction created the unpublished Member/Plus/VIP rows, the waiter returned `existing_tiers`, exactly three draft rows and two immutable operation receipts remained, and no tier was published. The disposable database was removed.

The SQL suite proves owner-only optimistic draft writes, persisted publication windows and multiline tier benefits, outsider denial, invalid-window denial, future exclusion, exact-end exclusion, current-tier selection, customer benefit projection, disabled-module denial, one atomic recommended-tier operation, byte-equivalent lost-response replay, changed-input conflict, fresh-key no-duplication, and exact later-draft boundary cloning. It found transaction-start clock drift during implementation; v143 now evaluates eligibility with `statement_timestamp()`.

## Browser evidence

`tests/browser/verify-v143-effective-loyalty-boundaries.mjs` passed against a deterministic fixture generated from the production stylesheet and exact v143 boundary, loyalty-authoring, idempotency-key, and recommended-tier RPC client helpers. Its embedded production source hash is `ef81be2118a59efd0959b59026df9b1512b49141f177e784d973e1b5253930b3`.

Verified at 1440px and 390px:

- Owner: all active products plus Custom reward; selected SGD 88 selling price and SGD 26 company cost; editable customer reward name; SGD 26 budget at SGD 0.010 per point producing 2,600 points; Member/Plus/VIP draft defaults with an explicit no-publication result; a simulated response loss after server commit followed by the same visible retry using the exact same operation key and rendering exactly three tiers; reward shortcut and multiline custom tier benefits; live, scheduled, ended, and paused reward/tier inventory; editable Kuala Lumpur datetime controls.
- Staff: current reward only; read-only programme notice; unavailable QR action disabled.
- Customer: one current Redeem action; future `Available soon`; ended `Offer ended`; current tier only; every current tier benefit rendered separately.
- No horizontal overflow or console errors.
- Empty, disabled, and retry states render without overflow.

Artifacts are under `docs/qa/evidence/v143-effective-loyalty-boundaries/` for owner, staff, and customer desktop/mobile frames.

## Governance

Status is `VERIFIED_DATABASE`, not `CLOSED`. This evidence was produced while acting as the builder after the prior rejection. A fresh independent Sol review must inspect this exact candidate and return `ACCEPTED` before the owner can consider any scoped release approval.
