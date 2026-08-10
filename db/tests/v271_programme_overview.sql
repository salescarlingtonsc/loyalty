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
  v_business uuid := gen_random_uuid();
  v_client_a uuid := gen_random_uuid();
  v_client_b uuid := gen_random_uuid();
  v_reward uuid := gen_random_uuid();
  v_program uuid := gen_random_uuid();
  v_result jsonb;
  v_reward_customers int;
  v_failed boolean;
begin
  insert into public.businesses (id, name, slug, industry)
  values (v_business, 'V271 Overview Fixture', 'v271-overview-fixture', 'beauty');

  insert into public.staff (business_id, user_id, role, active)
  values (v_business, v_owner, 'owner', true);

  insert into public.clients (id, business_id, full_name)
  values (v_client_a, v_business, 'V271 Customer A'),
         (v_client_b, v_business, 'V271 Customer B');

  insert into public.loyalty_programs (business_id, kind, active, earn_points_per_dollar)
  values (v_business, 'points', true, 1);

  insert into public.loyalty_rewards (id, business_id, name, cost_points, active)
  values (v_reward, v_business, 'V271 Free facial', 100, true);

  insert into public.retention_programs (id, business_id, name, goal_visits, period_days, active)
  values (v_program, v_business, 'V271 Bring-back', 1, 30, true);

  -- Two earns from ONE customer, one from another: two customers, three rows.
  insert into public.points_ledger (business_id, client_id, entry_type, points)
  values (v_business, v_client_a, 'earn', 10),
         (v_business, v_client_a, 'earn', 15),
         (v_business, v_client_b, 'earn', 20);

  -- The same customer redeems the same reward twice.
  insert into public.loyalty_redemptions (business_id, client_id, reward_id, reward_name, points_spent)
  values (v_business, v_client_a, v_reward, 'V271 Free facial', 100),
         (v_business, v_client_a, v_reward, 'V271 Free facial', 100);

  insert into public.reward_grants (business_id, program_id, client_id, period_index, reward_type, reward_value, status)
  values (v_business, v_program, v_client_b, 1, 'credit', 10, 'granted');

  insert into public.birthday_programs (business_id) values (v_business);
  -- One redemption that stands, one that was reversed. Only the first is a customer served.
  insert into public.customer_birthday_redemptions (business_id, client_id, active)
  values (v_business, v_client_a, true),
         (v_business, v_client_b, false);

  -- Granted is not the same as received.
  insert into public.welcome_offer_grants_v215 (business_id, client_id, reward_label, status)
  values (v_business, v_client_a, 'V271 welcome item', 'redeemed'),
         (v_business, v_client_b, 'V271 welcome item', 'granted');

  -- An unqualified referral has paid nobody.
  insert into public.referrals (business_id, referrer_client_id, referred_client_id, status, qualified_at)
  values (v_business, v_client_a, v_client_b, 'qualified', now()),
         (v_business, v_client_b, v_client_a, 'pending', null);

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
