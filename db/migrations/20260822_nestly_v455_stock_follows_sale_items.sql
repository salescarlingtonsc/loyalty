-- nestly_v455 — a till bill with two different products stops walking stock out of the shop.
--
-- THE DEFECT (audit D, 2026-08-22, reproduced against production gadpooereceldfpfxsod):
-- app.on_sale_stock_deduct is an AFTER INSERT trigger on public.sales and it reads the sale
-- HEADER's product_id/qty. record_cart_sale only stamps that header when the cart holds exactly
-- one retail line (`v_retail_lines = 1`); with two or more distinct products it leaves both NULL,
-- the trigger returns on its first `if`, and NOTHING is deducted for ANY of them.
--
-- Measured on prod, tenant qa-kopi-lab 8ad4a375-2d42-4e0d-b509-b0e4ed6ccf8c:
--   stock 10 / 10  ->  one cart of 2 x Kopi Powder 500g + 3 x Kaya Jar 200g (sale
--                      0475b457-b04b-4563-b63c-e0fc9e5a0c9f, 4800c, header product_id NULL,
--                      qty NULL)  ->  stock STILL 10 / 10. Five units left the shelf; the
--                      Inventory module recorded none of it.
--   control: 2 x Kopi Powder + 1 service in one cart (sale 9096ef2e-…, header stamped)
--                      ->  10 -> 8, correct.
-- Both products sit in business_get_checkout_catalogue_v94, so this is one tap apart from the
-- path that works, and there is no warning anywhere in the till or in Inventory.
--
-- THE DELIBERATE-GAP NOTE THIS SUPERSEDES. db/migrations/20260723_frenly_v51_sale_line_items.sql:273
-- says, in full:
--   "Only a single-retail-line cart can carry the parent product_id/qty that v6 FEFO
--    (single-product-per-sale) can act on. Otherwise leave product_id NULL: no deduction,
--    identical to every other checkout surface today."
-- That was an honest scoping decision in July, when the header column was the only per-sale product
-- fact that existed. It is superseded because the premise no longer holds: v51 itself introduced
-- public.sale_items, which carries product_id and qty PER LINE, and record_cart_sale has populated
-- it for every cart ever since. The information FEFO needs has been sitting one table over for a
-- month. "Identical to every other checkout surface" also stopped being true the moment the till
-- became the surface merchants actually use.
--
-- THE FIX: a SECOND trigger, on public.sale_items, that runs the SAME FEFO loop per retail line.
-- app.on_sale_stock_deduct is NOT modified — its bytes, its ordering and its clamping are left
-- exactly as they are, so every path that works today keeps working through the code that already
-- serves it.
--
-- WHY THIS CANNOT DOUBLE-DEDUCT. The two triggers are mutually exclusive on one field:
--   * sales.product_id IS NOT NULL  =>  record_cart_sale found exactly one retail line and stamped
--                                       the header; app.on_sale_stock_deduct has already deducted
--                                       it, and the new trigger returns immediately.
--   * sales.product_id IS NULL      =>  the old trigger returned on its own first `if` and deducted
--                                       nothing; the new trigger owns every retail line.
-- Never both, never neither. Verified against all 56 production sales that carry sale_items:
--   header stamped                            4   (all 4 have exactly ONE retail line, and the
--                                                  header product_id and qty agree with that line
--                                                  in every case -- 0 disagreements)
--   header stamped but not exactly one retail 0
--   header NULL with retail lines             1   (the two-product repro above -- the defect)
--   reversal rows carrying sale_items         0
-- public.record_cart_sale is the ONLY function in public or app that writes sale_items, so the
-- blast radius of the new trigger is exactly the cart checkout path.
--
-- WHAT IS DELIBERATELY UNCHANGED. This is a stock change and nothing else. It does not touch what
-- counts as revenue, a visit or an earn: v10 sale-policy resolution, app.on_sale_recorded, the
-- points/stamp ledgers and the rewards and till lifecycles are not read or written here. Reversals
-- still restore no stock (they never did -- reversal rows carry no sale_items and carry
-- reversal_of, and the new trigger refuses both); selling a product that has no stock batch still
-- succeeds and still leaves the balance at 0 rather than going negative, because the FEFO loop
-- simply finds no batches; app.on_appointment_completed keeps deducting service components from
-- public.service_products on its own separate path.

begin;

create or replace function app.on_sale_item_stock_deduct_v455()
returns trigger
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $function$
declare
  v_sale public.sales%rowtype;
  bt record;
  v_need integer;
  v_take integer;
begin
  -- Only a retail line moves stock. Service, custom and studio_discount lines carry no product.
  if new.product_id is null or coalesce(new.item_type, '') <> 'retail' then
    return new;
  end if;

  v_need := coalesce(new.qty, 1);
  if v_need <= 0 then
    return new;
  end if;

  select * into v_sale from public.sales where id = new.sale_id;
  if not found then
    return new;
  end if;

  -- A reversal never restores stock. This mirrors app.on_sale_stock_deduct's own first guard.
  if v_sale.reversal_of is not null then
    return new;
  end if;

  -- EXCLUSIVITY WITH app.on_sale_stock_deduct. A stamped header means record_cart_sale found
  -- exactly one retail line and the sales trigger has already deducted it. Deducting again here
  -- would double-count that line.
  if v_sale.product_id is not null then
    return new;
  end if;

  -- The same FEFO order and the same clamping as app.on_sale_stock_deduct: soonest expiry first,
  -- then oldest receipt. A line larger than the stock on hand takes what exists and stops; no
  -- batch is ever driven negative and no sale is refused for want of stock.
  for bt in
    select id, qty
      from public.stock_batches
     where product_id = new.product_id
       and qty > 0
     order by expires_on nulls last, received_on, id
  loop
    exit when v_need <= 0;
    v_take := least(bt.qty, v_need);
    update public.stock_batches
       set qty = qty - v_take
     where id = bt.id;
    v_need := v_need - v_take;
  end loop;

  return new;
end
$function$;

revoke all on function app.on_sale_item_stock_deduct_v455() from public, anon, authenticated;

drop trigger if exists trg_sale_item_stock_deduct on public.sale_items;
create trigger trg_sale_item_stock_deduct
  after insert on public.sale_items
  for each row execute function app.on_sale_item_stock_deduct_v455();

commit;
