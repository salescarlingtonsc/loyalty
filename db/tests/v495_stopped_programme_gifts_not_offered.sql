-- Rolled-back proof for nestly_v495. One transaction, ROLLBACK at the end, nothing survives.
-- Run: supabase db query --linked -f db/tests/v495_stopped_programme_gifts_not_offered.sql
--
-- Fixtures are the owner's own photos:
--   Cubbly SPA (8492e8d6…), stamps programme OFF, customer "Mumu" (b6454672…) holding 13 stamps
--   and 0 points — the customer photo A showed with "2 rewards ready".
--   QA Kaya Toast (38b30e6d…), stamps programme ON, customer "Devi M" (55e82702…) — the running
--   card that must NOT lose anything to the new gate.
begin;

do $$
declare
  v_cubbly uuid := '8492e8d6-8888-4383-ada0-7e1ed69f0caa';
  v_mumu uuid := 'b6454672-38a8-49cb-af4f-8e98fafae2ed';
  v_kaya uuid := '38b30e6d-de73-4c2b-a2ca-19b08950896c';
  v_devi uuid := '55e82702-02a5-4a95-bbff-b941cda53f3d';
  v_stopped_stamp_rows integer;
  v_points_rows integer;
  v_running_rows integer;
  v_ready integer;
begin
  -- 1. On the STOPPED programme, no stamp gift is offered at all — in any availability state.
  select count(*) into v_stopped_stamp_rows
    from app.reward_availability_v432(v_cubbly, v_mumu, now()) r
   where r.unit = 'stamps';
  if v_stopped_stamp_rows <> 0 then
    raise exception 'FAIL 1: % stamp gift(s) still offered on a stopped programme', v_stopped_stamp_rows;
  end if;
  raise notice 'PASS 1: a stopped programme offers no stamp gifts';

  -- 2. The RUNNING points programme's gifts survive, honestly marked for a 0-point holder.
  select count(*) into v_points_rows
    from app.reward_availability_v432(v_cubbly, v_mumu, now()) r
   where r.unit = 'points' and r.availability = 'insufficient_balance';
  if v_points_rows < 1 then
    raise exception 'FAIL 2: the running points programme lost its gifts too';
  end if;
  raise notice 'PASS 2: the running points gifts remain, marked insufficient_balance at 0 points';

  -- 3. The ready COUNT — the "N rewards ready" pill and the Home tile — agrees.
  -- (The function takes an as-of timestamp and returns jsonb {"count": N, "choose_one": bool}.)
  select (app.customer_ready_reward_count_v465(v_cubbly, v_mumu, now())->>'count')::int into v_ready;
  if coalesce(v_ready, 0) <> 0 then
    raise exception 'FAIL 3: ready count is % for a customer the intent path would refuse', v_ready;
  end if;
  raise notice 'PASS 3: the ready count is 0 — photo A''s "2 rewards ready" cannot recur';

  -- 4. A RUNNING stamps programme is untouched by the gate.
  select count(*) into v_running_rows
    from app.reward_availability_v432(v_kaya, v_devi, now()) r
   where r.unit = 'stamps' and r.availability = 'available_at_counter';
  if v_running_rows < 1 then
    raise exception 'FAIL 4: the gate also silenced a RUNNING stamps programme';
  end if;
  raise notice 'PASS 4: % gift(s) still offered on the running card', v_running_rows;

  -- 5. And the definition itself carries the gate, not the rescue.
  if position('or (rows.source = ''stamp_card''' in
      (select pg_get_functiondef(p.oid) from pg_proc p
        join pg_namespace n on n.oid = p.pronamespace
       where n.nspname = 'app' and p.proname = 'reward_availability_v432')) > 0 then
    raise exception 'FAIL 5: the stopped-programme rescue clause is still live';
  end if;
  raise notice 'PASS 5: the rescue clause is gone from the live definition';
end $$;

rollback;
