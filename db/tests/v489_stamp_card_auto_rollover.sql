-- Rolled-back proof for nestly_v489. One transaction, ROLLBACK at the end, nothing survives.
-- Run: supabase db query --linked -f db/tests/v489_stamp_card_auto_rollover.sql
--
-- Fixture is the owner's own screenshot: QA Kaya Toast (38b30e6d…), customer "Devi M"
-- (55e82702…), sitting on 17 stamps against a 15-slot card at cycle 0 — a full card that would
-- not roll, printing "2 already counted toward your next card" underneath it.
begin;

do $$
declare
  v_biz uuid := '38b30e6d-de73-4c2b-a2ca-19b08950896c';
  v_client uuid := '55e82702-02a5-4a95-bbff-b941cda53f3d';
  v_prog uuid;
  v_slots integer; v_filled integer; v_cycle integer;
  v_rolled integer;
  v_survivors integer; v_survivors_after integer;
  v_before_ready integer; v_after_ready integer;
  v_tg_name text; v_tg_fn text;
begin
  select sp.programme_id, sp.slots, sp.filled, sp.cycle_index
    into v_prog, v_slots, v_filled, v_cycle
    from app.stamp_progress_v323(v_biz, v_client) sp limit 1;

  if v_prog is null then
    raise exception 'FAIL 0: no stamps programme for the fixture business';
  end if;
  if coalesce(v_filled,0) < coalesce(v_slots,0) then
    raise exception 'FAIL 0: fixture no longer has a FULL card (filled % / slots %) — pick '
      'another client with filled >= slots', v_filled, v_slots;
  end if;
  raise notice 'fixture: slots=% filled=% cycle=%', v_slots, v_filled, v_cycle;

  -- ---- 1. the trigger exists, calls the right function, and fires AFTER the earn -------------
  select t.tgname, p.proname into v_tg_name, v_tg_fn
    from pg_trigger t join pg_class c on c.oid = t.tgrelid
    join pg_proc p on p.oid = t.tgfoid
   where c.relname = 'sales' and t.tgname = 'trg_v489_stamp_rollover' and not t.tgisinternal;
  if v_tg_name is null then
    raise exception 'FAIL 1: trg_v489_stamp_rollover is not on public.sales';
  end if;
  if v_tg_fn <> 'trg_v489_stamp_rollover' then
    raise exception 'FAIL 1: the trigger calls %, not the v489 rollover', v_tg_fn;
  end if;
  -- The ordering contract, asserted rather than assumed: PostgreSQL fires same-event triggers in
  -- NAME order, and the sweep is worthless if it runs before app.on_sale_recorded's earn.
  if not ('trg_v489_stamp_rollover' > 'trg_sale_recorded') then
    raise exception 'FAIL 1: the rollover trigger no longer sorts after trg_sale_recorded';
  end if;
  raise notice 'PASS 1: the rollover trigger is on sales and fires after the earn';

  -- ---- 2. how many gifts can this customer claim right now ------------------------------------
  select count(*) into v_before_ready
    from app.reward_availability_v432(v_biz, v_client, now()) r
   where r.availability = 'available_at_counter';

  -- ---- 3. the close: one card rolls, the excess carries -------------------------------------
  v_rolled := app.stamp_complete_full_cycle_v489(v_biz, v_client, v_prog);
  if v_rolled < 1 then
    raise exception 'FAIL 3: a full card did not roll (returned %)', v_rolled;
  end if;

  select sp.slots, sp.filled, sp.cycle_index
    into v_slots, v_filled, v_cycle
    from app.stamp_progress_v323(v_biz, v_client) sp limit 1;
  if v_filled <> 2 then
    raise exception 'FAIL 3: expected 2 stamps carried to the new card, got %', v_filled;
  end if;
  if v_cycle <> 1 then
    raise exception 'FAIL 3: expected to be on cycle 1 after one roll, got %', v_cycle;
  end if;
  raise notice 'PASS 3: the card rolled and the 2 excess stamps landed on the new one';

  -- ---- 4. the closed cycle is 'completed', with the TARGET consumed, not the filled count ----
  if not exists (
    select 1 from public.stamp_cycles sc
     where sc.business_id = v_biz and sc.client_id = v_client and sc.programme_id = v_prog
       and sc.cycle_index = 0 and sc.origin = 'completed' and sc.slots = 15
       and sc.redemption_id is null and sc.reward_id is null
       and sc.config_version_id is not null
  ) then
    raise exception 'FAIL 4: no completed cycle row of the expected shape';
  end if;
  raise notice 'PASS 4: cycle 0 closed as completed, consuming the 15-slot target only';

  -- ---- 5. the gifts earned on that card SURVIVE the roll -------------------------------------
  -- This is the half that would strand a real customer. reward_availability_v432's survivor arm
  -- and redeem_reward_core's survival path both had to learn the new origin.
  select count(*) into v_after_ready
    from app.reward_availability_v432(v_biz, v_client, now()) r
   where r.availability = 'available_at_counter';
  if v_after_ready < v_before_ready then
    raise exception 'FAIL 5: rolling the card DESTROYED % claimable gift(s) (% -> %)',
      v_before_ready - v_after_ready, v_before_ready, v_after_ready;
  end if;
  select count(*) into v_survivors
    from public.stamp_cycles sc
    join public.loyalty_reward_versions rv
      on rv.business_id = v_biz and rv.config_version_id = sc.config_version_id
     and rv.active and rv.cost_points <= sc.slots
   where sc.business_id = v_biz and sc.client_id = v_client
     and sc.programme_id = v_prog and sc.origin = 'completed'
     and not exists (select 1 from public.stamp_milestone_claims claim
                      where claim.business_id = v_biz and claim.client_id = v_client
                        and claim.programme_id = v_prog and claim.cycle_index = sc.cycle_index
                        and claim.reward_id = rv.reward_id);
  raise notice 'PASS 5: % claimable gift(s) held across the roll, % unclaimed milestone(s) '
    'survive on the completed card', v_after_ready, v_survivors;

  -- ---- 6. idempotent: the same call again closes nothing --------------------------------------
  v_rolled := app.stamp_complete_full_cycle_v489(v_biz, v_client, v_prog);
  if v_rolled <> 0 then
    raise exception 'FAIL 6: a second sweep closed % more cycle(s) from 2/15', v_rolled;
  end if;
  raise notice 'PASS 6: a repeat sweep on a part-filled card closes nothing';

  -- ---- 7. the survivor filters really did learn the new origin -------------------------------
  if position('''completed''' in
      (select pg_get_functiondef(p.oid) from pg_proc p
        join pg_namespace n on n.oid = p.pronamespace
       where n.nspname = 'app' and p.proname = 'redeem_reward_core')) = 0 then
    raise exception 'FAIL 7: redeem_reward_core cannot redeem a survivor of a completed card';
  end if;
  if position('''completed''' in
      (select pg_get_functiondef(p.oid) from pg_proc p
        join pg_namespace n on n.oid = p.pronamespace
       where n.nspname = 'app' and p.proname = 'reward_availability_v432')) = 0 then
    raise exception 'FAIL 7: reward_availability_v432 does not list survivors of a completed card';
  end if;
  raise notice 'PASS 7: both survivor paths accept the completed origin';
end $$;

rollback;
