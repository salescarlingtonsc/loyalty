-- EXECUTED acceptance fixture for nestly_v629 (first-acquisition provenance) and
-- nestly_v638 (demographics authority), read through the nestly_v650/v667 CI layer.
--
-- Named v629 because it proves behaviour ABOVE the v422 baseline watermark: `first_acquired_via`
-- / `first_acquired_evidence` do not exist in the baseline snapshot at all, so every assertion
-- below is `n/a` in the baseline phase and gated entirely on the migrated run
-- (`--migrated-only`). See docs/qa/CI-CORPUS-FIXTURE-GUIDE.md for the harness, the impersonation
-- recipes, and the four traps this fixture was built to avoid.
--
-- SCOPE. Five independently-keyed claims:
--   A1 every acquisition path is governed — one client per CHECK-allowed value, stored and
--      reported back by get_ci_acquisition_v1 under the right bucket with exact counts.
--   A2 unknown is first-class, never NULL, never guessed — the BEFORE INSERT trigger default.
--   A3 the acquisition fact is write-once — v629's guard trigger behaviour, asserted as it
--      actually is (a 42501 raise), not as a wished-for silent preserve.
--   A4 counts reconcile exactly — per-source and total, with a synthetic client excluded from
--      both.
--   A5 demographic coverage is MEASURED, not assumed — app.customer_demographics_v1 is a
--      single-customer lookup with no aggregate. There is no function anywhere in v638 that
--      reports coverage across a business. This fixture proves what the single-customer reader
--      genuinely does (age band from a birth date, missing-birth-date handling, gender masking
--      of 'prefer_not_to_say', and the customer-attested-wins-on-conflict rule) and states
--      explicitly that aggregate coverage is NOT computable today — see the A5 block comment.
--
-- TRUTH TABLE (spelled out before any assertion runs):
--   A1: nine non-'unknown' CHECK values, one client each, via GUC app.first_acquired_via —
--       staff_created, qr_join, qr_scan_provisioned, portal_booking, csv_import,
--       wallet_signup, referral, campaign, walk_in_till.
--       Each must land in clients with evidence='recorded_at_creation', and each must appear
--       in get_ci_acquisition_v1's `sources` array as exactly one row with customers=1.
--   A2: one client inserted with the GUC unset/blank -> first_acquired_via='unknown',
--       first_acquired_evidence='unknown'. Never NULL.
--   A3: the A1 'staff_created' client is UPDATEd toward via='campaign' with evidence left
--       unchanged (a same-value-shape mutation attempt) -> must raise 42501, and the row's
--       first_acquired_via must still read 'staff_created' afterward.
--   A4: 9 (A1) + 1 (A2 unknown) = 10 non-synthetic clients seeded total. A synthetic 11th
--       client is inserted with via='campaign'. get_ci_acquisition_v1 must report:
--         - total customers summed across `sources` = 10 (not 11 — the synthetic is excluded)
--         - the 'campaign' bucket = 1 (not 2 — the synthetic 'campaign' row must not count)
--   A5: four clients, business-membership caller (super admin, since is_salon_member is not
--       set up here and app.customer_demographics_v1's gate accepts either):
--         - cl_band: birth_date = exactly 22 years ago, no wallet link -> age_band='20_24',
--           source='staff_entered'.
--         - cl_none: no birth_date, no gender, no wallet link -> age_band=NULL, gender=NULL,
--           gender_declared=false, source='none'.
--         - cl_pnts: gender='prefer_not_to_say', no wallet link -> gender comes back NULL
--           (masked) but gender_declared=true, source='staff_entered'.
--         - cl_conflict: staff-entered birth_date (age 45 -> '41_50') and gender='male'; a
--           VERIFIED wallet link with a DIFFERENT birth_date (age 28 -> '25_30') and a
--           DIFFERENT gender='female' -> the reader must return the WALLET's values
--           (age_band='25_30', gender='female'), source='customer_attested', conflict=true.

\set ON_ERROR_STOP on

begin;

create temp table _fail(k text, v text) on commit drop;

do $v629$
declare
  biz         uuid := '00000000-0000-4000-8000-000000062901';
  u_sa        uuid := '00000000-0000-4000-8000-000000062911';
  u_wallet    uuid := '00000000-0000-4000-8000-000000062912';

  cl_staff    uuid := '00000000-0000-4000-8000-000000062921';
  cl_qrjoin   uuid := '00000000-0000-4000-8000-000000062922';
  cl_qrscan   uuid := '00000000-0000-4000-8000-000000062923';
  cl_portal   uuid := '00000000-0000-4000-8000-000000062924';
  cl_csv      uuid := '00000000-0000-4000-8000-000000062925';
  cl_wallet   uuid := '00000000-0000-4000-8000-000000062926';
  cl_referral uuid := '00000000-0000-4000-8000-000000062927';
  cl_campaign uuid := '00000000-0000-4000-8000-000000062928';
  cl_walkin   uuid := '00000000-0000-4000-8000-000000062929';
  cl_unknown  uuid := '00000000-0000-4000-8000-00000006292a';
  cl_synth    uuid := '00000000-0000-4000-8000-00000006292b';

  cl_band     uuid := '00000000-0000-4000-8000-000000062931';
  cl_none     uuid := '00000000-0000-4000-8000-000000062932';
  cl_pnts     uuid := '00000000-0000-4000-8000-000000062933';
  cl_conflict uuid := '00000000-0000-4000-8000-000000062934';

  identity_id uuid := '00000000-0000-4000-8000-000000062941';
  link_id     uuid := '00000000-0000-4000-8000-000000062942';

  d_from      date := current_date - 30;
  d_to        date := current_date;

  g           jsonb;
  v_err       text;
  v_row       record;
  v_total     bigint;
  v_campaign_n int;
  v_via       text;
  v_evidence  text;

  -- the nine non-'unknown' CHECK-allowed values the v629 trigger actually recognizes
  v_vias      constant text[] := array[
                 'staff_created','qr_join','qr_scan_provisioned','portal_booking',
                 'csv_import','wallet_signup','referral','campaign','walk_in_till'];
  v_client_ids constant uuid[] := array[
                 cl_staff, cl_qrjoin, cl_qrscan, cl_portal, cl_csv,
                 cl_wallet, cl_referral, cl_campaign, cl_walkin];
  i           int;
begin
  ---------------------------------------------------------------------------
  -- actors: a Google-SSO super admin (v625) so the v667 CI gate is satisfied
  -- throughout without also standing up a full operational business.
  ---------------------------------------------------------------------------
  insert into auth.users (id, email) values
    (u_sa, 'zz-v629-sa@example.test'),
    (u_wallet, 'zz-v629-wallet@example.test')
    on conflict (id) do nothing;
  insert into public.super_admins (user_id, email)
    values (u_sa, 'zz-v629-sa@example.test') on conflict do nothing;

  insert into public.businesses (id, name, slug, enabled_modules) values
    (biz, 'ZZ v629 corpus fixture', 'zz-v629-corpus', array['dashboard','clients','reports']);

  perform set_config('request.jwt.claims', json_build_object(
      'sub', u_sa, 'role','authenticated',
      'amr', json_build_array(json_build_object('method','oauth')),
      'app_metadata', json_build_object('providers', json_build_array('google'))
    )::text, true);

  ---------------------------------------------------------------------------
  -- PRECONDITION. The super admin must genuinely be entitled to read this firm's
  -- Customer Intelligence before any A1/A4 assertion is meaningful — otherwise a
  -- refusal (or an accidentally-empty payload) would prove nothing about A1/A4 and
  -- every count assertion below would pass vacuously against an error.
  ---------------------------------------------------------------------------
  begin
    g := public.get_ci_acquisition_v1(biz, d_from, d_to);
    if g is null or g->'sources' is null then
      insert into _fail values ('A0-pre', 'the super admin got no acquisition payload; A1/A4 would be vacuous');
    end if;
  exception when others then
    get stacked diagnostics v_err = returned_sqlstate;
    insert into _fail values ('A0-pre', format('the super admin was refused (%s); A1/A4 would be vacuous', v_err));
  end;

  ---------------------------------------------------------------------------
  -- A1 — every acquisition path is governed. One client per non-'unknown' CHECK
  -- value, via the writer-published GUC the v629 BEFORE INSERT trigger reads.
  ---------------------------------------------------------------------------
  for i in 1 .. array_length(v_vias, 1) loop
    perform set_config('app.first_acquired_via', v_vias[i], true);
    insert into public.clients (id, business_id, full_name)
      values (v_client_ids[i], biz, 'ZZ v629 ' || v_vias[i]);
    perform set_config('app.first_acquired_via', '', true);

    select c.first_acquired_via, c.first_acquired_evidence
      into v_via, v_evidence
      from public.clients c where c.id = v_client_ids[i];
    if v_via <> v_vias[i] then
      insert into _fail values ('A1-store',
        format('client seeded via GUC %s stored first_acquired_via=%s', v_vias[i], v_via));
    end if;
    if v_evidence <> 'recorded_at_creation' then
      insert into _fail values ('A1-store',
        format('client seeded via GUC %s stored evidence=%s, expected recorded_at_creation',
               v_vias[i], v_evidence));
    end if;
  end loop;

  ---------------------------------------------------------------------------
  -- A2 — unknown is first-class, never NULL, never guessed. GUC left unset.
  ---------------------------------------------------------------------------
  perform set_config('app.first_acquired_via', '', true);
  insert into public.clients (id, business_id, full_name)
    values (cl_unknown, biz, 'ZZ v629 unknown-path');

  select c.first_acquired_via, c.first_acquired_evidence into v_via, v_evidence
    from public.clients c where c.id = cl_unknown;
  if v_via is distinct from 'unknown' then
    insert into _fail values ('A2', format('unset-GUC insert stored first_acquired_via=%s, expected the literal ''unknown''', coalesce(v_via,'<NULL>')));
  end if;
  if v_evidence is distinct from 'unknown' then
    insert into _fail values ('A2', format('unset-GUC insert stored evidence=%s, expected ''unknown''', coalesce(v_evidence,'<NULL>')));
  end if;

  ---------------------------------------------------------------------------
  -- A3 — the acquisition fact is write-once. v629's guard raises 42501 on an
  -- attempted mutation that isn't the unknown->backfilled_provable upgrade or a
  -- ref-only erasure; asserting THAT behaviour (not an invented silent-preserve).
  ---------------------------------------------------------------------------
  begin
    update public.clients set first_acquired_via = 'campaign' where id = cl_staff;
    insert into _fail values ('A3', 'update from staff_created to campaign was NOT rejected — write-once guard did not fire');
  exception
    when insufficient_privilege then
      null; -- 42501, the guard's documented behaviour
    when others then
      get stacked diagnostics v_err = returned_sqlstate;
      insert into _fail values ('A3', format('update raised %s, expected 42501 (insufficient_privilege)', v_err));
  end;
  select c.first_acquired_via into v_via from public.clients c where c.id = cl_staff;
  if v_via <> 'staff_created' then
    insert into _fail values ('A3-survive',
      format('after the rejected update, cl_staff.first_acquired_via reads %s, expected the original staff_created', v_via));
  end if;

  ---------------------------------------------------------------------------
  -- A4 — counts reconcile exactly. Seed the synthetic client (must be excluded
  -- from both the per-source bucket and the total), then read.
  ---------------------------------------------------------------------------
  perform set_config('app.first_acquired_via', 'campaign', true);
  insert into public.clients (id, business_id, full_name, is_synthetic)
    values (cl_synth, biz, 'ZZ v629 synthetic campaign client', true);
  perform set_config('app.first_acquired_via', '', true);

  begin
    g := public.get_ci_acquisition_v1(biz, d_from, d_to);
  exception when others then
    get stacked diagnostics v_err = returned_sqlstate;
    insert into _fail values ('A4', format('get_ci_acquisition_v1 raised %s', v_err));
    g := null;
  end;

  if g is not null then
    select coalesce(sum((rec->>'customers')::bigint), -1) into v_total
      from jsonb_array_elements(g->'sources') rec;
    if v_total <> 10 then
      insert into _fail values ('A4-total',
        format('sources summed to %s customers, expected exactly 10 (9 A1 + 1 A2 unknown; synthetic excluded)', v_total));
    end if;

    select coalesce((rec->>'customers')::int, -1) into v_campaign_n
      from jsonb_array_elements(g->'sources') rec
     where rec->>'via' = 'campaign';
    if v_campaign_n <> 1 then
      insert into _fail values ('A4-campaign-bucket',
        format('the campaign bucket reported %s customers, expected exactly 1 (the synthetic campaign client must be excluded)', v_campaign_n));
    end if;

    -- Every A1 bucket must also be exactly 1, and each of the nine vias must appear.
    for i in 1 .. array_length(v_vias, 1) loop
      if v_vias[i] = 'campaign' then continue; end if; -- already asserted above with its own message
      select coalesce((rec->>'customers')::int, -1) into v_campaign_n
        from jsonb_array_elements(g->'sources') rec
       where rec->>'via' = v_vias[i] and rec->>'evidence' = 'recorded_at_creation';
      if v_campaign_n <> 1 then
        insert into _fail values ('A1-report',
          format('bucket via=%s evidence=recorded_at_creation reported %s customers, expected exactly 1',
                 v_vias[i], v_campaign_n));
      end if;
    end loop;

    -- The 'unknown' bucket (A2's client) must also read exactly 1.
    select coalesce((rec->>'customers')::int, -1) into v_campaign_n
      from jsonb_array_elements(g->'sources') rec
     where rec->>'via' = 'unknown' and rec->>'evidence' = 'unknown';
    if v_campaign_n <> 1 then
      insert into _fail values ('A2-report',
        format('bucket via=unknown evidence=unknown reported %s customers, expected exactly 1', v_campaign_n));
    end if;
  end if;

  ---------------------------------------------------------------------------
  -- A5 — demographic coverage. app.customer_demographics_v1 is a SINGLE-CUSTOMER
  -- lookup. Grepping nestly_v638 and everything that came after it (through the
  -- v422 baseline watermark to the current head) turns up no function that
  -- aggregates age-band or gender coverage across a business's client list —
  -- get_ci_acquisition_v1 / get_ci_category_mix_v1 / get_ci_category_customers_v1
  -- / get_ci_funnel_v1 / get_ci_contactability_v1 / get_ci_engagement_v1 (v650/v667)
  -- carry no demographic dimension at all. So this fixture proves exactly what
  -- v638 built — the single-customer reader's four behaviours — and asserts
  -- nothing about a business-wide figure, because no such figure exists to read.
  -- FINDING (not a defect — a scope note): "demographics authority" in v638's own
  -- filename is accurate for the single-customer case but does not extend to
  -- aggregate coverage; a Customer Intelligence page wanting "% of customers with
  -- a birth date on file" cannot get it from any RPC that exists today.
  ---------------------------------------------------------------------------
  insert into public.clients (id, business_id, full_name, birth_date, gender) values
    (cl_band, biz, 'ZZ v629 band-only', current_date - interval '22 years', null),
    (cl_none, biz, 'ZZ v629 no-demographics', null, null),
    (cl_pnts, biz, 'ZZ v629 prefer-not-to-say', null, 'prefer_not_to_say'),
    (cl_conflict, biz, 'ZZ v629 conflict', current_date - interval '45 years', 'male');

  -- cl_band: birth_date only, no wallet link -> age_band='20_24', staff_entered.
  g := app.customer_demographics_v1(biz, cl_band);
  if g->>'age_band' <> '20_24' then
    insert into _fail values ('A5-band', format('cl_band age_band=%s, expected 20_24', coalesce(g->>'age_band','<NULL>')));
  end if;
  if g->>'source' <> 'staff_entered' then
    insert into _fail values ('A5-band', format('cl_band source=%s, expected staff_entered', coalesce(g->>'source','<NULL>')));
  end if;
  if coalesce((g->>'gender_declared')::boolean, true) <> false then
    insert into _fail values ('A5-band', 'cl_band gender_declared should be false (no gender was ever set)');
  end if;

  -- cl_none: nothing on file -> age_band NULL, gender NULL, gender_declared false, source 'none'.
  g := app.customer_demographics_v1(biz, cl_none);
  if g->'age_band' is not null and g->>'age_band' is not null then
    insert into _fail values ('A5-none', format('cl_none age_band=%s, expected null', g->>'age_band'));
  end if;
  if g->'gender' is not null and g->>'gender' is not null then
    insert into _fail values ('A5-none', format('cl_none gender=%s, expected null', g->>'gender'));
  end if;
  if coalesce((g->>'gender_declared')::boolean, true) <> false then
    insert into _fail values ('A5-none', 'cl_none gender_declared should be false');
  end if;
  if g->>'source' <> 'none' then
    insert into _fail values ('A5-none', format('cl_none source=%s, expected none', coalesce(g->>'source','<NULL>')));
  end if;

  -- cl_pnts: gender='prefer_not_to_say' -> masked to NULL in the payload, but declared=true.
  g := app.customer_demographics_v1(biz, cl_pnts);
  if g->'gender' is not null and g->>'gender' is not null then
    insert into _fail values ('A5-pnts', format('cl_pnts gender leaked as %s; prefer_not_to_say must come back masked as null', g->>'gender'));
  end if;
  if coalesce((g->>'gender_declared')::boolean, false) <> true then
    insert into _fail values ('A5-pnts', 'cl_pnts gender_declared should be true (a value WAS declared, just withheld)');
  end if;

  -- cl_conflict: staff-entered (45yo/male) vs a VERIFIED wallet link with different
  -- values (28yo/female) -> the wallet's attested values must win, and conflict=true.
  insert into public.customer_identities (id, auth_user_id) values (identity_id, u_wallet);
  perform set_config('app.c42_profile_identity', identity_id::text, true);
  insert into public.customer_profiles (identity_id, auth_user_id, full_name, birth_date, gender) values
    (identity_id, u_wallet, 'ZZ v629 wallet identity', current_date - interval '28 years', 'female');
  perform set_config('app.c42_profile_identity', '', true);
  perform set_config('app.customer_link_insert_id', link_id::text, true);
  insert into public.customer_links
    (id, business_id, identity_id, auth_user_id, client_id, state, verification_method, verified_at) values
    (link_id, biz, identity_id, u_wallet, cl_conflict, 'verified', 'email_claim', now());
  perform set_config('app.customer_link_insert_id', '', true);

  g := app.customer_demographics_v1(biz, cl_conflict);
  if g->>'age_band' <> '25_30' then
    insert into _fail values ('A5-conflict',
      format('cl_conflict age_band=%s, expected 25_30 (the wallet-attested 28yo, not the staff-entered 45yo)',
             coalesce(g->>'age_band','<NULL>')));
  end if;
  if g->>'gender' <> 'female' then
    insert into _fail values ('A5-conflict',
      format('cl_conflict gender=%s, expected female (the wallet-attested value, not the staff-entered male)',
             coalesce(g->>'gender','<NULL>')));
  end if;
  if g->>'source' <> 'customer_attested' then
    insert into _fail values ('A5-conflict',
      format('cl_conflict source=%s, expected customer_attested', coalesce(g->>'source','<NULL>')));
  end if;
  if coalesce((g->>'conflict')::boolean, false) <> true then
    insert into _fail values ('A5-conflict', 'cl_conflict conflict flag should be true — wallet and staff-entered values disagree on both fields');
  end if;

  perform set_config('request.jwt.claims', null, true);
  perform set_config('app.first_acquired_via', '', true);
  perform set_config('app.first_acquired_ref', '', true);
end
$v629$;

select case when count(*)=0
            then 'PASS — v629 acquisition governance + v638 single-customer demographics hold'
            else 'FAIL' end as verdict,
       count(*) as failures from _fail;
select k, v from _fail order by k, v;

do $verdict$
declare n integer; d text;
begin
  select count(*), string_agg(format('%s: %s', f.k, f.v), E'\n  ' order by f.k, f.v)
    into n, d from _fail f;
  if n > 0 then raise exception 'v629: % assertion(s) failed:%  %', n, E'\n', d; end if;
end
$verdict$;

rollback;
