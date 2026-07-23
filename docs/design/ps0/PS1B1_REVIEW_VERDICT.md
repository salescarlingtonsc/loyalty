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
