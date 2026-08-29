-- nestly_v602 -- a child row may not point at another tenant's parent (SEC-02, batches B1 + B2).
--
-- SEC-02 measured 119 simple foreign keys whose parent carries `business_id` but whose FK proves
-- only that the parent row EXISTS, never that it belongs to the same business. A member of firm A
-- who knows (or guesses) a UUID owned by firm B can therefore attach B's service, product, staff
-- member, client, appointment or sale to an A-owned row: RLS checks the row's own business, and
-- the FK checks existence. Nothing checks that the two agree.
--
-- This migration closes the two browser-writable slices of that gap:
--   B1 (17 relationships, P0) -- appointment_services, booking_requests, change_requests,
--      reward_grants, sales, service_products, waitlist.
--   B2 (14 relationships, P1) -- branch_breaks, branch_hours, bringback_grants_v361,
--      client_packages, points_batches, staff_hours, staff_invites, staff_off_days,
--      staff_recurring_off_days.
--
-- Design (per docs/qa/audit-artifacts/SEC-02-TENANT-FK-MIGRATION-BATCH-PLAN-2026-08-29.md §2):
--   1. the parent gets a `(referenced_column, business_id)` unique key where it lacks one;
--   2. the child gets a COMPOSITE FK `(child_fk, business_id) -> parent(id, business_id)`;
--   3. the existing simple FK is KEPT -- nothing is dropped here. The composite is additive, so a
--      rollback is `drop constraint` on the new names only;
--   4. the existing ON DELETE action and the existing NULL semantics are preserved exactly. A
--      nullable child reference stays MATCH SIMPLE: a NULL reference still skips the check even
--      though `business_id` beside it is NOT NULL. That is deliberate -- MATCH FULL would reject
--      every optional link and break five browser writers.
--
-- Staging: every FK is added NOT VALID first (lock hygiene -- the ADD then takes no validation
-- scan inside the ACCESS EXCLUSIVE window), and VALIDATE CONSTRAINT runs afterwards, in this same
-- migration. The audit's live data scan found ZERO mismatching rows across all 31 relationships
-- and the platform's whole row count here is a few hundred (sales 198, booking_requests 26,
-- everything else smaller or empty), so validation is negligible and deferring it would leave the
-- constraint permanently unenforced for pre-existing rows. `set local lock_timeout` bounds the
-- exposure if a writer holds a conflicting lock.
--
-- === Live-schema verification, 2026-08-29 (read-only SELECTs against gadpooereceldfpfxsod) ====
-- Every table, column, constraint name, ON DELETE action, NOT NULL flag and parent unique key
-- below was read from pg_constraint/pg_attribute on production. Where the batch plan and live
-- prod disagree, LIVE WINS; the four discrepancies found are recorded here:
--
--  D1. ON DELETE SET NULL must name its column. The plan's standard shape says "use the existing
--      ON DELETE action". Thirteen of these relationships are ON DELETE SET NULL, and on a
--      composite FK the unqualified form would null EVERY referencing column -- including
--      `business_id`, which is NOT NULL on all thirteen children. That would turn a legitimate
--      parent delete into a constraint violation. Production is PostgreSQL 17.6, so the PG15+
--      form `on delete set null (<child column>)` is used: only the reference is nulled, the
--      tenant key is untouched, which is exactly what the existing simple FK does today.
--
--  D2. reward_grants (CSV row 112) is recorded as authenticated INSERT/UPDATE-capable. That was
--      true when the inventory was generated; nestly_v599 (applied 2026-08-29 09:41) revoked all
--      four write verbs from both browser roles. Live grants are now SELECT/REFERENCES/TRIGGER
--      only. The composite FK is still added -- the server-side writers remain, and the structural
--      invariant should not depend on an ACL that a later migration could widen again.
--
--  D3. booking_tables is EMPTY in production (0 rows), so the two `table_type_id` relationships
--      (booking_requests, waitlist) have no live data behind them. The parent key and both FKs
--      are added anyway: the tables are browser-writable and the gap is structural.
--
--  D4. appointment_services and service_products are both EMPTY (0 rows). The backfill below is
--      therefore a no-op in production; it is written for correctness in any other environment
--      and to make the column's derivation rule explicit at the point it is created.
--
-- Parent unique keys: 28 of the 31 relationships point at a parent that ALREADY has the required
-- `(id, business_id)` key (appointments, branches, business_programmes, clients, products, sales,
-- services, staff). Only three are missing and are created here: booking_tables,
-- bringback_campaigns_v361, package_plans. Matches the plan's READY/ADD split exactly.
--
-- Derived children: appointment_services and service_products have no `business_id` column at all
-- (their RLS reaches through one parent). Each gets an immutable derived `business_id`:
--   * backfilled from its AUTHORITATIVE parent -- the one its RLS policies already reach through
--     (appointments for appointment_services, services for service_products) -- but only after a
--     hard pre-check that BOTH parents agree on the business for every existing row. A
--     disagreement is a data-integrity incident and aborts the migration rather than silently
--     picking a winner;
--   * a BEFORE INSERT trigger derives it when the writer does not supply it, so the existing
--     browser writers (PostgREST INSERT/upsert from app/app-business.js) keep working unchanged --
--     the same pattern v11a used for sales.branch_id. A writer that DOES supply one is not
--     overridden; the composite FKs then judge it;
--   * a BEFORE UPDATE OF business_id trigger refuses to move a row between tenants.
-- Table-level GRANTs cover future columns, so no grant change is needed for the new column.
--
-- No RLS policy, no grant, no function used by the product and no ON DELETE action is changed by
-- this migration. Acceptance suite: db/tests/v602_same_business_references.sql.
--
-- Deploy stamp: the twin at supabase/migrations/20260829190000_nestly_v602_same_business_references.sql
-- carries an AUTHORED stamp (later than v601's real ledger stamp 20260829102308, so it sorts last).
-- Applying through MCP re-stamps the ledger row with the actual UTC apply time; when that happens
-- the plans and manifests are corrected to the real stamp, exactly as v599/v600/v601 were.
--
-- Rollback: drop the 31 constraints named below, then the four triggers, the three app.* functions,
-- the two derived business_id columns, and the three parent unique keys. Nothing else moved.

begin;

set local lock_timeout = '5s';

-- ===========================================================================================
-- 1. Parent unique keys that do not exist yet (3 of 31; the other 28 parents are already READY)
-- ===========================================================================================

alter table public.booking_tables
  add constraint booking_tables_id_business_key unique (id, business_id);

alter table public.bringback_campaigns_v361
  add constraint bringback_campaigns_v361_id_business_key unique (id, business_id);

alter table public.package_plans
  add constraint package_plans_id_business_key unique (id, business_id);

-- ===========================================================================================
-- 2. Derived, immutable business_id for the two children that have no tenant column
-- ===========================================================================================

-- 2a. Refuse to derive anything if the two parents already disagree anywhere.
do $precheck$
declare
  v_bad bigint;
begin
  select count(*) into v_bad
  from public.appointment_services x
  join public.appointments a on a.id = x.appointment_id
  join public.services     s on s.id = x.service_id
  where a.business_id is distinct from s.business_id;
  if v_bad > 0 then
    raise exception
      'v602: % appointment_services row(s) whose appointment and service belong to different businesses; repair or quarantine before applying', v_bad;
  end if;

  select count(*) into v_bad
  from public.service_products x
  join public.products p on p.id = x.product_id
  join public.services s on s.id = x.service_id
  where p.business_id is distinct from s.business_id;
  if v_bad > 0 then
    raise exception
      'v602: % service_products row(s) whose product and service belong to different businesses; repair or quarantine before applying', v_bad;
  end if;
end
$precheck$;

-- 2b. The column, backfilled from the authoritative parent (the one RLS already reaches through).
alter table public.appointment_services add column business_id uuid;
update public.appointment_services x
   set business_id = a.business_id
  from public.appointments a
 where a.id = x.appointment_id
   and x.business_id is null;
alter table public.appointment_services alter column business_id set not null;

alter table public.service_products add column business_id uuid;
update public.service_products x
   set business_id = s.business_id
  from public.services s
 where s.id = x.service_id
   and x.business_id is null;
alter table public.service_products alter column business_id set not null;

-- 2c. Derivation on INSERT. SECURITY DEFINER because the derivation must see the parent row even
--     when the caller's RLS view of it is narrower than the write it is performing; the composite
--     FKs added below are what actually enforce the answer, so this function decides nothing a
--     constraint does not re-check. search_path is pinned to the canonical v21 hardened list.
create or replace function app.appointment_services_business_v602()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public, app, pg_temp
as $$
begin
  if new.business_id is null then
    select a.business_id into new.business_id
      from public.appointments a
     where a.id = new.appointment_id;
  end if;
  return new;
end
$$;

create or replace function app.service_products_business_v602()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public, app, pg_temp
as $$
begin
  if new.business_id is null then
    select s.business_id into new.business_id
      from public.services s
     where s.id = new.service_id;
  end if;
  return new;
end
$$;

-- 2d. The tenant key is immutable once written. Shared by both tables.
create or replace function app.assert_business_id_immutable_v602()
returns trigger
language plpgsql
as $$
begin
  if new.business_id is distinct from old.business_id then
    raise exception 'v602: %.%.business_id is immutable (% -> %)',
      tg_table_schema, tg_table_name, old.business_id, new.business_id
      using errcode = '23514';
  end if;
  return new;
end
$$;

revoke all on function app.appointment_services_business_v602() from public, anon, authenticated;
revoke all on function app.service_products_business_v602()     from public, anon, authenticated;
revoke all on function app.assert_business_id_immutable_v602()   from public, anon, authenticated;

create trigger appointment_services_business_v602
  before insert on public.appointment_services
  for each row execute function app.appointment_services_business_v602();

create trigger appointment_services_business_immutable_v602
  before update of business_id on public.appointment_services
  for each row execute function app.assert_business_id_immutable_v602();

create trigger service_products_business_v602
  before insert on public.service_products
  for each row execute function app.service_products_business_v602();

create trigger service_products_business_immutable_v602
  before update of business_id on public.service_products
  for each row execute function app.assert_business_id_immutable_v602();

-- ===========================================================================================
-- 3. B1 -- P0 browser-write closure (17 composite FKs)
-- ===========================================================================================

-- appointment_services (derived tenant; PK is (appointment_id, service_id), both NOT NULL)
alter table public.appointment_services
  add constraint appointment_services_appointment_business_fkey
  foreign key (appointment_id, business_id)
  references public.appointments (id, business_id)
  on delete cascade
  not valid;

alter table public.appointment_services
  add constraint appointment_services_service_business_fkey
  foreign key (service_id, business_id)
  references public.services (id, business_id)
  on delete restrict
  not valid;

-- booking_requests (direct tenant; all five references nullable -> MATCH SIMPLE preserved,
-- and SET NULL names only the reference so the NOT NULL business_id survives a parent delete)
alter table public.booking_requests
  add constraint booking_requests_appointment_business_fkey
  foreign key (appointment_id, business_id)
  references public.appointments (id, business_id)
  on delete set null (appointment_id)
  not valid;

alter table public.booking_requests
  add constraint booking_requests_branch_business_fkey
  foreign key (branch_id, business_id)
  references public.branches (id, business_id)
  on delete set null (branch_id)
  not valid;

alter table public.booking_requests
  add constraint booking_requests_service_business_fkey
  foreign key (service_id, business_id)
  references public.services (id, business_id)
  on delete set null (service_id)
  not valid;

alter table public.booking_requests
  add constraint booking_requests_staff_business_fkey
  foreign key (staff_id, business_id)
  references public.staff (id, business_id)
  on delete set null (staff_id)
  not valid;

alter table public.booking_requests
  add constraint booking_requests_table_type_business_fkey
  foreign key (table_type_id, business_id)
  references public.booking_tables (id, business_id)
  on delete set null (table_type_id)
  not valid;

-- change_requests
alter table public.change_requests
  add constraint change_requests_appointment_business_fkey
  foreign key (appointment_id, business_id)
  references public.appointments (id, business_id)
  on delete cascade
  not valid;

-- reward_grants (see D2 -- browser write verbs already revoked by v599; server writers remain)
alter table public.reward_grants
  add constraint reward_grants_client_business_fkey
  foreign key (client_id, business_id)
  references public.clients (id, business_id)
  on delete cascade
  not valid;

-- sales (three optional references; anon and authenticated both hold INSERT)
alter table public.sales
  add constraint sales_appointment_business_fkey
  foreign key (appointment_id, business_id)
  references public.appointments (id, business_id)
  on delete set null (appointment_id)
  not valid;

alter table public.sales
  add constraint sales_client_business_fkey
  foreign key (client_id, business_id)
  references public.clients (id, business_id)
  on delete set null (client_id)
  not valid;

alter table public.sales
  add constraint sales_product_business_fkey
  foreign key (product_id, business_id)
  references public.products (id, business_id)
  on delete set null (product_id)
  not valid;

-- service_products (derived tenant)
alter table public.service_products
  add constraint service_products_product_business_fkey
  foreign key (product_id, business_id)
  references public.products (id, business_id)
  on delete cascade
  not valid;

alter table public.service_products
  add constraint service_products_service_business_fkey
  foreign key (service_id, business_id)
  references public.services (id, business_id)
  on delete cascade
  not valid;

-- waitlist
alter table public.waitlist
  add constraint waitlist_client_business_fkey
  foreign key (client_id, business_id)
  references public.clients (id, business_id)
  on delete set null (client_id)
  not valid;

alter table public.waitlist
  add constraint waitlist_service_business_fkey
  foreign key (service_id, business_id)
  references public.services (id, business_id)
  on delete set null (service_id)
  not valid;

alter table public.waitlist
  add constraint waitlist_table_type_business_fkey
  foreign key (table_type_id, business_id)
  references public.booking_tables (id, business_id)
  on delete set null (table_type_id)
  not valid;

-- ===========================================================================================
-- 4. B2 -- P1 owner/staff/module browser-write closure (14 composite FKs)
-- ===========================================================================================

alter table public.branch_breaks
  add constraint branch_breaks_branch_business_fkey
  foreign key (branch_id, business_id)
  references public.branches (id, business_id)
  on delete cascade
  not valid;

alter table public.branch_hours
  add constraint branch_hours_branch_business_fkey
  foreign key (branch_id, business_id)
  references public.branches (id, business_id)
  on delete cascade
  not valid;

alter table public.bringback_grants_v361
  add constraint bringback_grants_v361_campaign_business_fkey
  foreign key (campaign_id, business_id)
  references public.bringback_campaigns_v361 (id, business_id)
  on delete cascade
  not valid;

alter table public.bringback_grants_v361
  add constraint bringback_grants_v361_client_business_fkey
  foreign key (client_id, business_id)
  references public.clients (id, business_id)
  on delete cascade
  not valid;

-- the redeemed sale stays optional: a grant exists before it is redeemed
alter table public.bringback_grants_v361
  add constraint bringback_grants_v361_redeemed_sale_business_fkey
  foreign key (redeemed_sale_id, business_id)
  references public.sales (id, business_id)
  on delete set null (redeemed_sale_id)
  not valid;

alter table public.client_packages
  add constraint client_packages_client_business_fkey
  foreign key (client_id, business_id)
  references public.clients (id, business_id)
  on delete cascade
  not valid;

alter table public.client_packages
  add constraint client_packages_plan_business_fkey
  foreign key (plan_id, business_id)
  references public.package_plans (id, business_id)
  on delete restrict
  not valid;

alter table public.points_batches
  add constraint points_batches_client_business_fkey
  foreign key (client_id, business_id)
  references public.clients (id, business_id)
  on delete cascade
  not valid;

alter table public.points_batches
  add constraint points_batches_programme_business_fkey
  foreign key (programme_id, business_id)
  references public.business_programmes (id, business_id)
  on delete restrict
  not valid;

alter table public.points_batches
  add constraint points_batches_sale_business_fkey
  foreign key (sale_id, business_id)
  references public.sales (id, business_id)
  on delete set null (sale_id)
  not valid;

alter table public.staff_hours
  add constraint staff_hours_staff_business_fkey
  foreign key (staff_id, business_id)
  references public.staff (id, business_id)
  on delete cascade
  not valid;

-- staff_invites.staff_id is nullable (an invite exists before a staff row does) and its simple FK
-- is NO ACTION; both preserved.
alter table public.staff_invites
  add constraint staff_invites_staff_business_fkey
  foreign key (staff_id, business_id)
  references public.staff (id, business_id)
  not valid;

alter table public.staff_off_days
  add constraint staff_off_days_staff_business_fkey
  foreign key (staff_id, business_id)
  references public.staff (id, business_id)
  on delete cascade
  not valid;

alter table public.staff_recurring_off_days
  add constraint staff_recurring_off_days_staff_business_fkey
  foreign key (staff_id, business_id)
  references public.staff (id, business_id)
  on delete cascade
  not valid;

-- ===========================================================================================
-- 5. Validation -- every constraint above, after every ADD (zero mismatches were measured)
-- ===========================================================================================

alter table public.appointment_services     validate constraint appointment_services_appointment_business_fkey;
alter table public.appointment_services     validate constraint appointment_services_service_business_fkey;
alter table public.booking_requests         validate constraint booking_requests_appointment_business_fkey;
alter table public.booking_requests         validate constraint booking_requests_branch_business_fkey;
alter table public.booking_requests         validate constraint booking_requests_service_business_fkey;
alter table public.booking_requests         validate constraint booking_requests_staff_business_fkey;
alter table public.booking_requests         validate constraint booking_requests_table_type_business_fkey;
alter table public.change_requests          validate constraint change_requests_appointment_business_fkey;
alter table public.reward_grants            validate constraint reward_grants_client_business_fkey;
alter table public.sales                    validate constraint sales_appointment_business_fkey;
alter table public.sales                    validate constraint sales_client_business_fkey;
alter table public.sales                    validate constraint sales_product_business_fkey;
alter table public.service_products         validate constraint service_products_product_business_fkey;
alter table public.service_products         validate constraint service_products_service_business_fkey;
alter table public.waitlist                 validate constraint waitlist_client_business_fkey;
alter table public.waitlist                 validate constraint waitlist_service_business_fkey;
alter table public.waitlist                 validate constraint waitlist_table_type_business_fkey;

alter table public.branch_breaks            validate constraint branch_breaks_branch_business_fkey;
alter table public.branch_hours             validate constraint branch_hours_branch_business_fkey;
alter table public.bringback_grants_v361    validate constraint bringback_grants_v361_campaign_business_fkey;
alter table public.bringback_grants_v361    validate constraint bringback_grants_v361_client_business_fkey;
alter table public.bringback_grants_v361    validate constraint bringback_grants_v361_redeemed_sale_business_fkey;
alter table public.client_packages          validate constraint client_packages_client_business_fkey;
alter table public.client_packages          validate constraint client_packages_plan_business_fkey;
alter table public.points_batches           validate constraint points_batches_client_business_fkey;
alter table public.points_batches           validate constraint points_batches_programme_business_fkey;
alter table public.points_batches           validate constraint points_batches_sale_business_fkey;
alter table public.staff_hours              validate constraint staff_hours_staff_business_fkey;
alter table public.staff_invites            validate constraint staff_invites_staff_business_fkey;
alter table public.staff_off_days           validate constraint staff_off_days_staff_business_fkey;
alter table public.staff_recurring_off_days validate constraint staff_recurring_off_days_staff_business_fkey;

commit;
