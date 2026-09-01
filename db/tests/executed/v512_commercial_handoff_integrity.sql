-- Rolled-back acceptance contract for v512 (the commercial handoff holds its shape).
-- Every assertion executes real RPCs, real constraints and real triggers. Nothing is committed.
begin;

-- ---------------------------------------------------------------- structure
do $$
begin
  if not exists(select 1 from pg_class c join pg_namespace n on n.oid=c.relnamespace
    where n.nspname='public' and c.relname='sme_commission_accruals_v512' and c.relrowsecurity)
   or not exists(select 1 from pg_class c join pg_namespace n on n.oid=c.relnamespace
    where n.nspname='public' and c.relname='platform_discount_policies_v512' and c.relrowsecurity) then
    raise exception 'FAIL v512 tables must have row level security';end if;
  if exists(select 1 from information_schema.role_table_grants
    where table_schema='public'
      and table_name in ('sme_commission_accruals_v512','platform_discount_policies_v512')
      and grantee in ('anon','authenticated','public')) then
    raise exception 'FAIL v512 tables must not be directly reachable from the browser';end if;
  if exists(select 1 from pg_policy p join pg_class c on c.oid=p.polrelid
    where c.relname in ('sme_commission_accruals_v512','platform_discount_policies_v512')) then
    raise exception 'FAIL v512 tables are RPC-only and must carry no policy';end if;
  if exists(select 1 from public.platform_discount_policies_v512) then
    raise exception 'FAIL v512 must ship with no discount threshold configured';end if;
  if not has_function_privilege('authenticated',
       'public.platform_set_discount_policy_v512(text,numeric,text)','execute')
   or not has_function_privilege('authenticated',
       'public.platform_clear_discount_policy_v512(text)','execute') then
    raise exception 'FAIL the v512 super-admin RPCs must be reachable to be gated';end if;
  if exists(select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='app' and p.proname like 'v512%'
      and has_function_privilege('authenticated',p.oid,'execute')) then
    raise exception 'FAIL no app.v512 helper may be browser callable';end if;
  if exists(select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where n.nspname in ('app','public') and p.proname like '%v512%'
      and coalesce(array_to_string(p.proconfig,','),'') not like '%search_path%') then
    raise exception 'FAIL every v512 function must pin its search_path';end if;
  -- v510's paid-handoff guard must survive this migration untouched.
  if not exists(select 1 from pg_trigger where tgname='ab_sme_prospects_v510_paid_handoff')
   or not exists(select 1 from pg_trigger where tgname='aa_businesses_payment_activation_v510') then
    raise exception 'FAIL a v510 entitlement guard went missing';end if;
end $$;

-- ---------------------------------------------------------------- behaviour
do $$
declare
  v_admin constant uuid:='51200000-0000-4000-8000-000000000001';
  v_sales constant uuid:='51200000-0000-4000-8000-000000000002';
  v_verifier constant uuid:='51200000-0000-4000-8000-000000000003';
  v_owner constant uuid:='51200000-0000-4000-8000-000000000004';
  v_origin constant uuid:='51200000-0000-4000-8000-000000000005';
  v_junior constant uuid:='51200000-0000-4000-8000-000000000006';
  v_due constant timestamptz:=clock_timestamp()+interval '1 hour';
  v_consultant uuid;v_source_consultant uuid;v_junior_consultant uuid;
  v_created jsonb;v_claim jsonb;v_transition jsonb;v_conversion jsonb;
  v_invoice_result jsonb;v_upload jsonb;v_payment_result jsonb;
  v_prospect uuid;v_business uuid;v_invoice uuid;v_payment uuid;v_version bigint;
  v_terms public.sme_commercial_terms%rowtype;
  v_accrual public.sme_commission_accruals_v512%rowtype;
  v_count integer;v_terms_id uuid;
  v_p2 uuid;v_p2_company uuid;v_p2_version integer:=0;
  v_p3 uuid;v_p3_company uuid;v_business3 uuid;v_terms3 uuid;
  v_invoice3 uuid;v_payment3 uuid;v_upload3 jsonb;
begin
  insert into auth.users(id,email,created_at,updated_at)
  values(v_admin,'v512-admin@example.invalid',clock_timestamp(),clock_timestamp()),
    (v_sales,'v512-sales@example.invalid',clock_timestamp(),clock_timestamp()),
    (v_verifier,'v512-verifier@example.invalid',clock_timestamp(),clock_timestamp()),
    (v_owner,'owner-v512@example.invalid',clock_timestamp(),clock_timestamp()),
    (v_origin,'v512-origin@example.invalid',clock_timestamp(),clock_timestamp()),
    (v_junior,'v512-junior@example.invalid',clock_timestamp(),clock_timestamp());
  update auth.users set email_confirmed_at=clock_timestamp() where id=v_owner;
  insert into public.super_admins(user_id,email,note)
  values(v_admin,'v512-admin@example.invalid','synthetic rolled-back v512 proof'),
    (v_verifier,'v512-verifier@example.invalid','synthetic independent payment verifier');
  insert into public.platform_access_grants_v89(user_id,role,module_perms,created_by,updated_by)
  values(v_sales,'sales_staff','{"onboarding":"rw"}'::jsonb,v_admin,v_admin);
  insert into public.platform_consultants(user_id,display_name,tier,employment_started_on,created_by)
  values(v_sales,'V512 Closing Seller','senior',current_date,v_admin) returning id into v_consultant;
  insert into public.platform_consultants(user_id,display_name,tier,employment_started_on,created_by)
  values(v_origin,'V512 Originating Seller','senior',current_date,v_admin) returning id into v_source_consultant;
  insert into public.platform_consultants(user_id,display_name,tier,employment_started_on,created_by)
  values(v_junior,'V512 Junior Seller','junior',current_date,v_admin) returning id into v_junior_consultant;

  perform set_config('request.jwt.claim.sub',v_admin::text,true);
  -- v625: is_super_admin() now additionally requires a Google-SSO session (amr method 'oauth'
  -- plus app_metadata.providers containing 'google'), not merely a super_admins row. v_admin IS
  -- a genuine platform/super-admin actor in this fixture (inserted into super_admins above), so
  -- this is the same session, just carrying the claims a real platform login would present.
  perform set_config('request.jwt.claims',jsonb_build_object('sub',v_admin,'role','authenticated',
    'amr',jsonb_build_array(jsonb_build_object('method','oauth')),
    'app_metadata',jsonb_build_object('providers',jsonb_build_array('google')))::text,true);

  -- =====================================================================
  -- FIXTURE 1 -- the real v510 chain: lead, CLOSED_WON, conversion, payment.
  -- =====================================================================
  v_created:=public.platform_ingest_lead_v510(
    '{"legal_name":"V512 Handoff Proof","registration_number":"T25LL5120A","phone":"+65 6123 5120"}'::jsonb,
    '{"full_name":"Proof Owner","email":"owner-v512@example.invalid"}'::jsonb,
    '{"source_system":"platform_console","source_type":"manual"}'::jsonb,
    null,v_due,'51200000-0000-4000-8000-000000000010');
  v_prospect:=(v_created->>'prospect_id')::uuid;
  if v_prospect is null then raise exception 'FAIL lead fixture was not created: %',v_created;end if;

  -- The lead was originated by one salesperson and is later claimed by another.
  insert into public.sme_prospect_assignments(prospect_id,consultant_id,assigned_by,reason,created_at)
  values(v_prospect,v_source_consultant,v_admin,'originated the lead',clock_timestamp()-interval '1 day');

  -- v625: app.v89_platform_role() returns null on a non-Google session. v_sales is a genuine
  -- platform_access_grants_v89 sales_staff actor (inserted above), so add the same claims a
  -- real platform login would present.
  perform set_config('request.jwt.claim.sub',v_sales::text,true);
  perform set_config('request.jwt.claims',jsonb_build_object('sub',v_sales,'role','authenticated',
    'amr',jsonb_build_array(jsonb_build_object('method','oauth')),
    'app_metadata',jsonb_build_object('providers',jsonb_build_array('google')))::text,true);
  select version into v_version from public.sme_prospects where id=v_prospect;
  v_claim:=public.platform_claim_lead_v510(v_prospect,v_version,'51200000-0000-4000-8000-000000000011');
  if (v_claim->>'owner')::uuid<>v_consultant then raise exception 'FAIL claim did not take ownership';end if;
  select version into v_version from public.sme_prospects where id=v_prospect;
  v_transition:=public.platform_transition_lead_v510(v_prospect,'contacted',v_version,
    'send_follow_up',clock_timestamp()+interval '1 day',null,null,
    jsonb_build_object('contacted_at',clock_timestamp(),'channel','phone','context','Synthetic contact'),
    null,'51200000-0000-4000-8000-000000000012');
  v_transition:=public.platform_transition_lead_v510(v_prospect,'interested',(v_transition->>'version')::bigint,
    'prepare_proposal',clock_timestamp()+interval '1 day',null,null,
    jsonb_build_object('context','Merchant confirmed interest','next_follow_up_at',clock_timestamp()+interval '1 day'),
    null,'51200000-0000-4000-8000-000000000013');
  v_transition:=public.platform_transition_lead_v510(v_prospect,'proposal',(v_transition->>'version')::bigint,
    'proposal_follow_up',clock_timestamp()+interval '1 day',null,null,
    jsonb_build_object('proposal_issued',clock_timestamp(),'context','Commercial proposal sent'),
    null,'51200000-0000-4000-8000-000000000014');
  v_transition:=public.platform_transition_lead_v510(v_prospect,'closed_won',(v_transition->>'version')::bigint,
    'payment_follow_up',clock_timestamp()+interval '1 day',null,null,
    '{"explicit_confirmation":true}'::jsonb,
    jsonb_build_object('contract_status','accepted','owner_email','owner-v512@example.invalid',
      'plan_code','peekaa_core','product_code','loyalty','billing_cycle','annual','seats',2,
      'accepted_value_cents',240000,'list_value_cents',300000,'discount_cents',60000,
      'discount_reason','pilot cohort concession','currency','SGD',
      'onboarding_owner_consultant_id',v_consultant,'target_go_live',(current_date+14)::text),
    '51200000-0000-4000-8000-000000000015');

  -- A1. Acceptance captured both sides of the attribution without being asked.
  select * into v_terms from public.sme_commercial_terms where prospect_id=v_prospect order by version desc limit 1;
  if v_terms.closing_consultant_id<>v_consultant then
    raise exception 'FAIL closing consultant was not captured from the lead owner (got %)',v_terms.closing_consultant_id;end if;
  if v_terms.source_consultant_id<>v_source_consultant then
    raise exception 'FAIL originating consultant was not captured from the earliest assignment (got %)',
      v_terms.source_consultant_id;end if;
  if v_terms.list_value_cents<>300000 or v_terms.discount_cents<>60000
     or v_terms.discount_pct<>20.0000 then
    raise exception 'FAIL the accepted discount did not reach the commercial terms (list %, discount %, pct %)',
      v_terms.list_value_cents,v_terms.discount_cents,v_terms.discount_pct;end if;

  -- E1. CLOSED_WON still cannot manufacture entitlement.
  begin
    update public.sme_prospects set current_stage_key='client' where id=v_prospect;
    raise exception 'FAIL unpaid CLOSED_WON advanced to the paid handoff';
  exception when sqlstate '23514' then null;end;

  perform set_config('request.jwt.claim.sub',v_admin::text,true);
  -- v625: is_super_admin() now additionally requires a Google-SSO session (amr method 'oauth'
  -- plus app_metadata.providers containing 'google'), not merely a super_admins row. v_admin IS
  -- a genuine platform/super-admin actor in this fixture (inserted into super_admins above), so
  -- this is the same session, just carrying the claims a real platform login would present.
  perform set_config('request.jwt.claims',jsonb_build_object('sub',v_admin,'role','authenticated',
    'amr',jsonb_build_array(jsonb_build_object('method','oauth')),
    'app_metadata',jsonb_build_object('providers',jsonb_build_array('google')))::text,true);
  v_conversion:=public.convert_sme_prospect_v79(v_prospect,(v_transition->>'version')::bigint,
    'v512-payment-ready-account');
  v_business:=(v_conversion->>'business_id')::uuid;
  if v_conversion->>'outcome'<>'converted' or v_business is null then
    raise exception 'FAIL conversion fixture failed: %',v_conversion;end if;
  if exists(select 1 from public.sme_commission_accruals_v512 where business_id=v_business) then
    raise exception 'FAIL an unpaid handoff accrued commission';end if;

  perform public.platform_set_billing_profile_v156(jsonb_build_object(
    'registered_address','1 Synthetic Street, Singapore 018989','billing_email','billing-v512@example.invalid',
    'gst_status','not_registered','default_payment_terms','Due on receipt'),
    '51200000-0000-4000-8000-000000000016');
  perform public.platform_upsert_billing_contact_v156(jsonb_build_object('business_id',v_business,
    'business_display_name','V512 Handoff Proof','legal_entity_name','V512 Handoff Proof',
    'registration_number','T25LL5120A','billing_address',jsonb_build_object('line1','1 Synthetic Street'),
    'country','Singapore','contact_name','Proof Owner','email','owner-v512@example.invalid',
    'recipient_role','primary','active',true),'51200000-0000-4000-8000-000000000017');
  v_invoice_result:=public.platform_create_manual_invoice_v156(v_business,current_date,current_date+7,
    current_date,current_date+364,
    '[{"description":"Peekaa annual subscription","quantity":1,"unit_amount_cents":240000}]'::jsonb,
    0,'51200000-0000-4000-8000-000000000018');
  v_invoice:=(v_invoice_result#>>'{document,id}')::uuid;
  v_upload:=public.platform_prepare_manual_evidence_upload_v156(v_invoice,'proof.pdf','application/pdf',
    '51200000-0000-4000-8000-000000000019');
  insert into storage.objects(id,bucket_id,name,owner_id,metadata)
  values('51200000-0000-4000-8000-000000000020','sme-private',v_upload->>'object_path',
    v_admin::text,'{"mimetype":"application/pdf"}'::jsonb);
  v_payment_result:=public.platform_record_manual_payment_v156(v_invoice,240000,'V512-PAYMENT-PROOF',
    current_date,'6357',v_upload->>'object_path','51200000-0000-4000-8000-000000000021');
  v_payment:=(v_payment_result#>>'{payment,id}')::uuid;
  -- v625: is_super_admin() now additionally requires a Google-SSO session. v_verifier IS a
  -- genuine super_admins row (inserted above), so add the same claims a real platform login
  -- would present.
  perform set_config('request.jwt.claim.sub',v_verifier::text,true);
  perform set_config('request.jwt.claims',jsonb_build_object('sub',v_verifier,'role','authenticated',
    'amr',jsonb_build_array(jsonb_build_object('method','oauth')),
    'app_metadata',jsonb_build_object('providers',jsonb_build_array('google')))::text,true);
  perform public.platform_verify_manual_payment_v156(v_payment,'verified','Independent synthetic verification',
    '51200000-0000-4000-8000-000000000022');

  -- D1. Verified payment accrues exactly one row, snapshotting v78's rate.
  select count(*) into v_count from public.sme_commission_accruals_v512 where business_id=v_business;
  if v_count<>1 then raise exception 'FAIL expected exactly 1 accrual after verified payment, found %',v_count;end if;
  select * into v_accrual from public.sme_commission_accruals_v512 where business_id=v_business;
  if v_accrual.commercial_terms_id<>v_terms.id or v_accrual.terms_version<>v_terms.version then
    raise exception 'FAIL accrual did not snapshot the accepted commercial version';end if;
  if v_accrual.closing_consultant_id<>v_consultant or v_accrual.source_consultant_id<>v_source_consultant then
    raise exception 'FAIL accrual lost the commercial attribution';end if;
  if v_accrual.rate_source<>'consultant_commission_policy_v78' or v_accrual.tier_snapshot<>'senior'
     or v_accrual.rate_bps<>3000 or v_accrual.policy_id is null or v_accrual.zero_rate_reason is not null then
    raise exception 'FAIL accrual did not read the effective v78 senior policy (rate %, source %)',
      v_accrual.rate_bps,v_accrual.rate_source;end if;
  if v_accrual.basis_cents<>240000 or v_accrual.commission_cents<>72000
     or v_accrual.basis_source<>'manual_invoice_total_ex_tax'
     or v_accrual.payment_source<>'manual_payment' or v_accrual.payment_evidence_id<>v_payment then
    raise exception 'FAIL accrual amount or evidence is wrong (basis %, commission %)',
      v_accrual.basis_cents,v_accrual.commission_cents;end if;
  if v_accrual.obligation_period_start<>current_date or v_accrual.obligation_period_end<>current_date+364 then
    raise exception 'FAIL accrual is not keyed on the obligation period it paid';end if;

  -- D2. Replaying either projection cannot duplicate the accrual.
  update public.platform_manual_payments_v156 set status='verified' where id=v_payment;
  perform app.v512_accrue_initial_commission(v_business);
  perform app.v512_accrue_initial_commission(v_business);
  select count(*) into v_count from public.sme_commission_accruals_v512 where business_id=v_business;
  if v_count<>1 then raise exception 'FAIL replaying the projection produced % accruals',v_count;end if;

  -- D3. An accrual is append-only.
  begin
    update public.sme_commission_accruals_v512 set commission_cents=1 where id=v_accrual.id;
    raise exception 'FAIL a commission accrual was edited';
  exception when restrict_violation then
    if sqlerrm not like '%append-only%' then
      raise exception 'FAIL accrual update was refused by the wrong guard: %',sqlerrm;end if;end;
  begin
    delete from public.sme_commission_accruals_v512 where id=v_accrual.id;
    raise exception 'FAIL a commission accrual was deleted';
  exception when restrict_violation then
    if sqlerrm not like '%append-only%' then
      raise exception 'FAIL accrual delete was refused by the wrong guard: %',sqlerrm;end if;end;

  -- =====================================================================
  -- FIXTURE 2 -- immutability, amendment and the maker-checker mechanism.
  -- =====================================================================
  perform set_config('request.jwt.claim.sub',v_admin::text,true);
  -- v625: is_super_admin() now additionally requires a Google-SSO session (amr method 'oauth'
  -- plus app_metadata.providers containing 'google'), not merely a super_admins row. v_admin IS
  -- a genuine platform/super-admin actor in this fixture (inserted into super_admins above), so
  -- this is the same session, just carrying the claims a real platform login would present.
  perform set_config('request.jwt.claims',jsonb_build_object('sub',v_admin,'role','authenticated',
    'amr',jsonb_build_array(jsonb_build_object('method','oauth')),
    'app_metadata',jsonb_build_object('providers',jsonb_build_array('google')))::text,true);
  insert into public.sme_companies(legal_name,registration_number)
  values('V512 Terms Proof','T25LL5121B') returning id into v_p2_company;
  insert into public.sme_prospects(company_id,current_stage_key,assigned_consultant_id,
    ownership_state,queue_key,next_action_at,created_by)
  values(v_p2_company,'proposal',v_consultant,'owned',null,clock_timestamp()+interval '1 day',v_admin)
  returning id into v_p2;

  -- C1. With no threshold configured, a deep discount is accepted as-is.
  v_p2_version:=v_p2_version+1;
  insert into public.sme_commercial_terms(prospect_id,version,plan_code,product_code,billing_cycle,
    seats,currency,accepted_value_cents,list_value_cents,discount_cents,discount_reason,
    owner_email,contract_status,accepted_at,closing_consultant_id,created_by)
  values(v_p2,v_p2_version,'peekaa_core','loyalty','annual',1,'SGD',240000,300000,60000,
    'ungated concession','owner-v512@example.invalid','accepted',clock_timestamp(),v_consultant,v_admin)
  returning id into v_terms_id;

  -- B1/B2. The accepted version is frozen and is not deletable.
  -- The message matters: v512's guard is named to sort ahead of v76's blanket
  -- table guard, so the refusal has to be the specific one or the invariant is
  -- only being enforced by an object that predates it.
  begin
    update public.sme_commercial_terms set accepted_value_cents=100 where id=v_terms_id;
    raise exception 'FAIL an accepted commercial value was edited in place';
  exception when restrict_violation then
    if sqlerrm not like '%accepted commercial terms are frozen%' then
      raise exception 'FAIL frozen economics were refused by the wrong guard: %',sqlerrm;end if;end;
  begin
    update public.sme_commercial_terms set closing_consultant_id=v_source_consultant where id=v_terms_id;
    raise exception 'FAIL accepted attribution was reassigned after the fact';
  exception when restrict_violation then
    if sqlerrm not like '%accepted commercial terms are frozen%' then
      raise exception 'FAIL frozen attribution was refused by the wrong guard: %',sqlerrm;end if;end;
  begin
    delete from public.sme_commercial_terms where id=v_terms_id;
    raise exception 'FAIL an accepted commercial version was deleted';
  exception when restrict_violation then
    if sqlerrm not like '%may not be deleted%' then
      raise exception 'FAIL the delete was refused by the wrong guard: %',sqlerrm;end if;end;

  -- B3. Amendment is the next version; the superseded one keeps its history.
  v_p2_version:=v_p2_version+1;
  insert into public.sme_commercial_terms(prospect_id,version,plan_code,product_code,billing_cycle,
    seats,currency,accepted_value_cents,list_value_cents,discount_cents,discount_reason,
    owner_email,contract_status,accepted_at,closing_consultant_id,created_by)
  values(v_p2,v_p2_version,'peekaa_core','loyalty','annual',1,'SGD',270000,300000,30000,
    'renegotiated concession','owner-v512@example.invalid','accepted',clock_timestamp(),v_consultant,v_admin);
  if not exists(select 1 from public.sme_commercial_terms where id=v_terms_id
       and version=1 and contract_status='accepted' and accepted_value_cents=240000)
     or not exists(select 1 from public.sme_commercial_terms where prospect_id=v_p2
       and version=2 and accepted_value_cents=270000) then
    raise exception 'FAIL amendment did not create version 2 beside an intact version 1';end if;

  -- C2/C3/C4. With a threshold configured, an excessive discount needs an
  -- independent approver -- and the closer cannot be that approver.
  perform public.platform_set_discount_policy_v512('peekaa_core',10,
    'synthetic proof: concessions over 10 percent need a second signature');
  v_p2_version:=v_p2_version+1;
  begin
    insert into public.sme_commercial_terms(prospect_id,version,plan_code,product_code,billing_cycle,
      seats,currency,accepted_value_cents,list_value_cents,discount_cents,discount_reason,
      owner_email,contract_status,accepted_at,closing_consultant_id,created_by)
    values(v_p2,v_p2_version,'peekaa_core','loyalty','annual',1,'SGD',240000,300000,60000,
      'unapproved concession','owner-v512@example.invalid','accepted',clock_timestamp(),v_consultant,v_admin);
    raise exception 'FAIL an excessive discount was accepted with no approver';
  exception when sqlstate '23514' then
    if sqlerrm not like '%needs a second approver%' then
      raise exception 'FAIL the unapproved discount was refused for the wrong reason: %',sqlerrm;end if;end;
  begin
    insert into public.sme_commercial_terms(prospect_id,version,plan_code,product_code,billing_cycle,
      seats,currency,accepted_value_cents,list_value_cents,discount_cents,discount_reason,
      owner_email,contract_status,accepted_at,closing_consultant_id,
      discount_approved_by,discount_approved_at,created_by)
    values(v_p2,v_p2_version,'peekaa_core','loyalty','annual',1,'SGD',240000,300000,60000,
      'self approved concession','owner-v512@example.invalid','accepted',clock_timestamp(),v_consultant,
      v_sales,clock_timestamp(),v_admin);
    raise exception 'FAIL the closing salesperson approved their own discount';
  exception when sqlstate '23514' then
    if sqlerrm not like '%may not be approved by the salesperson closing the deal%' then
      raise exception 'FAIL the self-approval was refused for the wrong reason: %',sqlerrm;end if;end;
  insert into public.sme_commercial_terms(prospect_id,version,plan_code,product_code,billing_cycle,
    seats,currency,accepted_value_cents,list_value_cents,discount_cents,discount_reason,
    owner_email,contract_status,accepted_at,closing_consultant_id,
    discount_approved_by,discount_approved_at,created_by)
  values(v_p2,v_p2_version,'peekaa_core','loyalty','annual',1,'SGD',240000,300000,60000,
    'independently approved concession','owner-v512@example.invalid','accepted',clock_timestamp(),v_consultant,
    v_admin,clock_timestamp(),v_admin);

  -- A discount under the threshold, and any plan the policy does not name,
  -- are not gated: the mechanism is a threshold, not a blanket approval queue.
  v_p2_version:=v_p2_version+1;
  insert into public.sme_commercial_terms(prospect_id,version,plan_code,product_code,billing_cycle,
    seats,currency,accepted_value_cents,list_value_cents,discount_cents,discount_reason,
    owner_email,contract_status,accepted_at,closing_consultant_id,created_by)
  values(v_p2,v_p2_version,'peekaa_core','loyalty','annual',1,'SGD',285000,300000,15000,
    'small concession','owner-v512@example.invalid','accepted',clock_timestamp(),v_consultant,v_admin);
  v_p2_version:=v_p2_version+1;
  insert into public.sme_commercial_terms(prospect_id,version,plan_code,product_code,billing_cycle,
    seats,currency,accepted_value_cents,list_value_cents,discount_cents,discount_reason,
    owner_email,contract_status,accepted_at,closing_consultant_id,created_by)
  values(v_p2,v_p2_version,'peekaa_enterprise','loyalty','annual',1,'SGD',240000,300000,60000,
    'unnamed plan concession','owner-v512@example.invalid','accepted',clock_timestamp(),v_consultant,v_admin);

  -- C5. Clearing the threshold restores the ungated default.
  perform public.platform_clear_discount_policy_v512('peekaa_core');
  if app.v512_discount_threshold_pct('peekaa_core') is not null then
    raise exception 'FAIL the discount threshold survived being cleared';end if;
  v_p2_version:=v_p2_version+1;
  insert into public.sme_commercial_terms(prospect_id,version,plan_code,product_code,billing_cycle,
    seats,currency,accepted_value_cents,list_value_cents,discount_cents,discount_reason,
    owner_email,contract_status,accepted_at,closing_consultant_id,created_by)
  values(v_p2,v_p2_version,'peekaa_core','loyalty','annual',1,'SGD',240000,300000,60000,
    'ungated again','owner-v512@example.invalid','accepted',clock_timestamp(),v_consultant,v_admin);

  -- Only a super admin may price the platform's own approval threshold.
  -- v625: app.v89_platform_role() returns null on a non-Google session. v_sales is a genuine
  -- platform_access_grants_v89 sales_staff actor (inserted above), so add the same claims a
  -- real platform login would present.
  perform set_config('request.jwt.claim.sub',v_sales::text,true);
  perform set_config('request.jwt.claims',jsonb_build_object('sub',v_sales,'role','authenticated',
    'amr',jsonb_build_array(jsonb_build_object('method','oauth')),
    'app_metadata',jsonb_build_object('providers',jsonb_build_array('google')))::text,true);
  begin
    perform public.platform_set_discount_policy_v512(null,50,'a salesperson raising their own ceiling');
    raise exception 'FAIL a salesperson configured the discount threshold';
  exception when sqlstate '42501' then null;end;
  perform set_config('request.jwt.claim.sub',v_admin::text,true);
  -- v625: is_super_admin() now additionally requires a Google-SSO session (amr method 'oauth'
  -- plus app_metadata.providers containing 'google'), not merely a super_admins row. v_admin IS
  -- a genuine platform/super-admin actor in this fixture (inserted into super_admins above), so
  -- this is the same session, just carrying the claims a real platform login would present.
  perform set_config('request.jwt.claims',jsonb_build_object('sub',v_admin,'role','authenticated',
    'amr',jsonb_build_array(jsonb_build_object('method','oauth')),
    'app_metadata',jsonb_build_object('providers',jsonb_build_array('google')))::text,true);

  -- =====================================================================
  -- FIXTURE 3 -- verified payment with no applicable v78 rate.
  -- =====================================================================
  update public.consultant_commission_policies
     set effective_to=clock_timestamp()-interval '1 hour'
   where tier='junior' and effective_to is null;

  insert into public.sme_companies(legal_name,registration_number)
  values('V512 Unrated Proof','T25LL5122C') returning id into v_p3_company;
  insert into public.businesses(name,slug,legal_name,registration_number,is_synthetic)
  values('V512 Unrated Proof','v512-unrated-proof','V512 Unrated Proof','T25LL5122C',true)
  returning id into v_business3;
  -- The prospect stays unconverted on purpose: the accrual reaches its lead
  -- through the commercial terms the subscription names, not through the
  -- conversion pointer, and v79 freezes terms once a prospect has converted.
  insert into public.sme_prospects(company_id,current_stage_key,assigned_consultant_id,
    ownership_state,queue_key,next_action_at,created_by)
  values(v_p3_company,'closed_won',v_junior_consultant,'owned',null,
    clock_timestamp()+interval '1 day',v_admin) returning id into v_p3;
  insert into public.sme_commercial_terms(prospect_id,version,plan_code,product_code,billing_cycle,
    seats,currency,accepted_value_cents,owner_email,contract_status,accepted_at,
    closing_consultant_id,source_consultant_id,created_by)
  values(v_p3,1,'peekaa_core','loyalty','annual',1,'SGD',120000,'owner-v512@example.invalid',
    'accepted',clock_timestamp(),v_junior_consultant,v_junior_consultant,v_admin)
  returning id into v_terms3;
  insert into public.subscriptions(business_id,status,currency,billing_provider,billing_cadence,
    cadence_months,plan_code,product_code,commercial_terms_id,seat_limit,base_price_cents,
    included_seats,period_subtotal_cents,period_tax_cents,period_total_cents,payment_status,
    obligation_period_start,obligation_period_end)
  values(v_business3,'incomplete','SGD','manual','annual',12,'peekaa_core','loyalty',v_terms3,1,120000,
    1,120000,0,120000,'not_collected',current_date,current_date+364);

  perform public.platform_upsert_billing_contact_v156(jsonb_build_object('business_id',v_business3,
    'business_display_name','V512 Unrated Proof','legal_entity_name','V512 Unrated Proof',
    'registration_number','T25LL5122C','billing_address',jsonb_build_object('line1','2 Synthetic Street'),
    'country','Singapore','contact_name','Unrated Owner','email','owner-v512@example.invalid',
    'recipient_role','primary','active',true),'51200000-0000-4000-8000-000000000030');
  v_invoice_result:=public.platform_create_manual_invoice_v156(v_business3,current_date,current_date+7,
    current_date,current_date+364,
    '[{"description":"Peekaa annual subscription","quantity":1,"unit_amount_cents":120000}]'::jsonb,
    0,'51200000-0000-4000-8000-000000000031');
  v_invoice3:=(v_invoice_result#>>'{document,id}')::uuid;
  v_upload3:=public.platform_prepare_manual_evidence_upload_v156(v_invoice3,'proof.pdf','application/pdf',
    '51200000-0000-4000-8000-000000000032');
  insert into storage.objects(id,bucket_id,name,owner_id,metadata)
  values('51200000-0000-4000-8000-000000000033','sme-private',v_upload3->>'object_path',
    v_admin::text,'{"mimetype":"application/pdf"}'::jsonb);
  v_payment_result:=public.platform_record_manual_payment_v156(v_invoice3,120000,'V512-UNRATED-PROOF',
    current_date,'6357',v_upload3->>'object_path','51200000-0000-4000-8000-000000000034');
  v_payment3:=(v_payment_result#>>'{payment,id}')::uuid;
  -- v625: is_super_admin() now additionally requires a Google-SSO session. v_verifier IS a
  -- genuine super_admins row (inserted above), so add the same claims a real platform login
  -- would present.
  perform set_config('request.jwt.claim.sub',v_verifier::text,true);
  perform set_config('request.jwt.claims',jsonb_build_object('sub',v_verifier,'role','authenticated',
    'amr',jsonb_build_array(jsonb_build_object('method','oauth')),
    'app_metadata',jsonb_build_object('providers',jsonb_build_array('google')))::text,true);
  perform public.platform_verify_manual_payment_v156(v_payment3,'verified','Independent synthetic verification',
    '51200000-0000-4000-8000-000000000035');

  -- D4. No applicable rate is recorded as a zero accrual that names the gap,
  --     never as a silent skip and never as an invented rate.
  select count(*) into v_count from public.sme_commission_accruals_v512 where business_id=v_business3;
  if v_count<>1 then raise exception 'FAIL an unrated verified payment produced % accruals',v_count;end if;
  select * into v_accrual from public.sme_commission_accruals_v512 where business_id=v_business3;
  if v_accrual.rate_bps<>0 or v_accrual.rate_source<>'unresolved' or v_accrual.policy_id is not null
     or v_accrual.commission_cents<>0 then
    raise exception 'FAIL an unrated accrual invented a rate (% bps, source %)',
      v_accrual.rate_bps,v_accrual.rate_source;end if;
  if coalesce(v_accrual.zero_rate_reason,'') not like '%no v78 consultant commission policy%' then
    raise exception 'FAIL a zero accrual did not name the gap (reason %)',v_accrual.zero_rate_reason;end if;
  if v_accrual.basis_cents<>120000 or v_accrual.closing_consultant_id<>v_junior_consultant then
    raise exception 'FAIL an unrated accrual lost its basis or attribution';end if;
end $$;

select 'PASS v512 immutable commercial terms, attribution, discount maker-checker and idempotent commission accrual' result;
rollback;
