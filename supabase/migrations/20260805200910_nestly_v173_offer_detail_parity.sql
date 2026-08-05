-- v173: business-page offers parity + offer-detail business contact.
--
-- (1) customer_get_promotions_v155 (the business-page "Latest offers" reader)
--     still required an uploaded image (`media.url is not null`) and capped the
--     list at two rows. The Home shelf reader stopped requiring images in v172,
--     so a published imageless offer appeared on Home but vanished inside the
--     business page — the two surfaces must always agree. The image predicate
--     is dropped and the cap raised to six. Patched with the same self-guarded
--     definition rewrite technique as v172; a no-op when already applied.
--
-- (2) public.customer_get_offer_business_contact_v173: a minimal, verified-
--     link-gated reader giving the customer offer-detail sheet the business's
--     default-branch address/phone/email plus identity. The caller cannot
--     nominate a customer or tenant; anonymous execution is revoked.
begin;

do $$
declare
  v_def text;
  v_filter integer;
begin
  select pg_get_functiondef(p.oid) into v_def
    from pg_proc p join pg_namespace n on n.oid=p.pronamespace
   where n.nspname='public' and p.proname='customer_get_promotions_v155';
  if v_def is null then
    raise exception 'customer_get_promotions_v155 is missing';
  end if;
  select count(*) into v_filter
    from regexp_matches(v_def,'and media\.url is not null','g');
  if v_filter = 0 and v_def like '%limit 6%' then
    return; -- already applied
  end if;
  if v_filter <> 1 then
    raise exception
      'expected exactly one media.url filter in customer_get_promotions_v155, found %',
      v_filter;
  end if;
  v_def := regexp_replace(v_def,'\s*and media\.url is not null','');
  -- \y is the Postgres word boundary (\b is a backspace escape here)
  v_def := regexp_replace(v_def,'limit 2\y','limit 6');
  execute v_def;
end $$;

create or replace function public.customer_get_offer_business_contact_v173(p_business uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare
  v_actor uuid := auth.uid();
  v_identity uuid;
  v_result jsonb;
begin
  if v_actor is null then
    raise exception 'authenticated_session_required' using errcode='28000';
  end if;
  if p_business is null then
    raise exception 'business_required' using errcode='22023';
  end if;
  v_identity := app.v31_current_identity();
  if not exists(
    select 1 from public.customer_links link
    where link.identity_id = v_identity
      and link.auth_user_id = v_actor
      and link.business_id = p_business
      and link.state = 'verified'
  ) then
    raise exception 'verified_customer_link_required' using errcode='42501';
  end if;

  select jsonb_build_object(
    'business', jsonb_build_object(
      'id', business.id,
      'slug', business.slug,
      'name', business.name
    ),
    'branch', case when branch.id is null then null else jsonb_build_object(
      'name', branch.name,
      'address', branch.address,
      'phone', branch.phone,
      'email', branch.email
    ) end
  ) into v_result
  from public.businesses business
  left join lateral (
    select b.id, b.name, b.address, b.phone, b.email
    from public.branches b
    where b.business_id = business.id and coalesce(b.active,true)
    order by b.is_default desc, b.created_at, b.id
    limit 1
  ) branch on true
  where business.id = p_business;

  return v_result;
end
$$;

comment on function public.customer_get_offer_business_contact_v173(uuid) is
  'Default-branch contact for the customer offer-detail sheet; requires an auth.uid() verified customer link to the business.';

revoke all on function public.customer_get_offer_business_contact_v173(uuid) from public,anon;
grant execute on function public.customer_get_offer_business_contact_v173(uuid) to authenticated;

-- (3) The owner-console "visible promotions" counter mirrored the old
--     image-required visibility. Now that customer readers render imageless
--     offers, the count keeps the same non-media conditions but drops the
--     media requirement — otherwise the console claims "0 published" while
--     customers can see offers.
create or replace function public.business_get_visible_promotion_count_v167(p_business uuid)
returns jsonb
language plpgsql
stable security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $function$
declare
  v_count integer;
begin
  if auth.uid() is null or p_business is null then
    raise exception 'authenticated_business_context_required' using errcode='28000';
  end if;
  if not app.is_salon_owner(p_business) then
    raise exception 'owner_required' using errcode='42501';
  end if;

  -- v173: media is optional for customer visibility (customer readers render a
  -- branded fallback), so the owner-facing count no longer requires an image.
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
    );

  return jsonb_build_object(
    'business_id',p_business,
    'visible_count',v_count,
    'as_of',statement_timestamp()
  );
end
$function$;

revoke all on function public.business_get_visible_promotion_count_v167(uuid) from public,anon;
grant execute on function public.business_get_visible_promotion_count_v167(uuid) to authenticated;

commit;
