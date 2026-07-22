-- Rollback-only v49a forward-remediation catalog suite.
-- Proves the final definitions, ACLs, volatility, and pinned paths without
-- depending on or rewriting the historical migration files they repair.
begin;

do $v49a_test$
declare
  v_proc pg_proc%rowtype;
  v_path text;
begin
  select p.* into strict v_proc
    from pg_proc p
   where p.oid='app.suggest_appointment_reschedule_v48(
     uuid,uuid,uuid,uuid,timestamptz,integer,integer
   )'::regprocedure;
  v_path:=coalesce(array_to_string(v_proc.proconfig,','),'');
  if v_proc.provolatile<>'s' or not v_proc.prosecdef
     or v_path<>'search_path=pg_catalog, public, app, pg_temp'
     or position('clock_timestamp()' in v_proc.prosrc)>0
     or position('statement_timestamp()' in v_proc.prosrc)=0 then
    raise exception 'v49a appointment suggestion final definition is not statement-stable';
  end if;
  if has_function_privilege('anon',v_proc.oid,'execute')
     or has_function_privilege('authenticated',v_proc.oid,'execute')
     or exists (
       select 1 from aclexplode(coalesce(v_proc.proacl,acldefault('f',v_proc.proowner))) acl
        where acl.grantee=0 and acl.privilege_type='EXECUTE'
     ) then
    raise exception 'v49a exposed the private appointment suggestion helper';
  end if;

  select p.* into strict v_proc from pg_proc p
   where p.oid='public.reclassify_sale_policy(uuid,boolean,text)'::regprocedure;
  v_path:=coalesce(array_to_string(v_proc.proconfig,','),'');
  if not v_proc.prosecdef
     or v_path<>'search_path=pg_catalog, public, app, pg_temp'
     or position('v_reversal_ids uuid[] := ''{}''::uuid[];' in v_proc.prosrc)=0
     or not has_function_privilege('authenticated',v_proc.oid,'execute')
     or has_function_privilege('anon',v_proc.oid,'execute') then
    raise exception 'v49a reclassify_sale_policy repair or ACL drifted';
  end if;

  select p.* into strict v_proc from pg_proc p
   where p.oid='public.reverse_sale_v20_base(uuid,uuid,text,text,text,text)'::regprocedure;
  v_path:=coalesce(array_to_string(v_proc.proconfig,','),'');
  if not v_proc.prosecdef
     or v_path<>'search_path=pg_catalog, public, app, pg_temp'
     or position('v_payment_ids uuid[] := ''{}''::uuid[];' in v_proc.prosrc)=0
     or has_function_privilege('authenticated',v_proc.oid,'execute')
     or has_function_privilege('anon',v_proc.oid,'execute') then
    raise exception 'v49a reverse_sale_v20_base repair or private ACL drifted';
  end if;

  select p.* into strict v_proc from pg_proc p
   where p.oid='public.save_loyalty_reward_draft(uuid,uuid,jsonb,jsonb)'::regprocedure;
  v_path:=coalesce(array_to_string(v_proc.proconfig,','),'');
  if not v_proc.prosecdef
     or v_path<>'search_path=pg_catalog, public, app, pg_temp'
     or position('v_key text;' in v_proc.prosrc)>0
     or has_function_privilege('authenticated',v_proc.oid,'execute')
     or has_function_privilege('anon',v_proc.oid,'execute') then
    raise exception 'v49a draft reward editor repair or private ACL drifted';
  end if;

  raise notice 'v49a forward lint/remediation suite: ALL PASS';
end
$v49a_test$;

rollback;
