-- nestly_v489 — a completed stamp card rolls over on its own
-- (owner, photo 2: "it should auto reset to new stamp card once 15 stamp is hit. and any excess
--  stamps will flow to new card"; Sol review bypassed on the owner's explicit instruction)
--
-- WHAT WAS WRONG. app.stamp_progress_v323 computes filled = net_stamps - closed_slots, where
-- closed_slots is the sum of public.stamp_cycles.slots. A cycle was only ever closed by two
-- things: redeeming the FINAL milestone (app.redeem_reward_core, origin 'claimed') or the card
-- lapsing (app.stamp_expire_open_cycle_v435, origin 'expired'). NOTHING closed a cycle when the
-- customer simply reached the target, so a 15-slot card sat full for ever — the owner's own
-- screenshot shows 15/15 plus "2 already counted toward your next card", which is the carry-over
-- arithmetic working perfectly behind a card that would not roll.
--
-- So the carry-over needed no work at all. Only the close was missing.
--
-- THE CLOSE. app.stamp_complete_full_cycle_v489 closes the cycle with slots = THE TARGET, not
-- with the filled count. That single choice is what makes the excess flow: v435 closes an expired
-- card with `filled`, which drives filled to 0 because a lapsed card forfeits everything; closing
-- a COMPLETED card with the target leaves filled - target on the new card. A customer on 17
-- stamps against a 15-slot card lands on 2/15, exactly as the owner asked.
-- It loops (bounded at 20) so a customer who ran up two full cards' worth without redeeming gets
-- both closed and both cards' gifts, rather than one card rolling per sale.
--
-- WHY THE GIFTS SURVIVE. This is the half that would have broken a live bar if it were missed.
-- app.reward_availability_v432's second arm already lists rewards from CLOSED cycles that carry
-- no stamp_milestone_claims row, and app.redeem_reward_core already has the matching survival
-- path that redeems them — both filtered on `origin in ('expired','claimed')`. A new origin would
-- have been invisible to both, so a customer whose card auto-rolled would have watched three
-- earned gifts vanish. Both filters gain 'completed' here, by exact textual patch of the live
-- definition (see the DO block) rather than by restating 31k characters of two money-path
-- functions from memory — the patch asserts its anchor exists first and aborts the whole
-- migration if it does not.
-- The owner's expiry rule needs nothing: a survivor's deadline is still
-- app.stamp_reward_expiry_v464 over that cycle, which is the photo-7 "rewards expire N days after
-- they are earned" rule the owner confirmed.
--
-- WHERE IT FIRES. A second AFTER INSERT trigger on public.sales rather than an edit to the
-- 200-line app.on_sale_recorded. It has to run AFTER the earn — the sale is what fills the card,
-- so sweeping before it would always be one sale late, which is the bug — and PostgreSQL fires
-- same-event triggers in NAME order: 'trg_v489_stamp_rollover' sorts after 'trg_sale_recorded'
-- and after every trg_sales_* trigger, because 's' < 'v'. That ordering is the contract; the
-- acceptance suite asserts the rollover has happened by the time the sale statement returns.
--
-- IDEMPOTENCY. stamp_cycles carries UNIQUE (business_id, client_id, programme_id, cycle_index),
-- so a replayed sale cannot close the same cycle twice; the insert is ON CONFLICT DO NOTHING and
-- the loop stops the moment it writes nothing.

begin;

-- ============================================================================================
-- 1. stamp_cycles learns a fourth origin
-- ============================================================================================

alter table public.stamp_cycles drop constraint if exists stamp_cycles_origin_check;
alter table public.stamp_cycles add constraint stamp_cycles_origin_check
  check (origin = any (array['claimed'::text, 'migration'::text, 'expired'::text, 'completed'::text]));

-- 'completed' takes the SAME shape as 'expired': no redemption and no reward (nothing was
-- claimed to close it), but a pinned config version, because the survivor gifts on that closed
-- card must be read at the version the card was collected under (v416).
alter table public.stamp_cycles drop constraint if exists stamp_cycles_shape_check;
alter table public.stamp_cycles add constraint stamp_cycles_shape_check
  check (
    ((origin = 'claimed'::text) and (redemption_id is not null) and (reward_id is not null)
      and (config_version_id is not null))
    or ((origin = 'migration'::text) and (redemption_id is null) and (reward_id is null))
    or ((origin = 'expired'::text) and (redemption_id is null) and (reward_id is null)
      and (config_version_id is not null))
    or ((origin = 'completed'::text) and (redemption_id is null) and (reward_id is null)
      and (config_version_id is not null))
  );

-- ============================================================================================
-- 2. The close itself
-- ============================================================================================

create or replace function app.stamp_complete_full_cycle_v489(
  p_business uuid, p_client uuid, p_programme uuid)
 returns integer
 language plpgsql
 security definer
 set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $function$
declare
  v_rolled integer := 0;
  v_slots integer;
  v_filled integer;
  v_cycle integer;
  v_config uuid;
  v_written integer;
  v_guard integer := 0;
begin
  if p_business is null or p_client is null or p_programme is null then
    return 0;
  end if;
  -- The same shared lock every other stamp writer takes (v480), so a close cannot interleave
  -- with an earn and read a filled count that is about to change.
  perform app.acquire_loyalty_shared_v480(p_business);

  loop
    v_guard := v_guard + 1;
    exit when v_guard > 20;   -- a runaway backstop, never a business rule

    select sp.slots, sp.filled, sp.cycle_index
      into v_slots, v_filled, v_cycle
      from app.stamp_progress_v323(p_business, p_client) sp
     where sp.programme_id = p_programme
     limit 1;
    exit when not found;
    exit when coalesce(v_slots, 0) <= 0;
    exit when coalesce(v_filled, 0) < v_slots;

    v_config := app.stamp_cycle_version_v416(p_business, p_client, p_programme);
    exit when v_config is null;   -- no pinned version means nothing honest to close against

    insert into public.stamp_cycles(
      business_id, programme_id, client_id, cycle_index, slots, origin, config_version_id, actor)
    values (p_business, p_programme, p_client, v_cycle, v_slots, 'completed', v_config, null)
    on conflict (business_id, client_id, programme_id, cycle_index) do nothing;
    get diagnostics v_written = row_count;
    exit when v_written = 0;   -- already closed by a concurrent writer or a replay

    insert into public.audit_log(business_id, actor, action, entity, entity_id, detail)
    values (p_business, null, 'stamp_card.completed', 'stamp_cycles', p_client,
      jsonb_build_object('client_id', p_client, 'programme_id', p_programme,
        'cycle_index', v_cycle, 'slots', v_slots,
        'stamps_carried_forward', greatest(v_filled - v_slots, 0),
        'config_version_id', v_config));

    v_rolled := v_rolled + 1;
  end loop;

  return v_rolled;
end;
$function$;

-- Owner-only, matching every sibling stamp writer (proacl {postgres=X/postgres}).
revoke all on function app.stamp_complete_full_cycle_v489(uuid, uuid, uuid) from public, anon, authenticated;

-- ============================================================================================
-- 3. The hook: a later-firing AFTER INSERT trigger on sales
-- ============================================================================================

create or replace function app.trg_v489_stamp_rollover()
 returns trigger
 language plpgsql
 security definer
 set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $function$
declare
  v_prog record;
begin
  -- A walk-in sale has no customer and therefore no card.
  if new.client_id is null then
    return null;
  end if;
  for v_prog in
    select spine.id
      from public.business_programmes spine
     where spine.business_id = new.business_id
       and spine.active
       and spine.kind = 'stamps'
     order by spine.sort, spine.id
  loop
    perform app.stamp_complete_full_cycle_v489(new.business_id, new.client_id, v_prog.id);
  end loop;
  return null;
end;
$function$;

revoke all on function app.trg_v489_stamp_rollover() from public, anon, authenticated;

drop trigger if exists trg_v489_stamp_rollover on public.sales;
create trigger trg_v489_stamp_rollover
  after insert on public.sales
  for each row execute function app.trg_v489_stamp_rollover();

-- ============================================================================================
-- 4. The survivor filters learn the new origin — by exact patch of the LIVE definitions
-- ============================================================================================
-- app.redeem_reward_core is 18k characters and app.reward_availability_v432 is 13k, both on the
-- redemption money path. Restating them from a transcription would put 31k characters of
-- hand-copied SQL between the owner and their gifts; this replaces one substring in each, having
-- first proven the substring is there. If either anchor is missing — because a later migration
-- rewrote that filter — the whole migration aborts rather than silently leaving one of the two
-- halves unpatched, which is the failure mode that would strand earned gifts.

do $do$
declare
  v_src text;
  v_old constant text := 'origin in (''expired'',''claimed'')';
  v_new constant text := 'origin in (''expired'',''claimed'',''completed'')';
  v_name text;
begin
  foreach v_name in array array['redeem_reward_core', 'reward_availability_v432'] loop
    select pg_get_functiondef(p.oid) into v_src
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'app' and p.proname = v_name
     limit 1;
    if v_src is null then
      raise exception 'v489: app.% not found — the survivor filter cannot be patched', v_name
        using errcode = 'XX001';
    end if;
    if position(v_old in v_src) = 0 then
      raise exception 'v489: app.% no longer contains the survivor origin filter %; refusing to '
        'ship an auto-rollover whose earned gifts would be unreachable', v_name, v_old
        using errcode = 'XX001';
    end if;
    v_src := replace(v_src, v_old, v_new);
    execute v_src;
  end loop;
end
$do$;

-- Both were owner-only before the replace and CREATE OR REPLACE preserves an ACL; restated here
-- so the intent is on the record rather than inherited silently.
revoke all on function app.reward_availability_v432(uuid, uuid, timestamp with time zone) from public, anon, authenticated;

commit;
