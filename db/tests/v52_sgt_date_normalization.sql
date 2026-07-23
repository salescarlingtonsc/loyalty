-- Rollback-only v52 suite: SGT date-labeling normalization.
-- Run after the complete canonical chain through v52 in a disposable rehearsal DB.
-- Catalog assertions are clock-independent (they inspect the definitions, so they pass
-- at any hour); the behavioral checks compare against (timezone('Asia/Singapore',
-- now()))::date, which is fixed within the suite's single transaction.
begin;
\ir fixtures/pristine_chain_fixture.psql

create or replace function pg_temp.as_user(p_uid uuid) returns void language plpgsql as $$
begin
  execute 'reset role';
  execute 'set local role authenticated';
  perform set_config('request.jwt.claim.sub', p_uid::text, true);
  perform set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated')::text, true);
end $$;

create or replace function pg_temp.assert_true(p_ok boolean, p_message text) returns void language plpgsql as $$
begin
  if not coalesce(p_ok, false) then raise exception 'ASSERTION FAILED: %', p_message; end if;
end $$;

create or replace function pg_temp.assert_eq(p_actual anyelement, p_expected anyelement, p_message text)
returns void language plpgsql as $$
begin
  if p_actual is distinct from p_expected then
    raise exception 'ASSERTION FAILED: % (actual %, expected %)', p_message, p_actual, p_expected;
  end if;
end $$;

create or replace function pg_temp.count_occ(h text, n text) returns integer language sql as $$
  select (length(h) - length(replace(h, n, ''))) / length(n);
$$;

create or replace function pg_temp.col_default(p_table text, p_col text) returns text
language sql stable as $$
  select pg_catalog.pg_get_expr(ad.adbin, ad.adrelid)
    from pg_catalog.pg_attribute a
    join pg_catalog.pg_class c on c.oid = a.attrelid
    join pg_catalog.pg_namespace n on n.oid = c.relnamespace
    left join pg_catalog.pg_attrdef ad on ad.adrelid = a.attrelid and ad.adnum = a.attnum
   where n.nspname = 'public' and c.relname = p_table and a.attname = p_col;
$$;

grant execute on function pg_temp.as_user(uuid) to public;
grant execute on function pg_temp.assert_true(boolean, text) to public;
grant execute on function pg_temp.assert_eq(anyelement, anyelement, text) to public;
grant execute on function pg_temp.count_occ(text, text) to public;
grant execute on function pg_temp.col_default(text, text) to public;

do $v52$
declare
  v_biz_a uuid; v_owner_a uuid; v_branch_a uuid;
  v_sgt date := (timezone('Asia/Singapore', now()))::date;
  v_def text;
  v_prod uuid; v_batch_date date; v_rp_starts date; v_exp_occ date; v_rec uuid; v_rec_starts date;
  v_base uuid; v_draft uuid; v_hash text; v_tax uuid; v_program uuid := gen_random_uuid();
  v_dash jsonb; v_draft_starts date;
begin
  -- =====================================================================
  -- CATALOG ASSERTIONS (clock-independent, regression-proof at any hour).
  -- =====================================================================
  -- (1) Four column defaults now carry the SGT expression, no stale CURRENT_DATE.
  perform pg_temp.assert_true(
    pg_temp.col_default('stock_batches','received_on') like '%Asia/Singapore%'
      and pg_temp.col_default('stock_batches','received_on') !~* 'current_date',
    'stock_batches.received_on default is SGT');
  perform pg_temp.assert_true(
    pg_temp.col_default('retention_programs','starts_on') like '%Asia/Singapore%'
      and pg_temp.col_default('retention_programs','starts_on') !~* 'current_date',
    'retention_programs.starts_on default is SGT');
  perform pg_temp.assert_true(
    pg_temp.col_default('expenses','occurred_on') like '%Asia/Singapore%'
      and pg_temp.col_default('expenses','occurred_on') !~* 'current_date',
    'expenses.occurred_on default is SGT');
  perform pg_temp.assert_true(
    pg_temp.col_default('expense_recurrences','starts_on') like '%Asia/Singapore%'
      and pg_temp.col_default('expense_recurrences','starts_on') !~* 'current_date',
    'expense_recurrences.starts_on default is SGT');

  -- (2) run_expense_recurrences: no current_date remains; both comparisons are SGT.
  v_def := pg_get_functiondef('app.run_expense_recurrences()'::regprocedure);
  perform pg_temp.assert_true(v_def !~* 'current_date', 'run_expense_recurrences has no stale current_date');
  perform pg_temp.assert_eq(pg_temp.count_occ(v_def, 'Asia/Singapore'), 2,
    'run_expense_recurrences has exactly two SGT comparisons');

  -- (3) get_dashboard_summary: five age brackets now SGT; still invoker + pinned.
  v_def := pg_get_functiondef('public.get_dashboard_summary(uuid,date,date,uuid)'::regprocedure);
  perform pg_temp.assert_true(v_def !~* 'current_date', 'get_dashboard_summary has no stale current_date');
  -- Count the exact age-bracket expression, not bare 'Asia/Singapore' — the v18
  -- function already used SGT day-bucketing elsewhere (12 pre-existing occurrences).
  perform pg_temp.assert_eq(pg_temp.count_occ(v_def, 'age((timezone(''Asia/Singapore'', now()))::date'), 5,
    'get_dashboard_summary has five SGT age brackets');
  perform pg_temp.assert_true(v_def !~* 'security definer', 'get_dashboard_summary stayed SECURITY INVOKER');

  -- (4) save_retention_program_draft: starts_on fallback is SGT.
  v_def := pg_get_functiondef('public.save_retention_program_draft(uuid,uuid,jsonb,text)'::regprocedure);
  perform pg_temp.assert_true(v_def !~* 'current_date', 'save_retention_program_draft has no stale current_date');
  perform pg_temp.assert_true(v_def like '%Asia/Singapore%', 'save_retention_program_draft fallback is SGT');

  -- =====================================================================
  -- FIXTURE: locate pristine tenant A + its branch.
  -- =====================================================================
  reset role;
  select b.id, s.user_id into v_biz_a, v_owner_a
    from public.businesses b
    join public.staff s on s.business_id = b.id and s.role = 'owner' and s.active and s.user_id is not null
   where b.name = 'Pristine chain fixture A';
  select id into v_branch_a from public.branches where business_id = v_biz_a and active order by is_default desc, created_at limit 1;
  if v_biz_a is null or v_branch_a is null then raise exception 'v52 suite requires pristine tenant A'; end if;

  -- =====================================================================
  -- BEHAVIORAL: column defaults stamp the SGT calendar date.
  -- =====================================================================
  -- stock_batches.received_on (the receiving path).
  insert into public.products(business_id, name, sku, retail_price_cents, active)
  values (v_biz_a, 'V52 Product', 'V52-SKU-1', 1000, true) returning id into v_prod;
  insert into public.stock_batches(product_id, qty) values (v_prod, 5)
  returning received_on into v_batch_date;
  perform pg_temp.assert_eq(v_batch_date, v_sgt, 'received_on defaulted to the SGT date');

  -- retention_programs.starts_on. The v28 resolve trigger requires a real
  -- reward_taxonomy_id for the business, so supply the seeded credit taxonomy.
  select id into v_tax from public.firm_reward_taxonomy
   where business_id = v_biz_a and fulfillment_kind = 'credit' and active order by sort, id limit 1;
  if v_tax is null then raise exception 'v52 suite requires a seeded credit taxonomy'; end if;
  insert into public.retention_programs(business_id, name, goal_visits, period_days, reward_type, reward_taxonomy_id, reward_value)
  values (v_biz_a, 'V52 Retention', 3, 30, 'credit', v_tax, 500) returning starts_on into v_rp_starts;
  perform pg_temp.assert_eq(v_rp_starts, v_sgt, 'retention_programs.starts_on defaulted to the SGT date');

  -- expenses.occurred_on.
  insert into public.expenses(business_id, amount_cents) values (v_biz_a, 4200)
  returning occurred_on into v_exp_occ;
  perform pg_temp.assert_eq(v_exp_occ, v_sgt, 'expenses.occurred_on defaulted to the SGT date');

  -- expense_recurrences.starts_on (default) + capture a recurrence due today for the runner.
  insert into public.expense_recurrences(business_id, branch_id, name, amount_cents, cadence, next_run_on)
  values (v_biz_a, v_branch_a, 'V52 Rent', 90000, 'monthly', v_sgt)
  returning id, starts_on into v_rec, v_rec_starts;
  perform pg_temp.assert_eq(v_rec_starts, v_sgt, 'expense_recurrences.starts_on defaulted to the SGT date');

  -- =====================================================================
  -- BEHAVIORAL: the recurrence runner materialises a due row using the SGT date.
  -- =====================================================================
  reset role;
  perform app.run_expense_recurrences();
  perform pg_temp.assert_true(
    exists (select 1 from public.expenses e where e.recurrence_id = v_rec and e.occurred_on = v_sgt),
    'run_expense_recurrences materialised the due recurrence at the SGT date');

  -- =====================================================================
  -- BEHAVIORAL: get_dashboard_summary still executes (age brackets included).
  -- =====================================================================
  perform pg_temp.as_user(v_owner_a);
  v_dash := public.get_dashboard_summary(v_biz_a, v_sgt - 30, v_sgt, null);
  perform pg_temp.assert_true(v_dash is not null and jsonb_typeof(v_dash) = 'object',
    'get_dashboard_summary still returns an object after the SGT age-bracket change');

  -- =====================================================================
  -- BEHAVIORAL: save_retention_program_draft omitting starts_on falls back to SGT.
  -- =====================================================================
  perform pg_temp.as_user(v_owner_a);
  select active_config_version_id into v_base from public.businesses where id = v_biz_a;
  select id into v_tax from public.firm_reward_taxonomy
   where business_id = v_biz_a and fulfillment_kind = 'credit' and active order by sort, id limit 1;
  if v_tax is null then raise exception 'v52 suite requires a seeded credit taxonomy'; end if;
  v_draft := (public.create_loyalty_config_draft(v_biz_a, v_base, 'v52-draft')::jsonb->>'version_id')::uuid;
  select snapshot_hash into v_hash from public.firm_config_versions where id = v_draft;
  perform public.save_retention_program_draft(v_draft, v_program, jsonb_build_object(
    'name', 'V52 winback', 'active', true, 'goal_visits', 1, 'period_days', 30,
    'reward_taxonomy_id', v_tax, 'credit_cents', 500, 'sort', 10), v_hash);
  reset role;
  select starts_on into v_draft_starts from public.retention_program_versions
   where program_id = v_program and config_version_id = v_draft and business_id = v_biz_a;
  perform pg_temp.assert_eq(v_draft_starts, v_sgt,
    'save_retention_program_draft defaulted starts_on to the SGT date');
end $v52$;

rollback;
