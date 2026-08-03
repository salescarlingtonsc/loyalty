# Mandatory role journeys

These are end-to-end acceptance journeys, not page inventories. A page-level
test cannot replace the cross-role journey when the same value crosses roles.

## Journey A — QR join and first customer home

1. Owner enables signups and obtains the current business QR.
2. `CUS-NEW` scans it on a mobile viewport.
3. Customer creates an account with consent, password, and one OTP, or signs in
   to an existing account without OTP.
4. The original join intent survives authentication.
5. One business relationship is created.
6. The customer lands on that programme's clear home, not an empty generic
   dashboard.
7. A second scan is idempotent.
8. Disabling signups produces an honest inactive-link state without creating a
   relationship.

## Journey B — owner configuration to customer projection

1. `SPA-GLOW` owner configures logo, programme, module toggles, booking policy,
   reward, service variants, and package.
2. Reload owner workspace and verify persistent values.
3. Front desk operates only the effective branch/module set.
4. `CUS-MEI` reloads the portal.
5. Logo, enabled programme content, correct variant/package values, and allowed
   booking actions appear.
6. Birthday/gift/booking sections that are disabled or unconfigured do not
   appear.

## Journey C — catalogue sale, points, and correction

1. Front desk searches duplicate Lee customers by phone.
2. Select `CUS-LEE-A`, branch, and a real service variant.
3. Confirm the exact amount and expected points.
4. Simulate a response loss after the persistent write, then retry.
5. Verify one sale and one points effect.
6. Customer history shows amount, item, business, branch, and points.
7. Perform a fast double-confirm correction/reversal.
8. Business and customer histories retain the relationship and resulting
   balance.

## Journey D — package purchase and use

1. Owner creates 5x Spa 60 at SGD 270 against SGD 300 list value.
2. UI shows SGD 30 and 10% savings.
3. Owner chooses whether package purchase earns points.
4. Staff sells it to `CUS-MEI`; purchase history and points follow the chosen
   policy.
5. Customer sees 5/5 sessions and exact eligible service variant.
6. On a later visit, Quick Earn shows the owned package and uses one session
   without recording another SGD 60 paid sale.
7. Customer reload shows 4/5.
8. Wrong variant, wrong branch, retry, double use, used-up, and restore-session
   cases are verified.

## Journey E — gift issuance disabled, existing value retained

1. Owner disables new gift-card issuance.
2. New-card controls disappear from owner/staff checkout and direct issuance is
   denied.
3. `CUS-ARUN` keeps an existing $50 gift.
4. Staff can apply eligible existing value.
5. Partial spend, reversal, and customer history remain consistent.

## Journey F — pending reward QR redemption

1. `CUS-MEI` chooses an affordable reward.
2. Customer receives a pending, expiring QR; points do not change yet.
3. Wrong firm/branch cannot redeem it.
4. Authorized staff scans and confirms once.
5. A concurrent or repeated scan is idempotently rejected.
6. Customer receives the success state/history/notification and the exact new
   balance.

## Journey G — appointments and customer booking

1. Owner enables customer booking for Orchard only.
2. Customer requests an eligible service/time.
3. Front desk sees the request, distinguishes customer by phone, assigns a named
   staff member, and amends the time.
4. Customer sees the updated status/time after reload.
5. No-show, complete, and cancel follow permissions and produce correct
   histories.
6. Turning booking off hides future customer booking actions without deleting
   existing appointment history.

## Journey H — module and role boundaries

Run direct navigation and API action checks for:

- owner, manager, front desk;
- Super Admin, configurable Admin;
- assigned and unassigned Sales/Consultant;
- customer and dual-role user.

Verify sector template, firm override, branch override, and staff subset in that
order. A hidden navigation item without server-side denial is a failure.

## Journey I — platform onboarding, intelligence, billing, commission

1. Super admin lands on Today and sees each submitted application, blocked or
   overdue onboarding case, late billing account, payable commission, and
   system incident once, with reason, status, age, SLA, responsible owner, and
   one primary action. Healthy/paid records do not appear as work.
2. Sales staff lands on its own Today and sees only firms it created or was
   assigned.
3. A public self-service owner creates and confirms an account, chooses the
   business/sector, annual or monthly billing and customer capacity, and sees
   the exact server-derived recurring amount before Stripe Checkout. This path
   does not request super-admin approval.
4. Checkout creation, cancellation or an unpaid subscription leaves the new
   workspace payment-locked. Only the matching signed, normalized paid invoice
   opens it; refresh enters guided setup.
5. A consultant-led assisted firm may still appear in platform onboarding;
   assigned consultants can manage that separate path and unassigned
   consultants cannot.
6. A paid self-service or approved assisted firm appears as won/active with all
   branches and customers.
7. Consultant generates branch and whole-firm intelligence with source window,
   data sufficiency, and actionable recommendations.
8. Billing success sets paid/next date; overdue schedules daily notices and day
   14 access pause; payment restores access.
9. GST/refund/chargeback and anniversary/employment cases produce expected
   commission.
10. A new `SPA-GLOW-BILLING` owner sees annual selected by default, reads the
    included modules/exclusions, selects 1,000 or 3,000 customer capacity, and
    sees the exact recurring total before Stripe Checkout. No staff quantity is
    requested or billed.
11. Monthly 1,000/3,000 totals are SGD 149/169; annual 1,000/3,000 totals are
    SGD 1,188/1,428. An increase requests immediate provider proration but stays
    pending when payment confirmation or SCA is outstanding. Neither cadence
    nor capacity commands can decrease capacity.
12. For Terms accepted before 3 August 2026, the earliest successful paid
    invoice for the matching V124 provider subscription fixes one 30-day
    refund-request deadline; a matching earlier invoice is backfilled and an
    unrelated legacy renewal is excluded. For Terms accepted on or after
    3 August 2026, that same first-paid evidence activates access but does not
    create a refund window. Cadence/capacity changes, cancellation,
    reactivation, duplicate events and lost-response retries reuse exact
    evidence and do not move it. A refund is never represented as approved or
    paid until the provider event confirms it, and mandatory rights remain
    unaffected.
13. If payment confirmation remains pending, the same command recovers after
    its webhook projects the requested capacity. A later catalogue rollover
    cannot alter that command's snapshotted Stripe prices. Terminal failed or
    canceled commands display failure and require a new request rather than
    claiming successful submission.
14. While Nestly is not GST-registered, owner checkout, invoice history and
    platform billing all show `GST not charged` with SGD 0.00 tax; amount due
    equals subtotal. Catalogue activation rejects inclusive/unspecified Stripe
    Prices and Checkout keeps automatic tax disabled.
15. A provider invoice due on day 0 produces one daily notice; owner access is
    still open through day 13 and pauses at day 14. Customer value/history and
    customer access remain intact. A causally newer paid event restores owner
    access and the platform/owner next-payment projection after refresh.

## Journey J — navigation, language, and mobile resilience

1. Switch business workspace between English, Simplified Chinese, and Malay.
2. Traverse every enabled route by left navigation without hard refresh, blank
   content, auto-scroll, or lost draft.
3. Repeat with slow network, failed chunk, refresh, back/forward, and reconnect.
4. Run critical customer and staff paths at 390px and 412px viewports.
5. Verify touch targets, keyboard overlap, safe areas, camera denial/retry,
   notification denial, and passkey cancel/unsupported behavior.
6. Build the one-source native iOS and Android projects, verify universal/app
   links and permission copy, and run cold start, authentication, QR, offline,
   resume and update flows on physical devices before store submission.
7. Record Apple/Google signing teams, bundle/application IDs, archive hashes,
   store privacy/support metadata and review results. A simulator, PWA install,
   or unsigned wrapper alone does not satisfy publication readiness.

## Journey K — owner promotion to customer programme

1. `SPA-GLOW` owner starts a promotion and enters only these facts: 30% off Spa
   Ritual 60, National Day, valid through 30 August 2026.
2. The free copy assistant produces concise Singapore-English headline/body
   copy and one approved CTA without changing or inventing any number, date,
   product, eligibility rule, price, scarcity, or claim.
3. Owner edits the proposed copy, saves a draft, uploads an owned image with
   alt text, previews, and explicitly publishes.
4. Manager and front desk direct publish/image-write attempts are denied.
   Super admin may inspect the state and manage the launch entitlement, but a
   fresh merchant-authored promotion still requires the business owner; support
   may only replay an already-recorded exact receipt.
5. The linked customer reloads the selected programme. Business identity and
   formatted points occupy one compact header; up to two currently active
   promotion cards appear before supporting catalogue content.
6. A third eligible offer is not returned to the customer projection. Promotion
   authoring and reading are company-wide and reject non-null branch input;
   future, expired, inactive, and other-business offers do not leak.
7. Ten first-published offer slots are allowed during the complimentary
   authoring window. Unpublishing does not restore a slot; an eleventh and a
   new publish after 31 October 2026 are refused unless the platform
   entitlement extends the allowance.
8. Existing published offers continue to obey their own start/end dates when
   the complimentary authoring window ends.
9. Failed image upload, lost response, retry, double tap, refresh, back/forward,
   and 390px/412px layouts preserve an understandable draft or published state.

## Journey L — merchant onboarding to fixed PayNow receipt

1. `CAFE-HARBOUR-PAYMENTS` owner opens Settings -> Payments and selects **Set up
   Stripe**. Peekaa creates or reuses the business's connected account and opens
   a single-use Stripe-hosted onboarding link; the owner supplies legal,
   representative and payout-bank information only to Stripe.
2. Returning from an incomplete or expired session shows **More information
   needed** and a resume action. Only provider-reported ready capabilities show
   **Ready to accept payments**. Manager/front desk cannot create or rebind an
   account; another merchant cannot see the provider identifier.
3. At Tanjong Pagar, authorised staff chooses `CUS-MEI`, adds Harbour Lunch Set
   and accepts the authoritative SGD 10.00 evaluation. **PayNow QR** asks the
   server for one payment under Harbour's connected account. The returned QR
   displays SGD 10.00 and the merchant/branch; amount and merchant are not
   editable. The same exact server evaluation remains held for Stripe's full
   one-hour QR payment window, and any direct-finalise attempt from another tab
   fails without a sale, points or inventory effect.
4. Before a signed success event, the screen says Awaiting payment and no sale,
   payment, stock, points or paid receipt exists. Refresh/reconnect recovers the
   same attempt. Cancel, expiry and provider failure retain the cart and allow a
   safe replacement attempt.
5. The exact signed success event for Harbour, SGD and 1,000 cents atomically
   consumes the evaluation and creates one sale/payment/economic result. A
   duplicate or older event returns the same result without a second effect;
   wrong account/amount/currency/business is quarantined and finalises nothing.
   Refund creation remains pending until a signed `refund.updated` succeeds;
   `refund.failed` tells staff to resolve the refund manually in Stripe, and a
   delayed API response cannot overwrite that signed failure.
6. Staff sees Paid and one **Print receipt** action. The receipt shows Harbour
   Kopi, Tanjong Pagar, Singapore paid time, safe references, items, discounts,
   GST truth, SGD 10.00 and PayNow; it excludes Peekaa service-phone details.
   Customer history/points reflect the same sale after refresh.
7. Repeat with `SPA-GLOW-PAYMENTS` and SGD 88.00 to prove that two merchant
   accounts, attempts, webhook events, receipts and settlements never cross.
