# Help Centre (nestly_v904)

The in-app operating manual for the business workspace. Reachable at `#/help` by every
signed-in workspace account, whatever their role.

This document is for whoever has to keep it true. It records the audit the content was written
from, how the thing is put together, and the rules the content is held to.

---

## 1. What was audited

Everything below was read out of `app/app.js` and verified against the real route table, the
real route guards, and the real button labels. Nothing here was inferred from a module's name.

### Routes that exist (the `P` table in `renderShell`)

| Route | Screen | Guard |
|---|---|---|
| `#/dashboard` | Dashboard | module `dashboard` |
| `#/till` | Record sale | module `till` |
| `#/clients`, `#/client/<id>` | Customers, Customer profile | module `clients` |
| `#/sales` | Sales & refunds | module `sales` |
| `#/services` | Services | module `services` |
| `#/inventory` | Products | module `inventory` |
| `#/packages`, `#/custpackages` | Packages, Customer packages | module `packages` |
| `#/appointments` | Appointments | module `appointments`; rail hidden for `fnb`/`bar` |
| `#/bookings` | Bookings | module `bookings` |
| `#/waitlist` | Waitlist | modules `waitlist` **and** `bookings` |
| `#/grow` + `/overview /history /offers /points /tiers /bringback /birthday /welcome /setup` | Rewards & Offer | module `loyalty` |
| `#/loyalty` | alias onto the Rewards Programme landing | module `loyalty` |
| `#/retention` | redirects to `#/grow/bringback` | module `retention` |
| `#/referrals` | Referrals | module `referrals` |
| `#/promotions` | Limited Offer authoring | **owner only** |
| `#/studio` | Program Studio | **owner only** |
| `#/reports` | Business Insights | module `reports` + finance |
| `#/customerintel` | Business Intelligence | module `customerintel` + finance |
| `#/dailyreport` | Daily report | module `dailyreport` + finance |
| `#/staffperf` | Staff commission | module `staffperf` + finance |
| `#/branches` | Branches | **owner only** |
| `#/staffmembers` | Staff Members | **owner only** |
| `#/customer-interface` + `/brand /appointment /programme /done /interface` | Customer Interface | **owner only** |
| `#/settings` | Subscription | **owner only** |
| `#/setup` | Get started | **owner only** |
| `#/remindernotify` | Reminder & Notification | **owner only** |
| `#/bottles`, `#/bottlesetup` | Bottles, Bottle keep | bar sector only; setup owner only |
| `#/platform` | Platform console | super admin only |
| `#/help`, `#/help/<topic>`, `#/help/<topic>/<task>` | **Help Centre** | none — every role |

### Roles

`owner · manager · staff · frontdesk · bookkeeper` (`ROLE_LABELS`). Capability sets
(`ROLE_CAPABILITIES`): `create_sales` for owner/manager/staff/frontdesk; `view_finance` for
owner/manager/bookkeeper. `FINANCE_MODULES` = `expenses · pnl · staffperf · customerintel`.
`OWNER_ONLY_MODULES` = `branches · staffmembers · settings · setup · bottlesetup · remindernotify`.
On top of the role, the owner sets each teammate's modules to Off / Read / Edit in Staff Members.

### Deliberately NOT documented, and why

| Thing | Reason |
|---|---|
| Gift cards | `RETIRED_BUSINESS_MODULES_V768` — no rail row, route refused with a toast (V303). |
| WhatsApp Inbox | same set; owner ruling nestly_v768. |
| Memberships | `UNVERIFIED_MODULES_V466` — route refused with a toast. |
| Stored value | route refused: "not available for launch". |
| Expenses, P&L | left the rail in nestly_v518. The routes still resolve, but there is no door to them in the navigation, so a guide would be telling people to type URLs. |
| Reminder & Notification | `HIDE_WHATSAPP_API_SURFACES_V824 = true` makes **both** of its cards render nothing, so the page is a title and no content. It gets a Troubleshooting entry ("Reminder & Notification is empty"), not a module guide. See §5. |
| Program Studio | owner-only draft authoring reached from inside Rewards & Offer; it has no rail row of its own. Covered by the Rewards & Offer guide's publish steps. |

---

## 2. Where the content lives

**One authoring surface.** `app/app.js`, in the `nestly_v904` block:

```
HELP_TOPICS_V904           the guides. Everything a maintainer edits.
HELP_GENERAL_PROBLEMS_V904 cross-cutting problems that belong to no single module.
HELP_GLOSSARY_V904         [term, meaning], alphabetical.
HELP_CONTEXT_V904          route key -> topic slug, for the contextual Help button.
```

The **Common tasks**, **Troubleshooting**, **FAQ** and **search index** pages are *computed* from
`HELP_TOPICS_V904` — they are views, not content. A module guide and the FAQ about it therefore
cannot drift apart, and adding a module is one new entry with no other edit.

`app/app.js` is the only editable source; `app-business.js` and friends are generated. The Help
block lands in the **business** chunk (customers never download it) because `helpPage` is only
reachable from `renderShell`.

### A topic

Every field is optional except `slug`, `group`, `title`, `summary`. The renderer emits only what
is present, which is what keeps every guide the same shape without forcing empty sections.

```js
{
  slug, group:'start'|'module'|'help', title, icon, summary,
  route, routeLabel,      // the "Go to <feature>" button
  path,                   // 'Customers → Add customer'
  modules:[...],          // EVERY key must be readable. Waitlist = ['waitlist','bookings'].
  roles:['owner'],        // mirrors the route guard
  sector:'bar',           // mirrors BOTTLE_SURFACES_V275
  hideWhenSeated:true,    // mirrors SEATED_SECTORS_WITHOUT_APPOINTMENTS_V276
  what, can:[], sections:[], screen:[[label,meaning]],
  tasks:[{slug,title,path,steps:[],note,keywords:[],roles,modules,shot}],
  know:[], problems:[{q,causes:[],fix:[]}], faq:[[q,a]], related:[], keywords:[]
}
```

### Adding a guide when a module ships

1. Add one entry to `HELP_TOPICS_V904`.
2. Add its route key to `HELP_CONTEXT_V904` so the contextual Help button finds it.
3. `npm run bundle-stamp` (and `npm run app-css` if you touched CSS).

It then appears in the home grid, Browse by module, search, Common tasks, Troubleshooting and the
FAQ automatically.

### Screenshots

`shot:{src,alt,caption}` on a task or a section. Until a real image exists the field is absent and
**nothing** is rendered — no placeholder frame. The written steps always stand on their own.

---

## 3. Role and access awareness

`helpAccessOkV904()` mirrors the workspace's own gates:

* `roles` — the owner-only route guards in `route()`.
* `modules` — `canReadModule()`, which is `S.myModules` **and** the finance capability check.
* `sector` / `hideWhenSeated` — the bar-only and seated-sector rules the rail uses.

A guide the reader cannot act on is not listed, not searchable, and not reachable by URL — a typed
`#/help/branches` from a front-desk account lands on the Help home with the words pre-filled into
search rather than 404ing. Tasks may narrow their parent further (setting up the Point system is
owner-only inside a guide every role may read) but can never widen it.

**Verified by rendering:** a front-desk account with `till + clients + appointments` sees exactly
those three module guides. An F&B staff account sees Bookings and Waitlist and **no** Appointments.

---

## 4. Where Help is reachable

| Door | Behaviour |
|---|---|
| Sidebar, below the groups | `#/help`. Appended outside `NAVGROUPS` because Help is not a module and has no entitlement — putting it in the array would make it the one row not gated by `navModuleVisible`. The mobile "More" drawer renders `navHtml`, so it appears there too. |
| App bar, beside the bell | **Contextual.** Reads `HELP_CONTEXT_V904` and opens the guide for the screen you are on. A direct child of `.appbar` because `.global-actions` is `display:none` below 960px. |
| Account menu | "Help Centre" → `#/help`. |

The app-bar control is the answer to "contextual help without a question mark on every screen":
one insertion point in the shell, no edit to any page function.

---

## 5. Rules the content is held to

1. **It describes what the application does today.** No planned features, no feature-flagged
   surfaces, no unused code paths. See the "not documented" table in §1.
2. **Every instruction names a control that exists.** Labels were read out of `app/app.js`, not
   guessed. Corrections made during this pass: Sales says **Amend**, not "Correct amount"; Daily
   report says **Run report**, not "Generate".
3. **Business language.** No endpoint, API, schema, row, state or query.
4. **Short.** A guide should scan in under a minute. Improve wording, steps and links rather than
   adding text.
5. **Never advertise a screen the reader cannot open.** §3.

---

## 6. Analytics

One emit site: `helpRecordV904()`. It rides the **existing** `merchant.surface_viewed` taxonomy —
a name not in the database taxonomy is refused with `22023`, so a new event would need a migration
and Help does not need one.

* `surface_key` — `help`, `help:customers`, `help:customers/add-customer` → most-viewed guides
* `outcome` — `results` | `no_results` | `go_to_feature` → searches that fail, Help→feature clicks
* `query_shape` — `exploreQueryShapeV256`'s shape (word count, length band, matched or not),
  **never the typed text**. A Help search can easily contain a customer's name.

The v255b platform read already aggregates `query_shape` and suppresses shapes seen fewer than 5
times, so the search analytics are k-anonymised by the pipeline they join.

---

## 7. What changed outside the Help block

Everything else is additive and backward-compatible. No calculation, RLS policy, RPC, migration,
permission or existing route was touched.

* `app/app.js` — `help:helpPage` in the `P` table; a Help row appended in `navHtml`;
  `helpTriggerHtmlV904` in the app bar; a "Help Centre" row in the account menu; `'help'` added to
  two existing display-name fallback chains; one new i18n template key (`helpForSurfaceV904`).
* `app/customer-ui.js` — one new icon, `book`.
* `app/index.html` — the `-v904` stylesheet. Every selector is scoped; nothing touches `.card`,
  `.btn`, `.pill` or `.nav`.
* `app/sw.js` — `CACHE_VERSION` bumped to `v24-20260915-v904`. **Required**: the worker precaches
  `customer-ui.js`, so its `?v=` token and `CACHE_VERSION` move together or the new glyph is never
  served.

After editing: `npm run bundle-stamp && npm run app-css`, then
`node scripts/quality/regen-visual-fixtures.mjs` (needs Playwright) if CSS changed.
