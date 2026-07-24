# PS-2A Increment A Independent Review Verdict — stored-value FOUNDATION (v61)

Reviewer: independent adversarial reviewer (not the author). Scope: the exact frozen commit
`4bf22d0` (delta `git diff 3e61778..4bf22d0`). **Build-only gate**: this verdict authorizes
nothing to be applied to UAT or deployed — a separate owner instruction is required regardless
of outcome (owner: "Do not apply to UAT or deploy merely because the builder suite passes").

## Formal verdict: **PASS PS-2A-A**

v61 ships exactly the pinned Increment-A foundation — accounts, plans/plan-versions, immutable
lots, the append-only movement authority, the idempotency envelope, derived-balance functions,
and a dedicated `sv_authority` shipped at `unbuilt` — with no path that can move customer value,
send comms, or reach `live`. Every mandated safety property is verified (several live and
adversarially). One non-blocking documentation inconsistency is noted (F1); it does not affect
schema, code, tests, or any safety property and does not gate the build.

---

## Frozen state
HEAD `4bf22d0`; parent `3e61778` (PS-1C.2 verdict); tree clean. v61 migration hash
`7f9bcae579e0c69221b031ac1fd1f253d2894ff1d73442fb2d597b33f9f3f99f` matches both manifests; the
supabase mirror `20260724200000_*` is **byte-identical** (`cmp` clean). Diff = 20 files, all in
scope. Seven sv tables introduced (`sv_plans`, `sv_plan_versions`, `sv_operations`,
`sv_accounts`, `sv_lots`, `sv_lot_movements`, `sv_authority`).

## Independent verification performed (local cluster, `frenly_freeze` = fresh 95-chain replay)
- **Suite re-run**: `v61_ps2a_stored_value_foundation.sql` → ALL PASS.
- **Governance/bookkeeping machine-verified**: `node --test` on the tripwire
  (`ps0-no-executor`), `ps0-writer-registry`, and the three phase0 suites → **35/35**, including
  the new "no migration function can set sv_authority to live/ready_for_cutover" and "no sv_*
  table carries a mutable balance column" assertions, the "every new table has RLS+ACL", and the
  "pending SECURITY DEFINER RPCs pin search_path + revoke" checks.
- **Authority guard, live**: on a seeded `unbuilt` row, `UPDATE → 'live'` and
  `UPDATE → 'ready_for_cutover'` are **rejected (23001)**; `DELETE` is rejected; `UPDATE →
  'shadow_testing'` is accepted (the sanctioned future transition). Seeded state is `unbuilt`.
- **Impersonation/scope-boundary probes** and corpus greps as below.

## Requirement-by-requirement

1. **No customer value can move; no comms can send.** Corpus grep confirms v61 contains no
   `sv_spend / reserve / release / reverse / refund / expire`, no cutover function, and no comms
   surface (`send_notification` / `event_outbox` / `captured_messages` / whatsapp / twilio). The
   only value writers are `public.sv_topup` (mint) and `public.sv_grant` (bonus mint) — both
   owner-only (`app.is_salon_owner`), both append-only audited (`SV_TOPUP` / `SV_GRANT`
   `audit_log` rows), both writing only `kind='issue'` movements.
2. **`live` is truly unreachable — proven three ways.** (a) No function anywhere sets
   `sv_authority.state` to `live`/`ready_for_cutover` (grep: the only writes to `sv_authority`
   are the seed inserting `'unbuilt'`). (b) `app.sv_authority_guard` (BEFORE INSERT/UPDATE/DELETE)
   rejects those two states unconditionally and blocks DELETE — verified live. (c) The new
   tripwire asserts no UPDATE / plpgsql assignment / INSERT can carry those literals, and it
   passes. `get_sv_account.spendable = (authority_state = 'live')` is therefore always false, with
   `authority_state` carried verbatim (no client inference).
3. **No mutable balance anywhere.** No sv table declares a `balance`/`balance_cents` column (grep
   + the new tripwire). `sv_lots` carries only the immutable `minted_cents` — there is no
   `remaining_cents` cache at all; every balance is derived as `Σ sv_lot_movements`
   (`sv_lot_remaining` / `sv_available_balance` / `sv_class_balance`). `sv_lots` and
   `sv_plan_versions` are immutable and `sv_lot_movements` append-only (shared
   `app.sv_immutable_guard`; `restrict_violation` on UPDATE/DELETE — asserted in the suite).
4. **PS-0 fidelity.** `sv_lot_movements.kind` CHECK is PS-0 §2's exact 8-kind frozen set
   (`issue/spend/expiry/reversal/refund/clawback/correction/bad_debt`). No `'mint'`/`'adjust'`
   movement-**kind** exists in code or suite (the suite asserts `kind='issue'`); `sv_topup` mints
   exactly two immutable lots (paid=`price_cents`, bonus=`bonus_cents`, bonus skipped at 0), each
   with an independent per-class `expiry_key` and a monotonic `earned_seq`, one `issue` movement
   each. Foundation enforces `issue > 0` and `bad_debt = 0`; the remaining kinds' sign matrix is
   deferred to their Increment-C write paths. `sv_operations.operation_type` legitimately retains
   `adjust` (a distinct axis — caller intent, not a movement kind).
5. **Idempotency envelope.** `unique(business_id, operation_type, idempotency_key)` +
   `request_hash` (sha256) + `pg_advisory_xact_lock` + cached-result replay. Identical retry →
   the cached result, one effect (suite: one op / two lots / two `issue` movements). Conflicting
   hash under the same key → `22023`, fail-closed **before any write** (suite: zero lot/movement
   rows). All validation (plan-version, client, authority) precedes the op insert, so a
   rolled-back invalid `plan_version` leaves no orphan op/lot/movement and the key is reusable.
   The coordinator's real two-connection race (same `operation_id`, 1 op / 2 lots / 2 movements /
   total 12000) is consistent with the standard, already-proven house envelope.
6. **House invariants.** RLS + owner/SA read policies on all seven tables; every table revoked
   from public/anon/authenticated with SELECT-only browser grants (zero browser
   INSERT/UPDATE/DELETE). `sv_topup` / `sv_grant` / `get_sv_account` are SECURITY DEFINER, pin
   `search_path`, are revoked from public/anon/authenticated and granted only to authenticated;
   the `app.*` helpers stay revoked. Composite tenant FKs throughout
   (`(id,business_id)` / `(client_id,business_id)` / `(lot_id,business_id)` …). Integer cents only
   — no `numeric`/`double`/`float` money on any sv table. Cross-tenant top-up/read denied (suite
   §14 + owner/member checks + composite FKs). Machine-verified by the phase0 SECURITY-DEFINER and
   new-table-RLS tests.
7. **G2/G3/G4 interpretations — all sound; I agree with each.**
   - **G2** (start the sv ledger empty; treat `gift_cards` as a read-only reconciliation analog;
     gift-card migration out of scope): the honest reading. No stored-value incumbent exists to
     shadow; the nearest analog carries the exact mutable-balance anti-pattern this contract
     forbids, so reconciling read-only against it (Increment B) without moving real value is
     correct, and migrating gift cards would move real customer value (forbidden this phase).
   - **G3** (dedicated `sv_authority` instead of forcing `benefit_registry`): correct —
     `benefit_registry`'s CHECK makes `studio_executor+shadow` impossible and cannot express 4 of
     the 7 required states. `benefit_registry.stored_value` is genuinely untouched (v61 contains
     zero `benefit_registry` DML — the sole match is a comment).
   - **G4** (do NOT reroute `grant_credit`/`earn_bonus_points` into the sv ledger): correct — they
     are `points_loyalty`/shadow; routing them would treat points as currency, violating the
     owner's §4 and CLAUDE.md's "Points ≠ credit".
8. **No scope creep / gates.** PS-GATES flips PS-2 → `yes` scoped explicitly to the Increment-A
   foundation; PS-3/4/5 stay `no`. The tripwire is re-scoped, not deleted: it drops the
   now-legitimate `sv_topup`/`sv_lot_movement` from the forbidden list but **keeps
   `sv_spend_allocation` and `refund_sv_operation` forbidden** (Increment C) and adds the two new
   structural assertions. The checkout kernel (`ps1c_plan_checkout` / `record_cart_sale`), the
   executor (`ps1b_execute_event`), and `benefit_registry` are untouched (no redefinition/DML).
   Manifests coherent (db 92→93, canonical 94→95; hash matches); v21 forward-scan includes v61 so
   its three new authenticated RPCs are allowlist-covered.

## Builder/reviewer notes — judgment
- **(i) `sv_authority` BEFORE-DELETE guard alongside `ON DELETE CASCADE` from businesses —
  sound.** This is the established house pattern (v41 op tables, `studio_rule_emergency_pauses`
  all do the same). Businesses are already never hard-deletable because append-only ledgers with
  DELETE guards + cascade would abort any hard delete; v61 adds another such guard. The net effect
  is a *stronger* guarantee — stored-value authority history cannot be destroyed by deleting a
  business — which is the safest outcome. No regression.
- **(ii) Pinned earn-pause policy (customers keep spending held value during an `earn` pause) —
  I agree.** An `earn` pause stops new value creation (grants/top-ups); freezing already-granted
  balances would convert an operational safety action into a customer-visible seizure. Stopping
  spend correctly requires an explicit `redeem`/`all` pause. Moot in PS-2A (authority never
  `live`), but the pinned semantics are the customer-protective and operationally sensible choice.

## Findings
- **F1 (LOW — documentation, non-blocking).** `docs/design/ps0/writer-registry.json` line 194
  (`db.fn:public.sv_topup/4`) and line 206 (`db.fn:public.sv_grant/5`) describe the mint movement
  as `"one 'mint' sv_lot_movement"` / `"one 'mint' movement"`, whereas the actual DB movement
  `kind` is **`'issue'`** (PS-0 §2 frozen vocabulary — correctly used by the migration's CHECK and
  writes, and asserted as `'issue'` by the suite). The mint→issue reconciliation the mandate asked
  me to confirm **is complete in code and suite** (point 4's scope); this is a residual prose
  inconsistency in the audit registry only, newly introduced in this commit. Recommend changing
  the two registry strings `'mint'` → `'issue'` for fidelity. No effect on schema, behaviour,
  tests, gates, or any safety property; does not block the build gate.

## If/when the owner authorizes UAT apply (belt-and-suspenders; not gate conditions)
1. After apply, confirm every existing tenant received exactly one `sv_authority` row at
   `unbuilt` (the backfill + the new-business trigger) and that `get_sv_account` returns
   `spendable=false` / `authority_state='unbuilt'` for a real client.
2. Re-run the two-connection `sv_topup` race against a disposable UAT-schema clone (never the
   live DB) to re-confirm one op / two lots / two `issue` movements under contention.
3. Confirm `benefit_registry.stored_value` is still `studio_executor/unbuilt` post-apply (untouched).
