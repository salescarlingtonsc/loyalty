-- NESTLY v672 — one statistical authority for every subgroup surface.
--
-- Phase CI-B of the rescoped Customer Intelligence program
-- (docs/qa/CI-ACCEPTANCE-VERDICT-2026-09-02.md). The proof baseline's check 61 found three
-- mutually inconsistent hardcoded sample floors (5, 10, and a 20-txn/10-customer/4-week
-- combination) in three engines, and cohorts in the AI evidence pack with no floor at all — a
-- 1-customer cohort got a rate and a dollar figure as confidently as a 500-customer one. The
-- fix is not a fourth floor; it is ONE authority that every subgroup reader embeds, so the
-- floor, the numerator/denominator discipline, and the skew sensitivity live in exactly one
-- place and every future reader inherits them by calling, not by copying.
--
-- Four small pure functions. Every one is IMMUTABLE, takes no table access, and returns a
-- jsonb block a reader embeds verbatim, so readers stay set-based and the authority stays
-- trivially provable. Contract frozen by docs/design/ci/CI-STAT-AUTHORITY-CONTRACT.md; the
-- executed truth-table fixture is db/tests/executed/v672_corpus_stat_authority.sql.
--
--   subgroup_evidence_v1  the sample floor. k=5 default — the same convention v667 adopted
--                         for small-cell identity suppression, now shared by value surfaces.
--   rate_block_v1         a rate that always travels with its numerator and denominator, and
--                         refuses to manufacture 0.0% from an empty denominator (the
--                         consultant-brief lesson, made structural).
--   distribution_block_v1 mean AND median AND top-share AND leave-one-out, so a skewed
--                         segment cannot hide behind its mean (check 66). skew_material when
--                         the top value carries >= 30% of the total or mean/median >= 1.5.
--   comparisons_note_v1   discovery bookkeeping (check 69): how many subgroups were examined
--                         vs promoted, embedded so a reader of ten "findings" can see the two
--                         hundred comparisons behind them.

begin;

create or replace function app.subgroup_evidence_v1(p_n integer, p_floor integer default 5)
returns jsonb
language sql immutable
set search_path to 'pg_catalog', 'pg_temp'
as $$
  select jsonb_build_object(
    'n', coalesce(p_n, 0),
    'floor', greatest(1, coalesce(p_floor, 5)),
    'status', case when coalesce(p_n, 0) >= greatest(1, coalesce(p_floor, 5))
                   then 'ok' else 'insufficient' end);
$$;
revoke all on function app.subgroup_evidence_v1(integer,integer) from public, anon, authenticated;
grant execute on function app.subgroup_evidence_v1(integer,integer) to authenticated, service_role;

create or replace function app.rate_block_v1(p_num bigint, p_den bigint)
returns jsonb
language sql immutable
set search_path to 'pg_catalog', 'pg_temp'
as $$
  select jsonb_build_object(
    'numerator', coalesce(p_num, 0),
    'denominator', coalesce(p_den, 0),
    'pct', case when coalesce(p_den, 0) > 0
                then round(100.0 * coalesce(p_num, 0) / p_den, 1)
                else null end);
$$;
revoke all on function app.rate_block_v1(bigint,bigint) from public, anon, authenticated;
grant execute on function app.rate_block_v1(bigint,bigint) to authenticated, service_role;

create or replace function app.distribution_block_v1(p_values numeric[])
returns jsonb
language sql immutable
set search_path to 'pg_catalog', 'pg_temp'
as $$
  with vals as (
    select v from unnest(coalesce(p_values, '{}'::numeric[])) as v where v is not null
  ),
  agg as (
    select count(*)::int as n,
           sum(v) as total,
           avg(v) as mean,
           percentile_cont(0.5) within group (order by v) as median,
           percentile_cont(0.9) within group (order by v) as p90,
           max(v) as top1
      from vals
  )
  select case when n = 0 then jsonb_build_object('n', 0)
  else jsonb_build_object(
    'n', n,
    'mean', round(mean, 2),
    'median', round(median::numeric, 2),
    'p90', round(p90::numeric, 2),
    'top1_share_bps', case when total > 0 then (10000.0 * top1 / total)::int else null end,
    'skew_material',
      (total > 0 and (10000.0 * top1 / total) >= 3000)
      or (median > 0 and mean / median >= 1.5),
    -- the mean recomputed WITHOUT the single largest member — the "does the average story
    -- survive losing the whale" number. (For the SUM the leave-one-out delta is identically
    -- the top share, which is why no separate sum-delta key exists: the first draft shipped
    -- one, its expression was a copy of top1_share_bps, and the corpus fixture caught the
    -- duplication on first contact.)
    'mean_excl_top1',
      case when n > 1 then round((total - top1) / (n - 1), 2) else null end)
  end
  from agg;
$$;
revoke all on function app.distribution_block_v1(numeric[]) from public, anon, authenticated;
grant execute on function app.distribution_block_v1(numeric[]) to authenticated, service_role;

create or replace function app.comparisons_note_v1(p_examined integer, p_promoted integer)
returns jsonb
language sql immutable
set search_path to 'pg_catalog', 'pg_temp'
as $$
  select jsonb_build_object(
    'subgroups_examined', greatest(0, coalesce(p_examined, 0)),
    'subgroups_promoted', greatest(0, coalesce(p_promoted, 0)),
    'note', 'Promoted findings were selected from the examined set; treat borderline results as exploratory.');
$$;
revoke all on function app.comparisons_note_v1(integer,integer) from public, anon, authenticated;
grant execute on function app.comparisons_note_v1(integer,integer) to authenticated, service_role;

commit;
