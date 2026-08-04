-- Rollback-only v112 exact-receipt, serialization, and retry-backoff evidence.
-- Run after the canonical chain through v112 in a disposable database.
begin;

create or replace function pg_temp.approve_workspace_v94(p_business uuid)
returns void language sql as $$
  update public.business_workspace_controls_v94
     set approval_status='approved',version=version+1,
         decided_at=statement_timestamp(),
         decision_reason='approved synthetic rollback fixture',
         updated_at=statement_timestamp()
   where business_id=p_business and approval_status='pending'
$$;

do $contract$
declare
  v_constraint_valid boolean;
  v_policy public.growth_delivery_backoff_policies_v112%rowtype;
  v_expected_hash text;
begin
  if to_regclass('public.concurrent_operation_receipts_v112') is null
     or to_regclass('public.growth_delivery_backoff_policies_v112') is null
     or to_regprocedure(
       'app.v112_delivery_backoff(integer,timestamp with time zone)'
     ) is null
     or to_regprocedure('app.v112_lock_dispatch(uuid)') is null
     or to_regprocedure(
       'public.service_claim_growth_deliveries_v110(integer,text,uuid)'
     ) is null
     or to_regprocedure(
       'public.service_claim_growth_deliveries_v110_v112_inner(integer,text,uuid)'
     ) is null
     or to_regprocedure(
       'public.cancel_growth_delivery_v110(uuid,uuid,text,uuid)'
     ) is null then
    raise exception 'v112 persistence or policy contract is incomplete';
  end if;

  if not (
    select c.relrowsecurity
    from pg_catalog.pg_class c
    join pg_catalog.pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public'
      and c.relname = 'concurrent_operation_receipts_v112'
  ) or not (
    select c.relrowsecurity
    from pg_catalog.pg_class c
    join pg_catalog.pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public'
      and c.relname = 'growth_delivery_backoff_policies_v112'
  ) then
    raise exception 'v112 tables do not enforce RLS';
  end if;

  if has_table_privilege(
       'authenticated', 'public.concurrent_operation_receipts_v112', 'SELECT'
     ) or has_table_privilege(
       'authenticated', 'public.concurrent_operation_receipts_v112', 'INSERT'
     ) or has_table_privilege(
       'authenticated', 'public.concurrent_operation_receipts_v112', 'UPDATE'
     ) or has_table_privilege(
       'authenticated', 'public.concurrent_operation_receipts_v112', 'DELETE'
     ) then
    raise exception 'authenticated can directly access v112 receipts';
  end if;

  select convalidated into strict v_constraint_valid
  from pg_catalog.pg_constraint
  where conname = 'growth_delivery_dispatches_v112_retry_bound_check'
    and conrelid = 'public.growth_delivery_dispatches_v110'::regclass;
  if not v_constraint_valid then
    raise exception 'v112 retry bound constraint is not validated';
  end if;

  select * into strict v_policy
  from public.growth_delivery_backoff_policies_v112
  where version_no = 1;
  v_expected_hash := encode(
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
  );
  if v_policy.max_attempts <> 5
     or v_policy.delays_seconds <> array[60, 300, 900, 3600]::integer[]
     or v_policy.policy_hash <> v_expected_hash then
    raise exception 'v112 backoff policy evidence drifted: %', to_jsonb(v_policy);
  end if;

  if not has_function_privilege(
       'authenticated',
       'public.ingest_external_commerce_event_v106(uuid,uuid,text,text,text,text,timestamp with time zone,text,bigint,jsonb,text,uuid,text,text,uuid)',
       'EXECUTE'
     ) or not has_function_privilege(
       'authenticated',
       'public.dismiss_growth_recommendation_v108(uuid,uuid,text,uuid)',
       'EXECUTE'
     ) or not has_function_privilege(
       'authenticated',
       'public.approve_growth_recommendation_v108(uuid,uuid,integer,text,uuid)',
       'EXECUTE'
     ) or not has_function_privilege(
       'authenticated',
       'public.finalize_growth_execution_v108(uuid,uuid,uuid)',
       'EXECUTE'
     ) or not has_function_privilege(
       'authenticated',
       'public.set_effective_cost_rule_v109(uuid,uuid,text,text,text,bigint,text,text,jsonb,timestamp with time zone,uuid)',
       'EXECUTE'
     ) or not has_function_privilege(
       'authenticated',
       'public.set_business_sector_policy_override_v109(uuid,text,jsonb,text,timestamp with time zone,uuid)',
       'EXECUTE'
     ) or not has_function_privilege(
       'authenticated',
       'public.cancel_growth_delivery_v110(uuid,uuid,text,uuid)',
       'EXECUTE'
     ) or not has_function_privilege(
       'authenticated',
       'public.retry_growth_delivery_v110(uuid,uuid,uuid)',
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
    raise exception 'v112 public wrapper grants drifted';
  end if;

  if has_function_privilege(
       'authenticated',
       'public.dismiss_growth_recommendation_v108_v112_inner(uuid,uuid,text,uuid)',
       'EXECUTE'
     ) or has_function_privilege(
       'service_role',
       'public.service_claim_growth_deliveries_v110_v112_inner(integer,text,uuid)',
       'EXECUTE'
     ) or has_function_privilege(
       'authenticated',
       'public.service_claim_growth_deliveries_v110(integer,text,uuid)',
       'EXECUTE'
     ) or has_function_privilege(
       'service_role',
       'public.service_complete_growth_delivery_v110_v112_inner(uuid,text,boolean,text,uuid)',
       'EXECUTE'
     ) or has_function_privilege(
       'authenticated',
       'public.cancel_growth_delivery_v110_v112_inner(uuid,uuid,text,uuid)',
       'EXECUTE'
     ) or has_function_privilege(
       'authenticated',
       'public.cancel_growth_delivery_v110_v112_unsafe_row_inner(uuid,uuid,text,uuid)',
       'EXECUTE'
     ) then
    raise exception 'v112 inner functions remain externally executable';
  end if;
end
$contract$;

do $policy$
declare
  v_one jsonb;
  v_two jsonb;
  v_three jsonb;
  v_four jsonb;
begin
  v_one := app.v112_delivery_backoff(1, '2026-07-30 00:00+00');
  v_two := app.v112_delivery_backoff(2, '2026-07-30 00:00+00');
  v_three := app.v112_delivery_backoff(3, '2026-07-30 00:00+00');
  v_four := app.v112_delivery_backoff(4, '2026-07-30 00:00+00');
  if (v_one ->> 'delay_seconds')::integer <> 60
     or (v_two ->> 'delay_seconds')::integer <> 300
     or (v_three ->> 'delay_seconds')::integer <> 900
     or (v_four ->> 'delay_seconds')::integer <> 3600
     or (v_four ->> 'max_attempts')::integer <> 5
     or v_one ->> 'policy_hash' <> v_four ->> 'policy_hash' then
    raise exception 'v112 deterministic delay slots drifted: %, %, %, %',
      v_one, v_two, v_three, v_four;
  end if;
  begin
    perform app.v112_delivery_backoff(5, '2026-07-30 00:00+00');
    raise exception 'v112 allowed retry after the fifth completed attempt';
  exception
    when invalid_parameter_value then null;
  end;
  begin
    update public.growth_delivery_backoff_policies_v112
    set max_attempts = 6 where version_no = 1;
    raise exception 'v112 policy row was mutable';
  exception
    when integrity_constraint_violation then null;
  end;
end
$policy$;

create or replace function pg_temp.v112_seed_recommendation(
  p_business uuid,
  p_branch uuid,
  p_owner uuid,
  p_status text
)
returns uuid
language plpgsql
set search_path to 'pg_catalog', 'public', 'app', 'extensions', 'pg_temp'
as $$
declare
  v_recommendation uuid := extensions.gen_random_uuid();
  v_started timestamptz := statement_timestamp();
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
    'Rollback-only v112 concurrency evidence',
    '[]'::jsonb, '{}'::jsonb, '{}'::jsonb, '{}'::jsonb, null,
    '{}'::jsonb, '[]'::jsonb, '{}'::jsonb, 'in_app', '{}'::jsonb,
    300, 10, 0, 30, true, 'incremental_completed_purchase_revenue',
    14, 20, '{}'::jsonb, p_status, '[]'::jsonb, v_started,
    '{}'::jsonb,
    encode(
      extensions.digest(
        convert_to(extensions.gen_random_uuid()::text, 'UTF8'),
        'sha256'
      ),
      'hex'
    ),
    p_owner
  );
  return v_recommendation;
end
$$;

create or replace function pg_temp.v112_seed_dispatch(
  p_business uuid,
  p_branch uuid,
  p_owner uuid
)
returns uuid
language plpgsql
set search_path to 'pg_catalog', 'public', 'app', 'extensions', 'pg_temp'
as $$
declare
  v_customer_user uuid := extensions.gen_random_uuid();
  v_identity uuid := extensions.gen_random_uuid();
  v_client uuid := extensions.gen_random_uuid();
  v_link uuid := extensions.gen_random_uuid();
  v_recommendation uuid;
  v_recommendation_member uuid := extensions.gen_random_uuid();
  v_execution uuid := extensions.gen_random_uuid();
  v_execution_member uuid := extensions.gen_random_uuid();
  v_delivery uuid := extensions.gen_random_uuid();
  v_dispatch uuid;
  v_started timestamptz := statement_timestamp();
  v_expires timestamptz := statement_timestamp() + interval '7 days';
  v_ends timestamptz := statement_timestamp() + interval '14 days';
  v_copy jsonb;
begin
  insert into auth.users(
    instance_id, id, aud, role, email, encrypted_password,
    email_confirmed_at, created_at, updated_at
  ) values (
    '00000000-0000-0000-0000-000000000000',
    v_customer_user, 'authenticated', 'authenticated',
    'v112-customer-' || v_customer_user || '@example.test',
    '', now(), now(), now()
  );
  insert into public.clients(
    id, business_id, full_name, email, marketing_consent, is_synthetic
  ) values (
    v_client, p_business, 'V112 Customer',
    'v112-customer-' || v_customer_user || '@example.test', true, true
  );
  insert into public.customer_identities(
    id, auth_user_id, status, created_via
  ) values (
    v_identity, v_customer_user, 'active', 'phone_registration'
  );
  perform set_config('app.customer_link_insert_id', v_link::text, true);
  insert into public.customer_links(
    id, business_id, identity_id, auth_user_id, client_id, state,
    verification_method, verified_at
  ) values (
    v_link, p_business, v_identity, v_customer_user, v_client, 'verified',
    'qr_join', statement_timestamp() - interval '30 days'
  );
  perform set_config('app.customer_link_insert_id', '', true);
  insert into public.customer_notification_preferences(
    business_id, identity_id, auth_user_id, link_id, client_id,
    channel, topic, opted_in, consent_at
  ) values (
    p_business, v_identity, v_customer_user, v_link, v_client,
    'in_app', 'marketing', true, statement_timestamp() - interval '30 days'
  );

  v_recommendation := pg_temp.v112_seed_recommendation(
    p_business, p_branch, p_owner, 'executed'
  );
  insert into public.growth_recommendation_members_v108(
    id, recommendation_id, business_id, client_id, eligible,
    prior_visits, last_visit_at, cadence_days, lapse_days,
    average_transaction_cents, historical_revenue_cents, evidence
  ) values (
    v_recommendation_member, v_recommendation, p_business, v_client,
    true, 3, v_started - interval '60 days', 14, 60,
    3000, 9000, '{}'::jsonb
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
      'timezone', 'Asia/Singapore'
    ),
    'locked_facts', jsonb_build_object(
      'template_id', 'member_thank_you',
      'offer_value_cents', 300,
      'currency', 'SGD',
      'expires_at', v_expires,
      'timezone', 'Asia/Singapore'
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
    'Asia/Singapore', v_expires,
    'nestly.growth_offer_copy', 1, v_copy,
    10000, 20, 14, 3, 'running', p_owner, v_started,
    v_started, v_ends, extensions.gen_random_uuid(),
    encode(
      extensions.digest(
        convert_to(extensions.gen_random_uuid()::text, 'UTF8'),
        'sha256'
      ),
      'hex'
    )
  );
  insert into public.growth_execution_members_v108(
    id, execution_id, business_id, recommendation_member_id, client_id,
    assignment, assignment_rank, assignment_score
  ) values (
    v_execution_member, v_execution, p_business, v_recommendation_member,
    v_client, 'treatment', 1,
    encode(
      extensions.digest(
        convert_to(v_execution::text || ':' || v_client::text, 'UTF8'),
        'sha256'
      ),
      'hex'
    )
  );
  insert into public.growth_deliveries_v108(
    id, execution_id, execution_member_id, business_id, client_id,
    identity_id, link_id, assignment, channel, delivery_status,
    title, body, estimated_cost_cents, delivered_at
  ) values (
    v_delivery, v_execution, v_execution_member, p_business, v_client,
    v_identity, v_link, 'treatment', 'in_app', 'delivered',
    'intercepted by v110', 'intercepted by v110', 300,
    statement_timestamp()
  );
  select id into strict v_dispatch
  from public.growth_delivery_dispatches_v110
  where delivery_id = v_delivery;
  -- The dispatcher is platform-global. Give this rollback-only fixture an
  -- earlier due boundary so exact limit-one replay assertions remain isolated
  -- from unrelated synthetic queue residue in the disposable database.
  perform set_config('app.growth_delivery_v110_transition', 'on', true);
  update public.growth_delivery_dispatches_v110
  set scheduled_for = timestamptz '2000-01-01 00:00:00+00',
      next_attempt_at = timestamptz '2000-01-01 00:00:00+00',
      updated_at = statement_timestamp()
  where id = v_dispatch;
  return v_dispatch;
end
$$;

do $runtime$
declare
  v_super_admin uuid := extensions.gen_random_uuid();
  v_owner uuid := extensions.gen_random_uuid();
  v_owner_staff uuid := extensions.gen_random_uuid();
  v_frontdesk uuid := extensions.gen_random_uuid();
  v_frontdesk_staff uuid := extensions.gen_random_uuid();
  v_business uuid := extensions.gen_random_uuid();
  v_branch uuid := extensions.gen_random_uuid();
  v_other_branch uuid := extensions.gen_random_uuid();
  v_recommendation uuid;
  v_execution uuid;
  v_dispatch uuid;
  v_event_time timestamptz := clock_timestamp();
  v_first jsonb;
  v_replay jsonb;
  v_result jsonb;
  v_status jsonb;
  v_key uuid;
  v_claim_key uuid;
  v_next_attempt_at timestamptz;
  v_before_retry timestamptz;
  v_event_count integer;
begin
  insert into auth.users(
    instance_id, id, aud, role, email, encrypted_password,
    email_confirmed_at, created_at, updated_at
  ) values
  (
    '00000000-0000-0000-0000-000000000000',
    v_super_admin, 'authenticated', 'authenticated',
    'v112-sa-' || v_super_admin || '@example.test', '', now(), now(), now()
  ),
  (
    '00000000-0000-0000-0000-000000000000',
    v_owner, 'authenticated', 'authenticated',
    'v112-owner-' || v_owner || '@example.test', '', now(), now(), now()
  ),
  (
    '00000000-0000-0000-0000-000000000000',
    v_frontdesk, 'authenticated', 'authenticated',
    'v112-frontdesk-' || v_frontdesk || '@example.test', '', now(), now(), now()
  );
  insert into public.super_admins(user_id, email, note) values (
    v_super_admin,
    'v112-sa-' || v_super_admin || '@example.test',
    'v112 rollback fixture'
  );
  insert into public.businesses(
    id, name, slug, currency, industry, enabled_modules, is_synthetic
  ) values (
    v_business, 'V112 Concurrent Replay',
    'v112-' || v_business, 'SGD', 'facial',
    array['dashboard', 'clients', 'sales', 'reports', 'pnl', 'retention'],
    true
  );
  perform pg_temp.approve_workspace_v94(v_business);
  insert into public.branches(
    id, business_id, name, timezone, is_default
  ) values
  (
    v_branch, v_business, 'V112 Singapore', 'Asia/Singapore', true
  ),
  (
    v_other_branch, v_business, 'V112 Other Branch', 'Asia/Singapore', false
  );
  insert into public.staff(
    id, business_id, user_id, role, full_name, email, active
  ) values
  (
    v_owner_staff, v_business, v_owner, 'owner', 'V112 Owner',
    'v112-owner-' || v_owner || '@example.test', true
  ),
  (
    v_frontdesk_staff, v_business, v_frontdesk, 'frontdesk',
    'V112 Frontdesk',
    'v112-frontdesk-' || v_frontdesk || '@example.test', true
  );
  insert into public.staff_branches(business_id, staff_id, branch_id)
  values (v_business, v_frontdesk_staff, v_branch);
  update app.platform_feature_flags
  set enabled = true
  where feature_key in (
    'growth_closed_loop_v108', 'economics_driver_policy_v109'
  );
  v_event_time := clock_timestamp();

  -- v106: same request key returns the immutable first response. A second
  -- request key for the same source replays the source event, while a changed
  -- source envelope is quarantined and a reused request key conflicts.
  execute 'set local role authenticated';
  perform set_config('request.jwt.claim.sub', v_super_admin::text, true);
  perform set_config(
    'request.jwt.claims',
    json_build_object(
      'sub', v_super_admin, 'role', 'authenticated'
    )::text,
    true
  );
  v_first := public.ingest_external_commerce_event_v106(
    v_business, v_branch, 'transaction_completed', 'v112.test.pos',
    'source-1', 'request-1', v_event_time, 'SGD', 1200,
    '{"fixture":"v112"}'::jsonb
  );
  v_replay := public.ingest_external_commerce_event_v106(
    v_business, v_branch, 'transaction_completed', 'v112.test.pos',
    'source-1', 'request-1', v_event_time, 'SGD', 1200,
    '{"fixture":"v112"}'::jsonb
  );
  if v_first is distinct from v_replay
     or v_first ->> 'status' <> 'accepted' then
    raise exception 'v112 v106 exact request replay drifted: %, %',
      v_first, v_replay;
  end if;
  v_result := public.ingest_external_commerce_event_v106(
    v_business, v_branch, 'transaction_completed', 'v112.test.pos',
    'source-1', 'request-2', v_event_time, 'SGD', 1200,
    '{"fixture":"v112"}'::jsonb
  );
  if v_result ->> 'status' <> 'replayed'
     or v_result ->> 'event_id' <> v_first ->> 'event_id' then
    raise exception 'v112 v106 canonical source replay failed: %', v_result;
  end if;
  v_result := public.ingest_external_commerce_event_v106(
    v_business, v_branch, 'transaction_completed', 'v112.test.pos',
    'source-1', 'request-3', v_event_time + interval '1 second', 'SGD', 1200,
    '{"fixture":"changed"}'::jsonb
  );
  if v_result ->> 'status' <> 'quarantined' then
    raise exception 'v112 v106 changed source was not quarantined: %', v_result;
  end if;
  begin
    perform public.ingest_external_commerce_event_v106(
      v_business, v_branch, 'transaction_completed', 'v112.test.pos',
      'source-2', 'request-1', v_event_time, 'SGD', 1200,
      '{"fixture":"v112"}'::jsonb
    );
    raise exception 'v112 v106 accepted a reused request key for another source';
  exception
    when unique_violation then null;
  end;
  execute 'reset role';

  -- A receipt is not an authorization capability. Restrict the same
  -- front-desk actor to another branch and prove its exact prior receipt is
  -- no longer observable.
  execute 'set local role authenticated';
  perform set_config('request.jwt.claim.sub', v_frontdesk::text, true);
  perform set_config(
    'request.jwt.claims',
    json_build_object('sub', v_frontdesk, 'role', 'authenticated')::text,
    true
  );
  v_first := public.ingest_external_commerce_event_v106(
    v_business, v_branch, 'transaction_completed', 'v112.branch.pos',
    'branch-source-1', 'branch-request-1', v_event_time, 'SGD', 900,
    '{"fixture":"branch-authority"}'::jsonb
  );
  execute 'reset role';
  delete from public.staff_branches
  where business_id = v_business and staff_id = v_frontdesk_staff;
  insert into public.staff_branches(business_id, staff_id, branch_id)
  values (v_business, v_frontdesk_staff, v_other_branch);
  execute 'set local role authenticated';
  perform set_config('request.jwt.claim.sub', v_frontdesk::text, true);
  perform set_config(
    'request.jwt.claims',
    json_build_object('sub', v_frontdesk, 'role', 'authenticated')::text,
    true
  );
  begin
    perform public.ingest_external_commerce_event_v106(
      v_business, v_branch, 'transaction_completed', 'v112.branch.pos',
      'branch-source-1', 'branch-request-1', v_event_time, 'SGD', 900,
      '{"fixture":"branch-authority"}'::jsonb
    );
    raise exception 'v112 exposed a prior v106 receipt after branch restriction';
  exception
    when insufficient_privilege then null;
  end;
  execute 'reset role';

  -- v108 dismissal: exact response replay, changed payload conflict, one row.
  v_recommendation := pg_temp.v112_seed_recommendation(
    v_business, v_branch, v_owner, 'presented'
  );
  v_key := extensions.gen_random_uuid();
  execute 'set local role authenticated';
  perform set_config('request.jwt.claim.sub', v_owner::text, true);
  perform set_config(
    'request.jwt.claims',
    json_build_object('sub', v_owner, 'role', 'authenticated')::text,
    true
  );
  v_first := public.dismiss_growth_recommendation_v108(
    v_business, v_recommendation, 'not this month', v_key
  );
  v_replay := public.dismiss_growth_recommendation_v108(
    v_business, v_recommendation, 'not this month', v_key
  );
  if v_first is distinct from v_replay
     or (v_first ->> 'replayed')::boolean then
    raise exception 'v112 v108 exact dismissal replay drifted: %, %',
      v_first, v_replay;
  end if;
  begin
    perform public.dismiss_growth_recommendation_v108(
      v_business, v_recommendation, 'changed reason', v_key
    );
    raise exception 'v112 v108 accepted changed dismissal payload';
  exception
    when unique_violation then null;
  end;
  if (
    select count(*) from public.growth_recommendation_decisions_v108
    where recommendation_id = v_recommendation
  ) <> 1 then
    raise exception 'v112 v108 dismissal mutated more than once';
  end if;

  -- Revoking the original actor's owner role blocks exact receipt replay.
  execute 'reset role';
  update public.staff
  set role = 'frontdesk'
  where id = v_owner_staff;
  execute 'set local role authenticated';
  perform set_config('request.jwt.claim.sub', v_owner::text, true);
  perform set_config(
    'request.jwt.claims',
    json_build_object('sub', v_owner, 'role', 'authenticated')::text,
    true
  );
  begin
    perform public.dismiss_growth_recommendation_v108(
      v_business, v_recommendation, 'not this month', v_key
    );
    raise exception 'v112 exposed a prior v108 receipt after role revocation';
  exception
    when insufficient_privilege then null;
  end;
  execute 'reset role';
  update public.staff
  set role = 'owner'
  where id = v_owner_staff;
  execute 'set local role authenticated';
  perform set_config('request.jwt.claim.sub', v_owner::text, true);
  perform set_config(
    'request.jwt.claims',
    json_build_object('sub', v_owner, 'role', 'authenticated')::text,
    true
  );

  -- v109 cost and sector writes share the same exact-receipt boundary.
  v_key := extensions.gen_random_uuid();
  v_first := public.set_effective_cost_rule_v109(
    v_business, v_branch, 'sale_kind', 'quick_sale',
    'revenue_bps', 4000, 'supplier_invoice', 'INV-V112-001',
    '{"fixture":true,"currency":"SGD"}'::jsonb,
    '2026-07-01 00:00+00', v_key
  );
  v_replay := public.set_effective_cost_rule_v109(
    v_business, v_branch, 'sale_kind', 'quick_sale',
    'revenue_bps', 4000, 'supplier_invoice', 'INV-V112-001',
    '{"fixture":true,"currency":"SGD"}'::jsonb,
    '2026-07-01 00:00+00', v_key
  );
  if v_first is distinct from v_replay
     or (v_first ->> 'replayed')::boolean then
    raise exception 'v112 v109 exact cost replay drifted: %, %',
      v_first, v_replay;
  end if;
  begin
    perform public.set_effective_cost_rule_v109(
      v_business, v_branch, 'sale_kind', 'quick_sale',
      'revenue_bps', 4100, 'supplier_invoice', 'INV-V112-001',
      '{"fixture":true,"currency":"SGD"}'::jsonb,
      '2026-07-01 00:00+00', v_key
    );
    raise exception 'v112 v109 accepted changed cost payload';
  exception
    when unique_violation then null;
  end;

  v_key := extensions.gen_random_uuid();
  v_first := public.set_business_sector_policy_override_v109(
    v_business, 'lapse_detection',
    '{"minimum_lapse_days":45,"cadence_multiplier":1.8}'::jsonb,
    'V112 owner evidence', '2026-07-30 00:00+00', v_key
  );
  v_replay := public.set_business_sector_policy_override_v109(
    v_business, 'lapse_detection',
    '{"minimum_lapse_days":45,"cadence_multiplier":1.8}'::jsonb,
    'V112 owner evidence', '2026-07-30 00:00+00', v_key
  );
  if v_first is distinct from v_replay
     or (v_first ->> 'replayed')::boolean then
    raise exception 'v112 v109 exact sector replay drifted: %, %',
      v_first, v_replay;
  end if;
  execute 'reset role';

  -- v110: failure -> retry moves next_attempt_at into the future, immediate
  -- service claim refuses it, and the retry receipt preserves exact timestamps.
  v_dispatch := pg_temp.v112_seed_dispatch(v_business, v_branch, v_owner);
  execute 'set local role service_role';
  perform set_config(
    'request.jwt.claims',
    json_build_object('role', 'service_role')::text,
    true
  );
  v_claim_key := extensions.gen_random_uuid();
  v_result := public.service_claim_growth_deliveries_v110(
    1, 'v112-worker-1', v_claim_key
  );
  if (v_result ->> 'claimed_count')::integer <> 1
     or (v_result #>> '{claims,0,dispatch_id}')::uuid <> v_dispatch then
    raise exception 'v112 initial delivery claim failed: %', v_result;
  end if;
  v_key := extensions.gen_random_uuid();
  v_first := public.service_complete_growth_delivery_v110(
    v_dispatch, null, false, 'provider_timeout', v_key
  );
  v_replay := public.service_complete_growth_delivery_v110(
    v_dispatch, null, false, 'provider_timeout', v_key
  );
  if v_first is distinct from v_replay then
    raise exception 'v112 callback replay was not byte-stable: %, %',
      v_first, v_replay;
  end if;
  v_replay := public.service_claim_growth_deliveries_v110(
    1, 'v112-worker-1', v_claim_key
  );
  if v_result is distinct from v_replay
     or (v_replay ->> 'claimed_count')::integer <> 1
     or (v_replay #>> '{claims,0,dispatch_id}')::uuid <> v_dispatch then
    raise exception
      'v112 claim replay did not preserve the first moved-row batch: %, %',
      v_result, v_replay;
  end if;
  begin
    perform public.service_claim_growth_deliveries_v110(
      2, 'v112-worker-1', v_claim_key
    );
    raise exception 'v112 claim accepted a changed limit';
  exception
    when unique_violation then null;
  end;
  begin
    perform public.service_claim_growth_deliveries_v110(
      1, 'v112-worker-changed', v_claim_key
    );
    raise exception 'v112 claim accepted a changed worker';
  exception
    when unique_violation then null;
  end;
  begin
    perform public.service_complete_growth_delivery_v110(
      v_dispatch, null, false, 'changed_error', v_key
    );
    raise exception 'v112 callback accepted changed payload';
  exception
    when unique_violation then null;
  end;
  execute 'reset role';

  execute 'set local role authenticated';
  perform set_config('request.jwt.claim.sub', v_owner::text, true);
  perform set_config(
    'request.jwt.claims',
    json_build_object('sub', v_owner, 'role', 'authenticated')::text,
    true
  );
  v_key := extensions.gen_random_uuid();
  v_before_retry := clock_timestamp();
  v_first := public.retry_growth_delivery_v110(
    v_business, v_dispatch, v_key
  );
  v_replay := public.retry_growth_delivery_v110(
    v_business, v_dispatch, v_key
  );
  v_next_attempt_at := (v_first ->> 'next_attempt_at')::timestamptz;
  if v_first is distinct from v_replay
     or v_first ->> 'status' <> 'queued'
     or (v_first #>> '{retry_policy,policy_version}')::integer <> 1
     or (v_first #>> '{retry_policy,completed_attempts}')::integer <> 1
     or (v_first #>> '{retry_policy,delay_seconds}')::integer <> 60
     or v_next_attempt_at < v_before_retry + interval '59 seconds'
     or v_next_attempt_at <> (
       v_first #>> '{retry_policy,next_attempt_at}'
     )::timestamptz then
    raise exception 'v112 first retry evidence drifted: %, %', v_first, v_replay;
  end if;
  execute 'reset role';
  select count(*) into v_event_count
  from public.growth_delivery_state_events_v110
  where dispatch_id = v_dispatch
    and to_status = 'queued'
    and detail ? 'v112_backoff';
  if v_event_count <> 1 then
    raise exception 'v112 retry replay created duplicate state events: %',
      v_event_count;
  end if;

  execute 'set local role service_role';
  perform set_config(
    'request.jwt.claims',
    json_build_object('role', 'service_role')::text,
    true
  );
  v_result := public.service_claim_growth_deliveries_v110(
    100, 'v112-too-early', extensions.gen_random_uuid()
  );
  if exists (
    select 1
    from jsonb_array_elements(coalesce(v_result -> 'claims', '[]'::jsonb)) claim
    where (claim ->> 'dispatch_id')::uuid = v_dispatch
  ) or not exists (
    select 1
    from public.growth_delivery_dispatches_v110
    where id = v_dispatch
      and lifecycle_status = 'queued'
      and next_attempt_at > statement_timestamp()
  ) then
    raise exception 'v112 claimed retry before next_attempt_at: %', v_result;
  end if;
  execute 'reset role';

  -- Deterministic test-clock simulation: move only this disposable dispatch to
  -- its due boundary through the guarded lifecycle path, then prove claim.
  perform set_config('app.growth_delivery_v110_transition', 'on', true);
  update public.growth_delivery_dispatches_v110
  set next_attempt_at = statement_timestamp() - interval '1 second',
      updated_at = statement_timestamp()
  where id = v_dispatch;
  execute 'set local role service_role';
  perform set_config(
    'request.jwt.claims',
    json_build_object('role', 'service_role')::text,
    true
  );
  v_result := public.service_claim_growth_deliveries_v110(
    1, 'v112-now-due', extensions.gen_random_uuid()
  );
  if (v_result ->> 'claimed_count')::integer <> 1
     or (v_result #>> '{claims,0,dispatch_id}')::uuid <> v_dispatch
     or (v_result #>> '{claims,0,attempt}')::integer <> 2 then
    raise exception 'v112 due retry was not claimed: %', v_result;
  end if;
  perform public.service_complete_growth_delivery_v110(
    v_dispatch, null, false, 'provider_timeout', extensions.gen_random_uuid()
  );
  execute 'reset role';

  execute 'set local role authenticated';
  perform set_config('request.jwt.claim.sub', v_owner::text, true);
  perform set_config(
    'request.jwt.claims',
    json_build_object('sub', v_owner, 'role', 'authenticated')::text,
    true
  );
  v_result := public.retry_growth_delivery_v110(
    v_business, v_dispatch, extensions.gen_random_uuid()
  );
  if (v_result #>> '{retry_policy,delay_seconds}') <> '300'
     or (v_result #>> '{retry_policy,completed_attempts}')::integer <> 2 then
    raise exception 'v112 second retry did not use the 300-second slot: %',
      v_result;
  end if;
  execute 'reset role';

  perform set_config('app.growth_delivery_v110_transition', 'on', true);
  begin
    update public.growth_delivery_dispatches_v110
    set attempt_count = 5
    where id = v_dispatch;
    raise exception 'v112 allowed an exhausted dispatch to remain queued';
  exception
    when check_violation then null;
  end;

  execute 'set local role authenticated';
  perform set_config('request.jwt.claim.sub', v_owner::text, true);
  perform set_config(
    'request.jwt.claims',
    json_build_object('sub', v_owner, 'role', 'authenticated')::text,
    true
  );
  v_key := extensions.gen_random_uuid();
  v_first := public.cancel_growth_delivery_v110(
    v_business, v_dispatch, 'owner closed the campaign', v_key
  );
  v_replay := public.cancel_growth_delivery_v110(
    v_business, v_dispatch, 'owner closed the campaign', v_key
  );
  if v_first is distinct from v_replay
     or v_first ->> 'status' <> 'cancelled' then
    raise exception 'v112 cancel exact receipt drifted: %, %',
      v_first, v_replay;
  end if;
  begin
    perform public.cancel_growth_delivery_v110(
      v_business, v_dispatch, 'different cancellation reason', v_key
    );
    raise exception 'v112 cancel accepted changed payload';
  exception
    when unique_violation then null;
  end;
  execute 'reset role';
  select count(*) into v_event_count
  from public.growth_delivery_state_events_v110
  where dispatch_id = v_dispatch
    and idempotency_key = v_key
    and to_status = 'cancelled';
  if v_event_count <> 1 then
    raise exception 'v112 cancel replay created duplicate state events: %',
      v_event_count;
  end if;

  execute 'reset role';
  v_dispatch := pg_temp.v112_seed_dispatch(v_business, v_branch, v_owner);
  execute 'set local role service_role';
  perform set_config(
    'request.jwt.claims',
    jsonb_build_object('role', 'service_role')::text,
    true
  );
  v_result := public.service_claim_growth_deliveries_v110(
    1, 'v112-late-callback', extensions.gen_random_uuid()
  );
  if (v_result ->> 'claimed_count')::integer <> 1
     or (v_result #>> '{claims,0,dispatch_id}')::uuid <> v_dispatch then
    raise exception 'v112 late-callback fixture was not claimed: %', v_result;
  end if;
  execute 'reset role';
  update public.growth_executions_v108
  set status = 'running',
      started_at = statement_timestamp() - interval '3 days',
      offer_expires_at = statement_timestamp() - interval '1 day',
      ends_at = statement_timestamp() - interval '1 second',
      governed_copy = jsonb_set(
        jsonb_set(
          governed_copy,
          '{conditions,expires_at}',
          to_jsonb(statement_timestamp() - interval '1 day')
        ),
        '{locked_facts,expires_at}',
        to_jsonb(statement_timestamp() - interval '1 day')
      )
  where id = (
    select execution_id
    from public.growth_delivery_dispatches_v110
    where id = v_dispatch
  );
  execute 'set local role service_role';
  perform set_config(
    'request.jwt.claims',
    jsonb_build_object('role', 'service_role')::text,
    true
  );
  v_key := extensions.gen_random_uuid();
  v_first := public.service_complete_growth_delivery_v110(
    v_dispatch, 'provider-late-v112', true, null, v_key
  );
  v_replay := public.service_complete_growth_delivery_v110(
    v_dispatch, 'provider-late-v112', true, null, v_key
  );
  if v_first is distinct from v_replay
     or v_first ->> 'status' <> 'delivered'
     or (v_first ->> 'entitlement_suppressed')::boolean is distinct from true
     or v_first ->> 'suppression_reason' <> 'execution_expired'
     or v_first ->> 'entitlement_id' is not null then
    raise exception 'v112 late callback contract drifted: %, %',
      v_first, v_replay;
  end if;
  execute 'reset role';
  if exists (
    select 1 from public.growth_entitlements_v108 entitlement
    join public.growth_delivery_dispatches_v110 dispatch
      on dispatch.delivery_id = entitlement.delivery_id
    where dispatch.id = v_dispatch
  ) then
    raise exception 'v112 late callback minted an expired entitlement';
  end if;
  select count(*) into v_event_count
  from public.growth_delivery_state_events_v110
  where dispatch_id = v_dispatch
    and idempotency_key = v_key
    and to_status = 'delivered'
    and reason_code = 'execution_expired'
    and detail ->> 'suppression_reason' = 'execution_expired'
    and (detail ->> 'entitlement_suppressed')::boolean;
  if v_event_count <> 1 then
    raise exception 'v112 late callback suppression audit drifted: %',
      v_event_count;
  end if;
  select execution_id into strict v_execution
  from public.growth_delivery_dispatches_v110
  where id = v_dispatch;
  execute 'set local role authenticated';
  perform set_config('request.jwt.claim.sub', v_owner::text, true);
  perform set_config(
    'request.jwt.claims',
    json_build_object('sub', v_owner, 'role', 'authenticated')::text,
    true
  );
  v_result := public.get_growth_delivery_status_v110(
    v_business, v_execution
  );
  select delivery into strict v_status
  from jsonb_array_elements(v_result -> 'deliveries') delivery
  where delivery ->> 'dispatch_id' = v_dispatch::text;
  if v_result ->> 'contract_version' <> 'growth_delivery_lifecycle_v112'
     or v_status ->> 'status' <> 'delivered'
     or v_status ->> 'entitlement_status' <> 'suppressed'
     or (v_status ->> 'entitlement_suppressed')::boolean is distinct from true
     or v_status ->> 'suppression_reason' <> 'execution_expired'
     or v_status ? 'provider_message_id' then
    raise exception 'v112 owner suppression truth drifted: %, %',
      v_result, v_status;
  end if;
  execute 'reset role';

  if (
    select count(*) from public.concurrent_operation_receipts_v112
    where scope ->> 'business_id' = v_business::text
  ) < 8 then
    raise exception 'v112 immutable receipt evidence is incomplete';
  end if;
end
$runtime$;

reset role;
rollback;
