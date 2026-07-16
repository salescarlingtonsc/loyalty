# SINGAPORE_PRODUCT_STRATEGY  (first draft — needs your business input)

> Assumptions flagged ⚠️ need your confirmation (pricing intent, target vertical, funding).
> Nothing here is verified legal/regulatory advice — items needing counsel are marked ⚖️.

## Positioning
**Avocado = the loyalty platform for Singapore SMEs and multi-outlet brands — real
spendable rewards, WhatsApp-native, live in an afternoon.** Where Flowesce buries loyalty
inside a salon OS, Avocado is a dedicated, industry-agnostic loyalty layer that plugs into
whatever a business already uses.

## Beachhead (pick one to start) ⚠️
Rank of best first verticals in SG:
1. **F&B groups / cafés** — highest visit frequency → loyalty compounds fastest; QR + WhatsApp fit; many multi-outlet SMEs.
2. **Beauty & wellness / salons** — Flowesce's own turf; high AOV, strong referral culture; we win on WhatsApp + tiers.
3. **Fitness studios / gyms** — membership + loyalty combo, recurring revenue.
Recommendation: **F&B multi-outlet cafés** as beachhead (frequency + word-of-mouth +
QR-at-table), expand into beauty/fitness with the same engine.

## ICP
Multi-outlet SME (2–20 locations), owner-operated, already has POS + WhatsApp, grows by
word of mouth, no real loyalty tooling or stuck on stamp cards/points-that-mean-nothing.

## Core value prop
"Rewards your customers actually spend, sent on WhatsApp, that pay for themselves." Three
proof points: real credit (not vanity points) · self-funding referrals · live liability
you can read.

## SG-specific requirements
| Area | Requirement | Status/Note |
|---|---|---|
| PDPA ⚖️ | consent capture, purpose limitation, access/portability, withdrawal | build `consents` append-only; **legal review before launch** |
| WhatsApp | WhatsApp Business API sender, templates | 🔴 first-class channel; Flowesce lacks it |
| SMS | local sender-ID / registration ⚖️ | needed for reminders/OTP |
| Mobile number | +65 8-digit format validation | trivial, do early |
| Currency/GST | SGD, GST display ⚖️ | tenant currency ✔; GST on paid memberships |
| Payments | PayNow, NETS, GrabPay, ShopeePay, Stripe | loyalty core needs **none**; memberships/paid tiers use Stripe + PayNow |
| POS | integrate common SG POS (StoreHub, EPOS, Qashier, Slurp, Shopify/Woo) | earn via POS webhook/API; **POS-agnostic** is the wedge |
| Identity | QR member code; Singpass/MyInfo only where justified ⚖️ | QR yes; Singpass later/optional |
| Languages | EN + Simplified Chinese + Malay + Tamil | member-facing i18n |

## Pricing (draft — needs your call) ⚠️
Model: flat monthly + outlet-based, **no per-member or per-point fees** (mirror Flowesce's
"nothing skimmed" trust play, which resonates locally). Illustrative only:
- **Starter** (1 outlet): free or ~S$0–29/mo — PLG on-ramp.
- **Growth** (multi-outlet): ~S$79–149/mo.
- **Pro/Franchise + agency**: custom.
Add: free 14-day trial (no card, one-click export — copy Flowesce's low-friction promise),
optional onboarding/migration service. **Confirm intended price points.**

## GTM motion
Product-led trial + WhatsApp-first onboarding; POS-partner integrations as a distribution
channel; agency/reseller program for multi-client rollout; migration offer ("import from
your stamp app / Flowesce / spreadsheet in one step") as a switching lever; case studies
from 3–5 design-partner cafés.

## Do-not-overbuild (for SG launch)
Coalition loyalty, multi-country infra, reward marketplace, native mobile apps — all
🔵 later. Win one vertical in SG first.
