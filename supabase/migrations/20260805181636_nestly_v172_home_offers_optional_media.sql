-- v172: Home offers shelf must not require an offer image.
-- customer_get_home_offers_v167 joined offer media with an INNER lateral join,
-- so a published offer without a customer-visible image was silently excluded
-- from the customer Home shelf, while customer_get_promotions_v155 (the
-- business-page reader) uses a LEFT lateral join and shows the same offer.
-- The customer UI renders a branded no-image fallback, so the image gate only
-- hid legitimate promotions. This migration rewrites exactly that one join.
-- Self-guarding: it verifies the function still has exactly one inner media
-- lateral before patching, and is a no-op when already applied.
begin;
do $$
declare
  v_def text;
  v_inner integer;
begin
  select pg_get_functiondef(p.oid) into v_def
    from pg_proc p join pg_namespace n on n.oid=p.pronamespace
   where n.nspname='public' and p.proname='customer_get_home_offers_v167';
  if v_def is null then
    raise exception 'customer_get_home_offers_v167 is missing';
  end if;
  select count(*) into v_inner
    from regexp_matches(v_def,'(?<!left )join lateral\(','g');
  if v_inner = 0 then
    return; -- already applied
  end if;
  if v_inner <> 1 then
    raise exception
      'expected exactly one inner lateral join in customer_get_home_offers_v167, found %',
      v_inner;
  end if;
  v_def := regexp_replace(v_def,'(?<!left )join lateral\(','left join lateral(');
  execute v_def;
end $$;
commit;
