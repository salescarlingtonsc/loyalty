-- Rollback-only acceptance for V197: the recommendation cannot duplicate a reward.
begin;
do $$
declare v_def text;
begin
  -- 1. the seed only fires when the draft has no active reward
  select pg_get_functiondef(p.oid) into v_def from pg_proc p join pg_namespace n on n.oid=p.pronamespace
   where n.nspname='public' and p.proname='generate_retention_recommendation';
  if v_def is null then raise exception 'generate_retention_recommendation missing'; end if;
  if v_def !~ 'config_version_id = v_draft_id' then
    raise exception 'the recommendation still seeds a reward unconditionally; duplicates will return';
  end if;

  -- 2. a new draft starts from the LIVE catalogue, so a retired reward stays retired
  select pg_get_functiondef(p.oid) into v_def from pg_proc p join pg_namespace n on n.oid=p.pronamespace
   where n.nspname='app' and p.proname='clone_reward_versions_for_config';
  if v_def !~ 'coalesce\(live\.active, source\.active\)' then
    raise exception 'the clone copies a stale active flag; publish would resurrect retired rewards';
  end if;
  if v_def !~ 'left join public\.loyalty_rewards live' then
    raise exception 'the clone no longer consults the live catalogue';
  end if;
end $$;

-- Published reward versions must remain immutable: the fix must never rewrite history.
do $$
begin
  if not exists (select 1 from pg_trigger t join pg_proc p on p.oid=t.tgfoid
                  where p.proname='reward_version_immutable_guard' and not t.tgisinternal) then
    raise exception 'the published-version immutability guard is gone';
  end if;
end $$;
rollback;
