# AVOCADO_REUSE_MATRIX

Reuse decisions. Avocado has no app code yet, so "reuse" mostly means **reuse our
Supabase schema** and **reproduce Flowesce logic** with our own architecture. Categories:
Reuse-unchanged · Reuse-small-mods · Refactor-before-reuse · Extend · Rebuild · New ·
Not-recommended · Future-phase.

| Item | Existing Avocado asset | Benchmark feature | Decision | Required change | DB | API | UI | Tests | Complexity |
|---|---|---|---|---|---|---|---|---|---|
| Tenant + RLS | `salons` + RLS | multi-tenant isolation | **Reuse-small-mods** | rename `salons`→`tenants`; add industry, locale | low | – | – | RLS tests | S |
| Credit ledger | `credit_ledger` append-only + view | unified in-store credit | **Reuse-unchanged** | confirm `entry_type` enum coverage | none | read/write svc | balance widget | ledger math | S |
| Client/member | `clients` | member record | **Extend** | add consent, comms prefs, tags, source, dedupe | med | CRUD | member 360 | dedupe | M |
| Points engine | — | earn/expire/redeem | **New** | `points_ledger` + `points_batches`, earn/redeem/expiry services | high | earn/redeem/expiry | loyalty card | **heavy** (calc) | L |
| Loyalty config | `loyalty_programs` | points/stamp + expiry modes | **Extend** | add expiry_mode/days, tiers table, stamp scope | med | config CRUD | admin config | rules | M |
| Sales/transactions | `appointment_services` (partial) | earn + revenue source | **Rebuild** | proper `sales` table w/ `kind`, idempotency key | high | ingest | – | idempotency | L |
| Referrals | `referrals` skeleton | qualify-on-completion, self-funding | **Extend** | code, min_spend, reward_expiry, attributed/qualified_at, 1-reward guard | med | attribute/issue | portal share card | fraud/idempo | M |
| Memberships | — | plans + renewal + dunning | **New** | plans, memberships, charges, renewal job, Stripe SG dunning | high | enroll/renew/pause | member+admin | renewal edge | L |
| Gift cards | `gift_cards` | credit load/redeem | **Reuse-small-mods** | ensure writes to `credit_ledger`; unique codes | low | issue/redeem | – | uniqueness | S |
| Consent (PDPA) | — | consent-gated comms | **New** | `consents` append-only + prefs | med | check-before-send | consent UI | – | M |
| Audit log | — | manual adjust/refund trail | **New** | `audit_log` on sensitive writes | med | middleware | admin viewer | – | M |
| Comms | — | email now, SMS/WhatsApp | **New** | provider adapters; **WhatsApp/SMS first for SG** | med | send + status | templates | – | L |
| Jobs runner | — | expiry sweep, renewals, dunning | **New** | scheduled jobs (Supabase cron / edge fns) | low | – | – | job tests | M |
| Multi-outlet | — | branches | **Future-phase** | `outlets` + FKs | med | – | – | – | M |
| Reward catalogue | — | vouchers/experiences | **Future-phase** | `rewards`, `reward_redemptions` | med | – | – | – | M |
| Salon calendar/inventory/POS | — | booking/stock | **Not-recommended** | out of scope for a loyalty platform | – | – | – | – | – |

## Sequencing note
Build order is dictated by dependencies: `sales` + `points_ledger` + `credit_ledger`
first (nothing loyalty works without them), then referrals + memberships (they reuse the
ledger), then comms/consent, then analytics, then differentiators.

## Shared services (avoid duplicated business logic)
`PointsService`, `CreditLedgerService`, `EarnService` (subscribes to `visit.completed`),
`RedeemService`, `ExpiryJob`, `ReferralService`, `MembershipService`, `ConsentService`,
`NotificationService`, `AuditService`, `PermissionService`. Every module calls these —
no module writes the ledger directly.
