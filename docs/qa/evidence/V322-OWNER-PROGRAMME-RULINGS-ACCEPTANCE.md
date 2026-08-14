# V322 — the owner rulings of 2026-08-14, all six

Owner instruction for this wave, verbatim: **"proceed to fix it, dont over do it. just give me what
i want without breaking what we built."** Six rulings, one migration, one client wave. Nothing else
was redesigned; the W5 money kernel is asserted unchanged rather than merely left alone.

| ruling | what shipped | where |
|---|---|---|
| **R6** | the wizard's Programmes step is SCOPE-only; a separate on/off control per programme on the Rewards Programme page | `app/app.js` |
| **R2/R3** | stamps is exclusive — a server guard at the one spine writer, and the wizard states it before it does it | `nestly_v322` + `app/app.js` |
| **R1/R4** | referral stops writing `credit_ledger` and pays POINTS; the wizard asks for points | `nestly_v322` + `app/app.js` |
| **R5** | the stamp card is a quest with an unbounded, customisable milestone list | `app/app.js` (no schema change) |
| copy | four wrong sentences rewritten, in every locale each surface has | `app/app.js` |

---

## R6 — unselecting a programme is not turning it off  ← THIS WAS A LIVE DEFECT

> "if i unselect the program does not mean i want to turn off (i need a seperate button) — it just
> means i do not want to edit the rewards at this point in time"

**What was broken in production.** The wizard's Publish ran
`writeProgrammeSwitchesV314(S.biz.id,{...state.switches},…)` — all four kinds, every time — and the
comment above it said so on purpose. So an owner who opened the wizard to fix a gift, unticked Tier
because they did not want to walk two tier screens, and pressed through to Publish had their **live
tier programme switched off for every customer**, with nothing on screen saying so.

**The fix, in two halves.**

1. **Scope.** `programmeScopeSwitchesV322(scope,{paused})` is the only translation from screen 0 to
   a switch payload. A programme the owner selected is sent `true` (turning something on *is* what
   setting it up means) or `false` when they chose to publish paused. A programme they did **not**
   select is **absent from the payload entirely** — `public.set_programmes_v314` leaves an unnamed
   kind exactly as it found it, and that absence is the mechanism by which unselecting stops meaning
   off. The single exception is the R2 exclusivity, and it is not a side effect: the switchboard
   states the consequence and takes a confirmation before the scope changes.
2. **The separate button.** `growProgrammeSwitchPanelV322` on the Rewards Programme page — "What
   customers can use right now", one `role="switch"` row per programme, reading the **spine**, not
   the tile status. Switching one **off takes an inline confirmation** naming what customers lose;
   switching one on does not, because nothing is taken away. Turning the stamp card on states its
   exclusivity first and then sends **one** call carrying the whole set, so the firm is never
   briefly in a shape the server forbids and no pot is stranded by a two-step switch (the residual
   `V313-V314…§7.1` named). Referral writes **both** halves — the spine row and
   `referral_programs.enabled` — because SA-4 is still open and the engine gates the payout on the
   column.

The Go-live summary was rewritten with it: it read "Points & gifts — ON / Tier membership — off",
which was the screen telling the owner the very thing the ruling forbids. It now reads from the
PAYLOAD and prints one of four honest states — `turning ON`, `staying paused`, `switching OFF`,
`left as it is`.

**Red-first.** `tests/business-ui/v322-owner-rulings.test.mjs` builds the wizard against a minimal
DOM and asserts the `p_switches` object that actually leaves the browser. Reverting
`applyProgrammeSwitchesV314` to `{...state.switches}` turns the R6 payload tests red. On the server
side, suite step 16 proves a partial payload leaves every unnamed programme exactly as it found it.

---

## R2 + R3 — stamps is exclusive

> "stamps is not supposed to be able to be live with points and tier. - it is seperate rewards by
> itself." · "points / tier / points & tier"

Legal shapes: `points` | `tier` | `points + tier` | `stamps`. Referral is orthogonal and is never
part of the exclusivity.

**Server (the enforceable half).** A counted needle into `public.set_programmes_v314` — the one
writer of the spine — placed **after** the self-heal insert (so every kind has a row to read) and
**before** the flip loop (so nothing is written when the answer is no). It is computed on the
**merged result**, not on the payload: after R6 the wizard legitimately sends a partial payload, so
`{"stamps":true}` alone at a firm already running points is the forbidden shape even though the
payload names one kind. The refusal is a sentence an owner can act on, at errcode `22023` (the same
class every other argument refusal in that function raises, so the client's existing error rendering
already carries it to the screen):

> The stamp card runs on its own. Turn Points & gifts and Tier membership off before turning the
> stamp card on, or turn the stamp card off to run points and tiers.

**Client.** Pressing a switch whose kind excludes something already ticked does **not** flip
anything — it renders a confirmation block naming exactly which programmes go, and the flip happens
on the confirm. Cancel puts the screen back untouched. The same rule is reused by the Climbing
screen's one-tap "Turn on Points & gifts", so there is one spelling of it in the file.

**The W5 money kernel is KEPT.** Per-programme ledger tagging, the `(sale, programme)` earn arbiter,
the pot migration and both detectors are untouched — the loop simply never sees two accruing
programmes again. This is asserted, not promised: migration post-assertion **10.2** and suite
**step 17** both fail if the earn loop, the arbiter or the parity check moved.

**Preconditions, fail closed (as instructed).** The migration refuses to apply unless, at apply
time, `stamps active anywhere = 0` **and** `firms running stamps beside points or tiers = 0`. Both
were verified 0 against `gadpooereceldfpfxsod` while writing this. If that has stopped being true,
the guard would strand a firm whose stamps programme the migration cannot honestly switch off on
their behalf, so it stops rather than guessing.

---

## R1 + R4 — referral pays POINTS, not store credit

> "why referral is a stored credits? please remove it as i already said no more store credits"
> "referral is universal - and supposed to be free item (customer receive voucher and come to store
> to claim it or maybe give points)"

**The engine.** `app.on_sale_recorded`'s referral block no longer writes `public.credit_ledger`. It
writes one `points_ledger` `earn` row plus its matching `points_batches` row, tagged with the
referrer's firm's accruing programme.

**Why the earn row carries `sale_id = NULL`, since it looks like a mistake.**
`points_earn_once_per_sale_per_programme` is `UNIQUE (sale_id, programme_id) WHERE entry_type='earn'`.
The referral pays the **referrer**, who is not the sale's client, but it is triggered by the referred
friend's sale — so tagging it with that sale would collide with the friend's own earn row in the same
programme and abort the whole sale trigger with 23505 the first time a referred friend's qualifying
visit also earned points. That is every firm running points and referral together. The sale is
recorded where it belongs, on `referrals.qualified_sale_id`, which this block already sets. Suite
step 3 drives exactly that collision case.

**Which pot.** `app.referral_payout_programme_v322` — the firm's **one active accruing programme**,
or null. Not "points": referral is universal (R4) and runs beside stamps, and paying points into a
switched-off points row at a stamps firm would mint a balance `app.redeem_reward_core` refuses to
spend. Under R2 there is never more than one accruing programme, so the answer is unique. **When
there is none, the referral is left PENDING and nothing is written** — it pays on the next
qualifying visit after the owner switches a programme on. Fail closed, never a silent unspendable
balance.

**Column strategy (the decision the brief asked to be made and documented).**
`referral_programs.reward_cents` is **not** dropped and **not** redefined — reusing it with a changed
meaning was explicitly not acceptable and would be how two readers end up disagreeing by a factor of
a hundred. Two new columns:

| column | meaning |
|---|---|
| `referral_programs.reward_points` | what a qualifying referral pays, in points. The live amount. |
| `referral_programs.reward_kind` | `CHECK in ('points','voucher')`, default `'points'`. The DEFERRAL, made explicit. |
| `referrals.reward_points` | what was actually paid, for the activity table and any later reversal. |

`reward_cents` on both tables is frozen as the historical money record and is read by **nothing** on
the payout path. `public.save_referral_program` (the pre-v322 four-argument money signature) is left
installed and granted so the CDN-cached bundle keeps writing that dead column harmlessly for its
four-hour window instead of failing in front of an owner; the new door is
`public.save_referral_program_v322`, which speaks points.

### What the three live rows now pay — TELL THE OWNER THIS

Converted at each firm's **own published points price** (`reward_cents × redeem_points ÷
reward_credit_cents`), so the intended generosity is preserved rather than reinterpreted. All three
firms price points at 800 ÷ 2000 cents, i.e. 1 point = 2.5 cents.

| business | was | now pays | and in practice |
|---|---|---|---|
| **QA Test Cafe** | SGD 10.00 credit | **400 points** | pays on the next qualifying referral — its points programme is running |
| **AhXiang** | SGD 10.00 credit | **400 points** | ⚠️ **pays nothing yet.** Its spine is `points=false, tiers=false, stamps=false, referral=true` — referral is enabled with no accruing programme behind it, so the referral stays PENDING until the owner switches Points & gifts on, and then pays. It never silently mints an unspendable balance. |
| **ZZ-SYNTHETIC PS1B1 UAT Journey** | SGD 3.00 credit | **120 points** | ⚠️ same state as AhXiang (synthetic tenant) |

Two of the three therefore go from "paying store credit" to "paying nothing until a programme is
switched on". That is the honest consequence of removing credit from a firm that runs no accruing
programme — there is no pot to pay into — and it is visible and fixable from one screen (the new R6
on/off panel). It is stated here rather than discovered at a counter.

### The voucher payout is DEFERRED — named, not implied

R4 names two payouts: a **voucher for a free item** the customer claims in store, or **points**.
**Only points is built**, because it reuses the points ledger and needs no new machinery. The data
shape carries the deferral: `reward_kind` is CHECKed against both values, nothing writes `'voucher'`,
and `app.on_sale_recorded` pays only `'points'` — so a voucher row cannot be paid by accident.
Suite **step 9** asserts that a `'voucher'` programme pays nothing, which is what makes "deferred"
mean deferred rather than "half built". Building it later is an UPDATE and a branch, not a migration
of live rows.

### Two things that would have broken silently, and did not

1. **`app.trg_emit_referral_qualified` fires on a `credit_ledger` insert that no longer happens.**
   It is not dead code: production holds **11** `benefit_registry` referral rows in `shadow`, one
   `benefit_fulfilments` row and one `referral.qualified` domain event. The same two writes are
   re-expressed as `app.emit_referral_qualified_v322` and called directly from the referral block;
   the v56 trigger and its function are **left installed and untouched**, so a pre-v322 credit row
   (a rollback, a replay) still emits. Costing moved honestly from `cost_basis='credit_face'` to
   `'bonus_face'`, valued at the firm's own points price, `'low'` confidence when it has none.
   Suite step 11 pins both halves.
2. **`app.loyalty_ledger_write_guard` had no route for this write.** `sale_trigger` requires
   `sale_id IS NOT NULL`, which is precisely what the referral row must not carry. A new scope
   `referral_reward_points` was added **with its own shape rule** — earn, positive, no sale, and a
   programme — which is what stops the scope being a general-purpose hole. Suite step 10 proves the
   scope refuses a row that carries a sale.

**Checked and found already safe:** the live `public.reverse_sale` body contains no referral clawback
at all (`position('referral' in prosrc) = 0` on production), so no reversal path was left pointing at
a credit row that no longer exists.

---

## R5 — the stamp card is a quest, and ONE PART OF IT IS BLOCKED

> "stamps is like a quest - complete one set of quest (3 stamp = xx rewards, 5 stamp = xx rewards,
> 8 stamp = xx rewards) - customisable on how many stamps and what rewards … now is 3 sets in 1. but
> if bosses want to extend to 12 stamp = xx rewards and more = able to do it customisable"

**Shipped, with no new entity and no schema change.** A milestone is an ordinary catalogue reward
whose **cost is the stamp count**, priced in the stamps programme. v313 gave every reward a
`programme_id` and v314 re-bodied `app.reward_default_programme_v313` to "the business's one active
accruing programme when there is exactly one" — and R2 now guarantees a stamps firm is the only kind
of stamps firm there is, so a reward authored on that screen lands on the stamps programme by itself.
No writer change was needed.

- The rail's second stamps screen is renamed `Stamp gift` → **`Milestones`** and renders
  `stampMilestonesHtmlV322()`: a repeatable list, **add and remove, any number of rows**, sorted by
  stamp count. There is no separate reorder control because the order of a quest **is** its stamp
  counts — changing a number moves a rung, which is the only reordering a ladder can have.
- `stamp_target` (the length of the card the customer sees) is **derived from the last milestone**
  and saved after the form on the same press, rather than typed. A card whose length disagreed with
  its own last prize is the two-numbers-for-one-fact defect this file keeps having to fix. The typed
  `#growSetupStampTargetV301` input is gone from that screen.
- A one-tap **3 · 5 · 8** starting ladder (the owner's own example), skipping any milestone that
  already exists so a second tap is a no-op.

### ⚠️ BLOCKED, AND REPORTED RATHER THAN WORKED AROUND

The ruling also says **reaching one milestone must not reset progress toward the next**. **It does
today, and this wave did not change it**, because doing so means changing the money kernel — which
this wave was explicitly forbidden to do.

Verified against the live body of `app.redeem_reward_core`: claiming a reward drains
`points_batches` FEFO for `cost_points` and appends a negative `points_ledger` row. So claiming the
3-stamp prize **spends three stamps**, and the 5-stamp prize moves three further away.

Making it non-consuming needs two things this wave may not build: a claim path that **proves** a
balance without draining it, and a per-client per-milestone claim ledger so a milestone cannot be
claimed twice on the same card. Both are money-kernel changes.

**What was done instead:** the authoring screen states what actually happens, in the owner's own
words, rather than implying the ladder behaviour the engine does not have —

> "Claiming a milestone spends those stamps, so the card starts filling again from what is left. A
> milestone that keeps the card filling is not built yet."

**Also deferred and named:** R5 says a milestone reward is "an ITEM or a DISCOUNT (the existing
reward kinds)". `loyalty_rewards.fulfillment_kind` is CHECKed against **`credit | manual_item`** only
— there is no discount kind, and `credit` is the store credit that left at v320. So milestones ship
as `manual_item`, which is exactly what every wizard-authored reward already was. A first-class
DISCOUNT reward kind is a schema change and is not in this wave.

---

## Copy — all four wrong sentences, and the locales

| was | is | why |
|---|---|---|
| "Turn on as many as you like. Each one works on its own." | "Tick the ones you want to work on. Leaving one unticked does not switch it off — it just stays as it is. To turn a programme on or off for customers, use the switches on the Programmes page." | R6 — this is not a turn-on control |
| "You can turn any of these on or off later, on their own. **They do not affect each other.**" | "Points, tiers and referral run together. The stamp card runs on its own — picking it turns points and tiers off. Nothing you leave unticked here is switched off; it just stays as it is." | R2 + R6 — both halves were false |
| Referral: "you thank them **with store credit**" | "you thank them **with points**" | R1/R4 |
| Stamp card: "**A full card wins a gift**" | "You set the milestones — 3 stamps, 5, 8, as many as you like." | R5 — a card is a quest, not one prize |

The wizard's lead question moved with them: "Which programmes do you want to **run**?" →
"Which programmes do you want to **set up now**?"

**Locales — a correction to the brief's assumption.** `ct()` is the **customer app's** dictionary
(`CUSTOMER_COPY`, four locales: `en` / `zh-CN` / `ms` / `ta`) and the four sentences above are
**business-console** copy, which does not go through `ct()` at all. Business copy is localised by
`localizeWorkspaceSubtreeV97`, keyed on the **English string itself**, across the three workspace
locales (`en` / `zh-CN` / `ms` — there is no `ta` workspace locale). Changing an English sentence
therefore silently orphans its translations, so both halves were done:

- **`ct()`, all four locales:** the customer referral card's `referralTerms` /
  `referralTermsWithFloor` lost the word "credit" in en, zh-CN, ms and ta, and two new keys
  (`referralPoints` / `referralOnePoint`) carry the points phrase in all four. Real translations,
  not English fallbacks.
- **`WORKSPACE_COPY_V97`, zh-CN and ms:** every business sentence the rulings rewrote was re-keyed
  in both, so none of them falls back to English.

---

## Regenerated browser fixtures

Four checked-in fixtures inline `app/app.js` under a `production-source-sha256`, so all four had to
be regenerated with their own `generate-*.mjs` in the same change. The hashes below are what those
fixtures now carry; `tests/business-ui/v128-simple-rewards-setup.test.mjs` fails unless the
reward-overview hash is recorded in an evidence document, which is what this section is for.

| fixture | generator | production-source-sha256 |
|---|---|---|
| `tests/browser/reward-overview-owner-visual.html` | `generate-reward-overview-owner-visual.mjs` | `d240630052cf2d37bee444db531be285d475841f6fceeb0a70a08115d0cfffe8` |
| `tests/browser/v129-trial-test-visual.html` | `generate-v129-trial-test-visual.mjs` | `a7d7d297bf326cec2508d968d0a3178c0709649d233ddb15e223e95194de5459` |
| `tests/browser/v145-launch-freeze-visual.html` | `generate-v145-launch-freeze-visual.mjs` | `f9375a4682a9345d571b8b1bdc6176744f86ce90e31e95868cd211a18ac3fe0a` |
| `tests/browser/v104-promotions-visual.html` | `generate-v104-promotions-visual.mjs` | `341342f1a4087206b77904ab5835e835138c2e15d1a3422c21a7cb936e5a71aa` |

**The v104 fixture was re-captured in real Chrome, not hand-edited.** It carries measured Chrome
metrics keyed to its source hash (`docs/qa/evidence/v104-promotions-production-render-metrics.json`
plus three screenshots), and this wave moved the hash only because the customer referral card lives
in the same extracted region. Updating the recorded hash without re-measuring would have been
forging evidence, so `tests/browser/verify-v104-promotions-visual.mjs` was re-run at 1440 / 390 /
412 against headless Chrome and reported `PASS`. The promotion render itself is unchanged.

## Verification

| surface | result |
|---|---|
| `db/tests/v322_owner_programme_rulings.sql` | 19 steps, rolled back, four tenant shapes constructed in-transaction |
| **all six migration needles, counted against the LIVE production bodies** | **each matched exactly 1** (read-only `pg_get_functiondef` probe on `gadpooereceldfpfxsod`) |
| migration hardening guards + preflight | green (canonical `search_path`, exact-overload revokes, atomic boundaries, comment-free needles) |
| `tests/phase0-foundation/` | **89/89** — registration treadmill and both bundle-staleness checks |
| `tests/business-ui/v322-owner-rulings.test.mjs` | **30/30**, all behavioural |
| existing business-ui suites | 16 superseded pins re-pointed, none deleted, none weakened |
| `npm run bundle-stamp` · `bundle-stamp:check` · `npm run quality` | run / current / passed |
| `npm test` | **2989 tests, 2988 pass**; the one red is the known environmental `v131` store-readiness check (no `node_modules` in this worktree, so the Capacitor privacy-manifest generator refuses) |

### Red-first: nine client mutants, nine lethal

Each mutation was applied to the shipped `app/app.js`, the suite re-run, and the file restored
byte-identical (verified by sha256 after every one).

| # | mutation | tests that go red |
|---|---|---|
| M1 | **the live defect itself** — publish sends `{...state.switches}` again | R6 "the wizard publish sends the SCOPE" |
| M2 | drop the exclusivity clearing from `programmeScopeSwitchesV322` | 4 (R6 absence + all three R2/R3 payload tests) |
| M3 | the switchboard clears the other side silently instead of arming the confirmation | R2 "ARMS a confirmation before it clears" |
| M4 | the customer card reads `reward_cents` again | R1 "no referral surface still reads a money amount" |
| M5 | the wizard writes the payout in cents through the pre-v322 signature | 2 (R1 money sweep + R1 points writer) |
| M6 | the milestone list stops sorting by stamp count | R5 "renders every milestone, in stamp order" |
| M7 | the on/off panel switches without confirming | 3 (off-confirmation, stamp exclusivity, referral-pays-nothing warning) |
| M8 | the wizard writes `referral_programs` even when referral is out of scope | R6 "the referral write is scoped with it" |
| M9 | the stamps rail label reverts to "Stamp gift" | R5 "names the milestone screen for what it is" |

Server-side mutants are named in the suite's own banner (`M1`–`M8` in
`db/tests/v322_owner_programme_rulings.sql`), in this repo's house prose form: each banner states
which step it kills. The two that only one step catches are worth naming here — **M1** (judge the
guard on `p_switches` alone instead of merging it over the spine) passes step 12 and dies at step
13, which is the R6 partial-payload case; and **M5** (resolve the payout pot with
`app.reward_default_programme_v313`) survives steps 3, 4 and 7 and dies at step 8, where it would
mint points into a programme nobody is running.

### Deliberately NOT done

- The **voucher** referral payout (R4) — deferred, with the data shape carrying it (above).
- **Non-consuming stamp milestones** (R5) — blocked on the money kernel, reported above rather than
  worked around.
- A first-class **discount** reward kind (R5) — `loyalty_rewards.fulfillment_kind` has no such value.
- Moving the referral gate off `referral_programs.enabled` and onto the spine (**SA-4**) — still
  open; both doors that switch referral write both halves in the meantime.
- Any change to the W5 money kernel, the pot migration, the reward→programme identity, or the
  `tier_basis` / expiry knobs the 2026-08-14 owner amendment protects.
