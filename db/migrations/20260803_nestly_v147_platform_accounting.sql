-- V147: append-only platform accounting, automated posting and controlled documents.
begin;

alter table public.platform_operating_expense_entries_v146
  add column counterparty_name text,
  add column counterparty_registration_number text,
  add column payment_reference text,
  add column evidence_reference text;
alter table public.platform_operating_expense_entries_v146
  add constraint platform_expense_counterparty_v147_check check (counterparty_name is null or length(btrim(counterparty_name)) between 2 and 200),
  add constraint platform_expense_payment_reference_v147_check check (payment_reference is null or length(btrim(payment_reference)) between 3 and 200),
  add constraint platform_expense_evidence_v147_check check (evidence_reference is null or length(btrim(evidence_reference)) between 8 and 300);

create table public.platform_accounting_accounts_v147 (
  code text primary key check (code ~ '^[0-9]{4}$'),
  name text not null check (length(btrim(name)) between 2 and 100),
  account_type text not null check (account_type in ('asset','liability','equity','revenue','expense')),
  normal_balance text not null check (normal_balance in ('debit','credit')),
  system_key text not null unique,
  active boolean not null default true
);
insert into public.platform_accounting_accounts_v147(code,name,account_type,normal_balance,system_key) values
  ('1000','Operating bank','asset','debit','operating_bank'),
  ('1010','Stripe clearing','asset','debit','stripe_clearing'),
  ('1100','Accounts receivable','asset','debit','accounts_receivable'),
  ('2200','GST output tax payable','liability','credit','gst_output_payable'),
  ('3000','Opening and retained earnings','equity','credit','retained_earnings'),
  ('4000','Subscription revenue','revenue','credit','subscription_revenue'),
  ('4090','Other operating revenue','revenue','credit','other_revenue'),
  ('4010','Refunds, credits and discounts','revenue','debit','sales_adjustments'),
  ('6100','Software expense','expense','debit','software_expense'),
  ('6110','Marketing expense','expense','debit','marketing_expense'),
  ('6120','Professional services expense','expense','debit','professional_services_expense'),
  ('6130','Office and operations expense','expense','debit','operations_expense'),
  ('6200','Payment dispute expense','expense','debit','payment_dispute_expense'),
  ('6300','Bad debt expense','expense','debit','bad_debt_expense'),
  ('6990','Other operating expense','expense','debit','other_expense');

create table public.platform_accounting_policies_v147 (
  id uuid primary key default gen_random_uuid(),
  version integer not null unique check (version>0),
  effective_from date not null,
  legal_name text not null check (length(btrim(legal_name)) between 2 and 200),
  registration_number text not null check (length(btrim(registration_number)) between 4 and 40),
  registered_address text not null check (length(btrim(registered_address)) between 5 and 500),
  functional_currency text not null default 'SGD' check (functional_currency='SGD'),
  gst_status text not null check (gst_status in ('not_registered','registered','pending_review')),
  gst_registration_number text,
  gst_rate_bps integer not null default 0 check (gst_rate_bps between 0 and 2000),
  financial_year_end_month integer not null check (financial_year_end_month between 1 and 12),
  financial_year_end_day integer not null check (financial_year_end_day between 1 and 31),
  document_prefix text not null check (document_prefix ~ '^[A-Z0-9]{2,10}$'),
  operation_key uuid not null,
  request_hash text not null check (request_hash ~ '^[0-9a-f]{64}$'),
  supersedes uuid references public.platform_accounting_policies_v147(id) on delete restrict,
  evidence_reference text not null check (length(btrim(evidence_reference)) between 8 and 300),
  created_by uuid not null references auth.users(id) on delete restrict,
  created_at timestamptz not null default clock_timestamp(),
  unique(created_by,operation_key),
  check (financial_year_end_day<=case when financial_year_end_month=2 then 29 when financial_year_end_month in (4,6,9,11) then 30 else 31 end),
  check ((gst_status='registered' and length(btrim(gst_registration_number)) between 4 and 40 and gst_rate_bps>0)
      or (gst_status<>'registered' and gst_registration_number is null and gst_rate_bps=0))
);
create index platform_accounting_policy_effective_v147_idx
  on public.platform_accounting_policies_v147(effective_from);

create table public.platform_accounting_period_events_v147 (
  id uuid primary key default gen_random_uuid(),
  period_from date not null,
  period_to date not null check (period_to>=period_from),
  action text not null check (action in ('lock','unlock')),
  reason text not null check (length(btrim(reason)) between 8 and 1000),
  operation_key uuid not null,
  request_hash text not null check (request_hash ~ '^[0-9a-f]{64}$'),
  created_by uuid not null references auth.users(id) on delete restrict,
  created_at timestamptz not null default clock_timestamp(),
  unique(created_by,operation_key)
);

create table public.platform_accounting_journal_entries_v147 (
  id uuid primary key default gen_random_uuid(),
  journal_number bigint generated always as identity unique,
  journal_date date not null,
  description text not null check (length(btrim(description)) between 3 and 500),
  source_type text not null check (source_type ~ '^[a-z0-9_]{3,60}$'),
  source_id text not null check (length(source_id) between 1 and 200),
  operation_key uuid,
  request_hash text not null check (request_hash ~ '^[0-9a-f]{64}$'),
  reversal_of uuid references public.platform_accounting_journal_entries_v147(id) on delete restrict,
  created_by uuid references auth.users(id) on delete restrict,
  created_at timestamptz not null default clock_timestamp(),
  unique(source_type,source_id),
  unique(created_by,operation_key)
);
create index platform_accounting_journal_date_v147_idx
  on public.platform_accounting_journal_entries_v147(journal_date,journal_number);

create table public.platform_accounting_journal_lines_v147 (
  entry_id uuid not null references public.platform_accounting_journal_entries_v147(id) on delete restrict,
  line_number integer not null check (line_number>0),
  account_code text not null references public.platform_accounting_accounts_v147(code) on delete restrict,
  debit_cents bigint not null default 0 check (debit_cents>=0),
  credit_cents bigint not null default 0 check (credit_cents>=0),
  memo text,
  counterparty text,
  primary key(entry_id,line_number),
  check ((debit_cents>0 and credit_cents=0) or (credit_cents>0 and debit_cents=0))
);
create index platform_accounting_lines_account_v147_idx
  on public.platform_accounting_journal_lines_v147(account_code,entry_id);

create table public.platform_financial_document_sequences_v147 (
  document_type text primary key check (document_type in ('invoice','receipt','credit_note','debit_note','payment_voucher','journal_voucher')),
  next_value bigint not null default 1 check (next_value>0)
);
insert into public.platform_financial_document_sequences_v147(document_type)
values('invoice'),('receipt'),('credit_note'),('debit_note'),('payment_voucher'),('journal_voucher');

create table public.platform_financial_documents_v147 (
  id uuid primary key,
  document_type text not null check (document_type in ('invoice','receipt','credit_note','debit_note','payment_voucher','journal_voucher')),
  document_number text not null unique check (length(document_number) between 6 and 40),
  issue_date date not null,
  due_date date,
  currency text not null default 'SGD' check (currency='SGD'),
  counterparty jsonb not null check (jsonb_typeof(counterparty)='object'),
  line_items jsonb not null check (jsonb_typeof(line_items)='array'),
  subtotal_cents bigint not null check (subtotal_cents>=0),
  tax_cents bigint not null check (tax_cents>=0),
  total_cents bigint not null check (total_cents=subtotal_cents+tax_cents and total_cents>0),
  source_type text not null check (source_type ~ '^[a-z0-9_]{3,60}$'),
  source_id text not null check (length(source_id) between 1 and 200),
  original_document uuid references public.platform_financial_documents_v147(id) on delete restrict,
  journal_entry uuid not null references public.platform_accounting_journal_entries_v147(id) on delete restrict,
  snapshot jsonb not null check (jsonb_typeof(snapshot)='object'),
  snapshot_sha256 text not null check (snapshot_sha256 ~ '^[0-9a-f]{64}$'),
  operation_key uuid not null,
  request_hash text not null check (request_hash ~ '^[0-9a-f]{64}$'),
  created_by uuid not null references auth.users(id) on delete restrict,
  created_at timestamptz not null default clock_timestamp(),
  unique(source_type,source_id),
  unique(created_by,operation_key)
);
create index platform_financial_documents_date_v147_idx
  on public.platform_financial_documents_v147(issue_date,document_number);

alter table public.platform_accounting_accounts_v147 enable row level security;
alter table public.platform_accounting_policies_v147 enable row level security;
alter table public.platform_accounting_period_events_v147 enable row level security;
alter table public.platform_accounting_journal_entries_v147 enable row level security;
alter table public.platform_accounting_journal_lines_v147 enable row level security;
alter table public.platform_financial_document_sequences_v147 enable row level security;
alter table public.platform_financial_documents_v147 enable row level security;
revoke all privileges on table public.platform_accounting_accounts_v147,public.platform_accounting_policies_v147,
  public.platform_accounting_period_events_v147,public.platform_accounting_journal_entries_v147,
  public.platform_accounting_journal_lines_v147,public.platform_financial_document_sequences_v147,
  public.platform_financial_documents_v147 from public,anon,authenticated;

create or replace function app.platform_accounting_immutable_v147()
returns trigger language plpgsql set search_path to 'pg_catalog','public','app','pg_temp' as $$
begin raise exception 'posted accounting records are immutable; reverse and replace instead' using errcode='55000';end
$$;
revoke all on function app.platform_accounting_immutable_v147() from public,anon,authenticated;
create trigger platform_accounting_policy_immutable_v147 before update or delete on public.platform_accounting_policies_v147 for each row execute function app.platform_accounting_immutable_v147();
create trigger platform_accounting_period_immutable_v147 before update or delete on public.platform_accounting_period_events_v147 for each row execute function app.platform_accounting_immutable_v147();
create trigger platform_accounting_journal_immutable_v147 before update or delete on public.platform_accounting_journal_entries_v147 for each row execute function app.platform_accounting_immutable_v147();
create trigger platform_accounting_lines_immutable_v147 before update or delete on public.platform_accounting_journal_lines_v147 for each row execute function app.platform_accounting_immutable_v147();
create trigger platform_document_immutable_v147 before update or delete on public.platform_financial_documents_v147 for each row execute function app.platform_accounting_immutable_v147();

create or replace function app.platform_accounting_date_locked_v147(p_date date)
returns boolean language sql stable security definer set search_path to 'pg_catalog','public','app','pg_temp' as $$
  select coalesce((select event.action='lock' from public.platform_accounting_period_events_v147 event
    where p_date between event.period_from and event.period_to order by event.created_at desc,event.id desc limit 1),false)
$$;
revoke all on function app.platform_accounting_date_locked_v147(date) from public,anon,authenticated;

create or replace function app.platform_post_journal_v147(
  p_source_type text,p_source_id text,p_date date,p_description text,p_lines jsonb,
  p_operation_key uuid default null,p_request_hash text default null,p_actor uuid default null,p_reversal_of uuid default null
) returns jsonb language plpgsql security definer set search_path to 'pg_catalog','public','app','pg_temp' as $$
declare v_existing public.platform_accounting_journal_entries_v147%rowtype;v_entry public.platform_accounting_journal_entries_v147%rowtype;
  v_hash text;v_debits bigint;v_credits bigint;v_count integer;
begin
  v_hash:=coalesce(p_request_hash,encode(extensions.digest(jsonb_build_object('source_type',p_source_type,'source_id',p_source_id,'date',p_date,'description',btrim(p_description),'lines',p_lines)::text,'sha256'),'hex'));
  perform pg_advisory_xact_lock(hashtextextended(p_source_type||':'||p_source_id,147));
  select * into v_existing from public.platform_accounting_journal_entries_v147 where source_type=p_source_type and source_id=p_source_id;
  if found then
    if v_existing.request_hash<>v_hash then raise exception 'accounting source was reused with different input' using errcode='22023';end if;
    return jsonb_build_object('entry',to_jsonb(v_existing),'replayed',true);
  end if;
  perform pg_advisory_xact_lock(hashtextextended('platform_accounting_period_gate',147));
  if p_date is null or app.platform_accounting_date_locked_v147(p_date) then raise exception 'accounting period is locked or invalid' using errcode='55000';end if;
  if jsonb_typeof(p_lines)<>'array' then raise exception 'journal lines must be an array' using errcode='22023';end if;
  select count(*),coalesce(sum((line->>'debit_cents')::bigint),0),coalesce(sum((line->>'credit_cents')::bigint),0)
    into v_count,v_debits,v_credits from jsonb_array_elements(p_lines) line
   where (line->>'account_code')~'^[0-9]{4}$'
     and coalesce((line->>'debit_cents')::bigint,0)>=0 and coalesce((line->>'credit_cents')::bigint,0)>=0
     and ((coalesce((line->>'debit_cents')::bigint,0)>0 and coalesce((line->>'credit_cents')::bigint,0)=0)
       or (coalesce((line->>'credit_cents')::bigint,0)>0 and coalesce((line->>'debit_cents')::bigint,0)=0));
  if v_count<>jsonb_array_length(p_lines) or v_count<2 or v_debits<=0 or v_debits<>v_credits
     or exists(select 1 from jsonb_array_elements(p_lines) line left join public.platform_accounting_accounts_v147 account on account.code=line->>'account_code' where account.code is null or not account.active) then
    raise exception 'journal must contain valid active accounts and balanced one-sided lines' using errcode='22023';
  end if;
  insert into public.platform_accounting_journal_entries_v147(journal_date,description,source_type,source_id,operation_key,request_hash,reversal_of,created_by)
  values(p_date,btrim(p_description),p_source_type,p_source_id,p_operation_key,v_hash,p_reversal_of,p_actor) returning * into v_entry;
  insert into public.platform_accounting_journal_lines_v147(entry_id,line_number,account_code,debit_cents,credit_cents,memo,counterparty)
  select v_entry.id,ordinality,(line->>'account_code'),coalesce((line->>'debit_cents')::bigint,0),coalesce((line->>'credit_cents')::bigint,0),nullif(btrim(line->>'memo'),''),nullif(btrim(line->>'counterparty'),'')
    from jsonb_array_elements(p_lines) with ordinality rows(line,ordinality);
  insert into public.audit_log(business_id,actor,action,entity,entity_id,detail)
  values(null,p_actor,'PLATFORM_JOURNAL_POSTED_V147','platform_accounting_journal_entries_v147',v_entry.id,jsonb_build_object('journal_number',v_entry.journal_number,'source_type',p_source_type,'source_id',p_source_id,'debits_cents',v_debits));
  return jsonb_build_object('entry',to_jsonb(v_entry),'replayed',false);
end
$$;
revoke all on function app.platform_post_journal_v147(text,text,date,text,jsonb,uuid,text,uuid,uuid) from public,anon,authenticated;

create or replace function app.platform_reverse_journal_v147(p_original uuid,p_source_type text,p_source_id text,p_date date,p_description text,p_operation_key uuid,p_actor uuid)
returns jsonb language plpgsql security definer set search_path to 'pg_catalog','public','app','pg_temp' as $$
declare v_lines jsonb;v_hash text;
begin
  if not exists(select 1 from public.platform_accounting_journal_entries_v147 where id=p_original) then raise exception 'original journal was not found' using errcode='22023';end if;
  select jsonb_agg(jsonb_build_object('account_code',account_code,'debit_cents',credit_cents,'credit_cents',debit_cents,'memo','Reversal: '||coalesce(memo,''),'counterparty',counterparty) order by line_number)
    into v_lines from public.platform_accounting_journal_lines_v147 where entry_id=p_original;
  v_hash:=encode(extensions.digest(jsonb_build_object('original',p_original,'date',p_date,'description',btrim(p_description))::text,'sha256'),'hex');
  return app.platform_post_journal_v147(p_source_type,p_source_id,p_date,p_description,v_lines,p_operation_key,v_hash,p_actor,p_original);
end
$$;
revoke all on function app.platform_reverse_journal_v147(uuid,text,text,date,text,uuid,uuid) from public,anon,authenticated;

create or replace function app.platform_expense_account_v147(p_category text)
returns text language sql immutable as $$ select case p_category when 'software' then '6100' when 'marketing' then '6110' when 'professional_services' then '6120' when 'operations' then '6130' else '6990' end $$;
revoke all on function app.platform_expense_account_v147(text) from public,anon,authenticated;

create or replace function app.platform_sync_provider_invoice_v147(p_invoice public.billing_provider_invoices)
returns void language plpgsql security definer set search_path to 'pg_catalog','public','app','pg_temp' as $$
declare v_date date;v_result jsonb;v_counterparty text:=p_invoice.business_id::text;v_issued uuid;v_terminal uuid;
  v_target_paid bigint:=least(p_invoice.total_cents,p_invoice.amount_paid_cents);v_posted_paid bigint;v_payment_delta bigint;
  v_remaining bigint;v_remaining_tax bigint;v_remaining_subtotal bigint;v_lines jsonb;
  v_terminal_total bigint;v_recovered_total bigint;v_recovery_delta bigint;v_recovered_tax bigint;v_prior_recovered_tax bigint;v_recovery_tax bigint;v_recovery_subtotal bigint;
begin
  if p_invoice.currency<>'SGD' or p_invoice.status='draft' or p_invoice.total_cents<=0 then return;end if;
  perform pg_advisory_xact_lock(hashtextextended('platform_provider_invoice_state:'||p_invoice.provider_invoice_id,147));
  v_date:=(coalesce(p_invoice.created_at,clock_timestamp()) at time zone 'Asia/Singapore')::date;
  select id into v_issued from public.platform_accounting_journal_entries_v147 where source_type='provider_invoice_issued' and source_id=p_invoice.provider_invoice_id;
  if v_issued is null then
    v_result:=app.platform_post_journal_v147('provider_invoice_issued',p_invoice.provider_invoice_id,v_date,'Provider invoice '||p_invoice.provider_invoice_id||' issued',jsonb_build_array(
      jsonb_build_object('account_code','1100','debit_cents',p_invoice.total_cents,'credit_cents',0,'counterparty',v_counterparty),
      jsonb_build_object('account_code','4000','debit_cents',0,'credit_cents',p_invoice.subtotal_ex_tax_cents,'counterparty',v_counterparty)
    )||case when p_invoice.tax_cents>0 then jsonb_build_array(jsonb_build_object('account_code','2200','debit_cents',0,'credit_cents',p_invoice.tax_cents,'counterparty',v_counterparty)) else '[]'::jsonb end,null,null,null,null);
    v_issued:=(v_result#>>'{entry,id}')::uuid;
  end if;

  select coalesce(sum(line.debit_cents),0) into v_posted_paid
    from public.platform_accounting_journal_entries_v147 entry join public.platform_accounting_journal_lines_v147 line on line.entry_id=entry.id and line.account_code='1010'
   where entry.source_type='provider_invoice_payment' and left(entry.source_id,length(p_invoice.provider_invoice_id)+1)=p_invoice.provider_invoice_id||':';
  v_payment_delta:=greatest(0,v_target_paid-v_posted_paid);
  if v_payment_delta>0 then
    v_date:=(coalesce(p_invoice.paid_at,p_invoice.provider_event_created_at,p_invoice.created_at) at time zone 'Asia/Singapore')::date;
    select id into v_terminal from public.platform_accounting_journal_entries_v147 where source_type='provider_invoice_uncollectible' and source_id=p_invoice.provider_invoice_id;
    if v_terminal is not null and not exists(select 1 from public.platform_accounting_journal_entries_v147 where source_type='provider_invoice_uncollectible_to_void' and source_id=p_invoice.provider_invoice_id) then
      select coalesce(sum(debit_cents),0) into v_terminal_total from public.platform_accounting_journal_lines_v147 where entry_id=v_terminal and account_code='6300';
      select coalesce(sum(line.credit_cents),0) into v_recovered_total from public.platform_accounting_journal_entries_v147 entry join public.platform_accounting_journal_lines_v147 line on line.entry_id=entry.id and line.account_code='6300' where entry.source_type='provider_invoice_uncollectible_recovery' and left(entry.source_id,length(p_invoice.provider_invoice_id)+1)=p_invoice.provider_invoice_id||':';
      v_recovery_delta:=least(v_payment_delta,greatest(0,v_terminal_total-v_recovered_total));
      if v_recovery_delta>0 then
        v_result:=app.platform_post_journal_v147('provider_invoice_uncollectible_recovery',p_invoice.provider_invoice_id||':'||v_target_paid,v_date,'Recovery of uncollectible provider invoice '||p_invoice.provider_invoice_id,jsonb_build_array(
          jsonb_build_object('account_code','1100','debit_cents',v_recovery_delta,'credit_cents',0,'counterparty',v_counterparty),
          jsonb_build_object('account_code','6300','debit_cents',0,'credit_cents',v_recovery_delta,'counterparty',v_counterparty)
        ),null,null,null,v_terminal);
      end if;
    end if;
    select id into v_terminal from public.platform_accounting_journal_entries_v147 where source_type='provider_invoice_void' and source_id=p_invoice.provider_invoice_id;
    if v_terminal is not null then
      select coalesce(sum(credit_cents),0) into v_terminal_total from public.platform_accounting_journal_lines_v147 where entry_id=v_terminal and account_code='1100';
      select coalesce(sum(line.debit_cents),0),coalesce(sum(line.credit_cents) filter(where line.account_code='2200'),0)
        into v_recovered_total,v_prior_recovered_tax from public.platform_accounting_journal_entries_v147 entry join public.platform_accounting_journal_lines_v147 line on line.entry_id=entry.id where entry.source_type='provider_invoice_void_recovery' and left(entry.source_id,length(p_invoice.provider_invoice_id)+1)=p_invoice.provider_invoice_id||':' and line.account_code in ('1100','2200');
      v_recovery_delta:=least(v_payment_delta,greatest(0,v_terminal_total-v_recovered_total));
      if v_recovery_delta>0 then
        v_recovered_tax:=round((v_recovered_total+v_recovery_delta)*p_invoice.tax_cents::numeric/p_invoice.total_cents);
        v_recovery_tax:=v_recovered_tax-v_prior_recovered_tax;v_recovery_subtotal:=v_recovery_delta-v_recovery_tax;
        v_lines:=jsonb_build_array(jsonb_build_object('account_code','1100','debit_cents',v_recovery_delta,'credit_cents',0,'counterparty',v_counterparty),jsonb_build_object('account_code','4000','debit_cents',0,'credit_cents',v_recovery_subtotal,'counterparty',v_counterparty))||case when v_recovery_tax>0 then jsonb_build_array(jsonb_build_object('account_code','2200','debit_cents',0,'credit_cents',v_recovery_tax,'counterparty',v_counterparty)) else '[]'::jsonb end;
        v_result:=app.platform_post_journal_v147('provider_invoice_void_recovery',p_invoice.provider_invoice_id||':'||v_target_paid,v_date,'Recovery of void provider invoice '||p_invoice.provider_invoice_id,v_lines,null,null,null,v_terminal);
      end if;
    end if;
    v_result:=app.platform_post_journal_v147('provider_invoice_payment',p_invoice.provider_invoice_id||':'||v_target_paid,v_date,'Provider invoice payment '||p_invoice.provider_invoice_id,jsonb_build_array(
      jsonb_build_object('account_code','1010','debit_cents',v_payment_delta,'credit_cents',0,'counterparty',v_counterparty),
      jsonb_build_object('account_code','1100','debit_cents',0,'credit_cents',v_payment_delta,'counterparty',v_counterparty)
    ),null,null,null,null);
  end if;

  if p_invoice.status='void' then
    select id into v_terminal from public.platform_accounting_journal_entries_v147 where source_type='provider_invoice_uncollectible' and source_id=p_invoice.provider_invoice_id;
    if v_terminal is not null and not exists(select 1 from public.platform_accounting_journal_entries_v147 where source_type='provider_invoice_uncollectible_to_void' and source_id=p_invoice.provider_invoice_id) then
      select coalesce(sum(debit_cents),0) into v_terminal_total from public.platform_accounting_journal_lines_v147 where entry_id=v_terminal and account_code='6300';
      select coalesce(sum(line.credit_cents),0) into v_recovered_total from public.platform_accounting_journal_entries_v147 entry join public.platform_accounting_journal_lines_v147 line on line.entry_id=entry.id and line.account_code='6300' where entry.source_type='provider_invoice_uncollectible_recovery' and left(entry.source_id,length(p_invoice.provider_invoice_id)+1)=p_invoice.provider_invoice_id||':';
      v_recovery_delta:=greatest(0,v_terminal_total-v_recovered_total);
      if v_recovery_delta>0 then
        v_date:=(coalesce(p_invoice.voided_at,p_invoice.provider_event_created_at,p_invoice.created_at) at time zone 'Asia/Singapore')::date;
        v_result:=app.platform_post_journal_v147('provider_invoice_uncollectible_to_void',p_invoice.provider_invoice_id,v_date,'Reclassify uncollectible provider invoice before void '||p_invoice.provider_invoice_id,jsonb_build_array(
          jsonb_build_object('account_code','1100','debit_cents',v_recovery_delta,'credit_cents',0,'counterparty',v_counterparty),
          jsonb_build_object('account_code','6300','debit_cents',0,'credit_cents',v_recovery_delta,'counterparty',v_counterparty)
        ),null,null,null,v_terminal);
      end if;
    end if;
  end if;

  if p_invoice.status in ('void','uncollectible') then
    select id into v_terminal from public.platform_accounting_journal_entries_v147 where source_type=case when p_invoice.status='void' then 'provider_invoice_void' else 'provider_invoice_uncollectible' end and source_id=p_invoice.provider_invoice_id;
    v_remaining:=greatest(0,p_invoice.total_cents-v_target_paid);
    if v_terminal is null and v_remaining>0 then
      v_date:=(coalesce(case when p_invoice.status='void' then p_invoice.voided_at else p_invoice.marked_uncollectible_at end,p_invoice.provider_event_created_at,p_invoice.created_at) at time zone 'Asia/Singapore')::date;
      if p_invoice.status='void' then
        v_remaining_tax:=round(v_remaining*p_invoice.tax_cents::numeric/p_invoice.total_cents);
        v_remaining_subtotal:=v_remaining-v_remaining_tax;
        v_lines:=jsonb_build_array(
          jsonb_build_object('account_code','4000','debit_cents',v_remaining_subtotal,'credit_cents',0,'counterparty',v_counterparty),
          jsonb_build_object('account_code','1100','debit_cents',0,'credit_cents',v_remaining,'counterparty',v_counterparty)
        )||case when v_remaining_tax>0 then jsonb_build_array(jsonb_build_object('account_code','2200','debit_cents',v_remaining_tax,'credit_cents',0,'counterparty',v_counterparty)) else '[]'::jsonb end;
        v_result:=app.platform_post_journal_v147('provider_invoice_void',p_invoice.provider_invoice_id,v_date,'Void provider invoice '||p_invoice.provider_invoice_id,v_lines,null,null,null,v_issued);
      else
        v_result:=app.platform_post_journal_v147('provider_invoice_uncollectible',p_invoice.provider_invoice_id,v_date,'Provider invoice marked uncollectible '||p_invoice.provider_invoice_id,jsonb_build_array(
          jsonb_build_object('account_code','6300','debit_cents',v_remaining,'credit_cents',0,'counterparty',v_counterparty),
          jsonb_build_object('account_code','1100','debit_cents',0,'credit_cents',v_remaining,'counterparty',v_counterparty)
        ),null,null,null,v_issued);
      end if;
    end if;
  end if;
end
$$;
revoke all on function app.platform_sync_provider_invoice_v147(public.billing_provider_invoices) from public,anon,authenticated;

create or replace function app.platform_sync_provider_invoice_event_v147(p_event public.billing_provider_events)
returns void language plpgsql security definer set search_path to 'pg_catalog','public','app','pg_temp' as $$
declare v_object jsonb:=p_event.payload#>'{data,object}';v_invoice public.billing_provider_invoices%rowtype;v_subtotal integer;v_total integer;
begin
  if p_event.processing_status<>'processed' or p_event.event_type not like 'invoice.%' or jsonb_typeof(v_object)<>'object' then return;end if;
  select * into v_invoice from public.billing_provider_invoices where provider_invoice_id=coalesce(v_object->>'id',p_event.object_id);
  if not found then return;end if;
  v_subtotal:=greatest(coalesce(nullif(v_object->>'total_excluding_tax','')::integer,nullif(v_object->>'subtotal_excluding_tax','')::integer,nullif(v_object->>'subtotal','')::integer,v_invoice.subtotal_ex_tax_cents),0);
  v_total:=greatest(coalesce(nullif(v_object->>'total','')::integer,v_subtotal),0);
  v_invoice.business_id:=coalesce(p_event.business_id,v_invoice.business_id);
  v_invoice.provider_invoice_id:=coalesce(v_object->>'id',p_event.object_id);
  v_invoice.currency:=upper(coalesce(nullif(v_object->>'currency',''),v_invoice.currency));
  v_invoice.status:=case when p_event.event_type='invoice.paid' then 'paid' when p_event.event_type='invoice.voided' then 'void' when p_event.event_type='invoice.marked_uncollectible' then 'uncollectible' when v_object->>'status' in ('draft','open','void','uncollectible') then v_object->>'status' else 'open' end;
  v_invoice.paid_normalized:=p_event.event_type='invoice.paid';
  v_invoice.subtotal_ex_tax_cents:=v_subtotal;v_invoice.total_cents:=v_total;v_invoice.tax_cents:=greatest(v_total-v_subtotal,0);
  v_invoice.amount_paid_cents:=greatest(coalesce(nullif(v_object->>'amount_paid','')::integer,0),0);
  v_invoice.amount_remaining_cents:=greatest(coalesce(nullif(v_object->>'amount_remaining','')::integer,v_total-v_invoice.amount_paid_cents,0),0);
  v_invoice.provider_event_created_at:=p_event.event_created_at;
  v_invoice.paid_at:=case when p_event.event_type='invoice.paid' then coalesce(app.stripe_epoch_v77(v_object#>'{status_transitions,paid_at}'),p_event.event_created_at) end;
  v_invoice.voided_at:=case when p_event.event_type='invoice.voided' then coalesce(app.stripe_epoch_v77(v_object#>'{status_transitions,voided_at}'),p_event.event_created_at) end;
  v_invoice.marked_uncollectible_at:=case when p_event.event_type='invoice.marked_uncollectible' then coalesce(app.stripe_epoch_v77(v_object#>'{status_transitions,marked_uncollectible_at}'),p_event.event_created_at) end;
  perform app.platform_sync_provider_invoice_v147(v_invoice);
end
$$;
revoke all on function app.platform_sync_provider_invoice_event_v147(public.billing_provider_events) from public,anon,authenticated;

create or replace function app.platform_provider_invoice_trigger_v147()
returns trigger language plpgsql security definer set search_path to 'pg_catalog','public','app','pg_temp' as $$ begin perform app.platform_sync_provider_invoice_v147(new);return new;end $$;
revoke all on function app.platform_provider_invoice_trigger_v147() from public,anon,authenticated;
create trigger platform_provider_invoice_post_v147 after insert or update of status,paid_normalized,subtotal_ex_tax_cents,tax_cents,total_cents,amount_paid_cents,paid_at on public.billing_provider_invoices for each row execute function app.platform_provider_invoice_trigger_v147();

create or replace function app.platform_sync_billing_adjustment_v147(p_adjustment public.billing_adjustments)
returns void language plpgsql security definer set search_path to 'pg_catalog','public','app','pg_temp' as $$
declare v_amount bigint:=abs(p_adjustment.total_cents);v_date date:=(p_adjustment.occurred_at at time zone 'Asia/Singapore')::date;v_result jsonb;v_original uuid;v_lines jsonb;
begin
  if p_adjustment.currency<>'SGD' then return;end if;
  if p_adjustment.adjustment_type='reversal' then
    select id into v_original from public.platform_accounting_journal_entries_v147 where source_type='billing_adjustment' and source_id=p_adjustment.reversal_of::text;
    if v_original is not null then v_result:=app.platform_reverse_journal_v147(v_original,'billing_adjustment',p_adjustment.id::text,v_date,p_adjustment.reason,null,p_adjustment.recorded_by);end if;
    return;
  end if;
  v_lines:=case p_adjustment.adjustment_type
    when 'refund' then jsonb_build_array(jsonb_build_object('account_code','4010','debit_cents',v_amount,'credit_cents',0),jsonb_build_object('account_code','1010','debit_cents',0,'credit_cents',v_amount))
    when 'chargeback' then jsonb_build_array(jsonb_build_object('account_code','6200','debit_cents',v_amount,'credit_cents',0),jsonb_build_object('account_code','1010','debit_cents',0,'credit_cents',v_amount))
    when 'external_payment' then jsonb_build_array(jsonb_build_object('account_code','1000','debit_cents',v_amount,'credit_cents',0),jsonb_build_object('account_code','1100','debit_cents',0,'credit_cents',v_amount))
    when 'credit' then jsonb_build_array(jsonb_build_object('account_code','4010','debit_cents',v_amount,'credit_cents',0),jsonb_build_object('account_code','1100','debit_cents',0,'credit_cents',v_amount))
    when 'debit' then jsonb_build_array(jsonb_build_object('account_code','1100','debit_cents',v_amount,'credit_cents',0),jsonb_build_object('account_code','4090','debit_cents',0,'credit_cents',v_amount))
    when 'writeoff' then jsonb_build_array(jsonb_build_object('account_code','6300','debit_cents',v_amount,'credit_cents',0),jsonb_build_object('account_code','1100','debit_cents',0,'credit_cents',v_amount)) end;
  if v_lines is not null then v_result:=app.platform_post_journal_v147('billing_adjustment',p_adjustment.id::text,v_date,p_adjustment.reason,v_lines,null,null,p_adjustment.recorded_by,null);end if;
end
$$;
revoke all on function app.platform_sync_billing_adjustment_v147(public.billing_adjustments) from public,anon,authenticated;
create or replace function app.platform_billing_adjustment_trigger_v147() returns trigger language plpgsql security definer set search_path to 'pg_catalog','public','app','pg_temp' as $$ begin perform app.platform_sync_billing_adjustment_v147(new);return new;end $$;
revoke all on function app.platform_billing_adjustment_trigger_v147() from public,anon,authenticated;
create trigger platform_billing_adjustment_post_v147 after insert on public.billing_adjustments for each row execute function app.platform_billing_adjustment_trigger_v147();

create or replace function app.platform_sync_expense_v147(p_expense public.platform_operating_expense_entries_v146)
returns void language plpgsql security definer set search_path to 'pg_catalog','public','app','pg_temp' as $$
declare v_result jsonb;v_original uuid;v_lines jsonb;
begin
  if p_expense.currency<>'SGD' then return;end if;
  if p_expense.entry_type='reversal' then
    select id into v_original from public.platform_accounting_journal_entries_v147 where source_type='platform_expense' and source_id=p_expense.reversal_of::text;
    if v_original is not null then v_result:=app.platform_reverse_journal_v147(v_original,'platform_expense',p_expense.id::text,p_expense.expense_date,p_expense.description,null,p_expense.recorded_by);end if;
  else
    v_lines:=jsonb_build_array(jsonb_build_object('account_code',app.platform_expense_account_v147(p_expense.category),'debit_cents',p_expense.amount_cents,'credit_cents',0),jsonb_build_object('account_code','1000','debit_cents',0,'credit_cents',p_expense.amount_cents));
    v_result:=app.platform_post_journal_v147('platform_expense',p_expense.id::text,p_expense.expense_date,p_expense.description,v_lines,null,null,p_expense.recorded_by,null);
  end if;
end
$$;
revoke all on function app.platform_sync_expense_v147(public.platform_operating_expense_entries_v146) from public,anon,authenticated;
create or replace function app.platform_expense_trigger_v147() returns trigger language plpgsql security definer set search_path to 'pg_catalog','public','app','pg_temp' as $$ begin perform app.platform_sync_expense_v147(new);return new;end $$;
revoke all on function app.platform_expense_trigger_v147() from public,anon,authenticated;
create trigger platform_expense_post_v147 after insert on public.platform_operating_expense_entries_v146 for each row execute function app.platform_expense_trigger_v147();

-- Replay retained provider events so historical books match the live state machine.
-- Projection-only rows are a legacy fallback and are never double-backfilled.
do $$ declare row_record record;begin
  for row_record in select event from public.billing_provider_events event where event.processing_status='processed' and event.event_type like 'invoice.%' order by event.object_id,event.event_created_at,app.stripe_event_rank_v77(event.event_type),event.event_id loop perform app.platform_sync_provider_invoice_event_v147(row_record.event);end loop;
  for row_record in select invoice from public.billing_provider_invoices invoice where not exists(select 1 from public.billing_provider_events event where event.processing_status='processed' and event.event_type like 'invoice.%' and event.object_id=invoice.provider_invoice_id) order by coalesce(invoice.created_at,invoice.paid_at),invoice.id loop perform app.platform_sync_provider_invoice_v147(row_record.invoice);end loop;
  for row_record in select adjustment from public.billing_adjustments adjustment order by adjustment.occurred_at,adjustment.id loop perform app.platform_sync_billing_adjustment_v147(row_record.adjustment);end loop;
  for row_record in select expense from public.platform_operating_expense_entries_v146 expense order by expense.created_at,expense.id loop perform app.platform_sync_expense_v147(row_record.expense);end loop;
end $$;

create or replace function public.platform_set_accounting_policy_v147(
  p_effective_from date,p_legal_name text,p_registration_number text,p_registered_address text,
  p_gst_status text,p_gst_registration_number text,p_gst_rate_bps integer,
  p_fye_month integer,p_fye_day integer,p_document_prefix text,p_evidence_reference text,p_idempotency_key uuid
) returns jsonb language plpgsql security definer set search_path to 'pg_catalog','public','app','pg_temp' as $$
declare v_actor uuid:=auth.uid();v_hash text;v_existing public.platform_accounting_policies_v147%rowtype;v_previous uuid;v_row public.platform_accounting_policies_v147%rowtype;v_version integer;
begin
  if v_actor is null or not app.is_super_admin() then raise exception 'super-admin access is required' using errcode='42501';end if;
  if p_idempotency_key is null then raise exception 'idempotency key is required' using errcode='22023';end if;
  v_hash:=encode(extensions.digest(jsonb_build_object('effective_from',p_effective_from,'legal_name',btrim(p_legal_name),'registration_number',btrim(p_registration_number),'address',btrim(p_registered_address),'gst_status',p_gst_status,'gst_number',nullif(btrim(p_gst_registration_number),''),'gst_rate_bps',p_gst_rate_bps,'fye_month',p_fye_month,'fye_day',p_fye_day,'prefix',upper(btrim(p_document_prefix)),'evidence',btrim(p_evidence_reference))::text,'sha256'),'hex');
  perform pg_advisory_xact_lock(hashtextextended('platform_accounting_policy:'||p_idempotency_key::text,147));
  select * into v_existing from public.platform_accounting_policies_v147 where created_by=v_actor and operation_key=p_idempotency_key;
  if found then
    if v_existing.request_hash<>v_hash then raise exception 'idempotency key was reused with different input' using errcode='22023';end if;
    return jsonb_build_object('policy',to_jsonb(v_existing),'replayed',true);
  end if;
  if p_effective_from is null or p_effective_from<(clock_timestamp() at time zone 'Asia/Singapore')::date-366 or p_gst_status not in ('not_registered','registered','pending_review') then raise exception 'valid policy configuration is required' using errcode='22023';end if;
  perform pg_advisory_xact_lock(hashtextextended('platform_accounting_policy_version',147));
  select id into v_previous from public.platform_accounting_policies_v147 order by effective_from desc,version desc limit 1;
  select coalesce(max(version),0)+1 into v_version from public.platform_accounting_policies_v147;
  insert into public.platform_accounting_policies_v147(version,effective_from,legal_name,registration_number,registered_address,gst_status,gst_registration_number,gst_rate_bps,financial_year_end_month,financial_year_end_day,document_prefix,operation_key,request_hash,supersedes,evidence_reference,created_by)
  values(v_version,p_effective_from,btrim(p_legal_name),btrim(p_registration_number),btrim(p_registered_address),p_gst_status,nullif(btrim(p_gst_registration_number),''),p_gst_rate_bps,p_fye_month,p_fye_day,upper(btrim(p_document_prefix)),p_idempotency_key,v_hash,v_previous,btrim(p_evidence_reference),v_actor) returning * into v_row;
  insert into public.audit_log(business_id,actor,action,entity,entity_id,detail) values(null,v_actor,'PLATFORM_ACCOUNTING_POLICY_SET_V147','platform_accounting_policies_v147',v_row.id,jsonb_build_object('operation_key',p_idempotency_key,'request_hash',v_hash,'version',v_version));
  perform app.platform_sync_expense_document_v147(expense) from public.platform_operating_expense_entries_v146 expense order by expense.created_at,expense.id;
  return jsonb_build_object('policy',to_jsonb(v_row),'replayed',false);
end
$$;

create or replace function public.platform_set_accounting_period_lock_v147(p_from date,p_to date,p_locked boolean,p_reason text,p_idempotency_key uuid)
returns jsonb language plpgsql security definer set search_path to 'pg_catalog','public','app','pg_temp' as $$
declare v_actor uuid:=auth.uid();v_hash text;v_existing public.platform_accounting_period_events_v147%rowtype;v_row public.platform_accounting_period_events_v147%rowtype;
begin
  if v_actor is null or not app.is_super_admin() then raise exception 'super-admin access is required' using errcode='42501';end if;
  v_hash:=encode(extensions.digest(jsonb_build_object('from',p_from,'to',p_to,'locked',p_locked,'reason',btrim(p_reason))::text,'sha256'),'hex');
  perform pg_advisory_xact_lock(hashtextextended('platform_period:'||p_idempotency_key::text,147));
  select * into v_existing from public.platform_accounting_period_events_v147 where created_by=v_actor and operation_key=p_idempotency_key;
  if found then if v_existing.request_hash<>v_hash then raise exception 'idempotency key was reused with different input' using errcode='22023';end if;return jsonb_build_object('event',to_jsonb(v_existing),'replayed',true);end if;
  if p_from is null or p_to<p_from or p_to-p_from>366 or length(btrim(p_reason))<8 then raise exception 'valid period and reason are required' using errcode='22023';end if;
  perform pg_advisory_xact_lock(hashtextextended('platform_accounting_period_gate',147));
  insert into public.platform_accounting_period_events_v147(period_from,period_to,action,reason,operation_key,request_hash,created_by) values(p_from,p_to,case when p_locked then 'lock' else 'unlock' end,btrim(p_reason),p_idempotency_key,v_hash,v_actor) returning * into v_row;
  insert into public.audit_log(business_id,actor,action,entity,entity_id,detail) values(null,v_actor,'PLATFORM_ACCOUNTING_PERIOD_'||upper(v_row.action)||'_V147','platform_accounting_period_events_v147',v_row.id,jsonb_build_object('from',p_from,'to',p_to));
  return jsonb_build_object('event',to_jsonb(v_row),'replayed',false);
end
$$;

create or replace function app.platform_next_document_number_v147(p_type text,p_prefix text)
returns text language plpgsql security definer set search_path to 'pg_catalog','public','app','pg_temp' as $$ declare v_number bigint;v_code text;begin
  update public.platform_financial_document_sequences_v147 set next_value=next_value+1 where document_type=p_type returning next_value-1 into v_number;
  if v_number is null then raise exception 'unsupported financial document type' using errcode='22023';end if;
  v_code:=case p_type when 'invoice' then 'INV' when 'receipt' then 'RCT' when 'credit_note' then 'CN' when 'debit_note' then 'DN' when 'payment_voucher' then 'PV' else 'JV' end;
  return p_prefix||'-'||v_code||'-'||lpad(v_number::text,6,'0');
end $$;
revoke all on function app.platform_next_document_number_v147(text,text) from public,anon,authenticated;

create or replace function app.platform_document_issuer_v147(p_policy public.platform_accounting_policies_v147)
returns jsonb language sql stable set search_path to 'pg_catalog','public','app','pg_temp' as $$
  select jsonb_build_object('legal_name',p_policy.legal_name,'registration_number',p_policy.registration_number,
    'registered_address',p_policy.registered_address,'gst_status',p_policy.gst_status,
    'gst_registration_number',p_policy.gst_registration_number,'gst_rate_bps',p_policy.gst_rate_bps,
    'functional_currency',p_policy.functional_currency)
$$;
revoke all on function app.platform_document_issuer_v147(public.platform_accounting_policies_v147) from public,anon,authenticated;

create or replace function public.platform_record_operating_expense_v147(
  p_expense_date date,p_category text,p_description text,p_amount_cents integer,
  p_counterparty_name text,p_counterparty_registration_number text,p_payment_reference text,
  p_evidence_reference text,p_idempotency_key uuid
) returns jsonb language plpgsql security definer set search_path to 'pg_catalog','public','app','extensions','pg_temp' as $$
declare v_actor uuid:=auth.uid();v_hash text;v_existing public.platform_operating_expense_entries_v146%rowtype;v_row public.platform_operating_expense_entries_v146%rowtype;v_document public.platform_financial_documents_v147%rowtype;
begin
  if v_actor is null or not app.is_super_admin() then raise exception 'super-admin access is required' using errcode='42501';end if;
  if p_expense_date is null or p_expense_date>(clock_timestamp() at time zone 'Asia/Singapore')::date
     or p_category not in ('software','marketing','professional_services','banking','operations','other')
     or length(btrim(coalesce(p_description,''))) not between 3 and 240 or coalesce(p_amount_cents,0)<=0
     or length(btrim(coalesce(p_counterparty_name,''))) not between 2 and 200
     or length(btrim(coalesce(p_payment_reference,''))) not between 3 and 200
     or length(btrim(coalesce(p_evidence_reference,''))) not between 8 and 300 or p_idempotency_key is null then
    raise exception 'complete SGD supplier expense evidence is required' using errcode='22023';
  end if;
  if not exists(select 1 from public.platform_accounting_policies_v147 where effective_from<=p_expense_date) then raise exception 'reviewed accounting identity must be configured first' using errcode='55000';end if;
  v_hash:=encode(extensions.digest(jsonb_build_object('date',p_expense_date,'category',p_category,'description',btrim(p_description),'amount',p_amount_cents,'counterparty',btrim(p_counterparty_name),'counterparty_registration',nullif(btrim(p_counterparty_registration_number),''),'payment_reference',btrim(p_payment_reference),'evidence',btrim(p_evidence_reference))::text,'sha256'),'hex');
  perform pg_advisory_xact_lock(hashtextextended(v_actor::text||':'||p_idempotency_key::text,147));
  select * into v_existing from public.platform_operating_expense_entries_v146 where recorded_by=v_actor and idempotency_key=p_idempotency_key;
  if found then if v_existing.request_hash<>v_hash then raise exception 'idempotency key was reused with different input' using errcode='22023';end if;select * into v_document from public.platform_financial_documents_v147 where source_type='platform_expense_voucher' and source_id=v_existing.id::text;return jsonb_build_object('entry',to_jsonb(v_existing),'document',to_jsonb(v_document),'replayed',true);end if;
  insert into public.platform_operating_expense_entries_v146(entry_type,expense_date,category,description,amount_cents,currency,recorded_by,idempotency_key,request_hash,counterparty_name,counterparty_registration_number,payment_reference,evidence_reference)
  values('expense',p_expense_date,p_category,btrim(p_description),p_amount_cents,'SGD',v_actor,p_idempotency_key,v_hash,btrim(p_counterparty_name),nullif(btrim(p_counterparty_registration_number),''),btrim(p_payment_reference),btrim(p_evidence_reference)) returning * into v_row;
  insert into public.audit_log(business_id,actor,action,entity,entity_id,detail) values(null,v_actor,'PLATFORM_EXPENSE_RECORDED_V147','platform_operating_expense_entries_v146',v_row.id,jsonb_build_object('amount_cents',p_amount_cents,'counterparty',v_row.counterparty_name,'payment_reference',v_row.payment_reference,'evidence_reference',v_row.evidence_reference));
  select * into v_document from public.platform_financial_documents_v147 where source_type='platform_expense_voucher' and source_id=v_row.id::text;
  return jsonb_build_object('entry',to_jsonb(v_row),'document',to_jsonb(v_document),'replayed',false);
end
$$;

create or replace function public.platform_create_invoice_v147(p_issue_date date,p_due_date date,p_transaction_reference text,p_counterparty jsonb,p_line_items jsonb,p_tax_rate_bps integer,p_idempotency_key uuid)
returns jsonb language plpgsql security definer set search_path to 'pg_catalog','public','app','pg_temp' as $$
declare v_actor uuid:=auth.uid();v_policy public.platform_accounting_policies_v147%rowtype;v_existing public.platform_financial_documents_v147%rowtype;v_doc public.platform_financial_documents_v147%rowtype;
  v_id uuid:=gen_random_uuid();v_hash text;v_reference text:=upper(btrim(p_transaction_reference));v_subtotal bigint;v_tax bigint;v_total bigint;v_number text;v_journal jsonb;v_journal_id uuid;v_snapshot jsonb;
begin
  if v_actor is null or not app.is_super_admin() then raise exception 'super-admin access is required' using errcode='42501';end if;
  v_hash:=encode(extensions.digest(jsonb_build_object('issue_date',p_issue_date,'due_date',p_due_date,'transaction_reference',v_reference,'counterparty',p_counterparty,'line_items',p_line_items,'tax_rate_bps',p_tax_rate_bps)::text,'sha256'),'hex');
  perform pg_advisory_xact_lock(hashtextextended('platform_invoice:'||p_idempotency_key::text,147));
  select * into v_existing from public.platform_financial_documents_v147 where created_by=v_actor and operation_key=p_idempotency_key;
  if found then if v_existing.request_hash<>v_hash then raise exception 'idempotency key was reused with different input' using errcode='22023';end if;return jsonb_build_object('document',to_jsonb(v_existing),'replayed',true);end if;
  if v_reference is null or v_reference !~ '^NON-SUBSCRIPTION-[A-Z0-9][A-Z0-9._:/-]{0,82}$' then raise exception 'a unique approved NON-SUBSCRIPTION transaction reference is required' using errcode='22023';end if;
  perform pg_advisory_xact_lock(hashtextextended('platform_non_subscription_invoice:'||v_reference,147));
  if exists(select 1 from public.platform_financial_documents_v147 where source_type='generated_non_subscription_invoice' and source_id=v_reference)
     or exists(select 1 from public.billing_provider_invoices where upper(provider_invoice_id)=v_reference or upper(coalesce(number,''))=v_reference) then
    raise exception 'transaction reference already exists in generated or provider billing' using errcode='23505';
  end if;
  select * into v_policy from public.platform_accounting_policies_v147 where effective_from<=p_issue_date order by effective_from desc,version desc limit 1;
  if not found or v_policy.gst_status='pending_review' then raise exception 'reviewed accounting and tax identity must be configured first' using errcode='55000';end if;
  if p_due_date<p_issue_date or jsonb_typeof(p_counterparty)<>'object' or length(btrim(p_counterparty->>'legal_name'))<2 or jsonb_typeof(p_line_items)<>'array' or jsonb_array_length(p_line_items)=0 then raise exception 'valid invoice parties, dates and lines are required' using errcode='22023';end if;
  if (v_policy.gst_status='registered' and p_tax_rate_bps<>v_policy.gst_rate_bps) or (v_policy.gst_status<>'registered' and p_tax_rate_bps<>0) then raise exception 'invoice tax rate does not match reviewed tax status' using errcode='22023';end if;
  if v_policy.gst_status='registered' and (length(btrim(coalesce(p_counterparty->>'address','')))<5 or length(btrim(coalesce(p_counterparty->>'registration_number','')))<4) then raise exception 'GST invoice requires customer address and registration identity' using errcode='22023';end if;
  select sum((line->>'quantity')::bigint*(line->>'unit_amount_cents')::bigint) into v_subtotal from jsonb_array_elements(p_line_items) line where (line->>'quantity')::integer between 1 and 100000 and (line->>'unit_amount_cents')::integer>0 and length(btrim(line->>'description')) between 2 and 500;
  if v_subtotal is null or (select count(*) from jsonb_array_elements(p_line_items))<>(select count(*) from jsonb_array_elements(p_line_items) line where (line->>'quantity')::integer between 1 and 100000 and (line->>'unit_amount_cents')::integer>0 and length(btrim(line->>'description')) between 2 and 500) then raise exception 'invoice lines are invalid' using errcode='22023';end if;
  v_tax:=round(v_subtotal*p_tax_rate_bps/10000.0);v_total:=v_subtotal+v_tax;v_number:=app.platform_next_document_number_v147('invoice',v_policy.document_prefix);
  v_journal:=app.platform_post_journal_v147('generated_non_subscription_invoice',v_reference,p_issue_date,'Invoice '||v_number,jsonb_build_array(jsonb_build_object('account_code','1100','debit_cents',v_total,'credit_cents',0,'counterparty',p_counterparty->>'legal_name'),jsonb_build_object('account_code','4090','debit_cents',0,'credit_cents',v_subtotal,'counterparty',p_counterparty->>'legal_name'))||case when v_tax>0 then jsonb_build_array(jsonb_build_object('account_code','2200','debit_cents',0,'credit_cents',v_tax,'counterparty',p_counterparty->>'legal_name')) else '[]'::jsonb end,p_idempotency_key,v_hash,v_actor,null);
  v_journal_id:=(v_journal#>>'{entry,id}')::uuid;v_snapshot:=jsonb_build_object('issuer',app.platform_document_issuer_v147(v_policy),'number',v_number,'transaction_reference',v_reference,'issue_date',p_issue_date,'due_date',p_due_date,'counterparty',p_counterparty,'line_items',p_line_items,'subtotal_cents',v_subtotal,'tax_cents',v_tax,'total_cents',v_total,'currency','SGD');
  insert into public.platform_financial_documents_v147(id,document_type,document_number,issue_date,due_date,counterparty,line_items,subtotal_cents,tax_cents,total_cents,source_type,source_id,journal_entry,snapshot,snapshot_sha256,operation_key,request_hash,created_by)
  values(v_id,'invoice',v_number,p_issue_date,p_due_date,p_counterparty,p_line_items,v_subtotal,v_tax,v_total,'generated_non_subscription_invoice',v_reference,v_journal_id,v_snapshot,encode(extensions.digest(v_snapshot::text,'sha256'),'hex'),p_idempotency_key,v_hash,v_actor) returning * into v_doc;
  return jsonb_build_object('document',to_jsonb(v_doc),'snapshot',v_snapshot,'replayed',false);
end
$$;

create or replace function public.platform_record_invoice_receipt_v147(p_invoice uuid,p_payment_date date,p_amount_cents integer,p_reference text,p_idempotency_key uuid)
returns jsonb language plpgsql security definer set search_path to 'pg_catalog','public','app','pg_temp' as $$
declare v_actor uuid:=auth.uid();v_invoice public.platform_financial_documents_v147%rowtype;v_policy public.platform_accounting_policies_v147%rowtype;v_existing public.platform_financial_documents_v147%rowtype;v_doc public.platform_financial_documents_v147%rowtype;
 v_id uuid:=gen_random_uuid();v_hash text;v_paid bigint;v_credited bigint;v_debited bigint;v_number text;v_journal jsonb;v_journal_id uuid;v_snapshot jsonb;
begin
  if v_actor is null or not app.is_super_admin() then raise exception 'super-admin access is required' using errcode='42501';end if;
  v_hash:=encode(extensions.digest(jsonb_build_object('invoice',p_invoice,'date',p_payment_date,'amount',p_amount_cents,'reference',btrim(p_reference))::text,'sha256'),'hex');perform pg_advisory_xact_lock(hashtextextended('platform_receipt:'||p_idempotency_key::text,147));
  select * into v_existing from public.platform_financial_documents_v147 where created_by=v_actor and operation_key=p_idempotency_key;if found then if v_existing.request_hash<>v_hash then raise exception 'idempotency key was reused with different input' using errcode='22023';end if;return jsonb_build_object('document',to_jsonb(v_existing),'replayed',true);end if;
  perform pg_advisory_xact_lock(hashtextextended('platform_document_chain:'||p_invoice::text,147));
  select * into v_invoice from public.platform_financial_documents_v147 where id=p_invoice and document_type='invoice';if not found then raise exception 'invoice was not found' using errcode='22023';end if;
  select coalesce(sum(document.total_cents),0) into v_paid from public.platform_financial_documents_v147 document where document.original_document=p_invoice and document.document_type='receipt' and not exists(select 1 from public.platform_financial_documents_v147 reversal where reversal.original_document=document.id and reversal.document_type='journal_voucher');
  select coalesce(sum(document.total_cents),0) into v_credited from public.platform_financial_documents_v147 document where document.original_document=p_invoice and document.document_type='credit_note' and not exists(select 1 from public.platform_financial_documents_v147 reversal where reversal.original_document=document.id and reversal.document_type='journal_voucher');
  select coalesce(sum(document.total_cents),0) into v_debited from public.platform_financial_documents_v147 document where document.original_document=p_invoice and document.document_type='debit_note' and not exists(select 1 from public.platform_financial_documents_v147 reversal where reversal.original_document=document.id and reversal.document_type='journal_voucher');
  if p_amount_cents<=0 or p_amount_cents>v_invoice.total_cents+v_debited-v_paid-v_credited or p_payment_date<v_invoice.issue_date or length(btrim(p_reference))<3 then raise exception 'payment exceeds the invoice balance or is invalid' using errcode='22023';end if;
  select * into v_policy from public.platform_accounting_policies_v147 where effective_from<=p_payment_date order by effective_from desc,version desc limit 1;v_number:=app.platform_next_document_number_v147('receipt',v_policy.document_prefix);
  v_journal:=app.platform_post_journal_v147('generated_receipt',v_id::text,p_payment_date,'Receipt '||v_number,jsonb_build_array(jsonb_build_object('account_code','1000','debit_cents',p_amount_cents,'credit_cents',0,'counterparty',v_invoice.counterparty->>'legal_name'),jsonb_build_object('account_code','1100','debit_cents',0,'credit_cents',p_amount_cents,'counterparty',v_invoice.counterparty->>'legal_name')),p_idempotency_key,v_hash,v_actor,null);v_journal_id:=(v_journal#>>'{entry,id}')::uuid;
  v_snapshot:=jsonb_build_object('issuer',app.platform_document_issuer_v147(v_policy),'number',v_number,'invoice_number',v_invoice.document_number,'payment_date',p_payment_date,'amount_cents',p_amount_cents,'reference',btrim(p_reference),'counterparty',v_invoice.counterparty,'currency','SGD');
  insert into public.platform_financial_documents_v147(id,document_type,document_number,issue_date,counterparty,line_items,subtotal_cents,tax_cents,total_cents,source_type,source_id,original_document,journal_entry,snapshot,snapshot_sha256,operation_key,request_hash,created_by)
  values(v_id,'receipt',v_number,p_payment_date,v_invoice.counterparty,jsonb_build_array(jsonb_build_object('description','Payment for '||v_invoice.document_number,'reference',btrim(p_reference))),p_amount_cents,0,p_amount_cents,'generated_receipt',v_id::text,p_invoice,v_journal_id,v_snapshot,encode(extensions.digest(v_snapshot::text,'sha256'),'hex'),p_idempotency_key,v_hash,v_actor) returning * into v_doc;
  return jsonb_build_object('document',to_jsonb(v_doc),'snapshot',v_snapshot,'remaining_cents',v_invoice.total_cents+v_debited-v_paid-v_credited-p_amount_cents,'replayed',false);
end
$$;

create or replace function public.platform_issue_credit_note_v147(p_invoice uuid,p_issue_date date,p_subtotal_cents integer,p_tax_cents integer,p_reason text,p_idempotency_key uuid)
returns jsonb language plpgsql security definer set search_path to 'pg_catalog','public','app','pg_temp' as $$
declare v_actor uuid:=auth.uid();v_invoice public.platform_financial_documents_v147%rowtype;v_policy public.platform_accounting_policies_v147%rowtype;v_existing public.platform_financial_documents_v147%rowtype;v_doc public.platform_financial_documents_v147%rowtype;v_id uuid:=gen_random_uuid();v_hash text;v_total bigint:=p_subtotal_cents+p_tax_cents;v_credited bigint;v_credited_subtotal bigint;v_credited_tax bigint;v_paid bigint;v_debited bigint;v_number text;v_journal jsonb;v_journal_id uuid;v_snapshot jsonb;
begin
  if v_actor is null or not app.is_super_admin() then raise exception 'super-admin access is required' using errcode='42501';end if;
  v_hash:=encode(extensions.digest(jsonb_build_object('invoice',p_invoice,'date',p_issue_date,'subtotal',p_subtotal_cents,'tax',p_tax_cents,'reason',btrim(p_reason))::text,'sha256'),'hex');perform pg_advisory_xact_lock(hashtextextended('platform_credit_note:'||p_idempotency_key::text,147));
  select * into v_existing from public.platform_financial_documents_v147 where created_by=v_actor and operation_key=p_idempotency_key;if found then if v_existing.request_hash<>v_hash then raise exception 'idempotency key was reused with different input' using errcode='22023';end if;return jsonb_build_object('document',to_jsonb(v_existing),'replayed',true);end if;
  perform pg_advisory_xact_lock(hashtextextended('platform_document_chain:'||p_invoice::text,147));
  select * into v_invoice from public.platform_financial_documents_v147 where id=p_invoice and document_type='invoice';if not found then raise exception 'invoice was not found' using errcode='22023';end if;
  select coalesce(sum(document.total_cents),0) into v_paid from public.platform_financial_documents_v147 document where document.original_document=p_invoice and document.document_type='receipt' and not exists(select 1 from public.platform_financial_documents_v147 reversal where reversal.original_document=document.id and reversal.document_type='journal_voucher');
  select coalesce(sum(document.total_cents),0),coalesce(sum(document.subtotal_cents),0),coalesce(sum(document.tax_cents),0)
    into v_credited,v_credited_subtotal,v_credited_tax
    from public.platform_financial_documents_v147 document where document.original_document=p_invoice and document.document_type='credit_note' and not exists(select 1 from public.platform_financial_documents_v147 reversal where reversal.original_document=document.id and reversal.document_type='journal_voucher');
  select coalesce(sum(document.total_cents),0) into v_debited from public.platform_financial_documents_v147 document where document.original_document=p_invoice and document.document_type='debit_note' and not exists(select 1 from public.platform_financial_documents_v147 reversal where reversal.original_document=document.id and reversal.document_type='journal_voucher');
  if p_subtotal_cents<=0 or p_tax_cents<0 or v_total>v_invoice.total_cents+v_debited-v_paid-v_credited or p_issue_date<v_invoice.issue_date or length(btrim(p_reason))<8 then raise exception 'credit note amount, date or reason is invalid' using errcode='22023';end if;
  if v_credited_subtotal+p_subtotal_cents>v_invoice.subtotal_cents or v_credited_tax+p_tax_cents>v_invoice.tax_cents
     or (v_invoice.tax_cents=0 and v_credited_tax+p_tax_cents<>0)
     or (v_invoice.tax_cents>0 and v_credited_tax+p_tax_cents<>round((v_credited_subtotal+p_subtotal_cents)*v_invoice.tax_cents::numeric/v_invoice.subtotal_cents)) then raise exception 'cumulative credit note tax must proportionally reverse the original invoice tax' using errcode='22023';end if;
  select * into v_policy from public.platform_accounting_policies_v147 where effective_from<=p_issue_date order by effective_from desc,version desc limit 1;v_number:=app.platform_next_document_number_v147('credit_note',v_policy.document_prefix);
  v_journal:=app.platform_post_journal_v147('generated_credit_note',v_id::text,p_issue_date,'Credit note '||v_number,jsonb_build_array(jsonb_build_object('account_code','4010','debit_cents',p_subtotal_cents,'credit_cents',0,'counterparty',v_invoice.counterparty->>'legal_name'),jsonb_build_object('account_code','1100','debit_cents',0,'credit_cents',v_total,'counterparty',v_invoice.counterparty->>'legal_name'))||case when p_tax_cents>0 then jsonb_build_array(jsonb_build_object('account_code','2200','debit_cents',p_tax_cents,'credit_cents',0,'counterparty',v_invoice.counterparty->>'legal_name')) else '[]'::jsonb end,p_idempotency_key,v_hash,v_actor,null);v_journal_id:=(v_journal#>>'{entry,id}')::uuid;
  v_snapshot:=jsonb_build_object('issuer',app.platform_document_issuer_v147(v_policy),'number',v_number,'invoice_number',v_invoice.document_number,'issue_date',p_issue_date,'reason',btrim(p_reason),'subtotal_cents',p_subtotal_cents,'tax_cents',p_tax_cents,'total_cents',v_total,'counterparty',v_invoice.counterparty,'currency','SGD');
  insert into public.platform_financial_documents_v147(id,document_type,document_number,issue_date,counterparty,line_items,subtotal_cents,tax_cents,total_cents,source_type,source_id,original_document,journal_entry,snapshot,snapshot_sha256,operation_key,request_hash,created_by)
  values(v_id,'credit_note',v_number,p_issue_date,v_invoice.counterparty,jsonb_build_array(jsonb_build_object('description',btrim(p_reason))),p_subtotal_cents,p_tax_cents,v_total,'generated_credit_note',v_id::text,p_invoice,v_journal_id,v_snapshot,encode(extensions.digest(v_snapshot::text,'sha256'),'hex'),p_idempotency_key,v_hash,v_actor) returning * into v_doc;
  return jsonb_build_object('document',to_jsonb(v_doc),'snapshot',v_snapshot,'replayed',false);
end
$$;

create or replace function public.platform_issue_debit_note_v147(p_invoice uuid,p_issue_date date,p_subtotal_cents integer,p_tax_cents integer,p_reason text,p_idempotency_key uuid)
returns jsonb language plpgsql security definer set search_path to 'pg_catalog','public','app','pg_temp' as $$
declare v_actor uuid:=auth.uid();v_invoice public.platform_financial_documents_v147%rowtype;v_policy public.platform_accounting_policies_v147%rowtype;v_existing public.platform_financial_documents_v147%rowtype;v_doc public.platform_financial_documents_v147%rowtype;v_id uuid:=gen_random_uuid();v_hash text;v_total bigint:=p_subtotal_cents+p_tax_cents;v_number text;v_journal jsonb;v_journal_id uuid;v_snapshot jsonb;
begin
  if v_actor is null or not app.is_super_admin() then raise exception 'super-admin access is required' using errcode='42501';end if;
  v_hash:=encode(extensions.digest(jsonb_build_object('invoice',p_invoice,'date',p_issue_date,'subtotal',p_subtotal_cents,'tax',p_tax_cents,'reason',btrim(p_reason))::text,'sha256'),'hex');perform pg_advisory_xact_lock(hashtextextended('platform_debit_note:'||p_idempotency_key::text,147));
  select * into v_existing from public.platform_financial_documents_v147 where created_by=v_actor and operation_key=p_idempotency_key;if found then if v_existing.request_hash<>v_hash then raise exception 'idempotency key was reused with different input' using errcode='22023';end if;return jsonb_build_object('document',to_jsonb(v_existing),'replayed',true);end if;
  perform pg_advisory_xact_lock(hashtextextended('platform_document_chain:'||p_invoice::text,147));
  select * into v_invoice from public.platform_financial_documents_v147 where id=p_invoice and document_type='invoice';if not found then raise exception 'invoice was not found' using errcode='22023';end if;
  if p_subtotal_cents<=0 or p_tax_cents<0 or p_issue_date<v_invoice.issue_date or length(btrim(p_reason))<8 then raise exception 'debit note amount, date or reason is invalid' using errcode='22023';end if;
  if v_invoice.tax_cents<>0 or p_tax_cents<>0 then raise exception 'debit notes are limited to transactions where no GST is charged; issue a tax invoice instead' using errcode='22023';end if;
  select * into v_policy from public.platform_accounting_policies_v147 where effective_from<=p_issue_date order by effective_from desc,version desc limit 1;v_number:=app.platform_next_document_number_v147('debit_note',v_policy.document_prefix);
  v_journal:=app.platform_post_journal_v147('generated_debit_note',v_id::text,p_issue_date,'Debit note '||v_number,jsonb_build_array(jsonb_build_object('account_code','1100','debit_cents',v_total,'credit_cents',0,'counterparty',v_invoice.counterparty->>'legal_name'),jsonb_build_object('account_code','4090','debit_cents',0,'credit_cents',p_subtotal_cents,'counterparty',v_invoice.counterparty->>'legal_name'))||case when p_tax_cents>0 then jsonb_build_array(jsonb_build_object('account_code','2200','debit_cents',0,'credit_cents',p_tax_cents,'counterparty',v_invoice.counterparty->>'legal_name')) else '[]'::jsonb end,p_idempotency_key,v_hash,v_actor,null);v_journal_id:=(v_journal#>>'{entry,id}')::uuid;
  v_snapshot:=jsonb_build_object('issuer',app.platform_document_issuer_v147(v_policy),'number',v_number,'invoice_number',v_invoice.document_number,'issue_date',p_issue_date,'reason',btrim(p_reason),'subtotal_cents',p_subtotal_cents,'tax_cents',p_tax_cents,'total_cents',v_total,'counterparty',v_invoice.counterparty,'currency','SGD');
  insert into public.platform_financial_documents_v147(id,document_type,document_number,issue_date,counterparty,line_items,subtotal_cents,tax_cents,total_cents,source_type,source_id,original_document,journal_entry,snapshot,snapshot_sha256,operation_key,request_hash,created_by)
  values(v_id,'debit_note',v_number,p_issue_date,v_invoice.counterparty,jsonb_build_array(jsonb_build_object('description',btrim(p_reason))),p_subtotal_cents,p_tax_cents,v_total,'generated_debit_note',v_id::text,p_invoice,v_journal_id,v_snapshot,encode(extensions.digest(v_snapshot::text,'sha256'),'hex'),p_idempotency_key,v_hash,v_actor) returning * into v_doc;
  return jsonb_build_object('document',to_jsonb(v_doc),'snapshot',v_snapshot,'replayed',false);
end
$$;

create or replace function public.platform_reverse_financial_document_v147(p_document uuid,p_reversal_date date,p_reason text,p_idempotency_key uuid)
returns jsonb language plpgsql security definer set search_path to 'pg_catalog','public','app','pg_temp' as $$
declare v_actor uuid:=auth.uid();v_original public.platform_financial_documents_v147%rowtype;v_policy public.platform_accounting_policies_v147%rowtype;v_existing public.platform_financial_documents_v147%rowtype;v_doc public.platform_financial_documents_v147%rowtype;v_id uuid:=gen_random_uuid();v_hash text;v_number text;v_journal jsonb;v_journal_id uuid;v_snapshot jsonb;
begin
  if v_actor is null or not app.is_super_admin() then raise exception 'super-admin access is required' using errcode='42501';end if;
  v_hash:=encode(extensions.digest(jsonb_build_object('document',p_document,'date',p_reversal_date,'reason',btrim(p_reason))::text,'sha256'),'hex');perform pg_advisory_xact_lock(hashtextextended('platform_document_reversal:'||p_idempotency_key::text,147));
  select * into v_existing from public.platform_financial_documents_v147 where created_by=v_actor and operation_key=p_idempotency_key;if found then if v_existing.request_hash<>v_hash then raise exception 'idempotency key was reused with different input' using errcode='22023';end if;return jsonb_build_object('document',to_jsonb(v_existing),'replayed',true);end if;
  select * into v_original from public.platform_financial_documents_v147 where id=p_document;if not found then raise exception 'document is missing or already reversed' using errcode='22023';end if;
  perform pg_advisory_xact_lock(hashtextextended('platform_document_chain:'||coalesce(v_original.original_document,v_original.id)::text,147));
  select * into v_original from public.platform_financial_documents_v147 where id=p_document;
  if exists(select 1 from public.platform_financial_documents_v147 where original_document=p_document and document_type='journal_voucher') then raise exception 'document is missing or already reversed' using errcode='22023';end if;
  if v_original.document_type='invoice' and exists(select 1 from public.platform_financial_documents_v147 where original_document=p_document and document_type in ('receipt','credit_note','debit_note')) then raise exception 'invoice with payments, credits or debits must be corrected through linked documents' using errcode='22023';end if;
  if p_reversal_date<v_original.issue_date or length(btrim(p_reason))<8 then raise exception 'valid reversal date and reason are required' using errcode='22023';end if;
  select * into v_policy from public.platform_accounting_policies_v147 where effective_from<=p_reversal_date order by effective_from desc,version desc limit 1;v_number:=app.platform_next_document_number_v147('journal_voucher',v_policy.document_prefix);
  v_journal:=app.platform_reverse_journal_v147(v_original.journal_entry,'generated_document_reversal',v_id::text,p_reversal_date,'Reversal '||v_number||': '||btrim(p_reason),p_idempotency_key,v_actor);v_journal_id:=(v_journal#>>'{entry,id}')::uuid;
  v_snapshot:=jsonb_build_object('issuer',v_original.snapshot->'issuer','number',v_number,'original_number',v_original.document_number,'reversal_date',p_reversal_date,'reason',btrim(p_reason),'total_cents',v_original.total_cents,'currency','SGD');
  insert into public.platform_financial_documents_v147(id,document_type,document_number,issue_date,counterparty,line_items,subtotal_cents,tax_cents,total_cents,source_type,source_id,original_document,journal_entry,snapshot,snapshot_sha256,operation_key,request_hash,created_by)
  values(v_id,'journal_voucher',v_number,p_reversal_date,v_original.counterparty,jsonb_build_array(jsonb_build_object('description',btrim(p_reason))),v_original.subtotal_cents,v_original.tax_cents,v_original.total_cents,'generated_document_reversal',v_id::text,p_document,v_journal_id,v_snapshot,encode(extensions.digest(v_snapshot::text,'sha256'),'hex'),p_idempotency_key,v_hash,v_actor) returning * into v_doc;
  return jsonb_build_object('document',to_jsonb(v_doc),'snapshot',v_snapshot,'replayed',false);
end
$$;

create or replace function app.platform_sync_expense_document_v147(p_expense public.platform_operating_expense_entries_v146)
returns void language plpgsql security definer set search_path to 'pg_catalog','public','app','extensions','pg_temp' as $$
declare v_policy public.platform_accounting_policies_v147%rowtype;v_journal uuid;v_original public.platform_financial_documents_v147%rowtype;v_id uuid:=(md5('platform-expense-document:'||p_expense.id::text))::uuid;v_operation uuid:=(md5('platform-expense-operation:'||p_expense.id::text))::uuid;v_number text;v_snapshot jsonb;v_type text;v_source text;v_original_id uuid;
begin
  perform pg_advisory_xact_lock(hashtextextended('platform-expense-document:'||p_expense.id::text,147));
  if exists(select 1 from public.platform_financial_documents_v147 where source_type in ('platform_expense_voucher','platform_expense_reversal_voucher') and source_id=p_expense.id::text) then return;end if;
  select * into v_policy from public.platform_accounting_policies_v147 where effective_from<=p_expense.expense_date order by effective_from desc,version desc limit 1;
  if v_policy.id is null then return;end if;
  select id into v_journal from public.platform_accounting_journal_entries_v147 where source_type='platform_expense' and source_id=p_expense.id::text;
  if not found or v_journal is null then return;end if;
  if p_expense.entry_type='expense' then
    if p_expense.counterparty_name is null or p_expense.payment_reference is null or p_expense.evidence_reference is null then return;end if;
    v_type:='payment_voucher';v_source:='platform_expense_voucher';v_number:=app.platform_next_document_number_v147(v_type,v_policy.document_prefix);
    v_snapshot:=jsonb_build_object('issuer',app.platform_document_issuer_v147(v_policy),'number',v_number,'expense_date',p_expense.expense_date,'counterparty',jsonb_build_object('legal_name',p_expense.counterparty_name,'registration_number',p_expense.counterparty_registration_number),'description',p_expense.description,'category',p_expense.category,'amount_cents',p_expense.amount_cents,'payment_reference',p_expense.payment_reference,'evidence_reference',p_expense.evidence_reference,'currency','SGD');
  else
    select * into v_original from public.platform_financial_documents_v147 where source_type='platform_expense_voucher' and source_id=p_expense.reversal_of::text;
    if not found then return;end if;
    v_type:='journal_voucher';v_source:='platform_expense_reversal_voucher';v_original_id:=v_original.id;v_number:=app.platform_next_document_number_v147(v_type,v_policy.document_prefix);
    v_snapshot:=jsonb_build_object('issuer',v_original.snapshot->'issuer','number',v_number,'original_number',v_original.document_number,'reversal_date',p_expense.expense_date,'reason',p_expense.description,'amount_cents',p_expense.amount_cents,'currency','SGD');
  end if;
  insert into public.platform_financial_documents_v147(id,document_type,document_number,issue_date,counterparty,line_items,subtotal_cents,tax_cents,total_cents,source_type,source_id,original_document,journal_entry,snapshot,snapshot_sha256,operation_key,request_hash,created_by)
  values(v_id,v_type,v_number,p_expense.expense_date,coalesce(v_original.counterparty,jsonb_build_object('legal_name',p_expense.counterparty_name,'registration_number',p_expense.counterparty_registration_number)),jsonb_build_array(jsonb_build_object('description',p_expense.description,'quantity',1,'unit_amount_cents',p_expense.amount_cents)),p_expense.amount_cents,0,p_expense.amount_cents,v_source,p_expense.id::text,v_original_id,v_journal,v_snapshot,encode(extensions.digest(v_snapshot::text,'sha256'),'hex'),v_operation,p_expense.request_hash,p_expense.recorded_by);
end
$$;
revoke all on function app.platform_sync_expense_document_v147(public.platform_operating_expense_entries_v146) from public,anon,authenticated;
create or replace function app.platform_expense_document_trigger_v147() returns trigger language plpgsql security definer set search_path to 'pg_catalog','public','app','pg_temp' as $$ begin perform app.platform_sync_expense_document_v147(new);return new;end $$;
revoke all on function app.platform_expense_document_trigger_v147() from public,anon,authenticated;
create trigger zz_platform_expense_document_v147 after insert on public.platform_operating_expense_entries_v146 for each row execute function app.platform_expense_document_trigger_v147();

create or replace function public.platform_get_accounting_books_v147(p_from date,p_to date,p_limit integer default 5000)
returns jsonb language plpgsql stable security definer set search_path to 'pg_catalog','public','app','pg_temp' as $$
declare v_count bigint;v_document_count bigint;v_policy jsonb;begin
  if auth.uid() is null or not app.is_super_admin() then raise exception 'super-admin access is required' using errcode='42501';end if;
  if p_from is null or p_to<p_from or p_to-p_from>1826 or p_limit not between 1 and 5000 then raise exception 'valid accounting range and limit are required' using errcode='22023';end if;
  select count(*) into v_count from public.platform_accounting_journal_entries_v147 where journal_date between p_from and p_to;
  select count(*) into v_document_count from public.platform_financial_documents_v147 where issue_date between p_from and p_to;
  select to_jsonb(policy)-'created_by' into v_policy from public.platform_accounting_policies_v147 policy where effective_from<=p_to order by effective_from desc,version desc limit 1;
  return jsonb_build_object('from',p_from,'to',p_to,'currency','SGD','policy',v_policy,
    'row_counts',jsonb_build_object('journals',v_count,'documents',v_document_count),
    'complete',jsonb_build_object('journals',v_count<=p_limit,'documents',v_document_count<=p_limit),
    'summary',(select jsonb_build_object(
      'revenue_cents',coalesce(sum(case when account.account_type='revenue' and entry.journal_date between p_from and p_to then line.credit_cents-line.debit_cents else 0 end),0),
      'expense_cents',coalesce(sum(case when account.account_type='expense' and entry.journal_date between p_from and p_to then line.debit_cents-line.credit_cents else 0 end),0),
      'profit_cents',coalesce(sum(case when account.account_type='revenue' and entry.journal_date between p_from and p_to then line.credit_cents-line.debit_cents when account.account_type='expense' and entry.journal_date between p_from and p_to then line.credit_cents-line.debit_cents else 0 end),0),
      'assets_cents',coalesce(sum(case when account.account_type='asset' then line.debit_cents-line.credit_cents else 0 end),0),
      'liabilities_cents',coalesce(sum(case when account.account_type='liability' then line.credit_cents-line.debit_cents else 0 end),0),
      'equity_and_current_profit_cents',coalesce(sum(case when account.account_type='equity' then line.credit_cents-line.debit_cents when account.account_type='revenue' then line.credit_cents-line.debit_cents when account.account_type='expense' then line.credit_cents-line.debit_cents else 0 end),0))
      from public.platform_accounting_journal_lines_v147 line join public.platform_accounting_journal_entries_v147 entry on entry.id=line.entry_id join public.platform_accounting_accounts_v147 account on account.code=line.account_code where entry.journal_date<=p_to),
    'trial_balance',coalesce((select jsonb_agg(to_jsonb(rows) order by rows.code) from (
      select account.code,account.name,account.account_type,account.normal_balance,
        coalesce(sum(line.debit_cents) filter(where entry.journal_date<p_from),0) opening_debits_cents,
        coalesce(sum(line.credit_cents) filter(where entry.journal_date<p_from),0) opening_credits_cents,
        coalesce(sum(line.debit_cents) filter(where entry.journal_date between p_from and p_to),0) period_debits_cents,
        coalesce(sum(line.credit_cents) filter(where entry.journal_date between p_from and p_to),0) period_credits_cents,
        coalesce(sum(line.debit_cents-line.credit_cents) filter(where entry.journal_date<=p_to),0) closing_debit_net_cents
      from public.platform_accounting_accounts_v147 account left join public.platform_accounting_journal_lines_v147 line on line.account_code=account.code left join public.platform_accounting_journal_entries_v147 entry on entry.id=line.entry_id group by account.code,account.name,account.account_type,account.normal_balance
    ) rows),'[]'::jsonb),
    'journals',coalesce((select jsonb_agg(to_jsonb(rows) order by rows.journal_date desc,rows.journal_number desc) from (
      select entry.id,entry.journal_number,entry.journal_date,entry.description,entry.source_type,entry.source_id,entry.reversal_of,entry.created_at,
        (select jsonb_agg(jsonb_build_object('line_number',line.line_number,'account_code',line.account_code,'account_name',account.name,'debit_cents',line.debit_cents,'credit_cents',line.credit_cents,'memo',line.memo,'counterparty',line.counterparty) order by line.line_number) from public.platform_accounting_journal_lines_v147 line join public.platform_accounting_accounts_v147 account on account.code=line.account_code where line.entry_id=entry.id) lines
      from public.platform_accounting_journal_entries_v147 entry where entry.journal_date between p_from and p_to order by entry.journal_date desc,entry.journal_number desc limit p_limit
    ) rows),'[]'::jsonb),
    'documents',coalesce((select jsonb_agg(to_jsonb(rows) order by rows.issue_date desc,rows.document_number desc) from (
      select document.id,document.document_type,document.document_number,document.issue_date,document.due_date,document.currency,document.counterparty,document.line_items,document.subtotal_cents,document.tax_cents,document.total_cents,document.original_document,document.journal_entry,document.snapshot,document.snapshot_sha256,document.created_at,
        exists(select 1 from public.platform_financial_documents_v147 reversal where reversal.original_document=document.id and reversal.document_type='journal_voucher') reversed,
        case when document.document_type='invoice' then greatest(0,document.total_cents
          +coalesce((select sum(child.total_cents) from public.platform_financial_documents_v147 child where child.original_document=document.id and child.document_type='debit_note' and not exists(select 1 from public.platform_financial_documents_v147 child_reversal where child_reversal.original_document=child.id and child_reversal.document_type='journal_voucher')),0)
          -coalesce((select sum(child.total_cents) from public.platform_financial_documents_v147 child where child.original_document=document.id and child.document_type='receipt' and not exists(select 1 from public.platform_financial_documents_v147 child_reversal where child_reversal.original_document=child.id and child_reversal.document_type='journal_voucher')),0)
          -coalesce((select sum(child.total_cents) from public.platform_financial_documents_v147 child where child.original_document=document.id and child.document_type='credit_note' and not exists(select 1 from public.platform_financial_documents_v147 child_reversal where child_reversal.original_document=child.id and child_reversal.document_type='journal_voucher')),0)) else null end outstanding_cents
      from public.platform_financial_documents_v147 document where document.issue_date between p_from and p_to order by document.issue_date desc,document.document_number desc limit p_limit
    ) rows),'[]'::jsonb),
    'period_locked',exists(select 1 from generate_series(p_from,p_to,'1 day'::interval) day where app.platform_accounting_date_locked_v147(day::date)));
end
$$;

revoke all on function public.platform_set_accounting_policy_v147(date,text,text,text,text,text,integer,integer,integer,text,text,uuid) from public,anon,authenticated;
revoke all on function public.platform_record_operating_expense_v147(date,text,text,integer,text,text,text,text,uuid) from public,anon,authenticated;
revoke all on function public.platform_set_accounting_period_lock_v147(date,date,boolean,text,uuid) from public,anon,authenticated;
revoke all on function public.platform_create_invoice_v147(date,date,text,jsonb,jsonb,integer,uuid) from public,anon,authenticated;
revoke all on function public.platform_record_invoice_receipt_v147(uuid,date,integer,text,uuid) from public,anon,authenticated;
revoke all on function public.platform_issue_credit_note_v147(uuid,date,integer,integer,text,uuid) from public,anon,authenticated;
revoke all on function public.platform_issue_debit_note_v147(uuid,date,integer,integer,text,uuid) from public,anon,authenticated;
revoke all on function public.platform_reverse_financial_document_v147(uuid,date,text,uuid) from public,anon,authenticated;
revoke all on function public.platform_get_accounting_books_v147(date,date,integer) from public,anon,authenticated;
grant execute on function public.platform_set_accounting_policy_v147(date,text,text,text,text,text,integer,integer,integer,text,text,uuid) to authenticated;
grant execute on function public.platform_record_operating_expense_v147(date,text,text,integer,text,text,text,text,uuid) to authenticated;
grant execute on function public.platform_set_accounting_period_lock_v147(date,date,boolean,text,uuid) to authenticated;
grant execute on function public.platform_create_invoice_v147(date,date,text,jsonb,jsonb,integer,uuid) to authenticated;
grant execute on function public.platform_record_invoice_receipt_v147(uuid,date,integer,text,uuid) to authenticated;
grant execute on function public.platform_issue_credit_note_v147(uuid,date,integer,integer,text,uuid) to authenticated;
grant execute on function public.platform_issue_debit_note_v147(uuid,date,integer,integer,text,uuid) to authenticated;
grant execute on function public.platform_reverse_financial_document_v147(uuid,date,text,uuid) to authenticated;
grant execute on function public.platform_get_accounting_books_v147(date,date,integer) to authenticated;

commit;
