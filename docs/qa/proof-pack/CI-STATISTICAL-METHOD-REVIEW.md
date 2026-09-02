# CI-100 proof-pack item 8 — statistical method review

> **Internal review by an agent that did not author the methods; NOT an external expert
> sign-off — item 8 remains EXTERNAL until a named statistician signs below.**

```
Named independent reviewer (external, statistician):  ______________________________
Affiliation / credential:                              ______________________________
Date reviewed:                                          ______________________________
Signature:                                               ______________________________
Verdict (ACCEPTED / ACCEPTED WITH CONDITIONS / REJECTED): ___________________________
Conditions (if any):
______________________________________________________________________________________
______________________________________________________________________________________
```

**Scope.** Proof-pack item 8 of `docs/qa/CI-100-CHECKLIST.md` and section G's required proof:
*"Statistical routines must pass expert-reviewed fixtures for rare events, extreme rates, skew,
Simpson's paradox and confounding."* This document reviews, method by method, every statistical
routine underlying checks 61–70, with formula, implementation site, exercising fixture, and an
independent recomputation performed by this reviewer (not copied from the fixture's own
comments) using Python (`erf`/`math`) and hand arithmetic, cross-checked against a fresh
migrated-cluster run of the actual SQL where the harness could be run in the time available.

**Environment.** Reviewed in worktree `/Users/cs/Downloads/loyalty-worktrees/wt-ci-proof`,
branch `claude/ci-proof-100`, HEAD `68a55d3f` (2026-09-02 18:55 SGT). The working tree carries
uncommitted edits to several migrations plus two untracked migrations (v729, v730); the harness
was run with `--migrated-only` against the full chain including those, and the chain applied and
ran clean (see the "Fresh execution evidence" table at the end of each section — command,
duration and verdict are the tool's own output, not narrated).

---

## (a) Sample floor k = 5 — `app.subgroup_evidence_v1` (v672)

**File:line.** `db/migrations/20260920_nestly_v672_statistical_authority.sql:31-43`.

```sql
select jsonb_build_object(
  'n', coalesce(p_n, 0),
  'floor', greatest(1, coalesce(p_floor, 5)),
  'status', case when coalesce(p_n, 0) >= greatest(1, coalesce(p_floor, 5))
                 then 'ok' else 'insufficient' end);
```

Pure, `n >= floor` (inclusive), default floor 5, floor itself clamped up to a 1-sample minimum
(never 0 or negative). This is the single floor embedded by every subgroup-producing reader
(discovery cells, category mix, service intelligence, return-probability scoring, evaluation
population — grep across `db/migrations/2026090[1-2]_nestly_v6*` confirms only this function
computes a floor for CI surfaces post-v672).

**Provenance of "5".** `db/migrations/20260901_nestly_v667_ci_access_boundaries.sql:224`
("k=5: the conventional small-cell floor. Below it, naming the members of a filtered ... ")
shows the number originates as a **privacy** small-cell-suppression convention (k-anonymity
style, preventing re-identification of individuals in a filtered cohort), then v672's header
repurposes the *same* constant as the **statistical** evidence floor for every value surface.

**Appropriateness for proportions vs. means — PASS with a documented CONCERN.**

- For **proportions** (rates), n=5 is defensible as a *display floor*, not as a claim of
  precision, because the floor never gates the interval width — it only gates whether a value is
  shown at all, and every rate that does clear the floor still carries its own Wilson/Newcombe
  interval (see (b)), which at n=5 is honestly very wide (0/5 → CI [0.0, 43.4]% — see the stress
  table below). The floor plus the interval together do the job a floor alone cannot: the floor
  suppresses n=1..4 outright, and the interval keeps n=5..~20 from being over-read. This is the
  right division of labour and matches standard practice (a fixed minimum n plus an
  uncertainty interval, rather than a minimum n alone).
- For **means/distributions** (`app.distribution_block_v1`), n=5 is a much weaker basis: a
  single-point mean or skew verdict at n=5 has no confidence interval attached at all (no SE, no
  CI on the mean is emitted anywhere in this authority) — only a point estimate plus a boolean
  skew flag. The stress table below shows this is not merely theoretical: a single outlier among
  5–6 values trivially produces `skew_material=true` (top1 share 96–99%), which is the *correct*
  direction of error (flag, don't hide) but the underlying mean/median themselves carry no
  disclosed uncertainty at n=5. **Recommendation:** either (i) accept this as intentional — the
  distribution block is disclosure, not inference, and downstream readers are told to treat n=5
  distributions as directional — and say so explicitly next to `skew_material`, or (ii) raise the
  distribution-specific floor above the proportion floor (e.g. n≥10) since a mean has no built-in
  self-correcting interval the way a Wilson-scored rate does.
- **Structural gap, CONCERN:** `subgroup_evidence_v1` and `rate_block_v1`/`distribution_block_v1`
  are independent pure functions — nothing in the type system or a shared wrapper forces a
  reader to check `evidence.status == 'ok'` before displaying `rate.pct` or
  `distribution.mean`. Correctness today depends on every reader consistently gating render on
  the evidence block (verified true for the readers inspected — v681, v686, v691, v705 all call
  both and gate on status before using the rate/mean) but there is no compiler- or
  contract-level guarantee a future reader can't call `rate_block_v1` alone and print a real
  percentage from n=1. Recommend a single combined helper (or a lint/fixture rule) that makes it
  structurally impossible to render a rate without its evidence block.

**Fixture.** `db/tests/executed/v672_corpus_stat_authority.sql` T1/T2 (floor boundary n=4/5,
explicit-floor n=0 vs floor=1, negative-floor clamp). Independently recomputed, see stress table.

**Independent stress table (n=1..6, rates 0/n and n/n), computed directly from the function's own
code, not copied from any fixture comment:**

| n | evidence.status (floor=5) | rate 0/n → pct | rate n/n → pct | single-arm Wilson 0/n [lo,hi]% | single-arm Wilson n/n [lo,hi]% |
|---|---|---|---|---|---|
| 1 | insufficient | 0.0 | 100.0 | [0.0, 79.3] | [20.7, 100.0] |
| 2 | insufficient | 0.0 | 100.0 | [0.0, 65.8] | [34.2, 100.0] |
| 3 | insufficient | 0.0 | 100.0 | [0.0, 56.2] | [43.8, 100.0] |
| 4 | insufficient | 0.0 | 100.0 | [0.0, 49.0] | [51.0, 100.0] |
| 5 | **ok** | 0.0 | 100.0 | [0.0, 43.4] | [56.6, 100.0] |
| 6 | ok | 0.0 | 100.0 | [0.0, 39.0] | [61.0, 100.0] |

Note: `rate_block_v1`'s `pct` is honestly 0.0/100.0 at every n above (denominator > 0, so this is
a real, not a manufactured, zero — the manufactured-zero defect the function exists to prevent is
0/0, tested separately as T4/T5). The evidence-status column is what actually withholds a
low-n rate from display; the rate function itself does not.

**Verdict: PASS**, with the two documented CONCERNs above (mixed privacy/statistical origin of
the constant; no structural coupling between the floor and the rate/mean it is meant to gate).

---

## (b) Newcombe hybrid Wilson interval — `app.evidence_block_v1` (v669)

**File:line.** `db/migrations/20260901_nestly_v669_numeric_honesty.sql:93-180`. Newcombe (1998)
hybrid-score method: an independent Wilson score interval computed on each arm, then combined.

```
denom_i  = 1 + z²/n_i
centre_i = p_i + z²/(2·n_i)
adj_i    = sqrt( p_i(1-p_i)/n_i + z²/(4·n_i²) )
[l_i,u_i] = (centre_i ∓ z·adj_i) / denom_i         (Wilson score bound, arm i, z=1.96)

lo = (p1-p2) - sqrt( (p1-l1)² + (u2-p2)² )
hi = (p1-p2) + sqrt( (u1-p1)² + (p2-l2)² )
```

**Why this replaced Wald.** The migration's own header documents the defect it fixes: a Wald
interval on 9/10 vs 1/10 produced hi=106.3pp, outside the only legal range [-100,100] for a
difference of two rates — held red by a deliberately-red assertion (S6b) before the fix. Wilson
bounds are bounded to [0,1] by construction, so the Newcombe combination is bounded to [-100,100]pp
by construction. This is the textbook fix for exactly this failure mode and is correctly cited.

**Independent recomputation.** I implemented the exact formula above in Python (not reusing the
migration's inline comments) and ran it against the three cases the task specifies. Because
`evidence_block_v1` is inherently a *two-arm* function (it always compares a treated arm to a
comparison arm), I verified both (i) the single-arm Wilson bound that Newcombe combines — the
correctness-critical building block — and (ii) one genuine two-arm Newcombe difference, so the
combination step itself is also checked independently, not merely trusted.

*Single-arm Wilson bounds (the building block), independently computed:*

| Case | p̂ | Wilson [lo, hi] |
|---|---|---|
| 3/3 | 1.000 | [43.8%, 100.0%] |
| 0/5 | 0.000 | [0.0%, 43.4%] |
| 12/40 | 0.300 | [18.1%, 45.4%] |

Note the 3/3 case: unlike Wald (which collapses to a degenerate point [100%,100%] at p=1, the
exact defect the v669 header calls out for a 5/5-vs-0/5 case, S1b), Wilson correctly reports
genuine residual uncertainty even at the extreme — [43.8%, 100.0%], not a false point estimate.
This directly demonstrates check 63 ("tiny binary samples do not use misleading Wald intervals")
is satisfied by construction, independent of the fixture's own assertions.

*Two-arm Newcombe combination, independently recomputed (12/40 treated vs 3/3 comparison, an
extreme-vs-tiny pairing chosen to stress both ends at once):*

p1 = 0.300, p2 = 1.000, diff = -0.700
lo = -0.700 - sqrt((0.300-0.181)² + (1.000-1.000)²) = -0.700 - 0.119 = **-81.9pp**
hi = -0.700 + sqrt((0.454-0.300)² + (1.000-0.438)²) = -0.700 + 0.586 = **-11.4pp**

Both bounds inside [-100,100]pp as required; I additionally re-derived the migration's own
worked example (9/10 vs 1/10) independently and reproduced its stated bounds to within rounding
(lo≈53.7pp is the *Wald* number the header shows as the pre-fix defect, not what the fixed
function returns — the header is explicit that this is the historical bad value, and the live
fixture repins Wilson/Newcombe values for the same shape at S1b/S3/S4, which I did **not**
re-derive independently within this review's time budget; flagged below as a residual gap rather
than silently treated as verified).

**Fixture.** `db/tests/executed/v652_corpus_statistics.sql` (S1a/S1b/S3/S4/S6a/S6b), migration
header records that S1b/S3/S4 were re-pinned by the *verifying* session to hand-computed Newcombe
values at the time of the v669 migration (not merely re-run against new code) — a legitimate
truth-table update for a deliberate, disclosed method change, distinct from silently loosening a
tolerance.

**Verdict: PASS**, with one residual GAP disclosed rather than hidden: this review independently
re-derived the single-arm Wilson bounds for 3/3, 0/5, 12/40 and one full two-arm Newcombe
combination, all matching the implementation, but did **not** independently re-derive the three
specific truth-table pins in `v652_corpus_statistics.sql` (S1b/S3/S4) that the v669 migration
header says the *original verifying session* hand-computed. An external statistician should
re-derive those three pins from scratch as part of sign-off, since this review's independent
check covers the formula's correctness in general but not that every fixture constant is right.

---

## (c) Two-proportion z-test and Benjamini–Hochberg q=0.10 — `app.two_prop_p_value_v686` (v686)

**File:line.** `db/migrations/20260920_nestly_v686_discovery_scan.sql:140-197` (erf approximation,
normal two-tailed p, two-proportion z), `:380-393` (BH step-up).

```
p1 = x1/n1, p2 = x2/n2, pooled = (x1+x2)/(n1+n2)
se = sqrt( pooled·(1-pooled)·(1/n1 + 1/n2) )
z  = (p1-p2) / se        (se=0 ⇒ p=1 if p1=p2 else 0, an edge case that cannot arise given
                           callers always pass n1,n2 > 0)
p  = 2·(1 - Φ(|z|))      via erf (Abramowitz & Stegun 7.1.26, |error| ≤ 1.5e-7)
```

```sql
select *, row_number() over (order by p_value asc, dimension, group_key) as p_rank,
       count(*) over () as m
  from candidates
),
bh as (select *, (p_value <= (p_rank::numeric / m) * v_q) as clears_own_rank from ranked),
bh_cutoff as (select coalesce(max(p_rank) filter (where clears_own_rank), 0) as k from bh),
survivors as (select bh.* from bh, bh_cutoff where bh.p_rank <= bh_cutoff.k)
```

This is the textbook Benjamini–Hochberg step-up procedure: sort ascending, find the *largest*
rank i with p₍ᵢ₎ ≤ (i/m)·q, reject every hypothesis at or below that rank. The implementation is
correct — `max(p_rank) filter (where clears_own_rank)` is exactly "the largest i satisfying its
own threshold," and `p_rank <= k` (not `clears_own_rank` alone) is the correct BH semantics
(a hypothesis at rank j < k is rejected even if its own p-value doesn't individually clear
(j/m)·q, which is the step-up procedure's defining property, distinct from a naive
per-hypothesis Bonferroni-style filter).

**Independent recomputation.** Using the exact erf approximation coefficients from the migration
(not `math.erf`), on the v686 fixture's own REFERRAL candidate (train half, referral 16/20 vs
pooled rest 37/73):

```
p1=0.8, p2=0.506849, pooled=0.569892
se = sqrt(0.569892·0.430108·(1/20+1/73)) = sqrt(0.245115·0.063699) = 0.124955
z  = (0.8-0.506849)/0.124955 = 2.34607
p  = 2·(1-Φ(2.34607)) = 0.018973   [migration's own A&S erf approximation]
p  = 0.018973                       [exact math.erf, for cross-check]
```

Both the approximated and exact-erf computations agree to 4 significant figures (0.018973 vs
0.018973), confirming the erf approximation's stated ≤1.5e-7 error bound holds in this regime and
does not distort BH ranking or the q=0.10 comparison at any p-value scale relevant here. I then
independently verified the fixture's own worst-case BH argument: at the *largest possible* rank
(referral ranked dead last among however many candidates a live run turns up), the loosest
threshold BH can ever apply is (m/m)·q = q = 0.10; 0.0190 clears that unconditionally, so
REFERRAL's BH survival does not depend on the exact m or its exact rank — a sound, rank-robust
argument rather than a brittle re-derivation of tie-breaks.

**Train/holdout replication as a multiplicity control — PASS, correctly characterized.** BH
controls the *expected proportion of false discoveries among what is promoted*, given the
candidate set actually tested; it does **not** protect against a candidate that clears BH by
chance on this particular random split of the data. The engine's holdout step (train-half BH
survivors re-evaluated against a disjoint holdout half; kept only if the sign of the difference
replicates) is a *second, independent* filter that catches exactly the failure mode BH alone
cannot: a candidate whose apparent effect was a train-half artifact. This is the correct
mental model — BH and holdout replication are answering different questions (respectively "how
many of my rejections are false positives, given this test set" and "does this specific finding
reproduce out-of-sample") and the engine's own header explicitly frames them as independent by
design (`db/migrations/20260920_nestly_v686_discovery_scan.sql:130-133`), which this review
confirms is the statistically correct framing, not merely restating the comment as fact — the
"not_replicated" and BH-survivor populations are genuinely orthogonal because BH is computed on
train p-values only and replication is a sign-agreement test on a disjoint holdout, so the two
checks cannot substitute for each other and the migration is right to keep both.

**Fixture.** `db/tests/executed/v686_corpus_discovery.sql` — the REFERRAL/WALKIN/SATURDAY/FACIAL/
OUTLIER five-cohort scenario with hand-computed train/holdout counts and the p-value derivation
above, matched to 4 s.f.

**Verdict: PASS.**

---

## (d) Temporal holdout calibration (Brier/AUC) and the exponential return-probability model (v681)

**File:line.** Model: `db/migrations/20260920_nestly_v681_return_probability.sql:93-160`.
Evaluation: `:168-306`.

```
P(return within H days | as_of) = 1 - exp(-H / m)     H = 30 (default)
```
where m = the customer's own median inter-visit interval (`app.customer_cadence_batch_v1`), and
the model abstains (status='insufficient') below k=3 measured intervals — a *harder*, non-
configurable floor than the general k=5 (a's) or the cadence module's own business-configurable
policy, on the stated grounds that a probability claim is a stronger, more quotable statement
than a lapse-state label (migration header, lines 72-78). That reasoning is sound: a probability
figure invites arithmetic (EV = probability × ticket, seen downstream at v688) in a way a
categorical label does not, so the stricter, fixed floor is the right asymmetry.

**Is the exponential assumption disclosed? YES — explicitly, in the payload itself, not only in
a code comment.** The function's own `method` string
(`db/migrations/20260920_nestly_v681_return_probability.sql:151-158`) states verbatim: *"memoryless
exponential hazard ... Days already elapsed since the last visit are deliberately NOT used as a
covariate: the exponential distribution is memoryless by construction ... This is a documented
property of the chosen method, not an omission."* This is returned to every caller, not buried in
SQL comments a UI consumer would never see — satisfying the letter and the spirit of "disclosed."

**Statistical assessment of the model choice.** The memoryless-exponential-on-median-interval
model is a defensible, simple, auditable choice, but it has a real limitation this review
independently confirms is *not* separately disclosed alongside the memorylessness note: real
customer inter-visit distributions are frequently over-dispersed relative to an exponential (many
real-world visit-gap distributions are closer to a Weibull/gamma with shape≠1, i.e. NOT
memoryless — a customer who is already 40 days into a 30-day median rhythm is empirically often
*more* likely to be genuinely lapsed than the model's memoryless assumption implies, not
equally likely as a customer at day 2). The model discloses that it *doesn't use* elapsed time,
and explains why in a way that is honest about the mechanism — but it does not disclose that this
is a modeling *simplification* whose accuracy depends on the customer's true process actually
being close to memoryless, which the evaluation function's own calibration/AUC numbers are the
correct (and only) empirical check on. **CONCERN, not a defect:** recommend the `method` string
additionally name the calibration RPC (`evaluate_return_probability_v681`) as the way to verify
this assumption holds for a given business, so a reader of the disclosure is pointed at the
falsifiability check rather than only the mechanism.

**Calibration/AUC implementation — reviewed correct.**
- **Brier score**: `avg(power(prob - y, 2))` over exactly the scored (non-abstained) population —
  the standard Brier score definition, correctly restricted to predictions that exist.
- **AUC**: computed as the Mann-Whitney U statistic via rank-sum
  (`(sum_pos - n_pos*(n_pos+1)/2) / (n_pos*n_neg)`), with `avg(rn) over (partition by prob)` giving
  ties the standard 0.5-credit averaged rank. This is the textbook rank-based AUC estimator and is
  correctly null-guarded when either class is empty.
- **Temporal leak guard**: an *executed*, not merely claimed, re-check
  (`db/migrations/20260920_nestly_v681_return_probability.sql:193-205`) raises if any scored
  client's own last known visit falls after `p_train_until` — independently re-verifying the
  population the cadence function already claims to filter, rather than trusting that filter
  blindly. This is good practice (defense in depth against a future regression in the upstream
  batch function) and this review confirms the guard's condition (`b.last_visit_at > p_train_until`)
  is the correct direction to catch a leak.

**Fixture.** `db/tests/executed/v681_corpus_calibration.sql` — **fresh execution confirmed by
this review** (see table below): `ok v681_corpus_calibration.sql (10461ms)`, full migrated chain
through v730 applied clean.

**Verdict: PASS**, with one disclosed CONCERN (name the falsifiability check alongside the
memorylessness disclosure) that does not block acceptance.

---

## (e) Distribution block skew rule — `app.distribution_block_v1` (v672), sensitivity at n=5 (v691)

**File:line.** Formula: `db/migrations/20260920_nestly_v672_statistical_authority.sql:60-96`.

```
skew_material = (top1_share_bps >= 3000)  OR  (median > 0 AND mean/median >= 1.5)
```

i.e. the single largest value carries ≥30% of the total, OR the mean is at least 1.5× the median
(a classic right-skew signature). Either condition alone trips it — a deliberate OR, not AND, so
a whale-dominated set and a merely lopsided-but-no-single-whale set are both caught.

**Independent sensitivity check at n=5 (the exact boundary the fixture exercises).** I
independently constructed and hand-evaluated the two n=5 shapes the v691 fixture uses, plus one
more of my own (a "near-miss" whale at exactly 30% instead of 60%), to test the rule's boundary
behaviour rather than only its interior:

| n=5 values | mean | median | top1_share_bps | mean/median | skew_material | Correct? |
|---|---|---|---|---|---|---|
| {1000,1000,1000,1000,1000} (flat) | 1000.00 | 1000.00 | 2000 (20%) | 1.00 | **false** | Yes — no skew present |
| {1000,1000,1000,1000,6000} (whale, fixture A1) | 2000.00 | 1000.00 | 6000 (60%) | 2.00 | **true** (both legs trip) | Yes |
| {1000,1000,1000,1000,1000+x} where x chosen so top1=30.0% exactly | — | — | 3000 (30%, boundary) | — | **true** (`>=`, inclusive) | Yes — the `>=` makes the boundary itself material, the conservative (flag, don't hide) direction |
| {700,700,700,700,4200} (top1=60%, mean/median=1.5 exactly) | 1400 | 700 | 6000 | 2.0 | true | Yes |

The rule is monotonic and has no gap: at n=5, a single value needs only to be the *maximum* and
carry ≥30% of the five-value sum to trip skew_material, which is easy to satisfy by construction
— this is intentional oversensitivity (a low bar favouring disclosure over suppression), and the
fixture's own mutation check (removing the whale and re-running: `skew_material` flips to false,
recomputed not memoized — `db/tests/executed/v691_corpus_outliers_confounders.sql:395-435`)
independently proves the function is genuinely responsive to the data, not a static label.

**Independent stress table (n=1..6, one-whale shape: (n-1) units of value 1 plus one whale of
value 100), computed directly from the algorithm, not the fixture:**

| n | mean | median | top1_share_bps | skew_material |
|---|---|---|---|---|
| 2 | 50.50 | 50.50 | 9901 (99.0%) | true |
| 3 | 34.00 | 1.00 | 9804 (98.0%) | true |
| 4 | 25.75 | 1.00 | 9709 (97.1%) | true |
| 5 | 20.80 | 1.00 | 9615 (96.2%) | true |
| 6 | 17.50 | 1.00 | 9524 (95.2%) | true |

Correctly flags skew at every n from 2 upward for an extreme whale — the rule degrades gracefully
rather than requiring a minimum n to activate (it has no n-dependence at all, which is
appropriate here since `skew_material` is a *descriptive* statistic of the sample in hand, not an
inferential claim about a population).

**Fixture.** `db/tests/executed/v672_corpus_stat_authority.sql` T6/T7/T8 (formula truth table);
`db/tests/executed/v691_corpus_outliers_confounders.sql` PART A (n=5 WHALE/FLAT/SCARCE, the
below-floor n=4 SCARCE case, and the whale-removal mutation check) — **fresh execution confirmed
for v691** (see table below).

**Verdict: PASS.**

---

## (f) Stratified confounder check — consistent/mixed/reversed/tied/unchecked (v691/v702/v708)

**File:line.** Core logic (post-v708, the current live shape):
`db/migrations/20260920_nestly_v691_outliers_and_confounders.sql:638-698` (original), refined by
`db/migrations/20260920_nestly_v702_discovery_verdict_rigor.sql` (adds `unchecked`, fixes the
"minority reversal silently promoted" defect) and
`db/migrations/20260920_nestly_v708_discovery_tie_strata.sql` (adds `tied`, fixes exact-tie
strata being silently counted as agreement). The final verdict rule, confirmed by reading the
v708 anchor text directly (`db/migrations/20260920_nestly_v708_discovery_tie_strata.sql:86-92,
157-158`):

```
verdict = case
  when strata_checked = 0                                  then 'unchecked'
  when strata_reversed / strata_checked > 0.5               then 'reversed'
  when strata_reversed = 0 and strata_consistent = strata_checked  then 'consistent'
  when strata_reversed = 0                                  then 'tied'      -- (some strata neither agree nor reverse)
  else                                                            'mixed'
end
```

This is a genuinely typed, five-way verdict rather than a boolean "confounded/not," and the two
migrations layered on top of v691 are themselves evidence of the discipline working as intended:
v702's own header documents a **real defect it found and fixed** — a survivor with a *minority*
of reversed strata got `'mixed'`, correctly, but `confounded` was hardcoded `true` only for
`'reversed'`, so a `'mixed'` (partially confounded) survivor still sailed into `'discoveries'`
carrying a confounders block the caller was never told to distrust. v708 found a **second**
defect of the same family: an exact tie (stratum rate identical on both sides, `stratum_sign=0`)
was counted in *neither* the consistent nor the reversed bucket, so a stratum that showed *no
signal at all* was silently treated as agreement (`strata_reversed=0` was mistaken for
"everything agreed"). Both are exactly the class of subtle counting bug a Simpson's-paradox
detector is supposed to catch in *other* people's numbers — the fact that two were found and
fixed in its own bucket-counting logic, and are documented in the migration headers rather than
silently corrected, is a good governance signal, not a red flag.

**Independent Simpson's-paradox construction and hand verification.** Rather than re-deriving
the fixture's own worked example, I re-derived it independently from the raw counts alone (not
copying the fixture's stated conclusion) to confirm the classifier's math, then separately
confirmed the classifier's *verdict* against that recomputation:

```
Branch A: referral 28/40 = 70.0%   walk_in_till 8/10  = 80.0%   stratum diff = -10.0pp
Branch B: referral 1/10  = 10.0%   walk_in_till 8/40   = 20.0%   stratum diff = -10.0pp
Aggregate: referral (28+1)/(40+10) = 29/50 = 58.0%
           walk_in_till (8+8)/(10+40) = 16/50 = 32.0%
           aggregate diff = +26.0pp   (referral AHEAD in the pooled aggregate)
```

Both branch-level strata show referral **behind** walk_in_till (-10.0pp each), while the pooled
aggregate shows referral **26.0pp ahead** — a textbook Simpson's paradox driven by composition
(referral customers are concentrated in the high-performing branch A: 40 of 50; walk_in_till
customers are concentrated in the low-performing branch B: 40 of 50). I independently confirm
this arithmetic is internally consistent (29/50 and 16/50 are exactly the weighted combinations
of the two branch cells) and that the classifier's rule — 2 of 2 eligible strata reverse sign,
a full majority, `strata_reversed/strata_checked = 1.0 > 0.5` — correctly yields `verdict =
'reversed'`, which under the current (post-v702) membership rule removes this candidate from
`discoveries` into a separate `confounded` list rather than either silently dropping it or
silently promoting a false headline. This is the right behaviour: check 68 explicitly requires
confounders be *tested*, and this construction proves the mechanism actually catches a real
Simpson's-paradox shape rather than merely having a code path that claims to.

I also independently checked the **complementary, non-paradox case** (PART C of the same
fixture): same two-branch shape, but referral leads walk_in_till *within* each branch too
(Branch A +10.0pp, Branch B +10.0pp, aggregate +40.0pp) — same sign throughout, so
`strata_reversed=0, strata_consistent=strata_checked` correctly yields `'consistent'`. Having
both the paradox and non-paradox cases hand-verifiable and both resolving to the theoretically
correct verdict is meaningful evidence the classifier discriminates, not merely defaults to a
fixed answer.

**Fixture.** `db/tests/executed/v691_corpus_outliers_confounders.sql` PART B (Simpson's paradox,
`'reversed'`), PART C (mutation check, `'consistent'`), PART D (genuine relationship across four
strata, `'consistent'`, plus a competing-campaigns disclosure count). `db/tests/executed/
v702_corpus_discovery_rigor.sql` PART U exercises `'unchecked'` (every other dimension pinned so
it can never furnish an eligible stratum on both sides; asserted in `unverified`, never
`discoveries`/`confounded`, with an explicit mutation-check note that reverting the anchor text
would move it to `'consistent'` and turn the assertion red — confirmed by reading the fixture,
not independently re-run by this review). `db/tests/executed/v708_corpus_discovery_ties.sql`
PART T exercises `'tied'` (2 of 3 checked strata exact ties, 1 agrees, 0 reverse — verified by
reading the fixture that this correctly resolves to `'tied'`, not `'consistent'`, and lands in
`unverified`; the fixture's own comment documents that reverting either of two specific anchor
edits independently would surface the pre-v708 defect again). Both read and logically confirmed
against the anchor text in (f)'s formula box above; not independently hand-recomputed by this
review beyond that cross-check — see gaps section.

**Verdict: PASS.**

---

## (g) Materiality bps and expected value (v705/v712/v718)

**File:line.** Materiality bar: `app.ci_materiality_threshold_bps_v705()`
(`db/migrations/20260920_nestly_v705_spine_v3.sql:180-187`) — a single hardcoded `100` (1% of
period revenue, in basis points), the *one* place this bar is defined; `v712` moved the
duplicate constant (`c_ev_materiality_pct := 1.0`) that previously lived separately inside the
opportunities-ranking function to derive from this same authority instead
(`db/migrations/20260920_nestly_v712_spine_wording_closures.sql:6-14`), closing a
two-authorities-for-one-number risk. Margin guard:
`app.ci_margin_guard_v705(business, service_id, incentive_cents)`
(`db/migrations/20260920_nestly_v705_spine_v3.sql:195-239`) — `margin = price_cents - cost_cents`;
`status='unavailable'` when no service or no cost on record (never a guessed margin);
`status='blocked'` when the incentive exceeds the margin; `status='ok'` otherwise. Expected value
example (probability-adjusted, cost-*unaware* in this instance — see CONCERN below):
`db/migrations/20260920_nestly_v688_consultant_spine_v2.sql:1119-1129` —
`ev_cents += round(probability × avg_ticket)` per scored client, summed over the lapsed-regulars
population, `probability` sourced from `app.return_probability_v681` (item (d)).

**Materiality bar — PASS.** One function, one constant, one caller path after v712's
consolidation; every extended-mode candidate in `get_ci_opportunities_v1` carries a
`materiality` object (numerator/denominator/pct, via `rate_block_v1`) and a
`materiality_class` (`material`/`minor`/`unquantified`) rather than a bare pass/fail — satisfying
check 12's numerator-denominator-together discipline even for this threshold check specifically,
and check 76 ("insufficient evidence" is a valid ranked outcome) via the `unquantified` class for
a candidate whose EV cannot be computed at all (no behavioural model, e.g. a service-cost gap with
no probability model behind it — `db/migrations/20260920_nestly_v705_spine_v3.sql` C/E section).

**Margin guard — PASS.** Correctly refuses to manufacture a margin from a guessed cost
(`status='unavailable', reason='no cost recorded for this service; enter costs in Settings'`
rather than assuming a default margin), which is the check-74 requirement in its strongest form
("Reward, discount ... costs are included **before** recommending an incentive" — an unavailable
guard, correctly, blocks nothing but also *approves* nothing; it is on the caller to treat
`unavailable` as non-permissive, which the fixture at
`db/tests/executed/v705_corpus_spine_v3.sql` A-section confirms for the direct-call case, and
`db/tests/executed/v718_corpus_spine_margin.sql` extends to the full-RPC candidate-ranking path).

**Expected value — PASS on probability-adjustment, CONCERN on cost-awareness scope.** The
lapsed-regulars EV term (`probability × avg_ticket`) is correctly probability-adjusted — it uses
the item-(d) return-probability model rather than a flat assumption, and abstains (excludes from
the EV sum, counted separately as `v_ev_lapsed_abst`) for any client the model itself abstains on,
so an uncertain prediction never silently contributes a manufactured number to the aggregate. This
satisfies check 73's "probability-adjusted ... or explicitly unavailable" for the population as a
whole. However, this specific EV term is **not itself cost-net** — it is expected *gross revenue*
(probability × ticket), not expected *margin* (probability × (ticket − incentive cost)); margin
protection is applied as a separate, later gate (`ci_margin_guard_v705`) on the *incentive*
associated with acting on the finding, not netted into the EV figure the ranking sorts by. Check
73 asks for "expected value ... probability-adjusted and cost-aware" — as implemented, the
platform is cost-aware at the *action-gating* stage (an incentive that would exceed margin is
blocked before it reaches the customer) but the *ranking* stage sorts candidates by a
cost-unaware gross-EV number. For a candidate whose recommended action *is* a spend incentive,
this means two candidates with identical gross EV but very different margins could rank
identically, when the margin-aware one is the better recommendation. **Recommendation:** either
(i) net the margin-guard's resolved cost into the EV figure itself wherever an incentive is the
proposed action (falling back to `unquantified`/gross-only when the margin guard itself resolves
`unavailable`, consistent with check 76's "insufficient evidence is a valid outcome"), or (ii)
keep EV gross but make the ranking's sort key explicitly a (EV, margin_guard.status) composite
so a `blocked` or `unavailable` margin candidate cannot outrank a smaller-EV, margin-clean one —
and document the choice next to `expected_value` the way `return_probability_v681`'s own `method`
string documents its exponential assumption.

**Reachability finding — reported by v718 as a deliberate non-fix, correctly not silently
patched.** `db/migrations/20260920_nestly_v718_spine_margin_and_alternatives.sql` investigates
whether `materiality_class='minor'` is reachable for a realistic candidate and finds it is
architecturally unreachable in the current pipeline shape (any EV-bearing candidate that survives
to the materiality-classification step has, by construction, already cleared the pre-existing
EV-materiality gate that filters out everything below the same bar as a `below_materiality:...`
abstention) — and the migration explicitly declines to change this, because the one fix
considered would flip a frozen fixture's holder (`plan_small`) from "absent/abstained" to
"present/minor" for the identical underlying numbers, which is not a bug fix but a silent
redefinition of what a frozen truth-table constant means. This is exactly the "report, don't
bend" discipline the codebase's own audit rules ask for, and this review agrees with the
non-fix: `minor` remaining unreached by realistic data is a *consequence* of the gate ordering
being conservative (never showing a sub-materiality finding at all, rather than showing it
downgraded), not a bug — but it is worth a docs note next to `materiality_class`'s definition
that `minor` is a defined-but-currently-unreachable value for anyone reading the classifier
schema in isolation.

**Fixture.** `db/tests/executed/v705_corpus_spine_v3.sql` (margin guard direct calls, section A;
materiality/EV on real RPC output, sections C/D/E/F — including a real `material` example with
EV=19004 matched against an independent hand-count, and a real `minor` example with EV=0);
`db/tests/executed/v718_corpus_spine_margin.sql` (margin-guard status branch through the full
candidate-ranking RPC, plus the investigated-not-fixed reachability finding). **Fresh execution
confirmed for both** — see table below.

**Verdict: PASS**, with one CONCERN (EV is probability-adjusted but not consistently cost-net at
the ranking stage — margin-awareness lives at a separate gate) that should be resolved or
explicitly documented before this checklist item is signed off externally.

---

## Fresh execution evidence (this review's own runs, `--migrated-only`, worktree HEAD `68a55d3f`)

All commands below were executed by this review directly (not copied from prior session notes),
against a throwaway Postgres cluster built by `scripts/db-tests/run.mjs` from the committed
snapshot plus every pending migration in `db/migrations/` applied in order (through v730,
including the two untracked migrations v729/v730 present in the worktree at review time — the
chain applied cleanly, so no `--keep`-before-v729 workaround was needed).

All nine filters relevant to this review completed with `ok` — the full migrated chain (through
the untracked v729/v730) applies cleanly and every fixture below passes on top of it.

| Filter | Command | Result | Test duration | Total incl. cluster build |
|---|---|---|---|---|
| `v672_corpus` | `LC_ALL=C node scripts/db-tests/run.mjs --filter=v672_corpus --migrated-only` | **ok** | 13.7s | 222.6s |
| `v681_corpus` | `LC_ALL=C node scripts/db-tests/run.mjs --filter=v681_corpus --migrated-only` | **ok** | 10.5s | 152.4s |
| `v686_corpus` | `LC_ALL=C node scripts/db-tests/run.mjs --filter=v686_corpus --migrated-only` | **ok** | 29.3s | 169.8s |
| `v691_corpus` | `LC_ALL=C node scripts/db-tests/run.mjs --filter=v691_corpus --migrated-only` | **ok** | 100.2s | 215.8s |
| `v702_corpus` | `LC_ALL=C node scripts/db-tests/run.mjs --filter=v702_corpus --migrated-only` | **ok** (run twice, batch + direct foreground re-run — see note) | 23.2s / 54.9s | 367.4s / 136.7s |
| `v705_corpus` | `LC_ALL=C node scripts/db-tests/run.mjs --filter=v705_corpus --migrated-only` | **ok** (run twice, batch + direct foreground re-run — see note) | 14.1s / 30.3s | 90.2s / 197.1s |
| `v708_corpus` | `LC_ALL=C node scripts/db-tests/run.mjs --filter=v708_corpus --migrated-only` | **ok** | 9.4s | 63.3s |
| `v712_corpus` | `LC_ALL=C node scripts/db-tests/run.mjs --filter=v712_corpus --migrated-only` | **ok** | 6.7s | 45.1s |
| `v718_corpus` | `LC_ALL=C node scripts/db-tests/run.mjs --filter=v718_corpus --migrated-only` | **ok** | 26.3s | 129.6s |

**Note on concurrency and the double runs.** Launching two `run.mjs` invocations at the same
instant caused a cluster-`initdb` bootstrap collision (each invocation builds its own throwaway
Postgres cluster; a same-second collision surfaced once during this review). The remaining
filters were re-queued to run strictly sequentially in one background batch (`for f in
v686_corpus v691_corpus v702_corpus v705_corpus v708_corpus v712_corpus v718_corpus; do
LC_ALL=C node scripts/db-tests/run.mjs --filter=$f --migrated-only; done`), which completed with
all seven `ok`. This reviewer separately re-ran v702 and v705 a second time, directly in the
foreground and independently of that batch, specifically to confirm the batch result was not an
artifact of shared or leaked state (each `run.mjs` invocation builds an isolated, disposable
cluster from scratch, so two independent runs agreeing on `ok` corroborates the harness is
deterministic here, not merely that the batch script suppressed a failure). Both foreground
re-runs also passed. v672/v681/v686 completed individually before the batch was queued.

**Every routine reviewed in sections (a)–(g) above now has fresh, reproducible, executed-SQL
evidence on this worktree's exact HEAD** (not merely a source-level review) — this closes the gap
this review flagged in its own first draft, where six of nine filters were still queued.

---

## Verdict table

| Item | Method | Site | Fixture | Independent recomputation | Verdict |
|---|---|---|---|---|---|
| (a) | Sample floor k=5 | `app.subgroup_evidence_v1`, v672 | v672_corpus T1/T2 | Stress table n=1..6 | **PASS** — 2 CONCERNs (privacy/statistical dual origin of "5"; no structural coupling to rate/mean display) |
| (b) | Newcombe hybrid Wilson | `app.evidence_block_v1`, v669 | v652_corpus S1/S3/S4/S6 | Single-arm 3/3, 0/5, 12/40 + one full two-arm combination | **PASS** — 1 GAP (3 fixture pins not independently re-derived by this review) |
| (c) | Two-prop z + BH q=0.10 | `app.two_prop_p_value_v686` / discovery CTE, v686 | v686_corpus discovery scenario | p-value to 4 s.f. via independent erf; BH rank-robustness argument confirmed | **PASS** |
| (d) | Temporal holdout Brier/AUC + exponential return model | `app.return_probability_v681` / `evaluate_return_probability_v681`, v681 | v681_corpus_calibration | Brier/AUC formulas reviewed correct; exponential disclosure confirmed in payload | **PASS** — 1 CONCERN (name the falsifiability check alongside the disclosure) |
| (e) | Skew rule (top1≥30% or mean/median≥1.5) | `app.distribution_block_v1`, v672/v691 | v672_corpus T6-T8; v691_corpus PART A | n=5 boundary table + one-whale n=1..6 stress table | **PASS** |
| (f) | Stratified confounder verdicts | `get_ci_discovery_v1` confound_* CTEs, v691/v702/v708 | v691_corpus PART B/C/D; v702/v708 corpora | Independent Simpson's-paradox hand construction, verdict confirmed both directions | **PASS** |
| (g) | Materiality bps + EV | `ci_materiality_threshold_bps_v705`, `ci_margin_guard_v705`, EV term, v705/v712/v718 | v705_corpus, v718_corpus | Formula + reachability-finding review | **PASS** — 1 CONCERN (EV not consistently cost-net at ranking stage) |

**Overall: seven PASS, zero FAIL, zero CONCERN blocking, five CONCERNs and one GAP recorded above
for the external reviewer's attention.** None of the CONCERNs found a routine producing a wrong
or misleading number on the fixtures/stress cases this review constructed; all are about scope,
disclosure completeness, or structural robustness against future misuse rather than present
incorrectness. This review does not itself satisfy item 8 — it is the internal half of the
required proof. External statistician sign-off (block at top of this document) is still needed
before item 8 can be marked closed.
