-- Rollback-only acceptance for v416 — a stamp card belongs to the setup it was started under.
--   supabase db query --linked -f db/tests/v416_stamp_cycle_config_pin.sql
-- Any row whose result starts with FAIL is a failure. Nothing is committed.
--
-- OWNER RULING: a change to a gift applies "only from their next card" — a customer part-way
-- through keeps the deal they started. Before v416 all three stamp reads resolved a firm's gifts
-- and its card length through whatever the owner had published most recently, so a customer on
-- 4 of 5 stamps could find their card had become a different card mid-fill.
--
-- Check 04 is the ruling itself, exercised for real: a new configuration with a different card
-- length is PUBLISHED inside the transaction, and the mid-card customer must not move.

begin;

create temp table _r(k text, v text) on commit drop;

do $$
declare
  v_biz uuid := '8492e8d6-8888-4383-ada0-7e1ed69f0caa';
  v_client uuid := 'b6454672-38a8-49cb-af4f-8e98fafae2ed';
  v_spine uuid; v_active uuid; v_pinned uuid; v_slots integer; v_filled integer;
  v_started timestamptz; v_new uuid; v_slots_after integer; v_fresh uuid;
  v_before_slots integer;
begin
  select id into v_spine from public.business_programmes where business_id=v_biz and kind='stamps';
  select active_config_version_id into v_active from public.businesses where id=v_biz;

  -- 00 a client with NO stamps on the open card gets today's setup
  insert into _r
  select '00_empty_card_uses_active',
    case when app.stamp_cycle_version_v416(v_biz, gen_random_uuid(), v_spine) = v_active
      then 'PASS a customer who has not started a card gets the newest setup'
      else 'FAIL' end;

  -- 01 a mid-card client is pinned to a real published version
  v_pinned := app.stamp_cycle_version_v416(v_biz, v_client, v_spine);
  insert into _r
  select '01_pinned_to_a_published_version',
    case when exists(select 1 from public.firm_config_versions f
                      where f.id=v_pinned and f.business_id=v_biz and f.published_at is not null)
      then 'PASS pinned to a published version of this firm'
      else 'FAIL pinned to '||coalesce(v_pinned::text,'null') end;

  -- 02 and that version was in force when their current card's first stamp landed
  select min(pl.created_at) into v_started from public.points_ledger pl
   where pl.business_id=v_biz and pl.client_id=v_client and pl.programme_id=v_spine and pl.points>0
     and pl.created_at > coalesce((select max(sc.closed_at) from public.stamp_cycles sc
        where sc.business_id=v_biz and sc.client_id=v_client and sc.programme_id=v_spine),'-infinity'::timestamptz);
  insert into _r
  select '02_version_was_in_force_then',
    case when v_started is null then 'SKIP this client has no open card'
         when (select f.published_at from public.firm_config_versions f where f.id=v_pinned) <= v_started
           and not exists(select 1 from public.firm_config_versions f2
                           where f2.business_id=v_biz and f2.published_at is not null
                             and f2.published_at <= v_started
                             and f2.published_at > (select f.published_at from public.firm_config_versions f where f.id=v_pinned))
      then 'PASS it is the LATEST version published on or before their first stamp'
      else 'FAIL' end;

  -- 03 progress is unchanged today (the pinned version and the live column agree right now)
  select sp.slots, sp.filled into v_slots, v_filled from app.stamp_progress_v323(v_biz, v_client) sp;
  v_before_slots := v_slots;
  insert into _r values('03_progress_unchanged_today',
    'slots='||coalesce(v_slots::text,'null')||' filled='||coalesce(v_filled::text,'null')
    ||' (live column says '||coalesce((select stamp_target::text from public.loyalty_programs where business_id=v_biz),'null')||')');

  -- 04 THE RULING. Publish a NEW version with a different card length, right now.
  --    The mid-card customer must keep the length they started under.
  v_new := gen_random_uuid();
  -- one published version per business is enforced by firm_config_one_published_per_business,
  -- which is exactly the invariant this resolver relies on. Supersede before publishing.
  update public.firm_config_versions set status='superseded', superseded_at=now()
   where business_id=v_biz and status='published';
  insert into public.firm_config_versions(id,business_id,version_no,status,source,snapshot_hash,published_at)
  values(v_new,v_biz,(select coalesce(max(version_no),0)+1 from public.firm_config_versions where business_id=v_biz),
         'published','v416_rolled_back_test',md5('v416-rolled-back-test'),now());
  /* clone the live programme version wholesale, overriding only the card length — column-agnostic
     so this fixture cannot rot every time loyalty_program_versions gains a NOT NULL column. */
  insert into public.loyalty_program_versions
  select (jsonb_populate_record(null::public.loyalty_program_versions,
            to_jsonb(r) || jsonb_build_object('config_version_id', v_new, 'stamp_target', 99))).*
    from public.loyalty_program_versions r
   where r.config_version_id = (select active_config_version_id from public.businesses where id=v_biz);
  update public.businesses set active_config_version_id=v_new where id=v_biz;

  select sp.slots into v_slots_after from app.stamp_progress_v323(v_biz, v_client) sp;
  insert into _r
  select '04_midcard_keeps_its_length',
    case when v_slots_after = v_before_slots
      then 'PASS the card stayed '||v_before_slots||' stamps even though the firm just published a 99-stamp card'
      else 'FAIL the customer''s open card jumped to '||coalesce(v_slots_after::text,'null') end;

  -- 05 ...and a customer starting a FRESH card gets the new one
  select sp.slots into v_slots_after from app.stamp_progress_v323(v_biz, gen_random_uuid()) sp;
  insert into _r
  select '05_next_card_uses_the_new_setup',
    case when v_slots_after = 99
      then 'PASS a customer with no stamps yet gets the 99-stamp card - "moving forward will be based on the new settings"'
      else 'FAIL a fresh card reads '||coalesce(v_slots_after::text,'null') end;
end $$;

-- 06 the three readers all go through the one resolver
insert into _r
select '06_all_three_readers_pinned',
  case when count(*)=3 then 'PASS stamp_progress_v323, customer_get_stamp_card_v323 and redeem_reward_core all call it'
       else 'FAIL only '||count(*)||' of 3' end
from pg_proc p join pg_namespace n on n.oid=p.pronamespace
where pg_get_functiondef(p.oid) ~ 'stamp_cycle_version_v416'
  and p.proname in ('stamp_progress_v323','customer_get_stamp_card_v323','redeem_reward_core');

-- 07 the resolver is not reachable from the browser
insert into _r
select '07_not_client_callable',
  case when count(*)=0 then 'PASS neither anon nor authenticated can execute the resolver'
       else 'FAIL it is client-callable' end
from pg_proc p join pg_namespace n on n.oid=p.pronamespace
where n.nspname='app' and p.proname='stamp_cycle_version_v416'
  and (has_function_privilege('anon',p.oid,'execute') or has_function_privilege('authenticated',p.oid,'execute'));

-- 08 points redemptions still resolve the ACTIVE version, untouched
insert into _r
select '08_points_path_untouched',
  case when pg_get_functiondef(p.oid) ~ 'else \(select b\.active_config_version_id from public\.businesses b where b\.id = p_business\) end'
    then 'PASS a non-stamps programme still uses the firm''s active version'
    else 'FAIL' end
from pg_proc p join pg_namespace n on n.oid=p.pronamespace
where n.nspname='app' and p.proname='redeem_reward_core';

select k as check, v as result from _r order by k;
rollback;
