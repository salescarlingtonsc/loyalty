-- nestly_v300_growth_readbacks
--
-- Owner approval 2026-08-13 (superseding the launch feature-freeze for exactly these three
-- scopes): (1) customers may see and share their own referral code, synced to the firm's
-- actual referral programme; (2) the retention surface may state observed come-backs;
-- (3) the programmes page may state how many times each reward has been redeemed.
--
-- Three READ-ONLY projections. No table is created or altered, no write path changes, and
-- every function copies the gating idiom of the reader it sits beside:
--   * customer_get_referral_card_v300  — the v267 customer_get_business_summary gate
--     (authenticated session -> platform feature flag -> app.v32_customer_wallet_context,
--     42501 when the link is not verified);
--   * staff_list_returned_customers_v300 — the v244 retention_lapsed_candidates gate
--     (require_module_scope_v145 raises 42501) and the SAME valid-visit predicate
--     (sales.counts_as_visit, reversals excluded both ways, Asia/Singapore day boundaries),
--     so "came back" can never disagree with "lapsed";
--   * business_reward_redemption_counts_v300 — loyalty module scope; counts only
--     public.loyalty_redemptions, the single canonical redemption record (the v89 QR flow
--     references it by FK), so the number is a count of real, completed redemptions.

begin;

-- ---------------------------------------------------------------------------
-- 1. Customer referral card: the member's own code + the firm's CURRENT terms.
--    enabled reflects BOTH the module toggle and the programme row, so a firm that
--    turns referrals off (either way) makes the customer card disappear rather than
--    advertise a reward that would never be paid.
-- ---------------------------------------------------------------------------
create or replace function public.customer_get_referral_card_v300(p_business_slug text)
returns jsonb
language plpgsql
stable security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare
  v_actor uuid := auth.uid();
  v_context record;
  v_program record;
  v_code text;
  v_referred integer := 0;
  v_enabled boolean := false;
begin
  if v_actor is null then
    raise exception 'authenticated customer session required' using errcode = '28000';
  end if;
  if not app.platform_feature_enabled('customer_wallet') then
    raise exception 'customer wallet is not enabled' using errcode = '0A000';
  end if;

  select identity_id, business_id, client_id, business_currency, enabled_modules
    into v_context
    from app.v32_customer_wallet_context(p_business_slug)
   limit 1;
  if not found then
    raise exception 'verified customer link required' using errcode = '42501';
  end if;

  select rp.enabled, rp.reward_cents, rp.min_spend_cents
    into v_program
    from public.referral_programs rp
   where rp.business_id = v_context.business_id
   limit 1;

  v_enabled := coalesce(v_program.enabled, false)
    and 'referrals' = any(coalesce(v_context.enabled_modules, '{}'::text[]));

  if not v_enabled then
    -- A disabled programme returns ONLY the fact that it is off. No terms, no code:
    -- the card must vanish, not tease a reward the firm is not paying.
    return jsonb_build_object('enabled', false);
  end if;

  select c.referral_code into v_code
    from public.clients c
   where c.id = v_context.client_id;

  -- "You've referred N friends" counts only referrals that actually qualified —
  -- a pending link is not a success story yet.
  select count(*)::integer into v_referred
    from public.referrals r
   where r.business_id = v_context.business_id
     and r.referrer_client_id = v_context.client_id
     and r.status in ('qualified','rewarded');

  return jsonb_build_object(
    'enabled', true,
    'code', v_code,
    'reward_cents', coalesce(v_program.reward_cents, 0),
    'min_spend_cents', coalesce(v_program.min_spend_cents, 0),
    'currency', coalesce(v_context.business_currency, 'SGD'),
    'referred_count', v_referred
  );
end
$$;

revoke all on function public.customer_get_referral_card_v300(text) from public, anon;
grant execute on function public.customer_get_referral_card_v300(text)
  to authenticated;
grant execute on function public.customer_get_referral_card_v300(text)
  to service_role;

-- ---------------------------------------------------------------------------
-- 2. Observed come-backs: customers whose latest valid visit happened inside the
--    answer window AND whose gap since the visit before it was at least p_away_days.
--    Purely descriptive — it states who returned after a long break, never why.
--    (Causal claims stay with the bring-back playbooks and their hold-back arms.)
-- ---------------------------------------------------------------------------
create or replace function public.staff_list_returned_customers_v300(
  p_business uuid,
  p_away_days integer,
  p_window_days integer
)
returns jsonb
language plpgsql
stable security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare
  v_cap constant integer := 50;
  v_away integer := greatest(1, least(365, coalesce(p_away_days, 60)));
  v_window integer := greatest(1, least(90, coalesce(p_window_days, 30)));
  v_today date := (now() at time zone 'Asia/Singapore')::date;
  v_total bigint;
  v_rows jsonb;
begin
  -- Same gate as retention_lapsed_candidates_v244 (raises 42501 when out of scope).
  perform public.require_module_scope_v145(p_business, null, 'retention');

  with visit_rows as (
    select s.id, s.client_id, s.occurred_at, s.reversal_of
    from public.sales s
    where s.business_id = p_business
      and s.counts_as_visit = true
  ),
  valid_visits as (
    -- validVisitSales, verbatim from v244: reversals are never visits; a reversed
    -- original is out. The two readers MUST agree on what a visit is.
    select v.client_id, v.occurred_at
    from visit_rows v
    where v.reversal_of is null
      and not exists (
        select 1 from visit_rows r where r.reversal_of = v.id
      )
  ),
  ordered as (
    select vv.client_id, vv.occurred_at,
           lag(vv.occurred_at) over (partition by vv.client_id order by vv.occurred_at) as previous_visit_at,
           row_number() over (partition by vv.client_id order by vv.occurred_at desc) as recency
    from valid_visits vv
  ),
  returned as (
    -- The LATEST visit per client, only when it closed a gap of >= v_away days and
    -- landed inside the last v_window days (Singapore calendar on both counts).
    select o.client_id,
           o.occurred_at as returned_at,
           ((o.occurred_at at time zone 'Asia/Singapore')::date
             - (o.previous_visit_at at time zone 'Asia/Singapore')::date)::integer as away_days
    from ordered o
    where o.recency = 1
      and o.previous_visit_at is not null
      and (v_today - (o.occurred_at at time zone 'Asia/Singapore')::date) <= v_window
      and ((o.occurred_at at time zone 'Asia/Singapore')::date
            - (o.previous_visit_at at time zone 'Asia/Singapore')::date) >= v_away
  )
  select count(*),
         coalesce(jsonb_agg(x.row order by x.returned_at desc)
                    filter (where x.rank <= v_cap), '[]'::jsonb)
    into v_total, v_rows
    from (
      select r.returned_at,
             row_number() over (order by r.returned_at desc, r.client_id) as rank,
             jsonb_build_object(
               'id', c.id,
               'full_name', c.full_name,
               'phone', c.phone,
               'away_days', r.away_days,
               'returned_at', r.returned_at
             ) as row
      from returned r
      join public.clients c on c.id = r.client_id and c.business_id = p_business
    ) x;

  return jsonb_build_object(
    'away_days', v_away,
    'window_days', v_window,
    'total_returned', coalesce(v_total, 0),
    'truncated', coalesce(v_total, 0) > v_cap,
    'rows', v_rows
  );
end
$$;

revoke all on function public.staff_list_returned_customers_v300(uuid, integer, integer) from public, anon;
grant execute on function public.staff_list_returned_customers_v300(uuid, integer, integer)
  to authenticated;
grant execute on function public.staff_list_returned_customers_v300(uuid, integer, integer)
  to service_role;

-- ---------------------------------------------------------------------------
-- 3. Redemption counts per reward. loyalty_redemptions is append-only and written by
--    every completed redemption path (the v89 QR intents reference it by FK), so a
--    count of its rows is a count of real redemptions — never of attempts or intents.
--    Rows whose reward was a classic points->credit conversion carry no reward_id and
--    are reported under 'classic' rather than silently dropped.
-- ---------------------------------------------------------------------------
create or replace function public.business_reward_redemption_counts_v300(p_business uuid)
returns jsonb
language plpgsql
stable security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare
  v_by_reward jsonb;
  v_classic integer;
  v_total integer;
begin
  perform public.require_module_scope_v145(p_business, null, 'loyalty');

  select coalesce(jsonb_object_agg(t.reward_id::text, t.cnt), '{}'::jsonb)
    into v_by_reward
    from (
      select lr.reward_id, count(*)::integer as cnt
      from public.loyalty_redemptions lr
      where lr.business_id = p_business
        and lr.reward_id is not null
      group by lr.reward_id
    ) t;

  select count(*) filter (where lr.reward_id is null)::integer,
         count(*)::integer
    into v_classic, v_total
    from public.loyalty_redemptions lr
   where lr.business_id = p_business;

  return jsonb_build_object(
    'rewards', v_by_reward,
    'classic', coalesce(v_classic, 0),
    'total', coalesce(v_total, 0)
  );
end
$$;

revoke all on function public.business_reward_redemption_counts_v300(uuid) from public, anon;
grant execute on function public.business_reward_redemption_counts_v300(uuid)
  to authenticated;
grant execute on function public.business_reward_redemption_counts_v300(uuid)
  to service_role;

commit;
