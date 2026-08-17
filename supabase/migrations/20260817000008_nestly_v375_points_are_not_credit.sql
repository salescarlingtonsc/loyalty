-- nestly_v375 — points are points, never store credit.
--
-- Owner, photo 3 (2026-08-17): "why got $1.50 credit, i don't want credit feature", struck
-- through "0 points - 150 more for SGD 1.50 credit" on a customer's profile. Confirmed by the
-- owner as the retirement of the legacy `classic` model, following their 2026-08-14 ruling
-- ("points are points - not stored credits").
--
-- Two changes, both inside the business-side reader that produced that line:
--
-- 1. staff_get_customer_actionable_loyalty_v145 no longer synthesizes a reward out of the
--    programme's own redeem_points/reward_credit_cents pair. That arm of candidate_rewards is the
--    only place in the database that ever built the string 'SGD <n> credit'.
-- 2. The catalogue arm of the same CTE stops excluding `loyalty_model = 'classic'`. This is the
--    half that made the screenshot worse than it looked: a classic tenant was shown the
--    synthesized credit and NONE of the gifts it had actually published. Cubbly has five live
--    rewards and was seeing none of them here. Removing only the first arm would have left those
--    tenants with an empty rewards list, so the two changes belong in one migration.
--
-- redeem_points is the one route that ever converted a points balance into credit_ledger, and it
-- now refuses. It was already unreachable from the browser -- `authenticated` holds no EXECUTE on
-- it, and app/app.js never calls it -- and production has never used it: all 5 credit_ledger rows
-- are gift_card_load, membership_credit and referral_reward. Nothing is deleted and no balance is
-- touched; existing credit stays exactly where it is.
--
-- `loyalty_model` keeps its three values. Renaming 'classic' would rewrite every one of the 10
-- production programmes and 17 functions that branch on it, to no customer-visible end -- what the
-- owner asked for is that no customer is offered credit, which is what this does.
--
-- VERIFIED against production inside a rolled-back transaction on 2026-08-17 -- see
-- db/tests/v375_points_are_not_credit.sql, whose fixture reproduces the screenshot exactly
-- (classic, 150 points, reward_credit_cents 150). Five checks: the pre-v375 reader offers
-- "SGD 1.50 credit" and withholds the published gift; the repaired reader offers the gift and
-- names no credit; and redeem_points refuses with 22023.

begin;


-- ------------------------------------------- public.staff_get_customer_actionable_loyalty_v145
CREATE OR REPLACE FUNCTION public.staff_get_customer_actionable_loyalty_v145(p_business uuid, p_client uuid, p_branch uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'app', 'pg_temp'
AS $function$
declare
  v_as_of timestamptz := statement_timestamp();
  v_result jsonb;
begin
  perform public.require_module_scope_v145(
    p_business, p_branch, 'clients'
  );
  perform public.require_module_scope_v145(
    p_business, p_branch, 'loyalty'
  );
  if not exists (
    select 1
      from public.clients client
     where client.id = p_client
       and client.business_id = p_business
  ) then
    raise exception 'customer not found in business'
      using errcode = '22023';
  end if;

  with program as (
    select
      loyalty.id,
      loyalty.kind,
      loyalty.loyalty_model,
      loyalty.earn_points_per_dollar,
      loyalty.redeem_points,
      loyalty.reward_credit_cents,
      loyalty.stamp_per_cents,
      loyalty.expiry_mode,
      loyalty.configuration_status,
      coalesce(loyalty.active, false)
        and loyalty.configuration_status = 'published' as enabled,
      business.active_config_version_id
    from public.businesses business
    left join public.loyalty_programs loyalty
      on loyalty.business_id = business.id
    where business.id = p_business
  ), ledger_balance as (
    select greatest(coalesce(sum(ledger.points), 0), 0)::integer as units
      from public.points_ledger ledger
     where ledger.business_id = p_business
       and ledger.client_id = p_client
  ), unexpired_batches as (
    select
      batch.id,
      batch.remaining,
      batch.earned_at,
      batch.expires_at,
      sum(batch.remaining) over (
        order by batch.expires_at nulls last, batch.earned_at, batch.id
        rows between unbounded preceding and current row
      )::bigint as cumulative_remaining
      from public.points_batches batch
     where batch.business_id = p_business
       and batch.client_id = p_client
       and batch.remaining > 0
       and (batch.expires_at is null or batch.expires_at > v_as_of)
  ), batch_balance as (
    select coalesce(sum(batch.remaining), 0)::integer as units
      from unexpired_batches batch
  ), loyalty_balance as (
    select case when program.enabled
      then greatest(least(ledger_balance.units, batch_balance.units), 0)
      else 0 end::integer as units
      from program cross join ledger_balance cross join batch_balance
  ), actionable_batches as (
    select
      batch.expires_at,
      least(
        batch.remaining::bigint,
        greatest(
          loyalty_balance.units::bigint
            - (batch.cumulative_remaining - batch.remaining::bigint),
          0
        )
      )::integer as actionable_remaining
      from unexpired_batches batch
      cross join loyalty_balance
     where loyalty_balance.units > 0
       and batch.cumulative_remaining - batch.remaining::bigint
           < loyalty_balance.units::bigint
  ), next_expiry as (
    select batch.expires_at,
           sum(batch.actionable_remaining)::integer as units
      from actionable_batches batch
     where batch.expires_at is not null
       and batch.actionable_remaining > 0
     group by batch.expires_at
     order by batch.expires_at
     limit 1
  ), credit_balance as (
    select greatest(coalesce(sum(ledger.amount_cents), 0), 0)::integer
      as balance_cents
      from public.credit_ledger ledger
     where ledger.business_id = p_business
       and ledger.client_id = p_client
  ), redemption_capability as (
    select (
      program.enabled
      and app.platform_feature_enabled('customer_qr_redemption')
      and coalesce(capability.redemption_enabled, false)
    ) as enabled
    from program
    left join public.business_customer_capabilities_v89 capability
      on capability.business_id = p_business
  ), candidate_rewards as (
    select
      'catalog'::text as source,
      reward_version.reward_id,
      reward_version.customer_name as name,
      reward_version.cost_points::integer as cost_units,
      reward_version.credit_cents::integer,
      reward_version.fulfillment_kind,
      reward_version.sort::integer as sort_order,
      greatest(reward_version.cost_points - loyalty_balance.units, 0)::integer
        as remaining_units,
      (redemption_capability.enabled
        and loyalty_balance.units >= reward_version.cost_points) as available_now
    from program
    cross join loyalty_balance
    cross join redemption_capability
    join public.loyalty_reward_versions reward_version
      on reward_version.business_id = p_business
     and reward_version.config_version_id = program.active_config_version_id
     and reward_version.active
    join public.loyalty_rewards reward
      on reward.id = reward_version.reward_id
     and reward.business_id = reward_version.business_id
     and reward.active
     and not reward.paused
    left join lateral (
      select count(*)::integer as used_count
        from public.loyalty_redemptions redemption
       where redemption.business_id = p_business
         and redemption.client_id = p_client
         and redemption.reward_id = reward_version.reward_id
    ) usage on true
    where program.enabled
      and (reward_version.claim_available_from is null
        or reward_version.claim_available_from <= v_as_of)
      and (reward_version.claim_available_until is null
        or reward_version.claim_available_until > v_as_of)
      and (reward_version.usage_limit is null
        or usage.used_count < reward_version.usage_limit)
      and not exists (
        select 1 from public.loyalty_reward_branches restriction
         where restriction.reward_version_id = reward_version.id
      )
      and not exists (
        select 1 from public.loyalty_reward_services restriction
         where restriction.reward_version_id = reward_version.id
      )
      and not exists (
        select 1 from public.loyalty_reward_products restriction
         where restriction.reward_version_id = reward_version.id
      )
  ), reward_list as (
    select coalesce(jsonb_agg(jsonb_build_object(
      'source', candidate.source,
      'reward_id', candidate.reward_id,
      'name', candidate.name,
      'cost_units', candidate.cost_units,
      'credit_cents', candidate.credit_cents,
      'fulfillment_kind', candidate.fulfillment_kind,
      'remaining_units', candidate.remaining_units,
      'available_now', candidate.available_now
    ) order by candidate.remaining_units, candidate.sort_order,
      lower(candidate.name), candidate.reward_id nulls first), '[]'::jsonb)
      as rewards
      from candidate_rewards candidate
  ), next_reward as (
    select jsonb_build_object(
      'source', candidate.source,
      'reward_id', candidate.reward_id,
      'name', candidate.name,
      'cost_units', candidate.cost_units,
      'credit_cents', candidate.credit_cents,
      'fulfillment_kind', candidate.fulfillment_kind,
      'remaining_units', candidate.remaining_units,
      'available_now', candidate.available_now
    ) as reward
    from candidate_rewards candidate
    order by candidate.remaining_units, candidate.sort_order,
      lower(candidate.name), candidate.reward_id nulls first
    limit 1
  )
  select jsonb_build_object(
    'as_of', v_as_of,
    'program', case when program.id is null then null else jsonb_build_object(
      'id', program.id,
      'active', program.enabled,
      'kind', program.kind,
      'model', program.loyalty_model,
      'unit', case when program.loyalty_model = 'stamps'
        then 'stamps' else 'points' end,
      'earn_points_per_dollar', program.earn_points_per_dollar,
      'stamp_per_cents', program.stamp_per_cents,
      'redeem_points', program.redeem_points,
      'reward_credit_cents', program.reward_credit_cents,
      'expiry_mode', program.expiry_mode,
      'configuration_status', program.configuration_status
    ) end,
    'points_balance', loyalty_balance.units,
    'credit_balance_cents', credit_balance.balance_cents,
    'expiry', case
      when not program.enabled or program.expiry_mode = 'none'
        or next_expiry.expires_at is null then null
      else jsonb_build_object(
        'expires_at', next_expiry.expires_at,
        'units', next_expiry.units
      ) end,
    'redemption_enabled', redemption_capability.enabled,
    'rewards', reward_list.rewards,
    'next_reward', next_reward.reward
  ) into v_result
  from program
  cross join loyalty_balance
  cross join credit_balance
  cross join redemption_capability
  cross join reward_list
  left join next_expiry on true
  left join next_reward on true;

  return v_result;
end;
$function$;


-- ------------------------------------------------------- app.redeem_points_v40_internal
CREATE OR REPLACE FUNCTION app.redeem_points_v40_internal(p_business uuid, p_client uuid, p_idempotency_key text)
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'app', 'pg_temp'
AS $function$
declare
  lp public.loyalty_programs%rowtype;
  bal integer;
  v_batch_balance integer;
  v_remaining integer;
  v_take integer;
  v_batch record;
  v_actor uuid := auth.uid();
  v_staff uuid;
  v_points_id uuid := gen_random_uuid();
  v_credit_id uuid := gen_random_uuid();
  v_operation_id uuid := gen_random_uuid();
  v_payload jsonb;
  v_operation public.loyalty_operations%rowtype;
  v_rows integer;
  v_result json;
  v_points_programme uuid;
begin
  -- v375: points are points, never store credit. This is the only route that ever converted a
  -- points balance into credit_ledger, and it is refused outright rather than left reachable.
  raise exception 'points are redeemed for gifts, not for store credit'
    using errcode = '22023';
  if p_idempotency_key is null or length(btrim(p_idempotency_key)) < 8 then
    raise exception 'idempotency key must contain at least 8 characters' using errcode = '22023';
  end if;
  p_idempotency_key := btrim(p_idempotency_key);
  if not app.has_perm(p_business, 'create_sales') then
    raise exception 'you do not have permission to redeem points in this business (create_sales)'
      using errcode = '42501';
  end if;
  perform 1 from public.businesses where id = p_business for share;

  select s.id into v_staff
    from public.staff s
   where s.business_id = p_business and s.user_id = v_actor and s.active
     and 'create_sales' = any (app.role_perms(s.role))
   order by case s.role when 'owner' then 0 when 'manager' then 1 else 2 end, s.created_at
   limit 1 for update;
  if not found or not app.has_perm(p_business, 'create_sales') then
    raise exception 'active staff authorization changed while redeeming points'
      using errcode = '42501';
  end if;

  perform 1 from public.clients c
   where c.id = p_client and c.business_id = p_business for update;
  if not found then raise exception 'client does not belong to this business'; end if;

  v_payload := jsonb_build_object('business_id', p_business, 'client_id', p_client);
  perform set_config('app.loyalty_operation_insert_id', v_operation_id::text, true);
  insert into public.loyalty_operations
    (id, business_id, client_id, operation_type, actor, idempotency_key,
     request_payload, request_hash)
  values
    (v_operation_id, p_business, p_client, 'redeem_points', v_actor,
     p_idempotency_key, v_payload, md5(v_payload::text))
  on conflict (business_id, operation_type, idempotency_key) do nothing;
  get diagnostics v_rows = row_count;
  perform set_config('app.loyalty_operation_insert_id', '', true);

  if v_rows = 0 then
    select * into v_operation from public.loyalty_operations
     where business_id = p_business and operation_type = 'redeem_points'
       and idempotency_key = p_idempotency_key
     for update;
    if v_operation.actor is distinct from v_actor
       or v_operation.request_payload is distinct from v_payload then
      raise exception 'idempotency key was already used for another redemption request'
        using errcode = '22023';
    end if;
    if v_operation.status = 'completed' then return v_operation.result::json; end if;
    raise exception 'matching redemption is still reserved; retry shortly' using errcode = '40001';
  end if;

  select * into lp from public.loyalty_programs
   where business_id = p_business and active and kind = 'points'
     and redeem_points > 0 and reward_credit_cents > 0 limit 1;
  if not found then
    raise exception 'no active redeemable points program with positive points and credit values';
  end if;
  if lp.loyalty_model is distinct from 'classic' then
    raise exception 'this business redeems points through its reward catalog; use redeem_reward';
  end if;

  select coalesce(sum(pl.points), 0)::integer into bal from public.points_ledger pl
   where pl.business_id = p_business and pl.client_id = p_client;
  if bal < lp.redeem_points then
    raise exception 'insufficient points: % < %', bal, lp.redeem_points;
  end if;
  v_points_programme := app.resolve_ledger_programme_v309(p_business);
  if v_points_programme is null then
    raise exception 'redemption programme is not resolvable for this business'
      using errcode = 'XX001';
  end if;
  select coalesce(sum(pb.remaining), 0)::integer into v_batch_balance
    from public.points_batches pb
   where pb.business_id = p_business and pb.client_id = p_client and pb.remaining > 0
     and pb.programme_id = v_points_programme;
  if v_batch_balance < lp.redeem_points then
    raise exception 'points batches % cannot prove redemption %', v_batch_balance, lp.redeem_points
      using errcode = 'check_violation';
  end if;

  v_remaining := lp.redeem_points;
  for v_batch in
    select pb.id, pb.remaining from public.points_batches pb
     where pb.business_id = p_business and pb.client_id = p_client and pb.remaining > 0
       and pb.programme_id = v_points_programme
     order by pb.expires_at nulls last, pb.earned_at, pb.id for update
  loop
    exit when v_remaining = 0;
    v_take := least(v_batch.remaining, v_remaining);
    update public.points_batches set remaining = remaining - v_take where id = v_batch.id;
    v_remaining := v_remaining - v_take;
  end loop;

  perform set_config('app.points_ledger_insert_id', v_points_id::text, true);
  perform set_config('app.points_ledger_write_scope', 'redeem_points', true);
  insert into public.points_ledger
    (id, business_id, client_id, entry_type, points, reference, actor, programme_id)
  values
    (v_points_id, p_business, p_client, 'redeem', -lp.redeem_points,
     'redeemed to credit', v_actor, v_points_programme);
  perform set_config('app.points_ledger_insert_id', '', true);
  perform set_config('app.points_ledger_write_scope', '', true);

  perform set_config('app.credit_ledger_insert_id', v_credit_id::text, true);
  perform set_config('app.credit_ledger_write_scope', 'redeem_points', true);
  insert into public.credit_ledger
    (id, business_id, client_id, entry_type, amount_cents, reference, actor)
  values
    (v_credit_id, p_business, p_client, 'loyalty_earn', lp.reward_credit_cents,
     'points redemption', v_actor);
  perform set_config('app.credit_ledger_insert_id', '', true);
  perform set_config('app.credit_ledger_write_scope', '', true);

  v_result := json_build_object(
    'points_spent', lp.redeem_points,
    'credit_cents', lp.reward_credit_cents
  );
  perform set_config('app.loyalty_operation_complete_id', v_operation_id::text, true);
  update public.loyalty_operations
     set status = 'completed', result = v_result::jsonb, completed_at = now()
   where id = v_operation_id;
  perform set_config('app.loyalty_operation_complete_id', '', true);
  return v_result;
end $function$;

-- Grants restated verbatim from production (CREATE OR REPLACE preserves them; these make the
-- privilege surface explicit and re-derivable on a fresh database). Note redeem_points_v40_internal
-- holds no `authenticated` grant and gains none here -- the browser has never been able to call it.
revoke all on function public.staff_get_customer_actionable_loyalty_v145(uuid,uuid,uuid) from public, anon;
grant execute on function public.staff_get_customer_actionable_loyalty_v145(uuid,uuid,uuid) to postgres, service_role, authenticated;
revoke all on function app.redeem_points_v40_internal(uuid,uuid,text) from public, anon;
grant execute on function app.redeem_points_v40_internal(uuid,uuid,text) to postgres, service_role;

commit;
