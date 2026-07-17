-- FRENLY v11a — the entity foundation: BRANCHES, STAFF, SERVICES.
-- (target Supabase project kyzovonwnscrzmkvocid; migration name `frenly_v11a_branches_staff_services`)
--
-- APPLY ORDER:  v10_sale_policy  ->  v10_1_policy_snapshot  ->  v11a (this file)  ->  v11b_money.
-- **v10.1 IS A HARD PREREQUISITE OF THIS FILE.** It was not, in the original draft — v11a §1.7
-- issued a bare `update public.sales` and v10.1 makes `sales` append-only via
-- trg_sales_immutable_guard. That is not a theoretical clash; it was measured (rolled back):
--     ERROR: sales is append-only: UPDATE is not permitted (sale fc041326-06f4-497a-b91e-…).
--     -> 6 of 6 sales still branch_id IS NULL; the whole migration aborted.
-- §1.7 now wraps the backfill in v10.1's audited escape (app.begin_sales_backfill /
-- app.end_sales_backfill). Those functions do not exist before v10.1, so this file will now
-- fail loudly at §1.7 if v10.1 is skipped, rather than silently leaving branch_id null.
--
-- v11a does NOT touch app.on_sale_recorded(). It lands cleanly on top of v10/v10.1's rewrite
-- of that function without re-declaring it — see "WHY THIS FILE NEVER TOUCHES THE LOYALTY
-- TRIGGER" below.
--
-- SCOPE: protocol §12 foundation positions 1 (branches), 5 (staff), 6 (services).
-- Money — transactions/checkout/drawer/expenses (position 9) — is v11b.
--
-- ====================================================================================
-- PRE-FLIGHT CORRECTION TO THE BRIEF (read this first)
-- ====================================================================================
-- The brief states "sales is currently empty (0 rows, verify)" and "there is 1 existing
-- business". Both are FALSE as of 2026-07-17. Verified live, read-only:
--
--     sales 6 · businesses 2 · appointments 3 · services 1 · staff 2 · clients 4
--     products 1 · client_packages 1
--
-- The rows were created by the Sonnet end-to-end QA pass (task #18), which ran AFTER v10
-- was written. Three consequences, all of which changed this migration's design:
--
--   1. NO "empty table" free pass. Every column added here is nullable or defaulted, and
--      every backfill below is written against real rows.
--
--   2. **v10's OWN SAFETY HEADER IS NOW STALE — FLAG FOR THE ORCHESTRATOR.** v10 says
--      "public.sales is empty (0 rows, re-verified pre-flight) and there is 1 businesses
--      row." It is 6 and 2. v10's drop/recreate of sales_kind_check is still SAFE (all six
--      live kinds are in v10's new list, so the constraint validates), but the claim should
--      be re-verified before you apply it, not trusted.
--
--   3. **A LIVE ROW v10 WILL SILENTLY MIS-CLASSIFY — THIS IS A REAL FINDING.** Sale
--      `76afd37c-1080-4a90-bd1c-f47dd212763c` (business QA Test Cafe, 10000 cents,
--      note 'package sold: QA Test 5x Session Pack') is a package purchase carrying
--      kind='retail', written by the pre-v10 sell_package(). v10 changes sell_package to
--      write kind='package' but performs NO BACKFILL, so this row keeps kind='retail'
--      forever: it counts as a retention VISIT and qualifies a referral under the 'retail'
--      default, which is exactly the 11-visits-per-10-session-package bug v10 exists to
--      kill. It is QA data, so the fix may be "delete the QA rows" rather than "backfill" —
--      that is the owner's call, not mine. I have NOT touched it. Suggested one-liner if
--      you want it reclassified, to run inside v10:
--          update public.sales set kind = 'package'
--           where kind = 'retail' and note like 'package sold: %';
--      (Matches exactly 1 row today. Verify the count before running it.)
--
-- ====================================================================================
-- WHY THIS FILE NEVER TOUCHES THE LOYALTY TRIGGER
-- ====================================================================================
-- app.on_sale_recorded() is an AFTER INSERT trigger on sales. Everything v11a adds to sales
-- (branch_id, staff_id) is populated BEFORE INSERT. The two never interact, so v10's version
-- of the function survives byte-for-byte and none of its verified semantics are re-litigated
-- here. This is deliberate: on_sale_recorded is the single most-tested object in the schema
-- (16-assertion chain test in v9, 7 scenarios in v10) and re-declaring it in a third
-- migration would put all of that at risk for no gain.
--
-- ====================================================================================
-- DESIGN — BRANCHES
-- ====================================================================================
-- Live-confirmed competitor behaviour (LIVE_DATA_WALKTHROUGH step 1): a branch is a location
-- with per-day hours + breaks, address/phone/email, a tax-rate override ("blank inherits the
-- business default; 0 is a valid override" — so the column is NULLABLE and 0 is meaningful,
-- NOT a sentinel), and an active flag meaning "accepting bookings, shown on the public
-- booking page". Branch existence gates the cash drawer.
--
-- THE BACKFILL DECISION — auto-create one default branch per business, and backfill.
-- Argued, because the alternative was tempting and is wrong:
--
--   * The competitor blocks the drawer until you create a branch. It can afford to: it has
--     no pre-existing tenants. Frenly has 2 live businesses, 3 appointments and 6 sales that
--     work today. Shipping "your cash drawer is disabled until you go create a branch"
--     to a business that has been selling for a week is a regression we would be importing
--     for no reason other than mimicry. Parity is about capability, not about copying an
--     onboarding cliff.
--   * `businesses` IS the location today. A default branch is therefore not new information —
--     it is the existing implicit fact made addressable. Backfilling it is lossless.
--   * branch_id stays NULLABLE on sales/appointments, and is defaulted by a BEFORE INSERT
--     trigger (app.set_row_branch) rather than by NOT NULL. THIS IS THE LOAD-BEARING CHOICE:
--     enroll_membership, run_membership_renewals, issue_gift_card, sell_package and the UI's
--     quick-sale INSERT all write to `sales` without a branch_id and are not modified by this
--     migration. A NOT NULL column would break all five. The trigger makes every one of them
--     keep working, unmodified, AND come out branch-attributed. Backward compatibility here
--     is a trigger, not a promise.
--   * is_default is a column on branches with a unique partial index, not a pointer on
--     businesses. A pointer would need an FK back to a table that FKs to businesses, and
--     could dangle on delete; the partial index makes "exactly one default" an invariant the
--     database enforces.
--
-- Multi-branch is NOT gated. The competitor paywalls it; we model it fully, per the brief.
--
-- ⚖️ TAX / GST: businesses.tax_rate_bps + branches.tax_rate_bps (override). This migration
--    STORES a rate and resolves inheritance. It does NOT compute GST, does not decide what is
--    taxable, and makes NO claim of Singapore GST or IRAS compliance. Rate semantics,
--    registration thresholds and inclusive-vs-exclusive pricing are for counsel + the owner.
--    Basis points (1/100th of a percent) so 8.5% is 850 — an integer, no float drift.
--
-- ====================================================================================
-- DESIGN — STAFF
-- ====================================================================================
-- THE BLOCKER NOBODY HAS WRITTEN DOWN: public.staff.user_id is NOT NULL and FKs to
-- auth.users. Verified live. So today a Frenly "staff member" MUST be a login. The
-- competitor's flow (walkthrough step 2) is "Add staff -> Full name 'Test Staff' -> Create",
-- with email optional and no account. A salon adding six stylists to a rota does not want to
-- create six auth users, and a WPass worker may not have an email at all (see CLAUDE.md's
-- low-literacy-first direction). **Without making user_id nullable, FL-STAFF parity is not
-- reachable at all** — you cannot even create the record.
--
-- So v11a makes staff.user_id NULLABLE. Safety analysis, because this column is load-bearing
-- for the entire tenant-isolation model:
--   * app.is_salon_member / app.is_salon_owner both test `s.user_id = auth.uid()`. In SQL,
--     NULL = <anything> is NULL, never true. A staff row with a null user_id therefore grants
--     NOTHING to anyone. The membership test fails closed. This is the whole argument and it
--     is worth an explicit verification test (v11b test scenario F).
--   * staff_salon_id_user_id_key is UNIQUE (business_id, user_id). Postgres treats NULLs as
--     distinct in unique indexes, so many non-login staff per business are permitted while
--     the "one row per real user per business" rule still holds for real users. No change
--     needed.
--   * A non-login staff row is a ROTA ENTITY (bookable, commissionable, schedulable); a
--     login staff row is additionally a PRINCIPAL. Linking a login later = setting user_id.
--   * The staff RLS split is unchanged and now does useful work: staff_insert/update/delete
--     require app.is_salon_owner, so only an owner can create rota staff or edit a
--     commission rate. staff_select is is_salon_member.
--
-- COMMISSION (⚠️ UO-1, Unapproved Omission — see the parity matrix §4): CLAUDE.md says
-- commission/payroll is "out of scope per owner". Per the brief that exclusion predates the
-- parity mandate. I build the DATA FOUNDATION ONLY — the two rates, the start date, the
-- per-service override, and a derived view that shows the arithmetic. There is NO payroll
-- report, NO payout ledger, NO period close, and no RPC that pays anybody. Nothing here
-- moves money. If the owner re-confirms the exclusion, the cost of unwinding this is
-- dropping four columns and one view.
--
-- The two-rate split is the competitor's, live-confirmed: "Service commission %" vs
-- "Product / sale commission %" which "applies to every sale this staff rings up — retail,
-- package, walk-in". Resolution order for a sale, most specific first:
--     kind='service'  ->  services.commission_bps  ->  staff.commission_service_bps  -> 0
--     any other kind  ->  staff.commission_product_bps                                -> 0
-- ...and only if staff.commission_starts_on <= the sale date (the competitor's
-- "Commission starts on" field). Blank service override falls through — hence NULLABLE, and
-- again 0 is a real value meaning "zero commission", not "unset". The view lives in v11b
-- because it needs sales.staff_id AND must agree with v10's sale kinds.
--
-- ====================================================================================
-- DESIGN — SERVICES
-- ====================================================================================
-- Straight column parity per the brief + walkthrough step 3. The one judgement call:
--
-- "A service cannot be booked until at least one staff member is assigned" is live-confirmed
-- (the warning banner clears the instant staff is assigned). I model this as a DERIVED VIEW
-- (public.service_bookable), NOT a constraint or a booking-time RAISE. Three reasons:
--   1. The single existing service row (1 row, live) has no staff assignment. A constraint
--      would make this migration fail, or would require me to invent an assignment for it.
--   2. The competitor's own behaviour is a WARNING, not an error — it lets the record exist
--      in a not-yet-bookable state. A CHECK would be stricter than the thing we are matching.
--   3. Booking-time enforcement belongs with the booking path (portal availability), which is
--      a later slice; putting a RAISE in a trigger now would break convert_booking_request
--      for exactly the service that exists today.
--   The view gives the UI its banner and gives the later booking slice its predicate.
--
-- deposit_cents is a column only. It records "this service requires a deposit of $X on
-- booking". Nothing in v11a or v11b CHARGES it — that needs a payments processor, which is
-- owner-deferred (UO-2). v11b's payments ledger can RECORD a deposit taken by hand (cash /
-- PayNow at the counter), which is the honest half we can ship today.
--
-- Style follows v2/v8/v9/v10: plpgsql SECURITY DEFINER + `set search_path = public`;
-- RPCs revoke from public, anon then grant to authenticated (anon only for portal RPCs).
-- RLS on every table. app.audit() dereferences BOTH new.id AND new.business_id, so every
-- audited table below carries both.

-- ====================================================================================
-- TENANT INTEGRITY — WHY COMPOSITE FOREIGN KEYS (the P0 this file previously shipped)
-- ====================================================================================
-- The first draft validated `business_id` on every new row and then never checked that the
-- row it POINTED AT belonged to the same tenant. Measured, rolled back, all five ACCEPTED:
--     staff_branches   A.staff  -> B.branch    ACCEPTED
--     staff_services   A.staff  -> B.service   ACCEPTED
--     service_branches A.service-> B.branch    ACCEPTED
--     sales.branch_id  A.sale   -> B.branch    ACCEPTED   <- becomes money in v11b
--     sales.staff_id   A.sale   -> B.staff     ACCEPTED   <- becomes a commission payout
-- A single-column FK only asks "does this id exist?" — never "does it exist IN MY TENANT?".
-- RLS does not save us either: the owner of A legitimately passes `is_salon_owner(A)`, and the
-- `with check` on a join table tests only ONE side of the join. And RLS is not enforced for
-- the table owner or service_role at all, which is exactly who runs migrations and cron.
--
-- THE FIX: carry business_id and let the ENGINE enforce the pairing.
--   * Every parent gets a redundant-looking `unique (id, business_id)`. `id` is already the
--     PK so this adds no new uniqueness — its ONLY job is to be a legal FK TARGET, because
--     Postgres requires a unique constraint over the exact referenced column list.
--   * Every reference then FKs the PAIR: (branch_id, business_id) -> branches(id, business_id).
--     A row can only point at a branch whose business_id equals its own. Mismatch is rejected
--     by the engine, in every role, from every code path, forever — no policy to get subtly
--     wrong, no trigger to forget, no RLS to bypass.
--   * Join tables therefore DO carry business_id now. The original comment said carrying it
--     "would be denormalised and could disagree with the parent". That reasoning is inverted:
--     it is precisely the composite FK to BOTH parents that makes disagreement IMPOSSIBLE.
--     The column is not a cached copy; it is the join key that proves the two sides match.
--
-- **v11a OWNS THE FIVE COMPOSITE UNIQUE KEYS BELOW. v11b CONSUMES THEM — do not redeclare.**
--
-- WHY NOT A TRIGGER for sales.branch_id / sales.staff_id: a trigger is code that runs, so it
-- can be disabled, can be skipped by `alter table ... disable trigger`, has to be re-derived
-- by every reader, and (on `sales`) would have to coexist with v10.1's immutability guard and
-- v11a's own branch-defaulting trigger in name order. The FK is declarative, is enforced
-- during backfills and restores, shows up in the schema diagram, and costs one index.
--
-- ⚠️ POSTGREST NOTE (learned from the v1.6 PGRST201 outage): a composite FK is a SECOND
--    foreign key between the same pair of tables if a single-column one already exists.
--    PostgREST then cannot resolve `select=...,staff(*)` and returns PGRST201 — the exact bug
--    app v1.6 had to hot-fix. Every FK added below REPLACES rather than supplements, so no
--    table pair ends up with two. This is also why appointments.staff_id / .service_id are NOT
--    hardened here even though they have the same defect — see the report.
-- ====================================================================================

begin;

-- ====================================================================================
-- 0. THE COMPOSITE UNIQUE KEYS (FK targets). v11a owns these; v11b consumes them.
--    Redundant for uniqueness (id is already the PK), load-bearing as FK targets.
-- ====================================================================================
alter table public.sales        add constraint sales_id_business_uk    unique (id, business_id);
alter table public.appointments add constraint appts_id_business_uk    unique (id, business_id);
alter table public.services     add constraint services_id_business_uk unique (id, business_id);
alter table public.staff        add constraint staff_id_business_uk    unique (id, business_id);
alter table public.clients      add constraint clients_id_business_uk  unique (id, business_id);
-- branches is created in §1.2 and carries its own uk inline (branches_id_business_uk).
--
-- NOTE (added by reviewer, 2026-07-17): `clients` was MISSING from this list and the omission
-- was a hard blocker, found only by running the literal three-file chain. v11b §2 declares
--   payments_client_same_tenant foreign key (client_id, business_id)
--     references public.clients(id, business_id)
-- and a composite FK requires a unique constraint over the exact referenced column list, so
-- v11b aborted with:
--   ERROR: there is no unique constraint matching given keys for referenced table "clients"
-- Neither author caught it: v11a's contract said "five keys" and v11b was reworked against a
-- SCAFFOLD of v11a rather than this file, because the two were written in parallel. The lesson
-- is recorded here rather than in a report: a contract between two migrations is not verified
-- until the real files are applied back-to-back in one transaction. Scaffolds agree with
-- whatever the author believed.
--
-- ⚠️ Adding this key means SIX composite unique keys, not five. Any future migration adding a
--    (x_id, business_id) FK must confirm its target is on THIS list first.

-- ====================================================================================
-- 1. BRANCHES
-- ====================================================================================

-- 1.1 Business-level tax default. ⚖️ A stored rate, not a compliance claim.
alter table public.businesses
  add column tax_rate_bps integer not null default 0
    check (tax_rate_bps >= 0 and tax_rate_bps <= 10000);

-- 1.2 The branch entity.
create table public.branches (
  id           uuid primary key default gen_random_uuid(),
  business_id  uuid not null references public.businesses(id) on delete cascade,
  name         text not null check (length(trim(name)) > 0),
  address      text,
  phone        text,
  email        text,
  -- NULL = inherit businesses.tax_rate_bps. 0 = a real override meaning "no tax here".
  -- The competitor's helper text is explicit about this and it is easy to get wrong:
  -- never coalesce this to 0 at the call site; use app.effective_tax_bps().
  tax_rate_bps integer check (tax_rate_bps >= 0 and tax_rate_bps <= 10000),
  timezone     text not null default 'Asia/Singapore',
  -- "Accepting bookings, shown on the public booking page" (live copy).
  active       boolean not null default true,
  -- Exactly one per business (unique partial index below). The backfilled home location.
  is_default   boolean not null default false,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  -- FK target for every (x_id, business_id) reference to a branch. See TENANT INTEGRITY.
  constraint branches_id_business_uk unique (id, business_id)
);

create unique index one_default_branch_per_business
  on public.branches (business_id) where is_default;
create index branches_business_active on public.branches (business_id, active);

alter table public.branches enable row level security;
create policy branches_select on public.branches for select to authenticated
  using (app.is_salon_member(business_id));
create policy branches_write on public.branches for all to authenticated
  using (app.is_salon_owner(business_id))
  with check (app.is_salon_owner(business_id));
revoke all on public.branches from anon;
grant select, insert, update, delete on public.branches to authenticated;

create trigger trg_branches_audit
  after insert or update or delete on public.branches
  for each row execute function app.audit();

-- branches.updated_at defaults at INSERT and would then be frozen forever — the column would
-- claim "last changed" while meaning "created". No touch_updated_at helper existed in this
-- schema (verified live: no such function in app or public), so v11a adds the generic one.
-- Written to be reusable and idempotent: any future table with an updated_at column can hang
-- this same trigger off it.
create or replace function app.touch_updated_at()
returns trigger language plpgsql set search_path = public as $$
begin
  new.updated_at := now();
  return new;
end $$;

create trigger trg_branches_touch
  before update on public.branches
  for each row execute function app.touch_updated_at();

-- 1.3 Per-day opening hours. Weekday follows JS Date.getDay(): 0=Sunday .. 6=Saturday.
--     A day with NO ROW is CLOSED. That is the whole model — there is no `closed` boolean,
--     because "closed" and "open 00:00-00:00" would otherwise both be representable and the
--     UI would have to pick. "Close all days" = delete the rows.
create table public.branch_hours (
  id          uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  branch_id   uuid not null references public.branches(id) on delete cascade,
  weekday     smallint not null check (weekday between 0 and 6),
  opens_at    time not null,
  closes_at   time not null,
  unique (branch_id, weekday),
  -- Same-day trading only. An overnight bar (22:00-02:00) cannot be expressed and will need
  -- a deliberate model change (two rows, or a crosses_midnight flag). Flagged, not guessed:
  -- the beachhead is F&B cafes and the observed default is 09:00-17:00.
  check (closes_at > opens_at)
);
create index branch_hours_branch on public.branch_hours (branch_id, weekday);

alter table public.branch_hours enable row level security;
create policy branch_hours_select on public.branch_hours for select to authenticated
  using (app.is_salon_member(business_id));
create policy branch_hours_write on public.branch_hours for all to authenticated
  using (app.is_salon_owner(business_id))
  with check (app.is_salon_owner(business_id));
revoke all on public.branch_hours from anon;
grant select, insert, update, delete on public.branch_hours to authenticated;

-- 1.4 Breaks within a trading day ("Add break", live-confirmed — plural per day).
--     Separate table, not columns, because the count is unbounded.
create table public.branch_breaks (
  id          uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  branch_id   uuid not null references public.branches(id) on delete cascade,
  weekday     smallint not null check (weekday between 0 and 6),
  starts_at   time not null,
  ends_at     time not null,
  check (ends_at > starts_at)
);
create index branch_breaks_branch on public.branch_breaks (branch_id, weekday);
-- NOTE: overlapping breaks on the same weekday are NOT prevented. An exclusion constraint
-- would need btree_gist over (branch_id, weekday, timerange). Deliberately deferred — it is
-- a UI validation today and a cosmetic data-quality issue, not a money-correctness one.

alter table public.branch_breaks enable row level security;
create policy branch_breaks_select on public.branch_breaks for select to authenticated
  using (app.is_salon_member(business_id));
create policy branch_breaks_write on public.branch_breaks for all to authenticated
  using (app.is_salon_owner(business_id))
  with check (app.is_salon_owner(business_id));
revoke all on public.branch_breaks from anon;
grant select, insert, update, delete on public.branch_breaks to authenticated;

-- 1.5 Resolution helpers.
create or replace function app.default_branch(p_business uuid)
returns uuid language sql stable security definer set search_path = public as $$
  select id from public.branches
   where business_id = p_business and is_default
   limit 1
$$;

-- ⚖️ Rate resolution ONLY. Not a tax calculation, not a compliance statement.
create or replace function app.effective_tax_bps(p_branch uuid)
returns integer language sql stable security definer set search_path = public as $$
  select coalesce(br.tax_rate_bps, b.tax_rate_bps)   -- NULL override inherits; 0 does not.
  from public.branches br
  join public.businesses b on b.id = br.business_id
  where br.id = p_branch
$$;

-- 1.6 BACKFILL: one default branch per existing business. This is THE backward-compatibility
--     move for the 2 live businesses. Named for what it is so the owner can rename it.
--     THE GUARD KEYS ON is_default, NOT ON MERE EXISTENCE. `where not exists (… x.business_id
--     = b.id)` reads as "has a default branch" and actually means "has ANY branch". A business
--     holding only a NON-default branch would be skipped, would never get a default, and
--     app.default_branch() would return NULL for it forever. §1.8's trigger is deliberately
--     fail-soft, so the failure is SILENT: every subsequent sale lands with branch_id = NULL
--     and is unattributed — no error, no log line, and in v11b no cash drawer. Measured with
--     the old predicate (rolled back): default_branch(C) = NULL, and a new sale for C came out
--     branch_id = NULL. With `and x.is_default` both are correct.
--     It is also what makes this statement idempotent and safe to re-run.
insert into public.branches (business_id, name, is_default, active)
select b.id, b.name, true, true
from public.businesses b
where not exists (select 1 from public.branches x
                   where x.business_id = b.id and x.is_default);

-- 1.7 Wire the transactional tables to a branch. NULLABLE + trigger-defaulted, never NOT NULL
--     (see the header: five unmodified writers of `sales` depend on this).
--     ON DELETE: **restrict, NOT set null.** `set null` means deleting a branch silently
--     un-attributes every historical sale and appointment it ever hosted — the revenue is
--     still counted but belongs to nobody, and in v11b the branch's cash drawer detaches from
--     its own takings. That is history destruction dressed up as referential tidiness, and it
--     happens on a single click with no warning. There is already a correct retire path:
--     `branches.active = false` ("no longer accepting bookings"), which keeps every historical
--     row attributed. So a branch with history must not be deletable, and restrict says so.
--     Same argument, same severity for sales.staff_id: deleting a staff member must not erase
--     who earned the commission. `staff.active = false` (added in §2.1) is that retire path.
--
--     ⚠️ RESTRICT vs NO ACTION — a real interaction, tested rather than assumed. Both `sales`
--     and `branches` cascade-delete from `businesses`. RESTRICT is checked IMMEDIATELY and
--     cannot see that the referencing sales rows are about to be cascade-deleted in the same
--     statement, so `delete from businesses` would fail. NO ACTION defers the check to the end
--     of the statement, by which time the cascade has removed the children, so tenant deletion
--     still works while a bare `delete from branches` is still refused. NO ACTION is therefore
--     strictly better here and gives the identical protection. Verified both ways — see the
--     test scenarios. (Note `references` with no action clause = NO ACTION; it is spelled out
--     below so nobody reads the absence as an oversight.)
alter table public.appointments add column branch_id uuid;
alter table public.appointments add constraint appointments_branch_fk
  foreign key (branch_id, business_id) references public.branches(id, business_id)
  on delete no action;
alter table public.sales add column branch_id uuid;
alter table public.sales add constraint sales_branch_fk
  foreign key (branch_id, business_id) references public.branches(id, business_id)
  on delete no action;
-- Commission + "which staff rang this up" attribution. sales had no staff link at all.
alter table public.sales add column staff_id uuid;
alter table public.sales add constraint sales_staff_fk
  foreign key (staff_id, business_id) references public.staff(id, business_id)
  on delete no action;

create index appointments_branch on public.appointments (branch_id, starts_at);
create index sales_branch on public.sales (branch_id, occurred_at);
create index sales_staff on public.sales (staff_id, occurred_at);

-- appointments has no immutability guard, so this one needs no window. Verified.
update public.appointments a
   set branch_id = app.default_branch(a.business_id)
 where a.branch_id is null;

--     `sales` IS append-only as of v10.1, so this backfill MUST run inside v10.1's named,
--     audited window. Without it the statement raises 'sales is append-only: UPDATE is not
--     permitted' and the migration aborts — measured, not assumed. The window permits ONLY
--     columns that did not exist in v10.1 to move; amount_cents, kind and the whole policy
--     snapshot stay frozen even while it is open, and it is transaction-local so it cannot
--     outlive this migration even if end_sales_backfill() is never reached.
select app.begin_sales_backfill('frenly_v11a_branches_staff_services',
         'populate the new sales.branch_id column on pre-branch historical rows');
update public.sales s
   set branch_id = app.default_branch(s.business_id)
 where s.branch_id is null;
select app.end_sales_backfill();

-- 1.8 The compatibility trigger. Any INSERT that omits branch_id lands on the default branch.
--     BEFORE INSERT, so it cannot interact with the AFTER INSERT loyalty trigger
--     (app.on_sale_recorded) or the AFTER INSERT stock trigger (app.on_sale_stock_deduct).
--     A business with no default branch (impossible after 1.6 + 1.9, but fail-soft) simply
--     gets a null branch_id — inserts must never start failing because of this migration.
create or replace function app.set_row_branch()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.branch_id is null then
    new.branch_id := app.default_branch(new.business_id);
  end if;
  return new;
end $$;

create trigger trg_sales_default_branch
  before insert on public.sales
  for each row execute function app.set_row_branch();
create trigger trg_appointments_default_branch
  before insert on public.appointments
  for each row execute function app.set_row_branch();

-- 1.9 New businesses must get a default branch too, or 1.8 silently no-ops for them forever.
--     ONLY an added branches insert. The staff/loyalty_programs/audit_log inserts and the
--     row_to_json(rec) return shape are preserved byte-for-byte — the onboarding UI depends
--     on that shape.
create or replace function public.create_business(p_name text, p_slug text, p_industry text, p_modules text[])
returns json language plpgsql security definer set search_path = public as $$
declare v_uid uuid; rec businesses; v_staff uuid; v_branch uuid;
begin
  v_uid := auth.uid();
  if v_uid is null then raise exception 'sign in required'; end if;
  if p_name is null or length(trim(p_name)) < 2 then raise exception 'business name required'; end if;
  insert into businesses (name, slug, industry, enabled_modules)
  values (trim(p_name), p_slug, coalesce(p_industry,'other'),
          coalesce(p_modules, array['dashboard','clients','sales','loyalty','retention','referrals']))
  returning * into rec;
  insert into staff (business_id, user_id, role, full_name)
  values (rec.id, v_uid, 'owner', coalesce(auth.jwt()->>'email','Owner'))
  returning id into v_staff;
  -- v11a: every business owns exactly one default branch from birth. Without this, the
  -- BEFORE INSERT branch trigger would resolve to null for every new tenant and the cash
  -- drawer (v11b, per-branch) would have nothing to attach to.
  insert into branches (business_id, name, is_default, active)
  values (rec.id, trim(p_name), true, true)
  returning id into v_branch;
  -- ...and the founding owner works at it. §2.6 backfills exactly this for every EXISTING
  -- staff row; without the same line here, tenants created after v11a would be the only ones
  -- whose owner is assigned to no branch — a difference that would surface later as an empty
  -- rota for new signups only, which is a miserable bug to find.
  insert into staff_branches (business_id, staff_id, branch_id)
  values (rec.id, v_staff, v_branch);
  insert into loyalty_programs (business_id, kind, earn_points_per_dollar,
                                redeem_points, reward_credit_cents, active)
  values (rec.id, 'points', 1, 800, 2000, true);
  insert into audit_log (business_id, actor, action, entity, entity_id, detail)
  values (rec.id, v_uid, 'ONBOARD', 'businesses', rec.id,
          json_build_object('name', rec.name, 'industry', rec.industry)::jsonb);
  return row_to_json(rec);
end $$;
revoke execute on function public.create_business(text, text, text, text[]) from public, anon;
grant execute on function public.create_business(text, text, text, text[]) to authenticated;

-- ====================================================================================
-- 2. STAFF
-- ====================================================================================

-- 2.1 THE UNBLOCK. See the header for the full safety argument; the one-line version is that
--     `s.user_id = auth.uid()` is NULL (never true) for a null user_id, so a rota staff row
--     is not a principal and grants nothing.
alter table public.staff
  alter column user_id drop not null;

alter table public.staff
  add column email                  text,
  add column phone                  text,
  add column title                  text,
  -- Calendar colour (live-confirmed field). Hex, validated — the calendar renders it raw.
  add column calendar_color         text not null default '#7C9CBF'
    check (calendar_color ~ '^#[0-9A-Fa-f]{6}$'),
  add column active                 boolean not null default true,
  -- Two-rate split, live-confirmed. Basis points; NULL = unset (falls through to 0),
  -- 0 = an explicit "no commission". Do not coalesce these at the call site.
  add column commission_service_bps integer check (commission_service_bps between 0 and 10000),
  add column commission_product_bps integer check (commission_product_bps between 0 and 10000),
  -- "Commission starts on" — sales before this date earn no commission. NULL = no start
  -- gate (commission applies from the beginning of time), matching a blank field.
  add column commission_starts_on   date;

create index staff_business_active on public.staff (business_id, active);

-- staff has no audit trigger today and now holds commission rates, which are a sensitive,
-- disputable, money-adjacent fact. Add one. (staff already has id + business_id, which is
-- what app.audit() dereferences.)
create trigger trg_staff_audit
  after insert or update or delete on public.staff
  for each row execute function app.audit();

-- 2.2 Staff <-> branch. Many-to-many: the competitor's Branches tab is a checkbox LIST.
-- business_id is present and NOT NULL, and BOTH sides are pinned to it by composite FK. The
-- staff member and the branch must therefore belong to the same tenant as this row — the
-- engine rejects any other combination. See TENANT INTEGRITY in the header for why the
-- original "join tables carry no business_id" reasoning was backwards.
-- Still no audit trigger: app.audit() dereferences new.id, which a composite-PK join table
-- does not have. (business_id now exists, so that half of the old objection is gone.)
create table public.staff_branches (
  business_id uuid not null references public.businesses(id) on delete cascade,
  staff_id    uuid not null,
  branch_id   uuid not null,
  primary key (staff_id, branch_id),
  foreign key (staff_id,  business_id) references public.staff(id, business_id)    on delete cascade,
  foreign key (branch_id, business_id) references public.branches(id, business_id) on delete cascade
);
create index staff_branches_business on public.staff_branches (business_id);
alter table public.staff_branches enable row level security;
-- Now a direct business_id test instead of a subquery through one side of the join. Defence in
-- depth only — the composite FKs above are what actually make cross-tenant rows impossible.
create policy staff_branches_all on public.staff_branches for all to authenticated
  using (app.is_salon_member(business_id))
  with check (app.is_salon_owner(business_id));
revoke all on public.staff_branches from anon;
grant select, insert, update, delete on public.staff_branches to authenticated;

-- 2.3 Staff <-> service ("Staff who perform this" / the Services tab).
--     This is the table that makes a service bookable (see service_bookable, §3.3).
create table public.staff_services (
  business_id uuid not null references public.businesses(id) on delete cascade,
  staff_id    uuid not null,
  service_id  uuid not null,
  primary key (staff_id, service_id),
  foreign key (staff_id,   business_id) references public.staff(id, business_id)    on delete cascade,
  foreign key (service_id, business_id) references public.services(id, business_id) on delete cascade
);
create index staff_services_business on public.staff_services (business_id);
alter table public.staff_services enable row level security;
create policy staff_services_all on public.staff_services for all to authenticated
  using (app.is_salon_member(business_id))
  with check (app.is_salon_owner(business_id));
revoke all on public.staff_services from anon;
grant select, insert, update, delete on public.staff_services to authenticated;

-- 2.4 Working hours. Same shape and same no-row-means-off rule as branch_hours.
create table public.staff_hours (
  id          uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  staff_id    uuid not null references public.staff(id) on delete cascade,
  weekday     smallint not null check (weekday between 0 and 6),
  starts_at   time not null,
  ends_at     time not null,
  unique (staff_id, weekday),
  check (ends_at > starts_at)
);
create index staff_hours_staff on public.staff_hours (staff_id, weekday);
alter table public.staff_hours enable row level security;
create policy staff_hours_select on public.staff_hours for select to authenticated
  using (app.is_salon_member(business_id));
create policy staff_hours_write on public.staff_hours for all to authenticated
  using (app.is_salon_owner(business_id))
  with check (app.is_salon_owner(business_id));
revoke all on public.staff_hours from anon;
grant select, insert, update, delete on public.staff_hours to authenticated;

-- 2.5 Team off-days (leave / MC / public holiday). Date RANGE, not one row per day: a
--     two-week holiday is one record the owner can cancel in one action.
create table public.staff_off_days (
  id          uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  staff_id    uuid not null references public.staff(id) on delete cascade,
  starts_on   date not null,
  ends_on     date not null,          -- inclusive
  reason      text,
  created_at  timestamptz not null default now(),
  check (ends_on >= starts_on)
);
create index staff_off_days_staff on public.staff_off_days (staff_id, starts_on, ends_on);
-- NOTE: overlapping off-day ranges for the same staff member are NOT prevented — the same
-- deliberate omission as branch_breaks above, documented here because it was previously
-- silent. Preventing it needs an exclusion constraint over (staff_id, daterange) with
-- btree_gist. DELIBERATELY DEFERRED, and the reason is stronger here than for breaks:
-- overlapping leave is not even wrong. "MC 3-5 Aug" overlapping "Annual leave 1-10 Aug" is a
-- normal way to record two real, separately-cancellable facts about the same days. The
-- consumer is a UNION ("is this staff member off on date D?" = `exists (… starts_on <= D and
-- ends_on >= D)`), which is already overlap-correct and idempotent. Overlap only matters if a
-- future leave-BALANCE report double-counts days — that report does not exist (timesheets and
-- payroll are out of v11a; see WHAT v11a DELIBERATELY LEAVES OUT) and whoever builds it must
-- count distinct DAYS, not sum range lengths. Flagged there rather than constrained here.
alter table public.staff_off_days enable row level security;
create policy staff_off_days_select on public.staff_off_days for select to authenticated
  using (app.is_salon_member(business_id));
create policy staff_off_days_write on public.staff_off_days for all to authenticated
  using (app.is_salon_owner(business_id))
  with check (app.is_salon_owner(business_id));
revoke all on public.staff_off_days from anon;
grant select, insert, update, delete on public.staff_off_days to authenticated;
create trigger trg_staff_off_days_audit
  after insert or update or delete on public.staff_off_days
  for each row execute function app.audit();

-- 2.6 BACKFILL: existing staff belong to their business's default branch.
insert into public.staff_branches (business_id, staff_id, branch_id)
select s.business_id, s.id, app.default_branch(s.business_id)
from public.staff s
where app.default_branch(s.business_id) is not null
on conflict do nothing;

-- ====================================================================================
-- 3. SERVICES
-- ====================================================================================

alter table public.services
  add column description           text,
  add column category              text,
  -- Per-service "require a deposit on booking". RECORDED, never charged (see header).
  add column deposit_cents         integer not null default 0 check (deposit_cents >= 0),
  -- "Mid-booking wait — resources stay held" (live copy). Booking availability does not
  -- consume this yet; the resources module is not wired to availability (FL-RES, PARTIAL).
  add column processing_time_min   integer not null default 0 check (processing_time_min >= 0),
  add column buffer_before_min     integer not null default 0 check (buffer_before_min >= 0),
  add column buffer_after_min      integer not null default 0 check (buffer_after_min >= 0),
  -- "Overrides each staff member's default for this service. Leave blank to fall through."
  -- NULLABLE is the whole point. 0 = an explicit zero-commission service.
  add column commission_bps        integer check (commission_bps between 0 and 10000),
  add column show_on_booking_page  boolean not null default true,
  add column apply_tax             boolean not null default true;

create index services_business_active on public.services (business_id, active);

-- 3.1 Service <-> branch ("Offered at branches", defaulted to "All branches").
create table public.service_branches (
  business_id uuid not null references public.businesses(id) on delete cascade,
  service_id  uuid not null,
  branch_id   uuid not null,
  primary key (service_id, branch_id),
  foreign key (service_id, business_id) references public.services(id, business_id) on delete cascade,
  foreign key (branch_id,  business_id) references public.branches(id, business_id) on delete cascade
);
create index service_branches_business on public.service_branches (business_id);
alter table public.service_branches enable row level security;
-- WRITE IS NOW is_salon_owner, NOT is_salon_member. The original used `member` on the with
-- check while every sibling policy in this file (branches_write, branch_hours_write,
-- staff_branches, staff_services, staff_hours_write, staff_off_days_write) used `owner`. That
-- was a copy-paste slip with teeth: any stylist could rewire which branches offer which
-- services — i.e. silently take a service off sale at a location, or put it on sale at one
-- that cannot deliver it. Read stays `member`: everyone needs to see the catalog.
--
-- WHY is_salon_owner AND NOT app.has_perm() — the one place I did not follow the pinned shape:
-- v10.1's permission vocabulary is deliberately SALES-only (view_sales, create_sales,
-- refund_sales, reclassify_sales, view_finance, manage_sale_policy). None of the six describes
-- "may rewire the service catalog", so has_perm() cannot express this gate without a SEVENTH
-- permission (`manage_catalog`) — and adding one means v11a issuing a CREATE OR REPLACE over
-- app.role_perms(), an object v10.1 owns. That fork is the worse bug: v11a's copy would
-- silently win on apply order, so any later edit to v10.1's list would be reverted by
-- re-running v11a, with no error. v11a must not own v10.1's permission model.
-- So: is_salon_owner, which is exactly what every sibling uses and is what has_perm('owner')
-- would resolve to today anyway (all live staff are role='owner'; verified). If Fable wants
-- the permission model extended, the right move is `manage_catalog` added to role_perms in
-- v10.1, and then these three catalog policies become a one-line swap to
-- app.has_perm(business_id, 'manage_catalog'). Flagged in the report, not done here.
create policy service_branches_all on public.service_branches for all to authenticated
  using (app.is_salon_member(business_id))
  with check (app.is_salon_owner(business_id));
revoke all on public.service_branches from anon;
grant select, insert, update, delete on public.service_branches to authenticated;

-- 3.2 BACKFILL: existing services are offered at the default branch.
insert into public.service_branches (business_id, service_id, branch_id)
select s.business_id, s.id, app.default_branch(s.business_id)
from public.services s
where app.default_branch(s.business_id) is not null
on conflict do nothing;

-- 3.3 "This service can't be booked yet. Assign at least one staff member."
--     Derived, not enforced — see the header for why (the 1 live service has no staff and a
--     constraint would either fail this migration or force me to invent an assignment).
--     security_invoker so the caller's RLS applies rather than the view owner's.
--
--     TWO BUGS FIXED HERE, both measured:
--
--     (1) CARTESIAN FAN-OUT. staff_services and service_branches are two INDEPENDENT one-to-
--         many joins off the same row, so they MULTIPLY: 2 staff x 2 branches produced
--         staff_count = 4 and branch_count = 4, not 2 and 2. (In the actual repro it read 6
--         and 6, because a cross-tenant service_branches row — D1.3 — was in the mix too.)
--         `count(distinct ...)` collapses the duplicate rows the join manufactures. The
--         `bookable` flag survived by luck alone: 4 > 0 and 2 > 0 are both true. The COUNTS
--         are what the UI renders ("2 staff assigned"), and they were simply wrong.
--
--     (2) staff.active WAS IGNORED. v11a adds the column and then never reads it, so a
--         service whose only assigned staff had all been deactivated still reported
--         bookable = true and the booking page would offer a slot nobody can work. Joining
--         `staff` and counting only active rows fixes it: an inactive staff member yields a
--         NULL st.id, and count(distinct st.id) does not count NULLs.
--
--     NOTE ON SEMANTICS: staff_count now means ACTIVE assigned staff, which is the number the
--     warning banner is actually about. A service with 3 assigned stylists, all deactivated,
--     reads staff_count = 0, bookable = false — correct, and the UI needs no extra logic.
create view public.service_bookable
with (security_invoker = on) as
select s.id                                as service_id,
       s.business_id,
       s.active,
       s.show_on_booking_page,
       count(distinct st.id)               as staff_count,
       count(distinct sb.branch_id)        as branch_count,
       (s.active
        and count(distinct st.id) > 0)     as bookable
from public.services s
left join public.staff_services  ss on ss.service_id = s.id
left join public.staff           st on st.id = ss.staff_id and st.active
left join public.service_branches sb on sb.service_id = s.id
group by s.id, s.business_id, s.active, s.show_on_booking_page;

revoke all on public.service_bookable from anon;
grant select on public.service_bookable to authenticated;

commit;

-- ------------------------------------------------------------------------------------
-- WHAT v11a DELIBERATELY LEAVES OUT
-- ------------------------------------------------------------------------------------
--  * Timesheets (FL-STAFF sub-page). Clock-in/out is an attendance ledger with its own
--    correctness surface (overlap, forgotten clock-outs, overnight shifts) and it feeds
--    payroll, which is UO-1 and unapproved. staff_hours (the ROSTER — what they are
--    scheduled to work) is here; the TIMESHEET (what they actually worked) is not. They are
--    different tables and conflating them would be the kind of quiet wrong this file exists
--    to avoid.
--  * Booking-availability computation. branch_hours + branch_breaks + staff_hours +
--    staff_off_days + processing_time + buffers are now all recorded, but nothing READS them
--    to produce bookable slots. That is a real engine (overlap detection, resource holds,
--    timezone/DST) and belongs in its own slice with its own tests. v11a is the data
--    foundation for it, per the brief's "foundation layer only".
--  * Overnight trading hours (closes_at > opens_at is enforced). Flagged inline.
--  * Service Variants tab, CSV in/out, per-service resource requirements: not in the brief's
--    §3 list, and Variants in particular changes the price model.
--  * Deposit CHARGING (UO-2, owner-deferred processor).
--  * Any payroll/commission REPORT. Rates only.
--  * Hardening of the PRE-EXISTING appointments.staff_id / appointments.service_id /
--    sales.appointment_id / sales.product_id single-column FKs. They have EXACTLY the D1
--    cross-tenant defect this file fixes elsewhere, and the composite unique keys in §0 now
--    make the fix a two-line change. NOT DONE HERE, deliberately, for one concrete reason:
--    adding `foreign key (staff_id, business_id) references staff(id, business_id)` alongside
--    the existing `appointments_staff_id_fkey` gives that table pair TWO foreign keys, and
--    PostgREST then cannot resolve an embed — PGRST201, the exact production blocker app v1.6
--    had to hot-fix on `appointments -> services`. Doing it safely means DROPPING the old FK
--    and re-pinning every `select=…` embed in app/index.html in the same change. That is a
--    coordinated schema+UI change, not a v11a foundation edit, and this file is forbidden from
--    touching the UI. Live data is currently clean (0 cross-tenant rows on all three;
--    verified), so this is a latent hole, not an active one. REPORTED for its own slice.
-- ------------------------------------------------------------------------------------

-- ------------------------------------------------------------------------------------
-- FOUND WHILE FIXING THIS FILE — NOT v11a's TO FIX, RECORDED SO IT IS NOT LOST
-- ------------------------------------------------------------------------------------
--  ⚖️ TENANT DELETION IS NOW IMPOSSIBLE FOR ANY TENANT THAT HAS EVER RUNG UP A SALE.
--     `delete from businesses where id = <tenant with sales>` fails with
--         ERROR: sales is append-only: DELETE is not permitted (sale d48fa119-…)
--     Measured, rolled back. This is v10.1's immutability guard refusing the ON DELETE CASCADE
--     from businesses -> sales; it has nothing to do with v11a's foreign keys (a tenant with
--     NO sales still deletes cleanly under them — asserted). v10.1 reasoned about a user
--     DELETEing a sale directly and correctly forbade it; it did not consider that the same
--     trigger also blocks a cascade the schema has always allowed.
--     Why it matters beyond tidiness: PDPA erasure. "Delete my business and all its data" is
--     a request an SME can legitimately make, and today the only paths are to drop the guard
--     or to leave the tenant's rows in place. Neither is a decision for this file.
--     Whoever owns it (v10.1 or v11b) needs an explicit, audited tenant-purge path — the same
--     shape as begin_sales_backfill(): a named, reasoned, transaction-local window. Flagged
--     under the production-write approval gate; NOT actioned here. ⚖️ counsel for the PDPA half.
-- ------------------------------------------------------------------------------------

-- ------------------------------------------------------------------------------------
-- MANUAL TEST SCENARIOS — v11a
-- ------------------------------------------------------------------------------------
-- Scenario A — The backfill is complete and each business is self-consistent:
--   1. select count(*) from branches where is_default;                  -> 2 (one per business)
--   2. select business_id, count(*) from branches where is_default group by 1;
--      -> every row count = 1. Then try to force a second:
--      insert into branches (business_id, name, is_default) values ('<biz>','Dup', true);
--      -> rejected by one_default_branch_per_business.
--   3. select count(*) from sales where branch_id is null;              -> 0  (was 6)
--      select count(*) from appointments where branch_id is null;       -> 0  (was 3)
--   4. Every backfilled sale's branch must belong to that sale's OWN business — the
--      cross-tenant assertion that a naive backfill gets wrong:
--      select count(*) from sales s join branches b on b.id = s.branch_id
--       where b.business_id <> s.business_id;                           -> 0
--      Repeat for appointments, staff_branches (via staff), service_branches (via services).
--   5. select count(*) from staff_branches;   -> 2 (both live staff -> their default branch)
--      select count(*) from service_branches; -> 1 (the one live service)
--
-- Scenario B — THE COMPATIBILITY TRIGGER (most valuable test in this file). Every legacy
--              writer of `sales` is unmodified and must still work AND come out branched:
--   1. select public.issue_gift_card('<biz>', 2500, '<C>', null);
--      -> new sales row: kind='gift_card', branch_id = app.default_branch('<biz>') (NOT null).
--         points_ledger for C unchanged (v9 intact — the branch trigger must not have
--         perturbed the AFTER INSERT loyalty trigger).
--   2. select public.enroll_membership('<biz>','<C>','<plan>');   -> branch_id set, 0 points.
--   3. select public.sell_package('<biz>','<C>','<plan>');        -> branch_id set.
--   4. select public.use_package_session('<biz>','<cp>');         -> branch_id set on the $0 row.
--   5. select app.run_membership_renewals();  (with a due membership)
--      -> renewal sales row has branch_id set. This one is easy to miss: it inserts from a
--         cron context with no auth.uid(), and app.default_branch is SECURITY DEFINER
--         precisely so it does not depend on the caller.
--   6. A raw UI-style insert with NO branch_id:
--      insert into sales (business_id, client_id, kind, amount_cents)
--        values ('<biz>','<C>','quick_sale', 5000);
--      -> branch_id = default branch; 50 points still earned. NOTHING about loyalty moved.
--   7. An EXPLICIT branch_id must be respected, not overwritten:
--      insert into sales (business_id, client_id, kind, amount_cents, branch_id)
--        values ('<biz>','<C>','quick_sale', 100, '<second branch>');
--      -> branch_id = the second branch.
--
-- Scenario C — Tax inheritance. 0 must survive as an override; NULL must inherit:
--   1. update businesses set tax_rate_bps = 900 where id = '<biz>';   -- 9% GST-style rate
--   2. Branch with tax_rate_bps = NULL  -> app.effective_tax_bps(branch) = 900   (inherits)
--   3. update branches set tax_rate_bps = 0     -> app.effective_tax_bps = 0     (NOT 900)
--      ^ THE assertion. A coalesce(branch, business) written the wrong way round, or any
--        `nullif(rate,0)`, returns 900 here and silently taxes a tax-free branch.
--   4. update branches set tax_rate_bps = 700   -> app.effective_tax_bps = 700
--   5. update branches set tax_rate_bps = 10001 -> rejected by the check constraint.
--
-- Scenario D — Nullable staff.user_id grants NOTHING (the tenant-isolation assertion):
--   1. insert into staff (business_id, user_id, role, full_name)
--        values ('<biz>', null, 'stylist', 'Rota Only');            -> accepted.
--   2. select app.is_salon_member('<biz>');  as a signed-in NON-member -> false.
--      select app.is_salon_owner('<biz>');   as a signed-in NON-member -> false.
--      Creating the null-user_id row above must NOT have made anyone a member.
--   3. THE SUBTLE ONE — as an ANON/unauthenticated caller (auth.uid() IS NULL):
--      select app.is_salon_member('<biz>');  -> MUST be false, not true.
--      A null user_id row plus a null auth.uid() is `null = null` -> NULL -> exists() sees
--      no row -> false. Verify it rather than trusting the reasoning: if this ever returns
--      true, every tenant in the system is readable by the public portal key.
--   4. Add a SECOND null-user_id staff row for the same business -> accepted (NULLs are
--      distinct in staff_salon_id_user_id_key). Two real users with the same user_id in one
--      business -> still rejected.
--
-- Scenario E — service_bookable mirrors the live warning banner:
--   1. The existing service (no staff assigned) -> bookable = false, staff_count = 0.
--      This is the pre-state that made a CHECK constraint impossible.
--   2. insert into staff_services (business_id, staff_id, service_id) values (…);
--      -> bookable = true, staff_count = 1. Flips immediately, matching "the warning
--         disappeared the instant a staff member was checked".
--   3. update services set active = false -> bookable = false even with staff assigned.
--   4. delete from staff_services ... -> bookable = false again.
--   5. NO CARTESIAN FAN-OUT (D2). Assign 2 staff AND 2 branches to one service:
--      -> staff_count = 2 and branch_count = 2. Before count(distinct …) this read 4 and 4.
--         The pre-fix numbers are the PRODUCT of the two joins, so the bug only appears once
--         BOTH sides have >1 row — a single-staff, single-branch test passes either way and
--         proves nothing. This assertion must use 2 x 2 or it is worthless.
--   6. staff.active IS READ (D3). One service, one assigned staff, then:
--      update staff set active = false where id = '<the only assigned staff>';
--      -> staff_count = 0, bookable = false. Before, this reported bookable = true and the
--         booking page would sell a slot that nobody is employed to work.
--   7. Re-activate -> bookable = true again (the flag is read live, not cached).
--
-- Scenario F — Hours + off-days constraints:
--   1. insert branch_hours (branch, weekday 0, 09:00, 17:00)              -> accepted.
--   2. Same (branch, weekday 0) again                                     -> rejected (unique).
--   3. branch_hours (branch, weekday 0, 22:00, 02:00)                     -> rejected
--      (closes_at > opens_at). This is the documented overnight limitation, asserted so it
--      is a known refusal rather than a surprise.
--   4. weekday = 7                                                        -> rejected.
--   5. staff_off_days ends_on < starts_on                                 -> rejected.
--      staff_off_days starts_on = ends_on (single day off)                -> accepted.
--
-- Scenario G — RLS + grants:
--   1. As a NON-owner member (role='stylist'): select from branches -> visible;
--      update branches set name='x' -> 0 rows / denied (branches_write is is_salon_owner).
--      Same for branch_hours, staff, staff_hours, staff_off_days.
--   2. As a member of business X: select from branches -> only X's branches.
--   3. As anon (publishable key): select from branches / branch_hours / staff_branches /
--      service_branches / service_bookable -> permission denied on all.
--   4. service_branches write is is_salon_owner, not is_salon_member (D4). As role='stylist':
--      insert into service_branches -> denied. Under the original policy this SUCCEEDED.
--
-- Scenario H — TENANT INTEGRITY IS ENFORCED BY THE ENGINE (D1). Every one of these was
--              ACCEPTED before the composite FKs and must now RAISE
--              'insert or update on table "…" violates foreign key constraint'. Run them as
--              the TABLE OWNER / service_role, not as `authenticated` — that is the whole
--              point. RLS does not apply to those roles, so a test that passes only under RLS
--              proves nothing about migrations, cron, or the SQL editor:
--   1. insert into staff_branches (business_id, staff_id, branch_id)
--        values (A, A_staff, B_branch);                                   -> FK violation.
--   2. insert into staff_services (business_id, staff_id, service_id)
--        values (A, A_staff, B_service);                                  -> FK violation.
--   3. insert into service_branches (business_id, service_id, branch_id)
--        values (A, A_service, B_branch);                                 -> FK violation.
--   4. insert into sales (business_id, kind, amount_cents, branch_id)
--        values (A, 'quick_sale', 500, B_branch);                         -> FK violation.
--   5. insert into sales (business_id, kind, amount_cents, staff_id)
--        values (A, 'quick_sale', 500, B_staff);                          -> FK violation.
--   6. The SAME-tenant versions of all five must still be ACCEPTED — a constraint that
--      rejects everything is not tenant isolation, it is an outage.
--   7. NULL branch_id / staff_id must remain legal (MATCH SIMPLE: any NULL in the FK column
--      list skips the check). This is what keeps the five unmodified `sales` writers working.
--
-- Scenario I — HISTORY SURVIVES A BRANCH RETIREMENT (D5):
--   1. delete from branches where id = <a branch with sales>  -> FK violation, refused.
--      Under `on delete set null` this SUCCEEDED and silently orphaned the revenue.
--   2. update branches set active = false                     -> accepted (the retire path),
--      and every historical sale keeps its branch_id.
--   3. delete from businesses where id = <a tenant with NO sales> -> STILL WORKS. This is the
--      assertion that justifies `no action` over `restrict`: the cascade removes appointments
--      and branches in one statement, and only `no action` defers the check long enough to see
--      it. Under `restrict` this raises and tenant deletion is dead.
--   4. delete from businesses where id = <a tenant WITH sales> -> blocked, but NOT by anything
--      in this file: 'sales is append-only: DELETE is not permitted'. v10.1's guard refuses the
--      cascade. Verified. So tenant deletion is already impossible for any tenant that has ever
--      rung up a sale, regardless of v11a's FK choice. ⚖️ That is a PDPA erasure problem and it
--      belongs to v10.1/v11b, not here — REPORTED, not fixed. Noted so the next reader does not
--      "fix" it by weakening these FKs, which would not help.
--
-- Scenario J — branches.updated_at is maintained:
--   1. update branches set updated_at = '2000-01-01' where id = <branch>;
--      -> reading it back gives now(), NOT 2000: the trigger overrides the caller.
--      ⚠️ DO NOT assert `updated_at > created_at` inside a single transaction — that test
--      CANNOT PASS and does not mean the trigger is broken. now() is the TRANSACTION
--      timestamp, so a row inserted and updated in one txn has updated_at = created_at
--      exactly, and pg_sleep() does not advance it. (This bit me while writing these tests:
--      the first run reported 'FROZEN' against a trigger that was firing perfectly.) Use the
--      poison-value assertion above, or clock_timestamp(), or two transactions.
-- ------------------------------------------------------------------------------------
