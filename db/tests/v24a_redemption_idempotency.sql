-- Rollback-only v24a financial behavior suite. Run after applying v24a in rehearsal.
begin;

do $v24a_test$
declare
  v_business uuid;
  v_owner uuid;
  v_client uuid;
  v_other_client uuid;
  v_first json;
  v_replay json;
  v_before_points integer;
  v_after_points integer;
  v_redeem_rows integer;
  v_credit_rows integer;
  v_operation_rows integer;
begin
  select business_id, user_id into v_business, v_owner
    from public.staff
   where role = 'owner' and active and user_id is not null
   order by created_at limit 1;
  if v_business is null then
    raise exception 'v24a suite requires an active owner';
  end if;

  perform set_config('request.jwt.claims',
    json_build_object('sub', v_owner, 'role', 'authenticated')::text, true);

  insert into public.clients (business_id, full_name)
    values (v_business, 'v24a idempotency fixture') returning id into v_client;
  insert into public.clients (business_id, full_name)
    values (v_business, 'v24a mismatch fixture') returning id into v_other_client;

  insert into public.loyalty_programs
    (business_id, kind, reward_credit_cents, active, earn_points_per_dollar,
     redeem_points, tier_basis, loyalty_model, configuration_status)
  values
    (v_business, 'points', 500, true, 1, 50, 'visits', 'classic', 'published')
  on conflict (business_id) do update set
    kind = 'points', reward_credit_cents = 500, active = true,
    redeem_points = 50, loyalty_model = 'classic',
    configuration_status = 'published';

  perform public.adjust_points(v_business, v_client, 100, 'v24a replay fixture');
  select coalesce(sum(points), 0)::integer into v_before_points
    from public.points_ledger where business_id = v_business and client_id = v_client;

  v_first := public.redeem_points(v_business, v_client, 'v24a-replay-key');
  v_replay := public.redeem_points(v_business, v_client, 'v24a-replay-key');
  if v_replay::jsonb is distinct from v_first::jsonb then
    raise exception 'exact replay must return the original result';
  end if;

  select coalesce(sum(points), 0)::integer into v_after_points
    from public.points_ledger where business_id = v_business and client_id = v_client;
  if v_before_points - v_after_points <> 50 then
    raise exception 'replay spent points more than once';
  end if;

  select count(*) into v_redeem_rows from public.points_ledger
   where business_id = v_business and client_id = v_client and entry_type = 'redeem';
  select count(*) into v_credit_rows from public.credit_ledger
   where business_id = v_business and client_id = v_client
     and entry_type = 'loyalty_earn' and reference = 'points redemption';
  select count(*) into v_operation_rows from public.loyalty_operations
   where business_id = v_business and operation_type = 'redeem_points'
     and idempotency_key = 'v24a-replay-key' and status = 'completed';
  if v_redeem_rows <> 1 or v_credit_rows <> 1 or v_operation_rows <> 1 then
    raise exception 'replay must leave one points row, one credit row and one completed operation';
  end if;

  begin
    perform public.redeem_points(v_business, v_other_client, 'v24a-replay-key');
    raise exception 'request mismatch unexpectedly reused an operation key';
  exception when sqlstate '22023' then null;
  end;

  if has_function_privilege('authenticated', 'public.redeem_points(uuid,uuid)', 'execute')
     or not has_function_privilege('authenticated', 'public.redeem_points(uuid,uuid,text)', 'execute')
     or has_function_privilege('anon', 'public.redeem_points(uuid,uuid,text)', 'execute') then
    raise exception 'redeem_points overload ACL contract is incorrect';
  end if;

  raise notice 'v24a redemption idempotency suite: ALL PASS';
end $v24a_test$;

rollback;
