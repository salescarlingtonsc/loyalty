# Peekaa Permanent Bug-Closure Protocol

**Owner directive. This file is the canonical source.** `AGENTS.md` and `CLAUDE.md` point here;
if they ever disagree with this file, this file wins.

## Core principle

> **Every production bug should make Peekaa permanently harder to break.**

A bug is **not** closed because the affected tenant works, the screenshot looks right, a row was
backfilled, or the suite is green. It is closed when the knowledge from the defect has been
converted into automated guards, so the owner never has to manually rediscover the same class of
inconsistency.

Whenever a bug is reported, assess **without waiting to be asked** whether it warrants
(A) an acceptance regression, (B) a tenant scanner rule, and/or (C) lifecycle certification —
and add them.

## The ten layers

For any production bug, assess and apply each layer where relevant. "Not relevant" is a legitimate
answer; *unconsidered* is not. State explicitly which layers you applied and which you judged
inapplicable, and why.

### 1. Fix and verify the live symptom
Restore correct behaviour for the affected customer or business, and verify the **real production
reader or output** after the fix — not a local reproduction, not a fixture, not the source diff.

### 2. Identify the underlying defect class, not only the affected tenant
Never conclude "tenant X had bad data". Determine **what system behaviour ALLOWED tenant X to
acquire that shape, and whether another tenant can acquire it.** Prefer fixing the writer, the
authority, the invariant, or the lifecycle that created the bad state over repairing its output.

### 3. Add an executable regression that would have caught the bug
A test reproducing the exact failure shape. It **must fail against the old behaviour and pass
after the fix** — run it against the unpatched system first and record that it failed. Prefer
exercising BEHAVIOUR over grepping source: a source-regex assertion stays green over dead code.

Design the assertion so it can only pass for the right reason. If the code path under test can
fail for several unrelated reasons (permissions, scope, missing rows, bad arguments), a bare
"it raised" assertion is worthless — vary exactly one input and require the **outcome to change**.

### 4. Extend the divergence scanner when the invalid state is detectable estate-wide
`db/tests/tenant_divergence_scan.sql`, enforced by `npm run tenant-gate`. Ask: *can this failure
already exist silently in another tenant?* Classify findings:
- **runtime-dangerous** → blocking;
- **intentional documented exception** → an explicit, narrowly scoped waiver (never broad or
  global) in `db/tests/tenant_divergence_allowlist.json`;
- **historical / informational** → non-blocking.

Getting severity right matters more than flagging loudly: a check that reddens the gate during
normal, legitimate operation trains people to ignore it.

A new check must be **proven able to fail** — restore the pre-fix condition inside a rolled-back
transaction and watch it fire. A gate that cannot fail teaches nothing.

### 5. Extend lifecycle certification for state-transition bugs
`db/tests/tenant_lifecycle_certification.sql`, run by `npm run certify-tenant`. Add a step when
the bug represents a lifecycle or state transition — new tenant creation; programme ON/OFF;
Points↔Stamps; publish after an unrelated settings change; stale draft; a reward becoming
claimable or non-claimable; a customer earning before/after configuration; birthday, welcome or
referral configuration; redemption; programme switching; permission changes.

### 6. Verify canonical correctness — reader agreement is not correctness
For important business state (current programme; active/off; balance; stamp target; earning rate;
claimability; reward eligibility; expiry; who may use a module) define the **canonical answer**
and have all consumers derive from the same authority.

> `Reader A == Reader B` is **NOT** sufficient evidence.
> Require `Reader A == Reader B == the canonical business rule`.

A consistency check can only ever see disagreement; it is blind to a defect both readers inherit,
and it goes tautological the moment one reader is made to delegate to the other. Every such gate
needs a sibling check that states the rule **directly against the authority**.

### 7. Scan all tenants for the same failure shape
Run the scanner across the estate and identify every affected tenant. Never repair tenants one at
a time without closing the source of corruption. Measure and report the blast radius **before**
applying a fix that changes who is permitted or what is served.

### 8. Backfill bad state only after closing the writer that created it
Order matters: **stop the writer, then repair the data.** A backfill applied while the creating
path is still live re-breaks on the next write — this is exactly how the same defect returns
"after it was already fixed once". Backfills must be narrowly scoped, auditable, and idempotent
where practical, preceded by evidence and followed by verification.

### 9. Fail closed — never hide invalid production state behind UI defaults
Missing or contradictory required production state must not be papered over with cosmetic
defaults. **Defaults may initialise a NEW DRAFT; defaults must never fabricate live production
state.** If live configuration is invalid, refuse the publish or return an explicit configuration
failure rather than rendering a plausible guess.

### 10. Re-run the gates and prove no fixture or probe residue remains
Re-run the relevant gates after the fix, and prove the work left nothing behind: no fixture rows,
no probe accounts, no mutated real rows, no widened entitlements. Suites that touch production
must run inside `begin; … rollback;`. When verifying residue, prefer structural proof over
timestamps — rows written in the same transaction share its fate, so the absence of one proves the
absence of its siblings.

## Commands

| Command | Layer |
|---|---|
| `npm run tenant-gate` | 4, 7 — divergence scanner; exits non-zero on unwaived runtime-dangerous rows |
| `npm run tenant-gate:prove` | 4 — proves the scanner still detects an injected divergence (a gate on the gate) |
| `npm run certify-tenant` | 5 — lifecycle certification |
| `npm test` | 3 — the repo suite |

When each MUST run, verdict semantics, the allowlist rules and the reference canaries are in
[`docs/design/ps0/TENANT_CONSISTENCY_GATES.md`](../design/ps0/TENANT_CONSISTENCY_GATES.md).

## Worked examples

### nestly_v568 — why layer 6 exists
`reward_availability_v432` let a **parked** points gift render as "READY · 5 stamps" because its
closed-cycle arm joined reward versions without a programme-id predicate. The existing scanner
check could not catch it: it compared presentation against the availability core, and a previous
change had just made presentation *delegate* to that core — so the check had become "is X equal to
X", tautologically green while the shared core was wrong. Fix: check **D16** now states the rule
directly against the core's own answer — no reward may be offered while its own programme is off.

The same trap appeared in the fixture: the certification's points gift cost 10 against a 5-slot
card, so the faulty predicate could not fire. One number away from catching it.

### nestly_v572 / v573 — layers 3, 6, 7 and 10 in one incident
A module the owner switched **Off** was enforced at the page but nowhere near the data: six tables
carried only a membership-keyed policy, so a denied teammate could re-price *and delete* services
over the API, and sixteen RPCs asked only a ROLE permission — and every `staff` role carries
`view_sales` and `create_sales` by definition, so "gated on view_sales" meant "gated on being
staff".

- *Layer 3:* the first version of the RPC suite asserted only "the call raised", and passed for
  three reasons that had nothing to do with modules. It was rewritten to probe each module twice —
  Off then On — with one variable changed, minting its own probe account so a positive control
  existed. Where a module is platform-disabled estate-wide, it records `DENIAL-ONLY` rather than a
  false green.
- *Layer 6:* checks **D19** (a module-owned table's write commands must consult
  `app.can_module_write`) and **D20** (a module's principal RPC must consult `app.can_module`)
  state the rule against the catalogue, so they also cover accounts that do not exist yet.
- *Layer 7:* blast radius was measured before applying — 17 owners and every inherit-staff
  unaffected, 2 explicitly-denied accounts affected, which was the intended effect.
- *Layer 10:* certification step 18i initially "passed" against an already-fixed production
  because the harness swapped JWT claims but **not** the database role, and RLS never applies to
  the table owner. Any certification step testing RLS must `set local role authenticated`.
