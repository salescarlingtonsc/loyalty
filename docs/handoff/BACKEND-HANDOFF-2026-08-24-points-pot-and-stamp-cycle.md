# Backend handoff — 2026-08-24

Two owner-reported defects found while working the visual lane. Both were routed to the
backend / go-live lane by owner ruling (2026-08-24) because both require changing loyalty
calculation or writing server state, which the visual lane is forbidden to touch.

Neither is fixed. Nothing in `nestly_v487` addresses them.

---

## 1. P0 — reward availability and points balance read DIFFERENT programme pots

**Owner's words:** "no points, why show these rewards, please sync!!!"

**Symptom, all three from one bug.** On Cubbly SPA (`8492e8d6-8888-4383-ada0-7e1ed69f0caa`):

- the hero prints `0 points` and `10 more for Free Lotion`;
- the *same screen's* "Your rewards → Available (2)" lists **Free Massage Oil** and
  **Free Lotion** at **5 points**, both badged **Ready to claim**;
- the business page hero therefore offers **Claim reward** / **Redeem now** to a customer
  holding nothing.

**Root cause.** Cubbly SPA has two points programmes, and the two halves of the screen read
different ones:

| programme | reward | cost | read by |
|---|---|---|---|
| `b8fbc7b0-36fe-42c9-aabb-c5d98751baa3` | Free Lotion | 10 | the **balance** / "10 more for…" line |
| `708d5047-bd84-4f2c-a31c-79b4834ce2b9` | Free Lotion | 5 | the **Available list** |
| `708d5047-bd84-4f2c-a31c-79b4834ce2b9` | Free Massage Oil | 5 | the **Available list** |

Query used:

```sql
select r.id, r.customer_name, r.cost_points, r.programme_id, r.active, r.paused
  from public.loyalty_rewards r
 where r.business_id = '8492e8d6-8888-4383-ada0-7e1ed69f0caa'
   and (r.customer_name ilike '%lotion%' or r.customer_name ilike '%massage%');
```

The cost disagreement (10 vs 5) is the tell: a single pot cannot produce both numbers for a
reward of the same name on the same screen.

**Why this matters beyond cosmetics.** `customerRewardCanRedeem` gates purely on the server's
`availability === 'available_at_counter'` — deliberately, per v145/v397, because browser-side
readiness is forbidden. So the client is faithfully reporting what the server said. The server
is authorising a redemption the balance cannot fund. This is a redemption-eligibility defect,
not a display defect.

**Family.** Same class as the pot-scoping work already done in v312, v381 and v460 —
see `points-pot-scoping-unmigrated-readers` and `pot-scope-business-vs-customer-readers`.
Those passes scoped *some* readers. The reward-availability reader appears to have been missed.

**Suggested shape.** Scope the availability computation to the same programme the balance is
read from, then prove it with a rolled-back chain test on production asserting that a
zero-balance customer gets `availability <> 'available_at_counter'` for a costed reward.

---

## 2. A completed stamp card never rolls over on its own

**Owner's words:** "it should auto reset to new stamp card once 15 stamp is hit. and any excess
stamps will flow to new card." (photo 2, the full 15/15 card ringed with "show next card already
/ remove this old card")

**Current behaviour.** `app.stamp_progress_v323` computes:

```
filled = greatest(net_stamps - closed_slots, 0)
```

where `closed_slots = sum(sc.slots) from public.stamp_cycles`. A cycle is only "closed" when a
`stamp_cycles` row exists. **Nothing writes that row when the target is reached.** So a customer
on 17 net stamps against a 15-slot card sits at `filled = 17`, the client clamps the drawing to
15/15 (`shown = min(filled, slots)`) and prints the remainder as
`carried = 2` → "2 already counted toward your next card".

**So the carry-over arithmetic is already right** — `filled = net - closed` means the excess
survives the close automatically. The only missing piece is the close itself.

**Suggested shape.** Insert the `stamp_cycles` row when `net - closed >= stamp_target`, in the
same transaction that earns the stamp. Needs care on:

- **idempotency** — the earn path can retry, and a double close would eat 15 stamps twice;
- **milestone claims** — `stamp_milestone_claims` is keyed by cycle; closing a cycle whose gifts
  have not been claimed must not strand them (the owner's screenshot showed "3 rewards ready" on
  a card about to roll);
- **the v416 config pin** — `app.stamp_cycle_version_v416` resolves the card's config from the
  cycle, so the new cycle must pin correctly or a mid-cycle edit reappears;
- a rolled-back chain test before applying, per the migration rules in `AGENTS.md`.

---

## Related, already shipped (context, not work)

`nestly_v487` removes the per-gift "Last day to redeem" field and clears any stored
`claim_available_until` on save, per owner ruling: gift expiry now comes solely from the Stamp
Card rule ("Rewards expire N days after they are earned"), surfaced to the customer as the
reward sheet's "Use it by" line. That ruling reversed `nestly_v484`, which had briefly shown the
per-gift date.
