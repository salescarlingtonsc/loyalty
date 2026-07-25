# PS-2 LIVE Increment v69 — Controlled Cutover (PINNED)

Implements directive §9. **This is the increment that lets real customer money move.** Forward-only;
v61–v68c untouched. Reviewer/orchestrator: Fable. Builder base: the v68c freeze.
Pending version `20260725100000`. The migration itself moves ZERO value and activates NO business —
it builds the *mechanism*; activation is a separate, owner-designated runtime act.

## A. What v69 is — and is not
v69 makes `sv_authority.state='live'` REACHABLE for exactly one owner-designated business, through an
evidence-checked, audited, idempotent, fail-closed cutover RPC. It does NOT activate anyone by running,
does NOT enable global activation, does NOT touch customer self-service payment, real comms,
cross-business value, C2C transfer, or unrestricted cash-out. Every non-designated business stays
`unbuilt` and structurally unable to move value.

## 1. Ground truth this must respect (verified against prod 2026-07-25)
- `preview_sv_cutover` currently returns **`ready` HARDCODED false** with the comment "PS-2A ships a
  preview only, never a cutover action". v69 must replace that with a TRUTHFUL computation. The
  existing blocking-reason set (authority≠live, reconciliation never run, open discrepancies,
  all-scope pause active) is the floor, not the ceiling.
- `set_sv_authority_state` + the v61/v62 guard currently make `live`/`ready_for_cutover` unreachable.
  v69 must open the path **only** through the new cutover RPC — do NOT broadly relax the guard, and do
  NOT delete the tripwire that keeps `live` unreachable by ordinary state-setting.
- **7 cron jobs exist; NONE are stored-value.** `sv_expire_due`, `sv_release_expired_checkout_tenders`
  and `run_sv_reconciliation` are callable but unscheduled.

## 2. HARD REQUIREMENT — SV automation must exist BEFORE any business can go live
Wire all three as pg_cron jobs in the same migration, following the 7 existing `frenly-*` jobs'
conventions (naming, SGT-anchored times, `active`):
- **expiry sweep** — `sv_expire_due` daily, at an SGT-quiet hour that does not collide with the existing
  19:00–19:20 UTC block.
- **checkout-tender release** — `sv_release_expired_checkout_tenders` frequently (minutes-scale; abandoned
  holds must not strand a customer's balance).
- **reconciliation** — `run_sv_reconciliation` daily.
Then make the cutover RPC **refuse** if any of the three jobs is missing or inactive (typed
`sv_automation_missing`). Value that can expire without a scheduled sweep is value that silently rots;
a business must not go live into that state. Assert both the jobs' existence and the refusal in tests.

## 3. The cutover RPC
`public.sv_cutover_business(p_business uuid, p_reason text, p_evidence_hash text, p_idempotency_key uuid)`
- Owner-only (`app.is_salon_owner`) AND super-admin co-authorization if cheap to express; if not, owner
  only + audit. Reason mandatory (≥10 chars — this is a financial go-live, not a toggle).
- Refuses unless EVERY condition holds, each with its own typed error:
  `sv_not_ready` (preview not ready), `sv_reconciliation_unclean`, `sv_paused`,
  `sv_automation_missing` (§2), `sv_synthetic_business` (a synthetic business may never go live),
  `sv_already_live` (idempotent replay returns the stored result, does not re-transition).
- Records: actor, business, prior state, new state, reason, evidence hash, timestamp — in `audit_log`
  AND as an append-only cutover record (reuse `sv_plan_status_events`-style append-only shape or a new
  `sv_cutover_events` table; justify the choice).
- `sv_operations` idempotency envelope (unique key + request hash + advisory lock + cached replay).
- **NEVER global**: takes exactly one business id; no "all", no loop, no wildcard. A tripwire test must
  assert no function anywhere can transition more than one business per call.

## 4. Truthful readiness
Replace `preview_sv_cutover`'s hardcoded `ready:false` with a real computation over §3's conditions,
returning the same `blocking_reasons` shape (append, never remove, the existing reasons). `ready` must be
true ONLY when a subsequent `sv_cutover_business` call would succeed — preview and act must agree.
Assert agreement in tests (preview says ready ⇒ cutover succeeds; preview says blocked ⇒ cutover raises
the corresponding typed error).

## 5. Reversibility + emergency
- Emergency pause (`sv_pause` scopes all/earn/redeem) stays independent and keeps working on a live
  business — it is the kill switch and must NOT require cutover to be undone.
- Document (and test) the supported path back: a live business can be paused instantly; whether `live →
  ready_for_cutover/unbuilt` is permitted at all is an **owner decision** — pin the safe default as
  "not reversible by RPC; pause is the emergency control" and flag it for ratification rather than
  inventing a downgrade that could strand issued value.

## 6. LOW-1 from the v68b review (carried forward)
Concurrent door-A-vs-door-B settlement reversal currently resolves via Postgres deadlock detection
(40P01) for the loser rather than a typed refusal — fail-closed, money invariants hold. Either impose a
consistent lock order (advisory-lock-first in the sale core) or document 40P01 as an accepted retriable
outcome in the reversal RPCs' contract. State which you chose and test it.

## 7. Tests (`db/tests/v69_…` rolled back + concurrency harness)
Full refusal matrix (every typed error in §3, each proven to mutate nothing and reserve no key);
preview↔act agreement (§4); automation-missing refusal with a job disabled (§2); synthetic business
refused; idempotent replay + changed-request conflict; two-connection concurrent cutover → exactly one
transition; pause still works post-live; the v66 mint tripwire, v67 tender gates and v68a/v68b
refusal/lift behaviour all still hold on a live business; **and the whole PS-0 lettered-case oracle
re-run against a LIVE business** (this is the first time the arithmetic runs outside a forced-live
shim — it must be cents-exact there too). Chain gates: fresh replay v61→v69; ALL prior suites; validate;
prod-shape splice harness; writer registry; `git diff --check`.

## 8. Release ceremony
Freeze → independent adversarial review on the exact SHA → **PASS V69** → dry-run gate (exactly one
pending, no `--include-all`) → `db push --linked` → post-apply verification INCLUDING: cron jobs present
and active, `preview_sv_cutover.ready` computes (not hardcoded), **every real business still `unbuilt`**,
zero real value rows, canary unchanged → reconcile + deploy.
**Applying v69 must not cut over anybody.** Designating and cutting over the pilot business is a
separate owner act requiring the owner's explicit business designation, and remains gated on the
launch-evidence decisions.

## 9. Explicitly NOT in v69
Activating any business; customer self-service payment; real WhatsApp/SMS/email; cross-business value;
C2C transfer; unrestricted cash-out; legacy gift-card/credit migration (that is v70).
