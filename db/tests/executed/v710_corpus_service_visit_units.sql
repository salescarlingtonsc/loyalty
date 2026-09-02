-- EXECUTED regression fixture for nestly_v710 -- promotion_dependency.rate and value_association
-- on public.get_ci_service_intelligence_v1 must count VISIT-DAYS (client_id,
-- app.ci_visit_day_v699(occurred_at)), not raw sale rows -- a same-day split bill (several
-- tickets, one afternoon) is one visit, not several (checks 4 and 38). Above the v422 watermark:
-- n/a in the baseline phase, gated on the migrated run.
--
-- TRUTH TABLE (hand-computed before running anything):
--
-- Service S buyer population (promotion_dependency.rate): s1..s5 each have ONE sale, full price,
-- on a distinct day each. s6 has TWO sales on the SAME calendar day (a split bill) -- one full
-- price, one carrying a studio_discount line -- making that one day discounted.
--   Raw sale rows: 7 (s1..s5 = 1 each, s6 = 2). BUGGY (pre-v710) denominator: 7, numerator 1
--   (only s6's discounted sale) -> 1/7 = 14.3%.
--   Correct VISIT-DAY count: 6 (s1..s5 = 1 day each, s6 = 1 day, collapsed) -> 1/6 = 16.7%.
--   1/6 = 16.7% < 20% -> dependency_class = 'organic'.
--
-- Non-buyer population (value_association control group, c1..c6): c1..c5 each have ONE sale on a
-- distinct day, ticket 3000c. c6 has TWO sales on the SAME calendar day (3000c + 2000c) -- a split
-- bill, no service line item at all (never a buyer of S).
--   median_ticket: BUGGY reads 7 raw tickets ([3000,3000,3000,3000,3000,3000,2000]); CORRECT reads
--   6 visit-day tickets, c6's day summed to 3000+2000=5000c ([3000,3000,3000,3000,3000,5000]) ->
--   n=6, median=3000 (the middle two of six sorted values, both 3000).
--   repeat_visit_rate: every one of the 6 non-buyers has exactly ONE distinct visit-day (c6's
--   split bill collapses to one day) -> 0/6 = 0.0%.
--
-- AGREEMENT CHECK: get_ci_discount_dependency_v1 (v683/v699), which already counts visit-DAYS,
-- classifies all 6 real S-buyer clients (s1..s6) -- each with exactly one visit-day, so all_visits
-- < 3 puts every one of them in 'insufficient'. Asserting this sums to 6 (not 7) is the
-- independent cross-check that the correct population size is 6.
--
-- MUTATION (buyer side, distinguishes fixed-vs-reverted logic, not just "any change"): add a
-- SECOND sale for s2 on s2's OWN existing calendar day, carrying a studio_discount line. This
-- keeps the visit-day COUNT at 6 (s2's day was already counted once; a second same-day sale adds
-- no new day) while raising the discounted-visit-day count from 1 to 2 -> 2/6 = 33.3% (organic ->
-- mixed). Under the pre-v710 raw-sale-row logic this would instead move to 2 discounted sales out
-- of 8 total sales = 25.0% -- a DIFFERENT number, which is exactly why this mutation (rather than
-- a same-day pair for a brand-new client) proves the fix is really visit-day-keyed and not merely
-- coincidentally correct on the base fixture.
--
-- MUTATION (non-buyer side): give c1 a SECOND sale on a NEW (different) calendar day -> c1 now
-- has 2 distinct visit-days -> repeat_customers=1 of 6 -> repeat_visit_rate 1/6 = 16.7%.

\set ON_ERROR_STOP on
begin;
create temp table _fail(k text, v text) on commit drop;

do $v710setup$
declare
  u_sa uuid := '00000000-0000-4000-8000-000000710eee';
begin
  insert into auth.users (id, email) values (u_sa, 'zz-v710-sa@example.test')
    on conflict (id) do nothing;
  insert into public.super_admins (user_id, email) values (u_sa, 'zz-v710-sa@example.test')
    on conflict do nothing;
  perform set_config('request.jwt.claims', json_build_object(
      'sub', u_sa, 'role','authenticated',
      'amr', json_build_array(json_build_object('method','oauth')),
      'app_metadata', json_build_object('providers', json_build_array('google'))
    )::text, true);
end;
$v710setup$;

do $v710a$
declare
  biz uuid := gen_random_uuid();
  br uuid := gen_random_uuid();
  svc_s uuid := gen_random_uuid();
  d_to date := current_date;
  d_from date := current_date - 20;

  s_ids uuid[] := array(select gen_random_uuid() from generate_series(1,6));
  c_ids uuid[] := array(select gen_random_uuid() from generate_series(1,6));

  g jsonb;
  g683 jsonb;
  row_s jsonb;
  sid uuid;
  i integer;
  day_anchor timestamptz;
  v683_total integer;
  v683_insuff integer;
begin
  insert into public.businesses (id, name, slug, enabled_modules) values
    (biz, 'ZZ v710 visit-units firm', 'zz-v710-visit-units', array['dashboard','clients','sales','reports']);
  insert into public.branches (id, business_id, name, is_default, active) values
    (br, biz, 'ZZ v710 branch', true, true);
  insert into public.services (id, business_id, name, price_cents, duration_min) values
    (svc_s, biz, 'ZZ v710 service S', 5000, 30);

  -- ---------------------------------------------------------------------------
  -- Service S buyers: s1..s5, one full-price sale each, distinct days (spread across the window
  -- so no two land on the same calendar day by accident).
  -- ---------------------------------------------------------------------------
  insert into public.clients (id, business_id, full_name)
    select s_ids[gs], biz, 'ZZ v710 S buyer ' || gs from generate_series(1,5) gs;

  for i in 1..5 loop
    day_anchor := ((current_date - (10 + i))::timestamp + time '10:00') at time zone 'Asia/Singapore';
    sid := gen_random_uuid();
    insert into public.sales (id, business_id, branch_id, client_id, kind, amount_cents, occurred_at)
    values (sid, biz, br, s_ids[i], 'service', 5000, day_anchor);
    insert into public.sale_items (business_id, sale_id, item_type, ref_id, qty, unit_cents, line_cents)
    values (biz, sid, 'service', svc_s, 1, 5000, 5000);
  end loop;

  -- s6: a same-day split bill -- two sales, same calendar day, one full price and one carrying a
  -- studio_discount line. This is the ONE discounted visit-day.
  insert into public.clients (id, business_id, full_name) values (s_ids[6], biz, 'ZZ v710 S buyer 6');
  day_anchor := ((current_date - 3)::timestamp + time '10:00') at time zone 'Asia/Singapore';
  sid := gen_random_uuid();
  insert into public.sales (id, business_id, branch_id, client_id, kind, amount_cents, occurred_at)
  values (sid, biz, br, s_ids[6], 'service', 5000, day_anchor);
  insert into public.sale_items (business_id, sale_id, item_type, ref_id, qty, unit_cents, line_cents)
  values (biz, sid, 'service', svc_s, 1, 5000, 5000);

  sid := gen_random_uuid();
  insert into public.sales (id, business_id, branch_id, client_id, kind, amount_cents, occurred_at)
  values (sid, biz, br, s_ids[6], 'service', 4000,
          ((current_date - 3)::timestamp + time '15:00') at time zone 'Asia/Singapore');
  insert into public.sale_items (business_id, sale_id, item_type, ref_id, qty, unit_cents, line_cents)
  values (biz, sid, 'service', svc_s, 1, 5000, 5000);
  insert into public.sale_items (business_id, sale_id, item_type, ref_id, qty, unit_cents, line_cents)
  values (biz, sid, 'studio_discount', null, 1, -1000, -1000);

  -- ---------------------------------------------------------------------------
  -- Non-buyers (control group for value_association): c1..c5 one sale each (ticket 3000c),
  -- distinct days; c6 a same-day split bill (3000c + 2000c = day sum 5000c). None ever touches
  -- service S.
  -- ---------------------------------------------------------------------------
  insert into public.clients (id, business_id, full_name)
    select c_ids[gs], biz, 'ZZ v710 control ' || gs from generate_series(1,6) gs;

  for i in 1..5 loop
    day_anchor := ((current_date - (10 + i))::timestamp + time '11:00') at time zone 'Asia/Singapore';
    sid := gen_random_uuid();
    insert into public.sales (id, business_id, branch_id, client_id, kind, amount_cents, occurred_at)
    values (sid, biz, br, c_ids[i], 'retail', 3000, day_anchor);
    insert into public.sale_items (business_id, sale_id, item_type, ref_id, qty, unit_cents, line_cents)
    values (biz, sid, 'custom', null, 1, 3000, 3000);
  end loop;

  day_anchor := ((current_date - 3)::timestamp + time '11:00') at time zone 'Asia/Singapore';
  sid := gen_random_uuid();
  insert into public.sales (id, business_id, branch_id, client_id, kind, amount_cents, occurred_at)
  values (sid, biz, br, c_ids[6], 'retail', 3000, day_anchor);
  insert into public.sale_items (business_id, sale_id, item_type, ref_id, qty, unit_cents, line_cents)
  values (biz, sid, 'custom', null, 1, 3000, 3000);

  sid := gen_random_uuid();
  insert into public.sales (id, business_id, branch_id, client_id, kind, amount_cents, occurred_at)
  values (sid, biz, br, c_ids[6], 'retail', 2000,
          ((current_date - 3)::timestamp + time '16:00') at time zone 'Asia/Singapore');
  insert into public.sale_items (business_id, sale_id, item_type, ref_id, qty, unit_cents, line_cents)
  values (biz, sid, 'custom', null, 1, 2000, 2000);

  -- ===============================================================================
  -- CALL 1: get_ci_service_intelligence_v1 -- base fixture, before any mutation.
  -- ===============================================================================
  g := public.get_ci_service_intelligence_v1(biz, d_from, d_to);
  select s into row_s from jsonb_array_elements(g->'services') s where (s->>'service_id')::uuid = svc_s;

  if row_s is null then
    insert into _fail values ('S0', 'service S missing from services array');
  else
    -- visit_definition must be present at the top level of the payload.
    if g->>'visit_definition' is null then
      insert into _fail values ('TOP-visit-def', 'expected a top-level visit_definition key on get_ci_service_intelligence_v1''s payload');
    end if;

    -- promotion_dependency.rate: 1 discounted visit-day of 6, NOT 1 of 7.
    if row_s->'promotion_dependency' is null then
      insert into _fail values ('PD-null', 'expected promotion_dependency populated');
    else
      if (row_s->'promotion_dependency'->'rate'->>'numerator')::int <> 1 then
        insert into _fail values ('PD-num', format('got %s, expected 1', row_s->'promotion_dependency'->'rate'->>'numerator'));
      end if;
      if (row_s->'promotion_dependency'->'rate'->>'denominator')::int <> 6 then
        insert into _fail values ('PD-den', format('got %s, expected 6 (visit-days), not 7 (raw sales)', row_s->'promotion_dependency'->'rate'->>'denominator'));
      end if;
      if (row_s->'promotion_dependency'->'rate'->>'pct')::numeric <> 16.7 then
        insert into _fail values ('PD-pct', format('got %s, expected 16.7 (= 1/6), not 14.3 (= 1/7)', row_s->'promotion_dependency'->'rate'->>'pct'));
      end if;
      if row_s->'promotion_dependency'->>'dependency_class' <> 'organic' then
        insert into _fail values ('PD-class', format('got %s, expected organic (16.7%% < 20%%)', row_s->'promotion_dependency'->>'dependency_class'));
      end if;
      if row_s->'promotion_dependency'->'evidence'->>'status' <> 'ok' then
        insert into _fail values ('PD-evidence', 'expected evidence.status=ok at n=6 visit-buyers');
      end if;
    end if;

    -- value_association buyers-side sanity (unaffected by the split bill's day-count, since s6
    -- still contributes exactly one client either way -- included as a population-size check).
    if row_s->'value_association' is null then
      insert into _fail values ('VA-null', 'expected value_association populated');
    else
      if row_s->'value_association'->'buyers'->'evidence'->>'status' <> 'ok' then
        insert into _fail values ('VA-buyers-ev', 'expected buyer-side evidence.status=ok at n=6');
      end if;

      -- non_buyers: the check-4 assertions.
      if row_s->'value_association'->'non_buyers'->'evidence'->>'status' <> 'ok' then
        insert into _fail values ('VA-nb-ev', 'expected non-buyer-side evidence.status=ok at n=6');
      end if;
      if (row_s->'value_association'->'non_buyers'->'median_ticket'->>'n')::int <> 6 then
        insert into _fail values ('VA-nb-n', format('got %s, expected 6 visit-days, not 7 raw tickets', row_s->'value_association'->'non_buyers'->'median_ticket'->>'n'));
      end if;
      if (row_s->'value_association'->'non_buyers'->'median_ticket'->>'median')::numeric <> 3000 then
        insert into _fail values ('VA-nb-median', format('got %s, expected 3000 (median of [3000,3000,3000,3000,3000,5000], the split-bill day summed to 5000)', row_s->'value_association'->'non_buyers'->'median_ticket'->>'median'));
      end if;
      if (row_s->'value_association'->'non_buyers'->'repeat_visit_rate'->>'numerator')::int <> 0 then
        insert into _fail values ('VA-nb-repeat-num', format('got %s, expected 0 (no non-buyer has a SECOND distinct visit-day yet)', row_s->'value_association'->'non_buyers'->'repeat_visit_rate'->>'numerator'));
      end if;
      if (row_s->'value_association'->'non_buyers'->'repeat_visit_rate'->>'denominator')::int <> 6 then
        insert into _fail values ('VA-nb-repeat-den', format('got %s, expected 6', row_s->'value_association'->'non_buyers'->'repeat_visit_rate'->>'denominator'));
      end if;
      if (row_s->'value_association'->'non_buyers'->'repeat_visit_rate'->>'pct')::numeric <> 0.0 then
        insert into _fail values ('VA-nb-repeat-pct', format('got %s, expected 0.0', row_s->'value_association'->'non_buyers'->'repeat_visit_rate'->>'pct'));
      end if;
    end if;
  end if;

  -- ===============================================================================
  -- AGREEMENT: get_ci_discount_dependency_v1 (v683/v699) already counts visit-days -- it must
  -- classify exactly the 6 real S-buyer clients (s1..s6), not 7, proving the two readers agree on
  -- WHICH ROWS are real visits. Scoped by re-running against a window that only contains the S
  -- buyers' sales by construction (the control clients have no service line item, but they DO
  -- have counts_as_visit sales too -- so the true population v683 sees here is all 12 clients;
  -- the assertion below sums to 12 for that reason, then separately asserts insufficient=12,
  -- exactly the same shape as nestly_v707's own fixture and for the same reason: v683 classifies
  -- every visit-having client in the window, not just S's buyers).
  -- ===============================================================================
  g683 := public.get_ci_discount_dependency_v1(biz, d_from, d_to);
  v683_total := (g683->'classes'->'organic'->>'n')::int
              + (g683->'classes'->'discount_dependent'->>'n')::int
              + (g683->'classes'->'mixed'->>'n')::int
              + (g683->'classes'->'insufficient'->>'n')::int;
  if v683_total <> 12 then
    insert into _fail values ('AGREE-population', format(
      'v683 classified %s customers total, expected 12 (6 S buyers + 6 control clients) -- not 14 (raw sale rows would imply more if double-counted)',
      v683_total));
  end if;
  v683_insuff := (g683->'classes'->'insufficient'->>'n')::int;
  if v683_insuff <> 12 then
    insert into _fail values ('AGREE-insufficient', format(
      'expected all 12 single-visit-day clients to bucket as insufficient (all_visits<3), got %s -- if a split bill were still counted as 2 visits, s6/c6 could have crossed the <3 floor',
      v683_insuff));
  end if;

  -- ===============================================================================
  -- MUTATION (buyer/promotion side): a second, discounted sale for s2 on s2's OWN existing day.
  -- Visit-day count stays 6 (no new day); discounted-visit-day count moves 1 -> 2 -> 33.3%,
  -- organic -> mixed. Under raw-sale-row counting this would instead read 2/8 = 25.0% -- a
  -- different wrong number, proving this mutation actually discriminates the fix.
  -- ===============================================================================
  day_anchor := (select occurred_at from public.sales where business_id = biz and client_id = s_ids[2] limit 1);
  sid := gen_random_uuid();
  insert into public.sales (id, business_id, branch_id, client_id, kind, amount_cents, occurred_at)
  values (sid, biz, br, s_ids[2], 'service', 4000, day_anchor + interval '2 hours');
  insert into public.sale_items (business_id, sale_id, item_type, ref_id, qty, unit_cents, line_cents)
  values (biz, sid, 'service', svc_s, 1, 5000, 5000);
  insert into public.sale_items (business_id, sale_id, item_type, ref_id, qty, unit_cents, line_cents)
  values (biz, sid, 'studio_discount', null, 1, -1000, -1000);

  g := public.get_ci_service_intelligence_v1(biz, d_from, d_to);
  select s into row_s from jsonb_array_elements(g->'services') s where (s->>'service_id')::uuid = svc_s;

  if row_s is null then
    insert into _fail values ('MUT-PD-S0', 'service S missing after promotion mutation');
  else
    if (row_s->'promotion_dependency'->'rate'->>'numerator')::int <> 2 then
      insert into _fail values ('MUT-PD-num', format('got %s, expected 2 (discounted visit-days) after mutation', row_s->'promotion_dependency'->'rate'->>'numerator'));
    end if;
    if (row_s->'promotion_dependency'->'rate'->>'denominator')::int <> 6 then
      insert into _fail values ('MUT-PD-den', format('got %s, expected 6 (unchanged visit-day count -- s2''s new sale lands on an EXISTING day) -- 8 would mean this is still counting raw sale rows', row_s->'promotion_dependency'->'rate'->>'denominator'));
    end if;
    if (row_s->'promotion_dependency'->'rate'->>'pct')::numeric <> 33.3 then
      insert into _fail values ('MUT-PD-pct', format('got %s, expected 33.3 (= 2/6), not 25.0 (= 2/8, the raw-sale-row answer)', row_s->'promotion_dependency'->'rate'->>'pct'));
    end if;
    if row_s->'promotion_dependency'->>'dependency_class' <> 'mixed' then
      insert into _fail values ('MUT-PD-class', format('got %s, expected mixed (33.3%% is between 20%% and 60%%)', row_s->'promotion_dependency'->>'dependency_class'));
    end if;
  end if;

  -- ===============================================================================
  -- MUTATION (non-buyer/value_association side): give c1 a second sale on a NEW day -> c1 now has
  -- 2 distinct visit-days -> repeat_customers 1 of 6 -> 16.7%.
  -- ===============================================================================
  sid := gen_random_uuid();
  insert into public.sales (id, business_id, branch_id, client_id, kind, amount_cents, occurred_at)
  values (sid, biz, br, c_ids[1], 'retail', 3500,
          ((current_date - 1)::timestamp + time '11:00') at time zone 'Asia/Singapore');
  insert into public.sale_items (business_id, sale_id, item_type, ref_id, qty, unit_cents, line_cents)
  values (biz, sid, 'custom', null, 1, 3500, 3500);

  g := public.get_ci_service_intelligence_v1(biz, d_from, d_to);
  select s into row_s from jsonb_array_elements(g->'services') s where (s->>'service_id')::uuid = svc_s;

  if row_s is null then
    insert into _fail values ('MUT-VA-S0', 'service S missing after value_association mutation');
  else
    if (row_s->'value_association'->'non_buyers'->'repeat_visit_rate'->>'numerator')::int <> 1 then
      insert into _fail values ('MUT-VA-num', format('got %s, expected 1 (c1 now has 2 distinct visit-days)', row_s->'value_association'->'non_buyers'->'repeat_visit_rate'->>'numerator'));
    end if;
    if (row_s->'value_association'->'non_buyers'->'repeat_visit_rate'->>'denominator')::int <> 6 then
      insert into _fail values ('MUT-VA-den', format('got %s, expected 6', row_s->'value_association'->'non_buyers'->'repeat_visit_rate'->>'denominator'));
    end if;
    if (row_s->'value_association'->'non_buyers'->'repeat_visit_rate'->>'pct')::numeric <> 16.7 then
      insert into _fail values ('MUT-VA-pct', format('got %s, expected 16.7 (= 1/6)', row_s->'value_association'->'non_buyers'->'repeat_visit_rate'->>'pct'));
    end if;
  end if;
end
$v710a$;

select case when count(*)=0 then 'PASS — promotion_dependency and value_association count visit-days, not raw sale rows'
            else 'FAIL' end as verdict,
       count(*) as failures from _fail;
select k, v from _fail order by k, v;

do $verdict$
declare n integer; d text;
begin
  select count(*), string_agg(format('%s: %s', f.k, f.v), E'\n  ' order by f.k, f.v)
    into n, d from _fail f;
  if n > 0 then raise exception 'v710: % assertion(s) failed:%  %', n, E'\n', d; end if;
end
$verdict$;

rollback;
