# V231 — customer capabilities follow the chosen points mode (2026-08-08)

> **Numbering:** written and applied concurrently with another session's v230, which reached
> `main` first and answered the same owner instruction from the other direction (the tier and
> reward READS carry `points_mode`). This is filed as **v231**; the production ledger records it
> under the name it was applied with, `nestly_v230_customer_sees_the_chosen_points_mode`. The two
> are complementary — v230 makes the reads mode-aware, v231 makes the capability that decides
> whether a redemption surface is mounted at all agree with the v229 gate.

Owner, looking at Cubbly's programme page:

> "instead of showing different points to redeem rewards - it should show the relevant selected
> model. in this case selected tier - it should reflect the different tiers and its benefits"

## What was actually wrong

v229 gave a firm ONE use for points — `businesses.points_mode` is `'redeem'` or `'tiers'` — and
refuses redemption **server-side** in tiers mode:

```
points here count toward membership tiers and cannot be redeemed
```

Cubbly (`kopi-tiam-tyeh`) is on `'tiers'`, verified against production. The customer surface never
learned about that choice, so it kept printing a point-priced catalogue with "Show QR at counter"
buttons. Every one of those buttons led to an RPC that would reject it. Offering a customer an
action that cannot succeed is worse than showing nothing.

The two identical "150 points → A thank-you on your next visits" cards in the owner's screenshot
are **real rows** in the demo tenant (two active duplicates plus one inactive), not a render bug —
the surface was faithfully showing what was configured. Worth tidying in Cubbly, separately.

## What shipped

**Server** — `customer_portal_capabilities` answers the question the customer surface was already
asking, so no new round trip:

| key | behaviour |
| --- | --- |
| `rewards` | now **false** in tiers mode, so the capability agrees with the redemption gate and a stale wallet cannot render a button the server refuses |
| `tiers` | new — true when this firm's points buy membership **and** it has published tiers under an active programme |
| `points_mode` | new — the choice itself, reported verbatim including null |

Every other key is unchanged in shape and meaning.

**Customer** — the programme panel is built from the choice:

- **tiers** — one panel: the balance stated as *points earned*, "your points count toward
  membership here — they are not spent", where you stand, and every tier with its benefits.
  No catalogue, no redeem button, no tab leading to one.
- **redeem** — one panel: the balance, progress to the next reward, and the rewards it buys.
  No tier ladder for a firm that does not run tiers.
- **unchosen** — both tabs, exactly as before, because nothing has been put away yet.

Also fixed while in here: the panel printed "…is ready to redeem." twice, once itself and once
through the reward-progress markup.

## Evidence

`v231-points-mode-panels.png` — all three shapes rendered from the **production functions and
production CSS**, captured through the Chrome DevTools Protocol against installed Chrome.

## Verification

The rollback suite (`db/tests/v231_capabilities_follow_the_points_mode.sql`) ran against
production inside a transaction that was rolled back, driving the **real tenants** rather than a
synthetic one — a business conjured inside a transaction reports no effective modules at all
(entitlements are resolved by the platform policy) and every capability reads false, which would
have proven nothing. It asserts:

- Cubbly in tiers mode → `rewards=false`, `tiers=true`, `points_mode='tiers'`;
- the same firm flipped to redeem → `tiers=false`, `rewards=true`, and every unrelated key
  (wallet, bookings, activity, appointments, packages, membership) byte-identical across the flip;
- unchosen → both on, i.e. this migration changes nothing it was not asked to;
- Hougang ABC — three tiers configured, no ACTIVE programme — → `tiers=false`, so no customer is
  sent to an empty ladder;
- anon still cannot call it.

Post-run check confirmed Cubbly is still `'tiers'` and Hougang ABC still `'redeem'`: nothing
committed.

JS suite: 2058 tests, 13 failures — identical to this branch's pre-existing baseline.
