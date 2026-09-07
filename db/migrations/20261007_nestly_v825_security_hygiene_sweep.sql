-- NESTLY v825 — a read-only production security audit, closed. Seven RPCs stop being callable
-- with the publishable (anon) key, two catalogue tables stop being world-readable by policy, ten
-- SECURITY INVOKER helpers get their search_path pinned, and two orphaned overloads — one of them
-- the source of a live 42725 — are removed.
--
-- HOW THIS WAS FOUND. A read-only sweep of production on 2026-09-08 (pg_proc.proacl,
-- pg_policies.roles, the Supabase advisor's function_search_path_mutable list, and one 42725 in
-- the API log). Every finding below was re-read from production immediately before this file was
-- written; nothing here is inferred from the repo alone.
--
-- ────────────────────────────────────────────────────────────────────────────────────────────
-- 1 · SIX PRIVILEGED READERS WERE ANON-EXECUTABLE.
--
--   public.super_admin_list_businesses()                    anon=X  (and PUBLIC=X)
--   public.platform_generate_improvement_report_v82(...)    anon=X  (and PUBLIC=X)
--   public.platform_get_enterprise_hierarchy_v82(...)       anon=X  (and PUBLIC=X)
--   public.platform_get_assigned_firm_report_v94(...)       anon=X
--   public.get_customer_intelligence_v83(...)               anon=X
--   public.preview_campaign_audience_v155(...)              anon=X
--
-- All six are SECURITY DEFINER. Their own bodies gate on app.is_super_admin() / app.has_perm(),
-- so an anon caller is refused rather than served — this is a depth failure, not an open door.
-- But an executable SECURITY DEFINER entry point reachable with a key that ships in every page
-- of the app is one body edit away from being an open door, and nothing needs it: every caller
-- runs as `authenticated`.
--
-- THE CALLER GREP, BOTH DIRECTIONS (2026-09-08):
--   * app/platform-console.js and app/app.js (and its generated app-business.js / app-core.js
--     chunks) are the only repo call sites. Both surfaces sign in through Supabase Auth and issue
--     their RPCs on a session token — role `authenticated`.
--   * app/join.html (the one genuinely anonymous browser surface) references none of the six.
--   * supabase/functions/** and api/** reference none of the six. The public edge gateway builds
--     its client with gateway.ts's adminClient(), which is keyed on SUPABASE_SECRET_KEYS.default
--     (falling back to SUPABASE_SERVICE_ROLE_KEY) — role `service_role`, not anon.
--   Nothing in the estate loses a capability. anon and PUBLIC are revoked; authenticated and
--   service_role are restated explicitly so the grant is written down here rather than inherited.
--
-- Note the PUBLIC (`=X/postgres`) entries on four of the six: revoking `anon` alone would have
-- left them executable by anon anyway, through PUBLIC. Both are revoked.
--
-- ────────────────────────────────────────────────────────────────────────────────────────────
-- 2 · public.get_business_application_status_v95(uuid) — ANON REVOKED, and the reason.
--
-- This one had to be read, not assumed: it is the status lookup behind the public
-- "where is my application" page, so an anon grant would be legitimate if the browser called it
-- directly. It does not. supabase/functions/public-business-application/index.ts reaches it as
--
--     await adminClient().rpc('get_business_application_status_v95', { p_public_reference: ... })
--
-- and adminClient() is the SERVICE ROLE client (gateway.ts secretKey()). The browser only ever
-- talks to the edge function, which rate-limits the lookup (30 per 5 minutes, keyed on the
-- authoritative client IP) and 404s a malformed or unknown reference before the RPC is reached.
-- The anon grant therefore buys nothing and bypasses that rate limit: a direct
-- /rest/v1/rpc/get_business_application_status_v95 call with the publishable key is an
-- unthrottled oracle over application references. Revoked; the gateway is unaffected because
-- service_role keeps its grant.
--
-- ────────────────────────────────────────────────────────────────────────────────────────────
-- 3 · TWO `USING (true) TO PUBLIC` READ POLICIES.
--
--   platform_capabilities_v518_read       on public.platform_capabilities_v518
--   whatsapp_template_registry_v551_read  on public.whatsapp_template_registry_v551
--
-- Neither table grants SELECT to anon (relacl is postgres, service_role, authenticated=r), so
-- TO PUBLIC is today unreachable by anon — the finding is real but the exposure is not. It is
-- still worth closing: the policy is the layer a future `grant select ... to anon` would silently
-- fall through. Grepped first: app/join.html, app/app.js and its chunks read neither table, and
-- the only mention anywhere under supabase/functions/ is a prose comment in
-- whatsapp-admin-templates/index.ts. Both policies are recreated with the same USING (true),
-- addressed TO authenticated, service_role.
--
-- ────────────────────────────────────────────────────────────────────────────────────────────
-- 4 · TEN SECURITY INVOKER HELPERS WITH A MUTABLE search_path.
--
-- Every one has proconfig IS NULL in production. Each body was read before pinning, looking for
-- an unqualified reference to a schema the pin would drop (cron, net, vault, extensions):
-- there is none. The ten reference only built-ins (split_part, coalesce, jsonb_build_object,
-- least, gen_random_uuid is not among them) and, in the two trigger functions, the TG_ variables.
-- The pin is therefore the same four-element list every other function in the estate carries.
--
-- ONE ABSENCE IS TOLERATED, AND ONLY ONE KIND OF ABSENCE. Section 4 pins whichever of the ten
-- is actually present and refuses anything present that is not a SECURITY INVOKER function; it
-- does not refuse an absent one. That is not laxity, it is the only way this file can be replayed
-- by scripts/db-tests/run.mjs: the harness discovers pending migrations with
-- /_nestly_v(\d+)[_.]/, which does not match the nestly_v591a..v591e family, so
-- app.v591_max_attempts() — created by 20260828_nestly_v591a_webhook_consumer_markers.sql — does
-- not exist in the scratch cluster at all. Production has all ten (re-read 2026-09-08) and
-- therefore gets all ten pinned; the rehearsal pins nine and says which one it could not see.
-- The harness regex is a pre-existing gap in the replay tooling, reported separately, and is
-- deliberately NOT patched here: widening it would pull five unrelated migrations into every
-- rehearsal in the middle of a security fix.
--
-- ONE DELIBERATE TRADE-OFF, recorded so it is not rediscovered as a mystery regression. Seven of
-- the ten are LANGUAGE SQL, and a SQL function carrying a SET clause is no longer inlinable by
-- the planner. app.ci_visit_day_v699(timestamptz) in particular is called per row by roughly
-- thirty CI readers. The cost is a real function call per row instead of an inlined expression;
-- it is accepted because (a) none of the ten is referenced by an index expression or a generated
-- column — checked against pg_depend, zero index dependencies — so no plan that relies on
-- inlining for index matching exists, and (b) all seven are IMMUTABLE or STABLE constants and
-- CASE expressions whose per-call cost is nanoseconds. If a CI reader ever regresses on latency,
-- this is the paragraph to come back to.
--
-- ────────────────────────────────────────────────────────────────────────────────────────────
-- 5 · public.redeem_points(uuid, uuid) — DROPPED, and the both-directions proof.
--
-- The legacy two-argument redemption. It reads the client's points balance UNSCOPED —
--
--     select coalesce(sum(pl.points),0) from public.points_ledger pl
--      where pl.business_id = p_business and pl.client_id = p_client;
--
-- summing every programme's pot — and then drains points_batches SCOPED to
-- app.resolve_ledger_programme_v309(p_business). That is the exact defect class nestly_v312 /
-- v381 / v813 have been closing reader by reader: a business running two pots could pass the
-- sufficiency test on another programme's points and then fail (or under-drain) the batch check.
--
-- It is not API-executable — proacl is {postgres, service_role} only, anon and authenticated both
-- false — so this has never been reachable from a browser. It is dropped rather than repaired
-- because it has NO callers at all:
--   * FROM THE DATABASE: the only two pg_proc bodies in public/app that mention `redeem_points(`
--     are public.merchant_scan_redemption_qr_v89 and _v93, and both call the THREE-argument form
--     (`redeem_points(p_business, v_intent.client_id, 'v89:'||v_intent.id::text)`), which
--     delegates to app.redeem_points_v40_internal — already pot-scoped. The pre-flight below
--     re-proves this against the live catalogue and refuses to drop if a third caller has
--     appeared.
--   * FROM THE REPO: no `sb.rpc('redeem_points'...)` exists anywhere under app/,
--     supabase/functions/, api/ or scripts/. The 20-odd `redeem_points` hits in app/app.js are
--     the loyalty_programs.redeem_points COLUMN (the classic model's point cost), not this
--     function.
-- (Memory rule "dropping SQL objects breaks callers silently": PL/pgSQL resolves names at run
-- time, so a grep of pg_get_functiondef IS the proof, and it is executed as a pre-flight below,
-- not merely asserted in prose.)
--
-- The credit_ledger write-scope allowlist is deliberately NOT touched. 'redeem_points' remains a
-- named write route because app.redeem_points_v40_internal — the surviving path — still declares
-- it. Narrowing the guard here would take the live redemption down.
--
-- ────────────────────────────────────────────────────────────────────────────────────────────
-- 6 · public.evaluate_checkout — THE TWIN OVERLOAD THAT PRODUCED A LIVE 42725.
--
-- Production carries two:
--     evaluate_checkout(uuid, uuid, uuid, jsonb, uuid, uuid DEFAULT null)                 -- v656
--     evaluate_checkout(uuid, uuid, uuid, jsonb, uuid, uuid DEFAULT null, boolean DEFAULT false)
--                                                                                         -- v752
-- nestly_v656 replaced the five-argument form and correctly dropped it. nestly_v752 added
-- p_birthday as a NEW overload and did not. Because BOTH give p_tier_benefit a default, any call
-- naming five or six arguments matches both candidates and Postgres raises 42725
-- "function name is not unique" — which is precisely what one production log line shows. Only a
-- call naming all seven is unambiguous, and that is the only call the app makes today, which is
-- why the till has kept working and the ambiguity surfaced just once.
--
-- The two bodies were diffed line by line against production: the seven-argument form is a strict
-- superset, differing only by the two lines that add 'birthday' to the idempotency hash and pass
-- p_birthday through to app.ps1c_plan_checkout. With p_birthday DEFAULT false, dropping the
-- six-argument twin leaves ONE function that answers a five-, six- or seven-argument call
-- identically to the way the pair answered a seven-argument one. That is the
-- single-function-with-a-default shape, reached by subtraction rather than by writing a wrapper —
-- a wrapper would not have removed the ambiguity, only renamed it.
--
-- CALLER GREP, BOTH DIRECTIONS: the only rpc('evaluate_checkout', ...) call site in the estate is
-- app/app.js:27284 (and its generated twin app-business.js:8695), and it passes all seven named
-- arguments including p_birthday. No pg_proc body calls evaluate_checkout at all — the single
-- catalogue hit inside app.ps1c_plan_checkout is a prose comment. Nothing loses a signature it
-- was using.
--
-- ────────────────────────────────────────────────────────────────────────────────────────────
-- WHAT THIS MIGRATION DOES NOT DO. It registers no governance rows, changes no function body
-- except by removing two orphans, and writes no tenant data. Every statement is a privilege, a
-- policy, a proconfig, or a drop.
begin;

set local search_path = pg_catalog, public, app, pg_temp;

-- ============================================================================================
-- 0 · THE PIN SET, WRITTEN DOWN ONCE. The ten signatures of section 4 are named by the pre-flight,
--     by the ALTER loop and by the verification block. Three copies of a list is three chances to
--     pin nine and assert ten, so the list lives in one session-local function that dies with the
--     connection and leaves no object behind in either schema.
-- ============================================================================================
create function pg_temp.v825_pin_targets() returns text[] language sql immutable as $$
  select array[
    'app.v591_max_attempts()',
    'app.v785_lane(text)',
    'app.assert_business_id_immutable_v602()',
    'app.v550_attention_outreach_immutable()',
    'app.v551_retention_status_rank(text)',
    'app.ci_visit_day_v699(timestamp with time zone)',
    'app.ci_materiality_threshold_bps_v705()',
    'app.ci_verdict_class_v696(text)',
    'app.ci_visit_registry_v699()',
    'app.ci_standard_incentive_cents_v718()'
  ]
$$;

-- ============================================================================================
-- 1 · PRE-FLIGHT — the live shape this migration was written against, re-proved at apply time.
--     Every check below is a refusal, not a warning: if production has drifted, the audit that
--     produced this file is stale and the file must be re-derived, not forced through.
-- ============================================================================================
do $v825_pre$
declare
  v_missing text;
  v_absent text[];
  v_callers text[];
  v_def text;
  r record;
begin
  /* --- The seven public entry points whose ACLs this migration rewrites. Named by their exact
         identity signature: a revoke against a signature that no longer exists is a silent no-op,
         which is exactly how an ACL fix rots. --- */
  foreach v_missing in array array[
    'public.super_admin_list_businesses()',
    'public.platform_generate_improvement_report_v82(text, uuid[], uuid, date, date, text, timestamp with time zone)',
    'public.platform_get_enterprise_hierarchy_v82(text, uuid[], uuid, date, date, text, integer, timestamp with time zone, timestamp with time zone, uuid)',
    'public.platform_get_assigned_firm_report_v94(uuid, uuid, date, date)',
    'public.get_customer_intelligence_v83(uuid, uuid, date, date, integer, timestamp with time zone, timestamp with time zone, uuid)',
    'public.preview_campaign_audience_v155(uuid, text, text, uuid[], uuid)',
    'public.get_business_application_status_v95(uuid)'
  ]
  loop
    if to_regprocedure(v_missing) is null then
      raise exception 'v825 pre-flight: % is not present with that exact signature -- the audit '
        'this migration closes was taken against a different estate', v_missing;
    end if;
  end loop;

  /* --- The two read policies. --- */
  if not exists (select 1 from pg_policies
                  where schemaname = 'public' and tablename = 'platform_capabilities_v518'
                    and policyname = 'platform_capabilities_v518_read')
     or not exists (select 1 from pg_policies
                     where schemaname = 'public' and tablename = 'whatsapp_template_registry_v551'
                       and policyname = 'whatsapp_template_registry_v551_read')
  then
    raise exception 'v825 pre-flight: one of the two USING(true) read policies v825 recreates is '
      'already gone -- refusing to drop-and-create a policy somebody else has since rewritten';
  end if;

  /* --- The ten SECURITY INVOKER helpers. A SECURITY DEFINER one would need a different review,
         so the definer flag is asserted too, not just presence. --- */
  v_absent := array[]::text[];
  foreach v_missing in array pg_temp.v825_pin_targets() loop
    if to_regprocedure(v_missing) is null then
      /* Tolerated, and only for the reason set out in the header: the db-tests harness cannot
         discover the nestly_v591a..e family, so app.v591_max_attempts() is absent in a rehearsal
         and present in production. Whatever is absent is named in the notice below rather than
         passed over in silence. */
      v_absent := v_absent || v_missing;
    elsif (select prosecdef from pg_proc where oid = to_regprocedure(v_missing)) then
      raise exception 'v825 pre-flight: % is SECURITY DEFINER, not the SECURITY INVOKER helper '
        'the advisor flagged -- pinning it is a different decision', v_missing;
    end if;
  end loop;
  if cardinality(v_absent) = cardinality(pg_temp.v825_pin_targets()) then
    raise exception 'v825 pre-flight: NONE of the ten advisor-flagged app helpers exists -- this '
      'is not the estate the audit was taken against';
  end if;
  if cardinality(v_absent) > 0 then
    raise notice 'v825: % of the ten search_path targets are absent here and will not be pinned: %',
      cardinality(v_absent), array_to_string(v_absent, ', ');
  end if;

  /* --- Item 5's both-directions proof, executed rather than asserted in prose. PL/pgSQL resolves
         function names at run time, so the ONLY way to know a drop is safe is to read every
         body in the two schemas that could name it. --- */
  if to_regprocedure('public.redeem_points(uuid, uuid)') is null then
    raise exception 'v825 pre-flight: public.redeem_points(uuid, uuid) is already gone';
  end if;
  if to_regprocedure('public.redeem_points(uuid, uuid, text)') is null then
    raise exception 'v825 pre-flight: the surviving public.redeem_points(uuid, uuid, text) is '
      'missing -- dropping the two-argument form would leave NO redemption entry point';
  end if;

  select coalesce(array_agg(n.nspname || '.' || p.proname
                        order by n.nspname || '.' || p.proname), array[]::text[])
    into v_callers
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
   where n.nspname in ('public', 'app')
     and p.prosrc like '%redeem_points(%'
     and p.oid <> to_regprocedure('public.redeem_points(uuid, uuid)')
     and p.oid <> to_regprocedure('public.redeem_points(uuid, uuid, text)');
  if v_callers <> array['public.merchant_scan_redemption_qr_v89',
                        'public.merchant_scan_redemption_qr_v93'] then
    raise exception 'v825 pre-flight: the set of database bodies naming redeem_points( is % , not '
      'the two merchant QR scanners the drop proof was built on -- re-run the caller grep before '
      'dropping the two-argument overload', v_callers;
  end if;
  /* Both known callers must be on the THREE-argument form; a two-argument call there would make
     the drop a production outage. */
  for r in select p.oid, n.nspname || '.' || p.proname as fqn
             from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'public'
              and p.proname in ('merchant_scan_redemption_qr_v89', 'merchant_scan_redemption_qr_v93')
  loop
    v_def := (select prosrc from pg_proc where oid = r.oid);
    if position('redeem_points(' in v_def) > 0
       and position('v_intent.client_id,' in v_def) = 0 then
      raise exception 'v825 pre-flight: % does not call redeem_points in the three-argument form '
        'the drop proof assumed', r.fqn;
    end if;
  end loop;

  /* --- Item 6. Both overloads must be present, and the survivor must carry p_birthday with a
         DEFAULT -- without the default, dropping the six-argument twin would break a six-argument
         call instead of disambiguating it. --- */
  if to_regprocedure('public.evaluate_checkout(uuid, uuid, uuid, jsonb, uuid, uuid)') is null then
    raise exception 'v825 pre-flight: the six-argument evaluate_checkout overload is already gone';
  end if;
  if to_regprocedure('public.evaluate_checkout(uuid, uuid, uuid, jsonb, uuid, uuid, boolean)') is null then
    raise exception 'v825 pre-flight: the seven-argument evaluate_checkout is missing -- dropping '
      'the six-argument form would remove checkout pricing entirely';
  end if;
  if position('p_birthday boolean DEFAULT false' in
              pg_get_function_arguments(
                to_regprocedure('public.evaluate_checkout(uuid, uuid, uuid, jsonb, uuid, uuid, boolean)'))) = 0
  then
    raise exception 'v825 pre-flight: the surviving evaluate_checkout does not default p_birthday '
      '-- dropping the six-argument overload would break a six-argument call rather than '
      'disambiguate it';
  end if;
  if exists (
    select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname in ('public', 'app')
       and p.prosrc like '%evaluate_checkout(%')
  then
    raise exception 'v825 pre-flight: a database body now CALLS evaluate_checkout(...) -- the '
      'drop proof assumed the only in-catalogue mention was a prose comment';
  end if;
end
$v825_pre$;

-- ============================================================================================
-- 2 · ITEM 1 + ITEM 2 — the publishable key stops reaching seven privileged readers.
--     PUBLIC is revoked alongside anon: four of the seven carried `=X/postgres`, so revoking
--     anon alone would have left anon executing them through PUBLIC. authenticated and
--     service_role are re-granted explicitly, so this file is where the grant is written down.
-- ============================================================================================
revoke all on function public.super_admin_list_businesses() from public, anon;
grant execute on function public.super_admin_list_businesses() to authenticated, service_role;

revoke all on function public.platform_generate_improvement_report_v82(
  text, uuid[], uuid, date, date, text, timestamp with time zone) from public, anon;
grant execute on function public.platform_generate_improvement_report_v82(
  text, uuid[], uuid, date, date, text, timestamp with time zone) to authenticated, service_role;

revoke all on function public.platform_get_enterprise_hierarchy_v82(
  text, uuid[], uuid, date, date, text, integer, timestamp with time zone,
  timestamp with time zone, uuid) from public, anon;
grant execute on function public.platform_get_enterprise_hierarchy_v82(
  text, uuid[], uuid, date, date, text, integer, timestamp with time zone,
  timestamp with time zone, uuid) to authenticated, service_role;

revoke all on function public.platform_get_assigned_firm_report_v94(uuid, uuid, date, date)
  from public, anon;
grant execute on function public.platform_get_assigned_firm_report_v94(uuid, uuid, date, date)
  to authenticated, service_role;

revoke all on function public.get_customer_intelligence_v83(
  uuid, uuid, date, date, integer, timestamp with time zone, timestamp with time zone, uuid)
  from public, anon;
grant execute on function public.get_customer_intelligence_v83(
  uuid, uuid, date, date, integer, timestamp with time zone, timestamp with time zone, uuid)
  to authenticated, service_role;

revoke all on function public.preview_campaign_audience_v155(uuid, text, text, uuid[], uuid)
  from public, anon;
grant execute on function public.preview_campaign_audience_v155(uuid, text, text, uuid[], uuid)
  to authenticated, service_role;

/* Item 2. The public application-status page never touches this directly: the edge gateway calls
   it with the service role key, after its own rate limit. anon buys nothing and bypasses that
   limit. authenticated keeps it — the console reads an application's status from inside a
   signed-in session. */
revoke all on function public.get_business_application_status_v95(uuid) from public, anon;
grant execute on function public.get_business_application_status_v95(uuid)
  to authenticated, service_role;

-- ============================================================================================
-- 3 · ITEM 3 — the two catalogue read policies are addressed, not left open to PUBLIC.
--     Same USING (true): who may read is decided by the grant and by the role list, not by a
--     predicate. Only the audience changes.
-- ============================================================================================
drop policy platform_capabilities_v518_read on public.platform_capabilities_v518;
create policy platform_capabilities_v518_read
  on public.platform_capabilities_v518
  for select
  to authenticated, service_role
  using (true);

drop policy whatsapp_template_registry_v551_read on public.whatsapp_template_registry_v551;
create policy whatsapp_template_registry_v551_read
  on public.whatsapp_template_registry_v551
  for select
  to authenticated, service_role
  using (true);

-- ============================================================================================
-- 4 · ITEM 4 — ten mutable search_paths pinned. Bodies read first; none names cron, net, vault
--     or extensions, qualified or not, so the four-element pin cannot strand a reference.
--     See the header for the SQL-inlining trade-off this knowingly accepts.
-- ============================================================================================
do $v825_pin$
declare
  v_sig text;
begin
  foreach v_sig in array pg_temp.v825_pin_targets() loop
    if to_regprocedure(v_sig) is not null then
      execute format('alter function %s set search_path = pg_catalog, public, app, pg_temp', v_sig);
    end if;
  end loop;
end
$v825_pin$;

-- ============================================================================================
-- 5 · ITEM 5 — the unscoped legacy redemption is removed, not repaired. Section 1 has already
--     proved, against the live catalogue, that the only two database callers are on the
--     three-argument form and that the repo has no RPC call site at all.
-- ============================================================================================
drop function public.redeem_points(uuid, uuid);

-- ============================================================================================
-- 6 · ITEM 6 — one evaluate_checkout, with p_birthday defaulted. Dropping the six-argument twin
--     is what makes a five- or six-argument named call unambiguous again; keeping both and
--     adding a wrapper would have preserved the 42725 exactly.
-- ============================================================================================
drop function public.evaluate_checkout(uuid, uuid, uuid, jsonb, uuid, uuid);

-- ============================================================================================
-- 7 · ACLs RESTATED, NOT ASSUMED — the surviving evaluate_checkout keeps the pair's audience.
--     Live production ACL before this migration, on BOTH overloads:
--       {postgres=X/postgres, authenticated=X/postgres, service_role=X/postgres}
--     Dropping one sibling cannot change the other's ACL, but restating it is what makes that a
--     fact this file guarantees rather than one it hopes for. Same for the surviving
--     three-argument redeem_points, whose {postgres, service_role} audience is deliberately
--     NARROWER than API-executable and must stay that way.
-- ============================================================================================
revoke all on function public.evaluate_checkout(uuid, uuid, uuid, jsonb, uuid, uuid, boolean)
  from public, anon;
grant execute on function public.evaluate_checkout(uuid, uuid, uuid, jsonb, uuid, uuid, boolean)
  to authenticated, service_role;

revoke all on function public.redeem_points(uuid, uuid, text) from public, anon, authenticated;
grant execute on function public.redeem_points(uuid, uuid, text) to service_role;

-- ============================================================================================
-- 8 · IN-TRANSACTION VERIFICATION.
--
--     Nothing below writes a row, so unlike a behavioural migration there is no sub-transaction
--     to roll back: every assertion is a catalogue read, plus ONE live resolution probe.
--
--     That probe is the only assertion here that is behaviour rather than shape. Catalogue
--     arithmetic can tell us one evaluate_checkout remains; it cannot tell us that PostgREST's
--     six-named-argument call now RESOLVES. So the block actually issues such a call and
--     inspects the error: 42883 (no such function) or 42725 (not unique) is a failure; anything
--     else — in practice 42501, since the function refuses a null auth.uid() before it touches
--     data — proves resolution succeeded, and the refusal means nothing was priced or written.
-- ============================================================================================
do $v825_verify$
declare
  v_sig text;
  v_cnt integer;
  v_state text;
begin
  /* --- Items 1 and 2: gone for anon, present for authenticated. --- */
  foreach v_sig in array array[
    'public.super_admin_list_businesses()',
    'public.platform_generate_improvement_report_v82(text, uuid[], uuid, date, date, text, timestamp with time zone)',
    'public.platform_get_enterprise_hierarchy_v82(text, uuid[], uuid, date, date, text, integer, timestamp with time zone, timestamp with time zone, uuid)',
    'public.platform_get_assigned_firm_report_v94(uuid, uuid, date, date)',
    'public.get_customer_intelligence_v83(uuid, uuid, date, date, integer, timestamp with time zone, timestamp with time zone, uuid)',
    'public.preview_campaign_audience_v155(uuid, text, text, uuid[], uuid)',
    'public.get_business_application_status_v95(uuid)'
  ]
  loop
    if pg_catalog.has_function_privilege('anon', to_regprocedure(v_sig), 'execute') then
      raise exception 'v825 verify: anon can still execute %', v_sig;
    end if;
    if not pg_catalog.has_function_privilege('authenticated', to_regprocedure(v_sig), 'execute') then
      raise exception 'v825 verify: authenticated LOST execute on % -- the revoke was too wide', v_sig;
    end if;
    if not pg_catalog.has_function_privilege('service_role', to_regprocedure(v_sig), 'execute') then
      raise exception 'v825 verify: service_role LOST execute on % -- the edge gateway would 500', v_sig;
    end if;
    /* PUBLIC must be gone too, or anon inherits the grant right back. Tested with aclexplode
       (grantee 0 IS the PUBLIC pseudo-role), not by looking for '=X/' in proacl::text: every
       grantee's entry contains that substring, so the text test would have failed on
       `authenticated=X/postgres` and reported a PUBLIC grant that was not there. A NULL proacl
       is the other half of the trap — it means DEFAULT privileges, and the default on a function
       is EXECUTE TO PUBLIC, so an unmentioned ACL is the most open state, not the most closed. */
    if (select proacl is null from pg_proc where oid = to_regprocedure(v_sig))
       or exists (select 1 from pg_proc pr, aclexplode(pr.proacl) a
                   where pr.oid = to_regprocedure(v_sig) and a.grantee = 0)
    then
      raise exception 'v825 verify: % still carries a PUBLIC execute grant', v_sig;
    end if;
  end loop;

  /* --- Item 3: the policies exist, still read USING (true), and are no longer TO PUBLIC. --- */
  select count(*) into v_cnt
    from pg_policies
   where schemaname = 'public'
     and (tablename, policyname) in (
       ('platform_capabilities_v518', 'platform_capabilities_v518_read'),
       ('whatsapp_template_registry_v551', 'whatsapp_template_registry_v551_read'))
     and cmd = 'SELECT'
     and qual = 'true'
     and roles::text[] @> array['authenticated', 'service_role']
     and not (roles::text[] @> array['public']);
  if v_cnt <> 2 then
    raise exception 'v825 verify: expected 2 read policies addressed to authenticated+service_role '
      'with USING (true) and no PUBLIC, found %', v_cnt;
  end if;

  /* --- Item 4: every one of the ten carries the pin. --- */
  foreach v_sig in array pg_temp.v825_pin_targets() loop
    if to_regprocedure(v_sig) is null then
      continue;  -- absent here; the pre-flight already named it and refused a total absence
    end if;
    if not exists (
      select 1 from pg_proc
       where oid = to_regprocedure(v_sig)
         and proconfig @> array['search_path=pg_catalog, public, app, pg_temp'])
    then
      raise exception 'v825 verify: % does not carry the pinned search_path (proconfig = %)',
        v_sig, coalesce((select proconfig::text from pg_proc where oid = to_regprocedure(v_sig)), 'NULL');
    end if;
  end loop;

  /* --- Item 5: the unscoped overload is gone and the scoped one survived. --- */
  if to_regprocedure('public.redeem_points(uuid, uuid)') is not null then
    raise exception 'v825 verify: public.redeem_points(uuid, uuid) is still present';
  end if;
  if to_regprocedure('public.redeem_points(uuid, uuid, text)') is null then
    raise exception 'v825 verify: the surviving three-argument redeem_points is gone -- redemption '
      'through merchant_scan_redemption_qr_v89/v93 would now fail';
  end if;
  if pg_catalog.has_function_privilege('anon', 'public.redeem_points(uuid, uuid, text)', 'execute')
     or pg_catalog.has_function_privilege('authenticated', 'public.redeem_points(uuid, uuid, text)', 'execute')
  then
    raise exception 'v825 verify: redeem_points(uuid, uuid, text) became API-executable';
  end if;

  /* --- Item 6, shape: exactly one evaluate_checkout, and it is the seven-argument one. --- */
  select count(*) into v_cnt
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'evaluate_checkout';
  if v_cnt <> 1 then
    raise exception 'v825 verify: % evaluate_checkout overloads remain, expected exactly 1', v_cnt;
  end if;
  if to_regprocedure('public.evaluate_checkout(uuid, uuid, uuid, jsonb, uuid, uuid, boolean)') is null then
    raise exception 'v825 verify: the one surviving evaluate_checkout is not the seven-argument form';
  end if;

  /* --- Item 6, behaviour: a SIX-named-argument call resolves. This is the assertion the whole
         item exists for; a count of overloads would not have caught a survivor that still
         collided. --- */
  begin
    perform public.evaluate_checkout(
      p_business        => '00000000-0000-0000-0000-000000000000'::uuid,
      p_branch          => null::uuid,
      p_client          => null::uuid,
      p_lines           => '[]'::jsonb,
      p_idempotency_key => '00000000-0000-0000-0000-000000000000'::uuid,
      p_tier_benefit    => null::uuid);
    /* Resolution succeeded AND the call returned instead of refusing. That should be impossible
       here (auth.uid() is null under a migration, and the function refuses that first), but if it
       ever happens the sub-transaction must not keep whatever it wrote: the sentinel throws it
       away. A verification block never leaves a row behind. */
    raise exception 'v825 probe sentinel' using errcode = 'P0825';
  exception
    when sqlstate 'P0825' then
      null;  -- expected only if the probe somehow priced a checkout; rolled back
    when undefined_function then
      raise exception 'v825 verify: a six-named-argument evaluate_checkout call no longer resolves '
        '(42883) -- the drop removed the wrong overload or p_birthday lost its default';
    when ambiguous_function then
      raise exception 'v825 verify: a six-named-argument evaluate_checkout call is STILL ambiguous '
        '(42725) -- the twin overload was not the only collision';
    when others then
      get stacked diagnostics v_state = returned_sqlstate;
      /* Any other error means the call bound to a function and that function ran far enough to
         complain about something of its own (42501 with no auth.uid(), typically). Resolved. */
      null;
  end;

  raise notice 'v825: 7 anon grants revoked, 2 read policies re-addressed, 10 search_paths pinned, '
    'redeem_points(uuid,uuid) and the six-argument evaluate_checkout dropped; a six-argument '
    'named call still resolves (probe sqlstate %)', coalesce(v_state, 'none');
end
$v825_verify$;

commit;
