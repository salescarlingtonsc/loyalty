-- nestly_v308_programme_spine
--
-- WAVE 2 of the four-programme independence plan
-- (docs/design/FOUR-PROGRAMME-INDEPENDENCE-PLAN.md §6, owner approval 2026-08-13).
--
-- WHAT THIS IS. The programme SPINE: public.business_programmes, exactly four rows per business
-- (points, tiers, stamps, referral), backfilled from the W1 read model and kept in lock-step with
-- the legacy columns by one-way sync triggers. It is the stable join target every later wave needs
-- — W3 tags the points ledger with a programme, W4 flips the read path onto per-programme truth,
-- W5 rebuilds the earn loop around it, W6 finally lets an owner switch the four rows independently.
--
-- LEGACY STAYS AUTHORITATIVE. Nothing in this wave changes a single behaviour. The columns that
-- decide what runs today — loyalty_programs.active / .loyalty_model, businesses.points_mode, the
-- presence of loyalty_tiers rows, referral_programs.enabled — remain the truth, and this table is a
-- DERIVED PROJECTION of them. No reader is flipped onto the spine here; that is W4. Reverting this
-- migration (drop the triggers, drop the table) restores the database to a byte-equivalent
-- behavioural state, because nothing reads what it writes.
--
-- THE ONE-WAY SYNC INVARIANT. No BROWSER role can write the spine. RLS is on and there is a SELECT
-- policy and NOTHING else: no INSERT, UPDATE or DELETE policy exists for any API role, and the table
-- ACL is revoked from public/anon/authenticated with only SELECT granted back. Be precise about what
-- that does and does not cover: `service_role` keeps the Supabase default ALL privilege on this
-- PostgREST-exposed table and holds no RLS policy to satisfy, so a trusted platform surface running
-- as service_role CAN write these rows. That is the house shape (v108 growth_*, v174 pipeline
-- tables) and it is not weakened here; the structural guard against a service_role write producing
-- an impossible state is the tripwire in §2, not an ACL. Every INTENDED write happens inside
-- app.sync_business_programmes_v308, a SECURITY DEFINER recompute that derives `active` by CALLING
-- app.business_programmes_v307 — W1's reviewed predicates — rather than restating them. There is
-- exactly one place where the question "is this programme running?" is answered, in this wave and in
-- every later one. Drift between spine and read model is therefore not reachable from a tenant
-- session at all; it would take a bug in the sync, a service_role writer going around it, or a
-- legacy surface that no trigger watches. The rolled-back suite (db/tests/v308_programme_spine.sql)
-- proves the browser-role denial, the per-step projection and full-tenant parity.
--
-- CONCURRENCY: THE RECOMPUTE SERIALIZES ON THE BUSINESS ROW. The sync opens by taking
-- `select 1 from public.businesses where id = p_business for update`, which is both the existence
-- probe (a cascade delete can call the sync for a business that is already gone) and a per-business
-- mutex. It has to be a lock, not a bare probe: two watched writes to the SAME business can run
-- concurrently on different legacy tables — public.save_referral_program locks only a staff row, and
-- an owner PATCHing businesses.points_mode over PostgREST locks only that businesses row — so
-- without this, transaction A could compute its four flags from a snapshot taken before B committed,
-- then block on the SPINE row lock, wake after B commits, and have its `is distinct from excluded`
-- guard compare A's STALE computed values against B's already-fresh row. The guard passes (the two
-- differ), A overwrites B's answer with a pre-B one, and the spine stays wrong until the next
-- watched write. Locking the business row first moves the wait BEFORE the computation: under READ
-- COMMITTED every statement takes a fresh snapshot, so the recompute that runs after the lock wait
-- sees the other transaction's commit and projects the combined state. The lock order this
-- establishes globally is `public.businesses` row -> `public.business_programmes` rows in kind
-- order; nothing inverts it — publish_loyalty_config (v55:683) already takes the businesses row FOR
-- UPDATE before it touches loyalty_programs/loyalty_tiers, so its trigger-driven sync re-takes a
-- lock it already holds.
--
-- FOUR ROWS ALWAYS, NEVER SPARSE. A business gets all four rows the moment it exists (AFTER INSERT
-- on public.businesses) and every existing business gets them from the backfill below. Sparse rows
-- would make "is the spine equal to the read model?" a set-difference question in both directions;
-- four-rows-always makes it a row-for-row column comparison, which is what the W1 acceptance
-- baseline (docs/qa/evidence/V307-W1-PROGRAMME-READ-MODEL-ACCEPTANCE.md) is recorded as, and gives
-- W5's earn loop a join target that exists before the programme is ever switched on.
--
-- activated_at / deactivated_at ARE BREADCRUMBS, NOT STATE. The sync stamps activated_at when
-- `active` flips false->true and deactivated_at when it flips true->false, and NEVER clears either.
-- A row that has been on and then off carries both. `active` alone is the state; the two timestamps
-- are the history a later wave can show an owner ("running since…", "paused on…") without a
-- separate audit table. They are also why the upsert below is guarded by
-- `where spine.active is distinct from excluded.active`: a recompute that changes nothing must
-- write nothing, so re-running the sync is byte-stable including the timestamps.
-- One honest limitation of the backfill in §5: a programme that has been running for months gets
-- activated_at = the migration's own now(), because no earlier history exists to recover. Read
-- activated_at as "running since at least" for pre-v308 programmes, and as a true first-activation
-- moment only for flips the sync itself observed.
--
-- WHY THE loyalty_tiers SYNC IS DEFERRED TO COMMIT. public.publish_loyalty_config (v55:713-714)
-- republishes the ladder by DELETING every loyalty_tiers row for the business and re-INSERTing them
-- from the version table. With an immediate row trigger the spine sees that as two real flag moves
-- inside one transaction: after the DELETE the tiers predicate answers false and deactivated_at is
-- stamped, after the INSERT it answers true again and activated_at is stamped. A publish that
-- changed nothing about the ladder would rewrite BOTH breadcrumbs — and those timestamps are the
-- "running since… / paused on…" history a later wave shows the owner, so churning them on every
-- republish makes them lie. The loyalty_tiers triggers below are therefore CONSTRAINT TRIGGERS,
-- DEFERRABLE INITIALLY DEFERRED: their events queue and all fire at COMMIT, by which time the rungs
-- are in their FINAL state, so a net-unchanged republish recomputes tiers=true, hits the
-- `is distinct from` no-op guard and writes nothing at all. A real pause (rungs deleted and not
-- restored) still recomputes false at commit and still stamps deactivated_at. Only loyalty_tiers is
-- deferred: businesses, loyalty_programs and referral_programs stay immediate row triggers because
-- each of their writers moves the watched value exactly once per transaction, and immediate firing
-- keeps the spine correct statement-by-statement there.
-- CONSEQUENCE THE INTEGRATOR MUST KNOW: inside a transaction that edits ladder rungs, the spine
-- converges at COMMIT, not per statement. Nothing reads the spine mid-transaction today (no reader
-- is flipped onto it until W4, and W4 readers read committed state), and the rolled-back suite forces
-- the queue with `set constraints … immediate` wherever it needs to assert mid-transaction.
--
-- TIERS FUEL — A NOTE FOR LATER WAVES, NOT A CHANGE HERE. Under the legacy model a firm on
-- points_mode='tiers' still runs the points ENGINE: points accrue silently and the ladder is
-- climbed with them (owner decision D1 — tiers are fuelled by lifetime points earned). So when the
-- config columns eventually move onto the spine, that firm's earn rate belongs to the TIER
-- programme's row, not to a points row it does not have — move it to the points row and the ladder
-- silently stops. THIS WAVE MOVES NO CONFIG COLUMN AT ALL: the spine carries identity and an active
-- flag and nothing else, precisely so that the fuel question is decided deliberately in the wave
-- that moves earn_rate_bps/earn_points_per_dollar rather than accidentally here.
--
-- THE TRIPWIRE, AND WHEN IT IS REMOVED. business_programmes_exclusive_accrual_v308 is a constraint
-- trigger refusing a business whose points row and stamps row are both active. Today that state is
-- structurally impossible: loyalty_model is single-valued and the W1 points predicate is
-- model-exclusive (v307 divergence 3), so a stamps firm answers points=false by construction. The
-- tripwire exists because W5 rebuilds the earn loop and W6 unlocks independent switches, and either
-- could make two accruing programmes reachable BEFORE the anti-double-earn index swap makes that
-- safe. It must fail loudly at that moment rather than quietly double-earning.
-- ⚠ REMOVED AT W5 (the money wave), deliberately, in the same transaction as the
-- `unique (sale_id, programme_id)` index swap — not before.
--
-- NO RECURSION LATCH, BY CONSTRUCTION. The four sync triggers watch businesses, loyalty_programs,
-- loyalty_tiers and referral_programs. NONE of them watches public.business_programmes, and nothing
-- in the sync writes a legacy table, so there is no cycle to break — a re-entrancy guard here would
-- be dead code that a future reader would mistake for evidence that a loop exists.
--
-- SECURITY. app.sync_business_programmes_v308 is SECURITY DEFINER because it must see EVERY tenant
-- row regardless of who triggered it: a firm owner updating loyalty_programs over PostgREST is an
-- `authenticated` session, and the W1 read model is SECURITY INVOKER, so an invoker sync would
-- compute its answer through that session's RLS and could project a WRONG (all-false) spine for a
-- business the session cannot fully read. Canonical v21 search_path; house revoke from
-- public/anon/authenticated with execute granted to service_role only. The trigger function is
-- definer for the same reason and one more: a trigger firing in a tenant session must be able to
-- call the sync, and the sync's ACL deliberately does not admit `authenticated`.
--
-- Nothing here writes credit_ledger, points_ledger, sales or any other VALUE_TABLE.

begin;

-- ---------------------------------------------------------------------------
-- 1. The spine table.
-- ---------------------------------------------------------------------------

create table if not exists public.business_programmes (
  id             uuid primary key default gen_random_uuid(),
  business_id    uuid not null references public.businesses(id) on delete cascade,
  kind           text not null check (kind in ('points','tiers','stamps','referral')),
  active         boolean not null default false,
  sort           smallint not null,
  created_at     timestamptz not null default now(),
  activated_at   timestamptz,
  deactivated_at timestamptz,
  unique (business_id, kind),
  -- `sort` is a presentation rank that is a pure function of `kind`. Pinning it as a CHECK rather
  -- than trusting every writer to compute it keeps the four rows in one order forever, and means
  -- the sync never has to UPDATE it.
  constraint business_programmes_sort_matches_kind check (
    sort = case kind
             when 'points' then 1
             when 'tiers' then 2
             when 'stamps' then 3
             when 'referral' then 4
           end
  )
);

comment on table public.business_programmes is
  'v308 W2 programme spine: exactly four rows per business (points, tiers, stamps, referral). '
  'DERIVED — legacy columns stay authoritative until a later wave flips readers onto this table. '
  '`active` mirrors app.business_programmes_v307 and is maintained by '
  'app.sync_business_programmes_v308; no BROWSER role holds an INSERT/UPDATE/DELETE policy or '
  'privilege, so the projection cannot be drifted from a tenant session. service_role keeps its '
  'default write privilege (house shape) and is a trusted platform surface; the exclusive-accrual '
  'tripwire, not the ACL, is the structural guard on what it can produce. '
  'activated_at/deactivated_at are never cleared — they are a history '
  'breadcrumb, not state.';

comment on column public.business_programmes.sort is
  'v308: fixed presentation rank derived from kind (points=1, tiers=2, stamps=3, referral=4), '
  'pinned by a CHECK so the four rows always read in the same order.';
comment on column public.business_programmes.activated_at is
  'v308: last time active flipped false->true. Never cleared.';
comment on column public.business_programmes.deactivated_at is
  'v308: last time active flipped true->false. Never cleared.';

alter table public.business_programmes enable row level security;

-- ACL floor. Mirrors the house tenant-table shape (nestly_v108 growth_* tables): every browser role
-- loses everything, then SELECT alone comes back, so RLS is deciding WHICH rows a reader sees and
-- the grant is deciding that a reader can only ever read. service_role keeps the privileges Supabase
-- default-privileges give it; the sync runs as the table owner.
revoke all privileges on table public.business_programmes from public, anon, authenticated;
grant select on table public.business_programmes to authenticated;

-- Read policies mirror the shape public.loyalty_programs has carried since v23d — member read plus
-- the v14 super-admin read — MINUS the owner-write policy, which is exactly the point of this wave.
-- No module gate: a firm that has switched the Loyalty module off still HAS its programmes (W1
-- divergence 1), and gating the spine on enabled_modules would strand those rows.
drop policy if exists business_programmes_read on public.business_programmes;
drop policy if exists business_programmes_sa_read on public.business_programmes;
create policy business_programmes_read on public.business_programmes
  for select to authenticated
  using (app.is_salon_member(business_id));
create policy business_programmes_sa_read on public.business_programmes
  for select to authenticated
  using (app.is_super_admin());

-- ---------------------------------------------------------------------------
-- 2. The tripwire (removed at W5 — see the header).
-- ---------------------------------------------------------------------------

create or replace function app.business_programmes_exclusive_accrual_v308()
returns trigger
language plpgsql
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
begin
  if new.active and new.kind in ('points','stamps') then
    if exists (
      select 1
        from public.business_programmes other
       where other.business_id = new.business_id
         and other.kind = case new.kind when 'points' then 'stamps' else 'points' end
         and other.active
    ) then
      raise exception
        'business % cannot run the points and stamps programmes at the same time (v308 tripwire; removed at W5)',
        new.business_id
        using errcode = '23514';
    end if;
  end if;
  return null;
end
$$;

revoke all privileges on function app.business_programmes_exclusive_accrual_v308()
  from public, anon, authenticated;

comment on function app.business_programmes_exclusive_accrual_v308() is
  'v308 W2 tripwire: refuses a business whose points and stamps spine rows are both active. Today '
  'unreachable (loyalty_model is single-valued and the W1 points predicate is model-exclusive); it '
  'exists so W5/W6 cannot silently make double accrual reachable before the anti-double-earn index '
  'swap. REMOVED AT W5, in the same transaction as that swap.';

drop trigger if exists business_programmes_exclusive_accrual_v308 on public.business_programmes;
create constraint trigger business_programmes_exclusive_accrual_v308
  after insert or update on public.business_programmes
  deferrable initially immediate
  for each row
  execute function app.business_programmes_exclusive_accrual_v308();

-- ---------------------------------------------------------------------------
-- 3. The one and only recompute.
-- ---------------------------------------------------------------------------

create or replace function app.sync_business_programmes_v308(p_business uuid)
returns void
language plpgsql
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
begin
  if p_business is null then
    return;
  end if;

  -- LOCK, THEN PROBE — one statement doing two jobs.
  --
  -- (a) Existence. A cascade delete of a business removes its legacy rows AFTER the parent row is
  --     gone, so the DELETE triggers below can call this for a business that no longer exists. There
  --     is nothing to project onto (the spine rows cascaded away too) and the insert would violate
  --     the FK, so a missing business is a silent return.
  --
  -- (b) Serialization. FOR UPDATE makes this a per-business mutex around the whole recompute. Two
  --     watched writes to the same business really can run concurrently on different legacy tables:
  --     public.save_referral_program (v41) locks only a staff row, and an owner PATCHing
  --     businesses.points_mode over PostgREST locks only that businesses row — neither excludes the
  --     other. Without this lock the interleaving is:
  --       B updates points_mode and holds; A enables referral, computes BOTH flags from a snapshot
  --       that predates B, then blocks on B's spine row; B commits; A wakes, and its
  --       `where spine.active is distinct from excluded.active` guard now compares A's STALE points
  --       value against B's FRESH row — they differ, so the guard PASSES and A overwrites B's answer
  --       with a pre-B one. The spine stays wrong until the next watched write touches that business.
  --     Taking the lock here moves the wait in front of the computation. Under READ COMMITTED each
  --     statement takes a fresh snapshot, so the recompute below runs after B's commit is visible and
  --     projects the combined state.
  --
  -- Lock order established globally: public.businesses row -> public.business_programmes rows in
  -- kind order. Nothing inverts it — publish_loyalty_config (v55:683) already takes the businesses
  -- row FOR UPDATE before touching loyalty_programs/loyalty_tiers, so the sync its writes trigger
  -- simply re-takes a lock the transaction already holds.
  perform 1 from public.businesses target where target.id = p_business for update;
  if not found then
    return;
  end if;

  insert into public.business_programmes as spine
    (business_id, kind, active, sort, activated_at, deactivated_at)
  select
    p_business,
    model.kind,
    model.running,
    (case model.kind
       when 'points' then 1
       when 'tiers' then 2
       when 'stamps' then 3
       when 'referral' then 4
     end)::smallint,
    case when model.running then now() end,
    null::timestamptz
    from app.business_programmes_v307(p_business) model
  on conflict (business_id, kind) do update
     set active = excluded.active,
         activated_at = case
           when excluded.active and not spine.active then now()
           else spine.activated_at
         end,
         deactivated_at = case
           when spine.active and not excluded.active then now()
           else spine.deactivated_at
         end
   -- A recompute that changes nothing writes nothing: no dead tuple, no timestamp churn, and
   -- calling the sync twice is byte-stable.
   where spine.active is distinct from excluded.active;
end
$$;

revoke all privileges on function app.sync_business_programmes_v308(uuid)
  from public, anon, authenticated;
grant execute on function app.sync_business_programmes_v308(uuid) to service_role;

comment on function app.sync_business_programmes_v308(uuid) is
  'v308 W2: recompute one business''s four spine rows from the W1 read model '
  '(app.business_programmes_v307) and upsert them. The only INTENDED writer of '
  'public.business_programmes (no browser role can write the table at all; service_role can, and is '
  'held honest by the v308 tripwire rather than by an ACL). Opens by locking the businesses row FOR '
  'UPDATE — existence probe plus per-business mutex, so two concurrent watched writes cannot have '
  'the later one overwrite the earlier with stale computed flags. '
  'SECURITY DEFINER because it must see every tenant row whoever '
  'triggered it — the read model is SECURITY INVOKER, so an invoker sync would project a tenant '
  'session''s RLS-shaped answer. One-way: legacy -> spine, never the reverse.';

-- ---------------------------------------------------------------------------
-- 4. Trigger coverage: every legacy surface whose change can move a W1 flag.
-- ---------------------------------------------------------------------------

create or replace function app.business_programmes_sync_trigger_v308()
returns trigger
language plpgsql
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare
  v_column text := coalesce(tg_argv[0], 'business_id');
  v_row jsonb;
  v_new uuid;
  v_old uuid;
begin
  -- OLD and NEW are read only inside the branch that owns them: an unassigned record variable
  -- (OLD on INSERT, NEW on DELETE) cannot be passed to to_jsonb without raising. Each branch also
  -- fails loudly rather than silently syncing nothing if this trigger is ever attached to a table
  -- whose tenant key is spelled differently.
  if tg_op in ('INSERT','UPDATE') then
    v_row := to_jsonb(new);
    if not (v_row ? v_column) then
      raise exception 'v308 sync trigger on %.% has no column %',
        tg_table_schema, tg_table_name, v_column using errcode = '42703';
    end if;
    v_new := (v_row ->> v_column)::uuid;
  end if;
  if tg_op in ('UPDATE','DELETE') then
    v_row := to_jsonb(old);
    if not (v_row ? v_column) then
      raise exception 'v308 sync trigger on %.% has no column %',
        tg_table_schema, tg_table_name, v_column using errcode = '42703';
    end if;
    v_old := (v_row ->> v_column)::uuid;
  end if;

  if v_new is not null then
    perform app.sync_business_programmes_v308(v_new);
  end if;
  -- An UPDATE that moves a config row between tenants has to leave BOTH spines correct.
  if v_old is not null and v_old is distinct from v_new then
    perform app.sync_business_programmes_v308(v_old);
  end if;

  return null;
end
$$;

revoke all privileges on function app.business_programmes_sync_trigger_v308()
  from public, anon, authenticated;

comment on function app.business_programmes_sync_trigger_v308() is
  'v308 W2: AFTER-row trigger shim. Reads the tenant key named by tg_argv[0] (default '
  '''business_id''; ''id'' on public.businesses) from NEW and OLD and calls '
  'app.sync_business_programmes_v308 for each distinct business. Watches only LEGACY tables — never '
  'public.business_programmes — so no recursion is possible and no re-entrancy latch is needed. '
  'Attached IMMEDIATE on businesses/loyalty_programs/referral_programs and as a DEFERRABLE INITIALLY '
  'DEFERRED constraint trigger on loyalty_tiers, so publish_loyalty_config''s delete-and-reinsert of '
  'the ladder recomputes once at COMMIT instead of churning the activated_at/deactivated_at '
  'breadcrumbs twice per republish.';

-- businesses: INSERT creates the four rows for a brand-new tenant; points_mode is the only column
-- on this table any W1 predicate reads.
drop trigger if exists business_programmes_sync_businesses_v308 on public.businesses;
create trigger business_programmes_sync_businesses_v308
  after insert or update of points_mode on public.businesses
  for each row
  execute function app.business_programmes_sync_trigger_v308('id');

-- loyalty_programs: one row per business holding active + loyalty_model, both read by three of the
-- four predicates. Full UPDATE coverage (not `update of`) because this row is edited rarely and a
-- missed column here is a silently wrong spine.
drop trigger if exists business_programmes_sync_loyalty_programs_v308 on public.loyalty_programs;
create trigger business_programmes_sync_loyalty_programs_v308
  after insert or update or delete on public.loyalty_programs
  for each row
  execute function app.business_programmes_sync_trigger_v308('business_id');

-- loyalty_tiers: the tiers predicate asks only whether ANY row exists, so the first row appearing
-- and the last row vanishing are the two flag-moving events. business_id IS mutable on this table
-- (v23 added no guard and the owner-write policy is `for all`), so a row moved between tenants is
-- covered too — but nothing else about a tier (name, threshold, multiplier, sort) can move a flag,
-- and `update of business_id` keeps ordinary ladder edits off this path entirely.
--
-- DEFERRED, ALONE AMONG THE FOUR (see the header). public.publish_loyalty_config (v55:713-714)
-- deletes the whole ladder and re-inserts it in one transaction. Fired immediately, this trigger
-- would recompute tiers=false after the DELETE and tiers=true after the INSERT, stamping
-- deactivated_at and then activated_at on a republish that changed nothing — the breadcrumbs would
-- record a pause that never happened. As a CONSTRAINT TRIGGER, DEFERRABLE INITIALLY DEFERRED, the
-- per-row events queue and fire at COMMIT against the FINAL rung state: a net-unchanged republish
-- recomputes tiers=true, the upsert's `is distinct from` guard finds nothing to do, and neither
-- timestamp moves. A real pause — rungs deleted and not restored — still recomputes false at commit
-- and still stamps deactivated_at.
--
-- The queue fires once per queued row event, not once per transaction, and that is harmless: the
-- sync recomputes from CURRENT state, so the first firing converges the spine and every later one
-- is absorbed by the same no-op guard. tg_argv still reaches the shim — constraint triggers carry
-- arguments exactly like ordinary ones.
--
-- The other three stay immediate row triggers on purpose: each of their writers moves the watched
-- value exactly once per transaction, so there is no delete-and-reinsert storm to smooth out, and
-- immediate firing keeps the spine correct statement-by-statement for them.
drop trigger if exists business_programmes_sync_loyalty_tiers_v308 on public.loyalty_tiers;
create constraint trigger business_programmes_sync_loyalty_tiers_v308
  after insert or update of business_id or delete on public.loyalty_tiers
  deferrable initially deferred
  for each row
  execute function app.business_programmes_sync_trigger_v308('business_id');

-- referral_programs: `enabled` is the whole predicate; business_id is likewise mutable.
drop trigger if exists business_programmes_sync_referral_programs_v308 on public.referral_programs;
create trigger business_programmes_sync_referral_programs_v308
  after insert or update of enabled, business_id or delete on public.referral_programs
  for each row
  execute function app.business_programmes_sync_trigger_v308('business_id');

-- ---------------------------------------------------------------------------
-- 5. Backfill, then prove it — inside this transaction.
-- ---------------------------------------------------------------------------

insert into public.business_programmes (business_id, kind, active, sort, activated_at)
select
  business.id,
  model.kind,
  model.running,
  (case model.kind
     when 'points' then 1
     when 'tiers' then 2
     when 'stamps' then 3
     when 'referral' then 4
   end)::smallint,
  case when model.running then now() end
  from public.businesses business
  cross join lateral app.business_programmes_v307(business.id) model
on conflict (business_id, kind) do nothing;

do $v308_backfill_assertion$
declare
  v_businesses bigint;
  v_rows bigint;
  v_wrong_shape bigint;
  v_disagreements bigint;
  v_detail text;
begin
  select count(*) into strict v_businesses from public.businesses;
  select count(*) into strict v_rows from public.business_programmes;

  select count(*) into strict v_wrong_shape
    from (
      select business.id
        from public.businesses business
        left join public.business_programmes spine on spine.business_id = business.id
       group by business.id
      having count(spine.id) <> 4
          or count(distinct spine.kind) <> 4
    ) shape;

  select count(*), coalesce(string_agg(
           business.id::text || '/' || model.kind
             || ' spine=' || spine.active::text
             || ' model=' || model.running::text,
           ', ' order by business.id, model.kind), '')
    into strict v_disagreements, v_detail
    from public.businesses business
    cross join lateral app.business_programmes_v307(business.id) model
    join public.business_programmes spine
      on spine.business_id = business.id
     and spine.kind = model.kind
   where spine.active is distinct from model.running;

  -- Fail CLOSED. A backfill that is wrong for even one tenant must abort the whole migration
  -- rather than half-land a projection that later waves will treat as truth.
  if v_rows <> v_businesses * 4 then
    raise exception
      'v308 backfill shape: % businesses must own exactly % spine rows, found %',
      v_businesses, v_businesses * 4, v_rows
      using errcode = '23514';
  end if;
  if v_wrong_shape <> 0 then
    raise exception
      'v308 backfill shape: % business(es) do not own exactly four distinct programme kinds',
      v_wrong_shape
      using errcode = '23514';
  end if;
  if v_disagreements <> 0 then
    raise exception
      'v308 backfill disagrees with the W1 read model in % row(s): %',
      v_disagreements, v_detail
      using errcode = '23514';
  end if;

  raise notice
    'v308 backfill verified: % businesses, % spine rows, zero disagreements with app.business_programmes_v307',
    v_businesses, v_rows;
end
$v308_backfill_assertion$;

commit;
