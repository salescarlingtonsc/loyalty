# PS-1A (Program Studio authoring/projection/validation) — independent review verdict

**Reviewer independence.** I did not author any PS-1A artifact (the v55 migration, the Studio
UI, the test suite, the gate/registry updates). I have no stake in PS-1A passing. This verdict
stands in for the owner's independent-reviewer ("Sol") gate and is grounded in the committed
artifacts and the real schema under `supabase/migrations/*.sql`, verified by reading the code,
re-deriving behavior, running the Node gates, and grepping the truthfulness claims myself.

- **Commit reviewed:** `04614e883a38654afb5a46121ae13b865b18084d`
  (branch `codex/phase0-transaction-foundation`, HEAD; parent `ad72eae`; working tree clean).
- **Date:** 2026-07-24.
- **Runtime division:** I cannot run `psql`. I verified the v55 migration and suite by reading
  and mapped every suite assertion to a criterion; I **rely on the coordinator's rehearsal for
  runtime evidence** (FRESH from-scratch 89/89 canonical replay incl. the final v55 bytes, v55
  suite PASS, full matrix 48/48 on the fresh chain, DB pristine) — that division is per house
  process. Everything runnable from Node I ran: `npm run validate` (451/451 + build),
  `ps0-no-executor` (6/6), `ps0-writer-registry` (via validate), plus targeted greps.

---

## Criterion table (owner's 18 + 3 truthfulness + PLUS)

| # | Criterion | Result | Evidence |
|---|-----------|--------|----------|
| 1 | Every existing programme appears once in the unified overview | **PASS** | `get_programs_overview` returns registry(10) + legacy_programs (from `v_program_rules_all`) + studio_rules; suite §4 asserts `count(distinct rule_key) == array_length` (no duplicate) and the points-earn programme present. |
| 2 | Adapter projections match native config byte-for-byte or by documented canonical equivalence | **PASS** | `v_program_rules_all.native_config = to_jsonb(source_row)` for all six engine branches (byte-identical by construction); suite §3 byte-compares the earn row to `loyalty_program_versions` and asserts every row carries `native_config`; WHEN/IF/THEN restatement documented inline per engine. (See N1.) |
| 3 | No adapter row is a copied second source of truth | **PASS** | `relkind='v'` (zero storage), asserted by suite §1; the view derives everything from live engine tables joined on `active_config_version_id`. |
| 4 | Draft edits never alter active legacy configurations | **PASS** | `program_rule_version_guard` permits writes only on a `draft` firm_config_version; `save_program_rule_draft` writes only `program_rules`; suite §5 byte-compares loyalty_programs+tiers+retention before/after a draft edit and asserts `active_config_version_id` unchanged. |
| 5 | Published legacy configs + historical transactions unchanged | **PASS** | The only migration-time legacy mutation is `refresh_loyalty_config_snapshot` recomputing `firm_config_versions.snapshot_hash` (DO block l.1113-1119) — the v37b/c45 precedent (3rd occurrence); it touches config metadata only, no loyalty/sale/ledger/transaction row, and the historical publish `snapshot_hash` is preserved in `audit_log`. Precedent judged acceptable (see Findings). |
| 6 | Invalid event/condition/operator/effect/schedule/limit/stacking cannot validate | **PASS** | `program_rule_errors` enforces schema/event/field/operator/effect allowlists + schedule (SGT) + stacking sanity; suite §9 rejects invalid event, unknown field, bad operator, out-of-allowlist effect, non-SGT schedule, malformed stacking, over-limit conditions/effects; publish refuses any invalid rule atomically (suite §8). |
| 7 | No arbitrary SQL, client price, or client cost formula can enter a rule | **PASS** | Structural bars reject `price_cents`/`unit_price_cents`/`catalog_price` (`client_supplied_price`) and `sql`/`expr`/`expression`/`raw` (`sql_fragment_forbidden`); top-level/condition/effect keys are hard allowlists; prices are server-resolved via `catalog_id` + `ps1a_catalog_ref_valid`; UI Advanced is structured fields only (no freetext JSON/SQL); suite §9 rejects a `price_cents` and an `sql` fragment. |
| 8 | Canonical-equivalent rules hash identically | **PASS** | `program_rule_canonical` orders arrays + drops non-semantic fields (name/sort/active/notes); suite §10 proves reordered conditions + different name/sort → identical `rule_hash`. |
| 9 | Materially different rules hash differently | **PASS** | Suite §10: threshold 5000 vs 6000 → different hash. |
| 10 | Complexity limits enforced | **PASS** | ≤10 conditions, ≤8 effects (`program_rule_errors`); ≤200 active rules at publish; suite §9 rejects 11 conditions and 9 effects. |
| 11 | Owner/manager/staff permissions fail closed | **PASS** | UI: fail-closed `route()` guard for typed `#/studio` (`pageKey==='studio' && S.myRole!=='owner'`, l.1149-1150) + tab hidden for non-owners (`canStudio=S.myRole==='owner'`); DB: every authoring RPC gates `is_salon_owner` → 42501; suite §11 denies manager (save/get/delete/validate/overview) and anon. |
| 12 | Cross-business configuration access impossible | **PASS** | `ps1a_catalog_ref_valid` binds every catalog ref to `p_business`; RPCs gate on the version's `business_id`; view predicate `is_salon_owner(business_id)`; suite §3 (no B rows to A) + §12 (owner A denied on B draft/overview). |
| 13 | New Studio rules remain authoring-only | **PASS** | `ps1a_studio_rule_state` returns only draft/validated/validation_failed/ready_for_activation; a published studio rule → `ready_for_activation` (never live); no consumer moves value; suite §7. |
| 14 | No financial/customer-value executor exists | **PASS** | `ps0-no-executor` 6/6 (now permits the 6 authoring artifacts only when PS-1A is authorized, still forbids every executor artifact + studio ledger-guard scope + registry-authority mutation); adversarial grep finds no `event_outbox`/`rule_effect_log`/`benefit_fulfilments`/`budget_periods`/`sv_lot` and no `credit_ledger`/`points_ledger`/`reward_grants`/`sales` insert in v55; `benefit_registry` is append-only (BEFORE UPDATE/DELETE guard). |
| 15 | Every visible button has loading/success/validation/denied/conflict/error states | **PASS** | `setStatus` maps all six states with `aria-live`; save handler: disabled+aria-busy+"Saving…", 42501→denied, 40001→conflict+Reload, else→error, →"Saved."; publish + delete handlers likewise; save disabled while invalid. |
| 16 | Desktop/tablet/390px usable | **PASS (static)** | Grid layouts use `minmax(0,1fr)`; `@media` breakpoints (≤700/640/520px) collapse condition/effect cells and field-grids to single column. No browser run — static judgment only. |
| 17 | Owner understands a recommendation without technical JSON | **PASS** | Plain-language `STUDIO_EVENT_LABEL`, `STUDIO_ERRMAP`, `studioErrText` (e.g. "Prices come from your catalog, not from the rule."); the only rule `JSON.stringify` (l.6482) renders inside the collapsed Advanced `<details>` — never the default presentation. |
| 18 | Advanced editing progressively disclosed | **PASS** | Quick Start + Guided + Advanced; Advanced is a collapsed `<details class="studio-advanced"><summary>Advanced — limits, stacking & technical detail</summary>`. |
| T1 | `studioStateChip` can never emit Live/Active/Running | **PASS** | Static label set = {Draft, Validated, Ready for activation, Validation failed}; fallback = Validation failed; grep confirms zero live/active/running tokens in the function body. |
| T2 | Legacy chips are mechanically separate | **PASS** | `legacyStateChip` (l.5924) and `studioStateChip` (l.5929) are distinct functions; legacyStateChip is used only for legacy_trigger engines (which truthfully do run). |
| T3 | "will not run until a later activation phase" explainer present | **PASS** | Explainers at l.5263/6097/6104/6110/6188 ("Authoring only", "will not run", "records these rules for a later activation phase — it does not run them and does not change the counter"). |
| T4 | No Studio content in customer wallet / checkout routes | **PASS** | Grep of `app/customer-ui.js` and `app/join.html` for program_rules/overview/studio* is empty; the app/index.html change touches no checkout/sale/tender/wallet flow. |
| + | `npm run validate` | **PASS** | Exit 0; 451 tests, 0 fail; static build. |
| + | Writer-registry allowlist of the 5 authoring RPCs follows the `save_retention_program_draft` precedent | **PASS** | delete/get_draft/get_overview/save/validate program-rule RPCs are in `allowlist` (not `writers`) with the identical "read-only / config / non-value writer" reason; registry test 7/7 (0 missing/0 stale). |
| + | No unrelated work in the commit | **PASS** | All 18 delta files classified PS-1A-scoped (UI, migration+mirror+suite, gate, registry, tripwire, migration bookkeeping ×N, foundation-test v55 registration); `git diff --check` clean; secret scan over the delta clean; db/ and supabase/ v55 bodies byte-identical. |

---

## Findings

No BLOCKING or SHOULD-FIX findings. Two NOTE-level observations, neither affecting
correctness, security, truthfulness, or the no-executor guarantee:

- **N1 (NOTE) — §8a header wording.** The `v_program_rules_all` header comment says the
  per-engine equivalence is "documented in the column comments below," but the equivalence is
  actually documented in inline block comments per engine (`-- Engine N: … equiv: …`), not
  `COMMENT ON COLUMN` statements. The equivalence *is* documented and the `native_config`
  column is byte-identical to the source row by construction (`to_jsonb`); this is a wording
  imprecision only.
- **N2 (NOTE) — suite equivalence breadth.** The v55 suite byte-compares `native_config` to the
  source row for the **earn** engine (§3) and asserts `native_config` presence for all rows, but
  does not field-by-field re-derive the WHEN/IF/THEN restatement for the tiers/rewards/retention/
  birthday/referral branches. This is acceptable — `native_config = to_jsonb(source)` guarantees
  byte-equivalence for every engine by construction, and criterion 2 allows documented canonical
  equivalence — but a future suite could add a representative restatement check per engine for
  defense in depth.

**Positive notes worth recording:** the `benefit_registry` uses the corrected 2-arg
`tier_entry:{client_id}:{tier}` key (the PS-0 F1 fix) and an authority↔status CHECK constraint;
the definer-view choice is explicitly justified and honestly flagged as an accepted advisor
lint (heterogeneous underlying RLS incl. browser-closed birthday config); the snapshot recompute
follows an established precedent; and the truthful-state design uses two mechanically separate
chip functions so a studio rule can never structurally render as live.

---

## OVERALL VERDICT: **PASS PS-1A**

All 18 acceptance criteria, all 3+1 truthfulness requirements, and the PLUS items are met, with
zero BLOCKING or SHOULD-FIX findings. The adapter is a genuine zero-storage read-only projection
whose rows are 1:1 derivable from native config; draft authoring is version-scoped and provably
cannot alter active legacy configuration (byte-compared); the compiler enforces allowlist
conformance, structural bars against SQL and client prices, catalog-tenancy, deterministic
canonical hashing, and complexity limits; permissions fail closed at both the UI route guard and
every owner-gated RPC; cross-business access is impossible; studio rules are authoring-only and
structurally cannot report live/active (grep-proven, two separate chip functions); no executor or
customer-value movement exists and the tripwire + PS-GATES honestly authorize PS-1A while keeping
PS-1B+ locked; the UI presents plain language by default with technical JSON only behind an
Advanced disclosure and complete button-state handling; and the commit contains no unrelated work
or secrets, with the full gate green (validate 451/451, no-executor 6/6, diff-check clean).

The only migration-time mutation of existing rows is the `snapshot_hash` recompute
(v37b/c45 precedent, config-metadata only) — which I judge acceptable.

Per the owner's process, PS-1A is accepted: the coordinator may land the v55 authoring/
projection/validation schema under the PS-GATES marker (`PS-1A: yes`). No executor phase is
authorized by this work; production apply remains gated by `RELEASE APPROVED` in `CLAUDE.md`,
and PS-1B/1C/stored-value/production stay `authorized: no`.

I did not modify any file other than this verdict, and I did not commit.
