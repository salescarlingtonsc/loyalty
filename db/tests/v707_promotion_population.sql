-- EXECUTED regression fixture for nestly_v707 -- promotion_dependency and value_association must
-- draw from the VISIT population (include_visit), not the revenue population (include_revenue),
-- on public.get_ci_service_intelligence_v1 (check 38 fix). Above the v422 watermark: n/a in the
-- baseline phase, gated on the migrated run.
--
-- THE REFUTER'S SCENARIO, reproduced exactly: a tenant policy sets counts_as_revenue=false,
-- counts_as_visit=true for service S's sales, via a REAL public.sale_policies override row (see
-- below) -- the BEFORE INSERT snapshot trigger (app.on_sale_policy_snapshot(),
-- db/migrations/20260717_frenly_v10_1_policy_snapshot.sql) always overwrites whatever flags an
-- INSERT supplies with what that trigger resolves, so a bare column value on the `sales` insert
-- (the shortcut v697's own fixture uses for its all-default-policy scenario) cannot produce a
-- non-default policy here; only a genuine override row can. Six buyers (s1..s6), one sale each,
-- service line 5000c; s1's sale ALSO carries a studio_discount line of -1000c (ticket 4000c),
-- s2-s6 are full price (ticket 5000c each).
--   HAND-COMPUTED: all_sales=6, discounted_sales=1 -> rate.pct = round(100*1/6,1) = 16.7.
--   16.7 < 20 -> dependency_class = 'organic' under v683's own cut point (independently
--   recomputed inline below and asserted equal, same convention as v697's own fixture, whose
--   header explains why: v683 classifies a CUSTOMER by their own visit mix, this reader
--   classifies a SERVICE by its sales' discount mix -- different units, identical thresholds, so
--   there is no single per-row number to equate directly. What IS asserted directly is
--   population-size agreement: v683 (get_ci_discount_dependency_v1), which already read
--   include_visit before this fix existed, must classify all 6 of these real visits somewhere in
--   its 'classes' breakdown (organic+dependent+mixed+insufficient sums to 6) -- the same 6 that
--   v697's promotion_dependency now reports as its rate denominator, proving the two readers
--   agree on WHICH rows are real visits, which is exactly what they disagreed on before v707.
--
-- CONTROL GROUP for value_association's non-buyer side: six unrelated clients (c1..c6), each with
-- one 'custom' sale (no service line item, so they are never buyers of S), ticket 3000c each,
-- ordinary policy (counts_as_revenue=true, counts_as_visit=true) -- exercises the non-buyer side
-- of value_association at n=6, clearing the floor of 5.
--
-- PRE-FIX BEHAVIOUR (documented so a reader can see what regresses if v707 is ever reverted):
-- service S was ABSENT from the 'services' array entirely (per_service, built from `lines`
-- [include_revenue], had zero rows for S since every one of its sales has counts_as_revenue=
-- false) -- buyers/promotion_dependency/value_association all unreachable. This fixture's very
-- first assertion (S0) is exactly the one that catches a revert: if service_promo_agg / the
-- services_agg join ever goes back to driving off `per_service`/`lines` instead of
-- `all_service_ids`/`visit_lines`, row_s comes back null and every assertion beneath it fires.
--
-- 'buyers' (the REVENUE figure) MUST be null for S -- it earns zero counted revenue -- while
-- 'promotion_dependency' and 'value_association' (the VISIT figures) MUST be populated. This is
-- the population_basis split the migration header describes.

\set ON_ERROR_STOP on
begin;
create temp table _fail(k text, v text) on commit drop;

do $v707setup$
declare
  u_sa uuid := '00000000-0000-4000-8000-000000707eee';
begin
  insert into auth.users (id, email) values (u_sa, 'zz-v707-sa@example.test')
    on conflict (id) do nothing;
  insert into public.super_admins (user_id, email) values (u_sa, 'zz-v707-sa@example.test')
    on conflict do nothing;
  perform set_config('request.jwt.claims', json_build_object(
      'sub', u_sa, 'role','authenticated',
      'amr', json_build_array(json_build_object('method','oauth')),
      'app_metadata', json_build_object('providers', json_build_array('google'))
    )::text, true);
end;
$v707setup$;

do $v707a$
declare
  biz uuid := gen_random_uuid();
  br uuid := gen_random_uuid();
  svc_s uuid := gen_random_uuid();
  d_to date := current_date;
  d_from date := current_date - 10;
  anchor timestamptz := (d_from::timestamp + time '10:00') at time zone 'Asia/Singapore';

  s_ids uuid[] := array(select gen_random_uuid() from generate_series(1,6));
  c_ids uuid[] := array(select gen_random_uuid() from generate_series(1,6));

  g jsonb;
  g683 jsonb;
  svc_arr jsonb;
  row_s jsonb;
  i integer;
  sid uuid;
  v683_total integer;
begin
  insert into public.businesses (id, name, slug, enabled_modules) values
    (biz, 'ZZ v707 promo-population firm', 'zz-v707-promo-pop', array['dashboard','clients','sales','reports']);
  insert into public.branches (id, business_id, name, is_default, active) values
    (br, biz, 'ZZ v707 branch', true, true);
  insert into public.services (id, business_id, name, price_cents, duration_min) values
    (svc_s, biz, 'ZZ v707 policy service S', 5000, 30);

  -- ---------------------------------------------------------------------------
  -- The tenant policy override itself (db/migrations/20260717_frenly_v10_sale_policy.sql):
  -- app.on_sale_policy_snapshot() is a BEFORE INSERT trigger that ALWAYS overwrites whatever
  -- counts_as_revenue/counts_as_visit the caller supplies with app.sale_policy(business_id,kind)
  -- -- "the snapshot is the database's decision, not the client's" (v10.1). So the only way to
  -- get a kind='service' sale recorded with counts_as_revenue=false is a real sale_policies
  -- override row, exactly as a business owner would set via public.set_sale_policy -- not by
  -- passing the flags on the INSERT (that value would just be silently discarded and replaced
  -- with the default true/true).
  -- ---------------------------------------------------------------------------
  insert into public.sale_policies (business_id, kind, counts_as_revenue, counts_as_visit, note)
  values (biz, 'service', false, true, 'ZZ v707 fixture: comped/bundled service kind');

  -- ---------------------------------------------------------------------------
  -- Service S: 6 buyers, one sale each, POLICY sale kind -> counts_as_revenue=false,
  -- counts_as_visit=true (stamped by the trigger above, from the policy override just inserted).
  -- s1 discounted (ticket 4000c), s2-s6 full price (ticket 5000c).
  -- ---------------------------------------------------------------------------
  insert into public.clients (id, business_id, full_name)
    select s_ids[gs], biz, 'ZZ v707 S buyer ' || gs from generate_series(1,6) gs;

  for i in 1..6 loop
    sid := gen_random_uuid();
    insert into public.sales (id, business_id, branch_id, client_id, kind, amount_cents, occurred_at)
    values (sid, biz, br, s_ids[i], 'service', case when i = 1 then 4000 else 5000 end, anchor);
    -- counts_as_revenue/counts_as_visit deliberately NOT passed -- the BEFORE INSERT snapshot
    -- trigger stamps them from the policy row above regardless of what would have been supplied.
    insert into public.sale_items (business_id, sale_id, item_type, ref_id, qty, unit_cents, line_cents)
    values (biz, sid, 'service', svc_s, 1, 5000, 5000);
    if i = 1 then
      insert into public.sale_items (business_id, sale_id, item_type, ref_id, qty, unit_cents, line_cents)
      values (biz, sid, 'studio_discount', null, 1, -1000, -1000);
    end if;
  end loop;

  -- ---------------------------------------------------------------------------
  -- Control group: 6 unrelated clients, one ordinary (default-policy) sale each, no service
  -- line item -- populates value_association's non-buyer side.
  -- ---------------------------------------------------------------------------
  insert into public.clients (id, business_id, full_name)
    select c_ids[gs], biz, 'ZZ v707 control ' || gs from generate_series(1,6) gs;
  insert into public.sales (business_id, branch_id, client_id, kind, amount_cents,
                             occurred_at, counts_as_revenue, counts_as_visit)
  select biz, br, cid, 'retail', 3000, anchor, true, true from unnest(c_ids) cid;
  insert into public.sale_items (business_id, sale_id, item_type, ref_id, qty, unit_cents, line_cents)
  select biz, s.id, 'custom', null, 1, 3000, 3000
    from public.sales s where s.business_id = biz and s.client_id = any(c_ids) and s.kind = 'retail';

  -- ===============================================================================
  -- CALL: get_ci_service_intelligence_v1
  -- ===============================================================================
  g := public.get_ci_service_intelligence_v1(biz, d_from, d_to);
  svc_arr := g->'services';
  select s into row_s from jsonb_array_elements(svc_arr) s where (s->>'service_id')::uuid = svc_s;

  -- S0: the core regression -- pre-v707, this was null (service absent).
  if row_s is null then
    insert into _fail values ('S0', 'service S missing from services array -- the v707 fix (all_service_ids/visit_lines) did not take, or was reverted');
  end if;

  if row_s is not null then
    -- REVENUE figures must be null: S earns zero counted revenue under this policy.
    -- NOTE: `->` returns the jsonb literal `null`, which IS NOT SQL NULL (`'null'::jsonb IS NULL`
    -- is false) -- `->>` (text extraction) is what collapses a JSON null to SQL NULL, so that is
    -- what these checks must use.
    if row_s->>'buyers' is not null then
      insert into _fail values ('S-buyers-null', format('expected buyers=null (no revenue population), got %s', row_s->>'buyers'));
    end if;
    if row_s->>'revenue_cents' is not null then
      insert into _fail values ('S-revenue-null', format('expected revenue_cents=null, got %s', row_s->>'revenue_cents'));
    end if;
    if row_s->>'distribution' is not null then
      insert into _fail values ('S-distribution-null', format('expected distribution=null (no revenue population), got %s', row_s->>'distribution'));
    end if;

    -- VISIT figures (promotion_dependency) must be populated.
    if row_s->'promotion_dependency' is null then
      insert into _fail values ('S-promo-null', 'expected promotion_dependency populated from the visit population');
    else
      if (row_s->'promotion_dependency'->'rate'->>'numerator')::int <> 1 then
        insert into _fail values ('S-rate-num', format('got %s, expected 1', row_s->'promotion_dependency'->'rate'->>'numerator'));
      end if;
      if (row_s->'promotion_dependency'->'rate'->>'denominator')::int <> 6 then
        insert into _fail values ('S-rate-den', format('got %s, expected 6', row_s->'promotion_dependency'->'rate'->>'denominator'));
      end if;
      if (row_s->'promotion_dependency'->'rate'->>'pct')::numeric <> 16.7 then
        insert into _fail values ('S-rate-pct', format('got %s, expected 16.7', row_s->'promotion_dependency'->'rate'->>'pct'));
      end if;
      -- independent recompute of v683's own two thresholds against the same raw counts
      -- (same convention as v697's own fixture -- see header for why no single per-row number
      -- can be equated directly between a per-customer and a per-service reader).
      if not (round(100.0 * 1 / 6, 1) < 20 and row_s->'promotion_dependency'->>'dependency_class' = 'organic') then
        insert into _fail values ('S-class', format('got %s, expected organic under v683''s own <20 threshold',
                                                      row_s->'promotion_dependency'->>'dependency_class'));
      end if;
      if row_s->'promotion_dependency'->'evidence'->>'status' <> 'ok' then
        insert into _fail values ('S-evidence', 'expected evidence.status=ok at n=6 visit-buyers');
      end if;
      if row_s->'promotion_dependency'->'population_basis' is null then
        insert into _fail values ('S-basis-null', 'expected population_basis to be present on every service row');
      elsif (row_s->'promotion_dependency'->'population_basis'->>'revenue_fields' <> 'counts_as_revenue')
         or (row_s->'promotion_dependency'->'population_basis'->>'promotion_and_association' <> 'counts_as_visit') then
        insert into _fail values ('S-basis-shape', format('got %s', row_s->'promotion_dependency'->'population_basis'));
      end if;
    end if;

    -- value_association: buyers (the 6 S-buyers) vs non_buyers (the 6 control clients).
    if row_s->'value_association' is null then
      insert into _fail values ('S-va-null', 'expected value_association populated from the visit population');
    else
      if row_s->'value_association'->>'evidence_class' <> 'ASSOCIATION' then
        insert into _fail values ('S-va-class', format('got %s, expected ASSOCIATION', row_s->'value_association'->>'evidence_class'));
      end if;
      if row_s->'value_association'->'buyers'->'evidence'->>'status' <> 'ok' then
        insert into _fail values ('S-va-buyers-ev', 'expected buyer-side evidence.status=ok at n=6 (visit population, not revenue population)');
      end if;
      if (row_s->'value_association'->'buyers'->'median_ticket'->>'median')::numeric <> 5000 then
        insert into _fail values ('S-va-buyers-median', format('got %s, expected 5000 (median of [4000,5000,5000,5000,5000,5000])', row_s->'value_association'->'buyers'->'median_ticket'->>'median'));
      end if;
      if row_s->'value_association'->'non_buyers'->'evidence'->>'status' <> 'ok' then
        insert into _fail values ('S-va-nonbuyers-ev', 'expected non-buyer-side evidence.status=ok at n=6');
      end if;
      if (row_s->'value_association'->'non_buyers'->'median_ticket'->>'median')::numeric <> 3000 then
        insert into _fail values ('S-va-nonbuyers-median', format('got %s, expected 3000', row_s->'value_association'->'non_buyers'->'median_ticket'->>'median'));
      end if;
    end if;
  end if;

  -- ===============================================================================
  -- AGREEMENT: public.get_ci_discount_dependency_v1 (v683) classifies EVERY client with a
  -- counts_as_visit sale in the window, of ANY kind -- not just S buyers -- so its population
  -- here is all 12 real clients (the 6 policy-affected S buyers PLUS the 6 unrelated control
  -- clients, who also each have one counts_as_visit sale). v683 already read include_visit before
  -- v707 existed, so it was NEVER the one excluding the 6 policy-affected clients -- the point of
  -- this assertion is that v697 now agrees with it on WHICH ROWS are real visits (the 6 S buyers
  -- are counted by both readers), not that v683 changed. Asserting 12 here (rather than 6) is
  -- itself part of the proof: it shows the agreement is about the S buyers specifically being
  -- present in both readers' populations, not an artefact of a population that happens to contain
  -- only them.
  -- ===============================================================================
  g683 := public.get_ci_discount_dependency_v1(biz, d_from, d_to);
  v683_total := (g683->'classes'->'organic'->>'n')::int
              + (g683->'classes'->'discount_dependent'->>'n')::int
              + (g683->'classes'->'mixed'->>'n')::int
              + (g683->'classes'->'insufficient'->>'n')::int;
  if v683_total <> 12 then
    insert into _fail values ('AGREE-population', format(
      'v683 classified %s customers total, expected 12 (6 S buyers + 6 control clients) -- v683 no longer sees all the real visits it should',
      v683_total));
  end if;
  -- Every one of these 12 clients has exactly ONE window sale each, so v683's own
  -- "insufficient" rule for all_visits<3 puts every one of them in 'insufficient' -- a true,
  -- correct finding about v683's per-CUSTOMER grain (not a defect), asserted explicitly so a
  -- future reader does not mistake AGREE-population for a claim that v683 also says 'organic'.
  -- The two readers agree on WHICH ROWS are real visits (population membership); they classify
  -- at different grains (customer vs service) by design (see header).
  if (g683->'classes'->'insufficient'->>'n')::int <> 12 then
    insert into _fail values ('AGREE-insufficient-grain', format(
      'expected v683 to bucket all 12 single-visit customers as insufficient (all_visits<3), got %s',
      g683->'classes'->'insufficient'->>'n'));
  end if;

  -- ===============================================================================
  -- MUTATION CHECK: add a second discounted sale for s2 -> 2/6 = 33.3%, between the two cut
  -- points -- dependency_class must move from 'organic' to 'mixed', proving the number is
  -- recomputed live against the visit population, not memoised.
  -- ===============================================================================
  insert into public.sale_items (business_id, sale_id, item_type, ref_id, qty, unit_cents, line_cents)
  select biz, s.id, 'studio_discount', null, 1, -500, -500
    from public.sales s where s.business_id = biz and s.client_id = s_ids[2] and s.kind = 'service';

  g := public.get_ci_service_intelligence_v1(biz, d_from, d_to);
  select s into row_s from jsonb_array_elements(g->'services') s where (s->>'service_id')::uuid = svc_s;

  if row_s is null then
    insert into _fail values ('MUT-S0', 'service S missing from services array after mutation');
  else
    if (row_s->'promotion_dependency'->'rate'->>'numerator')::int <> 2 then
      insert into _fail values ('MUT-S-num', format('got %s, expected 2 after mutation', row_s->'promotion_dependency'->'rate'->>'numerator'));
    end if;
    if (row_s->'promotion_dependency'->'rate'->>'pct')::numeric <> 33.3 then
      insert into _fail values ('MUT-S-pct', format('got %s, expected 33.3 after mutation', row_s->'promotion_dependency'->'rate'->>'pct'));
    end if;
    if row_s->'promotion_dependency'->>'dependency_class' <> 'mixed' then
      insert into _fail values ('MUT-S-class', format('got %s, expected mixed after mutation (2/6=33.3%%, between 20 and 60)', row_s->'promotion_dependency'->>'dependency_class'));
    end if;
  end if;
end
$v707a$;

select case when count(*)=0 then 'PASS — v707 promotion_dependency/value_association read the visit population'
            else 'FAIL' end as verdict,
       count(*) as failures from _fail;
select k, v from _fail order by k, v;

do $verdict$
declare n integer; d text;
begin
  select count(*), string_agg(format('%s: %s', f.k, f.v), E'\n  ' order by f.k, f.v)
    into n, d from _fail f;
  if n > 0 then raise exception 'v707: % assertion(s) failed:%  %', n, E'\n', d; end if;
end
$verdict$;

rollback;
