# Peekaa Customer Intelligence — the 100/100 proof checklist (owner's text, verbatim)

> Recorded 2026-09-02 from the owner's message of 2026-09-01 so that every scorer, refuter and
> evidence map uses ONE numbering. The wording below is the owner's; nothing has been edited.
> Scoring rule (owner): a check earns its point only with reproducible executed evidence;
> source-inspection or regex tests count zero. Checks 80, 99 and 100 need people or a calendar
> and are reported as EXTERNAL until they happen.

Peekaa Customer Intelligence — 100/100 proof checklist
Use this as a release gate, not a feature wish list. A checkbox earns 1 point only when it has reproducible evidence. “Implemented,” “looks correct,” or “test exists” is not enough.
For every item, retain:

* Synthetic input dataset and expected answer.
* Exact query/RPC version.
* Actual machine-readable result.
* UI/report screenshot or rendered output.
* Numeric reconciliation.
* Test command and passing output.
* Evidence date, commit SHA and environment.
* Named independent reviewer.

100/100 requires all 100 checks, every hard gate, and independent Sol acceptance. Partial credit does not count as proof.
A. Data truth and metric correctness — 10 points

* 1. Canonical transaction population. Every report defines precisely which sales are included: completed, positive residual, reversal/refund treatment, date boundary, branch and generated-at cutoff.
* 2. Recorded versus total revenue. UI always says “Peekaa-recorded revenue” unless a reconciled source proves complete merchant revenue.
* 3. Identified versus anonymous revenue. Report returns both amounts, both transaction counts and identified coverage. They reconcile exactly to recorded totals.
* 4. Visit versus transaction separation. Multiple transactions during one real visit cannot silently create multiple visits or repeat customers.
* 5. Refund and reversal correctness. Full reversal, partial external refund, late refund and refund outside the reporting window produce expected signed results.
* 6. Package-session revenue correctness. Package purchase records fresh revenue once; session consumption records utilisation/visit activity without duplicating package revenue.
* 7. Zero-value event correctness. Reward, package and complimentary visits are never counted as revenue unless a genuine payment exists.
* 8. Time boundary correctness. 23:59/00:00 Singapore time, report-end cutoffs, backdated records and branches with different future timezones are tested.
* 9. Immutable snapshot correctness. Pagination, exports and drill-downs use one cutoff; activity created during pagination cannot alter the report midway.
* 10. Golden reconciliation suite. At least 100 synthetic businesses covering every supported sector reconcile all headline metrics exactly to independently calculated expected values.

Required proof: ≥99.9% row-level reconciliation and ≥95% of all testable factual metrics exact, with every discrepancy explained and fixed.
B. Metric definitions, evidence and traceability — 10 points

* 11. Versioned metric dictionary. Revenue, visit, new, repeat, returning, reactivated, retained, lapsed, LTV and ATV each have one canonical definition.
* 12. Numerator and denominator. Every percentage exposes both, e.g. `53 returns / 87 eligible customers = 60.9%`.
* 13. Observation period. Every result shows inclusive/exclusive date semantics, timezone and as-of time.
* 14. Comparison baseline. Every comparative claim names the comparison population or earlier period and shows its value.
* 15. Coverage. Every customer-derived claim shows identity coverage; every service/product claim shows itemisation/classification coverage.
* 16. Exclusions. Reversals, synthetic customers, anonymous transactions, missing demographic fields, overlapping campaigns and other exclusions are countable and visible.
* 17. Evidence classification. Every conclusion is explicitly marked `DIRECT FACT`, `ASSOCIATION`, `ESTIMATE` or `CAUSAL EVIDENCE`.
* 18. Confidence classification. `Strong`, `Moderate`, `Early signal` and `Insufficient evidence` are produced by documented rules, not model prose.
* 19. Record-level lineage. Authorized users can drill from insight → contributing cohort → transactions/appointments/events without changing scope.
* 20. Reproduction identifier. Every insight has an immutable trace ID containing query version, input scope, cutoff and evidence hash.

Required proof: Pick any 50 insights; an independent reviewer must reproduce all 50 from the underlying facts.
C. Executive understanding and pattern discovery — 10 points

* 21. Five-issue executive answer. “Five most important things” returns ranked business issues, not five large metrics.
* 22. Cross-domain candidate generation. The ranking considers retention, cadence, service, staffing, discounts, loyalty, campaigns, packages, acquisition and data quality.
* 23. Materiality threshold. Small but statistically unusual patterns do not outrank commercially meaningful ones without justification.
* 24. Comparison requirement. No pattern is promoted without a baseline: business average, prior period, comparable cohort or control.
* 25. Business-impact translation. Each pattern explains the affected customers, revenue, margin, capacity or retention risk.
* 26. Unexpected-pattern discovery. The system can surface a non-predefined but reproducible relationship from a held-out test dataset.
* 27. Random subgroup protection. Discovery controls subgroup count, false-discovery risk and repeated slicing.
* 28. Negative-trend detection. The system detects worsening frequency, retention, segment size, acquisition quality and service performance.
* 29. Contradictory metric handling. It distinguishes loyal, frequent, retained, high-LTV, at-risk and strategically important customers.
* 30. Data-quality issue ranking. A severe coverage or classification problem can correctly outrank a business recommendation.

Required proof: On a blinded synthetic business, at least 9 of the top 10 ground-truth issues must appear, with no fabricated top-five issue.
D. Demographic, time, service and staff intelligence — 10 points

* 31. Demographic revenue. Age/gender revenue is reported among identified customers with demographic and revenue coverage.
* 32. Demographic frequency and ATV. Age/gender groups can be compared on visits, cadence and transaction value with denominators.
* 33. Demographic service preference. Preference uses meaningful share or lift against baseline, not raw purchase count alone.
* 34. Demographic return behaviour. The women aged 25–30 facial test returns cohort definition, window, numerator, denominator, customers, observations, baseline, difference, period, coverage and confidence.
* 35. Daypart authority. Every time analysis states whether it uses scheduled appointment, arrival, service start, sale or payment time.
* 36. Busiest versus most valuable. Visit volume, revenue, revenue/visit and capacity utilisation are separately calculated.
* 37. Weekday/weekend preference. Customer segments are compared using rates and exposure/opportunity denominators, not counts alone.
* 38. Service intelligence. Gateway service, repeat behaviour, next purchase, natural cadence, promotion dependency and customer-value association are available.
* 39. Staff identity authority. Booked staff, assigned staff, actual provider, credited staff and till operator are separately recorded.
* 40. Mix-adjusted staff performance. Staff comparisons adjust for customer, service, branch, tenure and time mix and show adjusted and unadjusted results.

Required proof: Confounding fixture where Alice handles premium services must not produce an unsupported “Alice is best” conclusion.
E. Lifecycle, retention and prediction — 10 points

* 41. First→second conversion. Eligible first visits and qualifying second visits have an explicit window and denominator.
* 42. Second→third conversion. Calculated separately from first→second.
* 43. Bottleneck diagnosis. The larger lifecycle loss is identified numerically and recommended actions address that stage.
* 44. Fixed-window retention. 30/60/90/180/365-day retention is cohort-based and maturity-adjusted; immature cohorts are excluded or censored.
* 45. Customer-specific cadence. Median interval, dispersion, number of intervals and evidence source are stored and visible.
* 46. Service/segment cadence. Meaningful service and cohort intervals exist as fallbacks, with minimum evidence gates.
* 47. Overdue versus approaching. Customers already outside cadence are separated from those nearing their likely window.
* 48. Customer A/B test. A with a 7–10-day rhythm and 20 days inactive is higher risk than B with a 50–65-day rhythm and 20 days inactive.
* 49. Return-probability calibration. Predicted 30-day return probabilities are tested against observed outcomes using calibration and discrimination metrics.
* 50. Prediction abstention. Sparse-history, shifted-distribution or low-coverage cases return “insufficient evidence,” not a plausible-looking probability.

Required proof: Prediction evaluation must use temporally held-out data; training-period fit is not acceptance evidence.
F. Rebooking, loyalty, discounts, marketing, acquisition and packages — 10 points

* 51. Rebooking event authority. The system records that a next appointment was created before departure, with appointment/provider/service provenance.
* 52. Rebooking comparison. Rebooked and non-rebooked cohorts show sample, return window, retention difference and composition.
* 53. Rebooking causality wording. Observational results never become “rebooking caused retention” without valid experimental evidence.
* 54. Loyalty programmes separated. Points, tiers, stamps, welcome, birthday, bring-back and referrals are evaluated independently.
* 55. Loyalty incrementality. Participation, redemption, paid return, cannibalisation and causal effect are separate metrics.
* 56. Discount-dependency model. Full-price repeat behaviour, promotion share and return-without-incentive likelihood are calculated.
* 57. No-discount recommendation. Strong organic-return customers receive reminder-only recommendations unless evidence supports an incentive.
* 58. Marketing attribution taxonomy. Contacted, queued, sent, delivered, read, replied, redeemed, associated purchase and incremental effect are never conflated.
* 59. Acquisition authority. Every customer has a governed source or `unknown`; QR, referral, campaign, walk-in, portal, staff, wallet and import sources are mutually defined.
* 60. Package intelligence. Purchase, sessions used, utilisation, consumption speed, unused balance, lapse, repurchase and outside-package spend are correct.

Required proof: A campaign sent to historically best customers must not be credited as causal merely because recipients purchase afterward.
G. Statistical discipline — 10 points

* 61. General minimum-sample rules. All subgroup insights—not only experiments—share centrally enforced sample thresholds.
* 62. Three-of-three trap. A 3-customer subgroup with 100% retention is labelled “early signal/insufficient,” never “best segment.”
* 63. Uncertainty intervals. Rates and differences use appropriate intervals; tiny binary samples do not use misleading Wald intervals.
* 64. Effect size. Results show percentage-point or monetary difference, not significance alone.
* 65. Practical significance. Statistically detectable but commercially trivial findings are not promoted.
* 66. Outlier analysis. Mean, median, percentile range, top-customer share and leave-one-out sensitivity appear when skew is material.
* 67. Seasonality controls. Comparisons use appropriate prior periods or matched calendar windows and disclose unresolved seasonality.
* 68. Confounder checks. Service, staff, branch, customer mix, prior behaviour and competing campaigns are tested where relevant.
* 69. Multiple-testing control. Automated discovery records how many hypotheses were tested and controls false discoveries.
* 70. Missingness sensitivity. Insights are recomputed or bounded under plausible assumptions about anonymous/unclassified records.

Required proof: Statistical routines must pass expert-reviewed fixtures for rare events, extreme rates, skew, Simpson’s paradox and confounding.
H. Recommendation quality and management-consultant output — 10 points

* 71. Typed recommendation contract. Every action contains `WHO`, `WHY`, `WHY NOW`, `ACTION`, `INCENTIVE`, `VALUE`, `EVIDENCE`, `CONFIDENCE` and `LIMITATIONS`.
* 72. Multiple opportunity classes. Ranking compares more than a single hardcoded bring-back action.
* 73. Expected-value method. Expected value is probability-adjusted and cost-aware, or explicitly unavailable.
* 74. Margin protection. Reward, discount, delivery and traceable service/product costs are included before recommending an incentive.
* 75. Action specificity. Recommendations identify an exact cohort, timing, channel and owner/staff action.
* 76. No-action outcome. “Do nothing” and “insufficient evidence” are valid ranked outcomes.
* 77. Alternative actions. The system considers reminder-only, rebooking, service recovery, operational changes and incentives.
* 78. Sensitivity explanation. Each major action states what evidence would reverse or downgrade it.
* 79. Five-action master report. The exact senior-consultant prompt produces five impact-ranked actions covering strengths, failures, leakage, margin, unnoticed behaviour, segments and change.
* 80. Independent recommendation review. Senior business reviewers rate ≥80% of actions defensible and commercially sensible, with zero harmful recommendations.

Required proof: Reviewers must judge recommendations without seeing whether they were human- or AI-produced.
I. Evidence-safe AI generation — 10 points

* 81. Structured evidence first. The model receives validated insight objects, not unrestricted raw tables or dashboard text.
* 82. Schema-constrained output. Model output must conform to the recommendation/evidence schema.
* 83. Numeric claim validator. Every number in generated prose is matched to supplied evidence or validated arithmetic.
* 84. Population validator. Cohort, period, branch and baseline labels in prose must match the underlying evidence object.
* 85. Causal-language validator. Words such as “caused,” “generated,” “lift” and “incremental” are blocked unless causal evidence status permits them.
* 86. Confidence validator. Generated confidence cannot exceed the server-calculated confidence class.
* 87. Limitation preservation. The model cannot omit a material coverage, sample, confounding or freshness limitation.
* 88. Hallucination suite. Adversarial prompts and malformed evidence never produce invented customers, services, campaigns, amounts or explanations.
* 89. Contradiction suite. Separate questions about loyal, frequent, retained, valuable and at-risk customers remain definitionally consistent.
* 90. Model-change regression. Every model or prompt version reruns the full golden corpus and cannot ship if factual or causal performance regresses.

Required proof: Zero fabricated numbers, customers or causal claims across the complete acceptance corpus.
J. Access, tenant safety, UX and operational proof — 10 points

* 91. One supported Customer Intelligence surface. Merchant, consultant and AI-report roles are deliberately defined; no implemented-but-route-blocked ambiguity remains.
* 92. UI/RPC contract validation. Generated TypeScript/JSON schemas or integration tests prove every UI field matches the server payload.
* 93. Consultant report defect closure. Cohorts, affinity support/rate, transactions, returning rate and confidence render their real values—not fallback zeros.
* 94. Tenant isolation. Cross-tenant query, export, drill-down, trace and AI-report attempts return no data.
* 95. Branch isolation. Restricted staff cannot substitute business-wide history or another branch when access fails.
* 96. Privacy and small-cell protection. Sensitive demographic or customer details remain role-scoped; unsafe small groups are suppressed.
* 97. Freshness and stale states. Every report exposes data freshness and refuses to recommend from stale evidence.
* 98. Failure behaviour. RPC failure, partial response, model failure and export failure show explicit unavailable states—never zeros.
* 99. Production-shadow reconciliation. For a defined shadow period, production outputs reconcile against independent calculations without affecting customers or data.
* 100. Independent final acceptance. Sol reviews the frozen commit, proof pack and production-shadow results, reproduces the hard traps, and records `ACCEPTED 100/100`; the owner separately approves any later release.

Mandatory synthetic acceptance corpus
The proof dataset should contain, at minimum:

* A normal repeat customer.
* Customer A with a 7–10-day cadence, 20 days inactive.
* Customer B with a 50–65-day cadence, 20 days inactive.
* Three-person subgroup with 3/3 returns.
* One whale contributing most segment revenue.
* High anonymous-revenue business.
* Missing birth date and gender records.
* Women aged 25–30 facial cohort with a known return result.
* Multiple transactions during one visit.
* Package purchase followed by zero-value session uses.
* Full reversal and partial external refund.
* Staff Alice handling premium services.
* Different booked, actual-provider and till-operator identities.
* Appointment rebooked before departure and appointment booked later.
* Campaign targeting already-high-frequency customers.
* Randomized treatment and holdout with adequate samples.
* Overlapping campaigns.
* Loyalty redemption with no subsequent paid visit.
* Birthday benefit followed by a paid visit.
* Discount-dependent and organic-return customers.
* Imported, QR, referral, portal, walk-in and unknown-source customers.
* Weekday volume leader that differs from revenue/visit leader.
* Service with high acquisition but poor second-visit conversion.
* Service with low ticket but strong repeat cadence.
* Deteriorating cohort hidden by improving overall average.
* Cross-tenant and restricted-branch attack fixtures.

Every expected answer should be predetermined before running Peekaa.
Required proof pack
A 100/100 claim should ship with these artifacts:

1. Frozen commit SHA and migration ledger version.
2. Capability-to-query map.
3. Versioned metric dictionary.
4. Synthetic corpus manifest.
5. Expected-answer file.
6. Machine-readable actual results.
7. Reconciliation report.
8. Statistical-method review.
9. AI factuality and causal-language report.
10. Tenant/branch isolation report.
11. Browser screenshots for all answer states.
12. Failure/abstention screenshots.
13. Test commands and complete outputs.
14. Known-limitations register—empty for hard-gate defects.
15. Independent Sol acceptance record.

Scoring rule

```
Score = number of fully proven checks
Maximum = 100
```

A check scores zero if it is:

* Implemented but untested.
* Tested only by regex/source inspection.
* Correct on one tenant but not the corpus.
* Missing the UI/runtime proof.
* Missing denominator, coverage or lineage.
* Dependent on model instructions without output validation.
* Unable to reproduce from the stored evidence snapshot.

Even at 99/100, the claim is not permitted if the missing point involves tenant leakage, fabricated data, unsupported causality, misleading coverage, small-sample overconfidence, or incorrect financial truth.

you may assign to lower tier models to complete the task for token efficiency. and after the run, you must be able to achieve 100/100. if unsure ask me before proceeding anything
