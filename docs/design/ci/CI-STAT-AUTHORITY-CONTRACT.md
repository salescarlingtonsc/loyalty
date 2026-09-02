# CI statistical authority — frozen contract (v672)

Every Customer Intelligence reader added from phase CI-A onward embeds these four blocks
instead of computing its own floor, rate, or distribution. The signatures are FROZEN for the
build wave: readers code against them concurrently, so a change here breaks siblings silently.
Implementation: `db/migrations/20260920_nestly_v672_statistical_authority.sql`.

| Function | Returns | Rule it enforces |
|---|---|---|
| `app.subgroup_evidence_v1(n int, floor int default 5)` | `{"n","floor","status":"ok"\|"insufficient"}` | One sample floor everywhere (check 61/62). When `insufficient`: identity-bearing rows are suppressed and rate-like values go null; raw counts may remain. |
| `app.rate_block_v1(num bigint, den bigint)` | `{"numerator","denominator","pct"}` | A rate always travels with its counts (check 12); `pct` is **null**, never 0.0, when the denominator is 0. |
| `app.distribution_block_v1(values numeric[])` | `{"n","mean","median","p90","top1_share_bps","skew_material","mean_excl_top1"}` | Skew cannot hide behind a mean (check 66). `skew_material` = top1 ≥ 30% of total OR mean/median ≥ 1.5. |
| `app.comparisons_note_v1(examined int, promoted int)` | `{"subgroups_examined","subgroups_promoted","note"}` | Discovery discloses how many comparisons produced its findings (check 69). |

Reader conventions, also frozen:

1. **Gate**: every reader calls `app.ci_access_gate_v667(p_business, p_branch)` first;
   firm-level metrics with no branch dimension call `app.ci_no_branch_dimension_v667`.
2. **Time basis**: every time-derived payload carries `"time_basis"` naming the timestamp used
   (e.g. `"sale_occurred_at"`), and dates bucket in `Asia/Singapore` (check 35/13).
3. **Exclusions**: reversed sales out (`reversal_of is null` and no reversal row), synthetic
   clients out, `counts_as_revenue` / `counts_as_visit` respected — the same population rules
   the v667 corpus proves.
4. **Coverage beside numbers**: any claim over a subset (identified customers, classified
   items, customers with a birth date) carries the subset size and the eligible total via
   `rate_block_v1` (check 15).
5. **Observed-since**: readers include `app.metric_observed_since_v1(<watermark>, p_business)`
   where a watermark exists.
6. **Proof**: no reader ships without an executed truth-table fixture in `db/tests/executed/`,
   predetermined values, exact assertions, mutation-checked by the verifying session.
