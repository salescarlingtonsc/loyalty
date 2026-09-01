# Customer Intelligence — re-assessment after the P0 wave and first corpus

**Branch:** `claude/ci-proof-100` · **Base:** `origin/main` @ `3414eb78`
**Date:** 2026-09-01 · **Nothing deployed.** No production migration applied, no production data
touched, shadow period not begun.

Supersedes the score in `CI-PROOF-BASELINE-2026-09-01.md`. The baseline document remains valid as
the frozen starting record.

---

## 1. Revised score — six numbers, never merged

| Status | Count | Meaning |
|---|---:|---|
| **Proven** (`BUILT_AND_EXECUTED`) | **12** | A named assertion executes the code it covers, and mutation-checking confirms the assertion can fail. Was 1. |
| Implemented but unproven | 3 | Real code, no executing test. Was 12. |
| Partially implemented | 34 | Some sub-requirements met. Was 37. |
| Absent | 47 | Not implemented. Was 50. |
| **Confirmed defective** | **2** | Executable evidence that the capability produces a wrong or misleading result. New category — these are worse than absent, because they answer. |
| Proof written but blocked | 2 | The fixture exists and is correct; a separate defect prevents it executing. |

Total 100. **Proof coverage: 12/100.** **Functional coverage: 53/100** — the checks where a
capability is at least partly present (12 + 3 + 34 + 2 + 2). Report both, and never average them:
functional coverage counts 34 incomplete implementations and 2 that are actively wrong.

### The 12 proven

| Check | Proved by | Assertion |
|---:|---|---|
| 12 numerator and denominator | `v667-consultative-payload.test.mjs` | rate renders `25.0% (10/40)` |
| 14 comparison baseline | `v550-recovery-report.test.mjs` | *(pre-existing)* |
| 47 overdue vs approaching | `v651_corpus_cadence.sql` | `C3` due ≠ overdue |
| 48 risk is own-rhythm-relative | `v651_corpus_cadence.sql` | `C2` A overdue, B within cycle at identical 20-day absence |
| 59 acquisition authority | `v629_corpus_acquisition_demographics.sql` | `A1`–`A4` |
| 62 three-of-three trap | `v652_corpus_statistics.sql` | `S2` 3/3 vs 0/3 → `insufficient` |
| 64 effect size travels | `v652_corpus_statistics.sql` | `S4` exact 20.0pp, relative 1.67 |
| 92 UI/RPC contract validation | `v667-consultative-payload.test.mjs` | every key read is a key emitted |
| 93 consultant defect closure | `v667-consultative-payload.test.mjs` | 0/8 → 8/8 |
| 94 tenant isolation | `v667_ci_access_boundaries.sql` | `B2` |
| 95 branch isolation | `v667_ci_access_boundaries.sql` | `B4` exact 25000 vs 34000, `B5` foreign branch refused |
| 96 small-cell protection | `v667_ci_access_boundaries.sql` | `B6`/`B7` |

Two fixture files carry an additional **deliberately red** assertion documenting a defect
(D2, D3 below). Their other assertions pass and are counted above; the files are red on purpose.

---

## 2. Ranked defect list

Ranked by whether a user could be misled today, then by blast radius.

### D1 — An owner ruling was never actually applied · **P0, latent**

`nestly_v523` (owner ruling 2026-08-26) put Customer Intelligence back on normal entitlement and
removed the hand-placed override so the module would "resolve exactly like every other one". It
removed it from `app.staff_module_perms_at_v115` — but **not** from
`app.effective_platform_module_mode_v94`, which still answers `'disabled'` /
`'global_platform_only_policy'`. `nestly_v537` then re-pointed the capability gate at that
resolver.

*Verified by probe against the migrated cluster:* with `customerintel` present in
`enabled_modules` and `has_perm(view_finance)` true, `app.can_module(b,'customerintel')` is still
**false**.

Consequences: the whole module is unreachable, and because `nestly_v573` gated
`public.get_revenue_truth_v106` on that module, **revenue truth is unreachable for every merchant
role** — only a super admin can call it.

Blast radius **today is contained**: the RPC's only caller is `customerIntelligencePage`, whose
route is gated on the same disabled module, so nothing user-visible is broken. Both unlock
together the moment v523 is completed. Not fixed here — completing it changes what merchants can
see and is an owner decision.

**Also requires an owner decision:** `docs/product/PRODUCT-TRUTH.md:228` (2026-08-02) still calls
Customer Intelligence platform-only and directly contradicts v523 (2026-08-26). One of the two
must be corrected, or the next reader will make the same mistake I did.

### D2 — A confidence interval returns a mathematically impossible bound · **P0, misleading output**

`app.evidence_block_v1` at 9/10 vs 1/10 — n=10 per arm, which **clears** the default `p_min_arm`
floor of 10 — returns `[53.7, 106.3]` percentage points. The legal range for a difference between
two rates is `[-100, 100]`.

Hand-verified: diff 80.0pp, se 0.13416, 80 ± 1.96 × 13.416 = [53.7, 106.3].

Cause: an unadjusted normal-approximation (Wald) interval. A Wilson or Agresti-Coull interval is
bounded by construction. The `p_max_verdict` ceiling does not help — it governs the verdict *word*,
not the numeric bounds. Held red by `v652_corpus_statistics.sql` assertion `S6b`.

### D3 — A single-visit customer is given a measured-looking rhythm of zero · **P1, misleading output**

`app.customer_cadence_v1` line 170 does
`round(coalesce(v_row.median_interval_days, 0)::numeric, 1)`. The batch function correctly returns
NULL when a customer has zero measured intervals; the wrapper turns it into `0.0`, which reads as
"visits every 0 days". The true zero-visit case is handled correctly (`status='insufficient'`), so
the one-visit case is an inconsistency as well as a fabrication. Held red by
`v651_corpus_cadence.sql` assertion `C6`.

### D4 — 15 executed tests fail once the migration chain applies · **P1, process**

Including `v422_baseline_behaviours.sql`, the file the harness's own header designates the
regression floor. Green only because the chain stopped at v599. Left failing deliberately; most
appear to be fixtures predating the v625 Google-SSO rule. Detail in
`audit-artifacts/v667-suite-delta-2026-09-01.md`.

### D5 — No business-wide demographic coverage exists · **P2, absence**

`app.customer_demographics_v1` is a single-customer lookup with no aggregate anywhere. No function
reports "% of customers with a birth date on file". Checks 31–34 stay ABSENT. The migration
filename `v638_demographics_authority` oversold it; the original assessment was right.

### Closed this wave

| Was | Now |
|---|---|
| CI RPCs refused the assigned consultant and super admin | Fixed — platform arm added to the gate |
| Branch isolation absent from all six readers | Fixed — `p_branch`, validated, refused where the dimension does not exist |
| Small cohorts disclosed customer names | Fixed — k=5 floor, identities withheld, count still travels |
| Consultant brief rendered fallback zeros | Fixed — reads the emitted keys; rate shows its counts |
| The harness never reached the intelligence layer | Fixed — chain applies through v665 |

---

## 3. A correction I have to record against myself

The first cut of v667 **refused a firm owner**, citing `PRODUCT-TRUTH.md:228`. That document line
predates the owner's v523 ruling by 24 days. I read the older document as current and encoded it
in both a migration and a test. Had it shipped, it would have overruled an owner — a worse outcome
than the defect it was meant to fix.

It was caught because a corpus fixture, written to a *different* purpose, called
`get_revenue_truth_v106` as an owner and failed. Chasing why produced the probe that produced D1.

Two things follow. First, the mandate's framing of P0-1 as "authorization is too broad" came from
my baseline and was half wrong; the half that stands is that the gate was too **narrow**, refusing
the consultant and super admin. Second, a documentation line is not an authority — the newest
owner ruling is, and where the two disagree the disagreement itself is the finding.

---

## 4. Expected versus actual

Every corpus fixture states its truth table as a comment before any assertion runs, and asserts
exact equality. Representative values:

| Fixture | Expected | Actual |
|---|---|---|
| `v106_corpus` R1 | identified 15000 + anonymous 5000 = known 20000; 3 + 2 = 5 txns | blocked by D1 |
| `v106_corpus` R3 | 6100 with refund outside window; 0 with it inside | blocked by D1 |
| `v629_corpus` A4 | 10 non-synthetic clients; campaign bucket exactly 1 | 10 / 1 ✓ |
| `v651_corpus` C1 | gaps 7,8,9,10 → median 8.5, observations 4 | 8.5 / 4 ✓ |
| `v651_corpus` C2 | A overdue, B within_cycle at identical 20-day absence | ✓ |
| `v651_corpus` C6 | one visit → no median | **0.0** ✗ (D3) |
| `v652_corpus` S4 | 50% vs 30% → 20.0pp, relative 1.67 | ✓ |
| `v652_corpus` S6b | interval bounds within [-100, 100] | **[53.7, 106.3]** ✗ (D2) |
| `v667` B4 | branch A1 25000, firm-wide 34000 | ✓ |

---

## 5. Against the owner's stated acceptance target

| Target | Status |
|---|---|
| Zero known access-boundary failures | **Not met.** Boundaries proven for tenant, branch and small cell; D1 leaves an owner ruling unapplied and revenue truth merchant-unreachable |
| Zero fabricated or misleading outputs | **Not met.** D2 and D3 are both confirmed, with executable evidence |
| All implemented capabilities covered by deterministic tests | **Partial.** 12 proven, 3 unproven, 34 partial; 2 fixtures blocked by D1 |
| A trustworthy revised baseline | **Met**, with the correction in §3 on the record |

The gap to the target is now four named defects, not an unknown. D1 and the PRODUCT-TRUTH conflict
need an owner decision before anything else moves.

---

# Addendum — closure wave of 2026-09-01 (v667/v668/v669)

Written after the owner's "proceed" directive. Branch `claude/ci-proof-100`, rebuilt on
`origin/main` @ `f31f5fe3` after an upstream `nestly_v666` name-and-slot collision forced a
renumber (v666 → v667; old tip preserved at `archive/ci-proof-pre-renumber`).

## Revised score

| Status | Count | Δ |
|---|---:|---:|
| **Proven** | **17** | +5 |
| Implemented but unproven | 3 | — |
| Partially implemented | 33 | −1 |
| Confirmed defective | **0** | −2 |
| Proof written but blocked | **0** | −2 |
| Absent | 47 | — |

**Proof coverage 17/100 · functional coverage 53/100.** Newly proven: checks 3 and 5
(identified/anonymous reconciliation and refund/reversal correctness — unblocked when D1 fell),
6 and 7 (package-once revenue, zero-value visits), and 63 (bounded uncertainty intervals).
Check 45 moves from *defective* to *partial*: the fabricated `0.0` median is gone; dispersion is
still not computed.

## Defect ledger

| # | Was | Now |
|---|---|---|
| D1 owner ruling unapplied | P0 latent | **Closed** — v668 removes the surviving short-circuit, proves its own minimality via a `pg_get_functiondef` before/after equality, and `PRODUCT-TRUTH.md:228` now states the v523 rule. All six revenue-truth proofs unblocked, in both harness phases. |
| D2 impossible interval | P0 | **Closed** — v669 replaces Wald with the Newcombe hybrid Wilson interval, bounded by construction. `[53.7, 106.3]` → `[37.0, 91.6]` on the same inputs. The three Wald-pinned corpus values were re-pinned to independently hand-computed Newcombe values (matched live output to 0.1pp). |
| D3 zero-day rhythm | P1 | **Closed** — v669 emits null for a single-visit customer's median; no callers assumed otherwise. |
| D4 chain-exposure failures | P1 process | **Resolved** — 14 of 15 were fixtures predating v620 (paid-subscription requirement) or v625 (Google-SSO platform sessions); repaired without touching any assertion (all 23 removed lines are bare-claims `set_config`s replaced by their Google-claims form). The 15th became D6. The regression floor passes in both phases again. |
| D5 no demographic coverage | P2 | Open — unchanged; awaits the analytics build phase. |
| **D6 sessionless drain path broken by v625** | **new, P1** | Open, held red by `v552_gated_evidence_isolation`. `app.v176_gated_evidence`'s cron-path impersonation sets only `sub`/`role`/`aud`, which can never satisfy post-v625 `is_super_admin()`, so every background consultative-evidence call fails 42501. The fix is an auth-design decision — a dedicated internal authority, not a wider Google exemption — left for review. |

**For an owner call, not a defect:** `app.v32_customer_wallet_context` still inlines its own
`customerintel → disabled` clause on the *customer wallet* path. Removing it changes
customer-visible payload while unlocking nothing a wallet uses, so v668 left it alone.

## Suite state

Full executed suite: **25 failures → 8.** The remaining eight are the six files plus the
concurrency lane that already failed on *unmodified* `origin/main`, plus v552 (D6, held red
deliberately). This branch introduces zero failures of its own.

## Against the owner's acceptance target — updated

| Target | Status |
|---|---|
| Zero known access-boundary failures | **Met on this branch.** Tenant, branch, small-cell and entitlement boundaries all proven by executing tests; the v523 ruling is now actually in force. |
| Zero fabricated or misleading outputs | **Met for every confirmed case.** D2 and D3 fixed and proven; the consultant-brief zeros fixed in the v667 wave. D6 is an *availability* failure (fail-closed), not a misleading output. |
| All implemented capabilities covered by deterministic tests | **Partial** — 17 proven; 3 unproven; 33 partial. The corpus now covers revenue truth, cadence, acquisition, statistics and access boundaries end to end. |
| A trustworthy revised baseline | **Met.** |

Remaining before the shadow window: Sol review of this branch, an owner ruling on D6 and the
wallet-context clause, and the shadow window's own start/duration/method/stop definition.
