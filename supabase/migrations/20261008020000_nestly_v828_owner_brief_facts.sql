-- NESTLY v828 — the owner brief answers the questions the audit found the data for.
--
-- WHY THIS EXISTS. nestly_v826 put a nightly brief at the top of the Home dashboard, composed
-- from seven existing readers. A read-only coverage audit (2026-09-08, executed against
-- production as a real owner) then walked the forty owner questions in the "Ask My Business"
-- report and found: ten answered by the brief, seven by Insights readers, two not captured at
-- all (weather, footfall), and about twenty where the DATA already exists but nothing composes
-- the answer. This migration adds those compositions as nineteen more nightly facts.
--
-- WHAT THIS MIGRATION DOES.
--   * app.owner_brief_fact_<name>_v828(p_business) — one function per fact, owner-only, each
--     built on the existing authorities (app.v176_sales_window's valid-sales filter,
--     app.ci_visit_day_v699 for visit-days, app.stamp_progress_v323's stamp arithmetic, the
--     gated readers get_dashboard_summary_v155 / get_reports_summary / get_ci_daypart_v1 under
--     the owner's claims). No new definition of revenue or visits anywhere.
--       money:   day, month, liability, points_expiry
--       items:   items (revenue and margin), dying, pairs, discounts, stock
--       people:  staff, multi_outlet, birthdays, member_lift, referrals, anomalies
--       ahead:   stamps, bookings_ahead, memberships_due, slot_trend
--     Every fact fails closed: too little data → evidence 'insufficient' with null figures; a
--     component whose table does not exist → null with a note; an exception → status
--     'unavailable' with the reason. Nothing is ever estimated.
--   * app.owner_brief_compose_v828 — the v826 seven facts plus a `facts` object holding the
--     nineteen above, each in its own failure domain.
--   * app.refresh_owner_brief_v826 — restated to call the v828 composer. Same loop, same owner
--     impersonation, same snapshot table, same cron slot.
--
-- WHAT THIS MIGRATION DOES NOT DO. No new reader for the browser: public.get_owner_brief_v1
-- returns the whole payload as before; the card renders what it finds. No new tables. No cron
-- change. No WhatsApp.
--
-- ACCEPTANCE: db/tests/v828_owner_brief_facts.sql (rolled back against production).

begin;

-- =============================================================================================
-- fragment: money
-- =============================================================================================
-- nestly_v828 fragment: money — four owner-brief facts.
-- Style matches app.owner_brief_compose_v826 (db/migrations/20261007_nestly_v826_owner_brief.sql):
-- each fact wrapped in its own exception block, cents as integers, evidence floors, 'source'
-- naming the reader/table used. Reuses existing readers/authorities only — no new definition of
-- revenue, visits, or the loyalty pot:
--   app.v176_sales_window            -- valid-sales window (reversal-safe, synthetic-excluded)
--   public.get_dashboard_summary_v155 -- revenue_by_day, visits (gated: view_sales + dashboard module)
--   public.get_reports_summary        -- credit_liability_cents, gift_card_liability_cents (gated: view_sales + reports module)
--   app.sv_available_balance          -- the PS-2 stored-value per-account balance authority
--   app.live_balance_programme_v381   -- the one accruing points/stamps programme
--   app.owner_brief_pct_v826          -- the shared delta-pct helper from v826

-- =============================================================================================
-- 1 · "How did we do yesterday, is that normal?"
-- =============================================================================================
create or replace function app.owner_brief_fact_day_v828(p_business uuid)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_to      date := app.sg_today() - 1;      -- yesterday: the last complete day
  v_from63  date := v_to - 62;                -- 63 days ending yesterday (one dashboard call)
  v_week    jsonb;
  v_day1    jsonb;
  v_rev     bigint;
  v_vis     bigint;
  v_brev    numeric;
  v_bpos    int;
  v_evid    text;
  v_delta   numeric;
  v_wdlabel text;
  v_fact    jsonb;
  v_err     text;
begin
  begin
    v_week := public.get_dashboard_summary_v155(p_business, v_from63, v_to, 'all', array[]::uuid[], null);
    v_day1 := public.get_dashboard_summary_v155(p_business, v_to, v_to, 'all', array[]::uuid[], null);

    with rd as (
      select (elem ->> 'day')::date as day, coalesce((elem ->> 'amount_cents')::bigint, 0) as amount_cents
      from jsonb_array_elements(coalesce(v_week -> 'revenue_by_day', '[]'::jsonb)) elem
    ), baseline as (
      -- the same weekday, once a week, for the eight weeks before yesterday (offsets 7..56)
      select rd.amount_cents
      from generate_series(1, 8) k
      join rd on rd.day = v_to - (7 * k)
    )
    select
      (select amount_cents from rd where day = v_to),
      avg(amount_cents),
      count(*) filter (where amount_cents > 0)
    into v_rev, v_brev, v_bpos
    from baseline;

    v_rev  := coalesce(v_rev, 0);
    v_vis  := coalesce((v_day1 ->> 'visits')::bigint, 0);
    v_evid := case when coalesce(v_bpos, 0) >= 6 then 'ok' else 'insufficient' end;
    v_delta := case when v_evid = 'ok' then app.owner_brief_pct_v826(v_rev, v_brev) end;
    v_wdlabel := trim(to_char(v_to, 'Day'));

    v_fact := jsonb_build_object(
      'status', 'ok',
      'source', 'public.get_dashboard_summary_v155',
      'yesterday', jsonb_build_object(
        'date', v_to,
        'weekday_label', v_wdlabel,
        'revenue_cents', v_rev,
        'visits', v_vis),
      'baseline', jsonb_build_object(
        'weeks', 8,
        'revenue_cents', round(coalesce(v_brev, 0)),
        'visits', null,
        'evidence', v_evid),
      'revenue_delta_pct', v_delta);
  exception when others then
    get stacked diagnostics v_err = message_text;
    v_fact := jsonb_build_object('status', 'unavailable', 'reason', left(v_err, 200),
                                  'source', 'public.get_dashboard_summary_v155');
  end;
  return v_fact;
end;
$$;
revoke all on function app.owner_brief_fact_day_v828(uuid) from public, anon, authenticated;

-- =============================================================================================
-- 2 · "This month so far, ahead or behind?"
-- =============================================================================================
create or replace function app.owner_brief_fact_month_v828(p_business uuid)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_to             date := app.sg_today() - 1;                         -- last complete day
  v_month_start    date := date_trunc('month', v_to)::date;
  v_days_elapsed   int  := v_to - v_month_start + 1;
  v_days_in_month  int  := ((date_trunc('month', v_month_start) + interval '1 month - 1 day')::date
                             - v_month_start + 1);
  v_prev_start     date := date_trunc('month', v_month_start - interval '1 month')::date;
  v_prev_month_end date := v_month_start - 1;                          -- last day of prior month
  v_prev_end       date := least(v_prev_start + (v_days_elapsed - 1), v_prev_month_end);
  v_mtd            jsonb;
  v_prev           jsonb;
  v_mtd_rev        bigint;
  v_prev_rev       bigint;
  v_delta          numeric;
  v_on_pace        numeric;
  v_fact           jsonb;
  v_err            text;
begin
  begin
    v_mtd  := app.v176_sales_window(p_business, v_month_start, v_to);
    v_prev := app.v176_sales_window(p_business, v_prev_start, v_prev_end);
    v_mtd_rev  := coalesce((v_mtd  ->> 'net_revenue_cents')::bigint, 0);
    v_prev_rev := coalesce((v_prev ->> 'net_revenue_cents')::bigint, 0);
    v_delta := app.owner_brief_pct_v826(v_mtd_rev, v_prev_rev);
    v_on_pace := case when v_days_elapsed > 0
                 then round(v_mtd_rev::numeric / v_days_elapsed * v_days_in_month) end;

    v_fact := jsonb_build_object(
      'status', 'ok',
      'source', 'app.v176_sales_window',
      'mtd', jsonb_build_object('from', v_month_start, 'to', v_to, 'revenue_cents', v_mtd_rev),
      'previous_month_same_days', jsonb_build_object(
        'from', v_prev_start, 'to', v_prev_end, 'revenue_cents', v_prev_rev),
      'revenue_delta_pct', v_delta,
      'days_elapsed', v_days_elapsed,
      'days_in_month', v_days_in_month,
      'on_pace_cents', v_on_pace);
  exception when others then
    get stacked diagnostics v_err = message_text;
    v_fact := jsonb_build_object('status', 'unavailable', 'reason', left(v_err, 200),
                                  'source', 'app.v176_sales_window');
  end;
  return v_fact;
end;
$$;
revoke all on function app.owner_brief_fact_month_v828(uuid) from public, anon, authenticated;

-- =============================================================================================
-- 3 · "If every customer redeemed tomorrow, what would it cost me?"
-- =============================================================================================
create or replace function app.owner_brief_fact_liability_v828(p_business uuid)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_to         date := app.sg_today();
  v_reports    jsonb;
  v_credit     bigint;
  v_giftcard   bigint;
  v_reward_cnt bigint;
  v_sv_state   text;
  v_sv_cents   bigint;
  v_sv_note    text;
  v_known      bigint;
  v_total_note text;
  v_fact       jsonb;
  v_err        text;
begin
  begin
    -- credit + gift-card liability: current, business-wide, exactly as Reports shows them
    v_reports := public.get_reports_summary(p_business, v_to, v_to, null);
    v_credit   := (v_reports ->> 'credit_liability_cents')::bigint;
    v_giftcard := (v_reports ->> 'gift_card_liability_cents')::bigint;

    -- (a) unredeemed / not-yet-expired reward grants: a COUNT, not money -- reward_grants mixes
    -- discount_pct / free_item / credit and reward_value is not uniformly cents, so it cannot be
    -- summed into one figure. status is one of granted|redeemed|expired (reward_grants_status_check);
    -- 'granted' is exactly unredeemed-and-not-yet-expired.
    select count(*) into v_reward_cnt
    from public.reward_grants g
    join public.clients c on c.id = g.client_id and c.business_id = g.business_id
    where g.business_id = p_business
      and g.status = 'granted'
      and not c.is_synthetic;

    -- (b) stored-value balance outstanding: only real once PS-2's authority for this business is
    -- 'live' (app.sv_authority.state) -- app.sv_available_balance is the PS-0 balance authority,
    -- per account (public.sv_accounts), so sum it across the business the same way
    -- get_reports_summary sums client_credit_balance (greatest(balance,0), synthetic excluded).
    select a.state into v_sv_state
    from public.sv_authority a
    where a.business_id = p_business and a.asset = 'stored_value';

    if v_sv_state = 'live' then
      select coalesce(sum(greatest(app.sv_available_balance(p_business, sa.id), 0)), 0)
        into v_sv_cents
      from public.sv_accounts sa
      join public.clients c on c.id = sa.client_id and c.business_id = sa.business_id
      where sa.business_id = p_business
        and sa.asset = 'stored_value'
        and not c.is_synthetic;
      v_sv_note := null;
    else
      v_sv_cents := null;
      v_sv_note := 'stored value authority is ' || coalesce(v_sv_state, 'unbuilt')
                   || ' for this business, not live -- no stored-value balance is owed yet';
    end if;

    v_known := coalesce(v_credit, 0) + coalesce(v_giftcard, 0) + coalesce(v_sv_cents, 0);
    v_total_note := case
      when v_credit is null or v_giftcard is null then 'partial: one or more Reports components are unavailable for this scope'
      when v_sv_cents is null then 'excludes stored value (not live for this business) and reward-grant value (not a uniform money figure)'
      else 'excludes reward-grant value (not a uniform money figure)'
      end;

    v_fact := jsonb_build_object(
      'status', 'ok',
      'as_of', v_to,
      'credit_liability_cents', v_credit,
      'gift_card_liability_cents', v_giftcard,
      'stored_value_liability_cents', v_sv_cents,
      'stored_value_note', v_sv_note,
      'unredeemed_reward_grants', jsonb_build_object(
        'count', v_reward_cnt,
        'note', 'count only, not money -- reward_grants mixes discount_pct/free_item/credit fulfilment kinds'),
      'known_cents_total', v_known,
      'known_cents_total_note', v_total_note,
      'source', 'public.get_reports_summary + public.reward_grants + app.sv_available_balance');
  exception when others then
    get stacked diagnostics v_err = message_text;
    v_fact := jsonb_build_object('status', 'unavailable', 'reason', left(v_err, 200),
                                  'source', 'public.get_reports_summary');
  end;
  return v_fact;
end;
$$;
revoke all on function app.owner_brief_fact_liability_v828(uuid) from public, anon, authenticated;

-- =============================================================================================
-- 4 · "How much expires unused?"
-- =============================================================================================
create or replace function app.owner_brief_fact_points_expiry_v828(p_business uuid)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_to       date := app.sg_today() - 1;   -- last complete day
  v_from     date := v_to - 89;            -- 90 days total, inclusive
  v_earned   bigint;
  v_expired  bigint;
  v_pct      numeric;
  v_evid     text;
  v_fact     jsonb;
  v_err      text;
begin
  begin
    -- entry_type is one of earn|redeem|expire|adjust (public.points_ledger); expire rows are
    -- stored negative (verified against prod: min/max of expire = -15/-15), earn rows positive.
    -- Scoped to the one live accruing programme (app.live_balance_programme_v381) and to
    -- non-synthetic clients, exactly the filters public.get_reports_summary's points block uses.
    select
      coalesce(sum(pl.points) filter (where pl.entry_type = 'earn'), 0),
      coalesce(-sum(pl.points) filter (where pl.entry_type = 'expire'), 0)
      into v_earned, v_expired
    from public.points_ledger pl
    join public.clients plc on plc.id = pl.client_id and plc.business_id = pl.business_id
    where pl.business_id = p_business
      and pl.programme_id = app.live_balance_programme_v381(p_business)
      and pl.created_at >= (v_from::timestamp at time zone 'Asia/Singapore')
      and pl.created_at <  ((v_to + 1)::timestamp at time zone 'Asia/Singapore')
      and not plc.is_synthetic;

    v_evid := case when v_earned >= 100 then 'ok' else 'insufficient' end;
    v_pct  := case when v_evid = 'ok' and v_earned > 0 then round(100.0 * v_expired / v_earned, 1) end;

    v_fact := jsonb_build_object(
      'status', 'ok',
      'source', 'public.points_ledger',
      'from', v_from, 'to', v_to,
      'earned_points', v_earned,
      'expired_points', v_expired,
      'expired_pct_of_earned', v_pct,
      'evidence', v_evid);
  exception when others then
    get stacked diagnostics v_err = message_text;
    v_fact := jsonb_build_object('status', 'unavailable', 'reason', left(v_err, 200),
                                  'source', 'public.points_ledger');
  end;
  return v_fact;
end;
$$;
revoke all on function app.owner_brief_fact_points_expiry_v828(uuid) from public, anon, authenticated;

-- =============================================================================================
-- fragment: items
-- =============================================================================================
-- nestly_v828 fragment "items" — five owner-brief facts about items/inventory/discounts.
-- Style matches db/migrations/20261007_nestly_v826_owner_brief.sql: per-fact exception block,
-- cents as integers, evidence floors, 'source' naming the table/reader. Read-only; no repo edits.

-- =============================================================================================
-- 1 · app.owner_brief_fact_items_v828 — "Top items by revenue AND by margin" (last 56 complete days)
-- =============================================================================================
create or replace function app.owner_brief_fact_items_v828(p_business uuid)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_to     date := app.sg_today() - 1;
  v_from   date := app.sg_today() - 56;
  v_lines  bigint;
  v_result jsonb;
  v_err    text;
begin
  begin
    with bounds as (
      select v_from::timestamp at time zone 'Asia/Singapore' as from_ts,
             (v_to + 1)::timestamp at time zone 'Asia/Singapore' as to_ts
    ), valid_sales as (
      -- reproduces app.v176_sales_window's valid_sales CTE exactly (nestly_v724): non-reversed,
      -- not a reversal target, not a synthetic client, window on occurred_at in SGT.
      select sale.id, sale.counts_as_revenue
      from public.sales sale, bounds
      cross join lateral app.analytics_sale_class_v1(sale) sc
      where sale.business_id = p_business
        and sale.reversal_of is null
        and sale.occurred_at >= bounds.from_ts
        and sale.occurred_at < bounds.to_ts
        and not sc.is_synthetic_client
        and not exists(
          select 1 from public.sales reversal
          where reversal.business_id = sale.business_id
            and reversal.reversal_of = sale.id
        )
    ), lines as (
      select si.id as line_id, si.qty, si.line_cents, si.item_type,
             vs.counts_as_revenue,
             coalesce(p.name, sv.name, si.description, 'Item') as item_name,
             coalesce(si.item_type, 'other') as item_type_out,
             case when p.id is not null then p.cost_cents
                  when sv.id is not null then sv.cost_cents
                  else null end as unit_cost_cents
      from public.sale_items si
      join valid_sales vs on vs.id = si.sale_id
      left join public.products p
        on p.id = si.product_id and p.business_id = p_business
      left join public.services sv
        on sv.id = si.ref_id and si.item_type = 'service' and sv.business_id = p_business
      where si.business_id = p_business
    ), agg as (
      select item_name, item_type_out,
             sum(qty) as units,
             sum(case when counts_as_revenue then line_cents else 0 end) as revenue_cents,
             bool_and(unit_cost_cents is not null) as cost_known,
             sum(case when counts_as_revenue and unit_cost_cents is not null
                      then line_cents - qty * unit_cost_cents else 0 end) as margin_cents_known,
             sum(case when counts_as_revenue then line_cents else 0 end)
               filter (where unit_cost_cents is not null) as revenue_with_known_cost
      from lines
      group by item_name, item_type_out
    ), stats as (
      select count(*) as n from lines
    )
    select jsonb_build_object(
      'status', 'ok',
      'evidence', case when stats.n < 20 then 'insufficient' else 'ok' end,
      'from', v_from, 'to', v_to,
      'lines_seen', stats.n,
      'source', 'public.sale_items filtered as app.v176_sales_window',
      'top_by_revenue', case when stats.n < 20 then null else (
        select coalesce(jsonb_agg(jsonb_build_object(
          'name', item_name, 'item_type', item_type_out, 'units', units,
          'revenue_cents', revenue_cents,
          'margin_cents', case when cost_known then margin_cents_known else null end
        ) order by revenue_cents desc), '[]'::jsonb)
        from (select * from agg order by revenue_cents desc limit 10) t
      ) end,
      'top_by_margin', case when stats.n < 20 then null else (
        select coalesce(jsonb_agg(jsonb_build_object(
          'name', item_name, 'item_type', item_type_out, 'units', units,
          'revenue_cents', revenue_cents, 'margin_cents', margin_cents_known
        ) order by margin_cents_known desc), '[]'::jsonb)
        from (select * from agg where cost_known order by margin_cents_known desc limit 10) t2
      ) end,
      'cost_known_revenue_pct', case when stats.n < 20 then null else (
        select case when sum(revenue_cents) > 0
                    then round(100.0 * sum(coalesce(revenue_with_known_cost, 0)) / sum(revenue_cents), 1)
                    else null end
        from agg
      ) end
    ) into v_result
    from stats;
  exception when others then
    get stacked diagnostics v_err = message_text;
    v_result := jsonb_build_object('status', 'unavailable', 'reason', left(v_err, 200),
      'source', 'public.sale_items');
  end;
  return v_result;
end;
$$;
revoke all on function app.owner_brief_fact_items_v828(uuid) from public, anon, authenticated;


-- =============================================================================================
-- 2 · app.owner_brief_fact_dying_v828 — "What's quietly dying?"
--     Last 28 complete days vs the mean of the prior 84 days (3 blocks of 28).
-- =============================================================================================
create or replace function app.owner_brief_fact_dying_v828(p_business uuid)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_cur_to    date := app.sg_today() - 1;
  v_cur_from  date := app.sg_today() - 28;
  v_pri_to    date := app.sg_today() - 29;
  v_pri_from  date := app.sg_today() - 112;   -- 84 days before the current 28-day window
  v_lines     bigint;
  v_result    jsonb;
  v_err       text;
begin
  begin
    with cur_bounds as (
      select v_cur_from::timestamp at time zone 'Asia/Singapore' as from_ts,
             (v_cur_to + 1)::timestamp at time zone 'Asia/Singapore' as to_ts
    ), pri_bounds as (
      select v_pri_from::timestamp at time zone 'Asia/Singapore' as from_ts,
             (v_pri_to + 1)::timestamp at time zone 'Asia/Singapore' as to_ts
    ), valid_sales_cur as (
      select sale.id, sale.counts_as_revenue
      from public.sales sale, cur_bounds
      cross join lateral app.analytics_sale_class_v1(sale) sc
      where sale.business_id = p_business
        and sale.reversal_of is null
        and sale.occurred_at >= cur_bounds.from_ts
        and sale.occurred_at < cur_bounds.to_ts
        and not sc.is_synthetic_client
        and not exists(select 1 from public.sales r
                        where r.business_id = sale.business_id and r.reversal_of = sale.id)
    ), valid_sales_pri as (
      select sale.id, sale.counts_as_revenue
      from public.sales sale, pri_bounds
      cross join lateral app.analytics_sale_class_v1(sale) sc
      where sale.business_id = p_business
        and sale.reversal_of is null
        and sale.occurred_at >= pri_bounds.from_ts
        and sale.occurred_at < pri_bounds.to_ts
        and not sc.is_synthetic_client
        and not exists(select 1 from public.sales r
                        where r.business_id = sale.business_id and r.reversal_of = sale.id)
    ), lines_cur as (
      select si.id as line_id, si.qty, si.line_cents,
             coalesce(p.name, sv.name, si.description, 'Item') as item_name
      from public.sale_items si
      join valid_sales_cur vs on vs.id = si.sale_id and vs.counts_as_revenue
      left join public.products p on p.id = si.product_id and p.business_id = p_business
      left join public.services sv on sv.id = si.ref_id and si.item_type = 'service' and sv.business_id = p_business
      where si.business_id = p_business
    ), lines_pri as (
      select si.id as line_id, si.qty, si.line_cents,
             coalesce(p.name, sv.name, si.description, 'Item') as item_name
      from public.sale_items si
      join valid_sales_pri vs on vs.id = si.sale_id and vs.counts_as_revenue
      left join public.products p on p.id = si.product_id and p.business_id = p_business
      left join public.services sv on sv.id = si.ref_id and si.item_type = 'service' and sv.business_id = p_business
      where si.business_id = p_business
    ), cur_agg as (
      select item_name, sum(line_cents) as revenue_cents from lines_cur group by item_name
    ), pri_agg as (
      select item_name, sum(line_cents) / 3.0 as baseline_mean_cents from lines_pri group by item_name
    ), joined as (
      select coalesce(c.item_name, b.item_name) as item_name,
             coalesce(c.revenue_cents, 0) as current_28d_cents,
             coalesce(b.baseline_mean_cents, 0) as baseline_mean_28d_cents
      from cur_agg c
      full outer join pri_agg b on b.item_name = c.item_name
    ), stats as (
      select (select count(*) from lines_cur) + (select count(*) from lines_pri) as n
    )
    select jsonb_build_object(
      'status', 'ok',
      'evidence', case when stats.n < 20 then 'insufficient' else 'ok' end,
      'current_from', v_cur_from, 'current_to', v_cur_to,
      'baseline_from', v_pri_from, 'baseline_to', v_pri_to,
      'lines_seen', stats.n,
      'source', 'public.sale_items filtered as app.v176_sales_window',
      'dying_items', case when stats.n < 20 then null else coalesce((
        select jsonb_agg(jsonb_build_object(
          'name', item_name,
          'current_28d_cents', round(current_28d_cents)::bigint,
          'baseline_mean_28d_cents', round(baseline_mean_28d_cents)::bigint,
          'decline_pct', round(100.0 * (baseline_mean_28d_cents - current_28d_cents) / baseline_mean_28d_cents, 1),
          'lost_revenue_cents', round(baseline_mean_28d_cents - current_28d_cents)::bigint
        ) order by (baseline_mean_28d_cents - current_28d_cents) desc)
        from (
          select * from joined
          where baseline_mean_28d_cents >= 5000
            and current_28d_cents <= baseline_mean_28d_cents * 0.7
          order by (baseline_mean_28d_cents - current_28d_cents) desc
          limit 5
        ) top
      ), '[]'::jsonb) end
    ) into v_result
    from stats;
  exception when others then
    get stacked diagnostics v_err = message_text;
    v_result := jsonb_build_object('status', 'unavailable', 'reason', left(v_err, 200),
      'source', 'public.sale_items');
  end;
  return v_result;
end;
$$;
revoke all on function app.owner_brief_fact_dying_v828(uuid) from public, anon, authenticated;


-- =============================================================================================
-- 3 · app.owner_brief_fact_pairs_v828 — "What do people buy together?" (last 56 complete days)
-- =============================================================================================
create or replace function app.owner_brief_fact_pairs_v828(p_business uuid)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_to        date := app.sg_today() - 1;
  v_from      date := app.sg_today() - 56;
  v_multi     bigint;
  v_result    jsonb;
  v_err       text;
begin
  begin
    with bounds as (
      select v_from::timestamp at time zone 'Asia/Singapore' as from_ts,
             (v_to + 1)::timestamp at time zone 'Asia/Singapore' as to_ts
    ), valid_sales as (
      select sale.id
      from public.sales sale, bounds
      cross join lateral app.analytics_sale_class_v1(sale) sc
      where sale.business_id = p_business
        and sale.reversal_of is null
        and sale.occurred_at >= bounds.from_ts
        and sale.occurred_at < bounds.to_ts
        and not sc.is_synthetic_client
        and not exists(select 1 from public.sales r
                        where r.business_id = sale.business_id and r.reversal_of = sale.id)
    ), sale_item_names as (
      -- one row per (sale, distinct item name) -- several lines of the same item in one sale
      -- (e.g. two lattes) collapse to one membership of that sale's item set.
      select distinct si.sale_id,
             coalesce(p.name, sv.name, si.description, 'Item') as item_name
      from public.sale_items si
      join valid_sales vs on vs.id = si.sale_id
      left join public.products p on p.id = si.product_id and p.business_id = p_business
      left join public.services sv on sv.id = si.ref_id and si.item_type = 'service' and sv.business_id = p_business
      where si.business_id = p_business
    ), sale_item_counts as (
      select sale_id, count(*) as n_items from sale_item_names group by sale_id
    ), multi_sales as (
      select sale_id from sale_item_counts where n_items >= 2
    ), item_solo as (
      select item_name, count(distinct sale_id) as solo_sales
      from sale_item_names
      group by item_name
    ), pairs as (
      select a.sale_id, a.item_name as name1, b.item_name as name2
      from sale_item_names a
      join sale_item_names b on b.sale_id = a.sale_id and b.item_name > a.item_name
      where a.sale_id in (select sale_id from multi_sales)
    ), pair_counts as (
      select name1, name2, count(distinct sale_id) as pair_sales
      from pairs
      group by name1, name2
    ), oriented as (
      -- item_a is the more commonly-sold half of the pair (the "when they buy X" anchor).
      select
        case when s1.solo_sales >= s2.solo_sales then pc.name1 else pc.name2 end as item_a,
        case when s1.solo_sales >= s2.solo_sales then pc.name2 else pc.name1 end as item_b,
        pc.pair_sales,
        greatest(s1.solo_sales, s2.solo_sales) as item_a_solo_sales
      from pair_counts pc
      join item_solo s1 on s1.item_name = pc.name1
      join item_solo s2 on s2.item_name = pc.name2
    ), stats as (
      select count(*) as n from multi_sales
    )
    select jsonb_build_object(
      'status', 'ok',
      'evidence', case when stats.n < 30 then 'insufficient' else 'ok' end,
      'from', v_from, 'to', v_to,
      'multi_line_sales_seen', stats.n,
      'source', 'public.sale_items filtered as app.v176_sales_window',
      'top_pairs', case when stats.n < 30 then null else coalesce((
        select jsonb_agg(jsonb_build_object(
          'item_a', item_a, 'item_b', item_b,
          'pair_sales', pair_sales,
          'item_a_solo_sales', item_a_solo_sales,
          'attach_pct', round(100.0 * pair_sales / item_a_solo_sales, 1)
        ) order by pair_sales desc)
        from (select * from oriented order by pair_sales desc limit 5) t
      ), '[]'::jsonb) end
    ) into v_result
    from stats;
  exception when others then
    get stacked diagnostics v_err = message_text;
    v_result := jsonb_build_object('status', 'unavailable', 'reason', left(v_err, 200),
      'source', 'public.sale_items');
  end;
  return v_result;
end;
$$;
revoke all on function app.owner_brief_fact_pairs_v828(uuid) from public, anon, authenticated;


-- =============================================================================================
-- 4 · app.owner_brief_fact_discounts_v828 — "Who is giving discounts, on what?" (last 56 days)
-- =============================================================================================
create or replace function app.owner_brief_fact_discounts_v828(p_business uuid)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_to      date := app.sg_today() - 1;
  v_from    date := app.sg_today() - 56;
  v_lines   bigint;
  v_staffed bigint;
  v_result  jsonb;
  v_err     text;
begin
  begin
    with bounds as (
      select v_from::timestamp at time zone 'Asia/Singapore' as from_ts,
             (v_to + 1)::timestamp at time zone 'Asia/Singapore' as to_ts
    ), valid_sales as (
      select sale.id, sale.staff_id
      from public.sales sale, bounds
      cross join lateral app.analytics_sale_class_v1(sale) sc
      where sale.business_id = p_business
        and sale.reversal_of is null
        and sale.occurred_at >= bounds.from_ts
        and sale.occurred_at < bounds.to_ts
        and not sc.is_synthetic_client
        and not exists(select 1 from public.sales r
                        where r.business_id = sale.business_id and r.reversal_of = sale.id)
    ), lines as (
      select cdl.id, cdl.amount_cents, cdl.rule_id, vs.staff_id
      from public.checkout_discount_lines cdl
      join valid_sales vs on vs.id = cdl.sale_id
      where cdl.business_id = p_business
    ), stats as (
      select count(*) as n, count(*) filter (where staff_id is not null) as n_staffed
      from lines
    )
    select jsonb_build_object(
      'status', 'ok',
      'evidence', case when stats.n < 10 then 'insufficient' else 'ok' end,
      'from', v_from, 'to', v_to,
      'discount_lines_seen', stats.n,
      'source', 'public.checkout_discount_lines joined to public.sales (valid, as app.v176_sales_window)',
      'total_discount_cents', case when stats.n < 10 then null else
        (select coalesce(sum(amount_cents), 0) from lines) end,
      'staff', case when stats.n < 10 or stats.n_staffed = 0 then null else (
        select coalesce(jsonb_agg(jsonb_build_object(
          'staff_id', staff_id, 'name', staff_name,
          'discount_cents', discount_cents, 'discount_count', discount_count
        ) order by discount_cents desc), '[]'::jsonb)
        from (
          select l.staff_id, coalesce(st.full_name, 'Unknown staff') as staff_name,
                 sum(l.amount_cents) as discount_cents, count(*) as discount_count
          from lines l
          left join public.staff st on st.id = l.staff_id and st.business_id = p_business
          where l.staff_id is not null
          group by l.staff_id, st.full_name
          order by sum(l.amount_cents) desc
          limit 5
        ) s
      ) end,
      'staff_note', case when stats.n >= 10 and stats.n_staffed = 0
        then 'no discount line in this window carries sales.staff_id; staff attribution unavailable'
        else null end,
      'by_rule', case when stats.n < 10 then null else (
        select coalesce(jsonb_agg(jsonb_build_object(
          'rule_id', rule_id, 'rule_name', rule_name,
          'discount_cents', discount_cents, 'discount_count', discount_count
        ) order by discount_cents desc), '[]'::jsonb)
        from (
          select l.rule_id, coalesce(pr.name, 'Studio discount') as rule_name,
                 sum(l.amount_cents) as discount_cents, count(*) as discount_count
          from lines l
          left join public.program_rules pr
            on pr.rule_id = l.rule_id and pr.business_id = p_business
           and pr.config_version_id = (select active_config_version_id from public.businesses where id = p_business)
          group by l.rule_id, pr.name
          order by sum(l.amount_cents) desc
          limit 5
        ) r
      ) end
    ) into v_result
    from stats;
  exception when others then
    get stacked diagnostics v_err = message_text;
    v_result := jsonb_build_object('status', 'unavailable', 'reason', left(v_err, 200),
      'source', 'public.checkout_discount_lines');
  end;
  return v_result;
end;
$$;
revoke all on function app.owner_brief_fact_discounts_v828(uuid) from public, anon, authenticated;


-- =============================================================================================
-- 5 · app.owner_brief_fact_stock_v828 — "What runs out before the next delivery?"
-- =============================================================================================
create or replace function app.owner_brief_fact_stock_v828(p_business uuid)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_to       date := app.sg_today() - 1;
  v_from     date := app.sg_today() - 28;
  v_tracked  bigint;
  v_result   jsonb;
  v_err      text;
begin
  begin
    with bounds as (
      select v_from::timestamp at time zone 'Asia/Singapore' as from_ts,
             (v_to + 1)::timestamp at time zone 'Asia/Singapore' as to_ts
    ), valid_sales as (
      select sale.id
      from public.sales sale, bounds
      cross join lateral app.analytics_sale_class_v1(sale) sc
      where sale.business_id = p_business
        and sale.reversal_of is null
        and sale.occurred_at >= bounds.from_ts
        and sale.occurred_at < bounds.to_ts
        and not sc.is_synthetic_client
        and not exists(select 1 from public.sales r
                        where r.business_id = sale.business_id and r.reversal_of = sale.id)
    ), on_hand as (
      -- stock_batches has no business_id column; scope it through products.
      select p.id as product_id, p.name, sum(sb.qty) as on_hand_qty
      from public.stock_batches sb
      join public.products p on p.id = sb.product_id
      where p.business_id = p_business
      group by p.id, p.name
    ), sold as (
      select si.product_id, sum(si.qty) as units_28d
      from public.sale_items si
      join valid_sales vs on vs.id = si.sale_id
      where si.business_id = p_business and si.product_id is not null
      group by si.product_id
    ), combined as (
      select oh.product_id, oh.name, oh.on_hand_qty, coalesce(sd.units_28d, 0) as units_28d,
             case when coalesce(sd.units_28d, 0) > 0
                  then round(oh.on_hand_qty / (sd.units_28d / 28.0), 1)
                  else null end as days_left
      from on_hand oh
      left join sold sd on sd.product_id = oh.product_id
    ), stats as (
      select (select count(*) from on_hand) as n_tracked,
             exists (select 1 from combined where units_28d > 0) as has_sold_tracked
    )
    select jsonb_build_object(
      'status', 'ok',
      'evidence', case when not stats.has_sold_tracked then 'insufficient' else 'ok' end,
      'from', v_from, 'to', v_to,
      'products_with_stock_tracking', stats.n_tracked,
      'source', 'public.stock_batches + public.sale_items filtered as app.v176_sales_window',
      'running_out', case when not stats.has_sold_tracked then null else coalesce((
        select jsonb_agg(jsonb_build_object(
          'name', name, 'on_hand_qty', on_hand_qty, 'units_28d', units_28d, 'days_left', days_left
        ) order by days_left asc)
        from (
          select * from combined
          where days_left is not null and days_left < 14
          order by days_left asc
          limit 5
        ) t
      ), '[]'::jsonb) end
    ) into v_result
    from stats;
  exception when others then
    get stacked diagnostics v_err = message_text;
    v_result := jsonb_build_object('status', 'unavailable', 'reason', left(v_err, 200),
      'source', 'public.stock_batches');
  end;
  return v_result;
end;
$$;
revoke all on function app.owner_brief_fact_stock_v828(uuid) from public, anon, authenticated;

-- =============================================================================================
-- fragment: people
-- =============================================================================================
-- nestly_v828 fragment "people" — six owner-brief facts about staff, outlets, birthdays,
-- memberships, referrals and gaming risk. Style copied from db/migrations/20261007_nestly_v826_owner_brief.sql
-- (app.owner_brief_compose_v826): each fact fails closed inside its own exception block, every
-- money/visit figure over public.sales is filtered exactly the way app.v176_sales_window filters
-- it (reversal_of is null, no reversal row exists, not app.analytics_sale_class_v1(sale).is_synthetic_client,
-- window on occurred_at in Asia/Singapore), and visit-days collapse via app.ci_visit_day_v699.
-- No grants to anyone: these are composer-only building blocks, called by postgres.

-- =============================================================================================
-- 1 · Sales per staff fair to hours worked; who upsells; overstaffed at quiet hours?
-- =============================================================================================
create or replace function app.owner_brief_fact_staff_v828(p_business uuid)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_to      date := app.sg_today() - 1;
  v_from    date := app.sg_today() - 56;          -- last 56 complete days
  v_weeks   numeric := 8.0;                        -- 56 / 7 -- exact, no partial-week bias
  v_staffed bigint;
  v_staff   jsonb;
  v_quiet   jsonb;
  v_err     text;
begin
  -- how much staff-attributed evidence do we actually have?
  select count(distinct si.sale_id) into v_staffed
  from public.sale_items si
  join public.sales sale on sale.id = si.sale_id and sale.business_id = p_business
  cross join lateral app.analytics_sale_class_v1(sale) sc
  where sale.reversal_of is null
    and not sc.is_synthetic_client
    and sale.occurred_at >= (v_from::timestamp at time zone 'Asia/Singapore')
    and sale.occurred_at <  ((v_to + 1)::timestamp at time zone 'Asia/Singapore')
    and si.staff_id is not null
    and not exists (select 1 from public.sales r
                     where r.business_id = sale.business_id and r.reversal_of = sale.id);

  if coalesce(v_staffed, 0) < 20 then
    return jsonb_build_object(
      'status', 'ok', 'source', 'public.sale_items joined to valid public.sales + public.staff_hours',
      'from', v_from, 'to', v_to, 'evidence', 'insufficient',
      'sales_with_staff_attribution', coalesce(v_staffed, 0), 'staff', '[]'::jsonb, 'quiet_overlap', null);
  end if;

  with valid_sales as (
    select sale.id, sale.occurred_at
    from public.sales sale
    cross join lateral app.analytics_sale_class_v1(sale) sc
    where sale.business_id = p_business
      and sale.reversal_of is null
      and not sc.is_synthetic_client
      and sale.occurred_at >= (v_from::timestamp at time zone 'Asia/Singapore')
      and sale.occurred_at <  ((v_to + 1)::timestamp at time zone 'Asia/Singapore')
      and not exists (select 1 from public.sales r
                       where r.business_id = sale.business_id and r.reversal_of = sale.id)
  ),
  lines as (
    select si.staff_id, si.sale_id, si.qty, si.line_cents
    from public.sale_items si
    join valid_sales vs on vs.id = si.sale_id
    where si.staff_id is not null
  ),
  roster as (
    select staff_id, sum(extract(epoch from (ends_at - starts_at)) / 3600.0)::numeric as weekly_hours
    from public.staff_hours
    where business_id = p_business
    group by staff_id
  ),
  per_staff as (
    select s.id as staff_id, s.full_name,
      r.weekly_hours,
      coalesce(sum(l.line_cents), 0) as revenue_cents,
      count(distinct l.sale_id) as sales,
      coalesce(sum(l.qty), 0) as items
    from public.staff s
    left join roster r on r.staff_id = s.id
    left join lines l on l.staff_id = s.id
    where s.business_id = p_business and s.active
    group by s.id, s.full_name, r.weekly_hours
  )
  select jsonb_agg(jsonb_build_object(
      'staff_id', staff_id, 'name', full_name,
      'rostered_hours', case when weekly_hours is not null then round(weekly_hours * v_weeks, 1) end,
      'revenue_cents', revenue_cents,
      'sales', sales,
      'items_per_sale', case when sales > 0 then round(items::numeric / sales, 1) end,
      'revenue_per_rostered_hour_cents',
        case when weekly_hours is not null and weekly_hours * v_weeks > 0
             then round(revenue_cents / (weekly_hours * v_weeks)) end)
    order by revenue_cents desc)
  into v_staff
  from per_staff;

  -- quiet_overlap: eight 3-hour Singapore-time blocks. "staff rostered" is a shift-occurrence
  -- count (each staff_hours row recurs 8 times across 56 days, since 56/7 is exact), "sales" is
  -- staff-attributed valid sales landing in that block over the window.
  with valid_sales as (
    select sale.id, sale.occurred_at
    from public.sales sale
    cross join lateral app.analytics_sale_class_v1(sale) sc
    where sale.business_id = p_business
      and sale.reversal_of is null
      and not sc.is_synthetic_client
      and sale.occurred_at >= (v_from::timestamp at time zone 'Asia/Singapore')
      and sale.occurred_at <  ((v_to + 1)::timestamp at time zone 'Asia/Singapore')
      and not exists (select 1 from public.sales r
                       where r.business_id = sale.business_id and r.reversal_of = sale.id)
  ),
  sales_staffed as (
    select distinct si.sale_id, vs.occurred_at
    from public.sale_items si
    join valid_sales vs on vs.id = si.sale_id
    where si.staff_id is not null
  ),
  blocks as (select g as block_start from generate_series(0, 21, 3) g),
  sales_by_block as (
    select b.block_start, count(*) as sales_ct
    from blocks b
    left join sales_staffed ss
      on extract(hour from (ss.occurred_at at time zone 'Asia/Singapore')) >= b.block_start
     and extract(hour from (ss.occurred_at at time zone 'Asia/Singapore')) <  b.block_start + 3
    group by b.block_start
  ),
  rostered_by_block as (
    select b.block_start,
      coalesce(sum(case
        when extract(epoch from sh.starts_at) / 3600.0 < b.block_start + 3
         and extract(epoch from sh.ends_at)   / 3600.0 > b.block_start
        then 8 else 0 end), 0) as rostered_ct
    from blocks b
    left join public.staff_hours sh on sh.business_id = p_business
    group by b.block_start
  )
  select jsonb_build_object(
    'status', 'ok', 'from', v_from, 'to', v_to,
    'blocks', coalesce((
      select jsonb_agg(jsonb_build_object(
          'block', sb.block_start || '-' || (sb.block_start + 3),
          'staff_rostered', rb.rostered_ct, 'sales', sb.sales_ct,
          'staff_per_sale', case when sb.sales_ct > 0 then round(rb.rostered_ct::numeric / sb.sales_ct, 2) end)
        order by sb.block_start)
      from sales_by_block sb join rostered_by_block rb on rb.block_start = sb.block_start), '[]'::jsonb),
    'most_overstaffed_block', (
      select jsonb_build_object(
          'block', sb.block_start || '-' || (sb.block_start + 3),
          'staff_rostered', rb.rostered_ct, 'sales', sb.sales_ct,
          'staff_per_sale', round(rb.rostered_ct::numeric / sb.sales_ct, 2))
      from sales_by_block sb join rostered_by_block rb on rb.block_start = sb.block_start
      where sb.sales_ct > 0
      order by (rb.rostered_ct::numeric / sb.sales_ct) desc
      limit 1))
  into v_quiet;

  return jsonb_build_object(
    'status', 'ok',
    'source', 'public.sale_items joined to valid public.sales + public.staff_hours + app.ci_visit_day_v699',
    'from', v_from, 'to', v_to, 'weeks', v_weeks, 'evidence', 'ok',
    'sales_with_staff_attribution', v_staffed,
    'hours_basis', 'public.staff_hours holds a WEEKLY PATTERN (weekday, starts_at, ends_at), no dates -- rostered_hours = weekly pattern hours x 8 (56 days / 7). A staff member with no staff_hours rows shows rostered_hours null, not zero.',
    'staff', coalesce(v_staff, '[]'::jsonb),
    'quiet_overlap', v_quiet);
exception when others then
  get stacked diagnostics v_err = message_text;
  return jsonb_build_object('status', 'unavailable', 'reason', left(v_err, 200),
                             'source', 'public.sale_items + public.staff_hours');
end;
$$;
revoke all on function app.owner_brief_fact_staff_v828(uuid) from public, anon, authenticated;

-- =============================================================================================
-- 2 · Who visits more than one outlet? (multi-branch businesses only, last 180 days)
-- =============================================================================================
create or replace function app.owner_brief_fact_multi_outlet_v828(p_business uuid)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_to       date := app.sg_today() - 1;
  v_from     date := app.sg_today() - 180;
  v_branches int;
  v_result   jsonb;
  v_err      text;
begin
  select count(*) into v_branches from public.branches where business_id = p_business and active;

  if coalesce(v_branches, 0) <= 1 then
    return jsonb_build_object('status', 'single_outlet', 'source', 'public.branches', 'branches', coalesce(v_branches, 0));
  end if;

  with valid_sales as (
    select sale.client_id, sale.branch_id, sale.occurred_at
    from public.sales sale
    cross join lateral app.analytics_sale_class_v1(sale) sc
    where sale.business_id = p_business
      and sale.reversal_of is null
      and not sc.is_synthetic_client
      and sale.counts_as_visit
      and sale.client_id is not null
      and sale.occurred_at >= (v_from::timestamp at time zone 'Asia/Singapore')
      and sale.occurred_at <  ((v_to + 1)::timestamp at time zone 'Asia/Singapore')
      and not exists (select 1 from public.sales r
                       where r.business_id = sale.business_id and r.reversal_of = sale.id)
  ),
  visit_days as (
    select distinct client_id, branch_id, app.ci_visit_day_v699(occurred_at) as vday
    from valid_sales
  ),
  per_client as (
    select client_id, count(distinct branch_id) as branches_visited, count(*) as visit_days
    from visit_days
    group by client_id
  )
  select jsonb_build_object(
    'status', 'ok', 'source', 'public.sales (v176-style valid-sale filter) + app.ci_visit_day_v699',
    'from', v_from, 'to', v_to, 'branches', v_branches,
    'identified_customers', (select count(*) from per_client),
    'multi_outlet_customers', (select count(*) from per_client where branches_visited >= 2),
    'multi_outlet_share_pct', case when (select count(*) from per_client) > 0
      then round(100.0 * (select count(*) from per_client where branches_visited >= 2)
                        / (select count(*) from per_client), 1) end,
    'mean_visit_days_multi_outlet', (select round(avg(visit_days), 1) from per_client where branches_visited >= 2),
    'mean_visit_days_single_outlet', (select round(avg(visit_days), 1) from per_client where branches_visited = 1))
  into v_result;

  return v_result;
exception when others then
  get stacked diagnostics v_err = message_text;
  return jsonb_build_object('status', 'unavailable', 'reason', left(v_err, 200), 'source', 'public.sales + public.branches');
end;
$$;
revoke all on function app.owner_brief_fact_multi_outlet_v828(uuid) from public, anon, authenticated;

-- =============================================================================================
-- 3 · Birthdays this month: did we send anything, did they redeem?
-- =============================================================================================
create or replace function app.owner_brief_fact_birthdays_v828(p_business uuid)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_today  date := app.sg_today();
  v_month  int  := extract(month from v_today);
  v_year   int  := extract(year from v_today);
  v_bday   int;
  v_granted int;
  v_redeemed int;
  v_err    text;
begin
  select count(*) into v_bday
  from public.clients c
  where c.business_id = p_business and not c.is_synthetic
    and c.birth_date is not null
    and extract(month from c.birth_date) = v_month;

  begin
    select count(*) into v_granted
    from public.customer_birthday_entitlements e
    join public.clients c on c.id = e.client_id and c.business_id = p_business
    where e.business_id = p_business
      and not c.is_synthetic
      and extract(month from c.birth_date) = v_month
      and e.birthday_year = v_year
      and e.activated_at is not null;
  exception when undefined_table then
    v_granted := null;
  end;

  begin
    select count(*) into v_redeemed
    from public.customer_birthday_redemptions r
    join public.customer_birthday_entitlements e on e.id = r.entitlement_id
    join public.clients c on c.id = e.client_id and c.business_id = p_business
    where r.business_id = p_business
      and not c.is_synthetic
      and extract(month from c.birth_date) = v_month
      and e.birthday_year = v_year
      and r.operation_kind = 'redemption'
      and r.active;
  exception when undefined_table then
    v_redeemed := null;
  end;

  return jsonb_build_object(
    'status', 'ok',
    'source', 'public.clients.birth_date + public.customer_birthday_entitlements + public.customer_birthday_redemptions',
    'month', v_month, 'year', v_year,
    'birthday_clients_this_month', v_bday,
    'granted_this_month', v_granted,
    'granted_note', 'granted = customer_birthday_entitlements.activated_at is not null for birthday_year = current year; this is a customer self-activation (nestly_v560 join_program-style flow), not proof a WhatsApp/SMS notification was sent -- no notification-log table was found for birthday, so "did we send anything" is answered by activation, not delivery.',
    'redeemed_this_month', v_redeemed);
exception when others then
  get stacked diagnostics v_err = message_text;
  return jsonb_build_object('status', 'unavailable', 'reason', left(v_err, 200), 'source', 'public.clients + birthday tables');
end;
$$;
revoke all on function app.owner_brief_fact_birthdays_v828(uuid) from public, anon, authenticated;

-- =============================================================================================
-- 4 · Do members spend more than walk-ins? (56 days)
-- =============================================================================================
create or replace function app.owner_brief_fact_member_lift_v828(p_business uuid)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_to      date := app.sg_today() - 1;
  v_from    date := app.sg_today() - 56;
  v_has_mem boolean;
  v_result  jsonb;
  v_err     text;
begin
  select exists(select 1 from public.memberships where business_id = p_business) into v_has_mem;
  if not v_has_mem then
    return jsonb_build_object('status', 'no_memberships', 'source', 'public.memberships');
  end if;

  with member_clients as (
    -- active at any point in the window: started before the window ends, and (if since paused)
    -- was not paused before the window began. There is no cancelled_at column, so a cancelled
    -- membership is only excluded if it was also paused first -- see RESULT.md caveat.
    select distinct client_id
    from public.memberships
    where business_id = p_business
      and started_at <= ((v_to + 1)::timestamp at time zone 'Asia/Singapore')
      and (paused_at is null or paused_at >= (v_from::timestamp at time zone 'Asia/Singapore'))
  ),
  valid_sales as (
    select sale.client_id, sale.occurred_at, sale.amount_cents, sale.counts_as_revenue
    from public.sales sale
    cross join lateral app.analytics_sale_class_v1(sale) sc
    where sale.business_id = p_business
      and sale.reversal_of is null
      and not sc.is_synthetic_client
      and sale.counts_as_visit
      and sale.client_id is not null
      and sale.occurred_at >= (v_from::timestamp at time zone 'Asia/Singapore')
      and sale.occurred_at <  ((v_to + 1)::timestamp at time zone 'Asia/Singapore')
      and not exists (select 1 from public.sales r
                       where r.business_id = sale.business_id and r.reversal_of = sale.id)
  ),
  visit_days as (
    select distinct client_id, app.ci_visit_day_v699(occurred_at) as vday from valid_sales
  ),
  per_client as (
    select vd.client_id, count(*) as visit_days,
      coalesce((select sum(amount_cents) from valid_sales vs2
                 where vs2.client_id = vd.client_id and vs2.counts_as_revenue), 0) as revenue_cents,
      (mc.client_id is not null) as is_member
    from visit_days vd
    left join member_clients mc on mc.client_id = vd.client_id
    group by vd.client_id, mc.client_id
  ),
  agg as (
    select is_member, count(*) as customers,
      round(avg(visit_days), 1) as visit_days_per_customer,
      case when sum(visit_days) > 0 then round(sum(revenue_cents)::numeric / sum(visit_days)) end as revenue_per_visit_day_cents
    from per_client
    group by is_member
  )
  select jsonb_build_object(
    'status', 'ok',
    'source', 'public.memberships + public.sales (v176-style valid-sale filter) + app.ci_visit_day_v699',
    'from', v_from, 'to', v_to,
    'members', (select jsonb_build_object('customers', customers, 'visit_days_per_customer', visit_days_per_customer,
                  'revenue_per_visit_day_cents', revenue_per_visit_day_cents) from agg where is_member),
    'non_members', (select jsonb_build_object('customers', customers, 'visit_days_per_customer', visit_days_per_customer,
                  'revenue_per_visit_day_cents', revenue_per_visit_day_cents) from agg where not is_member),
    'evidence', case when coalesce((select customers from agg where is_member), 0) >= 5
                      and coalesce((select customers from agg where not is_member), 0) >= 5
                 then 'ok' else 'insufficient' end)
  into v_result;

  return v_result;
exception when others then
  get stacked diagnostics v_err = message_text;
  return jsonb_build_object('status', 'unavailable', 'reason', left(v_err, 200), 'source', 'public.memberships + public.sales');
end;
$$;
revoke all on function app.owner_brief_fact_member_lift_v828(uuid) from public, anon, authenticated;

-- =============================================================================================
-- 5 · Do referred friends stick? (referrals in the last 90 days)
-- =============================================================================================
create or replace function app.owner_brief_fact_referrals_v828(p_business uuid)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_to       date := app.sg_today() - 1;
  v_from     date := app.sg_today() - 90;
  v_referred int;
  v_result   jsonb;
  v_err      text;
begin
  select count(*) into v_referred
  from public.referrals r
  where r.business_id = p_business
    and r.referred_client_id is not null
    and r.created_at >= (v_from::timestamp at time zone 'Asia/Singapore')
    and r.created_at <  ((v_to + 1)::timestamp at time zone 'Asia/Singapore');

  if coalesce(v_referred, 0) < 5 then
    return jsonb_build_object('status', 'ok', 'source', 'public.referrals', 'from', v_from, 'to', v_to,
      'evidence', 'insufficient', 'referred_customers', coalesce(v_referred, 0));
  end if;

  with referred as (
    select r.id as referral_id, r.referred_client_id as client_id, r.reward_cents, r.status
    from public.referrals r
    where r.business_id = p_business
      and r.referred_client_id is not null
      and r.created_at >= (v_from::timestamp at time zone 'Asia/Singapore')
      and r.created_at <  ((v_to + 1)::timestamp at time zone 'Asia/Singapore')
  ),
  valid_sales as (
    select sale.client_id, sale.occurred_at
    from public.sales sale
    cross join lateral app.analytics_sale_class_v1(sale) sc
    where sale.business_id = p_business
      and sale.reversal_of is null
      and not sc.is_synthetic_client
      and sale.counts_as_visit
      and sale.client_id in (select client_id from referred)
      and not exists (select 1 from public.sales rv
                       where rv.business_id = sale.business_id and rv.reversal_of = sale.id)
  ),
  visit_days as (
    select distinct client_id, app.ci_visit_day_v699(occurred_at) as vday from valid_sales
  ),
  ranked as (
    select client_id, vday, row_number() over (partition by client_id order by vday) as rn
    from visit_days
  ),
  first_second as (
    select f.client_id, f.vday as first_vday, s.vday as second_vday
    from ranked f
    left join ranked s on s.client_id = f.client_id and s.rn = 2
    where f.rn = 1
  ),
  stuck as (
    select client_id, (second_vday is not null and second_vday <= first_vday + 60) as sticky
    from first_second
  )
  select jsonb_build_object(
    'status', 'ok', 'source', 'public.referrals + public.sales (v176-style filter) + app.ci_visit_day_v699',
    'from', v_from, 'to', v_to,
    'referred_customers', v_referred,
    'stuck_within_60_days', (select count(*) from stuck where sticky),
    'stick_pct', round(100.0 * (select count(*) from stuck where sticky) / v_referred, 1),
    'reward_cents_paid', coalesce((select sum(reward_cents) from referred where status = 'rewarded'), 0),
    'reward_points_paid', coalesce((select sum(reward_points) from referred where status = 'rewarded'), 0),
    'free_gift_grants', coalesce((select jsonb_build_object(
        'granted', count(*) filter (where g.status = 'granted'),
        'redeemed', count(*) filter (where g.status = 'redeemed'),
        'expired', count(*) filter (where g.status = 'expired'))
      from public.referral_grants_v420 g where g.referral_id in (select referral_id from referred)),
      jsonb_build_object('granted', 0, 'redeemed', 0, 'expired', 0)),
    'evidence', 'ok')
  into v_result;

  return v_result;
exception when others then
  get stacked diagnostics v_err = message_text;
  return jsonb_build_object('status', 'unavailable', 'reason', left(v_err, 200), 'source', 'public.referrals + public.sales');
end;
$$;
revoke all on function app.owner_brief_fact_referrals_v828(uuid) from public, anon, authenticated;

-- =============================================================================================
-- 6 · Is anyone gaming it? (56 days, three simple rules)
-- =============================================================================================
create or replace function app.owner_brief_fact_anomalies_v828(p_business uuid)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_to    date := app.sg_today() - 1;
  v_from  date := app.sg_today() - 56;
  v_a_cnt int; v_a_ex jsonb;
  v_b_top jsonb; v_b_total int; v_b_flag boolean := false;
  v_c_cnt int; v_c_ex jsonb;
  v_flags int;
  v_err   text;
begin
  -- (a) one client with 3+ manual reward redemptions on one day
  with per_day as (
    select client_id, app.ci_visit_day_v699(created_at) as day, sum(quantity) as qty
    from public.loyalty_manual_redemptions_v404
    where business_id = p_business
      and created_at >= (v_from::timestamp at time zone 'Asia/Singapore')
      and created_at <  ((v_to + 1)::timestamp at time zone 'Asia/Singapore')
    group by client_id, app.ci_visit_day_v699(created_at)
    having sum(quantity) >= 3
  )
  select count(*), (select coalesce(jsonb_agg(jsonb_build_object('client_id', client_id, 'day', day, 'count', qty)), '[]'::jsonb)
                     from (select * from per_day order by qty desc limit 3) t)
  into v_a_cnt, v_a_ex
  from per_day;

  -- (b) one staff login issuing more than 60% of manual redemptions when there are 10+
  with red as (
    select actor, count(*) as n
    from public.loyalty_manual_redemptions_v404
    where business_id = p_business
      and created_at >= (v_from::timestamp at time zone 'Asia/Singapore')
      and created_at <  ((v_to + 1)::timestamp at time zone 'Asia/Singapore')
    group by actor
  ),
  tot as (select coalesce(sum(n), 0) as total from red)
  select
    (select total from tot),
    (select jsonb_build_object('actor', r.actor, 'staff_name', s.full_name, 'count', r.n,
              'share_pct', round(100.0 * r.n / nullif((select total from tot), 0), 1))
       from red r
       left join public.staff s on s.user_id = r.actor and s.business_id = p_business
      order by r.n desc limit 1)
  into v_b_total, v_b_top;

  if v_b_total >= 10 and coalesce((v_b_top ->> 'share_pct')::numeric, 0) > 60 then
    v_b_flag := true;
  end if;

  -- (c) one client with sales at 3+ different branches on one day
  with valid_sales as (
    select sale.client_id, sale.branch_id, sale.occurred_at
    from public.sales sale
    cross join lateral app.analytics_sale_class_v1(sale) sc
    where sale.business_id = p_business
      and sale.reversal_of is null
      and not sc.is_synthetic_client
      and sale.client_id is not null
      and sale.branch_id is not null
      and sale.occurred_at >= (v_from::timestamp at time zone 'Asia/Singapore')
      and sale.occurred_at <  ((v_to + 1)::timestamp at time zone 'Asia/Singapore')
      and not exists (select 1 from public.sales r
                       where r.business_id = sale.business_id and r.reversal_of = sale.id)
  ),
  per_day as (
    select client_id, app.ci_visit_day_v699(occurred_at) as day, count(distinct branch_id) as branches
    from valid_sales
    group by client_id, app.ci_visit_day_v699(occurred_at)
    having count(distinct branch_id) >= 3
  )
  select count(*), (select coalesce(jsonb_agg(jsonb_build_object('client_id', client_id, 'day', day, 'branches', branches)), '[]'::jsonb)
                     from (select * from per_day order by branches desc limit 3) t)
  into v_c_cnt, v_c_ex
  from per_day;

  v_flags := coalesce(v_a_cnt, 0) + (case when v_b_flag then 1 else 0 end) + coalesce(v_c_cnt, 0);

  return jsonb_build_object(
    'status', 'ok',
    'source', 'public.loyalty_manual_redemptions_v404 + public.sales (v176-style filter) + app.ci_visit_day_v699',
    'from', v_from, 'to', v_to, 'flags', v_flags,
    'rule_a_redemption_burst', jsonb_build_object('count', coalesce(v_a_cnt, 0), 'examples', coalesce(v_a_ex, '[]'::jsonb)),
    'rule_b_staff_concentration', jsonb_build_object(
      'flagged', v_b_flag, 'total_redemptions', v_b_total,
      'top', case when v_b_total > 0 then v_b_top end,
      'evidence', case when v_b_total >= 10 then 'ok' else 'insufficient' end),
    'rule_c_multi_branch_same_day', jsonb_build_object('count', coalesce(v_c_cnt, 0), 'examples', coalesce(v_c_ex, '[]'::jsonb)));
exception when others then
  get stacked diagnostics v_err = message_text;
  return jsonb_build_object('status', 'unavailable', 'reason', left(v_err, 200),
                             'source', 'public.loyalty_manual_redemptions_v404 + public.sales');
end;
$$;
revoke all on function app.owner_brief_fact_anomalies_v828(uuid) from public, anon, authenticated;

-- =============================================================================================
-- fragment: ahead
-- =============================================================================================
-- nestly_v828 fragment "ahead" — four owner-brief facts.
-- Style copied from db/migrations/20261007_nestly_v826_owner_brief.sql: per-fact exception
-- block, cents as integers, evidence floors, 'source' naming the table/reader used.
-- No begin/commit here — paste into the migration body between existing begin/commit.

-- =================================================================================================
-- 1 · app.owner_brief_fact_stamps_v828 — "How many stamp cards are started and finished, and
--     where do people drop off?"
--
-- MODEL (read from db/migrations/20260814_nestly_v323_stamp_quest_milestones.sql,
-- app.stamp_progress_v323): a stamp card is NOT a stored row. Per (business, client):
--   net_stamps   = sum(points_ledger.points) on the business's kind='stamps' business_programmes
--                  row (all entry types — matches app.stamp_progress_v323 exactly)
--   closed_slots = sum(stamp_cycles.slots) for that (business, client, programme)
--   filled       = greatest(net_stamps - closed_slots, 0)
-- A cycle CLOSES (completes) only when its final milestone is claimed, recorded as one
-- public.stamp_cycles row (closed_at, slots). Nothing is written when a card starts or fills —
-- "started" is reconstructed by replaying each client's points_ledger + stamp_cycles rows in
-- timestamp order and finding every ledger row at which the running (net - closed) balance
-- crosses from <=0 up to >0: that ledger row is the first stamp of a fresh card. This is an
-- approximation of the real model (a true "cycle_index" boundary), documented in the RESULT.md
-- caveats, but it is built from the same two tables app.stamp_progress_v323 itself reads, not a
-- new definition of anything.
--
-- "Cycles completed" = count of public.stamp_cycles rows closed in the window (both origin
-- 'claimed' and 'migration' — a migration-origin row still means the customer's card portion was
-- closed out, see the migration's own comment). completion_pct relates completions to starts
-- WITHIN the same 90-day window (a period rate, not a true started-cohort's eventual outcome —
-- a card started on day 89 that completes on day 95 is not counted; noted in RESULT.md).
--
-- Drop-off stamp: among clients whose card is currently open (filled > 0) and whose most recent
-- EARN on the stamps programme is 21+ days old (abandoned, per the spec's own definition), the
-- filled position at abandonment. The position with the most abandoned clients is "the drop-off
-- stamp" — the number of stamps most owners' customers get to before they stop coming back for
-- more.
-- =================================================================================================
create or replace function app.owner_brief_fact_stamps_v828(p_business uuid)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_prog        uuid;
  v_window_start timestamptz := now() - interval '90 days';
  v_started     bigint := 0;
  v_completed   bigint := 0;
  v_pct         numeric;
  v_dropoff_pos integer;
  v_dropoff_n   bigint;
  v_evidence    text;
  v_err         text;
begin
  select bp.id into v_prog
    from public.business_programmes bp
   where bp.business_id = p_business and bp.kind = 'stamps';

  if v_prog is null then
    return jsonb_build_object('status', 'no_stamp_card', 'source', 'public.business_programmes');
  end if;

  begin
    with events as (
      select pl.client_id, pl.created_at as ts, pl.points as delta, 1 as ord, 'earn' as kind
        from public.points_ledger pl
       where pl.business_id = p_business and pl.programme_id = v_prog
      union all
      select sc.client_id, sc.closed_at as ts, -sc.slots as delta, 0 as ord, 'close' as kind
        from public.stamp_cycles sc
       where sc.business_id = p_business and sc.programme_id = v_prog
    ),
    running_cte as (
      select e.*,
             sum(delta) over (partition by client_id order by ts, ord
                              rows between unbounded preceding and current row) as running
        from events e
    ),
    ordered as (
      select r.*,
             lag(running) over (partition by client_id order by ts, ord) as prev_running
        from running_cte r
    ),
    starts as (
      select client_id, ts
        from ordered
       where kind = 'earn' and coalesce(prev_running, 0) <= 0 and running > 0
    ),
    last_earn as (
      select client_id, max(ts) as last_earn_at from events where kind = 'earn' group by client_id
    ),
    final_state as (
      select distinct on (client_id) client_id, greatest(running, 0) as filled
        from ordered
       order by client_id, ts desc, ord desc
    ),
    dropoff as (
      select fs.filled as pos, count(*) as n
        from final_state fs
        join last_earn le on le.client_id = fs.client_id
       where fs.filled > 0 and le.last_earn_at <= now() - interval '21 days'
       group by fs.filled
       order by n desc, pos asc
       limit 1
    )
    select
      (select count(*) from starts where ts >= v_window_start),
      (select count(*) from public.stamp_cycles sc
        where sc.business_id = p_business and sc.programme_id = v_prog
          and sc.closed_at >= v_window_start),
      (select pos from dropoff),
      (select n from dropoff)
    into v_started, v_completed, v_dropoff_pos, v_dropoff_n;

    v_pct := case when v_started > 0 then round(100.0 * v_completed / v_started, 1) end;
    v_evidence := case when v_started >= 5 then 'ok' else 'insufficient' end;

    return jsonb_build_object(
      'status', 'ok', 'source', 'public.points_ledger + public.stamp_cycles (app.stamp_progress_v323 model)',
      'from', (v_window_start)::date, 'to', app.sg_today() - 1,
      'cycles_started', v_started,
      'cycles_completed', v_completed,
      'completion_pct', case when v_evidence = 'ok' then v_pct end,
      'evidence', v_evidence,
      'dropoff_stamp', case when v_dropoff_pos is not null then jsonb_build_object(
          'position', v_dropoff_pos, 'abandoned_cards', v_dropoff_n,
          'definition', 'open card (filled>0), no earn in 21+ days; position = stamps filled when they stopped') end,
      'definition', 'cycle "started" = a stamps earn that pushes (lifetime stamps minus stamps '
                    'closed by prior claimed/migrated cycles) from <=0 to >0, replayed per client '
                    'in timestamp order; "completed" = a stamp_cycles row (final milestone claimed '
                    'or a pot migration closure) in the window. completion_pct relates the two '
                    'counts within the SAME window, not a started-cohort''s eventual fate.');
  exception when others then
    get stacked diagnostics v_err = message_text;
    return jsonb_build_object('status', 'unavailable', 'reason', left(v_err, 200),
      'source', 'public.points_ledger + public.stamp_cycles');
  end;
end;
$$;
revoke all on function app.owner_brief_fact_stamps_v828(uuid) from public, anon, authenticated;

-- =================================================================================================
-- 2 · app.owner_brief_fact_bookings_ahead_v828 — "Next seven days of bookings versus the same
--     week last year, and versus last week."
--
-- Reads public.appointments directly (no reader wraps a forward-looking booking count — every CI
-- reader in the codebase is historical). Columns discovered via information_schema on production:
-- business_id, client_id, starts_at (timestamptz), status (booked|completed|cancelled|no_show).
-- "Bookings" = appointment rows whose status is NOT cancelled/no_show (a cancelled slot never
-- happened; a booked-but-not-yet-completed future appointment still counts — most of "next seven
-- days" is necessarily still status='booked'). Bucketed on starts_at converted to Asia/Singapore,
-- matching get_ci_daypart_v1's own time_basis convention for the rest of the brief.
-- =================================================================================================
create or replace function app.owner_brief_fact_bookings_ahead_v828(p_business uuid)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_next_from   date := app.sg_today();
  v_next_to     date := app.sg_today() + 6;
  v_ly_from     date := (app.sg_today() - interval '1 year')::date;
  v_ly_to       date := ((app.sg_today() + 6) - interval '1 year')::date;
  v_lw_from     date := app.sg_today() - 7;
  v_lw_to       date := app.sg_today() - 1;
  v_next_n      bigint;
  v_ly_n        bigint;
  v_lw_n        bigint;
  v_any         boolean;
  v_err         text;
begin
  select exists(select 1 from public.appointments a where a.business_id = p_business) into v_any;
  if not v_any then
    return jsonb_build_object('status', 'no_appointments', 'source', 'public.appointments');
  end if;

  begin
    select count(*) filter (where (a.starts_at at time zone 'Asia/Singapore')::date between v_next_from and v_next_to),
           count(*) filter (where (a.starts_at at time zone 'Asia/Singapore')::date between v_ly_from and v_ly_to),
           count(*) filter (where (a.starts_at at time zone 'Asia/Singapore')::date between v_lw_from and v_lw_to)
      into v_next_n, v_ly_n, v_lw_n
      from public.appointments a
     where a.business_id = p_business
       and a.status not in ('cancelled', 'no_show');

    return jsonb_build_object(
      'status', 'ok', 'source', 'public.appointments',
      'next_7_days', jsonb_build_object('from', v_next_from, 'to', v_next_to, 'bookings', v_next_n),
      'same_week_last_year', jsonb_build_object('from', v_ly_from, 'to', v_ly_to, 'bookings', v_ly_n,
        'delta_pct', app.owner_brief_pct_v826(v_next_n, v_ly_n)),
      'same_days_last_week', jsonb_build_object('from', v_lw_from, 'to', v_lw_to, 'bookings', v_lw_n,
        'delta_pct', app.owner_brief_pct_v826(v_next_n, v_lw_n)),
      'definition', 'counts exclude status cancelled/no_show; bucketed on starts_at in Asia/Singapore.');
  exception when others then
    get stacked diagnostics v_err = message_text;
    return jsonb_build_object('status', 'unavailable', 'reason', left(v_err, 200), 'source', 'public.appointments');
  end;
end;
$$;
revoke all on function app.owner_brief_fact_bookings_ahead_v828(uuid) from public, anon, authenticated;

-- =================================================================================================
-- 3 · app.owner_brief_fact_memberships_due_v828 — "Which memberships expire or failed to renew
--     this month?"
--
-- Reads public.memberships directly. Columns discovered via information_schema on production:
-- business_id, client_id, plan_id, status (active|paused|cancel_at_period_end|cancelled),
-- started_at, current_period_start, current_period_end, created_at, paused_at.
--
-- IMPORTANT — there is NO dunning/payment-failure column or table anywhere in this schema.
-- app.run_membership_renewals (db/migrations/20260719_frenly_v20_financial_engine.sql) is the
-- ONLY writer of status='cancelled', and it never retries or records a failed charge — Stripe SG
-- auto-charge for customer memberships is a deferred owner decision (see CLAUDE.md). Inventing a
-- "failed" number from cancellations would misreport voluntary and involuntary lapses as payment
-- failures, so this fact reports failed_dunning as not_tracked rather than fabricate one (rule 2:
-- fail closed).
--
-- "Cancelled this month" uses current_period_end as the cancellation timestamp: the only writer
-- sets status='cancelled' in the SAME statement that observes current_period_end <= now(), i.e.
-- exactly at that period's end, so current_period_end is an accurate proxy for when the row
-- flipped to cancelled (documented, not asserted as a stored cancelled_at — none exists).
-- =================================================================================================
create or replace function app.owner_brief_fact_memberships_due_v828(p_business uuid)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_any         boolean;
  v_active      bigint;
  v_paused      bigint;
  v_due_n       bigint;
  v_due_names   jsonb;
  v_cancelled_n bigint;
  v_month_start date := date_trunc('month', app.sg_today())::date;
  v_err         text;
begin
  select exists(select 1 from public.memberships m where m.business_id = p_business) into v_any;
  if not v_any then
    return jsonb_build_object('status', 'no_memberships', 'source', 'public.memberships');
  end if;

  begin
    select count(*) filter (where m.status = 'active') into v_active
      from public.memberships m where m.business_id = p_business;

    select count(*) into v_paused
      from public.memberships m where m.business_id = p_business and m.status = 'paused';

    select count(*) into v_due_n
      from public.memberships m
     where m.business_id = p_business and m.status = 'active'
       and m.current_period_end >= now() and m.current_period_end <= now() + interval '30 days';

    select coalesce(jsonb_agg(x.full_name order by x.current_period_end), '[]'::jsonb) into v_due_names
      from (
        select c.full_name, m.current_period_end
          from public.memberships m
          join public.clients c on c.id = m.client_id and c.business_id = m.business_id
         where m.business_id = p_business and m.status = 'active'
           and m.current_period_end >= now() and m.current_period_end <= now() + interval '30 days'
         order by m.current_period_end
         limit 5
      ) x;

    select count(*) into v_cancelled_n
      from public.memberships m
     where m.business_id = p_business and m.status = 'cancelled'
       and (m.current_period_end at time zone 'Asia/Singapore')::date >= v_month_start
       and (m.current_period_end at time zone 'Asia/Singapore')::date <= app.sg_today();

    return jsonb_build_object(
      'status', 'ok', 'source', 'public.memberships',
      'active', v_active,
      'due_to_renew_30d', jsonb_build_object('count', v_due_n, 'clients', v_due_names),
      'failed_dunning_30d', jsonb_build_object('status', 'not_tracked', 'count', null,
        'reason', 'no dunning/payment-failure column exists; Stripe SG auto-charge for customer memberships is deferred (CLAUDE.md)'),
      'paused', v_paused,
      'cancelled_this_month', jsonb_build_object('count', v_cancelled_n, 'from', v_month_start, 'to', app.sg_today(),
        'definition', 'status=cancelled with current_period_end in this SG month — the only writer sets both together'));
  exception when others then
    get stacked diagnostics v_err = message_text;
    return jsonb_build_object('status', 'unavailable', 'reason', left(v_err, 200), 'source', 'public.memberships');
  end;
end;
$$;
revoke all on function app.owner_brief_fact_memberships_due_v828(uuid) from public, anon, authenticated;

-- =================================================================================================
-- 4 · app.owner_brief_fact_slot_trend_v828 — "Is the quiet new, or always like that?"
--
-- Calls the gated reader public.get_ci_daypart_v1(p_business, from, to, null, now()) AS THE
-- CALLER (owner claims must already be set — same contract as app.owner_brief_compose_v826) for
-- three consecutive, non-overlapping 28-day windows ending yesterday: weeks 1-4 (most recent),
-- 5-8, 9-12 back. Reads the reader's own 'weekdays' (label, visits, evidence) and 'hours' (hour,
-- visits) arrays — no new definition of a visit; get_ci_daypart_v1's own scope/exclusions apply.
--
-- "Slowest weekday" = the weekday with evidence.status='ok' and the fewest visits in the MOST
-- RECENT window (w1); that SAME weekday is then tracked across all three windows so the trend is
-- about one day, not whichever day happened to be slowest in each window independently.
-- share_pct (a new, explicitly-defined ratio, not app.rate_block_v1's visits-per-occurrence) =
-- that weekday's visits as a percentage of the window's total visits.
-- trend: comparing the most recent window's share to the oldest window's share, >=3 points either
-- way is 'worsening' (share fell — this day is relatively even quieter now) or 'improving' (share
-- rose — catching up); otherwise 'flat'. Evidence insufficient when any window totals <30 visits.
-- =================================================================================================
create or replace function app.owner_brief_daypart_window_v828(p_wd jsonb)
returns jsonb
language sql
immutable
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
  select jsonb_build_object(
    'total_visits', coalesce((select sum((w->>'visits')::bigint) from jsonb_array_elements(coalesce(p_wd->'weekdays','[]'::jsonb)) w), 0),
    'slowest_weekday', (select jsonb_build_object('dow', (w->>'dow')::int, 'label', w->>'label', 'visits', (w->>'visits')::bigint)
                          from jsonb_array_elements(coalesce(p_wd->'weekdays','[]'::jsonb)) w
                         where w#>>'{evidence,status}' = 'ok'
                         order by (w->>'visits')::bigint asc, (w->>'dow')::int asc limit 1),
    'block_14_17', coalesce((select sum((h->>'visits')::bigint) from jsonb_array_elements(coalesce(p_wd->'hours','[]'::jsonb)) h
                               where (h->>'hour')::int in (14,15,16)), 0),
    'block_18_21', coalesce((select sum((h->>'visits')::bigint) from jsonb_array_elements(coalesce(p_wd->'hours','[]'::jsonb)) h
                               where (h->>'hour')::int in (18,19,20)), 0));
$$;
revoke all on function app.owner_brief_daypart_window_v828(jsonb) from public, anon, authenticated;

create or replace function app.owner_brief_fact_slot_trend_v828(p_business uuid)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v1_to date := app.sg_today() - 1;  v1_from date := v1_to - 27;
  v2_to date := v1_from - 1;         v2_from date := v2_to - 27;
  v3_to date := v2_from - 1;         v3_from date := v3_to - 27;
  v1 jsonb; v2 jsonb; v3 jsonb;
  v_ref_dow int; v_ref_label text;
  v1_total bigint; v2_total bigint; v3_total bigint;
  v1_slow_v bigint; v2_slow_v bigint; v3_slow_v bigint;
  v1_share numeric; v2_share numeric; v3_share numeric;
  v1_ok boolean; v2_ok boolean; v3_ok boolean;
  v_trend text;
  v_err text;
begin
  begin
    v1 := public.get_ci_daypart_v1(p_business, v1_from, v1_to, null, now());
    v2 := public.get_ci_daypart_v1(p_business, v2_from, v2_to, null, now());
    v3 := public.get_ci_daypart_v1(p_business, v3_from, v3_to, null, now());

    select (w->>'dow')::int, w->>'label'
      into v_ref_dow, v_ref_label
      from jsonb_array_elements(coalesce(v1->'weekdays','[]'::jsonb)) w
     where w#>>'{evidence,status}' = 'ok'
     order by (w->>'visits')::bigint asc, (w->>'dow')::int asc limit 1;

    select coalesce(sum((w->>'visits')::bigint),0) into v1_total from jsonb_array_elements(coalesce(v1->'weekdays','[]'::jsonb)) w;
    select coalesce(sum((w->>'visits')::bigint),0) into v2_total from jsonb_array_elements(coalesce(v2->'weekdays','[]'::jsonb)) w;
    select coalesce(sum((w->>'visits')::bigint),0) into v3_total from jsonb_array_elements(coalesce(v3->'weekdays','[]'::jsonb)) w;

    if v_ref_dow is not null then
      select (w->>'visits')::bigint into v1_slow_v from jsonb_array_elements(coalesce(v1->'weekdays','[]'::jsonb)) w where (w->>'dow')::int = v_ref_dow;
      select (w->>'visits')::bigint into v2_slow_v from jsonb_array_elements(coalesce(v2->'weekdays','[]'::jsonb)) w where (w->>'dow')::int = v_ref_dow;
      select (w->>'visits')::bigint into v3_slow_v from jsonb_array_elements(coalesce(v3->'weekdays','[]'::jsonb)) w where (w->>'dow')::int = v_ref_dow;
      v1_share := case when v1_total > 0 then round(100.0 * v1_slow_v / v1_total, 1) end;
      v2_share := case when v2_total > 0 then round(100.0 * v2_slow_v / v2_total, 1) end;
      v3_share := case when v3_total > 0 then round(100.0 * v3_slow_v / v3_total, 1) end;
    end if;

    v1_ok := v1_total >= 30; v2_ok := v2_total >= 30; v3_ok := v3_total >= 30;

    if v_ref_dow is null or not (v1_ok and v2_ok and v3_ok) or v1_share is null or v3_share is null then
      v_trend := null;
    elsif (v1_share - v3_share) <= -3 then v_trend := 'worsening';
    elsif (v1_share - v3_share) >= 3 then v_trend := 'improving';
    else v_trend := 'flat';
    end if;

    return jsonb_build_object(
      'status', 'ok', 'source', 'public.get_ci_daypart_v1',
      'reference_weekday', case when v_ref_dow is not null then jsonb_build_object('dow', v_ref_dow, 'label', v_ref_label,
        'chosen_from', 'weeks 1-4 (most recent window)') end,
      'windows', jsonb_build_object(
        'weeks_1_4',  jsonb_build_object('from', v1_from, 'to', v1_to) || app.owner_brief_daypart_window_v828(v1)
                       || jsonb_build_object('reference_weekday_share_pct', v1_share, 'evidence', case when v1_ok then 'ok' else 'insufficient' end),
        'weeks_5_8',  jsonb_build_object('from', v2_from, 'to', v2_to) || app.owner_brief_daypart_window_v828(v2)
                       || jsonb_build_object('reference_weekday_share_pct', v2_share, 'evidence', case when v2_ok then 'ok' else 'insufficient' end),
        'weeks_9_12', jsonb_build_object('from', v3_from, 'to', v3_to) || app.owner_brief_daypart_window_v828(v3)
                       || jsonb_build_object('reference_weekday_share_pct', v3_share, 'evidence', case when v3_ok then 'ok' else 'insufficient' end)),
      'trend', v_trend,
      'definition', 'reference_weekday is the slowest evidence-ok weekday in weeks 1-4, tracked '
                    'across all three windows; share_pct = that weekday''s visits / window total '
                    'visits * 100; trend compares weeks 1-4 share to weeks 9-12 share, >=3pt move '
                    'either way, else flat; blocks are hour-of-day sums from the same reader.');
  exception when others then
    get stacked diagnostics v_err = message_text;
    return jsonb_build_object('status', 'unavailable', 'reason', left(v_err, 200), 'source', 'public.get_ci_daypart_v1');
  end;
end;
$$;
revoke all on function app.owner_brief_fact_slot_trend_v828(uuid) from public, anon, authenticated;

-- =============================================================================================
-- Composer v828: the v826 seven facts, plus the answers the audit found the data for
-- =============================================================================================
create or replace function app.owner_brief_compose_v828(p_business uuid)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_base  jsonb;
  v_more  jsonb := '{}'::jsonb;
  v_name  text;
  v_fact  jsonb;
  v_err   text;
begin
  v_base := app.owner_brief_compose_v826(p_business);
  -- Each fact is its own function and its own failure domain: a fact that throws is recorded as
  -- unavailable with the reason, and the other facts still land.
  foreach v_name in array array[
    'day','month','liability','points_expiry',
    'items','dying','pairs','discounts','stock',
    'staff','multi_outlet','birthdays','member_lift','referrals','anomalies',
    'stamps','bookings_ahead','memberships_due','slot_trend'] loop
    begin
      execute format('select app.owner_brief_fact_%s_v828($1)', v_name) into v_fact using p_business;
      v_more := v_more || jsonb_build_object(v_name, coalesce(v_fact, jsonb_build_object('status','unavailable','reason','null result')));
    exception when others then
      get stacked diagnostics v_err = message_text;
      v_more := v_more || jsonb_build_object(v_name, jsonb_build_object('status','unavailable','reason', left(v_err, 200)));
    end;
  end loop;
  return v_base || jsonb_build_object('contract_version', 'owner_brief_v828', 'facts', v_more);
end;
$$;
revoke all on function app.owner_brief_compose_v828(uuid) from public, anon, authenticated;

-- The nightly loop now composes v828. Restated from the live v826 body; only the composer call
-- and the version note change.
create or replace function app.refresh_owner_brief_v826(p_business uuid default null)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  r            record;
  v_prior_sub  text := current_setting('request.jwt.claim.sub', true);
  v_prior_cl   text := current_setting('request.jwt.claims', true);
  v_payload    jsonb;
  v_started    timestamptz;
  v_ok int := 0; v_failed int := 0; v_skipped int := 0; v_seen int := 0;
  v_err text;
begin
  for r in
    select b.id as business_id, o.owner_uid
      from public.businesses b
      left join lateral (
        select s.user_id as owner_uid
          from public.staff s
         where s.business_id = b.id and s.role = 'owner' and s.active and s.user_id is not null
         order by s.created_at, s.user_id limit 1) o on true
     where (p_business is null or b.id = p_business)
       and (p_business is not null
            or exists (select 1 from public.sales sl
                        where sl.business_id = b.id and sl.created_at > now() - interval '30 days'))
     order by b.id
  loop
    v_seen := v_seen + 1;
    if r.owner_uid is null then
      v_skipped := v_skipped + 1;
      continue;
    end if;
    v_started := clock_timestamp();
    perform set_config('request.jwt.claim.sub', r.owner_uid::text, true);
    perform set_config('request.jwt.claims',
      jsonb_build_object('sub', r.owner_uid, 'role', 'authenticated', 'aud', 'authenticated')::text, true);
    begin
      v_payload := app.owner_brief_compose_v828(r.business_id);
      insert into public.owner_brief_snapshots_v1 (business_id, as_of, computed_at, status, payload, error, duration_ms)
      values (r.business_id, (v_payload ->> 'as_of')::date, now(), 'ready', v_payload, null,
              (extract(epoch from clock_timestamp() - v_started) * 1000)::int)
      on conflict (business_id) do update
        set as_of = excluded.as_of, computed_at = excluded.computed_at, status = excluded.status,
            payload = excluded.payload, error = null, duration_ms = excluded.duration_ms;
      v_ok := v_ok + 1;
    exception when others then
      get stacked diagnostics v_err = message_text;
      insert into public.owner_brief_snapshots_v1 (business_id, as_of, computed_at, status, payload, error, duration_ms)
      values (r.business_id, app.sg_today() - 1, now(), 'error', '{}'::jsonb, left(v_err, 500),
              (extract(epoch from clock_timestamp() - v_started) * 1000)::int)
      on conflict (business_id) do update
        set as_of = excluded.as_of, computed_at = excluded.computed_at, status = 'error',
            payload = '{}'::jsonb, error = excluded.error, duration_ms = excluded.duration_ms;
      v_failed := v_failed + 1;
    end;
    perform set_config('request.jwt.claim.sub', coalesce(v_prior_sub, ''), true);
    perform set_config('request.jwt.claims', coalesce(v_prior_cl, ''), true);
  end loop;
  return jsonb_build_object('businesses', v_seen, 'ok', v_ok, 'failed', v_failed, 'skipped', v_skipped);
end;
$$;
revoke all on function app.refresh_owner_brief_v826(uuid) from public, anon, authenticated, service_role;

-- =============================================================================================
-- In-transaction verification
-- =============================================================================================
do $v828_verify$
declare
  v_name text;
begin
  foreach v_name in array array[
    'day','month','liability','points_expiry','items','dying','pairs','discounts','stock',
    'staff','multi_outlet','birthdays','member_lift','referrals','anomalies',
    'stamps','bookings_ahead','memberships_due','slot_trend'] loop
    if to_regprocedure(format('app.owner_brief_fact_%s_v828(uuid)', v_name)) is null then
      raise exception 'v828: fact function % is missing', v_name;
    end if;
    if has_function_privilege('anon', format('app.owner_brief_fact_%s_v828(uuid)', v_name), 'execute')
       or has_function_privilege('authenticated', format('app.owner_brief_fact_%s_v828(uuid)', v_name), 'execute') then
      raise exception 'v828: a non-owner role can execute fact %', v_name;
    end if;
  end loop;
  if has_function_privilege('anon', 'app.owner_brief_compose_v828(uuid)', 'execute')
     or has_function_privilege('authenticated', 'app.owner_brief_compose_v828(uuid)', 'execute') then
    raise exception 'v828: a non-owner role can execute the composer';
  end if;
  if has_function_privilege('authenticated', 'app.refresh_owner_brief_v826(uuid)', 'execute')
     or has_function_privilege('service_role', 'app.refresh_owner_brief_v826(uuid)', 'execute') then
    raise exception 'v828: a non-owner role can run the nightly refresh';
  end if;
end
$v828_verify$;

commit;
