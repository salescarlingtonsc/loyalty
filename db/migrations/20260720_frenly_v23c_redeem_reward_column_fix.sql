-- FRENLY v23c — fix redeem_reward's points_ledger insert (column name) + re-assert ACL.
-- Applied migration name: frenly_v23c_redeem_reward_column_fix
--
-- v23/v23b wrote points_ledger(..., reason) but that column is `reference` (points_ledger has:
-- business_id, client_id, entry_type, points, sale_id, reference, actor). Corrected, and `actor`
-- is now recorded on the points spend. As with every public create-or-replace, anon is re-revoked
-- to preserve the v21 invariant. This is the final redeem_reward body; the v23 source file matches.

begin;

create or replace function public.redeem_reward(p_business uuid, p_client uuid, p_reward uuid, p_idempotency_key text default null)
returns json language plpgsql security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp' as $$
declare v_reward public.loyalty_rewards%rowtype; v_balance integer; v_actor uuid := auth.uid(); v_credit_id uuid;
begin
  if not app.has_perm(p_business, 'create_sales') then
    raise exception 'not authorized to redeem loyalty rewards' using errcode = '42501';
  end if;
  select * into v_reward from public.loyalty_rewards where id = p_reward and business_id = p_business and active;
  if not found then raise exception 'reward not found or inactive'; end if;
  select coalesce(sum(points),0) into v_balance from public.points_ledger
    where business_id = p_business and client_id = p_client;
  if v_balance < v_reward.cost_points then
    raise exception 'insufficient points: have %, reward costs %', v_balance, v_reward.cost_points using errcode = 'check_violation';
  end if;
  insert into public.points_ledger (business_id, client_id, entry_type, points, reference, actor)
    values (p_business, p_client, 'redeem', -v_reward.cost_points, 'reward: ' || v_reward.name, v_actor);
  v_credit_id := gen_random_uuid();
  insert into public.credit_ledger (id, business_id, client_id, entry_type, amount_cents, reference, actor, idempotency_key)
    values (v_credit_id, p_business, p_client, 'manual_adjust', v_reward.credit_cents, 'loyalty reward: ' || v_reward.name, v_actor, p_idempotency_key)
    on conflict (business_id, idempotency_key) where idempotency_key is not null do nothing;
  insert into public.loyalty_redemptions (business_id, client_id, reward_id, reward_name, points_spent, credit_cents, actor)
    values (p_business, p_client, v_reward.id, v_reward.name, v_reward.cost_points, v_reward.credit_cents, v_actor);
  return json_build_object('ok', true, 'reward', v_reward.name, 'points_spent', v_reward.cost_points, 'credit_cents', v_reward.credit_cents);
end $$;

revoke all on function public.redeem_reward(uuid, uuid, uuid, text) from public, anon;
grant execute on function public.redeem_reward(uuid, uuid, uuid, text) to authenticated;

commit;
