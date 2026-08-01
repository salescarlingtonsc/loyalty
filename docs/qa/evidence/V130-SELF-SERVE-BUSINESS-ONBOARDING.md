# V130 self-service business onboarding

Date: 2026-08-01
Branch: `codex/v129-trial-test`
Requirement: `SELF-SERVE-ONBOARD-001`

## Reproduction

The current production source reproduces the complaint before implementation:

- `renderAuth('up')` routes to `renderBusinessApplication()` rather than
  creating an owner account.
- The public form says **Apply for a Nestly business account**, **Submit for
  approval**, and that a super admin must approve the request.
- `public-business-application` writes an application only; it does not create
  an Auth account, subscription selection, Stripe Checkout or usable workspace.
- `create_business` is deliberately denied, while
  `activate_approved_business_application_v95` requires a super-admin-issued
  invitation.
- `renderOnboard()` repeats **An approved invitation is required**.
- V124 plan selection and Stripe Checkout exist only in Settings inside an
  already open owner workspace. A new public owner cannot reach them.

The existing regression named **new firms cannot create owner access before the
super-admin application approval route** passes on the predecessor and proves
the reported behavior is real rather than inferred from copy alone.

## Acceptance contract

The corrected journey is confirmed account -> business/sector/options -> exact
server-derived price -> Stripe Checkout -> provider-confirmed paid invoice ->
usable workspace. Workspace creation before Checkout is a locked staging record,
not access: Checkout Session creation, success-page return, cancellation,
expiration, an unpaid subscription, or browser-supplied amount cannot activate
it. Exact retries reuse the same setup and billing identities.

## Implemented contract

- Public business signup creates a Supabase Auth owner account and records the
  business-owner/locale intent; the consultant-issued approved invitation path
  remains available as a separate assisted-sales journey.
- A confirmed owner chooses name, business, UEN, published sector, workspace
  address, annual/monthly cadence and 1,000-customer capacity blocks.
- Browser amounts are display only. The database selects the active reviewed
  V124 catalogue and published sector bundle, then creates exactly one locked
  staging workspace, owner, default branch and incomplete Stripe subscription.
- Checkout requests persist one server-priced billing command. Pending,
  uncertain and still-live Checkout sessions replay; explicit failure or a
  conservatively expired 23-hour command rotates once without duplicating the
  workspace.
- `claim_billing_command_v130` preserves the V124/V77 dispatcher and identifies
  self-service return routes. Existing owners still return to Settings.
- Checkout success, cancellation, abandonment or an invoice for another
  subscription cannot open access. Only a matching provider-paid invoice that
  creates the V124 immutable money-back window activates the workspace, sector
  assignment and editable draft loyalty preset.
- The V94 manual approve/reject writer is blocked by a control-table trigger
  while a self-service workspace is payment-pending, and Firm 360 identifies
  that state without rendering either decision button.
- Activation verifies the snapshotted catalogue, selected cadence and capacity,
  provider Price IDs, exact SGD subtotal/total/due/paid amount, zero tax and zero
  remaining balance. Wrong price, cadence, capacity, tax, total or balance stays
  locked.

## Local evidence

- `node --test tests/business-ui/v130-self-serve-business-onboarding.test.mjs`
  passes the account/setup/payment-boundary/Stripe-return contract.
- PostgreSQL parsing passes for the V130 canonical migration and rollback suite
  via `pglast`.
- Canonical and planning migration manifests pass with 169 canonical entries
  and 124 pending migrations.
- `EXPECTED_SUPABASE_PROJECT_REF=gadpooereceldfpfxsod npm test` passes all 1,375
  Node tests.
- The production static quality baseline, runtime configuration check and static
  build all pass with the expected Singapore Supabase project reference.
- The current production render functions are extracted into the deterministic
  V130 browser harness. Chromium passed signup, setup, pending and workspace
  control at 1,440px and signup/setup/pending at 390px with no console errors,
  no horizontal overflow and a minimum 44px visible button height.
- At 390px the signup language control re-rendered the current production
  component in Chinese and Bahasa Melayu, including one non-duplicated localized
  legal-consent sentence; viewport and scroll width both remained 390px.
- The executed Firm 360 governance renderer shows the payment-managed message
  and zero manual decision buttons on first paint for a self-service firm, while
  the assisted-onboarding fixture retains both approval decisions.
- Independent Sol re-review accepted the corrected candidate with no P0-P3
  findings after independently running the V130/platform/browser focused set
  (18/18) and confirming the canonical migration mirror.
- Browser interaction checks produced `radiant-skin-studio`, annual 3,000 total
  `SGD 1428.00 / year`, monthly 3,000 total `SGD 169.00 / month`, rejected a
  missing legal consent, and called the setup plus Checkout RPC sequence.
- Screenshots are in `docs/qa/evidence/v130-self-serve-browser/`.

## Database rehearsal closure

On 1 August 2026 the existing non-production Supabase `migration-rehearsal`
branch was advanced through V132. The first V130 rollback execution reproduced
`owner loyalty configuration access required` when provider-paid activation
seeded the draft preset without the locked owner claims. V132 now uses only the
active owner recorded on the locked onboarding row for that governed insert,
restores the prior provider claims in the same transaction, and changes no C45
predicate, RLS policy, table grant or browser RPC grant.

`db/tests/v130_self_serve_business_onboarding.sql` then passed with the exact
annual 3,000 / SGD 1,428.00 zero-tax invoice, owner-authored draft version,
wrong-payment denial, provider-claim restoration, replay and rollback. Queries
after V129/V130/V131 returned zero synthetic Auth users, businesses and account
deletion requests. The repository gate passes 1,381/1,381 plus build.

## Remaining evidence

Stripe test-mode Checkout, signed webhook/provider evidence, independent V132
review, release approval, production migration/deployment and production smoke
remain. The lifecycle therefore remains `IMPLEMENTED_UNVERIFIED`, not closed
or live-ready.
