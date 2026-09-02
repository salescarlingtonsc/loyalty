-- Rollback-only v677 acceptance suite — a reversed sale is not a visit (audit F061).
--
-- The scenario is the real one from the finding: a staff member records a sale at the
-- till and immediately reverses it. Nothing is simulated — the sale goes through
-- public.record_sale_by_phone (the till's own RPC) as the business owner, and the
-- reversal through public.reverse_sale_fast_v84 (the Sales screen's own RPC).
--
-- CANONICAL is computed inline, from the predicate the ~40 correct readers already use
-- (nestly_v244: a reversal row is never a visit, and an original is discounted once a
-- reversal referencing it exists inside the counts_as_visit set). It is deliberately NOT
-- app.client_qualifying_visits_v677 — a suite that asked the new helper whether the new
-- helper is right would prove nothing.
--
-- SECTION 0 — the fixture: a real tenant on tier_basis 'visits' with Tiers running and a
--   verified customer link, so all four readers can actually be called as their own
--   principal.
--
-- SECTION 1 — baseline. All four readers agree with CANONICAL before anything happens.
--   S1-T1  app.tier_resolve_v426 metric
--   S1-T2  public.lookup_client_by_phone visits
--   S1-T3  app.v666_till_customer_card visits
--   S1-T4  public.customer_get_business_presentation_v95 tier.current.metric
--
-- SECTION 2 — sensitivity. One real till sale moves all four by exactly +1. Without this
--   the section-3 assertions could pass on a probe that reads nothing.
--
-- SECTION 3 — the fix. After the real reversal all four are back to the baseline, i.e.
--   the refund netted to zero. Before v677 every one of them read baseline + 2, which
--   S3-T0 pins by showing the raw un-netted count IS baseline + 2 — the two rows are
--   there, the readers just stop counting them.
--
-- SECTION 4 — the tier engine. The customer is not promoted by the reversal, and no
--   tier_transition_events row is keyed to the reversal sale.
--
-- Run against production; everything is inside one transaction that rolls back.
begin;
create temporary table v677_evidence(test text, detail text) on commit drop;

do $v677$
declare
  v_business   uuid;
  v_client     uuid;
  v_customer   uuid;   -- the customer's auth user, from the verified link
  v_owner      uuid;   -- the owner's auth user, from staff
  v_branch     uuid;
  v_phone      text;
  v_locale     text := 'en';
  v_sale       uuid;
  v_reversal   uuid;
  v_res        json;
  v_pres       jsonb;
  v_tier       jsonb;
  v_base_tier  text;
  v_canonical  integer;
  v_baseline   integer;
  v_raw        integer;
  v_n          integer;
  v_count      integer;
  v_card       jsonb;
  v_metric_j   jsonb;
begin
  -- ---------------------------------------------------------------- SECTION 0
  -- A tenant whose tier metric IS the visit count, with Tiers switched on, an active
  -- branch, an owner who can sell and refund, and a customer whose app session can be
  -- impersonated through a verified link. Ordered so the choice is deterministic.
  select l.business_id, l.client_id, l.auth_user_id, c.phone_norm
    into v_business, v_client, v_customer, v_phone
    from public.customer_links l
    join public.clients c
      on c.id = l.client_id and c.business_id = l.business_id
    join public.customer_identities ci
      on ci.id = l.identity_id and ci.auth_user_id = l.auth_user_id and ci.status = 'active'
    left join public.loyalty_programs lp on lp.business_id = l.business_id
   where l.state = 'verified'
     and coalesce(lp.tier_basis, 'visits') = 'visits'
     and c.phone_norm is not null
     and app.programme_running_v371(l.business_id, 'tiers')
     and exists (select 1 from public.branches b
                  where b.business_id = l.business_id and b.active)
     and exists (select 1 from public.staff s
                  where s.business_id = l.business_id and s.role = 'owner'
                    and s.active and s.user_id is not null)
   order by l.business_id, l.client_id
   limit 1;
  if v_business is null then
    raise exception 'FIXTURE: no tenant on tier_basis=visits with Tiers running and a verified customer link';
  end if;

  select s.user_id into v_owner from public.staff s
   where s.business_id = v_business and s.role = 'owner' and s.active and s.user_id is not null
   order by s.id limit 1;
  select b.id into v_branch from public.branches b
   where b.business_id = v_business and b.active
   order by b.is_default desc, b.created_at, b.id limit 1;

  insert into v677_evidence values('S0','business '||v_business||', client '||v_client);

  -- ---------------------------------------------------------------- CANONICAL
  -- The estate's predicate, written out here rather than borrowed from the helper.
  with visit_rows as (
    select s.id, s.reversal_of from public.sales s
     where s.business_id = v_business and s.client_id = v_client and s.counts_as_visit
  )
  select count(*)::integer into v_canonical
    from visit_rows v
   where v.reversal_of is null
     and not exists (select 1 from visit_rows r where r.reversal_of = v.id);
  v_baseline := v_canonical;
  insert into v677_evidence values('S0 canonical','baseline qualifying visits = '||v_baseline);

  -- ---------------------------------------------------------------- SECTION 1
  -- Read as the owner: the two till readers and the resolver.
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_owner, 'role', 'authenticated')::text, true);

  v_tier := app.tier_resolve_v426(v_business, v_client);
  if (v_tier->>'basis') <> 'visits' then
    raise exception 'FIXTURE: resolver basis is %, expected visits', v_tier->>'basis'; end if;
  v_base_tier := coalesce(v_tier#>>'{current,name}', '(none)');
  if (v_tier->>'metric')::numeric <> v_canonical then
    raise exception 'S1-T1 FAIL: tier_resolve_v426 metric % against canonical %',
      v_tier->>'metric', v_canonical; end if;
  insert into v677_evidence values('S1-T1','tier_resolve_v426 metric = '||v_canonical||', tier '||v_base_tier);

  v_res := public.lookup_client_by_phone(v_business, v_phone);
  if (v_res->>'status') <> 'found' then
    raise exception 'FIXTURE: lookup_client_by_phone returned %', v_res->>'status'; end if;
  if (v_res->>'visits')::integer <> v_canonical then
    raise exception 'S1-T2 FAIL: lookup_client_by_phone visits % against canonical %',
      v_res->>'visits', v_canonical; end if;
  insert into v677_evidence values('S1-T2','lookup_client_by_phone visits = '||v_canonical);

  v_card := app.v666_till_customer_card(v_business, v_client);
  if (v_card->>'visits')::integer <> v_canonical then
    raise exception 'S1-T3 FAIL: v666_till_customer_card visits % against canonical %',
      v_card->>'visits', v_canonical; end if;
  insert into v677_evidence values('S1-T3','v666_till_customer_card visits = '||v_canonical);

  -- Read as the customer: their own app.
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_customer, 'role', 'authenticated')::text, true);
  v_pres := public.customer_get_business_presentation_v95(v_business, v_branch, v_locale);
  v_metric_j := jsonb_path_query_first(v_pres, '$.**.tier.current.metric');
  if v_metric_j is null or jsonb_typeof(v_metric_j) <> 'number' then
    raise exception 'FIXTURE: the customer stands below every tier, so v95 reports no metric to check';
  end if;
  v_n := v_metric_j::text::numeric;
  if v_n <> v_canonical then
    raise exception 'S1-T4 FAIL: v95 metric % against canonical %', v_n, v_canonical; end if;
  insert into v677_evidence values('S1-T4','customer_get_business_presentation_v95 metric = '||v_canonical);

  -- ---------------------------------------------------------------- SECTION 2
  -- The real till sale, as the owner.
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_owner, 'role', 'authenticated')::text, true);
  v_res := public.record_sale_by_phone(
    v_business, v_phone, 500, 'quick_sale', 'v677 acceptance probe',
    null, 'v677-'||replace(gen_random_uuid()::text,'-',''), v_branch, 'cash', null);
  if (v_res->>'status') <> 'ok' then
    raise exception 'FIXTURE: the till refused the sale (%)', v_res->>'status'; end if;
  v_sale := (v_res->>'sale_id')::uuid;

  with visit_rows as (
    select s.id, s.reversal_of from public.sales s
     where s.business_id = v_business and s.client_id = v_client and s.counts_as_visit
  )
  select count(*)::integer into v_canonical
    from visit_rows v
   where v.reversal_of is null
     and not exists (select 1 from visit_rows r where r.reversal_of = v.id);
  if v_canonical <> v_baseline + 1 then
    raise exception 'FIXTURE: the sale did not add a qualifying visit (% vs %); this tenant''s quick_sale policy has counts_as_visit off',
      v_canonical, v_baseline + 1; end if;

  v_tier := app.tier_resolve_v426(v_business, v_client);
  if (v_tier->>'metric')::numeric <> v_canonical then
    raise exception 'S2 FAIL: tier_resolve_v426 did not follow the sale (% vs %)',
      v_tier->>'metric', v_canonical; end if;
  v_res := public.lookup_client_by_phone(v_business, v_phone);
  if (v_res->>'visits')::integer <> v_canonical then
    raise exception 'S2 FAIL: lookup_client_by_phone did not follow the sale'; end if;
  v_card := app.v666_till_customer_card(v_business, v_client);
  if (v_card->>'visits')::integer <> v_canonical then
    raise exception 'S2 FAIL: v666_till_customer_card did not follow the sale'; end if;
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_customer, 'role', 'authenticated')::text, true);
  v_pres := public.customer_get_business_presentation_v95(v_business, v_branch, v_locale);
  v_metric_j := jsonb_path_query_first(v_pres, '$.**.tier.current.metric');
  v_n := v_metric_j::text::numeric;
  if v_n <> v_canonical then
    raise exception 'S2 FAIL: v95 did not follow the sale (% vs %)', v_n, v_canonical; end if;
  insert into v677_evidence values('S2','one real till sale moved all four readers to '||v_canonical);

  -- ---------------------------------------------------------------- SECTION 3
  -- The real reversal, as the owner.
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_owner, 'role', 'authenticated')::text, true);
  v_res := public.reverse_sale_fast_v84(
    v_business, v_sale, 'v677 acceptance probe',
    'v677rev-'||replace(gen_random_uuid()::text,'-',''));
  select s.id into v_reversal from public.sales s
   where s.business_id = v_business and s.reversal_of = v_sale;
  if v_reversal is null then
    raise exception 'FIXTURE: no reversal row was written for sale %', v_sale; end if;

  -- The two rows really are both flagged as visits — this is the defect's mechanism, and
  -- it is the number every one of the four readers used to report.
  select count(*)::integer into v_raw from public.sales s
   where s.business_id = v_business and s.client_id = v_client and s.counts_as_visit;
  if v_raw <> v_baseline + 2 then
    raise exception 'S3-T0 FAIL: the raw counts_as_visit set is % , expected the baseline + 2', v_raw; end if;
  insert into v677_evidence values('S3-T0','raw counts_as_visit = '||v_raw||' (baseline + 2) — what the four used to report');

  with visit_rows as (
    select s.id, s.reversal_of from public.sales s
     where s.business_id = v_business and s.client_id = v_client and s.counts_as_visit
  )
  select count(*)::integer into v_canonical
    from visit_rows v
   where v.reversal_of is null
     and not exists (select 1 from visit_rows r where r.reversal_of = v.id);
  if v_canonical <> v_baseline then
    raise exception 'S3 FAIL: canonical did not net to the baseline (% vs %)', v_canonical, v_baseline; end if;

  v_tier := app.tier_resolve_v426(v_business, v_client);
  if (v_tier->>'metric')::numeric <> v_baseline then
    raise exception 'S3-T1 FAIL: tier_resolve_v426 metric % after the reversal, expected %',
      v_tier->>'metric', v_baseline; end if;
  insert into v677_evidence values('S3-T1','tier_resolve_v426 netted back to '||v_baseline);

  v_res := public.lookup_client_by_phone(v_business, v_phone);
  if (v_res->>'visits')::integer <> v_baseline then
    raise exception 'S3-T2 FAIL: lookup_client_by_phone visits % after the reversal, expected %',
      v_res->>'visits', v_baseline; end if;
  insert into v677_evidence values('S3-T2','lookup_client_by_phone netted back to '||v_baseline);

  v_card := app.v666_till_customer_card(v_business, v_client);
  if (v_card->>'visits')::integer <> v_baseline then
    raise exception 'S3-T3 FAIL: v666_till_customer_card visits % after the reversal, expected %',
      v_card->>'visits', v_baseline; end if;
  insert into v677_evidence values('S3-T3','v666_till_customer_card netted back to '||v_baseline);

  perform set_config('request.jwt.claims',
    json_build_object('sub', v_customer, 'role', 'authenticated')::text, true);
  v_pres := public.customer_get_business_presentation_v95(v_business, v_branch, v_locale);
  v_metric_j := jsonb_path_query_first(v_pres, '$.**.tier.current.metric');
  v_n := v_metric_j::text::numeric;
  if v_n <> v_baseline then
    raise exception 'S3-T4 FAIL: v95 metric % after the reversal, expected %', v_n, v_baseline; end if;
  insert into v677_evidence values('S3-T4','customer_get_business_presentation_v95 netted back to '||v_baseline);

  -- ---------------------------------------------------------------- SECTION 4
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_owner, 'role', 'authenticated')::text, true);
  v_tier := app.tier_resolve_v426(v_business, v_client);
  if coalesce(v_tier#>>'{current,name}','(none)') <> v_base_tier then
    raise exception 'S4-T1 FAIL: the reversal moved the customer from % to %',
      v_base_tier, coalesce(v_tier#>>'{current,name}','(none)'); end if;
  insert into v677_evidence values('S4-T1','the reversal did not promote: still '||v_base_tier);

  select count(*)::integer into v_count from public.tier_transition_events e
   where e.business_id = v_business and e.client_id = v_client and e.trigger_ref = v_reversal;
  if v_count <> 0 then
    raise exception 'S4-T2 FAIL: % tier transition event(s) keyed to the reversal row', v_count; end if;
  insert into v677_evidence values('S4-T2','no tier transition event is keyed to the reversal');
end
$v677$;

select test, detail from v677_evidence order by test;

rollback;
