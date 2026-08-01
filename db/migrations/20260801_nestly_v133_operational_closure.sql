-- Nestly V133: retention-safe account-deletion operations.
-- This migration adds an audited operator lifecycle. It deliberately does not
-- delete Auth, financial, security, tenant, customer, or audit records.

begin;

alter table public.account_deletion_requests
  add column claimed_at timestamptz,
  add column claimed_by uuid,
  add column resolution_code text check(
    resolution_code is null or resolution_code in(
      'deleted_where_permitted','anonymised_where_permitted',
      'retained_legal','request_invalid'
    )
  ),
  add column retention_until timestamptz,
  add column resolution_reference text check(
    resolution_reference is null or length(resolution_reference) between 8 and 200
  );

do $$
declare
  v_legacy_active bigint;
begin
  select count(*) into v_legacy_active
    from public.account_deletion_requests
   where status in('processing','completed');
  if v_legacy_active>0 then
    raise exception 'V133 preflight blocked: % legacy processing/completed deletion requests require reviewed lifecycle evidence before migration',v_legacy_active
      using errcode='P0001';
  end if;
end
$$;

alter table public.account_deletion_requests
  add constraint account_deletion_requests_v133_lifecycle_check check(
    (status='pending' and claimed_at is null and claimed_by is null
      and resolution_code is null and retention_until is null
      and resolution_reference is null)
    or
    (status='processing' and claimed_at is not null and claimed_by is not null
      and resolution_code is null and retention_until is null
      and resolution_reference is null)
    or
    (status='completed' and completed_at is not null and claimed_at is not null
      and claimed_by is not null and resolution_code is not null
      and resolution_reference is not null
      and ((resolution_code='retained_legal' and retention_until is not null)
        or (resolution_code<>'retained_legal' and retention_until is null)))
    or status in('rejected','cancelled')
  ) not valid;

alter table public.account_deletion_requests
  validate constraint account_deletion_requests_v133_lifecycle_check;

create table public.account_deletion_request_events(
  id uuid primary key default gen_random_uuid(),
  request_id uuid not null references public.account_deletion_requests(id),
  operator_auth_user_id uuid not null,
  action text not null check(action in('claim','resolve','retention_review')),
  disposition text check(
    disposition is null or disposition in(
      'deleted_where_permitted','anonymised_where_permitted',
      'retained_legal','request_invalid'
    )
  ),
  reason text not null check(length(reason) between 8 and 1000),
  evidence_reference text check(
    evidence_reference is null or length(evidence_reference) between 8 and 200
  ),
  retention_until timestamptz,
  idempotency_key text not null check(length(idempotency_key) between 8 and 200),
  request_fingerprint text not null check(request_fingerprint~'^[0-9a-f]{64}$'),
  result_snapshot jsonb not null check(jsonb_typeof(result_snapshot)='object'),
  created_at timestamptz not null default now(),
  unique(operator_auth_user_id,idempotency_key),
  constraint account_deletion_request_events_shape_check check(
    (action='claim' and disposition is null and evidence_reference is null
      and retention_until is null)
    or
    (action in('resolve','retention_review') and disposition is not null and evidence_reference is not null
      and ((disposition='retained_legal' and retention_until is not null)
        or (disposition<>'retained_legal' and retention_until is null)))
  )
);

create index account_deletion_request_events_request_idx
  on public.account_deletion_request_events(request_id,created_at,id);

alter table public.account_deletion_request_events enable row level security;
alter table public.account_deletion_request_events force row level security;
revoke all on table public.account_deletion_request_events from public, anon, authenticated;
revoke all on table public.account_deletion_request_events from service_role;

create or replace function app.reject_account_deletion_event_mutation_v133()
returns trigger
language plpgsql
security invoker
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
begin
  raise exception 'account deletion evidence is append-only' using errcode='42501';
end
$$;

create trigger account_deletion_request_events_immutable_rows_v133
before update or delete on public.account_deletion_request_events
for each row execute function app.reject_account_deletion_event_mutation_v133();

create trigger account_deletion_request_events_immutable_truncate_v133
before truncate on public.account_deletion_request_events
for each statement execute function app.reject_account_deletion_event_mutation_v133();

create or replace function public.platform_list_account_deletion_requests_v133(
  p_status text default null,
  p_limit integer default 100,
  p_offset integer default 0
) returns table(
  request_id uuid,
  subject_ref uuid,
  status text,
  requested_at timestamptz,
  response_due_at timestamptz,
  updated_at timestamptz,
  claimed_at timestamptz,
  claimed_by uuid,
  resolution_code text,
  retention_until timestamptz,
  resolution_reference text,
  is_overdue boolean,
  total_count bigint
)
language plpgsql
stable
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
begin
  if auth.uid() is null or not app.is_super_admin() then
    raise exception 'super-admin only' using errcode='42501';
  end if;
  if p_status is not null
     and p_status not in('pending','processing','completed','rejected','cancelled') then
    raise exception 'invalid status' using errcode='22023';
  end if;

  return query
    select request_row.id,request_row.subject_ref,request_row.status,
      request_row.requested_at,request_row.response_due_at,request_row.updated_at,
      request_row.claimed_at,request_row.claimed_by,request_row.resolution_code,
      request_row.retention_until,request_row.resolution_reference,
      ((request_row.status in('pending','processing') and now()>request_row.response_due_at)
        or (request_row.status='completed'
          and request_row.resolution_code='retained_legal'
          and request_row.retention_until<=now())),
      count(*) over()
      from public.account_deletion_requests request_row
     where p_status is null or request_row.status=p_status
     order by
       case when (request_row.status in('pending','processing') and now()>request_row.response_due_at)
          or (request_row.status='completed' and request_row.resolution_code='retained_legal'
            and request_row.retention_until<=now()) then 0
         when request_row.status in('pending','processing') then 1 else 2 end,
       request_row.response_due_at,request_row.id
     limit least(greatest(coalesce(p_limit,100),1),100)
    offset least(greatest(coalesce(p_offset,0),0),1000000);
end
$$;

create or replace function public.platform_transition_account_deletion_request_v133(
  p_request uuid,
  p_action text,
  p_reason text,
  p_disposition text default null,
  p_retention_until timestamptz default null,
  p_evidence_reference text default null,
  p_idempotency_key text default null
) returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare
  v_actor uuid:=auth.uid();
  v_action text:=btrim(coalesce(p_action,''));
  v_reason text:=btrim(coalesce(p_reason,''));
  v_disposition text:=nullif(btrim(coalesce(p_disposition,'')),'');
  v_reference text:=nullif(btrim(coalesce(p_evidence_reference,'')),'');
  v_key text:=btrim(coalesce(p_idempotency_key,''));
  v_fingerprint text;
  v_existing public.account_deletion_request_events%rowtype;
  v_request public.account_deletion_requests%rowtype;
  v_receipt jsonb;
begin
  if v_actor is null or not app.is_super_admin() then
    raise exception 'super-admin only' using errcode='42501';
  end if;
  if p_request is null or v_action not in('claim','resolve','retention_review') then
    raise exception 'invalid action' using errcode='22023';
  end if;
  if length(v_reason) not between 8 and 1000
     or length(v_key) not between 8 and 200 then
    raise exception 'reason and idempotency key are required' using errcode='22023';
  end if;
  v_fingerprint:=encode(extensions.digest(convert_to(concat_ws('|',
    p_request::text,v_action,v_reason,coalesce(v_disposition,'-'),
    coalesce(p_retention_until::text,'-'),coalesce(v_reference,'-')
  ),'UTF8'),'sha256'),'hex');

  perform pg_advisory_xact_lock(hashtextextended(p_request::text,133));

  select * into v_existing
    from public.account_deletion_request_events event_row
   where event_row.operator_auth_user_id=v_actor
     and event_row.idempotency_key=v_key;
  if v_existing.id is not null then
    if v_existing.request_fingerprint<>v_fingerprint then
      raise exception 'idempotency key reused with different request' using errcode='22023';
    end if;
    return v_existing.result_snapshot;
  end if;

  if v_action='claim' and (
    v_disposition is not null or p_retention_until is not null or v_reference is not null
  ) then
    raise exception 'claim cannot include resolution fields' using errcode='22023';
  end if;
  if v_action in('resolve','retention_review') then
    if v_disposition not in(
      'deleted_where_permitted','anonymised_where_permitted',
      'retained_legal','request_invalid'
    ) or length(v_reference) not between 8 and 200 then
      raise exception 'valid disposition and evidence reference are required' using errcode='22023';
    end if;
    if v_disposition='retained_legal' and (
      p_retention_until is null or p_retention_until<=now()
    ) then
      raise exception 'future retention deadline required' using errcode='22023';
    end if;
    if v_disposition<>'retained_legal' and p_retention_until is not null then
      raise exception 'retention deadline is only valid for retained records' using errcode='22023';
    end if;
    if v_action='retention_review' and v_disposition='request_invalid' then
      raise exception 'an accepted retained request cannot become invalid' using errcode='22023';
    end if;
  end if;

  select * into v_request
    from public.account_deletion_requests
   where id=p_request for update;
  if v_request.id is null then
    raise exception 'deletion request not found' using errcode='22023';
  end if;

  if v_action='claim' then
    if v_request.status<>'pending' then
      raise exception 'only a pending request can be claimed' using errcode='22023';
    end if;
    update public.account_deletion_requests
       set status='processing',claimed_at=now(),claimed_by=v_actor,updated_at=now()
     where id=v_request.id returning * into v_request;
  elsif v_action='resolve' then
    if v_request.status<>'processing' then
      raise exception 'only a processing request can be resolved' using errcode='22023';
    end if;
    update public.account_deletion_requests
       set status='completed',completed_at=now(),updated_at=now(),
           operator_note=v_reason,resolution_code=v_disposition,
           retention_until=p_retention_until,resolution_reference=v_reference
     where id=v_request.id returning * into v_request;
  else
    if v_request.status<>'completed' or v_request.resolution_code<>'retained_legal'
       or v_request.retention_until is null or v_request.retention_until>now() then
      raise exception 'retention review is available only when legal retention is due' using errcode='22023';
    end if;
    update public.account_deletion_requests
       set completed_at=now(),updated_at=now(),claimed_at=now(),claimed_by=v_actor,
           operator_note=v_reason,resolution_code=v_disposition,
           retention_until=p_retention_until,resolution_reference=v_reference
     where id=v_request.id returning * into v_request;
  end if;

  v_receipt:=jsonb_build_object(
    'request_id',v_request.id,'status',v_request.status,
    'claimed_at',v_request.claimed_at,'completed_at',v_request.completed_at,
    'resolution_code',v_request.resolution_code,
    'retention_until',v_request.retention_until
  );

  insert into public.account_deletion_request_events(
    request_id,operator_auth_user_id,action,disposition,reason,
    evidence_reference,retention_until,idempotency_key,request_fingerprint,result_snapshot
  ) values(
    v_request.id,v_actor,v_action,v_disposition,v_reason,
    v_reference,p_retention_until,v_key,v_fingerprint,v_receipt
  );

  return v_receipt;
end
$$;

create or replace function public.get_account_deletion_request_v131()
returns jsonb
language plpgsql
stable
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare
  v_user uuid:=auth.uid();
  v_row public.account_deletion_requests%rowtype;
begin
  if v_user is null then
    raise exception 'authentication required' using errcode='42501';
  end if;
  select * into v_row from public.account_deletion_requests
   where subject_ref=v_user order by requested_at desc,id desc limit 1;
  if v_row.id is null then return null;end if;
  return jsonb_build_object(
    'request_id',v_row.id,'status',v_row.status,
    'requested_at',v_row.requested_at,'response_due_at',v_row.response_due_at,
    'resolution_code',v_row.resolution_code,'retention_until',v_row.retention_until
  );
end
$$;

revoke all on function public.platform_list_account_deletion_requests_v133(text,integer,integer)
  from public,anon,authenticated;
revoke all on function public.platform_transition_account_deletion_request_v133(
  uuid,text,text,text,timestamptz,text,text
) from public,anon,authenticated;
revoke all on function public.get_account_deletion_request_v131()
  from public,anon,authenticated;
grant execute on function public.platform_list_account_deletion_requests_v133(text,integer,integer)
  to authenticated;
grant execute on function public.platform_transition_account_deletion_request_v133(
  uuid,text,text,text,timestamptz,text,text
) to authenticated;
grant execute on function public.get_account_deletion_request_v131()
  to authenticated;

comment on table public.account_deletion_request_events is
  'V133 append-only privacy-operator evidence. No browser table access and no destructive cascade.';
comment on function public.platform_transition_account_deletion_request_v133(
  uuid,text,text,text,timestamptz,text,text
) is 'V133 super-admin claim/resolution receipt. Resolution records reviewed off-console fulfilment and never deletes data itself.';

commit;
