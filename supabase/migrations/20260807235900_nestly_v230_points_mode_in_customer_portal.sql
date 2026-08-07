-- Nestly v230 — the owner's points-mode choice reaches the customer portal.
--
-- Owner: "ensure selection by owner will be reflected in the customer portal". v229 made the
-- choice and holds the server door (redemption intents are refused in tiers mode). This carries
-- the same instant switch into both wallet readers, so the portal renders ONE story:
-- tiers mode -> the tier ladder leads and the rewards section explains that points build the
-- tier; redeem mode -> rewards lead and the tier ladder does not appear as a second narrative.

begin;

do $patch$
declare d text; n text;
begin
  -- 1. The tier reader: mode rides inside the tier object the wallet already consumes.
  select pg_get_functiondef(p.oid) into d from pg_proc p join pg_namespace ns on ns.oid=p.pronamespace
  where ns.nspname='public' and p.proname='customer_get_effective_tier_v143';
  if position('points_mode' in d) = 0 then
    n := replace(d,
      E'  return jsonb_build_object(''tier'',jsonb_build_object(\n',
      E'  return jsonb_build_object(''tier'',jsonb_build_object(\n    ''points_mode'',(select points_mode from public.businesses where id=p_business),\n');
    if n = d then raise exception 'v230: tier reader anchor not found'; end if;
    execute n;
  end if;

  -- 2. The reward catalogue reader: mode rides beside the reward list.
  select pg_get_functiondef(p.oid) into d from pg_proc p join pg_namespace ns on ns.oid=p.pronamespace
  where ns.nspname='public' and p.proname='customer_get_reward_catalog';
  if position('points_mode' in d) = 0 then
    n := replace(d,
      E'  ) listed;\n\n  return v_result;\nend;',
      E'  ) listed;\n\n  -- v230: the one owner choice for what points are FOR, so the wallet tells one story.\n  v_result := v_result || jsonb_build_object(''points_mode'',\n    (select points_mode from public.businesses where id = v_context.business_id));\n\n  return v_result;\nend;');
    if n = d then raise exception 'v230: catalog reader anchor not found'; end if;
    execute n;
  end if;

  if (select count(*) from pg_proc p join pg_namespace ns on ns.oid=p.pronamespace
      where ns.nspname='public'
        and p.proname in ('customer_get_effective_tier_v143','customer_get_reward_catalog')
        and position('points_mode' in pg_get_functiondef(p.oid)) > 0) <> 2 then
    raise exception 'v230: a reader patch did not land';
  end if;
end $patch$;

commit;
