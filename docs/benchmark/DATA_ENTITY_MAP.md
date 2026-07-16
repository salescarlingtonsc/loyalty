# DATA_ENTITY_MAP

Benchmark entities → mapping to our current Supabase schema (`kyzovonwnscrzmkvocid`,
migration `frenly_init`). Marks what exists, what to add, what to change.

## Legend
✅ exists in our schema · ➕ add · ✏️ change · ⬜ salon-only, skip for Avocado

## Entities
| Benchmark entity | Our table | Status | Notes / required change |
|---|---|---|---|
| Business/tenant | `salons` | ✅ (rename → `tenants`/`businesses`) | Avocado is multi-industry, not salons. Rename for generality. |
| Staff + role | `staff` (role check) | ✅ | Roles ok for ops; add loyalty roles (see ROLE matrix). |
| Member/client | `clients` | ✅ | Central member entity. Add: consent/marketing-consent, comms prefs, tags/segment, source, dedupe key. |
| Service | `services` | ✅ | Keep (earn basis). Generalize name for retail/other verticals. |
| Appointment (visit) | `appointments` | ✅ | The completion event. Generalize to `visits`/`transactions` for non-appointment verticals. |
| Sale/transaction | `appointment_services` (partial) | ✏️ | **Add a real `sales`/`transactions` table** with `kind` (service/retail/membership/quick_sale) — the earn + revenue source of record. |
| **In-store credit ledger** | `credit_ledger` (append-only) | ✅ | Already append-only ✔. Ensure `entry_type` covers loyalty_earn⟶ **rename to loyalty_redeem/credit**, referral_reward, membership_credit, gift_card, refund, spend. |
| **Points ledger** | — | ➕ **critical** | Add `points_ledger` (append-only) + **`points_batches`** for expiry (earned_at, expires_at, remaining, mode). Points ≠ credit. |
| Loyalty program config | `loyalty_programs` | ✅ | Add: `expiry_mode` (none/inactivity/fixed), `expiry_days`, redemption tiers table, stamp target/service scope. |
| Membership plan | — | ➕ | `membership_plans` (price, cadence, credit_pool, service_scope, rollover, discount_pct). |
| Membership (subscription) | — | ➕ | `memberships` (client, plan, status active/paused/cancel_at_period_end/lapsed, current_period_end, stripe_sub). |
| Membership charge | — | ➕ | via `sales(kind=membership)` + `membership_charges` (due/paid/failed, dunning_attempts). |
| Referral program config | — | ➕ | `referral_programs` (enabled, reward_amount, min_spend, reward_expiry_days). |
| Referral | `referrals` | ✅ | Add: `code`, `min_spend`, `reward_expiry`, `attributed_at`, `qualified_at`, one-reward guard. |
| Gift card | `gift_cards` | ✅ | Keep; ensure it writes to `credit_ledger`. |
| Reward/voucher | — | ➕ (phase 2) | If Avocado adds catalogue rewards beyond credit: `rewards`, `reward_redemptions`, unique voucher codes. |
| Consent record | — | ➕ **(PDPA)** | `consents` (channel, purpose, granted_at, source, withdrawn_at) — append-only. |
| Campaign | — | ➕ | `campaigns` (segment, trigger, schedule, reward). |
| Audit log | — | ➕ **critical** | `audit_log` (actor, action, entity, before/after) for manual adjustments, refunds, redemptions. |
| Outlet/branch | — | ➕ (multi-branch) | `outlets` + FK on sales/appointments (Growth = multi-branch). |
| Lead (marketing site) | `leads` | ✅ | Already present (anon insert). |

## Ledger integrity rules (carry into Avocado)
1. **Append-only** for `points_ledger`, `credit_ledger`, `consents`, `audit_log` — no destructive UPDATE of balances; balance = SUM(entries) (we already expose `client_credit_balance` view — add `client_points_balance`).
2. **Idempotency keys** on earn (per completed visit) and reward issuance (per referral first-visit, per redemption).
3. **Expiry** is batch-based, drained **oldest-first**; a daily job writes negative expiry entries — never silently mutates.
4. **Multi-tenant isolation** via `salon_id`/`tenant_id` + RLS (already enforced on all tables ✔).
5. **Refund → reversal** posts a compensating entry; never edits the original.

## Biggest schema gaps vs benchmark (priority order)
1. `points_ledger` + `points_batches` (expiry) — **loyalty cannot ship without this.**
2. `sales`/`transactions` with `kind` — earn + revenue source of record.
3. Membership tables + renewal/dunning state.
4. `consents` (PDPA) + comms prefs on client.
5. `audit_log`.
6. Referral qualifiers (code, min_spend, expiry) on `referrals`.
