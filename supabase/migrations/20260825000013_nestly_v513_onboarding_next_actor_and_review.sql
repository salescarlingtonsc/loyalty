-- NESTLY v513 — Peekaa Operating System P4 increment 1: onboarding knows whose
-- move it is.
--
-- v79 already answers "what is still missing?" with a REAL derived evaluator
-- that gates on actual tenant rows. It never answers the operational question
-- that decides whether a business goes live this week: WHOSE MOVE IS IT? A
-- checklist sitting at in_progress is either a merchant who has not uploaded
-- their documents or a Peekaa operator who has not looked at what they already
-- sent, and today those two look identical.
--
-- v513 adds the turn, and only the turn:
--   1. next_actor is DERIVED from the status v79 already computes, in a trigger
--      on the checklist, so every existing writer — recompute, refresh, block,
--      unblock, waive, activate — keeps working untouched and cannot leave the
--      turn stale. v79's own functions are not rewritten or forked.
--   2. A merchant (or an operator on their behalf) can hand the turn over
--      explicitly, which becomes ONE work item in the v511 queue, not a second
--      task system.
--   3. A turn that nobody takes becomes visible by itself: >24h on Peekaa is an
--      internal stall, >5 days on the merchant is a nudge.
--   4. Every touch is recorded, so "<=15-20 minutes of staff intervention per
--      onboarding" becomes a measured number instead of a belief.
--
-- Deliberately NOT here: automatic activation. A ready checklist hands the turn
-- to Peekaa and stops. Going live is an operator decision (OWNER-OPS-002 is an
-- open owner decision) and activate_business_v79 remains the only door.

begin;

-- --------------------------------------------------------------- next actor

alter table public.business_onboarding_checklists
  add column if not exists next_actor text not null default 'peekaa'
    check(next_actor in ('merchant','peekaa','system')),
  add column if not exists submitted_for_review_at timestamptz,
  add column if not exists last_evaluated_at timestamptz,
  add column if not exists template_version integer not null default 1
    check(template_version>0);

-- One rule, written once. Both the trigger and the backfill call it, so a row
-- created before v513 and a row created after it can never disagree about whose
-- move it is.
create or replace function app.v513_next_actor(p_status text,p_submitted timestamptz)
returns text language sql immutable
set search_path to 'pg_catalog','public','app','pg_temp' as $$
  select case
    -- A live workspace has no human turn left; the system owns it.
    when p_status='activated' then 'system'
    -- Blocked is an internal decision to unblock, never a merchant task.
    when p_status='blocked' then 'peekaa'
    -- Ready is NOT auto-activation: it is Peekaa's turn to decide.
    when p_status='ready' then 'peekaa'
    -- The merchant has handed the work over and is waiting on us.
    when p_submitted is not null and p_status='in_progress' then 'peekaa'
    else 'merchant' end
$$;
revoke all on function app.v513_next_actor(text,timestamptz) from public,anon,authenticated;

create or replace function app.v513_derive_next_actor()
returns trigger language plpgsql security definer
set search_path to 'pg_catalog','public','app','pg_temp' as $$
begin
  new.next_actor:=app.v513_next_actor(new.status,new.submitted_for_review_at);
  return new;
end $$;
revoke all on function app.v513_derive_next_actor() from public,anon,authenticated;
drop trigger if exists aa_business_onboarding_next_actor_v513
  on public.business_onboarding_checklists;
create trigger aa_business_onboarding_next_actor_v513
  before insert or update on public.business_onboarding_checklists
  for each row execute function app.v513_derive_next_actor();

-- Existing checklists get their turn by the same rule, before the measurement
-- triggers exist — a migration is not an intervention and must not be counted
-- as one.
update public.business_onboarding_checklists
   set next_actor=app.v513_next_actor(status,submitted_for_review_at)
 where next_actor is distinct from app.v513_next_actor(status,submitted_for_review_at);

-- ------------------------------------------------------- v511 origin widening

-- One work origin is added to v511's closed list and nothing else about that
-- constraint changes. A review round is not an 'onboarding_item' (that origin
-- means one blocked step) and not a 'system_sweep' (that origin means nobody
-- asked).
alter table public.work_items_v511
  drop constraint work_items_v511_origin_kind_check;
alter table public.work_items_v511
  add constraint work_items_v511_origin_kind_check check(origin_kind in
    ('native','sme_prospect_task','subscription_task','onboarding_item',
     'payment_exception','system_sweep','onboarding_review'));

-- ------------------------------------------------------------- measurement

-- Append-only record of every hand that touched an onboarding. This is the raw
-- material for "how many minutes of staff time does one activation cost?" —
-- stored as facts, never as a score.
create table public.onboarding_interventions_v513(
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  checklist_id uuid not null
    references public.business_onboarding_checklists(id) on delete cascade,
  actor uuid references auth.users(id) on delete restrict,
  actor_kind text not null check(actor_kind in ('platform','merchant','system')),
  action text not null check(length(btrim(action)) between 1 and 120),
  detail jsonb not null default '{}'::jsonb check(jsonb_typeof(detail)='object'),
  created_at timestamptz not null default clock_timestamp()
);
create index onboarding_interventions_v513_checklist_idx
  on public.onboarding_interventions_v513(checklist_id,created_at);
create index onboarding_interventions_v513_business_idx
  on public.onboarding_interventions_v513(business_id,created_at);
alter table public.onboarding_interventions_v513 enable row level security;
revoke all privileges on table public.onboarding_interventions_v513
  from public,anon,authenticated;

create or replace function app.v513_interventions_append_only()
returns trigger language plpgsql
set search_path to 'pg_catalog','pg_temp' as $$
begin
  raise exception 'onboarding intervention history is append-only' using errcode='42501';
end $$;
revoke all on function app.v513_interventions_append_only() from public,anon,authenticated;
drop trigger if exists onboarding_interventions_v513_immutable
  on public.onboarding_interventions_v513;
create trigger onboarding_interventions_v513_immutable before update or delete
  on public.onboarding_interventions_v513 for each row
  execute function app.v513_interventions_append_only();

-- Who touched it is decided from the actor's OWN grants, not from whichever
-- session variable happens to be set, so the same row means the same thing when
-- it is read back a quarter later.
create or replace function app.v513_actor_kind(p_business uuid,p_actor uuid)
returns text language sql stable security definer
set search_path to 'pg_catalog','public','app','pg_temp' as $$
  select case
    when p_actor is null then 'system'
    when exists(select 1 from public.super_admins admin where admin.user_id=p_actor)
      or exists(select 1 from public.platform_access_grants_v89 grant_row
        where grant_row.user_id=p_actor and grant_row.active) then 'platform'
    when exists(select 1 from public.staff staff_row
      where staff_row.business_id=p_business and staff_row.user_id=p_actor
        and staff_row.active) then 'merchant'
    else 'system' end
$$;
revoke all on function app.v513_actor_kind(uuid,uuid) from public,anon,authenticated;

-- The evaluator is not forked: v79 writes its verdict onto the derived items and
-- this trigger notices, so last_evaluated_at is true for every existing caller
-- of refresh_business_onboarding_v79 without touching that function.
create or replace function app.v513_record_item_touch()
returns trigger language plpgsql security definer
set search_path to 'pg_catalog','public','app','pg_temp' as $$
begin
  if new.verification_mode='derived' then
    update public.business_onboarding_checklists
       set last_evaluated_at=clock_timestamp()
     where id=new.checklist_id;
  end if;
  if new.status is distinct from old.status or new.evidence is distinct from old.evidence then
    insert into public.onboarding_interventions_v513(
      business_id,checklist_id,actor,actor_kind,action,detail)
    values(new.business_id,new.checklist_id,auth.uid(),
      app.v513_actor_kind(new.business_id,auth.uid()),
      'onboarding_item_'||new.status,
      jsonb_build_object('item_key',new.item_key,'from_status',old.status,
        'to_status',new.status,'verification_mode',new.verification_mode,
        'evidence_changed',new.evidence is distinct from old.evidence));
  end if;
  return null;
end $$;
revoke all on function app.v513_record_item_touch() from public,anon,authenticated;
drop trigger if exists business_onboarding_items_v513_touch on public.business_onboarding_items;
create trigger business_onboarding_items_v513_touch
  after update on public.business_onboarding_items
  for each row execute function app.v513_record_item_touch();

create or replace function app.v513_record_checklist_touch()
returns trigger language plpgsql security definer
set search_path to 'pg_catalog','public','app','pg_temp' as $$
begin
  if new.status is distinct from old.status or new.next_actor is distinct from old.next_actor then
    insert into public.onboarding_interventions_v513(
      business_id,checklist_id,actor,actor_kind,action,detail)
    values(new.business_id,new.id,auth.uid(),
      app.v513_actor_kind(new.business_id,auth.uid()),
      case when new.status is distinct from old.status
        then 'onboarding_status_'||new.status
        else 'onboarding_next_actor_'||new.next_actor end,
      jsonb_build_object('from_status',old.status,'to_status',new.status,
        'from_next_actor',old.next_actor,'to_next_actor',new.next_actor));
  end if;
  return null;
end $$;
revoke all on function app.v513_record_checklist_touch() from public,anon,authenticated;
drop trigger if exists business_onboarding_checklists_v513_touch
  on public.business_onboarding_checklists;
create trigger business_onboarding_checklists_v513_touch
  after update on public.business_onboarding_checklists
  for each row execute function app.v513_record_checklist_touch();

-- ---------------------------------------------------------- submit for review

-- The merchant's explicit "I am done, look at it". It re-runs v79's real
-- evaluator first, so a submission can never claim readiness the tenant rows do
-- not support, and it produces exactly one work item per round.
create or replace function public.onboarding_submit_for_review_v513(
  p_business uuid,p_idempotency_key uuid
) returns jsonb language plpgsql security definer
set search_path to 'pg_catalog','public','app','pg_temp' as $$
declare
  v_actor uuid:=auth.uid();v_hash text;v_replay jsonb;
  v_check public.business_onboarding_checklists%rowtype;
  v_name text;v_round integer;v_work uuid;v_response jsonb;
begin
  if p_idempotency_key is null then
    raise exception 'an operation key is required' using errcode='22023';end if;
  if app.v89_platform_role() is null and not exists(
    select 1 from public.staff
     where business_id=p_business and user_id=v_actor and role='owner' and active
  ) then
    raise exception 'an active workspace owner or a platform operator may submit onboarding for review'
      using errcode='42501';end if;

  v_hash:=app.v76_sha256_hex(jsonb_build_object('business',p_business)::text);
  perform pg_advisory_xact_lock(hashtextextended(
    'v513:submit:'||v_actor::text||':'||p_idempotency_key::text,0));
  v_replay:=app.v76_replay(v_actor,'onboarding_submit_for_review_v513',
    p_idempotency_key::text,v_hash);
  if v_replay is not null then return v_replay;end if;

  select * into v_check from public.business_onboarding_checklists
   where business_id=p_business for update;
  if not found then
    raise exception 'onboarding checklist was not found' using errcode='22023';end if;
  -- Two refusals, so that "submitted" always means the turn really moved to
  -- Peekaa: an activated workspace has nothing left to review, and a checklist
  -- that never started has nothing to look at.
  if v_check.status='activated' then
    raise exception 'an activated business has nothing left to review' using errcode='22023';end if;
  if v_check.status='not_started' then
    raise exception 'onboarding has not started yet' using errcode='22023';end if;

  -- (a) v79 decides what is satisfied. v513 never re-implements that judgement.
  perform app.refresh_onboarding_core_v79(p_business,v_actor);

  -- A round advances only after the previous round was actually completed, so
  -- re-submitting while Peekaa still owes an answer lands on the SAME origin key
  -- and therefore the same single work item.
  select count(*)+1 into v_round from public.work_items_v511
   where origin_kind='onboarding_review'
     and origin_key like v_check.id::text||':%'
     and closed_at is not null;

  update public.business_onboarding_checklists
     set submitted_for_review_at=clock_timestamp(),
         last_evaluated_at=clock_timestamp(),
         version=version+1,updated_at=clock_timestamp()
   where id=v_check.id
  returning * into v_check;

  select name into v_name from public.businesses where id=p_business;
  v_work:=app.v511_ensure_work_item(
    'onboarding_review',v_check.id::text||':'||v_round,'onboarding_step',
    left('Review onboarding submission — '||coalesce(v_name,'business'),180),
    'The merchant submitted their onboarding for review. Status at submission: '
      ||v_check.status||'.',
    p_business,null,null,clock_timestamp()+interval '1 day',null,2,null,
    'operations_intake',v_actor);

  v_response:=jsonb_build_object('replayed',false,'business_id',p_business,
    'checklist_id',v_check.id,'status',v_check.status,'next_actor',v_check.next_actor,
    'submitted_for_review_at',v_check.submitted_for_review_at,
    'review_round',v_round,'work_item_id',v_work,'version',v_check.version);
  perform app.v76_store_receipt(v_actor,'onboarding_submit_for_review_v513',
    p_idempotency_key::text,v_hash,v_response);
  return v_response;
end $$;

-- ---------------------------------------------------------------- stall sweep

-- A turn nobody takes is the failure mode this whole increment exists to catch.
-- Cron only wakes it; both rules live here, both are bounded, and both are
-- idempotent per day, so running it twice in an hour changes nothing.
create or replace function public.platform_sweep_stalled_onboarding_v513(
  p_limit integer default 200
) returns jsonb language plpgsql security definer
set search_path to 'pg_catalog','public','app','pg_temp' as $$
declare
  v_limit integer:=least(greatest(coalesce(p_limit,200),1),1000);
  v_row record;v_stalled integer:=0;v_nudged integer:=0;v_day text:=current_date::text;
begin
  if app.v89_platform_role() is distinct from 'super_admin' and auth.uid() is not null then
    raise exception 'only the platform may sweep stalled onboarding' using errcode='42501';end if;

  -- Rule 1: Peekaa has owed an answer for more than a day.
  for v_row in
    select checklist.id,checklist.business_id,business.name
      from public.business_onboarding_checklists checklist
      join public.businesses business on business.id=checklist.business_id
     where checklist.activated_at is null
       and checklist.next_actor='peekaa'
       and checklist.updated_at<clock_timestamp()-interval '24 hours'
     order by checklist.updated_at
     limit v_limit
       for update of checklist skip locked
  loop
    perform app.v511_ensure_work_item('system_sweep',
      'onboarding-stall:'||v_row.id::text||':'||v_day,'onboarding_step',
      left('Onboarding waiting on Peekaa — '||coalesce(v_row.name,'business'),180),
      'This onboarding has been Peekaa''s move for more than 24 hours.',
      v_row.business_id,null,null,clock_timestamp(),null,3,null,'operations_intake',null);
    v_stalled:=v_stalled+1;
  end loop;

  -- Rule 2: the merchant has gone quiet for a working week.
  for v_row in
    select checklist.id,checklist.business_id,business.name
      from public.business_onboarding_checklists checklist
      join public.businesses business on business.id=checklist.business_id
     where checklist.activated_at is null
       and checklist.next_actor='merchant'
       and checklist.updated_at<clock_timestamp()-interval '5 days'
     order by checklist.updated_at
     limit v_limit
       for update of checklist skip locked
  loop
    perform app.v511_ensure_work_item('system_sweep',
      'onboarding-nudge:'||v_row.id::text||':'||v_day,'onboarding_step',
      left('Nudge merchant — '||coalesce(v_row.name,'business'),180),
      'This onboarding has been the merchant''s move for more than 5 days.',
      v_row.business_id,null,null,clock_timestamp(),null,1,null,'operations_intake',null);
    v_nudged:=v_nudged+1;
  end loop;

  return jsonb_build_object('as_of',clock_timestamp(),
    'stalled',v_stalled,'nudged',v_nudged);
end $$;

-- -------------------------------------------------------------- review reader

-- What an operator needs in front of them to answer a submission: the turn, the
-- evidence, whether it really is ready, how much of our own time it has already
-- taken, and whether the money landed.
create or replace function public.platform_get_onboarding_review_v513(p_business uuid)
returns jsonb language plpgsql stable security definer
set search_path to 'pg_catalog','public','app','pg_temp' as $$
declare v_role text:=app.v511_assert_work_reader();
  v_check public.business_onboarding_checklists%rowtype;
  v_activated timestamptz;
begin
  select * into v_check from public.business_onboarding_checklists
   where business_id=p_business;
  if not found then
    raise exception 'onboarding checklist was not found' using errcode='P0002';end if;
  select activated_at into v_activated from public.businesses where id=p_business;

  return jsonb_build_object(
    'as_of',clock_timestamp(),
    'checklist',jsonb_build_object(
      'checklist_id',v_check.id,'business_id',v_check.business_id,
      'status',v_check.status,'next_actor',v_check.next_actor,
      'submitted_for_review_at',v_check.submitted_for_review_at,
      'last_evaluated_at',v_check.last_evaluated_at,
      'template_version',v_check.template_version,
      'blocked_reason',v_check.blocked_reason,'version',v_check.version),
    'items',coalesce((select jsonb_agg(jsonb_build_object(
        'item_key',item.item_key,'label',item.label,'category',item.category,
        'verification_mode',item.verification_mode,'mandatory',item.mandatory,
        'waivable',item.waivable,'status',item.status,'evidence',item.evidence,
        'satisfied_at',item.satisfied_at,'waived_at',item.waived_at,
        'waiver_reason',item.waiver_reason,'block_reason',item.block_reason,
        'updated_at',item.updated_at)
        order by item.category,item.item_key)
      from public.business_onboarding_items item
      where item.checklist_id=v_check.id),'[]'::jsonb),
    -- Ready is recomputed from the items themselves rather than trusted from the
    -- status column, so the reader and the evaluator can never drift apart.
    'ready',not exists(select 1 from public.business_onboarding_items item
      where item.checklist_id=v_check.id and item.mandatory
        and item.status not in ('satisfied','waived')),
    'interventions',(select jsonb_build_object(
        'platform_touches',count(*) filter (where touch.actor_kind='platform'),
        'merchant_touches',count(*) filter (where touch.actor_kind='merchant'),
        'first_touch_at',min(touch.created_at),'last_touch_at',max(touch.created_at))
      from public.onboarding_interventions_v513 touch
      where touch.checklist_id=v_check.id),
    'entitlement',jsonb_build_object(
      'entitled',app.v510_verified_initial_payment(p_business) is not null,
      'live',v_activated is not null));
end $$;

-- The cost side of the same question, across the book. No composite score: a
-- number an operator cannot explain is a number they will not act on.
create or replace function public.platform_get_onboarding_metrics_v513(
  p_limit integer default 100
) returns jsonb language plpgsql stable security definer
set search_path to 'pg_catalog','public','app','pg_temp' as $$
declare v_limit integer:=least(greatest(coalesce(p_limit,100),1),500);
begin
  if not app.is_super_admin() then
    raise exception 'super admin is required' using errcode='42501';end if;
  return jsonb_build_object('as_of',clock_timestamp(),'businesses',coalesce((
    select jsonb_agg(to_jsonb(row) order by row.created_at desc)
    from (
      select business.id business_id,business.name,business.created_at,
        checklist.status,checklist.next_actor,checklist.submitted_for_review_at,
        business.activated_at,
        (select count(*) from public.onboarding_interventions_v513 touch
          where touch.checklist_id=checklist.id and touch.actor_kind='platform')
          platform_touches,
        (select count(*) from public.onboarding_interventions_v513 touch
          where touch.checklist_id=checklist.id and touch.actor_kind='merchant')
          merchant_touches,
        case when business.activated_at is not null then round(
          extract(epoch from(business.activated_at-business.created_at))/86400.0,2)
        end days_to_live,
        case when business.activated_at is not null
          and checklist.submitted_for_review_at is not null
          then business.activated_at-checklist.submitted_for_review_at
        end submitted_to_activated,
        case when business.activated_at is not null
          and checklist.submitted_for_review_at is not null then round(
          extract(epoch from(business.activated_at-checklist.submitted_for_review_at))/3600.0,2)
        end submitted_to_activated_hours
      from public.business_onboarding_checklists checklist
      join public.businesses business on business.id=checklist.business_id
      where not business.is_demo
      order by business.created_at desc limit v_limit) row),'[]'::jsonb));
end $$;

-- ------------------------------------------------------------------- grants

revoke all on function public.onboarding_submit_for_review_v513(uuid,uuid)
  from public,anon;
revoke all on function public.platform_sweep_stalled_onboarding_v513(integer)
  from public,anon,authenticated;
revoke all on function public.platform_get_onboarding_review_v513(uuid)
  from public,anon;
revoke all on function public.platform_get_onboarding_metrics_v513(integer)
  from public,anon;

grant execute on function public.onboarding_submit_for_review_v513(uuid,uuid) to authenticated;
grant execute on function public.platform_get_onboarding_review_v513(uuid) to authenticated;
grant execute on function public.platform_get_onboarding_metrics_v513(integer) to authenticated;

comment on function public.onboarding_submit_for_review_v513(uuid,uuid) is
  'Hands the onboarding turn to Peekaa: re-runs the v79 evaluator, stamps the '
  'submission, and raises exactly one operations_intake work item per review round.';
comment on function public.platform_sweep_stalled_onboarding_v513(integer) is
  'Hourly cron rule: >24h on Peekaa raises a stall item, >5 days on the merchant '
  'raises a nudge item. Idempotent per checklist per day.';
comment on table public.onboarding_interventions_v513 is
  'Append-only record of every touch on an onboarding, so staff intervention cost '
  'per activation is measured rather than estimated.';

do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.schedule('nestly-v513-onboarding-stall', '7 * * * *',
      'select public.platform_sweep_stalled_onboarding_v513(200)');
  end if;
end $$;

commit;
