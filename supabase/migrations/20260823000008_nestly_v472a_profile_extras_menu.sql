-- nestly_v472a — the OWNER's read learns the menu too.
--
-- Split out of v472 only because it was missed there: v472 taught the customer read
-- (customer_get_business_summary) and the writer (business_set_gallery_v418) about kinds, but the
-- business side has its OWN read, and without this the editor would show the two segments merged
-- into one and then save that merge back over both. Same change, same batch, one statement.
--
-- 'gallery' is scoped rather than left unscoped for exactly that reason: an unscoped list here is
-- not merely a display bug, it is a data-loss path, because business_set_gallery_v418 replaces
-- every row of the kind it is given and the editor posts back what it was shown.

begin;

create or replace function public.business_get_profile_extras_v418(p_business uuid)
returns jsonb
language plpgsql
stable security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $function$
begin
  if not (app.is_salon_owner(p_business) or app.can_module_read(p_business,'dashboard')) then
    raise exception 'business profile access required' using errcode='42501';
  end if;
  return jsonb_build_object(
    'status','ok',
    'gallery', coalesce((select jsonb_agg(jsonb_build_object(
        'id', g.id, 'image_ref', g.image_ref, 'caption', g.caption, 'sort', g.sort)
        order by g.sort, g.created_at)
      from public.business_gallery_v418 g
      where g.business_id = p_business and g.kind = 'gallery'),'[]'::jsonb),
    -- nestly_v472a: the second segment, same shape, same read.
    'menu', coalesce((select jsonb_agg(jsonb_build_object(
        'id', g.id, 'image_ref', g.image_ref, 'caption', g.caption, 'sort', g.sort)
        order by g.sort, g.created_at)
      from public.business_gallery_v418 g
      where g.business_id = p_business and g.kind = 'menu'),'[]'::jsonb),
    'social_links', coalesce((select jsonb_agg(jsonb_build_object(
        'platform', l.platform, 'url', l.url, 'sort', l.sort) order by l.sort, l.platform)
      from public.business_social_links_v418 l where l.business_id = p_business),'[]'::jsonb));
end $function$;

-- Signature is unchanged, so CREATE OR REPLACE preserved the grants; restated per the repo's
-- preflight rule from the live proacl.
revoke all on function public.business_get_profile_extras_v418(uuid) from public, anon;
grant execute on function public.business_get_profile_extras_v418(uuid) to authenticated, service_role;

commit;
