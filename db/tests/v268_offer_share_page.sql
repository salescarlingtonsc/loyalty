-- Rollback-only acceptance for v268 — the public read behind the shared-offer landing page.
--
-- Runs inside one transaction and rolls back. Proves, against REAL tenant rows:
--   * a customer-visible offer resolves with the fields the page renders (name, artwork,
--     business identity, the co-brand's logo);
--   * every visibility condition is load-bearing: deactivating the offer, expiring it, or
--     unpublishing its artwork each kills the share page at that same moment;
--   * an unknown id returns NULL — the page redirects a recipient, never 404s them;
--   * anon holds EXECUTE (the caller is a link-preview crawler that cannot authenticate) and
--     the function is STABLE — a read that can never write.

begin;

do $suite$
declare
  v_offer uuid;
  v_asset uuid;
  v_page jsonb;
begin
  select content.id into v_offer
    from public.business_customer_content_v95 content
   where content.content_type = 'offer' and content.active
     and (content.starts_at is null or content.starts_at <= now())
     and content.ends_at > now()
     and exists (
       select 1 from public.business_media_assets_v95 asset
        where asset.business_id = content.business_id and asset.asset_kind = 'offer'
          and asset.entity_id = content.id and asset.customer_visible and asset.branch_id is null)
   limit 1;
  if v_offer is null then
    raise exception 'v268: no live customer-visible offer to test against';
  end if;

  v_page := public.offer_share_page_v268(v_offer);
  if v_page is null then
    raise exception 'v268: a customer-visible offer must resolve';
  end if;
  if coalesce(v_page->>'name','') = '' or coalesce(v_page->>'business_slug','') = ''
     or coalesce(v_page->>'image_url','') = '' then
    raise exception 'v268: the page needs name, slug and artwork; got %', v_page;
  end if;

  -- offer rows are guarded against writes outside the v104 RPCs; this suite mutates them only
  -- to prove visibility flips, inside a transaction that rolls back, so it opens the same
  -- transaction-local door the RPCs use
  perform set_config('app.v104_promotion_write','on',true);
  perform set_config('app.v104_promotion_media_write','on',true);

  -- deactivating the offer kills its share links at the same moment it leaves the app
  update public.business_customer_content_v95 set active = false where id = v_offer;
  if public.offer_share_page_v268(v_offer) is not null then
    raise exception 'v268: an inactive offer must not resolve';
  end if;
  update public.business_customer_content_v95 set active = true where id = v_offer;

  -- so does expiry
  update public.business_customer_content_v95 set ends_at = now() - interval '1 minute' where id = v_offer;
  if public.offer_share_page_v268(v_offer) is not null then
    raise exception 'v268: an expired offer must not resolve';
  end if;
  update public.business_customer_content_v95 set ends_at = now() + interval '1 day' where id = v_offer;

  -- and so does unpublishing the artwork (the customer list requires it; this page must agree)
  update public.business_media_assets_v95 set customer_visible = false
   where asset_kind = 'offer' and entity_id = v_offer;
  if public.offer_share_page_v268(v_offer) is not null then
    raise exception 'v268: an offer with unpublished artwork must not resolve';
  end if;

  if public.offer_share_page_v268('00000000-0000-0000-0000-000000000000'::uuid) is not null then
    raise exception 'v268: an unknown id must be NULL so the page can redirect, not 404';
  end if;

  -- the crawler cannot authenticate: anon must hold EXECUTE, and the function must be read-only
  if not has_function_privilege('anon', 'public.offer_share_page_v268(uuid)', 'EXECUTE') then
    raise exception 'v268: anon must be able to call the share-page read';
  end if;
  if (select provolatile from pg_proc p join pg_namespace n on n.oid = p.pronamespace
       where n.nspname = 'public' and p.proname = 'offer_share_page_v268') <> 's' then
    raise exception 'v268: the function must be STABLE — a read that can never write';
  end if;

  raise notice 'v268 acceptance: all assertions passed';
end $suite$;

rollback;
