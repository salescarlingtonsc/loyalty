-- Rollback-only v680 acceptance suite — a verified manual/GIRO payment reopens the workspace.
--
-- Audit finding F129: platform_verify_manual_payment_v156 issued the receipt and left
-- subscriptions.current_period_end at its stale value, so app.business_operational_v620 kept the
-- workspace shut 14 days after the last paid period ended, even though the money had arrived and
-- two administrators had signed it off.
--
-- SECTION 1 — the locked tenant.
--   S1-T1  A manual-rail tenant whose paid period ended 41 days ago is NOT operational.
--   S1-T2  Recording the renewal payment (real RPCs, first super admin) does not open it either —
--          money on file is not verification.
--
-- SECTION 2 — verification, by the second administrator, through the button.
--   S2-T1  app.business_operational_v620 becomes TRUE.
--   S2-T2  current_period_start / current_period_end / next_payment_at are exactly the invoice's
--          service period (Singapore midnight boundaries, end exclusive).
--   S2-T3  obligation_period_start / obligation_period_end are exactly the invoice's service
--          period, and app.v510_verified_initial_payment still finds a verified payment behind it.
--   S2-T4  status='active', payment_status='paid', and the receipt was still issued.
--   S2-T5  Exactly one SUBSCRIPTION_MANUAL_PAYMENT_V664 audit row carries the period move.
--
-- SECTION 3 — doing it twice, and not doing it when it must not be done.
--   S3-T1  Verifying the same payment again replays and moves nothing.
--   S3-T2  Calling the period writer again on the same payment replays; still one audit row.
--   S3-T3  A REJECTED payment issues no receipt and moves no date.
--   S3-T4  The writer refuses to act on a payment that is not verified.
--
-- Run against production; everything is inside one transaction that rolls back.
begin;
create temporary table v680_evidence(test text, detail text) on commit drop;

do $v680$
declare
  v_recorder uuid;                 -- super admin who records the transfer
  v_verifier uuid;                 -- the second authorised administrator
  v_business uuid;
  v_company uuid; v_prospect uuid; v_terms uuid;
  v_amount constant integer := 118800;               -- $1,188.00 annual, the v664 tier 1 price
  v_service_start date := current_date - 41;         -- the period the renewal invoice covers
  v_service_end date := current_date - 41 + 364;
  v_prior_end timestamptz;
  v_invoice uuid; v_invoice2 uuid;
  v_payment uuid; v_payment2 uuid;
  v_path text; v_path2 text;
  v_res jsonb;
  v_sub public.subscriptions%rowtype;
  v_snapshot record;
  v_count integer;
begin
  -- ------------------------------------------------------------------ fixture
  select user_id into v_recorder from public.super_admins order by user_id limit 1;
  select user_id into v_verifier from public.super_admins order by user_id offset 1 limit 1;
  if v_recorder is null or v_verifier is null or v_recorder = v_verifier then
    raise exception 'FIXTURE: two distinct super admins are required (recorder and verifier)';
  end if;

  select subscription.business_id into v_business
    from public.subscriptions subscription
    join public.business_workspace_controls_v94 control
      on control.business_id = subscription.business_id and control.approval_status = 'approved'
    join public.business_subscription_lifecycle_v94 lifecycle
      on lifecycle.business_id = subscription.business_id and not lifecycle.workspace_paused
   where subscription.billing_provider = 'manual'
   order by subscription.created_at limit 1;
  if v_business is null then
    raise exception 'FIXTURE: no approved, unpaused manual-rail tenant to test against';
  end if;

  -- The obligation this workspace was sold on.  v510 matches payment evidence against accepted
  -- commercial terms, so the suite has to build the same paperwork an assisted sale would.
  insert into public.sme_companies default values returning id into v_company;
  insert into public.sme_prospects(company_id, ownership_state, legacy_stage_raw, priority)
  values (v_company, 'closed', 'v680 rollback fixture', 'normal') returning id into v_prospect;
  insert into public.sme_commercial_terms(prospect_id, version, plan_code, product_code,
    billing_cycle, seats, currency, accepted_value_cents, owner_email, contract_status, accepted_at)
  values (v_prospect, 1, 'v680-fixture', 'peekaa-core', 'annual', 1, 'SGD', v_amount,
    'v680.fixture@example.com', 'accepted', now() - interval '406 days') returning id into v_terms;

  insert into public.platform_billing_contacts_v156(business_id, business_display_name,
    legal_entity_name, billing_address, contact_name, email, recipient_role, created_by, updated_by)
  values (v_business, 'V680 Fixture Tenant', 'V680 Fixture Tenant Pte Ltd', '{}'::jsonb,
    'V680 Fixture', 'v680.fixture@example.com', 'primary', v_recorder, v_recorder);

  v_prior_end := (v_service_start::timestamp at time zone 'Asia/Singapore');
  update public.subscriptions
     set billing_provider = 'manual', billing_cadence = 'annual', cadence_months = 12,
         currency = 'SGD', commercial_terms_id = v_terms,
         period_subtotal_cents = v_amount, period_tax_cents = 0, period_total_cents = v_amount,
         current_period_start = v_prior_end - interval '365 days',
         current_period_end = v_prior_end,
         next_payment_at = v_prior_end,
         obligation_period_start = v_service_start - 365,
         obligation_period_end = v_service_start - 1,
         trial_ends_at = null
   where business_id = v_business;
  /* The lapsed shape the finding describes: the money for the LAST period is on file, so v510 left
     payment_status 'paid' — only the date is stale.  Set it in its own statement: the v510
     projection trigger fires on the obligation columns above, not on these two. */
  update public.subscriptions set status = 'active', payment_status = 'paid'
   where business_id = v_business;

  -- ---------------------------------------------------------------- SECTION 1
  if app.business_operational_v620(v_business) then
    raise exception 'S1-T1 FAIL: the tenant is operational before the renewal is even recorded';
  end if;
  insert into v680_evidence values('S1-T1','a 41-day-stale paid period closes the workspace');

  perform set_config('request.jwt.claims', json_build_object(
    'sub', v_recorder::text, 'role', 'authenticated',
    'amr', json_build_array(json_build_object('method','oauth')),
    'app_metadata', json_build_object('providers', json_build_array('google')))::text, true);

  v_res := public.platform_create_manual_invoice_v156(
    v_business, current_date, current_date + 7, v_service_start, v_service_end,
    jsonb_build_array(jsonb_build_object('description','Peekaa subscription renewal',
      'quantity',1,'unit_amount_cents',v_amount)), 0, gen_random_uuid());
  v_invoice := ((v_res->'document')->>'id')::uuid;
  if ((v_res->'document')->>'balance_due_cents')::bigint <> v_amount then
    raise exception 'FIXTURE: the invoice total is % but the obligation is %',
      (v_res->'document')->>'balance_due_cents', v_amount;
  end if;

  v_path := 'platform-subscriptions/manual-evidence/'||v_business||'/'||v_invoice||'/'
            ||gen_random_uuid()||'.pdf';
  insert into storage.objects(bucket_id, name) values ('sme-private', v_path);
  v_res := public.platform_record_manual_payment_v156(
    v_invoice, v_amount::bigint, 'V680-TRANSFER', current_date, '1234', v_path, gen_random_uuid());
  v_payment := ((v_res->'payment')->>'id')::uuid;

  if app.business_operational_v620(v_business) then
    raise exception 'S1-T2 FAIL: an unverified payment opened the workspace';
  end if;
  insert into v680_evidence values('S1-T2','recorded but unverified money does not open anything');

  -- ---------------------------------------------------------------- SECTION 2
  perform set_config('request.jwt.claims', json_build_object(
    'sub', v_verifier::text, 'role', 'authenticated',
    'amr', json_build_array(json_build_object('method','oauth')),
    'app_metadata', json_build_object('providers', json_build_array('google')))::text, true);

  v_res := public.platform_verify_manual_payment_v156(
    v_payment, 'verified', null, gen_random_uuid());
  if coalesce(v_res->>'replayed','') <> 'false' then
    raise exception 'S2 FIXTURE: the first verification replayed';
  end if;

  if not app.business_operational_v620(v_business) then
    raise exception 'S2-T1 FAIL: a verified, receipted payment left the workspace closed';
  end if;
  insert into v680_evidence values('S2-T1','verified manual payment reopens the workspace');

  select * into v_sub from public.subscriptions where business_id = v_business;
  if v_sub.current_period_end is distinct from ((v_service_end + 1)::timestamp at time zone 'Asia/Singapore') then
    raise exception 'S2-T2 FAIL: current_period_end is %, expected %',
      v_sub.current_period_end, ((v_service_end + 1)::timestamp at time zone 'Asia/Singapore');
  end if;
  if v_sub.current_period_start is distinct from (v_service_start::timestamp at time zone 'Asia/Singapore') then
    raise exception 'S2-T2 FAIL: current_period_start is %, expected %',
      v_sub.current_period_start, (v_service_start::timestamp at time zone 'Asia/Singapore');
  end if;
  if v_sub.next_payment_at is distinct from v_sub.current_period_end then
    raise exception 'S2-T2 FAIL: next_payment_at % does not follow current_period_end %',
      v_sub.next_payment_at, v_sub.current_period_end;
  end if;
  insert into v680_evidence values('S2-T2','both period dates are exactly the invoice service period');

  if v_sub.obligation_period_start is distinct from v_service_start
     or v_sub.obligation_period_end is distinct from v_service_end then
    raise exception 'S2-T3 FAIL: obligation period is % .. %, expected % .. %',
      v_sub.obligation_period_start, v_sub.obligation_period_end, v_service_start, v_service_end;
  end if;
  if app.v510_verified_initial_payment(v_business) is null then
    raise exception 'S2-T3 FAIL: the advanced obligation period has no verified payment behind it';
  end if;
  insert into v680_evidence values('S2-T3','the obligation period advanced and v510 still sees the payment');

  if v_sub.status <> 'active' or v_sub.payment_status <> 'paid' then
    raise exception 'S2-T4 FAIL: subscription is % / %', v_sub.status, v_sub.payment_status;
  end if;
  if not exists (select 1 from public.platform_subscription_documents_v156
                  where document_type = 'receipt' and original_document_id = v_invoice) then
    raise exception 'S2-T4 FAIL: the receipt the verifier promised was not issued';
  end if;
  insert into v680_evidence values('S2-T4','paid and active, and the receipt still exists');

  select count(*) into v_count from public.audit_log
   where business_id = v_business and action = 'SUBSCRIPTION_MANUAL_PAYMENT_V664'
     and detail->>'operation_key' = 'v664-manual-payment:v680-verified-payment:'||v_payment::text;
  if v_count <> 1 then
    raise exception 'S2-T5 FAIL: % audited period moves for one payment, expected 1', v_count;
  end if;
  insert into v680_evidence values('S2-T5','exactly one audited period move');

  -- ---------------------------------------------------------------- SECTION 3
  select current_period_start cps, current_period_end cpe, next_payment_at npa,
         obligation_period_start ops, obligation_period_end ope, status st, payment_status ps
    into v_snapshot from public.subscriptions where business_id = v_business;

  v_res := public.platform_verify_manual_payment_v156(
    v_payment, 'verified', null, gen_random_uuid());
  if coalesce(v_res->>'replayed','') <> 'true' then
    raise exception 'S3-T1 FAIL: verifying twice did not replay';
  end if;
  select * into v_sub from public.subscriptions where business_id = v_business;
  if (v_sub.current_period_start, v_sub.current_period_end, v_sub.next_payment_at,
      v_sub.obligation_period_start, v_sub.obligation_period_end, v_sub.status, v_sub.payment_status)
     is distinct from
     (v_snapshot.cps, v_snapshot.cpe, v_snapshot.npa, v_snapshot.ops, v_snapshot.ope,
      v_snapshot.st, v_snapshot.ps) then
    raise exception 'S3-T1 FAIL: a second verification moved the subscription';
  end if;
  insert into v680_evidence values('S3-T1','verifying twice is a no-op');

  v_res := app.v680_manual_payment_period(v_payment, v_verifier);
  if coalesce(v_res->>'replayed','') <> 'true' or coalesce(v_res->>'applied','') <> 'false' then
    raise exception 'S3-T2 FAIL: the period writer re-applied the same payment: %', v_res;
  end if;
  select count(*) into v_count from public.audit_log
   where business_id = v_business and action = 'SUBSCRIPTION_MANUAL_PAYMENT_V664'
     and detail->>'operation_key' = 'v664-manual-payment:v680-verified-payment:'||v_payment::text;
  if v_count <> 1 then
    raise exception 'S3-T2 FAIL: the replay wrote another audit row (% now)', v_count;
  end if;
  select * into v_sub from public.subscriptions where business_id = v_business;
  if (v_sub.current_period_end, v_sub.obligation_period_end)
     is distinct from (v_snapshot.cpe, v_snapshot.ope) then
    raise exception 'S3-T2 FAIL: the replay moved the dates';
  end if;
  insert into v680_evidence values('S3-T2','the period writer replays on its own operation key');

  perform set_config('request.jwt.claims', json_build_object(
    'sub', v_recorder::text, 'role', 'authenticated',
    'amr', json_build_array(json_build_object('method','oauth')),
    'app_metadata', json_build_object('providers', json_build_array('google')))::text, true);
  v_res := public.platform_create_manual_invoice_v156(
    v_business, current_date, current_date + 7, v_service_end + 1, v_service_end + 365,
    jsonb_build_array(jsonb_build_object('description','Peekaa subscription renewal',
      'quantity',1,'unit_amount_cents',v_amount)), 0, gen_random_uuid());
  v_invoice2 := ((v_res->'document')->>'id')::uuid;
  v_path2 := 'platform-subscriptions/manual-evidence/'||v_business||'/'||v_invoice2||'/'
             ||gen_random_uuid()||'.pdf';
  insert into storage.objects(bucket_id, name) values ('sme-private', v_path2);
  v_res := public.platform_record_manual_payment_v156(
    v_invoice2, v_amount::bigint, 'V680-DISPUTED', current_date, '1234', v_path2, gen_random_uuid());
  v_payment2 := ((v_res->'payment')->>'id')::uuid;

  v_res := app.v680_manual_payment_period(v_payment2, v_verifier);
  if coalesce(v_res->>'reason','') <> 'payment_not_verified' then
    raise exception 'S3-T4 FAIL: the writer acted on an unverified payment: %', v_res;
  end if;
  insert into v680_evidence values('S3-T4','an unverified payment moves nothing');

  perform set_config('request.jwt.claims', json_build_object(
    'sub', v_verifier::text, 'role', 'authenticated',
    'amr', json_build_array(json_build_object('method','oauth')),
    'app_metadata', json_build_object('providers', json_build_array('google')))::text, true);
  perform public.platform_verify_manual_payment_v156(
    v_payment2, 'rejected', 'the transfer reference does not match this invoice', gen_random_uuid());
  select * into v_sub from public.subscriptions where business_id = v_business;
  if (v_sub.current_period_end, v_sub.obligation_period_end)
     is distinct from (v_snapshot.cpe, v_snapshot.ope) then
    raise exception 'S3-T3 FAIL: a REJECTED payment moved the billing dates';
  end if;
  if exists (select 1 from public.platform_subscription_documents_v156
              where document_type = 'receipt' and original_document_id = v_invoice2) then
    raise exception 'S3-T3 FAIL: a rejected payment issued a receipt';
  end if;
  insert into v680_evidence values('S3-T3','a rejected payment issues nothing and moves nothing');
end
$v680$;

select test, detail from v680_evidence order by test;

rollback;
