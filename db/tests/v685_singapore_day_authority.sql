-- Rollback-only v685 acceptance suite — one Singapore day authority in SQL.
--
-- OWNER RULING (2026-09-02): every date and time in Peekaa is Asia/Singapore, never UTC.
-- The live session TimeZone is UTC, so `current_date`, `<timestamptz>::date`,
-- `date_trunc('day', …)` and `<date>::timestamptz` were all deciding the UTC day — wrong for
-- the first eight hours of every Singapore day.
--
-- HOW THIS SUITE MAKES THAT DETERMINISTIC. A UTC-vs-Singapore defect only shows itself for
-- eight hours out of twenty-four, and now() cannot be moved. So §3 does not wait for the
-- window: it CHOOSES a session TimeZone whose calendar day is provably not today's Singapore
-- day. Two candidates are enough to cover the clock — at Singapore hour h, Etc/GMT+12 (UTC-12)
-- is a day behind whenever h < 20, and Etc/GMT-14 (UTC+14) is a day ahead whenever h >= 10, so
-- one of the two always differs — and the suite asserts the difference before relying on it.
-- Under that session zone `current_date` is provably wrong and `app.sg_today()` is provably
-- right, at any hour, on any day.
--
-- SECTION 1 — the authority itself.
--   S1-T1  app.sg_day() splits the day at 16:00 UTC, which is Singapore midnight.
--   S1-T2  app.sg_day_start() is the instant a Singapore day begins, and round-trips.
--   S1-T3  app.sg_month() buckets by the Singapore month, not the UTC one.
--   S1-T4  app.sg_today() ignores the session TimeZone entirely.
--   S1-T5  Volatility, search_path and ACL: sg_today STABLE, the other three IMMUTABLE, all
--          four on the canonical search_path and executable by no client role.
--
-- SECTION 2 — every patched reader and writer decides its day through the authority.
--   S2-T1  None of the twelve bodies still carries the UTC-day text v685 removed.
--   S2-T2  Each of the twelve now calls app.sg_today/sg_day/sg_day_start/sg_month.
--   S2-T3  Signatures and grants are exactly what they were.
--
-- SECTION 3 — behaviour, under a session zone whose day is NOT the Singapore day.
--   S3-T1  D-03 platform_set_workspace_pause_v622 seeds due_date with the Singapore day.
--   S3-T2  D-12 sme_prospect_card_v76 stage_age_days is a Singapore-to-Singapore subtraction.
--   S3-T3  D-11 customer_demographics_v1 ages a customer on the Singapore day.
--   S3-T4  D-07 platform_conversion_funnel_v312 opens its window at Singapore midnight.
--   S3-T5  D-01 platform_get_subscription_operations_v156 "new this month" starts at
--          Singapore midnight on the 1st, not 08:00 SGT.
--
-- SECTION 4 — D-04 + D-05, the matched pair, in the PRODUCTION session zone (UTC).
--   S4-T1  app.v510_verified_initial_payment matches an invoice whose period falls on the
--          stored Singapore obligation day but on the PREVIOUS UTC day. This is the exact
--          instant the old reader rejected, and the reason the pair had to ship together.
--   S4-T2  convert_sme_prospect_v79 writes the obligation window as a Singapore day.
--
-- SECTION 5 — the two crons.
--   S5-T1  Where they are registered, both now fire inside the Singapore night.
--
-- Everything is inside one transaction that rolls back. Every tenant it needs is BUILT here,
-- never discovered — production has no guarantee of any of it.
begin;
create temporary table v685_evidence(test text, detail text) on commit drop;

-- =============================================================================================
-- SECTION 1 — the authority.
-- =============================================================================================
do $v685_s1$
declare
  v_probe timestamptz;
  v_zone text;
begin
  -- S1-T1 — 15:59:59 UTC is still the 2nd in Singapore; 16:00:00 UTC is already the 3rd.
  if app.sg_day('2026-09-02 15:59:59+00'::timestamptz) <> date '2026-09-02'
     or app.sg_day('2026-09-02 16:00:00+00'::timestamptz) <> date '2026-09-03' then
    raise exception 'S1-T1 FAIL: app.sg_day does not split the day at Singapore midnight';
  end if;
  insert into v685_evidence values('S1-T1','app.sg_day splits the day at 16:00 UTC = Singapore midnight');

  -- S1-T2 — the instant a Singapore day begins, and a clean round trip.
  if app.sg_day_start(date '2026-09-03') <> '2026-09-02 16:00:00+00'::timestamptz then
    raise exception 'S1-T2 FAIL: app.sg_day_start is not Singapore midnight';
  end if;
  for v_probe in
    select unnest(array['2026-01-01 00:00:00+00'::timestamptz,
                        '2026-06-30 16:00:00+00'::timestamptz,
                        '2026-12-31 15:59:59+00'::timestamptz])
  loop
    if app.sg_day(app.sg_day_start(app.sg_day(v_probe))) <> app.sg_day(v_probe) then
      raise exception 'S1-T2 FAIL: sg_day/sg_day_start do not round-trip at %', v_probe;
    end if;
  end loop;
  insert into v685_evidence values('S1-T2','app.sg_day_start is Singapore midnight and round-trips');

  -- S1-T3 — 2026-08-31 16:30 UTC is already September in Singapore.
  if app.sg_month('2026-08-31 16:30:00+00'::timestamptz) <> date '2026-09-01'
     or app.sg_month('2026-08-31 15:30:00+00'::timestamptz) <> date '2026-08-01' then
    raise exception 'S1-T3 FAIL: app.sg_month buckets by the UTC month';
  end if;
  insert into v685_evidence values('S1-T3','app.sg_month buckets by the Singapore month');

  -- S1-T4 — the authority answers the same day whatever the session thinks the zone is.
  foreach v_zone in array array['UTC','Etc/GMT+12','Etc/GMT-14','America/Los_Angeles'] loop
    perform set_config('TimeZone', v_zone, true);
    if app.sg_today() <> (now() at time zone 'Asia/Singapore')::date then
      raise exception 'S1-T4 FAIL: app.sg_today() moved with the session zone %', v_zone;
    end if;
  end loop;
  perform set_config('TimeZone', 'UTC', true);
  insert into v685_evidence values('S1-T4','app.sg_today() ignores the session TimeZone');

  -- S1-T5 — volatility, search_path, ACL.
  if (select provolatile from pg_proc p join pg_namespace n on n.oid = p.pronamespace
       where n.nspname = 'app' and p.proname = 'sg_today') <> 's' then
    raise exception 'S1-T5 FAIL: app.sg_today() must be STABLE — it reads now()';
  end if;
  if exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
              where n.nspname = 'app' and p.proname in ('sg_day','sg_day_start','sg_month')
                and p.provolatile <> 'i') then
    raise exception 'S1-T5 FAIL: sg_day/sg_day_start/sg_month must be IMMUTABLE';
  end if;
  if exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
              where n.nspname = 'app' and p.proname in ('sg_today','sg_day','sg_day_start','sg_month')
                and coalesce(array_to_string(p.proconfig, ','), '')
                    <> 'search_path=pg_catalog, public, app, pg_temp') then
    raise exception 'S1-T5 FAIL: an sg_* helper is not on the canonical search_path';
  end if;
  if has_function_privilege('anon', 'app.sg_today()', 'EXECUTE')
     or has_function_privilege('authenticated', 'app.sg_today()', 'EXECUTE')
     or has_function_privilege('anon', 'app.sg_day(timestamptz)', 'EXECUTE')
     or has_function_privilege('authenticated', 'app.sg_day(timestamptz)', 'EXECUTE')
     or has_function_privilege('anon', 'app.sg_day_start(date)', 'EXECUTE')
     or has_function_privilege('authenticated', 'app.sg_day_start(date)', 'EXECUTE')
     or has_function_privilege('anon', 'app.sg_month(timestamptz)', 'EXECUTE')
     or has_function_privilege('authenticated', 'app.sg_month(timestamptz)', 'EXECUTE') then
    raise exception 'S1-T5 FAIL: a client role can execute an sg_* helper';
  end if;
  -- The throwaway patch helper must not have survived the migration.
  if exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
              where n.nspname = 'app' and p.proname = 'v685_patch') then
    raise exception 'S1-T5 FAIL: app.v685_patch was left behind';
  end if;
  insert into v685_evidence values('S1-T5','volatility, search_path and ACL are as declared; the patch helper is gone');
end
$v685_s1$;

-- =============================================================================================
-- SECTION 2 — no patched body still decides a day in UTC.
-- =============================================================================================
do $v685_s2$
declare
  v_site record;
  v_def text;
begin
  for v_site in
    select * from (values
      -- signature, the UTC-day text that must be GONE, how many sg_* calls must be present
      ('public.platform_get_subscription_operations_v156(text,text,integer)',
       'current_period_end::date between current_date', 8),
      ('app.accrue_consultant_invoice_v78(uuid)',            'paid_at::date', 1),
      ('public.platform_set_workspace_pause_v622(uuid,boolean,text)',
       'coalesce(due_date, current_date)', 1),
      ('app.issue_bringback_for_business_v361(uuid)',        'max(s.created_at)::date', 1),
      ('public.platform_conversion_funnel_v312(date,date)',  'current_date', 3),
      ('public.refresh_growth_recommendation_v108(uuid,uuid)', 'date_trunc(''day'',v_now)', 1),
      ('public.platform_sweep_stalled_onboarding_v513(integer)', 'current_date::text', 1),
      -- Merged 2026-09-03: the CI wave's nestly_v674 split app.customer_demographics_v1 into a
      -- gate-free core plus a byte-thin wrapper that only delegates. The age computation, and
      -- therefore v685's Singapore-day call, now lives in the core; the wrapper's own body has no
      -- day logic at all. Both halves are pinned: the wrapper must still carry no UTC-day text,
      -- and the core must carry the authority. db/tests/executed/v744_merge_v685_semantics.sql
      -- additionally proves the wrapper delegates to that core after the whole chain.
      ('app.customer_demographics_v1(uuid,uuid)',            'age(current_date', 0),
      ('app.customer_demographics_core_v674(uuid,uuid)',     'age(current_date', 1),
      ('app.sme_prospect_card_v76(uuid)',                    'current_date-', 2),
      ('public.platform_generate_subscription_reminders_v156(date)',
       'r.current_period_end::date', 3),
      ('public.convert_sme_prospect_v79(uuid,bigint,text)',  'v_terms.accepted_at::date', 2),
      ('app.v510_verified_initial_payment(uuid)',            'invoice.period_start::date', 3)
    ) as t(signature, gone, min_sg_calls)
  loop
    v_def := pg_get_functiondef(v_site.signature::regprocedure);
    if position(v_site.gone in v_def) > 0 then
      raise exception 'S2-T1 FAIL: % still carries the UTC-day text "%"',
        v_site.signature, v_site.gone;
    end if;
    if (length(v_def) - length(replace(v_def, 'app.sg_', ''))) / length('app.sg_')
       < v_site.min_sg_calls then
      raise exception 'S2-T2 FAIL: % calls the Singapore day authority fewer than % time(s)',
        v_site.signature, v_site.min_sg_calls;
    end if;
  end loop;
  insert into v685_evidence values('S2-T1','no patched body still carries its UTC-day text');
  insert into v685_evidence values('S2-T2','every patched body decides its day through app.sg_*');

  -- S2-T3 — grants are exactly what they were before v685. A zone fix must move no permission.
  if not (has_function_privilege('authenticated','public.platform_get_subscription_operations_v156(text,text,integer)','EXECUTE')
      and has_function_privilege('authenticated','public.platform_generate_subscription_reminders_v156(date)','EXECUTE')
      and has_function_privilege('authenticated','public.platform_set_workspace_pause_v622(uuid,boolean,text)','EXECUTE')
      and has_function_privilege('authenticated','public.platform_conversion_funnel_v312(date,date)','EXECUTE')
      and has_function_privilege('authenticated','public.refresh_growth_recommendation_v108(uuid,uuid)','EXECUTE')
      and has_function_privilege('authenticated','public.convert_sme_prospect_v79(uuid,bigint,text)','EXECUTE')
      and has_function_privilege('authenticated','app.customer_demographics_v1(uuid,uuid)','EXECUTE')
      and has_function_privilege('service_role','public.platform_sweep_stalled_onboarding_v513(integer)','EXECUTE')) then
    raise exception 'S2-T3 FAIL: a grant that existed before v685 is gone';
  end if;
  if has_function_privilege('authenticated','public.platform_sweep_stalled_onboarding_v513(integer)','EXECUTE')
     or has_function_privilege('authenticated','app.accrue_consultant_invoice_v78(uuid)','EXECUTE')
     or has_function_privilege('authenticated','app.issue_bringback_for_business_v361(uuid)','EXECUTE')
     or has_function_privilege('authenticated','app.sme_prospect_card_v76(uuid)','EXECUTE')
     or has_function_privilege('authenticated','app.v510_verified_initial_payment(uuid)','EXECUTE')
     or has_function_privilege('anon','public.platform_conversion_funnel_v312(date,date)','EXECUTE') then
    raise exception 'S2-T3 FAIL: v685 widened a grant';
  end if;
  insert into v685_evidence values('S2-T3','signatures and grants are unchanged');
end
$v685_s2$;

-- =============================================================================================
-- SECTION 3 — behaviour, under a session zone whose calendar day is NOT the Singapore day.
-- =============================================================================================
do $v685_s3$
declare
  v_zone text;
  v_offset integer;                 -- session day minus Singapore day: +1 or -1, never 0
  v_admin uuid := gen_random_uuid();
  v_business uuid := gen_random_uuid();
  v_client uuid;
  v_company uuid; v_prospect uuid;
  v_birth date; v_expected_band text;
  v_card jsonb; v_demo jsonb; v_funnel jsonb; v_ops jsonb;
  v_before integer; v_after integer;
  v_sub_row public.business_subscription_lifecycle_v94%rowtype;
begin
  -- ------------------------------------------------------------------ the hostile session zone
  if (now() at time zone 'Etc/GMT+12')::date <> app.sg_today() then
    v_zone := 'Etc/GMT+12';
  else
    v_zone := 'Etc/GMT-14';
  end if;
  perform set_config('TimeZone', v_zone, true);
  v_offset := current_date - app.sg_today();
  if v_offset = 0 then
    raise exception 'S3 SETUP FAIL: no session zone separates the UTC-style day from the Singapore day';
  end if;

  -- ------------------------------------------------------------------ fixture
  insert into auth.users(instance_id,id,aud,role,email,encrypted_password,
                         email_confirmed_at,created_at,updated_at)
  values ('00000000-0000-0000-0000-000000000000',v_admin,'authenticated','authenticated',
          'v685-admin-'||substr(v_admin::text,1,8)||'@example.test','',now(),now(),now());
  insert into public.super_admins(user_id,email,note)
  values (v_admin,'v685-admin-'||substr(v_admin::text,1,8)||'@example.test','v685 rollback fixture');

  insert into public.businesses(id,name,slug,industry,enabled_modules,points_mode)
  values (v_business,'V685 Fixture Tenant',
          'v685-sgday-'||substr(v_business::text,1,8),'retail',
          array['dashboard','clients','sales'],'redeem');
  update public.business_workspace_controls_v94
     set approval_status='approved', version=version+1, decided_at=now(), updated_at=now(),
         decision_reason='v685 rollback fixture'
   where business_id = v_business;
  update public.business_subscription_lifecycle_v94
     set workspace_paused=false where business_id = v_business;
  insert into public.subscriptions(business_id) values (v_business) on conflict do nothing;

  perform set_config('request.jwt.claims', json_build_object(
    'sub', v_admin::text, 'role', 'authenticated',
    'amr', json_build_array(json_build_object('method','oauth')),
    'app_metadata', json_build_object('providers', json_build_array('google')))::text, true);

  -- ------------------------------------------------------------------ S3-T1 (D-03)
  perform public.platform_set_workspace_pause_v622(
    v_business, true, 'v685 rollback fixture — proving the overdue clock starts on the Singapore day');
  select * into v_sub_row from public.business_subscription_lifecycle_v94 where business_id = v_business;
  if v_sub_row.due_date <> app.sg_today() then
    raise exception 'S3-T1 FAIL: pause seeded due_date % — the Singapore day is %',
      v_sub_row.due_date, app.sg_today();
  end if;
  insert into v685_evidence values('S3-T1','the workspace pause seeds due_date with the Singapore day');

  -- ------------------------------------------------------------------ S3-T2 (D-12)
  insert into public.sme_companies(legal_name) values ('V685 Fixture Tenant Pte Ltd')
    returning id into v_company;
  insert into public.sme_prospects(company_id, ownership_state, legacy_stage_raw, priority,
                                   stage_entered_at, created_at)
  values (v_company, 'closed', 'v685 rollback fixture', 'normal',
          app.sg_day_start(app.sg_today() - 5), app.sg_day_start(app.sg_today() - 5))
  returning id into v_prospect;

  v_card := app.sme_prospect_card_v76(v_prospect);
  if (v_card->>'stage_age_days')::integer <> 5 then
    raise exception 'S3-T2 FAIL: stage_age_days is % for a stage entered at Singapore midnight five days ago',
      v_card->>'stage_age_days';
  end if;
  insert into v685_evidence values('S3-T2','stage_age_days subtracts a Singapore day from a Singapore day');

  -- ------------------------------------------------------------------ S3-T3 (D-11)
  -- Pick the birthday so the session zone lands the customer in the WRONG age band, whichever
  -- side of the Singapore day that zone happens to be on. The bands break between 30 and 31.
  if v_offset = 1 then
    v_birth := (app.sg_today() - interval '31 years' + interval '1 day')::date;  -- truly 30
    v_expected_band := '25_30';
  else
    v_birth := (app.sg_today() - interval '31 years')::date;                     -- truly 31
    v_expected_band := '31_40';
  end if;
  insert into public.clients(business_id, full_name, phone, birth_date)
  values (v_business, 'V685 Birthday Customer', '81000685', v_birth)
  returning id into v_client;

  v_demo := app.customer_demographics_v1(v_business, v_client);
  if v_demo->>'age_band' <> v_expected_band then
    raise exception 'S3-T3 FAIL: age band is % for a customer born on %; the Singapore day gives %',
      v_demo->>'age_band', v_birth, v_expected_band;
  end if;
  insert into v685_evidence values('S3-T3','a customer ages on the Singapore day, not the UTC one');

  -- ------------------------------------------------------------------ S3-T4 (D-07)
  -- BOTH ENDS of the window, because a session zone can only be wrong at one end at a time:
  -- the old code opened at `p_from::timestamptz` and closed at `p_to::timestamptz + 1 day`,
  -- both midnight in the SESSION zone. A zone behind Singapore loses the start of the day; a
  -- zone ahead of it loses the end. One prospect at Singapore 00:00 and one at Singapore 23:30
  -- therefore fail the old code whichever zone was selected above.
  v_funnel := public.platform_conversion_funnel_v312(app.sg_today(), app.sg_today());
  v_before := coalesce((v_funnel->'funnel'->>'businesses')::integer, 0);

  update public.sme_prospects
     set created_at = app.sg_day_start(app.sg_today())
   where id = v_prospect;
  insert into public.sme_companies(legal_name) values ('V685 Late Evening Pte Ltd')
    returning id into v_company;
  insert into public.sme_prospects(company_id, ownership_state, legacy_stage_raw, priority,
                                   stage_entered_at, created_at)
  values (v_company, 'closed', 'v685 rollback fixture', 'normal',
          app.sg_day_start(app.sg_today()) + interval '23 hours 30 minutes',
          app.sg_day_start(app.sg_today()) + interval '23 hours 30 minutes');

  v_funnel := public.platform_conversion_funnel_v312(app.sg_today(), app.sg_today());
  v_after := coalesce((v_funnel->'funnel'->>'businesses')::integer, 0);
  if v_after - v_before <> 2 then
    raise exception 'S3-T4 FAIL: today''s funnel gained % of the 2 prospects created inside today''s '
      'Singapore day (first second and 23:30): %', v_after - v_before, v_funnel;
  end if;
  insert into v685_evidence values('S3-T4','the funnel window is Singapore midnight to Singapore midnight');

  -- ------------------------------------------------------------------ S3-T5 (D-01)
  v_ops := public.platform_get_subscription_operations_v156(null, null, 50);
  v_before := (v_ops->'summary'->>'new_this_month')::integer;
  insert into public.billing_provider_subscriptions(
    business_id, provider_customer_id, provider_subscription_id, status, cadence, cadence_months,
    currency, current_period_start, current_period_end, livemode,
    provider_event_created_at, provider_event_rank, last_event_id, created_at)
  values (v_business, 'cus_v685', 'sub_v685', 'active', 'annual', 12, 'SGD',
          app.sg_day_start(app.sg_month(now())), app.sg_day_start(app.sg_today() + 30), false,
          now(), 1, 'evt_v685',
          -- the first instant of this month in Singapore: counted by v685, missed by the old
          -- comparison, which started the month at 08:00 SGT on the 1st
          app.sg_day_start(app.sg_month(now())));
  v_ops := public.platform_get_subscription_operations_v156(null, null, 50);
  v_after := (v_ops->'summary'->>'new_this_month')::integer;
  if v_after - v_before <> 1 then
    raise exception 'S3-T5 FAIL: a subscription created at the first instant of the Singapore month '
      'moved new_this_month by % (before %, after %)', v_after - v_before, v_before, v_after;
  end if;
  insert into v685_evidence values('S3-T5','"new this month" starts at Singapore midnight on the 1st');

  perform set_config('request.jwt.claims','',true);
  perform set_config('TimeZone','UTC',true);
end
$v685_s3$;

-- =============================================================================================
-- SECTION 4 — D-04 + D-05, in the PRODUCTION session zone.
-- =============================================================================================
do $v685_s4$
declare
  v_business uuid := gen_random_uuid();
  v_company uuid; v_prospect uuid; v_terms uuid;
  v_amount constant integer := 118800;
  v_obligation_start date;
  v_obligation_end date;
  v_accepted timestamptz;
  v_evidence jsonb;
  v_def text;
begin
  perform set_config('TimeZone','UTC',true);   -- exactly what production runs

  insert into public.businesses(id,name,slug,industry,enabled_modules,points_mode)
  values (v_business,'V685 Obligation Tenant',
          'v685-obligation-'||substr(v_business::text,1,8),'retail',
          array['dashboard','clients','sales'],'redeem');
  update public.business_workspace_controls_v94
     set approval_status='approved', version=version+1, decided_at=now(), updated_at=now(),
         decision_reason='v685 rollback fixture'
   where business_id = v_business;
  insert into public.subscriptions(business_id) values (v_business) on conflict do nothing;

  -- Accepted at 16:30 UTC — 00:30 the NEXT morning in Singapore. This is the whole defect in
  -- one instant: the UTC day and the Singapore day disagree.
  v_accepted := app.sg_day_start(app.sg_today() - 200) + interval '30 minutes';
  v_obligation_start := app.sg_day(v_accepted);
  v_obligation_end := app.sg_day(v_accepted + interval '12 months' - interval '1 day');
  if v_obligation_start = (v_accepted at time zone 'UTC')::date then
    raise exception 'S4 SETUP FAIL: the fixture instant does not straddle the UTC/Singapore day';
  end if;

  insert into public.sme_companies(legal_name) values ('V685 Obligation Tenant Pte Ltd')
    returning id into v_company;
  insert into public.sme_prospects(company_id, ownership_state, legacy_stage_raw, priority)
  values (v_company, 'closed', 'v685 rollback fixture', 'normal') returning id into v_prospect;
  insert into public.sme_commercial_terms(prospect_id, version, plan_code, product_code,
    billing_cycle, seats, currency, accepted_value_cents, owner_email, contract_status, accepted_at)
  values (v_prospect, 1, 'v685-fixture', 'peekaa-core', 'annual', 1, 'SGD', v_amount,
    'v685.fixture@example.com', 'accepted', v_accepted) returning id into v_terms;

  -- The obligation window as convert_sme_prospect_v79 now writes it: Singapore days.
  update public.subscriptions
     set billing_provider = 'stripe', provider_subscription_id = 'sub_v685_obligation',
         billing_cadence = 'annual', cadence_months = 12, currency = 'SGD',
         commercial_terms_id = v_terms,
         period_subtotal_cents = v_amount, period_tax_cents = 0, period_total_cents = v_amount,
         obligation_period_start = v_obligation_start,
         obligation_period_end = v_obligation_end
   where business_id = v_business;

  -- The paid invoice. Its period_start is the same kind of instant: the Singapore obligation
  -- day, but the PREVIOUS UTC day. The pre-v685 reader compared `period_start::date` (UTC) and
  -- rejected it; the workspace stayed locked with the money in the bank.
  insert into public.billing_provider_invoices(
    business_id, provider_customer_id, provider_subscription_id, provider_invoice_id,
    currency, status, paid_normalized, subtotal_ex_tax_cents, tax_cents, total_cents,
    amount_due_cents, amount_paid_cents, amount_remaining_cents,
    period_start, period_end, paid_at, livemode,
    provider_event_created_at, provider_event_rank, last_event_id)
  values (v_business, 'cus_v685', 'sub_v685_obligation', 'in_v685',
          'SGD', 'paid', true, v_amount, 0, v_amount,
          v_amount, v_amount, 0,
          app.sg_day_start(v_obligation_start) + interval '30 minutes',
          app.sg_day_start(v_obligation_end) + interval '30 minutes',
          now(), false, now(), 1, 'evt_v685_invoice');

  v_evidence := app.v510_verified_initial_payment(v_business);
  if v_evidence is null or v_evidence->>'source' <> 'stripe_invoice' then
    raise exception 'S4-T1 FAIL: a paid invoice on the Singapore obligation day is not accepted as evidence: %',
      v_evidence;
  end if;
  insert into v685_evidence values('S4-T1','the payment gate matches an invoice on the Singapore obligation day');

  -- S4-T2 — the writer at the other end of the same pair.
  v_def := pg_get_functiondef('public.convert_sme_prospect_v79(uuid,bigint,text)'::regprocedure);
  if position('app.sg_day(v_terms.accepted_at)' in v_def) = 0
     or position('v_terms.accepted_at::date' in v_def) > 0 then
    raise exception 'S4-T2 FAIL: convert_sme_prospect_v79 does not write the obligation window as a Singapore day';
  end if;
  insert into v685_evidence values('S4-T2','the conversion writes the obligation window as a Singapore day');
end
$v685_s4$;

-- =============================================================================================
-- SECTION 5 — the crons.
--
-- cron rows are project state, not schema: a rehearsal cluster restores none of them, so a job
-- that is absent here is reported as such rather than failing. Where a job IS registered its
-- schedule must be the Singapore-night one.
-- =============================================================================================
do $v685_s5$
declare
  v_job record;
  v_seen integer := 0;
begin
  for v_job in
    select * from (values
      ('nestly-v94-subscription-lifecycle-daily', '15 16 * * *', '00:15 SGT'),
      ('nestly-v361-bringback-issue-daily',       '20 19 * * *', '03:20 SGT')
    ) as t(jobname, expected, sgt)
  loop
    if exists (select 1 from cron.job where jobname = v_job.jobname) then
      if (select schedule from cron.job where jobname = v_job.jobname) <> v_job.expected then
        raise exception 'S5-T1 FAIL: cron job % runs on "%" — v685 requires "%" (%)',
          v_job.jobname,
          (select schedule from cron.job where jobname = v_job.jobname),
          v_job.expected, v_job.sgt;
      end if;
      v_seen := v_seen + 1;
    end if;
  end loop;
  insert into v685_evidence
  values('S5-T1', v_seen || ' of 2 daily jobs registered here; every registered one fires in the Singapore night');
end
$v685_s5$;

select test, detail from v685_evidence order by test;

rollback;
