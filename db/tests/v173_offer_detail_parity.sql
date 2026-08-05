-- Rollback-only acceptance for V173 offer parity + contact reader.
-- Run after the canonical chain through v173 in a disposable local database.
--
-- Proves:
--   * customer_get_promotions_v155 no longer requires offer media and returns
--     up to six rows, so the business page agrees with the Home shelf;
--   * customer_get_offer_business_contact_v173 exists, is SECURITY DEFINER
--     with a pinned search_path, and is not executable by anon.
begin;

do $$
declare
  v_def text;
begin
  select pg_get_functiondef(p.oid) into v_def
    from pg_proc p join pg_namespace n on n.oid=p.pronamespace
   where n.nspname='public' and p.proname='customer_get_promotions_v155';
  if v_def is null then
    raise exception 'v173 FAIL: customer_get_promotions_v155 is missing';
  end if;
  if v_def like '%and media.url is not null%' then
    raise exception 'v173 FAIL: business-page offers still require an image';
  end if;
  if v_def not like '%limit 6%' then
    raise exception 'v173 FAIL: business-page offer cap was not raised to six';
  end if;

  select pg_get_functiondef(p.oid) into v_def
    from pg_proc p join pg_namespace n on n.oid=p.pronamespace
   where n.nspname='public' and p.proname='customer_get_offer_business_contact_v173';
  if v_def is null then
    raise exception 'v173 FAIL: customer_get_offer_business_contact_v173 is missing';
  end if;
  if v_def !~* 'security definer' or v_def !~* 'set search_path' then
    raise exception 'v173 FAIL: contact reader must be SECURITY DEFINER with pinned search_path';
  end if;
  if exists(
    select 1 from information_schema.routine_privileges
    where routine_schema='public'
      and routine_name='customer_get_offer_business_contact_v173'
      and grantee in ('PUBLIC','anon')
      and privilege_type='EXECUTE'
  ) then
    raise exception 'v173 FAIL: anon/public may execute the contact reader';
  end if;
  select pg_get_functiondef(p.oid) into v_def
    from pg_proc p join pg_namespace n on n.oid=p.pronamespace
   where n.nspname='public' and p.proname='business_get_visible_promotion_count_v167';
  if v_def like '%business_media_assets_v95%' then
    raise exception 'v173 FAIL: owner visible-promotion count still requires an image';
  end if;
  raise notice 'v173 PASS: offer parity, counter parity and contact reader verified';
end $$;

rollback;
