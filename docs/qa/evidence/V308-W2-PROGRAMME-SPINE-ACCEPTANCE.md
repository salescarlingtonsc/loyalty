# V308 — W2 programme spine: four rows per business, derived, drift-proof

Wave W2 of the four-programme independence plan (ledger `PROGRAMME-INDEPENDENCE-001`).
`public.business_programmes` — exactly four rows (points / tiers / stamps / referral)
per business, `active` mirrored from the W1 read model by one-way sync triggers.
**Legacy columns stay authoritative; nothing reads the spine yet** (that is W4).
Reverting (drop triggers, drop table) restores byte-equivalent behaviour.

## Design facts

- **One recompute** (`app.sync_business_programmes_v308`, SECURITY DEFINER) derives
  `active` by CALLING `app.business_programmes_v307` — W1's reviewed predicates are
  never restated. It opens with `businesses … FOR UPDATE`: existence probe (cascade
  deletes) plus **per-business mutex**, closing a race the adversarial verifier
  proved with two real backends (a later transaction's stale computed flags
  overwriting an earlier commit; the `is distinct from` idempotence guard is exactly
  what let the stale write fire). Global lock order: businesses row → spine rows in
  kind order; `publish_loyalty_config` already conforms.
- **Trigger coverage** = every legacy surface a W1 flag reads: businesses
  (INSERT + UPDATE OF points_mode), loyalty_programs (INSERT/UPDATE/DELETE),
  loyalty_tiers (INSERT / UPDATE OF business_id / DELETE), referral_programs
  (INSERT / UPDATE OF enabled, business_id / DELETE). The verifier enumerated every
  production writer of those four surfaces and confirmed completeness (no TRUNCATE
  paths exist).
- **loyalty_tiers sync is a DEFERRABLE INITIALLY DEFERRED constraint trigger** —
  `publish_loyalty_config` republishes the ladder by delete-and-reinsert, and an
  immediate trigger would stamp both breadcrumbs on every no-op republish. Deferred
  to COMMIT, a net-unchanged publish recomputes against the final rungs, hits the
  no-op guard, and writes nothing; a real pause still stamps `deactivated_at`.
- `activated_at`/`deactivated_at` are never-cleared breadcrumbs ("running since… /
  paused on…"); the backfill stamps `activated_at` = migration time for already-
  running programmes (read as "running since at least").
- **No browser role can write the table** (RLS on, SELECT-only policies mirroring
  loyalty_programs' member+super-admin reads, ACL revoked with SELECT granted back to
  authenticated; deliberately no module gate per W1 divergence 1). service_role keeps
  the house-default write privilege; the **tripwire** — a constraint trigger refusing
  points.active AND stamps.active on one business — is the structural guard, removed
  deliberately at W5 in the same transaction as the anti-double-earn index swap.
- Fail-closed in-migration backfill assertion: shape (4 rows × N businesses, kinds
  complete) and zero disagreements with the read model, or the whole migration aborts.

## Verification

- **Builder + two adversarial passes.** The first verifier CONFIRMED two defects that
  were fixed before any production contact: the stale-sync race (fix: the FOR UPDATE
  mutex) and the publish breadcrumb churn (fix: the deferred tier sync); plus the
  service_role wording correction and an authenticated-session coverage gap. A
  dedicated fix pass re-proved everything on a throwaway Postgres 17 cluster with the
  REAL migration files: 20/20 suite, **red/green two-backend race reproduction**
  (pre-fix: drift confirmed, spine points=true vs model false; post-fix: converged),
  and **red/green cross-commit storm proof** (immediate trigger: both breadcrumbs
  rewritten + phantom pause; deferred: byte-identical, no heap tuple).
- Red-first mutation matrix on the cluster: dropping any one of the four sync
  triggers, the no-op guard, the tripwire, or granting authenticated writes each
  turns named suite steps red.
- Guards: phase0 + ps0 116/116; both generator `--check`s clean; mirror byte-identical
  (migration sha256 `7c3426e85190cc7784521c141d84874dd118e6dea1fd09ea4ba096ab3d946958`).
  Writer registry: no entry (the discovery scanner classifies the triggers
  `writes_value:false`); recorded caveat — the scanner does not follow
  `perform app.sync_…` chains, so W3's ledger tag must not rely on it.

## Production evidence (2026-08-13, gadpooereceldfpfxsod)

- **Red-first**: `to_regclass('public.business_programmes')` and the sync function
  both absent pre-apply.
- **Rolled-back rehearsal** (full migration body + survey in one transaction): the
  fail-closed backfill assertion passed; distribution **exactly the recorded W1
  baseline** — 44 rows, 6 active: points → Cubbly, QA Go-Live Cafe, QA Test Cafe;
  referral → AhXiang, QA Test Cafe, ZZ-SYNTHETIC; zero tiers, zero stamps; parity
  PASS with zero disagreements.
- **Applied** as `nestly_v308_programme_spine` (slot 20260813000400); the apply
  transaction's own backfill assertion passed.
- **Post-apply live battery, 14/14 PASS** (rolled back): businesses-INSERT trigger
  creates the four rows; programme activation syncs points + stamps activated_at;
  deferred tier sync flushes via SET CONSTRAINTS; an AUTHENTICATED owner session
  updating points_mode over real RLS converges the spine (row_count=1); the
  publish-storm shape (delete + reinsert identical rungs) leaves breadcrumbs
  **byte-stable**; a real pause stamps deactivated_at; referral flips alone; RLS
  owner=4/stranger=0; authenticated write denied (42501); tripwire raises (23514);
  function + table ACL floor; recompute idempotent (xmin-stable); full-tenant parity
  zero disagreements. The full 20-step repository suite
  (`db/tests/v308_programme_spine.sql`) ran 20/20 against these exact migration bytes
  on the verification cluster; the live battery re-proves every production-specific
  surface (real policies, guards, tenants) — recorded honestly as the split.
- **Committed state**: 44 rows / 6 active / 0 disagreements. Advisors: 0 ERROR,
  zero mentions of any v308 object (platform WARN/INFO counts unchanged).

## Standing invariants for later waves

1. Lock order: `businesses` row → spine rows in kind order. Any W3–W6 writer touching
   the spine must take the businesses row first.
2. The loyalty_tiers sync converges at COMMIT. No W4+ reader may read the spine
   mid-transaction after editing rungs without flushing (`set constraints … immediate`
   — and re-defer BY NAME, never `all deferred`, which would also defer the tripwire).
3. The tripwire is removed at W5 only, in the same transaction as the
   `unique (sale_id, programme_id)` swap.
