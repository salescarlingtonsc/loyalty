-- nestly_v827 — commission can be set on a product, a bundle and a package, and the team's
--               commission is readable line by line.
--
-- NUMBERING. Written, proved and APPLIED to production as nestly_v825 on 2026-09-08; a parallel
-- session merged its own nestly_v825 (security hygiene sweep, deploy slot 20261007170000) to
-- origin/main first, so this migration yields the label and is registered as nestly_v827 at deploy
-- slot 20261008010000. The DATABASE OBJECTS KEEP THEIR _v825 SUFFIX (app.*_v825, the two public
-- RPCs, trg_sale_items_commission_v825, the *_range_v825 constraints) because they were already
-- live; renaming applied objects for a label is production churn for nothing. Grep either number
-- and you find the other. Same resolution nestly_v818 took for its _v811 objects.
--
-- OWNER REQUEST (2026-09-08, three screenshots: Services/Bundles "Edit bundle", Products,
-- Packages): "ensure that commissions allocation is allowed for bundle / package / products",
-- and "i need a new module to track staff commission ... list down all products/services sold
-- and which customer bought it with its timestamp (if it reversed sales, please remove it and
-- indicate it as reversed). ensure no overlapping of commission for staffs. one commission for
-- 1 staff."
--
-- WHAT EXISTED. nestly_v818 made commission PER LINE: every sale_items row carries an
-- immutable commission snapshot written by a BEFORE INSERT trigger, resolved from
-- services.commission_bps / commission_flat_cents for a service line and from the staff
-- member's product rate for everything else. So a product, a bundle and a package could not
-- carry a rate of their own — a product line always took the member's blanket product %, a
-- package purchase took the same, and a bundle (which v204 expands into one line per member
-- at checkout) paid whatever each member service happened to pay.
--
-- OWNER RULINGS (2026-09-08, asked before any schema was written):
--   1. Packages pay ONCE, at purchase, to the seller. A session use ($0 visit) pays nothing.
--   2. A bundle-level commission OVERRIDES every member line sold through that bundle; blank
--      falls back to the members' own rates, which is exactly what v818 pays today.
--   3. Rate type mirrors services: a percentage OR a fixed amount; the fixed amount wins when
--      both are set (v13's rule, unchanged). Blank means the member's default.
--   4. The new module lives under Reports and RETIRES the old Staff performance ranking page
--      into it, so there is one commission authority. (That part is app/app.js — the route key
--      `staffperf` is kept because every business is already entitled to it.)
--
-- WHAT THIS MIGRATION DOES.
--   §1  products / bundles / package_plans gain commission_bps + commission_flat_cents, the
--       same shape and the same blank-vs-zero meaning services have carried since v11a/v13.
--   §2  sale_items gains bundle_id. evaluate_checkout has stamped `bundle_id` onto every
--       bundle member line in checkout_evaluations.server_lines since v257; the finaliser
--       simply never copied it into the row. record_cart_sale/11 is patched in place (anchored
--       replacement on the live body, asserted to occur exactly once) to write it. Without it
--       the bundle override has nothing to key on. sell_package_v102 is patched the same way
--       to write ref_id = the plan — its `package` line had no reference at all, so a package
--       override could never be found either.
--   §3  ONE eligibility helper (app.staff_commission_eligible_v825) — "is this member paid
--       commission at this instant" — and two resolvers that take the line's product and
--       bundle as well as its ref. Resolution order per line, top wins:
--         no staff / before commission_starts_on ............ 0
--         package_session ................................... 0   (ruling 1)
--         bundle override (bps or flat on the bundle) ....... bundle's   (ruling 2)
--         service line ...................................... service override, else member service %
--         retail line ....................................... product override, else member product %
--         package line ...................................... package override, else member product %
--         anything else (custom, membership, gift card…) .... member product %   (v818, unchanged)
--       The v811 resolvers become thin wrappers over the v825 ones (null product, null bundle)
--       so nothing that still names them — the v818 proof suite — can disagree with the
--       trigger. One authority.
--   §4  A BUNDLE FIXED AMOUNT is paid once per bundle sold, not once per member line. The
--       trigger allocates it across the member lines in proportion to their share of the bundle
--       price (which v204 already made proportional to list price) and the LAST member line
--       absorbs the rounding remainder, so the lines always sum to exactly
--       flat × bundles-sold. "Last" is known because every member line of one bundle is
--       written in one statement, so the trigger can count its already-written siblings.
--   §5  app.sale_items_immutable_guard learns the new column (bundle_id is an economic fact).
--   §6  public.business_set_catalogue_commission_v825 — the one writer for the three new
--       pairs. bundles and package_plans have no UPDATE policy at all (every write goes through
--       a SECURITY DEFINER RPC), and products' is module-gated; one RPC, gated on the SAME
--       module-write capability each editor already requires, keeps blank/zero/range rules in
--       one place. services keep their existing direct write (services_update_v572).
--   §7  public.business_staff_commission_lines_v825 — the report reader. One row per sale
--       line in the window (or one synthetic row for a sale that has no lines — reversal rows
--       and pre-v818 quick sales), with the customer, the staff member the line pays, the
--       frozen rate and the commission. A sale that has been reversed is returned FLAGGED
--       (reversed, reversed_at, reversal_reason) rather than dropped, so the page can show it
--       struck through and leave it out of every total — "remove it and indicate it as
--       reversed". The reversal row itself is never returned: it is the compensating entry,
--       not a sale. Gated on view_finance + can_see_branch, exactly like public.sale_commission.
--       "One commission for one staff" is structural: a line pays coalesce(line.staff_id,
--       sale.staff_id) and nothing else; a line can never appear under two people.
--   §8  delete_service_bundle_v285 refuses to hard-delete a bundle that has been sold, with a
--       sentence instead of the raw 23503 the new FK would otherwise surface. Switch it off
--       instead — the same rule products and services already live under.
--
-- NOT CHANGED, deliberately: no backfill of rates onto past lines (the owner's own copy says
-- "saving applies to packages sold from now on"), no backfill of bundle_id onto past bundle
-- lines (the row does not know which bundle it came from; the commission on those lines is
-- already frozen), and public.sale_commission is untouched — it already sums the lines.
--
-- ACLs, restated verbatim from the live proacl (nestly_v818/v822 discipline):
--   record_cart_sale/11, sell_package_v102, delete_service_bundle_v285:
--     {postgres, service_role, authenticated}; PUBLIC and anon hold nothing.
--   app.sale_item_commission_*_v811: {postgres, service_role} — no browser grant.
--   The new app helpers get NO browser grant either (they run inside SECURITY DEFINER
--   callers; the v720 grants fixture scans for exactly that).

begin;

-- ------------------------------------------------------------------ §1 the three new pairs

alter table public.products
  add column if not exists commission_bps integer,
  add column if not exists commission_flat_cents integer;
alter table public.products
  drop constraint if exists products_commission_bps_range_v825,
  add constraint products_commission_bps_range_v825
    check (commission_bps is null or commission_bps between 0 and 10000),
  drop constraint if exists products_commission_flat_cents_range_v825,
  add constraint products_commission_flat_cents_range_v825
    check (commission_flat_cents is null or commission_flat_cents >= 0);
comment on column public.products.commission_bps is
  'nestly_v825 CONFIG: overrides each staff member''s product % for THIS product. NULL = inherit; 0 = a real "no commission on this product".';
comment on column public.products.commission_flat_cents is
  'nestly_v825 CONFIG: fixed commission in cents per unit of THIS product, outranking the percentage when set. NULL = none.';

alter table public.bundles
  add column if not exists commission_bps integer,
  add column if not exists commission_flat_cents integer;
alter table public.bundles
  drop constraint if exists bundles_commission_bps_range_v825,
  add constraint bundles_commission_bps_range_v825
    check (commission_bps is null or commission_bps between 0 and 10000),
  drop constraint if exists bundles_commission_flat_cents_range_v825,
  add constraint bundles_commission_flat_cents_range_v825
    check (commission_flat_cents is null or commission_flat_cents >= 0);
comment on column public.bundles.commission_bps is
  'nestly_v825 CONFIG: when set, every member line sold through this bundle pays this % instead of its own rate (owner ruling 2026-09-08). NULL = members'' own rates.';
comment on column public.bundles.commission_flat_cents is
  'nestly_v825 CONFIG: fixed commission in cents per BUNDLE sold, allocated across its member lines by the sale_items trigger; outranks the percentage when set. NULL = none.';

alter table public.package_plans
  add column if not exists commission_bps integer,
  add column if not exists commission_flat_cents integer;
alter table public.package_plans
  drop constraint if exists package_plans_commission_bps_range_v825,
  add constraint package_plans_commission_bps_range_v825
    check (commission_bps is null or commission_bps between 0 and 10000),
  drop constraint if exists package_plans_commission_flat_cents_range_v825,
  add constraint package_plans_commission_flat_cents_range_v825
    check (commission_flat_cents is null or commission_flat_cents >= 0);
comment on column public.package_plans.commission_bps is
  'nestly_v825 CONFIG: overrides the seller''s product % on the PURCHASE of this package. Paid once, at sale; session uses pay nothing (owner ruling 2026-09-08). NULL = inherit.';
comment on column public.package_plans.commission_flat_cents is
  'nestly_v825 CONFIG: fixed commission in cents per package sold, outranking the percentage when set. NULL = none.';

-- ------------------------------------------------------------------ §2 the line knows its bundle

do $ddl$
begin
  if not exists (select 1 from pg_constraint where conname = 'bundles_id_business_uk') then
    alter table public.bundles add constraint bundles_id_business_uk unique (id, business_id);
  end if;
end
$ddl$;

alter table public.sale_items add column if not exists bundle_id uuid;

do $ddl$
begin
  if not exists (select 1 from pg_constraint where conname = 'sale_items_bundle_business_fk') then
    alter table public.sale_items
      add constraint sale_items_bundle_business_fk
      foreign key (bundle_id, business_id)
      references public.bundles(id, business_id) on delete restrict;
  end if;
end
$ddl$;

create index if not exists sale_items_bundle_idx
  on public.sale_items (business_id, sale_id, bundle_id)
  where bundle_id is not null;

comment on column public.sale_items.bundle_id is
  'nestly_v825: the bundle this member line was sold through (v204 expands a bundle into one line per member). NULL for every line that was not part of a bundle, and for bundle lines written before v825.';

-- record_cart_sale/11: copy server_lines.bundle_id (stamped by evaluate_checkout since v257)
-- into the row. Anchored replacement on the live body; each anchor must occur exactly once.
do $patch$
declare
  v_src text;
  v_new text;
  v_hits int;
  c_cols_old constant text :=
    'insert into public.sale_items(sale_id, business_id, item_type, ref_id, description, qty, unit_cents, line_cents, product_id)' || E'\n' ||
    '  select v_sale_id, p_business,' || E'\n';
  c_cols_new constant text :=
    'insert into public.sale_items(sale_id, business_id, item_type, ref_id, description, qty, unit_cents, line_cents, product_id, bundle_id)' || E'\n' ||
    '  select v_sale_id, p_business,' || E'\n';
  c_vals_old constant text :=
    '         case when e->>''catalog_kind'' = ''product'' then nullif(e->>''catalog_id'', '''')::uuid end' || E'\n' ||
    '    from jsonb_array_elements(v_eval.server_lines) e;' || E'\n';
  c_vals_new constant text :=
    '         case when e->>''catalog_kind'' = ''product'' then nullif(e->>''catalog_id'', '''')::uuid end,' || E'\n' ||
    '         nullif(e->>''bundle_id'', '''')::uuid' || E'\n' ||
    '    from jsonb_array_elements(v_eval.server_lines) e;' || E'\n';
begin
  select pg_get_functiondef(p.oid) into v_src
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'record_cart_sale' and p.pronargs = 11;
  if v_src is null then
    raise exception 'v825: record_cart_sale/11 not found';
  end if;
  if position('nullif(e->>''bundle_id'', '''')::uuid' in v_src) > 0 then
    raise notice 'v825: record_cart_sale/11 already writes sale_items.bundle_id — nothing to patch';
  else
    v_hits := (length(v_src) - length(replace(v_src, c_cols_old, ''))) / length(c_cols_old);
    if v_hits <> 1 then
      raise exception 'v825: the sale_items column-list anchor occurs % times in record_cart_sale/11, expected exactly 1', v_hits;
    end if;
    v_hits := (length(v_src) - length(replace(v_src, c_vals_old, ''))) / length(c_vals_old);
    if v_hits <> 1 then
      raise exception 'v825: the sale_items value-list anchor occurs % times in record_cart_sale/11, expected exactly 1', v_hits;
    end if;
    v_new := replace(replace(v_src, c_cols_old, c_cols_new), c_vals_old, c_vals_new);
    execute v_new;
  end if;

  select pg_get_functiondef(p.oid) into v_src
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'record_cart_sale' and p.pronargs = 11;
  if position('nullif(e->>''bundle_id'', '''')::uuid' in v_src) = 0 then
    raise exception 'v825: record_cart_sale/11 did not take the bundle_id column';
  end if;
end
$patch$;

-- sell_package_v102: the package line references its plan, so a package override can be found.
do $patch$
declare
  v_src text;
  v_new text;
  v_hits int;
  c_old constant text :=
    '  insert into public.sale_items(sale_id, business_id, item_type, description, qty, unit_cents, line_cents, staff_id)' || E'\n' ||
    '  values (v_sale_id, p_business, ''package'', v_plan.name, 1, v_plan.price_cents, v_plan.price_cents, v_staff);' || E'\n';
  c_new constant text :=
    '  insert into public.sale_items(sale_id, business_id, item_type, description, qty, unit_cents, line_cents, staff_id, ref_id)' || E'\n' ||
    '  values (v_sale_id, p_business, ''package'', v_plan.name, 1, v_plan.price_cents, v_plan.price_cents, v_staff, v_plan.id);' || E'\n';
begin
  select pg_get_functiondef(p.oid) into v_src
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'sell_package_v102';
  if v_src is null then
    raise exception 'v825: sell_package_v102 not found';
  end if;
  if position(c_new in v_src) > 0 then
    raise notice 'v825: sell_package_v102 already references the plan on its line — nothing to patch';
  else
    v_hits := (length(v_src) - length(replace(v_src, c_old, ''))) / length(c_old);
    if v_hits <> 1 then
      raise exception 'v825: the package line anchor occurs % times in sell_package_v102, expected exactly 1', v_hits;
    end if;
    v_new := replace(v_src, c_old, c_new);
    execute v_new;
  end if;

  select pg_get_functiondef(p.oid) into v_src
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'sell_package_v102';
  if position(c_new in v_src) = 0 then
    raise exception 'v825: sell_package_v102 did not take ref_id on its package line';
  end if;
end
$patch$;

-- ------------------------------------------------------------------ §3 one eligibility, two resolvers

-- "Is this member paid commission at this instant." False for an unknown member and for a
-- sale dated before commission_starts_on (Singapore day), exactly as v12 decided it.
create or replace function app.staff_commission_eligible_v825(
  p_business uuid,
  p_staff uuid,
  p_occurred_at timestamptz
) returns boolean
language sql
stable
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $function$
  select exists (
    select 1
      from public.staff st
     where st.id = p_staff
       and st.business_id = p_business
       and (st.commission_starts_on is null
            or (p_occurred_at at time zone 'Asia/Singapore')::date >= st.commission_starts_on)
  )
$function$;

create or replace function app.sale_item_commission_bps_v825(
  p_business uuid,
  p_item_type text,
  p_ref_id uuid,
  p_product_id uuid,
  p_bundle_id uuid,
  p_staff uuid,
  p_occurred_at timestamptz
) returns integer
language sql
stable
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $function$
  select case
           when not app.staff_commission_eligible_v825(p_business, p_staff, p_occurred_at) then 0
           -- Owner ruling 2026-09-08: a package pays once, at purchase. A session use is a $0
           -- visit and pays nothing whatever the member's rate.
           when p_item_type = 'package_session' then 0
           -- Owner ruling 2026-09-08: the bundle's own % beats every member's rate.
           when bnd.commission_bps is not null then bnd.commission_bps
           else coalesce(
                  case
                    -- coalesce, NOT coalesce+nullif: a 0% override is a real setting (v12).
                    when p_item_type = 'service' then coalesce(svc.commission_bps, st.commission_service_bps)
                    when p_item_type = 'retail'  then coalesce(prd.commission_bps, st.commission_product_bps)
                    when p_item_type = 'package' then coalesce(pkg.commission_bps, st.commission_product_bps)
                    else st.commission_product_bps
                  end, 0)
         end
    from (select 1) _
    left join public.staff st
      on st.id = p_staff and st.business_id = p_business
    left join public.services svc
      on p_item_type = 'service' and svc.id = p_ref_id and svc.business_id = p_business
    left join public.products prd
      on p_item_type = 'retail' and prd.id = coalesce(p_product_id, p_ref_id) and prd.business_id = p_business
    left join public.package_plans pkg
      on p_item_type = 'package' and pkg.id = p_ref_id and pkg.business_id = p_business
    left join public.bundles bnd
      on p_bundle_id is not null and bnd.id = p_bundle_id and bnd.business_id = p_business
$function$;

-- The per-ITEM fixed amount (per unit, × qty by the trigger). A bundle that carries any
-- override of its own silences the members' fixed amounts; the bundle's own fixed amount is
-- allocated by the trigger (§4), not here, because it is per bundle, not per line.
create or replace function app.sale_item_commission_flat_cents_v825(
  p_business uuid,
  p_item_type text,
  p_ref_id uuid,
  p_product_id uuid,
  p_bundle_id uuid,
  p_staff uuid,
  p_occurred_at timestamptz,
  p_line_cents integer
) returns integer
language sql
stable
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $function$
  select case
           when not app.staff_commission_eligible_v825(p_business, p_staff, p_occurred_at) then null
           when coalesce(p_line_cents, 0) <= 0 then null
           when p_item_type = 'package_session' then null
           when bnd.id is not null
                and (bnd.commission_bps is not null or bnd.commission_flat_cents is not null) then null
           when p_item_type = 'service' then svc.commission_flat_cents
           when p_item_type = 'retail'  then prd.commission_flat_cents
           when p_item_type = 'package' then pkg.commission_flat_cents
           else null
         end
    from (select 1) _
    left join public.services svc
      on p_item_type = 'service' and svc.id = p_ref_id and svc.business_id = p_business
    left join public.products prd
      on p_item_type = 'retail' and prd.id = coalesce(p_product_id, p_ref_id) and prd.business_id = p_business
    left join public.package_plans pkg
      on p_item_type = 'package' and pkg.id = p_ref_id and pkg.business_id = p_business
    left join public.bundles bnd
      on p_bundle_id is not null and bnd.id = p_bundle_id and bnd.business_id = p_business
$function$;

-- The v811 names stay callable (the v818 proof suite names them) but resolve through v825
-- with no product and no bundle, so the two can never disagree.
create or replace function app.sale_item_commission_bps_v811(
  p_business uuid,
  p_item_type text,
  p_ref_id uuid,
  p_staff uuid,
  p_occurred_at timestamptz
) returns integer
language sql
stable
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $function$
  select app.sale_item_commission_bps_v825(p_business, p_item_type, p_ref_id, null, null, p_staff, p_occurred_at)
$function$;

create or replace function app.sale_item_commission_flat_cents_v811(
  p_business uuid,
  p_item_type text,
  p_ref_id uuid,
  p_staff uuid,
  p_occurred_at timestamptz,
  p_line_cents integer
) returns integer
language sql
stable
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $function$
  select app.sale_item_commission_flat_cents_v825(p_business, p_item_type, p_ref_id, null, null, p_staff, p_occurred_at, p_line_cents)
$function$;

-- ------------------------------------------------------------------ §4 the trigger, with bundle allocation

create or replace function app.on_sale_item_commission_snapshot_v825()
returns trigger
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $function$
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
    -- A fixed amount per BUNDLE sold, spread over its member lines in proportion to their share
    -- of the bundle price; the last member line takes the rounding remainder so the lines sum
    -- to exactly flat × bundles-sold. The siblings already written for this sale+bundle are
    -- visible to this row's trigger because one statement writes them all.
    select count(*), coalesce(sum(li.line_cents), 0), coalesce(sum(li.commission_cents), 0)
      into v_seen, v_seen_cents, v_seen_commission
      from public.sale_items li
     where li.sale_id = new.sale_id
       and li.business_id = new.business_id
       and li.bundle_id = new.bundle_id;
    -- Same membership predicate app.ps1c_bundle_lines_v204 expanded the bundle with.
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
    -- A bundle member line is always qty 1 (v204), so the per-line amount is the per-unit amount.
    new.commission_flat_cents := new.commission_cents;
  elsif new.commission_flat_cents is not null then
    new.commission_cents := new.commission_flat_cents * new.qty;
  else
    new.commission_cents := floor(new.line_cents::numeric * new.commission_rate_bps::numeric / 10000)::integer;
  end if;

  new.commission_resolved_at := now();
  return new;
end
$function$;

drop trigger if exists trg_sale_items_commission_v811 on public.sale_items;
drop trigger if exists trg_sale_items_commission_v825 on public.sale_items;
create trigger trg_sale_items_commission_v825
  before insert on public.sale_items
  for each row execute function app.on_sale_item_commission_snapshot_v825();

drop function if exists app.on_sale_item_commission_snapshot_v811();

-- ------------------------------------------------------------------ §5 the guard learns bundle_id

create or replace function app.sale_items_immutable_guard()
returns trigger
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $function$
declare
  v_window text;
begin
  if tg_op = 'UPDATE' then
    v_window := nullif(current_setting('app.sale_items_commission_backfill', true), '');
    if v_window is not null then
      if old.commission_rate_bps is not null
         or old.commission_flat_cents is not null
         or old.commission_cents is not null
         or old.commission_resolved_at is not null then
        raise exception
          'sale_items commission backfill "%" may only fill a line that has no snapshot yet (line %)',
          v_window, old.id
          using errcode = 'restrict_violation';
      end if;
      if (new.id, new.sale_id, new.business_id, new.item_type, new.ref_id, new.description,
          new.qty, new.unit_cents, new.line_cents, new.product_id, new.staff_id,
          new.created_at, new.canonical_node_key, new.taxonomy_version_no, new.bundle_id)
         is distinct from
         (old.id, old.sale_id, old.business_id, old.item_type, old.ref_id, old.description,
          old.qty, old.unit_cents, old.line_cents, old.product_id, old.staff_id,
          old.created_at, old.canonical_node_key, old.taxonomy_version_no, old.bundle_id)
      then
        raise exception
          'sale_items commission backfill "%" may not change any economic fact of line %',
          v_window, old.id
          using errcode = 'restrict_violation';
      end if;
      return new;
    end if;
  end if;
  raise exception 'sale_items is append-only: % is not permitted', tg_op
    using errcode = 'restrict_violation';
end
$function$;

-- ------------------------------------------------------------------ §6 the one writer

create or replace function public.business_set_catalogue_commission_v825(
  p_business uuid,
  p_kind text,
  p_id uuid,
  p_commission_bps integer,
  p_commission_flat_cents integer
) returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $function$
declare
  v_actor uuid := auth.uid();
  v_module text;
  v_table text;
  v_rows integer := 0;
begin
  if v_actor is null then
    raise exception 'sign in to change commission' using errcode = '42501';
  end if;
  v_module := case p_kind
                when 'product' then 'inventory'
                when 'bundle'  then 'services'
                when 'package' then 'packages'
              end;
  v_table := case p_kind
               when 'product' then 'products'
               when 'bundle'  then 'bundles'
               when 'package' then 'package_plans'
             end;
  if v_module is null or p_business is null or p_id is null then
    raise exception 'commission_kind_invalid' using errcode = '22023';
  end if;
  if not (app.is_super_admin() or app.can_module_write(p_business, v_module)) then
    raise exception 'you do not have permission to change commission here (%)', v_module
      using errcode = '42501';
  end if;
  if p_commission_bps is not null and p_commission_bps not between 0 and 10000 then
    raise exception 'commission_bps_invalid' using errcode = '22023';
  end if;
  if p_commission_flat_cents is not null and p_commission_flat_cents < 0 then
    raise exception 'commission_flat_cents_invalid' using errcode = '22023';
  end if;

  if p_kind = 'product' then
    update public.products
       set commission_bps = p_commission_bps, commission_flat_cents = p_commission_flat_cents
     where id = p_id and business_id = p_business;
  elsif p_kind = 'bundle' then
    update public.bundles
       set commission_bps = p_commission_bps, commission_flat_cents = p_commission_flat_cents
     where id = p_id and business_id = p_business;
  else
    update public.package_plans
       set commission_bps = p_commission_bps, commission_flat_cents = p_commission_flat_cents
     where id = p_id and business_id = p_business;
  end if;
  get diagnostics v_rows = row_count;
  if v_rows <> 1 then
    raise exception 'commission_target_not_found' using errcode = '22023';
  end if;

  insert into public.audit_log(business_id, actor, action, entity, entity_id, detail)
  values (p_business, v_actor, 'CATALOGUE_COMMISSION_SET_V825', v_table, p_id,
          jsonb_build_object('kind', p_kind,
                             'commission_bps', p_commission_bps,
                             'commission_flat_cents', p_commission_flat_cents));

  return jsonb_build_object('status', 'ok', 'kind', p_kind, 'id', p_id,
                            'commission_bps', p_commission_bps,
                            'commission_flat_cents', p_commission_flat_cents);
end
$function$;

-- ------------------------------------------------------------------ §7 the report reader

create or replace function public.business_staff_commission_lines_v825(
  p_business uuid,
  p_branch uuid,
  p_from timestamptz,
  p_to timestamptz
) returns table (
  sale_id uuid,
  line_id uuid,
  occurred_at timestamptz,
  branch_id uuid,
  sale_kind text,
  client_id uuid,
  client_name text,
  staff_id uuid,
  staff_name text,
  item_type text,
  description text,
  qty integer,
  line_cents integer,
  rate_bps integer,
  flat_cents integer,
  commission_cents integer,
  bundle_id uuid,
  reversed boolean,
  reversed_at timestamptz,
  reversal_reason text
)
language plpgsql
stable
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $function$
begin
  if auth.uid() is null then
    raise exception 'sign in to read staff commission' using errcode = '42501';
  end if;
  if p_business is null or not app.has_perm(p_business, 'view_finance') then
    raise exception 'you do not have permission to read staff commission here (view_finance)'
      using errcode = '42501';
  end if;
  if p_from is null or p_to is null or p_to <= p_from then
    raise exception 'staff commission needs a window with p_from before p_to' using errcode = '22023';
  end if;

  return query
  with visible as (
    select s.id, s.occurred_at, s.branch_id, s.kind, s.client_id, s.staff_id, s.amount_cents,
           s.commission_rate_bps, s.commission_flat_cents, s.note
      from public.sales s
     where s.business_id = p_business
       and s.reversal_of is null
       and s.occurred_at >= p_from
       and s.occurred_at <  p_to
       and (p_branch is null or s.branch_id = p_branch)
       and app.can_see_branch(p_business, s.branch_id)
  ),
  reversal as (
    select r.reversal_of as sale_id,
           min(r.occurred_at) as reversed_at,
           min(r.reversal_reason) as reversal_reason
      from public.sales r
     where r.business_id = p_business
       and r.reversal_of is not null
       and r.reversal_of in (select v.id from visible v)
     group by r.reversal_of
  ),
  lines as (
    select v.id as sale_id, li.id as line_id, v.occurred_at, v.branch_id, v.kind, v.client_id,
           coalesce(li.staff_id, v.staff_id) as staff_id,
           li.item_type, li.description, li.qty, li.line_cents,
           li.commission_rate_bps, li.commission_flat_cents,
           coalesce(li.commission_cents, 0) as commission_cents, li.bundle_id
      from visible v
      join public.sale_items li on li.sale_id = v.id and li.business_id = p_business
    union all
    -- A sale with no lines at all (a quick sale from before v818, an engine that writes no
    -- line): one row from the header snapshot, exactly what public.sale_commission falls back to.
    select v.id, null::uuid, v.occurred_at, v.branch_id, v.kind, v.client_id, v.staff_id,
           v.kind, coalesce(nullif(btrim(v.note), ''), replace(v.kind, '_', ' ')), 1, v.amount_cents,
           v.commission_rate_bps, v.commission_flat_cents,
           case
             when v.commission_flat_cents is not null then v.commission_flat_cents
             else floor(v.amount_cents::numeric * coalesce(v.commission_rate_bps, 0)::numeric / 10000)::integer
           end,
           null::uuid
      from visible v
     where not exists (select 1 from public.sale_items li where li.sale_id = v.id and li.business_id = p_business)
  )
  select l.sale_id, l.line_id, l.occurred_at, l.branch_id, l.kind, l.client_id, c.full_name,
         l.staff_id, st.full_name, l.item_type, l.description, l.qty, l.line_cents,
         l.commission_rate_bps, l.commission_flat_cents, l.commission_cents, l.bundle_id,
         (rv.sale_id is not null), rv.reversed_at, rv.reversal_reason
    from lines l
    left join public.clients c on c.id = l.client_id and c.business_id = p_business
    left join public.staff st on st.id = l.staff_id and st.business_id = p_business
    left join reversal rv on rv.sale_id = l.sale_id
   order by l.occurred_at desc, l.sale_id, l.line_id;
end
$function$;

-- ------------------------------------------------------------------ §8 a sold bundle is switched off, not deleted

do $patch$
declare
  v_src text;
  v_new text;
  v_hits int;
  c_old constant text :=
    '  delete from public.bundle_items item where item.bundle_id = p_bundle;' || E'\n';
  c_new constant text :=
    '  -- nestly_v825: sale_items.bundle_id references this row; a bundle that has been sold' || E'\n' ||
    '  -- stays for the commission and receipt history behind it. Switch it off instead.' || E'\n' ||
    '  if exists (select 1 from public.sale_items li' || E'\n' ||
    '              where li.business_id = p_business and li.bundle_id = p_bundle) then' || E'\n' ||
    '    raise exception ''bundle_has_sales: this bundle has been sold, so it cannot be deleted; switch it off instead''' || E'\n' ||
    '      using errcode = ''23503'';' || E'\n' ||
    '  end if;' || E'\n' ||
    '  delete from public.bundle_items item where item.bundle_id = p_bundle;' || E'\n';
begin
  select pg_get_functiondef(p.oid) into v_src
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'delete_service_bundle_v285';
  if v_src is null then
    raise exception 'v825: delete_service_bundle_v285 not found';
  end if;
  if position('bundle_has_sales' in v_src) > 0 then
    raise notice 'v825: delete_service_bundle_v285 already refuses a sold bundle — nothing to patch';
  else
    v_hits := (length(v_src) - length(replace(v_src, c_old, ''))) / length(c_old);
    if v_hits <> 1 then
      raise exception 'v825: the bundle_items delete anchor occurs % times in delete_service_bundle_v285, expected exactly 1', v_hits;
    end if;
    v_new := replace(v_src, c_old, c_new);
    execute v_new;
  end if;
end
$patch$;

-- ------------------------------------------------------------------ grants

revoke all on function app.staff_commission_eligible_v825(uuid, uuid, timestamptz)
  from public, anon, authenticated;
grant execute on function app.staff_commission_eligible_v825(uuid, uuid, timestamptz)
  to service_role;

revoke all on function app.sale_item_commission_bps_v825(uuid, text, uuid, uuid, uuid, uuid, timestamptz)
  from public, anon, authenticated;
grant execute on function app.sale_item_commission_bps_v825(uuid, text, uuid, uuid, uuid, uuid, timestamptz)
  to service_role;

revoke all on function app.sale_item_commission_flat_cents_v825(uuid, text, uuid, uuid, uuid, uuid, timestamptz, integer)
  from public, anon, authenticated;
grant execute on function app.sale_item_commission_flat_cents_v825(uuid, text, uuid, uuid, uuid, uuid, timestamptz, integer)
  to service_role;

revoke all on function app.sale_item_commission_bps_v811(uuid, text, uuid, uuid, timestamptz)
  from public, anon, authenticated;
grant execute on function app.sale_item_commission_bps_v811(uuid, text, uuid, uuid, timestamptz)
  to service_role;

revoke all on function app.sale_item_commission_flat_cents_v811(uuid, text, uuid, uuid, timestamptz, integer)
  from public, anon, authenticated;
grant execute on function app.sale_item_commission_flat_cents_v811(uuid, text, uuid, uuid, timestamptz, integer)
  to service_role;

revoke all on function app.on_sale_item_commission_snapshot_v825() from public, anon, authenticated;

revoke all on function app.sale_items_immutable_guard() from public, anon, authenticated;

revoke all on function public.business_set_catalogue_commission_v825(uuid, text, uuid, integer, integer)
  from public, anon;
grant execute on function public.business_set_catalogue_commission_v825(uuid, text, uuid, integer, integer)
  to authenticated, service_role;

revoke all on function public.business_staff_commission_lines_v825(uuid, uuid, timestamptz, timestamptz)
  from public, anon;
grant execute on function public.business_staff_commission_lines_v825(uuid, uuid, timestamptz, timestamptz)
  to authenticated, service_role;

revoke all on function public.record_cart_sale(uuid, uuid, uuid, uuid, text, text, jsonb, uuid, boolean, timestamptz, jsonb)
  from public, anon;
grant execute on function public.record_cart_sale(uuid, uuid, uuid, uuid, text, text, jsonb, uuid, boolean, timestamptz, jsonb)
  to authenticated, service_role;

revoke all on function public.sell_package_v102(uuid, uuid, uuid, uuid, uuid) from public, anon;
grant execute on function public.sell_package_v102(uuid, uuid, uuid, uuid, uuid) to authenticated, service_role;

revoke all on function public.delete_service_bundle_v285(uuid, uuid) from public, anon;
grant execute on function public.delete_service_bundle_v285(uuid, uuid) to authenticated, service_role;

commit;
