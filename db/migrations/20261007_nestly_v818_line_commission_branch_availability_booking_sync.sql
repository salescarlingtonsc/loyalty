-- nestly_v818 — owner batch, 2026-09-07 (seven annotated screenshots).
--
-- NUMBERING, so nobody has to work it out later: this was written, verified and applied as
-- nestly_v811. While it was in flight a parallel session merged its OWN nestly_v811
-- (self-serve loyalty birth) to origin/main and claimed deploy slot 20261007020000, so this
-- one yielded both and became v818 at 20261007090000. The database objects it creates keep
-- their `_v811` suffix — app.sale_item_commission_bps_v811, branch_offers_service_v811,
-- trg_sale_items_commission_v811 and the rest — because they were already live in production
-- by then and renaming applied objects to correct a label would have churned production for a
-- cosmetic reason. So: v818 is the migration, `_v811` is the suffix on everything it made.
--
-- Three defects, each traced to a root cause against production before writing a line.
--
-- ============================================================================
-- 1. COMMISSION NEVER LINKED TO THE SERVICE RATE  (owner photos 1 and 2)
-- ============================================================================
-- Photo 1 ringed the Commission% column of the services catalogue: "Commission failed
-- to link to staff commission when service sold". Photo 2 ringed a team member's two
-- rate fields: "1. Service comm failed to link when services sold. 2. Product comm
-- applied on both product and service sold."
--
-- Both are the same root cause. app.commission_rate_bps decides service-versus-product
-- from `sales.kind`, and finds the service through `appointments.service_id`:
--
--     case when p_kind = 'service'
--          then coalesce(svc.commission_bps, st.commission_service_bps)
--          else st.commission_product_bps end
--
-- The till has never written kind='service'. Every row it writes is kind='quick_sale'
-- with no appointment_id — verified on the live tenant, 15 of 15 recent sales:
--
--     kind        items                                              rate_bps
--     quick_sale  service:Signature Relaxation Massage(8800)          0
--     quick_sale  retail:Massage Oil(3000) | service:Foot Refl(5800)  1000
--
-- So the `else` branch always won: the PRODUCT rate was charged against the whole
-- basket, services included, and the service rate — and the per-service override in
-- photo 1 — could never fire at all. Exactly the two things the owner reported.
--
-- It is also the wrong SHAPE. commission_rate_bps is one number on the sale HEADER, so
-- a basket holding a massage and a bottle of oil cannot pay two different rates however
-- the kind is resolved. Owner ruling 2026-09-07: commission is worked out PER LINE.
--
--     Hot Stone Ritual  68.00  service -> service override 10%  ->  6.80
--     Massage Oil       30.00  retail  -> staff product 10%     ->  3.00
--                                                     commission   9.80
--
-- The resolution ORDER is unchanged from v11a — this migration moves where it is asked,
-- never what it answers:
--     service line -> services.commission_flat_cents          (fixed amount per service)
--                  -> services.commission_bps                 (per-service % override)
--                  -> staff.commission_service_bps            (the member's own rate)
--                  -> 0
--     other line   -> staff.commission_product_bps -> 0
-- and commission_starts_on still zeroes anything before the member's start date.
--
-- A 0 on a service still WINS over the staff rate (coalesce, not coalesce+nullif): 0% is
-- a real setting meaning "this service pays nothing", exactly as v12 recorded.
--
-- Non-service, non-retail lines (custom, package, membership, gift_card, discounts) keep
-- taking the product rate. That is what they are paid today as part of the whole-basket
-- header rate, so nothing an owner is already paying changes except the two things
-- reported. Whether a gift-card line should pay commission at all is a separate product
-- question and is deliberately NOT decided here.
--
-- sales is append-only — app.sales_immutable_guard permits UPDATE only under two named
-- session settings and neither may touch an economic column — so the per-line total is
-- NOT rolled up onto the header. public.sale_commission, the one view every commission
-- reader goes through, prefers the line sum and falls back to the old header arithmetic
-- for a sale that has no lines (reversals, and quick sales from before this migration).
--
-- ⚖️ EXPOSURE, deliberate: sale_items could be read only by the salon owner. Manager and
-- bookkeeper hold view_finance and therefore already read sale_commission — the sale
-- total, its kind and who it was attributed to. Without the lines behind it they would
-- read a DIFFERENT commission figure from the owner for the same sale, which is the
-- worse failure. They get a read on sale_items scoped to the same view_finance
-- permission. Staff and frontdesk hold no view_finance and see nothing.
--
-- Backfill: the four commission columns are new, so there is no prior snapshot being
-- rewritten — the backfill COMPLETES history rather than restating it. Nobody has been
-- paid on these figures (every commission rate on the estate was set during this week's
-- testing) and leaving 293 existing lines NULL would leave the owner's own test sales
-- reading the wrong number on Staff performance, which is the report that raised this.
--
-- ============================================================================
-- 2. A SERVICE PINNED TO A DEACTIVATED BRANCH DISAPPEARS  (owner photo 6)
-- ============================================================================
-- Photo 6 ringed the till's Add item sheet: "1. One of the item added and show 'ON' but
-- not shown here. 2. Bundles not shown here."
--
-- One root cause under both halves. Production:
--
--     services:        Aromatherapy Ritual   active = true
--     service_branches Aromatherapy Ritual -> KKY demo Salon
--     branches:        KKY demo Salon        active = FALSE
--                      ÉLAN Wellness         active = true   (the only live branch)
--
-- The availability predicate reads "if this service has ANY service_branches row it is
-- sold only where a row names this branch". It counts a row naming a DEACTIVATED branch
-- as a live restriction, so a service pinned only to branches that have since been
-- switched off becomes sellable nowhere — while the catalogue page, which reads
-- services.active, keeps showing it On. That is the contradiction in the photo.
--
-- The bundle vanished for the same reason: "The Elen Ritual" contains Aromatherapy
-- Ritual, and a bundle is withheld unless every member is sellable at the branch.
--
-- Fix: a row naming an inactive branch is not a restriction, because an inactive branch
-- is not a place anything can be sold. A service whose every pin points at inactive
-- branches is unrestricted again — the same principle as v14's ruling that turning a
-- module off must never strand rows, and v627's "no rows means available everywhere".
-- Deactivating a branch stops being able to strand a service.
--
-- The predicate lived copy-pasted in three places and had already drifted (products got
-- their own function in v627, services never did). It becomes ONE authority,
-- app.branch_offers_service_v811, called by the till catalogue and by the customer
-- booking portal — which had the identical bug, so the service was hidden from customers
-- online too.
--
-- ============================================================================
-- 3. A CANCELLED APPOINTMENT STILL READS "CONFIRMED"  (owner photo 4)
-- ============================================================================
-- Photo 4 ringed the Bookings list: "Appt cancelled but still showing 'Confirmed'. Only
-- can see it was cancelled after clicking into it."
--
-- Production, the exact row in the photo:
--
--     appointments     e6f0beb6…  status = cancelled
--     booking_requests 64ac3b7e…  status = confirmed   appointment_id = e6f0beb6…
--
-- The list renders booking_requests.status. Cancelling the appointment never wrote back,
-- so the request kept saying confirmed. Five such rows exist across the estate.
--
-- There are several writers of appointments.status (set_appointment_status_v47,
-- set_appointment_status_with_reason_v631, customer_cancel_appointment_v655, reschedule
-- paths), so patching the one the owner happened to use would leave the defect class
-- open. The sync is a TRIGGER on appointments — every writer, present and future, is
-- closed by construction.

begin;

-- ---------------------------------------------------------------- 1. per-line commission

alter table public.sale_items
  add column if not exists commission_rate_bps integer,
  add column if not exists commission_flat_cents integer,
  add column if not exists commission_cents integer,
  add column if not exists commission_resolved_at timestamptz;

do $$
begin
  if not exists (select 1 from pg_constraint
                  where conrelid = 'public.sale_items'::regclass
                    and conname = 'sale_items_commission_rate_range_v811') then
    alter table public.sale_items
      add constraint sale_items_commission_rate_range_v811
      check (commission_rate_bps is null or commission_rate_bps between 0 and 10000);
  end if;
end $$;

comment on column public.sale_items.commission_rate_bps is
  'nestly_v818: the commission rate this LINE was signed at, resolved once at insert. '
  'Service lines take the service override then the member''s service rate; every other '
  'line takes the member''s product rate. Frozen — later rate edits never restate it.';
comment on column public.sale_items.commission_cents is
  'nestly_v818: what this line pays. flat x qty when the service carries a fixed amount, '
  'otherwise floor(line_cents * rate_bps / 10000).';

-- The rate for one line. Same resolution order as v11a/v12, asked per line instead of
-- per sale, and reading the line's own service rather than an appointment's.
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
  select case
           when st.id is null then 0
           when st.commission_starts_on is not null
                and (p_occurred_at at time zone 'Asia/Singapore')::date < st.commission_starts_on
                then 0
           else coalesce(
                  case when p_item_type = 'service'
                       -- coalesce, NOT coalesce+nullif: a 0% service override is a real
                       -- setting and must beat the member's own rate (v12).
                       then coalesce(svc.commission_bps, st.commission_service_bps)
                       else st.commission_product_bps
                  end, 0)
         end
  from (select 1) _
  left join public.staff st
    on st.id = p_staff and st.business_id = p_business
  left join public.services svc
    on p_item_type = 'service' and svc.id = p_ref_id and svc.business_id = p_business
$function$;

-- The fixed-amount-per-service alternative (v13). Service lines only, positive lines
-- only, and it outranks the percentage when the service carries one — identical rules to
-- app.commission_flat_cents, which could never fire from the till for the same reason
-- the percentage could not.
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
  select case
           when st.id is null then null
           when st.commission_starts_on is not null
                and (p_occurred_at at time zone 'Asia/Singapore')::date < st.commission_starts_on
                then null
           when coalesce(p_line_cents, 0) <= 0 then null
           when p_item_type = 'service' then svc.commission_flat_cents
           else null
         end
  from (select 1) _
  left join public.staff st
    on st.id = p_staff and st.business_id = p_business
  left join public.services svc
    on p_item_type = 'service' and svc.id = p_ref_id and svc.business_id = p_business
$function$;

-- Signs each line as it is written. The line's own staff_id wins when the till starts
-- attributing lines individually; until then every line inherits the sale's attribution,
-- which is the same person the header snapshot used.
create or replace function app.on_sale_item_commission_snapshot_v811()
returns trigger
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $function$
declare
  v_sale public.sales%rowtype;
  v_staff uuid;
begin
  select * into v_sale
    from public.sales
   where id = new.sale_id and business_id = new.business_id;
  if not found then
    raise exception 'sale % not found for line commission snapshot', new.sale_id
      using errcode = 'foreign_key_violation';
  end if;

  v_staff := coalesce(new.staff_id, v_sale.staff_id);

  new.commission_rate_bps := app.sale_item_commission_bps_v811(
    new.business_id, new.item_type, new.ref_id, v_staff, v_sale.occurred_at);
  new.commission_flat_cents := app.sale_item_commission_flat_cents_v811(
    new.business_id, new.item_type, new.ref_id, v_staff, v_sale.occurred_at, new.line_cents);
  new.commission_cents := case
    when new.commission_flat_cents is not null then new.commission_flat_cents * new.qty
    else floor(new.line_cents::numeric * new.commission_rate_bps::numeric / 10000)::integer
  end;
  new.commission_resolved_at := now();
  return new;
end
$function$;

drop trigger if exists trg_sale_items_commission_v811 on public.sale_items;
create trigger trg_sale_items_commission_v811
  before insert on public.sale_items
  for each row execute function app.on_sale_item_commission_snapshot_v811();

-- ⚖️ view_finance already reads every sale total, kind and attribution through
-- sale_commission. Without the lines a manager and the owner would read two different
-- commission figures for one sale; this keeps them reading the same one.
drop policy if exists sale_items_finance_read_v811 on public.sale_items;
create policy sale_items_finance_read_v811 on public.sale_items
  for select using (app.has_perm(business_id, 'view_finance'));

-- The one view every commission reader goes through. Line sum first; the old header
-- arithmetic survives untouched for sales that have no lines.
create or replace view public.sale_commission
with (security_invoker = on) as
  select
    sale.id as sale_id,
    sale.business_id,
    sale.branch_id,
    sale.staff_id,
    sale.kind,
    sale.occurred_at,
    sale.amount_cents,
    sale.commission_rate_bps as rate_bps,
    case
      -- A reversal mirrors whatever the original actually paid, per line if the
      -- original had lines. Sign is set explicitly so rounding stays on the same side
      -- of zero as the sale it reverses.
      when sale.reversal_of is not null and sale.amount_cents < 0
        then - coalesce(
               (select sum(orig.commission_cents)::integer
                  from public.sale_items orig
                 where orig.business_id = sale.business_id
                   and orig.sale_id = sale.reversal_of
                   and orig.commission_cents is not null),
               case when sale.commission_flat_cents is not null
                    then sale.commission_flat_cents
                    else floor((- sale.amount_cents)::numeric
                               * sale.commission_rate_bps::numeric / 10000)::integer end)
      else coalesce(
             (select sum(line.commission_cents)::integer
                from public.sale_items line
               where line.business_id = sale.business_id
                 and line.sale_id = sale.id
                 and line.commission_cents is not null),
             case when sale.commission_flat_cents is not null
                  then sale.commission_flat_cents
                  else floor(sale.amount_cents::numeric
                             * sale.commission_rate_bps::numeric / 10000)::integer end)
    end as commission_cents,
    sale.commission_flat_cents as flat_cents,
    sale.counts_as_revenue
  from public.sales sale
 where app.has_perm(sale.business_id, 'view_finance')
   and app.can_see_branch(sale.business_id, sale.branch_id);

-- sale_items is absolutely append-only: its guard refuses every UPDATE with no escape at
-- all, so the backfill below cannot run against it. sales solved the same problem in v20
-- with a named session setting that may not touch an economic fact; sale_items gets the
-- narrower version of exactly that. The window may change the four commission columns and
-- NOTHING else, and only where they were all still NULL — so it can complete a snapshot
-- that never existed and can never restate one that does. Anything else still raises.
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
          new.created_at, new.canonical_node_key, new.taxonomy_version_no)
         is distinct from
         (old.id, old.sale_id, old.business_id, old.item_type, old.ref_id, old.description,
          old.qty, old.unit_cents, old.line_cents, old.product_id, old.staff_id,
          old.created_at, old.canonical_node_key, old.taxonomy_version_no)
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

revoke all on function app.sale_items_immutable_guard() from public, anon;

-- Completes the four new columns for lines written before this migration. Reuses the
-- same two resolvers the trigger uses, so a backfilled line and a live one can never
-- disagree. Reversal sale rows carry no lines and are untouched.
select set_config('app.sale_items_commission_backfill', 'nestly_v818', true);

update public.sale_items line
   set commission_rate_bps = app.sale_item_commission_bps_v811(
         line.business_id, line.item_type, line.ref_id,
         coalesce(line.staff_id, sale.staff_id), sale.occurred_at),
       commission_flat_cents = app.sale_item_commission_flat_cents_v811(
         line.business_id, line.item_type, line.ref_id,
         coalesce(line.staff_id, sale.staff_id), sale.occurred_at, line.line_cents),
       commission_cents = case
         when app.sale_item_commission_flat_cents_v811(
                line.business_id, line.item_type, line.ref_id,
                coalesce(line.staff_id, sale.staff_id), sale.occurred_at, line.line_cents) is not null
           then app.sale_item_commission_flat_cents_v811(
                  line.business_id, line.item_type, line.ref_id,
                  coalesce(line.staff_id, sale.staff_id), sale.occurred_at, line.line_cents) * line.qty
         else floor(line.line_cents::numeric * app.sale_item_commission_bps_v811(
                line.business_id, line.item_type, line.ref_id,
                coalesce(line.staff_id, sale.staff_id), sale.occurred_at)::numeric / 10000)::integer
       end,
       commission_resolved_at = now()
  from public.sales sale
 where sale.id = line.sale_id
   and sale.business_id = line.business_id
   and line.commission_resolved_at is null;

select set_config('app.sale_items_commission_backfill', '', true);

-- ------------------------------------------------- 2. branch availability, one authority

-- A service is offered at a branch when it is pinned to no ACTIVE branch at all, or is
-- pinned to this one. A pin to a branch that has since been switched off is not a
-- restriction, because nothing can be sold at a branch that is off.
create or replace function app.branch_offers_service_v811(
  p_business uuid,
  p_service uuid,
  p_branch uuid
) returns boolean
language sql
stable
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $function$
  select p_service is null
      or not exists(
        select 1
          from public.service_branches configured
          join public.branches branch
            on branch.id = configured.branch_id
           and branch.business_id = configured.business_id
           and branch.active
         where configured.business_id = p_business
           and configured.service_id = p_service)
      or exists(
        select 1 from public.service_branches allowed
         where allowed.business_id = p_business
           and allowed.service_id = p_service
           and allowed.branch_id = p_branch)
$function$;

-- Products had their own function since v627 and the identical hole. Only the "is it
-- restricted at all" test needs the active filter: the branch being asked about is
-- already required to be active by every caller.
create or replace function app.branch_offers_product_v627(
  p_business uuid,
  p_product uuid,
  p_branch uuid
) returns boolean
language sql
stable
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $function$
  select p_product is null
      or not exists(
        select 1
          from public.product_branches configured
          join public.branches branch
            on branch.id = configured.branch_id
           and branch.business_id = configured.business_id
           and branch.active
         where configured.business_id = p_business
           and configured.product_id = p_product)
      or exists(
        select 1 from public.product_branches allowed
         where allowed.business_id = p_business
           and allowed.product_id = p_product
           and allowed.branch_id = p_branch)
$function$;

-- The till catalogue: the inline service predicate becomes the shared function. Nothing
-- else in this function changes.
create or replace function public.business_get_checkout_catalogue_v94(
  p_business uuid,
  p_branch uuid,
  p_include_inactive boolean
) returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $function$
declare
  v_branch uuid:=p_branch;
  v_setting public.business_checkout_catalogue_settings_v94%rowtype;
  v_branches jsonb;
  v_items jsonb;
begin
  if p_include_inactive is null then
    raise exception 'include_inactive_required' using errcode='22023';
  end if;
  if v_branch is null then
    select branch.id into v_branch
    from public.branches branch
    where branch.business_id=p_business and branch.active
    order by branch.is_default desc,branch.created_at,branch.id
    limit 1;
  end if;
  if v_branch is null or not exists(
    select 1 from public.branches branch
    where branch.id=v_branch and branch.business_id=p_business and branch.active
  ) then
    raise exception 'active_branch_required' using errcode='22023';
  end if;
  if not (
    app.is_super_admin()
    or app.can_module_read_at_v94(p_business,v_branch,'sales')
    or app.can_module_read_at_v94(p_business,v_branch,'till')
  ) then
    raise exception 'checkout_catalogue_access_required' using errcode='42501';
  end if;
  if p_include_inactive and not (
    app.is_super_admin() or app.is_salon_owner(p_business)
  ) then
    raise exception 'owner_required_for_inactive_catalogue' using errcode='42501';
  end if;

  select * into v_setting
  from public.business_checkout_catalogue_settings_v94
  where business_id=p_business;
  if not found then
    raise exception 'business_not_found' using errcode='22023';
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
    'id',branch.id,'name',branch.name,'is_default',branch.is_default
  ) order by branch.is_default desc,branch.name,branch.id),'[]'::jsonb)
  into v_branches
  from public.branches branch
  where branch.business_id=p_business and branch.active
    and (
      app.is_super_admin()
      or app.can_see_branch(p_business,branch.id)
    );

  with catalogue as (
    select
      'service'::text item_type,service.id item_id,service.name,
      service.price_cents unit_cents,service.active source_active,
      coalesce(item.checkout_active,true) checkout_active,
      -- nestly_v818: was an inline "any service_branches row restricts", which counted a
      -- pin to a deactivated branch as a live restriction and hid the service everywhere.
      app.branch_offers_service_v811(p_business,service.id,v_branch) branch_available,
      coalesce(item.version,0) version,
      app.v95_public_media_url(service_asset.object_path) image_url
    from public.services service
    left join public.business_checkout_catalogue_items_v94 item
      on item.business_id=p_business and item.item_type='service'
      and item.item_id=service.id
    left join public.business_media_assets_v95 service_asset
      on service_asset.business_id=p_business
      and service_asset.asset_kind='service'
      and service_asset.entity_id=service.id
      and service_asset.branch_id is null
      and service_asset.customer_visible
    where service.business_id=p_business
    union all
    select
      'product'::text,product.id,product.name,
      product.retail_price_cents,product.active,
      coalesce(item.checkout_active,true),
      -- nestly_v627: was the literal `true`. A product with no product_branches row is still
      -- available everywhere, so nothing already on sale changes.
      app.branch_offers_product_v627(p_business,product.id,v_branch),
      coalesce(item.version,0),
      app.v95_public_media_url(product_asset.object_path)
    from public.products product
    left join public.business_checkout_catalogue_items_v94 item
      on item.business_id=p_business and item.item_type='product'
      and item.item_id=product.id
    left join public.business_media_assets_v95 product_asset
      on product_asset.business_id=p_business
      and product_asset.asset_kind='product'
      and product_asset.entity_id=product.id
      and product_asset.branch_id is null
      and product_asset.customer_visible
    where product.business_id=p_business
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'item_type',item_type,'item_id',item_id,'name',name,
    'unit_cents',unit_cents,'checkout_active',checkout_active,
    'branch_available',branch_available,'version',version,
    'image_url',image_url
  ) order by item_type,name,item_id),'[]'::jsonb)
  into v_items
  from catalogue
  where p_include_inactive
     or (source_active and checkout_active and branch_available);

  return jsonb_build_object(
    'platform_allowed',v_setting.platform_allowed,
    'enabled',v_setting.platform_allowed and v_setting.owner_enabled,
    'settings_version',v_setting.version,
    'selected_branch_id',v_branch,
    'branches',v_branches,
    'items',v_items
  );
end
$function$;

-- The customer booking portal carried a verbatim copy of the same inline predicate, so
-- the service was hidden from customers online too. Patched in place against the live
-- body rather than restated: this function is 20KB of localisation and media joins that
-- this migration has no business rewriting, and a silent miss is impossible because the
-- anchor is required to match.
do $do$
declare
  v_old text;
  v_new text;
  v_anchor constant text :=
'      and (not exists(select 1 from public.service_branches configured
        where configured.business_id=p_business and configured.service_id=service.id)
        or exists(select 1 from public.service_branches available
          where available.business_id=p_business and available.service_id=service.id
            and available.branch_id=v_branch))';
  v_replacement constant text :=
'      and app.branch_offers_service_v811(p_business,service.id,v_branch)';
begin
  select pg_get_functiondef(p.oid) into v_old
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'customer_get_business_presentation_v95';
  if v_old is null then
    raise exception 'nestly_v818: customer_get_business_presentation_v95 not found';
  end if;
  v_new := replace(v_old, v_anchor, v_replacement);
  if v_new = v_old then
    raise exception
      'nestly_v818: the service branch predicate in customer_get_business_presentation_v95 '
      'did not match — it has been edited since this migration was written; re-derive the anchor';
  end if;
  execute v_new;
end
$do$;

-- ------------------------------------------- 3. a booking request follows its appointment

-- Several RPCs write appointments.status. A trigger closes all of them, and any writer
-- added later, rather than the one path the owner happened to use.
create or replace function app.booking_request_follows_appointment_v811()
returns trigger
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $function$
begin
  if new.status is not distinct from old.status then
    return new;
  end if;
  if new.status not in ('cancelled', 'no_show') then
    return new;
  end if;
  update public.booking_requests request
     set status = 'cancelled'
   where request.business_id = new.business_id
     and request.appointment_id = new.id
     and request.status in ('new', 'pending', 'confirmed', 'waitlisted');
  return new;
end
$function$;

drop trigger if exists trg_booking_request_follows_appointment_v811 on public.appointments;
create trigger trg_booking_request_follows_appointment_v811
  after update of status on public.appointments
  for each row execute function app.booking_request_follows_appointment_v811();

-- The five rows already stranded across the estate, including the one in photo 4.
update public.booking_requests request
   set status = 'cancelled'
  from public.appointments appointment
 where appointment.id = request.appointment_id
   and appointment.business_id = request.business_id
   and appointment.status in ('cancelled', 'no_show')
   and request.status in ('new', 'pending', 'confirmed', 'waitlisted');

-- ------------------------------------------------------------------------------ grants
-- Restated verbatim from the live proacl. CREATE OR REPLACE preserves grants, but the
-- pending-migration preflight requires the exact overload signature to appear.

-- The three new `app` helpers get NO browser grant. Every caller reaches them from inside a
-- SECURITY DEFINER function (the two catalogue readers, the sale_items trigger) or from this
-- migration's own backfill, so they run as the definer and an `authenticated` grant would buy
-- nothing while adding three directly-callable internal helpers to the estate. The
-- v720_corpus_evidence_pack_grants fixture scans for exactly that and is what caught the
-- first draft of this migration granting them out of habit.
revoke all on function app.sale_item_commission_bps_v811(uuid, text, uuid, uuid, timestamptz)
  from public, anon, authenticated;
grant execute on function app.sale_item_commission_bps_v811(uuid, text, uuid, uuid, timestamptz)
  to service_role;

revoke all on function app.sale_item_commission_flat_cents_v811(uuid, text, uuid, uuid, timestamptz, integer)
  from public, anon, authenticated;
grant execute on function app.sale_item_commission_flat_cents_v811(uuid, text, uuid, uuid, timestamptz, integer)
  to service_role;

revoke all on function app.on_sale_item_commission_snapshot_v811() from public, anon, authenticated;

revoke all on function app.booking_request_follows_appointment_v811() from public, anon, authenticated;

revoke all on function app.branch_offers_service_v811(uuid, uuid, uuid) from public, anon, authenticated;
grant execute on function app.branch_offers_service_v811(uuid, uuid, uuid) to service_role;

revoke all on function app.branch_offers_product_v627(uuid, uuid, uuid) from public, anon;
grant execute on function app.branch_offers_product_v627(uuid, uuid, uuid)
  to authenticated, service_role;

revoke all on function public.business_get_checkout_catalogue_v94(uuid, uuid, boolean)
  from public, anon;
grant execute on function public.business_get_checkout_catalogue_v94(uuid, uuid, boolean)
  to authenticated, service_role;

grant select on public.sale_commission to authenticated, service_role;

commit;
