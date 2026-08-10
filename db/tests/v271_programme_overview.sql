-- Rollback-only acceptance for v271 business_programme_usage_v271.
-- Run after the canonical chain through v271 in a disposable local database.
--
-- What this proves, and why each assertion exists:
--   * a customer who used a programme twice counts ONCE — the column asks how many customers,
--     not how many events, and a row count would inflate every figure on the Overview;
--   * a reversed birthday redemption and an unredeemed welcome grant do NOT count — both would
--     credit a programme with a customer it never actually reached;
--   * promotions and gift cards return SQL NULL, never 0 — the UI renders null as "Not tracked",
--     and a 0 there would be a fabricated measurement of something nothing records;
--   * a caller with no session is refused (42501), and anon holds no EXECUTE.
--
-- The whole file runs inside one transaction and ends in ROLLBACK: it writes nothing.
begin;

create or replace function pg_temp.as_v271_user(
  p_uid uuid,
  p_role text default 'authenticated'
) returns void language plpgsql as $$
begin
  -- reset first: without it a second call while already in role `authenticated` fails, because a
  -- non-superuser role cannot SET ROLE to another role.
  reset role;
  execute format('set local role %I', p_role);
  perform set_config('request.jwt.claim.sub', coalesce(p_uid::text, ''), true);
  perform set_config('request.jwt.claims',
    json_build_object('sub', p_uid, 'role', p_role)::text, true);
end
$$;
grant execute on function pg_temp.as_v271_user(uuid, text) to public;

do $v271$
declare
  v_owner uuid := gen_random_uuid();
  v_auth_a uuid := gen_random_uuid();
  v_auth_b uuid := gen_random_uuid();
  v_business uuid := gen_random_uuid();
  v_branch uuid := gen_random_uuid();
  v_config uuid := gen_random_uuid();
  v_taxonomy uuid := gen_random_uuid();
  v_client_a uuid := gen_random_uuid();
  v_client_b uuid := gen_random_uuid();
  v_ident_a uuid := gen_random_uuid();
  v_ident_b uuid := gen_random_uuid();
  v_reward uuid := gen_random_uuid();
  v_program uuid := gen_random_uuid();
  v_prog_ver uuid := gen_random_uuid();
  v_bday uuid := gen_random_uuid();
  v_bday_ver uuid := gen_random_uuid();
  v_ent_a uuid := gen_random_uuid();
  v_ent_b uuid := gen_random_uuid();
  v_sale1 uuid := gen_random_uuid();
  v_sale2 uuid := gen_random_uuid();
  v_sale3 uuid := gen_random_uuid();
  v_result jsonb;
  v_reward_customers int;
  v_failed boolean;
begin
  -- Fixture rows are written with triggers suppressed. Every loyalty WRITE path in this schema is
  -- guarded (points_ledger accepts only tokenised internal routes via app.loyalty_ledger_write_guard;
  -- loyalty_redemptions and customer_birthday_redemptions demand a branch-module check against
  -- auth.uid()), and none of those routes is what v271 is being tested on — it only READS. Stating
  -- the rows directly is what makes the expected counts legible. Every column those triggers would
  -- have filled is supplied explicitly below.
  set local session_replication_role = replica;

  -- staff.user_id and several audit columns are FKs to auth.users, so the actors must exist.
  insert into auth.users (id, instance_id, aud, role, email)
  values (v_owner, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'v271-owner@example.test'),
         (v_auth_a, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'v271-a@example.test'),
         (v_auth_b, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'v271-b@example.test');

  insert into public.businesses (id, name, slug, industry)
  values (v_business, 'V271 Overview Fixture', 'v271-overview-fixture', 'beauty');

  -- Normally seeded by AFTER INSERT triggers on businesses; suppressed here, so stated directly.
  -- app.is_salon_owner() is gated on app.business_workspace_open_v94(), which needs BOTH an
  -- approved control row and an unpaused lifecycle row. approval_status='approved' additionally
  -- requires the decided_by / decided_at / decision_reason trio (decision_shape check constraint).
  insert into public.business_workspace_controls_v94
    (business_id, approval_status, decided_by, decided_at, decision_reason)
  values (v_business, 'approved', v_owner, now(), 'V271 rolled-back acceptance fixture');
  insert into public.business_subscription_lifecycle_v94 (business_id, state, workspace_paused)
  values (v_business, 'current', false);

  -- access_state must be 'approved': app.is_salon_owner() checks it alongside role and active.
  insert into public.staff (business_id, user_id, role, active, access_state)
  values (v_business, v_owner, 'owner', true, 'approved');

  -- No trigger creates a default branch; customer_birthday_redemptions.branch_id is NOT NULL.
  insert into public.branches (id, business_id, name, is_default)
  values (v_branch, v_business, 'V271 Main', true);

  insert into public.clients (id, business_id, full_name)
  values (v_client_a, v_business, 'V271 Customer A'),
         (v_client_b, v_business, 'V271 Customer B');

  -- customer_birthday_entitlements.identity_id is NOT NULL and FKs to customer_identities.
  insert into public.customer_identities (id, auth_user_id)
  values (v_ident_a, v_auth_a), (v_ident_b, v_auth_b);

  -- Versioned-config header the programme version rows and provenance FKs hang off.
  insert into public.firm_config_versions (id, business_id, version_no, status, snapshot_hash, published_at)
  values (v_config, v_business, 1, 'published', md5('v271'), now());

  -- retention_programs / retention_program_versions / reward_grants all require a taxonomy row.
  insert into public.firm_reward_taxonomy (id, business_id, label, fulfillment_kind)
  values (v_taxonomy, v_business, 'V271 credit', 'credit');

  insert into public.loyalty_programs (business_id, kind, active, earn_points_per_dollar, configuration_status)
  values (v_business, 'points', true, 1, 'published');

  -- internal_name / customer_name / fulfillment_kind / credit_cents / estimated_cost_cents are all
  -- NOT NULL, and loyalty_rewards_fulfillment_amount_check ties credit_cents>0 to kind='credit'.
  insert into public.loyalty_rewards (id, business_id, name, internal_name, customer_name, cost_points,
                                      credit_cents, fulfillment_kind, estimated_cost_cents, active)
  values (v_reward, v_business, 'V271 Free facial', 'V271 Free facial', 'V271 Free facial', 100,
          500, 'credit', 0, true);

  insert into public.retention_programs (id, business_id, name, goal_visits, period_days, active,
                                         reward_type, reward_value, reward_taxonomy_id)
  values (v_program, v_business, 'V271 Bring-back', 1, 30, true, 'credit', 1000, v_taxonomy);

  -- reward_grants.retention_program_version_id is NOT NULL, so the grant needs a version to cite.
  insert into public.retention_program_versions (id, program_id, config_version_id, business_id, name,
         goal_visits, period_days, starts_on, reward_taxonomy_id, fulfillment_kind, credit_cents)
  values (v_prog_ver, v_program, v_config, v_business, 'V271 Bring-back', 1, 30, current_date,
          v_taxonomy, 'credit', 1000);

  -- points_ledger.sale_id is NOT NULL on the earn route and `points_earn_once_per_sale` is UNIQUE
  -- on sale_id, so three earn rows need three sales. A sale also gives the redeemed welcome offer
  -- something to point at (welcome_offer_grants_v215_redeem_shape requires redeemed_sale_id).
  insert into public.sales (id, business_id, client_id, branch_id, kind, amount_cents,
         counts_as_revenue, counts_as_visit, earns_points, policy_resolved_at,
         commission_rate_bps, commission_resolved_at, config_version_id)
  values (v_sale1, v_business, v_client_a, v_branch, 'service', 5000, true, true, true, now(), 0, now(), v_config),
         (v_sale2, v_business, v_client_a, v_branch, 'service', 7500, true, true, true, now(), 0, now(), v_config),
         (v_sale3, v_business, v_client_b, v_branch, 'service', 9000, true, true, true, now(), 0, now(), v_config);

  -- Two earns from ONE customer, one from another: two customers, three rows.
  insert into public.points_ledger (business_id, client_id, entry_type, points, sale_id, config_version_id)
  values (v_business, v_client_a, 'earn', 10, v_sale1, v_config),
         (v_business, v_client_a, 'earn', 15, v_sale2, v_config),
         (v_business, v_client_b, 'earn', 20, v_sale3, v_config);

  -- The same customer redeems the same reward twice. credit_cents is NOT NULL.
  insert into public.loyalty_redemptions (business_id, client_id, reward_id, reward_name, points_spent,
         credit_cents, config_version_id)
  values (v_business, v_client_a, v_reward, 'V271 Free facial', 100, 500, v_config),
         (v_business, v_client_a, v_reward, 'V271 Free facial', 100, 500, v_config);

  insert into public.reward_grants (business_id, program_id, client_id, period_index, reward_type,
         reward_value, status, reward_taxonomy_id, reward_label, fulfillment_kind,
         retention_program_version_id, period_start, period_end, config_version_id)
  values (v_business, v_program, v_client_b, 1, 'credit', 10, 'granted', v_taxonomy, 'V271 credit',
          'credit', v_prog_ver, now() - interval '1 day', now() + interval '29 days', v_config);

  insert into public.birthday_programs (id, business_id) values (v_bday, v_business);
  -- customer_birthday_entitlements FKs to a birthday_program_versions row, which is NOT NULL on
  -- customer_label / customer_description / customer_terms / fulfillment_kind.
  insert into public.birthday_program_versions (id, program_id, config_version_id, business_id,
         customer_label, customer_description, customer_terms, fulfillment_kind, manual_item)
  values (v_bday_ver, v_bday, v_config, v_business, 'V271 birthday', 'V271 birthday treat',
          'V271 terms', 'free_item', 'V271 birthday treat');

  insert into public.customer_birthday_entitlements (id, business_id, client_id, identity_id,
         config_version_id, birthday_program_version_id, birthday_year, status, valid_from,
         valid_until, benefit_snapshot)
  values (v_ent_a, v_business, v_client_a, v_ident_a, v_config, v_bday_ver, 2026, 'redeemed',
          now() - interval '1 day', now() + interval '7 days', '{}'::jsonb),
         (v_ent_b, v_business, v_client_b, v_ident_b, v_config, v_bday_ver, 2026, 'available',
          now() - interval '1 day', now() + interval '7 days', '{}'::jsonb);

  -- One redemption that stands, one that a reversal has already deactivated. active=false is the
  -- state the reversal route leaves on the original row, and is exactly what v271 must ignore.
  -- entitlement_id / branch_id / actor / operation_kind / idempotency_key / request_hash are all
  -- NOT NULL; request_hash must match ^[0-9a-f]{64}$.
  insert into public.customer_birthday_redemptions (entitlement_id, business_id, client_id, branch_id,
         actor, operation_kind, idempotency_key, request_hash, active)
  values (v_ent_a, v_business, v_client_a, v_branch, v_owner, 'redemption', gen_random_uuid(),
          md5('v271a')||md5('v271a2'), true),
         (v_ent_b, v_business, v_client_b, v_branch, v_owner, 'redemption', gen_random_uuid(),
          md5('v271b')||md5('v271b2'), false);

  -- Granted is not the same as received.
  insert into public.welcome_offer_grants_v215 (business_id, client_id, min_spend_cents,
         reward_catalog_kind, reward_catalog_id, reward_label, status, redeemed_at, redeemed_sale_id)
  values (v_business, v_client_a, 0, 'service', gen_random_uuid(), 'V271 welcome item', 'redeemed', now(), v_sale1),
         (v_business, v_client_b, 0, 'service', gen_random_uuid(), 'V271 welcome item', 'granted', null, null);

  -- An unqualified referral has paid nobody.
  insert into public.referrals (business_id, referrer_client_id, referred_client_id, status, qualified_at)
  values (v_business, v_client_a, v_client_b, 'qualified', now()),
         (v_business, v_client_b, v_client_a, 'pending', null);

  set local session_replication_role = origin;

  perform pg_temp.as_v271_user(v_owner);
  v_result := public.business_programme_usage_v271(v_business);
  reset role;

  if (v_result->>'status') is distinct from 'ok' then
    raise exception 'V271: expected status ok, got %', v_result->>'status';
  end if;

  if (v_result->'point_system'->>'customers')::int <> 2 then
    raise exception 'V271: point system must count DISTINCT customers, got %',
      v_result->'point_system'->>'customers';
  end if;

  select (entry->>'customers')::int into v_reward_customers
    from jsonb_array_elements(v_result->'rewards') entry
   where (entry->>'reward_id')::uuid = v_reward;
  if v_reward_customers <> 1 then
    raise exception 'V271: two redemptions by one customer must count as 1, got %', v_reward_customers;
  end if;

  if (v_result->'birthday'->>'customers')::int <> 1 then
    raise exception 'V271: a reversed birthday redemption must not count, got %',
      v_result->'birthday'->>'customers';
  end if;
  if (v_result->'birthday'->>'started_at') is null then
    raise exception 'V271: birthday start date must come from birthday_programs.created_at';
  end if;

  if (v_result->'welcome'->>'customers')::int <> 1 then
    raise exception 'V271: only a redeemed welcome offer counts, got %',
      v_result->'welcome'->>'customers';
  end if;

  if (v_result->'referrals'->>'customers')::int <> 1 then
    raise exception 'V271: only a qualified referral counts, got %',
      v_result->'referrals'->>'customers';
  end if;

  -- The honesty contract: null, never 0.
  if jsonb_typeof(v_result->'promotions'->'customers') <> 'null' then
    raise exception 'V271: promotion usage must be null (Not tracked), got %',
      v_result->'promotions'->'customers';
  end if;
  if jsonb_typeof(v_result->'gift_cards'->'customers') <> 'null' then
    raise exception 'V271: gift card usage must be null (Not tracked), got %',
      v_result->'gift_cards'->'customers';
  end if;

  -- No session at all must be refused, not answered with zeros.
  v_failed := false;
  begin
    perform pg_temp.as_v271_user(null, 'anon');
    perform public.business_programme_usage_v271(v_business);
  exception when others then
    v_failed := true;
  end;
  reset role;
  if not v_failed then
    raise exception 'V271: an unauthenticated caller must be refused';
  end if;

  raise notice 'V271 programme usage acceptance passed';
end
$v271$;

do $v271_grants$
declare
  v_anon boolean;
  v_authenticated boolean;
begin
  select has_function_privilege('anon', 'public.business_programme_usage_v271(uuid)', 'EXECUTE')
    into v_anon;
  select has_function_privilege('authenticated', 'public.business_programme_usage_v271(uuid)', 'EXECUTE')
    into v_authenticated;
  if v_anon then
    raise exception 'V271: anon must not hold EXECUTE on business_programme_usage_v271';
  end if;
  if not v_authenticated then
    raise exception 'V271: authenticated must hold EXECUTE on business_programme_usage_v271';
  end if;
end
$v271_grants$;

rollback;
