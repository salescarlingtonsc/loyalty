-- nestly_v872 rollback suite — Customer Intelligence revenue reads valid purchases and
-- frequency divides by visit-days.
--
-- Run inside a transaction against production and ROLLED BACK. Impersonates Cubbly SPA's real
-- owner; get_customer_intelligence_v83 writes an audit row (v741 roster read), which the
-- rollback discards.

\set ON_ERROR_STOP on

begin;

do $suite$
declare
  cb constant uuid := '8492e8d6-8888-4383-ada0-7e1ed69f0caa';
  owner_uid uuid; payload jsonb; row jsonb; def text; expected numeric; n integer := 0;
begin
  def := pg_get_functiondef('public.get_customer_intelligence_v83(uuid,uuid,date,date,integer,timestamptz,timestamptz,uuid)'::regprocedure);
  n := n + 1;
  if position('from valid_period_purchases sale where sale.client_id is not null /* nestly_v872 */' in def) = 0 then
    raise exception 'D% failed: period_revenue still reads the unfiltered window', n;
  end if;
  n := n + 1;
  if position('/86400/(count(distinct app.ci_visit_day_v699(sale.occurred_at))-1),1' in def) = 0 then
    raise exception 'D% failed: frequency still divides by sale rows', n;
  end if;

  select s.user_id into owner_uid from public.staff s where s.business_id = cb and s.role = 'owner' and s.user_id is not null limit 1;
  perform set_config('request.jwt.claims', json_build_object('sub', owner_uid, 'role', 'authenticated')::text, true);
  payload := public.get_customer_intelligence_v83(cb, null, '2026-07-01', app.sg_today(), 200, null, null, null);

  -- D3: no customer row reads "Purchases 0" with non-zero revenue any more
  n := n + 1;
  if exists (select 1 from jsonb_array_elements(payload->'customers') c
              where coalesce((c->>'purchase_count')::int,0) = 0 and coalesce((c->>'net_revenue_cents')::bigint,0) <> 0) then
    raise exception 'D% failed: a customer has purchase_count 0 with non-zero revenue', n;
  end if;

  -- D4: per-customer revenue equals the valid-purchase sum for every customer in the payload
  n := n + 1;
  if exists (
    select 1 from jsonb_array_elements(payload->'customers') c
    where (c->>'net_revenue_cents')::bigint <> coalesce((
      select sum(s.amount_cents) from public.sales s
       where s.business_id = cb and s.client_id = (c->>'client_id')::uuid
         and s.reversal_of is null and s.amount_cents > 0 and s.counts_as_revenue
         and not exists (select 1 from public.sales r where r.business_id = s.business_id and r.reversal_of = s.id)
         and s.occurred_at >= ('2026-07-01'::date::timestamp at time zone 'Asia/Singapore')
         and s.occurred_at <  ((app.sg_today() + 1)::timestamp at time zone 'Asia/Singapore')), 0)) then
    raise exception 'D% failed: a customer revenue does not equal its valid-purchase sum', n;
  end if;

  -- D5: frequency for the busiest customer equals the visit-day formula
  select c into row from jsonb_array_elements(payload->'customers') c
   where c->>'average_days_between_purchases' is not null
   order by (c->>'purchase_count')::int desc limit 1;
  if row is not null then
    select round(extract(epoch from (max(s.occurred_at) - min(s.occurred_at)))/86400
                 / (count(distinct app.ci_visit_day_v699(s.occurred_at)) - 1), 1) into expected
      from public.sales s
     where s.business_id = cb and s.client_id = (row->>'client_id')::uuid
       and s.reversal_of is null and s.amount_cents > 0 and s.counts_as_revenue
       and not exists (select 1 from public.sales r where r.business_id = s.business_id and r.reversal_of = s.id)
       and s.occurred_at < ((app.sg_today() + 1)::timestamp at time zone 'Asia/Singapore');
    n := n + 1;
    if (row->>'average_days_between_purchases')::numeric <> expected then
      raise exception 'D% failed: frequency % <> visit-day formula % for %', n, row->>'average_days_between_purchases', expected, row->>'client_id';
    end if;
  end if;

  raise notice 'nestly_v872 suite: % assertions passed', n;
end
$suite$;

rollback;
