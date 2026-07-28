# V95 customer programme experience — frontend implementation record

Date: 2026-07-28  
Builder scope: customer frontend, focused tests, and the narrow media CSP allowlist only.

## Outcome

The customer portal now uses a selector-first model for accounts linked to multiple businesses. Selecting a business opens a merchant-specific programme home with its own logo, hero treatment, live balance, points/stamps unit, tier progress, next reward, benefits, birthday/seasonal offers, and programme switching. Existing transaction, points, activity, gift-card, package, membership, appointment, feedback, and message feeds remain below the programme summary so the richer presentation does not replace financial or activity truth.

Accounts with no programmes render one QR-join quest. They cannot search for or self-link a business.

## Contract integration

The frontend consumes these V95 RPCs exactly:

- `customer_get_locale_preference_v95()`
- `customer_set_locale_preference_v95(p_locale, p_expected_version)`
- `customer_get_business_presentation_v95(p_business, p_branch, p_locale)`

The presentation response is adapted with existing wallet/business data as a safe fallback. A presentation failure leaves authoritative wallet balances and activity available, shows a retry control, and does not enable booking.

Customer booking is shown only when both the existing owner action contract and `capabilities.booking_enabled` permit it.

## Locale behaviour

- Supported UI locales: English and Simplified Chinese.
- Initial default: browser preference.
- Signed-in preference: loaded from the V95 locale RPC.
- Writes use the returned version as an optimistic concurrency token.
- Every `ct()` lookup falls back to the English dictionary, then to the key.
- The language switch lives in the top-right profile menu and is available in the zero-programme state.

Business-authored programme, reward, benefit, and offer copy is supplied already localized by the presentation RPC.

## Media boundary

Only the configured Supabase origin and the public `business-public` bucket are accepted. Object paths must match:

`<business_uuid>/<logo|hero|programme|reward|product|service|benefit|offer>/<asset_uuid>.<png|jpg|jpeg|webp|gif>`

Arbitrary remote image hosts and other Supabase object paths are discarded. The Content Security Policy adds only the configured Supabase HTTPS origin to `img-src`.

## Interaction and accessibility

- Customer navigation remains four destinations with a fixed mobile bottom bar.
- Profile and notifications stay in the top-right header.
- Navigation, account, locale, scan, retry, and booking actions retain at least 44px targets.
- Offer/perk image dimensions are reserved before load.
- Motion uses transform/opacity transitions and the existing reduced-motion override.
- Celebration audio defaults off, requires an explicit profile opt-in, remains session-scoped, and is blocked when reduced motion is requested.
- Loading, empty, partial-error fallback, and retry states are explicit.

## Verification

Focused behavioural coverage:

- `tests/customer-wallet/v95-bilingual-programme-ui.test.mjs`
- `tests/customer-modules/v89-customer-journey-frontend.test.mjs`
- `tests/customer-wallet/phase1-customer-first-class.test.mjs`
- `tests/customer-wallet/gold-ux-p0-remediation.test.mjs`
- `tests/customer-modules/customer-enterprise-ui.test.mjs`
- `tests/customer-wallet/c42-luna-adversarial.test.mjs`
- `tests/quality/inline-script-syntax.test.mjs`

No migration was applied, no production data changed, and no deploy/push/commit was performed by this builder.
