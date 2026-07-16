# OPEN_QUESTIONS

Things needing your decision or a follow-up review before Phase 1 code.

## Needs your decision (blocking-ish)
1. **Product name:** Frenly vs Avocado — same product or two? These docs assume Avocado = loyalty app, Frenly = marketing site. Confirm the canonical name.
2. **Repo home:** the loyalty schema currently lives at `marketing-content/frenly-site/db/`, but these benchmark docs are in `loyalty-main/docs/benchmark/`, and `loyalty-main` isn't a git repo yet. Where should the Avocado app + schema live? (Recommend: one git repo = `loyalty-main`, move the `db/` there.)
3. **Beachhead vertical:** confirm F&B cafés (my recommendation) vs beauty vs fitness.
4. **Pricing intent:** flat + per-outlet, no per-member fee? Target price points? Free tier / freemium yes/no?
5. **Scope boundary:** Avocado = loyalty-only platform (recommended), or does it also need booking/POS/inventory like Flowesce? (Recommend loyalty-only.)
6. **Funding model for rewards:** merchant-funded only at launch, or platform/partner-funded too (coalition)?

## Needs a follow-up live review (locked/empty this session)
7. Loyalty admin config — exact fields (verify on Growth or seeded tenant).
8. Points earn edge cases — refunds → reversal, partial refunds, rounding, min-redeem, max-earn caps.
9. Membership dunning states + Stripe flows (SG) — see live.
10. Reports/Analytics module — what metrics/exports exist.
11. Clients detail view — full field list, segmentation, tags, consent surface.
12. Integrations + Text & WhatsApp + Payments + Data & privacy + Import settings pages (didn't load / not opened).
13. Reviews/reputation module — only marketing-page evidence so far.
14. Quick Sale flow — confirm it's the retail/walk-in earn trigger and how it books a sale.

## Needs legal / regulatory review ⚖️ (do not claim compliance)
15. PDPA consent + data handling design.
16. SMS sender-ID registration in SG; WhatsApp Business API onboarding.
17. GST treatment on paid memberships/tiers; whether stored credit has e-money implications.
18. Data residency requirements before any overseas expansion.

## Guardrail reminders honored this session
No billing changed, no upgrade purchased, no data written to the benchmark tenant, no
messages sent, no PII stored. Unlocking loyalty config requires a billing change — will not
do without your explicit approval.
