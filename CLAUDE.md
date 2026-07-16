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

## Should NOT be duplicated / out of scope
Salon-specific surface (calendar, booking, inventory, POS, packages) — Avocado is loyalty-
only. Don't clone Flowesce branding, copy, or code.

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
Deferred by owner decision: Stripe SG auto-charge + WhatsApp/SMS comms.
Next candidates: member-facing portal balance, Supabase Auth Site URL config,
custom domain, role-scoped UI permissions.

## Key unresolved risks
Ledger/points-calc correctness; double earn/redeem; loyalty-liability accuracy; PDPA ⚖️;
WhatsApp/SMS onboarding ⚖️; tenant isolation; scope creep into a full salon OS.

## Detailed benchmark docs
`docs/benchmark/`: EXECUTIVE_SUMMARY, REVIEW_LOG, MODULE_INVENTORY, PAGE_INVENTORY,
MODULE_RELATIONSHIP_MAP, DATA_ENTITY_MAP, EFFICIENCY_AUTOMATION_AUDIT,
ROLE_PERMISSION_MATRIX, AVOCADO_GAP_ANALYSIS, AVOCADO_REUSE_MATRIX,
SINGAPORE_PRODUCT_STRATEGY, IMPLEMENTATION_ROADMAP, OPEN_QUESTIONS.

## Do not put in this file
Passwords, tokens, personal customer data, or confidential benchmark-tenant data.
