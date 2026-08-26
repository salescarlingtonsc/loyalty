-- Rollback-only acceptance for nestly_v554 — the live v154 family gets repo provenance.
-- Run: supabase db query --linked -f db/tests/v554_v154_family_provenance.sql
-- Any row whose value starts with FAIL is a failure. Nothing is committed.
--
-- This runs against PRODUCTION, where the five functions ALREADY exist — v554 is a provenance
-- capture, not a behaviour change, so this acceptance checks EQUALITY, not a before/after delta:
--
--   01  all five functions exist with the production identity signatures (to_regprocedure).
--   02  md5(pg_get_functiondef(oid)) of each equals the md5 of the corresponding body as written
--       in the migration file db/migrations/20260827_nestly_v554_v154_family_provenance.sql. The
--       five expected md5s are hardcoded here — the main session verified them identical between
--       production and the local rebuild at capture time (2026-08-27). A mismatch means either
--       production changed after capture (report it, do not overwrite blindly) or the capture
--       itself drifted — either way this suite's job is to notice, not to fix.
--   03  grants: authenticated has EXECUTE on all five; anon has EXECUTE on none.
--   04  public.staff_list_customers_v154's source contains the literal
--       'client_points_balance_v409' — the nestly_v544 correction is still present in the
--       captured body (it reads the canonical points primitive, not a stale duplicate).
--
-- ROLLBACK OF THE MIGRATION ITSELF: rolling back v554 means DROPping the five captured
-- functions. That is NOT safe to do casually. preview_campaign_audience_v154 resolves
-- staff_list_customers_v154 at run time (PL/pgSQL late-binds by name), and both app helpers
-- (app.resolve_reporting_branch_scope_v154, app.reporting_scope_label_v154) are called by the
-- family itself and by save_promotion_scope_v154 (a repo-built function outside this capture).
-- Dropping any of the five breaks those callers silently, at call time, not at DROP time. The
-- capture has zero behavioural effect on production — it only lets a rebuilt database reproduce
-- what already runs live — so the only legitimate reason to roll it back is a faulty capture
-- (wrong body, wrong grants, wrong signature), and the correct remedy for that is re-capturing
-- the live definitions verbatim, never dropping the functions.

begin;

create temp table _r(check_id text, value text) on commit drop;

-- 01 — existence with production identity signatures
do $exists$
declare
  missing text;
begin
  select string_agg(fn, ', ') into missing from (values
    ('app.resolve_reporting_branch_scope_v154(uuid,text,uuid[],uuid)'),
    ('app.reporting_scope_label_v154(uuid,text,uuid[],uuid)'),
    ('public.staff_list_customers_v154(uuid,text,text,text,uuid[],uuid,integer,integer)'),
    ('public.get_dashboard_summary_v154(uuid,date,date,text,uuid[],uuid)'),
    ('public.preview_campaign_audience_v154(uuid,text,text,uuid[],uuid)')
  ) v(fn) where to_regprocedure(fn) is null;

  insert into _r values ('01 all five v154 functions exist with production signatures',
    case when missing is null then 'PASS'
      else pg_catalog.format('FAIL missing: %s', missing) end);
end
$exists$;

-- 02 — captured body hash equals the migration file's hash (provenance equality, not a diff)
do $hashes$
declare
  expected jsonb := jsonb_build_object(
    'app.resolve_reporting_branch_scope_v154(uuid,text,uuid[],uuid)', '78a67d39e07c95e7b292fb5336fdfc1f',
    'app.reporting_scope_label_v154(uuid,text,uuid[],uuid)', '818f30f5c519c2b5a71cd6ca1813e2c0',
    'public.staff_list_customers_v154(uuid,text,text,text,uuid[],uuid,integer,integer)', 'befd9082957f0f0b088fe712f66d280c',
    'public.get_dashboard_summary_v154(uuid,date,date,text,uuid[],uuid)', '344c5a777266b2a5654188e0d3fd2c46',
    'public.preview_campaign_audience_v154(uuid,text,text,uuid[],uuid)', '23bc1341e5c574709ceab27ba1abfcc1'
  );
  fn text; want text; got text; oid_ regprocedure;
  bad integer := 0; note text := '';
begin
  for fn, want in select * from jsonb_each_text(expected) loop
    oid_ := to_regprocedure(fn);
    if oid_ is null then
      bad := bad + 1;
      note := note || pg_catalog.format('[%s: function missing, cannot hash] ', fn);
      continue;
    end if;
    got := md5(pg_get_functiondef(oid_::oid));
    if got is distinct from want then
      bad := bad + 1;
      note := note || pg_catalog.format('[%s: expected %s, live is %s] ', fn, want, got);
    end if;
  end loop;

  insert into _r values ('02 live body md5 equals the migration-file body md5 for all five',
    case when bad = 0 then 'PASS' else pg_catalog.format('FAIL %s: %s', bad, note) end);
end
$hashes$;

-- 03 — grants: authenticated has EXECUTE on all five; anon has EXECUTE on none
do $grants$
declare
  fn text;
  bad integer := 0; note text := '';
  fns text[] := array[
    'app.resolve_reporting_branch_scope_v154(uuid,text,uuid[],uuid)',
    'app.reporting_scope_label_v154(uuid,text,uuid[],uuid)',
    'public.staff_list_customers_v154(uuid,text,text,text,uuid[],uuid,integer,integer)',
    'public.get_dashboard_summary_v154(uuid,date,date,text,uuid[],uuid)',
    'public.preview_campaign_audience_v154(uuid,text,text,uuid[],uuid)'
  ];
begin
  foreach fn in array fns loop
    if to_regprocedure(fn) is null then
      bad := bad + 1;
      note := note || pg_catalog.format('[%s: function missing, cannot check grants] ', fn);
      continue;
    end if;
    if not has_function_privilege('authenticated', fn, 'EXECUTE') then
      bad := bad + 1;
      note := note || pg_catalog.format('[%s: authenticated lacks EXECUTE] ', fn);
    end if;
    if has_function_privilege('anon', fn, 'EXECUTE') then
      bad := bad + 1;
      note := note || pg_catalog.format('[%s: anon HAS EXECUTE (should not)] ', fn);
    end if;
  end loop;

  insert into _r values ('03 authenticated has EXECUTE on all five; anon has EXECUTE on none',
    case when bad = 0 then 'PASS' else pg_catalog.format('FAIL %s: %s', bad, note) end);
end
$grants$;

-- 04 — staff_list_customers_v154 still reads the canonical points primitive (nestly_v544 survived)
do $v544$
declare
  oid_ regprocedure := to_regprocedure(
    'public.staff_list_customers_v154(uuid,text,text,text,uuid[],uuid,integer,integer)');
  src text;
begin
  if oid_ is null then
    insert into _r values ('04 staff_list_customers_v154 body still calls client_points_balance_v409',
      'FAIL function missing');
    return;
  end if;
  src := pg_get_functiondef(oid_::oid);
  insert into _r values ('04 staff_list_customers_v154 body still calls client_points_balance_v409',
    case when src ilike '%client_points_balance_v409%' then 'PASS'
      else 'FAIL literal not found in the captured body' end);
end
$v544$;

select check_id, value from _r order by check_id;

rollback;
