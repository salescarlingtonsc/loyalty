/* nestly_v804 — two readers that answer with the wrong rows.

   Audit findings F079 (P2) and F123 (P2), both confirmed read-only against production on
   2026-09-02 by reading the live definitions with pg_get_functiondef.

   ============================================================================================
   F079 — EVERY points-pot reader shows 0 for EVERY customer in business_pot scope.
   ============================================================================================
   public.staff_list_customers_v155 sums a customer's points with

     and (v_balance_scope = 'programme_pot' and ledger.programme_id is not distinct from
          v_live_programme)

   The predicate is inverted. When app.programme_balance_scope_v312 resolves to 'business_pot'
   the first conjunct is false for every row, the sum is over nothing, and every customer's
   points column coalesces to 0. 'business_pot' means "sum every programme"; the expression says
   "sum nothing".

   THE FIRST DRAFT OF THIS MIGRATION FIXED ONE SITE, on the belief that the sibling reader on the
   same screen, public.staff_get_customer_actionable_loyalty_v145, already carried the correct
   '<> ... or ...' form and the two therefore disagreed. That belief was wrong, and building the
   acceptance suite is what disproved it: v145 carries the same inverted predicate, twice. A
   read-only scan of every function in public and app on production, 2026-09-02, finds FIVE
   occurrences across four functions and not one correct one:

     app.client_points_balance_v409                          1  (l.programme_id)
     public.staff_get_customer_actionable_loyalty_v145       2  (ledger. and batch.)
     public.staff_list_customers_v129                        1  (inline v312/v381 calls)
     public.staff_list_customers_v155                        1  (ledger.programme_id)

   So this is one defect class with five instances, not one bug with a correct neighbour. Fixing
   only v155 would have made the list and the profile disagree in the OPPOSITE direction — the
   list right, the profile still zero — which is worse than both being wrong together, because it
   reads as a data loss rather than as an outage. All five are corrected here, to the predicate
   the phrase actually means: business_pot sums every programme, programme_pot sums the live one.

   'business_pot' is not hypothetical. app.programme_balance_scope_v312 returns it while a
   points-pot migration is pending or running, and as its safe fallback whenever a (client,
   programme) pot's ledger sum and batch remaining are momentarily incoherent. No live tenant is
   in that state right now (measured: zero businesses resolve to anything but 'programme_pot'),
   which is why nobody has seen it — and why it would arrive silently, mid-migration, at the
   worst possible moment, across every one of these readers at once.

   Two things deliberately NOT touched. app.c45_base_actionable_wallet_card and the other
   customer-side wallet readers filter on app.live_balance_programme_v381 alone and never consult
   the scope at all; that is a different shape with its own history and it is not this finding.
   And public.staff_list_customers_v129 keeps its EXECUTE grant to anon exactly as it is — an
   anon caller is already refused by its own `auth.uid() is null` guard on the first statement,
   and re-grants belong to a migration that is about ACLs, not to this one.

   ============================================================================================
   F123 — platform Marketing usage KPIs and monthly trend are computed from one PAGE.
   ============================================================================================
   public.platform_engagement_monthly_v255 builds `page` as `select * from rows_out ... limit
   p_limit`, stores it in v_rows, and then derives BOTH the four KPI tiles (v_summary) and the
   platform-wide "Monthly trend" table (v_trend) by aggregating jsonb_array_elements(v_rows) —
   the truncated page, not the full rows_out. has_more is returned and correctly gates the
   per-firm table's Load-more button, but nothing gates the tiles or the trend.

   Because the page is ordered month DESC, truncation deletes the OLDEST months from the trend
   outright and clips the boundary month mid-way, and campaigns / push_sent / sends /
   inbox_opens / businesses all undercount. Measured against production today: 23 business-month
   rows over the default 12-month range against a limit of 100, so the numbers are still right —
   but at the observed rate the rolling window crosses 100 rows on ordinary growth with no code
   change at all, and above the 1000 ceiling even walking Load-more cannot recover the truth.

   The fix keeps the paged `businesses` list exactly as it is — that page is the point of a
   page — and computes the trend and the tiles from a second, UNLIMITED aggregate over the same
   rows_out CTE. rows_out was already referenced twice (by `page` and by the total_count
   subquery) and so was already materialised; this adds a third reference to the same
   materialisation, not a third scan of the base tables.

   Rollback suite: db/tests/v692_pot_scope_and_unpaged_totals.sql */
begin;

-- =============================================================================================
-- F079 — one operator and one keyword, in all five places the estate scan found.
-- =============================================================================================
do $v692_pots$
declare
  v_site record;
  v_def text;
  v_new text;
  v_fixed integer := 0;
begin
  for v_site in
    select * from (values
      ('app.client_points_balance_v409(uuid,uuid)',
       'v_scope = ''programme_pot'' and l.programme_id is not distinct from v_live',
       'v_scope <> ''programme_pot'' or l.programme_id is not distinct from v_live', 1),
      ('public.staff_get_customer_actionable_loyalty_v145(uuid,uuid,uuid)',
       'v_balance_scope = ''programme_pot'' and ledger.programme_id is not distinct from v_live_programme',
       'v_balance_scope <> ''programme_pot'' or ledger.programme_id is not distinct from v_live_programme', 1),
      ('public.staff_get_customer_actionable_loyalty_v145(uuid,uuid,uuid)',
       'v_balance_scope = ''programme_pot'' and batch.programme_id is not distinct from v_live_programme',
       'v_balance_scope <> ''programme_pot'' or batch.programme_id is not distinct from v_live_programme', 1),
      ('public.staff_list_customers_v129(uuid,text,integer,integer,integer)',
       'app.programme_balance_scope_v312(p_business) = ''programme_pot'' and ledger.programme_id is not distinct from app.live_balance_programme_v381(p_business)',
       'app.programme_balance_scope_v312(p_business) <> ''programme_pot'' or ledger.programme_id is not distinct from app.live_balance_programme_v381(p_business)', 1),
      ('public.staff_list_customers_v155(uuid,text,text,text,uuid[],uuid,integer,integer)',
       'v_balance_scope = ''programme_pot'' and ledger.programme_id is not distinct from v_live_programme',
       'v_balance_scope <> ''programme_pot'' or ledger.programme_id is not distinct from v_live_programme', 1)
    ) as site(fn, needle, replacement, occurrences)
  loop
    v_def := pg_get_functiondef(v_site.fn::regprocedure);
    if position(v_site.replacement in v_def) > 0 then
      raise notice 'nestly_v804: % already sums every pot in business_pot scope, skipping', v_site.fn;
      continue;
    end if;
    if (length(v_def) - length(replace(v_def, v_site.needle, '')))
       / nullif(length(v_site.needle),0) <> v_site.occurrences then
      raise exception 'nestly_v804: % did not carry its pot predicate exactly % time(s)'
        , v_site.fn, v_site.occurrences using errcode = 'XX001';
    end if;
    v_new := replace(v_def, v_site.needle, v_site.replacement);
    if v_new = v_def then
      raise exception 'nestly_v804: the pot splice on % produced no change', v_site.fn
        using errcode = 'XX001';
    end if;
    execute v_new;
    v_fixed := v_fixed + 1;
  end loop;
  raise notice 'nestly_v804: % pot predicate site(s) corrected', v_fixed;
end
$v692_pots$;
revoke all privileges on function app.client_points_balance_v409(uuid,uuid)
  from public, anon, authenticated;
revoke all privileges on function
  public.staff_get_customer_actionable_loyalty_v145(uuid,uuid,uuid) from public, anon;
grant execute on function
  public.staff_get_customer_actionable_loyalty_v145(uuid,uuid,uuid)
  to authenticated, service_role;
revoke all privileges on function
  public.staff_list_customers_v155(uuid,text,text,text,uuid[],uuid,integer,integer)
  from public, anon;
grant execute on function
  public.staff_list_customers_v155(uuid,text,text,text,uuid[],uuid,integer,integer)
  to authenticated, service_role;

-- =============================================================================================
-- F123 — the tiles and the trend read the whole range, the list keeps its page.
-- =============================================================================================
do $v692_engagement$
declare
  v_def text; v_new text;
  v_decl constant text :=
'  v_rows jsonb;';
  v_decl_new constant text :=
'  v_rows jsonb;
  v_all_rows jsonb;';
  v_into constant text :=
'    (select count(*)::integer from rows_out)
  into v_rows,v_total
  from page;';
  v_into_new constant text :=
'    (select count(*)::integer from rows_out),
    (select coalesce(
       pg_catalog.jsonb_agg(
         pg_catalog.jsonb_build_object(
           ''business_id'',every_row.business_id,''business_name'',every_row.business_name,
           ''month'',every_row.month,''customers'',every_row.customers,
           ''campaigns'',every_row.campaigns,''push_sent'',every_row.push_sent,
           ''push_failed'',every_row.push_failed,''sends'',every_row.sends,
           ''inbox_opens'',every_row.inbox_opens,''merchant_dau'',every_row.merchant_dau,
           ''merchant_mau'',every_row.merchant_mau,''sessions'',every_row.sessions,
           ''customer_mau'',every_row.customer_mau,''redemptions'',every_row.redemptions,
           ''bookings'',every_row.bookings,''sales_count'',every_row.sales_count
         )
         order by every_row.month desc,every_row.business_name,every_row.business_id
       ),
       ''[]''::jsonb) from rows_out every_row)
  into v_rows,v_total,v_all_rows
  from page;';
  v_trend constant text :=
'    from pg_catalog.jsonb_array_elements(v_rows) as element(item)
    group by 1';
  v_trend_new constant text :=
'    from pg_catalog.jsonb_array_elements(v_all_rows) as element(item)
    group by 1';
  v_newest constant text :=
'        from pg_catalog.jsonb_array_elements(v_rows) as newest(latest)';
  v_newest_new constant text :=
'        from pg_catalog.jsonb_array_elements(v_all_rows) as newest(latest)';
  v_summary constant text :=
'  from pg_catalog.jsonb_array_elements(v_rows) as element(item);';
  v_summary_new constant text :=
'  from pg_catalog.jsonb_array_elements(v_all_rows) as element(item);';
begin
  v_def := pg_get_functiondef(
    'public.platform_engagement_monthly_v255(date,date,uuid[],integer)'::regprocedure);
  if position('v_all_rows' in v_def) > 0 then
    raise notice 'nestly_v804: the engagement report already totals the whole range, skipping';
  else
    if (length(v_def) - length(replace(v_def, v_decl, ''))) / nullif(length(v_decl),0) <> 1
       or (length(v_def) - length(replace(v_def, v_into, ''))) / nullif(length(v_into),0) <> 1
       or (length(v_def) - length(replace(v_def, v_trend, ''))) / nullif(length(v_trend),0) <> 1
       or (length(v_def) - length(replace(v_def, v_newest, ''))) / nullif(length(v_newest),0) <> 1
       or (length(v_def) - length(replace(v_def, v_summary, ''))) / nullif(length(v_summary),0) <> 1 then
      raise exception 'nestly_v804: an engagement anchor did not match exactly once — body drifted'
        using errcode = 'XX001';
    end if;
    v_new := replace(v_def, v_decl, v_decl_new);
    v_new := replace(v_new, v_into, v_into_new);
    v_new := replace(v_new, v_trend, v_trend_new);
    v_new := replace(v_new, v_newest, v_newest_new);
    v_new := replace(v_new, v_summary, v_summary_new);
    if v_new = v_def then
      raise exception 'nestly_v804: the engagement splice produced no change' using errcode = 'XX001';
    end if;
    execute v_new;
  end if;
end
$v692_engagement$;
revoke all privileges on function
  public.platform_engagement_monthly_v255(date,date,uuid[],integer) from public, anon;
grant execute on function
  public.platform_engagement_monthly_v255(date,date,uuid[],integer) to authenticated, service_role;

-- =============================================================================================
-- Prove both changes took, in the transaction that made them.
-- =============================================================================================
do $verify$
declare
  v_site record;
  v_def text;
  v_engagement text := pg_get_functiondef(
    'public.platform_engagement_monthly_v255(date,date,uuid[],integer)'::regprocedure);
begin
  for v_site in
    select unnest(array[
      'app.client_points_balance_v409(uuid,uuid)',
      'public.staff_get_customer_actionable_loyalty_v145(uuid,uuid,uuid)',
      'public.staff_list_customers_v129(uuid,text,integer,integer,integer)',
      'public.staff_list_customers_v155(uuid,text,text,text,uuid[],uuid,integer,integer)'
    ]) as fn
  loop
    v_def := pg_get_functiondef(v_site.fn::regprocedure);
    if position('= ''programme_pot'' and' in v_def) > 0 then
      raise exception 'nestly_v804 (F079): % still zeroes every balance in business_pot scope'
        , v_site.fn using errcode = 'XX001';
    end if;
    if position('<> ''programme_pot'' or' in v_def) = 0 then
      raise exception 'nestly_v804 (F079): % lost its pot scope rule entirely', v_site.fn
        using errcode = 'XX001';
    end if;
  end loop;
  if position('into v_rows,v_total,v_all_rows' in v_engagement) = 0
     or position('jsonb_array_elements(v_all_rows)' in v_engagement) = 0 then
    raise exception 'nestly_v804 (F123): the engagement tiles still read one page'
      using errcode = 'XX001';
  end if;
  if position('jsonb_array_elements(v_rows)' in v_engagement) > 0 then
    raise exception 'nestly_v804 (F123): an aggregate still reads the truncated page'
      using errcode = 'XX001';
  end if;
end
$verify$;

commit;
