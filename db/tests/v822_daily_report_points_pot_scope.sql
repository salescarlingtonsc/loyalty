-- Rollback-only acceptance for nestly_v822 — the Daily report counts one points pot.
--   supabase db query --linked -f db/tests/v822_daily_report_points_pot_scope.sql
--
-- Every check CALLS public.get_dashboard_summary(uuid,date,date,uuid) — the RPC the Daily report
-- page actually uses — as a real authenticated owner, and compares it with the OTHER readers of
-- the same ledger. No check reads a function's source text except A1, which only confirms the
-- one predicate is present so a future retype cannot quietly drop it.
--
--   A1  the tenant in the report has a LIVE points pot and a RETIRED stamps pot both carrying
--       earn rows in the window — the exact shape that produced the defect
--   A2  Daily report == Insights earn == ledger (live pot only); the Dashboard is read too but
--       only asserted equal where the tenant's earns are all sale-linked (ÉLAN's are)
--   A3  the retired pot contributes nothing (a raw all-pot sum is strictly larger)
--   A4  ESTATE-WIDE: no business anywhere reads a different points_issued on the Daily report
--       from Business Insights' earn (the same definition; the Dashboard's is sale-linked by design)
--   A7  the live body carries the v381 pot predicate (a guard against a future retype)
--   A5  a fresh earn in the live pot moves the Daily report by exactly that amount
--   A6  a tenant with NO accruing programme reports 0, not everything ever earned
--
-- NEGATIVE CONTROL: on a database without v822, A2 fails at ÉLAN with 177 / 140 / 140 / 140 (and A4 would name
-- Cubbly SPA, QA Kopi Lab (Bedok) and ÉLAN Wellness. That is the defect reproducing itself and
-- is the intended pre-apply result (it is exactly what
-- db/tests/v820_business_reports_kpis_end_to_end.sql R11 reported when this was found).

begin;

do $suite$
declare
  c_biz    constant uuid := '8ccace3a-9736-447e-bb1e-da842622592d';  -- ÉLAN Wellness
  c_owner  constant uuid := '8efcffc8-61a5-4235-ad45-54a8954208f9';
  c_branch constant uuid := '586f4069-12cb-4f54-b37c-8c5742244520';
  c_service constant uuid := '274204da-ad83-4e3b-b7f5-30681788079d';
  d_from   constant date := (now() at time zone 'Asia/Singapore')::date - 30;
  d_to     constant date := (now() at time zone 'Asia/Singapore')::date;
  t_from   constant timestamptz := (d_from::timestamp) at time zone 'Asia/Singapore';
  t_to     constant timestamptz := ((d_to + 1)::timestamp) at time zone 'Asia/Singapore';
  v_live   uuid;
  v_daily  bigint; v_dash bigint; v_ins bigint; v_ledger bigint; v_all bigint;
  v_client uuid; v_eval jsonb; v_sale uuid; v_earned bigint;
  v_txt    text;
  r        record;
  n        integer := 0;
begin
  v_live := app.live_balance_programme_v381(c_biz);
  n := n + 1;
  if v_live is null
     or not exists (select 1 from public.points_ledger pl where pl.business_id=c_biz and pl.entry_type='earn'
                      and pl.programme_id = v_live and pl.created_at >= t_from and pl.created_at < t_to)
     or not exists (select 1 from public.points_ledger pl join public.business_programmes bp on bp.id = pl.programme_id
                      where pl.business_id=c_biz and pl.entry_type='earn' and not bp.active
                        and pl.created_at >= t_from and pl.created_at < t_to) then
    raise exception 'A%: the fixture no longer has a live pot AND a retired pot with earns in the window', n;
  end if;

  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', c_owner, 'role','authenticated')::text, true);
  v_daily := (public.get_dashboard_summary(c_biz, d_from, d_to, null)->>'points_issued')::bigint;
  v_dash  := (public.get_dashboard_summary_v155(c_biz, d_from, d_to, 'all', array[]::uuid[], null)->>'points_issued')::bigint;
  v_ins   := (public.get_reports_summary(c_biz, d_from, d_to, null)->'points_by_type'->>'earn')::bigint;
  reset role; perform set_config('request.jwt.claims','',true);

  select coalesce(sum(pl.points),0) into v_ledger from public.points_ledger pl
    join public.clients c on c.id = pl.client_id and c.business_id = pl.business_id and not c.is_synthetic
   where pl.business_id = c_biz and pl.entry_type='earn' and pl.programme_id = v_live
     and pl.created_at >= t_from and pl.created_at < t_to;
  select coalesce(sum(pl.points),0) into v_all from public.points_ledger pl
    join public.clients c on c.id = pl.client_id and c.business_id = pl.business_id and not c.is_synthetic
   where pl.business_id = c_biz and pl.entry_type='earn'
     and pl.created_at >= t_from and pl.created_at < t_to;

  n := n + 1;
  if v_daily is distinct from v_dash or v_daily is distinct from v_ins or v_daily is distinct from v_ledger then
    raise exception 'A%: Daily report % / Dashboard % / Insights % / live-pot ledger % — not one number',
      n, v_daily, v_dash, v_ins, v_ledger;
  end if;
  n := n + 1;
  if v_all <= v_ledger then
    raise exception 'A%: the retired pot carries no earn in the window, so this run cannot prove exclusion', n;
  end if;

  -- Estate-wide: the Daily report's points_issued must equal Business Insights' earn for EVERY
  -- business, read as each business's own owner (the RPCs refuse a caller with no permission,
  -- so a single set-returning query cannot do this). Insights is the right peer: both count
  -- every earn in the live pot for non-synthetic customers. The Dashboard (v155) is NOT the
  -- peer — its tile is labelled "Sale-linked earn" and by design excludes referral, welcome and
  -- manual earns (Jess Salon: 595 all-earn vs 195 sale-linked in the same window), so equality
  -- with it would be the wrong assertion, and the first draft of this suite made it.
  n := n + 1;
  v_txt := null;
  for r in
    select b.id, b.name, o.user_id
      from public.businesses b
      join lateral (select st.user_id from public.staff st where st.business_id=b.id and st.role='owner'
                     and st.active and st.user_id is not null order by st.created_at limit 1) o on true
     where exists (select 1 from public.points_ledger pl where pl.business_id=b.id and pl.entry_type='earn'
                     and pl.created_at >= t_from and pl.created_at < t_to)
  loop
    begin
      set local role authenticated;
      perform set_config('request.jwt.claims', json_build_object('sub', r.user_id, 'role','authenticated')::text, true);
      v_daily := (public.get_dashboard_summary(r.id, d_from, d_to, null)->>'points_issued')::bigint;
      v_ins   := (public.get_reports_summary(r.id, d_from, d_to, null)->'points_by_type'->>'earn')::bigint;
      reset role; perform set_config('request.jwt.claims','',true);
    exception when insufficient_privilege then
      -- this owner login lacks the report permission; the comparison is about the readers, not
      -- about that tenant's staffing, so skip rather than fail for an unrelated reason
      reset role; perform set_config('request.jwt.claims','',true);
      continue;
    end;
    if v_daily is distinct from coalesce(v_ins, 0) then
      v_txt := concat_ws(', ', v_txt, r.name||'(daily '||v_daily||' vs insights '||coalesce(v_ins,0)||')');
    end if;
  end loop;
  if v_txt is not null then
    raise exception 'A%: Daily report and Business Insights disagree for: %', n, v_txt;
  end if;

  -- A fresh earn in the live pot moves the Daily report by exactly what the ledger wrote.
  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', c_owner, 'role','authenticated')::text, true);
  v_daily := (public.get_dashboard_summary(c_biz, d_from, d_to, null)->>'points_issued')::bigint;
  reset role; perform set_config('request.jwt.claims','',true);
  n := n + 1;
  select c.id into v_client from public.clients c where c.business_id=c_biz and c.full_name not ilike 'erased%'
   order by c.created_at limit 1;
  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', c_owner, 'role','authenticated')::text, true);
  v_eval := public.evaluate_checkout(c_biz, c_branch, v_client,
    jsonb_build_array(jsonb_build_object('catalog_kind','service','catalog_id',c_service,'qty',1)),
    gen_random_uuid(), null::uuid, false)::jsonb;
  v_sale := (public.record_cart_sale(c_biz, v_client, c_branch, null, 'cash', 'v822-'||gen_random_uuid()::text,
    jsonb_build_array(jsonb_build_object('catalog_kind','service','catalog_id',c_service,'qty',1)),
    (v_eval->>'evaluation_id')::uuid, true, now(), '[]'::jsonb)::jsonb->>'sale_id')::uuid;
  v_all := (public.get_dashboard_summary(c_biz, d_from, d_to, null)->>'points_issued')::bigint;
  reset role; perform set_config('request.jwt.claims','',true);
  select coalesce(sum(pl.points),0) into v_earned from public.points_ledger pl
   where pl.business_id=c_biz and pl.sale_id=v_sale and pl.points>0 and pl.programme_id = v_live;
  if v_all <> v_daily + v_earned then
    raise exception 'A%: a sale earned % in the live pot but the Daily report moved % -> %', n, v_earned, v_daily, v_all;
  end if;

  -- No accruing programme -> 0, not everything ever earned.
  n := n + 1;
  update public.business_programmes set active = false where id = v_live;
  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', c_owner, 'role','authenticated')::text, true);
  v_all := (public.get_dashboard_summary(c_biz, d_from, d_to, null)->>'points_issued')::bigint;
  reset role; perform set_config('request.jwt.claims','',true);
  if v_all <> 0 then
    raise exception 'A%: with no live programme the Daily report still reports % points issued', n, v_all;
  end if;

  -- Last, not first: a text check is only a guard against a future retype dropping the
  -- predicate. Placed first it would fire before the money comparison and turn the negative
  -- control into a grep. The comparisons above are what prove the report is right.
  n := n + 1;
  if position('and pl.programme_id = app.live_balance_programme_v381(p_business)' in
       (select pg_get_functiondef(p.oid) from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
         where ns.nspname='public' and p.proname='get_dashboard_summary' and p.pronargs=4)) = 0 then
    raise exception 'A%: get_dashboard_summary(uuid,date,date,uuid) is not pot-scoped', n;
  end if;

  raise notice 'nestly_v822: % / % assertions passed', n, n;
end
$suite$;

rollback;
