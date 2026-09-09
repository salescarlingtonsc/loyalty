-- Rollback-only acceptance for nestly_v865 — the Dashboard has ONE visit definition.
--   supabase db query --linked -f db/tests/v833_one_visit_definition_on_the_dashboard.sql
--
-- Every check CALLS public.get_dashboard_summary_v155(uuid,date,date,text,uuid[],uuid) — the RPC
-- the Dashboard page actually uses — as a real authenticated owner, and compares the Visits tile
-- with the visits_by_weekday chart drawn directly beneath it on the same screen. Only the LAST
-- check reads the function's source text, and only as a guard against a future retype dropping
-- the predicate; the comparisons above it are what prove the number is right.
--
--   A1  fixture: the tenant has at least one customer with TWO valid visit-sales on the same SGT
--       day inside the window — the exact shape that made the two numbers diverge — and every
--       sale in the window carries a branch, so the independent recompute in A3 is comparable
--   A2  sum(visits_by_weekday) == the Visits tile, exactly
--   A3  the served array equals an INDEPENDENTLY recomputed deduplicated array (spelled out with
--       (occurred_at at time zone 'Asia/Singapore')::date rather than by calling the authority,
--       so a broken authority cannot make both sides wrong in the same way)
--   A4  NEGATIVE CONTROL: the old raw-sale-row array is strictly different from the served one.
--       If this ever stops failing, the fixture no longer exercises the defect and A2/A3 are
--       passing for free.
--   A5  a SECOND sale for the same customer on the same day moves NEITHER the tile nor the chart
--       (a split bill is one visit, in both places)
--   A6  a WALK-IN sale (no client_id) moves BOTH the tile and today's weekday bucket by exactly 1
--       — walk-ins carry no identity to deduplicate by and must still count one apiece, which is
--       what makes the chart total equal the tile rather than merely resemble it
--   A7  a SYNTHETIC customer's sale moves neither — the weekday block applies the same
--       synthetic-client filter the KPI block does (before v865 it did not)
--   A8  ESTATE-WIDE: no business anywhere reports a chart total different from its Visits tile
--   A9  the live body buckets the weekday from the visit-day and deduplicates (retype guard)
--
-- NEGATIVE CONTROL, measured on production 2026-09-09 before this migration is applied:
-- ÉLAN Wellness over 2025-09-09..2026-09-09 serves tile 17 with weekday [12,6,1,9,1,0,0], total
-- 29. A2 fails with 17 vs 29, A3 fails, A5 fails (the second same-day sale moves the chart), A7
-- fails, and A8 additionally names Cubbly SPA (39 vs 75), Hougang ABC (16 vs 29), QA Kaya Toast
-- (7 vs 23), QA Kopi Lab (Bedok) (4 vs 20), AhXiang (5 vs 6), Jess Salon (4 vs 7) and QA Test
-- Cafe (2 vs 3). That is the defect reproducing itself and is the intended pre-apply result.

begin;

do $suite$
declare
  c_biz    constant uuid := '8ccace3a-9736-447e-bb1e-da842622592d';  -- ÉLAN Wellness
  c_owner  constant uuid := '8efcffc8-61a5-4235-ad45-54a8954208f9';
  c_branch constant uuid := '586f4069-12cb-4f54-b37c-8c5742244520';
  d_from   constant date := (now() at time zone 'Asia/Singapore')::date - 365;
  d_to     constant date := (now() at time zone 'Asia/Singapore')::date;
  t_from   constant timestamptz := (d_from::timestamp) at time zone 'Asia/Singapore';
  t_to     constant timestamptz := ((d_to + 1)::timestamp) at time zone 'Asia/Singapore';
  v_dow    constant int := extract(isodow from (now() at time zone 'Asia/Singapore')::date)::int;
  v_scope  uuid[];
  j        jsonb;
  v_tile   bigint; v_chart bigint;
  v_tile2  bigint; v_chart2 bigint;
  v_bucket bigint; v_bucket2 bigint;
  v_served bigint[]; v_expect bigint[]; v_raw bigint[];
  v_client uuid; v_synth uuid;
  v_txt    text;
  r        record;
  n        integer := 0;
begin
  ---------------------------------------------------------------------------
  -- A1  the fixture must actually contain a same-day repeat, or nothing below
  --     can tell a deduplicated count from a raw row count.
  ---------------------------------------------------------------------------
  n := n + 1;
  if not exists (
    select 1
      from public.sales s
      left join public.clients c on c.id = s.client_id
     where s.business_id = c_biz
       and s.client_id is not null
       and s.counts_as_visit and s.reversal_of is null
       and s.occurred_at >= t_from and s.occurred_at < t_to
       and not coalesce(c.is_synthetic, false)
       and not exists (select 1 from public.sales r
                        where r.business_id = s.business_id and r.reversal_of = s.id)
     group by s.client_id, (s.occurred_at at time zone 'Asia/Singapore')::date
    having count(*) >= 2
  ) then
    raise exception 'A%: the fixture has no same-day repeat visit in the window — a raw row count and a deduplicated count would agree by accident', n;
  end if;
  n := n + 1;
  if exists (select 1 from public.sales s
              where s.business_id = c_biz and s.branch_id is null
                and s.occurred_at >= t_from and s.occurred_at < t_to) then
    raise exception 'A%: a sale in the window carries no branch, so the branch-scoped RPC and the recompute below are not comparable', n;
  end if;

  ---------------------------------------------------------------------------
  -- A2  the tile and the chart under it are the same number.
  ---------------------------------------------------------------------------
  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', c_owner, 'role','authenticated')::text, true);
  j := public.get_dashboard_summary_v155(c_biz, d_from, d_to, 'all', array[]::uuid[], null);
  reset role; perform set_config('request.jwt.claims','',true);

  v_tile := (j->>'visits')::bigint;
  select array_agg(e::text::bigint order by ord) into v_served
    from jsonb_array_elements(j->'visits_by_weekday') with ordinality t(e, ord);
  v_chart := (select coalesce(sum(x), 0) from unnest(v_served) x);
  select array_agg(e::text::uuid) into v_scope
    from jsonb_array_elements_text(j->'scope'->'branch_ids') e;

  n := n + 1;
  if v_tile is distinct from v_chart then
    raise exception 'A%: the Visits tile says % and the chart beneath it totals % — %',
      n, v_tile, v_chart, v_served;
  end if;

  ---------------------------------------------------------------------------
  -- A3  the served array equals an independent deduplicated recompute.
  ---------------------------------------------------------------------------
  select array_agg(coalesce(w.visits, 0) order by d.day_no) into v_expect
    from generate_series(1,7) d(day_no)
    left join (
      select extract(isodow from (s.occurred_at at time zone 'Asia/Singapore')::date)::int as day_no,
             count(distinct (s.client_id, (s.occurred_at at time zone 'Asia/Singapore')::date))
               filter (where s.client_id is not null)
             + count(*) filter (where s.client_id is null) as visits
        from public.sales s
        left join public.clients c on c.id = s.client_id
       where s.business_id = c_biz
         and s.branch_id = any(v_scope)
         and s.counts_as_visit and s.reversal_of is null
         and s.occurred_at >= t_from and s.occurred_at < t_to
         and not coalesce(c.is_synthetic, false)
         and not exists (select 1 from public.sales r
                          where r.business_id = s.business_id and r.reversal_of = s.id)
       group by 1
    ) w using (day_no);
  n := n + 1;
  if v_served is distinct from v_expect then
    raise exception 'A%: the chart serves % but the deduplicated visit-days are %', n, v_served, v_expect;
  end if;

  ---------------------------------------------------------------------------
  -- A4  negative control: the pre-v865 raw-row array must differ.
  ---------------------------------------------------------------------------
  select array_agg(coalesce(w.visits, 0) order by d.day_no) into v_raw
    from generate_series(1,7) d(day_no)
    left join (
      select extract(isodow from s.occurred_at at time zone 'Asia/Singapore')::int as day_no,
             count(*) as visits
        from public.sales s
       where s.business_id = c_biz
         and s.branch_id = any(v_scope)
         and s.counts_as_visit and s.reversal_of is null
         and s.occurred_at >= t_from and s.occurred_at < t_to
         and not exists (select 1 from public.sales r
                          where r.business_id = s.business_id and r.reversal_of = s.id)
       group by 1
    ) w using (day_no);
  n := n + 1;
  if v_raw is not distinct from v_served then
    raise exception 'A%: the raw sale-row array % is identical to the served array — this fixture cannot detect the defect and A2/A3 passed for free', n, v_raw;
  end if;

  ---------------------------------------------------------------------------
  -- A5  a split bill is ONE visit, in the tile AND in the chart.
  ---------------------------------------------------------------------------
  select c.id into v_client
    from public.clients c
   where c.business_id = c_biz and not c.is_synthetic
   order by c.created_at limit 1;
  if v_client is null then
    raise exception 'A%: the fixture has no real customer to record a sale for', n + 1;
  end if;

  insert into public.sales (business_id, branch_id, client_id, kind, amount_cents, occurred_at, created_at)
  values (c_biz, c_branch, v_client, 'service', 4200, now(), now());

  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', c_owner, 'role','authenticated')::text, true);
  j := public.get_dashboard_summary_v155(c_biz, d_from, d_to, 'all', array[]::uuid[], null);
  reset role; perform set_config('request.jwt.claims','',true);
  v_tile := (j->>'visits')::bigint;
  v_bucket := (j->'visits_by_weekday'->(v_dow - 1))::text::bigint;
  select coalesce(sum(e::text::bigint), 0) into v_chart from jsonb_array_elements(j->'visits_by_weekday') e;
  n := n + 1;
  if v_tile is distinct from v_chart then
    raise exception 'A%: after one sale the tile is % and the chart totals %', n, v_tile, v_chart;
  end if;

  -- the SAME customer buys again the same day: a split bill, not a second visit
  insert into public.sales (business_id, branch_id, client_id, kind, amount_cents, occurred_at, created_at)
  values (c_biz, c_branch, v_client, 'service', 3100, now(), now());

  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', c_owner, 'role','authenticated')::text, true);
  j := public.get_dashboard_summary_v155(c_biz, d_from, d_to, 'all', array[]::uuid[], null);
  reset role; perform set_config('request.jwt.claims','',true);
  v_tile2 := (j->>'visits')::bigint;
  v_bucket2 := (j->'visits_by_weekday'->(v_dow - 1))::text::bigint;
  select coalesce(sum(e::text::bigint), 0) into v_chart2 from jsonb_array_elements(j->'visits_by_weekday') e;
  n := n + 1;
  if v_tile2 <> v_tile or v_bucket2 <> v_bucket then
    raise exception 'A%: a second same-day sale for the same customer moved the tile % -> % and today''s bucket % -> %',
      n, v_tile, v_tile2, v_bucket, v_bucket2;
  end if;
  n := n + 1;
  if v_tile2 is distinct from v_chart2 then
    raise exception 'A%: tile % and chart total % diverged on the split bill', n, v_tile2, v_chart2;
  end if;

  ---------------------------------------------------------------------------
  -- A6  a walk-in has no identity to deduplicate by and counts one apiece.
  ---------------------------------------------------------------------------
  insert into public.sales (business_id, branch_id, client_id, kind, amount_cents, occurred_at, created_at)
  values (c_biz, c_branch, null, 'service', 900, now(), now());

  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', c_owner, 'role','authenticated')::text, true);
  j := public.get_dashboard_summary_v155(c_biz, d_from, d_to, 'all', array[]::uuid[], null);
  reset role; perform set_config('request.jwt.claims','',true);
  v_tile := (j->>'visits')::bigint;
  v_bucket := (j->'visits_by_weekday'->(v_dow - 1))::text::bigint;
  select coalesce(sum(e::text::bigint), 0) into v_chart from jsonb_array_elements(j->'visits_by_weekday') e;
  n := n + 1;
  if v_tile <> v_tile2 + 1 or v_bucket <> v_bucket2 + 1 then
    raise exception 'A%: a walk-in sale moved the tile % -> % and today''s bucket % -> % (expected +1 on both)',
      n, v_tile2, v_tile, v_bucket2, v_bucket;
  end if;
  n := n + 1;
  if v_tile is distinct from v_chart then
    raise exception 'A%: tile % and chart total % diverged on the walk-in', n, v_tile, v_chart;
  end if;

  ---------------------------------------------------------------------------
  -- A7  a synthetic customer is invisible to BOTH numbers. Before v865 the KPI
  --     block filtered synthetic clients and the weekday block did not, so this
  --     sale moved the chart while leaving the tile alone.
  ---------------------------------------------------------------------------
  insert into public.clients (business_id, full_name, is_synthetic)
  values (c_biz, 'ZZ v865 synthetic probe', true)
  returning id into v_synth;
  insert into public.sales (business_id, branch_id, client_id, kind, amount_cents, occurred_at, created_at)
  values (c_biz, c_branch, v_synth, 'service', 7700, now(), now());

  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', c_owner, 'role','authenticated')::text, true);
  j := public.get_dashboard_summary_v155(c_biz, d_from, d_to, 'all', array[]::uuid[], null);
  reset role; perform set_config('request.jwt.claims','',true);
  v_tile2 := (j->>'visits')::bigint;
  v_bucket2 := (j->'visits_by_weekday'->(v_dow - 1))::text::bigint;
  select coalesce(sum(e::text::bigint), 0) into v_chart2 from jsonb_array_elements(j->'visits_by_weekday') e;
  n := n + 1;
  if v_tile2 <> v_tile or v_bucket2 <> v_bucket then
    raise exception 'A%: a synthetic customer''s sale moved the tile % -> % and today''s bucket % -> %',
      n, v_tile, v_tile2, v_bucket, v_bucket2;
  end if;
  n := n + 1;
  if v_tile2 is distinct from v_chart2 then
    raise exception 'A%: tile % and chart total % diverged on the synthetic sale', n, v_tile2, v_chart2;
  end if;

  ---------------------------------------------------------------------------
  -- A8  estate-wide. The RPC refuses a caller with no permission, so this has
  --     to be read business by business as each business's own owner.
  ---------------------------------------------------------------------------
  n := n + 1;
  v_txt := null;
  for r in
    select b.id, b.name, o.user_id
      from public.businesses b
      join lateral (select st.user_id from public.staff st
                     where st.business_id = b.id and st.role = 'owner'
                       and st.active and st.user_id is not null
                     order by st.created_at limit 1) o on true
  loop
    begin
      set local role authenticated;
      perform set_config('request.jwt.claims', json_build_object('sub', r.user_id, 'role','authenticated')::text, true);
      j := public.get_dashboard_summary_v155(r.id, d_from, d_to, 'all', array[]::uuid[], null);
      reset role; perform set_config('request.jwt.claims','',true);
    exception when insufficient_privilege then
      -- this owner login cannot read this dashboard; the assertion is about the two numbers
      -- agreeing, not about that tenant's staffing, so skip rather than fail for another reason
      reset role; perform set_config('request.jwt.claims','',true);
      continue;
    end;
    v_tile := (j->>'visits')::bigint;
    select coalesce(sum(e::text::bigint), 0) into v_chart from jsonb_array_elements(j->'visits_by_weekday') e;
    if v_tile is distinct from v_chart then
      v_txt := concat_ws(', ', v_txt, r.name||' (tile '||v_tile||' vs chart '||v_chart||')');
    end if;
  end loop;
  if v_txt is not null then
    raise exception 'A%: the Visits tile and the weekday chart disagree for: %', n, v_txt;
  end if;

  ---------------------------------------------------------------------------
  -- A9  last, not first. A text check is only a guard against a future retype
  --     dropping the predicate; placed first it would fire before the number
  --     comparisons and turn the negative control into a grep.
  ---------------------------------------------------------------------------
  n := n + 1;
  if position('count(distinct (s.client_id, app.ci_visit_day_v699(s.occurred_at)))' in
       pg_get_functiondef(
         'public.get_dashboard_summary_v155(uuid,date,date,text,uuid[],uuid)'::regprocedure)) = 0
     or position('extract(isodow from app.ci_visit_day_v699(s.occurred_at))' in
       pg_get_functiondef(
         'public.get_dashboard_summary_v155(uuid,date,date,text,uuid[],uuid)'::regprocedure)) = 0 then
    raise exception 'A%: the weekday chart is no longer deduplicated by visit-day', n;
  end if;

  raise notice 'nestly_v865: % / % assertions passed', n, n;
end
$suite$;

rollback;
