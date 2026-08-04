# V166 outstanding-version reconciliation

Date: 2026-08-05

## Objective

Reconcile the owner's 13-item August 4 inventory against the exact production
artifact, preserve every later production correction, integrate only genuinely
absent work, and publish one reviewed candidate.

Production baseline at reconciliation start:
`215e5a90b204d08f8e628851a1595dcc09264cae`.

## Reconciliation

| Version | Owner-listed tip | Current source status | V166 action |
| --- | --- | --- | --- |
| V117 | `2da2b198` (later branch tip `276ace0`) | V115/V116/V117 Supabase migrations exist in production source with byte-identical SHA-256 hashes; the reviewed branch is pushed. | Do not replay old application/docs; rerun focused boundary tests. |
| V142 | `271a3b5c` | Canonical V142 migration is byte-identical in production source; its two prerequisite commits are patch-equivalent in production. | Do not replay; rerun Connect/PayNow tests and retain provider verification limitation. |
| V143 | uncommitted at inventory time (later `d39b3c7`) | V148 forward-integrates the V143 schema/functions and current UI invokes the V143 RPCs; reviewed branch is pushed. | Do not add the obsolete standalone migration; rerun V143/V148 tests. |
| V145 | `51077de1` | The V144 consent change was reconciled by the later V145/V148 production lineage and recorded as deployed. | Do not replay superseded migration/application state. |
| V148 | `8531974c` | All four commits are patch-equivalent in production. | No code copy; rerun onboarding/admin tests. |
| V154 | `0dfa394d` | Direct ancestor of production. | No action beyond regression. |
| V156 | `5bb40910` | Direct ancestor of production. | No action beyond regression. |
| V157 | `65887b0f` | Direct ancestor of production. | No action beyond regression. |
| V158 | `eb04c120` | Direct ancestor of production. | No action beyond regression. |
| V161 | `5a2c170f` | Direct ancestor of production. | No action beyond regression. |
| V162 | `7baea871` | Direct ancestor of production. | No action beyond regression. |
| V163 | `e9d7aa91` | Direct ancestor of production. | No action beyond regression. |
| V165 | `3b7828f1` | One clean commit directly above the production baseline; not yet in production. | Carry the SwiftPM resolution, V165 regression and documentation into V166. |

## Safety decision

The V166 candidate adds no database migration, Edge Function, browser payment
writer, Stripe price, entitlement rule, merchant financial calculation,
commission rule, loyalty rule, credit/ledger/reversal rule, expense/P&L rule,
appointment rule, tenant policy or role authority. Production migration work is
therefore verification-only. Replaying a historical commit whose behavior is
already present is treated as a release defect, not as completion.

## Verification record

### Candidate corrections found during reconciliation

The live-based V164 application initially rendered the V155 reporting-scope
selector without invoking the first Dashboard data load. V166 now awaits scope
initialisation and invokes the existing loader once while preserving its route
guard. The focused V154 regression asserts this initial-load contract.

The current V154 section toggle and V150 segmented controls were also 40px and
38px high respectively. V166 raises both to the existing 44px touch-target
floor and adds focused source assertions. No business rule, authority or data
writer changed.

### Local gates

| Gate | Result |
| --- | --- |
| Focused V142/V145/V148/V150/V154/V156/V158/V161/V162/V163/V165 suite | PASS, 93/93 |
| Earlier focused V117/V130/V135/V164/V165 and migration checks | PASS, 47/47 |
| V142 production-component browser acceptance | PASS at desktop and 390px; refreshed evidence under `v142-connect-paynow-pos/` |
| V145 production-component browser acceptance | PASS at desktop and 390px for Dashboard, gated Dashboard, Reports, Daily, Customer 360, Expenses, P&L, inbox and launch-safety states; refreshed evidence under `v145-launch-freeze-browser/` |
| `EXPECTED_SUPABASE_PROJECT_REF=gadpooereceldfpfxsod npm run quality` | PASS |
| `npm run build` | PASS |
| `npm run mobile:store:validate` | PASS; signing and live association remain external store concerns |
| `npm run mobile:sync` | PASS |
| `xcodebuild -project ios/App/App.xcodeproj -scheme App -configuration Debug -sdk iphonesimulator -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.5' build` | PASS, `BUILD SUCCEEDED` |
| `git diff --check` | PASS |

The complete historical `npm test` gate is not green on the production V164
baseline. A detached baseline run produced 76 unique failures; the V166
candidate produced 65. Set comparison found zero candidate-only failures and
11 baseline failures resolved by the reconciled current-state tests and the
Dashboard correction. The remaining 65 failures are pre-existing historical
expectation drift and are not represented as passing or as production proof.
V166 release acceptance is therefore based on the named focused regression,
browser, quality, build, mobile and native gates above, plus independent Sol
review and production verification.

### Production release record

| Gate | Result |
| --- | --- |
| Reviewed feature commit | `e5520e768c8a5d1a3dde5949b552541c9d491613` on `codex/v166-outstanding-version-integration` |
| Main promotion | PR #18 merged as `6db41b0ce0540fc6c2a562df11bf750fd4355446` |
| Production deployment | GitHub deployment `5750972745`; Vercel deployment `pFyWVVq8svfc7fzp9b3bKXBMtaC6` |
| Production build identity | `/api/build` returned `6db41b0ce0540fc6c2a562df11bf750fd4355446` exactly |
| Canonical HTTP smoke | `/api/build`, `/`, `/business` and `/admin` returned HTTP 200 |
| Production browser smoke | Customer, business and admin entry routes rendered meaningful signed-out states at 1440x1000 and 390x844, exposed the exact build identity, had no horizontal overflow or obstructing overlay, and produced no browser error/console failure; visible primary controls met the 44px floor on mobile |
| Production migration ledger | Read-only `supabase migration list --linked` connected to `gadpooereceldfpfxsod` and confirmed the recent V155-V164 production ledger entries; V166 added and applied no migration |

The GitHub historical full-suite check remains red for the same disclosed
expectation drift measured before promotion. The candidate introduced zero new
full-suite failures and resolved 11 baseline failures, but the remaining 65
historical failures are still repository debt. They do not invalidate the
focused V166 release evidence and are not represented as complete.

### Independent review

Sol reviewed the exact staged candidate on 2026-08-05 and returned
**ACCEPTED**, with no P0, P1 or P2 findings. Sol independently reran a 60-test
V145/V150/V154/V165 subset, a 17-test V148/V158 subset, the production build,
and staged/unstaged diff checks. Sol confirmed that the Dashboard initial load
is required and non-duplicative, the V165 patch is native-shell-only, and no
schema, payment, price, entitlement, finance, loyalty, tenant or role-authority
change is staged.
