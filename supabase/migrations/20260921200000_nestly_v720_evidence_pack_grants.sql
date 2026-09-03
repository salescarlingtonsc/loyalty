-- NESTLY v720 -- app.v176_evidence_pack: restate the revoke, add an internal auth gate
-- (defence in depth), and prove the estate has no other silently-exposed app.* function.
--
-- ===========================================================================================
-- WHAT WAS REPORTED. A refuter claimed app.v176_evidence_pack(uuid,text,date,date) carries
-- EXECUTE granted to PUBLIC (ACL `{=X/postgres,...}`), reachable by any authenticated session
-- -- a customer, another tenant's owner, an unassigned consultant -- to read any business's
-- name, revenue, growth, retention and top-customer figures.
--
-- WHAT WAS TRUE. Checked directly against production (gadpooereceldfpfxsod, read-only query,
-- 2026-09-02): app.v176_evidence_pack, app.v176_gated_evidence and app.ci_access_gate_v667 all
-- carry ACL `{postgres=X/postgres}` -- owner only. anon and authenticated cannot execute any of
-- the three. The PUBLIC grant the refuter observed exists ONLY in the local rehearsal harness
-- (scripts/db-tests/*), which restores its baseline from a `pg_dump --no-privileges` snapshot
-- (tests/fixtures/db-schema-snapshot.sql) -- every routine defined before the v422 snapshot
-- watermark, app.v176_evidence_pack included, is recreated there by a bare CREATE FUNCTION with
-- no ACL, and Postgres's own default is to grant EXECUTE to PUBLIC on creation. Nothing
-- downstream restated the revoke for THIS routine by name (v690/v713 redefine it with CREATE OR
-- REPLACE, which preserves whatever ACL is already sitting there). Fixed at the source in
-- scripts/db-tests/baseline-grants.sql (separate change, same date): the harness now revokes
-- EXECUTE on every `app` function from public/anon/authenticated after restoring the snapshot,
-- then re-grants exactly the set production actually exposes there.
--
-- SO WHY THIS MIGRATION EXISTS ANYWAY. Rehearsal-fidelity is necessary but not sufficient --
-- "no migration currently grants it" is a fact about history, not an invariant about the
-- future. This migration is belt-and-braces, in the sense the ticket asked for:
--
--   1. Restate the revoke explicitly, in the routine's own migration history, so the ACL is no
--      longer "whatever a --no-privileges snapshot happens to leave behind" for anyone reading
--      this repo's migrations as the record of intent. A no-op against the already-correct
--      production ACL; the thing that changes is the rehearsal harness, per the companion fix.
--   2. Add an INTERNAL gate inside app.v176_evidence_pack itself, so the pack cannot be misread
--      even by a caller that reaches it some way an ACL check does not cover -- a future
--      SECURITY DEFINER chain, a mis-scoped service-role RPC, a superuser session running ad
--      hoc SQL. The gate mirrors the table's own RLS policy exactly
--      (ai_firm_reports_v176_read: `app.v176_can_read_firm_report(business_id)`), plus the
--      sessionless internal drain (`app.v676_internal_drain_active()`) that
--      public.internal_claim_ai_firm_report_v176 depends on. Two authorities, one already
--      covering "super admin OR the firm's assigned consultant", the other already covering
--      "the v176_gated_evidence definer chain, and nothing else" (nestly_v676) -- this
--      migration does not invent a third rule, it only makes the pack ask the same question
--      its own storage table already asks.
--
-- THE THIRD ARM. app.has_perm(p_business,'view_finance') is included alongside the drain and
-- app.v176_can_read_firm_report: an AI firm report is a paid feature of the firm's OWN
-- dashboard, not platform-console-only, and app.has_perm is already the canonical "may this
-- account see this business's finances" authority every other financial reader in this codebase
-- defers to (reports_gift_card_liability_v49b, resolve_reporting_branch_scope_v15x, etc.) -- a
-- bespoke fourth rule for this one function was rejected in favour of reusing it. An EARLIER
-- draft of this migration reasoned the opposite way, by analogy with Customer Intelligence
-- (nestly_v667 B1: "CI is not a self-service owner module") -- that analogy does not hold here:
-- CI is gated on the 'customerintel' module ENTITLEMENT specifically, deliberately separate from
-- ordinary financial visibility, whereas the v176 evidence pack IS ordinary financial reporting
-- (revenue, growth, retention) assembled with an LLM narrative on top, and db/tests/executed/
-- v723_corpus_reader_contracts.sql -- which calls all 27 CI/reporting readers uniformly to prove
-- their contracts -- already needed to fall back from the fixture's ordinary entitled owner to a
-- super-admin session specifically for this one function, which is what surfaced the gap.
--
-- ESTATE SCAN. db/tests/executed/v720_corpus_evidence_pack_grants.sql:
--   (a) calls app.v176_evidence_pack under eight identities -- cross-tenant owner, unassigned
--       consultant, customer, anon (all refused, 42501); the firm's own owner (has view_finance,
--       nestly_v720's third arm), assigned consultant, SA-with-Google, sessionless drain (all
--       allowed) -- proving the ACL and the new three-armed internal gate agree with each other
--       and with the table's RLS policy;
--   (b) queries pg_proc/aclexplode for every function in schema `app` with EXECUTE granted to
--       PUBLIC/anon/authenticated and asserts the set equals an explicit, justified allowlist,
--       so a function that starts being exposed tomorrow fails the suite by name, not by luck.
--
-- ROLLBACK: `grant execute on function app.v176_evidence_pack(uuid,text,date,date) to public;`
-- restores the accidental-grant shape (do not do this); to remove only the internal gate added
-- here, re-run this migration's anchored replace in reverse (swap v_new_gate/v_old_gate below)
-- or restore the v713 body of app.v176_evidence_pack verbatim (reproduced in that migration).
-- ===========================================================================================

begin;

-- ---------------------------------------------------------------------------
-- 1 * Restate the revoke. Idempotent: REVOKE of a privilege that is already absent is a no-op.
--     service_role is included -- the original nestly_v179 body already revoked it ("from
--     public, anon, authenticated, service_role"), matching this migration. It costs
--     service_role nothing: the only production caller reaches this function through
--     public.internal_claim_ai_firm_report_v176, a SECURITY DEFINER routine owned by postgres,
--     and an owner's own routine is always callable by the owner regardless of ACL.
-- ---------------------------------------------------------------------------
revoke execute on function app.v176_evidence_pack(uuid, text, date, date)
  from public, anon, authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 2 * The internal gate, added by anchored replace so the ~90 lines of evidence assembly
--     around it are never retyped. Captured, patched, and proved equal to the intended diff.
-- ---------------------------------------------------------------------------
do $v720_capture$
declare
  v_def text;
begin
  select pg_get_functiondef(to_regprocedure('app.v176_evidence_pack(uuid,text,date,date)'))
    into v_def;
  if v_def is null then
    raise exception 'v720: app.v176_evidence_pack(uuid,text,date,date) is missing';
  end if;
  if position('ai_firm_evidence_pack_requires_platform_or_consultant_access' in v_def) > 0 then
    raise exception 'v720: the internal gate is already present -- re-read before shipping';
  end if;
  create temp table _v720_before(def text) on commit drop;
  insert into _v720_before(def) values (v_def);
end
$v720_capture$;

do $v720_patch$
declare
  v_before text;
  v_after  text;
  v_count  integer;
  v_old_anchor constant text := $oldg$  if not found then
    raise exception 'business_not_found' using errcode = '22023';
  end if;

  v_current := app.v176_sales_window(p_business, p_period_start, p_period_end);
$oldg$;
  v_new_anchor constant text := $newg$  if not found then
    raise exception 'business_not_found' using errcode = '22023';
  end if;

  /* NESTLY v720 (defence in depth): the ACL is the primary boundary -- this function has never
     been callable by anon/authenticated in production (verified 2026-09-02) and step 1 of this
     migration restates that revoke explicitly. This second, internal check means the pack
     cannot be misread even by a caller that reaches it some other way (a future SECURITY
     DEFINER chain, a mis-scoped service-role RPC, a superuser session running ad hoc SQL): it
     must still be one of three things -- the sessionless internal drain
     (app.v676_internal_drain_active(), nestly_v676), a reader app.v176_can_read_firm_report
     already approves for this business (super admin or the assigned consultant -- the exact
     predicate behind the table's own RLS policy, ai_firm_reports_v176_read), or the firm's own
     owner/finance-permitted staff (app.has_perm(p_business,'view_finance')) -- an AI firm report
     is a paid feature of the firm's own dashboard, not platform-console-only, and app.has_perm
     already IS the canonical "may this account see this business's finances" authority every
     other financial reader in this codebase defers to; a fourth, bespoke rule was rejected in
     favour of reusing it. */
  if not (
    app.v676_internal_drain_active()
    or app.v176_can_read_firm_report(p_business)
    or app.has_perm(p_business, 'view_finance')
  ) then
    raise exception 'ai_firm_evidence_pack_requires_platform_consultant_or_finance_access'
      using errcode = '42501';
  end if;

  v_current := app.v176_sales_window(p_business, p_period_start, p_period_end);
$newg$;
begin
  select def into v_before from _v720_before;

  v_count := (length(v_before) - length(replace(v_before, v_old_anchor, '')))
    / greatest(length(v_old_anchor), 1);
  if v_count <> 1 then
    raise exception
      'v720: the not-found/v_current anchor occurs % times in app.v176_evidence_pack (expected 1)',
      v_count;
  end if;

  execute replace(v_before, v_old_anchor, v_new_anchor);

  select pg_get_functiondef(to_regprocedure('app.v176_evidence_pack(uuid,text,date,date)'))
    into v_after;
  if v_after <> replace(v_before, v_old_anchor, v_new_anchor) then
    raise exception
      'v720: app.v176_evidence_pack changed by more than the internal-gate insertion'
      using detail = 'intended:' || E'\n' || replace(v_before, v_old_anchor, v_new_anchor)
                  || E'\n' || 'actual:' || E'\n' || v_after;
  end if;
end
$v720_patch$;

-- Live surface restated verbatim -- CREATE OR REPLACE above preserves it, this just says so.
revoke execute on function app.v176_evidence_pack(uuid, text, date, date)
  from public, anon, authenticated, service_role;

comment on function app.v176_evidence_pack(uuid, text, date, date) is
  'nestly_v176/v179/v690/v713/v720: assembles the AI firm-report evidence pack. Owner-only ACL '
  '(no anon/authenticated/public EXECUTE, restated by nestly_v720) plus an internal gate '
  '(nestly_v720): callable only by the sessionless internal drain, a reader '
  'app.v176_can_read_firm_report already approves (super admin / assigned consultant), or the '
  'firm''s own view_finance-permitted staff (app.has_perm(business,''view_finance'')).';

-- ---------------------------------------------------------------------------
-- 2b * Thread the internal-drain token through the ONE real production caller.
--
--     app.v176_gated_evidence already opens app.v676_internal_drain_active()'s window itself
--     when it sees auth.uid() IS NULL (nestly_v676) -- but that only covers ITS OWN body. The
--     new gate added in step 2 above runs at the TOP of app.v176_evidence_pack, BEFORE
--     v176_gated_evidence is ever called, so for the real sessionless worker
--     (public.internal_claim_ai_firm_report_v176, service_role, no JWT at all) the drain is not
--     yet open at the moment the new gate checks it -- app.v676_internal_drain_active() would
--     read false and a legitimate call would be refused. Deliberately NOT fixed by having
--     app.v176_evidence_pack open the drain for itself on nothing more than "auth.uid() is
--     null": that predicate is also true of an unauthenticated anon caller, which is exactly
--     the "a flag is a password everyone knows" shape nestly_v676's own header rejected --
--     auth.uid() IS NULL is free for anyone to arrange, drain-open must not be.
--
--     Fix: the CALLER opens the window, exactly as app.v176_gated_evidence already does for
--     its own nested calls, and exactly as this repo's OWN test fixtures already do
--     (db/tests/executed/v713_corpus_evidence_pack.sql F6, this migration's own verify block
--     below) when simulating the sessionless path directly. public.internal_claim_ai_firm_
--     report_v176 is itself a SECURITY DEFINER function owned by postgres -- the same owner as
--     app.v676_open_internal_drain() -- so it already has the standing (by Postgres's ordinary
--     ownership-bypass rule, not by any new grant) to open and close the window; this patch
--     only makes it do so around the one call that needs it.
-- ---------------------------------------------------------------------------
do $v720_worker_capture$
declare
  v_def text;
begin
  select pg_get_functiondef(to_regprocedure('public.internal_claim_ai_firm_report_v176()'))
    into v_def;
  if v_def is null then
    raise exception 'v720: public.internal_claim_ai_firm_report_v176() is missing';
  end if;
  if position('v676_open_internal_drain' in v_def) > 0 then
    raise exception 'v720: the worker already threads the internal drain -- re-read before shipping';
  end if;
  create temp table _v720_worker_before(def text) on commit drop;
  insert into _v720_worker_before(def) values (v_def);
end
$v720_worker_capture$;

do $v720_worker_patch$
declare
  v_before text;
  v_after  text;
  v_count  integer;
  v_old_anchor constant text := $oldw$  v_evidence := app.v176_evidence_pack(
    v_row.business_id, v_row.period_kind, v_row.period_start, v_row.period_end
  );
$oldw$;
  v_new_anchor constant text := $neww$  /* NESTLY v720: this is the ONE real production caller of app.v176_evidence_pack with no JWT
     at all (a background worker, service_role, auth.uid() IS NULL throughout). v720's new
     internal gate inside app.v176_evidence_pack requires the drain to be OPEN at entry, so this
     function -- itself SECURITY DEFINER, owned by the same postgres owner -- opens the window
     for the one call that needs it, exactly as app.v176_gated_evidence already does for its own
     nested calls (nestly_v676). Closed in the same statement group regardless of outcome, via
     the surrounding EXCEPTION-free straight-line path -- if app.v176_evidence_pack raises, this
     function has no handler either, so the whole transaction/statement aborts and the
     transaction-local GUC is discarded either way; there is no path that leaves it open. */
  perform app.v676_open_internal_drain();
  v_evidence := app.v176_evidence_pack(
    v_row.business_id, v_row.period_kind, v_row.period_start, v_row.period_end
  );
  perform app.v676_close_internal_drain();
$neww$;
begin
  select def into v_before from _v720_worker_before;

  v_count := (length(v_before) - length(replace(v_before, v_old_anchor, '')))
    / greatest(length(v_old_anchor), 1);
  if v_count <> 1 then
    raise exception
      'v720: the v176_evidence_pack call anchor occurs % times in internal_claim_ai_firm_report_v176 (expected 1)',
      v_count;
  end if;

  execute replace(v_before, v_old_anchor, v_new_anchor);

  select pg_get_functiondef(to_regprocedure('public.internal_claim_ai_firm_report_v176()'))
    into v_after;
  if v_after <> replace(v_before, v_old_anchor, v_new_anchor) then
    raise exception
      'v720: internal_claim_ai_firm_report_v176 changed by more than the drain-threading insertion'
      using detail = 'intended:' || E'\n' || replace(v_before, v_old_anchor, v_new_anchor)
                  || E'\n' || 'actual:' || E'\n' || v_after;
  end if;
end
$v720_worker_patch$;

-- Live surface restated verbatim.
revoke all privileges on function public.internal_claim_ai_firm_report_v176()
  from public, anon, authenticated, service_role;
grant execute on function public.internal_claim_ai_firm_report_v176()
  to service_role;

-- ---------------------------------------------------------------------------
-- 3 * Verification. The claims above, executed rather than asserted.
-- ---------------------------------------------------------------------------
savepoint v720_verify;

do $v720_verify$
declare
  r_role text;
  v_fake_biz constant uuid := '00000000-0000-4000-8000-0000000720aa';
  v_real_biz uuid;
  v_ok boolean;
  v_pack jsonb;
begin
  -- 3.1 * No non-owner role may execute the pack directly.
  foreach r_role in array array['anon','authenticated','service_role'] loop
    if pg_catalog.has_function_privilege(
      r_role, 'app.v176_evidence_pack(uuid,text,date,date)', 'execute'
    ) then
      raise exception 'v720: role % can execute app.v176_evidence_pack directly', r_role;
    end if;
  end loop;

  -- A real, non-demo business is required for 3.2/3.3: the business_not_found check in the
  -- function precedes the new internal gate, so a fake id would prove nothing about the gate.
  select business.id into v_real_biz
  from public.businesses business
  where business.is_demo = false and business.is_synthetic = false
  order by business.created_at
  limit 1;

  if v_real_biz is not null then
    -- 3.2 * A plain authenticated session with no consultant assignment, no super-admin grant,
    --       and no open internal drain is refused by the NEW internal gate (owner bypasses the
    --       ACL, so this is reachable and meaningful even though role EXECUTE is revoked).
    perform pg_catalog.set_config('request.jwt.claims', pg_catalog.json_build_object(
      'sub', '00000000-0000-4000-8000-0000000720bb', 'role', 'authenticated',
      'aud', 'authenticated')::text, true);
    begin
      perform app.v176_evidence_pack(
        v_real_biz, 'monthly', date_trunc('month', app.sg_today() - 35)::date,
        (date_trunc('month', app.sg_today() - 35) + interval '1 month' - interval '1 day')::date
      );
      raise exception 'v720: an unauthorized authenticated session read the evidence pack';
    exception
      when sqlstate '42501' then null; -- expected
    end;
    perform pg_catalog.set_config('request.jwt.claims', '', true);

    -- 3.3 * The sessionless internal drain still produces a pack against the same business, so
    --       the worker (public.internal_claim_ai_firm_report_v176) is proved unaffected.
    perform app.v676_open_internal_drain();
    begin
      v_pack := app.v176_evidence_pack(
        v_real_biz, 'monthly', date_trunc('month', app.sg_today() - 35)::date,
        (date_trunc('month', app.sg_today() - 35) + interval '1 month' - interval '1 day')::date
      );
      v_ok := v_pack ? 'contract_version';
    exception when others then
      v_ok := false;
    end;
    perform app.v676_close_internal_drain();
    if not v_ok then
      raise exception 'v720: the sessionless internal drain no longer produces an evidence pack';
    end if;
  end if;
end
$v720_verify$;

rollback to savepoint v720_verify;

commit;
