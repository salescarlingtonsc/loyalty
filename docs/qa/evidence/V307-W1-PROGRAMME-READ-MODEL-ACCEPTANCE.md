# V307 — W1 programme read model: one function, four flags, zero writes

Wave W1 of the four-programme independence plan
(`docs/design/FOUR-PROGRAMME-INDEPENDENCE-PLAN.md` §6; ledger
`PROGRAMME-INDEPENDENCE-001`, owner approval 2026-08-13). A single stable function —
`app.business_programmes_v307(business)` → four rows `(kind, running)` for
points / tiers / stamps / referral — derived entirely from today's legacy columns.
No table, no trigger, no write, no behaviour change anywhere. It exists so that the
W2 spine backfills FROM one reviewed set of predicates and every later wave (W3
ledger tag, W4 read-path flip, W5 write path) is diffed AGAINST it.

## The contract

Points and tiers mirror the live, v306-patched `customer_portal_capabilities`
byte-for-semantics — including the asymmetric NULL coalesces ('redeem' for the
points gate, 'tiers' for the tier gate) and the live `<> 'tiers'` spelling of the
mode gate (closed under future vocabulary extension). Three deliberate divergences,
all documented in the migration header: no module/link gating (per-business
programme truth vs per-customer presentation); no reward-catalogue-nonempty clause
(an empty catalogue is presentation, not programme-off); and points is
model-exclusive (a stamps firm answers points=false even though its stamp catalogue
makes the live `rewards` capability true — programme identity wins, or the W2 spine
would grow a phantom points row for every stamps tenant). The known mirrored oddity
(stamps model + NULL mode + leftover ladder ⇒ tiers=true) is pinned by the suite
rather than hidden; the tenant survey found no such firm live, and W2 resolves it
by recording what the owner actually switched on.

SECURITY INVOKER with the house revoke: v19 grants schema-app usage to
`authenticated` and a new function defaults to PUBLIC execute, so the migration
revokes from public/anon/authenticated and grants service_role — even though there
is no PostgREST route for the app schema and RLS makes the invoker function a
non-oracle (four false rows for a business the caller cannot read).

## Adversarial verification (pre-ship)

Builder + independent verifier agents. The verifier confirmed predicate fidelity
value-by-value over the whole mode domain, traced the live production edge (stamps
firm with a leftover ladder on 'redeem' ⇒ stamps-only), proved the four-row shape
survives an unknown business id, and established that the pinned row order is real
because the search_path pin keeps the SQL function un-inlined. Its three findings
were folded in before apply: the third divergence documented (was silently
stricter than live), the ACL premise corrected + house revoke added, and the mode
gate re-spelled `<> 'tiers'`.

## Production evidence (2026-08-13, gadpooereceldfpfxsod)

- **Red-first**: `to_regprocedure('app.business_programmes_v307(uuid)')` NULL
  before apply.
- **Combined rolled-back rehearsal** (migration body + 11-assertion suite + tenant
  survey in one transaction): **11/11 PASS**; survey confirms no stamps+NULL+ladder
  firm exists; full-tenant baseline recorded — 11 real businesses: Cubbly /
  QA Go-Live Cafe / QA Test Cafe points=true; AhXiang, QA Test Cafe, ZZ-SYNTHETIC
  referral=true; all others all-false; **zero live tiers=true and zero live
  stamps=true tenants** (the one active points+tiers firm sits on
  points_mode='redeem', which puts the ladder away — the live capabilities answer,
  i.e. the mirror holding). This baseline is what W2's backfill must reproduce
  row-for-row.
- **Applied** as `nestly_v307_programme_read_model` (slot 20260813000300). The
  applied head comment is condensed and references the repository file by sha256
  `14fb3c64cbbd6cd537d5cae434f873c2a78e6941f379ae655d18d9a3ec754420`; the function
  body, ACL statements and comment-on are byte-identical to the file.
- **Post-apply live suite + ACL floor**: **12/12 PASS** (`db/tests/
  v307_programme_read_model.sql` + `has_function_privilege` floor:
  authenticated=false, anon=false, service_role=true).
- Registration: both plans + regenerated manifests/sha256, counts 295/250, date
  tally `['20260813', 3]`, preflight suite mapping v307 → its db test; phase0+ps0
  guards 116/116. Writer registry: no entry required (zero-write read model, no
  browser call site) — confirmed by the ps0 suites, not assumed.

## Residuals

- Step 9 parity is proven for a classic-model firm across the whole mode
  vocabulary; stamps-model firms sit outside the points-vs-rewards comparison by
  design (divergence 3). Suite header states this.
- The builder's local red-first mutation proof (reverting either coalesce turns
  steps 2 and 9 red) ran on a throwaway local cluster; production red-first is the
  absent-function probe above.
