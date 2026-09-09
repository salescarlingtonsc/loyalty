-- nestly_v871 rollback suite — the conversion reverses at its recorded rate; parked pots are
-- visible; the wallet promises only what the counter honours.
--
-- Run inside a transaction against production and ROLLED BACK. Exercises the real reverse on
-- Cubbly SPA (whose owner converted 75,800 points into 758 stamps on 2026-08-21 and then
-- switched back), impersonating the real owner; nothing commits.

\set ON_ERROR_STOP on

begin;

do $suite$
declare
  cb      constant uuid := '8492e8d6-8888-4383-ada0-7e1ed69f0caa';
  cust    constant uuid := '268cb96d-e6cc-4217-99f6-884b006ba7a3';
  pts     constant uuid := 'b8fbc7b0-36fe-42c9-aabb-c5d98751baa3';
  stamps  constant uuid := '708d5047-bd84-4f2c-a31c-79b4834ce2b9';
  owner_uid uuid; card jsonb; parked jsonb; resp jsonb; resp2 jsonb; key uuid := gen_random_uuid();
  stamps_before integer; pts_before integer; stamps_after integer; pts_after integer; issued integer; n integer := 0;
begin
  -- C1: objects exist
  n := n + 1;
  if to_regprocedure('public.business_switch_to_points_v871(uuid,uuid)') is null
     or to_regclass('public.programme_stamp_reversals_v871') is null then
    raise exception 'C% failed: reverse RPC or its ledger table is missing', n;
  end if;

  -- C2: the wallet card shows the parked stamps pot for this customer
  select coalesce(sum(points),0) into stamps_before from public.points_ledger where business_id=cb and client_id=cust and programme_id=stamps;
  card := app.c45_base_actionable_wallet_card(cb, cust, 'kopi-tiam-tyeh', 'Cubbly SPA', 'spa', 'SGD', array['loyalty'], now());
  parked := card->'parked_programmes';
  n := n + 1;
  if parked is null or jsonb_typeof(parked) <> 'array' then raise exception 'C% failed: no parked_programmes on the wallet card', n; end if;
  n := n + 1;
  if stamps_before > 0 and not exists (select 1 from jsonb_array_elements(parked) p
        where (p->>'programme_id')::uuid = stamps and (p->>'balance')::integer = stamps_before and p->>'unit' = 'stamps') then
    raise exception 'C% failed: parked stamps pot (% stamps) is not reported: %', n, stamps_before, parked::text;
  end if;

  -- C3: available_now on the card is the canonical readiness core, never the lifetime pot
  n := n + 1;
  if (card #>> '{next_eligible_reward,available_now}') is not null
     and (card #>> '{next_eligible_reward,available_now}')::boolean <> (coalesce((card->>'ready_count')::integer,0) > 0) then
    raise exception 'C% failed: available_now % disagrees with ready_count %', n, card #>> '{next_eligible_reward,available_now}', card->>'ready_count';
  end if;

  -- C4: the reverse, executed and rolled back
  select s.user_id into owner_uid from public.staff s where s.business_id = cb and s.role = 'owner' and s.user_id is not null limit 1;
  perform set_config('request.jwt.claims', json_build_object('sub', owner_uid, 'role', 'authenticated')::text, true);
  select coalesce(sum(points),0) into pts_before from public.points_ledger where business_id=cb and client_id=cust and programme_id=pts;
  select coalesce(sum(points),0) into issued from public.points_ledger
   where business_id=cb and client_id=cust and programme_id=stamps and reference='stamp conversion: stamps issued';

  resp := public.business_switch_to_points_v871(cb, key);
  n := n + 1;
  if not coalesce((resp->>'ok')::boolean,false) then raise exception 'C% failed: reverse did not return ok: %', n, resp::text; end if;
  n := n + 1;
  if (resp->>'points_per_stamp')::int <> 100 then raise exception 'C% failed: rate % is not the recorded 100', n, resp->>'points_per_stamp'; end if;

  select coalesce(sum(points),0) into stamps_after from public.points_ledger where business_id=cb and client_id=cust and programme_id=stamps;
  select coalesce(sum(points),0) into pts_after from public.points_ledger where business_id=cb and client_id=cust and programme_id=pts;
  n := n + 1;
  if stamps_after <> stamps_before - least(issued, stamps_before) then
    raise exception 'C% failed: stamps % -> %, expected -% (only what the conversion issued, and only what is still held)', n, stamps_before, stamps_after, least(issued, stamps_before);
  end if;
  n := n + 1;
  if pts_after <> pts_before + least(issued, stamps_before) * 100 then
    raise exception 'C% failed: points % -> %, expected +% (stamps x recorded rate)', n, pts_before, pts_after, least(issued, stamps_before) * 100;
  end if;

  -- C5: conservation holds in both pots after the reverse
  n := n + 1;
  if exists (
    select 1 from
      (select client_id, programme_id, sum(points)::integer t from public.points_ledger where business_id=cb and programme_id in (pts, stamps) group by 1,2) l
      full join
      (select client_id, programme_id, sum(remaining)::integer t from public.points_batches where business_id=cb and programme_id in (pts, stamps) group by 1,2) b
      using (client_id, programme_id)
     where coalesce(l.t,0) <> coalesce(b.t,0)) then
    raise exception 'C% failed: ledger and batches disagree after the reverse', n;
  end if;

  -- C6: the spine is back on points
  n := n + 1;
  if not exists (select 1 from public.business_programmes where business_id=cb and kind='points' and active)
     or exists (select 1 from public.business_programmes where business_id=cb and kind='stamps' and active) then
    raise exception 'C% failed: the spine was not switched back to points', n;
  end if;

  -- C7: replaying the same key returns the same answer and moves nothing
  resp2 := public.business_switch_to_points_v871(cb, key);
  n := n + 1;
  if resp2 <> resp then raise exception 'C% failed: replay returned a different response', n; end if;
  n := n + 1;
  if (select coalesce(sum(points),0) from public.points_ledger where business_id=cb and client_id=cust and programme_id=pts) <> pts_after then
    raise exception 'C% failed: replay moved points', n;
  end if;

  raise notice 'nestly_v871 suite: % assertions passed (stamps % -> %, points % -> %)', n, stamps_before, stamps_after, pts_before, pts_after;
end
$suite$;

rollback;
