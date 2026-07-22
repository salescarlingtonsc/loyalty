-- FRENLY v51 — itemized checkout: public.sale_items + public.record_cart_sale.
-- Forward-only. Not applied to any remote database; verified only by the rolled-back
-- rehearsal chain + db/tests/v51_sale_line_items.sql before any RELEASE APPROVED.
--
-- WHAT THIS ADDS
--   * public.sale_items — an append-only child ledger of one parent sales row. RLS +
--     owner-read + super-admin-read, tenant-safe composite FKs, immutable (v34/v50 style).
--   * public.record_cart_sale — ONE RPC that turns a cart (jsonb line array) into ONE
--     parent sales row for the TOTAL plus its child sale_items rows, in one transaction.
--
-- HOW IT REUSES THE FINANCIAL ENGINE (does NOT reimplement it)
--   The parent sales row is created by delegating to public.record_quick_sale — the exact
--   internal path public.record_sale_by_phone (v47b) composes onto. That gives us, for free
--   and unchanged: the financial_operations reserve->complete idempotency ledger keyed
--   (business_id,'quick_sale',idempotency_key), the payments row, and the
--   app.on_sale_recorded points/retention/referral firing under the v10 per-kind policy.
--   The parent row is kind='quick_sale' and therefore behaves EXACTLY like today's Quick
--   Earn / till row for all of those semantics. record_cart_sale never touches
--   financial_operations, payments, points_ledger or credit_ledger directly.
--
-- FEFO (v6 single-product-per-sale) — the design-queue assumption corrected
--   The v6 stock-deduct trigger (app.on_sale_stock_deduct, recreated in v20) is
--   AFTER INSERT ON sales and keys off NEW.product_id; sales is append-only (the v10.1 /
--   v20 immutability guard forbids changing product_id/qty after insert); and
--   record_quick_sale's own INSERT does not set product_id. So product_id can only be
--   present at INSERT time, and there is no post-hoc UPDATE path. We therefore stamp it
--   during the parent insert with a strictly opt-in, GUC-gated BEFORE INSERT trigger
--   (app.cart_line_stock_stamp): record_cart_sale sets two transaction-local GUCs
--   immediately before delegating to record_quick_sale and clears them immediately after,
--   so exactly the one cart parent-sale insert is stamped and every other insert path is a
--   strict no-op. This reuses the EXISTING FEFO trigger unchanged (no logic duplication,
--   no drift) and is replay-safe: a replayed record_quick_sale inserts no new sales row, so
--   the stamp never fires twice and stock deducts exactly once, on the original checkout.
--   Because v6 FEFO is single-product-per-sale, we stamp ONLY when the cart contains
--   exactly one retail line; a multi-retail cart leaves product_id NULL and deducts nothing
--   — identical to today, where no write path ever sets sales.product_id. Per-line FEFO for
--   multi-retail carts needs a real per-line stock trigger and is deferred (design queue).

begin;

-- ---------------------------------------------------------------------------
-- 1. sale_items — append-only itemization of one parent sales row.
-- ---------------------------------------------------------------------------
create table public.sale_items (
  id uuid primary key default gen_random_uuid(),
  sale_id uuid not null,
  business_id uuid not null,
  item_type text not null
    check (item_type in ('service', 'retail', 'package', 'membership', 'gift_card', 'custom')),
  ref_id uuid,
  description text,
  qty integer not null check (qty > 0),
  unit_cents integer not null check (unit_cents >= 0),
  line_cents integer not null check (line_cents >= 0 and line_cents = qty * unit_cents),
  product_id uuid,
  staff_id uuid,
  created_at timestamptz not null default now(),
  constraint sale_items_sale_business_fk
    foreign key (sale_id, business_id)
    references public.sales(id, business_id) on delete restrict,
  constraint sale_items_product_business_fk
    foreign key (product_id, business_id)
    references public.products(id, business_id) on delete restrict,
  constraint sale_items_staff_business_fk
    foreign key (staff_id, business_id)
    references public.staff(id, business_id) on delete restrict
);
create index sale_items_sale_idx on public.sale_items(business_id, sale_id, created_at);

alter table public.sale_items enable row level security;
revoke all privileges on table public.sale_items from public, anon, authenticated;
grant select on public.sale_items to authenticated;
create policy sale_items_owner_read on public.sale_items
  for select to authenticated using (app.is_salon_owner(business_id));
create policy sale_items_sa_read on public.sale_items
  for select to authenticated using (app.is_super_admin());

create or replace function app.sale_items_immutable_guard()
returns trigger language plpgsql security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
begin
  raise exception 'sale_items is append-only: % is not permitted', tg_op
    using errcode = 'restrict_violation';
end $$;
revoke all privileges on function app.sale_items_immutable_guard()
  from public, anon, authenticated;
create trigger trg_sale_items_immutable
  before update or delete on public.sale_items
  for each row execute function app.sale_items_immutable_guard();

-- ---------------------------------------------------------------------------
-- 2. Opt-in FEFO stamp: stamp product_id/qty onto the ONE cart parent-sale insert.
--    Strictly a no-op unless record_cart_sale set the transaction-local GUCs.
-- ---------------------------------------------------------------------------
create or replace function app.cart_line_stock_stamp()
returns trigger language plpgsql security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_product text := nullif(current_setting('app.cart_line_product_id', true), '');
  v_qty text := nullif(current_setting('app.cart_line_qty', true), '');
begin
  if v_product is null then
    return new;
  end if;
  -- Never stamp a reversal row and never overwrite a product_id another path already set.
  if new.reversal_of is not null or new.product_id is not null then
    return new;
  end if;
  new.product_id := v_product::uuid;
  if v_qty is not null then
    new.qty := v_qty::integer;
  end if;
  return new;
end $$;
revoke all privileges on function app.cart_line_stock_stamp()
  from public, anon, authenticated;
drop trigger if exists trg_cart_line_stock_stamp on public.sales;
create trigger trg_cart_line_stock_stamp
  before insert on public.sales
  for each row execute function app.cart_line_stock_stamp();

-- ---------------------------------------------------------------------------
-- 3. record_cart_sale — validate, create ONE parent sale for the total via
--    record_quick_sale, then the child sale_items. Fully idempotent on replay.
-- ---------------------------------------------------------------------------
create or replace function public.record_cart_sale(
  p_business uuid,
  p_client uuid,
  p_branch uuid,
  p_staff uuid,
  p_method text,
  p_idempotency_key text,
  p_lines jsonb)
returns json
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_actor uuid := auth.uid();
  v_key text := nullif(btrim(p_idempotency_key), '');
  v_method text := lower(nullif(btrim(p_method), ''));
  v_types text[] := array['service', 'retail', 'package', 'membership', 'gift_card', 'custom'];
  v_line jsonb;
  v_type text;
  v_ref uuid;
  v_qn numeric;
  v_un numeric;
  v_qty integer;
  v_unit integer;
  v_line_staff uuid;
  v_count integer;
  v_total bigint := 0;
  v_retail_lines integer := 0;
  v_stamp_product uuid;
  v_stamp_qty integer;
  v_financial jsonb;
  v_sale_id uuid;
  v_replayed boolean;
  v_points integer := 0;
  v_items json;
begin
  if v_actor is null then
    raise exception 'authenticated staff required to record a cart sale' using errcode = '42501';
  end if;
  if not app.has_perm(p_business, 'create_sales') then
    raise exception 'you do not have permission to record a sale in this business (create_sales)'
      using errcode = '42501';
  end if;
  if v_key is null or length(v_key) < 8 then
    raise exception 'a cart-sale idempotency key of at least 8 characters is required'
      using errcode = '22023';
  end if;
  if v_method is null or v_method not in ('cash', 'card', 'paynow', 'other') then
    raise exception 'choose Cash, Card, PayNow or Other' using errcode = '22023';
  end if;
  if p_lines is null or jsonb_typeof(p_lines) <> 'array' then
    raise exception 'cart lines must be a JSON array' using errcode = '22023';
  end if;
  v_count := jsonb_array_length(p_lines);
  if v_count < 1 or v_count > 50 then
    raise exception 'a cart must have between 1 and 50 lines' using errcode = '22023';
  end if;
  if p_client is not null and not exists (
    select 1 from public.clients c where c.id = p_client and c.business_id = p_business
  ) then
    raise exception 'cart-sale client does not belong to this business' using errcode = '22023';
  end if;

  -- Validate every line before creating anything.
  for v_line in select * from jsonb_array_elements(p_lines) loop
    v_type := v_line->>'item_type';
    if v_type is null or not (v_type = any (v_types)) then
      raise exception 'unsupported cart line item_type %', coalesce(v_type, '(null)')
        using errcode = '22023';
    end if;
    if jsonb_typeof(v_line->'qty') is distinct from 'number'
       or jsonb_typeof(v_line->'unit_cents') is distinct from 'number' then
      raise exception 'each cart line requires numeric qty and unit_cents' using errcode = '22023';
    end if;
    v_qn := (v_line->>'qty')::numeric;
    v_un := (v_line->>'unit_cents')::numeric;
    if v_qn <> trunc(v_qn) or v_qn <= 0 or v_qn > 1000000 then
      raise exception 'cart line qty must be a whole number between 1 and 1000000'
        using errcode = '22023';
    end if;
    if v_un <> trunc(v_un) or v_un < 0 or v_un > 100000000 then
      raise exception 'cart line unit_cents must be a whole number between 0 and 100000000'
        using errcode = '22023';
    end if;
    v_qty := v_qn::integer;
    v_unit := v_un::integer;
    v_ref := nullif(v_line->>'ref_id', '')::uuid;
    v_line_staff := nullif(v_line->>'staff_id', '')::uuid;

    if v_type = 'service' then
      if v_ref is null or not exists (
        select 1 from public.services s where s.id = v_ref and s.business_id = p_business
      ) then
        raise exception 'service line references a service outside this business'
          using errcode = '22023';
      end if;
    elsif v_type = 'retail' then
      if v_ref is null or not exists (
        select 1 from public.products p where p.id = v_ref and p.business_id = p_business
      ) then
        raise exception 'retail line references a product outside this business'
          using errcode = '22023';
      end if;
      v_retail_lines := v_retail_lines + 1;
      v_stamp_product := v_ref;
      v_stamp_qty := v_qty;
    elsif v_type = 'package' then
      if v_ref is null or not exists (
        select 1 from public.package_plans pp where pp.id = v_ref and pp.business_id = p_business
      ) then
        raise exception 'package line references a plan outside this business'
          using errcode = '22023';
      end if;
    elsif v_type = 'membership' then
      if v_ref is null or not exists (
        select 1 from public.membership_plans mp where mp.id = v_ref and mp.business_id = p_business
      ) then
        raise exception 'membership line references a plan outside this business'
          using errcode = '22023';
      end if;
    else
      -- gift_card / custom carry no typed reference.
      if v_ref is not null then
        raise exception 'a % line must not carry a ref_id', v_type using errcode = '22023';
      end if;
    end if;

    if v_line_staff is not null and not exists (
      select 1 from public.staff s
       where s.id = v_line_staff and s.business_id = p_business and s.active
    ) then
      raise exception 'cart line staff is inactive or outside this business' using errcode = '22023';
    end if;

    v_total := v_total + (v_qty::bigint * v_unit::bigint);
  end loop;

  if v_total <= 0 then
    raise exception 'a cart sale must total more than zero' using errcode = '22023';
  end if;
  if v_total > 2147483647 then
    raise exception 'cart total exceeds the supported maximum' using errcode = '22023';
  end if;

  -- Only a single-retail-line cart can carry the parent product_id/qty that v6 FEFO
  -- (single-product-per-sale) can act on. Otherwise leave product_id NULL: no deduction,
  -- identical to every other checkout surface today.
  if v_retail_lines <> 1 then
    v_stamp_product := null;
    v_stamp_qty := null;
  end if;

  perform set_config('app.cart_line_product_id', coalesce(v_stamp_product::text, ''), true);
  perform set_config('app.cart_line_qty', coalesce(v_stamp_qty::text, ''), true);
  v_financial := public.record_quick_sale(
    p_business => p_business,
    p_amount_cents => v_total::integer,
    p_method => v_method,
    p_client => p_client,
    p_staff => p_staff,
    p_branch => p_branch,
    p_note => 'cart checkout',
    p_idempotency_key => v_key,
    p_paid => true
  )::jsonb;
  perform set_config('app.cart_line_product_id', '', true);
  perform set_config('app.cart_line_qty', '', true);

  v_sale_id := nullif(v_financial #>> '{sale,id}', '')::uuid;
  v_replayed := coalesce((v_financial->>'replayed')::boolean, false);
  if v_sale_id is null then
    raise exception 'cart sale did not produce a parent sale row' using errcode = 'XX001';
  end if;

  -- First run inserts the child lines; a replay already committed them, so skip to avoid
  -- duplicates. sale_id committed <=> its items committed (one transaction), so this holds.
  if not v_replayed then
    insert into public.sale_items(
      sale_id, business_id, item_type, ref_id, description,
      qty, unit_cents, line_cents, product_id, staff_id)
    select v_sale_id,
           p_business,
           e->>'item_type',
           nullif(e->>'ref_id', '')::uuid,
           nullif(e->>'description', ''),
           (e->>'qty')::integer,
           (e->>'unit_cents')::integer,
           (e->>'qty')::integer * (e->>'unit_cents')::integer,
           case when e->>'item_type' = 'retail' then nullif(e->>'ref_id', '')::uuid end,
           nullif(e->>'staff_id', '')::uuid
      from jsonb_array_elements(p_lines) as e;
  end if;

  if p_client is not null then
    select coalesce(sum(pl.points), 0) into v_points
      from public.points_ledger pl
     where pl.business_id = p_business
       and pl.client_id = p_client
       and pl.sale_id = v_sale_id
       and pl.entry_type = 'earn';
  end if;

  select coalesce(json_agg(row_to_json(si) order by si.created_at, si.id), '[]'::json)
    into v_items
    from public.sale_items si
   where si.business_id = p_business and si.sale_id = v_sale_id;

  return json_build_object(
    'status', case when v_replayed then 'duplicate_ignored' else 'ok' end,
    'sale_id', v_sale_id,
    'business_id', p_business,
    'total_cents', v_total,
    'item_count', v_count,
    'replayed', v_replayed,
    'points_earned', case when v_replayed then 0 else v_points end,
    'sale', v_financial->'sale',
    'items', v_items
  );
end $$;

revoke all privileges on function public.record_cart_sale(uuid, uuid, uuid, uuid, text, text, jsonb)
  from public, anon, authenticated;
grant execute on function public.record_cart_sale(uuid, uuid, uuid, uuid, text, text, jsonb)
  to authenticated;

commit;
