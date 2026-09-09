-- nestly_v877 — three more owner-brief facts say what is true: the month fact stops projecting
--               from one trading day, the birthday fact reads the birthday the engine reads, and
--               the liability answer counts prepaid sessions the firm still owes.
--
-- WHAT WAS LIVE, AND WHY IT IS WRONG.
--
--   (A) MONTH. app.owner_brief_fact_month_v828 refused nothing: on 2026-09-02 it printed "on
--       pace for $4,071.43 this month" for a tenant with one trading day, three lines under a
--       week fact that had just declined to compare a week for lack of evidence. Same card, two
--       standards. A month-to-date extrapolation from one or two days is not a forecast, it is a
--       multiplication.
--
--   (B) BIRTHDAYS. app.owner_brief_fact_birthdays_v828 read public.clients.birth_date. The
--       birthday ENGINE (app.c45_customer_birthday_context, the entitlement grant and the
--       checkout discount) reads public.customer_profiles.birth_date through the customer's
--       verified link. A customer who told the app their birthday in their own profile — the
--       only place the app asks for it — was invisible to the brief, which reported "0 birthday
--       benefits granted this month" beside a live, redeemable entitlement.
--
--   (C) LIABILITY. The "what would it cost me" answer counted store credit and stored value and
--       nothing else. Unused prepaid package sessions — money already collected against
--       services not yet delivered — appeared on no surface at all. Cubbly SPA carries seven
--       prepaid packages; the obligation behind them was reported as $0.
--
-- THE FIX.
--   (A) The month fact carries 'evidence' like every other fact: 'ok' needs at least seven
--       elapsed days AND three trading days with revenue; below that on_pace_cents is null and
--       the note says why. The MTD revenue itself is always stated — it is a sum, not a projection.
--   (B) The birthday is resolved the way the engine resolves it: the verified customer link's
--       profile birth date, falling back to clients.birth_date only when no profile exists.
--   (C) A prepaid_sessions_liability_cents term: for each active package with sessions left,
--       price paid x remaining / sessions, over non-synthetic clients; included in
--       known_cents_total with its own line and note. Layered on the v867 body of the fact.
--
-- Snapshots do not self-heal: app.refresh_owner_brief_v826() recomputes the estate.

begin;

-- ---------------------------------------------------------------------------------------------
-- (A) month
-- ---------------------------------------------------------------------------------------------
create or replace function app.owner_brief_fact_month_v828(p_business uuid)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $function$
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
  v_trading_days   int;
  v_evidence       text;
  v_fact           jsonb;
  v_err            text;
begin
  begin
    v_mtd  := app.v176_sales_window(p_business, v_month_start, v_to);
    v_prev := app.v176_sales_window(p_business, v_prev_start, v_prev_end);
    v_mtd_rev  := coalesce((v_mtd  ->> 'net_revenue_cents')::bigint, 0);
    v_prev_rev := coalesce((v_prev ->> 'net_revenue_cents')::bigint, 0);
    v_delta := app.owner_brief_pct_v826(v_mtd_rev, v_prev_rev);

    -- nestly_v877: how many Singapore days this month actually traded. A projection needs a
    -- base; the week fact already refuses on thin evidence and this fact now holds the same line.
    select count(distinct app.ci_visit_day_v699(s.occurred_at)) into v_trading_days
      from public.sales s
      cross join lateral app.analytics_sale_class_v1(s) sc
     where s.business_id = p_business
       and sc.include_revenue
       and not sc.is_synthetic_client
       and app.ci_visit_day_v699(s.occurred_at) between v_month_start and v_to;

    v_evidence := case when v_days_elapsed >= 7 and coalesce(v_trading_days, 0) >= 3 then 'ok'
                       else 'insufficient' end;
    v_on_pace := case when v_evidence = 'ok' and v_days_elapsed > 0
                 then round(v_mtd_rev::numeric / v_days_elapsed * v_days_in_month) end;

    v_fact := jsonb_build_object(
      'status', 'ok',
      'source', 'app.v176_sales_window',
      'evidence', v_evidence,
      'evidence_note', case when v_evidence = 'ok' then null
        else format('%s elapsed day(s), %s trading day(s): the month-to-date figure is exact, the pace is not projected until 7 days and 3 trading days have passed',
                    v_days_elapsed, coalesce(v_trading_days, 0)) end,
      'trading_days_mtd', coalesce(v_trading_days, 0),
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
$function$;

-- ---------------------------------------------------------------------------------------------
-- (B) birthdays
-- ---------------------------------------------------------------------------------------------
create or replace function app.owner_brief_fact_birthdays_v828(p_business uuid)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $function$
declare
  v_today  date := app.sg_today();
  v_month  int  := extract(month from v_today);
  v_year   int  := extract(year from v_today);
  v_bday   int;
  v_granted int;
  v_redeemed int;
  v_err    text;
begin
  -- nestly_v877: the birthday the ENGINE reads — the verified link's profile — with the client
  -- record as the fallback for a customer who never linked an account.
  create temp table if not exists _v877_dob (client_id uuid primary key, birth_date date) on commit drop;
  delete from _v877_dob;
  insert into _v877_dob(client_id, birth_date)
  select c.id,
         coalesce((select cp.birth_date
                     from public.customer_links cl
                     join public.customer_profiles cp on cp.identity_id = cl.identity_id
                    where cl.client_id = c.id and cl.business_id = c.business_id
                      and cl.state = 'verified' and cl.unlinked_at is null
                    order by cl.verified_at desc nulls last
                    limit 1), c.birth_date)
    from public.clients c
   where c.business_id = p_business and not c.is_synthetic;

  select count(*) into v_bday
  from _v877_dob d
  where d.birth_date is not null
    and extract(month from d.birth_date) = v_month;

  begin
    select count(*) into v_granted
    from public.customer_birthday_entitlements e
    join _v877_dob d on d.client_id = e.client_id
    where e.business_id = p_business
      and d.birth_date is not null
      and extract(month from d.birth_date) = v_month
      and e.birthday_year = v_year
      and e.activated_at is not null;
  exception when undefined_table then
    v_granted := null;
  end;

  begin
    select count(*) into v_redeemed
    from public.customer_birthday_redemptions r
    join public.customer_birthday_entitlements e on e.id = r.entitlement_id
    join _v877_dob d on d.client_id = e.client_id
    where r.business_id = p_business
      and d.birth_date is not null
      and extract(month from d.birth_date) = v_month
      and e.birthday_year = v_year
      and r.operation_kind = 'redemption'
      and r.active;
  exception when undefined_table then
    v_redeemed := null;
  end;

  return jsonb_build_object(
    'status', 'ok',
    'source', 'public.customer_profiles.birth_date via the verified public.customer_links row (the birthday engine''s authority), falling back to public.clients.birth_date; + public.customer_birthday_entitlements + public.customer_birthday_redemptions',
    'month', v_month, 'year', v_year,
    'birthday_clients_this_month', v_bday,
    'granted_this_month', v_granted,
    'granted_note', 'granted = customer_birthday_entitlements.activated_at is not null for birthday_year = current year; this is a customer self-activation (nestly_v560 join_program-style flow), not proof a WhatsApp/SMS notification was sent -- no notification-log table was found for birthday, so "did we send anything" is answered by activation, not delivery.',
    'redeemed_this_month', v_redeemed);
exception when others then
  get stacked diagnostics v_err = message_text;
  return jsonb_build_object('status', 'unavailable', 'reason', left(v_err, 200), 'source', 'public.customer_profiles + birthday tables');
end;
$function$;

-- ---------------------------------------------------------------------------------------------
-- (C) liability — the v867 body plus the prepaid-sessions term
-- ---------------------------------------------------------------------------------------------
create or replace function app.owner_brief_fact_liability_v828(p_business uuid)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $function$
declare
  v_to         date := app.sg_today();
  v_reports    jsonb;
  v_credit     bigint;
  v_reward_cnt bigint;
  v_sv_state   text;
  v_sv_cents   bigint;
  v_sv_note    text;
  v_packages   bigint;
  v_pkg_count  bigint;
  v_sessions   bigint;
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

    -- (c) nestly_v877: prepaid sessions still owed. The package was paid for in full at purchase
    -- (revenue booked upfront, v10 policy); every undelivered session is a service the firm still
    -- owes, valued at what the customer paid for it: price x remaining / sessions.
    select coalesce(sum(round(cp.price_cents_snapshot::numeric * cp.remaining / nullif(cp.sessions_snapshot, 0))), 0)::bigint,
           count(*)::bigint,
           coalesce(sum(cp.remaining), 0)::bigint
      into v_packages, v_pkg_count, v_sessions
      from public.client_packages cp
      join public.clients c on c.id = cp.client_id and c.business_id = cp.business_id
     where cp.business_id = p_business
       and cp.status = 'active'
       and cp.remaining > 0
       and (cp.expires_at is null or cp.expires_at > now())
       and not c.is_synthetic;

    v_known := coalesce(v_credit, 0) + coalesce(v_sv_cents, 0) + coalesce(v_packages, 0);
    v_total_note := case
      when v_credit is null then 'partial: the Reports credit-liability component is unavailable for this scope'
      when v_sv_cents is null then 'includes prepaid sessions not yet delivered; excludes stored value (not live for this business) and reward-grant value (not a uniform money figure)'
      else 'includes prepaid sessions not yet delivered; excludes reward-grant value (not a uniform money figure)'
      end;

    v_fact := jsonb_build_object(
      'status', 'ok',
      'as_of', v_to,
      'credit_liability_cents', v_credit,
      'stored_value_liability_cents', v_sv_cents,
      'stored_value_note', v_sv_note,
      'prepaid_sessions_liability_cents', v_packages,
      'prepaid_sessions', jsonb_build_object(
        'packages', v_pkg_count, 'sessions_remaining', v_sessions,
        'note', 'price paid x sessions remaining / sessions bought, over active, unexpired packages'),
      'unredeemed_reward_grants', jsonb_build_object(
        'count', v_reward_cnt,
        'note', 'count only, not money -- reward_grants mixes discount_pct/free_item/credit fulfilment kinds'),
      'known_cents_total', v_known,
      'known_cents_total_note', v_total_note,
      'source', 'public.get_reports_summary + public.reward_grants + app.sv_available_balance + public.client_packages');
  exception when others then
    get stacked diagnostics v_err = message_text;
    v_fact := jsonb_build_object('status', 'unavailable', 'reason', left(v_err, 200),
                                  'source', 'public.get_reports_summary');
  end;
  return v_fact;
end;
$function$;

-- ACLs restated verbatim from prod (nestly_v877): all three are owner-only internals of the
-- brief composer.
revoke all on function app.owner_brief_fact_month_v828(uuid) from public, anon, authenticated;
revoke all on function app.owner_brief_fact_birthdays_v828(uuid) from public, anon, authenticated;
revoke all on function app.owner_brief_fact_liability_v828(uuid) from public, anon, authenticated;

do $verify$
begin
  if position('''trading_days_mtd''' in pg_get_functiondef('app.owner_brief_fact_month_v828(uuid)'::regprocedure)) = 0 then
    raise exception 'nestly_v877: month fact has no evidence gate' using errcode = 'XX001';
  end if;
  if position('public.customer_profiles cp' in pg_get_functiondef('app.owner_brief_fact_birthdays_v828(uuid)'::regprocedure)) = 0 then
    raise exception 'nestly_v877: birthday fact does not read the profile birth date' using errcode = 'XX001';
  end if;
  if position('''prepaid_sessions_liability_cents''' in pg_get_functiondef('app.owner_brief_fact_liability_v828(uuid)'::regprocedure)) = 0 then
    raise exception 'nestly_v877: liability fact has no prepaid-sessions term' using errcode = 'XX001';
  end if;
end
$verify$;

commit;
