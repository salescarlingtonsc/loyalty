-- V158: expose customer-visible service/product media to merchant catalogue and Record sale.
-- Existing customer portal media remains governed by business_media_assets_v95 and
-- business_publish_media_replacement_v95; this migration only adds a focused
-- owner-readable version list plus image_url projection in checkout catalogue rows.

create or replace function public.business_get_catalogue_media_versions_v158(
  p_business uuid
)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare
  v_items jsonb;
begin
  if p_business is null then
    raise exception 'business_required' using errcode='22023';
  end if;
  if not (
    app.is_super_admin()
    or app.is_salon_owner(p_business)
  ) then
    raise exception 'owner_required' using errcode='42501';
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
    'asset_kind',asset.asset_kind,
    'entity_id',asset.entity_id,
    'version',asset.version,
    'url',app.v95_public_media_url(asset.object_path)
  ) order by asset.asset_kind,asset.entity_id),'[]'::jsonb)
  into v_items
  from public.business_media_assets_v95 asset
  where asset.business_id=p_business
    and asset.asset_kind in ('service','product')
    and asset.branch_id is null
    and asset.customer_visible;

  return jsonb_build_object('items',v_items);
end
$$;

revoke all on function public.business_get_catalogue_media_versions_v158(uuid) from public;
grant execute on function public.business_get_catalogue_media_versions_v158(uuid) to authenticated;

create or replace function public.business_get_checkout_catalogue_v94(
  p_business uuid,p_branch uuid,p_include_inactive boolean
)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare
  v_branch uuid:=p_branch;
  v_setting public.business_checkout_catalogue_settings_v94%rowtype;
  v_branches jsonb;
  v_items jsonb;
begin
  if p_include_inactive is null then
    raise exception 'include_inactive_required' using errcode='22023';
  end if;
  if v_branch is null then
    select branch.id into v_branch
    from public.branches branch
    where branch.business_id=p_business and branch.active
    order by branch.is_default desc,branch.created_at,branch.id
    limit 1;
  end if;
  if v_branch is null or not exists(
    select 1 from public.branches branch
    where branch.id=v_branch and branch.business_id=p_business and branch.active
  ) then
    raise exception 'active_branch_required' using errcode='22023';
  end if;
  if not (
    app.is_super_admin()
    or app.can_module_read_at_v94(p_business,v_branch,'sales')
    or app.can_module_read_at_v94(p_business,v_branch,'till')
  ) then
    raise exception 'checkout_catalogue_access_required' using errcode='42501';
  end if;
  if p_include_inactive and not (
    app.is_super_admin() or app.is_salon_owner(p_business)
  ) then
    raise exception 'owner_required_for_inactive_catalogue' using errcode='42501';
  end if;

  select * into v_setting
  from public.business_checkout_catalogue_settings_v94
  where business_id=p_business;
  if not found then
    raise exception 'business_not_found' using errcode='22023';
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
    'id',branch.id,'name',branch.name,'is_default',branch.is_default
  ) order by branch.is_default desc,branch.name,branch.id),'[]'::jsonb)
  into v_branches
  from public.branches branch
  where branch.business_id=p_business and branch.active
    and (
      app.is_super_admin()
      or app.can_see_branch(p_business,branch.id)
    );

  with catalogue as (
    select
      'service'::text item_type,service.id item_id,service.name,
      service.price_cents unit_cents,service.active source_active,
      coalesce(item.checkout_active,true) checkout_active,
      (
        not exists(
          select 1 from public.service_branches configured
          where configured.business_id=p_business
            and configured.service_id=service.id
        )
        or exists(
          select 1 from public.service_branches available
          where available.business_id=p_business
            and available.service_id=service.id
            and available.branch_id=v_branch
        )
      ) branch_available,
      coalesce(item.version,0) version,
      app.v95_public_media_url(service_asset.object_path) image_url
    from public.services service
    left join public.business_checkout_catalogue_items_v94 item
      on item.business_id=p_business and item.item_type='service'
      and item.item_id=service.id
    left join public.business_media_assets_v95 service_asset
      on service_asset.business_id=p_business
      and service_asset.asset_kind='service'
      and service_asset.entity_id=service.id
      and service_asset.branch_id is null
      and service_asset.customer_visible
    where service.business_id=p_business
    union all
    select
      'product'::text,product.id,product.name,
      product.retail_price_cents,product.active,
      coalesce(item.checkout_active,true),true,
      coalesce(item.version,0),
      app.v95_public_media_url(product_asset.object_path)
    from public.products product
    left join public.business_checkout_catalogue_items_v94 item
      on item.business_id=p_business and item.item_type='product'
      and item.item_id=product.id
    left join public.business_media_assets_v95 product_asset
      on product_asset.business_id=p_business
      and product_asset.asset_kind='product'
      and product_asset.entity_id=product.id
      and product_asset.branch_id is null
      and product_asset.customer_visible
    where product.business_id=p_business
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'item_type',item_type,'item_id',item_id,'name',name,
    'unit_cents',unit_cents,'checkout_active',checkout_active,
    'branch_available',branch_available,'version',version,
    'image_url',image_url
  ) order by item_type,name,item_id),'[]'::jsonb)
  into v_items
  from catalogue
  where p_include_inactive
     or (source_active and checkout_active and branch_available);

  return jsonb_build_object(
    'platform_allowed',v_setting.platform_allowed,
    'enabled',v_setting.platform_allowed and v_setting.owner_enabled,
    'settings_version',v_setting.version,
    'selected_branch_id',v_branch,
    'branches',v_branches,
    'items',v_items
  );
end
$$;

revoke all on function public.business_get_checkout_catalogue_v94(uuid,uuid,boolean) from public;
grant execute on function public.business_get_checkout_catalogue_v94(uuid,uuid,boolean) to authenticated;
