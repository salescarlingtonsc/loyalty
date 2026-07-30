-- NESTLY v112 — CONCURRENT REPLAY + DETERMINISTIC DELIVERY BACKOFF
--
-- Forward-only closure increment for:
--   * canonical source/idempotency serialization during v106 ingestion;
--   * exact receipt replay behind deterministic request + record locks for the
--     v108/v109/v110 mutations identified by the independent review; and
--   * an append-only, versioned retry schedule for failed growth delivery.

begin;

create table public.concurrent_operation_receipts_v112 (
  request_identity text primary key
    check (request_identity ~ '^[0-9a-f]{64}$'),
  operation text not null
    check (operation ~ '^[a-z][a-z0-9_]{2,79}$'),
  request_hash text not null
    check (request_hash ~ '^[0-9a-f]{64}$'),
  scope jsonb not null default '{}'::jsonb
    check (jsonb_typeof(scope) = 'object'),
  receipt jsonb not null
    check (jsonb_typeof(receipt) = 'object'),
  created_at timestamptz not null default clock_timestamp()
);

create table public.growth_delivery_backoff_policies_v112 (
  version_no integer primary key check (version_no > 0),
  max_attempts integer not null check (max_attempts between 2 and 20),
  delays_seconds integer[] not null,
  effective_from timestamptz not null,
  policy_hash text not null unique
    check (policy_hash ~ '^[0-9a-f]{64}$'),
  created_at timestamptz not null default clock_timestamp(),
  constraint growth_delivery_backoff_policies_v112_shape_check check (
    cardinality(delays_seconds) = max_attempts - 1
    and array_position(delays_seconds, null) is null
    and 0 < all(delays_seconds)
  )
);

insert into public.growth_delivery_backoff_policies_v112(
  version_no, max_attempts, delays_seconds, effective_from, policy_hash
) values (
  1,
  5,
  array[60, 300, 900, 3600]::integer[],
  '-infinity'::timestamptz,
  encode(
    extensions.digest(
      convert_to(
        jsonb_build_object(
          'version_no', 1,
          'max_attempts', 5,
          'delays_seconds', array[60, 300, 900, 3600]::integer[]
        )::text,
        'UTF8'
      ),
      'sha256'
    ),
    'hex'
  )
);

create or replace function app.v112_immutable()
returns trigger
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
begin
  raise exception '% is append-only', tg_table_name using errcode = '23000';
end $$;

create trigger concurrent_operation_receipts_v112_immutable
  before update or delete on public.concurrent_operation_receipts_v112
  for each row execute function app.v112_immutable();

create trigger growth_delivery_backoff_policies_v112_immutable
  before update or delete on public.growth_delivery_backoff_policies_v112
  for each row execute function app.v112_immutable();

alter table public.concurrent_operation_receipts_v112 enable row level security;
alter table public.growth_delivery_backoff_policies_v112 enable row level security;

revoke all on table
  public.concurrent_operation_receipts_v112,
  public.growth_delivery_backoff_policies_v112
from public, anon, authenticated;

create policy growth_delivery_backoff_policies_v112_authenticated_read
  on public.growth_delivery_backoff_policies_v112
  for select to authenticated
  using (true);

grant select on table public.growth_delivery_backoff_policies_v112
to authenticated;

create or replace function app.v112_hash(p_value jsonb)
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

create or replace function app.v112_lock_pair(
  p_first text,
  p_second text
)
returns void
language plpgsql
volatile
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_first text := least(p_first, p_second);
  v_second text := greatest(p_first, p_second);
begin
  if nullif(v_first, '') is null or nullif(v_second, '') is null then
    raise exception 'two non-empty lock identities are required'
      using errcode = '22023';
  end if;
  perform pg_advisory_xact_lock(hashtextextended(v_first, 112));
  if v_second <> v_first then
    perform pg_advisory_xact_lock(hashtextextended(v_second, 112));
  end if;
end $$;

create or replace function app.v112_lock_dispatch(
  p_dispatch uuid
)
returns void
language plpgsql
volatile
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
begin
  if p_dispatch is null then
    raise exception 'dispatch identity is required' using errcode = '22023';
  end if;
  perform pg_advisory_xact_lock(
    hashtextextended('v112-v110-dispatch:' || p_dispatch::text, 112)
  );
end $$;

create or replace function app.v112_get_receipt(
  p_request_identity text,
  p_request_hash text
)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_row public.concurrent_operation_receipts_v112%rowtype;
begin
  select * into v_row
  from public.concurrent_operation_receipts_v112
  where request_identity = p_request_identity;
  if not found then
    return null;
  end if;
  if v_row.request_hash <> p_request_hash then
    raise exception 'idempotency key reused with a different request'
      using errcode = '23505';
  end if;
  return v_row.receipt;
end $$;

create or replace function app.v112_put_receipt(
  p_request_identity text,
  p_operation text,
  p_request_hash text,
  p_scope jsonb,
  p_receipt jsonb
)
returns jsonb
language plpgsql
volatile
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
begin
  if p_request_identity !~ '^[0-9a-f]{64}$'
     or p_request_hash !~ '^[0-9a-f]{64}$'
     or p_operation !~ '^[a-z][a-z0-9_]{2,79}$'
     or jsonb_typeof(coalesce(p_scope, '{}'::jsonb)) <> 'object'
     or jsonb_typeof(p_receipt) <> 'object' then
    raise exception 'valid immutable operation receipt is required'
      using errcode = '22023';
  end if;
  insert into public.concurrent_operation_receipts_v112(
    request_identity, operation, request_hash, scope, receipt
  ) values (
    p_request_identity, p_operation, p_request_hash,
    coalesce(p_scope, '{}'::jsonb), p_receipt
  );
  return p_receipt;
end $$;

create or replace function app.v112_delivery_backoff(
  p_completed_attempts integer,
  p_at timestamptz default clock_timestamp()
)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_policy public.growth_delivery_backoff_policies_v112%rowtype;
  v_slot integer;
begin
  select * into strict v_policy
  from public.growth_delivery_backoff_policies_v112
  where effective_from <= p_at
  order by effective_from desc, version_no desc
  limit 1;
  if p_completed_attempts is null
     or p_completed_attempts < 0
     or p_completed_attempts >= v_policy.max_attempts then
    raise exception 'delivery retry limit reached'
      using errcode = '22023';
  end if;
  v_slot := greatest(1, p_completed_attempts);
  return jsonb_build_object(
    'policy_version', v_policy.version_no,
    'policy_hash', v_policy.policy_hash,
    'max_attempts', v_policy.max_attempts,
    'completed_attempts', p_completed_attempts,
    'backoff_slot', v_slot,
    'delay_seconds', v_policy.delays_seconds[v_slot]
  );
end $$;

-- The claim query already refuses work before next_attempt_at.  This database
-- invariant additionally prevents exhausted work from re-entering its queue.
alter table public.growth_delivery_dispatches_v110
  add constraint growth_delivery_dispatches_v112_retry_bound_check check (
    lifecycle_status not in ('queued', 'scheduled')
    or attempt_count < 5
  ) not valid;
alter table public.growth_delivery_dispatches_v110
  validate constraint growth_delivery_dispatches_v112_retry_bound_check;

-- Preserve the reviewed implementations as inaccessible inner functions.  The
-- public names below become the serialization + exact-receipt boundary.
alter function public.ingest_external_commerce_event_v106(
  uuid, uuid, text, text, text, text, timestamptz, text, bigint, jsonb,
  text, uuid, text, text, uuid
) rename to ingest_external_commerce_event_v106_v112_inner;

alter function public.dismiss_growth_recommendation_v108(
  uuid, uuid, text, uuid
) rename to dismiss_growth_recommendation_v108_v112_inner;

alter function public.approve_growth_recommendation_v108(
  uuid, uuid, integer, text, uuid
) rename to approve_growth_recommendation_v108_v112_inner;

alter function public.finalize_growth_execution_v108(
  uuid, uuid, uuid
) rename to finalize_growth_execution_v108_v112_inner;

alter function public.set_effective_cost_rule_v109(
  uuid, uuid, text, text, text, bigint, text, text, jsonb, timestamptz, uuid
) rename to set_effective_cost_rule_v109_v112_inner;

alter function public.set_business_sector_policy_override_v109(
  uuid, text, jsonb, text, timestamptz, uuid
) rename to set_business_sector_policy_override_v109_v112_inner;

alter function app.v110_transition_delivery(
  uuid, text, text, text, uuid, jsonb
) rename to v110_transition_delivery_v112_unsafe_row_inner;

alter function public.service_claim_growth_deliveries_v110(
  integer, text, uuid
) rename to service_claim_growth_deliveries_v110_v112_unsafe_row_inner;

alter function public.service_complete_growth_delivery_v110(
  uuid, text, boolean, text, uuid
) rename to service_complete_growth_delivery_v110_v112_unsafe_row_inner;

alter function public.retry_growth_delivery_v110(
  uuid, uuid, uuid
) rename to retry_growth_delivery_v110_v112_unsafe_row_inner;

alter function public.cancel_growth_delivery_v110(
  uuid, uuid, text, uuid
) rename to cancel_growth_delivery_v110_v112_unsafe_row_inner;

revoke all on function
  public.ingest_external_commerce_event_v106_v112_inner(
    uuid,uuid,text,text,text,text,timestamptz,text,bigint,jsonb,
    text,uuid,text,text,uuid
  ),
  public.dismiss_growth_recommendation_v108_v112_inner(uuid,uuid,text,uuid),
  public.approve_growth_recommendation_v108_v112_inner(
    uuid,uuid,integer,text,uuid
  ),
  public.finalize_growth_execution_v108_v112_inner(uuid,uuid,uuid),
  public.set_effective_cost_rule_v109_v112_inner(
    uuid,uuid,text,text,text,bigint,text,text,jsonb,timestamptz,uuid
  ),
  public.set_business_sector_policy_override_v109_v112_inner(
    uuid,text,jsonb,text,timestamptz,uuid
  ),
  app.v110_transition_delivery_v112_unsafe_row_inner(
    uuid,text,text,text,uuid,jsonb
  ),
  public.service_claim_growth_deliveries_v110_v112_unsafe_row_inner(
    integer,text,uuid
  ),
  public.service_complete_growth_delivery_v110_v112_unsafe_row_inner(
    uuid,text,boolean,text,uuid
  ),
  public.retry_growth_delivery_v110_v112_unsafe_row_inner(uuid,uuid,uuid),
  public.cancel_growth_delivery_v110_v112_unsafe_row_inner(
    uuid,uuid,text,uuid
  )
from public, anon, authenticated, service_role;

-- Every dispatch mutation now enters through a safe inner boundary that owns
-- the dispatch advisory lock before any implementation can lock the row.
create or replace function app.v110_transition_delivery_v112_inner(
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
begin
  perform app.v112_lock_dispatch(p_dispatch);
  return app.v110_transition_delivery_v112_unsafe_row_inner(
    p_dispatch, p_to_status, p_reason_code, p_provider_message_id,
    p_idempotency_key, p_detail
  );
end $$;

create or replace function public.service_claim_growth_deliveries_v110_v112_inner(
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
  v_candidate record;
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
  for v_candidate in
    select dispatch.id, dispatch.execution_id
    from public.growth_delivery_dispatches_v110 dispatch
    where dispatch.lifecycle_status in ('queued', 'scheduled')
      and dispatch.scheduled_for <= statement_timestamp()
      and dispatch.next_attempt_at <= statement_timestamp()
    order by dispatch.scheduled_for, dispatch.created_at, dispatch.id
    limit p_limit
  loop
    -- Preserve v110's execution-level budget serialization, but acquire it
    -- before the shared dispatch advisory and dispatch row locks.
    perform pg_advisory_xact_lock(
      hashtextextended('v110-dispatch:' || v_candidate.execution_id::text, 0)
    );
    perform app.v112_lock_dispatch(v_candidate.id);
    select * into v_dispatch
    from public.growth_delivery_dispatches_v110
    where id = v_candidate.id
      and lifecycle_status in ('queued', 'scheduled')
      and scheduled_for <= statement_timestamp()
      and next_attempt_at <= statement_timestamp()
    for update;
    if not found then
      continue;
    end if;
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

create or replace function public.service_complete_growth_delivery_v110_v112_inner(
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
  v_suppression_reason text;
  v_now timestamptz := statement_timestamp();
begin
  perform app.v112_lock_dispatch(p_dispatch);
  if p_succeeded then
    if length(btrim(coalesce(p_provider_message_id, ''))) < 3 then
      raise exception 'verified provider message id is required'
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

    if not app.platform_feature_enabled('growth_closed_loop_v108') then
      v_suppression_reason := 'feature_disabled';
    elsif not exists (
      select 1 from public.businesses business
      where business.id = v_dispatch.business_id
        and 'retention' = any(coalesce(business.enabled_modules, '{}'::text[]))
    ) then
      v_suppression_reason := 'module_disabled';
    elsif v_execution.status <> 'running' then
      v_suppression_reason := 'execution_cancelled';
    elsif v_execution.ends_at <= v_now then
      v_suppression_reason := 'execution_expired';
    elsif v_dispatch.branch_id is not null and not exists (
      select 1 from public.branches branch
      where branch.id = v_dispatch.branch_id
        and branch.business_id = v_dispatch.business_id
        and branch.active
    ) then
      v_suppression_reason := 'branch_unavailable';
    elsif not exists (
      select 1 from public.customer_links link
      where link.id = v_delivery.link_id
        and link.business_id = v_delivery.business_id
        and link.client_id = v_delivery.client_id
        and link.identity_id = v_delivery.identity_id
        and link.state = 'verified'
    ) then
      v_suppression_reason := 'link_unavailable';
    elsif not exists (
      select 1
      from public.customer_notification_preferences preference
      where preference.business_id = v_delivery.business_id
        and preference.client_id = v_delivery.client_id
        and preference.link_id = v_delivery.link_id
        and preference.channel = 'in_app'
        and preference.topic = 'marketing'
        and preference.opted_in
    ) then
      v_suppression_reason := 'consent_withdrawn';
    end if;

    if v_suppression_reason is not null then
      v_dispatch := app.v110_transition_delivery(
        p_dispatch, 'delivered', v_suppression_reason,
        btrim(p_provider_message_id), p_idempotency_key,
        jsonb_build_object(
          'callback_verified', true,
          'entitlement_suppressed', true,
          'suppression_reason', v_suppression_reason,
          'eligibility_rechecked_at', v_now
        )
      );
      return jsonb_build_object(
        'dispatch_id', v_dispatch.id,
        'delivery_id', v_dispatch.delivery_id,
        'status', v_dispatch.lifecycle_status,
        'entitlement_id', null,
        'entitlement_suppressed', true,
        'suppression_reason', v_suppression_reason,
        'replayed', false
      );
    end if;
  end if;
  return public.service_complete_growth_delivery_v110_v112_unsafe_row_inner(
    p_dispatch, p_provider_message_id, p_succeeded, p_error_code,
    p_idempotency_key
  );
end $$;

create or replace function public.retry_growth_delivery_v110_v112_inner(
  p_business uuid,
  p_dispatch uuid,
  p_idempotency_key uuid
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
begin
  perform app.v112_lock_dispatch(p_dispatch);
  return public.retry_growth_delivery_v110_v112_unsafe_row_inner(
    p_business, p_dispatch, p_idempotency_key
  );
end $$;

create or replace function public.cancel_growth_delivery_v110_v112_inner(
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
begin
  perform app.v112_lock_dispatch(p_dispatch);
  return public.cancel_growth_delivery_v110_v112_unsafe_row_inner(
    p_business, p_dispatch, p_reason, p_idempotency_key
  );
end $$;

revoke all on function app.v110_transition_delivery_v112_inner(
  uuid,text,text,text,uuid,jsonb
) from public, anon, authenticated, service_role;

revoke all on function public.service_claim_growth_deliveries_v110_v112_inner(
  integer,text,uuid
) from public, anon, authenticated, service_role;

revoke all on function public.service_complete_growth_delivery_v110_v112_inner(
  uuid,text,boolean,text,uuid
) from public, anon, authenticated, service_role;

revoke all on function public.retry_growth_delivery_v110_v112_inner(
  uuid,uuid,uuid
) from public, anon, authenticated, service_role;

revoke all on function public.cancel_growth_delivery_v110_v112_inner(
  uuid,uuid,text,uuid
)
from public, anon, authenticated, service_role;

create or replace function public.ingest_external_commerce_event_v106(
  p_business uuid,
  p_branch uuid,
  p_event_type text,
  p_source_system text,
  p_source_event_id text,
  p_idempotency_key text,
  p_occurred_at timestamptz,
  p_currency text,
  p_amount_minor bigint,
  p_payload jsonb default '{}'::jsonb,
  p_actor_type text default 'integration',
  p_actor_id uuid default null,
  p_causation_id text default null,
  p_correlation_id text default null,
  p_supersedes_event_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_actor uuid := auth.uid();
  v_source_lock text;
  v_request_lock text;
  v_identity text;
  v_hash text;
  v_receipt jsonb;
  v_existing_hash text;
begin
  if v_actor is null then
    raise exception 'authentication required' using errcode = '42501';
  end if;
  if not (
    app.is_super_admin()
    or (
      lower(btrim(p_event_type)) in (
        'refund_completed', 'chargeback_opened', 'chargeback_reversed'
      )
      and app.has_perm(p_business, 'refund_sales')
    )
    or (
      lower(btrim(p_event_type)) in (
        'transaction_completed', 'transaction_voided'
      )
      and app.has_perm(p_business, 'create_sales')
    )
  ) then
    raise exception 'sale-write permission required for this external event'
      using errcode = '42501';
  end if;
  if not app.can_see_branch(p_business, p_branch) then
    raise exception 'branch is outside actor scope' using errcode = '42501';
  end if;
  if p_branch is not null and not exists (
    select 1
    from public.branches b
    where b.id = p_branch and b.business_id = p_business
  ) then
    raise exception 'branch does not belong to business' using errcode = '23503';
  end if;
  v_source_lock := concat_ws(
    ':', 'v112-v106-source', p_business,
    lower(btrim(p_source_system)), btrim(p_source_event_id),
    lower(btrim(p_event_type))
  );
  v_request_lock := concat_ws(
    ':', 'v112-v106-idempotency', p_business,
    lower(btrim(p_source_system)), btrim(p_idempotency_key)
  );
  v_identity := app.v112_hash(jsonb_build_object(
    'operation', 'ingest_external_commerce_event_v106',
    'business_id', p_business,
    'source_system', lower(btrim(p_source_system)),
    'idempotency_key', btrim(p_idempotency_key)
  ));
  v_hash := app.v112_hash(jsonb_build_object(
    'business_id', p_business, 'branch_id', p_branch,
    'event_type', lower(btrim(p_event_type)),
    'source_system', lower(btrim(p_source_system)),
    'source_event_id', btrim(p_source_event_id),
    'idempotency_key', btrim(p_idempotency_key),
    'occurred_at', p_occurred_at, 'currency', upper(p_currency),
    'amount_minor', p_amount_minor, 'payload', p_payload,
    'actor_type', lower(btrim(p_actor_type)), 'actor_id', p_actor_id,
    'causation_id', p_causation_id, 'correlation_id', p_correlation_id,
    'supersedes_event_id', p_supersedes_event_id
  ));
  perform app.v112_lock_pair(v_source_lock, v_request_lock);
  select request_hash, receipt
  into v_existing_hash, v_receipt
  from public.concurrent_operation_receipts_v112
  where request_identity = v_identity;
  if v_receipt is not null then
    if v_existing_hash = v_hash then
      return v_receipt;
    end if;
    -- Let the canonical source identity decide this conflict.  A materially
    -- changed replay of the same source is quarantined by v106; a reused
    -- idempotency key for a different source still raises 23505.
    return public.ingest_external_commerce_event_v106_v112_inner(
      p_business, p_branch, p_event_type, p_source_system, p_source_event_id,
      p_idempotency_key, p_occurred_at, p_currency, p_amount_minor, p_payload,
      p_actor_type, p_actor_id, p_causation_id, p_correlation_id,
      p_supersedes_event_id
    );
  end if;
  v_receipt := public.ingest_external_commerce_event_v106_v112_inner(
    p_business, p_branch, p_event_type, p_source_system, p_source_event_id,
    p_idempotency_key, p_occurred_at, p_currency, p_amount_minor, p_payload,
    p_actor_type, p_actor_id, p_causation_id, p_correlation_id,
    p_supersedes_event_id
  );
  return app.v112_put_receipt(
    v_identity, 'ingest_external_commerce_event_v106', v_hash,
    jsonb_build_object(
      'business_id', p_business,
      'source_system', lower(btrim(p_source_system)),
      'source_event_id', btrim(p_source_event_id)
    ),
    v_receipt
  );
end $$;

revoke all on function public.ingest_external_commerce_event_v106(
  uuid,uuid,text,text,text,text,timestamptz,text,bigint,jsonb,
  text,uuid,text,text,uuid
) from public, anon;

create or replace function public.dismiss_growth_recommendation_v108(
  p_business uuid,
  p_recommendation uuid,
  p_reason text,
  p_idempotency_key uuid
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_actor uuid := auth.uid();
  v_identity text;
  v_hash text;
  v_receipt jsonb;
  v_branch uuid;
begin
  if not app.is_salon_owner(p_business) then
    raise exception 'owner only' using errcode = '42501';
  end if;
  select r.branch_id into v_branch
  from public.growth_recommendations_v108 r
  where r.id = p_recommendation and r.business_id = p_business;
  if not found then
    raise exception 'recommendation not found';
  end if;
  if not app.can_see_branch(p_business, v_branch) then
    raise exception 'recommendation branch is outside actor scope'
      using errcode = '42501';
  end if;
  v_identity := app.v112_hash(jsonb_build_object(
    'operation', 'dismiss_growth_recommendation_v108',
    'business_id', p_business, 'actor', v_actor,
    'idempotency_key', p_idempotency_key
  ));
  v_hash := app.v112_hash(jsonb_build_object(
    'business_id', p_business,
    'recommendation_id', p_recommendation,
    'decision', 'dismissed',
    'reason', nullif(btrim(coalesce(p_reason, '')), '')
  ));
  perform app.v112_lock_pair(
    'v112-v108-dismiss-request:' || v_identity,
    'v112-v108-recommendation:' || p_recommendation::text
  );
  v_receipt := app.v112_get_receipt(v_identity, v_hash);
  if v_receipt is not null then
    return v_receipt;
  end if;
  v_receipt := public.dismiss_growth_recommendation_v108_v112_inner(
    p_business, p_recommendation, p_reason, p_idempotency_key
  );
  return app.v112_put_receipt(
    v_identity, 'dismiss_growth_recommendation_v108', v_hash,
    jsonb_build_object(
      'business_id', p_business, 'recommendation_id', p_recommendation,
      'actor', v_actor
    ),
    v_receipt
  );
end $$;

revoke all on function public.dismiss_growth_recommendation_v108(
  uuid,uuid,text,uuid
) from public, anon;

create or replace function public.approve_growth_recommendation_v108(
  p_business uuid,
  p_recommendation uuid,
  p_offer_value_cents integer,
  p_offer_label text,
  p_idempotency_key uuid
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_actor uuid := auth.uid();
  v_identity text;
  v_hash text;
  v_receipt jsonb;
  v_branch uuid;
begin
  if not app.is_salon_owner(p_business) then
    raise exception 'owner only' using errcode = '42501';
  end if;
  select r.branch_id into v_branch
  from public.growth_recommendations_v108 r
  where r.id = p_recommendation and r.business_id = p_business;
  if not found then
    raise exception 'recommendation not found';
  end if;
  if not app.can_see_branch(p_business, v_branch) then
    raise exception 'recommendation branch is outside actor scope'
      using errcode = '42501';
  end if;
  if not app.platform_feature_enabled('growth_closed_loop_v108')
     or not app.can_module_read(p_business, 'retention') then
    raise exception 'growth feature or retention entitlement is no longer enabled'
      using errcode = '42501';
  end if;
  v_identity := app.v112_hash(jsonb_build_object(
    'operation', 'approve_growth_recommendation_v108',
    'business_id', p_business, 'actor', v_actor,
    'idempotency_key', p_idempotency_key
  ));
  v_hash := app.v112_hash(jsonb_build_object(
    'business_id', p_business,
    'recommendation_id', p_recommendation,
    'offer_value_cents', p_offer_value_cents,
    'offer_label', btrim(p_offer_label)
  ));
  perform app.v112_lock_pair(
    'v112-v108-approve-request:' || v_identity,
    'v112-v108-recommendation:' || p_recommendation::text
  );
  v_receipt := app.v112_get_receipt(v_identity, v_hash);
  if v_receipt is not null then
    return v_receipt;
  end if;
  v_receipt := public.approve_growth_recommendation_v108_v112_inner(
    p_business, p_recommendation, p_offer_value_cents, p_offer_label,
    p_idempotency_key
  );
  return app.v112_put_receipt(
    v_identity, 'approve_growth_recommendation_v108', v_hash,
    jsonb_build_object(
      'business_id', p_business, 'recommendation_id', p_recommendation,
      'actor', v_actor
    ),
    v_receipt
  );
end $$;

revoke all on function public.approve_growth_recommendation_v108(
  uuid,uuid,integer,text,uuid
) from public, anon;

create or replace function public.finalize_growth_execution_v108(
  p_business uuid,
  p_execution uuid,
  p_idempotency_key uuid
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_actor uuid := auth.uid();
  v_identity text;
  v_hash text;
  v_receipt jsonb;
  v_branch uuid;
begin
  if not app.is_salon_owner(p_business) then
    raise exception 'owner only' using errcode = '42501';
  end if;
  if not app.has_perm(p_business, 'view_finance')
     or not app.can_module_read(p_business, 'retention') then
    raise exception 'finance and retention access required'
      using errcode = '42501';
  end if;
  select e.branch_id into v_branch
  from public.growth_executions_v108 e
  where e.id = p_execution and e.business_id = p_business;
  if not found then
    raise exception 'execution not found';
  end if;
  if not app.can_see_branch(p_business, v_branch) then
    raise exception 'execution branch is outside actor scope'
      using errcode = '42501';
  end if;
  v_identity := app.v112_hash(jsonb_build_object(
    'operation', 'finalize_growth_execution_v108',
    'business_id', p_business, 'actor', v_actor,
    'idempotency_key', p_idempotency_key
  ));
  v_hash := app.v112_hash(jsonb_build_object(
    'business_id', p_business, 'execution_id', p_execution
  ));
  perform app.v112_lock_pair(
    'v112-v108-finalize-request:' || v_identity,
    'v112-v108-execution:' || p_execution::text
  );
  v_receipt := app.v112_get_receipt(v_identity, v_hash);
  if v_receipt is not null then return v_receipt; end if;
  v_receipt := public.finalize_growth_execution_v108_v112_inner(
    p_business, p_execution, p_idempotency_key
  );
  return app.v112_put_receipt(
    v_identity, 'finalize_growth_execution_v108', v_hash,
    jsonb_build_object(
      'business_id', p_business, 'execution_id', p_execution,
      'actor', v_actor
    ),
    v_receipt
  );
end $$;

revoke all on function public.finalize_growth_execution_v108(
  uuid,uuid,uuid
) from public, anon;

create or replace function public.set_effective_cost_rule_v109(
  p_business uuid,
  p_branch uuid,
  p_scope_kind text,
  p_scope_key text,
  p_cost_method text,
  p_cost_value bigint,
  p_source_type text,
  p_source_reference text,
  p_evidence jsonb,
  p_effective_from timestamptz,
  p_idempotency_key uuid
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_actor uuid := auth.uid();
  v_identity text;
  v_hash text;
  v_receipt jsonb;
begin
  if v_actor is null then
    raise exception 'authentication required' using errcode = '42501';
  end if;
  perform app.v109_require_feature();
  perform app.v109_require_finance_scope(p_business, p_branch);
  v_identity := app.v112_hash(jsonb_build_object(
    'operation', 'set_effective_cost_rule_v109',
    'business_id', p_business, 'actor', v_actor,
    'idempotency_key', p_idempotency_key
  ));
  v_hash := app.v112_hash(jsonb_build_object(
    'business_id', p_business, 'branch_id', p_branch,
    'scope_kind', p_scope_kind, 'scope_key', btrim(p_scope_key),
    'cost_method', p_cost_method, 'cost_value', p_cost_value,
    'source_type', p_source_type,
    'source_reference', btrim(p_source_reference),
    'evidence', p_evidence, 'effective_from', p_effective_from,
    'currency', (select upper(currency) from public.businesses where id=p_business)
  ));
  perform app.v112_lock_pair(
    'v112-v109-cost-request:' || v_identity,
    concat_ws(
      ':', 'v112-v109-cost-scope', p_business,
      coalesce(p_branch::text, 'all'), p_scope_kind, btrim(p_scope_key)
    )
  );
  v_receipt := app.v112_get_receipt(v_identity, v_hash);
  if v_receipt is not null then
    return v_receipt;
  end if;
  v_receipt := public.set_effective_cost_rule_v109_v112_inner(
    p_business, p_branch, p_scope_kind, p_scope_key, p_cost_method,
    p_cost_value, p_source_type, p_source_reference, p_evidence,
    p_effective_from, p_idempotency_key
  );
  return app.v112_put_receipt(
    v_identity, 'set_effective_cost_rule_v109', v_hash,
    jsonb_build_object(
      'business_id', p_business, 'branch_id', p_branch, 'actor', v_actor,
      'scope_kind', p_scope_kind, 'scope_key', btrim(p_scope_key)
    ),
    v_receipt
  );
end $$;

revoke all on function public.set_effective_cost_rule_v109(
  uuid,uuid,text,text,text,bigint,text,text,jsonb,timestamptz,uuid
) from public, anon;

create or replace function public.set_business_sector_policy_override_v109(
  p_business uuid,
  p_policy_key text,
  p_override_parameters jsonb,
  p_reason text,
  p_effective_from timestamptz,
  p_idempotency_key uuid
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_actor uuid := auth.uid();
  v_identity text;
  v_hash text;
  v_receipt jsonb;
begin
  if v_actor is null then
    raise exception 'authentication required' using errcode = '42501';
  end if;
  perform app.v109_require_feature();
  if not app.is_salon_owner(p_business) then
    raise exception 'owner only' using errcode = '42501';
  end if;
  if not app.can_see_branch(p_business, null) then
    raise exception 'business-wide sector policy is outside actor scope'
      using errcode = '42501';
  end if;
  v_identity := app.v112_hash(jsonb_build_object(
    'operation', 'set_business_sector_policy_override_v109',
    'business_id', p_business, 'actor', v_actor,
    'idempotency_key', p_idempotency_key
  ));
  v_hash := app.v112_hash(jsonb_build_object(
    'business_id', p_business, 'policy_key', p_policy_key,
    'override_parameters', p_override_parameters,
    'reason', btrim(p_reason), 'effective_from', p_effective_from
  ));
  perform app.v112_lock_pair(
    'v112-v109-sector-request:' || v_identity,
    concat_ws(':', 'v112-v109-sector-scope', p_business, p_policy_key)
  );
  v_receipt := app.v112_get_receipt(v_identity, v_hash);
  if v_receipt is not null then
    return v_receipt;
  end if;
  v_receipt :=
    public.set_business_sector_policy_override_v109_v112_inner(
      p_business, p_policy_key, p_override_parameters, p_reason,
      p_effective_from, p_idempotency_key
    );
  return app.v112_put_receipt(
    v_identity, 'set_business_sector_policy_override_v109', v_hash,
    jsonb_build_object(
      'business_id', p_business, 'policy_key', p_policy_key, 'actor', v_actor
    ),
    v_receipt
  );
end $$;

revoke all on function public.set_business_sector_policy_override_v109(
  uuid,text,jsonb,text,timestamptz,uuid
) from public, anon;

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
  v_identity text;
  v_hash text;
  v_receipt jsonb;
  v_dispatch public.growth_delivery_dispatches_v110%rowtype;
  v_backoff jsonb;
  v_detail jsonb := coalesce(p_detail, '{}'::jsonb);
  v_now timestamptz;
  v_next_attempt_at timestamptz;
begin
  if p_idempotency_key is null
     or jsonb_typeof(v_detail) <> 'object' then
    raise exception 'valid transition idempotency and detail are required'
      using errcode = '22023';
  end if;
  v_identity := app.v112_hash(jsonb_build_object(
    'operation', 'v110_transition_delivery',
    'dispatch_id', p_dispatch, 'idempotency_key', p_idempotency_key
  ));
  v_hash := app.v112_hash(jsonb_build_object(
    'dispatch_id', p_dispatch, 'to_status', p_to_status,
    'reason_code', p_reason_code,
    'provider_message_id', p_provider_message_id,
    'detail', v_detail
  ));
  perform app.v112_lock_dispatch(p_dispatch);
  perform app.v112_lock_pair(
    'v112-v110-transition-request:' || v_identity,
    'v112-v110-transition-request:' || v_identity
  );
  v_receipt := app.v112_get_receipt(v_identity, v_hash);
  if v_receipt is not null then
    return jsonb_populate_record(
      null::public.growth_delivery_dispatches_v110, v_receipt
    );
  end if;
  select * into strict v_dispatch
  from public.growth_delivery_dispatches_v110
  where id = p_dispatch;
  if v_dispatch.lifecycle_status = 'failed' and p_to_status = 'queued' then
    v_now := clock_timestamp();
    v_backoff := app.v112_delivery_backoff(v_dispatch.attempt_count, v_now);
    v_next_attempt_at := v_now
      + make_interval(secs => (v_backoff ->> 'delay_seconds')::integer);
    v_detail := v_detail || jsonb_build_object(
      'v112_backoff', v_backoff || jsonb_build_object(
        'computed_at', v_now,
        'next_attempt_at', v_next_attempt_at
      )
    );
  end if;
  v_dispatch := app.v110_transition_delivery_v112_inner(
    p_dispatch, p_to_status, p_reason_code, p_provider_message_id,
    p_idempotency_key, v_detail
  );
  if v_next_attempt_at is not null then
    perform set_config('app.growth_delivery_v110_transition', 'on', true);
    update public.growth_delivery_dispatches_v110
    set next_attempt_at = v_next_attempt_at,
        updated_at = v_now
    where id = p_dispatch
    returning * into v_dispatch;
  end if;
  v_receipt := to_jsonb(v_dispatch);
  perform app.v112_put_receipt(
    v_identity, 'v110_transition_delivery', v_hash,
    jsonb_build_object(
      'dispatch_id', p_dispatch, 'idempotency_key', p_idempotency_key,
      'to_status', p_to_status
    ),
    v_receipt
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
  v_identity text;
  v_hash text;
  v_request_lock text;
  v_receipt jsonb;
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
  v_identity := app.v112_hash(jsonb_build_object(
    'operation', 'service_claim_growth_deliveries_v110',
    'idempotency_key', p_idempotency_key
  ));
  v_hash := app.v112_hash(jsonb_build_object(
    'limit', p_limit,
    'worker_id', p_worker_id
  ));
  v_request_lock := 'v112-v110-claim-request:' || v_identity;
  perform app.v112_lock_pair(v_request_lock, v_request_lock);
  v_receipt := app.v112_get_receipt(v_identity, v_hash);
  if v_receipt is not null then
    return v_receipt;
  end if;
  v_receipt := public.service_claim_growth_deliveries_v110_v112_inner(
    p_limit, p_worker_id, p_idempotency_key
  );
  return app.v112_put_receipt(
    v_identity, 'service_claim_growth_deliveries_v110', v_hash,
    jsonb_build_object(
      'idempotency_key', p_idempotency_key,
      'limit', p_limit,
      'worker_id', p_worker_id
    ),
    v_receipt
  );
end $$;

revoke all on function public.service_claim_growth_deliveries_v110(
  integer,text,uuid
) from public, anon, authenticated;

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
  v_identity text;
  v_hash text;
  v_receipt jsonb;
begin
  if coalesce(auth.jwt() ->> 'role', '') <> 'service_role' then
    raise exception 'service role required' using errcode = '42501';
  end if;
  v_identity := app.v112_hash(jsonb_build_object(
    'operation', 'service_complete_growth_delivery_v110',
    'dispatch_id', p_dispatch, 'idempotency_key', p_idempotency_key
  ));
  v_hash := app.v112_hash(jsonb_build_object(
    'dispatch_id', p_dispatch,
    'provider_message_id', nullif(btrim(coalesce(p_provider_message_id, '')), ''),
    'succeeded', p_succeeded,
    'error_code', nullif(btrim(coalesce(p_error_code, '')), '')
  ));
  perform app.v112_lock_dispatch(p_dispatch);
  perform app.v112_lock_pair(
    'v112-v110-callback-request:' || v_identity,
    'v112-v110-callback-request:' || v_identity
  );
  v_receipt := app.v112_get_receipt(v_identity, v_hash);
  if v_receipt is not null then
    return v_receipt;
  end if;
  v_receipt := public.service_complete_growth_delivery_v110_v112_inner(
    p_dispatch, p_provider_message_id, p_succeeded, p_error_code,
    p_idempotency_key
  );
  return app.v112_put_receipt(
    v_identity, 'service_complete_growth_delivery_v110', v_hash,
    jsonb_build_object(
      'dispatch_id', p_dispatch, 'idempotency_key', p_idempotency_key
    ),
    v_receipt
  );
end $$;

revoke all on function public.service_complete_growth_delivery_v110(
  uuid,text,boolean,text,uuid
) from public, anon, authenticated;

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
  v_actor uuid := auth.uid();
  v_identity text;
  v_hash text;
  v_receipt jsonb;
  v_dispatch_branch uuid;
begin
  if not app.is_salon_owner(p_business)
     or not app.can_module_write(p_business, 'retention') then
    raise exception 'owner retention access required' using errcode = '42501';
  end if;
  select d.branch_id into v_dispatch_branch
  from public.growth_delivery_dispatches_v110 d
  where d.id = p_dispatch and d.business_id = p_business;
  if not found then
    raise exception 'dispatch not found';
  end if;
  if not app.can_see_branch(p_business, v_dispatch_branch) then
    raise exception 'delivery branch is outside actor scope'
      using errcode = '42501';
  end if;
  if length(btrim(coalesce(p_reason, ''))) not between 2 and 500
     or p_idempotency_key is null then
    raise exception 'cancellation reason and idempotency are required'
      using errcode = '22023';
  end if;
  v_identity := app.v112_hash(jsonb_build_object(
    'operation', 'cancel_growth_delivery_v110',
    'business_id', p_business, 'dispatch_id', p_dispatch,
    'actor', v_actor, 'idempotency_key', p_idempotency_key
  ));
  v_hash := app.v112_hash(jsonb_build_object(
    'business_id', p_business, 'dispatch_id', p_dispatch,
    'reason', btrim(p_reason)
  ));
  perform app.v112_lock_dispatch(p_dispatch);
  perform app.v112_lock_pair(
    'v112-v110-cancel-request:' || v_identity,
    'v112-v110-cancel-request:' || v_identity
  );
  v_receipt := app.v112_get_receipt(v_identity, v_hash);
  if v_receipt is not null then return v_receipt; end if;
  v_receipt := public.cancel_growth_delivery_v110_v112_inner(
    p_business, p_dispatch, p_reason, p_idempotency_key
  );
  return app.v112_put_receipt(
    v_identity, 'cancel_growth_delivery_v110', v_hash,
    jsonb_build_object(
      'business_id', p_business, 'dispatch_id', p_dispatch,
      'actor', v_actor
    ),
    v_receipt
  );
end $$;

revoke all on function public.cancel_growth_delivery_v110(
  uuid,uuid,text,uuid
) from public, anon;

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
  v_actor uuid := auth.uid();
  v_identity text;
  v_hash text;
  v_receipt jsonb;
  v_event public.growth_delivery_state_events_v110%rowtype;
  v_dispatch public.growth_delivery_dispatches_v110%rowtype;
  v_dispatch_branch uuid;
begin
  if not app.is_salon_owner(p_business)
     or not app.can_module_write(p_business, 'retention') then
    raise exception 'owner retention access required' using errcode = '42501';
  end if;
  select d.branch_id into v_dispatch_branch
  from public.growth_delivery_dispatches_v110 d
  where d.id = p_dispatch and d.business_id = p_business;
  if not found then
    raise exception 'dispatch not found';
  end if;
  if not app.can_see_branch(p_business, v_dispatch_branch) then
    raise exception 'delivery branch is outside actor scope'
      using errcode = '42501';
  end if;
  v_identity := app.v112_hash(jsonb_build_object(
    'operation', 'retry_growth_delivery_v110',
    'business_id', p_business, 'dispatch_id', p_dispatch,
    'actor', v_actor, 'idempotency_key', p_idempotency_key
  ));
  v_hash := app.v112_hash(jsonb_build_object(
    'business_id', p_business, 'dispatch_id', p_dispatch
  ));
  perform app.v112_lock_dispatch(p_dispatch);
  perform app.v112_lock_pair(
    'v112-v110-retry-request:' || v_identity,
    'v112-v110-retry-request:' || v_identity
  );
  v_receipt := app.v112_get_receipt(v_identity, v_hash);
  if v_receipt is not null then return v_receipt; end if;
  v_receipt := public.retry_growth_delivery_v110_v112_inner(
    p_business, p_dispatch, p_idempotency_key
  );
  select * into strict v_dispatch
  from public.growth_delivery_dispatches_v110
  where id = p_dispatch;
  select * into strict v_event
  from public.growth_delivery_state_events_v110
  where dispatch_id = p_dispatch and idempotency_key = p_idempotency_key;
  v_receipt := v_receipt || jsonb_build_object(
    'next_attempt_at', v_dispatch.next_attempt_at,
    'retry_policy', v_event.detail -> 'v112_backoff'
  );
  return app.v112_put_receipt(
    v_identity, 'retry_growth_delivery_v110', v_hash,
    jsonb_build_object(
      'business_id', p_business, 'dispatch_id', p_dispatch,
      'actor', v_actor
    ),
    v_receipt
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
    'contract_version', 'growth_delivery_lifecycle_v112',
    'execution_id', v_execution.id,
    'business_id', v_execution.business_id,
    'branch_id', v_execution.branch_id,
    'counts', (
      select coalesce(
        jsonb_object_agg(status_rows.lifecycle_status, status_rows.n),
        '{}'::jsonb
      )
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
        'updated_at', dispatch.updated_at,
        'entitlement_status', case
          when latest_event.detail ->> 'entitlement_suppressed' = 'true'
            then 'suppressed'
          when entitlement.id is not null then entitlement.status
          else null
        end,
        'entitlement_suppressed',
          latest_event.detail ->> 'entitlement_suppressed' = 'true',
        'suppression_reason', case
          when latest_event.detail ->> 'entitlement_suppressed' = 'true'
           and latest_event.reason_code in (
             'feature_disabled', 'module_disabled', 'execution_cancelled',
             'execution_expired', 'branch_unavailable', 'link_unavailable',
             'consent_withdrawn'
           )
            then latest_event.reason_code
          else null
        end
      ) order by dispatch.created_at, dispatch.id)
      from public.growth_delivery_dispatches_v110 dispatch
      left join public.growth_entitlements_v108 entitlement
        on entitlement.delivery_id = dispatch.delivery_id
      left join lateral (
        select event.reason_code, event.detail
        from public.growth_delivery_state_events_v110 event
        where event.dispatch_id = dispatch.id
          and event.to_status = dispatch.lifecycle_status
        order by event.occurred_at desc, event.id desc
        limit 1
      ) latest_event on true
      where dispatch.execution_id = p_execution
    ), '[]'::jsonb)
  );
end $$;

revoke all on function public.retry_growth_delivery_v110(
  uuid,uuid,uuid
) from public, anon;

revoke all privileges on function
  app.v112_immutable(),
  app.v112_hash(jsonb),
  app.v112_lock_pair(text,text),
  app.v112_lock_dispatch(uuid),
  app.v112_get_receipt(text,text),
  app.v112_put_receipt(text,text,text,jsonb,jsonb),
  app.v112_delivery_backoff(integer,timestamptz),
  app.v110_transition_delivery(uuid,text,text,text,uuid,jsonb)
from public, anon, authenticated, service_role;

revoke all on function public.ingest_external_commerce_event_v106(
  uuid,uuid,text,text,text,text,timestamptz,text,bigint,jsonb,
  text,uuid,text,text,uuid
) from public, anon;
grant execute on function public.ingest_external_commerce_event_v106(
  uuid,uuid,text,text,text,text,timestamptz,text,bigint,jsonb,
  text,uuid,text,text,uuid
) to authenticated;

revoke all on function public.dismiss_growth_recommendation_v108(
  uuid,uuid,text,uuid
) from public, anon;

revoke all on function public.approve_growth_recommendation_v108(
  uuid,uuid,integer,text,uuid
) from public, anon;

revoke all on function public.finalize_growth_execution_v108(
  uuid,uuid,uuid
) from public, anon;

revoke all on function public.set_effective_cost_rule_v109(
  uuid,uuid,text,text,text,bigint,text,text,jsonb,timestamptz,uuid
) from public, anon;

revoke all on function public.set_business_sector_policy_override_v109(
  uuid,text,jsonb,text,timestamptz,uuid
) from public, anon;

revoke all on function public.cancel_growth_delivery_v110(
  uuid,uuid,text,uuid
) from public, anon;

revoke all on function public.retry_growth_delivery_v110(
  uuid,uuid,uuid
) from public, anon;

revoke all on function public.get_growth_delivery_status_v110(
  uuid,uuid
) from public, anon;

grant execute on function
  public.dismiss_growth_recommendation_v108(uuid,uuid,text,uuid),
  public.approve_growth_recommendation_v108(uuid,uuid,integer,text,uuid),
  public.finalize_growth_execution_v108(uuid,uuid,uuid),
  public.set_effective_cost_rule_v109(
    uuid,uuid,text,text,text,bigint,text,text,jsonb,timestamptz,uuid
  ),
  public.set_business_sector_policy_override_v109(
    uuid,text,jsonb,text,timestamptz,uuid
  ),
  public.cancel_growth_delivery_v110(uuid,uuid,text,uuid),
  public.retry_growth_delivery_v110(uuid,uuid,uuid),
  public.get_growth_delivery_status_v110(uuid,uuid)
to authenticated;

revoke all on function public.service_complete_growth_delivery_v110(
  uuid,text,boolean,text,uuid
) from public, anon, authenticated;
revoke all on function public.service_claim_growth_deliveries_v110(
  integer,text,uuid
) from public, anon, authenticated;
grant execute on function public.service_claim_growth_deliveries_v110(
  integer,text,uuid
) to service_role;
grant execute on function public.service_complete_growth_delivery_v110(
  uuid,text,boolean,text,uuid
) to service_role;

comment on table public.concurrent_operation_receipts_v112 is
  'Append-only exact mutation receipts. Callers first acquire deterministic request and canonical record/source advisory locks.';
comment on table public.growth_delivery_backoff_policies_v112 is
  'Append-only deterministic retry schedule. v1 delays failed deliveries by 1m, 5m, 15m, then 60m with five total attempts.';
comment on function app.v112_delivery_backoff(integer,timestamptz) is
  'Returns the versioned deterministic delay for the persisted completed-attempt count; exhausted attempts are rejected.';
comment on function public.get_growth_delivery_status_v110(uuid,uuid) is
  'Owner-scoped delivery truth including whether a delivered message produced an entitlement or was safely suppressed after eligibility changed.';

commit;
