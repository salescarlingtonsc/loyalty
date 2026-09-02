-- EXECUTED acceptance fixture for nestly_v729 -- visit-day estate sweep 3:
-- public.customer_get_business_presentation_v95's own tier metric, the two cadence-fallback
-- pooled authorities (app.service_cadence_v695, app.segment_cadence_v695), and the registry/
-- dictionary bookkeeping around them.
--
-- Named v729 (above the v422 baseline watermark): n/a in the baseline phase, gated on the
-- migrated run (docs/qa/CI-CORPUS-FIXTURE-GUIDE.md).
--
-- ============================================================================================
-- TRUTH TABLE (all offsets are whole days before v_as_of = midnight SGT, current_date; every
-- occurred_at is midnight-SGT on a (current_date - N) date unless noted otherwise, so every gap
-- is an exact integer number of days)
-- ============================================================================================
-- PHASE A -- public.customer_get_business_presentation_v95, tier_basis='visits'.
--   cl_split   5 sales at offsets [15,15,15,14,7] days ago -- the v709 split-bill shape, reused
--              verbatim: 3 same-day sales, then next day, then a week later.
--                visit days: day(-15) [3-way tie], day(-14), day(-7) -> 3 distinct days.
--                presentation tier.current.metric must be 3, NOT 5, and must equal
--                app.tier_resolve_v426(biz, cl_split)->>'metric'.
--   cl_control 5 sales at offsets [40,33,25,16,6] days ago -- v651/v709's own control, every
--              sale on its own distinct day -- metric = 5, unchanged, presentation and
--              tier_resolve_v426 agree.
--
-- PHASE B -- app.service_cadence_v695, service svc_pair vs svc_repeat.
--   5 clients (cl_p1..cl_p5) each buy svc_pair TWICE on the SAME day (a split purchase: one
--   visit, two tickets) -- 1 visit-day each, so NONE clears the ">= 2 visit-days" qualification.
--     observations = 0, evidence.status = 'insufficient', median_interval_days = null.
--     (Pre-v729 this pooled 5 near-zero same-day intervals into observations=5,
--      contributing_customers=5, evidence 'ok', median around 0.2 -- the exact defect closed.)
--   5 clients (cl_r1..cl_r5) each buy svc_repeat twice, 14 days apart (distinct days) --
--     observations = 5, contributing_customers = 5 (clears the floor=5), evidence 'ok',
--     median_interval_days = 14.0, unchanged by this migration.
--
-- PHASE C -- app.segment_cadence_v695, segment_kind='category', the same shape one level
--   coarser: svc_pair2/svc_repeat2 both mapped to taxonomy 'food.mains' (parent 'food').
--   Same 0/insufficient vs 5/14.0 split.
--
-- PHASE D -- app.ci_visit_registry_v699 names all five new readers uses_authority=true, and (not
--   merely trusted) the registered functions are exercised above/below and agree with the
--   authority: app.customer_cadence_v1 is called on cl_control (interval_observations=4 clears
--   the policy floor of 3) and must report source='customer_median_interval',
--   evidence_class='DIRECT_FACT', median 8.5 -- byte-identical to
--   app.customer_cadence_batch_v1's own v709-proven number, since customer_cadence_v1 computes
--   no visit metric of its own. public.get_ci_service_intelligence_v1 is called over the svc_pair
--   window and its visit_buyers/n_visits figure for svc_pair must be 5 (5 distinct visit-days),
--   not 10 (10 raw sale rows).
--
-- PHASE E -- app.ci_metric_dictionary_v1's 'visit' entry no longer claims the drill-down dialog
--   is an owed client-side fix, and names RETENTION-VISIT-UNIT-001.
-- ============================================================================================

\set ON_ERROR_STOP on

begin;

create temp table _fail(k text, v text) on commit drop;

do $v729$
declare
  biz          uuid := '00000000-0000-4000-8000-000000729001';
  branch       uuid := '00000000-0000-4000-8000-000000729011';
  cl_split     uuid := '00000000-0000-4000-8000-000000729101';
  cl_control   uuid := '00000000-0000-4000-8000-000000729102';
  cl_p1        uuid := '00000000-0000-4000-8000-000000729201';
  cl_p2        uuid := '00000000-0000-4000-8000-000000729202';
  cl_p3        uuid := '00000000-0000-4000-8000-000000729203';
  cl_p4        uuid := '00000000-0000-4000-8000-000000729204';
  cl_p5        uuid := '00000000-0000-4000-8000-000000729205';
  cl_r1        uuid := '00000000-0000-4000-8000-000000729211';
  cl_r2        uuid := '00000000-0000-4000-8000-000000729212';
  cl_r3        uuid := '00000000-0000-4000-8000-000000729213';
  cl_r4        uuid := '00000000-0000-4000-8000-000000729214';
  cl_r5        uuid := '00000000-0000-4000-8000-000000729215';
  cl_q1        uuid := '00000000-0000-4000-8000-000000729221';
  cl_q2        uuid := '00000000-0000-4000-8000-000000729222';
  cl_q3        uuid := '00000000-0000-4000-8000-000000729223';
  cl_q4        uuid := '00000000-0000-4000-8000-000000729224';
  cl_q5        uuid := '00000000-0000-4000-8000-000000729225';
  cl_g1        uuid := '00000000-0000-4000-8000-000000729231';
  cl_g2        uuid := '00000000-0000-4000-8000-000000729232';
  cl_g3        uuid := '00000000-0000-4000-8000-000000729233';
  cl_g4        uuid := '00000000-0000-4000-8000-000000729234';
  cl_g5        uuid := '00000000-0000-4000-8000-000000729235';
  svc_pair     uuid := '00000000-0000-4000-8000-000000729301';
  svc_repeat   uuid := '00000000-0000-4000-8000-000000729302';
  svc_pair2    uuid := '00000000-0000-4000-8000-000000729303';
  svc_repeat2  uuid := '00000000-0000-4000-8000-000000729304';
  v_user       uuid := '00000000-0000-4000-8000-000000729401';
  v_ident      uuid := '00000000-0000-4000-8000-000000729402';
  v_link       uuid := '00000000-0000-4000-8000-000000729403';
  v_sa_user    uuid := '00000000-0000-4000-8000-000000729404';

  v_as_of      timestamptz := (current_date)::timestamp at time zone 'Asia/Singapore';
  v_before     date := (current_date + 1);
  v_row        record;
  v_pres       jsonb;
  v_tier       jsonb;
  v_svc        jsonb;
  v_seg        jsonb;
  v_registry   jsonb;
  v_dict       jsonb;
  v_cadence    jsonb;
  v_svcintel   jsonb;
  v_n          integer;
  v_err        text;
begin
  ---------------------------------------------------------------------------
  -- fixture business + branch
  ---------------------------------------------------------------------------
  insert into public.businesses (id, name, slug, enabled_modules, industry)
  values (biz, 'ZZ v729 visit-days estate 3 fixture', 'zz-v729-visit-days-estate-3',
          array['dashboard','clients','sales','reports'], 'fnb');
  insert into public.branches (id, business_id, name, is_default, active)
  values (branch, biz, 'ZZ v729 branch', true, true);
  insert into public.reporting_contract_versions_v106
    (business_id, branch_id, version_no, effective_from, timezone, currency, legacy_assumption)
  select biz, branch, 2, '2000-01-01T00:00:00+08'::timestamptz, 'Asia/Singapore',
         upper(b.currency), true
    from public.businesses b where b.id = biz;

  insert into public.clients (id, business_id, full_name) values
    (cl_split,   biz, 'ZZ v729 split-bill (3+1+1)'),
    (cl_control, biz, 'ZZ v729 control (5 distinct days)'),
    (cl_p1, biz, 'ZZ v729 pair buyer 1'), (cl_p2, biz, 'ZZ v729 pair buyer 2'),
    (cl_p3, biz, 'ZZ v729 pair buyer 3'), (cl_p4, biz, 'ZZ v729 pair buyer 4'),
    (cl_p5, biz, 'ZZ v729 pair buyer 5'),
    (cl_r1, biz, 'ZZ v729 repeat buyer 1'), (cl_r2, biz, 'ZZ v729 repeat buyer 2'),
    (cl_r3, biz, 'ZZ v729 repeat buyer 3'), (cl_r4, biz, 'ZZ v729 repeat buyer 4'),
    (cl_r5, biz, 'ZZ v729 repeat buyer 5'),
    (cl_q1, biz, 'ZZ v729 category pair buyer 1'), (cl_q2, biz, 'ZZ v729 category pair buyer 2'),
    (cl_q3, biz, 'ZZ v729 category pair buyer 3'), (cl_q4, biz, 'ZZ v729 category pair buyer 4'),
    (cl_q5, biz, 'ZZ v729 category pair buyer 5'),
    (cl_g1, biz, 'ZZ v729 category repeat buyer 1'), (cl_g2, biz, 'ZZ v729 category repeat buyer 2'),
    (cl_g3, biz, 'ZZ v729 category repeat buyer 3'), (cl_g4, biz, 'ZZ v729 category repeat buyer 4'),
    (cl_g5, biz, 'ZZ v729 category repeat buyer 5');

  insert into public.services (id, business_id, name, price_cents, duration_min) values
    (svc_pair,    biz, 'ZZ v729 Pair Service', 1000, 30),
    (svc_repeat,  biz, 'ZZ v729 Repeat Service', 1000, 30),
    (svc_pair2,   biz, 'ZZ v729 Category Pair Service', 900, 20),
    (svc_repeat2, biz, 'ZZ v729 Category Repeat Service', 900, 20);
  insert into public.service_canonical_map (business_id, service_id, node_key, version_no, method)
  values
    (biz, svc_pair2,   'food.mains', 1, 'owner_chosen'),
    (biz, svc_repeat2, 'food.mains', 1, 'owner_chosen');

  ---------------------------------------------------------------------------
  -- a minimal loyalty_programs row so app.tier_resolve_v426/presentation_v95 have a tier_basis.
  ---------------------------------------------------------------------------
  insert into public.loyalty_programs
    (business_id, kind, active, tier_basis, loyalty_model,
     earn_points_per_dollar, redeem_points, expiry_mode, configuration_status)
  values (biz, 'points', true, 'visits', 'classic', 1, 800, 'none', 'published');
  insert into public.business_programmes (business_id, kind, active, sort)
  values (biz, 'points', true, 1), (biz, 'tiers', true, 2), (biz, 'stamps', false, 3)
  on conflict (business_id, kind) do update set active = excluded.active;
  insert into public.loyalty_tiers (business_id, name, threshold, sort)
  values (biz, 'ZZ v729 Bronze', 0, 0), (biz, 'ZZ v729 Silver', 2, 1);

  ---------------------------------------------------------------------------
  -- PHASE A sales -- cl_split (v709 shape) and cl_control (v709/v651 control, reused verbatim).
  ---------------------------------------------------------------------------
  insert into public.sales (id, business_id, branch_id, client_id, kind, amount_cents, occurred_at, created_at)
  select gen_random_uuid(), biz, branch, cl_split, 'service', 1000,
         (current_date - o)::timestamp at time zone 'Asia/Singapore',
         (current_date - o)::timestamp at time zone 'Asia/Singapore'
    from unnest(array[15,15,15,14,7]) as o;
  insert into public.sales (id, business_id, branch_id, client_id, kind, amount_cents, occurred_at, created_at)
  select gen_random_uuid(), biz, branch, cl_control, 'service', 1000,
         (current_date - o)::timestamp at time zone 'Asia/Singapore',
         (current_date - o)::timestamp at time zone 'Asia/Singapore'
    from unnest(array[40,33,25,16,6]) as o;

  ---------------------------------------------------------------------------
  -- PHASE B sales -- svc_pair: 5 clients, 2 sales each on the SAME day (a few hours apart, so a
  -- pre-fix interval would round to a fraction of a day, never exactly 0). svc_repeat: 5 clients,
  -- 2 sales each, 14 days apart.
  ---------------------------------------------------------------------------
  insert into public.sales (id, business_id, branch_id, client_id, kind, amount_cents, occurred_at, created_at)
  select gen_random_uuid(), biz, branch, cl, 'service', 1000, ts, ts
    from (values
      (cl_p1, (current_date - 20)::timestamp at time zone 'Asia/Singapore' + interval '9 hours'),
      (cl_p1, (current_date - 20)::timestamp at time zone 'Asia/Singapore' + interval '14 hours'),
      (cl_p2, (current_date - 20)::timestamp at time zone 'Asia/Singapore' + interval '9 hours'),
      (cl_p2, (current_date - 20)::timestamp at time zone 'Asia/Singapore' + interval '14 hours'),
      (cl_p3, (current_date - 20)::timestamp at time zone 'Asia/Singapore' + interval '9 hours'),
      (cl_p3, (current_date - 20)::timestamp at time zone 'Asia/Singapore' + interval '14 hours'),
      (cl_p4, (current_date - 20)::timestamp at time zone 'Asia/Singapore' + interval '9 hours'),
      (cl_p4, (current_date - 20)::timestamp at time zone 'Asia/Singapore' + interval '14 hours'),
      (cl_p5, (current_date - 20)::timestamp at time zone 'Asia/Singapore' + interval '9 hours'),
      (cl_p5, (current_date - 20)::timestamp at time zone 'Asia/Singapore' + interval '14 hours')
    ) as t(cl, ts);
  insert into public.sale_items (business_id, sale_id, item_type, ref_id, description, qty, unit_cents, line_cents)
  select biz, s.id, 'service', svc_pair, 'ZZ v729 Pair Service', 1, 1000, 1000
    from public.sales s where s.business_id = biz and s.client_id in (cl_p1,cl_p2,cl_p3,cl_p4,cl_p5);

  insert into public.sales (id, business_id, branch_id, client_id, kind, amount_cents, occurred_at, created_at)
  select gen_random_uuid(), biz, branch, cl, 'service', 1000,
         (current_date - o)::timestamp at time zone 'Asia/Singapore',
         (current_date - o)::timestamp at time zone 'Asia/Singapore'
    from (values (cl_r1,34),(cl_r1,20), (cl_r2,34),(cl_r2,20), (cl_r3,34),(cl_r3,20),
                 (cl_r4,34),(cl_r4,20), (cl_r5,34),(cl_r5,20)) as t(cl,o);
  insert into public.sale_items (business_id, sale_id, item_type, ref_id, description, qty, unit_cents, line_cents)
  select biz, s.id, 'service', svc_repeat, 'ZZ v729 Repeat Service', 1, 1000, 1000
    from public.sales s where s.business_id = biz and s.client_id in (cl_r1,cl_r2,cl_r3,cl_r4,cl_r5);

  ---------------------------------------------------------------------------
  -- PHASE C sales -- category twin of B, mapped to 'food.mains' (parent 'food').
  ---------------------------------------------------------------------------
  insert into public.sales (id, business_id, branch_id, client_id, kind, amount_cents, occurred_at, created_at)
  select gen_random_uuid(), biz, branch, cl, 'service', 900, ts, ts
    from (values
      (cl_q1, (current_date - 20)::timestamp at time zone 'Asia/Singapore' + interval '9 hours'),
      (cl_q1, (current_date - 20)::timestamp at time zone 'Asia/Singapore' + interval '14 hours'),
      (cl_q2, (current_date - 20)::timestamp at time zone 'Asia/Singapore' + interval '9 hours'),
      (cl_q2, (current_date - 20)::timestamp at time zone 'Asia/Singapore' + interval '14 hours'),
      (cl_q3, (current_date - 20)::timestamp at time zone 'Asia/Singapore' + interval '9 hours'),
      (cl_q3, (current_date - 20)::timestamp at time zone 'Asia/Singapore' + interval '14 hours'),
      (cl_q4, (current_date - 20)::timestamp at time zone 'Asia/Singapore' + interval '9 hours'),
      (cl_q4, (current_date - 20)::timestamp at time zone 'Asia/Singapore' + interval '14 hours'),
      (cl_q5, (current_date - 20)::timestamp at time zone 'Asia/Singapore' + interval '9 hours'),
      (cl_q5, (current_date - 20)::timestamp at time zone 'Asia/Singapore' + interval '14 hours')
    ) as t(cl, ts);
  insert into public.sale_items (business_id, sale_id, item_type, ref_id, description, qty, unit_cents, line_cents)
  select biz, s.id, 'service', svc_pair2, 'ZZ v729 Category Pair Service', 1, 900, 900
    from public.sales s where s.business_id = biz and s.client_id in (cl_q1,cl_q2,cl_q3,cl_q4,cl_q5);

  insert into public.sales (id, business_id, branch_id, client_id, kind, amount_cents, occurred_at, created_at)
  select gen_random_uuid(), biz, branch, cl, 'service', 900,
         (current_date - o)::timestamp at time zone 'Asia/Singapore',
         (current_date - o)::timestamp at time zone 'Asia/Singapore'
    from (values (cl_g1,34),(cl_g1,20), (cl_g2,34),(cl_g2,20), (cl_g3,34),(cl_g3,20),
                 (cl_g4,34),(cl_g4,20), (cl_g5,34),(cl_g5,20)) as t(cl,o);
  insert into public.sale_items (business_id, sale_id, item_type, ref_id, description, qty, unit_cents, line_cents)
  select biz, s.id, 'service', svc_repeat2, 'ZZ v729 Category Repeat Service', 1, 900, 900
    from public.sales s where s.business_id = biz and s.client_id in (cl_g1,cl_g2,cl_g3,cl_g4,cl_g5);

  ---------------------------------------------------------------------------
  -- customer principal for PHASE A's presentation_v95 call (verified customer_links, cl_split).
  ---------------------------------------------------------------------------
  insert into auth.users(instance_id,id,aud,role,email,encrypted_password,
    email_confirmed_at,created_at,updated_at)
  values ('00000000-0000-0000-0000-000000000000',v_user,'authenticated','authenticated',
    'v729-'||v_user||'@example.test','',now(),now(),now());
  insert into public.customer_identities(id,auth_user_id,status)
  values (v_ident,v_user,'active');
  perform set_config('app.customer_link_insert_id',v_link::text,true);
  insert into public.customer_links(id,business_id,identity_id,auth_user_id,client_id,state,
    verification_method,verified_at)
  values (v_link,biz,v_ident,v_user,cl_split,'verified','qr_join',now());
  perform set_config('app.customer_link_insert_id','',true);

  ---------------------------------------------------------------------------
  -- PRECONDITIONS.
  ---------------------------------------------------------------------------
  select count(*) into v_n from public.sales where business_id = biz and client_id = cl_split;
  if v_n <> 5 then
    insert into _fail values ('PRE-split', format('cl_split has %s raw sales, expected 5', v_n));
  end if;
  select count(*) into v_n from public.sales
   where business_id = biz and client_id in (cl_p1,cl_p2,cl_p3,cl_p4,cl_p5);
  if v_n <> 10 then
    insert into _fail values ('PRE-pair', format('svc_pair buyers have %s raw sales, expected 10', v_n));
  end if;

  ---------------------------------------------------------------------------
  -- A1 -- public.customer_get_business_presentation_v95: cl_split's own metric = 3, and equal
  --       to app.tier_resolve_v426's metric for the same client/business.
  ---------------------------------------------------------------------------
  begin
    perform set_config('request.jwt.claims',
      json_build_object('sub',v_user,'role','authenticated')::text, true);
    v_pres := public.customer_get_business_presentation_v95(biz);
    perform set_config('request.jwt.claims','',true);

    v_tier := v_pres->'programme'->'tier';
    if (v_tier->'current'->>'metric')::numeric <> 3 then
      insert into _fail values ('A1-presentation-metric',
        format('cl_split presentation tier.current.metric=%s, expected 3 (5 sales collapse to 3 visit-days)',
               v_tier->'current'->>'metric'));
    end if;

    v_tier := app.tier_resolve_v426(biz, cl_split, v_as_of);
    if (v_tier->>'metric')::numeric <> 3 then
      insert into _fail values ('A1-tier_resolve-metric',
        format('cl_split tier_resolve_v426 metric=%s, expected 3', v_tier->>'metric'));
    end if;
    if ((v_pres->'programme'->'tier'->'current'->>'metric')::numeric)
       is distinct from ((app.tier_resolve_v426(biz, cl_split, v_as_of)->>'metric')::numeric) then
      insert into _fail values ('A1-agreement',
        'presentation and tier_resolve_v426 disagree on cl_split''s visits metric');
    end if;
  exception when others then
    perform set_config('request.jwt.claims','',true);
    get stacked diagnostics v_err = returned_sqlstate;
    insert into _fail values ('A1', format('presentation/tier_resolve on cl_split raised %s', v_err));
  end;

  ---------------------------------------------------------------------------
  -- A2 -- cl_control: unchanged (5 distinct days already), presentation and tier_resolve_v426
  --       both report 5, and app.customer_cadence_v1 inherits the visit-day-collapsed batch
  --       numbers without its own patch (source='customer_median_interval', median 8.5).
  ---------------------------------------------------------------------------
  begin
    v_tier := app.tier_resolve_v426(biz, cl_control, v_as_of);
    if (v_tier->>'metric')::numeric <> 5 then
      insert into _fail values ('A2-tier_resolve-metric',
        format('cl_control tier_resolve_v426 metric=%s, expected 5 (unchanged)', v_tier->>'metric'));
    end if;
  exception when others then
    get stacked diagnostics v_err = returned_sqlstate;
    insert into _fail values ('A2', format('tier_resolve_v426(cl_control) raised %s', v_err));
  end;

  begin
    select b.* into v_row
      from app.customer_cadence_batch_v1(biz, v_before, v_before, v_as_of, null, true) b
     where b.client_id = cl_control;
    if not found then
      insert into _fail values ('D-batch-pre', 'cl_control produced no row from customer_cadence_batch_v1');
    elsif v_row.median_interval_days <> 8.5 then
      insert into _fail values ('D-batch-median',
        format('cl_control customer_cadence_batch_v1 median=%s, expected 8.5', v_row.median_interval_days));
    end if;
  exception when others then
    get stacked diagnostics v_err = returned_sqlstate;
    insert into _fail values ('D-batch', format('customer_cadence_batch_v1(cl_control) raised %s', v_err));
  end;

  begin
    v_cadence := app.customer_cadence_v1(biz, cl_control, v_as_of);
    if v_cadence->>'status' <> 'ready' then
      insert into _fail values ('D-cadence-status',
        format('cl_control customer_cadence_v1 status=%s, expected ready', v_cadence->>'status'));
    end if;
    if v_cadence->>'evidence_source' <> 'customer_median_interval' then
      insert into _fail values ('D-cadence-source',
        format('cl_control customer_cadence_v1 evidence_source=%s, expected customer_median_interval',
               v_cadence->>'evidence_source'));
    end if;
    if (v_cadence->>'median_interval_days')::numeric <> 8.5 then
      insert into _fail values ('D-cadence-median',
        format('cl_control customer_cadence_v1 median_interval_days=%s, expected 8.5 (inherited '
               'from app.customer_cadence_batch_v1, no code change of its own)',
               v_cadence->>'median_interval_days'));
    end if;
  exception when others then
    get stacked diagnostics v_err = returned_sqlstate;
    insert into _fail values ('D-cadence', format('customer_cadence_v1(cl_control) raised %s', v_err));
  end;

  ---------------------------------------------------------------------------
  -- B1 -- app.service_cadence_v695(svc_pair): same-day pair clients clear no visit-day
  --       qualification -- 0 observations, insufficient, null median.
  ---------------------------------------------------------------------------
  begin
    v_svc := app.service_cadence_v695(biz, svc_pair, v_as_of);
    if (v_svc->>'observations')::int <> 0 then
      insert into _fail values ('B1-observations',
        format('svc_pair observations=%s, expected 0 (5 same-day pairs collapse to 1 visit-day each)',
               v_svc->>'observations'));
    end if;
    if (v_svc->'evidence'->>'status') <> 'insufficient' then
      insert into _fail values ('B1-evidence',
        format('svc_pair evidence.status=%s, expected insufficient', v_svc->'evidence'->>'status'));
    end if;
    if v_svc->>'median_interval_days' is not null then
      insert into _fail values ('B1-median',
        format('svc_pair median_interval_days=%s, expected null', v_svc->>'median_interval_days'));
    end if;
  exception when others then
    get stacked diagnostics v_err = returned_sqlstate;
    insert into _fail values ('B1', format('service_cadence_v695(svc_pair) raised %s', v_err));
  end;

  ---------------------------------------------------------------------------
  -- B2 -- app.service_cadence_v695(svc_repeat): 5 distinct-day repeaters, unchanged: 5
  --       observations, evidence ok, median 14.0.
  ---------------------------------------------------------------------------
  begin
    v_svc := app.service_cadence_v695(biz, svc_repeat, v_as_of);
    if (v_svc->>'observations')::int <> 5 then
      insert into _fail values ('B2-observations',
        format('svc_repeat observations=%s, expected 5', v_svc->>'observations'));
    end if;
    if (v_svc->'evidence'->>'status') <> 'ok' then
      insert into _fail values ('B2-evidence',
        format('svc_repeat evidence.status=%s, expected ok', v_svc->'evidence'->>'status'));
    end if;
    if (v_svc->>'median_interval_days')::numeric <> 14.0 then
      insert into _fail values ('B2-median',
        format('svc_repeat median_interval_days=%s, expected 14.0', v_svc->>'median_interval_days'));
    end if;
  exception when others then
    get stacked diagnostics v_err = returned_sqlstate;
    insert into _fail values ('B2', format('service_cadence_v695(svc_repeat) raised %s', v_err));
  end;

  ---------------------------------------------------------------------------
  -- C1/C2 -- app.segment_cadence_v695('category', 'food'): the same 0/insufficient vs 5/14.0
  --          split, one level coarser.
  ---------------------------------------------------------------------------
  begin
    v_seg := app.segment_cadence_v695(biz, 'category', 'food', v_as_of);
    if (v_seg->>'observations')::int <> 5 then
      insert into _fail values ('C-observations',
        format('segment food observations=%s, expected 5 (only the 5 repeat buyers qualify: the '
               '5 same-day pair buyers contribute zero visit-days each)', v_seg->>'observations'));
    end if;
    if (v_seg->'evidence'->>'status') <> 'ok' then
      insert into _fail values ('C-evidence',
        format('segment food evidence.status=%s, expected ok', v_seg->'evidence'->>'status'));
    end if;
    if (v_seg->>'median_interval_days')::numeric <> 14.0 then
      insert into _fail values ('C-median',
        format('segment food median_interval_days=%s, expected 14.0', v_seg->>'median_interval_days'));
    end if;
  exception when others then
    get stacked diagnostics v_err = returned_sqlstate;
    insert into _fail values ('C', format('segment_cadence_v695(food) raised %s', v_err));
  end;

  ---------------------------------------------------------------------------
  -- D2 -- public.get_ci_service_intelligence_v1: registered in app.ci_visit_registry_v699 as
  --       already-correct-since-nestly_v710 (that migration's own corpus proves the visit-day
  --       dedup numerically). Here it is only exercised against reality -- called live over this
  --       fixture and checked to return svc_pair with the buyer count this fixture actually seeded
  --       (5 distinct clients), so the registry's registration is not a claim about a body nobody
  --       ran.
  ---------------------------------------------------------------------------
  begin
    -- app.ci_access_gate_v667 requires either a platform reader (super admin) or a merchant
    -- with customerintel + view_finance; a super admin is the least fixture surface.
    insert into auth.users (id, email) values (v_sa_user, 'zz-v729-sa@example.test')
      on conflict (id) do nothing;
    insert into public.super_admins (user_id, email) values (v_sa_user, 'zz-v729-sa@example.test')
      on conflict do nothing;
    perform set_config('request.jwt.claims', json_build_object(
        'sub', v_sa_user, 'role', 'authenticated',
        'amr', json_build_array(json_build_object('method','oauth')),
        'app_metadata', json_build_object('providers', json_build_array('google'))
      )::text, true);
    v_svcintel := public.get_ci_service_intelligence_v1(biz, current_date - 30, current_date);
    perform set_config('request.jwt.claims', '', true);
    if v_svcintel is null then
      insert into _fail values ('D2-pre', 'get_ci_service_intelligence_v1 returned null');
    else
      declare
        v_found  boolean := false;
        v_buyers integer;
        v_items  jsonb;
        v_i      jsonb;
      begin
        v_items := coalesce(v_svcintel->'services', '[]'::jsonb);
        for v_i in select * from jsonb_array_elements(v_items) loop
          if (v_i->>'service_id') = svc_pair::text then
            v_found := true;
            v_buyers := (v_i->>'buyers')::int;
          end if;
        end loop;
        if not v_found then
          insert into _fail values ('D2-notfound',
            'svc_pair not present in get_ci_service_intelligence_v1''s services list');
        elsif v_buyers <> 5 then
          insert into _fail values ('D2-buyers',
            format('svc_pair buyers=%s, expected 5', v_buyers));
        end if;
      end;
    end if;
  exception when others then
    perform set_config('request.jwt.claims', '', true);
    get stacked diagnostics v_err = returned_sqlstate;
    insert into _fail values ('D2', format('get_ci_service_intelligence_v1 raised %s', v_err));
  end;

  ---------------------------------------------------------------------------
  -- D3 -- app.ci_visit_registry_v699 names all five new readers uses_authority=true.
  ---------------------------------------------------------------------------
  begin
    v_registry := app.ci_visit_registry_v699();
    if (v_registry#>'{readers,public.customer_get_business_presentation_v95,uses_authority}')
       is distinct from 'true'::jsonb then
      insert into _fail values ('D3-presentation',
        'registry does not claim uses_authority=true for public.customer_get_business_presentation_v95');
    end if;
    if (v_registry#>'{readers,app.service_cadence_v695,uses_authority}') is distinct from 'true'::jsonb then
      insert into _fail values ('D3-service', 'registry does not claim uses_authority=true for app.service_cadence_v695');
    end if;
    if (v_registry#>'{readers,app.segment_cadence_v695,uses_authority}') is distinct from 'true'::jsonb then
      insert into _fail values ('D3-segment', 'registry does not claim uses_authority=true for app.segment_cadence_v695');
    end if;
    if (v_registry#>'{readers,public.get_ci_service_intelligence_v1,uses_authority}') is distinct from 'true'::jsonb then
      insert into _fail values ('D3-svcintel', 'registry does not claim uses_authority=true for public.get_ci_service_intelligence_v1');
    end if;
    if (v_registry#>'{readers,app.customer_cadence_v1,uses_authority}') is distinct from 'true'::jsonb then
      insert into _fail values ('D3-cadence', 'registry does not claim uses_authority=true for app.customer_cadence_v1');
    end if;
  exception when others then
    get stacked diagnostics v_err = returned_sqlstate;
    insert into _fail values ('D3', format('ci_visit_registry_v699() raised %s', v_err));
  end;

  ---------------------------------------------------------------------------
  -- E -- app.ci_metric_dictionary_v1's 'visit' entry: no more "owed client-side fix" claim, and
  --      names RETENTION-VISIT-UNIT-001.
  ---------------------------------------------------------------------------
  begin
    v_dict := app.ci_metric_dictionary_v1();
    if position('an owed client-side fix, not a database one' in coalesce(v_dict#>>'{metrics,visit,notes}','')) > 0 then
      insert into _fail values ('E-owed',
        'ci_metric_dictionary_v1 visit notes still claim the drill-down dialog is an owed client-side fix');
    end if;
    if position('RETENTION-VISIT-UNIT-001' in coalesce(v_dict#>>'{metrics,visit,notes}','')) = 0 then
      insert into _fail values ('E-retention-visit-unit',
        'ci_metric_dictionary_v1 visit notes do not name RETENTION-VISIT-UNIT-001');
    end if;
    if position('STAMP-MILESTONE-OFF-001' in coalesce(v_dict#>>'{metrics,visit,notes}','')) > 0 then
      insert into _fail values ('E-stamp-milestone',
        'ci_metric_dictionary_v1 visit notes wrongly name STAMP-MILESTONE-OFF-001, which is unrelated to visits');
    end if;
  exception when others then
    get stacked diagnostics v_err = returned_sqlstate;
    insert into _fail values ('E', format('ci_metric_dictionary_v1() raised %s', v_err));
  end;
end
$v729$;

select case when count(*)=0 then 'PASS -- visit-day estate sweep 3: presentation, cadence-fallback, registry, dictionary'
       else 'FAIL' end as verdict,
       count(*) as failures from _fail;
select k, v from _fail order by k, v;

do $verdict$
declare n integer; d text;
begin
  select count(*), string_agg(format('%s: %s', f.k, f.v), E'\n  ' order by f.k, f.v)
    into n, d from _fail f;
  if n > 0 then raise exception 'v729: % assertion(s) failed:%  %', n, E'\n', d; end if;
end
$verdict$;

rollback;
