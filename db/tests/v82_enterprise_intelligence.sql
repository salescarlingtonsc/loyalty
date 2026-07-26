-- Rollback-only v82 enterprise intelligence contract evidence.
begin;

do $v82_contract$
declare
  v_hierarchy regprocedure:=to_regprocedure(
    'public.platform_get_enterprise_hierarchy_v82(text,uuid[],uuid,date,date,text,integer,timestamp with time zone,timestamp with time zone,uuid)'
  );
  v_customers regprocedure:=to_regprocedure(
    'public.platform_list_enterprise_customers_v82(text,uuid[],uuid,date,date,text,integer,timestamp with time zone,timestamp with time zone,uuid)'
  );
  v_report regprocedure:=to_regprocedure(
    'public.platform_generate_improvement_report_v82(text,uuid[],uuid,date,date,text,timestamp with time zone)'
  );
  v_definition text;
begin
  if v_hierarchy is null or v_customers is null or v_report is null then
    raise exception 'v82 enterprise intelligence RPCs are missing';
  end if;
  if not (select prosecdef from pg_proc where oid=v_hierarchy)
     or not (select prosecdef from pg_proc where oid=v_customers)
     or not (select prosecdef from pg_proc where oid=v_report)
  then raise exception 'v82 enterprise intelligence is not security definer'; end if;
  if has_function_privilege('anon',v_hierarchy,'EXECUTE')
     or has_function_privilege('anon',v_customers,'EXECUTE')
     or has_function_privilege('anon',v_report,'EXECUTE')
  then raise exception 'anon can execute v82 enterprise intelligence'; end if;
  if not has_function_privilege('authenticated',v_hierarchy,'EXECUTE')
     or not has_function_privilege('authenticated',v_customers,'EXECUTE')
     or not has_function_privilege('authenticated',v_report,'EXECUTE')
  then raise exception 'authenticated lacks v82 enterprise RPC execute'; end if;

  v_definition:=pg_get_functiondef(v_hierarchy);
  if v_definition!~ 'complete_firm_cursor_required'
     or v_definition!~ '''total_firms'''
     or v_definition!~ '''next_cursor'''
     or v_definition!~ '''branches'''
     or v_definition!~ 'staff_branches'
     or v_definition!~ '''staff_count'''
  then raise exception 'v82 hierarchy keyset contract is incomplete'; end if;

  v_definition:=pg_get_functiondef(v_customers);
  if v_definition!~ 'complete_customer_cursor_required'
     or v_definition!~ '''total_customers'''
     or v_definition!~ 'period_first_purchase_at'
     or v_definition!~ 'lifetime\.last_purchase_at'
  then raise exception 'v82 customer paging/lifetime contract is incomplete'; end if;

  v_definition:=pg_get_functiondef(v_report);
  if v_definition!~ '''summary_by_currency'''
     or v_definition!~ '''currency_mode'''
     or v_definition!~ '''customer_total'''
     or v_definition!~ 'revenue_momentum_by_currency'
     or v_definition!~ 'returning_customers'
     or v_definition!~ '''search'''
     or v_definition!~ 'v_search'
  then raise exception 'v82 search/currency report contract is incomplete'; end if;
end
$v82_contract$;

rollback;
