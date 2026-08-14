# V320 — W6 wave 1: gift authoring gets a programme, and a place to hold a cap

Wave 1, migration 3 of 3 of the W6 independence unlock (ledger `PROGRAMME-INDEPENDENCE-001`),
built on `5bca979` (== W6 increment 2, the four-switch programmes home). Slot `20260814000400`,
file `db/migrations/20260814_nestly_v320_gift_authoring_programme_and_stock.sql`, mirror
`supabase/migrations/20260814000400_nestly_v320_gift_authoring_programme_and_stock.sql`.

**Renumbering, recorded so a later reader is not confused by the contract.** The design contract
(`w6design/20-GIFTS.md`) labelled the AUTHORING half `v319` and the ENFORCEMENT half `v320`. The
orchestrator's build order renumbered the authoring half to **v320** (slot `…000400`), gave
`v319`/`…000300` to the referral spine gate, and reassigned ENFORCEMENT to **wave 2's v324**. Every
plan entry, manifest row and preflight mapping below binds **by full migration name**, never by
semantic label — `v313`–`v318` are each already used, two of them twice, across two parallel
sessions.

**Enforcement is not in this migration.** The derived stock counter, the advisory-locked cap inside
`app.redeem_reward_core`, the sold-out intent refusal, `availability='sold_out'` on the two customer
readers, the wallet-card filter and the owner's gifts board are v324's. This migration proves it did
not touch any of them, by **snapshot equality** (ruling R-G): it reads their `md5(prosrc)` into
transaction-local GUCs in its own step 0 and asserts equality at the end — never against a
transcribed literal, because a hardcoded pin would claim "nobody in the wave touched it", which no
single migration is entitled to claim.

---

## 1. What it changes

### SA-3 — a gift's programme becomes an author choice, not the default trigger's guess

`public.save_loyalty_reward_draft`'s payload whitelist held **zero occurrences of the string
`programme_id`** (verified live against `gadpooereceldfpfxsod`, 2026-08-14), so a client sending it
got a hard `22023 'reward contains unsupported fields'`. The shipped client documents exactly this
blocker at `app/app.js:24128`. Four writers are spliced:

| writer | edit |
| --- | --- |
| `public.save_loyalty_reward_draft/4` | whitelist, declarations, FOUND capture, live-row branch, resolution block, BOTH insert lists, **and the ON CONFLICT DO UPDATE list** |
| `app.clone_reward_versions_for_config/0` | insert list + select list gain `programme_id`, `total_stock` — from the **source**, see §2 |
| `public.ensure_published_reward_in_draft_v138/3` | insert gains `programme_id`, `total_stock`, **`min_tier_id`, `min_tier_threshold`** — see §2 |
| `public.publish_loyalty_config/1` | the reward projection gains `total_stock=rv.total_stock`; it already carried `programme_id=rv.programme_id` from v313 |

The resolution chain **is** the contract, and it is what makes the migration behaviour-neutral:

```
explicit p_reward->>'programme_id'
  -> the draft row's current programme_id
    -> the LIVE published row's programme_id
      -> app.reward_default_programme_v313(business)      <- v313's own default, unchanged
```

An edit that does not mention `programme_id` never moves it. A payload that never mentions it lands
on **exactly** the uuid v313's BEFORE INSERT default would have chosen. Suite step 15 is that claim
as an assertion.

**The ON CONFLICT entry is not optional.** Without `programme_id = excluded.programme_id` an
existing draft gift's programme could never be changed by an edit: the insert conflicts, the DO
UPDATE preserves the old value, and the owner's reassignment is swallowed behind a success
response. Suite step 4 is its red-first proof (mutant M3).

### The accruing-kind guard — this STRENGTHENS v313

A gift tagged to the `tiers` or `referral` spine row is **permanently unclaimable**:
`public.points_batches` never holds a row for a non-accruing programme, so
`app.redeem_reward_core`'s batch proof is always 0 and the claim raises
`'insufficient proven points'` forever. Making `programme_id` author-settable is what creates that
footgun, so the floor closes it in the same transaction, at **both** doors:

- `public.save_loyalty_reward_draft` refuses first, with a message an owner can read:
  `22023 'a gift may only belong to a programme customers earn into'`;
- `app.reward_programme_tenant_guard_v313` refuses the same thing from a direct write, and keeps
  v313's cross-tenant refusal **byte-identical** in message and errcode
  (`42501 'reward is tagged with another tenant''s programme'`).

Provenance for adding a refusal: **zero pre-existing violators**, asserted in step 0 and re-asserted
in the postconditions. The only two tenants holding rewards are Cubbly (7, all on the `points`
spine) and Hougang ABC (7, all on `stamps`).

### `total_stock`, the column only

`integer`, nullable, `CHECK (total_stock is null or total_stock > 0)`, on both
`public.loyalty_rewards` and `public.loyalty_reward_versions`. NULL means unlimited — the same shape
`usage_limit` already uses, which is why it is not `NOT NULL DEFAULT` anything. Config: authored on
the draft version, cloned forward, projected to the live row at publish. **The COUNT is never
stored** — v324 derives it from the append-only `public.loyalty_redemptions` anti-joined against
`public.loyalty_redemption_reversals`, keyed on `reward_id` so it survives every republish.

**No backfill, and none is possible.** A cap is an owner intention that has never been expressible
in this product, so no tenant can be holding one; a migration that guessed would silently make a
live gift finite. `total_stock is not null` on **0 rows** at apply, asserted.

---

## 2. Two declared bug fixes, found on the way

Both are no-ops in production today. Both are recorded here and in the owner ledger rather than
buried in a diff.

**(a) `app.clone_reward_versions_for_config` read the LIVE programme, not the source version's.**
The clone omitted `programme_id` entirely, so v313's default trigger filled it from the live
`public.loyalty_rewards` row. Reassign a gift's programme in a draft, publish, then create a new
draft — the clone silently re-read the live row and reverted the owner's choice. `source.programme_id`
is strictly more correct: in the normal case (`based_on` = the published version) the two are the
same uuid, and where they differ the SOURCE is the truth. Suite step 8 constructs the disagreement
(source says points/7, live says stamps/20) and asserts the clone follows the source.
`active` keeps its deliberate `coalesce(live.active, source.active)` — a retire/unretire is a live
action, not a versioned one. Untouched.

**(b) `public.ensure_published_reward_in_draft_v138` DROPPED THE TIER GATE.** Its INSERT listed 20
columns and omitted `min_tier_id` / `min_tier_threshold`, so materialising a published reward into a
draft for editing silently opened a premium reward to everyone on the next publish. Verified live:
**0 rows** in `loyalty_rewards` and **0** in `loyalty_reward_versions` carry a tier gate today, so
the fix is a no-op in production and a real fix for the next tenant. It rides here because it is the
same INSERT statement; splitting it would mean editing one body twice in one wave. Suite step 12.

---

## 3. The hazard the contract did not see, and how it is closed

`public.save_loyalty_reward_draft` decides whether to create the live `public.loyalty_rewards` row
with `if not found then`, and **FOUND at that point still carries the result of the
`select * into v_existing … for update` eight statements earlier** — every statement in between is a
plain assignment, which does not touch FOUND.

The contract's resolution block, as designed, opened with `select spine.kind into v_programme_kind …`
— a SELECT INTO. That sets FOUND true, so the live-row insert would have been **skipped for every
brand-new gift**, and the version INSERT would then have died on
`loyalty_reward_versions_reward_business_fk` a few lines later. Every "create a gift" in the product
would have broken, in a way no existing test covers because no existing test creates a gift through
this door with a two-accruing-programme firm.

The migration removes the dependency rather than tiptoeing around it: **two extra splices** capture
FOUND into `v_is_new` the instant it is meaningful and change the branch to read that variable. The
kind lookups are additionally written as assignments rather than SELECT INTO, so the same trap
cannot be re-set by a careless later edit. Suite step 1 creates a gift from nothing and asserts the
live row exists; mutant M14 (restore `if not found then` **and** make the lookup a SELECT INTO)
turns it red.

---

## 4. Splice needles — all verified LIVE at occurrence count 1

Verified against production `gadpooereceldfpfxsod` on 2026-08-14, **using the exact literals as
written in the migration file** (extracted from the file, sent back to the database, counted with
`(length(def) - length(replace(def, needle,''))) / length(needle)` over `pg_get_functiondef`).

| id | function | needle length | occurrences |
| --- | --- | --- | --- |
| S1 whitelist | `save_loyalty_reward_draft` | 83 | 1 |
| S2 declarations | `save_loyalty_reward_draft` | 32 | 1 |
| S3 FOUND capture | `save_loyalty_reward_draft` | 85 | 1 |
| S4 new-row branch | `save_loyalty_reward_draft` | 60 | 1 |
| S5 resolution | `save_loyalty_reward_draft` | 130 | 1 |
| S6 live insert cols | `save_loyalty_reward_draft` | 70 | 1 |
| S7 live insert values | `save_loyalty_reward_draft` | 72 | 1 |
| S8 version insert cols | `save_loyalty_reward_draft` | 79 | 1 |
| S9 version insert values | `save_loyalty_reward_draft` | 139 | 1 |
| S10 on conflict | `save_loyalty_reward_draft` | 72 | 1 |
| C1 insert cols | `clone_reward_versions_for_config` | 113 | 1 |
| C2 select list | `clone_reward_versions_for_config` | 121 | 1 |
| E1 insert cols | `ensure_published_reward_in_draft_v138` | 87 | 1 |
| E2 insert values | `ensure_published_reward_in_draft_v138` | 104 | 1 |
| P1 reward projection | `publish_loyalty_config` | 169 | 1 |

Every splice asserts its own count **before** replacing and fails closed on any other count. Each
DO block is skip-if-already-present, so a second apply is a no-op rather than a refusal.

`app.reward_programme_tenant_guard_v313` is **re-stated**, not spliced — it is a 328-byte body this
repo owns end to end. The other five are **spliced, never re-stated**:
`save_loyalty_reward_draft` and `publish_loyalty_config` carry a V176 "Stage A"
`min_tier_id`/`min_tier_threshold` patch applied by asserted string replacement against their LIVE
definitions that **no repo migration reproduces** (`v176b:51-53` records the fact). Re-stating either
from a repo source would silently delete the tier gate.

### Predecessor pins (hardcoded, fail closed, skipped on a re-apply)

| function | `md5(prosrc)` before |
| --- | --- |
| `public.save_loyalty_reward_draft/4` | `5a6bca2e79ea7380a772c6d7196a36b9` |
| `app.clone_reward_versions_for_config/0` | `ff309e27653a28b7b20760a4ac85d7cf` |
| `public.ensure_published_reward_in_draft_v138/3` | `0bf4031e25171491541ee8c3e50141fa` |
| `public.publish_loyalty_config/1` | `6bcc491a86d0f19a7284dc6deda83097` |
| `app.reward_programme_tenant_guard_v313/0` | `deb9b5f7065732f2f9f8c7db2166da57` |

### PREDICTED post-apply pins — these are v324's predecessors

Computed read-only, by applying the migration's own literals to the live `prosrc` inside a `SELECT`.
**The migration RAISE NOTICEs the real values at apply; whoever applies it must paste the notice
here and correct any line that differs.**

| function | predicted `md5(prosrc)` after |
| --- | --- |
| `public.save_loyalty_reward_draft/4` | `7e7c466a614ee194d149f1026f503b10` |
| `app.clone_reward_versions_for_config/0` | `912e1c9a51cc1764975474f03bfaf19a` |
| `public.ensure_published_reward_in_draft_v138/3` | `34335b544db468ed21d0dd972a06aa00` |
| `public.publish_loyalty_config/1` | `a71b0e03ee36d5e3b9c0b24f6c6b171f` |
| `app.reward_programme_tenant_guard_v313/0` | `e68afd04bafa82f2dec4264ce41c7ade` |

### Deliberately UNTOUCHED, asserted by snapshot equality (ruling R-G)

`app.redeem_reward_core`, `public.customer_create_redemption_intent_v89`,
`public.customer_get_reward_catalog`, `public.customer_get_business_actions_v89` — the four v324
targets — plus `app.c45_base_actionable_wallet_card` (whose programme scoping is ruling R-K's work)
and `public.merchant_scan_redemption_qr_v117`. Their pre-values at build time were
`37ae059cca6715bd998daab843776279`, `2913f3847db0a5c77427cbcc5edc7b0f`,
`07897b24b70da71c5a954d748cc0df3d`, `7cce57c72be68556a54784ce0020aff9`,
`915aa32023c199ab9f2eed9c75408cb9`, `e6117b02a0746f8e87cf0f5eda5b71f5` — **recorded for information
only**; the migration compares against what IT read, not against these.

---

## 5. Postconditions — every claim in the header is proved

1. `total_stock` on both tables, `integer`, nullable, named CHECK present, **NULL on 100% of rows**.
2. `programme_id` still NOT NULL on both tables; **reward row counts unchanged** (captured in step 0).
3. `save_loyalty_reward_draft` carries `'programme_id','total_stock'`,
   `programme_id = excluded.programme_id`, `total_stock = excluded.total_stock`,
   `v_is_new := not found;` and `if v_is_new then` **exactly once each**, and
   `if not found then` **zero times**.
4. the clone carries `source.programme_id` and `source.total_stock` once each and contains
   **no** `live.programme_id`.
5. the materialiser carries `v_source.programme_id`, `v_source.total_stock`, `v_source.min_tier_id`,
   `v_source.min_tier_threshold` once each.
6. publish carries `total_stock=rv.total_stock` once and still `programme_id=rv.programme_id` once.
7. the guard's md5 is no longer v313's, keeps both refusal strings, and **zero** rows in either
   reward table resolve to a non-accruing kind.
8. all four v313 programme triggers and `business_programmes_seed_v314` still attached name-for-name;
   `trg_loyalty_reward_versions_immutable` and `trg_loyalty_reward_versions_snapshot` still ENABLED.
9. **not one `firm_config_versions.snapshot_hash` moved** (digest captured in step 0). See §6.
10. snapshot equality on all six no-touch bodies.
11. the whole `app`+`public` function digest, **excluding the five re-stated bodies**, is byte-stable;
    the five keep their exact ACLs; the guard is not browser-callable.
12. `app.detect_programme_pot_split_v312()` and `app.detect_double_earn_v309()` both empty.
13. `app.detect_spine_legacy_divergence_v314()` is **READ AND PRINTED, NEVER ASSERTED** (ruling R-H).
    It is non-empty in production right now — Cubbly, tiers, spine on / legacy off, from a real owner
    switch at 03:51:08 on 2026-08-14. That is the product working exactly as V313/V314 SI-5
    predicted, and a migration asserting it empty would refuse to apply for a correct reason.

The step 0 / §7.11 catalogue digest is computed by one throwaway helper
(`app.v320_other_catalog_digest_probe`) created after the lock prelude and **dropped before
`commit`**, so the two comparisons are provably the same expression and the migration leaves behind
exactly one new thing: the column.

---

## 6. The snapshot-hash decision, and why it is safe

Adding a column changes what `app.refresh_loyalty_config_snapshot` **would** compute — it builds
`'rewards'` from `to_jsonb(rv)` minus four keys, so `total_stock` is automatically inside the hash —
but the stored `firm_config_versions.snapshot_hash` does not move until something refreshes it.

**The migration refreshes nothing, on purpose.** Refreshing would change every open draft's hash and
hand every owner holding one a spurious `40001 'draft configuration changed; reload before saving'`
on their next save. There were **13 open drafts** in production at build time.

Leaving them alone is provably safe because of the order inside both
`public.save_loyalty_config_draft/3` and `public.ensure_published_reward_in_draft_v138/3`: the
`p_expected_snapshot_hash` comparison happens against the **stored** value **before** any write, and
the refresh happens after. The first post-migration save therefore passes and self-heals the hash.
Postcondition 9 asserts the migration moved zero of them; suite step 13 proves the self-heal by
stamping a known-stale hash on a draft and saving against it exactly once.

---

## 7. Verification

### The rolled-back suite

`db/tests/v320_gift_authoring_programme_and_stock.sql` — single transaction, rolled back, 18 steps,
outcomes recorded as rows so one final SELECT reports the whole run.

Production holds **zero** capped gifts, **zero** tier-gated rewards and **no** firm running two
accruing programmes, so a green run against production would prove absence of regression, not
presence of correctness. The suite therefore **constructs** its shapes: `G1`, a firm with points AND
stamps both switched on through `public.set_programmes_v314` (the one spine writer), and `G2`, a
second tenant so the cross-tenant refusal has something to refuse. Every authoring path is driven
through the door the browser actually uses — `public.save_loyalty_config_draft` as role
`authenticated` — because `public.save_loyalty_reward_draft` is revoked from `authenticated` in
production and calling it directly would prove something the browser can never do.

| # | Step |
| --- | --- |
| 1 | a stamp gift can be authored with an explicit `programme_id` at all (today: `22023`), and the live `loyalty_rewards` row is created — the FOUND-hazard regression cell |
| 2 | the authored programme beats the v313 default at a two-accruing firm (the two uuids differ by construction) |
| 3 | publish projects `programme_id` **and** `total_stock` onto the live row |
| 4 | an edit MOVES a gift between programmes (the ON CONFLICT DO UPDATE entry) |
| 5 | an edit that omits `programme_id` leaves the DRAFT value alone, not the live one |
| 6 | `total_stock`: an omitting edit keeps it, an explicit one moves it, an empty one clears it |
| 7 | a draft-to-draft clone reproduces the gift |
| 8 | **bug fix (a)**: the clone carries the SOURCE programme and cap, not the live row's |
| 9 | a gift tagged to a NON-ACCRUING programme is refused by the RPC, with the exact message |
| 10 | the trigger refuses the same thing from a direct write **and** still refuses another tenant's programme with v313's exact message and errcode |
| 11 | a non-positive cap is refused by the RPC (22023) and by the named CHECK (23514) |
| 12 | **bug fix (b)**: materialising a published reward keeps its tier gate, its programme and its cap |
| 13 | a client holding the pre-migration snapshot hash saves once and self-heals |
| 14 | another tenant's programme is still `42501` through the RPC |
| 15 | **behaviour neutrality**: a legacy payload lands exactly where v313's default put it, uncapped; the whitelist still refuses unknown fields |
| 16 | **wave boundary**: no reader consults `total_stock` yet — goes red on purpose at v324 |
| 17 | the five re-stated bodies carry every contracted edit exactly once |
| 18 | detectors empty; the divergence detector REPORTED, never asserted |

### Red-first mutant matrix

| M | Mutation | Step that must go red |
| --- | --- | --- |
| M1 | drop `'programme_id','total_stock'` from the whitelist | 1 |
| M2 | omit `programme_id` from the version INSERT | 2 |
| M3 | omit `programme_id = excluded.programme_id` from ON CONFLICT | 4 |
| M4 | omit `total_stock = excluded.total_stock` from ON CONFLICT | 6 |
| M5 | omit `source.programme_id` from the clone | 8 |
| M6 | omit `source.total_stock` from the clone | 8 |
| M7 | remove the accruing-kind refusal from `save_loyalty_reward_draft` | 9 |
| M8 | remove the accruing-kind refusal from the trigger guard | 10 |
| M9 | drop `min_tier_id` from `ensure_published_reward_in_draft_v138` | 12 |
| M10 | drop `programme_id`/`total_stock` from `ensure_published_reward_in_draft_v138` | 12 |
| M11 | omit `total_stock=rv.total_stock` from `publish_loyalty_config` | 3 |
| M12 | accept `total_stock <= 0` | 11 |
| M13 | put the live-row lookup before `v_existing.programme_id` in the chain | 5 |
| M14 | restore `if not found then` **and** make the kind lookup a SELECT INTO | 1 |
| M15 | fill `programme_id` from the v313 default instead of the payload | 2 |
| M16 | let a legacy payload move `programme_id` | 15 |

**No concurrency harness.** This migration introduces no lock and no counter; the two-connection
harness the gifts contract specifies (`db/tests/v324_gift_stock_cap_concurrency.sh`) belongs to v324,
whose advisory-locked cap is the thing a rolled-back single-session suite cannot prove.

### Repo guards (all green)

- `npm run migration-manifest:check`, `npm run canonical-migrations:check`,
  `node scripts/migrations/materialize-canonical-order.mjs --check-plan` — clean.
- `tests/phase0-foundation/*` — 13 files, 0 failures, including
  `pending-migration-preflight` (6/6, the by-name suite binding),
  `canonical-migration-order` (4/4), `migration-manifest` (9/9).
- `tests/program-studio/ps0-writer-registry.test.mjs` — 11/11.

### Registration treadmill

- both plan JSONs carry `20260814000400` in slot order, between v319's `…000300` and the parallel
  prospecting session's `…001000`;
- both manifests regenerated, both `.sha256` companions rewritten;
- byte mirror materialized at
  `supabase/migrations/20260814000400_nestly_v320_gift_authoring_programme_and_stock.sql`;
- preflight binds **BY FULL MIGRATION NAME**
  (`nestly_v320_gift_authoring_programme_and_stock` → `db/tests/v320_gift_authoring_programme_and_stock.sql`)
  and its pending count moves `269 → 270`;
- `scripts/migrations/materialize-canonical-order.mjs` `313 → 315` / `268 → 270`;
  `tests/phase0-foundation/canonical-migration-order.test.mjs` `313 → 315` / `268 → 270`;
  `tests/phase0-foundation/migration-manifest.test.mjs` `312 → 314`, `298 → 300`, `20260814` `9 → 11`.
  **All four counts include v319's entry as well as v320's** — the two wave-1 migrations share every
  one of these constants, so whichever session edits second must read the current value, not
  increment its own.
- `docs/design/ps0/writer-registry.json`: **no writer and no allowlist entry**, and that is a
  finding, not an omission — the `counts_note` now says why. The four spliced bodies are edited by
  `execute replace(...)` and never by a literal `create function`, so `scripts/ps0/discover-writers.mjs`
  correctly does not re-attribute their `latest_file`; hand-bumping it (as the contract's §6.5
  suggested) would turn `ps0-writer-registry.test.mjs` red. The guard function is re-created
  literally but has no curated identity, because a BEFORE trigger that only raises writes nothing.
  **v324 owns registering `public.business_gifts_board_v320` in `allowlist[]`** beside
  `browser.rpc:app/app.js:business_reward_redemption_counts_v300`.

### Owed before this row moves past `VERIFIED_LOCAL`

Production apply is the orchestrator's, not the builder's. Owed:
1. the rolled-back rehearsal of the suite against production **before** apply (expected: 18/18);
2. apply at slot `20260814000400`, and paste the migration's own `v320 POST-APPLY PINS` notice into
   §4, correcting any predicted md5 that differs;
3. the post-apply live battery: `total_stock` NULL on 100% of rows, both detectors empty,
   the divergence detector's count RECORDED not asserted, advisors 0 ERROR;
4. a REST probe, not a fingerprint (repo memory: fingerprints prove the deploy, not the service) —
   one authenticated `save_loyalty_config_draft` round trip on a scratch draft proving the whitelist
   now accepts `programme_id` and rejects a `tiers` one.

---

## 8. Standing invariants for the next increment

1. **The cap is CONFIG; the count is DERIVED.** `total_stock` lives on the versioned reward row and
   is projected at publish. The count must be computed at read time from the append-only
   `public.loyalty_redemptions`, anti-joined against `public.loyalty_redemption_reversals`, **keyed
   on `reward_id`** so it survives every republish, edit and clone. A stored counter would need four
   writers and would be the second source of truth the brief forbids.
2. **A gift may only name an accruing programme.** Both doors enforce it
   (`save_loyalty_reward_draft` and `app.reward_programme_tenant_guard_v313`). The client's
   programme control must never be able to produce a `tiers` or `referral` id; the server refuses
   with `22023`, but a control that can emit it is a bug.
3. **v324 must pre-assert the post-apply md5s in §4** for the five bodies v320 re-stated, and must
   read its own no-touch snapshots in its step 0 rather than transcribing v320's.
4. **`total_stock` must never enter `quoted_terms`.** When v324 adds the intent-side refusal, it must
   not add a `total_stock` key to `v_quote`: `public.merchant_scan_redemption_qr_v117` rebuilds the
   quote and compares it, so any new key has to be added to both functions in the same transaction —
   and a live count there would invalidate every in-flight intent the moment anyone else claimed.
5. **Intents do not reserve stock.** The last unit can be promised to two customers seconds apart and
   one is refused at the counter. Deliberate: reserving burns a unit for the whole 5-minute TTL of an
   abandoned QR. The mitigation is copy ("Almost gone", never a number), not machinery.
6. **Suite step 16 is the wave boundary and is SUPPOSED to go red at v324.** It asserts that none of
   the five v324 targets reads `total_stock`. When enforcement lands, v324's suite replaces it. It
   must not be "fixed" by deletion.
7. **FOUND is captured, not inherited.** `save_loyalty_reward_draft` now decides the live-row insert
   from `v_is_new`. Any future edit that adds a SELECT INTO between the `v_existing` lookup and that
   branch is harmless — which was not true before v320, and is why the capture exists.
8. **The client work is not done.** The reward editor's programme control, the "Total available
   (optional)" input, the two new `saveReward` payload keys, and the deletion of the now-false
   `sharedGiftNote` (`app/app.js:24124-24134`) are the client wave. Grep `sharedGiftNote` across the
   whole file before deleting it: a surviving reference passes `node --check` and the entire suite
   and then crashes in production (repo memory).
