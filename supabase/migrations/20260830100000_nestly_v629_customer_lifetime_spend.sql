-- nestly_v629 — the customer directory shows lifetime spend where consent used to be.
--
-- Owner ruling (photo 2, the CONSENT header struck through and "Lifetime Spend" written above
-- it), confirmed when asked as "everything the customer paid".
--
-- What it counts, and why:
--   • EVERY sale kind. A package, a membership or a gift card is money the customer handed over,
--     and the column answers "what is this customer worth to me", not "what did Reports call
--     revenue". The owner was offered the revenue-only reading and chose this one.
--   • The whole relationship — no branch scope and no date window. That is what "lifetime" means,
--     and it is why the figure sits beside points and credit, the two other business-wide numbers
--     on the row, rather than beside the branch-scoped last visit.
--   • Reversals cancel on both sides: the compensating row is skipped AND so is the sale it
--     reversed, the same pair of conditions visit_facts already applies, so a refunded sale
--     leaves no trace in either the visit or the money.
--   • A package session is a SGD 0 sale, so using one adds nothing. The package was counted in
--     full when it was sold.
--
-- Consent is not lost with the column: it is still on the customer's own record and still in both
-- CSV exports, which is where a PDPA question is actually answered.
--
-- Additive to the payload — one more key on each customer object. Nothing that reads this RPC
-- today can break by receiving it.
--
-- ROLLBACK: db/tests/v629_customer_lifetime_spend.sql

begin;

do $pre$
begin
  if to_regprocedure('public.staff_list_customers_v155(uuid,text,text,text,uuid[],uuid,integer,integer)') is null then
    raise exception 'v629: staff_list_customers_v155 is missing — the reader this extends';
  end if;
end
$pre$;

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
      and (
        v_scope_is_whole_business
        or exists(select 1 from customer_scope scoped where scoped.client_id = customer.id)
      )
      and (
        v_search = ''
        or position(v_search in lower(customer.full_name)) > 0
        or (length(v_phone_search) >= 4 and
          position(v_phone_search in coalesce(customer.phone_norm,'')) > 0)
      )
      and (
        p_inactive_bucket is null
        or (p_inactive_bucket = 'never' and v_scope_is_whole_business
          and visit.last_visit_at is null)
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
          and (v_balance_scope = 'programme_pot' and ledger.programme_id is not distinct from v_live_programme)),0)::bigint as points,
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
$function$
;

revoke all on function public.staff_list_customers_v155(uuid,text,text,text,uuid[],uuid,integer,integer) from public, anon;
grant execute on function public.staff_list_customers_v155(uuid,text,text,text,uuid[],uuid,integer,integer)
  to postgres, service_role, authenticated;

commit;
