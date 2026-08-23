-- nestly_v477 — a gift can say, in the owner's own words, where it works.
--
-- OWNER (photo 3, the customer's REWARD RULES sheet, ruling 2026-08-23): "for the where it works
-- and what it gets: it should be typed in settings. default is your wordings and can be
-- customised". Asked where, the owner chose PER GIFT, in the gift editor — different gifts
-- genuinely differ, and a free lotion and a free facial do not work in the same places.
--
-- WHAT YOU GET needed no schema at all: that row already prints the gift's own `description`,
-- which the Point system editor has always exposed. The owner confirmed it is the same field, so
-- it is relabelled in the editor (browser side) and the data is untouched.
--
-- WHERE IT WORKS had no field to type into. It was DERIVED — a count of restricted
-- branches/services/products, or the fallback "Valid across all eligible services and locations."
-- That sentence stays as the default; this adds somewhere to override it.
--
-- WHY NOT app.reward_availability_v432: it is a TABLE-returning function, so adding a column means
-- DROP and recreate, and everything resolving it by name would need recreating with it (the
-- standing "dropping SQL objects breaks callers silently" rule). customer_get_reward_catalog is a
-- jsonb builder that already carries core.reward_version_id, so it fetches the one extra column
-- itself and no signature changes shape.
--
-- THE LANDMINE, again: app.reward_version_immutable_guard's hardcoded allowlist. Widened for
-- claim_available_until in v472; without where_it_works here EVERY gift edit would raise
-- restrict_violation, because the writer sets the column on every call. Proved in the dry run —
-- the seed UPDATE was refused with 23001 until the allowlist was widened.
--
-- Verified before applying, rolled back: the custom text reaches customer_get_reward_catalog for
-- the gift it was set on, and a gift without one stays null so the default sentence still applies.

begin;

-- 1. The column, on the live row and on the versioned copy the customer is actually served from.
alter table public.loyalty_rewards add column if not exists where_it_works text;
alter table public.loyalty_reward_versions add column if not exists where_it_works text;

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'loyalty_rewards_where_it_works_len') then
    alter table public.loyalty_rewards
      add constraint loyalty_rewards_where_it_works_len
      check (where_it_works is null or length(where_it_works) <= 280);
  end if;
  if not exists (select 1 from pg_constraint where conname = 'loyalty_reward_versions_where_it_works_len') then
    alter table public.loyalty_reward_versions
      add constraint loyalty_reward_versions_where_it_works_len
      check (where_it_works is null or length(where_it_works) <= 280);
  end if;
end $$;

comment on column public.loyalty_rewards.where_it_works is
  'nestly_v477. The owner''s own sentence for the customer rules sheet''s "Where it works" row. '
  'NULL means the app''s derived wording is used, which is what every gift starts with.';

-- 2. The guard learns the column BEFORE any writer can set it.
do $outer$
declare
  v_src text;
  v_old constant text := $marker$    'claim_available_until'];$marker$;
  v_new constant text := $marker$    'claim_available_until','where_it_works'];$marker$;
begin
  select pg_get_functiondef(p.oid) into v_src from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'app' and p.proname = 'reward_version_immutable_guard';
  if position(v_old in v_src) = 0 then
    raise exception 'reward_version_immutable_guard allowlist has moved; widen it by hand' using errcode='XX001';
  end if;
  execute replace(v_src, v_old, v_new);
end $outer$;

-- 3. The two Point-system writers carry it. Patched in place with asserted markers rather than
-- restated: these are ~8KB bodies this change touches a handful of lines of.
-- NOTE the new parameter goes at the END of each signature. On the update function it must follow
-- p_clear_end_date, not p_claim_available_until — appending after the timestamp put it in the
-- middle and left the grant below naming a signature that did not exist.
do $outer$
declare
  v_src text; v_out text;
  v_ts constant text := 'p_claim_available_until timestamp with time zone DEFAULT NULL::timestamp with time zone';
  v_tail constant text := 'p_clear_end_date boolean DEFAULT false';
begin
  -- CREATE: the timestamp IS the last parameter, so appending after it is appending at the end.
  select pg_get_functiondef(p.oid) into v_src from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'business_create_reward_v326';
  if position(v_ts in v_src) = 0 then raise exception 'create signature marker gone' using errcode='XX001'; end if;
  v_out := replace(v_src, v_ts, v_ts || ', p_where_it_works text DEFAULT NULL::text');
  v_out := replace(v_out,
    'estimated_cost_cents,active,paused,sort,programme_id,current_config_version_id,claim_available_until',
    'estimated_cost_cents,active,paused,sort,programme_id,current_config_version_id,claim_available_until,where_it_works');
  v_out := replace(v_out,
    'coalesce(p_credit_cents,0),true,false,v_sort,p_programme,v_target,p_claim_available_until',
    'coalesce(p_credit_cents,0),true,false,v_sort,p_programme,v_target,p_claim_available_until,nullif(btrim(coalesce(p_where_it_works,'''')),'''')');
  v_out := replace(v_out,
    'cost_points,credit_cents,estimated_cost_cents,active,sort,programme_id,claim_available_until',
    'cost_points,credit_cents,estimated_cost_cents,active,sort,programme_id,claim_available_until,where_it_works');
  v_out := replace(v_out,
    'p_points,coalesce(p_credit_cents,0),coalesce(p_credit_cents,0),true,v_sort,p_programme,p_claim_available_until',
    'p_points,coalesce(p_credit_cents,0),coalesce(p_credit_cents,0),true,v_sort,p_programme,p_claim_available_until,nullif(btrim(coalesce(p_where_it_works,'''')),'''')');
  if v_out = v_src then raise exception 'create patch changed nothing' using errcode='XX001'; end if;
  execute v_out;

  -- UPDATE: append after the LAST parameter.
  select pg_get_functiondef(p.oid) into v_src from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'business_update_reward_v326';
  if position(v_tail in v_src) = 0 then raise exception 'update signature marker gone' using errcode='XX001'; end if;
  v_out := replace(v_src, v_tail, v_tail || ', p_where_it_works text DEFAULT NULL::text');
  -- Tri-state, the same shape as the image and the end date beside it: null means "say nothing",
  -- so an older bundle can never wipe wording the owner typed. An empty string is an explicit
  -- clear, which is how the field is emptied back to the default sentence.
  v_out := replace(v_out, '  v_end_date timestamptz;',
    '  v_end_date timestamptz;' || chr(10) || '  v_where text;');
  v_out := replace(v_out,
    '  select active_config_version_id into v_active_version' || chr(10) || '    from public.businesses where id=p_business for share;',
    '  v_where := case when p_where_it_works is null then v_row.where_it_works' || chr(10) ||
    '                  else nullif(btrim(p_where_it_works),'''') end;' || chr(10) || chr(10) ||
    '  select active_config_version_id into v_active_version' || chr(10) || '    from public.businesses where id=p_business for share;');
  -- All four SET lists (the live row, the split branch, the published branch, the draft resync).
  v_out := replace(v_out, 'claim_available_until=v_end_date', 'claim_available_until=v_end_date, where_it_works=v_where');
  -- And the "has this draft diverged?" comparison, so a draft carrying its own wording is left
  -- alone exactly as one carrying its own end date is.
  v_out := replace(v_out,
    '           and draft.claim_available_until is not distinct from v_published.claim_available_until',
    '           and draft.claim_available_until is not distinct from v_published.claim_available_until' || chr(10) ||
    '           and draft.where_it_works is not distinct from v_published.where_it_works');
  if v_out = v_src then raise exception 'update patch changed nothing' using errcode='XX001'; end if;
  execute v_out;
end $outer$;

revoke all on function public.business_create_reward_v326(uuid,uuid,text,integer,integer,text,text,timestamptz,text) from public, anon;
grant execute on function public.business_create_reward_v326(uuid,uuid,text,integer,integer,text,text,timestamptz,text) to authenticated, service_role;
revoke all on function public.business_update_reward_v326(uuid,uuid,text,integer,text,integer,text,boolean,timestamptz,boolean,text) from public, anon;
grant execute on function public.business_update_reward_v326(uuid,uuid,text,integer,text,integer,text,boolean,timestamptz,boolean,text) to authenticated, service_role;

-- The pre-v477 overloads go, or PostgREST answers PGRST203 to every caller. Dropped AFTER the
-- replacements exist. PostgREST resolves by NAMED argument, so the deployed bundle keeps working
-- against the new signature with the new parameter defaulted.
drop function if exists public.business_create_reward_v326(uuid,uuid,text,integer,integer,text,text,timestamptz);
drop function if exists public.business_update_reward_v326(uuid,uuid,text,integer,text,integer,text,boolean,timestamptz,boolean);

-- 4. The customer read carries it. core.reward_version_id is already in scope, so the catalogue
-- fetches the one column itself and app.reward_availability_v432 is untouched.
do $outer$
declare
  v_src text;
  v_old constant text := $marker$    'instructions', core.instructions,$marker$;
  v_new constant text := $marker$    'instructions', core.instructions,
    'where_it_works', (select rv.where_it_works from public.loyalty_reward_versions rv
                        where rv.id = core.reward_version_id),$marker$;
begin
  select pg_get_functiondef(p.oid) into v_src from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'customer_get_reward_catalog';
  if position(v_old in v_src) = 0 then
    raise exception 'customer_get_reward_catalog no longer has the instructions line this migration patches'
      using errcode='XX001';
  end if;
  execute replace(v_src, v_old, v_new);
end $outer$;

commit;
