# PS-0 acceptance — independent review verdict

**Reviewer independence.** I did not author any PS-0 artifact (contracts, discovery tool,
tests, reconciliation SQL, or the architecture doc). I have no stake in PS-0 passing. This
verdict stands in for the owner's independent-reviewer ("Sol") gate and is grounded in the
actual committed artifacts and the real schema under `supabase/migrations/*.sql`, verified by
running the tools and re-deriving the arithmetic myself — not by trusting the document's
self-description.

- **Commit reviewed:** `5e2ff5c93a100dd2b80940ac9cd70109c83254f0`
  (branch `codex/phase0-transaction-foundation`, HEAD; working tree clean apart from this file).
- **Date:** 2026-07-23.
- **What I ran:** `scripts/ps0/discover-writers.mjs` ×2 (byte-identical); all five
  `tests/program-studio/*` suites (56 tests, all pass); `EXPECTED_SUPABASE_PROJECT_REF=gadpooereceldfpfxsod npm run validate`
  (exit 0; 449 tests + build). I re-derived SV cases by machine, spot-checked 6 writers and
  adversarially hunted 4 more against migration source, and read the reconciliation SQL and all
  contract docs critically. I could not run the reconciliation SQL against a database (none
  available); I verified it by reading, as the criterion allows.

---

## Per-criterion table

| # | Criterion | Result | Evidence |
|---|-----------|--------|----------|
| 1 | Exhaustive, repeatable writer discovery | **PASS** | Discovery byte-identical on two runs; `ps0-writer-registry` 7/7. 211 identities / 100 value-impact / 78 curated writers / 133 allowlist. Spot-checked 6 (wrapper `enroll_membership_v41/3`, trigger `trg_sale_recorded` AFTER INSERT, browser-direct `sell_package` @6539, `redeem_gift_card/4`, `record_cart_sale/7`, idempotent `enroll_membership_v41/4`) — every idempotency/locking/policy attribute matches source. Adversarially hunted points-expiry crons, birthday redemption, v53 feedback, birthday reversal — all present/correctly classified. No known writer absent. |
| 2 | Canonical event identity prevents dup emission | **PASS** | EVENT_CONTRACT `UNIQUE(business_id, event_type, source_operation_id, schema_version)` + `ON CONFLICT DO NOTHING` matches arch §6 correction; `ps0-event-identity` 9/9; scheduled/period source keys deterministic + collision-tested (`sweep:{job}:{business}:{sgt_date}`, `membership_renewal:{id}:{period_key}`). |
| 3 | Effect uniqueness prevents dup execution | **PASS** | `(event_id, rule_id, effect_index)` runs each effect exactly once; full-pipeline replay under fresh UUIDs changes nothing (tested). |
| 4 | Canonical benefit keys don't collide | **PASS (with MEDIUM finding F1)** | `ps0-benefit-keys` 10/10 — bijective parser, cross-family non-collision, batch collision-free, arity/component validation. **But** BENEFIT_REGISTRY_CONTRACT.md §4 gives `tier` as 3-arg `tier_entry:{business_id}:{client_id}:{tier}`, contradicting the arch's reconciled 2-arg ruling (§3 l.138 + §12 l.493, "business scope lives in the UNIQUE constraint, not the key") and the shipped test (`['client','tier']`). Lone unreconciled family. → F1. |
| 5 | Refund arithmetic conserves + partials terminate | **PASS** | `ps0-sv-arithmetic` 26/26; all 7 numbered rounding requirements present in the arch (incl. #7 termination) and tested; 400-scenario fuzz + determinism. I re-derived case (g) A=$100+$12/B=$200+$50 spend$50 → **A $58.56 / B $200.00**, single-op spent$56 → **$50.00**, coordinator's A $49.70/B $50.00, and the inverted-FEFO edge — all conserve to the cent. |
| 6 | Value reconciliation proves single-representation | **PASS (read, not run)** | `db/tests/ps0_value_reconciliation.sql` exercises points→credit (balance deltas + redeem row), gift-card→credit (explicit card-XOR-credit conservation, using the `redeem_gift_card_v41` fix), package→sessions (conservation), + a global "no double-count into credit" cross-check. Assumptions A1–A4 documented and self-localizing; deferrals (membership/SV) honestly stated. Assertions genuinely prove the invariant for the three live conversions. |
| 7 | Every value concept has reversal + idempotency | **PASS** | All value contracts carry both (EVENT, BENEFIT_REGISTRY, STORED_VALUE, VALUE_DOMAIN). STORED_VALUE assigns every `movement_type` a signed direction + reversal/clawback and idempotency keys, and pins the round-3 SF2 partial-refund cash semantics (X = cash returned; terminal step claws entire bonus). ECONOMICS carries 0 idempotency rules correctly — it defines read-only measures, no value-bearing write concept. |
| 8 | No financial executor enabled | **PASS** | No PS/executor table (`program_rules`, `benefit_fulfilments`, `event_outbox`, `budget_periods`, `sv_*`, …) in the migration set; `loyalty_ledger_write_guard` scope enum has NO studio scope; `ps0-no-executor` 4/4; PS-GATES.md authorizes PS-0 only, enumerates every executor artifact + studio scope → phase, with an owner-quote change protocol. |
| 9 | Owner's four pre-work corrections truthfully applied | **PASS** | (a) header = "revision 4, PS-0 active / review PASS round 3 / PS-0 approved, PS-1+ NOT authorized"; (b) "Canonical event identity (owner correction, PS-0)" section present (§6); (c) all 7 refund rounding requirements present; (d) zero fixed-count surface references — replaced by "never stops at a predetermined count" (§17). Bonus: the round-3 SF1 stale "generalize v33" refs are cleaned (ERD + §17 now "NEW event_outbox … v33 untouched"; §1a row struck through + marked HISTORICAL). |
| 10 | Full gate `npm run validate` | **PASS** | Exit 0. quality → runtime-config:check → migration-manifest:check → canonical-migrations:check → 449 tests (0 fail) → static build all green. |
| G | Accounting worksheet scope-honesty | **PASS** | §0 explicitly disclaims: "not a legal opinion, not an accounting compliance certification, not tax advice"; "no figure … is an exact accounting liability until the business's accountant selects a policy." Configuration aid only; no hard compliance claim found. |
| — | Hard audit findings — block PS-0 or document? | **DOCUMENT SUFFICES** | The `sell_package/3`, `enroll_membership_v41/3`, and browser-direct `expenses`/`stock_batches` write hazards **predate PS-0** and are correctly captured (HARD findings, marked MUST-NOT-as-is, remediation sequenced into the PS-1C kernel that revokes the /3 grants). PS-0 is contracts+audit **by design** — surfacing these IS the deliverable. Fixing them is code work outside PS-0's remit and under the `RELEASE APPROVED` gate. They do **not** block PS-0. (See F2 — owner should still be aware they are live double-charge/double-grant hazards worth near-term remediation independent of the PS timeline.) |

---

## Findings

### MEDIUM — F1 (the one required change)

**`docs/design/ps0/BENEFIT_REGISTRY_CONTRACT.md` §4 (line 104) states the `tier` family's
canonical key as `tier_entry:{business_id}:{client_id}:{tier}` — 3-arg — which contradicts the
architecture's reconciled ruling and the shipped test.** The architecture is internally
consistent and explicit: §3 (l.138) and §12 (l.493) both use **2-arg** `tier_entry:{client}:{tier}`,
with §12 stating "the business scope lives in the UNIQUE constraint, not the key"; and
`tests/program-studio/ps0-benefit-keys.test.mjs` enforces `tier_entry: ['client','tier']` (a
3-arg build would throw "stray component"). Every **other** family in the contract's own §4
table correctly omits `business_id` (relying on `UNIQUE(business_id, canonical_benefit_key)`);
`tier` is the lone outlier. Impact is low — `tier` is a PS-3 (unbuilt) family and the authoritative
test is already correct — but this is a confirmed contradiction in a PS-0 contract deliverable, on
exactly the arity ruling criterion 4 was asked to verify, so it must be reconciled before the
contract set is internally consistent.
*Fix:* change line 104 to `tier_entry:{client_id}:{tier}` (matching §3/§12 and the test); no code
change is required.

### NOTE — F2 (owner awareness; not a PS-0 blocker)

The three HARD audit findings are pre-existing **live-app** hazards, faithfully documented:
- `sell_package/3` and `enroll_membership_v41/3` are non-idempotent value writers still
  `execute`-granted to `authenticated` **and** still called directly by the standalone UI
  (`app/index.html:6539` / `:5816`) — a double-tap books a duplicate sale + duplicate
  `client_packages`/membership.
- `app/index.html` writes `expenses` (P&L, `:7003`) and `stock_batches` (inventory) directly
  from the browser.

Documenting them satisfies PS-0. However, because they are customer-facing double-charge /
double-grant risks in production **today**, the owner may want a targeted remediation
(revoke the `/3` grants, move the UI to the idempotent `/4` overloads, route the browser-direct
writes through RPCs) ahead of — and independent of — the full PS-1C kernel, rather than waiting
for the kernel to absorb them. The medium findings (`redeem_gift_card` / `adjust_points` /
drawer movements lacking idempotency keys) are correctly characterised and appropriately
deferred to their phases.

---

## OVERALL VERDICT: **CHANGES REQUIRED**

PS-0 is, in substance, an excellent and genuinely complete piece of work: the writer audit is
exhaustive, deterministic, and survived adversarial probing; the event-identity, effect-uniqueness,
benefit-key, and refund-arithmetic contracts are tested and (where I re-derived them) correct to
the cent; the value-reconciliation SQL genuinely proves single-representation for every live
conversion; no financial executor exists and the PS-GATES marker makes that auditable; all four
owner corrections (and the round-3 SF1/SF2 items) are truthfully applied; the full `validate` gate
is green; and the accounting worksheet is scope-honest. The hard audit findings do **not** block
PS-0 — surfacing them is the audit's job, and their fix is correctly sequenced into PS-1C.

Acceptance is withheld on a **single, precise, one-line change**: **F1** — reconcile the `tier`
family's canonical key in `BENEFIT_REGISTRY_CONTRACT.md` §4 to the 2-arg form
`tier_entry:{client_id}:{tier}` that the architecture (§3/§12) and the shipped test already
mandate. This is the only confirmed contradiction in a PS-0 deliverable, and criterion 4
explicitly required verifying it. With F1 corrected (no code change, no re-run of the engines
needed beyond the already-green benefit-key test), PS-0 meets every acceptance criterion and I
would return **PASS PS-0**. F2 is an owner-awareness note, not a gate.

**Required to convert to PASS:** F1 only.
