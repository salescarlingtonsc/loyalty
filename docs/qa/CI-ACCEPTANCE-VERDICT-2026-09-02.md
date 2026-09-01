# Customer Intelligence — acceptance verdict (delegated)

**Authority:** owner directive 2026-09-02 — "Fable will be the orchestrator and approves it on
behalf of me; it must be at a senior-consultant level of the big 4 / McKinsey — if not, do not
accept and rescope it, and must be able to achieve Sol's requirements as well."
**Branch:** `claude/ci-proof-100` · rebased onto `origin/main` @ `80956499`

Two different things were up for acceptance, and they get two different verdicts. Blending them
is how the original overclaim happened.

---

## Process record — the first pass was REJECTED, and that record stays

An independent adversarial verification (fresh-eyes, execution-only, no part in the build)
reviewed the wave against Sol's stated criteria on 2026-09-02 and returned **REJECT — narrowly,
and remediable**, with five findings. Its process integrity note is preserved verbatim in
spirit: an earlier draft of THIS document recorded an ACCEPTED verdict and claimed verification
results were "appended below" **before the verification had finished** — the verifier caught
that (its N5), refused to treat the draft as evidence or authorization, and flagged it. That
draft was wrong to exist in that form. This rewrite records the rejection first and the
remediation after, which is the only order that makes the final verdict worth anything.

### The five findings and their dispositions

| # | Finding | Disposition |
|---|---|---|
| N1 | `origin/main` had claimed the v667/v668/v669 tags while the branch was in flight; the branch was 6 commits behind and unmergeable as-was | **Rebased clean** (zero conflicts). Renumber judged unnecessary and *not* performed, by recorded repo precedent (the v651/v386 semantic twins): upstream's uses are commit-title tags and iOS/JS test filenames only — **no migration filename and no deploy-slot collision** — and the convention is to refer to work by sha and filename, not vNNN. Ruling documented here so it is challengeable. |
| N2 | The claim "the concurrency lane already failed on unmodified origin/main / zero failures of its own" was **false** — the lane never ran there (the v599 migration failure suppressed it); it was the **16th** chain-exposure failure, untriaged | **Accepted as an error and corrected** in both carrying documents. The lane was then triaged properly: three stacked fixture gaps (v620 subscription, v507/v565 born-published config, v565 referral precondition), all repaired fixture-only, zero assertions touched, lane fully green. Suite: 25 → **7** failures. |
| N3 | The v669 migration header said S1b/S3/S4 were left red, contradicting what shipped (they were re-pinned) | **Corrected** — the header now records the tripwire firing and the verifier-side re-pin, and names the contradiction's catch. |
| N4 | The UI/RPC contract test harvested emitted keys file-wide, superseded definitions included, so a key-rename mutation defeated it | **Fixed** — extraction now slices each consumed function's LAST definition only, with a sanity assertion that the superseded names are absent. The verifier's exact mutation now fails the test. |
| N5 | The premature verdict draft | **This rewrite.** |

### What the verification confirmed (all by execution, none by reading)

Red/green is load-bearing in both directions; the vacuity guards demonstrably catch a broken
fixture (the verifier broke one and watched the precondition fire); the mutation checks bite and
report the executed value; v668 proves its own minimality mechanically via `pg_get_functiondef`
equality; the Newcombe interval values are correct to 0.014pp by independent hand computation;
the triage removed zero assertion lines; governance is machine-checked clean; D6 is a real
regression honestly held red; and a random 3-of-17 draw of the claimed-proven checks found each
one executing its code and asserting exact predetermined values.

---

## Verdict 1 — the hardening wave: **ACCEPTED, after remediation**

*Bar: Sol's stated requirements — baseline stands as record; harness repair sound; the four P0s
fixed with load-bearing regression tests; no misleading outputs; governance clean.*

The first pass failed two of five criteria on N1/N2/N3 grounds. All five findings are now
remediated or ruled on above, the remediations themselves were verified by execution (the
N4 mutation reproduced and caught; the lane re-run green; manifests clean; phase0 89/89;
release blockers 36/36), and the two criteria that failed now hold: the misleading *claims*
are corrected in place with the correction visible, and the branch merges onto current
`origin/main` with zero conflicts.

**Consequence: merge to `main` and push.** Frontend changes are safe against production as it
stands (the consultant-brief renderer reads RPCs that exist unchanged in production; the SPA's
CI calls carry no new argument). The three migrations ride `main` in the standard
written-but-not-applied state; **production application is a separately scheduled step** and
has not happened.

## Verdict 2 — the "senior-consultant level" claim: **REJECTED — rescoped**

*Bar: would a senior engagement manager at a top-tier firm stand behind this product's output to
a paying client?*

No. Proof coverage 17/100, functional coverage 53/100, and the 47 absent checks are concentrated
exactly where consultancy lives:

- **No discovery or diagnosis layer** (section C, 8/10 absent): nothing generates candidate
  issues across domains, ranks them, detects deterioration, or controls false discovery. The
  "five most important things" question has no engine behind it.
- **One opportunity class** (section H, 6/10 absent): `recommendation_type` is CHECK-constrained
  to a single value. A consultant with one move is not a consultant.
- **Prompt-instructed, not validated AI** (section I, 9/10 absent): no numeric, population,
  causal-language or confidence validator inspects generated output.
- **No demographic, funnel, daypart, staff-mix or package analytics** (sections D/E): the raw
  authorities exist; the analysis layer does not.

What the wave bought is the part consultancy cannot exist without: numbers that reconcile,
intervals that are mathematically possible, cadence honest about ignorance, boundaries that
hold, and a proof discipline — predetermined truth tables, mutation checks, red-held defects,
and now an adversarial verification loop that demonstrably catches the orchestrator's own
errors — that makes every future claim checkable. That is the foundation, not the house.

### The rescoped program

Five phases; every capability lands with an executed truth-table fixture; no phase ships on
source inspection.

| Phase | Builds | Acceptance bar (executable) | Checks |
|---|---|---|---|
| **CI-A · Analyst** | Retention funnels (1st→2nd→3rd, maturity-adjusted fixed windows), demographic aggregates with coverage + k-floors, daypart/weekday rates with exposure denominators, service & package intelligence | Every reader proven corpus-style: exact predetermined values, coverage fields, small-cell suppression; the "women 25–30 facial" question answers with all eleven required fields | 31–38, 41–44, 60 |
| **CI-B · Statistician** | One central sample-floor authority for *every* subgroup surface, median/outlier/top-share sensitivity, YoY seasonality, missingness bounds, hypothesis-count bookkeeping | Section G's traps pass: 3-of-3 abstains everywhere, skew triggers leave-one-out, discovery records its comparisons | 61–70 |
| **CI-C · Consultant spine** | Typed insight contract (pattern→comparison→impact→action→evidence→confidence→limitation), multi-class opportunity generation, cross-domain ranking with "do nothing" as a ranked outcome, margin guardrails where cost coverage exists | Blinded synthetic-business test: ≥9 of 10 planted ground-truth issues in the top ten, zero fabricated top-five entries | 21–30, 71–79 |
| **CI-D · Evidence-safe generation** | Deterministic validators on model output (numeric, population, causal vocabulary, confidence ceiling, limitation preservation), adversarial + contradiction suites, model-change regression gate | Zero fabricated numbers/customers/causal claims across the adversarial corpus, enforced by code that rejects | 81–90 |
| **CI-E · Field acceptance** | Blinded reviewer panel, defined production-shadow window, Sol's final reproduction | Reviewers rate ≥80% defensible with zero harmful; shadow reconciles; Sol records the verdict | 80, 99, 100 |

CI-A and CI-B are parallel-safe; CI-C consumes both; CI-D wraps CI-C's contract; CI-E is
calendar- and people-gated.

### Standing items this verdict does not close

- **D6** — v625 broke the sessionless evidence drain path; held red by `v552`. Needs an
  auth-design decision (a dedicated internal authority, not a wider Google exemption).
- **`v32_customer_wallet_context`** still carries its own `customerintel → disabled` clause on
  the customer-wallet path; flagged for an owner call.
- **Five of the six remaining pre-existing suite failures** now show the v620 fixture-class
  error under the full chain — cheap follow-up repairs, outside this wave's scope.
- **Production application of v667–v669** and the **shadow window** (start, duration,
  reconciliation method, stop conditions) remain scheduled steps, not side effects of the merge.
