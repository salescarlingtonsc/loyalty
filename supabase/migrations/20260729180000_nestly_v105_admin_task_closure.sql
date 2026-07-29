-- Nestly v105: atomic platform module policy writes and scalable delegated directories.

begin;

create or replace function public.platform_set_module_overrides_v105(
  p_business uuid,
  p_branch uuid,
  p_changes jsonb,
  p_reason text
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare
  v_actor uuid:=auth.uid();
  v_change jsonb;
  v_module text;
  v_mode text;
  v_expected_version bigint;
  v_prior_mode text;
  v_prior_version bigint;
  v_new_version bigint;
  v_effective record;
  v_results jsonb:='[]'::jsonb;
begin
  if not app.is_super_admin() then
    raise exception 'super_admin_required' using errcode='42501';
  end if;
  if length(btrim(coalesce(p_reason,''))) not between 3 and 1000 then
    raise exception 'module_override_reason_required' using errcode='22023';
  end if;
  if jsonb_typeof(p_changes) is distinct from 'array'
     or jsonb_array_length(p_changes) not between 1 and 100 then
    raise exception 'module_override_changes_required' using errcode='22023';
  end if;
  perform 1 from public.businesses where id=p_business for key share;
  if not found then
    raise exception 'business_not_found' using errcode='22023';
  end if;
  if p_branch is not null and not exists(
    select 1 from public.branches branch
    where branch.id=p_branch and branch.business_id=p_business
  ) then
    raise exception 'branch_not_in_business' using errcode='22023';
  end if;
  if exists(
    select 1
    from jsonb_array_elements(p_changes) change
    group by change->>'module'
    having count(*)>1
  ) then
    raise exception 'duplicate_module_override' using errcode='22023';
  end if;

  -- Validate the complete request before taking any write action.
  for v_change in
    select change
    from jsonb_array_elements(p_changes) change
    order by change->>'module'
  loop
    perform app.v86_assert_object_keys(
      v_change,array['module','mode','expected_version'],'module override change'
    );
    v_module:=v_change->>'module';
    v_mode:=v_change->>'mode';
    if v_module is null or v_module!~'^[a-z][a-z0-9_]*$'
       or v_mode not in ('inherit','disabled','r','rw')
       or jsonb_typeof(v_change->'expected_version') not in ('number','null') then
      raise exception 'valid_module_override_change_required' using errcode='22023';
    end if;
  end loop;

  -- Lock every existing row in deterministic order, then preflight every
  -- optimistic version. Any mismatch aborts the single PostgreSQL transaction.
  perform 1
  from public.platform_module_overrides_v94 override_row
  where override_row.business_id=p_business
    and override_row.branch_scope is not distinct from p_branch
    and override_row.module_key in (
      select change->>'module' from jsonb_array_elements(p_changes) change
    )
  order by override_row.module_key
  for update;

  for v_change in
    select change
    from jsonb_array_elements(p_changes) change
    order by change->>'module'
  loop
    v_module:=v_change->>'module';
    v_prior_version:=null;
    v_expected_version:=case
      when jsonb_typeof(v_change->'expected_version')='number'
        then (v_change->>'expected_version')::bigint
      else null
    end;
    select override_row.version
    into v_prior_version
    from public.platform_module_overrides_v94 override_row
    where override_row.business_id=p_business
      and override_row.branch_scope is not distinct from p_branch
      and override_row.module_key=v_module;
    if found then
      if v_expected_version is null or v_expected_version<>v_prior_version then
        raise exception 'module_override_version_conflict' using errcode='40001';
      end if;
    elsif v_expected_version is not null then
      raise exception 'module_override_version_conflict' using errcode='40001';
    end if;
  end loop;

  for v_change in
    select change
    from jsonb_array_elements(p_changes) change
    order by change->>'module'
  loop
    v_module:=v_change->>'module';
    v_mode:=v_change->>'mode';
    v_prior_mode:=null;
    v_prior_version:=null;
    select override_row.mode,override_row.version
    into v_prior_mode,v_prior_version
    from public.platform_module_overrides_v94 override_row
    where override_row.business_id=p_business
      and override_row.branch_scope is not distinct from p_branch
      and override_row.module_key=v_module;
    if found then
      update public.platform_module_overrides_v94
      set mode=v_mode,version=version+1,reason=btrim(p_reason),
        updated_by=v_actor,updated_at=now()
      where business_id=p_business
        and branch_scope is not distinct from p_branch
        and module_key=v_module
      returning version into v_new_version;
    else
      insert into public.platform_module_overrides_v94(
        business_id,branch_scope,module_key,mode,reason,updated_by
      ) values(
        p_business,p_branch,v_module,v_mode,btrim(p_reason),v_actor
      )
      returning version into v_new_version;
    end if;
    insert into public.platform_module_override_audit_v94(
      business_id,branch_scope,module_key,prior_mode,new_mode,prior_version,
      new_version,reason,actor
    ) values(
      p_business,p_branch,v_module,v_prior_mode,v_mode,v_prior_version,
      v_new_version,btrim(p_reason),v_actor
    );
    select * into v_effective
    from app.effective_platform_module_mode_v94(
      p_business,p_branch,v_module
    );
    v_results:=v_results||jsonb_build_array(jsonb_build_object(
      'business_id',p_business,
      'branch_id',p_branch,
      'module_key',v_module,
      'mode',v_mode,
      'version',v_new_version,
      'effective_mode',v_effective.mode,
      'source',v_effective.source
    ));
  end loop;
  return jsonb_build_object(
    'business_id',p_business,
    'branch_id',p_branch,
    'updated_count',jsonb_array_length(v_results),
    'items',v_results
  );
end
$$;

comment on function public.platform_set_module_overrides_v105(uuid,uuid,jsonb,text)
  is 'v105 super-admin atomic batch module policy writer. Validates and version-checks every change before writing any row.';

revoke all on function public.platform_set_module_overrides_v105(uuid,uuid,jsonb,text)
  from public,anon,authenticated;
grant execute on function public.platform_set_module_overrides_v105(uuid,uuid,jsonb,text)
  to authenticated;

create or replace function public.platform_get_effective_modules_v105(
  p_business uuid,
  p_branch uuid default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare
  v_modules jsonb;
begin
  if not app.v89_platform_can('sectors','r') then
    raise exception 'platform_module_access_required' using errcode='42501';
  end if;
  if p_branch is not null and not exists(
    select 1 from public.branches branch
    where branch.id=p_branch and branch.business_id=p_business
  ) then
    raise exception 'branch_not_in_business' using errcode='22023';
  end if;
  with module_keys as (
    select unnest(business.enabled_modules) module_key
    from public.businesses business where business.id=p_business
    union
    select module_key from public.platform_module_overrides_v94
    where business_id=p_business
    union
    select 'inventory'
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'module_key',module_keys.module_key,
    'mode',resolved.mode,
    'source',resolved.source,
    'version',resolved.version,
    'override_mode',coalesce(scoped.mode,'inherit'),
    'override_version',scoped.version
  ) order by module_keys.module_key),'[]'::jsonb)
  into v_modules
  from module_keys
  cross join lateral app.effective_platform_module_mode_v94(
    p_business,p_branch,module_keys.module_key
  ) resolved
  left join lateral (
    select override_row.mode,override_row.version
    from public.platform_module_overrides_v94 override_row
    where override_row.business_id=p_business
      and override_row.branch_scope is not distinct from p_branch
      and override_row.module_key=module_keys.module_key
  ) scoped on true;
  return jsonb_build_object(
    'business_id',p_business,
    'branch_id',p_branch,
    'workspace_access',app.business_workspace_open_v94(p_business),
    'inventory_global_disabled',true,
    'modules',v_modules
  );
end
$$;

comment on function public.platform_get_effective_modules_v105(uuid,uuid)
  is 'v105 effective module projection plus the exact firm/branch override mode and optimistic version required by the editor.';

revoke all on function public.platform_get_effective_modules_v105(uuid,uuid)
  from public,anon,authenticated;
grant execute on function public.platform_get_effective_modules_v105(uuid,uuid)
  to authenticated;

-- v88 freezes the complete row projection. v105 additionally freezes which of
-- those rows were inside the caller's delegated scope at first-page capture.
-- A later reassignment therefore cannot add, remove, reorder or rewrite rows
-- midway through the same cursor walk.
create table app.platform_firm_snapshot_scopes_v105(
  actor_id uuid not null,
  snapshot_at timestamptz not null,
  scope_key text not null check(scope_key in ('all','own_created_or_assigned')),
  captured_at timestamptz not null default clock_timestamp(),
  primary key(actor_id,snapshot_at),
  foreign key(actor_id,snapshot_at)
    references app.platform_firm_snapshots_v88(actor_id,snapshot_at)
    on delete cascade
);

revoke all privileges on table app.platform_firm_snapshot_scopes_v105
  from public,anon,authenticated;

create or replace function public.platform_list_my_firms_v105(
  p_search text default null,
  p_limit integer default 50,
  p_snapshot_at timestamptz default null,
  p_after_updated_at timestamptz default null,
  p_after_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare
  v_actor uuid:=auth.uid();
  v_limit integer:=least(greatest(coalesce(p_limit,50),1),100);
  v_snapshot_at timestamptz:=coalesce(p_snapshot_at,clock_timestamp());
  v_snapshot_expires_at timestamptz;
  v_current_scope text:=case when app.v89_platform_role()='sales_staff'
    then 'own_created_or_assigned' else 'all' end;
  v_captured_scope text;
  v_result jsonb;
begin
  if not (
    app.v89_platform_can('overview','r')
    or app.v89_platform_can('onboarding','r')
    or app.v89_platform_can('firms','r')
    or app.v89_platform_can('reports','r')
  ) then
    raise exception 'platform firm-list read access is required' using errcode='42501';
  end if;
  if (p_after_updated_at is null)<>(p_after_id is null) then
    raise exception 'complete firm cursor is required' using errcode='22023';
  end if;
  if p_snapshot_at is null and p_after_updated_at is not null then
    raise exception 'snapshot token is required after the first page'
      using errcode='22023';
  end if;

  v_snapshot_expires_at:=app.ensure_platform_firm_snapshot_v88(
    v_actor,v_snapshot_at,p_snapshot_at is null
  );

  if p_snapshot_at is null then
    insert into app.platform_firm_snapshot_scopes_v105(
      actor_id,snapshot_at,scope_key
    ) values(v_actor,v_snapshot_at,v_current_scope)
    on conflict(actor_id,snapshot_at) do nothing;

    if v_current_scope='own_created_or_assigned' then
      delete from app.platform_firm_snapshot_rows_v88 snapshot_row
      where snapshot_row.actor_id=v_actor
        and snapshot_row.snapshot_at=v_snapshot_at
        and (
          nullif(snapshot_row.payload->>'prospect_id','') is null
          or not app.v89_prospect_in_role_scope(
            (snapshot_row.payload->>'prospect_id')::uuid
          )
        );
    end if;
  end if;

  select scope_row.scope_key into v_captured_scope
  from app.platform_firm_snapshot_scopes_v105 scope_row
  where scope_row.actor_id=v_actor
    and scope_row.snapshot_at=v_snapshot_at;
  if v_captured_scope is null then
    raise exception 'delegated firm snapshot token was not found'
      using errcode='22023';
  end if;
  if v_current_scope='own_created_or_assigned' and v_captured_scope='all' then
    raise exception 'firm snapshot scope is no longer permitted'
      using errcode='42501';
  end if;

  with eligible as materialized (
    select snapshot_row.*
    from app.platform_firm_snapshot_rows_v88 snapshot_row
    where snapshot_row.actor_id=v_actor
      and snapshot_row.snapshot_at=v_snapshot_at
      and (
        nullif(btrim(p_search),'') is null
        or snapshot_row.search_text like '%'||lower(btrim(p_search))||'%'
      )
  ), page as materialized (
    select snapshot_row.*
    from eligible snapshot_row
    where p_after_updated_at is null
       or (snapshot_row.updated_at,snapshot_row.row_id)
          <(p_after_updated_at,p_after_id)
    order by snapshot_row.updated_at desc,snapshot_row.row_id desc
    limit v_limit
  )
  select jsonb_build_object(
    'items',coalesce((
      select jsonb_agg(item.payload
        order by item.updated_at desc,item.row_id desc)
      from page item
    ),'[]'::jsonb),
    'scope',v_captured_scope,
    'snapshot_at',v_snapshot_at,
    'snapshot_expires_at',v_snapshot_expires_at,
    'total_count',(select count(*) from eligible),
    'next_cursor',case when (select count(*) from page)=v_limit then (
      select jsonb_build_object('updated_at',item.updated_at,'id',item.row_id)
      from page item order by item.updated_at,item.row_id limit 1
    ) else null end
  ) into v_result;
  return v_result;
end
$$;

comment on function public.platform_list_my_firms_v105(
  text,integer,timestamptz,timestamptz,uuid
)
  is 'v105 role-scoped, searchable, fixed-snapshot keyset-paginated delegated firm and prospect directory.';

revoke all on function public.platform_list_my_firms_v105(
  text,integer,timestamptz,timestamptz,uuid
)
  from public,anon,authenticated;
grant execute on function public.platform_list_my_firms_v105(
  text,integer,timestamptz,timestamptz,uuid
)
  to authenticated;

-- A decision may commit while its HTTP response is lost. Keep the
-- idempotency receipt, never the raw invitation token. An exact replay of an
-- approval rotates the unobserved invitation so the operator can safely
-- recover a usable link without approving the application twice.
create table public.platform_application_decision_receipts_v105(
  idempotency_key uuid primary key,
  application_id uuid not null references public.business_applications_v95(id)
    on delete restrict,
  actor uuid not null references auth.users(id) on delete restrict,
  request_hash text not null check(request_hash~'^[0-9a-f]{64}$'),
  decision text not null check(decision in ('approved','rejected')),
  invitation_id uuid references public.business_application_invitations_v95(id)
    on delete restrict,
  response_version bigint not null check(response_version>0),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index platform_application_decision_receipts_v105_application_idx
  on public.platform_application_decision_receipts_v105(
    application_id,created_at,idempotency_key
  );
alter table public.platform_application_decision_receipts_v105
  enable row level security;
revoke all privileges on table
  public.platform_application_decision_receipts_v105
  from public,anon,authenticated;

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
  v_reason text:=btrim(coalesce(p_reason,''));
  v_request_hash text;
  v_receipt public.platform_application_decision_receipts_v105%rowtype;
  v_application public.business_applications_v95%rowtype;
  v_invitation public.business_application_invitations_v95%rowtype;
  v_raw_token text;
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
  perform pg_advisory_xact_lock(
    hashtextextended(p_idempotency_key::text,105)
  );
  select * into v_receipt
  from public.platform_application_decision_receipts_v105 receipt
  where receipt.idempotency_key=p_idempotency_key
  for update;
  if found then
    if v_receipt.actor<>v_actor
       or v_receipt.application_id<>p_application
       or v_receipt.request_hash<>v_request_hash
    then
      raise exception 'application_decision_idempotency_conflict'
        using errcode='22023';
    end if;
    select * into v_application
    from public.business_applications_v95 application
    where application.id=p_application
    for update;
    if v_application.status<>v_receipt.decision then
      raise exception 'application_decision_receipt_state_conflict'
        using errcode='40001';
    end if;
    if v_receipt.decision='approved' then
      update public.business_application_invitations_v95 invitation
      set revoked_at=coalesce(invitation.revoked_at,now())
      where invitation.application_id=p_application
        and invitation.revoked_at is null
        and invitation.consumed_at is null;
      v_raw_token:=encode(extensions.gen_random_bytes(32),'hex');
      insert into public.business_application_invitations_v95(
        application_id,token_hash,expires_at,issued_by
      ) values(
        p_application,app.v95_sha256(v_raw_token),now()+interval '72 hours',
        v_actor
      ) returning * into v_invitation;
      update public.platform_application_decision_receipts_v105
      set invitation_id=v_invitation.id,
        response_version=response_version+1,updated_at=now()
      where idempotency_key=p_idempotency_key
      returning * into v_receipt;
    end if;
    return jsonb_build_object(
      'application_id',p_application,
      'status',v_application.status,
      'version',v_application.version,
      'approved_email',case when v_receipt.decision='approved'
        then v_application.contact_email else null end,
      'invitation_token',v_raw_token,
      'invitation_expires_at',v_invitation.expires_at,
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
  update public.business_applications_v95
  set status=p_decision,version=version+1,decided_by=v_actor,
    decided_at=now(),decision_reason=v_reason,updated_at=now()
  where id=p_application
  returning * into v_application;
  insert into public.business_application_audit_v95(
    application_id,event_type,actor,prior_status,new_status,reason
  ) values(
    p_application,p_decision,v_actor,'submitted',p_decision,v_reason
  );
  if p_decision='approved' then
    v_raw_token:=encode(extensions.gen_random_bytes(32),'hex');
    insert into public.business_application_invitations_v95(
      application_id,token_hash,expires_at,issued_by
    ) values(
      p_application,app.v95_sha256(v_raw_token),now()+interval '72 hours',
      v_actor
    ) returning * into v_invitation;
  end if;
  insert into public.platform_application_decision_receipts_v105(
    idempotency_key,application_id,actor,request_hash,decision,
    invitation_id,response_version
  ) values(
    p_idempotency_key,p_application,v_actor,v_request_hash,p_decision,
    v_invitation.id,1
  ) returning * into v_receipt;
  return jsonb_build_object(
    'application_id',p_application,
    'status',p_decision,
    'version',v_application.version,
    'approved_email',case when p_decision='approved'
      then v_application.contact_email else null end,
    'invitation_token',v_raw_token,
    'invitation_expires_at',v_invitation.expires_at,
    'replayed',false,
    'response_version',1
  );
end
$$;

comment on function public.platform_decide_business_application_v105(
  uuid,text,text,bigint,uuid
) is 'v105 retry-safe business application decision. Exact approval replays rotate the active one-time invitation without duplicating the decision.';

revoke all on function public.platform_decide_business_application_v105(
  uuid,text,text,bigint,uuid
) from public,anon,authenticated;
grant execute on function public.platform_decide_business_application_v105(
  uuid,text,text,bigint,uuid
) to authenticated;

commit;
