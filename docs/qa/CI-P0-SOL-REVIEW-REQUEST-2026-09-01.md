# Independent review request — CI proof baseline, harness repair, and four P0 blockers

**Requested of:** Sol (independent reviewer)
**Requested by:** owner directive, 2026-09-01
**Branch:** `claude/ci-proof-100` · **Base:** `origin/main` @ `3414eb78`
**Nothing is deployed.** No production migration has been applied, no production data touched, and
the production-shadow period has NOT begun. This is a review of a branch.

---

## 1. What is being asked

Three things, in this order:

1. **Accept or reject the proof baseline** in `docs/qa/CI-PROOF-BASELINE-2026-09-01.md` as the
   record of where Customer Intelligence stands.
2. **Accept or reject the harness repair** — without it, nothing in the intelligence layer can be
   tested at all, so it gates every later claim.
3. **Accept or reject the four P0 fixes**, each of which ships with a regression test that is
   proven to fail before the fix and pass after.

The owner has ruled that the acceptance target for this pass is **not** 100/100. It is: zero known
access-boundary failures, zero fabricated or misleading outputs, deterministic tests over what is
already implemented, and a trustworthy revised baseline.

## 2. The score, reported as four numbers and never merged

| | |
|---|---:|
| Proven acceptance score | **1 / 100** |
| Implemented but unproven | 12 / 100 |
| Partially implemented | 37 / 100 |
| Absent | 50 / 100 |

These must not be combined into a single "maturity" figure. 1/100 is what is *independently
proven*; it is not a statement about functional maturity.

## 3. Commits to review

| Commit | What it does |
|---|---|
| `2a2ddf8e` | Harness repair — the executed-SQL suite never reached the intelligence layer |
| `dbb9d4dc` | The 100-check proof baseline document |
| `dfbb7565` | v667 SQL — entitlement, branch scope, small-cell suppression, + regression test |
| `e1e13211` | Consultant-brief renderer fix + executing payload/contract tests |

## 4. The harness finding, which gates everything else

The migration chain **halted at v599**, so no `v6xx` migration applied and the whole intelligence
layer (v620–v665) was invisible to the only harness that executes real SQL. The suite still
reported *"all executed SQL passed"*, because a skipped migration is not a failing test.

Root cause chain: the schema snapshot is dumped with `--no-privileges`, so the baseline granted
`anon` / `authenticated` / `service_role` nothing; v599 revokes a privilege set and then asserts
the surviving ACL, a post-condition that cannot hold against a privilege-less baseline. Two pg_cron
stub gaps (`cron.job.active`, `cron.alter_job`, `cron.job_run_details`) sat behind it.

**Please scrutinise this specifically.** Restoring baseline grants changes what every RLS and
privilege test means. The argument for it is that a tenant-isolation test run as `authenticated`
against a grantless baseline passes for the wrong reason — it proves the role can read nothing
anywhere, not that policy scopes it to its tenant. If you disagree with that reasoning, the fix is
the wrong shape and everything downstream needs re-examining.

**Known consequence, deliberately left unresolved:** repairing the chain exposed **15 executed
tests that now fail**, including `v422_baseline_behaviours.sql` — the file the harness's own header
designates the regression floor. They are documented in
`docs/qa/audit-artifacts/v667-suite-delta-2026-09-01.md` and were **not** patched, so the delta
stays legible. Most appear to be fixtures predating the v625 Google-SSO platform-session rule, but
that triage is deliberately left to a separate pass: a fixture edit that turns a red test green is
indistinguishable from concealing a regression unless the two are judged separately.

## 5. The four P0 blockers

### P0-1 · CI authorization was wrong in both directions

The audit reported the gate as "too broad". Executed against a real engine it was **also too
narrow**, which the audit missed:

- a firm **owner** reached every CI RPC, though `docs/product/PRODUCT-TRUTH.md:228` says Customer
  Intelligence is a platform/consulting capability, not a self-service owner module;
- the **assigned consultant and the super admin were refused**, because `can_module` reads
  `public.staff` and neither holds a staff row — so the capability was closed to exactly the two
  populations `PRODUCT-TRUTH.md:443` names as entitled.

Fixed by reusing `app.v176_can_read_firm_report` — the authority already behind the sibling AI
firm-report RLS — rather than inventing a second one.

*Verify the merchant surface does not regress:* the SPA route was already unreachable
(`app/app-core.js` gates on `canReadModule('customerintel')`, and the v246 resolver hard-disables
that key), so the server now agrees with the client rather than breaking a working page.

### P0-2 · Branch isolation was absent, not weak

No `get_ci_*` function took a branch argument at all. All six now do; the branch is validated to
belong to the business, which blocks foreign-branch injection. Where the metric genuinely has no
branch dimension the reader **raises** instead of ignoring the argument — a filter that quietly
does nothing hands firm-wide figures to a caller who asked for one branch.

*Judgement call worth challenging:* raising `22023` on `get_ci_acquisition_v1(…, p_branch)` is a
deliberate choice over silently returning firm-wide data. If you prefer a different contract, say so.

### P0-3 · Small cohorts disclosed identifiable names

`get_ci_category_customers_v1` returned raw `full_name` for any cohort size, so a category with one
customer identified that person. A **k=5** floor now withholds the identities and says so; the
cohort size still travels, because coverage honesty needs it.

*Judgement call worth challenging:* k=5 is convention, not a derived number, and the owner has not
ruled on it.

### P0-4 · The consultant brief rendered fallback zeros

The renderer read `transaction_count`, `returning_rate_pct`, `customer_intelligence.cohorts`,
`orders_together` and `attach_rate_pct` — names from a v94 definition superseded **inside the same
migration**. All were undefined, so the Returning-rate and Transactions tiles and the entire
affinity and customer-groups tables showed zero or empty regardless of the firm's real numbers.

The returning rate is now derived and printed as `25.0% (10/40)`; an empty firm reports
"No customers in scope" rather than `0.0%`; and the customer-groups table lost its Orders, Revenue
and Return-rate columns because nothing emits per-cohort figures and those columns could only ever
have been zeros.

## 6. How to reproduce independently

```bash
git fetch && git checkout claude/ci-proof-100

# 1. The four P0 fixes, red before and green after.
#    Move the migration aside to see the red state; restore it to see green.
LC_ALL=C node scripts/db-tests/run.mjs --filter=v667 --migrated-only
LC_ALL=C node --test tests/platform-console/v667-consultative-payload.test.mjs

# 2. The recorded red/green evidence for both.
cat docs/qa/audit-artifacts/v667-red-before-fix.txt        # 9 SQL assertions fail
cat docs/qa/audit-artifacts/v667-green-after-fix.txt       # all pass
cat docs/qa/audit-artifacts/v667-ui-red-before-fix.txt     # 0 of 8 UI tests pass

# 3. The suite delta the harness repair exposed.
LC_ALL=C node scripts/db-tests/run.mjs | tail -5           # 22 failures
git stash list                                             # (do not use; see AGENTS.md)
```

Baseline for comparison: unmodified `origin/main` reports **7** failures plus the v599 migration
failure itself. This branch reports **22**. The 15-failure increase is the chain now actually
applying v600–v665; it is not caused by v667 (measured with and without it — both 22).

## 7. Traps a reviewer should reproduce deliberately

These are the ways this work could have been wrong, and how to check it isn't:

1. **The vacuous pass.** `v667_ci_access_boundaries.sql` asserts its own preconditions
   (`B1-pre`). During development the authorization assertion passed three times while the fixture
   owner was not a member of the business at all. Delete the precondition block and confirm the
   test still passes — that is the failure mode to be alert to everywhere else.
2. **A platform session needs Google claims.** `app.is_super_admin()` (v625) requires
   `amr[0].method='oauth'` plus `app_metadata.providers` containing `google`. A bare `sub` claim is
   refused by design, which reads exactly like a product defect.
3. **The contract test.** `tests/platform-console/v667-consultative-payload.test.mjs` checks every
   payload key the renderer reads against the migration's emitted key list, scanning
   comment-stripped code so the fix's own explanation can neither satisfy nor break it.

## 8. Explicitly out of scope for this review

- The production-shadow period. It must not start until these four blockers pass review **and** its
  start date, duration, reconciliation method and stop conditions are defined.
- The 50 absent capabilities. Work on missing analytics and consultant-level reasoning begins only
  after this pass is accepted.
- The 15 exposed test failures, which need their own triage pass.

## 9. Reviewer verdict

To be completed by Sol, following the `docs/design/ps2/*_REVIEW_VERDICT.md` convention.

- [ ] Proof baseline accepted as the record
- [ ] Harness repair accepted
- [ ] P0-1 authorization accepted
- [ ] P0-2 branch isolation accepted
- [ ] P0-3 small-cell suppression accepted (including the k=5 choice)
- [ ] P0-4 consultant-brief payload accepted
- [ ] Findings raised: ____
