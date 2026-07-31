-- NESTLY v120 — task-first staff blocked time.
-- Forward-only local implementation. Do not apply remotely without release approval.

begin;

create table public.staff_blocked_times (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  branch_id uuid not null,
  staff_id uuid not null,
  starts_at timestamptz not null,
  ends_at timestamptz not null,
  reason text,
  created_by uuid not null,
  created_at timestamptz not null default clock_timestamp(),
  constraint staff_blocked_times_window_v120 check (
    ends_at > starts_at and ends_at <= starts_at + interval '24 hours'
  ),
  constraint staff_blocked_times_reason_v120 check (
    reason is null or (reason = btrim(reason) and char_length(reason) between 1 and 160)
  ),
  foreign key (branch_id,business_id)
    references public.branches(id,business_id) on delete cascade,
  foreign key (staff_id,business_id)
    references public.staff(id,business_id) on delete cascade
);

create index staff_blocked_times_window_v120_idx
  on public.staff_blocked_times (business_id,branch_id,staff_id,starts_at,ends_at);

alter table public.staff_blocked_times enable row level security;
revoke all privileges on table public.staff_blocked_times
  from public,anon,authenticated;

-- The client keeps one key while a write outcome is uncertain. A receipt makes
-- the replay deterministic, while a request hash rejects key reuse with edited
-- input. This table is intentionally API-invisible.
create table app.staff_blocked_time_operations_v120 (
  business_id uuid not null references public.businesses(id) on delete cascade,
  actor uuid not null,
  operation_type text not null
    check (operation_type in ('create','delete')),
  idempotency_key text not null
    check (char_length(idempotency_key) between 1 and 160),
  request_hash text not null check (request_hash ~ '^[0-9a-f]{64}$'),
  response jsonb not null,
  created_at timestamptz not null default clock_timestamp(),
  primary key (business_id,actor,operation_type,idempotency_key)
);

alter table app.staff_blocked_time_operations_v120 enable row level security;
revoke all privileges on table app.staff_blocked_time_operations_v120
  from public,anon,authenticated;

create or replace function app.lock_staff_calendar_v120(
  p_business uuid,p_branch uuid,p_staff uuid
)
returns void
language sql volatile security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
  select pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(
      'v120:staff-calendar:'||p_business::text||':'||p_staff::text,
      120
    )
  )
$$;

revoke all privileges on function app.lock_staff_calendar_v120(uuid,uuid,uuid)
  from public,anon,authenticated;

create or replace function public.list_staff_blocked_times_v120(
  p_business uuid,p_branch uuid,p_from timestamptz,p_to timestamptz
)
returns table (
  id uuid,staff_id uuid,starts_at timestamptz,ends_at timestamptz,reason text
)
language plpgsql stable security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
begin
  if p_business is null or p_branch is null or p_from is null or p_to is null
     or p_to <= p_from or p_to > p_from + interval '366 days'
     or not app.can_module_read_at_v94(p_business,p_branch,'appointments') then
    raise exception 'permission denied or invalid blocked-time window'
      using errcode='42501';
  end if;

  -- A staff member cannot be free at two branches at once. Return local blocks
  -- with their management data and redact cross-branch details to "busy"
  -- while still letting the current branch suppress false availability.
  return query
    select
      case when blocked.branch_id=p_branch then blocked.id else null end,
      blocked.staff_id,blocked.starts_at,blocked.ends_at,
      case when blocked.branch_id=p_branch then blocked.reason else null end
      from public.staff_blocked_times blocked
     where blocked.business_id=p_business
       and exists (
         select 1 from public.staff_branches assignment
          where assignment.business_id=p_business
            and assignment.branch_id=p_branch
            and assignment.staff_id=blocked.staff_id
       )
       and blocked.starts_at < p_to and blocked.ends_at > p_from
     order by blocked.starts_at,blocked.staff_id,blocked.id;
end
$$;

create or replace function public.create_staff_blocked_time_v120(
  p_business uuid,p_branch uuid,p_staff uuid,
  p_starts timestamptz,p_ends timestamptz,p_reason text,
  p_idempotency_key text
)
returns jsonb
language plpgsql security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare
  v_actor uuid:=auth.uid();
  v_timezone text;
  v_reason text:=nullif(btrim(coalesce(p_reason,'')),'');
  v_request_hash text;
  v_existing app.staff_blocked_time_operations_v120%rowtype;
  v_id uuid;
  v_response jsonb;
begin
  if v_actor is null or p_business is null or p_branch is null or p_staff is null
     or not app.can_module_write_at_v94(p_business,p_branch,'appointments') then
    raise exception 'permission denied' using errcode='42501';
  end if;
  if p_starts is null or p_ends is null or p_ends <= p_starts
     or p_ends > p_starts + interval '24 hours'
     or char_length(btrim(coalesce(p_reason,''))) > 160
     or p_idempotency_key is null
     or char_length(p_idempotency_key) not between 1 and 160 then
    raise exception 'invalid blocked time' using errcode='22023';
  end if;

  select branch.timezone into v_timezone
    from public.branches branch
   where branch.business_id=p_business and branch.id=p_branch and branch.active;
  if not found
     or (p_starts at time zone v_timezone)::date
        <> (p_ends at time zone v_timezone)::date then
    raise exception 'blocked time must stay within one active branch day'
      using errcode='22023';
  end if;

  if not exists (
    select 1
      from public.staff person
      join public.staff_branches assignment
        on assignment.business_id=person.business_id
       and assignment.staff_id=person.id
       and assignment.branch_id=p_branch
     where person.business_id=p_business and person.id=p_staff and person.active
  ) then
    raise exception 'staff is not active at this branch' using errcode='42501';
  end if;

  v_request_hash:=app.v41_request_hash(jsonb_build_object(
    'business_id',p_business,'branch_id',p_branch,'staff_id',p_staff,
    'starts_at',p_starts,'ends_at',p_ends,'reason',v_reason
  )::text);

  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(
    'v120:create:'||p_business::text||':'||v_actor::text||':'||p_idempotency_key,
    120
  ));

  select * into v_existing
    from app.staff_blocked_time_operations_v120 operation
   where operation.business_id=p_business and operation.actor=v_actor
     and operation.operation_type='create'
     and operation.idempotency_key=p_idempotency_key;
  if found then
    if v_existing.request_hash<>v_request_hash then
      raise exception 'idempotency key reused with different blocked time'
        using errcode='22023';
    end if;
    return v_existing.response||jsonb_build_object('replayed',true);
  end if;

  -- Every appointment mutation added below and every block creation takes this
  -- same lock. Different keys therefore cannot race an overlap check.
  perform app.lock_staff_calendar_v120(p_business,p_branch,p_staff);

  if exists (
    select 1 from public.staff_blocked_times blocked
     where blocked.business_id=p_business and blocked.staff_id=p_staff
       and blocked.starts_at < p_ends and blocked.ends_at > p_starts
  ) then
    raise exception 'this time is already blocked' using errcode='23P01';
  end if;

  if exists (
    select 1
      from public.appointments appointment
      left join public.services service
        on service.id=appointment.service_id
       and service.business_id=appointment.business_id
     where appointment.business_id=p_business
       and appointment.staff_id=p_staff and appointment.status='booked'
       and appointment.starts_at
           - make_interval(mins=>coalesce(service.buffer_before_min,0)) < p_ends
       and appointment.ends_at
           + make_interval(mins=>coalesce(service.buffer_after_min,0)) > p_starts
  ) then
    raise exception 'an appointment or its buffer already uses this time'
      using errcode='23P01';
  end if;

  insert into public.staff_blocked_times (
    business_id,branch_id,staff_id,starts_at,ends_at,reason,created_by
  ) values (
    p_business,p_branch,p_staff,p_starts,p_ends,v_reason,v_actor
  ) returning id into v_id;

  v_response:=jsonb_build_object(
    'status','created','replayed',false,'block_id',v_id
  );
  insert into app.staff_blocked_time_operations_v120 (
    business_id,actor,operation_type,idempotency_key,request_hash,response
  ) values (
    p_business,v_actor,'create',p_idempotency_key,v_request_hash,v_response
  );

  insert into public.audit_log (business_id,actor,action,entity,entity_id,detail)
  values (
    p_business,v_actor,'STAFF_TIME_BLOCK','staff_blocked_times',v_id,
    jsonb_build_object(
      'branch_id',p_branch,'staff_id',p_staff,
      'starts_at',p_starts,'ends_at',p_ends
    )
  );
  return v_response;
end
$$;

create or replace function public.delete_staff_blocked_time_v120(
  p_business uuid,p_block uuid,p_idempotency_key text
)
returns jsonb
language plpgsql security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare
  v_actor uuid:=auth.uid();
  v_request_hash text;
  v_existing app.staff_blocked_time_operations_v120%rowtype;
  v_block public.staff_blocked_times%rowtype;
  v_response jsonb;
begin
  if v_actor is null or p_business is null or p_block is null
     or p_idempotency_key is null
     or char_length(p_idempotency_key) not between 1 and 160 then
    raise exception 'permission denied or invalid blocked time'
      using errcode='42501';
  end if;

  v_request_hash:=app.v41_request_hash(jsonb_build_object(
    'business_id',p_business,'block_id',p_block
  )::text);

  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(
    'v120:delete:'||p_business::text||':'||v_actor::text||':'||p_idempotency_key,
    120
  ));

  select * into v_existing
    from app.staff_blocked_time_operations_v120 operation
   where operation.business_id=p_business and operation.actor=v_actor
     and operation.operation_type='delete'
     and operation.idempotency_key=p_idempotency_key;
  if found then
    if v_existing.request_hash<>v_request_hash then
      raise exception 'idempotency key reused with different blocked time'
        using errcode='22023';
    end if;
    if not app.can_module_write_at_v94(
      p_business,(v_existing.response->>'branch_id')::uuid,'appointments'
    ) then
      raise exception 'permission denied' using errcode='42501';
    end if;
    return (v_existing.response-'branch_id')||jsonb_build_object('replayed',true);
  end if;

  -- Different delete keys for the same block must not both observe and log the
  -- row before either deletion commits.
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(
    'v120:block-delete:'||p_business::text||':'||p_block::text,
    120
  ));
  select * into v_block
    from public.staff_blocked_times blocked
   where blocked.business_id=p_business and blocked.id=p_block;
  if not found
     or not app.can_module_write_at_v94(
       p_business,v_block.branch_id,'appointments'
     ) then
    raise exception 'permission denied' using errcode='42501';
  end if;

  perform app.lock_staff_calendar_v120(
    p_business,v_block.branch_id,v_block.staff_id
  );
  delete from public.staff_blocked_times
   where business_id=p_business and id=p_block;

  -- branch_id is retained only in the API-invisible receipt so replay can
  -- re-check current branch-effective permission after the source row is gone.
  v_response:=jsonb_build_object(
    'status','deleted','replayed',false,'block_id',p_block,
    'branch_id',v_block.branch_id
  );
  insert into app.staff_blocked_time_operations_v120 (
    business_id,actor,operation_type,idempotency_key,request_hash,response
  ) values (
    p_business,v_actor,'delete',p_idempotency_key,v_request_hash,v_response
  );

  insert into public.audit_log (business_id,actor,action,entity,entity_id,detail)
  values (
    p_business,v_actor,'STAFF_TIME_UNBLOCK','staff_blocked_times',p_block,
    jsonb_build_object(
      'branch_id',v_block.branch_id,'staff_id',v_block.staff_id,
      'starts_at',v_block.starts_at,'ends_at',v_block.ends_at,
      'reason',v_block.reason
    )
  );
  return v_response-'branch_id';
end
$$;

revoke all privileges on function public.list_staff_blocked_times_v120(
  uuid,uuid,timestamptz,timestamptz) from public,anon,authenticated;
revoke all privileges on function public.create_staff_blocked_time_v120(
  uuid,uuid,uuid,timestamptz,timestamptz,text,text
) from public,anon,authenticated;
revoke all privileges on function public.delete_staff_blocked_time_v120(
  uuid,uuid,text
) from public,anon,authenticated;
grant execute on function public.list_staff_blocked_times_v120(
  uuid,uuid,timestamptz,timestamptz) to authenticated;
grant execute on function public.create_staff_blocked_time_v120(
  uuid,uuid,uuid,timestamptz,timestamptz,text,text
) to authenticated;
grant execute on function public.delete_staff_blocked_time_v120(
  uuid,uuid,text
) to authenticated;

-- Keep the established availability function authoritative for every booking
-- consumer. The wrapper adds the requested service's buffers to the blocked
-- interval check, then delegates every pre-v120 schedule rule to the old body.
alter function app.staff_free_for_appointment_v47(
  uuid,uuid,uuid,uuid,timestamptz,timestamptz,uuid
) rename to staff_free_for_appointment_v120_base;

create or replace function app.staff_free_for_appointment_v47(
  p_business uuid,p_staff uuid,p_branch uuid,p_service uuid,
  p_starts timestamptz,p_ends timestamptz,
  p_exclude_appointment uuid default null
)
returns boolean
language plpgsql stable security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare
  v_buffer_before integer:=0;
  v_buffer_after integer:=0;
  v_timezone text;
  v_block_start timestamptz;
  v_block_end timestamptz;
  v_local_start timestamp;
  v_local_end timestamp;
  v_weekday smallint;
begin
  if not app.staff_free_for_appointment_v120_base(
    p_business,p_staff,p_branch,p_service,p_starts,p_ends,p_exclude_appointment
  ) then
    return false;
  end if;

  if p_service is not null then
    select service.buffer_before_min,service.buffer_after_min
      into v_buffer_before,v_buffer_after
      from public.services service
     where service.business_id=p_business and service.id=p_service
       and service.active;
    if not found then return false; end if;
  end if;

  select branch.timezone into v_timezone
    from public.branches branch
   where branch.business_id=p_business and branch.id=p_branch and branch.active;
  if not found then return false; end if;
  v_block_start:=p_starts-make_interval(mins=>coalesce(v_buffer_before,0));
  v_block_end:=p_ends+make_interval(mins=>coalesce(v_buffer_after,0));
  v_local_start:=v_block_start at time zone v_timezone;
  v_local_end:=v_block_end at time zone v_timezone;
  v_weekday:=extract(dow from v_local_start)::smallint;

  -- V118/V119 expose recorded hours as truth. Missing hours are closed, not
  -- legacy-available, and the complete service-plus-buffer interval must fit.
  if v_local_end::date<>v_local_start::date
     or not exists (
       select 1 from public.branch_hours hours
        where hours.business_id=p_business and hours.branch_id=p_branch
          and hours.weekday=v_weekday
          and v_local_start::time>=hours.opens_at
          and v_local_end::time<=hours.closes_at
     )
     or not exists (
       select 1 from public.staff_hours hours
        where hours.business_id=p_business and hours.staff_id=p_staff
          and hours.weekday=v_weekday
          and v_local_start::time>=hours.starts_at
          and v_local_end::time<=hours.ends_at
     ) then
    return false;
  end if;

  return not exists (
    select 1 from public.staff_blocked_times blocked
     where blocked.business_id=p_business and blocked.staff_id=p_staff
       and blocked.starts_at < v_block_end
       and blocked.ends_at > v_block_start
  );
end
$$;

revoke all privileges on function app.staff_free_for_appointment_v47(
  uuid,uuid,uuid,uuid,timestamptz,timestamptz,uuid
) from public,anon,authenticated;

-- Serialize direct appointment writes with block creation and reject any
-- bypass that overlaps a persisted block. The existing RPC checks remain the
-- friendly path; this trigger is the final race-safe boundary.
create or replace function app.guard_staff_blocked_time_v120()
returns trigger
language plpgsql security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
begin
  if new.status<>'booked' or new.staff_id is null then return new; end if;

  perform app.lock_staff_calendar_v120(
    new.business_id,new.branch_id,new.staff_id
  );
  if not app.staff_free_for_appointment_v47(
    new.business_id,new.staff_id,new.branch_id,new.service_id,
    new.starts_at,new.ends_at,new.id
  ) then
    raise exception 'staff is not available for this appointment'
      using errcode='23P01';
  end if;
  return new;
end
$$;

revoke all privileges on function app.guard_staff_blocked_time_v120()
  from public,anon,authenticated;

-- Alphabetically after trg_appointments_default_branch so legacy inserts with
-- a null branch first receive their authoritative default branch.
create trigger zz_appointments_guard_staff_blocked_time_v120
before insert or update of business_id,branch_id,staff_id,service_id,
  starts_at,ends_at,status
on public.appointments
for each row execute function app.guard_staff_blocked_time_v120();

commit;
