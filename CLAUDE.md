# Avocado — project instructions (loyalty platform)

> If this repo and the marketing-content repo ever conflict, note: **this folder is the
> Avocado loyalty PRODUCT**; `marketing-content` is a separate "Super Marketing Brain"
> repo with its own CLAUDE.md — do not merge them.

## What Avocado is
A **Singapore-first, multi-tenant, industry-agnostic loyalty platform** — real spendable
rewards (in-store credit, not vanity points), WhatsApp-native, that a business can set up
in an afternoon. Benchmarked against **Flowesce** (a salon OS where loyalty is one module);
Avocado extracts the loyalty engine + automations and generalizes them, winning on channels
(WhatsApp/SMS), tiers, gamification, wallet passes, analytics, AI, and being API-first.

> Naming: product referred to as **Avocado** (app) and **Frenly** (marketing site). Confirm
> canonical name — see `docs/benchmark/OPEN_QUESTIONS.md`.

## Target users
Multi-outlet SME (2–20 locations), owner-operated, already on POS + WhatsApp, grows by word
of mouth. **Beachhead: F&B cafés** (frequency compounds loyalty), then beauty + fitness.

## Singapore-first strategy
Win one vertical in SG before any overseas build. SG essentials: PDPA consent ⚖️,
WhatsApp/SMS ⚖️, +65 numbers, SGD/GST, PayNow/e-wallets/Stripe, POS-agnostic integration,
QR member identity, EN/ZH/MS/TA. Do not claim legal compliance — flag ⚖️ items for counsel.

## Core product principles
- **One append-only in-store credit ledger** is the system of record (loyalty, referrals,
  gift cards, memberships, refunds all flow through it).
- **Points ≠ credit:** points earn/expire, then redeem INTO credit. Two append-only ledgers.
- **Completion is the universal earn/qualify event** — one shared `visit.completed` /
  `sale.closed` signal; modules subscribe, none writes the ledger directly.
- **Automations are the product:** auto-earn, daily expiry sweep, referral payout-on-
  completion, membership renewal + dunning.
- Idempotency on earn + reward issuance; prevent double earn/redeem; every sensitive write
  audited; RBAC + tenant isolation; loading/empty/error/success/denied states everywhere;
  automated tests for all loyalty calculations; no mock data in prod.

## Confirmed architecture decisions
- Backend: **Supabase** project `kyzovonwnscrzmkvocid`. Publishable key
  `sb_publishable_hOMgvuulHY0iSs7nmbqt3Q_RD0df_p7` (use this, not legacy anon).
- Migration `frenly_init` applied: 13 tables, **RLS on every table**, append-only
  `credit_ledger` + `client_credit_balance` view, salon-membership-scoped policies.
- Schema currently lives at `marketing-content/frenly-site/db/` — **should move into this
  repo** (open question 2).

## Key module relationships (see docs/benchmark/MODULE_RELATIONSHIP_MAP.md)
Appointment/Quick Sale completion → points ledger → (redeem) → credit ledger → reports/
liability. Referral code → attribute at booking → reward credit on qualified first visit.
Membership enroll/renew → sale(kind=membership) → P&L; SG auto-charge + dunning.

## Features already implemented (don't rebuild)
Multi-tenant schema + RLS; append-only credit ledger + balance view; core entities
(clients, services, appointments, products, gift_cards, referrals skeleton, leads);
Supabase auth. The **Frenly marketing site** (deployed on Vercel).

## Scope — SUPERSEDED 2026-07-17 by the Full-Coverage Parity Protocol
> **The old line here ("Avocado is loyalty-only; don't clone the salon OS surface") is DEAD.**
> Owner directive 2026-07-17: **complete functional and behavioural parity with Flowesce for
> every accessible feature**, built with Frenly's own code. "Do not decide that a module is
> unimportant." Default decision for every confirmed accessible feature = **include in parity
> scope**. Omissions require explicit written owner approval and live in the Unapproved
> Omissions register (`docs/parity/FLOWESCE_TO_AVOCADO_PARITY_MATRIX.md` §4).
>
> Still binding (protocol §15, and unchanged): **do NOT copy Flowesce source code, trademarks,
> logos, proprietary copy, or distinctive visual assets.** Reproduce capabilities, workflows,
> calculations, data relationships, automations, validations, permissions — using our own
> branding, wording, components, code and DB implementation.
>
> Owner rulings 2026-07-17 (recorded so they don't get re-litigated):
> - **Payroll/commission is IN scope** (UO-1 lifted). Prior "out of scope" was partly based on
>   a false 404 report — `/reports/payroll` is real, complete, and SG-localised (Talenox CSV
>   export). Build the data foundation first (staff commission rates + assignment).
> - Stripe SG auto-charge and WhatsApp/SMS remain deferred, but note this now BLOCKS
>   Transactions / Cash drawer / Deposits / the checkout split. Email campaigns are a separate
>   capability the comms deferral arguably doesn't cover — unresolved.
> - QA Test Cafe tenant: kept, not deleted; its mis-classified package row was backfilled in v10.

## Audit discipline (learned the hard way, 2026-07-17)
**Never report a 404 without proving the route came from the app's own `href`, not a guessed
URL pattern.** Four modules (Payroll, Store orders, Review feedback, Journeys) were wrongly
reported as "dead nav links Flowesce never shipped." All four are real and working; the 404s
were self-inflicted by guessing `/payroll`, `/store-orders`, `/reviews`, `/journeys` instead of
reading the sidebar's actual routes (`/reports/payroll`, `/storefront/orders`,
`/marketing/feedback`, `/marketing/journeys`). Distinguish 404 (route absent) from paywall
(route exists, plan-gated) — both exist here. Capture routes via accessibility-tree dump.

## Current phase
**Phase 1 MVP — shipped.** Canonical product name: **Frenly** (owner confirmed; "Avocado"
in older docs = same product). App: `app/index.html`, deployed at
https://frenly-app.vercel.app (Vercel project `frenly-app`; marketing site stays on
project `loyalty`). Schema v2 applied (migration `frenly_v2_saas`): `salons`→`businesses`
(+industry, +enabled_modules), `sales`, `points_ledger`, `retention_programs`,
`reward_grants`, `booking_requests`; DB triggers auto-earn points + fire retention
rewards on every sale (verified); RPCs `redeem_points`, `get_business_public`,
`request_booking`. Repo git-initialized (commit 347e391).
v3 added: points expiry (3 modes, batches, daily pg_cron sweep), referrals
(codes + qualify-on-first-sale), consents, audit_log. v4: create_business onboarding
RPC (fixes INSERT..RETURNING vs SELECT-policy chicken-and-egg). v5: memberships
(plans, enroll, daily renewal job, pause/cancel) + gift cards (issue/redeem RPCs).
Membership sales never earn points/retention/referral. v6 (ops parity with
Flowesce): appointments (+completion trigger -> sale -> loyalty; idempotent),
waitlist, inventory (product_stock view, FEFO auto-deduct on retail sales),
packages (sell/use-session RPCs; session = $0 visit for retention), bundles +
resources tables, convert_booking_request RPC (portal request -> client +
appointment). v7 (final Flowesce parity): staff_invites + create_invite/
accept_invite RPCs (5 roles, code-based join at onboarding), Settings team roster
+ CSV customer import, appointments Week calendar view, bundles/resources UI,
businesses.brand_color + booking_policy (portal-themed). All engines verified via
rolled-back SQL chain tests. App v1.4, 15 modules, industry-mapped.
v9 (`frenly_v9_giftcard_revenue`, applied + deployed 2026-07-17): **gift card
sales are cash collected, NOT revenue.** New `sales.kind = 'gift_card'`;
`issue_gift_card` now writes that kind (was wrongly `'retail'`);
`app.on_sale_recorded()` treats `'gift_card'` exactly like `'membership'` —
no points, no points batch, no retention visit, no referral qualification —
in both the early-return guard and the retention visit-count window.
`redeem_gift_card` deliberately does NOT insert a sale: it loads
`credit_ledger`, and the later real sale when that credit is spent IS the
revenue (inserting at redemption would double-count). UI (`app/index.html`)
excludes `gift_card` from dashboard Revenue + Visits KPIs and both charts, and
Reports shows it as a separate "cash collected, not revenue" line outside the
revenue total. Verified by 16-assertion rolled-back chain test before applying.
Deferred by owner decision: Stripe SG auto-charge + WhatsApp/SMS comms.
**Open, needs owner decision (found during v9 review):** `sell_package` has the
same accounting shape as the gift-card bug — it books `kind='retail'` revenue
upfront for prepaid sessions, earns points on the full package price, AND counts
as a retention visit at purchase; then each `use_package_session` inserts a $0
`kind='service'` sale, so a 10-session package registers 11 visits. Revenue-
upfront may be deliberate (the UI copy says "revenue upfront"), but the
purchase-time retention visit looks unintentional. Not changed — see
`docs/benchmark/LIVE_DATA_WALKTHROUGH.md`.
v10 (`frenly_v10_sale_policy`, applied + verified 2026-07-17, 14/14 rolled-back
assertions): **sale accounting semantics are now per-business policy, not hardcoded.**
New `sales.kind='package'` (`sell_package` writes it; the QA-era 'retail' row was
backfilled). `public.sale_policies` (business_id, kind) holds three orthogonal
nullable flags — `counts_as_revenue` / `counts_as_visit` / `earns_points`; NULL =
inherit product default. `app.sale_policy_defaults()` is the single source of truth;
`app.sale_policy_set()` resolves defaults LEFT JOIN overrides; no backfill needed —
a business with zero rows resolves to defaults. `app.on_sale_recorded()` now ASKS
instead of assuming, incl. the retention visit-count window, which judges each
HISTORICAL row by its own kind's current policy (flip a policy, history is re-judged —
verified). RPCs `get_sale_policy` / `set_sale_policy`. Defaults reproduce live
behaviour except **package visit=false**, killing the 11-visits-per-10-session bug.
Referral qualification is deliberately bound to `counts_as_visit`.
App v1.6 (deployed 2026-07-17): fixed two production blockers — (1) appointments
list/week permanently empty via `PGRST201` ambiguous embed (3 sites now pinned to
`services!appointments_service_id_fkey`); (2) portal booking dates corrupted — two
stacked timezone bugs (write side treated `datetime-local` as ambient browser zone,
read side printed raw UTC as local). Added `sgt()` / `sgIso()` helpers anchoring to
+08:00. Round-trip verified. **Known residual:** Week-view bucketing still uses
browser-local time — works on an SGT browser, architecturally fragile.
**WRITTEN BUT NOT APPLIED:** `20260717_frenly_v11a_branches_staff_services.sql` and
`20260717_frenly_v11b_money.sql`. Apply order v10 → v11a → v11b. v11a adds branches
(+ auto-created default branch per business, `branch_id` nullable + BEFORE INSERT
trigger so the 5 unmodified `sales` writers keep working), staff schedules/branch+
service assignment/two-rate commission, service deposits/buffers/processing time.
**v11a makes `staff.user_id` NULLABLE** — today it's NOT NULL → auth.users, so a
rota-only staff member (no login) is impossible; this blocks FL-STAFF parity.
v11b adds the payments ledger + completion≠payment split (loyalty stays firing at
completion per CLAUDE.md's own first principle; revenue reported twice as
`revenue_accrual` and `revenue_cash`, the delta being A/R), cash drawer, expenses.
Neither is verified yet — both need rolled-back chain tests before applying.
v14 (`frenly_v14a/b/c/d`, applied + verified 2026-07-18, 25/25 rolled-back assertions,
security advisor 0 ERROR — see `db/migrations/20260718_frenly_v14_*.note.md` for the
full rationale). Five things:
(1) **Super admin** = `leechuanseng.biz@gmail.com` (owner ruling). Scope = **read every
tenant, write platform tables only**. `public.super_admins` + `app.is_super_admin()` +
46 SELECT-only `<t>_sa_read` policies. `super_admins` has NO write policy at all — it is
API-unwritable by anyone incl. a super admin (service role/SQL only), so a stolen owner
session cannot self-promote. SA can write `subscriptions`; SA insert into a tenant's
`clients`/`credit_ledger` → 42501. Verified both directions.
(2) **ROLE BUG FIXED (was live since v7):** `staff_invites` allowed
`manager|receptionist|bookkeeper|staff` but `staff` allowed `owner|manager|stylist|
frontdesk`, and `accept_invite` inserts the invite role straight into `staff` — so
**every invite except 'manager' threw a check violation.** Employee onboarding was broken
for 3 of 4 roles. Canonical set now `owner|manager|staff|frontdesk|bookkeeper`
(`stylist`→`staff`, `receptionist`→`frontdesk`, backfilled). `owner` is not invitable.
(3) **Seat billing:** `subscriptions` + `v_business_billing`. $25/mo covers firm + 1
login; each extra ACTIVE login +$10/mo. **A seat = `staff.user_id IS NOT NULL AND
active`** — v11a rota-only staff are FREE; deactivating frees the seat. Only a super
admin can write it (a firm cannot price itself — verified 0 rows). **No Stripe, no hard
seat cap** (blocking invites with no way to pay would brick the pilot).
(4) **Per-staff module permissions:** `staff.modules text[]` (NULL = inherit, array =
allowlist, owner always bypasses) + `module_templates` + `app.can_module()` /
`get_my_modules`. **Enforced in RLS on `clients`/`appointments`/`products`/
`stock_batches`** — an inventory-only employee hitting `/rest/v1/clients` gets 0 rows,
not the customer list. `can_module()` deliberately ignores `enabled_modules` (turning a
module off in Settings must not strand rows). Other modules remain UI-level only.
(5) **Customer self-signup + phone till:** `join_program`/`get_join_page` (anon) behind
`app/join.html?s=<slug>` + QR in Settings; `businesses.join_enabled`. `join_program`
returns a UNIFORM `{status:'ok'}` for new AND existing numbers — differing would make it
an oracle for "is 8xxxxxxx your customer" (PDPA). `app.norm_phone()` folds
`+65 8186 3833`→`81863833`; `clients.phone_norm` GENERATED + partial unique
`(business_id, phone_norm)`. Till: `lookup_client_by_phone` → `record_sale_by_phone`
with `sales.idem_key` (double-tap → `duplicate_ignored`, one sale). The till writes ONE
`sales` row and no ledger — v10 triggers still own earning.
**⚖️ Open risks from v14:** `join_program` is anon with NO rate limiting (mass-junk-insert
vector; needs captcha/edge limit before scale). Pre-existing, NOT fixed:
`businesses.salons_insert` is `WITH CHECK (true)` (any authed user can create an orphan
business, bypassing `create_business` → no owner row, no subscription = billing evasion);
Supabase leaked-password protection is OFF.
Next candidates: verify+apply v11a/v11b; wire UI to `get_sale_policy` (revenue KPI
still hardcodes `!== 'gift_card'`); Pass 2/3 of the parity audit; member-facing portal
balance, Supabase Auth Site URL config, custom domain, role-scoped UI permissions.

## Key unresolved risks
Ledger/points-calc correctness; double earn/redeem; loyalty-liability accuracy; PDPA ⚖️;
WhatsApp/SMS onboarding ⚖️; tenant isolation; scope creep into a full salon OS.

## Detailed benchmark docs
`docs/benchmark/`: EXECUTIVE_SUMMARY, REVIEW_LOG, MODULE_INVENTORY, PAGE_INVENTORY,
MODULE_RELATIONSHIP_MAP, DATA_ENTITY_MAP, EFFICIENCY_AUTOMATION_AUDIT,
ROLE_PERMISSION_MATRIX, AVOCADO_GAP_ANALYSIS, AVOCADO_REUSE_MATRIX,
SINGAPORE_PRODUCT_STRATEGY, IMPLEMENTATION_ROADMAP, OPEN_QUESTIONS.

## Working method (standing instruction from owner)
**Fable 5 is the reviewer & orchestrator.** Delegate implementation via subagents:
**Opus** = complex logic (schema, triggers, RPCs, architecture, tricky flows);
**Sonnet** = standard coding/execution (UI edits, browsing/documentation, deploys).
Fable pins the API contract before parallel delegation, reviews both outputs,
fixes gaps, runs the rolled-back SQL verification tests itself, and owns the
final merge + report (exact files touched, what changed and why).

## Design direction (owner-confirmed; updated 2026-07-18 post-launch)
- **Grouped navigation (Cubbly reference, owner screenshot 2026-07-18):** a handful of
  top-level headers, NOT a long flat rail. Owner's words: "too many modules… modules will
  be inside these main headers — won't look messy." Admin/settings live under the Profile
  menu, not the nav. Target shape: Home (dashboard) · Customers · Operations (workday:
  appointments, bookings, waitlist, sales, services, inventory, packages) · Growth
  (loyalty, retention, referrals, memberships, gift cards) · Insights (reports, staff
  performance) · Profile menu → Settings/admin.
- **Guided setup:** a step-by-step first-run guide before operations — set products/
  services, understand sale→inventory deduction, set up loyalty, etc. Wizard, not docs.
- **Staff performance & commission (owner ruling 2026-07-18):** platform provides the
  MECHANISM, never the numbers — each firm sets its own commission as a % of sales OR a
  fixed amount per selected service. "We don't need to set any pricing or % right now."
  Engine already supports %: staff.commission_service_bps/product_bps + services.
  commission_bps override + v12 per-sale rate snapshot. Fixed-amount-per-service is an
  owner-requested addition. Finance modules (payments/drawer/expenses) exist in DB,
  deliberately have no UI yet (pilot-disabled), NOT skipped — sequenced after pilot.
- **Low-literacy-first UX:** staff may be WPass/SPass workers from Thailand,
  Vietnam, Myanmar etc. Pictogram-first, ≤3-word labels, step-by-step wizards,
  big tap targets, colour semantics, numbers over words, illustrations for every
  workflow. See docs/benchmark/UX_SIMPLIFICATION_PLAN.md.

## Do not put in this file
Passwords, tokens, personal customer data, or confidential benchmark-tenant data.
