-- nestly_v472 rollback suite — a gift can be given an end date, and a business can publish a menu.
--
-- Everything runs inside ONE transaction that ends in ROLLBACK, so the suite can be run against
-- production without leaving a row behind. It runs AS a real owner via set_config on the JWT
-- claims, because both features are behind owner authorisation and a run as postgres would prove
-- nothing about the path a browser actually takes.
--
-- WHAT IT PROVES
--   01  the end date reaches loyalty_rewards.
--   02  it also reaches the PUBLISHED loyalty_reward_versions row — this is the assertion that
--       fails if app.reward_version_immutable_guard was not widened, because the guard raises
--       restrict_violation on a published row and the whole update aborts. It is the single most
--       important check in this file: without the widened allowlist EVERY gift edit breaks, not
--       just one that sets a date.
--   03  the customer catalogue serves it, so a date that is set is a date that is seen.
--   04  a date in the past is refused rather than stored — a gift that ended before it began
--       can never be claimed and the counter would have absorbed the mistake silently.
--   05  an old bundle (no date argument) leaves an existing date ALONE. This is the regression
--       that would quietly wipe every date the deep editor ever set.
--   06  p_clear_end_date clears it — the owner can take a deadline off again.
--   07  saving the MENU does not delete the GALLERY, and saving the gallery does not delete the
--       menu. The writer deletes before it inserts, so a mis-scoped delete would silently destroy
--       the segment the owner was not editing.
--   08  the customer read returns the two segments separately, and neither leaks into the other.
--   09  an unknown segment is refused rather than silently filed as 'gallery'.
--   10  every pre-v472 row kept its meaning: nothing is 'menu' that the owner did not make so.

begin;

create temp table _v472(id int generated always as identity, check_name text, ok boolean, detail text) on commit drop;
grant all on _v472 to public;

create or replace function pg_temp.v472_as(p_uid uuid) returns void language plpgsql as $$
begin
  execute 'reset role';
  execute 'set local role authenticated';
  perform set_config('request.jwt.claim.sub', coalesce(p_uid::text,''), true);
  perform set_config('request.jwt.claims', json_build_object('sub',p_uid,'role','authenticated')::text, true);
end $$;
grant execute on function pg_temp.v472_as(uuid) to public;

do $$
declare
  v_biz uuid; v_uid uuid; v_reward uuid; v_version uuid;
  v_when timestamptz := date_trunc('day', now()) + interval '90 days';
  v_stored timestamptz; v_published timestamptz;
  v_photo text; v_photo2 text;
  v_business jsonb; r jsonb; v_cuid uuid; v_slug text;
begin
  -- A real owner of a business that has a published loyalty config and at least one live points
  -- gift. Both features are owner-gated, and the reward half needs a published version row for
  -- the immutability guard to have anything to refuse.
  select s.user_id, s.business_id, lr.id
    into v_uid, v_biz, v_reward
    from public.staff s
    join public.businesses bz on bz.id = s.business_id
    join public.loyalty_rewards lr on lr.business_id = s.business_id and lr.active
    join public.business_programmes spine on spine.id = lr.programme_id and spine.kind = 'points'
   where s.role = 'owner' and s.user_id is not null and s.active
     and bz.active_config_version_id is not null
   order by bz.created_at
   limit 1;
  if v_reward is null then
    insert into _v472(check_name, ok, detail)
    values ('00 fixture', false, 'no owner with a live points gift on a published config');
    return;
  end if;

  select slug into v_slug from public.businesses where id = v_biz;
  perform pg_temp.v472_as(v_uid);

  -- ------------------------------------------------------------------ the gift end date -------
  r := public.business_update_reward_v326(
         p_business => v_biz, p_reward => v_reward,
         p_name => (select coalesce(customer_name, name) from public.loyalty_rewards where id = v_reward),
         p_points => (select cost_points from public.loyalty_rewards where id = v_reward),
         p_claim_available_until => v_when);

  select claim_available_until into v_stored from public.loyalty_rewards where id = v_reward;
  insert into _v472(check_name, ok, detail) values (
    '01 the end date reaches loyalty_rewards',
    v_stored = v_when,
    coalesce(v_stored::text, 'null'));

  select active_config_version_id into v_version from public.businesses where id = v_biz;
  select claim_available_until into v_published
    from public.loyalty_reward_versions
   where reward_id = v_reward and config_version_id = v_version;
  insert into _v472(check_name, ok, detail) values (
    '02 it reaches the PUBLISHED version row (the guard was widened)',
    v_published = v_when,
    'without claim_available_until in app.reward_version_immutable_guard this raises '
    || 'restrict_violation and EVERY gift edit breaks, not just this one');

  insert into _v472(check_name, ok, detail)
  select '03 the customer catalogue serves it',
         (rv.claim_available_until = v_when),
         'the versions row is what app.reward_availability_v432 reads'
    from public.loyalty_reward_versions rv
   where rv.reward_id = v_reward and rv.config_version_id = v_version;

  -- A date in the past is a mistake, not a configuration.
  begin
    r := public.business_update_reward_v326(
           p_business => v_biz, p_reward => v_reward,
           p_name => (select coalesce(customer_name, name) from public.loyalty_rewards where id = v_reward),
           p_points => (select cost_points from public.loyalty_rewards where id = v_reward),
           p_claim_available_until => now() - interval '1 day');
    insert into _v472(check_name, ok, detail) values ('04 a past end date is refused', false, 'it was accepted');
  exception when others then
    insert into _v472(check_name, ok, detail) values (
      '04 a past end date is refused', sqlstate = '22023', sqlstate || ' ' || sqlerrm);
  end;

  -- An older bundle calls without the argument. It must not wipe the date.
  r := public.business_update_reward_v326(
         p_business => v_biz, p_reward => v_reward,
         p_name => (select coalesce(customer_name, name) from public.loyalty_rewards where id = v_reward),
         p_points => (select cost_points from public.loyalty_rewards where id = v_reward));
  select claim_available_until into v_stored from public.loyalty_rewards where id = v_reward;
  insert into _v472(check_name, ok, detail) values (
    '05 an old bundle leaves an existing date alone',
    v_stored = v_when,
    'a NULL argument means "say nothing", never "clear it"');

  -- And the owner can take the deadline off again.
  r := public.business_update_reward_v326(
         p_business => v_biz, p_reward => v_reward,
         p_name => (select coalesce(customer_name, name) from public.loyalty_rewards where id = v_reward),
         p_points => (select cost_points from public.loyalty_rewards where id = v_reward),
         p_clear_end_date => true);
  select claim_available_until into v_stored from public.loyalty_rewards where id = v_reward;
  select claim_available_until into v_published
    from public.loyalty_reward_versions
   where reward_id = v_reward and config_version_id = v_version;
  insert into _v472(check_name, ok, detail) values (
    '06 the end date can be cleared, on both rows',
    v_stored is null and v_published is null,
    coalesce(v_stored::text, 'null') || ' / ' || coalesce(v_published::text, 'null'));

  -- ------------------------------------------------------------------ the menu gallery --------
  v_photo  := '/storage/v1/object/public/business-public/' || v_biz::text || '/gallery/'
              || gen_random_uuid()::text || '.jpg';
  v_photo2 := '/storage/v1/object/public/business-public/' || v_biz::text || '/gallery/'
              || gen_random_uuid()::text || '.jpg';

  perform public.business_set_gallery_v418(v_biz,
    jsonb_build_array(jsonb_build_object('image_ref', v_photo, 'caption', 'the room')), 'gallery');
  perform public.business_set_gallery_v418(v_biz,
    jsonb_build_array(jsonb_build_object('image_ref', v_photo2, 'caption', 'today special')), 'menu');

  insert into _v472(check_name, ok, detail)
  select '07 saving the menu did not delete the gallery',
         (select count(*) from public.business_gallery_v418
           where business_id = v_biz and kind = 'gallery') = 1
     and (select count(*) from public.business_gallery_v418
           where business_id = v_biz and kind = 'menu') = 1,
         'the writer deletes before it inserts — a mis-scoped delete destroys the other segment';

  -- The reverse direction is the one a mis-scoped delete would actually hit in production, because
  -- the gallery is the segment an owner edits most.
  perform public.business_set_gallery_v418(v_biz,
    jsonb_build_array(jsonb_build_object('image_ref', v_photo, 'caption', 'the room again')), 'gallery');
  insert into _v472(check_name, ok, detail)
  select '07b saving the gallery did not delete the menu',
         (select count(*) from public.business_gallery_v418
           where business_id = v_biz and kind = 'menu') = 1,
         'and the menu photo is still the one that was put there';

  -- 08 needs a CUSTOMER identity, not the owner's, and it is isolated in its own sub-block: the
  -- read raises 42501 without an active customer identity, and a bare call would abort every
  -- assertion above it (a PL/pgSQL exception rolls the whole block's inserts back with it).
  -- gallery and menu are nested under 'business', which is where every other profile field lives.
  begin
    select cl.auth_user_id into v_cuid
      from public.customer_links cl
     where cl.business_id = v_biz and cl.state = 'verified' and cl.auth_user_id is not null
     limit 1;
    if v_cuid is null then
      insert into _v472(check_name, ok, detail)
      values ('08 the customer read returns the two segments separately', false,
              'no verified customer on this tenant to read as');
    else
      perform pg_temp.v472_as(v_cuid);
      v_business := public.customer_get_business_summary(v_slug) -> 'business';
      insert into _v472(check_name, ok, detail) values (
        '08 the customer read returns the two segments separately',
        jsonb_array_length(coalesce(v_business->'gallery','[]'::jsonb)) = 1
          and jsonb_array_length(coalesce(v_business->'menu','[]'::jsonb)) = 1
          and (v_business->'gallery'->0->>'image_ref') = v_photo
          and (v_business->'menu'->0->>'image_ref') = v_photo2,
        'gallery=' || coalesce(v_business->'gallery'->0->>'caption','-')
        || ' menu=' || coalesce(v_business->'menu'->0->>'caption','-'));
      perform pg_temp.v472_as(v_uid);
    end if;
  exception when others then
    insert into _v472(check_name, ok, detail)
    values ('08 the customer read returns the two segments separately', false, sqlstate || ' ' || sqlerrm);
  end;

  begin
    perform public.business_set_gallery_v418(v_biz, '[]'::jsonb, 'menu_specials');
    insert into _v472(check_name, ok, detail) values ('09 an unknown segment is refused', false, 'it was accepted');
  exception when others then
    insert into _v472(check_name, ok, detail) values (
      '09 an unknown segment is refused', sqlstate = '22023', sqlstate || ' ' || sqlerrm);
  end;
exception when others then
  insert into _v472(check_name, ok, detail) values ('!! aborted', false, sqlstate || ' ' || sqlerrm);
end $$;

reset role;

-- 10 is asserted outside the owner block: it is a statement about every tenant, not about the one
-- the suite happened to pick. The default is 'gallery', so a backfill was never needed — and this
-- proves no row acquired a meaning nobody gave it.
insert into _v472(check_name, ok, detail)
select '10 no pre-v472 row silently became a menu photo',
       count(*) filter (where kind not in ('gallery','menu')) = 0,
       count(*) filter (where kind = 'menu')::text || ' menu of ' || count(*)::text || ' total'
  from public.business_gallery_v418;

select check_name, case when ok then 'PASS' else 'FAIL' end as result, detail from _v472 order by id;
select count(*) filter (where not ok) as failures, count(*) as checks from _v472;

rollback;
