-- FRENLY v53a - WALLET REVIEW-LINK PROJECTION
--
-- Forward-only surgical repair. v53 added businesses.review_url and the UI's anti-gating
-- review-link paths, but the customer wallet derives its business object from
-- public.customer_get_business_summary (v32), which projects only slug/name/industry/
-- currency from the app.v32_customer_wallet_context row and therefore never surfaced
-- review_url. Customers also have no direct RLS read on public.businesses
-- (salons_select requires is_salon_member), so the link was dark in the wallet.
--
-- FIX: add one key, 'review_url', to the business jsonb_build_object in
-- customer_get_business_summary. The value is read via a scalar subselect on
-- public.businesses keyed by the already-verified v_context.business_id (the customer is
-- verified for that business, and this SECURITY DEFINER function may read it), so nothing
-- else in the projection or the context helper changes. review_url is nullable, so a
-- business that has not set one yields "review_url": null and the UI treats that as
-- "no link" (never gating negatives).
--
-- SCOPE — exactly ONE projection site, and why the others are excluded:
--   * customer_get_business_summary — INCLUDED. It is the surface the wallet UI reads for
--     per-business info. It builds the business object TWICE (the normal select and a
--     defensive coalesce fallback); both are byte-identical, so the single fail-closed
--     replace below covers both (asserted occurrence count = 2).
--   * customer_get_wallet (the multi-firm wallet LIST) — EXCLUDED. It builds its own
--     business object from the same context helper, but the review-link path is the
--     per-business detail, not the card list; the UI does not read review_url there.
--   * customer_get_actionable_business (v44) — EXCLUDED. It is a DIFFERENT code path: it
--     builds its own jsonb from v_context and never calls this function or a shared
--     projection helper, and the UI does not read its output for the review link.
--   There is NO shared jsonb-building helper to change; the context helper
--   (app.v32_customer_wallet_context) only returns scalar business columns.
--
-- Fail-closed in the v49a/v52 style: the live definition must contain the exact old
-- projection tail exactly twice and the new tail zero times, or the migration aborts;
-- definer/search_path pinning is asserted and the exact ACL is reasserted afterwards.

begin;

do $review_projection$
declare
  v_def text;
  v_old text := '''currency'', v_context.business_currency';
  v_new text := '''currency'', v_context.business_currency,'
    || E'\n      ''review_url'', (select b.review_url from public.businesses b where b.id = v_context.business_id)';
  v_old_n integer;
  v_new_n integer;
begin
  select pg_get_functiondef('public.customer_get_business_summary(text)'::regprocedure) into strict v_def;
  v_old_n := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  v_new_n := (length(v_def) - length(replace(v_def, v_new, ''))) / length(v_new);
  if v_old_n <> 2 or v_new_n <> 0 then
    raise exception 'unexpected customer_get_business_summary predecessor business projection (old=%, new=%)',
      v_old_n, v_new_n;
  end if;
  if position('security definer' in lower(v_def)) = 0
     or position('set search_path' in lower(v_def)) = 0 then
    raise exception 'customer_get_business_summary predecessor lost its definer/search_path pinning';
  end if;
  execute replace(v_def, v_old, v_new);
end
$review_projection$;

-- PostgreSQL preserves grants across CREATE OR REPLACE; reassert the exact v32 boundary
-- so it is explicit and self-contained: authenticated only, never anon/PUBLIC.
revoke all on function public.customer_get_business_summary(text) from public, anon;
grant execute on function public.customer_get_business_summary(text) to authenticated;

commit;
