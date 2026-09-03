# CI-100 checklist item 20 (section B) — 50-insight independent reproduction

> Independent reproduction by an agent that did not author the readers; not an external
> reviewer — the checklist's independent-reviewer requirement remains **EXTERNAL** until a
> named person signs.

**Commit SHA:** `57706c87e61623544e3a2beab8cb529067a4ba68`
**Date:** 2026-09-02 (run started ~11:17 UTC / 19:17 SGT, finished ~11:27 UTC / 19:27 SGT)
**Harness watermark:** `LC_ALL=C node scripts/db-tests/run.mjs --filter=v682_golden --migrated-only --keep`
(boots throwaway Postgres 17, baseline snapshot `tests/fixtures/db-schema-snapshot.sql` watermark
v422, replays every migration up to and including `20260920_nestly_v730_category_customers_window.sql`
into database `peekaa_migrated`; cluster kept at `127.0.0.1:65344` per `--keep`, stopped at the end
of this run). Note: the `v682_golden_reconciliation.sql` fixture itself FAILed on this run inside
its own `rollback`-wrapped transaction, but for an unrelated, pre-existing reason — a `format()`
call in its own timing-budget branch (`db/tests/executed/v682_golden_reconciliation.sql:234`)
passes a literal `%` inside a message string without escaping it (`'... over the % ms budget'`),
which `format()` rejects. That is a defect in the test file's own diagnostic message, not in the
seeder or in any reader under test here; it did not block this proof, which calls the seeder
directly (see below) rather than depending on that fixture's own transaction.

## Method

1. Booted the harness as above and left the cluster running (`--keep`).
2. Directly seeded three golden businesses with `app.seed_golden_business_v682(p_index, p_sector,
   p_owner)` (the checklist-item-10 golden-corpus seeder,
   `db/migrations/20260920_nestly_v682_golden_corpus.sql`), one call per sector, against
   `peekaa_migrated`:

   | sector | p_index | business_id | branch_id |
   |---|---|---|---|
   | fnb | 901 | `a244162b-084b-4de3-bbfa-375a4681742a` | `a8e2882f-4820-42d7-bce8-663cb357d402` |
   | salon | 902 | `a629f228-c9da-43dc-aa60-8e00808d3739` | `801975ec-8d3d-4563-9859-5a3fd3541752` |
   | fitness | 903 | `d7d4afda-581e-4d8b-8d88-465f5c8dad2a` | `32fde1ef-e5d6-4da0-9f7e-682f20f0e6d6` |

   Owner: `00000000-0000-4000-8000-000000900001` (`auth.users` row inserted for the fixture; RLS
   verified as this owner via `set_config('request.jwt.claims', ..., false)` — session-level, not
   local, since each `psql -f` statement here is its own implicit transaction and a `true`
   (local) GUC would be wiped between statements — a trap this run hit and fixed before any RPC
   call below).
3. Called the eleven listed product RPCs — `get_ci_opportunities_v1` (`p_extended=true`),
   `app.v179_business_insights`, `get_ci_funnel_conversion_v1`, `get_ci_retention_windows_v1`,
   `get_ci_daypart_v1`, `get_ci_category_mix_v1`, `get_ci_demographics_v1`,
   `get_ci_staff_performance_v1`, `get_ci_discount_dependency_v1`, `get_ci_loyalty_programmes_v1`,
   `get_ci_discovery_v1` — as the seeded owner, over the same `[from, to] = [2026-05-05,
   2026-09-03]` window the seeder used (`current_date - 120` .. `current_date + 1`), all three
   verified genuinely entitled first (`app.is_salon_member`, `app.can_module(...,'customerintel')`,
   `app.has_perm(...,'view_finance')` all true for all three businesses before any RPC call).
4. Selected 50 distinct headline numbers out of those outputs (see table below; 51 were actually
   collected because a clean 3-way split across the useful sources landed one over — all 51 are
   reported, not just the first 50, since every one of them matched and none needed to be
   discarded).
5. For each one, wrote independent SQL directly over `public.sales` / `public.clients` /
   `public.sale_items` — never calling the RPC under test, never reading its return value as an
   input — applying the same exclusions the envelope declares for every CI reader
   (`app.ci_exclusion_counts_v680` / the `qualifying sale` shape used throughout: `reversal_of is
   null` AND no later row reverses it, `client.is_synthetic is not true`, `counts_as_visit` /
   `counts_as_revenue` per metric, Singapore-timezone visit day via `occurred_at at time zone
   'Asia/Singapore'`). Where a metric's definition is genuinely non-trivial (the acquisition
   funnel, the retention cohort windows, the discount-dependency classifier, the at-risk /
   new-customer population in `v179`), the reader's own `pg_get_functiondef` was read first and
   the independent SQL implements the same definition against the base tables from scratch —
   never copy-pasted from inside the function body, always re-derived from its logic and then
   run separately.
6. Captured the record ids (`sales.id` for sale-level insights, `clients.id` for
   customer-level insights) that each independent computation actually touched, as the lineage
   column below.
7. Diffed the RPC's JSON output against the independent SQL result, value for value.

**Result: 51/51 matched. Zero mismatches.**

## Business identity (for anyone re-running this)

- Owner: `00000000-0000-4000-8000-000000900001` (`zz-proof-owner@example.test`)
- fnb: `zz-golden-fnb-901`, business `a244162b-084b-4de3-bbfa-375a4681742a`, branch
  `a8e2882f-4820-42d7-bce8-663cb357d402`
- salon: `zz-golden-salon-902`, business `a629f228-c9da-43dc-aa60-8e00808d3739`, branch
  `801975ec-8d3d-4563-9859-5a3fd3541752`
- fitness: `zz-golden-fitness-903`, business `d7d4afda-581e-4d8b-8d88-465f5c8dad2a`, branch
  `32fde1ef-e5d6-4da0-9f7e-682f20f0e6d6`
- Reporting window used by every RPC call and every independent query: `[2026-05-05, 2026-09-03]`
  (`current_date - 120` .. `current_date + 1`, evaluated 2026-09-02 SGT — matches the seeder's own
  `window_from`/`window_to`).
- These businesses were **left seeded on the kept cluster** at the time of writing (the kept
  Postgres cluster itself was stopped after this proof was written — see "Cleanup" below — so
  they no longer exist anywhere; this identity block is provenance for the numbers in the table,
  not a live pointer).

## The 51 reproductions

Product value = the exact value read out of the RPC's own JSON response. Independent value = the
value computed by this session's own SQL, run separately, against `public.sales` /
`public.clients` / `public.sale_items` directly. Lineage = the specific record ids the
independent SQL actually aggregated (truncated to the first two ids plus a count where the full
list is long; the count itself is part of the independent computation, not decoration).

| # | Source | Insight | Business | Product value | Independent value | Match | Lineage (record ids) |
|---|---|---|---|---|---|---|---|
| 1 | `get_ci_daypart_v1` | weekday Mon visits+revenue_cents | fnb | `(5, 12000)` | `(5, 12000)` | YES | 5 sale ids, first 2: `10cce761-03a2-4ec6-b0f5-b76cfa1b6bb5`, `244ef438-2df2-4e2b-a95c-b538803c8a38` |
| 2 | `get_ci_daypart_v1` | weekday Tue visits+revenue_cents | fnb | `(11, 25200)` | `(11, 25200)` | YES | 11 sale ids, first 2: `51bc107d-cc83-4122-aad8-ba25b6ca5de0`, `62a3f3c3-8075-454b-a99a-ea61a140aea4` |
| 3 | `get_ci_daypart_v1` | weekday Wed visits+revenue_cents | fnb | `(7, 16800)` | `(7, 16800)` | YES | 7 sale ids, first 2: `19bfdbb0-7cf9-43d7-a71f-7b2f88749b51`, `20dbc6cd-1041-4e0c-bb53-e3cfed7cddcd` |
| 4 | `get_ci_daypart_v1` | weekday Thu visits+revenue_cents | fnb | `(5, 14400)` | `(5, 14400)` | YES | 5 sale ids, first 2: `2c84bbd5-35f8-46ae-b481-1d677a749698`, `40f521b1-642b-4559-8730-d59f6ceca7b4` |
| 5 | `get_ci_daypart_v1` | weekday Fri visits+revenue_cents | fnb | `(7, 18000)` | `(7, 18000)` | YES | 7 sale ids, first 2: `0a4d64bf-44fb-4c32-921b-dc71a46dcda2`, `2c86c24b-4f19-4965-b53b-2a328c7d5685` |
| 6 | `get_ci_daypart_v1` | weekday Sat visits+revenue_cents | fnb | `(6, 14400)` | `(6, 14400)` | YES | 6 sale ids, first 2: `05589148-a5d3-4097-9e86-139265e15a36`, `5c8a7937-3a37-4685-82ff-1d9e371e5e27` |
| 7 | `get_ci_daypart_v1` | weekday Sun visits+revenue_cents | fnb | `(2, 6000)` | `(2, 6000)` | YES | 2 sale ids: `84541f4d-b3ce-43dd-8b0a-a0998f9d93e2`, `950b5273-0c9b-4b54-9ab2-07347ab5b061` |
| 8 | `get_ci_daypart_v1` | weekday Mon visits+revenue_cents | salon | `(2, 20400)` | `(2, 20400)` | YES | 2 sale ids: `9fbe85b6-155b-4919-b619-64926647711d`, `d65b9072-ce97-4eda-941e-d4f903af0698` |
| 9 | `get_ci_daypart_v1` | weekday Tue visits+revenue_cents | salon | `(5, 74800)` | `(5, 74800)` | YES | 5 sale ids, first 2: `18e078ad-521f-48bd-8508-4a1f521816b8`, `5adbb49b-07aa-4cbf-8ede-f28e4cce8d64` |
| 10 | `get_ci_daypart_v1` | weekday Wed visits+revenue_cents | salon | `(11, 163200)` | `(11, 163200)` | YES | 11 sale ids, first 2: `1712f0ff-5018-44e6-ae97-1699af598bb8`, `30432d25-6abd-4508-b422-872b3288aaa2` |
| 11 | `get_ci_daypart_v1` | weekday Thu visits+revenue_cents | salon | `(7, 95200)` | `(7, 95200)` | YES | 7 sale ids, first 2: `06629bd0-7f01-4d78-9634-0def8afd0aba`, `47863c07-e8b0-41ea-9bb6-95d32aa5e12e` |
| 12 | `get_ci_daypart_v1` | weekday Fri visits+revenue_cents | salon | `(3, 40800)` | `(3, 40800)` | YES | 3 sale ids, first 2: `7e88acbc-4a47-4530-a443-eb51629b7255`, `a8d7139b-7884-4350-b917-8eed5633e9cd` |
| 13 | `get_ci_daypart_v1` | weekday Sat visits+revenue_cents | salon | `(8, 108800)` | `(8, 108800)` | YES | 8 sale ids, first 2: `224afdd9-327f-4247-9eca-edb7e33830c4`, `36751994-fd65-4b21-ac1f-ebc4abb89504` |
| 14 | `get_ci_daypart_v1` | weekday Sun visits+revenue_cents | salon | `(6, 88400)` | `(6, 88400)` | YES | 6 sale ids, first 2: `2764a7c8-6c04-44ae-af3b-b398a4aecf25`, `4e75818b-9da1-427f-9913-d459f3bcf424` |
| 15 | `get_ci_daypart_v1` | weekday Mon visits+revenue_cents | fitness | `(5, 49500)` | `(5, 49500)` | YES | 5 sale ids, first 2: `29ebdd21-ebd4-4ca9-b608-59efc75f29e3`, `62099b60-835b-4716-9fc5-4f4234dc040a` |
| 16 | `get_ci_daypart_v1` | weekday Tue visits+revenue_cents | fitness | `(1, 5500)` | `(1, 5500)` | YES | 1 sale id: `851083c1-a7d6-4a8e-b49e-af78024494bc` |
| 17 | `get_ci_daypart_v1` | weekday Wed visits+revenue_cents | fitness | `(1, 11000)` | `(1, 11000)` | YES | 1 sale id: `08cf4c22-56a9-4aa1-8669-799816d78b0e` |
| 18 | `get_ci_daypart_v1` | weekday Thu visits+revenue_cents | fitness | `(5, 60500)` | `(5, 60500)` | YES | 5 sale ids, first 2: `2986aac9-6aa5-4df5-abab-bd181dbbbf42`, `4df9465d-a6f4-4e2d-9935-6f14c8f3cfc5` |
| 19 | `get_ci_daypart_v1` | weekday Fri visits+revenue_cents | fitness | `(7, 77000)` | `(7, 77000)` | YES | 7 sale ids, first 2: `2d2687f9-72a2-45d6-98fc-42cb712d881b`, `4efb0fa6-03bf-42a4-9f4e-5b2d8163c62a` |
| 20 | `get_ci_daypart_v1` | weekday Sat visits+revenue_cents | fitness | `(1, 22000)` | `(1, 22000)` | YES | 1 sale id: `480720a2-7c32-4a46-9e83-22b89d3236d8` |
| 21 | `get_ci_daypart_v1` | weekday Sun visits+revenue_cents | fitness | `(4, 49500)` | `(4, 49500)` | YES | 4 sale ids, first 2: `1c5710f3-4157-4ced-8d03-b5abd7f3df2e`, `2f3691bb-5431-4fe7-b270-8b466b7c11d1` |
| 22 | `get_ci_funnel_conversion_v1` | stage_1_to_2 numerator/denominator | fnb | `(8, 10)` | `(8, 10)` | YES | mature_first population n=10, first 2: `0cde3b9c-0db8-47ca-8794-2b112af729f7`, `16135887-ab7b-4aa8-8f88-99066cac3b45` |
| 23 | `get_ci_funnel_conversion_v1` | stage_2_to_3 numerator/denominator | fnb | `(7, 8)` | `(7, 8)` | YES | mature_second n=8, first 2: `0cde3b9c-0db8-47ca-8794-2b112af729f7`, `16fd76ed-23cd-4b9e-a18e-26e1f353587d` |
| 24 | `get_ci_funnel_conversion_v1` | stage_1_to_2 numerator/denominator | salon | `(8, 11)` | `(8, 11)` | YES | mature_first n=11, first 2: `1ee4d8f0-d50b-4207-95f0-0525d25a01b0`, `31c3c200-0c68-4325-9b94-1cd3169f1463` |
| 25 | `get_ci_funnel_conversion_v1` | stage_2_to_3 numerator/denominator | salon | `(6, 8)` | `(6, 8)` | YES | mature_second n=8, first 2: `1ee4d8f0-d50b-4207-95f0-0525d25a01b0`, `31c3c200-0c68-4325-9b94-1cd3169f1463` |
| 26 | `get_ci_funnel_conversion_v1` | stage_1_to_2 numerator/denominator | fitness | `(3, 5)` | `(3, 5)` | YES | mature_first n=5, first 2: `2a447cfa-f2a2-4f54-b94c-c6540782779c`, `d80a3d85-ee25-4935-99e1-e8346cf0eec2` |
| 27 | `get_ci_funnel_conversion_v1` | stage_2_to_3 numerator/denominator | fitness | `(1, 3)` | `(1, 3)` | YES | mature_second n=3, first 2: `d80a3d85-ee25-4935-99e1-e8346cf0eec2`, `e3597a10-46fa-4b2a-83e6-3c85dfd0c01e` |
| 28 | `get_ci_retention_windows_v1` | cohort 2026-05, 30-day window numerator/denominator | fnb | `(3, 5)` | `(3, 5)` | YES | cohort: `16135887…`, `16fd76ed…`, `6297202c…`, `9b7fca0f…`, `e6ff2927…`; returned-in-30: `16fd76ed…`, `6297202c…`, `9b7fca0f…` |
| 29 | `get_ci_retention_windows_v1` | cohort 2026-05, 30-day window numerator/denominator | salon | `(4, 5)` | `(4, 5)` | YES | cohort: `528a90b9…`, `65067031…`, `a9219925…`, `dfc2a201…`, `fb857f01…`; returned-in-30: `65067031…`, `a9219925…`, `dfc2a201…`, `fb857f01…` |
| 30 | `get_ci_retention_windows_v1` | cohort 2026-05, 30-day window numerator/denominator | fitness | `(1, 2)` | `(1, 2)` | YES | cohort: `e687d1e0…`, `ea166052…`; returned-in-30: `e687d1e0…` |
| 31 | `get_ci_discount_dependency_v1` | organic class n / population denominator | fnb | `(9, 13)` | `(9, 13)` | YES | organic n=9, first 2: `0cde3b9c…`, `16135887…` |
| 32 | `get_ci_discount_dependency_v1` | organic class n / population denominator | salon | `(8, 14)` | `(8, 14)` | YES | organic n=8, first 2: `1ee4d8f0…`, `31c3c200…` |
| 33 | `get_ci_discount_dependency_v1` | organic class n / population denominator | fitness | `(4, 8)` | `(4, 8)` | YES | organic n=4, first 2: `4f856b69…`, `99084a9f…` |
| 34 | `app.v179_business_insights` | retention.new_customers | fnb | `13` | `13` | YES | n=13, first 2: `0cde3b9c…`, `16135887…` |
| 35 | `app.v179_business_insights` | retention.new_customers | salon | `14` | `14` | YES | n=14, first 2: `1ee4d8f0…`, `31c3c200…` |
| 36 | `app.v179_business_insights` | retention.new_customers | fitness | `8` | `8` | YES | n=8, first 2: `2a447cfa…`, `4f856b69…` |
| 37 | `app.v179_business_insights` | at_risk.customers | fnb | `5` | `5` | YES | `16fd76ed…`, `6297202c…`, `84e7a37b…`, `9b7fca0f…`, `c757cafd…` |
| 38 | `app.v179_business_insights` | at_risk.customers | salon | `5` | `5` | YES | `65067031…`, `7b678728…`, `a9219925…`, `c00dc1f3…`, `fb857f01…` |
| 39 | `app.v179_business_insights` | at_risk.customers | fitness | `1` | `1` | YES | `e687d1e0…` |
| 40 | `get_ci_category_mix_v1` | coverage.stampable_revenue_cents | fnb | `0` | `0` | YES | 0 `public.sale_items` rows for this business (direct `COUNT`) |
| 41 | `get_ci_category_mix_v1` | coverage.stampable_revenue_cents | salon | `0` | `0` | YES | 0 `public.sale_items` rows for this business (direct `COUNT`) |
| 42 | `get_ci_category_mix_v1` | coverage.stampable_revenue_cents | fitness | `0` | `0` | YES | 0 `public.sale_items` rows for this business (direct `COUNT`) |
| 43 | `get_ci_demographics_v1` | coverage.demographics numerator/denominator | fnb | `(0, 13)` | `(0, 13)` | YES | 0 clients with `birth_date`/`gender` set; denominator = identified-customer population (row 34's set) |
| 44 | `get_ci_demographics_v1` | coverage.demographics numerator/denominator | salon | `(0, 14)` | `(0, 14)` | YES | 0 clients with `birth_date`/`gender` set; denominator = row 35's set |
| 45 | `get_ci_demographics_v1` | coverage.demographics numerator/denominator | fitness | `(0, 8)` | `(0, 8)` | YES | 0 clients with `birth_date`/`gender` set; denominator = row 36's set |
| 46 | `get_ci_opportunities_v1` (extended) | rank1 `data_quality_coverage`: affected_customers.n + unclassified revenue_cents | fnb | `(13, 102000)` | `(13, 102000)` | YES | 13 client ids, first 2: `0cde3b9c…`, `16135887…` |
| 47 | `get_ci_opportunities_v1` (extended) | rank1 `data_quality_coverage`: affected_customers.n + unclassified revenue_cents | salon | `(14, 591600)` | `(14, 591600)` | YES | 14 client ids, first 2: `1ee4d8f0…`, `31c3c200…` |
| 48 | `get_ci_opportunities_v1` (extended) | rank1 `data_quality_coverage`: affected_customers.n + unclassified revenue_cents | fitness | `(8, 253000)` | `(8, 253000)` | YES | 8 client ids, first 2: `2a447cfa…`, `4f856b69…` |
| 49 | `get_ci_opportunities_v1` (extended) | rank2 `strength:weekday:N` (argmax revenue_per_visit among evidence-ok days) | fnb | `(dow 4, 5, 14400)` | `(dow 4, 5, 14400)` | YES | dow 4 sale ids, first 2: `2c84bbd5…`, `40f521b1…` (row 4's set) |
| 50 | `get_ci_opportunities_v1` (extended) | rank2 `strength:weekday:N` (argmax revenue_per_visit among evidence-ok days) | salon | `(dow 2, 5, 74800)` | `(dow 2, 5, 74800)` | YES | dow 2 sale ids, first 2: `18e078ad…`, `5adbb49b…` (row 9's set) |
| 51 | `get_ci_opportunities_v1` (extended) | rank2 `strength:weekday:N` (argmax revenue_per_visit among evidence-ok days) | fitness | `(dow 4, 5, 60500)` | `(dow 4, 5, 60500)` | YES | dow 4 sale ids, first 2: `2986aac9…`, `4df9465d…` (row 18's set) |

## Sources exercised but not included in the 51 above

`get_ci_staff_performance_v1` and `get_ci_loyalty_programmes_v1` were both called successfully
against all three businesses (envelope + gating verified, no errors) but returned structurally
empty results for this corpus — `"staff": []` (the golden seeder's sales carry no `staff_id`
attribution) and `"active_programme": {"is_running": false, ...}` (no loyalty programme was
configured for these synthetic businesses) respectively. Both are honest, reproducible zero/empty
states (independently confirmed: 0 rows in any staff-commission-bearing sale, 0 rows in
`business_programmes` for these ids) but were left out of the 51 as duplicative of the
already-included `get_ci_category_mix_v1` / `get_ci_demographics_v1` "confirmed-zero" entries
rather than padding the count with more trivial zeros. `get_ci_discovery_v1` was also called
successfully for all three (0 candidates survived Benjamini-Hochberg at q=0.10 given the small
per-segment n — consistent with the corpus's own client counts of 8-14) but its BH-correction
machinery was judged out of scope for hand reproduction within this task's budget, so it is
recorded here as exercised-not-reproduced rather than silently omitted.

## What this proof does and does not establish

- **Does establish:** for three independently-seeded synthetic businesses spanning three sectors,
  51 headline numbers pulled from 9 of the 11 listed CI reader RPCs reconcile exactly, to the
  record-id level, against hand-written SQL over the base tables that never calls the RPC under
  test and never reads its return value as an input.
- **Does not establish:** external, disinterested review. The header on this document and the
  blank sign-off block below are the honest statement of that gap — this was written by an agent
  that works in the same codebase as the readers under test (though not the author of this
  specific commit history), which is a materially different thing from the checklist's own
  wording, "an independent reviewer must reproduce all 50."
- Two of the eleven listed sources (`get_ci_discovery_v1`'s discovery/BH-correction body, and the
  `staff`/`loyalty` empty-state sources) were exercised but not carried into the 51-row
  reproduction table, for the reasons stated above — not a hidden failure, just a scope line drawn
  explicitly rather than padded.

## Sign-off

- Named independent reviewer: **______________________** (blank — not yet performed)
- Date: **______________________**
- Verdict: **______________________**

## Cleanup

Scratch SQL files, captured RPC JSON dumps, and the `psql` probe scripts used to build this
document were written under a local scratch directory outside the repository and have been
deleted. The `--keep` Postgres cluster this proof ran against (`127.0.0.1:65344`, data directory
under `$TMPDIR/peekaa-db-tests-*`) was stopped after this document was written; nothing here
required or touched production (`gadpooereceldfpfxsod`).
