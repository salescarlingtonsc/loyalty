-- NESTLY v950 — a customer no branch can claim is claimed by every branch.
--
-- AUDIT FINDING F4 (production sweep, 2026-09-15). With the top bar's VIEWING set to a named
-- branch — which is where the app lands by default — an owner added a customer, the row was
-- written with every field correct, and then: the Customers list still showed 9 rows, the "All"
-- chip still read 9, the new customer was not listed, and searching their name returned "No
-- matching customers". Switching VIEWING to "All branches" showed 14. Two REAL customers in the
-- reporting tenant were already invisible this way.
--
-- THE DEFECT CLASS, not the tenant. public.clients has no branch_id column: a customer belongs to
-- the BUSINESS, and the only thing that ever attributes one to a branch is a sale. Both readers
-- below decided roster membership with
--
--     and (
--       v_scope_is_whole_business
--       or exists(select 1 from customer_scope scoped where scoped.client_id = customer.id)
--     )
--
-- where customer_scope is "has a counts_as_visit, non-reversal sale at a branch in this scope",
-- and v_scope_is_whole_business is true only when the scope covers every active branch. A
-- customer with no sales satisfies neither arm and falls out of the roster, the search AND the
-- counts. EVERY newly created customer is in exactly that state until their first sale — and the
-- app's own Dashboard already rules the other way for the same population (app/app.js: "This
-- figure is business-wide unless the record has an auditable branch attribution"), which is why
-- the Dashboard counted a customer the Customers page could not show.
--
-- THE RULE. A customer that no branch can claim is claimed by every branch. A customer that HAS
-- branch-attributed sales stays scoped to the branches they actually transacted in, so v155's
-- branch-scoped retention audiences do not move. public.sales.branch_id is nullable, so
-- "attributed to some branch at all" is `branch_id is not null`: a sale carrying no branch
-- attributes its customer to nothing and must not hide them everywhere.
--
-- BLAST RADIUS, measured read-only on production BEFORE applying: 29 non-synthetic clients across
-- 11 businesses are invisible to their own owner on any named-branch selection; worst single
-- tenant 7. After this they are visible to principals who ALREADY hold clients-read on their own
-- business. Nobody loses a row. Tenant reach does not change: the customer.business_id boundary,
-- the can_module_read gate, the is_synthetic filter (nestly_v740) and the whole
-- resolve_reporting_branch_scope_v155 path are untouched, and an unattributed customer carries no
-- branch information to leak in the first place.
--
-- THE THREE CHANGES, made identically in both readers:
--   1. a customer_branch_attributed CTE — customer_scope with the branch predicate swapped for
--      "attributed to any branch at all";
--   2. the roster gate gains `or not exists(... customer_branch_attributed ...)`;
--   3. the "Never visited" filter (v155) and its chip (v290) drop their v_scope_is_whole_business
--      requirement. Without this the fix would introduce a NEW disagreement: the unattributed
--      customer would appear under "All customers" on a branch but vanish under "Never visited",
--      and the chip would read 0 over a list that showed rows. Under a named branch every row in
--      the roster now either has a scoped visit (last visit not null) or is unattributed (null),
--      so the filter and the chip say exactly what the roster says.
--
-- Nothing else moves: not the search predicate, not the 30_59/60_89/90_plus buckets, not the
-- points-pot scoping, not is_synthetic, not the ordering, not the ACL prelude, not the grants.
-- Both functions are re-issued with CREATE OR REPLACE — no DDL, no data written, no signature or
-- ACL change — so this is reversible by re-applying the bodies nestly_v804 installed.
--
-- PROVENANCE OF THE BODIES BELOW. They are pg_get_functiondef output read from production on
-- 2026-09-15, with only the three substitutions above applied. They are NOT copied from
-- db/migrations/20260920_nestly_v740_*.sql: a first draft of this migration did that and its own
-- check block rejected it, because nestly_v804 later re-issued both functions to correct an
-- inverted points-pot predicate (`= ... and ...` -> `<> ... or ...`). v740 is a superseded
-- revision of these functions and must not be used as their source again.
--
-- The do-blocks are the proof: each asserts the live definition AFTER this migration equals the
-- definition BEFORE it with exactly these substitutions applied, so a body that moved by anything
-- else aborts the migration instead of shipping.

begin;

create temp table _v950_before(fn text primary key, def text) on commit drop;

do $capture$
begin
  insert into _v950_before(fn, def)
  select 'staff_list_customers_v155', pg_get_functiondef(p.oid)
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'staff_list_customers_v155'
  union all
  select 'staff_customer_bucket_counts_v290', pg_get_functiondef(p.oid)
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'staff_customer_bucket_counts_v290';

  if (select count(*) from _v950_before) <> 2 then
    raise exception 'v950: expected 2 captured bodies, got %',
      (select count(*) from _v950_before);
  end if;
  if exists (select 1 from _v950_before where def like '%customer_branch_attributed%') then
    raise exception 'v950: a captured body already carries customer_branch_attributed — already applied?';
  end if;
end
$capture$;

-- =============================================================================================
-- 1 · public.staff_list_customers_v155 — the roster, the search and the "Never visited" filter
-- =============================================================================================
CREATE OR REPLACE FUNCTION public.staff_list_customers_v155(p_business uuid, p_search text DEFAULT NULL::text, p_inactive_bucket text DEFAULT NULL::text, p_scope_mode text DEFAULT 'all'::text, p_branch_ids uuid[] DEFAULT ARRAY[]::uuid[], p_operational_branch uuid DEFAULT NULL::uuid, p_limit integer DEFAULT 100, p_offset integer DEFAULT 0)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'app', 'pg_temp'
AS $function$
declare
  v_as_of timestamptz := statement_timestamp();
  v_search text := lower(btrim(coalesce(p_search,'')));
  v_phone_search text := regexp_replace(coalesce(p_search,''),'[^0-9]','','g');
  v_scope_ids uuid[];
  v_scope_label text;
  v_scope_is_whole_business boolean := false;
  v_result jsonb;
  -- v381: same pot rule as the customer profile — one programme's balance, not the sum of all
  v_balance_scope text := app.programme_balance_scope_v312(p_business);
  v_live_programme uuid := app.live_balance_programme_v381(p_business);
begin
  if length(v_phone_search)=10 and left(v_phone_search,2)='65' then
    v_phone_search := right(v_phone_search,8);
  end if;
  if auth.uid() is null or not app.can_module_read(p_business,'clients') then
    raise exception 'customer read access required' using errcode='42501';
  end if;
  if p_inactive_bucket is not null
     and p_inactive_bucket not in ('30_59','60_89','90_plus','never','all_inactive') then
    raise exception 'unsupported_inactivity_bucket' using errcode='22023';
  end if;
  if p_limit < 1 or p_limit > 100 then
    raise exception 'limit must be between 1 and 100' using errcode='22023';
  end if;
  if p_offset < 0 or p_offset > 100000 then
    raise exception 'offset must be between 0 and 100000' using errcode='22023';
  end if;

  select coalesce(array_agg(scope.branch_id order by scope.branch_name),array[]::uuid[])
    into v_scope_ids
  from app.resolve_reporting_branch_scope_v155(
    p_business,p_scope_mode,p_branch_ids,p_operational_branch
  ) scope;
  v_scope_label := app.reporting_scope_label_v155(
    p_business,p_scope_mode,p_branch_ids,p_operational_branch
  );
  select not exists(
    select 1
    from public.branches branch
    where branch.business_id = p_business
      and coalesce(branch.active,true)
      and not (branch.id = any(v_scope_ids))
  ) into v_scope_is_whole_business;

  with visit_facts as materialized (
    select sale.client_id,max(sale.occurred_at) as last_visit_at
    from public.sales sale
    where sale.business_id = p_business
      and sale.client_id is not null
      and sale.counts_as_visit
      and sale.reversal_of is null
      and sale.occurred_at <= v_as_of
      and sale.branch_id = any(v_scope_ids)
      and not exists(
        select 1 from public.sales reversal
        where reversal.business_id = sale.business_id
          and reversal.reversal_of = sale.id
          and reversal.created_at <= v_as_of
      )
    group by sale.client_id
  ), customer_scope as materialized (
    select distinct sale.client_id
    from public.sales sale
    where sale.business_id = p_business
      and sale.client_id is not null
      and sale.counts_as_visit
      and sale.reversal_of is null
      and sale.branch_id = any(v_scope_ids)
  ), customer_branch_attributed as materialized (
    select distinct sale.client_id
    from public.sales sale
    where sale.business_id = p_business
      and sale.client_id is not null
      and sale.counts_as_visit
      and sale.reversal_of is null
      and sale.branch_id is not null
  ), customer_rows as materialized (
    select customer.id,customer.full_name,customer.phone,
      customer.marketing_consent,customer.created_at,
      visit.last_visit_at,
      case when visit.last_visit_at is null then null
        else ((v_as_of at time zone 'Asia/Singapore')::date-
          (visit.last_visit_at at time zone 'Asia/Singapore')::date)::integer
      end as days_since_last_visit
    from public.clients customer
    left join visit_facts visit on visit.client_id = customer.id
    where customer.business_id = p_business
      and customer.is_synthetic = false
      and (
        v_scope_is_whole_business
        or exists(select 1 from customer_scope scoped where scoped.client_id = customer.id)
        or not exists(select 1 from customer_branch_attributed attributed
          where attributed.client_id = customer.id)
      )
      and (
        v_search = ''
        or position(v_search in lower(customer.full_name)) > 0
        or (length(v_phone_search) >= 4 and
          position(v_phone_search in coalesce(customer.phone_norm,'')) > 0)
      )
      and (
        p_inactive_bucket is null
        or (p_inactive_bucket = 'never' and visit.last_visit_at is null)
        or (p_inactive_bucket = '30_59' and visit.last_visit_at is not null
          and ((v_as_of at time zone 'Asia/Singapore')::date-
            (visit.last_visit_at at time zone 'Asia/Singapore')::date) between 30 and 59)
        or (p_inactive_bucket = '60_89' and visit.last_visit_at is not null
          and ((v_as_of at time zone 'Asia/Singapore')::date-
            (visit.last_visit_at at time zone 'Asia/Singapore')::date) between 60 and 89)
        or (p_inactive_bucket = '90_plus' and visit.last_visit_at is not null
          and ((v_as_of at time zone 'Asia/Singapore')::date-
            (visit.last_visit_at at time zone 'Asia/Singapore')::date) >= 90)
        or (p_inactive_bucket = 'all_inactive' and visit.last_visit_at is not null
          and ((v_as_of at time zone 'Asia/Singapore')::date-
            (visit.last_visit_at at time zone 'Asia/Singapore')::date) >= 30)
      )
  ), page as materialized (
    select * from customer_rows customer
    order by customer.last_visit_at asc nulls last, customer.full_name, customer.id
    limit p_limit offset p_offset
  ), page_balances as materialized (
    select customer.*,
      coalesce((select sum(ledger.points) from public.points_ledger ledger
        where ledger.business_id = p_business and ledger.client_id = customer.id
          and (v_balance_scope <> 'programme_pot' or ledger.programme_id is not distinct from v_live_programme)),0)::bigint as points,
      coalesce((select sum(ledger.amount_cents) from public.credit_ledger ledger
        where ledger.business_id = p_business and ledger.client_id = customer.id),0)::bigint as balance_cents,
      -- nestly_v629: everything this customer has paid this company, ever. Owner ruling when
      -- asked: "everything the customer paid" — every sale kind, so a package or a membership
      -- counts as the money it was. It is NOT branch-scoped and NOT date-scoped: "lifetime" means
      -- the whole relationship, which is also why it sits beside points and credit here, the two
      -- other business-wide figures on this row, rather than beside the branch-scoped last visit.
      -- Reversals are excluded on BOTH sides — the compensating row and the sale it cancelled —
      -- exactly as visit_facts above excludes them, so a refunded sale leaves no trace in either.
      -- A package SESSION is a SGD 0 sale and therefore adds nothing; the package was already
      -- counted at its full price when it was sold.
      coalesce((select sum(sale.amount_cents) from public.sales sale
        where sale.business_id = p_business and sale.client_id = customer.id
          and sale.reversal_of is null
          and not exists(
            select 1 from public.sales reversal
            where reversal.business_id = sale.business_id
              and reversal.reversal_of = sale.id
          )),0)::bigint as lifetime_spend_cents
    from page customer
  )
  select jsonb_build_object(
    'status','ok',
    'as_of',v_as_of,
    'scope',jsonb_build_object(
      'mode',coalesce(p_scope_mode,'all'),
      'label',v_scope_label,
      'branch_ids',to_jsonb(v_scope_ids),
      'definition',case when v_scope_is_whole_business
        then 'Business-wide last valid visit across all included authorised branches.'
        else 'Inactive in this branch scope: last valid visit within that selected scope.'
      end
    ),
    'inactive_bucket',p_inactive_bucket,
    'loyalty_available',app.metric_module_scope_available_v145(p_business,null,'loyalty'),
    'total',(select count(*) from customer_rows),
    'customers',coalesce((select jsonb_agg(jsonb_build_object(
      'id',customer.id,
      'full_name',customer.full_name,
      'phone',customer.phone,
      'marketing_consent',customer.marketing_consent,
      'created_at',customer.created_at,
      'last_visit_at',customer.last_visit_at,
      'days_since_last_visit',customer.days_since_last_visit,
      'points',customer.points,
      'balance_cents',customer.balance_cents,
      'lifetime_spend_cents',customer.lifetime_spend_cents
    ) order by customer.last_visit_at asc nulls last,customer.full_name,customer.id)
    from page_balances customer),'[]'::jsonb)
  ) into v_result;

  return v_result;
end
$function$;


-- CREATE OR REPLACE preserves an existing ACL, so this restates rather than changes it: the live
-- proacl on both overloads is postgres=X, authenticated=X, service_role=X — PUBLIC holds nothing.
-- It is stated explicitly so that a future CREATE (rather than REPLACE) of either overload can
-- never quietly reinstate PostgreSQL's default PUBLIC EXECUTE on a SECURITY DEFINER reader.
revoke all on function public.staff_list_customers_v155(uuid, text, text, text, uuid[], uuid, integer, integer) from public, anon;
grant execute on function public.staff_list_customers_v155(uuid, text, text, text, uuid[], uuid, integer, integer) to authenticated, service_role;

-- =============================================================================================
-- 2 · public.staff_customer_bucket_counts_v290 — the "All" chip and the "Never visited" chip
-- =============================================================================================
CREATE OR REPLACE FUNCTION public.staff_customer_bucket_counts_v290(p_business uuid, p_search text DEFAULT NULL::text, p_scope_mode text DEFAULT 'all'::text, p_branch_ids uuid[] DEFAULT ARRAY[]::uuid[], p_operational_branch uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'app', 'pg_temp'
AS $function$
declare
  v_as_of timestamptz := statement_timestamp();
  v_search text := lower(btrim(coalesce(p_search,'')));
  v_phone_search text := regexp_replace(coalesce(p_search,''),'[^0-9]','','g');
  v_scope_ids uuid[];
  v_scope_label text;
  v_scope_is_whole_business boolean := false;
  v_result jsonb;
begin
  if length(v_phone_search)=10 and left(v_phone_search,2)='65' then
    v_phone_search := right(v_phone_search,8);
  end if;
  if auth.uid() is null or not app.can_module_read(p_business,'clients') then
    raise exception 'customer read access required' using errcode='42501';
  end if;

  select coalesce(array_agg(scope.branch_id order by scope.branch_name),array[]::uuid[])
    into v_scope_ids
  from app.resolve_reporting_branch_scope_v155(
    p_business,p_scope_mode,p_branch_ids,p_operational_branch
  ) scope;
  v_scope_label := app.reporting_scope_label_v155(
    p_business,p_scope_mode,p_branch_ids,p_operational_branch
  );
  select not exists(
    select 1
    from public.branches branch
    where branch.business_id = p_business
      and coalesce(branch.active,true)
      and not (branch.id = any(v_scope_ids))
  ) into v_scope_is_whole_business;

  with visit_facts as materialized (
    select sale.client_id,max(sale.occurred_at) as last_visit_at
    from public.sales sale
    where sale.business_id = p_business
      and sale.client_id is not null
      and sale.counts_as_visit
      and sale.reversal_of is null
      and sale.occurred_at <= v_as_of
      and sale.branch_id = any(v_scope_ids)
      and not exists(
        select 1 from public.sales reversal
        where reversal.business_id = sale.business_id
          and reversal.reversal_of = sale.id
          and reversal.created_at <= v_as_of
      )
    group by sale.client_id
  ), customer_scope as materialized (
    select distinct sale.client_id
    from public.sales sale
    where sale.business_id = p_business
      and sale.client_id is not null
      and sale.counts_as_visit
      and sale.reversal_of is null
      and sale.branch_id = any(v_scope_ids)
  ), customer_branch_attributed as materialized (
    select distinct sale.client_id
    from public.sales sale
    where sale.business_id = p_business
      and sale.client_id is not null
      and sale.counts_as_visit
      and sale.reversal_of is null
      and sale.branch_id is not null
  ), customer_rows as materialized (
    select customer.id,
      case when visit.last_visit_at is null then null
        else ((v_as_of at time zone 'Asia/Singapore')::date-
          (visit.last_visit_at at time zone 'Asia/Singapore')::date)::integer
      end as days_since_last_visit
    from public.clients customer
    left join visit_facts visit on visit.client_id = customer.id
    where customer.business_id = p_business
      and customer.is_synthetic = false
      and (
        v_scope_is_whole_business
        or exists(select 1 from customer_scope scoped where scoped.client_id = customer.id)
        or not exists(select 1 from customer_branch_attributed attributed
          where attributed.client_id = customer.id)
      )
      and (
        v_search = ''
        or position(v_search in lower(customer.full_name)) > 0
        or (length(v_phone_search) >= 4 and
          position(v_phone_search in coalesce(customer.phone_norm,'')) > 0)
      )
  )
  select jsonb_build_object(
    'status','ok',
    'as_of',v_as_of,
    'scope',jsonb_build_object(
      'mode',coalesce(p_scope_mode,'all'),
      'label',v_scope_label,
      'branch_ids',to_jsonb(v_scope_ids),
      'whole_business',v_scope_is_whole_business
    ),
    'counts',jsonb_build_object(
      '30_59',count(*) filter (
        where days_since_last_visit between 30 and 59),
      '60_89',count(*) filter (
        where days_since_last_visit between 60 and 89),
      '90_plus',count(*) filter (
        where days_since_last_visit >= 90),
      'all_inactive',count(*) filter (
        where days_since_last_visit >= 30),
      'never',count(*) filter (
        where days_since_last_visit is null),
      'active',count(*) filter (
        where days_since_last_visit is not null and days_since_last_visit < 30),
      'total',count(*)
    )
  ) into v_result
  from customer_rows;

  return v_result;
end
$function$;


revoke all on function public.staff_customer_bucket_counts_v290(uuid, text, text, uuid[], uuid) from public, anon;
grant execute on function public.staff_customer_bucket_counts_v290(uuid, text, text, uuid[], uuid) to authenticated, service_role;

-- =============================================================================================
-- 3 · proof: each body moved by exactly the three substitutions above, and by nothing else
-- =============================================================================================
do $check$
declare
  v_before text; v_after text; v_expected text;
  v_cte_old constant text := $lit$  ), customer_rows as materialized ($lit$;
  v_cte_new constant text := $lit$  ), customer_branch_attributed as materialized (
    select distinct sale.client_id
    from public.sales sale
    where sale.business_id = p_business
      and sale.client_id is not null
      and sale.counts_as_visit
      and sale.reversal_of is null
      and sale.branch_id is not null
  ), customer_rows as materialized ($lit$;
  v_gate_old constant text := $lit$      and (
        v_scope_is_whole_business
        or exists(select 1 from customer_scope scoped where scoped.client_id = customer.id)
      )$lit$;
  v_gate_new constant text := $lit$      and (
        v_scope_is_whole_business
        or exists(select 1 from customer_scope scoped where scoped.client_id = customer.id)
        or not exists(select 1 from customer_branch_attributed attributed
          where attributed.client_id = customer.id)
      )$lit$;
  v_never_list_old constant text := $lit$        or (p_inactive_bucket = 'never' and v_scope_is_whole_business
          and visit.last_visit_at is null)$lit$;
  v_never_list_new constant text := $lit$        or (p_inactive_bucket = 'never' and visit.last_visit_at is null)$lit$;
  v_never_count_old constant text := $lit$      'never',count(*) filter (
        where v_scope_is_whole_business and days_since_last_visit is null),$lit$;
  v_never_count_new constant text := $lit$      'never',count(*) filter (
        where days_since_last_visit is null),$lit$;
begin
  select def into v_before from _v950_before where fn = 'staff_list_customers_v155';
  select pg_get_functiondef(p.oid) into v_after
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'staff_list_customers_v155';
  if position(v_cte_old in v_before) = 0
    or position(v_gate_old in v_before) = 0
    or position(v_never_list_old in v_before) = 0 then
    raise exception 'v950/staff_list_customers_v155: an anchor was not found in the captured body';
  end if;
  v_expected := replace(v_before, v_cte_old, v_cte_new);
  v_expected := replace(v_expected, v_gate_old, v_gate_new);
  v_expected := replace(v_expected, v_never_list_old, v_never_list_new);
  if v_after <> v_expected then
    raise exception 'v950/staff_list_customers_v155: definition moved by more than the three substitutions';
  end if;

  select def into v_before from _v950_before where fn = 'staff_customer_bucket_counts_v290';
  select pg_get_functiondef(p.oid) into v_after
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'staff_customer_bucket_counts_v290';
  if position(v_cte_old in v_before) = 0
    or position(v_gate_old in v_before) = 0
    or position(v_never_count_old in v_before) = 0 then
    raise exception 'v950/staff_customer_bucket_counts_v290: an anchor was not found in the captured body';
  end if;
  v_expected := replace(v_before, v_cte_old, v_cte_new);
  v_expected := replace(v_expected, v_gate_old, v_gate_new);
  v_expected := replace(v_expected, v_never_count_old, v_never_count_new);
  if v_after <> v_expected then
    raise exception 'v950/staff_customer_bucket_counts_v290: definition moved by more than the three substitutions';
  end if;
end
$check$;

commit;
