# PS-0 Benefit Registry Contract (scope D) — FREEZE

Status: **PS-0 contract, freeze-ready.** Reports to Fable 5. Authority:
`docs/design/PROGRAM_STUDIO_ARCHITECTURE.md` rev 4 §3, §7, §10 (+ decision logs §1a B1/B3,
§1b B5, §1c N6/N7). Every schema claim grounded in `supabase/migrations/*.sql` (latest wins).
Forced decisions → **§10 Decisions made during freeze**.

> **Build status.** `benefit_registry` and `benefit_fulfilments` **do not exist today** (grep
> of every `create table` confirms). They are introduced in PS-1A/PS-1B (ARCHITECTURE §17).
> This is the freeze those migrations implement. Every *detail table* named below is **live
> today** and is cited to its migration.

---

## 1. `benefit_fulfilments` — the authoritative single-count registry (B1/B3 fix)

An **append-only registry**, not a projection (§3). One row = one benefit actually fulfilled
(or promised) to one customer. It is the single source of realized cost (§10).

| Column | Type | Rule |
|---|---|---|
| `id` | uuid PK | `default gen_random_uuid()` |
| `business_id` | uuid not null | FK → `businesses(id)`; tenant scope |
| `canonical_benefit_key` | text not null | **`UNIQUE(business_id, canonical_benefit_key)`** — the hard double-grant guard (§7). Format = registered template per family (§4), validated at write (N5). |
| `source_engine` | text not null | `points_loyalty \| retention \| referral \| birthday \| tier \| recurring \| campaign \| checkout \| stored_value \| membership \| studio_rule` |
| `fulfilment_kind` | text not null | typed kind (§4 col 1); selects which `detail_ref` table is valid |
| `client_id` | uuid | FK → `clients(id, business_id)` composite; nullable only for business-level effects (none today) |
| `detail_ref` | uuid not null | typed back-reference to the live detail row (§4 col 5); composite-tenant FK to the family's table |
| `face_value_cents` | integer not null | what the customer sees (§4 col 6); integer cents |
| `estimated_cost_cents` | integer not null | business variable cost estimate captured **at fulfilment time** (§4 col 7) |
| `cost_basis` | text not null | how `estimated_cost_cents` was derived: `credit_face \| catalog_cost \| benefit_snapshot \| owner_offer_cost \| discount_face \| bonus_face \| margin_band` |
| `cost_confidence` | text not null | `high \| medium \| low` (propagates to economics §10 measure 2) |
| `config_version_id` | uuid not null | FK → `firm_config_versions(id, business_id)`; the config in force (§6) |
| `reverses_fulfilment_id` | uuid | FK → `benefit_fulfilments(id, business_id)`; set only on reversal rows (§8) |
| `occurred_at` | timestamptz not null | business time of the fulfilment |
| `recorded_at` | timestamptz not null | `default now()`; immutable |

Requirements: RLS + `sa_read`; `revoke all … from public, anon, authenticated`; writes only
through `security definer` writers; a `BEFORE UPDATE OR DELETE` guard (append-only, like
`app.v41_operation_immutable_guard`, `…v41…:260`); composite tenant FKs throughout.

**Who writes it (rev 4, B5):** **only the CURRENT execution-authority holder** for a family
inserts, in the same transaction as its detail row — the legacy engine while its
`cutover_status ∈ (legacy, shadow)` (its adoption insert is added when it enters `shadow`), the
studio executor only once authority = `studio`. A **shadowing evaluator writes ONLY the shadow
log** (§7), never the registry — so shadow mode can never collide with the live engine on the
unique key, and a UNIQUE violation can never abort a customer's live transaction.

**`rule_effect_log` link (§3, §10, N1):** every effect-log row that **moves or promises**
value carries a mandatory FK to exactly one `benefit_fulfilments` row; non-value effects
(`display_perk`, suppressions) carry none; uniqueness applies whenever the reference exists.

---

## 2. `benefit_registry` — per business × family execution authority (§7)

| Column | Type | Rule |
|---|---|---|
| `id` | uuid PK | |
| `business_id` | uuid not null | FK → `businesses(id)` |
| `source_engine` | text not null | one benefit family (see §3); `UNIQUE(business_id, source_engine)` |
| `execution_authority` | text not null | `legacy_trigger \| studio_executor` — "who executes and writes the registry RIGHT NOW" (§7, N7) |
| `cutover_status` | text not null | `legacy \| shadow \| studio \| rolled_back` — the migration lifecycle stage (§7, N7) |
| `canonical_benefit_key_template` | text not null | the family's key format (§4) |
| `shadow_started_at` / `cutover_at` / `rolled_back_at` | timestamptz | audited transition timestamps |

**The two fields are distinct (N7):** `execution_authority` answers who executes now;
`cutover_status` is the lifecycle stage. **During `shadow`, `execution_authority` is still
`legacy_trigger`** — shadowing does not move authority.

---

## 3. Benefit families — completeness judged against §10 + live engines

| # | Family (`source_engine`) | `fulfilment_kind`(s) | Current authority | Current cutover | Live engine (producer) |
|---|---|---|---|---|---|
| 1 | `points_loyalty` | `points_redeem` (+ earn = exposure, not a row — §10 D1) | `legacy_trigger` | `legacy` | earn `app.on_sale_recorded` (`…v10:76`); redeem `redeem_points`/`redeem_reward` + `loyalty_operations` (`…v24a:11`) |
| 2 | `retention` | `retention_grant` | `legacy_trigger` | `legacy` | `app.on_sale_recorded` → `reward_grants` (`…v2_saas.sql:103`) |
| 3 | `referral` | `referral_reward` | `legacy_trigger` | `legacy` | referral qualify → `credit_ledger('referral_reward')`; `referrals` (`…frenly_init.sql:112`); legacy provenance `legacy_referral_*` (`…v20`). **Migrates first** (§7). |
| 4 | `birthday` | `birthday` | `legacy_trigger` | `legacy` | `customer_birthday_entitlements` / `…_redemptions` (`…c45:116,165`) |
| 5 | `membership` | `membership_credit` | `legacy_trigger` | `legacy` | `enroll_membership`/`run_membership_renewals` → `credit_ledger('membership_credit')` (`…v5:18`; `…v20:1311`) |
| 6 | `campaign` | `campaign_offer` | `legacy_trigger` | `legacy` | `retention_campaign_grants` (`…v50:151`) |
| 7 | `tier` | `tier_entry` | `studio_executor` (future) | n/a (**PS-3**) | `client_tier_status` + entry rewards (§12; not built) |
| 8 | `recurring` | `recurring_perk` | `studio_executor` (future) | n/a (**PS-1B**) | lazy entitlements `program_entitlements` (§15; not built) |
| 9 | `checkout` | `checkout_discount` | `studio_executor` (future) | n/a (**PS-1C**) | signed discount line on the sale (§9; not built) |
| 10 | `stored_value` | `sv_bonus_spend` | `studio_executor` (future) | n/a (**PS-2**) | `sv_lot_movements` bonus-class draw (§5; not built) |

Families 1–6 are **live legacy** today; 7–10 are **studio-only future** families that enter the
registry already at `studio` authority when their phase ships (nothing to cut over — they never
had a legacy engine). This matches "all legacy except future studio-only families."

---

## 4. Canonical key format + fulfilment detail + cost sourcing per family

| Family | `canonical_benefit_key` template | Detail table (`detail_ref` →) | `face_value_cents` source | `estimated_cost_cents` source · `cost_basis` · confidence |
|---|---|---|---|---|
| `points_loyalty` (redeem) | `points_redeem:{loyalty_operation_id}` | `loyalty_redemptions(id)` (op `loyalty_operations`) | `loyalty_redemptions.credit_cents` (`…v23:40`) | = credit face; `credit_face`; **high** |
| `retention` | `retention:{program_id}:{client_id}:{period_index}` (maps §3 `{period}` → live `period_index`, D2) | `reward_grants(id)` (`unique(program_id,client_id,period_index)`, `…v2_saas.sql:114`) | from `reward_type`/`reward_value`: `credit`→cents, `discount_pct`→basket est, `free_item`→catalog price | `credit`= face (`credit_face`, high); `free_item`= catalog cost (`catalog_cost`, medium); `discount_pct`= `margin_band` (low) |
| `referral` | `referral:{referral_id}` (`referrals` one-per-referred unique, `…v3:92`) | `credit_ledger(id)` entry `referral_reward` | `referrals.reward_cents` (`…frenly_init.sql:119`) | = face; `credit_face`; **high** |
| `birthday` | `birthday:{client_id}:{birthday_year}` (`unique(business,client,birthday_year)`, `…c45:140`) | `customer_birthday_redemptions(id)` / entitlement `customer_birthday_entitlements(id)` | from **`customer_birthday_entitlements.benefit_snapshot`** jsonb (`…c45:127`), captured at activation | from `benefit_snapshot` × margin; `benefit_snapshot`; **medium** (the B3 example) |
| `membership` | `membership_credit:{membership_id}:{period_key}` | `credit_ledger(id)` entry `membership_credit` | posted `credit_cents` | = face; `credit_face`; **high** |
| `campaign` | `campaign_offer:{campaign_id}:{client_id}` (`unique(campaign_id,client_id)`, `…v50:151`) | `retention_campaign_grants(id)` | from `reward_grant_id`'s grant / offer | **`retention_campaign_grants.offer_cost_cents`** (`…v50:158`); `owner_offer_cost`; **high** |
| `tier` (PS-3) | `tier_entry:{client_id}:{tier}` (§3 canonical, §12 once-ever — business scope lives in the UNIQUE constraint, not the key) | `program_entitlements(id)` / `client_tier_status` (future) | tier-entry reward config (benefit snapshot) | snapshot × `margin_band`; medium |
| `recurring` (PS-1B) | `recurring:{rule_id}:{client_id}:{period_key}` (§15 lazy `unique(business,client,rule,period_key)`) | `program_entitlements(id)` or the applied checkout discount (future) | rule effect config (server-resolved) | `discount_face` (for % / $ perks); high |
| `checkout` (PS-1C) | `discount:{sale_id}:{rule_id}:{effect_index}` (N6) | signed discount line on `sale_items` / `rule_effect_log(id)` (future) | server-resolved discount cents | = discount cents; `discount_face`; **high** |
| `stored_value` (PS-2) | `sv_spend:{operation_id}:{movement_id}` (N6, **bonus class only**) | `sv_lot_movements(id)` (future) | `bonus_draw_cents` of the movement | = bonus draw (business funded the bonus); `bonus_face`; **high** |

**Not benefit fulfilments (no business cost):** gift-card load (`credit_ledger('gift_card_load')`)
and paid-class SV spend are the **customer's own prepaid money** — value conversions, not
granted benefits. They register value movements for the value-reconciliation invariant
(`VALUE_DOMAIN.md`) but carry **no** `benefit_fulfilments` cost row. (D3.)

**config_version stamping:** `benefit_fulfilments.config_version_id` is captured at fulfilment
time from the source fact's config version — the same discipline as `sales.config_version_id` /
`credit_ledger.config_version_id` (`…v26:155,158`) and the redemption provenance
`loyalty_redemption_provenance.config_version_id` (`…v34:66`).

---

## 5. Cutover state machine (§7, verbatim-consistent)

Per engine, `cutover_status` transitions (each audited; `execution_authority` moves only at the
`shadow → studio` and `studio → rolled_back` steps):

```
legacy → shadow : studio evaluates the same events, writes would-be effects to the SHADOW LOG
                  ONLY. It moves no value and never touches benefit_fulfilments (still the live
                  engine's to write). execution_authority stays legacy_trigger. A comparator job
                  diffs the shadow log vs the live engine's registry rows daily (§6).
shadow → studio : owner-approved cutover after N days of zero diff. Single flip of
                  execution_authority → studio_executor. The legacy path short-circuits via a
                  cheap registry check.
studio → rolled_back → legacy : single flip back. Idempotency keys + canonical keys make the
                  transition safe both directions. Every transition audited.
```

**Referral migrates first** (simplest; the only engine off the config spine today, §7).

**Double-grant prevented twice over (§7):** (1) the studio executor refuses any effect whose
registry row says authority = `legacy` (and the legacy path gains one cheap inverse registry
check once shadow exists); (2) the `benefit_fulfilments UNIQUE(business_id,
canonical_benefit_key)` — a real constraint both the legacy engine (from shadow on) and the
studio executor insert into transactionally — means even a bug cannot double-fulfil.

---

## 6. Shadow-comparison data contract

The **shadow log** (`benefit_shadow_evaluations`, PS-1B) is what a shadowing evaluator writes
instead of the registry. One row per would-be fulfilment, carrying everything the comparator
needs to diff against the live engine's `benefit_fulfilments` rows without touching them:

| Column | Purpose |
|---|---|
| `id`, `business_id` | identity, tenant |
| `event_id` | FK → `domain_events`; the event the shadow evaluator processed |
| `source_engine`, `rule_id` | which studio rule/engine produced the would-be effect |
| `would_be_canonical_key` | the `canonical_benefit_key` the studio WOULD have written |
| `client_id` | subject |
| `fulfilment_kind` | as §4 |
| `face_value_cents`, `estimated_cost_cents`, `cost_basis`, `cost_confidence` | the studio's computed economics |
| `config_version_id` | config the shadow used |
| `computed_at` | when |

**Comparator (`app.compare_shadow_vs_live`, daily):** for a shadow window, LEFT/RIGHT join
shadow rows and the live engine's `benefit_fulfilments` rows on
`(business_id, canonical_benefit_key)`. A **clean diff** requires, for every matched key,
equality of `fulfilment_kind`, `face_value_cents`, `estimated_cost_cents`, and no
shadow-only or live-only keys in the window. `diff = 0` for N days gates the owner-approved
`shadow → studio` cutover (§17 PS-1B exit: "shadow diff = 0 for referral fixture week").
Mismatches are surfaced with the offending keys for owner review; they never touch live value.

---

## 7. Idempotency & uniqueness

- **`UNIQUE(business_id, canonical_benefit_key)`** on `benefit_fulfilments` is the hard guard.
- The writer performs a **plain INSERT** (not `ON CONFLICT DO NOTHING`) so a genuine
  cross-engine double-fulfil **raises** (the §7 guarantee). Same-source replay never reaches a
  second insert because the family's own detail-table idempotency short-circuits upstream first:
  `reward_grants unique(program_id,client_id,period_index)`; `customer_birthday_entitlements
  unique(business,client,birthday_year)` + `customer_birthday_one_live_redemption_idx`
  (`…c45:140,196`); `loyalty_operations unique(business,operation_type,idempotency_key)`
  (`…v24a:11`); `retention_campaign_grants unique(campaign_id,client_id)` (`…v50:151`);
  `package_session_consumptions unique(business,idempotency_key)` (`…v34:18`). The registry key
  is **derived from these natural keys**, so the two agree by construction.
- Every canonical key is **validated against its registered template at write time** (N5).

---

## 8. Reversal behaviour per family (append-only; never deletes)

`benefit_fulfilments` is append-only (§1). A reversal is a **NEW signed row** with a
`*_reversal` `fulfilment_kind`, negative `face_value_cents`/`estimated_cost_cents`, and
`reverses_fulfilment_id` pointing at the original — the original row is **never mutated or
deleted**. This generalizes the live append-only reversal pattern that every engine already
uses:

| Family | Reversal writes… | Live pattern cited |
|---|---|---|
| `points_loyalty` | reversal fulfilment + `loyalty_redemption_reversals` row (points restored, credit clawed) | `…v34:66` (`loyalty_redemption_reversals`, `loyalty_redemption_batch_drains`) |
| `retention` | reversal fulfilment; grant `status` → `expired`/reversed (a signed row) | `reward_grants.status ∈ (granted,redeemed,expired)` (`…v2_saas.sql:112`) |
| `referral` | reversal fulfilment + compensating `credit_ledger` entry | append-only credit ledger |
| `birthday` | reversal fulfilment; `customer_birthday_redemptions(operation_kind='reversal', original_redemption_id, reason, active=false flip)` | `…c45:172-198` (shape check requires `original_redemption_id` + 3–500-char reason; one-live-redemption partial index) |
| `membership` | reversal fulfilment + compensating `credit_ledger` entry | append-only |
| `campaign` | reversal fulfilment + compensating `retention_campaign_grants` handling | `…v50:151` |
| `checkout` (PS-1C) | on `sale.reversed`, a signed reversal discount fulfilment | `sale_reversal_audits` (`…v20`) |
| `stored_value` (PS-2) | reversal fulfilment; `sv_lot_movements(movement_type='reversal'/'clawback')` | §5 refund matrix |

A reversal fulfilment reuses (does not collide with) the original key by carrying it plus the
`reverses_fulfilment_id` link; the economics nets original + reversal to zero realized cost
(§10 measure 4), so a reversed benefit correctly stops counting without deleting history.

---

## 9. What a fulfilment row means for economics (bridge to `ECONOMICS_DEFINITIONS.md`)

- **Realized cost (§10 measure 4)** is computed **only** from `benefit_fulfilments`
  (`Σ estimated_cost_cents` over a period, net of reversal rows). The effect log contributes
  attribution, never amounts — single-count by the unique key.
- **Promises** (grants not yet redeemed) are fulfilment rows too (N1) with an outstanding
  status; **granted exposure (§10 measure 3)** reads them.
- **Points earn is the exception (D1):** it does not write a per-earn fulfilment row (mass
  scale); its exposure is the cohort model (`ECONOMICS_DEFINITIONS.md §2`); the realized
  `points_redeem` fulfilment is the counted cost when points convert to credit.

---

## 10. Decisions made during freeze (flag to orchestrator)

- **D1 — points EARN writes no per-earn `benefit_fulfilments` row.** Mass earn volume makes a
  per-earn registry row impractical and §10 already models points via a cohort exposure. The
  counted realized cost is the `points_redeem` fulfilment. Confirm this asymmetry (earn =
  exposure, redeem = fulfilment) is intended; it is the only family split this way.
- **D2 — `retention` key uses the live `period_index`**, not §3's `{period_start}`, because
  `reward_grants` enforces `unique(program_id, client_id, period_index)`. The template maps
  1:1; I pinned it to the enforced natural key so the registry key and the detail unique agree.
- **D3 — gift-card load and paid-class SV spend write NO cost fulfilment** (customer's own
  prepaid money). They are value movements for the reconciliation invariant only. Only the
  **bonus** class of SV is a business-cost fulfilment.
- **D4 — reversals are signed NEW rows with `reverses_fulfilment_id`**, reusing the original
  canonical key rather than minting a `*_reversal:` key, so a benefit and its reversal net to
  zero under one key. If the orchestrator prefers distinct reversal keys, the template set is
  additive.
- **D5 — `membership_credit` and per-renewal keys use `{period_key}`** (SGT period), since a
  membership can post credit each renewal; a single `membership:{id}` key would collide across
  periods.
- **D6 — completeness set = families 1–10.** Judged against §10's enumerated cost sources +
  every live grant/redemption engine in the migrations. Gift-card load is deliberately excluded
  (D3); packages hold session value (no cost fulfilment until consumed against a benefit).

## 11. Open questions

- **O1** — Does the referral reward post a `credit_ledger('referral_reward')` row per
  qualification, or via `reward_grants`? The `referral` detail_ref target must be pinned before
  referral's shadow migration (it migrates first). Current design: `credit_ledger` entry +
  `referrals` row; confirm against the v20 legacy referral resolution path.
- **O2** — `estimated_cost_cents` for `discount_pct` retention grants and `checkout_discount`
  depends on the basket at redemption; this contract uses `margin_band` (low confidence) at
  grant and the actual discount cents at checkout. Confirm the two-stage cost capture.
- **O3** — Whether `program_entitlements` (the recurring/tier detail table, §3/§15) is one
  table or per-kind; not built. Affects `detail_ref` typing for families 7–8.

## 12. Schema evidence relied on
`reward_grants` `…v2_saas.sql:103` (status, `unique(program_id,client_id,period_index)`);
`referrals` `…frenly_init.sql:112` (`reward_cents`); `credit_ledger` entry types
`…frenly_init.sql:98-100`; `loyalty_redemptions` `…v23_loyalty_points_tiers.sql:33`
(`credit_cents`); `loyalty_operations` `…v24a:11`; `loyalty_redemption_reversals`/
`loyalty_redemption_provenance` `…v34:66`; `customer_birthday_entitlements` (`benefit_snapshot`
`…c45:127`, `unique(business,client,birthday_year)` `…c45:140`), `customer_birthday_redemptions`
(reversal shape `…c45:172-198`, one-live-redemption idx `…c45:196`); `retention_campaign_grants`
(`offer_cost_cents`, `reward_grant_id`, `unique(campaign,client)`) `…v50:151`; `memberships`
`…v5:18`; `firm_config_versions` `…v26:13`; append-only guard `…v41:260`.
