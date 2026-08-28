# Peekaa Permanent Bug-Closure Protocol

**Owner directive. This file is the canonical source.** `AGENTS.md` summarises it and `CLAUDE.md`
points here; if either ever disagrees with this file, **this file wins**.

## Core principle

> **Every production bug should make Peekaa permanently harder to break.**

A bug is **not** closed because the affected tenant works, the screenshot looks right, a row was
backfilled, or the suite is green. It is closed when the knowledge from the defect has been
converted into an automated guard, so nobody has to rediscover the same class of inconsistency by
hand.

Two corollaries carry equal weight:

- **Every fix hardens the system.** If a fix leaves no new guard behind, the same class of bug is
  free to return through a different door.
- **Every fix leaves the codebase cleaner than it found it.** A fix that adds a parallel
  implementation beside the broken one has not closed the bug — it has doubled it (§5).

## Contents

| § | Section | Use it when |
|---|---|---|
| 1 | [Triage](#1-triage) | The moment a bug is reported |
| 2 | [The ten layers](#2-the-ten-layers) | The rule itself — the spine of every closure |
| 3 | [Verification standards](#3-verification-standards) | Proving any claim in this document |
| 4 | [False-closure traps](#4-false-closure-traps) | Before believing a green result |
| 5 | [Cleanliness rules](#5-cleanliness-rules) | While writing the fix |
| 6 | [Waivers](#6-waivers) | A finding is intentional |
| 7 | [Definition of Done](#7-definition-of-done) | Before claiming closure |
| 8 | [Commands and related governance](#8-commands-and-related-governance) | Running the gates |
| 9 | [Worked examples](#9-worked-examples) | Learning why a layer exists |

---

## 1. Triage

Answer these four questions **before** writing the fix. They decide how much of the protocol is
mandatory and they are cheap; skipping them is what turns a one-hour fix into a repeat incident.

### 1.1 Severity

| Severity | Definition | Obligation |
|---|---|---|
| **P0** | Money, permissions, tenant isolation, customer-visible data loss, or a reward/ledger integrity defect. Anything a customer or a tenant could exploit or be harmed by. | All ten layers assessed. Incident record (§1.4). Blast radius measured before applying. |
| **P1** | Wrong behaviour on a real surface with no money or permission consequence — a reader disagreeing, a screen not reflecting state, an automation not firing. | Layers 1–7 and 10 assessed; 8–9 where relevant. |
| **P2** | Cosmetic or single-surface presentation with no state consequence. | Layers 1–3 and 10. State explicitly that 4–9 were considered and why they do not apply. |

When severity is ambiguous, **treat it as the higher one** until evidence says otherwise. A
permission or ledger defect is P0 even when only one tenant is currently affected — reachability,
not observed impact, sets the severity.

### 1.2 Exposure window — how long has this been live?

Establish **when the defect became reachable** and therefore how much production state may already
be wrong. Usually the migration or commit that introduced it. This drives layer 7 (how far back to
scan) and layer 8 (how much to backfill). "Since v182" and "since yesterday" are different
incidents with the same symptom.

Record the answer even when it is *"unknown, bounded by X"*. Never assume "probably recent".

### 1.3 Data exposure and privacy ⚖️

For any defect touching permissions, RLS, tenant isolation, or a reader that returns another
party's data, state plainly:

- **what data was reachable**, by **whom**, and for **how long** (§1.2);
- whether any of it is personal data (names, phone numbers, spend history, birthdays);
- whether cross-tenant exposure was possible, or only intra-tenant over-permission.

**Flag ⚖️ for the owner and counsel when personal data was reachable by a party who should not
have had it — do not assess legal or PDPA obligations here, and never assert compliance.** The
engineering duty is to state the facts accurately and promptly; the disclosure decision is the
owner's.

### 1.4 Incident record

Every P0 gets a durable record. The canonical record is the **commit message on the fix**, which
must state: the symptom as reported, the proven root cause, the exposure window, the blast radius
measured before applying, which layers were applied, and the evidence (suite results, gate
verdicts). A migration additionally carries this in its header comment and a `ROLLBACK:` pointer
to its acceptance suite.

This is deliberately not a separate tracker: the record lives with the change it describes, so it
cannot drift from it.

---

## 2. The ten layers

Assess and apply each layer where relevant. **"Not relevant" is a legitimate answer;
*unconsidered* is not.** State which layers you applied and which you judged inapplicable, and why.

### 1. Fix and verify the live symptom
Restore correct behaviour for the affected customer or business, and verify the **real production
reader or output** after the fix — not a local reproduction, not a fixture, not the source diff.
See §3.1 for what counts as verification.

### 2. Identify the underlying defect class, not only the affected tenant
Never conclude *"tenant X had bad data"*. Determine **what system behaviour ALLOWED tenant X to
acquire that shape, and whether another tenant can acquire it.** Prefer fixing the writer, the
authority, the invariant, or the lifecycle that created the bad state over repairing its output.

Peekaa's recurring defect class has one shape, seen repeatedly: **a permission, flag or state that
some readers honour and others ignore.** When a bug matches that shape, the fix is to make the
ignoring reader ask the authority — never to special-case the tenant.

### 3. Add an executable regression that would have caught the bug
A test reproducing the exact failure shape. It **must fail against the old behaviour and pass
after the fix** — run it against the unpatched system first and record that it failed (§3.3).
Prefer BEHAVIOUR over source inspection: a source-regex assertion stays green over dead code.

Design the assertion so it can only pass for the right reason (§3.4).

### 4. Extend the divergence scanner when the invalid state is detectable estate-wide
`db/tests/tenant_divergence_scan.sql`, enforced by `npm run tenant-gate`. Ask: *can this failure
already exist silently in another tenant?* Classify every finding:

- **runtime-dangerous** → blocking;
- **intentional, documented** → an explicit narrowly scoped waiver (§6);
- **historical / informational** → non-blocking.

Getting severity right matters more than flagging loudly: **a check that reddens the gate during
normal, legitimate operation trains people to ignore the gate.** A pending invite, a disarmed
historical draft and a deliberate pilot override are not defects.

Prefer a check that states the rule **against the catalogue or the authority** over one that
probes only the accounts that happen to exist today — the latter goes quiet when those accounts
are removed and says nothing about an account created tomorrow.

Every new check must be **proven able to fail** (§3.3).

### 5. Extend lifecycle certification for state-transition bugs
`db/tests/tenant_lifecycle_certification.sql`, run by `npm run certify-tenant`. Add a step when the
bug represents a lifecycle or state transition — new tenant creation; programme ON/OFF;
Points↔Stamps; publish after an unrelated settings change; stale draft; a reward becoming
claimable or non-claimable; a customer earning before/after configuration; birthday, welcome or
referral configuration; redemption; programme switching; permission or access-state changes.

### 6. Verify canonical correctness — reader agreement is not correctness
For important business state (current programme; active/off; balance; stamp target; earning rate;
claimability; reward eligibility; expiry; who may use a module) define the **canonical answer** and
have every consumer derive from the same authority.

> `Reader A == Reader B` is **NOT** evidence.
> Require `Reader A == Reader B == the canonical business rule`.

A consistency check can only see *disagreement*. It is structurally blind to a defect both readers
inherit, and it becomes tautological the instant one reader is made to delegate to the other.
**Every consistency gate needs a sibling check that states the rule directly against the
authority.**

### 7. Scan all tenants for the same failure shape
Run the scanner across the estate and identify every affected tenant. Never repair tenants one at
a time without closing the source of corruption.

**Measure blast radius before applying** any fix that changes who is permitted or what is served,
and state it in the incident record: who loses access, who gains it, who is unaffected, and which
of those changes are the intended effect. A fix whose blast radius was never measured is a fix
whose side effects will be discovered by a customer.

### 8. Backfill bad state only after closing the writer that created it
Order matters: **stop the writer, then repair the data.** A backfill applied while the creating
path is still live re-breaks on the next write — this is precisely how a defect returns *"after it
was already fixed once"*.

Backfills must be narrowly scoped, auditable, and idempotent where practical; preceded by evidence
of exactly which rows are wrong, and followed by verification that they are now right and that
nothing else moved.

### 9. Fail closed — never hide invalid production state behind UI defaults
Missing or contradictory required production state must not be papered over with cosmetic
defaults. **Defaults may initialise a NEW DRAFT; defaults must never fabricate live production
state.** If live configuration is invalid, refuse the publish or return an explicit configuration
failure rather than rendering a plausible guess.

A guessed default is worse than an error: the error gets fixed, the guess gets trusted.

### 10. Re-run the gates and prove no fixture or probe residue remains
Re-run the relevant gates after the fix, and prove the work left nothing behind: no fixture rows,
no probe accounts, no mutated real rows, no widened entitlements, no leftover grants.

Suites that touch production run inside `begin; … rollback;`. When checking for residue, prefer
**structural proof over timestamps** — rows written in the same transaction share its fate, so the
absence of one proves the absence of its siblings (§3.5).

---

## 3. Verification standards

These apply to every claim made under §2. They exist because each was, at some point, the reason a
bug was believed fixed when it was not.

### 3.1 Verify against production, as the real principal

- **Production, not a local stub.** Local schemas lack prod's FKs, triggers and CHECK constraints;
  fixtures that pass locally fail in prod, and vice versa.
- **As the real role.** `set local role authenticated` before probing anything RLS governs.
  **RLS never applies to the table owner**, so a probe running as the migration role proves
  nothing about a policy. The same applies to `SECURITY DEFINER` functions: inside them, RLS is
  not in play, so their own guard *is* the whole boundary.
- **The service, not the artifact.** A deploy fingerprint proves a file shipped, not that the
  system works. Probe the real reader or RPC.

### 3.2 Executable, not textual

Prefer a test that *runs* the behaviour. Source greps and identifier pins pass over dead code,
unreachable screens and functions nothing calls. Where a structural check is genuinely the right
tool (a catalogue-wide invariant, §2.4), say so explicitly and pair it with an executable suite.

### 3.3 Prove the check can fail

A new test or scanner rule must be run against the **unpatched** condition and observed to fail —
restore the pre-fix state inside a rolled-back transaction if the fix is already applied. Record
that result. **A gate that has never failed is a gate of unknown value.**

### 3.4 One variable, and a positive control

If the code path can fail for several unrelated reasons — permissions, scope, missing rows, bad
arguments — then "it raised" is not evidence. Vary **exactly one** input and require the
**outcome to change**. Build the fixture that makes the positive control possible; if the positive
control is genuinely unavailable, record the weaker guarantee **by name** rather than presenting it
as the full one.

### 3.5 Prove the absence, don't assume it

For residue, dead code, or "nothing else uses this": search both directions and prefer structural
argument. PL/pgSQL resolves names at run time, so a dropped object breaks callers silently —
inspect function bodies before removing anything. A migration-history table under-records; probe
for the **objects**, not the ledger.

---

## 4. False-closure traps

Each of these has produced a green result over a live defect in this repo. Check the list before
believing a pass.

| Trap | Why it passes | The correction |
|---|---|---|
| **Tautological consistency check** | Both readers delegate to one core, so `X == X` | State the rule against the authority (§2.6) |
| **Source-regex assertion** | The string is present; the behaviour is dead | Execute the path (§3.2) |
| **Fixture that cannot fire** | Fixture values sit outside the faulty predicate's range | Rebuild the fixture to the exact failing shape |
| **The test stubs what it tests** | The stub answers, the real function never runs | Call the real implementation |
| **Privileged probe** | Runs as owner/definer, so RLS never engages | `set local role authenticated` (§3.1) |
| **Literal count pin** | Fails or passes for reasons unrelated to the property | Assert the property per item, not the total |
| **Version gate by equality** | `contract === 'vNNN'` dies silently when the server bumps | Gate on a **minimum**, never equality |
| **History says applied** | The ledger row exists; the object does not | Probe the object (§3.5) |
| **Fingerprint says deployed** | The file shipped; the API is down | Probe a real reader (§3.1) |
| **Screenshot predates the fix** | Re-implementing something already shipped | Render current `HEAD` and diff before acting |
| **Silent no-op call** | A builder assigned but never awaited sends nothing | Ensure the call is actually executed |
| **Cross-tree evidence** | Capture tooling points at another worktree's port | Pin the target explicitly before capturing |

---

## 5. Cleanliness rules

The system stays maintainable only if fixes *reduce* surface area. These are binding, not advice.

1. **One authority per fact.** Current programme, balance, claimability, "may this account use
   module X" — each has exactly one canonical resolver. A fix must route through it, never add a
   second opinion beside it.
2. **Fix the shared path, not the caller.** If three readers are wrong, fix the thing they share.
   Patching them one at a time creates the next divergence.
3. **No parallel implementations.** Never leave the broken path in place beside a new one "just in
   case". If a path is superseded, remove it in the same change, or record in the commit exactly
   why it must remain and what would let it go.
4. **Delete what the change orphans.** Wrapper functions with no callers, dead branches, stale
   drafts, superseded flags. Verify both directions before deleting (§3.5).
5. **Do not widen scope to make a test pass.** Never weaken security, RLS, tenant isolation, or
   ledger correctness for a green result. If a pinned expectation blocks a correct change, rewrite
   the assertion as a *property*; do not delete it.
6. **A migration must be replay-safe.** Idempotent from every state it may meet, including a
   partially-applied earlier attempt, with preconditions that abort on drift rather than silently
   patching a body that has moved.
7. **Enforce at the authority; honour at every surface.** A server-side gate with a client that
   still shows the control is a half-fix; a client-side hide with no server gate is not a fix at
   all. Both, or the layer is not closed.

---

## 6. Waivers

A scanner finding that is genuinely intentional may be waived in
`db/tests/tenant_divergence_allowlist.json` — under these conditions only:

- **Exact scope.** A specific `check_id` + `business_id` pair. Never a whole check, never a
  wildcard, never "all tenants".
- **A stated reason** naming who decided and why it is correct, not merely tolerated.
- **A review date.** A waiver is a deferral, not a verdict. Re-justify it or remove it.
- **Never to silence a real defect** because a fix is inconvenient or a deadline is close. If it
  is a defect, it is an open bug with a severity (§1.1).

---

## 7. Definition of Done

Closure is claimed by walking this list explicitly. Anything not applicable is stated as such with
a reason — the checklist is answered, never skipped.

```
INCIDENT: <one line — the symptom as the owner reported it>
SEVERITY: P0 | P1 | P2            EXPOSURE WINDOW: <since when / bounded by>
DATA EXPOSURE: <none | what, to whom, for how long — ⚖️ flagged?>

 1 live symptom fixed and verified against the production reader ......... [ ]
 2 defect class identified; the writer/authority/lifecycle fixed ......... [ ]
 3 executable regression added, PROVEN to fail before the fix ............ [ ]
 4 divergence scanner rule added, proven able to fail .................... [ ] / n-a
 5 lifecycle certification step added ................................... [ ] / n-a
 6 canonical correctness verified against the rule, not reader agreement . [ ]
 7 estate scanned; blast radius measured BEFORE applying ................. [ ]
 8 writer closed BEFORE any backfill; backfill scoped and verified ....... [ ] / n-a
 9 invalid state fails closed; no cosmetic default fabricates live state . [ ]
10 gates re-run; no fixture/probe residue; mutated rows restored ......... [ ]

CLEANLINESS: one authority [ ]  no parallel path left [ ]  orphans deleted [ ]
GATES: npm test ____/____   tenant-gate ____   certify-tenant ____
```

---

## 8. Commands and related governance

| Command | Layer |
|---|---|
| `npm run tenant-gate` | 4, 7 — divergence scanner; exits non-zero on unwaived runtime-dangerous rows |
| `npm run tenant-gate:prove` | 4 — proves the scanner still detects an injected divergence (a gate on the gate) |
| `npm run certify-tenant` | 5 — lifecycle certification |
| `npm test` | 3 — the repo suite |

- Gate semantics, when each MUST run, the allowlist rules and the reference canaries:
  [`docs/design/ps0/TENANT_CONSISTENCY_GATES.md`](../design/ps0/TENANT_CONSISTENCY_GATES.md).
- A fix that ships a migration also carries the migration governance chain — two byte-identical
  file copies, an acceptance suite, grants, both order plans, both manifests, the pinned counts and
  the writer registry. Follow the existing migrations as the pattern; the counts are pinned
  deliberately so that adding a migration cannot be silent.
- Client changes ship through the bundle pipeline: `app/app.js` is the single source, and the
  generated chunks must be re-stamped or the CDN serves a stale build.

---

## 9. Worked examples

### nestly_v568 — why layer 6 exists
`reward_availability_v432` let a **parked** points gift render as "READY · 5 stamps" because its
closed-cycle arm joined reward versions without a programme-id predicate. The existing scanner
check could not catch it: it compared presentation against the availability core, and a previous
change had just made presentation *delegate* to that core — so the check had become "is X equal to
X", tautologically green while the shared core was wrong. Fix: check **D16** states the rule
directly against the core's own answer — no reward may be offered while its own programme is off.

The same trap sat in the fixture: the certification's points gift cost 10 against a 5-slot card, so
the faulty predicate could not fire. One number away from catching it.

### nestly_v572 / v573 — layers 3, 6, 7 and 10 in one incident
A module the owner switched **Off** was enforced at the page but nowhere near the data: six tables
carried only a membership-keyed policy, so a denied teammate could re-price *and delete* services
over the API, and sixteen RPCs asked only a ROLE permission — and every `staff` role carries
`view_sales` and `create_sales` by definition, so "gated on view_sales" meant "gated on being
staff".

- **Layer 3:** the first version of the RPC suite asserted only "the call raised" and passed for
  three reasons unrelated to modules. Rewritten to probe each module twice — Off then On — with one
  variable changed, minting its own probe account so a positive control existed. Where a module is
  platform-disabled estate-wide it records `DENIAL-ONLY` rather than a false green.
- **Layer 6:** checks **D19** (a module-owned table's write commands must consult
  `app.can_module_write`) and **D20** (a module's principal RPC must consult `app.can_module`) state
  the rule against the catalogue, so they cover accounts that do not exist yet.
- **Layer 7:** blast radius measured before applying — 17 owners and every inherit-staff
  unaffected; 2 explicitly-denied accounts affected, which was the intended effect.
- **Layer 10:** certification step 18i initially "passed" against an already-fixed production
  because the harness swapped JWT claims but **not** the database role. Any step testing RLS must
  `set local role authenticated`.

### nestly_v559 / v560 / v563 — why layer 8 orders the work
A publish path kept copying a stale `active` flag from a version snapshot onto the live row. The
data was backfilled once and looked fixed; the **next publish re-applied the lie**, because the
writer was still live. Three separate organs of the same disease shipped before the writer itself
was corrected. Stop the writer, then repair the data — never the reverse.
