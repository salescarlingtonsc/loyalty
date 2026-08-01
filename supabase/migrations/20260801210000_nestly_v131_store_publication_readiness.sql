-- Nestly V131: store-safe account deletion request boundary.
-- Requests are append-only operational records. This migration never deletes
-- identity, financial, tenant, customer, or audit data.

begin;

create table public.account_deletion_requests(
  id uuid primary key default gen_random_uuid(),
  subject_auth_user_id uuid references auth.users(id) on delete set null,
  subject_ref uuid not null,
  status text not null default 'pending'
    check(status in ('pending','processing','completed','rejected','cancelled')),
  idempotency_key text not null check(length(idempotency_key) between 8 and 200),
  request_fingerprint text not null default 'DELETE:v131',
  requested_at timestamptz not null default now(),
  response_due_at timestamptz not null default (now()+interval '30 days'),
  updated_at timestamptz not null default now(),
  completed_at timestamptz,
  operator_note text,
  constraint account_deletion_requests_due_check
    check(response_due_at=requested_at+interval '30 days'),
  constraint account_deletion_requests_completion_check check(
    (status='completed' and completed_at is not null)
    or (status<>'completed' and completed_at is null)
  ),
  unique(subject_ref,idempotency_key)
);

create unique index account_deletion_requests_one_open_subject_idx
  on public.account_deletion_requests(subject_ref)
  where status in ('pending','processing');
create index account_deletion_requests_queue_idx
  on public.account_deletion_requests(status,requested_at,id);

alter table public.account_deletion_requests enable row level security;
alter table public.account_deletion_requests force row level security;
revoke all on table public.account_deletion_requests from public, anon, authenticated;

create or replace function public.request_account_deletion_v131(
  p_confirmation text,
  p_idempotency_key text
) returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare
  v_user uuid:=auth.uid();
  v_key text:=btrim(coalesce(p_idempotency_key,''));
  v_row public.account_deletion_requests%rowtype;
begin
  if v_user is null then
    raise exception 'authentication required' using errcode='42501';
  end if;
  if coalesce(p_confirmation,'')<>'DELETE' then
    raise exception 'type DELETE to confirm' using errcode='22023';
  end if;
  if length(v_key) not between 8 and 200 then
    raise exception 'invalid idempotency key' using errcode='22023';
  end if;

  perform pg_advisory_xact_lock(hashtextextended(v_user::text,131));

  select * into v_row
    from public.account_deletion_requests
   where subject_ref=v_user and idempotency_key=v_key
   order by requested_at desc limit 1;

  if v_row.id is null then
    select * into v_row
      from public.account_deletion_requests
     where subject_ref=v_user and status in ('pending','processing')
     order by requested_at desc limit 1;
  end if;

  if v_row.id is null then
    insert into public.account_deletion_requests(
      subject_auth_user_id,subject_ref,idempotency_key,
      requested_at,response_due_at,updated_at
    ) values(v_user,v_user,v_key,now(),now()+interval '30 days',now())
    returning * into v_row;
  end if;

  return jsonb_build_object(
    'request_id',v_row.id,'status',v_row.status,
    'requested_at',v_row.requested_at,'response_due_at',v_row.response_due_at
  );
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
    'requested_at',v_row.requested_at,'response_due_at',v_row.response_due_at
  );
end
$$;

create or replace function public.platform_list_account_deletion_requests_v131(
  p_status text default 'pending',
  p_limit integer default 50
) returns table(
  request_id uuid,subject_ref uuid,status text,requested_at timestamptz,
  response_due_at timestamptz,updated_at timestamptz
)
language plpgsql
stable
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
begin
  if not app.is_super_admin() then
    raise exception 'super-admin only' using errcode='42501';
  end if;
  if p_status is not null and p_status not in ('pending','processing','completed','rejected','cancelled') then
    raise exception 'invalid status' using errcode='22023';
  end if;
  return query
    select request_row.id,request_row.subject_ref,request_row.status,request_row.requested_at,request_row.response_due_at,request_row.updated_at
      from public.account_deletion_requests request_row
     where p_status is null or request_row.status=p_status
     order by request_row.requested_at,request_row.id
     limit least(greatest(coalesce(p_limit,50),1),100);
end
$$;

revoke all on function public.request_account_deletion_v131(text,text) from public,anon,authenticated;
revoke all on function public.get_account_deletion_request_v131() from public,anon,authenticated;
revoke all on function public.platform_list_account_deletion_requests_v131(text,integer) from public,anon,authenticated;
grant execute on function public.request_account_deletion_v131(text,text) to authenticated;
grant execute on function public.get_account_deletion_request_v131() to authenticated;
grant execute on function public.platform_list_account_deletion_requests_v131(text,integer) to authenticated;

comment on table public.account_deletion_requests is
  'V131 append-only queue for authenticated account-deletion requests; no browser table access and no immediate destructive cascade.';
comment on function public.request_account_deletion_v131(text,text) is
  'V131 authenticated, idempotent deletion-request intake. Returns the same open request after retry or lost response.';
comment on function public.get_account_deletion_request_v131() is
  'V131 subject-only projection of the caller current deletion request.';
comment on function public.platform_list_account_deletion_requests_v131(text,integer) is
  'V131 bounded super-admin operations queue without email, phone, or business data.';

commit;
