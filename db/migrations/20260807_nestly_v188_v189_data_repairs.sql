-- V188 + V189 — production DATA repairs, applied 2026-08-07 via MCP apply_migration
-- (nestly_v188_hougang_menu_services_to_products, nestly_v189_dedupe_hougang_recommended_rewards).
-- Recorded here so the repo chain reflects what production actually ran.
--
-- V188 — a café's menu was living in the Services catalogue.
-- Hougang ABC (F&B) had entered Coffee, Ice Cream, Candy Floss, Cheese Cake, Teacake and Vietnam
-- Coffee as SERVICES with invented durations ("1 min", "60 min"), because the Products module was
-- invisible to every business until the V184 kernel kill switch was removed. 7 active services,
-- 0 products, 0 appointments ever. Menu items are products: no duration, no staff, no time slot.
--   * Services are DEACTIVATED, not deleted — two are referenced by bundle_items and a delete
--     would fail or destroy that bundle.
--   * No sale line table references services.id, so all 24 existing sales keep their snapshots
--     and every past receipt still reads exactly as before.
--   * The product insert is name-guarded, so re-running is a no-op rather than a duplicate menu.
--
-- V189 — the recommended-reward setup was silently duplicating.
-- The Programmes list showed SIX identical "A thank-you on your next visits" rows at 8 stamps,
-- created on six separate occasions. The recommended reward has no stable identity, so each
-- recommend -> publish cycle minted a new reward instead of updating the existing one. Setup was
-- not failing; it was duplicating, which is why it read as broken.
--   * None of the six had ever been redeemed (asserted before the write).
--   * The EARLIEST is kept; the five later copies are deactivated, not deleted, because
--     loyalty_reward_versions rows reference them across every past config version.
--   * The duplicate-creation defect itself is NOT fixed by this file: giving a recommended
--     reward a stable identity is a kernel change and is still outstanding.
--
-- Both are scoped to one business by name and touch no other tenant.
begin;

-- V188
do $$
declare v_biz uuid;
begin
  select id into v_biz from public.businesses where name='Hougang ABC';
  if v_biz is null then return; end if;
  insert into public.products(business_id, name, retail_price_cents, active)
  select v_biz, s.name, s.price_cents, s.active
    from public.services s
   where s.business_id = v_biz
     and not exists (select 1 from public.products p
                      where p.business_id = v_biz and lower(p.name) = lower(s.name));
  update public.services set active = false where business_id = v_biz and active;
end $$;

-- V189
do $$
declare v_biz uuid; v_keep uuid;
begin
  select id into v_biz from public.businesses where name='Hougang ABC';
  if v_biz is null then return; end if;
  select id into v_keep from public.loyalty_rewards
   where business_id=v_biz and customer_name='A thank-you on your next visits'
   order by created_at limit 1;
  if v_keep is null then return; end if;
  if exists (
    select 1 from public.loyalty_redemptions lr
     join public.loyalty_rewards r on r.id=lr.reward_id
    where r.business_id=v_biz and r.customer_name='A thank-you on your next visits'
      and r.id<>v_keep
  ) then
    raise exception 'a duplicate reward has redemptions; refusing to retire it';
  end if;
  update public.loyalty_rewards set active=false
   where business_id=v_biz and customer_name='A thank-you on your next visits'
     and id<>v_keep and active;
end $$;

commit;
