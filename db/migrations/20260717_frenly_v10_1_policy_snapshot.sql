-- FRENLY v10.1 — sale accounting policy is SNAPSHOTTED AT RECORD TIME, not resolved at read time.
-- (target Supabase project kyzovonwnscrzmkvocid; migration name `frenly_v10_1_policy_snapshot`)
-- P0 CORRECTION to `frenly_v10_sale_policy`, WHICH IS ALREADY LIVE IN PRODUCTION.
--
-- ======================================================================================
-- SCOPE OF THIS FILE — read this before anything else
-- ======================================================================================
-- v10.1 does EXACTLY six things and nothing else:
--   1. Immutable resolved policy flags on `sales` (the snapshot).
--   2. Backfill of the 6 existing rows.
--   3. Snapshot future rows at INSERT.
--   4. Retention calculations read EACH ROW'S OWN snapshot.
--   5. Routine policy changes (set_sale_policy) cannot reinterpret history.
--   6. An audited accounting RECLASSIFICATION path, revenue-only.
--
-- REFUNDS / REVERSALS ARE NOT IN THIS FILE AND ARE NOT IMPLEMENTED ANYWHERE YET.
--   An earlier draft of v10.1 carried `reverse_sale()` and a `reversal_of` column. Both are
--   REMOVED. The reviewer's verdict: the P0 correction must not ride along with an incomplete
--   refund system. A refund is not one negative row — it interacts with payments (v11b),
--   line items, partial amounts, gift-card balance restoration, points clawback, referral
--   de-qualification and the cash drawer. None of that is defined yet. Shipping the negative
--   row now would mean shipping a refund feature that is wrong in five places while claiming
--   to be a policy fix.
--   CONSEQUENCE, STATED PLAINLY: after v10.1, `sales` is append-only and there is NO
--   supported way to undo a sale. DELETE is blocked and no reversal exists. That is a
--   deliberate, temporary dead end owned by v11b, not an oversight. It is not a regression:
--   nothing in the app deletes or reverses a sale today either (verified — app/index.html
--   only .insert()/.select()s `sales`, and no function in schema app or public issues an
--   UPDATE or DELETE against it).
--
-- ======================================================================================
-- THE DEFECT
-- ======================================================================================
-- v10 made sale semantics configurable (public.sale_policies + app.sale_policy_defaults()),
-- which was right. But it stored NO decision: it resolves the policy EVERY TIME A ROW IS
-- READ, against TODAY'S configuration. `sales` holds only `kind`; the meaning of that kind
-- is looked up live. So a routine, forward-looking configuration change silently REWRITES
-- THE MEANING OF SALES THAT COMPLETED MONTHS AGO. Nothing is corrupted and no row is
-- updated — which is precisely why it is dangerous: the books simply read differently
-- tomorrow than they did today, with no diff, no audit row, and no way to reproduce a
-- number that was reported last quarter.
--
-- MEASURED ON LIVE ROWS (business 'QA Test Cafe', 6 completed sales, rolled back):
--   one `insert into sale_policies(package, counts_as_revenue=false, counts_as_visit=true)`
--     historical revenue : 28000 cents -> 18000 cents   (a COMPLETED $100 package sale left
--                                                        the revenue total, retroactively)
--     historical visits  : 3 -> 4                       (a past purchase BECAME a visit)
--     historical points  : 200 -> 200                   (STABLE — see below)
--
-- ======================================================================================
-- THE DIAGNOSIS — mechanism level
-- ======================================================================================
-- Two read-time couplings, both from the same root cause (no stored decision):
--
--  1. REPORTING. Revenue/visits are computed as `sales JOIN app.sale_policy(business, kind)`.
--     The join resolves against current config, so history is a function of the present.
--
--  2. THE RETENTION WINDOW (the subtle one, and the worst). app.on_sale_recorded() builds
--     `v_visit_kinds` from TODAY'S policy, then counts HISTORICAL rows with
--         `and s.kind = any(v_visit_kinds)`
--     i.e. it re-judges every past sale by today's rules. v10's own header calls this a
--     feature ("flip a policy, history is re-judged — verified", Scenario C.4). It is the
--     bug. Flipping a flag retroactively changes which past sales counted as visits, which
--     changes WHEN FUTURE REWARDS FIRE — a config change silently moves the goalposts on
--     in-flight customer entitlements, and can fire a reward a customer did not earn under
--     the rules in force when they earned it.
--
--  WHY POINTS WERE STABLE — AND WHAT IT PROVES. points did NOT move (200 -> 200) because
--  on_sale_recorded MATERIALISES the earn decision into points_ledger at insert time. The
--  earn is a fact, written once. That is the pattern that works, it is already in this
--  codebase, and v10 simply failed to apply it to the other two flags. THIS MIGRATION
--  GENERALISES THE points_ledger PATTERN TO ALL THREE FLAGS. Nothing novel is invented.
--
-- ======================================================================================
-- ARCHITECTURE — A (immutable resolved flags on the sale) vs B (effective-dated versions)
-- ======================================================================================
-- CHOSEN: A (approved in principle by the reviewer). Resolve at record time, write the three
-- booleans onto the sale, report off those columns forever.
--
-- Why A:
--   * It makes historical stability STRUCTURAL, not disciplined. The number cannot drift
--     because there is no live lookup left to drift: reporting is `sum(amount_cents) filter
--     (where counts_as_revenue)` — a column read. B keeps an as-of join on every read, so
--     every future report, export, and trigger must remember to pass the right as-of
--     timestamp. One forgotten `as_of` silently reintroduces this exact P0.
--   * Efficient reporting: no join, no temporal range predicate.
--   * It matches points_ledger, which already demonstrably works (the only flag that
--     survived the defect is the one that was materialised).
--   * The decision is SELF-CONTAINED — the snapshot is the three FLAGS, not a
--     `policy_version` FK. A pointer into config is still a read-time dereference, and
--     `sale_policies` is mutable, so the pointer would resolve through a row someone can
--     edit — the defect, one level of indirection down. Provenance is not lost:
--     `trg_sale_policies_audit` already writes every config change to audit_log, so "what
--     was configured when" is answerable from the audit trail, while "what did this sale
--     mean" is answerable from the sale itself.
--
-- Why NOT B (the honest case against my own choice): B is the textbook bitemporal answer and
-- is strictly more expressive — it can answer "what would Q1 look like under the rules we
-- had in March". Rejected because the owner did not ask for as-of replay; the owner asked
-- for history that does not move. Also: `occurred_at` is caller-supplied and backdatable
-- while `created_at` is insert time, so B must pick one to join on and either choice is
-- wrong somewhere. A sidesteps that entirely. If as-of replay is ever genuinely required, A
-- does not block B — audit_log already holds the raw material.
--
-- IS A SNAPSHOT COLUMN IN TENSION WITH "append-only ledgers + derived views, never a mutable
-- stored balance" (CLAUDE.md)? No — it is the same principle. That rule forbids caching a
-- DERIVED AGGREGATE (a balance). These flags are not an aggregate; they are an ATTRIBUTE OF
-- THE EVENT — what this sale MEANT when it happened — exactly like points_ledger.points
-- records what was earned rather than recomputing it from today's earn rate. Revenue and
-- visit counts remain DERIVED (`sum(...) filter (where counts_as_revenue)`); no total is
-- stored anywhere. The genuine tension is that `sales` was never immutable in the way a
-- ledger must be — so this migration makes it so (section 4).
--
-- ======================================================================================
-- STYLE / SAFETY
-- ======================================================================================
-- plpgsql SECURITY DEFINER + `set search_path = public`; RPCs revoke from public, anon then
-- grant to authenticated. RLS fail-closed.
-- NOTE: `authenticated` has NO USAGE on schema `app` (verified live). So NO security_invoker
-- view may call app.* — it would apply green and fail at SELECT. This migration deliberately
-- exposes NOTHING via a view: historical reporting reads PLAIN COLUMNS ON `sales`.
-- PRE-FLIGHT (re-verified live 2026-07-17, read-only): public.sales = 6 rows, ALL owned by
-- the disposable QA tenant 'QA Test Cafe'; the real tenant 'kopi tiam' has 0 sales.
-- 2 businesses. public.sale_policies = 0 rows and audit_log has 0 rows for
-- entity='sale_policies' — NO OVERRIDE HAS EVER EXISTED, so every historical row was
-- recorded under pure defaults. That is what makes the backfill provably exact rather than a
-- best guess (see BACKFILL PLAN).
-- PRE-FLIGHT ON ROLES (re-verified live; the brief said 5, it is 4):
--   staff_role_check = ('owner','manager','stylist','frontdesk').
--   staff_invites_role_check = ('manager','receptionist','bookkeeper','staff') — a DIFFERENT,
--   mostly NON-OVERLAPPING set. accept_invite() inserts inv.role straight into staff.role, so
--   accepting an invite for 'receptionist' / 'bookkeeper' / 'staff' violates staff_role_check
--   and RAISES. That is a real pre-existing bug, out of scope here, reported not fixed.
--   app.role_perms() below returns an EMPTY permission array for any unknown role, so if that
--   bug is ever fixed by widening staff_role_check, the new roles arrive with NO permissions
--   rather than inheriting some default. Fail-closed by construction.

begin;

-- 1. The snapshot. ---------------------------------------------------------------------
--    Nullable first so the backfill can run; NOT NULL is asserted at the end of section 2,
--    after every existing row has a value.
alter table public.sales
  add column if not exists counts_as_revenue  boolean,
  add column if not exists counts_as_visit    boolean,
  add column if not exists earns_points       boolean,
  add column if not exists policy_resolved_at timestamptz;

comment on column public.sales.counts_as_revenue is
  'IMMUTABLE SNAPSHOT of sale_policies as resolved when this sale was RECORDED. Historical '
  'reporting MUST read this column, never app.sale_policy(). Changed only by '
  'public.reclassify_sale_policy() (audited, owner-only).';
comment on column public.sales.counts_as_visit is
  'Immutable snapshot — see counts_as_revenue. NEVER changeable after insert: the loyalty '
  'ledgers (reward_grants, referrals, credit_ledger) were written against this value.';
comment on column public.sales.earns_points is
  'Immutable snapshot — see counts_as_revenue. NEVER changeable after insert: points_ledger '
  'and points_batches were written against this value.';
comment on column public.sales.policy_resolved_at is
  'When the snapshot was taken (insert time). Backfilled rows carry created_at.';

-- 2. BACKFILL. See BACKFILL PLAN at the foot of this file for the full argument. ---------
--    Correct because sale_policies has never held a row (0 rows, 0 audit history), so
--    app.sale_policy_set() TODAY returns exactly the policy that was in force when each of
--    these 6 rows was recorded. This is a replay of the original decision, not a re-judgement.
--    Runs BEFORE section 4 creates the immutability guard, so it needs no backfill window.
update public.sales s set
  counts_as_revenue  = (select d.counts_as_revenue from app.sale_policy(s.business_id, s.kind) d),
  counts_as_visit    = (select d.counts_as_visit   from app.sale_policy(s.business_id, s.kind) d),
  earns_points       = (select d.earns_points      from app.sale_policy(s.business_id, s.kind) d),
  policy_resolved_at = s.created_at
where counts_as_revenue is null;

--    Fail-closed: an unknown kind (none can exist while sales_kind_check and
--    sale_policy_defaults agree) resolves to NULL above and would trip the NOT NULL below,
--    aborting the migration rather than silently defaulting to "everything counts".
alter table public.sales
  alter column counts_as_revenue  set not null,
  alter column counts_as_visit    set not null,
  alter column earns_points       set not null,
  alter column policy_resolved_at set not null;

-- 3. Indexes. ---------------------------------------------------------------------------
--    Supports the retention window's new predicate (section 6).
create index if not exists sales_visit_window_idx
  on public.sales (business_id, client_id, occurred_at)
  where counts_as_visit;

--    NOTE: sales_amount_cents_check (amount_cents >= 0) is LEFT EXACTLY AS v10 HAS IT. The
--    earlier draft widened it to permit negative reversal rows. With reversals deferred to
--    v11b, widening it now would open the door to negative sales with no code that writes
--    them and no accounting story for them. v11b owns that change.

-- 4. PERMISSIONS — named, explicit, role-mapped. ----------------------------------------
--    v10 gates every sales action on app.is_salon_member(), i.e. "any authenticated member".
--    That is too coarse the moment history becomes restatable: a frontdesk role that can ring
--    up a sale must not also be able to restate closed books or retune accounting policy.
--
--    DECISION: a single helper, app.has_perm(business, permission), over a static role ->
--    permission array. NOT a permissions table. Argued, because a table is the tempting move:
--      * A table means RLS on the table, a UI to edit it, a seeding migration for 2 live
--        tenants, and a new question ("who may grant reclassify_sales?") that recurses.
--      * Per-tenant custom roles are not an asked-for capability and no evidence suggests
--        the beachhead SME wants them. Building the general case now is speculative.
--      * The mapping is 4 roles x 6 permissions. It fits on a screen and it is greppable.
--      * Widening later is cheap: has_perm() is the ONLY call site the rest of the schema
--        knows about, so a table can be slid underneath it without touching a single policy
--        or RPC. The indirection is the point; the storage is not.
--    If the reviewer disagrees, the disagreement is cheap to act on — that is the argument.
--
--    THE SIX PERMISSIONS:
--      view_sales         — read the sales ledger.               owner, manager, stylist, frontdesk
--      create_sales       — record a sale.                       owner, manager, stylist, frontdesk
--      refund_sales       — DEFINED ONLY. GATES NOTHING TODAY.   owner, manager
--      reclassify_sales   — restate a closed sale's revenue.     owner
--      view_finance       — revenue/net reporting (for v11b).    owner, manager
--      manage_sale_policy — edit forward-looking sale policy.    owner
--
--    refund_sales IS A NAME WITH NO SUBJECT. There is no refund path in this schema — v10.1
--    removed the draft one and v11b has not landed. It is defined here so that v11b wires its
--    refund RPC to an existing, already-reviewed permission instead of inventing a seventh
--    one under deadline. Nothing calls it. Do not read its presence as "refunds work".
--
--    view_sales/create_sales resolve TRUE for all four live roles, so this section is a
--    NO-OP for every existing user on day one. The only behaviour changes are:
--      * set_sale_policy() narrows from any member to owner-only (section 7).
--      * reclassify_sale_policy() is owner-only (it is new, so nothing narrows).
create or replace function app.role_perms(p_role text)
returns text[] language sql immutable as $$
  select case p_role
    when 'owner' then array['view_sales','create_sales','refund_sales',
                            'reclassify_sales','view_finance','manage_sale_policy']
    when 'manager' then array['view_sales','create_sales','refund_sales','view_finance']
    when 'stylist' then array['view_sales','create_sales']
    when 'frontdesk' then array['view_sales','create_sales']
    -- Fail closed. An unrecognised role (see the accept_invite note in the header) gets
    -- nothing, rather than falling through to a permissive default.
    else array[]::text[]
  end
$$;

create or replace function app.has_perm(p_business uuid, p_perm text)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.staff s
    where s.business_id = p_business
      and s.user_id = auth.uid()          -- NULL user_id (v11a rota staff) => never matches
      and p_perm = any (app.role_perms(s.role))
  )
$$;

-- 5. IMMUTABILITY. ---------------------------------------------------------------------
--    v10 left `sales_all` as a single `for all` policy: any authenticated member could
--    UPDATE or DELETE a completed sale, so "history is stable" was an unenforced promise.
--    Fixed the way this codebase already does it — points_ledger/credit_ledger grant only
--    SELECT + INSERT via per-command RLS policies and have NO update/delete policy, so RLS
--    denies those verbs fail-closed. `sales` now matches its sibling ledgers.
drop policy if exists sales_all on public.sales;

create policy sales_select on public.sales for select to authenticated
  using (app.has_perm(business_id, 'view_sales'));
create policy sales_insert on public.sales for insert to authenticated
  with check (app.has_perm(business_id, 'create_sales'));
-- (no update/delete policy: RLS denies both for `authenticated`.)

--    Defence in depth — RLS is the fence, the grant is the lock, the trigger (below) is the
--    last resort that also binds roles RLS does not apply to (table owner / service_role).
revoke update, delete, truncate on public.sales from authenticated, anon;

-- 5.1 THE MIGRATION-TIME BACKFILL WINDOW. -----------------------------------------------
--     THE PROBLEM THIS SOLVES, STATED HONESTLY: v10.1 makes `sales` immutable. v11a then
--     needs to UPDATE all 6 historical sales rows to populate its new `branch_id` column
--     (v11a §1.7). That is a LEGITIMATE historical write. Under v10.1 as first drafted, it
--     fails — proven, not assumed, in the chain test at the foot of this file.
--
--     The wrong fixes, and why:
--       * `alter table sales disable trigger` around the backfill — disables immutability
--         GLOBALLY for the duration, for every row and every column, unaudited. Exactly what
--         the reviewer forbade.
--       * Drop and recreate the trigger in v11a — same thing, plus it leaves a window where
--         a concurrent write is unguarded, plus it puts v10.1's invariant in v11a's hands.
--       * Make branch_id exempt by name — v10.1 cannot know about v11a's columns, and
--         hardcoding a future column name into this file inverts the dependency.
--
--     THE MECHANISM: a named, transaction-local, audited window that can only widen the
--     surface to columns that DID NOT EXIST when v10.1 was written.
--       * app.begin_sales_backfill(migration, reason) writes ONE audit_log row naming the
--         migration, the reason, and the database user, then sets a transaction-local GUC.
--       * While that GUC is set, the guard permits UPDATEs to `sales` that leave EVERY
--         v10.1-era column byte-identical — id, business_id, client_id, kind, amount_cents,
--         occurred_at, created_at, note, appointment_id, product_id, qty, and all four
--         snapshot columns. Only columns added by a LATER migration can move.
--       * It is transaction-local (set_config(..., true)), so it cannot outlive the
--         migration's transaction even if end_sales_backfill() is never called.
--       * app.begin_sales_backfill is SECURITY INVOKER with EXECUTE revoked from
--         authenticated and anon, so it is reachable only from a migration/owner context.
--
--     WHAT THIS IS NOT — and I would rather say it than have it discovered: the GUC is not a
--     security boundary. `set_config('app.sales_backfill', ...)` is callable by anyone, so a
--     role that can already UPDATE `sales` can forge the token. Today no such role exists
--     except the table owner and service_role — and either of those can simply DROP the
--     trigger, so the token adds no attack surface it does not already have. This mechanism
--     defends against ACCIDENT (a careless migration, an admin-console typo, a well-meaning
--     future agent), which is what actually caused the P0. It does not defend against a
--     hostile superuser, and no in-database mechanism can.
create or replace function app.begin_sales_backfill(p_migration text, p_reason text)
returns void language plpgsql set search_path = public as $$
begin
  if p_migration is null or length(btrim(p_migration)) < 3 then
    raise exception 'begin_sales_backfill requires the migration name that is opening the window';
  end if;
  if p_reason is null or length(btrim(p_reason)) < 10 then
    raise exception 'begin_sales_backfill requires a reason of at least 10 characters';
  end if;
  insert into audit_log (business_id, actor, action, entity, entity_id, detail)
  values (null, auth.uid(), 'SALES_BACKFILL_WINDOW_OPEN', 'sales', null,
          jsonb_build_object('migration', btrim(p_migration),
                             'reason',    btrim(p_reason),
                             'db_user',   current_user,
                             'opened_at', now(),
                             'scope', 'columns added after v10.1 only; all v10.1-era columns '
                                      'incl. the policy snapshot remain frozen'));
  perform set_config('app.sales_backfill', btrim(p_migration), true);   -- true = txn-local
end $$;
revoke execute on function app.begin_sales_backfill(text, text) from public, anon, authenticated;

create or replace function app.end_sales_backfill()
returns void language plpgsql set search_path = public as $$
begin
  insert into audit_log (business_id, actor, action, entity, entity_id, detail)
  values (null, auth.uid(), 'SALES_BACKFILL_WINDOW_CLOSE', 'sales', null,
          jsonb_build_object('migration', nullif(current_setting('app.sales_backfill', true), ''),
                             'db_user', current_user, 'closed_at', now()));
  perform set_config('app.sales_backfill', '', true);
end $$;
revoke execute on function app.end_sales_backfill() from public, anon, authenticated;

-- 5.2 The guard. Blocks every DELETE, and every UPDATE except two narrow, named windows.
create or replace function app.sales_immutable_guard()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_reclassify text; v_backfill text;
begin
  if tg_op = 'DELETE' then
    raise exception 'sales is append-only: DELETE is not permitted (sale %). There is no '
                    'reversal path in this schema yet — refunds/reversals are deferred to '
                    'v11b.', old.id
      using errcode = 'restrict_violation';
  end if;

  v_reclassify := nullif(current_setting('app.reclassify_sale', true), '');
  v_backfill   := nullif(current_setting('app.sales_backfill',  true), '');

  -- WINDOW 1 — audited accounting reclassification of ONE named row (section 7).
  -- The token is the row id, not a global "admin mode", so the exemption cannot leak to any
  -- other row in the same transaction.
  if v_reclassify is not null and v_reclassify = old.id::text then
    -- OPTION A (reviewer's ruling): counts_as_revenue is the ONLY column that may move.
    -- Everything else — including counts_as_visit and earns_points — is frozen.
    if (new.id, new.business_id, new.client_id, new.kind, new.amount_cents, new.occurred_at,
        new.created_at, new.note, new.appointment_id, new.product_id, new.qty,
        new.counts_as_visit, new.earns_points, new.policy_resolved_at)
       is distinct from
       (old.id, old.business_id, old.client_id, old.kind, old.amount_cents, old.occurred_at,
        old.created_at, old.note, old.appointment_id, old.product_id, old.qty,
        old.counts_as_visit, old.earns_points, old.policy_resolved_at)
    then
      raise exception 'reclassification of sale % may change counts_as_revenue and nothing '
                      'else', old.id
        using errcode = 'restrict_violation';
    end if;
    return new;
  end if;

  -- WINDOW 2 — migration-time attribution backfill (section 5.1). Every column that existed
  -- when v10.1 was written must survive byte-identical; only later-added columns may move.
  if v_backfill is not null then
    if (new.id, new.business_id, new.client_id, new.kind, new.amount_cents, new.occurred_at,
        new.created_at, new.note, new.appointment_id, new.product_id, new.qty,
        new.counts_as_revenue, new.counts_as_visit, new.earns_points, new.policy_resolved_at)
       is distinct from
       (old.id, old.business_id, old.client_id, old.kind, old.amount_cents, old.occurred_at,
        old.created_at, old.note, old.appointment_id, old.product_id, old.qty,
        old.counts_as_revenue, old.counts_as_visit, old.earns_points, old.policy_resolved_at)
    then
      raise exception 'backfill window "%" may only populate columns added after v10.1; it '
                      'may not change any economic fact or the policy snapshot of sale %',
                      v_backfill, old.id
        using errcode = 'restrict_violation';
    end if;
    return new;
  end if;

  raise exception 'sales is append-only: UPDATE is not permitted (sale %). Use '
                  'public.reclassify_sale_policy() for an audited revenue restatement, or '
                  'app.begin_sales_backfill() from a migration to populate a new column.',
                  old.id
    using errcode = 'restrict_violation';
end $$;

drop trigger if exists trg_sales_immutable_guard on public.sales;
create trigger trg_sales_immutable_guard
  before update or delete on public.sales
  for each row execute function app.sales_immutable_guard();

-- 6. THE SNAPSHOT TRIGGER — resolve once, at record time. -------------------------------
--    BEFORE INSERT, so the row is already stamped when the AFTER INSERT trg_sale_recorded
--    fires and can simply read new.*. (BEFORE always precedes AFTER.)
--    Runs for EVERY insert including client_id IS NULL: a walk-in quick_sale with no client
--    earns nothing but is still revenue, and must still be classified.
--    Caller-supplied flag values are ALWAYS overwritten — the snapshot is the database's
--    decision, not the client's. This is what makes "policy is resolved at record time" an
--    invariant rather than a convention.
--    ORDERING vs v11a: v11a adds trg_sales_default_branch, also BEFORE INSERT. Postgres fires
--    BEFORE triggers in name order: 'trg_sale_policy_snapshot' < 'trg_sales_default_branch'
--    ('_' 0x5F < 's' 0x73), so this one runs first. They touch disjoint columns, so the order
--    is irrelevant either way — noted so nobody has to re-derive it.
create or replace function app.on_sale_policy_snapshot()
returns trigger language plpgsql security definer set search_path = public as $$
declare p record;
begin
  select * into p from app.sale_policy(new.business_id, new.kind);
  if not found then
    -- Unknown kind: inert. Cannot happen while sales_kind_check and sale_policy_defaults()
    -- agree; this is the fail-closed guard if they ever drift (v10 Scenario G.5).
    new.counts_as_revenue := false;
    new.counts_as_visit   := false;
    new.earns_points      := false;
  else
    new.counts_as_revenue := p.counts_as_revenue;
    new.counts_as_visit   := p.counts_as_visit;
    new.earns_points      := p.earns_points;
  end if;
  new.policy_resolved_at := now();
  return new;
end $$;

drop trigger if exists trg_sale_policy_snapshot on public.sales;
create trigger trg_sale_policy_snapshot
  before insert on public.sales
  for each row execute function app.on_sale_policy_snapshot();

-- 7. on_sale_recorded now READS THE SNAPSHOT it was just handed. ------------------------
--    Diff vs the live v10 definition, and nothing else:
--      (a) the app.sale_policy_set() aggregate is GONE. The flags arrive on `new`, already
--          resolved by section 6. One less policy read per insert than v10, not one more.
--      (b) the `v_known` guard is gone: an unknown kind snapshots to all-false and is
--          caught by the (earns OR visit) early return, same outcome.
--      (c) THE FIX — the retention window's `s.kind = any(v_visit_kinds)` (today's policy
--          applied to old rows) becomes `s.counts_as_visit` (EACH ROW'S OWN snapshot). The
--          window now counts what those sales meant WHEN THEY HAPPENED. This is the line
--          that stops a config change from moving in-flight reward entitlements.
--    Preserved byte-for-byte in spirit: the points math, the points_batches `fixed`
--    expiry_mode logic, the retention loop's unique_violation swallow, the referral
--    qualification block (its `found` re-check and min_spend_cents comparison), and the
--    binding of referral qualification to counts_as_visit (v10's deliberate choice).
create or replace function app.on_sale_recorded()
returns trigger language plpgsql security definer set search_path = public as $$
declare lp record; rp record; refrow record; refprog record;
        v_pts integer; v_idx integer; v_count integer; v_earn_id uuid;
        w_start timestamptz; w_end timestamptz;
begin
  if new.client_id is null then
    return new;
  end if;

  -- The snapshot resolved at record time. No live policy read: this trigger can no longer
  -- disagree with the row it is processing, nor with the report that reads it later.
  if not (new.earns_points or new.counts_as_visit) then
    return new;
  end if;

  if new.earns_points then
    select * into lp from loyalty_programs
      where business_id = new.business_id and active limit 1;
    if found and lp.kind = 'points' then
      v_pts := floor((new.amount_cents / 100.0) * lp.earn_points_per_dollar);
      if v_pts > 0 then
        insert into points_ledger (business_id, client_id, entry_type, points, sale_id, reference)
        values (new.business_id, new.client_id, 'earn', v_pts, new.id, 'auto-earn on sale')
        on conflict do nothing
        returning id into v_earn_id;
        if v_earn_id is not null then
          insert into points_batches (business_id, client_id, earned, remaining, sale_id, earned_at, expires_at)
          values (new.business_id, new.client_id, v_pts, v_pts, new.id, now(),
                  case when lp.expiry_mode = 'fixed'
                       then now() + make_interval(days => lp.expiry_days) end);
        end if;
      end if;
    end if;
  end if;

  if new.counts_as_visit then
    for rp in select * from retention_programs
        where business_id = new.business_id and active loop
      v_idx := floor(extract(epoch from (new.occurred_at - rp.starts_on::timestamptz))
                     / (rp.period_days * 86400));
      if v_idx >= 0 then
        w_start := rp.starts_on::timestamptz + make_interval(days => v_idx * rp.period_days);
        w_end   := w_start + make_interval(days => rp.period_days);
        -- THE FIX: each historical row is judged by ITS OWN snapshot — what it meant when
        -- it was recorded — not by today's policy for its kind.
        select count(*) into v_count from sales s
          where s.business_id = new.business_id and s.client_id = new.client_id
            and s.counts_as_visit
            and s.occurred_at >= w_start and s.occurred_at < w_end;
        if v_count >= rp.goal_visits then
          begin
            insert into reward_grants (business_id, program_id, client_id, period_index,
                                       reward_type, reward_value, reward_item)
            values (new.business_id, rp.id, new.client_id, v_idx,
                    rp.reward_type, rp.reward_value, rp.reward_item);
            if rp.reward_type = 'credit' and rp.reward_value > 0 then
              insert into credit_ledger (business_id, client_id, entry_type, amount_cents, reference)
              values (new.business_id, new.client_id, 'loyalty_earn',
                      rp.reward_value::integer, 'retention reward: ' || rp.name);
            end if;
          exception when unique_violation then null;
          end;
        end if;
      end if;
    end loop;

    select r.* into refrow from referrals r
      where r.business_id = new.business_id and r.referred_client_id = new.client_id
        and r.status = 'pending' limit 1;
    if found then
      select * into refprog from referral_programs
        where business_id = new.business_id and enabled limit 1;
      if found and new.amount_cents >= coalesce(refprog.min_spend_cents, 0) then
        update referrals set status = 'rewarded', qualified_at = now(),
               reward_cents = refprog.reward_cents
          where id = refrow.id and status = 'pending';
        if found then
          insert into credit_ledger (business_id, client_id, entry_type, amount_cents, reference)
          values (new.business_id, refrow.referrer_client_id, 'referral_reward',
                  refprog.reward_cents, 'referral qualified: first visit completed');
        end if;
      end if;
    end if;
  end if;

  return new;
end $$;

-- 8. set_sale_policy() — unchanged behaviour, narrowed permission. -----------------------
--    The BODY is v10's, byte-for-byte, except the one permission line. This is the whole
--    point of req. 4: set_sale_policy is now PURELY FORWARD-LOOKING. It writes config; the
--    config is read only by the BEFORE INSERT snapshot trigger; therefore it cannot reach a
--    row that already exists. That property is not asserted here — it is structural, and it
--    is what section 6 bought.
--    NARROWING (a real behaviour change, flagged): v10 gated this on is_salon_member, so a
--    stylist could retune the company's accounting. Now manage_sale_policy => owner only.
--    Blast radius today: every live staff row is role='owner' (verified), so no live user
--    loses anything. A future manager will get 'permission denied' where v10 would have let
--    them through; that is the intent.
create or replace function public.set_sale_policy(
  p_business          uuid,
  p_kind              text,
  p_counts_as_revenue boolean,
  p_counts_as_visit   boolean,
  p_earns_points      boolean,
  p_note              text default null)
returns json language plpgsql security definer set search_path = public as $$
declare v_row record;
begin
  if not app.has_perm(p_business, 'manage_sale_policy') then
    raise exception 'only an owner may change sale accounting policy';
  end if;
  if not exists (select 1 from app.sale_policy_defaults() d where d.kind = p_kind) then
    raise exception 'unknown sale kind: %', p_kind;
  end if;
  insert into sale_policies (business_id, kind, counts_as_revenue, counts_as_visit,
                             earns_points, note)
  values (p_business, p_kind, p_counts_as_revenue, p_counts_as_visit, p_earns_points, p_note)
  on conflict (business_id, kind) do update
    set counts_as_revenue = excluded.counts_as_revenue,
        counts_as_visit   = excluded.counts_as_visit,
        earns_points      = excluded.earns_points,
        note              = excluded.note,
        updated_at        = now();
  select * into v_row from app.sale_policy(p_business, p_kind);
  return row_to_json(v_row);
end $$;
revoke execute on function public.set_sale_policy(uuid, text, boolean, boolean, boolean, text)
  from public, anon;
grant execute on function public.set_sale_policy(uuid, text, boolean, boolean, boolean, text)
  to authenticated;

-- 9. REQ 6 — the administrative reclassification path. ----------------------------------
--    Restating history is sometimes legitimate (a firm books packages as revenue for a year,
--    their accountant says defer it, and the prior year must be restated). v10 let that
--    happen BY ACCIDENT, invisibly, as a side effect of a settings toggle. It must instead be
--    impossible to do by accident and impossible to do quietly. Hence:
--      * a SEPARATE RPC — never a side effect of set_sale_policy().
--      * OWNER-ONLY via has_perm(reclassify_sales).
--      * ONE SALE AT A TIME, by explicit id. No bulk verb: a restatement should be a
--        deliberate, enumerable list of rows, and the absence of a bulk verb is a feature.
--      * A MANDATORY REASON, persisted.
--      * AUDITED AS action='RECLASSIFY', with BEFORE and AFTER both recorded (app.audit()
--        records only the new row, which is not enough to reconstruct a restatement).
--
--    ===================================================================================
--    WHY REVENUE ONLY — Option A, the reviewer's ruling, and the reason it is right
--    ===================================================================================
--    This RPC may change counts_as_revenue. It REJECTS any attempt to change earns_points or
--    counts_as_visit. Not because those are less important — because they are MORE entangled.
--
--    counts_as_revenue is a PRESENTATION FACT. It says how one row is aggregated into a
--    report. Nothing else in the database was written because of it. Flip it and the only
--    consequence is that a total changes — which is precisely what a restatement is for.
--
--    earns_points and counts_as_visit are ENTITLEMENT FACTS. When they were resolved at
--    insert time, on_sale_recorded ACTED on them and wrote rows to OTHER LEDGERS:
--        earns_points     -> points_ledger, points_batches
--        counts_as_visit  -> reward_grants, credit_ledger (retention), referrals (qualified_at,
--                            status, reward_cents), credit_ledger (referral_reward)
--    Those ledgers are append-only and this RPC does not touch them. So flipping
--    earns_points = false on a sale that already minted 200 points would leave the sale row
--    saying "this sale earns nothing" while points_ledger says "this sale earned 200" — and
--    the customer's balance still shows 200. The snapshot would contradict the ledger.
--
--    That is the SAME CLASS OF DEFECT this migration exists to kill. v10's bug was that the
--    sale's meaning and the reported number could disagree because the meaning was resolved
--    late. A permissive reclassify would recreate it in a new place: the sale's meaning and
--    the LEDGERS could disagree because the meaning was rewritten late. Freezing the flags
--    and letting a config toggle rewrite them are two different mistakes with one shape.
--
--    THE SNAPSHOT AND THE LEDGERS MUST NEVER DISAGREE. That is the invariant. counts_as_revenue
--    has no ledger, so restating it cannot violate it. The other two do, so restating them
--    without append-only compensating adjustments IN EVERY AFFECTED LEDGER — a points
--    clawback entry, a reward_grant reversal, a referral de-qualification, a credit_ledger
--    correction, each with its own customer-facing and PDPA consequences — necessarily does.
--
--    Entitlement reclassification is therefore a SEPARATE, EXPLICIT WORKFLOW, deferred to
--    v11b alongside refunds (they need the same machinery: an append-only correction in every
--    downstream ledger, plus a decision about what the customer is told). It is not built
--    here, it is not half-built here, and this RPC raises rather than pretending.
create or replace function public.reclassify_sale_policy(
  p_sale              uuid,
  p_counts_as_revenue boolean,
  p_reason            text)
returns json language plpgsql security definer set search_path = public as $$
declare o sales; n sales;
begin
  if p_counts_as_revenue is null then
    raise exception 'p_counts_as_revenue is required (it is the only flag this RPC may change)';
  end if;
  if p_reason is null or length(btrim(p_reason)) < 10 then
    raise exception 'a reason of at least 10 characters is required to reclassify a historical sale';
  end if;

  select * into o from sales where id = p_sale;
  if not found then raise exception 'sale not found'; end if;
  if not app.has_perm(o.business_id, 'reclassify_sales') then
    raise exception 'only an owner may reclassify a historical sale';
  end if;

  if o.counts_as_revenue = p_counts_as_revenue then
    raise exception 'sale % already has counts_as_revenue = %; nothing to restate',
                    p_sale, p_counts_as_revenue;
  end if;

  perform set_config('app.reclassify_sale', p_sale::text, true);   -- true = transaction-local
  update sales set counts_as_revenue = p_counts_as_revenue where id = p_sale
  returning * into n;
  perform set_config('app.reclassify_sale', '', true);             -- close the window immediately

  insert into audit_log (business_id, actor, action, entity, entity_id, detail)
  values (o.business_id, auth.uid(), 'RECLASSIFY', 'sales', o.id,
          jsonb_build_object(
            'reason', p_reason,
            'occurred_at', o.occurred_at,
            'kind', o.kind,
            'amount_cents', o.amount_cents,
            'before', jsonb_build_object('counts_as_revenue', o.counts_as_revenue),
            'after',  jsonb_build_object('counts_as_revenue', n.counts_as_revenue),
            'frozen', jsonb_build_object('counts_as_visit', o.counts_as_visit,
                                         'earns_points',    o.earns_points),
            'note', 'revenue reclassification only. counts_as_visit and earns_points are '
                    'immutable because points_ledger / points_batches / reward_grants / '
                    'referrals / credit_ledger were written against them. No loyalty side '
                    'effect was re-run and none was reversed.'));

  return row_to_json(n);
end $$;
revoke execute on function public.reclassify_sale_policy(uuid, boolean, text) from public, anon;
grant execute on function public.reclassify_sale_policy(uuid, boolean, text) to authenticated;

--    Kill the earlier 5-argument draft if a previous attempt ever installed it, so a stale
--    caller cannot reach a signature that promised to move all three flags.
drop function if exists public.reclassify_sale_policy(uuid, boolean, boolean, boolean, text);
--    And the reversal RPC, which is REMOVED from v10.1 and deferred to v11b.
drop function if exists public.reverse_sale(uuid, text);

commit;

-- ======================================================================================
-- WHAT THE UI MUST READ AFTER THIS (app/index.html — NOT touched by this migration)
-- ======================================================================================
-- The two questions have now genuinely separated, and this is the crux of the change:
--
--   HISTORICAL REPORTING — "what did these sales MEAN?" -> the snapshot columns on `sales`.
--     Dashboard Revenue KPI, both charts, Reports:
--       sb.from('sales').select('id,client_id,amount_cents,occurred_at,kind,counts_as_revenue,counts_as_visit')
--       revenue = sum(amount_cents) where counts_as_revenue      -- replaces `kind !== 'gift_card'`
--       visits  = count(*)          where counts_as_visit
--     This needs NO RPC and NO app.* call (so it cannot hit the schema-app-usage trap), it
--     is stable across policy changes by construction, and it also fixes the pre-existing v5
--     bug where 'membership' rows inflate the visits KPI.
--     Kinds with counts_as_revenue = false stay presented as "cash collected, not revenue"
--     OUTSIDE the revenue total (today gift_card; tomorrow package, if a firm defers it) —
--     but driven by the row's own flag, not a hardcoded kind list.
--
--   CONFIGURATION DISPLAY — "what WILL a new sale mean?" -> get_sale_policy(business).
--     ONLY for the Settings screen. get_sale_policy() must NEVER be joined against historical
--     rows again — that join IS the defect. It describes the future, not the past.
--
--   A Settings change should now say so plainly: "this affects sales recorded from now on.
--   Past sales keep the treatment they were recorded with." That sentence is true only
--   because of this migration.
--
--   Settings must also handle a NEW failure the UI has never seen: set_sale_policy() now
--   raises 'only an owner may change sale accounting policy' for non-owners. Hide or disable
--   the control for them rather than letting them discover it via a red toast.
--
-- ======================================================================================
-- ROLLBACK PLAN  (undo v10.1; leaves the v10 behaviour, defect included, exactly as it was)
-- ======================================================================================
-- Safe to run at any time: v10.1 adds columns and swaps function bodies. It destroys no
-- pre-existing data. The only v10.1-native data are the snapshot columns and audit_log rows
-- with action in ('RECLASSIFY','SALES_BACKFILL_WINDOW_OPEN','SALES_BACKFILL_WINDOW_CLOSE') —
-- all additive. There are no reversal rows to worry about, because v10.1 no longer creates
-- any.
--
--   begin;
--   -- 1. Restore v10's read-time trigger and remove v10.1's.
--   drop trigger if exists trg_sale_policy_snapshot on public.sales;
--   drop trigger if exists trg_sales_immutable_guard on public.sales;
--   drop function if exists app.on_sale_policy_snapshot();
--   drop function if exists app.sales_immutable_guard();
--   drop function if exists app.begin_sales_backfill(text, text);
--   drop function if exists app.end_sales_backfill();
--   --    Re-run section 5 of 20260717_frenly_v10_sale_policy.sql verbatim to restore
--   --    app.on_sale_recorded(), and its set_sale_policy definition to restore the
--   --    is_salon_member gate. (That file is the source of truth; do not hand-retype it.)
--   -- 2. Restore the permissive RLS + grants v10 had.
--   drop policy if exists sales_select on public.sales;
--   drop policy if exists sales_insert on public.sales;
--   create policy sales_all on public.sales for all to authenticated
--     using (app.is_salon_member(business_id)) with check (app.is_salon_member(business_id));
--   grant update, delete on public.sales to authenticated;
--   -- 3. Drop the new RPC + permission helpers.
--   drop function if exists public.reclassify_sale_policy(uuid, boolean, text);
--   drop function if exists app.has_perm(uuid, text);
--   drop function if exists app.role_perms(text);
--   -- 4. Indexes.
--   drop index if exists public.sales_visit_window_idx;
--   -- 5. Columns. Do this LAST and only if you are sure — it discards the snapshots.
--   alter table public.sales
--     drop column if exists counts_as_revenue, drop column if exists counts_as_visit,
--     drop column if exists earns_points,      drop column if exists policy_resolved_at;
--   commit;
--
-- PARTIAL ROLLBACK (recommended if v10.1 misbehaves in the UI rather than in the engine):
--   run steps 1-2 only. The snapshot columns are then dead weight but harmless, history is
--   preserved for a re-apply, and the app reverts to v10 read-time behaviour. Prefer this:
--   dropping the columns is the only irreversible step in the whole plan.
--
-- ======================================================================================
-- BACKFILL PLAN
-- ======================================================================================
-- QUESTION: existing rows predate any snapshot, so what did they MEAN when recorded?
-- ANSWER (this case, provable): exactly what app.sale_policy_set() says today.
--   * public.sale_policies has 0 rows, and audit_log has 0 rows for entity='sale_policies'
--     — the table is audited by trg_sale_policies_audit from the moment it was created, so
--     zero audit rows proves no override has EVER been written and rolled back. Therefore
--     every business has always resolved to app.sale_policy_defaults().
--   * app.sale_policy_defaults() is IMMUTABLE and has not changed since v10 was applied
--     (today, 2026-07-17).
--   Hence the backfill in section 2 REPLAYS the original decision. It is not a re-judgement
--   under new rules — the rules are provably identical. This is the one moment in this
--   system's life when that is true, which is a good reason to apply v10.1 now: every sale
--   recorded after the first override lands would need a judgement call instead of a proof.
--
-- BLAST RADIUS: 6 rows, ALL owned by the disposable QA tenant 'QA Test Cafe'. The real
--   tenant 'kopi tiam' has 0 sales, so no real customer's books move. Verified live at
--   authoring time; RE-VERIFY IMMEDIATELY BEFORE APPLYING:
--     select b.name, count(s.id), count(s.id) filter (where s.counts_as_revenue is null)
--     from businesses b left join sales s on s.business_id = b.id group by b.name;
--
-- POST-APPLY VERIFICATION (must both pass):
--   -- 1. No row escaped the backfill (also guaranteed by the NOT NULL, belt and braces):
--        select count(*) from sales where counts_as_revenue is null;                  -- 0
--   -- 2. THE REGRESSION TEST — the snapshot must agree with what v10 reports TODAY, i.e.
--        v10.1 changes no number on day one; it only freezes them:
--        select count(*) from sales s
--        join lateral app.sale_policy(s.business_id, s.kind) p on true
--        where (s.counts_as_revenue, s.counts_as_visit, s.earns_points)
--              is distinct from (p.counts_as_revenue, p.counts_as_visit, p.earns_points);
--        -- expect 0. Any non-zero row means the backfill and the live resolver disagree:
--        -- STOP and roll back rather than reconcile by hand.
--
-- KNOWN, ACCEPTED, AND FLAGGED: the QA package row (76afd37c…, 10000c) was recorded as
--   kind='retail' and BACKFILLED to 'package' by v10 earlier today. Its snapshot therefore
--   records v10's package defaults (revenue Y, visit N, points Y), not the retail semantics
--   in force at the instant it was inserted (visit Y). v10 already made that ruling and this
--   migration deliberately does not re-litigate it — but it is the single row whose snapshot
--   is a v10 judgement rather than a replay. It belongs to the disposable QA tenant.
--
-- IF THIS EVER RUNS AGAINST A DB WHERE OVERRIDES ALREADY EXIST (i.e. not this one): the
--   proof above collapses and section 2 becomes a re-judgement of history under whatever
--   config happens to be current — the very defect being fixed, applied once, permanently.
--   In that case DO NOT run section 2 as written. Reconstruct each row's policy from
--   audit_log's sale_policies history as at that row's created_at, and have the owner sign
--   off the resulting restatement per the production-write approval gate.
--
-- ======================================================================================
-- COMPOSITION WITH v11a / v11b — VERIFIED, NOT ASSUMED
-- ======================================================================================
-- A single rolled-back transaction ran v10.1 -> v11a -> v11b against live (40 assertions,
-- all passed). Findings that belong in THIS file:
--
--  1. v11a §1.7 `update public.sales s set branch_id = app.default_branch(s.business_id)
--     where s.branch_id is null;` IS BLOCKED by trg_sales_immutable_guard. Confirmed by
--     EXECUTING it, not by reading it:
--        ERROR: sales is append-only: UPDATE is not permitted (sale db32f4fc-…). Use
--               public.reclassify_sale_policy() or app.begin_sales_backfill().
--     …and the assertion immediately after it showed 8 of 8 sales still branch_id IS NULL,
--     i.e. the whole backfill was lost. Applying v11a on top of v10.1 unchanged FAILS.
--     THE FIX IS ONE LINE ON EITHER SIDE OF THAT STATEMENT, IN v11a (v11a is owned by another
--     reviewer; this is the recommendation, not an edit):
--        select app.begin_sales_backfill('frenly_v11a_branches_staff_services',
--                 'populate the new sales.branch_id column on pre-branch historical rows');
--        update public.sales s set branch_id = app.default_branch(s.business_id)
--         where s.branch_id is null;
--        select app.end_sales_backfill();
--     Measured with that wrapper in place:
--        backfill inside the window                    -> 0 rows left null   (was 8)
--        cross-tenant check (branch's business <> sale's) -> 0
--        amount_cents change inside the SAME open window  -> still raises:
--          'backfill window "frenly_v11a…" may only populate columns added after v10.1; it
--           may not change any economic fact or the policy snapshot of sale fc041326-…'
--        counts_as_revenue change inside the SAME open window -> still raises (same message)
--        any sales UPDATE after end_sales_backfill()          -> raises again
--        audit_log rows with action='SALES_BACKFILL_WINDOW_OPEN' -> exactly 1
--     The window widens the surface to new columns only; it never disables immutability.
--  2. v11a's `update public.appointments … set branch_id` is NOT affected — appointments has
--     no immutability guard. Verified: 0 rows left null. Only `sales` is append-only.
--  3. v11a's sales.staff_id is added but never backfilled, so it trips nothing today. Any
--     future staff backfill needs the same window.
--  4. v11b never UPDATEs `sales`. Verified by scanning prosrc of all eight v11b functions for
--     an UPDATE against sales: 0 matches. Payments link to sales by FK from the payments
--     side, so the "payment/refund linkage" concern is structurally absent — nothing writes
--     back to the sale. record_payment() against a v10.1-immutable sale succeeds and
--     sale_balance resolves it to 'paid' with no sales UPDATE anywhere.
--  5. v11b's public.get_revenue_summary() REPRODUCES THE P0 under v10.1 and is now provably
--     wrong in TWO independent ways. It does
--        select array_agg(kind) filter (where counts_as_revenue) from app.sale_policy_set(...)
--        ... where s.kind = any(v_kinds)
--     which is the live-policy join this migration exists to delete. Measured in the chain
--     test at the same instant, same tenant, same date range:
--        get_revenue_summary -> revenue_accrual_cents = 23000
--        snapshot truth      -> 28000
--        revenue_kinds it used = ["service","retail","quick_sale","membership"]
--     The 5000-cent gap decomposes exactly:
--        -10000  it DROPPED a historical package sale that was recorded as revenue, because
--                the config was later flipped -> the original P0, verbatim.
--        + 5000  it COUNTED a sale that an owner had formally restated to non-revenue via
--                reclassify_sale_policy(), because it never looks at the snapshot column ->
--                it silently ignores the audited restatement path entirely.
--     Under v10.1 it MUST read `s.counts_as_revenue` (and drop v_kinds for the accrual and
--     cash legs). v11b is owned elsewhere and is NOT edited here; this is reported, with the
--     chain test as evidence.
-- ======================================================================================

-- ======================================================================================
-- MANUAL TEST SCENARIOS  (executed as rolled-back transactions; see the chain-test report)
-- ======================================================================================
-- Scenario A — THE DEFECT ITSELF, now closed (the headline regression test):
--   1. Record a package sale for client C (policy A: revenue Y, visit N, points Y).
--   2. select public.set_sale_policy('<biz>','package', false, true, true, 'defer revenue');
--   3. Re-read the historical sale.
--      -> counts_as_revenue STILL true, counts_as_visit STILL false. Historical revenue and
--         visit totals UNCHANGED. Under v10 the same call moved revenue 28000 -> 18000 and
--         visits 3 -> 4 on live rows.
--   4. Record a NEW package sale.
--      -> the new row snapshots revenue=false, visit=true (policy B). Old and new rows now
--         legitimately disagree, each correct for its own era. This is req. 1-4 in one test.
--
-- Scenario B — Historical points remain stable (the pattern that already worked).
--
-- Scenario C — THE RETENTION WINDOW judges each row by its own snapshot:
--   1. retention_program: goal_visits = 2, period_days = 30, starts_on = today.
--   2. A package sale (visit N by default), then ONE service sale -> NO reward_grants row.
--   3. set_sale_policy('package', …, counts_as_visit => TRUE, …) — a config change.
--   4. A SECOND service sale -> the reward fires on THIS sale (count = 2: the two service
--      rows), and NOT one sale early. The historical package row is STILL not a visit.
--      THIS IS THE ASSERTION v10's Scenario C.4 GOT BACKWARDS.
--   5. A package sale recorded AFTER step 3 DOES count as a visit (forward-looking).
--
-- Scenario D — Referral qualification is stable across a policy change.
--
-- Scenario E — Immutability is ENFORCED, not promised:
--   1. update sales set counts_as_revenue = false  -> 'sales is append-only: UPDATE is not
--      permitted'. (As authenticated: also no RLS policy and no grant. Three locks.)
--   2. delete from sales                           -> 'DELETE is not permitted'.
--   3. update sales set amount_cents = 1 inside a reclassify window -> blocked.
--   4. insert into sales (…, counts_as_revenue) values (…, true) for a gift_card
--      -> the caller's `true` is IGNORED; the row lands with counts_as_revenue = false.
--
-- Scenario F — The admin reclassification path (req. 6):
--   1. Owner, reason 'oops'        -> 'a reason of at least 10 characters is required'.
--   2. Owner, valid reason         -> counts_as_revenue moves; ONE audit_log row, action
--                                     'RECLASSIFY', with before + after + the frozen flags.
--   3. Non-owner                   -> 'only an owner may reclassify a historical sale'.
--   4. The exemption does not leak: inside the same transaction, an update to a DIFFERENT
--      sale still raises. The token is the row id, not a global "admin mode".
--   5. After the RPC returns, a further update to the SAME row raises again.
--
-- Scenario G — OPTION A IS ENFORCED (the new headline):
--   1. There is no argument by which reclassify_sale_policy can be asked to move
--      counts_as_visit or earns_points — the signature does not accept them.
--   2. A hand-rolled `update sales set earns_points = false` inside an OPEN reclassify window
--      -> 'reclassification of sale % may change counts_as_revenue and nothing else'.
--      This is the assertion that proves the ruling is enforced by the database rather than
--      by the RPC's signature alone.
--
-- Scenario H — The backfill window (section 5.1):
--   1. update sales set branch_id = … with NO window            -> raises.
--   2. begin_sales_backfill('m','a real reason here'); same update -> succeeds.
--   3. Inside the SAME open window, update sales set amount_cents = 1 -> STILL raises.
--   4. begin_sales_backfill writes exactly one audit_log row, action
--      'SALES_BACKFILL_WINDOW_OPEN', naming the migration, reason and db_user.
--   5. begin_sales_backfill('m', 'short') -> raises on the reason length.
--
-- Scenario I — NULL inherits; explicit beats default (v10 semantics preserved).
-- Scenario J — Tenant isolation: business Y's override does not touch X's snapshots.
-- Scenario K — Historical exports are byte-identical across a full policy flip.
-- ======================================================================================
