-- nestly_v869 rollback suite — the two discount readers report the discounts actually given.
--
-- Run inside a transaction against production and ROLLED BACK. Impersonates AhXiang's real
-- owner (the tenant that gave SGD 2,938 in tier discounts and read $0.00) and Cubbly SPA's.
-- Every expected figure is recomputed here from public.benefit_fulfilments, independently of
-- the function under test.

\set ON_ERROR_STOP on

begin;

do $suite$
declare
  ah  constant uuid := '33773caa-6d51-4cf2-9ad6-b83f015759e6';  -- AhXiang
  cb  constant uuid := '8492e8d6-8888-4383-ada0-7e1ed69f0caa';  -- Cubbly SPA
  owner_uid uuid;
  rep jsonb; fact jsonb; expected bigint; got bigint; n integer := 0;
begin
  -- A1: the report reads the registry, not Studio provenance
  n := n + 1;
  if position('public.benefit_fulfilments bf' in pg_get_functiondef('public.get_checkout_discount_report(uuid,date,date)'::regprocedure)) = 0 then
    raise exception 'A% failed: get_checkout_discount_report does not read benefit_fulfilments', n;
  end if;

  -- A2: AhXiang, all time — grand total equals the independent registry sum
  select s.user_id into owner_uid from public.staff s where s.business_id = ah and s.role = 'owner' and s.user_id is not null limit 1;
  perform set_config('request.jwt.claims', json_build_object('sub', owner_uid, 'role', 'authenticated')::text, true);
  rep := public.get_checkout_discount_report(ah, '2026-01-01', app.sg_today());
  select coalesce(sum(bf.face_value_cents), 0) into expected
    from public.benefit_fulfilments bf
    join public.sales s on s.id = bf.detail_ref and s.business_id = bf.business_id
    cross join lateral app.analytics_sale_class_v1(s) sc
   where bf.business_id = ah and bf.fulfilment_kind = 'checkout_discount'
     and bf.reverses_fulfilment_id is null
     and not exists (select 1 from public.benefit_fulfilments r where r.reverses_fulfilment_id = bf.id)
     and sc.include_revenue and not sc.is_synthetic_client;
  got := (rep #>> '{grand_totals,discount_cents}')::bigint;
  n := n + 1;
  if got <> expected then raise exception 'A% failed: AhXiang discount total % <> registry %', n, got, expected; end if;
  n := n + 1;
  if expected = 0 then raise exception 'A% failed: negative control — AhXiang is expected to have given discounts', n; end if;

  -- A3: the per-day rows sum to the grand total
  select coalesce(sum((r->>'discount_cents')::bigint), 0) into got from jsonb_array_elements(rep->'by_day_rule') r;
  n := n + 1;
  if got <> expected then raise exception 'A% failed: by_day_rule sums to % not %', n, got, expected; end if;

  -- A4: a rule-less discount is named by its benefit, never left as a bare null
  n := n + 1;
  if exists (select 1 from jsonb_array_elements(rep->'by_day_rule') r where coalesce(r->>'rule_name','') = '') then
    raise exception 'A% failed: a by_day_rule row has no rule_name', n;
  end if;

  -- A5: the owner brief states the total whenever any discount exists (Cubbly: 5 lines)
  fact := app.owner_brief_fact_discounts_v828(cb);
  select coalesce(sum(bf.face_value_cents), 0) into expected
    from public.benefit_fulfilments bf
    join public.sales s on s.id = bf.detail_ref and s.business_id = bf.business_id
    cross join lateral app.analytics_sale_class_v1(s) sc
   where bf.business_id = cb and bf.fulfilment_kind = 'checkout_discount'
     and bf.reverses_fulfilment_id is null
     and not exists (select 1 from public.benefit_fulfilments r where r.reverses_fulfilment_id = bf.id)
     and sc.is_reversal = false and not sc.is_synthetic_client
     and not exists (select 1 from public.sales rv where rv.business_id = s.business_id and rv.reversal_of = s.id)
     and s.occurred_at >= ((app.sg_today() - 56)::timestamp at time zone 'Asia/Singapore')
     and s.occurred_at <  ((app.sg_today())::timestamp at time zone 'Asia/Singapore');
  n := n + 1;
  if (fact->>'status') <> 'ok' then raise exception 'A% failed: brief discounts fact status %', n, fact->>'status'; end if;
  n := n + 1;
  if (fact->>'discount_lines_seen')::int > 0 and (fact->>'total_discount_cents') is null then
    raise exception 'A% failed: brief withholds the total although % lines exist', n, fact->>'discount_lines_seen';
  end if;
  n := n + 1;
  if (fact->>'discount_lines_seen')::int > 0 and (fact->>'total_discount_cents')::bigint <> expected then
    raise exception 'A% failed: brief total % <> registry %', n, fact->>'total_discount_cents', expected;
  end if;

  raise notice 'nestly_v869 suite: % assertions passed', n;
end
$suite$;

rollback;
