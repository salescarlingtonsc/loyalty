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

1. Website firm request appears in platform onboarding.
2. Assigned consultant can manage it; unassigned consultant cannot.
3. Owner cannot activate before Super Admin approval.
4. Approved firm appears as won/active with all branches and customers.
5. Consultant generates branch and whole-firm intelligence with source window,
   data sufficiency, and actionable recommendations.
6. Billing success sets paid/next date; overdue schedules daily notices and day
   14 access pause; payment restores access.
7. GST/refund/chargeback and anniversary/employment cases produce expected
   commission.

## Journey J — navigation, language, and mobile resilience

1. Switch business workspace between English, Simplified Chinese, and Malay.
2. Traverse every enabled route by left navigation without hard refresh, blank
   content, auto-scroll, or lost draft.
3. Repeat with slow network, failed chunk, refresh, back/forward, and reconnect.
4. Run critical customer and staff paths at 390px and 412px viewports.
5. Verify touch targets, keyboard overlap, safe areas, camera denial/retry,
   notification denial, and passkey cancel/unsupported behavior.
