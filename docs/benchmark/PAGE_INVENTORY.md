# PAGE_INVENTORY

Routes observed live (L) or inferred from marketing feature pages (M). Empty tenant, so
component lists reflect structure, not populated data.

| Page | Route | Src | Parent | Roles (observed) | Purpose | Key components | Gated |
|---|---|---|---|---|---|---|---|
| Onboarding: country | `/welcome/setup/country` | L | Onboarding | Owner | Set operating country (drives payments) | Country select, Continue, Skip | No |
| Dashboard | `/dashboard` | L | — | Owner+ | Command centre | Greeting, Booked today, Revenue this week, trial banner, KPI cards (Today's appts, Revenue 30d, Low-stock alerts, Unpaid deposits), Today-at-a-glance timeline, Today's Schedule, Revenue-this-week chart, "Finish setup 10%" | No |
| Loyalty | `/loyalty` | L | Catalog | Owner+ | Points/stamp config | **Locked** — upgrade card ("Loyalty… is a Growth feature") | **Growth** |
| Loyalty (mechanics) | `flowesce.com/features/loyalty` | M | — | — | Full engine spec | points/stamps, earn triggers, 3 expiry modes, credit mint, limits | — |
| Memberships (mechanics) | `flowesce.com/features/memberships` | M | — | — | Plan/renewal/dunning spec | credit pool, rollover, discount, daily renewal, Stripe SG | — |
| Referrals (mechanics) | `flowesce.com/features/referrals` | M | — | — | Referral engine spec | personal codes, attribution, qualify-on-completion, min-spend | — |
| Settings: Billing | `/settings/billing` | L | Settings | Owner | Plan & subscription | Trial banner, current plan (Solo S$25/mo trial), Monthly/Annual toggle, Solo vs Growth cards, Add payment method | No |
| Settings: Team | `/settings/team` | L | Settings | Owner | Roles & staff | Expertise levels (Senior/Junior), role tiers (Owner/Manager/Receptionist/Bookkeeper/Staff — invites Growth-gated), Team members table (Change role) | Invites Growth |
| Settings shell | `/settings/*` | L | Settings | Owner | Config hub | Tabs: Business, Account, Billing, Team, Integrations, Text & WhatsApp, Policies, Brand, Payments, Data & privacy, Import | Mixed |

## Plan feature split (from `/settings/billing`, founding annual)
- **Solo — S$18/mo founding (S$25 list):** 1 branch; unlimited staff/clients/appointments; inventory auto-deduct on completion; multi-currency expense tracking; Google Calendar sync (1); booking confirmations + reminder emails; standard reports; email support.
- **Growth — S$48/mo founding:** multi-branch; **team invites + role-based staff logins**; per-staff Google Calendar sync; custom booking domain; white-label transactional email; advanced reports + per-branch breakdowns; **smart marketing campaigns (win-back, review, anniversary)**; priority support; everything in Solo. **(Loyalty, Memberships live here.)**

## Not yet inventoried (locked or empty) — see OPEN_QUESTIONS
Clients detail view, Calendar, Appointments, Inventory, Quick Sale flow, Reports/Analytics,
Integrations, Text & WhatsApp, Payments, Data & privacy, Import, Loyalty/Membership admin config.
