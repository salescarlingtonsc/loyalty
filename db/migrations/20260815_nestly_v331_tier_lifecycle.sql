-- Nestly v331 — Tiered membership gets a real parallel immediate-write page
--
-- Owner ruling ("proceed all at once", 2026-08-15): build a full parallel immediate-write Tiers
-- page, NOT a read-only view layered onto the existing draft/publish tier editor.
--
-- Pre-migration audit found a materially harder landmine than the gift (v326) or membership
-- (v329) lifecycles: `public.loyalty_tiers` has NO `active` column at all today, and its
-- publish mechanism (public.publish_loyalty_config) does a full DELETE + INSERT of every tier
-- row for the business on every single publish — not just when tiers themselves changed. The
-- INSERT only ever knows what the draft being published carried in `loyalty_tier_versions`.
-- That means an immediate-write `paused`/`deleted_at` flag living only on `loyalty_tiers` would
-- be silently wiped the very next time ANYONE publishes ANY draft for that business (even one
-- that only touched the earning rate) — a much bigger blast radius than v326's "an already-open
-- draft could resurrect a delete" risk, because it is triggered by ANY future publish, forever,
-- not just one pre-existing stale draft.
--
-- Two prior features (v176 reward tier gate, v278 bar bottle-keep) already had to solve "a tier
-- can vanish out from under a reference" — both explicitly reject a real foreign key on
-- loyalty_tiers.id for the exact same delete+reinsert reason, and both capture a fallback value
-- instead. This migration follows the same house lesson for the live table itself:
--   1. loyalty_tiers gets `paused boolean not null default false` and `deleted_at timestamptz`.
--   2. Three new immediate-write RPCs: business_create_tier_v331, business_set_tier_paused_v331,
--      business_delete_tier_v331 (auth: app.c45_owner_loyalty_write, matching every other loyalty
--      config writer). Creating a tier ALSO mirror-inserts a matching loyalty_tier_versions row
--      at the business's currently published config version (and, if one exists, any currently
--      OPEN draft's version too) — appending a row is allowed even to a published version
--      (trg_loyalty_tier_versions_immutable only blocks UPDATE/DELETE), and is what makes a
--      brand-new tier survive a FUTURE publish or a future draft clone (create_loyalty_config_draft
--      clones tiers from the last published version's loyalty_tier_versions, not from the live
--      table). Pausing/deleting an EXISTING tier does NOT attempt to touch loyalty_tier_versions
--      at all (its published rows are immutable, and it isn't necessary — see next point).
--   3. publish_loyalty_config is patched to capture (id,paused,deleted_at) for every affected tier
--      immediately before its delete+reinsert, and restore that state onto whichever tier_ids
--      survive the reinsert immediately after. This is a table-snapshot carry-over, not tied to
--      any specific draft, so it durably protects a paused/deleted tier against EVERY future
--      publish, not just the one that happened to be open when it was paused/deleted.
--   4. Every function that reads live loyalty_tiers to rank a customer into a tier, gate a reward,
--      or advertise the tiers capability is patched to exclude paused/deleted rows — the full
--      list, from an exhaustive audit of every current reader of the table:
--        - app.loyalty_tier_for (the earn-multiplier resolver on_sale_recorded calls)
--        - public.customer_get_effective_tier_v143 (customer "your tier + ladder", 3 sites)
--        - app.v176_reward_gate_threshold / app.v176_reward_gate_label (reward tier-gate)
--        - public.customer_get_business_presentation_v95 (storefront presentation, 2 sites)
--        - public.customer_portal_capabilities (advertises the tiers capability)
--      plus four lower-severity admin/write-time sites, filtered on deleted_at only (a paused
--      tier is still fine to show/reference in an owner-facing setup screen):
--        - app.business_programmes_v307 (superseded diagnostic/self-heal path, not live-read)
--        - public.bar_get_bottle_setup_v278 / public.bar_save_tier_keep_days_v278 (bar sector)
--        - app.v95_entity_in_business (localized-copy authoring validator)
--
-- Note: min_tier_id / min_tier_threshold on loyalty_rewards is untouched by this migration --
-- it was already designed (v176) around exactly this "tier can vanish" risk, with its own frozen
-- fallback, and the app.v176_reward_gate_threshold patch above is the only change it needs.

begin;

alter table public.loyalty_tiers add column if not exists paused boolean not null default false;
alter table public.loyalty_tiers add column if not exists deleted_at timestamptz;
comment on column public.loyalty_tiers.paused is
  'v331: immediate-write off switch, set by business_set_tier_paused_v331. A paused tier is '
  'excluded from every live customer-facing tier computation (loyalty_tier_for, the customer '
  'tier/ladder RPCs, the reward tier-gate) but keeps its row -- turning it back on restores it '
  'exactly as it was. Survives publish_loyalty_config''s tier delete+reinsert via an explicit '
  'capture/restore in that function (see its own comment).';
comment on column public.loyalty_tiers.deleted_at is
  'v331: set once, by business_delete_tier_v331, when an owner deletes a tier from the Tiers '
  'page. NULL = not deleted. Also implies paused=true. Survives publish_loyalty_config''s tier '
  'delete+reinsert the same way `paused` does.';

-- 4a. app.loyalty_tier_for -- the earn-multiplier resolver. Full body verbatim, one added clause.
create or replace function app.loyalty_tier_for(p_business uuid, p_client uuid)
returns public.loyalty_tiers
language plpgsql
stable security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_basis text;
  v_metric numeric;
  v_row public.loyalty_tiers%rowtype;
  v_points_programme uuid;
begin
  select tier_basis into v_basis
  from public.loyalty_programs
  where business_id=p_business;
  v_basis:=coalesce(v_basis,'visits');
  if v_basis='visits' then
    select count(*) into v_metric from public.sales
    where business_id=p_business and client_id=p_client and counts_as_visit;
  elsif v_basis='spend' then
    select coalesce(sum(amount_cents),0)/100.0 into v_metric from public.sales
    where business_id=p_business and client_id=p_client and counts_as_revenue;
  else
    select spine.id into v_points_programme
      from public.business_programmes spine
     where spine.business_id=p_business and spine.kind='points';
    if v_points_programme is null then
      select coalesce(sum(points),0) into v_metric from public.points_ledger
      where business_id=p_business and client_id=p_client and entry_type='earn';
    else
      select coalesce(sum(pl.points),0) into v_metric from public.points_ledger pl
      where pl.business_id=p_business and pl.client_id=p_client
        and pl.entry_type='earn' and pl.programme_id=v_points_programme;
    end if;
  end if;
  select * into v_row from public.loyalty_tiers
  where business_id=p_business
    and threshold<=v_metric
    and deleted_at is null and not paused
    and (effective_from is null or effective_from<=statement_timestamp())
    and (expires_at is null or expires_at>statement_timestamp())
  order by threshold desc,sort desc,id
  limit 1;
  return v_row;
end
$$;
revoke all privileges on function app.loyalty_tier_for(uuid,uuid) from public, anon, authenticated;

-- 4b. public.customer_get_effective_tier_v143 -- customer "your tier + ladder". Full body
-- verbatim, three added clauses (current, next, ladder).
create or replace function public.customer_get_effective_tier_v143(p_business uuid)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_identity uuid;
  v_client uuid;
  v_basis text;
  v_metric numeric:=0;
  v_points_programme uuid;
  v_current public.loyalty_tiers%rowtype;
  v_next public.loyalty_tiers%rowtype;
  v_progress numeric:=0;
  v_tiers jsonb;
begin
  if auth.uid() is null then
    raise exception 'authenticated customer session required' using errcode='28000';
  end if;
  v_identity:=app.v31_current_identity();
  select link.client_id into v_client
  from public.customer_links link
  where link.identity_id=v_identity
    and link.auth_user_id=auth.uid()
    and link.business_id=p_business
    and link.state='verified';
  if not found then
    raise exception 'verified customer link required' using errcode='42501';
  end if;
  if not app.business_module_enabled_at_v117(p_business,'loyalty',null)
     or not exists(
       select 1 from public.loyalty_programs
       where business_id=p_business and active
     ) then
    raise exception 'loyalty module is unavailable for this business' using errcode='42501';
  end if;

  select coalesce(tier_basis,'visits') into v_basis
  from public.loyalty_programs
  where business_id=p_business and active
  limit 1;
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

  select * into v_current from public.loyalty_tiers
  where business_id=p_business
    and threshold<=v_metric
    and deleted_at is null and not paused
    and (effective_from is null or effective_from<=statement_timestamp())
    and (expires_at is null or expires_at>statement_timestamp())
  order by threshold desc,sort desc,id limit 1;
  select * into v_next from public.loyalty_tiers
  where business_id=p_business
    and threshold>coalesce(v_current.threshold,-1)
    and deleted_at is null and not paused
    and (effective_from is null or effective_from<=statement_timestamp())
    and (expires_at is null or expires_at>statement_timestamp())
  order by threshold,sort,id limit 1;
  if v_next.id is not null then
    v_progress:=greatest(0,least(100,round(
      (v_metric-coalesce(v_current.threshold,0))*100
      /nullif(v_next.threshold-coalesce(v_current.threshold,0),0),2
    )));
  elsif v_current.id is not null then
    v_progress:=100;
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
    'id',ladder.id,
    'label',ladder.name,
    'threshold',ladder.threshold,
    'achieved',ladder.threshold<=v_metric,
    'current',ladder.id=v_current.id,
    'benefits',coalesce((
      select jsonb_agg(btrim(benefit) order by ordinal)
      from regexp_split_to_table(coalesce(ladder.perk_note,''),E'\\r?\\n')
        with ordinality as item(benefit,ordinal)
      where btrim(benefit)<>''
    ),'[]'::jsonb)
  ) order by ladder.threshold,ladder.sort,ladder.id),'[]'::jsonb) into v_tiers
  from public.loyalty_tiers ladder
  where ladder.business_id=p_business
    and ladder.deleted_at is null and not ladder.paused
    and (ladder.effective_from is null or ladder.effective_from<=statement_timestamp())
    and (ladder.expires_at is null or ladder.expires_at>statement_timestamp());

  return jsonb_build_object('tier',jsonb_build_object(
    'points_mode',(select points_mode from public.businesses where id=p_business),
    'label',v_current.name,
    'current',case when v_current.id is null then null else jsonb_build_object(
      'id',v_current.id,'label',v_current.name,'threshold',v_current.threshold,
      'metric',v_metric,'benefits',coalesce((
        select jsonb_agg(btrim(benefit) order by ordinal)
        from regexp_split_to_table(coalesce(v_current.perk_note,''),E'\\r?\\n')
          with ordinality as item(benefit,ordinal)
        where btrim(benefit)<>''
      ),'[]'::jsonb)
    ) end,
    'next',case when v_next.id is null then null else jsonb_build_object(
      'id',v_next.id,'label',v_next.name,'threshold',v_next.threshold,
      'benefits',coalesce((
        select jsonb_agg(btrim(benefit) order by ordinal)
        from regexp_split_to_table(coalesce(v_next.perk_note,''),E'\\r?\\n')
          with ordinality as item(benefit,ordinal)
        where btrim(benefit)<>''
      ),'[]'::jsonb)
    ) end,
    'tiers',v_tiers,
    'progress_percent',v_progress,'basis',v_basis,'metric',v_metric,
    'tier_fuel','points_programme_earn','balance_scope',app.programme_balance_scope_v312(p_business)
  ));
end
$$;
revoke all privileges on function public.customer_get_effective_tier_v143(uuid) from public, anon, authenticated;
grant execute on function public.customer_get_effective_tier_v143(uuid) to authenticated;

-- 4c. app.v176_reward_gate_threshold / app.v176_reward_gate_label -- reward tier-gate. Full
-- bodies verbatim, one added clause each. Own header comment: "Deleting a tier must never open
-- a gate" -- pausing one must not either.
create or replace function app.v176_reward_gate_threshold(p_business uuid, p_min_tier_id uuid, p_min_tier_threshold integer)
returns integer
language plpgsql
stable security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_live integer;
begin
  if p_min_tier_id is null and p_min_tier_threshold is null then
    return null;
  end if;
  if p_min_tier_id is not null then
    select threshold into v_live
      from public.loyalty_tiers
     where business_id = p_business and id = p_min_tier_id
       and deleted_at is null and not paused
     limit 1;
    if v_live is not null then
      return v_live;
    end if;
  end if;
  return p_min_tier_threshold;
end $$;
revoke all privileges on function app.v176_reward_gate_threshold(uuid,uuid,integer) from public, anon, authenticated;

create or replace function app.v176_reward_gate_label(p_business uuid, p_min_tier_id uuid)
returns text
language sql
stable security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
  select t.name from public.loyalty_tiers t
   where t.business_id = p_business and t.id = p_min_tier_id
     and t.deleted_at is null and not t.paused
   limit 1;
$$;
revoke all privileges on function app.v176_reward_gate_label(uuid,uuid) from public, anon, authenticated;

-- 4d. public.customer_get_business_presentation_v95 -- storefront presentation. Full body
-- verbatim, two added clauses (current, next).
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
  select coalesce(sum(points),0)::integer into v_balance
  from public.points_ledger
  where business_id=p_business and client_id=v_client;
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
  select * into v_current from public.loyalty_tiers
  where business_id=p_business and threshold<=v_metric
    and deleted_at is null and not paused
  order by threshold desc,sort desc,id limit 1;
  select * into v_next from public.loyalty_tiers
  where business_id=p_business and threshold>coalesce(v_current.threshold,-1)
    and deleted_at is null and not paused
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
  ), rewards_json as (
    select coalesce(jsonb_agg(jsonb_build_object(
      'id',reward.id,'name',coalesce(copy.name,english.name,reward.name),
      'description',coalesce(copy.description,english.description),
      'terms',coalesce(copy.terms,english.terms),
      'image_url',media.url,
      'metadata',jsonb_build_object(
        'cost_points',reward.cost_points,'credit_cents',reward.credit_cents
      )
    ) order by reward.sort,reward.id),'[]'::jsonb) value
    from public.loyalty_rewards reward
    left join public.business_localized_copy_v95 copy
      on copy.business_id=p_business and copy.entity_type='reward'
      and copy.entity_id=reward.id and copy.locale=v_locale
    left join public.business_localized_copy_v95 english
      on english.business_id=p_business and english.entity_type='reward'
      and english.entity_id=reward.id and english.locale='en'
    left join visible_media media
      on media.asset_kind='reward' and media.entity_id=reward.id
    where reward.business_id=p_business and reward.active and not reward.paused
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
revoke all privileges on function public.customer_get_business_presentation_v95(uuid,uuid,text) from public, anon, authenticated;
grant execute on function public.customer_get_business_presentation_v95(uuid,uuid,text) to authenticated;

-- 4e. public.customer_portal_capabilities -- advertises the tiers capability. Full body verbatim,
-- one added clause (v_tiers).
CREATE OR REPLACE FUNCTION public.customer_portal_capabilities(p_business_slug text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'app', 'pg_temp'
AS $function$
declare
  v_context record;
  v_points_mode text;
  v_points_active boolean;
  v_tiers_active boolean;
  v_wallet boolean;
  v_rewards boolean;
  v_tiers boolean;
  v_programmes jsonb;
  v_balance_scope text;
begin
  if auth.uid() is null then
    raise exception 'authenticated customer session required'
      using errcode='28000';
  end if;

  select *
    into v_context
    from app.v32_customer_wallet_context(p_business_slug)
   limit 1;
  if not found then
    raise exception 'verified customer link required'
      using errcode='42501';
  end if;

  select coalesce(bool_or(spine.active) filter (where spine.kind='points'),false),
         coalesce(bool_or(spine.active) filter (where spine.kind='tiers'),false)
    into v_points_active, v_tiers_active
    from public.business_programmes spine
   where spine.business_id=v_context.business_id;
  v_points_mode := case
    when v_points_active and v_tiers_active then 'both'
    when v_tiers_active then 'tiers'
    else 'redeem'
  end;

  v_wallet :=
    'loyalty'=any(v_context.enabled_modules)
    and exists(
      select 1
        from public.loyalty_programs program
       where program.business_id=v_context.business_id
         and program.active
    );

  v_rewards :=
    'loyalty'=any(v_context.enabled_modules)
    and v_points_active
    and exists(
      select 1
        from public.loyalty_programs program
       where program.business_id=v_context.business_id
         and (
           (
             program.loyalty_model='classic'
             and program.kind='points'
             and program.redeem_points>0
             and program.reward_credit_cents>0
           )
           or exists(
             select 1
               from public.loyalty_reward_versions reward_version
               join public.businesses business
                 on business.id=reward_version.business_id
                and business.active_config_version_id=
                  reward_version.config_version_id
              where reward_version.business_id=v_context.business_id
                and reward_version.active
           )
         )
    );

  v_tiers :=
    'loyalty'=any(v_context.enabled_modules)
    and v_tiers_active
    and exists(
      select 1
        from public.loyalty_tiers tier
       where tier.business_id=v_context.business_id
         and tier.deleted_at is null and not tier.paused
    );

  v_balance_scope := app.programme_balance_scope_v312(v_context.business_id);
  select coalesce(jsonb_agg(jsonb_build_object(
           'kind', spine.kind,
           'active', spine.active,
           'customer_visible', case spine.kind
                                 when 'points' then v_rewards
                                 when 'tiers' then v_tiers
                                 when 'stamps' then (v_wallet and spine.active)
                                 else spine.active
                               end,
           'running_since', spine.activated_at,
           'paused_since', spine.deactivated_at,
           'balance_scope', v_balance_scope
         ) order by spine.sort), '[]'::jsonb)
    into v_programmes
    from public.business_programmes spine
   where spine.business_id=v_context.business_id;

  return jsonb_build_object(
    'wallet', v_wallet,
    'rewards', v_rewards,
    'tiers', v_tiers,
    'points_mode', v_points_mode,
    'activity',
      'loyalty'=any(v_context.enabled_modules)
      and exists(
        select 1
          from public.loyalty_programs program
         where program.business_id=v_context.business_id
           and program.active
      )
      and (
        exists(
          select 1
            from public.points_ledger ledger
           where ledger.business_id=v_context.business_id
             and ledger.client_id=v_context.client_id
        )
        or exists(
          select 1
            from public.loyalty_redemptions redemption
           where redemption.business_id=v_context.business_id
             and redemption.client_id=v_context.client_id
        )
        or exists(
          select 1
            from public.reward_grants grant_row
           where grant_row.business_id=v_context.business_id
             and grant_row.client_id=v_context.client_id
        )
      ),
    'appointments',
      'appointments'=any(v_context.enabled_modules)
      and exists(
        select 1
          from public.appointments appointment
         where appointment.business_id=v_context.business_id
           and appointment.client_id=v_context.client_id
      ),
    'booking_request',
      'bookings'=any(v_context.enabled_modules)
      and exists(
        select 1
          from public.services service
         where service.business_id=v_context.business_id
           and service.active
      ),
    'packages',
      'packages'=any(v_context.enabled_modules)
      and exists(
        select 1
          from public.client_packages customer_package
         where customer_package.business_id=v_context.business_id
           and customer_package.client_id=v_context.client_id
      ),
    'membership',
      'memberships'=any(v_context.enabled_modules)
      and exists(
        select 1
          from public.memberships membership
         where membership.business_id=v_context.business_id
           and membership.client_id=v_context.client_id
      ),
    'programmes_contract', 'v310',
    'programmes', v_programmes
  );
end
$function$;
revoke all privileges on function public.customer_portal_capabilities(text) from public, anon, authenticated;
grant execute on function public.customer_portal_capabilities(text) to authenticated;

-- 4f. Lower-severity admin/write-time sites. deleted_at filter only -- a paused tier is still
-- fine to manage/reference in an owner-facing setup screen; only a deleted one should vanish.
create or replace function app.business_programmes_v307(p_business uuid)
returns table(kind text, running boolean)
language sql
stable
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
  with business_mode as (
    select (
      select business.points_mode
        from public.businesses business
       where business.id = p_business
    ) as points_mode
  ),
  programme_state as (
    select
      exists(
        select 1
          from public.loyalty_programs program
         where program.business_id = p_business
           and program.active
           and program.loyalty_model in ('classic','points_tiers')
      )
      and coalesce(business_mode.points_mode,'redeem') <> 'tiers'
        as points_running,
      exists(
        select 1
          from public.loyalty_programs program
         where program.business_id = p_business
           and program.active
      )
      and coalesce(business_mode.points_mode,'tiers') in ('tiers','both')
      and exists(
        select 1
          from public.loyalty_tiers tier
         where tier.business_id = p_business
           and tier.deleted_at is null
      )
        as tiers_running,
      exists(
        select 1
          from public.loyalty_programs program
         where program.business_id = p_business
           and program.active
           and program.loyalty_model = 'stamps'
      ) as stamps_running,
      exists(
        select 1
          from public.referral_programs referral_program
         where referral_program.business_id = p_business
           and referral_program.enabled
      ) as referral_running
    from business_mode
  )
  select
    programme.programme_kind,
    case programme.programme_kind
      when 'points' then programme_state.points_running
      when 'tiers' then programme_state.tiers_running
      when 'stamps' then programme_state.stamps_running
      when 'referral' then programme_state.referral_running
    end
  from programme_state
  cross join (values
    (1,'points'),
    (2,'tiers'),
    (3,'stamps'),
    (4,'referral')
  ) as programme(sort_order, programme_kind)
  order by programme.sort_order
$$;

create or replace function public.bar_get_bottle_setup_v278(p_business uuid)
returns jsonb
language plpgsql
stable security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_tiers jsonb;
  v_products jsonb;
begin
  perform app.require_bar_business_v275(p_business);
  perform app.require_bar_staff_v275(p_business, false);

  select coalesce(jsonb_agg(jsonb_build_object(
           'tier_id', tier.id,
           'name', tier.name,
           'threshold', tier.threshold,
           'keep_days', keep.keep_days
         ) order by tier.threshold, tier.sort, tier.id), '[]'::jsonb)
    into v_tiers
    from public.loyalty_tiers tier
    left join public.bar_tier_keep_days_v278 keep
      on keep.business_id = tier.business_id and keep.tier_id = tier.id
   where tier.business_id = p_business and tier.deleted_at is null;

  select coalesce(jsonb_agg(jsonb_build_object(
           'id', product.id,
           'name', product.name,
           'size_ml', product.size_ml,
           'price_cents', product.retail_price_cents,
           'is_bottle', product.size_ml is not null
         ) order by (product.size_ml is null), product.name, product.id), '[]'::jsonb)
    into v_products
    from public.products product
   where product.business_id = p_business and product.active;

  return jsonb_build_object(
    'status', 'ok',
    'keep_days', app.bar_keep_days_v275(p_business),
    'reminder_days', app.bar_expiry_reminder_days_v282(p_business),
    'can_edit', app.is_salon_owner(p_business),
    'tiers', v_tiers,
    'products', v_products);
end;
$$;
revoke all privileges on function public.bar_get_bottle_setup_v278(uuid) from public, anon, authenticated;
grant execute on function public.bar_get_bottle_setup_v278(uuid) to authenticated;

create or replace function public.bar_save_tier_keep_days_v278(p_business uuid, p_tiers jsonb)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_actor uuid := auth.uid();
  v_entry jsonb;
  v_tier uuid;
  v_days integer;
  v_kept uuid[] := '{}'::uuid[];
begin
  perform app.require_bar_business_v275(p_business);
  if v_actor is null then
    raise exception 'authenticated staff required' using errcode = '28000';
  end if;
  if not app.is_salon_owner(p_business) then
    raise exception 'only the owner can change bottle keep setup' using errcode = '42501';
  end if;
  if p_tiers is not null and jsonb_typeof(p_tiers) <> 'array' then
    raise exception 'tier keep windows must be a list' using errcode = '22023';
  end if;

  for v_entry in select value from jsonb_array_elements(coalesce(p_tiers, '[]'::jsonb)) loop
    v_tier := nullif(v_entry->>'tier_id', '')::uuid;
    if v_tier is null then
      raise exception 'a tier keep window needs a tier' using errcode = '22023';
    end if;
    if not exists (select 1 from public.loyalty_tiers tier
                    where tier.id = v_tier and tier.business_id = p_business
                      and tier.deleted_at is null) then
      raise exception 'that tier does not belong to this business' using errcode = '22023';
    end if;
    v_days := nullif(v_entry->>'keep_days', '')::integer;
    if v_days is null then
      delete from public.bar_tier_keep_days_v278 keep
       where keep.business_id = p_business and keep.tier_id = v_tier;
    else
      if v_days < 1 or v_days > 365 then
        raise exception 'a tier keep window must be between 1 and 365 days' using errcode = '22023';
      end if;
      insert into public.bar_tier_keep_days_v278 (business_id, tier_id, keep_days, updated_at, updated_by)
      values (p_business, v_tier, v_days, now(), v_actor)
      on conflict (business_id, tier_id) do update
        set keep_days = excluded.keep_days,
            updated_at = excluded.updated_at,
            updated_by = excluded.updated_by;
    end if;
    v_kept := array_append(v_kept, v_tier);
  end loop;

  delete from public.bar_tier_keep_days_v278 keep
   where keep.business_id = p_business
     and not (keep.tier_id = any (v_kept));

  return public.bar_get_bottle_setup_v278(p_business);
end;
$$;
revoke all privileges on function public.bar_save_tier_keep_days_v278(uuid,jsonb) from public, anon, authenticated;
grant execute on function public.bar_save_tier_keep_days_v278(uuid,jsonb) to authenticated;

create or replace function app.v95_entity_in_business(
  p_business uuid,p_entity_type text,p_entity uuid
)
returns boolean
language sql
stable security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
  select case p_entity_type
    when 'programme' then exists(select 1 from public.loyalty_programs
      where id=p_entity and business_id=p_business)
    when 'reward' then exists(select 1 from public.loyalty_rewards
      where id=p_entity and business_id=p_business)
    when 'product' then exists(select 1 from public.products
      where id=p_entity and business_id=p_business)
    when 'service' then exists(select 1 from public.services
      where id=p_entity and business_id=p_business)
    when 'tier' then exists(select 1 from public.loyalty_tiers
      where id=p_entity and business_id=p_business and deleted_at is null)
    when 'benefit' then exists(select 1 from public.business_customer_content_v95
      where id=p_entity and business_id=p_business and content_type='benefit')
    when 'offer' then exists(select 1 from public.business_customer_content_v95
      where id=p_entity and business_id=p_business and content_type='offer')
    else false end
$$;
revoke all privileges on function app.v95_entity_in_business(uuid,text,uuid) from public, anon, authenticated;

-- 3. publish_loyalty_config -- captures (id,paused,deleted_at) for every affected tier before its
-- delete+reinsert, restores it after. Full body verbatim, only the declare block and the tier
-- block change.
CREATE OR REPLACE FUNCTION public.publish_loyalty_config(p_version uuid)
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'app', 'pg_temp'
AS $function$
declare v_header public.firm_config_versions%rowtype; v_typed public.loyalty_program_versions%rowtype; v_prior uuid;
  v_rule public.program_rules%rowtype; v_rule_errs text[]; v_active_rule_count integer;
  v_tier_carry_ids uuid[]; v_tier_carry_paused boolean[]; v_tier_carry_deleted timestamptz[];
begin
  select * into v_header from public.firm_config_versions where id=p_version for update;
  if not found or not app.c45_owner_loyalty_write(v_header.business_id) then raise exception 'owner loyalty configuration access required' using errcode='42501'; end if;
  if v_header.status<>'draft' then raise exception 'only a draft may be published'; end if;
  perform 1 from public.businesses where id=v_header.business_id for update;
  select * into v_typed from public.loyalty_program_versions where config_version_id=p_version;
  if exists(select 1 from public.business_programmes spine where spine.business_id=v_header.business_id and spine.kind='stamps' and spine.active) and coalesce(v_typed.stamp_per_cents,0)<=0 then raise exception 'active stamps configuration requires spend per stamp' using errcode='23514'; end if;
  if exists(select 1 from public.business_programmes spine where spine.business_id=v_header.business_id and spine.kind='stamps' and spine.active) then
    if coalesce(v_typed.stamp_target,0)<=0 then
      raise exception 'a live stamp card needs a number of stamps' using errcode='23514';
    end if;
    if exists(select 1 from public.loyalty_reward_versions rv join public.business_programmes spine on spine.id=rv.programme_id
               where rv.config_version_id=p_version and rv.business_id=v_header.business_id and rv.active and spine.kind='stamps' and rv.cost_points>v_typed.stamp_target) then
      raise exception 'a stamp gift sits past the last stamp on the card' using errcode='23514';
    end if;
    if not exists(select 1 from public.loyalty_reward_versions rv join public.business_programmes spine on spine.id=rv.programme_id
                   where rv.config_version_id=p_version and rv.business_id=v_header.business_id and rv.active and spine.kind='stamps' and rv.cost_points=v_typed.stamp_target) then
      raise exception 'a live stamp card needs a gift at the last stamp' using errcode='23514';
    end if;
  end if;
  if exists(select 1 from public.retention_program_versions rv left join public.firm_reward_taxonomy t on t.id=rv.reward_taxonomy_id and t.business_id=rv.business_id where rv.config_version_id=p_version and rv.business_id=v_header.business_id and rv.active and coalesce(t.active,false)=false) then
    raise exception 'active retention programs cannot publish a retired taxonomy' using errcode='23514';
  end if;
  if exists(select 1 from public.birthday_program_versions bp where bp.config_version_id=p_version and bp.business_id=v_header.business_id and bp.active and bp.window_days_before+bp.window_days_after+1>365) then
    raise exception 'birthday benefit windows may not overlap annually' using errcode='23514';
  end if;
  for v_rule in select * from public.program_rules where config_version_id=p_version and business_id=v_header.business_id loop
    v_rule_errs := app.program_rule_errors(v_header.business_id, jsonb_build_object(
      'schema_version',v_rule.schema_version,'when_event',v_rule.when_event,'if_conditions',v_rule.if_conditions,
      'then_effects',v_rule.then_effects,'with_params',v_rule.with_params,'during_schedule',v_rule.during_schedule,'using_stacking',v_rule.using_stacking));
    if coalesce(array_length(v_rule_errs,1),0)>0 then
      raise exception 'cannot publish: program rule % is invalid (%)', v_rule.name, array_to_string(v_rule_errs,', ') using errcode='23514';
    end if;
  end loop;
  select count(*) into v_active_rule_count from public.program_rules where config_version_id=p_version and business_id=v_header.business_id and active;
  if v_active_rule_count>200 then
    raise exception 'cannot publish: too many active program rules (%)', v_active_rule_count using errcode='23514';
  end if;
  perform app.refresh_loyalty_config_snapshot(p_version);
  select * into v_header from public.firm_config_versions where id=p_version;
  select active_config_version_id into v_prior from public.businesses where id=v_header.business_id;
  update public.firm_config_versions set status='superseded',superseded_at=now() where id=v_prior and status='published';
  update public.firm_config_versions set status='published',published_at=now() where id=p_version;
  update public.businesses set active_config_version_id=p_version where id=v_header.business_id;
  update public.loyalty_programs set kind=v_typed.kind,loyalty_model=v_typed.loyalty_model,active=v_typed.active,earn_points_per_dollar=v_typed.earn_points_per_dollar,redeem_points=v_typed.redeem_points,reward_credit_cents=v_typed.reward_credit_cents,stamp_target=v_typed.stamp_target,stamp_per_cents=v_typed.stamp_per_cents,tier_basis=v_typed.tier_basis,expiry_mode=v_typed.expiry_mode,expiry_days=v_typed.expiry_days,configuration_status='published',current_config_version_id=p_version where business_id=v_header.business_id;
  update public.loyalty_rewards r set programme_id=rv.programme_id,name=rv.customer_name,internal_name=rv.internal_name,customer_name=rv.customer_name,description=rv.description,fulfillment_kind=rv.fulfillment_kind,taxonomy_label=rv.taxonomy_label,cost_points=rv.cost_points,credit_cents=rv.credit_cents,estimated_cost_cents=rv.estimated_cost_cents,active=rv.active,sort=rv.sort,claim_available_from=rv.claim_available_from,claim_available_until=rv.claim_available_until,entitlement_expiry_days=rv.entitlement_expiry_days,instructions=rv.instructions,terms=rv.terms,image_ref=rv.image_ref,usage_limit=rv.usage_limit,min_tier_id=rv.min_tier_id,min_tier_threshold=rv.min_tier_threshold,current_config_version_id=p_version from public.loyalty_reward_versions rv where rv.reward_id=r.id and rv.business_id=r.business_id and rv.config_version_id=p_version;
  -- V330: loyalty_tiers.paused/deleted_at are an IMMEDIATE-WRITE layer this publish cycle knows
  -- nothing about -- the DELETE below wipes every tier row for the business and the INSERT only
  -- ever knows what THIS draft carried, so without this capture/restore an unrelated publish (of
  -- a draft that predates a v331 pause/delete) would silently revert it. Keyed on id, because the
  -- DELETE+INSERT already reuses tier_id as the new row's id -- the same soft-reference identity
  -- loyalty_rewards.min_tier_id and bar_tier_keep_days_v278.tier_id both already depend on
  -- surviving a publish. A tier snapshot, not a per-draft sync, so it protects against EVERY
  -- future publish, not just the one that happened to be open when it was paused/deleted.
  select array_agg(id), array_agg(paused), array_agg(deleted_at)
    into v_tier_carry_ids, v_tier_carry_paused, v_tier_carry_deleted
    from public.loyalty_tiers
   where business_id=v_header.business_id and (paused or deleted_at is not null);
  delete from public.loyalty_tiers where business_id=v_header.business_id;
  insert into public.loyalty_tiers(id,business_id,name,threshold,points_multiplier,perk_note,sort,effective_from,expires_at) select tier_id,business_id,name,threshold,points_multiplier,perk_note,sort,effective_from,expires_at from public.loyalty_tier_versions where config_version_id=p_version and business_id=v_header.business_id and active;
  if v_tier_carry_ids is not null then
    update public.loyalty_tiers t set paused=c.paused,deleted_at=c.deleted_at
      from (select unnest(v_tier_carry_ids) as id, unnest(v_tier_carry_paused) as paused, unnest(v_tier_carry_deleted) as deleted_at) c
     where c.id=t.id and t.business_id=v_header.business_id;
  end if;
  update public.retention_programs rp set name=rv.name,active=rv.active,goal_visits=rv.goal_visits,period_days=rv.period_days,starts_on=rv.starts_on,reward_taxonomy_id=rv.reward_taxonomy_id,reward_type=rv.fulfillment_kind,reward_value=coalesce(rv.discount_percent,rv.credit_cents,0),reward_item=rv.manual_item,current_config_version_id=p_version from public.retention_program_versions rv where rv.program_id=rp.id and rv.business_id=rp.business_id and rv.config_version_id=p_version and rp.business_id=v_header.business_id;
  perform app.compile_program_rules(p_version);
  insert into public.audit_log(business_id,actor,action,entity,entity_id,detail)
  values(v_header.business_id,auth.uid(),'PUBLISH_CONFIG','firm_config_versions',p_version,jsonb_build_object('prior_version_id',v_prior,'new_version_id',p_version,'snapshot_hash',v_header.snapshot_hash,'birthday_program_count',(select count(*) from public.birthday_program_versions where config_version_id=p_version),'program_rule_count',(select count(*) from public.program_rules where config_version_id=p_version)));
  return json_build_object('version_id',p_version,'version_no',v_header.version_no,'status','published');
end $function$;
revoke all privileges on function public.publish_loyalty_config(uuid) from public, anon, authenticated;
grant execute on function public.publish_loyalty_config(uuid) to authenticated;

-- 2. New immediate-write RPCs, mirroring business_set_reward_paused_v326/business_delete_reward_v326/
-- business_create_reward_v326's exact shapes and authorization (app.c45_owner_loyalty_write).
create or replace function public.business_set_tier_paused_v331(p_business uuid, p_tier uuid, p_paused boolean)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_row public.loyalty_tiers%rowtype;
begin
  if not app.c45_owner_loyalty_write(p_business) then
    raise exception 'owner loyalty configuration access required' using errcode='42501';
  end if;
  if p_paused is null then
    raise exception 'paused flag is required' using errcode='22023';
  end if;
  select * into v_row from public.loyalty_tiers
   where id=p_tier and business_id=p_business and deleted_at is null
   for update;
  if not found then
    raise exception 'tier not found in this business' using errcode='42704';
  end if;
  if v_row.paused is distinct from p_paused then
    update public.loyalty_tiers set paused=p_paused
     where id=p_tier and business_id=p_business;
    insert into public.audit_log(business_id,actor,action,entity,entity_id,detail)
    values(p_business,auth.uid(),case when p_paused then 'tier.paused' else 'tier.unpaused' end,
      'loyalty_tiers',p_tier,jsonb_build_object('name',v_row.name,'threshold',v_row.threshold));
  end if;
  return jsonb_build_object('status','ok','tier_id',p_tier,'paused',p_paused);
end
$$;
revoke all privileges on function public.business_set_tier_paused_v331(uuid,uuid,boolean) from public, anon, authenticated;
grant execute on function public.business_set_tier_paused_v331(uuid,uuid,boolean) to authenticated;

create or replace function public.business_delete_tier_v331(p_business uuid, p_tier uuid)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_row public.loyalty_tiers%rowtype;
  v_remaining integer;
begin
  if not app.c45_owner_loyalty_write(p_business) then
    raise exception 'owner loyalty configuration access required' using errcode='42501';
  end if;
  select * into v_row from public.loyalty_tiers
   where id=p_tier and business_id=p_business and deleted_at is null
   for update;
  if not found then
    raise exception 'tier not found in this business' using errcode='42704';
  end if;

  -- Mirrors the wizard's own existing "keep at least one tier" guard (app/app.js tiersStepHtml)
  -- for a live tier programme, now enforced server-side for the immediate-write path too.
  select count(*) into v_remaining from public.loyalty_tiers
   where business_id=p_business and deleted_at is null and not paused and id<>p_tier;
  if v_remaining=0 and exists(
    select 1 from public.business_programmes spine
     where spine.business_id=p_business and spine.kind='tiers' and spine.active
  ) then
    raise exception 'at least one tier must stay on for a live tier programme' using errcode='23514';
  end if;

  update public.loyalty_tiers set paused=true, deleted_at=now()
   where id=p_tier and business_id=p_business;

  insert into public.audit_log(business_id,actor,action,entity,entity_id,detail)
  values(p_business,auth.uid(),'tier.deleted','loyalty_tiers',p_tier,
    jsonb_build_object('name',v_row.name,'threshold',v_row.threshold));

  return jsonb_build_object('status','ok','tier_id',p_tier,'mode','deleted');
end
$$;
revoke all privileges on function public.business_delete_tier_v331(uuid,uuid) from public, anon, authenticated;
grant execute on function public.business_delete_tier_v331(uuid,uuid) to authenticated;

create or replace function public.business_create_tier_v331(p_business uuid, p_name text, p_threshold integer, p_multiplier numeric default 1)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_tier public.loyalty_tiers%rowtype;
  v_name text := nullif(btrim(coalesce(p_name,'')),'');
  v_published uuid;
  v_open_draft uuid;
  v_sort integer;
begin
  if not app.c45_owner_loyalty_write(p_business) then
    raise exception 'owner loyalty configuration access required' using errcode='42501';
  end if;
  if v_name is null or char_length(v_name)>120 then
    raise exception 'invalid tier name' using errcode='22023';
  end if;
  if p_threshold is null or p_threshold<0 then
    raise exception 'invalid tier threshold' using errcode='22023';
  end if;
  if p_multiplier is null or p_multiplier<1 then
    raise exception 'invalid tier multiplier' using errcode='22023';
  end if;

  select coalesce(max(sort),0)+1 into v_sort from public.loyalty_tiers where business_id=p_business;
  insert into public.loyalty_tiers(business_id,name,threshold,points_multiplier,sort)
  values (p_business,v_name,p_threshold,p_multiplier,v_sort)
  returning * into v_tier;

  -- Appending a NEW tier_id to loyalty_tier_versions is allowed even at an already-published
  -- version (trg_loyalty_tier_versions_immutable only blocks UPDATE/DELETE on it) -- the same
  -- reasoning business_create_reward_v326 used. Without this, create_loyalty_config_draft (which
  -- clones tiers from the last PUBLISHED version's loyalty_tier_versions, not from the live table)
  -- would never pick this tier up, and the very next publish of any OTHER draft would delete it
  -- outright (publish_loyalty_config's tier delete+reinsert only knows what the draft carries).
  select active_config_version_id into v_published from public.businesses where id=p_business;
  if v_published is not null then
    insert into public.loyalty_tier_versions(tier_id,config_version_id,business_id,name,threshold,points_multiplier,sort,active)
    values (v_tier.id,v_published,p_business,v_tier.name,v_tier.threshold,v_tier.points_multiplier,v_tier.sort,true)
    on conflict (tier_id,config_version_id) do nothing;
  end if;

  -- And, if there is also a currently OPEN (unpublished) draft, mirror the same row into it --
  -- an already-open draft was cloned before this tier existed, so it has no row for it either;
  -- publishing THAT specific draft next would otherwise still delete this tier outright, the
  -- same "an already-open draft" resurrection risk v326 closed for gift deletes.
  select id into v_open_draft from public.firm_config_versions
   where business_id=p_business and status='draft' limit 1;
  if v_open_draft is not null and v_open_draft is distinct from v_published then
    insert into public.loyalty_tier_versions(tier_id,config_version_id,business_id,name,threshold,points_multiplier,sort,active)
    values (v_tier.id,v_open_draft,p_business,v_tier.name,v_tier.threshold,v_tier.points_multiplier,v_tier.sort,true)
    on conflict (tier_id,config_version_id) do nothing;
  end if;

  insert into public.audit_log(business_id,actor,action,entity,entity_id,detail)
  values(p_business,auth.uid(),'tier.created','loyalty_tiers',v_tier.id,
    jsonb_build_object('name',v_name,'threshold',p_threshold,'points_multiplier',p_multiplier));

  return jsonb_build_object('status','ok','tier_id',v_tier.id,'name',v_tier.name,'threshold',v_tier.threshold);
end
$$;
revoke all privileges on function public.business_create_tier_v331(uuid,text,integer,numeric) from public, anon, authenticated;
grant execute on function public.business_create_tier_v331(uuid,text,integer,numeric) to authenticated;

commit;
