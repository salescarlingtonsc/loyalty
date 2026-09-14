# Presenting Peekaa's intelligence to the owner — alignment spec

Drafted 2026-09-15 from a read-only audit of `app/app.js`, `app/sector-economics.js`,
`app/revenue-truth.js` and the v826/v828 owner-brief migrations. Presentation only:
no RPC, trigger, ledger or policy logic changes are proposed. Every number named
below is already computed by an existing reader and already fetched by the page it
is proposed for, unless marked **(flag)** or **(ruling)**.

## 1. The objective, stated as what the owner must see

Peekaa is not a POS. The POS knows what sold. Peekaa knows **who bought it**, and
Business Intelligence turns that into guidance. So every owner-facing screen must
answer, in this order:

1. **What only Peekaa knows** — who is slipping, who buys what, which service or
   item brings people back, where customers come from.
2. **What to do about it** — one action per finding, from an existing surface.
3. **How complete the data is** — share of sales linked to a customer, share of
   revenue categorised, so the owner trusts the guidance and improves capture.

## 2. What the audit found

### 2a. The Dashboard is POS-shaped
`dashboard()` (app.js 24620–25039) shows revenue, valid visits, new members,
inactive customers, busiest days, revenue over time, age and gender. Apart from
"inactive", a POS report shows all of this. Meanwhile the nightly owner brief
(`get_owner_brief_v1`, v826 + v828) already composes the owner's five questions
("am I okay, what is wrong, why, what should I do, did last week's thing work" —
v826 header, owner request 2026-09-08) plus 19 extended facts: top items by
revenue and by margin, dying items, items bought together, discounts by staff,
referrals, points expiry, member lift, birthdays, stock, bookings ahead. The
Dashboard renders **three tiles** of it (`ownerBriefOverviewV890`, 24553–24576)
and a link.

### 2b. The differentiating answers exist but are buried
All of these render today, but only inside Business Intelligence → Explore,
a page that fires 28 readers on open:

| Answer only Peekaa can give | Where it is today | Reader |
|---|---|---|
| Customers to bring back (name, usual interval, last visit, SGD at stake, Call) | BI → Explore → Retention (54607) | `get_attention_list_v548` |
| Which service brings people back (bought again, first-timers it brought in) | BI → Explore → Services (54711) | `get_ci_service_intelligence_v1` |
| Category mix → named customers per category | BI → Explore → Services (53215, 53254) | `get_ci_category_mix_v1`, `get_ci_category_customers_v1` |
| What each demographic group buys | BI → Explore → Customers (55062) | `get_ci_demographic_totals_v1` |
| Where customers come from (QR, referred, till, imported…) | BI → Explore → Acquisition (53101) | `get_ci_acquisition_v1` |
| Staff: who brings customers back | BI → Explore → Staff (54871) | owner brief `staff` fact |
| Most popular / ignored rewards | BI → Explore → Rewards (54910) | `get_ci_reward_popularity_v1` |
| Top seller, top by margin, dying items, pairs | BI → Ask my business (prose only, 24393–24410) | owner brief `facts.items`, `facts.dying`, `facts.pairs` |

### 2c. Data completeness is invisible to the owner
- `customers.identified_pct` (share of transactions linked to a customer) is
  composed by the brief (v826 line 229) and **never rendered**.
- Line-item capture ("Itemized transactions / Itemized revenue") renders only in
  Sector Economics (`sector-economics.js` 596–657), behind platform flag
  `economics_driver_policy_v109`, seeded false. The page draws nothing when gated.
- The only coverage the owner sees is "X% of revenue is sorted into categories"
  (BI → Business health, 56093) and "Identity coverage" on Reports → Customer
  Retention (57206).

### 2d. Surfaces that carry the objective and are dead or unreachable

| Surface | State | Cause | Reverse? |
|---|---|---|---|
| "Customers to bring back" card | loader `loadAttentionListV571` has zero call sites | **(ruling)** v613: struck out on the Bring-back page as a second audience above the campaigns | Not on Bring-back. Promote to Dashboard instead — different page, same reason holds. |
| "Gone quiet, and who came back" + Bring-back playbooks with held-back arms ("did it work?") | unreachable: `#/retention` redirects to `#/grow/bringback`; renderers only mounted in the un-routed `retentionPage()` | routing change, **not a ruling** | Yes — mount under Bring-back as "Did it work?" |
| "Loyalty this period" strip | `loyaltyVisibleV170=false` | **(ruling)** V224: belongs in Programmes | Respect. |
| Product cost and profitability block | deleted | **(ruling)** V364: second index of editors | Respect. Margin survives in "Recommend my numbers" and in brief `facts.items.top_by_margin`. |
| Sector Economics (gross profit, itemized coverage, revenue drivers) | flag off | **(flag)** evidence-gated by design | Leave the page. Lift only `identified_pct` (already fetched elsewhere). |
| "Peekaa's suggestion" banner on Customer 360 | removed | **(ruling)** V249: duplicated header buttons | Respect. |
| Daily report gift-card tile | computed, not rendered | v468 layout | Leave (gift cards removed v768). |

### 2e. Two destinations with near-identical names
Module labels (app.js 600): `reports` = **Business Insights**, `customerintel` =
**Business Intelligence**. The first is POS-style reporting (revenue by type,
reversals, capacity, retention rate). The second is the flagship. Owners cannot
tell which to open.

## 3. Proposed presentation, per surface

### 3a. Dashboard (owner's daily screen)
1. **Expand "This week" from 3 tiles to the five answers**, each one line with one
   action, all from the cached brief payload already loaded by
   `loadOwnerBriefV826`:
   - *Am I okay* — revenue vs normal week, and the `driver` (visits or basket).
   - *What is wrong* — `at_risk.overdue` regulars, `monthly_at_risk_cents`; action
     opens the bring-back list.
   - *Why* — `outlets.worst` / `daypart.quietest_hours` when evidence passes.
   - *What to do* — `action.top_action` title, audience, expected revenue.
   - *Did it work* — `action.last_result` and `rewards.top` / `ignored_active`.
   Then one row of item facts: top seller, top by margin, dying item, best pair
   (`facts.items`, `facts.dying`, `facts.pairs`). Needs owner confirmation because
   v890 chose three tiles.
2. **Add the capture meter as a Performance tile**: "Identified sales — N% of
   sales linked to a customer" from `customers.identified_pct` (brief) or
   `coverage.identified_transaction_pct` (`get_customer_lifecycle_v107`). Same
   tile component, same drill-down dialog. Zero new reads.
3. **Add "Customers to bring back" as a Dashboard card** using the existing
   `loadAttentionListV571` renderer (Call, Open). Owner decision (see 2d).
4. Keep Performance, Busiest days, Age, Gender as ruled 2026-08-02.

### 3b. Business Intelligence
1. **Reorder Explore** so the Peekaa-only groups lead: Customers, Services,
   Acquisition, Retention, Staff, Rewards; then Revenue & payments, Booking
   funnel, Packages, Branches, Weekday behaviour; Improve your insights,
   Evidence & methodology, Ask my business last. Array at 53482–53509.
2. **Business health gains one coverage row**: "Identified: N% of sales linked to
   a customer · Categorised: N% of revenue". Both values are already in the
   page's `Promise.all`.
3. **Promote the item facts out of prose**: render `facts.items`, `facts.dying`,
   `facts.pairs` as a small "What sells, what is dying, what goes together" table
   in Explore → Services, beside "Which service brings people back".

### 3c. Bring-back (`#/grow/bringback`)
Mount `renderComebackCardV300` and `renderPlaybooks` results below the campaigns
as a **"Did it work?"** section. Their RPCs (`retention_lapsed_candidates_v244`,
`staff_list_returned_customers_v300`, `get_campaign_results`) are untouched. Keeps
the v613 ruling: no second audience card above the campaigns.

### 3d. Reports (`#/reports`)
Rename the module label from "Business Insights" to **"Reports"** (MODULES, app.js
600) so "Business Intelligence" is unambiguous. Content unchanged.

### 3e. Customer 360
Add one line under the summary card, owner role only: **"Usually buys: A, B, C"**
summarised in the browser from the `sale_items` rows the history already loads
(26815–26859). No new read. "Peekaa's suggestion" stays removed (V249).

### 3f. Daily report and Staff commission
No change. Staff commission already is the most granular customer × item join in
the product; leave it.

## 4. Decisions needed from the owner

1. Dashboard "This week": expand to the five answers plus item facts (3a.1)?
2. Dashboard "Customers to bring back" card (3a.3)? v613 removed it from
   Bring-back, not from the Dashboard.
3. Restore "Did it work?" under Bring-back (3c)?
4. Rename `reports` to "Reports" (3d)?
5. Optional, later: flip `economics_driver_policy_v109` for itemized-revenue
   coverage. Not required for 3a.2.

Items 3a.2, 3b.1, 3b.2, 3b.3 and 3e add or reorder only and contradict no ruling;
they can proceed without a new ruling.

## 5. Delivery notes
- Edit only `app/app.js`; run `npm run bundle-stamp`; regenerate browser fixtures
  with `node scripts/quality/regen-visual-fixtures.mjs`; `npm run validate`.
- Every new tile or row must honour PRODUCT-TRUTH: no exact zero for an
  unavailable read, state scope (branch vs business-wide) and window.
- Estimated effort for everything in §3: 1 to 2 weeks including fixtures.
