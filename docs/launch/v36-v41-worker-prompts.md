# Frenly v36-v41 Worker Prompts

Status: READY FOR DISPATCH AFTER CODE-EDIT AUTHORITY IS ACTIVE

These prompts are subordinate to `docs/launch/v36-v41-remediation-contract.md`.
Workers must use disjoint file scopes, work locally, and never apply production
migrations, deploy, commit, or push. Sol reviews every patch before integration.

## Terra - v36 and v37 configuration integrity

```text
You are Terra implementing Frenly v36-v37 locally in
/Users/cs/Downloads/loyalty-main. Read CLAUDE.md,
docs/design/CONFIGURABILITY_BLUEPRINT.md,
docs/launch/v36-v41-remediation-contract.md, v21, and migrations v26-v29 first.

Your write scope is limited to:
- new v36-v37 migration files;
- matching db/tests/v36*.sql and db/tests/v37*.sql;
- tests/phase2-config/;
- the loyalty, retention, and branch editor sections of app/index.html;
- the two v21 authenticated RPC allowlists when required.

Implement:
1. owner-only get_loyalty_reward_draft(uuid) with exact-version output, fixed safe
   search_path, authenticated-only ACL, v21 registration, active-only ordinary
   reward-version RLS, and optimistic snapshot-hash concurrency;
2. draft UI reads keyed by stable reward_id, no direct draft child-table queries,
   explicit unrestricted eligibility, stale-hash recovery, and no lost form state;
3. immutable retention_program_versions backfill and draft/publish projection;
4. version-aware retention resolution from the sale's stamped config;
5. owner-only branch override draft RPCs and a simple inherit/override editor;
6. editable taxonomy labels/sort/retirement while fulfillment_kind stays immutable.

Never drop or replace an object before inspecting it. Never use DROP CASCADE. All
new SECURITY DEFINER functions must deny PUBLIC/anon and use the v21 allowlist rules.
Do not weaken ledger guards, RLS, or historical snapshots.

Add substantive rollback tests for tenant denial, draft/published immutability,
eligibility preservation, stale writes, publish concurrency, retention backfill,
branch precedence, and rollback-as-new-version. Static regex tests are supplementary.

Run focused Node tests, npm run validate, and git diff --check. Report changed files,
exact test output, unresolved runtime assumptions, and no production actions.
```

## Luna - v38 customer identity, claims, and personas

```text
You are Luna implementing Frenly v38 locally in
/Users/cs/Downloads/loyalty-main. Read CLAUDE.md, Part C in
docs/design/CONFIGURABILITY_BLUEPRINT.md, the v36-v41 remediation contract, and
migrations/tests v30-v33 first.

Your write scope is limited to:
- one new v38 migration and db/tests/v38*.sql;
- tests/customer-wallet/ identity/persona/claim tests;
- routing, authentication, claim, persona, and signed-in portal sections of
  app/index.html;
- the two v21 authenticated RPC allowlists.

Implement get_my_personas() with allowlisted output, #/claim, identity creation,
exact-email and opaque-invitation claims, unlink, dual-role switching, workspace/wallet
route selection, and optional signed-in state on /b/{slug}. A signed-in public portal
must still use the public gateway, Turnstile, rate limits, and booking policy.

Do not expose raw identity/link/client tables. Never accept client_id, identity_id, or
business_id as customer authority. Derive scope from auth.uid() and verified links.
Names and phones are never claim proof. Remove invitation secrets from browser history
immediately and never log them. Mutations require idempotency and generic outcomes.

Keep customer email OTP and wallet release fail-closed until SMTP and operations gates
are accepted, but replace normal hard-coded feature enablement with server-derived
capabilities plus an emergency build kill switch.

Add rollback tests for customer-only, staff-only, dual-role, duplicate email candidates,
invitation expiry/replay/theft, unlink, cross-business denial, ACLs, safe search paths,
and raw-table denial. Add route-state tests covering every loading/empty/error outcome.

Run focused Node tests, npm run validate, and git diff --check. Report changed files,
exact results, unresolved runtime assumptions, and no production actions.
```

## Luna - v39 detailed wallet

```text
You are Luna implementing Frenly v39 after Sol accepts v38. Read the accepted v38
patch and docs/launch/v36-v41-remediation-contract.md.

Your write scope is limited to:
- one new v39 migration and db/tests/v39*.sql;
- wallet-related tests/customer-wallet/ files;
- renderCustomerWallet and its styles in app/index.html;
- the two v21 authenticated RPC allowlists.

Implement cursor-bounded customer_get_loyalty_details,
customer_get_reward_catalog, customer_get_packages, and
customer_get_memberships. Every RPC derives one verified relationship from auth.uid()
and slug, returns explicit customer-safe columns, and denies raw-table access. Never
return internal reward costs, client contacts/notes, staff data, payment internals, or
cross-firm totals.

Render only enabled and relevant sections: Rewards, Activity, Packages, Membership,
Appointments, and Book. Each has loading, empty, denied, retryable error, and mobile
states. Do not add customer self-redemption unless its fulfillment and reversal journey
is complete; otherwise use a counter-claim presentation.

Prove Customer A/B isolation, pagination bounds, capability hiding, no empty modules,
column allowlists, dual-role separation, ACLs, and mobile layout. Run focused tests,
npm run validate, and git diff --check. No production actions.
```

## Terra - v40 staff reversal workflows

```text
You are Terra implementing Frenly v40 after Sol accepts v36-v39. Read v20-v22, v34,
their SQL suites, and docs/launch/v36-v41-remediation-contract.md.

Your write scope is limited to:
- a new v40 migration only if a bounded read/detail RPC is required;
- db/tests/v40*.sql and tests/financial-integrity/;
- sale/customer/package/redemption history and report/export sections of app/index.html;
- the two v21 allowlists if a new RPC is added.

Build permission-aware UI over reverse_sale and reverse_loyalty_redemption. Never write
sales, ledgers, batches, packages, or provenance tables directly. Require a reason,
stable idempotency key, confirmation, and explicit result. Show no-payment-refund for a
package-session reversal, refusal reasons for impossible loyalty compensation, completed
reversal links, replay success, and changed-request conflict. Remove stale text saying
reversals are deferred. Reports and CSV must represent reversals and net values.

Prove branch scope, owner/manager/authorized staff, inactive/unauthorized denial,
customer/anon denial, exact replay, conflict, package restoration, loyalty compensation,
and ledger/batch reconciliation. Run v20-v22, v34, focused Node tests, npm run validate,
and git diff --check. No production actions.
```

## Sol - v41 acceptance

```text
Review and integrate only after each worker returns green focused tests. Inspect every
changed SECURITY DEFINER ACL, tenant predicate, immutable guard, projection, frontend
call, and substantive test. Reject source-pattern-only evidence for runtime behavior.

Build a disposable production-equivalent Singapore database from a reviewed executable
baseline. Apply the complete chain once; run v20-v41 rollback suites, v21 all-schema ACL
inventory, adversarial principals, and concurrency harnesses. Run desktop/mobile browser
journeys listed in the remediation contract, including disabled feature gates. Run
npm run validate and git diff --check.

Return PASS only if every contract item has direct evidence. Do not apply production
migrations, deploy, commit, or push as part of acceptance.
```
