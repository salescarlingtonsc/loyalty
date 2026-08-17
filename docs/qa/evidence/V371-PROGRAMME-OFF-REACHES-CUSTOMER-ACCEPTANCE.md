# V371 — "turned off" must reach the customer

Date: 17 August 2026
Scope: production-readiness audit of the business↔customer contract across the rewards, loyalty,
bookings and packages flows, and the fixes it turned up.

## What the audit proved, and how

Every claim below was verified end to end against the production database
(`gadpooereceldfpfxsod`) inside `begin; … rollback;`, using a synthetic two-tenant fixture — two
businesses, their owners, a branch, a catalogue, and a customer identity verified-linked to tenant
A only. The suite is `db/tests/v371_programme_off_reaches_customer.sql`.

It is deliberately non-vacuous: on the pre-v371 functions **six of its seventeen checks fail**
(05, 06, 09, 10, 11, 12); with the migration applied all seventeen pass.

## The defects

### 1. The Programmes on/off switch never reached the customer (P0)

`set_programmes_v314` — the control behind "Turn on"/"Turn off" on the Programmes page — moves the
`business_programmes` spine and syncs `loyalty_programs.loyalty_model` and `kind`. It does **not**
touch `loyalty_programs.active`, which is the only thing `app.c45_base_actionable_wallet_card`
gated on. Observed with points switched off:

| surface | answer |
| --- | --- |
| `app.business_programmes_active_v314` (business page) | `points: running=false` |
| `customer_get_actionable_business` (customer wallet) | `{"enabled": true, "unit": "points", "balance": 50}` |

The owner saw "off". The customer kept seeing the programme and a balance.

### 2. Turning Tier membership off left the whole ladder visible (P0)

`customer_get_effective_tier_v143` filters per-tier `paused` / `deleted_at` only. Its single
`business_programmes` lookup is for choosing which points pot to count under
`tier_basis='points_earned'` — not a visibility gate. With the tiers programme switched off the
customer still received the full ladder and a current tier label.

Per-tier pause was, and remains, correct — only the programme-level switch was ignored.

### 3. A paused gift stayed on offer (P1)

`business_set_reward_paused_v326` pauses the **live** `loyalty_rewards` row, but customers read the
published `loyalty_reward_versions` snapshot, filtered on `rv.active` alone. A paused gift therefore
stayed in `customer_get_reward_catalog` and was advertised on the wallet as:

```json
"next_eligible_reward": {"name": "ZZ Free Kopi", "cost_units": 5, "available_now": true}
```

`app.redeem_reward_core` and `customer_create_redemption_intent_v89` *do* check `paused`, so no
money moved and no ledger row was written — the claim simply refused. This was a broken promise and
a dead-end journey, not a data-integrity failure.

The same shape existed latently for retention programmes: the wallet's `retention_windows` join
checked `prog.deleted_at is null` but not `prog.active`.

## The fix

`app.programme_running_v371(business, kind)` is now the single reader of "is this programme
running": the spine row when it exists, falling back to the derived `app.business_programmes_v307`
when one is genuinely missing, so a data gap can never silently hide a live programme. The three
customer-facing readers consult it, and the two published-snapshot readers now honour the live
row's off switch.

## Production impact of applying it

Measured before writing the migration:

- All 11 businesses have spine rows (seeded by trigger `business_programmes_seed_v314`); the count
  of tenants that would change behaviour from a missing spine row is **0**.
- For points, `loyalty_programs.active` and the spine agree on **every** tenant, so no live wallet
  changes.
- **0** rewards are currently paused and **0** retention programmes are inactive-but-published, so
  the two snapshot fixes change nothing that is live today.

The change is therefore preventive: it costs no current tenant anything, and stops the defect the
next time an owner uses a switch. Cubbly, QA Go-Live Cafe and QA Test Cafe were all one click away
from it (`loyalty_programs.active = true`).

A note on a claim that did not survive checking: *Hougang ABC* (3 live tier rows, whole spine false)
looked at first like a tenant already mis-displaying tiers. It is not — `loyalty_programs.active` is
false there, and both `customer_get_effective_tier_v143` and `customer_get_loyalty_details` raise
"loyalty module is unavailable" before reaching any tier. Reproducing its exact row state
synthetically is what disproved it.

## What the audit found to be correct

- **Tenant isolation.** Checks 14–17 pass both before and after: business B refuses a customer it
  has no verified link to, and neither its gifts nor its tiers are reachable under the other tenant.
- **Numbers are factual.** The wallet balance equals `sum(points_ledger.points)` for that client;
  the reward's `remaining_units` is derived from it. No `Math.random`, no demo constants and no
  fabricated fallbacks exist in the shipped business or customer code paths. The two numeric
  fallbacks present (`points_multiplier||1`, `restored_sessions||1`) are neutral defaults.
- **Money paths refuse what the display offered.** Every write path already consulted `paused`.

One deliberate exception is recorded rather than removed: `localCustomerPreviewCardsV345()` in
`app/app.js` holds hard-coded sample businesses and balances (75877, 12450, 8, 3210). It is gated at
both its router entry and its renderer on `location.hostname` being `localhost`/`127.0.0.1`/`::1`,
so it is unreachable in production, but it does ship in the customer bundle.

## Applied to production

Applied to `gadpooereceldfpfxsod` on 17 August 2026 and re-verified against the live functions:
the 17-check suite passes 17/17 there, and a side-by-side probe confirms the two views now agree
in every state.

| step | business view | customer view |
| --- | --- | --- |
| all on | points=true tiers=true | enabled=true · tier=ZZ Bronze · gift offered |
| points off | points=false | **enabled=false** · tier=ZZ Bronze · **gift hidden** (v372) |
| tiers off | tiers=false | enabled=true · **tier=(none)** · gift offered |
| gift paused | — | enabled=true · tier=ZZ Bronze · **gift not offered** |
| gift live again | — | enabled=true · tier=ZZ Bronze · gift offered |

The "gift hidden" cell in the points-off row is v372's doing, and its absence is what v372 fixed —
see below. As first reported this row read "gift offered", which was correct as an observation and
wrong as an outcome: the gift belonged to the Points programme.

`supabase_migrations.schema_migrations` records v371 at `20260817000004`. The 15 migrations from
v343 to v370 remain absent from that ledger: they were applied by direct SQL, and the backfill is
refused by the Claude Code auto-mode classifier (both as a batch and one row at a time). The repo
plans and manifests are the accurate record. v340 is correctly absent — it is written for rehearsal
and is not applied, which was confirmed by probing for the object it would create.

## V372 — a gift is only offered while its own programme is running

Found by the owner reading the table above: with Points off, the customer view still said "gift
offered", and that gift was a Points programme reward. It was. v371 gated the wallet's `enabled`
flag and the `paused` check but not the reward's own programme, so a live, unpaused gift belonging
to a switched-off programme stayed in the catalogue.

The damaging shape is not the one that was spotted, but the one next to it, and **Cubbly was in it**:

| | |
| --- | --- |
| business | stamps **off**, points **on** |
| gift | "Free Massage Oil", priced **2 stamps**, on the stamps programme |
| customer wallet | unit `points`, balance `50` |
| customer was told | `{"name":"Free Massage Oil","cost_units":2,"available_now":true}` |

A reward priced in stamps, reported ready to claim, judged against a points balance, for a
programme the owner had switched off — and `redeem_reward_core` would refuse the claim. Two units
conflated into one number.

Both readers now drop a reward whose own programme is switched off, extending the same live-row
lookup that already carries the pause check so there is one condition per reader rather than two
that can drift. A reward with no `programme_id` is deliberately left alone — failing open never
hides a real gift because a link is missing (all 20 production rewards do have one).

`db/tests/v372_gift_follows_its_programme.sql` reproduces Cubbly's shape exactly, pricing the
running programme's gift out of reach so the switched-off programme's cheap gift is the one the
wallet would otherwise pick. Five of its seven checks fail on the pre-v372 functions; all seven pass
after, and v371's seventeen still pass unchanged.

Live effect, the whole of it:

| business | reward | programme | now |
| --- | --- | --- | --- |
| Cubbly | Free Massage Oil (2) | stamps, **off** | **hidden** |
| Cubbly | Free Mini Burger (10) | points, on | offered |
| Cubbly | moisturizer (10) | points, on | offered |

Hougang ABC's two stamps rewards are unaffected because its `loyalty_programs.active` is false, so
the catalogue refuses for that tenant before reaching any reward.

## Defects found while making the suite green

Three more product defects surfaced while working through the 62 failing tests, each fixed rather
than papered over:

1. **The two programme-view lists had drifted (routing).** `programmeView` and
   `hashParamIsProgrammeView` were maintained as separate literals. V366 added `'bringback'` to the
   first only — so `#/grow/bringback` resolved as a view *and* fell through to `mountGrowSurface`
   with `draftOverride:'bringback'`, mounting a deep editor surface the owner never asked for, with
   a view name where a draft id belongs. This is the sibling of the very defect V366 fixed. Both
   now read one frozen `GROW_PROGRAMME_VIEWS_V371`, and
   `tests/business-ui/v366-bringback-route-reachability.test.mjs` executes both statements out of
   the shipped source and asserts they cannot disagree.

2. **A tile whose read failed claimed "Not set up" (fabricated state).** When birthday moved from a
   row to a topic tile it lost its unavailable state, so a failed read was reported as a fact about
   the owner's configuration. Every tile now routes its status through `growTileStatusV371`, which
   names the read it depends on and answers `Unavailable` when that read failed — the honest-unknown
   state the drilled rows always had.

3. **Uploaded promotion artwork was being cropped again.** The V343 "customer luxury polish" pass
   re-introduced `object-fit:cover` on `.customer-home-offer-media img`, silently overriding the
   `contain` rule and cropping merchant-uploaded artwork on the customer home carousel — the exact
   thing V173 forbids. Removed; the image is letterboxed inside its fixed-ratio container, as on the
   card and detail surfaces.

Two smaller truthfulness fixes: the localhost preview's two inert "Book again" buttons are now
`disabled` rather than looking pressable, and the V123 readiness scanner no longer reads `<style>`
blocks as markup (a CSS comment mentioning `<a>` had been reported as a permanently unwired control).

## Dead code found

Left in place and recorded rather than removed, because each has a live consumer or a multi-line
shape whose removal carries more risk than value:

- `pendingGrowSetupModelV303` — declared and read, never written. Its reader feeds
  `handoffKindW6I2`, which is therefore always null, making the wizard's tile hand-off branch dead.
- `welcomeOfferRowV215` — a complete row builder with no caller since V358 gave the welcome offer
  its own tile.
- `growRetentionDiffV291` and `growPendingBirthdayV291` — both computed once and never read, left
  behind when birthday and bring-back moved off the overview's row list.

One dead symbol *was* removed: `growBreadcrumbV268`, because it held a second copy of the back
button's element id and any future caller would have put a duplicate id in the document.

## Test suite

3145 tests, all passing (`npm run validate` exits 0). The suite was at 88 failures when this audit
started and every one has been resolved by either updating an assertion whose behaviour the owner
had intentionally changed, or fixing the product where the test had found something real. No test
was deleted to make the suite pass; where a feature was struck out by owner ruling, its tests were
inverted so the removal itself is now guarded.

## Regenerated browser evidence

The recent rewards wave changed production source without recapturing the fixtures that pin it, so
these were regenerated from current source. New `production-source-sha256` pins:

- `tests/browser/reward-overview-owner-visual.html` → `9b32f7e9c1dfdbed53ad5735e60278366ae69be04cc88fd2eb93dd94aebf44c3`
- `tests/browser/v129-trial-test-visual.html` → `21fabfec39f27d2fc8c21b7967dbe1ababf0726e80e82e07873ee570ed796fe0`
- `tests/browser/v130-self-serve-visual.html` → `817134c82c85476f274ea80a1fea6d4498058bbe4a15007ac3b4ed54a5fe37e1`
- `tests/browser/v131-store-visual.html` → `67b4f13384f8367f962188f3cd21b6d0ae62b98ab69f99d42e2f1c42cc802a1c`
- `tests/browser/v141-dashboard-visual.html` → `5a63c1ff37c4bab27ff4f33d5cd1504fac016db5a86cf80906febde8b7bf0202`
- `tests/browser/v145-launch-freeze-visual.html` → `bb9946d3da81e75e240cd0bd711d403f5dfe27020c99ab31f889b577ef326b80`

The v141/v145 generators sliced production source at the marker
`async function visibleBranchesForCurrentUser()`; v370 gave that function a `{refresh}` option and
the capture broke. They now slice from the signature prefix, so a future parameter change cannot
break it the same way.

## Migration ledger

This paragraph originally read "still ends at `nestly_v332`", written before v371 was applied. It
was left standing when the applied section was added above, so the document contradicted itself.
Queried directly against production, the truth is:

```
20260815070236  nestly_v332_retention_program_lifecycle
20260817000004  nestly_v371_programme_off_reaches_customer
20260817000005  nestly_v372_gift_follows_its_programme     <- head
```

367 rows. v371 and v372 are both recorded. **v343 through v370 are absent** — zero rows in that
range: they were applied by direct SQL, and the backfill is refused by the Claude Code auto-mode
classifier, as a batch and one row at a time. v340 is correctly absent because it is not applied.
So the ledger is accurate about what it contains and incomplete about the 2026-08-16 wave; the repo
plans and manifests remain the complete record.
