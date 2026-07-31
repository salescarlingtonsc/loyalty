# V121 appointment completion Loyalty-boundary acceptance

Date: 2026-07-31
Scope: local feature branch, with owner-authorized release pending production evidence
Issue: `OPSUX-004`
Release authorization: **owner supplied `RELEASE APPROVED push and deploy` on 2026-07-31**

## Outcome

The V47 **Complete & checkout** path still completes a booked appointment and
creates one appointment-linked sale. V121 changes only the sale-triggered
points/stamps earn: a new earn is created only when the sale branch's effective
v94 Loyalty mode is exactly `rw`.

This evidence supports `VERIFIED_LOCAL`, not `VERIFIED_BROWSER`,
`VERIFIED_DATABASE`, `VERIFIED_PRODUCTION`, `CLOSED`, or release approval. The
database evidence below is from disposable local PostgreSQL 17, not the target
database environment.

## Exact reproduction before V121

The rollback-only `SPA-GLOW` fixture first proved that the enabled path was
internally coherent:

- Olivia completed `CUS-MEI`'s booked SGD 60 Spa ritual 60 at Orchard;
- V47 persisted one completed appointment and one appointment-linked sale;
- the sale trigger persisted one +600 earn;
- repeating the same status call returned `replayed: true` and created no
  duplicate sale or earn;
- `customer_get_wallet`, `customer_get_business_summary`, and
  `customer_get_loyalty_details` all returned the same 600 balance and one earn;
- Farah, assigned only to Orchard, could not complete the Tampines appointment
  and the denied call changed no appointment, sale, or points row.

The same fixture then disabled Loyalty at firm scope. Customer-safe projections
correctly hid or denied Loyalty, but the subsequent V47 completion still minted
hidden value:

```text
ERROR: DEFECT OPSUX-004: disabled Loyalty completion created 600 point(s);
checkout result={"status":"completed","replayed":false,...}
replay={"status":"completed","replayed":true,...}
```

The root cause was the final `app.on_sale_recorded()` implementation: it
resolved the immutable published loyalty configuration but never consulted
`app.effective_platform_module_mode_v94()` for the sale branch.

## Forward-only repair

`db/migrations/20260731_nestly_v121_effective_loyalty_sale_earn_boundary.sql`
patches the final trigger function in place with strict predecessor and
postcondition checks. It requires:

```sql
app.effective_platform_module_mode_v94(
  new.business_id,new.branch_id,'loyalty'
).mode = 'rw'
```

before entering the points/stamps earn branch. It does not:

- change or delete existing `points_ledger` or `points_batches` rows;
- suppress the sale, appointment status, visit/retention, referral, commission,
  inventory, or reversal trigger paths;
- alter V47 replay behavior or branch authorization;
- broaden customer or merchant reads;
- weaken RLS, ACLs, security-definer search paths, or production controls.

The source and Supabase mirror are byte-identical:

```text
571cd4e6e367d1b8d540d739df9cc6f74db9ffeda1f9f379e82ae3aa057629c0
```

## Passing local database acceptance

After applying V121 to the disposable rehearsal database:

```text
BEGIN
DO
REVOKE
DO
COMMIT

NOTICE: V121 OPSUX-004 appointment completion customer projection: PASS
DO
ROLLBACK
```

The same rollback-only fixture then passed in a separately cloned
`nestly_v121_completion_rehearsal` database, which was dropped immediately
afterward and confirmed absent (`0` matching databases).

The final acceptance covers:

| State | Persistent result |
| --- | --- |
| Orchard Loyalty `rw` | One SGD 60 sale, one +600 earn, all three customer readers return 600 and one earn |
| Same completion called twice | First call completes; second returns replay; still one sale and one earn |
| Firm Loyalty `disabled` | One sale, zero new points; customer Loyalty hidden/denied |
| Orchard Loyalty `disabled` with Tampines still enabled | One Orchard sale, zero new points |
| Orchard Loyalty `r` | One Orchard sale, zero new points; prior 600 remains readable because a current effective read path exists |
| Farah attempts Tampines completion while assigned only to Orchard | Permission denial; appointment remains booked; zero sale/points mutation |

Across the four authorised completions, exactly four sales exist and only the
single `rw` completion has an earn. The prior 600 balance is never deleted or
rewritten.

## Automated contracts

Focused static, manifest, canonical-plan, and pending-migration checks pass:

```text
node --test \
  tests/appointments/v121-appointment-completion-customer-projection.test.mjs \
  tests/phase0-foundation/canonical-migration-order.test.mjs \
  tests/phase0-foundation/migration-manifest.test.mjs \
  tests/phase0-foundation/pending-migration-preflight.test.mjs

25 tests passed, 0 failed
```

The rollback SQL and static regression hashes are:

```text
5f47081fb844883b35923e5392062c917e008ecab0309bc00efdb043a09cc434
  db/tests/v121_appointment_completion_customer_projection.sql
372507df9d016efc267a6e31d30bb0750ac46e2df4abc219308870427fccbf08
  tests/appointments/v121-appointment-completion-customer-projection.test.mjs
```

The complete repository gate also passes:

```text
EXPECTED_SUPABASE_PROJECT_REF=gadpooereceldfpfxsod npm run validate

quality: pass
runtime configuration: pass
migration manifest: pass
canonical migration chain: pass
tests: 1,311 passed, 0 failed
static build: pass
```

## Remaining release blockers

- Run authenticated owner/front-desk/customer refresh evidence against the
  candidate target database and browser, including desktop and 390px.
- Run the appointment-linked sale reversal/correction journey and verify the
  customer history relationship.
- Sol and Luna independently accepted the exact frozen candidate as
  `VERIFIED_LOCAL`; see
  `SOL-V118-V121-INDEPENDENT-REVIEW-2026-07-31.md`.
- Obtain owner release approval before any commit, push, production migration,
  deployment, production data change, or production smoke.
