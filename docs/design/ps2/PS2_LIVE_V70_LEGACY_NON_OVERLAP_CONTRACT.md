# PS-2 LIVE Increment v70 — Legacy Gift-Card / Credit Non-Overlap (PINNED)

Implements directive §10. Forward-only; v61–v69 untouched. Reviewer/orchestrator: Fable.
Builder base: the v69 freeze. Pending version `20260725110000`. **Applying v70 moves ZERO value and
activates nobody**; every real business stays `unbuilt` until an owner-designated v69 cutover.

## A. The mandate's premise is FALSE — corrected against prod (2026-07-26)
The mandate records "3 gift_cards / 4 credit_ledger are synthetic/test-only (prior ground truth G2)".
Measured live:

| business | is_synthetic | active gift cards | legacy gift-card ¢ | legacy credit ¢ | SV ledger ¢ | recon snapshots |
|---|---|---|---|---|---|---|
| **kopi tiam** (pilot candidate) | false | **1** | **5000** | 0 | 0 | **0** |
| QA Go-Live Cafe | false | 1 | 5000 | 0 | 0 | 0 |
| QA Test Cafe | false | 0 | 0 | **12000** | 0 | 0 |
| ZZ-SYNTHETIC PS1B1 UAT Journey | **false** (name-only) | 0 | 0 | 300 | 0 | 0 |
| ZZZ Stored-Value Shadow Canary | true | 0 | 0 | 0 | 5500 | 0 |

Nothing here is structurally synthetic except the canary. **kopi tiam — the only plausible pilot —
holds a LIVE $50 gift card and has never been reconciled.** Two clients hold non-zero legacy credit.
v70 must therefore be a real reconciliation/decision increment, not a documentation exercise.

## B. The blocking interaction v70 exists to resolve
v62's reconciliation compares the SV ledger against **gift_cards as the legacy analog**. kopi tiam
today: legacy 5000¢ vs SV 0¢ ⇒ a `missing_in_studio` discrepancy. v69 refuses cutover on
`sv_reconciliation_unclean`. **So kopi tiam cannot pass v69 readiness while that card is
outstanding and unreconciled.** This is a live blocker on the pilot, not a hypothetical. v70 must
make the intended relationship explicit and machine-checked.

## 1. Decide and encode the relationship (the core of v70)
The two legacy value systems (`gift_cards` balances, `credit_ledger` store credit) and stored value
must have a stated, enforced relationship. Implement **non-overlap**, the safe default:
- A business that is `live` on stored value must not simultaneously issue NEW legacy gift-card or
  store-credit value — one live value authority per business per asset. Existing outstanding legacy
  value is **honoured to extinction**, never silently voided or migrated.
- Express this as a typed refusal in the legacy issuing paths (`issue_gift_card` both overloads,
  `record_credit_tender` and any other legacy minting path the builder finds — enumerate them from the
  catalog, do not assume this list is complete): refuse with `sv_live_legacy_issue_blocked` when that
  business's `sv_authority.state = 'live'`. **Redemption of already-issued legacy value must keep
  working** — blocking redemption would strand customer money (the v14 don't-strand-rows ruling).
- Do NOT migrate legacy balances into SV lots. Migration would mint SV value with no payment evidence,
  which v68a's `sv_no_payment_evidence` cap exists to forbid, and would double-count against the
  original cash. State this explicitly in the header.

## 2. Make reconciliation truthful about outstanding legacy value
Reconciliation must be able to reach "clean" for a business that legitimately holds outstanding legacy
gift cards while running zero SV. Today a non-zero legacy balance against a zero SV ledger reads as a
discrepancy, which would block cutover forever.
- Introduce an explicit, auditable **acknowledgement**: an owner (or super-admin) records that a given
  business's outstanding legacy balance is known, accepted and excluded from the SV comparison — with
  reason, actor, timestamp, and the exact acknowledged cent amount, append-only.
- Reconciliation then compares SV against legacy **net of acknowledged amounts**, and a discrepancy
  reappears if the legacy balance moves beyond what was acknowledged. Acknowledgement must be a
  statement about a specific measured amount, never a blanket "ignore legacy for this business".
- Assert both directions: acknowledged ⇒ clean; legacy grows past the acknowledgement ⇒ dirty again.

## 3. Inventory + classification (directive §10's original ask)
Produce a machine-generated inventory of every outstanding legacy value row (business, kind, cents,
status, age), and record the owner-facing classification for each business: `pilot` (honour to
extinction, non-overlap enforced), `qa_reset` (test data the owner may clear), or `retain_fixture`.
**v70 must NOT delete or reset anything** — classification is data + docs; any actual reset is a
separate owner-authorised act. Emit the inventory as a report RPC or a documented query, and include
the measured table in the migration header so it is reviewable without DB access.

## 4. ZZ-SYNTHETIC is not structurally synthetic
`ZZ-SYNTHETIC PS1B1 UAT Journey` has `is_synthetic = false` (it predates v66's structural flag) yet
carries 300¢ of legacy credit and is named as synthetic. Either mark it structurally via v66's
`set_synthetic_marker` (preferred — it makes billing exclusion and every synthetic guard correct) or
document why not. Flag, don't guess: if marking it changes any historical projection, report instead.

## 5. Gates + non-goals
No value moved; no legacy row deleted, voided or migrated; no cutover; no activation. Typed refusals
mutate nothing. Suite: legacy issue refused on a live business (each enumerated path), legacy
redemption still works on a live business, acknowledgement makes reconciliation clean, legacy drift
re-dirties it, inventory matches a hand-computed table, and every prior suite stays green.
Ceremony: freeze → independent adversarial review → **PASS V70** → dry-run gate (exactly one pending,
no `--include-all`) → `db push --linked` → post-apply verification (**every real business still
`unbuilt`; kopi tiam's $50 card still active and untouched**) → reconcile + deploy.
