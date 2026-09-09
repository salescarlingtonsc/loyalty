-- NESTLY v868 — a bundle that contains a PRODUCT can be priced but can never be sold.
--
-- THE DEFECT. public.record_cart_sale/11 (the kernel finaliser) re-projects every server line of
-- the checkout token and compares it against a freshly-priced copy, so that a bundle whose
-- composition or price moved between "Price it" and "Record sale" fails as stale_evaluation
-- rather than charging a price nobody agreed to. Section 8.4 did that comparison on ONE field:
--
--     if v257_bline is null or nullif(v257_bline->>'service_id', '')::uuid is distinct from v_cid
--
-- app.ps1c_bundle_lines_v204 expands a bundle into one line per member and identifies every
-- member by 'item_id' + 'kind'; 'service_id' is a service-only convenience field and is NULL for
-- a product member. app.ps1c_plan_checkout has known this since v488 — it writes
-- catalog_kind = coalesce(kind,'service') and catalog_id = coalesce(item_id, service_id) into
-- checkout_evaluations.server_lines. The finaliser did not. So for a product member the guard
-- read NULL, compared it to the product's catalog_id, found them distinct, and raised
-- unconditionally. Not a rare race: EVERY finalise of a bundle containing a product failed, on
-- the first attempt and on every re-evaluation after it. The till could quote the bundle and
-- then never record it, with the customer standing at the counter.
--
-- LIVE IMPACT. 1 of the 4 bundles in production: AhXiang's "Package x5 facial + treatment"
-- (33773caa-6d51-4cf2-9ad6-b83f015759e6 / 9d0646d1-f669-4db0-9709-c5d0482b926d, 500,000c, four
-- services + one product). Re-projecting it today, member 5 (SK-II Facial Treatment Clear
-- Lotion, c85f5479-f35e-49a9-84cc-7de018978aa2, 14,862c) makes the old predicate TRUE — the sale
-- raises — while members 1-4 pass. The service-only bundles (AhXiang "Ultimate Glow", Cubbly
-- "Rainbow special", ELAN "The Elen Ritual") were never affected.
--
-- THE FIX. Compare the SAME pair the evaluator wrote into the token: the member's own identifier
-- (coalesce(item_id, service_id), which is the service id for a service member and the product
-- id for a product member) AND its kind. This is not a relaxation — it is strictly stronger than
-- what shipped:
--
--   * a swapped member (a different id at that position) still raises;
--   * a removed member (v257_bline null at that position) still raises;
--   * a re-ordered bundle still raises — v257_pos is untouched, so the guard stays
--     position-sensitive and member N of the token must still be member N of the re-pricing;
--   * a KIND FLIP at the same position now raises too, which the old one-field check could only
--     catch by accident;
--   * price drift is caught where it always was, by app.ps1c_cart_hash over the re-projection
--     (it hashes catalog_kind, catalog_id, qty, unit_price_cents and line_total_cents), which
--     this migration does not touch. v_unit still comes from the freshly-priced line_cents.
--
-- WHAT IS NOT WRONG. app.ps1c_bundle_lines_v204 is correct and is NOT changed: it already emits
-- product members with kind='product', item_id=<product id>, service_id=null, and allocates the
-- bundle price across them (the five AhXiang members sum to exactly 500,000c). The 7-argument
-- record_cart_sale overload — the pre-kernel path, no evaluation token — has no bundle handling
-- at all and therefore does not carry this defect; it is not touched either.
--
-- HOW. record_cart_sale/11 is patched in place, anchored on the live body (the same technique
-- v825/v827 used), so nothing else in a 24KB finaliser can drift while fixing one predicate.
-- The anchor must occur exactly once or the migration refuses to run.

begin;

do $patch$
declare
  v_src text;
  v_new text;
  v_hits int;
  c_old constant text :=
    '      if v257_bline is null or nullif(v257_bline->>''service_id'', '''')::uuid is distinct from v_cid then' || E'\n';
  c_new constant text :=
    '      -- nestly_v868: identify the re-projected member the way app.ps1c_plan_checkout did when' || E'\n' ||
    '      -- it wrote this token — by its OWN id and kind. ''service_id'' is null for a product' || E'\n' ||
    '      -- member, so comparing it alone made this guard unconditionally true and a bundle' || E'\n' ||
    '      -- containing a product could be priced but never sold. Composition drift (a swapped,' || E'\n' ||
    '      -- removed or re-ordered member, and now a kind flip) still raises; price drift is still' || E'\n' ||
    '      -- caught by the cart re-hash below.' || E'\n' ||
    '      if v257_bline is null' || E'\n' ||
    '         or coalesce(nullif(v257_bline->>''item_id'', ''''), v257_bline->>''service_id'')::uuid is distinct from v_cid' || E'\n' ||
    '         or coalesce(v257_bline->>''kind'', ''service'') is distinct from v_kind then' || E'\n';
begin
  select pg_get_functiondef(p.oid) into v_src
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'record_cart_sale' and p.pronargs = 11;
  if v_src is null then
    raise exception 'v868: record_cart_sale/11 not found';
  end if;

  if position('nestly_v868' in v_src) > 0 then
    raise notice 'v868: record_cart_sale/11 already identifies a bundle member by id + kind — nothing to patch';
  else
    v_hits := (length(v_src) - length(replace(v_src, c_old, ''))) / length(c_old);
    if v_hits <> 1 then
      raise exception 'v868: the bundle drift-guard anchor occurs % times in record_cart_sale/11, expected exactly 1', v_hits;
    end if;
    v_new := replace(v_src, c_old, c_new);
    execute v_new;
  end if;

  select pg_get_functiondef(p.oid) into v_src
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'record_cart_sale' and p.pronargs = 11;
  if position('nestly_v868' in v_src) = 0 then
    raise exception 'v868: record_cart_sale/11 did not take the bundle member-identity guard';
  end if;
  if position('nullif(v257_bline->>''service_id'', '''')::uuid is distinct from v_cid' in v_src) > 0 then
    raise exception 'v868: the service_id-only bundle guard is still present in record_cart_sale/11';
  end if;
  -- The position cursor and the price re-hash must both survive the patch untouched.
  if position('v257_pos := v257_pos + 1;' in v_src) = 0
     or position('v_rehash := app.ps1c_cart_hash(v_reproj);' in v_src) = 0 then
    raise exception 'v868: the patch disturbed the bundle position cursor or the cart re-hash';
  end if;
end
$patch$;

-- CREATE OR REPLACE preserves the ACL; the grants are restated so the migration is the whole
-- truth about who may call this function (unchanged from v752/v827: authenticated + service_role).
revoke all on function public.record_cart_sale(uuid, uuid, uuid, uuid, text, text, jsonb, uuid, boolean, timestamptz, jsonb)
  from public, anon, authenticated;
grant execute on function public.record_cart_sale(uuid, uuid, uuid, uuid, text, text, jsonb, uuid, boolean, timestamptz, jsonb)
  to authenticated, service_role;

commit;
