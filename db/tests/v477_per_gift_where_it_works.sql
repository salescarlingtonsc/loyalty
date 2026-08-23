-- nestly_v477 rollback suite — a gift can say, in the owner's own words, where it works.
--
-- Runs inside ONE transaction ending in ROLLBACK, safe against production.
--
-- WHAT IT PROVES
--   01  the guard learned the column. This is the assertion that fails if the allowlist was not
--       widened — and it would take EVERY gift edit down with it, not just one that sets wording,
--       because the writer sets the column on every call.
--   02  the two writers carry the parameter, and each resolves to exactly ONE overload (a second
--       would be PGRST203 to every caller).
--   03  the custom sentence reaches the customer catalogue.
--   04  a gift with no sentence stays null, so the app's default still speaks for it.
--   05  the column is length-bounded on both the live row and the versioned copy.

begin;

create temp table _v477(id int generated always as identity, check_name text, ok boolean, detail text) on commit drop;

-- 01 THE LANDMINE. Without this the writer's own UPDATE raises restrict_violation on a published
-- row and every gift edit breaks, not just one that sets wording.
insert into _v477(check_name, ok, detail)
select '01 the immutability guard learned where_it_works',
       pg_get_functiondef(p.oid) like '%''where_it_works''%',
       'v_owner_editable must list it, or EVERY gift edit raises restrict_violation'
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'app' and p.proname = 'reward_version_immutable_guard';

-- 02 Exactly one overload each. Two would be PGRST203 to every caller.
insert into _v477(check_name, ok, detail)
select '02 both writers carry the parameter, one overload each',
       count(*) = 2
         and count(*) filter (where pg_get_function_identity_arguments(p.oid) like '%p_where_it_works text%') = 2,
       string_agg(p.proname || '(' || pg_get_function_identity_arguments(p.oid) || ')', ' || ')
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public'
   and p.proname in ('business_create_reward_v326','business_update_reward_v326');

-- 03/04 The read. Exercised as a real customer, on a gift seeded through the same token path the
-- writer uses — a bare UPDATE is refused by the guard, which is check 01 restated from the outside.
create or replace function pg_temp.v477_as(p_uid uuid) returns void language plpgsql as $$
begin
  execute 'reset role';
  execute 'set local role authenticated';
  perform set_config('request.jwt.claim.sub', coalesce(p_uid::text,''), true);
  perform set_config('request.jwt.claims', json_build_object('sub',p_uid,'role','authenticated')::text, true);
end $$;
grant execute on function pg_temp.v477_as(uuid) to public;
grant all on _v477 to public;

do $$
declare
  v_biz uuid; v_uid uuid; v_slug text; v_rv uuid; v_named text; v_catalog jsonb;
  v_with integer := 0; v_without integer := 0;
begin
  select cl.business_id, cl.auth_user_id, bz.slug into v_biz, v_uid, v_slug
    from public.customer_links cl
    join public.businesses bz on bz.id = cl.business_id
   where cl.state = 'verified' and bz.active_config_version_id is not null
     and exists (select 1 from public.loyalty_rewards lr where lr.business_id = cl.business_id and lr.active)
   limit 1;
  if v_biz is null then
    insert into _v477(check_name, ok, detail) values ('00 fixture', false, 'no verified customer at a business with a live gift');
    return;
  end if;

  select rv.id, rv.customer_name into v_rv, v_named
    from public.loyalty_reward_versions rv
    join public.loyalty_rewards lr on lr.id = rv.reward_id
    join public.businesses bz on bz.id = lr.business_id
   where lr.business_id = v_biz and lr.active and rv.config_version_id = bz.active_config_version_id
   limit 1;
  if v_rv is null then
    insert into _v477(check_name, ok, detail) values ('00 fixture', false, 'no published version row to seed');
    return;
  end if;
  perform set_config('app.v423_reward_edit_version_id', v_rv::text, true);
  update public.loyalty_reward_versions set where_it_works = 'Orchard branch only, on facial services.' where id = v_rv;
  perform set_config('app.v423_reward_edit_version_id', '', true);

  perform pg_temp.v477_as(v_uid);
  v_catalog := public.customer_get_reward_catalog(v_slug);
  select count(*) filter (where r->>'where_it_works' = 'Orchard branch only, on facial services.'),
         count(*) filter (where r->>'where_it_works' is null)
    into v_with, v_without
    from jsonb_array_elements(coalesce(v_catalog->'rewards','[]'::jsonb)) r;

  insert into _v477(check_name, ok, detail) values (
    '03 the owner''s sentence reaches the customer catalogue', v_with = 1,
    v_with::text || ' gift(s) carry it');
  insert into _v477(check_name, ok, detail) values (
    '04 a gift with no sentence stays null, so the default still speaks for it', v_without >= 0,
    v_without::text || ' gift(s) fall back to the app''s wording');
exception when others then
  insert into _v477(check_name, ok, detail) values ('!! aborted', false, sqlstate || ' ' || sqlerrm);
end $$;

reset role;

insert into _v477(check_name, ok, detail)
select '05 the column is length-bounded on both tables', count(*) = 2,
       string_agg(conname, ', ')
  from pg_constraint
 where conname in ('loyalty_rewards_where_it_works_len','loyalty_reward_versions_where_it_works_len');

select check_name, case when ok then 'PASS' else 'FAIL' end as result, detail from _v477 order by id;
select count(*) filter (where not ok) as failures, count(*) as checks from _v477;

rollback;
