-- NESTLY v511 — Peekaa Operating System P2: the Work operating system and a
-- minimal Business 360.
--
-- One canonical WorkItem answers the seven questions for every operational
-- action: what it is, what state it is in, who owns it, what happens next,
-- when it is due, why it is blocked, and what happened before. The existing
-- task concepts are NOT deleted and NOT duplicated: each remains its own
-- system of record and projects into work_items through an idempotent origin
-- key, so a single queue can answer "what requires action today?" without a
-- second task system competing with it.
--
-- A SupportTicket (P6) is the CASE. A WorkItem is the ACTION. work_items
-- therefore carries a nullable case reference and never becomes a ticket.

begin;

-- ------------------------------------------------------------------ work

create table public.work_items_v511 (
  id uuid primary key default gen_random_uuid(),
  -- Idempotency for event-generated work: one origin produces one work item,
  -- no matter how many times the generating event is replayed.
  origin_kind text not null check(origin_kind in
    ('native','sme_prospect_task','subscription_task','onboarding_item','payment_exception','system_sweep')),
  origin_key text not null,
  work_type text not null check(work_type in
    ('lead_follow_up','commercial_review','payment_exception','manual_payment_review',
     'onboarding_step','onboarding_blocked','activation_review','renewal_prep',
     'support_action','data_correction','integration_incident','anomaly_review')),
  title text not null check(length(btrim(title)) between 1 and 200),
  detail text,
  -- Subject: what this action is about. At least one anchor is required so no
  -- work item can float free of the thing it concerns.
  business_id uuid references public.businesses(id) on delete cascade,
  prospect_id uuid references public.sme_prospects(id) on delete cascade,
  company_id uuid references public.sme_companies(id) on delete cascade,
  -- A WorkItem may belong to a case (P6 SupportTicket) but is never the case.
  case_ref text,
  state text not null default 'open' check(state in
    ('open','in_progress','waiting','blocked','done','cancelled')),
  -- Ownership is the v510 contract: owned XOR queued, never both, never neither.
  ownership_state text not null default 'queued' check(ownership_state in ('owned','queued')),
  owner_consultant_id uuid references public.platform_consultants(id) on delete restrict,
  queue_key text,
  priority integer not null default 0 check(priority between 0 and 3),
  due_at timestamptz,
  sla interval check(sla is null or sla>interval '0'),
  -- waiting_until powers automatic reopen: a snoozed or waiting item returns to
  -- the queue by itself instead of relying on somebody remembering it.
  waiting_until timestamptz,
  waiting_reason text,
  blocker_reason text,
  closed_at timestamptz,
  closed_by uuid references auth.users(id) on delete restrict,
  close_outcome text check(close_outcome is null or close_outcome in
    ('completed','not_needed','superseded','rejected')),
  version bigint not null default 1,
  created_by uuid references auth.users(id) on delete restrict,
  created_at timestamptz not null default clock_timestamp(),
  updated_at timestamptz not null default clock_timestamp(),
  unique(origin_kind,origin_key),
  check(business_id is not null or prospect_id is not null or company_id is not null),
  check((state in ('done','cancelled')) = (closed_at is not null)),
  check((state in ('done','cancelled')) = (close_outcome is not null)),
  check(state<>'blocked' or nullif(btrim(blocker_reason),'') is not null),
  check(state<>'waiting' or waiting_until is not null)
);
create index work_items_v511_queue_idx on public.work_items_v511
  (ownership_state,queue_key,due_at,id) where closed_at is null;
create index work_items_v511_owner_idx on public.work_items_v511
  (owner_consultant_id,due_at,id) where closed_at is null;
create index work_items_v511_business_idx on public.work_items_v511
  (business_id,created_at desc) where business_id is not null;
create index work_items_v511_prospect_idx on public.work_items_v511
  (prospect_id,created_at desc) where prospect_id is not null;
create index work_items_v511_waiting_idx on public.work_items_v511
  (waiting_until) where state='waiting';

-- Append-only history: question seven ("what happened previously") is answered
-- from this table alone, never reconstructed from mutable columns.
create table public.work_item_events_v511 (
  id uuid primary key default gen_random_uuid(),
  work_item_id uuid not null references public.work_items_v511(id) on delete cascade,
  event_type text not null check(event_type in
    ('created','claimed','queued','transferred','state_changed','due_changed',
     'blocked','unblocked','waiting_set','reopened','closed','note')),
  from_state text,
  to_state text,
  from_owner uuid references public.platform_consultants(id) on delete set null,
  to_owner uuid references public.platform_consultants(id) on delete set null,
  detail jsonb not null default '{}'::jsonb check(jsonb_typeof(detail)='object'),
  actor uuid references auth.users(id) on delete restrict,
  created_at timestamptz not null default clock_timestamp()
);
create index work_item_events_v511_item_idx on public.work_item_events_v511
  (work_item_id,created_at desc);

alter table public.work_items_v511 enable row level security;
alter table public.work_item_events_v511 enable row level security;
revoke all privileges on table public.work_items_v511 from public,anon,authenticated;
revoke all privileges on table public.work_item_events_v511 from public,anon,authenticated;

-- ---------------------------------------------------------------- invariants

-- The seven-question contract, enforced in the table rather than in any RPC, so
-- that no writer — canonical, legacy, adapter or human — can produce a work item
-- that nobody owns, that has no next moment, or that is blocked without saying why.
create or replace function app.v511_work_item_guard()
returns trigger language plpgsql
set search_path to 'pg_catalog','public','app','pg_temp' as $$
declare v_legal boolean;
begin
  if new.closed_at is null then
    if not (
      (new.ownership_state='owned' and new.owner_consultant_id is not null and new.queue_key is null)
      or (new.ownership_state='queued' and new.owner_consultant_id is null and new.queue_key is not null)
    ) then
      raise exception 'an open work item requires one owner or one explicit queue'
        using errcode='23514';
    end if;
    if new.due_at is null then
      raise exception 'an open work item requires a due date' using errcode='23514';
    end if;
  end if;

  if tg_op='UPDATE' and new.state is distinct from old.state then
    v_legal:=case old.state
      when 'open'        then new.state in ('in_progress','waiting','blocked','done','cancelled')
      when 'in_progress' then new.state in ('open','waiting','blocked','done','cancelled')
      when 'waiting'     then new.state in ('open','in_progress','blocked','done','cancelled')
      when 'blocked'     then new.state in ('open','in_progress','waiting','done','cancelled')
      -- A closed item may only come back as open, and only deliberately.
      when 'done'        then new.state='open'
      when 'cancelled'   then new.state='open'
      else false end;
    if not v_legal then
      raise exception 'work item cannot move from % to %',old.state,new.state using errcode='23514';
    end if;
    if old.state in ('done','cancelled') and new.state='open' then
      new.closed_at:=null;new.closed_by:=null;new.close_outcome:=null;
    end if;
  end if;

  -- Clearing the reason that justified a state must clear the state with it.
  if new.state<>'blocked' then new.blocker_reason:=null;end if;
  if new.state<>'waiting' then new.waiting_until:=null;new.waiting_reason:=null;end if;

  if tg_op='UPDATE' then new.updated_at:=clock_timestamp();end if;
  return new;
end $$;
drop trigger if exists aa_work_items_v511_guard on public.work_items_v511;
create trigger aa_work_items_v511_guard before insert or update on public.work_items_v511
  for each row execute function app.v511_work_item_guard();

-- History is written by the database, not by whoever remembered to log it.
create or replace function app.v511_work_item_history()
returns trigger language plpgsql security definer
set search_path to 'pg_catalog','public','app','pg_temp' as $$
begin
  if tg_op='INSERT' then
    insert into public.work_item_events_v511(work_item_id,event_type,to_state,to_owner,detail,actor)
    values(new.id,'created',new.state,new.owner_consultant_id,
      jsonb_build_object('origin_kind',new.origin_kind,'work_type',new.work_type,'due_at',new.due_at),
      new.created_by);
    return new;
  end if;
  if new.state is distinct from old.state then
    insert into public.work_item_events_v511(work_item_id,event_type,from_state,to_state,detail,actor)
    values(new.id,
      case when old.state in ('done','cancelled') and new.state='open' then 'reopened'
           when new.state='blocked' then 'blocked'
           when old.state='blocked' then 'unblocked'
           when new.state='waiting' then 'waiting_set'
           when new.state in ('done','cancelled') then 'closed'
           else 'state_changed' end,
      old.state,new.state,
      jsonb_build_object('blocker_reason',new.blocker_reason,'waiting_until',new.waiting_until,
        'close_outcome',new.close_outcome),
      coalesce(new.closed_by,auth.uid()));
  end if;
  if new.owner_consultant_id is distinct from old.owner_consultant_id
     or new.ownership_state is distinct from old.ownership_state then
    insert into public.work_item_events_v511(
      work_item_id,event_type,from_owner,to_owner,detail,actor)
    values(new.id,
      case when new.ownership_state='queued' then 'queued'
           when old.owner_consultant_id is null then 'claimed' else 'transferred' end,
      old.owner_consultant_id,new.owner_consultant_id,
      jsonb_build_object('queue_key',new.queue_key),auth.uid());
  end if;
  if new.due_at is distinct from old.due_at then
    insert into public.work_item_events_v511(work_item_id,event_type,detail,actor)
    values(new.id,'due_changed',
      jsonb_build_object('from',old.due_at,'to',new.due_at),auth.uid());
  end if;
  return new;
end $$;
drop trigger if exists work_items_v511_history on public.work_items_v511;
create trigger work_items_v511_history after insert or update on public.work_items_v511
  for each row execute function app.v511_work_item_history();

-- Append-only: history is evidence, so it may never be edited or deleted.
create or replace function app.v511_work_events_append_only()
returns trigger language plpgsql
set search_path to 'pg_catalog','pg_temp' as $$
begin
  raise exception 'work item history is append-only' using errcode='42501';
end $$;
drop trigger if exists work_item_events_v511_immutable on public.work_item_events_v511;
create trigger work_item_events_v511_immutable before update or delete
  on public.work_item_events_v511 for each row
  execute function app.v511_work_events_append_only();

-- ------------------------------------------------------------------ core

-- One creation core. Every producer — RPC, adapter trigger, sweep — goes
-- through it, so "the same event twice" can only ever mean "the same work item".
-- A closed item is never silently resurrected: replaying an old event returns
-- the historical id and changes nothing.
create or replace function app.v511_ensure_work_item(
  p_origin_kind text,p_origin_key text,p_work_type text,p_title text,p_detail text,
  p_business uuid,p_prospect uuid,p_company uuid,
  p_due_at timestamptz,p_sla interval,p_priority integer,
  p_owner uuid,p_queue text,p_actor uuid
) returns uuid language plpgsql security definer
set search_path to 'pg_catalog','public','app','pg_temp' as $$
declare v_id uuid;v_closed timestamptz;v_owner uuid:=p_owner;v_queue text:=p_queue;
begin
  if v_owner is not null then v_queue:=null; else v_queue:=coalesce(v_queue,'operations_intake'); end if;
  -- Serialize on the origin so two concurrent producers cannot both insert.
  perform pg_advisory_xact_lock(hashtextextended('v511:origin:'||p_origin_kind||':'||p_origin_key,0));
  select id,closed_at into v_id,v_closed from public.work_items_v511
   where origin_kind=p_origin_kind and origin_key=p_origin_key;
  if found then
    if v_closed is null then
      update public.work_items_v511 set
        title=coalesce(nullif(btrim(p_title),''),title),
        detail=coalesce(p_detail,detail),
        due_at=coalesce(p_due_at,due_at),
        priority=coalesce(p_priority,priority),
        version=version+1
      where id=v_id;
    end if;
    return v_id;
  end if;
  insert into public.work_items_v511(
    origin_kind,origin_key,work_type,title,detail,business_id,prospect_id,company_id,
    ownership_state,owner_consultant_id,queue_key,priority,due_at,sla,created_by)
  values(p_origin_kind,p_origin_key,p_work_type,btrim(p_title),p_detail,
    p_business,p_prospect,p_company,
    case when v_owner is not null then 'owned' else 'queued' end,v_owner,v_queue,
    coalesce(p_priority,0),coalesce(p_due_at,clock_timestamp()),p_sla,p_actor)
  returning id into v_id;
  return v_id;
end $$;
revoke all on function app.v511_ensure_work_item(
  text,text,text,text,text,uuid,uuid,uuid,timestamptz,interval,integer,uuid,text,uuid)
  from public,anon,authenticated;

-- Read authority. sales_staff sees its own work and anything unclaimed; admin
-- and super admin see the whole operation. Refusing an unknown platform user is
-- deliberate: work items expose the commercial pipeline.
create or replace function app.v511_assert_work_reader()
returns text language plpgsql stable security definer
set search_path to 'pg_catalog','public','app','pg_temp' as $$
declare v_role text:=app.v89_platform_role();
begin
  if v_role is null then
    raise exception 'work requires an active platform grant' using errcode='42501';
  end if;
  return v_role;
end $$;
revoke all on function app.v511_assert_work_reader() from public,anon,authenticated;

-- ------------------------------------------------------------------- rpcs

create or replace function public.platform_create_work_item_v511(
  p_work_type text,p_title text,p_detail text,
  p_business uuid,p_prospect uuid,p_due_at timestamptz,
  p_owner uuid,p_queue text,p_priority integer,p_idempotency_key uuid
) returns jsonb language plpgsql security definer
set search_path to 'pg_catalog','public','app','pg_temp' as $$
declare v_actor uuid:=auth.uid();v_role text:=app.v511_assert_work_reader();
  v_hash text;v_replay jsonb;v_id uuid;v_company uuid;v_response jsonb;
begin
  if p_idempotency_key is null then
    raise exception 'an operation key is required' using errcode='22023';end if;
  v_hash:=app.v76_sha256_hex(jsonb_build_object('work_type',p_work_type,'title',p_title,
    'business',p_business,'prospect',p_prospect,'due_at',p_due_at,
    'owner',p_owner,'queue',p_queue)::text);
  perform pg_advisory_xact_lock(hashtextextended('v511:operation:'||v_actor||':create:'||p_idempotency_key,0));
  v_replay:=app.v76_replay(v_actor,'create_work_item_v511',p_idempotency_key::text,v_hash);
  if v_replay is not null then return v_replay;end if;
  if p_business is null and p_prospect is null then
    raise exception 'a work item must name a business or a lead' using errcode='23514';end if;
  if p_prospect is not null then
    select company_id into v_company from public.sme_prospects where id=p_prospect;end if;
  v_id:=app.v511_ensure_work_item('native',
    coalesce(p_idempotency_key::text,gen_random_uuid()::text),
    p_work_type,p_title,p_detail,p_business,p_prospect,v_company,
    coalesce(p_due_at,clock_timestamp()),null,p_priority,p_owner,p_queue,v_actor);
  v_response:=jsonb_build_object('replayed',false,'work_item_id',v_id);
  perform app.v76_store_receipt(v_actor,'create_work_item_v511',p_idempotency_key::text,v_hash,v_response);
  return v_response;
end $$;

-- Claim / transfer / queue keep the owner-XOR-queue contract and the optimistic
-- version, so two operators cannot both believe they own the same action.
create or replace function public.platform_assign_work_item_v511(
  p_work_item uuid,p_expected_version bigint,p_owner uuid,p_queue text,p_idempotency_key uuid
) returns jsonb language plpgsql security definer
set search_path to 'pg_catalog','public','app','pg_temp' as $$
declare v_actor uuid:=auth.uid();v_role text:=app.v511_assert_work_reader();
  v_self uuid;v_hash text;v_replay jsonb;v_row public.work_items_v511%rowtype;v_response jsonb;
begin
  if p_idempotency_key is null then
    raise exception 'an operation key is required' using errcode='22023';end if;
  v_hash:=app.v76_sha256_hex(jsonb_build_object('work_item',p_work_item,'owner',p_owner,
    'queue',p_queue,'version',p_expected_version)::text);
  perform pg_advisory_xact_lock(hashtextextended('v511:operation:'||v_actor||':assign:'||p_idempotency_key,0));
  v_replay:=app.v76_replay(v_actor,'assign_work_item_v511',p_idempotency_key::text,v_hash);
  if v_replay is not null then return v_replay;end if;
  select * into v_row from public.work_items_v511 where id=p_work_item for update;
  if not found then raise exception 'work item not found' using errcode='P0002';end if;
  if v_row.version<>p_expected_version then
    raise exception 'work item version conflict' using errcode='40001';end if;
  if v_row.closed_at is not null then
    raise exception 'a closed work item cannot be reassigned' using errcode='23514';end if;
  if v_role='sales_staff' then
    v_self:=app.v226_self_consultant();
    if p_owner is distinct from v_self then
      raise exception 'a salesperson may only claim work for themselves' using errcode='42501';end if;
    if v_row.ownership_state='owned' and v_row.owner_consultant_id is distinct from v_self then
      raise exception 'that work item already has an owner' using errcode='42501';end if;
  end if;
  update public.work_items_v511 set
    ownership_state=case when p_owner is not null then 'owned' else 'queued' end,
    owner_consultant_id=p_owner,
    queue_key=case when p_owner is not null then null else coalesce(p_queue,'operations_intake') end,
    version=version+1
  where id=p_work_item returning * into v_row;
  v_response:=jsonb_build_object('replayed',false,'work_item_id',p_work_item,
    'ownership_state',v_row.ownership_state,'owner',v_row.owner_consultant_id,
    'queue_key',v_row.queue_key,'version',v_row.version);
  perform app.v76_store_receipt(v_actor,'assign_work_item_v511',p_idempotency_key::text,v_hash,v_response);
  return v_response;
end $$;

-- One transition entry point. The legality of the move is enforced by the table
-- guard; this function owns authorization, concurrency and the evidence each
-- state demands (a blocker needs a reason, a wait needs a return date).
create or replace function public.platform_transition_work_item_v511(
  p_work_item uuid,p_expected_version bigint,p_to_state text,
  p_reason text,p_waiting_until timestamptz,p_due_at timestamptz,
  p_close_outcome text,p_idempotency_key uuid
) returns jsonb language plpgsql security definer
set search_path to 'pg_catalog','public','app','pg_temp' as $$
declare v_actor uuid:=auth.uid();v_role text:=app.v511_assert_work_reader();
  v_self uuid;v_hash text;v_replay jsonb;v_row public.work_items_v511%rowtype;v_response jsonb;
begin
  if p_idempotency_key is null then
    raise exception 'an operation key is required' using errcode='22023';end if;
  v_hash:=app.v76_sha256_hex(jsonb_build_object('work_item',p_work_item,'to',p_to_state,
    'version',p_expected_version,'reason',p_reason,'waiting_until',p_waiting_until,
    'due_at',p_due_at,'outcome',p_close_outcome)::text);
  perform pg_advisory_xact_lock(hashtextextended('v511:operation:'||v_actor||':transition:'||p_idempotency_key,0));
  v_replay:=app.v76_replay(v_actor,'transition_work_item_v511',p_idempotency_key::text,v_hash);
  if v_replay is not null then return v_replay;end if;
  select * into v_row from public.work_items_v511 where id=p_work_item for update;
  if not found then raise exception 'work item not found' using errcode='P0002';end if;
  if v_row.version<>p_expected_version then
    raise exception 'work item version conflict' using errcode='40001';end if;
  if v_role='sales_staff' then
    v_self:=app.v226_self_consultant();
    if v_row.owner_consultant_id is distinct from v_self then
      raise exception 'a salesperson may only act on their own work' using errcode='42501';end if;
  end if;
  if p_to_state='blocked' and nullif(btrim(p_reason),'') is null then
    raise exception 'a blocked work item must say why' using errcode='23514';end if;
  if p_to_state='waiting' and p_waiting_until is null then
    raise exception 'a waiting work item must say when it comes back' using errcode='23514';end if;
  if p_to_state in ('done','cancelled') and p_close_outcome is null then
    raise exception 'closing a work item requires an outcome' using errcode='23514';end if;
  -- A projected item belongs to its source. Closing it here would leave the
  -- source open and let two systems disagree about whether the job is done.
  if p_to_state in ('done','cancelled') and v_row.origin_kind<>'native' then
    raise exception 'close the % that generated this work item, not the work item',
      v_row.origin_kind using errcode='23514';end if;

  update public.work_items_v511 set
    state=p_to_state,
    blocker_reason=case when p_to_state='blocked' then btrim(p_reason) else null end,
    waiting_until=case when p_to_state='waiting' then p_waiting_until else null end,
    waiting_reason=case when p_to_state='waiting' then nullif(btrim(p_reason),'') else null end,
    due_at=case
      when p_to_state='waiting' then p_waiting_until
      when p_to_state in ('done','cancelled') then due_at
      else coalesce(p_due_at,due_at) end,
    closed_at=case when p_to_state in ('done','cancelled') then clock_timestamp() else null end,
    closed_by=case when p_to_state in ('done','cancelled') then v_actor else null end,
    close_outcome=case when p_to_state in ('done','cancelled') then p_close_outcome else null end,
    version=version+1
  where id=p_work_item returning * into v_row;

  v_response:=jsonb_build_object('replayed',false,'work_item_id',p_work_item,
    'state',v_row.state,'version',v_row.version,'due_at',v_row.due_at);
  perform app.v76_store_receipt(v_actor,'transition_work_item_v511',p_idempotency_key::text,v_hash,v_response);
  return v_response;
end $$;

-- Automatic reopen. A waiting item is not a forgotten item: once its return date
-- passes it comes back to the queue by itself, in bounded batches, and says so in
-- its own history. Cron only wakes this; the rule lives here.
create or replace function public.platform_reopen_due_work_v511(p_limit integer default 500)
returns jsonb language plpgsql security definer
set search_path to 'pg_catalog','public','app','pg_temp' as $$
declare v_ids uuid[];v_limit integer:=least(greatest(coalesce(p_limit,500),1),2000);
begin
  if app.v89_platform_role() is distinct from 'super_admin' and auth.uid() is not null then
    raise exception 'only the platform may sweep waiting work' using errcode='42501';end if;
  with due as (
    select id from public.work_items_v511
     where state='waiting' and waiting_until<=clock_timestamp() and closed_at is null
     order by waiting_until limit v_limit for update skip locked
  ), moved as (
    update public.work_items_v511 item set state='open',due_at=item.waiting_until,
      waiting_until=null,waiting_reason=null,version=item.version+1
    from due where item.id=due.id returning item.id
  ) select array_agg(id) into v_ids from moved;
  return jsonb_build_object('reopened',coalesce(array_length(v_ids,1),0),'as_of',clock_timestamp());
end $$;

-- ----------------------------------------------------------------- queues

-- One queue reader with four scopes, so "my work", "the team's work", "nobody's
-- work" and "late work" can never disagree about what an item is.
create or replace function public.platform_list_work_v511(
  p_scope text default 'mine',p_owner uuid default null,p_limit integer default 100
) returns jsonb language plpgsql stable security definer
set search_path to 'pg_catalog','public','app','pg_temp' as $$
declare v_role text:=app.v511_assert_work_reader();v_self uuid;
  v_limit integer:=least(greatest(coalesce(p_limit,100),1),250);v_owner uuid:=p_owner;
begin
  if p_scope not in ('mine','team','unassigned','overdue') then
    raise exception 'unknown work scope %',p_scope using errcode='22023';end if;
  v_self:=app.v226_self_consultant();
  if v_role='sales_staff' then
    if p_scope='team' then
      raise exception 'a salesperson reads their own work and the unclaimed queue'
        using errcode='42501';end if;
    v_owner:=v_self;
  else
    v_owner:=coalesce(p_owner,case when p_scope='mine' then v_self else null end);
  end if;
  return jsonb_build_object('as_of',clock_timestamp(),'scope',p_scope,'items',coalesce((
    select jsonb_agg(to_jsonb(row) order by row.due_at,row.priority desc,row.id)
    from (
      select item.id,item.origin_kind,item.work_type,item.title,item.state,item.priority,item.due_at,
        item.ownership_state,item.owner_consultant_id,consultant.display_name owner_name,
        item.queue_key,item.blocker_reason,item.waiting_until,item.version,
        item.business_id,item.prospect_id,
        coalesce(business.name,company.trading_name,company.legal_name) subject_name,
        case
          when item.state='blocked' then 'blocked'
          when item.due_at<clock_timestamp() then 'overdue'
          when item.ownership_state='queued' then 'unassigned'
          when consultant.id is null or not consultant.active then 'inactive_owner'
          else 'on_track' end attention
      from public.work_items_v511 item
      left join public.platform_consultants consultant on consultant.id=item.owner_consultant_id
      left join public.businesses business on business.id=item.business_id
      left join public.sme_companies company on company.id=item.company_id
      where item.closed_at is null
        and case p_scope
          when 'mine' then item.owner_consultant_id=v_owner
          when 'team' then (v_owner is null or item.owner_consultant_id=v_owner)
          when 'unassigned' then item.ownership_state='queued'
          when 'overdue' then item.due_at<clock_timestamp()
            and (v_role<>'sales_staff' or item.owner_consultant_id=v_self)
          else false end
      order by item.due_at,item.priority desc limit v_limit) row
  ),'[]'::jsonb));
end $$;

-- ------------------------------------------------------------ business 360

-- The canonical operator entry point. One round trip answers the ten questions
-- an unfamiliar operator asks about a merchant, so nobody needs SQL, a
-- spreadsheet, or the founder's memory to understand where a business stands.
create or replace function public.platform_get_business_360_v511(
  p_business uuid,p_timeline_limit integer default 20
) returns jsonb language plpgsql stable security definer
set search_path to 'pg_catalog','public','app','pg_temp' as $$
declare v_role text:=app.v511_assert_work_reader();
  v_limit integer:=least(greatest(coalesce(p_timeline_limit,20),1),100);
  v_business public.businesses%rowtype;v_prospect public.sme_prospects%rowtype;
  v_payment jsonb;v_entitled boolean;
begin
  select * into v_business from public.businesses where id=p_business;
  if not found then raise exception 'business not found' using errcode='P0002';end if;
  if v_business.source_prospect_id is not null then
    select * into v_prospect from public.sme_prospects where id=v_business.source_prospect_id;
  end if;
  v_payment:=app.v510_verified_initial_payment(p_business);
  v_entitled:=v_payment is not null;

  return jsonb_build_object(
    'as_of',clock_timestamp(),
    'identity',jsonb_build_object(
      'business_id',v_business.id,'name',v_business.name,'slug',v_business.slug,
      'industry',v_business.industry,'company_id',v_prospect.company_id,
      'acquired_via',case when v_business.source_prospect_id is not null
        then 'assisted_sale' else 'self_service' end),
    'relationship_owner',(select jsonb_build_object(
        'consultant_id',consultant.id,'name',consultant.display_name,'active',consultant.active)
      from public.platform_consultants consultant where consultant.id=v_prospect.assigned_consultant_id),
    'commercial',jsonb_build_object(
      'prospect_id',v_prospect.id,'stage',v_prospect.current_stage_key,
      'ownership_state',v_prospect.ownership_state,'queue_key',v_prospect.queue_key),
    -- Commercial success and money are reported separately, on purpose.
    'entitlement',jsonb_build_object(
      'entitled',v_entitled,'evidence',v_payment,
      'payment_status',(select payment_status from public.subscriptions
         where business_id=p_business),
      'activated_at',v_business.activated_at,
      'live',v_business.activated_at is not null),
    'onboarding',(select jsonb_build_object(
        'status',checklist.status,'blocked_reason',checklist.blocked_reason,
        'started_at',checklist.started_at,'activated_at',checklist.activated_at)
      from public.business_onboarding_checklists checklist
      where checklist.business_id=p_business
      order by checklist.created_at desc limit 1),
    'next_action',(select jsonb_build_object(
        'work_item_id',item.id,'title',item.title,'work_type',item.work_type,
        'state',item.state,'due_at',item.due_at,'owner',item.owner_consultant_id,
        'queue_key',item.queue_key,'blocker_reason',item.blocker_reason)
      from public.work_items_v511 item
      where item.business_id=p_business and item.closed_at is null
      order by item.due_at,item.priority desc limit 1),
    'open_work',jsonb_build_object(
      'total',(select count(*) from public.work_items_v511
        where business_id=p_business and closed_at is null),
      'overdue',(select count(*) from public.work_items_v511
        where business_id=p_business and closed_at is null and due_at<clock_timestamp()),
      'blocked',(select count(*) from public.work_items_v511
        where business_id=p_business and closed_at is null and state='blocked')),
    'blocker',coalesce(
      (select item.blocker_reason from public.work_items_v511 item
        where item.business_id=p_business and item.closed_at is null
          and item.state='blocked' order by item.due_at limit 1),
      (select checklist.blocked_reason from public.business_onboarding_checklists checklist
        where checklist.business_id=p_business and checklist.blocked_reason is not null
        order by checklist.created_at desc limit 1),
      case when not v_entitled and v_business.activated_at is null
        then 'awaiting verified initial payment' end),
    'timeline',coalesce((
      select jsonb_agg(to_jsonb(entry) order by entry.at desc)
      from (
        select event.created_at at,'work' source,event.event_type kind,
          item.title subject,
          jsonb_build_object('from',event.from_state,'to',event.to_state,'detail',event.detail) detail
        from public.work_item_events_v511 event
        join public.work_items_v511 item on item.id=event.work_item_id
        where item.business_id=p_business
        union all
        select history.occurred_at,'commercial',history.reason_code,
          history.from_stage_key||' -> '||history.to_stage_key,
          jsonb_build_object('reason_detail',history.reason_detail)
        from public.sme_prospect_stage_history history
        where history.prospect_id=v_prospect.id
        order by 1 desc limit v_limit) entry
    ),'[]'::jsonb));
end $$;

-- ---------------------------------------------------------- command center

-- "What requires action today?" answered by ONE server call, across work,
-- leads and onboarding, with every row carrying its own reason and owner.
-- Exception-driven: a healthy operation returns an empty list, not a wall of
-- cards that nobody reads.
create or replace function public.platform_command_center_v511(
  p_limit integer default 50
) returns jsonb language plpgsql stable security definer
set search_path to 'pg_catalog','public','app','pg_temp' as $$
declare v_role text:=app.v511_assert_work_reader();v_self uuid:=app.v226_self_consultant();
  v_limit integer:=least(greatest(coalesce(p_limit,50),1),200);
  v_scoped boolean:=v_role='sales_staff';
  v_day_end timestamptz:=(date_trunc('day',clock_timestamp() at time zone 'Asia/Singapore')
    +interval '1 day') at time zone 'Asia/Singapore';
  v_items jsonb;
begin
  with attention as (
    -- Work that is late, blocked, unowned, or owned by somebody who has left.
    select 'work' domain,item.id ref_id,item.title subject,item.work_type reason_type,
      item.due_at due_at,item.owner_consultant_id owner_id,item.business_id,item.prospect_id,
      case
        when item.state='blocked' then 'blocked'
        when item.ownership_state='queued' then 'unassigned'
        when consultant.id is null or not consultant.active then 'inactive_owner'
        when item.due_at<clock_timestamp() then 'overdue'
        else 'due_today' end reason,
      case when item.state='blocked' or item.due_at<clock_timestamp() then 3 else 2 end severity
    from public.work_items_v511 item
    left join public.platform_consultants consultant on consultant.id=item.owner_consultant_id
    where item.closed_at is null and item.due_at<v_day_end
      and (not v_scoped or item.owner_consultant_id=v_self or item.ownership_state='queued')

    union all
    -- Leads whose next action is missing, late, unowned or orphaned (v510 contract).
    select 'lead',prospect.id,coalesce(company.trading_name,company.legal_name),
      prospect.next_action_type,prospect.next_action_at,prospect.assigned_consultant_id,
      null::uuid,prospect.id,
      case
        when prospect.ownership_state='queued' then 'unassigned'
        when consultant.id is null or not consultant.active then 'inactive_owner'
        when prospect.next_action_at is null then 'missing_next_action'
        when prospect.next_action_at<clock_timestamp() then 'overdue'
        else 'due_today' end,
      case when prospect.next_action_at is null
        or prospect.next_action_at<clock_timestamp() then 3 else 2 end
    from public.sme_prospects prospect
    join public.sme_companies company on company.id=prospect.company_id
    left join public.platform_consultants consultant on consultant.id=prospect.assigned_consultant_id
    join public.sme_pipeline_stages stage on stage.stage_key=prospect.current_stage_key
    where prospect.archived_at is null and prospect.converted_business_id is null
      and (stage.kind='active' or prospect.current_stage_key='closed_won')
      and (prospect.next_action_at is null or prospect.next_action_at<v_day_end)
      and (not v_scoped or prospect.assigned_consultant_id=v_self
        or prospect.ownership_state='queued')

    union all
    -- Onboarding that has stalled or been explicitly blocked.
    select 'onboarding',checklist.business_id,business.name,'onboarding',
      checklist.updated_at,null::uuid,checklist.business_id,checklist.prospect_id,
      case when checklist.blocked_reason is not null then 'blocked' else 'stalled' end,3
    from public.business_onboarding_checklists checklist
    join public.businesses business on business.id=checklist.business_id
    where checklist.activated_at is null
      and (checklist.blocked_reason is not null
        or checklist.updated_at<clock_timestamp()-interval '3 days')
      and not v_scoped

    union all
    -- Money that did not land: an entitled-looking subscription whose provider
    -- says otherwise. Finance sees this before the merchant complains.
    select 'billing',subscription.business_id,business.name,'payment',
      coalesce(subscription.next_payment_at,subscription.updated_at),null::uuid,
      subscription.business_id,null::uuid,'payment_failed',3
    from public.subscriptions subscription
    join public.businesses business on business.id=subscription.business_id
    where subscription.payment_status in ('past_due','unpaid','incomplete_expired')
      and not v_scoped

    union all
    -- A self-service application nobody has decided yet. It has no owner column
    -- of its own, so without this it is invisible to every queue in the system.
    select 'application',application.id,application.business_name,'application_decision',
      application.created_at,null::uuid,null::uuid,null::uuid,
      case when application.created_at<clock_timestamp()-interval '2 days'
        then 'overdue' else 'awaiting_decision' end,
      case when application.created_at<clock_timestamp()-interval '2 days' then 3 else 2 end
    from public.business_applications_v95 application
    where application.status='submitted' and not v_scoped
  )
  select jsonb_agg(to_jsonb(row) order by row.severity desc,row.due_at nulls first)
    into v_items
  from (select * from attention order by severity desc,due_at nulls first limit v_limit) row;

  return jsonb_build_object(
    'as_of',clock_timestamp(),'scope',case when v_scoped then 'own' else 'operation' end,
    'items',coalesce(v_items,'[]'::jsonb));
end $$;

-- ---------------------------------------------------------------- adapters

-- Each legacy task concept stays its own system of record and PROJECTS here.
-- Projection is one-way on purpose: a projected work item cannot be closed on
-- its own, because that is exactly how two task systems start disagreeing about
-- whether the job is done. Close the source; the projection follows.
create or replace function app.v511_project_prospect_task()
returns trigger language plpgsql security definer
set search_path to 'pg_catalog','public','app','pg_temp' as $$
declare v_company uuid;v_id uuid;
begin
  select company_id into v_company from public.sme_prospects where id=new.prospect_id;
  if new.status='open' then
    v_id:=app.v511_ensure_work_item('sme_prospect_task',new.id::text,'lead_follow_up',
      new.title,null,null,new.prospect_id,v_company,
      new.due_at,null,0,new.assigned_consultant_id,'sales_intake',new.created_by);
  else
    update public.work_items_v511 set
      state=case when new.status='completed' then 'done' else 'cancelled' end,
      closed_at=coalesce(new.completed_at,clock_timestamp()),
      closed_by=coalesce(closed_by,auth.uid()),
      close_outcome=case when new.status='completed' then 'completed' else 'not_needed' end,
      version=version+1
    where origin_kind='sme_prospect_task' and origin_key=new.id::text and closed_at is null;
  end if;
  return null;
end $$;
drop trigger if exists sme_prospect_tasks_v511_projection on public.sme_prospect_tasks;
create trigger sme_prospect_tasks_v511_projection after insert or update of status,due_at,title,assigned_consultant_id
  on public.sme_prospect_tasks for each row execute function app.v511_project_prospect_task();

-- The v156 task_type enum is closed; map every member deliberately rather than
-- guessing with a pattern that silently matches nothing.
create or replace function app.v511_subscription_work_type(p_task_type text)
returns text language sql immutable
set search_path to 'pg_catalog','pg_temp' as $$
  select case p_task_type
    when 'payment_failed' then 'payment_exception'
    when 'payment_action_required' then 'payment_exception'
    when 'past_due' then 'payment_exception'
    when 'renewal_30' then 'renewal_prep'
    when 'renewal_14' then 'renewal_prep'
    when 'renewal_7' then 'renewal_prep'
    when 'cancel_at_period_end' then 'renewal_prep'
    when 'billing_contact_missing' then 'data_correction'
    when 'billing_profile_missing' then 'data_correction'
    when 'invoice_delivery_failed' then 'data_correction'
    when 'onboarding' then 'onboarding_step'
    else 'payment_exception' end
$$;
revoke all on function app.v511_subscription_work_type(text) from public,anon,authenticated;

create or replace function app.v511_project_subscription_task()
returns trigger language plpgsql security definer
set search_path to 'pg_catalog','public','app','pg_temp' as $$
declare v_id uuid;v_priority integer;
begin
  v_priority:=case lower(coalesce(new.priority,'')) when 'high' then 3 when 'urgent' then 3
    when 'low' then 0 else 1 end;
  if new.status='open' then
    v_id:=app.v511_ensure_work_item('subscription_task',new.id::text,
      app.v511_subscription_work_type(new.task_type),
      coalesce(new.title,new.task_type),null,new.business_id,new.prospect_id,null,
      new.due_at,null,v_priority,new.assigned_consultant_id,'finance_intake',null);
  else
    update public.work_items_v511 set
      state=case when new.status='completed' then 'done' else 'cancelled' end,
      closed_at=coalesce(new.completed_at,clock_timestamp()),
      closed_by=coalesce(closed_by,auth.uid()),
      close_outcome=case when new.status='completed' then 'completed' else 'not_needed' end,
      version=version+1
    where origin_kind='subscription_task' and origin_key=new.id::text and closed_at is null;
  end if;
  return null;
end $$;
drop trigger if exists platform_subscription_tasks_v511_projection on public.platform_subscription_tasks_v156;
create trigger platform_subscription_tasks_v511_projection
  after insert or update of status,due_at,title,assigned_consultant_id,priority
  on public.platform_subscription_tasks_v156 for each row
  execute function app.v511_project_subscription_task();

-- Only BLOCKED onboarding items become work. A checklist full of pending steps
-- is the merchant's job, not a queue of internal actions — projecting all of
-- them would bury the operator in noise and defeat the exception model.
create or replace function app.v511_project_onboarding_item()
returns trigger language plpgsql security definer
set search_path to 'pg_catalog','public','app','pg_temp' as $$
declare v_id uuid;
begin
  if new.status='blocked' then
    v_id:=app.v511_ensure_work_item('onboarding_item',new.id::text,'onboarding_blocked',
      coalesce(new.label,new.item_key),new.block_reason,new.business_id,null,null,
      coalesce(new.blocked_at,clock_timestamp()),null,3,null,'operations_intake',new.blocked_by);
    update public.work_items_v511 set state='blocked',blocker_reason=new.block_reason,version=version+1
     where id=v_id and state<>'blocked';
  else
    update public.work_items_v511 set
      state='done',closed_at=clock_timestamp(),closed_by=coalesce(closed_by,auth.uid()),
      close_outcome=case when new.status='satisfied' then 'completed' else 'not_needed' end,
      blocker_reason=null,version=version+1
    where origin_kind='onboarding_item' and origin_key=new.id::text and closed_at is null;
  end if;
  return null;
end $$;
drop trigger if exists business_onboarding_items_v511_projection on public.business_onboarding_items;
create trigger business_onboarding_items_v511_projection after insert or update of status,block_reason
  on public.business_onboarding_items for each row execute function app.v511_project_onboarding_item();

-- ---------------------------------------------------------------- backfill

-- Existing open work becomes visible immediately. Without this the Command
-- Center would open empty and quietly hide every action already outstanding.
insert into public.work_items_v511(
  origin_kind,origin_key,work_type,title,business_id,prospect_id,company_id,
  ownership_state,owner_consultant_id,queue_key,priority,due_at,created_by,created_at)
select 'sme_prospect_task',task.id::text,'lead_follow_up',task.title,
  null,task.prospect_id,prospect.company_id,
  case when task.assigned_consultant_id is not null then 'owned' else 'queued' end,
  task.assigned_consultant_id,
  case when task.assigned_consultant_id is not null then null else 'sales_intake' end,
  0,coalesce(task.due_at,clock_timestamp()),task.created_by,task.created_at
from public.sme_prospect_tasks task
join public.sme_prospects prospect on prospect.id=task.prospect_id
where task.status='open'
on conflict(origin_kind,origin_key) do nothing;

insert into public.work_items_v511(
  origin_kind,origin_key,work_type,title,business_id,prospect_id,
  ownership_state,owner_consultant_id,queue_key,priority,due_at,created_at)
select 'subscription_task',task.id::text,
  app.v511_subscription_work_type(task.task_type),
  coalesce(task.title,task.task_type),task.business_id,task.prospect_id,
  case when task.assigned_consultant_id is not null then 'owned' else 'queued' end,
  task.assigned_consultant_id,
  case when task.assigned_consultant_id is not null then null else 'finance_intake' end,
  case lower(coalesce(task.priority,'')) when 'high' then 3 when 'urgent' then 3
    when 'low' then 0 else 1 end,
  coalesce(task.due_at,clock_timestamp()),task.created_at
from public.platform_subscription_tasks_v156 task
where task.status='open'
on conflict(origin_kind,origin_key) do nothing;

insert into public.work_items_v511(
  origin_kind,origin_key,work_type,title,detail,business_id,
  ownership_state,queue_key,priority,due_at,state,blocker_reason,created_at)
select 'onboarding_item',item.id::text,'onboarding_blocked',
  coalesce(item.label,item.item_key),item.block_reason,item.business_id,
  'queued','operations_intake',3,coalesce(item.blocked_at,clock_timestamp()),
  'blocked',item.block_reason,coalesce(item.blocked_at,clock_timestamp())
from public.business_onboarding_items item
where item.status='blocked'
on conflict(origin_kind,origin_key) do nothing;

-- ------------------------------------------------------------------ grants

revoke all on function public.platform_create_work_item_v511(
  text,text,text,uuid,uuid,timestamptz,uuid,text,integer,uuid) from public,anon;
revoke all on function public.platform_assign_work_item_v511(
  uuid,bigint,uuid,text,uuid) from public,anon;
revoke all on function public.platform_transition_work_item_v511(
  uuid,bigint,text,text,timestamptz,timestamptz,text,uuid) from public,anon;
revoke all on function public.platform_reopen_due_work_v511(integer) from public,anon,authenticated;
revoke all on function public.platform_list_work_v511(text,uuid,integer) from public,anon;
revoke all on function public.platform_get_business_360_v511(uuid,integer) from public,anon;
revoke all on function public.platform_command_center_v511(integer) from public,anon;
revoke all on function app.v511_work_item_guard() from public,anon,authenticated;
revoke all on function app.v511_work_item_history() from public,anon,authenticated;
revoke all on function app.v511_work_events_append_only() from public,anon,authenticated;
revoke all on function app.v511_project_prospect_task() from public,anon,authenticated;
revoke all on function app.v511_project_subscription_task() from public,anon,authenticated;
revoke all on function app.v511_project_onboarding_item() from public,anon,authenticated;

grant execute on function public.platform_create_work_item_v511(
  text,text,text,uuid,uuid,timestamptz,uuid,text,integer,uuid) to authenticated;
grant execute on function public.platform_assign_work_item_v511(
  uuid,bigint,uuid,text,uuid) to authenticated;
grant execute on function public.platform_transition_work_item_v511(
  uuid,bigint,text,text,timestamptz,timestamptz,text,uuid) to authenticated;
grant execute on function public.platform_list_work_v511(text,uuid,integer) to authenticated;
grant execute on function public.platform_get_business_360_v511(uuid,integer) to authenticated;
grant execute on function public.platform_command_center_v511(integer) to authenticated;

do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.schedule('nestly-v511-work-reopen', '*/10 * * * *',
      'select public.platform_reopen_due_work_v511(500)');
  end if;
end $$;

commit;
