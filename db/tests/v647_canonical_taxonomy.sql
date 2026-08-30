-- Rollback-only v647 acceptance suite: the v1 canonical taxonomy seed contains exactly
-- 48 nodes with no orphan level-3 node, and taxonomy_versions/taxonomy_nodes are immutable
-- once published (update/delete raise 42501 via app.taxonomy_guard_v647()).
-- Run after the complete canonical chain through v647 in a disposable database (or as a
-- rolled-back transaction directly against a prod-shaped instance).
begin;

create or replace function pg_temp.as_postgres() returns void language plpgsql as $$
begin
  execute 'reset role';
  perform set_config('request.jwt.claim.sub','',true);
  perform set_config('request.jwt.claims','{}',true);
end;
$$;
grant execute on function pg_temp.as_postgres() to public;

-- ---------------------------------------------------------------------------
-- D1/D-immutable. v647 taxonomy seed shape + immutability guard
-- ---------------------------------------------------------------------------
do $d$
declare
  n integer;
begin
  perform pg_temp.as_postgres();

  select count(*) into n from public.taxonomy_nodes where version_no = 1;
  if n <> 48 then
    raise exception 'D1: expected 48 nodes, found %', n;
  end if;

  if exists (select 1 from public.taxonomy_nodes c
              where c.version_no = 1 and c.level = 3
                and not exists (select 1 from public.taxonomy_nodes p
                                 where p.version_no = 1 and p.level = 2 and p.node_key = c.parent_key)) then
    raise exception 'D2: taxonomy v1 seed has an orphan level-3 node';
  end if;

  begin
    update public.taxonomy_versions set notes = 'tampered' where version_no = 1;
    raise exception 'D3: taxonomy_versions must be immutable once published';
  exception when sqlstate '42501' then null;
  end;

  begin
    delete from public.taxonomy_nodes where version_no = 1 and node_key = 'facial.hydration';
    raise exception 'D4: taxonomy_nodes must be immutable once published';
  exception when sqlstate '42501' then null;
  end;

  raise notice 'D OK: canonical taxonomy (48 nodes, no orphans, immutable)';
end
$d$;

reset role;
rollback;
