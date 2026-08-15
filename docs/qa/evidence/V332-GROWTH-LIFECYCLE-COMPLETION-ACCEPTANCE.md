# V332 — Growth lifecycle completion: Stamp card, Memberships, Tiered membership, Lifestyle bring-back

Date: 2026-08-15
Branch: `codex/v324-rewards-offer-cosmetics`
Production-component source hash: `db7d2245bbef0af67708d5e0b15ac580af5d3c271013fa8715614c82e854dd60`

Owner instruction: "proceed all at once" — build all four remaining queued Growth lifecycle
pages (Tiered membership, Stamp card, Memberships, Lifestyle bring-back rules) in one continuous
push, matching the same Published/History delete-to-History treatment already shipped for gifts
in [V326-POINTS-SYSTEM-PAGE-ACCEPTANCE.md](V326-POINTS-SYSTEM-PAGE-ACCEPTANCE.md). This file is
the batched close-out for the whole arc — one evidence doc rather than one per increment, since
every increment regenerates the same `reward-overview-owner-visual.html` fixture and only the
LAST regeneration's hash is ever live.

## What shipped, across four commits

1. **Stamp card** (commit `57772fa`, "unify Points System page as the Stamp card destination
   too"). Points and stamps are mutually exclusive live models (R2), so rather than a second
   near-duplicate page, `#/grow/points` became fully model-aware: scopes its gift list to the live
   model's spine `programme_id`; swaps "Points System"/"Stamp card" copy and "point"/"stamps" unit
   wording; the summary row's on/off switch and Edit link target whichever spine kind is actually
   live. Caught and fixed a real routing bug in passing: the wizard's Edit-link hand-off only ever
   checked for a step literally named `'earn'`, which does not exist on a stamps-only rail (it is
   `'stampEarn'`) — Edit from a stamps business would have silently landed on the Programmes screen
   instead of the earning-rate step.
2. **Memberships** (commit `ff53f2a`, "add Memberships delete-to-History lifecycle"). Adds
   `business_delete_membership_plan_v329` and `membership_plans.deleted_at`. Audit found a
   materially simpler landmine than gifts: `membership_plans` has no draft/publish layer at all
   (`save_membership_plan` already writes the live row directly), and only two functions gate on
   `active` (`enroll_membership`, and the daily `app.run_membership_renewals` cron) — both already
   correct once delete sets `active=false`, so neither needed to change.
3. **Tiered membership** (this segment, `db/migrations/20260815_nestly_v331_tier_lifecycle.sql`).
   Unlike Stamp card and Memberships, the owner's own AskUserQuestion answer for Tiers was a
   **full parallel immediate-write page**, not a read-only view over the existing draft/publish
   tier editor — a tier ladder is a genuinely different shape (an ordered list of rungs with
   implicit rank, not independent siblings) from gifts or plans. Adds `loyalty_tiers.paused` and
   `loyalty_tiers.deleted_at`, three RPCs (`business_create_tier_v331`,
   `business_set_tier_paused_v331`, `business_delete_tier_v331`), and a novel capture/restore patch
   inside `publish_loyalty_config` (array_agg/unnest around its pre-existing delete+reinsert tier
   mechanism) so an immediate-write pause/delete survives **every future publish**, not just one
   pre-existing draft. Discovered and fixed, in passing, a real pre-existing production bug found
   while auditing every reader of `loyalty_tiers`: the Overview tile's tier query selected a column
   named `active` that has **never existed** on `loyalty_tiers` — PostgREST returns an error (not a
   throw) for an unknown column, which `r.error?null:(r.data||[])` silently converted to `null`, so
   the "Tiered membership" tile has shown "Tier details could not be loaded" for every tenant with
   a live tier programme, in production, indefinitely. Fixed by selecting `paused,deleted_at`
   instead. 16/16 new tests (`tests/business-ui/v331-tier-lifecycle.test.mjs`); 20/20 PASS on a
   rolled-back verification transaction against production (`db/tests/v331_tier_lifecycle.sql`),
   independently re-verified twice more (once after a version-number rename forced by a parallel
   session claiming v330, once as a final pre-apply check) before being applied.
4. **Lifestyle bring-back rules** (this segment,
   `db/migrations/20260815_nestly_v332_retention_program_lifecycle.sql`). Overrides the V291
   ruling recorded inline in `retentionPage()` — *"There is deliberately still NO delete: a
   published rule with grant history cannot be unmade without rewriting what customers were given,
   so pausing is the honest ending"* — per explicit owner instruction to add a real delete this
   time. The audit found a landmine materially harder than either the Memberships or Tiers case:
   `retention_program_versions` carries `trg_guard_retention_program_version`, a trigger that
   blocks INSERT **and** UPDATE **and** DELETE the moment a row's `config_version_id` points at a
   non-draft `firm_config_versions` row — stricter than `loyalty_tier_versions`' own trigger (which
   only blocks UPDATE/DELETE, not INSERT). This means a published snapshot row's `active` flag can
   **never** be forced false directly, by any writer, including a SECURITY DEFINER delete RPC. Since
   `app.on_sale_recorded()` (the trigger that actually grants retention rewards on every qualifying
   sale) reads only that frozen published snapshot, the fix could not be "patch the snapshot" — it
   had to be "patch `on_sale_recorded` and `public.issue_campaign_offer` to also require the LIVE
   `retention_programs.deleted_at is null`", with `public.publish_loyalty_config`'s pre-existing
   retention sync UPDATE patched as the durable resurrection guard (`active = rv.active and
   rp.deleted_at is null` — permanent because `deleted_at` is never one of that UPDATE's own target
   columns, so it can't be reset by any future publish). Two more functions
   (`app.clone_retention_program_versions_on_draft`, `public.save_reward_taxonomy`) and two
   defense-in-depth resurrection guards (`public.ensure_published_retention_in_draft_v138`,
   `public.save_retention_program_draft`) were patched alongside the new
   `business_delete_retention_program_v332` RPC. A second, independent bug was caught while wiring
   the UI: the live-programs read filtered `.eq('current_config_version_id', currentVersion)` —
   correct before this migration (every existing program was always carried forward by the clone
   trigger on every publish), but now a deleted program is deliberately never re-cloned, so its
   `current_config_version_id` goes stale the next time an unrelated draft publishes, and the plain
   `.eq()` filter would have silently dropped it out of History. Fixed with
   `.or('current_config_version_id.eq.<id>,deleted_at.not.is.null')`, verified against the live
   PostgREST endpoint (200, not a 400 filter-parse error) before shipping. 13/13 new tests
   (`tests/business-ui/v332-retention-program-lifecycle.test.mjs`); 20/20 PASS on a rolled-back
   verification transaction against production (`db/tests/v332_retention_program_lifecycle.sql`),
   independently re-verified by re-reading the entire migration end-to-end and re-confirming the
   core `trg_guard_retention_program_version` claim directly against `pg_trigger`/
   `pg_get_functiondef` before applying.

## Cross-cutting design decisions this arc established or reused

- **Points/stamps and tiers each get their own page**, not a shared one: `#/grow/points` (model-
  aware for the mutually-exclusive points/stamps pair) and `#/grow/tiers` (its own page, since a
  ladder's shape doesn't fit the points page's independent-siblings list). Both fully replace the
  wizard as the tile's destination; `growSetupEntryV301`'s wizard-entry branch in the tile click
  handler is now provably dead for all three of its possible keys and was removed (its helper,
  `growSetupKindForTileW6I2`, is left defined but unused — its only remaining call sites are inside
  each page's own Setup/Edit controls, not the tile).
- **Memberships and Bring-back rules keep their pre-existing pages** (`membershipsPage()`,
  `retentionPage()`) and gain delete-to-History as an addition, not a rebuild — Memberships had no
  draft/publish layer to begin with, and Bring-back rules' existing draft/publish editor and its
  V291 immediate-toggle-via-draft mechanism are both left completely intact; only a new, separate
  delete axis was added on top.
- **`paused`/`deleted_at` as two independent axes**, never conflated into one flag: matches the
  house convention from v176 (reward tier gate) and v278 (bar bottle-keep) of never using a real FK
  on a row that a delete/publish cycle might remove, using a soft reference + a frozen fallback
  value captured at write time instead.
- **Every delete is confirm-gated, immediate-write, and provably never touches history**: no
  `reward_grants`, `credit_ledger`, `points_ledger`, or already-issued campaign row is ever mutated
  by any of the four deletes shipped this arc — verified per-migration in the rolled-back test
  suites, not merely asserted.

## Verification

- `node --check app/app.js` clean throughout every increment.
- Every DB migration verified via a rolled-back transaction against production
  (`begin; ... rollback;`) before being applied for real — v331's suite re-run three times
  (mid-flight version rename, agent-delegated fixture debugging, final pre-apply confirmation);
  v332's suite independently re-verified by re-deriving its core architectural claim
  (`trg_guard_retention_program_version`'s BEFORE INSERT OR DELETE OR UPDATE scope) directly from
  `pg_trigger`/`pg_get_functiondef`, not merely trusted from a delegated audit's report.
- `docs/design/ps0/writer-registry.json` updated for all seven new RPCs
  (`business_set_tier_paused_v331`, `business_delete_tier_v331`, `business_create_tier_v331`,
  `business_delete_retention_program_v332`) plus the two pre-existing writer entries whose
  defining migration changed (`app.on_sale_recorded`, `public.issue_campaign_offer`), confirmed
  against the registry's own discovery test (`tests/program-studio/ps0-writer-registry.test.mjs`,
  11/11 PASS).
- Every allow-list this arc's new routes needed to join (`programmeView`, `hashParamIsProgrammeView`,
  `growCategoryViewV271`'s exclusion list) updated at all three sites, matching the exact pattern
  already established for `'points'` — and every pre-existing test that pinned the OLD (pre-Tiers-
  page) tile-click/wizard-hand-off behaviour updated in place, with the supersession recorded
  inline, not deleted.
- Full `npm run validate`: 3109 tests, 3107 pass. The two failures are both pre-existing,
  environment-bound exceptions unrelated to this arc: `tests/mobile/v131-store-publication-
  readiness.test.mjs`'s Capacitor privacy-manifest check, and a mobile-card-swipe issue on V104
  tracked separately.
