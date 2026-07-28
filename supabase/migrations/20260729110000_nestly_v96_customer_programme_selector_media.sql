-- NESTLY v96 — customer programme selector media.
--
-- Extends the existing actionable wallet projection in-place so one bounded
-- customer RPC returns the current customer-visible logo for every verified
-- programme. The verified customer context remains the only tenant scope.

begin;

create or replace function public.customer_get_actionable_wallet()
returns jsonb
language plpgsql
stable
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_as_of timestamptz := statement_timestamp();
  v_cards jsonb;
  v_truncated boolean := false;
begin
  if auth.uid() is null then
    raise exception 'authenticated customer session required' using errcode = '28000';
  end if;
  if not app.platform_feature_enabled('customer_actionable_wallet') then
    raise exception 'actionable customer wallet is not enabled' using errcode = '0A000';
  end if;

  -- Rank every verified relationship before the 100-card response bound. Logo
  -- media is joined to that same relationship context, never discovered from
  -- a caller-supplied business id or slug.
  select coalesce(jsonb_agg(card order by
    (card#>>'{action,sort_band}')::integer,
    nullif(card#>>'{action,deadline_at}', '')::timestamptz nulls last,
    (card#>>'{action,sort_units}')::integer,
    lower(card#>>'{business,name}'),
    card#>>'{business,slug}'
  ) filter (where action_rank <= 100), '[]'::jsonb),
  coalesce(bool_or(action_rank > 100), false)
    into v_cards, v_truncated
    from (
      select action_cards.card, row_number() over (order by
        (action_cards.card#>>'{action,sort_band}')::integer,
        nullif(action_cards.card#>>'{action,deadline_at}', '')::timestamptz nulls last,
        (action_cards.card#>>'{action,sort_units}')::integer,
        lower(action_cards.card#>>'{business,name}'),
        action_cards.card#>>'{business,slug}'
      ) as action_rank
        from (
          select base.card || jsonb_build_object(
            'business',
            coalesce(base.card->'business', '{}'::jsonb)
              || jsonb_build_object(
                'logo_url', app.v95_public_media_url(logo.object_path)
              )
          ) as card
            from app.v32_customer_wallet_context(null) context
            cross join lateral (
              select app.c44_actionable_wallet_card(
                context.business_id, context.client_id, context.business_slug,
                context.business_name, context.business_industry,
                context.business_currency, context.enabled_modules, v_as_of
              ) as card
            ) base
            left join public.business_brand_presentation_v95 brand
              on brand.business_id = context.business_id
            left join public.business_media_assets_v95 logo
              on logo.id = brand.logo_asset_id
             and logo.business_id = context.business_id
             and logo.asset_kind = 'logo'
             and logo.customer_visible
        ) action_cards
    ) ranked
   where action_rank <= 101;

  return jsonb_build_object(
    'as_of', v_as_of,
    'cards', v_cards,
    'truncated', v_truncated
  );
end;
$$;

create or replace function public.customer_get_programme_selector_media_v96()
returns jsonb
language plpgsql
stable
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_items jsonb;
  v_truncated boolean := false;
begin
  if auth.uid() is null then
    raise exception 'authenticated customer session required' using errcode = '28000';
  end if;

  -- This contract is intentionally independent of the optional actionable
  -- ranking flag. Scope still comes solely from the customer wallet's verified
  -- auth.uid() -> identity -> link resolver and remains bounded for large users.
  select
    coalesce(jsonb_agg(jsonb_build_object(
      'business_slug', ranked.business_slug,
      'logo_url', app.v95_public_media_url(ranked.object_path)
    ) order by ranked.business_slug) filter(where ranked.item_rank<=100),'[]'::jsonb),
    coalesce(bool_or(ranked.item_rank>100),false)
  into v_items,v_truncated
  from (
    select
      context.business_slug,
      logo.object_path,
      row_number() over(order by context.business_slug) item_rank
    from app.v32_customer_wallet_context(null) context
    left join public.business_brand_presentation_v95 brand
      on brand.business_id=context.business_id
    left join public.business_media_assets_v95 logo
      on logo.id=brand.logo_asset_id
     and logo.business_id=context.business_id
     and logo.asset_kind='logo'
     and logo.customer_visible
  ) ranked
  where ranked.item_rank<=101;

  return jsonb_build_object('items',v_items,'truncated',v_truncated);
end;
$$;

comment on function public.customer_get_actionable_wallet() is
  'Bounded actionable cards for verified customer links, including the current customer-visible v95 logo URL.';
comment on function public.customer_get_programme_selector_media_v96() is
  'Bounded customer-visible v95 logo URLs for the current authenticated customer verified links.';

revoke all on function public.customer_get_actionable_wallet()
  from public, anon, authenticated;
grant execute on function public.customer_get_actionable_wallet()
  to authenticated;
revoke all on function public.customer_get_programme_selector_media_v96()
  from public, anon, authenticated;
grant execute on function public.customer_get_programme_selector_media_v96()
  to authenticated;

commit;
