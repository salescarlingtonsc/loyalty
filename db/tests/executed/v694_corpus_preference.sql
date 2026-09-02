-- EXECUTED acceptance fixture for nestly_v694 — demographic service preference
-- (public.get_ci_demographic_preference_v1): SHARE and LIFT against the all-customer baseline,
-- never raw counts alone. Named for v694 because the RPC is new above the v422 baseline
-- watermark: every assertion below is `n/a` in the baseline phase and gated entirely on the
-- migrated run (`--migrated-only`). See docs/qa/CI-CORPUS-FIXTURE-GUIDE.md for the harness, the
-- impersonation recipe, and the write-guard GUC table this fixture follows for the reversal pair.
--
-- Two independent, disjoint calls (own windows, so neither call's population can contaminate the
-- other's totals even though both run against the same business):
--
-- ===========================================================================================
-- TRUTH TABLE — PRIMARY call, window [today-30, today-20]
-- ===========================================================================================
--   Two level-2 taxonomy nodes selected exactly like v667's fixture (first two distinct level-2
--   node_keys of version_no=1): node A, node B.
--
--   Cell (25_30, female): 6 women (W1..W6). Each spends 5000 cents on node A and 1000 cents on
--     node B. customers=6 (>= floor 5 -> evidence.status='ok').
--       cell_total_revenue_cents = 6*(5000+1000) = 36000.
--       node-A revenue = 6*5000 = 30000 -> cell_share.pct = round(100*30000/36000,1) = 83.3.
--       node-B revenue = 6*1000 = 6000  -> cell_share.pct = round(100*6000/36000,1)  = 16.7.
--       buyers = 6 for both nodes (every woman bought both).
--   Cell (41_50, male): 6 men (M1..M6). Each spends 1000 cents on node A and 5000 cents on node
--     B (the mirror image of the women's split). customers=6 -> evidence.status='ok'.
--       cell_total_revenue_cents = 6*(1000+5000) = 36000.
--       node-A revenue = 6000 -> cell_share.pct = 16.7.  node-B revenue = 30000 -> pct = 83.3.
--       buyers = 6 for both nodes.
--
--   Baseline (all resolved customers, both cells combined; nobody else resolved in this window):
--     baseline_total_revenue_cents = 36000 + 36000 = 72000.
--     node-A baseline revenue = 30000(women) + 6000(men)  = 36000 -> baseline pct = 50.0.
--     node-B baseline revenue = 6000(women)  + 30000(men) = 36000 -> baseline pct = 50.0.
--
--   Lift (computed from the ROUNDED pcts, per the migration's own formula):
--     women, node A: 83.3 / 50.0 = 1.666.. -> round(.,2) = 1.67  (over-indexes on A)
--     women, node B: 16.7 / 50.0 = 0.334   -> round(.,2) = 0.33  (under-indexes on B)
--     men,   node A: 16.7 / 50.0 = 0.334   -> round(.,2) = 0.33
--     men,   node B: 83.3 / 50.0 = 1.666.. -> round(.,2) = 1.67
--   Sorted by lift desc within cell: women = [A(1.67), B(0.33)]; men = [B(1.67), A(0.33)].
--
--   NEGATIVE CONTROLS (must leave every number above untouched):
--     Synthetic-1 (is_synthetic=true) spends 500000 cents on node A in the SAME window — the
--       `lines` CTE excludes any synthetic client before it ever reaches client_node/demog, so
--       node-A revenue must stay exactly 30000+6000=36000, not 536000.
--     W1 additionally gets an extra 20000-cent node-A sale that is IMMEDIATELY REVERSED (a
--       genuine reversal pair: an original sale + a reversal row with reversal_of pointing back
--       at it, per the CI-CORPUS-FIXTURE-GUIDE write-guard GUC recipe). If reversal exclusion
--       broke, women's node-A revenue would read 50000 instead of 30000 and W1's own
--       total_revenue_cents would read 26000 instead of 6000 — this fixture's assertions catch
--       either failure mode.
--
--   Coverage: active population = the 12 real, non-synthetic, classified-revenue customers (6
--     women + 6 men); every one of them is demographically resolved (age_band and gender both
--     known) and none has any unclassified line, so coverage.demographics = 12/12 = 100.0% and
--     coverage.revenue = 72000/72000 = 100.0%.
--
--   Envelope exclusions (app.ci_exclusion_counts_v680, an existing shared authority, sanity-
--     checked here rather than re-derived): reversed_sales=2 (the original AND its reversal row
--     both match the shared "reversed" predicate), synthetic_clients=1, anonymous_sales=0.
--
-- ===========================================================================================
-- TRUTH TABLE — SECOND call, isolated window [today-90, today-80]: confidence insufficiency
-- ===========================================================================================
--   2 customers (P1, P2; a demographic combo untouched by the primary window) each spend 3000
--   cents on node A only. cell customers=2 < floor 5 -> evidence.status='insufficient'.
--   cell_share is KEPT as real counts (numerator=6000, denominator=6000) but its pct is NULLED
--   (would otherwise be 100.0), so lift (which depends on cell_share.pct) is also NULL.
--   buyers=2 is kept exactly, because a raw count carries no false-precision risk.
\set ON_ERROR_STOP on

begin;

create temp table _fail(k text, v text) on commit drop;

do $v694$
declare
  biz     uuid := '00000000-0000-4000-8000-000000694001';
  u_sa    uuid := '00000000-0000-4000-8000-000000694002';
  u_owner uuid := '00000000-0000-4000-8000-000000694003';

  svc_a uuid := '00000000-0000-4000-8000-000000694010';
  svc_b uuid := '00000000-0000-4000-8000-000000694011';
  node_a text;
  node_b text;

  w1 uuid := '00000000-0000-4000-8000-000000694101';
  w2 uuid := '00000000-0000-4000-8000-000000694102';
  w3 uuid := '00000000-0000-4000-8000-000000694103';
  w4 uuid := '00000000-0000-4000-8000-000000694104';
  w5 uuid := '00000000-0000-4000-8000-000000694105';
  w6 uuid := '00000000-0000-4000-8000-000000694106';

  m1 uuid := '00000000-0000-4000-8000-000000694111';
  m2 uuid := '00000000-0000-4000-8000-000000694112';
  m3 uuid := '00000000-0000-4000-8000-000000694113';
  m4 uuid := '00000000-0000-4000-8000-000000694114';
  m5 uuid := '00000000-0000-4000-8000-000000694115';
  m6 uuid := '00000000-0000-4000-8000-000000694116';

  syn1 uuid := '00000000-0000-4000-8000-000000694120'; -- is_synthetic negative control
  s_rev_orig uuid := '00000000-0000-4000-8000-000000694121'; -- reversed-pair negative control
  s_rev_new  uuid := '00000000-0000-4000-8000-000000694122';

  p1 uuid := '00000000-0000-4000-8000-000000694201'; -- isolated-window below-floor cell
  p2 uuid := '00000000-0000-4000-8000-000000694202';

  d1_from date := current_date - 30;
  d1_to   date := current_date - 20;
  d1_sale date := current_date - 25;

  d2_from date := current_date - 90;
  d2_to   date := current_date - 80;
  d2_sale date := current_date - 85;

  g1 jsonb; g2 jsonb;
  v_cellF jsonb; v_cellM jsonb; v_cell2 jsonb;
  v_prefA jsonb; v_prefB jsonb; v_pref2 jsonb;
  v_baseA jsonb; v_baseB jsonb;
  v_err text;
begin
  ---------------------------------------------------------------------------
  -- actors: a Google-SSO super admin (v625 claim shape) — sole caller for this fixture.
  ---------------------------------------------------------------------------
  insert into auth.users (id, email) values
    (u_sa, 'zz-v694-sa@example.test'),
    (u_owner, 'zz-v694-owner@example.test')
    on conflict (id) do nothing;
  insert into public.super_admins (user_id, email)
    values (u_sa, 'zz-v694-sa@example.test') on conflict do nothing;

  ---------------------------------------------------------------------------
  -- an operational business (CI-CORPUS-FIXTURE-GUIDE.md recipe)
  ---------------------------------------------------------------------------
  insert into public.businesses (id, name, slug, enabled_modules) values
    (biz, 'ZZ v694 preference fixture', 'zz-v694-pref',
      array['dashboard','clients','sales','reports','customerintel']);
  insert into public.staff (business_id, user_id, role, full_name, active, access_state)
    values (biz, u_owner, 'owner', 'ZZ v694 owner', true, 'approved');
  insert into public.business_workspace_controls_v94
    (business_id, approval_status, decided_at, decision_reason)
  values (biz, 'approved', now(), 'v694 fixture')
    on conflict (business_id) do update
      set approval_status = 'approved', decided_at = now(), decision_reason = 'v694 fixture';
  insert into public.business_subscription_lifecycle_v94 (business_id, state, workspace_paused)
  values (biz, 'current', false)
    on conflict (business_id) do update set state = 'current', workspace_paused = false;
  insert into public.subscriptions (business_id, status, payment_status, current_period_end)
  values (biz, 'active', 'paid', now() + interval '30 days')
    on conflict (business_id) do update
      set status = 'active', payment_status = 'paid', current_period_end = now() + interval '30 days';

  ---------------------------------------------------------------------------
  -- catalogue: two level-2 nodes (v667's fixture pattern), each with its own service.
  ---------------------------------------------------------------------------
  select n.node_key into node_a from public.taxonomy_nodes n
   where n.version_no = 1 and n.level = 2 order by n.node_key limit 1;
  select n.node_key into node_b from public.taxonomy_nodes n
   where n.version_no = 1 and n.level = 2 and n.node_key <> node_a order by n.node_key limit 1;
  if node_a is null or node_b is null then
    insert into _fail values ('R0', 'taxonomy v1 has fewer than two level-2 nodes; fixture cannot run');
    return;
  end if;

  insert into public.services (id, business_id, name, price_cents, duration_min) values
    (svc_a, biz, 'ZZ v694 node-A service', 5000, 45),
    (svc_b, biz, 'ZZ v694 node-B service', 5000, 45);
  insert into public.service_canonical_map
    (business_id, service_id, node_key, version_no, method, mapped_by) values
    (biz, svc_a, node_a, 1, 'owner_chosen', u_owner),
    (biz, svc_b, node_b, 1, 'owner_chosen', u_owner);

  ---------------------------------------------------------------------------
  -- clients
  ---------------------------------------------------------------------------
  insert into public.clients (id, business_id, full_name, birth_date, gender) values
    (w1, biz, 'ZZ v694 W1', current_date - interval '27 years', 'female'),
    (w2, biz, 'ZZ v694 W2', current_date - interval '27 years', 'female'),
    (w3, biz, 'ZZ v694 W3', current_date - interval '27 years', 'female'),
    (w4, biz, 'ZZ v694 W4', current_date - interval '27 years', 'female'),
    (w5, biz, 'ZZ v694 W5', current_date - interval '27 years', 'female'),
    (w6, biz, 'ZZ v694 W6', current_date - interval '27 years', 'female'),
    (m1, biz, 'ZZ v694 M1', current_date - interval '45 years', 'male'),
    (m2, biz, 'ZZ v694 M2', current_date - interval '45 years', 'male'),
    (m3, biz, 'ZZ v694 M3', current_date - interval '45 years', 'male'),
    (m4, biz, 'ZZ v694 M4', current_date - interval '45 years', 'male'),
    (m5, biz, 'ZZ v694 M5', current_date - interval '45 years', 'male'),
    (m6, biz, 'ZZ v694 M6', current_date - interval '45 years', 'male'),
    (p1, biz, 'ZZ v694 P1', current_date - interval '22 years', 'male'),
    (p2, biz, 'ZZ v694 P2', current_date - interval '22 years', 'male');

  insert into public.clients (id, business_id, full_name, birth_date, gender, is_synthetic) values
    (syn1, biz, 'ZZ v694 Synthetic', current_date - interval '27 years', 'female', true);

  ---------------------------------------------------------------------------
  -- PRIMARY window sales: women (node A + node B), men (node A + node B, mirrored split)
  ---------------------------------------------------------------------------
  with ins as (
    insert into public.sales (id, business_id, client_id, kind, amount_cents, occurred_at,
                               counts_as_revenue, counts_as_visit)
    select gen_random_uuid(), biz, cid, 'service', 5000,
           d1_sale::timestamp at time zone 'Asia/Singapore', true, true
      from unnest(array[w1,w2,w3,w4,w5,w6]) as cid
    returning id, business_id
  )
  insert into public.sale_items (business_id, sale_id, item_type, ref_id, qty, unit_cents, line_cents)
  select business_id, id, 'service', svc_a, 1, 5000, 5000 from ins;

  with ins as (
    insert into public.sales (id, business_id, client_id, kind, amount_cents, occurred_at,
                               counts_as_revenue, counts_as_visit)
    select gen_random_uuid(), biz, cid, 'service', 1000,
           d1_sale::timestamp at time zone 'Asia/Singapore', true, true
      from unnest(array[w1,w2,w3,w4,w5,w6]) as cid
    returning id, business_id
  )
  insert into public.sale_items (business_id, sale_id, item_type, ref_id, qty, unit_cents, line_cents)
  select business_id, id, 'service', svc_b, 1, 1000, 1000 from ins;

  with ins as (
    insert into public.sales (id, business_id, client_id, kind, amount_cents, occurred_at,
                               counts_as_revenue, counts_as_visit)
    select gen_random_uuid(), biz, cid, 'service', 1000,
           d1_sale::timestamp at time zone 'Asia/Singapore', true, true
      from unnest(array[m1,m2,m3,m4,m5,m6]) as cid
    returning id, business_id
  )
  insert into public.sale_items (business_id, sale_id, item_type, ref_id, qty, unit_cents, line_cents)
  select business_id, id, 'service', svc_a, 1, 1000, 1000 from ins;

  with ins as (
    insert into public.sales (id, business_id, client_id, kind, amount_cents, occurred_at,
                               counts_as_revenue, counts_as_visit)
    select gen_random_uuid(), biz, cid, 'service', 5000,
           d1_sale::timestamp at time zone 'Asia/Singapore', true, true
      from unnest(array[m1,m2,m3,m4,m5,m6]) as cid
    returning id, business_id
  )
  insert into public.sale_items (business_id, sale_id, item_type, ref_id, qty, unit_cents, line_cents)
  select business_id, id, 'service', svc_b, 1, 5000, 5000 from ins;

  ---------------------------------------------------------------------------
  -- negative control 1: synthetic client, huge node-A spend, same window — must be invisible.
  ---------------------------------------------------------------------------
  with ins as (
    insert into public.sales (id, business_id, client_id, kind, amount_cents, occurred_at,
                               counts_as_revenue, counts_as_visit)
    values (gen_random_uuid(), biz, syn1, 'service', 500000,
            d1_sale::timestamp at time zone 'Asia/Singapore', true, true)
    returning id, business_id
  )
  insert into public.sale_items (business_id, sale_id, item_type, ref_id, qty, unit_cents, line_cents)
  select business_id, id, 'service', svc_a, 1, 500000, 500000 from ins;

  ---------------------------------------------------------------------------
  -- negative control 2: a genuine reversal pair on W1's node-A spend, same window — must be
  -- invisible (write-guard GUC recipe from CI-CORPUS-FIXTURE-GUIDE.md).
  ---------------------------------------------------------------------------
  insert into public.sales (id, business_id, client_id, kind, amount_cents, occurred_at,
                             created_at, counts_as_revenue, counts_as_visit)
  values (s_rev_orig, biz, w1, 'service', 20000,
          d1_sale::timestamp at time zone 'Asia/Singapore',
          d1_sale::timestamp at time zone 'Asia/Singapore', true, true);
  insert into public.sale_items (business_id, sale_id, item_type, ref_id, qty, unit_cents, line_cents)
  values (biz, s_rev_orig, 'service', svc_a, 1, 20000, 20000);

  perform set_config('app.sale_reversal_insert_id', s_rev_new::text, true);
  perform set_config('app.sale_reversal_original_id', s_rev_orig::text, true);
  insert into public.sales (id, business_id, client_id, kind, amount_cents, occurred_at, created_at,
                             reversal_of, reversal_reason, reversal_actor, reversal_idempotency_key)
  values (s_rev_new, biz, w1, 'service', -20000,
          d1_sale::timestamp at time zone 'Asia/Singapore',
          d1_sale::timestamp at time zone 'Asia/Singapore',
          s_rev_orig, 'ZZ v694 fixture reversal', u_owner, 'zz-v694-rev-idem-001');
  perform set_config('app.sale_reversal_insert_id', '', true);
  perform set_config('app.sale_reversal_original_id', '', true);

  ---------------------------------------------------------------------------
  -- SECOND, isolated window: a below-floor 2-customer cell.
  ---------------------------------------------------------------------------
  with ins as (
    insert into public.sales (id, business_id, client_id, kind, amount_cents, occurred_at,
                               counts_as_revenue, counts_as_visit)
    select gen_random_uuid(), biz, cid, 'service', 3000,
           d2_sale::timestamp at time zone 'Asia/Singapore', true, true
      from unnest(array[p1,p2]) as cid
    returning id, business_id
  )
  insert into public.sale_items (business_id, sale_id, item_type, ref_id, qty, unit_cents, line_cents)
  select business_id, id, 'service', svc_a, 1, 3000, 3000 from ins;

  ---------------------------------------------------------------------------
  -- impersonate the entitled caller: super admin via Google SSO (v625 claim shape)
  ---------------------------------------------------------------------------
  perform set_config('request.jwt.claims', json_build_object(
      'sub', u_sa, 'role', 'authenticated',
      'amr', json_build_array(json_build_object('method', 'oauth')),
      'app_metadata', json_build_object('providers', json_build_array('google'))
    )::text, true);

  ---------------------------------------------------------------------------
  -- PRIMARY call
  ---------------------------------------------------------------------------
  begin
    g1 := public.get_ci_demographic_preference_v1(biz, d1_from, d1_to);
  exception when others then
    get stacked diagnostics v_err = returned_sqlstate;
    insert into _fail values ('P1-pre', format('super admin refused (%s)', v_err));
    g1 := null;
  end;

  if g1 is null then
    insert into _fail values ('P1-pre', 'get_ci_demographic_preference_v1 returned no payload');
  else
    -- payload must never claim causality
    if position('CAUSAL' in upper(g1::text)) > 0 then
      insert into _fail values ('P1-no-causal', 'the word CAUSAL appears in the payload');
    end if;
    if g1->>'limitation' <> 'preference is a revenue-share association within the window, not a stated intent' then
      insert into _fail values ('P1-limitation', coalesce(g1->>'limitation', '<null>'));
    end if;
    if g1->>'time_basis' <> 'sale_occurred_at' then
      insert into _fail values ('P1-time-basis', coalesce(g1->>'time_basis', '<null>'));
    end if;
    if g1->>'observed_since' is null then
      insert into _fail values ('P1-observed-since', 'missing');
    end if;

    -- envelope (v680 contract)
    if g1->>'generated_at' is null then
      insert into _fail values ('P1-envelope-generated-at', 'missing');
    end if;
    if g1->>'as_of' is null then
      insert into _fail values ('P1-envelope-as-of', 'missing');
    end if;
    if g1->>'trace_id' is null then
      insert into _fail values ('P1-envelope-trace', 'missing');
    end if;
    if (g1->'exclusions'->>'reversed_sales')::int <> 2 then
      insert into _fail values ('P1-excl-reversed', format('got %s expected 2', g1->'exclusions'->>'reversed_sales'));
    end if;
    if (g1->'exclusions'->>'synthetic_clients')::int <> 1 then
      insert into _fail values ('P1-excl-synthetic', format('got %s expected 1', g1->'exclusions'->>'synthetic_clients'));
    end if;
    if (g1->'exclusions'->>'anonymous_sales')::int <> 0 then
      insert into _fail values ('P1-excl-anon', format('got %s expected 0', g1->'exclusions'->>'anonymous_sales'));
    end if;

    if jsonb_array_length(coalesce(g1->'cells', '[]'::jsonb)) <> 2 then
      insert into _fail values ('P1-cellcount',
        format('%s cells, expected exactly 2 (25_30/female and 41_50/male) — a leaked negative control widens this',
               jsonb_array_length(coalesce(g1->'cells', '[]'::jsonb))));
    end if;

    -- ---------------------------------------------------------------- women cell
    v_cellF := null;
    select rec into v_cellF from jsonb_array_elements(g1->'cells') rec
     where rec->>'age_band' = '25_30' and rec->>'gender' = 'female';
    if v_cellF is null then
      insert into _fail values ('P1-cellF', 'no (25_30,female) cell in the payload');
    else
      if v_cellF->'evidence'->>'status' <> 'ok' then
        insert into _fail values ('P1-cellF-evidence', coalesce(v_cellF->'evidence'->>'status', '<null>'));
      end if;
      if (v_cellF->'evidence'->>'n')::int <> 6 then
        insert into _fail values ('P1-cellF-n', v_cellF->'evidence'->>'n');
      end if;
      if jsonb_array_length(coalesce(v_cellF->'preferences', '[]'::jsonb)) <> 2 then
        insert into _fail values ('P1-cellF-prefcount', jsonb_array_length(coalesce(v_cellF->'preferences','[]'::jsonb))::text);
      else
        v_prefA := v_cellF->'preferences'->0; -- sorted by lift desc -> node A (1.67) first
        v_prefB := v_cellF->'preferences'->1;

        if v_prefA->>'node_key' <> node_a then
          insert into _fail values ('P1-cellF-pref0-node', coalesce(v_prefA->>'node_key', '<null>'));
        end if;
        if (v_prefA->'cell_share'->>'numerator')::bigint <> 30000
           or (v_prefA->'cell_share'->>'denominator')::bigint <> 36000
           or (v_prefA->'cell_share'->>'pct')::numeric <> 83.3 then
          insert into _fail values ('P1-cellF-pref0-share', format('got %s', v_prefA->'cell_share'));
        end if;
        if (v_prefA->'baseline_share'->>'numerator')::bigint <> 36000
           or (v_prefA->'baseline_share'->>'denominator')::bigint <> 72000
           or (v_prefA->'baseline_share'->>'pct')::numeric <> 50.0 then
          insert into _fail values ('P1-cellF-pref0-baseline', format('got %s', v_prefA->'baseline_share'));
        end if;
        if (v_prefA->>'lift')::numeric <> 1.67 then
          insert into _fail values ('P1-cellF-pref0-lift', format('got %s expected 1.67', v_prefA->>'lift'));
        end if;
        if (v_prefA->>'buyers')::int <> 6 then
          insert into _fail values ('P1-cellF-pref0-buyers', v_prefA->>'buyers');
        end if;

        if v_prefB->>'node_key' <> node_b then
          insert into _fail values ('P1-cellF-pref1-node', coalesce(v_prefB->>'node_key', '<null>'));
        end if;
        if (v_prefB->'cell_share'->>'numerator')::bigint <> 6000
           or (v_prefB->'cell_share'->>'denominator')::bigint <> 36000
           or (v_prefB->'cell_share'->>'pct')::numeric <> 16.7 then
          insert into _fail values ('P1-cellF-pref1-share', format('got %s', v_prefB->'cell_share'));
        end if;
        if (v_prefB->>'lift')::numeric <> 0.33 then
          insert into _fail values ('P1-cellF-pref1-lift', format('got %s expected 0.33', v_prefB->>'lift'));
        end if;
        if (v_prefB->>'buyers')::int <> 6 then
          insert into _fail values ('P1-cellF-pref1-buyers', v_prefB->>'buyers');
        end if;
      end if;
    end if;

    -- ---------------------------------------------------------------- men cell
    v_cellM := null;
    select rec into v_cellM from jsonb_array_elements(g1->'cells') rec
     where rec->>'age_band' = '41_50' and rec->>'gender' = 'male';
    if v_cellM is null then
      insert into _fail values ('P1-cellM', 'no (41_50,male) cell in the payload');
    else
      if v_cellM->'evidence'->>'status' <> 'ok' then
        insert into _fail values ('P1-cellM-evidence', coalesce(v_cellM->'evidence'->>'status', '<null>'));
      end if;
      if jsonb_array_length(coalesce(v_cellM->'preferences', '[]'::jsonb)) <> 2 then
        insert into _fail values ('P1-cellM-prefcount', jsonb_array_length(coalesce(v_cellM->'preferences','[]'::jsonb))::text);
      else
        v_prefA := v_cellM->'preferences'->0; -- sorted by lift desc -> node B (1.67) first for men
        v_prefB := v_cellM->'preferences'->1;

        if v_prefA->>'node_key' <> node_b then
          insert into _fail values ('P1-cellM-pref0-node', coalesce(v_prefA->>'node_key', '<null>'));
        end if;
        if (v_prefA->'cell_share'->>'numerator')::bigint <> 30000
           or (v_prefA->'cell_share'->>'denominator')::bigint <> 36000
           or (v_prefA->'cell_share'->>'pct')::numeric <> 83.3 then
          insert into _fail values ('P1-cellM-pref0-share', format('got %s', v_prefA->'cell_share'));
        end if;
        if (v_prefA->>'lift')::numeric <> 1.67 then
          insert into _fail values ('P1-cellM-pref0-lift', format('got %s expected 1.67', v_prefA->>'lift'));
        end if;

        if v_prefB->>'node_key' <> node_a then
          insert into _fail values ('P1-cellM-pref1-node', coalesce(v_prefB->>'node_key', '<null>'));
        end if;
        if (v_prefB->'cell_share'->>'numerator')::bigint <> 6000
           or (v_prefB->'cell_share'->>'denominator')::bigint <> 36000
           or (v_prefB->'cell_share'->>'pct')::numeric <> 16.7 then
          insert into _fail values ('P1-cellM-pref1-share', format('got %s', v_prefB->'cell_share'));
        end if;
        if (v_prefB->>'lift')::numeric <> 0.33 then
          insert into _fail values ('P1-cellM-pref1-lift', format('got %s expected 0.33', v_prefB->>'lift'));
        end if;
      end if;
    end if;

    -- ---------------------------------------------------------------- baseline block
    v_baseA := null; v_baseB := null;
    select rec into v_baseA from jsonb_array_elements(g1->'baseline') rec where rec->>'node_key' = node_a;
    select rec into v_baseB from jsonb_array_elements(g1->'baseline') rec where rec->>'node_key' = node_b;
    if v_baseA is null or v_baseB is null then
      insert into _fail values ('P1-baseline-nodes', 'missing node A or node B in the baseline block');
    else
      if (v_baseA->'share'->>'numerator')::bigint <> 36000
         or (v_baseA->'share'->>'denominator')::bigint <> 72000
         or (v_baseA->'share'->>'pct')::numeric <> 50.0 then
        insert into _fail values ('P1-baseline-A', format('got %s', v_baseA->'share'));
      end if;
      if (v_baseB->'share'->>'numerator')::bigint <> 36000
         or (v_baseB->'share'->>'denominator')::bigint <> 72000
         or (v_baseB->'share'->>'pct')::numeric <> 50.0 then
        insert into _fail values ('P1-baseline-B', format('got %s', v_baseB->'share'));
      end if;
    end if;

    -- ---------------------------------------------------------------- coverage
    if (g1->'coverage'->'demographics'->>'numerator')::int <> 12
       or (g1->'coverage'->'demographics'->>'denominator')::int <> 12
       or (g1->'coverage'->'demographics'->>'pct')::numeric <> 100.0 then
      insert into _fail values ('P1-coverage-demo', format('got %s', g1->'coverage'->'demographics'));
    end if;
    if (g1->'coverage'->'revenue'->>'numerator')::bigint <> 72000
       or (g1->'coverage'->'revenue'->>'denominator')::bigint <> 72000
       or (g1->'coverage'->'revenue'->>'pct')::numeric <> 100.0 then
      insert into _fail values ('P1-coverage-rev', format('got %s', g1->'coverage'->'revenue'));
    end if;
  end if;

  ---------------------------------------------------------------------------
  -- SECOND call — isolated window, below-floor cell
  ---------------------------------------------------------------------------
  begin
    g2 := public.get_ci_demographic_preference_v1(biz, d2_from, d2_to);
  exception when others then
    get stacked diagnostics v_err = returned_sqlstate;
    insert into _fail values ('P2-pre', format('super admin refused (%s)', v_err));
    g2 := null;
  end;

  if g2 is null then
    insert into _fail values ('P2-pre', 'get_ci_demographic_preference_v1 returned no payload (second call)');
  else
    if jsonb_array_length(coalesce(g2->'cells', '[]'::jsonb)) <> 1 then
      insert into _fail values ('P2-cellcount', jsonb_array_length(coalesce(g2->'cells','[]'::jsonb))::text);
    else
      v_cell2 := g2->'cells'->0;
      if v_cell2->'evidence'->>'status' <> 'insufficient' then
        insert into _fail values ('P2-evidence', coalesce(v_cell2->'evidence'->>'status', '<null>'));
      end if;
      if (v_cell2->'evidence'->>'n')::int <> 2 then
        insert into _fail values ('P2-evidence-n', v_cell2->'evidence'->>'n');
      end if;
      if (v_cell2->'evidence'->>'floor')::int <> 5 then
        insert into _fail values ('P2-evidence-floor', v_cell2->'evidence'->>'floor');
      end if;

      if jsonb_array_length(coalesce(v_cell2->'preferences', '[]'::jsonb)) <> 1 then
        insert into _fail values ('P2-prefcount', jsonb_array_length(coalesce(v_cell2->'preferences','[]'::jsonb))::text);
      else
        v_pref2 := v_cell2->'preferences'->0;
        if v_pref2->>'node_key' <> node_a then
          insert into _fail values ('P2-pref-node', coalesce(v_pref2->>'node_key', '<null>'));
        end if;
        -- counts kept exactly ...
        if (v_pref2->'cell_share'->>'numerator')::bigint <> 6000
           or (v_pref2->'cell_share'->>'denominator')::bigint <> 6000 then
          insert into _fail values ('P2-pref-share-counts', format('got %s', v_pref2->'cell_share'));
        end if;
        -- ... but pct is withheld
        if v_pref2->'cell_share'->>'pct' is not null then
          insert into _fail values ('P2-pref-share-pct', format('expected null, got %s', v_pref2->'cell_share'->>'pct'));
        end if;
        -- lift withheld
        if v_pref2->>'lift' is not null then
          insert into _fail values ('P2-pref-lift', format('expected null, got %s', v_pref2->>'lift'));
        end if;
        -- buyers count kept
        if (v_pref2->>'buyers')::int <> 2 then
          insert into _fail values ('P2-pref-buyers', format('got %s expected 2', v_pref2->>'buyers'));
        end if;
      end if;
    end if;
  end if;

  perform set_config('request.jwt.claims', null, true);
end
$v694$;

select case when count(*) = 0
            then 'PASS — v694 demographic preference share + lift hold exactly'
            else 'FAIL' end as verdict,
       count(*) as failures from _fail;
select k, v from _fail order by k, v;

do $verdict$
declare n integer; d text;
begin
  select count(*), string_agg(format('%s: %s', f.k, f.v), E'\n  ' order by f.k, f.v)
    into n, d from _fail f;
  if n > 0 then raise exception 'v694: % assertion(s) failed:%  %', n, E'\n', d; end if;
end
$verdict$;

rollback;
