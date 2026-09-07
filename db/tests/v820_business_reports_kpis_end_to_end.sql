-- Business reports and KPIs — END TO END, 2026-09-08.
--
-- Walks every report surface the business sidebar offers, as the OWNER under RLS, through the
-- RPCs each page actually calls:
--
--   Dashboard / Daily report   get_dashboard_summary(business, from, to, branch)   (app.js 55127)
--   Business Insights          get_reports_summary(business, from, to, branch)     (app.js 54012)
--   Sales & refunds            get_revenue_summary(business, from, to, branch)     (app.js 55493)
--   Staff performance          public.sale_commission                              (app.js 54601)
--   Sales export / daily rows  direct reads of public.sales                        (app.js 55144)
--
-- WHY EVERY ASSERTION IS A COMPARISON. A report cannot be checked by reading it — a number on
-- its own is neither right nor wrong. So each figure is compared against an INDEPENDENT
-- recomputation straight from the ledger tables, using the same Singapore half-open day window
-- the pages use ([from 00:00 SGT, to+1 00:00 SGT)), and the three RPCs are compared against
-- each other, because the estate has shipped exactly this class of bug before: business KPI
-- readers that summed every points pot while the customer's card read one (v460), a dashboard
-- that showed 78,345 against a true 53, and drill-downs that did not mirror the server's own
-- definition (v388/v405).
--
-- Then the ledger is MOVED and every reader has to move with it: a real till sale (the
-- evaluate_checkout -> record_cart_sale pair the Record sale button uses) must lift revenue,
-- visits, points and commission on every surface by exactly the right amount, and reversing
-- that sale must put revenue back and land in the reversal reconciliation. That is the part a
-- read-only check can never prove.
--
-- Everything runs as the real owner principal. Rolled back; nothing is left behind.
--
--   supabase db query --linked -f db/tests/v820_business_reports_kpis_end_to_end.sql

begin;

do $suite$
declare
  c_biz     constant uuid := '8ccace3a-9736-447e-bb1e-da842622592d';  -- ÉLAN Wellness
  c_owner   constant uuid := '8efcffc8-61a5-4235-ad45-54a8954208f9';
  c_branch  constant uuid := '586f4069-12cb-4f54-b37c-8c5742244520';
  c_service constant uuid := '274204da-ad83-4e3b-b7f5-30681788079d';  -- SGD 88.00
  c_amanda  constant uuid := '0fb55728-f2b3-4db9-87ec-574e93b80780';
  d_from    constant date := (now() at time zone 'Asia/Singapore')::date - 30;
  d_to      constant date := (now() at time zone 'Asia/Singapore')::date;
  t_from    constant timestamptz := (d_from::timestamp) at time zone 'Asia/Singapore';
  t_to      constant timestamptz := ((d_to + 1)::timestamp) at time zone 'Asia/Singapore';
  v_client  uuid;
  v_dash    jsonb;
  v_rep     jsonb;
  v_rev     jsonb;
  v_eval    jsonb;
  v_sale    uuid;
  v_rev0    bigint; v_vis0 bigint; v_pts0 bigint; v_comm0 bigint; v_rows0 bigint; v_revd0 bigint;
  v_ledger  bigint;
  v_got     bigint;
  v_got2    bigint;
  v_txt     text;
  n         integer := 0;

  -- Reads all three summaries as the owner and returns them; the caller compares.
  procedure_placeholder text;
begin
  -- A customer with NO visit today, so one new sale is exactly one new visit-day.
  select c.id into v_client from public.clients c
   where c.business_id = c_biz and c.full_name not ilike 'erased%'
     and not exists (select 1 from public.sales s where s.business_id = c_biz and s.client_id = c.id
                       and app.ci_visit_day_v699(s.occurred_at) = app.ci_visit_day_v699(now()))
   order by c.created_at limit 1;

  -- ================================================================ READ, AS THE OWNER
  set local role authenticated;
  perform set_config('request.jwt.claims',
    json_build_object('sub', c_owner, 'role', 'authenticated')::text, true);
  v_dash := public.get_dashboard_summary(c_biz, d_from, d_to, null);
  v_rep  := public.get_reports_summary(c_biz, d_from, d_to, null);
  v_rev  := public.get_revenue_summary(c_biz, d_from, d_to, null);
  reset role; perform set_config('request.jwt.claims','',true);

  n := n + 1;
  if v_dash is null or v_rep is null or v_rev is null then
    raise exception 'R%: a report RPC returned nothing for the owner', n;
  end if;

  -- =================================== 1. THREE READERS, ONE NUMBER, AND THE LEDGER AGREES
  -- Signed revenue: every sale that counts as revenue, reversals included as negatives.
  select coalesce(sum(s.amount_cents),0) into v_ledger from public.sales s
   where s.business_id = c_biz and s.counts_as_revenue
     and s.occurred_at >= t_from and s.occurred_at < t_to;

  v_rev0 := (v_dash->>'revenue_cents')::bigint;
  n := n + 1;
  if v_rev0 is distinct from v_ledger then
    raise exception 'R%: dashboard revenue % != signed ledger %', n, v_rev0, v_ledger;
  end if;
  n := n + 1;
  if (v_rep->'reversal_reconciliation'->>'net_revenue_cents')::bigint is distinct from v_ledger then
    raise exception 'R%: Business Insights net revenue % != signed ledger %',
      n, v_rep->'reversal_reconciliation'->>'net_revenue_cents', v_ledger;
  end if;
  n := n + 1;
  if (v_rev->>'revenue_accrual_cents')::bigint is distinct from v_ledger then
    raise exception 'R%: Sales & refunds accrual revenue % != signed ledger %',
      n, v_rev->>'revenue_accrual_cents', v_ledger;
  end if;

  -- revenue_by_kind must sum to the total, or a kind is being dropped or double-counted.
  n := n + 1;
  select coalesce(sum(value::bigint),0) into v_got from jsonb_each_text(v_rep->'revenue_by_kind');
  if v_got is distinct from v_ledger then
    raise exception 'R%: revenue_by_kind sums to %, total is %', n, v_got, v_ledger;
  end if;

  -- The daily series must sum to the total too (this is the chart the dashboard draws).
  n := n + 1;
  select coalesce(sum((d->>'amount_cents')::bigint),0) into v_got
    from jsonb_array_elements(v_dash->'revenue_by_day') d;
  if v_got is distinct from v_ledger then
    raise exception 'R%: revenue_by_day sums to %, total is %', n, v_got, v_ledger;
  end if;

  -- ============================================================ 2. REVERSALS RECONCILE
  n := n + 1;
  select count(*), coalesce(-sum(s.amount_cents),0) into v_got, v_got2 from public.sales s
   where s.business_id = c_biz and s.reversal_of is not null and s.counts_as_revenue
     and s.occurred_at >= t_from and s.occurred_at < t_to;
  if (v_rep->'reversal_reconciliation'->>'compensating_rows')::bigint is distinct from v_got then
    raise exception 'R%: compensating_rows % != % reversal rows in the ledger',
      n, v_rep->'reversal_reconciliation'->>'compensating_rows', v_got;
  end if;
  n := n + 1;
  if (v_rep->'reversal_reconciliation'->>'reversed_revenue_cents')::bigint is distinct from v_got2 then
    raise exception 'R%: reversed_revenue_cents % != % from the ledger',
      n, v_rep->'reversal_reconciliation'->>'reversed_revenue_cents', v_got2;
  end if;

  -- ======================================================================= 3. VISITS
  -- A visit is ONE CUSTOMER PER DAY (nestly_v714: a split bill is one visit), the day being
  -- app.ci_visit_day_v699's, plus each anonymous sale on its own. The first draft of this
  -- assertion counted sales and read 29 against the dashboard's 17 — the dashboard was right.
  -- Mirror the server's definition rather than inventing one (see v388/v405).
  n := n + 1;
  select (select count(*) from (
            select s.client_id, app.ci_visit_day_v699(s.occurred_at)
              from public.sales s
             where s.business_id = c_biz and s.counts_as_visit and s.reversal_of is null
               and s.client_id is not null
               and s.occurred_at >= t_from and s.occurred_at < t_to
               and not exists (select 1 from public.sales r where r.business_id = s.business_id and r.reversal_of = s.id)
             group by 1, 2) d)
       + (select count(*) from public.sales s
           where s.business_id = c_biz and s.counts_as_visit and s.reversal_of is null
             and s.client_id is null
             and s.occurred_at >= t_from and s.occurred_at < t_to
             and not exists (select 1 from public.sales r where r.business_id = s.business_id and r.reversal_of = s.id))
    into v_got;
  v_vis0 := (v_dash->>'visits')::bigint;
  if v_vis0 is distinct from v_got then
    raise exception 'R%: dashboard visits % != % customer-days in the ledger', n, v_vis0, v_got;
  end if;

  -- ======================================================================= 4. POINTS
  -- points_issued is gross earn in the period, business-wide, in the LIVE pot only
  -- (app.live_balance_programme_v381) for non-synthetic customers. The first draft summed every
  -- pot and read 177 against the reader's 140; ÉLAN has 37 points in a switched-off stamps pot
  -- that every other reader — Insights, the wallet, the till, the canonical balance — excludes.
  -- The Daily report's reader was the one left unscoped, fixed in nestly_v822; this assertion
  -- is what found it, and it now mirrors the one definition.
  n := n + 1;
  select coalesce(sum(pl.points),0) into v_got from public.points_ledger pl
    join public.clients c on c.id = pl.client_id and c.business_id = pl.business_id and not c.is_synthetic
   where pl.business_id = c_biz and pl.entry_type = 'earn'
     and pl.programme_id = app.live_balance_programme_v381(c_biz)
     and pl.created_at >= t_from and pl.created_at < t_to;
  v_pts0 := (v_dash->>'points_issued')::bigint;
  if v_pts0 is distinct from v_got then
    raise exception 'R%: dashboard points_issued % != % live-pot earn in the ledger', n, v_pts0, v_got;
  end if;
  n := n + 1;
  if (v_rep->'points_by_type'->>'earn')::bigint is distinct from v_got then
    raise exception 'R%: Business Insights earn % != dashboard points_issued %',
      n, v_rep->'points_by_type'->>'earn', v_got;
  end if;
  n := n + 1;
  select coalesce(sum(pl.points),0) into v_got from public.points_ledger pl
   where pl.business_id = c_biz and pl.points < 0
     and pl.created_at >= t_from and pl.created_at < t_to;
  if (v_rep->'points_by_type'->>'redeem')::bigint is distinct from v_got then
    raise exception 'R%: Business Insights redeem % != % in the ledger',
      n, v_rep->'points_by_type'->>'redeem', v_got;
  end if;

  -- ============================================================ 5. CREDIT LIABILITY
  n := n + 1;
  select coalesce(sum(cl.amount_cents),0) into v_got from public.credit_ledger cl
   where cl.business_id = c_biz;
  if (v_rep->>'credit_liability_cents')::bigint is distinct from v_got then
    raise exception 'R%: credit liability % != signed credit ledger %',
      n, v_rep->>'credit_liability_cents', v_got;
  end if;

  -- ============================================================ 6. BRANCH SCOPE
  -- One active branch here, so the branch-scoped read must equal the business-wide one and
  -- must equal the ledger filtered by that branch. A second active branch would make these
  -- a partition (sum of branches == whole); the shape of the assertion is the same.
  n := n + 1;
  set local role authenticated;
  perform set_config('request.jwt.claims',
    json_build_object('sub', c_owner, 'role', 'authenticated')::text, true);
  v_got := (public.get_dashboard_summary(c_biz, d_from, d_to, c_branch)->>'revenue_cents')::bigint;
  v_got2 := (public.get_revenue_summary(c_biz, d_from, d_to, c_branch)->>'revenue_accrual_cents')::bigint;
  reset role; perform set_config('request.jwt.claims','',true);
  select coalesce(sum(s.amount_cents),0) into v_ledger from public.sales s
   where s.business_id = c_biz and s.counts_as_revenue and s.branch_id = c_branch
     and s.occurred_at >= t_from and s.occurred_at < t_to;
  if v_got is distinct from v_ledger or v_got2 is distinct from v_ledger then
    raise exception 'R%: branch-scoped revenue dash=% sales=% != branch ledger %', n, v_got, v_got2, v_ledger;
  end if;

  -- ============================================================ 7. STAFF PERFORMANCE
  -- sale_commission is the one view Staff performance reads. Since v818 a sale with lines pays
  -- the SUM of its lines; a sale without lines pays the header arithmetic. Recompute both.
  n := n + 1;
  set local role authenticated;
  perform set_config('request.jwt.claims',
    json_build_object('sub', c_owner, 'role', 'authenticated')::text, true);
  select coalesce(sum(sc.commission_cents),0) into v_comm0 from public.sale_commission sc
   where sc.business_id = c_biz and sc.occurred_at >= t_from and sc.occurred_at < t_to;
  reset role; perform set_config('request.jwt.claims','',true);

  select coalesce(sum(
    case
      when s.reversal_of is not null and s.amount_cents < 0 then
        - coalesce((select sum(o.commission_cents) from public.sale_items o
                     where o.business_id = s.business_id and o.sale_id = s.reversal_of
                       and o.commission_cents is not null),
                   case when s.commission_flat_cents is not null then s.commission_flat_cents
                        else floor((-s.amount_cents)::numeric * s.commission_rate_bps::numeric / 10000)::integer end)
      else coalesce((select sum(l.commission_cents) from public.sale_items l
                      where l.business_id = s.business_id and l.sale_id = s.id
                        and l.commission_cents is not null),
                    case when s.commission_flat_cents is not null then s.commission_flat_cents
                         else floor(s.amount_cents::numeric * s.commission_rate_bps::numeric / 10000)::integer end)
    end),0) into v_got
    from public.sales s
   where s.business_id = c_biz and s.occurred_at >= t_from and s.occurred_at < t_to;
  if v_comm0 is distinct from v_got then
    raise exception 'R%: Staff performance commission % != per-line recomputation %', n, v_comm0, v_got;
  end if;

  -- ============================================================ 8. ESTATE-WIDE AGREEMENT
  -- app.v176_sales_window is the Business Insights headline and it is a THIRD definition, on
  -- purpose: VALID ORIGINALS ONLY — reversal rows are not counted and a reversed original is
  -- removed entirely (rather than netted), synthetic customers are excluded. The three summary
  -- RPCs above are the signed ledger. Both are documented in their own bodies; a suite that
  -- compared v176 to the signed sum failed on Cubbly SPA by 158 cents — a reversal inside the
  -- window of an original before it — and that was the assertion being wrong, not the report.
  -- So this mirrors v176's own CTE, for EVERY business: a reader migrated for one tenant and
  -- not another is how this class of bug has shipped.
  n := n + 1;
  select string_agg(b.name||'('||coalesce((app.v176_sales_window(b.id, d_from, d_to)->>'net_revenue_cents'),'null')
                    ||' vs '||v.valid||')', ', ') into v_txt
    from public.businesses b
    cross join lateral (
      select coalesce(sum(s.amount_cents),0) as valid
        from public.sales s
        left join public.clients c on c.id = s.client_id and c.business_id = s.business_id
       where s.business_id = b.id and s.counts_as_revenue
         and s.reversal_of is null
         and not coalesce(c.is_synthetic, false)
         and s.occurred_at >= t_from and s.occurred_at < t_to
         and not exists (select 1 from public.sales r where r.business_id = s.business_id and r.reversal_of = s.id)
    ) v
   where exists (select 1 from public.sales s where s.business_id = b.id)
     and coalesce((app.v176_sales_window(b.id, d_from, d_to)->>'net_revenue_cents')::bigint, 0) is distinct from v.valid;
  if v_txt is not null then
    raise exception 'R%: the Insights sales window disagrees with valid originals for: %', n, v_txt;
  end if;

  -- ======================================= 9. MOVE THE LEDGER; EVERY READER MUST MOVE
  select count(*) into v_rows0 from public.sales s
   where s.business_id = c_biz and s.reversal_of is not null and s.counts_as_revenue
     and s.occurred_at >= t_from and s.occurred_at < t_to;
  v_revd0 := (v_rep->'reversal_reconciliation'->>'reversed_revenue_cents')::bigint;

  n := n + 1;
  set local role authenticated;
  perform set_config('request.jwt.claims',
    json_build_object('sub', c_owner, 'role', 'authenticated')::text, true);
  v_eval := public.evaluate_checkout(c_biz, c_branch, v_client,
    jsonb_build_array(jsonb_build_object('catalog_kind','service','catalog_id',c_service,'qty',1)),
    gen_random_uuid(), null::uuid, false)::jsonb;
  v_sale := (public.record_cart_sale(c_biz, v_client, c_branch, c_amanda, 'cash',
    'reports-e2e-' || gen_random_uuid()::text,
    jsonb_build_array(jsonb_build_object('catalog_kind','service','catalog_id',c_service,'qty',1)),
    (v_eval->>'evaluation_id')::uuid, true, now(), '[]'::jsonb)::jsonb->>'sale_id')::uuid;
  v_dash := public.get_dashboard_summary(c_biz, d_from, d_to, null);
  v_rep  := public.get_reports_summary(c_biz, d_from, d_to, null);
  v_rev  := public.get_revenue_summary(c_biz, d_from, d_to, null);
  reset role; perform set_config('request.jwt.claims','',true);
  if v_sale is null then
    raise exception 'R%: the till did not return a sale', n;
  end if;

  n := n + 1;
  if (v_dash->>'revenue_cents')::bigint <> v_rev0 + 8800
     or (v_rep->'reversal_reconciliation'->>'net_revenue_cents')::bigint <> v_rev0 + 8800
     or (v_rev->>'revenue_accrual_cents')::bigint <> v_rev0 + 8800 then
    raise exception 'R%: an SGD 88 sale moved revenue to dash=% insights=% sales=% (expected %)',
      n, v_dash->>'revenue_cents', v_rep->'reversal_reconciliation'->>'net_revenue_cents',
      v_rev->>'revenue_accrual_cents', v_rev0 + 8800;
  end if;
  n := n + 1;
  if (v_dash->>'visits')::bigint <> v_vis0 + 1 then
    raise exception 'R%: one sale moved visits % -> %', n, v_vis0, v_dash->>'visits';
  end if;
  n := n + 1;
  select coalesce(sum(pl.points),0) into v_got from public.points_ledger pl
   where pl.business_id = c_biz and pl.sale_id = v_sale and pl.points > 0
     and pl.programme_id = app.live_balance_programme_v381(c_biz);
  if (v_dash->>'points_issued')::bigint <> v_pts0 + v_got then
    raise exception 'R%: the sale earned % points but points_issued moved % -> %',
      n, v_got, v_pts0, v_dash->>'points_issued';
  end if;

  -- and Staff performance now carries this sale's per-line commission (v818).
  n := n + 1;
  set local role authenticated;
  perform set_config('request.jwt.claims',
    json_build_object('sub', c_owner, 'role', 'authenticated')::text, true);
  select sc.commission_cents into v_got from public.sale_commission sc where sc.sale_id = v_sale;
  reset role; perform set_config('request.jwt.claims','',true);
  select coalesce(sum(li.commission_cents),0) into v_got2 from public.sale_items li where li.sale_id = v_sale;
  if v_got is distinct from v_got2 then
    raise exception 'R%: Staff performance shows %c for the new sale, its lines say %c', n, v_got, v_got2;
  end if;

  -- The daily rows the Daily report lists (a direct sales read) include it, as the owner.
  n := n + 1;
  set local role authenticated;
  perform set_config('request.jwt.claims',
    json_build_object('sub', c_owner, 'role', 'authenticated')::text, true);
  select count(*) into v_got from public.sales s where s.id = v_sale;
  reset role; perform set_config('request.jwt.claims','',true);
  if v_got <> 1 then
    raise exception 'R%: the owner cannot see the sale just recorded in the daily rows', n;
  end if;

  -- ======================================================= 10. REVERSE IT; READERS FOLLOW
  n := n + 1;
  set local role authenticated;
  perform set_config('request.jwt.claims',
    json_build_object('sub', c_owner, 'role', 'authenticated')::text, true);
  perform public.reverse_sale_fast_v84(c_biz, v_sale, 'reports e2e', 'reports-e2e-rev-' || gen_random_uuid()::text);
  v_dash := public.get_dashboard_summary(c_biz, d_from, d_to, null);
  v_rep  := public.get_reports_summary(c_biz, d_from, d_to, null);
  v_rev  := public.get_revenue_summary(c_biz, d_from, d_to, null);
  reset role; perform set_config('request.jwt.claims','',true);

  if (v_dash->>'revenue_cents')::bigint <> v_rev0
     or (v_rep->'reversal_reconciliation'->>'net_revenue_cents')::bigint <> v_rev0
     or (v_rev->>'revenue_accrual_cents')::bigint <> v_rev0 then
    raise exception 'R%: after reversal revenue is dash=% insights=% sales=% (expected back to %)',
      n, v_dash->>'revenue_cents', v_rep->'reversal_reconciliation'->>'net_revenue_cents',
      v_rev->>'revenue_accrual_cents', v_rev0;
  end if;
  n := n + 1;
  if (v_rep->'reversal_reconciliation'->>'compensating_rows')::bigint <> v_rows0 + 1
     or (v_rep->'reversal_reconciliation'->>'reversed_revenue_cents')::bigint <> v_revd0 + 8800 then
    raise exception 'R%: the reversal did not land in the reconciliation (rows % -> %, reversed % -> %)',
      n, v_rows0, v_rep->'reversal_reconciliation'->>'compensating_rows',
      v_revd0, v_rep->'reversal_reconciliation'->>'reversed_revenue_cents';
  end if;
  -- A reversed visit is no longer a valid original visit.
  n := n + 1;
  if (v_dash->>'visits')::bigint <> v_vis0 then
    raise exception 'R%: visits after reversal is %, expected back to %', n, v_dash->>'visits', v_vis0;
  end if;
  -- and the reversal's commission mirrors the original's, so Staff performance nets to zero.
  n := n + 1;
  set local role authenticated;
  perform set_config('request.jwt.claims',
    json_build_object('sub', c_owner, 'role', 'authenticated')::text, true);
  select coalesce(sum(sc.commission_cents),0) into v_got from public.sale_commission sc
   where sc.sale_id = v_sale or sc.sale_id = (select id from public.sales where reversal_of = v_sale);
  reset role; perform set_config('request.jwt.claims','',true);
  if v_got <> 0 then
    raise exception 'R%: a reversed sale still nets %c of commission on Staff performance', n, v_got;
  end if;

  -- ======================================================= 11. THE PRIOR-PERIOD READ
  -- Business Insights reads the previous window alongside (app.js 54009); it must answer and
  -- must be a different window.
  n := n + 1;
  set local role authenticated;
  perform set_config('request.jwt.claims',
    json_build_object('sub', c_owner, 'role', 'authenticated')::text, true);
  v_rep := public.get_reports_summary(c_biz, d_from - 31, d_from - 1, null);
  reset role; perform set_config('request.jwt.claims','',true);
  if v_rep is null or (v_rep->'scope'->>'to')::date <> d_from - 1 then
    raise exception 'R%: the prior-period read did not answer for its own window', n;
  end if;

  raise notice 'business reports and KPIs end to end: % / % assertions passed', n, n;
end
$suite$;

rollback;
