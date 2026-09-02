-- EXECUTED regression fixture for nestly_v726 -- period validation on the 13 remaining
-- get_ci_* readers (docs/qa/CI-100-CHECKLIST.md check 98).
--
-- WHY. The refuter proved every one of these 13 readers accepted p_to < p_from and returned a
-- normal-looking, empty payload instead of raising -- an inverted window is indistinguishable
-- from a genuinely quiet period at the call site. nestly_v726 adds
-- app.ci_period_validate_v726(p_from, p_to), called immediately after the shared
-- app.ci_access_gate_v667 in each of the 13 readers, raising 'invalid_report_window' (22023)
-- on an inverted or null-bounded window.
--
-- Three assertions per reader, run as SA1..SA13 / SI1..SI13 / SS1..SS13:
--   SAn  a super-admin (entitled) call with an INVERTED window (p_from later than p_to) raises
--        22023 'invalid_report_window'.
--   SIn  the SAME super-admin call with a VALID window still answers (no exception, non-null
--        jsonb payload) -- proves the new guard does not reject legitimate requests.
--   SSn  an unrelated, unentitled caller ("the stranger") making the SAME inverted-window call
--        is refused with 42501, NOT 22023 -- proves the access gate still fires before the new
--        period guard, so a refused caller never learns anything about the shape of the request
--        they were never entitled to make.
--
-- AUTH CONTEXT. Reuses the v706/v698 pattern: a real-session (Google OAuth) super admin clears
-- app.ci_access_gate_v667's platform arm outright, so this fixture needs no merchant workspace
-- setup (subscription/module/staff rows) to prove entitled behaviour -- it is not testing
-- entitlement, only the new period guard and its placement relative to the existing gate.
--
-- Named for v726 (above the v422 baseline watermark): n/a in the baseline phase, gated on the
-- migrated run. Proves db/migrations/20260902_nestly_v726_period_validation.sql.
--
-- One transaction, rolled back. No production access.

\set ON_ERROR_STOP on

begin;

create temp table _fail(k text, v text) on commit drop;

do $v726$
declare
  biz         uuid := '00000000-0000-4000-8000-000000726001';
  u_sa        uuid := '00000000-0000-4000-8000-000000726101';
  u_stranger  uuid := '00000000-0000-4000-8000-000000726102';
  d_from      date := current_date - 10;
  d_to        date := current_date;
  node_key    text;
  g           jsonb;
  v_err       text;
begin
  ---------------------------------------------------------------------------
  -- actors + minimal business (SA path needs no workspace/subscription rows -- v176 checks
  -- is_super_admin() OR platform_firm_report_access_v94, both independent of subscription
  -- state; the merchant arm is not exercised by this fixture).
  ---------------------------------------------------------------------------
  insert into auth.users (id, email) values
    (u_sa,'zz-v726-sa@example.test'), (u_stranger,'zz-v726-stranger@example.test')
    on conflict (id) do nothing;
  insert into public.super_admins (user_id, email)
    values (u_sa,'zz-v726-sa@example.test') on conflict do nothing;

  insert into public.businesses (id, name, slug, enabled_modules) values
    (biz,'ZZ v726 firm','zz-v726-firm',
      array['dashboard','clients','sales','reports','customerintel']);

  select n.node_key into node_key from public.taxonomy_nodes n
   where n.version_no = 1 and n.level = 2 order by n.node_key limit 1;
  if node_key is null then
    insert into _fail values ('pre','no taxonomy node found at version_no=1, level=2 -- demographic_cohort assertions would be vacuous');
    node_key := 'barbering';
  end if;

  ---------------------------------------------------------------------------
  -- PRECONDITIONS.
  ---------------------------------------------------------------------------
  perform set_config('request.jwt.claims', json_build_object(
      'sub', u_sa, 'role','authenticated',
      'amr', json_build_array(json_build_object('method','oauth')),
      'app_metadata', json_build_object('providers', json_build_array('google'))
    )::text, true);
  if not app.is_super_admin() then
    insert into _fail values ('pre','the Google-session fixture user does not resolve is_super_admin(); SA/SI series would be vacuous');
  end if;
  perform set_config('request.jwt.claims',
    json_build_object('sub',u_stranger,'role','authenticated')::text, true);
  if app.v176_can_read_firm_report(biz) then
    insert into _fail values ('pre','the stranger already resolves platform read access; SS series would be vacuous');
  end if;
  if app.is_salon_member(biz) then
    insert into _fail values ('pre','the stranger already resolves salon membership; SS series would be vacuous');
  end if;

  ---------------------------------------------------------------------------
  -- acquisition: public.get_ci_acquisition_v1
  ---------------------------------------------------------------------------
  perform set_config('request.jwt.claims', json_build_object(
      'sub', u_sa, 'role','authenticated',
      'amr', json_build_array(json_build_object('method','oauth')),
      'app_metadata', json_build_object('providers', json_build_array('google'))
    )::text, true);
  -- SA1 -- entitled caller, inverted window -> 22023 invalid_report_window
  begin
    g := public.get_ci_acquisition_v1(biz, d_to, d_from);
    insert into _fail values ('SA1','get_ci_acquisition_v1: inverted window did not raise for the entitled caller');
  exception when others then
    get stacked diagnostics v_err = returned_sqlstate;
    if v_err <> '22023' then
      insert into _fail values ('SA1', format('get_ci_acquisition_v1: expected 22023, got %s', v_err));
    end if;
  end;
  -- SI1 -- entitled caller, valid window -> still answers
  begin
    g := public.get_ci_acquisition_v1(biz, d_from, d_to);
    if g is null then
      insert into _fail values ('SI1','get_ci_acquisition_v1: valid window returned a null payload for the entitled caller');
    end if;
  exception when others then
    get stacked diagnostics v_err = returned_sqlstate;
    insert into _fail values ('SI1', format('get_ci_acquisition_v1: valid window was refused (%s) for the entitled caller', v_err));
  end;

  -- SS1 -- stranger, inverted window -> 42501 (gate fires before the period guard)
  perform set_config('request.jwt.claims',
    json_build_object('sub',u_stranger,'role','authenticated')::text, true);
  begin
    g := public.get_ci_acquisition_v1(biz, d_to, d_from);
    insert into _fail values ('SS1','get_ci_acquisition_v1: the stranger reached the reader at all');
  exception when insufficient_privilege then null;
           when others then
             get stacked diagnostics v_err = returned_sqlstate;
             insert into _fail values ('SS1', format('get_ci_acquisition_v1: expected 42501, got %s', v_err));
  end;

  ---------------------------------------------------------------------------
  -- category_mix: public.get_ci_category_mix_v1
  ---------------------------------------------------------------------------
  perform set_config('request.jwt.claims', json_build_object(
      'sub', u_sa, 'role','authenticated',
      'amr', json_build_array(json_build_object('method','oauth')),
      'app_metadata', json_build_object('providers', json_build_array('google'))
    )::text, true);
  -- SA2 -- entitled caller, inverted window -> 22023 invalid_report_window
  begin
    g := public.get_ci_category_mix_v1(biz, d_to, d_from);
    insert into _fail values ('SA2','get_ci_category_mix_v1: inverted window did not raise for the entitled caller');
  exception when others then
    get stacked diagnostics v_err = returned_sqlstate;
    if v_err <> '22023' then
      insert into _fail values ('SA2', format('get_ci_category_mix_v1: expected 22023, got %s', v_err));
    end if;
  end;
  -- SI2 -- entitled caller, valid window -> still answers
  begin
    g := public.get_ci_category_mix_v1(biz, d_from, d_to);
    if g is null then
      insert into _fail values ('SI2','get_ci_category_mix_v1: valid window returned a null payload for the entitled caller');
    end if;
  exception when others then
    get stacked diagnostics v_err = returned_sqlstate;
    insert into _fail values ('SI2', format('get_ci_category_mix_v1: valid window was refused (%s) for the entitled caller', v_err));
  end;

  -- SS2 -- stranger, inverted window -> 42501 (gate fires before the period guard)
  perform set_config('request.jwt.claims',
    json_build_object('sub',u_stranger,'role','authenticated')::text, true);
  begin
    g := public.get_ci_category_mix_v1(biz, d_to, d_from);
    insert into _fail values ('SS2','get_ci_category_mix_v1: the stranger reached the reader at all');
  exception when insufficient_privilege then null;
           when others then
             get stacked diagnostics v_err = returned_sqlstate;
             insert into _fail values ('SS2', format('get_ci_category_mix_v1: expected 42501, got %s', v_err));
  end;

  ---------------------------------------------------------------------------
  -- demographic_cohort: public.get_ci_demographic_cohort_v1
  ---------------------------------------------------------------------------
  perform set_config('request.jwt.claims', json_build_object(
      'sub', u_sa, 'role','authenticated',
      'amr', json_build_array(json_build_object('method','oauth')),
      'app_metadata', json_build_object('providers', json_build_array('google'))
    )::text, true);
  -- SA3 -- entitled caller, inverted window -> 22023 invalid_report_window
  begin
    g := public.get_ci_demographic_cohort_v1(biz, 'female', 0, 99, node_key, d_to, d_from);
    insert into _fail values ('SA3','get_ci_demographic_cohort_v1: inverted window did not raise for the entitled caller');
  exception when others then
    get stacked diagnostics v_err = returned_sqlstate;
    if v_err <> '22023' then
      insert into _fail values ('SA3', format('get_ci_demographic_cohort_v1: expected 22023, got %s', v_err));
    end if;
  end;
  -- SI3 -- entitled caller, valid window -> still answers
  begin
    g := public.get_ci_demographic_cohort_v1(biz, 'female', 0, 99, node_key, d_from, d_to);
    if g is null then
      insert into _fail values ('SI3','get_ci_demographic_cohort_v1: valid window returned a null payload for the entitled caller');
    end if;
  exception when others then
    get stacked diagnostics v_err = returned_sqlstate;
    insert into _fail values ('SI3', format('get_ci_demographic_cohort_v1: valid window was refused (%s) for the entitled caller', v_err));
  end;

  -- SS3 -- stranger, inverted window -> 42501 (gate fires before the period guard)
  perform set_config('request.jwt.claims',
    json_build_object('sub',u_stranger,'role','authenticated')::text, true);
  begin
    g := public.get_ci_demographic_cohort_v1(biz, 'female', 0, 99, node_key, d_to, d_from);
    insert into _fail values ('SS3','get_ci_demographic_cohort_v1: the stranger reached the reader at all');
  exception when insufficient_privilege then null;
           when others then
             get stacked diagnostics v_err = returned_sqlstate;
             insert into _fail values ('SS3', format('get_ci_demographic_cohort_v1: expected 42501, got %s', v_err));
  end;

  ---------------------------------------------------------------------------
  -- demographics: public.get_ci_demographics_v1
  ---------------------------------------------------------------------------
  perform set_config('request.jwt.claims', json_build_object(
      'sub', u_sa, 'role','authenticated',
      'amr', json_build_array(json_build_object('method','oauth')),
      'app_metadata', json_build_object('providers', json_build_array('google'))
    )::text, true);
  -- SA4 -- entitled caller, inverted window -> 22023 invalid_report_window
  begin
    g := public.get_ci_demographics_v1(biz, d_to, d_from);
    insert into _fail values ('SA4','get_ci_demographics_v1: inverted window did not raise for the entitled caller');
  exception when others then
    get stacked diagnostics v_err = returned_sqlstate;
    if v_err <> '22023' then
      insert into _fail values ('SA4', format('get_ci_demographics_v1: expected 22023, got %s', v_err));
    end if;
  end;
  -- SI4 -- entitled caller, valid window -> still answers
  begin
    g := public.get_ci_demographics_v1(biz, d_from, d_to);
    if g is null then
      insert into _fail values ('SI4','get_ci_demographics_v1: valid window returned a null payload for the entitled caller');
    end if;
  exception when others then
    get stacked diagnostics v_err = returned_sqlstate;
    insert into _fail values ('SI4', format('get_ci_demographics_v1: valid window was refused (%s) for the entitled caller', v_err));
  end;

  -- SS4 -- stranger, inverted window -> 42501 (gate fires before the period guard)
  perform set_config('request.jwt.claims',
    json_build_object('sub',u_stranger,'role','authenticated')::text, true);
  begin
    g := public.get_ci_demographics_v1(biz, d_to, d_from);
    insert into _fail values ('SS4','get_ci_demographics_v1: the stranger reached the reader at all');
  exception when insufficient_privilege then null;
           when others then
             get stacked diagnostics v_err = returned_sqlstate;
             insert into _fail values ('SS4', format('get_ci_demographics_v1: expected 42501, got %s', v_err));
  end;

  ---------------------------------------------------------------------------
  -- discount_dependency: public.get_ci_discount_dependency_v1
  ---------------------------------------------------------------------------
  perform set_config('request.jwt.claims', json_build_object(
      'sub', u_sa, 'role','authenticated',
      'amr', json_build_array(json_build_object('method','oauth')),
      'app_metadata', json_build_object('providers', json_build_array('google'))
    )::text, true);
  -- SA5 -- entitled caller, inverted window -> 22023 invalid_report_window
  begin
    g := public.get_ci_discount_dependency_v1(biz, d_to, d_from);
    insert into _fail values ('SA5','get_ci_discount_dependency_v1: inverted window did not raise for the entitled caller');
  exception when others then
    get stacked diagnostics v_err = returned_sqlstate;
    if v_err <> '22023' then
      insert into _fail values ('SA5', format('get_ci_discount_dependency_v1: expected 22023, got %s', v_err));
    end if;
  end;
  -- SI5 -- entitled caller, valid window -> still answers
  begin
    g := public.get_ci_discount_dependency_v1(biz, d_from, d_to);
    if g is null then
      insert into _fail values ('SI5','get_ci_discount_dependency_v1: valid window returned a null payload for the entitled caller');
    end if;
  exception when others then
    get stacked diagnostics v_err = returned_sqlstate;
    insert into _fail values ('SI5', format('get_ci_discount_dependency_v1: valid window was refused (%s) for the entitled caller', v_err));
  end;

  -- SS5 -- stranger, inverted window -> 42501 (gate fires before the period guard)
  perform set_config('request.jwt.claims',
    json_build_object('sub',u_stranger,'role','authenticated')::text, true);
  begin
    g := public.get_ci_discount_dependency_v1(biz, d_to, d_from);
    insert into _fail values ('SS5','get_ci_discount_dependency_v1: the stranger reached the reader at all');
  exception when insufficient_privilege then null;
           when others then
             get stacked diagnostics v_err = returned_sqlstate;
             insert into _fail values ('SS5', format('get_ci_discount_dependency_v1: expected 42501, got %s', v_err));
  end;

  ---------------------------------------------------------------------------
  -- funnel_conversion: public.get_ci_funnel_conversion_v1
  ---------------------------------------------------------------------------
  perform set_config('request.jwt.claims', json_build_object(
      'sub', u_sa, 'role','authenticated',
      'amr', json_build_array(json_build_object('method','oauth')),
      'app_metadata', json_build_object('providers', json_build_array('google'))
    )::text, true);
  -- SA6 -- entitled caller, inverted window -> 22023 invalid_report_window
  begin
    g := public.get_ci_funnel_conversion_v1(biz, d_to, d_from, 60);
    insert into _fail values ('SA6','get_ci_funnel_conversion_v1: inverted window did not raise for the entitled caller');
  exception when others then
    get stacked diagnostics v_err = returned_sqlstate;
    if v_err <> '22023' then
      insert into _fail values ('SA6', format('get_ci_funnel_conversion_v1: expected 22023, got %s', v_err));
    end if;
  end;
  -- SI6 -- entitled caller, valid window -> still answers
  begin
    g := public.get_ci_funnel_conversion_v1(biz, d_from, d_to, 60);
    if g is null then
      insert into _fail values ('SI6','get_ci_funnel_conversion_v1: valid window returned a null payload for the entitled caller');
    end if;
  exception when others then
    get stacked diagnostics v_err = returned_sqlstate;
    insert into _fail values ('SI6', format('get_ci_funnel_conversion_v1: valid window was refused (%s) for the entitled caller', v_err));
  end;

  -- SS6 -- stranger, inverted window -> 42501 (gate fires before the period guard)
  perform set_config('request.jwt.claims',
    json_build_object('sub',u_stranger,'role','authenticated')::text, true);
  begin
    g := public.get_ci_funnel_conversion_v1(biz, d_to, d_from, 60);
    insert into _fail values ('SS6','get_ci_funnel_conversion_v1: the stranger reached the reader at all');
  exception when insufficient_privilege then null;
           when others then
             get stacked diagnostics v_err = returned_sqlstate;
             insert into _fail values ('SS6', format('get_ci_funnel_conversion_v1: expected 42501, got %s', v_err));
  end;

  ---------------------------------------------------------------------------
  -- funnel: public.get_ci_funnel_v1
  ---------------------------------------------------------------------------
  perform set_config('request.jwt.claims', json_build_object(
      'sub', u_sa, 'role','authenticated',
      'amr', json_build_array(json_build_object('method','oauth')),
      'app_metadata', json_build_object('providers', json_build_array('google'))
    )::text, true);
  -- SA7 -- entitled caller, inverted window -> 22023 invalid_report_window
  begin
    g := public.get_ci_funnel_v1(biz, d_to, d_from);
    insert into _fail values ('SA7','get_ci_funnel_v1: inverted window did not raise for the entitled caller');
  exception when others then
    get stacked diagnostics v_err = returned_sqlstate;
    if v_err <> '22023' then
      insert into _fail values ('SA7', format('get_ci_funnel_v1: expected 22023, got %s', v_err));
    end if;
  end;
  -- SI7 -- entitled caller, valid window -> still answers
  begin
    g := public.get_ci_funnel_v1(biz, d_from, d_to);
    if g is null then
      insert into _fail values ('SI7','get_ci_funnel_v1: valid window returned a null payload for the entitled caller');
    end if;
  exception when others then
    get stacked diagnostics v_err = returned_sqlstate;
    insert into _fail values ('SI7', format('get_ci_funnel_v1: valid window was refused (%s) for the entitled caller', v_err));
  end;

  -- SS7 -- stranger, inverted window -> 42501 (gate fires before the period guard)
  perform set_config('request.jwt.claims',
    json_build_object('sub',u_stranger,'role','authenticated')::text, true);
  begin
    g := public.get_ci_funnel_v1(biz, d_to, d_from);
    insert into _fail values ('SS7','get_ci_funnel_v1: the stranger reached the reader at all');
  exception when insufficient_privilege then null;
           when others then
             get stacked diagnostics v_err = returned_sqlstate;
             insert into _fail values ('SS7', format('get_ci_funnel_v1: expected 42501, got %s', v_err));
  end;

  ---------------------------------------------------------------------------
  -- loyalty_programmes: public.get_ci_loyalty_programmes_v1
  ---------------------------------------------------------------------------
  perform set_config('request.jwt.claims', json_build_object(
      'sub', u_sa, 'role','authenticated',
      'amr', json_build_array(json_build_object('method','oauth')),
      'app_metadata', json_build_object('providers', json_build_array('google'))
    )::text, true);
  -- SA8 -- entitled caller, inverted window -> 22023 invalid_report_window
  begin
    g := public.get_ci_loyalty_programmes_v1(biz, d_to, d_from);
    insert into _fail values ('SA8','get_ci_loyalty_programmes_v1: inverted window did not raise for the entitled caller');
  exception when others then
    get stacked diagnostics v_err = returned_sqlstate;
    if v_err <> '22023' then
      insert into _fail values ('SA8', format('get_ci_loyalty_programmes_v1: expected 22023, got %s', v_err));
    end if;
  end;
  -- SI8 -- entitled caller, valid window -> still answers
  begin
    g := public.get_ci_loyalty_programmes_v1(biz, d_from, d_to);
    if g is null then
      insert into _fail values ('SI8','get_ci_loyalty_programmes_v1: valid window returned a null payload for the entitled caller');
    end if;
  exception when others then
    get stacked diagnostics v_err = returned_sqlstate;
    insert into _fail values ('SI8', format('get_ci_loyalty_programmes_v1: valid window was refused (%s) for the entitled caller', v_err));
  end;

  -- SS8 -- stranger, inverted window -> 42501 (gate fires before the period guard)
  perform set_config('request.jwt.claims',
    json_build_object('sub',u_stranger,'role','authenticated')::text, true);
  begin
    g := public.get_ci_loyalty_programmes_v1(biz, d_to, d_from);
    insert into _fail values ('SS8','get_ci_loyalty_programmes_v1: the stranger reached the reader at all');
  exception when insufficient_privilege then null;
           when others then
             get stacked diagnostics v_err = returned_sqlstate;
             insert into _fail values ('SS8', format('get_ci_loyalty_programmes_v1: expected 42501, got %s', v_err));
  end;

  ---------------------------------------------------------------------------
  -- marketing_funnel: public.get_ci_marketing_funnel_v1
  ---------------------------------------------------------------------------
  perform set_config('request.jwt.claims', json_build_object(
      'sub', u_sa, 'role','authenticated',
      'amr', json_build_array(json_build_object('method','oauth')),
      'app_metadata', json_build_object('providers', json_build_array('google'))
    )::text, true);
  -- SA9 -- entitled caller, inverted window -> 22023 invalid_report_window
  begin
    g := public.get_ci_marketing_funnel_v1(biz, d_to, d_from);
    insert into _fail values ('SA9','get_ci_marketing_funnel_v1: inverted window did not raise for the entitled caller');
  exception when others then
    get stacked diagnostics v_err = returned_sqlstate;
    if v_err <> '22023' then
      insert into _fail values ('SA9', format('get_ci_marketing_funnel_v1: expected 22023, got %s', v_err));
    end if;
  end;
  -- SI9 -- entitled caller, valid window -> still answers
  begin
    g := public.get_ci_marketing_funnel_v1(biz, d_from, d_to);
    if g is null then
      insert into _fail values ('SI9','get_ci_marketing_funnel_v1: valid window returned a null payload for the entitled caller');
    end if;
  exception when others then
    get stacked diagnostics v_err = returned_sqlstate;
    insert into _fail values ('SI9', format('get_ci_marketing_funnel_v1: valid window was refused (%s) for the entitled caller', v_err));
  end;

  -- SS9 -- stranger, inverted window -> 42501 (gate fires before the period guard)
  perform set_config('request.jwt.claims',
    json_build_object('sub',u_stranger,'role','authenticated')::text, true);
  begin
    g := public.get_ci_marketing_funnel_v1(biz, d_to, d_from);
    insert into _fail values ('SS9','get_ci_marketing_funnel_v1: the stranger reached the reader at all');
  exception when insufficient_privilege then null;
           when others then
             get stacked diagnostics v_err = returned_sqlstate;
             insert into _fail values ('SS9', format('get_ci_marketing_funnel_v1: expected 42501, got %s', v_err));
  end;

  ---------------------------------------------------------------------------
  -- rebooking: public.get_ci_rebooking_v1
  ---------------------------------------------------------------------------
  perform set_config('request.jwt.claims', json_build_object(
      'sub', u_sa, 'role','authenticated',
      'amr', json_build_array(json_build_object('method','oauth')),
      'app_metadata', json_build_object('providers', json_build_array('google'))
    )::text, true);
  -- SA10 -- entitled caller, inverted window -> 22023 invalid_report_window
  begin
    g := public.get_ci_rebooking_v1(biz, d_to, d_from);
    insert into _fail values ('SA10','get_ci_rebooking_v1: inverted window did not raise for the entitled caller');
  exception when others then
    get stacked diagnostics v_err = returned_sqlstate;
    if v_err <> '22023' then
      insert into _fail values ('SA10', format('get_ci_rebooking_v1: expected 22023, got %s', v_err));
    end if;
  end;
  -- SI10 -- entitled caller, valid window -> still answers
  begin
    g := public.get_ci_rebooking_v1(biz, d_from, d_to);
    if g is null then
      insert into _fail values ('SI10','get_ci_rebooking_v1: valid window returned a null payload for the entitled caller');
    end if;
  exception when others then
    get stacked diagnostics v_err = returned_sqlstate;
    insert into _fail values ('SI10', format('get_ci_rebooking_v1: valid window was refused (%s) for the entitled caller', v_err));
  end;

  -- SS10 -- stranger, inverted window -> 42501 (gate fires before the period guard)
  perform set_config('request.jwt.claims',
    json_build_object('sub',u_stranger,'role','authenticated')::text, true);
  begin
    g := public.get_ci_rebooking_v1(biz, d_to, d_from);
    insert into _fail values ('SS10','get_ci_rebooking_v1: the stranger reached the reader at all');
  exception when insufficient_privilege then null;
           when others then
             get stacked diagnostics v_err = returned_sqlstate;
             insert into _fail values ('SS10', format('get_ci_rebooking_v1: expected 42501, got %s', v_err));
  end;

  ---------------------------------------------------------------------------
  -- retention_windows: public.get_ci_retention_windows_v1
  ---------------------------------------------------------------------------
  perform set_config('request.jwt.claims', json_build_object(
      'sub', u_sa, 'role','authenticated',
      'amr', json_build_array(json_build_object('method','oauth')),
      'app_metadata', json_build_object('providers', json_build_array('google'))
    )::text, true);
  -- SA11 -- entitled caller, inverted window -> 22023 invalid_report_window
  begin
    g := public.get_ci_retention_windows_v1(biz, d_to, d_from);
    insert into _fail values ('SA11','get_ci_retention_windows_v1: inverted window did not raise for the entitled caller');
  exception when others then
    get stacked diagnostics v_err = returned_sqlstate;
    if v_err <> '22023' then
      insert into _fail values ('SA11', format('get_ci_retention_windows_v1: expected 22023, got %s', v_err));
    end if;
  end;
  -- SI11 -- entitled caller, valid window -> still answers
  begin
    g := public.get_ci_retention_windows_v1(biz, d_from, d_to);
    if g is null then
      insert into _fail values ('SI11','get_ci_retention_windows_v1: valid window returned a null payload for the entitled caller');
    end if;
  exception when others then
    get stacked diagnostics v_err = returned_sqlstate;
    insert into _fail values ('SI11', format('get_ci_retention_windows_v1: valid window was refused (%s) for the entitled caller', v_err));
  end;

  -- SS11 -- stranger, inverted window -> 42501 (gate fires before the period guard)
  perform set_config('request.jwt.claims',
    json_build_object('sub',u_stranger,'role','authenticated')::text, true);
  begin
    g := public.get_ci_retention_windows_v1(biz, d_to, d_from);
    insert into _fail values ('SS11','get_ci_retention_windows_v1: the stranger reached the reader at all');
  exception when insufficient_privilege then null;
           when others then
             get stacked diagnostics v_err = returned_sqlstate;
             insert into _fail values ('SS11', format('get_ci_retention_windows_v1: expected 42501, got %s', v_err));
  end;

  ---------------------------------------------------------------------------
  -- staff_identity: public.get_ci_staff_identity_v1
  ---------------------------------------------------------------------------
  perform set_config('request.jwt.claims', json_build_object(
      'sub', u_sa, 'role','authenticated',
      'amr', json_build_array(json_build_object('method','oauth')),
      'app_metadata', json_build_object('providers', json_build_array('google'))
    )::text, true);
  -- SA12 -- entitled caller, inverted window -> 22023 invalid_report_window
  begin
    g := public.get_ci_staff_identity_v1(biz, d_to, d_from);
    insert into _fail values ('SA12','get_ci_staff_identity_v1: inverted window did not raise for the entitled caller');
  exception when others then
    get stacked diagnostics v_err = returned_sqlstate;
    if v_err <> '22023' then
      insert into _fail values ('SA12', format('get_ci_staff_identity_v1: expected 22023, got %s', v_err));
    end if;
  end;
  -- SI12 -- entitled caller, valid window -> still answers
  begin
    g := public.get_ci_staff_identity_v1(biz, d_from, d_to);
    if g is null then
      insert into _fail values ('SI12','get_ci_staff_identity_v1: valid window returned a null payload for the entitled caller');
    end if;
  exception when others then
    get stacked diagnostics v_err = returned_sqlstate;
    insert into _fail values ('SI12', format('get_ci_staff_identity_v1: valid window was refused (%s) for the entitled caller', v_err));
  end;

  -- SS12 -- stranger, inverted window -> 42501 (gate fires before the period guard)
  perform set_config('request.jwt.claims',
    json_build_object('sub',u_stranger,'role','authenticated')::text, true);
  begin
    g := public.get_ci_staff_identity_v1(biz, d_to, d_from);
    insert into _fail values ('SS12','get_ci_staff_identity_v1: the stranger reached the reader at all');
  exception when insufficient_privilege then null;
           when others then
             get stacked diagnostics v_err = returned_sqlstate;
             insert into _fail values ('SS12', format('get_ci_staff_identity_v1: expected 42501, got %s', v_err));
  end;

  ---------------------------------------------------------------------------
  -- staff_performance: public.get_ci_staff_performance_v1
  ---------------------------------------------------------------------------
  perform set_config('request.jwt.claims', json_build_object(
      'sub', u_sa, 'role','authenticated',
      'amr', json_build_array(json_build_object('method','oauth')),
      'app_metadata', json_build_object('providers', json_build_array('google'))
    )::text, true);
  -- SA13 -- entitled caller, inverted window -> 22023 invalid_report_window
  begin
    g := public.get_ci_staff_performance_v1(biz, d_to, d_from);
    insert into _fail values ('SA13','get_ci_staff_performance_v1: inverted window did not raise for the entitled caller');
  exception when others then
    get stacked diagnostics v_err = returned_sqlstate;
    if v_err <> '22023' then
      insert into _fail values ('SA13', format('get_ci_staff_performance_v1: expected 22023, got %s', v_err));
    end if;
  end;
  -- SI13 -- entitled caller, valid window -> still answers
  begin
    g := public.get_ci_staff_performance_v1(biz, d_from, d_to);
    if g is null then
      insert into _fail values ('SI13','get_ci_staff_performance_v1: valid window returned a null payload for the entitled caller');
    end if;
  exception when others then
    get stacked diagnostics v_err = returned_sqlstate;
    insert into _fail values ('SI13', format('get_ci_staff_performance_v1: valid window was refused (%s) for the entitled caller', v_err));
  end;

  -- SS13 -- stranger, inverted window -> 42501 (gate fires before the period guard)
  perform set_config('request.jwt.claims',
    json_build_object('sub',u_stranger,'role','authenticated')::text, true);
  begin
    g := public.get_ci_staff_performance_v1(biz, d_to, d_from);
    insert into _fail values ('SS13','get_ci_staff_performance_v1: the stranger reached the reader at all');
  exception when insufficient_privilege then null;
           when others then
             get stacked diagnostics v_err = returned_sqlstate;
             insert into _fail values ('SS13', format('get_ci_staff_performance_v1: expected 42501, got %s', v_err));
  end;

  perform set_config('request.jwt.claims', null, true);
end
$v726$;

select case when count(*)=0
            then 'PASS -- v726: period validation on all 13 readers, gate-before-guard preserved'
            else 'FAIL' end as verdict,
       count(*) as failures from _fail;
select k, v from _fail order by k, v;

do $verdict$
declare n integer; d text;
begin
  select count(*), string_agg(format('%s: %s', f.k, f.v), E'\n  ' order by f.k, f.v)
    into n, d from _fail f;
  if n > 0 then raise exception 'v726: % assertion(s) failed:%  %', n, E'\n', d; end if;
end
$verdict$;

rollback;
