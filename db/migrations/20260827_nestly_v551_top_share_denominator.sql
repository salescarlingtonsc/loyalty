-- nestly_v551 — the top-customer share names its denominator, and the total-revenue share exists.
--
-- WHAT WAS WRONG (AI-004), measured read-only on production 2026-08-26. QA Kaya Toast, monthly
-- 2026-08: top1_share_pct = 84.0 — which is 554150 / 659650, the top customer's share of
-- IDENTIFIED revenue (window_revenue), not of total revenue (660150, share 83.9). The ratio is
-- internally consistent, so the maths was right — but neither the field name nor the system
-- prompt said which denominator, and the mandate calls this out specifically. At today's 99.9%
-- identified share the two numbers barely differ; at an F&B tenant with heavy anonymous walk-ins
-- they diverge wildly, and the model would present the identified-only concentration as if it
-- described the whole business.
--
-- WHAT THIS DOES (no number changes; names and additions only):
--   * top1_share_pct  -> top1_share_of_identified_revenue_pct   (expression untouched)
--   * top5_share_pct  -> top5_share_of_identified_revenue_pct   (expression untouched)
--   * NEW top1_share_of_total_revenue_pct / top5_share_of_total_revenue_pct — the same
--     numerators over window_all_revenue (v548's headline population), so the model can quote a
--     concentration figure that covers all revenue, anonymous included.
--   * The system prompt ships alongside: quote the total-revenue share by default, name the
--     denominator when using the identified one.
--
-- The only consumer of the old names is the ai-firm-reports prompt (verified by grep across
-- app/, supabase/functions/ and db/migrations/); no UI reads them.
--
-- ROLLBACK: db/tests/v551_top_share_denominator.sql

begin;

do $patch$
declare d text; n text;
begin
  select pg_get_functiondef(p.oid) into d
    from pg_proc p join pg_namespace ns on ns.oid=p.pronamespace
   where ns.nspname='app' and p.proname='v179_business_insights';
  if d is null then raise exception 'v551: app.v179_business_insights is missing'; end if;

  if position('top1_share_of_identified_revenue_pct' in d) > 0 then
    raise notice 'v551: top shares already name their denominator';
    return;
  end if;
  if position('window_all_revenue' in d) = 0 then
    raise exception 'v551: v548 must be applied first (window_all_revenue is missing)';
  end if;

  -- the two new total-denominator fields, inserted where the old top1 field began
  n := replace(d, '''top1_share_pct'', (',
'''top1_share_of_total_revenue_pct'', (
        select case when wa.total_cents = 0 then null
          else round(100.0 * (select max(revenue_cents) from window_clients) / wa.total_cents, 1) end
        from window_all_revenue wa
      ),
      ''top5_share_of_total_revenue_pct'', (
        select case when wa.total_cents = 0 then null
          else round(100.0 * (
            select coalesce(sum(revenue_cents), 0)
              from (select revenue_cents from window_clients order by revenue_cents desc limit 5) top5
          ) / wa.total_cents, 1) end
        from window_all_revenue wa
      ),
      /* v551: the expressions below are the PRE-v551 fields verbatim — only the names changed,
         to say what the denominator has always been. */
      ''top1_share_of_identified_revenue_pct'', (');
  if n = d then raise exception 'v551: top1_share_pct anchor not found'; end if;
  d := n;

  n := replace(d, '''top5_share_pct'', (', '''top5_share_of_identified_revenue_pct'', (');
  if n = d then raise exception 'v551: top5_share_pct anchor not found'; end if;

  execute n;
  raise notice 'v551: top shares name their denominator, total-revenue shares added';
end
$patch$;

do $verify$
declare d text;
begin
  select pg_get_functiondef(p.oid) into d
    from pg_proc p join pg_namespace ns on ns.oid=p.pronamespace
   where ns.nspname='app' and p.proname='v179_business_insights';
  if position('''top1_share_pct''' in d) > 0 or position('''top5_share_pct''' in d) > 0 then
    raise exception 'v551: an undisclosed-denominator field survived';
  end if;
  if position('top1_share_of_total_revenue_pct' in d) = 0 then
    raise exception 'v551: the total-revenue share is missing';
  end if;
end
$verify$;

commit;
