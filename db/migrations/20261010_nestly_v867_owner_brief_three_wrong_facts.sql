-- nestly_v867 — three wrong facts on the owner's Home "Your brief" card.
--
-- The brief (nestly_v826) is composed nightly from the nineteen fact functions nestly_v828 added
-- and cached in public.owner_brief_snapshots_v1. Three of those facts print numbers that are not
-- true. Each is fixed here in place; nothing else about the brief changes.
--
-- (A) A RETIRED MODULE WAS BEING BILLED AS A LIVE LIABILITY.
--     app.owner_brief_fact_liability_v828 asked public.get_reports_summary for
--     gift_card_liability_cents and folded it into known_cents_total, which the card renders as
--     "If every customer redeemed tomorrow, you would owe at least $X."
--     Gift cards are a retired module (owner, 2026-09-05: "there is no gift card (remove it from
--     my app)", restated 2026-09-08 alongside memberships). app/app.js keeps them out of the
--     product through RETIRED_BUSINESS_MODULES_V768, and the Reports "Liabilities" card
--     deliberately does not show the figure -- so the brief and Reports contradicted each other.
--     Measured read-only against production as the real owner, 2026-09-09:
--
--       tenant        credit_cents   gift_card_cents   brief said   Reports shows
--       Cubbly SPA               0              5000         5000               0
--       AhXiang              80000             20000       100000           80000
--
--     After this migration the brief reads the same components Reports does. NO gift-card row is
--     deleted, changed, or hidden from anything that already reads it: public.gift_cards,
--     app.reports_gift_card_liability_v49b and get_reports_summary's own field are all untouched.
--     The retired module simply stops contributing to a live number.
--
-- (B) THE REFERRALS FACT COULD ONLY EVER THROW.
--     app.owner_brief_fact_referrals_v828 builds a `referred` CTE that projects
--     (referral_id, client_id, reward_cents, status) and then asks it for sum(reward_points).
--     public.referrals HAS a reward_points column; the CTE just never carried it. Any tenant with
--     five or more referred customers in the trailing 90 days reaches that branch and the whole
--     fact degrades to status 'unavailable' -- the card then shows nothing for
--     "Referrals. Do the friends stick?". Below five the function returns early on the evidence
--     floor and never touches the branch, which is why no tenant has hit it yet: the estate's
--     busiest referrer today is Jess Salon with four. Reproduced read-only, 2026-09-09:
--
--       ERROR: 42703 column "reward_points" does not exist
--       HINT:  Perhaps you meant to reference the column "referred.reward_cents".
--
--     Fix: project the column the CTE already needed. One line; no arithmetic changes.
--
-- (C) A COMPLETION RATE OF 633.3%.
--     app.owner_brief_fact_stamps_v828 counted cycles STARTED in the trailing 90 days as the
--     denominator and cycles CLOSED in the same 90 days as the numerator, then divided. Those are
--     two different populations: a cycle closed inside the window may have started long before
--     it. The card renders the two counts as one English sentence --
--     "38 of 6 stamp cards started in the last 90 days were completed (633.3%)" on QA Kaya Toast
--     -- which is false twice over, because those 38 closures are mostly not among the 6 starts.
--
--     Fix: compare like with like. `cycles_completed` is now the number of cycles FROM THAT SAME
--     STARTED COHORT that have since been closed, so the sentence the browser already writes
--     becomes true as written and the ratio cannot exceed 100%. The closure count that used to be
--     the numerator is not thrown away -- it is reported separately and honestly as
--     `cycles_closed_in_window`.
--
--     Measured read-only against production, 2026-09-09 (same rows, both expressions):
--
--       tenant           started   old numerator   old pct    new completed   new pct
--       QA Kaya Toast          6              38     633.3%               5     83.3%
--       Cubbly SPA             9               4      44.4%               2     22.2%
--
--     Cubbly's old figure was inside 0-100% and still wrong: only 2 of those 9 cards were ever
--     finished. An impossible percentage was the symptom, not the defect.
--
-- WHAT THIS MIGRATION DOES NOT DO. It does not refresh the cached snapshots. Every row already in
-- public.owner_brief_snapshots_v1 keeps the numbers it was computed with; the corrected figures
-- appear when app.refresh_owner_brief_v826 next runs (nightly cron, or called for one business to
-- recompute immediately). It touches no browser code: app/app.js renders known_cents_total,
-- cycles_started/cycles_completed/completion_pct and the referral counts exactly as before.
--
-- ACCEPTANCE: db/tests/v836_owner_brief_three_wrong_facts.sql (rolled back against production).

begin;

-- =============================================================================================
-- (A) liability — a retired module is not a live liability
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
    -- credit liability: current, business-wide, exactly as Reports shows it.
    -- nestly_v867 — gift_card_liability_cents is deliberately NOT read from this same reader any
    -- more. Gift cards are a retired module (owner ruling 2026-09-05, restated 2026-09-08), the
    -- Reports "Liabilities" card does not show the figure, and the brief was the only surface
    -- still telling the owner they owed money for it. The underlying rows and readers are
    -- untouched; the retired module just stops contributing to a live number.
    v_reports := public.get_reports_summary(p_business, v_to, v_to, null);
    v_credit  := (v_reports ->> 'credit_liability_cents')::bigint;

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

    v_known := coalesce(v_credit, 0) + coalesce(v_sv_cents, 0);
    v_total_note := case
      when v_credit is null then 'partial: the Reports credit-liability component is unavailable for this scope'
      when v_sv_cents is null then 'excludes stored value (not live for this business) and reward-grant value (not a uniform money figure)'
      else 'excludes reward-grant value (not a uniform money figure)'
      end;

    v_fact := jsonb_build_object(
      'status', 'ok',
      'as_of', v_to,
      'credit_liability_cents', v_credit,
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
-- (B) referrals — the CTE must carry the column the fact reads
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
    -- nestly_v867 — r.reward_points is projected here. It was not, and the jsonb below has always
    -- asked this CTE for sum(reward_points), so every tenant that got past the evidence floor of
    -- five referred customers raised 42703 and lost the whole referrals answer to 'unavailable'.
    select r.id as referral_id, r.referred_client_id as client_id,
           r.reward_cents, r.reward_points, r.status
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
-- (C) stamps — the completion rate is a cohort's fate, not two unrelated counts divided
-- =============================================================================================
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
  v_closed_win  bigint := 0;
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
         -- nestly_v866: filtered at the source so every derived CTE inherits it.
         and not exists (select 1 from public.clients c where c.id = pl.client_id and c.is_synthetic)
      union all
      select sc.client_id, sc.closed_at as ts, -sc.slots as delta, 0 as ord, 'close' as kind
        from public.stamp_cycles sc
       where sc.business_id = p_business and sc.programme_id = v_prog
         and not exists (select 1 from public.clients c where c.id = sc.client_id and c.is_synthetic)
    ),
    running_cte as (
      select e.*,
             sum(delta) over (partition by client_id order by ts, ord
                              rows between unbounded preceding and current row) as running
        from events e
    ),
    ordered as (
      select r.*,
             lag(running) over (partition by client_id order by ts, ord) as prev_running,
             -- nestly_v867 — a stable per-client sequence number, so a start can be paired with
             -- the closure that ends THAT card rather than any closure that happens to fall in
             -- the reporting window.
             row_number() over (partition by client_id order by ts, ord) as sn
        from running_cte r
    ),
    starts as (
      select client_id, ts, sn,
             lead(sn) over (partition by client_id order by sn) as next_start_sn
        from ordered
       where kind = 'earn' and coalesce(prev_running, 0) <= 0 and running > 0
    ),
    closes as (
      select client_id, sn from ordered where kind = 'close'
    ),
    cohort as (
      -- the cards STARTED in the window, and for each one whether it has since been closed. The
      -- closure must fall after this start and before the client's next start, so a later card's
      -- completion can never be credited to an earlier abandoned one.
      select s.client_id, s.ts,
             exists (select 1 from closes c
                      where c.client_id = s.client_id
                        and c.sn > s.sn
                        and (s.next_start_sn is null or c.sn < s.next_start_sn)) as completed
        from starts s
       where s.ts >= v_window_start
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
      (select count(*) from cohort),
      (select count(*) from cohort where completed),
      (select count(*) from public.stamp_cycles sc
        where sc.business_id = p_business and sc.programme_id = v_prog
          and sc.closed_at >= v_window_start),
      (select pos from dropoff),
      (select n from dropoff)
    into v_started, v_completed, v_closed_win, v_dropoff_pos, v_dropoff_n;

    v_pct := case when v_started > 0 then round(100.0 * v_completed / v_started, 1) end;
    v_evidence := case when v_started >= 5 then 'ok' else 'insufficient' end;

    return jsonb_build_object(
      'status', 'ok', 'source', 'public.points_ledger + public.stamp_cycles (app.stamp_progress_v323 model)',
      'from', (v_window_start)::date, 'to', app.sg_today() - 1,
      'cycles_started', v_started,
      'cycles_completed', v_completed,
      'completion_pct', case when v_evidence = 'ok' then v_pct end,
      'cycles_closed_in_window', v_closed_win,
      'cycles_closed_in_window_note', 'closures that landed in the window whatever they started -- '
                    'NOT a subset of cycles_started, so it is reported beside the cohort figures '
                    'rather than divided by them',
      'evidence', v_evidence,
      'dropoff_stamp', case when v_dropoff_pos is not null then jsonb_build_object(
          'position', v_dropoff_pos, 'abandoned_cards', v_dropoff_n,
          'definition', 'open card (filled>0), no earn in 21+ days; position = stamps filled when they stopped') end,
      'definition', 'cycle "started" = a stamps earn that pushes (lifetime stamps minus stamps '
                    'closed by prior claimed/migrated cycles) from <=0 to >0, replayed per client '
                    'in timestamp order. "completed" counts the cards from THAT SAME started '
                    'cohort that have since been closed by a stamp_cycles row (final milestone '
                    'claimed, or a pot migration closure), whenever that closure happened, each '
                    'closure credited only to the card it ended. completion_pct is therefore the '
                    'cohort''s fate to date and cannot exceed 100%; a card started late in the '
                    'window has had less time to finish, so the figure is a floor.');
  exception when others then
    get stacked diagnostics v_err = message_text;
    return jsonb_build_object('status', 'unavailable', 'reason', left(v_err, 200),
      'source', 'public.points_ledger + public.stamp_cycles');
  end;
end;
$$;

revoke all on function app.owner_brief_fact_stamps_v828(uuid) from public, anon, authenticated;

commit;
