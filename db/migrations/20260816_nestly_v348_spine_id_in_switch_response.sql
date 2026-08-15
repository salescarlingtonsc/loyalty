-- V348: set_programmes_v314's own response never included the spine row's `id` — only
-- kind/active/running_since/paused_since. app.js's rememberProgrammeSpineV314 (fixed client-side
-- in commit a1aec39, "preserve programme spine id for gifts") already reads `row.id` off this
-- response and OVERWRITES the whole S.programmes cache with it on every switch call — so every
-- time an owner flips ANY programme switch (including the new V347 "Set up Tier membership" CTA,
-- which calls this same RPC), every cached spine id gets nulled out, including 'points'. The next
-- "Save gift" then fails with "The points programme could not be found" because
-- growPointsSpineIdV326 reads that now-null id. a1aec39 only fixed HALF of the path (the client
-- read + the full-refresh RPC, refreshProgrammeSpineV314) — this RPC's own response was the other
-- half and was never touched. Byte-identical to the live function except the one added key.
--
-- APPLIED 2026-08-16 to gadpooereceldfpfxsod (rolled-back dry run confirmed the 'id' key appears
-- on every row, then applied for real and re-confirmed live with a harmless no-op switch call).

create or replace function public.set_programmes_v314(
  p_business uuid,
  p_switches jsonb,
  p_idempotency_key uuid
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare
  v_actor uuid := auth.uid();
  v_hash text;
  v_rows integer;
  v_existing public.programme_switch_operations_v314%rowtype;
  v_kind text;
  v_want boolean;
  v_before boolean;
  v_changes jsonb := '[]'::jsonb;
  v_result jsonb;
  v_points boolean;
  v_stamps boolean;
  v_points_before boolean;
  v_stamps_before boolean;
  v_from uuid;
  v_to uuid;
  v_migration uuid;
  v_after_points boolean;
  v_after_tiers boolean;
  v_after_stamps boolean;
begin
  if p_business is null or p_idempotency_key is null then
    raise exception 'business and idempotency key are required' using errcode = '22023';
  end if;
  if p_switches is null or jsonb_typeof(p_switches) <> 'object' then
    raise exception 'switches must be a JSON object' using errcode = '22023';
  end if;
  if jsonb_typeof(p_switches) = 'object' and exists (
    select 1 from jsonb_object_keys(p_switches) key
     where key not in ('points','tiers','stamps','referral')
  ) then
    raise exception 'switches may only name points, tiers, stamps or referral'
      using errcode = '22023';
  end if;
  if exists (
    select 1 from jsonb_each(p_switches) entry
     where jsonb_typeof(entry.value) <> 'boolean'
  ) then
    raise exception 'every switch must be true or false' using errcode = '22023';
  end if;
  if p_switches = '{}'::jsonb then
    raise exception 'at least one switch is required' using errcode = '22023';
  end if;

  if not app.c45_owner_loyalty_write(p_business) then
    raise exception 'owner loyalty configuration access required' using errcode = '42501';
  end if;

  v_hash := md5(p_business::text || ':' || (
    select coalesce(string_agg(key || '=' || (p_switches ->> key), ',' order by key), '')
      from jsonb_object_keys(p_switches) key
  ));

  insert into public.programme_switch_operations_v314
    (business_id, idempotency_key, actor, request_hash)
  values (p_business, p_idempotency_key, v_actor, v_hash)
  on conflict (business_id, idempotency_key) do nothing;
  get diagnostics v_rows = row_count;
  if v_rows = 0 then
    select * into strict v_existing from public.programme_switch_operations_v314
     where business_id = p_business and idempotency_key = p_idempotency_key
       for update;
    if v_existing.request_hash is distinct from v_hash then
      raise exception 'idempotency key conflicts with another programme switch'
        using errcode = '23505';
    end if;
    if v_existing.result is not null then
      return v_existing.result;
    end if;
    raise exception 'programme switch already in progress' using errcode = '55P03';
  end if;

  perform 1 from public.businesses target where target.id = p_business for update;
  if not found then
    raise exception 'business does not exist' using errcode = '42501';
  end if;

  select coalesce(bool_or(spine.active) filter (where spine.kind = 'points'), false),
         coalesce(bool_or(spine.active) filter (where spine.kind = 'stamps'), false)
    into v_points_before, v_stamps_before
    from public.business_programmes spine
   where spine.business_id = p_business;

  insert into public.business_programmes (business_id, kind, active, sort, activated_at)
  select p_business, model.kind, model.running,
         (case model.kind
            when 'points' then 1 when 'tiers' then 2 when 'stamps' then 3 when 'referral' then 4
          end)::smallint,
         case when model.running then now() end
    from app.business_programmes_v307(p_business) model
  on conflict (business_id, kind) do nothing;

  select coalesce((p_switches ->> 'points')::boolean,
                  bool_or(spine.active) filter (where spine.kind = 'points'), false),
         coalesce((p_switches ->> 'tiers')::boolean,
                  bool_or(spine.active) filter (where spine.kind = 'tiers'), false),
         coalesce((p_switches ->> 'stamps')::boolean,
                  bool_or(spine.active) filter (where spine.kind = 'stamps'), false)
    into v_after_points, v_after_tiers, v_after_stamps
    from public.business_programmes spine
   where spine.business_id = p_business;

  if v_after_stamps and (v_after_points or v_after_tiers) then
    raise exception 'The stamp card runs on its own. Turn Points & gifts and Tier membership off '
      'before turning the stamp card on, or turn the stamp card off to run points and tiers.'
      using errcode = '22023';
  end if;

  for v_kind, v_want in
    select entry.key, (entry.value)::boolean
      from jsonb_each_text(p_switches) entry
     order by case entry.key
                when 'points' then 1 when 'tiers' then 2 when 'stamps' then 3 else 4 end
  loop
    select spine.active into v_before
      from public.business_programmes spine
     where spine.business_id = p_business and spine.kind = v_kind
       for update;
    if not found then
      raise exception 'business % has no % programme row', p_business, v_kind
        using errcode = 'XX001';
    end if;
    if v_before is distinct from v_want then
      update public.business_programmes spine
         set active = v_want,
             activated_at = case when v_want and not spine.active then now()
                                 else spine.activated_at end,
             deactivated_at = case when spine.active and not v_want then now()
                                   else spine.deactivated_at end
       where spine.business_id = p_business and spine.kind = v_kind;
      v_changes := v_changes || jsonb_build_object('kind', v_kind, 'from', v_before, 'to', v_want);
      insert into public.audit_log (business_id, actor, action, entity, entity_id, detail)
      select p_business, v_actor, 'PROGRAMME_SWITCH_V314', 'business_programmes', spine.id,
             jsonb_build_object('kind', v_kind, 'from', v_before, 'to', v_want,
                                'source', 'set_programmes_v314')
        from public.business_programmes spine
       where spine.business_id = p_business and spine.kind = v_kind;
    end if;
  end loop;

  select coalesce(bool_or(spine.active) filter (where spine.kind = 'points'), false),
         coalesce(bool_or(spine.active) filter (where spine.kind = 'stamps'), false)
    into v_points, v_stamps
    from public.business_programmes spine
   where spine.business_id = p_business;

  if (v_points and not v_stamps and v_stamps_before and not v_points_before)
     or (v_stamps and not v_points and v_points_before and not v_stamps_before) then
    select spine.id into v_to from public.business_programmes spine
     where spine.business_id = p_business
       and spine.kind = case when v_points then 'points' else 'stamps' end;
    select spine.id into v_from from public.business_programmes spine
     where spine.business_id = p_business
       and spine.kind = case when v_points then 'stamps' else 'points' end;
    if v_from is not null and v_to is not null and exists (
      select 1 from public.points_ledger ledger
       where ledger.business_id = p_business and ledger.programme_id = v_from
       group by ledger.client_id having sum(ledger.points) <> 0
      union all
      select 1 from public.points_batches batch
       where batch.business_id = p_business and batch.programme_id = v_from
         and batch.remaining > 0
    ) then
      v_migration := app.enqueue_programme_pot_migration_v312(p_business, v_from, v_to);
    end if;
  end if;

  v_result := jsonb_build_object(
    'business_id', p_business,
    'changed', v_changes,
    'pot_migration_id', v_migration,
    'programmes', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', spine.id,
               'kind', spine.kind,
               'active', spine.active,
               'running_since', spine.activated_at,
               'paused_since', spine.deactivated_at) order by spine.sort)
        from public.business_programmes spine
       where spine.business_id = p_business), '[]'::jsonb));

  update public.programme_switch_operations_v314
     set result = v_result
   where business_id = p_business and idempotency_key = p_idempotency_key;

  return v_result;
end
$$;

-- ============================================================================================
-- VERIFICATION (rolled-back transaction against production before applying for real)
-- ============================================================================================
-- Verified 2026-08-16 inside a rolled-back transaction against gadpooereceldfpfxsod: called
-- set_programmes_v314 with a no-op switch (setting 'referral' to its own current value) on Cubbly
-- and confirmed the returned 'programmes' array now carries a non-null 'id' for every row,
-- matching the live business_programmes.id values queried separately in the same transaction.
