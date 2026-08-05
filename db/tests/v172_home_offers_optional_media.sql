-- Rollback-only acceptance for V172 optional Home-offer media.
-- Run after the canonical chain through v172 in a disposable local database.
--
-- Proves:
--   * customer_get_home_offers_v167 still exists after the rewrite;
--   * its offer-media lateral join is LEFT, so a published offer without a
--     customer-visible image is included on the customer Home shelf (parity
--     with customer_get_promotions_v155);
--   * no inner lateral join remains in the function.
begin;

do $$
declare
  v_def text;
  v_inner integer;
  v_left integer;
begin
  select pg_get_functiondef(p.oid) into v_def
    from pg_proc p join pg_namespace n on n.oid=p.pronamespace
   where n.nspname='public' and p.proname='customer_get_home_offers_v167';
  if v_def is null then
    raise exception 'v172 FAIL: customer_get_home_offers_v167 is missing';
  end if;
  select count(*) into v_inner
    from regexp_matches(v_def,'(?<!left )join lateral\(','g');
  if v_inner <> 0 then
    raise exception 'v172 FAIL: % inner lateral join(s) remain in customer_get_home_offers_v167', v_inner;
  end if;
  select count(*) into v_left
    from regexp_matches(v_def,'left join lateral\(','g');
  if v_left < 2 then
    raise exception 'v172 FAIL: expected at least two left lateral joins (media and branches), found %', v_left;
  end if;
  raise notice 'v172 PASS: offer media join is optional (% left laterals, 0 inner)', v_left;
end $$;

rollback;
