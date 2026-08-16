-- V354: make the programme SPINE the single source of truth for loyalty_programs.loyalty_model
--       / kind, and repair the one business left inconsistent by V353.
--
-- LIVE DEFECT THIS FIXES (owner-reported 2026-08-16: "when i turn on stamps, my points suddenly
-- converted to stamps (incorrect)"). Nothing was ever converted -- the points_ledger was untouched
-- and every balance is intact. What broke is the LABEL, and V353 (same day, mine) introduced it:
--
--   V353 added business_set_loyalty_model_v353 and had the client call it just BEFORE
--   set_programmes_v314, so "Set up Stamp Card system" became a non-atomic two-step:
--     1. write loyalty_programs.loyalty_model='stamps'   (declared model)
--     2. flip the business_programmes spine to stamps    (the actual engine gate)
--   Step 2 has its own idempotency/exclusivity machinery and an early `if(!isGrowCurrent())return`
--   in front of it, so the two can and did come apart. Worse: once step 1 has run, NOTHING ever
--   undoes it -- set_programmes_v314 does not touch loyalty_model, so an owner who later switches
--   the spine back to points keeps loyalty_model='stamps' permanently.
--
--   Cubbly's audit trail shows exactly that: loyalty_model.updated->'stamps' at 08:51:29, then the
--   owner toggled the spine back to points at 08:55:37 and tiers at 08:56:02. Final state: spine
--   points+tiers ON / stamps OFF, but loyalty_model still 'stamps'. The customer app derives its
--   unit word from that column, so a 75,877 POINT balance rendered as "75,877 stamps".
--
-- THE FIX, and why it belongs in the RPC rather than the client:
-- V314's own comments state the invariant plainly -- "the spine is now the ONLY gate the engine
-- reads: app.on_sale_recorded loops over active accruing spine rows". loyalty_model/kind are
-- downstream bookkeeping that several redemption paths still read (v89:1009, v326:307 both gate on
-- `kind<>'points' or loyalty_model<>'classic'`). Two writers for one fact is the defect; so the
-- spine switch itself now derives and writes them, in the SAME transaction as the switch, for
-- EVERY caller (owner page, wizard, publish routes) rather than only the one client path I fixed.
-- The client's separate business_set_loyalty_model_v353 call is removed alongside this migration.
--
-- Mapping (deliberately only two outcomes, matching PROGRAMME_SWITCHES_V314 and the redemption
-- guards above): stamps spine active -> ('stamps','stamps'); otherwise -> ('classic','points').
-- 'points_tiers' is not produced: it is vestigial (v23g backfilled every row to 'classic'), the
-- owner UI only ever tests `loyalty_model==='stamps'`, tiers are driven by the spine's own tiers
-- row, and the classic-points redemption guards REFUSE anything but 'classic'/'points' -- writing
-- 'points_tiers' here would silently disable classic redemption for tier-running firms.
-- Only ever UPDATEs an existing row: a business with no loyalty_programs row has no configured
-- programme, and inventing one here would create a half-configured firm as a side effect.

-- 1. The sync, appended to set_programmes_v314 immediately before it builds its result. Everything
--    else in this function is byte-identical to the live V348 version.
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
  v_model text;
  v_program_kind text;
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

  -- V354: the spine has just moved, so the declared model follows it, in this same transaction.
  -- Without this the two disagree the moment an owner switches back (the live defect above).
  v_model := case when v_stamps then 'stamps' else 'classic' end;
  v_program_kind := case when v_stamps then 'stamps' else 'points' end;
  update public.loyalty_programs
     set loyalty_model = v_model, kind = v_program_kind
   where business_id = p_business
     and (loyalty_model is distinct from v_model or kind is distinct from v_program_kind);
  if found then
    insert into public.audit_log(business_id, actor, action, entity, entity_id, detail)
    values (p_business, v_actor, 'loyalty_model.synced_to_spine', 'loyalty_programs', p_business,
      jsonb_build_object('loyalty_model', v_model, 'kind', v_program_kind,
                         'source', 'set_programmes_v314'));
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

-- 2. Repair every business already left inconsistent (Cubbly is the only one, but this is written
--    as a set-based reconciliation so it is correct whatever the audit missed). Same mapping as
--    above, derived from each firm's own live spine.
update public.loyalty_programs lp
   set loyalty_model = case when spine.stamps_on then 'stamps' else 'classic' end,
       kind          = case when spine.stamps_on then 'stamps' else 'points' end
  from (
    select business_id,
           coalesce(bool_or(active) filter (where kind = 'stamps'), false) as stamps_on
      from public.business_programmes group by business_id
  ) spine
 where spine.business_id = lp.business_id
   and (lp.loyalty_model is distinct from (case when spine.stamps_on then 'stamps' else 'classic' end)
     or lp.kind          is distinct from (case when spine.stamps_on then 'stamps' else 'points' end));

-- ============================================================================================
-- VERIFICATION (rolled-back transaction against production before applying for real)
-- ============================================================================================
-- Verified 2026-08-16 inside a rolled-back transaction against gadpooereceldfpfxsod:
--   1. Cubbly before: spine points+tiers ON / stamps OFF, loyalty_model='stamps', kind='stamps'
--      (the reported defect). After the reconciliation UPDATE: loyalty_model='classic',
--      kind='points' -- matching its spine, so the customer app labels points as points again.
--   2. No other business row changed (the UPDATE's WHERE clause is a no-op for consistent firms).
--   3. Switching Cubbly's spine to stamps via set_programmes_v314 -> loyalty_model/kind both
--      become 'stamps' in the same call; switching back to points -> both return to
--      'classic'/'points'. The drift that caused the defect is no longer reachable.
--   4. points_ledger untouched throughout -- confirmed the balance total is identical before and
--      after, in the same transaction (this migration never touches a ledger).
