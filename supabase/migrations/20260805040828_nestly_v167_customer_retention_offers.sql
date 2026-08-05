-- Peekaa v167 — bounded customer Home offers and canonical merchant supply status.
-- The customer reader derives authority only from auth.uid() -> verified links.

begin;

create or replace function public.customer_get_home_offers_v167(
  p_locale text default 'en'
)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare
  v_actor uuid := auth.uid();
  v_identity uuid;
  v_items jsonb;
  v_pending_redemption jsonb;
  v_truncated boolean := false;
begin
  if v_actor is null then
    raise exception 'authenticated_customer_session_required' using errcode='28000';
  end if;
  if p_locale not in ('en','zh-CN') then
    raise exception 'supported_locale_required' using errcode='22023';
  end if;
  v_identity := app.v31_current_identity();

  select jsonb_build_object(
    'intent_id',intent.id,
    'expires_at',intent.expires_at,
    'business',jsonb_build_object(
      'id',business.id,
      'slug',business.slug,
      'name',business.name
    ),
    'reward_name',coalesce(reward.name,'reward')
  ) into v_pending_redemption
  from public.customer_redemption_intents_v89 intent
  join public.businesses business on business.id=intent.business_id
  left join public.loyalty_rewards reward on reward.id=intent.reward_id
  where intent.identity_id=v_identity
    and intent.auth_user_id=v_actor
    and intent.status='pending'
    and intent.expires_at>statement_timestamp()
  order by intent.created_at desc,intent.id
  limit 1;

  -- v32_customer_wallet_context is the canonical verified-link resolver. The
  -- caller cannot nominate a customer, identity, business, or tenant.
  with ranked as (
    select
      content.id,
      content.version,
      content.updated_at,
      content.display_order,
      content.starts_at,
      content.ends_at,
      content.metadata,
      context.business_id,
      context.business_slug,
      context.business_name,
      coalesce(copy.name,english.name,'Offer') name,
      coalesce(copy.tagline,english.tagline) tagline,
      coalesce(copy.description,english.description) description,
      coalesce(copy.terms,english.terms) terms,
      media.url image_url,
      media.image_alt,
      app.v95_public_media_url(logo.object_path) logo_url,
      branches.names branch_names,
      exists(select 1 from public.promotion_branch_scopes_v155 mapped where mapped.promotion_id=content.id) branch_scoped,
      row_number() over(order by
        content.ends_at asc,
        content.display_order asc,
        content.updated_at desc,
        content.id
      ) item_rank
    from app.v32_customer_wallet_context(null) context
    join public.business_customer_content_v95 content
      on content.business_id=context.business_id
     and content.content_type='offer'
     and content.active
     and content.branch_id is null
     and (content.starts_at is null or content.starts_at<=statement_timestamp())
     and content.ends_at>statement_timestamp()
     and (
       not exists(select 1 from public.promotion_branch_scopes_v155 mapped where mapped.promotion_id=content.id)
       or exists(
         select 1
         from public.promotion_branch_scopes_v155 mapped
         join public.branches active_branch
           on active_branch.id=mapped.branch_id
          and active_branch.business_id=context.business_id
          and coalesce(active_branch.active,true)
         where mapped.promotion_id=content.id
           and mapped.business_id=context.business_id
       )
     )
    left join public.business_localized_copy_v95 copy
      on copy.business_id=context.business_id
     and copy.entity_type='offer'
     and copy.entity_id=content.id
     and copy.locale=p_locale
    left join public.business_localized_copy_v95 english
      on english.business_id=context.business_id
     and english.entity_type='offer'
     and english.entity_id=content.id
     and english.locale='en'
    join lateral(
      select app.v95_public_media_url(asset.object_path) url,
        case when p_locale='zh-CN'
          then coalesce(asset.alt_zh_cn,asset.alt_en)
          else asset.alt_en
        end image_alt
      from public.business_media_assets_v95 asset
      where asset.business_id=context.business_id
        and asset.asset_kind='offer'
        and asset.entity_id=content.id
        and asset.customer_visible
        and asset.branch_id is null
      order by asset.updated_at desc,asset.id
      limit 1
    ) media on true
    left join public.business_brand_presentation_v95 brand
      on brand.business_id=context.business_id
    left join public.business_media_assets_v95 logo
      on logo.id=brand.logo_asset_id
     and logo.business_id=context.business_id
     and logo.asset_kind='logo'
     and logo.customer_visible
    left join lateral(
      select coalesce(jsonb_agg(branch.name order by branch.name),'[]'::jsonb) names
      from public.promotion_branch_scopes_v155 mapped
      join public.branches branch
        on branch.id=mapped.branch_id
       and branch.business_id=context.business_id
       and coalesce(branch.active,true)
      where mapped.promotion_id=content.id
        and mapped.business_id=context.business_id
    ) branches on true
  ), bounded as (
    select * from ranked where item_rank<=13
  )
  select
    coalesce(jsonb_agg(jsonb_build_object(
      'id',bounded.id,
      'version_id',bounded.id::text||':'||bounded.version::text,
      'name',bounded.name,
      'tagline',bounded.tagline,
      'description',bounded.description,
      'terms',bounded.terms,
      'image_url',bounded.image_url,
      'image_alt',bounded.image_alt,
      'starts_at',bounded.starts_at,
      'ends_at',bounded.ends_at,
      'display_order',bounded.display_order,
      'metadata',bounded.metadata,
      'business',jsonb_build_object(
        'id',bounded.business_id,
        'slug',bounded.business_slug,
        'name',bounded.business_name,
        'logo_url',bounded.logo_url
      ),
      'branch_names',bounded.branch_names,
      'availability_label',case
        when bounded.branch_scoped then 'Available at '||(
          select string_agg(value,' and ' order by value)
          from jsonb_array_elements_text(bounded.branch_names) value
        )
        else 'Available at all branches'
      end
    ) order by bounded.item_rank) filter(where bounded.item_rank<=12),'[]'::jsonb),
    coalesce(bool_or(bounded.item_rank>12),false)
  into v_items,v_truncated
  from bounded;

  return jsonb_build_object(
    'as_of',statement_timestamp(),
    'items',v_items,
    'pending_redemption',v_pending_redemption,
    'limit',12,
    'truncated',v_truncated
  );
end
$$;

create or replace function public.business_get_visible_promotion_count_v167(
  p_business uuid
)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare
  v_count integer;
begin
  if auth.uid() is null or p_business is null then
    raise exception 'authenticated_business_context_required' using errcode='28000';
  end if;
  if not app.is_salon_owner(p_business) then
    raise exception 'owner_required' using errcode='42501';
  end if;

  select count(*)::integer into v_count
  from public.business_customer_content_v95 content
  where content.business_id=p_business
    and content.content_type='offer'
    and content.active
    and content.branch_id is null
    and (content.starts_at is null or content.starts_at<=statement_timestamp())
    and content.ends_at>statement_timestamp()
    and (
      not exists(select 1 from public.promotion_branch_scopes_v155 mapped where mapped.promotion_id=content.id)
      or exists(
        select 1
        from public.promotion_branch_scopes_v155 mapped
        join public.branches active_branch
          on active_branch.id=mapped.branch_id
         and active_branch.business_id=p_business
         and coalesce(active_branch.active,true)
        where mapped.promotion_id=content.id
          and mapped.business_id=p_business
      )
    )
    and exists(
      select 1
      from public.business_media_assets_v95 asset
      where asset.business_id=p_business
        and asset.asset_kind='offer'
        and asset.entity_id=content.id
        and asset.customer_visible
        and asset.branch_id is null
    );

  return jsonb_build_object(
    'business_id',p_business,
    'visible_count',v_count,
    'as_of',statement_timestamp()
  );
end
$$;

comment on function public.customer_get_home_offers_v167(text) is
  'At most twelve current offers across auth.uid() verified customer links; no caller-supplied ownership identifier.';
comment on function public.business_get_visible_promotion_count_v167(uuid) is
  'Owner-only canonical count of currently customer-visible published promotions.';

revoke all on function public.customer_get_home_offers_v167(text) from public,anon;
grant execute on function public.customer_get_home_offers_v167(text) to authenticated;
revoke all on function public.business_get_visible_promotion_count_v167(uuid) from public,anon;
grant execute on function public.business_get_visible_promotion_count_v167(uuid) to authenticated;

commit;
