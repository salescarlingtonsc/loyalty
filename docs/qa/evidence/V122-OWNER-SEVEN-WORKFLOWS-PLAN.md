# V122 owner seven-workflow plan

Source: owner message, 2026-07-31.

State: `VERIFIED_LOCAL`. Acceptance was captured before application changes.
The full local suite, disposable development-database migration/rollback
acceptance, and deterministic desktop/390px browser checks pass. Independent
review, authenticated target journeys, provider receipts, and production
evidence remain required before close.

## Reproduction record — 2026-07-31

| Issue | Reproduced root cause before fix |
|---|---|
| `QUICK-002` | `tillPage()` rendered gift-card issue and redemption controls and called both v117 gift-card mutation RPCs. |
| `CALENDAR-001` | The calendar already had named staff columns and contextual slot buttons; the unclosed gap was exact two-staff click → manual assignment → persisted refresh evidence. |
| `REWARD-OVERVIEW-001` | Grow showed an active reward count but not ordered thresholds, incremental progress, fulfilment cost, or birthday configuration. |
| `PROFIT-AI-001` | Products stored retail price but no cost; `growCatalogMetrics()` was price-only and could not calculate gross profit or a cost-aware reward budget. |
| `CUSTOMER-CATEGORY-001` | `customerProgrammeGridMarkupV96()` rendered one flat list despite `business.industry` already being present in linked cards. |
| `FEEDBACK-SYNC-001` | v53 persisted feedback, but a new row created no business notification or staff-session refresh signal. |
| `PROMO-PUSH-001` | V95 push and V104 promotions existed independently, with no explicit promotion consent or publication/expiry event connecting them. |

The initial V122 regression run passed only the pre-existing calendar contract
and failed the other six new contracts. After implementation, the focused
28-test business UI/build run and complete 1,318-test repository validation
pass. This remains local evidence only.

## Verification record — 2026-07-31

- `EXPECTED_SUPABASE_PROJECT_REF=gadpooereceldfpfxsod npm run validate`:
  1,318 tests passed, zero failed; quality, runtime config, migration manifest,
  canonical chain, and static build gates passed.
- The hosted reset operation twice reported `MIGRATIONS_FAILED`, so it was not
  accepted as evidence. The disposable Supabase development branch
  `wtegnefsgnyxhflzizcu` was instead rolled back in one transaction to the
  read-only production definitions and verified at migration
  `20260731064502`, with no V122 table, column, or RPC remaining.
- The exact frozen
  `supabase/migrations/20260731140000_nestly_v122_owner_seven_workflows.sql`
  then applied once as `nestly_v122_owner_seven_workflows_exact_candidate`.
  `db/tests/v122_owner_seven_workflows.sql` returned
  `V122 owner seven-workflow acceptance: PASS` in rollback. It verifies the
  product-cost authority/replay boundary, inbox ACL, current consent and exact
  promotion source binding, durable fanout watermark, feedback persistence plus
  one staff notification, the 15-minute activation/expiry schedule, denied
  cases, and two manually assigned persisted appointments for Alina Chen and
  Maya Lim. Production was not changed.
- Desktop owner evidence:
  `docs/qa/evidence/v122-browser/owner-grow-desktop-1440.png`.
- Desktop production-component two-staff calendar click/prefill evidence:
  `docs/qa/evidence/v122-browser/calendar-click-desktop-two-staff.png`.
- Desktop production-component save/refresh evidence with one booked
  appointment under each named staff column:
  `docs/qa/evidence/v122-browser/calendar-save-refresh-desktop-two-staff.png`.
- 390px production-component click/prefill evidence:
  `docs/qa/evidence/v122-browser/calendar-click-mobile-390.png`.
- 390px linked-company category and consented promotion-dialog evidence:
  `docs/qa/evidence/v122-browser/customer-categories-promo-mobile-390.png`.
- 390px production promotion-card evidence:
  `docs/qa/evidence/v122-browser/promotion-card-mobile-390.png`.
- The production-component calendar harness uses the shipped `appointmentsPage`
  DOM and synthetic local API responses; database persistence is proved
  separately by the development-branch SQL suite. Its 390px pass first exposed
  a 492px form overflow, which was fixed with zero-minimum grid containment and
  a source regression. The recapture recorded
  `clientWidth=scrollWidth=390`, Maya Lim, 31 July 2026, 13:00. Other browser
  measurements recorded no horizontal overflow at 1440px or 390px; the
  promotion dialog dismissed through its explicit “Not now” action.
- Calendar/dialog axe scan: zero WCAG A/AA violations (one incomplete contrast
  review because axe cannot resolve gradients/obscured background colors).
- Google review handoff remains score-independent after successful persistence
  to avoid prohibited selective positive-review solicitation.

## Scope and exact observable acceptance

### `QUICK-002` — remove Gift Cards from Quick Earn

- Quick Earn contains zero gift-card issue, apply, redeem, balance, or shortcut
  controls for owner, manager, and front desk at desktop and 390px.
- A direct legacy Quick Earn handler cannot mutate a gift card.
- `CUS-ARUN`'s existing SGD 50 liability is unchanged and remains operable only
  through the effective-module and role-gated Gift Cards workflow.

### `CALENDAR-001` — two-staff click-to-create calendar

- Orchard Day view renders Chen Wei and Aisha Rahman as distinct named columns.
- Selecting Chen's free 10:15 cell opens the previously hidden appointment form
  with Orchard, Chen, the visible date, and 10:15 already selected.
- Saving writes one appointment. Refresh and List view show the same staff,
  time, service, customer, and status.
- Aisha remains independently selectable. Occupied time, buffers, branch
  break, leave, Supplier training, missing hours, wrong branch, and read-only
  policy never appear as successful free-time writers.
- Mouse, keyboard, and 390px touch paths expose at least 44px targets.

### `REWARD-OVERVIEW-001` — game-like reward overview

- The owner overview shows configured rewards and birthday benefit in one
  ordered path with requirement, unlocked benefit, current state, next
  milestone, and direct edit action.
- Harbour Kopi reads as stamp 5 → Kopi, then five more stamps → Kaya toast set;
  it never misleadingly labels the second threshold as ten additional stamps.
- Empty/disabled rules show an honest setup action and no invented tier.

### `PROFIT-AI-001` — understandable profitability and AI setup

- Glow serum at SGD 68 price / SGD 24 cost displays SGD 44 gross profit and
  approximately 64.7% margin with formulas explained in plain language.
- A proposed reward displays estimated fulfilment cost and contribution after
  reward, including assumptions and low-confidence/missing-cost warnings.
- The deterministic setup assistant uses actual catalogue/sector inputs,
  remains editable, and requires explicit owner save/publish. It does not claim
  model-generated intelligence or hide missing cost data; manual setup remains
  fully usable.

### `CUSTOMER-CATEGORY-001` — linked-company categories

- `CUS-MEI` sees existing programmes grouped under Personal care, Food & drink,
  Fitness, and an Other fallback; card selection opens the same programme.
- Zero/one/many programmes, duplicate names, missing logos, retry, keyboard,
  and 390px states remain usable.
- No business directory search or self-link action is introduced.

### `FEEDBACK-SYNC-001` — persistent feedback and Google review handoff

- A submitted rating writes once with a stable submission key and appears for
  the authorized business after refresh/reconnect.
- Another firm and a denied staff role cannot read it.
- After any internal 1–5 star write succeeds, a configured valid Google review
  URL appears as the same explicit external action. Five-star copy may be
  warmer, but link reachability is score-independent to avoid prohibited review
  gating. Failed writes and missing/invalid URLs never redirect.

### `PROMO-PUSH-001` — company promotions and expiry notifications

- A newly active promotion creates at most one linked-customer in-app prompt.
- With consent, browser permission, public key, and dispatcher configuration,
  it creates at most one Web Push delivery per customer/promotion/channel and a
  safe programme deep link.
- Three-day and one-day expiry events remain independently deduplicated.
- Opt-out, unlinked customer, inactive/future/expired promotion, duplicate job,
  missing configuration, provider failure/backoff, timezone, and reconnect
  states fail honestly without a false “sent” record.

## Complete journey map

1. Owner configures catalogue cost/price, reward milestones, birthday benefit,
   Google review URL, appointment schedules, and one factual promotion.
2. Staff runs focused Quick Earn without gift cards, creates appointments by
   selecting either staff member's calendar cell, and reads synchronized
   feedback only within permission/tenant scope.
3. Customer sees linked businesses grouped by category, reward progression,
   persisted booking/feedback state, and consent-aware promotion/expiry
   notifications.

## Remaining evidence before close

- Authenticated target owner/front-desk/customer refresh/reconnect journeys,
  including feedback cross-session projection and customer booking history.
- Real provider receipt/failure/backoff evidence for Web Push.
- Independent Sol review of the exact candidate.
- No commit, push, production migration, production secret change, or deploy
  before a new owner release approval for V122.
