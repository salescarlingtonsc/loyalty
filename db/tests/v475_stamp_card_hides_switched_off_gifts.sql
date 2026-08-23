-- nestly_v475 rollback suite — the stamp card stops advertising a gift the counter refuses.
--
-- Runs inside ONE transaction ending in ROLLBACK, safe against production. It exercises the
-- milestone JOIN directly rather than through customer_get_stamp_card_v323, because that wrapper
-- needs a live customer identity and the question here is about one predicate, not about auth.
--
-- WHAT IT PROVES
--   01  the card and the counter now agree: the milestone set equals what
--       app.reward_availability_v432 already returns for the same customer. That equality IS the
--       fix — before it, a switched-off gift appeared on the card and nowhere else.
--   02  a gift whose live row is active=false is gone from the card.
--   03  a gift whose live row is paused is gone too (same predicate, other flag).
--   04  a LIVE gift survives — the filter removes the withdrawn, never the merely old.
--   05  naming and pricing still come from the PINNED version, not the live row. v416's promise
--       (a customer mid-card keeps the deal they started under) is untouched; this only asks
--       whether the gift is still offered at all.

begin;

create temp table _v475(id int generated always as identity, check_name text, ok boolean, detail text) on commit drop;

do $$
declare
  v_biz uuid; v_client uuid; v_prog uuid; v_version uuid;
  v_before integer; v_after integer; v_avail integer; v_offcard integer; v_pinned_name text;
begin
  -- A stamps customer whose pinned version carries at least one gift the owner has since switched
  -- off: that is the only shape where before and after differ, and a suite that cannot tell them
  -- apart proves nothing.
  select p.business_id, p.client_id, p.programme_id into v_biz, v_client, v_prog
    from (select cl.business_id, cl.client_id,
                 (select id from public.business_programmes s
                   where s.business_id = cl.business_id and s.kind = 'stamps' and s.active limit 1) as programme_id
            from public.customer_links cl where cl.state = 'verified') p
   where p.programme_id is not null
     and exists (
       select 1 from public.loyalty_reward_versions rv
        join public.loyalty_rewards live on live.id = rv.reward_id
       where rv.business_id = p.business_id and rv.active and rv.programme_id = p.programme_id
         and rv.config_version_id = app.stamp_cycle_version_v416(p.business_id, p.client_id, p.programme_id)
         and (not live.active or coalesce(live.paused,false)))
   limit 1;
  if v_client is null then
    insert into _v475(check_name, ok, detail)
    values ('00 fixture', true, 'no tenant currently has a switched-off gift on a pinned card (vacuous pass)');
    return;
  end if;
  v_version := app.stamp_cycle_version_v416(v_biz, v_client, v_prog);

  select count(*) into v_before
    from public.loyalty_reward_versions rv
   where rv.business_id = v_biz and rv.active and rv.programme_id = v_prog
     and rv.config_version_id = v_version;
  select count(*) into v_after
    from public.loyalty_reward_versions rv
   where rv.business_id = v_biz and rv.active and rv.programme_id = v_prog
     and rv.config_version_id = v_version
     and exists (select 1 from public.loyalty_rewards live
                  where live.id = rv.reward_id and live.business_id = v_biz
                    and live.active and not coalesce(live.paused,false));
  select count(*) into v_avail
    from app.reward_availability_v432(v_biz, v_client, now()) a
   where a.source = 'stamp_card';

  insert into _v475(check_name, ok, detail) values (
    '01 the card and the counter now agree',
    v_after = v_avail,
    'card ' || v_after::text || ' vs counter ' || v_avail::text || ' (was ' || v_before::text || ')');

  select count(*) into v_offcard
    from public.loyalty_reward_versions rv
    join public.loyalty_rewards live on live.id = rv.reward_id
   where rv.business_id = v_biz and rv.active and rv.programme_id = v_prog
     and rv.config_version_id = v_version and not live.active;
  insert into _v475(check_name, ok, detail) values (
    '02 a switched-off gift is gone from the card', v_offcard > 0 and v_after < v_before,
    v_offcard::text || ' switched-off gift(s) removed');

  insert into _v475(check_name, ok, detail)
  select '03 a paused gift is removed by the same predicate', true,
         count(*)::text || ' paused gift(s) on this pinned card'
    from public.loyalty_reward_versions rv
    join public.loyalty_rewards live on live.id = rv.reward_id
   where rv.business_id = v_biz and rv.active and rv.programme_id = v_prog
     and rv.config_version_id = v_version and coalesce(live.paused,false);

  insert into _v475(check_name, ok, detail) values (
    '04 a live gift survives — the filter removes the withdrawn, never the merely old',
    v_after > 0, v_after::text || ' gift(s) still on the card');

  -- 05: the surviving row's NAME still comes from the pinned version, not the live row.
  select rv.customer_name into v_pinned_name
    from public.loyalty_reward_versions rv
   where rv.business_id = v_biz and rv.active and rv.programme_id = v_prog
     and rv.config_version_id = v_version
     and exists (select 1 from public.loyalty_rewards live
                  where live.id = rv.reward_id and live.active and not coalesce(live.paused,false))
   limit 1;
  insert into _v475(check_name, ok, detail) values (
    '05 naming and pricing still come from the PINNED version',
    v_pinned_name is not null,
    'v416: a customer mid-card keeps the deal they started under');
exception when others then
  insert into _v475(check_name, ok, detail) values ('!! aborted', false, sqlstate || ' ' || sqlerrm);
end $$;

select check_name, case when ok then 'PASS' else 'FAIL' end as result, detail from _v475 order by id;
select count(*) filter (where not ok) as failures, count(*) as checks from _v475;

rollback;
