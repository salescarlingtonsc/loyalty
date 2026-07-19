# Refund / Void / Partial-Refund Architecture — design proposal

## v20 launch contract (2026-07-19)

The historical options below are not the launch implementation. v20 deliberately supports
only one full append-only reversal for original `service`, `retail`, and `quick_sale` rows.
Partial refunds, un-refunds, `gift_card`/`package`/`membership` reversals, automatic restock,
and provider-settled refunds are rejected rather than guessed.

At launch, cash is refundable and store credit is refundable only when each credit payment has
an exact `credit_tenders` row plus its linked negative `credit_ledger` spend. Card, PayNow,
bank-transfer, gift-card, and other tender refunds remain disabled until an immutable provider
settlement/consumption reference exists.

Points clawback is also disabled. A sale earn can already have been redeemed into credit, while
the current schema has no immutable redemption-to-earn provenance or tenant policy defining
which downstream value must be recovered. v20 records the observed earned points in reversal
audit evidence but does not append a points adjustment or mutate `points_batches`. Enabling
clawback requires both provenance and an explicit policy migration; it is not a configuration
toggle in v20.

v13 flat commission is tombstoned and is not in the apply chain. v20 requires and preserves the
v12 percentage-only commission snapshot contract.

**Historical body status:** DESIGN ONLY. The v20 launch contract above supersedes conflicting
recommendations in the original proposal; repository migration remains unapplied by this work.
**Target implementation:** v11b (per the reviewer's ruling that `reverse_sale()` must not ship in v10.1).
**Author context:** live schema read from Supabase project `kyzovonwnscrzmkvocid` on 2026-07-17 (read-only `execute_sql` / `pg_get_functiondef`). The repo is stale; every schema claim below is from the database, not from the migration files on disk.
**Date:** 2026-07-17

---

## 0. How to read this document

This is a **decision document**, not a spec. For each question: the options, the trade-offs, a recommendation, and an explicit marker where the decision is **not mine to make**.

Two markers are used throughout:

- 🔴 **OWNER DECISION** — a business-semantics call. The owner has been clear they want to be presented with options, not have these silently decided. There are **7** of these; they are collected in §11.
- ⚠️ **BLOCKER / PREREQUISITE** — something that must be resolved before the implementation can be correct, independent of taste.

Competitor claims carry an evidence class:

| Class | Meaning |
|---|---|
| **A** | Confirmed live — we performed the action and observed the result |
| **B** | Observed — we saw the UI element / route but did not exercise it |
| **C** | Inferred — reasoned from other evidence; not observed |
| **D** | Unknown — explicitly not established |

**The single most important competitor fact for this document:** their **Refund modal was never opened** (`docs/flowesce/PAGE_ACTION_COVERAGE.md` FL-TXN-01: *"Row action: 'Refund' (present, **not clicked**)"*, *"Refund flow/modal never opened in any pass — genuinely unknown what fields it asks for or whether partial refunds are supported"*). That is **evidence B for existence, evidence D for behaviour**. Nothing in this document infers their refund semantics. Where I would otherwise be tempted, I mark it D and design from first principles instead.

---

## 1. Ground truth — what actually exists today (live-verified)

### 1.1 There is no refund concept at all

```
sales_amount_cents_check   CHECK (amount_cents >= 0)      -- live
```

`public.sales` columns (live): `id, business_id, client_id, kind, amount_cents, occurred_at, note, created_at, appointment_id, product_id, qty`.

There is **no** `reversal_of`, **no** snapshot columns, **no** `branch_id`, **no** `staff_id`. v10.1, v11a and v11b are all unapplied. `sales` has 6 rows, all owned by the disposable `QA Test Cafe` tenant. `public.sale_policies` has 0 rows.

Consequences that shape the whole design:

- No sale↔refund link exists in any form.
- `sales.kind` is constrained to `('service','retail','membership','quick_sale','gift_card','package')` — live. Note `package` **is** already in the live CHECK.
- `sales` has **no line items**. One sale row = one amount. `product_id`/`qty` are single-product hints for the retail path, not a line-item model. **Line-item refund is therefore not expressible today** (see §3.3).

### 1.2 The idempotency guards refunds must not collide with (live)

```
one_sale_per_appointment    UNIQUE (appointment_id) WHERE appointment_id IS NOT NULL   -- on sales
points_earn_once_per_sale   UNIQUE (sale_id) WHERE entry_type='earn' AND sale_id IS NOT NULL
reward_grants_program_id_client_id_period_index_key   UNIQUE (program_id, client_id, period_index)
one_referral_per_referred   UNIQUE (referred_client_id) WHERE referred_client_id IS NOT NULL
```

⚠️ **`one_sale_per_appointment` is a live landmine for refunds.** If a reversal row for an appointment-derived sale copies `appointment_id`, it collides with the original and the insert fails (or is silently swallowed by an `on conflict do nothing`). See §7.1.

### 1.3 The ledgers and their sign discipline (live)

| Table | Sign constraint | Refund implication |
|---|---|---|
| `sales` | `amount_cents >= 0` | must be relaxed — see §7.2 |
| `points_ledger` | **none** on `points`; `entry_type IN ('earn','redeem','expire','adjust')` | negative rows are already legal; a clawback fits `'adjust'` |
| `points_batches` | `earned > 0`, **`remaining >= 0`** | ⚠️ you **cannot** claw back points out of a spent batch — see §5.1 |
| `credit_ledger` | **none** on `amount_cents`; `entry_type IN ('loyalty_earn','loyalty_redeem','referral_reward','gift_card_load','membership_credit','manual_adjust','spend')` | negative rows legal; `manual_adjust` is the natural reversal type |
| `gift_cards` | `balance_cents >= 0`; `status IN ('active','redeemed','void')` | `'void'` already exists and is unused by any live function |
| `client_packages` | `remaining >= 0`; `status IN ('active','used_up')` | no `'refunded'` status exists |
| `stock_batches` | `qty >= 0` | mutable in place — see §5.4, this is the worst finding in the document |

### 1.4 Permissions as they actually are (live)

```
staff_role_check  CHECK (role IN ('owner','manager','stylist','frontdesk'))
app.is_salon_member(uuid)  -> exists(staff where business_id = p and user_id = auth.uid())
app.is_salon_owner(uuid)   -> ... and s.role = 'owner'
```

**There are exactly two privilege levels in the live database: member and owner.** `manager`, `stylist` and `frontdesk` are all indistinguishable from each other — every one of them satisfies `is_salon_member`.

⚠️ **I could not verify the `refund_sales` permission the brief refers to.** The on-disk `20260717_frenly_v10_1_policy_snapshot.sql` contains no permission concept — it gates `reclassify_sale_policy()` on `app.is_salon_owner` and `reverse_sale()` on `app.is_salon_member`. Grepping `db/migrations/` for `refund_sales` returns nothing. Either it lives in the parallel revision I cannot see, or it does not exist yet. §9 designs against both possibilities.

### 1.5 `app.audit()` — live definition

```sql
insert into audit_log (business_id, actor, action, entity, entity_id, detail)
values (coalesce(new.business_id, old.business_id), auth.uid(), tg_op, tg_table_name,
        coalesce(new.id, old.id), to_jsonb(coalesce(new, old)));
```

It dereferences `new.id` **and** `new.business_id`, so any audited table must carry both. It records `tg_op` (`INSERT`/`UPDATE`/`DELETE`) and **only the new row** — it cannot express "this reversed that, for this reason". **`sales` has no `app.audit()` trigger today.** See §8.

---

## 2. The core claim: a refund is TWO facts, not one

This is the decision everything else hangs off.

The live system, plus v11b, contains two independent event streams:

```
public.sales     = "the service was delivered / the thing was sold"   ACCRUAL
public.payments  = "money physically arrived"                          CASH     (v11b, unapplied)
```

v11b's own header argues this split at length, and the walkthrough confirms the competitor separates them: completion deducts stock and counts a visit with **no** transaction and **no** revenue; a separate Checkout recognises revenue and credits the drawer (**evidence A** — `$0.00 → $50.00`, drawer `$0 → $50 → $75 → $100`).

If completion and payment are two facts, then **un-doing them is also two facts**:

```
un-accrual:  "we should not have billed this"    -> a negative row in `sales`
un-cash:     "money went back to the customer"   -> a negative row in `payments`  (v11b already has this)
```

**These are orthogonal and all four combinations are real:**

| accrual reversed? | cash returned? | What it is | Example |
|---|---|---|---|
| yes | no | **Void** | Rung up on the wrong client 2 minutes ago; never paid |
| yes | yes | **Refund** | Customer hated the cut, paid, gets money back |
| no | yes | **Overpayment return / deposit return** | Took a $30 deposit, customer cancelled a booking that never became a sale |
| no | no | — | not an event |

### 2.1 🔴 OWNER DECISION 1 — is "void" a separate concept from "refund"?

**Option A — one concept, two layers (RECOMMENDED).** There is no `void` verb. There is a `refund_sale()` RPC that always posts the accrual reversal and *optionally* posts the cash refund (`p_refund_method => null` means no money moved). A "void" is simply a refund with no cash leg. UI may still show two buttons — "Void" (same-day, nothing paid) and "Refund" — but they call one RPC.

*Why:* the two differ only in whether a `payments` row exists. Modelling them as two verbs means two RPCs, two audit actions, two over-refund guards, and an inevitable bug where a "void" of a sale that *was* paid silently leaves the money with us. Under Option A that case is impossible to express wrongly: the RPC sees `paid_cents > 0` and forces the question.

*Cost:* the word "void" disappears from the schema. Reports must derive "voided" as *"fully reversed and never paid"* rather than reading a flag.

**Option B — two concepts.** `void_sale()` (hard-blocked if any payment exists, same-day only) and `refund_sale()`. Closer to how a cashier thinks; makes "void" cheap and unambiguous in the UI; matches the competitor's *expenses* void-toggle idiom (**evidence A** for expenses, **evidence D** for sales/transactions).

*Cost:* two code paths that must agree forever.

**Recommendation: A.** Rationale: the underlying fact is identical, and the mistake Option B invites (voiding paid money) is a real-money bug. But this is a workflow/vocabulary call the owner sees in the UI every day, hence 🔴.

> ⚠️ **Note on the competitor:** their Expenses page has a "void toggle" and a "Show voided" filter (**evidence A**). Their Transactions page has a "Refund" row action (**evidence B**). Whether they *also* have a void on transactions is **evidence D**. Do not let the expenses idiom leak into this decision as if it were evidence about sales.

---

## 3. Scope of a refund

### 3.1 Full vs partial — and multiple partials

The reviewer's constraint is explicit: *"Do not limit the final design to one full reversal per sale."*

**Design:** a refund is an **amount**, not a **state**. There is no `sales.refunded` boolean, no `status` column, no state machine. A sale accumulates zero or more reversal rows, and its refunded-ness is **derived**:

```
refunded_cents(S)  = -sum(R.amount_cents) for all R where R.reversal_of = S.id
net_cents(S)       = S.amount_cents - refunded_cents(S)
refund_state(S)    = none    when refunded_cents = 0
                     partial when 0 < refunded_cents < S.amount_cents
                     full    when refunded_cents = S.amount_cents
```

This is the codebase's own principle (*"append-only ledgers + derived views, never a mutable stored balance"*) applied to refunds. It gives multiple partial refunds **for free** — there is nothing to increment and nothing to conflict on.

⚠️ **This kills v10.1's `sales_reversal_of_uidx`.** The unapplied v10.1 file contains:

```sql
--    A sale may be reversed at most once (idempotency; house rule per CLAUDE.md).
create unique index if not exists sales_reversal_of_uidx
  on public.sales (reversal_of) where reversal_of is not null;
```

That index **is exactly the limitation the reviewer forbade** and must not ship. Its stated purpose — idempotency — is real but is the wrong mechanism: uniqueness on `reversal_of` conflates "don't double-post *this* refund" with "only ever refund once". The right mechanism is an idempotency key (§7.3) plus an over-refund guard (§3.4). *If v10.1 is shipping with `reversal_of` removed entirely, as the brief says, this index goes with it and there is nothing to undo — but if any variant of it survives, it must be dropped before v11b.*

### 3.2 Refund of a *reversal*

Rejected. `reversal_of` must point at an original. v10.1's snapshot trigger already raises `'cannot reverse a reversal'`; keep that. To undo an over-eager refund you post a **positive** reversal row against the same original (a "re-bill"), which the sum-based model handles natively: `refunded_cents` goes back down.

🔴 **OWNER DECISION 2 — should un-refunding be allowed at all?** Allowing a positive `reversal_of` row means the refund ledger can move both ways, which is honest but lets a frontdesk user erase a refund's economic effect (the audit row survives, so nothing is *hidden*). Blocking it means a mistaken refund can only be corrected by refunding less next time — i.e. it can't. **Recommendation: allow it, gated on the same permission as a refund, with a mandatory reason.** But this is a control-environment question.

### 3.3 Line-item refunds ⚠️ NOT EXPRESSIBLE TODAY

**`sales` has no line items.** One sale = one `amount_cents`. There is no `sale_lines` table (live-verified: the 34 live tables contain no such thing). `appointment_services` exists (0 rows) and `service_products` exists (0 rows), but neither is a sale line — they're catalog links.

Therefore:

- **A "line-item refund" today is indistinguishable from a partial refund of a specific amount.** The refund row can carry `product_id` + `qty` + `note` as *provenance* ("this $12 was the shampoo"), but nothing in the schema validates that the original sale contained that product, because a sale row can only reference one product anyway.
- **Recommendation:** v11b ships **amount-based partial refunds with optional `product_id`/`qty` provenance**, and explicitly does **not** claim line-item support. True line-item refunds require a `sale_lines` table, which is a v12+ change with its own blast radius (every one of the 6 live sale-writing paths would need to emit lines).
- ⚠️ Flag for the parity matrix: whether the competitor's refund modal offers line selection is **evidence D**. Do not build against a guess.

### 3.4 Over-refund prevention

**Rule:** `refunded_cents(S)` may never exceed `S.amount_cents`, and may never go below 0.

Cannot be a table `CHECK` — it's a cross-row aggregate. Options:

- **(a) Guard inside the RPC, holding a row lock on the original** (`select ... from sales where id = p_sale for update`). ✅ **Recommended.** Simple, gives a good error message, and the lock serialises concurrent refunds of the same sale so two $60 refunds against a $100 sale cannot both pass their check. Note: `SELECT ... FOR UPDATE` requires UPDATE privilege, which v10.1 revokes from `authenticated` — but the RPC is `SECURITY DEFINER` and runs as the owner, so this works. **This must be tested**, because it is exactly the kind of thing that passes in a superuser test and fails for a real user.
- **(b) A deferred constraint trigger** recomputing the sum on every insert. Belt-and-braces; catches direct inserts that bypass the RPC. Cheap (indexed on `reversal_of`).
- **(c) Both.** ✅ **Recommended.** (a) for the error message, (b) so the invariant is structural. This mirrors v10.1's own "RLS is the fence, the grant is the lock, the trigger is the last resort" posture.

### 3.5 Refunding an unpaid sale

Legal, and it is the **void** case. `paid_cents = 0`, so the accrual reversal posts and no cash leg is possible. The RPC must **reject a cash leg** on an unpaid sale rather than post a negative payment that would drive the drawer negative for money never received.

### 3.6 Refund exceeding what was paid

**Rule: the cash leg is capped at `paid_cents`; the accrual leg is capped at `amount_cents`. They are capped independently.**

Concretely, a $100 sale with a $30 deposit paid and $70 outstanding, being cancelled entirely:
- accrual reversal: `-10000` (we un-bill the whole thing) — legal, `refunded_cents = 10000 = amount_cents`.
- cash refund: at most `-3000` (we only ever received $30) — returning $100 would be *giving away* $70.
- Result: `net_cents = 0`, `paid_cents = 0`, `balance = 0`. Correct. The $70 receivable evaporates because it was never owed.

⚠️ **v11b's `record_payment()` deliberately does not enforce a cap** ("Deliberately does NOT enforce 'cannot exceed the balance'... a hard guard would make the cashier's screen wrong more often than it would save a mistake"). That reasoning is sound for *payments* (tips, rounding, deposits) and **wrong for refunds** — there is no legitimate reason to return more cash than was received. **Recommendation: `refund_sale()` enforces the cap itself and never relies on `record_payment()` to do it.** Raw `record_payment(p_kind => 'refund')` stays uncapped for the escape-hatch cases, but the refund RPC is the supported path.

---

## 4. Policy inheritance — the load-bearing part

**Requirement:** a refund inherits the **original sale's snapshot flags**, not today's policy.

v10.1 already builds this correctly and it must be preserved verbatim. From `app.on_sale_policy_snapshot()` (unapplied v10.1, §5):

```sql
if new.reversal_of is not null then
  select * into o from sales where id = new.reversal_of;
  ...
  new.counts_as_revenue  := o.counts_as_revenue;
  new.counts_as_visit    := o.counts_as_visit;
  new.earns_points       := o.earns_points;
  new.policy_resolved_at := o.policy_resolved_at;   -- inherited: same decision, same age
  return new;
end if;
```

**Why this is not optional, with numbers.** Gift cards default to `counts_as_revenue = false` (live: `app.sale_policy_defaults()` returns `('gift_card', false, false, false)`).

1. Firm sells a $100 gift card. Snapshot: `counts_as_revenue = false`. Revenue impact: **$0**.
2. Firm's accountant later says "book gift cards as revenue." `set_sale_policy('gift_card', true, ...)`.
3. Customer refunds the gift card.

- **With inheritance:** the reversal row snapshots `counts_as_revenue = false`. Revenue impact: **$0**. Net across the pair: **$0**. ✅
- **Without inheritance** (resolving current policy): the reversal snapshots `counts_as_revenue = true` and *subtracts* $100 of revenue **the original sale never added**. Reported revenue goes **−$100**. ❌

That is the whole argument. v10.1's own Scenario E already tests it.

### 4.1 Three refinements this document adds

1. **Partial refunds inherit identically.** Inheritance is of the *flags*, not of the amount. A $40 partial reversal of a $100 `counts_as_revenue=true` sale inherits `true` and reduces revenue by exactly $40. No proration of flags — flags are booleans about *meaning*, not quantities.

2. **`reclassify_sale_policy()` must move every reversal, not just one.** v10.1 §7 already does this:
   ```sql
   update sales set counts_as_revenue = n.counts_as_revenue, ...
   where reversal_of = p_sale;
   ```
   ✅ This is already plural (`where reversal_of = p_sale`, not `= (select ...)`), so it survives the move to multiple partials **for the UPDATE**. ⚠️ **But the `set_config` line immediately above it does not:**
   ```sql
   perform set_config('app.reclassify_sale', r.id::text, true)
     from sales r where r.reversal_of = p_sale;
   ```
   `perform ... from` with multiple matching rows sets the token to **one arbitrary row's id**, and `app.sales_immutable_guard()` compares `current_setting('app.reclassify_sale') = old.id::text` **per row**. With two or more reversals, the immutability guard raises on every reversal except the lucky one. **Under v10.1-as-written this is latent** (the unique index guarantees ≤1 reversal). **The moment multiple partials are allowed, `reclassify_sale_policy()` breaks.** This must be fixed in the same migration that removes the once-only limit — either loop per row, or widen the token to accept a set. **This is the single highest-value defect this design review found in the existing files.**

3. **The `kind` equality check stays.** v10.1 raises if `o.kind <> new.kind`. Keep it — a `gift_card` reversal that claimed to be a `service` would inherit gift-card flags while being counted by any report that filters on kind.

---

## 5. Cross-module effects

Summary table first; the argument for each follows.

| Module | Rule | Full refund | Partial refund | Owner call? |
|---|---|---|---|---|
| **Points earn** | Configurable; **default: no clawback** | no clawback (default) | no clawback (default) | 🔴 **D3** |
| **Points already spent** | Never claw back below what a batch has left; ledger may go negative, batches may not | see §5.1 | see §5.1 | 🔴 **D3** |
| **Retention visit count** | Full refund un-counts the visit for **future** grants; partial does not | un-counts | still a visit | 🔴 **D4** (partial threshold) |
| **Reward already granted** | **Never revoked**, even if the qualifying visit is refunded | keep | keep | 🔴 **D4** |
| **Referrals** | Full refund of the qualifying sale reverses the referrer's credit | reverse | no change | 🔴 **D5** |
| **Inventory** | **No auto-restock.** Structurally impossible today | none | none | ⚠️ blocked — §5.4 |
| **Gift cards** | Refund capped at **unredeemed balance**; card voided | capped | capped | 🔴 **D6** |
| **Packages** | Refund capped at **unused sessions pro-rata** | capped | capped | 🔴 **D6** |
| **Memberships** | Consumed periods are **not** refundable | current period only | current period only | 🔴 **D6** |
| **Cash drawer** | Cash refund debits the drawer — **automatic, no new code** | ✅ free | ✅ free | no |
| **Commission** | Claws back automatically via the negative row | ✅ free | ✅ free | 🔴 **D7** (if paid out) |

### 5.1 Points — 🔴 OWNER DECISION 3

This is the one the brief flags hardest, and correctly: **doing nothing is reversible; clawing back points a customer has already seen is not.**

**What the live schema permits and forbids:**

- `points_ledger` has **no sign constraint** and `entry_type` already allows `'adjust'`. A negative `adjust` row is legal today. **A negative points *balance* is therefore representable.**
- `redeem_points()` (live) reads `select coalesce(sum(points),0) into bal from points_ledger` and raises `'insufficient points'` if `bal < lp.redeem_points`. **A negative balance is safe** — it blocks redemption until re-earned. It does not corrupt anything.
- ⚠️ **`points_batches.remaining >= 0` is a hard CHECK.** A FEFO-style clawback that decrements batches will **raise a constraint violation** if the customer has spent the points. This is not a design preference — it is a wall. Any clawback design must either floor the batch decrement at 0 or skip batches entirely.
- ⚠️ `points_earn_once_per_sale` is `UNIQUE (sale_id) WHERE entry_type='earn'`. A clawback **must not** use `entry_type='earn'` with the original's `sale_id`. It should use `entry_type='adjust'` with `sale_id = the reversal row's id` — which needs its own partial unique index (`UNIQUE (sale_id) WHERE entry_type='adjust'`) for idempotency.

**The options:**

**Option A — no clawback ever.** The customer keeps the points. This is v10.1's current stance (`if new.reversal_of is not null then return new; end if`, with the comment *"Doing nothing is reversible; clawing back points a customer has seen is not. Flagged, not decided."*).
- ✅ Zero customer-facing risk. Zero PDPA/expectation risk. Zero new indexes. Zero interaction with the `remaining >= 0` wall.
- ❌ A free-points exploit: buy $1,000, earn 1,000 points, refund, keep the points. Repeat.
- ❌ Loyalty liability is overstated by exactly the refunded earn.

**Option B — pro-rata clawback, ledger only.** Post `entry_type='adjust', points = -floor(refund_amount/100 * earn_rate)`, `sale_id = reversal.id`. Do **not** touch `points_batches`.
- ✅ Accounting-correct; liability tracks reality. Closes the exploit.
- ✅ Sidesteps the `remaining >= 0` wall entirely — nothing decrements.
- ❌ The customer's visible balance drops. If they already spent the points, the balance goes negative and they see it.
- ❌ ⚠️ **Ledger and batches now disagree.** `sum(points_ledger)` says 60; `sum(points_batches.remaining)` says 100. The expiry sweep operates on batches. This is a real inconsistency that would need its own reconciliation story.

**Option C — clawback capped at unspent.** Claw back `min(pro_rata, sum(batches.remaining))`, decrementing batches FEFO. Never negative.
- ✅ Never surprises a customer with a negative balance. Ledger and batches stay consistent.
- ❌ Partially closes the exploit only — spend the points *first*, then refund, and you keep everything.
- ❌ The most code, and the most interaction with the batch model.

**My recommendation — and it is deliberately a recommendation about *sequencing*, not about points:**

> **Ship Option A as the DEFAULT, but build the mechanism so B or C is a config flip, not a migration.**
>
> Add `sale_policies`-style per-business configuration — e.g. `businesses.refund_clawback_points text default 'none' check (in ('none','ledger_only','capped'))` — and have the reversal path read it. v11b ships with every business on `'none'`, which is byte-for-byte v10.1's current conservative behaviour and changes nothing for anyone.
>
> **Why this is the right shape regardless of which option the owner picks:** the asymmetry the brief identifies is real. Shipping A and later flipping to B costs one config update and affects only *future* refunds. Shipping B and later retreating to A means points were already taken from real customers and cannot be un-taken without a restatement. The mechanism is the expensive part; the policy is the cheap part. Build the expensive part, defer the cheap part to the owner.
>
> **If forced to choose a permanent default:** Option C. It closes the honest half of the exploit while making the "customer sees a negative balance" scenario structurally impossible. But I am not choosing — 🔴.

### 5.2 Retention (`reward_grants`) — 🔴 OWNER DECISION 4

Two separable questions.

**(a) Does a refunded visit un-count toward *future* rewards?**

The live visit-count window in `app.on_sale_recorded()`:
```sql
select count(*) into v_count from sales s
  where s.business_id = new.business_id and s.client_id = new.client_id
    and s.kind = any(v_visit_kinds)
    and s.occurred_at >= w_start and s.occurred_at < w_end;
```
v10.1 improves this to `and s.counts_as_visit and s.reversal_of is null`. ⚠️ **Note what that does *not* do:** a fully refunded sale still has `reversal_of IS NULL` (it's the *original*) and `counts_as_visit = true`, so **it still counts as a visit**. The `reversal_of is null` clause only stops the *reversal row* from being double-counted as a second visit — which it correctly does. Un-counting the refunded original requires a new predicate:

```sql
and not exists (select 1 from sales r where r.reversal_of = s.id
                group by r.reversal_of having -sum(r.amount_cents) >= s.amount_cents)
```

**Recommendation: only a FULL refund un-counts the visit. A partial refund does not.**

*Why:* a visit is a physical fact — the person walked in and was served. Refunding $10 of a $100 cut doesn't mean they weren't there. Refunding the whole thing usually means it didn't happen (wrong client, cancelled, never delivered). The rule "did we un-bill 100% of it?" is a clean, explainable line. 🔴 because the owner may prefer a threshold (>50% refunded = not a visit) — I have no evidence either way, and the competitor's behaviour here is **evidence D**.

**(b) Is an already-granted reward revoked?**

**Recommendation: NO. Never.** Strongly held.

*Why:* `reward_grants` is an **entitlement communicated to a customer**. It may already be `status='redeemed'`, and if `reward_type='credit'` the value is already in `credit_ledger` and may already be spent. Revoking it means either (i) clawing spendable money back out of a customer's balance — potentially negative — or (ii) a dangling `reward_grants` row that says `redeemed` for a reward that no longer exists. Both are worse than the overcount. This mirrors v10.1's ruling for reclassification (*"Entitlements already communicated to a customer stay honoured"*) and should be the same ruling for the same reason.

⚠️ Note the interaction: `reward_grants_program_id_client_id_period_index_key` is `UNIQUE (program_id, client_id, period_index)`. Because a grant is never revoked, a refund followed by a re-qualifying visit in the same period **cannot** re-grant — the unique index swallows it via the existing `exception when unique_violation then null`. That is the correct outcome (one reward per period) and needs no change, but it should be asserted in a test so nobody later "fixes" it.

### 5.3 Referrals — 🔴 OWNER DECISION 5

The live qualification block sets `referrals.status = 'rewarded'` and inserts a `credit_ledger` row of `entry_type='referral_reward'` for the **referrer** — a different client from the one refunding.

**The fraud vector is concrete:** create a second client, use your own referral code, buy $50, collect the referral credit, refund the $50. Repeat. Unlike the points exploit, this one mints **spendable in-store credit**, not points. `one_referral_per_referred` limits it to one per referred-client, but creating clients is free.

**Options:**

- **A — never reverse.** Simplest; matches the "entitlements stay honoured" principle. But the entitlement here was obtained on a **false premise**, and the beneficiary is a *third party* who may be the fraudster.
- **B — reverse on full refund of the qualifying sale.** Post `credit_ledger (entry_type='manual_adjust', amount_cents = -reward_cents)` for the referrer, and set `referrals.status` back to `'pending'`. ⚠️ `referrals_status_check` allows `('pending','qualified','rewarded')`, so `'pending'` is legal — but reverting to `'pending'` means the referral can qualify *again* on the referred client's next real sale, which is arguably correct.
- **C — reverse only if the referrer's credit is unspent.** Check `client_credit_balance >= reward_cents` first; otherwise leave it and log.

**Recommendation: B, on FULL refund only, with the negative credit row allowed to drive the balance negative.**

*Why B over A:* a referral reward is contractually "you get $X when your friend's first visit **completes**". A fully refunded visit did not complete. Reversing it is not clawing back an earned entitlement; it is correcting a qualification that turned out to be false. That is a materially different act from §5.2(b).

*Why B over C:* C makes the fraud **profitable by construction** — spend the credit first, then refund, and C declines to act. If we're going to reverse at all, reversing conditionally on the fraudster's cooperation is worse than not reversing.

*The honest cost of B:* a negative credit balance for an **innocent referrer** whose friend legitimately got a refund. That is a real customer-facing harm and it is why this is 🔴 rather than my call. If the owner picks A, the fraud vector should be logged as an accepted risk in the open-questions register, not silently ignored.

⚠️ Also note: `client_credit_balance` is a **view** over `credit_ledger` (per CLAUDE.md), so a negative balance is representable. Whatever spends credit must handle it — I did not audit the spend path, and it is not in scope here.

### 5.4 Inventory ⚠️ **BLOCKER — exact restock is structurally impossible today**

This is the most significant finding in this document.

Both live deduction paths mutate `stock_batches.qty` **in place** and record **nothing** about which batch was taken:

```sql
-- app.on_sale_stock_deduct() (live)
for bt in select id, qty from stock_batches
  where product_id = new.product_id and qty > 0
  order by expires_on nulls last, received_on loop
  exit when v_need <= 0;
  v_take := least(bt.qty, v_need);
  update stock_batches set qty = qty - v_take where id = bt.id;   -- <-- no record of this
  v_need := v_need - v_take;
end loop;
```

`app.on_appointment_completed()` does the same for `service_products` consumption. **There is no `stock_movements` table** (live-verified across all 34 tables).

**Therefore the question "which batch does a returned unit go back to?" is unanswerable from the data.** It's not hard — the information does not exist. A refund can know a sale took 1 unit of product P; it cannot know whether that unit came from the batch expiring next week or the one expiring next year.

⚠️ **Second, deeper problem:** `stock_batches.qty` is a **mutable stored balance**, which directly violates the codebase's own stated first principle (*"Append-only ledgers + derived views. Never a mutable stored balance."*). Inventory is the one module that never got the ledger treatment. Refunds are simply the first feature that makes the omission *load-bearing*.

**Options:**

- **A — no restock (RECOMMENDED for v11b).** The refund posts the money and does not touch stock. The UI tells the user to adjust stock manually if the goods came back. Honest, correct, non-destructive, and does not encode a guess as a fact.
- **B — restock to a new batch** (`received_on = today`, `expires_on = null`). ❌ **Rejected.** A returned unit of a product expiring in 3 days would be modelled as never expiring, and FEFO would then sell it *last*. That is worse than not restocking: it silently corrupts the expiry model, and inventory is the module where wrong data becomes physical waste.
- **C — restock to the FEFO-first batch** (the one the deduct *probably* took from). ❌ **Rejected.** It is only correct if no stock arrived or moved in between — i.e. it's right by luck. It also silently un-does the wrong batch when a batch was fully drained and is now at 0.
- **D — build `stock_movements` first**, an append-only signed ledger with `batch_id`, and make `product_stock` a derived view. Then refunds restock to exactly the batch they took from, provably. ✅ **The right answer** — and out of scope for a refund migration.

**Recommendation: A for v11b, with D logged as an explicit prerequisite for any future restock feature.** Do not ship B or C. This should be raised in the parity matrix: whether the competitor restocks on refund is **evidence D** — their refund modal was never opened.

### 5.5 Gift cards — 🔴 OWNER DECISION 6a

Live behaviour: `issue_gift_card()` inserts `gift_cards` (`balance_cents = initial_cents`) **and** a `sales` row of `kind='gift_card'` (v9's fix — cash collected, not revenue). `redeem_gift_card()` decrements `gift_cards.balance_cents` and inserts a **`credit_ledger`** row of `entry_type='gift_card_load'`. It deliberately inserts **no sale** (v9: inserting at redemption would double-count).

**The hard case:** $100 card sold; $60 already redeemed into the customer's credit; customer wants a refund.

The $60 **is gone** — it is spendable credit that may already have been spent on a real sale which *was* recognised as revenue. Refunding $100 means refunding $60 of value we already handed over.

**Recommendation:** refund is **capped at `gift_cards.balance_cents`** (the unredeemed remainder, $40), and the card is set to `status = 'void'` (already a legal value, live, and currently unused by any function — so this is the first real use of it). The accrual reversal is `-4000`, inheriting `counts_as_revenue = false`, so revenue is untouched — correct, because the sale never added revenue.

🔴 **because the alternative is a real business position:** the owner may want to refund the full $100 and post a compensating `credit_ledger (entry_type='manual_adjust', amount_cents = -6000)` to take the loaded credit back — potentially driving the customer's credit balance negative. That is defensible ("you get your money, you give back the value"). It is a customer-relations call, not a schema call. **My recommendation is the cap** because it cannot make a customer's balance negative and cannot fail.

⚠️ Also flag: v11b's own header already notes *"Refund of a gift-card-**method** payment does not restore the card balance"* — a different case (paying *with* a card and refunding), also unresolved. Both should be answered together; they are the same asymmetry seen from two sides.

### 5.6 Packages — 🔴 OWNER DECISION 6b

Live: `sell_package()` inserts `client_packages (remaining = plan.sessions)` and a `sales` row of `kind='package'` at `plan.price_cents`. `use_package_session()` decrements `remaining` and inserts a **$0 `kind='service'` sale**.

Live policy default (from `app.sale_policy_defaults()`): `('package', true, false, true)` — revenue **yes**, visit **no**, points **yes**. (CLAUDE.md's noted "11 visits per 10-session package" bug is what `counts_as_visit = false` fixes.)

**The hard case:** a 10-session, $500 package with 4 sessions used.

**Recommendation:** refund capped at the **unused pro-rata** — `price_cents * remaining / sessions` = `$500 * 6/10 = $300`. Set `client_packages.remaining = 0`. ⚠️ `client_packages_status_check` allows only `('active','used_up')` — **there is no `'refunded'` status**, so a refunded package would have to masquerade as `'used_up'`, which is a lie in the data. **Adding `'refunded'` to that CHECK is a required part of the implementation** and is a schema change beyond refunds proper. Flag it.

⚠️ Note the compounding: package sales `earns_points = true` on the **full** price. Under points Option B/C, a $300 refund of a $500 package claws back 60% of the points earned at purchase — while the 4 sessions the customer consumed each fired a $0 sale that earned **nothing** (`floor(0/100 * rate) = 0`). The arithmetic holds, but only by coincidence. Worth an explicit test.

🔴 because "do we refund unused sessions pro-rata, or is a package non-refundable once opened, or is there an admin fee?" is a pricing decision. **My recommendation is pro-rata on unused** as the least surprising default.

### 5.7 Memberships — 🔴 OWNER DECISION 6c

Live: `enroll_membership()` and `app.run_membership_renewals()` each insert a `kind='membership'` sale and, if `plan.credit_cents > 0`, a `credit_ledger` row of `entry_type='membership_credit'`. Policy default: `('membership', true, false, false)` — revenue yes, visit no, points no.

**Recommendation: a consumed period is not refundable.** Only the **current** period may be refunded, and only if `now() < current_period_end`. Prorating a period the customer had access to would mean refunding a benefit already delivered.

⚠️ **The membership credit is the same trap as the gift card**: if `plan.credit_cents = 2000` was granted at renewal and the customer already spent it, refunding the period returns money for value already consumed. Same three options as §5.5; **recommendation: cap the refund at `period_price - unspent_credit_shortfall`**, or more simply, apply the same rule the owner chooses for gift cards. **These three (gift card, package, membership) should get ONE consistent ruling, not three** — they are the same question: *"what happens when we refund a prepayment whose value has already been partly delivered?"* Hence D6 is one decision with three instances.

### 5.8 Cash drawer — ✅ falls out for free

v11b's `app.on_payment_drawer()` gates only on `new.method = 'cash'` and posts `amount_cents` **verbatim** into `cash_drawer_movements`. Because a refund payment is a **negative** `amount_cents` (enforced by v11b's sign check), a cash refund posts a **negative** `sale_cash` movement and the drawer debits automatically. **No new code.**

Two notes:
- `cash_drawer_movements` has `check (kind not in ('open_float','pay_in','sale_cash') or amount_cents <> 0)` — only rejects **zero**, not negatives. ✅ compatible.
- `one_drawer_movement_per_payment` (`UNIQUE (payment_id)`) means a replayed refund cannot double-debit. ✅
- A cash refund at a branch with **no open session** posts with `session_id = null` and still hits the branch running total — v11b's deliberate choice, and correct for refunds too.

### 5.9 Commission — 🔴 OWNER DECISION 7

v11b's `sale_commission` view computes `floor(s.amount_cents * rate_bps / 10000.0)` per sale row.

**A negative reversal row therefore produces negative commission automatically** — `floor(-4000 * 1000 / 10000.0) = -400` — and nets against the original in any `sum()`. **The clawback is free**, on one condition:

⚠️ **The reversal row must carry `staff_id`.** v11a adds `sales.staff_id`; v10.1's `reverse_sale()` insert **does not copy it**:
```sql
insert into sales (business_id, client_id, kind, amount_cents, occurred_at, note, reversal_of)
```
No `staff_id`, no `branch_id`. If the reversal row has `staff_id = null`, `sale_commission` yields `commission_cents = 0` for it (`when st.id is null then 0`) and the original's commission **never claws back**. **The refund RPC must copy `staff_id` and `branch_id` from the original.** (Branch matters too, or the reversal lands in the default branch's drawer/reports rather than the branch that made the sale.)

🔴 **The genuine decision:** should commission claw back **if it has already been paid out?** Today this is **moot** — v11b's §4.1 is explicit that `sale_commission` is *"DATA FOUNDATION ONLY... It does not pay anyone, has no period close, and no payout ledger."* There is nothing to claw back *from*. **Recommendation: let it net automatically now** (it's free and correct), and flag that when a payout ledger exists, "refund of a sale from a closed commission period" needs its own rule — almost certainly "adjust the *next* period, never restate a closed one," which is standard payroll practice. That is a v12+ decision.

⚠️ One more: `floor()` on negatives rounds **away from zero** in Postgres (`floor(-0.5) = -1`). A $0.01-rate refund could claw back one cent more than was granted. Immaterial in cents at realistic rates, but assert it rather than discover it.

---

## 6. Recommended representation

### 6.1 The options

**Option 1 — negative rows in `sales`, linked by `reversal_of`.** ✅ **RECOMMENDED**

**Option 2 — a dedicated `sale_reversals` table.**

**Option 3 — reuse v11b's negative `payments` only; no accrual reversal.**

### 6.2 The argument

**Option 3 is disqualified on correctness, not taste.** It cannot express a **void** — a sale rung up on the wrong client and never paid has no payment to negate, so under Option 3 the $100 stays in accrual revenue **forever** with no mechanism to remove it. It also cannot un-bill: `revenue_accrual` sums `sales.amount_cents` and would never move. Option 3 confuses "we got our money back" with "we shouldn't have billed it" — precisely the accrual/cash conflation v11b spent 90 lines arguing against. **Rejected.**

**Option 2 (`sale_reversals`) is the seductive one, and it's a trap.** Its appeal is that `sales.amount_cents >= 0` survives untouched, so no existing consumer changes. That is exactly the problem:

> **Every existing consumer keeps working — and every one of them is now silently wrong.** Every `sum(sales.amount_cents)` in the dashboard, both charts, Reports, `get_revenue_summary()`, the CSV export — each over-reports revenue by the full refunded amount and **nothing fails**. The failure mode is wrong-by-omission, silent, and reintroduced by every new report anyone writes forever. It is the same class of bug as v10's read-time policy resolution, which is what v10.1 exists to fix. We would be fixing that defect in one migration and reintroducing its shape in the next.

Under Option 1, a refund lands in `sales` and **every existing sum nets out with zero code changes**. The correct thing is the default thing.

Option 2 also duplicates the policy-snapshot machinery: a `sale_reversals` row still needs `counts_as_revenue` inherited, so you either duplicate the columns and the trigger, or you join. Option 1 gets it from the trigger v10.1 already wrote.

**Option 1's honest costs:**

1. ⚠️ **`sales.amount_cents >= 0` must be relaxed** — see §7.2 for the full consumer blast radius. This is real work and real risk.
2. **`count(*) from sales` becomes wrong** wherever it means "number of transactions". Reversal rows inflate it. Every such count needs `and reversal_of is null` — v10.1 already flags this for the visits KPI.
3. **`sales` becomes a table where a row can be negative**, which surprises anyone reading it fresh.

Cost 1 is a one-time migration with a bounded, enumerable consumer list (§7.2). Cost 2 is bounded and already partly handled by v10.1. Cost 3 is what a ledger *is* — `credit_ledger` and `points_ledger` are already signed, and v11b's `payments` is signed. **`sales` is the odd one out, and refunds are the feature that makes it the odd one out.** Option 1 doesn't add an inconsistency; it removes one.

### 6.3 The recommendation, precisely

> **Two rows, two layers, one RPC.**
>
> **Accrual leg — always.** A negative row in `public.sales`:
> - `reversal_of` = the original sale's id (FK, `on delete restrict`)
> - `amount_cents` = negative, magnitude = the refunded amount (partial or full)
> - `kind` = **identical** to the original (enforced)
> - `client_id`, `staff_id`, `branch_id` = **copied** from the original (§5.9 — v10.1's `reverse_sale()` omits the latter two)
> - `appointment_id` = **NULL, always** (⚠️ §7.1 — `one_sale_per_appointment`)
> - `product_id` / `qty` = optional provenance (§3.3)
> - the three policy flags = **inherited** via v10.1's `app.on_sale_policy_snapshot()` (§4)
> - `occurred_at` = `now()` — the refund happened today, not on the original's date. *(A backdated refund into a closed period is a restatement and should go through `reclassify_sale_policy()`'s discipline, not through a refund.)*
>
> **Cash leg — only if money moved.** A `payments` row with `kind='refund'`, negative `amount_cents`, `sale_id` = the **ORIGINAL** sale's id (⚠️ §7.4), capped at `paid_cents` (§3.6). Omitted entirely for a void.
>
> **Both legs, atomically, in one `public.refund_sale()` RPC.** Never two calls the UI could half-complete.

### 6.4 Proposed RPC surface (signature only — no implementation, this is a design doc)

```
public.refund_sale(
  p_sale             uuid,      -- the ORIGINAL sale
  p_amount_cents     integer,   -- POSITIVE; the RPC negates. null = full remaining.
  p_reason           text,      -- MANDATORY, min length enforced
  p_refund_method    text default null,  -- null = VOID (accrual only, no cash leg)
  p_idempotency_key  text default null,  -- strongly recommended; see §7.3
  p_product          uuid default null,  -- optional provenance
  p_qty              integer default null,
  p_reference        text default null
) returns json   -- { reversal_sale_id, payment_id, refunded_cents_total, net_cents, refund_state }
```

Returning **both** ids plus the recomputed derived state lets the UI render the outcome without a second round-trip, and makes the two legs visibly one act.

---

## 7. Mechanics — the sharp edges

### 7.1 ⚠️ `one_sale_per_appointment` — the collision

```
one_sale_per_appointment  UNIQUE (appointment_id) WHERE appointment_id IS NOT NULL   -- LIVE
```

A reversal of an appointment-derived sale that copies `appointment_id` **collides with the original**. Worse: `app.on_appointment_completed()` inserts with `on conflict do nothing`, so if that pattern is copied into the refund path, the reversal is **silently swallowed** — the RPC returns success, no reversal exists, money is refunded and revenue is never reduced. A silent money bug.

**Resolution: reversal rows carry `appointment_id = NULL`, always.** The appointment is reachable via `reversal_of -> sales.appointment_id`. Any report needing "refunds against appointment A" joins through the parent.

**Rejected alternative:** changing the index to `UNIQUE (appointment_id) WHERE appointment_id IS NOT NULL AND reversal_of IS NULL`. It would work, and it would let reversal rows carry the appointment directly. Rejected because it *weakens a live idempotency guard* that currently protects the completion trigger, to buy denormalisation we don't need. Keep the strong guard; NULL the column.

### 7.2 ⚠️ Relaxing `sales_amount_cents_check` — the consumer blast radius

v10.1 proposes:
```sql
alter table public.sales drop constraint if exists sales_amount_cents_check;
alter table public.sales add constraint sales_amount_cents_check check (
  (reversal_of is null     and amount_cents >= 0) or
  (reversal_of is not null and amount_cents <= 0)
);
```
✅ **Correct and sufficient — with one change.** The `<= 0` should be `< 0`: a zero-amount reversal is meaningless and should be rejected the way v11b rejects `amount_cents = 0` on payments. (Note the asymmetry is deliberate — `>= 0` must stay `>=` for originals, because `use_package_session()` inserts a **$0** sale.)

**⚠️ §3.2 conflict:** if un-refunding is allowed (a *positive* `reversal_of` row), this constraint **forbids it**. The constraint would need to become `(reversal_of is not null and amount_cents <> 0)`, with sign discipline moved into the RPC + the over-refund guard (which already bounds `refunded_cents` to `[0, amount_cents]` from both ends). **These two decisions are coupled** and must be made together.

**Every live consumer of the sign assumption, enumerated:**

| Consumer | Effect of negative rows | Action |
|---|---|---|
| `app.on_sale_recorded()` | would earn **negative** points, count a **visit**, and qualify a **referral** off a refund | ⚠️ **must early-return on `reversal_of is not null`** — v10.1 already does this |
| `app.on_sale_stock_deduct()` | gates on `product_id is not null` only. A reversal with provenance `product_id` would **deduct stock again** on a refund | ⚠️ **must also gate on `reversal_of is null`** — v10.1 does **not** do this, and v11b's compatibility table wrongly asserts this function is unaffected ("gates on product_id, not kind or branch"). **Real defect.** |
| `sales_qty_check` (`qty IS NULL OR qty > 0`) | a reversal cannot carry a negative qty | fine — provenance qty stays positive; sign lives in `amount_cents` |
| `app/index.html` revenue KPI | still hardcodes `kind !== 'gift_card'`; negatives net out **correctly by accident** | UI work, owned elsewhere |
| `app/index.html` visits KPI | reversal rows inflate `count(*)` | needs `reversal_of === null` — v10.1 already flags |
| v11b `get_revenue_summary()` accrual | `sum(sales.amount_cents)` → nets out ✅ | none |
| v11b `sale_balance` | ❌ **breaks** | ⚠️ §7.4 |
| v11b `sale_commission` | negative commission ✅ correct | needs `staff_id` copied (§5.9) |
| v10.1 `reclassify_sale_policy()` | ❌ **breaks with >1 reversal** | ⚠️ §4.1(2) |

### 7.3 Idempotency

The house pattern is unique partial indexes (`points_earn_once_per_sale`, `one_sale_per_appointment`, `one_drawer_movement_per_payment`, v11b's `payments_idempotency`).

⚠️ **A refund cannot use "one per sale" uniqueness** — that's the limitation the reviewer forbade. Uniqueness on `reversal_of` conflates *"don't double-post this refund"* with *"only ever refund once"*. They are different properties and need different mechanisms:

- **Don't double-post THIS refund** → `sales.idempotency_key` + `UNIQUE (business_id, idempotency_key) WHERE idempotency_key IS NOT NULL`, exactly mirroring v11b's `payments_idempotency`. The RPC returns the **existing** reversal on replay rather than raising — v11b's reasoning applies verbatim (*"a raise would show the cashier an error for an operation that in fact succeeded, and they would retry again"*), and it is **more** important here: a double-tapped refund that raises invites a second refund of real money.
- **Don't over-refund** → §3.4's row lock + constraint trigger. This is the property that actually bounds the money, and it holds regardless of whether the caller supplies a key.

⚠️ **The two legs must share one key**, or a retry could post a second payment against the deduplicated reversal. Suggestion: derive the payment key deterministically (`p_idempotency_key || ':pay'`) so one caller-supplied key covers both, and the whole RPC is idempotent as a unit.

⚠️ **Points clawback idempotency** (if Option B/C is ever chosen): needs `UNIQUE (sale_id) WHERE entry_type='adjust'` on `points_ledger`, with `sale_id = the reversal row's id`. It must **not** reuse `points_earn_once_per_sale`, which is scoped to `entry_type='earn'`.

### 7.4 ⚠️ v11b's `sale_balance` breaks on refunds — with numbers

```sql
create view public.sale_balance as
select s.id as sale_id, ..., s.amount_cents,
       coalesce(sum(p.amount_cents), 0) as paid_cents,
       (s.amount_cents - coalesce(sum(p.amount_cents), 0)) as balance_cents,
       case when coalesce(sum(p.amount_cents), 0) <= 0 then 'unpaid'
            when coalesce(sum(p.amount_cents), 0) < s.amount_cents then 'partial'
            ...
from public.sales s left join public.payments p on p.sale_id = s.id or (...)
group by s.id, ...
```

**It iterates over `sales`, so a reversal row becomes its own "sale" in the view** — with `amount_cents = -4000` and `paid_cents = 0`. Trace it: `-4000 <= 0`? No, `0 <= 0` is **true** → `payment_status = 'unpaid'`, `balance_cents = -4000`. A phantom "unpaid invoice" for **negative four thousand cents**. v11b's `get_revenue_summary()` filters `balance_cents > 0`, so `unpaid_balance` survives — but any UI reading `sale_balance` directly (which v11b's own UI NOTE instructs: *"read sale_balance for the FULLY PAID / balance-pending badge"*) shows a garbage row.

**And the original is also wrong.** $100 sale, $100 paid, $40 refunded → the refund payment carries `sale_id = the ORIGINAL` (§6.3), so `paid_cents = 10000 - 4000 = 6000`, and `balance_cents = 10000 - 6000 = 4000` → **`'partial'`**. But the customer owes **nothing** — we un-billed $40 and returned $40. The view says they owe $40. **It compares payments against the gross amount and ignores the reversal.**

**Required fix (v11b must ship this, not a later migration):**
1. **Exclude reversal rows from the view's row set:** `where s.reversal_of is null`.
2. **Net the reversals into the original's amount:**
   ```sql
   (s.amount_cents + coalesce((select sum(r.amount_cents) from sales r
                               where r.reversal_of = s.id), 0)) as net_amount_cents
   ```
   and compare `paid_cents` against **`net_amount_cents`**, not `s.amount_cents`, in both `balance_cents` and the `payment_status` CASE.

With both: net $6000, paid $6000 → `'paid'`, `balance 0`. ✅ Correct.

⚠️ **This is why the reviewer was right to unbundle `reverse_sale()` from v10.1.** A `reverse_sale()` shipped in v10.1 would have been live and correct-looking for exactly as long as it took v11b to add `sale_balance` — at which point every refunded sale would silently have shown a phantom outstanding balance. The two migrations have to be designed against each other, which is what this document is for.

**Also required:** the refund payment's `sale_id` must point at the **ORIGINAL**, not the reversal row. If it pointed at the reversal, the join would attach the money to a row the fixed view excludes, and `paid_cents` on the original would never move.

### 7.5 Transaction ordering inside the RPC

1. `select ... from sales where id = p_sale for update` — lock the original; serialises concurrent refunds (§3.4).
2. Validate: exists, same business, `reversal_of is null`, permission (§9), reason present.
3. Compute `refunded_cents` and `paid_cents`; enforce both caps (§3.6).
4. Insert the reversal row. `trg_sale_policy_snapshot` (BEFORE) inherits the flags; `trg_sale_recorded` (AFTER) early-returns on `reversal_of`.
5. If `p_refund_method is not null`: insert the payment (→ `trg_payment_drawer` posts the negative drawer movement automatically).
6. Apply the cross-module rules the owner selected (§5).
7. Insert the `audit_log` row (§8).

All in one transaction. A refund that debits the drawer but doesn't reduce revenue is the failure mode to design out.

---

## 8. Audit trail

⚠️ **`sales` has no `app.audit()` trigger today** (live-verified; v10.1 §7 notes this too). And `app.audit()` **cannot express a refund anyway** — it records `tg_op` (`'INSERT'`) plus `to_jsonb(new)`. It cannot say *which* sale was reversed (well — `reversal_of` is in the row, so it could be dug out), *why*, or *what the state was before*.

**Recommendation: the refund RPC writes its own `audit_log` row explicitly**, exactly as v10.1's `reclassify_sale_policy()` does for `'RECLASSIFY'`:

```
action    = 'REFUND'   (or 'VOID' when there is no cash leg — 🔴 D1's shadow: if D1 picks
                        one concept, one action name with a `voided: true` detail flag is
                        cleaner than two actions)
entity    = 'sales'
entity_id = the ORIGINAL sale's id     <-- so `where entity_id = <sale>` finds every refund
                                            of that sale, which is the query people run
detail    = { reason, reversal_sale_id, payment_id, refunded_cents, refunded_cents_total_after,
              net_cents_after, refund_state_after, method, points_clawed_back,
              referral_reversed, gift_card_voided, ... }
```

Keying `entity_id` on the **original** (not the reversal) is deliberate: the question people ask is *"show me everything that happened to sale S"*, and with multiple partial refunds, one `entity_id` returning N audit rows in time order **is** the refund history.

`payments` already has `trg_payments_audit`, so the cash leg self-audits. Expect **two** audit rows per cash refund (one explicit `'REFUND'`, one automatic `'INSERT'` on `payments`) — that's fine and correct; assert it rather than "fix" it.

⚠️ `audit_log.business_id` is nullable and `actor` is `auth.uid()`. **A refund triggered from `pg_cron` would have `actor = null`.** No refund path is currently automated, so this is theoretical — but if refunds ever become automated (dunning reversal, failed-payment cleanup), `actor = null` needs a convention rather than an accident.

---

## 9. Permissions

⚠️ **Restating §1.4: the live database has two levels, member and owner.** `manager`, `stylist` and `frontdesk` all satisfy `is_salon_member`. So today, `reverse_sale()` gated on `app.is_salon_member` is **open to every staff member including a stylist** — which is precisely the concern the brief raises ("refunds must be gated, not open to every business member"), and precisely what v10.1's on-disk `reverse_sale()` does. **That alone justifies unbundling it.**

⚠️ **I could not verify the `refund_sales` permission.** It does not exist in the live DB and does not appear in any on-disk migration. Designing against both cases:

**If a general permission system lands (v10.1's parallel revision or v11a):** `refund_sale()` gates on it. That is the right answer and needs nothing from this document but a hook.

**If it does not:** the fallback must not be `is_salon_member`. Options:

- **(a) Owner-only** (`app.is_salon_owner`). Safest; matches `reclassify_sale_policy()`. ❌ Operationally wrong: an owner is not at the counter at 9pm, and a frontdesk who can't refund will find a workaround — like re-ringing a negative sale, which is worse because it bypasses every guard in this document.
- **(b) A new `app.can_refund(business)` → `role in ('owner','manager')`.** ✅ **Recommended fallback.** Uses the live `staff_role_check` values, needs no new tables, and gives a real second level. Frontdesk and stylist cannot refund.
- **(c) Per-business config** (`businesses.refund_min_role`). Flexible, more surface, more to get wrong. Defer.

**Recommendation: (b) as a stopgap, explicitly labelled as such, with a comment pointing at the permission system as the real answer.** And whichever lands: **the RLS `insert` policy on `sales` must not become the enforcement point.** It's `with check (app.is_salon_member(business_id))` — any member can insert a `sales` row directly via PostgREST, including one with `reversal_of` set, bypassing `refund_sale()` entirely.

⚠️ **This is a real hole and it needs a structural answer, not a comment.** Options: (i) a BEFORE INSERT trigger raising if `new.reversal_of is not null` and a transaction-local token isn't set (the `set_config` idiom v10.1 already uses for `reclassify_sale_policy()` — ✅ **recommended**, it's an established pattern in this codebase); or (ii) drop `sales_insert` from `authenticated` entirely and route all inserts through RPCs — architecturally cleaner, but `app/index.html` inserts sales directly for quick sale, so it breaks the UI. **Recommendation: (i).** Same shape as the reclassify guard, same reasoning: *a design where the correct thing is the only expressible thing beats one where it is merely default.*

---

## 10. Reporting — how the numbers net out

With the §6.3 representation and the §7.4 `sale_balance` fix:

| Figure | Definition | Effect of a $40 refund on a $100 paid sale |
|---|---|---|
| `revenue_accrual` | `sum(sales.amount_cents) where counts_as_revenue` | 10000 → **6000** (the −4000 reversal nets in) ✅ **no code change** |
| `revenue_cash` | `sum(payments.amount_cents)` joined to revenue-kind sales | 10000 → **6000** (the −4000 payment nets in) ✅ **no code change** |
| `cash_collected` | `sum(payments.amount_cents)`, all kinds | 10000 → **6000** ✅ |
| **A/R** (`unpaid_balance`) | `sum(sale_balance.balance_cents) where > 0` | 0 → **0** ✅ — **only with §7.4's fix.** Unfixed: **4000**, a receivable that does not exist |
| `expenses` | unchanged | — |
| `net_accrual` / `net_cash` | revenue − expenses | both fall by 4000 ✅ |
| Drawer `expected_cents` | `sum(cash_drawer_movements.amount_cents)` | falls by 4000 ✅ **automatic** (§5.8) |
| Commission | `sum(sale_commission.commission_cents)` | falls by `rate × 4000` ✅ — **only if `staff_id` is copied** (§5.9) |
| **Visits** | `count(*) where counts_as_visit and reversal_of is null` | unchanged (partial ≠ un-visit, §5.2) ✅ |
| **Txn count** | `count(*) where reversal_of is null` | unchanged ✅ — **only with the `reversal_of is null` filter** |

**The headline:** `revenue_accrual`, `revenue_cash`, `cash_collected`, the drawer, and commission **all net out with zero code changes**, purely because the refund is a negative row in the same ledger the report already sums. That property is Option 1's entire justification (§6.2), and it is why Option 2 (`sale_reversals`) is the wrong answer despite looking safer.

**A/R is the exception, and it's instructive:** it's the one figure that compares *two* ledgers rather than summing one, so it's the one that needs explicit work. That is a good smell test for any future report — *if it sums a ledger, refunds are free; if it compares ledgers, refunds need thought.*

---

## 11. 🔴 Decisions escalated to the owner

Collected. Every one is business semantics, not schema.

| # | Decision | Options | My recommendation | Why it's yours |
|---|---|---|---|---|
| **D1** | Is **void** a separate concept from **refund**? | A: one RPC, cash leg optional · B: two RPCs | **A** | It's the verb the owner's staff use daily |
| **D2** | May a refund be **un-done** (positive reversal row)? | allow (gated + reason) · forbid | **allow** | Control-environment call; also constrains the §7.2 CHECK |
| **D3** | **Points clawback** on refund | A: never · B: pro-rata, ledger only, may go negative · C: capped at unspent | **Ship A as default; build the config so B/C is a flip.** If forced to choose permanently: **C** | Doing nothing is reversible; taking points a customer has seen is not |
| **D4** | Does a refunded visit **un-count**? Is a granted reward **revoked**? | full-refund-only un-counts / threshold / never · revoke / never revoke | **Full-refund-only un-counts; never revoke a granted reward** | "Was it really a visit?" is a business judgement; competitor behaviour is **evidence D** |
| **D5** | **Referral** credit reversal when the qualifying sale is refunded | A: never · B: reverse on full refund (may go negative) · C: reverse only if unspent | **B** — but A is defensible if the fraud risk is accepted **in writing** | Punishes an innocent referrer to close a fraud vector. Not my trade-off |
| **D6** | **Prepayment refunds** — gift card / package / membership, where value is partly delivered | cap at undelivered (recommended) · full refund + negative credit adjustment · non-refundable once used | **Cap at undelivered — and give ONE ruling for all three**, they are the same question | Pricing + customer-relations policy |
| **D7** | **Commission** clawback once a payout ledger exists | net automatically · adjust next period · never restate closed periods | **Net automatically now** (moot — no payout ledger); **"adjust next period"** when one exists | Payroll policy, and it touches staff pay |

**Two more that are not strictly refund decisions but are blocked behind this work:**

- ⚠️ **Inventory restock** (§5.4) — not an owner decision, a **structural blocker**. Exact restock is impossible until a `stock_movements` ledger exists. Recommendation: **no restock in v11b**; do not ship a guess.
- ⚠️ **`refund_sales` permission** (§9) — needs to exist somewhere. If v10.1's revision doesn't add it, v11b needs `app.can_refund()` as a stopgap, because `is_salon_member` means *a stylist can refund*.

---

## 12. Worked example — end to end, every ledger

**Setup.** Business B (SGT). Points program: 1 pt per $1, `expiry_mode='fixed'`, 365 days. Retention program R: `goal_visits=3`, `period_days=30`. Client C, staff ST (`commission_service_bps = 1000` → 10%), branch BR. Service "Cut & Colour", $100.00. Appointment A booked for C/ST. Sale policy: all defaults, no overrides (`sale_policies` = 0 rows live). `service` defaults → `counts_as_revenue=true, counts_as_visit=true, earns_points=true`.

Assumes v10.1 (snapshot, no `reverse_sale`), v11a (branches/staff/commission), v11b (payments/drawer) + this design.

---

### T0 — Booking. Deposit taken.

```
record_payment(B, 'paynow', 3000, p_appointment => A, p_kind => 'deposit', key => 'dep-1')
```

| Ledger | Row |
|---|---|
| `payments` | `P1`: kind=`deposit`, `amount_cents = +3000`, `appointment_id = A`, **`sale_id = NULL`**, method paynow |
| `sales` | — *(no sale yet; the appointment hasn't completed)* |
| `cash_drawer_movements` | — *(paynow, not cash)* |

`get_revenue_summary`: accrual **0**, cash **0**, collected **3000**.

---

### T1 — Appointment completes. `app.on_appointment_completed()` fires.

| Ledger | Row |
|---|---|
| `sales` | **`S`**: kind=`service`, `amount_cents = +10000`, `appointment_id = A`, `client_id = C`, `staff_id = ST`, `branch_id = BR`, `reversal_of = NULL`<br>snapshot (BEFORE INSERT): `counts_as_revenue=true, counts_as_visit=true, earns_points=true`, `policy_resolved_at = T1` |
| `points_ledger` | `PL1`: `entry_type='earn'`, `points = +100`, `sale_id = S` |
| `points_batches` | `PB1`: `earned=100`, `remaining=100`, `sale_id = S`, `expires_at = T1 + 365d` |
| `reward_grants` | — *(visit 1 of 3)* |
| `stock_batches` | *(unchanged — no `service_products` rows)* |

**The deposit attaches with no mutation.** `P1.sale_id` is still NULL; `sale_balance`'s join branch (b) resolves it via `S.appointment_id = A`.

`sale_balance(S)`: `net 10000`, `paid 3000`, `balance 7000`, **`'partial'`**.
`get_revenue_summary`: accrual **10000**, cash **0** *(`P1` has `sale_id = NULL`, so the `join sales on s.id = p.sale_id` drops it — ⚠️ **v11b defect, out of scope, worth flagging: `revenue_cash` under-counts every deposit**)*, collected **3000**, unpaid **7000**.
`sale_commission(S)`: `rate 1000`, **`+1000`** ($10).

---

### T2 — Balance paid, cash.

```
record_payment(B, 'cash', 7000, p_sale => S, p_staff => ST, key => 'chk-1')
```

| Ledger | Row |
|---|---|
| `payments` | `P2`: kind=`payment`, `+7000`, `sale_id = S`, method cash |
| `cash_drawer_movements` | `M1`: kind=`sale_cash`, **`+7000`**, `payment_id = P2` — automatic |

`sale_balance(S)`: `net 10000`, `paid 10000` (3000 + 7000), `balance 0`, **`'paid'`**.
`get_revenue_summary`: accrual **10000**, cash **7000**, collected **10000**, unpaid **0**.
Drawer `expected_cents`: **7000**.
`points_ledger` for C: **still 100, not 200.** The payment is invisible to `on_sale_recorded()`.

---

### T3 — 🔵 **THE REFUND. $40 back, cash.**

```
refund_sale(p_sale => S, p_amount_cents => 4000, p_reason => 'colour not as agreed',
            p_refund_method => 'cash', p_idempotency_key => 'rf-1')
```

**Guards, in order (§7.5):**
1. `select ... for update` on `S`. ✅
2. `S.reversal_of is null` ✅ · same business ✅ · `can_refund(B)` ✅ · reason present ✅
3. `refunded_cents(S) = 0`; `0 + 4000 <= 10000` ✅ **over-refund guard passes**
4. `paid_cents(S) = 10000`; `4000 <= 10000` ✅ **cash cap passes** (§3.6)

**Accrual leg:**

| Ledger | Row |
|---|---|
| `sales` | **`R1`**: `reversal_of = S`, kind=`service` *(must match)*, **`amount_cents = −4000`**, `client_id = C`, **`staff_id = ST`** *(copied — §5.9)*, **`branch_id = BR`** *(copied)*, **`appointment_id = NULL`** *(⚠️ §7.1 — copying it would collide with `one_sale_per_appointment`)*, `occurred_at = T3`, `idempotency_key = 'rf-1'`<br>snapshot: **`counts_as_revenue=true, counts_as_visit=true, earns_points=true`, `policy_resolved_at = T1`** — all five **INHERITED from `S`** (§4), *not* re-resolved. `policy_resolved_at` is `T1`, not `T3`: same decision, same age. |

**Triggers on `R1`:**
- `trg_sale_policy_snapshot` (BEFORE) → takes the inheritance branch. ✅
- `trg_sale_recorded` (AFTER) → `new.reversal_of is not null` → **early return.** No points, no visit, no referral. ✅
- `trg_sale_stock_deduct` → ⚠️ `product_id` is NULL here so it's inert — **but see §7.2: if a refund carried `product_id` provenance, this trigger would deduct stock on a refund.** Must gate on `reversal_of is null`.

**Cash leg:**

| Ledger | Row |
|---|---|
| `payments` | `P3`: kind=`refund`, **`amount_cents = −4000`** *(RPC negates; sign check enforces)*, **`sale_id = S`** *(⚠️ the ORIGINAL, not `R1` — §7.4)*, method cash, `idempotency_key = 'rf-1:pay'` |
| `cash_drawer_movements` | `M2`: kind=`sale_cash`, **`−4000`**, `payment_id = P3` — **automatic**, no new code (§5.8) |

**Cross-module, under my recommended defaults:**

| Module | Row / effect |
|---|---|
| `points_ledger` | **no change — 100 pts.** D3 default = no clawback. *(Under D3-B: `PL2` `entry_type='adjust'`, `points = −40`, `sale_id = R1` → balance 60. Under D3-C: same, capped at `PB1.remaining = 100` → also −40, and `PB1.remaining` → 60.)* |
| `points_batches` | **no change** *(and note: under D3-B it would still be 100 while the ledger said 60 — the inconsistency §5.1 warns about)* |
| `reward_grants` | **no change.** Partial refund ≠ un-visit (§5.2). C is still visit 1 of 3. |
| `referrals` | **no change.** Partial refund never reverses a referral (§5.3). |
| `stock_batches` | **no change.** No restock (§5.4). |
| `audit_log` | `action='REFUND'`, `entity='sales'`, **`entity_id = S`** (the original), `detail = { reason:'colour not as agreed', reversal_sale_id: R1, payment_id: P3, refunded_cents: 4000, refunded_cents_total_after: 4000, net_cents_after: 6000, refund_state_after: 'partial', method:'cash', points_clawed_back: 0 }` — **plus** an automatic `INSERT`/`payments` row from `trg_payments_audit`. Two rows, both correct. |

**Every figure after T3:**

| Figure | Before | After | How |
|---|---|---|---|
| `revenue_accrual` | 10000 | **6000** | `10000 + (−4000)` — ✅ no code change |
| `revenue_cash` | 7000 | **3000** | `7000 + (−4000)` — ✅ no code change |
| `cash_collected` | 10000 | **6000** | `3000 + 7000 − 4000` |
| `sale_balance(S)` net | 10000 | **6000** | ⚠️ **only with §7.4's fix.** Unfixed: still `10000` |
| `sale_balance(S)` paid | 10000 | **6000** | `P1 + P2 + P3` |
| `sale_balance(S)` status | `'paid'` | **`'paid'`** | `6000 = 6000` ✅ ⚠️ **Unfixed: `'partial'`, `balance 4000` — a $40 receivable that does not exist** |
| `sale_balance(R1)` | — | **must not exist** | ⚠️ **only with §7.4's `where s.reversal_of is null`.** Unfixed: a phantom row, `amount −4000`, status `'unpaid'` |
| A/R (`unpaid_balance`) | 0 | **0** | ✅ only with §7.4 |
| Drawer `expected_cents` | 7000 | **3000** | `M1 + M2` — ✅ automatic |
| `sale_commission` sum | 1000 | **600** | `+1000 (S) + (−400) (R1)` — ✅ **only because `R1.staff_id = ST` was copied** |
| Visits (C, period) | 1 | **1** | partial ≠ un-visit |
| Txn count | 1 | **1** | ✅ only with `where reversal_of is null` |
| Points (C) | 100 | **100** | D3 default |

**The reconciliation that proves it:** billed $60, collected $60, owed $0, drawer holds $30 cash *(the other $30 came in via paynow and never touched the drawer)*, commission $6 on $60 of work at 10%. Every number is internally consistent, and **five of the eight figures required no code at all** — they net out because the refund is a negative row in a ledger the report already sums.

---

### T4 — Multiple partial refunds. Second $40.

```
refund_sale(S, 4000, 'second issue', 'cash', key => 'rf-2')
```
`refunded_cents(S) = 4000`; `4000 + 4000 = 8000 <= 10000` ✅ **passes.**
→ `R2`: `−4000`, `reversal_of = S`. `refunded_cents(S) = 8000`, `net = 2000`, still `'partial'`.
✅ **No unique-index conflict** — `sales_reversal_of_uidx` does not exist in this design (§3.1). **This is the case v10.1's index would have rejected**, and the one the reviewer specifically required.

`revenue_accrual` **2000** · drawer **−1000** *(overdrawn — real: we've handed back more cash than the $7000 cash we took, because $3000 came in via paynow. Correct, and exactly what a drawer-count would show.)*

### T5 — Third $40. Over-refund.

`8000 + 4000 = 12000 > 10000` → ❌ **raises.** `'cannot refund 4000: only 2000 remains on sale S (10000 billed, 8000 already refunded)'`

### T6 — Replay of T3, verbatim, same key `'rf-1'`.

→ `sales_idempotency` hits → **returns the existing `R1`**, no new row, no new payment, no new drawer movement, no raise (§7.3). `refunded_cents(S)` still 8000. ✅ **The double-tap is safe.**

---

## 13. What I could not determine

Recorded honestly rather than guessed:

1. **The competitor's refund behaviour — entirely.** Their Refund row action exists (**evidence B**); the modal was **never opened** (**evidence D**). Unknown: partial support, line-item selection, restock behaviour, points clawback, whether a separate void exists, what fields it asks for. **Nothing in this document is designed from their refund semantics.** A Pass-2 that opens that modal would materially inform D1, D3, D4 and §3.3 — and is the single highest-value piece of missing evidence.
2. **The `refund_sales` permission.** Not in the live DB, not in any on-disk migration, not in v10.1-as-written (§1.4, §9). Either it's in the parallel revision I can't see, or it doesn't exist. §9 designs for both.
3. **v10.1's final shape.** The brief says `reverse_sale`/`reversal_of` are being removed. I designed assuming `reversal_of` and the inheritance branch of `app.on_sale_policy_snapshot()` **come back in v11b** — they are the correct mechanism and v10.1 already got them right. ⚠️ **If v10.1 ships without `reversal_of`, v11b must add the column, the CHECK relaxation, the inheritance branch, the `on_sale_recorded` early-return, AND the `on_sale_stock_deduct` gate — that's a bigger v11b than the brief implies.**
4. **Whether `sales` will have `branch_id`/`staff_id` at refund time.** Both come from v11a, which is unapplied and rated with 6 defects. §5.9's commission clawback **depends on `staff_id` existing**. If v11a slips, commission clawback silently doesn't happen — and nothing fails.
5. **The credit-spend path.** §5.3 and §5.5 can drive `client_credit_balance` negative. I did not audit what spends credit or whether it tolerates a negative balance. **Out of scope, but a prerequisite for D5-B and the aggressive branch of D6.**
6. **The live UI's exact reads.** `app/index.html` is owned by another agent right now and I did not open it. §7.2's UI rows are from v10.1/v11b's own notes, not from reading the file.
7. **Tips, GST, no-show fees.** All deferred by v11b (its Q1). Each has a refund story. Not designed here.

---

## 14. Implementation checklist for v11b (design-complete, code-not-written)

Ordered by risk, not by convenience.

**Must fix in existing files before/with this work:**
- [ ] ⚠️ **`reclassify_sale_policy()`'s `perform set_config ... from` breaks with >1 reversal** (§4.1). **The highest-value defect found.**
- [ ] ⚠️ **`app.on_sale_stock_deduct()` must gate on `reversal_of is null`** (§7.2). v11b's compatibility table wrongly calls it unaffected.
- [ ] ⚠️ **`sale_balance` must exclude reversal rows and net them into the original** (§7.4). Without it: phantom negative "unpaid" rows and a false receivable on every refunded sale.
- [ ] ⚠️ **Drop / never ship `sales_reversal_of_uidx`** (§3.1) — it *is* the limitation the reviewer forbade.
- [ ] ⚠️ **`reverse_sale()` must copy `staff_id` + `branch_id`** (§5.9), or commission never claws back and the reversal lands in the wrong branch.
- [ ] ⚠️ **`reverse_sale()` gated on `is_salon_member` = a stylist can refund** (§9).
- [ ] Consider: `revenue_cash` under-counts deposits (`P1.sale_id is null` fails the join) — §12/T1. Pre-existing v11b issue, surfaced by this trace.

**New in v11b:**
- [ ] `sales.idempotency_key` + `UNIQUE (business_id, idempotency_key) WHERE NOT NULL` (§7.3)
- [ ] Over-refund constraint trigger + `FOR UPDATE` row lock in the RPC (§3.4) — **test the lock as a real `authenticated` user, not as owner**
- [ ] `refund_sale()` RPC, both legs, one transaction (§6.4, §7.5)
- [ ] `app.can_refund()` stopgap **if** no permission system lands (§9)
- [ ] Trigger blocking direct `reversal_of` inserts outside the RPC, via the `set_config` token pattern (§9)
- [ ] Explicit `action='REFUND'` audit row keyed on the **original** (§8)
- [ ] `client_packages_status_check` += `'refunded'` (§5.6)
- [ ] `amount_cents` CHECK: `< 0` not `<= 0` for reversals — **unless D2 allows un-refund** (§7.2)
- [ ] Per-business points-clawback config, defaulting to `'none'` (§5.1)

**Rolled-back chain tests required before applying** (house rule — Fable runs these):
- [ ] The §12 trace, all of T0–T6, every figure asserted
- [ ] **Two partial refunds succeed; the third over-refund raises** — the reviewer's explicit requirement
- [ ] Replay with the same key returns the same row and posts nothing new
- [ ] Policy-inheritance: flip `gift_card` to `counts_as_revenue=true`, refund a pre-flip card, assert revenue impact is **0** and not **−100**
- [ ] `reclassify_sale_policy()` on a sale with **two** reversals — currently **expected to fail** (§4.1)
- [ ] A refund carrying `product_id` provenance does **not** deduct stock (§7.2)
- [ ] Reversal with `appointment_id` copied → asserts the collision, proving why it's NULLed (§7.1)
- [ ] `sale_balance` shows `'paid'`/`balance 0` after a full-refund-of-paid, and **no row** for the reversal (§7.4)
- [ ] Cross-tenant: `refund_sale()` against another business's sale raises
- [ ] As `anon`: `refund_sale()` → permission denied
- [ ] As a `stylist`: `refund_sale()` → denied (§9)
- [ ] Direct `insert into sales (reversal_of => ...)` via PostgREST as a member → raises (§9)
