# REVIEW_LOG

Session: 2026-07-16. Reviewer role: benchmark audit for Avocado. Method: Chrome
browser control (navigate + screenshot + DOM/text extraction) + public feature pages.

## Access
| Item | Detail |
|---|---|
| Platform URL | `https://app.flowesce.com` (admin console); `https://flowesce.com` (marketing) |
| Login | Manual, by the account owner. Credentials never entered by the agent, never stored. |
| Tenant | Own trial account — "CARLINGTON SMITH CONSULTANCY PTE. LTD.", owner Zeph Lee. Singapore. |
| Plan | **Solo (trial)**, S$25/mo list. 14-day trial, ends Jul 30 2026. No payment method on file. |
| Data state | **Empty** — 0 clients, 0 appointments, 0 revenue. Fresh onboarding (setup 10%). |

## What was reachable
- Dashboard (KPIs, today-at-a-glance, schedule, revenue).
- Left-nav module structure (all labels visible).
- Settings shell: Business, Account, Billing, Team, Integrations, Text & WhatsApp, Policies, Brand, Payments, Data & privacy, Import.
- Settings → Billing (plan tiers, feature split).
- Settings → Team (role model, expertise levels).
- Public feature pages: Loyalty, Memberships, Referrals (full mechanics captured).

## What was NOT reachable (and why)
| Area | Reason | Mitigation |
|---|---|---|
| Loyalty config screens | **Growth-tier gated**; unlocking = add payment method / change billing | Not done — billing changes need explicit approval. Used public loyalty feature page instead. |
| Memberships config | Growth-gated | Public memberships page. |
| Team invites / role editor | Growth-gated (Solo = single owner login) | Role tiers captured from gate copy + Team page. |
| Live member/transaction data | Tenant is empty | Config surfaces + feature-page mechanics documented instead. |
| Some settings sub-pages | Direct-URL guesses 404'd (client-side routing) | Documented from what loaded; flagged in OPEN_QUESTIONS. |

## Guardrails honored
- No billing change, no upgrade, no payment method added.
- No destructive actions, no messages sent, no campaigns published, no settings committed.
- No third-party customer PII encountered (empty tenant). Only the owner's own name/email appeared; not treated as confidential benchmark data.
- Credentials/tokens never captured in text or screenshots.

## Confidence
- **High** on: module structure, plan gating, role tiers, loyalty/membership/referral mechanics (primary-source feature pages).
- **Medium** on: exact admin config field-by-field (locked; inferred from feature copy).
- **To verify live** (needs Growth or a seeded tenant): points-earn edge cases, expiry job timing, refund→reversal behavior, membership dunning states, reports/analytics screens.
