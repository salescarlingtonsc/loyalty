# nestly_v951 — correction to its own header, and the guard that replaced it

## The correction

The v951 migration header names a "fourth group this migration does NOT close", and lists
`get_billing_reconciliation_v77`, `get_platform_billing_v77`, `platform_get_finance_v146`,
`platform_get_catalogue_affinity_v94`, `preview_growth_recommendation_v108`,
`business_list_media_cleanup_queue_v95` and `platform_get_subscription_operations_v156` as passing
`limit p_limit` with "no clamp and no validation at all".

**That is wrong.** Every one of them validates before it reads, with an explicit raise:

| function | bound |
|---|---|
| `business_list_media_cleanup_queue_v95` | `if p_limit not between 1 and 100 then raise` |
| `get_billing_reconciliation_v77` | `1 and 200` |
| `get_platform_billing_v77` | `1 and 250` |
| `platform_get_catalogue_affinity_v94` | `1 and 100` |
| `platform_get_finance_v146` | `1 and 5000` |
| `platform_get_subscription_operations_v156` | `1 and 500` |
| `preview_growth_recommendation_v108` | `coalesce(p_limit,0) not between 1 and 200` |

The classification that produced that paragraph came from a regex looking for `least(` and for
`greatest(coalesce(p_limit`. A function that validates with `if p_limit not between 1 and N then
raise` matches neither, so it was bucketed as "NO CLAMP FOUND" and then read as "unbounded". The
bucket meant "my pattern did not match", not "this function is unbounded", and the header states
the second when the evidence only supported the first.

The migration file itself is left exactly as applied — it is a record of what was executed, and
rewriting an applied migration to fix its prose would break the byte-pinned manifests and put the
repo out of step with the deployed catalog. This note is the correction; the note is what the next
reader should believe where the two disagree.

## What was actually unbounded

Three functions, all fixed by v951, and they were the only ones:
`get_notifications`, `business_support_get_thread_v531`, `business_support_list_conversations_v531`.

A re-scan of every function in `public` and `app` taking a `p_limit` — classifying by clamp shape,
by validating raise, by delegation to a bounded callee, and by whether `authenticated` holds
EXECUTE — found **nothing else reachable from a browser that is unbounded**. The four that looked
unvalidated (`platform_get_billing_v125`, `platform_get_consultative_recommendations_v94`,
`platform_get_sme_analytics_v510`, `suggest_appointment_staff_v47`) are thin wrappers whose callee
does the bounding: `platform_get_billing_v89` (1..250), `platform_get_catalogue_affinity_v94`
(1..100), `platform_get_sme_analytics_v86` (`least(...,200)`) and
`suggest_appointment_staff_v47_v94_base` (1..10) respectively.

## What replaced the prose

GUARD 4 in `tests/phase0-foundation/pending-migration-hardening-guards.test.mjs`. It folds the
ordered migration chain to the SURVIVING definition of each function — last write wins, a drop
removes it — and refuses any surviving definition where `p_limit` reaches a `limit` clause with no
ceiling and no validating raise. Three bound shapes are accepted, because all three are real and in
use: a `least(...)` ceiling, a validating raise, and delegation to a callee that does one of those.

Cron and service_role sweeps are exempt **by name** in `PAGE_SIZE_BOUND_EXEMPT`: there `p_limit` is
an operator's batch size per run, not a page size a caller chooses, and capping it would be a
behaviour change dressed as a security fix. None of them is reachable by `anon` or `authenticated`.

The guard is proven non-vacuous: reverting v951's three caps in the repo makes it fail, naming
exactly those three functions and the migration they were last defined in.
