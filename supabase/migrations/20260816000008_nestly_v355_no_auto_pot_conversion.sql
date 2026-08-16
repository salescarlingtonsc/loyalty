-- V355: a programme switch must NEVER convert one programme's balance into another's.
--
-- OWNER RULING 2026-08-16, verbatim: "i just want to ensure that the points doesn't flow to become
-- stamps, if points is off - it will be switch off and show no. of stamps. not conveniently
-- convert all the points into stamps (as shown in the photo)."
--
-- WHAT WAS ACTUALLY HAPPENING (this is a real data movement, not only a label):
-- V312 shipped app.enqueue_programme_pot_migration_v312, which moves every client's balance out of
-- the outgoing programme's pot and into the incoming one whenever a firm switches points <-> stamps.
-- It fired from TWO places, both of which an ordinary owner could trip just by using a switch:
--   1. an explicit call inside public.set_programmes_v314, and
--   2. trigger trg_programme_pot_switch_v312 on public.loyalty_programs, on any UPDATE that flips
--      loyalty_model into or out of 'stamps'.
-- Cubbly's programme_pot_migrations rows show it running FOUR times inside ninety seconds
-- (08:27:13 points->stamps, 08:55:09 stamps->points, 08:55:33 points->stamps, 08:55:37
-- stamps->points), 3 clients each. That is why a 75,877 POINT balance surfaced to the customer as
-- 75,877 STAMPS -- a unit they had never earned, at a 1:1 rate nobody chose.
--
-- V312's intent was benign (its comments call the alternative "a stranded points pot"), but the
-- owner's ruling settles the trade-off the other way, and the data model already supports it:
-- points_ledger.programme_id and points_batches.programme_id keep the two pots separate rows, and
-- app.on_sale_recorded already loops over the active accruing spine rows writing one ledger entry
-- per programme_id. Keeping the pots apart is therefore the DEFAULT behaviour of every other part
-- of the system -- V312's migration was the only thing merging them.
--
-- THIS MIGRATION:
--   1. removes the enqueue call from set_programmes_v314 (otherwise byte-identical to the live
--      V354 version, including V354's own spine->loyalty_model sync), and
--   2. drops trg_programme_pot_switch_v312, closing the second path -- which matters especially
--      because V354 made set_programmes_v314 itself write loyalty_model, so that trigger would
--      now fire on ordinary switches as well.
-- Nothing is dropped that anything else calls: a live catalogue check confirmed the ONLY two
-- callers of enqueue_programme_pot_migration_v312 are the two removed here. The migration
-- machinery itself (public.programme_pot_migrations, app.migrate_programme_pot_v312,
-- app.run_programme_pot_migrations_v312, and the enqueue function) is deliberately LEFT INTACT and
-- callable, so a deliberate super-admin-initiated move is still possible; it is simply never again
-- triggered automatically by an owner flipping a switch.
--
-- NO BACKFILL, DELIBERATELY. The four completed migrations are append-only ledger history and are
-- not rewritten here. Cubbly's live distribution was verified after the fact: points pot 76,222 /
-- stamps pot 0, with points the active programme -- the round trip happened to end where it began,
-- so there is nothing to restore. Reversing historical ledger rows would be a fresh set of
-- balance-changing writes to fix a balance that is already correct.
--
-- APPLIED 2026-08-16 to gadpooereceldfpfxsod (rolled-back dry run first; see VERIFICATION below).

begin;

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

  -- V355: THE POT MIGRATION IS GONE FROM THIS PATH, DELIBERATELY.
  -- Owner ruling 2026-08-16: "i just want to ensure that the points doesn't flow to become
  -- stamps, if points is off - it will be switch off and show no. of stamps. not conveniently
  -- convert all the points into stamps." V312 used to move every client's balance from the
  -- outgoing programme's pot into the incoming one on a points<->stamps switch, so a firm that
  -- toggled the stamp card on saw 75,877 POINTS reappear as 75,877 STAMPS -- a unit the customer
  -- never earned. Cubbly's own trail shows it firing four times in ninety seconds of toggling.
  -- points_ledger.programme_id already keeps the two pots apart; leaving them apart IS the fix.
  -- A programme that is switched off now simply parks its pot untouched, and the customer sees
  -- only the live programme's own balance, which is what "turned off" should mean. The machinery
  -- (programme_pot_migrations, app.migrate_programme_pot_v312, run_programme_pot_migrations_v312)
  -- is intentionally left in place and callable for a deliberate, super-admin-initiated move --
  -- it is only no longer fired automatically by an owner flipping a switch.
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


-- Re-state the ACL on the exact overload. CREATE OR REPLACE preserves the existing grants, so this
-- is belt-and-braces at run time — but it is REQUIRED governance: every pending migration that
-- defines a public SECURITY DEFINER RPC must be readable on its own as revoking PostgreSQL's
-- default PUBLIC execute grant, rather than depending on a previous migration having done it.
revoke all privileges on function public.set_programmes_v314(uuid,jsonb,uuid) from public, anon;
grant execute on function public.set_programmes_v314(uuid,jsonb,uuid) to authenticated;

drop trigger if exists trg_programme_pot_switch_v312 on public.loyalty_programs;

-- ============================================================================================
-- VERIFICATION (rolled-back transaction against production before applying for real)
-- ============================================================================================
-- Verified 2026-08-16 inside a rolled-back transaction against gadpooereceldfpfxsod, on Cubbly
-- (points pot 76,222 / stamps pot 0, points+tiers live):
--   1. switch points -> stamps via set_programmes_v314: NO new programme_pot_migrations row, and
--      the points pot still holds 76,222 while the stamps pot still holds 0 -- the balance stayed
--      where it was earned instead of being converted.
--   2. switch back stamps -> points: still no migration row, both pots still unchanged.
--   3. loyalty_model/kind still track the spine correctly across both switches (V354's sync is
--      preserved -- 'stamps'/'stamps' then 'classic'/'points').
--   4. trg_programme_pot_switch_v312 confirmed absent from public.loyalty_programs afterwards.
commit;
