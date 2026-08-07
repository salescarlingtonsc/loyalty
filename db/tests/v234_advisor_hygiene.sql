-- V234 rollback verification: the advisor-hygiene fixes are installed.
-- Run inside a transaction that is ROLLED BACK.
begin;
do $$
declare v_config text[];
begin
  select proconfig into v_config
    from pg_proc p join pg_namespace n on n.oid=p.pronamespace
   where n.nspname='app' and p.proname='platform_expense_account_v147';
  if v_config is null or not exists(
    select 1 from unnest(v_config) cfg where cfg like 'search_path=%'
  ) then
    raise exception 'v234.fn: platform_expense_account_v147 search_path is not pinned: %', v_config;
  end if;
  if (select count(*) from pg_index i
        join pg_class c on c.oid=i.indrelid
        join pg_namespace n on n.oid=c.relnamespace
       where n.nspname='public' and i.indisprimary
         and c.relname in ('promotion_branch_scopes_v154','promotion_branch_scopes_v155')) <> 2 then
    raise exception 'v234.pk: a promotion branch-scope table is missing its primary key';
  end if;
  -- The mapping itself still answers.
  if app.platform_expense_account_v147('software') <> '6100'
     or app.platform_expense_account_v147('unknown-category') <> '6990' then
    raise exception 'v234.fn: expense account mapping changed behaviour';
  end if;
end $$;
rollback;
