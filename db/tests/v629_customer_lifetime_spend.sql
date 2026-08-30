-- Rollback-only acceptance for nestly_v629 — the customer directory carries lifetime spend.
-- Run: supabase db query --linked -f db/tests/v629_customer_lifetime_spend.sql
-- Any row whose value starts with FAIL is a failure. Nothing is committed.
--
--   01  one signature, and the field is in the payload
--   02  behavioural: every customer on the first page agrees with the sales ledger it sums
--   03  behavioural: a reversal cancels on both sides — the sale and its compensating row
--   04  the reader still refuses a caller without customer read access

begin;

create temp table _r(check_id text, value text) on commit drop;

insert into _r
select '01 one signature, and lifetime_spend_cents is returned',
  case when count(*)<>1 then 'FAIL: '||count(*)||' overloads of staff_list_customers_v155'
       when max(case when position('lifetime_spend_cents' in prosrc)>0 then 1 else 0 end)=0
         then 'FAIL: the payload does not carry the figure'
       when max(case when position('reversal_of is null' in prosrc)>0 then 1 else 0 end)=0
         then 'FAIL: reversal rows are being counted as spend'
       else 'OK' end
from pg_proc where proname='staff_list_customers_v155' and pronamespace='public'::regnamespace;

/* Two separate blocks on purpose: PL/pgSQL rolls an exception handler back to the START of its
   block, so a failure in the reversal probe would discard the result the agreement check had
   already recorded. Learned by watching check 02 vanish from this suite's own output. */
do $agree$
declare
  v_biz uuid; v_owner uuid; v_out jsonb; v_row jsonb; v_expected bigint; v_mismatch int:=0;
begin
  select s.business_id,s.user_id into v_biz,v_owner
  from public.staff s
  where s.role='owner' and s.active and s.user_id is not null
    and exists(select 1 from public.sales x where x.business_id=s.business_id and x.client_id is not null and x.amount_cents>0)
  limit 1;
  if v_biz is null then
    insert into _r values('02 behavioural: the figure agrees with the ledger','SKIP: no tenant with a paid sale and an owner login');
    return;
  end if;
  perform set_config('request.jwt.claims',json_build_object('sub',v_owner,'role','authenticated')::text,true);
  set local role authenticated;
  v_out:=public.staff_list_customers_v155(v_biz,null,null,'all',array[]::uuid[],null,100,0);
  reset role;
  -- Every row, not a sample: the column is only trustworthy if it is right for all of them.
  for v_row in select value from jsonb_array_elements(v_out->'customers') value loop
    select coalesce(sum(sale.amount_cents),0) into v_expected
    from public.sales sale
    where sale.business_id=v_biz and sale.client_id=(v_row->>'id')::uuid
      and sale.reversal_of is null
      and not exists(select 1 from public.sales r
                      where r.business_id=sale.business_id and r.reversal_of=sale.id);
    if (v_row->>'lifetime_spend_cents')::bigint is distinct from v_expected then
      v_mismatch:=v_mismatch+1;
    end if;
  end loop;
  insert into _r values('02 behavioural: the figure agrees with the ledger',
    case when v_mismatch=0 then 'OK'
         else 'FAIL: '||v_mismatch||' customer(s) report a lifetime spend the sales ledger does not support' end);
exception when others then
  reset role;
  insert into _r values('02 behavioural: the figure agrees with the ledger','FAIL: raised — '||sqlerrm);
end
$agree$;

do $reversal$
declare
  v_biz uuid; v_owner uuid; v_out jsonb; v_client uuid; v_sale uuid;
  v_amount bigint; v_before bigint; v_after bigint;
begin
  select s.business_id,s.user_id into v_biz,v_owner
  from public.staff s
  where s.role='owner' and s.active and s.user_id is not null
    and exists(select 1 from public.sales x where x.business_id=s.business_id and x.client_id is not null and x.amount_cents>0)
  limit 1;
  if v_biz is null then
    insert into _r values('03 behavioural: a reversal cancels on both sides','SKIP: no tenant with a paid sale and an owner login');
    return;
  end if;
  perform set_config('request.jwt.claims',json_build_object('sub',v_owner,'role','authenticated')::text,true);
  set local role authenticated;
  v_out:=public.staff_list_customers_v155(v_biz,null,null,'all',array[]::uuid[],null,100,0);
  reset role;
  select (value->>'id')::uuid into v_client from jsonb_array_elements(v_out->'customers') value
   where (value->>'lifetime_spend_cents')::bigint>0
     and exists(select 1 from public.sales x where x.business_id=v_biz
                 and x.client_id=(value->>'id')::uuid and x.reversal_of is null
                 and x.amount_cents>0 and x.kind in ('service','retail','quick_sale'))
   limit 1;
  if v_client is null then
    insert into _r values('03 behavioural: a reversal cancels on both sides','SKIP: nobody on the first page has spent anything');
    return;
  end if;
  select (value->>'lifetime_spend_cents')::bigint into v_before
    from jsonb_array_elements(v_out->'customers') value where (value->>'id')::uuid=v_client;
  /* reverse_sale only supports the three kinds v20 proved a correction path for, so the probe
     picks one of those rather than asserting against a refusal that is about reversal policy and
     not about this column. */
  select id,amount_cents into v_sale,v_amount from public.sales
   where business_id=v_biz and client_id=v_client and reversal_of is null and amount_cents>0
     and kind in ('service','retail','quick_sale')
   order by id limit 1;
  if v_sale is null then
    insert into _r values('03 behavioural: a reversal cancels on both sides','SKIP: this customer has no reversible sale kind');
    return;
  end if;

  /* Through public.reverse_sale, which the database insists on — a hand-written reversal row is
     refused outright, and that refusal is itself worth knowing about. */
  set local role authenticated;
  perform public.reverse_sale(v_biz,v_sale,'v629 rolled-back probe','v629probe-'||v_sale::text);
  v_out:=public.staff_list_customers_v155(v_biz,null,null,'all',array[]::uuid[],null,100,0);
  reset role;
  select (value->>'lifetime_spend_cents')::bigint into v_after
    from jsonb_array_elements(v_out->'customers') value where (value->>'id')::uuid=v_client;

  insert into _r values('03 behavioural: a reversal cancels on both sides',
    case when v_after is null then 'SKIP: the customer left the first page after the reversal'
         when v_after<>v_before-v_amount
           then 'FAIL: expected both rows to cancel — before '||v_before||', after '||v_after||', sale '||v_amount
         else 'OK' end);
exception when others then
  reset role;
  insert into _r values('03 behavioural: a reversal cancels on both sides','FAIL: raised — '||sqlerrm);
end
$reversal$;

insert into _r
select '04 the reader still demands customer read access',
  case when (select position('can_module_read(p_business,''clients'')' in prosrc) from pg_proc
              where proname='staff_list_customers_v155' and pronamespace='public'::regnamespace)=0
         then 'FAIL: the authorisation gate was lost while adding the column'
       when has_function_privilege('anon','public.staff_list_customers_v155(uuid,text,text,text,uuid[],uuid,integer,integer)','execute')
         then 'FAIL: anon can read the customer directory'
       else 'OK' end;

reset role;
select check_id, value from _r order by check_id;

rollback;
