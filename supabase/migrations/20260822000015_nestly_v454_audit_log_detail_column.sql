-- nestly_v454 — retiring an offer and renaming a package could never commit.
--
-- THE DEFECT (audit D, 2026-08-22, reproduced against production gadpooereceldfpfxsod):
-- business_delete_promotion_v183 and business_manage_package_plan_v193 both finish with
--
--   insert into public.audit_log(business_id, actor, action, entity, entity_id, meta)
--
-- and public.audit_log has no column called "meta" — it is "detail", which is what every other
-- writer in this schema uses. The insert is the LAST statement in each function, so PostgreSQL
-- raises 42703 and rolls the whole call back. The owner-visible symptom:
--   * #/grow/offers "End" (a live offer) and "Delete" (a draft)  -> nothing happens, error toast
--   * #/packages     rename and delete of an unsold package plan -> nothing happens, error toast
-- Neither surface has any other write path, so both controls have been inert since the day they
-- shipped (v183 on 2026-08-06, v193 on 2026-08-07).
--
-- Reproduction used to find it (prod, tenant qa-kopi-lab 8ad4a375-2d42-4e0d-b509-b0e4ed6ccf8c):
--   select business_delete_promotion_v183('8ad4a375-…','d72a0000-0000-4000-8000-000000000001',6)
--   ERROR:  42703: column "meta" of relation "audit_log" does not exist
--   CONTEXT: PL/pgSQL function business_delete_promotion_v183(uuid,uuid,bigint) line 44
-- and the same shape from business_manage_package_plan_v193(…,'rename',…) at its line 37.
--
-- THIS IS THE THIRD APPEARANCE OF THE SAME TOKEN. nestly_v213 (2026-08-07) fixed exactly this in
-- business_set_sales_mix_v184 — "That column does not exist and never did" — but patched only the
-- one function it was chasing and no sweep followed. A scan of every function body in public and
-- app finds precisely two survivors, and this migration is both of them. The new guard suite
-- (db/tests/v454_audit_log_detail_column.sql, check 05) enumerates every audit_log insert in the
-- database and compares its column list against information_schema, so a fourth appearance fails
-- CI instead of reaching an owner.
--
-- WHY IT SURVIVED TWO ACCEPTANCE SUITES AND A P0 FIX. db/tests/v183_promotion_delete.sql and
-- db/tests/v193_manage_unsold_package_plan.sql were pg_get_functiondef REGEX suites: they asserted
-- the source text mentioned the right content_type, the right guards and the right lock, and never
-- once called the function. They were green throughout. Worse, nestly_v412 shipped on 2026-08-21
-- in response to an owner report that End/Delete "showed `promotion write access required` — to the
-- OWNER of the business", correctly repaired the module-key gate, and stopped there: the gate fix
-- was necessary but not sufficient, because the very next statement past the gate is the broken
-- insert. From the owner's chair the next attempt fails again. Both suites are rewritten by this
-- change to EXECUTE the RPCs against real fixture rows and assert the audit row that lands.
--
-- THE FIX: a single token replacement against the deployed definition, the v213 pattern, rather
-- than a rewrite. Both functions return json (not jsonb), so create-or-replace cannot change their
-- shape, and retyping either body would risk drifting from what is actually running. Nothing else
-- in either function changes — same guards, same lock, same retire/delete branches, same return
-- shape. The patch is idempotent: a body that no longer mentions the bad token is left alone, and
-- the block fails loudly if a function is missing or if the replacement did not take.
--
-- ACL: create-or-replace preserves grants, and the live ACL for both functions is
-- {postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres} — PUBLIC and anon already
-- hold nothing. The revoke/grant pair below restates that verbatim so the file is explicit about
-- the ACL it leaves behind; it is a no-op reassertion, not a privilege change.

begin;

do $patch$
declare
  v_targets text[] := array[
    'business_delete_promotion_v183',
    'business_manage_package_plan_v193'
  ];
  v_name text;
  v_src text;
  v_new text;
  v_patched int := 0;
begin
  foreach v_name in array v_targets loop
    select pg_get_functiondef(p.oid) into v_src
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = v_name;
    if v_src is null then
      raise exception 'v454: public.% is missing; refusing to half-patch the pair', v_name;
    end if;

    v_new := replace(v_src,
      'insert into public.audit_log(business_id, actor, action, entity, entity_id, meta)',
      'insert into public.audit_log(business_id, actor, action, entity, entity_id, detail)');

    if v_new = v_src then
      -- Already fixed, or the body changed shape. Either way do not install anything.
      raise notice 'v454: public.% does not reference the meta column; left as it is', v_name;
    else
      execute v_new;
      v_patched := v_patched + 1;
    end if;

    -- Whatever branch we took, the deployed body must not name the missing column any more.
    select pg_get_functiondef(p.oid) into v_src
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = v_name;
    if position('audit_log(business_id, actor, action, entity, entity_id, meta)' in v_src) > 0 then
      raise exception 'v454: public.% still writes audit_log.meta after patching', v_name;
    end if;
  end loop;

  raise notice 'v454: patched % of % functions', v_patched, array_length(v_targets, 1);
end
$patch$;

revoke all on function public.business_delete_promotion_v183(uuid, uuid, bigint) from public, anon;
grant execute on function public.business_delete_promotion_v183(uuid, uuid, bigint) to authenticated, service_role;

revoke all on function public.business_manage_package_plan_v193(uuid, uuid, text, text) from public, anon;
grant execute on function public.business_manage_package_plan_v193(uuid, uuid, text, text) to authenticated, service_role;

commit;
