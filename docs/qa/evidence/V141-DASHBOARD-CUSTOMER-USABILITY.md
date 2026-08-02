# V141 dashboard and customer usability

## Scope

Owner annotated iPad screenshots on 2026-08-02 direct three frontend-only
changes: streamline Dashboard, complete customer-directory context, and make
the customer-profile recommendation understandable. This phase changes no
database schema, migration, RLS, production data, provider configuration or
production deployment.

## Reproduced baseline

The production screenshots and current source on `origin/main` reproduce the
complaints:

- the rail says **Home**, the branch picker is inside the page heading, and four
  cards duplicate app-bar/navigation actions;
- Performance is a collapsed `<details>` surface with a plus/minus control;
- there is no Today preset, inactive-customer KPI, recorded-gender chart or
  service-versus-goods summary;
- KPI cards are non-semantic `<div>` elements, **Unique customers** has no
  definition, and the revenue chart uses bare numeric values;
- Customers already has a 30/60/90 filter but the label is easy to miss and the
  directory omits Date joined;
- customer profile says **Next best action**, expiry appears only inside the
  Rewards body, and Rewards has no icon-led header.

The new `tests/business-ui/v141-dashboard-customer-usability.test.mjs` was run
before implementation and failed **0/5** against that baseline. The failures
covered the duplicate launcher/collapsed Performance dashboard, non-semantic
KPIs and missing detail, missing analytical charts/currency treatment, missing
Date joined, and missing profile guidance/expiry/reward treatment.

## Exact acceptance

See `DASHBOARD-UX-001`, `CUSTOMER-DIRECTORY-UX-001`, and
`CUSTOMER-GUIDANCE-UX-001` in the issue ledger and traceability matrix. Required
viewports are 1440px, an 1180px iPad-class viewport, and 390px. Required roles
are owner, manager and front desk. All visible KPI controls must be keyboard
operable, at least 44px high, preserve the selected scope in their detail, and
lead to an existing route. No automatic customer contact or value mutation may
occur.

## Implemented candidate

- **Dashboard** replaces Home in business navigation. Record sale, New
  appointment and customer search remain in the permission-aware app bar; the
  four duplicated page cards were removed.
- The branch selector is in the Dashboard app bar. Performance is a permanent
  section with Today/7/30/90/custom ranges and a visually distinct heading.
- Visit entries, revenue, unique customers, new customers, points, credit liability
  and inactive customers render as semantic buttons. Each opens an accessible
  scope/value/definition dialog and links to the relevant existing page.
- Branch-scoped report values say which branch they represent. Values whose
  current reader is business-wide are explicitly labelled business-wide. Date
  inputs do not relabel the figures until **Apply** succeeds.
- Busiest days use quiet green, medium amber and busiest red; revenue axes and
  tooltips say SGD. Age, recorded gender (including Unknown), and itemised
  service/goods/other gross line value are separate labelled charts. Visit
  entries and busiest-day activity explicitly disclose that reversals are
  separate entries rather than claiming a net-visit value. Item detail is read
  only for owner/super-admin roles; manager and front-desk roles see an honest
  unavailable state and issue no raw `sale_items` read. An unavailable owner
  item-detail read does not suppress the other current figures.
- Customers exposes the last-visit filter as a named control, keeps exact
  30/60/90 thresholds and never-visited semantics, and enriches the current
  bounded result page with Date joined. A failed join-date read leaves customer
  rows usable and offers a truthful retry.
- Customer profile says **Peekaa's suggestion**, uses a distinct insight
  surface, shows the next points expiry amount/date in the Points KPI, and
  gives Rewards an icon-led heading and distinct body. A failed expiry-batch
  read is distinct from a genuine no-expiry state and offers a retry without
  falsely asserting that points do not expire.

Key new surface labels are present in the English, Simplified Chinese and
Malay dictionaries.

No migration, backend writer, customer contact, reward fulfilment, or value
mutation was added.

## Verification evidence

- Focused behavior/regression and fixture-integrity set:
  `node --test tests/business-ui/v141-dashboard-customer-usability.test.mjs tests/business-ui/v118-task-first-ux.test.mjs tests/business-ui/v129-trial-test-ux.test.mjs`
  plus `tests/browser/v141-dashboard-visual.test.mjs` — **20/20 pass**. The
  current-renderer fixture and updated V129 fixture pass byte-for-byte source
  binding.
- Automated Chromium acceptance:
  `tests/browser/verify-v141-dashboard-customer.mjs` — **PASS** at 1440×1000,
  1180×820 and 390×844 for owner, manager and front desk. It proves zero body
  overflow, no console/renderer/error overlay,
  no duplicate task cards, branch selector in app bar, seven KPI buttons, five
  chart headings, branch versus business-wide scope labelling, applied-date
  authority, unique-customer and visit-entry definitions, inactive-customer
  navigation, and 44px-class visible actions. The owner issues exactly one
  permitted item-detail read; manager/front desk issue zero and see the
  permission-aware unavailable state. It also injects report, inactivity-count
  and item-detail interruptions, proves each in-surface Retry issues a fresh
  read, and confirms the signed discount fixture never becomes a negative or
  misleading **Other** segment. Customer acceptance proves 30-day filter
  persistence, Date joined, and retry after an injected join-date-only read
  interruption while rows remain usable. Profile acceptance proves guidance,
  exact expiry amount/date, no-expiry/no-programme/read-only variants, and an
  expiry-only interruption with retry and no false no-expiry claim.
- Browser captures:
  `v141-dashboard-customer-usability/dashboard-desktop-1440.png`,
  `dashboard-ipad-1180.png`, `dashboard-phone-390.png`,
  `dashboard-manager-ipad-1180.png`,
  `customers-ipad-1180.png`, and `customer-profile-phone-390.png`.
- Complete repository gate:
  `EXPECTED_SUPABASE_PROJECT_REF=gadpooereceldfpfxsod npm run validate` —
  **1,446/1,446 tests pass** and the static build passes.
- Candidate source hashes: `app/index.html`
  `2a81ac189e36c6e10fe99edb79208cfa46ab334c4cb85fc8ee000fb3e6bc56bd`;
  `app/customer-ui.js`
  `af2f2fc5b837c677d5a958ad975970b8bf3fcc17aa1acaada351c8f976842aeb`;
  V141 fixture
  `851d1d5c3733fa6f5bd5efa3851934bbba3140515017082bc8e96ac8f243c5ea`;
  focused regression
  `e62c8bf50d4525abfdaa4c863e7cb27b993e65314b1d67deccebe365b4749d8c`;
  browser verifier
  `c5cb7a4351c47d47d44e0e8b1d438b63f306f083b476bed4053a4488ae6ba4b1`.

## Independent review and closure

The first independent Sol review rejected the earlier `app/index.html`
candidate hash
`4ed7255d4e948196d1abe63a0dfbad586f67896a966061851e89fffa26a1eea6`
with zero P0, five P1 and two P2 findings. The revised candidate closes those
findings by permission-gating raw item detail, separating branch-scoped and
business-wide claims, using truthful **Visit entries** semantics, distinguishing
expiry read failure from no expiry, adding role/error/alternate browser states,
binding detail labels to the last successfully applied range, and adding the
new dictionary entries. Because this phase is intentionally frontend-only, it
does not invent a net-visit calculation or receipt-level allocation that the
current readers cannot support.

The second independent review rejected hash
`247357670c6b0204e777b98265da49c040fb64650895d5eb323dc538acbbb704`
with zero P0, two P1 and two P2 findings. The current candidate adds recoverable
report/inactivity/item-detail states, excludes signed discounts and all
non-positive lines from the gross positive mix, localizes the core dashboard
labels/definitions/errors, and runs every dashboard role at every required
viewport. The revised hashes above are the candidate for the third independent
review.

The third independent review found no P0/P1 and rejected the prior candidate
only for three P2 evidence/accessibility/localization gaps. The current
candidate clears `aria-busy` on failure, waits for Chart.js to settle before
capturing stable owner/manager evidence, and localizes the dynamic branch/
business/current-scope fragments before interpolating runtime names and dates.
The regenerated owner 1440 capture was visually inspected and all five charts
are settled and readable. The current hashes above are the candidate for the
fourth independent review.

The fourth independent Sol review accepted the exact current hashes above with
**0 P0, 0 P1 and 0 P2**. Sol independently confirmed the accessibility-state
reset, settled visual captures, localized dynamic scope, 20/20 focused suite,
1,446/1,446 full validation plus static build, clean diff check, and absence of
backend, migration or Supabase changes.

The browser fixtures use the production render functions with synthetic
`SPA-GLOW` data. They prove local/browser behavior, not authenticated target or
production data. No production deployment has occurred.

## Status

`VERIFIED_BROWSER` — independently accepted by Sol and released under the
owner's explicit V141 approval on 2026-08-02. Commit
`ebdac8b12d6dc739a799a73a399578644122664d` was pushed to
`origin/codex/v141-dashboard-customer-ux`. Vercel production deployment
`dpl_87Rg8gyADszJTZFkmgzErH3zn9oA` reached `READY` and was aliased to
`https://www.peekaa.asia`. The canonical `index.html` SHA-256 is exactly the
accepted `2a81ac189e36c6e10fe99edb79208cfa46ab334c4cb85fc8ee000fb3e6bc56bd`;
`/business` returned HTTP 200; bare `peekaa.asia` returned HTTP 308 to `www`;
and the served source contains **Visit entries**, **Peekaa's suggestion**, and
the dashboard item-detail Retry marker. This proves exact production artifact
delivery, not an authenticated owner/manager/front-desk journey. The three
ledger rows therefore remain `VERIFIED_BROWSER`, not `CLOSED`, until that
target-authenticated proof is captured.
