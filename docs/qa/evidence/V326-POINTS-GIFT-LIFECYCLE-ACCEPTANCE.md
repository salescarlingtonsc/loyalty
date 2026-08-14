# V326 — gifts get a real third state: On / Off (paused) / Deleted, all immediate-write

Date: 2026-08-15
Branch: `codex/v324-rewards-offer-cosmetics`
Migrations: `20260815_nestly_v326_points_gift_lifecycle.sql` (applied as `20260814180912`),
`20260815_nestly_v326a_gift_rpc_anon_revoke.sql` (applied as `20260814181116`)

Second increment of the owner's 5-photo Points System flow — see
[V324-REMOVE-LIST-DRAFT-BANNER-ACCEPTANCE.md](V324-REMOVE-LIST-DRAFT-BANNER-ACCEPTANCE.md) for the
first (Photo 1) and memory `claim-v324-points-system-page` for the full flow. This increment is
**database only** — the new Points System page (Photo 3), the tile-click rewire, the edit→wizard
step-jump, and the add-gift flow are still queued, deliberately built on top of a verified schema
rather than alongside it.

## What shipped

`loyalty_rewards.paused` (boolean, not null, default false) — a gift can now be On (live), Off
(paused: still exists, still owner-visible, NOT in History), or Deleted (moved to History via
`active=false`, the flag History already read before this migration). All three new RPCs are
immediate-write, bypassing the draft/publish cycle the rest of `loyalty_rewards` goes through,
per the owner's confirmed decision (AskUserQuestion, 2026-08-14):

- `business_set_reward_paused_v326(business, reward, paused)`
- `business_delete_reward_v326(business, reward)` — soft-delete; syncs any currently open draft's
  own `loyalty_reward_versions` row so publishing that unrelated draft later can't resurrect the
  delete (see "the resurrection risk" below).
- `business_create_reward_v326(business, programme, name, points, credit_cents)` — writes both the
  live row and a matching `loyalty_reward_versions` row at the business's *currently published*
  config version, which is what makes a new gift redeemable immediately with no draft/publish step.

All three use the same authorization as `set_programmes_v314` (the v322 R6 switches this same page
reuses) and `publish_loyalty_config`: `app.c45_owner_loyalty_write`. Every write is `audit_log`'d.

## Why this took a full audit before any SQL was written

`loyalty_rewards` is read by five customer/staff-facing functions that gate real redemption. An
immediate write to this table that those functions don't know about would let a paused or deleted
gift stay redeemable — a correctness bug, not a cosmetic one. All twelve functions referencing
`loyalty_rewards.active` were read in full (`pg_get_functiondef`) before any migration was drafted.

**The landmine**: `app.redeem_reward_core` (staff-assisted, in-person redemption) was the one
function that did NOT check `loyalty_rewards.active` for its gate — it gated purely on
`loyalty_reward_versions.active` at the business's active config version. That version row is
protected by `trg_loyalty_reward_versions_immutable`: once its config version's status is
`published`, UPDATE/DELETE on it raises `published reward configuration is immutable`. So an
immediate pause/delete on `loyalty_rewards` could never be mirrored onto that row — meaning,
unpatched, staff could complete an in-person redemption of a gift the owner had just paused or
deleted. Fixed by making `redeem_reward_core` check `v_reward.active`/`.paused` directly (the row
it already loads), independent of the immutable snapshot.

**The resurrection risk**: deleting a gift sets `loyalty_rewards.active=false` directly. If a draft
was already open before the delete, that draft's own `loyalty_reward_versions` row for the reward
still says `active=true` — and `publish_loyalty_config`'s materialization does an unconditional
`active=rv.active` from whatever config version gets published. Publish an unrelated draft later
(a Tier edit in progress, say) and the deleted gift's `active` flag would flip back to `true`,
undoing the delete everywhere. `business_delete_reward_v326` now also writes `false` onto the open
draft's own version row — allowed, since only a *published* version row is immutable.

**Four functions just needed a filter added** (`customer_create_redemption_intent_v89`,
`customer_get_business_actions_v89`, `customer_get_business_presentation_v95`,
`staff_get_customer_actionable_loyalty_v145` — each gained `and not reward.paused`). **Five needed
no change**: `customer_get_home_offers_v167` and `staff_get_customer_entitlements_v102` are
display-only for an already-created intent, never a gate; `app.v177_programmes` and
`business_programme_usage_v271` are owner-facing counts/analytics; `publish_loyalty_config`'s
reward-materialization UPDATE sets an explicit column list that deliberately does not include
`paused` — publishing an unrelated draft must never touch a gift's paused state.

## Verification

16-cell rolled-back transaction against production (`db/tests/v326_points_gift_lifecycle.sql`),
run and iterated to a clean pass before anything was applied — **the migration's own logic needed
zero changes**; every iteration fixed test-fixture plumbing only (a missing `INTO` keyword, RLS
visibility timing against `pg_temp` role resets, a locked-down grant on `redeem_reward_core` that
needed a transaction-scoped `GRANT` to exercise). Cells cover: schema shape; owner-only pause/
delete/create with audit rows; staff (non-owner) refused on all three RPCs; a paused gift excluded
from the staff actionable list and refused by `redeem_reward_core`; un-pausing is fully reversible
end-to-end; the exact `active and not paused` predicate shipped in the three customer-facing
functions; a deleted gift refused by `redeem_reward_core`; the resurrection guard proved by
actually publishing the stale draft afterward and confirming the delete held; `paused` proved
untouched by an unrelated publish; a brand-new gift proved immediately redeemable with no draft or
publish step; input validation on the create RPC.

`get_advisors` caught the three new RPCs as `anon`-executable (default PostgreSQL PUBLIC grant on
function creation) — unlike every comparable owner-only write in this module. The internal
authorization check already blocked a real anonymous caller with 42501, so this was defense in
depth, not an exploitable hole; closed by `revoke execute ... from public` on all seven
`public`-schema functions this migration touches (matches every sibling function's existing grant
shape: `anon_exec=false, auth_exec=true`), plus a small `v326a` follow-up doing the same for the
three new RPCs specifically, since it landed before the revokes were folded into `v326` itself.

Full `npm run validate`: 3049 tests, 3048 pass — the one failure is the pre-existing, environment-
bound `tests/mobile/v131-store-publication-readiness.test.mjs` Capacitor privacy-manifest check,
unrelated to this change.
