-- nestly_v309_ledger_programme_tag
--
-- WAVE 3 of the four-programme independence plan
-- (docs/design/FOUR-PROGRAMME-INDEPENDENCE-PLAN.md §6, owner approval 2026-08-13).
--
-- WHAT THIS IS. The programme TAG on the money tables: public.points_ledger and
-- public.points_batches each gain a nullable programme_id pointing at the W2 spine
-- (public.business_programmes), every existing row is backfilled, and a BEFORE INSERT trigger
-- tags every new row from the BUSINESS. Nothing reads the tag in this wave. Nothing changes
-- about how many points a sale earns, which programme earns them, or what any surface shows.
-- The wave exists so that W4 can read per-programme truth and W5 can write it.
--
-- WHY NULLABLE, DELIBERATELY. The plan splits "add the column and prove the tag on real
-- traffic" (here) from "make the tag mandatory" (W5) on purpose. A NOT NULL column added in
-- this wave would make the migration itself the first and only proof that the resolver answers
-- for every row, and would make any future insert path that this wave has not yet observed fail
-- CLOSED in production the first time it runs. Nullable-plus-trigger fails OPEN by exactly one
-- row and surfaces it: app.detect_double_earn_v309() below reports any sale-linked row that
-- arrived untagged, so a missed writer becomes a query result rather than an outage. W5 lands
-- NOT NULL after the tag has been observed on live traffic, in the same wave that rebuilds the
-- earn loop and swaps the anti-double-earn index. That separation is the point; do not
-- "tidy it up" by adding NOT NULL here.
--
-- THIS WAVE DOES NOT TOUCH app.on_sale_recorded. The earn insert lives at
-- 20260720_frenly_v37b_versioned_retention_taxonomy.sql:653-661 and the live definition is
-- maintained by TEXT-PATCHING it (the v121 precedent,
-- 20260731_nestly_v121_effective_loyalty_sale_earn_boundary.sql). A W3 edit there would collide
-- with that patch chain for no gain: the earn insert names its columns explicitly and omits
-- programme_id, so a BEFORE INSERT default-assignment trigger on the value table tags its rows
-- without the function changing by one byte. app.on_sale_recorded is W5's subject.
--
-- ------------------------------------------------------------------------------------------
-- THE APPEND-ONLY ESCAPE: WHAT EXISTS, AND WHAT DOES NOT
-- ------------------------------------------------------------------------------------------
-- The backfill is an UPDATE against a table the house treats as absolutely append-only, so the
-- mechanism matters more than the SQL. What is actually there, read rather than assumed:
--
--   * public.points_ledger carries FOUR triggers: trg_points_ledger_config_version (BEFORE
--     INSERT, app.stamp_config_version, 20260720_frenly_v26_immutable_config_versions.sql:280),
--     trg_points_ledger_write_guard (BEFORE INSERT, app.loyalty_ledger_write_guard,
--     20260719_frenly_v20_financial_engine.sql:760-763), trg_points_ledger_append_only (BEFORE
--     UPDATE OR DELETE, app.forbid_mutation, v20:769-772) and trg_audit_points (AFTER, from the
--     remote-only v3 engine migration).
--   * The WRITE GUARD IS BEFORE INSERT ONLY (v20:761-763). It never sees an UPDATE. There is
--     therefore nothing to escape on the guard side at all, and this migration neither disables
--     it nor sets any of its scope tokens. Every one of its INSERT routes
--     ('sale_trigger', 'redeem_points', 'adjust_points', 'points_expiry', v20:692-694) is left
--     exactly as it is.
--   * app.forbid_mutation (20260717_frenly_v11b_money.sql:378-383) is four lines that RAISE
--     unconditionally. It reads no GUC, takes no argument and has NO escape branch — unlike
--     public.sales, whose own guard honours the 'app.sales_backfill' token
--     (v20:2662-2663). Searching for a token-based ledger escape and inventing one on not
--     finding it would be the wrong move: the absence is the design.
--   * THE SANCTIONED MECHANISM IS THEREFORE THE NAMED-TRIGGER DISABLE, and it is not novel —
--     20260720_frenly_v26_immutable_config_versions.sql:175-196 established it for exactly this
--     situation (adding a derived provenance column, config_version_id, to the same two ledgers)
--     and states the rule in its own comment: disable ONLY the named UPDATE/DELETE guard, inside
--     the migration transaction, so that the guard is restored or the whole migration is rolled
--     back. §5 below follows that precedent verbatim in shape, and then does what v26 did not:
--     asserts, after re-enabling, that the trigger is enabled AND that it still raises.
--   * public.points_batches has NO append-only trigger. That is not an oversight in v20 and not
--     one here: batches are UPDATED in normal operation every day — the FEFO drain at
--     v20:930-935 and the expiry sweep at v20:1043 both decrement `remaining`. Its backfill is a
--     plain UPDATE and disables nothing.
--
-- WHAT STAYS ENABLED DURING THE BACKFILL, ON PURPOSE. trg_audit_points is NOT disabled. If its
-- event mask covers UPDATE, the backfill writes one audit_log row per ledger row — that is
-- evidence, not noise, and suppressing it would make the one UPDATE this table has ever seen the
-- one UPDATE with no trail. §5 raises a NOTICE recording the trigger's event coverage and the
-- audit rows the backfill produced, so the integrator can reconcile the count.
--
-- LOCKING. `alter table ... disable trigger` takes ACCESS EXCLUSIVE on public.points_ledger for
-- the remainder of this transaction. On the production shape (39 ledger rows, 37 batch rows) the
-- whole section is sub-millisecond. At a scale where that lock is a real outage the backfill
-- would have to be batched OUTSIDE one transaction with the guard left enabled and a purpose-
-- built maintenance route added to app.forbid_mutation — a different design, deliberately not
-- attempted at this size.
--
-- ------------------------------------------------------------------------------------------
-- THE RESOLVER, AND WHY IT ANSWERS FROM THE BUSINESS
-- ------------------------------------------------------------------------------------------
-- app.resolve_ledger_programme_v309(business) encodes the SINGLE-POT TRUTH of the product as it
-- stands: a business has exactly ONE accruing programme, because loyalty_model is single-valued
-- (v24:24-27) and the v308 tripwire refuses a second accruing spine row until W5. So the whole
-- rule is: a firm whose loyalty_programs row carries loyalty_model='stamps' accrues into its
-- STAMPS spine row; every other firm accrues into its POINTS spine row.
--
-- Resolved from the BUSINESS, never from the caller (plan §6 control 1). A caller-supplied
-- programme_id on an INSERT is honoured (see below) but nothing in the product supplies one
-- today, and no trigger, RPC or policy in this wave reads a client-provided programme.
--
-- ONE DELIBERATE DIVERGENCE FROM THE W1 READ MODEL, STATED SO IT IS NOT READ AS A BUG. The
-- resolver does NOT require loyalty_programs.active. app.business_programmes_v307 answers "is
-- this programme RUNNING right now"; the resolver answers "whose money is this row" — a
-- different question with a different correct answer for a paused firm. A firm that pauses its
-- stamp card still owns its stamp history, and rows written while paused (an owner adjustment,
-- an expiry sweep) still belong to the stamp programme. Binding the tag to `active` would make
-- a pause retag nothing but would make every row written during it land on the points row, i.e.
-- it would corrupt provenance on exactly the tenants that had switched something off. Identity
-- is not runningness.
--
-- Returns NULL when the business owns no spine row of the resolved kind. Post-v308 that is
-- structurally impossible — every business has all four rows and the businesses-INSERT trigger
-- creates them — so this is belt-and-braces, and the NULL it would produce is precisely what
-- app.detect_double_earn_v309() surfaces.
--
-- ------------------------------------------------------------------------------------------
-- TRIGGER PLACEMENT — IT HAS TO BE BEFORE INSERT, AND IT HAS TO BE HERE IN THE ORDER
-- ------------------------------------------------------------------------------------------
-- BEFORE INSERT is not a style choice. trg_points_ledger_append_only is a BEFORE UPDATE OR
-- DELETE guard, so the obvious alternative — let the row land, then UPDATE it into shape from an
-- AFTER trigger — is structurally unavailable on this table. Default-column assignment on NEW
-- inside a BEFORE INSERT trigger is the ONLY way to tag a points_ledger row without either
-- disabling the append-only guard on every write or editing every writer. That is why the tag is
-- shaped this way and not as an AFTER-INSERT fixer.
--
-- Same-event row triggers fire in NAME order (pg_trigger, alphabetical by tgname), so the name
-- below places the tag between the two existing BEFORE INSERT triggers:
--
--     trg_points_ledger_config_version   ->  trg_points_ledger_programme_tag_v309  ->  trg_points_ledger_write_guard
--
-- Both boundaries are chosen, and §7 asserts the resulting order so a later rename cannot move
-- it silently:
--   * BEFORE the write guard, because the guard is where a shape rule about programme_id
--     belongs. W5 tightens this table's invariants; if it wants the guard to refuse a
--     sale_trigger row whose programme_id is null, the guard must be able to SEE the resolved
--     value. A tag that fired after the guard would make that check impossible without also
--     renaming a trigger on a money table.
--   * AFTER the config-version stamp, because app.stamp_config_version opens with
--     `perform 1 from public.businesses ... for share` (v26:234). The v308 standing invariant is
--     that the global lock order is `businesses` row -> spine rows; firing after it means this
--     trigger's read of public.business_programmes always happens with the businesses row
--     already share-locked, in the same direction. (The tag takes no row lock of its own — it
--     only SELECTs — so it cannot invert an order; the placement keeps the two consistent
--     anyway rather than relying on that.)
-- The three triggers touch disjoint columns: the config trigger writes config_version_id, this
-- one writes programme_id, and the guard writes nothing and reads neither. trg_audit_points is
-- AFTER, so it records the tagged row whatever the BEFORE order is.
--
-- THE TRIGGER NEVER OVERRIDES A NON-NULL VALUE. `if new.programme_id is null then ... end if` is
-- load-bearing: at W5 the earn loop supplies programme_id explicitly, once per accruing
-- programme per sale, and a trigger that recomputed the single-pot answer would flatten that loop
-- back onto one programme — silently, and only on the second programme. Explicit input wins.
--
-- SECURITY. Both functions are SECURITY DEFINER with the canonical v21 search_path and the house
-- revoke. The trigger function must be definer for the reason v308's shim is: it fires in
-- whatever session wrote the row (a front-desk `authenticated` session recording a sale), and the
-- resolver's ACL deliberately does not admit `authenticated`, so an invoker trigger could not
-- call it. The resolver must be definer because it reads public.loyalty_programs and
-- public.business_programmes, both RLS-protected, and a tag computed through the writer's RLS
-- would be NULL for any session that cannot read the firm's programme row. Neither function is
-- reachable from PostgREST (schema app is not exposed in supabase/config.toml) and neither is
-- granted to a browser role.
--
-- THE NEW INDEX IS INERT TODAY, AND THAT IS THE POINT. points_earn_once_per_sale (v2:70-71) —
-- unique on (sale_id) alone for earn rows — is UNTOUCHED. The new
-- points_earn_once_per_sale_per_programme is strictly weaker while every business has one
-- accruing programme: any pair of rows the new index would reject, the old one rejects first.
-- Both exist side by side from now until W5 drops the old one in the same transaction that
-- removes the v308 tripwire. Creating it plainly, inside this transaction, is correct at 39 rows
-- (instant, and the ACCESS EXCLUSIVE lock is already held from the trigger disable above). At a
-- scale where a full-table index build blocks writes for a noticeable time, this statement is the
-- one that must move OUT of the transaction and become CREATE UNIQUE INDEX CONCURRENTLY — noted
-- here rather than left for whoever hits it.
--
-- Nothing here writes a value row. The two UPDATEs in §5 set a derived provenance column on rows
-- that already exist; no points are created, moved, expired or destroyed, and every `points`,
-- `earned`, `remaining` and `sale_id` value in both tables is byte-identical afterwards (§7
-- asserts the ledger sum is unchanged).

begin;

-- ---------------------------------------------------------------------------
-- 1. The columns. Nullable in this wave; W5 makes them NOT NULL (see the header).
-- ---------------------------------------------------------------------------

alter table public.points_ledger  add column if not exists programme_id uuid;
alter table public.points_batches add column if not exists programme_id uuid;

-- ---------------------------------------------------------------------------
-- 2. The foreign keys.
--
-- ON DELETE action decided by EXPERIMENT, not by taste — on a throwaway PG17 cluster carrying
-- the REAL v20/v11b append-only + write-guard triggers over the production row shape (4
-- businesses, 39 ledger rows, 37 batch rows). The setup: points_ledger.business_id and
-- points_batches.business_id are both `references public.businesses(id) on delete cascade`
-- (v2:61), and business_programmes.business_id is ON DELETE CASCADE too (v308:135), so deleting
-- a business fires BOTH cascades and the question is whether the spine cascade can trip over the
-- money cascade.
--
-- Three fixtures, so the append-only guard and the FK action can never be confused for each
-- other: A = batch rows but NO ledger rows (isolates the FK — nothing else can block); B = ledger
-- AND batch rows (the production shape); C = no money rows (control). Recorded output:
--
--     variant    fixture   outcome
--     RESTRICT   A         business delete SUCCEEDED
--     RESTRICT   B         FAILED: points_ledger is an append-only ledger: DELETE is not permitted.
--     RESTRICT   C         business delete SUCCEEDED
--     SET NULL   A/B/C     SUCCEEDED / same append-only DELETE failure / SUCCEEDED
--     NO ACTION  A/B/C     SUCCEEDED / same append-only DELETE failure / SUCCEEDED
--
-- Read that carefully, because it refutes the obvious prediction. RESTRICT does NOT break
-- business deletion. A parent-side referential action is an AFTER ROW trigger fired from the
-- deleting statement's queue, so by the time the RESTRICT check on business_programmes runs, the
-- cascade has already removed the rows that referenced it. A second probe forced the OPPOSITE
-- constraint order — dropping and recreating the points_batches -> businesses FK so its OID is
-- NEWER than business_programmes' — and RESTRICT still succeeded (4/4 across both orders), so the
-- result is not an accident of which table was created first.
--
-- And fixture B is the one that matters for the money rule: with ledger rows present the business
-- delete fails under ALL THREE actions, with `points_ledger is an append-only ledger: DELETE is
-- not permitted`. It is the v20 append-only trigger, not this FK, that makes a firm with money
-- history undeletable — that predates this wave and this wave does not change it.
--
-- SET NULL is therefore rejected as actively dangerous, and the probe proves it rather than
-- asserting it. Deleting a REFERENCED spine row directly (not via a business cascade) gives:
--     RESTRICT   REFUSED: ... violates foreign key constraint ... on table "points_ledger"
--     NO ACTION  REFUSED: ... violates foreign key constraint ... on table "points_ledger"
--     SET NULL   REFUSED: points_ledger is an append-only ledger: UPDATE is not permitted.
-- SET NULL can only ever succeed by doing the single thing this table exists to forbid. A
-- referential action that is load-bearing only when it violates the append-only invariant is not
-- a safety valve, it is a landmine — and the "SET NULL leaves an orphan the detector surfaces"
-- fallback is unreachable here, because the guard fires before the orphan can be created.
--
-- ON DELETE RESTRICT LANDS. It never blocks a business cascade (proved, both constraint orders),
-- it never attempts a forbidden UPDATE on a money table, and it refuses the one deletion that
-- would silently orphan tagged money rows. W5 revisits when programme_id becomes NOT NULL.
-- ---------------------------------------------------------------------------

alter table public.points_ledger
  drop constraint if exists points_ledger_programme_fk;
alter table public.points_ledger
  add constraint points_ledger_programme_fk
  foreign key (programme_id) references public.business_programmes(id)
  on delete restrict;

alter table public.points_batches
  drop constraint if exists points_batches_programme_fk;
alter table public.points_batches
  add constraint points_batches_programme_fk
  foreign key (programme_id) references public.business_programmes(id)
  on delete restrict;

comment on column public.points_ledger.programme_id is
  'v309 W3: which programme this row belongs to (public.business_programmes). Assigned by '
  'trg_points_ledger_programme_tag_v309 from the BUSINESS, never from the caller, and never '
  'overridden when explicitly supplied. NULLABLE in W3 by design — W5 makes it NOT NULL after '
  'the tag is proven on live traffic. Identity, not runningness: a paused programme still owns '
  'its rows.';
comment on column public.points_batches.programme_id is
  'v309 W3: which programme this batch belongs to (public.business_programmes). Assigned by '
  'trg_points_batches_programme_tag_v309. NULLABLE in W3 by design; NOT NULL at W5.';

-- ---------------------------------------------------------------------------
-- 3. The resolver — the single-pot rule, answered from the business.
-- ---------------------------------------------------------------------------

create or replace function app.resolve_ledger_programme_v309(p_business uuid)
returns uuid
language sql
stable
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
  select spine.id
    from public.business_programmes spine
   where spine.business_id = p_business
     and spine.kind = case
           when exists (
             select 1
               from public.loyalty_programs program
              where program.business_id = p_business
                and program.loyalty_model = 'stamps'
           ) then 'stamps'
           else 'points'
         end
$$;

revoke all privileges on function app.resolve_ledger_programme_v309(uuid)
  from public, anon, authenticated;
grant execute on function app.resolve_ledger_programme_v309(uuid) to service_role;

comment on function app.resolve_ledger_programme_v309(uuid) is
  'v309 W3: the programme a new points_ledger/points_batches row for this business belongs to. '
  'Single-pot rule — loyalty_model=''stamps'' resolves to the stamps spine row, everything else '
  'to the points spine row — which is exactly true while loyalty_model is single-valued and the '
  'v308 tripwire refuses a second accruing programme. Deliberately does NOT require '
  'loyalty_programs.active: this answers "whose money is this row", not "is the programme '
  'running", so a paused firm keeps writing to its own programme. SECURITY DEFINER because both '
  'tables it reads are RLS-protected and the writer''s session must not shape the answer. '
  'Returns null only for a business with no spine row of that kind (impossible post-v308); '
  'app.detect_double_earn_v309() surfaces any row that lands untagged.';

-- ---------------------------------------------------------------------------
-- 4. The tag triggers. BEFORE INSERT, default-column assignment, never overriding.
-- ---------------------------------------------------------------------------

create or replace function app.tag_ledger_programme_v309()
returns trigger
language plpgsql
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
begin
  -- NEVER override. W5's earn loop supplies programme_id explicitly, once per accruing
  -- programme per sale; recomputing the single-pot answer here would silently collapse that
  -- loop onto one programme.
  if new.programme_id is null then
    new.programme_id := app.resolve_ledger_programme_v309(new.business_id);
  end if;
  return new;
end
$$;

revoke all privileges on function app.tag_ledger_programme_v309()
  from public, anon, authenticated;

comment on function app.tag_ledger_programme_v309() is
  'v309 W3: BEFORE INSERT default-column assignment for points_ledger/points_batches.programme_id. '
  'Fills the tag from app.resolve_ledger_programme_v309(new.business_id) and NEVER overrides a '
  'value the writer supplied. BEFORE INSERT is forced, not preferred: trg_points_ledger_append_only '
  'is a BEFORE UPDATE guard, so an AFTER-INSERT fixer would have to violate the table''s own '
  'append-only invariant. SECURITY DEFINER because it fires in the writer''s session (typically '
  'authenticated) and the resolver''s ACL does not admit browser roles.';

drop trigger if exists trg_points_ledger_programme_tag_v309 on public.points_ledger;
create trigger trg_points_ledger_programme_tag_v309
  before insert on public.points_ledger
  for each row execute function app.tag_ledger_programme_v309();

drop trigger if exists trg_points_batches_programme_tag_v309 on public.points_batches;
create trigger trg_points_batches_programme_tag_v309
  before insert on public.points_batches
  for each row execute function app.tag_ledger_programme_v309();

-- ---------------------------------------------------------------------------
-- 5. The backfill — through the v26 sanctioned escape, and nothing wider.
-- ---------------------------------------------------------------------------

do $v309_audit_coverage$
declare
  v_events text;
begin
  select string_agg(event, '+' order by event) into v_events
    from (
      select unnest(array[
        case when (trigger.tgtype &  4) <> 0 then 'INSERT' end,
        case when (trigger.tgtype &  8) <> 0 then 'DELETE' end,
        case when (trigger.tgtype & 16) <> 0 then 'UPDATE' end
      ]) as event
        from pg_trigger trigger
       where trigger.tgrelid = 'public.points_ledger'::regclass
         and trigger.tgname = 'trg_audit_points'
    ) events
   where event is not null;
  raise notice
    'v309 backfill: trg_audit_points event coverage = %. It is NOT disabled — if it covers '
    'UPDATE the backfill below writes one audit_log row per ledger row, which is evidence.',
    coalesce(v_events, 'trigger not present');
end
$v309_audit_coverage$;

-- ⚠⚠⚠ APPEND-ONLY GUARD DISABLED — ONE NAMED TRIGGER, ONE STATEMENT, ONE TRANSACTION. ⚠⚠⚠
-- public.points_ledger is an absolutely append-only journal and app.forbid_mutation
-- (20260717_frenly_v11b_money.sql:378-383) has NO token escape, unlike public.sales
-- ('app.sales_backfill', v20:2662-2663). The sanctioned mechanism for adding a DERIVED
-- provenance column to this exact table is the named-trigger disable established by
-- 20260720_frenly_v26_immutable_config_versions.sql:185-188, whose own comment states the rule:
-- disable only the named UPDATE/DELETE guard, inside the migration transaction, so that the
-- guard is restored or the entire migration is rolled back. Nothing else is disabled — the
-- BEFORE INSERT write guard is untouched (it never sees an UPDATE) and trg_audit_points stays on.
-- §7 asserts, after re-enabling, that the trigger is enabled AND that it still raises.
alter table public.points_ledger disable trigger trg_points_ledger_append_only;

update public.points_ledger ledger
   set programme_id = app.resolve_ledger_programme_v309(ledger.business_id)
 where ledger.programme_id is null;

alter table public.points_ledger enable trigger trg_points_ledger_append_only;
-- ⚠⚠⚠ GUARD RESTORED. Everything below runs with points_ledger append-only again. ⚠⚠⚠

-- public.points_batches carries NO append-only trigger — v20 attached app.forbid_mutation to
-- points_ledger and credit_ledger only, because batches are UPDATED in normal operation every
-- day (FEFO drain v20:930-935, expiry sweep v20:1043). Nothing to disable, nothing to restore.
update public.points_batches batch
   set programme_id = app.resolve_ledger_programme_v309(batch.business_id)
 where batch.programme_id is null;

-- ---------------------------------------------------------------------------
-- 6. The new index, alongside the old. The old one is UNTOUCHED until W5.
-- ---------------------------------------------------------------------------

-- Plain, in-transaction, deliberately: 39 ledger rows build instantly and this transaction
-- already holds ACCESS EXCLUSIVE on the table from §5. At a scale where a blocking index build
-- is a real outage, THIS is the statement that must leave the transaction and become
-- `create unique index concurrently`. The two backfill UPDATEs and assertions (b)/(c) are
-- O(n) full scans too — with (b) invoking the resolver per row — trivial at 39/37 rows; at
-- real scale the backfill batches and the assertions sample or aggregate.
create unique index if not exists points_earn_once_per_sale_per_programme
  on public.points_ledger (sale_id, programme_id)
  where entry_type = 'earn' and sale_id is not null;

comment on index public.points_earn_once_per_sale_per_programme is
  'v309 W3: the anti-double-earn constraint W5 will rely on, created ALONGSIDE the v2 '
  'points_earn_once_per_sale (unique on sale_id alone), which stays authoritative until W5 '
  'drops it in the same transaction as the v308 tripwire removal. Strictly weaker than the old '
  'index while every business has exactly one accruing programme — inert by construction, which '
  'is why it can ship a wave early.';

-- ---------------------------------------------------------------------------
-- 7. The standing detector (plan §6 control 5). SELECT-only, ships with the tag.
-- ---------------------------------------------------------------------------

create or replace function app.detect_double_earn_v309()
returns table(sale_id uuid, programme_id uuid, earns bigint)
language sql
stable
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
  -- Two shapes of the same defect, deduplicated by UNION (a group that is both duplicated and
  -- untagged produces the identical tuple from both arms).
  --
  -- 1. More than one earn row for the same (sale, programme). Impossible today — the v2
  --    points_earn_once_per_sale index refuses a second earn for a sale at all — and the whole
  --    reason this query exists is that W5 drops that index and replaces it with the
  --    per-programme one, at which point this is the only thing watching.
  select ledger.sale_id, ledger.programme_id, count(*)::bigint
    from public.points_ledger ledger
   where ledger.entry_type = 'earn'
     and ledger.sale_id is not null
   group by ledger.sale_id, ledger.programme_id
  having count(*) > 1
  union
  -- 2. A sale-linked row that arrived UNTAGGED. programme_id is nullable through W4, so a writer
  --    the tag trigger does not cover fails open by one row instead of erroring — and shows up
  --    here. (The v20 write guard admits sale_id only on 'earn' rows, v20:698-707, so this arm
  --    reports earn rows today; it is deliberately not filtered on entry_type so that a future
  --    sale-linked entry type cannot slip past it.)
  select ledger.sale_id, ledger.programme_id, count(*)::bigint
    from public.points_ledger ledger
   where ledger.sale_id is not null
     and ledger.programme_id is null
   group by ledger.sale_id, ledger.programme_id
$$;

revoke all privileges on function app.detect_double_earn_v309()
  from public, anon, authenticated;
grant execute on function app.detect_double_earn_v309() to service_role;

comment on function app.detect_double_earn_v309() is
  'v309 W3 standing detector (plan §6 control 5): sale-linked points_ledger earn rows that are '
  'either duplicated within one (sale, programme) or untagged. SELECT-only, no writes, no side '
  'effects. Must return ZERO rows on a healthy database; it is asserted empty by this '
  'migration, by db/tests/v309_ledger_programme_tag.sql and by every later wave. It exists '
  'because W5 drops the v2 points_earn_once_per_sale index — until then it is a tripwire on a '
  'condition the database already makes impossible, which is exactly when a detector should be '
  'installed.';

-- ---------------------------------------------------------------------------
-- 8. Fail-closed post-backfill assertions. Any one of these aborts the migration.
-- ---------------------------------------------------------------------------

do $v309_assertions$
declare
  v_ledger_null bigint;
  v_batch_null bigint;
  v_ledger_disagree bigint;
  v_batch_disagree bigint;
  v_ledger_cross bigint;
  v_batch_cross bigint;
  v_old_index bigint;
  v_new_index bigint;
  v_append_only text;
  v_write_guard text;
  v_order text;
  v_probe uuid;
  v_raised boolean := false;
  v_detected bigint;
  v_ledger_rows bigint;
  v_batch_rows bigint;
begin
  select count(*) into strict v_ledger_rows from public.points_ledger;
  select count(*) into strict v_batch_rows from public.points_batches;

  -- (a) Nothing untagged, in either table.
  select count(*) into strict v_ledger_null
    from public.points_ledger where programme_id is null;
  select count(*) into strict v_batch_null
    from public.points_batches where programme_id is null;
  if v_ledger_null <> 0 or v_batch_null <> 0 then
    raise exception 'v309 backfill left untagged rows: points_ledger=%, points_batches=%',
      v_ledger_null, v_batch_null using errcode = '23514';
  end if;

  -- (b) Every tag equals the resolver's current answer for that row's business.
  --     TRUE ONLY WHILE SINGLE-POT. W5 deliberately breaks this predicate when a business runs
  --     two accruing programmes; it is asserted here because for the whole of W3 and W4 an
  --     inequality can only mean the backfill or the trigger is wrong.
  select count(*) into strict v_ledger_disagree
    from public.points_ledger ledger
   where ledger.programme_id
         is distinct from app.resolve_ledger_programme_v309(ledger.business_id);
  select count(*) into strict v_batch_disagree
    from public.points_batches batch
   where batch.programme_id
         is distinct from app.resolve_ledger_programme_v309(batch.business_id);
  if v_ledger_disagree <> 0 or v_batch_disagree <> 0 then
    raise exception
      'v309 tags disagree with the resolver: points_ledger=%, points_batches=%',
      v_ledger_disagree, v_batch_disagree using errcode = '23514';
  end if;

  -- (c) No cross-tenant tag: the spine row a money row points at must belong to the same
  --     business as the money row. (b) alone would not catch this if the resolver itself were
  --     ever wrong about tenancy.
  select count(*) into strict v_ledger_cross
    from public.points_ledger ledger
    left join public.business_programmes spine on spine.id = ledger.programme_id
   where spine.id is null or spine.business_id <> ledger.business_id;
  select count(*) into strict v_batch_cross
    from public.points_batches batch
    left join public.business_programmes spine on spine.id = batch.programme_id
   where spine.id is null or spine.business_id <> batch.business_id;
  if v_ledger_cross <> 0 or v_batch_cross <> 0 then
    raise exception
      'v309 cross-tenant or dangling tags: points_ledger=%, points_batches=%',
      v_ledger_cross, v_batch_cross using errcode = '23514';
  end if;

  -- (d) Both indexes exist, are valid and are ready. The OLD one surviving is as much a part of
  --     this wave's contract as the new one existing.
  select count(*) into strict v_old_index
    from pg_index idx
    join pg_class cls on cls.oid = idx.indexrelid
   where cls.relname = 'points_earn_once_per_sale'
     and idx.indrelid = 'public.points_ledger'::regclass
     and idx.indisunique and idx.indisvalid and idx.indisready;
  select count(*) into strict v_new_index
    from pg_index idx
    join pg_class cls on cls.oid = idx.indexrelid
   where cls.relname = 'points_earn_once_per_sale_per_programme'
     and idx.indrelid = 'public.points_ledger'::regclass
     and idx.indisunique and idx.indisvalid and idx.indisready;
  if v_old_index <> 1 or v_new_index <> 1 then
    raise exception
      'v309 index state wrong: points_earn_once_per_sale=%, points_earn_once_per_sale_per_programme=%',
      v_old_index, v_new_index using errcode = '23514';
  end if;

  -- (e) The guards are back on. tgenabled 'O' = fires in origin/local sessions (the default);
  --     'D' is what §5 set temporarily. This is the assertion that makes the disable safe.
  select trigger.tgenabled into v_append_only
    from pg_trigger trigger
   where trigger.tgrelid = 'public.points_ledger'::regclass
     and trigger.tgname = 'trg_points_ledger_append_only';
  select trigger.tgenabled into v_write_guard
    from pg_trigger trigger
   where trigger.tgrelid = 'public.points_ledger'::regclass
     and trigger.tgname = 'trg_points_ledger_write_guard';
  if coalesce(v_append_only, 'missing') <> 'O' or coalesce(v_write_guard, 'missing') <> 'O' then
    raise exception
      'v309 left a points_ledger guard disabled or missing: append_only=%, write_guard=%',
      coalesce(v_append_only, 'missing'), coalesce(v_write_guard, 'missing')
      using errcode = '23514';
  end if;

  -- (f) ...and still ENFORCING, not merely present. A no-op UPDATE of a real row must raise.
  --     Conditional on a row existing: on an empty ledger no row trigger can fire, so a
  --     behavioural probe would pass vacuously and claim something it had not tested. The
  --     unconditional half is (e); the behavioural half is proved on a fixture, unconditionally,
  --     by db/tests/v309_ledger_programme_tag.sql step 7.
  if v_ledger_rows > 0 then
    select ledger.id into v_probe from public.points_ledger ledger limit 1;
    begin
      update public.points_ledger set programme_id = programme_id where id = v_probe;
    exception when others then
      v_raised := true;
    end;
    if not v_raised then
      raise exception
        'v309 re-enabled trg_points_ledger_append_only but a points_ledger UPDATE still succeeded'
        using errcode = '23514';
    end if;
  else
    raise notice
      'v309: points_ledger is empty, so the behavioural append-only probe was skipped; '
      'the pg_trigger state assertion still ran.';
  end if;

  -- (g) BEFORE INSERT firing order is name order, and the name was chosen for its position
  --     (see the header). Pin it so a rename cannot move the tag past the write guard.
  select string_agg(trigger.tgname, ' -> ' order by trigger.tgname) into v_order
    from pg_trigger trigger
   where trigger.tgrelid = 'public.points_ledger'::regclass
     and not trigger.tgisinternal
     and (trigger.tgtype & 2) <> 0   -- BEFORE
     and (trigger.tgtype & 4) <> 0;  -- INSERT
  if v_order <> 'trg_points_ledger_config_version -> trg_points_ledger_programme_tag_v309'
                || ' -> trg_points_ledger_write_guard' then
    raise exception
      'v309 unexpected BEFORE INSERT trigger order on points_ledger: %', v_order
      using errcode = '23514';
  end if;

  -- (h) The standing detector must be clean the moment it ships.
  select count(*) into strict v_detected from app.detect_double_earn_v309();
  if v_detected <> 0 then
    raise exception 'v309 double-earn detector is non-empty at install time: % row(s)', v_detected
      using errcode = '23514';
  end if;

  raise notice
    'v309 backfill verified: % points_ledger rows and % points_batches rows tagged, zero nulls, '
    'zero resolver disagreements, zero cross-tenant tags, both indexes valid, append-only and '
    'write guards enabled and enforcing, detector empty.',
    v_ledger_rows, v_batch_rows;
end
$v309_assertions$;

commit;
