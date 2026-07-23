# Checkout kernel — path classification (PS-1C)

Owner rule: **every sale/tender writer surface is exactly one of** `KERNEL`,
`SAFE WRAPPER`, `LEGACY-CLASSIFIED (no studio effects)`, or `RETIRED`. This document is
the authoritative classification of the writer set enumerated in
`docs/design/ps0/writer-registry.json` (the PS-0 audit output). It is enforced two
ways:

1. **Structural** — a Studio discount can only be applied by the finaliser
   `public.record_cart_sale(…, p_evaluation_id, p_paid)` (the arity-9 overload), and
   only when it is handed a server-owned `checkout_evaluations` token. Every other
   sale path either never receives a token (so it structurally cannot carry a
   discount) or is not a checkout at all. As of PS-1C.1 (v59) the token path is the
   **only** browser cart entry: the legacy `record_cart_sale/7` overload is RETIRED
   (EXECUTE revoked from every browser role), and a DB-level `sale_items` guard rejects
   a `package`/`membership`/`gift_card` line under a `quick_sale`/`cart_sale` parent, so
   no path can impersonate a dedicated-engine instrument through the sale spine.
2. **Tripwired** — `checkout_discount_lines` (per-effect discount provenance) has a
   FK to `checkout_evaluations`; the ONLY migration sites that insert into it are the
   kernel finaliser (defined in v58, CREATE-OR-REPLACE'd by the v59 hardening
   increment), asserted by
   `tests/program-studio/ps0-no-executor.test.mjs` ("checkout_discount_lines is
   written ONLY by the kernel finaliser"). The v58 and v59 suites additionally assert
   every SAFE WRAPPER / LEGACY path produces **zero** `checkout_discount_lines`.

The kernel never writes `credit_ledger` / `points_ledger`. A discount reduces
`sales.amount_cents` **before** `app.on_sale_recorded` fires, so points / retention /
referral earn on the discounted total (asserted in the suite). No studio
ledger-guard scope is added.

## KERNEL — the one authoritative discount-applying write path

| surface | why it is the kernel |
|---|---|
| `public.evaluate_checkout/5` | Server-owned pricing. Resolves every catalog line via `app.ps1b_catalog_price` (typed, fail-closed), evaluates `sale.completed` `apply_discount_*` rules against a synthetic cart payload, and mints an opaque `checkout_evaluations` token. No catalog line is client-priceable (a price/amount key on a `service`/`product` line is a hard `22023 client_priced`). PS-1C.1: `p_lines` may also carry a `custom` manually-priced line `{catalog_kind:'custom', description, amount_cents, reason}` — permitted only for owner + holders of the `custom_price_lines` permission, bounded by `businesses.custom_line_limit_cents`, with mandatory description/reason and `qty=1`; typed failures are `custom_line_denied` / `custom_line_limit` / `custom_line_invalid`. A cart discounted to a zero total returns the typed `total_zero_not_supported`. Moves no money. |
| `public.record_cart_sale/9` (WITH `p_evaluation_id`) | The finaliser. Locks the token, re-validates (single-use, unexpired, active config unchanged, prices re-resolved → `cart_hash`, budget re-checked and committed under a sorted lock). Writes the discounted sale via `record_quick_sale`, the server-line + signed `studio_discount` `sale_items`, `checkout_discount_lines` + `benefit_fulfilments` provenance, then consumes the token. **This is the only place a discount touches money.** PS-1C.1: also finalises `custom` manually-priced lines (re-projected AS-IS from the immutable token — never re-priced through `ps1b_catalog_price`) into `item_type='custom'` `sale_items` plus one `CUSTOM_PRICE_LINE` audit row each; carries a typed `total_zero_not_supported` (22023, never a stale P0001) belt-guard so a fully-discounted cart never creates a zero-value sale. |

## SAFE WRAPPER — no token parameter, structurally carries no studio discount

These sale writers take **no evaluation-token argument**. No token ⇒ no
`applied_effects` ⇒ no `checkout_discount_lines` can ever be produced. They are safe to
keep unchanged. (The F2 correction: the classifying property is *"has no token
parameter"*, **not** *"is server-priced"* — the now-RETIRED `/7` path was in fact
client-priced, so "server-priced" was never the true SAFE-WRAPPER invariant.)

| surface | why no studio discount can apply |
|---|---|
| `public.record_quick_sale/9` | The named kernel candidate for the sale spine. A single server-validated amount; no line array, no token, no discount surface. |
| `public.record_sale_by_phone/9` (and the retired /7 stub) | A thin dispatcher that delegates to `record_quick_sale`; carries no token and no discount. |

## RETIRED — kept in place, revoked from every browser role

| surface | disposition |
|---|---|
| `public.record_cart_sale/7` (no token) | The v51 itemized-cart path. It accepted **client-supplied line prices** and had no evaluation-token argument, so it could neither carry a studio discount **nor** guarantee server pricing. PS-1C.1 (v59) **RETIRES** it: EXECUTE is revoked from `public`/`anon`/`authenticated` (the function body is kept in place, matching the F2 revoke-not-drop idiom). The kernel `/9` token path is now the only browser cart entry, so every browser checkout is server-priced and token-governed. The v59 suite asserts `has_function_privilege('authenticated', …/7, 'execute') = false` and `…/9 = true`. |

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
