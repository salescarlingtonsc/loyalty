-- nestly_v325_business_bio
--
-- Owner-authorized exception #1 in the 2026-08-14 Customer Interface cosmetics brief
-- (session codex/v325-customer-interface-cosmetics): a "Company bio" field, shown to
-- customers on the public booking portal, editable from the new Business Profile step.
--
-- Nullable, no default, no backfill — a business that never fills it in shows nothing where
-- it would render, exactly like booking_policy and review_url already do on the same form.
-- One column, one write site (workspaceBrandPanelHtmlV259 / wireWorkspaceBrandV259 in
-- app/app.js), one read site (renderPortal). No RLS change: businesses already has row-level
-- policies letting an owner update their own row and letting anyone read a business's public
-- columns for the portal; bio rides those unchanged.
--
-- The public portal never reads businesses directly — it goes through the public-booking edge
-- function -> internal_public_booking_page() -> get_business_public(), the SECURITY DEFINER
-- read that already exposes booking_policy the same way. bio rides the SAME function, same
-- signature, same grants — no new RPC, no RLS change (get_business_public is SECURITY DEFINER
-- and already public-callable; a plain column add cannot widen what it returns on its own).

begin;

alter table public.businesses
  add column if not exists bio text;

comment on column public.businesses.bio is
  'v325: short company description shown to customers on the public booking portal. '
  'Nullable — blank means nothing is rendered. Edited from Customer Interface > Business Profile.';

create or replace function public.get_business_public(p_slug text)
 returns json
 language sql
 stable security definer
 set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $function$
  select json_build_object(
    'id',business.id,
    'name',business.name,
    'industry',business.industry,
    'currency',business.currency,
    'booking_policy',business.booking_policy,
    'bio',business.bio,
    'brand_color',business.brand_color,
    'services',coalesce((
      select json_agg(json_build_object(
        'id',service.id,
        'name',service.name,
        'price_cents',service.price_cents,
        'duration_min',service.duration_min
      ) order by lower(service.name),service.id)
      from public.services service
      where service.business_id=business.id
        and service.active
        and service.show_on_booking_page
    ),'[]'::json)
  )
  from public.businesses business
  where business.slug=p_slug
$function$;

-- Defense in depth, matching this repo's SECURITY DEFINER convention: revoke Postgres's default
-- PUBLIC execute grant on the exact overload. anon/authenticated already carry their own explicit
-- grants (unchanged by this migration — get_business_public was already the public portal read),
-- so this only removes the implicit PUBLIC grant CREATE FUNCTION assigns, never a working caller.
revoke all on function public.get_business_public(text) from public;

commit;
