-- EXECUTED regression fixture for nestly_v697 -- per-service promotion dependency and value
-- association (check 38) on public.get_ci_service_intelligence_v1. Above the v422 watermark:
-- n/a in the baseline phase, gated on the migrated run (the function itself, and the
-- 'studio_discount' item_type it reads, postdate v422).
--
-- ONE business ("biz"), one branch, three services:
--
--   P: 6 buyers, one sale each. Service line is 10000c for every buyer; 4 of the 6 sales ALSO
--      carry a studio_discount line of -2000c (so their ticket is 8000c, matching the 2
--      full-price buyers' own 10000c list price minus nothing -- see below), 2 are full price.
--      HAND-COMPUTED: all_sales=6, discounted_sales=4 -> rate.pct = round(100*4/6,1) = 66.7.
--      all_revenue_cents=60000, discounted_revenue_cents=40000 -> discounted_revenue_share.pct
--      = 66.7 (same ratio; service price is uniform across discounted and full-price buyers, so
--      the two rates coincide in this fixture by construction -- that is a property of the DATA,
--      not of the two metrics, which read different numerator/denominator pairs). 66.7 >= 60 ->
--      dependency_class = 'dependent' under v683's own cut point (see get_ci_discount_
--      dependency_v1's `classified` CTE, reused here at a per-service grain -- the fixture
--      independently recomputes the same 20/60 thresholds against the same raw counts below and
--      asserts EXACT agreement with the reader's own verdict, since v683 itself classifies
--      customers, not services, and so has no per-service number to compare against directly).
--   Q: 6 buyers, one sale each, service line 4000c, ZERO discounted -> rate.pct = 0.0 -> organic
--      (0 < 20).
--   R: 2 buyers (below the floor of 5) -> evidence.status='insufficient'; rate.pct MUST be null
--      while numerator/denominator (0/2) are still reported; dependency_class MUST be null.
--
-- VALUE ASSOCIATION (service P only): buyers are p1..p6 (ticket = the SALE's total, i.e.
-- 10000c-2000c=8000c for the 4 discounted buyers, 10000c for the 2 full-price buyers --
-- 6 values [8000,8000,8000,8000,10000,10000], median = avg(3rd,4th) = 8000c EXACTLY). Non-buyers
-- are q1..q6 and r1..r2 (8 clients), each ticket EXACTLY 4000c -> median = 4000c EXACTLY. Two of
-- the P buyers (p1,p2) and three of the non-buyers (q1,q2,q3) each get a second, unrelated
-- window sale so repeat-visit rate is hand-computable: buyers repeat = round(100*2/6,1) = 33.3;
-- non-buyers repeat = round(100*3/8,1) = 37.5. evidence_class must be 'ASSOCIATION' and the
-- string 'CAUSAL' must not appear anywhere in the whole payload.
--
-- INERT POISON: a client whose ONLY service-P sale is later reversed, and a synthetic client
-- (is_synthetic=true) who also buys service P -- both must be invisible everywhere (buyers stay
-- 6, tickets stay [8000x4,10000x2], non-buyer population stays 8), proving
-- app.analytics_sale_class_v1's reversal + synthetic-client exclusions are actually applied by
-- the new CTEs, not just by the pre-existing ones.
--
-- MUTATION CHECK: two of Q's six sales are given a studio_discount line after the first call
-- (2/6 = 33.3%, between the two cut points) and the reader is called again -- Q's
-- dependency_class MUST flip from 'organic' to 'mixed' and its rate.pct from 0.0 to 33.3,
-- proving the number is recomputed live, not memoised from the first call.

\set ON_ERROR_STOP on
begin;
create temp table _fail(k text, v text) on commit drop;

do $v697setup$
declare
  u_sa uuid := '00000000-0000-4000-8000-000000697eee';
begin
  insert into auth.users (id, email) values (u_sa, 'zz-v697-sa@example.test')
    on conflict (id) do nothing;
  insert into public.super_admins (user_id, email) values (u_sa, 'zz-v697-sa@example.test')
    on conflict do nothing;
  perform set_config('request.jwt.claims', json_build_object(
      'sub', u_sa, 'role','authenticated',
      'amr', json_build_array(json_build_object('method','oauth')),
      'app_metadata', json_build_object('providers', json_build_array('google'))
    )::text, true);
end;
$v697setup$;

do $v697a$
declare
  biz uuid := gen_random_uuid();
  br uuid := gen_random_uuid();
  svc_p uuid := gen_random_uuid();
  svc_q uuid := gen_random_uuid();
  svc_r uuid := gen_random_uuid();
  d_to date := current_date;
  d_from date := current_date - 10;
  anchor timestamptz := (d_from::timestamp + time '10:00') at time zone 'Asia/Singapore';
  repeat_anchor timestamptz := ((d_from+1)::timestamp + time '10:00') at time zone 'Asia/Singapore';

  p_ids uuid[] := array(select gen_random_uuid() from generate_series(1,6));
  q_ids uuid[] := array(select gen_random_uuid() from generate_series(1,6));
  r_ids uuid[] := array(select gen_random_uuid() from generate_series(1,2));
  poison_rev_client uuid := gen_random_uuid();
  poison_syn_client uuid := gen_random_uuid();

  poison_rev_sale uuid := gen_random_uuid();
  poison_rev_reversal uuid := gen_random_uuid();

  g jsonb;
  svc_arr jsonb;
  row_p jsonb;
  row_q jsonb;
  row_r jsonb;
  i integer;
  sid uuid;
begin
  insert into public.businesses (id, name, slug, enabled_modules) values
    (biz, 'ZZ v697 promo firm', 'zz-v697-promo', array['dashboard','clients','sales','reports']);
  insert into public.branches (id, business_id, name, is_default, active) values
    (br, biz, 'ZZ v697 branch', true, true);
  insert into public.services (id, business_id, name, price_cents, duration_min) values
    (svc_p, biz, 'ZZ v697 service P', 10000, 30),
    (svc_q, biz, 'ZZ v697 service Q', 4000, 30),
    (svc_r, biz, 'ZZ v697 service R', 4000, 30);

  -- ---------------------------------------------------------------------------
  -- Service P: 6 buyers, one sale each. p1-p4 discounted (ticket 8000c), p5-p6 full
  -- price (ticket 10000c). p1,p2 additionally get a second, unrelated window sale
  -- (item_type='custom') so they count as repeat customers on the buyer side.
  -- ---------------------------------------------------------------------------
  insert into public.clients (id, business_id, full_name)
    select p_ids[gs], biz, 'ZZ v697 P buyer ' || gs from generate_series(1,6) gs;

  for i in 1..6 loop
    sid := gen_random_uuid();
    insert into public.sales (id, business_id, branch_id, client_id, kind, amount_cents,
                               occurred_at, counts_as_revenue, counts_as_visit)
    values (sid, biz, br, p_ids[i], 'service', case when i <= 4 then 8000 else 10000 end,
            anchor, true, true);
    insert into public.sale_items (business_id, sale_id, item_type, ref_id, qty, unit_cents, line_cents)
    values (biz, sid, 'service', svc_p, 1, 10000, 10000);
    if i <= 4 then
      insert into public.sale_items (business_id, sale_id, item_type, ref_id, qty, unit_cents, line_cents)
      values (biz, sid, 'studio_discount', null, 1, -2000, -2000);
    end if;
  end loop;

  -- p1, p2 repeat sales (any item type, unrelated to any of P/Q/R) -- push them to n_sales=2.
  insert into public.sales (business_id, branch_id, client_id, kind, amount_cents,
                             occurred_at, counts_as_revenue, counts_as_visit)
  values (biz, br, p_ids[1], 'retail', 500, repeat_anchor, true, true),
         (biz, br, p_ids[2], 'retail', 500, repeat_anchor, true, true);
  insert into public.sale_items (business_id, sale_id, item_type, ref_id, qty, unit_cents, line_cents)
  select biz, s.id, 'custom', null, 1, 500, 500
    from public.sales s
   where s.business_id = biz and s.client_id in (p_ids[1], p_ids[2])
     and s.occurred_at = repeat_anchor and s.kind = 'retail';

  -- ---------------------------------------------------------------------------
  -- Service Q: 6 buyers, one sale each, no discount. q1,q2,q3 get a second, unrelated
  -- window sale so they count as repeat customers on the non-buyer side.
  -- ---------------------------------------------------------------------------
  insert into public.clients (id, business_id, full_name)
    select q_ids[gs], biz, 'ZZ v697 Q buyer ' || gs from generate_series(1,6) gs;

  insert into public.sales (business_id, branch_id, client_id, kind, amount_cents,
                             occurred_at, counts_as_revenue, counts_as_visit)
  select biz, br, qid, 'service', 4000, anchor, true, true from unnest(q_ids) qid;
  insert into public.sale_items (business_id, sale_id, item_type, ref_id, qty, unit_cents, line_cents)
  select biz, s.id, 'service', svc_q, 1, 4000, 4000
    from public.sales s where s.business_id = biz and s.client_id = any(q_ids) and s.kind = 'service';

  insert into public.sales (business_id, branch_id, client_id, kind, amount_cents,
                             occurred_at, counts_as_revenue, counts_as_visit)
  select biz, br, qid, 'retail', 500, repeat_anchor, true, true
    from unnest(q_ids[1:3]) qid;
  insert into public.sale_items (business_id, sale_id, item_type, ref_id, qty, unit_cents, line_cents)
  select biz, s.id, 'custom', null, 1, 500, 500
    from public.sales s
   where s.business_id = biz and s.client_id = any(q_ids[1:3])
     and s.occurred_at = repeat_anchor and s.kind = 'retail';

  -- ---------------------------------------------------------------------------
  -- Service R: 2 buyers, one sale each, no discount -- below the floor of 5.
  -- ---------------------------------------------------------------------------
  insert into public.clients (id, business_id, full_name)
    select r_ids[gs], biz, 'ZZ v697 R buyer ' || gs from generate_series(1,2) gs;
  insert into public.sales (business_id, branch_id, client_id, kind, amount_cents,
                             occurred_at, counts_as_revenue, counts_as_visit)
  select biz, br, rid, 'service', 4000, anchor, true, true from unnest(r_ids) rid;
  insert into public.sale_items (business_id, sale_id, item_type, ref_id, qty, unit_cents, line_cents)
  select biz, s.id, 'service', svc_r, 1, 4000, 4000
    from public.sales s where s.business_id = biz and s.client_id = any(r_ids) and s.kind = 'service';

  -- ---------------------------------------------------------------------------
  -- Poison 1: a client whose only P sale is fully reversed. If wrongly counted this
  -- would make P's buyers=7, all_sales=7, and shift every ticket/median.
  -- ---------------------------------------------------------------------------
  insert into public.clients (id, business_id, full_name)
  values (poison_rev_client, biz, 'ZZ v697 poison reversed');
  insert into public.sales (id, business_id, branch_id, client_id, kind, amount_cents,
                             occurred_at, counts_as_revenue, counts_as_visit)
  values (poison_rev_sale, biz, br, poison_rev_client, 'service', 999999, anchor, true, true);
  insert into public.sale_items (business_id, sale_id, item_type, ref_id, qty, unit_cents, line_cents)
  values (biz, poison_rev_sale, 'service', svc_p, 1, 999999, 999999);
  perform set_config('app.sale_reversal_insert_id', poison_rev_reversal::text, true);
  perform set_config('app.sale_reversal_original_id', poison_rev_sale::text, true);
  insert into public.sales (id, business_id, branch_id, client_id, kind, amount_cents,
                             occurred_at, counts_as_revenue, counts_as_visit,
                             reversal_of, reversal_reason, reversal_actor, reversal_idempotency_key)
  values (poison_rev_reversal, biz, br, poison_rev_client, 'service', -999999, anchor, true, true,
          poison_rev_sale, 'ZZ v697 fixture reversal',
          '00000000-0000-4000-8000-000000697eee', gen_random_uuid());
  perform set_config('app.sale_reversal_insert_id', '', true);
  perform set_config('app.sale_reversal_original_id', '', true);

  -- ---------------------------------------------------------------------------
  -- Poison 2: a synthetic client buying service P. If wrongly counted this would
  -- also make P's buyers=7 (or 8, alongside poison 1) and shift the tickets.
  -- ---------------------------------------------------------------------------
  insert into public.clients (id, business_id, full_name, is_synthetic)
  values (poison_syn_client, biz, 'ZZ v697 poison synthetic', true);
  insert into public.sales (business_id, branch_id, client_id, kind, amount_cents,
                             occurred_at, counts_as_revenue, counts_as_visit)
  values (biz, br, poison_syn_client, 'service', 888888, anchor, true, true);
  insert into public.sale_items (business_id, sale_id, item_type, ref_id, qty, unit_cents, line_cents)
  select biz, s.id, 'service', svc_p, 1, 888888, 888888
    from public.sales s where s.business_id = biz and s.client_id = poison_syn_client;

  -- ===============================================================================
  -- CALL 1
  -- ===============================================================================
  g := public.get_ci_service_intelligence_v1(biz, d_from, d_to);
  svc_arr := g->'services';

  select s into row_p from jsonb_array_elements(svc_arr) s where (s->>'service_id')::uuid = svc_p;
  select s into row_q from jsonb_array_elements(svc_arr) s where (s->>'service_id')::uuid = svc_q;
  select s into row_r from jsonb_array_elements(svc_arr) s where (s->>'service_id')::uuid = svc_r;

  if row_p is null then insert into _fail values ('P0','service P missing from services array'); end if;
  if row_q is null then insert into _fail values ('Q0','service Q missing from services array'); end if;
  if row_r is null then insert into _fail values ('R0','service R missing from services array'); end if;

  -- ------------------------------------------------------------- P: promotion_dependency
  if row_p is not null then
    if (row_p->'buyers')::int <> 6 then
      insert into _fail values ('P-buyers', format('P buyers = %s, expected 6 (poison inert check)', row_p->'buyers'));
    end if;
    if (row_p->'promotion_dependency'->'rate'->>'numerator')::int <> 4 then
      insert into _fail values ('P-rate-num', format('got %s, expected 4', row_p->'promotion_dependency'->'rate'->>'numerator'));
    end if;
    if (row_p->'promotion_dependency'->'rate'->>'denominator')::int <> 6 then
      insert into _fail values ('P-rate-den', format('got %s, expected 6', row_p->'promotion_dependency'->'rate'->>'denominator'));
    end if;
    if (row_p->'promotion_dependency'->'rate'->>'pct')::numeric <> 66.7 then
      insert into _fail values ('P-rate-pct', format('got %s, expected 66.7', row_p->'promotion_dependency'->'rate'->>'pct'));
    end if;
    if (row_p->'promotion_dependency'->'discounted_revenue_share'->>'numerator')::bigint <> 40000 then
      insert into _fail values ('P-rev-num', format('got %s, expected 40000', row_p->'promotion_dependency'->'discounted_revenue_share'->>'numerator'));
    end if;
    if (row_p->'promotion_dependency'->'discounted_revenue_share'->>'denominator')::bigint <> 60000 then
      insert into _fail values ('P-rev-den', format('got %s, expected 60000', row_p->'promotion_dependency'->'discounted_revenue_share'->>'denominator'));
    end if;
    if (row_p->'promotion_dependency'->'discounted_revenue_share'->>'pct')::numeric <> 66.7 then
      insert into _fail values ('P-rev-pct', format('got %s, expected 66.7', row_p->'promotion_dependency'->'discounted_revenue_share'->>'pct'));
    end if;
    -- independent recompute of v683's own two thresholds against the same raw counts.
    if not (
      (round(100.0 * 4 / 6, 1) >= 60 and row_p->'promotion_dependency'->>'dependency_class' = 'dependent')
    ) then
      insert into _fail values ('P-class', format('got %s, expected dependent under v683''s own >=60 threshold',
                                                    row_p->'promotion_dependency'->>'dependency_class'));
    end if;
    if row_p->'promotion_dependency'->'evidence'->>'status' <> 'ok' then
      insert into _fail values ('P-evidence', 'expected evidence.status=ok at n=6 buyers');
    end if;
  end if;

  -- ------------------------------------------------------------- Q: promotion_dependency (organic)
  if row_q is not null then
    if (row_q->'promotion_dependency'->'rate'->>'numerator')::int <> 0 then
      insert into _fail values ('Q-rate-num', format('got %s, expected 0', row_q->'promotion_dependency'->'rate'->>'numerator'));
    end if;
    if (row_q->'promotion_dependency'->'rate'->>'denominator')::int <> 6 then
      insert into _fail values ('Q-rate-den', format('got %s, expected 6', row_q->'promotion_dependency'->'rate'->>'denominator'));
    end if;
    if (row_q->'promotion_dependency'->'rate'->>'pct')::numeric <> 0.0 then
      insert into _fail values ('Q-rate-pct', format('got %s, expected 0.0', row_q->'promotion_dependency'->'rate'->>'pct'));
    end if;
    if not (round(100.0 * 0 / 6, 1) < 20 and row_q->'promotion_dependency'->>'dependency_class' = 'organic') then
      insert into _fail values ('Q-class', format('got %s, expected organic under v683''s own <20 threshold',
                                                    row_q->'promotion_dependency'->>'dependency_class'));
    end if;
  end if;

  -- ------------------------------------------------------------- R: below floor
  if row_r is not null then
    if (row_r->'buyers')::int <> 2 then
      insert into _fail values ('R-buyers', format('got %s, expected 2', row_r->'buyers'));
    end if;
    if row_r->'promotion_dependency'->'evidence'->>'status' <> 'insufficient' then
      insert into _fail values ('R-evidence', 'expected evidence.status=insufficient at n=2 buyers (floor 5)');
    end if;
    if row_r->'promotion_dependency'->'rate'->>'pct' is not null then
      insert into _fail values ('R-rate-pct-null', format('expected pct null below floor, got %s', row_r->'promotion_dependency'->'rate'->>'pct'));
    end if;
    if (row_r->'promotion_dependency'->'rate'->>'numerator')::int <> 0
       or (row_r->'promotion_dependency'->'rate'->>'denominator')::int <> 2 then
      insert into _fail values ('R-rate-counts', 'expected raw counts (0/2) kept even though pct is null');
    end if;
    if row_r->'promotion_dependency'->>'dependency_class' is not null then
      insert into _fail values ('R-class-null', format('expected null dependency_class below floor, got %s', row_r->'promotion_dependency'->>'dependency_class'));
    end if;
    -- both-sides floor gate on value_association too: R's buyer side (n=2) must also read
    -- insufficient even though its non-buyer side (everyone else) clears the floor easily.
    if row_r->'value_association'->'buyers'->'evidence'->>'status' <> 'insufficient' then
      insert into _fail values ('R-va-buyers', 'expected R buyer-side evidence insufficient at n=2');
    end if;
    if row_r->'value_association'->>'difference_note' <> 'insufficient sample on one or both sides to compare' then
      insert into _fail values ('R-va-note', format('got %s', row_r->'value_association'->>'difference_note'));
    end if;
  end if;

  -- ------------------------------------------------------------- P: value_association
  if row_p is not null then
    if row_p->'value_association'->>'evidence_class' <> 'ASSOCIATION' then
      insert into _fail values ('P-va-class', format('got %s, expected ASSOCIATION', row_p->'value_association'->>'evidence_class'));
    end if;
    if row_p->'value_association'->'buyers'->'evidence'->>'status' <> 'ok' then
      insert into _fail values ('P-va-buyers-ev', 'expected buyer-side evidence.status=ok at n=6');
    end if;
    if (row_p->'value_association'->'buyers'->'median_ticket'->>'median')::numeric <> 8000 then
      insert into _fail values ('P-va-buyers-median', format('got %s, expected 8000', row_p->'value_association'->'buyers'->'median_ticket'->>'median'));
    end if;
    if (row_p->'value_association'->'buyers'->'repeat_visit_rate'->>'numerator')::int <> 2
       or (row_p->'value_association'->'buyers'->'repeat_visit_rate'->>'denominator')::int <> 6 then
      insert into _fail values ('P-va-buyers-repeat-counts', 'expected 2/6 repeat customers on the buyer side');
    end if;
    if (row_p->'value_association'->'buyers'->'repeat_visit_rate'->>'pct')::numeric <> 33.3 then
      insert into _fail values ('P-va-buyers-repeat-pct', format('got %s, expected 33.3', row_p->'value_association'->'buyers'->'repeat_visit_rate'->>'pct'));
    end if;
    if row_p->'value_association'->'non_buyers'->'evidence'->>'status' <> 'ok' then
      insert into _fail values ('P-va-nonbuyers-ev', 'expected non-buyer-side evidence.status=ok at n=8');
    end if;
    if (row_p->'value_association'->'non_buyers'->'median_ticket'->>'median')::numeric <> 4000 then
      insert into _fail values ('P-va-nonbuyers-median', format('got %s, expected 4000', row_p->'value_association'->'non_buyers'->'median_ticket'->>'median'));
    end if;
    if (row_p->'value_association'->'non_buyers'->'repeat_visit_rate'->>'numerator')::int <> 3
       or (row_p->'value_association'->'non_buyers'->'repeat_visit_rate'->>'denominator')::int <> 8 then
      insert into _fail values ('P-va-nonbuyers-repeat-counts', 'expected 3/8 repeat customers on the non-buyer side');
    end if;
    if (row_p->'value_association'->'non_buyers'->'repeat_visit_rate'->>'pct')::numeric <> 37.5 then
      insert into _fail values ('P-va-nonbuyers-repeat-pct', format('got %s, expected 37.5', row_p->'value_association'->'non_buyers'->'repeat_visit_rate'->>'pct'));
    end if;
    if row_p->'value_association'->>'difference_note' is null
       or position('association' in lower(row_p->'value_association'->>'difference_note')) = 0 then
      insert into _fail values ('P-va-note', 'expected difference_note to phrase the comparison as an association');
    end if;
  end if;

  -- ------------------------------------------------------------- no 'CAUSAL' anywhere
  -- Case-SENSITIVE, quoted-token search: the enum value is always upper-case 'CAUSAL' when it
  -- appears as a JSON string; the prose disclaimer legitimately uses the lower-case word
  -- "causal" ("not a causal effect of the service"), so an upper()'d substring search would
  -- flag its own compliant disclaimer as a violation.
  if position('"CAUSAL"' in g::text) > 0 then
    insert into _fail values ('NO-CAUSAL', 'the enum value CAUSAL must never appear in this payload');
  end if;

  -- ===============================================================================
  -- MUTATION CHECK: flip 2 of Q's 6 sales to discounted (2/6 = 33.3%, between the two
  -- cut points) -- dependency_class must move from 'organic' to 'mixed'.
  -- ===============================================================================
  insert into public.sale_items (business_id, sale_id, item_type, ref_id, qty, unit_cents, line_cents)
  select biz, s.id, 'studio_discount', null, 1, -500, -500
    from public.sales s
   where s.business_id = biz and s.client_id = any(q_ids[1:2]) and s.kind = 'service';

  g := public.get_ci_service_intelligence_v1(biz, d_from, d_to);
  select s into row_q from jsonb_array_elements(g->'services') s where (s->>'service_id')::uuid = svc_q;

  if row_q is null then
    insert into _fail values ('MUT-Q0','service Q missing from services array after mutation');
  else
    if (row_q->'promotion_dependency'->'rate'->>'numerator')::int <> 2 then
      insert into _fail values ('MUT-Q-num', format('got %s, expected 2 after mutation', row_q->'promotion_dependency'->'rate'->>'numerator'));
    end if;
    if (row_q->'promotion_dependency'->'rate'->>'pct')::numeric <> 33.3 then
      insert into _fail values ('MUT-Q-pct', format('got %s, expected 33.3 after mutation', row_q->'promotion_dependency'->'rate'->>'pct'));
    end if;
    if row_q->'promotion_dependency'->>'dependency_class' <> 'mixed' then
      insert into _fail values ('MUT-Q-class', format('got %s, expected mixed after mutation (2/6=33.3%%, between 20 and 60)', row_q->'promotion_dependency'->>'dependency_class'));
    end if;
  end if;
end
$v697a$;

select case when count(*)=0 then 'PASS — v697 per-service promotion dependency and value association hold'
            else 'FAIL' end as verdict,
       count(*) as failures from _fail;
select k, v from _fail order by k, v;

do $verdict$
declare n integer; d text;
begin
  select count(*), string_agg(format('%s: %s', f.k, f.v), E'\n  ' order by f.k, f.v)
    into n, d from _fail f;
  if n > 0 then raise exception 'v697: % assertion(s) failed:%  %', n, E'\n', d; end if;
end
$verdict$;

rollback;
