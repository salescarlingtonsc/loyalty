# V123 module and button readiness audit

Date: 2026-07-31
Requirement: `READINESS-001`
Baseline: released V122 commit `31331e71640d3b25c63b3b85d7b23d9fda5e63a8`
Candidate branch: `codex/v123-module-button-readiness`

## Outcome

The repository-wide structural inventory and the focused changed-surface browser journeys pass.
V123 removes six concrete failure modes found during the audit: a hidden Inventory destination
advertised by Setup, an unrecoverable Setup loading state, a mouse-only staff table row, false
clipboard-success notices, non-atomic bundle creation, and stale report exports. The two report
surfaces and the Services bundle surface also fit the 390px outer viewport after the responsive
containment changes.

This remains `VERIFIED_LOCAL` for the owner’s all-module objective: it is browser and
disposable-local-database evidence for a bounded remediation set, not the required authenticated
target or production proof. It does not mean that every one of the repository's 269 literal
controls was exercised through every role and state. Production remained untouched.

## Reproduction before the fix

On the exact V122 baseline, the new readiness regression suite failed all six initial cases:

- Setup derived destinations from raw `enabled_modules`, exposed the hidden Inventory route, and
  could remain on `Loading…` after a rejected query.
- Staff performance used a clickable table row instead of a keyboard-operable link.
- browser clipboard calls announced success without awaiting the browser permission result.
- bundle creation issued separate bundle and item requests, permitting an orphan or partial bundle
  after timeout, double tap, or the second request failing.
- Daily Report and Profit & Loss retained an exportable prior response after scope changed.
- the focused report/service layouts could overflow a 390px outer viewport.

The initial independent Sol 5.6 review rejected release on those defects and required direct
regressions, atomic persistence, honest recovery states, and browser evidence before reconsidering
the phase.

## Implemented closure

- Setup now uses effective routed capability checks, exposes only reachable setup destinations,
  and replaces indefinite loading with a specific error and meaningful Retry.
- clipboard actions share one awaited helper; denial restores the button, announces the failure,
  and tells the user to select and copy manually.
- staff drill-down is an ordinary anchor, so focus plus Enter follows the same route as a click.
- bundle creation uses one authenticated `create_service_bundle_v123` security-definer RPC. The
  RPC validates same-tenant active services, serializes by a stable write-attempt key, creates the
  bundle, items, receipt and audit entry in one transaction, and returns the original result on an
  exact lost-response replay. Reusing the key with edited input is rejected.
- direct browser writes to `bundles` and `bundle_items` are retired. Their broad write policies and
  grants are removed; authenticated members retain bounded read policies.
- Daily Report and Profit & Loss use a latest-request gate, disable stale exports when date or
  branch changes, immediately restore Generate/Run for the new scope, keep export filenames
  scoped, and prevent late responses from replacing current state. Rejected summary, expense and
  monthly queries replace the loading state with a visible Retry. Every successful P&L export
  includes its date/branch scope and the four visible summary KPIs, even when there are no category
  or monthly rows.
- shared mobile containment keeps the top bar, split panels, and Services table inside the outer
  viewport; the dense service list scrolls internally when needed.

## Automated evidence

- `node --test tests/quality/v123-module-button-readiness.test.mjs` — **9/9 pass**.
  Exact tests cover the route/control inventory, hidden Setup destination, clipboard contract,
  semantic staff link, single bundle RPC plus busy state, migration atomicity/privilege revocation,
  and report request gates/mobile CSS.
- `node scripts/quality/module-button-readiness.mjs` — **pass**: 25 business routes, 9 platform
  routes, 254 literal buttons and 15 literal links inventoried; no missing route page, unlabeled or
  unwired literal button, hidden literal route link, or non-semantic `onclick` remains.
- `EXPECTED_SUPABASE_PROJECT_REF=gadpooereceldfpfxsod npm run validate` — **pass** after regenerating
  the visual source-hash fixtures: quality, runtime configuration, migration manifests, canonical
  order, **1,327/1,327 tests**, and build.
- source migration and canonical mirror are byte-identical with SHA-256
  `d58fdf21f15ee55be202318584c7ccfeca7a83e4928c1868853396d0c7610640`.
- application candidate `app/index.html` SHA-256:
  `903514085bddfa72e3fce629f0159b9aaf69c95cf43e942459bf7b98ac823d8d`.

## Real-browser evidence

The production application component was served locally and exercised in Chrome through the
agent-browser harness using the realistic `SPA-GLOW` owner/staff fixtures. The browser session did
not replace application markup with a hand-written visual facsimile.

- Sign-in and create-account states render at 1440px and 390px. Password reveal works; the 390px
  document reports `clientWidth=390`, `scrollWidth=390`, and zero visible action targets below
  44px. The expected local-only Turnstile domain warning is the only console warning.
- Setup at desktop and 390px contains no Inventory action, has no outer overflow, and all visible
  controls are at least 44px. Forced clipboard denial produces the exact live message **“Copy was
  blocked. Select the text and copy it manually.”** and restores the button.
- Staff performance exposes Aisha Rahman as an `<a>` with `tabIndex=0`; focusing it and pressing
  Enter changes the hash to her exact drill-down route.
- Daily Report restores Generate immediately when scope changes during a pending request, rejects
  the obsolete completion, then permits a successful retry. A forced rejection replaces the
  loading state with **“Daily report could not be generated. Retry”**; the Retry starts a fresh
  request and the eventual success removes the error. Profit & Loss likewise renders a Retry after
  a forced summary rejection and then renders SGD 1,250 cash revenue, SGD 1,300 accrual revenue,
  SGD 450 expenses and SGD 800 net after retry. Both 390px renders have no outer overflow or visible
  sub-44px controls.
- Services creates one bundle from two realistic services. During the request the action reads
  **Creating…** and is disabled; completion restores **Create bundle**, invokes exactly
  `create_service_bundle_v123` with a 36-character attempt key and two service IDs, and shows
  **Bundle created.** At 390px, the outer document is exactly 390px wide and the table overflow is
  contained inside the service list.

Artifacts:

- `docs/qa/evidence/v123-browser/sign-in-desktop-1440.png`
- `docs/qa/evidence/v123-browser/sign-in-mobile-390.png`
- `docs/qa/evidence/v123-browser/services-desktop-1440.png`
- `docs/qa/evidence/v123-browser/services-mobile-390.png`
- `docs/qa/evidence/v123-browser/setup-copy-denied-mobile-390.png`
- `docs/qa/evidence/v123-browser/daily-retry-mobile-390.png`
- `docs/qa/evidence/v123-browser/pnl-retry-success-mobile-390.png`

## Disposable database rehearsal

The documented `db/tests/rehearsal/bootstrap.sql` harness ran in a fresh template database on
Supabase PostgreSQL 17.6. The canonical manifest applied **163/163 migrations** in order. Then
`db/tests/v123_module_button_readiness.sql` completed through `ROLLBACK` with `ON_ERROR_STOP=1`.

The suite proves:

- owner exact replay returns one bundle and two items, with one private operation receipt;
- edited-input reuse of an attempt key is rejected;
- cross-tenant services and a read-only actor are denied without mutation;
- the transaction leaves `public.businesses=0` and `auth.users=0` after rollback.

The container and database are disposable development infrastructure. They are not evidence from
the target Supabase project.

## Independent Sol 5.6 verdict

**ACCEPT — limited local V123 remediation patch.** Sol independently reran the 9/9 focused suite,
the 1,327/1,327 full validation and build, inspected the exact app hash and migration mirror, and
re-executed the disposable database acceptance through rollback with zero fixture residue. No
blocking code finding remains in this bounded patch.

Sol explicitly did **not** accept full module/button readiness or production release. The
authenticated all-role/module sweep is missing, `READINESS-001` remains `VERIFIED_LOCAL`, and
`RELEASE-001` remains `CAPTURED`.

## Remaining gap and release boundary

The code-wide inventory is a strict structural gate and the changed high-risk flows have focused
real-browser and database proof. Closing `READINESS-001` still requires authenticated target
journeys across every named role, branch and module projection, including denied/disabled and
owner -> staff -> customer persistence where relevant, followed by production smoke on the exact
released version. Existing unrelated ledger rows remain open.

No production migration, production data, secret, deployment, merge, commit, or push occurred in
this audit. `RELEASE-001` remains `CAPTURED`, which is an automatic production-release stop. Even
Sol's acceptance of this bounded remediation patch does not make the all-module/button objective
complete or authorize a release; the authenticated target sweep and a later scoped release review
remain separate work.
