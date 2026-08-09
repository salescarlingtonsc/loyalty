-- Nestly v267 — the programme summary carries the firm's logo.
--
-- Owner: "you can put peekaa x (company name) - with our logos together."
--
-- A share now goes out CO-BRANDED: the Peekaa mark and the firm's mark side by side. The Peekaa
-- mark is a static asset, but the firm's mark has to come from the server, and
-- customer_get_business_summary — the RPC behind the programme page, where the Share button
-- lives — was the one customer projection that did not return it. Without this the lockup would
-- fall back to the firm's initial for EVERY business, on every share, forever: co-branding in
-- name only.
--
-- The lookup is the same one every other customer surface uses (v95 brand presentation → the
-- business's customer_visible logo asset → the public media URL), so a firm's logo is one fact
-- with one definition, not a per-RPC reimplementation. customer_visible is load-bearing: an asset
-- the firm has not published to customers must not reach a customer's screen, still less a
-- stranger's phone.
--
-- Nothing else about the function changes. It is reproduced in full because it is plpgsql and
-- there is no way to amend one key of a jsonb_build_object in place; the diff against the
-- deployed definition is exactly the two 'logo_url' lines — one in the live projection, one in
-- the all-modules-off fallback, which must not disagree about who the business is.

begin;

-- One definition of "this firm's customer-facing logo", so the live projection and the fallback
-- projection below cannot drift apart. Lives in app (never exposed through PostgREST) and is
-- STABLE + SECURITY INVOKER: it is only ever reached from inside an already-authorised customer
-- RPC that has resolved the caller's verified link, and it must not become a way to read brand
-- assets outside one.
create or replace function app.v267_business_logo_url(p_business uuid)
returns text
language sql
stable
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $fn$
  select app.v95_public_media_url(logo.object_path)
    from public.business_brand_presentation_v95 brand
    join public.business_media_assets_v95 logo
      on logo.id = brand.logo_asset_id
     and logo.business_id = brand.business_id
     and logo.asset_kind = 'logo'
     and logo.customer_visible
   where brand.business_id = p_business
   limit 1;
$fn$;

create or replace function public.customer_get_business_summary(p_business_slug text)
 returns jsonb
 language plpgsql
 stable security definer
 set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $function$
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

  -- The app context resolves auth.uid() through customer_links with link status = 'verified'.
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
      'currency', v_context.business_currency,
      'logo_url', app.v267_business_logo_url(v_context.business_id),
      'review_url', (select b.review_url from public.businesses b where b.id = v_context.business_id)
    ),
    'loyalty', jsonb_build_object(
      'enabled', 'loyalty' = any(v_context.enabled_modules) and coalesce(lp.active, false),
      'model', case when 'loyalty' = any(v_context.enabled_modules) and coalesce(lp.active, false)
                    then lp.loyalty_model end,
      'unit', case when 'loyalty' = any(v_context.enabled_modules) and coalesce(lp.active, false)
                     then case when lp.loyalty_model = 'stamps' then 'stamps' else 'points' end end,
      'balance', case when 'loyalty' = any(v_context.enabled_modules) and coalesce(lp.active, false) then coalesce((
        select sum(pl.points)::integer
          from public.points_ledger pl
         where pl.business_id = v_context.business_id
           and pl.client_id = v_context.client_id
      ), 0) else 0 end,
      'credit_balance_cents', case when 'loyalty' = any(v_context.enabled_modules) and coalesce(lp.active, false) then coalesce((
        select sum(cl.amount_cents)::integer
          from public.credit_ledger cl
         where cl.business_id = v_context.business_id
           and cl.client_id = v_context.client_id
      ), 0) else 0 end
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
  ) into v_summary
    from (select 1) scope
    left join public.loyalty_programs lp
      on lp.business_id = v_context.business_id;

  return coalesce(v_summary, jsonb_build_object(
    'business', jsonb_build_object(
      'id', v_context.business_id,
      'slug', v_context.business_slug,
      'name', v_context.business_name,
      'industry', v_context.business_industry,
      'currency', v_context.business_currency,
      'logo_url', app.v267_business_logo_url(v_context.business_id),
      'review_url', (select b.review_url from public.businesses b where b.id = v_context.business_id)
    ),
    'loyalty', jsonb_build_object(
      'enabled', false,
      'model', null,
      'unit', null,
      'balance', 0,
      'credit_balance_cents', 0
    ),
    'packages', jsonb_build_object('enabled', false, 'active_count', 0, 'sessions_remaining', 0),
    'membership', jsonb_build_object('enabled', false, 'active', false, 'current_period_ends_at', null),
    'upcoming_appointments', jsonb_build_object('enabled', false, 'count', 0)
  ));
end;
$function$;

-- CREATE OR REPLACE keeps the grants an existing database already has, so this changes nothing in
-- production — it is here so a REPLAY from an empty database lands in the same place. PostgreSQL
-- grants EXECUTE to PUBLIC on every new function, and a SECURITY DEFINER RPC that anon can call is
-- the whole tenant's data behind one unauthenticated request.
revoke all on function public.customer_get_business_summary(text) from public, anon;
grant execute on function public.customer_get_business_summary(text) to authenticated, service_role;
revoke all on function app.v267_business_logo_url(uuid) from public, anon;

commit;
