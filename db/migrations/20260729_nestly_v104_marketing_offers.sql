-- NESTLY v104 — owner-authored customer promotions.
--
-- Reuses the v95 customer-content, localized-copy, and media authority. Owners
-- can draft and publish promotions only through finite RPCs. The launch
-- entitlement is ten first-published offer slots through 31 October 2026
-- (Singapore time). The stored boundary is exclusive so the full final day is
-- included, unless a super admin deliberately changes that entitlement.
--
-- Forward-only review candidate. No production action is authorized by this file.

begin;

create table public.business_promotion_entitlements_v104(
  business_id uuid primary key references public.businesses(id) on delete cascade,
  max_published_offers integer not null
    check(max_published_offers between 0 and 100),
  complimentary_until timestamptz not null,
  version bigint not null default 1 check(version>0),
  updated_by uuid references auth.users(id) on delete set null,
  updated_at timestamptz not null default now()
);

alter table public.business_promotion_entitlements_v104
  enable row level security;
revoke all privileges on table public.business_promotion_entitlements_v104
  from public,anon,authenticated;

create table public.business_promotion_attempt_receipts_v104(
  business_id uuid not null
    references public.businesses(id) on delete cascade,
  attempt_key uuid not null,
  promotion_id uuid not null,
  request_payload jsonb not null
    check(jsonb_typeof(request_payload)='object'),
  response_payload jsonb not null
    check(jsonb_typeof(response_payload)='object'),
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  primary key(business_id,attempt_key)
);
alter table public.business_promotion_attempt_receipts_v104
  enable row level security;
revoke all privileges on table public.business_promotion_attempt_receipts_v104
  from public,anon,authenticated;

create or replace function app.v104_lock_promotion_business(
  p_business uuid
)
returns void
language sql
volatile
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
  select pg_advisory_xact_lock(
    hashtextextended('nestly.v104.promotion:'||p_business::text,0)
  )
$$;
revoke all on function app.v104_lock_promotion_business(uuid)
  from public,anon,authenticated;

create or replace function app.v104_effective_promotion_entitlement(
  p_business uuid
)
returns table(
  max_published_offers integer,
  complimentary_until timestamptz,
  version bigint
)
language sql
stable
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
  select
    coalesce(entitlement.max_published_offers,10),
    coalesce(
      entitlement.complimentary_until,
      timestamptz '2026-11-01 00:00:00+08'
    ),
    coalesce(entitlement.version,0)
  from (select 1) seed
  left join public.business_promotion_entitlements_v104 entitlement
    on entitlement.business_id=p_business
$$;
revoke all on function app.v104_effective_promotion_entitlement(uuid)
  from public,anon,authenticated;

-- v95 exposed a generic owner content writer for benefits and offers. Keep
-- benefits compatible, but prevent that legacy offer path from bypassing the
-- v104 image, quota, date and launch-window authority.
create or replace function app.v104_promotion_write_guard()
returns trigger
language plpgsql
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare
  v_touches_offer boolean;
begin
  if tg_op='DELETE' then
    v_touches_offer:=old.content_type='offer';
  else
    v_touches_offer:=new.content_type='offer'
      or (tg_op='UPDATE' and old.content_type='offer');
  end if;
  if v_touches_offer
     and coalesce(
       current_setting('app.v104_promotion_write',true),''
     )<>'on'
  then
    raise exception 'promotion_v104_rpc_required' using errcode='42501';
  end if;
  if tg_op='DELETE' then return old;end if;
  return new;
end
$$;
revoke all on function app.v104_promotion_write_guard()
  from public,anon,authenticated;
create trigger business_customer_content_v104_promotion_write_guard
before insert or update or delete on public.business_customer_content_v95
for each row execute function app.v104_promotion_write_guard();

create or replace function app.v104_promotion_media_write_guard()
returns trigger
language plpgsql
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare
  v_touches_offer boolean;
begin
  if tg_op='DELETE' then
    v_touches_offer:=old.asset_kind='offer';
  else
    v_touches_offer:=new.asset_kind='offer'
      or (tg_op='UPDATE' and old.asset_kind='offer');
  end if;
  if v_touches_offer
     and coalesce(
       current_setting('app.v104_promotion_media_write',true),''
     )<>'on'
  then
    raise exception 'promotion_media_v104_rpc_required'
      using errcode='42501';
  end if;
  if tg_op='DELETE' then return old;end if;
  return new;
end
$$;
revoke all on function app.v104_promotion_media_write_guard()
  from public,anon,authenticated;
create trigger business_media_assets_v104_promotion_write_guard
before insert or update or delete on public.business_media_assets_v95
for each row execute function app.v104_promotion_media_write_guard();

create or replace function app.v104_promotion_copy_write_guard()
returns trigger
language plpgsql
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare
  v_touches_offer boolean;
begin
  if tg_op='DELETE' then
    v_touches_offer:=old.entity_type='offer';
  else
    v_touches_offer:=new.entity_type='offer'
      or (tg_op='UPDATE' and old.entity_type='offer');
  end if;
  if v_touches_offer
     and coalesce(
       current_setting('app.v104_promotion_copy_write',true),''
     )<>'on'
  then
    raise exception 'promotion_copy_v104_rpc_required'
      using errcode='42501';
  end if;
  if tg_op='DELETE' then return old;end if;
  return new;
end
$$;
revoke all on function app.v104_promotion_copy_write_guard()
  from public,anon,authenticated;
create trigger business_localized_copy_v104_promotion_write_guard
before insert or update or delete on public.business_localized_copy_v95
for each row execute function app.v104_promotion_copy_write_guard();

create or replace function public.platform_set_promotion_entitlement_v104(
  p_business uuid,
  p_max_published_offers integer,
  p_complimentary_until timestamptz,
  p_expected_version bigint
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare
  v_row public.business_promotion_entitlements_v104%rowtype;
begin
  if auth.uid() is null or not app.is_super_admin() then
    raise exception 'super_admin_required' using errcode='42501';
  end if;
  if p_business is null
     or p_max_published_offers is null
     or p_max_published_offers not between 0 and 100
     or p_complimentary_until is null
     or p_expected_version is null
     or not exists(
       select 1 from public.businesses business where business.id=p_business
     )
  then
    raise exception 'valid_promotion_entitlement_required'
      using errcode='22023';
  end if;

  perform app.v104_lock_promotion_business(p_business);

  select * into v_row
  from public.business_promotion_entitlements_v104 entitlement
  where entitlement.business_id=p_business
  for update;

  if found then
    if v_row.version<>p_expected_version then
      raise exception 'promotion_entitlement_version_conflict'
        using errcode='40001';
    end if;
    update public.business_promotion_entitlements_v104
    set max_published_offers=p_max_published_offers,
        complimentary_until=p_complimentary_until,
        version=version+1,
        updated_by=auth.uid(),
        updated_at=now()
    where business_id=p_business
    returning * into v_row;
  else
    if p_expected_version<>0 then
      raise exception 'promotion_entitlement_version_conflict'
        using errcode='40001';
    end if;
    insert into public.business_promotion_entitlements_v104(
      business_id,max_published_offers,complimentary_until,updated_by
    ) values(
      p_business,p_max_published_offers,p_complimentary_until,auth.uid()
    )
    returning * into v_row;
  end if;

  return jsonb_build_object(
    'business_id',v_row.business_id,
    'max_published_offers',v_row.max_published_offers,
    'complimentary_until',v_row.complimentary_until,
    'version',v_row.version
  );
end
$$;

create or replace function public.business_save_promotion_v104(
  p_business uuid,
  p_promotion_id uuid,
  p_branch uuid,
  p_name text,
  p_tagline text,
  p_description text,
  p_terms text,
  p_starts_at timestamptz,
  p_ends_at timestamptz,
  p_display_order integer,
  p_cta_kind text,
  p_cta_label text,
  p_offer_facts text,
  p_occasion text,
  p_publish boolean,
  p_expected_content_version bigint,
  p_expected_copy_version bigint
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare
  v_actor uuid:=auth.uid();
  v_content public.business_customer_content_v95%rowtype;
  v_copy public.business_localized_copy_v95%rowtype;
  v_is_new boolean:=p_promotion_id is null;
  v_entitlement record;
  v_media_id uuid;
  v_media_version bigint;
  v_media_url text;
  v_media_alt text;
  v_published_count integer:=0;
  v_quota_used integer:=0;
  v_metadata jsonb;
begin
  if v_actor is null then
    raise exception 'authenticated_session_required' using errcode='28000';
  end if;
  if not app.is_salon_owner(p_business) then
    raise exception 'owner_required' using errcode='42501';
  end if;
  if p_business is null
     or p_publish is null
     or p_expected_content_version is null
     or p_expected_copy_version is null
     or p_display_order is null
     or p_display_order not between 0 and 10000
     or p_cta_kind is null
     or p_cta_kind not in ('book','programme','counter')
     or length(btrim(coalesce(p_cta_label,''))) not between 2 and 40
     or length(btrim(coalesce(p_name,''))) not between 2 and 70
     or (
       nullif(btrim(coalesce(p_tagline,'')),'') is not null
       and length(btrim(p_tagline)) not between 2 and 120
     )
     or length(btrim(coalesce(p_description,''))) not between 10 and 600
     or (
       nullif(btrim(coalesce(p_terms,'')),'') is not null
       and length(btrim(p_terms))>1000
     )
     or length(btrim(coalesce(p_offer_facts,''))) not between 2 and 500
     or (
       nullif(btrim(coalesce(p_occasion,'')),'') is not null
       and length(btrim(p_occasion)) not between 2 and 80
     )
     or p_ends_at is null
     or (p_starts_at is not null and p_ends_at<=p_starts_at)
     or (
       p_branch is not null
       and not exists(
         select 1 from public.branches branch
         where branch.id=p_branch
           and branch.business_id=p_business
           and branch.active
       )
     )
     or not exists(
       select 1 from public.businesses business where business.id=p_business
     )
  then
    raise exception 'valid_promotion_fields_required' using errcode='22023';
  end if;

  perform app.v104_lock_promotion_business(p_business);
  -- Retained only as an explicit compatibility failure for cached clients.
  -- Every mutable save now requires a stable attempt key and therefore goes
  -- through business_finalize_promotion_v104, even when the result is a draft
  -- or an unpublish.
  raise exception 'promotion_finalize_rpc_required' using errcode='42501';

  if p_promotion_id is null then
    raise exception 'promotion_create_draft_rpc_required' using errcode='42501';
  end if;
  if p_publish then
    raise exception 'promotion_finalize_rpc_required' using errcode='42501';
  end if;

  select * into v_entitlement
  from app.v104_effective_promotion_entitlement(p_business);

  if v_is_new then
    if p_expected_content_version<>0 or p_expected_copy_version<>0 then
      raise exception 'promotion_version_conflict' using errcode='40001';
    end if;
    if now()>=v_entitlement.complimentary_until then
      raise exception 'promotion_creation_window_closed' using errcode='42501';
    end if;
  else
    select * into v_content
    from public.business_customer_content_v95 content
    where content.id=p_promotion_id
      and content.business_id=p_business
      and content.content_type='offer'
    for update;
    if not found then
      raise exception 'promotion_not_found' using errcode='22023';
    end if;
    if v_content.version<>p_expected_content_version then
      raise exception 'promotion_version_conflict' using errcode='40001';
    end if;
    select * into v_copy
    from public.business_localized_copy_v95 copy
    where copy.business_id=p_business
      and copy.entity_type='offer'
      and copy.entity_id=p_promotion_id
      and copy.locale='en'
    for update;
    if found then
      if v_copy.version<>p_expected_copy_version then
        raise exception 'promotion_copy_version_conflict' using errcode='40001';
      end if;
    elsif p_expected_copy_version<>0 then
      raise exception 'promotion_copy_version_conflict' using errcode='40001';
    end if;
  end if;

  v_metadata:=jsonb_strip_nulls(jsonb_build_object(
    'schema','nestly.promotion.v104',
    'cta',jsonb_build_object(
      'kind',p_cta_kind,
      'label',btrim(p_cta_label)
    ),
    'offer_facts',btrim(p_offer_facts),
    'occasion',nullif(btrim(coalesce(p_occasion,'')),''),
    'published_once_at',v_content.metadata->'published_once_at'
  ));
  perform set_config('app.v104_promotion_write','on',true);
  perform set_config('app.v104_promotion_copy_write','on',true);

  if v_is_new then
    insert into public.business_customer_content_v95(
      business_id,content_type,branch_id,active,display_order,
      starts_at,ends_at,metadata,updated_by
    ) values(
      p_business,'offer',p_branch,false,p_display_order,
      p_starts_at,p_ends_at,v_metadata,v_actor
    )
    returning * into v_content;
    insert into public.business_localized_copy_v95(
      business_id,entity_type,entity_id,locale,name,tagline,description,
      terms,updated_by
    ) values(
      p_business,'offer',v_content.id,'en',btrim(p_name),
      nullif(btrim(coalesce(p_tagline,'')),''),
      btrim(p_description),nullif(btrim(coalesce(p_terms,'')),''),
      v_actor
    )
    returning * into v_copy;
  else
    update public.business_customer_content_v95
    set branch_id=p_branch,
        active=p_publish,
        display_order=p_display_order,
        starts_at=p_starts_at,
        ends_at=p_ends_at,
        metadata=v_metadata,
        version=version+1,
        updated_by=v_actor,
        updated_at=now()
    where id=p_promotion_id
    returning * into v_content;

    if v_copy.business_id is null then
      insert into public.business_localized_copy_v95(
        business_id,entity_type,entity_id,locale,name,tagline,description,
        terms,updated_by
      ) values(
        p_business,'offer',v_content.id,'en',btrim(p_name),
        nullif(btrim(coalesce(p_tagline,'')),''),
        btrim(p_description),nullif(btrim(coalesce(p_terms,'')),''),
        v_actor
      )
      returning * into v_copy;
    else
      update public.business_localized_copy_v95
      set name=btrim(p_name),
          tagline=nullif(btrim(coalesce(p_tagline,'')),''),
          description=btrim(p_description),
          terms=nullif(btrim(coalesce(p_terms,'')),''),
          version=version+1,
          updated_by=v_actor,
          updated_at=now()
      where business_id=p_business
        and entity_type='offer'
        and entity_id=v_content.id
        and locale='en'
      returning * into v_copy;
    end if;
  end if;
  perform set_config('app.v104_promotion_write','',true);
  perform set_config('app.v104_promotion_copy_write','',true);

  select asset.id,asset.version,
    app.v95_public_media_url(asset.object_path) url,asset.alt_en
  into v_media_id,v_media_version,v_media_url,v_media_alt
  from public.business_media_assets_v95 asset
  where asset.business_id=p_business
    and asset.asset_kind='offer'
    and asset.entity_id=v_content.id
    and asset.customer_visible
    and (
      asset.branch_id is not distinct from v_content.branch_id
      or (v_content.branch_id is not null and asset.branch_id is null)
    )
  order by (asset.branch_id is not distinct from v_content.branch_id) desc,
    asset.updated_at desc,asset.id
  limit 1;

  select count(*)::integer into v_quota_used
  from public.business_customer_content_v95 content
  where content.business_id=p_business
    and content.content_type='offer'
    and content.metadata->>'schema'='nestly.promotion.v104'
    and content.metadata ? 'published_once_at';
  select count(*)::integer into v_published_count
  from public.business_customer_content_v95 content
  where content.business_id=p_business
    and content.content_type='offer'
    and content.active
    and (content.ends_at is null or content.ends_at>now());

  return jsonb_build_object(
    'id',v_content.id,
    'promotion_id',v_content.id,
    'business_id',v_content.business_id,
    'branch_id',v_content.branch_id,
    'status',case when v_content.active then 'published' else 'draft' end,
    'publish_state',case when v_content.active then 'published' else 'draft' end,
    'active',v_content.active,
    'display_order',v_content.display_order,
    'starts_at',v_content.starts_at,
    'ends_at',v_content.ends_at,
    'metadata',v_content.metadata,
    'content_version',v_content.version,
    'copy_version',v_copy.version,
    'name',v_copy.name,
    'tagline',v_copy.tagline,
    'description',v_copy.description,
    'terms',v_copy.terms,
    'image_url',v_media_url,
    'image_alt',v_media_alt,
    'media_asset_id',v_media_id,
    'media_version',coalesce(v_media_version,0),
    'quota_used',v_quota_used,
    'quota_limit',v_entitlement.max_published_offers,
    'published_count',v_published_count,
    'item',jsonb_build_object(
      'id',v_content.id,
      'branch_id',v_content.branch_id,
      'active',v_content.active,
      'publish_state',case
        when v_content.active then 'published' else 'draft' end,
      'starts_at',v_content.starts_at,
      'ends_at',v_content.ends_at,
      'display_order',v_content.display_order,
      'content_version',v_content.version,
      'copy_version',v_copy.version,
      'name',v_copy.name,
      'tagline',v_copy.tagline,
      'description',v_copy.description,
      'terms',v_copy.terms,
      'metadata',v_content.metadata,
      'image_url',v_media_url,
      'image_alt',v_media_alt,
      'media_asset_id',v_media_id,
      'media_version',coalesce(v_media_version,0)
    )
  );
end
$$;

create or replace function public.business_create_promotion_draft_v104(
  p_business uuid,
  p_promotion_id uuid,
  p_attempt_key uuid,
  p_branch uuid,
  p_name text,
  p_tagline text,
  p_description text,
  p_terms text,
  p_starts_at timestamptz,
  p_ends_at timestamptz,
  p_display_order integer,
  p_cta_kind text,
  p_cta_label text,
  p_offer_facts text,
  p_occasion text
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare
  v_actor uuid:=auth.uid();
  v_content public.business_customer_content_v95%rowtype;
  v_copy public.business_localized_copy_v95%rowtype;
  v_receipt public.business_promotion_attempt_receipts_v104%rowtype;
  v_entitlement record;
  v_request jsonb;
  v_response jsonb;
  v_quota_used integer:=0;
begin
  if v_actor is null then
    raise exception 'authenticated_session_required' using errcode='28000';
  end if;
  if p_business is null or p_promotion_id is null or p_attempt_key is null then
    raise exception 'valid_promotion_attempt_identity_required'
      using errcode='22023';
  end if;

  perform app.v104_lock_promotion_business(p_business);
  v_request:=jsonb_build_object(
    'action','create_draft',
    'promotion_id',p_promotion_id,
    'branch_id',p_branch,
    'name',p_name,
    'tagline',p_tagline,
    'description',p_description,
    'terms',p_terms,
    'starts_at',p_starts_at,
    'ends_at',p_ends_at,
    'display_order',p_display_order,
    'cta_kind',p_cta_kind,
    'cta_label',p_cta_label,
    'offer_facts',p_offer_facts,
    'occasion',p_occasion
  );
  select * into v_receipt
  from public.business_promotion_attempt_receipts_v104 receipt
  where receipt.business_id=p_business
    and receipt.attempt_key=p_attempt_key
  for update;
  if found then
    if v_receipt.created_by is distinct from v_actor
       and not app.is_salon_owner(p_business)
       and not app.is_super_admin()
    then
      raise exception 'promotion_receipt_replay_forbidden'
        using errcode='42501';
    end if;
    if v_receipt.request_payload<>v_request then
      raise exception 'promotion_attempt_key_reused'
        using errcode='23505';
    end if;
    return v_receipt.response_payload||jsonb_build_object(
      'attempt_key',p_attempt_key,
      'replayed',true
    );
  end if;

  if not app.is_salon_owner(p_business) then
    raise exception 'owner_required' using errcode='42501';
  end if;
  if p_branch is not null
     or p_display_order is null
     or p_display_order not between 0 and 10000
     or p_cta_kind is null
     or p_cta_kind not in ('book','programme','counter')
     or length(btrim(coalesce(p_cta_label,''))) not between 2 and 40
     or length(btrim(coalesce(p_name,''))) not between 2 and 70
     or (
       nullif(btrim(coalesce(p_tagline,'')),'') is not null
       and length(btrim(p_tagline)) not between 2 and 120
     )
     or length(btrim(coalesce(p_description,''))) not between 10 and 600
     or (
       nullif(btrim(coalesce(p_terms,'')),'') is not null
       and length(btrim(p_terms))>1000
     )
     or length(btrim(coalesce(p_offer_facts,''))) not between 2 and 500
     or (
       nullif(btrim(coalesce(p_occasion,'')),'') is not null
       and length(btrim(p_occasion)) not between 2 and 80
     )
     or p_ends_at is null
     or (p_starts_at is not null and p_ends_at<=p_starts_at)
     or not exists(
       select 1 from public.businesses business where business.id=p_business
     )
  then
    raise exception 'valid_promotion_draft_fields_required'
      using errcode='22023';
  end if;

  select * into v_entitlement
  from app.v104_effective_promotion_entitlement(p_business);
  if exists(
    select 1 from public.business_customer_content_v95 content
    where content.id=p_promotion_id
  ) then
    raise exception 'promotion_id_already_exists' using errcode='23505';
  end if;

  perform set_config('app.v104_promotion_write','on',true);
  insert into public.business_customer_content_v95(
    id,business_id,content_type,branch_id,active,display_order,
    starts_at,ends_at,metadata,updated_by
  ) values(
    p_promotion_id,p_business,'offer',p_branch,false,p_display_order,
    p_starts_at,p_ends_at,
    jsonb_strip_nulls(jsonb_build_object(
      'schema','nestly.promotion.v104',
      'cta',jsonb_build_object(
        'kind',p_cta_kind,
        'label',btrim(p_cta_label)
      ),
      'offer_facts',btrim(p_offer_facts),
      'occasion',nullif(btrim(coalesce(p_occasion,'')),'')
    )),
    v_actor
  )
  returning * into v_content;
  perform set_config('app.v104_promotion_write','',true);

  perform set_config('app.v104_promotion_copy_write','on',true);
  insert into public.business_localized_copy_v95(
    business_id,entity_type,entity_id,locale,name,tagline,description,
    terms,updated_by
  ) values(
    p_business,'offer',p_promotion_id,'en',btrim(p_name),
    nullif(btrim(coalesce(p_tagline,'')),''),
    btrim(p_description),nullif(btrim(coalesce(p_terms,'')),''),
    v_actor
  )
  returning * into v_copy;
  perform set_config('app.v104_promotion_copy_write','',true);

  select count(*)::integer into v_quota_used
  from public.business_customer_content_v95 content
  where content.business_id=p_business
    and content.content_type='offer'
    and content.metadata->>'schema'='nestly.promotion.v104'
    and content.metadata ? 'published_once_at';
  v_response:=jsonb_build_object(
    'id',v_content.id,
    'promotion_id',v_content.id,
    'business_id',v_content.business_id,
    'branch_id',v_content.branch_id,
    'status','draft',
    'publish_state','draft',
    'active',false,
    'display_order',v_content.display_order,
    'starts_at',v_content.starts_at,
    'ends_at',v_content.ends_at,
    'metadata',v_content.metadata,
    'content_version',v_content.version,
    'copy_version',v_copy.version,
    'name',v_copy.name,
    'tagline',v_copy.tagline,
    'description',v_copy.description,
    'terms',v_copy.terms,
    'media_version',0,
    'target_media_version',0,
    'quota_used',v_quota_used,
    'quota_limit',v_entitlement.max_published_offers,
    'item',jsonb_build_object(
      'id',v_content.id,
      'branch_id',v_content.branch_id,
      'active',false,
      'publish_state','draft',
      'starts_at',v_content.starts_at,
      'ends_at',v_content.ends_at,
      'display_order',v_content.display_order,
      'content_version',v_content.version,
      'copy_version',v_copy.version,
      'name',v_copy.name,
      'tagline',v_copy.tagline,
      'description',v_copy.description,
      'terms',v_copy.terms,
      'metadata',v_content.metadata,
      'media_version',0,
      'target_media_version',0
    )
  );
  insert into public.business_promotion_attempt_receipts_v104(
    business_id,attempt_key,promotion_id,request_payload,response_payload,
    created_by
  ) values(
    p_business,p_attempt_key,p_promotion_id,v_request,v_response,v_actor
  );
  return v_response||jsonb_build_object(
    'attempt_key',p_attempt_key,
    'replayed',false
  );
end
$$;

create or replace function public.business_finalize_promotion_v104(
  p_business uuid,
  p_promotion_id uuid,
  p_branch uuid,
  p_name text,
  p_tagline text,
  p_description text,
  p_terms text,
  p_starts_at timestamptz,
  p_ends_at timestamptz,
  p_display_order integer,
  p_cta_kind text,
  p_cta_label text,
  p_offer_facts text,
  p_occasion text,
  p_publish boolean,
  p_object_path text,
  p_mime_type text,
  p_width_px integer,
  p_height_px integer,
  p_alt_en text,
  p_expected_content_version bigint,
  p_expected_copy_version bigint,
  p_expected_target_media_version bigint,
  p_attempt_key uuid
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare
  v_actor uuid:=auth.uid();
  v_content public.business_customer_content_v95%rowtype;
  v_copy public.business_localized_copy_v95%rowtype;
  v_target_media public.business_media_assets_v95%rowtype;
  v_applicable_media public.business_media_assets_v95%rowtype;
  v_receipt public.business_promotion_attempt_receipts_v104%rowtype;
  v_entitlement record;
  v_request jsonb;
  v_response jsonb;
  v_metadata jsonb;
  v_previous_object_path text;
  v_media_url text;
  v_media_alt text;
  v_quota_used integer:=0;
  v_published_count integer:=0;
  v_first_adoption boolean;
begin
  if v_actor is null then
    raise exception 'authenticated_session_required' using errcode='28000';
  end if;
  if p_business is null or p_promotion_id is null or p_attempt_key is null then
    raise exception 'valid_promotion_attempt_identity_required'
      using errcode='22023';
  end if;

  perform app.v104_lock_promotion_business(p_business);
  v_request:=jsonb_build_object(
    'promotion_id',p_promotion_id,
    'branch_id',p_branch,
    'name',p_name,
    'tagline',p_tagline,
    'description',p_description,
    'terms',p_terms,
    'starts_at',p_starts_at,
    'ends_at',p_ends_at,
    'display_order',p_display_order,
    'cta_kind',p_cta_kind,
    'cta_label',p_cta_label,
    'offer_facts',p_offer_facts,
    'occasion',p_occasion,
    'publish',p_publish,
    'object_path',p_object_path,
    'mime_type',p_mime_type,
    'width_px',p_width_px,
    'height_px',p_height_px,
    'alt_en',p_alt_en,
    'expected_content_version',p_expected_content_version,
    'expected_copy_version',p_expected_copy_version,
    'expected_target_media_version',p_expected_target_media_version
  );
  select * into v_receipt
  from public.business_promotion_attempt_receipts_v104 receipt
  where receipt.business_id=p_business
    and receipt.attempt_key=p_attempt_key
  for update;
  if found then
    if v_receipt.created_by is distinct from v_actor
       and not app.is_salon_owner(p_business)
       and not app.is_super_admin()
    then
      raise exception 'promotion_receipt_replay_forbidden'
        using errcode='42501';
    end if;
    if v_receipt.request_payload<>v_request then
      raise exception 'promotion_attempt_key_reused'
        using errcode='23505';
    end if;
    return v_receipt.response_payload||jsonb_build_object(
      'attempt_key',p_attempt_key,
      'replayed',true
    );
  end if;

  if not app.is_salon_owner(p_business) then
    raise exception 'owner_required' using errcode='42501';
  end if;
  if p_branch is not null
     or p_publish is null
     or p_expected_content_version is null
     or p_expected_copy_version is null
     or p_expected_target_media_version is null
     or p_display_order is null
     or p_display_order not between 0 and 10000
     or p_cta_kind is null
     or p_cta_kind not in ('book','programme','counter')
     or length(btrim(coalesce(p_cta_label,''))) not between 2 and 40
     or length(btrim(coalesce(p_name,''))) not between 2 and 70
     or (
       nullif(btrim(coalesce(p_tagline,'')),'') is not null
       and length(btrim(p_tagline)) not between 2 and 120
     )
     or length(btrim(coalesce(p_description,''))) not between 10 and 600
     or (
       nullif(btrim(coalesce(p_terms,'')),'') is not null
       and length(btrim(p_terms))>1000
     )
     or length(btrim(coalesce(p_offer_facts,''))) not between 2 and 500
     or (
       nullif(btrim(coalesce(p_occasion,'')),'') is not null
       and length(btrim(p_occasion)) not between 2 and 80
     )
     or p_ends_at is null
     or (p_publish and p_ends_at<=now())
     or (p_starts_at is not null and p_ends_at<=p_starts_at)
     or not exists(
       select 1 from public.businesses business where business.id=p_business
     )
     or (
       p_object_path is null
       and (
         p_mime_type is not null
         or p_width_px is not null
         or p_height_px is not null
         or p_alt_en is not null
       )
     )
     or (
       p_object_path is not null
       and (
         p_mime_type is null
         or length(btrim(coalesce(p_alt_en,''))) not between 1 and 240
       )
     )
  then
    raise exception 'valid_promotion_finalize_fields_required'
      using errcode='22023';
  end if;

  if p_object_path is not null
     and not app.v95_storage_object_is_publishable(
       p_business,'offer',p_object_path,p_mime_type
     )
  then
    raise exception 'verified_storage_object_required' using errcode='22023';
  end if;

  select * into v_content
  from public.business_customer_content_v95 content
  where content.id=p_promotion_id
    and content.business_id=p_business
    and content.content_type='offer'
  for update;
  if not found then
    raise exception 'promotion_not_found' using errcode='22023';
  end if;
  if v_content.version<>p_expected_content_version then
    raise exception 'promotion_version_conflict' using errcode='40001';
  end if;

  select * into v_copy
  from public.business_localized_copy_v95 copy
  where copy.business_id=p_business
    and copy.entity_type='offer'
    and copy.entity_id=p_promotion_id
    and copy.locale='en'
  for update;
  if not found or v_copy.version<>p_expected_copy_version then
    raise exception 'promotion_copy_version_conflict' using errcode='40001';
  end if;

  select * into v_entitlement
  from app.v104_effective_promotion_entitlement(p_business);
  v_first_adoption:=p_publish
    and not(v_content.metadata ? 'published_once_at');
  if v_first_adoption then
    if now()>=v_entitlement.complimentary_until then
      raise exception 'promotion_publishing_window_closed' using errcode='42501';
    end if;
    select count(*)::integer into v_quota_used
    from public.business_customer_content_v95 content
    where content.business_id=p_business
      and content.content_type='offer'
      and content.metadata->>'schema'='nestly.promotion.v104'
      and content.metadata ? 'published_once_at';
    if v_quota_used>=v_entitlement.max_published_offers then
      raise exception 'promotion_publish_limit_reached' using errcode='23514';
    end if;
  end if;

  select * into v_target_media
  from public.business_media_assets_v95 asset
  where asset.business_id=p_business
    and asset.asset_kind='offer'
    and asset.entity_id=p_promotion_id
    and asset.branch_id is not distinct from p_branch
  for update;

  if found then
    if v_target_media.version<>p_expected_target_media_version then
      raise exception 'promotion_target_media_version_conflict'
        using errcode='40001';
    end if;
    v_previous_object_path:=v_target_media.object_path;
  elsif p_expected_target_media_version<>0 then
    raise exception 'promotion_target_media_version_conflict'
      using errcode='40001';
  end if;

  if p_object_path is not null then
    perform set_config('app.v104_promotion_media_write','on',true);
    perform public.business_upsert_media_asset_v95(
      p_business,'offer',p_promotion_id,p_branch,p_object_path,p_mime_type,
      p_width_px,p_height_px,btrim(p_alt_en),null,false,
      coalesce(v_target_media.version,0)
    );
    update public.business_media_assets_v95 asset
    set customer_visible=p_publish
    where asset.business_id=p_business
      and asset.asset_kind='offer'
      and asset.entity_id=p_promotion_id
      and asset.branch_id is not distinct from p_branch
    returning * into v_applicable_media;
    perform set_config('app.v104_promotion_media_write','',true);
  else
    select * into v_applicable_media
    from public.business_media_assets_v95 asset
    where asset.business_id=p_business
      and asset.asset_kind='offer'
      and asset.entity_id=p_promotion_id
      and (
        asset.branch_id is not distinct from p_branch
        or (p_branch is not null and asset.branch_id is null)
      )
    order by (asset.branch_id is not distinct from p_branch) desc,
      asset.updated_at desc,asset.id
    limit 1
    for update;
    if not found and p_publish then
      raise exception 'promotion_image_required' using errcode='23514';
    end if;
    if found and p_publish and not v_applicable_media.customer_visible then
      perform set_config('app.v104_promotion_media_write','on',true);
      update public.business_media_assets_v95
      set customer_visible=true,
          version=version+1,
          updated_by=v_actor,
          updated_at=now()
      where id=v_applicable_media.id
      returning * into v_applicable_media;
      perform set_config('app.v104_promotion_media_write','',true);
    end if;
  end if;

  v_metadata:=jsonb_strip_nulls(jsonb_build_object(
    'schema','nestly.promotion.v104',
    'cta',jsonb_build_object(
      'kind',p_cta_kind,
      'label',btrim(p_cta_label)
    ),
    'offer_facts',btrim(p_offer_facts),
    'occasion',nullif(btrim(coalesce(p_occasion,'')),''),
    'published_once_at',case when p_publish then coalesce(
      v_content.metadata->'published_once_at',to_jsonb(now())
    ) else v_content.metadata->'published_once_at' end
  ));

  perform set_config('app.v104_promotion_write','on',true);
  update public.business_customer_content_v95
  set branch_id=p_branch,
      active=p_publish,
      display_order=p_display_order,
      starts_at=p_starts_at,
      ends_at=p_ends_at,
      metadata=v_metadata,
      version=version+1,
      updated_by=v_actor,
      updated_at=now()
  where id=p_promotion_id
  returning * into v_content;
  perform set_config('app.v104_promotion_write','',true);

  perform set_config('app.v104_promotion_copy_write','on',true);
  update public.business_localized_copy_v95
  set name=btrim(p_name),
      tagline=nullif(btrim(coalesce(p_tagline,'')),''),
      description=btrim(p_description),
      terms=nullif(btrim(coalesce(p_terms,'')),''),
      version=version+1,
      updated_by=v_actor,
      updated_at=now()
  where business_id=p_business
    and entity_type='offer'
    and entity_id=p_promotion_id
    and locale='en'
  returning * into v_copy;
  perform set_config('app.v104_promotion_copy_write','',true);

  select count(*)::integer into v_quota_used
  from public.business_customer_content_v95 content
  where content.business_id=p_business
    and content.content_type='offer'
    and content.metadata->>'schema'='nestly.promotion.v104'
    and content.metadata ? 'published_once_at';
  select count(*)::integer into v_published_count
  from public.business_customer_content_v95 content
  where content.business_id=p_business
    and content.content_type='offer'
    and content.active
    and content.ends_at>now();

  v_media_url:=app.v95_public_media_url(v_applicable_media.object_path);
  v_media_alt:=v_applicable_media.alt_en;
  v_response:=jsonb_build_object(
    'id',v_content.id,
    'promotion_id',v_content.id,
    'business_id',v_content.business_id,
    'branch_id',v_content.branch_id,
    'status',case when p_publish then 'published' else 'draft' end,
    'publish_state',case when p_publish then 'published' else 'draft' end,
    'active',p_publish,
    'display_order',v_content.display_order,
    'starts_at',v_content.starts_at,
    'ends_at',v_content.ends_at,
    'metadata',v_content.metadata,
    'content_version',v_content.version,
    'copy_version',v_copy.version,
    'name',v_copy.name,
    'tagline',v_copy.tagline,
    'description',v_copy.description,
    'terms',v_copy.terms,
    'image_url',v_media_url,
    'image_alt',v_media_alt,
    'media_asset_id',v_applicable_media.id,
    'media_version',v_applicable_media.version,
    'target_media_version',v_applicable_media.version,
    'quota_used',v_quota_used,
    'quota_limit',v_entitlement.max_published_offers,
    'published_count',v_published_count,
    'previous_object_path',case
      when v_previous_object_path is distinct from v_applicable_media.object_path
      then v_previous_object_path else null end,
    'item',jsonb_build_object(
      'id',v_content.id,
      'branch_id',v_content.branch_id,
      'active',p_publish,
      'publish_state',case when p_publish then 'published' else 'draft' end,
      'starts_at',v_content.starts_at,
      'ends_at',v_content.ends_at,
      'display_order',v_content.display_order,
      'content_version',v_content.version,
      'copy_version',v_copy.version,
      'name',v_copy.name,
      'tagline',v_copy.tagline,
      'description',v_copy.description,
      'terms',v_copy.terms,
      'metadata',v_content.metadata,
      'image_url',v_media_url,
      'image_alt',v_media_alt,
      'media_asset_id',v_applicable_media.id,
      'media_version',v_applicable_media.version,
      'target_media_version',v_applicable_media.version
    )
  );

  insert into public.business_promotion_attempt_receipts_v104(
    business_id,attempt_key,promotion_id,request_payload,response_payload,
    created_by
  ) values(
    p_business,p_attempt_key,p_promotion_id,v_request,v_response,v_actor
  );

  return v_response||jsonb_build_object(
    'attempt_key',p_attempt_key,
    'replayed',false
  );
end
$$;

create or replace function public.business_get_promotion_editor_v104(
  p_business uuid
)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare
  v_entitlement record;
  v_published_count integer;
  v_quota_used integer;
  v_items jsonb;
begin
  if auth.uid() is null then
    raise exception 'authenticated_session_required' using errcode='28000';
  end if;
  if not app.is_salon_owner(p_business) and not app.is_super_admin() then
    raise exception 'owner_required' using errcode='42501';
  end if;
  if p_business is null or not exists(
    select 1 from public.businesses business where business.id=p_business
  ) then
    raise exception 'business_not_found' using errcode='22023';
  end if;

  select * into v_entitlement
  from app.v104_effective_promotion_entitlement(p_business);
  select count(*)::integer into v_published_count
  from public.business_customer_content_v95 content
  where content.business_id=p_business
    and content.content_type='offer'
    and content.active
    and (content.ends_at is null or content.ends_at>now());
  select count(*)::integer into v_quota_used
  from public.business_customer_content_v95 content
  where content.business_id=p_business
    and content.content_type='offer'
    and content.metadata->>'schema'='nestly.promotion.v104'
    and content.metadata ? 'published_once_at';

  with bounded as (
    select content.*
    from public.business_customer_content_v95 content
    where content.business_id=p_business
      and content.content_type='offer'
    order by content.active desc,content.display_order,
      content.updated_at desc,content.id
    limit 100
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'id',content.id,
    'business_id',content.business_id,
    'branch_id',content.branch_id,
    'status',case when content.active then 'published' else 'draft' end,
    'publish_state',case when content.active then 'published' else 'draft' end,
    'active',content.active,
    'display_order',content.display_order,
    'starts_at',content.starts_at,
    'ends_at',content.ends_at,
    'metadata',content.metadata,
    'content_version',content.version,
    'copy_version',coalesce(copy.version,0),
    'name',copy.name,
    'tagline',copy.tagline,
    'description',copy.description,
    'terms',copy.terms,
    'image_url',media.url,
    'image_alt',media.alt_en,
    'media_asset_id',media.id,
    'media_version',coalesce(media.version,0),
    'image_asset_version',coalesce(media.version,0),
    'image_customer_visible',coalesce(media.customer_visible,false),
    'media_versions_by_scope',coalesce(
      media_scopes.items,'{}'::jsonb
    )
  ) order by content.active desc,content.display_order,
      content.updated_at desc,content.id),'[]'::jsonb)
  into v_items
  from bounded content
  left join public.business_localized_copy_v95 copy
    on copy.business_id=p_business
    and copy.entity_type='offer'
    and copy.entity_id=content.id
    and copy.locale='en'
  left join lateral(
    select asset.id,app.v95_public_media_url(asset.object_path) url,
      asset.version,asset.alt_en,asset.customer_visible
    from public.business_media_assets_v95 asset
    where asset.business_id=p_business
      and asset.asset_kind='offer'
      and asset.entity_id=content.id
      and (
        asset.branch_id is not distinct from content.branch_id
        or (content.branch_id is not null and asset.branch_id is null)
      )
    order by (asset.branch_id is not distinct from content.branch_id) desc,
      asset.updated_at desc,asset.id
    limit 1
  ) media on true
  left join lateral(
    select jsonb_object_agg(
      coalesce(asset.branch_id::text,'global'),
      jsonb_build_object(
        'branch_id',asset.branch_id,
        'media_asset_id',asset.id,
        'media_version',asset.version,
        'customer_visible',asset.customer_visible,
        'image_url',app.v95_public_media_url(asset.object_path),
        'image_alt',asset.alt_en
      )
    ) items
    from public.business_media_assets_v95 asset
    where asset.business_id=p_business
      and asset.asset_kind='offer'
      and asset.entity_id=content.id
  ) media_scopes on true;

  return jsonb_build_object(
    'items',v_items,
    'entitlement',jsonb_build_object(
      'max_published_offers',v_entitlement.max_published_offers,
      'complimentary_until',v_entitlement.complimentary_until,
      'version',v_entitlement.version,
      'published_count',v_published_count,
      'quota_used',v_quota_used,
      'quota_limit',v_entitlement.max_published_offers,
      'quota_remaining',greatest(
        v_entitlement.max_published_offers-v_quota_used,0
      ),
      'can_publish_new',
        now()<v_entitlement.complimentary_until
        and v_quota_used<v_entitlement.max_published_offers
    )
  );
end
$$;

create or replace function public.customer_get_promotions_v104(
  p_business uuid,
  p_branch uuid default null,
  p_locale text default 'en'
)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare
  v_actor uuid:=auth.uid();
  v_identity uuid;
  v_items jsonb;
begin
  if v_actor is null then
    raise exception 'authenticated_session_required' using errcode='28000';
  end if;
  if p_business is null
     or p_branch is not null
     or p_locale not in ('en','zh-CN')
  then
    raise exception 'valid_promotion_reader_context_required'
      using errcode='22023';
  end if;

  v_identity:=app.v31_current_identity();
  if not exists(
    select 1
    from public.customer_links link
    where link.identity_id=v_identity
      and link.auth_user_id=v_actor
      and link.business_id=p_business
      and link.state='verified'
  ) then
    raise exception 'verified_customer_link_required' using errcode='42501';
  end if;

  with visible as (
    select
      content.id,content.display_order,content.starts_at,content.ends_at,
      content.metadata,content.updated_at,
      coalesce(copy.name,english.name,'Offer') name,
      coalesce(copy.tagline,english.tagline) tagline,
      coalesce(copy.description,english.description) description,
      coalesce(copy.terms,english.terms) terms,
      media.url image_url,media.image_alt
    from public.business_customer_content_v95 content
    left join public.business_localized_copy_v95 copy
      on copy.business_id=p_business
      and copy.entity_type='offer'
      and copy.entity_id=content.id
      and copy.locale=p_locale
    left join public.business_localized_copy_v95 english
      on english.business_id=p_business
      and english.entity_type='offer'
      and english.entity_id=content.id
      and english.locale='en'
    left join lateral(
      select app.v95_public_media_url(asset.object_path) url,
        case when p_locale='zh-CN'
          then coalesce(asset.alt_zh_cn,asset.alt_en)
          else asset.alt_en
        end image_alt
      from public.business_media_assets_v95 asset
      where asset.business_id=p_business
        and asset.asset_kind='offer'
        and asset.entity_id=content.id
        and asset.customer_visible
        and asset.branch_id is null
      order by asset.updated_at desc,asset.id
      limit 1
    ) media on true
    where content.business_id=p_business
      and content.content_type='offer'
      and content.active
      and content.branch_id is null
      and (content.starts_at is null or content.starts_at<=now())
      and content.ends_at>now()
      and media.url is not null
    order by content.display_order,content.starts_at desc nulls last,
      content.updated_at desc,content.id
    limit 2
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'id',visible.id,
    'name',visible.name,
    'tagline',visible.tagline,
    'description',visible.description,
    'terms',visible.terms,
    'image_url',visible.image_url,
    'image_alt',visible.image_alt,
    'starts_at',visible.starts_at,
    'ends_at',visible.ends_at,
    'display_order',visible.display_order,
    'metadata',visible.metadata
  ) order by visible.display_order,visible.starts_at desc nulls last,
      visible.updated_at desc,visible.id),'[]'::jsonb)
  into v_items
  from visible;

  return jsonb_build_object(
    'business_id',p_business,
    'branch_id',null,
    'locale',p_locale,
    'items',v_items,
    'limit',2
  );
end
$$;

-- Finite browser ACLs. The entitlement table remains RPC-only.
revoke all on function public.platform_set_promotion_entitlement_v104(
  uuid,integer,timestamptz,bigint
) from public,anon,authenticated;
grant execute on function public.platform_set_promotion_entitlement_v104(
  uuid,integer,timestamptz,bigint
) to authenticated;

revoke all on function public.business_save_promotion_v104(
  uuid,uuid,uuid,text,text,text,text,timestamptz,timestamptz,integer,
  text,text,text,text,boolean,bigint,bigint
) from public,anon,authenticated;
grant execute on function public.business_save_promotion_v104(
  uuid,uuid,uuid,text,text,text,text,timestamptz,timestamptz,integer,
  text,text,text,text,boolean,bigint,bigint
) to authenticated;

revoke all on function public.business_create_promotion_draft_v104(
  uuid,uuid,uuid,uuid,text,text,text,text,timestamptz,timestamptz,integer,
  text,text,text,text
) from public,anon,authenticated;
grant execute on function public.business_create_promotion_draft_v104(
  uuid,uuid,uuid,uuid,text,text,text,text,timestamptz,timestamptz,integer,
  text,text,text,text
) to authenticated;

revoke all on function public.business_finalize_promotion_v104(
  uuid,uuid,uuid,text,text,text,text,timestamptz,timestamptz,integer,
  text,text,text,text,boolean,text,text,integer,integer,text,
  bigint,bigint,bigint,uuid
) from public,anon,authenticated;
grant execute on function public.business_finalize_promotion_v104(
  uuid,uuid,uuid,text,text,text,text,timestamptz,timestamptz,integer,
  text,text,text,text,boolean,text,text,integer,integer,text,
  bigint,bigint,bigint,uuid
) to authenticated;

revoke all on function public.business_get_promotion_editor_v104(uuid)
  from public,anon,authenticated;
grant execute on function public.business_get_promotion_editor_v104(uuid)
  to authenticated;

revoke all on function public.customer_get_promotions_v104(uuid,uuid,text)
  from public,anon,authenticated;
grant execute on function public.customer_get_promotions_v104(uuid,uuid,text)
  to authenticated;

commit;
