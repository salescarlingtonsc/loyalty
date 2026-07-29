# End-to-End and Acceptance Test Results

> **MANDATORY DELIVERABLE INCOMPLETE:** the five requested scenarios were not executed as complete fresh disposable-database + browser workflows. This audit executed 157 scenario-specific contract tests and mapped all 12 steps for each scenario, but it did not create five fresh runtime businesses/customers or complete live provider/device steps. Those gaps are explicitly failed or marked “cannot verify” below. A full audit PASS is prohibited until the reproducible scenarios in “Required remaining acceptance” run.

## Test boundary

Evidence used:

- full repository validation: **936/936 tests passed** with the expected project-reference environment;
- independent adoption-critical suite: **98/98 passed**;
- independent customer/frontline suite: **182/182 passed**;
- independent architecture/data suite: **65/65 passed**;
- local browser inspection at desktop and 390×844 mobile viewport;
- production metadata/advisor/cron inspection, read-only;
- prior v93 disposable-database campaign evidence;
- source-to-database/API traces.

These checks do **not** equal:

- a live SMS/email/WhatsApp campaign;
- a provider-settled refund;
- an actual POS transaction;
- a physical iPhone/Android camera/passkey run;
- a real merchant adoption pilot.

## Workflow results

| Workflow | Preconditions and steps | Expected | Actual | Evidence | Result | Adoption impact |
| --- | --- | --- | --- | --- | --- | --- |
| Customer default entry | Open root route at 390px | Customer sign-in first; no horizontal overflow; 44px controls | Customer phone/password/passkey screen; viewport width and scroll width both 390; primary controls 44px | Browser DOM/metrics; `app/index.html` | Pass | Strong mobile first impression |
| QR-only programme link | Valid merchant QR; signed-out customer authenticates | Preserve QR context and auto-link; no business search | Repository contracts enforce invitation-only linking and revoke self-linking | v89 migration/tests | Pass by contract | Correct low-trust linking model |
| Customer first-time registration | QR or create account; phone/password/OTP/profile | Complete and link under 20 seconds | Flow exists; local Turnstile intentionally fails on localhost; actual time not measured | Browser + auth tests | Cannot fully verify | First-use friction remains |
| Normal sign-in | Existing customer/password | No OTP consumed | UI explicitly uses phone/password and normal sign-in sends no OTP | Browser DOM/auth tests | Pass | Avoids recurring SMS cost |
| Passkey sign-in | Registered passkey, supported device | Biometric prompt and session | WebAuthn flow exists; no physical device run in this audit | auth controls/tests | Conditional pass | Good convenience, device acceptance needed |
| Programme selector | Customer linked to multiple firms | Show compact merchant cards and selected programme | v95/v96 customer programme contracts pass | customer UI tests | Pass by contract | Good cross-business wallet |
| Quick Earn existing customer | Staff selects branch/customer/item/tender and saves | One canonical sale, points and receipt | v93 disposable run recorded sale and points; replay safe | v93 launch evidence | Pass | Strong first-party checkout |
| Wrong sale amount correction | Eligible cash quick sale | Double-confirm, append reversal+replacement, wallet sync | v84 contract passes for supported cash cases | v84 migration/tests | Pass with scope limit | Fast recovery for simple mistakes |
| Card/PayNow partial refund | Provider-settled sale | Provider refund + proportional ledger correction | Explicitly rejected/unsupported | v20/v84 | Fail | Broad retail/F&B blocker |
| Full supported reversal | Eligible sale and permission | Immutable reversal, points compensation, reports/wallet reconcile | Reversal/provenance tests pass; v93 evidence shows corrected history | v20/v34/v40/v84 tests | Pass | Strong integrity |
| Customer history | Linked customer opens merchant history | Purchases, corrections, line items and point changes match business | Read model is verified-link scoped and reversal-aware | v81/tests | Pass by contract | High customer trust |
| Reward QR preparation | Customer has enough points | Pending token; no points change | v93 evidence shows pending QR did not change balance | v89/v93 evidence | Pass | Prevents accidental redemption |
| Merchant scan redemption | Assigned branch front desk scans token | Recheck role/branch/programme; one redemption and receipt | v93 disposable evidence: assigned staff accepted, outsiders denied, replay safe | v93 migration/evidence | Strong pass | Defensible differentiator |
| Wrong branch redemption | Token not eligible/actor not assigned | Refuse without balance change | Branch-scoped tests and v93 evidence deny actor | v93 | Pass | Fraud/trust control |
| Customer booking gate | Merchant disables/enables booking | Customer only sees enabled action | Capability tests pass | v89/app tests | Pass | Avoids dead functions |
| Appointment amendment | Permitted staff changes time/staff/details | Durable update and refreshed calendar | v48 contracts cover detail/reschedule | v48 tests | Pass by contract | Strong salon fit |
| Customer opt-out/preferences | Customer changes preferences | Durable consent/preference state; future sends suppressed | Structures/RPC tests pass; real provider suppression untested | v41/v91 tests | Partial | Trust foundation, delivery proof missing |
| Birthday benefit | Merchant enables, customer participates | Hidden when unavailable; activate/redeem with privacy separation | UI/RPC contracts exist; production rows zero | app/v91 production metadata | Implemented, unverified | Promising but no live adoption evidence |
| Inactivity audience | Enough historical transactions | Detect lapsed customers using defined criteria | Criteria and cohorts exist | v50/app tests | Pass by contract | Useful owner action |
| Issue retention offers | Approved audience/reward | Entitlement and verified delivery | Grant rows are recorded; no reward mint/delivery verification; UI says “sent” | v50 + app | **Fail** | P0 false-success |
| Holdout attribution | Treatment/holdout, verified exposure, return sale | Incremental lift after exposure with uncertainty | Deterministic holdout and reversal-aware math exist; exposure and confidence guardrails missing | v50 | Partial/fail for claim | Cannot credibly prove causation |
| Review request | Customer positive experience | Track request and completed review | Public link and click opportunity exist; completion signal absent | feedback UI | Partial | Advocacy loop breaks after click |
| Referral | Valid referrer/new customer/qualified purchase | Prevent self-abuse; reward after qualification | Programme/referral records exist; full qualification/abuse proof incomplete | v41/tests | Partial | Useful but not launch differentiator |
| Multi-outlet operations | Firm with several branches/staff | Consolidated firm view and scoped branch operations | Branch reports/roles/redemption contracts pass | v82/v89/v94 | Pass by contract | Strong chain capability |
| Sector/module assignment | Approved firm and sector | Platform-controlled defaults and firm/branch overrides | Production has seven bundles and six assignments | v94/metadata | Pass | Good operational configuration |
| Subscription lifecycle | Price/subscription/Stripe events | Paid status and next date update automatically | Code/functions real; production billing tables empty | v77/functions/metadata | Cannot verify live | Revenue operations unproven |
| Commission payable | Paid invoice excluding GST/refunds/chargebacks | Versioned rates, anniversary/renewal and employment recheck | v78 contracts implement it; no live accrual cohort | v78/tests | Pass by contract | Strong platform back office |
| Product-adoption funnel | Users complete business/customer/staff milestones | Query activation, retention and drop-off | Required comprehensive event taxonomy is absent | source search | Fail | Product team is flying blind |
| Offline authenticated work | Network drops mid-checkout | Safe recovery or bounded queue | Only public shell caches; authenticated operation requires network | service worker/PWA tests | Fail target | Peak-service resilience risk |

## Browser observations

### Customer entry at 390×844

- no horizontal overflow;
- customer route is the default;
- phone, password, show-password, passkey, create-account and forgot-password controls are exposed;
- visible action buttons meet the 44px touch target;
- local Turnstile returned error `110200`, which is expected for a localhost origin not in the production allowlist;
- the error was explicit rather than a false-success state.

This validates responsive structure, not production authentication.

## Onboarding and frontline measurement record

The brief asks for actual time, click and field measurements. The following is the complete evidence available without mutating production or bypassing Turnstile:

| Journey | Source-derived steps/fields | Actual stopwatch result | Verdict |
| --- | --- | --- | --- |
| Returning customer sign-in | phone + password, or passkey; one submit | Not timed; localhost Turnstile blocks production-auth completion | Cannot verify target |
| First customer account | phone, password, confirm password, legal consent, OTP, profile name/date/language | Not timed end to end | Likely above 20-second target until measured |
| QR programme link for existing signed-in customer | scan/open QR → server claim → programme | Not timed on physical camera | Contract pass, timing unknown |
| Business application/approval | public application → platform approval → invitation/owner activation | No new production/local database firm created | Cannot verify <5-minute owner setup |
| First programme | choose recommended draft → preview → publish; production v96 also exposes multiple settings/submodules | No first-time-owner stopwatch | Cannot verify <15-minute target |
| Normal Quick Earn | open Quick Earn; identify customer; choose item/amount; choose tender; save | No authenticated browser stopwatch | Estimated interaction count is not accepted as timing evidence |
| Reward redemption | open scan; scan customer token; review; confirm | No physical-device stopwatch | Contract/replay/permission pass, speed unknown |
| Campaign | define audience/reward → review/activate → manually contact customers | Real delivery step does not exist | Fails <3-minute automated campaign target |
| First useful insight | requires sufficient complete transaction history and/or campaign outcome | No pilot cohort | Cannot verify |

Missing timing evidence is itself a P1 launch gap. It must be collected in the pilot using event timestamps and screen recordings rather than developer estimates.

## Five executed scenario contract simulations

These are **executed local contract simulations**, not claims that five real merchant businesses completed a live pilot. They exercise the actual migrations, RPC contracts and UI source associated with each scenario. Missing runtime steps are recorded as failures or “cannot verify”; they are not converted into passes.

Executed on 2026-07-29:

| Scenario suite | Command scope | Result |
| --- | --- | ---: |
| Small café | registration, notifications, retention recommendation, customer-module integrity | 32/32 pass |
| Bubble-tea chain | branch redemption, staff modules, correction, reversal provenance | 30/30 pass |
| Salon | scheduling, calendar/reschedule, overdue selectors, booking lifecycle | 34/34 pass |
| Tuition | customer-module hardening, identity, link claims, versioned retention | 31/31 pass |
| Retail | customer relationship/history, reversal workflow, intelligence, detailed wallet | 30/30 pass |

Total: **157/157 scenario-relevant contract tests passed**. This does not erase the functional failures below.

### Scenario 1 — small café

Target: one outlet, three staff, 500 monthly customers, digital stamps, birthday and inactivity.

Primary evidence:

- tests: `c42-consumer-registration`, `v91-customer-game-notifications`, `retention-recommendation`, `v41-customer-module-integrity`;
- tables: `customer_profiles`, `customer_legal_acceptances`, `customer_registration_preferences`, `loyalty_programs`, `retention_campaigns`, `retention_campaign_members`, `retention_campaign_grants`, `retention_campaign_returns`;
- APIs/RPCs: `customer_register_verified_phone`, public QR join, `record_quick_sale`/`record_cart_sale`, `create_retention_campaign`, `activate_retention_campaign`, `issue_campaign_offer`, `get_campaign_results`.

| Required step | Expected | Executed evidence/actual result | Result | Adoption impact |
| --- | --- | --- | --- | --- |
| 1 Configure business | one branch/three scoped staff | sector/module and staff contracts pass; no fresh runtime café row created in this audit | Cannot fully verify | Onboarding time unknown |
| 2 Enrol customers | QR join and verified identity | registration/link contracts pass; first-time stopwatch unavailable because localhost Turnstile is fail-closed | Partial | Join target unproven |
| 3 Record transactions | canonical sale/stamps | Quick Earn/loyalty contract and prior v93 synthetic sale evidence pass | Pass by contract | Core counter flow credible |
| 4 Trigger rewards/campaign | stamp reward + inactivity campaign | programme/recommendation/audience/grant contracts pass | Partial | Grant is not delivery |
| 5 Refund/cancel | safe full/partial/provider handling | full safe reversal contracts exist; partial/provider path rejected | **Fail** | Broad café tender risk |
| 6 Staff permissions | owner/manager/front desk scoped | v41/v74 permission suites pass | Pass | Good control |
| 7 Customer opt-out | durable preference/suppression | preference contracts pass; real-provider suppression absent | Partial | Trust not end-to-end |
| 8 Inactivity detection | lapsed cohort | recommendation/retention criteria contracts pass | Pass by contract | Useful action foundation |
| 9 Customer returns | post-exposure sale | return recording exists; no verified exposure | Partial | Recovery cannot be proven |
| 10 Revenue attribution | holdout incremental result | v50 math exists; contact/exposure and uncertainty absent | **Fail for causal claim** | P0 product truth |
| 11 Owner reporting | honest result and cost | result RPC exists; COGS/net contribution incomplete | Partial | ROI not subscription-grade |
| 12 Record friction | time/clicks/errors | responsive entry measured; authenticated counter timing not performed | Cannot verify | Pilot must measure |

Verdict: **Conditional pilot fit only.**

### Scenario 2 — five-outlet bubble-tea chain

Primary evidence:

- tests: `v93-branch-scoped-redemption`, `v74-staff-module-permissions`, `v84-fast-sale-corrections`, `v34-reversal-provenance`;
- tables: `branches`, `staff`, `staff_branch_assignments`, `sales`, `payments`, `points_ledger`, `points_batches`, `loyalty_redemptions`;
- APIs/RPCs: `record_cart_sale`, `correct_quick_sale_amount_v84`, `reverse_sale`, customer redemption-intent RPC, `merchant_scan_redemption_qr_v93`.

| Required step | Expected | Executed evidence/actual result | Result | Adoption impact |
| --- | --- | --- | --- | --- |
| 1 Configure business | five outlets, role assignments | branch/module contracts pass; no new five-outlet runtime fixture created | Partial | Scale UI not observed live |
| 2 Enrol customers | one identity across outlets | verified link/relationship model supports it | Pass by contract | Strong wallet model |
| 3 Record realistic volume | automated/high-speed transactions | only manual Quick Earn exists; no POS feed/stress volume run | **Fail** | Fatal double-entry risk |
| 4 Trigger rewards/offers | points/tiers/time-limited offer | loyalty mechanics exist; real offer delivery absent | Partial | Engagement incomplete |
| 5 Refund/cancel | partial card/PayNow/split | correction/reversal contracts explicitly reject required matrix | **Fail** | Broad launch blocker |
| 6 Staff permissions | branch staff cannot cross scope | branch/staff/redemption tests pass | Strong pass | Strong fraud control |
| 7 Opt-out | cross-outlet suppression | preference model exists; real send not tested | Partial | Fatigue risk |
| 8 Inactivity detection | chain/branch cohort | intelligence and retention scopes support branch/firm | Pass by contract | Useful chain insight |
| 9 Customer returns | any eligible outlet | canonical return possible if sale recorded | Partial | Data capture dependency |
| 10 Revenue attribution | exposure/branch-aware lift | holdout math exists; delivery absent | **Fail for causal claim** | Cannot prove chain ROI |
| 11 Owner reporting | consolidated + branch | v82/v83/v94 report contracts exist | Pass by contract | Premium potential |
| 12 Peak/fraud stress | concurrency/replay/wrong branch | QR replay/branch checks pass; real 500+ transaction peak test absent | Partial | Device/volume risk |

Verdict: **Fail for broad chain launch.**

### Scenario 3 — salon

Primary evidence:

- tests: `v47-smart-scheduling`, `v48-calendar-details-reschedule`, `v87-overdue-amendments-and-selectors`, `v73-booking-lifecycle`;
- tables: `appointments`, `booking_requests`, `services`, `branches`, `staff`, `clients`, packages/memberships;
- APIs/RPCs: public booking Edge Function, booking lifecycle RPCs, `reschedule_appointment_v48`, Quick Earn/sale RPCs, customer actionable-wallet and birthday RPCs.

| Required step | Expected | Executed evidence/actual result | Result | Adoption impact |
| --- | --- | --- | --- | --- |
| 1 Configure business | services/staff/branch | service/staff/appointment contracts pass; no fresh runtime salon fixture | Partial | Setup timing unknown |
| 2 Enrol customers | QR identity | join contracts pass | Pass by contract | Good |
| 3 Record transactions | service and staff attribution | itemised sale/staff data supported | Pass by contract | Good |
| 4 Trigger reward/reminder | birthday/rebooking cadence | benefit/cadence logic exists; outbound reminder absent | Partial | Owner still contacts |
| 5 Cancel/refund | booking cancellation and payment refund | booking lifecycle passes; provider payment refund incomplete | Partial/fail | Financial exception risk |
| 6 Staff permissions | assigned staff/manager controls | scheduling/module permission tests pass | Pass | Strong |
| 7 Opt-out | no marketing after withdrawal | contracts exist; provider suppression unverified | Partial | Trust gap |
| 8 Inactivity detection | overdue after usual 4–8 weeks | v87/cadence logic covers overdue reasoning | Pass by contract | Strong vertical fit |
| 9 Customer returns | rebook and complete | booking/appointment lifecycle exists | Pass by contract | Strong |
| 10 Revenue attribution | reminder exposure → service sale | exposure missing | **Fail for causal claim** | Cannot prove reminder value |
| 11 Owner reporting | customer frequency/revenue/forecast | v83 intelligence supports it; owner route hidden | Partial | Consultant-led only |
| 12 Friction | reschedule speed/mobile | 34 contracts pass; no physical-device stopwatch | Cannot fully verify | Pilot measure |

Verdict: **Best pilot fit; conditional pass.**

### Scenario 4 — tuition centre

Primary evidence:

- tests: `v41-customer-module-hardening`, `identity-foundation`, `links-claims`, `versioned-retention`;
- tables: `customer_identities`, `customer_profiles`, `customer_business_links`, `clients`, packages, memberships, referrals;
- APIs/RPCs: verified-phone registration/claim, customer-module save RPCs, package/membership operations, referral programme RPCs.

| Required step | Expected | Executed evidence/actual result | Result | Adoption impact |
| --- | --- | --- | --- | --- |
| 1 Configure business | centre/classes/terms | generic modules only; no course/term/attendance model | **Fail vertical fit** | High custom workaround |
| 2 Enrol families | guardian + siblings | individual phone identity works; household graph absent | **Fail** | Fragmented relationship |
| 3 Record monthly payments | recurring student account | packages/memberships partial; no tuition payment lifecycle | Partial/fail | Manual finance |
| 4 Trigger referral | qualified family referral | referral records/programmes exist | Partial | Qualification/abuse incomplete |
| 5 Refund/cancel | partial term refund | refund matrix incomplete | **Fail** | Material |
| 6 Staff permissions | teacher/admin boundaries | generic module roles pass; no teacher/course scope | Partial | Wrong abstraction |
| 7 Opt-out | guardian preference | individual consent model exists | Partial | Household ambiguity |
| 8 Inactivity detection | term/lifecycle risk | generic lapsed threshold only | Partial | Weak relevance |
| 9 Customer returns | re-enrol next term | generic transaction return only | Partial | No term context |
| 10 Revenue attribution | referral/campaign → enrolment | exposure and qualified lifecycle incomplete | **Fail** | Cannot prove |
| 11 Owner reporting | family/course retention | generic client intelligence only | **Fail vertical requirement** | Low willingness to pay |
| 12 Operational friction | attendance/class usage | not implemented | **Fail** | Not a tuition product |

Verdict: **Fail as a tuition vertical.**

### Scenario 5 — retail shop

Primary evidence:

- tests: `v81-customer-relationship-sync`, `v40-staff-reversal-workflows`, `v83-customer-intelligence`, `detailed-wallet`;
- tables: `sales`, sale line items, `payments`, `points_ledger`, `customer_identities`, `customer_business_links`, `customer_intelligence_exports_v83`;
- APIs/RPCs: `record_cart_sale`, `reverse_sale`, `customer_sync_verified_relationships_v81`, `customer_get_transaction_history_v81`, `get_customer_intelligence_v83`.

| Required step | Expected | Executed evidence/actual result | Result | Adoption impact |
| --- | --- | --- | --- | --- |
| 1 Configure business | products/categories/outlet | catalogue/itemised sale contracts exist; runtime fixture not created | Partial | Setup unmeasured |
| 2 Enrol customers | online/offline identity | QR/phone identity works; online identity ingestion absent | Partial/fail | Channel fragmentation |
| 3 Record transactions | POS/e-commerce + store | manual cart sale only | **Fail** | Double-entry |
| 4 Trigger personalised reward | category preference | line items/intelligence exist; category action workflow limited | Partial | Weak personalisation |
| 5 Refund/return | line-level partial/provider | reversal contracts pass only narrow supported flow | **Fail** | Broad retail blocker |
| 6 Staff permissions | branch/manager/front desk | permission/reversal tests pass | Pass | Strong |
| 7 Opt-out | suppress real communications | model exists; provider absent | Partial | Unverified |
| 8 Inactivity detection | category/recency cohort | intelligence supports recency/value, not mature category workflow | Partial | Directional |
| 9 Customer returns | online/offline purchase | only if transaction reaches Nestly | Partial | Coverage dependency |
| 10 Revenue attribution | verified exposure → net margin | exposure/e-commerce/margin missing | **Fail** | Cannot prove |
| 11 Owner reporting | category/customer/branch | v83 report/export contracts pass | Pass by contract | Useful advisory |
| 12 Duplicate resolution | merge fragmented profiles | sync avoids some duplicates; mature merge absent | **Fail** | Customer history fragmentation |

Verdict: **Fail for broad retail launch.**

## False-success register

1. **“Offers sent”** when only grants were recorded.
2. **“Brought back”/lift result** when exposure may not have occurred.
3. **Synthetic captured message “delivered”** is test-provider evidence only, not a real provider receipt.
4. **Active cron/outbox** does not prove delivery.
5. **Stripe-ready UI/code** does not prove live billing because production billing rows are empty.

## Required remaining acceptance

Before broad launch:

1. iPhone Safari/PWA + Face ID/passkey + camera join/redeem;
2. Android Chrome/PWA + camera join/redeem;
3. 30 concurrent Quick Earn/replay/slow-network tests;
4. full cash/card/PayNow/split/partial/full refund matrix;
5. real provider queue/delivery/failure/opt-out/duplicate callback;
6. one real transaction ingestion connector;
7. billing invoice/renewal/failure/refund/chargeback rehearsal;
8. 10–20 SME measured pilot.
