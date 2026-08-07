-- Nestly v219 — the Products module stops being disabled for everyone.
--
-- Owner, repeatedly: "not all companies offer services - how about sale of products?",
-- "i need a product modules - instead of just services", and now "missing products (why still".
--
-- app.effective_platform_module_mode_v94 opened with an unconditional
--     if p_module='inventory' then return 'disabled','global_inventory_policy'
-- so NO tenant could ever reach the Products page, whatever their own configuration said. All
-- ten businesses carry 'inventory' in enabled_modules (it comes from the sector entitlement,
-- which business_sector_modules_guard_v75 makes read-only) and three already have active
-- products — and those products are sellable at the till, because the till is gated on 'till',
-- not 'inventory'. The platform was selling products it gave nobody a way to manage.
-- inventoryPage exists and is routed; it was simply unreachable.
--
-- The blanket line is removed so 'inventory' resolves down the same path as every other module:
-- a branch override, then a firm override, then the business's own entitlement. A business that
-- has not been entitled to products still does not get them, and a platform operator can still
-- withhold the module per firm or per branch. Nothing here grants a business anything it was
-- not already configured for.
--
-- customerintel is deliberately left disabled — it is a platform-only surface and the owner has
-- not asked for it.

begin;

do $patch$
declare d text; n text;
begin
  select pg_get_functiondef(p.oid) into d from pg_proc p join pg_namespace ns on ns.oid=p.pronamespace
  where ns.nspname='app' and p.proname='effective_platform_module_mode_v94';

  if position('global_inventory_policy' in d) = 0 then
    raise notice 'v219: inventory policy already removed';
    return;
  end if;

  n := replace(d,
E'  if p_module=''inventory'' then
    return query select ''disabled''::text,''global_inventory_policy''::text,null::bigint;
    return;
  elsif p_module=''customerintel'' then',
E'  -- v219: the blanket inventory disable is gone. Products now follow the business''s own
  -- enabled_modules like every other module, via the sector_entitlement branch below.
  if p_module=''customerintel'' then');
  if n = d then raise exception 'v219: inventory policy anchor not found'; end if;
  execute n;

  select pg_get_functiondef(p.oid) into d from pg_proc p join pg_namespace ns on ns.oid=p.pronamespace
  where ns.nspname='app' and p.proname='effective_platform_module_mode_v94';
  if position('global_inventory_policy' in d) > 0 then
    raise exception 'v219: inventory policy did not clear';
  end if;
  if position('global_platform_only_policy' in d) = 0 then
    raise exception 'v219: customerintel policy must be left untouched';
  end if;
end $patch$;

commit;
