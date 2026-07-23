# F2 value-write hardening — independent review verdict

**Reviewer independence.** I did not author any F2 artifact (the v54 migration, the app
rewiring, the test suites, or the registry reconciliation). I have no stake in F2 passing.
This verdict stands in for the owner's independent-reviewer ("Sol") gate under the A6 process
and is grounded in the committed artifacts and the real schema under `supabase/migrations/*.sql`,
verified by reading the code, re-deriving the count/atomicity logic, and running the gate myself.

- **Final commit reviewed:** `09b8e37b0208278ca5ada9332a097ad277efcd69`
  (branch `codex/phase0-transaction-foundation`, HEAD; parent `7208a15`; working tree clean).
- **Prior review commit:** `7208a15a1de7653044db4bf8b868b58c8f2fc101` (round 1 — CHANGES REQUIRED).
- **Date:** 2026-07-23.
- **Runtime division:** I cannot run `psql`, so I verified the v54 SQL suite and migration by
  reading, and I **rely on the coordinator's local rehearsal for runtime evidence** (expanded
  v54 suite PASS, full matrix 47/47, DB pristine) — that division is per house process.
  Everything runnable from Node I ran: discovery (deterministic), the PS-0 suites, and the full
  `validate` gate (exit 0).

## Round-2 verification (commit `09b8e37`, delta vs `7208a15` = exactly 3 files)

Diff scope confirmed: `db/tests/v54_f2_write_hardening.sql` (+183), `writer-registry.json`
(prose only), and my round-1 `F2_REVIEW_VERDICT.md` now committed. No production code, migration,
or app change — this round is test + doc only.

1. **Four failure-injection cases — CLOSED (F2-1).** A surgical trigger (raises only for a marker
   GUC `f2.inject_key`) is installed, the RPC is called inside a nested `BEGIN/EXCEPTION`, then
   the trigger and its function are dropped and a normal call is proven to succeed:
   - **A1/A2** fail the **audit_log** insert inside `create_expense` / `receive_stock`.
   - **B1/B2** fail the **`f2_write_operations`** insert **after** the value row *and* the audit
     row are already written — the stronger atomicity exercise. Each of the four asserts (a) the
     error surfaced (`v_raised`), and (b) **zero persisted rows across expenses / stock_batches /
     audit_log / f2_write_operations** (baseline-count equality). Post-injection recovery is
     proven (+1 expense, +1 batch, +2 op rows after both triggers are dropped); both injection
     functions are dropped before `rollback`. Fresh random keys per case avoid advisory-lock
     contention; the transaction-local GUC survives the in-RPC role change. This proves the
     "atomic, no partial record on failure" bullet **behaviorally**, not just structurally.
2. **Payments `+0` — CLOSED.** A `v_pay_base` baseline is captured at seed, and a `+0` assertion
   fires after **both** the expense/receiving section and the package/membership `/4` section.
   I verified the claim against the migration bodies: **neither `sell_package` (v10 `/3`, v51a
   `/4`) nor `enroll_membership_v41` (v5 `/3`, v41, v51a `/4`) inserts into `public.payments`** —
   the `+0` delta is true, not assumed.
3. **N2 registry prose — CLOSED; machine fields untouched.** The hard-finding, `callers`, and
   `kernel` prose are now past-tense and accurate ("was granted", "has been migrated to the
   4-arg overload (now app/index.html:6581)", "no browser caller of /3 remains"). I diffed the
   machine fields against the parent: `counts` byte-equal, the writer+allowlist id set byte-equal,
   `hard_findings` count unchanged (3). `ps0-writer-registry` passes (0 missing / 0 stale,
   deterministic).
4. **N1 delta-count — on record.** My round-1 verdict, now committed at this SHA, records that
   the F2 delta was **21 files, not 18**, with all 21 classified F2-scoped.
5. **Full gate re-run — green.** `EXPECTED_SUPABASE_PROJECT_REF=gadpooereceldfpfxsod npm run
   validate` → exit 0 (449 tests, 0 fail, static build). `ps0-no-executor` green; no executor
   artifact in the delta.
6. **Structural guards intact; no coverage lost.** The suite still has exactly one `begin;`
   (l.23) and one `rollback;` (l.673) and **no `commit;`** — the injection functions/triggers
   live and die inside that single rolled-back transaction. The only line the diff removes is a
   `declare` extension (`v_n int; v_qty int;` → adds `v_pay_base int;`); everything else is
   purely additive, so no prior assertion was dropped.

---

## Per-requirement table (A1–A6) — final

| Req | Requirement | Result | Evidence |
|-----|-------------|--------|----------|
| **A1** | Packages → keyed idempotent 4-arg; /3 revoked | **PASS** | Standalone UI (`:6581`) 4-arg; cart (`:4113`) already 4-arg; live v51a signature confirmed; v54 revokes /3 from public/anon/authenticated; sole survivor = SECURITY DEFINER /4 wrapper; no 3-arg browser caller remains. |
| **A2** | Memberships → keyed idempotent 4-arg; /3 revoked | **PASS** | Standalone UI (`:5841`) 4-arg; cart (`:4115`) already 4-arg; /3 revoked; /4 SECURITY DEFINER. |
| **A1/A2 key lifecycle** | One stable key/attempt, reused on retry, regenerated only on deliberate change/settlement; survives full re-render; not resting on button-disabling | **PASS** | `writeAttemptKey`/`clearWriteAttempt` over sessionStorage; `isReplayResult` keys only off explicit sentinels; 23505/40001 conflict handling honest; button-disable is UI polish only. |
| **A3** | `create_expense` meets every owner bullet; direct-write boundary closed | **PASS** | actor from auth; staff+expenses-module+view_finance gate; branch tenancy; payload validation; atomic value+audit+op (now **injection-proven**, F2-1 A1/B1); exact replay; changed-payload 23505; boundary FOR ALL→SELECT-only + revoke IUD; `run_expense_recurrences` (definer) unaffected. |
| **A4** | `receive_stock` meets every applicable bullet; boundary closed; schema-honest | **PASS** | same shape; product-ownership cross-tenant gate (no business_id); qty/date/expiry validation; atomic (injection-proven, F2-1 A2/B2); schema-honesty on inapplicable unit-cost/batch/branch + no inventory-ledger scope creep; boundary closed; internal writers (all definer) unaffected. |
| **A5** | Full A5 matrix with exact final counts; 4 suites strengthened | **PASS** | Success/replay/changed-payload/malformed/unauthorized/wrong-branch/cross-tenant/inactive-user/direct-insert-denied/internal-writers, exact counts on expenses/stock_batches/sales/client_packages/memberships/membership-credit/**payments**/audit/op with zero-duplicate-effects; **four failure-injection cases** (audit + op-ledger-after-value+audit); four pre-existing suites correctly encode the hardened /3-revoked-/4-works contract (incl. PUBLIC via `aclexplode`) with no coverage lost. |
| **A5 concurrency note** | Single-connection limitation judged | **SUFFICIENT** | Advisory lock + `UNIQUE(business_id, idempotency_key)` (same as proven v41/v51a); §16 asserts the UNIQUE backstop directly; optional `.sh` harness is a fair, non-blocking follow-up. |
| **A6** | Gates: validate / diff --check / secret scan / no executor | **PASS** | validate exit 0 (449/0 + build); diff --check clean; secret scan over the delta clean; no-executor 4/4; zero PS executor artifacts. |
| **Registry** | Exhaustive against this tree; prose current | **PASS** | deterministic; 7/7 (0 missing/0 stale); new RPC writers curated; browser-direct writes gone; /3 EXECUTE-REVOKED; op-ledger non-value; prose now past-tense; machine fields byte-identical to parent. |

---

## Findings

All round-1 findings are **CLOSED**:

- **F2-1 (was MEDIUM — the blocker): CLOSED.** The v54 suite now exercises db-failure-injection
  and audit-failure across four cases (audit-insert failure and the stronger op-ledger-insert-
  after-value+audit failure, for both RPCs), each asserting the surfaced error and zero persisted
  rows in all four tables, with recovery proven and artifacts dropped; the `payments +0`
  assertions are present for both sections and true against the migration bodies.
- **N2 (was cosmetic): CLOSED.** Registry prose is past-tense and accurate; machine fields
  untouched.
- **N1 (was NOTE): on record.** The committed round-1 verdict documents the 21-vs-18 count with
  all files classified F2-scoped.
- **Recommended (non-blocking, unchanged):** deliver `v54_..._concurrency.sh` for parity with the
  v41/v51a concurrency harnesses, as the suite itself flags. Not required for acceptance.

No new defects were introduced by this commit: it is test + documentation only; production code,
the migration body, and the app are unchanged from `7208a15`; the structural guards hold and no
prior coverage was lost.

---

## OVERALL VERDICT: **PASS**

Every F2 requirement (A1–A6) is met on commit `09b8e37b0208278ca5ada9332a097ad277efcd69`, and
there are zero open blocking findings. All four pre-existing value-write hazards are genuinely
closed at both the DB and app layers; the two new RPCs are keyed, authorized, validated, and
**behaviorally proven atomic** (a mid-transaction failure of either the audit insert or the final
op-ledger insert persists nothing across all four tables, and normal operation recovers); the
direct-write boundaries are closed with SELECT preserved and every internal SECURITY DEFINER
writer verified unaffected; the four strengthened suites encode the hardened contract without
losing coverage; the writer registry is exhaustive and its prose current; and the full A6 gate is
green with no executor artifacts, no secrets, a clean diff, and intact structural guards.

Per the owner's A6 process, F2 is accepted: the coordinator may apply v54 to the UAT project and
deploy the frontend. (Production apply remains gated by the `RELEASE APPROVED` phrase in
`CLAUDE.md`, and no Program Studio executor phase is authorized by this work.)

I did not modify any file other than this verdict, and I did not commit.

---

## Review history

- **Round 1 — commit `7208a15…`: CHANGES REQUIRED.** All requirements substantively met and the
  four hazards genuinely closed, but the v54 suite omitted the owner-enumerated
  **db-failure-injection** and **audit-failure** cases and a `payments` count assertion
  (**F2-1**, MEDIUM). Notes: **N1** (delta was 21 files, not 18 — all F2-scoped), **N2**
  (registry prose described the completed app migration in future tense). Required-to-pass: F2-1.
- **Round 2 (final) — commit `09b8e37…`: PASS.** F2-1 closed with four failure-injection cases
  (audit + op-ledger-after-value+audit, both RPCs, zero-row + recovery + artifact-drop
  assertions) and `payments +0` for both sections (verified true against the migration bodies);
  N2 prose refreshed to past tense with machine fields byte-identical; N1 on record. Structural
  guards intact (one begin/rollback, no commit), no prior coverage lost, gate green (449/0 +
  build), no executor artifacts, clean diff, secret scan clean.
