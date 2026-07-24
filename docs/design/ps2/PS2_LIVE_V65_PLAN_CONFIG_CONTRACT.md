# PS-2 LIVE — Increment 1 (v65): Top-Up Plan Configuration (PINNED)

Implements directive §1 (Top-Up Plan Configuration) + the §12 effective-discount/warning surface at the
DB layer. First forward migration of the RELEASE APPROVED pilot arc (see
[[ps2-live-cutover-pilot-mandate]]). **Forward-only:** v61–v64 files and statements are NOT rewritten;
v65 only ADDs. Reuses the immutable-version idiom (v26/v55/v61). No value moves, no cutover, no UI in this
increment (UI lands in a later increment). Authority stays `unbuilt` on every business.

## 0. Ground truth (frozen at read time)
- `sv_plans` (v61): id, business_id, name, active, created_at — a plan *container*.
- `sv_plan_versions` (v61, immutable, guarded `sv_plan_versions_immutable_guard`): id, business_id, plan_id,
  version_no, price_cents, bonus_cents, **single shared** expiry_days, terms_snapshot jsonb, published_at,
  created_at. Consumed by `sv_topup` (v61/v64) + refund math.
- **No owner authoring RPC exists** — plan versions are only insertable by raw SQL today. §1 is greenfield.
- Eligibility refs present: `branches` (id, business_id, is_default…), `services` (id…, `category text`),
  `products` (id, business_id, sku, retail_price_cents — no category column), `clients`.
- 0 plans / 0 plan_versions on prod (nothing to migrate).

## 1. Schema — mutable draft → immutable published version
Editing happens on a mutable **draft**; publishing compiles the draft into an immutable **version** row. The
immutable row is the authoritative sold-plan snapshot (directive §1 "previously sold top-ups must keep their
complete sold-plan snapshot" — the version is frozen by the existing guard; a sale copies the version_id).

**`public.sv_plan_drafts`** (mutable, owner-editable, RLS owner+SA read, browser writes revoked):
- id, business_id (FK businesses, composite uk (id,business_id)), plan_id uuid null (null until first publish
  binds/creates a plan), status text CHECK in ('draft','published','discarded') default 'draft',
  actor uuid, created_at, updated_at, published_version_id uuid null.
- Config columns (all captured, directive §1):
  - customer_facing_name text (btrim ≥ 1)
  - price_cents int CHECK ≥ 0, bonus_cents int CHECK ≥ 0  (total_usable = price+bonus, derived)
  - paid_expiry_days int null CHECK (null or > 0), bonus_expiry_days int null CHECK (null or > 0) — INDEPENDENT
  - eligible_branch_ids uuid[] null (null = all branches), eligible_service_ids uuid[] null,
    eligible_product_ids uuid[] null, eligible_service_categories text[] null (null = all)
  - min_spend_cents int null CHECK (null or ≥ 0)
  - stacking_policy text CHECK in ('stackable','not_with_other_discounts','exclusive') default 'stackable'
  - max_balance_cents int null CHECK (null or ≥ 0)   -- max customer stored-value balance
  - purchase_window_days int null, purchase_max_in_window int null   -- per-customer frequency
  - purchase_lifetime_cap int null   -- per-customer lifetime purchase count cap
  - refund_policy text CHECK in ('full_unused','proportional','unused_only','no_refund') default 'proportional'
    -- maps to the PS-0 refund model already in v63 (sv_plan_refund); v65 stores the choice only
  - spend_order text CHECK in ('bonus_first','paid_first','earliest_expiry_first','proportional')
    default 'proportional'   -- v63 sv_allocate_spend currently implements proportional; other variants enforced in v67
  - earns_points boolean default false
  - customer_terms text null
  - accounting_inputs jsonb default '{}'   -- classification INPUTS only; NO hardcoded GST/tax conclusion
  - effective_at timestamptz null   -- future effective date (null = immediate on publish)
- Guard: updates allowed only while status='draft' (published/discarded drafts are frozen); status may go
  draft→published or draft→discarded once; no delete.

**ALTER `public.sv_plan_versions` ADD** (immutable snapshot mirrors the draft's config at publish; all nullable
or defaulted so the v61 guard/insert contract is untouched and existing 0 rows are unaffected):
customer_facing_name, paid_expiry_days, bonus_expiry_days, eligible_branch_ids, eligible_service_ids,
eligible_product_ids, eligible_service_categories, min_spend_cents, stacking_policy, max_balance_cents,
purchase_window_days, purchase_max_in_window, purchase_lifetime_cap, refund_policy, spend_order, earns_points,
effective_at, accounting_inputs, retired_at timestamptz null, source_draft_id uuid null.
(`expiry_days` stays for back-compat; publish sets paid_expiry_days := coalesce(paid_expiry_days, expiry_days)
so v61 `sv_topup` keeps working until v66 create-or-replaces it to read the independent fields.)

**`public.sv_plan_guardrails`** (firm-scoped configurable sanity limits, directive §1 "configurable
margin/sanity limits"): business_id PK (FK businesses), warn_discount_bps int default 3000,
hard_discount_bps int default 7000, seeded per business by a BEFORE INSERT trigger on businesses (idempotent),
owner+SA read. Preview warns at ≥ warn, requires override_reason at ≥ hard — but NEVER blocks (directive: "do
not block an owner merely because a plan is aggressive").

## 2. Effective discount + warnings (directive §1/§12)
`app.sv_plan_effective_discount_bps(price, bonus)` = round(bonus * 10000 / nullif(price+bonus,0)) — pure.
`public.preview_sv_plan(business, draft_id)` (owner-only, READ-only, no DML) →
`{customer_facing_name, price_cents, bonus_cents, total_usable_cents, effective_discount_bps, warnings:[...],
override_required:bool, warn_threshold_bps, hard_threshold_bps}`. Warnings enumerate: aggressive discount
(≥ warn), override-required (≥ hard), bonus>paid, zero price with positive bonus (giveaway), missing expiry on
large balances, etc. — all informational, none blocking.

## 3. Owner RPCs (all `security definer`, owner-only via `app.is_salon_owner`, audited, revoked from anon)
- `create_sv_plan_draft(p_business uuid, p_config jsonb) → jsonb` — validates+inserts a draft, returns draft.
- `update_sv_plan_draft(p_business uuid, p_draft uuid, p_config jsonb) → jsonb` — edits a draft (draft status only).
- `preview_sv_plan(p_business uuid, p_draft uuid) → jsonb` — §2.
- `publish_sv_plan_version(p_business uuid, p_draft uuid, p_override_reason text default null) → jsonb` —
  compiles draft→immutable version: creates the `sv_plans` container if plan_id null (name=customer_facing_name),
  version_no = coalesce(max(version_no),0)+1 for that plan, copies every config field into `sv_plan_versions`,
  sets published_at=now(), links draft.published_version_id, sets draft.status='published'. If effective
  discount ≥ hard_discount_bps and p_override_reason is null/<3 chars → raise 22023 (override required); the
  override_reason is PRESERVED in `audit_log` (SV_PLAN_PUBLISHED detail). Idempotent by draft (re-publish of a
  published draft returns the existing version, replayed:true).
- `retire_sv_plan(p_business uuid, p_plan uuid, p_reason text) → jsonb` — sets sv_plans.active=false; stamps
  retired_at on that plan's live versions; sold snapshots keep provenance (immutable). Audited SV_PLAN_RETIRED.
- `get_sv_plans(p_business uuid) → jsonb` — owner list: plans + their versions (config summary + effective
  discount + active/retired) + open drafts.

## 4. Invariants / safety (house rules)
- Canonical `db/migrations/20260724_frenly_v65_ps2live_plan_config.sql` + byte-identical `supabase/migrations`
  mirror (next timestamp after v64 `20260724230000` → `20260725000000`).
- RLS on sv_plan_drafts + sv_plan_guardrails; owner+SA SELECT; browser writes revoked; definer RPCs granted to
  authenticated, revoked from anon/public; `app.*` helpers revoked from browser roles.
- Draft write-once transitions (guard); sv_plan_versions stays immutable (v61 guard untouched); ADD COLUMN only.
- Integer cents everywhere; no floats. No value ledger touched (0 movements/lots). Authority untouched (unbuilt).
- Composite tenant FKs (id,business_id) on new tables. Search_path pinned 'pg_catalog,public,app,pg_temp'.
- PS-GATES tripwire additions: no cutover fn still asserted; NEW — publishing a plan writes NO sv_lot_movements
  and does NOT transition sv_authority (a plan is configuration, not value).

## 5. Tests (db/tests/v65_ps2live_plan_config.sql — rolled back)
draft create/update/preview/publish/version/retire; effective-discount arithmetic (exact bps); warn vs hard
threshold + override-required + override_reason preserved in audit; aggressive plan NOT blocked; publish
immutability (published draft frozen; published version guarded); version_no increments per plan; sold-snapshot
provenance (version carries full config); eligibility arrays round-trip; independent paid/bonus expiry stored;
owner-only (frontdesk/anon 42501); cross-tenant IDs denied; get_sv_plans isolation; publish writes zero
sv_lot_movements + leaves authority unbuilt (tripwire); guardrails seeded per business. Plus: fresh replay,
prior suites green, validate, writers 0/0, RLS/ACL/SECDEF scans.

## 5b. REV 2 — corrections applied after the independent CHANGES REQUIRED verdict
All 15 findings folded in (migration + suite green on a fresh v64 base):
1. **Immutable retirement.** `sv_plan_versions` stays fully immutable (v61 `sv_immutable_guard` rejects
   all UPDATE/DELETE). Retirement/reactivation mutate ONLY the `sv_plans.active` container and append to
   a new append-only **`sv_plan_status_events`** (actor/prior/new/reason/ts). No `retired_at` on the
   version. Retire is proven to leave the version row byte-identical (md5 compare in the suite).
2. **Positive paid.** `price_cents > 0` enforced as a typed 22023 validation error before insert (v61
   already CHECKs it); a zero-paid promo is `sv_grant`, not a top-up.
3. **Configurable guardrails.** `set_sv_plan_guardrails(business, warn, hard, idem)` owner RPC (validates
   `0 ≤ warn ≤ hard ≤ 10000`, idempotent, audited); reads coalesce to 3000/7000 defaults (no raw SQL);
   effective values returned by `get_sv_plans`.
4. **Eligibility validation.** Membership + active checked at preview/publish (cross-tenant/inactive →
   typed error); arrays canonicalised (distinct + sorted) at apply; **empty array rejected**; `null` = all.
5. **Strict config patch.** `sv_plan_assert_config` rejects unknown keys / wrong JSON types / malformed
   scalars / empty eligibility arrays / over-long text (name ≤200, terms ≤5000); missing = unchanged;
   JSON `null` clears only nullable fields (non-nullable null → typed error).
6. **Optimistic concurrency.** `sv_plan_drafts.revision`; `update`/`publish`/`discard` take
   `expected_revision`; a stale editor gets a typed 22023 conflict.
7. **Publish concurrency.** `SELECT … FROM sv_plans … FOR UPDATE` before `max(version_no)+1`; preserves
   v61 `unique(plan_id, version_no)`; deterministic replay/conflict. (True two-connection race → harness.)
8. **Draft↔version FKs.** `sv_plan_versions.source_draft_id → sv_plan_drafts` (+ partial `unique` so one
   draft mints at most one version) and `sv_plan_drafts.published_version_id → sv_plan_versions`, both
   satisfied atomically in the publish txn.
9. **Explicit points policy.** `topup_purchase_earns_points` + `stored_value_spend_earns_points` (both
   default false) replace the ambiguous `earns_points`.
10. **Purchase-limit consistency.** window_days/max_in_window both-or-neither; `max_balance_cents` must fit
    ≥ one purchase of total usable — otherwise a typed publish blocker.
11. **Publish readiness.** `preview_sv_plan` returns `validation_errors` / `warnings` / `override_required`
    / `publishable` separately; publish blocks on structural errors (incl. required customer terms);
    warnings are overridable with a reason at/above the hard limit.
12. **Full lifecycle.** `discard_sv_plan_draft`, `clone_sv_plan_version_to_draft`, `retire_sv_plan`,
    `reactivate_sv_plan`; publishing a new version under a retired plan is denied until explicit reactivation.
13. **Complete read shape.** `get_sv_plans` returns full per-version config + status history + guardrails.
14. **Idempotency + audit.** `sv_plan_operations` envelope (business, op_type, key, request_hash, actor,
    result) on create/publish/discard/clone/retire/reactivate/guardrail; every state change audited.
Final RPC set: `create_sv_plan_draft(biz,cfg,idem)` · `update_sv_plan_draft(biz,draft,cfg,exp_rev)` ·
`preview_sv_plan(biz,draft)` · `publish_sv_plan_version(biz,draft,exp_rev,idem,override?)` ·
`discard_sv_plan_draft(biz,draft,exp_rev,idem,reason?)` · `clone_sv_plan_version_to_draft(biz,ver,idem)` ·
`retire_sv_plan(biz,plan,reason,idem)` · `reactivate_sv_plan(biz,plan,reason,idem)` ·
`set_sv_plan_guardrails(biz,warn,hard,idem)` · `get_sv_plans(biz)`.

## 6. Explicitly deferred to later increments (NOT in v65)
Staff top-up SALE + payment evidence + limits enforcement (v66); sv_topup create-or-replace to read
independent expiry + enforce max_balance/frequency/cap (v66); checkout-kernel SV tender + spend-order variant
enforcement (v67); refund/chargeback/expiry full matrix (v68); cutover state machine (v69); legacy gift-card
inventory (v70); all UI (owner control centre, till, wallet, plan editor, templates, terms).
