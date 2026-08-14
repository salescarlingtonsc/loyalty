# V323 — the stamp card is a quest, and claiming a milestone does not reset it

Owner ruling **R5** (`OWNER-RULINGS-2026-08-14-PROGRAMME-MODEL-CORRECTION.md`), the half
`V322-OWNER-PROGRAMME-RULINGS-ACCEPTANCE.md` reported as **BLOCKED**:

> "stamps is like a quest - complete one set of quest (3 stamp = xx rewards, 5 stamp = xx rewards,
> 8 stamp = xx rewards) - customisable on how many stamps and what rewards … Milestones are
> non-consuming: reaching 5 does not reset progress toward 8; the card keeps filling to the end of
> the quest."

v322 shipped the authoring half and stopped at the claim, because `app.redeem_reward_core` drained
`points_batches` FEFO and appended a negative `points_ledger` row for the reward's `cost_points` —
so claiming the 3-stamp prize spent three stamps and pushed the 5-stamp prize three further away.
Closing it needed a money-kernel change v322 was forbidden to make. The owner has now authorised it.

**Nothing is committed, pushed, deployed or applied.** One migration,
`nestly_v323_stamp_quest_milestones`, slot `20260814000400`, registered and mirrored but **NOT
applied**; the orchestrator applies it.

---

## 1. The model

A **card is a projection, not a stored balance.**

```
net_stamps   = sum(points_ledger.points) on the stamps programme   -- ALL entry types
closed_slots = sum(stamp_cycles.slots)   for (business, client, stamps programme)
filled       = greatest(net_stamps - closed_slots, 0)
cycle_index  = count(stamp_cycles rows)                            -- 0-based, monotone
slots (N)    = loyalty_programs.stamp_target                       -- NULL = not configured
```

A **cycle is recorded only when it CLOSES**, and it closes when the **final** milestone of the quest
is claimed. That single choice removes every new writer from the earn path: `app.on_sale_recorded`
is not touched at all, and progress is a pure `STABLE` read (`app.stamp_progress_v323`) that a
`STABLE` catalogue function may call.

A **claim is non-consuming, literally**: no `points_ledger` row, no `points_batches` update, no
`loyalty_redemption_batch_drains` row. The stamps ledger stays a pure lifetime accrual record.

**The final claim is where the quest's stamps are consumed — by RECORDING THE CYCLE, not by moving
the ledger.** One `stamp_cycles` row with `slots = N` raises `closed_slots` by N, so `filled` falls
by exactly N and the remainder carries into the next card. A `-N` ledger debit was rejected: it
would subtract N from `net_stamps` while the cycle row subtracts N again from the projection, and
the card would lose 2N. Keeping the consumption in the projection also keeps every W5 invariant —
`sum(remaining) = sum(points)` still holds on the stamps pot, so `app.programme_balance_scope_v312`
stays `'programme_pot'` and `app.detect_programme_pot_split_v312` stays empty.

**The scarce resource is no longer a balance — it is two unique indexes** on
`public.stamp_milestone_claims`:

| index | what it closes |
|---|---|
| `…_slot_uk (business, client, programme, cycle_index, slot_position)` | the PRODUCT RULE: one gift per milestone per card. Also closes "the owner swaps the gift at slot 5 mid-cycle and the customer claims both". |
| `…_reward_uk (business, client, programme, cycle_index, reward_id)` | the IDEMPOTENCY KEY: the same gift cannot be claimed twice on one card even if the owner MOVES it from slot 5 to slot 7 mid-cycle. |

`cycle_index` is in **both** keys, which is what makes a milestone claimable again on the next card.
Drop it from either and the quest becomes once-ever (suite cell 13, mutant M5).

`stamp_cycles.slots` stores **the N in force at closure**, not the current `stamp_target`, so editing
the card's length moves only the CURRENT card and never rewrites a card the customer already
completed (cell 14, mutant M7).

---

## 2. The money-kernel change and its paired guards

Owner-authorised, and it makes the invariant **stronger**, not weaker:

```sql
alter table public.loyalty_redemptions            add column consumes_balance boolean not null default true;
alter table public.loyalty_redemption_provenance  add column consumes_balance boolean not null default true;

-- loyalty_redemptions_points_spent_check:  CHECK (points_spent > 0)  ->  CHECK (points_spent >= 0)
alter table public.loyalty_redemptions add constraint loyalty_redemptions_consumption_shape_check check (
     (consumes_balance     and points_spent > 0)
  or (not consumes_balance and points_spent = 0));

alter table public.loyalty_redemption_provenance alter column points_ledger_id drop not null;
alter table public.loyalty_redemption_provenance add constraint
  loyalty_redemption_provenance_consumption_shape_check check (
     (consumes_balance     and points_ledger_id is not null)
  or (not consumes_balance and points_ledger_id is null));
```

Today `points_spent > 0` silently does double duty as *"money moved"*. Afterwards that meaning is
**explicit, machine-checked, and defaults to `true`** — so an ordinary POINTS reward is
*structurally unable* to record a free claim, which is strictly more than the old CHECK guaranteed.
Suite cells **16 / 17 / 18** prove all three directions: `points_spent = 0, consumes_balance = true`
→ `check_violation`; `points_spent = 300, consumes_balance = false` → `check_violation`;
`consumes_balance = true, points_ledger_id = null` → `check_violation`.

**Both `ADD COLUMN … NOT NULL DEFAULT true` are DDL fast defaults**: they fire no row trigger, so
`app.loyalty_redemption_immutable_guard` and `app.v34_immutable_evidence_guard` are never invoked,
and no table is rewritten. **There is no backfill UPDATE anywhere in the file** — one would raise
`restrict_violation` on every existing row. Post-assertion 11.3 proves the default reached every row
without one, and that no legacy provenance row lost its ledger id.

**`public.merchant_scan_redemption_qr_v117` needs no change and is deliberately kept out of this
migration's md5 chain.** It raises `40001 'canonical catalog redemption was not recorded'` when the
provenance row for the operation is absent — so a stamp claim **still writes its provenance row**,
with `points_ledger_id` NULL, and v117 selects only `provenance.redemption_id`. Post-assertion 11.7
compares its `md5(prosrc)` before and after and refuses on any difference.

Keeping the claim inside `loyalty_redemptions` is what keeps a stamp gift in Customer 360's
redemption history, in `public.business_programme_usage_v271`, in per-customer `usage_limit`
enforcement (which counts `loyalty_redemptions` rows) and on the QR path. The honest alternative —
record claims only in `stamp_milestone_claims` — needs no money-table change and loses all four.

---

## 3. Concurrency

Two counter scans at the same moment cannot double-claim a milestone or close a cycle twice, for
three independent reasons, in the order they engage:

1. **The money kernel's own row lock.** `app.redeem_reward_core` already takes
   `perform 1 from public.clients c where c.id = p_client and c.business_id = p_business for update`
   before it reads any balance. Every key in v323 is per `(business, client)`, so two claims for one
   customer **serialise on that row** — the second reads `app.stamp_progress_v323` only after the
   first has committed its cycle row. **No advisory lock is added.**
2. **`loyalty_operations (business_id, operation_type, idempotency_key)`** with `for update` and the
   stored-result replay already collapses a retried scan of the same QR.
3. **The uniques.** Anything that got past 1 and 2 becomes a `23505` with an owner-readable sentence
   (`'this stamp gift has already been claimed on this card'`) rather than a second gift:
   `stamp_milestone_claims_slot_uk` / `_reward_uk` / `_redemption_uk` and
   `stamp_cycles_cycle_uk` / `_redemption_uk`.

`db/tests/v323_stamp_quest_concurrency.sh` drives **eight real concurrent psql sessions** at three
races — the same mid-card milestone, the same FINAL milestone, and eight claims sharing one
idempotency key — and asserts exactly one claim, exactly one closed cycle, `filled` 10 → 2,
`net_stamps` unchanged at 10, and zero ledger/drain rows. Suite cell 22 proves the backstop the race
falls onto inside the rolled-back transaction, which is all a single transaction can honestly show.

---

## 4. What is NOT touched, asserted rather than promised

Migration post-assertion **11.6** pins and re-compares:

- **`app.on_sale_recorded`** — `md5(prosrc)` captured in section 0 and compared after; the W5 earn
  loop, its `(sale, programme)` arbiter (`points_earn_once_per_sale_per_programme`) and the
  in-trigger ledger/batch parity assertion are additionally matched by their own text.
  **Stamps still earns into its own programme pot and still writes its batch rows** — they are
  simply never drained (suite cell 26).
- **`public.set_programmes_v314`** — `md5(prosrc)` pinned and compared; the pot-migration writer and
  the R2 exclusivity guard are untouched.
- **`app.enqueue_programme_pot_migration_v312`** — presence asserted.
- **`app.detect_double_earn_v309`** and **`app.detect_programme_pot_split_v312`** — both re-run and
  required empty (11.6), and re-run again inside the suite after ten stamps, five claims, one closed
  cycle and a points redemption (cell 26).
- **`app.run_points_expiry_for_business`** — already filters `pb.programme_id = the points
  programme`, so stamp batches are structurally unsweepable. No guard needed and none added.

**A points reward is byte-identical afterwards.** Every needle into `app.redeem_reward_core` either
adds a declaration, adds an `if v_programme_kind='stamps'` arm whose ELSE is the live statement
**verbatim**, or substitutes `v_points_spent` for `v_version.cost_points` where `v_points_spent` is
assigned `v_version.cost_points` on the points arm. Post-assertion 11.1 asserts exactly one FEFO
loop, one claim insert, one cycle insert, one `if v_consumes then`, one `'insufficient proven
points'`, and the four verbatim points-path fragments. Suite cell 15 executes a points claim end to
end and compares every row it writes.

---

## 5. What was built

| # | file | what |
|---|---|---|
| 1 | `db/migrations/20260814_nestly_v323_stamp_quest_milestones.sql` | 2 tables, 3 columns, 1 spine unique, 2 functions, **15 counted needles across 5 bodies** |
| 2 | `supabase/migrations/20260814000400_nestly_v323_stamp_quest_milestones.sql` | byte-identical mirror |
| 3 | `db/tests/v323_stamp_quest_milestones.sql` | 27 cells, one `begin`/`rollback`, three tenant shapes built in-transaction |
| 4 | `db/tests/v323_stamp_quest_concurrency.sh` | three eight-session races |
| 5 | `app/app.js` | the customer quest card, five new sentences × four locales, the corrected owner sentence |
| 6 | `tests/customer-wallet/v323-stamp-quest.test.mjs` | 9 behavioural cells, real functions evaluated |

**New SQL surfaces**

- `public.stamp_cycles` — one row per completed card. Append-only
  (`app.v34_immutable_evidence_guard`), RLS on, two SELECT policies, **zero write policies**,
  `authenticated` = SELECT only, no `anon`.
- `public.stamp_milestone_claims` — the per `(client, cycle, milestone)` claim record. Same guards.
- `app.stamp_progress_v323(business, client)` — the projection. `STABLE`, `SECURITY DEFINER`,
  revoked from every browser role. **Returns ZERO ROWS** when the firm has no stamps spine row.
- `public.customer_get_stamp_card_v323(slug)` — the customer's read. Gated exactly as
  `customer_get_referral_card_v300` (`28000` without a session, `42501` without a verified
  `customer_links` row), `authenticated` only, returns **exactly `{"enabled": false}`** for a firm
  with no stamp card. Post-assertion 11.5 asserts its body contains no `points_ledger`,
  no `points_batches` and no `c45_base_actionable_wallet_card`.
- `public.business_programmes` gains `unique (id, business_id)` — purely additive, and the reason
  the two new tables can carry tenant-safe composite FKs.

**The fifteen needles**

| body | needles | what |
|---|---|---|
| `app.redeem_reward_core` | 6 | declarations · programme-kind capture · the stamps affordability arm · `consumes_balance` on both evidence inserts · the `if v_consumes` wrapper + the claim/closure writes · the result envelope |
| `public.customer_create_redemption_intent_v89` | 2 | declarations · a stamps branch that refuses "not enough stamps yet" and "already claimed on this card" **at mint**, so an intent that cannot settle never becomes a QR |
| `public.customer_get_reward_catalog` | 3 | declarations · hoists · availability measured against the CARD, and a milestone already collected this cycle reported as `limit_reached` |
| `public.customer_get_business_actions_v89` | 3 | the same, on the list the wallet actually renders and that decides whether a Claim affordance is drawn |
| `public.publish_loyalty_config` | 1 | a live stamp card must have a length and a gift at exactly N, and none past it |

Every needle's occurrence count was **read live from production** through the read-only MCP server
before the file was written: **15/15 matched `old_count = 1`, `new_count = 0`.**

**Why the publish guard is a refusal, not a warning.** Under closure-at-claim, a live stamp card with
no gift at exactly `stamp_target` **can never reset**: it fills to N/N, says Ready for ever, and the
customer's stamps pile up behind a door with no handle. It fires only when the stamps switch is
already ON — of which production has zero — and the v322 wizard derives `stamp_target` from the last
milestone, so an owner using the shipped surface can never meet it.

---

## 6. Client

- `stampQuestNormaliseV323` / `customerStampQuestRingsV323` / `customerStampQuestBodyV323` — the card
  shows **filled/total against the CURRENT cycle**, which milestones are collected on this card,
  which is next and how far, and carried stamps said out loud.
- `loadStampCardV323` runs in the same `Promise.all` as the other wallet loaders and **replaces the
  shipped v310 card in place**. Every failure path leaves v310 standing: no card on the page, an RPC
  error (an old server behind a new bundle), `{enabled:false}`, a foreign contract, a **paused**
  programme, or a card shape it cannot safely edit. Both directions of the four-hour CDN window are
  therefore safe, with no dark flag to remember to flip.
- **It never prints a points figure.** Not `loyalty.balance`, not a cost, not the word "points". The
  v322-era defect was a stamp card printing points, and the number it reached for came from
  `app.c45_base_actionable_wallet_card`, whose balance CTEs carry no programme filter at all.
- **No new CSS rule.** The rings reuse `.customer-programme-stamp-ring` / `.is-filled` / `.is-goal`
  and the existing tick — seven browser fixtures inline `app/index.html`'s stylesheet under captured
  Chrome measurements pinned to a `production-source-sha256`, so one new rule would force a full
  browser recapture for a cosmetic change.
- **The v322 sentence is gone.** "Claiming a milestone spends those stamps… is not built yet" was
  true only while the claim drained FEFO. It now reads *"Claiming a milestone does not spend the
  stamps — the card keeps filling to the end. When the last milestone is claimed the card is
  complete and starts again from whatever is left over."*, in English, zh-CN and ms.
- Five new customer keys (`stampsQuestProgress`, `stampsQuestCarried`, `stampsQuestClaimed`,
  `stampsQuestAllClaimed`, `stampsQuestRetired`) in **all four** `ct()` locales, real translations.

---

## 7. Red-first proofs

**SQL — 15 mutants, each turning a NAMED cell red** (banner in `db/tests/v323_stamp_quest_milestones.sql`):

| mutant | cells it reds |
|---|---|
| M1 drop the `if v_consumes` wrapper (a stamp claim drains FEFO) | 3, 4, 5, 14 |
| M2 invert the `v_programme_kind` test (points goes non-consuming) | 14, 15 |
| M3 drop `stamp_milestone_claims_slot_uk` | 6, 7 |
| M4 drop `stamp_milestone_claims_reward_uk` | 8 |
| M5 drop `cycle_index` from both claim uniques | 12 |
| M6 write the cycle row for every claim, not only the final one | 4, 9 |
| M7 store the CURRENT `stamp_target` at read time instead of the N at closure | 13 |
| M8 drop the `greatest(…,0)` clamp | 21 |
| M9 drop `loyalty_redemptions_consumption_shape_check` | 16 |
| M10 drop `loyalty_redemption_provenance_consumption_shape_check` | 17 |
| M11 drop the two append-only triggers | 18 |
| M12 add a write policy to either quest table | 19 |
| M13 drop the "gift at the last stamp" publish refusal | 20 |
| M14 drop the already-claimed check from the QR intent minter | 11 |
| M15 let a milestone priced past `stamp_target` be claimed | 10 |

**Client — every rule is EVALUATED, never a source regex.** The real functions are lifted out of
`app/app.js` and asked what they render. The headline cell is *"collecting a milestone does not move
the next one"*: two cards holding the same four stamps, differing only in whether slot 3 was
collected, must print the same progress line, and the 5-stamp gift must still be **one** stamp away.
Under the old consuming claim it would read four.

---

## 8. Verification, run and recorded

| check | result |
|---|---|
| all 15 needles counted against LIVE production bodies (read-only MCP, `5cc852de…`) | **15/15 old=1, new=0** |
| slot `20260814000400` re-verified against `supabase_migrations.schema_migrations` | **free**; highest applied is `20260814000300` (v322) |
| `tests/phase0-foundation/*` | **89/89** |
| `tests/program-studio/ps0-writer-registry.test.mjs` | **11/11** |
| `tests/business-ui/v314-programme-switchboard.test.mjs` + `v322-owner-rulings.test.mjs` | **41/41** |
| `tests/customer-wallet/v323-stamp-quest.test.mjs` | **9/9** |
| `npm run bundle-stamp` / `bundle-stamp:check` | run / current |
| `npm run quality` | passed |
| `npm run migration-manifest:check` / `canonical-migrations:check` / `--check-plan` | all pass |
| **`npm test`** | **2998 tests, 2997 pass** — the one red is the known environmental `v131` store-readiness check (no `node_modules`) |

`v104` was **re-captured in real headless Chrome** at 1440 / 390 / 412 (`PASS`) rather than having
its recorded hash hand-edited, and `v129` was regenerated from its own generator.

**Registration treadmill:** both plan JSONs, regenerated manifests + `.sha256` for both, the
canonical mirror, the phase0 counts (`313→314`, `299→300`, `269→270`, `314→315`, `310→311`
files, `20260814` day count `10→11`), and the preflight bound **by FULL migration name**
(`nestly_v323_stamp_quest_milestones`) rather than by the `v323` semantic label, because the label
map is already doubled for v313/v314 and a full name cannot collide with a parallel session's
renumbering.

**Superseded pins re-pointed, none deleted, none weakened:**
`tests/business-ui/v322-owner-rulings.test.mjs` (the sentence pin now aims at the sentence that is
true) and `tests/customer-wallet/v300-growth-loop.test.mjs` (the loader is still asserted to run in
the SAME `Promise.all`).

**Six writer-registry entries added**, each with a house-style reason: one read-only browser RPC
(`customer_get_stamp_card_v323`) and five scanner false positives — the tables the scanner matched
inside the needle STRINGS this migration splices. V323 executes **no DML against any VALUE_TABLE**;
post-assertion 11.9 proves it mints neither a stamp cycle nor a milestone claim for anybody.

---

## 9. Deliberately left, named rather than implied

- **`stamp_earn_mode` / `stamp_min_spend_cents`** (per-visit vs per-spend stamping). Not part of R5's
  claim semantics; `stamp_per_cents` is unchanged, so earn behaviour is byte-identical.
- **A first-class DISCOUNT reward kind.** `loyalty_reward_versions.fulfillment_kind` is CHECKed
  against `credit | manual_item` only. Milestones remain `manual_item`, which is what every
  wizard-authored reward already was. R5 names item **or** discount; only item exists.
- **The opening-balance conversion** (`preview_stamp_pot_conversion` / `convert_stamp_pot_to_cards`).
  Hougang ABC holds 336 and 11 stamps on a **paused** stamps programme with `stamp_target` NULL. The
  recommendation on record is a two-row manual reconciliation with the owner *after* they author N,
  not a tool that writes off 42 cards. `stamp_target` is deliberately never backfilled, so that pot
  stays inert until an owner chooses a length.
- **`public.customer_get_business_actions_v89`'s `v_batch_balance` is still not programme-filtered.**
  v323 fixes only the stamps path; the POINTS path over-reports at a firm holding two pots. R2 makes
  that shape unreachable and the fix belongs to the points/gifts area. Named, not silently inherited.
- **A per-cycle reinterpretation of `usage_limit`.** It stays a LIFETIME per-customer cap. An owner
  who sets it to 1 on a final gift caps the customer at one completed card **ever** — a real product
  trap that belongs in owner copy, not in a per-programme reinterpretation of a shared column.
- **No commit, push, deploy or migration apply.**
