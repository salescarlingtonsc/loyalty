-- NESTLY v90 — production-readiness repair discovered by the live release gate.
--
-- v79 onboarding and activation already maintain businesses.updated_at, but the
-- original businesses relation did not contain that column. Add the missing
-- lifecycle timestamp so both guarded RPCs compile and execute atomically.

begin;

-- Sales access is deliberately limited to its CRM/reporting surface even if a
-- malformed row is inserted outside the public grant RPC.
alter table public.platform_access_grants_v89
  add constraint platform_access_grants_v90_sales_modules_check check(
    role<>'sales_staff'
    or (
      not(module_perms?'*')
      and (module_perms-array['onboarding','firms','reports']::text[])='{}'::jsonb
    )
  );

create or replace function app.v89_platform_can(
  p_module text,p_mode text default 'r'
)
returns boolean language sql stable security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
  select case
    when app.is_super_admin() then true
    when p_mode not in ('r','rw') then false
    else coalesce((
      select case
        when grant_row.role='sales_staff'
             and p_module not in ('onboarding','firms','reports') then false
        when p_mode='r' then coalesce(
          grant_row.module_perms->>p_module,
          case when grant_row.role='admin' then grant_row.module_perms->>'*' end
        ) in ('r','rw')
        else coalesce(
          grant_row.module_perms->>p_module,
          case when grant_row.role='admin' then grant_row.module_perms->>'*' end
        )='rw'
      end
      from public.platform_access_grants_v89 grant_row
      where grant_row.user_id=auth.uid() and grant_row.active
    ),false)
  end
$$;

-- Replace the v89 verb heuristic with a finite map of the legacy platform
-- callers. An unknown caller is denied instead of being guessed read-only.
create or replace function app.is_platform_operator_v75()
returns boolean language plpgsql stable security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare v_context text;v_module text;v_mode text;
begin
  if app.is_super_admin() then return true;end if;
  if app.v89_platform_role()<>'admin' then return false;end if;
  get diagnostics v_context=pg_context;
  v_context:=lower(v_context);

  if v_context~E'\\npl/pgsql function platform_list_consultants_v75\\(' then
    v_module:='sectors';v_mode:='r';
  elsif v_context~E'\\npl/pgsql function (platform_get_sme_board_v76|platform_list_prospects_v76|platform_get_prospect_detail_v76|get_business_onboarding_v79|platform_get_import_errors_v86|platform_get_import_batch_v86|platform_list_prospects_v86|platform_get_prospect_workspace_v86|platform_get_prospect_detail_v86|platform_get_sme_analytics_v86)\\(' then
    v_module:='onboarding';v_mode:='r';
  elsif v_context~E'\\npl/pgsql function (platform_create_prospect_v76|platform_update_prospect_v76|platform_assign_prospect_v76|platform_add_prospect_activity_v76|platform_create_prospect_task_v76|platform_complete_prospect_task_v76|platform_move_prospect_stage_v76|platform_stage_prospect_import_v76|platform_commit_prospect_import_v76|convert_sme_prospect_v79|reissue_workspace_owner_invite_v79|start_business_onboarding_v79|refresh_business_onboarding_v79|record_onboarding_manual_evidence_v79|platform_record_company_profile_v86|platform_record_contact_profile_v86|platform_record_qualification_v86|platform_record_activity_detail_v86|platform_record_commercial_detail_v86|platform_record_conversion_configuration_v86|platform_upsert_prospect_contact_v86|platform_move_prospect_stage_v86|platform_analyse_prospect_import_v86|platform_stage_prospect_import_v86|platform_decide_import_row_v86|platform_commit_prospect_import_v86|platform_refresh_prospect_quality_v86)\\(' then
    v_module:='onboarding';v_mode:='rw';
  else
    return false;
  end if;
  return app.v89_platform_can(v_module,v_mode);
end
$$;

revoke all on function app.v89_platform_can(text,text)
  from public,anon,authenticated;
revoke all on function app.is_platform_operator_v75()
  from public,anon,authenticated;

-- Preserve the v89 implementation as an inaccessible base and put the
-- business join kill-switch under the same transaction lock as every claim.
alter function public.customer_join_business_from_qr_v89(text,uuid)
  rename to customer_join_business_from_qr_v89_base_v90;
revoke all on function public.customer_join_business_from_qr_v89_base_v90(text,uuid)
  from public,anon,authenticated,service_role;

create or replace function public.customer_join_business_from_qr_v89(
  p_join_token text,p_idempotency_key uuid
)
returns jsonb language plpgsql security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
begin
  perform 1
  from public.business_customer_join_qr_v89 qr
  join public.businesses business on business.id=qr.business_id
  where qr.token_hash=app.v89_sha256(p_join_token)
    and qr.status='active' and qr.expires_at>now()
    and business.join_enabled
  for share of qr,business;
  if not found then
    raise exception 'join QR is invalid, expired, or paused' using errcode='22023';
  end if;
  return public.customer_join_business_from_qr_v89_base_v90(
    p_join_token,p_idempotency_key
  );
end
$$;

create or replace function public.business_revoke_customer_join_qrs_v90(
  p_business uuid
)
returns jsonb language plpgsql security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare v_count integer;
begin
  if not (app.is_salon_owner(p_business) or app.is_super_admin()) then
    raise exception 'business owner access is required' using errcode='42501';
  end if;
  perform pg_advisory_xact_lock(hashtextextended(
    'v90:join-qr:'||p_business::text,0
  ));
  update public.business_customer_join_qr_v89
  set status='revoked',revoked_at=now()
  where business_id=p_business and status='active';
  get diagnostics v_count=row_count;
  insert into public.audit_log(
    business_id,actor,action,entity,entity_id,detail
  ) values(
    p_business,auth.uid(),'REVOKE_CUSTOMER_JOIN_QRS_V90',
    'businesses',p_business,jsonb_build_object('revoked_count',v_count)
  );
  return jsonb_build_object('business_id',p_business,'revoked_count',v_count);
end
$$;

create or replace function public.business_rotate_customer_join_qr_v90(
  p_business uuid,p_expires_at timestamptz default now()+interval '365 days'
)
returns jsonb language plpgsql security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare v_revoked jsonb;v_created jsonb;
begin
  if not (app.is_salon_owner(p_business) or app.is_super_admin()) then
    raise exception 'business owner access is required' using errcode='42501';
  end if;
  v_revoked:=public.business_revoke_customer_join_qrs_v90(p_business);
  v_created:=public.business_create_customer_join_qr_v89(
    p_business,p_expires_at
  );
  return v_created||jsonb_build_object(
    'replaced_count',coalesce((v_revoked->>'revoked_count')::integer,0)
  );
end
$$;

revoke all on function public.customer_join_business_from_qr_v89(text,uuid)
  from public,anon,authenticated;
revoke all on function public.business_revoke_customer_join_qrs_v90(uuid)
  from public,anon,authenticated;
revoke all on function public.business_rotate_customer_join_qr_v90(uuid,timestamptz)
  from public,anon,authenticated;
revoke all on function public.business_create_customer_join_qr_v89(uuid,timestamptz)
  from public,anon,authenticated;
grant execute on function public.customer_join_business_from_qr_v89(text,uuid)
  to authenticated;
grant execute on function public.business_revoke_customer_join_qrs_v90(uuid)
  to authenticated;
grant execute on function public.business_rotate_customer_join_qr_v90(uuid,timestamptz)
  to authenticated;

alter table public.businesses
  add column if not exists updated_at timestamptz;

update public.businesses
set updated_at=coalesce(activated_at,onboarding_started_at,created_at,now())
where updated_at is null;

alter table public.businesses
  alter column updated_at set default now(),
  alter column updated_at set not null;

comment on column public.businesses.updated_at
  is 'Last workspace lifecycle update; maintained by guarded business mutation RPCs.';

commit;
