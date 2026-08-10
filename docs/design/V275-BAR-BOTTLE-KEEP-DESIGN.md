# V275 — Bars sector: bottle keep, integrated with rewards and spending tiers

Owner brief (2026-08-11): a new **Bars** sector where the business tracks customers' leftover
bottles in the app; it integrates with the existing rewards; VIP feel comes from **tiers based on
spending**; the customer sees their bottle details inside the business's page in the customer
app. Reference product: bottlebank.io.

## 1. What the reference product actually does (researched 2026-08-11)

From bottlebank.io and the owner's walkthrough screenshots:

- **Park a bottle**: staff registers customer + bottle in ~30s; serial auto-assigned
  (`BB-2026-0005 · 700ml`); optional storage location; **re-entry limit** ("how many people can
  use this bottle for re-entry" — default 1 / disabled / N pax); notification preference per
  park.
- **Fill level**: preset buttons 100/75/50/25/Empty plus a draggable marker on a bottle
  illustration (e.g. 45%).
- **Lifecycle**: statuses on the floor — *active, called, at table*; then retrieved / expired /
  repurposed. Expiry ~30 days with **Extend** and **Transfer** actions.
- **Notifications**: WhatsApp reminder before expiry (SGD 0.05/message beyond quota), email
  fallback, one-tap per customer. "One reminder typically triggers return visits" — the expiry
  reminder IS their retention engine.
- **Customer side**: a branded, no-app status page listing bottles with fill %, parked date,
  re-entry, days left, Extend/Transfer.
- **Pricing**: S$148/mo (30 bottles), S$288/mo (100 bottles), bottle-count add-ons.
- **Not in their product**: any points/rewards engine, tiers, spend tracking, or POS/sale link.
  Bottle keep is their whole product; for Peekaa it is one module inside an ecosystem that
  already has the retention machinery they lack. That is the wedge: *"your bottle keep should
  earn your customers points and build their tier — not live in a separate app."*

## 2. What Peekaa already has (verified in code, nothing here is aspirational)

| Need | Existing machinery |
|---|---|
| Spending-based VIP tiers | `loyalty_tiers` + `tier_basis='spend'` — `app.loyalty_tier_for` already sums `counts_as_revenue` sales. Buying a bottle is a sale, so tiers move with zero new plumbing. Tier perks render on the customer card today. |
| Earn on bottle purchase | v10 `sale_policies`: add `sales.kind='bottle_keep'` with policy defaults (revenue=true, visit=true, earns_points=true). The trigger engine asks the policy — no new earn path. |
| "Consume over visits" shape | Packages: sell → `client_packages` → `use_package_session` ($0 service sale per use). Bottle keep is the same shape with fill % instead of session count. |
| Expiry notifications | `customer_in_app_inbox_events` (+`deadline_at`), push topic `value_expiry` already in the SW allowlist, daily pg_cron sweeps already run (points expiry, renewals). A bottle sweep is one more cron. WhatsApp = deferred per CLAUDE.md; v263 consent matrix already has the channel switch waiting. |
| Customer sees bottles under the business | `#/wallet/<slug>` per-business wallet page — add a "Your bottles" card. Same place points/rewards/promotions already render. |
| Sector wiring | `businesses.industry` drives modules (v246 hides Appointments for `fnb`; v235 gates seating). `'bar'` string already appears in the app's sector options — needs a module map + recommender entry (v75/v128 sector CASE lists don't know it yet → falls to 'classic'). |
| Idempotent staff writes, RBAC, branch scope, append-only audit | House patterns everywhere (idem keys, `app.has_perm`, branch_id triggers, append-only guards). |

## 3. Design

### 3.1 Data (all new tables RLS deny-by-default + RPC-only, house style)

- `bar_bottles` — one physical parked bottle. `id`, `business_id`, `branch_id`, `client_id`,
  `serial` (per-business sequence, rendered `PK-2026-0001`), `label` (free text or FK →
  `products.id` when the bottle was sold from the catalogue), `size_ml`, `fill_percent int`
  (0–100), `storage_location text`, `reentry_limit int null` (null = disabled),
  `status` ∈ `stored | called | at_table | finished | expired | transferred | removed`,
  `parked_at`, `expires_at`, `sale_id null` (the purchase that parked it), timestamps.
- `bar_bottle_events` — **append-only** audit: park, fill change (old→new), call, serve,
  return-to-storage, extend (old→new expiry), transfer (old→new client), finish, expire,
  reminder-sent. Every dispute ("my bottle was fuller than that") is answered here; this is the
  same discipline as the credit ledger and is non-negotiable for a product storing customers'
  property.
- No value ledger entry: a bottle is **property, not stored value**. It never touches
  points/credit ledgers directly; only its *purchase sale* does, via the normal engine.

### 3.2 RPCs (SECURITY DEFINER, explicit grants, staff-side gated on a new `bottles` module perm)

`park_bottle` (idem key; optional `p_sale_id` to link the purchase; creating the sale stays the
till's job), `set_bottle_fill`, `set_bottle_status` (called/at_table/back to stored),
`extend_bottle` (new expiry + reason), `transfer_bottle` (to another client of the same
business; event records both parties), `finish_bottle`, `list_bar_bottles` (branch-scoped,
filters: status/customer/expiring-soon). Customer side: extend `customer_get_wallet` (or a
`customer_get_bottles_v275`) returning the customer's own bottles for that business only.

### 3.3 Tier integration — the part the owner cares about

- Bottle purchase = normal sale ⇒ earns points AND moves the spend tier. Nothing to build
  beyond the `bottle_keep` sale kind + policy row.
- **Tier perks that are about bottles** (the VIP feel): per-tier `bottle_keep_days` override —
  e.g. Base 30 days, Gold 60, Platinum 90 — resolved at park time from the customer's current
  tier and shown on the customer card ("Gold keeps bottles 60 days"). One nullable column on
  `loyalty_tiers` + the resolution in `park_bottle`. Optional later: tier-gated re-entry
  defaults.
- Expiry reminder = retention moment: inbox event + push (`value_expiry` topic, so the v263
  consent matrix already governs it). Copy invites the visit, not just the deadline.

### 3.4 Sector wiring

`industry='bar'` → modules: till/sales, **bottles**, bookings+waitlist (+seating), programmes,
customers, insights; Appointments hidden like `fnb`. Add `'bar'` to the v75/v128 sector CASE
(recommend `points_tiers` with `tier_basis='spend'` — the owner's stated model for bars) and to
the sector option copy. Guided setup step: "Park your first bottle".

### 3.5 Staff UI (business app)

New **Bottles** page in Serve & sell: list with search, status pills (Stored n / Called n / At
table n), fill bar, days-left, expiring-soon filter; Park dialog mirroring the reference
(customer search-or-add — `lookup_client_by_phone` exists; bottle from catalogue or free text;
storage location; re-entry; expiry preview showing the tier-derived keep window); bottle detail
with fill selector (presets 100/75/50/25/Empty + slider), Call → At table → Back to storage,
Extend, Transfer, Finish, and the full event history. Low-literacy rules apply: pictogram
statuses, big targets, numbers over words.

### 3.6 Customer app

Inside the business's wallet page: **"Your bottles"** — label, serial, fill bar, parked date,
days left (SGT), re-entry, storage note if shared; expiring state highlighted. Read-only in
increment 1 (Extend/Transfer are staff actions at the venue; a customer "request extension"
button can ride the existing booking-request/notification rails later).

### 3.7 Deliberately NOT in increment 1

WhatsApp sending (deferred platform-wide; consent switches already exist), per-bottle photos,
bottle marketplace/repurposing, POS integration, customer self-service extend/transfer, pricing
changes (bottle keep ships inside the existing subscription — undercuts bottlebank's S$148/mo
*for bottle keep alone* at Peekaa's S$148/mo *for the whole platform*; a per-bottle cap can come
later via the platform console if the owner wants one).

## 4. Build plan (each step = migration + rolled-back prod verification + tests + UI + live check)

1. **V275a** schema + RPCs + `bottle_keep` sale kind/policy + `'bar'` sector wiring + events.
2. **V275b** staff Bottles page + Park/detail dialogs + module perm + guided-setup step.
3. **V275c** customer wallet "Your bottles" + expiry sweep cron + inbox/push reminder + tier
   `bottle_keep_days` + landing-page "Bars" category copy update.

Estimated as three ship-sized increments, same cadence as v263/v271.
