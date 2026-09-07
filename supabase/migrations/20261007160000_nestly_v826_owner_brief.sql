-- NESTLY v826 — the owner brief: computed once a night, read as one row.
--
-- WHY THIS EXISTS. The owner asked (2026-09-08) for the questions a business owner actually
-- asks — am I okay, what is wrong, why, what should I do, did last week's thing work — answered
-- at the top of the business dashboard, and for Supabase not to be overloaded doing it. Today the
-- Insights page fires 27 readers on open and the Home dashboard 8. Every reader the brief needs
-- already exists (get_dashboard_summary_v155, get_ci_daypart_v1, get_ci_branch_comparison_v1,
-- get_customer_lifecycle_v107, get_attention_list_v548, get_ci_reward_popularity_v1,
-- get_growth_daily_briefing_v108). What does not exist is a way to read their answers WITHOUT
-- running them at request time.
--
-- WHAT THIS MIGRATION DOES.
--   1. public.owner_brief_snapshots_v1 — one row per business, API-unreadable (RLS on, no
--      policy, all privileges revoked). Only the RPC below reads it.
--   2. app.owner_brief_compose_v826(p_business) — calls the existing readers AS THE CALLER and
--      composes seven facts. It never reads a base table for a figure: every number is what the
--      owner would see on the corresponding screen. Each reader is wrapped on its own, so a
--      reader that refuses or fails yields {status:'unavailable'} for that fact, never a made-up
--      number and never a lost brief.
--   3. app.refresh_owner_brief_v826(p_business default null) — the nightly loop. For every
--      business with a sale in the last 30 days and an active owner login it publishes that
--      owner's claims (the v277 / v565 precedent), composes, upserts, and restores the claims.
--      A business whose composition throws is written as status='error' with the reason, so the
--      dashboard says "could not be prepared", not yesterday's numbers.
--   4. public.get_owner_brief_v1(p_business) — the only reader. Same gate as the dashboard
--      summary the header sits above: a signed-in caller with view_sales on a business whose
--      dashboard module is on. Adds data_status: ready | stale (older than 30 h) | error |
--      not_computed.
--   5. cron 'nestly-v826-owner-brief' at 20:40 UTC (04:40 Singapore) — after the 19:xx–20:15
--      expiry and sweep jobs, before any shop opens. One sequential pass on one connection.
--
-- WHAT THIS MIGRATION DOES NOT DO. No WhatsApp send. No new Insights panel. No new definition
-- of revenue or visits — the week figure is get_dashboard_summary_v155's signed-ledger figure,
-- the baseline is the same reader over the eight prior weeks divided by eight.
--
-- ACCEPTANCE: db/tests/v826_owner_brief.sql (rolled back, against production, as ÉLAN's owner).

begin;

-- =============================================================================================
-- 1 · The snapshot table
-- =============================================================================================
create table if not exists public.owner_brief_snapshots_v1 (
  business_id  uuid primary key references public.businesses(id) on delete cascade,
  as_of        date not null,
  computed_at  timestamptz not null default now(),
  status       text not null check (status in ('ready','error')),
  payload      jsonb not null default '{}'::jsonb,
  error        text,
  duration_ms  integer
);

alter table public.owner_brief_snapshots_v1 enable row level security;
revoke all privileges on table public.owner_brief_snapshots_v1 from public, anon, authenticated;

comment on table public.owner_brief_snapshots_v1 is
  'nestly_v826: the nightly owner brief, one row per business. API-unreadable; public.get_owner_brief_v1 is the only reader and app.refresh_owner_brief_v826 the only writer.';

-- =============================================================================================
-- 2 · Composer — runs as whoever the claims say; every figure comes from an existing reader
-- =============================================================================================
create or replace function app.owner_brief_pct_v826(p_current numeric, p_base numeric)
returns numeric
language sql immutable
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
  select case when p_base is null or p_base = 0 then null
              else round(100.0 * (p_current - p_base) / p_base, 1) end;
$$;
revoke all on function app.owner_brief_pct_v826(numeric, numeric) from public, anon, authenticated;

create or replace function app.owner_brief_compose_v826(p_business uuid)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_to        date := app.sg_today() - 1;           -- yesterday: the last complete day
  v_from      date := app.sg_today() - 7;           -- seven complete days
  v_bto       date := app.sg_today() - 8;
  v_bfrom     date := app.sg_today() - 63;          -- the eight weeks before those seven days
  v_week      jsonb; v_base jsonb; v_life jsonb; v_att jsonb; v_rew jsonb; v_grow jsonb;
  v_day       jsonb; v_cmp_w jsonb; v_cmp_b jsonb;
  v_branches  integer;
  v_fact_week jsonb; v_fact_out jsonb; v_fact_day jsonb; v_fact_cust jsonb;
  v_fact_risk jsonb; v_fact_rew jsonb; v_fact_act jsonb;
  v_unavail   jsonb;
  v_rev bigint; v_vis bigint; v_brev numeric; v_bvis numeric; v_basket numeric; v_bbasket numeric;
  v_rev_d numeric; v_vis_d numeric; v_bas_d numeric;
  v_hours     jsonb; v_first int; v_last int; v_h int; v_sum bigint; v_min bigint; v_min_h int;
  v_total_h   bigint;
  v_wd        jsonb;
  v_err       text;
begin
  select count(*) into v_branches from public.branches br where br.business_id = p_business;

  -- 2.1 · This week against a normal week ------------------------------------------------------
  begin
    v_week := public.get_dashboard_summary_v155(p_business, v_from, v_to, 'all', array[]::uuid[], null);
    v_base := public.get_dashboard_summary_v155(p_business, v_bfrom, v_bto, 'all', array[]::uuid[], null);
    v_rev  := coalesce((v_week ->> 'revenue_cents')::bigint, 0);
    v_vis  := coalesce((v_week ->> 'visits')::bigint, 0);
    v_brev := coalesce((v_base ->> 'revenue_cents')::numeric, 0) / 8.0;
    v_bvis := coalesce((v_base ->> 'visits')::numeric, 0) / 8.0;
    v_basket  := case when v_vis  > 0 then round(v_rev  / v_vis)  else null end;
    v_bbasket := case when v_bvis > 0 then round(v_brev / v_bvis) else null end;
    v_rev_d := app.owner_brief_pct_v826(v_rev, v_brev);
    v_vis_d := app.owner_brief_pct_v826(v_vis, v_bvis);
    v_bas_d := app.owner_brief_pct_v826(v_basket, v_bbasket);
    v_fact_week := jsonb_build_object(
      'status', 'ok',
      'from', v_from, 'to', v_to,
      'revenue_cents', v_rev,
      'visits', v_vis,
      'basket_cents', v_basket,
      'new_customers', coalesce((v_week ->> 'new_customers')::int, 0),
      'baseline', jsonb_build_object(
        'weeks', 8, 'from', v_bfrom, 'to', v_bto,
        'revenue_cents', round(v_brev), 'visits', round(v_bvis, 1), 'basket_cents', v_bbasket,
        'evidence', case when coalesce((v_base ->> 'visits')::bigint, 0) >= 20 then 'ok' else 'insufficient' end),
      'revenue_delta_pct', case when coalesce((v_base ->> 'visits')::bigint, 0) >= 20 then v_rev_d end,
      'visits_delta_pct',  case when coalesce((v_base ->> 'visits')::bigint, 0) >= 20 then v_vis_d end,
      'basket_delta_pct',  case when coalesce((v_base ->> 'visits')::bigint, 0) >= 20 then v_bas_d end,
      'driver', case
        when coalesce((v_base ->> 'visits')::bigint, 0) < 20 or v_rev_d is null then null
        when v_vis_d is null or v_bas_d is null then null
        when abs(v_vis_d) >= abs(v_bas_d) then 'visits' else 'basket' end,
      'definition', jsonb_build_object(
        'revenue', v_week #>> '{scope,revenue}', 'visits', v_week #>> '{scope,visits}',
        'source', 'public.get_dashboard_summary_v155'));
  exception when others then
    get stacked diagnostics v_err = message_text;
    v_fact_week := jsonb_build_object('status', 'unavailable', 'reason', left(v_err, 200),
                                      'source', 'public.get_dashboard_summary_v155');
  end;

  -- 2.2 · Outlets: which one carried the week, which one is dragging (multi-branch only) --------
  if v_branches > 1 then
    begin
      v_cmp_w := public.get_ci_branch_comparison_v1(p_business, v_from, v_to, now());
      v_cmp_b := public.get_ci_branch_comparison_v1(p_business, v_bfrom, v_bto, now());
      with w as (
        select (b -> 'branch' ->> 'id')::uuid as id, b -> 'branch' ->> 'name' as name,
               coalesce((b ->> 'revenue_cents')::bigint, 0) as rev, coalesce((b ->> 'visits')::bigint, 0) as vis
        from jsonb_array_elements(coalesce(v_cmp_w -> 'branches', '[]'::jsonb)) b),
      bl as (
        select (b -> 'branch' ->> 'id')::uuid as id,
               coalesce((b ->> 'revenue_cents')::numeric, 0) / 8.0 as rev, coalesce((b ->> 'visits')::numeric, 0) / 8.0 as vis,
               coalesce((b ->> 'visits')::bigint, 0) as vis_total
        from jsonb_array_elements(coalesce(v_cmp_b -> 'branches', '[]'::jsonb)) b),
      rows_ as (
        select w.id, w.name, w.rev, w.vis, round(bl.rev) as brev, round(bl.vis, 1) as bvis,
               case when bl.vis_total >= 20 then app.owner_brief_pct_v826(w.rev, bl.rev) end as delta_pct,
               case when bl.vis_total >= 20 then 'ok' else 'insufficient' end as evidence
        from w left join bl on bl.id = w.id)
      select jsonb_build_object(
        'status', 'ok', 'source', 'public.get_ci_branch_comparison_v1',
        'outlets', coalesce((select jsonb_agg(jsonb_build_object(
            'branch_id', id, 'name', name, 'revenue_cents', rev, 'visits', vis,
            'baseline_revenue_cents', brev, 'baseline_visits', bvis,
            'revenue_delta_pct', delta_pct, 'evidence', evidence) order by delta_pct desc nulls last) from rows_), '[]'::jsonb),
        'best',  (select jsonb_build_object('name', name, 'revenue_delta_pct', delta_pct) from rows_ where delta_pct is not null order by delta_pct desc limit 1),
        'worst', case when (select count(*) from rows_ where delta_pct is not null) >= 2
                 then (select jsonb_build_object('name', name, 'revenue_delta_pct', delta_pct) from rows_ where delta_pct is not null order by delta_pct asc  limit 1) end)
      into v_fact_out;
    exception when others then
      get stacked diagnostics v_err = message_text;
      v_fact_out := jsonb_build_object('status', 'unavailable', 'reason', left(v_err, 200),
                                       'source', 'public.get_ci_branch_comparison_v1');
    end;
  else
    v_fact_out := jsonb_build_object('status', 'single_outlet');
  end if;

  -- 2.3 · When is it busy, when is it dead (eight weeks, hour and weekday) ---------------------
  begin
    v_day := public.get_ci_daypart_v1(p_business, v_bfrom, v_to, null, now());
    v_hours := coalesce(v_day -> 'hours', '[]'::jsonb);
    -- trading span: the first and last hour that carries real trade (at least five visits over
    -- the eight weeks AND at least 2% of them), so an hour the shop is simply closed is never
    -- reported as its "quietest".
    select sum((h ->> 'visits')::bigint) into v_total_h from jsonb_array_elements(v_hours) h;
    select min((h ->> 'hour')::int), max((h ->> 'hour')::int)
      into v_first, v_last
      from jsonb_array_elements(v_hours) h
     where coalesce((h ->> 'visits')::bigint, 0) >= greatest(5, ceil(0.02 * coalesce(v_total_h, 0)));
    v_min := null; v_min_h := null;
    if v_first is not null and v_last - v_first >= 3 then
      for v_h in v_first .. (v_last - 2) loop
        select sum(coalesce((h ->> 'visits')::bigint, 0)) into v_sum
          from jsonb_array_elements(v_hours) h
         where (h ->> 'hour')::int between v_h and v_h + 2;
        if v_min is null or v_sum < v_min then v_min := v_sum; v_min_h := v_h; end if;
      end loop;
    end if;
    -- slowest weekday among those with enough evidence, by visits per occurrence
    select to_jsonb(x) into v_wd from (
      select w ->> 'label' as label, (w ->> 'dow')::int as dow,
             (w #>> '{visits_per_occurrence,pct}')::numeric as visits_per_occurrence_pct,
             (w ->> 'visits')::int as visits
        from jsonb_array_elements(coalesce(v_day -> 'weekdays', '[]'::jsonb)) w
       where w #>> '{evidence,status}' = 'ok'
       order by (w #>> '{visits_per_occurrence,pct}')::numeric asc nulls last, (w ->> 'dow')::int
       limit 1) x;
    v_fact_day := jsonb_build_object(
      'status', 'ok', 'source', 'public.get_ci_daypart_v1', 'from', v_bfrom, 'to', v_to,
      'busiest_weekday', v_day -> 'busiest_weekday',
      'slowest_weekday', case when (select count(*) from jsonb_array_elements(coalesce(v_day -> 'weekdays', '[]'::jsonb)) w
                                     where w #>> '{evidence,status}' = 'ok') >= 2 then v_wd end,
      'quietest_hours', case when v_min_h is not null and coalesce(v_total_h, 0) >= 30 then jsonb_build_object(
          'start_hour', v_min_h, 'end_hour', v_min_h + 3, 'visits', v_min,
          'share_pct', round(100.0 * v_min / v_total_h, 1), 'trading_from', v_first, 'trading_to', v_last + 1) end,
      'evidence', case when coalesce(v_total_h, 0) >= 30 then 'ok' else 'insufficient' end);
  exception when others then
    get stacked diagnostics v_err = message_text;
    v_fact_day := jsonb_build_object('status', 'unavailable', 'reason', left(v_err, 200),
                                     'source', 'public.get_ci_daypart_v1');
  end;

  -- 2.4 · New against returning ----------------------------------------------------------------
  begin
    v_life := public.get_customer_lifecycle_v107(p_business, v_from, v_to + 1, null, now());
    v_fact_cust := jsonb_build_object(
      'status', 'ok', 'source', 'public.get_customer_lifecycle_v107',
      'new_customers', (v_life #>> '{metrics,new_customers}')::int,
      'returning_customers', (v_life #>> '{metrics,existing_returning_customers}')::int,
      'repeat_in_period_rate_pct', (v_life #>> '{metrics,repeat_in_period_rate_pct}')::numeric,
      'identified_pct', (v_life #>> '{coverage,identified_transaction_pct}')::numeric);
  exception when others then
    get stacked diagnostics v_err = message_text;
    v_fact_cust := jsonb_build_object('status', 'unavailable', 'reason', left(v_err, 200),
                                      'source', 'public.get_customer_lifecycle_v107');
  end;

  -- 2.5 · Regulars whose usual visit is overdue ------------------------------------------------
  begin
    v_att := public.get_attention_list_v548(p_business, null, 5);
    v_fact_risk := jsonb_build_object(
      'status', 'ok', 'source', 'public.get_attention_list_v548',
      'overdue', coalesce((v_att #>> '{summary,overdue}')::int, 0),
      'due', coalesce((v_att #>> '{summary,due}')::int, 0),
      'slipping', coalesce((v_att #>> '{summary,slipping}')::int, 0),
      'considered', coalesce((v_att #>> '{summary,considered}')::int, 0),
      'monthly_at_risk_cents', coalesce((v_att #>> '{summary,monthly_at_risk_cents}')::bigint, 0));
  exception when others then
    get stacked diagnostics v_err = message_text;
    v_fact_risk := jsonb_build_object('status', 'unavailable', 'reason', left(v_err, 200),
                                      'source', 'public.get_attention_list_v548');
  end;

  -- 2.6 · Which reward is popular, which is ignored (eight weeks) ------------------------------
  begin
    v_rew := public.get_ci_reward_popularity_v1(p_business, v_bfrom, v_to, null, now());
    v_fact_rew := jsonb_build_object(
      'status', 'ok', 'source', 'public.get_ci_reward_popularity_v1', 'from', v_bfrom, 'to', v_to,
      'redemptions', coalesce((v_rew #>> '{totals,redemptions}')::int, 0),
      'redeeming_customers', coalesce((v_rew #>> '{totals,customers}')::int, 0),
      'eligible_customers', coalesce((v_rew #>> '{totals,eligible_customers}')::int, 0),
      'top', (select jsonb_build_object('name', r ->> 'reward_name', 'redemptions', (r ->> 'redemptions')::int,
                                        'evidence', r #>> '{evidence,status}')
                from jsonb_array_elements(coalesce(v_rew -> 'rewards', '[]'::jsonb)) r
               where coalesce((r ->> 'redemptions')::int, 0) > 0
               order by (r ->> 'redemptions')::int desc limit 1),
      'ignored_active', (select count(*) from jsonb_array_elements(coalesce(v_rew -> 'rewards', '[]'::jsonb)) r
                          where (r ->> 'active')::boolean and coalesce((r ->> 'redemptions')::int, 0) = 0));
  exception when others then
    get stacked diagnostics v_err = message_text;
    v_fact_rew := jsonb_build_object('status', 'unavailable', 'reason', left(v_err, 200),
                                     'source', 'public.get_ci_reward_popularity_v1');
  end;

  -- 2.7 · One thing to do, and what the last one did -------------------------------------------
  begin
    v_grow := public.get_growth_daily_briefing_v108(p_business, null);
    v_fact_act := jsonb_build_object(
      'status', 'ok', 'source', 'public.get_growth_daily_briefing_v108',
      'data_status', v_grow ->> 'data_status',
      'top_action', case when v_grow -> 'top_action' is null or jsonb_typeof(v_grow -> 'top_action') = 'null' then null
        else jsonb_build_object(
          'recommendation_id', v_grow #>> '{top_action,recommendation_id}',
          'title', v_grow #>> '{top_action,title}',
          'finding', v_grow #> '{top_action,finding}',
          'audience', v_grow #> '{top_action,audience}',
          'estimated_cost_cents', (v_grow #>> '{top_action,estimated_cost_cents}')::bigint,
          'expected_incremental_revenue', v_grow #> '{top_action,expected_incremental_revenue}',
          'offer', v_grow #>> '{top_action,action,offer}',
          'expires_at', v_grow #>> '{top_action,action,expires_at}') end,
      'last_result', v_grow -> 'latest_completed_action');
  exception when others then
    get stacked diagnostics v_err = message_text;
    v_fact_act := jsonb_build_object('status', 'unavailable', 'reason', left(v_err, 200),
                                     'source', 'public.get_growth_daily_briefing_v108');
  end;

  return jsonb_build_object(
    'contract_version', 'owner_brief_v826',
    'as_of', v_to,
    'week', v_fact_week,
    'outlets', v_fact_out,
    'daypart', v_fact_day,
    'customers', v_fact_cust,
    'at_risk', v_fact_risk,
    'rewards', v_fact_rew,
    'action', v_fact_act);
end;
$$;
revoke all on function app.owner_brief_compose_v826(uuid) from public, anon, authenticated;

-- =============================================================================================
-- 3 · The nightly refresh — impersonates each business's owner, one at a time
-- =============================================================================================
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
      v_payload := app.owner_brief_compose_v826(r.business_id);
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
-- 4 · The one reader
-- =============================================================================================
create or replace function public.get_owner_brief_v1(p_business uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_row public.owner_brief_snapshots_v1%rowtype;
begin
  if auth.uid() is null or not app.has_perm(p_business, 'view_sales') then
    raise exception 'sales access is required' using errcode = '42501';
  end if;
  if not app.can_module(p_business, 'dashboard') then
    raise exception 'dashboard module is off for this business' using errcode = '42501';
  end if;

  select * into v_row from public.owner_brief_snapshots_v1 s where s.business_id = p_business;

  return jsonb_build_object(
    'contract_version', 'owner_brief_v826',
    'data_status', case
      when v_row.business_id is null then 'not_computed'
      when v_row.status = 'error' then 'error'
      when v_row.computed_at < now() - interval '30 hours' then 'stale'
      else 'ready' end,
    'as_of', v_row.as_of,
    'computed_at', v_row.computed_at,
    'brief', case when v_row.status = 'ready' then v_row.payload else null end);
end;
$$;
revoke all on function public.get_owner_brief_v1(uuid) from public, anon;
grant execute on function public.get_owner_brief_v1(uuid) to authenticated, service_role;

-- =============================================================================================
-- 5 · The nightly slot: 04:40 Singapore, after the 03:15–04:15 sweeps, before any shop opens
-- =============================================================================================
select cron.schedule('nestly-v826-owner-brief', '40 20 * * *',
  $$select app.refresh_owner_brief_v826()$$);

-- =============================================================================================
-- 6 · In-transaction verification: the boundary holds before this commits
-- =============================================================================================
do $v826_verify$
declare
  v_ok boolean;
begin
  if has_table_privilege('anon', 'public.owner_brief_snapshots_v1', 'select')
     or has_table_privilege('authenticated', 'public.owner_brief_snapshots_v1', 'select') then
    raise exception 'v826: the snapshot table is readable through the API';
  end if;
  if has_function_privilege('anon', 'app.refresh_owner_brief_v826(uuid)', 'execute')
     or has_function_privilege('authenticated', 'app.refresh_owner_brief_v826(uuid)', 'execute')
     or has_function_privilege('service_role', 'app.refresh_owner_brief_v826(uuid)', 'execute') then
    raise exception 'v826: a non-owner role can run the nightly refresh';
  end if;
  if has_function_privilege('anon', 'app.owner_brief_compose_v826(uuid)', 'execute')
     or has_function_privilege('authenticated', 'app.owner_brief_compose_v826(uuid)', 'execute') then
    raise exception 'v826: a non-owner role can run the composer';
  end if;
  if has_function_privilege('anon', 'public.get_owner_brief_v1(uuid)', 'execute') then
    raise exception 'v826: anon can execute get_owner_brief_v1';
  end if;
  if not has_function_privilege('authenticated', 'public.get_owner_brief_v1(uuid)', 'execute') then
    raise exception 'v826: authenticated cannot execute get_owner_brief_v1';
  end if;
  -- a sessionless caller is refused, never handed an empty brief
  begin
    perform public.get_owner_brief_v1('00000000-0000-0000-0000-000000000000');
    v_ok := true;
  exception when insufficient_privilege then
    v_ok := false;
  end;
  if v_ok then
    raise exception 'v826: get_owner_brief_v1 admits a sessionless caller';
  end if;
  if not exists (select 1 from cron.job where jobname = 'nestly-v826-owner-brief') then
    raise exception 'v826: the nightly job is not scheduled';
  end if;
end
$v826_verify$;

commit;
