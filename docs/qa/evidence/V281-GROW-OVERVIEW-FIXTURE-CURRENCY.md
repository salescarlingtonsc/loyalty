# V281 — the Grow overview browser fixture is current again (2026-08-12)

The checked-in Chromium fixture `tests/browser/reward-overview-owner-visual.html` had drifted:
it still embedded the pre-v271 Grow surface, so the "checked-in browser evidence identifies the
exact extracted production component" guard failed — correctly — from the moment b4b9445
(v271/v272, the programme Overview/History rewrite) landed without regenerating it.

## What was done

`node tests/browser/generate-reward-overview-owner-visual.mjs` regenerated the fixture from the
current production sources. That surfaced three real harness gaps the v271 code exposed, each
fixed in the generator (never in production code):

- the query stub lacked `.not()` (v271's earliest-published-version read uses it), so `growPage`
  threw and the fixture hung at its loading state;
- `growTopicV229` — a top-level app global the extracted sections read — was never declared in
  the harness;
- the v271 reads (`business_programme_usage_v271`, `business_get_welcome_offer_v215`) had no
  stub responses.

## Production-component source hash

`e2a796ad00f122a109bdfe6ab96f38c93413e2d571fb850b35d660e69e1b733d`

## What was verified in Chromium (1440×1100, system Chrome via playwright-core)

The regenerated fixture executes the real extracted `growPage` to completion: the Programmes
heading and `#rewardJourneyTitle` render (the v271 surface titles the tab "List"), **zero console
errors, zero page errors, no horizontal overflow, and no interactive control under 44 px**.

## Honest limitation

`tests/browser/verify-reward-overview-owner.mjs` — the deep owner-journey acceptance — still
asserts the **pre-v271** surface (title "All reward programmes", the old card taxonomy and
hrefs) and now fails on its own first assertion. Re-authoring that acceptance is work that
belongs with the session that shipped the v271 rewrite; it is recorded here rather than silently
skipped. The suite-level guard this document supports asserts fixture-to-source currency, which
is what was restored and verified.
