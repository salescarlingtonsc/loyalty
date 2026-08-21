-- nestly_v418 — a business profile gets a gallery and its social links.
--
-- OWNER, 2026-08-21 (photo 10, drawn beside Save Profile):
--   "1. i want to add another segment in customer app, which is editable here — i want to be able
--       to upload menu or other gallery photos to business profile
--    2. add biz social media links"
--
-- This is the one item in that batch that is a FEATURE rather than a correction: nothing here was
-- broken, there was simply nowhere to put a menu photo or an Instagram handle. So it is built the
-- way the surrounding surfaces already work rather than inventing a second way of doing things:
--   * images go to the SAME storage bucket and path grammar every other business image uses
--     (business-public, <business_id>/<kind>/<uuid>.<ext>), so one storage policy governs them all;
--   * the customer reads them through customer_get_business_summary, the read that already carries
--     the name, logo, industry and bio — no new customer-facing endpoint;
--   * both writers are owner-only through app.is_salon_owner, the same gate the logo upload uses.
--
-- REPLACE-SET, not add/remove. Both writers take the whole list and make the stored set equal it.
-- A gallery is a handful of photos an owner reorders by dragging, and a per-item add/remove API
-- would need its own ordering rules, its own idempotency and its own reconciliation when the two
-- disagree. One statement, one truth, and a save that is safe to repeat.

begin;

-- ============================================================================================
-- 1. STORAGE: 'gallery' joins the kinds an owner may write under their own business id
-- ============================================================================================
-- The kind whitelist appears in exactly two places and they must agree: this guard (which the
-- storage policies call) and customerMediaUrlV95 in app/app.js (which refuses to render a URL
-- that does not match). Both gain 'gallery' in this change.
create or replace function app.v95_storage_path_owned(p_name text)
returns boolean
language plpgsql
stable
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
begin
  if coalesce(p_name,'')!~(
    '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}'||
    '/(logo|hero|programme|reward|product|service|benefit|offer|gallery)'||
    '/[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\.(png|jpg|jpeg|webp|gif)$'
  )
  then return false;end if;
  return app.is_salon_owner(split_part(p_name,'/',1)::uuid);
end $$;

-- ============================================================================================
-- 2. THE GALLERY
-- ============================================================================================
create table if not exists public.business_gallery_v418(
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  image_ref text not null,
  caption text,
  sort integer not null default 0,
  created_at timestamptz not null default now(),
  created_by uuid,
  constraint business_gallery_v418_caption_len check (caption is null or length(caption) <= 140),
  constraint business_gallery_v418_sort_range check (sort >= 0 and sort < 100)
);
create index if not exists business_gallery_v418_business_sort_idx
  on public.business_gallery_v418(business_id, sort, created_at);
alter table public.business_gallery_v418 enable row level security;

drop policy if exists business_gallery_v418_owner_all on public.business_gallery_v418;
create policy business_gallery_v418_owner_all on public.business_gallery_v418
  for all using (app.is_salon_owner(business_id)) with check (app.is_salon_owner(business_id));
-- Staff may READ what customers will see; only an owner edits the profile.
drop policy if exists business_gallery_v418_staff_read on public.business_gallery_v418;
create policy business_gallery_v418_staff_read on public.business_gallery_v418
  for select using (app.can_module_read(business_id, 'dashboard'));

-- The browser's ACL, stated rather than inherited. Reads go through RLS (an owner sees their own
-- rows, dashboard-read staff see them too); WRITES do not go through the browser at all — they go
-- through the owner-gated SECURITY DEFINER writers below, so insert/update/delete are withheld
-- here and a compromised session cannot rewrite a firm's profile by talking to PostgREST directly.
revoke all on table public.business_gallery_v418 from public, anon, authenticated;
grant select on table public.business_gallery_v418 to authenticated;

comment on table public.business_gallery_v418 is
  'v418: photos a business shows customers on its profile - menu boards, the room, the work. '
  'image_ref holds a business-public storage URL under <business_id>/gallery/. Owner-writable, '
  'read by customers only through public.customer_get_business_summary.';

-- ============================================================================================
-- 3. THE SOCIAL LINKS
-- ============================================================================================
-- A fixed platform set rather than free text: the customer app renders an icon per platform, and
-- a row it cannot name is a row it cannot draw. 'website' is included because a firm without any
-- social account still has somewhere to send people.
create table if not exists public.business_social_links_v418(
  business_id uuid not null references public.businesses(id) on delete cascade,
  platform text not null,
  url text not null,
  sort integer not null default 0,
  updated_at timestamptz not null default now(),
  primary key (business_id, platform),
  constraint business_social_links_v418_platform_check check (platform = any(array[
    'website','instagram','facebook','tiktok','whatsapp','youtube','telegram','xiaohongshu'])),
  -- https only. A profile link is one a customer taps from their phone; http would be a
  -- downgrade the firm did not choose and cannot see.
  -- A POSIX repetition bound may not exceed 255, so the length lives in its own predicate rather
  -- than inside the pattern; {3,300} is not a valid regex and would have failed at insert time.
  constraint business_social_links_v418_url_https
    check (url ~ '^https://[^[:space:]]+$' and length(url) between 11 and 300)
);
alter table public.business_social_links_v418 enable row level security;

drop policy if exists business_social_links_v418_owner_all on public.business_social_links_v418;
create policy business_social_links_v418_owner_all on public.business_social_links_v418
  for all using (app.is_salon_owner(business_id)) with check (app.is_salon_owner(business_id));
drop policy if exists business_social_links_v418_staff_read on public.business_social_links_v418;
create policy business_social_links_v418_staff_read on public.business_social_links_v418
  for select using (app.can_module_read(business_id, 'dashboard'));

-- The browser's ACL, stated rather than inherited. Reads go through RLS (an owner sees their own
-- rows, dashboard-read staff see them too); WRITES do not go through the browser at all — they go
-- through the owner-gated SECURITY DEFINER writers below, so insert/update/delete are withheld
-- here and a compromised session cannot rewrite a firm's profile by talking to PostgREST directly.
revoke all on table public.business_social_links_v418 from public, anon, authenticated;
grant select on table public.business_social_links_v418 to authenticated;

comment on table public.business_social_links_v418 is
  'v418: a business''s own links, shown on its customer profile. One row per platform, https only.';


-- ============================================================================================
-- 4. THE WRITERS
-- ============================================================================================
-- Replace-set. p_items is the gallery the owner is looking at, in the order they arranged it;
-- after this call the stored set equals it exactly. Anything they removed is gone, anything they
-- added is there, and running the same save twice changes nothing the second time.
create or replace function public.business_set_gallery_v418(
  p_business uuid, p_items jsonb default '[]'::jsonb
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare
  v_count integer;
begin
  if not app.is_salon_owner(p_business) then
    raise exception 'owner access required to edit the business profile' using errcode='42501';
  end if;
  if jsonb_typeof(coalesce(p_items,'[]'::jsonb)) <> 'array' then
    raise exception 'gallery must be a list of photos' using errcode='22023';
  end if;
  select count(*) into v_count from jsonb_array_elements(coalesce(p_items,'[]'::jsonb));
  if v_count > 12 then
    raise exception 'a profile gallery holds up to 12 photos' using errcode='23514';
  end if;

  /* Every image must be one THIS business owns, in the gallery folder. The check is here and not
     only in the browser because the browser is not a place a rule can live: without it an owner
     could point a row at another firm's storage object and the customer app would render it. */
  if exists(
    select 1 from jsonb_array_elements(coalesce(p_items,'[]'::jsonb)) item
     where coalesce(item->>'image_ref','') !~ (
       '/storage/v1/object/public/business-public/'||p_business::text||'/gallery/'||
       '[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\.(png|jpg|jpeg|webp|gif)$')
  ) then
    raise exception 'a gallery photo must be an image uploaded to this business' using errcode='22023';
  end if;

  delete from public.business_gallery_v418 where business_id = p_business;
  insert into public.business_gallery_v418(business_id, image_ref, caption, sort, created_by)
  select p_business,
         item->>'image_ref',
         nullif(btrim(coalesce(item->>'caption','')),''),
         (ordinality - 1)::integer,
         auth.uid()
    from jsonb_array_elements(coalesce(p_items,'[]'::jsonb)) with ordinality as t(item, ordinality);

  insert into public.audit_log(business_id, actor, action, entity, entity_id, detail)
  values (p_business, auth.uid(), 'business_profile.gallery_set', 'businesses', p_business,
    jsonb_build_object('photos', v_count));

  return jsonb_build_object('status','ok','photos', v_count);
end $$;

revoke all on function public.business_set_gallery_v418(uuid,jsonb) from public, anon;
grant execute on function public.business_set_gallery_v418(uuid,jsonb) to authenticated;

create or replace function public.business_set_social_links_v418(
  p_business uuid, p_links jsonb default '[]'::jsonb
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare
  v_count integer;
begin
  if not app.is_salon_owner(p_business) then
    raise exception 'owner access required to edit the business profile' using errcode='42501';
  end if;
  if jsonb_typeof(coalesce(p_links,'[]'::jsonb)) <> 'array' then
    raise exception 'links must be a list' using errcode='22023';
  end if;

  delete from public.business_social_links_v418 where business_id = p_business;
  /* The platform and https CHECKs on the table do the validating, so a bad row raises with the
     constraint's own message rather than a second, hand-written copy of the same rule that could
     drift from it. Blank urls are dropped rather than refused: an owner clearing one field should
     not have to delete the row to save the others. */
  insert into public.business_social_links_v418(business_id, platform, url, sort)
  select p_business,
         lower(btrim(link->>'platform')),
         btrim(link->>'url'),
         (ordinality - 1)::integer
    from jsonb_array_elements(coalesce(p_links,'[]'::jsonb)) with ordinality as t(link, ordinality)
   where btrim(coalesce(link->>'url','')) <> '';
  get diagnostics v_count = row_count;

  insert into public.audit_log(business_id, actor, action, entity, entity_id, detail)
  values (p_business, auth.uid(), 'business_profile.links_set', 'businesses', p_business,
    jsonb_build_object('links', v_count));

  return jsonb_build_object('status','ok','links', v_count);
end $$;

revoke all on function public.business_set_social_links_v418(uuid,jsonb) from public, anon;
grant execute on function public.business_set_social_links_v418(uuid,jsonb) to authenticated;

-- ============================================================================================
-- 5. THE WORKSPACE READ
-- ============================================================================================
-- The Business Profile page needs its own gallery and links back to edit them. RLS already lets
-- an owner select both tables directly, but one round trip beats two and keeps the page's read
-- shaped like the payload it edits.
create or replace function public.business_get_profile_extras_v418(p_business uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
begin
  if not (app.is_salon_owner(p_business) or app.can_module_read(p_business,'dashboard')) then
    raise exception 'business profile access required' using errcode='42501';
  end if;
  return jsonb_build_object(
    'status','ok',
    'gallery', coalesce((select jsonb_agg(jsonb_build_object(
        'id', g.id, 'image_ref', g.image_ref, 'caption', g.caption, 'sort', g.sort)
        order by g.sort, g.created_at)
      from public.business_gallery_v418 g where g.business_id = p_business),'[]'::jsonb),
    'social_links', coalesce((select jsonb_agg(jsonb_build_object(
        'platform', l.platform, 'url', l.url, 'sort', l.sort) order by l.sort, l.platform)
      from public.business_social_links_v418 l where l.business_id = p_business),'[]'::jsonb));
end $$;

revoke all on function public.business_get_profile_extras_v418(uuid) from public, anon;
grant execute on function public.business_get_profile_extras_v418(uuid) to authenticated;


-- ============================================================================================
-- 6. THE CUSTOMER READ
-- ============================================================================================
-- Extracted from production and patched programmatically, then diffed: 13 added lines, no line
-- removed and none changed. Everything else in this payload — name, slug, industry,
-- industry_label, currency, logo, review_url, bio, the loyalty block — is byte-for-byte v417's.
CREATE OR REPLACE FUNCTION public.customer_get_business_summary(p_business_slug text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'app', 'pg_temp'
AS $function$
declare
  v_actor uuid := auth.uid();
  v_context record;
  v_summary jsonb;
begin
  if v_actor is null then
    raise exception 'authenticated customer session required' using errcode = '28000';
  end if;
  if not app.platform_feature_enabled('customer_wallet') then
    raise exception 'customer wallet is not enabled' using errcode = '0A000';
  end if;

  select identity_id, business_id, client_id, business_name, business_slug,
         business_industry, business_currency, enabled_modules into v_context
    from app.v32_customer_wallet_context(p_business_slug)
   limit 1;
  if not found then
    raise exception 'verified customer link required' using errcode = '42501';
  end if;

  select jsonb_build_object(
    'business', jsonb_build_object(
      'id', v_context.business_id,
      'slug', v_context.business_slug,
      'name', v_context.business_name,
      'industry', v_context.business_industry,
      -- V385: the firm's OWN wording for what it does, shown under the business name in the
      -- customer app. Read straight off the row rather than added to the wallet context, so the
      -- context view keeps the shape every other caller of it already depends on.
      'industry_label', (select b.industry_label from public.businesses b where b.id = v_context.business_id),
      -- nestly_v417 (owner, photo 7: an arrow from the workspace's "Company bio" field to the line
      -- under the business name in the customer app, "show here as bio"). The column has existed
      -- since v325 and the workspace has always edited it; no customer read ever returned it, so
      -- everything a firm wrote there was only ever visible to the firm. Same shape as
      -- industry_label above: a scalar subquery off the row, leaving v32_customer_wallet_context
      -- untouched for every other caller.
      'bio', (select b.bio from public.businesses b where b.id = v_context.business_id),
      -- nestly_v418 (owner, photo 10): the profile's own gallery and links, on the read that
      -- already carries the name, logo, industry and bio. No new customer endpoint, so nothing
      -- else about what a customer may fetch changed.
      'gallery', coalesce((select jsonb_agg(jsonb_build_object('image_ref', g.image_ref,
                                                              'caption', g.caption)
                             order by g.sort, g.created_at)
                             from public.business_gallery_v418 g
                            where g.business_id = v_context.business_id),'[]'::jsonb),
      'social_links', coalesce((select jsonb_agg(jsonb_build_object('platform', l.platform,
                                                                   'url', l.url)
                                  order by l.sort, l.platform)
                                  from public.business_social_links_v418 l
                                 where l.business_id = v_context.business_id),'[]'::jsonb),
      'currency', v_context.business_currency,
      'logo_url', app.v267_business_logo_url(v_context.business_id),
      'review_url', (select b.review_url from public.businesses b where b.id = v_context.business_id)
    ),
    'loyalty', app.customer_live_loyalty_v384(
      v_context.business_id, v_context.client_id, v_context.enabled_modules, now()
    ),
    'packages', jsonb_build_object(
      'enabled', 'packages' = any(v_context.enabled_modules),
      'active_count', case when 'packages' = any(v_context.enabled_modules) then coalesce((
        select count(*)::integer
          from public.client_packages cp
         where cp.business_id = v_context.business_id
           and cp.client_id = v_context.client_id
           and cp.status = 'active'
           and cp.remaining > 0
      ), 0) else 0 end,
      'sessions_remaining', case when 'packages' = any(v_context.enabled_modules) then coalesce((
        select sum(cp.remaining)::integer
          from public.client_packages cp
         where cp.business_id = v_context.business_id
           and cp.client_id = v_context.client_id
           and cp.status = 'active'
           and cp.remaining > 0
      ), 0) else 0 end
    ),
    'membership', jsonb_build_object(
      'enabled', 'memberships' = any(v_context.enabled_modules),
      'active', case when 'memberships' = any(v_context.enabled_modules) then exists (
        select 1 from public.memberships m
         where m.business_id = v_context.business_id
           and m.client_id = v_context.client_id
           and m.status in ('active', 'paused', 'cancel_at_period_end')
      ) else false end,
      'current_period_ends_at', case when 'memberships' = any(v_context.enabled_modules) then (
        select min(m.current_period_end)
          from public.memberships m
         where m.business_id = v_context.business_id
           and m.client_id = v_context.client_id
           and m.status in ('active', 'paused', 'cancel_at_period_end')
      ) end
    ),
    'upcoming_appointments', jsonb_build_object(
      'enabled', 'appointments' = any(v_context.enabled_modules),
      'count', case when 'appointments' = any(v_context.enabled_modules) then (
        select count(*)::integer
          from public.appointments a
         where a.business_id = v_context.business_id
           and a.client_id = v_context.client_id
           and a.status = 'booked'
           and a.starts_at >= now()
      ) else 0 end
    )
  ) into v_summary;

  return v_summary;
end;
$function$;

revoke all on function public.customer_get_business_summary(text) from public, anon;
grant execute on function public.customer_get_business_summary(text) to authenticated, service_role;

commit;
