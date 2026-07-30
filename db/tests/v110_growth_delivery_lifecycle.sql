-- Rollback-only v110 provider-neutral delivery lifecycle evidence.
-- Run after the canonical chain through v110 in a disposable database.
begin;

do $contract$
declare
  v_table text;
begin
  if to_regprocedure(
    'public.service_claim_growth_deliveries_v110(integer,text,uuid)'
  ) is null or to_regprocedure(
    'public.service_complete_growth_delivery_v110(uuid,text,boolean,text,uuid)'
  ) is null or to_regprocedure(
    'public.cancel_growth_delivery_v110(uuid,uuid,text,uuid)'
  ) is null or to_regprocedure(
    'public.retry_growth_delivery_v110(uuid,uuid,uuid)'
  ) is null or to_regprocedure(
    'public.get_growth_delivery_status_v110(uuid,uuid)'
  ) is null then
    raise exception 'v110 public RPC contract is incomplete';
  end if;

  foreach v_table in array array[
    'growth_delivery_dispatches_v110',
    'growth_delivery_state_events_v110'
  ] loop
    if not exists (
      select 1
      from pg_catalog.pg_class c
      join pg_catalog.pg_namespace n on n.oid = c.relnamespace
      where n.nspname = 'public'
        and c.relname = v_table
        and c.relrowsecurity
    ) then
      raise exception 'v110 table % does not enforce RLS', v_table;
    end if;
    if has_table_privilege(
         'authenticated', 'public.' || v_table, 'INSERT'
       ) or has_table_privilege(
         'authenticated', 'public.' || v_table, 'UPDATE'
       ) or has_table_privilege(
         'authenticated', 'public.' || v_table, 'DELETE'
       ) then
      raise exception 'authenticated has a direct mutation grant on %', v_table;
    end if;
  end loop;

  if has_function_privilege(
       'authenticated',
       'public.service_claim_growth_deliveries_v110(integer,text,uuid)',
       'EXECUTE'
     ) or has_function_privilege(
       'authenticated',
       'public.service_complete_growth_delivery_v110(uuid,text,boolean,text,uuid)',
       'EXECUTE'
     ) or not has_function_privilege(
       'service_role',
       'public.service_claim_growth_deliveries_v110(integer,text,uuid)',
       'EXECUTE'
     ) or not has_function_privilege(
       'service_role',
       'public.service_complete_growth_delivery_v110(uuid,text,boolean,text,uuid)',
       'EXECUTE'
     ) then
    raise exception 'v110 service callback grants are not fail-closed';
  end if;
end
$contract$;

create temporary table v110_fixture_clients (
  sequence_no integer primary key,
  auth_user_id uuid not null,
  identity_id uuid not null,
  client_id uuid not null,
  link_id uuid not null
) on commit drop;

create or replace function pg_temp.v110_seed_client(
  p_business uuid,
  p_sequence integer,
  p_quiet boolean default false
)
returns uuid
language plpgsql
set search_path to 'pg_catalog', 'public', 'app', 'extensions', 'pg_temp'
as $$
declare
  v_auth uuid := extensions.gen_random_uuid();
  v_identity uuid := extensions.gen_random_uuid();
  v_client uuid := extensions.gen_random_uuid();
  v_link uuid := extensions.gen_random_uuid();
  v_now_time time := (statement_timestamp() at time zone 'UTC')::time;
begin
  insert into auth.users(
    instance_id, id, aud, role, email, encrypted_password,
    email_confirmed_at, created_at, updated_at
  ) values (
    '00000000-0000-0000-0000-000000000000',
    v_auth, 'authenticated', 'authenticated',
    'v110-customer-' || p_sequence || '-' || v_auth || '@example.test',
    '', now(), now(), now()
  );
  insert into public.clients(
    id, business_id, full_name, email, marketing_consent, is_synthetic
  ) values (
    v_client, p_business, 'V110 Customer ' || p_sequence,
    'v110-customer-' || p_sequence || '@example.test', true, true
  );
  insert into public.customer_identities(
    id, auth_user_id, status, created_via
  ) values (
    v_identity, v_auth, 'active', 'phone_registration'
  );
  perform set_config('app.customer_link_insert_id', v_link::text, true);
  insert into public.customer_links(
    id, business_id, identity_id, auth_user_id, client_id, state,
    verification_method, verified_at
  ) values (
    v_link, p_business, v_identity, v_auth, v_client, 'verified',
    'qr_join', statement_timestamp() - interval '30 days'
  );
  perform set_config('app.customer_link_insert_id', '', true);
  insert into public.customer_notification_preferences(
    business_id, identity_id, auth_user_id, link_id, client_id,
    channel, topic, opted_in, consent_at,
    quiet_hours_timezone, quiet_hours_start, quiet_hours_end
  ) values (
    p_business, v_identity, v_auth, v_link, v_client,
    'in_app', 'marketing', true, statement_timestamp() - interval '30 days',
    case when p_quiet then 'UTC' end,
    case when p_quiet then (v_now_time - interval '1 hour')::time end,
    case when p_quiet then (v_now_time + interval '1 hour')::time end
  );
  insert into v110_fixture_clients(
    sequence_no, auth_user_id, identity_id, client_id, link_id
  ) values (
    p_sequence, v_auth, v_identity, v_client, v_link
  );
  return v_client;
end
$$;

create or replace function pg_temp.v110_seed_execution(
  p_business uuid,
  p_branch uuid,
  p_owner uuid,
  p_clients uuid[],
  p_budget_cap_cents bigint default 10000,
  p_frequency_cap_days integer default 30
)
returns uuid
language plpgsql
set search_path to 'pg_catalog', 'public', 'app', 'extensions', 'pg_temp'
as $$
declare
  v_recommendation uuid := extensions.gen_random_uuid();
  v_execution uuid := extensions.gen_random_uuid();
  v_recommendation_member uuid;
  v_client uuid;
  v_rank integer := 0;
  v_started timestamptz := statement_timestamp();
  v_expires timestamptz := statement_timestamp() + interval '7 days';
  v_ends timestamptz := statement_timestamp() + interval '14 days';
  v_copy jsonb;
begin
  insert into public.growth_recommendations_v108(
    id, business_id, branch_id, recommendation_type, policy_version,
    generated_at, valid_until, observation_start, observation_end,
    comparison_start, comparison_end, finding, supporting_evidence,
    baseline, opportunity, expected_incremental_revenue,
    expected_incremental_gross_profit, confidence, assumptions,
    recommended_action, recommended_channel, recommended_offer,
    estimated_cost_cents, audience_size, excluded_size,
    frequency_cap_days, approval_required, success_metric,
    attribution_window_days, holdout_percent, stop_conditions, status,
    suppression_reasons, data_freshness_at, data_coverage, dedupe_key,
    created_by
  ) values (
    v_recommendation, p_business, p_branch,
    'lapsed_high_value_bring_back', 'bring_back_v1',
    v_started, v_started + interval '1 day',
    v_started - interval '180 days', v_started,
    v_started - interval '360 days', v_started - interval '180 days',
    'Rollback-only v110 delivery lifecycle evidence',
    '[]'::jsonb, '{}'::jsonb, '{}'::jsonb, '{}'::jsonb, null,
    '{}'::jsonb, '[]'::jsonb, '{}'::jsonb, 'in_app', '{}'::jsonb,
    cardinality(p_clients) * 300, cardinality(p_clients), 0,
    p_frequency_cap_days, true, 'incremental_completed_purchase_revenue',
    14, 20, '{}'::jsonb, 'executed', '[]'::jsonb, v_started,
    '{}'::jsonb,
    encode(
      extensions.digest(
        convert_to(extensions.gen_random_uuid()::text, 'UTF8'), 'sha256'
      ),
      'hex'
    ),
    p_owner
  );

  v_copy := jsonb_build_object(
    'schema', 'nestly.growth_offer_copy',
    'version', 1,
    'title', 'A thank-you reward is ready',
    'body', 'Enjoy SGD 3.00 off before the offer expires.',
    'cta_label', 'Redeem now',
    'cta_destination', 'customer_growth_offer_qr',
    'eligibility', jsonb_build_object(
      'business_id', p_business,
      'branch_id', p_branch
    ),
    'conditions', jsonb_build_object(
      'expires_at', v_expires,
      'timezone', 'Pacific/Auckland'
    ),
    'locked_facts', jsonb_build_object(
      'template_id', 'member_thank_you',
      'offer_value_cents', 300,
      'currency', 'SGD',
      'expires_at', v_expires,
      'timezone', 'Pacific/Auckland'
    )
  );
  insert into public.growth_executions_v108(
    id, recommendation_id, business_id, branch_id,
    channel, offer_type, offer_value_cents, offer_label, currency,
    offer_timezone, offer_expires_at,
    governed_copy_schema, governed_copy_version, governed_copy,
    budget_cap_cents, holdout_percent, attribution_window_days,
    minimum_arm_size, status, approved_by, approved_at,
    started_at, ends_at, idempotency_key, request_hash
  ) values (
    v_execution, v_recommendation, p_business, p_branch,
    'in_app', 'credit_cents', 300, 'member_thank_you', 'SGD',
    'Pacific/Auckland', v_expires,
    'nestly.growth_offer_copy', 1, v_copy,
    p_budget_cap_cents, 20, 14, 3, 'running', p_owner, v_started,
    v_started, v_ends, extensions.gen_random_uuid(),
    encode(
      extensions.digest(
        convert_to(extensions.gen_random_uuid()::text, 'UTF8'), 'sha256'
      ),
      'hex'
    )
  );

  foreach v_client in array p_clients loop
    v_rank := v_rank + 1;
    v_recommendation_member := extensions.gen_random_uuid();
    insert into public.growth_recommendation_members_v108(
      id, recommendation_id, business_id, client_id, eligible,
      prior_visits, last_visit_at, cadence_days, lapse_days,
      average_transaction_cents, historical_revenue_cents, evidence
    ) values (
      v_recommendation_member, v_recommendation, p_business, v_client,
      true, 3, v_started - interval '60 days', 14, 60,
      3000, 9000, '{}'::jsonb
    );
    insert into public.growth_execution_members_v108(
      execution_id, business_id, recommendation_member_id, client_id,
      assignment, assignment_rank, assignment_score
    ) values (
      v_execution, p_business, v_recommendation_member, v_client,
      'treatment', v_rank,
      encode(
        extensions.digest(
          convert_to(
            v_execution::text || ':' || v_client::text, 'UTF8'
          ),
          'sha256'
        ),
        'hex'
      )
    );
  end loop;
  return v_execution;
end
$$;

create or replace function pg_temp.v110_seed_delivery(
  p_execution uuid,
  p_client uuid,
  p_quiet boolean default false
)
returns uuid
language plpgsql
set search_path to 'pg_catalog', 'public', 'app', 'extensions', 'pg_temp'
as $$
declare
  v_execution public.growth_executions_v108%rowtype;
  v_member public.growth_execution_members_v108%rowtype;
  v_fixture v110_fixture_clients%rowtype;
  v_delivery uuid := extensions.gen_random_uuid();
  v_dispatch uuid;
begin
  select * into strict v_execution
  from public.growth_executions_v108 where id = p_execution;
  select * into strict v_member
  from public.growth_execution_members_v108
  where execution_id = p_execution and client_id = p_client;
  select * into strict v_fixture
  from v110_fixture_clients where client_id = p_client;
  insert into public.growth_deliveries_v108(
    id, execution_id, execution_member_id, business_id, client_id,
    identity_id, link_id, assignment, channel, delivery_status,
    suppression_reason, title, body, estimated_cost_cents, delivered_at
  ) values (
    v_delivery, p_execution, v_member.id, v_execution.business_id, p_client,
    v_fixture.identity_id, v_fixture.link_id, 'treatment', 'in_app',
    case when p_quiet then 'suppressed' else 'delivered' end,
    case when p_quiet then 'quiet_hours' end,
    'intercepted by v110', 'intercepted by v110', 300,
    case when p_quiet then null else statement_timestamp() end
  );
  select id into strict v_dispatch
  from public.growth_delivery_dispatches_v110
  where delivery_id = v_delivery;
  return v_dispatch;
end
$$;

do $runtime$
declare
  v_owner_user uuid := extensions.gen_random_uuid();
  v_bookkeeper_user uuid := extensions.gen_random_uuid();
  v_owner_staff uuid := extensions.gen_random_uuid();
  v_bookkeeper_staff uuid := extensions.gen_random_uuid();
  v_business uuid := extensions.gen_random_uuid();
  v_branch_a uuid := extensions.gen_random_uuid();
  v_branch_b uuid := extensions.gen_random_uuid();
  v_clients uuid[] := array[]::uuid[];
  v_execution uuid;
  v_branch_b_execution uuid;
  v_dispatch uuid;
  v_second_dispatch uuid;
  v_claim_key uuid;
  v_callback_key uuid;
  v_cancel_key uuid;
  v_result jsonb;
  v_replay jsonb;
  v_status jsonb;
  v_sequence integer;
  v_attempt integer;
  v_count integer;
  v_user uuid;
  v_link uuid;
begin
  insert into auth.users(
    instance_id, id, aud, role, email, encrypted_password,
    email_confirmed_at, created_at, updated_at
  ) values
  (
    '00000000-0000-0000-0000-000000000000',
    v_owner_user, 'authenticated', 'authenticated',
    'v110-owner-' || v_owner_user || '@example.test', '',
    now(), now(), now()
  ),
  (
    '00000000-0000-0000-0000-000000000000',
    v_bookkeeper_user, 'authenticated', 'authenticated',
    'v110-bookkeeper-' || v_bookkeeper_user || '@example.test', '',
    now(), now(), now()
  );
  insert into public.businesses(
    id, name, slug, currency, industry, enabled_modules, is_synthetic
  ) values (
    v_business, 'V110 Delivery Lifecycle',
    'v110-delivery-' || v_business, 'SGD', 'facial',
    array['dashboard', 'clients', 'sales', 'loyalty', 'retention'],
    true
  );
  insert into public.branches(
    id, business_id, name, timezone, is_default
  ) values
  (
    v_branch_a, v_business, 'V110 Orchard', 'Asia/Singapore', true
  ),
  (
    v_branch_b, v_business, 'V110 Tampines', 'Asia/Singapore', false
  );
  insert into public.staff(
    id, business_id, user_id, role, full_name, email, active, module_perms
  ) values
  (
    v_owner_staff, v_business, v_owner_user, 'owner', 'V110 Owner',
    'v110-owner-' || v_owner_user || '@example.test', true, null
  ),
  (
    v_bookkeeper_staff, v_business, v_bookkeeper_user, 'bookkeeper',
    'V110 Branch Bookkeeper',
    'v110-bookkeeper-' || v_bookkeeper_user || '@example.test',
    true, '{"retention":"r"}'::jsonb
  );
  insert into public.staff_branches(business_id, staff_id, branch_id)
  values(v_business, v_bookkeeper_staff, v_branch_a);
  update app.platform_feature_flags
  set enabled = true
  where feature_key = 'growth_closed_loop_v108';

  for v_sequence in 1..14 loop
    v_clients := v_clients || pg_temp.v110_seed_client(
      v_business, v_sequence, v_sequence = 2
    );
  end loop;

  -- queued -> claim -> verified callback -> one entitlement.
  v_execution := pg_temp.v110_seed_execution(
    v_business, v_branch_a, v_owner_user, array[v_clients[1]]
  );
  v_dispatch := pg_temp.v110_seed_delivery(
    v_execution, v_clients[1]
  );
  if (
    select lifecycle_status
    from public.growth_delivery_dispatches_v110 where id = v_dispatch
  ) <> 'queued' or exists (
    select 1 from public.growth_entitlements_v108
    where delivery_id = (
      select delivery_id from public.growth_delivery_dispatches_v110
      where id = v_dispatch
    )
  ) then
    raise exception 'v110 approval issued value before verified delivery';
  end if;

  v_claim_key := extensions.gen_random_uuid();
  execute 'set local role service_role';
  perform set_config(
    'request.jwt.claims',
    json_build_object('role', 'service_role')::text, true
  );
  v_result := public.service_claim_growth_deliveries_v110(
    1, 'v110-sql-fixture', v_claim_key
  );
  if (v_result ->> 'claimed_count')::integer <> 1
     or (v_result #>> '{claims,0,dispatch_id}')::uuid <> v_dispatch then
    raise exception 'v110 service did not claim the queued dispatch: %', v_result;
  end if;
  v_callback_key := extensions.gen_random_uuid();
  v_result := public.service_complete_growth_delivery_v110(
    v_dispatch, 'provider-v110-success-1', true, null, v_callback_key
  );
  v_replay := public.service_complete_growth_delivery_v110(
    v_dispatch, 'provider-v110-success-1', true, null, v_callback_key
  );
  if v_result ->> 'status' <> 'delivered'
     or v_replay ->> 'status' <> 'delivered'
     or (
       select count(*) from public.growth_entitlements_v108 entitlement
       join public.growth_delivery_dispatches_v110 dispatch
         on dispatch.delivery_id = entitlement.delivery_id
       where dispatch.id = v_dispatch
     ) <> 1
     or (
       select count(*) from public.growth_delivery_state_events_v110
       where dispatch_id = v_dispatch
     ) <> 3 then
    raise exception 'v110 success/replay was not exactly-once: %, %',
      v_result, v_replay;
  end if;
  begin
    perform public.service_complete_growth_delivery_v110(
      v_dispatch, 'provider-v110-different', true, null, v_callback_key
    );
    raise exception 'v110 accepted a changed callback under a reused key';
  exception
    when unique_violation then null;
  end;
  execute 'reset role';

  -- The callback rejects every browser role before reading delivery state.
  execute 'set local role authenticated';
  perform set_config('request.jwt.claim.sub', v_owner_user::text, true);
  perform set_config(
    'request.jwt.claims',
    json_build_object(
      'sub', v_owner_user, 'role', 'authenticated'
    )::text,
    true
  );
  begin
    perform public.service_complete_growth_delivery_v110(
      v_dispatch, 'browser-forbidden', true, null,
      extensions.gen_random_uuid()
    );
    raise exception 'v110 browser session completed a provider callback';
  exception
    when insufficient_privilege then null;
  end;
  execute 'reset role';

  -- Quiet-hour approval is scheduled and not claimable before its due time.
  v_execution := pg_temp.v110_seed_execution(
    v_business, v_branch_a, v_owner_user, array[v_clients[2]]
  );
  v_dispatch := pg_temp.v110_seed_delivery(
    v_execution, v_clients[2], true
  );
  if not exists (
    select 1
    from public.growth_delivery_dispatches_v110
    where id = v_dispatch
      and lifecycle_status = 'scheduled'
      and scheduled_for > statement_timestamp()
      and next_attempt_at = scheduled_for
  ) then
    raise exception 'v110 quiet-hour delivery was not scheduled forward';
  end if;
  execute 'set local role service_role';
  perform set_config(
    'request.jwt.claims',
    json_build_object('role', 'service_role')::text, true
  );
  v_result := public.service_claim_growth_deliveries_v110(
    10, 'v110-quiet-check', extensions.gen_random_uuid()
  );
  if (v_result ->> 'claimed_count')::integer <> 0 then
    raise exception 'v110 claimed a quiet-hour delivery before due: %', v_result;
  end if;
  execute 'reset role';

  -- Five verified provider failures permit four retries, then fail closed.
  v_execution := pg_temp.v110_seed_execution(
    v_business, v_branch_a, v_owner_user, array[v_clients[3]]
  );
  v_dispatch := pg_temp.v110_seed_delivery(
    v_execution, v_clients[3]
  );
  for v_attempt in 1..5 loop
    execute 'set local role service_role';
    perform set_config(
      'request.jwt.claims',
      json_build_object('role', 'service_role')::text, true
    );
    v_result := public.service_claim_growth_deliveries_v110(
      1, 'v110-retry-' || v_attempt, extensions.gen_random_uuid()
    );
    if (v_result ->> 'claimed_count')::integer <> 1
       or (v_result #>> '{claims,0,dispatch_id}')::uuid <> v_dispatch then
      raise exception 'v110 retry attempt % was not claimed: %',
        v_attempt, v_result;
    end if;
    perform public.service_complete_growth_delivery_v110(
      v_dispatch, null, false, 'provider_timeout',
      extensions.gen_random_uuid()
    );
    execute 'reset role';
    if v_attempt < 5 then
      execute 'set local role authenticated';
      perform set_config('request.jwt.claim.sub', v_owner_user::text, true);
      perform set_config(
        'request.jwt.claims',
        json_build_object(
          'sub', v_owner_user, 'role', 'authenticated'
        )::text,
        true
      );
      v_result := public.retry_growth_delivery_v110(
        v_business, v_dispatch, extensions.gen_random_uuid()
      );
      if v_result ->> 'status' <> 'queued'
         or (v_result ->> 'attempt_count')::integer <> v_attempt then
        raise exception 'v110 retry % did not preserve its attempt count: %',
          v_attempt, v_result;
      end if;
      execute 'reset role';
      execute 'set local role service_role';
      perform set_config(
        'request.jwt.claims',
        json_build_object('role', 'service_role')::text, true
      );
      v_result := public.service_claim_growth_deliveries_v110(
        1, 'v112-backoff-not-due-' || v_attempt,
        extensions.gen_random_uuid()
      );
      if (v_result ->> 'claimed_count')::integer <> 0 then
        raise exception 'v112 retry backoff was claimable before due: %',
          v_result;
      end if;
      execute 'reset role';
      perform set_config(
        'app.growth_delivery_v110_transition', 'on', true
      );
      update public.growth_delivery_dispatches_v110
      set next_attempt_at = statement_timestamp() - interval '1 second'
      where id = v_dispatch;
    end if;
  end loop;
  execute 'set local role authenticated';
  perform set_config('request.jwt.claim.sub', v_owner_user::text, true);
  perform set_config(
    'request.jwt.claims',
    json_build_object(
      'sub', v_owner_user, 'role', 'authenticated'
    )::text,
    true
  );
  begin
    perform public.retry_growth_delivery_v110(
      v_business, v_dispatch, extensions.gen_random_uuid()
    );
    raise exception 'v110 allowed a sixth provider attempt';
  exception
    when invalid_parameter_value then null;
  end;
  execute 'reset role';
  if (
    select attempt_count
    from public.growth_delivery_dispatches_v110 where id = v_dispatch
  ) <> 5 or (
    select count(*) from public.growth_delivery_state_events_v110
    where dispatch_id = v_dispatch
  ) <> 15 then
    raise exception 'v110 bounded retry audit history is incomplete';
  end if;

  -- Owner cancellation is replay-safe and branch B supplies branch-denial proof.
  v_branch_b_execution := pg_temp.v110_seed_execution(
    v_business, v_branch_b, v_owner_user, array[v_clients[4]]
  );
  v_dispatch := pg_temp.v110_seed_delivery(
    v_branch_b_execution, v_clients[4]
  );
  v_cancel_key := extensions.gen_random_uuid();
  execute 'set local role authenticated';
  perform set_config('request.jwt.claim.sub', v_owner_user::text, true);
  perform set_config(
    'request.jwt.claims',
    json_build_object(
      'sub', v_owner_user, 'role', 'authenticated'
    )::text,
    true
  );
  v_result := public.cancel_growth_delivery_v110(
    v_business, v_dispatch, 'Owner stopped this send', v_cancel_key
  );
  v_replay := public.cancel_growth_delivery_v110(
    v_business, v_dispatch, 'Owner stopped this send', v_cancel_key
  );
  execute 'reset role';
  if v_result ->> 'status' <> 'cancelled'
     or v_replay ->> 'status' <> 'cancelled'
     or (
       select count(*) from public.growth_delivery_state_events_v110
       where dispatch_id = v_dispatch
     ) <> 2 then
    raise exception 'v110 cancellation was not replay-safe: %, %',
      v_result, v_replay;
  end if;
  execute 'set local role authenticated';
  perform set_config('request.jwt.claim.sub', v_owner_user::text, true);
  perform set_config(
    'request.jwt.claims',
    json_build_object(
      'sub', v_owner_user, 'role', 'authenticated'
    )::text,
    true
  );
  v_status := public.get_growth_delivery_status_v110(
    v_business, v_branch_b_execution
  );
  if v_status #>> '{counts,cancelled}' <> '1' then
    raise exception 'v110 owner status did not expose cancellation: %', v_status;
  end if;
  execute 'reset role';

  execute 'set local role authenticated';
  perform set_config('request.jwt.claim.sub', v_bookkeeper_user::text, true);
  perform set_config(
    'request.jwt.claims',
    json_build_object(
      'sub', v_bookkeeper_user, 'role', 'authenticated'
    )::text,
    true
  );
  begin
    perform public.get_growth_delivery_status_v110(
      v_business, v_branch_b_execution
    );
    raise exception 'v110 branch-scoped reader saw another branch';
  exception
    when insufficient_privilege then null;
  end;
  execute 'reset role';

  -- Feature kill switch is rechecked at dispatch time.
  v_execution := pg_temp.v110_seed_execution(
    v_business, v_branch_a, v_owner_user, array[v_clients[5]]
  );
  v_dispatch := pg_temp.v110_seed_delivery(v_execution, v_clients[5]);
  update app.platform_feature_flags
  set enabled = false where feature_key = 'growth_closed_loop_v108';
  execute 'set local role service_role';
  perform set_config(
    'request.jwt.claims',
    json_build_object('role', 'service_role')::text, true
  );
  perform public.service_claim_growth_deliveries_v110(
    1, 'v110-feature-off', extensions.gen_random_uuid()
  );
  execute 'reset role';
  if not exists (
    select 1 from public.growth_delivery_dispatches_v110
    where id = v_dispatch
      and lifecycle_status = 'cancelled'
      and failure_code = 'feature_disabled'
  ) then
    raise exception 'v110 feature kill switch did not cancel queued work';
  end if;
  update app.platform_feature_flags
  set enabled = true where feature_key = 'growth_closed_loop_v108';

  -- Business module kill switch is rechecked at dispatch time.
  v_execution := pg_temp.v110_seed_execution(
    v_business, v_branch_a, v_owner_user, array[v_clients[6]]
  );
  v_dispatch := pg_temp.v110_seed_delivery(v_execution, v_clients[6]);
  update public.businesses
  set enabled_modules = array_remove(enabled_modules, 'retention')
  where id = v_business;
  execute 'set local role service_role';
  perform set_config(
    'request.jwt.claims',
    json_build_object('role', 'service_role')::text, true
  );
  perform public.service_claim_growth_deliveries_v110(
    1, 'v110-module-off', extensions.gen_random_uuid()
  );
  execute 'reset role';
  if not exists (
    select 1 from public.growth_delivery_dispatches_v110
    where id = v_dispatch
      and lifecycle_status = 'cancelled'
      and failure_code = 'module_disabled'
  ) then
    raise exception 'v110 module kill switch did not cancel queued work';
  end if;
  update public.businesses
  set enabled_modules = array_append(enabled_modules, 'retention')
  where id = v_business;

  -- Consent withdrawal is rechecked at dispatch time.
  v_execution := pg_temp.v110_seed_execution(
    v_business, v_branch_a, v_owner_user, array[v_clients[7]]
  );
  v_dispatch := pg_temp.v110_seed_delivery(v_execution, v_clients[7]);
  update public.customer_notification_preferences
  set opted_in = false, updated_at = statement_timestamp()
  where business_id = v_business
    and client_id = v_clients[7]
    and channel = 'in_app'
    and topic = 'marketing';
  execute 'set local role service_role';
  perform set_config(
    'request.jwt.claims',
    json_build_object('role', 'service_role')::text, true
  );
  perform public.service_claim_growth_deliveries_v110(
    1, 'v110-consent-off', extensions.gen_random_uuid()
  );
  execute 'reset role';
  if not exists (
    select 1 from public.growth_delivery_dispatches_v110
    where id = v_dispatch
      and lifecycle_status = 'cancelled'
      and failure_code = 'consent_withdrawn'
  ) then
    raise exception 'v110 consent withdrawal did not cancel queued work';
  end if;

  -- Link loss is rechecked at dispatch time.
  v_execution := pg_temp.v110_seed_execution(
    v_business, v_branch_a, v_owner_user, array[v_clients[8]]
  );
  v_dispatch := pg_temp.v110_seed_delivery(v_execution, v_clients[8]);
  select auth_user_id, link_id into strict v_user, v_link
  from v110_fixture_clients where client_id = v_clients[8];
  perform set_config('app.customer_link_transition_id', v_link::text, true);
  update public.customer_links
  set state = 'unlinked',
      unlinked_at = statement_timestamp(),
      unlinked_by_auth_user_id = v_user,
      updated_at = statement_timestamp()
  where id = v_link;
  perform set_config('app.customer_link_transition_id', '', true);
  execute 'set local role service_role';
  perform set_config(
    'request.jwt.claims',
    json_build_object('role', 'service_role')::text, true
  );
  perform public.service_claim_growth_deliveries_v110(
    1, 'v110-link-off', extensions.gen_random_uuid()
  );
  execute 'reset role';
  if not exists (
    select 1 from public.growth_delivery_dispatches_v110
    where id = v_dispatch
      and lifecycle_status = 'cancelled'
      and failure_code = 'link_unavailable'
  ) then
    raise exception 'v110 link loss did not cancel queued work';
  end if;

  -- Two SGD 3 treatments under a SGD 5 budget: exactly one is claimable.
  v_execution := pg_temp.v110_seed_execution(
    v_business, v_branch_a, v_owner_user,
    array[v_clients[9], v_clients[10]], 500
  );
  v_dispatch := pg_temp.v110_seed_delivery(v_execution, v_clients[9]);
  v_second_dispatch := pg_temp.v110_seed_delivery(
    v_execution, v_clients[10]
  );
  execute 'set local role service_role';
  perform set_config(
    'request.jwt.claims',
    json_build_object('role', 'service_role')::text, true
  );
  v_result := public.service_claim_growth_deliveries_v110(
    2, 'v110-budget', extensions.gen_random_uuid()
  );
  if (v_result ->> 'claimed_count')::integer <> 1 then
    raise exception 'v110 budget cap did not limit claims: %', v_result;
  end if;
  if (v_result #>> '{claims,0,dispatch_id}')::uuid = v_second_dispatch then
    v_second_dispatch := v_dispatch;
    v_dispatch := (v_result #>> '{claims,0,dispatch_id}')::uuid;
  end if;
  perform public.service_complete_growth_delivery_v110(
    v_dispatch, 'provider-v110-budget', true, null,
    extensions.gen_random_uuid()
  );
  execute 'reset role';
  if not exists (
    select 1 from public.growth_delivery_dispatches_v110
    where id = v_second_dispatch
      and lifecycle_status = 'cancelled'
      and failure_code = 'budget_cap'
  ) then
    raise exception 'v110 budget overflow was not cancelled';
  end if;

  -- A recent verified delivery suppresses a second execution for that customer.
  v_execution := pg_temp.v110_seed_execution(
    v_business, v_branch_a, v_owner_user, array[v_clients[1]]
  );
  v_dispatch := pg_temp.v110_seed_delivery(v_execution, v_clients[1]);
  execute 'set local role service_role';
  perform set_config(
    'request.jwt.claims',
    json_build_object('role', 'service_role')::text, true
  );
  perform public.service_claim_growth_deliveries_v110(
    1, 'v110-frequency', extensions.gen_random_uuid()
  );
  execute 'reset role';
  if not exists (
    select 1 from public.growth_delivery_dispatches_v110
    where id = v_dispatch
      and lifecycle_status = 'cancelled'
      and failure_code = 'frequency_cap'
  ) then
    raise exception 'v110 frequency cap did not cancel repeat contact';
  end if;

  -- All synthetic transition histories remain append-only and internally scoped.
  if exists (
    select 1
    from public.growth_delivery_state_events_v110 event_row
    join public.growth_delivery_dispatches_v110 dispatch
      on dispatch.id = event_row.dispatch_id
    where event_row.delivery_id <> dispatch.delivery_id
       or event_row.execution_id <> dispatch.execution_id
       or event_row.business_id <> dispatch.business_id
       or event_row.request_hash !~ '^[0-9a-f]{64}$'
  ) then
    raise exception 'v110 transition history lost delivery scope or request evidence';
  end if;
  select count(*) into v_count
  from public.growth_delivery_state_events_v110;
  if v_count < 31 then
    raise exception 'v110 transition history is unexpectedly incomplete: %', v_count;
  end if;
end
$runtime$;

reset role;
rollback;
