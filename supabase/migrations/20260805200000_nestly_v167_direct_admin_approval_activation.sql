begin;

create or replace function public.platform_decide_business_application_v105(
  p_application uuid,
  p_decision text,
  p_reason text,
  p_expected_version bigint,
  p_idempotency_key uuid
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare
  v_actor uuid:=auth.uid();
  v_reason text:=case
    when p_decision='approved' then 'Approved by Super Admin'
    else btrim(coalesce(p_reason,''))
  end;
  v_request_hash text;
  v_receipt public.platform_application_decision_receipts_v105%rowtype;
  v_application public.business_applications_v95%rowtype;
  v_owner uuid;
  v_bundle public.sector_bundle_versions%rowtype;
  v_business public.businesses%rowtype;
  v_staff uuid;
  v_branch uuid;
  v_slug_base text;
  v_slug text;
  v_suffix integer:=0;
  v_response jsonb;
begin
  if not app.is_super_admin() then
    raise exception 'super_admin_required' using errcode='42501';
  end if;
  if p_application is null or p_idempotency_key is null
     or p_decision not in ('approved','rejected')
     or length(v_reason) not between 3 and 1000
     or p_expected_version is null
  then
    raise exception 'valid decision, reason, version and idempotency key are required'
      using errcode='22023';
  end if;

  v_request_hash:=app.v95_sha256(concat_ws('|',
    p_application::text,p_decision,v_reason,p_expected_version::text
  ));
  perform pg_advisory_xact_lock(hashtextextended(p_idempotency_key::text,105));

  select * into v_receipt
    from public.platform_application_decision_receipts_v105 receipt
   where receipt.idempotency_key=p_idempotency_key
   for update;
  if found then
    if v_receipt.actor<>v_actor
       or v_receipt.application_id<>p_application
       or v_receipt.request_hash<>v_request_hash then
      raise exception 'application_decision_idempotency_conflict'
        using errcode='22023';
    end if;
    select * into v_application
      from public.business_applications_v95 application
     where application.id=p_application
     for update;
    if v_application.status not in (v_receipt.decision,'consumed') then
      raise exception 'application_decision_receipt_state_conflict'
        using errcode='40001';
    end if;
    return jsonb_build_object(
      'application_id',p_application,
      'status',v_application.status,
      'version',v_application.version,
      'business_id',v_application.consumed_business_id,
      'workspace_created',v_application.status='consumed',
      'workspace_access',v_application.status='consumed',
      'replayed',true,
      'response_version',v_receipt.response_version
    );
  end if;

  select * into v_application
    from public.business_applications_v95 application
   where application.id=p_application
   for update;
  if not found then
    raise exception 'application_not_found' using errcode='22023';
  end if;
  if v_application.status<>'submitted' then
    raise exception 'application_is_not_pending' using errcode='23514';
  end if;
  if v_application.version<>p_expected_version then
    raise exception 'application_version_conflict' using errcode='40001';
  end if;

  if p_decision='rejected' then
    update public.business_applications_v95
       set status='rejected',version=version+1,decided_by=v_actor,
           decided_at=now(),decision_reason=v_reason,updated_at=now()
     where id=p_application
     returning * into v_application;
    insert into public.business_application_audit_v95(
      application_id,event_type,actor,prior_status,new_status,reason
    ) values(
      p_application,'rejected',v_actor,'submitted','rejected',v_reason
    );
    insert into public.platform_application_decision_receipts_v105(
      idempotency_key,application_id,actor,request_hash,decision,
      invitation_id,response_version
    ) values(
      p_idempotency_key,p_application,v_actor,v_request_hash,'rejected',
      null,1
    ) returning * into v_receipt;
    return jsonb_build_object(
      'application_id',p_application,'status','rejected',
      'version',v_application.version,'workspace_created',false,
      'workspace_access',false,'replayed',false,'response_version',1
    );
  end if;

  select user_row.id into v_owner
    from auth.users user_row
   where lower(user_row.email)=v_application.contact_email
     and coalesce(user_row.email_confirmed_at,user_row.confirmed_at) is not null
   order by user_row.created_at asc,user_row.id asc
   limit 1;
  if v_owner is null then
    raise exception 'owner_account_not_found_for_application' using errcode='42501';
  end if;
  if exists(select 1 from public.staff staff_row where staff_row.user_id=v_owner) then
    raise exception 'owner_account_already_has_workspace' using errcode='42501';
  end if;

  select * into v_bundle
    from public.sector_bundle_versions
   where sector_key=v_application.sector_key and status='published';
  if not found then
    raise exception 'published_sector_required' using errcode='23514';
  end if;

  v_slug_base:=lower(regexp_replace(v_application.business_name,'[^a-zA-Z0-9]+','-','g'));
  v_slug_base:=trim(both '-' from v_slug_base);
  if length(v_slug_base)<3 then
    v_slug_base:='business-'||left(v_application.public_reference::text,8);
  end if;
  v_slug_base:=left(v_slug_base,60);
  v_slug:=v_slug_base;
  while exists(select 1 from public.businesses where slug=v_slug) loop
    v_suffix:=v_suffix+1;
    v_slug:=left(v_slug_base,55)||'-'||v_suffix::text;
  end loop;

  update public.business_applications_v95
     set status='approved',version=version+1,decided_by=v_actor,
         decided_at=now(),decision_reason=v_reason,updated_at=now()
   where id=p_application
   returning * into v_application;
  insert into public.business_application_audit_v95(
    application_id,event_type,actor,prior_status,new_status,reason
  ) values(
    p_application,'approved',v_actor,'submitted','approved',v_reason
  );

  update public.business_application_invitations_v95 invitation
     set revoked_at=coalesce(invitation.revoked_at,now())
   where invitation.application_id=p_application
     and invitation.revoked_at is null
     and invitation.consumed_at is null;

  insert into public.businesses(name,slug,industry,enabled_modules)
  values(v_application.business_name,v_slug,v_application.sector_key,v_bundle.modules)
  returning * into v_business;
  insert into public.staff(business_id,user_id,role,full_name,active)
  values(v_business.id,v_owner,'owner',v_application.contact_name,true)
  returning id into v_staff;
  insert into public.branches(business_id,name,is_default,active)
  values(v_business.id,v_application.business_name,true,true)
  returning id into v_branch;
  insert into public.staff_branches(business_id,staff_id,branch_id)
  values(v_business.id,v_staff,v_branch);

  update public.business_workspace_controls_v94
     set approval_status='approved',version=version+1,
         decided_by=v_actor,decided_at=v_application.decided_at,
         decision_reason='direct super-admin application approval '||v_application.id,
         updated_at=now()
   where business_id=v_business.id;
  insert into public.business_workspace_control_audit_v94(
    business_id,actor,event_type,prior_status,new_status,reason,control_version
  ) values(
    v_business.id,v_actor,'application_activated','pending','approved',
    'direct super-admin application approval',2
  );
  insert into public.loyalty_programs(
    business_id,kind,earn_points_per_dollar,redeem_points,
    reward_credit_cents,active,loyalty_model,configuration_status,
    recommendation_source
  ) values(
    v_business.id,'points',1,800,2000,false,'classic','draft',
    'onboarding_preset'
  );
  insert into public.subscriptions(business_id) values(v_business.id)
  on conflict(business_id) do nothing;
  insert into public.business_sector_assignments(
    business_id,bundle_version_id,version,assigned_by
  ) values(v_business.id,v_bundle.id,1,v_actor);

  update public.business_applications_v95
     set status='consumed',version=version+1,consumed_business_id=v_business.id,
         consumed_by=v_owner,consumed_at=now(),updated_at=now()
   where id=v_application.id
   returning * into v_application;

  v_response:=jsonb_build_object(
    'application_id',v_application.id,'status','consumed',
    'business_id',v_business.id,'business_slug',v_business.slug,
    'owner_staff_id',v_staff,'default_branch_id',v_branch,
    'workspace_created',true,'workspace_access',true,
    'approved_email',v_application.contact_email,
    'replayed',false,'response_version',1
  );

  insert into public.business_application_audit_v95(
    application_id,event_type,actor,prior_status,new_status,reason,detail
  ) values(
    v_application.id,'invitation_consumed',v_owner,'approved','consumed',
    'super-admin approval activated existing owner account directly',
    jsonb_build_object('business_id',v_business.id,'approved_by',v_actor)
  );
  insert into public.audit_log(
    business_id,actor,action,entity,entity_id,detail
  ) values(
    v_business.id,v_actor,'DIRECT_APPLICATION_APPROVED_ACTIVATED_V167',
    'businesses',v_business.id,jsonb_build_object(
      'application_id',v_application.id,
      'owner_user_id',v_owner,
      'sector_bundle_version_id',v_bundle.id
    )
  );
  insert into public.platform_application_decision_receipts_v105(
    idempotency_key,application_id,actor,request_hash,decision,
    invitation_id,response_version
  ) values(
    p_idempotency_key,p_application,v_actor,v_request_hash,'approved',
    null,1
  ) returning * into v_receipt;

  return v_response;
end
$$;

comment on function public.platform_decide_business_application_v105(
  uuid,text,text,bigint,uuid
) is 'V167 retry-safe Super Admin business application decision. Approval directly activates the matching confirmed owner account and workspace without returning an invitation link.';

revoke all on function public.platform_decide_business_application_v105(
  uuid,text,text,bigint,uuid
) from public,anon,authenticated;
grant execute on function public.platform_decide_business_application_v105(
  uuid,text,text,bigint,uuid
) to authenticated;

commit;
