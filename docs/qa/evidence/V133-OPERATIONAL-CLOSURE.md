# V133 operational closure evidence

Date: 2026-08-01 (Asia/Singapore)

Scope: owner request “please proceed to close the gaps”, excluding any claim that
provider credentials, legal appointments, production evidence, store signing, or a
new release approval were supplied.

## Independent review and release authority

Sol independently accepted the exact V133 local candidate on 2026-08-02 with no
remaining P0/P1/P2 findings. The owner subsequently instructed “please commit and
push to live” on 2026-08-02, authorising the reviewed V133 commit, push, production
migration and web deployment. This scoped approval does not close the separately
listed provider, store, legal or production-evidence gates.

## Reproduction

The V132 production baseline accepted account-deletion requests and provided a
private Super Admin list RPC, but no operator could claim or resolve a request and
the Platform console exposed no queue. The red-first V133 suite failed 0/3 because
the V133 migration and queue renderer did not exist.

The repository launch gate also truthfully reports 17 P0 blockers and zero with
production-grade closure evidence:

```text
P0 total: 17
P0 proven closed: 0
P0 blocked: 17
manifest validation issues: 0
```

## Implemented boundary

- System health renders a private deletion-request queue with pending, processing,
  completed, due and overdue states; no email or phone is projected.
- Pending requests have one **Claim request** action. Any current Super Admin can
  complete a processing request, so an unavailable claimant cannot strand it.
  Expired legal retention has one **Review retention** action; other completed
  requests have no writer.
- A resolution modal says explicitly that it records a reviewed outcome and does
  not delete data. The operator must first complete the controlled privacy runbook.
- Outcomes are limited to deleted where permitted, anonymised where permitted,
  retained under legal obligation, or invalid after identity review. Legal
  retention requires a future deadline; every outcome requires an evidence
  reference and reason.
- Claim, resolution and retention review are Super Admin only, serialized and
  exact-replay idempotent. The browser reuses the same key for the same payload
  after a lost response, and each database event stores the original immutable
  result snapshot rather than replaying newer request state.
- Event update/delete/truncate is trigger-blocked, including privileged access;
  direct `service_role` table access is revoked. Stable operator UUID evidence is
  retained even if the corresponding Auth account is later removed.
- The queue is bounded at 100 rows per page, returns an exact total, and exposes a
  **Load more privacy requests** path so request 101 cannot be hidden.
- Completed legal retention becomes due at `retention_until`; a reviewed follow-up
  must either record deletion/anonymisation or set another future legal deadline.
- Customers see their reviewed completed disposition and any retention-review
  date after refresh instead of being offered a second deletion request.
- Migration preflight aborts with an explicit count if legacy processing/completed
  requests lack the new reviewed lifecycle evidence.
- V133 contains no `DELETE FROM auth.users` and no public-table delete statement.

## Automated evidence

```text
node --test tests/platform-console/v133-operational-closure.test.mjs
6 tests, 6 pass, 0 fail
```

Canonical migration preflight passes with 45 catalog + 127 pending migrations and
172 unique deploy files. The V133 source and Supabase mirror are byte-identical.

The complete repository gate passes after the change:

```text
EXPECTED_SUPABASE_PROJECT_REF=gadpooereceldfpfxsod npm run validate
1,387 tests, 1,387 pass, 0 fail
Static build validation passed for all six deployable app entry files.
```

The final migration was applied only to the isolated Supabase project
`wtegnefsgnyxhflzizcu` (`migration-rehearsal`). Because that branch already held
the superseded V133 rehearsal candidate, a rehearsal-only removal migration first
returned those V133 objects to the V132 shape; production was not touched.
`db/tests/v133_operational_closure.sql` completed inside `BEGIN ... ROLLBACK` and
proved:

- non-Super-Admin queue denial;
- exact claim/resolution replay, including a claim replay after later resolution
  and a retained receipt replay after its deadline;
- changed-payload rejection under a used key;
- required future deadline for legal retention;
- another current Super Admin can complete a claimed request;
- expired legal retention is due and can be reviewed into a new future deadline;
- 101 actionable requests paginate 100 + 1 with an exact total;
- subject-only reviewed disposition projection;
- private event-table denial;
- update/delete/truncate immutability and service-role write denial;
- exactly one claim plus one resolution event; and
- all five synthetic Auth users remained present.

## Browser evidence

The browser loaded `tests/browser/v133-operational-closure-visual.html`, which
imports the current `app/platform-console.js` rather than a copied renderer.

At 1440px, the platform fixture:

- ready state `true`; four requests; one claim, one outcome and one retention-review action;
- overdue state visible; action heights approximately 58px;
- opens **Review legal retention** with no invalid-request option;
- `scrollWidth = clientWidth = 1440`.

At 390px, the platform fixture:

- ready state `true`; four requests and one retention-review action;
- action heights 44px and approximately 58px;
- resolution modal width 390px; every input/button is at least 44px high;
- the evidence-reference hint renders as readable copy with no raw interpolation;
- `scrollWidth = clientWidth = 390`.

The 390px error fixture keeps reconciliation visible, shows one **Retry privacy
queue** action, and makes no empty-state claim. The empty fixture shows **No account
deletion requests**, exposes zero claim/outcome actions, and has no horizontal
overflow.

The generated V131 fixture executes the exact account-deletion component extracted
from current `app/index.html`. At 1440px the retained outcome shows **Deletion
request reviewed** and its retention-review date with no second request form. At
390px the deleted outcome shows **Deleted where permitted**, the dialog is 390px,
controls remain at least 44px, and there is no overflow or second request form.
After a fresh retained-state navigation the reviewed outcome remains visible. The
load-error state says no request was created and its retry repeats the safe status
read without exposing a request form.

## Remaining gates

V133 closes only the reproducible in-repository deletion-operations gap. It does
not prove the whole app release-ready. Still required:

1. authenticated target browser sweep for every named role and module;
2. fresh provider OTP/passkey and QR-join evidence;
3. target appointment -> checkout -> reward -> customer refresh evidence;
4. WhatsApp Business provider, approved templates, consent and receipts for
   automatic delivery (the current manual `wa.me` path remains truthful);
5. named monitored support/alert owner plus backup/PITR restore rehearsal;
6. counsel review and formal DPO/privacy-operations appointment;
7. Apple/Google signing and physical-device/store evidence; and
8. live Stripe catalogue and provider payment lifecycle.

No production migration, production data, secret, commit, push, merge, or deploy
was performed in this phase.
