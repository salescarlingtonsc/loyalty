-- Rollback-only v69 CONTROLLED-CUTOVER suite. Run after the complete canonical chain through v69
-- in a disposable rehearsal database.
--
-- Contract: docs/design/ps2/PS2_LIVE_V69_CUTOVER_CONTRACT.md §7.
-- Oracle for every cents figure in PART 5: docs/design/ps0/STORED_VALUE_CONTRACT.md §9 (the frozen
-- vectors and the lettered cases) + §10 (invariants). Nothing is re-derived here.
--
-- WHAT MAKES THIS SUITE DIFFERENT FROM v63/v64/v67/v68a/v68b. Those suites reach authority='live'
-- with a SHIM: they transiently disable the sv_authority guard trigger and force the row. This one
-- does not, and must not: it cuts the business over through public.sv_cutover_business, the real
-- evidence-gated path, and then runs the PS-0 lettered-case oracle on that genuinely live tenant.
-- That is the first time the stored-value arithmetic is exercised outside a forced-live shim.
--
-- WHAT IT PROVES
--   PART 0  static catalog truth on the APPLIED chain: the three stored-value cron jobs exist and
--           are active; every v69 function is definer + pinned + correctly revoked; the three new
--           tables have RLS and zero browser DML; the NEVER-GLOBAL tripwire (exactly one writer of
--           sv_cutover_events, exactly two functions that update sv_authority, neither containing a
--           loop, the cutover update keyed by p_business); set_sv_authority_state still cannot name
--           'live'; preview_sv_cutover no longer hardcodes ready.
--   PART 1  the reachability tripwire: a direct UPDATE to 'live' without a same-transaction cutover
--           event is refused; an INSERT at 'live' is refused; 'ready_for_cutover' is still refused
--           with its original message; sv_authority is still undeletable and browser-unwritable.
--   PART 2  the full refusal matrix with PREVIEW<->ACT AGREEMENT: for every blocked configuration
--           the preview's first blocking code IS the typed error the RPC raises, nothing is
--           mutated, and no idempotency key is reserved; plus (rev-3, review MEDIUM-1) a designation
--           REVOKED between the readiness read and the permanent attribution read makes the cutover
--           refuse with the typed sv_designation_revoked instead of recording a NULL authorizer in an
--           immutable sv_cutover_events row - and the refusal stays retriable with the same key.
--   PART 3  the cutover itself: preview ready => cutover succeeds; idempotent replay; changed-request
--           conflict; a second cutover is refused; live is not reversible; the singleton designation.
--   PART 4  live behaviour: mint, spend, tender reserve/finalise, chargeback, settlement reversal,
--           expiry sweep, pause+lift on a live business; the v66 mint tripwire; and the three
--           scheduled drivers actually working - including the defect this migration closes, that a
--           scheduled reconciliation must NEVER downgrade a live tenant out of 'live'.
--   PART 5  the PS-0 lettered-case oracle, cents-exact, on the genuinely live business:
--           (a) ten $1 refunds to closure, (c) same-key whole refunds, (d) lost-response retry,
--           (e) chargeback + bad debt, (f) expired bonus then reversal, (g) two-op FEFO refunds,
--           (g-spill) cross-op spill, (h) inverted expiry order.
--           (b) is a two-connection race and lives in db/tests/v69_cutover_concurrency.sh.
--
-- CRON IS NOT ROLLBACK-SAFE IN THE SAME WAY. cron.schedule() is asserted from the APPLIED chain
-- (PART 0 reads cron.job before anything is mutated), never by scheduling inside this transaction.
-- The two automation-missing refusals DO mutate cron.job (a plain table in both real pg_cron and
-- the local rehearsal stub), and the outer ROLLBACK discards those mutations; the deleted row is
-- also explicitly re-inserted so the assertion cannot leak even if the transaction were committed
-- by accident. The rehearsal stub's cron.job has no `active` column, so the inactive-job case adds
-- one inside the transaction (DDL is transactional) and app.sv_automation_status() introspects for
-- it rather than assuming - which is also exactly how it behaves against real pg_cron.
--
-- The including transaction owns BEGIN/ROLLBACK; nothing commits.
begin;
\ir fixtures/pristine_chain_fixture.psql

create or replace function pg_temp.as_v69(p_uid uuid, p_role text) returns void language plpgsql as $$
begin
  execute 'reset role';
  perform set_config('request.jwt.claim.sub', '', true);
  perform set_config('request.jwt.claims', '', true);
  if p_role = 'anon' then
    execute 'set local role anon';
    perform set_config('request.jwt.claims', json_build_object('role', 'anon')::text, true);
  elsif p_role = 'postgres' then
    return;
  else
    execute 'set local role authenticated';
    perform set_config('request.jwt.claim.sub', p_uid::text, true);
    perform set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated')::text, true);
  end if;
end $$;
grant execute on function pg_temp.as_v69(uuid, text) to authenticated, anon;

-- publish one plan, each on its own sv_plans row (the v68a helper shape)
create or replace function pg_temp.v69_plan(p_business uuid, p_cfg jsonb) returns uuid language plpgsql as $$
declare d uuid;
begin
  d := (public.create_sv_plan_draft(p_business, p_cfg, gen_random_uuid())->>'draft_id')::uuid;
  return (public.publish_sv_plan_version(p_business, d, 0, gen_random_uuid(), null)->>'version_id')::uuid;
end $$;
grant execute on function pg_temp.v69_plan(uuid, jsonb) to authenticated;

-- Seed lots with EXPLICIT expiry keys - the mint path can only set FUTURE expiry, and PS-0 cases
-- (f) and (h) need a past-expiry lot and an inverted bonus/paid expiry ordering respectively.
-- A funding-payment evidence row is written too (same rationale as fixtures/sv_mint_reinstate.psql)
-- so the v68a cash-refund cap bounds case (h) by real collected cash instead of refusing it.
create or replace function pg_temp.v69_seed(
  p_business uuid, p_client uuid, p_paid int, p_paid_expiry timestamptz, p_bonus int, p_bonus_expiry timestamptz)
returns jsonb language plpgsql as $$
declare
  v_account uuid := app.sv_ensure_account(p_business, p_client);
  v_op uuid := gen_random_uuid();
  v_paid_lot uuid := gen_random_uuid();
  v_bonus_lot uuid;
begin
  insert into public.sv_operations(id, business_id, operation_type, idempotency_key, request_hash)
  values (v_op, p_business, 'topup', gen_random_uuid(), md5(gen_random_uuid()::text) || md5(gen_random_uuid()::text));
  insert into public.sv_lots(id, business_id, account_id, operation_id, class, minted_cents, expiry_key, earned_seq)
  values (v_paid_lot, p_business, v_account, v_op, 'paid', p_paid, p_paid_expiry, nextval('app.sv_earned_seq'));
  insert into public.sv_lot_movements(business_id, account_id, lot_id, operation_id, kind, cents)
  values (p_business, v_account, v_paid_lot, v_op, 'issue', p_paid);
  if p_bonus > 0 then
    v_bonus_lot := gen_random_uuid();
    insert into public.sv_lots(id, business_id, account_id, operation_id, class, minted_cents, expiry_key, earned_seq)
    values (v_bonus_lot, p_business, v_account, v_op, 'bonus', p_bonus, p_bonus_expiry, nextval('app.sv_earned_seq'));
    insert into public.sv_lot_movements(business_id, account_id, lot_id, operation_id, kind, cents)
    values (p_business, v_account, v_bonus_lot, v_op, 'issue', p_bonus);
  end if;
  -- sv_topup_payments.plan_version_id is NOT NULL, so the evidence row is attributed to the
  -- business's most recently published plan version. Only the AMOUNT matters to the v68a cash cap.
  insert into public.sv_topup_payments(
    business_id, branch_id, client_id, operation_id, plan_version_id,
    amount_cents, currency, method, confirmation_mode, actor)
  select p_business,
         (select b.id from public.branches b where b.business_id = p_business
           order by b.is_default desc nulls last, b.id asc limit 1),
         p_client, v_op,
         (select pv.id from public.sv_plan_versions pv where pv.business_id = p_business
           order by pv.version_no desc, pv.id desc limit 1),
         p_paid,
         coalesce(nullif(btrim(bz.currency), ''), 'SGD'), 'test', 'synthetic_test', null
    from public.businesses bz where bz.id = p_business;
  return jsonb_build_object('account', v_account, 'operation', v_op,
    'paid_lot', v_paid_lot, 'bonus_lot', v_bonus_lot);
end $$;

-- definer shims so an impersonated browser-role session can read the revoked app.* helpers
create or replace function pg_temp.v69_rem(p_lot uuid) returns integer
  language sql security definer set search_path to 'pg_catalog','public','app','pg_temp' as $$
  select app.sv_lot_remaining(p_lot) $$;
grant execute on function pg_temp.v69_rem(uuid) to authenticated;
create or replace function pg_temp.v69_out(p_business uuid, p_account uuid) returns integer
  language sql security definer set search_path to 'pg_catalog','public','app','pg_temp' as $$
  select app.sv_total_outstanding(p_business, p_account) $$;
grant execute on function pg_temp.v69_out(uuid, uuid) to authenticated;
create or replace function pg_temp.v69_ready(p_business uuid) returns jsonb
  language sql security definer set search_path to 'pg_catalog','public','app','pg_temp' as $$
  select app.sv_cutover_readiness(p_business) $$;
grant execute on function pg_temp.v69_ready(uuid) to authenticated;
-- Σ remaining over one operation's lots, optionally restricted to a class. app.sv_lot_remaining is
-- revoked from browser roles, so an impersonated session needs a definer shim.
create or replace function pg_temp.v69_op_remaining(p_business uuid, p_op uuid, p_class text)
returns integer language sql security definer set search_path to 'pg_catalog','public','app','pg_temp' as $$
  select coalesce(sum(app.sv_lot_remaining(l.id)), 0)::integer from public.sv_lots l
   where l.business_id = p_business and l.operation_id = p_op
     and (p_class is null or l.class = p_class) $$;
grant execute on function pg_temp.v69_op_remaining(uuid, uuid, text) to authenticated;
-- PS-0 §10 invariants over a whole tenant, as a definer read.
create or replace function pg_temp.v69_invariants(p_business uuid) returns jsonb
language sql security definer set search_path to 'pg_catalog','public','app','pg_temp' as $$
  select jsonb_build_object(
    'out_of_range_lots', (select count(*) from public.sv_lots l where l.business_id = p_business
       and (app.sv_lot_remaining(l.id) < 0 or app.sv_lot_remaining(l.id) > l.minted_cents)),
    'reservation_movements', (select count(*) from public.sv_lot_movements m
       join public.sv_reservations r on r.operation_id = m.operation_id where m.business_id = p_business)) $$;
grant execute on function pg_temp.v69_invariants(uuid) to authenticated;
-- Platform-wide authority census as a definer read (sv_authority RLS scopes a tenant owner to their
-- own row, so a cross-tenant "nobody else moved" assertion has to be made outside that scope).
create or replace function pg_temp.v69_census() returns jsonb
language sql security definer set search_path to 'pg_catalog','public','app','pg_temp' as $$
  select coalesce(jsonb_object_agg(business_id::text, state), '{}'::jsonb) from public.sv_authority $$;
grant execute on function pg_temp.v69_census() to authenticated;

create or replace function pg_temp.v69_autoctx() returns boolean
  language sql security definer set search_path to 'pg_catalog','public','app','pg_temp' as $$
  select app.sv_automation_context() $$;
grant execute on function pg_temp.v69_autoctx() to authenticated;

-- The v62 snapshot ordering tie-break is (captured_at desc, id desc). Every snapshot written inside
-- ONE transaction shares now(), so two runs in this suite tie on captured_at and the "latest" one is
-- then decided by a random uuid. Production cannot reach that (each owner run is its own transaction
-- and the scheduled sweep writes at most one snapshot per business per run), but this suite must be
-- deterministic, so superseded snapshots are aged by a minute. ONLY the one NAMED immutability
-- trigger is suspended, and it is restored on the next statement - never `disable trigger all`, never
-- session_replication_role.
create or replace function pg_temp.v69_pin_snapshot(p_business uuid, p_keep uuid)
returns void language plpgsql as $$
begin
  execute 'reset role';
  alter table public.sv_reconciliation_snapshots disable trigger sv_reconciliation_snapshots_immutable_guard;
  update public.sv_reconciliation_snapshots
     set captured_at = captured_at - interval '1 minute'
   where business_id = p_business and id <> p_keep;
  alter table public.sv_reconciliation_snapshots enable trigger sv_reconciliation_snapshots_immutable_guard;
end $$;
grant execute on function pg_temp.v69_pin_snapshot(uuid, uuid) to authenticated;

-- Assert that a cutover attempt is refused with the code the preview names FIRST, that the
-- authority did not move, and that the attempt reserved no idempotency key. This single helper is
-- what makes "preview and act agree" a mechanical claim rather than a prose one.
create or replace function pg_temp.v69_expect_blocked(
  p_business uuid, p_code text, p_label text) returns void language plpgsql as $$
declare
  v_prev jsonb; v_ready jsonb; v_key uuid := gen_random_uuid();
  v_state_before text; v_state_after text; v_events_before int; v_events_after int;
begin
  select state into v_state_before from public.sv_authority
   where business_id = p_business and asset = 'stored_value';
  select count(*) into v_events_before from public.sv_cutover_events where business_id = p_business;

  v_prev := public.preview_sv_cutover(p_business);
  if (v_prev->>'ready')::boolean is not false then
    raise exception 'v69 %: preview says ready but the case is meant to be blocked', p_label;
  end if;
  if (v_prev->'blocking_codes'->>0) is distinct from p_code then
    raise exception 'v69 %: preview first blocking code is % (expected %), reasons %',
      p_label, v_prev->'blocking_codes'->>0, p_code, v_prev->>'blocking_reasons';
  end if;

  begin
    perform public.sv_cutover_business(p_business, 'v69 refusal matrix probe: ' || p_label,
      coalesce(v_prev->>'evidence_hash', 'x'), v_key);
    raise exception 'v69 %: sv_cutover_business unexpectedly succeeded', p_label;
  exception when sqlstate '22023' then
    if position(p_code in sqlerrm) = 0 then
      raise exception 'v69 %: cutover raised "%" but the preview named %', p_label, sqlerrm, p_code;
    end if;
  end;

  select state into v_state_after from public.sv_authority
   where business_id = p_business and asset = 'stored_value';
  select count(*) into v_events_after from public.sv_cutover_events where business_id = p_business;
  if v_state_after is distinct from v_state_before then
    raise exception 'v69 %: a refused cutover moved the authority (% -> %)', p_label, v_state_before, v_state_after;
  end if;
  if v_events_after <> v_events_before then
    raise exception 'v69 %: a refused cutover wrote a cutover event', p_label;
  end if;
  if exists (select 1 from public.sv_operations o
              where o.business_id = p_business and o.operation_type = 'cutover'
                and o.idempotency_key = v_key) then
    raise exception 'v69 %: a refused cutover reserved its idempotency key', p_label;
  end if;
end $$;
grant execute on function pg_temp.v69_expect_blocked(uuid, text, text) to authenticated;

-- ==========================================================================================
-- PART 0 - STATIC CATALOG TRUTH ON THE APPLIED CHAIN (read before anything is mutated)
-- ==========================================================================================
do $v69_part0$
declare
  v_jobs int; v_active_col boolean; v_status jsonb; v_src text; v_n int;
begin
  reset role;

  ---------------------------------------------------------------- §2 automation is SCHEDULED
  select exists (select 1 from pg_attribute a
                  where a.attrelid = 'cron.job'::regclass and a.attname = 'active'
                    and a.attnum > 0 and not a.attisdropped) into v_active_col;
  select count(*) into v_jobs from cron.job
   where jobname in ('frenly-sv-expiry', 'frenly-sv-tender-release', 'frenly-sv-reconciliation');
  assert v_jobs = 3,
    'v69: the three stored-value cron jobs are not present on the applied chain (found ' || v_jobs || ')';
  -- the SGT convention: neither daily job may land in the taken 19:00-19:20 UTC block
  assert not exists (
    select 1 from cron.job j
     where j.jobname in ('frenly-sv-expiry', 'frenly-sv-reconciliation')
       and j.schedule ~ '^(0|[1-9]|1[0-9]|20) 19 \* \* \*$'),
    'v69: a daily stored-value job collides with the existing 19:00-19:20 UTC block';
  assert (select count(*) from cron.job
           where jobname = 'frenly-sv-tender-release' and schedule like '*/%') = 1,
    'v69: the checkout-tender release job is not on a minutes-scale schedule';
  assert (select count(*) from cron.job
           where jobname = 'frenly-sv-expiry' and command like '%run_sv_expiry_sweep%') = 1,
    'v69: the expiry job does not call the expiry driver';
  assert (select count(*) from cron.job
           where jobname = 'frenly-sv-tender-release' and command like '%run_sv_tender_release%') = 1,
    'v69: the tender-release job does not call the tender-release driver';
  assert (select count(*) from cron.job
           where jobname = 'frenly-sv-reconciliation' and command like '%run_sv_reconciliation_sweep%') = 1,
    'v69: the reconciliation job does not call the reconciliation driver';
  v_status := app.sv_automation_status();
  assert (v_status->>'ok')::boolean is true,
    'v69: app.sv_automation_status() is not ok on the applied chain: ' || v_status::text;

  ---------------------------------------------------------------- definer + search_path + ACL
  assert not exists (
    select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where (n.nspname, p.proname) in (
       ('public', 'sv_cutover_business'), ('public', 'set_sv_cutover_designation'),
       ('public', 'preview_sv_cutover'), ('public', 'get_sv_authority_overview'),
       ('app', 'sv_cutover_readiness'), ('app', 'sv_automation_status'),
       ('app', 'sv_automation_context'), ('app', 'sv_automation_begin'),
       ('app', 'sv_automation_finish'), ('app', 'run_sv_expiry_sweep'),
       ('app', 'run_sv_tender_release'), ('app', 'run_sv_reconciliation_sweep'),
       ('app', 'sv_authority_guard'), ('app', 'sv_cutover_events_guard'),
       ('app', 'sv_cutover_designations_guard'), ('app', 'sv_automation_runs_guard'))
       and (not p.prosecdef
            or array_to_string(coalesce(p.proconfig, '{}'), ',') <> 'search_path=pg_catalog, public, app, pg_temp')),
    'v69: a v69 function is not SECURITY DEFINER or lost the canonical search_path pin';

  assert has_function_privilege('authenticated', 'public.sv_cutover_business(uuid,text,text,uuid)', 'execute'),
    'v69: sv_cutover_business is not callable by authenticated';
  assert has_function_privilege('authenticated', 'public.set_sv_cutover_designation(uuid,boolean,text)', 'execute'),
    'v69: set_sv_cutover_designation is not callable by authenticated';
  assert not has_function_privilege('anon', 'public.sv_cutover_business(uuid,text,text,uuid)', 'execute'),
    'v69: sv_cutover_business leaked to anon';
  assert not has_function_privilege('anon', 'public.set_sv_cutover_designation(uuid,boolean,text)', 'execute'),
    'v69: set_sv_cutover_designation leaked to anon';
  foreach v_src in array array[
    'app.sv_cutover_readiness(uuid)', 'app.sv_cutover_raise(jsonb)', 'app.sv_automation_status()',
    'app.sv_automation_context()', 'app.sv_automation_begin(text)', 'app.sv_automation_finish(uuid,jsonb)',
    'app.run_sv_expiry_sweep(integer)', 'app.run_sv_tender_release(integer)',
    'app.run_sv_reconciliation_sweep()'] loop
    assert not has_function_privilege('authenticated', v_src, 'execute'),
      'v69: authenticated retains EXECUTE on internal helper ' || v_src;
    assert not has_function_privilege('anon', v_src, 'execute'),
      'v69: anon retains EXECUTE on internal helper ' || v_src;
  end loop;

  ---------------------------------------------------------------- new tables: RLS + zero browser DML
  foreach v_src in array array['sv_cutover_events', 'sv_cutover_designations', 'sv_automation_runs'] loop
    assert (select relrowsecurity from pg_class where oid = ('public.' || v_src)::regclass),
      'v69: RLS is not enabled on ' || v_src;
    assert not has_table_privilege('anon', 'public.' || v_src, 'select'),
      'v69: anon can read ' || v_src;
    assert not has_table_privilege('authenticated', 'public.' || v_src, 'insert')
       and not has_table_privilege('authenticated', 'public.' || v_src, 'update')
       and not has_table_privilege('authenticated', 'public.' || v_src, 'delete'),
      'v69: a browser role retains a direct write on ' || v_src;
    assert has_table_privilege('authenticated', 'public.' || v_src, 'select'),
      'v69: authenticated lost the read grant on ' || v_src || ' (RLS is the scope, not the grant)';
    assert not exists (select 1 from information_schema.columns
                        where table_schema = 'public' and table_name = v_src
                          and column_name in ('balance', 'balance_cents')),
      'v69: ' || v_src || ' carries a mutable balance column';
  end loop;
  -- sv_automation_runs is PLATFORM machinery: super-admin read only, no tenant policy
  assert (select count(*) from pg_policies
           where schemaname = 'public' and tablename = 'sv_automation_runs') = 1,
    'v69: sv_automation_runs must expose exactly one (super-admin) read policy';
  assert (select count(*) from pg_policies
           where schemaname = 'public' and tablename = 'sv_cutover_events') = 2,
    'v69: sv_cutover_events must expose exactly the owner + super-admin read policies';

  ---------------------------------------------------------------- NEVER GLOBAL (contract §3)
  -- exactly ONE function in the entire catalog can write a cutover event
  select count(*) into v_n from pg_proc p
   where p.prosrc like '%insert into public.sv_cutover_events%';
  assert v_n = 1, 'v69: sv_cutover_events has ' || v_n || ' writers; it must have exactly one';
  assert (select p.proname from pg_proc p
           where p.prosrc like '%insert into public.sv_cutover_events%') = 'sv_cutover_business',
    'v69: the single sv_cutover_events writer is not sv_cutover_business';
  -- exactly TWO functions can update sv_authority, and NEITHER contains a loop, so neither can
  -- transition more than one business per call
  select count(*) into v_n from pg_proc p
   where p.prosrc like '%update public.sv_authority%';
  assert v_n = 2, 'v69: ' || v_n || ' functions update sv_authority; expected exactly two';
  assert (select string_agg(p.proname, ',' order by p.proname) from pg_proc p
           where p.prosrc like '%update public.sv_authority%')
         = 'sv_apply_authority_state,sv_cutover_business',
    'v69: an unexpected function can update sv_authority';
  assert not exists (
    select 1 from pg_proc p
     where p.prosrc like '%update public.sv_authority%'
       and p.prosrc ~* '(^|[^a-z_])loop([^a-z_]|$)'),
    'v69: a function that can write sv_authority contains a loop (it could transition more than one business)';
  select prosrc into v_src from pg_proc where oid = 'public.sv_cutover_business(uuid,text,text,uuid)'::regprocedure;
  assert (length(v_src) - length(replace(v_src, 'update public.sv_authority', ''))) / length('update public.sv_authority') = 1,
    'v69: sv_cutover_business contains more than one sv_authority update';
  assert position('where business_id = p_business and asset = ''stored_value''' in v_src) > 0,
    'v69: the cutover update is not keyed to the single p_business argument';
  assert v_src !~* 'business_id\s+in\s*\(' and v_src !~* '(^|[^a-z_])all([^a-z_]|$)\s*=',
    'v69: sv_cutover_business shows a multi-business shape';

  ---------------------------------------------------------------- ordinary state-setting is closed
  select prosrc into v_src from pg_proc
   where oid = 'public.set_sv_authority_state(uuid,text,text,text)'::regprocedure;
  assert position('''unbuilt'', ''shadow_testing'', ''reconciliation_blocked''' in v_src) > 0,
    'v69: set_sv_authority_state no longer restricts itself to the safe subset';
  -- and there is no assignment/comparison that could put it there (the only 'live' bytes in this
  -- body are inside the explanatory comment); the behavioural proof is PART 1f.
  assert v_src !~ 'state\s*(:=|=)\s*''live''' and position('p_state not in' in v_src) > 0,
    'v69: set_sv_authority_state shows a live-settable shape';
  select prosrc into v_src from pg_proc
   where oid = 'app.sv_apply_authority_state(uuid,text,text,text,uuid)'::regprocedure;
  assert position('''unbuilt'', ''shadow_testing'', ''reconciliation_blocked''' in v_src) > 0,
    'v69: the internal authority path no longer restricts itself to the safe subset';
  assert position('sv_live_not_reversible' in v_src) > 0,
    'v69: the internal authority path does not make live terminal';

  ---------------------------------------------------------------- readiness is computed, not faked
  select prosrc into v_src from pg_proc where oid = 'public.preview_sv_cutover(uuid)'::regprocedure;
  assert position('sv_cutover_readiness' in v_src) > 0,
    'v69: preview_sv_cutover does not consult the readiness oracle';
  assert position('HARDCODED' in v_src) = 0,
    'v69: preview_sv_cutover still carries a hardcoded readiness';
  select prosrc into v_src from pg_proc where oid = 'public.get_sv_authority_overview(uuid)'::regprocedure;
  assert position('sv_cutover_readiness' in v_src) > 0,
    'v69: get_sv_authority_overview still hardcodes can_cutover';

  ---------------------------------------------------------------- §6 LOW-1 is documented, not just believed
  assert coalesce(obj_description(
    'public.sv_reverse_spend(uuid,uuid,uuid)'::regprocedure, 'pg_proc'), '') ilike '%40P01%retriable%'
     and coalesce(obj_description(
    'public.sv_reverse_spend(uuid,uuid,uuid)'::regprocedure, 'pg_proc'), '') ilike '%retry 40P01%',
    'v69: door A does not document 40P01 as an accepted retriable outcome';
  assert coalesce(obj_description(
    'public.reverse_sale(uuid,uuid,text,text,text,text)'::regprocedure, 'pg_proc'), '') ilike '%40P01%retriable%'
     and coalesce(obj_description(
    'public.reverse_sale(uuid,uuid,text,text,text,text)'::regprocedure, 'pg_proc'), '') ilike '%retry 40P01%',
    'v69: door B does not document 40P01 as an accepted retriable outcome';

  ---------------------------------------------------------------- applying v69 cut nobody over
  assert (select count(*) from public.sv_authority where state = 'live') = 0,
    'v69: a business is already live on the applied chain - applying v69 must cut over NOBODY';
  assert (select count(*) from public.sv_cutover_events) = 0,
    'v69: a cutover event exists on the applied chain';
  assert (select count(*) from public.sv_cutover_designations) = 0,
    'v69: a cutover designation exists on the applied chain';

  raise notice 'v69 PART 0 (catalog truth, cron presence, never-global tripwire): PASS';
end
$v69_part0$;

-- ==========================================================================================
-- PARTS 1-5
-- ==========================================================================================
do $v69_main$
declare
  A uuid; A_owner uuid; B uuid; B_owner_sa uuid; A_front uuid := gen_random_uuid();
  v_branch uuid; v_svc uuid;
  v_prev jsonb; v_res jsonb; v_res2 jsonb; v_ready jsonb;
  v_key uuid; v_key2 uuid; v_hash text; v_state text; v_n int; v_row record;
  v_client uuid; v_client2 uuid; v_client3 uuid; v_client4 uuid; v_client5 uuid; v_client6 uuid;
  v_acct uuid; v_op uuid; v_opA uuid; v_opB uuid; v_seed jsonb; v_seedA jsonb; v_seedB jsonb;
  v_paid_lot uuid; v_bonus_lot uuid; v_ver uuid; v_ver2 uuid; v_tok uuid; v_spend_op uuid;
  v_gc uuid; v_cash int; v_claw int; v_cash_total int; v_claw_total int; i int;
  v_before int; v_after int; v_marker uuid; v_trail text; v_fndef text;
begin
  reset role;
  select b.id into A from public.businesses b where b.slug like 'pristine-a-%';
  select b.id into B from public.businesses b where b.slug like 'pristine-b-%';
  select s.user_id into A_owner from public.staff s where s.business_id = A and s.role = 'owner';
  select s.user_id into B_owner_sa from public.staff s where s.business_id = B and s.role = 'owner';
  assert exists (select 1 from public.super_admins where user_id = B_owner_sa),
    'v69 fixture: the pristine fixture no longer makes owner B a super admin';
  select br.id into v_branch from public.branches br where br.business_id = A
   order by br.is_default desc nulls last, br.id asc limit 1;
  insert into auth.users(instance_id, id, aud, role, email, encrypted_password,
                         email_confirmed_at, created_at, updated_at)
  values ('00000000-0000-0000-0000-000000000000', A_front, 'authenticated', 'authenticated',
          'v69-front-' || A_front::text || '@example.test', '', now(), now(), now());
  insert into public.staff(business_id, user_id, full_name, role, active)
  values (A, A_front, 'v69 front desk', 'frontdesk', true);
  insert into public.services(business_id, name, price_cents, duration_min)
  values (A, 'v69 service 5000', 5000, 30) returning id into v_svc;
  insert into public.clients(business_id, full_name, phone) values
    (A, 'v69 c1', '+6591000001'), (A, 'v69 c2', '+6591000002'), (A, 'v69 c3', '+6591000003'),
    (A, 'v69 c4', '+6591000004'), (A, 'v69 c5', '+6591000005'), (A, 'v69 c6', '+6591000006'),
    (A, 'v69 g',  '+6591000007'), (A, 'v69 gs', '+6591000008'), (A, 'v69 h',  '+6591000009');
  select id into v_client  from public.clients where business_id = A and full_name = 'v69 c1';
  select id into v_client2 from public.clients where business_id = A and full_name = 'v69 c2';
  select id into v_client3 from public.clients where business_id = A and full_name = 'v69 c3';
  select id into v_client4 from public.clients where business_id = A and full_name = 'v69 c4';
  select id into v_client5 from public.clients where business_id = A and full_name = 'v69 c5';
  select id into v_client6 from public.clients where business_id = A and full_name = 'v69 c6';

  -- =======================================================================================
  -- PART 1 - THE REACHABILITY TRIPWIRE
  -- =======================================================================================
  reset role;
  -- (1a) a privileged direct UPDATE to 'live' with NO same-transaction cutover event is refused
  begin
    update public.sv_authority set state = 'live' where business_id = A and asset = 'stored_value';
    raise exception 'v69 tripwire: a direct UPDATE reached live without a cutover event';
  exception when sqlstate '2F004' or sqlstate '38000' or sqlstate '23514' or sqlstate '0A000' then
    raise exception 'v69 tripwire: unexpected sqlstate';
  when others then
    if sqlstate <> '2BP01' and position('cutover tripwire' in sqlerrm) = 0 then
      raise exception 'v69 tripwire: direct UPDATE failed with the wrong error: % %', sqlstate, sqlerrm;
    end if;
  end;
  assert (select state from public.sv_authority where business_id = A and asset = 'stored_value') = 'unbuilt',
    'v69 tripwire: the refused direct UPDATE still moved the state';

  -- (1b) an INSERT can never be born live
  begin
    insert into public.sv_authority(business_id, asset, state)
    values (B, 'stored_value', 'live');
    raise exception 'v69 tripwire: an sv_authority row was inserted at live';
  exception when others then
    if position('never born live' in sqlerrm) = 0 and position('cannot be created live' in sqlerrm) = 0
       and position('sv_authority_business_asset_uk' in sqlerrm) = 0 then
      -- the unique key may fire first; either refusal is acceptable, a SUCCESS is not
      if position('cutover' in sqlerrm) = 0 then
        raise exception 'v69 tripwire: insert-at-live failed with the wrong error: % %', sqlstate, sqlerrm;
      end if;
    end if;
  end;

  -- (1c) 'ready_for_cutover' is STILL unconditionally rejected, with the original message
  begin
    update public.sv_authority set state = 'ready_for_cutover'
     where business_id = A and asset = 'stored_value';
    raise exception 'v69 tripwire: ready_for_cutover became reachable';
  exception when others then
    assert position('cutover is unreachable until a future authorized phase' in sqlerrm) > 0,
      'v69 tripwire: the ready_for_cutover refusal lost its original message: ' || sqlerrm;
  end;

  -- (1d) sv_authority is still undeletable
  begin
    delete from public.sv_authority where business_id = A and asset = 'stored_value';
    raise exception 'v69 tripwire: sv_authority became deletable';
  exception when others then
    assert position('not deletable' in sqlerrm) > 0,
      'v69 tripwire: the delete refusal lost its original message: ' || sqlerrm;
  end;

  -- (1e) no browser role can write the table at all
  assert not has_table_privilege('authenticated', 'public.sv_authority', 'update')
     and not has_table_privilege('authenticated', 'public.sv_authority', 'insert'),
    'v69 tripwire: a browser role can write sv_authority directly';

  -- (1f) ordinary state-setting still cannot name live
  perform pg_temp.as_v69(A_owner, 'authenticated');
  begin
    perform public.set_sv_authority_state(A, 'stored_value', 'live', 'v69 tries the ordinary door');
    raise exception 'v69 tripwire: set_sv_authority_state reached live';
  exception when sqlstate '22023' then null;
  end;
  raise notice 'v69 PART 1 (reachability tripwire): PASS';

  -- =======================================================================================
  -- PART 2 - REFUSAL MATRIX + PREVIEW<->ACT AGREEMENT
  -- =======================================================================================
  ---------------------------------------------------------------- authorization
  perform pg_temp.as_v69(A_front, 'authenticated');
  begin perform public.preview_sv_cutover(A);
    raise exception 'v69: a frontdesk previewed cutover';
  exception when sqlstate '42501' then null; end;
  begin perform public.sv_cutover_business(A, 'front desk tries to go live', repeat('a', 64), gen_random_uuid());
    raise exception 'v69: a frontdesk cut a business over';
  exception when sqlstate '42501' then null; end;
  perform pg_temp.as_v69(B_owner_sa, 'authenticated');
  begin perform public.sv_cutover_business(A, 'a super admin tries to go live', repeat('a', 64), gen_random_uuid());
    raise exception 'v69: a super admin (not the owner) cut a business over';
  exception when sqlstate '42501' then null; end;
  perform pg_temp.as_v69(null, 'anon');
  begin perform public.preview_sv_cutover(A);
    raise exception 'v69: anon previewed cutover';
  exception when others then null; end;

  ---------------------------------------------------------------- arguments
  perform pg_temp.as_v69(A_owner, 'authenticated');
  begin perform public.sv_cutover_business(A, 'a long enough reason here', repeat('a', 64), null);
    raise exception 'v69: a null idempotency key was accepted';
  exception when sqlstate '22023' then null; end;
  begin perform public.sv_cutover_business(A, 'too short', repeat('a', 64), gen_random_uuid());
    raise exception 'v69: a sub-10-character reason was accepted for a financial go-live';
  exception when sqlstate '22023' then
    assert position('at least 10 characters' in sqlerrm) > 0, 'v69: wrong short-reason error: ' || sqlerrm; end;
  begin perform public.sv_cutover_business(A, 'a long enough reason here', '   ', gen_random_uuid());
    raise exception 'v69: a blank evidence hash was accepted';
  exception when sqlstate '22023' then
    assert position('sv_evidence_required' in sqlerrm) > 0, 'v69: wrong evidence error: ' || sqlerrm; end;

  ---------------------------------------------------------------- sv_synthetic_business (precedence 1)
  reset role;
  update public.businesses set is_synthetic = true where id = A;
  perform pg_temp.as_v69(A_owner, 'authenticated');
  perform pg_temp.v69_expect_blocked(A, 'sv_synthetic_business', 'synthetic business');
  -- a super admin cannot even designate a synthetic business
  perform pg_temp.as_v69(B_owner_sa, 'authenticated');
  begin perform public.set_sv_cutover_designation(A, true, 'designating a synthetic business');
    raise exception 'v69: a synthetic business was designated for cutover';
  exception when sqlstate '22023' then
    assert position('sv_synthetic_business' in sqlerrm) > 0, 'v69: wrong synthetic-designation error'; end;
  reset role;
  update public.businesses set is_synthetic = false where id = A;

  ---------------------------------------------------------------- sv_not_designated (precedence 3)
  perform pg_temp.as_v69(A_owner, 'authenticated');
  perform pg_temp.v69_expect_blocked(A, 'sv_not_designated', 'undesignated business');
  -- the business owner CANNOT designate itself (a firm cannot put itself live)
  begin perform public.set_sv_cutover_designation(A, true, 'the owner designates itself');
    raise exception 'v69: a business owner designated its own business';
  exception when sqlstate '42501' then null; end;

  ---------------------------------------------------------------- the super admin designates A
  perform pg_temp.as_v69(B_owner_sa, 'authenticated');
  v_res := public.set_sv_cutover_designation(A, true, 'v69 rehearsal pilot designation for business A');
  assert (v_res->>'designated')::boolean is true and (v_res->>'unchanged')::boolean is false,
    'v69: designation did not take';
  -- idempotent re-designation
  v_res2 := public.set_sv_cutover_designation(A, true, 'v69 rehearsal pilot designation for business A');
  assert (v_res2->>'unchanged')::boolean is true and (v_res2->>'designation_id') = (v_res->>'designation_id'),
    'v69: re-designation was not idempotent';
  -- SINGLETON (rev-2, review D2): while A holds the active designation, B cannot be designated (the
  -- pilot is ONE firm). The collision is now a TYPED refusal raised under the global advisory lock,
  -- not a raw 23505 surfaced from the singleton index.
  begin perform public.set_sv_cutover_designation(B, true, 'a second pilot firm designation attempt');
    raise exception 'v69: two businesses were designated for cutover at once';
  exception when sqlstate '22023' then
    assert position('sv_pilot_already_designated' in sqlerrm) > 0,
      'v69: the second-designation collision is not the typed sv_pilot_already_designated: ' || sqlerrm;
  end;

  ---------------------------------------------------------------- sv_not_ready (precedence 4)
  perform pg_temp.as_v69(A_owner, 'authenticated');
  perform pg_temp.v69_expect_blocked(A, 'sv_not_ready', 'authority is unbuilt');
  v_prev := public.preview_sv_cutover(A);
  assert position('authority is unbuilt' in (v_prev->'blocking_reasons')::text) > 0,
    'v69: the preserved "authority is <state>" reason prefix is gone';
  assert position('future authorized phase' in (v_prev->'blocking_reasons')::text) = 0,
    'v69: the retired PS-2A standing blocker is still emitted';

  ---------------------------------------------------------------- sv_reconciliation_unclean (precedence 5)
  perform public.set_sv_authority_state(A, 'stored_value', 'shadow_testing', 'v69 begins shadow testing');
  perform pg_temp.v69_expect_blocked(A, 'sv_reconciliation_unclean', 'reconciliation never run');
  v_prev := public.preview_sv_cutover(A);
  assert (v_prev->'blocking_reasons')::text like '%reconciliation has not been run%',
    'v69: the preserved "reconciliation has not been run" reason string changed';

  -- an unclean snapshot: a gift card with a balance is a discrepancy against the legacy analog
  reset role;
  insert into public.gift_cards(business_id, code, initial_cents, balance_cents, status)
  values (A, 'V69GC' || substr(md5(random()::text), 1, 8), 5000, 5000, 'active') returning id into v_gc;
  perform pg_temp.as_v69(A_owner, 'authenticated');
  v_res := public.run_sv_reconciliation(A);
  assert (v_res->>'reconciliation_status') = 'blocked' and (v_res->>'discrepancy_count')::int >= 1,
    'v69: the gift-card discrepancy did not block reconciliation';
  assert (select state from public.sv_authority where business_id = A and asset = 'stored_value')
         = 'reconciliation_blocked',
    'v69: a NON-live tenant with discrepancies must still be driven to reconciliation_blocked';
  -- from reconciliation_blocked the first blocker is the STATE; step back to shadow_testing and the
  -- unclean snapshot becomes the first blocker, with the preserved discrepancy reason string
  perform pg_temp.v69_expect_blocked(A, 'sv_not_ready', 'authority is reconciliation_blocked');
  perform public.set_sv_authority_state(A, 'stored_value', 'shadow_testing', 'v69 steps back to shadow');
  perform pg_temp.v69_expect_blocked(A, 'sv_reconciliation_unclean', 'open discrepancies');
  v_prev := public.preview_sv_cutover(A);
  assert (v_prev->'blocking_reasons')::text like '%open discrepancy(ies); it must be clean%',
    'v69: the preserved discrepancy reason string changed';
  -- The card is DRAINED, not deleted: a prior run wrote a shadow evaluation carrying this card's
  -- legacy_ref, so deleting the row would simply trade the discrepancy for a missing_in_legacy one.
  -- A zero-balance card is what a genuinely resolved discrepancy looks like.
  reset role;
  update public.gift_cards set balance_cents = 0, status = 'redeemed' where id = v_gc;
  perform pg_temp.as_v69(A_owner, 'authenticated');
  v_res := public.run_sv_reconciliation(A);
  assert (v_res->>'reconciliation_status') = 'clean',
    'v69: reconciliation did not come back clean: ' || v_res::text;
  perform pg_temp.v69_pin_snapshot(A, (v_res->>'snapshot_id')::uuid);
  perform pg_temp.as_v69(A_owner, 'authenticated');

  ---------------------------------------------------------------- sv_paused (precedence 6)
  perform public.sv_pause(A, 'stored_value', 'all', 'v69 checks the pause blocker');
  perform pg_temp.v69_expect_blocked(A, 'sv_paused', 'all-scope pause active');
  v_prev := public.preview_sv_cutover(A);
  assert (v_prev->'blocking_reasons')::text like '%an all-scope stored-value pause is active%',
    'v69: the preserved pause reason string changed';
  perform public.sv_lift_pause(A, 'stored_value', 'all', 'v69 lifts the probe pause');
  -- an earn/redeem-only pause is NOT a cutover blocker (only an all-scope pause is)
  perform public.sv_pause(A, 'stored_value', 'redeem', 'v69 checks scope discrimination');
  assert (public.preview_sv_cutover(A)->>'ready')::boolean is true,
    'v69: a redeem-scope pause wrongly blocks cutover (only all-scope should)';
  perform public.sv_lift_pause(A, 'stored_value', 'redeem', 'v69 lifts the scope probe');

  ---------------------------------------------------------------- sv_automation_missing (precedence 7)
  -- (i) a MISSING job. cron.job is a plain table in both real pg_cron and the local rehearsal stub.
  --     The job is hidden by RENAMING it rather than deleting it: jobid is a GENERATED ALWAYS
  --     identity in the rehearsal stub, so a delete/re-insert round trip is not portable, whereas a
  --     jobname update is. The outer ROLLBACK discards the mutation regardless.
  reset role;
  update cron.job set jobname = 'frenly-sv-expiry-v69probe' where jobname = 'frenly-sv-expiry';
  perform pg_temp.as_v69(A_owner, 'authenticated');
  perform pg_temp.v69_expect_blocked(A, 'sv_automation_missing', 'expiry sweep unscheduled');
  v_prev := public.preview_sv_cutover(A);
  assert (v_prev->'automation'->>'ok')::boolean is false
     and (v_prev->'automation'->'missing')::text like '%frenly-sv-expiry%',
    'v69: the preview does not name the missing automation job';
  reset role;
  update cron.job set jobname = 'frenly-sv-expiry' where jobname = 'frenly-sv-expiry-v69probe';
  perform pg_temp.as_v69(A_owner, 'authenticated');
  assert (public.preview_sv_cutover(A)->>'ready')::boolean is true,
    'v69: restoring the cron job did not restore readiness';

  -- (ii) an INACTIVE job. Real pg_cron has cron.job.active; the local rehearsal stub does not, so
  --      the column is added inside this rolled-back transaction when absent (DDL is transactional)
  --      and app.sv_automation_status() introspects for it either way.
  reset role;
  if not exists (select 1 from pg_attribute a
                  where a.attrelid = 'cron.job'::regclass and a.attname = 'active'
                    and a.attnum > 0 and not a.attisdropped) then
    alter table cron.job add column active boolean not null default true;
    raise notice 'v69: cron.job had no active column (rehearsal stub); one was added for this rolled-back test only';
  end if;
  update cron.job set active = false where jobname = 'frenly-sv-reconciliation';
  perform pg_temp.as_v69(A_owner, 'authenticated');
  perform pg_temp.v69_expect_blocked(A, 'sv_automation_missing', 'reconciliation job inactive');
  v_prev := public.preview_sv_cutover(A);
  assert (v_prev->'automation'->>'basis') = 'cron.job.active',
    'v69: the automation status did not use the active column when it exists';
  assert (v_prev->'automation'->'missing')::text like '%frenly-sv-reconciliation%',
    'v69: an inactive job is not reported missing';
  reset role;
  update cron.job set active = true where jobname = 'frenly-sv-reconciliation';
  perform pg_temp.as_v69(A_owner, 'authenticated');
  assert (public.preview_sv_cutover(A)->>'ready')::boolean is true,
    'v69: reactivating the cron job did not restore readiness';

  ---------------------------------------------------------------- sv_evidence_stale
  v_prev := public.preview_sv_cutover(A);
  v_hash := v_prev->>'evidence_hash';
  v_res := public.run_sv_reconciliation(A);         -- a NEW clean snapshot -> new evidence, still ready
  perform pg_temp.v69_pin_snapshot(A, (v_res->>'snapshot_id')::uuid);
  perform pg_temp.as_v69(A_owner, 'authenticated');
  assert (public.preview_sv_cutover(A)->>'ready')::boolean is true, 'v69: a fresh clean run blocked readiness';
  assert (public.preview_sv_cutover(A)->>'evidence_hash') <> v_hash,
    'v69: the evidence hash did not move when the evidence moved';
  v_key := gen_random_uuid();
  begin
    perform public.sv_cutover_business(A, 'acting on stale preview evidence', v_hash, v_key);
    raise exception 'v69: a cutover acted on stale evidence';
  exception when sqlstate '22023' then
    assert position('sv_evidence_stale' in sqlerrm) > 0, 'v69: wrong stale-evidence error: ' || sqlerrm; end;
  assert not exists (select 1 from public.sv_operations
                      where business_id = A and operation_type = 'cutover' and idempotency_key = v_key),
    'v69: a stale-evidence refusal reserved its idempotency key';
  assert (select state from public.sv_authority where business_id = A and asset = 'stored_value') = 'shadow_testing',
    'v69: a stale-evidence refusal moved the authority';

  ------------------------------------------- rev-3, review MEDIUM-1: sv_designation_revoked
  -- THE DEFECT. sv_cutover_business reads the active designation TWICE: once inside
  -- app.sv_cutover_readiness (the read that AUTHORIZES the go-live) and once again for the values it
  -- writes into the PERMANENT record - sv_cutover_events (immutable, UNIQUE(business_id, asset)) and
  -- audit_log. Rev-2 took no lock for the second read, so under READ COMMITTED a legitimate revoke
  -- committed in the gap left it empty, plpgsql left the row variable NULL, and the cutover completed
  -- writing designation_id = NULL / designated_by = NULL - a permanent, unrepairable hole in "who
  -- authorized this business going live". Rev-3 re-reads under the SAME global designation mutex the
  -- designate/revoke path takes and REFUSES with the typed sv_designation_revoked if it is gone.
  --
  -- DETERMINISTIC SINGLE-CONNECTION REPRODUCTION. The real race needs two connections (that half is
  -- db/tests/v69_cutover_concurrency.sh Round A0). Here the identical STATE is produced without one:
  -- freeze the readiness oracle to the object it returned WHILE the designation was live, then really
  -- revoke the designation. sv_cutover_business then observes exactly what it observes when a revoke
  -- commits inside the window - readiness says ready and names a designation, the catalog no longer
  -- has one. DDL is transactional, and the original oracle is restored from pg_get_functiondef
  -- immediately afterwards (the outer ROLLBACK is the second net).
  perform pg_temp.as_v69(A_owner, 'authenticated');
  v_prev := public.preview_sv_cutover(A);
  assert (v_prev->>'ready')::boolean is true,
    'v69 MEDIUM-1: A is not ready immediately before the revoked-designation probe';
  v_hash  := v_prev->>'evidence_hash';
  v_ready := pg_temp.v69_ready(A);
  assert (v_ready->>'designation_id') is not null,
    'v69 MEDIUM-1: the frozen readiness object carries no designation, so the probe would prove nothing';
  perform pg_temp.as_v69(B_owner_sa, 'authenticated');
  perform public.set_sv_cutover_designation(A, false, 'v69 MEDIUM-1 revokes A while a cutover is in flight');
  reset role;
  v_fndef := pg_get_functiondef('app.sv_cutover_readiness(uuid)'::regprocedure);
  execute format(
    'create or replace function app.sv_cutover_readiness(p_business uuid) returns jsonb '
    || 'language sql stable security definer '
    || 'set search_path to ''pg_catalog'', ''public'', ''app'', ''pg_temp'' '
    || 'as $frozen$ select %L::jsonb $frozen$', v_ready::text);
  perform pg_temp.as_v69(A_owner, 'authenticated');
  assert (public.preview_sv_cutover(A)->>'ready')::boolean is true,
    'v69 MEDIUM-1: the frozen oracle does not still report ready - the probe is not reproducing the window';
  v_key := gen_random_uuid();
  begin
    perform public.sv_cutover_business(A, 'v69 MEDIUM-1 cutover racing a designation revoke', v_hash, v_key);
    raise exception 'v69 MEDIUM-1: a cutover COMPLETED with its designation revoked (rev-2 behaviour: it would have written designation_id/designated_by NULL into an immutable record)';
  exception when sqlstate '22023' then
    assert position('sv_designation_revoked' in sqlerrm) > 0,
      'v69 MEDIUM-1: wrong revoked-designation error: ' || sqlerrm; end;
  reset role;
  execute v_fndef;                                    -- the real oracle is back
  assert position('sv_pilot_already_live' in pg_get_functiondef('app.sv_cutover_readiness(uuid)'::regprocedure)) > 0,
    'v69 MEDIUM-1: the readiness oracle was not restored after the probe';

  -- Fail-closed means fail-CLOSED: nothing moved, nothing permanent was written, no key was burned.
  assert (select state from public.sv_authority where business_id = A and asset = 'stored_value') = 'shadow_testing',
    'v69 MEDIUM-1: the refused cutover moved the authority';
  assert not exists (select 1 from public.sv_cutover_events where business_id = A),
    'v69 MEDIUM-1: the refused cutover wrote a permanent cutover event';
  assert not exists (select 1 from public.audit_log where business_id = A and action = 'SV_CUTOVER'),
    'v69 MEDIUM-1: the refused cutover claimed a cutover in the audit log';
  assert not exists (select 1 from public.sv_operations
                      where business_id = A and operation_type = 'cutover' and idempotency_key = v_key),
    'v69 MEDIUM-1: the refused cutover reserved its idempotency key';

  -- ...and the refusal is RETRIABLE: re-designate, re-preview, and the SAME key still works. Proven
  -- inside a plpgsql subtransaction that is deliberately unwound, so PART 3 below still performs the
  -- FIRST and only cutover of A.
  perform pg_temp.as_v69(B_owner_sa, 'authenticated');
  perform public.set_sv_cutover_designation(A, true, 'v69 MEDIUM-1 re-designates A so the refused cutover can be retried');
  perform pg_temp.as_v69(A_owner, 'authenticated');
  begin
    v_res := public.sv_cutover_business(A, 'v69 MEDIUM-1 cutover racing a designation revoke',
      public.preview_sv_cutover(A)->>'evidence_hash', v_key);
    assert (v_res->>'status') = 'ok' and (v_res->>'new_state') = 'live'
       and (v_res->>'designation_id') is not null and (v_res->>'designated_by') is not null,
      'v69 MEDIUM-1: the retry after re-designation did not succeed with a recorded designation: ' || v_res::text;
    raise exception 'V69_MEDIUM1_UNWIND' using errcode = 'P0001';
  exception when sqlstate 'P0001' then
    if sqlerrm <> 'V69_MEDIUM1_UNWIND' then raise; end if; end;
  assert (select state from public.sv_authority where business_id = A and asset = 'stored_value') = 'shadow_testing',
    'v69 MEDIUM-1: the unwound retry left A live - PART 3 would no longer be the first cutover';
  assert not exists (select 1 from public.sv_cutover_events where business_id = A),
    'v69 MEDIUM-1: the unwound retry left a cutover event behind';

  raise notice 'v69 PART 2 (refusal matrix + preview<->act agreement, incl. rev-3 sv_designation_revoked): PASS';

  -- =======================================================================================
  -- PART 3 - THE CUTOVER
  -- =======================================================================================
  v_prev := public.preview_sv_cutover(A);
  assert (v_prev->>'ready')::boolean is true, 'v69: the preview is not ready at the cutover moment';
  assert jsonb_array_length(v_prev->'blocking_codes') = 0, 'v69: ready with blocking codes';
  assert (v_prev->>'designated')::boolean is true, 'v69: the preview does not report the designation';
  assert (v_prev->>'reversible')::boolean is false, 'v69: the preview claims cutover is reversible';
  v_hash := v_prev->>'evidence_hash';
  v_key := gen_random_uuid();
  v_res := public.sv_cutover_business(A, 'v69 rehearsal pilot go-live for business A', v_hash, v_key);
  assert (v_res->>'status') = 'ok' and (v_res->>'prior_state') = 'shadow_testing'
     and (v_res->>'new_state') = 'live' and (v_res->>'reversible')::boolean is false
     and (v_res->>'emergency_control') = 'sv_pause',
    'v69: the cutover result is not the expected shape: ' || v_res::text;
  assert (select state from public.sv_authority where business_id = A and asset = 'stored_value') = 'live',
    'v69: the authority did not reach live';
  assert (select count(*) from public.sv_cutover_events where business_id = A) = 1,
    'v69: exactly one cutover event expected';
  assert (select count(*) from public.sv_operations
           where business_id = A and operation_type = 'cutover') = 1,
    'v69: exactly one cutover operation expected';
  assert (select count(*) from public.audit_log where business_id = A and action = 'SV_CUTOVER') = 1,
    'v69: exactly one SV_CUTOVER audit row expected';
  select * into v_row from public.sv_cutover_events where business_id = A;
  assert v_row.actor = A_owner and v_row.designated_by = B_owner_sa and v_row.prior_state = 'shadow_testing'
     and v_row.evidence_hash = v_hash and v_row.reason = 'v69 rehearsal pilot go-live for business A',
    'v69: the cutover event did not record actor / designator / prior state / evidence / reason';
  -- the whole rest of the platform is untouched: B is still unbuilt
  assert (pg_temp.v69_census() ->> B::text) = 'unbuilt',
    'v69: cutting over A also moved B - the cutover is not per-business (census ' || pg_temp.v69_census()::text || ')';
  assert (select count(*) from jsonb_each_text(pg_temp.v69_census()) v where v.value = 'live') = 1,
    'v69: more than one business went live: ' || pg_temp.v69_census()::text;
  assert (pg_temp.v69_census() ->> A::text) = 'live', 'v69: the census disagrees that A is live';

  ---------------------------------------------------------------- idempotent replay
  v_res2 := public.sv_cutover_business(A, 'v69 rehearsal pilot go-live for business A', v_hash, v_key);
  assert v_res2 = v_res, 'v69: the same-key replay did not return the cached result byte-equal';
  assert (select count(*) from public.sv_cutover_events where business_id = A) = 1,
    'v69: the replay wrote a second cutover event';
  assert (select count(*) from public.audit_log where business_id = A and action = 'SV_CUTOVER') = 1,
    'v69: the replay wrote a second audit row';

  ---------------------------------------------------------------- changed request, same key
  begin
    perform public.sv_cutover_business(A, 'a different reason under the same key', v_hash, v_key);
    raise exception 'v69: a changed request replayed under the same key';
  exception when sqlstate '22023' then
    assert position('conflicts with a different stored-value cutover' in sqlerrm) > 0,
      'v69: wrong same-key conflict error: ' || sqlerrm; end;

  ---------------------------------------------------------------- a second cutover under a NEW key
  perform pg_temp.v69_expect_blocked(A, 'sv_already_live', 'already live');
  assert (select count(*) from public.sv_cutover_events where business_id = A) = 1,
    'v69: a second cutover attempt wrote an event';

  ---------------------------------------------------------------- live is NOT reversible by RPC
  begin
    perform public.set_sv_authority_state(A, 'stored_value', 'shadow_testing', 'v69 tries to undo the cutover');
    raise exception 'v69: a live business was downgraded by the ordinary RPC';
  exception when sqlstate '22023' then
    assert position('sv_live_not_reversible' in sqlerrm) > 0 or position('cutover states are unreachable' in sqlerrm) > 0,
      'v69: wrong live-downgrade error: ' || sqlerrm; end;
  assert (select state from public.sv_authority where business_id = A and asset = 'stored_value') = 'live',
    'v69: the refused downgrade still moved the state';
  -- ...but the emergency control still works on a live business (contract §5)
  perform public.sv_pause(A, 'stored_value', 'all', 'v69 proves pause works on a live business');
  assert (select count(*) from public.sv_pauses
           where business_id = A and scope = 'all' and lifted_at is null) = 1,
    'v69: pause did not take on a live business';
  perform public.sv_lift_pause(A, 'stored_value', 'all', 'v69 lifts the live-business pause');
  assert (select state from public.sv_authority where business_id = A and asset = 'stored_value') = 'live',
    'v69: pausing/lifting changed the authority state';

  ---------------------------------------------------------------- rev-2 D1: ONE live business platform-wide
  -- With A already live, no OTHER business can be cut over. The SA (B_owner_sa) hands the pilot slot
  -- to B (revoke A, designate B - which also proves the slot is reusable once freed); B enters
  -- shadow_testing and reconciles CLEAN, so it is otherwise fully ready - yet its readiness is blocked
  -- by sv_pilot_already_live and sv_cutover_business raises exactly that typed error. Exactly one
  -- business stays live platform-wide. (The direct-UPDATE unique-index backstop is proven in the
  -- rehearsal D1 proof and db/tests/v69_cutover_concurrency.sh Round A2, where the guard can be
  -- cleanly suspended in a rolled-back probe.)
  perform pg_temp.as_v69(B_owner_sa, 'authenticated');
  perform public.set_sv_cutover_designation(A, false, 'v69 D1 releases A''s pilot slot to probe the one-live bound');
  v_res := public.set_sv_cutover_designation(B, true, 'v69 D1 designates B to probe the one-live bound');
  assert (v_res->>'designated')::boolean is true and (v_res->>'unchanged')::boolean is false,
    'v69 D1: designating B failed after A''s slot was released (the singleton slot is not reusable)';
  perform public.set_sv_authority_state(B, 'stored_value', 'shadow_testing', 'v69 D1 puts B in shadow testing');
  v_res := public.run_sv_reconciliation(B);
  assert (v_res->>'reconciliation_status') = 'clean',
    'v69 D1: B (a fresh tenant with no gift cards) did not reconcile clean: ' || v_res::text;
  v_prev := public.preview_sv_cutover(B);
  assert (v_prev->>'ready')::boolean is false, 'v69 D1: B previewed ready while A is live platform-wide';
  assert (pg_temp.v69_ready(B)->>'pilot_already_live')::boolean is true,
    'v69 D1: the readiness oracle does not surface pilot_already_live=true';
  assert (v_prev->'blocking_codes'->>0) = 'sv_pilot_already_live',
    'v69 D1: B''s first blocking code is not sv_pilot_already_live (codes '
      || (v_prev->'blocking_codes')::text || ', reasons ' || (v_prev->'blocking_reasons')::text || ')';
  v_key := gen_random_uuid();
  begin
    perform public.sv_cutover_business(B, 'v69 D1: B attempts go-live while A is already live', v_prev->>'evidence_hash', v_key);
    raise exception 'v69 D1: B was cut over while A is already live platform-wide';
  exception when sqlstate '22023' then
    assert position('sv_pilot_already_live' in sqlerrm) > 0,
      'v69 D1: B''s cutover raised the wrong error (expected sv_pilot_already_live): ' || sqlerrm;
  end;
  assert not exists (select 1 from public.sv_operations
                      where business_id = B and operation_type = 'cutover' and idempotency_key = v_key),
    'v69 D1: a sv_pilot_already_live refusal reserved B''s idempotency key';
  assert (select count(*) from jsonb_each_text(pg_temp.v69_census()) v where v.value = 'live') = 1,
    'v69 D1: more than one business is live platform-wide: ' || pg_temp.v69_census()::text;
  assert (pg_temp.v69_census() ->> B::text) <> 'live', 'v69 D1: B became live';
  perform pg_temp.as_v69(A_owner, 'authenticated');   -- restore A's owner for PART 4 (D1 probe used B's SA)
  raise notice 'v69 PART 3 (the cutover, replay, conflict, irreversibility, one-live-platform-wide): PASS';

  -- =======================================================================================
  -- PART 4 - LIVE BEHAVIOUR ON A GENUINELY LIVE BUSINESS (no shim anywhere below this line)
  -- =======================================================================================
  ---------------------------------------------------------------- v66 mint tripwire still holds
  -- (pg_temp is excluded: this suite's OWN v69_seed helper writes explicit-expiry lots for PS-0
  --  cases (f) and (h), and a rolled-back test fixture is not a shipped mint path.)
  assert not exists (
    select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname not like 'pg_temp%'
       and p.prosrc ilike '%insert into public.sv_lots%' and p.prosrc ilike '%''paid''%'
       and p.proname <> 'record_sv_topup_sale'),
    'v69: a non-authoritative function can mint a paid lot';

  ---------------------------------------------------------------- mint + spend through the live path
  v_ver := pg_temp.v69_plan(A, jsonb_build_object(
    'customer_facing_name', 'V69 live 5000', 'price_cents', 5000, 'bonus_cents', 0, 'customer_terms', '1y'));
  v_res := public.record_sv_topup_sale(A, v_branch, v_client, v_ver,
    jsonb_build_object('method', 'cash', 'amount_cents', 5000, 'currency', 'SGD'), gen_random_uuid());
  v_acct := (v_res->>'account_id')::uuid;
  assert pg_temp.v69_out(A, v_acct) = 5000, 'v69 live: the mint did not create 5000 of outstanding value';
  v_res := public.sv_spend(A, v_acct, 1000, gen_random_uuid());
  assert pg_temp.v69_out(A, v_acct) = 4000, 'v69 live: the spend did not reduce the balance';

  ---------------------------------------------------------------- v67 tender reserve -> finalise
  v_tok := (public.evaluate_checkout(A, v_branch, v_client,
    jsonb_build_array(jsonb_build_object('catalog_kind', 'service', 'catalog_id', v_svc, 'qty', 1)),
    gen_random_uuid())->>'evaluation_id')::uuid;
  perform public.reserve_checkout_sv_tender(A, v_tok, 4000, gen_random_uuid());
  assert pg_temp.v69_out(A, v_acct) = 4000, 'v69 live: a reservation must not move value';
  perform public.record_cart_sale(A, v_client, v_branch, null, 'cash',
    'v69-' || substr(md5(random()::text), 1, 12), null, v_tok, true);
  assert pg_temp.v69_out(A, v_acct) = 0, 'v69 live: the tender settlement did not spend the balance';
  select spend_operation_id into v_spend_op from public.checkout_sv_tenders
   where business_id = A and account_id = v_acct and status = 'consumed';
  assert v_spend_op is not null, 'v69 live: the tender did not record a settlement spend';

  ---------------------------------------------------------------- v68b settlement reversal (lifted)
  v_res := public.sv_reverse_spend(A, v_spend_op, gen_random_uuid());
  assert (v_res->>'status') = 'ok', 'v69 live: the settlement reversal was refused';
  assert pg_temp.v69_out(A, v_acct) = 4000, 'v69 live: the reversal did not restore the value exactly once';

  ---------------------------------------------------------------- pause really stops spending when live
  perform public.sv_pause(A, 'stored_value', 'redeem', 'v69 proves the kill switch bites when live');
  begin
    perform public.sv_spend(A, v_acct, 100, gen_random_uuid());
    raise exception 'v69 live: a redeem pause did not stop spending on a live business';
  exception when sqlstate '22023' then
    assert position('sv_paused' in sqlerrm) > 0, 'v69 live: wrong pause error: ' || sqlerrm; end;
  perform public.sv_lift_pause(A, 'stored_value', 'redeem', 'v69 lifts the kill switch');
  perform public.sv_spend(A, v_acct, 100, gen_random_uuid());
  assert pg_temp.v69_out(A, v_acct) = 3900, 'v69 live: spending did not resume after the lift';

  ---------------------------------------------------------------- the scheduled drivers actually work
  perform pg_temp.as_v69(A_owner, 'authenticated');
  assert pg_temp.v69_autoctx() is false,
    'v69 automation: the automation context is true outside a driver';
  begin
    insert into public.sv_automation_runs(job_name, run_txid) values ('sv_expiry_sweep', 1);
    raise exception 'v69 automation: a browser role forged an automation marker';
  exception when sqlstate '42501' then null; end;

  reset role;
  select count(*) into v_before from public.sv_automation_runs;
  v_n := app.run_sv_expiry_sweep(1000);
  assert v_n = 1, 'v69 automation: the expiry sweep did not visit the single live business (visited ' || v_n || ')';
  v_n := app.run_sv_tender_release(1000);
  v_n := app.run_sv_reconciliation_sweep();
  assert v_n >= 1, 'v69 automation: the reconciliation sweep visited no business';
  select count(*) into v_after from public.sv_automation_runs;
  assert v_after = v_before + 3, 'v69 automation: the three drivers did not each open a marker row';
  assert not exists (select 1 from public.sv_automation_runs where finished_at is null),
    'v69 automation: a driver left its marker row unfinished';
  assert not exists (select 1 from public.audit_log where action = 'SV_AUTOMATION_ERROR'),
    'v69 automation: a driver recorded a per-business failure: '
    || coalesce((select detail::text from public.audit_log where action = 'SV_AUTOMATION_ERROR' limit 1), '');
  -- the marker table is append-only and write-once
  select id into v_marker from public.sv_automation_runs order by started_at desc limit 1;
  begin delete from public.sv_automation_runs where id = v_marker;
    raise exception 'v69 automation: the marker table is deletable';
  exception when others then
    assert position('append-only' in sqlerrm) > 0, 'v69 automation: wrong delete refusal'; end;
  begin update public.sv_automation_runs set summary = '{"tamper":true}'::jsonb where id = v_marker;
    raise exception 'v69 automation: a finished marker row was rewritten';
  exception when others then
    assert position('write-once' in sqlerrm) > 0, 'v69 automation: wrong rewrite refusal'; end;

  ---------------------------------------------------------------- THE DEFECT v69 CLOSES:
  -- a scheduled reconciliation must NEVER downgrade a LIVE tenant out of 'live'
  reset role;
  select count(*) into v_before from public.sv_reconciliation_snapshots
   where business_id = A and status = 'blocked';
  insert into public.gift_cards(business_id, code, initial_cents, balance_cents, status)
  values (A, 'V69LIVE' || substr(md5(random()::text), 1, 6), 2500, 2500, 'active') returning id into v_gc;
  v_n := app.run_sv_reconciliation_sweep();
  assert (select state from public.sv_authority where business_id = A and asset = 'stored_value') = 'live',
    'v69: the scheduled reconciliation DOWNGRADED a live tenant and stranded its customers'' value';
  select count(*) into v_after from public.sv_reconciliation_snapshots
   where business_id = A and status = 'blocked';
  assert v_after = v_before + 1,
    'v69: the discrepancy was not recorded on the live tenant (it must be recorded, just not acted on)';
  -- and the same discrepancy on a NON-live tenant still blocks, exactly as before
  perform pg_temp.as_v69(B_owner_sa, 'authenticated');
  perform public.set_sv_authority_state(B, 'stored_value', 'shadow_testing', 'v69 control tenant');
  reset role;
  insert into public.gift_cards(business_id, code, initial_cents, balance_cents, status)
  values (B, 'V69CTL' || substr(md5(random()::text), 1, 7), 100, 100, 'active');
  v_n := app.run_sv_reconciliation_sweep();
  assert (select state from public.sv_authority where business_id = B and asset = 'stored_value')
         = 'reconciliation_blocked',
    'v69: a NON-live tenant with discrepancies is no longer driven to reconciliation_blocked';
  reset role;
  update public.gift_cards set balance_cents = 0, status = 'redeemed' where business_id in (A, B);
  raise notice 'v69 PART 4 (live behaviour + working automation + no live downgrade): PASS';

  -- =======================================================================================
  -- PART 5 - THE PS-0 LETTERED-CASE ORACLE, ON THE GENUINELY LIVE BUSINESS
  --   Every number below is quoted from docs/design/ps0/STORED_VALUE_CONTRACT.md §9.
  -- =======================================================================================
  perform pg_temp.as_v69(A_owner, 'authenticated');

  ---------------------------------------------------------------- (a) $10.00/$1.37, ten $1 refunds
  v_ver := pg_temp.v69_plan(A, jsonb_build_object(
    'customer_facing_name', 'V69 case a', 'price_cents', 1000, 'bonus_cents', 137, 'customer_terms', '1y'));
  v_res := public.record_sv_topup_sale(A, v_branch, v_client2, v_ver,
    jsonb_build_object('method', 'cash', 'amount_cents', 1000, 'currency', 'SGD'), gen_random_uuid());
  v_op := (v_res->>'operation_id')::uuid;
  v_acct := (v_res->>'account_id')::uuid;
  v_cash_total := 0; v_claw_total := 0;
  for i in 1..10 loop
    v_res2 := public.refund_sv_operation(A, v_op, 100, gen_random_uuid());
    v_cash_total := v_cash_total + (v_res2->>'cash_cents')::int;
    v_claw_total := v_claw_total + (v_res2->>'clawback_cents')::int;
  end loop;
  assert v_cash_total = 1000, 'PS-0 (a) on live: cash total must be 1000, got ' || v_cash_total;
  assert v_claw_total = 137, 'PS-0 (a) on live: clawback total must be 137, got ' || v_claw_total;
  assert pg_temp.v69_out(A, v_acct) = 0, 'PS-0 (a) on live: the account must close at {0,0} with no stranded cent';

  ---------------------------------------------------------------- (c) two same-key whole refunds
  v_ver := pg_temp.v69_plan(A, jsonb_build_object(
    'customer_facing_name', 'V69 case c', 'price_cents', 10000, 'bonus_cents', 0, 'customer_terms', '1y'));
  v_res := public.record_sv_topup_sale(A, v_branch, v_client3, v_ver,
    jsonb_build_object('method', 'cash', 'amount_cents', 10000, 'currency', 'SGD'), gen_random_uuid());
  v_op := (v_res->>'operation_id')::uuid;
  v_acct := (v_res->>'account_id')::uuid;
  perform public.sv_spend(A, v_acct, 2000, gen_random_uuid());     -- leaves 8000 -> the $80.00 payout
  v_key := gen_random_uuid();
  v_res := public.refund_sv_operation(A, v_op, 8000, v_key);
  select count(*) into v_before from public.sv_lot_movements where business_id = A;
  v_res2 := public.refund_sv_operation(A, v_op, 8000, v_key);
  select count(*) into v_after from public.sv_lot_movements where business_id = A;
  assert (v_res->>'cash_cents')::int = 8000, 'PS-0 (c) on live: the payout must be 8000';
  assert v_res2 = v_res, 'PS-0 (c) on live: the same-key replay is not byte-equal';
  assert v_after = v_before, 'PS-0 (c) on live: the replay wrote a second movement set';

  ---------------------------------------------------------------- (d) lost response + retry
  v_ver := pg_temp.v69_plan(A, jsonb_build_object(
    'customer_facing_name', 'V69 case d', 'price_cents', 10000, 'bonus_cents', 0, 'customer_terms', '1y'));
  v_res := public.record_sv_topup_sale(A, v_branch, v_client4, v_ver,
    jsonb_build_object('method', 'cash', 'amount_cents', 10000, 'currency', 'SGD'), gen_random_uuid());
  v_op := (v_res->>'operation_id')::uuid;
  v_acct := (v_res->>'account_id')::uuid;
  v_key := gen_random_uuid();
  perform public.refund_sv_operation(A, v_op, 3000, v_key);        -- the "lost response"
  select count(*) into v_before from public.sv_lot_movements where business_id = A;
  perform public.refund_sv_operation(A, v_op, 3000, v_key);        -- the retry
  select count(*) into v_after from public.sv_lot_movements where business_id = A;
  assert v_after = v_before, 'PS-0 (d) on live: the retry wrote new movements';
  assert pg_temp.v69_out(A, v_acct) = 7000, 'PS-0 (d) on live: paid remaining must be 7000';

  ---------------------------------------------------------------- (e) chargeback + bad debt
  v_ver := pg_temp.v69_plan(A, jsonb_build_object(
    'customer_facing_name', 'V69 case e', 'price_cents', 10000, 'bonus_cents', 1200, 'customer_terms', '1y'));
  v_res := public.record_sv_topup_sale(A, v_branch, v_client5, v_ver,
    jsonb_build_object('method', 'cash', 'amount_cents', 10000, 'currency', 'SGD'), gen_random_uuid());
  v_op := (v_res->>'operation_id')::uuid;
  v_acct := (v_res->>'account_id')::uuid;
  perform public.sv_spend(A, v_acct, 8000, gen_random_uuid());
  v_res := public.sv_chargeback_topup(A, v_op, 'PS-0 case (e) on a genuinely live business', gen_random_uuid());
  assert (v_res->>'void_paid_cents')::int = 2857,
    'PS-0 (e) on live: void_paid must be 2857, got ' || (v_res->>'void_paid_cents');
  assert (v_res->>'void_bonus_cents')::int = 343,
    'PS-0 (e) on live: void_bonus must be 343, got ' || (v_res->>'void_bonus_cents');
  assert (v_res->>'bad_debt_cents')::int = 7143,
    'PS-0 (e) on live: bad debt must be 7143, got ' || (v_res->>'bad_debt_cents');
  assert pg_temp.v69_out(A, v_acct) = 0, 'PS-0 (e) on live: remaining must reach 0';

  ---------------------------------------------------------------- (f) expired bonus then reversal
  -- needs a PAST-expiry bonus lot, which the mint path cannot create -> seeded directly
  reset role;
  v_seed := pg_temp.v69_seed(A, v_client6, 10000, now() + interval '365 days', 1200, now() - interval '1 day');
  perform pg_temp.as_v69(A_owner, 'authenticated');
  v_acct := (v_seed->>'account')::uuid;
  v_paid_lot := (v_seed->>'paid_lot')::uuid;
  v_bonus_lot := (v_seed->>'bonus_lot')::uuid;
  v_res := public.sv_spend(A, v_acct, 1200, gen_random_uuid());
  v_spend_op := (v_res->>'operation_id')::uuid;
  perform public.sv_expire_due(A, 1000);
  perform public.sv_reverse_spend(A, v_spend_op, gen_random_uuid());
  perform public.sv_expire_due(A, 1000);
  -- Asserted twice, exactly as the v68a suite pins it: as a canonically-ordered MULTISET (every row
  -- in this suite shares one transaction timestamp, so created_at cannot order them), and in
  -- physical append order via ctid, which additionally proves the restore-then-expire SEQUENCE.
  select string_agg(m.kind || ':' || m.cents::text, ',' order by m.cents, m.kind) into v_trail
    from public.sv_lot_movements m where m.lot_id = v_bonus_lot;
  assert v_trail = 'expiry:-1072,expiry:-128,spend:-128,reversal:128,issue:1200',
    'PS-0 (f) on live: the bonus trail multiset must be {issue+1200,spend-128,expiry-1072,reversal+128,expiry-128}; got ' || v_trail;
  select string_agg(m.kind || ' ' || m.cents, ', ' order by m.ctid) into v_trail
    from public.sv_lot_movements m where m.lot_id = v_bonus_lot;
  assert v_trail = 'issue 1200, spend -128, expiry -1072, reversal 128, expiry -128',
    'PS-0 (f) on live: the bonus trail order must be exact; got ' || v_trail;
  assert (select coalesce(sum(m.cents), 0) from public.sv_lot_movements m where m.lot_id = v_bonus_lot) = 0,
    'PS-0 (f) on live: the bonus trail must sum to 0';
  assert pg_temp.v69_rem(v_bonus_lot) = 0, 'PS-0 (f) on live: the bonus lot must end at 0';
  assert pg_temp.v69_rem(v_paid_lot) = 10000, 'PS-0 (f) on live: the paid lot must be fully restored to 10000';

  ---------------------------------------------------------------- (g) two-op FEFO refunds
  select id into v_client from public.clients where business_id = A and full_name = 'v69 g';
  v_ver  := pg_temp.v69_plan(A, jsonb_build_object(
    'customer_facing_name', 'V69 case g A', 'price_cents', 10000, 'bonus_cents', 1200, 'customer_terms', '1y'));
  v_ver2 := pg_temp.v69_plan(A, jsonb_build_object(
    'customer_facing_name', 'V69 case g B', 'price_cents', 20000, 'bonus_cents', 5000, 'customer_terms', '1y'));
  v_res := public.record_sv_topup_sale(A, v_branch, v_client, v_ver,
    jsonb_build_object('method', 'cash', 'amount_cents', 10000, 'currency', 'SGD'), gen_random_uuid());
  v_opA := (v_res->>'operation_id')::uuid;
  v_acct := (v_res->>'account_id')::uuid;
  v_res := public.record_sv_topup_sale(A, v_branch, v_client, v_ver2,
    jsonb_build_object('method', 'cash', 'amount_cents', 20000, 'currency', 'SGD'), gen_random_uuid());
  v_opB := (v_res->>'operation_id')::uuid;
  perform public.sv_spend(A, v_acct, 5000, gen_random_uuid());
  v_res  := public.refund_sv_operation(A, v_opA, 5856, gen_random_uuid());
  v_res2 := public.refund_sv_operation(A, v_opB, 20000, gen_random_uuid());
  assert (v_res->>'cash_cents')::int = 5856 and (v_res->>'clawback_cents')::int = 344,
    'PS-0 (g) on live: refund A must be 5856 cash / 344 clawback, got '
    || (v_res->>'cash_cents') || '/' || (v_res->>'clawback_cents');
  assert (v_res2->>'cash_cents')::int = 20000 and (v_res2->>'clawback_cents')::int = 5000,
    'PS-0 (g) on live: refund B must be 20000 cash / 5000 clawback, got '
    || (v_res2->>'cash_cents') || '/' || (v_res2->>'clawback_cents');
  assert 5856 + 20000 = 25856, 'PS-0 (g) on live: conservation arithmetic';
  assert pg_temp.v69_out(A, v_acct) = 0, 'PS-0 (g) on live: both operations must close at {0,0}';

  ---------------------------------------------------------------- (g-spill) cross-op FEFO spill
  select id into v_client2 from public.clients where business_id = A and full_name = 'v69 gs';
  v_res := public.record_sv_topup_sale(A, v_branch, v_client2, v_ver,
    jsonb_build_object('method', 'cash', 'amount_cents', 10000, 'currency', 'SGD'), gen_random_uuid());
  v_opA := (v_res->>'operation_id')::uuid;
  v_acct := (v_res->>'account_id')::uuid;
  v_res := public.record_sv_topup_sale(A, v_branch, v_client2, v_ver2,
    jsonb_build_object('method', 'cash', 'amount_cents', 20000, 'currency', 'SGD'), gen_random_uuid());
  v_opB := (v_res->>'operation_id')::uuid;
  perform public.sv_spend(A, v_acct, 5000, gen_random_uuid());     -- as in (g)
  perform public.sv_spend(A, v_acct, 12000, gen_random_uuid());    -- the spill
  assert pg_temp.v69_op_remaining(A, v_opA, null) = 0,
    'PS-0 (g-spill) on live: operation A must be drained, got ' || pg_temp.v69_op_remaining(A, v_opA, null);
  assert pg_temp.v69_op_remaining(A, v_opB, 'paid') = 15911,
    'PS-0 (g-spill) on live: B paid remaining must be 15911, got ' || pg_temp.v69_op_remaining(A, v_opB, 'paid');
  assert pg_temp.v69_op_remaining(A, v_opB, 'bonus') = 3289,
    'PS-0 (g-spill) on live: B bonus remaining must be 3289, got ' || pg_temp.v69_op_remaining(A, v_opB, 'bonus');
  v_res := public.refund_sv_operation(A, v_opB, 15911, gen_random_uuid());
  assert (v_res->>'cash_cents')::int = 15911 and (v_res->>'clawback_cents')::int = 3289,
    'PS-0 (g-spill) on live: refund B must be 15911 cash / 3289 clawback, got '
    || (v_res->>'cash_cents') || '/' || (v_res->>'clawback_cents');

  ---------------------------------------------------------------- (h) inverted expiry order
  -- A = paid 10000 + bonus 1200, B = paid 5000 + bonus 500, spend 5600.
  -- The BONUS order is inverted (B's bonus expires first) while the PAID order stays A-first, so
  -- the 570-cent bonus draw empties B's 500 bonus and takes 70 from A's, leaving A with 1130.
  select id into v_client3 from public.clients where business_id = A and full_name = 'v69 h';
  reset role;
  v_seedA := pg_temp.v69_seed(A, v_client3, 10000, now() + interval '100 days', 1200, now() + interval '200 days');
  v_seedB := pg_temp.v69_seed(A, v_client3,  5000, now() + interval '300 days',  500, now() + interval '100 days');
  perform pg_temp.as_v69(A_owner, 'authenticated');
  v_acct := (v_seedA->>'account')::uuid;
  v_opA := (v_seedA->>'operation')::uuid;
  v_opB := (v_seedB->>'operation')::uuid;
  perform public.sv_spend(A, v_acct, 5600, gen_random_uuid());
  assert pg_temp.v69_rem((v_seedA->>'paid_lot')::uuid) = 4970,
    'PS-0 (h) on live: A paid remaining must be 4970, got ' || pg_temp.v69_rem((v_seedA->>'paid_lot')::uuid);
  assert pg_temp.v69_rem((v_seedA->>'bonus_lot')::uuid) = 1130,
    'PS-0 (h) on live: A bonus remaining must be 1130 under the inverted order, got '
    || pg_temp.v69_rem((v_seedA->>'bonus_lot')::uuid);
  assert pg_temp.v69_rem((v_seedB->>'paid_lot')::uuid) = 5000, 'PS-0 (h) on live: B paid must be untouched';
  assert pg_temp.v69_rem((v_seedB->>'bonus_lot')::uuid) = 0, 'PS-0 (h) on live: B bonus must be emptied first';
  v_res  := public.refund_sv_operation(A, v_opA, 4970, gen_random_uuid());
  v_res2 := public.refund_sv_operation(A, v_opB, 5000, gen_random_uuid());
  assert (v_res->>'cash_cents')::int = 4970 and (v_res->>'clawback_cents')::int = 1130,
    'PS-0 (h) on live: refund A must be 4970 cash / 1130 clawback, got '
    || (v_res->>'cash_cents') || '/' || (v_res->>'clawback_cents');
  assert (v_res2->>'cash_cents')::int = 5000 and (v_res2->>'clawback_cents')::int = 0,
    'PS-0 (h) on live: refund B must be 5000 cash / 0 clawback, got '
    || (v_res2->>'cash_cents') || '/' || (v_res2->>'clawback_cents');

  ---------------------------------------------------------------- PS-0 §10 invariants, whole tenant
  assert (pg_temp.v69_invariants(A)->>'out_of_range_lots')::int = 0,
    'PS-0 §10 on live: a lot went below 0 or above its minted amount';
  assert (pg_temp.v69_invariants(A)->>'reservation_movements')::int = 0,
    'PS-0 §10 on live: a reservation wrote a stored-value movement';
  assert (pg_temp.v69_census() ->> A::text) = 'live',
    'PS-0 on live: the business stopped being live during the oracle';

  reset role;
  raise notice 'v69 PART 5 (PS-0 lettered cases a/c/d/e/f/g/g-spill/h on a GENUINELY live business): PASS';
  raise notice 'V69 SUITE PASS';
end
$v69_main$;

reset role;
rollback;
