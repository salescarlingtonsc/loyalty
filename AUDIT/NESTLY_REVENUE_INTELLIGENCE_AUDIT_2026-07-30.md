# Nestly Revenue Intelligence and Next-Best-Action Audit

**Audit date:** 2026-07-30
**Mode:** Read-only product and engineering audit
**Frozen commit:** `6226777e34c41ac1bc5f6ec10edd13332e17c929`
**Branch:** `codex/v89-security-readiness`
**Working tree:** Dirty before the audit; 57 tracked changes and 26 untracked paths were present. They were treated as owner work and were not altered.
**Audited application:** Nestly static web/PWA application and the Supabase/Postgres services, migrations, functions, and tests it directly uses.
**Runtime limitation:** The frozen local workspace is not a clean representation of `main` or a verified production deployment. Conclusions apply to this frozen workspace only.

## Executive verdict

Nestly has a credible loyalty ledger, verified customer-linking model, tenant-scoped sales and payment foundations, reversal-aware customer analytics, and an unusually promising treatment/holdout measurement substrate. It does **not** yet provide a reliable closed revenue-growth loop.

The current product can capture transactions entered into Nestly and present useful loyalty analytics. It cannot prove that it captures the merchant's complete sales, cannot safely call its identified-customer totals total business revenue, cannot explain the drivers of revenue change, cannot rank commercially grounded next actions, and cannot automatically deliver and learn from a campaign. Gross-profit claims are impossible because general product/service cost and margin data are absent.

**Score: 47/100.**
**Highest fully supported classification: Loyalty analytics dashboard.**
**Overall maturity: L2 for a limited analytics subset; L1–L2 across the complete growth loop.**

The single best next build is a **Measured Bring-Back Loop v1**: a server-authoritative, consent-aware lapsed-customer opportunity; one concrete offer; one supported delivery channel; a mandatory holdout when sample size permits; automatic transaction outcome capture; and an owner-visible incremental-revenue result. Profit must remain out of scope until cost and margin data are authoritative.

## Scope and repository orientation

### Architecture

| Concern | Audited implementation |
|---|---|
| Application | Static single-page web/PWA in `app/`, centred on `app/index.html` and supporting JavaScript |
| Package shape | One root npm package; not a monorepo |
| Package manager/runtime | npm; Node.js 22 or newer |
| Database | Supabase Postgres, versioned SQL migrations, RPC-heavy server authority, RLS |
| Server execution | Supabase RPCs, triggers, Edge Functions, cron-oriented database functions |
| Hosting | Vercel static deployment configuration |
| Customer surfaces | Customer wallet/programme, booking, QR join, notifications |
| Merchant surfaces | Checkout/Quick earn, customers, appointments, loyalty, retention playbooks, reports |
| Platform surfaces | Super-admin/firm intelligence and controls |
| AI | No repository evidence of a production OpenAI, Anthropic, Gemini, or equivalent model integration in the audited growth loop |

### Important evidence boundaries

- Database migrations and source tests prove structure and intended authority, not that a remote database has the migration or contains correct production data.
- The full source test suite passed, but seeded SQL integration tests did not run because no local Postgres rehearsal server or database URL was available.
- No browser acceptance test was performed in this audit.
- No remote Supabase, Vercel, messaging provider, or production data was accessed.
- Design documents were used as intent only, never as proof of implementation.

## Verification ledger

### Commands executed

```text
git rev-parse HEAD
git branch --show-current
git status --short
git status --short | awk ...
rg --files
rg and nl/sed inspections across app/, db/, docs/, scripts/, supabase/, and tests/
pg_isready -h 127.0.0.1 -p 5499
printenv DATABASE_URL
printenv SUPABASE_DB_URL
node --test tests/platform/v82-enterprise-intelligence.test.mjs \
  tests/platform/v83-customer-intelligence.test.mjs \
  tests/platform-console/v82-enterprise-intelligence.test.mjs \
  tests/grow/grow-recommender.test.mjs \
  tests/phase2-config/retention-recommendation.test.mjs \
  tests/phase2-config/versioned-retention.test.mjs \
  tests/customer-wallet/identity-foundation.test.mjs \
  tests/customer-wallet/v81-customer-relationship-sync.test.mjs
EXPECTED_SUPABASE_PROJECT_REF=gadpooereceldfpfxsod npm run validate
```

### Results

| Verification | Result | What it proves | What it does not prove |
|---|---|---|---|
| Focused intelligence/identity tests | 80 passed, 0 failed | Relevant source contracts remain internally consistent | Seeded numeric SQL results or browser behaviour |
| Full `npm run validate` | Passed | Quality, runtime config, migration manifests, 863 Node tests, and static build passed | Remote schema state, production data, provider delivery, or end-to-end browser workflow |
| Full Node test count | 863 passed, 0 failed | Broad source-level regression coverage | Live database execution |
| Static build | Passed | Deployable static assets can be produced | Correctness after deployment |
| SQL integration/rehearsal tests | **Blocked** | Local `pg_isready` returned no response; DB URLs were unset | No SQL test is represented as passed |
| Browser acceptance | **Not run** | None | No browser claim is made |
| Remote/production checks | **Not run** | None | No production-readiness claim is made |

The Node process emitted module-type warnings. They did not fail the suite but should be cleaned up separately.

## Weighted score

| Category | Score | Maturity | Verdict |
|---|---:|---|---|
| A. Data capture, integrity, tenant safety | 13/20 | L2 subset | Strong internal ledgers; incomplete source coverage |
| B. Customer identity and intelligence | 8/15 | L2 subset | Safe verified linking; incomplete merge and behavioural segmentation |
| C. Revenue metrics and explanation | 8/15 | L2 subset | Useful reversal-aware metrics; misleading coverage and weak diagnosis |
| D. Next-best-action quality | 7/20 | L2 subset | Deterministic suggestions exist; no ranked commercial NBA object |
| E. Execution and automation | 5/15 | L1–L2 | Measurement control plane exists; delivery remains manual/incomplete |
| F. Attribution and learning loop | 4/10 | L2 subset | Deterministic holdout and lift math exist; outcomes and learning are incomplete |
| G. SME and hawker usability | 2/5 | L1 | Too much manual capture and campaign expertise |
| **Total** | **47/100** | **L1–L2 overall** | **Loyalty analytics dashboard** |

## Category findings

### A. Data capture, integrity, and tenant safety — 13/20

**Strengths**

- Tenant-owned businesses, staff, clients, services, appointments, products, sales, payments, points, and rewards are modelled in migrations beginning with `db/migrations/20260716075908_frenly_init.sql` and `db/migrations/20260716084652_frenly_v2_saas.sql`.
- `public.payments` is an append-oriented signed money ledger with idempotency and tenant foreign keys in `db/migrations/20260717_frenly_v11b_money.sql:202-275`.
- `public.sale_items` is append-only and tenant-bound in `db/migrations/20260723_frenly_v51_sale_line_items.sql:44-90`.
- `public.record_cart_sale` delegates to the authoritative quick-sale path and records line items atomically and idempotently in `db/migrations/20260723_frenly_v51_sale_line_items.sql:128-333`.
- Points and payment reversals are represented rather than silently mutating historical totals.

**Defects and missing inputs**

- Revenue completeness depends on merchants recording sales in Nestly. No direct merchant POS/e-commerce sales integration, payment transaction import, receipt ingestion, or reconciliation feed was found.
- Anonymous walk-in sales can exist without a customer and are therefore absent from identified-customer intelligence.
- General product/service COGS, gross margin, discount, tax, service-charge, tip, and acquisition-source fields are not authoritative.
- Partial refunds are not implemented as a general launch capability; full reversal semantics dominate.
- The migration explicitly states that multi-retail carts do not deduct inventory unless exactly one retail line is present (`db/migrations/20260723_frenly_v51_sale_line_items.sql:21-37`).
- Business timezone is not an authoritative setting in the audited intelligence RPC; reporting is hardcoded to `Asia/Singapore`.
- Multiple-currency accounting is not a decision-grade cross-currency model.

**Business consequence**

Nestly can calculate faithfully over the sales it knows, but cannot prove those rows equal the merchant's total business. Missing walk-ins or external POS sales can make trends, repeat rates, and forecasts look precise while representing only a subset.

**Required remediation**

Add a canonical transaction/event contract, revenue-coverage KPI, explicit unattributed revenue, authoritative timezone/currency, partial-refund events, and at least one reconciled ingestion path. Do not expose profit until item/service cost and campaign cost are captured.

### B. Customer identity and intelligence — 8/15

**Strengths**

- Platform customer identity and proof objects are audited and RLS-protected in `db/migrations/20260720_frenly_v30_customer_identity.sql:33-180`.
- Business-client links have uniqueness constraints and fail-closed browser writes in `db/migrations/20260720_frenly_v31_customer_links_claims.sql:14-61,198-211`.
- Relationship sync uses verified Auth phone/email, normalization, rate limiting, idempotency, exact matching, and ambiguity suppression in `db/migrations/20260726_nestly_v81_customer_relationship_sync.sql:31-290`.
- Cross-outlet activity can be consolidated at a business identity when the verified link exists.

**Defects and missing inputs**

- There is no safe owner-visible merge workflow for duplicate business client profiles with transaction-history preservation.
- Anonymous purchases are not retroactively stitched to a later verified identity.
- Shared-phone or ambiguous matches are intentionally skipped; safe, but it leaves incomplete histories.
- No authoritative RFM segmentation, configurable cadence model, churn state machine, responder propensity, complaint exclusion, discount dependence, or service-failure signal was found.
- Opt-out storage exists in parts of the platform, but campaign audience selection does not prove end-to-end suppression at delivery time.

**Business consequence**

Customer-level analytics is reliable for linked, identified customers but not for the entire business. “High value” and “at risk” decisions may ignore anonymous or duplicated history.

**Required remediation**

Add identity coverage metrics, auditable merge/stitching, and server-authoritative lifecycle states with business/segment cadence. Consent must be checked again at execution time.

### C. Revenue metrics and explanation — 8/15

**Strengths**

- `platform_customer_intelligence` is server-authoritative, reversal-aware, branch-filterable, and documents methodology in `db/migrations/20260726_nestly_v83_customer_intelligence.sql:53-473`.
- Forecast gating is conservative: 90 history days, 12 active weeks, 30 completed transactions, and 8 cash weeks are required (`:126-283`).
- Forecast output includes a range rather than a single guaranteed number.
- Customer frequency uses the interval between first and last purchase divided by purchase gaps, not an arbitrary count.

**Critical correctness problem**

The v83 RPC builds its revenue summary from `client_metrics`, which begins from identified clients (`db/migrations/20260726_nestly_v83_customer_intelligence.sql:286-393`). The UI labels the aggregate simply “Net revenue” and “Cash collected” (`app/index.html:11163-11169`). It does not disclose that anonymous/unlinked business sales are excluded. This is a false-completeness risk.

**Definition problem**

“Returning customer” means two or more eligible purchases **inside the selected period** (`db/migrations/20260726_nestly_v83_customer_intelligence.sql:375-393`). That is not the same as a historically existing customer who returns once in the period. The UI label “Returning” is therefore ambiguous.

**Missing diagnosis**

- No quantified price/volume/customer-frequency/product-mix/outlet/daypart/refund decomposition.
- No server-authoritative new, repeat, reactivated, dormant, or churned state dictionary.
- No RFM, profit LTV, product/category mix, discount dependence, or campaign ROI.
- Enterprise insights in v82 use threshold rules such as fewer than 30 transactions, repeat rate below 30%, and last purchase over 90 days; they are not ranked causal explanations.

**Business consequence**

An owner can see a number but cannot safely answer “what changed, why, and what is the dollar opportunity?” The product risks encouraging action on incomplete coverage.

**Required remediation**

Separate total revenue from identified-customer revenue, disclose coverage, define lifecycle metrics, and add a deterministic change-decomposition layer before adding generative explanation.

### D. Next-best-action quality — 7/20

**Present**

- Customer wallet guidance ranks actions server-side in `db/migrations/20260721_frenly_v44_actionable_customer_wallet.sql:50-236`.
- `app/grow-recommender.js` deterministically proposes loyalty economics and labels retention lift as an estimate.
- `db/migrations/20260720_frenly_v35_retention_recommendation_drafts.sql:60-161` creates editable configuration drafts from catalogue/sector inputs.
- The retention playbook can define an audience and treatment/holdout experiment.

**Not present**

- No canonical recommendation record containing evidence window, comparison window, opportunity value, cost, confidence, expiry, ranking, guardrails, owner decision, execution state, outcome, and feedback.
- No ranking of top opportunities by expected incremental revenue or profit.
- No suppression based on confidence, small samples, consent, recent contact, recent complaint, or cold start at the recommendation layer.
- No evidence that estimated lift learns from the business's own past experiments.
- No production LLM integration; current language and suggestions are deterministic/rule-based. That is acceptable, but must not be represented as AI-generated commercial intelligence.

**Business consequence**

Nestly helps configure loyalty but does not yet tell a busy owner the one best commercially defensible action to take today.

### E. Execution and automation — 5/15

**Present**

- Campaigns, immutable eligibility snapshots, deterministic holdout assignment, treatment-only offer guards, budgets, return recording, and result retrieval exist in `db/migrations/20260722_frenly_v50_retention_measurement.sql:42-779`.
- The database refuses issuing an offer to a holdout customer (`:452-556`).
- Owner and staff authority is enforced in server functions.

**Incomplete**

- The app computes playbook audiences client-side from fetched clients/sales and asks the owner to configure lapse thresholds, holdout, budget, window, and expected upside.
- “Delivery” is manual: the UI exposes contacts/WhatsApp and then calls `issue_campaign_offer` (`app/index.html:8217-8262`). It does not prove a message was sent or delivered.
- The UI label “Offers sent” (`app/index.html:8167`) overstates an issued database row.
- No end-to-end consent suppression, quiet hours, frequency caps, failed-send retry, provider callbacks, open/click states, or execution reconciliation was verified.
- The general customer push dispatcher covers service events, not this promotional campaign loop.

**Business consequence**

Owners still have to operate a campaign builder and perform outreach manually. Nestly can record intended offers without proving customer exposure.

### F. Attribution and learning loop — 4/10

**Present**

- Deterministic, reproducible treatment/holdout assignment is implemented in `app.campaign_holdout_bucket` (`db/migrations/20260722_frenly_v50_retention_measurement.sql:42-52`).
- Treatment-only issuance is structurally enforced.
- `get_campaign_results` calculates treatment and holdout return rates and a counterfactual lift (`:676-779`).

**Incomplete**

- Holdout may be configured to 0%, eliminating a causal comparison.
- “Return” recording is manually triggered from the UI (`app/index.html:8178`), not an automatically maintained outcome pipeline.
- Exposure/delivery is not proven, so intent-to-treat and treatment-on-treated concepts are conflated.
- Overlapping campaigns, organic purchases, pre-existing trends, statistical uncertainty, minimum sample size, message cost, reward cost, discount cost, and gross margin are not handled end to end.
- No recommendation model updates from past outcomes.

**Business consequence**

The system can calculate a useful experimental comparison for a carefully run campaign, but it cannot yet reliably claim a campaign caused incremental sales, and it cannot calculate incremental gross profit.

### G. SME and hawker usability — 2/5

The product supports cash, SGD, mobile web/PWA, QR joining, and plain-language customer flows. However:

- Merchant sales must be recorded in Nestly or imported through limited manual workflows.
- Customer joining includes QR scan, authentication/account creation, required verification/profile/legal steps, and relationship linking.
- Merchant checkout requires customer lookup/entry, item or amount selection, payment selection, and confirmation.
- Bring-back execution requires audience rules, holdout, budget, dates, expected upside, activation, manual contact, offer recording, later return recording, and results interpretation.
- No instrumentation proves p95 checkout duration, QR-join completion rate, message-delivery rate, or time-to-first-campaign.
- There is no one-minute daily briefing with one verified problem, dollar range, one recommended action, and one-click execution.

This is too cognitively and operationally demanding for a lunch-rush hawker without a marketing operator.

## Capability maturity matrix

| ID | Capability | Status | Maturity | Evidence | Source of Truth | Formula or Rule | End-to-End Path | Missing Input | Failure Mode | Business Consequence | Recommended Fix | Priority |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| CAP-01 | Customer creation | PARTIAL | L2 subset | v30, v31, v81 migrations; identity tests | Auth identity + platform identity + business client/link | Verified normalized phone/email; ambiguous match skipped | QR/auth → verified proof → exact link → wallet | Runtime/browser proof | Network/auth failure or unmatched client | Join may not yield complete history | Instrument join funnel and reconciliation | P1 |
| CAP-02 | Customer identity merging | MISSING | L0 | No authoritative merge RPC found | None | None | None | Merge authority and audit contract | Duplicate client histories remain split | Understated value/frequency | Add audited merge and reversible aliasing | P0 |
| CAP-03 | Transaction ingestion | PARTIAL | L1–L2 | v2 sales; v51 cart RPC | `sales`, `sale_items`, `payments` | Manual Nestly sale/cart | Merchant entry → RPC → ledgers | POS/e-commerce/payment reconciliation | Missing external/walk-in sales | Incomplete revenue view | Canonical ingestion + coverage/reconciliation | P0 |
| CAP-04 | Duplicate prevention | VERIFIED_ANALYTICS_ONLY | L2 | v51 idempotent cart; payment idempotency | Server RPC/idempotency keys | Replays return canonical record | Client key → authoritative RPC | Webhook/source external IDs | Bad callers can choose weak keys | Duplicate risk outside Nestly path | Enforce source/event unique keys | P0 |
| CAP-05 | Full refund/reversal | VERIFIED_ANALYTICS_ONLY | L2 | v11b signed payments; reversal-aware v83 | Append-only sales/payment/points rows | Signed reversal rows excluded/netted | Reversal RPC → ledgers → analytics | Browser/DB runtime proof | Operational retry failure | Stale customer/revenue totals | Seeded SQL integration cases | P0 |
| CAP-06 | Partial refund | MISSING | L0 | No general partial-refund contract found | None | None | None | Partial line/payment allocation | Full reversal only | Incorrect net revenue/customer value | Add partial refund allocation events | P0 |
| CAP-07 | Anonymous customer history | DATA_ONLY | L1 | Sales may have nullable client | `sales` | Anonymous sale remains unlinked | Checkout → anonymous sale | Later identity stitch | History cannot follow customer | Lower repeat/CLV coverage | Anonymous token and audited stitch | P0 |
| CAP-08 | New customer classification | PARTIAL | L1–L2 | v83 customer metrics | Identified client sales | Not exposed as first-ever canonical state | RPC → UI “New / one purchase” | Lifetime first purchase definition | One purchase in window conflated with new | Mis-targeted acquisition messaging | First-ever completed purchase metric | P0 |
| CAP-09 | Returning customer classification | BROKEN | L2 calculation, L0 label | v83 `purchase_count >= 2` in period; UI “Returning” | v83 RPC | Two purchases within selected period | RPC → customer table | Historical-period context | Label differs from common meaning | Misleading repeat rate | Split repeat, returning, reactivated | P0 |
| CAP-10 | Repeat customer rate | PARTIAL | L2 subset | v83 methodology JSON | v83 identified clients | Returning identified purchasers / active identified purchasers | RPC → UI/report | Anonymous coverage | Denominator silently excludes unlinked sales | Inflated/biased repeat rate | Show formula and coverage | P0 |
| CAP-11 | RFM | MISSING | L0 | No authoritative RFM object found | None | None | None | Stable recency/frequency/monetary windows | Ad hoc owner interpretation | Weak targeting | Add versioned server RFM after coverage fix | P1 |
| CAP-12 | Churn/at-risk | PARTIAL | L1 | v82 hardcoded >90-day lapse; client playbook thresholds | Mixed SQL/client | Generic threshold | Analytics → manual playbook | Business/segment cadence | Salon and hawker treated alike | Bad timing and fatigue | Cadence-aware lifecycle states | P1 |
| CAP-13 | Lifetime revenue | VERIFIED_ANALYTICS_ONLY | L2 subset | v83 client metrics | Identified client net sales | Sum reversal-aware eligible sales | RPC → customer record | Anonymous/merged history | Understated total history | Misranked VIPs | Label identified lifetime revenue + coverage | P0 |
| CAP-14 | Profit LTV | BLOCKED_BY_MISSING_INPUT | L0 | No general COGS/margin/horizon | None | Cannot calculate defensibly | None | Margin, retention horizon, costs | Revenue mislabeled as value/profit | Unsafe offers | Capture margin; later model profit LTV | P2 |
| CAP-15 | Average order value | PARTIAL | L1–L2 | Derivable from eligible sales; not canonical enterprise metric | Sales | Net eligible revenue / completed transactions | Query/report fragments | Discount/tax/refund semantics | Inconsistent definitions | Conflicting reports | Canonical metric dictionary/RPC | P0 |
| CAP-16 | Revenue coverage | MISSING | L0 | v83 begins from identified clients | None | Needed: identified revenue / total known revenue | None | Total reconciled sales | UI implies completeness | False confidence | Add total, identified, unattributed, coverage | P0 |
| CAP-17 | Revenue change explanation | MISSING | L0 | v82 generic threshold insights | None | No quantified decomposition | KPI → generic insight only | Product/category/price/volume comparison | Correlation presented as advice | Owner cannot know why | Deterministic driver decomposition | P1 |
| CAP-18 | Forecast | VERIFIED_ANALYTICS_ONLY | L2 | v83 gates and p20/mean/p80 | v83 RPC | 90d, 12 weeks, 30 tx, 8 cash weeks | SQL → report | Live seeded numeric verification | Incomplete source data enters model | Precise-looking subset forecast | Coverage gate and seeded tests | P1 |
| CAP-19 | Multi-outlet analytics | PARTIAL | L2 subset | v82/v83 business/branch filters | Tenant/branch sales | Aggregate or filter branches | RPC → admin report | Cross-outlet runtime tests | Incorrect scope if data/link incomplete | Bad branch comparison | Seeded cross-branch tests and coverage | P1 |
| CAP-20 | Product/category intelligence | BLOCKED_BY_MISSING_INPUT | L1 | Products and sale items exist; category/margin absent | `sale_items`, products/services | Item mix possible when itemized | Cart → line items → reports | Category, cost, external sales | Custom amount/missing line item | Weak cross-sell/mix advice | Product taxonomy and item coverage KPI | P1 |
| CAP-21 | Campaign audience selection | PARTIAL | L1–L2 | v50 snapshot tables; UI computes playbook audience client-side | Campaign member snapshot after activation | Lapse/visit rules | Owner wizard → activate → snapshot | Server eligibility/consent/cadence | Stale or unsafe client audience | Wrong customers contacted | Server-authoritative eligibility preview | P0 |
| CAP-22 | Consent enforcement | PARTIAL | L1 | Consent data exists; v50 delivery path lacks proof of filtering | Consent records, incomplete executor | Must recheck at execution | Manual workflow | Delivery-time enforcement | Opted-out customer contacted | Compliance and trust harm | Executor-side hard suppression | P0 |
| CAP-23 | Campaign sending | UI_ONLY | L0–L1 | `app/index.html:8217-8262` manual WhatsApp/contact path | External manual action | No provider send record | Copy/open app → owner sends manually | Provider API/callback | Offer row exists with no exposure | False “sent” reporting | One supported provider/channel with state | P1 |
| CAP-24 | Delivery status/retry | MISSING | L0 | No campaign provider lifecycle found | None | None | None | Provider callbacks | Failure invisible | Owner believes outreach happened | queued/sent/delivered/failed/retry events | P1 |
| CAP-25 | Voucher/offer issuance | VERIFIED_ANALYTICS_ONLY | L2 | v50 treatment-only issuance and idempotency | Campaign grant/reward grant | Holdout prohibited | Activated campaign → issue RPC | UI cost/reward linkage | Offer may be record-only | Weak economic/accounting link | Require entitlement, cost, expiry | P1 |
| CAP-26 | Voucher redemption | PARTIAL | L2 subset | Reward/QR ledger exists elsewhere; campaign link incomplete | Reward operations | Single-use/idempotent operation | Customer QR → merchant scan → ledger | Campaign entitlement linkage | Purchase/redemption not attributable | Ambiguous campaign result | Join voucher and transaction lineage | P1 |
| CAP-27 | Holdout group | VERIFIED_ANALYTICS_ONLY | L2 | v50 hash bucket and treatment FK | Campaign members | Deterministic hash; 0–90% configurable | Activate → snapshot → issue guard | Minimum sample/confidence rule | Owner chooses 0% | No causal estimate | Enforce default/minimum or suppress claim | P0 |
| CAP-28 | Incremental revenue | PARTIAL | L2 subset | v50 treatment/holdout lift RPC | Campaign outcomes | Difference in return rates and revenue | Manual returns → results | Real exposure, automatic outcomes, overlap | Selection/exposure/overlap bias | Overclaimed lift | Intent-to-treat automatic outcome pipeline | P1 |
| CAP-29 | Incremental gross profit | BLOCKED_BY_MISSING_INPUT | L0 | Costs/margin absent | None | Revenue × margin − all costs unavailable | None | COGS, discount, reward, message cost | Revenue called profit | Destructive promotions | Do not expose until cost contract exists | P2 |
| CAP-30 | Recommendation generation | PARTIAL | L1–L2 | v35 draft; v44 wallet; JS recommender | Rules/config data | Deterministic heuristic | Analytics/config → draft | Opportunity object and outcome history | Generic suggestion | Low owner trust | Canonical evidence-backed recommendation | P1 |
| CAP-31 | Recommendation ranking | MISSING | L0 | No cross-opportunity ranking found | None | None | None | Comparable expected impact/confidence | Many modules, no priority | Owner does analysis | Rank one to three by impact/urgency | P1 |
| CAP-32 | Recommendation execution | PARTIAL | L1 | Playbook wizard/manual contact | Campaign RPC + manual action | Multi-step | Insight → wizard → manual outreach | One-click guarded executor | Drop-off and error | Low adoption | Preview/approve/execute single action | P1 |
| CAP-33 | Recommendation outcome | DATA_ONLY | L2 subset | v50 results object | Campaign result RPC | Treatment vs holdout | Manual record returns → results | Automatic transaction linkage | Stale/manual outcomes | Cannot trust value | Event-driven automatic outcome | P1 |
| CAP-34 | Recommendation feedback/learning | MISSING | L0 | No outcome-fed policy/model found | None | None | None | Acceptance/dismissal/outcome history | Same rules repeat | No improvement | Store decisions and calibrate estimates | P2 |
| CAP-35 | Daily owner briefing | MISSING | L0 | Analytics screens and modules only | None | None | None | Ranked verified issues/actions | Cognitive overload | No daily reason to open | One-minute briefing | P1 |
| CAP-36 | Cold-start behaviour | PARTIAL | L2 for forecast, L0 for NBA | v83 forecast suppression | v83 RPC | Explicit sufficiency thresholds | SQL → insufficient-data state | Recommendation-wide gate | Other rules can still sound confident | Premature advice | Shared confidence/cold-start policy | P1 |
| CAP-37 | Hawker checkout workflow | PARTIAL | L1 | Cash/manual Quick earn supported | Sale RPC | Search customer → choose item/amount → payment → confirm | Merchant UI → RPC | POS integration/offline queue/latency metrics | Rush-hour interruption | Low capture coverage | Express scan/anonymous sale + reconciliation | P1 |

## End-to-end lineage verdicts

### Captured sale

```text
Merchant manually selects/enters customer and items
→ record_cart_sale / record_quick_sale
→ authoritative sales row
→ append-only sale_items, payment, and points rows
→ v82/v83 analytics
→ merchant reports/customer ledger
```

This path is structurally strong inside Nestly. Its weakness is **coverage**, not only calculation: sales that never enter Nestly are invisible.

### Customer identity

```text
Customer scans QR and authenticates
→ verified Auth phone/email
→ normalized proof
→ exact unique candidate matching
→ immutable business-client link
→ cross-device customer wallet
```

This path is safe and conservative. Ambiguous identities are skipped, not guessed. There is no complete duplicate/anonymous merge path.

### Campaign experiment

```text
Owner defines rule in a multi-step UI
→ client computes eligible candidates
→ campaign created and activated
→ immutable treatment/holdout members
→ owner manually contacts treatment customers
→ offer issuance row recorded
→ owner later invokes return recording
→ SQL computes treatment/holdout comparison
→ UI displays result
```

The experimental database core is promising. The exposure, consent, delivery, automatic outcome, overlap, cost, and learning links are incomplete.

## Metric findings

The canonical definitions proposed for remediation are in `NESTLY_METRIC_AND_EVENT_CONTRACT_2026-07-30.md`.

| Current display/capability | Current meaning | Authority | Correctness verdict |
|---|---|---|---|
| Net revenue in Customer Intelligence | Sum of eligible reversal-aware sales for identified clients in scope | Server RPC | Formula is useful; label is incomplete because unlinked sales are excluded |
| Cash collected | Payment methods treated as cash for identified clients | Server RPC | Useful subset; not total drawer/business cash |
| Returning customer | Identified client with at least two eligible purchases in the selected period | Server RPC | Reproducible but ambiguously labelled |
| Repeat customer rate | Period “returning” identified purchasers / active identified purchasers | Server RPC | Denominator documented in methodology; coverage missing |
| Purchase frequency | Days between first and last eligible purchase divided by purchase gaps | Server RPC | Correct for customers with 2+ purchases; sensitive to incomplete history |
| Lifetime revenue | Reversal-aware eligible revenue attached to identified client | Server RPC | Must be labelled identified lifetime revenue |
| Forecast | Weekly history range after sufficiency gates | Server RPC | Sensible cold-start gate; source coverage may still be incomplete |
| Campaign lift | Treatment return rate minus holdout return rate, with counterfactual revenue structure | Server RPC | Promising; delivery and automatic outcome evidence incomplete |
| Incremental gross profit | Not calculated | None | Must remain unavailable |

## Required edge-case test matrix

| Scenario | Evidence/result | Status | Missing exact test |
|---|---|---|---|
| 1. First and second purchase | v83 uses period count, not first-ever/lifetime state | PARTIAL | Seed first-ever before/inside period; assert new, repeat, returning, reactivated separately |
| 2. Duplicate ingestion | RPC idempotency exists for Nestly cart/payment path | PARTIAL | Replay external source event/webhook with same source ID and altered payload |
| 3. Refund | Full reversal structure exists | PARTIAL | Seed partial refund, full refund, points reversal, campaign outcome, and late refund |
| 4. Cancelled/voided sale | Eligible-state filters/reversals exist | PARTIAL | Seed booked/pending/cancelled/voided/completed rows and assert every KPI |
| 5. Anonymous to identified | No stitch path found | MISSING | Anonymous cash purchase → later verified join → audited merge without duplication |
| 6. Multi-outlet customer | Branch/business filters exist | PARTIAL | Same identity at two branches, business aggregate, branch isolation |
| 7. Timezone boundary | Hardcoded Singapore timezone | PARTIAL | 23:59/00:01 local, UTC boundary, backdated transaction, DST-capable future market |
| 8. Exposure without purchase | Campaign membership/grant exists | PARTIAL | Provider delivered state, no purchase, correct non-return |
| 9. Purchase without redemption | Return window can associate purchase | PARTIAL | Define attributed/associated versus redeemed versus incremental labels |
| 10. Overlapping campaigns | No robust overlap policy found | MISSING | Same customer in two active campaigns, mutual exclusion and attribution |
| 11. Opt-out | Consent exists but executor suppression unverified | UNVERIFIED | Opt out after scheduling but before send; assert suppression and audit |
| 12. Reward cost exceeds value | Margin/cost absent | BLOCKED_BY_MISSING_INPUT | Seed margin/cost and assert campaign stop/rejection |
| 13. Cold start | Forecast suppression exists | PARTIAL | Ensure all recommendations—not only forecast—suppress confidence/upside |
| 14. Small sample | Generic transaction threshold in insights | PARTIAL | Holdout too small; confidence unavailable; no causal claim |
| 15. Execution failure | No campaign provider lifecycle | MISSING | queued → failed → retry → delivered; owner-visible status; no false “sent” |

## Security and integrity risks relevant to growth

1. Tenant scoping and server-authoritative RPCs are a strength, but the audit could not execute live RLS tests.
2. Client-side audience computation is not a safe final authority for consent, eligibility, or cadence.
3. A campaign offer row can exist without a proven message exposure.
4. Allowing a 0% holdout permits the UI to display campaign outcomes without a causal control.
5. Revenue and customer metrics can be numerically correct over an incomplete identified subset while appearing complete.
6. No production data or remote environment was inspected; operational configuration remains unverified.

## False or unsupported claims to remove or qualify

| Claim/surface | Problem | Required wording |
|---|---|---|
| “Net revenue” in identified-customer intelligence | Excludes anonymous/unlinked sales | “Identified-customer net revenue” plus coverage and total known revenue |
| “Cash collected” | Same identified-client limitation | “Identified-customer cash collected” |
| “Returning” | Means 2+ purchases in selected period | Use “Repeat purchaser in this period”; add historical returning/reactivated states |
| “Offers sent” | UI can record issued rows after manual workflow, not provider delivery | “Offers recorded” until delivery is confirmed |
| Campaign result language implying “caused” | Delivery, overlap, sample confidence, and automatic outcome are incomplete | “Estimated incremental revenue” only when holdout requirements pass; otherwise “associated revenue” |
| “AI” growth advice | No production model integration found | “Rule-based recommendation” unless a governed model is actually used |
| Profit, ROI, or value generated | Margin and full costs absent | Use revenue-only terms; do not state incremental profit |

## Five most dangerous false-confidence risks

1. **Subset presented as total:** identified-customer revenue is labelled as business net revenue.
2. **Ambiguous retention:** period repeat purchasers are labelled returning customers.
3. **Recorded offer presented as delivery:** a database row is labelled “sent” without provider evidence.
4. **Correlation presented as causation:** manual outcome recording and optional zero holdout can support an unjustified lift claim.
5. **Revenue presented as economic value:** COGS, discounts, reward cost, message cost, and gross margin are incomplete.

## Three highest-value capabilities already present

1. Tenant-scoped, append-oriented sales/payment/points ledgers with idempotent server RPCs.
2. Verified, ambiguity-safe customer relationship linking across customer and merchant views.
3. Deterministic campaign treatment/holdout membership with a database guard preventing holdout offer issuance.

## Three most important missing foundations

1. A reconciled, coverage-measured canonical transaction stream including anonymous activity and partial refunds.
2. A precise metric/customer lifecycle contract covering total versus identified revenue, new/repeat/returning/reactivated/churn, timezone, and completeness.
3. A delivery-to-outcome event chain with consent enforcement, confirmed exposure, automatic transaction linkage, costs, and confidence.

## Final verdict: direct answers

1. **Can Nestly currently track sales accurately?**
   **Partly.** It can accurately ledger sales entered through its authoritative paths, but it cannot prove complete merchant sales coverage and lacks general partial-refund handling.

2. **Can Nestly currently identify new, returning, loyal, dormant, at-risk and churned customers using clearly defined rules?**
   **No.** Period repeat purchasers are defined, and some lapse thresholds exist, but the complete lifecycle taxonomy is absent or ambiguous.

3. **Can Nestly explain why revenue or repeat behaviour changed?**
   **No.** It reports metrics and generic threshold insights, not a quantified driver decomposition.

4. **Can Nestly currently advise an owner what to do next?**
   **Partly.** It can produce rule-based configuration guidance and a manual bring-back playbook, not a ranked business-specific NBA with confidence and impact.

5. **Are its recommendations grounded in real data or mainly generic rules and generated text?**
   **Mostly deterministic generic rules over some real data.** No production generative-model integration was found, and no outcome-calibrated recommendation engine was verified.

6. **Can the owner execute the recommendation easily?**
   **Not yet.** Execution requires a multi-step campaign flow and manual outreach.

7. **Can Nestly prove that an action caused incremental sales?**
   **Not reliably end to end.** The holdout substrate is promising, but exposure, mandatory control, overlap, confidence, and automatic outcome capture are incomplete.

8. **Can Nestly calculate incremental gross profit, or only revenue?**
   **Only a partial estimated incremental-revenue comparison.** It cannot calculate incremental gross profit.

9. **Is the customer-identification workflow practical for a busy hawker?**
   **Potentially for repeat customers, but unverified under rush conditions.** QR/web joining avoids an app download, yet authentication and linking are synchronous and no latency/funnel instrumentation exists.

10. **Which required insights are impossible with the data currently collected?**
    Incremental gross profit, profit LTV, margin-safe offers, product/category profitability, reliable discount dependence, complete acquisition ROI, weather effects, and complete business-revenue coverage.

11. **What are the five most dangerous false-confidence risks?**
    Identified revenue presented as total; ambiguous returning labels; issued offers presented as sent; associated purchases presented as caused lift; revenue presented as profit/value.

12. **What are the three highest-value capabilities already present?**
    Authoritative append-oriented ledgers; verified identity linking; deterministic treatment/holdout with holdout issuance protection.

13. **What are the three most important missing foundations?**
    Reconciled transaction coverage; canonical metric/lifecycle definitions; delivery-to-outcome event lineage with consent and costs.

14. **What is the single best feature or product loop to build next?**
    Measured Bring-Back Loop v1 described below and in the build plan.

15. **What should Nestly deliberately not build yet?**
    Generative “AI advisor” prose, profit LTV, dynamic pricing, autonomous multi-channel campaigns, weather advice, and dozens of new dashboards before data coverage and attribution close.

16. **What is Nestly currently best described as?**
    **A loyalty analytics dashboard.**

17. **Would a hawker paying from their own pocket have a clear reason to open Nestly every day?**
    **Not yet.** There is no concise daily ranked opportunity and result briefing.

18. **Would the owner be able to see, in dollars, that Nestly generated more value than its subscription and reward costs?**
    **No.** Complete incremental revenue, subscription allocation, reward/discount/message cost, and gross margin are not joined.

## Single recommended next build

Build **Measured Bring-Back Loop v1**:

1. Compute one server-authoritative opportunity: identified customers whose observed visit interval has exceeded a conservative business/segment cadence.
2. Show evidence, data coverage, audience size, historical transaction value, expected incremental-revenue range, confidence, assumptions, expiry, offer cost cap, and exclusions.
3. Recheck consent, opt-out, frequency cap, recent activity, and suppression immediately before execution.
4. Let the owner preview and approve one offer in one screen.
5. Use one supported delivery channel with queued/sent/delivered/failed states and retry.
6. Issue a single-use, expiring entitlement tied to the recommendation, campaign, customer, and transaction.
7. Preserve a deterministic holdout when sample size is adequate; otherwise show associated outcomes only and suppress incremental claims.
8. Automatically record eligible purchases and compute intent-to-treat incremental revenue with a confidence/sufficiency state.
9. Show the owner a plain result: audience, delivery, return, incremental-revenue estimate, reward/message cost, and what Nestly learned.

This is the smallest build that advances the system from analytics toward a measurable growth product without pretending it knows profit.

## Completion confirmation

- No application code, migration, dependency, lockfile, configuration, branch, commit, remote database, production data, message, reward, voucher, or campaign was changed.
- Only the three requested documents under `AUDIT/` were created.
- No browser or production verification is claimed.
- Correlation is distinguished from causation.
- Revenue is distinguished from gross profit.
- Redemption and associated revenue are distinguished from incremental lift.
- The roadmap prioritizes data truth and a closed loop before speculative AI.
- Unverified assumptions are: remote migration state, live data coverage, live RLS behaviour, provider configuration, deployed UI behaviour, SQL numeric runtime behaviour, and real merchant workflow latency.
