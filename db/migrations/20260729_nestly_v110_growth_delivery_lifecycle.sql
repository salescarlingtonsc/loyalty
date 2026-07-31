-- NESTLY v110 — PROVIDER-NEUTRAL GROWTH DELIVERY LIFECYCLE
--
-- Approval creates queued or quiet-hours-scheduled work. It does not issue an
-- entitlement. A service-role dispatcher claims work after rechecking the
-- feature, entitlement, execution, link, consent, quiet-hours, frequency and
-- budget gates. Only a verified successful callback marks delivery complete
-- and issues the single-use entitlement.

begin;

alter table public.growth_deliveries_v108
  drop constraint growth_deliveries_v108_delivery_status_check,
  drop constraint growth_deliveries_v108_suppression_reason_check,
  drop constraint growth_deliveries_v108_shape_check;

alter table public.growth_deliveries_v108
  add constraint growth_deliveries_v110_delivery_status_check check (
    delivery_status in (
      'queued', 'scheduled', 'delivering', 'delivered',
      'held_out', 'suppressed', 'failed', 'cancelled'
    )
  ),
  add constraint growth_deliveries_v110_suppression_reason_check check (
    suppression_reason is null or suppression_reason in (
      'holdout', 'consent_withdrawn', 'quiet_hours', 'frequency_cap',
      'link_unavailable', 'budget_cap', 'execution_cancelled',
      'feature_disabled', 'module_disabled', 'execution_expired',
      'provider_failure', 'owner_cancelled'
    )
  ),
  add constraint growth_deliveries_v110_shape_check check (
    (delivery_status in ('queued', 'scheduled', 'delivering')
      and assignment = 'treatment'
      and identity_id is not null and link_id is not null
      and delivered_at is null and suppression_reason is null
      and title is not null and body is not null)
    or (delivery_status = 'delivered'
      and assignment = 'treatment'
      and identity_id is not null and link_id is not null
      and delivered_at is not null and suppression_reason is null
      and title is not null and body is not null)
    or (delivery_status = 'held_out'
      and assignment = 'holdout' and suppression_reason = 'holdout'
      and delivered_at is null and estimated_cost_cents = 0)
    or (delivery_status in ('suppressed', 'failed', 'cancelled')
      and suppression_reason is not null and delivered_at is null)
  );

create table public.growth_delivery_dispatches_v110 (
  id uuid primary key default gen_random_uuid(),
  delivery_id uuid not null unique
    references public.growth_deliveries_v108(id) on delete restrict,
  execution_id uuid not null,
  business_id uuid not null,
  branch_id uuid,
  provider text not null default 'in_app'
    check (provider ~ '^[a-z][a-z0-9_]{1,39}$'),
  lifecycle_status text not null check (lifecycle_status in (
    'queued', 'scheduled', 'delivering', 'delivered',
    'held_out', 'suppressed', 'failed', 'cancelled'
  )),
  scheduled_for timestamptz not null default statement_timestamp(),
  next_attempt_at timestamptz not null default statement_timestamp(),
  attempt_count integer not null default 0 check (attempt_count between 0 and 5),
  claimed_by text,
  claimed_at timestamptz,
  provider_message_id text,
  delivered_at timestamptz,
  failure_code text,
  cancelled_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint growth_delivery_dispatches_v110_execution_fk
    foreign key (execution_id, business_id)
    references public.growth_executions_v108(id, business_id) on delete restrict,
  constraint growth_delivery_dispatches_v110_branch_fk
    foreign key (branch_id, business_id)
    references public.branches(id, business_id) on delete restrict,
  constraint growth_delivery_dispatches_v110_shape_check check (
    (lifecycle_status in ('queued', 'scheduled')
      and claimed_by is null and claimed_at is null
      and delivered_at is null and cancelled_at is null)
    or (lifecycle_status = 'delivering'
      and claimed_by is not null and claimed_at is not null
      and delivered_at is null and cancelled_at is null)
    or (lifecycle_status = 'delivered'
      and claimed_by is not null and claimed_at is not null
      and delivered_at is not null and provider_message_id is not null
      and cancelled_at is null)
    or (lifecycle_status = 'failed'
      and claimed_by is not null and claimed_at is not null
      and delivered_at is null and failure_code is not null
      and cancelled_at is null)
    or (lifecycle_status = 'cancelled'
      and delivered_at is null and failure_code is not null
      and cancelled_at is not null)
    or (lifecycle_status in ('held_out', 'suppressed')
      and claimed_by is null and claimed_at is null
      and delivered_at is null and cancelled_at is null)
  )
);

create index growth_delivery_dispatches_v110_claim_idx
  on public.growth_delivery_dispatches_v110(
    lifecycle_status, next_attempt_at, scheduled_for, created_at, id
  ) where lifecycle_status in ('queued', 'scheduled');

create index growth_delivery_dispatches_v110_execution_idx
  on public.growth_delivery_dispatches_v110(
    execution_id, lifecycle_status, created_at, id
  );

create table public.growth_delivery_state_events_v110 (
  id uuid primary key default gen_random_uuid(),
  dispatch_id uuid not null
    references public.growth_delivery_dispatches_v110(id) on delete restrict,
  delivery_id uuid not null
    references public.growth_deliveries_v108(id) on delete restrict,
  execution_id uuid not null,
  business_id uuid not null,
  from_status text,
  to_status text not null,
  reason_code text,
  provider_message_id text,
  actor uuid references auth.users(id) on delete restrict,
  idempotency_key uuid not null,
  request_hash text not null check (request_hash ~ '^[0-9a-f]{64}$'),
  detail jsonb not null default '{}'::jsonb
    check (jsonb_typeof(detail) = 'object'),
  occurred_at timestamptz not null default statement_timestamp(),
  created_at timestamptz not null default now(),
  constraint growth_delivery_state_events_v110_execution_fk
    foreign key (execution_id, business_id)
    references public.growth_executions_v108(id, business_id) on delete restrict,
  constraint growth_delivery_state_events_v110_idempotency_uk
    unique (delivery_id, idempotency_key)
);

create index growth_delivery_state_events_v110_dispatch_idx
  on public.growth_delivery_state_events_v110(dispatch_id, occurred_at, id);

alter table public.growth_delivery_dispatches_v110 enable row level security;
alter table public.growth_delivery_state_events_v110 enable row level security;

revoke all privileges on table
  public.growth_delivery_dispatches_v110,
  public.growth_delivery_state_events_v110
from public, anon, authenticated;

create policy growth_delivery_dispatches_v110_finance_read
  on public.growth_delivery_dispatches_v110 for select to authenticated
  using (
    app.is_super_admin()
    or (
      app.has_perm(business_id, 'view_finance')
      and app.can_module_read(business_id, 'retention')
      and app.can_see_branch(business_id, branch_id)
    )
  );

create policy growth_delivery_state_events_v110_finance_read
  on public.growth_delivery_state_events_v110 for select to authenticated
  using (
    app.is_super_admin()
    or exists (
      select 1
      from public.growth_executions_v108 execution_row
      where execution_row.id = growth_delivery_state_events_v110.execution_id
        and execution_row.business_id =
          growth_delivery_state_events_v110.business_id
        and app.has_perm(execution_row.business_id, 'view_finance')
        and app.can_module_read(execution_row.business_id, 'retention')
        and app.can_see_branch(
          execution_row.business_id, execution_row.branch_id
        )
    )
  );

create or replace function app.v110_request_hash(p_value jsonb)
returns text
language sql
immutable
strict
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
  select encode(
    extensions.digest(convert_to(p_value::text, 'UTF8'), 'sha256'),
    'hex'
  )
$$;

create or replace function app.v110_next_allowed_at(
  p_timezone text,
  p_quiet_start time,
  p_quiet_end time,
  p_from timestamptz default statement_timestamp()
)
returns timestamptz
language plpgsql
stable
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_candidate timestamptz := p_from;
  v_step integer;
begin
  if not app.c46_in_quiet_hours(
    p_timezone, p_quiet_start, p_quiet_end, p_from
  ) then
    return p_from;
  end if;
  for v_step in 1..288 loop
    v_candidate := p_from + make_interval(mins => v_step * 5);
    if not app.c46_in_quiet_hours(
      p_timezone, p_quiet_start, p_quiet_end, v_candidate
    ) then
      return v_candidate;
    end if;
  end loop;
  return p_from + interval '24 hours';
end $$;

create or replace function app.v110_prepare_delivery_insert()
returns trigger
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_execution public.growth_executions_v108%rowtype;
begin
  if new.assignment = 'treatment'
     and (
       new.delivery_status = 'delivered'
       or (
         new.delivery_status = 'suppressed'
         and new.suppression_reason = 'quiet_hours'
       )
     ) then
    select * into strict v_execution
    from public.growth_executions_v108
    where id = new.execution_id and business_id = new.business_id;
    new.delivery_status := case
      when new.suppression_reason = 'quiet_hours' then 'scheduled'
      else 'queued'
    end;
    new.suppression_reason := null;
    new.title := v_execution.governed_copy ->> 'title';
    new.body := v_execution.governed_copy ->> 'body';
    new.estimated_cost_cents := v_execution.offer_value_cents;
    new.delivered_at := null;
  end if;
  return new;
end $$;

create or replace function app.v110_guard_delivery_update()
returns trigger
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
begin
  if tg_op = 'DELETE' then
    raise exception 'growth deliveries cannot be deleted' using errcode = '23000';
  end if;
  if current_setting('app.growth_delivery_v110_transition', true)
       is distinct from 'on' then
    raise exception 'growth delivery transitions require the lifecycle service'
      using errcode = '42501';
  end if;
  if new.id is distinct from old.id
     or new.execution_id is distinct from old.execution_id
     or new.execution_member_id is distinct from old.execution_member_id
     or new.business_id is distinct from old.business_id
     or new.client_id is distinct from old.client_id
     or new.identity_id is distinct from old.identity_id
     or new.link_id is distinct from old.link_id
     or new.assignment is distinct from old.assignment
     or new.channel is distinct from old.channel
     or new.title is distinct from old.title
     or new.body is distinct from old.body
     or new.estimated_cost_cents is distinct from old.estimated_cost_cents
     or new.created_at is distinct from old.created_at then
    raise exception 'growth delivery identity and governed content are immutable'
      using errcode = '23000';
  end if;
  if not (
    (old.delivery_status in ('queued', 'scheduled')
      and new.delivery_status in (
        'queued', 'scheduled', 'delivering', 'cancelled'
      ))
    or (old.delivery_status = 'delivering'
      and new.delivery_status in ('delivering', 'delivered', 'failed', 'cancelled'))
    or (old.delivery_status = 'failed'
      and new.delivery_status in ('failed', 'queued', 'cancelled'))
    or old.delivery_status = new.delivery_status
  ) then
    raise exception 'invalid growth delivery transition: % -> %',
      old.delivery_status, new.delivery_status using errcode = '22023';
  end if;
  return new;
end $$;

create or replace function app.v110_guard_dispatch_update()
returns trigger
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
begin
  if tg_op = 'DELETE' then
    raise exception 'growth dispatches cannot be deleted' using errcode = '23000';
  end if;
  if current_setting('app.growth_delivery_v110_transition', true)
       is distinct from 'on' then
    raise exception 'growth dispatch transitions require the lifecycle service'
      using errcode = '42501';
  end if;
  if new.id is distinct from old.id
     or new.delivery_id is distinct from old.delivery_id
     or new.execution_id is distinct from old.execution_id
     or new.business_id is distinct from old.business_id
     or new.branch_id is distinct from old.branch_id
     or new.provider is distinct from old.provider
     or new.created_at is distinct from old.created_at then
    raise exception 'growth dispatch identity is immutable' using errcode = '23000';
  end if;
  return new;
end $$;

drop trigger growth_deliveries_v108_immutable
  on public.growth_deliveries_v108;

create trigger growth_deliveries_v110_prepare
  before insert on public.growth_deliveries_v108
  for each row execute function app.v110_prepare_delivery_insert();

create trigger growth_deliveries_v110_guard
  before update or delete on public.growth_deliveries_v108
  for each row execute function app.v110_guard_delivery_update();

create trigger growth_delivery_dispatches_v110_guard
  before update or delete on public.growth_delivery_dispatches_v110
  for each row execute function app.v110_guard_dispatch_update();

create trigger growth_delivery_state_events_v110_immutable
  before update or delete on public.growth_delivery_state_events_v110
  for each row execute function app.growth_v108_immutable();

create or replace function app.v110_register_delivery()
returns trigger
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_dispatch uuid;
  v_execution public.growth_executions_v108%rowtype;
  v_preference public.customer_notification_preferences%rowtype;
  v_scheduled_for timestamptz := statement_timestamp();
  v_event_key uuid;
  v_hash text;
begin
  select * into strict v_execution
  from public.growth_executions_v108
  where id = new.execution_id and business_id = new.business_id;
  if new.delivery_status = 'scheduled' then
    select * into v_preference
    from public.customer_notification_preferences preference
    where preference.business_id = new.business_id
      and preference.client_id = new.client_id
      and preference.link_id = new.link_id
      and preference.channel = 'in_app'
      and preference.topic = 'marketing'
    order by preference.updated_at desc, preference.id
    limit 1;
    v_scheduled_for := app.v110_next_allowed_at(
      v_preference.quiet_hours_timezone,
      v_preference.quiet_hours_start,
      v_preference.quiet_hours_end,
      statement_timestamp()
    );
  end if;
  insert into public.growth_delivery_dispatches_v110(
    delivery_id, execution_id, business_id, branch_id,
    lifecycle_status, scheduled_for, next_attempt_at
  ) values (
    new.id, new.execution_id, new.business_id, v_execution.branch_id,
    new.delivery_status, v_scheduled_for, v_scheduled_for
  ) returning id into v_dispatch;
  v_event_key := extensions.uuid_generate_v5(new.id, 'v110-created');
  v_hash := app.v110_request_hash(jsonb_build_object(
    'delivery_id', new.id, 'to_status', new.delivery_status,
    'scheduled_for', v_scheduled_for
  ));
  insert into public.growth_delivery_state_events_v110(
    dispatch_id, delivery_id, execution_id, business_id,
    from_status, to_status, reason_code, idempotency_key,
    request_hash, detail
  ) values (
    v_dispatch, new.id, new.execution_id, new.business_id,
    null, new.delivery_status, new.suppression_reason, v_event_key,
    v_hash, jsonb_build_object('scheduled_for', v_scheduled_for)
  );
  return new;
end $$;

create trigger growth_deliveries_v110_register
  after insert on public.growth_deliveries_v108
  for each row execute function app.v110_register_delivery();

-- Preserve evidence for executions approved before v110. These historical rows
-- keep their existing lifecycle status; only new approvals are queued.
insert into public.growth_delivery_dispatches_v110(
  delivery_id, execution_id, business_id, branch_id, lifecycle_status,
  scheduled_for, next_attempt_at, attempt_count, claimed_by, claimed_at,
  provider_message_id, delivered_at, failure_code, cancelled_at,
  created_at, updated_at
)
select delivery.id, delivery.execution_id, delivery.business_id,
  execution_row.branch_id, delivery.delivery_status,
  coalesce(delivery.delivered_at, delivery.created_at),
  coalesce(delivery.delivered_at, delivery.created_at),
  delivery.retry_count,
  case when delivery.delivery_status in ('delivered', 'failed')
    then 'v108-historical' else null end,
  case when delivery.delivery_status in ('delivered', 'failed')
    then delivery.created_at else null end,
  delivery.provider_message_id, delivery.delivered_at,
  case
    when delivery.delivery_status in ('failed', 'cancelled')
      then coalesce(delivery.suppression_reason, 'provider_failure')
    else null
  end,
  case when delivery.delivery_status = 'cancelled'
    then delivery.created_at else null end,
  delivery.created_at, delivery.created_at
from public.growth_deliveries_v108 delivery
join public.growth_executions_v108 execution_row
  on execution_row.id = delivery.execution_id
 and execution_row.business_id = delivery.business_id
on conflict (delivery_id) do nothing;

insert into public.growth_delivery_state_events_v110(
  dispatch_id, delivery_id, execution_id, business_id,
  from_status, to_status, reason_code, provider_message_id,
  idempotency_key, request_hash, detail, occurred_at
)
select dispatch.id, dispatch.delivery_id, dispatch.execution_id,
  dispatch.business_id, null, dispatch.lifecycle_status,
  delivery.suppression_reason, dispatch.provider_message_id,
  extensions.uuid_generate_v5(dispatch.delivery_id, 'v110-backfill'),
  app.v110_request_hash(jsonb_build_object(
    'delivery_id', dispatch.delivery_id,
    'to_status', dispatch.lifecycle_status,
    'historical', true
  )),
  jsonb_build_object('historical_v108', true), dispatch.created_at
from public.growth_delivery_dispatches_v110 dispatch
join public.growth_deliveries_v108 delivery
  on delivery.id = dispatch.delivery_id
where not exists (
  select 1 from public.growth_delivery_state_events_v110 event_row
  where event_row.dispatch_id = dispatch.id
);

create or replace function app.v110_transition_delivery(
  p_dispatch uuid,
  p_to_status text,
  p_reason_code text,
  p_provider_message_id text,
  p_idempotency_key uuid,
  p_detail jsonb default '{}'::jsonb
)
returns public.growth_delivery_dispatches_v110
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_dispatch public.growth_delivery_dispatches_v110%rowtype;
  v_existing public.growth_delivery_state_events_v110%rowtype;
  v_hash text;
  v_from_status text;
  v_now timestamptz := statement_timestamp();
begin
  if p_idempotency_key is null
     or jsonb_typeof(coalesce(p_detail, '{}'::jsonb)) <> 'object' then
    raise exception 'valid transition idempotency and detail are required'
      using errcode = '22023';
  end if;
  v_hash := app.v110_request_hash(jsonb_build_object(
    'dispatch_id', p_dispatch, 'to_status', p_to_status,
    'reason_code', p_reason_code,
    'provider_message_id', p_provider_message_id,
    'detail', coalesce(p_detail, '{}'::jsonb)
  ));
  select * into v_existing
  from public.growth_delivery_state_events_v110
  where dispatch_id = p_dispatch and idempotency_key = p_idempotency_key;
  if found then
    if v_existing.request_hash <> v_hash then
      raise exception 'idempotency key reused with a different delivery transition'
        using errcode = '23505';
    end if;
    select * into strict v_dispatch
    from public.growth_delivery_dispatches_v110 where id = p_dispatch;
    return v_dispatch;
  end if;
  select * into strict v_dispatch
  from public.growth_delivery_dispatches_v110
  where id = p_dispatch for update;
  v_from_status := v_dispatch.lifecycle_status;
  if not (
    (v_from_status in ('queued', 'scheduled')
      and p_to_status in ('queued', 'scheduled', 'delivering', 'cancelled'))
    or (v_from_status = 'delivering'
      and p_to_status in ('delivering', 'delivered', 'failed', 'cancelled'))
    or (v_from_status = 'failed'
      and p_to_status in ('failed', 'queued', 'cancelled'))
    or v_from_status = p_to_status
  ) then
    raise exception 'invalid growth dispatch transition: % -> %',
      v_from_status, p_to_status using errcode = '22023';
  end if;
  perform set_config('app.growth_delivery_v110_transition', 'on', true);
  update public.growth_delivery_dispatches_v110
  set lifecycle_status = p_to_status,
      claimed_by = case
        when p_to_status in ('queued', 'scheduled') then null
        else coalesce(claimed_by, p_detail ->> 'worker_id')
      end,
      claimed_at = case
        when p_to_status in ('queued', 'scheduled') then null
        else coalesce(claimed_at, v_now)
      end,
      provider_message_id = case when p_to_status = 'delivered'
        then p_provider_message_id else provider_message_id end,
      delivered_at = case when p_to_status = 'delivered' then v_now else null end,
      failure_code = case
        when p_to_status in ('failed', 'cancelled') then p_reason_code
        when p_to_status in ('queued', 'scheduled', 'delivering', 'delivered')
          then null
        else failure_code
      end,
      cancelled_at = case when p_to_status = 'cancelled' then v_now else null end,
      attempt_count = case when p_to_status = 'delivering'
        and lifecycle_status <> 'delivering' then attempt_count + 1
        else attempt_count end,
      next_attempt_at = case when p_to_status = 'queued'
        then v_now else next_attempt_at end,
      updated_at = v_now
  where id = p_dispatch
  returning * into v_dispatch;
  update public.growth_deliveries_v108
  set delivery_status = p_to_status,
      suppression_reason = case
        when p_to_status = 'failed' then 'provider_failure'
        when p_to_status = 'cancelled' then coalesce(p_reason_code, 'owner_cancelled')
        else null
      end,
      provider_message_id = case when p_to_status = 'delivered'
        then p_provider_message_id else provider_message_id end,
      delivered_at = case when p_to_status = 'delivered' then v_now else null end,
      retry_count = v_dispatch.attempt_count
  where id = v_dispatch.delivery_id;
  insert into public.growth_delivery_state_events_v110(
    dispatch_id, delivery_id, execution_id, business_id,
    from_status, to_status, reason_code, provider_message_id,
    actor, idempotency_key, request_hash, detail
  ) values (
    v_dispatch.id, v_dispatch.delivery_id, v_dispatch.execution_id,
    v_dispatch.business_id, v_from_status, p_to_status,
    p_reason_code, p_provider_message_id, auth.uid(),
    p_idempotency_key, v_hash, coalesce(p_detail, '{}'::jsonb)
  );
  return v_dispatch;
end $$;

create or replace function public.service_claim_growth_deliveries_v110(
  p_limit integer default 25,
  p_worker_id text default 'growth-dispatcher',
  p_idempotency_key uuid default gen_random_uuid()
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_dispatch public.growth_delivery_dispatches_v110%rowtype;
  v_delivery public.growth_deliveries_v108%rowtype;
  v_execution public.growth_executions_v108%rowtype;
  v_preference public.customer_notification_preferences%rowtype;
  v_claims jsonb := '[]'::jsonb;
  v_reason text;
  v_spend bigint;
  v_event_key uuid;
begin
  if coalesce(auth.jwt() ->> 'role', '') <> 'service_role' then
    raise exception 'service role required' using errcode = '42501';
  end if;
  if coalesce(p_limit, 0) not between 1 and 100
     or length(btrim(coalesce(p_worker_id, ''))) not between 2 and 120
     or p_idempotency_key is null then
    raise exception 'valid claim limit, worker and idempotency are required'
      using errcode = '22023';
  end if;
  for v_dispatch in
    select dispatch.*
    from public.growth_delivery_dispatches_v110 dispatch
    where dispatch.lifecycle_status in ('queued', 'scheduled')
      and dispatch.scheduled_for <= statement_timestamp()
      and dispatch.next_attempt_at <= statement_timestamp()
    order by dispatch.scheduled_for, dispatch.created_at, dispatch.id
    for update skip locked
    limit p_limit
  loop
    perform pg_advisory_xact_lock(
      hashtextextended('v110-dispatch:' || v_dispatch.execution_id::text, 0)
    );
    select * into strict v_delivery
    from public.growth_deliveries_v108
    where id = v_dispatch.delivery_id for update;
    select * into strict v_execution
    from public.growth_executions_v108
    where id = v_dispatch.execution_id
      and business_id = v_dispatch.business_id for update;
    select * into v_preference
    from public.customer_notification_preferences preference
    where preference.business_id = v_delivery.business_id
      and preference.client_id = v_delivery.client_id
      and preference.link_id = v_delivery.link_id
      and preference.channel = 'in_app'
      and preference.topic = 'marketing'
    order by preference.updated_at desc, preference.id
    limit 1;
    v_reason := null;
    if not app.platform_feature_enabled('growth_closed_loop_v108') then
      v_reason := 'feature_disabled';
    elsif not exists (
      select 1 from public.businesses business
      where business.id = v_dispatch.business_id
        and 'retention' = any(coalesce(business.enabled_modules, '{}'::text[]))
    ) then
      v_reason := 'module_disabled';
    elsif v_execution.status <> 'running'
       or v_execution.ends_at <= statement_timestamp() then
      v_reason := 'execution_expired';
    elsif not exists (
      select 1 from public.customer_links link
      where link.id = v_delivery.link_id
        and link.business_id = v_delivery.business_id
        and link.client_id = v_delivery.client_id
        and link.identity_id = v_delivery.identity_id
        and link.state = 'verified'
    ) then
      v_reason := 'link_unavailable';
    elsif v_preference.opted_in is distinct from true then
      v_reason := 'consent_withdrawn';
    elsif app.c46_in_quiet_hours(
      v_preference.quiet_hours_timezone,
      v_preference.quiet_hours_start,
      v_preference.quiet_hours_end,
      statement_timestamp()
    ) then
      perform set_config('app.growth_delivery_v110_transition', 'on', true);
      update public.growth_delivery_dispatches_v110
      set lifecycle_status = 'scheduled',
          scheduled_for = app.v110_next_allowed_at(
            v_preference.quiet_hours_timezone,
            v_preference.quiet_hours_start,
            v_preference.quiet_hours_end,
            statement_timestamp()
          ),
          next_attempt_at = app.v110_next_allowed_at(
            v_preference.quiet_hours_timezone,
            v_preference.quiet_hours_start,
            v_preference.quiet_hours_end,
            statement_timestamp()
          ),
          updated_at = statement_timestamp()
      where id = v_dispatch.id;
      update public.growth_deliveries_v108
      set delivery_status = 'scheduled'
      where id = v_delivery.id;
      continue;
    elsif exists (
      select 1
      from public.growth_delivery_dispatches_v110 prior_dispatch
      join public.growth_deliveries_v108 prior_delivery
        on prior_delivery.id = prior_dispatch.delivery_id
      where prior_delivery.business_id = v_delivery.business_id
        and prior_delivery.client_id = v_delivery.client_id
        and prior_dispatch.lifecycle_status = 'delivered'
        and prior_dispatch.delivered_at >= statement_timestamp()
          - make_interval(days => (
              select frequency_cap_days
              from public.growth_recommendations_v108 recommendation
              where recommendation.id = v_execution.recommendation_id
            ))
    ) then
      v_reason := 'frequency_cap';
    end if;
    select coalesce(sum(delivery.estimated_cost_cents), 0)
    into v_spend
    from public.growth_delivery_dispatches_v110 dispatch
    join public.growth_deliveries_v108 delivery
      on delivery.id = dispatch.delivery_id
    where dispatch.execution_id = v_execution.id
      and dispatch.lifecycle_status in ('delivering', 'delivered');
    if v_reason is null
       and v_spend + v_delivery.estimated_cost_cents >
         v_execution.budget_cap_cents then
      v_reason := 'budget_cap';
    end if;
    v_event_key := extensions.uuid_generate_v5(
      p_idempotency_key, v_dispatch.id::text || ':claim'
    );
    if v_reason is not null then
      perform app.v110_transition_delivery(
        v_dispatch.id, 'cancelled', v_reason, null, v_event_key,
        jsonb_build_object('worker_id', p_worker_id, 'gate_recheck', true)
      );
      continue;
    end if;
    v_dispatch := app.v110_transition_delivery(
      v_dispatch.id, 'delivering', null, null, v_event_key,
      jsonb_build_object('worker_id', p_worker_id, 'gate_recheck', true)
    );
    v_claims := v_claims || jsonb_build_array(jsonb_build_object(
      'dispatch_id', v_dispatch.id,
      'delivery_id', v_dispatch.delivery_id,
      'execution_id', v_execution.id,
      'business_id', v_execution.business_id,
      'branch_id', v_execution.branch_id,
      'provider', v_dispatch.provider,
      'identity_id', v_delivery.identity_id,
      'governed_copy', v_execution.governed_copy,
      'attempt', v_dispatch.attempt_count
    ));
  end loop;
  return jsonb_build_object(
    'contract_version', 'growth_delivery_lifecycle_v110',
    'claims', v_claims,
    'claimed_count', jsonb_array_length(v_claims)
  );
end $$;

create or replace function public.service_complete_growth_delivery_v110(
  p_dispatch uuid,
  p_provider_message_id text,
  p_succeeded boolean,
  p_error_code text,
  p_idempotency_key uuid
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_dispatch public.growth_delivery_dispatches_v110%rowtype;
  v_delivery public.growth_deliveries_v108%rowtype;
  v_execution public.growth_executions_v108%rowtype;
  v_entitlement public.growth_entitlements_v108%rowtype;
begin
  if coalesce(auth.jwt() ->> 'role', '') <> 'service_role' then
    raise exception 'service role required' using errcode = '42501';
  end if;
  if p_dispatch is null or p_succeeded is null or p_idempotency_key is null then
    raise exception 'dispatch result and idempotency are required'
      using errcode = '22023';
  end if;
  select * into strict v_dispatch
  from public.growth_delivery_dispatches_v110
  where id = p_dispatch for update;
  select * into strict v_delivery
  from public.growth_deliveries_v108
  where id = v_dispatch.delivery_id for update;
  select * into strict v_execution
  from public.growth_executions_v108
  where id = v_dispatch.execution_id
    and business_id = v_dispatch.business_id;
  if p_succeeded then
    if length(btrim(coalesce(p_provider_message_id, ''))) < 3 then
      raise exception 'verified provider message id is required'
        using errcode = '22023';
    end if;
    v_dispatch := app.v110_transition_delivery(
      p_dispatch, 'delivered', null, btrim(p_provider_message_id),
      p_idempotency_key, jsonb_build_object('callback_verified', true)
    );
    insert into public.growth_entitlements_v108(
      delivery_id, execution_id, business_id, client_id, identity_id,
      entitlement_type, value_cents, estimated_cost_cents, expires_at
    ) values (
      v_delivery.id, v_execution.id, v_execution.business_id,
      v_delivery.client_id, v_delivery.identity_id,
      'credit_cents', v_execution.offer_value_cents,
      v_execution.offer_value_cents,
      least(statement_timestamp() + interval '7 days', v_execution.ends_at)
    )
    on conflict (delivery_id) do nothing
    returning * into v_entitlement;
    if v_entitlement.id is null then
      select * into strict v_entitlement
      from public.growth_entitlements_v108
      where delivery_id = v_delivery.id;
    end if;
    insert into public.growth_entitlement_events_v108(
      entitlement_id, business_id, event_type, actor,
      idempotency_key, detail
    ) values (
      v_entitlement.id, v_entitlement.business_id, 'issued', null,
      extensions.uuid_generate_v5(p_idempotency_key, 'entitlement-issued'),
      jsonb_build_object(
        'execution_id', v_execution.id,
        'delivery_id', v_delivery.id,
        'provider_message_id', btrim(p_provider_message_id),
        'value_cents', v_entitlement.value_cents
      )
    ) on conflict do nothing;
  else
    if length(btrim(coalesce(p_error_code, ''))) < 2 then
      raise exception 'provider error code is required' using errcode = '22023';
    end if;
    v_dispatch := app.v110_transition_delivery(
      p_dispatch, 'failed', btrim(p_error_code), null,
      p_idempotency_key, jsonb_build_object('callback_verified', true)
    );
  end if;
  return jsonb_build_object(
    'dispatch_id', v_dispatch.id,
    'delivery_id', v_dispatch.delivery_id,
    'status', v_dispatch.lifecycle_status,
    'entitlement_id', v_entitlement.id,
    'replayed', exists (
      select 1 from public.growth_delivery_state_events_v110 event_row
      where event_row.dispatch_id = p_dispatch
        and event_row.idempotency_key = p_idempotency_key
        and event_row.occurred_at < statement_timestamp()
    )
  );
end $$;

create or replace function public.cancel_growth_delivery_v110(
  p_business uuid,
  p_dispatch uuid,
  p_reason text,
  p_idempotency_key uuid
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_dispatch public.growth_delivery_dispatches_v110%rowtype;
begin
  if not app.is_salon_owner(p_business)
     or not app.can_module_write(p_business, 'retention') then
    raise exception 'owner retention access required' using errcode = '42501';
  end if;
  select * into strict v_dispatch
  from public.growth_delivery_dispatches_v110
  where id = p_dispatch and business_id = p_business for update;
  if not app.can_see_branch(v_dispatch.business_id, v_dispatch.branch_id) then
    raise exception 'delivery branch is outside actor scope' using errcode = '42501';
  end if;
  if length(btrim(coalesce(p_reason, ''))) not between 2 and 500 then
    raise exception 'cancellation reason is required' using errcode = '22023';
  end if;
  v_dispatch := app.v110_transition_delivery(
    p_dispatch, 'cancelled', 'owner_cancelled', null, p_idempotency_key,
    jsonb_build_object('owner_reason', btrim(p_reason))
  );
  return jsonb_build_object(
    'dispatch_id', v_dispatch.id,
    'status', v_dispatch.lifecycle_status
  );
end $$;

create or replace function public.retry_growth_delivery_v110(
  p_business uuid,
  p_dispatch uuid,
  p_idempotency_key uuid
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_dispatch public.growth_delivery_dispatches_v110%rowtype;
begin
  if not app.is_salon_owner(p_business)
     or not app.can_module_write(p_business, 'retention') then
    raise exception 'owner retention access required' using errcode = '42501';
  end if;
  select * into strict v_dispatch
  from public.growth_delivery_dispatches_v110
  where id = p_dispatch and business_id = p_business for update;
  if not app.can_see_branch(v_dispatch.business_id, v_dispatch.branch_id) then
    raise exception 'delivery branch is outside actor scope' using errcode = '42501';
  end if;
  if v_dispatch.lifecycle_status <> 'failed' or v_dispatch.attempt_count >= 5 then
    raise exception 'only failed deliveries below retry limit can be retried'
      using errcode = '22023';
  end if;
  v_dispatch := app.v110_transition_delivery(
    p_dispatch, 'queued', null, null, p_idempotency_key,
    jsonb_build_object('owner_retry', true)
  );
  return jsonb_build_object(
    'dispatch_id', v_dispatch.id,
    'status', v_dispatch.lifecycle_status,
    'attempt_count', v_dispatch.attempt_count
  );
end $$;

create or replace function public.get_growth_delivery_status_v110(
  p_business uuid,
  p_execution uuid
)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_execution public.growth_executions_v108%rowtype;
begin
  if auth.uid() is null or (
    not app.is_super_admin()
    and (
      not app.has_perm(p_business, 'view_finance')
      or not app.can_module_read(p_business, 'retention')
    )
  ) then
    raise exception 'finance and retention access required' using errcode = '42501';
  end if;
  select * into strict v_execution
  from public.growth_executions_v108
  where id = p_execution and business_id = p_business;
  if not app.can_see_branch(v_execution.business_id, v_execution.branch_id) then
    raise exception 'execution branch is outside actor scope' using errcode = '42501';
  end if;
  return jsonb_build_object(
    'contract_version', 'growth_delivery_lifecycle_v110',
    'execution_id', v_execution.id,
    'business_id', v_execution.business_id,
    'branch_id', v_execution.branch_id,
    'counts', (
      select coalesce(jsonb_object_agg(status_rows.lifecycle_status, status_rows.n), '{}'::jsonb)
      from (
        select dispatch.lifecycle_status, count(*) as n
        from public.growth_delivery_dispatches_v110 dispatch
        where dispatch.execution_id = p_execution
        group by dispatch.lifecycle_status
      ) status_rows
    ),
    'deliveries', coalesce((
      select jsonb_agg(jsonb_build_object(
        'dispatch_id', dispatch.id,
        'delivery_id', dispatch.delivery_id,
        'status', dispatch.lifecycle_status,
        'provider', dispatch.provider,
        'scheduled_for', dispatch.scheduled_for,
        'attempt_count', dispatch.attempt_count,
        'delivered_at', dispatch.delivered_at,
        'failure_code', dispatch.failure_code,
        'cancelled_at', dispatch.cancelled_at,
        'updated_at', dispatch.updated_at
      ) order by dispatch.created_at, dispatch.id)
      from public.growth_delivery_dispatches_v110 dispatch
      where dispatch.execution_id = p_execution
    ), '[]'::jsonb)
  );
end $$;

revoke all privileges on function
  app.v110_request_hash(jsonb),
  app.v110_next_allowed_at(text,time,time,timestamptz),
  app.v110_prepare_delivery_insert(),
  app.v110_guard_delivery_update(),
  app.v110_guard_dispatch_update(),
  app.v110_register_delivery(),
  app.v110_transition_delivery(uuid,text,text,text,uuid,jsonb)
from public, anon, authenticated;

revoke all on function
  public.service_claim_growth_deliveries_v110(integer,text,uuid)
from public, anon, authenticated;

revoke all on function
  public.service_complete_growth_delivery_v110(uuid,text,boolean,text,uuid)
from public, anon, authenticated;

grant execute on function
  public.service_claim_growth_deliveries_v110(integer,text,uuid),
  public.service_complete_growth_delivery_v110(uuid,text,boolean,text,uuid)
to service_role;

revoke all on function
  public.cancel_growth_delivery_v110(uuid,uuid,text,uuid)
from public, anon;

revoke all on function
  public.retry_growth_delivery_v110(uuid,uuid,uuid)
from public, anon;

revoke all on function
  public.get_growth_delivery_status_v110(uuid,uuid)
from public, anon;

grant execute on function
  public.cancel_growth_delivery_v110(uuid,uuid,text,uuid),
  public.retry_growth_delivery_v110(uuid,uuid,uuid),
  public.get_growth_delivery_status_v110(uuid,uuid)
to authenticated;

comment on table public.growth_delivery_dispatches_v110 is
  'Provider-neutral queued delivery lifecycle. Entitlements issue only after a verified delivered callback.';
comment on function public.service_claim_growth_deliveries_v110(
  integer,text,uuid
) is
  'Service-only SKIP LOCKED claim with feature, module, execution, consent, quiet-hours, frequency and budget rechecks.';

commit;
