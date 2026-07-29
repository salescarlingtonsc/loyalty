# Current System Truth

## Scope and evidence boundary

This document separates:

- **verified production state:** migrations/functions/metadata visible in the connected production project and production base commit `90afc77`;
- **verified local contracts:** repository code and automated tests;
- **pending local work:** uncommitted v97 localisation and v98 Grow UX;
- **not verified:** physical devices, live outbound campaign delivery, production payment settlement, and real merchant adoption outcomes.

No production rows were modified. No migration, deploy, commit or push was performed.

## Product and positioning

Product name: **Nestly**.

Current truthful position:

> A multi-business loyalty and assisted-retention platform for Singapore SMEs, with a cross-business customer wallet, merchant QR enrolment, transaction/points histories, bookings, merchant-confirmed redemption, multi-outlet controls and platform-managed intelligence.

Position not yet supported:

> An automated customer-growth system that independently delivers campaigns and proves the resulting incremental net revenue.

## Supported business profiles

Sector bundles exist for F&B/café, facial/spa, fitness, salon, retail and other configurations. The module engine can assign sector defaults and platform overrides by firm. The mechanics also cover appointments, packages and memberships, but tested vertical depth is strongest for café and salon/spa.

Tuition, household services, clinics, automotive, renovation/property and other high-value/low-frequency models do not yet have first-class household, course, case, service-reminder or long-cycle playbooks.

## Roles and surfaces

### Customers

- Public customer sign-in at the top-level route.
- Phone + password normal login; OTP is reserved for account creation and reset.
- Passkey/Face ID/Touch ID registration and sign-in.
- Merchant QR join; customers cannot search for and self-link businesses.
- Cross-business programme selector.
- Merchant-specific programme view, balances, history, rewards, expiry, bookings and notifications.
- Pending reward QR that requires merchant confirmation.

### Business users

- Owner, manager, front desk and staff role/permission paths.
- Business sign-in at `/business`.
- Home, customers, Quick Earn, appointments, bookings, waitlist, sales and configurable Grow/Money/Operations modules.
- Branch and staff scoping.
- Itemised catalogue and manual-amount sale recording.
- Full reversal and fast cash correction paths.

### Platform users

- Super admin, configurable admin and assigned sales/consultant roles.
- Firm onboarding CRM/kanban, approval workflow, sector/module controls, billing/commission surfaces, firm/branch/customer intelligence and reports.
- Assigned consultants are scoped to their firms; super admin has broader authority.

## Architecture

```text
Static responsive SPA/PWA (app/index.html)
  ├─ customer wallet and authentication
  ├─ business workspace
  └─ public application / QR flows

Platform console (`/admin` route rendered by index.html + platform-console.js/css)
  └─ super admin, admin and consultant operations

Supabase
  ├─ Auth: phone/password/OTP/passkeys
  ├─ Postgres: tenant, customer, sale, payment, loyalty, retention,
  │            billing, platform CRM and audit tables
  ├─ RLS + guarded SECURITY DEFINER RPCs
  ├─ pg_cron scheduled jobs
  └─ Edge Functions: public join/booking/application and Stripe lifecycle

Vercel
  └─ static deployment, route rewrites and browser security headers
```

The PWA caches only the public shell/assets. Authenticated business/customer data is deliberately not available offline.

## Core data model

Production metadata on 2026-07-29 showed:

- 6 businesses, 6 branches, 7 staff, 18 clients;
- 40 sales, 21 payments, 19 points-ledger rows and 17 points batches;
- 6 loyalty programmes, 1 reward and 2 loyalty redemptions;
- 3 customer identities, profiles and business links;
- 1 retention programme, but zero campaign/member/grant/return rows;
- zero customer notification preference/outbox/inbox rows;
- zero birthday participation/entitlement/redemption rows;
- zero production billing price/subscription/invoice/payment/event rows;
- zero platform consultant and SME CRM rows;
- 185 audit-log rows.

These counts establish implementation use, not commercial adoption.

## Integration truth

| Capability | Truth |
| --- | --- |
| Supabase Auth | Real and production configured |
| Twilio Verify OTP | Real for account creation/reset; not a marketing channel |
| Passkeys | Implemented; hosted Auth/device support still requires live-device acceptance |
| QR enrolment | Real Edge Function/RPC path |
| QR redemption | Real merchant-confirmed path |
| Stripe billing | Functions and tables are implemented; production billing tables are empty |
| WhatsApp campaigns | Manual owner copy/paste only |
| SMS marketing | Not connected |
| Email marketing | Not connected |
| In-app notifications | Data structures and UI foundations exist; production activity rows are empty |
| Web Push | No implementation found |
| POS | Missing |
| E-commerce | Missing |
| Payment-linked identity | Missing |
| Receipt import | No production automated path found |
| CSV import/export | Real bounded import/export workflows; production usage unproven |
| Apple/Google Wallet passes | Missing |
| Public partner API/webhooks | No adoption-ready partner product found |

## Scheduled automation

The following production cron jobs were active:

- booking expiry every minute;
- outbox sweep every two minutes;
- stored-value tender release every three minutes;
- programme studio executor every five minutes;
- daily points expiry;
- daily membership renewals;
- daily referral shadow processing;
- daily expense recurrences;
- daily stored-value expiry/reconciliation;
- daily subscription lifecycle.

An active scheduler is not evidence that a downstream provider delivers a message. The outbox currently lacks a verified production communications provider.

## End-to-end growth workflow

| Connection | Status | Evidence/truth |
| --- | --- | --- |
| Customer QR interaction → identity capture | Fully implemented and verified by local contracts | QR-only linking; public join endpoint |
| Identity → customer/business link | Fully implemented | Durable customer identity/profile/link model |
| Nestly-recorded transaction → loyalty event | Fully implemented | Quick Earn + sale/points ledgers |
| External POS transaction → loyalty event | Missing | No POS/e-commerce/payment ingestion |
| Loyalty event → customer wallet | Fully implemented | Customer history and balance read models |
| Profile → segmentation | Implemented but not commercially verified | Inactivity/cadence/value cohorts |
| Segmentation → recommendation | Partially implemented | Drafts and recommended actions exist |
| Recommendation → reward grant | Fully implemented | Campaign/member/grant tables and RPCs |
| Reward grant → customer contact | Missing | Manual WhatsApp copy/paste |
| Customer return → Nestly transaction | Fully implemented if staff records it | Return/transaction linkage |
| Return → incremental attribution | Partially implemented | Strong holdout math; exposure unverified |
| Attribution → owner result | Partially implemented | Reports exist; causal language can overclaim |
| Owner result → subscription proof | Missing in production evidence | Billing cohort is empty |

## Customer journey truth

### Join

1. Scan merchant QR.
2. If signed out, create or sign in to the Nestly customer account.
3. QR context is preserved and links the customer automatically after authentication.
4. Complete required profile data.
5. View the merchant programme.

Strengths: no app-store download, no business search, durable link, mobile web.  
Friction: password + phone OTP + profile on first use; under-20-second target unproven.

### Earn

Staff locate the customer by name or phone, choose a branch/catalogue item or amount, choose tender, and record the sale. Customer balances and history update from the same server-side records.

Strengths: branch/role attribution, idempotency, customer history consistency.  
Friction: manual double-entry if the merchant already has a POS.

### Redeem

Customer chooses a reward and generates a pending QR. Staff scan it in Quick Earn. Only authorised confirmation changes the balance. This flow is strongly implemented and tested.

### Book

Customer booking/action surfaces are available only when the merchant enables them. Requests and appointments are grouped per business. Appointments can be amended by permitted business staff.

## Staff journey truth

Quick Earn is a credible first-party till companion. It supports customer/phone search, branches, catalogue items, payment method, points, receipts, QR scanning and fast correction.

The main operational gaps are:

- desktop/mobile navigation still exposes a large module surface;
- no external transaction ingestion;
- provider-settled/partial refunds are incomplete;
- authenticated operations do not work offline;
- live measured peak-hour speed is absent.

## Owner journey truth

Approval-first onboarding, sector assignment, module entitlements, business branding, branches, team permissions and catalogue configuration are real.

Production Grow configuration remains concept-heavy. Pending local v98 work introduces a unified overview, guided draft and save-without-refresh continuity. That is promising but not production truth.

Owner/customer intelligence is primarily a platform/consultant capability by product choice. This supports Nestly’s consultative upsell, but it means the SME cannot independently validate every recommendation/result.

## Financial, loyalty and redemption integrity

Strengths:

- append-only sale/loyalty provenance;
- idempotency and replay conflict handling;
- branch-scoped permissions;
- reversal-aware points and attribution;
- durable redemption receipts;
- split-tender/stored-value foundations.

Material limitation:

- normal sale reversal is full-sale oriented;
- partial and external provider-settled card/PayNow refunds are not a broad-launch-ready workflow;
- fast amount correction is limited, particularly for non-cash/provider tenders.

## Consent and identity

The system stores consent events, sources, actors, timestamps, preferences and opt-out state. Birthday participation is separated from marketing and date of birth is not shown to merchants.

Gaps:

- counter quick-add wording is a basic “marketing consent given” checkbox rather than explicit customer-confirmed evidence/version;
- no verified outbound provider means suppression behaviour has not been proven against real sends;
- phone normalisation reduces duplicates, but there is no mature merge/household/sibling workflow.

## Production database posture

- 136 production migrations; latest verified production version corresponds to v96.
- All listed public tables had RLS enabled.
- Supabase security advisor: 0 ERROR, 334 WARN, 143 INFO.
- Warnings are dominated by authenticated executability of SECURITY DEFINER RPCs and RLS-enabled tables with no direct policies. Many are intentional RPC-only designs, but they require maintained allowlist/auth-guard tests.
- Performance advisor reported multiple permissive-policy and indexing opportunities. These are scale/maintainability risks, not demonstrated data-isolation failures in this audit.

## What is real, partial, disconnected and missing

### Real and strong

- QR enrolment and customer/business linking
- customer wallet and histories
- Quick Earn
- branch/role controls
- merchant-confirmed QR redemption
- programme versioning
- append-only financial/loyalty records
- full reversal compensation
- deterministic holdout design
- platform firm/branch intelligence

### Partial

- onboarding simplicity
- next-best-action delivery
- churn prediction
- campaign automation
- ROI/profitability
- refunds
- subscription billing operations
- multilingual business/platform interface (local v97 only)
- unified Grow experience (local v98 only)

### Disconnected

- reward grant vs actual customer message exposure
- campaign outcome claims vs verified delivery
- Stripe implementation vs real production billing cohort
- customer actionable-wallet result vs prominent home CTA
- sector module templates vs genuinely vertical playbooks

### Missing

- POS/e-commerce/payment-linked ingestion
- delivery/open/click campaign evidence
- product analytics funnels
- mature customer merge/household model
- partial/provider refund completion
- Apple/Google Wallet passes
- partner integration product
- live commercial proof cohort
