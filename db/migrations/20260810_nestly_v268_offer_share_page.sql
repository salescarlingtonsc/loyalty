-- Nestly v268 — one public read for the shared-offer landing page.
--
-- Owner: "yes please build the public offer page" — the follow-on to v264/v267's share button.
-- A link shared to WhatsApp or Facebook is fetched by THEIR crawler, which never runs
-- JavaScript and never authenticates. Today every shared link previews as generic Peekaa
-- branding because the SPA's hash routes all serve one static index.html. The fix is a
-- server-rendered page at /o/<offer-id> (a Vercel function), and that page needs exactly one
-- thing from the database: the offer as a customer would see it.
--
-- Why this is deliberately ANON-callable when v14's hard-won rule is that anon RPCs are the
-- enemy: the caller is a link-preview crawler. It cannot hold a session and cannot solve a
-- Turnstile. What it reads is the single most public data in the system — marketing content the
-- business created precisely so strangers would see it, behind an unguessable uuid the customer
-- chose to broadcast. The function exposes nothing a verified customer of that business does not
-- already get from customer_get_promotions_v155, takes no free-text predicate (a primary-key
-- lookup, nothing to enumerate with), and is STABLE read-only.
--
-- Visibility mirrors customer_get_promotions_v155 EXACTLY — active, inside its date window,
-- with published (customer_visible, unbranched) artwork. An offer the customer list would not
-- show, this page will not show either: one definition of "visible offer", so unpublishing an
-- offer kills its share links at the same moment it leaves the app. A miss returns NULL and the
-- page redirects to the business's public page rather than 404ing a recipient.

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
    and media.url is not null
    and nullif(trim(b.slug),'') is not null
  limit 1;
$fn$;

revoke all on function public.offer_share_page_v268(uuid) from public;
grant execute on function public.offer_share_page_v268(uuid) to anon, authenticated, service_role;

commit;
