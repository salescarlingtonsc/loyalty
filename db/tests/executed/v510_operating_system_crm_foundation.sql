-- Rolled-back acceptance contract for v510. No production data is changed.
begin;

do $$
declare v_definition text;v_unexpected text[];
begin
  if not exists(select 1 from pg_class c join pg_namespace n on n.oid=c.relnamespace
    where n.nspname='public' and c.relname='sme_company_identity_keys_v510' and c.relrowsecurity) then
    raise exception 'FAIL identity registry is absent or not protected by RLS';end if;
  if not exists(select 1 from pg_class c join pg_namespace n on n.oid=c.relnamespace
    where n.nspname='public' and c.relname='sme_lead_intakes_v510' and c.relrowsecurity) then
    raise exception 'FAIL canonical intake ledger is absent or not protected by RLS';end if;
  if not exists(select 1 from pg_indexes where schemaname='public'
    and indexname='sme_company_identity_strong_v510_uk'
    and indexdef ilike '%key_namespace%') then
    raise exception 'FAIL strong identity uniqueness is not provider/jurisdiction scoped';end if;
  if (select count(*) from public.sme_pipeline_transition_rules_v510 where active)<25 then
    raise exception 'FAIL canonical lifecycle graph is incomplete';end if;
  if exists(select 1 from public.sme_prospects prospect
    join public.sme_pipeline_stages stage on stage.stage_key=prospect.current_stage_key
    where prospect.archived_at is null and prospect.converted_business_id is null
      and (stage.kind='active' or prospect.current_stage_key='closed_won')
      and (prospect.next_action_at is null or
        not ((prospect.ownership_state='owned' and prospect.assigned_consultant_id is not null and prospect.queue_key is null)
          or (prospect.ownership_state='queued' and prospect.assigned_consultant_id is null and prospect.queue_key is not null)))) then
    raise exception 'FAIL an active lead has no owner/queue or next action';end if;
  select pg_get_functiondef('public.platform_transition_lead_v510(uuid,text,bigint,text,timestamptz,text,text,jsonb,jsonb,uuid)'::regprocedure)
    into v_definition;
  if v_definition not ilike '%app.v76_replay%'
     or v_definition not ilike '%sme_stage_entry_evidence%'
     or v_definition not ilike '%requires_commercial_terms%' then
    raise exception 'FAIL transition core lacks replay, evidence or commercial gate';end if;
  if has_function_privilege('anon','public.platform_ingest_lead_v510(jsonb,jsonb,jsonb,uuid,timestamptz,uuid)','EXECUTE')
     or has_function_privilege('anon','public.platform_transition_lead_v510(uuid,text,bigint,text,timestamptz,text,text,jsonb,jsonb,uuid)','EXECUTE') then
    raise exception 'FAIL anonymous role can execute CRM writes';end if;
  if has_function_privilege('authenticated','public.platform_move_prospect_stage_v86(uuid,text,bigint,jsonb,jsonb,text)','EXECUTE')
     or has_function_privilege('authenticated','public.platform_move_my_prospect_stage_v89(uuid,text,bigint,text)','EXECUTE')
     or has_function_privilege('authenticated','public.platform_explorer_bulk_assign_v312(uuid[],uuid,text)','EXECUTE')
     or has_function_privilege('authenticated','public.platform_merge_prospects_v184(uuid,uuid,text)','EXECUTE') then
    raise exception 'FAIL a legacy stage bypass remains callable';end if;
  with routines as (
    select procedure.oid,procedure.proname,pg_get_functiondef(procedure.oid) definition
    from pg_proc procedure join pg_namespace namespace on namespace.oid=procedure.pronamespace
    where namespace.nspname='public' and procedure.prokind in ('f','p')
  ) select array_agg(proname order by proname) into v_unexpected from routines
    where has_function_privilege('authenticated',oid,'EXECUTE')
      and definition ilike '%update public.sme_prospects%'
      and definition ilike '%current_stage_key%'
      and proname not in ('activate_business_v79','convert_sme_prospect_v79','start_business_onboarding_v79',
        'platform_archive_prospect_v184','platform_bulk_transfer_leads_v510','platform_claim_lead_v510',
        'platform_reassign_consultant_portfolio_v510','platform_transfer_lead_v510','platform_transition_lead_v510');
  -- Identity resolution is the only intake writer that may materialise the
  -- reviewed lead's initial lifecycle state; it is itself versioned,
  -- idempotent and restricted to super-admins by v510.
  v_unexpected:=array_remove(v_unexpected,'platform_resolve_identity_review_v510');
  if cardinality(v_unexpected)>0 then
    raise exception 'FAIL unexpected authenticated lifecycle writer(s): %',array_to_string(v_unexpected,', ');end if;
end $$;

do $$
declare
  v_admin constant uuid:='50200000-0000-4000-8000-000000000001';
  v_sales constant uuid:='50200000-0000-4000-8000-000000000002';
  v_verifier constant uuid:='50200000-0000-4000-8000-000000000003';
  v_owner constant uuid:='50200000-0000-4000-8000-000000000004';
  v_consultant uuid;v_created jsonb;v_replay jsonb;v_reused jsonb;v_review jsonb;
  v_claim jsonb;v_transition jsonb;v_resolution jsonb;v_conversion jsonb;v_invoice_result jsonb;v_conflict jsonb;v_upload jsonb;
  v_payment_result jsonb;v_prospect uuid;v_company uuid;v_business uuid;v_invoice uuid;v_payment uuid;v_version bigint;
  v_partial_invoice uuid;v_partial_payment uuid;v_partial_upload jsonb;v_owner_token text;v_outreach jsonb;v_outreach_replay jsonb;
  v_existing_business uuid;v_existing_result jsonb;
  v_activity uuid;
  v_review_intake uuid;v_review_updated timestamptz;v_google_company uuid;
  v_owner_base jsonb;v_owner_review jsonb;v_owner_company uuid;v_owner_prospect uuid;v_owner_intake uuid;
  v_batch uuid;v_import_row uuid;v_import_result jsonb;
  v_due timestamptz:=clock_timestamp()+interval '1 hour';
begin
  insert into auth.users(id,email,created_at,updated_at)
  values(v_admin,'v510-admin@example.invalid',clock_timestamp(),clock_timestamp()),
    (v_sales,'v510-sales@example.invalid',clock_timestamp(),clock_timestamp()),
    (v_verifier,'v510-verifier@example.invalid',clock_timestamp(),clock_timestamp()),
    (v_owner,'owner-v510@example.invalid',clock_timestamp(),clock_timestamp());
  update auth.users set email_confirmed_at=clock_timestamp() where id=v_owner;
  insert into public.super_admins(user_id,email,note)
  values(v_admin,'v510-admin@example.invalid','synthetic rolled-back v510 proof'),
    (v_verifier,'v510-verifier@example.invalid','synthetic independent payment verifier');
  insert into public.platform_access_grants_v89(user_id,role,module_perms,created_by,updated_by)
  values(v_sales,'sales_staff','{"onboarding":"rw"}'::jsonb,v_admin,v_admin);
  insert into public.platform_consultants(user_id,display_name,tier,employment_started_on,created_by)
  values(v_sales,'V510 Synthetic Seller','senior',current_date,v_admin) returning id into v_consultant;
  perform set_config('request.jwt.claim.sub',v_admin::text,true);
  -- v625: is_super_admin() now additionally requires a Google-SSO session (amr method 'oauth'
  -- plus app_metadata.providers containing 'google'), not merely a super_admins row. v_admin IS
  -- a genuine platform/super-admin actor in this fixture (inserted into super_admins above), so
  -- this is the same session, just carrying the claims a real platform login would present.
  perform set_config('request.jwt.claims',jsonb_build_object('sub',v_admin,'role','authenticated',
    'amr',jsonb_build_array(jsonb_build_object('method','oauth')),
    'app_metadata',jsonb_build_object('providers',jsonb_build_array('google')))::text,true);

  insert into public.businesses(name,slug,legal_name,registration_number,place_id,postal_code,is_synthetic)
  values('Existing Merchant Proof','v510-existing-merchant','Existing Merchant Proof','T25LIVE502A',
    'v510-live-place','049318',true) returning id into v_existing_business;
  v_existing_result:=public.platform_ingest_lead_v510(
    '{"legal_name":"Existing Merchant Proof","registration_number":"T25LIVE502A"}'::jsonb,null,
    '{"source_system":"platform_console","source_type":"manual"}'::jsonb,null,
    clock_timestamp()+interval '30 minutes','50200000-0000-4000-8000-000000000040');
  if v_existing_result->>'disposition'<>'existing_merchant'
     or (v_existing_result->>'business_id')::uuid<>v_existing_business
     or exists(select 1 from public.sme_prospects where company_id=(v_existing_result->>'company_id')::uuid
       and converted_business_id is null) then
    raise exception 'FAIL UEN intake created a prospect for an existing merchant';end if;
  v_existing_result:=public.platform_ingest_lead_v510(
    '{"legal_name":"Renamed Existing Merchant","place_id":"v510-live-place","place_provider":"google_places"}'::jsonb,
    null,'{"source_system":"google_places","source_type":"directory","external_id":"v510-live-place"}'::jsonb,
    null,clock_timestamp()+interval '30 minutes','50200000-0000-4000-8000-000000000041');
  if v_existing_result->>'disposition'<>'existing_merchant'
     or (v_existing_result->>'business_id')::uuid<>v_existing_business then
    raise exception 'FAIL Place ID intake created a prospect for an existing merchant';end if;
  v_existing_result:=public.platform_ingest_lead_v510(
    '{"legal_name":"Existing Merchant Proof","postal_code":"049318"}'::jsonb,null,
    '{"source_system":"referral_form","source_type":"referral"}'::jsonb,null,
    clock_timestamp()+interval '30 minutes','50200000-0000-4000-8000-000000000042');
  if v_existing_result->>'disposition'<>'existing_merchant'
     or (v_existing_result->>'business_id')::uuid<>v_existing_business then
    raise exception 'FAIL name and postal intake created a prospect for an existing merchant';end if;

  v_created:=public.platform_ingest_lead_v510(
    '{"legal_name":"V510 Operating Proof","registration_number":"T25LL5020A","phone":"+65 6123 4502"}'::jsonb,
    '{"full_name":"Proof Owner","email":"owner-v510@example.invalid","phone":"+65 6123 4502"}'::jsonb,
    '{"source_system":"platform_console","source_type":"manual"}'::jsonb,
    null,v_due,'50200000-0000-4000-8000-000000000010');
  if v_created->>'disposition'<>'created' then raise exception 'FAIL first canonical intake did not create';end if;
  v_prospect:=(v_created->>'prospect_id')::uuid;v_company:=(v_created->>'company_id')::uuid;
  begin
    perform public.platform_ingest_lead_v510('{"legal_name":"Forgotten Until 2030"}'::jsonb,
      '{"full_name":"Late Follow-up","email":"late-v510@example.invalid"}'::jsonb,
      '{"source_system":"platform_console","source_type":"manual"}'::jsonb,null,
      clock_timestamp()+interval '365 days','50200000-0000-4000-8000-000000000028');
    raise exception 'FAIL intake accepted a lead outside its SLA';
  exception when sqlstate '22023' then null;end;
  select version into v_version from public.sme_prospects where id=v_prospect;
  begin
    perform public.platform_update_prospect_v76(v_prospect,v_version,
      jsonb_build_object('next_action_at',clock_timestamp()+interval '365 days'),
      'v510-legacy-profile-sla');
    raise exception 'FAIL legacy profile editor bypassed the canonical SLA';
  exception when sqlstate '23514' then null;end;
  begin
    perform public.platform_create_prospect_task_v76(v_prospect,'Impossible future follow-up',
      clock_timestamp()+interval '365 days',null,'v510-task-sla');
    raise exception 'FAIL task projection bypassed the canonical SLA';
  exception when sqlstate '23514' then null;end;
  insert into public.sme_prospect_activities(prospect_id,activity_type,summary,created_by)
    values(v_prospect,'note','Shadow follow-up proof',v_admin) returning id into v_activity;
  begin
    insert into public.sme_activity_detail_versions(activity_id,version,next_action,next_action_due_at,created_source,created_by)
    values(v_activity,1,'Hidden reminder',clock_timestamp()+interval '1 day','manual',v_admin);
    raise exception 'FAIL activity detail retained a shadow next-action system';
  exception when sqlstate '23514' then null;end;
  v_replay:=public.platform_ingest_lead_v510(
    '{"legal_name":"V510 Operating Proof","registration_number":"T25LL5020A","phone":"+65 6123 4502"}'::jsonb,
    '{"full_name":"Proof Owner","email":"owner-v510@example.invalid","phone":"+65 6123 4502"}'::jsonb,
    '{"source_system":"platform_console","source_type":"manual"}'::jsonb,
    null,v_due,'50200000-0000-4000-8000-000000000010');
  if (v_replay->>'prospect_id')::uuid<>v_prospect then raise exception 'FAIL idempotent replay changed lead';end if;
  v_reused:=public.platform_ingest_lead_v510(
    '{"legal_name":"V510 Operating Proof","registration_number":"T25LL5020A"}'::jsonb,null,
    '{"source_system":"referral_form","source_type":"referral"}'::jsonb,
    null,clock_timestamp()+interval '30 minutes','50200000-0000-4000-8000-000000000011');
  if v_reused->>'disposition'<>'reused' or (v_reused->>'company_id')::uuid<>v_company then
    raise exception 'FAIL strong identity did not reuse the Company';end if;
  v_review:=public.platform_ingest_lead_v510(
    '{"legal_name":"Different Claimed Name","phone":"+65 6123 4502"}'::jsonb,null,
    '{"source_system":"campaign","source_type":"paid_advertising"}'::jsonb,
    null,clock_timestamp()+interval '30 minutes','50200000-0000-4000-8000-000000000012');
  if v_review->>'disposition'<>'duplicate_review' then
    raise exception 'FAIL supporting-only identity auto-merged instead of entering review';end if;
  v_review_intake:=(v_review->>'intake_id')::uuid;
  if jsonb_array_length(public.platform_list_identity_reviews_v510(100)->'items')<1 then
    raise exception 'FAIL duplicate review cannot be listed';end if;
  select updated_at into v_review_updated from public.sme_lead_intakes_v510 where id=v_review_intake;
  v_resolution:=public.platform_resolve_identity_review_v510(v_review_intake,'confirm',v_company,
    v_review_updated,'50200000-0000-4000-8000-000000000016');
  if v_resolution->>'disposition'<>'reused' or
     (select status from public.sme_lead_intakes_v510 where id=v_review_intake)<>'committed' then
    raise exception 'FAIL duplicate review did not resolve into canonical Company';end if;
  if (select count(*) from public.sme_companies where registration_number='T25LL5020A')<>1 then
    raise exception 'FAIL duplicate Company created for one UEN';end if;
  begin
    insert into public.sme_companies(legal_name,registration_number)
    values('Punctuation Collision Proof','T25-LL5020A');
    raise exception 'FAIL normalized UEN collision was silently accepted';
  exception when unique_violation then null;end;

  -- A CSV row that lands in canonical duplicate review must not disappear
  -- from the import ledger when an operator resolves it later.
  insert into public.sme_prospect_import_batches(source_system,source_name,total_rows,valid_rows,created_by)
  values('v510_csv','synthetic-v510.csv',1,1,v_admin) returning id into v_batch;
  insert into public.sme_prospect_import_rows(batch_id,row_number,raw_payload,normalized_payload,
    mapped_stage_key,row_status)
  values(v_batch,1,'{"company":"CSV duplicate"}'::jsonb,
    '{"company_name":"CSV duplicate","phone_e164":"+65 6123 4502","contact_name":"CSV Owner"}'::jsonb,
    'new_lead','valid') returning id into v_import_row;
  insert into public.sme_import_row_decision_versions(import_row_id,version,decision,reason,decided_by)
  values(v_import_row,1,'insert','Synthetic canonical insert',v_admin);
  v_import_result:=public.platform_commit_prospect_import_v86(v_batch);
  if v_import_result->>'review_rows'<>'1' or not exists(select 1 from public.sme_prospect_import_rows
      where id=v_import_row and row_status='conflict') then
    raise exception 'FAIL canonical CSV duplicate was not held for review';end if;
  select id,updated_at into v_review_intake,v_review_updated from public.sme_lead_intakes_v510
    where operation_key=v_import_row;
  perform public.platform_resolve_identity_review_v510(v_review_intake,'confirm',v_company,
    v_review_updated,'50200000-0000-4000-8000-000000000031');
  if not exists(select 1 from public.sme_import_commit_ledger where batch_id=v_batch
       and import_row_id=v_import_row and prospect_id=v_prospect)
     or not exists(select 1 from public.sme_prospect_import_rows where id=v_import_row
       and row_status='imported' and prospect_id=v_prospect)
     or not exists(select 1 from public.sme_prospect_import_batches where id=v_batch
       and imported_rows=1 and conflict_rows=0) then
    raise exception 'FAIL reviewed CSV row did not converge into its import ledger';end if;

  insert into public.sme_prospect_import_batches(source_system,source_name,total_rows,valid_rows,created_by)
  values('v510_csv_merge','synthetic-v510-merge.csv',1,1,v_admin) returning id into v_batch;
  insert into public.sme_prospect_import_rows(batch_id,row_number,raw_payload,normalized_payload,
    mapped_stage_key,row_status)
  values(v_batch,1,'{"company":"Reviewed CSV merge"}'::jsonb,
    '{"company_name":"V510 Operating Proof","phone_e164":"+65 6999 0502","email":"merged-v510@example.invalid","contact_name":"Merged Owner"}'::jsonb,
    'new_lead','valid') returning id into v_import_row;
  insert into public.sme_import_row_decision_versions(import_row_id,version,decision,candidate_prospect_id,reason,decided_by)
  values(v_import_row,1,'merge',v_prospect,'Reviewed merge convergence proof',v_admin);
  v_import_result:=public.platform_commit_prospect_import_v86(v_batch);
  if v_import_result->>'merged_rows'<>'1'
     or not exists(select 1 from public.sme_prospect_contacts where prospect_id=v_prospect and active
       and phone='+65 6999 0502' and email='merged-v510@example.invalid')
     or not exists(select 1 from public.sme_company_identity_keys_v510 where company_id=v_company
       and key_type='phone' and normalized_value='+6569990502') then
    raise exception 'FAIL reviewed CSV merge did not converge Company/contact identity';end if;
  v_review:=public.platform_ingest_lead_v510(
    '{"legal_name":"CSV phone replay candidate","phone":"+65 6999 0502"}'::jsonb,null,
    '{"source_system":"platform_console","source_type":"manual"}'::jsonb,null,
    clock_timestamp()+interval '30 minutes','50200000-0000-4000-8000-000000000048');
  if v_review->>'disposition'<>'duplicate_review'
     or not (v_company=any(array(select jsonb_array_elements_text(v_review->'candidate_company_ids')::uuid))) then
    raise exception 'FAIL merged CSV identity was not reusable by later intake';end if;

  perform public.platform_crm_ingest_discovered_v297(
    '[{"source":"google_places","source_id":"v510-google-partial","name":"Provider Truth Café","address":"1 Proof Street","postal_code":"018989","latitude":"1.2801","longitude":"103.8501","rating":"4.7","review_count":"52","phone":"+65 6000 0502","website":"https://provider-proof.invalid"}]'::jsonb,
    '{"provider":"google_places","proof":"full"}'::jsonb,true,1,1);
  select company_id into v_google_company from public.sme_company_sources
    where source='google_places' and source_id='v510-google-partial';
  perform public.platform_crm_ingest_discovered_v297(
    '[{"source":"google_places","source_id":"v510-google-partial","name":"Provider Truth Café"}]'::jsonb,
    '{"provider":"google_places","proof":"partial"}'::jsonb,true,1,0);
  if not exists(select 1 from public.sme_company_locations where company_id=v_google_company
      and address='1 Proof Street' and postal_code='018989' and latitude=1.2801 and longitude=103.8501)
     or not exists(select 1 from public.sme_company_market_facts where company_id=v_google_company
      and rating=4.7 and review_count=52 and provider_phone='+65 6000 0502'
      and provider_website='https://provider-proof.invalid') then
    raise exception 'FAIL partial provider refresh erased previously collected facts';end if;
  update public.sme_companies set registration_number='T25LLPLACE1' where id=v_google_company;
  v_conflict:=public.platform_ingest_lead_v510(
    '{"legal_name":"Provider Truth Café","registration_number":"T25LLPLACE2","place_id":"v510-google-partial","place_provider":"google_places"}'::jsonb,
    null,'{"source_system":"google_places","source_type":"directory","external_id":"v510-google-partial"}'::jsonb,
    null,clock_timestamp()+interval '1 hour','50200000-0000-4000-8000-000000000029');
  if v_conflict->>'disposition'<>'duplicate_review'
     or (select count(*) from public.sme_company_identity_keys_v510 where company_id=v_google_company
       and key_type='uen' and confidence='strong')<>1 then
    raise exception 'FAIL matching Place ID silently installed a contradictory UEN';end if;

  -- Reviewed Google intake retains its requested salesperson and provider
  -- facts instead of becoming an ownerless, context-free record.
  v_owner_base:=public.platform_ingest_lead_v510(
    '{"legal_name":"Reviewed Provider Base","phone":"+65 6000 0503"}'::jsonb,null,
    '{"source_system":"platform_console","source_type":"manual"}'::jsonb,
    null,clock_timestamp()+interval '30 minutes','50200000-0000-4000-8000-000000000032');
  v_owner_company:=(v_owner_base->>'company_id')::uuid;v_owner_prospect:=(v_owner_base->>'prospect_id')::uuid;
  -- v625: app.v89_platform_role() returns null on a non-Google session — a delegated platform
  -- grant holds no authority on a password session. v_sales is a genuine
  -- platform_access_grants_v89 sales_staff actor (inserted above), so add the same claims a
  -- real platform login would present.
  perform set_config('request.jwt.claim.sub',v_sales::text,true);
  perform set_config('request.jwt.claims',jsonb_build_object('sub',v_sales,'role','authenticated',
    'amr',jsonb_build_array(jsonb_build_object('method','oauth')),
    'app_metadata',jsonb_build_object('providers',jsonb_build_array('google')))::text,true);
  v_owner_review:=public.platform_ingest_lead_v510(
    '{"legal_name":"Reviewed Provider Candidate","phone":"+65 6000 0503","place_id":"v510-reviewed-place","place_provider":"google_places"}'::jsonb,
    null,jsonb_build_object('source_system','google_places','source_type','directory',
      'external_id','v510-reviewed-place','campaign','owner-preservation-proof','provider_payload',
      jsonb_build_object('address','3 Review Street','postal_code','039503','rating','4.8',
        'review_count','80','phone','+65 6000 0503','website','https://reviewed-provider.invalid')),
    null,clock_timestamp()+interval '30 minutes','50200000-0000-4000-8000-000000000033');
  if v_owner_review->>'disposition'<>'duplicate_review' then
    raise exception 'FAIL reviewed provider fixture did not enter duplicate review';end if;
  v_owner_intake:=(v_owner_review->>'intake_id')::uuid;
  perform set_config('request.jwt.claim.sub',v_admin::text,true);
  -- v625: is_super_admin() now additionally requires a Google-SSO session (amr method 'oauth'
  -- plus app_metadata.providers containing 'google'), not merely a super_admins row. v_admin IS
  -- a genuine platform/super-admin actor in this fixture (inserted into super_admins above), so
  -- this is the same session, just carrying the claims a real platform login would present.
  perform set_config('request.jwt.claims',jsonb_build_object('sub',v_admin,'role','authenticated',
    'amr',jsonb_build_array(jsonb_build_object('method','oauth')),
    'app_metadata',jsonb_build_object('providers',jsonb_build_array('google')))::text,true);
  select updated_at into v_review_updated from public.sme_lead_intakes_v510 where id=v_owner_intake;
  perform public.platform_resolve_identity_review_v510(v_owner_intake,'confirm',v_owner_company,
    v_review_updated,'50200000-0000-4000-8000-000000000034');
  if not exists(select 1 from public.sme_prospects where id=v_owner_prospect
       and assigned_consultant_id=v_consultant and ownership_state='owned')
     or not exists(select 1 from public.sme_company_sources where company_id=v_owner_company
       and source='google_places' and source_id='v510-reviewed-place')
     or not exists(select 1 from public.sme_company_market_facts where company_id=v_owner_company
       and rating=4.8 and review_count=80)
     or not exists(select 1 from public.sme_prospect_source_lineage where prospect_id=v_owner_prospect
       and source_system='google_places' and detail->>'campaign'='owner-preservation-proof') then
    raise exception 'FAIL reviewed intake lost ownership, provider facts or source context';end if;

  -- v625: app.v89_platform_role() returns null on a non-Google session — a delegated platform
  -- grant holds no authority on a password session. v_sales is a genuine
  -- platform_access_grants_v89 sales_staff actor (inserted above), so add the same claims a
  -- real platform login would present.
  perform set_config('request.jwt.claim.sub',v_sales::text,true);
  perform set_config('request.jwt.claims',jsonb_build_object('sub',v_sales,'role','authenticated',
    'amr',jsonb_build_array(jsonb_build_object('method','oauth')),
    'app_metadata',jsonb_build_object('providers',jsonb_build_array('google')))::text,true);
  select version into v_version from public.sme_prospects where id=v_prospect;
  v_claim:=public.platform_claim_lead_v510(v_prospect,v_version,'50200000-0000-4000-8000-000000000013');
  if (v_claim->>'owner')::uuid<>v_consultant then raise exception 'FAIL queued lead claim did not assign salesperson';end if;
  if not exists(select 1 from public.sme_prospect_stage_history where prospect_id=v_prospect
    and from_stage_key='new_lead' and to_stage_key='assigned' and reason_code='lead_claimed') then
    raise exception 'FAIL claim omitted canonical stage history';end if;
  if not exists(select 1 from public.sme_prospects where id=v_prospect and current_stage_key='assigned'
    and next_action_type='first_contact') then raise exception 'FAIL claim left stale ownership action';end if;
  v_outreach:=public.platform_crm_log_outreach_v297(v_prospect,'call','follow_up','Reached owner',null,
    v_due,'v510-outreach-proof');
  v_outreach_replay:=public.platform_crm_log_outreach_v297(v_prospect,'call','follow_up','Reached owner',null,
    v_due,'v510-outreach-proof');
  if not coalesce((v_outreach_replay->>'replayed')::boolean,false)
     or (v_outreach_replay->>'outreach_id')::uuid<>(v_outreach->>'outreach_id')::uuid
     or (select count(*) from public.sme_outreach_records where id=(v_outreach->>'outreach_id')::uuid)<>1
     or (select count(*) from public.sme_prospect_tasks where id=(v_outreach->>'task_id')::uuid)<>1
     or (select count(*) from public.audit_log where action='CRM_OUTREACH_LOGGED_V510'
       and detail->>'outreach_id'=v_outreach->>'outreach_id')<>1 then
    raise exception 'FAIL outreach replay duplicated a write';end if;
  begin
    perform public.platform_crm_log_outreach_v297(v_prospect,'email','follow_up','Changed request',null,
      clock_timestamp()+interval '1 hour','v510-outreach-proof');
    raise exception 'FAIL outreach idempotency key accepted changed input';
  exception when sqlstate '22023' then null;end;
  update public.sme_prospect_tasks set status='cancelled'
    where id=(v_outreach->>'task_id')::uuid;
  select version into v_version from public.sme_prospects where id=v_prospect;
  begin
    perform public.platform_transition_lead_v510(v_prospect,'contacted',v_version,
      'send_follow_up',clock_timestamp()+interval '1 hour',null,null,'{}'::jsonb,null,
      '50200000-0000-4000-8000-000000000017');
    raise exception 'FAIL contacted accepted empty evidence';
  exception when sqlstate '22023' then null;end;
  v_transition:=public.platform_transition_lead_v510(v_prospect,'contacted',v_version,
    'send_follow_up',clock_timestamp()+interval '1 day',null,null,
    jsonb_build_object('contacted_at',clock_timestamp(),'channel','phone','context','Synthetic contact'),
    null,'50200000-0000-4000-8000-000000000014');
  if v_transition->>'to_stage'<>'contacted' then raise exception 'FAIL allowed stage transition did not run';end if;
  begin
    perform public.platform_transition_lead_v510(v_prospect,'closed_won',(v_transition->>'version')::bigint,
      'payment_follow_up',clock_timestamp()+interval '1 day',null,null,
      '{"explicit_confirmation":true}'::jsonb,'{}'::jsonb,
      '50200000-0000-4000-8000-000000000015');
    raise exception 'FAIL illegal contacted to closed_won jump succeeded';
  exception when sqlstate '22023' then null;end;
  v_transition:=public.platform_transition_lead_v510(v_prospect,'interested',(v_transition->>'version')::bigint,
    'prepare_proposal',clock_timestamp()+interval '1 day',null,null,
    jsonb_build_object('context','Merchant confirmed interest','next_follow_up_at',clock_timestamp()+interval '1 day'),
    null,'50200000-0000-4000-8000-000000000018');
  v_transition:=public.platform_transition_lead_v510(v_prospect,'proposal',(v_transition->>'version')::bigint,
    'proposal_follow_up',clock_timestamp()+interval '1 day',null,null,
    jsonb_build_object('proposal_issued',clock_timestamp(),'context','Commercial proposal sent'),
    null,'50200000-0000-4000-8000-000000000019');
  v_transition:=public.platform_transition_lead_v510(v_prospect,'closed_won',(v_transition->>'version')::bigint,
    'payment_follow_up',clock_timestamp()+interval '1 day',null,null,
    '{"explicit_confirmation":true}'::jsonb,
    jsonb_build_object('contract_status','accepted','owner_email','owner-v510@example.invalid',
      'plan_code','peekaa_core','product_code','loyalty','billing_cycle','annual','seats',2,
      'accepted_value_cents',240000,'currency','SGD','onboarding_owner_consultant_id',v_consultant,
      'target_go_live',(current_date+14)::text),
    '50200000-0000-4000-8000-000000000020');
  if exists(select 1 from public.sme_prospects where id=v_prospect
      and (current_stage_key<>'closed_won' or converted_business_id is not null)) then
    raise exception 'FAIL CLOSED_WON created or activated a merchant before payment';end if;
  begin
    update public.sme_prospects set current_stage_key='client' where id=v_prospect;
    raise exception 'FAIL unpaid CLOSED_WON advanced to paid handoff';
  exception when sqlstate '23514' then null;end;
  insert into public.businesses(name,slug,legal_name,registration_number,is_synthetic)
  values('V510 Operating Proof','v510-same-name-other-uen','V510 Operating Proof','T25OTHER502',true);
  v_conversion:=public.convert_sme_prospect_v79(v_prospect,(v_transition->>'version')::bigint,
    'v510-payment-ready-account');
  v_business:=(v_conversion->>'business_id')::uuid;
  v_owner_token:=v_conversion#>>'{owner_invitation,raw_token}';
  if v_conversion->>'outcome'<>'converted' or v_business is null
     or not exists(select 1 from public.sme_prospects where id=v_prospect
       and current_stage_key='account_created' and converted_business_id=v_business)
     or not exists(select 1 from public.businesses where id=v_business and not join_enabled and activated_at is null)
     or not exists(select 1 from public.branches where business_id=v_business and is_default and not active)
     or not exists(select 1 from public.subscriptions where business_id=v_business
       and status='incomplete' and payment_status='not_collected' and base_price_cents=240000
       and period_total_cents=240000 and obligation_period_start is not null and obligation_period_end is not null
       and initial_payment_source is null)
     or not exists(select 1 from public.business_onboarding_items where business_id=v_business
       and item_key='payment_verified' and status='pending' and mandatory and not waivable) then
    raise exception 'FAIL CLOSED_WON did not create an inactive payment-ready Business';end if;
  begin
    update public.sme_companies set legal_name='Illicit post-conversion rename' where id=v_company;
    raise exception 'FAIL converted Company identity remained mutable';
  exception when sqlstate '23514' then null;end;
  perform set_config('request.jwt.claim.sub',v_owner::text,true);
  perform set_config('request.jwt.claims',jsonb_build_object('sub',v_owner,'role','authenticated')::text,true);
  begin
    perform public.accept_workspace_owner_invite_v79(v_owner_token,'v510-owner-before-payment');
    raise exception 'FAIL unpaid owner invitation activated workspace access';
  exception when sqlstate '23514' then null;end;
  perform set_config('request.jwt.claim.sub',v_admin::text,true);
  -- v625: is_super_admin() now additionally requires a Google-SSO session (amr method 'oauth'
  -- plus app_metadata.providers containing 'google'), not merely a super_admins row. v_admin IS
  -- a genuine platform/super-admin actor in this fixture (inserted into super_admins above), so
  -- this is the same session, just carrying the claims a real platform login would present.
  perform set_config('request.jwt.claims',jsonb_build_object('sub',v_admin,'role','authenticated',
    'amr',jsonb_build_array(jsonb_build_object('method','oauth')),
    'app_metadata',jsonb_build_object('providers',jsonb_build_array('google')))::text,true);
  begin
    update public.branches set active=true where business_id=v_business and is_default;
    raise exception 'FAIL unpaid shell enabled an active branch';
  exception when sqlstate '23514' then null;end;
  begin
    insert into public.business_customer_join_qr_v89(business_id,token_hash,expires_at,issued_by)
    values(v_business,repeat('a',64),clock_timestamp()+interval '30 days',v_admin);
    raise exception 'FAIL unpaid shell issued an active customer join QR';
  exception when sqlstate '23514' then null;end;
  begin
    update public.businesses set activated_at=clock_timestamp() where id=v_business;
    raise exception 'FAIL unpaid Business activation was accepted';
  exception when sqlstate '23514' then null;end;

  perform set_config('request.jwt.claim.sub',v_admin::text,true);
  -- v625: is_super_admin() now additionally requires a Google-SSO session (amr method 'oauth'
  -- plus app_metadata.providers containing 'google'), not merely a super_admins row. v_admin IS
  -- a genuine platform/super-admin actor in this fixture (inserted into super_admins above), so
  -- this is the same session, just carrying the claims a real platform login would present.
  perform set_config('request.jwt.claims',jsonb_build_object('sub',v_admin,'role','authenticated',
    'amr',jsonb_build_array(jsonb_build_object('method','oauth')),
    'app_metadata',jsonb_build_object('providers',jsonb_build_array('google')))::text,true);
  perform public.platform_set_billing_profile_v156(jsonb_build_object(
    'registered_address','1 Synthetic Street, Singapore 018989','billing_email','billing-v510@example.invalid',
    'gst_status','not_registered','default_payment_terms','Due on receipt'),
    '50200000-0000-4000-8000-000000000021');
  perform public.platform_upsert_billing_contact_v156(jsonb_build_object('business_id',v_business,
    'business_display_name','V510 Operating Proof','legal_entity_name','V510 Operating Proof',
    'registration_number','T25LL5020A','billing_address',jsonb_build_object('line1','1 Synthetic Street'),
    'country','Singapore','contact_name','Proof Owner','email','owner-v510@example.invalid',
    'recipient_role','primary','active',true),'50200000-0000-4000-8000-000000000022');
  v_invoice_result:=public.platform_create_manual_invoice_v156(v_business,current_date,current_date+7,
    current_date,current_date+364,'[{"description":"Unrelated partial invoice","quantity":1,"unit_amount_cents":120000}]'::jsonb,
    0,'50200000-0000-4000-8000-000000000043');
  v_partial_invoice:=(v_invoice_result#>>'{document,id}')::uuid;
  v_partial_upload:=public.platform_prepare_manual_evidence_upload_v156(v_partial_invoice,'partial.pdf','application/pdf',
    '50200000-0000-4000-8000-000000000044');
  insert into storage.objects(id,bucket_id,name,owner_id,metadata)
  values('50200000-0000-4000-8000-000000000045','sme-private',v_partial_upload->>'object_path',
    v_admin::text,'{"mimetype":"application/pdf"}'::jsonb);
  v_payment_result:=public.platform_record_manual_payment_v156(v_partial_invoice,120000,'V510-PARTIAL-PROOF',
    current_date,'6357',v_partial_upload->>'object_path','50200000-0000-4000-8000-000000000046');
  v_partial_payment:=(v_payment_result#>>'{payment,id}')::uuid;
  -- v625: is_super_admin() now additionally requires a Google-SSO session. v_verifier IS a
  -- genuine super_admins row (inserted above) acting as an independent payment verifier, so add
  -- the same claims a real platform login would present.
  perform set_config('request.jwt.claim.sub',v_verifier::text,true);
  perform set_config('request.jwt.claims',jsonb_build_object('sub',v_verifier,'role','authenticated',
    'amr',jsonb_build_array(jsonb_build_object('method','oauth')),
    'app_metadata',jsonb_build_object('providers',jsonb_build_array('google')))::text,true);
  perform public.platform_verify_manual_payment_v156(v_partial_payment,'verified','Independent partial proof',
    '50200000-0000-4000-8000-000000000047');
  if exists(select 1 from public.subscriptions where business_id=v_business
       and (status<>'incomplete' or payment_status<>'not_collected' or initial_payment_source is not null))
     or exists(select 1 from public.business_onboarding_items where business_id=v_business
       and item_key='payment_verified' and status<>'pending') then
    raise exception 'FAIL unrelated partial payment unlocked the contractual entitlement';end if;
  perform set_config('request.jwt.claim.sub',v_admin::text,true);
  -- v625: is_super_admin() now additionally requires a Google-SSO session (amr method 'oauth'
  -- plus app_metadata.providers containing 'google'), not merely a super_admins row. v_admin IS
  -- a genuine platform/super-admin actor in this fixture (inserted into super_admins above), so
  -- this is the same session, just carrying the claims a real platform login would present.
  perform set_config('request.jwt.claims',jsonb_build_object('sub',v_admin,'role','authenticated',
    'amr',jsonb_build_array(jsonb_build_object('method','oauth')),
    'app_metadata',jsonb_build_object('providers',jsonb_build_array('google')))::text,true);
  v_invoice_result:=public.platform_create_manual_invoice_v156(v_business,current_date,current_date+7,
    current_date,current_date+364,'[{"description":"Peekaa annual subscription","quantity":1,"unit_amount_cents":240000}]'::jsonb,
    0,'50200000-0000-4000-8000-000000000023');
  v_invoice:=(v_invoice_result#>>'{document,id}')::uuid;
  v_upload:=public.platform_prepare_manual_evidence_upload_v156(v_invoice,'proof.pdf','application/pdf',
    '50200000-0000-4000-8000-000000000025');
  insert into storage.objects(id,bucket_id,name,owner_id,metadata)
  values('50200000-0000-4000-8000-000000000024','sme-private',
    v_upload->>'object_path',
    v_admin::text,'{"mimetype":"application/pdf"}'::jsonb);
  if (select balance_due_cents from public.platform_subscription_documents_v156 where id=v_invoice)<>240000
     or not exists(select 1 from storage.objects where bucket_id='sme-private' and name=v_upload->>'object_path')
     or (v_upload->>'object_path')!~('^platform-subscriptions/manual-evidence/'||v_business||'/'||v_invoice||'/[0-9a-f-]+\.(pdf|jpg|png)$') then
    raise exception 'FAIL manual payment fixture is invalid: balance %, path %, object %',
      (select balance_due_cents from public.platform_subscription_documents_v156 where id=v_invoice),
      v_upload->>'object_path',exists(select 1 from storage.objects where name=v_upload->>'object_path');
  end if;
  v_payment_result:=public.platform_record_manual_payment_v156(v_invoice,240000,'V510-PAYMENT-PROOF',
    current_date,'6357',v_upload->>'object_path','50200000-0000-4000-8000-000000000026');
  v_payment:=(v_payment_result#>>'{payment,id}')::uuid;
  -- v625: is_super_admin() now additionally requires a Google-SSO session. v_verifier IS a
  -- genuine super_admins row (inserted above) acting as an independent payment verifier, so add
  -- the same claims a real platform login would present.
  perform set_config('request.jwt.claim.sub',v_verifier::text,true);
  perform set_config('request.jwt.claims',jsonb_build_object('sub',v_verifier,'role','authenticated',
    'amr',jsonb_build_array(jsonb_build_object('method','oauth')),
    'app_metadata',jsonb_build_object('providers',jsonb_build_array('google')))::text,true);
  perform public.platform_verify_manual_payment_v156(v_payment,'verified','Independent synthetic verification',
    '50200000-0000-4000-8000-000000000027');
  if not exists(select 1 from public.business_onboarding_items where business_id=v_business
       and item_key='payment_verified' and status='satisfied')
     or not exists(select 1 from public.subscriptions where business_id=v_business
       and status='active' and payment_status='paid' and initial_payment_source='manual_payment'
       and initial_payment_evidence_id=v_payment and initial_payment_verified_at is not null)
     or not exists(select 1 from public.sme_prospects where id=v_prospect and current_stage_key='account_created') then
    raise exception 'FAIL verified payment did not unlock readiness or regressed the account lifecycle';end if;
  perform set_config('request.jwt.claim.sub',v_owner::text,true);
  perform set_config('request.jwt.claims',jsonb_build_object('sub',v_owner,'role','authenticated')::text,true);
  perform public.accept_workspace_owner_invite_v79(v_owner_token,'v510-owner-after-payment');
  if not exists(select 1 from public.staff where business_id=v_business and user_id=v_owner
       and role='owner' and active) then
    raise exception 'FAIL exact payment did not unlock owner access';end if;
  perform set_config('request.jwt.claim.sub',v_admin::text,true);
  -- v625: is_super_admin() now additionally requires a Google-SSO session (amr method 'oauth'
  -- plus app_metadata.providers containing 'google'), not merely a super_admins row. v_admin IS
  -- a genuine platform/super-admin actor in this fixture (inserted into super_admins above), so
  -- this is the same session, just carrying the claims a real platform login would present.
  perform set_config('request.jwt.claims',jsonb_build_object('sub',v_admin,'role','authenticated',
    'amr',jsonb_build_array(jsonb_build_object('method','oauth')),
    'app_metadata',jsonb_build_object('providers',jsonb_build_array('google')))::text,true);
  begin
    update public.branches set active=true where business_id=v_business and is_default;
    raise exception 'FAIL paid but unactivated shell enabled a branch';
  exception when sqlstate '23514' then null;end;
  if jsonb_array_length(public.platform_get_lead_timeline_v510(v_prospect,100)->'items')<4 then
    raise exception 'FAIL unified lead timeline omitted operating events';end if;
end $$;

select 'PASS v510 canonical identity, ownership, lifecycle, intake and ACL contracts' result;
rollback;
