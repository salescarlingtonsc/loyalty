# PS-2 LIVE Increment v66 — Staff-Assisted Top-Up Sale + Till (PINNED, rev 3: 11 mandatory corrections)

Implements directive §3 + the owner's mandatory v66 safety contract AND the 11 corrections (this rev).
Forward-only; v61–v65b untouched. RELEASE APPROVED extends to v66 (apply + deploy on independent **PASS
V66** without re-asking). Do NOT begin v67 until V66 is applied. The migration itself creates ZERO
lots/movements/payments; prod authority stays `unbuilt` for every REAL business.

## A. Authority-state safety (accepted core)
`record_sv_topup_sale` branches on `sv_authority.state`: **unbuilt** → refuse every top-up (typed
`sv_not_ready`), no test/real payment, no lot/movement; **shadow_testing** → synthetic test mints ONLY
(business AND customer structurally `is_synthetic`, `payment.method='test'`, no real payment, value
non-spendable); **ready_for_cutover** → same synthetic-only canary restriction, real top-ups still refused;
**live** → real `cash`/`card_terminal`/`paynow`/`manual` top-ups (never `test`); minted value consumable
only via the v67 checkout tender (v66 adds no spend path). Paid and bonus lots stay separate; no revenue
`sales` row and no points are written.

## 1. Close every alternate mint path (correction 1)
Audited: `public.sv_topup` and `public.sv_grant` are the ONLY functions that insert `sv_lots` / `issue`
`sv_lot_movements`, and BOTH are currently EXECUTE-granted to `authenticated` — a browser bypass of payment
evidence + authority safety. v66:
- **Retires `public.sv_topup` to a fail-closed stub** (same signature) that raises typed
  `use_record_sv_topup_sale`; **revokes** its execute from public/anon/authenticated.
- **Gates `public.sv_grant`** so it cannot create real customer value in v66: first-line refuse (typed
  `sv_grant_unavailable_v66`); execute revoked from browser roles. (A future increment may reintroduce a
  reviewed grant path.)
- `record_sv_topup_sale` becomes the ONLY authoritative top-up mint; it mints paid+bonus lots directly with
  full validation — it does NOT call the retired kernel.
- **Tripwire test:** fails if ANY live function other than `record_sv_topup_sale` can insert a paid
  (`class='paid'`) top-up lot, or if `sv_topup`/`sv_grant` are executable by anon/authenticated. No browser,
  staff, owner, Edge or service path may bypass payment evidence + authority safety.

## 2. Append-only payment model (correction 2)
- **`public.sv_topup_payments`** — IMMUTABLE original evidence, never UPDATEd: id, business_id, branch_id,
  client_id, operation_id (→ `sv_operations`, composite tenant FK, unique), plan_version_id, amount_cents
  int CHECK>0, currency text, method text CHECK in ('cash','card_terminal','paynow','manual','test'),
  reference text, reference_norm text (generated lower(btrim(reference))), confirmation_mode text CHECK in
  ('cash_received','staff_attested','synthetic_test'), actor uuid, confirmed_at timestamptz, created_at.
  Immutability guard (no UPDATE/DELETE); RLS owner+SA read; browser writes revoked.
- **`public.sv_topup_payment_events`** — APPEND-ONLY: id, business_id, payment_id (→ sv_topup_payments,
  composite FK), event_type text CHECK in ('confirmed','reversed','chargeback','correction'),
  operation_id uuid null, actor uuid, reason text, created_at. Immutability guard; RLS owner+SA read.
- Current payment state is DERIVED from the original row + its events. The original evidence is NEVER mutated
  to add reversal/chargeback links (those are future v68 events). v66 writes exactly one `confirmed` event
  per successful top-up.

## 3. Payment confirmation semantics (correction 3)
No ambiguous `status='recorded'`. `p_payment = {method, reference, amount_cents, currency, staff_confirmed}`:
- **cash** → `confirmation_mode='cash_received'`, mints immediately.
- **card_terminal/paynow/manual** → require a non-empty trimmed `reference` AND explicit
  `staff_confirmed=true`; `confirmation_mode='staff_attested'`; the UI must state Frenly has NOT
  independently verified settlement.
- **test** → synthetic business/customer only; `confirmation_mode='synthetic_test'`.
A pending/failed/incomplete/unconfirmed payment NEVER mints (mint and the `confirmed` event happen together,
in-txn). Frenly does not claim processor verification — no real payment-provider webhook exists.

## 4. Dedicated top-up permission (correction 4)
Generic sales-write is NOT sufficient. New helper `app.can_sell_topups(p_business)` = owner OR
`staff.role='manager'` OR active staff with `'sell_topups'` in `staff.module_perms`. Other staff denied.
Actor must also be active staff (`app.is_salon_member`) with `app.can_see_branch(business,branch)`. The Till
hides/disables the top-up action when the permission is absent; direct-RPC denial (42501) is tested
independently of the UI.

## 5. Current sellable plan version (correction 5)
Staff cannot sell an arbitrary historical version. `app.current_sellable_sv_version(p_business, p_plan)` =
the highest `version_no` among that ACTIVE plan's versions whose `effective_at` is null or ≤ now(). A future
version does not activate early; the previous current version stays sellable until the new effective date;
after the new version is effective an older one is refused; a retired plan has no sellable version.
`record_sv_topup_sale` refuses (typed `not_current_version`) unless `p_plan_version` equals the current
sellable version, and **revalidates at finalisation**. `get_sellable_sv_topup_plans(p_business, p_branch,
p_client)` returns server-authoritative rows: plan+version ids, plan name, amount paid, bonus, total,
effective discount, paid/bonus expiry, eligibility, limits, terms, points policy, authority state,
spendability (=false unless live), blockers. The Till uses this RPC and never reconstructs a plan from raw
tables.

## 6. Account locking + limit basis (correction 6)
Before any evaluate/mint: `pg_advisory_xact_lock` on a deterministic (business, client, asset) key; then
`sv_ensure_account` and `SELECT … FOR UPDATE` the account row; then read limit-driving rows under that lock;
then compute. **Maximum-balance basis = total OUTSTANDING unexpired value = paid + bonus + reserved +
temporarily-unavailable** (i.e. `sum(sv_lot_movements.cents)` over the account, which is gross of active
reservations) — NOT `sv_available_balance`. New helper `app.sv_total_outstanding(business, account)`. Two
concurrent top-ups competing for the final max-balance capacity resolve to exactly ONE winner (the advisory
lock serialises; the loser's max-balance check refuses). Lock order pinned (advisory → account → limit
reads) so no deadlock; tested by the two-connection harness.

## 7. Synthetic marker lifecycle (correction 7)
`businesses.is_synthetic boolean not null default false` + `clients.is_synthetic boolean not null default
false` (default false ⇒ every existing entity is REAL). A guard trigger permits changing `is_synthetic`
ONLY when `app.is_super_admin()` (or service role) — an owner cannot self-mark. `set_synthetic_marker`
(SA-only, audited): **false→true** stamps + audits; **true→false** is PROHIBITED if any synthetic evidence
remains (sv_topup_payments / sv_topup_payment_events / sv_operations / sv_lots / sv_lot_movements / sales /
program_entitlements for that entity) and otherwise requires SA + reason + audit. A synthetic customer may
not be used in a non-synthetic flow, and a REAL customer may never be used in a synthetic top-up (enforced
in `record_sv_topup_sale`: shadow/ready require both business AND client `is_synthetic`; live requires both
NOT synthetic). Structural exclusion: `v_business_billing` (and any real-business count / liability /
reporting read v66 touches) EXCLUDE `is_synthetic` businesses; comms/campaign/scheduled surfaces (deferred)
must also exclude them when built — pinned here so later increments inherit it. No names/prefixes anywhere.

## 8. Complete idempotency hash + reference uniqueness (correction 8)
The `sv_operations` request hash covers: business, branch, customer, plan_version, payment method, payment
amount, **currency**, and the **canonical reference** (`lower(btrim(reference))`, i.e. case-insensitive,
applied consistently). Exact retry → original result; any changed meaningful field under the same key →
typed conflict. Non-cash double-funding guard: a **partial unique index** on `sv_topup_payments
(business_id, method, reference_norm)` WHERE `method <> 'cash'` prevents the same business+method+normalised
reference from funding two successful top-ups (typed `duplicate_payment_reference`).

## 9. Currency validation (correction 9)
`p_payment.currency` must equal the business's configured `businesses.currency`; never silently coerce.
Mismatch → typed `currency_mismatch` (or `unsupported_currency` if the business currency is itself
unsupported). Plan price + payment amount stay integer minor units.

## 10. Preview before finalisation (correction 10)
`preview_sv_topup_sale(p_business, p_branch, p_client, p_plan_version, p_payment jsonb)` — READ-ONLY, no
DML — returns before confirmation: payment amount; paid value; bonus value; total value; projected account
total; balance-cap impact; frequency + lifetime remaining allowance; paid/bonus expiry; terms; authority;
spendability; payment-reference requirement; blockers. Finalisation (`record_sv_topup_sale`) repeats EVERY
check atomically. The preview is advisory and reserves nothing.

## 11. Op summary — `public.record_sv_topup_sale`
`record_sv_topup_sale(p_business, p_branch, p_client, p_plan_version, p_payment jsonb, p_idempotency_key
uuid) → jsonb`. Atomic order: actor from auth → `can_sell_topups` + active-staff + branch access → customer
in business → plan_version in business + parent plan active + version published + `effective_at` arrived +
is-current-sellable + branch eligibility → §A authority/synthetic gate → currency match → idempotency
envelope (hash §8; advisory lock §6) → §6 account lock + total-outstanding max-balance + rolling-window +
lifetime-cap → payment validation (§3) + non-cash reference-uniqueness (§8) → points guard (`policy_not_yet_
supported` if `topup_purchase_earns_points`) → mint ONE paid lot + ONE bonus lot (bonus>0) with independent
expiry, preserving immutable `plan_version_id`+sold terms (§6 of directive) → ONE `sv_topup_payments` +
ONE `confirmed` event → audit `SV_TOPUP_SALE` + receipt → return account projection (balances derived, cash
collected / paid issued / bonus issued split, accountant-ready categories, no hardcoded GST). Fail-closed:
any failure aborts the whole txn (zero partial records). Cash never double-counted as revenue.

## 12. Accounting / points / expiry (accepted, unchanged)
Top-up = cash collected + paid stored-value liability + promotional-bonus exposure — NOT revenue; no
`sales` row (real revenue recognised at the later checkout). Reports split cash collected / paid issued /
bonus issued / outstanding paid / outstanding bonus / refunds / chargebacks; no hardcoded GST.
`topup_purchase_earns_points` must be false for the pilot (else `policy_not_yet_supported`); v66 writes no
points; `stored_value_spend_earns_points` is a v67 concern. Paid lot uses `paid_expiry_days`, bonus lot
uses `bonus_expiry_days`, null ⇒ no expiry; classes never merged; a future plan edit never affects existing
lots.

## 13. Till UI (deploys after the op; server-authoritative)
Shows customer / plan name / amount paid / bonus / total / effective discount / paid+bonus expiry /
restrictions / method / reference / terms. Pre-confirm: “You are collecting S$X and issuing S$Y paid value
plus S$Z promotional bonus.” On success: receipt/reference / paid issued / bonus issued / total account
value / authority+spendability state. NEVER "available to spend" while authority ≠ live. No frontend
computes authoritative price/bonus/expiry/balance — all via `get_sellable_sv_topup_plans` /
`preview_sv_topup_sale` / `record_sv_topup_sale`. Top-up action hidden/disabled without `sell_topups`;
disabled for real top-ups unless `live`; in shadow_testing only a labelled owner/SA **test** action.

## 14. Phase boundaries — v66 may ONLY mint under §A
v66 must NOT: spend/reserve/refund/reverse/expire stored value; enable cutover; make authority `live`; send
real comms; enable customer self-service payment; write points; create Studio credit; activate every
business. Those are v67–v69+.

## 15. Tests (db/tests/v66_… rolled back) + gate matrix
Every §8-directive failure/concurrency case (success; exact replay; changed-request conflict; double-click;
two concurrent identical; two concurrent competing for final capacity → one winner; timeout; lost response;
inactive staff; wrong role; wrong branch; cross-tenant customer/plan; retired plan; future-effective
version; window/lifetime/max-balance caps; cash success; missing non-cash reference; wrong amount; failed
payment; injected failure at each write step) → assert ZERO partial records + exact final counts for
sv_topup_payments / sv_topup_payment_events / sv_operations / sv_accounts / sv_lots / sv_lot_movements /
audit_log. PLUS the correction tests: old `sv_topup` cannot bypass (raises) + not browser-executable; the
mint-path tripwire; `sv_grant` cannot create real v66 value; immutable payment never UPDATEd;
reversal/chargeback evidence append-only; staff_attested ≠ provider-verified; generic sales perm alone
insufficient + `sell_topups` works; historical version refused / latest-effective accepted / future not
early / one-winner capacity / max-balance includes reserved; synthetic marker cannot be removed while
evidence exists + synthetic excluded from billing/reporting; changed currency same-key conflicts; duplicate
non-cash reference rejected; wrong business currency rejected; preview reconciles exactly with the final
result; authority-state matrix (unbuilt refuse / shadow+ready synthetic-test-only / live real-only).
Gates: fresh full-chain replay; v65/v65a/v65b/v66 suites; two-connection top-up race; full prior SQL matrix;
RLS/ACL/SECDEF scans; writer registry (declare sv_topup_payments + payment_events + the mint writer, and the
sv_topup/sv_grant retirements); npm run validate; static build; JS parse; secret scan; git diff --check.
Freeze → independent PASS V66 → apply + normalize ledger (`20260725030000`) + deploy Till UI + retain
authority unbuilt for every real business + persist ONE structurally-synthetic shadow canary + verify zero
real customer payment/value. Registration bumps: db exec 85→86, canonical chain 101→102, pending 56→57.
