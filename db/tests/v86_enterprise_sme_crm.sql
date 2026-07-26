-- Rollback-only v86 enterprise SME CRM acceptance evidence.
-- Run after the canonical chain through v86 in a disposable database.
begin;

create or replace function pg_temp.as_v86_user(p_uid uuid,p_role text default 'authenticated')
returns void language plpgsql as $$
begin
  execute format('set local role %I',p_role);
  perform set_config('request.jwt.claim.sub',coalesce(p_uid::text,''),true);
  perform set_config('request.jwt.claims',json_build_object('sub',p_uid,'role',p_role)::text,true);
end
$$;
grant execute on function pg_temp.as_v86_user(uuid,text) to public;

do $v86_test$
declare
  v_sa uuid:=gen_random_uuid();
  v_outsider uuid:=gen_random_uuid();
  v_consultant_user uuid:=gen_random_uuid();
  v_consultant uuid;
  v_prospect uuid;
  v_company uuid;
  v_contact uuid;
  v_secondary uuid;
  v_version bigint;
  v_result jsonb;
  v_document uuid;
  v_document_request uuid;
  v_document_exchange_token text;
  v_batch uuid;
  v_imported uuid;
  v_before integer;
begin
  if not exists(
    select 1 from storage.buckets
    where id='sme-private' and name='sme-private' and public=false
      and file_size_limit=26214400
      and allowed_mime_types=array[
        'application/pdf','text/csv',
        'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
        'image/png','image/jpeg','image/webp','application/zip'
      ]::text[]
  ) then
    raise exception 'private document bucket constraints were not installed exactly';
  end if;

  insert into auth.users(
    instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at
  ) values
    ('00000000-0000-0000-0000-000000000000',v_sa,'authenticated','authenticated',
     'v86-sa-'||substr(v_sa::text,1,8)||'@example.test','',now(),now(),now()),
    ('00000000-0000-0000-0000-000000000000',v_outsider,'authenticated','authenticated',
     'v86-out-'||substr(v_outsider::text,1,8)||'@example.test','',now(),now(),now()),
    ('00000000-0000-0000-0000-000000000000',v_consultant_user,'authenticated','authenticated',
     'v86-consultant-'||substr(v_consultant_user::text,1,8)||'@example.test','',now(),now(),now());
  insert into public.super_admins(user_id,email,note)
  values(v_sa,'v86-sa-'||substr(v_sa::text,1,8)||'@example.test','v86 rollback fixture');

  perform pg_temp.as_v86_user(v_sa);
  v_result:=public.platform_upsert_consultant_v75(
    null,v_consultant_user,'V86 Senior','senior',current_date-800,true
  );
  reset role;
  v_consultant:=(v_result->'consultant'->>'id')::uuid;

  perform pg_temp.as_v86_user(v_sa);
  v_result:=public.platform_create_prospect_v76(
    '{"legal_name":"V86 Prospect Pte Ltd","trading_name":"V86 Prospect","registration_number":"V86-UEN-1","industry":"retail"}',
    '{"full_name":"V86 Owner","email":"owner-v86@example.test","phone":"81234567"}',
    'new_lead',v_consultant,'{"source_system":"manual","source_type":"manual"}',
    array['Enterprise'],'v86-create-0001'
  );
  reset role;
  v_prospect:=(v_result->'prospect'->>'id')::uuid;
  select company_id,version into v_company,v_version from public.sme_prospects where id=v_prospect;
  select id into v_contact from public.sme_prospect_contacts where prospect_id=v_prospect and is_primary;

  perform pg_temp.as_v86_user(v_sa);
  v_result:=public.platform_record_company_profile_v86(v_company,jsonb_build_object(
    'registration_country','SG','entity_type','private_limited','business_status','active',
    'postal_code','048583','country_code','SG','service_areas',jsonb_build_array('Singapore'),
    'employee_range','10-19','expected_seats',5,'customer_type','b2b',
    'required_integrations',jsonb_build_array('Xero'),'digital_maturity','medium',
    'verification_status','confirmed','source_name','owner confirmation',
    'source_value',jsonb_build_object('postal_code','048583'),
    'confirmed_value',jsonb_build_object('postal_code','048583'),'confirmed',true
  ));
  reset role;
  if (v_result#>>'{profile,version}')::integer<>1
     or (v_result#>>'{profile,registration_country}')<>'SG'
     or (v_result#>>'{profile,confirmed_by}')::uuid<>v_sa then
    raise exception 'company profile version was not preserved';
  end if;

  perform pg_temp.as_v86_user(v_sa);
  v_result:=public.platform_record_contact_profile_v86(v_contact,jsonb_build_object(
    'preferred_name','Owner','decision_role','decision_maker',
    'mobile_original','8123 4567','preferred_channel','whatsapp',
    'consent_basis','legitimate_interest','marketing_opt_in',false
  ));
  reset role;
  if v_result#>>'{profile,mobile_e164}'<>'+6581234567' then
    raise exception 'contact profile normalization failed';
  end if;

  perform pg_temp.as_v86_user(v_sa);
  perform public.platform_record_qualification_v86(v_prospect,jsonb_build_object(
    'primary_problem','Manual retention tracking','pain_points',jsonb_build_array('Fragmented data'),
    'required_features',jsonb_build_array('Unified customer history'),
    'expected_user_count',5,'budget_status','approved',
    'expected_subscription_cents',120000,'risk_level','low','fit_score',90,
    'intent_score',85,'qualification_status','qualified',
    'system_suggested_score',88,'score_reasons',jsonb_build_array('Strong fit'),
    'human_confirmed_score',90
  ));
  reset role;

  perform pg_temp.as_v86_user(v_sa);
  v_result:=public.platform_upsert_prospect_contact_v86(
    v_prospect,null,
    '{"full_name":"V86 Finance","title":"Finance Manager","email":"finance-v86@example.test","is_primary":false,"active":true}',
    '{"department_function":"Finance","decision_role":"finance","preferred_channel":"email","consent_basis":"contract_negotiation"}',
    v_version,'v86-contact-upsert-0001'
  );
  v_result:=public.platform_upsert_prospect_contact_v86(
    v_prospect,null,
    '{"full_name":"V86 Finance","title":"Finance Manager","email":"finance-v86@example.test","is_primary":false,"active":true}',
    '{"department_function":"Finance","decision_role":"finance","preferred_channel":"email","consent_basis":"contract_negotiation"}',
    v_version,'v86-contact-upsert-0001'
  );
  reset role;
  v_secondary:=(v_result#>>'{contact,id}')::uuid;
  if coalesce((v_result->>'replayed')::boolean,false)<>true
     or not exists(select 1 from public.sme_contact_profile_versions where contact_id=v_secondary) then
    raise exception 'buying committee contact upsert was not idempotent';
  end if;
  select version into v_version from public.sme_prospects where id=v_prospect;

  begin
    perform pg_temp.as_v86_user(v_sa);
    perform public.platform_move_prospect_stage_v86(
      v_prospect,'appt_set',v_version,'{"appointment_at":"2026-08-01T02:00:00Z"}',null,'v86-stage-invalid'
    );
    reset role;
    raise exception 'stage accepted missing evidence';
  exception when invalid_parameter_value then reset role;
  end;

  perform pg_temp.as_v86_user(v_sa);
  perform public.platform_move_prospect_stage_v86(
    v_prospect,'appt_set',v_version,
    jsonb_build_object('appointment_at','2026-08-01T02:00:00Z',
      'appointment_owner',v_consultant,'next_action_at','2026-08-01T02:00:00Z'),
    null,'v86-stage-valid'
  );
  reset role;
  if not exists(select 1 from public.sme_stage_entry_evidence
      where prospect_id=v_prospect and stage_key='appt_set' and prospect_version=v_version)
     or not exists(select 1 from public.sme_prospect_stage_history
      where prospect_id=v_prospect and to_stage_key='appt_set') then
    raise exception 'stage evidence or history was not preserved';
  end if;

  perform pg_temp.as_v86_user(v_sa);
  v_result:=public.platform_request_prospect_document_upload_v86(
    v_prospect,'company_registration','V86 BizFile.pdf','application/pdf',1024,null,'fixture'
  );
  reset role;
  v_document:=(v_result->>'document_version_id')::uuid;
  v_document_request:=(v_result->>'request_id')::uuid;
  v_document_exchange_token:=v_result->>'exchange_token';
  if v_result->>'bucket_id'<>'sme-private' or (v_result->>'signed_url') is not null
     or coalesce((v_result->>'requires_trusted_signer')::boolean,false)<>true then
    raise exception 'document request exposed a public or signed URL';
  end if;
  begin
    perform pg_temp.as_v86_user(v_outsider);
    perform public.platform_request_prospect_document_read_v86(v_document);
    reset role;
    raise exception 'outsider requested a private prospect document';
  exception when insufficient_privilege then reset role;
  end;

  begin
    perform pg_temp.as_v86_user(null,'service_role');
    perform public.service_consume_document_signing_request_v86(
      v_document_request,v_document_exchange_token,v_outsider
    );
    reset role;
    raise exception 'document signer accepted the wrong bound actor';
  exception when invalid_parameter_value then reset role;
  end;
  perform pg_temp.as_v86_user(null,'service_role');
  perform public.service_consume_document_signing_request_v86(
    v_document_request,v_document_exchange_token,v_sa
  );
  v_result:=public.service_get_consumed_document_upload_v86(v_document_request,v_sa);
  if v_result->>'bucket_id'<>'sme-private'
     or (v_result->>'document_version_id')::uuid<>v_document
     or v_result->>'object_path' is null then
    raise exception 'consumed upload target was not resolved by request and actor';
  end if;
  perform public.service_finalize_document_upload_v86(
    v_document_request,repeat('0',64),1024,v_sa
  );
  reset role;
  if not exists(select 1 from public.sme_document_versions
      where id=v_document and status='uploaded' and sha256=repeat('0',64)) then
    raise exception 'document upload finalization did not preserve verified metadata';
  end if;

  perform pg_temp.as_v86_user(v_sa);
  v_result:=public.platform_refresh_prospect_quality_v86(v_prospect);
  reset role;
  if (v_result#>>'{snapshot,total_weight}')::integer<>100 then
    raise exception 'quality weights did not resolve to 100';
  end if;

  perform pg_temp.as_v86_user(v_sa);
  v_result:=public.platform_stage_prospect_import_v86(
    'legacy_crm','v86-import',
    '{"company_name":"Company","email":"Email Address","registration_number":"UEN","stage":"Stage","custom__import_note":"Extra Field"}',
    '[{"Company":"V86 Imported Co","Email Address":"imported-v86@example.test","UEN":"V86-IMPORT-1","Stage":"New Lead","Extra Field":"preserved"},
      {"Company":"Invalid Email Co","Email Address":"not-an-email","UEN":"V86-IMPORT-2","Stage":"New Lead","Extra Field":"invalid"}]',
    'v86-import-stage-0001'
  );
  reset role;
  v_batch:=(v_result->>'batch_id')::uuid;
  if not exists(select 1 from public.sme_import_column_mappings
      where batch_id=v_batch and canonical_field is null and custom_label='Import Note') then
    raise exception 'custom import mapping was not preserved';
  end if;
  select id into v_imported from public.sme_prospect_import_rows
    where batch_id=v_batch and normalized_payload->>'company_name'='Invalid Email Co';
  perform pg_temp.as_v86_user(v_sa);
  perform public.platform_decide_import_row_v86(v_imported,'skip',null,'invalid email');
  v_result:=public.platform_commit_prospect_import_v86(v_batch);
  reset role;
  select prospect_id into v_imported from public.sme_import_commit_ledger
    where batch_id=v_batch and decision='insert';
  if v_imported is null then raise exception 'reviewed import batch did not insert its valid row';end if;
  perform pg_temp.as_v86_user(v_sa);
  perform public.platform_reverse_prospect_import_v86(v_batch,'rollback untouched fixture import');
  reset role;
  if not exists(select 1 from public.sme_prospects
        where id=v_imported and current_stage_key='lost')
     or not exists(select 1 from public.sme_import_batch_reversals where batch_id=v_batch)
     or not exists(select 1 from public.sme_prospect_stage_history
        where prospect_id=v_imported and reason_code='import_reversed')
     or not exists(select 1 from public.sme_import_commit_ledger
        where prospect_id=v_imported and batch_id=v_batch) then
    raise exception 'import batch reversal did not tombstone untouched inserted records';
  end if;

  perform pg_temp.as_v86_user(v_sa);
  v_result:=public.platform_list_prospects_v86(
    '{"source":"manual","priority":"normal"}',now(),50,null,null
  );
  v_result:=public.platform_get_prospect_detail_v86(v_prospect,now(),20);
  v_result:=public.platform_list_prospect_audit_v86(v_prospect,now(),20,null,null);
  v_result:=public.platform_get_sme_analytics_v86(current_date-365,current_date,now(),null,50,null);
  reset role;
  if jsonb_typeof(v_result->'stages')<>'array' then raise exception 'v86 analytics did not return stage metrics';end if;
  begin
    perform pg_temp.as_v86_user(v_outsider);
    perform public.platform_get_sme_analytics_v86(current_date-30,current_date,now(),null,50,null);
    reset role;
    raise exception 'non-platform user opened v86 analytics';
  exception when insufficient_privilege then reset role;
  end;
end
$v86_test$;

rollback;
