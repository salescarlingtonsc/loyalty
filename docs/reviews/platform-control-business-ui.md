# Platform control: business UI implementation report

## Delivered

- Business navigation excludes **Customer intelligence** and **Inventory** for owner, manager, front-desk, and staff roles.
- Typed `#/customerintel` and `#/inventory` routes use the same fail-closed deny-list and return to the dashboard.
- Customer-to-business workspace controls identify the firm by name.
- The business app bar no longer offers a redundant link to the workspace already open:
  - staff-only users with one firm see no switch control;
  - dual-role users see **Customer view**;
  - users with other firm assignments see **Switch workspace**, with the current firm removed.
- Owners get a dedicated **Settings → Checkout catalogue** surface. It can enable/disable catalogue-first checkout and include/exclude existing products and services without exposing stock, suppliers, quantities, costs, or Inventory.
- Owners can inspect the effective list per branch. Services excluded by the existing branch-service availability rule are labelled unavailable and cannot be enabled from the checkout surface.
- Quick Earn is catalogue-first. Staff choose branch-effective products/services, review the server-checked total, then choose the payment method.
- Changing branch clears the cart and price evaluation, then re-reads that branch’s effective catalogue before staff can continue.
- The legacy amount-only form is shown only when the effective firm setting is explicitly false.
- Existing loading, retry, checkout recovery, idempotency, receipt, and fast-correction paths remain intact.

## Exact backend contract

### Workspace gate

`platform_get_business_control_v94` continues to expose:

- `quick_earn_catalogue_enabled`: effective platform-and-owner catalogue gate used for the initial Quick Earn render.

### Read

`business_get_checkout_catalogue_v94(p_business uuid, p_branch uuid, p_include_inactive boolean) returns jsonb`

Response:

- `platform_allowed boolean`
- `enabled boolean`
- `settings_version bigint`
- `selected_branch_id uuid`
- `branches [{id, name, is_default}]`
- `items [{item_type, item_id, name, unit_cents, checkout_active, branch_available, version}]`

Rules:

- `item_type` is only `service` or `product`.
- With `p_include_inactive=false`, return only checkout-active items effective at `p_branch`.
- Service effectiveness must preserve the existing `service_branches` contract: a service with no mappings is available at all branches; a mapped service requires a row for the selected branch.
- Product checkout reads must not require access to the hidden Inventory module.
- An invalid/inaccessible business or branch fails closed.

### Owner writes

- `business_set_checkout_catalogue_enabled_v94(p_business uuid, p_enabled boolean, p_expected_version bigint)`
- `business_set_checkout_catalogue_item_v94(p_business uuid, p_item_type text, p_item uuid, p_active boolean, p_expected_version bigint)`

Both writes are owner-only and use the expected version to reject stale changes. The item setter controls checkout inclusion only; it must not mutate product stock or operational service activation.

## Validation

Passed:

- `node --test tests/business-ui/platform-control-intelligence.test.mjs tests/quality/frontend-role-matrix.test.mjs tests/sales/v84-fast-sale-corrections.test.mjs tests/quality/inline-script-syntax.test.mjs`
- `node --test tests/customer-wallet/phase1-customer-first-class.test.mjs tests/appointments/v47-smart-scheduling.test.mjs tests/customer-modules/v89-customer-journey-frontend.test.mjs`
- `npm run build`
- `git diff --check`

No migration, manifest, commit, push, deployment, production data, or production secret was changed by this business UI phase.
