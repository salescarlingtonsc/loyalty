-- NESTLY v687 — get_revenue_truth_v106 excludes synthetic-client sales (D7).
--
-- THE DEFECT (D7, docs/qa/CI-CORPUS-FIXTURE-GUIDE.md / v682's seeder header names the same
-- divergence in prose without fixing it). nestly_v628 ("Phase A capture-correctness")
-- established ONE exclusion authority, app.analytics_sale_class_v1 / app.analytics_business_
-- included_v1, so no analytical reader would re-derive these rules privately again, and its
-- header says every reader added from Phase A onward must use it. public.get_revenue_truth_v106
-- (nestly_v106, most recently re-emitted whole by nestly_v573) predates v628 entirely and has
-- never excluded a synthetic client's sales from headline known/identified revenue. Every v6xx
-- Customer Intelligence reader added since v628 DOES exclude them (get_ci_daypart_v1 via
-- app.analytics_sale_class_v1's is_synthetic_client column; get_ci_category_mix_v1 and siblings
-- via the equivalent inline `not coalesce((select c.is_synthetic from public.clients c where
-- c.id = s.client_id), false)` predicate — see nestly_v680's get_ci_category_mix_v1). So on any
-- business carrying synthetic data, the Dashboard/P&L headline (get_revenue_truth_v106) and the
-- Customer Intelligence readers built on the same sales disagree on revenue and transaction
-- counts for no product reason — a synthetic client's rows should never be revenue in either
-- reading. db/tests/executed/v682_golden_reconciliation.sql's own seeder sidesteps this today by
-- giving its synthetic client zero sales specifically to avoid exercising the divergence (see
-- that migration's header, "1 synthetic client... ZERO sales"); this migration closes the gap so
-- v682 can be hardened (see the accompanying migration touching that seeder) to give the
-- synthetic client real sales without breaking its own expected numbers.
--
-- THE FIX. Add exactly one exclusion to get_revenue_truth_v106's sales population: a sale is
-- excluded from both the currency-detection scan and the "original_sales" eligible set when
-- public.clients.is_synthetic is true for the sale's own (raw) sales.client_id. Nothing else
-- about the function moves — same reversal/refund/reconciliation logic, same identity split via
-- app.v111_effective_client_id, same coverage/formula/limitations metadata, same ACL. The proof
-- is mechanical, in the style of nestly_v668: the block below captures pg_get_functiondef BEFORE
-- the replacement and, after it, requires the new definition to equal the old one with the two
-- exclusion predicates added and nothing else moved. Any other drift raises and rolls back.
--
-- CHOICE OF AUTHORITY: app.analytics_sale_class_v1, not a private re-derivation. v628's own
-- header calls out this exact tradeoff ("existing readers are not force-migrated; every reader
-- added from Phase A onward must use them"). get_revenue_truth_v106 is being re-emitted BY this
-- migration, which lands after v628 -- so under v628's own rule this counts as a reader added
-- from Phase A onward, and should reach for the shared authority rather than hand-write the
-- predicate. The function's own reversal/refund logic stays untouched: v106's `original_sales`
-- CTE already has a far richer, purpose-built reversal/refund-reconciliation model (native
-- full-reversal netting, external partial-refund allocations via commerce_event_reconciliations)
-- than analytics_sale_class_v1's simple boolean include_revenue/include_visit columns, so this
-- migration reaches into analytics_sale_class_v1 for exactly the one field it actually needs --
-- is_synthetic_client -- and leaves v106's own revenue/reversal logic alone. That is the same
-- "cross join lateral app.analytics_sale_class_v1(s) sc ... and not sc.is_synthetic_client"
-- shape nestly_v680's get_ci_daypart_v1 and get_ci_category_mix_v1 already use.
--
-- app.analytics_business_included_v1 (demo/QA TENANT exclusion) is DELIBERATELY NOT added here.
-- That function excludes an entire business (is_demo, or named in analytics_excluded_businesses)
-- and its own doc comment and every existing caller apply it only to PLATFORM-WIDE aggregates
-- (a super admin's cross-tenant rollup), where a demo/QA tenant's numbers would otherwise
-- contaminate a real total nobody asked for by business_id. get_revenue_truth_v106 is the
-- opposite shape: it is always called scoped to ONE p_business, by that business's own owner (or
-- a super admin reading on its behalf) asking "what is MY revenue" -- Dashboard, Business
-- Insights, P&L accrual. A firm that happens to be flagged demo or platform_qa must still see its
-- own real sales when it asks for its own revenue; zeroing it out because the business itself is
-- excluded from a PLATFORM rollup would make the RPC lie to the one caller who is entitled to the
-- truth about that business. (The QA Test Cafe tenant precedent in this file's own CLAUDE.md --
-- "kept, not deleted" -- is exactly this: a demo-flagged tenant whose own numbers still have to
-- be real for anyone looking at it directly.) Synthetic CLIENTS are a different shape entirely:
-- they are rows planted inside an otherwise-real business specifically to be excluded from that
-- business's own truth (v628's is_synthetic_client field exists for exactly this), so excluding
-- them from get_revenue_truth_v106 does not carry the same risk.
--
-- PROVEN BY: db/tests/executed/v687_corpus_synthetic_exclusion.sql (red-before/green-after,
-- header carries the captured red output) and the hardened db/tests/executed/
-- v682_golden_reconciliation.sql (104/104 businesses, each now carrying a synthetic client with
-- real sales that must NOT move any expected number). db/tests/executed/v106_corpus_revenue_
-- truth.sql (the v106 regression floor) is unaffected: none of its fixture clients are
-- is_synthetic, so its six assertions are untouched by this change.
--
-- ROLLBACK: re-apply the v573-shape body, i.e. remove the two `cross join lateral
-- app.analytics_sale_class_v1(s) sc` joins and the two `and not sc.is_synthetic_client`
-- predicates. The block below prints the pre-change definition into a temp table for exactly
-- that purpose.

begin;

-- ---------------------------------------------------------------------------
-- 1 · Capture the live definition, and refuse to run against a shape we do not
--     recognise. A silent no-op here would look exactly like a successful fix.
-- ---------------------------------------------------------------------------
create temp table _v687_before(def text) on commit drop;

do $pre$
declare v_n integer;
begin
  insert into _v687_before(def)
  select pg_get_functiondef(p.oid)
    from pg_proc p
    join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'public'
     and p.proname = 'get_revenue_truth_v106';

  select count(*) into v_n from _v687_before;
  if v_n <> 1 then
    raise exception 'v687: expected exactly one public.get_revenue_truth_v106, found %', v_n;
  end if;

  if position('sc.is_synthetic_client' in (select def from _v687_before)) > 0 then
    raise exception
      'v687: the synthetic-client exclusion is already present — stop and re-read before shipping';
  end if;
end
$pre$;

-- ---------------------------------------------------------------------------
-- 2 · The same function, verbatim (v573's body) except for the two exclusion
--     joins/predicates added below. Nothing else moved.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.get_revenue_truth_v106(p_business uuid, p_from date, p_to date, p_branch uuid DEFAULT NULL::uuid, p_as_of timestamp with time zone DEFAULT clock_timestamp())
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'app', 'pg_temp'
AS $function$
declare
  v_currency text;
  v_period_currency text;
  v_currency_count integer;
  v_timezone text;
  v_result jsonb;
begin
  if auth.uid() is null then
    raise exception 'authentication required' using errcode = '42501';
  end if;
  if p_to <= p_from then
    raise exception 'p_to must be after p_from' using errcode = '22023';
  end if;
  if not (app.is_super_admin()
          or (app.has_perm(p_business, 'view_finance')
              and app.can_module(p_business, 'customerintel'))) then
    raise exception 'finance permission required' using errcode = '42501';
  end if;
  if not app.can_see_branch(p_business, p_branch) then
    raise exception 'branch is outside actor scope' using errcode = '42501';
  end if;
  if p_branch is not null and not exists (
    select 1 from public.branches b
     where b.id = p_branch and b.business_id = p_business
  ) then
    raise exception 'branch does not belong to business' using errcode = '23503';
  end if;
  select upper(b.currency) into strict v_currency
    from public.businesses b where b.id = p_business;
  if p_branch is null then
    v_timezone := 'per_outlet';
  else
    select b.timezone into strict v_timezone
      from public.branches b
     where b.id = p_branch and b.business_id = p_business;
  end if;
  select count(distinct c.currency), min(c.currency)
    into v_currency_count, v_period_currency
    from public.sales s
    cross join lateral app.v106_reporting_contract(
      s.business_id, s.branch_id, s.occurred_at
    ) c
    cross join lateral app.analytics_sale_class_v1(s) sc
   where s.business_id = p_business
     and s.reversal_of is null
     and s.counts_as_revenue
     and s.created_at <= p_as_of
     and not sc.is_synthetic_client
     and (p_branch is null or s.branch_id = p_branch)
     and (s.occurred_at at time zone c.timezone)::date >= p_from
     and (s.occurred_at at time zone c.timezone)::date < p_to;
  if v_currency_count > 1 then
    raise exception 'cross-currency reporting periods are not supported'
      using errcode = '22023';
  end if;
  if v_currency_count = 1 then
    v_currency := v_period_currency;
  end if;

  with original_sales as materialized (
    select s.id,
           app.v111_effective_client_id(s.business_id, s.client_id) as client_id,
           s.amount_cents, s.occurred_at, s.created_at,
           s.branch_id, c.timezone, c.currency,
           coalesce((
             select abs(sum(r.amount_cents))
             from public.sales r
              cross join lateral app.v106_reporting_contract(
                r.business_id, r.branch_id, r.occurred_at
              ) rc
              where r.business_id = s.business_id
                and r.reversal_of = s.id
                and r.created_at <= p_as_of
                and (r.occurred_at at time zone rc.timezone)::date < p_to
           ), 0)::bigint as native_refund_minor,
           coalesce((
             select sum(a.amount_minor)
               from public.commerce_refund_allocations_v106 a
               join public.commerce_event_reconciliations_v106 rr
                 on rr.id = a.reconciliation_id and rr.business_id = a.business_id
               join public.commerce_events_v106 e
                 on e.id = a.event_id and e.business_id = a.business_id
              where a.business_id = s.business_id
                and a.sale_id = s.id
                and rr.created_at <= p_as_of
                and e.business_date < p_to
           ), 0)::bigint as external_refund_minor,
           exists (
             select 1 from public.sale_items i
              where i.business_id = s.business_id and i.sale_id = s.id
           ) as is_itemized,
           exists (
             select 1
               from public.commerce_event_reconciliations_v106 rr
               join public.commerce_events_v106 e
                 on e.id = rr.event_id
                and e.business_id = rr.business_id
              where rr.business_id = s.business_id
                and rr.sale_id = s.id
                and rr.created_at <= p_as_of
                and e.received_at <= p_as_of
                and e.event_type = 'transaction_completed'
                and e.branch_id is not distinct from s.branch_id
                and e.currency = c.currency
                and e.amount_minor = s.amount_cents
           ) as is_reconciled
      from public.sales s
      cross join lateral app.v106_reporting_contract(
        s.business_id, s.branch_id, s.occurred_at
      ) c
      cross join lateral app.analytics_sale_class_v1(s) sc
     where s.business_id = p_business
       and s.reversal_of is null
       and s.counts_as_revenue
       and s.created_at <= p_as_of
       and not sc.is_synthetic_client
       and (p_branch is null or s.branch_id = p_branch)
       and (s.occurred_at at time zone c.timezone)::date >= p_from
       and (s.occurred_at at time zone c.timezone)::date < p_to
  ), eligible as (
    select *,
      app.v106_sale_residual_minor(id, p_to, p_as_of) as net_minor
      from original_sales
  ), totals as (
    select
      coalesce(sum(net_minor), 0)::bigint as known_revenue,
      coalesce(sum(net_minor) filter (where client_id is not null), 0)::bigint
        as identified_revenue,
      coalesce(sum(net_minor) filter (where client_id is null), 0)::bigint
        as anonymous_revenue,
      count(*) filter (where net_minor > 0)::bigint as completed_transactions,
      count(*) filter (where net_minor > 0 and client_id is not null)::bigint
        as identified_transactions,
      count(*) filter (where net_minor > 0 and client_id is null)::bigint
        as anonymous_transactions,
      count(*) filter (where net_minor > 0 and is_itemized)::bigint
        as itemized_transactions,
      count(*) filter (where net_minor > 0 and is_reconciled)::bigint
        as reconciled_transactions,
      max(occurred_at) as latest_sale_occurred_at,
      max(created_at) as latest_sale_recorded_at,
      count(*)::bigint as cohort_rows
    from eligible
  ), event_freshness as (
    select max(e.received_at) as latest_external_event_received_at
      from public.commerce_events_v106 e
     where e.business_id = p_business
       and (p_branch is null or e.branch_id = p_branch)
       and e.received_at <= p_as_of
  ), conflict_count as (
    select count(*)::bigint as conflicts
      from public.commerce_event_conflicts_v106 q
      join public.commerce_events_v106 e
        on e.id = q.existing_event_id and e.business_id = q.business_id
     where q.business_id = p_business and q.created_at <= p_as_of
       and (p_branch is null or e.branch_id = p_branch)
  )
  select jsonb_build_object(
    'contract_version', 'v106.1',
    'generated_at', clock_timestamp(),
    'as_of', p_as_of,
    'scope', jsonb_build_object(
      'business_id', p_business,
      'branch_id', p_branch,
      'period', jsonb_build_object(
        'from', p_from,
        'to', p_to,
        'interval', '[from,to)'
      ),
      'timezone', v_timezone,
      'timezone_contract', case when p_branch is null
        then 'per_outlet_effective_timezone'
        else 'selected_outlet_effective_timezone'
      end,
      'currency', v_currency
    ),
    'status', case when t.completed_transactions = 0 then 'no_data' else 'ok' end,
    'totals', jsonb_build_object(
      'known_revenue_minor', t.known_revenue,
      'identified_revenue_minor', t.identified_revenue,
      'anonymous_revenue_minor', t.anonymous_revenue,
      'completed_transactions', t.completed_transactions,
      'identified_transactions', t.identified_transactions,
      'anonymous_transactions', t.anonymous_transactions,
      'itemized_transactions', t.itemized_transactions
    ),
    'coverage', jsonb_build_object(
      'identity_revenue_pct', case when t.known_revenue = 0 then null
        else round(100 * t.identified_revenue::numeric / t.known_revenue, 2) end,
      'identity_transaction_pct', case when t.completed_transactions = 0 then null
        else round(100 * t.identified_transactions::numeric / t.completed_transactions, 2) end,
      'itemization_transaction_pct', case when t.completed_transactions = 0 then null
        else round(100 * t.itemized_transactions::numeric / t.completed_transactions, 2) end,
      'reconciled_transaction_pct', case when t.completed_transactions = 0 then null
        else round(100 * t.reconciled_transactions::numeric / t.completed_transactions, 2) end
    ),
    'freshness', jsonb_build_object(
      'latest_sale_occurred_at', t.latest_sale_occurred_at,
      'latest_sale_recorded_at', t.latest_sale_recorded_at,
      'latest_external_event_received_at', f.latest_external_event_received_at,
      'reconciliation_conflicts', q.conflicts
    ),
    'formula_metadata', jsonb_build_object(
      'version', 'revenue_truth_v106_1',
      'eligible_sale', 'original sale with counts_as_revenue=true and created_at<=as_of',
      'period_assignment', 'sale occurred_at converted by its effective outlet timezone',
      'known_revenue', 'sum(max(original_amount-native_full_reversal-reconciled_external_refund_allocations,0))',
      'identity_split', 'identified iff the v111 current-attribution resolver returns a client_id; otherwise anonymous',
      'identity_attribution', 'immutable sales.client_id is resolved through app.v111_effective_client_id for current synchronized reporting',
      'invariant', 'known_revenue_minor = identified_revenue_minor + anonymous_revenue_minor',
      'refund_cutoff', 'refund business date is before report p_to and recorded by as_of',
      'zero_denominator', 'coverage ratios are null'
    ),
    'limitations', jsonb_build_array(
      'Known revenue covers the Peekaa sales ledger; it is not merchant-total revenue until a POS adapter proves source completeness.',
      'External transaction observations do not affect totals until reconciled to an existing sale.',
      'Legacy pre-v106 facts use an explicit migration-time timezone/currency assumption.',
      'Native reversals are full-sale only; v106 external allocations provide partial-refund attribution without rewriting old ledgers.'
    )
  ) into v_result
  from totals t cross join event_freshness f cross join conflict_count q;

  if (v_result #>> '{totals,known_revenue_minor}')::bigint <>
     (v_result #>> '{totals,identified_revenue_minor}')::bigint +
     (v_result #>> '{totals,anonymous_revenue_minor}')::bigint then
    raise exception 'v106 revenue identity invariant failed'
      using errcode = 'data_exception';
  end if;
  return v_result;
end $function$;

-- ---------------------------------------------------------------------------
-- 3 · Mechanical byte-faithful proof: the new definition equals the old one
--     with exactly the two exclusion joins/predicates added and nothing else
--     moved. Any other drift raises and rolls the whole migration back.
-- ---------------------------------------------------------------------------
do $post$
declare
  v_before   text;
  v_after    text;
  v_expected text;

  /* Location 1: the currency-detection scan. */
  v_clause1_old constant text :=
E'    from public.sales s
    cross join lateral app.v106_reporting_contract(
      s.business_id, s.branch_id, s.occurred_at
    ) c
   where s.business_id = p_business
     and s.reversal_of is null
     and s.counts_as_revenue
     and s.created_at <= p_as_of
     and (p_branch is null or s.branch_id = p_branch)
     and (s.occurred_at at time zone c.timezone)::date >= p_from
     and (s.occurred_at at time zone c.timezone)::date < p_to;
';
  v_clause1_new constant text :=
E'    from public.sales s
    cross join lateral app.v106_reporting_contract(
      s.business_id, s.branch_id, s.occurred_at
    ) c
    cross join lateral app.analytics_sale_class_v1(s) sc
   where s.business_id = p_business
     and s.reversal_of is null
     and s.counts_as_revenue
     and s.created_at <= p_as_of
     and not sc.is_synthetic_client
     and (p_branch is null or s.branch_id = p_branch)
     and (s.occurred_at at time zone c.timezone)::date >= p_from
     and (s.occurred_at at time zone c.timezone)::date < p_to;
';

  /* Location 2: the original_sales CTE population. */
  v_clause2_old constant text :=
E'      from public.sales s
      cross join lateral app.v106_reporting_contract(
        s.business_id, s.branch_id, s.occurred_at
      ) c
     where s.business_id = p_business
       and s.reversal_of is null
       and s.counts_as_revenue
       and s.created_at <= p_as_of
       and (p_branch is null or s.branch_id = p_branch)
       and (s.occurred_at at time zone c.timezone)::date >= p_from
       and (s.occurred_at at time zone c.timezone)::date < p_to
  ), eligible as (
';
  v_clause2_new constant text :=
E'      from public.sales s
      cross join lateral app.v106_reporting_contract(
        s.business_id, s.branch_id, s.occurred_at
      ) c
      cross join lateral app.analytics_sale_class_v1(s) sc
     where s.business_id = p_business
       and s.reversal_of is null
       and s.counts_as_revenue
       and s.created_at <= p_as_of
       and not sc.is_synthetic_client
       and (p_branch is null or s.branch_id = p_branch)
       and (s.occurred_at at time zone c.timezone)::date >= p_from
       and (s.occurred_at at time zone c.timezone)::date < p_to
  ), eligible as (
';
begin
  select def into v_before from _v687_before;
  select pg_get_functiondef(p.oid) into v_after
    from pg_proc p
    join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'public'
     and p.proname = 'get_revenue_truth_v106';

  if position(v_clause1_old in v_before) = 0 then
    raise exception
      'v687: currency-scan clause was not found in the live body in the expected shape; '
      'extract it with pg_get_functiondef and re-diff rather than guessing';
  end if;
  if position(v_clause2_old in v_before) = 0 then
    raise exception
      'v687: original_sales clause was not found in the live body in the expected shape; '
      'extract it with pg_get_functiondef and re-diff rather than guessing';
  end if;

  v_expected := replace(v_before, v_clause1_old, v_clause1_new);
  v_expected := replace(v_expected, v_clause2_old, v_clause2_new);

  if v_after <> v_expected then
    raise exception
      'v687: the new definition differs from the old one by more than the two synthetic-client '
      'exclusion predicates — nothing else may move. Old:%  %New:%  %',
      E'\n', v_expected, E'\n', v_after;
  end if;

  if position('sc.is_synthetic_client' in v_after) = 0 then
    raise exception 'v687: the synthetic-client exclusion did not land';
  end if;
end
$post$;

-- ---------------------------------------------------------------------------
-- 4 · ACL restated verbatim (unchanged from v573 — CREATE OR REPLACE preserves
--     the existing grants, but this is stated explicitly per the task).
-- ---------------------------------------------------------------------------
revoke all on function public.get_revenue_truth_v106(p_business uuid, p_from date, p_to date, p_branch uuid, p_as_of timestamp with time zone) from public;
revoke all on function public.get_revenue_truth_v106(p_business uuid, p_from date, p_to date, p_branch uuid, p_as_of timestamp with time zone) from postgres;
grant execute on function public.get_revenue_truth_v106(p_business uuid, p_from date, p_to date, p_branch uuid, p_as_of timestamp with time zone) to postgres;
revoke all on function public.get_revenue_truth_v106(p_business uuid, p_from date, p_to date, p_branch uuid, p_as_of timestamp with time zone) from authenticated;
grant execute on function public.get_revenue_truth_v106(p_business uuid, p_from date, p_to date, p_branch uuid, p_as_of timestamp with time zone) to authenticated;
revoke all on function public.get_revenue_truth_v106(p_business uuid, p_from date, p_to date, p_branch uuid, p_as_of timestamp with time zone) from service_role;
grant execute on function public.get_revenue_truth_v106(p_business uuid, p_from date, p_to date, p_branch uuid, p_as_of timestamp with time zone) to service_role;

commit;
