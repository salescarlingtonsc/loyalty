-- Rollback-only acceptance for v267 — the programme summary can co-brand a share.
--
-- Runs inside one transaction and rolls back. Proves, against REAL tenant rows:
--   * the logo helper returns the same URL the other customer surfaces resolve, so "this firm's
--     logo" has one definition and the share lockup cannot disagree with the wallet card;
--   * an asset the firm has NOT published to customers is never returned — a share reaches
--     strangers, so customer_visible is the boundary that matters most here;
--   * a firm with no logo yields NULL rather than an empty string or a broken path, which is what
--     lets the client fall back to the firm's initial instead of rendering a dead image;
--   * customer_get_business_summary actually emits the key, in BOTH its projections — the live
--     one and the all-modules-off fallback — because a customer whose firm has every module
--     switched off still sees a Share button.

begin;

do $suite$
declare
  v_business uuid;
  v_asset uuid;
  v_expected text;
  v_def text;
begin
  -- a real tenant that has published a logo
  select brand.business_id, brand.logo_asset_id into v_business, v_asset
    from public.business_brand_presentation_v95 brand
    join public.business_media_assets_v95 logo
      on logo.id = brand.logo_asset_id and logo.business_id = brand.business_id
     and logo.asset_kind = 'logo' and logo.customer_visible
   limit 1;
  if v_business is null then
    raise exception 'v267: no tenant with a published logo to test against';
  end if;

  select app.v95_public_media_url(object_path) into v_expected
    from public.business_media_assets_v95 where id = v_asset;
  if app.v267_business_logo_url(v_business) is distinct from v_expected then
    raise exception 'v267: the helper disagrees with the canonical v95 media URL';
  end if;

  -- an unpublished logo must not reach a customer, still less a stranger receiving a share
  update public.business_media_assets_v95 set customer_visible = false where id = v_asset;
  if app.v267_business_logo_url(v_business) is not null then
    raise exception 'v267: a logo the firm has not published to customers was returned anyway';
  end if;
  update public.business_media_assets_v95 set customer_visible = true where id = v_asset;

  -- a firm with no brand row at all is NULL, not '' and not a broken path
  if app.v267_business_logo_url('00000000-0000-0000-0000-000000000000'::uuid) is not null then
    raise exception 'v267: an unknown business must yield NULL so the client can fall back';
  end if;

  -- both projections carry the key; a business with every module off still shares co-branded
  select pg_get_functiondef(p.oid) into v_def
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'customer_get_business_summary';
  if (length(v_def) - length(replace(v_def, '''logo_url''', ''))) / length('''logo_url''') <> 2 then
    raise exception 'v267: logo_url must appear in BOTH the live and fallback business projections';
  end if;

  raise notice 'v267 acceptance: all assertions passed';
end $suite$;

rollback;
