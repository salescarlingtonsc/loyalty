-- NESTLY V129 — TRIAL & TEST OWNER WORKFLOW CLEANUP
--
-- Adds one bounded, permission-safe Customers reader for exact 30/60/90-day
-- inactivity filters. A valid visit is an original sale snapshot that counts
-- as a visit and has not been reversed. This deliberately includes canonical
-- SGD 0 package-session usage and partially refunded visits. No customer or
-- financial record is mutated by this migration.

begin;

create or replace function public.staff_list_customers_v129(
  p_business uuid,
  p_search text default null,
  p_inactive_days integer default null,
  p_limit integer default 100,
  p_offset integer default 0
)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_as_of timestamptz:=statement_timestamp();
  v_search text:=lower(btrim(coalesce(p_search,'')));
  v_phone_search text:=regexp_replace(coalesce(p_search,''),'[^0-9]','','g');
  v_cutoff_date date;
  v_result jsonb;
begin
  if length(v_phone_search)=10 and left(v_phone_search,2)='65' then
    v_phone_search:=right(v_phone_search,8);
  end if;

  if auth.uid() is null
     or not app.can_module_read(p_business,'clients') then
    raise exception 'customer read access required' using errcode='42501';
  end if;

  if p_inactive_days is not null and p_inactive_days not in (30,60,90) then
    raise exception 'inactive days must be 30, 60 or 90' using errcode='22023';
  end if;
  if p_limit<1 or p_limit>100 then
    raise exception 'limit must be between 1 and 100' using errcode='22023';
  end if;
  if p_offset<0 or p_offset>100000 then
    raise exception 'offset must be between 0 and 100000' using errcode='22023';
  end if;

  v_cutoff_date:=(v_as_of at time zone 'Asia/Singapore')::date-p_inactive_days;

  with visit_facts as materialized (
    select sale.client_id,max(sale.occurred_at) as last_visit_at
      from public.sales sale
     where sale.business_id=p_business
       and sale.client_id is not null
       and sale.counts_as_visit
       and sale.reversal_of is null
       and sale.occurred_at<=v_as_of
       and not exists(
         select 1 from public.sales reversal
          where reversal.business_id=sale.business_id
            and reversal.reversal_of=sale.id
            and reversal.created_at<=v_as_of
       )
     group by sale.client_id
  ),customer_rows as materialized (
    select customer.id,customer.full_name,customer.phone,
      customer.marketing_consent,customer.created_at,
      visit.last_visit_at,
      case when visit.last_visit_at is null then null
        else ((v_as_of at time zone 'Asia/Singapore')::date-
          (visit.last_visit_at at time zone 'Asia/Singapore')::date)::integer
      end as days_since_last_visit
      from public.clients customer
      left join visit_facts visit on visit.client_id=customer.id
     where customer.business_id=p_business
       and (
         v_search=''
         or position(v_search in lower(customer.full_name))>0
         or (length(v_phone_search)>=4 and
           position(v_phone_search in coalesce(customer.phone_norm,''))>0)
       )
       and (
         p_inactive_days is null
         or visit.last_visit_at is null
         or (visit.last_visit_at at time zone 'Asia/Singapore')::date<=v_cutoff_date
       )
  ),page as materialized (
    select * from customer_rows customer
     order by
       case when p_inactive_days is not null and customer.last_visit_at is null then 0 else 1 end,
       case when p_inactive_days is not null then customer.last_visit_at end asc nulls first,
       case when p_inactive_days is null then customer.created_at end desc,
       customer.full_name,customer.id
     limit p_limit offset p_offset
  ),page_balances as materialized (
    select customer.*,
      coalesce((select sum(ledger.points) from public.points_ledger ledger
        where ledger.business_id=p_business and ledger.client_id=customer.id),0)::bigint as points,
      coalesce((select sum(ledger.amount_cents) from public.credit_ledger ledger
        where ledger.business_id=p_business and ledger.client_id=customer.id),0)::bigint as balance_cents
      from page customer
  )
  select jsonb_build_object(
    'status','ok',
    'as_of',v_as_of,
    'inactive_days',p_inactive_days,
    'total',(select count(*) from customer_rows),
    'customers',coalesce((select jsonb_agg(jsonb_build_object(
      'id',customer.id,
      'full_name',customer.full_name,
      'phone',customer.phone,
      'marketing_consent',customer.marketing_consent,
      'last_visit_at',customer.last_visit_at,
      'days_since_last_visit',customer.days_since_last_visit,
      'points',customer.points,
      'balance_cents',customer.balance_cents
    ) order by
      case when p_inactive_days is not null and customer.last_visit_at is null then 0 else 1 end,
      case when p_inactive_days is not null then customer.last_visit_at end asc nulls first,
      case when p_inactive_days is null then customer.created_at end desc,
      customer.full_name,customer.id) from page_balances customer),'[]'::jsonb)
  ) into v_result;

  return v_result;
end
$$;

comment on function public.staff_list_customers_v129(uuid,text,integer,integer,integer) is
  'Lists a bounded customer page with last unreversed counts-as-visit event (including SGD 0 package sessions), page-only balances and exact optional 30/60/90 Singapore-calendar-day inactivity filtering for staff with Clients read access.';

revoke all on function public.staff_list_customers_v129(uuid,text,integer,integer,integer)
  from public,anon,authenticated;
grant execute on function public.staff_list_customers_v129(uuid,text,integer,integer,integer)
  to authenticated;

commit;
