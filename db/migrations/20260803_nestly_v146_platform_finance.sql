-- PEEKAA v146: Super Admin cash P&L, operating expenses and Stripe documents.
begin;

alter table public.billing_provider_invoices
  add column hosted_invoice_url text,
  add column invoice_pdf_url text,
  add column provider_receipt_url text;

alter table public.billing_provider_invoices
  add constraint billing_provider_invoices_hosted_url_v146_check check (
    hosted_invoice_url is null or hosted_invoice_url ~ '^https://([a-z0-9-]+\.)*stripe\.com/[^[:space:]]+$'
  ),
  add constraint billing_provider_invoices_pdf_url_v146_check check (
    invoice_pdf_url is null or invoice_pdf_url ~ '^https://([a-z0-9-]+\.)*stripe\.com/[^[:space:]]+$'
  ),
  add constraint billing_provider_invoices_receipt_url_v146_check check (
    provider_receipt_url is null or provider_receipt_url ~ '^https://([a-z0-9-]+\.)*stripe\.com/[^[:space:]]+$'
  );

create or replace function app.project_invoice_documents_v146()
returns trigger language plpgsql security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare v_object jsonb;
begin
  select payload#>'{data,object}' into v_object
    from public.billing_provider_events
   where provider='stripe' and event_id=new.last_event_id;
  if v_object is null then return new; end if;
  new.hosted_invoice_url:=coalesce(
    nullif(v_object->>'hosted_invoice_url',''),new.hosted_invoice_url
  );
  new.invoice_pdf_url:=coalesce(
    nullif(v_object->>'invoice_pdf',''),new.invoice_pdf_url
  );
  new.provider_receipt_url:=coalesce(
    nullif(v_object->>'receipt_url',''),
    nullif(v_object#>>'{charge,receipt_url}',''),
    new.provider_receipt_url
  );
  return new;
end
$$;
revoke all on function app.project_invoice_documents_v146() from public;

create trigger billing_provider_invoices_documents_v146
before insert or update of last_event_id on public.billing_provider_invoices
for each row execute function app.project_invoice_documents_v146();

-- Backfill from the immutable provider-event evidence already stored locally.
update public.billing_provider_invoices invoice
set hosted_invoice_url=nullif(event.payload#>>'{data,object,hosted_invoice_url}',''),
    invoice_pdf_url=nullif(event.payload#>>'{data,object,invoice_pdf}',''),
    provider_receipt_url=coalesce(
      nullif(event.payload#>>'{data,object,receipt_url}',''),
      nullif(event.payload#>>'{data,object,charge,receipt_url}','')
    )
from public.billing_provider_events event
where event.provider='stripe' and event.event_id=invoice.last_event_id;

create table public.platform_operating_expense_entries_v146 (
  id uuid primary key default gen_random_uuid(),
  entry_type text not null check (entry_type in ('expense','reversal')),
  reversal_of uuid references public.platform_operating_expense_entries_v146(id) on delete restrict,
  expense_date date not null,
  category text not null check (category in (
    'software','marketing','professional_services','banking','operations','other'
  )),
  description text not null check (length(btrim(description)) between 3 and 240),
  amount_cents integer not null check (amount_cents > 0),
  currency text not null default 'SGD' check (currency='SGD'),
  recorded_by uuid not null references auth.users(id) on delete restrict,
  idempotency_key uuid not null,
  request_hash text not null check (request_hash ~ '^[0-9a-f]{64}$'),
  created_at timestamptz not null default now(),
  constraint platform_operating_expense_entry_shape_v146_check check (
    (entry_type='expense' and reversal_of is null)
    or (entry_type='reversal' and reversal_of is not null)
  ),
  unique(recorded_by,idempotency_key)
);
create unique index platform_operating_expense_one_reversal_v146_uk
  on public.platform_operating_expense_entries_v146(reversal_of)
  where reversal_of is not null;
create index platform_operating_expense_date_v146_idx
  on public.platform_operating_expense_entries_v146(expense_date desc,created_at desc);

alter table public.platform_operating_expense_entries_v146 enable row level security;
revoke all privileges on table public.platform_operating_expense_entries_v146
  from public,anon,authenticated;

create or replace function app.platform_expense_immutable_v146()
returns trigger language plpgsql
set search_path to 'pg_catalog','public','app','pg_temp'
as $$begin raise exception 'platform expense ledger entries are immutable';end$$;
revoke all on function app.platform_expense_immutable_v146() from public;
create trigger platform_operating_expense_immutable_v146
before update or delete on public.platform_operating_expense_entries_v146
for each row execute function app.platform_expense_immutable_v146();

create or replace function public.platform_record_operating_expense_v146(
  p_expense_date date,p_category text,p_description text,p_amount_cents integer,
  p_currency text,p_idempotency_key uuid
)
returns jsonb language plpgsql security definer
set search_path to 'pg_catalog','public','app','extensions','pg_temp'
as $$
declare v_actor uuid:=auth.uid();v_hash text;v_existing public.platform_operating_expense_entries_v146%rowtype;
  v_row public.platform_operating_expense_entries_v146%rowtype;
begin
  if v_actor is null or not app.is_super_admin() then
    raise exception 'super-admin access is required' using errcode='42501';
  end if;
  if p_expense_date is null or p_expense_date>(clock_timestamp() at time zone 'Asia/Singapore')::date
     or p_category not in ('software','marketing','professional_services','banking','operations','other')
     or length(btrim(coalesce(p_description,''))) not between 3 and 240
     or coalesce(p_amount_cents,0)<=0 or upper(coalesce(p_currency,''))<>'SGD'
     or p_idempotency_key is null then
    raise exception 'valid SGD expense details are required' using errcode='22023';
  end if;
  v_hash:=encode(extensions.digest(convert_to(concat_ws('|',p_expense_date,p_category,btrim(p_description),p_amount_cents,'SGD'),'UTF8'),'sha256'),'hex');
  perform pg_advisory_xact_lock(hashtextextended(v_actor::text||':'||p_idempotency_key::text,0));
  select * into v_existing from public.platform_operating_expense_entries_v146
   where recorded_by=v_actor and idempotency_key=p_idempotency_key;
  if found then
    if v_existing.request_hash<>v_hash then
      raise exception 'idempotency key was reused with different input' using errcode='22023';
    end if;
    return jsonb_build_object('entry',to_jsonb(v_existing),'replayed',true);
  end if;
  insert into public.platform_operating_expense_entries_v146(
    entry_type,expense_date,category,description,amount_cents,currency,
    recorded_by,idempotency_key,request_hash
  ) values('expense',p_expense_date,p_category,btrim(p_description),p_amount_cents,
    'SGD',v_actor,p_idempotency_key,v_hash) returning * into v_row;
  insert into public.audit_log(business_id,actor,action,entity,entity_id,detail)
  values(null,v_actor,'PLATFORM_EXPENSE_RECORDED_V146','platform_operating_expense_entries_v146',v_row.id,
    jsonb_build_object('expense_date',v_row.expense_date,'category',v_row.category,'amount_cents',v_row.amount_cents,'currency',v_row.currency));
  return jsonb_build_object('entry',to_jsonb(v_row),'replayed',false);
end
$$;

create or replace function public.platform_reverse_operating_expense_v146(
  p_expense uuid,p_reason text,p_idempotency_key uuid
)
returns jsonb language plpgsql security definer
set search_path to 'pg_catalog','public','app','extensions','pg_temp'
as $$
declare v_actor uuid:=auth.uid();v_original public.platform_operating_expense_entries_v146%rowtype;
  v_existing public.platform_operating_expense_entries_v146%rowtype;v_row public.platform_operating_expense_entries_v146%rowtype;
  v_hash text;
begin
  if v_actor is null or not app.is_super_admin() then
    raise exception 'super-admin access is required' using errcode='42501';
  end if;
  if p_expense is null or length(btrim(coalesce(p_reason,''))) not between 3 and 240
     or p_idempotency_key is null then
    raise exception 'expense, reversal reason and idempotency key are required' using errcode='22023';
  end if;
  select * into v_original from public.platform_operating_expense_entries_v146
   where id=p_expense and entry_type='expense';
  if not found then raise exception 'platform expense was not found' using errcode='22023';end if;
  v_hash:=encode(extensions.digest(convert_to(concat_ws('|',p_expense,btrim(p_reason)),'UTF8'),'sha256'),'hex');
  perform pg_advisory_xact_lock(hashtextextended(v_actor::text||':'||p_idempotency_key::text,0));
  perform pg_advisory_xact_lock(hashtextextended('platform-expense:'||p_expense::text,0));
  select * into v_existing from public.platform_operating_expense_entries_v146
   where recorded_by=v_actor and idempotency_key=p_idempotency_key;
  if found then
    if v_existing.request_hash<>v_hash then
      raise exception 'idempotency key was reused with different input' using errcode='22023';
    end if;
    return jsonb_build_object('entry',to_jsonb(v_existing),'replayed',true);
  end if;
  if exists(select 1 from public.platform_operating_expense_entries_v146 where reversal_of=p_expense) then
    raise exception 'platform expense is already reversed' using errcode='22023';
  end if;
  insert into public.platform_operating_expense_entries_v146(
    entry_type,reversal_of,expense_date,category,description,amount_cents,currency,
    recorded_by,idempotency_key,request_hash
  ) values('reversal',p_expense,(clock_timestamp() at time zone 'Asia/Singapore')::date,v_original.category,btrim(p_reason),
    v_original.amount_cents,v_original.currency,v_actor,p_idempotency_key,v_hash)
  returning * into v_row;
  insert into public.audit_log(business_id,actor,action,entity,entity_id,detail)
  values(null,v_actor,'PLATFORM_EXPENSE_REVERSED_V146','platform_operating_expense_entries_v146',v_row.id,
    jsonb_build_object('reversal_of',p_expense,'amount_cents',v_row.amount_cents,'reason',v_row.description));
  return jsonb_build_object('entry',to_jsonb(v_row),'replayed',false);
end
$$;

create or replace function public.platform_get_finance_v146(
  p_from date,p_to date,p_limit integer default 100
)
returns jsonb language plpgsql stable security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare v_income bigint;v_adjustments bigint;v_expenses bigint;v_reversals bigint;v_pending bigint;
  v_start timestamptz;v_end timestamptz;
begin
  if auth.uid() is null or not app.is_super_admin() then
    raise exception 'super-admin access is required' using errcode='42501';
  end if;
  if p_from is null or p_to is null or p_to<p_from or p_to-p_from>1826
     or p_limit not between 1 and 5000 then
    raise exception 'valid finance range and limit are required' using errcode='22023';
  end if;
  v_start:=p_from::timestamp at time zone 'Asia/Singapore';
  v_end:=(p_to+1)::timestamp at time zone 'Asia/Singapore';
  select coalesce(sum(net_cash_ex_tax_cents),0) into v_income
    from public.billing_provider_invoices
   where paid_normalized and currency='SGD' and paid_at>=v_start and paid_at<v_end;
  select coalesce(sum(case
      when adjustment.adjustment_type in ('refund','chargeback','external_payment')
        then adjustment.total_cents
      when adjustment.adjustment_type='reversal'
       and original.adjustment_type in ('refund','chargeback','external_payment')
        then adjustment.total_cents
      else 0 end),0) into v_adjustments
    from public.billing_adjustments adjustment
    left join public.billing_adjustments original on original.id=adjustment.reversal_of
   where adjustment.currency='SGD' and adjustment.occurred_at>=v_start and adjustment.occurred_at<v_end;
  select coalesce(sum(amount_cents) filter(where entry_type='expense'),0),
         coalesce(sum(amount_cents) filter(where entry_type='reversal'),0)
    into v_expenses,v_reversals
    from public.platform_operating_expense_entries_v146
   where expense_date between p_from and p_to;
  select coalesce(sum(amount_remaining_cents),0) into v_pending
    from public.billing_provider_invoices
   where currency='SGD' and not paid_normalized and status='open' and created_at<v_end;
  return jsonb_build_object(
    'from',p_from,'to',p_to,'currency','SGD','basis','cash',
    'summary',jsonb_build_object(
      'income_cents',v_income,'billing_adjustments_cents',v_adjustments,
      'expense_outflows_cents',v_expenses,'expense_reversals_cents',v_reversals,
      'net_expenses_cents',v_expenses-v_reversals,
      'net_cash_cents',v_income+v_adjustments-v_expenses+v_reversals,
      'pending_invoice_cents',v_pending
    ),
    'row_counts',jsonb_build_object(
      'invoices',(select count(*) from public.billing_provider_invoices invoice where invoice.currency='SGD' and coalesce(invoice.paid_at,invoice.created_at)>=v_start and coalesce(invoice.paid_at,invoice.created_at)<v_end),
      'adjustments',(select count(*) from public.billing_adjustments adjustment where adjustment.currency='SGD' and adjustment.occurred_at>=v_start and adjustment.occurred_at<v_end),
      'expenses',(select count(*) from public.platform_operating_expense_entries_v146 entry where entry.expense_date between p_from and p_to)
    ),
    'complete',jsonb_build_object(
      'invoices',(select count(*)<=p_limit from public.billing_provider_invoices invoice where invoice.currency='SGD' and coalesce(invoice.paid_at,invoice.created_at)>=v_start and coalesce(invoice.paid_at,invoice.created_at)<v_end),
      'adjustments',(select count(*)<=p_limit from public.billing_adjustments adjustment where adjustment.currency='SGD' and adjustment.occurred_at>=v_start and adjustment.occurred_at<v_end),
      'expenses',(select count(*)<=p_limit from public.platform_operating_expense_entries_v146 entry where entry.expense_date between p_from and p_to)
    ),
    'invoices',coalesce((select jsonb_agg(to_jsonb(rows) order by rows.sort_at desc) from (
      select invoice.id,invoice.business_id,business.name business_name,
        invoice.provider_invoice_id,invoice.number,invoice.status,invoice.paid_normalized,
        invoice.currency,invoice.total_cents,invoice.amount_paid_cents,
        invoice.amount_remaining_cents,invoice.paid_at,invoice.created_at,
        invoice.hosted_invoice_url,invoice.invoice_pdf_url,invoice.provider_receipt_url,
        coalesce(invoice.paid_at,invoice.created_at) sort_at
      from public.billing_provider_invoices invoice
      join public.businesses business on business.id=invoice.business_id
      where invoice.currency='SGD' and coalesce(invoice.paid_at,invoice.created_at)>=v_start
        and coalesce(invoice.paid_at,invoice.created_at)<v_end
      order by sort_at desc limit p_limit
    ) rows),'[]'::jsonb),
    'adjustments',coalesce((select jsonb_agg(to_jsonb(rows) order by rows.occurred_at desc) from (
      select adjustment.id,adjustment.business_id,business.name business_name,
        adjustment.provider_invoice_id,adjustment.adjustment_type,
        adjustment.subtotal_ex_tax_cents,adjustment.tax_cents,adjustment.total_cents,
        adjustment.currency,adjustment.reason,adjustment.source_event_id,
        adjustment.provider_object_id,adjustment.reversal_of,adjustment.occurred_at,
        case
          when adjustment.adjustment_type in ('refund','chargeback','external_payment')
            then adjustment.total_cents
          when adjustment.adjustment_type='reversal'
           and original.adjustment_type in ('refund','chargeback','external_payment')
            then adjustment.total_cents
          else 0
        end cash_effect_cents,
        (adjustment.adjustment_type in ('refund','chargeback','external_payment')
          or (adjustment.adjustment_type='reversal'
            and original.adjustment_type in ('refund','chargeback','external_payment'))) cash_affecting
      from public.billing_adjustments adjustment
      left join public.billing_adjustments original on original.id=adjustment.reversal_of
      join public.businesses business on business.id=adjustment.business_id
      where adjustment.currency='SGD' and adjustment.occurred_at>=v_start
        and adjustment.occurred_at<v_end
      order by adjustment.occurred_at desc limit p_limit
    ) rows),'[]'::jsonb),
    'expenses',coalesce((select jsonb_agg(to_jsonb(rows) order by rows.expense_date desc,rows.created_at desc) from (
      select entry.id,entry.entry_type,entry.reversal_of,entry.expense_date,entry.category,
        entry.description,entry.amount_cents,entry.currency,entry.created_at,
        exists(select 1 from public.platform_operating_expense_entries_v146 reversal where reversal.reversal_of=entry.id) reversed
      from public.platform_operating_expense_entries_v146 entry
      where entry.expense_date between p_from and p_to
      order by entry.expense_date desc,entry.created_at desc limit p_limit
    ) rows),'[]'::jsonb)
  );
end
$$;

create or replace function public.get_business_billing_v146(p_business uuid)
returns jsonb language plpgsql stable security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare v_base jsonb;
begin
  v_base:=public.get_business_billing_v125(p_business);
  return jsonb_set(v_base,'{invoices}',coalesce((select jsonb_agg(to_jsonb(rows) order by rows.sort_at desc) from (
    select provider_invoice_id,number,status,paid_normalized,currency,
      subtotal_ex_tax_cents,tax_cents,total_cents,amount_paid_cents,
      amount_remaining_cents,collection_method,period_start,period_end,
      paid_at,next_payment_attempt_at,hosted_invoice_url,invoice_pdf_url,
      provider_receipt_url,coalesce(paid_at,created_at) sort_at
    from public.billing_provider_invoices where business_id=p_business
    order by coalesce(paid_at,created_at) desc limit 20
  ) rows),'[]'::jsonb),true);
end
$$;

revoke all on function public.platform_record_operating_expense_v146(date,text,text,integer,text,uuid) from public,anon,authenticated;
revoke all on function public.platform_reverse_operating_expense_v146(uuid,text,uuid) from public,anon,authenticated;
revoke all on function public.platform_get_finance_v146(date,date,integer) from public,anon,authenticated;
revoke all on function public.get_business_billing_v146(uuid) from public,anon,authenticated;
grant execute on function public.platform_record_operating_expense_v146(date,text,text,integer,text,uuid) to authenticated;
grant execute on function public.platform_reverse_operating_expense_v146(uuid,text,uuid) to authenticated;
grant execute on function public.platform_get_finance_v146(date,date,integer) to authenticated;
grant execute on function public.get_business_billing_v146(uuid) to authenticated;

commit;
