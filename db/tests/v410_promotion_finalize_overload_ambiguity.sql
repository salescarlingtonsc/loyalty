-- Rollback-only acceptance for v410 — one finalize function per name.
--   supabase db query --linked -f db/tests/v410_promotion_finalize_overload_ambiguity.sql
-- Any row whose result starts with FAIL is a failure. Nothing is committed.
--
-- Owner, 2026-08-21 (photo 1): "Update published offer" -> "Offer was not published." and the
-- generic "Something went wrong on our side." No promotion could be published or updated at all.
--
-- Proved against production by calling the RPC unauthenticated and reading the error:
--   PGRST203 "Could not choose the best candidate function between:
--     public.business_finalize_promotion_v155(... p_expected_content_version => bigint ...)
--     public.business_finalize_promotion_v155(... p_expected_content_version => integer ...)"
--
-- The three expected-version parameters were `bigint` from v104 through v280. v378 (v155) and
-- v379 (v154) re-declared them `integer`. `create or replace function` keys on ARGUMENT TYPES, so
-- that did not replace the function — it created a second one. PostgREST cannot choose between
-- two candidates that differ only by integer-vs-bigint for a JSON number, so every finalize call
-- failed before reaching the database, and v380's circuit breaker was never reached either.
--
-- This suite does not depend on production state: it builds both overloads from scratch under a
-- throwaway name-alike, applies the same DROP the migration applies, and proves that exactly one
-- candidate survives and that it is the bigint one. Run it against production too — the last two
-- checks read the REAL catalogue and are the ones that prove the outage is over.

begin;

create temp table _r(k text, v text) on commit drop;

-- ---------------------------------------------------------------- 1 - the shape of the defect
-- Two functions, same name, differing only in integer-vs-bigint. This is what v378/v379 produced.
create function pg_temp.v410_probe(p_a uuid, p_v integer) returns text
  language sql immutable as $$ select 'integer' $$;
create function pg_temp.v410_probe(p_a uuid, p_v bigint) returns text
  language sql immutable as $$ select 'bigint' $$;

insert into _r values('01_twin_overloads_exist',
  case when (select count(*) from pg_catalog.pg_proc p
             join pg_catalog.pg_namespace n on n.oid=p.pronamespace
             where p.proname='v410_probe' and n.nspname like 'pg_temp%')=2
       then 'PASS both overloads present (the v378/v379 outcome)'
       else 'FAIL expected exactly two overloads' end);

-- A caller that does not pin the integer width cannot choose between them. Plain SQL hides this:
-- the literal 1 is already `integer`, so an SQL caller silently binds the integer overload and
-- everything looks fine — which is exactly why this shipped. PostgREST does not have that luxury.
-- It binds by NAME from JSON, where a number is equally good as integer or as bigint, and reports
-- the tie as PGRST203. `smallint` reproduces the same tie inside Postgres: it promotes implicitly
-- to integer AND to bigint, both at one step, so neither candidate is preferred.
do $$
begin
  begin
    perform pg_temp.v410_probe('11111111-1111-4111-8111-111111111111'::uuid, 1::smallint);
    insert into _r values('02_ambiguous_before_drop','FAIL the call resolved when it should not');
  exception
    when ambiguous_function then
      insert into _r values('02_ambiguous_before_drop','PASS 42725 ambiguous_function - the same tie PostgREST reports as PGRST203');
    when others then
      insert into _r values('02_ambiguous_before_drop','FAIL unexpected '||sqlstate||' '||sqlerrm);
  end;
end $$;

-- And the SQL-caller blind spot itself, recorded so nobody re-learns it the hard way: an integer
-- literal binds cleanly, so a rehearsal written in plain SQL passes over a broken function pair.
-- v380's own suite passed for this reason.
insert into _r values('02b_sql_literal_hides_it',
  case when pg_temp.v410_probe('11111111-1111-4111-8111-111111111111'::uuid, 1)='integer'
       then 'PASS an SQL integer literal binds one overload silently - why rehearsals missed this'
       else 'FAIL expected the integer literal to bind the integer overload' end);

-- ---------------------------------------------------------------- 2 - the fix, and its effect
drop function if exists pg_temp.v410_probe(uuid, integer);

insert into _r values('03_one_candidate_after_drop',
  case when (select count(*) from pg_catalog.pg_proc p
             join pg_catalog.pg_namespace n on n.oid=p.pronamespace
             where p.proname='v410_probe' and n.nspname like 'pg_temp%')=1
       then 'PASS exactly one candidate remains'
       else 'FAIL drop did not leave exactly one candidate' end);

insert into _r values('04_survivor_is_bigint',
  case when pg_temp.v410_probe('11111111-1111-4111-8111-111111111111'::uuid, 1)='bigint'
       then 'PASS the surviving overload is the bigint one (the canonical v104/v280 declaration)'
       else 'FAIL the integer overload survived' end);

-- ---------------------------------------------------------------- 3 - the real catalogue
-- Against production these two are the acceptance criteria. Before the migration each name has
-- two rows; after it, exactly one, and its version parameters are bigint.
insert into _r
select '05_live_v155_candidates',
  case count(*) when 1 then 'PASS exactly one business_finalize_promotion_v155'
    when 0 then 'SKIP function not present in this database'
    else 'FAIL '||count(*)||' overloads still present - PostgREST cannot resolve the call' end
from pg_catalog.pg_proc p join pg_catalog.pg_namespace n on n.oid=p.pronamespace
where n.nspname='public' and p.proname='business_finalize_promotion_v155';

insert into _r
select '06_live_v154_candidates',
  case count(*) when 1 then 'PASS exactly one business_finalize_promotion_v154'
    when 0 then 'SKIP function not present in this database'
    else 'FAIL '||count(*)||' overloads still present - PostgREST cannot resolve the call' end
from pg_catalog.pg_proc p join pg_catalog.pg_namespace n on n.oid=p.pronamespace
where n.nspname='public' and p.proname='business_finalize_promotion_v154';

-- The survivor must be the bigint declaration: the integer twin is the accidental one, and it is
-- also the one WITHOUT v380's circuit breaker.
insert into _r
select '07_live_survivor_is_bigint',
  case when count(*)=0 then 'SKIP function not present in this database'
       when count(*) filter (where pg_catalog.pg_get_function_identity_arguments(p.oid)
                                   like '%p_expected_content_version bigint%')=count(*)
       then 'PASS every surviving finalize declares bigint version parameters'
       else 'FAIL an integer-typed finalize overload is still present' end
from pg_catalog.pg_proc p join pg_catalog.pg_namespace n on n.oid=p.pronamespace
where n.nspname='public' and p.proname in
  ('business_finalize_promotion_v154','business_finalize_promotion_v155');

select k as check, v as result from _r order by k;

rollback;
