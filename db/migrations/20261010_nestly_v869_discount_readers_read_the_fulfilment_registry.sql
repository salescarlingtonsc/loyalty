-- nestly_v869 — the two discount readers read the fulfilment registry, not Studio provenance.
--
-- WHAT WAS LIVE, AND WHY IT IS WRONG. public.get_checkout_discount_report (Reports → Discounts,
-- and its CSV) and app.owner_brief_fact_discounts_v828 (the Home brief's "who is giving
-- discounts, and on what?") both read ONLY public.checkout_discount_lines. That table is Studio
-- provenance: record_cart_sale writes a row there only when the applied effect carries a
-- rule_id (its own comment: "A tier discount has no rule, so it gets no row there rather than a
-- fabricated one"). The v370 automatic tier discount and the v752 birthday discount therefore
-- never reach either reader. Measured on prod 2026-09-09: checkout_discount_lines holds 2 rows
-- estate-wide, while public.benefit_fulfilments holds every checkout discount ever settled —
-- AhXiang 2 lines / 293,800c and Cubbly SPA 5 lines / 27,600c — and the negative
-- 'studio_discount' sale_items lines agree (10 rows, 321,750c). So the Reports discount total
-- read $0.00 and the brief said "Not enough history yet" on a tenant that had given $2,938.00.
--
-- THE FIX. One authority for "a discount was given": the fulfilment registry row every discount
-- path already writes (fulfilment_kind = 'checkout_discount', detail_ref = the sale). Both
-- readers now start from it. The Studio row, where one exists, still supplies the rule for the
-- per-rule grouping; a rule-less discount is named by its benefit ('Tier benefit' /
-- 'Birthday gift'), exactly as the sale line describes it. GST comes from the sale's own
-- consumed evaluation, so it is present for every discounted sale, not only rule-keyed ones.
-- A reversed fulfilment (reverses_fulfilment_id, or a later row that reverses it) is excluded,
-- and the sale must still be a valid revenue original (app.analytics_sale_class_v1), as before.
--
-- The brief's evidence floor (10 lines) still gates the STAFF and BY-RULE rankings — a ranking
-- on three rows is noise — but total_discount_cents is a sum of settled money, not an estimate,
-- and is now stated whenever a single discount exists. The owner asked "how much did I give
-- away"; the honest answer to that on two lines is the two lines, not "not enough history".
--
-- Output shapes are unchanged: by_day_rule / grand_totals / csv, and the brief fact's keys.
-- rule_id may now be null in a by_day_rule row (a rule-less discount); the CSV prints it empty.

begin;

create or replace function public.get_checkout_discount_report(p_business uuid, p_from date, p_to date)
returns jsonb
language plpgsql
stable security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $function$
declare
  v_rows jsonb;
  v_grand jsonb;
  v_csv text;
begin
  if not (app.is_salon_owner(p_business) or app.is_super_admin()) then
    raise exception 'owner only' using errcode = '42501';
  end if;
  if p_from is null or p_to is null or p_to < p_from then
    raise exception 'a valid from/to date range is required' using errcode = '22023';
  end if;

  -- nestly_v869: the grain is the fulfilment registry row. One row per discount actually
  -- settled on a valid sale in the window; the Studio row (when the discount had a rule) only
  -- names the rule. Distinct-sale sales_total / gst avoid the double-count that summing a
  -- per-line grain would cause when a sale carries several discount lines.
  with lines as (
    select cdl.rule_id,
           bf.face_value_cents as amount_cents,
           s.id as sale_id,
           s.amount_cents as sale_total,
           (s.occurred_at at time zone 'Asia/Singapore')::date as sgt_date,
           coalesce(ce.gst_cents, 0) as gst_cents,
           case
             when cdl.rule_id is not null then null
             when bf.canonical_benefit_key like 'birthdaydiscount:%' then 'Birthday gift'
             when bf.canonical_benefit_key like 'tierdiscount:%' then 'Tier benefit'
             else 'Studio discount'
           end as benefit_name
      from public.benefit_fulfilments bf
      join public.sales s on s.id = bf.detail_ref and s.business_id = bf.business_id
      cross join lateral app.analytics_sale_class_v1(s) sc
      left join public.checkout_discount_lines cdl
        on cdl.benefit_fulfilment_id = bf.id and cdl.business_id = bf.business_id
      left join public.checkout_evaluations ce
        on ce.consumed_sale_id = s.id and ce.business_id = s.business_id
     where bf.business_id = p_business
       and bf.fulfilment_kind = 'checkout_discount'
       and bf.reverses_fulfilment_id is null
       and not exists (select 1 from public.benefit_fulfilments r
                        where r.business_id = bf.business_id and r.reverses_fulfilment_id = bf.id)
       and (s.occurred_at at time zone 'Asia/Singapore')::date between p_from and p_to
       and sc.include_revenue
       and not sc.is_synthetic_client
  ),
  sale_grain as (
    select distinct sgt_date, rule_id, benefit_name, sale_id, sale_total, gst_cents from lines
  ),
  discount_grain as (
    select sgt_date, rule_id, benefit_name,
           count(*)::int as discount_count, sum(amount_cents)::int as discount_cents
      from lines group by sgt_date, rule_id, benefit_name
  ),
  sale_totals as (
    select sgt_date, rule_id, benefit_name,
           sum(sale_total)::int as sales_total_cents, sum(gst_cents)::int as gst_cents
      from sale_grain group by sgt_date, rule_id, benefit_name
  ),
  merged as (
    select dg.sgt_date, dg.rule_id,
           coalesce(pr.name, dg.benefit_name, 'Studio discount') as rule_name,
           dg.discount_count, dg.discount_cents, st.sales_total_cents, st.gst_cents
      from discount_grain dg
      join sale_totals st
        on st.sgt_date = dg.sgt_date
       and st.rule_id is not distinct from dg.rule_id
       and st.benefit_name is not distinct from dg.benefit_name
      left join public.program_rules pr
        on pr.rule_id = dg.rule_id and pr.business_id = p_business
       and pr.config_version_id = (select active_config_version_id from public.businesses where id = p_business)
     order by dg.sgt_date, dg.rule_id
  )
  select
    coalesce(jsonb_agg(jsonb_build_object(
      'date', sgt_date, 'rule_id', rule_id, 'rule_name', rule_name,
      'discount_count', discount_count, 'discount_cents', discount_cents,
      'gst_cents', gst_cents, 'sales_total_cents', sales_total_cents) order by sgt_date, rule_id), '[]'::jsonb),
    'date,rule_id,rule_name,discount_count,discount_cents,gst_cents,sales_total_cents' ||
      coalesce(string_agg(E'\n' ||
        sgt_date::text || ',' || coalesce(rule_id::text, '') || ',' ||
        '"' || replace(rule_name, '"', '""') || '"' || ',' ||
        discount_count::text || ',' || discount_cents::text || ',' ||
        gst_cents::text || ',' || sales_total_cents::text, '' order by sgt_date, rule_id), '')
    into v_rows, v_csv
    from merged;

  -- Grand totals computed directly from the same registry grain; discount_cents is the
  -- reconciliation anchor. Distinct-sale sales_total / gst are the true unduplicated totals.
  with valid as (
    select bf.face_value_cents as amount_cents, s.id as sale_id, s.amount_cents as sale_total,
           coalesce(ce.gst_cents, 0) as gst_cents
      from public.benefit_fulfilments bf
      join public.sales s on s.id = bf.detail_ref and s.business_id = bf.business_id
      cross join lateral app.analytics_sale_class_v1(s) sc
      left join public.checkout_evaluations ce
        on ce.consumed_sale_id = s.id and ce.business_id = s.business_id
     where bf.business_id = p_business
       and bf.fulfilment_kind = 'checkout_discount'
       and bf.reverses_fulfilment_id is null
       and not exists (select 1 from public.benefit_fulfilments r
                        where r.business_id = bf.business_id and r.reverses_fulfilment_id = bf.id)
       and (s.occurred_at at time zone 'Asia/Singapore')::date between p_from and p_to
       and sc.include_revenue
       and not sc.is_synthetic_client
  )
  select jsonb_build_object(
           'discount_count', coalesce((select count(*) from valid), 0)::int,
           'discount_cents', coalesce((select sum(amount_cents) from valid), 0)::int,
           'sales_total_cents', coalesce((select sum(d.sale_total) from (select distinct sale_id, sale_total from valid) d), 0)::int,
           'gst_cents', coalesce((select sum(d.gst_cents) from (select distinct sale_id, gst_cents from valid) d), 0)::int)
    into v_grand;

  return jsonb_build_object(
    'business_id', p_business, 'from', p_from, 'to', p_to,
    'by_day_rule', v_rows, 'grand_totals', v_grand, 'csv', v_csv,
    'source', 'public.benefit_fulfilments (fulfilment_kind = checkout_discount) joined to valid sales; rule named from public.checkout_discount_lines where the discount had a rule');
end $function$;

-- ACL restated verbatim from prod (nestly_v869): this report has always been executable by
-- authenticated, service_role, anon and PUBLIC; the owner gate is inside the function.
revoke all on function public.get_checkout_discount_report(uuid,date,date) from public, anon;
grant execute on function public.get_checkout_discount_report(uuid,date,date) to authenticated, service_role, anon, public;

create or replace function app.owner_brief_fact_discounts_v828(p_business uuid)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $function$
declare
  v_to      date := app.sg_today() - 1;
  v_from    date := app.sg_today() - 56;
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
      -- nestly_v869: the fulfilment registry is the grain; the Studio row only names a rule.
      select bf.id, bf.face_value_cents as amount_cents, cdl.rule_id, vs.staff_id,
             case
               when cdl.rule_id is not null then null
               when bf.canonical_benefit_key like 'birthdaydiscount:%' then 'Birthday gift'
               when bf.canonical_benefit_key like 'tierdiscount:%' then 'Tier benefit'
               else 'Studio discount'
             end as benefit_name
      from public.benefit_fulfilments bf
      join valid_sales vs on vs.id = bf.detail_ref
      left join public.checkout_discount_lines cdl
        on cdl.benefit_fulfilment_id = bf.id and cdl.business_id = bf.business_id
      where bf.business_id = p_business
        and bf.fulfilment_kind = 'checkout_discount'
        and bf.reverses_fulfilment_id is null
        and not exists (select 1 from public.benefit_fulfilments r
                         where r.business_id = bf.business_id and r.reverses_fulfilment_id = bf.id)
    ), stats as (
      select count(*) as n, count(*) filter (where staff_id is not null) as n_staffed
      from lines
    )
    select jsonb_build_object(
      'status', 'ok',
      'evidence', case when stats.n < 10 then 'insufficient' else 'ok' end,
      'from', v_from, 'to', v_to,
      'discount_lines_seen', stats.n,
      'source', 'public.benefit_fulfilments (fulfilment_kind = checkout_discount) joined to valid public.sales (as app.v176_sales_window); rule named from public.checkout_discount_lines where the discount had a rule',
      -- nestly_v869: the total is settled money, stated whenever any discount exists. The
      -- evidence floor below gates only the rankings.
      'total_discount_cents', case when stats.n = 0 then null else
        (select coalesce(sum(amount_cents), 0) from lines) end,
      'total_note', case when stats.n between 1 and 9
        then 'fewer than 10 discount lines in the window: the total is exact, the staff and rule rankings are withheld'
        else null end,
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
          select l.rule_id, coalesce(pr.name, l.benefit_name, 'Studio discount') as rule_name,
                 sum(l.amount_cents) as discount_cents, count(*) as discount_count
          from lines l
          left join public.program_rules pr
            on pr.rule_id = l.rule_id and pr.business_id = p_business
           and pr.config_version_id = (select active_config_version_id from public.businesses where id = p_business)
          group by l.rule_id, l.benefit_name, pr.name
          order by sum(l.amount_cents) desc
          limit 5
        ) r
      ) end
    ) into v_result
    from stats;
  exception when others then
    get stacked diagnostics v_err = message_text;
    v_result := jsonb_build_object('status', 'unavailable', 'reason', left(v_err, 200),
      'source', 'public.benefit_fulfilments');
  end;
  return v_result;
end;
$function$;

-- ACL restated verbatim from prod: owner-only (postgres) — the brief composer calls it.
revoke all on function app.owner_brief_fact_discounts_v828(uuid) from public;

do $verify$
declare v_def text;
begin
  v_def := pg_get_functiondef('public.get_checkout_discount_report(uuid,date,date)'::regprocedure);
  if position('public.benefit_fulfilments bf' in v_def) = 0
     or position('fulfilment_kind = ''checkout_discount''' in v_def) = 0 then
    raise exception 'nestly_v869: get_checkout_discount_report does not read the fulfilment registry'
      using errcode = 'XX001';
  end if;
  v_def := pg_get_functiondef('app.owner_brief_fact_discounts_v828(uuid)'::regprocedure);
  if position('public.benefit_fulfilments bf' in v_def) = 0
     or position('''total_note''' in v_def) = 0 then
    raise exception 'nestly_v869: owner_brief_fact_discounts_v828 does not read the fulfilment registry'
      using errcode = 'XX001';
  end if;
end
$verify$;

commit;
