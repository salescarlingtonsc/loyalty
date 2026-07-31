# V120 staff blocked-time acceptance

Date: 2026-07-31
Scope: local feature branch, with owner-authorized release pending production evidence
Issue: `APPT-BLOCK-001`
Release authorization: **owner supplied `RELEASE APPROVED push and deploy` on 2026-07-31**

## Outcome

Appointments now owns one-off staff blocked-time authoring without adding a
module or navigation destination. An authorised owner/front-desk user can add,
reload, view, and remove a block in the Day calendar. The same durable records
are consumed by calendar availability, appointment booking/rescheduling guards,
and scheduled-capacity reporting.

This evidence supports `VERIFIED_LOCAL`, not `VERIFIED_BROWSER`,
`VERIFIED_DATABASE`, or release approval. The database runs below use a
disposable local PostgreSQL 17 rehearsal database, not the target environment.
The screenshots use a deterministic synthetic browser fixture, not
authenticated target sessions.

## Reproduction and fixture

V118 reproduced the gap: the Day calendar projected branch hours, staff hours,
leave, and recurring branch breaks, but there was no time-specific block
entity, writer, loader, or authoring control. The acceptance fixture is
`SPA-GLOW` Orchard on 31 July 2026:

- Chen Wei and Aisha Rahman are active branch staff;
- Spa Ritual 60 uses its configured before/after buffers;
- Chen has “Supplier training” from 14:00–15:00;
- an adjacent 15:00 appointment remains visibly distinct;
- cross-branch blocks appear only as “Busy at another branch”.

## Local implementation contract

- `app.staff_blocked_times_v120` is RLS-protected and has no direct browser-role
  table access.
- Create/delete RPCs use stable request keys and immutable request hashes so a
  lost response replays the prior result and key reuse with different input is
  rejected.
- Staff-calendar advisory locks serialize block and appointment writers across
  branches. Delete also locks the block identity.
- Availability includes service before/after buffers, rejects appointments and
  blocks across all assigned branches, and fails closed when branch or staff
  hours are missing.
- The appointment trigger is ordered after default-branch assignment, so direct
  appointment writes cannot bypass blocked-time enforcement.
- Other-branch blocks are listed as redacted busy intervals: no block ID,
  reason, or remove action is exposed.
- Delete audit records retain staff, branch, start/end, and reason.
- Reports subtract the union of persisted blocks and recurring breaks for active
  staff, avoiding double subtraction; full-day leave contributes no capacity.
- Effective module projections are fetched again on each route/branch load, so
  another session's permission downgrade is not retained by an indefinite
  browser cache.

## Automated evidence

The V120 application, migration, fixture-approval, concurrency-harness, durable
memory, and responsive-layout contract passes **10/10**:

```text
node --test tests/appointments/v120-staff-blocked-times.test.mjs
```

The complete local validation passes **1,305/1,305** tests plus quality,
runtime configuration, migration manifest, canonical materialisation, and
static build checks:

```text
EXPECTED_SUPABASE_PROJECT_REF=gadpooereceldfpfxsod npm run validate
```

The recovered appointment/report integration command also passes:

```text
node --test \
  tests/appointments/v120-staff-blocked-times.test.mjs \
  tests/business-ui/v118-task-first-ux.test.mjs \
  tests/business-ui/v119-zero-learning-operations.test.mjs \
  tests/appointments/v48-calendar-details-reschedule.test.mjs \
  tests/phase0-foundation/canonical-migration-order.test.mjs \
  tests/phase0-foundation/pending-migration-preflight.test.mjs
```

The manifest adversarial suite separately passed **9/9**:

```text
node --test tests/phase0-foundation/migration-manifest.test.mjs
```

Manifest generation, canonical materialisation, and both checked-in manifest
checks passed:

```text
node scripts/migrations/generate-manifest.mjs --write
npm run canonical-migrations:materialize
npm run canonical-migrations:check
npm run migration-manifest:check
```

The rollback-only database suite passes against the canonical 160-migration
chain in disposable PostgreSQL 17:

```text
PGHOST=127.0.0.1 PGPORT=55431 PGUSER=postgres \
PGDATABASE=nestly_v120_rehearsal \
psql -X -v ON_ERROR_STOP=1 -f db/tests/v120_staff_blocked_times.sql

V120 staff blocked-time acceptance: PASS
ROLLBACK
```

It exercises browser-role ACL denial, create/delete replay, changed-key
rejection, cross-branch block overlap, reason bounds, service buffers,
missing-hours fail-closed behavior, cross-branch redaction, read-only denial,
the direct appointment trigger, deletion, and complete audit retention.

The true two-session harness also passes in a newly created, separately named
database that is dropped whole immediately afterward:

```text
createdb --template=nestly_v120_rehearsal \
  nestly_v120_concurrency_rehearsal

V120_CONFIRM_DISPOSABLE_DB=YES \
DATABASE_URL=postgresql://postgres@127.0.0.1:55431/nestly_v120_concurrency_rehearsal \
PGPASSWORD=<local-disposable-password> \
db/tests/v120_staff_blocked_times_concurrency.sh

V120 two-session concurrency: PASS
(blocks 2, appointments 1, receipts 2, audits 2; both writer orderings)
Fixture rows intentionally remain. Drop the entire dedicated
v120_concurrency database now.

dropdb nestly_v120_concurrency_rehearsal
dedicated_database_remaining=0
```

One race submits different block keys at overlapping branches for the same
staff member. The other races block creation against a direct appointment
insert in both orderings: block-first rejects the waiting appointment, while
appointment-first rejects the waiting block. Each first writer holds the same
staff-calendar advisory lock until commit. The harness requires an explicit
disposable-database confirmation, password outside the URL, rejects the
protected project reference, and requires the database name to contain
`v120_concurrency`.

The harness deliberately performs no row cleanup. Prior rehearsal proved that
deleting the synthetic business cascades into immutable benefit evidence whose
guard correctly refuses deletion. Suppressing that error would falsely claim
cleanup and retain synthetic rows. The safe contract is therefore one harness
per dedicated database followed by dropping the entire database. No immutable
guard is weakened or bypassed.

## Deterministic browser evidence

Browser verification of `tests/browser/v120-staff-blocked-times-visual.html`
found no page errors, no horizontal document overflow at 390×844, and zero
automatically detected accessibility violations. One colour-contrast check was
incomplete because automated analysis could not resolve gradient/overlap
colours.

- Desktop Day view: `v120-staff-blocked-times-desktop.png`
- Mobile Day view: `v120-staff-blocked-times-mobile-390.png`
- Mobile create form: `v120-staff-blocked-times-mobile-390-modal.png`
- Mobile read-only state: `v120-staff-blocked-times-mobile-390-readonly.png`
- Mobile empty-team state: `v120-staff-blocked-times-mobile-390-empty.png`
- Mobile load/retry state: `v120-staff-blocked-times-mobile-390-load-error.png`
- Mobile create-error state: `v120-staff-blocked-times-mobile-390-save-error.png`
- Mobile remove-error state: `v120-staff-blocked-times-mobile-390-remove-error.png`

The read-only capture was regenerated after review found that using the HTML
`hidden` attribute was overridden by fixture CSS. The fixture now removes the
action container. At 390×844 it has zero **Block time**, **New appointment**,
or **Remove** controls, no literal-template artifact, and no horizontal
overflow.

## Remaining release blockers

- Run authenticated owner/front-desk/read-only/disabled-module journeys against
  the candidate database at desktop and a 390px-class viewport.
- Verify create → reload/reconnect → remove persistence and cross-branch
  redaction against that database.
- V121 now supplies the separate appointment completion → sale/loyalty ledger
  → refreshed customer projection proof and fixes the disabled-Loyalty hidden
  earn found by that proof. See
  `V121-APPOINTMENT-COMPLETION-LOYALTY-BOUNDARY-ACCEPTANCE.md`.
- Sol and Luna accepted the exact V120/V121 candidate as `VERIFIED_LOCAL`; see
  `SOL-V118-V121-INDEPENDENT-REVIEW-2026-07-31.md`. No commit, push,
  production migration, deployment, or production verification is authorised
  by that local verdict.
