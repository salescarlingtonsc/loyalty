-- nestly_v850 — commission is accurate after a discount, packages pay the member who sold
--               them, and gift cards pay nothing.
--
-- NUMBERING. Written, proved and APPLIED to production as nestly_v832 (deploy slot 20261009020000)
-- on 2026-09-09; a parallel session merged its own nestly_v832 (welcome backfill respects
-- consumption) to origin/main in the same hour, so this file yields the label and is registered
-- as nestly_v850 at slot 20261009170000. The DATABASE OBJECTS KEEP THEIR _v832 SUFFIX
-- (app.sale_item_discount_commission_v832, public.sell_package_v832, the guard window name)
-- because they were already live — the same resolution nestly_v818/v827 took.
--
-- OWNER REQUEST (2026-09-09): "verify the end to end sales commission works perfectly with data
-- accuracy ... test the different variations, from setting commission on product / services /
-- package / bundles > ensure staff commission is accurate. while staff commission % how accurate
-- is it? because it is now based on staff % multiply by the total revenue sold."
--
-- The variation walk (db/tests/v850_commission_accuracy_end_to_end.sql) found three places
-- where the number a member is paid is not "their rate × what the customer actually paid":
--
-- 1 · A DISCOUNT LINE WAS CHARGED AGAINST COMMISSION AT THE MEMBER'S PRODUCT RATE.
--     record_cart_sale writes a negative studio_discount line for every discount (v370/v656/
--     v752). The v825 resolver has no branch for that item type, so it falls to "anything else
--     → member product %". On AhXiang (services 8%, products 20%) a $1,895.40 tier discount on a
--     $9,477 bill of services therefore took $379.08 OFF the member's commission — 20% of the
--     discount — when the services it reduced had only ever paid 8%. Net: 5.2% of the net bill.
--     Where the member has NO product rate the discount deducted nothing at all, so the member
--     was paid on the GROSS bill (Cubbly, three sales). Both are wrong in opposite directions.
--     THE RULE NOW: a discount reduces commission by the bill's own blended PERCENTAGE rate —
--     Σ(commission of the %-paid positive lines) ÷ Σ(all positive lines) — applied to the
--     discount amount. A fixed-amount line ("$1 per Kopi Set") is excluded from the numerator,
--     because a fixed amount is paid per item sold and a price cut does not change how many
--     were sold; its cents stay in the denominator because the discount fell on the whole bill.
--     Rounding is floor on the deduction (the member keeps the odd cent). The line's stored
--     rate_bps is that blended rate, so the Staff commission page shows "8%" on the discount
--     line rather than the product rate. The same rule prices an item-scoped discount (v657):
--     the sale line does not record which item it landed on, so the bill's blended rate is the
--     honest approximation; it is exact whenever every %-line carries the same rate.
--     Every existing studio_discount line (10 rows, 4 tenants) is re-priced under a new,
--     narrower guard window that may touch ONLY the four commission columns of ONLY a
--     studio_discount line. The positive lines' snapshots are untouched.
--
-- 2 · A PACKAGE PAID WHOEVER WAS LOGGED IN, NOT WHO SOLD IT.
--     sell_package_v102 attributes the sale to the CALLER's own staff row. The till's team-member
--     picker (tillSaleStaffId) is sent to record_cart_sale for every other line but was never
--     sent for a package, so a package rung up by the owner for Mei paid the owner. New
--     public.sell_package_v832 takes p_staff (validated: an active member of this business) and
--     is byte-for-byte v102 otherwise — built by anchored replacement on the live body, each
--     anchor asserted to occur exactly once. sell_package_v102 becomes a wrapper that passes
--     null (caller's own row), so nothing that still calls it changes behaviour. The till moves
--     to v832 in app/app.js.
--
-- 3 · A GIFT CARD SALE PAID COMMISSION. frenly_v9: a gift card sale is cash collected, not
--     revenue; the revenue is the later sale that spends it, which pays commission then.
--     Paying on the gift card too paid twice. Gift cards are also not live (owner ruling AO-1,
--     2026-09-08). The line now pays 0. One historical line (AhXiang, $200 card, $40 commission)
--     is left as recorded — the page shows it, and re-stating a frozen snapshot on a live
--     liability is not this migration's call.
--
-- NOT changed: custom ("Other item") lines keep paying the member's product % (v827 listed
-- this explicitly as unchanged; the owner has not ruled). Reported separately.
--
-- ACLs restated from the live proacl: sell_package_v102 {postgres, service_role,
-- authenticated}; the new app helper gets no browser grant (it runs inside the trigger).

begin;

-- ------------------------------------------------------------------ §1 the discount rule
create or replace function app.sale_item_discount_commission_v832(
  p_business uuid, p_sale uuid, p_line_cents integer)
returns table(rate_bps integer, commission_cents integer)
language sql
stable
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $function$
  with positive as (
    select li.line_cents, coalesce(li.commission_cents, 0) as commission_cents,
           (li.commission_flat_cents is null and coalesce(li.commission_rate_bps, 0) > 0) as pct_paid
      from public.sale_items li
     where li.sale_id = p_sale and li.business_id = p_business
       and li.line_cents > 0
  ),
  pool as (
    select coalesce(sum(line_cents), 0)::numeric as total_cents,
           coalesce(sum(commission_cents) filter (where pct_paid), 0)::numeric as pct_commission
      from positive
  )
  select case when total_cents > 0 and coalesce(p_line_cents, 0) < 0
              then round(pct_commission * 10000 / total_cents)::integer else 0 end,
         case when total_cents > 0 and coalesce(p_line_cents, 0) < 0
              then -floor((-p_line_cents)::numeric * pct_commission / total_cents)::integer else 0 end
    from pool
$function$;

revoke all on function app.sale_item_discount_commission_v832(uuid, uuid, integer) from public, anon, authenticated;
grant execute on function app.sale_item_discount_commission_v832(uuid, uuid, integer) to service_role;

-- The trigger: the live v825 body (re-read from production 2026-09-09) plus the two branches.
create or replace function app.on_sale_item_commission_snapshot_v825()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'app', 'pg_temp'
AS $function$
declare
  v_sale public.sales%rowtype;
  v_staff uuid;
  v_bundle_price integer;
  v_bundle_flat integer;
  v_seen integer;
  v_seen_cents bigint;
  v_seen_commission bigint;
  v_members integer;
  v_bundles_sold integer;
  v_disc_bps integer;
  v_disc_cents integer;
begin
  select * into v_sale
    from public.sales
   where id = new.sale_id and business_id = new.business_id;
  if not found then
    raise exception 'sale % not found for line commission snapshot', new.sale_id
      using errcode = 'foreign_key_violation';
  end if;

  -- One commission for one staff member: the line's own attribution, else the sale's.
  v_staff := coalesce(new.staff_id, v_sale.staff_id);
  -- nestly_v832 — a discount line reduces commission at the bill's own blended percentage
  -- rate (see app.sale_item_discount_commission_v832), never at the member's product rate.
  if new.item_type = 'studio_discount' then
    select d.rate_bps, d.commission_cents into v_disc_bps, v_disc_cents
      from app.sale_item_discount_commission_v832(new.business_id, new.sale_id, new.line_cents) d;
    new.commission_rate_bps := v_disc_bps;
    new.commission_flat_cents := null;
    new.commission_cents := v_disc_cents;
    new.commission_resolved_at := now();
    return new;
  end if;
  -- nestly_v832 — a gift card sale is cash held for the customer, not revenue (frenly_v9), and
  -- gift cards are not live (owner ruling AO-1). It pays no commission.
  if new.item_type = 'gift_card' then
    new.commission_rate_bps := 0;
    new.commission_flat_cents := null;
    new.commission_cents := 0;
    new.commission_resolved_at := now();
    return new;
  end if;

  new.commission_rate_bps := app.sale_item_commission_bps_v825(
    new.business_id, new.item_type, new.ref_id, new.product_id, new.bundle_id, v_staff, v_sale.occurred_at);
  new.commission_flat_cents := app.sale_item_commission_flat_cents_v825(
    new.business_id, new.item_type, new.ref_id, new.product_id, new.bundle_id, v_staff, v_sale.occurred_at, new.line_cents);

  if new.bundle_id is not null then
    select b.price_cents, b.commission_flat_cents
      into v_bundle_price, v_bundle_flat
      from public.bundles b
     where b.id = new.bundle_id and b.business_id = new.business_id;
  end if;

  if v_bundle_flat is not null
     and app.staff_commission_eligible_v825(new.business_id, v_staff, v_sale.occurred_at) then
    select count(*), coalesce(sum(li.line_cents), 0), coalesce(sum(li.commission_cents), 0)
      into v_seen, v_seen_cents, v_seen_commission
      from public.sale_items li
     where li.sale_id = new.sale_id
       and li.business_id = new.business_id
       and li.bundle_id = new.bundle_id;
    select count(*) into v_members
      from (
        select bi.service_id
          from public.bundle_items bi
          join public.services s on s.id = bi.service_id and s.business_id = new.business_id
         where bi.bundle_id = new.bundle_id and s.active
        union all
        select bi.product_id
          from public.bundle_items bi
          join public.products pr on pr.id = bi.product_id and pr.business_id = new.business_id
         where bi.bundle_id = new.bundle_id and pr.active
      ) m;
    if coalesce(v_bundle_price, 0) <= 0 then
      new.commission_cents := case when v_seen = 0 then v_bundle_flat else 0 end;
    elsif v_seen + 1 >= v_members then
      v_bundles_sold := ((v_seen_cents + new.line_cents) / v_bundle_price)::integer;
      new.commission_cents := (v_bundle_flat::bigint * greatest(v_bundles_sold, 1) - v_seen_commission)::integer;
    else
      new.commission_cents := floor(v_bundle_flat::numeric * new.line_cents::numeric / v_bundle_price::numeric)::integer;
    end if;
    new.commission_flat_cents := new.commission_cents;
  elsif new.commission_flat_cents is not null then
    new.commission_cents := new.commission_flat_cents * new.qty;
  else
    new.commission_cents := floor(new.line_cents::numeric * new.commission_rate_bps::numeric / 10000)::integer;
  end if;

  new.commission_resolved_at := now();
  return new;
end
$function$
;

-- ------------------------------------------------------------------ §2 the reprice window
do $patch$
declare
  v_src text;
  v_new text;
  c_anchor constant text :=
    E'  raise exception ''sale_items is append-only: % is not permitted'', tg_op\n';
  c_window constant text := $w$  -- nestly_v832: a second, narrower window. It may change ONLY the four commission columns
  -- of ONLY a studio_discount line (every other column is compared as a whole row).
  if tg_op = 'UPDATE'
     and nullif(current_setting('app.sale_items_discount_reprice_v832', true), '') is not null then
    if old.item_type <> 'studio_discount' then
      raise exception 'sale_items discount reprice may only touch a studio_discount line (line %)', old.id
        using errcode = 'restrict_violation';
    end if;
    if (to_jsonb(new) - 'commission_rate_bps' - 'commission_flat_cents' - 'commission_cents' - 'commission_resolved_at')
       is distinct from
       (to_jsonb(old) - 'commission_rate_bps' - 'commission_flat_cents' - 'commission_cents' - 'commission_resolved_at') then
      raise exception 'sale_items discount reprice may not change any economic fact of line %', old.id
        using errcode = 'restrict_violation';
    end if;
    return new;
  end if;
$w$;
begin
  select pg_get_functiondef(p.oid) into v_src
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'app' and p.proname = 'sale_items_immutable_guard';
  if v_src is null then raise exception 'v832: app.sale_items_immutable_guard is missing'; end if;
  if position('app.sale_items_discount_reprice_v832' in v_src) > 0 then
    raise notice 'v832: the guard already carries the reprice window';
  else
    if (length(v_src) - length(replace(v_src, c_anchor, ''))) / length(c_anchor) <> 1 then
      raise exception 'v832: the append-only anchor in sale_items_immutable_guard is not unique';
    end if;
    v_new := replace(v_src, c_anchor, c_window || c_anchor);
    execute v_new;
  end if;
  select pg_get_functiondef(p.oid) into v_src
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'app' and p.proname = 'sale_items_immutable_guard';
  if position('app.sale_items_discount_reprice_v832' in v_src) = 0 then
    raise exception 'v832: the guard did not take the reprice window';
  end if;
end
$patch$;

-- ------------------------------------------------------------------ §3 re-price every discount line
select set_config('app.sale_items_discount_reprice_v832', 'nestly_v832', true);

update public.sale_items line
   set commission_rate_bps    = d.rate_bps,
       commission_flat_cents  = null,
       commission_cents       = d.commission_cents,
       commission_resolved_at = now()
  from (select li.id, r.rate_bps, r.commission_cents
          from public.sale_items li
         cross join lateral app.sale_item_discount_commission_v832(li.business_id, li.sale_id, li.line_cents) r
         where li.item_type = 'studio_discount') d
 where d.id = line.id
   and (line.commission_rate_bps is distinct from d.rate_bps
        or line.commission_cents is distinct from d.commission_cents
        or line.commission_flat_cents is not null);

select set_config('app.sale_items_discount_reprice_v832', '', true);

do $check$
declare v_bad int;
begin
  select count(*) into v_bad
    from public.sale_items line
    cross join lateral app.sale_item_discount_commission_v832(line.business_id, line.sale_id, line.line_cents) d
   where line.item_type = 'studio_discount'
     and (line.commission_cents is distinct from d.commission_cents or line.commission_rate_bps is distinct from d.rate_bps);
  if v_bad <> 0 then raise exception 'v832: % discount lines still disagree with the rule', v_bad; end if;
end
$check$;

-- ------------------------------------------------------------------ §4 the package pays who sold it
do $pkg$
declare
  v_src text;
  v_new text;
  c_head constant text := 'FUNCTION public.sell_package_v102(p_business uuid, p_client uuid, p_plan uuid, p_branch uuid, p_idempotency_key uuid)';
  c_head_new constant text := 'FUNCTION public.sell_package_v832(p_business uuid, p_client uuid, p_plan uuid, p_branch uuid, p_idempotency_key uuid, p_staff uuid)';
  c_client constant text := E'  if p_client is null or not exists(\n';
  c_staff constant text := $s$  -- nestly_v832: the member the till picked sells the package; null keeps the caller's own row.
  if p_staff is not null then
    if not exists (
      select 1 from public.staff chosen
       where chosen.id = p_staff and chosen.business_id = p_business and chosen.active
    ) then
      raise exception 'package_sale_staff_invalid' using errcode='22023';
    end if;
    v_staff := p_staff;
  end if;
$s$;
  c_payload constant text := E'    ''plan_id'',p_plan\n  );';
  c_payload_new constant text := E'    ''plan_id'',p_plan,\n    ''staff_id'',p_staff\n  );';
begin
  select pg_get_functiondef(p.oid) into v_src
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'sell_package_v102' and p.pronargs = 5;
  if v_src is null then raise exception 'v832: sell_package_v102/5 is missing'; end if;
  if position('sell_package_v832' in v_src) > 0 then
    raise exception 'v832: sell_package_v102 is already the wrapper; the source body is gone';
  end if;
  if (length(v_src) - length(replace(v_src, c_head, ''))) / length(c_head) <> 1
     or (length(v_src) - length(replace(v_src, c_client, ''))) / length(c_client) <> 1
     or (length(v_src) - length(replace(v_src, c_payload, ''))) / length(c_payload) <> 1 then
    raise exception 'v832: a sell_package_v102 anchor is not unique';
  end if;
  v_new := replace(v_src, c_head, c_head_new);
  v_new := replace(v_new, c_client, c_staff || c_client);
  v_new := replace(v_new, c_payload, c_payload_new);
  execute v_new;
end
$pkg$;

create or replace function public.sell_package_v102(p_business uuid, p_client uuid, p_plan uuid, p_branch uuid, p_idempotency_key uuid)
returns jsonb
language sql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $function$
  select public.sell_package_v832(p_business, p_client, p_plan, p_branch, p_idempotency_key, null);
$function$;

revoke all on function public.sell_package_v832(uuid, uuid, uuid, uuid, uuid, uuid) from public, anon;
grant execute on function public.sell_package_v832(uuid, uuid, uuid, uuid, uuid, uuid) to authenticated, service_role;
revoke all on function public.sell_package_v102(uuid, uuid, uuid, uuid, uuid) from public, anon;
grant execute on function public.sell_package_v102(uuid, uuid, uuid, uuid, uuid) to authenticated, service_role;

-- ------------------------------------------------------------------ §5 in-transaction proof
do $proof$
declare v_bps int; v_cents int;
begin
  -- AhXiang sale 64d75b53: services at 8% (Σ 83,406 on 1,042,600), a −104,260 discount → −8,340 at 8%
  select commission_rate_bps, commission_cents into v_bps, v_cents
    from public.sale_items where sale_id::text like '64d75b53%' and item_type = 'studio_discount';
  if found and (v_bps <> 800 or v_cents <> -8340) then
    raise exception 'v832: AhXiang discount line re-priced to % bps / % cents (expected 800 / -8340)', v_bps, v_cents;
  end if;
  if not exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                  where n.nspname = 'public' and p.proname = 'sell_package_v832' and p.pronargs = 6) then
    raise exception 'v832: sell_package_v832/6 was not created';
  end if;
end
$proof$;

commit;
