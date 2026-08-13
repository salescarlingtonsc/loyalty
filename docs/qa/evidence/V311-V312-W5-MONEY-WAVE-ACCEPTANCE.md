# V311 + V312 — W5 the money wave: one sale may now earn twice, safely

Waves W5a/W5b of the four-programme independence plan (ledger
`PROGRAMME-INDEPENDENCE-001`). The write path becomes multi-programme-safe:
`app.on_sale_recorded` loops over the business's active accruing spine rows
(points, stamps) — one earn row and one batch per programme — with its idempotency
taken from `GET DIAGNOSTICS row_count` on an insert whose `ON CONFLICT` arbiter
NAMES `points_earn_once_per_sale_per_programme`. The v2 single-earn index and the
v308 tripwire were removed in the same transaction that made that index
authoritative and `programme_id` NOT NULL on both money tables. Every money writer
is programme-scoped: redemption (three paths), reversal, corrections, owner
adjustments, the expiry sweep, and the intent gate. v312 adds the pot-migration
machinery that closes the V309 currentness gap: a model switch now enqueues a
coherent per-client transfer (append-only pair + open-batch retag inside one loop
iteration under the client's row lock), `balance_scope` flips by VALUE to
`'programme_pot'` for coherent firms, and a re-specified standing detector
(`app.detect_programme_pot_split_v312`: no negative programme pot, ledger↔batch
parity per (client, programme)) supersedes the W4a distinct-tag form.

## Owner amendment 2026-08-14 — verified in the landed code

Tiered membership co-exists and nothing was retired: `app.loyalty_tier_for`'s
visits and spend branches are logic-identical to v148 (the D1 filter and fail-open
guard live only in the points_earned branch); the sweep preserves both expiry modes
(fixed-days including yearly, inactivity) and refuses to touch anything but the
points programme's batches — the rig proved a lapsed customer's points expire while
their stamp card survives (step 13), and the reverse mutation (unscoped sweep
zeroing a stamp card) turns the suite red (M6b).

## Verification

- Builder (max effort) + adversarial verifier (max effort) + a dedicated fix pass.
  The build replayed all 13 predecessor lineages before writing a line — the
  on_sale_recorded reconstruction (v37b + v121) matched the live md5
  `21345c7f8a5d6d11174f3456ac6c709c` exactly, and three lineage corrections were
  discovered (the v134 Nestly→Peekaa rewrite inside v84 is byte-different at equal
  length — a length check would have passed the wrong predecessor).
- The verifier independently re-reconstructed 12 of 13 pins, line-by-line-diffed
  the landed loop against the replayed baseline (exactly two hunks, both
  contract-named), executed all four tenant shapes with real sales, and measured
  the red-first matrix on its own rig. Verdict: APPROVED with four findings, ALL
  fixed pre-apply: the v84 replay-evidence check now reads the per-programme arrays
  (a two-programme correction retry would have hard-failed — reproduced red-first,
  suite step 29); the reversal's single-valued assert uses a count(distinct) guard
  + INTO STRICT (step 31); the v312 retag is per-client inside the transfer loop so
  every commit boundary is coherent at any p_limit (step 32, measured); the
  balance-scope resolver is hoisted to one evaluation per payload (step 35,
  measured via pg_stat scan counts — the repo's own SQL-inlining memory note).
- Suite `db/tests/v311_v312_programme_money_kernel.sql`: **36/36** on the rig
  against the real migration bytes AND against the comment-stripped apply copies;
  18-case red-first matrix (M0–M9, F1r–F4r) with byte-identical outcomes to the
  verifier's independent run; double-apply idempotent (whole-catalog function
  digest byte-stable). Steps 29–36 run with both v309 tag triggers dropped —
  under NOT NULL, any non-explicit writer names itself with a violation.
- Two defects found beyond the contract and fixed: the inactivity clock would have
  orphaned a switched customer's history (freshly-earned points expiring after a
  stamps→points switch — the transfer-lineage clause + steps 27/28 pin both
  directions), and the v84 aggregate-vs-per-programme worry was proven unreachable
  and documented on the real invariants (no `remaining<=earned` CHECK exists; the
  restore is bounded row-by-row at v34:652).

## Production evidence (2026-08-14, gadpooereceldfpfxsod)

- **Pre-flight (read-only)**: all 13 predecessor pins matched (the extra
  `redeem_points` row is a 3-arg wrapper that purely delegates to the spliced
  internal — covered); needles present; both indexes valid; tripwire present; zero
  untagged money rows; both detectors empty; spine shape clean; v312 objects absent
  (red-first).
- **v311 applied** (slot 20260813001400). **v312 first REFUSED itself** — its sweep
  post-state pin caught that my apply paste had dropped four trailing `-- v311`
  markers from the sweep body (functionally identical, byte-different; the
  transaction rolled back whole). The sweep was re-applied byte-exactly from the
  validated file, the pin then matched (`a44d959bfae0681c4887a21bfc1d51e1`), and
  **v312 applied clean** (slot 20260813001500): backfill found nothing to migrate
  (expected), detector empty, postcondition battery green, pot worker scheduled
  (`frenly-programme-pot-migrations`, */10).
- **Post-apply live battery, 7/8 PASS + 1 fixture artifact** (all rolled back): a
  REAL sale through the new earn loop produced exactly one tagged earn + one batch
  (the in-trigger parity assertion held); a live model flip fired the switch
  trigger, ran the pot migration INLINE, preserved the business pot exactly (220),
  left the detector empty, marked the migration `complete`, and retagged every open
  batch; both standing detectors empty database-wide; `balance_scope` reads
  `programme_pot` live for all three coherent probe firms; old index gone, new
  index authoritative, cron scheduled. The one FAIL was the battery's own doing: it
  flipped `loyalty_programs` directly, bypassing publish, so the immutable VERSION
  row (which `resolve_loyalty_branch_config` reads) still said classic-with-no-
  stamp-knobs — an incoherent state no real flow produces; the coherent re-probe
  was then blocked by the v26 immutability guard working as designed. The stamps
  earn branch stands proven on the rig (S1/S3, 36/36) against pin-identical bytes,
  and the in-trigger parity assertion plus both standing detectors make any
  real-world stamps-earn failure loud. The first real stamps publish is the natural
  live confirmation.
- **Production post-state fingerprints** (md5(prosrc), the canonical W6 baseline —
  prod strips full-line comments, so normalised-form values appear where bodies
  carry comments): on_sale_recorded `aac80aec8f893ed6c883020aff5da090` ·
  loyalty_tier_for `7847edd63bb72a5f6643ff1d990e6205` · write_guard
  `7f5590449570d76051feed93d182487f` · sweep `9ac8327e5d7cfb3e40be3e8b25ecf934` ·
  run_points_expiry `2321760d1b52bab1b1500526740bf81a` · adjust_points
  `57ca548d40c75fdadc71f9ea9c2f104c` · redeem_reward_core
  `91171a153bc295bbaf0e535b3e9c4d7b` · redeem_points_v40_internal
  `360e6cc8b000cf5108fbb1e3169f0d03` · redeem_points/2
  `66d9c1b41606bc83a87159c4ac519afc` · reversal_v34_base
  `3e8ede00b9c0dcebe7ec0413f442622f` · correct_v84
  `d203e4dbc3bce3d5f5b9f99f938b1e3e` · intent_v89
  `f396a1e8e5914e880c293303276a5cc1` · capabilities
  `735e2b2b885f12937c73ff0aae827085` · catalog
  `07897b24b70da71c5a954d748cc0df3d` · migrate_pot
  `68aaf8094b4e58d362c551a4a89e466e` · enqueue
  `fc46ac7e074ff2b7b4e2a1bfc80953ba` · worker
  `7358edbb36853ba7bb348c7123e8f2cf` · switch
  `1196debb8eb3e1851e147720cebab6a1` · balance_scope
  `300ce0554907302dd92a192a467ea06f` · detector_v312
  `7e2c51dc4b309c798fa83003a594a489`.

## Standing invariants for W6

1. The arbiter is `points_earn_once_per_sale_per_programme`; the earn loop is
   bounded by `unique (business_id, kind)` on the spine; one sale legitimately
   earns points AND a stamp when both programmes are active.
2. `app.enqueue_programme_pot_migration_v312` is THE entry point for "the accruing
   programme changed identity" — W6's switchboard flips must route through it.
3. `balance_scope` is now a live per-firm value; readers must never re-hardcode it
   (the v312 splice battery refuses any function that does).
4. `app.detect_programme_pot_split_v312` supersedes the v310 detector; distinct
   tags are a fact, not a defect. Both detectors must stay empty.
5. The v309 resolver/tag trigger remains as belt-and-braces; W6 has explicit
   permission to retire it, with suite steps 29–36 as the standing proof that every
   writer is explicit.
6. Visible RPC behaviour change, declared: `public.adjust_points` returns the
   POINTS programme's balance and refuses when no points spine row exists.
