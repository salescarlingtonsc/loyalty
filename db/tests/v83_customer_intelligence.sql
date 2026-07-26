-- Rollback-only v83 owner customer intelligence contract evidence.
begin;

do $v83_contract$
declare
  v_read_rpc regprocedure := to_regprocedure(
    'public.get_customer_intelligence_v83(uuid,uuid,date,date,integer,timestamp with time zone,timestamp with time zone,uuid)'
  );
  v_create_export_rpc regprocedure := to_regprocedure(
    'public.create_customer_intelligence_export_v83(uuid,uuid,date,date)'
  );
  v_page_export_rpc regprocedure := to_regprocedure(
    'public.get_customer_intelligence_export_page_v83(uuid,integer,integer)'
  );
  v_read_definition text;
  v_create_definition text;
  v_page_definition text;
begin
  if v_read_rpc is null then
    raise exception 'v83 customer intelligence RPC is missing';
  end if;
  if v_create_export_rpc is null or v_page_export_rpc is null then
    raise exception 'v83 stable export RPCs are missing';
  end if;

  if not (select prosecdef from pg_proc where oid=v_read_rpc)
     or not (select prosecdef from pg_proc where oid=v_create_export_rpc)
     or not (select prosecdef from pg_proc where oid=v_page_export_rpc)
  then raise exception 'v83 RPC is not security definer'; end if;

  if has_function_privilege('anon',v_read_rpc,'EXECUTE')
     or has_function_privilege('anon',v_create_export_rpc,'EXECUTE')
     or has_function_privilege('anon',v_page_export_rpc,'EXECUTE')
  then raise exception 'anon can execute a v83 RPC'; end if;
  if not has_function_privilege('authenticated',v_read_rpc,'EXECUTE')
     or not has_function_privilege('authenticated',v_create_export_rpc,'EXECUTE')
     or not has_function_privilege('authenticated',v_page_export_rpc,'EXECUTE')
  then raise exception 'authenticated lacks a v83 RPC execute grant'; end if;

  v_read_definition := pg_get_functiondef(v_read_rpc);
  v_create_definition := pg_get_functiondef(v_create_export_rpc);
  v_page_definition := pg_get_functiondef(v_page_export_rpc);

  if v_read_definition !~ 'app\.has_perm\(p_business,[[:space:]]*''view_finance'''
     or v_read_definition !~ 'app\.can_see_branch'
  then raise exception 'v83 tenant or branch authorization is incomplete'; end if;
  if v_read_definition !~ 'complete_customer_cursor_required'
     or v_read_definition !~ '''snapshot_at'''
     or v_read_definition !~ '''next_cursor'''
     or v_read_definition !~ 'customer_since'
  then raise exception 'v83 snapshot keyset pagination is incomplete'; end if;
  if v_read_definition !~ 'valid_lifetime_purchases'
     or v_read_definition !~ 'period_last_purchase_at'
     or v_read_definition !~ 'days_since_last_purchase'
  then raise exception 'v83 period and lifetime customer facts are not separated'; end if;
  if v_read_definition !~ 'v_history_days'
     or v_read_definition !~ 'v_active_weeks'
     or v_read_definition !~ 'v_completed_transactions'
     or v_read_definition !~ 'v_cash_observation_weeks'
     or v_read_definition !~ 'insufficient_data'
  then raise exception 'v83 forecast sufficiency gate is incomplete'; end if;
  if v_read_definition !~ 'percentile_cont\(0.20\)'
     or v_read_definition !~ 'percentile_cont\(0.80\)'
     or v_read_definition !~ 'trailing_13_complete_singapore_calendar_weeks_p20_mean_p80'
     or v_read_definition !~ '''partial_report_end_week_excluded'''
  then raise exception 'v83 complete-week forecast range is incomplete'; end if;

  if v_create_definition !~ 'insert into public.customer_intelligence_exports_v83'
     or v_create_definition !~ 'insert into public.customer_intelligence_export_rows_v83'
     or v_create_definition !~ 'v_snapshot'
     or v_create_definition !~ 'next_cursor'
  then raise exception 'v83 immutable export materialisation is incomplete'; end if;
  if v_page_definition !~ 'requested_by'
     or v_page_definition !~ 'p_after_ordinal'
     or v_page_definition !~ '''next_ordinal'''
  then raise exception 'v83 immutable export paging is incomplete'; end if;
end
$v83_contract$;

rollback;
