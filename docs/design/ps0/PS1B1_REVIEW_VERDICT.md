# PS-1B.1 Independent Review Verdict

Scope: PS-1B.1 §1 — catalog price fail-closed hardening (v57).
Reviewer: independent adversarial reviewer (not the author).
Two-round review. The formal verdict (PASS / CHANGES REQUIRED / BLOCKED) is issued
in Round 2, after persisted UAT evidence exists. Round 1 decides only whether the
frozen commit may be applied to the non-live UAT database.

---

## Round 1 — commit clearance

**Commit under review:** `5fe5508` ("feat(ps1b1): catalog pricing fails closed - typed
price, evidence, effect isolation")
**Delta:** `git diff 92aefec..5fe5508` (14 files).
**Result: CLEAR TO APPLY** — v57 may be applied to the non-live UAT database (`gadpooereceldfpfxsod`
remains gated by the owner's `RELEASE APPROVED` phrase; this clearance is UAT-only).

### What was verified

**1. Owner §1 requirements — met by the CODE, not merely the tests.**
`app.ps1b_catalog_price(uuid,text,uuid)` now returns `jsonb {status,price_cents,reason}`
and every status path was traced (migration lines 32-73):
- null reference → `not_applicable`, `price_cents = null` (line 39-42). Not a meaningful 0.
- unsupported kind (not service/product) → `invalid_kind` typed validation failure (43-46).
- missing/cross-tenant row → `not_found`, `price_cents = null` (59-62).
- genuine configured price of 0 → `ok` with `price_cents = 0` (correct: that IS a price).
- `WHEN OTHERS` → inserts a structured `audit_log` row
  (`action='PS1B_PRICING_ERROR'`, detail = `{sqlstate, left(sqlerrm,200), kind, catalog_id}`)
  and returns `status='error'`, `price_cents=null`, `reason=sqlstate` (65-72). Never a 0.
- No code path converts a failure to numeric 0: the only numeric result is the true
  column value on `ok`. Audit detail carries no secrets/raw SQL — only sqlstate, a
  200-char-truncated message, kind, and the caller-supplied uuid; the value returned to
  the caller is just the 5-char sqlstate. `audit_log` columns
  (`business_id,actor,action,entity,entity_id,detail`) match the insert exactly
  (actor/entity_id/detail nullable). Function correctly switched `stable`→`volatile`
  because it now writes.

**2. Executor diff vs v56 is exactly the three sanctioned changes.**
`app.ps1b_execute_event`: (a) `grant_free_item` consults the typed price and fails
closed; (b) each effect runs in its own `begin…exception when others` subtransaction
that logs `outcome='failed'` and continues; (c) that is all. `send_notification`,
`display_perk`, the shadow/else branch, `budget_exhausted`, `fulfilled`, the
`domain_event_execution` marker, and the per-effect `v_idx`/`v_count` increment
semantics are behaviourally identical to v56. Subtleties checked:
- exception-handler variable scope: `v_type` survives subtransaction rollback;
  `coalesce(v_type,'unknown')` guards the pre-assignment case. Effect_index stays
  correct, so no unique-key collision between a failed effect and its siblings.
- `not_applicable + amount_cents` fallback (lines 186-190): uses an explicit
  owner-authored value, never a silent 0. The PS-1A validator (v55 lines 409-410)
  *requires* a valid catalog_ref for `grant_free_item`, so this branch is unreachable
  for validly-published rules — it is defensive and fails safe, not validator-inconsistent.
  This is strictly better than v56, where a null catalog_id silently produced
  `coalesce(0, amount_cents, 0) = 0`.
- `status='ok'` with null `price_cents`: `v_face` stays null → `failed`. Unreachable in
  practice — `services.price_cents` and `products.retail_price_cents` are both
  `integer NOT NULL check (>=0)` — but safe if it ever occurred.
- poison isolation is a genuine robustness gain: in v56 a malformed `amount_cents`
  raised out of the sweep and wedged the whole batch; v57 isolates it to one effect.

**3. rule_effect_log constraint mechanics correct.**
`failure_reason text` added (nullable). Known named presence + outcome checks dropped
by name, then a conname-pattern DO block drops any residual CHECK whose def mentions
`outcome` — the `effect_index >= 0` check does not match and is preserved. Three named
CHECKs re-added: outcome allowlist (v56 set + `'failed'`); `fulfilled ⟺ fulfilment-ref`
(unchanged); `failed ⟺ failure_reason`. Cross-consistency holds for every outcome, and
the new checks are backward-compatible with any pre-existing v56 rows (none can have
`outcome='failed'`, so all satisfy `(false)=(false)`), so the "table is empty" note is
stronger than strictly required.

**4. Test suite proves the owner's eight cases + executor isolation.**
Pure-pricing a-g map to concrete assertions (a valid service 1500 / b valid product
2500 / c cross-tenant not_found / d missing not_found / e null not_applicable+null
price / f bundle invalid_kind / g renamed column → error+sqlstate+structured audit row,
no raw SQL). The renamed-column simulation is real (`alter table … rename column …`,
run, rename back). (h) end-to-end: rule X product errors → `failed`+no
entitlement/fulfilment/budget while its `send_notification` sibling still fires; rule Y
service fulfils at the TRUE 1500 face with a reconciling reservation; the no-silent-zero
assertion (`face_value_cents=0`) is scoped to the WHOLE business, not one rule. (i) The
poison rule Z carries a malformed `amount_cents` that passes PS-1A (grant_free_item never
parses it) and raises inside the executor's `v_amt` parse — exercising the subtransaction
handler, not an earlier catch — producing `failed` with no promise while the event still
receives its execution marker.

**5. No scope creep.** The diff is exactly 14 files: the v57 migration + byte-identical
supabase mirror (`cmp` clean), the v57 test, three phase0 bookkeeping tests, five
manifest/plan/sha files, the materialiser count, and the writer-registry entry. Token
scan of the migration finds no `checkout`, `sv_`/`stored_value`, `credit_ledger`,
`points_ledger`, comms provider, `discount`, `tender`, or `create/drop table`. Producer
triggers, `emit_domain_event`, outbox/sweep/captured_messages, shadow evaluator/comparator,
redeem/reverse, registry guard/seed, `ps1b_materialise_entitlement`, and budget arithmetic
are untouched. No new activation surface. `PS-GATES.md` (PS-1B yes / PS-1C no) and the
`tests/program-studio/ps0-no-executor.test.mjs` tripwire are unmodified; v57 introduces no
new table (only an ALTER of the existing PS-1B `rule_effect_log`), so the artifact tripwire
is unaffected.

**6. Bookkeeping honest.** File sha256 `e0afb92…7a15f6` and octet length 16634 match both
manifests. db manifest 88→89 items / 74→75 executable / 20260724 count 2→3; supabase
canonical 90→91 items / 45→46 pending; materialiser assertions and all three phase0
test-count updates are internally consistent. writer-registry `db.fn:app.ps1b_execute_event/1`
truthfully documents the fail-closed behaviour and the new latest_file.

### Minor observations (non-blocking; no change required to clear Round 1)
- O1. If a single effect BOTH triggers an internal pricing error (audit row written) AND
  then raises (e.g. a co-present malformed `amount_cents`), the subtransaction rollback
  discards that `PS1B_PRICING_ERROR` audit row; the failure still remains fully evidenced
  via the outer handler's `rule_effect_log` `failed` row (written in the outer transaction).
  Primary structured-evidence path always survives. Extremely narrow; acceptable.
- O2. The `not_applicable + amount_cents` executor fallback is dead code for
  validly-published `grant_free_item` rules (validator mandates a catalog_ref). Harmless
  and fail-safe; left as defence in depth.

### To re-verify on UAT during Round 2 (persisted-evidence journey)
1. Apply v57 to UAT on top of the v56 chain and confirm the `alter table … add column`
   + constraint rebuild succeeds against a rule_effect_log that already holds v56 rows
   (not just the empty fresh-replay table).
2. Persist and inspect a real `PS1B_PRICING_ERROR` audit_log row on UAT — confirm detail
   carries sqlstate/kind/catalog_id and no raw SQL or secret payload.
3. Confirm a genuine $0-priced catalog item still fulfils at face 0 (intended) while an
   errored/missing price yields `failed` — i.e. the "no zero from error" invariant holds
   distinct from a legitimate zero.
4. Re-run the v57 + v56 suites, the concurrency harness, and
   `EXPECTED_SUPABASE_PROJECT_REF=gadpooereceldfpfxsod npm run validate` against the
   persisted UAT database and capture output as Round 2 evidence.

---

## Round 2 — persisted UAT journey & formal verdict

**Frozen state:** repo HEAD `1ee25b0` (round-1 verdict commit) on top of the reviewed
commit `5fe5508`; `git status` clean; v57 migration byte-hash unchanged
(`e0afb92…7a15f6`). **UAT:** `gadpooereceldfpfxsod` (verified via `get_project_url` on
the sanctioned MCP server; the other two Supabase servers were never touched), ledger 91,
v57 applied. Synthetic tenant `bcd24ddd-9614-4384-9f83-a6e6da31f700`
(`ZZ-SYNTHETIC PS1B1 UAT Journey` / `zz-synthetic-ps1b1`). All queries below were
read-only; I deliberately avoided the pricing error path so nothing was written to UAT.

### Formal verdict: **PASS PS-1B.1**

PS-1B.1 §1 (catalog price fail-closed hardening) is fully realised in code, enforced by
the live UAT schema, exercised at the live function level, and demonstrated end-to-end by
the persisted synthetic journey with zero silent-zeros and complete isolation. No owner
requirement is unmet; no forbidden surface appeared.

### Live-UAT evidence I independently re-verified

**Schema post-apply (live):** `app.ps1b_catalog_price` is `volatile` returning `jsonb`;
`rule_effect_log.failure_reason text` present; four CHECKs exactly as designed —
`effect_index >= 0` (preserved, not collateral-dropped),
`(outcome='fulfilled') = (benefit_fulfilment_id IS NOT NULL)`,
`(outcome='failed') = (failure_reason IS NOT NULL)`, and the 8-value outcome allowlist
including `'failed'`.

**Typed contract, live + read-only** (called directly against the synthetic tenant):
- real granted service `74a68be4…` → `{status:ok, price_cents:500}`
- null reference → `{status:not_applicable, price_cents:null}`
- kind `bundle` → `{status:invalid_kind, price_cents:null}`
- missing row → `{status:not_found, price_cents:null}`
No non-ok status ever yields a numeric price. Three of the four fail-closed statuses are
thus confirmed on the live UAT function, not only in rehearsal.

**No silent-zero — the definitive tie:** the persisted `benefit_fulfilments` recurring row
carries `face_value_cents = 500`, which equals the live `ps1b_catalog_price` result for the
same granted item (`ok`/500). The promise was priced at the TRUE catalog value, not 0.
Platform-wide `face_value_cents = 0` fulfilments: **0**. Platform-wide
`PS1B_PRICING_ERROR` audit rows: **0** (pricing stayed healthy).

**rule_effect_log row integrity (persisted):** `fulfilled` carries a fulfilment ref and no
reason; both `notified` and the `budget_exhausted` rows carry neither ref nor reason — every
row satisfies all three CHECKs; no orphan `failure_reason`; no `failed` rows (healthy run).

**§2 single path / §3 budget preservation:** effects `{fulfilled:1, notified:2,
budget_exhausted:1}`; entitlements `{reversed:1, available:1}`; one 500-face fulfilment;
one reservation; `budget_periods committed=500=cap=500` (client B's budget_exhausted was
logged while A's reservation + committed counter stayed intact); outbox `{delivered:2}`.

**§4 redeem/reverse:** entitlement ops `{redeem:1, reverse:1}`; audit
`{REDEEM_ENTITLEMENT:1, REVERSE_ENTITLEMENT:1}`; the recurring entitlement shows
`redeemed`→`reversed` (the v57-sanctioned post-terminal transition) with its
`budget_reservation_id` retained (promise preserved). No financial ledger touched: `points`
rows 0; the only `credit_ledger` row is the legacy referral reward.

**§5 comms safety:** `captured_messages` = 2, recipients both
`synthetic:<uuid>@example.test`; outbox all `delivered`. (The real-recipient
`check_violation` was proven in the coordinator's rolled-back probe; the live CHECK on
`captured_messages.recipient` is the same structural guard from v56.)

**§6 referral shadow:** persisted comparator
`{clean:true, matched:1, shadow_only:0, live_only:0, mismatches:0}`; the referral
fulfilment (`engine=referral, basis=credit_face, conf=high, face=300`) was written by the
legacy trigger, the shadow evaluator wrote exactly one `benefit_shadow_evaluations` row
(face 300) and NO fulfilment/value. The referral `+300` credit is the single financial row
in the tenant and is legacy-attributed.

**§7 final state + isolation:** independently reproduced every claimed figure
(events `{sale.completed:2, referral.qualified:1}`, fulfilments `{recurring:1, referral:1}`,
shadow_evals 1, sales 2, points 0). Platform-wide `domain_events` = 3, all 3 in the
synthetic tenant, **0 in any other tenant** — complete isolation. Append-only guards intact
(v56, untouched by v57); nothing deleted; no real customer data.

**Forbidden-in-this-pass items — all absent:** no checkout financial effects (checkout
family shadow-logged, no `checkout_evaluations`), no stored value / `sv_*`, no top-ups, no
real comms (synthetic-only), no points movement (0 rows), no studio-driven credit movement
(only legacy referral), no new activation surface (v57 adds no table — only an ALTER of the
existing PS-1B `rule_effect_log` — and both functions remain revoked from
public/anon/authenticated).

### Notes carried forward (do NOT block PASS)

- **N1 — internal-SQL-error path not persisted on UAT (accepted).** Because pricing stayed
  healthy, the `WHEN OTHERS` → `status:'error'` + `PS1B_PRICING_ERROR` audit row +
  executor `'failed'` outcome was NOT persisted on UAT. It is directly runtime-proven in
  the v57 acceptance suite (cases g/h/i, ALL PASS) on a full 91-chain replay whose v57
  bytes are hash-identical to UAT, and the live UAT schema demonstrably supports the outcome
  (allowlist includes `'failed'`, `failure_reason` present, `failed⟺reason` CHECK enforced).
  The audit-write mechanism (SECURITY DEFINER owner bypassing RLS) is the same pattern used
  by numerous existing functions. Risk of divergent UAT behaviour: negligible. The
  coordinator offered to persist one via a deliberately-dangling catalog id — a worthwhile
  OPTIONAL confirmatory artifact, but not a gate given the identical-hash rehearsal proof
  and the three fail-closed statuses I confirmed live above.
- **N2 — §6 harness artifacts, not defects.** The first `run_referral_shadow` executed
  inside a rolled-back transaction (its shadow row rolled back; re-run persistently after —
  final state has exactly the required 1 shadow row), and one comparator call issued in the
  same statement as the sweep saw STABLE-function snapshot visibility (expected Postgres
  MVCC; a fresh-statement re-read showed the true state — which is the normal operational
  pattern, since the comparator runs as a separate monitoring call). Neither affects the
  integrity of the final persisted evidence, which I re-verified clean (comparator
  `clean:true` in its own statement). Benign operational reminder: run
  `app.compare_shadow_vs_live` in a statement separate from the executor sweep.

### Standing gate reminder
This PASS clears PS-1B.1 §1 on the UAT database only. Production apply to
`gadpooereceldfpfxsod` as the live surface remains blocked until the owner writes
`RELEASE APPROVED` (CLAUDE.md standing gate). PS-1C / stored-value / any value-moving
executor path remain forbidden and tripwired.
