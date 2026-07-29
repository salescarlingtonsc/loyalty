# Nestly v99-v100 campaign truth and adoption evidence

Status: local review candidate. These migrations do not authorize a production
push, database migration, or deployment.

## Why this exists

The earlier retention result path could count a return without proving that the
treatment customer received an offer. It also exposed derived lift fields before
the platform had a statistical test that could support a causal statement.

v99 changes the contract from “grant implies exposure” to an evidence ladder:

1. a customer is assigned to a frozen campaign arm;
2. a treatment customer receives a real, same-customer reward entitlement;
3. an immutable exposure record is confirmed;
4. a common measurement window is sealed after the final treatment exposure;
5. only qualifying returns inside that window are attributed;
6. results remain descriptive and inconclusive until a future reviewed
   statistical contract is implemented.

Legacy grants and v50 return rows are not backfilled as exposures. Their
delivery state is `unknown`, and `legacy_v50_return_evidence_used` is always
false in the v99 result contract.

## v99 write and read contracts

### `issue_campaign_offer`

`public.issue_campaign_offer(uuid,uuid,uuid,text,bigint,uuid)` keeps the deployed
signature for compatibility, but the final UUID argument must be null. The
server verifies the active campaign, treatment assignment, exact active
published retention version, budget, customer, and tenant. It then creates the
`reward_grants` entitlement and the linked campaign grant atomically.

The result separates the facts:

- `customer_history_visible=true`: the reward grant is visible through the
  existing customer activity/history projection;
- `economic_value_posted=false`: issuing the campaign offer does not create
  points or store-credit ledger value;
- `redemption_mode=merchant_fulfilment_pending`: the entitlement still requires
  the merchant's fulfilment workflow;
- `exposure_status=awaiting_manual_attestation`: issuance is not evidence that
  the customer saw or received it;
- `delivery_provider_status=not_configured`: no provider delivery is claimed.

Exact replay returns the same campaign and reward grant. A changed entitlement
envelope, cross-customer link, holdout member, stale configuration, or exhausted
budget fails. If that grant was already manually attested, an offer replay
returns `exposure_status=verified` plus the immutable exposure identity, time,
and channel; it does not send the owner through attestation again.

### `attest_campaign_exposure_v99`

`public.attest_campaign_exposure_v99(uuid,uuid,uuid,text,boolean,text,timestamptz,jsonb)`
is the only browser-callable exposure writer. It requires owner access,
retention write permission, and `confirmed=true` after the owner actually shows
or sends the offer. The campaign grant, campaign, business, customer, and reward
grant are structurally linked. A reward must be granted or redeemed and must
predate the exposure.

The only currently accepted evidence kind is `manual_confirmation`. No SMS,
email, WhatsApp, push, or other delivery-provider receipt is claimed. The result
states `delivery_provider_status=not_configured`.

The business-scoped idempotency key and request hash make exact retries return
the original exposure while changed envelopes fail. Evidence context is part of
that exact envelope: reusing the same key with changed context conflicts. The
campaign-grant identity is a second recovery anchor: after a page reload, the
wrapper returns the existing same-channel, same-context attestation even if the
browser lost its first idempotency key.

`public.record_campaign_exposure_v99(...)` is the internal evidence writer.
Browser roles have no execute privilege on it.

### `seal_campaign_measurement_v99`

`public.seal_campaign_measurement_v99(uuid,uuid,text,integer)` requires every
treatment member to have a verified, same-customer entitlement and exposure,
and requires a non-empty holdout arm. The common-arm start is the later of
campaign activation and final verified exposure. The minimum sample is bounded
from 10 to 10,000.

### `record_campaign_returns`

`public.record_campaign_returns(uuid,uuid)` writes append-only v99 attribution
rows only after the measurement window has been sealed. Sales before the common
start or outside the common end do not qualify.

### `get_campaign_results`

`public.get_campaign_results(uuid)` can return:

- `awaiting_verified_exposure`
- `collecting`
- `inconclusive_minimum_sample`
- `inconclusive_statistical_test_not_implemented`

Minimum sample sufficiency is reported separately from evidence quality.
`net_lift_bps`, `incremental_returns`, and `incremental_revenue_cents` are null.
No response claims statistical significance or causal proof.

## v100 adoption event contract

The browser may submit only these exact interaction events through
`public.record_product_interaction_v100(text,uuid,uuid,uuid,text,timestamptz,jsonb)`:

- `merchant.workspace_viewed`
- `merchant.grow_opened`
- `merchant.grow_draft_started`
- `merchant.counter_action_opened`
- `merchant.counter_action_started`
- `merchant.redemption_scan_started`
- `customer.programme_viewed`

These events prove only that a UI interaction was accepted. Every result says
`recording_status=accepted_interaction_only` and
`business_outcome_asserted=false`.

The allowed context keys are `action_key`, `entry_point`, `locale`,
`device_class`, `install_mode`, `surface_version`, and `outcome`. Values must be
scalars, strings are at most 80 characters, and the whole context is at most
2 KiB. Names, email addresses, phone numbers, postal addresses, tokens, search
terms, queries, free text, and raw routes are not accepted.

Economic or completed outcomes are database-authored from canonical writes:

| Event | Canonical source |
| --- | --- |
| `customer.qr_join_completed` | `customer_link_audit_events` |
| `customer.booking_submitted` | `booking_requests` |
| `sale.recorded` | original `sales` row |
| `sale.reversed` | reversal `sales` row |
| `loyalty.redemption_completed` | `loyalty_redemptions` |
| `billing.invoice_paid` | paid transition in `billing_provider_invoices` |
| `campaign.exposure_verified` | v99 exposure |
| `campaign.return_attributed` | v99 attribution |

Server source identity is unique by source table, source row, and event name, so
trigger retries cannot duplicate evidence.

## Access and retention

The v99 evidence tables and v100 event/taxonomy tables use row-level security.
The raw v100 event table is not readable from a browser role. Merchant writes
require tenant membership plus the appropriate module and branch permission.
The aggregate adoption summary permits authorized merchant finance readers,
scoped platform reporting roles, or super admins.

Raw adoption events have a 400-day retention deadline. If `pg_cron` is present,
the migration installs one bounded daily job named
`nestly-v100-adoption-retention-daily`, scheduled at `40 19 * * *`, which calls
`public.purge_product_adoption_events_v100(5000)`. Databases without `pg_cron`
receive an explicit migration notice and require an external scheduler before
release.

## Release checks

Run:

```sh
node --test tests/grow/v99-v100-campaign-truth-adoption.test.mjs
```

Then apply v99 and v100 to a disposable database containing the final canonical
chain and execute:

```sh
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 \
  -f db/tests/v99_v100_campaign_truth_adoption.sql
```

The SQL suite is rollback-only. It verifies tenant isolation, exact replay,
changed-envelope rejection, cross-customer entitlement rejection, exposure
gating, non-causal results, canonical sale-trigger capture, aggregate access,
and presence of the retention cron.

## Deliberately unresolved integration work

Provider-neutral POS/payment ingestion is not silently inferred from these
events. A future contract must define provider signature verification, location
mapping, customer resolution, GST/tip/discount allocation, tender and currency
semantics, event ordering, refund/chargeback authority, dead-letter handling,
and canonical sale/payment handoff.

Until that contract exists, the conservative refund matrix is:

| Scenario | Current support |
| --- | --- |
| Full cash quick-sale reversal | Supported when existing reversal eligibility passes |
| Cash amount correction | Supported only by the existing unspent-points/single-cash correction path |
| Card or PayNow provider-settled refund | Not supported |
| Partial refund | Not supported |
| Mixed-tender refund | Not supported |
| Gift card, package, or membership refund | Not supported as a general sale refund |
| General sales chargeback | Not supported; stored-value chargeback handling is a separate specialized path |
