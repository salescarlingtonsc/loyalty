# V294 — owner iPad markup batch (2026-08-12): acceptance evidence

Nine owner annotations from a live-app walk on iPad, all UI-only (no migration, no governance
manifest change). Built and proven on 2026-08-12.

## What shipped (owner's words in quotes)

1. **Dashboard** — "I want date linked to data below": picking a day on the Today-schedule card
   now also sets the Performance figures to that single day; helper copy reads
   "Also sets the figures below to this day." The global range pills and Apply keep working
   and override.
2. **Customers** — "remove this, cause above have already": the duplicated filter bar is gone;
   the one kept bar carries the union of inactivity buckets (including `all_inactive`).
3. **Customer 360** — owner sketch: visits / lifetime spend / PDPA consent moved into a compact
   summary card at the upper right, the POINTS and SPENDABLE CREDIT tiles folded into that card
   as rows (history button, paused note, expiry line and both collapsibles preserved), and
   "Available Customer Programmes" now lists real programme rows — "all available Customer
   programmes should show here" — with an honest Paused pill when the loyalty programme is
   paused.
4. **Nav** — Programmes is a group with three children (Overview / List / History), mirroring
   Serve & sell, each routing to the matching #/grow view with active-state highlighting.
5. **Reward catalogue** — "expired don't show here, show in own history": retired and ended
   rewards leave the offer grid/list and live in a collapsed "Reward history" disclosure (count
   in the summary; Edit from history still opens, so a retired reward can be un-archived).
6. **Loyalty editor** — "this in tier programme, not here!": entered from the Points redemption
   card the editor shows the point system + reward catalogue only (entry context carried on the
   hash as `ctx-points` / `ctx-tiers`); entered from the Tiered membership card the tiers block
   shows; the "← Back to Grow overview" button is removed (the rail group supersedes it).
7. **Programmes overview** — promotions ongoing card reads "N LIVE"; the combined "Memberships &
   gift cards" card is removed ("remove this programme") — Memberships stands alone with
   "Let customers subscribe and save", and Gift cards moved to the Serve & sell nav group;
   pending-setup cards lead with the owner's benefit lines.
8. **Business Insights** — the four report cards became a tab bar: Sales & Revenue · Efficiency
   (renamed from Appointments & busy times) · Customer Retention · Team Performance; From/To +
   Run report + Export stay above and apply to the open tab.
9. **Staff Members** — "Roster only" renamed to "Team members".

## Proof

- `tests/browser/verify-v294-owner-batch-walkthrough.mjs` — scripted Chrome walkthrough over the
  real stamped bundles and router (in-page Supabase fixture): steps 1–9 all PASS.
- `tests/browser/verify-v293-reward-editor-walkthrough.mjs` — retargeted at step (e) to assert
  the archived reward moves into the Reward history section: PASS (steps a–g).
- Full `node --test` triage sweep: zero new failures against the origin/main baseline (the one
  pre-existing baseline failure, v131 store-association, is unchanged).

## Regenerated fixture provenance

- `tests/browser/reward-overview-owner-visual.html` production-source-sha256:
  `ab5342d62cbb3d0ffb724c1078d42c8257e5315dfe0a01c49c7d3312f766e798`
- `docs/qa/evidence/v104-promotions-production-render-metrics.json` recaptured from the
  regenerated fixture (status PASS, sourceHash
  `044b6933228f7ec9ff0bf42a4eb730580c22843defeaa8b07938a169a79b12e8`).
