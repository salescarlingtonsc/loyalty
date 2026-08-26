-- nestly_v555 — an untrustworthy pot shows NO balance, never a merged one (LOYALTY-008).
--
-- OWNER RULING 2026-08-27: fail-closed.
--
-- app.programme_balance_scope_v312 answers 'business_pot' exactly when the pot data cannot be
-- trusted: a pot migration is pending or running, or the ledger and batches disagree per
-- (client, programme). Five reader sites treated that signal as permission to SUM EVERY POT:
--
--     (v_scope <> 'programme_pot' or <row>.programme_id is not distinct from v_live)
--
-- i.e. "if the pots are inconsistent, merge them all" — the exact cross-unit arithmetic that
-- produced the 940-for-139 customer display (nestly_v544) and the 3155-points-plus-stamps AI
-- evidence (nestly_v545). Measured incidence today: all 8 businesses with ledger rows resolve
-- to programme_pot, so nothing is actively mis-served — this closes the latent branch before a
-- tenant ever lands on it.
--
-- THE TRANSFORM, uniform across all five sites: OR becomes AND.
--
--     (v_scope = 'programme_pot' and <row>.programme_id is not distinct from v_live)
--
-- Under business_pot no ledger row qualifies: balances read 0, expiring batches read empty. A
-- zero is honest here — the alternative was a number in no particular unit. Surfaces that
-- EXPOSE the scope value (customer_get_loyalty_details, customer_get_reward_catalog,
-- customer_get_effective_tier_v143) are untouched: they already delegate their balance to
-- app.client_points_balance_v409 and their scope field now truthfully describes a fail-closed
-- state.
--
-- Patched functions (5 sites): app.client_points_balance_v409 (1),
-- public.staff_get_customer_actionable_loyalty_v145 (2: ledger + batches),
-- public.staff_list_customers_v155 (1), public.staff_list_customers_v129 (1, inline-call form).
--
-- ROLLBACK: db/tests/v555_business_pot_fails_closed.sql

begin;

do $patch$
declare r record; d text; n text; v_sites integer := 0; v_before integer; v_fn_sites integer;
begin
  for r in
    select p.oid, ns.nspname, p.proname
      from pg_proc p join pg_namespace ns on ns.oid=p.pronamespace
     where (ns.nspname='app' and p.proname='client_points_balance_v409')
        or (ns.nspname='public' and p.proname in
            ('staff_get_customer_actionable_loyalty_v145','staff_list_customers_v155',
             'staff_list_customers_v129'))
  loop
    d := pg_get_functiondef(r.oid);
    v_before := (length(d) - length(replace(d, '<> ''programme_pot''', ''))) / length('<> ''programme_pot''');

    -- local-variable form: (v_scope|v_balance_scope) <> 'programme_pot' or <qual>.programme_id ...
    n := regexp_replace(d,
      '\((v_scope|v_balance_scope) <> ''programme_pot''\s+or\s+(\w+\.programme_id is not distinct from (?:v_live_programme|v_live))\)',
      '(\1 = ''programme_pot'' and \2)', 'g');

    -- inline-call form (staff_list_customers_v129)
    n := regexp_replace(n,
      '\(app\.programme_balance_scope_v312\(p_business\) <> ''programme_pot''\s+or\s+(ledger\.programme_id is not distinct from app\.live_balance_programme_v381\(p_business\))\)',
      '(app.programme_balance_scope_v312(p_business) = ''programme_pot'' and \1)', 'g');

    if n = d then
      if v_before > 0 then
        raise exception 'v555: %.% carries % merge site(s) the transform did not match',
          r.nspname, r.proname, v_before;
      end if;
      raise notice 'v555: %.% already fails closed', r.nspname, r.proname;
      continue;
    end if;

    v_fn_sites := v_before - (length(n) - length(replace(n, '<> ''programme_pot''', ''))) / length('<> ''programme_pot''');
    execute n;
    v_sites := v_sites + v_fn_sites;
    raise notice 'v555: %.% — % site(s) now fail closed', r.nspname, r.proname, v_fn_sites;
  end loop;

  if v_sites not in (0, 5) then
    raise exception 'v555: expected all 5 sites in one pass (or 0 on rerun), changed %', v_sites;
  end if;
end
$patch$;

do $verify$
declare bad text;
begin
  select string_agg(n.nspname||'.'||p.proname, ', ') into bad
    from pg_proc p join pg_namespace n on n.oid=p.pronamespace
   where n.nspname in ('public','app')
     and p.prosrc like '%programme_balance_scope_v312%'
     and p.prosrc like '%<> ''programme_pot''%';
  if bad is not null then
    raise exception 'v555: a merge-on-inconsistency branch survives in: %', bad;
  end if;
end
$verify$;

commit;
