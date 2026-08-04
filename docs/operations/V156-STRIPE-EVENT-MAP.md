# V156 Stripe event map

V77 verifies signatures, retains event IDs/API versions/payload hashes and
projects provider state. V156 consumes only events whose V77 status became
`processed`.

| Verified event | V156 result |
| --- | --- |
| `invoice.finalized` | Stripe remains the open pre-payment obligation; no conflicting immutable Peekaa mirror is frozen |
| `invoice.paid` | One paid invoice mirror, one receipt, subscription summary, lifecycle update, CRM activity/stage automation, invoice-scoped task recovery and one document pack |
| `invoice.payment_failed` | Past-due lifecycle and one urgent follow-up task |
| `invoice.payment_action_required` | Action-required lifecycle and one urgent follow-up task |
| `customer.subscription.created/updated/deleted` | Canonical lifecycle snapshot, cancel-at-period-end task where applicable |
| `invoice.voided/marked_uncollectible` | Append the corresponding operational document status when a mirror exists |
| `refund.created/charge.dispute.created` | Preserve the receipt and append partial/full refund or dispute activity from V77's canonical adjustment |

Period display uses V77's canonical subscription projections, whose processor
already prefers subscription-item/invoice-line period fields for the configured
Stripe event shape. Indefinite recurring subscriptions show no scheduled end;
cancel-at-period-end shows the current period end as scheduled end.

Duplicate event IDs, Stripe invoice IDs, lifecycle source keys, task keys and
delivery keys are unique. Out-of-order provider events remain governed by V77's
event rank/timestamp projection rules; a delayed failure is ignored when the
canonical invoice is already paid. Blocked/failed V156 preparations are stored
and replayed by the scheduled automation after configuration is completed.
