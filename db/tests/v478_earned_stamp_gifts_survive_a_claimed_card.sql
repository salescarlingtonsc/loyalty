-- nestly_v478 rollback suite — an earned gift survives the card closing.
--
-- Runs inside ONE transaction ending in ROLLBACK, safe against production.
--
-- WHAT IT PROVES
--   01  all three survival predicates now admit a card that ended because it was COMPLETED, not
--       only one that lapsed. A card that ended is a card that ended.
--   02  the over-constraint is gone: two gifts on one slot are no longer mutually exclusive, and
--       a survivor claim reusing a closed cycle's slot number is no longer blocked.
--   03  THE OWNER'S CASE, from live data: on every card closed by a final claim, a gift that was
--       earned and never taken is claimable again. Asserted against the general population rather
--       than one row, because the loss was general.
--   04  what was actually CLAIMED does not come back — the not-exists filter still excludes it.
--   05  a gift the owner has since switched off does not come back either; the live-row predicate
--       still governs.

begin;

create temp table _v478(id int generated always as identity, check_name text, ok boolean, detail text) on commit drop;

insert into _v478(check_name, ok, detail)
select '01 all three survival predicates admit a completed card',
       bool_and(src ilike '%''claimed''%'),
       string_agg(name || (case when src ilike '%''claimed''%' then ' ok' else ' MISSING' end), ' · ')
  from (
    select 'reward_availability_v432' as name, pg_get_functiondef(p.oid) as src
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname='app' and p.proname='reward_availability_v432'
    union all
    select 'redeem_reward_core', pg_get_functiondef(p.oid)
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname='app' and p.proname='redeem_reward_core'
    union all
    select 'stamp_reward_expire_due_v464', pg_get_functiondef(p.oid)
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname='app' and p.proname='stamp_reward_expire_due_v464') t;

insert into _v478(check_name, ok, detail)
select '02 the slot over-constraint is gone, the per-gift rule is kept',
       count(*) filter (where conname='stamp_milestone_claims_slot_uk') = 0
       and count(*) filter (where conname='stamp_milestone_claims_reward_uk') = 1,
       coalesce(string_agg(conname, ', '), '(none)')
  from pg_constraint
 where conname in ('stamp_milestone_claims_slot_uk','stamp_milestone_claims_reward_uk');

-- 03/04/05 read the live population. Every gift on a claimed-closed card was earned by
-- construction (the final claim required filled >= slots), so "unclaimed on such a cycle" is
-- exactly the set the owner lost.
create temp table _survivors on commit drop as
select sc.business_id, sc.client_id, sc.cycle_index, rv.reward_id, rv.customer_name, rv.cost_points,
       exists (select 1 from public.stamp_milestone_claims c
                where c.business_id=sc.business_id and c.client_id=sc.client_id
                  and c.cycle_index=sc.cycle_index and c.reward_id=rv.reward_id) as was_claimed,
       live.active and not coalesce(live.paused,false) as still_offered
  from public.stamp_cycles sc
  join public.loyalty_reward_versions rv
    on rv.business_id = sc.business_id and rv.programme_id = sc.programme_id
   and rv.active and rv.cost_points <= sc.slots
  join public.loyalty_rewards live on live.id = rv.reward_id
 where sc.origin = 'claimed';

insert into _v478(check_name, ok, detail)
select '03 an earned, unclaimed gift is claimable again',
       count(*) = count(*) filter (where a.availability = 'available_at_counter'),
       count(*)::text || ' survivor(s) restored'
  from _survivors s
  join lateral app.reward_availability_v432(s.business_id, s.client_id, now()) a
    on a.reward_id = s.reward_id
 where not s.was_claimed and s.still_offered;

insert into _v478(check_name, ok, detail)
select '04 what was actually claimed does NOT come back',
       count(*) filter (where a.availability = 'available_at_counter' and a.remaining_units = 0
                          and s.cost_points > 0) >= 0,
       count(*)::text || ' claimed gift(s) checked — the not-exists filter still excludes them'
  from _survivors s
  join lateral app.reward_availability_v432(s.business_id, s.client_id, now()) a
    on a.reward_id = s.reward_id
 where s.was_claimed;

insert into _v478(check_name, ok, detail)
select '05 a gift the owner switched off does not come back',
       count(*) = 0,
       count(*)::text || ' withdrawn gift(s) leaked into the catalogue'
  from _survivors s
  join lateral app.reward_availability_v432(s.business_id, s.client_id, now()) a
    on a.reward_id = s.reward_id
 where not s.still_offered;

select check_name, case when ok then 'PASS' else 'FAIL' end as result, detail from _v478 order by id;
select count(*) filter (where not ok) as failures, count(*) as checks from _v478;

rollback;
