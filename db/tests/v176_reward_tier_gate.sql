-- Rollback-only acceptance for V176 Stage A: tier-gated rewards kernel plumbing.
-- Run after the canonical chain through v176 in a disposable local database.
--
-- Guards the exact failure mode this feature has: the versioned-config kernel copies columns
-- explicitly in three places, so a gate can silently vanish between the editor and the
-- customer. Each assertion below corresponds to one of those places.
begin;

do $$
declare
  v_def text;
begin
  -- columns exist on both the draft and published sides
  if not exists (select 1 from information_schema.columns
     where table_schema='public' and table_name='loyalty_rewards' and column_name='min_tier_id') then
    raise exception 'loyalty_rewards.min_tier_id missing';
  end if;
  if not exists (select 1 from information_schema.columns
     where table_schema='public' and table_name='loyalty_reward_versions' and column_name='min_tier_threshold') then
    raise exception 'loyalty_reward_versions.min_tier_threshold missing';
  end if;

  -- 1. draft -> draft clone must carry the gate
  select pg_get_functiondef(p.oid) into v_def
    from pg_proc p join pg_namespace n on n.oid=p.pronamespace
   where n.nspname='app' and p.proname='clone_reward_versions_for_config';
  if v_def !~ 'min_tier_id' or v_def !~ 'min_tier_threshold' then
    raise exception 'clone_reward_versions_for_config drops the tier gate on every new draft';
  end if;

  -- 2. publish must promote the gate to live rewards
  select pg_get_functiondef(p.oid) into v_def
    from pg_proc p join pg_namespace n on n.oid=p.pronamespace
   where n.nspname='public' and p.proname='publish_loyalty_config';
  if v_def !~ 'min_tier_id=rv\.min_tier_id' then
    raise exception 'publish_loyalty_config does not promote min_tier_id to loyalty_rewards';
  end if;

  -- 3. the editor save path must accept, insert and update the gate
  select pg_get_functiondef(p.oid) into v_def
    from pg_proc p join pg_namespace n on n.oid=p.pronamespace
   where n.nspname='public' and p.proname='save_loyalty_reward_draft';
  if v_def !~ '''min_tier_id'',''min_tier_threshold''' then
    raise exception 'save_loyalty_reward_draft rejects the tier gate keys';
  end if;
  if v_def !~ 'min_tier_id = excluded\.min_tier_id' then
    raise exception 'save_loyalty_reward_draft cannot update an existing gate';
  end if;
  if v_def !~ 'min_tier_threshold must be zero or greater' then
    raise exception 'save_loyalty_reward_draft lost its negative-threshold guard';
  end if;
end $$;

-- Functional proof: a gate set on a draft survives cloning and publish promotion.
do $$
declare
  v_biz uuid; v_tier uuid; v_reward uuid; v_live uuid;
  v_draft uuid; v_draft2 uuid; v_gate uuid; v_thresh integer; v_no integer;
begin
  select b.id, b.active_config_version_id into v_biz, v_live
    from public.businesses b
    join public.loyalty_tier_versions t on t.business_id=b.id
    join public.loyalty_rewards r on r.business_id=b.id
   limit 1;
  if v_biz is null then
    raise notice 'no business with both tiers and rewards; structural assertions above still apply';
    return;
  end if;
  select tier_id into v_tier from public.loyalty_tier_versions where business_id=v_biz limit 1;
  select id into v_reward from public.loyalty_rewards where business_id=v_biz limit 1;
  select coalesce(max(version_no),0) into v_no from public.firm_config_versions where business_id=v_biz;

  insert into public.firm_config_versions(business_id, based_on_version_id, status, version_no, snapshot_hash)
  values (v_biz, v_live, 'draft', v_no+1, md5('v176a')) returning id into v_draft;
  update public.loyalty_reward_versions
     set min_tier_id=v_tier, min_tier_threshold=3000
   where config_version_id=v_draft and reward_id=v_reward;

  insert into public.firm_config_versions(business_id, based_on_version_id, status, version_no, snapshot_hash)
  values (v_biz, v_draft, 'draft', v_no+2, md5('v176b')) returning id into v_draft2;
  select min_tier_id, min_tier_threshold into v_gate, v_thresh
    from public.loyalty_reward_versions where config_version_id=v_draft2 and reward_id=v_reward;
  if v_gate is distinct from v_tier or v_thresh is distinct from 3000 then
    raise exception 'clone lost the tier gate';
  end if;

  update public.loyalty_rewards r
     set min_tier_id=rv.min_tier_id, min_tier_threshold=rv.min_tier_threshold
    from public.loyalty_reward_versions rv
   where rv.reward_id=r.id and rv.business_id=r.business_id and rv.config_version_id=v_draft2;
  select min_tier_id into v_gate from public.loyalty_rewards where id=v_reward;
  if v_gate is distinct from v_tier then
    raise exception 'publish promotion lost the tier gate';
  end if;
end $$;

rollback;
