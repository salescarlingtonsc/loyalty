-- Rollback-only acceptance for V176 Stage B: tier-gate read path and enforcement.
-- Mirrors the run executed against production on 2026-08-06.
--
-- The structural block guards the two ways this feature rots silently:
--   * the guard drifting BELOW the balance check, which would make a locked reward report
--     "not enough points" — a misleading refusal that sends owners hunting the wrong bug;
--   * the resolver being inlined at one call site, letting the customer badge and the counter
--     disagree about whether a reward is locked.
begin;

do $$
declare v_def text;
begin
  if to_regprocedure('app.v176_reward_gate_threshold(uuid,uuid,integer)') is null then
    raise exception 'shared gate resolver missing';
  end if;
  if to_regprocedure('app.v176_tier_gate_metric(uuid,uuid)') is null then
    raise exception 'shared tier metric missing';
  end if;

  select pg_get_functiondef(p.oid) into v_def
    from pg_proc p join pg_namespace n on n.oid=p.pronamespace
   where n.nspname='app' and p.proname='redeem_reward_core';
  if v_def !~ 'reward requires a higher membership tier' then
    raise exception 'redemption does not enforce the tier gate — display-only gating is not a gate';
  end if;
  if position('reward requires a higher membership tier' in v_def)
     > position('insufficient proven points' in v_def) then
    raise exception 'tier gate must be checked before the balance check, or the refusal misleads';
  end if;

  select pg_get_functiondef(p.oid) into v_def
    from pg_proc p join pg_namespace n on n.oid=p.pronamespace
   where n.nspname='public' and p.proname='customer_get_reward_catalog';
  if v_def !~ 'tier_locked' then
    raise exception 'catalog has no tier_locked state';
  end if;
  if v_def !~ 'tier_requirement' then
    raise exception 'catalog does not tell the member which tier they need';
  end if;
  if v_def !~ 'v176_reward_gate_threshold' then
    raise exception 'catalog resolves the gate independently of the redemption guard';
  end if;

  select pg_get_functiondef(p.oid) into v_def
    from pg_proc p join pg_namespace n on n.oid=p.pronamespace
   where n.nspname='public' and p.proname='get_loyalty_reward_draft';
  if v_def !~ 'min_tier_id' or v_def !~ 'min_tier_threshold' then
    raise exception 'owner editor cannot read back the gate it saved';
  end if;
end $$;

-- Resolver semantics, without needing a seeded member.
do $$
declare
  v_biz uuid; v_tier uuid; v_thresh integer;
begin
  select t.business_id, t.id, t.threshold into v_biz, v_tier, v_thresh
    from public.loyalty_tiers t where t.threshold > 0 limit 1;
  if v_biz is null then
    raise notice 'no tiers present; structural assertions above still apply';
    return;
  end if;

  -- a live tier wins over the stored fallback, so the gate follows a later threshold edit
  if app.v176_reward_gate_threshold(v_biz, v_tier, 99999) is distinct from v_thresh then
    raise exception 'resolver did not prefer the live tier threshold';
  end if;
  -- a deleted tier must TIGHTEN to the stored value, never open the gate
  if app.v176_reward_gate_threshold(v_biz, gen_random_uuid(), 99999) is distinct from 99999 then
    raise exception 'an unresolvable tier opened the gate';
  end if;
  -- and no gate means no gate
  if app.v176_reward_gate_threshold(v_biz, null, null) is not null then
    raise exception 'an ungated reward reported a gate';
  end if;
end $$;

rollback;
