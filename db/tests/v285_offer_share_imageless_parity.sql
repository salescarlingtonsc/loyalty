-- Rollback-only acceptance for v285 — imageless offers share (v172/v173 parity).
-- The substantive assertions live in db/tests/v268_offer_share_page.sql, which exercises the
-- SAME function this migration redefines (v285 changes the function in place; the v268 suite
-- was updated in the same commit to assert the new parity rule, including that an offer whose
-- artwork is unpublished still resolves with a NULL image_url). This file exists so v285 has an
-- atomic rollback boundary of its own in the preflight map.
begin;
do $suite$
begin
  if not has_function_privilege('anon', 'public.offer_share_page_v268(uuid)', 'EXECUTE') then
    raise exception 'v285: anon EXECUTE must survive the redefinition';
  end if;
  if position('media.url is not null' in pg_get_functiondef(
       (select p.oid from pg_proc p join pg_namespace n on n.oid=p.pronamespace
         where n.nspname='public' and p.proname='offer_share_page_v268'))) > 0 then
    raise exception 'v285: the artwork predicate must be gone from the deployed function';
  end if;
  raise notice 'v285 acceptance: all assertions passed';
end $suite$;
rollback;
