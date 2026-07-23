# PS-1C.1 Independent Review Verdict — till UI kernel integration + legacy-cart hardening (v59)

Reviewer: independent adversarial reviewer (not the author). Scope: the exact frozen commit
`7c1e26d` (delta `git diff 730ff7e..7c1e26d`). Single-verdict gate: on PASS the owner has
pre-authorised UAT apply + deploy.

## Formal verdict: **PASS PS-1C.1**

v59 puts the live till on the v58 checkout kernel, retires the client-priced legacy cart,
adds a permissioned/audited manual-price line, types the zero-total outcome, and closes the
sale_items impersonation surface — meeting every owner requirement with no forbidden surface,
all house invariants intact (machine-verified), and an ALL-PASS suite set (independently
re-run) plus my own adversarial probes. Findings below are non-blocking.

---

## Frozen state
HEAD `7c1e26d`; parent `730ff7e` (PS-1C verdict); `git status` clean. v59 migration hash
`299a6f9a1c7b4e04c01e52d9f02ae8c23d71fa6cf559e3d2659470fa12d090fc` matches both manifests;
the supabase mirror `20260724180000_*` is **byte-identical** (`cmp` clean). `git diff --check`
clean; no secrets. Diff = 19 files, all within PS-1C.1 scope (migration + mirror, the till UI,
three test artifacts, the paths doc, tripwire, writer-registry, and manifest/phase0
bookkeeping). PS-GATES is unchanged — PS-1C.1 is a hardening increment inside the
already-authorised PS-1C phase, so no phase-authorisation change was needed.

## Independent verification performed (local cluster 127.0.0.1:5499, `frenly_freeze` = fresh 93-chain replay)
- **Suites re-run**: `v59_ps1c1_cart_hardening.sql` → ALL PASS; `v58_ps1c_checkout_kernel.sql`
  → ALL PASS (regression at v59 depth); `v51_sale_line_items.sql` → clean exit 0 (0
  errors) with the kind-guard present.
- **Live schema**: `custom_line_limit_cents` column present; `trg_sale_items_kind_guard`
  present; `role_perms('owner')`/`('manager')` include `custom_price_lines`, `role_perms('staff')`
  = `{view_sales,create_sales}` (no custom); `/7` revoked from authenticated, `/9` granted.
- **Adversarial probes** (rolled back): a `service`/`product` line with `unit_price_cents` or
  `discount` → `client_priced`; null config → `ok` / zero discount; missing catalog row →
  `price_error`; `record_quick_sale(…,0,…)` → positive-amount raise. Impersonation guard:
  `service` under a `quick_sale` parent accepted, `package` under `quick_sale` **rejected 23514**,
  `membership` under a `package`-kind parent accepted (guard is precisely scoped — it never
  over-blocks a dedicated engine's own kind).
- **Bookkeeping machine-verified**: `node --test` on the phase0-foundation suite → 18/18,
  including "pending public SECURITY DEFINER RPCs pin search_path and revoke default execution"
  (covers v59's `evaluate_checkout` and `record_cart_sale/9`).

## Requirement-by-requirement

**(§1 role_perms — CRITICAL review-round catch, re-verified).** `app.role_perms` is
**byte-faithful to v14d** (`20260718180659_frenly_v14d_harden_search_path.sql`) plus exactly
`custom_price_lines` on owner and manager. All eight owner perms (incl. `manage_team` /
`manage_billing`), manager's four, and the `staff` / `frontdesk` / `bookkeeper` / `stylist` /
`receptionist` rows are preserved verbatim; the pinned `set search_path = pg_catalog, pg_temp`
is identical. The prior stale-v10.1 rebuild (which stripped roles) is gone, and the builder's
"no staff" flag is confirmed resolved (v14d has `staff`; v59 keeps it — verified live).

**(§1/§2 UI truthfulness — app/index.html).** The old client-side totals
(`saleSubtotalCents` / `grandTotalCents`) are removed. The sole finaliser call (L4336-4338)
is `record_cart_sale` with `p_lines:null` + `p_evaluation_id`; service/product lines send
`{catalog_kind, catalog_id, qty}` only, custom sends `{catalog_kind:'custom', description,
amount_cents, reason}` (L4032-4036). Every payable figure in the panel is copied verbatim from
`evalResult` (L4109-4126); suppressed effects render with plain-language reasons
(L4097-4108). The evaluate key is a fresh uuid per call (L4083); the finalise key is the F2
`writeAttemptKey`/`FINALISE_SLOT` pattern, stable across retries/re-evaluations of the same
cart (fingerprint = branch+client+lines), cleared on success (L4342), on cart change
(`onSaleLinesChanged`, L4065), and on new checkout (L4282). `duplicate_ignored` is treated as
success (L4344, `isReplayResult`). The stale path (L4383-4388) re-evaluates **once** and sets
`staleConfirm`, which shows the new total and waits for an explicit "Confirm new total" click
— it never auto-finalises and cannot loop; the amount is never changed silently. Because every
P0001 in the finaliser rolls the sale back, the re-evaluate-with-new-token confirm cannot
double-sell; a network failure keeps the key for a same-token retry that dedupes to
`duplicate_ignored`.

**(§3 /7 retirement + custom lines + impersonation).** `record_cart_sale/7` EXECUTE is revoked
from public/anon/authenticated (kept in place per the F2 revoke-not-drop idiom); `/9` is the
only browser cart entry (verified live). Custom lines require `is_salon_owner OR
has_perm('custom_price_lines')` (owner-controllable via role assignment; per-staff override
machinery does not exist and is documented), are bounded by `businesses.custom_line_limit_cents`
(default $500), demand a 3..200-char description **and** reason, lock qty to 1, and reject any
key other than the five allowed — while `service`/`product` lines still hard-reject **all**
price keys (the rejection was correctly restructured to run only on catalog lines). The
finaliser writes `item_type='custom'` sale_items (re-projected AS-IS from the immutable token,
never re-priced) and one `CUSTOM_PRICE_LINE` audit row per line carrying the finalising actor
plus the token-frozen `entered_by`/`reason`; the amount is inside the `cart_hash` projection.
The permission gate sits at the minting boundary (a non-permissioned user gets
`custom_line_denied` from evaluate and thus cannot craft a custom-line token — no escalation).
The DB-level `sale_items_kind_guard` rejects `package`/`membership`/`gift_card` item_types under
a `quick_sale`/`cart_sale` parent (23514) and, because the dedicated engines write **no**
sale_items and the only historical such writer was the now-retired /7, breaks nothing
legitimate (probed live).

**(§4 zero-total).** `ps1c_plan_checkout` returns typed `total_zero_not_supported` **before**
minting a token, so `evaluate_checkout` persists no evaluation row and no op-ledger row (v59
suite §5 asserts both counts unchanged); the finaliser carries a belt-guard raising the **same
typed 22023** (never a stale P0001) for a hand-crafted/pre-migration zero token. The UI maps
`total_zero_not_supported` to a typed message with **no** re-evaluate, at both evaluate and
finalise (L4055, L4381-4382).

**(§5 legacy-path proofs).** The v59 suite exercises all eight non-kernel value writers —
`sell_package`, `enroll_membership_v41`, `run_membership_renewals`, appointment completion
(status→completed trigger), gift-card issue + `redeem_gift_card_v41`, `record_payment`,
`record_credit_tender`, `redeem_program_entitlement` — asserting each lands its own rows **and**
that `checkout_discount_lines` is unchanged across all of them (zero studio discount lines). Re-run
green.

**(Scope / forbidden).** No stored value, no real comms, no new customer-programme activation.
The only `credit_ledger`/`points_ledger` touch is a `points_ledger` **read** to report
`points_earned`; no ledger writes. The executor (`ps1b_execute_event`), `on_sale_recorded`, and
the `loyalty_ledger_write_guard` are untouched (referenced only in comments). Loyalty earns on
the discounted/custom final total because the kernel reduces `sales.amount_cents` before
`on_sale_recorded` fires.

## House invariants
The four table-touching v59 functions (`sale_items_kind_guard`, `ps1c_plan_checkout`,
`evaluate_checkout`, `record_cart_sale/9`) are SECURITY DEFINER with pinned search_path and are
revoked from public/anon/authenticated; the two browser RPCs additionally grant execute to
authenticated. `role_perms` is a pure `immutable` lookup (no table access, no definer needed)
and CREATE-OR-REPLACE preserves its v14d ACL. Machine-verified by the phase0 SECURITY-DEFINER
test.

## Suite-strengthening legitimacy (point 7)
The v51 edit asserts the /7 revoke, then re-grants /7 **inside** the rolled-back transaction to
keep historical coverage — I confirmed /7 is still revoked live after the suite runs (the
re-grant cannot leak). The v58 edit replaces the old "/7 works as a safe wrapper" call with a
"revoke held" assertion. Both add the new stricter reality without weakening any historical
assertion. The tripwire's single-writer test correctly widens to accept the finaliser in
v58 **or** v59 (v59 CREATE-OR-REPLACEs it) while keeping "no other migration writes
checkout_discount_lines" and the "insert lives inside record_cart_sale, never in
evaluate_checkout" positional guards. The writer-registry adds a truthful
`browser.rpc:evaluate_checkout` binding; the `record_cart_sale` browser binding is present.

## Non-blocking observations
- **O1 — `p_paid` hardcoded `true` in the till (acceptable).** The till always takes payment at
  checkout; unpaid/partial/later-paid remain the kernel's API-level capability (v58, preserved
  by v59). A point-of-sale till taking payment at checkout is a sound product decision, and the
  API path is unchanged — acceptable for PS-1C.1. (Deposits/invoicing are a separate future
  workflow.)
- **O2 — zero-total belt-guard placement (trivial).** In the finaliser the zero-total guard
  (7.6) runs after the budget re-check (7.5); both positions are safe because the raise rolls
  the whole transaction back, so no sale or budget commit survives. Marginally cleaner earlier;
  no behavioural impact.
- **O3 — GST informational extraction (⚖️, carried forward).** Unchanged from PS-1C; still the
  correct GST-inclusive model and still appropriately flagged for counsel.

## To confirm on UAT during apply/deploy (belt-and-suspenders; not gate conditions)
1. Apply v59 over the real v58 chain and confirm the `sale_items` kind-guard install and the
   `role_perms` replace succeed against production history (the guard only newly-rejects
   `package`/`membership`/`gift_card` under `quick_sale`/`cart_sale` parents — confirm no such
   historical rows exist that would be re-validated on any future write path).
2. Confirm on the live app that a `custom_price_lines`-less login (e.g. frontdesk) can ring a
   normal checkout but is denied a custom line (`custom_line_denied`), and that owner/manager can
   enter one within the firm limit with a `CUSTOM_PRICE_LINE` audit row.
3. Drive one real till checkout end-to-end (evaluate → finalise → duplicate-tap → stale
   re-confirm) and confirm the payable amount is only ever the server figure and no re-eval loop
   occurs.
