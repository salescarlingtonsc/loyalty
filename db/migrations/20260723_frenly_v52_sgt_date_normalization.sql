-- FRENLY v52 - SGT DATE-LABELING NORMALIZATION
--
-- Forward-only defect repair. Historical migrations remain immutable; this file
-- re-labels the benign UTC-vs-SGT calendar-date skews assessed after v50a (design
-- queue item 6). Supabase runs the server clock in UTC, so bare current_date is the
-- UTC calendar date; between 00:00 and 08:00 SGT the Singapore date is one day ahead.
-- Every site below is a Singapore-business-facing "today" that should be the SGT
-- calendar date, (timezone('Asia/Singapore', now()))::date. No data is backfilled;
-- historical rows keep their stored dates. Only defaults and the labeling logic move.
--
-- SCOPE (re-derived from the live chain, both trees):
--   1. Column DEFAULTs current_date -> SGT date on four Singapore-"today" columns.
--   2. app.run_expense_recurrences(): both `<= current_date` catch-up comparisons.
--   3. public.get_dashboard_summary(): the five age(current_date, birth_date) brackets.
--   4. public.save_retention_program_draft(): the starts_on coalesce fallback.
-- ALREADY SGT (skipped, verified): app.c42_profile_guard() and
--   public.customer_register_verified_phone() were fixed in v50a; their live
--   definitions no longer contain current_date. The only other current_date hit in the
--   sweep is a comment in v14. No now()::date / statement_timestamp()::date / CURRENT_DATE
--   date-labeling sites exist anywhere else in either migration tree.
--
-- Each function replacement follows the v49a/v50a fail-closed pattern: read the live
-- definition, assert the old expression occurs exactly the expected number of times and
-- the new expression zero times (or abort), assert the definer/invoker + search_path
-- pinning is intact, then re-create with only the date expression changed. Existing ACLs
-- are preserved by CREATE OR REPLACE and reasserted for the two browser-facing RPCs.

begin;

-- ---------------------------------------------------------------------------
-- 1. Column DEFAULTs. Guard first (each must currently be CURRENT_DATE), then ALTER.
--    Defaults are stored as parsed nodes, so pg_get_expr renders them as CURRENT_DATE.
-- ---------------------------------------------------------------------------
do $defaults$
declare
  r record;
  v_expr text;
begin
  for r in
    select tbl, col from (values
      ('stock_batches', 'received_on'),
      ('retention_programs', 'starts_on'),
      ('expenses', 'occurred_on'),
      ('expense_recurrences', 'starts_on')
    ) as t(tbl, col)
  loop
    select pg_catalog.pg_get_expr(ad.adbin, ad.adrelid)
      into v_expr
      from pg_catalog.pg_attribute a
      join pg_catalog.pg_class c on c.oid = a.attrelid
      join pg_catalog.pg_namespace n on n.oid = c.relnamespace
      left join pg_catalog.pg_attrdef ad on ad.adrelid = a.attrelid and ad.adnum = a.attnum
     where n.nspname = 'public' and c.relname = r.tbl and a.attname = r.col;
    if v_expr is null or upper(v_expr) <> 'CURRENT_DATE' then
      raise exception 'v52 expected public.%.% default CURRENT_DATE, found %',
        r.tbl, r.col, coalesce(v_expr, '(none)');
    end if;
  end loop;
end
$defaults$;

alter table public.stock_batches
  alter column received_on set default (timezone('Asia/Singapore', now()))::date;
alter table public.retention_programs
  alter column starts_on set default (timezone('Asia/Singapore', now()))::date;
alter table public.expenses
  alter column occurred_on set default (timezone('Asia/Singapore', now()))::date;
alter table public.expense_recurrences
  alter column starts_on set default (timezone('Asia/Singapore', now()))::date;

-- ---------------------------------------------------------------------------
-- 2. app.run_expense_recurrences(): the daily catch-up materialiser compares
--    recurrence dates against "today". Both `<= current_date` must be the SGT date,
--    or a Singapore recurrence due today is skipped for up to eight hours.
-- ---------------------------------------------------------------------------
do $recurrence$
declare
  v_def text;
  v_old text := '<= current_date';
  v_new text := '<= (timezone(''Asia/Singapore'', now()))::date';
  v_old_n integer;
  v_new_n integer;
begin
  select pg_get_functiondef('app.run_expense_recurrences()'::regprocedure) into strict v_def;
  v_old_n := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  v_new_n := (length(v_def) - length(replace(v_def, v_new, ''))) / length(v_new);
  if v_old_n <> 2 or v_new_n <> 0 then
    raise exception 'unexpected app.run_expense_recurrences predecessor date comparisons (old=%, new=%)',
      v_old_n, v_new_n;
  end if;
  if position('security definer' in lower(v_def)) = 0
     or position('set search_path' in lower(v_def)) = 0 then
    raise exception 'app.run_expense_recurrences predecessor lost its definer/search_path pinning';
  end if;
  execute replace(v_def, v_old, v_new);
end
$recurrence$;

-- ---------------------------------------------------------------------------
-- 3. public.get_dashboard_summary(): five age(current_date, birth_date) brackets.
--    This function is SECURITY INVOKER with an empty search_path (a hardening choice);
--    the guard asserts that pinning survived and that it did not become DEFINER.
-- ---------------------------------------------------------------------------
do $insights$
declare
  v_def text;
  v_old text := 'age(current_date,';
  v_new text := 'age((timezone(''Asia/Singapore'', now()))::date,';
  v_old_n integer;
  v_new_n integer;
begin
  select pg_get_functiondef('public.get_dashboard_summary(uuid,date,date,uuid)'::regprocedure)
    into strict v_def;
  v_old_n := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  v_new_n := (length(v_def) - length(replace(v_def, v_new, ''))) / length(v_new);
  if v_old_n <> 5 or v_new_n <> 0 then
    raise exception 'unexpected get_dashboard_summary predecessor age brackets (old=%, new=%)',
      v_old_n, v_new_n;
  end if;
  if position('set search_path' in lower(v_def)) = 0 then
    raise exception 'get_dashboard_summary predecessor lost its search_path pinning';
  end if;
  if position('security definer' in lower(v_def)) <> 0 then
    raise exception 'get_dashboard_summary predecessor unexpectedly is SECURITY DEFINER';
  end if;
  execute replace(v_def, v_old, v_new);
end
$insights$;

revoke all on function public.get_dashboard_summary(uuid, date, date, uuid)
  from public, anon, authenticated;
grant execute on function public.get_dashboard_summary(uuid, date, date, uuid)
  to authenticated;

-- ---------------------------------------------------------------------------
-- 4. public.save_retention_program_draft(): the starts_on fallback for a brand-new
--    program should default to the SGT calendar date, matching the SGT column default.
-- ---------------------------------------------------------------------------
do $draft$
declare
  v_def text;
  v_old text := 'coalesce(v_existing.starts_on,current_date)';
  v_new text := 'coalesce(v_existing.starts_on,(timezone(''Asia/Singapore'', now()))::date)';
  v_old_n integer;
  v_new_n integer;
begin
  select pg_get_functiondef('public.save_retention_program_draft(uuid,uuid,jsonb,text)'::regprocedure)
    into strict v_def;
  v_old_n := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  v_new_n := (length(v_def) - length(replace(v_def, v_new, ''))) / length(v_new);
  if v_old_n <> 1 or v_new_n <> 0 then
    raise exception 'unexpected save_retention_program_draft predecessor starts_on fallback (old=%, new=%)',
      v_old_n, v_new_n;
  end if;
  if position('security definer' in lower(v_def)) = 0
     or position('set search_path' in lower(v_def)) = 0 then
    raise exception 'save_retention_program_draft predecessor lost its definer/search_path pinning';
  end if;
  execute replace(v_def, v_old, v_new);
end
$draft$;

revoke all on function public.save_retention_program_draft(uuid, uuid, jsonb, text)
  from public, anon;
grant execute on function public.save_retention_program_draft(uuid, uuid, jsonb, text)
  to authenticated;

commit;
