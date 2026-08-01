# V132 release-gap closure

Date: 1 August 2026
Baseline: `9da60cb10aa3c668df114158d20eab518bc6ecf3`
Requirement: `RELEASE-GAP-001`
State: `VERIFIED_DATABASE`

## Reproduction

The existing non-production Supabase `migration-rehearsal` schema was manually
advanced from its stale V122 ledger by applying the already-reviewed V123–V131
sources in order after automatic rebase failed on the duplicate V122 identity.
Its branch metadata therefore still reports that failed rebase even though the
database is healthy. The rehearsal ledger contains 172 rows because both the
first V132 rehearsal and its corrective re-run are retained; the canonical
repository has one V132 end-state migration. V129 passed. V130 then
failed at the matching paid-invoice
case with `owner loyalty configuration access required`: the provider trigger
inserted a draft loyalty programme, whose immutable-version seed correctly
called the C45 owner/module writer guard, but no owner claim existed in the
provider transaction. V131 separately showed that its rollback harness tried
to count the private deletion queue while still running as `authenticated`.

## Correction

- V132 replaces the paid-activation trigger function and checkout reader, and
  adds an authoritative private Loyalty-bundle guard.
- It retains the complete exact paid-invoice, price, cadence, capacity, SGD,
  no-GST, amount and subscription match.
- It returns only published sector bundles containing the included Loyalty
  module, rejects forged non-Loyalty staging through a private insert trigger,
  and aborts migration if an incompatible payment-pending row already exists.
- It verifies the onboarding row's owner is still one active owner staff row.
- Only for the idempotent draft-preset insert, it supplies that locked owner as
  the transaction-local Auth claim, then restores both prior claim settings.
- It changes no C45 predicate, RLS policy, table grant or public RPC grant.
- The V130 negative test recognizes V125's stronger immediate non-zero-tax
  trigger rejection only by its exact error text; unrelated check violations
  remain failures. The V131 harness restores the privileged role for private
  state inspection and deliberately re-enters `authenticated` for denial.

## Executed evidence

- Non-production Supabase branch contains the canonical end state through V132;
  its rehearsal ledger has 172 rows because it retains the corrective V132
  re-run as a separate audit entry.
- `db/tests/v129_trial_test_ux.sql`: PASS / ROLLBACK.
- `db/tests/v130_self_serve_business_onboarding.sql`: PASS / ROLLBACK.
  This includes a published dashboard/clients-only sector which is absent from
  the plan list and whose forged setup leaves no business or staff row.
- `db/tests/v131_store_publication_readiness.sql`: PASS / ROLLBACK.
- Post-suite residue: zero synthetic Auth users, zero V130 businesses and zero
  account-deletion requests.
- Supabase advisors report no newly introduced public RPC or browser grant;
  the replaced checkout reader retains its authenticated-only `EXECUTE`
  boundary. V130/V131 definer RPC notices describe intentional authenticated
  boundaries covered by the executed outsider/anonymous tests.
- Focused migration/V130/V131 suite: 31/31.
- `EXPECTED_SUPABASE_PROJECT_REF=gadpooereceldfpfxsod npm run validate`:
  1,381/1,381 plus static build.

Production migrations, data, functions, secrets and deployment were not
changed.

## Independent review

Sol independently accepted the current V132 diff with no remaining P0/P1/P2
findings after verifying the byte-identical migration mirrors, 19/19 focused
manifest/security checks, exact provider/no-GST matching, locked-owner claim
restoration, C45/RLS/ACL preservation, the non-Loyalty regression and the V131
role-denial correction. The apparent pending legacy module-mutation path is
already denied because the current V94 owner predicate requires an open
workspace, while a payment-pending V130 workspace is closed.

The owner subsequently gave the exact V132 release approval on 1 August 2026
for commit, push, production migrations V129–V132, the reviewed function and
web production deployment. This evidence remains `VERIFIED_DATABASE` until
those live steps and their post-deployment checks succeed.
