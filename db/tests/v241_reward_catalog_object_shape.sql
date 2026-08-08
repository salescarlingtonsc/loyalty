-- V241 rollback verification: the customer reward catalog is an object carrying points_mode.
-- Run inside a transaction that is ROLLED BACK. Uses the demo tenant and its verified customer.
begin;
update public.loyalty_programs set tier_basis='visits'
 where business_id='8492e8d6-8888-4383-ada0-7e1ed69f0caa';
update public.businesses set points_mode='both'
 where id='8492e8d6-8888-4383-ada0-7e1ed69f0caa';
select set_config('request.jwt.claims',
  json_build_object('sub','253de8ef-b08c-40fa-b435-5723a6123a9d','role','authenticated')::text, true);
set local role authenticated;
do $$
declare v_payload jsonb;
begin
  v_payload := public.customer_get_reward_catalog('kopi-tiam-tyeh')::jsonb;
  if jsonb_typeof(v_payload) <> 'object' then
    raise exception 'v241.shape: catalog is %, not an object', jsonb_typeof(v_payload);
  end if;
  if v_payload->>'points_mode' is distinct from 'both' then
    raise exception 'v241.mode: expected both, got %', v_payload->>'points_mode';
  end if;
  if jsonb_typeof(v_payload->'rewards') <> 'array' then
    raise exception 'v241.rewards: rewards is %, not an array', jsonb_typeof(v_payload->'rewards');
  end if;
  -- No phantom mode element inside the rewards array — every entry is a nameable reward.
  if exists (select 1 from jsonb_array_elements(v_payload->'rewards') reward
              where reward->>'customer_name' is null) then
    raise exception 'v241.phantom: a rewards entry has no customer_name';
  end if;
end $$;
rollback;
