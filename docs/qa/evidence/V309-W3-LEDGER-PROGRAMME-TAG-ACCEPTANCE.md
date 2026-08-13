# V309 — W3 ledger programme tag: nullable column, backfilled, parallel index

Wave W3 of the four-programme independence plan (ledger `PROGRAMME-INDEPENDENCE-001`).
`public.points_ledger` and `public.points_batches` gain a nullable `programme_id`
pointing at the W2 spine, every existing row is backfilled, and a BEFORE INSERT
trigger tags all new traffic from the BUSINESS. **Nothing reads the tag yet** (that
is W4) and **no earn behaviour changes** — `app.on_sale_recorded` is deliberately
untouched. Reverting (drop the triggers, the two functions, the new index and the
two columns) restores byte-equivalent behaviour.

Migration `db/migrations/20260813_nestly_v309_ledger_programme_tag.sql`
(slot `20260813000500`, sha256 `e46e9300768c3a8e3a087c97c96be7b1f6770512afa13f0b4e83e57b25f28e7b`,
mirror `supabase/migrations/20260813000500_nestly_v309_ledger_programme_tag.sql` byte-identical).
Suite `db/tests/v309_ledger_programme_tag.sql` (12 steps, rolled back).

## Design facts

- **NULLABLE on purpose.** W5 lands `NOT NULL` after the tag has been observed on
  live traffic. Nullable-plus-trigger fails OPEN by one row and surfaces it through
  the detector; a NOT NULL column added now would make any writer this wave has not
  yet observed fail CLOSED in production the first time it ran.
- **The append-only escape was FOUND, not invented.** `app.forbid_mutation`
  (`20260717_frenly_v11b_money.sql:378-383`) raises unconditionally: it reads no GUC
  and has no escape branch, unlike `public.sales`, whose guard honours the
  `app.sales_backfill` token (`20260719_frenly_v20_financial_engine.sql:2662-2663`).
  The sanctioned mechanism for adding a derived provenance column to these exact two
  ledgers is the **named-trigger disable** established by
  `20260720_frenly_v26_immutable_config_versions.sql:175-196` (which did precisely
  this for `config_version_id`): disable only `trg_points_ledger_append_only`, inside
  the migration transaction, so the guard is restored or the whole migration rolls
  back. §5 follows it and then does what v26 did not — asserts after re-enabling that
  the trigger is enabled (`pg_trigger.tgenabled='O'`) **and** that a real UPDATE still
  raises. The v20 **write guard is BEFORE INSERT only** (`v20:761-763`), so it never
  sees the backfill and is neither disabled nor tokened. `points_batches` carries no
  append-only trigger at all (the FEFO drain `v20:930-935` and the expiry sweep
  `v20:1043` UPDATE it daily), so its backfill is a plain UPDATE.
  `trg_audit_points` is deliberately left ENABLED — the one UPDATE this ledger has
  ever seen is not the one that should have no trail; the migration NOTICEs the
  trigger's event mask so the integrator can reconcile the audit rows.
- **FK action = `ON DELETE RESTRICT`, decided by experiment** (below), not by taste.
- **Resolver `app.resolve_ledger_programme_v309`** encodes the single-pot truth
  (`loyalty_model='stamps'` → stamps spine row, everything else → points spine row),
  resolved from the BUSINESS, never caller-supplied (plan §6 control 1). One
  deliberate divergence from the W1 read model, documented in the header: it does
  **not** require `loyalty_programs.active`, because it answers "whose money is this
  row", not "is the programme running" — binding it to `active` would land every row
  written during a pause on the wrong programme.
- **Trigger placement is forced, not stylistic.** `trg_points_ledger_append_only` is
  a BEFORE UPDATE guard, so an AFTER-INSERT fixer would have to violate the table's
  own invariant; BEFORE INSERT default-column assignment is the only shape available.
  Same-event triggers fire in name order, and the name places the tag
  `trg_points_ledger_config_version → trg_points_ledger_programme_tag_v309 →
  trg_points_ledger_write_guard`: **before** the write guard so W5 can add a
  `programme_id` shape rule to the guard without renaming a trigger on a money table,
  and **after** the config-version stamp, which takes `businesses … FOR SHARE`
  (`v26:234`), keeping the tag's spine read in the v308 lock direction. The order is
  pinned by an in-migration assertion so a rename cannot move it silently.
- **The trigger never overrides a non-null value** — W5's earn loop supplies
  `programme_id` explicitly per accruing programme, and a recomputing trigger would
  collapse that loop onto one programme.
- **Both indexes, side by side.** `points_earn_once_per_sale` (v2:70-71) is
  UNTOUCHED; `points_earn_once_per_sale_per_programme` ships alongside and is
  strictly weaker while every business has one accruing programme. Plain
  in-transaction build (39 rows, and the ACCESS EXCLUSIVE lock is already held);
  the header names this as the one statement that must become `CONCURRENTLY` at scale.
- **Standing detector `app.detect_double_earn_v309()`** (plan §6 control 5):
  SELECT-only, service_role-granted, returns duplicated `(sale_id, programme_id)`
  earn groups UNION sale-linked rows that arrived untagged. Asserted empty by the
  migration and by the suite.

## The FK experiment (the ON DELETE decision)

Run on the verification cluster with the real guards and the production row shape.
Three fixtures so the append-only guard and the FK action can never be confused:
A = batch rows only, B = ledger **and** batch rows, C = no money rows.

| variant | A | B | C |
| --- | --- | --- | --- |
| `RESTRICT` | delete SUCCEEDED | FAILED: `points_ledger is an append-only ledger: DELETE is not permitted` | SUCCEEDED |
| `SET NULL` | SUCCEEDED | same append-only DELETE failure | SUCCEEDED |
| `NO ACTION` | SUCCEEDED | same append-only DELETE failure | SUCCEEDED |

This **refutes the obvious prediction**: `RESTRICT` does not break business deletion,
because a parent-side referential action is an AFTER ROW trigger fired from the
deleting statement's queue — the cascade has already removed the referencing rows by
the time the check on `business_programmes` runs. A second probe forced the OPPOSITE
constraint order (dropping and recreating the `points_batches → businesses` FK so its
OID is newer than `business_programmes`') and RESTRICT still succeeded, 4/4 across
both orders, so the result is not an accident of table-creation order.

Fixture B is the money fact: with ledger rows present the delete fails under **all
three** actions. It is the v20 append-only trigger, not this FK, that makes a firm
with money history undeletable — that predates this wave.

Deleting a **referenced spine row directly** (not via a cascade):

| variant | outcome |
| --- | --- |
| `RESTRICT` | REFUSED — foreign key violation on `points_ledger` |
| `NO ACTION` | REFUSED — foreign key violation on `points_ledger` |
| `SET NULL` | REFUSED — `points_ledger is an append-only ledger: UPDATE is not permitted` |

`SET NULL` is therefore rejected as a landmine, proved rather than argued: it can only
ever succeed by doing the single thing the table exists to forbid, and the "SET NULL
leaves an orphan the detector surfaces" fallback is unreachable because the guard
fires before the orphan can exist. **`ON DELETE RESTRICT` lands**: it never blocks a
business cascade, never attempts a forbidden UPDATE, and refuses the one deletion that
would silently orphan tagged money rows.

## Verification

**Cluster re-proof** — throwaway PostgreSQL 17 in the scratchpad, the established
pattern: a stub schema carrying `app.forbid_mutation` (v11b:378-383),
`app.loyalty_ledger_write_guard` + its four triggers (v20:676-776) and
`app.stamp_config_version` + its triggers (v26:223-289) **copied real, byte-for-byte
by line extraction from the repository migrations**, not restated; then
`20260813_nestly_v307_*.sql`, `20260813_nestly_v308_*.sql` and
`20260813_nestly_v309_*.sql` applied **unmodified**. Seeded to the production shape
recorded by recon: 4 businesses, 39 `points_ledger` rows, 37 `points_batches` rows,
16 spine rows, every ledger row written through the real `sale_trigger` write-guard
route.

- Migration applied clean: `UPDATE 39` / `UPDATE 37`, its own fail-closed assertion
  block reported *zero nulls, zero resolver disagreements, zero cross-tenant tags,
  both indexes valid, append-only and write guards enabled and enforcing, detector
  empty*. `trg_audit_points` event coverage NOTICE read `DELETE+INSERT+UPDATE`, and
  the backfill produced exactly 39 audit rows — recorded, not suppressed.
- Tag distribution exactly as predicted for production:
  `stamps-firm (stamps) → stamps` 8 rows; `tiers-firm (points_tiers) → points` 25;
  `classic-a → points` 4; `classic-b → points` 2.
- Repository suite **12/12 PASS** against these exact migration bytes.
- Trigger inventory on `points_ledger` after the wave, as pinned:
  `trg_audit_points`, `trg_points_ledger_append_only`,
  `trg_points_ledger_config_version`, `trg_points_ledger_programme_tag_v309`,
  `trg_points_ledger_write_guard`.

**Red-first mutation matrix** (each mutation applied to the real files on a rebuilt
cluster):

| mutation | result |
| --- | --- |
| drop both BEFORE INSERT tag triggers | steps 1, 2 and 11 FAIL (`ledger=null batch=null`); step 6 also FAILs with 2 untagged rows — the detector catches what the triggers stopped doing |
| remove the two backfill UPDATEs | the migration **aborts itself**: `ERROR: v309 backfill left untagged rows: points_ledger=39, points_batches=37`, and `programme_id` does not exist afterwards — it fails closed and rolls back whole |
| remove the backfill **and** neuter the assertion block so it can land | step 5 FAILs `untagged=76 cross_tenant=76 disagreements=76`; step 6 FAILs 39 rows |

**Guards**: phase0 89/89, ps0 72/72, `migration-manifest --check`,
`canonical-migrations --check` and `--check-plan` all clean; mirror byte-identical.

**Writer registry**: `scripts/ps0/discover-writers.mjs` discovers **four** v309
objects and classifies them itself — the two BEFORE INSERT triggers as
`writes_value:false / writes_any:false` (they assign a column on NEW; they write no
row), and the two migration backfills as value-impacting `db.backfill:` identities.
Per the registry's own rule (`ps0-writer-registry.test.mjs`: run-once backfills belong
in `allowlist`, everything else value-impacting in `writers`), both backfills are
allowlisted with bespoke justifications naming the escape mechanism and what is and is
not changed, and the `counts_note` records the delta and the scanner's trigger
classification. This extends V308's recorded caveat from the other direction: the
scanner does not follow `perform app.sync_…` chains, and it also does not treat a
BEFORE INSERT default-column assignment as a write — so the tests, not an assumption
about the scanner, decided the registration.

## Production evidence (2026-08-13, gadpooereceldfpfxsod)

- **Verifier risks actioned pre-apply**: R4's scaling note corrected in the file; the
  comment-condensed apply copy was validated by rebuilding the cluster and running the
  full 12-step suite against those exact bytes (12/12) with the audit trigger corrected
  to prod's real INSERT-only mask (closing R1's harness artefact); R3's trigger
  enumeration ran read-only against prod first — BEFORE INSERT set is exactly the two
  expected v20/v26 triggers, so the exact-order assertion holds with ours making three.
- **Red-first**: both `programme_id` columns absent pre-apply.
- **Rolled-back rehearsal**: every fail-closed assertion green; tag distribution
  exactly as predicted — ledger points=31 / stamps=8, batches points=29 / stamps=8;
  **zero audit rows from the backfill** (the audit trigger is INSERT-only in
  production — do not read 0 as failure; R1); detector 0.
- **Applied** as `nestly_v309_ledger_programme_tag` (slot 20260813000500); repository
  file sha256 `4189c59b7d4d06bdb5974a2e18f662f41634d8c65d86a6f7ba47fac602b34972`
  referenced from the applied header; statements byte-identical.
- **Post-apply live battery, 8/8 PASS** (rolled back): a REAL sale inserted for the
  points-active QA Test Cafe went through the entire live earn machinery —
  policy snapshot, config-version stamp, on_sale_recorded — and its earn row arrived
  **tagged with the points spine** (closes verifier risk R5 with the actual path, not a
  synthetic session); the new batch tagged likewise; after a loyalty_model flip to
  stamps the NEXT sale earned into the **stamps** spine while sale 1's history kept its
  points tag and the v308 spine followed the flip (points=false, stamps=true);
  detector 0; resolver/detector ACL floor held; append-only still enforcing on tagged
  rows. Committed state: distribution points=31 / stamps=8, zero nulls, detector 0.

## The currentness gap — named W4 design item (verifier R2)

The tag follows the business's CURRENT model, so after a model switch the offsetting
rows history produces later (expiry sweeps, redemptions, adjustments — all
`sale_id IS NULL`) land on the NEW model's programme while the original earns keep the
OLD tag: per-programme sums for a switched firm can go negative on one side even though
the single-pot balance is right. Inert in W3 (nothing reads the tag) and invisible to
the double-earn detector by design. **W4 owns this**: whichever reader first sums
per-programme balances must either migrate the pot at switch time or read switched
firms single-pot; the W4 brief must carry this paragraph.

## Standing invariants for later waves

1. `points_earn_once_per_sale` (unique on `sale_id` alone) is the authoritative
   anti-double-earn constraint until W5. `db/tests/v309_ledger_programme_tag.sql`
   step 4 PINS that fact deliberately, and W5 flips it in the same transaction that
   drops the old index and removes the v308 tripwire.
2. The tag is provenance, not a live pointer: changing a business's `loyalty_model`
   moves what NEW rows are tagged with and never retags history (suite step 11).
   Any later wave that wants to "correct" historical tags is proposing to UPDATE an
   append-only ledger and must say so out loud.
3. The BEFORE INSERT tag must keep firing before `trg_points_ledger_write_guard`.
   The migration asserts the order; a rename that breaks it fails the migration.
4. Migration assertion (b) — every tag equals the resolver's current answer — is true
   only while a business has one accruing programme. W5 breaks it deliberately; do not
   carry it forward unchanged.
