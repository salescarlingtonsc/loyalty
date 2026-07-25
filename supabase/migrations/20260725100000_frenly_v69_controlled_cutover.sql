-- FRENLY v69 - CONTROLLED CUTOVER (the increment that lets real customer money move)
--
-- Pinned contract: docs/design/ps2/PS2_LIVE_V69_CUTOVER_CONTRACT.md. Forward-only; v61-v68c are
-- not rewritten except for the five surgical replacements enumerated in §0 below.
--
-- WHAT THIS MIGRATION DOES AND DOES NOT DO. It makes public.sv_authority.state = 'live' REACHABLE
-- for exactly one owner-designated business through an evidence-checked, super-admin-designated,
-- audited, idempotent, fail-closed RPC. Applying it activates NOBODY: no authority row changes
-- state here, and the postcondition block at the bottom PROVES that by comparing a
-- (state, count) census taken before any object in this file is created against the same census
-- taken after. Designating and cutting over the pilot business is a separate runtime act.
--
-- =====================================================================================
-- §0 THE FIVE REPLACED FUNCTIONS AND THEIR EXACT DELTAS
--   Each body below was lifted VERBATIM from its latest prior definition and edited with a single
--   asserted replacement (except preview_sv_cutover, which is a justified rewrite).
--
--   1. app.sv_authority_guard()            (v61 §6) - REWRITTEN GUARD BODY. 'ready_for_cutover'
--      stays unconditionally rejected, word for word. 'live' is no longer unconditionally
--      rejected; instead it now requires a matching public.sv_cutover_events row written in the
--      SAME transaction (see §4). Deletion stays forbidden, verbatim.
--   2. app.sv_apply_authority_state(...)   (v62 §4) - ADDED: 'live' is terminal on this path.
--   3. public.run_sv_reconciliation(uuid)  (v62 §7) - ADDED: the scheduled-automation caller is
--      accepted alongside the owner; and a LIVE tenant is never downgraded to
--      'reconciliation_blocked' by a run (the discrepancy is still fully recorded).
--   4. public.sv_expire_due(uuid,integer)  (v64 §5g) - ADDED: scheduled-automation caller.
--   5. public.sv_release_expired_checkout_tenders(uuid,integer) (v67 §9) - ADDED: same.
--   6. public.get_sv_authority_overview(uuid) (v64 §6) - can_cutover stops being hardcoded false.
--   7. public.preview_sv_cutover(uuid)     (v64 §7) - REWRITTEN (§6 below explains every byte).
--   NO pg_get_functiondef splice is used anywhere in this migration.
--
-- =====================================================================================
-- §1 HOW 'live' BECOMES REACHABLE - AND WHY NOTHING ELSE CAN REACH IT
--   public.set_sv_authority_state (v62 §5) is NOT touched: its hard CHECK still refuses to name
--   'live'/'ready_for_cutover' at all (22023). app.sv_apply_authority_state (the internal path)
--   still refuses the same two states, and now additionally refuses to LEAVE 'live'.
--   The v61 table guard is the tripwire and it stays a tripwire: an UPDATE that sets state='live'
--   is rejected unless a public.sv_cutover_events row for that exact (business_id, asset) was
--   inserted by the SAME transaction (matched on a stored top-level transaction id). The only
--   FUNCTION writer of sv_cutover_events is public.sv_cutover_business - that table has RLS on, every
--   browser privilege revoked, an append-only trigger, and a UNIQUE(business_id, asset) that makes
--   a second cutover of the same business structurally impossible. (rev-2, review D3: the "one
--   writer" claim is precisely "exactly one catalog FUNCTION writer", which the postcondition
--   machine-checks. service_role - BYPASSRLS, not a browser role - can still DML these v69 tables
--   directly via SQL, consistent with its chain-wide DML posture; the append-only/immutable triggers
--   still bite it, and the browser roles anon/authenticated cannot write at all.) So the reachability
--   chain is exactly one function long, and a stolen owner session that could somehow UPDATE
--   sv_authority directly still cannot reach 'live'. An INSERT can never be 'live' either (a business
--   is never born live).
--
-- =====================================================================================
-- §1a ONE LIVE BUSINESS PLATFORM-WIDE - THE STRUCTURAL EXPRESSION OF THE PS-2 LIVE "ONE PILOT"
--     MANDATE (rev-2, review D1). The mandate is "one pilot business is live at a time", and it is
--     enforced on the AUTHORITY, not on designations:
--       * STRUCTURAL BOUND: a partial unique index public.sv_authority (asset) WHERE state = 'live'
--         (§10a) allows at most one live row per asset across the WHOLE platform. Because 'live' is
--         irreversible (§5), a mistaken second cutover would be unrecoverable, so this makes a second
--         live transition fail at the constraint (23505) even under a true race between two DIFFERENT
--         businesses cutting over concurrently (they take DIFFERENT per-business advisory locks, so
--         they do not serialise against each other; the index is the backstop that does). Prod has 0
--         live rows, so the index applies cleanly.
--       * TYPED CODE: app.sv_cutover_readiness emits sv_pilot_already_live (§12) when a DIFFERENT
--         business already holds sv_authority.state='live' for the asset; readiness is then false and
--         sv_cutover_business raises that typed error through the same precedence->raise path every
--         other refusal uses, so preview and act AGREE. The typed code is the normal, serialised
--         answer (the other business is already committed-live); the unique index is the belt-and-
--         braces answer for the uncommitted-race window.
--     The designation singleton index (§8) is NOT this enforcement: it bounds concurrent
--     DESIGNATIONS only (at most one active designation at a time, so the SA hands the pilot slot to
--     one firm), which is a weaker property - revoke-A / designate-B / cutover-B could otherwise
--     reach two live businesses. The one-live invariant above is what actually forbids that.
--
-- =====================================================================================
-- §2 SV AUTOMATION MUST EXIST BEFORE ANYONE GOES LIVE (contract §2)
--   Value that can expire with no scheduled sweep is value that silently rots, so this migration
--   schedules all three stored-value jobs, following the existing frenly-* conventions (SGT-anchored
--   daily work in the small hours; the 19:00-19:20 UTC = 03:00-03:20 SGT block is already taken by
--   points expiry / membership renewals / referral shadow / expense recurrences, so the two new
--   daily jobs sit at 19:35 and 19:45 UTC = 03:35 and 03:45 SGT):
--     frenly-sv-expiry           35 19 * * *   app.run_sv_expiry_sweep(1000)
--     frenly-sv-tender-release   */3 * * * *   app.run_sv_tender_release(1000)
--     frenly-sv-reconciliation   45 19 * * *   app.run_sv_reconciliation_sweep()
--   and public.sv_cutover_business REFUSES with sv_automation_missing if any of the three is
--   absent or inactive.
--
--   WHY THE THREE RPCs NEEDED A ONE-CLAUSE EDIT. All three are owner-gated on app.is_salon_owner,
--   which reads auth.uid(); a pg_cron job has no JWT, so auth.uid() is NULL and every call would
--   raise 42501. The two alternatives were both worse: duplicating ~230 lines of money logic into
--   app.* twins (guaranteed drift), or having the driver impersonate a real owner's user id (which
--   would write that human's uuid into sv_operations.actor and audit_log.actor for work they never
--   did - a truthfulness defect this repo does not accept). Instead the drivers open a marker row
--   in public.sv_automation_runs and the gate accepts app.sv_automation_context(), which is true
--   ONLY inside a transaction that already holds such a marker. The marker table is RLS-on, has
--   every browser privilege revoked and is append-only; its only writer is app.sv_automation_begin,
--   which is itself revoked from public/anon/authenticated. A browser therefore cannot manufacture
--   the context, and under automation actor stays NULL - the audit trail says "system", truthfully.
--
--   INTERACTION DEFECT CLOSED BY THIS MIGRATION. run_sv_reconciliation drives a business with open
--   discrepancies to 'reconciliation_blocked'. Scheduling it daily WITHOUT the §0.3 change would
--   mean a live tenant that grows a single gift-card discrepancy is silently un-lived overnight -
--   every customer's stored value instantly unspendable (sv_not_live), with no RPC path back.
--   Contract §5 pins the opposite: live is not reversible by RPC and pause is the emergency
--   control. Both halves of the fix are belt-and-braces: the reconciliation skips the downgrade,
--   and app.sv_apply_authority_state refuses to leave 'live' at all.
--
--   POST-APPLY CANARY NOTE (rev-2, review D5). run_sv_reconciliation_sweep runs nightly over EVERY
--   business whose stored value is not 'unbuilt', and each run_sv_reconciliation call APPENDS one
--   public.sv_reconciliation_snapshots row plus one SV_RECONCILIATION_RUN audit_log row for that
--   business. So the sweep is expected to grow those two append-only tables by one row per
--   non-unbuilt business per day. "Canary unchanged" after apply therefore means authority STATE and
--   value rows (sv_authority states, sv_lots/sv_lot_movements) are unchanged - NOT that no new
--   snapshot/audit rows appear; those daily rows are the monitoring signal working as designed.
--
-- =====================================================================================
-- §3 THE CUTOVER RPC (contract §3)
--   public.sv_cutover_business(p_business, p_reason, p_evidence_hash, p_idempotency_key).
--   Business owner performs it; a SUPER ADMIN must have designated the business first. That is the
--   contract's "super-admin co-authorization if cheap to express" - two distinct principals, both
--   recorded, expressible in one small table rather than an impossible same-session co-signature.
--   A firm cannot put itself live, exactly as a firm cannot price itself (v14 seat billing).
--   Reason >= 10 characters: this is a financial go-live, not a toggle.
--   p_evidence_hash must equal the hash preview_sv_cutover just returned; if any condition moved
--   since the preview the call is refused (sv_evidence_stale) rather than acting on stale evidence.
--   Typed refusals, evaluated in this fixed precedence: sv_synthetic_business, sv_already_live,
--   sv_not_designated, sv_not_ready, sv_reconciliation_unclean, sv_paused, sv_automation_missing.
--   NEVER global: one business id, no loop, no wildcard, no 'all'. The single UPDATE inside this
--   function is keyed by business_id = p_business, and sv_cutover_events.UNIQUE(business_id, asset)
--   means one row per business forever.
--   Envelope: sv_operations (unique key + request hash + advisory locks + cached replay), with the
--   'cutover' operation type added to the vocabulary. A refused attempt writes NOTHING and reserves
--   no idempotency key (every refusal precedes the envelope insert).
--
-- =====================================================================================
-- §4 WHY A NEW sv_cutover_events TABLE RATHER THAN sv_plan_status_events
--   sv_plan_status_events is FK-bound to (plan_id, business_id) in public.sv_plans, CHECKs
--   new_status in ('active','retired'), and carries no evidence hash, no operation link and no
--   reason-length floor. A cutover is not a plan lifecycle event: it has no plan, its status is
--   'live', it must carry the evidence hash and readiness snapshot it acted on, and it needs the
--   authorizing transaction id that makes the sv_authority tripwire work. Reusing that table would
--   have meant widening a CHECK, dropping an FK and adding four columns to a plan table - a larger
--   and more confusing change than one purpose-built append-only table.
--
-- =====================================================================================
-- §5 REVERSIBILITY (contract §5) - PINNED DEFAULT, FLAGGED FOR OWNER RATIFICATION
--   Cutover is NOT reversible by RPC. public.sv_pause (all/earn/redeem) is the emergency control;
--   it does not consult sv_authority and therefore keeps working unchanged on a live business, and
--   lifting a pause stays a separate confirmed action. A downgrade out of 'live' would strand
--   issued value (every balance instantly unspendable with no defined disposition), so this
--   migration deliberately does not invent one. If the owner wants a supervised wind-down path it
--   belongs in its own increment with a value-disposition design, not here.
--
-- =====================================================================================
-- §6 TRUTHFUL READINESS (contract §4)
--   preview_sv_cutover's 'ready' was HARDCODED false. It is now computed by
--   app.sv_cutover_readiness - the SAME oracle sv_cutover_business consults - so preview and act
--   cannot disagree: the RPC raises the typed error belonging to the FIRST code in the readiness
--   object's blocking_codes array, and returns ok exactly when that array is empty.
--   Three of the four pre-existing reason strings are preserved BYTE FOR BYTE:
--     'reconciliation has not been run'
--     'reconciliation has N open discrepancy(ies); it must be clean'
--     'an all-scope stored-value pause is active'
--   Two are deliberately changed, and this is flagged rather than done silently:
--     (a) the standing reason 'cutover is a future authorized phase - no cutover action exists in
--         PS-2A' is REMOVED. It asserted a fact this migration falsifies, and keeping it would pin
--         ready=false forever, making the contract's own preview<->act agreement unachievable.
--     (b) the authority reason's parenthetical said cutover requires the state to ALREADY be
--         'live'. Under v69 cutover is the act of BECOMING live, so that sentence was backwards.
--         The prefix 'authority is <state> ' is kept; the parenthetical now states the real
--         precondition (shadow_testing) and 'live' gets its own already-live reason.
--   Everything else is additive: designation, automation, synthetic and reconciliation-status
--   reasons are appended.
--
-- =====================================================================================
-- §7 LOW-1 CARRIED FORWARD FROM THE v68b REVIEW (contract §6)
--   Door-A (public.sv_reverse_spend) racing door-B (public.reverse_sale -> the sale core's
--   settlement reversal) currently resolves through Postgres deadlock detection: the loser gets
--   40P01, money invariants hold, nothing is double-reversed. CHOICE MADE HERE: document 40P01 as
--   an accepted, retriable outcome rather than re-order the locks. Imposing an advisory-lock-first
--   order inside the sale core means editing reverse_sale_v20_base - the single most heavily
--   spliced function in the chain (v34, v67 §11a, v68b §11a) - on the same migration that first
--   lets real money move. That trade is not worth it. The documentation is machine-visible
--   (COMMENT ON FUNCTION) so it can be asserted by a test instead of living only in prose.

begin;

-- =====================================================================
-- 1. CENSUS BEFORE. Snapshot every authority state so the postcondition can PROVE that applying
--    v69 cut nobody over. Held in a TEMP table dropped at commit.
-- =====================================================================
create temporary table v69_authority_census_before on commit drop as
select business_id, asset, state from public.sv_authority;

-- =====================================================================
-- 2. sv_operations operation_type vocabulary: add 'cutover'. Same catalog-resolved shape v68a
--    used (the v61 CHECK is inline+unnamed in some environments and named in others, so the name
--    is looked up rather than assumed). Only WIDENS the accepted set.
--    A 'cutover' operation writes no sv_lot_movements - exactly like 'reserve'/'release', which
--    already exist as movement-free operation types.
-- =====================================================================
do $v69_operation_type_vocab$
declare v_name text; v_def text;
begin
  select c.conname, pg_get_constraintdef(c.oid) into v_name, v_def
    from pg_constraint c
   where c.conrelid = 'public.sv_operations'::regclass and c.contype = 'c'
     and pg_get_constraintdef(c.oid) like '%operation_type%';
  if v_name is null then
    raise exception 'v69: the sv_operations operation_type CHECK constraint was not found';
  end if;
  if position('cutover' in v_def) > 0 then
    raise exception 'v69: sv_operations already accepts cutover operations';
  end if;
  if position('''chargeback''' in v_def) = 0 or position('''correction''' in v_def) = 0 then
    raise exception 'v69: unexpected sv_operations operation_type CHECK definition: %', v_def;
  end if;
  execute format('alter table public.sv_operations drop constraint %I', v_name);
end
$v69_operation_type_vocab$;

alter table public.sv_operations
  add constraint sv_operations_operation_type_check check (operation_type in
    ('topup', 'grant', 'spend', 'reserve', 'release', 'expire', 'reverse', 'refund', 'adjust',
     'chargeback', 'correction', 'cutover'));

-- =====================================================================
-- 3. public.sv_automation_runs - the scheduled-automation marker (see header §2). One row per
--    scheduled sweep. Append-only with a write-once completion (the sv_pauses lift-once shape):
--    identity is immutable, no delete, finished_at/summary settable exactly once. Super-admin READ
--    only - this is platform machinery, not tenant data - and every browser privilege revoked.
-- =====================================================================
create table public.sv_automation_runs (
  id uuid primary key default gen_random_uuid(),
  job_name text not null check (job_name in
    ('sv_expiry_sweep', 'sv_tender_release', 'sv_reconciliation_sweep')),
  run_txid bigint not null,
  started_at timestamptz not null default now(),
  finished_at timestamptz,
  summary jsonb,
  constraint sv_automation_runs_finish_presence check ((finished_at is null) = (summary is null))
);
create index sv_automation_runs_job_idx on public.sv_automation_runs (job_name, started_at desc);
create index sv_automation_runs_txid_idx on public.sv_automation_runs (run_txid);

create or replace function app.sv_automation_runs_guard()
returns trigger language plpgsql security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
begin
  if tg_op = 'DELETE' then
    raise exception 'sv_automation_runs is append-only' using errcode = 'restrict_violation';
  end if;
  if old.finished_at is not null then
    raise exception 'this stored-value automation run is already finished (write-once)' using errcode = 'restrict_violation';
  end if;
  if new.id is distinct from old.id
     or new.job_name is distinct from old.job_name
     or new.run_txid is distinct from old.run_txid
     or new.started_at is distinct from old.started_at then
    raise exception 'stored-value automation run identity is immutable' using errcode = 'restrict_violation';
  end if;
  if new.finished_at is null or new.summary is null then
    raise exception 'finishing a stored-value automation run requires finished_at and summary' using errcode = 'restrict_violation';
  end if;
  return new;
end $$;
revoke all on function app.sv_automation_runs_guard() from public, anon, authenticated;
create trigger sv_automation_runs_guard
  before update or delete on public.sv_automation_runs
  for each row execute function app.sv_automation_runs_guard();

alter table public.sv_automation_runs enable row level security;
create policy sv_automation_runs_sa_read on public.sv_automation_runs
  for select to authenticated using (app.is_super_admin());
revoke all on public.sv_automation_runs from public, anon, authenticated;
grant select on public.sv_automation_runs to authenticated;

-- =====================================================================
-- 4. The automation context. app.sv_automation_context() is TRUE only inside a transaction that
--    already opened a marker row. pg_current_xact_id_if_assigned() is used (never
--    pg_current_xact_id()) so a plain owner call never burns a transaction id just to answer the
--    question, and it returns the TOP-LEVEL id, so a per-business subtransaction inside a driver
--    still resolves to the run's transaction.
-- =====================================================================
create or replace function app.sv_automation_begin(p_job text)
returns uuid language plpgsql security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare v_id uuid;
begin
  insert into public.sv_automation_runs(job_name, run_txid)
  values (p_job, pg_catalog.pg_current_xact_id()::text::bigint)
  returning id into v_id;
  return v_id;
end $$;
revoke all on function app.sv_automation_begin(text) from public, anon, authenticated;

create or replace function app.sv_automation_finish(p_run uuid, p_summary jsonb)
returns void language plpgsql security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
begin
  update public.sv_automation_runs
     set finished_at = now(), summary = coalesce(p_summary, '{}'::jsonb)
   where id = p_run;
end $$;
revoke all on function app.sv_automation_finish(uuid, jsonb) from public, anon, authenticated;

create or replace function app.sv_automation_context()
returns boolean language sql stable security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
  select exists (
    select 1 from public.sv_automation_runs r
     where r.run_txid = pg_catalog.pg_current_xact_id_if_assigned()::text::bigint
       and r.finished_at is null);
$$;
revoke all on function app.sv_automation_context() from public, anon, authenticated;

-- =====================================================================
-- 5. app.sv_automation_status() - is the stored-value automation actually scheduled AND active?
--    Reads cron.job defensively: pg_cron may be absent (bare rehearsal cluster), and the local
--    rehearsal stub's cron.job has no `active` column, so the column is introspected rather than
--    assumed. Absent cron.job => not ok => the cutover refuses. Fail-closed in every direction.
-- =====================================================================
create or replace function app.sv_automation_status()
returns jsonb language plpgsql stable security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_required text[] := array['frenly-sv-expiry', 'frenly-sv-tender-release', 'frenly-sv-reconciliation'];
  v_found text[] := '{}'::text[];
  v_missing text[];
  v_has_active boolean;
begin
  if to_regclass('cron.job') is null then
    return jsonb_build_object(
      'required', to_jsonb(v_required), 'scheduled', '[]'::jsonb,
      'missing', to_jsonb(v_required), 'ok', false, 'basis', 'cron.job is absent');
  end if;
  select exists (
    select 1 from pg_attribute a
     where a.attrelid = 'cron.job'::regclass and a.attname = 'active'
       and a.attnum > 0 and not a.attisdropped)
    into v_has_active;
  execute format(
    'select coalesce(array_agg(distinct j.jobname), ''{}''::text[]) from cron.job j where j.jobname = any($1)%s',
    case when v_has_active then ' and j.active' else '' end)
    into v_found using v_required;
  select coalesce(array_agg(m order by m), '{}'::text[]) into v_missing
    from (select unnest(v_required) except select unnest(v_found)) s(m);
  return jsonb_build_object(
    'required', to_jsonb(v_required),
    'scheduled', to_jsonb((select coalesce(array_agg(f order by f), '{}'::text[]) from unnest(v_found) s(f))),
    'missing', to_jsonb(v_missing),
    'ok', (coalesce(array_length(v_missing, 1), 0) = 0),
    'basis', case when v_has_active then 'cron.job.active' else 'cron.job presence (no active column)' end);
end $$;
revoke all on function app.sv_automation_status() from public, anon, authenticated;

-- =====================================================================
-- 6. The three scheduled drivers. Each opens ONE marker row, iterates a deterministic, narrowly
--    scoped business set, and isolates a per-business failure so one bad tenant cannot stop the
--    sweep for everyone else. Failures are recorded in audit_log with actor NULL (system).
--    NONE of them can transition an authority state - they only call the value RPCs.
-- =====================================================================
create or replace function app.run_sv_expiry_sweep(p_limit integer default 1000)
returns integer language plpgsql security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare v_run uuid; v_b uuid; v_done integer := 0; v_failed integer := 0;
begin
  v_run := app.sv_automation_begin('sv_expiry_sweep');
  for v_b in
    select a.business_id from public.sv_authority a
     where a.asset = 'stored_value' and a.state = 'live'
     order by a.business_id
  loop
    begin
      perform public.sv_expire_due(v_b, p_limit);
      v_done := v_done + 1;
    exception when others then
      v_failed := v_failed + 1;
      insert into public.audit_log(business_id, actor, action, entity, entity_id, detail)
      values (v_b, null, 'SV_AUTOMATION_ERROR', 'sv_automation_runs', v_run, jsonb_build_object(
        'job', 'sv_expiry_sweep', 'sqlstate', sqlstate, 'message', sqlerrm));
    end;
  end loop;
  perform app.sv_automation_finish(v_run, jsonb_build_object('succeeded', v_done, 'failed', v_failed));
  return v_done;
end $$;
revoke all on function app.run_sv_expiry_sweep(integer) from public, anon, authenticated;

create or replace function app.run_sv_tender_release(p_limit integer default 1000)
returns integer language plpgsql security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare v_run uuid; v_b uuid; v_done integer := 0; v_failed integer := 0;
begin
  v_run := app.sv_automation_begin('sv_tender_release');
  -- Scoped by outstanding work, not by authority: an abandoned hold must be released even if the
  -- business was paused after the hold was taken, or its balance stays stranded.
  for v_b in
    select distinct t.business_id from public.checkout_sv_tenders t
     where t.status = 'reserved'
     order by t.business_id
  loop
    begin
      perform public.sv_release_expired_checkout_tenders(v_b, p_limit);
      v_done := v_done + 1;
    exception when others then
      v_failed := v_failed + 1;
      insert into public.audit_log(business_id, actor, action, entity, entity_id, detail)
      values (v_b, null, 'SV_AUTOMATION_ERROR', 'sv_automation_runs', v_run, jsonb_build_object(
        'job', 'sv_tender_release', 'sqlstate', sqlstate, 'message', sqlerrm));
    end;
  end loop;
  perform app.sv_automation_finish(v_run, jsonb_build_object('succeeded', v_done, 'failed', v_failed));
  return v_done;
end $$;
revoke all on function app.run_sv_tender_release(integer) from public, anon, authenticated;

create or replace function app.run_sv_reconciliation_sweep()
returns integer language plpgsql security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare v_run uuid; v_b uuid; v_done integer := 0; v_failed integer := 0;
begin
  v_run := app.sv_automation_begin('sv_reconciliation_sweep');
  -- Every business that has begun stored value: pre-cutover evidence has to stay fresh (the
  -- cutover requires a clean run) and a live business has to stay monitored.
  for v_b in
    select a.business_id from public.sv_authority a
     where a.asset = 'stored_value' and a.state <> 'unbuilt'
     order by a.business_id
  loop
    begin
      perform public.run_sv_reconciliation(v_b);
      v_done := v_done + 1;
    exception when others then
      v_failed := v_failed + 1;
      insert into public.audit_log(business_id, actor, action, entity, entity_id, detail)
      values (v_b, null, 'SV_AUTOMATION_ERROR', 'sv_automation_runs', v_run, jsonb_build_object(
        'job', 'sv_reconciliation_sweep', 'sqlstate', sqlstate, 'message', sqlerrm));
    end;
  end loop;
  perform app.sv_automation_finish(v_run, jsonb_build_object('succeeded', v_done, 'failed', v_failed));
  return v_done;
end $$;
revoke all on function app.run_sv_reconciliation_sweep() from public, anon, authenticated;

-- =====================================================================
-- 7. SGT cron discipline (the frenly-* convention; see header §2). Scheduling is skipped only when
--    there is no cron.job at all; when there IS one, a failure to schedule must fail the migration
--    rather than ship a live-capable chain with no sweeps.
-- =====================================================================
do $v69_cron$
begin
  if to_regclass('cron.job') is null then
    raise notice 'v69: pg_cron is absent; stored-value automation is NOT scheduled and sv_cutover_business will refuse with sv_automation_missing';
  else
    perform cron.schedule('frenly-sv-expiry',         '35 19 * * *', $c$select app.run_sv_expiry_sweep(1000);$c$);
    perform cron.schedule('frenly-sv-tender-release', '*/3 * * * *', $c$select app.run_sv_tender_release(1000);$c$);
    perform cron.schedule('frenly-sv-reconciliation', '45 19 * * *', $c$select app.run_sv_reconciliation_sweep();$c$);
  end if;
end
$v69_cron$;

-- =====================================================================
-- 8. public.sv_cutover_designations - the super-admin half of the co-authorization (header §3).
--    Append-only-ish: revoked_at/revoked_by are settable exactly once and identity is immutable.
--    TWO partial unique indexes:
--      * one ACTIVE designation per (business, asset);
--      * at most ONE active designation platform-wide. This bounds concurrent DESIGNATIONS only (it
--        hands the pilot slot to one firm at a time); it is NOT the one-live-business enforcement -
--        revoke-A / designate-B / cutover-B would otherwise slip a second business to live past it
--        (rev-2, review D1). The actual "one pilot live" mandate is enforced on the AUTHORITY: the
--        sv_authority (asset) WHERE state='live' unique index (§10a) plus the sv_pilot_already_live
--        readiness code (§12); see header §1a. A later increment that widens the pilot drops these
--        deliberately and visibly.
--    Owner + super-admin READ, browser writes revoked (definer RPC only). A second concurrent
--    designation is refused with the typed sv_pilot_already_designated under the global advisory lock
--    (rev-2, review D2), not a raw 23505 on the singleton index.
-- =====================================================================
create table public.sv_cutover_designations (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  asset text not null default 'stored_value' check (asset = 'stored_value'),
  designated_by uuid not null,
  reason text not null check (char_length(btrim(reason)) >= 10),
  designated_at timestamptz not null default now(),
  revoked_at timestamptz,
  revoked_by uuid,
  created_at timestamptz not null default now(),
  constraint sv_cutover_designations_id_business_uk unique (id, business_id),
  constraint sv_cutover_designations_revoke_presence check ((revoked_at is null) = (revoked_by is null))
);
create unique index sv_cutover_designations_active_uk
  on public.sv_cutover_designations (business_id, asset) where revoked_at is null;
create unique index sv_cutover_designations_singleton_uk
  on public.sv_cutover_designations (asset) where revoked_at is null;
create index sv_cutover_designations_business_idx
  on public.sv_cutover_designations (business_id, designated_at desc);

create or replace function app.sv_cutover_designations_guard()
returns trigger language plpgsql security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
begin
  if tg_op = 'DELETE' then
    raise exception 'sv_cutover_designations is append-only' using errcode = 'restrict_violation';
  end if;
  if old.revoked_at is not null then
    raise exception 'this stored-value cutover designation is already revoked (write-once)' using errcode = 'restrict_violation';
  end if;
  if new.id is distinct from old.id
     or new.business_id is distinct from old.business_id
     or new.asset is distinct from old.asset
     or new.designated_by is distinct from old.designated_by
     or new.reason is distinct from old.reason
     or new.designated_at is distinct from old.designated_at
     or new.created_at is distinct from old.created_at then
    raise exception 'stored-value cutover designation identity is immutable' using errcode = 'restrict_violation';
  end if;
  if new.revoked_at is null or new.revoked_by is null then
    raise exception 'revoking a stored-value cutover designation requires revoked_at and revoked_by' using errcode = 'restrict_violation';
  end if;
  return new;
end $$;
revoke all on function app.sv_cutover_designations_guard() from public, anon, authenticated;
create trigger sv_cutover_designations_guard
  before update or delete on public.sv_cutover_designations
  for each row execute function app.sv_cutover_designations_guard();

alter table public.sv_cutover_designations enable row level security;
create policy sv_cutover_designations_owner_read on public.sv_cutover_designations
  for select to authenticated using (app.is_salon_owner(business_id));
create policy sv_cutover_designations_sa_read on public.sv_cutover_designations
  for select to authenticated using (app.is_super_admin());
revoke all on public.sv_cutover_designations from public, anon, authenticated;
grant select on public.sv_cutover_designations to authenticated;

-- =====================================================================
-- 9. public.sv_cutover_events - the append-only cutover record AND the reachability key for the
--    sv_authority tripwire (header §1/§4). UNIQUE(business_id, asset) = one cutover per business,
--    ever, structurally. Fully immutable: no update, no delete.
-- =====================================================================
create table public.sv_cutover_events (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  asset text not null default 'stored_value' check (asset = 'stored_value'),
  operation_id uuid not null,
  actor uuid,
  designation_id uuid,
  designated_by uuid,
  prior_state text not null,
  new_state text not null check (new_state = 'live'),
  reason text not null check (char_length(btrim(reason)) >= 10),
  evidence_hash text not null check (evidence_hash ~ '^[0-9a-f]{64}$'),
  readiness jsonb not null,
  authorized_txid bigint not null,
  created_at timestamptz not null default now(),
  constraint sv_cutover_events_business_asset_uk unique (business_id, asset),
  constraint sv_cutover_events_id_business_uk unique (id, business_id),
  constraint sv_cutover_events_operation_fk foreign key (operation_id, business_id)
    references public.sv_operations(id, business_id),
  constraint sv_cutover_events_designation_fk foreign key (designation_id, business_id)
    references public.sv_cutover_designations(id, business_id)
);
create index sv_cutover_events_created_idx on public.sv_cutover_events (created_at desc);
create index sv_cutover_events_txid_idx on public.sv_cutover_events (business_id, asset, authorized_txid);

create or replace function app.sv_cutover_events_guard()
returns trigger language plpgsql security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
begin
  raise exception 'sv_cutover_events is immutable (a cutover is a fact, not a setting)'
    using errcode = 'restrict_violation';
end $$;
revoke all on function app.sv_cutover_events_guard() from public, anon, authenticated;
create trigger sv_cutover_events_guard
  before update or delete on public.sv_cutover_events
  for each row execute function app.sv_cutover_events_guard();

alter table public.sv_cutover_events enable row level security;
create policy sv_cutover_events_owner_read on public.sv_cutover_events
  for select to authenticated using (app.is_salon_owner(business_id));
create policy sv_cutover_events_sa_read on public.sv_cutover_events
  for select to authenticated using (app.is_super_admin());
revoke all on public.sv_cutover_events from public, anon, authenticated;
grant select on public.sv_cutover_events to authenticated;

-- =====================================================================
-- 10. REPLACED (v61 §6): app.sv_authority_guard. 'ready_for_cutover' stays unconditionally
--     rejected with its original message; deletion stays forbidden with its original message.
--     'live' is now reachable, and ONLY through a same-transaction sv_cutover_events row.
-- =====================================================================
create or replace function app.sv_authority_guard()
returns trigger language plpgsql security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
begin
  if tg_op = 'DELETE' then
    raise exception 'sv_authority is not deletable (history survives)' using errcode = 'restrict_violation';
  end if;
  -- 'ready_for_cutover' remains unreachable: readiness is DERIVED evidence (see
  -- app.sv_cutover_readiness), never a stored state, so nothing needs to set it.
  if new.state = 'ready_for_cutover' then
    raise exception 'sv_authority cannot transition to % in PS-2A (cutover is unreachable until a future authorized phase)', new.state
      using errcode = 'restrict_violation';
  end if;
  -- v69 TRIPWIRE: 'live' is reachable only for an UPDATE authorized in THIS transaction by a
  -- public.sv_cutover_events row (written solely by public.sv_cutover_business). A business is
  -- never born live, and ordinary state-setting can still never reach live.
  if new.state = 'live' then
    if tg_op <> 'UPDATE' then
      raise exception 'sv_authority cannot be created live; cutover is an explicit, evidence-gated transition'
        using errcode = 'restrict_violation';
    end if;
    if not exists (
      select 1 from public.sv_cutover_events e
       where e.business_id = new.business_id
         and e.asset = new.asset
         and e.new_state = 'live'
         and e.authorized_txid = pg_catalog.pg_current_xact_id_if_assigned()::text::bigint)
    then
      raise exception 'sv_authority can only reach live through public.sv_cutover_business (v69 cutover tripwire)'
        using errcode = 'restrict_violation';
    end if;
  end if;
  return new;
end $$;
revoke all on function app.sv_authority_guard() from public, anon, authenticated;

-- =====================================================================
-- 10a. ONE LIVE BUSINESS PLATFORM-WIDE (rev-2, review D1; see header §1a). A partial unique index
--      allows at most one live authority row per asset across the whole platform. This is the
--      STRUCTURAL half of the one-pilot-live mandate: two DIFFERENT businesses cutting over
--      concurrently take DIFFERENT per-business advisory locks and therefore do not serialise, so a
--      race could otherwise slip two rows to 'live'; this index makes the second commit fail with
--      23505. The typed, serialised half is app.sv_cutover_readiness -> sv_pilot_already_live (§12).
--      Prod (and the freeze) carry 0 live rows, so it applies cleanly, and the postcondition census
--      proves v69 apply leaves 0 live rows.
create unique index sv_authority_one_live_per_asset_uk
  on public.sv_authority (asset) where state = 'live';

-- =====================================================================
-- 11. public.set_sv_cutover_designation - SUPER ADMIN ONLY. A firm cannot designate itself, so a
--     business owner (however privileged inside their tenant) cannot put themselves live.
-- =====================================================================
create or replace function public.set_sv_cutover_designation(
  p_business uuid, p_designated boolean, p_reason text)
returns jsonb language plpgsql security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_actor uuid := auth.uid();
  v_reason text := btrim(coalesce(p_reason, ''));
  v_existing public.sv_cutover_designations%rowtype;
  v_id uuid;
begin
  if not app.is_super_admin() then
    raise exception 'super admin only: a business cannot designate itself for stored-value cutover'
      using errcode = '42501';
  end if;
  if char_length(v_reason) < 10 then
    raise exception 'a stored-value cutover designation requires a reason of at least 10 characters'
      using errcode = '22023';
  end if;
  if not exists (select 1 from public.businesses b where b.id = p_business) then
    raise exception 'business not found' using errcode = '22023';
  end if;
  if coalesce(p_designated, false) and coalesce(
       (select b.is_synthetic from public.businesses b where b.id = p_business), false) then
    raise exception 'sv_synthetic_business: a synthetic business may never be designated for cutover'
      using errcode = '22023';
  end if;

  perform pg_advisory_xact_lock(hashtextextended('v69:sv_designation', 0));
  select * into v_existing from public.sv_cutover_designations
   where business_id = p_business and asset = 'stored_value' and revoked_at is null
   for update;

  if coalesce(p_designated, false) then
    if found then
      return jsonb_build_object('status', 'ok', 'business_id', p_business, 'designated', true,
        'designation_id', v_existing.id, 'unchanged', true);
    end if;
    -- rev-2, review D2: the designation singleton (sv_cutover_designations_singleton_uk) allows at
    -- most one active designation platform-wide. Rather than let a second concurrent designation hit
    -- a raw 23505, pre-check it under the global advisory lock already held above and raise a typed
    -- error the caller can act on. (This bounds concurrent DESIGNATIONS; the one-live-business
    -- mandate is enforced separately on the authority - see §10a / sv_pilot_already_live.)
    if exists (
      select 1 from public.sv_cutover_designations d
       where d.asset = 'stored_value' and d.revoked_at is null and d.business_id <> p_business)
    then
      raise exception 'sv_pilot_already_designated: another business is already designated for stored-value cutover; revoke it first'
        using errcode = '22023';
    end if;
    insert into public.sv_cutover_designations(business_id, asset, designated_by, reason)
    values (p_business, 'stored_value', v_actor, v_reason)
    returning id into v_id;
    insert into public.audit_log(business_id, actor, action, entity, entity_id, detail)
    values (p_business, v_actor, 'SV_CUTOVER_DESIGNATED', 'sv_cutover_designations', v_id,
      jsonb_build_object('reason', v_reason));
    return jsonb_build_object('status', 'ok', 'business_id', p_business, 'designated', true,
      'designation_id', v_id, 'unchanged', false);
  end if;

  if not found then
    return jsonb_build_object('status', 'ok', 'business_id', p_business, 'designated', false,
      'designation_id', null, 'unchanged', true);
  end if;
  update public.sv_cutover_designations
     set revoked_at = now(), revoked_by = v_actor
   where id = v_existing.id;
  insert into public.audit_log(business_id, actor, action, entity, entity_id, detail)
  values (p_business, v_actor, 'SV_CUTOVER_DESIGNATION_REVOKED', 'sv_cutover_designations',
    v_existing.id, jsonb_build_object('reason', v_reason));
  return jsonb_build_object('status', 'ok', 'business_id', p_business, 'designated', false,
    'designation_id', v_existing.id, 'unchanged', false);
end $$;
revoke all on function public.set_sv_cutover_designation(uuid, boolean, text) from public, anon, authenticated;
grant execute on function public.set_sv_cutover_designation(uuid, boolean, text) to authenticated;

-- =====================================================================
-- 12. app.sv_cutover_readiness - THE single readiness oracle. preview_sv_cutover renders it and
--     sv_cutover_business acts on it, so the two cannot disagree. It authorizes nothing (callers
--     do) and writes nothing.
--     blocking_codes is ORDERED BY PRECEDENCE and runs parallel to blocking_reasons; the RPC
--     raises the error belonging to blocking_codes[0]. ready = (blocking_codes = []).
--     evidence_hash covers exactly the facts the decision was made on, so a cutover attempt that
--     quotes a stale hash is refused instead of acting on evidence that has moved.
-- =====================================================================
create or replace function app.sv_cutover_readiness(p_business uuid)
returns jsonb language plpgsql stable security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_asset text := 'stored_value';
  v_state text;
  v_snapshot public.sv_reconciliation_snapshots%rowtype;
  v_has_run boolean;
  v_rec_status text;
  v_disc int;
  v_paused boolean;
  v_synth boolean;
  v_designation uuid;
  v_pilot_live boolean;
  v_automation jsonb;
  v_reasons jsonb := '[]'::jsonb;
  v_codes jsonb := '[]'::jsonb;
begin
  select coalesce(state, 'unbuilt') into v_state from public.sv_authority
   where business_id = p_business and asset = v_asset;
  v_state := coalesce(v_state, 'unbuilt');   -- fail closed if no authority row

  select * into v_snapshot from public.sv_reconciliation_snapshots
   where business_id = p_business and asset = v_asset
   order by captured_at desc, id desc limit 1;
  v_has_run := found;
  v_rec_status := case when v_has_run then v_snapshot.status else null end;
  v_disc := case when v_has_run then v_snapshot.discrepancy_count else 0 end;

  v_paused := app.sv_pause_active(p_business, v_asset, 'all_only');
  select coalesce(b.is_synthetic, false) into v_synth from public.businesses b where b.id = p_business;
  v_synth := coalesce(v_synth, true);   -- unknown business fails closed
  select d.id into v_designation from public.sv_cutover_designations d
   where d.business_id = p_business and d.asset = v_asset and d.revoked_at is null;
  -- rev-2, review D1: is a DIFFERENT business already live on this asset platform-wide? The pilot is
  -- one business at a time, and 'live' is irreversible, so this must block cutover of anyone else.
  select exists (
    select 1 from public.sv_authority a2
     where a2.asset = v_asset and a2.state = 'live' and a2.business_id <> p_business)
    into v_pilot_live;
  v_pilot_live := coalesce(v_pilot_live, false);
  v_automation := app.sv_automation_status();

  -- PRECEDENCE ORDER. The three PS-2A reason strings that still hold are byte-identical.
  if v_synth then
    v_codes := v_codes || jsonb_build_array('sv_synthetic_business');
    v_reasons := v_reasons || jsonb_build_array(
      'this business is synthetic; a synthetic business may never go live');
  end if;
  if v_state = 'live' then
    v_codes := v_codes || jsonb_build_array('sv_already_live');
    v_reasons := v_reasons || jsonb_build_array(
      'authority is live (this business has already been cut over)');
  end if;
  -- rev-2, review D1: at-most-one-live-per-asset platform-wide. Placed just after this business's own
  -- already-live check: a business that is not itself live but faces an existing platform pilot is
  -- blocked here, so preview and act agree on sv_pilot_already_live via the precedence->raise path.
  if v_pilot_live then
    v_codes := v_codes || jsonb_build_array('sv_pilot_already_live');
    v_reasons := v_reasons || jsonb_build_array(
      'another business is already live on stored value; the pilot is one business at a time platform-wide');
  end if;
  if v_designation is null then
    v_codes := v_codes || jsonb_build_array('sv_not_designated');
    v_reasons := v_reasons || jsonb_build_array(
      'this business has not been designated for stored-value cutover by a super admin');
  end if;
  if v_state <> 'live' and v_state <> 'shadow_testing' then
    v_codes := v_codes || jsonb_build_array('sv_not_ready');
    v_reasons := v_reasons || jsonb_build_array(
      'authority is ' || v_state || ' (it must be shadow_testing to cut over to live)');
  end if;
  if not v_has_run then
    v_codes := v_codes || jsonb_build_array('sv_reconciliation_unclean');
    v_reasons := v_reasons || jsonb_build_array('reconciliation has not been run');
  elsif v_disc > 0 then
    v_codes := v_codes || jsonb_build_array('sv_reconciliation_unclean');
    v_reasons := v_reasons || jsonb_build_array(
      'reconciliation has ' || v_disc || ' open discrepancy(ies); it must be clean');
  elsif coalesce(v_rec_status, '') <> 'clean' then
    v_codes := v_codes || jsonb_build_array('sv_reconciliation_unclean');
    v_reasons := v_reasons || jsonb_build_array(
      'the latest reconciliation snapshot is ' || coalesce(v_rec_status, 'unknown') || '; it must be clean');
  end if;
  if v_paused then
    v_codes := v_codes || jsonb_build_array('sv_paused');
    v_reasons := v_reasons || jsonb_build_array('an all-scope stored-value pause is active');
  end if;
  if (v_automation->>'ok')::boolean is not true then
    v_codes := v_codes || jsonb_build_array('sv_automation_missing');
    v_reasons := v_reasons || jsonb_build_array(
      'stored-value automation is not scheduled and active: '
      || coalesce(nullif(array_to_string(array(
           select jsonb_array_elements_text(v_automation->'missing')), ', '), ''), 'unknown')
      || ' (value that can expire with no scheduled sweep must not go live)');
  end if;

  return jsonb_build_object(
    'business_id', p_business,
    'asset', v_asset,
    'authority_state', v_state,
    'reconciliation_status', v_rec_status,
    'discrepancy_count', v_disc,
    'designation_id', v_designation,
    'is_synthetic', v_synth,
    'pilot_already_live', v_pilot_live,
    'all_scope_pause_active', v_paused,
    'automation', v_automation,
    'blocking_reasons', v_reasons,
    'blocking_codes', v_codes,
    'ready', (jsonb_array_length(v_codes) = 0),
    'evidence_hash', app.ps1b_sha256(jsonb_build_object(
      'business_id', p_business, 'asset', v_asset, 'authority_state', v_state,
      'reconciliation_snapshot_id', case when v_has_run then v_snapshot.id else null end,
      'reconciliation_status', v_rec_status, 'discrepancy_count', v_disc,
      'designation_id', v_designation, 'is_synthetic', v_synth,
      'pilot_already_live', v_pilot_live,
      'all_scope_pause_active', v_paused,
      'automation_scheduled', v_automation->'scheduled',
      'blocking_codes', v_codes)::text));
end $$;
revoke all on function app.sv_cutover_readiness(uuid) from public, anon, authenticated;

-- =====================================================================
-- 13. app.sv_cutover_raise - turns the readiness object into the ONE typed refusal that belongs to
--     its first blocking code. This is the mechanism that makes preview and act agree: there is no
--     second copy of the rules to drift.
-- =====================================================================
create or replace function app.sv_cutover_raise(p_readiness jsonb)
returns void language plpgsql immutable
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare v_code text; v_reason text;
begin
  if (p_readiness->>'ready')::boolean is true then
    return;
  end if;
  v_code := p_readiness->'blocking_codes'->>0;
  v_reason := coalesce(p_readiness->'blocking_reasons'->>0, 'cutover conditions are not met');
  if v_code is null then
    raise exception 'sv_not_ready: cutover conditions are not met' using errcode = '22023';
  end if;
  raise exception '%: %', v_code, v_reason using errcode = '22023';
end $$;
revoke all on function app.sv_cutover_raise(jsonb) from public, anon, authenticated;

-- =====================================================================
-- 14. REPLACED (v64 §7): public.preview_sv_cutover. See header §6 for the exact reason-string
--     deltas. ready is now computed from the same oracle the action uses.
-- =====================================================================
create or replace function public.preview_sv_cutover(p_business uuid)
returns jsonb language plpgsql stable security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare v_readiness jsonb;
begin
  if not app.is_salon_owner(p_business) then
    raise exception 'owner only' using errcode = '42501';
  end if;
  v_readiness := app.sv_cutover_readiness(p_business);
  return jsonb_build_object(
    'business_id', p_business,
    'asset', v_readiness->>'asset',
    'authority_state', v_readiness->>'authority_state',
    'reconciliation_status', v_readiness->>'reconciliation_status',
    'discrepancy_count', (v_readiness->>'discrepancy_count')::int,
    'blocking_reasons', v_readiness->'blocking_reasons',
    'blocking_codes', v_readiness->'blocking_codes',
    'automation', v_readiness->'automation',
    'designated', (v_readiness->>'designation_id') is not null,
    'evidence_hash', v_readiness->>'evidence_hash',
    'reversible', false,
    'ready', (v_readiness->>'ready')::boolean);
end $$;
revoke all on function public.preview_sv_cutover(uuid) from public, anon, authenticated;
grant execute on function public.preview_sv_cutover(uuid) to authenticated;

-- =====================================================================
-- 15. public.sv_cutover_business - THE cutover. One business, no loop, no wildcard.
--     Gate order: owner -> arguments -> advisory locks -> idempotency envelope -> readiness ->
--     evidence freshness -> write. Every refusal happens BEFORE the envelope insert, so a refused
--     attempt writes nothing and reserves no idempotency key.
--     WHY READINESS IS EVALUATED AFTER THE ENVELOPE, unlike v66/v67/v68a. Those gates (authority is
--     live, no pause) are still TRUE after the operation succeeds, so a replay passes them. This
--     gate is inverted: a successful cutover itself makes sv_already_live true. Checking readiness
--     before the replay lookup would therefore make an idempotent retry impossible - the caller who
--     lost the response could never learn the outcome. The advisory locks are taken first either
--     way, so a concurrent second cutover still serialises and still receives sv_already_live.
-- =====================================================================
create or replace function public.sv_cutover_business(
  p_business uuid, p_reason text, p_evidence_hash text, p_idempotency_key uuid)
returns jsonb language plpgsql security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_actor uuid := auth.uid();
  v_reason text := btrim(coalesce(p_reason, ''));
  v_evidence text := btrim(coalesce(p_evidence_hash, ''));
  v_readiness jsonb;
  v_hash text;
  v_existing public.sv_operations%rowtype;
  v_op uuid := gen_random_uuid();
  v_prior text;
  v_designation public.sv_cutover_designations%rowtype;
  v_result jsonb;
begin
  if not app.is_salon_owner(p_business) then
    raise exception 'owner only' using errcode = '42501';
  end if;
  if p_idempotency_key is null then
    raise exception 'a stored-value cutover idempotency key is required' using errcode = '22023';
  end if;
  if char_length(v_reason) < 10 then
    raise exception 'a stored-value cutover requires a reason of at least 10 characters (this is a financial go-live, not a toggle)'
      using errcode = '22023';
  end if;
  if v_evidence = '' then
    raise exception 'sv_evidence_required: the evidence hash returned by preview_sv_cutover is required'
      using errcode = '22023';
  end if;

  -- Per-business lock first (two different keys racing the same business serialize here), then the
  -- per-key lock (the envelope). Deterministic order -> no deadlock between the two.
  perform pg_advisory_xact_lock(hashtextextended('v69:sv_cutover:' || p_business::text, 0));
  perform pg_advisory_xact_lock(hashtextextended(
    'v69:sv_cutover_key:' || p_business::text || ':' || p_idempotency_key::text, 0));

  v_hash := app.ps1b_sha256(jsonb_build_object(
    'op', 'cutover', 'business_id', p_business, 'reason', v_reason)::text);
  select * into v_existing from public.sv_operations o
   where o.business_id = p_business and o.operation_type = 'cutover'
     and o.idempotency_key = p_idempotency_key
   for update;
  if found then
    if v_existing.request_hash <> v_hash then
      raise exception 'idempotency key conflicts with a different stored-value cutover' using errcode = '22023';
    end if;
    return v_existing.result;   -- same key, same request -> ONE transition, replayed result
  end if;

  -- Readiness, evaluated under the locks on the SAME oracle preview_sv_cutover renders. Being under
  -- the locks makes it a TOCTOU-safe check as well: a cutover, pause, designation revocation or
  -- reconciliation committed by another session cannot slip a transition through.
  v_readiness := app.sv_cutover_readiness(p_business);
  perform app.sv_cutover_raise(v_readiness);
  if (v_readiness->>'evidence_hash') <> v_evidence then
    raise exception 'sv_evidence_stale: the cutover conditions changed since preview_sv_cutover was taken; re-run the preview and act on the new evidence'
      using errcode = '22023';
  end if;

  select state into v_prior from public.sv_authority
   where business_id = p_business and asset = 'stored_value' for update;
  select * into v_designation from public.sv_cutover_designations
   where business_id = p_business and asset = 'stored_value' and revoked_at is null;

  v_result := jsonb_build_object(
    'status', 'ok',
    'business_id', p_business,
    'asset', 'stored_value',
    'operation_id', v_op,
    'prior_state', v_prior,
    'new_state', 'live',
    'reason', v_reason,
    'evidence_hash', v_readiness->>'evidence_hash',
    'designation_id', v_designation.id,
    'designated_by', v_designation.designated_by,
    'readiness', v_readiness,
    'reversible', false,
    'emergency_control', 'sv_pause');

  insert into public.sv_operations(id, business_id, operation_type, idempotency_key, request_hash, actor, result)
  values (v_op, p_business, 'cutover', p_idempotency_key, v_hash, v_actor, v_result);

  -- The event row is written BEFORE the authority update: it is what authorizes the update.
  insert into public.sv_cutover_events(
    business_id, asset, operation_id, actor, designation_id, designated_by,
    prior_state, new_state, reason, evidence_hash, readiness, authorized_txid)
  values (
    p_business, 'stored_value', v_op, v_actor, v_designation.id, v_designation.designated_by,
    v_prior, 'live', v_reason, v_readiness->>'evidence_hash', v_readiness,
    pg_catalog.pg_current_xact_id()::text::bigint);

  update public.sv_authority
     set state = 'live', updated_at = now(), updated_by = v_actor
   where business_id = p_business and asset = 'stored_value';

  insert into public.audit_log(business_id, actor, action, entity, entity_id, detail)
  values (p_business, v_actor, 'SV_CUTOVER', 'sv_authority', p_business, jsonb_build_object(
    'operation_id', v_op, 'from', v_prior, 'to', 'live', 'reason', v_reason,
    'evidence_hash', v_readiness->>'evidence_hash',
    'designation_id', v_designation.id, 'designated_by', v_designation.designated_by,
    'reversible', false));

  return v_result;
end $$;
revoke all on function public.sv_cutover_business(uuid, text, text, uuid) from public, anon, authenticated;
grant execute on function public.sv_cutover_business(uuid, text, text, uuid) to authenticated;

-- =====================================================================
-- 16. REPLACED (v62 §4): app.sv_apply_authority_state - 'live' is terminal on this path.
-- =====================================================================
create or replace function app.sv_apply_authority_state(
  p_business uuid, p_asset text, p_state text, p_reason text, p_actor uuid)
returns text language plpgsql security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_asset text := coalesce(p_asset, 'stored_value');
  v_reason text := btrim(coalesce(p_reason, ''));
  v_current text;
begin
  if p_state is null or p_state not in ('unbuilt', 'shadow_testing', 'reconciliation_blocked') then
    raise exception 'stored-value authority state % is not settable in PS-2A (cutover states are unreachable)', p_state
      using errcode = '22023';
  end if;
  if char_length(v_reason) < 3 then
    raise exception 'a stored-value authority transition requires a reason of at least 3 characters' using errcode = '22023';
  end if;

  select state into v_current from public.sv_authority
   where business_id = p_business and asset = v_asset
   for update;
  if v_current is null then
    raise exception 'stored-value authority is not initialised for this business' using errcode = '22023';
  end if;

  -- Idempotent no-op: same state -> no write, no audit.
  if v_current = p_state then
    return v_current;
  end if;

  -- v69 §5 (ADDED): 'live' is TERMINAL on this path. Cutover is deliberately NOT reversible by
  -- RPC; the emergency control is public.sv_pause, which keeps working on a live business. This
  -- is also what stops the newly-scheduled daily reconciliation from silently driving a LIVE
  -- tenant to 'reconciliation_blocked' and stranding issued customer value.
  if v_current = 'live' then
    raise exception 'sv_live_not_reversible: stored value is live for this business and cannot be moved out of live (pause is the emergency control)'
      using errcode = '22023';
  end if;

  -- Blocked-lock (contract §1): a business with open discrepancies cannot leave
  -- 'reconciliation_blocked' except back to 'shadow_testing' (never forward). Forward states
  -- do not exist in PS-2A, so this concretely forbids blocked -> unbuilt.
  if v_current = 'reconciliation_blocked' and p_state <> 'shadow_testing' then
    raise exception 'stored-value authority is reconciliation_blocked; it may only return to shadow_testing' using errcode = '22023';
  end if;

  update public.sv_authority
     set state = p_state, updated_at = now(), updated_by = p_actor
   where business_id = p_business and asset = v_asset;

  insert into public.audit_log(business_id, actor, action, entity, entity_id, detail)
  values (p_business, p_actor, 'SV_AUTHORITY_STATE_SET', 'sv_authority', p_business, jsonb_build_object(
    'asset', v_asset, 'from', v_current, 'to', p_state, 'reason', v_reason));

  return p_state;
end $$;

-- =====================================================================
-- 17. REPLACED (v62 §7): public.run_sv_reconciliation - scheduled-automation caller accepted; a
--     LIVE tenant is never downgraded by a run.
-- =====================================================================
create or replace function public.run_sv_reconciliation(p_business uuid)
returns jsonb language plpgsql security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_actor uuid := auth.uid();
  v_asset text := 'stored_value';
  v_run uuid := gen_random_uuid();
  v_snapshot uuid := gen_random_uuid();
  v_authority text;
  gc record;
  v_legacy_ref text;
  v_studio integer;
  v_legacy_total bigint := 0;
  v_studio_total bigint := 0;
  v_disc integer;
  v_status text;
  v_category text;
  v_dup boolean;
  v_discrepancies jsonb := '[]'::jsonb;
begin
  if not (app.is_salon_owner(p_business) or app.sv_automation_context()) then
    raise exception 'owner only' using errcode = '42501';
  end if;
  select state into v_authority from public.sv_authority
   where business_id = p_business and asset = v_asset;
  if v_authority is null then
    raise exception 'stored-value authority is not initialised for this business' using errcode = '22023';
  end if;

  -- Direction 1: legacy (gift_cards, READ-ONLY) -> studio projection. No migration linkage
  -- exists in PS-2A, so the studio value attributable to any legacy gift card is 0.
  for gc in
    select id, code, balance_cents, status, purchaser_client_id
      from public.gift_cards
     where business_id = p_business
     order by id
  loop
    v_legacy_ref := 'legacy:giftcard:' || gc.id::text;
    v_studio := 0;
    v_legacy_total := v_legacy_total + coalesce(gc.balance_cents, 0);
    v_studio_total := v_studio_total + v_studio;

    -- Shadow evaluation: the would-be mint projection of this legacy balance into the studio
    -- ledger. Writing it moves NO value (append-only shadow log only).
    perform app.sv_write_shadow_evaluation(
      p_business, null, v_asset, 'topup',
      jsonb_build_array(jsonb_build_object('class', 'paid', 'kind', 'issue', 'cents', coalesce(gc.balance_cents, 0))),
      coalesce(gc.balance_cents, 0), v_legacy_ref, 'reconcile_projection');

    select count(*) > 1 into v_dup from public.gift_cards g
     where g.business_id = p_business and g.code = gc.code;

    v_category := null;
    if gc.balance_cents is null or gc.balance_cents < 0 then
      v_category := 'invalid_legacy_balance';
    elsif v_dup then
      v_category := 'duplicate_legacy_event';
    elsif gc.status in ('void', 'redeemed') and gc.balance_cents > 0 then
      v_category := 'orphan_legacy_record';
    elsif gc.balance_cents > 0 and v_studio = 0 then
      v_category := 'missing_in_studio';
    elsif gc.balance_cents <> v_studio then
      v_category := 'amount_mismatch';
    else
      v_category := null;   -- balance 0 (or exact match) -> clean, no discrepancy row
    end if;

    if v_category is not null then
      v_discrepancies := v_discrepancies || jsonb_build_object(
        'category', v_category,
        'legacy_ref', v_legacy_ref,
        'client_id', gc.purchaser_client_id,
        'legacy_cents', gc.balance_cents,
        'studio_cents', v_studio,
        'delta_cents', case when gc.balance_cents is null then null else gc.balance_cents - v_studio end,
        'detail', jsonb_build_object('code', gc.code, 'status', gc.status, 'source', 'gift_cards'));
    end if;
  end loop;

  -- Direction 2: a studio record claiming a legacy gift-card origin (a prior shadow
  -- evaluation's legacy_ref) whose gift card has vanished -> missing_in_legacy. Empty on a
  -- fresh tenant (every current card exists); DISTINCT so each vanished ref is one row.
  for v_legacy_ref in
    select distinct se.legacy_ref
      from public.sv_shadow_evaluations se
     where se.business_id = p_business
       and se.legacy_ref like 'legacy:giftcard:%'
       and not exists (
         select 1 from public.gift_cards g
          where g.business_id = p_business
            and 'legacy:giftcard:' || g.id::text = se.legacy_ref)
     order by se.legacy_ref
  loop
    v_discrepancies := v_discrepancies || jsonb_build_object(
      'category', 'missing_in_legacy',
      'legacy_ref', v_legacy_ref,
      'client_id', null,
      'legacy_cents', null,
      'studio_cents', 0,
      'delta_cents', null,
      'detail', jsonb_build_object('source', 'studio_shadow_origin'));
  end loop;

  v_disc := jsonb_array_length(v_discrepancies);
  v_status := case when v_disc = 0 then 'clean' else 'blocked' end;

  -- Snapshot FIRST (the discrepancy rows carry a composite FK to it).
  insert into public.sv_reconciliation_snapshots(
    id, business_id, run_id, asset, source, actor,
    legacy_total_cents, studio_total_cents, discrepancy_count, status)
  values (v_snapshot, p_business, v_run, v_asset, 'gift_cards', v_actor,
    v_legacy_total, v_studio_total, v_disc, v_status);

  insert into public.sv_reconciliation_discrepancies(
    business_id, run_id, snapshot_id, category, legacy_ref, client_id,
    legacy_cents, studio_cents, delta_cents, detail)
  select p_business, v_run, v_snapshot,
    d->>'category', d->>'legacy_ref', nullif(d->>'client_id', '')::uuid,
    (d->>'legacy_cents')::integer, (d->>'studio_cents')::integer, (d->>'delta_cents')::integer,
    coalesce(d->'detail', '{}'::jsonb)
  from jsonb_array_elements(v_discrepancies) d;

  -- Any open discrepancy blocks cutover (drives 'reconciliation_blocked' via the INTERNAL
  -- state path). NEVER auto-corrects, NEVER writes a legacy row.
  -- v69 (ADDED PREDICATE): a LIVE tenant is NEVER downgraded by this run. The discrepancy is
  -- still captured in the snapshot, the discrepancy rows and the audit entry; the owner control
  -- is sv_pause (§5). The state is re-read here rather than reusing the entry-time value so a
  -- cutover committed mid-run cannot be undone by a stale read.
  if v_disc > 0 and coalesce((select state from public.sv_authority
                               where business_id = p_business and asset = v_asset), '') <> 'live' then
    perform app.sv_apply_authority_state(
      p_business, v_asset, 'reconciliation_blocked', 'open stored-value reconciliation discrepancies', v_actor);
  end if;

  insert into public.audit_log(business_id, actor, action, entity, entity_id, detail)
  values (p_business, v_actor, 'SV_RECONCILIATION_RUN', 'sv_reconciliation_snapshots', v_snapshot, jsonb_build_object(
    'run_id', v_run, 'status', v_status, 'discrepancy_count', v_disc,
    'legacy_total_cents', v_legacy_total, 'studio_total_cents', v_studio_total));

  return jsonb_build_object(
    'status', 'ok',
    'run_id', v_run,
    'snapshot_id', v_snapshot,
    'source', 'gift_cards',
    'reconciliation_status', v_status,
    'discrepancy_count', v_disc,
    'legacy_total_cents', v_legacy_total,
    'studio_total_cents', v_studio_total,
    'authority_state', (select state from public.sv_authority where business_id = p_business and asset = v_asset));
end $$;
revoke all on function public.run_sv_reconciliation(uuid) from public, anon, authenticated;
grant execute on function public.run_sv_reconciliation(uuid) to authenticated;

-- =====================================================================
-- 18. REPLACED (v64 §5g): public.sv_expire_due - scheduled-automation caller accepted.
-- =====================================================================
create or replace function public.sv_expire_due(p_business uuid, p_limit integer default 1000)
returns jsonb language plpgsql security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_actor uuid := auth.uid();
  v_op uuid := gen_random_uuid();
  v_limit integer := least(greatest(coalesce(p_limit, 1000), 1), 100000);
  v_acc uuid;
  l record;
  v_rem integer;
  v_expired_lots integer := 0;
  v_expired_cents bigint := 0;
  v_details jsonb := '[]'::jsonb;
begin
  if not (app.is_salon_owner(p_business) or app.sv_automation_context()) then
    raise exception 'owner only' using errcode = '42501';
  end if;
  if coalesce((select state from public.sv_authority
                where business_id = p_business and asset = 'stored_value'), 'unbuilt') <> 'live' then
    raise exception 'sv_not_live: stored value is not the authority for this business' using errcode = '22023';
  end if;

  -- PS-2A Increment D pause gate (contract D §1: expiry is a system sweep, not an earn or a
  -- redeem, so ONLY an 'all' sv_pause blocks it). Second gate, independent of sv_not_live;
  -- this block is the ONLY addition over the v63 body.
  if app.sv_pause_active(p_business, 'stored_value', 'all_only') then
    raise exception 'sv_paused: stored value is paused' using errcode = '22023';
  end if;

  -- Serialize per touched account (ascending order -> deadlock-free vs per-account spend locks).
  for v_acc in
    select distinct l2.account_id from public.sv_lots l2
     where l2.business_id = p_business and l2.expiry_key is not null and l2.expiry_key <= now()
     order by l2.account_id
  loop
    perform pg_advisory_xact_lock(hashtextextended('v63:sv_acct:' || p_business::text || ':' || v_acc::text, 0));
  end loop;

  -- Compute the sweep plan under FOR UPDATE row locks (sv_operations is append-only, so the anchor
  -- op is inserted ONCE with its final result). Locking the candidate lots holds them for the txn.
  for l in
    select ll.id as lot_id, ll.account_id
      from public.sv_lots ll
     where ll.business_id = p_business and ll.expiry_key is not null and ll.expiry_key <= now()
     order by ll.account_id, ll.expiry_key asc, ll.earned_seq asc, ll.id asc
     for update
  loop
    exit when v_expired_lots >= v_limit;
    v_rem := app.sv_lot_remaining(l.lot_id);
    if v_rem is null or v_rem <= 0 then continue; end if;   -- spent / already-expired -> skip
    v_expired_lots := v_expired_lots + 1;
    v_expired_cents := v_expired_cents + v_rem;
    v_details := v_details || jsonb_build_array(jsonb_build_object(
      'lot_id', l.lot_id, 'account_id', l.account_id, 'expired_cents', v_rem));
  end loop;

  insert into public.sv_operations(id, business_id, operation_type, idempotency_key, request_hash, actor, result)
  values (v_op, p_business, 'expire', gen_random_uuid(),
    app.ps1b_sha256(jsonb_build_object('op', 'expire', 'business_id', p_business, 'at', now())::text),
    v_actor, jsonb_build_object('status', 'ok', 'expired_lots', v_expired_lots,
      'expired_cents', v_expired_cents::int, 'details', v_details));

  for l in select value from jsonb_array_elements(v_details) as t(value) loop
    insert into public.sv_lot_movements(business_id, account_id, lot_id, operation_id, kind, cents)
    values (p_business, (l.value->>'account_id')::uuid, (l.value->>'lot_id')::uuid, v_op, 'expiry',
      (-(l.value->>'expired_cents')::int)::int);
  end loop;

  if v_expired_lots > 0 then
    insert into public.audit_log(business_id, actor, action, entity, entity_id, detail)
    values (p_business, v_actor, 'SV_EXPIRE_SWEEP', 'sv_accounts', v_op, jsonb_build_object(
      'operation_id', v_op, 'expired_lots', v_expired_lots, 'expired_cents', v_expired_cents::int));
  end if;

  return jsonb_build_object('status', 'ok', 'operation_id', v_op,
    'expired_lots', v_expired_lots, 'expired_cents', v_expired_cents::int, 'details', v_details);
end $$;
revoke all on function public.sv_expire_due(uuid, integer) from public, anon, authenticated;
grant execute on function public.sv_expire_due(uuid, integer) to authenticated;

-- =====================================================================
-- 19. REPLACED (v67 §9): public.sv_release_expired_checkout_tenders - same.
-- =====================================================================
create or replace function public.sv_release_expired_checkout_tenders(p_business uuid, p_limit integer default 1000)
returns jsonb language plpgsql security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_actor uuid := auth.uid();
  v_limit integer := least(greatest(coalesce(p_limit, 1000), 1), 100000);
  t record;
  v_released integer := 0;
begin
  if not (app.is_salon_owner(p_business) or app.is_super_admin() or app.sv_automation_context()) then
    raise exception 'owner only' using errcode = '42501';
  end if;
  for t in
    select ct.id, ct.reservation_id
      from public.checkout_sv_tenders ct
      join public.checkout_evaluations ce on ce.id = ct.evaluation_id and ce.business_id = ct.business_id
     where ct.business_id = p_business and ct.status = 'reserved'
       and (ce.expires_at <= now() or ce.consumed_at is not null)
     order by ct.created_at
     for update of ct
  loop
    exit when v_released >= v_limit;
    perform app.sv_release_core(p_business, t.reservation_id, gen_random_uuid());
    update public.checkout_sv_tenders
       set status = 'released', released_reason = 'expired_sweep', updated_at = now()
     where id = t.id;
    v_released := v_released + 1;
  end loop;
  if v_released > 0 then
    insert into public.audit_log(business_id, actor, action, entity, entity_id, detail)
    values (p_business, v_actor, 'SV_CHECKOUT_TENDER_SWEEP', 'checkout_sv_tenders', p_business,
      jsonb_build_object('released', v_released));
  end if;
  return jsonb_build_object('status', 'ok', 'business_id', p_business, 'released', v_released);
end $$;
revoke all on function public.sv_release_expired_checkout_tenders(uuid, integer) from public, anon, authenticated;
grant execute on function public.sv_release_expired_checkout_tenders(uuid, integer) to authenticated;

-- =====================================================================
-- 20. REPLACED (v64 §6): public.get_sv_authority_overview - can_cutover is computed.
-- =====================================================================
create or replace function public.get_sv_authority_overview(p_business uuid)
returns jsonb language plpgsql stable security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_asset text := 'stored_value';
  v_state text;
  v_snapshot public.sv_reconciliation_snapshots%rowtype;
  v_has_run boolean;
  v_pauses jsonb;
begin
  if not (app.is_salon_owner(p_business) or app.is_super_admin()) then
    raise exception 'not permitted to view stored-value authority for this business' using errcode = '42501';
  end if;

  select coalesce(state, 'unbuilt') into v_state from public.sv_authority
   where business_id = p_business and asset = v_asset;
  v_state := coalesce(v_state, 'unbuilt');   -- fail closed if no authority row

  select * into v_snapshot from public.sv_reconciliation_snapshots
   where business_id = p_business and asset = v_asset
   order by captured_at desc, id desc limit 1;
  v_has_run := found;

  select coalesce(jsonb_agg(jsonb_build_object(
      'scope', p.scope, 'reason', p.reason, 'actor', p.actor, 'paused_at', p.paused_at)
      order by p.scope, p.paused_at desc), '[]'::jsonb)
    into v_pauses
    from public.sv_pauses p
   where p.business_id = p_business and p.asset = v_asset and p.lifted_at is null;

  return jsonb_build_object(
    'business_id', p_business,
    'asset', v_asset,
    'authority_state', v_state,
    'spendable', (v_state = 'live'),
    'shadow_testing', (v_state = 'shadow_testing'),
    'reconciliation', jsonb_build_object(
      'has_run', v_has_run,
      'status', case when v_has_run then v_snapshot.status else null end,
      'discrepancy_count', case when v_has_run then v_snapshot.discrepancy_count else 0 end),
    'active_pauses', v_pauses,
    'can_cutover', coalesce((app.sv_cutover_readiness(p_business) ->> 'ready')::boolean, false));
end $$;
revoke all on function public.get_sv_authority_overview(uuid) from public, anon, authenticated;
grant execute on function public.get_sv_authority_overview(uuid) to authenticated;

-- =====================================================================
-- 21. LOW-1 (header §7): 40P01 is an ACCEPTED, RETRIABLE outcome of a door-A vs door-B settlement
--     reversal race. Recorded as catalog metadata so it is testable, not just prose.
-- =====================================================================
comment on function public.sv_reverse_spend(uuid, uuid, uuid) is
  'Stored-value spend reversal (door A). CONCURRENCY CONTRACT (v69, LOW-1): racing door B '
  '(public.reverse_sale -> the sale core settlement reversal) may resolve through Postgres deadlock '
  'detection - the loser receives SQLSTATE 40P01. That is an ACCEPTED, RETRIABLE outcome, not a '
  'defect: it is fail-closed (the loser wrote nothing), money invariants hold, exactly one '
  'restitution occurs, and a retry succeeds. Callers must retry 40P01 rather than surface it.';
comment on function public.reverse_sale(uuid, uuid, text, text, text, text) is
  'Sale reversal (door B). CONCURRENCY CONTRACT (v69, LOW-1): racing door A '
  '(public.sv_reverse_spend) may resolve through Postgres deadlock detection - the loser receives '
  'SQLSTATE 40P01. That is an ACCEPTED, RETRIABLE outcome, not a defect: it is fail-closed, money '
  'invariants hold, exactly one restitution occurs, and a retry succeeds. Callers must retry 40P01 '
  'rather than surface it.';

-- =====================================================================
-- 22. POSTCONDITIONS. The load-bearing one is the census: applying v69 cut NOBODY over.
-- =====================================================================
do $v69_postconditions$
declare
  v_before integer;
  v_after integer;
  v_drift integer;
  v_live integer;
  v_automation jsonb;
  v_def text;
begin
  -- (1) APPLYING v69 CUT OVER NOBODY. Row-for-row comparison of the before/after census.
  select count(*) into v_before from v69_authority_census_before;
  select count(*) into v_after from public.sv_authority;
  if v_before <> v_after then
    raise exception 'v69: the sv_authority row count changed during apply (% -> %)', v_before, v_after;
  end if;
  select count(*) into v_drift
    from public.sv_authority a
    full join v69_authority_census_before b
      on b.business_id = a.business_id and b.asset = a.asset
   where a.business_id is null or b.business_id is null or a.state is distinct from b.state;
  if v_drift <> 0 then
    raise exception 'v69: % sv_authority row(s) changed state during apply - applying v69 must cut over NOBODY', v_drift;
  end if;
  select count(*) into v_live from public.sv_authority where state = 'live';
  if v_live <> 0 then
    raise exception 'v69: % business(es) are live after apply; v69 must activate nobody', v_live;
  end if;
  if exists (select 1 from public.sv_cutover_events) then
    raise exception 'v69: a cutover event exists after apply';
  end if;
  if exists (select 1 from public.sv_cutover_designations) then
    raise exception 'v69: a cutover designation exists after apply';
  end if;

  -- (2) The tripwire is intact: the guard trigger still exists and still rejects ready_for_cutover.
  if not exists (
    select 1 from pg_trigger t
     where t.tgrelid = 'public.sv_authority'::regclass and t.tgname = 'sv_authority_guard'
       and not t.tgisinternal and t.tgenabled = 'O') then
    raise exception 'v69: the sv_authority guard trigger is missing or disabled';
  end if;
  v_def := pg_get_functiondef('app.sv_authority_guard()'::regprocedure);
  if position('ready_for_cutover' in v_def) = 0 or position('sv_cutover_business' in v_def) = 0 then
    raise exception 'v69: the sv_authority guard lost its ready_for_cutover refusal or its cutover tripwire';
  end if;

  -- (3) Ordinary state-setting still cannot name live.
  v_def := pg_get_functiondef('public.set_sv_authority_state(uuid,text,text,text)'::regprocedure);
  if position('''unbuilt'', ''shadow_testing'', ''reconciliation_blocked''' in v_def) = 0 then
    raise exception 'v69: set_sv_authority_state no longer restricts itself to the safe state subset';
  end if;

  -- (4) preview_sv_cutover no longer hardcodes ready.
  v_def := pg_get_functiondef('public.preview_sv_cutover(uuid)'::regprocedure);
  if position('sv_cutover_readiness' in v_def) = 0 then
    raise exception 'v69: preview_sv_cutover does not consult the readiness oracle';
  end if;

  -- (5) Exactly ONE function in the whole catalog can write sv_cutover_events.
  if (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
       where p.prosrc like '%insert into public.sv_cutover_events%') <> 1 then
    raise exception 'v69: sv_cutover_events has more than one writer';
  end if;

  -- (6) Automation: when cron.job exists at all, all three jobs must be scheduled and active.
  v_automation := app.sv_automation_status();
  if to_regclass('cron.job') is not null and (v_automation->>'ok')::boolean is not true then
    raise exception 'v69: stored-value automation was not scheduled: %', v_automation::text;
  end if;
  raise notice 'v69 automation status: %', v_automation::text;

  -- (7) Browser ACLs on the two new tables.
  if has_table_privilege('anon', 'public.sv_cutover_events', 'select')
     or has_table_privilege('authenticated', 'public.sv_cutover_events', 'insert')
     or has_table_privilege('authenticated', 'public.sv_cutover_designations', 'insert')
     or has_table_privilege('authenticated', 'public.sv_automation_runs', 'insert') then
    raise exception 'v69: a new stored-value table has a browser write privilege';
  end if;
  if has_function_privilege('anon', 'public.sv_cutover_business(uuid,text,text,uuid)', 'execute')
     or has_function_privilege('anon', 'public.set_sv_cutover_designation(uuid,boolean,text)', 'execute')
     or has_function_privilege('authenticated', 'app.sv_automation_begin(text)', 'execute')
     or has_function_privilege('authenticated', 'app.sv_cutover_readiness(uuid)', 'execute') then
    raise exception 'v69: a v69 function has the wrong browser-role ACL';
  end if;

  -- (8) rev-2, review D1/D2: the one-live-per-asset structural bound exists as a PARTIAL UNIQUE
  --     index; the readiness oracle emits sv_pilot_already_live; the designation RPC raises the typed
  --     sv_pilot_already_designated. (Applying v69 still leaves 0 live rows, proven at (1) above, so
  --     the index applies cleanly.)
  if not exists (
    select 1 from pg_index i join pg_class c on c.oid = i.indexrelid
     where i.indrelid = 'public.sv_authority'::regclass
       and c.relname = 'sv_authority_one_live_per_asset_uk'
       and i.indisunique and i.indpred is not null) then
    raise exception 'v69: the one-live-per-asset partial unique index is missing';
  end if;
  v_def := pg_get_functiondef('app.sv_cutover_readiness(uuid)'::regprocedure);
  if position('sv_pilot_already_live' in v_def) = 0 then
    raise exception 'v69: the readiness oracle no longer emits sv_pilot_already_live';
  end if;
  v_def := pg_get_functiondef('public.set_sv_cutover_designation(uuid,boolean,text)'::regprocedure);
  if position('sv_pilot_already_designated' in v_def) = 0 then
    raise exception 'v69: set_sv_cutover_designation no longer raises the typed designation collision';
  end if;
end
$v69_postconditions$;

commit;
