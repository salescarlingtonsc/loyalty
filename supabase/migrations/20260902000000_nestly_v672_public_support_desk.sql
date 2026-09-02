-- NESTLY v672 — the public support desk.
--
-- Owner directive 2026-09-02: anyone — a customer of one of our businesses, or a
-- business owner — can raise a support ticket from https://www.peekaa.asia/support
-- without an account, and the super admin reads the queue at /admin.
--
-- Three things are deliberate here:
--
--   1. The table is invisible to anon and authenticated. Every write arrives through
--      the Turnstile-gated public gateway calling the service-role RPC below, and
--      every read is the super-admin RPC. This is the v95 business-application shape,
--      for the same reason: a public intake table that anon could SELECT would be a
--      directory of who has complained about whom.
--
--   2. Submission is idempotency-keyed and request-hashed. A double-tapped Send is one
--      ticket, not two; a changed message under a replayed key is refused rather than
--      silently dropped, so the submitter is never told "received" about text we did
--      not store.
--
--   3. The audit table is append-only through app.forbid_mutation(). A support queue is
--      the record of what a person told us and what we did about it; a status that can
--      be rewritten with no trace is not a record.
--
-- No email is sent from here. The page tells the submitter to allow 7 business days and
-- to write to hello@peekaa.asia if nobody has replied — a promise the console has to keep
-- by being read, which is why the queue is the deliverable and not a notification.

begin;

-- ---------------------------------------------------------------------------
-- 1. The ticket, its audit trail.
-- ---------------------------------------------------------------------------

create table public.support_tickets_v672(
  id uuid primary key default gen_random_uuid(),
  public_reference uuid not null default gen_random_uuid() unique,
  idempotency_key uuid not null unique,
  request_hash text not null check(request_hash~'^[0-9a-f]{64}$'),
  requester_kind text not null check(requester_kind in ('customer','business_owner')),
  contact_name text not null check(length(btrim(contact_name)) between 2 and 120),
  contact_email text not null check(
    contact_email=lower(btrim(contact_email))
    and contact_email~'^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$'
  ),
  contact_phone text check(contact_phone is null or contact_phone~'^\+[1-9][0-9]{7,14}$'),
  business_name text check(
    business_name is null or length(btrim(business_name)) between 2 and 160
  ),
  what_happened text not null check(length(btrim(what_happened)) between 10 and 4000),
  preferred_locale text not null default 'en' check(preferred_locale in ('en','zh-CN','ms')),
  status text not null default 'open'
    check(status in ('open','in_progress','resolved','closed')),
  version bigint not null default 1 check(version>0),
  handled_by uuid references auth.users(id) on delete set null,
  handled_at timestamptz,
  resolution_note text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  -- An open ticket carries no handling fields; a handled one carries all three. Without
  -- this a ticket could read "resolved" with nobody's name against it.
  constraint support_tickets_v672_handling_shape check(
    (status='open' and handled_by is null and handled_at is null and resolution_note is null)
    or
    (status in ('in_progress','resolved','closed') and handled_by is not null
      and handled_at is not null
      and length(btrim(resolution_note)) between 3 and 2000)
  ),
  -- A business owner tells us which business. A customer need not know its legal name.
  constraint support_tickets_v672_owner_business check(
    requester_kind<>'business_owner' or business_name is not null
  )
);
create index support_tickets_v672_queue_idx
  on public.support_tickets_v672(status,created_at desc,id desc);
create index support_tickets_v672_email_idx
  on public.support_tickets_v672(contact_email,created_at desc);

create table public.support_ticket_audit_v672(
  id uuid primary key default gen_random_uuid(),
  ticket_id uuid not null references public.support_tickets_v672(id) on delete restrict,
  event_type text not null check(event_type in ('submitted','status_changed')),
  actor uuid references auth.users(id) on delete set null,
  prior_status text,
  new_status text not null,
  reason text not null check(length(btrim(reason)) between 3 and 2000),
  detail jsonb not null default '{}'::jsonb check(jsonb_typeof(detail)='object'),
  created_at timestamptz not null default now()
);
create index support_ticket_audit_v672_timeline_idx
  on public.support_ticket_audit_v672(ticket_id,created_at,id);

alter table public.support_tickets_v672 enable row level security;
alter table public.support_ticket_audit_v672 enable row level security;
revoke all privileges on table public.support_tickets_v672
  from public,anon,authenticated;
revoke all privileges on table public.support_ticket_audit_v672
  from public,anon,authenticated;

create trigger trg_support_ticket_audit_v672_append_only
before update or delete on public.support_ticket_audit_v672
for each row execute function app.forbid_mutation();

-- ---------------------------------------------------------------------------
-- 2. Anonymous submission — service role only, behind the public gateway.
-- ---------------------------------------------------------------------------

create or replace function public.internal_submit_support_ticket_v672(
  p_requester_kind text,p_contact_name text,p_contact_email text,
  p_contact_phone text,p_business_name text,p_what_happened text,
  p_locale text,p_idempotency_key uuid
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare
  v_email text:=lower(btrim(coalesce(p_contact_email,'')));
  v_phone text:=nullif(btrim(coalesce(p_contact_phone,'')),'');
  v_business text:=nullif(btrim(coalesce(p_business_name,'')),'');
  v_message text:=btrim(coalesce(p_what_happened,''));
  v_name text:=btrim(coalesce(p_contact_name,''));
  v_hash text;
  v_ticket public.support_tickets_v672%rowtype;
begin
  -- Re-validate everything the edge function validated. The gateway is a filter, not the
  -- authority: this function is the last place a bad row can be stopped.
  if p_idempotency_key is null
     or coalesce(p_requester_kind,'') not in ('customer','business_owner')
     or length(v_name) not between 2 and 120
     or v_email!~'^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$'
     or length(v_email)>254
     or (v_phone is not null and v_phone!~'^\+[1-9][0-9]{7,14}$')
     or (v_business is not null and length(v_business) not between 2 and 160)
     or length(v_message) not between 10 and 4000
     or coalesce(p_locale,'') not in ('en','zh-CN','ms')
  then raise exception 'valid support ticket fields are required' using errcode='22023';end if;
  if p_requester_kind='business_owner' and v_business is null then
    raise exception 'business_name_required' using errcode='22023';
  end if;

  v_hash:=app.v95_sha256(concat_ws('|',
    p_requester_kind,v_name,v_email,coalesce(v_phone,''),
    coalesce(v_business,''),v_message,p_locale
  ));

  select * into v_ticket from public.support_tickets_v672
  where idempotency_key=p_idempotency_key;
  if found then
    -- Same key, different words: refuse. Answering "received" here would confirm a
    -- message we never stored.
    if v_ticket.request_hash<>v_hash then
      raise exception 'support_idempotency_conflict' using errcode='22023';
    end if;
    return jsonb_build_object(
      'ticket_id',v_ticket.id,'public_reference',v_ticket.public_reference,
      'status',v_ticket.status,'replayed',true
    );
  end if;

  insert into public.support_tickets_v672(
    idempotency_key,request_hash,requester_kind,contact_name,contact_email,
    contact_phone,business_name,what_happened,preferred_locale
  ) values(
    p_idempotency_key,v_hash,p_requester_kind,v_name,v_email,
    v_phone,v_business,v_message,p_locale
  ) returning * into v_ticket;

  insert into public.support_ticket_audit_v672(
    ticket_id,event_type,new_status,reason,detail
  ) values(
    v_ticket.id,'submitted','open','public support ticket submitted',
    jsonb_build_object('requester_kind',p_requester_kind,'preferred_locale',p_locale)
  );

  return jsonb_build_object(
    'ticket_id',v_ticket.id,'public_reference',v_ticket.public_reference,
    'status','open','replayed',false
  );
end
$$;

-- ---------------------------------------------------------------------------
-- 3. The super-admin queue.
-- ---------------------------------------------------------------------------

create or replace function public.platform_list_support_tickets_v672(
  p_status text default null,p_search text default null,p_limit integer default 100
)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare
  v_rows jsonb;
  v_search text:=lower(btrim(coalesce(p_search,'')));
  v_matched integer;
begin
  if not app.is_super_admin() then
    raise exception 'super_admin_required' using errcode='42501';
  end if;
  if (p_status is not null and p_status not in ('open','in_progress','resolved','closed'))
     or p_limit not between 1 and 250
  then raise exception 'valid support queue filters are required' using errcode='22023';end if;

  with matched as (
    select ticket.*,
      row_number() over(order by ticket.created_at desc,ticket.id desc) ordinal
    from public.support_tickets_v672 ticket
    where (p_status is null or ticket.status=p_status)
      and (v_search='' or lower(concat_ws(' ',
        ticket.contact_name,ticket.contact_email,ticket.contact_phone,
        ticket.business_name,ticket.what_happened,ticket.public_reference::text
      )) like '%'||v_search||'%')
    order by ticket.created_at desc,ticket.id desc
    limit p_limit+1
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'id',id,'public_reference',public_reference,
    'requester_kind',requester_kind,'contact_name',contact_name,
    'contact_email',contact_email,'contact_phone',contact_phone,
    'business_name',business_name,'what_happened',what_happened,
    'preferred_locale',preferred_locale,'status',status,'version',version,
    'submitted_at',created_at,'handled_at',handled_at,
    'resolution_note',resolution_note
  ) order by created_at desc,id desc) filter(where ordinal<=p_limit),'[]'::jsonb),
    count(*)
  into v_rows,v_matched
  from matched;

  -- matched is read with limit p_limit+1, so a count above the limit is the proof that
  -- another page exists — and it carries the same filters the page itself was built with.
  return jsonb_build_object(
    'tickets',v_rows,
    'returned',least(coalesce(v_matched,0),p_limit),
    'limit',p_limit,
    'has_more',coalesce(v_matched,0)>p_limit,
    'open_count',(select count(*) from public.support_tickets_v672 where status='open'),
    'generated_at',now()
  );
end
$$;

create or replace function public.platform_update_support_ticket_v672(
  p_ticket uuid,p_status text,p_note text,p_expected_version bigint
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare
  v_ticket public.support_tickets_v672%rowtype;
  v_note text:=btrim(coalesce(p_note,''));
  v_actor uuid:=auth.uid();
  v_prior_status text;
begin
  if not app.is_super_admin() then
    raise exception 'super_admin_required' using errcode='42501';
  end if;
  if p_ticket is null
     or coalesce(p_status,'') not in ('in_progress','resolved','closed')
     or length(v_note) not between 3 and 2000
     or p_expected_version is null
  then raise exception 'valid support ticket update is required' using errcode='22023';end if;
  if v_actor is null then
    raise exception 'super_admin_required' using errcode='42501';
  end if;

  select * into v_ticket from public.support_tickets_v672
  where id=p_ticket for update;
  if not found then raise exception 'support_ticket_not_found' using errcode='22023';end if;
  -- Optimistic concurrency: two admins working the same queue must not silently
  -- overwrite each other's note.
  if v_ticket.version<>p_expected_version then
    raise exception 'support_ticket_version_conflict' using errcode='40001';
  end if;
  -- Capture the prior status before the update, not after: reading it back from the row
  -- afterwards would record the new status as its own predecessor.
  v_prior_status:=v_ticket.status;

  update public.support_tickets_v672
  set status=p_status,handled_by=v_actor,handled_at=now(),
      resolution_note=v_note,version=version+1,updated_at=now()
  where id=p_ticket
  returning * into v_ticket;

  insert into public.support_ticket_audit_v672(
    ticket_id,event_type,actor,prior_status,new_status,reason,detail
  ) values(
    v_ticket.id,'status_changed',v_actor,v_prior_status,
    v_ticket.status,v_note,
    jsonb_build_object('version',v_ticket.version)
  );

  return jsonb_build_object(
    'ticket_id',v_ticket.id,'status',v_ticket.status,'version',v_ticket.version
  );
end
$$;

-- ---------------------------------------------------------------------------
-- 4. Finite ACL. The submit path is service-role only; the console reads as the
--    signed-in super admin, so its two functions are granted to authenticated and
--    gate themselves on app.is_super_admin().
-- ---------------------------------------------------------------------------

revoke all on function public.internal_submit_support_ticket_v672(
  text,text,text,text,text,text,text,uuid
) from public,anon,authenticated;
grant execute on function public.internal_submit_support_ticket_v672(
  text,text,text,text,text,text,text,uuid
) to service_role;

revoke all on function public.platform_list_support_tickets_v672(text,text,integer)
  from public,anon,authenticated;
grant execute on function public.platform_list_support_tickets_v672(text,text,integer)
  to authenticated;

revoke all on function public.platform_update_support_ticket_v672(uuid,text,text,bigint)
  from public,anon,authenticated;
grant execute on function public.platform_update_support_ticket_v672(uuid,text,text,bigint)
  to authenticated;

commit;
