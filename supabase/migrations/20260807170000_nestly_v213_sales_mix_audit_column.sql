-- NESTLY v213 — the "what do you sell?" toggle could never save.
--
-- business_set_sales_mix_v184 (mine, earlier today) wrote its audit row into an audit_log column
-- called "meta". That column does not exist and never did — it is "detail", which is what every
-- other writer in this schema uses. The insert is the LAST statement in the function, so it threw
-- 42703 and rolled the whole transaction back: an owner toggling "we sell products" got an error
-- and the setting silently stayed exactly as it was.
--
-- That is why Hougang ABC had seven active products and products switched OFF. I migrated their
-- menu from services to products earlier today, and the toggle that would have turned the module
-- on could not commit. Their menu has been unsellable ever since.
--
-- Patched as a single token replacement against the deployed definition rather than a rewrite:
-- the function returns json (not jsonb), so create-or-replace cannot change its shape, and
-- retyping the body would risk drifting from what is actually running.
--
-- Note for anyone reading the toggle later: "sells products" is modelled as the INVENTORY module,
-- not a module named "products". I checked the wrong key first and briefly believed the toggle
-- was still broken after the fix.

begin;

do $patch$
declare v_src text; v_new text;
begin
  select pg_get_functiondef(p.oid) into v_src
    from pg_proc p join pg_namespace n on n.oid=p.pronamespace
   where n.nspname='public' and p.proname='business_set_sales_mix_v184';
  if v_src is null then
    raise exception 'business_set_sales_mix_v184 is missing';
  end if;
  v_new := replace(v_src,
    'insert into public.audit_log(business_id, actor, action, entity, entity_id, meta)',
    'insert into public.audit_log(business_id, actor, action, entity, entity_id, detail)');
  if v_new = v_src then
    -- already fixed, or the shape changed; either way do not install a half-patched function
    raise notice 'v213: no meta column reference found, leaving the function as it is';
  else
    execute v_new;
  end if;
end
$patch$;

commit;
