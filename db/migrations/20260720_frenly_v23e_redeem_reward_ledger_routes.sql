-- FRENLY v23e — route redeem_reward through the sanctioned ledger write-guard (final correct body).
-- Applied migration name: frenly_v23e_redeem_reward_ledger_routes
--
-- points_ledger and credit_ledger are protected by app.loyalty_ledger_write_guard, which only
-- accepts an insert whose id matches a session token AND whose scope + row shape match an approved
-- route. redeem_reward must therefore mirror public.redeem_points exactly:
--   * points spend: scope 'redeem_points', entry_type 'redeem', points < 0, sale_id null.
--   * credit grant: scope 'redeem_points', entry_type 'loyalty_earn', amount > 0, sale_id/payment_id
--     null, actor = auth.uid().
-- A zero-credit reward (pure points burn) skips the credit insert. Anon is re-revoked (public
-- create-or-replace re-applies the anon default). p_idempotency_key is reserved for future use;
-- like redeem_points, the ledger writes are not idempotency-keyed here.

begin;

create or replace function public.redeem_reward(p_business uuid, p_client uuid, p_reward uuid, p_idempotency_key text default null)
returns json language plpgsql security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp' as $$
declare
  v_reward public.loyalty_rewards%rowtype;
  v_balance integer;
  v_actor uuid := auth.uid();
  v_points_id uuid := gen_random_uuid();
  v_credit_id uuid := gen_random_uuid();
begin
  if not app.has_perm(p_business, 'create_sales') then
    raise exception 'not authorized to redeem loyalty rewards' using errcode = '42501';
  end if;
  select * into v_reward from public.loyalty_rewards where id = p_reward and business_id = p_business and active;
  if not found then raise exception 'reward not found or inactive'; end if;

  select coalesce(sum(points),0) into v_balance from public.points_ledger
    where business_id = p_business and client_id = p_client;
  if v_balance < v_reward.cost_points then
    raise exception 'insufficient points: % < %', v_balance, v_reward.cost_points using errcode = 'check_violation';
  end if;

  -- spend points via the approved 'redeem_points' route
  perform set_config('app.points_ledger_insert_id', v_points_id::text, true);
  perform set_config('app.points_ledger_write_scope', 'redeem_points', true);
  insert into public.points_ledger (id, business_id, client_id, entry_type, points, reference, actor)
    values (v_points_id, p_business, p_client, 'redeem', -v_reward.cost_points, 'reward: ' || v_reward.name, v_actor);
  perform set_config('app.points_ledger_insert_id', '', true);
  perform set_config('app.points_ledger_write_scope', '', true);

  -- grant store credit via the approved 'redeem_points' route (loyalty_earn), if the reward is worth credit
  if v_reward.credit_cents > 0 then
    perform set_config('app.credit_ledger_insert_id', v_credit_id::text, true);
    perform set_config('app.credit_ledger_write_scope', 'redeem_points', true);
    insert into public.credit_ledger (id, business_id, client_id, entry_type, amount_cents, reference, actor)
      values (v_credit_id, p_business, p_client, 'loyalty_earn', v_reward.credit_cents, 'loyalty reward: ' || v_reward.name, v_actor);
    perform set_config('app.credit_ledger_insert_id', '', true);
    perform set_config('app.credit_ledger_write_scope', '', true);
  end if;

  insert into public.loyalty_redemptions (business_id, client_id, reward_id, reward_name, points_spent, credit_cents, actor)
    values (p_business, p_client, v_reward.id, v_reward.name, v_reward.cost_points, v_reward.credit_cents, v_actor);

  return json_build_object('ok', true, 'reward', v_reward.name, 'points_spent', v_reward.cost_points, 'credit_cents', v_reward.credit_cents);
end $$;

revoke all on function public.redeem_reward(uuid, uuid, uuid, text) from public, anon;
grant execute on function public.redeem_reward(uuid, uuid, uuid, text) to authenticated;

commit;
