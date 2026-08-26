-- Rollback-only acceptance for nestly_v551 — the top-customer share names its denominator.
-- Run: supabase db query --linked -f db/tests/v551_top_share_denominator.sql
-- Any row whose value starts with FAIL is a failure. Nothing is committed.
--
-- v551 renamed app.v179_business_insights' top_customers fields top1_share_pct/top5_share_pct to
-- top1_share_of_identified_revenue_pct/top5_share_of_identified_revenue_pct (expressions
-- untouched), and added top1_share_of_total_revenue_pct/top5_share_of_total_revenue_pct — the same
-- numerators over window_all_revenue, v548's headline population.
--
--   01  neither top1_share_pct nor top5_share_pct appears among top_customers' keys
--   02  top1_share_of_identified_revenue_pct matches an INDEPENDENT recomputation: the max
--       per-client identified revenue over the identified total
--   03  top1_share_of_total_revenue_pct matches the same numerator over the total (unfiltered)
--       revenue; and the total-denominator share is always <= the identified-denominator share
--   04  internal consistency with v548's identification block: identified-share revenue and
--       total-share revenue for top1 must agree within a small rounding tolerance
--
-- ROLLBACK OF THE MIGRATION ITSELF: v551 patched v179_business_insights by text substitution from
-- its live body; the migration file quotes the pre-v551 field expressions verbatim (they are
-- unchanged, only renamed) inside the replacement string. To revert, restore the two old key names
-- (`top1_share_pct` / `top5_share_pct`) in front of those same expressions and drop the two new
-- total-denominator fields. The edge function's system prompt
-- (supabase/functions/ai-firm-reports/index.ts) ships alongside this migration and tells the model
-- which of the two shares to quote by default; reverting the SQL without reverting that prompt
-- leaves the model told to read fields that no longer exist.

begin;

create temp table _r(check_id text, value text) on commit drop;

-- 01 — the old undisclosed-denominator keys must be gone
do $names$
declare b record; ev jsonb; tc jsonb; bad integer := 0; note text := '';
begin
  for b in
    select bs.id, bs.name from public.businesses bs
     where exists (select 1 from public.sales s where s.business_id = bs.id)
     order by bs.name
  loop
    ev := app.v179_business_insights(b.id, (current_date - 30), current_date,
                                     (current_date - 60), (current_date - 31));
    tc := ev->'top_customers';
    if tc ? 'top1_share_pct' or tc ? 'top5_share_pct' then
      bad := bad + 1;
      note := note || format('[%s keys=%s] ', b.name,
        (select string_agg(k, ',') from jsonb_object_keys(tc) k));
    end if;
  end loop;
  insert into _r values ('01 undisclosed-denominator keys absent',
    case when bad = 0 then 'PASS' else format('FAIL %s business(es): %s', bad, note) end);
end
$names$;

-- 02 — top1_share_of_identified_revenue_pct against an INDEPENDENT recomputation from raw
--      public.sales, replicating v179's identified-customer population (client_id not null, not
--      reversed, not a reversal, joined to a non-synthetic client, v176's window bounds).
do $ident$
declare
  b record; ev jsonb;
  reported numeric; total_ident bigint; max_client bigint; expected numeric;
  bad integer := 0; note text := '';
begin
  for b in
    select bs.id, bs.name from public.businesses bs
     where exists (select 1 from public.sales s where s.business_id = bs.id)
     order by bs.name
  loop
    ev := app.v179_business_insights(b.id, (current_date - 30), current_date,
                                     (current_date - 60), (current_date - 31));
    reported := (ev->'top_customers'->>'top1_share_of_identified_revenue_pct')::numeric;

    select coalesce(sum(s.amount_cents), 0) into total_ident
      from public.sales s
      join public.clients c on c.id = s.client_id and c.business_id = s.business_id
     where s.business_id = b.id
       and s.client_id is not null
       and s.reversal_of is null
       and coalesce(c.is_synthetic, false) = false
       and s.occurred_at >= (current_date - 30)::timestamp at time zone 'Asia/Singapore'
       and s.occurred_at <  (current_date + 1)::timestamp at time zone 'Asia/Singapore'
       and coalesce(s.counts_as_revenue, true)
       and not exists(
         select 1 from public.sales r
          where r.business_id = s.business_id and r.reversal_of = s.id
       );

    select max(client_total) into max_client from (
      select s.client_id, sum(s.amount_cents) as client_total
        from public.sales s
        join public.clients c on c.id = s.client_id and c.business_id = s.business_id
       where s.business_id = b.id
         and s.client_id is not null
         and s.reversal_of is null
         and coalesce(c.is_synthetic, false) = false
         and s.occurred_at >= (current_date - 30)::timestamp at time zone 'Asia/Singapore'
         and s.occurred_at <  (current_date + 1)::timestamp at time zone 'Asia/Singapore'
         and coalesce(s.counts_as_revenue, true)
         and not exists(
           select 1 from public.sales r
            where r.business_id = s.business_id and r.reversal_of = s.id
         )
       group by s.client_id
    ) per_client;

    expected := case when total_ident is null or total_ident = 0 then null
                      else round(100.0 * max_client / total_ident, 1) end;

    if (reported is null) is distinct from (expected is null)
       or (reported is not null and reported is distinct from expected) then
      bad := bad + 1;
      note := note || format('[%s reported=%s expected=%s max_client=%s total_ident=%s] ',
        b.name, reported, expected, max_client, total_ident);
    end if;
  end loop;
  insert into _r values ('02 top1 identified-share matches independent recomputation',
    case when bad = 0 then 'PASS' else format('FAIL %s: %s', bad, note) end);
end
$ident$;

-- 03 — top1_share_of_total_revenue_pct against the SAME numerator (max identified client revenue)
--      over the total (unfiltered, no client join) revenue; and total-denominator share must
--      never exceed identified-denominator share (a bigger denominator can only shrink the share).
do $total$
declare
  b record; ev jsonb;
  reported_total numeric; reported_ident numeric;
  total_all bigint; max_client bigint; expected numeric;
  bad integer := 0; note text := '';
begin
  for b in
    select bs.id, bs.name from public.businesses bs
     where exists (select 1 from public.sales s where s.business_id = bs.id)
     order by bs.name
  loop
    ev := app.v179_business_insights(b.id, (current_date - 30), current_date,
                                     (current_date - 60), (current_date - 31));
    reported_total := (ev->'top_customers'->>'top1_share_of_total_revenue_pct')::numeric;
    reported_ident := (ev->'top_customers'->>'top1_share_of_identified_revenue_pct')::numeric;

    select coalesce(sum(s.amount_cents), 0) into total_all
      from public.sales s
     where s.business_id = b.id
       -- v551 fix to this suite itself: the first draft filtered client_id IS NOT NULL here,
       -- rebuilding the identified population and calling it "total" - the exact defect this
       -- wave exists to kill, reproduced inside the oracle. The total population has NO client
       -- filter and NO clients join; anonymous sales belong in it.
       and s.reversal_of is null
       and s.occurred_at >= (current_date - 30)::timestamp at time zone 'Asia/Singapore'
       and s.occurred_at <  (current_date + 1)::timestamp at time zone 'Asia/Singapore'
       and coalesce(s.counts_as_revenue, true)
       and not exists(
         select 1 from public.sales r
          where r.business_id = s.business_id and r.reversal_of = s.id
       );
    -- note: "total" here follows window_all_revenue's population (no client-existence/synthetic
    -- filter is meaningful once client_id is dropped from the join — client_id not null is kept
    -- because top_customers' numerator is defined only over rows with a client_id at all); the
    -- only structural difference from check 02's denominator is the removal of the clients join.

    select max(client_total) into max_client from (
      select s.client_id, sum(s.amount_cents) as client_total
        from public.sales s
        join public.clients c on c.id = s.client_id and c.business_id = s.business_id
       where s.business_id = b.id
         and s.client_id is not null
         and s.reversal_of is null
         and coalesce(c.is_synthetic, false) = false
         and s.occurred_at >= (current_date - 30)::timestamp at time zone 'Asia/Singapore'
         and s.occurred_at <  (current_date + 1)::timestamp at time zone 'Asia/Singapore'
         and coalesce(s.counts_as_revenue, true)
         and not exists(
           select 1 from public.sales r
            where r.business_id = s.business_id and r.reversal_of = s.id
         )
       group by s.client_id
    ) per_client;

    expected := case when total_all is null or total_all = 0 then null
                      else round(100.0 * max_client / total_all, 1) end;

    if (reported_total is null) is distinct from (expected is null)
       or (reported_total is not null and reported_total is distinct from expected) then
      bad := bad + 1;
      note := note || format('[%s total-share reported=%s expected=%s max_client=%s total_all=%s] ',
        b.name, reported_total, expected, max_client, total_all);
    end if;

    if reported_total is not null and reported_ident is not null
       and reported_total > reported_ident then
      bad := bad + 1;
      note := note || format('[%s total-share %s exceeds identified-share %s] ',
        b.name, reported_total, reported_ident);
    end if;
  end loop;
  insert into _r values ('03 top1 total-share matches recomputation and never exceeds identified-share',
    case when bad = 0 then 'PASS' else format('FAIL %s: %s', bad, note) end);
end
$total$;

-- 04 — internal consistency with v548's identification block. Both shares describe the SAME
--      top1 client's revenue, just over different denominators, so:
--        top1_of_identified_pct * identified_revenue_cents  ~=  top1_of_total_pct * total_revenue_cents
--      (both equal 100 * top1_client_revenue_cents). Tolerance: 0.15 percentage-point equivalent,
--      i.e. the two reconstructed top1_client_revenue_cents values may differ by at most
--      0.15/100 * total_revenue_cents, covering the rounding of each share to one decimal place.
do $consistency$
declare
  b record; ev jsonb; ident jsonb; tc jsonb;
  ident_pct numeric; total_pct numeric; ident_rev bigint; total_rev bigint;
  recon_from_ident numeric; recon_from_total numeric; tolerance numeric;
  bad integer := 0; note text := '';
begin
  for b in
    select bs.id, bs.name from public.businesses bs
     where exists (select 1 from public.sales s where s.business_id = bs.id)
     order by bs.name
  loop
    ev := app.v179_business_insights(b.id, (current_date - 30), current_date,
                                     (current_date - 60), (current_date - 31));
    ident := ev->'identification';
    tc := ev->'top_customers';

    ident_pct := (tc->>'top1_share_of_identified_revenue_pct')::numeric;
    total_pct := (tc->>'top1_share_of_total_revenue_pct')::numeric;
    ident_rev := (ident->>'identified_revenue_cents')::bigint;
    total_rev := (ident->>'total_revenue_cents')::bigint;

    if ident_pct is null or total_pct is null or ident_rev is null or total_rev is null then
      continue; -- no revenue at all: check 04's null case is covered by checks 02/03
    end if;

    recon_from_ident := ident_pct / 100.0 * ident_rev;
    recon_from_total := total_pct / 100.0 * total_rev;
    tolerance := 0.15 / 100.0 * total_rev + 1; -- +1 cent for integer rounding slack

    if abs(recon_from_ident - recon_from_total) > tolerance then
      bad := bad + 1;
      note := note || format(
        '[%s recon_from_ident=%s recon_from_total=%s tolerance=%s ident_pct=%s total_pct=%s] ',
        b.name, recon_from_ident, recon_from_total, tolerance, ident_pct, total_pct);
    end if;
  end loop;
  insert into _r values ('04 identified-share and total-share reconstruct the same top1 revenue',
    case when bad = 0 then 'PASS' else format('FAIL %s: %s', bad, note) end);
end
$consistency$;

select check_id, value from _r order by check_id;

rollback;
