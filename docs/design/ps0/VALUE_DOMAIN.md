# PS-0 Customer-Value Domain (scope C) — FREEZE

Status: **PS-0 contract, freeze-ready.** Reports to Fable 5. Authority:
`docs/design/PROGRAM_STUDIO_ARCHITECTURE.md` rev 4 §4 (+§5 for stored value). Every schema
claim grounded in `supabase/migrations/*.sql` (latest wins). Forced decisions →
**§4 Decisions made during freeze**.

**Invariant being frozen (§4-arch):** at any instant, each unit of economic value is
authoritatively represented in **exactly one** typed ledger. Conversions are one-way, atomic,
recorded movements. Projections never store value — they read the authorities side by side.

---

## 1. Authoritative value-type matrix (§4's 8 rows, expanded)

Money is **integer cents** everywhere (`*_cents` columns). "Units" distinguishes cents from
points/stamps/sessions. Each row names the **sole authority**; no value may appear in two
authorities at once.

### Row 1 — Points / stamps
| Field | Value |
|---|---|
| **Sole authority** | `public.points_ledger` (balance = `Σ points`), with FEFO expiry detail in `public.points_batches` (`remaining` is a cache; the ledger is the balance authority) |
| **Units** | points (points models) or stamps (stamps models) — the model's earn unit (ARCHITECTURE §12 S6) |
| **Enters by** | `entry_type='earn'` — auto-earn trigger `app.on_sale_recorded` on a qualifying sale (`…v10_sale_policy.sql:76`); rate `loyalty_programs.earn_points_per_dollar` |
| **Exits by** | `entry_type ∈ ('redeem','expire','adjust')` — redemption (`redeem_points`/`redeem_reward`), daily expiry sweep, manual adjust |
| **Conversion** | **redeem → promotional credit or entitlement**: points row (`redeem`, −) **and** a `credit_ledger` credit-in row (+) in **one transaction** — value never in both. **Finding (O4):** the redeem RPCs write that credit under `entry_type='manual_adjust'` (v23/v23b) or `'loyalty_earn'` (v23e/v24), **not** the semantically-correct `'loyalty_redeem'` — which exists in the CHECK but is unused by any redeem RPC |
| **Atomicity** | Single SQL transaction inside `redeem_points`/`redeem_reward`; provenance row `loyalty_redemption_provenance` links the exact `points_ledger_id` + `credit_ledger_id` + `operation_id` + `config_version_id`, each `UNIQUE` (`…v34_reversal_provenance.sql:66`) |
| **Evidence** | `points_ledger` `…v2_saas.sql:64-76` (entry_type CHECK `('earn','redeem','expire','adjust')`, unique `points_earn_once_per_sale (sale_id) where entry_type='earn'`); `points_batches` `…v3_engine.sql:9-20`; `client_points_balance` view `…v2_saas.sql:78`; redemption idempotency `loyalty_operations` `…v24a…:11` |

### Row 2 — Promotional store credit
| Field | Value |
|---|---|
| **Sole authority** | `public.credit_ledger` (balance = `Σ amount_cents`), read via `public.client_credit_balance` view |
| **Units** | cents |
| **Enters by** | `entry_type ∈ ('loyalty_earn','loyalty_redeem','referral_reward','gift_card_load','membership_credit','manual_adjust')` — loyalty/referral/membership fulfilment, gift-card redemption. **Note (O4):** points-redemption credit is recorded today as `loyalty_earn`/`manual_adjust`, and `loyalty_redeem` appears unused by any RPC — so provenance-by-`entry_type` is currently lossy |
| **Exits by** | `entry_type='spend'` (negative) — credit tender against a sale (`credit_tenders`, `…v20_financial_engine.sql:539`) |
| **Conversion** | credit is a **terminal** value form: value converts INTO it (from points, gift card, membership, referral) and leaves only by `spend`. It never converts back into points/sessions/gift-card |
| **Atomicity** | each ledger insert is one row; tender `spend` is written with its `credit_tenders` op row + `idempotency_key` in one transaction; append-only guard blocks UPDATE/DELETE (`…v20`/`…v34` guards) |
| **Evidence** | `credit_ledger` `…frenly_init.sql:94-104` (entry_type CHECK), col rename `salon_id→business_id` `…v2_saas.sql:12`; `+sale_id,payment_id,actor,idempotency_key` `…v20…:478`; `+config_version_id` `…v26…:158`; balance view `…v2_saas.sql:34` |

### Row 3 — Customer-paid stored value (PS-2, not yet built)
| Field | Value |
|---|---|
| **Sole authority** | `sv_lots(class='paid')` with append-only authority `sv_lot_movements`; `sv_lots.remaining_cents` a **locked cache** (`remaining = Σ movements`, asserted, §5-arch) |
| **Units** | cents |
| **Enters by** | `movement_type='issue'` at top-up (mints paid lot) |
| **Exits by** | `spend` (proportional allocation, FEFO within class), `refund` (paid-remaining only), `correction` |
| **Conversion** | own tender method; **never mixes with promotional credit**; refund = paid-remaining cash only + bonus clawback (§5 refund matrix) |
| **Atomicity** | movement writer maintains the cache in the same transaction; per-customer advisory lock serializes spend/refund (§5 items 5–7) |
| **Evidence** | **Does not exist today** — grep of `create table` shows no `sv_*` table. Introduced PS-2 (ARCHITECTURE §5, §13, §17). Purchase books `sales.kind='topup'` with policy `revenue=false,visit=false,points=false` (S1; neither the kind nor the policy row exists yet — `sales_kind_check` today = `service\|retail\|membership\|quick_sale\|gift_card\|package`, `…v10:7`). |

### Row 4 — Top-up bonus value (PS-2, not yet built)
| Field | Value |
|---|---|
| **Sole authority** | `sv_lots(class='bonus')` via `sv_lot_movements` — a **separate** authority from paid (Row 3), always reported as a distinct field |
| **Units** | cents |
| **Enters by** | `movement_type='issue'` at top-up (mints bonus lot; independent expiry terms) |
| **Exits by** | `spend` (proportional), `expiry`, `clawback` (on refund), `correction` — **never cash-out** |
| **Conversion** | consumed proportionally with paid on each spend; clawed back on refund of its operation; terminal clawback closes an operation with **no stranded bonus cent** (§5 item 2) |
| **Atomicity** | same movement writer + advisory lock as Row 3 |
| **Evidence** | as Row 3 — PS-2 future; the paid/bonus split is the anti-arbitrage core of §5. |

### Row 5 — Gift-card value
| Field | Value |
|---|---|
| **Sole authority** | `public.gift_cards.balance_cents` (with `initial_cents`, `status ∈ ('active','redeemed','void')`), issuance op-ledger `public.gift_card_issue_operations` |
| **Units** | cents |
| **Enters by** | `issue_gift_card` — mints a card `balance_cents = initial_cents`, writes a `sales.kind='gift_card'` liability row (cash collected, **not revenue** — v9 rule) + an immutable `gift_card_issue_operations` provenance row |
| **Exits by** | `redeem_gift_card` — **one-way conversion into `credit_ledger('gift_card_load')`**, decrementing the card atomically |
| **Conversion** | value is on the card **XOR** in credit, never both. Redemption does **not** insert a sale — the later real sale that spends the loaded credit is the revenue (double-count avoided, v9) |
| **Atomicity** | `redeem_gift_card` in one transaction: `update gift_cards set balance_cents = balance_cents - v_load, status=…` then `insert credit_ledger('gift_card_load', v_load)` under `app.credit_ledger_write_scope='redeem_gift_card'` (`…v20_financial_engine.sql`, `redeem_gift_card` body) |
| **Evidence** | `gift_cards` `…frenly_init.sql:125-136`; rename `…v2_saas.sql:14`; op-ledger `…v41…:234`; sale kind `gift_card` + v9 accounting `…v9_giftcard_revenue.sql:8` |

### Row 6 — Package sessions
| Field | Value |
|---|---|
| **Sole authority** | `public.client_packages.remaining` (integer sessions, `status ∈ ('active','used_up')`), consumption detail `public.package_session_consumptions`, reversals `public.package_session_reversals` |
| **Units** | **sessions** (not cash) |
| **Enters by** | `sell_package` — mints `client_packages.remaining = package_plans.sessions`; books cash as a `sales.kind='package'` row (revenue-upfront per policy; **visit=false** to kill the 11-visits bug, `app.sale_policy_defaults()` `…v10:53`) |
| **Exits by** | `use_package_session` — decrements `remaining` by 1, writes a `$0 sales.kind='service'` visit + an immutable `package_session_consumptions` row (`remaining_after = remaining_before - 1`) |
| **Conversion** | session-denominated, not cash; the cash story is the purchase sale + policy. A session never becomes credit/points; a reversal restores exactly 1 session (`restored_sessions=1`) |
| **Atomicity** | `use_package_session` in one transaction, `for update` on the package row, advisory lock keyed on `(business,idempotency_key)`; `remaining_after` CHECK ties the counter to the ledger row (`…v34_reversal_provenance.sql:18`) |
| **Evidence** | `client_packages` `…v6_ops_modules.sql:101-109`; `package_plans` `…v6…:` (`sessions>0`, `price_cents`); consumptions/reversals `…v34…:18`; keyed sell overload `sale_intent_operations` `…v51a…:33` |

### Row 7 — Membership entitlements
| Field | Value |
|---|---|
| **Sole authority** | `public.memberships` status (+ plan `public.membership_plans`; terms snapshot mandated by §13, backfilled) |
| **Units** | membership period / entitlement (status: active/paused/cancelled/expired) |
| **Enters by** | `enroll_membership` (`…v20`) → `memberships` row + `sales.kind='membership'` (revenue; **no points, no retention, no referral** — v9/v10 policy `membership: revenue=true,visit=false,points=false`, `…v10:51`); renewals via `app.run_membership_renewals()` cron (`…v5:148`, `…v20:1311`) |
| **Exits by** | expiry / cancel |
| **Conversion** | **membership credit drops post to `credit_ledger('membership_credit')`** — a recorded one-way conversion into Row 2; membership status itself is not cash |
| **Atomicity** | enrol/renew writes the membership row and any `membership_credit` ledger row in the same transaction |
| **Evidence** | `memberships`/`membership_plans` `…v5_memberships_giftcards.sql:18,5`; credit entry `membership_credit` in `credit_ledger` CHECK `…frenly_init.sql:100`; membership sale policy defaults `…v10:51` |

### Row 8 — Non-cash entitlements (free item, % off, birthday, recurring perks)
| Field | Value |
|---|---|
| **Sole authority** | grant/entitlement rows: `public.reward_grants` (retention), `public.customer_birthday_entitlements` (birthday), `program_entitlements` (recurring/tier — **PS-1B future**); campaign grants `public.retention_campaign_grants` |
| **Units** | face-value **promises** (`reward_type ∈ ('discount_pct','free_item','credit')`, `reward_value`; birthday `benefit_snapshot` jsonb) |
| **Enters by** | rule/engine grant — retention grant fired by `app.on_sale_recorded`; birthday activation (`customer_birthday_activation_operations`); campaign issue (`retention_campaign_grants`) |
| **Exits by** | redemption (a fulfilment record), expiry, or reversal (a signed row, never a delete) |
| **Conversion** | face-value promises; **cash cost recognized only at fulfilment** (ARCHITECTURE §10 / `BENEFIT_REGISTRY_CONTRACT.md`). A `credit`-type grant converts into `credit_ledger` at redemption; a `free_item`/`% off` is consumed at checkout |
| **Atomicity** | grant is one row (`reward_grants UNIQUE(program_id,client_id,period_index)`); birthday redemption is append-only with a single live redemption per entitlement (`customer_birthday_one_live_redemption_idx`, `…c45:196`) |
| **Evidence** | `reward_grants` `…v2_saas.sql:103-115` (status `granted\|redeemed\|expired`); `customer_birthday_entitlements`/`…_redemptions` `…c45…:116,165`; `retention_campaign_grants` (`offer_cost_cents`, `reward_grant_id`) `…v50_retention_measurement.sql:151` |

---

## 2. Unified projection `v_customer_value` (design)

`v_customer_value(business_id, client_id)` returns every authority above **side by side**,
paid SV and bonus SV always as separate fields (§4-arch). It **stores nothing** — it is a
read model over the real authorities:

| Projection field | Definition (authority sum) |
|---|---|
| `points_balance` | `Σ points_ledger.points` for `(business_id, client_id)` |
| `promo_credit_cents` | `Σ credit_ledger.amount_cents` |
| `paid_sv_cents` | `Σ sv_lot_movements.cents where lot.class='paid'` (PS-2; `0` until then) |
| `bonus_sv_cents` | `Σ sv_lot_movements.cents where lot.class='bonus'` (PS-2; `0` until then) |
| `giftcard_balance_cents` | `Σ gift_cards.balance_cents where status='active'` (cards the client can spend) |
| `package_sessions_remaining` | `Σ client_packages.remaining` |
| `membership_status` | active membership state(s) |
| `entitlement_promises` | live grants: `reward_grants(status='granted')` + `customer_birthday_entitlements(status='available')` + future `program_entitlements` |

**Acceptance invariant (the reconciliation contract):** for a full-day fixture exercising
every conversion, `Σ(entries per authority)` equals the projection **and no value appears in
two authorities**. PS-0 defines the reconciliation query (`db/tests/ps0_value_reconciliation.sql`);
every later phase's suite must keep it green. Since `v_customer_value` is itself a PS-1+
artifact, the PS-0 query asserts the **invariant definition directly against the live
authorities** (the sums the view will later expose).

---

## 3. Reconciliation query design (`db/tests/ps0_value_reconciliation.sql`)

A **read-only, rolled-back** suite (`begin … rollback`, pristine fixture) in the house style
of `db/tests/v53_visit_feedback.sql` / `db/tests/v50_retention_measurement.sql`
(`pg_temp.as_user/as_anon/assert_true/assert_eq/expect_state` helpers; drives real owner RPCs
on the pristine A/B fixture). It **exercises one conversion of each kind that exists today**
and asserts the single-representation invariant after each:

| Conversion exercised | Path (real, grounded) | Single-representation assertion |
|---|---|---|
| **Points → promotional credit** | seed points via a qualifying sale (auto-earn trigger), then `redeem_points(business, client, idem)` | points balance **drops** and credit balance **rises** in one call; the removed points appear as a `points_ledger('redeem')` row and the credit as a `credit_ledger` credit-in row — **value left points and entered credit, never both**. Asserted on **balances**, not on `entry_type`, because the credit route uses `manual_adjust`/`loyalty_earn` (O4) |
| **Gift card → promotional credit** | `issue_gift_card(business, amount, client, null, idem)` then `redeem_gift_card(business, code, client, null)` | after issue: card `balance_cents = amount`, **zero** `gift_card_load` credit; after full redeem: card `balance_cents = 0`, `status='redeemed'`, credit gains exactly one `gift_card_load` of `amount`; **`card_balance_after + gift_card_load_delta = initial`** (value on card XOR in credit) |
| **Package purchase → session consumption** | `sell_package(business, client, plan, idem)` then `use_package_session(business, cp, idem)` | after sale: `remaining = plan.sessions`; after one use: `remaining = sessions − 1` **and** exactly one `package_session_consumptions` row; **`remaining + consumption_count = sessions`**; **no** session value leaked into `credit_ledger`/`points_ledger` |
| **Cross-cutting disjointness** | after all three conversions | for the test client, each value type's authority is disjoint: the credit gained is exactly `loyalty_redeem + gift_card_load` (the two conversions that produce credit); points and sessions carry no cash duplicate; the four live authorities never double-count one unit |

**Membership → credit (Row 7)** and **stored-value (Rows 3–4)** conversions are **not
exercised** by this suite: membership credit posting is plan-conditional (optional in the live
enrol path) and SV lots/movements do not exist until PS-2. Both are flagged (§4 D3/D4) so the
suite grows with those phases per §4-arch ("every later phase's matrix must keep it green").

**Why real RPCs, not seeded ledger rows:** the task and house style call for exercising the
**conversion code paths**. The three chosen conversions are grounded to exact live signatures
(`redeem_points(uuid,uuid,text)` `…v41…`; `redeem_gift_card(uuid,text,uuid,int)` `…v20`;
`issue_gift_card(uuid,int,uuid,text,uuid)` `…v41:234`; `sell_package(uuid,uuid,uuid,uuid)`
`…v51a:33`; `use_package_session(uuid,uuid,text)` `…v34`) and their prerequisites are all
satisfiable on the pristine fixture (owner bypasses module gates via `app.can_module_write`
owner short-circuit, `…v41…`). Assertions are on the **authoritative ledgers**, so they hold
regardless of internal RPC structure.

---

## 4. Decisions made during freeze (flag to orchestrator)

- **D1 — the PS-0 reconciliation query asserts the invariant against live authorities, not
  against `v_customer_value`,** because the view is a PS-1+ artifact. When the view lands, add
  a row-equality assertion (`view field == authority Σ`) to the same suite.
- **D2 — assertions capture before/after balance deltas and their direction**, not hardcoded
  cent amounts, so the suite is robust to the fixture's configured earn/redeem rates
  (fixture: `earn_points_per_dollar=1`, `redeem_points=50`, `reward_credit_cents=500`,
  `pristine_chain_fixture.psql:70-78`). Exact-amount checks are added where the fixture pins
  them (gift-card `initial` is chosen by the test).
- **D3 — membership→credit conversion is documented (Row 7) but not exercised**, because the
  live enrol path grants `membership_credit` only when the plan is configured to; exercising it
  would require seeding a credit-granting plan and asserting a conditional. Deferred to the
  membership-touching phase.
- **D4 — SV (Rows 3–4) are specified from §4/§5 but marked not-built**; the reconciliation
  suite adds paid/bonus conservation rows in PS-2 (the §5 refund matrix becomes numbered tests
  there per §17).
- **D5 — `giftcard_balance_cents` in the projection filters `status='active'`**, so a
  `redeemed`/`void` card contributes zero spendable value — matching how a customer can spend
  it. (§4 lists "gift-card value on the card"; I pinned the spendable filter.)

## 5. Open questions

- **O1** — Does `enroll_membership` on a credit-granting plan post `membership_credit`
  synchronously in the same transaction, or via renewal cron only? (Affects whether Row 7's
  conversion is fully synchronous.) Needs a read of the credit-granting branch before PS-3.
- **O2** — Confirm `v_customer_value` should expose per-card rows or a single summed
  `giftcard_balance_cents`; this contract sums (a customer may hold several cards).
- **O3** — Whether promotional `credit`-type entitlement grants (Row 8) should be counted as
  `entitlement_promises` (unfulfilled) or already inside `promo_credit_cents` — this contract
  keeps them in Row 8 until redemption converts them into `credit_ledger`, avoiding double
  count.
- **O4 (schema finding)** — **Points-redemption credit is recorded under `entry_type`
  `'manual_adjust'` (v23/v23b `…v23_loyalty_points_tiers.sql`) or `'loyalty_earn'` (v23e/v24
  `…v23e_redeem_reward_ledger_routes.sql`, `…v24_stamps_model.sql`), while the
  semantically-correct `'loyalty_redeem'` value — present in the `credit_ledger` CHECK since
  `…frenly_init.sql:98-100` — is written by no RPC.** Credit provenance-by-`entry_type` is
  therefore lossy: a points-redemption credit is indistinguishable from a manual adjustment.
  Not a blocker for the reconciliation invariant (asserted on balances), but the benefit
  registry (`BENEFIT_REGISTRY_CONTRACT.md`) should key `points_redeem` fulfilments off
  `loyalty_operations`/`loyalty_redemptions`, not off the credit `entry_type`. Flagged for a
  possible cleanup migration.

## 6. Schema evidence relied on
`points_ledger`/`points_batches` `…v2_saas.sql:64` / `…v3_engine.sql:9`; `credit_ledger`
`…frenly_init.sql:94` (+`…v20…:478`, +`…v26…:158`); `gift_cards` `…frenly_init.sql:125`,
op-ledger `…v41…:234`; `client_packages` `…v6_ops_modules.sql:101`, consumptions `…v34…:18`;
`memberships`/`membership_plans` `…v5…:18,5`; `reward_grants` `…v2_saas.sql:103`;
`customer_birthday_entitlements`/`…_redemptions` `…c45…:116,165`; `retention_campaign_grants`
`…v50…:151`; `loyalty_redemption_provenance` `…v34…:66`; sale policy defaults
`…v10_sale_policy.sql:44-55`; pristine fixture `db/tests/fixtures/pristine_chain_fixture.psql`.
