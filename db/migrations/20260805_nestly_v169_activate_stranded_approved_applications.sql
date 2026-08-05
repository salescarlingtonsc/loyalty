begin;

/*
  V169 — activate applications that were approved BEFORE V167 shipped direct activation.

  Problem this repairs
  --------------------
  Until V167, `platform_decide_business_application_v105` only marked an application
  `approved`; a separate token-based `activate_approved_business_application_v95` call was
  required to actually create the workspace, and the invitation link carrying that token was
  never delivered to the owner. V167 folded activation into the approval itself, but it only
  accepts `status='submitted'`. Any application approved under the old flow is therefore
  stranded: `status='approved'`, `consumed_at is null`, no business, no staff row — and the
  owner signs in to no workspace with no way forward. Re-approving raises
  `application_is_not_pending`.

  This migration adds a super-admin RPC that finishes the activation for exactly those rows,
  using the same provisioning block V167 uses, so a stranded owner is indistinguishable from
  one approved after V167.

  It deliberately does NOT change `platform_decide_business_application_v105`; the forward
  path is already correct.
*/

create or replace function public.platform_activate_approved_application_v169(
  p_application uuid,
  p_idempotency_key uuid
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare
  v_actor uuid:=auth.uid();
  v_application public.business_applications_v95%rowtype;
  v_owner uuid;
  v_bundle public.sector_bundle_versions%rowtype;
  v_business public.businesses%rowtype;
  v_staff uuid;
  v_branch uuid;
  v_slug_base text;
  v_slug text;
  v_suffix integer:=0;
begin
  if not app.is_super_admin() then
    raise exception 'super_admin_required' using errcode='42501';
  end if;
  if p_application is null or p_idempotency_key is null then
    raise exception 'application and idempotency key are required' using errcode='22023';
  end if;

  perform pg_advisory_xact_lock(hashtextextended(p_idempotency_key::text,169));

  select * into v_application
    from public.business_applications_v95 application
   where application.id=p_application
   for update;
  if not found then
    raise exception 'application_not_found' using errcode='22023';
  end if;

  -- Idempotent replay: already activated by V167 or by an earlier call to this function.
  if v_application.status='consumed' then
    return jsonb_build_object(
      'application_id',v_application.id,'status','consumed',
      'business_id',v_application.consumed_business_id,
      'workspace_created',false,'workspace_access',true,'replayed',true
    );
  end if;
  if v_application.status<>'approved' then
    raise exception 'application_is_not_approved' using errcode='23514';
  end if;

  select user_row.id into v_owner
    from auth.users user_row
   where lower(user_row.email)=lower(v_application.contact_email)
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
         decided_by=coalesce(v_application.decided_by,v_actor),
         decided_at=coalesce(v_application.decided_at,now()),
         decision_reason='V169 activation of pre-V167 approved application '||v_application.id,
         updated_at=now()
   where business_id=v_business.id;
  insert into public.business_workspace_control_audit_v94(
    business_id,actor,event_type,prior_status,new_status,reason,control_version
  ) values(
    v_business.id,v_actor,'application_activated','pending','approved',
    'V169 activation of pre-V167 approved application',2
  );

  /*
    Deliberately NOT seeding public.loyalty_programs here.

    `app.c45_loyalty_program_version_write_guard` fires on the version row that
    `seed_loyalty_config_version()` creates, and requires app.c45_owner_loyalty_write(business)
    -> app.is_salon_owner(business) -> an ACTIVE owner staff row whose user_id = auth.uid().
    During activation auth.uid() is the SUPER ADMIN, who by design is never staff of the tenant,
    so the guard raises 42501 and rolls the whole activation back. Proven by rolled-back test
    against production on 2026-08-05.

    The seeded row was an inactive 'draft' preset anyway, so omitting it costs the owner
    nothing: they create their programme through Grow as the owner, where the guard passes.

    NOTE: public.platform_decide_business_application_v105 still contains this exact insert and
    is therefore believed to fail for every new approval. That is tracked separately — this
    migration only repairs the already-stranded rows and must not be read as fixing it.
  */
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

  insert into public.business_application_audit_v95(
    application_id,event_type,actor,prior_status,new_status,reason,detail
  ) values(
    v_application.id,'invitation_consumed',v_owner,'approved','consumed',
    'V169 activated an application approved before direct activation shipped',
    jsonb_build_object('business_id',v_business.id,'activated_by',v_actor)
  );
  insert into public.audit_log(
    business_id,actor,action,entity,entity_id,detail
  ) values(
    v_business.id,v_actor,'STRANDED_APPLICATION_ACTIVATED_V169',
    'businesses',v_business.id,jsonb_build_object(
      'application_id',v_application.id,
      'owner_user_id',v_owner,
      'sector_bundle_version_id',v_bundle.id,
      'originally_decided_at',v_application.decided_at
    )
  );

  return jsonb_build_object(
    'application_id',v_application.id,'status','consumed',
    'business_id',v_business.id,'business_slug',v_business.slug,
    'owner_staff_id',v_staff,'default_branch_id',v_branch,
    'workspace_created',true,'workspace_access',true,
    'approved_email',v_application.contact_email,'replayed',false
  );
end
$$;

revoke all on function public.platform_activate_approved_application_v169(uuid,uuid)
  from public,anon,authenticated;
grant execute on function public.platform_activate_approved_application_v169(uuid,uuid)
  to authenticated;

comment on function public.platform_activate_approved_application_v169(uuid,uuid) is
  'V169 super-admin repair: finish workspace activation for applications approved before V167 shipped direct activation (status=approved, consumed_at is null). Idempotent on already-consumed rows.';

commit;
