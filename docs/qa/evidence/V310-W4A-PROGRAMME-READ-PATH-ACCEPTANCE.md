# V310 — W4a programme read path: additive payloads, one behaviour change, one honest disclosure

Wave W4a of the four-programme independence plan (ledger `PROGRAMME-INDEPENDENCE-001`;
design contract workflow wf_80e3e488-edd, recorded in the plan §6 W4). Nine server
readers gain per-programme payloads; every spendable balance stays the business pot
(currentness policy (a)); the only behaviour change is the approved D1 tier-fuel
filter. The W4b customer stack gates on `programmes_contract='v310'` and ships
separately after this wave is proven live.

## Design facts

- **Additive-first for the 4-hour CDN window**: `customer_portal_capabilities` gains
  `programmes[4]` (kind, active, customer_visible, running_since, paused_since,
  balance_scope) + `programmes_contract='v310'`; `customer_get_reward_catalog` gains a
  derived `programmes[]` grouping over the SAME aggregation as its flat `rewards[]`
  (cannot drift); wallet/loyalty-details gain identity blocks; every pre-v310 key is
  byte-stable — proven live, below.
- **The D1 tier-fuel filter** in exactly THREE twins (`customer_get_effective_tier_v143`,
  `app.v176_tier_gate_metric`, the metric branch of
  `customer_get_business_presentation_v95`), each with an explicit **fail-open**
  fallback: a missing points spine row yields the unfiltered sum, never a zeroed tier
  (the design's highest-severity line; red-first proven — dropping the branch
  reproduces the silent tier wipe). The FOURTH twin, `app.loyalty_tier_for`, is the
  earn multiplier and is deliberately untouched (W5's named target) — the migration
  asserts its md5 unchanged across the transaction.
- **Currentness policy (a)** enforced: no reader computes a per-programme spendable
  balance; insights/overview add `points_outstanding_by_programme_tag` as provenance
  with `pot_is_split` suppression to NULL (never a partial array). The split guard is
  NULL-hardened (verifier risk 2: `count(distinct)` is NULL-blind; an untagged row now
  reads as split rather than silently under-reporting liability).
- **Standing detector** `app.detect_programme_pot_split_v310()` — W5's pot-migration
  worklist; asserted empty at install; a resolver disagreement here is a finding, not
  a migration failure (V309 standing invariant 4 honoured).
- **Live-body discipline**: the two functions whose live bodies are text-patched
  (capabilities: v231+v306; catalog: v176b+v230+v241 — the catalog's live md5 is
  reproduced by NO repo lineage) are handled with md5 pre-assertion pins and, for the
  catalog, a fail-closed needle splice — the only technique correct against a body
  that cannot be re-stated from files. All six pins matched production exactly at
  pre-flight.

## Verification

- Builder + adversarial verifier (both Opus, high effort; the verifier ran twice due
  to a network outage — its completed pass **APPROVED** with 8 risks, none
  CONFIRMED-BROKEN). Verifier work included independently rebuilding all 11
  predecessor lineages on its own cluster, byte-diffing the re-stated bodies against
  the reconstructed live text, jsonb pre/post payload diffs, a fail-open execution
  proof (delete spine row → metric 40→47, not 0), and a call-graph + live-sale check
  that the earn multiplier is behaviourally untouched.
- Repository suite `db/tests/v310_programme_read_path.sql`: 14/14 on the builder's
  cluster against the real migration bytes; red-first matrix measured (D1 revert →
  steps 6/7/9 red; fail-open dropped → step 7 reproduces the exact silent wipe;
  left-behind twin → twin-parity net catches it; detector dropped → suite aborts).
- Verifier risks actioned before apply: R2 NULL-hardening folded into the migration;
  R4 scaling-note corrected; R1 closed by a live needle probe; R3 became the
  disclosure below; R5 closed by the live real-sale probe; R8 recorded as a W4b gate
  requirement (`programmes.length === 0` must fall back to the tab renderer).

## Production evidence (2026-08-13, gadpooereceldfpfxsod)

- **Pre-flight (read-only)**: all six md5 pins equal to the recorded live values;
  catalog splice needle present; `programmes_contract` absent (red-first); pot-split
  detector function absent (red-first); double-earn detector empty; every business
  carries exactly four spine rows.
- **Pre-apply payload captures** for QA Test Cafe and Hougang ABC (fixture-link
  probes, rolled back) recorded for the diff below.
- **Applied** as `nestly_v310_programme_read_path` (slot 20260813000600); repository
  file sha256 `ed4cab8143a2d268dbeeb937…` referenced from the applied header; the
  apply's own chain held: pins → seven fail-closed splices → loyalty_tier_for
  unchanged → detector empty → spine shape → capabilities cross-check binding → ACL
  floors.
- **Post-apply live battery, 7/7 PASS** (rolled back): QA Test Cafe capabilities /
  catalog / tier payloads **byte-identical** to the pre-apply captures once the new
  keys are removed (`programmes=4`, `contract=v310`, derived group `points`,
  `tier_fuel=points_programme_earn`); Hougang ABC capabilities byte-stable with the
  module-off catalog error unchanged; a REAL sale through the live earn machinery
  arrived tagged to the points spine and the gate metric read it; both detectors
  empty including the in-transaction sale.

## The one declared live payload value change (verifier risk 3)

`business_programme_usage_v271` at the stamps tenant (Hougang ABC): measured live —
`point_system.customers` moved from 2 to **0** and the new `stamp_card.customers`
reads **2**. This is the intended correction (stamp earners were being reported as
point-system users), but it IS a visible value change at one live tenant, disclosed
here rather than hidden inside "additive only".

## Validation caveat (deliberate, temporary)

At commit time the W4b customer-stack build is in flight in the same worktree, so
`npm run validate`'s bundle-stamp checks cannot run against a quiet tree. This commit
stages the W4a file set explicitly and alone (per the verifier's process-blocker
finding); the registration/phase0/ps0 guards for these files are green
(manifest + canonical + preflight + hardening + writer-registry), and the full-suite
run happens at W4b integration on the combined tree.
