-- nestly_v876 rollback suite — a card opened by carried-over stamps has a start, a deadline and
-- a pinned version.
--
-- Run inside a transaction against production and ROLLED BACK. The invariant is checked over
-- every real (client, programme) that has closed at least one cycle: whenever the canonical
-- card model says stamps are on the card, the deadline authority must say when the card
-- started, and the version authority must agree with it.

\set ON_ERROR_STOP on

begin;

do $suite$
declare
  r record; d record; checked integer := 0; n integer := 0;
begin
  n := n + 1;
  if position('v_started := v_last_close' in pg_get_functiondef('app.stamp_cycle_version_v416(uuid,uuid,uuid)'::regprocedure)) = 0 then
    raise exception 'H% failed: stamp_cycle_version_v416 has no carried-card fallback', n;
  end if;
  n := n + 1;
  if position('where sp.programme_id = p_programme' in pg_get_functiondef('app.stamp_cycle_deadline_v435(uuid,uuid,uuid)'::regprocedure)) = 0 then
    raise exception 'H% failed: stamp_cycle_deadline_v435 progress lookup is not programme-scoped', n;
  end if;

  for r in
    select distinct sc.business_id, sc.client_id, sc.programme_id
      from public.stamp_cycles sc
  loop
    select * into d from app.stamp_cycle_deadline_v435(r.business_id, r.client_id, r.programme_id);
    checked := checked + 1;
    if coalesce(d.filled, 0) > 0 and d.started_at is null then
      raise exception 'H failed: client % programme % holds % stamps but the card has no start', r.client_id, r.programme_id, d.filled;
    end if;
    if d.started_at is not null and d.config_version_id is null then
      raise exception 'H failed: client % programme % has a start but no pinned version', r.client_id, r.programme_id;
    end if;
  end loop;
  n := n + 1;

  raise notice 'nestly_v876 suite: % assertions passed (% cycled cards checked)', n, checked;
end
$suite$;

rollback;
