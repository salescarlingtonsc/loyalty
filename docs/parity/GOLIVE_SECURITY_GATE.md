# GO-LIVE SECURITY & FINANCIAL-INTEGRITY GATE

**System:** Frenly — multi-tenant loyalty/ops SaaS · Supabase `kyzovonwnscrzmkvocid`
**Live schema:** 17 migrations (…v10 → v10.1 → v11a → v11b → v11c → v12a → v12) — verified against live via `list_migrations`, `pg_get_functiondef`, `pg_policies`, `pg_constraint`. The repo was NOT trusted; every definition below was read from the live catalog.
**Date:** 2026-07-17
**Method:** Every assertion executed inside a single `begin … rollback` transaction. QA tenants built in-transaction. Nothing applied, deployed, committed, or migrated.

---

## VERDICT — one line per part

| Part | Scope | Verdict |
|------|-------|---------|
| **A** | Tenant isolation | **PASS with 2 P2 deviations** — all confidentiality reads, all cross-tenant writes-into-B, all cross-tenant RPCs fail closed for owner/staff/anon/rota. Two *simple-FK* cross-tenant **reference** paths fail open (A can store B's client_id / service_id inside A's own rows). No P0/P1: no read of B's data, no write into B's partition. |
| **B** | §3 policy-snapshot P0 | **PASS — P0 CONFIRMED CLOSED.** Historical accounting is immutable under a live policy flip; new sales adopt the new policy; the old read-time computation diverges (that divergence is the proof). |
| **C** | §8 financial & loyalty integrity | **PASS — 0 failures.** Revenue = row snapshot (not live join); gift-card/membership excluded; explicit-beats-default both directions; NULL inherits; double-earn blocked; package purchase≠visit / session=visit; referral once; balances are ledger views; both idempotency paths dedupe. |
| **D** | §7 auth / permission (DB layer) | **PASS — 0 failures.** anon locked out of financial tables; stylist cannot call owner-only RPCs or read finance; `authenticated` holds no TRUNCATE. |

**Overall gate result:** **No P0 / P1 launch-blocker found by this gate.** Two **P2** referential-integrity hardening items in Part A (recommended fix before or shortly after pilot; see §Deviations). This gate does **not** itself force a NO-GO.

---

## How the non-superuser RLS context was established (the thing most likely to cause a false PASS)

`execute_sql` runs as the `postgres`/service role, which **bypasses RLS**. A test run in that role proves nothing about tenant isolation. To exercise RLS as a real principal I did, per assertion:

```sql
perform set_config('request.jwt.claims',
   json_build_object('sub', <user_uuid>, 'role','authenticated')::text, true);  -- drives auth.uid()
set local role authenticated;   -- (or: set local role anon)  => RLS now enforced
```

**Proof this actually dropped superuser (not a self-fulfilling test):**
- **CANARY control** — as `postgres`, `select count(*) from clients where business_id = B` returns **1** (B's row is visible; RLS bypassed). This proves the probe is *falsifiable*: if `authenticated` also saw it, isolation would be broken.
- As `authenticated` = Tenant-A owner, the same read returns **0**, and `select count(*) from businesses` returns **1** (only A), not 2. RLS is demonstrably in force.
- Confirmed the "forbidden" side genuinely runs the action: e.g. `owner-A UPDATE B sales` returned **`permission denied for table sales`** and `staff/anon/rota INSERT into B` returned **`new row violates row-level security policy`** — real engine errors, not empty stubs.
- **Anti-trap catch:** my first pass "blocked" the staff/anon/rota writes-into-B with `business_id is of type uuid but expression is of type text` — a *type-cast* error that aborted **before** RLS evaluated (a test that couldn't prove anything). Re-run with explicit `::uuid` casts; all three then produced the genuine RLS-policy violation shown above. Likewise `C3` first mis-read the wrong gift-card row (identical in-txn `created_at`); re-tested deterministically by the card's unique code and it passed.

For accounting-only assertions (Part B/C snapshot & constraint behaviour, which are trigger/column/index enforced, not RLS) I ran in the superuser context *with* the owner's JWT claims set, so the `has_perm` checks inside SECURITY DEFINER RPCs still resolved against a real `auth.uid()`. Unique indexes (`points_earn_once_per_sale`) and BEFORE-INSERT snapshot triggers apply to the superuser too, so those results are valid regardless of role.

---

## PART A — TENANT ISOLATION

Two QA tenants built in-transaction: **A** (owner `UA`, stylist `USA` with a real `user_id`, and a **rota-only** staff with `user_id IS NULL`) and **B** (owner `UB`), each with its own branch, clients, service; plus a real B sale for the payment-attach probe.

| id | assertion | expected | actual | pass | evidence |
|----|-----------|----------|--------|:----:|----------|
| CANARY | superuser sees B rows (falsifiability canary) | exposes B | B clients=1 | ✔ (by design) | postgres bypasses RLS |
| CTRL-A0 | **control:** owner-A reads its OWN clients | ≥1 | 2 | ✔ | harness not blanket-blocking |
| A-own-01 | owner-A reads B clients | 0 | 0 | ✔ | RLS `is_salon_member(B)=false` |
| A-own-02 | owner-A reads B appointments | 0 | 0 | ✔ | |
| A-own-03 | owner-A reads B sales | 0 | 0 | ✔ | |
| A-own-04 | owner-A reads B points+credit ledgers | 0/0 | 0/0 | ✔ | |
| A-own-05 | owner-A reads B staff | 0 | 0 | ✔ | |
| A-own-06 | owner-A reads B branches | 0 | 0 | ✔ | |
| A-own-07 | owner-A `get_revenue_summary(B)` | raise | blocked | ✔ | `…permission to view finance (view_finance)` |
| **A-own-08** | owner-A inserts an **A**-sale referencing **B**'s `client_id` | block | **INSERT SUCCEEDED** | **✗ FAIL (P2)** | `sales.client_id` is a *simple* FK → no tenant binding |
| A-own-09 | owner-A writes a row INTO tenant B (`business_id=B`) | block | blocked | ✔ | `new row violates row-level security policy for table "sales"` |
| A-own-10 | owner-A UPDATEs B sales rows | 0/deny | blocked | ✔ | `permission denied for table sales` (no UPDATE grant to `authenticated`) |
| **A-own-11** | owner-A attaches **B**'s service to an **A** appointment | block | **INSERT SUCCEEDED** | **✗ FAIL (P2)** | `appointments.service_id` is a *simple* FK → no tenant binding |
| A-own-12 | owner-A `record_payment(A biz, B sale_id)` | block | blocked | ✔ | `sale does not belong to this business` (+ composite FK `payments_sale_same_tenant`) |
| A-own-13 | owner-A `get_sale_policy(B)` | block | blocked | ✔ | `not a member of this business` |
| A-own-14 | owner-A `redeem_points(B biz, B client)` | block | blocked | ✔ | `not a member of this business` |
| STAFF-readB | stylist-A reads all 7 B tables | 0 exposed | 0 (all denied) | ✔ | RLS |
| STAFF-revB | stylist-A `get_revenue_summary(B)` | raise | blocked | ✔ | view_finance |
| STAFF-writeB | stylist-A writes into tenant B *(re-run w/ ::uuid)* | block | blocked | ✔ | RLS policy violation |
| ANON-readB | anon reads all 7 B tables | 0 exposed | 0 (all denied) | ✔ | RLS / grant |
| ANON-revB | anon `get_revenue_summary(B)` | raise | blocked | ✔ | `permission denied for function get_revenue_summary` |
| ANON-writeB | anon writes into tenant B *(re-run w/ ::uuid)* | block | blocked | ✔ | RLS policy violation |
| ROTA_NOSUB-readB | rota/no-sub reads all 7 B tables | 0 exposed | 0 (all denied) | ✔ | RLS |
| ROTA_NOSUB-revB | rota/no-sub `get_revenue_summary(B)` | raise | blocked | ✔ | view_finance |
| ROTA_NOSUB-writeB | rota/no-sub writes into tenant B *(re-run w/ ::uuid)* | block | blocked | ✔ | RLS policy violation |
| ROTA-mem | `is_salon_member(A)` when `auth.uid()=NULL` (rota row `user_id IS NULL`) | false | false | ✔ | `NULL = auth.uid()` fail-closed |
| ROTA-readA | rota/no-sub reads tenant A clients | 0/deny | denied | ✔ | no login ⇒ no access |

**Part A reads/writes-into-B/RPCs: 0 failures for confidentiality and for writes into B's partition.** The two FAILs are cross-tenant **references stored inside A's own rows** — see Deviations.

---

## PART B — §3 POLICY-SNAPSHOT P0 (immutable history under config change)

Sale **S1** (`kind='service'`) recorded under policy A (service default = revenue/visit/points all TRUE). Then, as owner, `set_sale_policy(A,'service', false,false,false)` (policy B).

| id | assertion | expected | actual | pass |
|----|-----------|----------|--------|:----:|
| B1 | S1 snapshot at insert (policy A) | T/T/T | r=t v=t p=t | ✔ |
| B2 | S1 snapshot AFTER flip is unchanged | T/T/T | r=t v=t p=t | ✔ |
| B3 | tenant-A snapshot **revenue** unchanged across flip | 11234 | 11234 | ✔ |
| B4 | tenant-A snapshot **visit-count** unchanged across flip | 2 | 2 | ✔ |
| **B5** | **CONTROL:** old read-time way (live `sale_policy_set` ⨝ historical `kind`) **diverges** from snapshot | live ≠ snapshot | **live=0, snapshot=11234** | ✔ |
| B6 | NEW sale after flip uses policy B (service revenue now false) | false | false | ✔ |

**The divergence in B5 is the proof.** `on_sale_policy_snapshot` (BEFORE INSERT) freezes `counts_as_revenue/visit/points` + `policy_resolved_at` onto the row; `get_revenue_summary` and the retention visit-count window read the **row snapshot** (`s.counts_as_revenue`), never a live policy join. Flipping policy moves the old (buggy) computation to 0 while frozen history stays at 11234. **P0 closed in production.**

---

## PART C — §8 FINANCIAL & LOYALTY INTEGRITY

| id | assertion | expected | actual | pass |
|----|-----------|----------|--------|:----:|
| C1 | gift-card issuance excluded from revenue by default (v9) | false | false | ✔ |
| C2 | explicit **false** overrides default-true (retail revenue) | false | false | ✔ |
| C3 | explicit **true** overrides default-false (gift_card revenue) *(deterministic by code)* | true | true | ✔ |
| C4 | **NULL** override inherits product default (membership revenue) | true | true | ✔ |
| C5a | control: first earn row exists for a sale | 1 | 1 | ✔ |
| C5b | re-fire earn on same `sale_id` blocked | block | blocked | ✔ (`points_earn_once_per_sale` unique idx) |
| C6 | package **purchase** does NOT count as visit (v10) | false | false | ✔ (kills 11-visits bug) |
| C7 | package **session** use DOES count as visit | true | true | ✔ |
| C8 | membership sale earns 0 points / 0 visit | pts=f vis=f | pts=f vis=f | ✔ |
| C9a | referral qualifies on first qualifying visit | rewarded/1 | rewarded/1 | ✔ |
| C9b | referral re-fire on 2nd visit does NOT pay twice | 1 | 1 | ✔ |
| C10 | `client_points_balance` is a VIEW over the ledger | v | v | ✔ |
| C10 | `client_credit_balance` is a VIEW over the ledger | v | v | ✔ |
| C11 | `get_revenue_summary` accrual == Σ(snapshot `counts_as_revenue`) | match | 44234 = 44234 | ✔ |
| C12 | `record_quick_sale` dup idempotency key ⇒ 1 payment, replayed | 1 & replayed | pmts=1 replayed=true | ✔ |
| C13 | `record_payment` dup idempotency key ⇒ 1 row, same id | 1 & same | pmts=1 same=true | ✔ |

Controls that failed as designed: **C5a→C5b** (first earn inserts fine, the *second* is rejected — proving the unique index isn't just refusing all inserts); **C3** re-tested deterministically after the identical-`created_at` artifact was caught.

**Part C: 0 failures.**

---

## PART D — §7 AUTH / PERMISSION (DB layer)

| id | assertion | expected | actual | pass |
|----|-----------|----------|--------|:----:|
| D1 | stylist calls `set_sale_policy` (owner-only) | deny | blocked | ✔ `only an owner may change sale accounting policy` |
| D2 | stylist calls `reclassify_sale_policy` (owner-only) | deny | blocked | ✔ `only an owner may reclassify a historical sale` |
| D3 | stylist reads own-tenant **payments** | 0/deny | denied | ✔ RLS `view_finance` owner/manager only |
| D3-ctrl | **control:** owner-A DOES read own payments | ≥1 | 2 | ✔ (proves D3 not vacuous) |
| D4 | stylist reads own-tenant **expenses** | 0/deny | denied | ✔ |
| D5 | anon reads payments/sales/expenses/cash_drawer | 0 exposed | 0 (all denied) | ✔ |
| D6 | `authenticated` has NO TRUNCATE on sales | false | false | ✔ v11c |
| D6 | `authenticated` has NO TRUNCATE on payments | false | false | ✔ v11c |
| D6 | `authenticated` has NO TRUNCATE on credit_ledger | false | false | ✔ v11c |

**Part D: 0 failures.**

---

## DEVIATIONS (the only 2 failures) — severity & fix

Both are the *same* root cause: three FK columns are plain `REFERENCES <tbl>(id)` instead of composite `(child_id, business_id) REFERENCES <tbl>(id, business_id)`. The composite pattern **is** already used on `payments` (`payments_sale_same_tenant`, `_client_same_tenant`, `_staff_same_tenant`, `_branch_same_tenant`) and on `sales_branch_fk` / `sales_staff_fk` — but not on:

- `sales_client_id_fkey` → `clients(id)`  (⇒ **A-own-08**)
- `appointments_service_id_fkey` → `services(id)`  (⇒ **A-own-11**)
- (`sales_appointment_id_fkey` → `appointments(id)` has the same shape — not exercised here but should be fixed together.)

**What actually happens:** a member of tenant A, with legitimate `create_sales`, can insert a row **into A's own partition** (`business_id = A`) whose `client_id`/`service_id` points at a UUID owned by tenant B. RLS (`sales_insert` = `has_perm(A,'create_sales')`) passes because the row is A's; the simple FK doesn't check tenancy.

**Why this is P2, not P0/P1:**
- **No confidentiality breach** — A cannot *read* any B row (all A-own-01..06, STAFF/ANON/ROTA reads = 0). The reference is an opaque UUID A already supplied.
- **No write into B's data** — `business_id` stays A; B's `clients`/`services` rows are untouched (contrast A-own-09, which is correctly RLS-blocked).
- **No practical enumeration oracle** — client/service IDs are random UUIDv4; insert-succeeds-iff-exists is not exploitable at UUIDv4 entropy.
- Impact is *data hygiene / referential integrity*: A can create dangling cross-tenant references and loyalty side-effects (points/credit) keyed to a foreign `client_id` **inside A's own tenant**.

**Recommended fix (own-code, additive; verify with a rolled-back chain test first):**
```sql
-- requires clients_id_business_uk (id,business_id) [exists] and services (id,business_id) unique
alter table sales        drop constraint sales_client_id_fkey,
  add constraint sales_client_same_tenant       foreign key (client_id, business_id)      references clients(id, business_id);
alter table appointments drop constraint appointments_service_id_fkey,
  add constraint appointments_service_same_tenant foreign key (service_id, business_id)   references services(id, business_id);
-- and mirror for sales_appointment_id_fkey (appointment_id, business_id)->appointments(id,business_id)
```
(Needs a `services (id, business_id)` unique index — add if absent. This is the same hardening already applied to `payments`/`branch`/`staff`.)

---

## HARD-CONSTRAINT CONFIRMATION

- **Nothing applied / deployed / committed / migrated.** No `apply_migration` call was made. Every test ran inside `begin … rollback`; QA tenants and all writes were rolled back.
- **`kopi tiam` untouched; no rows added to `QA Test Cafe`.** QA tenants were fresh in-transaction businesses (`zzz-qa-gate-a/b`).
- **Production row counts unchanged (post-gate re-count):** businesses=2, sales=6, clients=5, staff=2, payments=0, points_ledger=4, credit_ledger=3, gift_cards=1, referrals=1, sale_policies=0, auth.users=2 — identical to the pre-gate baseline.

## GATE TALLY

- Assertions executed: **51** (incl. 4 controls + the CANARY falsifiability control).
- **PASS: 49 · FAIL: 2 (both P2, tenant-isolation referential integrity) · P0/P1: 0.**
- Parts B (policy-snapshot P0), C (financial/loyalty), D (auth) — **0 failures each.**
