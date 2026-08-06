-- Rollback-only v179 acceptance: insight evidence for AI firm reports.
-- Run after the canonical chain through v179. Prod-compatible: fixture-scoped
-- business and clients; no assertion depends on pre-existing data.
begin;

do $v179$
declare
  v_business uuid := '17900000-0000-4000-8000-000000000010';
  v_regular uuid := '17900000-0000-4000-8000-000000000020';
  v_newbie uuid := '17900000-0000-4000-8000-000000000021';
  v_lapsed uuid := '17900000-0000-4000-8000-000000000022';
  v_from date := '2026-07-01';
  v_to date := '2026-07-31';
  v_prior_from date := '2026-06-01';
  v_prior_to date := '2026-06-30';
  v_insights jsonb;
  v_pack jsonb;
begin
  if to_regprocedure('app.v179_business_insights(uuid,date,date,date,date)') is null then
    raise exception 'v179_business_insights is missing';
  end if;
  if has_function_privilege('authenticated',
       'app.v179_business_insights(uuid,date,date,date,date)','EXECUTE')
     or has_function_privilege('anon',
       'app.v179_business_insights(uuid,date,date,date,date)','EXECUTE') then
    raise exception 'v179_business_insights is callable by browser roles';
  end if;

  insert into public.businesses(id,name,slug,industry)
  values (v_business,'V179 Insight Fixture','v179-insight-fixture','fnb');
  insert into public.clients(id,business_id,full_name,phone) values
    (v_regular,v_business,'Mei Lin Ho','91790001'),
    (v_newbie,v_business,'Raj Kumar','91790002'),
    (v_lapsed,v_business,'Sarah Ong','91790003');

  -- Regular: first visit in June (prior window), returns twice in July.
  insert into public.sales(business_id,client_id,kind,amount_cents,occurred_at) values
    (v_business,v_regular,'service',3000,'2026-06-10 03:00+00'),
    (v_business,v_regular,'service',4000,'2026-07-05 03:00+00'),
    (v_business,v_regular,'service',5000,'2026-07-19 03:00+00'),
  -- Newbie: first-ever visit in July.
    (v_business,v_newbie,'service',2000,'2026-07-12 03:00+00'),
  -- Lapsed regular: two visits, last one ~70 days before period end.
    (v_business,v_lapsed,'service',6000,'2026-04-01 03:00+00'),
    (v_business,v_lapsed,'service',8000,'2026-05-22 03:00+00');

  v_insights := app.v179_business_insights(
    v_business, v_from, v_to, v_prior_from, v_prior_to);

  if (v_insights#>>'{retention,customers_served}')::int <> 2 then
    raise exception 'served expected 2: %', v_insights->'retention';
  end if;
  if (v_insights#>>'{retention,new_customers}')::int <> 1
     or (v_insights#>>'{retention,returning_customers}')::int <> 1
     or (v_insights#>>'{retention,repeat_rate_pct}')::numeric <> 50.0 then
    raise exception 'new/returning split wrong: %', v_insights->'retention';
  end if;
  if (v_insights#>>'{retention,prior_period_new_customers}')::int <> 1
     or (v_insights#>>'{retention,prior_new_who_returned_this_period}')::int <> 1
     or (v_insights#>>'{retention,prior_new_return_rate_pct}')::numeric <> 100.0 then
    raise exception 'prior-new return rate wrong: %', v_insights->'retention';
  end if;

  if (v_insights#>>'{at_risk,customers}')::int <> 1 then
    raise exception 'at-risk count expected 1: %', v_insights->'at_risk';
  end if;
  -- Lapsed customer: 14000 cents over 2 visits -> avg ticket 7000.
  if (v_insights#>>'{at_risk,recovery_value_one_visit_each_cents}')::bigint <> 7000 then
    raise exception 'at-risk recovery value expected 7000: %', v_insights->'at_risk';
  end if;

  -- Top customer is the regular (9000 of 11000 July cents = 81.8%).
  if (v_insights#>>'{top_customers,top1_share_pct}')::numeric <> 81.8 then
    raise exception 'top1 share expected 81.8: %', v_insights->'top_customers';
  end if;
  if v_insights#>'{top_customers,rows,0}'->>'label' <> 'Mei H.' then
    raise exception 'top customer label not abbreviated: %',
      v_insights#>'{top_customers,rows,0}';
  end if;
  if position('91790001' in v_insights::text) > 0
     or position('Mei Lin Ho' in v_insights::text) > 0 then
    raise exception 'insights leaked a full name or phone';
  end if;

  if jsonb_array_length(v_insights#>'{weekday_pattern,rows}') < 1 then
    raise exception 'weekday pattern empty';
  end if;

  -- The evidence pack now carries the insights and flags the version.
  v_pack := app.v176_evidence_pack(v_business,'monthly',v_from,v_to);
  if not (v_pack ? 'insights')
     or v_pack#>>'{evidence_completeness,insights_version}' <> 'v179' then
    raise exception 'evidence pack does not carry v179 insights: %',
      v_pack->'evidence_completeness';
  end if;

  raise notice 'v179 insight evidence: all assertions passed';
end
$v179$;

rollback;
