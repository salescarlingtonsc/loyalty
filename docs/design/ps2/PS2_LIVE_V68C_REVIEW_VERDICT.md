# v68c (Customer-facing gift-card balance view) — Independent Review Verdict

## VERDICT: `PASS V68C` — **APPLIED TO PRODUCTION 2026-07-26**

- **Frozen commit:** `e64ba531e457bbf1a646e99d2c25ec144c8283d6`
- **SHA-256 (canonical + mirror, byte-identical):** `23f88d2fa995d26e45cd84001972efdc9663336713457951175ba1aa08689539`
- **Applied via** `supabase db push --linked` at canonical `20260725090000`; dry-run gate showed
  exactly one pending migration, zero mismatches. Additive only: ONE new function, nothing replaced,
  no splice.

## What it delivers (gap-register B4)
`public.customer_get_gift_cards(text)` — a SECURITY DEFINER reader letting a customer see gift-card
BALANCES they purchased, plus the wallet section that renders them. Required a migration because
`public.gift_cards` carries a single super-admin RLS policy; the definer RPC is the access path.

## Security verification (independent, executed not argued)
- **Code never leaks.** Output walked recursively; zero leaf matches for full codes (incl. 503-char
  and unicode codes), `recipient_email`, or `purchaser_client_id`. Projection is an explicit
  allowlist; `code_suffix = right(code,4)` is a hard cap no input can lengthen.
- **Isolation holds every direction:** pending/rejected/unlinked links, disabled identity, cross-slug
  requests, `'%'` and SQL-injection-shaped slugs → 42501; null `auth.uid()` → 28000; anon → no EXECUTE.
  Notably: `gift_cards_purchaser_client_id_fkey` references `clients(id)` only, so a tenant-A card can
  FK-point at a tenant-B client — the reviewer planted exactly that and the
  `business_id AND purchaser_client_id` conjunction closed it (count 0, zero leaks).
- **Gate is byte-identical to the sibling gate** (`app.v32_customer_wallet_context`); business_id AND
  client_id both come from the resolver, never from caller input.
- **Suite mutation-tested:** re-injecting the full code, or adding `recipient_email` to the predicate,
  each makes the suite FAIL.

## Orchestrator adjudications (reviewer agreed with all four)
1. `validate` 506 not ≥507 — my estimate was wrong; no test dropped (verified against parent commit).
2. Stale `counts` block in the writer registry — pre-existing since `7208a15`; builder recorded live
   figures rather than rewriting 14 unreconstructable numbers. Machine-checked surfaces green.
3. (a) wallet-local currency instead of `money()` — a correctness fix (`money()` reads the STAFF
   business, unset in the customer wallet). (b) added `truncated`: list capped at 100 but `count` and
   `total_balance_cents` computed over the FULL set — verified empirically with 105 cards
   (listed=100, count=105, total=10500, truncated=true). A bounded list can never understate money,
   and the bound is visible — the no-silent-caps principle.
4. **No module gate** (siblings raise 42501 when their module is off). Accepted: a gift card is money
   already collected and still owed; `enabled_modules` is a navigation toggle; the repo's own v14
   ruling says module checks must not strand rows. Reviewer confirmed no information-disclosure risk —
   the caller already holds a verified link, so nothing new is revealed. Siblings gate features; this
   gates a liability.

## Post-apply production state (verified)
Ledger `20260725090000`; function present, SECURITY DEFINER, canonical search_path, anon EXECUTE false
/ authenticated true; body masks the code and mentions `recipient_email` only in the comment explaining
it is never projected. `gift_cards` untouched (3 rows, still 1 policy). All real businesses
`sv_authority='unbuilt'`. **Blast radius at apply time is zero:** `customer_wallet` platform flag is
false and prod has 0 verified customer links, so the RPC raises `0A000` for every caller until that
gate is deliberately opened.

## Findings (none blocking)
- **D1 (informational):** `right(code,4)` would return a whole code shorter than 4 chars. Proven
  unreachable — both `issue_gift_card` overloads generate 11/15-char codes and accept no caller code;
  `gift_cards` has no browser grants; prod `min(length(code)) = 11`. Pre-existing convention shared
  with `staff_list_gift_cards` and `staff_get_client_credit_history`. Optional future hardening:
  `case when length(code) >= 4 then right(code,4) end`, applied uniformly to all three readers.
- **D2 (low, pre-existing, tracked):** stale registry `counts` block — owed its own reconciliation.
- **D3 (informational):** no new node test case; coverage rides the parametric preflight map, the v21
  forward-grant union, and the psql suite.
