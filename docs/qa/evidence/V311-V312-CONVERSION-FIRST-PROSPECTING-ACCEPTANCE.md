# V311–V312 — Conversion-first prospecting: acceptance evidence

**Date:** 2026-08-14
**Production project:** `gadpooereceldfpfxsod`
**Owner directive:** the prospecting system optimises for ONE objective — conversion.
Lead scoring is explicitly banned: *"I don't care about predicting conversion. I care
about MEASURING actual conversion."*

---

## 1. The defect this release exists to fix

Before v311, "is this business already a Peekaa merchant?" was answered by
`sme_prospects.converted_business_id`, which is written **only** by our own conversion
RPC. Every merchant who signed up directly was therefore invisible to that check.

At the time of the audit **0 of 11 live merchants** had any link to prospecting, and
`public.businesses` carried no Place ID, postal code or phone — so no join to a
discovered business was even possible. The consequence was not an edge case: Google
would rediscover an existing customer, the business would appear in the available-prospect
pool, and a sales rep would cold-call someone who already pays us.

## 2. What shipped

| Area | Change |
|---|---|
| Merchant identity | `businesses.place_id` (unique) + `businesses.postal_code`; `sme_companies.peekaa_business_id` + link metadata |
| Auto-match | `app.v311_match_merchants()` — Place ID or name+postal links silently; name-only is queued |
| Review queue | `sme_merchant_match_candidates` (definer-only) + list/decide RPCs |
| Live removal | Statement trigger on `businesses` re-runs the matcher, so signing a merchant removes them from the pool with no manual step |
| Pipeline | 19 inherited stages → the owner's lifecycle (7 rep-facing + 6 closed + 2 hidden system) |
| Lead scoring | `sme_lead_scores`, `sme_lead_score_weights`, `app.v297_lead_score`, `app.v297_refresh_lead_score` — **dropped** |
| Explorer | `platform_explorer_search_v312` — 4 modes, 10 sorts, defaults to hiding our own merchants |
| Bulk assign | `platform_explorer_bulk_assign_v312` — super-admin only, refuses existing merchants |
| Analytics | `platform_conversion_funnel_v312` — measured from real stage history |

### Why two stages were kept but hidden

`client` and `account_created` remain in the vocabulary with `is_system=true`.
`convert_sme_prospect_v79` — which writes `subscriptions`, `loyalty_programs`, the owner
invite and the onboarding checklist — hard-requires both. Hiding them from the rep-facing
pipeline gave the owner the short pipeline he asked for **without editing billing-critical
code**, which is a risk exception under `AGENTS.md`.

## 3. Verification (rolled back against production)

`db/tests/v311_conversion_first_prospecting.sql`, plus an equivalent chain for v312. The
assertions that carry the weight are the negative ones:

| # | Assertion | Result |
|---|---|---|
| A | Same Place ID links even when names disagree entirely; basis recorded as `place_id` | pass |
| B | Same normalized name **and** postal code links; basis `name_postal` | pass |
| C | Same name, **different** postal → **NOT** linked, queued as `name_only` | pass |
| D | Inserting a merchant auto-links the discovered company via trigger | pass |
| E | Rep pipeline is exactly `new_lead>assigned>contacted>interested>appointment>onboarding>activated`; 6 closed states; `client` preserved as system | pass |
| F | Zero rep-facing stages are unreachable (`validate_stage_entry_v86` raises without a requirements row) | pass |
| G | Lead scoring tables and functions are gone | pass |
| A′ | Explorer default view excludes an existing merchant, includes the real prospect | pass |
| B′ | `peekaa_status='merchant'` finds it explicitly | pass |
| C′ | An unknown sort key is rejected (`22023`), not silently ignored | pass |
| D′ | `ids` mode returns the id set that powers select-all-matching | pass |
| E′ | `markers` mode carries geometry | pass |
| F′ | Bulk assign: 1 assigned, 1 **skipped** because it is already a merchant; stage advanced `new_lead→assigned`; consultant recorded | pass |
| G′ | Funnel counts contacted + appointments from real history, computes the rate, populates by_location and by_consultant | pass |
| H′ | `count` mode agrees with `list` | pass |
| I′ | An assigned prospect no longer matches `assignment='unassigned'` | pass |

Two defects in the migration SQL were caught by these runs before anything shipped: the
outreach and stage-history timestamp columns (`contacted_at` / `occurred_at`) had been
used the wrong way round in two different functions.

## 4. Security finding, self-inflicted and closed

`sme_merchant_match_candidates` was created with RLS enabled but inherited Supabase's
default grants, leaving **`anon` and `authenticated` holding full DML** while every
sibling `sme_*` table is definer-only. RLS with zero policies already denied access, so
nothing was exposed — but that is one safety net where the family standard is two, and a
future permissive policy would have silently opened the table. Revoked in production and
in `20260814_nestly_v311_conversion_first_prospecting.sql`. Caught by the repo's own
`pending-migration-preflight` RLS/ACL test.

## 5. Scope correction recorded for the record

The cleanup was authorised on the basis of "~30 empty unused tables". A dependency scan
proved that description wrong: **45 of 48 `sme_*` tables and 42 of 54 prospecting RPCs are
referenced by live code**. They are empty because the CRM has not been used in production
yet. `sme_commercial_terms` — zero rows — is required by the conversion RPC; dropping it
would have broken merchant conversion.

Only the proven-unreachable set was removed: 3 tables and 11 functions. Reference data
from the dropped tables is preserved verbatim in
`db/migrations/20260814_nestly_v311_rollback_data_snapshot.sql`, which is registered as a
non-executing recovery artefact.

## 6. Open items

- ⚖️ Google Places storage terms remain the outer constraint on what the explorer may
  persist — see `V310` evidence and `docs/qa/evidence` for the OneMap posture. Counsel
  review still recommended before scaling outreach.
- The master business database is still effectively empty: **0 businesses have been
  imported from Google**. The discovery pipeline is live and gated, but the first import
  is an owner action because it spends against the Google billing account.
