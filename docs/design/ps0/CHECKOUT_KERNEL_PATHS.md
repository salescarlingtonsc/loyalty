# Checkout kernel — path classification (PS-1C)

Owner rule: **every sale/tender writer surface is exactly one of** `KERNEL`,
`SAFE WRAPPER`, or `LEGACY-CLASSIFIED (no studio effects)`. This document is the
authoritative classification of the writer set enumerated in
`docs/design/ps0/writer-registry.json` (the PS-0 audit output). It is enforced two
ways:

1. **Structural** — a Studio discount can only be applied by the finaliser
   `public.record_cart_sale(…, p_evaluation_id, p_paid)` (the arity-9 overload), and
   only when it is handed a server-owned `checkout_evaluations` token. Every other
   sale path either never receives a token (so it structurally cannot carry a
   discount) or is not a checkout at all.
2. **Tripwired** — `checkout_discount_lines` (per-effect discount provenance) has a
   FK to `checkout_evaluations`; the ONLY migration site that inserts into it is the
   kernel finaliser, asserted by
   `tests/program-studio/ps0-no-executor.test.mjs` ("checkout_discount_lines is
   written ONLY by the kernel finaliser"). The v58 suite additionally asserts every
   SAFE WRAPPER / LEGACY path produces **zero** `checkout_discount_lines`.

The kernel never writes `credit_ledger` / `points_ledger`. A discount reduces
`sales.amount_cents` **before** `app.on_sale_recorded` fires, so points / retention /
referral earn on the discounted total (asserted in the suite). No studio
ledger-guard scope is added.

## KERNEL — the one authoritative discount-applying write path

| surface | why it is the kernel |
|---|---|
| `public.evaluate_checkout/5` | Server-owned pricing. Resolves every line via `app.ps1b_catalog_price` (typed, fail-closed), evaluates `sale.completed` `apply_discount_*` rules against a synthetic cart payload, and mints an opaque `checkout_evaluations` token. Nothing is client-priceable (a price/amount key on any line is a hard `22023`). Moves no money. |
| `public.record_cart_sale/9` (WITH `p_evaluation_id`) | The finaliser. Locks the token, re-validates (single-use, unexpired, active config unchanged, prices re-resolved → `cart_hash`, budget re-checked and committed under a sorted lock). Writes the discounted sale via `record_quick_sale`, the server-line + signed `studio_discount` `sale_items`, `checkout_discount_lines` + `benefit_fulfilments` provenance, then consumes the token. **This is the only place a discount touches money.** |

## SAFE WRAPPER — server-priced, structurally carries no studio discount

These are already server-priced sale writers with **no token parameter**. No token ⇒
no `applied_effects` ⇒ no `checkout_discount_lines` can ever be produced. They are
safe to keep unchanged.

| surface | why no studio discount can apply |
|---|---|
| `public.record_cart_sale/7` (no token) | The v51 cart path. Takes client-supplied line prices but has **no evaluation-token argument**; it never reads `applied_effects` and never writes a discount line. |
| `public.record_quick_sale/9` | The named kernel candidate for the sale spine. A single server-priced amount; no line array, no token, no discount surface. |
| `public.record_sale_by_phone/9` (and the retired /7 stub) | A thin dispatcher that delegates to `record_quick_sale`; carries no token and no discount. |

## LEGACY-CLASSIFIED — not a discountable checkout

Each of these writes value but is **not** a general in-store checkout, so a Studio
checkout discount is out of scope by construction. One line each on *why*:

| surface | why studio discounts do not apply |
|---|---|
| `public.sell_package/3` and `/4` | Sells a prepaid package at its **plan price** (`kind='package'`), booked upfront per v10 sale policy; not a line-item checkout — no token path. |
| `public.use_package_session/3` | Consumes a prepaid session as a **$0** `service` sale; there is nothing to discount. |
| `public.enroll_membership/3`, `public.enroll_membership_v41/3` and `/4` | Enrols at the **plan price** (`kind='membership'`); membership sales never earn/qualify and are not a discountable checkout. |
| `app.run_membership_renewals/0` | The daily renewal job re-bills a membership at its plan price on a cron; no interactive checkout, no token. |
| `public.issue_gift_card/5` | **Cash collected, not revenue** (`kind='gift_card'`, v9). Face value is fixed by the buyer; discounting a stored-value top-up is a PS-2 concern, not a checkout discount. |
| `public.redeem_gift_card_v41/4` | Loads gift-card balance into `credit_ledger`; it deliberately inserts **no sale** (the later real sale is the revenue). Nothing to discount here. |
| `app.on_appointment_completed` (trigger) | Completion posts the booked **service** as a sale through the normal spine; the appointment price is authored elsewhere, and this trigger carries no token. Studio discounts on appointment checkouts would arrive through a future token-bearing completion, not this trigger. |
| `public.reverse_sale/6` → `reverse_sale_v40_base` → `_v34_base` → `_v20_base` | Reversal is **compensation**, never a new discountable checkout. PS-1C only adds the exact *release* of a kernel discount's budget + a signed compensating fulfilment; it applies no new discount. |
| `public.record_credit_tender/5` | Tender allocation against an already-fixed total (spends `credit_ledger`). The token governs pricing/discounts, **never tender** (architecture §9). |
| `public.record_payment/12` | Records a cash/card/PayNow/deposit/no-show payment against a fixed sale total; tender only, no pricing. |
| `public.reclassify_sale_policy/3` | Flips per-kind revenue/visit/earn policy and re-judges history; touches policy, not price — no checkout, no discount. |
| entitlement redemption (`public.redeem_program_entitlement`, birthday/campaign claimables) | **Promise-only / non-monetary** status flips (PS-1B). They redeem an already-granted benefit; they are not a priced checkout and write no sale. |
| loyalty redemption (`public.redeem_points/3`, `redeem_reward_at_context`, `app.redeem_reward_core`) | Converts points into `credit_ledger`; the resulting credit is later *spent* through a real sale (which itself may be a kernel checkout). The redemption is not a discount. |

## Deferred (not yet a live tender/checkout surface)

Cash drawer, expenses, and the stored-value tender do not exist as live interactive
checkout surfaces yet (finance pilot-disabled / PS-2). They join the kernel gate when
they ship; PS-1C does not touch them.
