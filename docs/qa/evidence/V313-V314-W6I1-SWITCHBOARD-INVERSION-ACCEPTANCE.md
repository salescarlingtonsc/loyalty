# V313 + V314 — W6 increment 1: the switchboard inversion

Increment 1 of the W6 independence unlock (ledger `PROGRAMME-INDEPENDENCE-001`), built on
`18536c0` (== `origin/main`, W0–W5 all applied to production). Two migrations, one increment,
applied back-to-back.

**v313** gives a reward its own programme identity: `loyalty_rewards.programme_id` and
`loyalty_reward_versions.programme_id`, backfilled from `app.resolve_ledger_programme_v309` in the
last transaction in which that resolver is unambiguous, then `NOT NULL`. `app.redeem_reward_core`
and `public.customer_create_redemption_intent_v89` stop asking the BUSINESS which pot to prove and
drain and start asking the REWARD. The two v309 tag triggers are retired.

**v314** inverts the spine. The four v308 one-way sync triggers are dropped by name;
`public.set_programmes_v314` becomes the one intended writer; a seed-only trigger keeps a
brand-new tenant alive; `businesses.points_mode` is frozen behind a swallow-and-audit tripwire;
six consumers move onto the spine; the publish stamps guard follows the switch; and
`trg_programme_pot_switch_v312` is retired so a settings republish can no longer move a live pot.
`loyalty_programs.loyalty_model` and `.active` become SETTINGS.

## Adversarial review 2026-08-14 — three CONFIRMED-BROKEN findings, and what closed them

An independent adversarial verification of the first cut of this increment rebuilt the rig from the
same lineage (its own cluster; pre-v313 fingerprints identical to the recorded W5 production
post-state), reproduced the headline money closure end to end, and then **withheld approval on
three confirmed defects**. All three were on the OWNER's side of the inversion: after v314 nothing
mapped the owner's ON/OFF decision onto the spine except one of three publish routes, and two live
client writers of `businesses.points_mode` remained that now silently lied.

The first cut of this document did not mention any of them. It does now. Each finding is recorded
with the probe evidence that confirmed it, the fix, and the test that keeps it fixed.

### Finding 1 — two surviving `points_mode` writers, both success-reporting no-ops

`app/app.js:18027` (the Grow editor's Save, fed by the four-way `data-loyalty-model-v235` toggle)
and `app/app.js:21213` (the `[data-points-mode-v229]` chooser) both still ran
`sb.from('businesses').update({points_mode:…})`. After the inversion the v314 tripwire PINS that
column and audits the attempt: PostgREST answers 204 with no error, so the toast fired, local state
flipped, the page re-rendered — and nothing changed server-side, in the column or the spine. The
chooser was the worse of the two: it renders only when `points_mode` is falsy, which every tenant
created after v314 is, permanently, so the one surface that looked like the place to choose a model
was the one surface that could not.

Consequence for this document's own contract: standing invariant 3 below says the tripwire is
upgraded to a raise "once `audit_log where action='POINTS_MODE_WRITE_SUPPRESSED_V314'` shows zero
rows over a full CDN window". With either writer shipping, that condition is **never satisfiable**
and increment 9's plan is unreachable.

**Fix.** The chooser's three cards and their click wiring are deleted together — a live listener for
a selector nothing renders is how a dead writer comes back. The slot keeps an honest line pointing
at the setup wizard, so the region is not blank and the capability is not lost. The editor's toggle
routes through `public.set_programmes_v314` using the SAME mapping the wizard uses, which is now at
module scope (`PROGRAMME_SWITCHES_V314` / `programmeSwitchSetV314` / `writeProgrammeSwitchesV314`)
precisely because a per-door copy is what allowed one door to be right and three to be wrong. Local
state is refreshed from the server's own reply (`rememberProgrammeSpineV314(data.programmes)`),
never from an optimistic flip.

**Mechanical proof.** `grep '.update({points_mode' app/app.js` → **0**, and the same is true of the
shipped surface bundles after `npm run bundle-stamp`.
`tests/business-ui/v314-programme-switchboard.test.mjs` asserts it, and reverting either half of the
fix turns that file red (red-first table below).

### Finding 2 — "Keep it paused for now — customers earn nothing" was false, in both directions

v314 consumer 1 removed `lp.active` from the earn gate — correct, that is the inversion — but the
wizard wrote `active:!state.keepPaused` onto the draft and then called the switch RPC
**unconditionally** with the switches ON. The verifier's probe:

```
7 | a paused firm starts with the points spine row OFF     | PASS
8 | "Keep it paused" still means customers earn nothing    | FAIL: PAUSED CONFIG EARNED 100 points;
                                                             loyalty_programs.active=false
```

And on the same firm, the opposite direction: `app.redeem_reward_core`'s row lookup
`select * into lp from public.loyalty_programs where business_id=p_business and active limit 1` was
never touched — consumer 5's needle rewrote only the `loyalty_model` half of the following `if`. So
a paused firm **accrued a liability its customers could never spend**:

```
9 | catalogue redemption at the same paused firm | REDEEM REFUSED: catalog redemption is inactive
                                                   (earn rows on the same firm: 1)
```

**Fix, stated as the rule it now is: PAUSED = the programme's spine row is OFF, and that one flag
governs accrual and payout together.**

- Client: `programmeSwitchSetV314(selection,{paused})` turns EVERY switch in the chosen model's set
  false when the owner keeps it paused — not only the accruing one, because a tier ladder still
  climbing under a paused programme is the same broken promise wearing a different hat — and the
  wizard passes `state.keepPaused` into it.
- Server: v314 gains consumer 5 **site 1**, a counted needle that drops `and active` from the
  `loyalty_programs` lookup. `lp` survives as the "this business has a programme row at all"
  existence check it now is. §9's post-assertion fails the migration if the flip does not land.
- The v314 header and the `loyalty_programs.active` column comment now state the complete rule,
  including which consumers enforce which half.

**Mechanical proof.** Suite step 33 drives the whole schedule on one firm: publish PAUSED → 0 earn
rows and a refused redemption; unpause → 1 earn row and a successful redemption, with the published
settings row still saying `active=false` throughout. Mutant **M18** restores `and active limit 1`
and turns step 33 red; mutant **M8** (restore `lp.active` in the earn gate) now reds it too.

### Finding 3 — only 1 of the 3 publish routes wrote the spine, and the owner pill did not know

`app/app.js` has three `publish_loyalty_config` call sites: the wizard, the Grow review page and the
Studio publish. Only the wizard applied the switches. The seeder derives a brand-new tenant's four
rows at INSERT time, before `loyalty_programs` exists, so every post-v314 tenant starts
all-four-false — correct and documented — and then nothing turned points on except the wizard. The
verifier's probe against a brand-new tenant that set its programme up in the Grow editor and
published from the review page:

```
1 | a brand-new post-v314 tenant's four spine rows              | points=false,tiers=false,stamps=false,referral=false
2 | after an ACTIVE publish from the review page                | loyalty_programs.active=true  spine=points=false,…
3 | a $100 sale at a firm whose live programme says active=true | FAIL: EARNED NOTHING — the published live programme is dead
4 | owner pill vs engine                                        | owner pill (loyalty_programs.active) = true ; engine (spine points) = false
```

**Fix.**

- Both non-wizard routes call `applyPublishedProgrammeSwitchesV314({active,loyaltyModel})` after a
  successful publish. The selection is the owner's current one, read from the spine
  (`programmeSelectionForPublishV314`, falling back to the frozen column and then to `'redeem'` for
  a firm that has never run anything); the level is the DRAFT's own `active` flag, so the paused
  semantics are identical on every route. A draft with **no** programme row skips the switch
  entirely, because `publish_loyalty_config` leaves `loyalty_programs` alone in that case and a
  rules-only Studio publish must not switch a firm on or off as a side effect of editing an
  automation. Both routes guard the publish behind an "already done" flag, so retrying a failed
  SWITCH is never a second publish.
- The owner's Live/paused pill (`ownerRewardJourneyV122`'s `programmeActive`) reads the SPINE. The
  least-invasive read available is `public.business_programmes` itself: v308 made it SELECT-only for
  authenticated members under a member-scoped RLS policy, so no new RPC and no server change is
  needed — the alternative, threading it through `customer_portal_capabilities`, is a customer
  contract and would have to grow an owner-shaped branch. It is cached on `S.programmes` once per
  business exactly like `S.myModules`, refreshed from every `set_programmes_v314` reply, and handed
  into `ownerRewardJourneyV122` as a parameter so that function stays pure. The Programmes tile
  status (`loyaltyLive`) and the customer-360 programme row read the same source, and every reader
  of the now-frozen `businesses.points_mode` — the editor's model derivation, the Grow page's
  `pointsModeV229`, the wizard's `livePointsModeV303` — derives from the spine with the frozen
  column kept only as the fallback for a session that could not read it. Leaving them would have
  made every post-v314 tenant look like a never-configured `redeem` firm forever, since nothing
  writes that column any more.

**Mechanical proof.** Suite step 34 pins both halves (an ACTIVE publish alone does NOT move the
spine — the inversion working as designed — and the switch call the route now makes does), and step
35 is the acceptance bar: a brand-new tenant published ACTIVE from a non-wizard route earns one
tagged row on its next sale. Mutant **M2** (re-attach a v308 sync trigger) now reds step 34 too.

### One deliberate semantic change that came with finding 2's fix, named rather than buried

In the Grow editor, Status (`#la`) is now applied at Save, together with the model, because in the
switchboard there is one flag per programme — "which model" and "is it running" are the same row.
Before the inversion Status was a draft field that took effect at publish while the model was
instant. Two consequences, both intended: pausing in the editor stops accrual and redemption
immediately rather than at the next publish, and the Status control itself now renders from the
spine, so an owner never sees "Paused" over an earning firm and cannot pause one by saving an
unrelated edit.

### Behavioural reproduction of findings 2 and 3, against the FIXED database

The two client fixes cannot be reverted with a SQL mutant, so a probe drives the OLD call sequences
against the fixed schema and shows the verdict's exact failures return:

```
1 | F2r — old client (keepPaused dropped)       | REPRODUCED: PAUSED CONFIG EARNED 100 points; loyalty_programs.active=false
2 | F2  — fixed client (keepPaused honoured)    | PASS no earn on a paused publish
3 | F3r — old review route (publish only)       | loyalty_programs.active=true spine=points=false,… earn_rows=0  <== REPRODUCED: EARNED NOTHING
4 | F3  — fixed review route (publish + switch) | PASS the published programme earns
```

### What the review verified and found HOLDING (unchanged by the remediation)

The cross-programme double-spend closure end to end on a dual-programme firm (a points reward drains
only the points pot, a stamps reward only the stamps pot, neither can buy the other's gift, one sale
earns twice and both are tagged, intent → `merchant_scan_redemption_qr_v117` → settle is
programme-consistent); the inversion window (both files are one transaction with no intermediate
commit, post-state trigger inventory clean); the swallow tripwire; the backfill lock story; both
kinds of fail-closed pin, measured; all 17 original mutants re-run and lethal; registration and
manifest hygiene; and the owner-amendment non-goals. The deviation of flipping BOTH merchant scanner
signatures was confirmed correct — the v89 one is dead and v117 is what `app/app.js:1314` calls.

### Residual risks the review named, carried forward (not defects)

1. Two-step switching (stamps on, then points off) strands the points pot where the wizard's
   one-call path migrates it. This is the documented "frozen, not confiscated" rule, and increment
   2's four independent toggles are what make the two-step path reachable — **name it in the
   increment-2 brief**.
2. `public.customer_get_reward_catalog` returns a single-element `programmes` array derived from
   `loyalty_model`, plus a frozen `points_mode` key. Unreachable in increment 1 (no UI creates a
   both-firm), wrong the moment increment 2 does. Residual §7 flagged the `points_mode` key; the
   `programmes[].kind` half is recorded here.
3. The v117 scanner needle is written against the repo replay; production's live body is unpinned by
   design and the wave aborts at apply if its whitespace differs. The integrator's "read and record"
   pre-flight step is therefore load-bearing.
4. `tiers:{points:false,tiers:true}` means a tiers-only firm accrues nothing, so a ladder measured
   on `points_earned` cannot climb under that pick. It is coherent for the visits basis the wizard
   defaults tiers-only firms to, and 'both' is the pick for a points-measured ladder — but increment
   2's independent toggles should surface it rather than leave it implied.

## Owner amendment 2026-08-14 — satisfied by omission, and mechanically guarded

Nothing in either migration touches `tier_basis`, `expiry_mode`, `expiry_days` or any other expiry
knob. Both headers state it as a non-goal so a later reader does not "tidy it up", and suite step
31 is the mechanical guard: it fails if `set_programmes_v314`'s body ever mentions either. The tier
programme gains an independent ON/OFF switch here and nothing else; the basis CHOICE and its
`GROW_SETUP_CLIMB_V305` control are increment 2's deliverable, unchanged and undeleted.

## Design facts

1. **v313 is a hard precondition of v314, not a convenience.** W5 spliced the batch drain and the
   affordability check to scope through `app.resolve_ledger_programme_v309(p_business)`
   (`v311:911-993`, `:1505-1545`). That resolver answers from `loyalty_programs.loyalty_model =
   'stamps'` — a single-valued question. The moment the switchboard lets points and stamps both
   run, the resolver is a lie and catalogue redemption drains the wrong pot. Fusing the two puts
   the backfill and the thing that invalidates it in one atomic chain.
2. **The seeder.** `v308:395-401` was commented *"businesses: INSERT creates the four rows for a
   brand-new tenant"*. Dropping it without a replacement would leave every business created after
   v314 with zero spine rows, and every consequence is silent: the earn loop iterates nothing, the
   authoring default raises 23514, `points_ledger.programme_id` has nowhere legal to point.
   `app.seed_business_programmes_v314` replaces it, seed-only, never updating. Provably a no-op
   versus today: `public.create_business` inserts `businesses` FIRST
   (`20260721000004_frenly_v25_draft_onboarding_loyalty.sql:53`) and only then `loyalty_programs …
   active=false` (`:71-77`), so `app.business_programmes_v307` already answered all-four-false at
   insert time. The observable change is that the later `loyalty_programs` insert no longer
   resyncs — correct in the switchboard world, and named rather than discovered.
3. **The pot-routing rule is MOVEMENT, not "one left standing".** The build brief states it as
   `|A| = 1 and the sibling is inactive and holds a pot`, but that form contradicts its own second
   exclusion: turning one of two accruing programmes off also leaves `|A| = 1` with a sibling
   holding money, and that flip must **not** confiscate the paused pot. The implemented rule is:
   enqueue iff, across the call, the single accruing programme changed from X to Y **and** X still
   holds money — exactly what `app.programme_pot_switch_v312` expressed on `loyalty_model`
   (`v312:1030-1039`), generalised to the switchboard. The three no-enqueue cases:
   - **adding a second accruing programme** — `|A|` becomes 2; the points pot stays with points and
     stamps starts empty. Turning stamps on never moves anyone's points.
   - **turning one of two off** — Y was already accruing, so identity did not move; the paused
     programme's pot is frozen, not confiscated, and turning it back on resumes the same pot.
   - **both on** — a split IS the intended state; `app.programme_balance_scope_v312` already reads
     `programme_pot` for it, because it tests parity and negativity, not distinct tags.
   Suite steps 19 (moves) and 20 (all three no-enqueue cases) measure both halves; mutant M14
   restores the brief's literal form and turns step 20 red.
4. **The tripwire SWALLOWS, deliberately (brief R4).** `/app-*.js` is CDN-pinned ~4h, so the old
   bundle keeps PATCHing `businesses.points_mode` after every wizard publish for that long. A
   raising tripwire would surface as *"Published. The … switch could not be applied"* for every
   owner who publishes in the window. The column is silently pinned and one `audit_log` row
   `POINTS_MODE_WRITE_SUPPRESSED_V314` is written. Increment 9 upgrades it to a raise; suite step 8
   proves the raising variant works **now**, against the real trigger, so increment 9 inherits a
   proof rather than a plan.
5. **Consumer 5's declared, live-visible behaviour change.** QA Test Cafe and QA Go-Live Cafe are
   `loyalty_model='classic'` and therefore cannot redeem a catalogue reward at all today
   (`v34:551`). After the flip, "points switched on" means catalogue redemption works for them.
   Suite step 15 measures both sides of that boundary. **This is in the owner note, not discovered
   at a counter.**
6. **Six consumers, plus one the brief under-counted.** The brief names
   `public.merchant_scan_redemption_qr_v89` for consumer 6 site 1, citing `v89:1177` — text that is
   true of BOTH scanner bodies. `merchant_scan_redemption_qr_v117(uuid,uuid,text,uuid)` is the LIVE
   settle path (`app/app.js:1314`, `app/app-business.js:386`); the v89 signature is fully revoked
   (`v93:297`, `v117:931`) but still installed. Flipping only the dead one would have left the
   reachable scanner refusing every redemption at a firm whose `loyalty_programs` row is not
   `active`. **Both are flipped**, each with its own counted needle because their whitespace
   differs, and the migration reports how many it moved.
7. **v313 covers its three INSERT writers with a default, not four column-list splices.**
   `public.save_loyalty_reward_draft` and `public.publish_loyalty_config` carry a V176 "Stage A"
   `min_tier_id`/`min_tier_threshold` patch that was applied by asserted string replacement against
   their LIVE definitions and that **no repo migration reproduces** (`v176b:51-53` records the fact;
   `20260806_nestly_v176_reward_tier_gate.sql` adds the columns and stops at 55 lines). Their live
   column lists therefore have a shape this repo cannot predict. So the three INSERT writers
   (`save_loyalty_reward_draft`, `app.clone_reward_versions_for_config`,
   `public.ensure_published_reward_in_draft_v138`) are covered by one BEFORE INSERT default that
   only ever fills a NULL, and only the UPDATE projection is spliced — on the anchor
   `update public.loyalty_rewards r set `, which no Stage A edit can have moved. The doctrinal
   difference from v311 is narrow and deliberate: v309's money default guessed from a resolver
   about to become a lie, whereas this default is derived from the row's OWN business and, for a
   version, from its OWN live reward — correct by construction, and it raises 23514 rather than
   writing NULL when it cannot decide.
8. **The authoring default follows authority.** The brief says a new reward with no explicit
   programme "defaults to the business's points spine row". Taken literally that would price a
   stamps firm's new rewards in a pot its customers never fill — the same defect v313 exists to
   close, moved from redemption time to authoring time. `app.reward_default_programme_v313` is the
   one named place that answers: v313's body is the v309 answer with a points fallback (exactly
   right inside that wave), and **v314 re-bodies it** to "the business's one active accruing
   programme when there is exactly one, points otherwise" in the same transaction that makes the
   resolver a lie. Suite step 25 measures it.
9. **V308 standing invariant 2 is retired.** `business_programmes_sync_loyalty_tiers_v308` was the
   only `DEFERRABLE INITIALLY DEFERRED` trigger in the set. With it dropped nothing defers, and the
   spine is correct statement-by-statement again. Post-assertion 9.1 refuses any surviving deferred
   spine trigger, so the retirement is enforced rather than merely written down.

## Verification

- Cluster: a throwaway PostgreSQL 17 built from the **real** v307→v312 lineage (the W5 rig,
  extended). Every predecessor body is reconstructed by line extraction from its own repo file, in
  apply order, and the real `20260813_nestly_v307/v308/v309/v310/v311/v312` migrations are applied
  unmodified. Rig extension for this wave: `v229` (the points_mode intent gate),
  `customer_get_business_actions_v89` (`v89:790-896`), `merchant_scan_redemption_qr_v89`
  (`v89:1114-1281`), `merchant_scan_redemption_qr_v117` (`v117:355-636`) and
  `publish_loyalty_config` (`v55:673-721`), all extracted verbatim; only the publish kernel's
  PERIPHERY (rule studio, birthday, taxonomy, snapshot hash) is stubbed, and every stub is EMPTY in
  every fixture, so the extracted body's branches over them are no-ops exactly as they are for a
  firm that uses none of those features.
- **The lineage replay is byte-exact where it matters.** On the rig, before v313:
  `app.on_sale_recorded` = `aac80aec8f893ed6c883020aff5da090`, `app.redeem_reward_core` =
  `91171a153bc295bbaf0e535b3e9c4d7b`, `customer_create_redemption_intent_v89` =
  `f396a1e8e5914e880c293303276a5cc1`, `customer_portal_capabilities` (normalised) =
  `735e2b2b885f12937c73ff0aae827085` — **all four identical to the recorded W5 production
  post-state** (`V311-V312-W5-MONEY-WAVE-ACCEPTANCE.md:93-113`). The one divergence is
  `customer_get_reward_catalog`, whose canonical replay has differed from live since v310
  (`v310:213-220` records both values); v314 does not touch it and pins it with a notice, not an
  exception.
- Suite `db/tests/v313_v314_programme_switchboard.sql`: **35/35 PASS**, rolled back, against the
  real migration bytes. Four tenant shapes plus four more are CONSTRUCTED inside the transaction,
  because zero live tenants exercise most changed branches. (Steps 33-35 and tenants T7/T8 are the
  adversarial review's three probe schedules, made permanent.)
- Client suite `tests/business-ui/v314-programme-switchboard.test.mjs`: **11/11 PASS**. The three
  confirmed findings were client defects and are invisible to SQL, so their regression pins are
  source-level.
- **Red-first mutation matrix: 18 mutants, 18 lethal.** Every mutation is applied to the live
  catalogue inside the same transaction as the suite body, so each measures the shipped bytes.

  | # | mutation | suite steps that go red |
  |---|---|---|
  | M1 | drop the seeder trigger | **whole suite ABORTS** — `reward programme is not resolvable for business …` at fixture time |
  | M2 | re-attach one v308 sync trigger (`loyalty_programs`) | 1, 2, 3, 9, 10, 12, 15, 21, 22, 25, 27, **34** |
  | M3 | let a re-activation CLEAR `deactivated_at` | 3 |
  | M4 | remove the no-op-flip guard | 4 |
  | M5 | make the idempotency receipt an upsert | 5, 22 |
  | M6 | remove the `c45_owner_loyalty_write` gate | 6, 7, 9, 10 |
  | M7 | make the points_mode tripwire RAISE | 7, 8 |
  | M8 | revert consumer 1 (`if found and lp.active then`) | 10, **33** |
  | M9 | revert consumer 2 (`and lp.kind='points'`) | 32 |
  | M10 | revert v313's `redeem_reward_core` re-splice | 13, 26 |
  | M11 | revert v313's intent re-splice | 16, 26 |
  | M12 | remove the per-reward programme-active check in the intent | 17 |
  | M13 | revert consumer 3 (capabilities derive `points_mode`) | 18 |
  | M14 | use the brief's literal `\|A\|=1` routing form | 20 |
  | M15 | restore `trg_programme_pot_switch_v312` | 21 |
  | M16 | revert the publish stamps guard to `loyalty_model` | 22 |
  | M17 | drop `programme_id=rv.programme_id` from the publish projection | 25 |
  | **M18** | **F2r — restore `and active limit 1` on `redeem_reward_core`'s row lookup** | **33** |

  All 17 original mutants keep their original red sets; M2 and M8 gain a step because the new
  steps cover ground the old ones did not.

- **Red-first for the three CLIENT fixes.** They cannot be reverted with a SQL mutant, so each fix
  was reverted in `app/app.js` and `tests/business-ui/v314-programme-switchboard.test.mjs` re-run
  (`app/app.js` restored byte-identical afterwards, verified by `diff`):

  | # | revert | client suite result |
  |---|---|---|
  | F1r | restore the Grow editor's `points_mode` writer | 9 pass / **2 fail** — "NOTHING in the bundle writes businesses.points_mode any more", "the Grow editor Save routes the four-way toggle through the spine" |
  | F2r | drop the `paused` branch from `programmeSwitchSetV314` | 10 pass / **1 fail** — "keepPaused reaches the switch call, and turns the whole chosen set OFF" |
  | F3r | remove the review route's switch call | 10 pass / **1 fail** — "every publish route applies the switches through the same helper" |

  Step 35 is deliberately NOT in the mutant table: it is the end-to-end ACCEPTANCE bar reproduced
  from the review's own probe schedule, not a discriminator. Its discriminating partners are step 34
  (killed by M2) and F3r above.

- Two defects found by the matrix and fixed before this document was written, both in the SUITE
  rather than the migrations: three shared fixtures (the two T3 rewards, the T5 reward and the whole
  customer-session block) were built INSIDE `begin … exception` blocks, which are subtransactions —
  a catch rolled them back and the next step read a fixture that no longer existed; and step 12's
  original form could not see consumer 2's flip at all, because every wizard-written version row
  carries `kind='points'`. Tenant **T6** (`loyalty_model='stamps'` AND version `kind='stamps'`, the
  shape `v26:43` permits and the wizard never writes) makes that flip behavioural, and step 32
  measures it.
- Gates: `npm test` **2890/2891**. The one red is `store association generator fails closed …`,
  which is environmental (`missing dependency privacy manifest:
  node_modules/@capacitor/ios/CapacitorCordova/CapacitorCordova/PrivacyInfo.xcprivacy`),
  pre-existing and untouched by this wave. `npm run migration-manifest:check`,
  `npm run canonical-migrations:check` and `--check-plan` are green.
  **`npm run bundle-stamp` HAS been run in the remediation** (the first cut deferred it). It was not
  cosmetic here: until the surface bundles are regenerated, `app/app-business.js` still ships the
  two deleted `points_mode` writers, so finding 1 would be fixed in the source and live in the
  artifact. `app/app-core.js`, `app/app-business.js` and `app/index.html` are regenerated; the two
  phase0 staleness checks are green (phase0: **89/89**).
- Test files updated for the moved contracts, each with its rationale in place: the seven pins that
  asserted the old `businesses.points_mode` write or the deleted chooser
  (`v191-product-edit`, `v229-topic-tiles-and-points-mode`, `v230-one-loyalty-model`,
  `v235-loyalty-ux`, `v240-points-and-tiers-together` ×2, `v258-loyalty-setup-friction` ×2,
  `v301-programmes-setup-wizard` ×2, `v306-wizard-mode-and-basis-hotfix`). Every one keeps the FACT
  it was protecting and re-points it at the spine; none was deleted. The two generated browser
  fixtures (`v129-trial-test-visual.html`, `v145-launch-freeze-visual.html`) are regenerated from
  the current `app/app.js`. Business-UI suites: **984/984**.

## Suite step map

| step | what it proves |
|---|---|
| 1 | the seeder gives every new tenant four spine rows, all inactive |
| 2 | the four v308 sync triggers are dropped BY NAME; a `loyalty_programs` write no longer moves the spine; the sync FUNCTION survives for the rollback |
| 3 | a switch flips the spine, keeps v308's breadcrumb semantics, and writes one `PROGRAMME_SWITCH_V314` per real flip |
| 4 | a no-op flip writes NOTHING — no breadcrumb churn, no audit row, no claimed change |
| 5 | a double-tapped switch is one switch; a different payload under the same key is 23505 |
| 6 | only the owner RPC writes the spine; a stranger is refused, an authenticated session cannot write the table, the ACL floor holds |
| 7 | an old-bundle `points_mode` write is SWALLOWED and audited, and does not disturb the spine |
| 8 | the named escape GUC works, and the increment-9 RAISE variant is proven against the real trigger |
| 9 | **THE HEADLINE** — a switch survives `publish_loyalty_config` |
| 10 | the earn loop is gated by the SPINE, not the version row |
| 11 | a switched-off programme stops accruing |
| 12 | points AND stamps: one sale, two tagged earns, two batches, in-trigger parity holds |
| 13 | **the cross-programme double-spend, closed end-to-end** — a points gift drains points, a stamps gift drains stamps |
| 14 | a rich points pot cannot rescue a short stamps reward |
| 15 | a `classic` firm redeems a catalogue reward once points are on (consumer 5's declared change) |
| 16 | the customer quote is scoped to the reward's own programme |
| 17 | a paused programme's reward is refused at quote time; the intent no longer reads `points_mode` |
| 18 | capabilities derive `points_mode` from the spine and it is never null; the contract key and the four-row array survive |
| 19 | an accruing-identity flip routes through `app.enqueue_programme_pot_migration_v312`; the pot arrives whole; the detector stays empty |
| 20 | adding, pausing and splitting never move a pot |
| 21 | a settings republish across the stamps boundary moves no pot |
| 22 | the publish stamps guard is keyed on the stamps SWITCH; the points side stays lenient |
| 23 | the switch takes the `businesses` row before the spine rows, in kind order |
| 24 | `set_programmes_v314` self-heals a firm missing spine rows |
| 25 | a reward always knows its programme and only its own tenant's; the default resolves; publish projects it |
| 26 | honesty: the v309 tag triggers are gone, nothing is untagged or cross-tenant, no money path calls the oracle |
| 27 | the rollback re-derives the spine — **and discards the switches** |
| 28 | `detect_spine_legacy_divergence_v314` reports the intended divergence (a report, never an assertion) |
| 29 | both standing money detectors empty; four spine rows per business; no orphan tag |
| 30 | both migrations carry a self-refusal; the function catalog is byte-stable under a read-only check |
| 31 | `tier_basis` and every expiry knob untouched (OWNER AMENDMENT), mechanically |
| 32 | a stamps-KIND version can still run the points programme (consumer 2, behavioural) |
| 33 | **finding 2** — publishing PAUSED earns nothing AND pays nothing; unpausing the same firm restores both, with the published settings row still saying `active=false` |
| 34 | **finding 3** — an ACTIVE publish alone does NOT switch the spine (the inversion working as designed); the switch call the publish routes now make does |
| 35 | **finding 3, the acceptance bar** — a brand-new post-v314 tenant published ACTIVE from a NON-wizard route earns one correctly tagged row on its next sale |

Steps 33-35 are the adversarial review's three probe schedules, made permanent. Finding 1 (the two
client writers) has no server surface to assert against — the tripwire behaviour it exploits is
already step 7 — so its pins are source-level, in
`tests/business-ui/v314-programme-switchboard.test.mjs`.

## Post-state fingerprints (rig, byte-identical to what production will hold)

`md5(prosrc)`; normalised = full-line comments stripped, everything else byte-for-byte, because a
production apply strips them and a byte-faithful one does not.

**After v313** (these are the values v314 §0 pins, and they are what v313 deterministically
produces from the recorded W5 production post-state):

| function | raw | normalised |
|---|---|---|
| `app.redeem_reward_core/7` | `4b994c9b8865b5fbf72383db484500d3` | (same) |
| `public.customer_create_redemption_intent_v89/4` | `f639d833b9907ff2a03402c7388c5351` | `bf653a90adbe617b9b84f4942529bacc` |

**After v314:**

| function | raw | normalised |
|---|---|---|
| `app.on_sale_recorded/0` | `094f7f8e2be24cea0a8d9d3e8fbacfdc` | (same) |
| `app.redeem_reward_core/7` | `37ae059cca6715bd998daab843776279` | (same) |
| `public.customer_create_redemption_intent_v89/4` | `2913f3847db0a5c77427cbcc5edc7b0f` | `673fedeb36c979831360afea6adb87c4` |
| `public.customer_portal_capabilities/1` | `f8dc992fb496f3d8574d6244151c2a54` | `918a264e9f0eb595f96a7c10a7f0ca61` |
| `public.customer_get_business_actions_v89/1` | `7cce57c72be68556a54784ce0020aff9` | `70d9f5214397acad2651a9e6d52a179d` |
| `public.merchant_scan_redemption_qr_v117/4` | `e6117b02a0746f8e87cf0f5eda5b71f5` | `ad349b08b65e6b2376f545fb058207b7` |
| `public.merchant_scan_redemption_qr_v89/3` | `76228930e7288502471ad285fb334435` | (same) |
| `public.set_programmes_v314/3` | `3400454e911de49756ac00e9a7cd6551` | `fe0d353ec384d84540fa5717fadec307` |
| `app.seed_business_programmes_v314/0` | `c2b6be39619944506f98466db5c0ac4e` | (same) |
| `app.points_mode_frozen_v314/0` | `c3a5b5bd0bb2907a1e71d8f194fd2dca` | `9bbf902d76f312a533ddc0363f942b6f` |
| `app.business_programmes_active_v314/1` | `a8792c51390a0461bc5ce83eb587bd55` | (same) |
| `app.detect_spine_legacy_divergence_v314/0` | `2d5e3eb0386464d2bae93bdc6849a458` | (same) |
| `app.reward_default_programme_v313/1` | `db1165fe71a5bd3c5d1487dcd8cbc53e` | (same) |

`app.redeem_reward_core/7` moved from the first cut's `4bafcd97603490eba3540d1fb390ddee` when
finding 2's fix added consumer 5 site 1 (the row lookup). Every other body above is byte-identical
to the first cut — the remediation touched exactly one server body, and the post-v313 pin
(`4b994c9b8865b5fbf72383db484500d3`) is unchanged because v313 itself was not edited.

`public.publish_loyalty_config/1` is **not** pinned: its live body carries the un-repo'd V176
Stage A patch, so the rig's value (`ccf14b6bc7f45420495cd8a23dfc4e8f`) is not production's.
Structural assertions guard it instead (`programme_id=rv.programme_id` present; the stamps guard
reads the spine).

## Rollback, said out loud

Re-attaching the four v308 sync triggers and re-running `app.sync_business_programmes_v308` per
business restores the pre-inversion world **and discards every switch an owner made after the
inversion**, because the sync recomputes from the legacy columns. That is the rollback. Suite step
27 proves both halves of it. It belongs here, not in an incident.

`app.sync_business_programmes_v308`, `app.business_programmes_sync_trigger_v308`,
`app.programme_pot_switch_v312`, `app.tag_ledger_programme_v309` and
`app.resolve_ledger_programme_v309` are all kept INSTALLED and revoked, so every rollback step is
`create trigger`, never `create function`.

## Standing invariants for increment 2+

1. **The md5 pin chain.** The next increment that edits any of these MUST pre-assert the v314
   post-apply value above: `app.redeem_reward_core` (inc 5, inc 6), `app.on_sale_recorded`
   (inc 4, inc 6), `merchant_scan_redemption_qr_v117` **and** `_v89` (inc 3),
   `customer_create_redemption_intent_v89` (inc 3), `customer_portal_capabilities`.
   None of those increments may be in flight simultaneously.
2. **Pot routing is MOVEMENT.** Enqueue iff the single accruing programme changed identity from X
   to Y and X still holds money. Adding a second accruing programme, pausing one of two, and
   running both never enqueue. `app.enqueue_programme_pot_migration_v312` remains THE entry point
   (V311/V312 standing invariant 2); nothing else may move a pot.
3. **The tripwire swallows until increment 9.** Upgrade it to a raise only once
   `audit_log where action='POINTS_MODE_WRITE_SUPPRESSED_V314'` shows zero rows over a full CDN
   window. Suite step 8 already proves the raising variant. **This condition is now SATISFIABLE**:
   the remediation removed the last two client writers, so the only rows that table can gain after
   deploy come from the old cached bundle during its Cloudflare window. Before the first cut it
   could never have been met — see finding 1.
4. **The seeder exists and must keep existing.** Any later migration touching
   `public.businesses`'s trigger set must preserve `business_programmes_seed_v314` or a successor.
   v314 post-assertion 9.1 refuses to apply without it.
5. **`app.business_programmes_v307` is the PRE-INVERSION ORACLE.** It is no longer truth. It keeps
   exactly one live job — seeding a brand-new tenant and self-healing a firm that lacks rows — and
   its role as the reference every W1–W5 acceptance document was measured against.
   `app.business_programmes_active_v314` is the spine reader.
   `app.detect_spine_legacy_divergence_v314` is a **report and never an assertion**: it was
   asserted empty once, at apply, and the first owner who switches independently makes it non-empty
   by design.
6. **V308 standing invariant 2 is RETIRED.** Nothing defers any more.
7. **Named residuals, deliberately left for increment 2** (each is a decision, not an oversight):
   - `customer_portal_capabilities.wallet` and `.activity` still read `loyalty_programs.active`.
     That column now means "this firm has a published loyalty configuration", which is the correct
     question for those two keys — but it is a legacy read, and increment 2 should say so on the
     surface it builds.
   - `public.customer_get_effective_tier_v143` and `public.customer_get_reward_catalog` still
     report a `points_mode` KEY read from the frozen `businesses` column. Both are presentation
     values, not switches; they go stale for a firm that switches, and increment 2 (which owns the
     customer-side fixtures anyway) should derive them the way `customer_portal_capabilities` now
     does.
   - `tests/browser/reward-overview-owner-visual.html` still inlines the pre-v314 wizard source
     (it carries no `production-source-sha256` pin, so no test caught it). Regenerate it with the
     nine customer fixtures in increment 2's client wave.
8. **`loyalty_program_versions.kind` and `.loyalty_model` remain single-valued settings
   discriminators** (`v26:43-44`) under the v26 immutability guard. Increment 1 stops READING them
   as switches but does not remove them; an increment that wants per-programme settings rows must
   plan for that guard.

## Integrator notes

**Apply order, non-negotiable:** `v313` (slot `20260814000100`) then `v314` (slot
`20260814000200`). v314 refuses to apply on anything but v313's post-state.

**Pre-flight pin list (read-only, on `gadpooereceldfpfxsod`, before v313):**

| target | expected | form |
|---|---|---|
| `app.redeem_reward_core` | `91171a153bc295bbaf0e535b3e9c4d7b` | raw (no comments in body) |
| `public.customer_create_redemption_intent_v89` | `f396a1e8e5914e880c293303276a5cc1` | raw |
| `app.on_sale_recorded` | `aac80aec8f893ed6c883020aff5da090` | raw |
| `public.customer_portal_capabilities` | `735e2b2b885f12937c73ff0aae827085` | normalised |
| `public.customer_get_reward_catalog` | `07897b24b70da71c5a954d748cc0df3d` | normalised, **notice only** |
| `public.merchant_scan_redemption_qr_v117` | READ AND RECORD | raw — no repo file reproduces it; the counted needles are the guard |
| `business_programmes_exclusive_accrual_v308` | ABSENT | trigger |
| `points_earn_once_per_sale_per_programme` / `points_earn_once_per_sale` | EXISTS / ABSENT | index |
| `app.detect_programme_pot_split_v312()` | 0 rows | detector |

v313 and v314 assert all of these themselves and fail closed; the pre-flight exists so a mismatch
is discovered before a transaction is opened, not inside one.

**Expected backfill counts.** v313's backfill is `update … set programme_id = …` over every
existing `loyalty_rewards` and `loyalty_reward_versions` row; on production that is the full live
catalogue and its version history. It asserts, in-transaction: zero NULLs on both tables, zero
cross-tenant tags, zero reward/version disagreements. It raises the counts as a NOTICE — record
them in the apply log. No money row is written or read.

**`schema_migrations` re-check obligation, non-negotiable.** `nestly_vNNN` is a shared namespace
across parallel sessions. Before registering or applying: rebase onto `origin/main`, re-read
`db/migrations/migration-order.plan.json` and `supabase/canonical-migration-order.plan.json`,
**and** query `supabase_migrations.schema_migrations` for `version >= '20260814000000'`. The plan
files are the repo's intent; `schema_migrations` is what production actually holds, and W5's own
apply proved they can diverge mid-wave (v312 refused itself once and was re-applied).

**`npm run bundle-stamp` HAS been run** (the first cut deferred it; the remediation could not).
`app/app-core.js`, `app/app-business.js` and `app/index.html` are regenerated and the two phase0
staleness checks are green. Re-run it after any rebase that touches `app/app.js` — it is
deterministic, so a second run on the same source is a no-op. **Why it mattered here:** until the
surface bundles are regenerated, `app/app-business.js` still ships the two deleted `points_mode`
writers, so finding 1 would be fixed in the source and live in the artifact — and the increment-9
condition (zero `POINTS_MODE_WRITE_SUPPRESSED_V314` rows) would stay unreachable. The two generated
browser fixtures were regenerated for the same reason. Nothing in the repo is left red by this
increment except the pre-existing environmental v131 store-association check.

**One extra CDN-window consequence to expect, and it is benign.** For the ~4h the old bundle stays
cached, an owner who saves the Grow editor still PATCHes `businesses.points_mode`; the tripwire pins
it and writes one `POINTS_MODE_WRITE_SUPPRESSED_V314` audit row, and their model choice does not
reach the spine. That is the same window the tripwire was designed for. Start the increment-9
zero-rows measurement after the window closes, not at deploy.

**Post-apply, hit the service, not just the fingerprint.** Repo memory: fingerprints prove the
deploy, not the service. Post-apply, call one REST RPC on the real project — a
`customer_portal_capabilities` read for a live business — and assert `points_mode` is present and
**non-NULL** and `programmes_contract` is still `'v310'`. Then create-and-roll-back one business to
confirm the seeder gives it four spine rows.

**Files**

| file | sha256 | md5 |
|---|---|---|
| `db/migrations/20260814_nestly_v313_reward_programme_identity.sql` | `15bca485e749d8289e78b9d9135e21f146ce6314af06979d105ed84394daecee` | (as applied, incl. apply-day edits) |
| `db/migrations/20260814_nestly_v314_programme_switchboard_inversion.sql` | `20b6f040dd3f24b7808df75a3d7d38a8ebfbe7cc320efa8a31e4cd998653fd50` | (as applied, incl. apply-day edits) |
| `db/tests/v313_v314_programme_switchboard.sql` | `64d431c33060025005333ab0d4cbeb85b81e1dc45dbcb1b2fa3d1fea2de605dc` | `d55ce644bdd58e781dc4a5ce48cf281a` |
| `supabase/migrations/20260814000100_nestly_v313_reward_programme_identity.sql` | (byte-identical mirror, `cmp` clean) | — |
| `supabase/migrations/20260814000200_nestly_v314_programme_switchboard_inversion.sql` | (byte-identical mirror, `cmp` clean) | — |
| `tests/business-ui/v314-programme-switchboard.test.mjs` | `e505c2f09d32fc1eded436020cdb65643cb22665ad0774ea0639e4aa007574e2` | `d6926daac2d1a3a58a0cd6cc109ac18c` |
| `app/app.js` | `7efdfeed4513d84acff990b65b0731a55f6236508774500e924a0783ffdb0151` | `b19f58d87a264170147f97075e76f0a7` |
| `app/app-core.js` (generated) | `ce10195ecb7aa87fcf73c9839aa7060e472ed9c106531196d72d76bb41900a0a` | `ee1f8b0c5c164e46af431a8a56e35426` |
| `app/app-business.js` (generated) | `6a680c272e95f32216bfc8f9d401905047320c6c8b4baddc5862ac99f8a0caf0` | `4d81f33543775c89632344c7784b461b` |
| `app/index.html` (generated stamp) | `d72618e626397f79` (prefix; as shipped — carries this increment's stamps MERGED with the parallel session's platform-console stamp after the rebase onto main `409c7db`) | — |
| `tests/browser/v129-trial-test-visual.html` | `b7998dc7fdd15d2d900df60da9c446b6767a4a47eecb355eb59fdc895b740b4d` | `80117e1cee303ee53eab067ee49d77c5` |
| `tests/browser/v145-launch-freeze-visual.html` | `027645ced2c1bdeb942c86a8b40d09f4f9d259928c37f2d6020b787518791f85` | `7be0c1f4a6986eb6fe685e63ee78641e` |

Remediation history of the bytes: v313 was `128986…` as first cut and unchanged by the
remediation; v314 moved from `dafa2d01…` to `70bf98e6…` (one new counted needle — consumer 5
site 1 — one new post-assertion, the complete pause rule in the header, and the
`loyalty_programs.active` column comment). Both then moved once more on APPLY DAY (2026-08-14,
sections below): v313 `128986…` → `15bca485…`, v314 `70bf98e6…` → `20b6f040…`.

**Pre-flight list: unchanged by the remediation.** The one row that moves is a POST-state value:
`app.redeem_reward_core` after v314 is now `37ae059cca6715bd998daab843776279`
(was `4bafcd97603490eba3540d1fb390ddee`). Anything that pinned the old post-value — nothing does
yet; increments 5 and 6 will — must use the new one.

## Production apply, 2026-08-14 (gadpooereceldfpfxsod) — two incidents, both cured IN the bytes

**Incident 1 — three identical deadlocks (40P01), cured by a deterministic lock prelude.** The
first three apply attempts each aborted whole with the same signature: our backend reported
waiting on an AccessExclusiveLock on `storage.objects` while a PostgREST backend held
`storage.objects` (AccessShare) and waited to read `loyalty_rewards`, which we held. The
counterparty transaction was running `public.business_publish_media_replacement_v95`.
Per-statement lock probes proved our DDL requests nothing on `storage.*` (the analytics log API
was down, so the reported waiter attribution stays unexplained), and the structural cure needs no
attribution: both migrations now open with `set local lock_timeout='25s'` and one ordered
`LOCK TABLE` acquiring `storage.objects` (conditionally — rigs replay app/public only) plus every
table the migration will alter. With everything contested held up front, no cycle can form;
concurrent media transactions (millisecond-scale) queue behind the migration for the seconds it
runs. Attempt 4 (v313) and the v314 apply both went through cleanly.

> **CORRECTION 2026-08-14, same day, from a parallel session's independent investigation.**
> This section originally attributed the deadlocks to a *continuous erroring retry stream* of that
> RPC, inferred from seeing it on the same two PostgREST pids at every sample plus a gap between
> expected calls and `pg_stat_statements.calls`. **That diagnosis was wrong and is withdrawn.**
> `pg_stat_activity.query` holds the LAST statement a backend ran and keeps showing it after the
> statement finishes, so repeated sightings on pooled connections prove nothing; `backend_start`
> age (~7.4 days) is ordinary pooled-connection age, not a stuck client. The shipped caller
> (`app/v95-media-sync.js`) calls the RPC exactly once per button press — no loop, no retry, no
> edge caller — and already surfaces the version conflict to the user. Diagnose with `state` +
> `query_start`, never query text: `idle in transaction (aborted)` is what actually deadlocks a
> concurrent migration. **What does not change:** the three 40P01s were real, the lock prelude is
> the correct structural cure, and it is what let the applies through. **What does change:** there
> is no media retry storm; the separately-raised storm task is void, and the migration files'
> own prelude comments still carry the original wording — read them against this correction. One
> genuine latent issue surfaced by the same investigation and left open: the RPC raises
> `40001` (serialization_failure) for a business-logic version conflict, which invites automatic
> retries from any layer that treats 40001 as retryable; a non-retryable class (23514/22023) is
> the right shape.

**Incident 2 — the versions backfill tripped the v27 immutability guard (23001), a case the rig
fixture never held.** On the first non-deadlocked attempt, `update public.loyalty_reward_versions
set programme_id=…` was refused by `trg_loyalty_reward_versions_immutable` ("published reward
configuration is immutable"): the guard rejects ALL DML on a version row whose config is
non-draft, and production holds 98 such rows where the rig's fixture held ZERO — the escape route
for this defect. The fix is in the migration bytes, on the v281 house precedent
(`20260812_nestly_v281…:583-588`): the backfill window now disables exactly
`trg_loyalty_reward_versions_immutable` and `trg_loyalty_reward_versions_snapshot` (which would
otherwise rebuild every historical config's snapshot once per touched row, for a column snapshots
do not read) around the ONE versions UPDATE, under the prelude's AccessExclusiveLock, re-enables
both immediately after, and the postcondition block asserts both are back to `'O'` and both still
exist. The v313 TENANT guard stays live through the backfill. Unconditional by design: a
production without these triggers should fail loudly, not proceed silently.

**Rig fidelity repair + red-first.** The w6fix rig stub had omitted the v27 guard/snapshot
objects (they ARE in the repo lineage — `20260720_frenly_v27_rich_rewards.sql:322` — the stub
never carried them). The rig was rebuilt with the REAL v27 function + both triggers installed
verbatim and a fixture holding one PUBLISHED config + reward + version. **Red-first:** the
pre-fix bytes abort on that rig with exactly the production error (23001, transaction rolled back
whole, column absent afterwards). The fixed bytes then apply clean (backfill notice: 1+1 tagged),
v314 applies clean on top, the full suite runs **35/35** against this more faithful shape, both
suspended triggers read `'O'`, the fixture version row is tagged, and the post-state pins are
IDENTICAL to the remediation's (`redeem_reward_core` `37ae059c…`, `on_sale_recorded`
`094f7f8e…`) — the trigger window changes no function body. The comment-strip transformation was
itself re-verified by reproducing the previously-validated apply copies byte-exactly modulo
exactly the two deliberate edits.

**The apply itself.** Pre-flight: all four W5 pins matched raw; catalog matched the notice-only
value; `merchant_scan_redemption_qr_v117` READ-AND-RECORDED `1ac39258e3257af3eb1fe215e161e815`
(v89 scanner `d63bebbe6a764255082ea6e58067ee7f`); v308 tripwire absent; per-programme arbiter
present and valid, v2 index absent; both detectors 0; `schema_migrations >= '20260814000000'`
empty; expected backfill counted 14 rewards + 98 versions. **v313 applied** (slot
`20260814000100`): pins-met notice, backfill notice `14 loyalty_rewards and 98
loyalty_reward_versions tagged, zero nulls, zero cross-tenant tags, zero reward/version
disagreements`, postconditions green, `redeem_reward_core` post-state
`4b994c9b8865b5fbf72383db484500d3` = the rig pin. **v314 applied** (slot `20260814000200`): its
own pin block verified v313's post-state (including the normalised intent body `bf653a90…`)
before flipping; postcondition notice reports six consumers on the spine, seeder + tripwire +
switch RPC installed, ACL floors held, owner amendment honoured. **Post-apply battery:**
create-and-roll-back business → exactly four spine rows from the seeder; a live `points_mode`
write swallowed AND audited (`POINTS_MODE_WRITE_SUPPRESSED_V314`), probe rolled back;
`detect_spine_legacy_divergence_v314()` = 0 (the inversion landed on an agreeing state);
`detect_programme_pot_split_v312()` = 0; `detect_double_earn_v309()` = 0; post-state md5s match
the rig exactly (`37ae059c…` / `094f7f8e…`); `set_programmes_v314` callable by authenticated and
not by anon; every business holds exactly four spine rows; the four v308 sync triggers and
`trg_programme_pot_switch_v312` gone, seeder live. REST liveness: an anon RPC round-trip returns
cleanly post-DDL (the service, not just the fingerprint).

**Version-namespace note.** The semantic labels v313/v314 are now shared with a parallel
session's prospecting migrations (`nestly_v313_conversion_first_prospecting`,
`nestly_v314_business_explorer_and_funnel`, applied 2026-08-13 at timestamp slots) — the v310
precedent again. Slots and full names are all distinct; every binding in this repo is by FULL
name.
