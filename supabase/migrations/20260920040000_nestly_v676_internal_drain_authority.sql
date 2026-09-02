-- NESTLY v676 — the sessionless evidence drain stops impersonating a person and gets an
-- authority of its own.
--
-- ===========================================================================================
-- THE DEFECT (D6 in docs/qa/CI-REASSESSMENT-2026-09-01.md; held red on purpose by
-- db/tests/executed/v552_gated_evidence_isolation.sql, which asserts the correct behaviour and
-- has been failing five assertions since the migration chain reached v625).
--
-- app.v176_gated_evidence assembles the four consultative sections of the AI firm-report
-- evidence pack. Its only production caller is public.internal_claim_ai_firm_report_v176,
-- granted to service_role and invoked by supabase/functions/ai-firm-reports — a background
-- worker with no user session, so auth.uid() is NULL. The four sections it needs are gated:
--
--   public.platform_get_assigned_firm_report_v94       -> app.platform_firm_report_access_v94
--   public.platform_get_catalogue_affinity_v94         -> app.platform_firm_report_access_v94
--   public.platform_get_consultative_recommendations_v94 -> (no gate of its own; it calls
--                                                            catalogue affinity and inherits it)
--   public.platform_customer_account_opens_v175        -> its own auth.uid()/is_super_admin gate
--
-- To get past them, v176 (2026-08-06) had the drain FORGE a request claim: it read the first
-- row of public.super_admins and set request.jwt.claims to {sub, role, aud} for the duration of
-- the four reads. Its own header flagged this — "Reviewer: this is the one place in v176 that
-- forges a request claim".
--
-- nestly_v625 (owner directive 2026-08-30, "google log in only") then rewrote
-- app.is_super_admin() to additionally require app.platform_session_via_google_v625(), i.e.
-- amr[0].method = 'oauth' AND app_metadata.providers containing 'google'. A synthetic claim set
-- carrying only sub/role/aud can never satisfy that, and it must not be made to: a forged
-- Google session would be exactly the hole v625 closed. So since v625 every background caller
-- fails ALL FOUR sections with 42501. Measured, not reasoned — the pre-fix v552 run reports:
--
--   [{"section":"consultant_brief","sqlstate":"42501"},
--    {"section":"catalogue_affinity","sqlstate":"42501"},
--    {"section":"recommendations","sqlstate":"42501"},
--    {"section":"account_opens_report","sqlstate":"42501"}]
--
-- Every scheduled/queued AI firm report has been generated from an evidence pack with all four
-- consultative sections withheld. Thanks to v552 the withholding is at least DISCLOSED
-- (unavailable_sections), so this is an availability failure, not a misleading one — but the
-- capability is dead for the only caller that has it.
--
-- v625 is not at fault and is not touched here. The fault is that an internal, sessionless code
-- path was authenticating by pretending to be a human, which stops working the moment the human
-- rule tightens — and would have to be re-forged every time it tightens again.
--
-- ===========================================================================================
-- THE SHAPES CONSIDERED
--
-- (a) A FLAG GUC. app.v176_gated_evidence sets app.v676_internal_drain = 'on' (transaction
--     local) and the gates accept it. REJECTED AS INSECURE. set_config is available to any
--     caller: an authenticated merchant who can issue `select set_config('app.v676_internal_
--     drain','on',true)` in their transaction then calls public.platform_get_assigned_firm_
--     report_v94 against ANOTHER firm and is served. A flag is a password everyone knows.
--
-- (b) GATE-FREE INTERNAL CORES. Extract each of the four RPCs' computation into an app.* core
--     with no auth gate, revoked from everyone, and have the drain call the cores while
--     interactive callers keep the gated public.* path. Structurally the cleanest, and it needs
--     no marker at all. REJECTED FOR TWO REASONS, one of them decisive:
--       · The acceptance bar forbids it. v552 assertion G2 stubs *public*.platform_get_
--         catalogue_affinity_v94 to fail and requires the drain to lose exactly
--         catalogue_affinity AND recommendations (proving the real dependency between them)
--         while the two independent sections survive. A drain that calls app.* cores would be
--         unaffected by that stub, so G2 could not fail even when the section is broken — the
--         fixture would pass for the wrong reason. The test is the specification here: the
--         drain must go through the same public entry points a human uses.
--       · Extracting ~600 lines of analytics into parallel cores creates a snapshot that drifts
--         from the public bodies the next time either is edited — the exact duplication v176's
--         own header refused ("rather than duplicating (and drifting from) their SQL").
--
-- (c) THE SHAPE TAKEN — a dedicated internal authority whose proof cannot be forged. The drain
--     stops impersonating anybody. Instead it opens a transaction-local authority carrying a
--     SECRET TOKEN that lives in app.v676_internal_drain_authority: a table with no grants to
--     any role and RLS enabled with no policy, reachable only by its owner, i.e. only from
--     inside a SECURITY DEFINER function owned by postgres. The three functions that mint,
--     clear and verify the token are revoked from public, anon, authenticated AND service_role,
--     so the only route to them is the definer chain that starts at app.v176_gated_evidence
--     (itself revoked from every role — no caller can invoke it directly).
--
--     No precedent existed to follow. Every other background writer in this repo either runs as
--     the table owner behind SECURITY DEFINER with no gate to pass (app.run_subscription_
--     lifecycle_v94, the expiry sweeps) or impersonates a real user the same way v176 did
--     (nestly_v132, v277, v565 all save/set/restore request.jwt.claims). This is the first
--     internal path that must satisfy a gate written for humans, so it is also the first that
--     needs an authority that is not a human.
--
-- ===========================================================================================
-- WHY (c) IS SAFE — the attacker-set-GUC threat, spelled out
--
-- THREAT. An authenticated merchant wants another firm's consultative report. They call
-- public.platform_get_assigned_firm_report_v94(victim, …) — a function granted to
-- `authenticated`. The gate is now
--     app.v676_internal_drain_active() OR <the two unchanged human arms>.
-- To win they must make app.v676_internal_drain_active() return true. It returns true only when
-- BOTH hold:
--
--   1. auth.uid() IS NULL. A PostgREST request carries the caller's JWT, so a merchant's
--      session has a sub. Clearing it requires arbitrary SQL in the session, not an RPC call.
--   2. current_setting('app.v676_internal_drain_token') EQUALS the row in
--      app.v676_internal_drain_authority. The attacker CAN set that GUC to anything — that is
--      assumed, not hoped — but cannot learn what to set it to:
--        · the table has no privileges for public/anon/authenticated/service_role (asserted
--          below with has_table_privilege, not assumed), and RLS is on with no policy. That
--          also closes the statistics side door: pg_stats gates each row on
--          has_column_privilege, so a most_common_vals leak of a one-row table is not
--          available to a role that cannot select from it;
--        · the token is NOT a literal in any function body, so it cannot be read out of
--          pg_proc.prosrc / pg_get_functiondef — which ARE world-readable. Both the minting and
--          the verifying function read it from the table at run time. This is why the authority
--          is a table row and not a constant in a function;
--        · the GUC is transaction-local and backend-local, so its value during a genuine drain
--          is not observable from any other session (pg_settings shows only your own backend);
--        · app.v676_open_internal_drain / _close / _active are executable by no role at all.
--
-- Even step 1 alone defeats the RPC-level attacker; step 2 defeats an attacker who has
-- arbitrary SQL as `authenticated`, which is the stronger model this was designed against.
-- Note that such an attacker still cannot read another firm's sales directly — RLS scopes them
-- to their own tenant — so admitting them here WOULD have been a real escalation. That is
-- precisely why shape (a) was rejected.
--
-- RESIDUAL RISK, stated rather than hidden: anyone who can read app.v676_internal_drain_
-- authority can forge the authority. The set of principals who can read that table is exactly
-- {the table owner, a superuser} — the set that can already read every firm's raw data without
-- going through any RPC. The token therefore protects nothing that its own disclosure would not
-- already have exposed. Rotation, if ever wanted, is one UPDATE: both sides read the same row.
--
-- ===========================================================================================
-- WHAT CHANGES, EXACTLY
--
-- 1. NEW: app.v676_internal_drain_authority (one row), app.v676_open_internal_drain(),
--    app.v676_close_internal_drain(), app.v676_internal_drain_active(). All revoked from
--    public, anon, authenticated, service_role.
--
-- 2. app.platform_firm_report_access_v94 — one disjunct added AHEAD of the two existing arms,
--    which are byte-unchanged. Re-emitted in full and proved minimal by a pg_get_functiondef
--    before/after equality (v668's pattern): the new definition must equal the old one with
--    exactly that clause swapped, or the migration raises and rolls back.
--
--    BLAST RADIUS, checked in both directions:
--      · app.v176_can_read_firm_report opens with `auth.uid() is not null and (…)`, so the
--        drain (auth.uid() NULL) is still false there. app.ci_access_gate_v667 reads that
--        predicate, so NOTHING in the Customer Intelligence access boundary moves — v667's B1b
--        (a member of the firm without the reports entitlement is refused) is untouched, as are
--        B2/B3/B5.
--      · public.platform_get_business_control_v94 also consults this helper. It would admit an
--        open drain — but the drain window is opened and closed inside app.v176_gated_evidence
--        around four calls, none of which is that RPC, and no role can open the window itself.
--        Recorded because "unreachable" is a claim that should be written down, not assumed.
--
-- 3. public.platform_customer_account_opens_v175 — its 28000 sessionless guard and its
--    v_authorized expression each gain the same internal arm. Patched by extract-and-diff
--    (pg_get_functiondef -> two anchored replacements -> execute), because the other 100 lines
--    are analytics that must not be retyped. Both anchors are asserted to occur exactly once
--    before the replacement and the result is proved equal to the intended diff afterwards.
--
-- 4. app.v176_gated_evidence — the impersonation preamble and its restore are replaced by
--    open/close of the internal authority. Three clauses move; everything else (the v552
--    account-opens clamp, the four per-section exception handlers, unavailable_sections, the
--    return shape) is byte-identical, again proved by before/after equality.
--
--    Two consequences worth naming. The function no longer reads public.super_admins at all, so
--    the 'no_platform_reader' early return disappears with it — a deployment with zero super
--    admins used to have its consultative evidence silently withheld, and now does not. And the
--    drain no longer writes request.jwt.claims anywhere, which the verification block asserts.
--
-- NOT CHANGED, deliberately: app.is_super_admin, app.v89_platform_role and
-- app.platform_session_via_google_v625 are untouched — no session, forged or real, gains
-- platform authority it did not have. No human arm of any gate is widened. No new grant is
-- issued to any role.
--
-- PROVEN BY: db/tests/executed/v552_gated_evidence_isolation.sql (G1/G2/G3, assertions
-- unmodified) and, for the no-regression direction, db/tests/executed/v667_ci_access_
-- boundaries.sql.
--
-- ROLLBACK: re-apply the v552 body of app.v176_gated_evidence and the v94/v175 bodies of the
-- two gates (all three are reproduced verbatim in their own migrations), then
--   drop function if exists app.v676_internal_drain_active();
--   drop function if exists app.v676_open_internal_drain();
--   drop function if exists app.v676_close_internal_drain();
--   drop table if exists app.v676_internal_drain_authority;
-- Reverting restores the D6 outage; it does not restore any authority to a human.
-- ===========================================================================================

begin;

-- ---------------------------------------------------------------------------
-- 1 · The authority. A secret the definer chain can read and nobody else can.
-- ---------------------------------------------------------------------------
create table if not exists app.v676_internal_drain_authority (
  singleton  boolean primary key default true
             constraint v676_internal_drain_authority_one_row check (singleton),
  token      text not null,
  created_at timestamptz not null default now()
);

/* No policy is ever added: RLS-on-with-no-policy plus zero table privileges means the row is
   reachable only by the owner, which is only ever reached through SECURITY DEFINER. */
alter table app.v676_internal_drain_authority enable row level security;

revoke all privileges on table app.v676_internal_drain_authority
  from public, anon, authenticated, service_role;

/* 256 bits of server-side randomness. Generated HERE rather than written as a literal so the
   value never appears in any migration text, function body, or pg_proc row. */
insert into app.v676_internal_drain_authority (singleton, token)
values (true, pg_catalog.gen_random_uuid()::text || pg_catalog.gen_random_uuid()::text)
on conflict (singleton) do nothing;

comment on table app.v676_internal_drain_authority is
  'nestly_v676: the shared secret proving a sessionless internal evidence drain. Readable only '
  'by the table owner (no grants, RLS on with no policy) so that a caller who can set the '
  'app.v676_internal_drain_token GUC still cannot learn what to set it to.';

-- ---------------------------------------------------------------------------
-- 2 · Mint / clear / verify. Executable by no role — definer chain only.
-- ---------------------------------------------------------------------------
create or replace function app.v676_open_internal_drain()
returns void
language plpgsql
volatile
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $function$
declare
  v_token text;
begin
  select authority.token into v_token
    from app.v676_internal_drain_authority authority
   where authority.singleton;
  if v_token is null then
    raise exception 'v676: the internal drain authority row is missing'
      using errcode = '55000';
  end if;
  /* Transaction-local, so it cannot outlive the statement that opened it even if a caller
     forgets to close it, and cannot be observed from another backend. */
  perform pg_catalog.set_config('app.v676_internal_drain_token', v_token, true);
end
$function$;
revoke all privileges on function app.v676_open_internal_drain()
  from public, anon, authenticated, service_role;

create or replace function app.v676_close_internal_drain()
returns void
language plpgsql
volatile
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $function$
begin
  perform pg_catalog.set_config('app.v676_internal_drain_token', '', true);
end
$function$;
revoke all privileges on function app.v676_close_internal_drain()
  from public, anon, authenticated, service_role;

create or replace function app.v676_internal_drain_active()
returns boolean
language sql
stable
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $function$
  /* Two conditions, both required. auth.uid() IS NULL keeps the authority to genuinely
     sessionless callers — a live user session can never hold it, whatever GUC it sets. The
     token comparison is what an attacker cannot satisfy: setting the GUC is free, learning
     the value is not (see this migration's header). Empty/unset is refused explicitly so a
     table read cannot be short-circuited by a NULL on either side. */
  select auth.uid() is null
     and coalesce(
           pg_catalog.current_setting('app.v676_internal_drain_token', true), '') <> ''
     and exists (
       select 1
         from app.v676_internal_drain_authority authority
        where authority.singleton
          and authority.token
              = pg_catalog.current_setting('app.v676_internal_drain_token', true)
     )
$function$;
revoke all privileges on function app.v676_internal_drain_active()
  from public, anon, authenticated, service_role;

comment on function app.v676_internal_drain_active() is
  'nestly_v676: true only inside the app.v176_gated_evidence drain window — sessionless caller '
  'holding the internal authority token. Never true for any user session.';

-- ---------------------------------------------------------------------------
-- 3 · Gate 1 of 2 — the shared firm-report authority. Capture, replace, prove.
--     Covers consultant_brief, catalogue_affinity and (transitively) recommendations.
-- ---------------------------------------------------------------------------
create temp table _v676_before(name text, def text) on commit drop;

do $pre$
declare
  v_def text;
begin
  select pg_get_functiondef(p.oid) into v_def
    from pg_proc p
    join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'app' and p.proname = 'platform_firm_report_access_v94';
  if v_def is null then
    raise exception 'v676: app.platform_firm_report_access_v94 is missing';
  end if;
  if position('v676_internal_drain_active' in v_def) > 0 then
    raise exception 'v676: the internal arm is already present — re-read before shipping';
  end if;
  insert into _v676_before(name, def) values ('platform_firm_report_access_v94', v_def);

  select pg_get_functiondef(p.oid) into v_def
    from pg_proc p
    join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'public' and p.proname = 'platform_customer_account_opens_v175';
  if v_def is null then
    raise exception 'v676: public.platform_customer_account_opens_v175 is missing';
  end if;
  if position('v676_internal_drain_active' in v_def) > 0 then
    raise exception 'v676: account opens already carries the internal arm';
  end if;
  insert into _v676_before(name, def) values ('platform_customer_account_opens_v175', v_def);

  select pg_get_functiondef(p.oid) into v_def
    from pg_proc p
    join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'app' and p.proname = 'v176_gated_evidence';
  if v_def is null then
    raise exception 'v676: app.v176_gated_evidence is missing';
  end if;
  if position('request.jwt.claims' in v_def) = 0 then
    raise exception
      'v676: v176_gated_evidence no longer forges a claim — the shape this migration expects '
      'is not the shape that is deployed; extract it and re-diff rather than guessing';
  end if;
  insert into _v676_before(name, def) values ('v176_gated_evidence', v_def);
end
$pre$;

/* The v94 body verbatim, with the internal arm placed AHEAD of the two human arms. Both human
   arms are unchanged, character for character; the $post$ block below refuses anything else. */
create or replace function app.platform_firm_report_access_v94(p_business uuid)
returns boolean
language sql
stable
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $function$
  /* v676: the FIRST arm is the sessionless internal evidence drain - a dedicated authority,
     not a person and not a Google exemption. It is true only inside the
     app.v176_gated_evidence definer chain; no session, and no caller who can set a GUC, can
     mint it. The two human arms below are byte-unchanged. */
  select app.v676_internal_drain_active()
    or app.v89_platform_can('reports','r')
    or exists(
      select 1 from app.assigned_consultant_v94(p_business) consultant
      where consultant.user_id=auth.uid()
    )
$function$;
-- v94's live surface, restated verbatim.
revoke all on function app.platform_firm_report_access_v94(uuid)
  from public,anon,authenticated;

do $post$
declare
  v_before text;
  v_after  text;
  v_old constant text := $old$  select app.v89_platform_can('reports','r')
$old$;
  v_new constant text := $new$  /* v676: the FIRST arm is the sessionless internal evidence drain - a dedicated authority,
     not a person and not a Google exemption. It is true only inside the
     app.v176_gated_evidence definer chain; no session, and no caller who can set a GUC, can
     mint it. The two human arms below are byte-unchanged. */
  select app.v676_internal_drain_active()
    or app.v89_platform_can('reports','r')
$new$;
begin
  select def into v_before from _v676_before where name = 'platform_firm_report_access_v94';
  select pg_get_functiondef(p.oid) into v_after
    from pg_proc p
    join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'app' and p.proname = 'platform_firm_report_access_v94';

  if (length(v_before) - length(replace(v_before, v_old, ''))) / length(v_old) <> 1 then
    raise exception 'v676: the v89_platform_can arm does not occur exactly once in the live body';
  end if;
  if v_after <> replace(v_before, v_old, v_new) then
    raise exception 'v676: app.platform_firm_report_access_v94 changed by more than the internal arm'
      using detail = 'intended:' || E'\n' || replace(v_before, v_old, v_new)
                  || E'\n' || 'actual:' || E'\n' || v_after;
  end if;
end
$post$;

-- ---------------------------------------------------------------------------
-- 4 · Gate 2 of 2 — account opens. Extract-and-diff: the surrounding 100 lines
--     of analytics are never retyped, so they cannot drift here.
-- ---------------------------------------------------------------------------
do $patch$
declare
  v_before text;
  v_after  text;
  v_want   text;
  /* Anchor 1: the sessionless refusal. A drain has no session by definition, so this is the
     first thing it hits. */
  v_old_guard constant text := $old1$  if auth.uid() is null then
    raise exception 'authenticated report session is required'
      using errcode='28000';
  end if;
$old1$;
  v_new_guard constant text := $new1$  /* v676: a sessionless caller is still refused - unless it is the internal evidence drain,
     whose authority is a transaction-local token only the app.v176_gated_evidence definer
     chain can mint. Every other sessionless caller still gets 28000. */
  if auth.uid() is null and not app.v676_internal_drain_active() then
    raise exception 'authenticated report session is required'
      using errcode='28000';
  end if;
$new1$;
  /* Anchor 2: the authorization expression. The three human arms are untouched and keep their
     order; the internal arm is added ahead of them. */
  v_old_auth constant text := $old2$  v_authorized:=
    app.is_super_admin()
$old2$;
  v_new_auth constant text := $new2$  v_authorized:=
    app.v676_internal_drain_active()
    or app.is_super_admin()
$new2$;
begin
  select def into v_before from _v676_before where name = 'platform_customer_account_opens_v175';

  if (length(v_before) - length(replace(v_before, v_old_guard, ''))) / length(v_old_guard) <> 1 then
    raise exception 'v676: the 28000 sessionless guard does not occur exactly once in v175';
  end if;
  if (length(v_before) - length(replace(v_before, v_old_auth, ''))) / length(v_old_auth) <> 1 then
    raise exception 'v676: the v_authorized expression does not occur exactly once in v175';
  end if;

  v_want := replace(replace(v_before, v_old_guard, v_new_guard), v_old_auth, v_new_auth);
  execute v_want;

  select pg_get_functiondef(p.oid) into v_after
    from pg_proc p
    join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'public' and p.proname = 'platform_customer_account_opens_v175';
  if v_after <> v_want then
    raise exception 'v676: public.platform_customer_account_opens_v175 did not land as the intended diff'
      using detail = 'intended:' || E'\n' || v_want || E'\n' || 'actual:' || E'\n' || v_after;
  end if;
end
$patch$;

-- v175's live surface, restated verbatim.
revoke all privileges on function public.platform_customer_account_opens_v175(
  uuid,date,date
) from public,anon,authenticated,service_role;
grant execute on function public.platform_customer_account_opens_v175(
  uuid,date,date
) to authenticated;

-- ---------------------------------------------------------------------------
-- 5 · The drain itself. No forged claim, no borrowed identity, no super_admins
--     lookup — everything else in the v552 body is byte-identical.
-- ---------------------------------------------------------------------------
create or replace function app.v176_gated_evidence(p_business uuid, p_from date, p_to date)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $function$
declare
  v_internal_drain boolean := false;
  v_to_effective date;
  v_brief jsonb; v_affinity jsonb; v_recs jsonb; v_opens jsonb;
  v_unavailable jsonb := '[]'::jsonb;
begin
  /* v676: a sessionless caller no longer borrows the first super admin's identity. It opens a
     dedicated internal authority instead - a transaction-local token readable only inside this
     definer chain - so nothing is forged and app.is_super_admin()'s post-v625 Google rule is
     neither weakened nor evaded. With no identity to borrow, public.super_admins is no longer
     consulted and the 'no_platform_reader' outcome is gone: a deployment with no super admin
     used to lose all four consultative sections for that reason alone. */
  if auth.uid() is null then
    perform app.v676_open_internal_drain();
    v_internal_drain := true;
  end if;

  /* v552: the account-opens reader refuses future dates (its 22023 guard is correct); the
     monthly pack's period end is the month's last day, future for any mid-month claim. Clamp
     here, and say so in the payload rather than clamping silently. */
  v_to_effective := least(p_to, (pg_catalog.now() at time zone 'Asia/Singapore')::date);

  /* v552: one section, one handler. A failing section records its sqlstate (never sqlerrm — no
     internal identifiers for the model) and the other three survive. Before this, one failure
     removed all four and the error text was discarded. */
  begin
    v_brief := public.platform_get_assigned_firm_report_v94(p_business, null, p_from, p_to);
  exception when others then
    v_unavailable := v_unavailable || pg_catalog.jsonb_build_object(
      'section','consultant_brief','sqlstate', sqlstate);
  end;
  begin
    v_affinity := public.platform_get_catalogue_affinity_v94(p_business, null, p_from, p_to, 25);
  exception when others then
    v_unavailable := v_unavailable || pg_catalog.jsonb_build_object(
      'section','catalogue_affinity','sqlstate', sqlstate);
  end;
  begin
    v_recs := public.platform_get_consultative_recommendations_v94(p_business, null, p_from, p_to, 25);
  exception when others then
    v_unavailable := v_unavailable || pg_catalog.jsonb_build_object(
      'section','recommendations','sqlstate', sqlstate);
  end;
  begin
    v_opens := public.platform_customer_account_opens_v175(p_business, p_from, v_to_effective);
  exception when others then
    v_unavailable := v_unavailable || pg_catalog.jsonb_build_object(
      'section','account_opens_report','sqlstate', sqlstate);
  end;

  if v_internal_drain then
    perform app.v676_close_internal_drain();
  end if;

  return pg_catalog.jsonb_build_object(
    'available', pg_catalog.jsonb_array_length(v_unavailable) = 0,
    'reason', case when pg_catalog.jsonb_array_length(v_unavailable) = 0 then null
                   else 'sections_unavailable' end,
    'unavailable_sections', v_unavailable,
    'consultant_brief', v_brief,
    'catalogue_affinity', v_affinity,
    'recommendations', v_recs,
    'account_opens_report', v_opens,
    'account_opens_range', pg_catalog.jsonb_build_object(
      'requested_to', p_to,
      'effective_to', v_to_effective,
      'clamped', v_to_effective < p_to
    )
  );
end
$function$;

/* v552's restatement, plus service_role: v176 revoked it there and v552's restatement dropped
   the mention. The drain reaches this function through public.internal_claim_ai_firm_report_
   v176 (SECURITY DEFINER, owned by postgres), where EXECUTE is checked against the owner, so
   removing service_role's direct grant costs the worker nothing and closes a route nobody
   should have. */
revoke all privileges on function app.v176_gated_evidence(uuid, date, date)
  from public, anon, authenticated, service_role;

do $drain$
declare
  v_before text;
  v_after  text;
  v_old_decl constant text := $oldd$  v_reader uuid;
  v_prior_sub text;
  v_prior_claims text;
  v_impersonated boolean := false;
$oldd$;
  v_new_decl constant text := $newd$  v_internal_drain boolean := false;
$newd$;
  v_old_open constant text := $oldo$  if auth.uid() is null then
    select super_admin.user_id into v_reader
      from public.super_admins super_admin
     order by super_admin.user_id limit 1;
    if v_reader is null then
      return pg_catalog.jsonb_build_object(
        'available', false,
        'reason', 'no_platform_reader',
        'unavailable_sections', pg_catalog.jsonb_build_array(
          pg_catalog.jsonb_build_object('section','consultant_brief','sqlstate','n/a'),
          pg_catalog.jsonb_build_object('section','catalogue_affinity','sqlstate','n/a'),
          pg_catalog.jsonb_build_object('section','recommendations','sqlstate','n/a'),
          pg_catalog.jsonb_build_object('section','account_opens_report','sqlstate','n/a')
        )
      );
    end if;
    v_prior_sub := coalesce(pg_catalog.current_setting('request.jwt.claim.sub', true), '');
    v_prior_claims := coalesce(pg_catalog.current_setting('request.jwt.claims', true), '');
    perform pg_catalog.set_config('request.jwt.claim.sub', v_reader::text, true);
    perform pg_catalog.set_config('request.jwt.claims', pg_catalog.json_build_object(
      'sub', v_reader, 'role', 'authenticated', 'aud', 'authenticated')::text, true);
    v_impersonated := true;
  end if;
$oldo$;
  v_new_open constant text := $newo$  /* v676: a sessionless caller no longer borrows the first super admin's identity. It opens a
     dedicated internal authority instead - a transaction-local token readable only inside this
     definer chain - so nothing is forged and app.is_super_admin()'s post-v625 Google rule is
     neither weakened nor evaded. With no identity to borrow, public.super_admins is no longer
     consulted and the 'no_platform_reader' outcome is gone: a deployment with no super admin
     used to lose all four consultative sections for that reason alone. */
  if auth.uid() is null then
    perform app.v676_open_internal_drain();
    v_internal_drain := true;
  end if;
$newo$;
  v_old_close constant text := $oldc$  if v_impersonated then
    perform pg_catalog.set_config('request.jwt.claim.sub', v_prior_sub, true);
    perform pg_catalog.set_config('request.jwt.claims', v_prior_claims, true);
  end if;
$oldc$;
  v_new_close constant text := $newc$  if v_internal_drain then
    perform app.v676_close_internal_drain();
  end if;
$newc$;
begin
  select def into v_before from _v676_before where name = 'v176_gated_evidence';
  select pg_get_functiondef(p.oid) into v_after
    from pg_proc p
    join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'app' and p.proname = 'v176_gated_evidence';

  if position(v_old_decl in v_before) = 0
     or position(v_old_open in v_before) = 0
     or position(v_old_close in v_before) = 0 then
    raise exception
      'v676: the impersonation preamble is not in the v552 shape this migration expects; '
      'extract it with pg_get_functiondef and re-diff rather than guessing';
  end if;

  if v_after <> replace(replace(replace(v_before, v_old_decl, v_new_decl),
                                v_old_open, v_new_open),
                        v_old_close, v_new_close) then
    raise exception
      'v676: app.v176_gated_evidence changed by more than the impersonation swap - the clamp, '
      'the four per-section handlers and the return shape must not move'
      using detail = 'intended:' || E'\n'
        || replace(replace(replace(v_before, v_old_decl, v_new_decl), v_old_open, v_new_open),
                   v_old_close, v_new_close)
        || E'\n' || 'actual:' || E'\n' || v_after;
  end if;
end
$drain$;

-- ---------------------------------------------------------------------------
-- 6 · Verification. The claims in the header, executed rather than asserted.
-- ---------------------------------------------------------------------------
do $verify$
declare
  r_role      text;
  v_guessable text;
  v_fake_biz constant uuid := '00000000-0000-4000-8000-0000000676ff';
begin
  -- 6.1 · No role may reach the authority. has_*_privilege('anon', …) also answers for PUBLIC,
  --       because every role inherits PUBLIC's grants.
  foreach r_role in array array['anon','authenticated','service_role'] loop
    if pg_catalog.has_table_privilege(r_role, 'app.v676_internal_drain_authority', 'select')
       or pg_catalog.has_table_privilege(r_role, 'app.v676_internal_drain_authority', 'insert')
       or pg_catalog.has_table_privilege(r_role, 'app.v676_internal_drain_authority', 'update')
       or pg_catalog.has_table_privilege(r_role, 'app.v676_internal_drain_authority', 'delete') then
      raise exception 'v676: role % can reach the drain authority table', r_role;
    end if;
    if pg_catalog.has_function_privilege(r_role, 'app.v676_open_internal_drain()', 'execute')
       or pg_catalog.has_function_privilege(r_role, 'app.v676_close_internal_drain()', 'execute')
       or pg_catalog.has_function_privilege(r_role, 'app.v676_internal_drain_active()', 'execute')
       or pg_catalog.has_function_privilege(r_role, 'app.v176_gated_evidence(uuid,date,date)', 'execute')
    then
      raise exception 'v676: role % can execute an internal drain routine', r_role;
    end if;
  end loop;

  -- 6.2 · Cold start: no token, no authority.
  if app.v676_internal_drain_active() then
    raise exception 'v676: the drain reports active with no token set';
  end if;
  if app.platform_firm_report_access_v94(v_fake_biz) then
    raise exception 'v676: the firm-report gate admits a sessionless caller with no authority';
  end if;

  -- 6.3 · THE ATTACK, executed. Any caller can set an arbitrary GUC — that is exactly why the
  --       authority is a secret and not a flag. Every guessable value must be refused.
  foreach v_guessable in array array['on','true','1','yes','internal','v676','drain'] loop
    perform pg_catalog.set_config('app.v676_internal_drain_token', v_guessable, true);
    if app.v676_internal_drain_active() then
      raise exception 'v676: the guessed token "%" opened the drain - the authority is forgeable',
        v_guessable;
    end if;
    if app.platform_firm_report_access_v94(v_fake_biz) then
      raise exception 'v676: the guessed token "%" got past the firm-report gate', v_guessable;
    end if;
  end loop;
  perform pg_catalog.set_config('app.v676_internal_drain_token', '', true);

  -- 6.4 · The definer chain can open it, and both gates then admit it.
  perform app.v676_open_internal_drain();
  if not app.v676_internal_drain_active() then
    raise exception 'v676: the drain did not open for its own definer chain';
  end if;
  if not app.platform_firm_report_access_v94(v_fake_biz) then
    raise exception 'v676: the firm-report gate refused an open internal drain';
  end if;

  -- 6.5 · A live user session can never hold the authority, token or no token.
  perform pg_catalog.set_config('request.jwt.claims', pg_catalog.json_build_object(
    'sub', '00000000-0000-4000-8000-0000000676aa', 'role', 'authenticated')::text, true);
  if app.v676_internal_drain_active() then
    raise exception 'v676: the internal authority survived a live user session';
  end if;
  perform pg_catalog.set_config('request.jwt.claims', '', true);

  -- 6.6 · Closing it puts both gates back.
  perform app.v676_close_internal_drain();
  if app.v676_internal_drain_active() then
    raise exception 'v676: the drain stayed open after being closed';
  end if;
  if app.platform_firm_report_access_v94(v_fake_biz) then
    raise exception 'v676: the firm-report gate stayed open after the drain closed';
  end if;

  -- 6.7 · No claim is forged anywhere in the drain any more.
  if exists (
    select 1 from pg_proc p
      join pg_namespace ns on ns.oid = p.pronamespace
     where ns.nspname = 'app' and p.proname = 'v176_gated_evidence'
       and position('request.jwt' in p.prosrc) > 0
  ) then
    raise exception 'v676: app.v176_gated_evidence still writes a request claim';
  end if;

  -- 6.8 · And the human rules are exactly as v625 left them.
  if not exists (
    select 1 from pg_proc p
      join pg_namespace ns on ns.oid = p.pronamespace
     where ns.nspname = 'app' and p.proname = 'is_super_admin'
       and position('platform_session_via_google_v625' in p.prosrc) > 0
  ) then
    raise exception 'v676: app.is_super_admin no longer requires a Google session';
  end if;
end
$verify$;

commit;
