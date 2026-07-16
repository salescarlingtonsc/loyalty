# AVOCADO_GAP_ANALYSIS

Flowesce (benchmark) vs Avocado (current state). **Avocado today = a Supabase schema
(migration `frenly_init`) + a marketing site (Frenly). There is no application yet.**
So most gaps are "build," but the schema is a strong, well-shaped foundation.

Classification: 🔴 Critical for SG launch · 🟠 Competitive parity · 🟣 Differentiator ·
🔵 Later/expansion · ⚪ Unnecessary complexity (skip).

## Where Flowesce is strong (reproduce)
| Capability | Flowesce | Avocado now | Class |
|---|---|---|---|
| Real-credit loyalty (not vanity points) | ✅ mature | schema partial (`credit_ledger` ✅, no `points_ledger`) | 🔴 |
| Auto-earn on completion/Quick Sale | ✅ | ❌ (no app) | 🔴 |
| 3-mode points expiry + daily sweep | ✅ | ❌ | 🔴 |
| Unified credit ledger (loyalty/referral/gift/refund/membership) | ✅ | `credit_ledger` ✅ shape | 🔴 |
| Self-funding referrals w/ qualify-on-completion | ✅ | `referrals` skeleton, no qualifiers | 🟠 |
| Memberships + daily renewal + dunning (SG) | ✅ | ❌ | 🟠 |
| CSV migration from incumbents | ✅ | ❌ | 🟠 |
| Honest, plain-English UX + FAQs | ✅ strong | n/a | 🟣 (adopt the ethos) |

## Where Flowesce is weak (Avocado can win)
| Gap in Flowesce | Impact | Avocado opportunity | Class |
|---|---|---|---|
| Loyalty is a **salon** sub-feature, not a platform | can't serve retail/F&B/gym/clinic natively | **dedicated, industry-agnostic loyalty platform** w/ templates per vertical | 🟣 |
| Earns on **headline service price only** (no add-ons/discount netting) | under-rewards baskets | earn on full basket, product/category/outlet multipliers | 🔴 |
| **No tiers/VIP status** (credit-only, single tier) | no status-driven retention | tiered membership status + benefits | 🟠 |
| **Single-tier, credit-only referrals** | limited virality | multi-tier, ambassador, corporate referrals | 🟣 |
| **No gamification** (missions/streaks/spin/badges) | engagement ceiling | opt-in gamification that ties to real rewards | 🟣 |
| **Email-only** comms (SMS "building", WhatsApp later) | weak in SG where WhatsApp/SMS win | **WhatsApp + SMS first-class** (SG-critical) | 🔴 |
| **No wallet passes** (Apple/Google), no QR membership | friction to carry/scan | wallet pass + QR member identity | 🟠 |
| **No coalition / cross-merchant** | single-merchant only | coalition loyalty, cross-merchant earn/redeem | 🔵 |
| **No loyalty analytics** (breakage, liability, CLV, RFM, cohort) | owners fly blind on program ROI | loyalty analytics suite + live liability | 🟠 |
| **No AI** (segmentation, churn, next-best-action) | manual campaign work | AI loyalty copilot | 🟣 |
| Payments **SG-only** for online card; loyalty needs none | membership auto-charge capped elsewhere | loyalty core needs no processor → travels; add PayNow/e-wallets | 🔵 |
| **No member-facing app/portal depth** | thin self-serve | branded member web app + wallet pass | 🟠 |
| **No open API / webhooks / embedded** | not a platform others build on | POS-agnostic API + webhooks + embeddable widget | 🟠 |
| No security/compliance page, thin trust layer | enterprise/medspa hesitation | PDPA posture + audit trail as a feature | 🟠 |

## Avocado's existing foundation (don't rebuild)
- Multi-tenant schema with **RLS on every table** ✅
- **Append-only `credit_ledger`** + `client_credit_balance` view ✅ (matches Flowesce's spine)
- Core entities (clients, services, appointments, products, gift_cards, referrals skeleton, leads) ✅
- Supabase auth + publishable key ready ✅

## Verdict
Avocado should **not** clone a salon OS. It should extract Flowesce's **loyalty engine +
automations + unified-ledger discipline**, generalize them to any business type, and win
on the axes Flowesce is weak: WhatsApp/SMS, tiers, gamification, wallet passes, analytics,
AI, and being an actual API-first platform.
