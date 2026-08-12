-- NESTLY v282 HOTFIX: stop the promotion-finalize rollback storm.
-- (Applied to production 2026-08-11 as the emergency fix; lands in the repo as
--  v282 because a parallel Stripe-readiness migration claimed the v281 slot on
--  main. This file's function body is byte-identical to what is live on prod;
--  the inline guard marker reads "V281 fast-fail" — its original hotfix number.)
--
-- INCIDENT: a client (an abandoned browser tab running a pre-V280 bundle that
-- auto-retried a doomed finalize) hit business_finalize_promotion at ~500 req/s
-- for ~5 days. Each retry sent a permanently-stale p_expected_content_version,
-- so it took the per-business advisory lock (app.v104_lock_promotion_business)
-- and read 8 tables before raising 40001 promotion_version_conflict. Every retry
-- for the same business serialized on that lock into a convoy that drained the
-- PostgREST connection pool -> "exhausting multiple resources" / PGRST002. Live
-- evidence: xact_rollback 220M vs xact_commit 2M, 13-14 advisory-lock waiters,
-- 533 rollbacks/s. The deployed V280 CLIENT already prevents the loop for any
-- freshly-loaded tab (it releases the stale receipt instead of auto-retrying);
-- this is the server-side belt-and-suspenders so a stale tab can never again
-- drain the pool.
--
-- FIX: a two-index-scan short-circuit BEFORE the advisory lock and the heavy
-- reads. It raises the SAME 40001 the authoritative check raises ~30 lines
-- later, so no legitimate caller changes outcome; a genuine replay (matching
-- attempt receipt) skips the guard and takes the normal path. Verified rolled
-- back on prod against a real offer row (db/tests/v282_*), then applied; the
-- live convoy collapsed to 0 advisory waiters and 0 rollbacks/s immediately.

begin;

create or replace function public.business_finalize_promotion_v104(p_business uuid, p_promotion_id uuid, p_branch uuid, p_name text, p_tagline text, p_description text, p_terms text, p_starts_at timestamp with time zone, p_ends_at timestamp with time zone, p_display_order integer, p_cta_kind text, p_cta_label text, p_offer_facts text, p_occasion text, p_publish boolean, p_object_path text, p_mime_type text, p_width_px integer, p_height_px integer, p_alt_en text, p_expected_content_version bigint, p_expected_copy_version bigint, p_expected_target_media_version bigint, p_attempt_key uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'app', 'pg_temp'
AS $function$
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

  -- V281 fast-fail: reject a stale-version retry before the advisory lock and the
  -- 8 table reads. Two indexed existence checks only. Same 40001 as the
  -- authoritative check below; a real replay (receipt present) skips this.
  if p_expected_content_version is not null
     and not exists(
       select 1 from public.business_promotion_attempt_receipts_v104 receipt
       where receipt.business_id=p_business and receipt.attempt_key=p_attempt_key)
     and exists(
       select 1 from public.business_customer_content_v95 content
       where content.id=p_promotion_id and content.business_id=p_business
         and content.content_type='offer'
         and content.version <> p_expected_content_version)
  then
    raise exception 'promotion_version_conflict' using errcode='40001';
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
$function$;

revoke all on function public.business_finalize_promotion_v104(uuid, uuid, uuid, text, text, text, text, timestamptz, timestamptz, integer, text, text, text, text, boolean, text, text, integer, integer, text, bigint, bigint, bigint, uuid)
  from public, anon;
grant execute on function public.business_finalize_promotion_v104(uuid, uuid, uuid, text, text, text, text, timestamptz, timestamptz, integer, text, text, text, text, boolean, text, text, integer, integer, text, bigint, bigint, bigint, uuid)
  to authenticated;

commit;
