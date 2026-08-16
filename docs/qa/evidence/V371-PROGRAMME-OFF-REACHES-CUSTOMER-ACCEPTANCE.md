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

## Regenerated browser evidence

The recent rewards wave changed production source without recapturing the fixtures that pin it, so
these were regenerated from current source. New `production-source-sha256` pins:

- `tests/browser/reward-overview-owner-visual.html` → `084d6f5ed5bade0d91a515bed26794ebf61017ee59fdfa1b1e8eaf936d349974`
- `tests/browser/v129-trial-test-visual.html` → `4d0d2a7ab4d560913b1b18c566887b527bb974bca4394d269ebb416a6ed5c74f`
- `tests/browser/v130-self-serve-visual.html` → `e55c2827b007395c8d021a5d01b86b4fe0252aa9191e7685d6dd19c7513a85ad`
- `tests/browser/v131-store-visual.html` → `2e9725fdd00d97023ccc3441d15fe6011f454f3aa188c55bf5c45ebc5c668955`
- `tests/browser/v141-dashboard-visual.html` → `330ccf3060e15a2292bde1f76800d94c93bc864e7596451355a588d10d9d5f0b`
- `tests/browser/v145-launch-freeze-visual.html` → `9866473ed843b99e9b9200dc929706465d3e93c6e8b02bafd7f361e1e258c1bd`

The v141/v145 generators sliced production source at the marker
`async function visibleBranchesForCurrentUser()`; v370 gave that function a `{refresh}` option and
the capture broke. They now slice from the signature prefix, so a future parameter change cannot
break it the same way.

## Migration ledger

`supabase_migrations.schema_migrations` still ends at `nestly_v332`. Everything from v343 onward —
the whole 2026-08-16/17 rewards wave, now including v371 — has been applied by direct SQL without a
ledger row, because writes to that table are refused by the Claude Code auto-mode classifier. The
repo plans and manifests are the accurate record; the database ledger is not.
