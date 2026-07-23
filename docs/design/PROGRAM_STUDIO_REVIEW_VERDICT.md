# Program Studio architecture — independent review verdict

**Reviewer independence.** I did not author `PROGRAM_STUDIO_ARCHITECTURE.md` (authored by
Fable 5) and have no stake in its passing. This review stands in for the owner's
independent-reviewer ("Sol") gate. It is grounded in the real schema under
`db/migrations/*.sql` (latest definition wins) and in `CLAUDE.md`'s standing invariants,
not in the document's own claims about itself.

- **Target:** `docs/design/PROGRAM_STUDIO_ARCHITECTURE.md`, **revision 4**.
- **Date:** 2026-07-23.
- **Round:** 3 (re-review after rev 4 claimed to close all round-2 findings).
- **Method:** each round-2 finding re-checked for *actual* closure; the S2-R refund
  arithmetic recomputed by machine (including the coordinator's numbers and my own
  inverted-FEFO edge probe); a fresh grep-sweep for internal contradictions the rev-4
  edits may have left behind.

---

## Verdict table (14 required corrections) — revision 4

| # | Item | Verdict | One-line justification |
|---|------|---------|------------------------|
| 1 | Stored-value refunds / arbitrage killed | **PASS** | Single- and multi-operation arithmetic both recomputed and correct; spend allocation now fully pinned (aggregate split + cross-op FEFO + per-op refund). |
| 2 | One value-domain, single-representation proof | **PASS** | Unchanged and sound; the two async tables (event_outbox / v33) hold delivery-state vs notification-evidence — neither is economic value, so the value-domain invariant is untouched. |
| 3 | Event envelope + sync/async + comms can't roll back checkout | **PASS** | Envelope + uniqueness intact; delivery now on a NEW `event_outbox`, v33 left immutable (§6). Two stale cross-refs to the abandoned approach remain — finding SF1, not a design flaw. |
| 4 | Adapter execution authority / double-grant prevented structurally | **PASS** | Real `benefit_fulfilments` UNIQUE constraint; single-writer rule (current authority holder) removes the round-2 collision (§3/§7). |
| 5 | Rule compiler | **PASS** | Unchanged and complete. |
| 6 | Checkout token + atomicity + kernel prerequisite | **PASS** | Token/atomicity intact; real-writer surface list enumerated (§9). |
| 7 | Economics / no double-count / cohort exposure | **PASS** | Registry row carries face/est cost captured at fulfilment; realized cost computable for every class incl. birthday (§10). |
| 8 | Budget reservation / promise never vanishes | **PASS** | Counter authoritative + deterministic lock order (business_id, rule_id, period_start) → deadlock-free (§11). |
| 9 | Tier qualification provenance + policies | **PASS** | `qualifying_amount` denominated per earn-unit; policies complete (§12). |
| 10 | Plan versioning mandatory | **PASS** | Unchanged and sound. |
| 11 | Consent separation | **PASS** | Unchanged and sound. |
| 12 | Recurring perks materialisation | **PASS** | Unchanged and sound. |
| 13 | Composer provenance + experiences | **PASS** | Unchanged and sound. |
| 14 | Sequencing PS-0/1A/1B/1C, money last & gated | **PASS** | Phasing intact. (§17 PS-1B row carries a stale outbox description — finding SF1.) |

**All 14 items PASS**, and — for the first time across three rounds — there are **zero
BLOCKING findings**. The remaining items are SHOULD-FIX cleanups, listed below.

---

## Disposition of every prior finding (rounds 1–2)

| Finding | Status | Evidence / note |
|---|---|---|
| **B1** cross-store canonical-key uniqueness unenforceable | **CLOSED** | Real single-table `benefit_fulfilments` with `UNIQUE(business_id, canonical_benefit_key)` (§3 l.110–128). |
| **B2** payments-as-atomic vs completion≠payment / A-R | **CLOSED** | Tender optional/decoupled; total fixed at completion; A/R first-class (§6 l.228–237, §9 l.325–327). Agrees with live v11b (`p_paid` default true). |
| **B3** birthday realized cost uncomputable | **CLOSED** | `benefit_fulfilments.face_value_cents`/`estimated_cost_cents` captured at fulfilment from `benefit_snapshot` (§10 l.350–354); c45 confirms the snapshot column exists. |
| **B4** v33 outbox "additive generalization" impossible | **CLOSED (design)** | §6 drops the retrofit; NEW `event_outbox` owns delivery state; v33 untouched as evidence store, crisp non-overlap (§6 l.239–254). Respects the append-only guard + pinned CHECKs I verified in v33/v46. **Residual:** two stale cross-refs still assert the old plan → SF1. |
| **B5** shadow-mode registry-write self-contradiction | **CLOSED** | Only the current execution-authority holder writes `benefit_fulfilments`; shadowing evaluator writes only the shadow log; comparator diffs shadow log vs the live engine's registry rows (§3 l.117–123, §7 l.278–281). The live engine's registry rows are guaranteed to exist during shadow (adoption insert lands "when it enters shadow"), so the comparator has its data. |
| **S1** `topup` kind/policy row absent | **CLOSED** | PS-2 extends `sales.kind` CHECK + adds the defaults row (§5 l.208–213, §17). |
| **S2** multi-lot / partial refund scope undefined | **CLOSED** | Per-operation refund scope defined (§5 l.202–206). |
| **S2-R** multi-op spend allocation ambiguous | **CLOSED** | Pinned: aggregate-class split, cross-op FEFO within class (expiry→earned→lot id), per-op refund (§5 l.165–181). Arithmetic verified below. |
| **S3** ledger write-guard enum rejects studio writes | **CLOSED** | `studio_executor` scope extension is a PS-1B/1C deliverable (§17). |
| **S4** proposed outbox vs live v33 unreconciled | **CLOSED** | Superseded by B4's resolution (new table, not a generalization). |
| **S5** budget_periods vs v50 dual-authority/race | **CLOSED** | budget_periods sole authority for studio; v50 legacy until cutover (§11 l.398–401). |
| **S6** qualifying_amount units for stamps | **CLOSED** | Denominated per earn-unit; matches v24 (points col = `floor(amount/stamp_per_cents)`) (§12 l.419–423). |
| **S7** "seven surfaces" undercount | **CLOSED** | Real-writer list incl. phone till + deposits + entitlement redemptions (§9 l.335–342). |
| **S8-R** budget-lock deadlock risk | **CLOSED** | Deterministic global lock order (business_id, rule_id, period_start) (§11 l.390–393). |
| **N1** ERD 1:1 over-constraint | **CLOSED** | Reference mandatory only when value moves (§3 l.90, §10 l.346–349). |
| **N2/N3** unlabeled tables; branch-price rationale | **CLOSED** | Phase labels (§3 l.103–108); config-version + price re-resolution both checked (§9 l.328–330). |
| **N4** "rolls the whole business fact back" vs optional tender | **CLOSED** | Reworded: a failure rolls back only its own transaction, never a completed sale (§6 l.228–230). |
| **N5** canonical-key formats unspecified | **CLOSED (mechanism)** | Registered template per fulfilment kind, validated at write (§3 l.123–127). **Residual:** examples cover natural-key kinds only; per-event kinds (checkout discount, SV movement) not exemplified → NOTE N6. |

**Every round-1 and round-2 finding is closed.** Two closures carry narrow residuals
(SF1, N6) and one new spec ambiguity surfaced in the sweep (SF2).

---

## Verification detail

**S2-R arithmetic (recomputed by machine).** Op A = 10 000¢ paid / 1 200¢ bonus; Op B =
5 000¢ paid / 500¢ bonus; spend 5 600¢. Aggregate 15 000 paid / 1 700 bonus / 16 700 total.
Bonus draw = `floor(5 600 × 1 700 / 16 700)` = **570¢**; paid draw = **5 030¢**. Cross-op
FEFO (A first): both draws land wholly on A → A 4 970 paid / 630 bonus remaining, B untouched.
Refund A = **$49.70** + 630¢ clawback; refund B = **$50.00** + 500¢ clawback; total
refundable 9 970¢ = total paid remaining (15 000 − 5 030). The coordinator's figures are
correct to the cent, and the rule is now deterministic enough that two engineers land
identically.

**Inverted-FEFO edge (my probe): B's bonus expires *before* A's.** Bonus-class FEFO now
draws B first: 500¢ from B (→0), 70¢ from A (→1 130); paid-class FEFO unchanged (5 030¢
from A). Refund A = $49.70 + 1 130¢ clawback; refund B = $50.00 + 0 clawback; conservation
still 9 970¢ = 9 970¢, no arbitrage (remaining bonus is always clawed, never cashed).
Because FEFO is applied **independently per class** with a total-order tiebreak
(expiry → earned → lot id) and the split uses the aggregate ratio, inverting one class's
expiry order changes only *which* lot is drawn, never the drawn *amounts* or the refund
outcome. The rule is unambiguous under the inversion.

---

## Remaining findings

### SHOULD-FIX (must be reconciled before PS-1B; neither re-architects anything)

**SF1 — the B4 fix is not propagated to two current normative sections, which still
instruct the abandoned, schema-impossible "generalize v33" approach.** §6 and §1b correctly
establish a NEW `event_outbox` with v33 left untouched, but:
- **§3 ERD, l.89:** `domain_events ||--o{ event_outbox : "async effects (generalized v33
  outbox)"` — still labels the outbox a *generalized v33*.
- **§17 PS-1B, l.491:** `` `domain_events` + outbox (generalizing the v33 table — S4) `` —
  the build-sequence table still tells the implementer to generalize v33.

An engineer building PS-1B from §17 would attempt exactly the retrofit B4 proved impossible
against v33's append-only guard and pinned `delivery_status` CHECK. §6 is unambiguous and
authoritative, so this is a propagation/editorial defect, not a design error — but it is a
live internal contradiction on the single most-scrutinised fix and must be corrected.
*Fix:* change l.89 to `"async effects (delivery state; NEW table, PS-1B)"` and l.491 to
`` `domain_events` + NEW `event_outbox` (delivery state; v33 untouched — B4) ``. Optionally
annotate the superseded §1a/S4 row (l.51) as "superseded by §1b/B4."

**SF2 — §5 partial-refund-of-one-operation wording conflicts with the paid-only cash
rule.** The refund rule (l.183) is "cash refund = paid-class remaining only; bonus clawed
back," but the partial-refund clause (l.205–206) says a partial refund "splits
proportionally across that operation's remaining classes." Bonus can never be paid out as
cash (§4: "never cash-out"), so "proportional across classes" is under-defined for a *cash*
refund: it does not say whether a requested "$X refund" means **$X of cash received** (then
X comes from paid, with a proportional bonus clawback) or **$X of value withdrawn** (then
the customer receives only the paid fraction as cash). Two engineers would build the partial
path differently. The whole-operation matrix rows are unaffected and fully deterministic;
this is scoped to the owner-configurable partial-refund variant. *Fix:* state that a partial
refund's amount is the **cash returned** (drawn from that operation's paid remaining), with
a proportional bonus clawback recorded alongside — and give one numeric partial-refund row.

### NOTE

**N6 — §3/N5: register the key template for the per-event fulfilment kinds too.** §10 says
checkout discounts and SV movements "register their rows" in `benefit_fulfilments`, but the
§3 template examples are all natural-key benefits (retention, tier_entry, birthday,
recurring, campaign_offer). Add the synthetic-unique templates for the per-event kinds
(e.g. `discount:{sale_id}:{effect_index}`, `sv_move:{movement_id}`) so the UNIQUE constraint
neither collapses distinct fulfilments nor is mistaken for an anti-double-grant guarantee it
cannot provide for those kinds.

**N7 — §3 l.119 phrasing.** "the legacy engine while authority = legacy or shadow" conflates
`execution_authority` (legacy_trigger) with `cutover_status` (shadow); the intent (legacy
engine writes the registry through both the `legacy` and `shadow` cutover states, studio
only after `studio`) is clear from context, but tightening the wording to reference
`cutover_status` explicitly would remove the last trace of the round-2 ambiguity.

---

## OVERALL VERDICT: **PASS**

Implementation may begin per the phase gates in §17. All 14 required corrections PASS and
there are **zero BLOCKING findings** — the first clean pass across three review rounds. Every
round-1 blocker (B1–B3) and every round-2 blocker (B4, B5) is genuinely closed against the
real schema, not merely acknowledged; the stored-value refund arithmetic (single- and
multi-operation, plus my inverted-FEFO edge) is verified correct to the cent; the async
delivery model now respects v33's append-only invariants instead of trying to retrofit them;
and the shadow-mode registry-write contradiction is resolved with the comparator still fully
fed.

Two SHOULD-FIX items (**SF1** stale "generalize v33" cross-references in §3 ERD l.89 and §17
PS-1B l.491; **SF2** partial-refund proportional-split wording) and two NOTEs (**N6**, **N7**)
should be cleared as part of the PS-0 contracts pass — SF1 in particular must be reconciled
before any engineer builds PS-1B, so nobody works from the superseded outbox instruction.
None of them gate the PASS: SF1 is an un-propagated edit to a fix that §6 states correctly,
and SF2 is a spec-tightening on an owner-configurable variant.

---

## Review history

- **Round 1 (rev 2): FAIL.** Item 4 FAIL. Blocking: **B1** (canonical-key uniqueness
  unenforceable across 7 heterogeneous fulfilment stores), **B2** (payments-as-sync-atomic
  + no on-account path contradicted the live completion≠payment / A-R invariant), **B3**
  (birthday/entitlement realized cost uncomputable from cost-less fulfilment rows).
  Should-fix: **S1** (topup kind/policy row absent), **S2** (multi-lot/partial refund scope
  undefined), **S3** (ledger write-guard enum rejects studio writes), **S4** (proposed
  outbox vs live v33 unreconciled), **S5** (budget_periods vs v50 dual-authority/race),
  **S6** (qualifying_amount units for stamps), **S7** ("seven surfaces" undercount). Notes:
  **N1** (ERD 1:1 over-constraint), **N2/N3** (unlabeled new tables; branch-price rationale).
  Positive: §5 refund arithmetic recomputed and correct.
- **Round 2 (rev 3): FAIL (narrowed).** All 14 items PASS. B1/B2/B3 and
  S1/S3/S5/S6/S7/N1/N2/N3 closed; S2 partially closed (residual S2-R). New blocking: **B4**
  (v33 outbox generalization incompatible with the live append-only table), **B5**
  (benefit_fulfilments shadow-write self-contradiction). New should-fix: **S2-R** (multi-op
  spend allocation), **S8-R** (budget lock ordering). Notes: **N4** (tender rollback
  wording), **N5** (canonical-key templates).
- **Round 3 (rev 4): PASS.** All 14 items PASS; zero BLOCKING. B4 and B5 closed; S2-R
  arithmetic verified (incl. inverted-FEFO edge); S8-R/N4/N5 closed. Remaining: **SF1**
  (stale "generalize v33" cross-references in §3 ERD + §17 PS-1B — must reconcile before
  PS-1B), **SF2** (partial-refund proportional-split wording), notes **N6** (per-event key
  templates), **N7** (§3 authority/cutover phrasing).
