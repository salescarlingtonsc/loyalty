# F2 value-write hardening — independent review verdict

**Reviewer independence.** I did not author any F2 artifact (the v54 migration, the app
rewiring, the test suites, or the registry reconciliation). I have no stake in F2 passing.
This verdict stands in for the owner's independent-reviewer ("Sol") gate under the A6 process
and is grounded in the committed artifacts and the real schema under `supabase/migrations/*.sql`,
verified by reading the code, re-deriving the exact-count logic, and running the gate myself —
not by trusting the commit message.

- **Commit reviewed:** `7208a15a1de7653044db4bf8b868b58c8f2fc101`
  (branch `codex/phase0-transaction-foundation`, HEAD; parent `3b26550`; working tree clean
  apart from this verdict file).
- **Date:** 2026-07-23.
- **Runtime division:** I cannot run `psql`, so I verified the v54 SQL suite and the migration
  by reading, and I **rely on the coordinator's local rehearsal for runtime evidence**
  (chain 88/88 apply, v54 suite PASS, full matrix 47/47, DB pristine) — that division is per
  house process. Everything runnable from Node I ran: discovery (deterministic), the PS-0 test
  suites, and the full `validate` gate.

---

## Per-requirement table (A1–A6)

| Req | Requirement | Result | Evidence |
|-----|-------------|--------|----------|
| **A1** | Packages → keyed idempotent 4-arg; /3 revoked | **PASS** | Standalone Packages UI (`app/index.html:6581`) now calls `sell_package` 4-arg with `p_idempotency_key`; the cart path (`:4113`) already passed a per-line key. Live 4-arg signature confirmed in v51a (`sell_package(business,client,plan,idempotency_key)`). v54 `revoke execute on public.sell_package(uuid,uuid,uuid) from public, anon, authenticated`. Repo-wide grep: **no 3-arg browser caller remains**; sole survivor is the /4 wrapper's internal delegation, and /4 is **SECURITY DEFINER** (v51a l.73), so it calls /3 as owner — unaffected. |
| **A2** | Memberships → keyed idempotent 4-arg; /3 revoked | **PASS** | Standalone Memberships UI (`:5841`) now calls `enroll_membership_v41` 4-arg; cart (`:4115`) already 4-arg. v54 revokes /3 from public/anon/authenticated; /4 is SECURITY DEFINER (v51a l.138). Same "sole survivor = /4 wrapper" verification. |
| **A1/A2 key lifecycle** | One stable key per logical attempt, reused on retry, regenerated only on deliberate change/settlement; survives full re-render; not resting on button-disabling | **PASS** | `writeAttemptKey(slot,fingerprint)` mints one uuid per (slot,fingerprint) in **sessionStorage** (survives page-function re-invocation, unlike a page `let`), reuses it verbatim on double-tap/timeout/lost-response/rerender/reconnect, and regenerates only when the fingerprint changes; `clearWriteAttempt` fires on success and on same-key/different-payload conflict. `isReplayResult` keys only off explicit sentinels (`replayed`/`already_recorded`/`status in (duplicate_ignored,replayed)`), never the bare `status` (membership status is `active`). Comment and code confirm button-disabling is UI polish; the server dedupes on the key. Conflict handling (23505/40001) is honest. |
| **A3** | `create_expense` meets every owner bullet; direct-write boundary closed | **PASS** | Actor `auth.uid()` (42501 if null); active-staff-of-this-business + `can_module_write('expenses')` + `has_perm('view_finance')` gate; branch tenancy validated when non-null; category/amount/supplier/description/note/date-window validation (fail-closed); **value + audit + op-ledger all in one function body = one txn** (no partial path); exact replay → `duplicate_ignored` cached id; changed-payload → 23505; distinct errcodes. Boundary: `expenses_all` FOR ALL → `expenses_select` (identical `view_finance` USING) + `revoke insert,update,delete`; SELECT preserved; internal `run_expense_recurrences` is SECURITY DEFINER → unaffected (verified). |
| **A4** | `receive_stock` meets every applicable bullet; boundary closed; schema-honest | **PASS** | Same shape; cross-tenant gate rides **product ownership** (stock_batches has no `business_id`); qty/date-window/expiry-after-received validation; atomic batch+audit+op; replay/conflict. Migration is explicitly honest that unit-cost/batch-ref/branch validations are **inapplicable to the real table** and that a full inventory-movement ledger is **out of F2 scope** — no scope creep. Boundary: `stock_batches_all` → `stock_batches_select` (identical product/`can_module` USING) + `revoke insert,update,delete`; internal writers `on_sale_stock_deduct`/`on_appointment_completed`/`commit_import_job` all SECURITY DEFINER → unaffected (verified). |
| **A5** | Full A5 matrix with exact final counts; 4 pre-existing suites strengthened | **CHANGES REQUIRED** | `v54_f2_write_hardening.sql` covers success, exact-replay (= timeout/lost-response/double-click retry), changed-payload (23505), malformed (22023 ×8), unauthorized (42501), wrong-branch (22023), cross-tenant product+business (22023/42501), inactive-user (42501), /3-now-42501 (authenticated **and** anon), direct-insert-denied, internal-writers-still-work, and **exact final counts** on expenses/stock_batches/sales/client_packages/memberships/membership-credit/audit/op rows with **zero-duplicate-effects**. The four strengthened suites correctly invert the old "/3 works" contract to "/3 revoked, /4 works via definer delegation" (v51a) and add explicit ACL assertions incl. the PUBLIC (`aclexplode` grantee 0) case (v41 ×2), and v20 moves to the 4-arg call — **no unrelated coverage lost**. **Gaps vs the owner's enumerated A5 list → finding F2-1:** no explicit **db-failure-injection** and no **audit-failure** case (the "atomic, no partial on failure" bullet is proven only structurally, not behaviorally), and **no `payments` exact-count** assertion. |
| **A5 concurrency note** | Single-connection limitation judged | **SUFFICIENT (for acceptance)** | A single psql connection genuinely cannot fork two transactions. Idempotency rests on the in-RPC `pg_advisory_xact_lock(business,key)` **and** `UNIQUE(business_id, idempotency_key)` — the exact structure the live v41/v51a `.sh` harnesses already prove under real parallelism; §16 asserts the UNIQUE backstop directly. Structural proof + the suite's own "optional `.sh` follow-up" is an honest, adequate position; delivering that harness for parity is a recommended (not blocking) follow-up. |
| **A6** | Gates: validate / diff --check / secret scan / no executor | **PASS** | `EXPECTED_SUPABASE_PROJECT_REF=gadpooereceldfpfxsod npm run validate` → exit 0 (449 tests, 0 fail, static build). `git diff --check` clean. Secret scan over the full delta clean. `ps0-no-executor` 4/4; **no** Program-Studio executor artifact (`program_rules`/`benefit_*`/`event_outbox`/`domain_events`/`budget_periods`/`sv_*`/`studio_executor`) anywhere in v54 or the delta. |
| **Registry** | Exhaustive against this tree | **PASS** | `discover-writers.mjs` deterministic; `ps0-writer-registry` 7/7 (0 missing / 0 stale). New writers `db.fn:public.create_expense/9` and `receive_stock/6` curated; the two browser-direct `expenses`/`stock_batches` writes are **gone**; both /3 overloads marked `EXECUTE-REVOKED by v54`; the op-ledger `f2_write_operations` correctly classified non-value. Hard findings retained with honest `[DB-CLOSED by v54: …]` annotations. |

---

## Findings

### MEDIUM — F2-1 (the required change): the v54 suite omits two owner-enumerated A5 cases

The owner's A5 matrix explicitly includes **db-failure-injection** and **audit-failure**, and
the "atomic expense+audit / no partial record on failure" bullet (A3/A4). `create_expense` and
`receive_stock` guarantee atomicity **structurally** — the value insert, the `audit_log` insert,
and the `f2_write_operations` insert all live in one `plpgsql` function body, so a downstream
failure rolls the whole RPC transaction back and no partial record is possible. But the suite
**never exercises a failure between the value write and the audit/op write** — every failure it
tests is an input/authz/conflict rejection that fires **before** any write. So the "no partial on
failure" property is asserted only by construction, not behaviorally. The suite also asserts no
`payments` count (the owner's count list names it; it is `+0` for these ops, so an explicit
`+0` assertion would complete the list).

*Fix (additive test cases in the existing rollback harness — no production-code change):*
1. **db-failure-injection / audit-failure:** inside the suite, create a temporary trigger on
   `audit_log` (or `f2_write_operations`) that raises, call `create_expense` (and
   `receive_stock`) inside `expect_state`, and assert the `expenses`/`stock_batches` **and**
   `f2_write_operations` counts are unchanged — proving the atomic rollback behaviorally for
   both RPCs. Drop the temp trigger and confirm the next call succeeds.
2. Add the `payments` exact-count (`+0`) assertion to the success sections to complete the
   owner's named count list.

### LOW / NOTE

- **N1 — file count.** The delta is **21 files**, not the "18" stated by the coordinator. I
  classified all 21 and every one is F2-scoped (app call sites; the v54 migration in both the
  `db/` and `supabase/` trees; the v54 suite + four strengthened suites; the writer registry +
  discovery script; six migration-order manifest/plan/sha256 bookkeeping files across both trees
  + the materialize script; four phase0/security node tests that register v54 and extend the
  RPC-allowlist coverage to the new RPCs). Scope integrity holds — nothing unrelated, no executor
  work, no secrets — but the stated count is wrong; reconcile it in the change record.
- **N2 — registry prose freshness.** The retained hard-finding / `kernel` prose says the
  standalone UI 3-arg call "must be migrated to /4 by the app agent" and cites line numbers
  (`:5816`/`:6539`/`:7054`/`:6533`), but this same commit already completed that migration (the
  live call sites are 4-arg at `:5841`/`:6581`, etc.). The machine-checked exhaustiveness is
  correct; only the human-readable prose lags (reads "pending" for work that is done, with
  now-approximate line numbers). Cosmetic — tidy for audit clarity.
- **Recommended (non-blocking):** deliver `db/tests/v54_f2_write_hardening_concurrency.sh` for
  parity with the v41/v51a concurrency harnesses, as the suite itself flags.

---

## OVERALL VERDICT: **CHANGES REQUIRED**

The F2 remediation is, in substance, correct and complete: **all four pre-existing value-write
hazards are genuinely closed** at both the DB and app layers. Packages/Memberships move to the
keyed idempotent 4-arg overloads with an owner-faithful sessionStorage key lifecycle; the
non-idempotent /3 overloads are EXECUTE-revoked from every browser principal with the definer /4
wrappers verified as the sole legitimate survivors; `create_expense` and `receive_stock` are
keyed, authorized, validated, atomic, audited RPCs that meet every applicable owner bullet, with
the browser-direct write boundaries closed (SELECT-only) and all internal SECURITY DEFINER
writers verified unaffected; the four pre-existing suites are strengthened to the new contract
without losing coverage; the registry is exhaustive against this tree; and the full A6 gate is
green with no executor artifacts, no secrets, and a clean diff.

Acceptance is withheld on **one MEDIUM test-coverage gap (F2-1)**: the v54 suite does not
exercise the owner-enumerated **db-failure-injection** and **audit-failure** cases (the
"atomic, no partial on failure" property is proven only structurally, not behaviorally) and does
not assert the `payments` count. These are additive test cases in the existing rollback harness —
no production code changes, and the migration is not yet applied to UAT, so this is a
low-effort, in-flight correction rather than a rejection of the work. With F2-1's tests added
(and, ideally, N1/N2 tidied and the optional concurrency `.sh` delivered), I would return
**PASS**.

I did not modify any file other than this verdict, and I did not commit.
