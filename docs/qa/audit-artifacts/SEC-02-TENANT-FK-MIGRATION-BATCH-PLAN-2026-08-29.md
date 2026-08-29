# SEC-02 tenant-FK migration batch plan

**Date:** 2026-08-29  
**Mode:** read-only audit; no production DDL, DML, grants, RLS or application edits  
**Production project:** `loyalty` (`gadpooereceldfpfxsod`, PostgreSQL 17.6)  
**Source inventory:** `tenant-simple-fk-inventory-2026-08-29.csv`

This is the migration design for all **141** inventory rows. Row numbers below are 1-based data-row numbers in the CSV (the header is not counted); the CSV remains the authoritative source for exact constraint names, policy names and trigger names. The partition is exhaustive and disjoint: **B1 17 + B2 14 + B3 48 + B4 42 + B5 12 + B6 8 = 141**.

## 1. Decision summary

The immediate gap is structural tenant integrity, not current corruption. The live catalog check returned:

| Live SELECT-only measure | Result |
|---|---:|
| Simple FKs whose parent has `business_id` | 153 |
| Those whose child also has `business_id` | 131 |
| Indirect children without `business_id` | 22 |
| Child/parent pairs missing a matching two-column same-business FK | 119 |
| Inventory rows in this plan | 141 |
| High conditional rows | 17 |
| Medium conditional rows | 14 |
| Low/server-only rows | 110 |
| Rows with any authenticated table DML privilege | 31 |
| Rows with any anonymous table DML privilege | 20 |
| Rows carrying effective policy names | 85 |
| Rows carrying trigger names | 88 |
| Rows whose trigger text mentions child and business | 43 |
| Unique policy names in inventory | 105 |
| Unique trigger names in inventory | 118 |

The high slice must close first because it has authenticated browser DML and a known-UUID cross-tenant association path. The low slice should not be treated as harmless: it is currently server/RPC-only or RLS-limited, but a future writer can reopen the gap.

## 2. Standard migration shape

For a direct tenant row, where the child already has `business_id`, the intended proof is:

```sql
-- parent prerequisite; exact parent column is the referenced column in the CSV
UNIQUE (parent_reference, business_id)

-- child proof; retain the existing simple FK until cutover is verified
FOREIGN KEY (child_reference, business_id)
  REFERENCES parent(parent_reference, business_id)
  -- use the existing ON DELETE action; do not silently change lifecycle behavior
```

For a derived row, first decide whether to materialize an immutable child `business_id`. If one referenced parent is authoritative, backfill it from that parent. If several parents are tenant-bearing, backfill only where every non-null parent resolves to the same business; quarantine/log orphan and disagreement rows rather than choosing one parent silently. If the child is an event/audit row whose tenant is intentionally inherited, a pinned trigger/RPC can be preferable to adding a redundant column, but it must enforce the same invariant on INSERT and UPDATE.

Use this order for each ordinary batch:

1. Read-only preflight: count missing parents, `business_id` mismatches, nullability, duplicate candidate keys, and active writers.
2. Create missing parent unique indexes concurrently where the parent key is not already present; attach/record the key in a short lock window. A two-column key is still required even when `id` is globally unique because PostgreSQL requires the referenced column list itself to be unique.
3. Backfill/repair child `business_id` in bounded, idempotent chunks. Do not overwrite a non-null conflicting value; quarantine it.
4. Add the new FK `NOT VALID` while retaining the old simple FK. Use a lock timeout and abort on unexpected blocking.
5. Run two-tenant negative tests through REST/RPC and the relevant owner/staff/module paths.
6. `VALIDATE CONSTRAINT` in a separate controlled window; then remove the redundant simple FK only after writer and rollback evidence is accepted.

`NOT VALID` avoids a table-wide validation scan in the add transaction, but it does not make the add lock-free. `VALIDATE CONSTRAINT` still scans existing rows and takes locks; measure the live PostgreSQL 17 lock profile, use a short `lock_timeout`, and schedule validation by table size. Never hide a validation failure by disabling triggers or weakening RLS.

## 3. NULL and lifecycle semantics

- Preserve the existing nullable status of every child reference. A nullable simple FK currently implements PostgreSQL `MATCH SIMPLE`: a null reference skips the FK check. The composite replacement should preserve that behavior unless product semantics explicitly require the reference.
- A nullable composite reference with non-null `business_id` is intentionally a mixed-null case under `MATCH SIMPLE`; this is acceptable for optional links. Do not change it to `MATCH FULL` without checking every writer, because `MATCH FULL` rejects a null reference paired with a non-null business.
- A required child reference must be `NOT NULL` before the composite FK is validated. A nullable parent `business_id` is different: it denotes a pre-tenant/global lifecycle and must not be forced to a tenant key.
- Live nullable tenant columns include `billing_provider_events.business_id`, `business_application_invitations_v95.business_id`, `platform_subscription_documents_v156.business_id`, `work_items_v511.business_id`, and other catalog rows outside this 141-row child set. The B6 rows are held out of unconditional composite enforcement for this reason.
- A missing parent is impossible under the existing simple FK, but a cross-tenant mismatch is possible. Preflight must distinguish `child_reference IS NULL`, `parent.business_id IS NULL`, and `child.business_id <> parent.business_id`; only the first two can be allowed by lifecycle policy.

## 4. Parent unique-key prerequisites from the live catalog

The following is the exact prerequisite state for every distinct parent tuple in the 141-row inventory. `READY` means the live catalog already has the required two-column unique key. `ADD` means create `UNIQUE (referenced_column,business_id)` before the child composite FK. `CONDITIONAL` means the parent or relationship is polymorphic/pre-tenant; do not add an unconditional same-business FK.

**READY (15 parent tables):**

`public.appointments(id,business_id)`, `public.branches(id,business_id)`, `public.business_customer_content_v95(id,business_id)`, `public.business_programmes(id,business_id)`, `public.clients(id,business_id)`, `public.customer_links(id,business_id)`, `public.firm_config_versions(id,business_id)`, `public.loyalty_operations(id,business_id)`, `public.loyalty_redemptions(id,business_id)`, `public.loyalty_reward_versions(id,business_id)`, `public.loyalty_rewards(id,business_id)`, `public.products(id,business_id)`, `public.sales(id,business_id)`, `public.services(id,business_id)`, and `public.staff(id,business_id)`.

**ADD (36 parent tuples):**

| Parent tuple(s) | Required key |
|---|---|
| `app.booking_management_tokens.id`; `app.sale_loyalty_reversal_operations_v480.id` | `(id,business_id)` |
| `public.bar_bottles.id`; `public.billing_adjustments.id`; `public.billing_commands.id`; `public.billing_provider_invoices.id`; `public.billing_provider_subscriptions.provider_subscription_id` | `(referenced_column,business_id)` |
| `public.birthday_program_versions.id`; `public.booking_tables.id`; `public.bringback_campaigns_v361.id`; `public.bringback_grants_v361.id`; `public.bundles.id` | `(id,business_id)` |
| `public.business_onboarding_checklists.id`; `public.business_support_entry_tokens_v530.id`; `public.consultant_commission_accruals.id`; `public.consultant_commission_attributions.id` | `(id,business_id)` |
| `public.customer_birthday_entitlements.id`; `public.customer_birthday_redemptions.id`; `public.customer_identity_decisions_v111.id`; `public.customer_identity_proofs_v111.id`; `public.customer_intelligence_exports_v83.id`; `public.customer_notification_preferences.id` | `(id,business_id)` |
| `public.growth_deliveries_v108.id`; `public.growth_delivery_dispatches_v110.id`; `public.growth_recommendation_members_v108.id`; `public.legacy_referral_provenance.referral_id` | `(referenced_column,business_id)` |
| `public.loyalty_programs.id`; `public.loyalty_tiers.id`; `public.membership_plans.id`; `public.package_plans.id` | `(id,business_id)` |
| `public.platform_subscription_revenue_periods_v200.id`; `public.promotion_redemption_intents_v290.id`; `public.referrals.id`; `public.resources.id`; `public.sale_items.id`; `public.tier_benefits_v365.id` | `(id,business_id)` |

**CONDITIONAL / do not add unconditionally (4 parent tables, 5 referenced tuples, 8 rows):**

| Rows | Relationship | Reason and safe replacement |
|---|---|---|
| 81 | `platform_application_decision_receipts_v105.invitation_id → business_application_invitations_v95.id` | Invitations may exist before a business is bound. Derive/validate the business only after binding; use a trigger/RPC conditional on both sides being tenant-bound. |
| 82 | `platform_billing_event_preparations_v156.event_pk → billing_provider_events.id` | Provider events can be unresolved (`business_id IS NULL`). Keep event identity as the global key; enforce same-business only after resolution, with a resolver invariant. |
| 83, 85, 86, 87, 88 | Platform subscription document links | `platform_subscription_documents_v156` is polymorphic: it may belong to a business or a prospect. A blanket `(reference,business_id)` FK would reject valid pre-conversion workflows or silently skip malformed mixed-null rows. Use lifecycle checks/triggers; for row 88 the optional parent prerequisite would be `(billing_provider_invoices.provider_invoice_id,business_id)`, but enforce the pairing conditionally when both are present. |
| 141 | `work_item_events_v511.work_item_id → work_items_v511.id` | `work_items_v511.business_id` is nullable. Preserve platform/global work items; enforce inherited business only for business-bound work items. |

No row in the 141-row inventory is proven to be an intentionally cross-tenant business relationship. Therefore no current row receives an explicit cross-tenant exemption. The B6 lifecycle relationships are **not** cross-tenant; they are polymorphic or pre-tenant and must not receive a blanket composite. Do not infer that platform consultant, SME prospect, global catalog, identity, or other relationships outside this inventory should be tenant-composite: if a future row points to a parent with no tenant key, mark it `X-CROSS-TENANT` and leave it simple by design.

## 5. Prioritized batches

### B1 — P0 browser-write closure (17 rows)

**Rows:** `5,6,18,19,20,21,22,34,112,115,116,117,121,122,134,135,136`.

Targets: `appointment_services` (appointment/service), `booking_requests` (appointment/branch/service/staff/table), `change_requests.appointment_id`, `reward_grants.client_id`, `sales` (appointment/client/product), `service_products` (product/service), and `waitlist` (client/service/table). Exact FK names and policies are in the source CSV.

Plan: use READY parent keys for appointments, branches, clients, products, services and staff; add `(id,business_id)` for `booking_tables`. Add immutable `business_id` to derived children `appointment_services` and `service_products`, backfilling only on unanimous parent-business agreement. Existing browser policies include the v572 module-gated INSERT/UPDATE/DELETE paths; preserve them, revoke unused `anon` verbs if product contract permits, and regression-test known foreign UUIDs for each reference. `sales` also has an authenticated INSERT path, so test client, appointment and product independently. `reward_grants` is authenticated INSERT/UPDATE-capable in the inventory; its existing snapshot guard is not a same-business FK and status mutation must remain a separate narrow workflow.

Writer impact: `appointment_services_*`, `booking_requests_*`, `change_requests_*`, `service_products_*`, `waitlist_*` policies; appointment/sales/grant triggers and RPCs listed in the CSV and the existing reward-grant policy scan. Every writer must set/retain `business_id` and cannot update the tenant key after insertion.

### B2 — P1 owner/staff/module browser-write closure (14 rows)

**Rows:** `23,24,25,26,27,36,37,90,91,92,123,124,125,126`.

Targets: `branch_breaks`, `branch_hours`, `bringback_grants_v361`, `client_packages`, `points_batches`, and staff schedule/invite tables. Parent keys are READY except `bringback_campaigns_v361(id,business_id)` and `package_plans(id,business_id)`, which must be added first.

Backfill from each child’s non-null `business_id`; preserve optional redeemed-sale semantics. Validate campaign/client/sale, package plan, points programme/client/sale, and staff ownership independently. Keep owner/module RLS and test owner, non-owner staff, inactive staff, anon, and foreign-tenant UUIDs. The `authenticated` privileges are mixed (`ttt` for the row’s listed write surface; anon is either denied or, for package/waitlist-adjacent paths, currently present as shown in CSV), so do not infer safety from RLS alone.

Writer impact: branch/staff schedule policies, v361 bring-back policies/triggers, package and points writers, and any RPCs named by the CSV’s `effective_policy_names`/`trigger_names` columns.

### B3 — P2 direct server-only rows with parent key already READY (48 rows)

**Rows:** `2,7,9,10,12,15,31,35,39,50,54,57,58,60,61,62,63,71,72,73,74,75,76,79,93,94,95,96,97,99,100,101,102,103,105,106,108,109,110,119,120,130,131,132,137,138,139,140`.

These are direct `business_id` children whose referenced parent already has the required unique tuple. Add the child composite FK in small table groups, retaining current simple FKs until validation. No child tenant backfill is needed; preflight must still prove `business_id` is non-null for all rows that the product contract treats as tenant-bound and must check existing mismatches before `NOT VALID`.

Representative groups are appointments/client/service/staff, promotions/content/branches, loyalty operations/rewards/programme versions, referrals, tier benefits, welcome-offer grants, and WhatsApp appointment sends. Trigger-mentioned rows require manual writer review because a trigger mention is not equivalent to a full composite invariant. Since all are server-only in the inventory, first acceptance is an ACL/RPC regression proving no browser DML was unintentionally reintroduced.

### B4 — P3 direct server-only rows requiring parent unique prerequisites (42 rows)

**Rows:** `3,4,8,11,13,14,16,32,33,38,40,41,45,46,47,48,49,51,52,53,56,59,64,65,66,67,68,69,70,77,78,80,84,104,107,111,113,114,118,128,129,133`.

These are direct `business_id` children, but the live parent key is absent. Add the exact parent keys in section 4 first, then follow the standard direct-child sequence. Important subgroups include self-referential append-only/reversal links (`billing_adjustments`, birthday redemptions, package supersession), billing/provider identifiers, growth delivery chains, identity decision/proof links, referral provenance, onboarding checklists, and tier-benefit links.

Conflict handling is table-specific: for a self-reference, compare the child row’s business to the referenced row; for provider identifiers, pair the provider key with the invoice/subscription business; for optional links, preserve NULL/MATCH SIMPLE behavior. Review append-only and immutable triggers before replacing any simple FK, and do not change ON DELETE actions.

### B5 — P3 indirect-tenant children requiring derived backfill (12 rows)

**Rows:** `1,17,28,29,30,42,43,44,55,89,98,127`.

Targets: booking management submissions, provider subscription items, bundle items, consultant commission adjustments/payout lines, customer intelligence export rows, subscription revenue months, promotion alert runs, and stock batches. For each row, derive `business_id` from the referenced parent; for a child with more than one tenant-bearing reference, require all populated parents to agree. Rows `28–30` and `42–44` are multi-parent/chain candidates and must be backfilled with an agreement query, not a single-parent `UPDATE`.

Parent prerequisites: add keys for booking tokens, provider subscriptions, bundles, commission accruals/adjustments, customer intelligence exports and revenue periods; products, services and business content are already READY. Keep immutable/event rows writeable only through their existing server paths. Add the composite FK only after the column is materialized and non-null policy is decided.

### B6 — P3 conditional lifecycle review; no blanket composite (8 rows)

**Rows:** `81,82,83,85,86,87,88,141`.

Do not force these into ordinary tenant-composite DDL. They cross a pre-tenant/polymorphic lifecycle boundary. Preserve the simple identity FK, then add a narrowly scoped trigger/RPC or `CHECK`/conditional validation that says: when both child and parent are business-bound, their businesses must match; when the relationship is global/prospect/unresolved, the lifecycle’s allowed null state remains valid. Add explicit tests for pending→bound transition, wrong-business binding, retry/idempotency, and delete/reissue behavior.

## 6. Writer and RPC acceptance matrix

The inventory’s `effective_policy_names`, `trigger_names`, and DML privilege columns are the writer manifest. Before each batch is validated:

| Writer class | Required check |
|---|---|
| Browser table DML | Existing `USING` and `WITH CHECK` still authorize only the caller’s business/module; wrong-tenant UUID insert/update fails. |
| Security-definer/RPC writer | Identity and business are checked before the first write; function uses pinned `search_path`; it supplies or derives the child business consistently. |
| Trigger writer | Trigger cannot be bypassed by direct table DML, does not overwrite a conflicting non-null business, and preserves append-only/state-machine rules. |
| Webhook/cron/Edge writer | Idempotent retry path sets the same business proof; unresolved events remain in B6 rather than being assigned by guesswork. |
| Delete/cascade path | Existing ON DELETE behavior is preserved and cross-business parent deletes cannot strand or relink a child. |

For every B1/B2 row, run a disposable two-business matrix with known UUIDs at REST and RPC boundaries: same-business success; foreign parent denial; foreign child update denial; null optional link behavior; owner/staff/module role denial; anon denial; retry/idempotency. For B3–B5, run the same matrix through every current RPC/trigger writer before enabling browser privileges in future work.

## 7. Required preflight queries for the eventual migrations

These are templates only; they were not executed as writes in this audit. Substitute the exact table/column names from the CSV and run them as read-only checks before each batch:

```sql
-- direct mismatch (a simple FK proves existence, not same-business ownership)
SELECT count(*) AS mismatch_count
FROM child c
JOIN parent p ON p.parent_column = c.child_column
WHERE c.child_column IS NOT NULL
  AND c.business_id IS NOT NULL
  AND p.business_id IS NOT NULL
  AND c.business_id <> p.business_id;

-- indirect derivation agreement for a child with two tenant-bearing parents
SELECT count(*) AS disagreement_count
FROM child c
JOIN parent_a a ON a.id = c.parent_a_id
JOIN parent_b b ON b.id = c.parent_b_id
WHERE a.business_id IS DISTINCT FROM b.business_id;

-- nullable references and unresolved parents must be counted separately
SELECT count(*) FILTER (WHERE child_reference IS NULL) AS null_reference,
       count(*) FILTER (WHERE parent.business_id IS NULL) AS unresolved_parent
FROM child
LEFT JOIN parent ON parent.id = child.child_reference;
```

The validation gate is zero mismatch/disagreement rows, an explicit decision for every null/unresolved row, and a writer test for every policy/trigger/RPC named in the source inventory. A non-zero mismatch is a data-integrity incident requiring repair/quarantine, not a reason to add `NOT VALID` and defer it indefinitely.

## 8. Evidence and reproducibility

Local evidence:

- `docs/qa/audit-artifacts/tenant-simple-fk-inventory-2026-08-29.csv` — 141 exact rows, including effective privileges, RLS, policy/trigger names and exploitability rank.
- `docs/qa/SECURITY-CRON-FOLLOWUP-2026-08-29.md` — live SEC-02 totals and critical slice.
- `db/migrations/20260726_nestly_v77_stripe_billing.sql` and `db/migrations/20260804_nestly_v156_subscription_operations_crm.sql` — source lifecycle definitions for provider and polymorphic document paths.

Live SELECT-only catalog checks performed against project `gadpooereceldfpfxsod` on 2026-08-29:

1. `pg_constraint`/`pg_attribute` query of simple one-column FKs and parent primary/unique keys; confirmed exact READY/ADD/CONDITIONAL prerequisites above.
2. `pg_attribute` query for nullable simple-FK child columns; confirmed optional references and nullable lifecycle business columns must retain explicit NULL semantics.
3. Aggregate catalog query: `153` parent-business simple FKs, `131` with child `business_id`, `22` indirect, `119` without matching same-business composite.

No production change was made. This artifact is a design handoff for a later reviewed migration; it is not a migration itself.
