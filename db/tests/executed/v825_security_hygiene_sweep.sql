-- EXECUTED acceptance fixture for nestly_v825
-- (db/migrations/20261007_nestly_v825_security_hygiene_sweep.sql).
--
-- Run: LC_ALL=C node scripts/db-tests/run.mjs --migrated-only --filter=v825
--
-- WHY THIS EXISTS. v825 closes a read-only production security audit of 2026-09-08. Six of its
-- items are privilege or catalogue facts, and a privilege regression is exactly the kind of change
-- that ships silently: nothing throws, no test goes red, the estate just becomes reachable again.
-- A later CREATE OR REPLACE on any of these functions, a re-run of an older migration, or a
-- restored snapshot can each hand `anon` its grant back. These assertions are the floor.
--
-- ASSERTIONS (one row each, with a fatal gate at the end):
--   T1   The seven audited SECURITY DEFINER readers are not executable by anon.
--   T2   ...and PUBLIC does not hand anon the grant back through the back door.
--   T3   ...and authenticated + service_role kept theirs, so no surface lost a capability.
--   T4   platform_capabilities_v518_read is TO authenticated, service_role -- not PUBLIC.
--   T5   whatsapp_template_registry_v551_read is likewise, and both still read USING (true).
--   T6   All ten advisor-flagged SECURITY INVOKER helpers in schema app carry the pinned
--        search_path in proconfig.
--   T7   ...and are still SECURITY INVOKER (a pin is not a licence to become DEFINER).
--   T8   public.redeem_points(uuid, uuid) -- the unscoped legacy balance read -- is gone.
--   T9   The surviving public.redeem_points(uuid, uuid, text) is present and still NOT
--        API-executable (anon and authenticated both false).
--   T10  Exactly one public.evaluate_checkout remains, and it is the seven-argument one.
--   T11  BEHAVIOUR: a six-NAMED-argument evaluate_checkout call resolves -- neither 42883 nor
--        42725. This is the assertion the whole item exists for; counting overloads would not
--        catch a survivor that still collided.
--   T12  No database body calls the dropped functions (the both-directions grep, re-run).
--   T6b  At least nine of the ten pin targets actually exist here -- so T6 cannot pass vacuously
--        on a cluster that is missing them. (nestly_v591a..e are invisible to the replay harness's
--        migration-discovery regex, so app.v591_max_attempts() is legitimately absent in a
--        rehearsal and present in production.)
--
-- Rolled back.
begin;

create temp table v825_out(seq integer, step text, outcome text, detail text) on commit drop;

create or replace function pg_temp.v825_note(
  p_seq integer, p_step text, p_ok boolean, p_detail text default null
) returns void language plpgsql as $$
begin
  insert into v825_out values (p_seq, p_step, case when p_ok then 'PASS' else 'FAIL' end, p_detail);
end
$$;

/* The seven public entry points item 1 and item 2 re-address, by exact identity signature. A
   revoke aimed at a signature that no longer exists is a no-op, so the signature is part of the
   assertion, not a convenience. */
create or replace function pg_temp.v825_audited() returns text[] language sql immutable as $$
  select array[
    'public.super_admin_list_businesses()',
    'public.platform_generate_improvement_report_v82(text, uuid[], uuid, date, date, text, timestamp with time zone)',
    'public.platform_get_enterprise_hierarchy_v82(text, uuid[], uuid, date, date, text, integer, timestamp with time zone, timestamp with time zone, uuid)',
    'public.platform_get_assigned_firm_report_v94(uuid, uuid, date, date)',
    'public.get_customer_intelligence_v83(uuid, uuid, date, date, integer, timestamp with time zone, timestamp with time zone, uuid)',
    'public.preview_campaign_audience_v155(uuid, text, text, uuid[], uuid)',
    'public.get_business_application_status_v95(uuid)'
  ]
$$;

/* The ten SECURITY INVOKER helpers item 4 pins. */
create or replace function pg_temp.v825_pinned() returns text[] language sql immutable as $$
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

do $v825_test$
declare
  v_sig text;
  v_bad text[] := array[]::text[];
  v_absent text[] := array[]::text[];
  v_cnt integer;
  v_state text;
  v_resolved boolean := false;
begin
  ---------------------------------------------------------------------------------------------
  -- T1 · anon cannot execute any of the seven.
  ---------------------------------------------------------------------------------------------
  v_bad := array[]::text[];
  foreach v_sig in array pg_temp.v825_audited() loop
    if to_regprocedure(v_sig) is null then
      v_bad := v_bad || (v_sig || ' [MISSING]');
    elsif pg_catalog.has_function_privilege('anon', to_regprocedure(v_sig), 'execute') then
      v_bad := v_bad || v_sig;
    end if;
  end loop;
  perform pg_temp.v825_note(1, 'T1 anon cannot execute the seven audited readers',
    cardinality(v_bad) = 0, array_to_string(v_bad, ' | '));

  ---------------------------------------------------------------------------------------------
  -- T2 · ...and none of them carries a PUBLIC execute grant. Four of the seven did before v825
  --      (`=X/postgres` in proacl); revoking anon alone would have left anon executing them
  --      through PUBLIC, and T1 would still have gone green because has_function_privilege
  --      resolves PUBLIC. This is the check that makes T1 mean what it says.
  ---------------------------------------------------------------------------------------------
  v_bad := array[]::text[];
  foreach v_sig in array pg_temp.v825_audited() loop
    /* aclexplode, not a substring of proacl::text: grantee 0 IS the PUBLIC pseudo-role, whereas
       every grantee's ACL entry contains '=X/' and a text test would flag `authenticated=X/postgres`
       as a PUBLIC grant. A NULL proacl is the other trap -- it means DEFAULT privileges, and the
       default on a function is EXECUTE TO PUBLIC, so "no ACL recorded" is the most open state. */
    if to_regprocedure(v_sig) is not null
       and ((select proacl is null from pg_proc where oid = to_regprocedure(v_sig))
            or exists (select 1 from pg_proc pr, aclexplode(pr.proacl) a
                        where pr.oid = to_regprocedure(v_sig) and a.grantee = 0))
    then
      v_bad := v_bad || v_sig;
    end if;
  end loop;
  perform pg_temp.v825_note(2, 'T2 no PUBLIC execute grant hands anon the seven back',
    cardinality(v_bad) = 0, array_to_string(v_bad, ' | '));

  ---------------------------------------------------------------------------------------------
  -- T3 · The console and the edge gateway keep working: authenticated and service_role kept
  --      execute on all seven. A revoke that overshoots is a worse outage than the finding.
  ---------------------------------------------------------------------------------------------
  v_bad := array[]::text[];
  foreach v_sig in array pg_temp.v825_audited() loop
    if to_regprocedure(v_sig) is null then
      v_bad := v_bad || (v_sig || ' [MISSING]');
    else
      if not pg_catalog.has_function_privilege('authenticated', to_regprocedure(v_sig), 'execute') then
        v_bad := v_bad || (v_sig || ' [authenticated]');
      end if;
      if not pg_catalog.has_function_privilege('service_role', to_regprocedure(v_sig), 'execute') then
        v_bad := v_bad || (v_sig || ' [service_role]');
      end if;
    end if;
  end loop;
  perform pg_temp.v825_note(3, 'T3 authenticated and service_role kept execute on all seven',
    cardinality(v_bad) = 0, array_to_string(v_bad, ' | '));

  ---------------------------------------------------------------------------------------------
  -- T4 / T5 · The two catalogue read policies are addressed, and the predicate is unchanged.
  --           USING (true) is deliberate here -- who may read is decided by the grant and the
  --           role list, not by a row predicate -- so the test asserts it stayed `true` rather
  --           than allowing a narrowing that would look like an improvement and break the
  --           console's capability lookup.
  ---------------------------------------------------------------------------------------------
  select count(*) into v_cnt
    from pg_policies
   where schemaname = 'public'
     and tablename = 'platform_capabilities_v518'
     and policyname = 'platform_capabilities_v518_read'
     and cmd = 'SELECT'
     and qual = 'true'
     and roles::text[] @> array['authenticated', 'service_role']
     and not (roles::text[] @> array['public']);
  perform pg_temp.v825_note(4, 'T4 platform_capabilities_v518_read is TO authenticated,service_role',
    v_cnt = 1,
    'matching policies=' || v_cnt || ' roles=' || coalesce(
      (select roles::text from pg_policies
        where tablename = 'platform_capabilities_v518'
          and policyname = 'platform_capabilities_v518_read'), 'ABSENT'));

  select count(*) into v_cnt
    from pg_policies
   where schemaname = 'public'
     and tablename = 'whatsapp_template_registry_v551'
     and policyname = 'whatsapp_template_registry_v551_read'
     and cmd = 'SELECT'
     and qual = 'true'
     and roles::text[] @> array['authenticated', 'service_role']
     and not (roles::text[] @> array['public']);
  perform pg_temp.v825_note(5, 'T5 whatsapp_template_registry_v551_read is TO authenticated,service_role',
    v_cnt = 1,
    'matching policies=' || v_cnt || ' roles=' || coalesce(
      (select roles::text from pg_policies
        where tablename = 'whatsapp_template_registry_v551'
          and policyname = 'whatsapp_template_registry_v551_read'), 'ABSENT'));

  ---------------------------------------------------------------------------------------------
  -- T6 · Every one of the ten carries the pin, verbatim.
  ---------------------------------------------------------------------------------------------
  v_bad := array[]::text[];
  foreach v_sig in array pg_temp.v825_pinned() loop
    if to_regprocedure(v_sig) is null then
      /* Absent, not unpinned. scripts/db-tests/run.mjs discovers pending migrations with
         /_nestly_v(\d+)[_.]/, which does not match nestly_v591a..v591e, so
         app.v591_max_attempts() does not exist in a rehearsal cluster even though production has
         it. T6b below bounds how much of this the suite will tolerate, so an absence cannot grow
         into "nothing was pinned and everything passed". */
      v_absent := v_absent || v_sig;
    elsif not exists (
      select 1 from pg_proc
       where oid = to_regprocedure(v_sig)
         and proconfig @> array['search_path=pg_catalog, public, app, pg_temp'])
    then
      v_bad := v_bad || (v_sig || ' [' || coalesce(
        (select proconfig::text from pg_proc where oid = to_regprocedure(v_sig)), 'NULL') || ']');
    end if;
  end loop;
  perform pg_temp.v825_note(6,
    'T6 every advisor-flagged app helper PRESENT here carries the pinned search_path',
    cardinality(v_bad) = 0,
    'unpinned=' || array_to_string(v_bad, ' | ')
      || ' absent=' || array_to_string(v_absent, ' | '));

  ---------------------------------------------------------------------------------------------
  -- T6b · ...and at least nine of the ten were actually present to be pinned. Without this, a
  --       cluster missing all ten would sail through T6 with an empty failure list.
  ---------------------------------------------------------------------------------------------
  perform pg_temp.v825_note(13, 'T6b at least 9 of the 10 pin targets exist in this cluster',
    cardinality(pg_temp.v825_pinned()) - cardinality(v_absent) >= 9,
    'present=' || (cardinality(pg_temp.v825_pinned()) - cardinality(v_absent)));

  ---------------------------------------------------------------------------------------------
  -- T7 · ...and are still SECURITY INVOKER. Pinning a search_path is the cheap half of the
  --      advisor's finding; the expensive half would be somebody "fixing" it by making the
  --      helper DEFINER, which changes who its callers are running as.
  ---------------------------------------------------------------------------------------------
  v_bad := array[]::text[];
  foreach v_sig in array pg_temp.v825_pinned() loop
    if to_regprocedure(v_sig) is not null
       and (select prosecdef from pg_proc where oid = to_regprocedure(v_sig))
    then
      v_bad := v_bad || v_sig;
    end if;
  end loop;
  perform pg_temp.v825_note(7, 'T7 the ten pinned helpers are still SECURITY INVOKER',
    cardinality(v_bad) = 0, array_to_string(v_bad, ' | '));

  ---------------------------------------------------------------------------------------------
  -- T8 · The unscoped legacy redemption is gone. It summed points_ledger with NO programme_id
  --      filter and then drained a programme-scoped batch set -- the v312/v381/v813 defect class.
  ---------------------------------------------------------------------------------------------
  perform pg_temp.v825_note(8, 'T8 public.redeem_points(uuid, uuid) is dropped',
    to_regprocedure('public.redeem_points(uuid, uuid)') is null);

  ---------------------------------------------------------------------------------------------
  -- T9 · The scoped survivor is present and still not reachable from a browser. Its
  --      {postgres, service_role} audience is deliberately narrower than API-executable;
  --      merchant_scan_redemption_qr_v89/v93 reach it as SECURITY DEFINER callers, not as anon.
  ---------------------------------------------------------------------------------------------
  perform pg_temp.v825_note(9, 'T9 redeem_points(uuid,uuid,text) survives and is not API-executable',
    to_regprocedure('public.redeem_points(uuid, uuid, text)') is not null
    and not pg_catalog.has_function_privilege('anon', 'public.redeem_points(uuid, uuid, text)', 'execute')
    and not pg_catalog.has_function_privilege('authenticated', 'public.redeem_points(uuid, uuid, text)', 'execute'),
    'acl=' || coalesce((select proacl::text from pg_proc
                         where oid = to_regprocedure('public.redeem_points(uuid, uuid, text)')), 'ABSENT'));

  ---------------------------------------------------------------------------------------------
  -- T10 · Exactly one evaluate_checkout, and it is the seven-argument form.
  ---------------------------------------------------------------------------------------------
  select count(*) into v_cnt
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'evaluate_checkout';
  perform pg_temp.v825_note(10, 'T10 exactly one evaluate_checkout remains, the 7-argument one',
    v_cnt = 1
    and to_regprocedure('public.evaluate_checkout(uuid, uuid, uuid, jsonb, uuid, uuid, boolean)') is not null,
    'overloads=' || v_cnt);

  ---------------------------------------------------------------------------------------------
  -- T11 · BEHAVIOUR. Issue an actual six-NAMED-argument call, the shape that raised 42725 in
  --       production, and classify the outcome by SQLSTATE:
  --         42883 undefined_function -> the wrong overload was dropped, or p_birthday lost its
  --                                     default, and a six-argument caller now gets nothing;
  --         42725 ambiguous_function -> the collision survived;
  --         anything else            -> the call BOUND to a function and that function ran far
  --                                     enough to raise a complaint of its own (42501: the first
  --                                     statement of evaluate_checkout refuses a null auth.uid()).
  --                                     Resolution is what is being tested, so that is a pass.
  --       Wrapped in a sub-transaction that always unwinds, so even the impossible case where the
  --       probe priced a checkout leaves nothing behind.
  ---------------------------------------------------------------------------------------------
  begin
    begin
      perform public.evaluate_checkout(
        p_business        => '00000000-0000-0000-0000-000000000000'::uuid,
        p_branch          => null::uuid,
        p_client          => null::uuid,
        p_lines           => '[]'::jsonb,
        p_idempotency_key => '00000000-0000-0000-0000-000000000000'::uuid,
        p_tier_benefit    => null::uuid);
      v_resolved := true;
      v_state := 'returned';
      raise exception 'v825 probe sentinel' using errcode = 'P0825';
    exception
      when sqlstate 'P0825' then
        null;                       -- resolved and returned; anything it wrote is now unwound
      when undefined_function then
        v_resolved := false; v_state := '42883';
      when ambiguous_function then
        v_resolved := false; v_state := '42725';
      when others then
        get stacked diagnostics v_state = returned_sqlstate;
        v_resolved := true;         -- it bound to a function; the complaint is that function's own
    end;
  end;
  perform pg_temp.v825_note(11, 'T11 a six-named-argument evaluate_checkout call resolves',
    v_resolved, 'sqlstate=' || coalesce(v_state, 'none'));

  ---------------------------------------------------------------------------------------------
  -- T12 · The both-directions grep, re-run against the live catalogue. PL/pgSQL resolves function
  --       names at run time, so a dropped function does not break its callers until one of them
  --       is next executed. The only way this stays true is to keep asserting it.
  ---------------------------------------------------------------------------------------------
  select coalesce(
           array_agg(n.nspname || '.' || p.proname order by n.nspname || '.' || p.proname),
           array[]::text[])
    into v_bad
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname in ('public', 'app')
     and p.prosrc like '%redeem_points(%'
     and p.oid is distinct from to_regprocedure('public.redeem_points(uuid, uuid, text)');
  perform pg_temp.v825_note(12,
    'T12 the only bodies naming redeem_points( are the two merchant QR scanners',
    v_bad = array['public.merchant_scan_redemption_qr_v89',
                  'public.merchant_scan_redemption_qr_v93'],
    array_to_string(v_bad, ' | '));
end
$v825_test$;

select seq, step, outcome, detail from v825_out order by seq;

do $v825_gate$
declare
  v_failed integer;
  v_detail text;
begin
  select count(*), string_agg(step || ' :: ' || coalesce(detail, ''), E'\n')
    into v_failed, v_detail
    from v825_out where outcome = 'FAIL';
  if v_failed > 0 then
    raise exception E'v825 acceptance: % assertion(s) failed\n%', v_failed, v_detail;
  end if;
  if (select count(*) from v825_out) <> 13 then
    raise exception 'v825 acceptance: expected 13 assertions, recorded %',
      (select count(*) from v825_out);
  end if;
  raise notice 'v825 acceptance: 13/13 PASS';
end
$v825_gate$;

rollback;
