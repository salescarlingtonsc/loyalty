-- nestly_v566 -- one answer about what a customer can claim.
--
-- THE DEFECT: public.customer_get_business_presentation_v95 and
-- public.customer_get_reward_catalog are read by the SAME customer screen, and they disagreed
-- about which rewards exist. The catalogue resolves every reward through
-- app.reward_availability_v432 -- the spine (is this reward's programme switched on?), the
-- PUBLISHED version row (is this gift live, at the pinned config version?), the claim window,
-- and the per-customer gates. The presentation invented its own, far shorter, answer:
--
--     from public.loyalty_rewards reward
--    where reward.business_id=p_business and reward.active and not reward.paused
--
-- No spine check, no published-version join, no claim window. On prod today that shows 9
-- rewards no customer can claim, across six tenants: 8 sit on programmes whose spine row is
-- INACTIVE (Cubbly SPA 2, Hougang ABC 2, KKY demo 2, QA Kaya Toast 1, QA Kopi Lab 1) and 1 is
-- past its claim_available_until (QA Kopi Lab, "Hava a cup of Milk Tea!"). The same screen's
-- reward list refuses them, and the counter refuses them -- a listed gift the counter will not
-- honour is worse than no gift at all, which is exactly the reasoning v495 recorded when it
-- closed this same class of bug for the owner's live preview in app/app.js.
--
-- Imagery disagreed too: the presentation served its own media asset while the catalogue serves
-- the published version's image_ref, so the same reward could carry two different pictures.
--
-- THE FIX (delegation, not a second copy of the predicate): the rewards block now READS
-- app.reward_availability_v432(p_business, v_client, now()). The presentation already resolves
-- a verified v_client above -- it raises 42501 without one -- so the full per-customer answer is
-- available here and there is no customer-agnostic subset to settle for; the tier gate and the
-- usage limit are evaluated for this customer exactly as the catalogue evaluates them. The
-- projection stays the presentation's own (localised name/description/terms, image_url,
-- metadata) so no caller's shape changes.
--
-- Two lifecycle states are dropped rather than shown: 'not_started' and 'ended'. The catalogue
-- keeps those rows because it also carries an `availability` field and the wallet renders them
-- as "Available soon" / "Offer ended" (CUSTOMER_REWARD_AVAILABILITY_COPY_V399). The
-- presentation's reward object has no such field and never has, so an ended reward listed here
-- is an unqualified promise. Every other state -- insufficient_balance, tier_locked,
-- limit_reached, claimed_this_cycle, not_on_card, reward_expired -- is KEPT, because those are
-- rewards the customer really does have, or is working towards, on a programme that is running.
--
-- cost_points / credit_cents now come from the published version rather than the live editor
-- row, which is the number the counter will actually charge (the v416 per-cycle pin). Zero
-- rewards differ between the two on prod today, so this changes no displayed figure now and
-- prevents the two surfaces quoting different prices later.
--
-- TIERS: the same rule. The presentation had `deleted_at is null and not paused` but not
-- app.tier_resolve_v426's other two gates -- the effective_from/expires_at window, and
-- app.programme_running_v371(business,'tiers'). A tenant who switched Tiers OFF still had a
-- tier badge computed for their customers. The metric is deliberately still computed when the
-- ladder is off, exactly as v426 does it, because a reward's min-tier threshold is answered
-- with that metric and that question is about distance travelled, not about which rung the
-- customer stands on.
--
-- NOTHING ELSE MOVES: name, logo, bio, gallery, benefits, offers, services, products, balance,
-- capabilities are byte-identical to the live definition.
--
-- ROLLBACK: db/tests/v566_one_claimable_answer.sql

begin;

do $pre$
declare v_def text;
begin
  v_def := pg_get_functiondef('public.customer_get_business_presentation_v95(uuid,uuid,text)'::regprocedure);
  if position('reward_availability_v432' in v_def) > 0 then
    raise exception 'v566: the presentation already delegates to app.reward_availability_v432';
  end if;
  if position('where reward.business_id=p_business and reward.active and not reward.paused' in v_def) = 0 then
    raise exception 'v566: expected the un-gated rewards predicate to replace -- re-derive from the live definition';
  end if;
  if position('app.client_points_balance_v409(p_business, v_client)' in v_def) = 0 then
    raise exception 'v566: expected the v544 balance shape -- re-derive from the live definition';
  end if;
  if to_regprocedure('app.reward_availability_v432(uuid,uuid,timestamptz)') is null then
    raise exception 'v566: app.reward_availability_v432 is missing';
  end if;
  if to_regprocedure('app.programme_running_v371(uuid,text)') is null then
    raise exception 'v566: app.programme_running_v371 is missing';
  end if;
end
$pre$;

CREATE OR REPLACE FUNCTION public.customer_get_business_presentation_v95(p_business uuid, p_branch uuid DEFAULT NULL::uuid, p_locale text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'app', 'pg_temp'
AS $function$
declare
  v_actor uuid:=auth.uid();v_identity uuid;v_client uuid;v_branch uuid:=p_branch;
  v_locale text;v_programme uuid;v_balance integer:=0;v_unit text:='points';
  v_metric numeric:=0;v_basis text;v_points_programme uuid;
  v_tiers_running boolean:=false; -- nestly_v566
  v_current public.loyalty_tiers%rowtype;
  v_next public.loyalty_tiers%rowtype;v_progress numeric:=0;v_result jsonb;
begin
  if v_actor is null then raise exception 'authenticated_session_required'
    using errcode='28000';end if;
  if p_locale is not null and p_locale not in ('en','zh-CN') then
    raise exception 'unsupported_locale' using errcode='22023';end if;
  v_identity:=app.v31_current_identity();
  select link.client_id into v_client from public.customer_links link
  where link.identity_id=v_identity and link.auth_user_id=v_actor
    and link.business_id=p_business and link.state='verified';
  if not found then raise exception 'verified_customer_link_required'
    using errcode='42501';end if;
  v_locale:=coalesce(
    p_locale,(select locale from public.customer_locale_preferences_v95
      where auth_user_id=v_actor),'en'
  );
  if v_branch is null then
    select id into v_branch from public.branches
    where business_id=p_business and active
    order by is_default desc,created_at,id limit 1;
  end if;
  if v_branch is null or not exists(
    select 1 from public.branches
    where id=v_branch and business_id=p_business and active
  ) then raise exception 'active_branch_required' using errcode='22023';end if;
  select id,case when loyalty_model='stamps' then 'stamps' else 'points' end,
    coalesce(tier_basis,'visits')
  into v_programme,v_unit,v_basis
  from public.loyalty_programs
  where business_id=p_business and active
  order by (current_config_version_id is not null) desc,id limit 1;
  -- v544: LOYALTY_CURRENT_BALANCE_V1. This summed every programme pot, so a customer with a
  -- dormant stamps pot beside a live points pot was shown their two balances added together and
  -- labelled with the live unit (Cubbly: 940 shown, 139 spendable). The canonical primitive
  -- resolves the live pot and the safety scope; the unit beside it is already derived from the
  -- business configuration, so balance and unit now describe the same programme.
  v_balance := app.client_points_balance_v409(p_business, v_client);
  if v_basis='spend' then
    select coalesce(sum(amount_cents),0)/100.0 into v_metric from public.sales
    where business_id=p_business and client_id=v_client and counts_as_revenue;
  elsif v_basis='points_earned' then
    select spine.id into v_points_programme
    from public.business_programmes spine
    where spine.business_id=p_business and spine.kind='points';
    if v_points_programme is null then
      select coalesce(sum(points),0) into v_metric from public.points_ledger
      where business_id=p_business and client_id=v_client and entry_type='earn';
    else
      select coalesce(sum(ledger.points),0) into v_metric from public.points_ledger ledger
      where ledger.business_id=p_business and ledger.client_id=v_client
        and ledger.entry_type='earn' and ledger.programme_id=v_points_programme;
    end if;
  else
    select count(*) into v_metric from public.sales
    where business_id=p_business and client_id=v_client and counts_as_visit;
  end if;
  -- nestly_v566: the ladder only exists while the owner's Tiers switch is on, and a tier only
  -- counts while it is inside its own effective window -- app.tier_resolve_v426's gates, which
  -- this function had drifted away from. The METRIC above is computed either way, exactly as
  -- v426 computes it when the switch is off, because it also answers "how far have I come".
  v_tiers_running := app.programme_running_v371(p_business,'tiers');
  select * into v_current from public.loyalty_tiers
  where business_id=p_business and threshold<=v_metric
    and deleted_at is null and not paused
    and v_tiers_running
    and (effective_from is null or effective_from<=now())
    and (expires_at is null or expires_at>now())
  order by threshold desc,sort desc,id limit 1;
  select * into v_next from public.loyalty_tiers
  where business_id=p_business and threshold>coalesce(v_current.threshold,-1)
    and deleted_at is null and not paused
    and v_tiers_running
    and (effective_from is null or effective_from<=now())
    and (expires_at is null or expires_at>now())
  order by threshold,sort,id limit 1;
  if v_next.id is not null then
    v_progress:=greatest(0,least(100,round(
      (v_metric-coalesce(v_current.threshold,0))*100
      /nullif(v_next.threshold-coalesce(v_current.threshold,0),0),2
    )));
  elsif v_current.id is not null then v_progress:=100;end if;

  with programme_copy as (
    select copy.* from public.business_localized_copy_v95 copy
    where copy.business_id=p_business and copy.entity_type='programme'
      and copy.entity_id=v_programme and copy.locale=v_locale
    limit 1
  ), programme_english as (
    select copy.* from public.business_localized_copy_v95 copy
    where copy.business_id=p_business and copy.entity_type='programme'
      and copy.entity_id=v_programme and copy.locale='en'
    limit 1
  ), visible_media as (
    select distinct on(asset.asset_kind,asset.entity_id)
      asset.asset_kind,asset.entity_id,
      app.v95_public_media_url(asset.object_path) url
    from public.business_media_assets_v95 asset
    where asset.business_id=p_business and asset.customer_visible
      and (asset.branch_id is null or asset.branch_id=v_branch)
    order by asset.asset_kind,asset.entity_id,
      (asset.branch_id=v_branch) desc,asset.updated_at desc,asset.id
  ), benefits as (
    select coalesce(jsonb_agg(jsonb_build_object(
      'id',content.id,
      'name',coalesce(copy.name,english.name,'Benefit'),
      'tagline',coalesce(copy.tagline,english.tagline),
      'description',coalesce(copy.description,english.description),
      'image_url',media.url,'metadata',content.metadata
    ) order by content.display_order,content.id),'[]'::jsonb) value
    from public.business_customer_content_v95 content
    left join public.business_localized_copy_v95 copy
      on copy.business_id=p_business and copy.entity_type='benefit'
      and copy.entity_id=content.id and copy.locale=v_locale
    left join public.business_localized_copy_v95 english
      on english.business_id=p_business and english.entity_type='benefit'
      and english.entity_id=content.id and english.locale='en'
    left join visible_media media
      on media.asset_kind='benefit' and media.entity_id=content.id
    where content.business_id=p_business and content.content_type='benefit'
      and content.active and (content.branch_id is null or content.branch_id=v_branch)
      and (content.starts_at is null or content.starts_at<=now())
      and (content.ends_at is null or content.ends_at>now())
  ), offers as (
    select coalesce(jsonb_agg(jsonb_build_object(
      'id',content.id,
      'name',coalesce(copy.name,english.name,'Offer'),
      'tagline',coalesce(copy.tagline,english.tagline),
      'description',coalesce(copy.description,english.description),
      'terms',coalesce(copy.terms,english.terms),
      'image_url',media.url,'starts_at',content.starts_at,
      'ends_at',content.ends_at,'metadata',content.metadata
    ) order by content.display_order,content.id),'[]'::jsonb) value
    from public.business_customer_content_v95 content
    left join public.business_localized_copy_v95 copy
      on copy.business_id=p_business and copy.entity_type='offer'
      and copy.entity_id=content.id and copy.locale=v_locale
    left join public.business_localized_copy_v95 english
      on english.business_id=p_business and english.entity_type='offer'
      and english.entity_id=content.id and english.locale='en'
    left join visible_media media
      on media.asset_kind='offer' and media.entity_id=content.id
    where content.business_id=p_business and content.content_type='offer'
      and content.active and (content.branch_id is null or content.branch_id=v_branch)
      and (content.starts_at is null or content.starts_at<=now())
      and (content.ends_at is null or content.ends_at>now())
  ), services_json as (
    select coalesce(jsonb_agg(jsonb_build_object(
      'id',service.id,'name',coalesce(copy.name,english.name,service.name),
      'description',coalesce(copy.description,english.description),
      'image_url',media.url,'price_cents',service.price_cents,
      'duration_min',service.duration_min
    ) order by service.name,service.id),'[]'::jsonb) value
    from public.services service
    left join public.business_localized_copy_v95 copy
      on copy.business_id=p_business and copy.entity_type='service'
      and copy.entity_id=service.id and copy.locale=v_locale
    left join public.business_localized_copy_v95 english
      on english.business_id=p_business and english.entity_type='service'
      and english.entity_id=service.id and english.locale='en'
    left join visible_media media
      on media.asset_kind='service' and media.entity_id=service.id
    where service.business_id=p_business and service.active
      and service.show_on_booking_page
      and (not exists(select 1 from public.service_branches configured
        where configured.business_id=p_business and configured.service_id=service.id)
        or exists(select 1 from public.service_branches available
          where available.business_id=p_business and available.service_id=service.id
            and available.branch_id=v_branch))
  ), products_json as (
    select coalesce(jsonb_agg(jsonb_build_object(
      'id',product.id,'name',coalesce(copy.name,english.name,product.name),
      'description',coalesce(copy.description,english.description),
      'image_url',media.url,'price_cents',product.retail_price_cents
    ) order by product.name,product.id),'[]'::jsonb) value
    from public.products product
    left join public.business_localized_copy_v95 copy
      on copy.business_id=p_business and copy.entity_type='product'
      and copy.entity_id=product.id and copy.locale=v_locale
    left join public.business_localized_copy_v95 english
      on english.business_id=p_business and english.entity_type='product'
      and english.entity_id=product.id and english.locale='en'
    left join visible_media media
      on media.asset_kind='product' and media.entity_id=product.id
    where product.business_id=p_business and product.active
  ), claimable_rewards as (
    -- nestly_v566: ONE definition of "a reward this customer has". The catalogue's own core,
    -- read with this screen's own verified client, so the two lists on one screen cannot differ.
    -- 'not_started'/'ended' are dropped because this projection carries no availability field to
    -- qualify them with; every other state is a reward the customer really holds or is earning.
    select core.reward_id,core.customer_name,core.description,core.terms,core.image_ref,
      core.cost_points,core.credit_cents,core.sort
    from app.reward_availability_v432(p_business,v_client,now()) core
    where core.availability not in ('not_started','ended')
  ), rewards_json as (
    select coalesce(jsonb_agg(jsonb_build_object(
      'id',reward.reward_id,
      'name',coalesce(copy.name,english.name,nullif(btrim(reward.customer_name),''),live.name),
      'description',coalesce(copy.description,english.description),
      'terms',coalesce(copy.terms,english.terms),
      -- The published version's picture first: that is the one the reward list beside this block
      -- already shows. The presentation's own media asset stays as the fallback for a version
      -- that carries none, so no tenant loses an image it had yesterday.
      'image_url',coalesce(nullif(btrim(reward.image_ref),''),media.url),
      'metadata',jsonb_build_object(
        'cost_points',reward.cost_points,'credit_cents',reward.credit_cents
      )
    ) order by reward.sort,reward.reward_id),'[]'::jsonb) value
    from claimable_rewards reward
    join public.loyalty_rewards live
      on live.id=reward.reward_id and live.business_id=p_business
    left join public.business_localized_copy_v95 copy
      on copy.business_id=p_business and copy.entity_type='reward'
      and copy.entity_id=reward.reward_id and copy.locale=v_locale
    left join public.business_localized_copy_v95 english
      on english.business_id=p_business and english.entity_type='reward'
      and english.entity_id=reward.reward_id and english.locale='en'
    left join visible_media media
      on media.asset_kind='reward' and media.entity_id=reward.reward_id
  )
  select jsonb_build_object(
    'business_id',business.id,'branch_id',v_branch,'locale',v_locale,
    'available_locales',jsonb_build_array('en','zh-CN'),
    'brand',jsonb_build_object(
      'logo_url',app.v95_public_media_url(logo.object_path),
      'hero_image_url',app.v95_public_media_url(hero.object_path),
      'hero_color',brand.hero_color
    ),
    'programme',jsonb_build_object(
      'id',v_programme,
      'name',coalesce(programme_copy.name,programme_english.name,
        business.name||' Loyalty'),
      'tagline',coalesce(programme_copy.tagline,programme_english.tagline),
      'description',coalesce(
        programme_copy.description,programme_english.description
      ),
      'balance',v_balance,'unit',v_unit,
      'tier',jsonb_build_object(
        'label',coalesce(tier_copy.name,tier_english.name,v_current.name),
        'current',case when v_current.id is null then null else jsonb_build_object(
          'id',v_current.id,'threshold',v_current.threshold,'metric',v_metric
        ) end,
        'next',case when v_next.id is null then null else jsonb_build_object(
          'id',v_next.id,'label',coalesce(next_copy.name,next_english.name,v_next.name),
          'threshold',v_next.threshold
        ) end,
        'progress_percent',v_progress
      ),
      'benefits',benefits.value,'offers',offers.value
    ),
    'catalogue',jsonb_build_object(
      'services',services_json.value,'products',products_json.value,
      'rewards',rewards_json.value
    ),
    'capabilities',jsonb_build_object(
      'booking_enabled',coalesce(capability.booking_enabled,false)
        and app.v89_business_module_enabled(p_business,'bookings')
        and jsonb_array_length(services_json.value)>0,
      'redemption_enabled',coalesce(capability.redemption_enabled,false)
        and app.v89_business_module_enabled(p_business,'loyalty')
        and v_programme is not null,
      'appointment_changes_enabled',
        coalesce(capability.appointment_changes_enabled,false)
        and app.v89_business_module_enabled(p_business,'appointments')
    )
  ) into v_result
  from public.businesses business
  join public.business_brand_presentation_v95 brand
    on brand.business_id=business.id
  left join public.business_media_assets_v95 logo
    on logo.id=brand.logo_asset_id and logo.customer_visible
    and (logo.branch_id is null or logo.branch_id=v_branch)
  left join public.business_media_assets_v95 hero
    on hero.id=brand.hero_asset_id and hero.customer_visible
    and (hero.branch_id is null or hero.branch_id=v_branch)
  left join public.business_customer_capabilities_v89 capability
    on capability.business_id=business.id
  left join programme_copy on true
  left join programme_english on true
  left join public.business_localized_copy_v95 tier_copy
    on tier_copy.business_id=p_business and tier_copy.entity_type='tier'
    and tier_copy.entity_id=v_current.id and tier_copy.locale=v_locale
  left join public.business_localized_copy_v95 tier_english
    on tier_english.business_id=p_business and tier_english.entity_type='tier'
    and tier_english.entity_id=v_current.id and tier_english.locale='en'
  left join public.business_localized_copy_v95 next_copy
    on next_copy.business_id=p_business and next_copy.entity_type='tier'
    and next_copy.entity_id=v_next.id and next_copy.locale=v_locale
  left join public.business_localized_copy_v95 next_english
    on next_english.business_id=p_business and next_english.entity_type='tier'
    and next_english.entity_id=v_next.id and next_english.locale='en'
  cross join benefits cross join offers cross join services_json
  cross join products_json cross join rewards_json
  where business.id=p_business;
  return v_result;
end
$function$;

-- CREATE OR REPLACE preserves grants; restated per governance (the live ACL, unchanged).
revoke all on function public.customer_get_business_presentation_v95(uuid,uuid,text) from public, anon;
grant execute on function public.customer_get_business_presentation_v95(uuid,uuid,text) to authenticated, service_role;

comment on function public.customer_get_business_presentation_v95(uuid,uuid,text) is
  'v310 D1 twin: the points_earned tier metric is scoped to the v308 points spine row, fail-OPEN. The programme BALANCE stays the business pot, byte-identical to v95 -- W4 policy rule 1. nestly_v566: rewards are app.reward_availability_v432 for this verified client (minus not_started/ended, which this projection cannot qualify), and tiers obey app.tier_resolve_v426''s gates -- running programme, not paused, not deleted, inside the effective window.';

commit;
