# Frenly — UX Simplification Plan (low-literacy-first)

Front-line users are often WPass/SPass staff (TH/VN/MM/CN) with limited English. Design goal:
**anyone can run the front desk on day one without reading.** Owner-only depth stays, but is
tucked behind groups. Grounded in `app/index.html` (`MODULES`, `INDUSTRIES`, `renderShell`,
hash routing, `enabled_modules`). Non-destructive: nav becomes grouped, pages get wizards.

## 1. Grouped navigation IA

15 flat items → 5 collapsible workday groups. Group renders as a header row (emoji + label +
chevron); click toggles its children. Active child expands its parent. Missing modules
(per `enabled_modules`) are skipped; a group with zero enabled children is hidden entirely.

| Emoji | Label (≤2 words) | Member modules | Opens by default |
|---|---|---|---|
| 🏠 | Today | Dashboard, Appointments, Waitlist, Bookings | Dashboard |
| 👥 | Customers | Customers, Sales | Customers |
| 🎁 | Come Back | Loyalty, Retention, Referrals, Memberships, Gift cards | Loyalty |
| 📦 | Stock | Services, Inventory, Packages | Inventory |
| ⚙️ | Setup | Reports, Settings | Reports |

**Role-based default collapse** (from `staff.role`): **frontline** (staff/cashier) sees only
🏠 Today + 👥 Customers expanded, all else collapsed, and lands on a giant "Customer visit"
button (wizard 4a) — not the analytics dashboard. **manager** sees 🏠/👥/🎁 expanded.
**owner/admin** sees all expanded. Collapse state persists per-user in `localStorage`
(`frenly_nav_${userId}`); role sets the first-run default only.

## 2. Per-module improvements

| Module | Efficiency | Ease-of-use | Visual |
|---|---|---|---|
| Dashboard | Role-aware: frontline gets one "Start visit" tile, not charts | 3 KPIs max above fold, rest on scroll | Big numerals, sparkline not axis-heavy charts |
| Customers | Search-by-last-4-digits phone; recent-first list | Tap row → visit wizard, no edit form first | Avatar/initial circle + phone, name secondary |
| Appointments | One-tap "Done" → fires sale; today defaults to Today tab | Week view already exists; add "Now" jump | Colour dots: green=done, orange=due, grey=later |
| Sales | Amount keypad (big digits) + one-tap recent customers, no dropdown | Skip line-items for F&B: total only | Live "+X pts" preview under amount |
| Services | Duplicate-from-existing; drag reorder | Emoji/photo per service, price big | Photo tiles, not text rows |
| Bookings | Approve→appointment in one tap (`convert_booking_request`) | Two buttons only: ✅ approve / ✕ decline | New = orange dot badge on 🏠 group |
| Waitlist | "Notify next" one tap; auto-sort by wait time | Add walk-in = name + phone only | Position number as big circle |
| Inventory | Low-stock floats to top; +/- steppers not typed qty | Only show items that move | Red bar when below reorder point |
| Packages | Sell = pick customer + package tile; use-session one tap | Sessions-left as pictogram dots ●●●○○ | Progress dots, no table |
| Loyalty | Points auto-earn (trigger); staff never computes | Reward = progress bar to next tier | 🎁 fills up; "3 more visits" text |
| Retention | Toggle programs on/off; templates preloaded | Plain-language "win back after 30 days" | Toggle switches, green=on |
| Referrals | Auto-generate code; share sheet | "Give friend, both get $X" one-liner | 🤝 + QR to share |
| Memberships | Enrol = plan tile + confirm; renewal auto | Status badge active/paused/due | 💎 colour by state |
| Gift cards | Issue = amount keypad + QR; redeem = scan/enter code | One screen issue, one screen redeem | 🎟️ card visual with balance |
| Reports | Presets (Today/Week/Month) not date pickers first | Owner-only; hidden from frontline | Big totals, export button |
| Settings | Group toggles by module; team roster with avatars | Language toggle top of page | Role pills, avatar rows |

## 3. Low-literacy design system

**Pictogram per core action** (label ≤3 words beneath, never icon-only):
add ➕ · save 💾→ show ✓ · confirm ✅ · cancel/stop ✕(red) · customer 👤 · money 💰 ·
points 🎁 · phone 📞 · scan 📷 · done ✓ · back ‹ · search 🔍 · approve ✅ · decline ✕.
**Rules:** numerals over words ("12", not "twelve"; "$8.50" not "eight fifty"). **Colour
semantics:** green `--green`=money in / success / on; orange `--amber`=needs action / new /
due; red `#C0392B`=stop / decline / low stock; ink=neutral. Never colour-only — pair with
icon + shape. **Tap targets ≥48px** (bump `.btn` min-height 48px on wizard screens).
**One decision per screen** in every wizard — one primary big button, one small back.
**Customer rows show avatar/photo** (initial circle if none) so staff recognise by face, not
spelling. **Success = full-screen big ✓** + amount/points, auto-dismiss 2s. **Confirmation by
illustration** — e.g. redeem shows a draining 🎁 bar, not a sentence.

**Language strategy — label dictionary, not hard-coded strings.** Add a `LABELS` object keyed
by short IDs, each mapping to 6 locales: `en` / `zh` (中文) / `ms` (Bahasa Melayu) /
`th` (ไทย) / `vi` (Tiếng Việt) / `my` (မြန်မာ). A `t('start_visit')` helper reads the current
lang from `localStorage.frenly_lang` (default `en`), falls back to `en` on missing key. A
language toggle (6 flag/name chips) sits in Settings header and on the auth/onboard screen so
staff switch before they ever read English. Only wizard + nav + action labels need translating
first (~40 keys); analytics stay English. Do NOT machine-translate business data
(customer names, service names) — only chrome/UI.

## 4. Three wizard flows to build first

Each step = one screen, one decision, one big button. Maps to existing RPCs/tables.

**(a) Customer visit** (frontline default landing)
1. `t('who')` 👤 — phone keypad (big digits). Type last digits → live filtered list of
   avatars+phones. Tap match **or** "➕ New" → name+phone only. → holds `client_id`.
2. `t('how_much')` 💰 — amount keypad, big digits, live "+X pts" preview. Big **✓ Done**.
   → `insert into sales (business_id, client_id, amount_cents, kind:'sale')`; trigger
   auto-earns points + fires retention/referral.
3. **Done screen** — full-screen big ✓, "🎁 +X pts", reward progress bar ("2 more → free
   coffee"). Auto-return to step 1 after 2s.

**(b) New booking request** (from 🏠 badge)
1. Request card — customer avatar, service, requested time; two buttons: **✅ Approve** /
   **✕ Decline**.
2. Approve → one tap calls `convert_booking_request` (creates client + appointment). Success
   ✓ "Booked ✓ · Mon 3pm". Decline → confirm ✕, done. No manual re-entry.

**(c) Redeem reward**
1. Find customer (reuse step-1 phone finder) → show balance as pictogram progress bar
   (🎁🎁🎁▫️▫️) + "You have 300 pts".
2. Pick reward tile (shows cost in pts). Big **✅ Redeem**.
3. Confirm illustration (draining 🎁). → `redeem_points(client_id, reward)`; on success
   full-screen big ✓ "Redeemed! 🎉", new balance. Guard double-tap (disable button).

## 5. Implementation spec (for Sonnet)

Single-file, framework-free. Keep everything in `app/index.html`. Add near `MODULES`:

```js
const NAV_GROUPS=[
 {id:'today',   em:'🏠', k:'nav_today',   mods:['dashboard','appointments','waitlist','bookings'], open:'dashboard'},
 {id:'custs',   em:'👥', k:'nav_customers',mods:['clients','sales'],                                open:'clients'},
 {id:'comeback',em:'🎁', k:'nav_comeback', mods:['loyalty','retention','referrals','memberships','giftcards'], open:'loyalty'},
 {id:'stock',   em:'📦', k:'nav_stock',    mods:['services','inventory','packages'],               open:'inventory'},
 {id:'setup',   em:'⚙️', k:'nav_setup',    mods:['reports','settings'],                             open:'reports'}
];
```

**Collapsible nav** — in `renderShell`, replace the flat map with a per-group render: filter
`g.mods` by `enabled_modules`+`settings`; skip empty groups. Header `<div class="navgrp">`
(emoji + `t(g.k)` + `▸`/`▾`); children reuse existing `.nav a`. Toggle adds/removes a
`.collapsed` class (`max-height:0;overflow:hidden`) + persists open-set to
`localStorage['frenly_nav_'+S.user.id]`. First-run default open-set derived from
`S.staff.role` (fetch role alongside `business_id` in `route()`).

**i18n** — add `const LABELS={ start_visit:{en:'Start visit',zh:'开始',ms:'Mula',th:'เริ่ม',
vi:'Bắt đầu',my:'စတင်'}, ... }` and `function t(k){return (LABELS[k]?.[localStorage.frenly_lang
||'en'])||LABELS[k]?.en||k}`. Language chips write `frenly_lang` then `route()`.

**Wizards first** — build 4a (Customer visit) as new `#/visit` page, set as frontline landing
in `route()`. Then 4b inside existing `bookingsPage` (add approve button calling
`convert_booking_request`). Then 4c as `#/redeem`. Reuse the phone-finder as a shared
`customerFinder(onPick)` helper.

**Do NOT touch:** DB schema, RPCs, triggers, `create_business`/`accept_invite` onboarding,
auth, portal (`renderPortal`), Reports/analytics internals, Supabase keys. Additive only —
new pages + grouped nav + `LABELS`/`t()`; existing page functions keep their signatures.
