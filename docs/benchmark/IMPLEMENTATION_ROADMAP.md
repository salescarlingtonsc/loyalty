# IMPLEMENTATION_ROADMAP

Phased plan. Each item: objective · acceptance · deps · DB/API/UI · security · tests.
Do **not** start Phase 1 code until you confirm OPEN_QUESTIONS (naming, repo home, pricing,
beachhead). Ledger/points work is the critical path.

## Phase 0 — Discovery (this) ✅ mostly done
Benchmark audit, module/relationship/entity maps, efficiency audit, gap + reuse, this
roadmap. Remaining: verify locked screens on a seeded/Growth tenant; confirm business inputs.

## Phase 1 — SG MVP foundation (the loyalty core)
**Goal: a business can run real-credit loyalty end-to-end.**
1. **Schema v2** — add `sales`(kind), `points_ledger`, `points_batches`, `consents`, `audit_log`; extend `clients` (consent/prefs/tags), `loyalty_programs` (expiry mode/tiers), `referrals` (qualifiers). *DB migration; RLS on all; tests: RLS + ledger math.*
2. **EarnService** — `visit.completed`/`sale.closed` → points earn (idempotent, full basket). *Acceptance: one completion = one earn; add-ons + discount netting correct.*
3. **CreditLedgerService + RedeemService** — redeem points → mint credit (one txn). *Acceptance: balance = SUM(entries); no double-redeem under concurrency.*
4. **ExpiryJob** — daily sweep, 3 modes, oldest-first. *Acceptance: expired batches drained, negative entries written, balance honest.*
5. **Member 360 + loyalty card UI** — balance, history, redeem, manual adjust (audited). States: loading/empty/error/success/permission-denied.
6. **Consent + PDPA basics** ⚖️ — capture at enrol; check before send.
7. **Onboarding** — create tenant → configure program in minutes (copy Flowesce's low-friction feel).
*Exit: seed a café, ring sales, earn, redeem to credit, expire — all correct and audited.*

## Phase 2 — Competitive parity
- **Referrals** (personal codes, attribute-at-booking, reward-on-qualified-completion, min-spend, one-reward guard).
- **Memberships** (plans, enroll-as-sale, daily renewal job, pause/cancel; **Stripe SG auto-charge + dunning**; manual elsewhere).
- **WhatsApp + SMS channels** (🔴 SG-critical) + templates + birthday/win-back campaigns.
- **CSV import** (from stamp apps / incumbents / spreadsheet).
- **Loyalty analytics v1**: active members, repeat rate, points issued/redeemed/expired, **breakage + live liability**, reward cost.
*Exit: matches serious local competitors; migration path exists.*

## Phase 3 — Avocado differentiation
- **Tiers / VIP status** with benefits (Flowesce has none).
- **Gamification** tied to real rewards (missions/streaks/spin) — opt-in, measured for real retention.
- **Wallet passes** (Apple/Google) + QR member identity.
- **AI loyalty copilot** — auto-segmentation, churn prediction, next-best-action, expiry-reminder campaigns, reward-cost optimization.
- **Multi-language** member surfaces (EN/ZH/MS/TA).
*Exit: noticeably better + easier than anything local.*

## Phase 4 — SG market leadership
- Multi-outlet/franchise management + outlet-scoped roles/campaigns.
- **POS-agnostic integrations** (StoreHub/Qashier/EPOS/Shopify/Woo) + open API + webhooks + embeddable widget.
- Agency/reseller dashboards; enterprise RBAC; SOC-style trust page.
- Advanced analytics: CLV, RFM, cohort, campaign ROI/incremental revenue.

## Phase 5 — Overseas (only after SG PMF)
Country infra: currency/tax, data residency ⚖️, local messaging senders, PayNow-equivalents,
timezones, i18n. Sequence MY → ID/TH/VN/PH → AU/HK. See OVERSEAS plan (to be written).

## Global build rules (apply from Phase 1)
Append-only ledgers · idempotency on earn + reward issuance · prevent double earn/redeem ·
RBAC + tenant isolation · every sensitive write audited · loading/empty/error/success/denied
states · automated tests for all loyalty calculations · no mock data in prod · nothing
"done" until tested end-to-end.
