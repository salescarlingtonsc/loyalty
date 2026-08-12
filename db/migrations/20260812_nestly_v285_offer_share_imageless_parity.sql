-- Nestly v285 — the shared-offer page shows every offer a customer can see, artwork or not.
--
-- v268's read required published artwork (a non-null media URL predicate), citing parity with
-- customer_get_promotions_v155. That was v155's rule — and v172/v173 deliberately REMOVED it
-- ("a published imageless offer appeared on Home but vanished inside the business page — the
-- two surfaces must always agree"). So v268 shipped mirroring a predicate the app had already
-- retired: an imageless offer renders a full card in the app, its Share button produces a link,
-- and the recipient was 302'd to the marketing homepage — a dead share for exactly the offers
-- small firms without artwork create. One definition of "visible offer" means THE CURRENT one.
--
-- The page itself already handles the absence: og:image is emitted only when there is an image,
-- twitter:card falls back to summary, and the artwork block is skipped. Everything else about
-- the function — anon EXECUTE for link-preview crawlers, primary-key lookup, STABLE,
-- broadcast-marketing-content-only — is unchanged.

begin;

create or replace function public.offer_share_page_v268(p_offer uuid)
returns jsonb
language sql
stable
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $fn$
  select jsonb_build_object(
    'offer_id', content.id,
    'name', coalesce(copy.name,'Offer'),
    'tagline', copy.tagline,
    'description', copy.description,
    'starts_at', content.starts_at,
    'ends_at', content.ends_at,
    'image_url', media.url,
    'image_alt', media.image_alt,
    'business_name', b.name,
    'business_slug', b.slug,
    'business_logo_url', app.v267_business_logo_url(b.id)
  )
  from public.business_customer_content_v95 content
  join public.businesses b on b.id = content.business_id
  left join public.business_localized_copy_v95 copy
    on copy.business_id = content.business_id
   and copy.entity_type = 'offer'
   and copy.entity_id = content.id
   and copy.locale = 'en'
  left join lateral (
    select app.v95_public_media_url(asset.object_path) url, asset.alt_en image_alt
    from public.business_media_assets_v95 asset
    where asset.business_id = content.business_id
      and asset.asset_kind = 'offer'
      and asset.entity_id = content.id
      and asset.customer_visible
      and asset.branch_id is null
    order by asset.updated_at desc, asset.id
    limit 1
  ) media on true
  where content.id = p_offer
    and content.content_type = 'offer'
    and content.active
    and (content.starts_at is null or content.starts_at <= now())
    and content.ends_at > now()
    and nullif(trim(b.slug),'') is not null
  limit 1;
$fn$;

-- CREATE OR REPLACE preserves the grants the deployed function already has; restated so a replay
-- from an empty database lands identically. PUBLIC's default EXECUTE is revoked and anon's is
-- granted back deliberately — the caller is a link-preview crawler that cannot authenticate.
revoke all on function public.offer_share_page_v268(uuid) from public;
grant execute on function public.offer_share_page_v268(uuid) to anon, authenticated, service_role;

commit;
