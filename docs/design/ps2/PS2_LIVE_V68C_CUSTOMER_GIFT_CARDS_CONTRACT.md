# v68c — Customer-facing gift-card view (PINNED)

Small, self-contained increment closing gap **B4** from the 2026-07-25 gap register: customers hold
gift-card value they cannot see. Forward-only; v61–v68b untouched. Reviewer/orchestrator: Fable.
Builder base: `9d640b8`. Pending version `20260725090000`.

## Why a migration is required (not a UI-only win)
`public.gift_cards` carries exactly ONE RLS policy — `gift_cards_sa_read` (super-admin). A signed-in
customer cannot read the table directly and must not be granted broad access to it (it holds
`purchaser_client_id`, `recipient_email`, and codes across the whole tenant). The sanctioned pattern
is a SECURITY DEFINER RPC scoped to the caller's verified customer link, exactly like every other
`customer_*` reader.

## 1. The RPC
`public.customer_get_gift_cards(p_business_slug text)` → jsonb.
- SECURITY DEFINER; `set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'`;
  `revoke all ... from public, anon, authenticated` then `grant execute ... to authenticated`.
- **Identity gate:** resolve the caller through the SAME verified-link context every sibling uses —
  `app.v32_customer_wallet_context(p_business_slug)` (see `customer_get_business_summary`). If no
  verified link, raise `42501 'verified customer link required'`. Do not invent a second identity path.
- **Scope:** only gift cards belonging to THAT business AND tied to the caller's client record for that
  business. Match on `purchaser_client_id = <the linked client id>`. If the schema also permits a
  recipient linkage the builder must state exactly what it matched on and why; do NOT match on
  `recipient_email` unless that email is a VERIFIED contact of the caller (unverified email matching
  would let anyone claim a card by typing an address — a security defect, not a feature).
- **Never return the code.** Return `id`, `initial_cents`, `balance_cents`, `status`, `created_at`, and
  a masked display hint only (e.g. last 4 of `code`). The code is a bearer instrument: a wallet view is
  for *balance visibility*, not for redemption.
- Shape: `{ business:{slug,name,currency}, cards:[...], total_balance_cents, count }`. Empty → `cards:[]`,
  totals 0 (never null-shaped errors).
- Read-only: writes nothing, no ledger, no audit row needed (it is a getter).

## 2. UI (app/index.html, customer wallet)
- New wallet section "Gift cards", rendered ONLY when the section returns ≥1 card (or via the existing
  capability-flag pattern if `customer_portal_capabilities` gains a flag — reuse, do not invent).
- Show per card: balance (house `money()`), original value, status, masked hint. Show the summed
  balance at section level. Plain-words note that redemption happens at the counter.
- Four states (loading / empty / error / denied) per house style; `CUI.*` components; low-literacy copy.
- Reuse `walletSectionShell` + the existing section-loader pattern; no new global state.

## 3. Non-goals (explicit)
No customer-side redemption. No code reveal. No issuing. No transfer. No changes to
`issue_gift_card`/`redeem_gift_card*`. No new table, no new column, no RLS policy change on
`gift_cards` (the definer RPC is the access path).

## 4. Tests
`db/tests/v68c_customer_gift_cards.sql` (rollback-only, one begin/rollback,
`\ir fixtures/pristine_chain_fixture.psql`): caller with a verified link sees ONLY their own cards for
that business; a second tenant's cards are invisible (cross-tenant isolation); a customer with no link
gets 42501; the code is NEVER present in the output (assert the returned jsonb contains no full code
value); empty case returns the zero shape; totals equal the sum of visible balances. Plus: `anon` cannot
execute; `authenticated` can.

## 5. Gates + ceremony
Fresh chain replay v65→v68c; ALL prior suites green; `npm run validate`; inline-script syntax + build;
writer registry curated (a read-only getter → allowlist, not a writer — justify); v21 forward-grant list
updated if a new authenticated RPC is added. Freeze → independent adversarial review → **PASS V68C** →
dry-run gate (exactly one pending, no `--include-all`) → `db push --linked` → post-apply verify →
reconcile + deploy. No `pg_get_functiondef` splice expected; if one is used, the comment-free +
prod-catalog-validated rule applies.
