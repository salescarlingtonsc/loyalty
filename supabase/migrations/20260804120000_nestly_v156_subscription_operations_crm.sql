-- Peekaa V156: internal subscription operations, billing documents and CRM.
-- Additive only. Stripe V77 remains paid truth; V147 remains accounting truth.
begin;

create extension if not exists pg_net with schema extensions;

create table public.platform_billing_profiles_v156 (
  id uuid primary key default gen_random_uuid(),
  version integer not null unique check(version>0),
  effective_from timestamptz not null default clock_timestamp(),
  brand_name text not null check(length(btrim(brand_name)) between 2 and 80),
  legal_name text not null check(length(btrim(legal_name)) between 2 and 200),
  uen text,
  registered_address text,
  billing_email text,
  currency text not null default 'SGD' check(currency='SGD'),
  gst_status text not null check(gst_status in ('unconfigured','not_registered','registered')),
  gst_registration_number text,
  gst_rate_bps integer not null default 0 check(gst_rate_bps between 0 and 2000),
  default_payment_terms text,
  logo_object_path text,
  authorised_signature_object_path text,
  bank_account_name text not null,
  bank_name text not null,
  bank_code text not null,
  branch_code text not null,
  swift_code text not null,
  bank_account_number text not null,
  bank_account_location text not null,
  billing_contact_name text not null,
  billing_contact_mobile text not null,
  internal_copy_email text,
  customer_reminders_enabled boolean not null default false,
  annual_reminder_days integer[] not null default array[30,14,7],
  created_by uuid references auth.users(id) on delete restrict,
  created_at timestamptz not null default clock_timestamp(),
  operation_key uuid unique,
  request_hash text check(request_hash is null or request_hash ~ '^[0-9a-f]{64}$'),
  check(uen is null or length(btrim(uen)) between 4 and 40),
  check(registered_address is null or length(btrim(registered_address)) between 5 and 500),
  check(billing_email is null or billing_email ~* '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$'),
  check(internal_copy_email is null or internal_copy_email ~* '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$'),
  check((gst_status='registered' and length(btrim(gst_registration_number))>=4 and gst_rate_bps>0)
    or (gst_status<>'registered' and gst_registration_number is null and gst_rate_bps=0)),
  check((operation_key is null)=(request_hash is null)),
  check(cardinality(annual_reminder_days)<=3 and annual_reminder_days<@array[30,14,7])
);

insert into public.platform_billing_profiles_v156(
  version,brand_name,legal_name,uen,currency,gst_status,
  bank_account_name,bank_name,bank_code,branch_code,swift_code,
  bank_account_number,bank_account_location,billing_contact_name,billing_contact_mobile
) values(
  1,'Peekaa','NESTLY TECHNOLOGIES PTE. LTD.','202634502E','SGD','unconfigured',
  'NESTLY TECHNOLOGIES PTE. LTD.','Standard Chartered Bank (Singapore) Limited',
  '9496','001','SCBLSG22','7897246357','Singapore','Lee Chuan Seng','+65 8186 3833'
);

create table public.platform_billing_contacts_v156 (
  id uuid primary key default gen_random_uuid(),
  business_id uuid references public.businesses(id) on delete cascade,
  prospect_id uuid references public.sme_prospects(id) on delete cascade,
  business_display_name text not null,
  legal_entity_name text not null,
  registration_number text,
  billing_address jsonb not null check(jsonb_typeof(billing_address)='object'),
  country text not null default 'Singapore',
  contact_name text not null,
  email text not null check(email ~* '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$'),
  telephone text,
  recipient_role text not null check(recipient_role in ('primary','cc','accounts_payable')),
  purchase_order_number text,
  customer_reference text,
  active boolean not null default true,
  created_by uuid not null references auth.users(id) on delete restrict,
  updated_by uuid not null references auth.users(id) on delete restrict,
  created_at timestamptz not null default clock_timestamp(),
  updated_at timestamptz not null default clock_timestamp(),
  check((business_id is null)<>(prospect_id is null)),
  check(length(btrim(business_display_name)) between 2 and 200),
  check(length(btrim(legal_entity_name)) between 2 and 200),
  check(length(btrim(contact_name)) between 2 and 160)
);
create unique index platform_billing_contacts_primary_business_v156_uk
  on public.platform_billing_contacts_v156(business_id) where active and recipient_role='primary';
create unique index platform_billing_contacts_primary_prospect_v156_uk
  on public.platform_billing_contacts_v156(prospect_id) where active and recipient_role='primary';
create unique index platform_billing_contacts_email_scope_v156_uk
  on public.platform_billing_contacts_v156(coalesce(business_id,prospect_id),lower(email)) where active;

create table public.platform_crm_commercial_v156 (
  prospect_id uuid primary key references public.sme_prospects(id) on delete cascade,
  lead_source text,
  expected_plan text,
  billing_interval text check(billing_interval is null or billing_interval in ('monthly','quarterly','half_yearly','annual','fixed')),
  currency text not null default 'SGD' check(currency='SGD'),
  expected_value_cents bigint check(expected_value_cents is null or expected_value_cents>=0),
  proposed_discount_cents bigint not null default 0 check(proposed_discount_cents>=0),
  expected_close_date date,
  intended_duration text,
  purchase_order_number text,
  customer_reference text,
  checkout_session_id text,
  checkout_url text check(checkout_url is null or checkout_url ~ '^https://checkout\.stripe\.com/'),
  checkout_created_at timestamptz,
  quotation_status text not null default 'none' check(quotation_status in ('none','draft','sent','accepted','rejected','expired','superseded')),
  payment_link_status text not null default 'none' check(payment_link_status in ('none','created','sent','expired','completed')),
  updated_by uuid not null references auth.users(id) on delete restrict,
  updated_at timestamptz not null default clock_timestamp()
);

create table public.platform_subscription_document_sequences_v156 (
  document_type text not null check(document_type in ('quotation','invoice','receipt','subscription_summary')),
  document_year integer not null check(document_year between 2020 and 2200),
  next_value bigint not null default 1 check(next_value>0),
  primary key(document_type,document_year)
);

create table public.platform_subscription_documents_v156 (
  id uuid primary key default gen_random_uuid(),
  document_type text not null check(document_type in ('quotation','invoice','receipt','subscription_summary')),
  document_number text unique,
  business_id uuid references public.businesses(id) on delete restrict,
  prospect_id uuid references public.sme_prospects(id) on delete restrict,
  seller_profile_id uuid not null references public.platform_billing_profiles_v156(id) on delete restrict,
  provider_invoice_id text references public.billing_provider_invoices(provider_invoice_id) on delete restrict,
  provider_subscription_id text,
  accounting_document_id uuid references public.platform_financial_documents_v147(id) on delete restrict,
  original_document_id uuid references public.platform_subscription_documents_v156(id) on delete restrict,
  issue_date date,
  expiry_date date,
  due_date date,
  service_period_start date,
  service_period_end date,
  currency text not null default 'SGD' check(currency='SGD'),
  subtotal_cents bigint not null default 0 check(subtotal_cents>=0),
  discount_cents bigint not null default 0 check(discount_cents>=0),
  tax_cents bigint not null default 0 check(tax_cents>=0),
  total_cents bigint not null default 0 check(total_cents>=0),
  amount_paid_cents bigint not null default 0 check(amount_paid_cents>=0),
  balance_due_cents bigint not null default 0 check(balance_due_cents>=0),
  snapshot jsonb not null default '{}'::jsonb check(jsonb_typeof(snapshot)='object'),
  snapshot_sha256 text check(snapshot_sha256 is null or snapshot_sha256 ~ '^[0-9a-f]{64}$'),
  template_version text not null default 'v156-a4-1',
  finalized_at timestamptz,
  operation_key uuid not null,
  request_hash text not null check(request_hash ~ '^[0-9a-f]{64}$'),
  source_event_id text,
  created_by uuid references auth.users(id) on delete restrict,
  created_at timestamptz not null default clock_timestamp(),
  unique(operation_key),
  check((business_id is not null) or (prospect_id is not null)),
  check((finalized_at is null and document_number is null and snapshot_sha256 is null)
    or (finalized_at is not null and document_number is not null and issue_date is not null and snapshot_sha256 is not null)),
  check(total_cents=subtotal_cents-discount_cents+tax_cents),
  check(amount_paid_cents+balance_due_cents=total_cents)
);
create unique index platform_subscription_docs_provider_invoice_v156_uk
  on public.platform_subscription_documents_v156(provider_invoice_id)
  where provider_invoice_id is not null and document_type='invoice';
create unique index platform_subscription_docs_provider_receipt_v156_uk
  on public.platform_subscription_documents_v156(provider_invoice_id)
  where provider_invoice_id is not null and document_type='receipt';
create unique index platform_subscription_docs_provider_summary_v156_uk
  on public.platform_subscription_documents_v156(provider_invoice_id)
  where provider_invoice_id is not null and document_type='subscription_summary';
create index platform_subscription_docs_business_v156_idx
  on public.platform_subscription_documents_v156(business_id,created_at desc);

create table public.platform_subscription_document_events_v156 (
  id uuid primary key default gen_random_uuid(),
  document_id uuid not null references public.platform_subscription_documents_v156(id) on delete restrict,
  status text not null check(status in ('draft','finalized','sent','viewed','accepted','rejected','expired','superseded','open','paid','past_due','void','uncollectible','refunded','partially_refunded','issued','delivery_failed','reissued_copy')),
  reason text,
  source_type text not null check(source_type in ('admin','stripe_event','delivery','system')),
  source_id text not null,
  actor uuid references auth.users(id) on delete restrict,
  occurred_at timestamptz not null default clock_timestamp(),
  unique(document_id,source_type,source_id,status)
);
create index platform_subscription_document_events_v156_idx
  on public.platform_subscription_document_events_v156(document_id,occurred_at desc);

create table public.platform_subscription_document_files_v156 (
  id uuid primary key default gen_random_uuid(),
  document_id uuid not null references public.platform_subscription_documents_v156(id) on delete restrict,
  revision integer not null check(revision>0),
  bucket_id text not null default 'sme-private' check(bucket_id='sme-private'),
  object_path text not null unique check(object_path ~ '^platform-subscriptions/(businesses|prospects)/[0-9a-f-]{36}/[0-9a-f-]{36}/r[0-9]+\.pdf$'),
  mime_type text not null default 'application/pdf' check(mime_type='application/pdf'),
  size_bytes bigint not null check(size_bytes between 1 and 10485760),
  sha256 text not null check(sha256 ~ '^[0-9a-f]{64}$'),
  template_version text not null,
  generated_at timestamptz not null default clock_timestamp(),
  unique(document_id,revision)
);

create table public.platform_subscription_deliveries_v156 (
  id uuid primary key default gen_random_uuid(),
  delivery_key text not null unique,
  business_id uuid references public.businesses(id) on delete restrict,
  prospect_id uuid references public.sme_prospects(id) on delete restrict,
  provider_invoice_id text,
  delivery_type text not null check(delivery_type in ('quotation','first_payment_pack','renewal_payment_pack','manual_invoice','manual_receipt','document_resend')),
  document_ids uuid[] not null,
  recipients text[] not null,
  cc_recipients text[] not null default '{}',
  subject text not null,
  status text not null default 'queued' check(status in ('queued','processing','provider_accepted','delivered','retryable_failed','permanent_failed','provider_unconfigured')),
  attempt_count integer not null default 0 check(attempt_count>=0),
  next_attempt_at timestamptz not null default clock_timestamp(),
  provider_message_id text,
  failure_code text,
  failure_reason text,
  last_attempt_at timestamptz,
  delivered_at timestamptz,
  manual_resend_by uuid references auth.users(id) on delete restrict,
  created_at timestamptz not null default clock_timestamp(),
  updated_at timestamptz not null default clock_timestamp(),
  check((business_id is not null or prospect_id is not null) and cardinality(document_ids)>0 and cardinality(recipients)>0)
);
create index platform_subscription_deliveries_due_v156_idx
  on public.platform_subscription_deliveries_v156(status,next_attempt_at)
  where status in ('queued','retryable_failed');

create table public.platform_subscription_lifecycle_events_v156 (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete restrict,
  provider_subscription_id text,
  lifecycle_status text not null check(lifecycle_status in ('payment_received','onboarding','active','renewal_approaching','payment_action_required','past_due','cancel_at_period_end','cancelled','churned','payment_incomplete','trial','paused')),
  snapshot jsonb not null check(jsonb_typeof(snapshot)='object'),
  source_type text not null check(source_type in ('stripe_event','manual_payment','system')),
  source_id text not null,
  occurred_at timestamptz not null default clock_timestamp(),
  unique(source_type,source_id,lifecycle_status)
);
create index platform_subscription_lifecycle_business_v156_idx
  on public.platform_subscription_lifecycle_events_v156(business_id,occurred_at desc);

create table public.platform_subscription_tasks_v156 (
  id uuid primary key default gen_random_uuid(),
  task_key text not null unique,
  task_type text not null check(task_type in ('renewal_30','renewal_14','renewal_7','payment_failed','payment_action_required','past_due','cancel_at_period_end','billing_contact_missing','billing_profile_missing','invoice_delivery_failed','onboarding')),
  business_id uuid references public.businesses(id) on delete restrict,
  prospect_id uuid references public.sme_prospects(id) on delete restrict,
  provider_subscription_id text,
  provider_invoice_id text,
  assigned_consultant_id uuid references public.platform_consultants(id) on delete restrict,
  priority text not null check(priority in ('low','normal','high','urgent')),
  due_at timestamptz not null,
  status text not null default 'open' check(status in ('open','completed','cancelled')),
  title text not null,
  resolution text,
  completed_at timestamptz,
  source_event_id text,
  created_at timestamptz not null default clock_timestamp(),
  updated_at timestamptz not null default clock_timestamp(),
  check(business_id is not null or prospect_id is not null),
  check((status='completed' and completed_at is not null) or (status<>'completed' and completed_at is null))
);
create index platform_subscription_tasks_due_v156_idx
  on public.platform_subscription_tasks_v156(status,due_at,priority);

create table public.platform_manual_payments_v156 (
  id uuid primary key default gen_random_uuid(),
  invoice_document_id uuid not null references public.platform_subscription_documents_v156(id) on delete restrict,
  amount_cents bigint not null check(amount_cents>0),
  currency text not null default 'SGD' check(currency='SGD'),
  payment_reference text not null,
  value_date date not null,
  bank_account_last4 text not null check(bank_account_last4 ~ '^[0-9]{4}$'),
  evidence_object_path text not null check(evidence_object_path ~ '^platform-subscriptions/manual-evidence/'),
  status text not null default 'pending_verification' check(status in ('pending_verification','verified','rejected')),
  recorded_by uuid not null references auth.users(id) on delete restrict,
  verified_by uuid references auth.users(id) on delete restrict,
  verified_at timestamptz,
  rejection_reason text,
  request_hash text not null check(request_hash ~ '^[0-9a-f]{64}$'),
  idempotency_key uuid not null unique,
  created_at timestamptz not null default clock_timestamp(),
  unique(invoice_document_id,payment_reference),
  check((status='verified' and verified_by is not null and verified_at is not null and verified_by<>recorded_by)
    or (status='rejected' and verified_by is not null and verified_at is not null and length(btrim(rejection_reason))>=3)
    or status='pending_verification')
);

create table public.platform_subscription_dispatch_audit_v156 (
  id uuid primary key default gen_random_uuid(),
  action text not null,
  entity_type text not null,
  entity_id uuid,
  detail jsonb not null default '{}'::jsonb,
  actor uuid references auth.users(id) on delete restrict,
  occurred_at timestamptz not null default clock_timestamp()
);

create table public.platform_v156_operation_receipts (
  operation_key uuid primary key,
  operation_type text not null,
  actor uuid not null references auth.users(id) on delete restrict,
  request_hash text not null check(request_hash ~ '^[0-9a-f]{64}$'),
  response jsonb not null check(jsonb_typeof(response)='object'),
  created_at timestamptz not null default clock_timestamp()
);

create table public.platform_billing_event_preparations_v156 (
  event_pk uuid primary key references public.billing_provider_events(id) on delete restrict,
  event_id text not null unique,
  status text not null check(status in ('prepared','blocked','ignored','failed')),
  reason text,
  attempt_count integer not null default 1 check(attempt_count>0),
  last_result jsonb not null default '{}'::jsonb check(jsonb_typeof(last_result)='object'),
  last_attempt_at timestamptz not null default clock_timestamp(),
  prepared_at timestamptz
);
create index platform_billing_event_preparations_retry_v156 on public.platform_billing_event_preparations_v156(status,last_attempt_at) where status in ('blocked','failed');

alter table public.platform_billing_profiles_v156 enable row level security;
alter table public.platform_billing_contacts_v156 enable row level security;
alter table public.platform_crm_commercial_v156 enable row level security;
alter table public.platform_subscription_document_sequences_v156 enable row level security;
alter table public.platform_subscription_documents_v156 enable row level security;
alter table public.platform_subscription_document_events_v156 enable row level security;
alter table public.platform_subscription_document_files_v156 enable row level security;
alter table public.platform_subscription_deliveries_v156 enable row level security;
alter table public.platform_subscription_lifecycle_events_v156 enable row level security;
alter table public.platform_subscription_tasks_v156 enable row level security;
alter table public.platform_manual_payments_v156 enable row level security;
alter table public.platform_subscription_dispatch_audit_v156 enable row level security;
alter table public.platform_v156_operation_receipts enable row level security;
alter table public.platform_billing_event_preparations_v156 enable row level security;

revoke all on table public.platform_billing_profiles_v156,public.platform_billing_contacts_v156,
  public.platform_crm_commercial_v156,public.platform_subscription_document_sequences_v156,
  public.platform_subscription_documents_v156,public.platform_subscription_document_events_v156,
  public.platform_subscription_document_files_v156,public.platform_subscription_deliveries_v156,
  public.platform_subscription_lifecycle_events_v156,public.platform_subscription_tasks_v156,
  public.platform_manual_payments_v156,public.platform_subscription_dispatch_audit_v156,
  public.platform_v156_operation_receipts,public.platform_billing_event_preparations_v156
from public,anon,authenticated;

create or replace function app.v156_immutable_guard()
returns trigger language plpgsql set search_path to 'pg_catalog','public','app','pg_temp' as $$
begin raise exception 'V156 audit evidence is immutable' using errcode='55000';end $$;
revoke all on function app.v156_immutable_guard() from public,anon,authenticated;
create trigger platform_billing_profiles_v156_immutable before update or delete on public.platform_billing_profiles_v156 for each row execute function app.v156_immutable_guard();
create trigger platform_subscription_document_events_v156_immutable before update or delete on public.platform_subscription_document_events_v156 for each row execute function app.v156_immutable_guard();
create trigger platform_subscription_document_files_v156_immutable before update or delete on public.platform_subscription_document_files_v156 for each row execute function app.v156_immutable_guard();
create trigger platform_subscription_lifecycle_events_v156_immutable before update or delete on public.platform_subscription_lifecycle_events_v156 for each row execute function app.v156_immutable_guard();
create trigger platform_subscription_dispatch_audit_v156_immutable before update or delete on public.platform_subscription_dispatch_audit_v156 for each row execute function app.v156_immutable_guard();
create trigger platform_v156_operation_receipts_immutable before update or delete on public.platform_v156_operation_receipts for each row execute function app.v156_immutable_guard();

create or replace function app.v156_document_guard()
returns trigger language plpgsql set search_path to 'pg_catalog','public','app','pg_temp' as $$
begin
  if tg_op='DELETE' or old.finalized_at is not null then raise exception 'finalized subscription documents are immutable; void or reissue instead' using errcode='55000';end if;
  if new.id<>old.id or new.document_type<>old.document_type or new.business_id is distinct from old.business_id
    or new.prospect_id is distinct from old.prospect_id or new.operation_key<>old.operation_key
    or new.created_by is distinct from old.created_by then raise exception 'document identity is immutable' using errcode='55000';end if;
  return new;
end $$;
revoke all on function app.v156_document_guard() from public,anon,authenticated;
create trigger platform_subscription_documents_v156_guard before update or delete on public.platform_subscription_documents_v156 for each row execute function app.v156_document_guard();

create or replace function app.v156_can(p_mode text default 'r')
returns boolean language sql stable security definer set search_path to 'pg_catalog','public','app','pg_temp' as $$
  select coalesce(app.is_super_admin() or app.v89_platform_can('billing',p_mode),false)
$$;
revoke all on function app.v156_can(text) from public,anon,authenticated;

create or replace function app.v156_can_prospect(p_prospect uuid,p_mode text default 'r')
returns boolean language sql stable security definer set search_path to 'pg_catalog','public','app','pg_temp' as $$
  select coalesce(app.is_super_admin()
    or app.v89_platform_can('onboarding',p_mode)
    or (app.v89_platform_role()='sales_staff' and exists(
      select 1 from public.sme_prospects prospect
      join public.platform_consultants consultant on consultant.id=prospect.assigned_consultant_id
      where prospect.id=p_prospect and consultant.user_id=auth.uid() and consultant.active)),false)
$$;
revoke all on function app.v156_can_prospect(uuid,text) from public,anon,authenticated;

create or replace function app.v156_profile_ready(p_profile public.platform_billing_profiles_v156)
returns boolean language sql immutable set search_path to 'pg_catalog','public','app','pg_temp' as $$
  select p_profile.uen is not null and p_profile.registered_address is not null
    and p_profile.billing_email is not null and p_profile.default_payment_terms is not null
    and p_profile.gst_status in ('not_registered','registered')
$$;

create or replace function app.v156_seller_snapshot(p_profile public.platform_billing_profiles_v156)
returns jsonb language sql immutable set search_path to 'pg_catalog','public','app','pg_temp' as $$
  select jsonb_build_object('brand_name',p_profile.brand_name,'legal_name',p_profile.legal_name,
    'display_name',p_profile.brand_name||' by '||p_profile.legal_name,'uen',p_profile.uen,
    'registered_address',p_profile.registered_address,'billing_email',p_profile.billing_email,
    'currency',p_profile.currency,'gst_status',p_profile.gst_status,
    'gst_registration_number',case when p_profile.gst_status='registered' then p_profile.gst_registration_number end,
    'gst_rate_bps',case when p_profile.gst_status='registered' then p_profile.gst_rate_bps else 0 end,
    'payment_terms',p_profile.default_payment_terms,'logo_object_path',p_profile.logo_object_path,
    'bank',jsonb_build_object('currency','SGD','account_name',p_profile.bank_account_name,
      'bank_name',p_profile.bank_name,'bank_code',p_profile.bank_code,'branch_code',p_profile.branch_code,
      'swift_code',p_profile.swift_code,'account_number',p_profile.bank_account_number,
      'account_location',p_profile.bank_account_location),
    'contact',jsonb_build_object('name',p_profile.billing_contact_name,'mobile',p_profile.billing_contact_mobile))
$$;
revoke all on function app.v156_profile_ready(public.platform_billing_profiles_v156) from public,anon,authenticated;
revoke all on function app.v156_seller_snapshot(public.platform_billing_profiles_v156) from public,anon,authenticated;

create or replace function app.v156_next_document_number(p_type text,p_date date)
returns text language plpgsql security definer set search_path to 'pg_catalog','public','app','pg_temp' as $$
declare v_year integer:=extract(year from p_date);v_value bigint;v_prefix text;
begin
  if p_type not in ('quotation','invoice','receipt','subscription_summary') then raise exception 'unsupported document type' using errcode='22023';end if;
  insert into public.platform_subscription_document_sequences_v156(document_type,document_year,next_value)
  values(p_type,v_year,2) on conflict(document_type,document_year) do update
    set next_value=platform_subscription_document_sequences_v156.next_value+1
  returning next_value-1 into v_value;
  v_prefix:=case p_type when 'quotation' then 'QTN' when 'invoice' then 'INV' when 'receipt' then 'REC' else 'SUB' end;
  return v_prefix||'-'||v_year||'-'||lpad(v_value::text,6,'0');
end $$;
revoke all on function app.v156_next_document_number(text,date) from public,anon,authenticated;

create or replace function app.v156_customer_snapshot(p_business uuid,p_prospect uuid)
returns jsonb language sql stable security definer set search_path to 'pg_catalog','public','app','pg_temp' as $$
  select coalesce((select jsonb_build_object('business_display_name',c.business_display_name,
    'legal_entity_name',c.legal_entity_name,'registration_number',c.registration_number,
    'billing_address',c.billing_address,'country',c.country,'contact_name',c.contact_name,
    'primary_email',c.email,'telephone',c.telephone,'purchase_order_number',c.purchase_order_number,
    'customer_reference',c.customer_reference,'recipients',(select jsonb_agg(jsonb_build_object(
      'name',r.contact_name,'email',r.email,'role',r.recipient_role) order by r.recipient_role,r.email)
      from public.platform_billing_contacts_v156 r where r.active and (r.business_id=p_business or r.prospect_id=p_prospect)))
    from public.platform_billing_contacts_v156 c where c.active and c.recipient_role='primary'
      and (c.business_id=p_business or c.prospect_id=p_prospect) limit 1),null)
$$;
revoke all on function app.v156_customer_snapshot(uuid,uuid) from public,anon,authenticated;

create or replace function app.v156_upsert_task(p_key text,p_type text,p_business uuid,p_prospect uuid,
  p_subscription text,p_invoice text,p_priority text,p_due timestamptz,p_title text,p_event text)
returns uuid language plpgsql security definer set search_path to 'pg_catalog','public','app','pg_temp' as $$
declare v_id uuid;v_owner uuid;
begin
  select assigned_consultant_id into v_owner from public.sme_prospects where id=p_prospect;
  insert into public.platform_subscription_tasks_v156(task_key,task_type,business_id,prospect_id,
    provider_subscription_id,provider_invoice_id,assigned_consultant_id,priority,due_at,title,source_event_id)
  values(p_key,p_type,p_business,p_prospect,p_subscription,p_invoice,v_owner,p_priority,p_due,p_title,p_event)
  on conflict(task_key) do update set due_at=excluded.due_at,priority=excluded.priority,
    title=excluded.title,updated_at=clock_timestamp()
  where platform_subscription_tasks_v156.status='open' returning id into v_id;
  return coalesce(v_id,(select id from public.platform_subscription_tasks_v156 where task_key=p_key));
end $$;
revoke all on function app.v156_upsert_task(text,text,uuid,uuid,text,text,text,timestamptz,text,text) from public,anon,authenticated;

create or replace function public.platform_set_billing_profile_v156(p_profile jsonb,p_idempotency_key uuid)
returns jsonb language plpgsql security definer set search_path to 'pg_catalog','public','app','extensions','pg_temp' as $$
declare v_actor uuid:=auth.uid();v_current public.platform_billing_profiles_v156%rowtype;v_new public.platform_billing_profiles_v156%rowtype;v_hash text;
begin
  if v_actor is null or not app.is_super_admin() then raise exception 'super admin access is required' using errcode='42501';end if;
  if jsonb_typeof(p_profile)<>'object' or p_idempotency_key is null then raise exception 'valid billing profile is required' using errcode='22023';end if;
  select * into v_current from public.platform_billing_profiles_v156 order by version desc limit 1;
  v_hash:=encode(extensions.digest(jsonb_build_object('profile',p_profile)::text,'sha256'),'hex');
  perform pg_advisory_xact_lock(hashtextextended('v156-profile:'||p_idempotency_key::text,156));
  perform pg_advisory_xact_lock(hashtextextended('v156-profile-version',156));
  select * into v_new from public.platform_billing_profiles_v156 where operation_key=p_idempotency_key;
  if found then
    if v_new.request_hash<>v_hash then raise exception 'idempotency key conflict' using errcode='22023';end if;
    return jsonb_build_object('profile',to_jsonb(v_new)-'bank_account_number','bank_account_last4',right(v_new.bank_account_number,4),'ready',app.v156_profile_ready(v_new),'replayed',true);
  end if;
  insert into public.platform_billing_profiles_v156(version,brand_name,legal_name,uen,registered_address,
    billing_email,currency,gst_status,gst_registration_number,gst_rate_bps,default_payment_terms,
    logo_object_path,authorised_signature_object_path,bank_account_name,bank_name,bank_code,branch_code,
    swift_code,bank_account_number,bank_account_location,billing_contact_name,billing_contact_mobile,
    internal_copy_email,customer_reminders_enabled,annual_reminder_days,created_by,operation_key,request_hash)
  values(v_current.version+1,coalesce(nullif(btrim(p_profile->>'brand_name'),''),v_current.brand_name),
    coalesce(nullif(btrim(p_profile->>'legal_name'),''),v_current.legal_name),case when p_profile?'uen' then nullif(btrim(p_profile->>'uen'),'') else v_current.uen end,
    case when p_profile?'registered_address' then nullif(btrim(p_profile->>'registered_address'),'') else v_current.registered_address end,
    case when p_profile?'billing_email' then lower(nullif(btrim(p_profile->>'billing_email'),'')) else v_current.billing_email end,
    'SGD',coalesce(nullif(p_profile->>'gst_status',''),v_current.gst_status),case when p_profile?'gst_registration_number' then nullif(btrim(p_profile->>'gst_registration_number'),'') else v_current.gst_registration_number end,
    coalesce((p_profile->>'gst_rate_bps')::integer,v_current.gst_rate_bps),case when p_profile?'default_payment_terms' then nullif(btrim(p_profile->>'default_payment_terms'),'') else v_current.default_payment_terms end,
    nullif(btrim(p_profile->>'logo_object_path'),''),nullif(btrim(p_profile->>'authorised_signature_object_path'),''),
    coalesce(nullif(btrim(p_profile->>'bank_account_name'),''),v_current.bank_account_name),
    coalesce(nullif(btrim(p_profile->>'bank_name'),''),v_current.bank_name),
    coalesce(nullif(btrim(p_profile->>'bank_code'),''),v_current.bank_code),
    coalesce(nullif(btrim(p_profile->>'branch_code'),''),v_current.branch_code),
    coalesce(nullif(btrim(p_profile->>'swift_code'),''),v_current.swift_code),
    coalesce(nullif(btrim(p_profile->>'bank_account_number'),''),v_current.bank_account_number),
    coalesce(nullif(btrim(p_profile->>'bank_account_location'),''),v_current.bank_account_location),
    coalesce(nullif(btrim(p_profile->>'billing_contact_name'),''),v_current.billing_contact_name),
    coalesce(nullif(btrim(p_profile->>'billing_contact_mobile'),''),v_current.billing_contact_mobile),
    case when p_profile?'internal_copy_email' then lower(nullif(btrim(p_profile->>'internal_copy_email'),'')) else v_current.internal_copy_email end,
    coalesce((p_profile->>'customer_reminders_enabled')::boolean,v_current.customer_reminders_enabled),
    case when jsonb_typeof(p_profile->'annual_reminder_days')='array' then array(select jsonb_array_elements_text(p_profile->'annual_reminder_days')::integer) else v_current.annual_reminder_days end,
    v_actor,p_idempotency_key,v_hash)
  returning * into v_new;
  insert into public.platform_subscription_dispatch_audit_v156(action,entity_type,entity_id,detail,actor)
  values('billing_profile_versioned','billing_profile',v_new.id,jsonb_build_object('version',v_new.version,'request_hash',v_hash),v_actor);
  return jsonb_build_object('profile',to_jsonb(v_new)-'bank_account_number','bank_account_last4',right(v_new.bank_account_number,4),'ready',app.v156_profile_ready(v_new),'replayed',false);
end $$;

create or replace function app.v156_operation_replay(p_key uuid,p_type text,p_actor uuid,p_hash text)
returns jsonb language plpgsql stable security definer set search_path to 'pg_catalog','public','app','pg_temp' as $$
declare v_receipt public.platform_v156_operation_receipts%rowtype;
begin
  select * into v_receipt from public.platform_v156_operation_receipts where operation_key=p_key;
  if not found then return null;end if;
  if v_receipt.operation_type<>p_type or v_receipt.actor<>p_actor or v_receipt.request_hash<>p_hash then
    raise exception 'idempotency key conflict' using errcode='22023';
  end if;
  return v_receipt.response||jsonb_build_object('replayed',true);
end $$;
revoke all on function app.v156_operation_replay(uuid,text,uuid,text) from public,anon,authenticated;

create or replace function app.v156_store_operation(p_key uuid,p_type text,p_actor uuid,p_hash text,p_response jsonb)
returns jsonb language plpgsql security definer set search_path to 'pg_catalog','public','app','pg_temp' as $$
begin
  insert into public.platform_v156_operation_receipts(operation_key,operation_type,actor,request_hash,response)
  values(p_key,p_type,p_actor,p_hash,p_response);
  return p_response||jsonb_build_object('replayed',false);
end $$;
revoke all on function app.v156_store_operation(uuid,text,uuid,text,jsonb) from public,anon,authenticated;

create or replace function public.platform_upsert_billing_contact_v156(p_contact jsonb,p_idempotency_key uuid)
returns jsonb language plpgsql security definer set search_path to 'pg_catalog','public','app','extensions','pg_temp' as $$
declare v_actor uuid:=auth.uid();v_business uuid:=nullif(p_contact->>'business_id','')::uuid;v_prospect uuid:=nullif(p_contact->>'prospect_id','')::uuid;v_id uuid:=coalesce(nullif(p_contact->>'id','')::uuid,gen_random_uuid());v_row public.platform_billing_contacts_v156%rowtype;v_hash text;v_replay jsonb;
begin
  if v_actor is null or p_idempotency_key is null or ((v_business is not null)=(v_prospect is not null)) then raise exception 'valid scoped billing contact is required' using errcode='22023';end if;
  if v_business is not null and not app.v156_can('rw') then raise exception 'billing write access is required' using errcode='42501';end if;
  if v_prospect is not null and not app.v156_can_prospect(v_prospect,'rw') then raise exception 'CRM write access is required' using errcode='42501';end if;
  if coalesce(p_contact->>'email','')!~*'^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$' then raise exception 'valid billing email is required' using errcode='22023';end if;
  v_hash:=encode(extensions.digest(jsonb_build_object('contact',p_contact)::text,'sha256'),'hex');
  perform pg_advisory_xact_lock(hashtextextended('v156-contact:'||p_idempotency_key::text,156));
  v_replay:=app.v156_operation_replay(p_idempotency_key,'billing_contact',v_actor,v_hash);if v_replay is not null then return v_replay;end if;
  if p_contact?'id' and exists(select 1 from public.platform_billing_contacts_v156 c where c.id=v_id and (c.business_id is distinct from v_business or c.prospect_id is distinct from v_prospect)) then
    raise exception 'billing contact scope does not match' using errcode='42501';
  end if;
  if p_contact->>'recipient_role'='primary' then update public.platform_billing_contacts_v156 set active=false,updated_by=v_actor,updated_at=clock_timestamp() where active and recipient_role='primary' and id<>v_id and (business_id=v_business or prospect_id=v_prospect);end if;
  insert into public.platform_billing_contacts_v156(id,business_id,prospect_id,business_display_name,legal_entity_name,
    registration_number,billing_address,country,contact_name,email,telephone,recipient_role,purchase_order_number,
    customer_reference,active,created_by,updated_by)
  values(v_id,v_business,v_prospect,btrim(p_contact->>'business_display_name'),btrim(p_contact->>'legal_entity_name'),
    nullif(btrim(p_contact->>'registration_number'),''),coalesce(p_contact->'billing_address','{}'::jsonb),
    coalesce(nullif(btrim(p_contact->>'country'),''),'Singapore'),btrim(p_contact->>'contact_name'),
    lower(btrim(p_contact->>'email')),nullif(btrim(p_contact->>'telephone'),''),p_contact->>'recipient_role',
    nullif(btrim(p_contact->>'purchase_order_number'),''),nullif(btrim(p_contact->>'customer_reference'),''),
    coalesce((p_contact->>'active')::boolean,true),v_actor,v_actor)
  on conflict(id) do update set business_display_name=excluded.business_display_name,legal_entity_name=excluded.legal_entity_name,
    registration_number=excluded.registration_number,billing_address=excluded.billing_address,country=excluded.country,
    contact_name=excluded.contact_name,email=excluded.email,telephone=excluded.telephone,recipient_role=excluded.recipient_role,
    purchase_order_number=excluded.purchase_order_number,customer_reference=excluded.customer_reference,active=excluded.active,
    updated_by=v_actor,updated_at=clock_timestamp() returning * into v_row;
  insert into public.platform_subscription_dispatch_audit_v156(action,entity_type,entity_id,detail,actor)
  values('billing_contact_saved','billing_contact',v_row.id,jsonb_build_object('business_id',v_business,'prospect_id',v_prospect,'recipient_role',v_row.recipient_role),v_actor);
  return app.v156_store_operation(p_idempotency_key,'billing_contact',v_actor,v_hash,jsonb_build_object('contact',to_jsonb(v_row)));
end $$;

create or replace function public.platform_save_crm_commercial_v156(p_prospect uuid,p_data jsonb,p_idempotency_key uuid)
returns jsonb language plpgsql security definer set search_path to 'pg_catalog','public','app','pg_temp' as $$
declare v_actor uuid:=auth.uid();v_row public.platform_crm_commercial_v156%rowtype;v_hash text;v_replay jsonb;
begin
  if v_actor is null or not app.v156_can_prospect(p_prospect,'rw') then raise exception 'CRM write access is required' using errcode='42501';end if;
  if p_idempotency_key is null or jsonb_typeof(p_data)<>'object' then raise exception 'valid commercial request is required' using errcode='22023';end if;
  v_hash:=encode(extensions.digest(jsonb_build_object('prospect',p_prospect,'data',p_data)::text,'sha256'),'hex');
  perform pg_advisory_xact_lock(hashtextextended('v156-commercial:'||p_idempotency_key::text,156));
  v_replay:=app.v156_operation_replay(p_idempotency_key,'crm_commercial',v_actor,v_hash);if v_replay is not null then return v_replay;end if;
  insert into public.platform_crm_commercial_v156(prospect_id,lead_source,expected_plan,billing_interval,expected_value_cents,
    proposed_discount_cents,expected_close_date,intended_duration,purchase_order_number,customer_reference,updated_by)
  values(p_prospect,nullif(btrim(p_data->>'lead_source'),''),nullif(btrim(p_data->>'expected_plan'),''),
    nullif(p_data->>'billing_interval',''),nullif(p_data->>'expected_value_cents','')::bigint,
    coalesce((p_data->>'proposed_discount_cents')::bigint,0),nullif(p_data->>'expected_close_date','')::date,
    nullif(btrim(p_data->>'intended_duration'),''),nullif(btrim(p_data->>'purchase_order_number'),''),
    nullif(btrim(p_data->>'customer_reference'),''),v_actor)
  on conflict(prospect_id) do update set lead_source=excluded.lead_source,expected_plan=excluded.expected_plan,
    billing_interval=excluded.billing_interval,expected_value_cents=excluded.expected_value_cents,
    proposed_discount_cents=excluded.proposed_discount_cents,expected_close_date=excluded.expected_close_date,
    intended_duration=excluded.intended_duration,purchase_order_number=excluded.purchase_order_number,
    customer_reference=excluded.customer_reference,updated_by=v_actor,updated_at=clock_timestamp()
  returning * into v_row;
  return app.v156_store_operation(p_idempotency_key,'crm_commercial',v_actor,v_hash,jsonb_build_object('commercial',to_jsonb(v_row)));
end $$;

create or replace function public.platform_link_checkout_command_v156(p_prospect uuid,p_command uuid,p_idempotency_key uuid)
returns jsonb language plpgsql security definer set search_path to 'pg_catalog','public','app','pg_temp' as $$
declare v_actor uuid:=auth.uid();v_business uuid;v_command public.billing_commands%rowtype;v_row public.platform_crm_commercial_v156%rowtype;
begin
  if v_actor is null or not app.v156_can_prospect(p_prospect,'rw') then raise exception 'CRM write access is required' using errcode='42501';end if;
  select converted_business_id into v_business from public.sme_prospects where id=p_prospect;if v_business is null then raise exception 'create and link the business before Stripe Checkout' using errcode='22023';end if;
  select * into v_command from public.billing_commands where id=p_command and business_id=v_business and command_type='create_checkout' and status='completed' and provider_object_id like 'cs_%' and redirect_url~'^https://checkout\\.stripe\\.com/' ;if not found then raise exception 'completed Stripe Checkout command was not found' using errcode='22023';end if;
  insert into public.platform_crm_commercial_v156(prospect_id,checkout_session_id,checkout_url,checkout_created_at,payment_link_status,updated_by)
  values(p_prospect,v_command.provider_object_id,v_command.redirect_url,coalesce(v_command.completed_at,clock_timestamp()),'created',v_actor)
  on conflict(prospect_id) do update set checkout_session_id=excluded.checkout_session_id,checkout_url=excluded.checkout_url,checkout_created_at=excluded.checkout_created_at,payment_link_status='created',updated_by=v_actor,updated_at=clock_timestamp() returning * into v_row;
  if not exists(select 1 from public.sme_prospect_activities where prospect_id=p_prospect and detail='checkout-command:'||p_command) then insert into public.sme_prospect_activities(prospect_id,activity_type,summary,detail,created_by) values(p_prospect,'system','Stripe Checkout created','checkout-command:'||p_command,v_actor);end if;
  return jsonb_build_object('commercial',to_jsonb(v_row),'checkout_url',v_command.redirect_url,'replayed',false);
end $$;

create or replace function public.platform_finalize_quotation_v156(p_prospect uuid,p_issue_date date,p_expiry_date date,
  p_line_items jsonb,p_notes text,p_idempotency_key uuid)
returns jsonb language plpgsql security definer set search_path to 'pg_catalog','public','app','extensions','pg_temp' as $$
declare v_actor uuid:=auth.uid();v_profile public.platform_billing_profiles_v156%rowtype;v_customer jsonb;v_commercial public.platform_crm_commercial_v156%rowtype;v_doc public.platform_subscription_documents_v156%rowtype;v_subtotal bigint;v_discount bigint;v_tax bigint;v_total bigint;v_number text;v_snapshot jsonb;v_hash text;
begin
  if v_actor is null or not app.v156_can_prospect(p_prospect,'rw') then raise exception 'CRM write access is required' using errcode='42501';end if;
  if p_expiry_date<p_issue_date or jsonb_typeof(p_line_items)<>'array' or jsonb_array_length(p_line_items)=0 then raise exception 'valid quotation dates and lines are required' using errcode='22023';end if;
  select * into v_profile from public.platform_billing_profiles_v156 order by version desc limit 1;
  if not app.v156_profile_ready(v_profile) then raise exception 'seller legal, GST and payment settings are incomplete' using errcode='22023';end if;
  v_customer:=app.v156_customer_snapshot(null,p_prospect);if v_customer is null then raise exception 'primary billing contact is required' using errcode='22023';end if;
  select * into v_commercial from public.platform_crm_commercial_v156 where prospect_id=p_prospect;
  v_subtotal:=coalesce((select sum((line->>'quantity')::numeric*(line->>'unit_amount_cents')::bigint) from jsonb_array_elements(p_line_items) line),0);
  v_discount:=coalesce(v_commercial.proposed_discount_cents,0);v_tax:=case when v_profile.gst_status='registered' then round((v_subtotal-v_discount)*v_profile.gst_rate_bps::numeric/10000) else 0 end;v_total:=v_subtotal-v_discount+v_tax;
  if v_total<=0 then raise exception 'quotation total must be positive' using errcode='22023';end if;
  v_hash:=encode(extensions.digest(jsonb_build_object('prospect',p_prospect,'issue',p_issue_date,'expiry',p_expiry_date,'lines',p_line_items,'notes',p_notes)::text,'sha256'),'hex');
  select * into v_doc from public.platform_subscription_documents_v156 where operation_key=p_idempotency_key;
  if found then if v_doc.request_hash<>v_hash then raise exception 'idempotency key conflict' using errcode='22023';end if;return jsonb_build_object('document',to_jsonb(v_doc),'replayed',true);end if;
  v_number:=app.v156_next_document_number('quotation',p_issue_date);
  v_snapshot:=jsonb_build_object('document_type','quotation','number',v_number,'issue_date',p_issue_date,'expiry_date',p_expiry_date,
    'seller',app.v156_seller_snapshot(v_profile),'customer',v_customer,'plan',v_commercial.expected_plan,
    'billing_interval',v_commercial.billing_interval,'intended_duration',v_commercial.intended_duration,
    'line_items',p_line_items,'discount_cents',v_discount,'subtotal_cents',v_subtotal,'tax_cents',v_tax,
    'total_cents',v_total,'currency','SGD','payment_received',false,'notes',nullif(btrim(p_notes),''));
  insert into public.platform_subscription_documents_v156(document_type,document_number,prospect_id,seller_profile_id,
    issue_date,expiry_date,subtotal_cents,discount_cents,tax_cents,total_cents,balance_due_cents,snapshot,snapshot_sha256,
    finalized_at,operation_key,request_hash,created_by)
  values('quotation',v_number,p_prospect,v_profile.id,p_issue_date,p_expiry_date,v_subtotal,v_discount,v_tax,v_total,v_total,
    v_snapshot,encode(extensions.digest(v_snapshot::text,'sha256'),'hex'),clock_timestamp(),p_idempotency_key,v_hash,v_actor) returning * into v_doc;
  insert into public.platform_subscription_document_events_v156(document_id,status,source_type,source_id,actor)
  values(v_doc.id,'finalized','admin',p_idempotency_key::text,v_actor);
  update public.platform_crm_commercial_v156 set quotation_status='draft',updated_by=v_actor,updated_at=clock_timestamp() where prospect_id=p_prospect;
  insert into public.sme_prospect_activities(prospect_id,consultant_id,activity_type,summary,detail,created_by)
  select p_prospect,assigned_consultant_id,'system','Quotation generated',v_number,v_actor from public.sme_prospects where id=p_prospect;
  return jsonb_build_object('document',to_jsonb(v_doc),'snapshot',v_snapshot,'replayed',false);
end $$;

create or replace function app.v156_prepare_billing_event(p_event_id text)
returns jsonb language plpgsql security definer set search_path to 'pg_catalog','public','app','extensions','pg_temp' as $$
declare v_event public.billing_provider_events%rowtype;v_invoice public.billing_provider_invoices%rowtype;v_subscription public.billing_provider_subscriptions%rowtype;v_profile public.platform_billing_profiles_v156%rowtype;v_customer jsonb;v_prospect uuid;v_invoice_doc public.platform_subscription_documents_v156%rowtype;v_receipt_doc public.platform_subscription_documents_v156%rowtype;v_summary_doc public.platform_subscription_documents_v156%rowtype;v_quote uuid;v_number text;v_snapshot jsonb;v_id uuid;v_status text;v_period_start date;v_period_end date;v_recipient text[];v_cc text[];v_docs uuid[];v_first boolean;v_previous_stage text;
begin
  select * into v_event from public.billing_provider_events where event_id=p_event_id and processing_status='processed';if not found or v_event.business_id is null then return jsonb_build_object('status','ignored');end if;
  select id into v_prospect from public.sme_prospects where converted_business_id=v_event.business_id order by converted_at desc nulls last limit 1;
  if v_event.event_type in ('invoice.payment_failed','invoice.payment_action_required') then
    select * into v_invoice from public.billing_provider_invoices where provider_invoice_id=v_event.object_id;if not found then return jsonb_build_object('status','ignored');end if;
    if v_invoice.paid_normalized then
      return jsonb_build_object('status','ignored_stale','reason','invoice_already_paid');
    elsif v_event.event_type='invoice.payment_failed' then
      perform app.v156_upsert_task('payment-failed:'||v_invoice.provider_invoice_id,'payment_failed',v_event.business_id,v_prospect,v_invoice.provider_subscription_id,v_invoice.provider_invoice_id,'urgent',clock_timestamp(),'Follow up failed subscription payment',p_event_id);
    else
      perform app.v156_upsert_task('payment-action:'||v_invoice.provider_invoice_id,'payment_action_required',v_event.business_id,v_prospect,v_invoice.provider_subscription_id,v_invoice.provider_invoice_id,'urgent',clock_timestamp(),'Customer payment action is required',p_event_id);
    end if;
    insert into public.platform_subscription_lifecycle_events_v156(business_id,provider_subscription_id,lifecycle_status,snapshot,source_type,source_id,occurred_at)
    values(v_event.business_id,v_invoice.provider_subscription_id,case when v_event.event_type='invoice.payment_failed' then 'past_due' else 'payment_action_required' end,jsonb_build_object('invoice_id',v_invoice.provider_invoice_id,'invoice_status',v_invoice.status),'stripe_event',p_event_id,v_event.event_created_at) on conflict do nothing;
    return jsonb_build_object('status','processed','follow_up_created',true);
  end if;
  if v_event.event_type in ('invoice.voided','invoice.marked_uncollectible') then
    select * into v_invoice from public.billing_provider_invoices where provider_invoice_id=v_event.object_id;if not found then return jsonb_build_object('status','ignored');end if;
    select * into v_invoice_doc from public.platform_subscription_documents_v156 where provider_invoice_id=v_invoice.provider_invoice_id and document_type='invoice';
    if found then insert into public.platform_subscription_document_events_v156(document_id,status,source_type,source_id)
      values(v_invoice_doc.id,case when v_event.event_type='invoice.voided' then 'void' else 'uncollectible' end,'stripe_event',p_event_id) on conflict do nothing;end if;
    return jsonb_build_object('status','processed','document_state',case when v_event.event_type='invoice.voided' then 'void' else 'uncollectible' end);
  end if;
  if v_event.event_type in ('refund.created','charge.dispute.created') then
    select invoice.* into v_invoice from public.billing_adjustments adjustment join public.billing_provider_invoices invoice on invoice.provider_invoice_id=adjustment.provider_invoice_id where adjustment.source_event_id=p_event_id;
    if not found then return jsonb_build_object('status','ignored');end if;
    select * into v_invoice_doc from public.platform_subscription_documents_v156 where provider_invoice_id=v_invoice.provider_invoice_id and document_type='invoice';
    if found then
      select case when abs(coalesce(sum(total_cents),0))>=v_invoice.amount_paid_cents then 'refunded' else 'partially_refunded' end into v_status from public.billing_adjustments where provider_invoice_id=v_invoice.provider_invoice_id and adjustment_type in ('refund','chargeback');
      insert into public.platform_subscription_document_events_v156(document_id,status,source_type,source_id) values(v_invoice_doc.id,v_status,'stripe_event',p_event_id) on conflict do nothing;
    end if;
    if v_prospect is not null and not exists(select 1 from public.sme_prospect_activities where prospect_id=v_prospect and detail='event:'||p_event_id) then insert into public.sme_prospect_activities(prospect_id,activity_type,summary,detail) values(v_prospect,'payment',case when v_event.event_type='refund.created' then 'Verified Stripe refund recorded' else 'Stripe payment dispute recorded' end,'event:'||p_event_id);end if;
    return jsonb_build_object('status','processed','document_state',v_status);
  end if;
  if v_event.event_type like 'customer.subscription.%' then
    select * into v_subscription from public.billing_provider_subscriptions where provider_subscription_id=v_event.object_id;if not found then return jsonb_build_object('status','ignored');end if;
    v_status:=case when v_subscription.cancel_at_period_end then 'cancel_at_period_end' when v_subscription.status='trialing' then 'trial' when v_subscription.status='active' then 'active' when v_subscription.status='incomplete' then 'payment_incomplete' when v_subscription.status='past_due' then 'past_due' when v_subscription.status='paused' then 'paused' when v_subscription.status='canceled' then 'cancelled' else 'payment_incomplete' end;
    insert into public.platform_subscription_lifecycle_events_v156(business_id,provider_subscription_id,lifecycle_status,snapshot,source_type,source_id,occurred_at)
    values(v_event.business_id,v_subscription.provider_subscription_id,v_status,jsonb_build_object('canonical_status',v_subscription.status,'start_date',v_subscription.created_at,'trial_end',v_subscription.trial_end,'paid_period_start',v_subscription.current_period_start,'paid_period_end',v_subscription.current_period_end,'billing_cycle_anchor',v_subscription.billing_cycle_anchor,'cancel_at_period_end',v_subscription.cancel_at_period_end,'scheduled_end',case when v_subscription.cancel_at_period_end then v_subscription.current_period_end end,'actual_end',v_subscription.ended_at,'no_scheduled_end',not v_subscription.cancel_at_period_end and v_subscription.ended_at is null),'stripe_event',p_event_id,v_event.event_created_at) on conflict do nothing;
    if v_subscription.cancel_at_period_end then perform app.v156_upsert_task('cancel-at-end:'||v_subscription.provider_subscription_id,'cancel_at_period_end',v_event.business_id,v_prospect,v_subscription.provider_subscription_id,null,'high',coalesce(v_subscription.current_period_end,clock_timestamp()),'Subscription is scheduled to end',p_event_id);end if;
    return jsonb_build_object('status','processed');
  end if;
  select * into v_profile from public.platform_billing_profiles_v156 order by version desc limit 1;
  if not app.v156_profile_ready(v_profile) then perform app.v156_upsert_task('billing-profile:'||v_event.business_id,'billing_profile_missing',v_event.business_id,v_prospect,null,null,'urgent',clock_timestamp(),'Complete seller legal and billing settings',p_event_id);return jsonb_build_object('status','blocked','reason','billing_profile_incomplete');end if;
  v_customer:=app.v156_customer_snapshot(v_event.business_id,v_prospect);
  if v_customer is null then perform app.v156_upsert_task('billing-contact:'||v_event.business_id,'billing_contact_missing',v_event.business_id,v_prospect,null,null,'high',clock_timestamp(),'Add a primary billing contact',p_event_id);return jsonb_build_object('status','blocked','reason','billing_contact_missing');end if;

  if v_event.event_type like 'invoice.%' then
    select * into v_invoice from public.billing_provider_invoices where provider_invoice_id=v_event.object_id;if not found then return jsonb_build_object('status','ignored');end if;
    select * into v_subscription from public.billing_provider_subscriptions where provider_subscription_id=v_invoice.provider_subscription_id;
    v_period_start:=(v_invoice.period_start at time zone 'Asia/Singapore')::date;v_period_end:=((v_invoice.period_end at time zone 'Asia/Singapore')::date-1);
    select * into v_invoice_doc from public.platform_subscription_documents_v156 where provider_invoice_id=v_invoice.provider_invoice_id and document_type='invoice';
    -- Stripe's finalised/open invoice is itself the pre-payment obligation.  The
    -- Peekaa mirror is issued only from verified invoice.paid so its immutable
    -- snapshot can never be frozen with an unpaid balance and later mislabelled.
    if not found and v_event.event_type='invoice.paid' then
      v_number:=app.v156_next_document_number('invoice',(coalesce(v_invoice.finalized_at,v_event.event_created_at) at time zone 'Asia/Singapore')::date);
      v_snapshot:=jsonb_build_object('document_type','invoice','number',v_number,'stripe_invoice_id',v_invoice.provider_invoice_id,
        'stripe_invoice_number',v_invoice.number,'canonical_provider','Stripe','no_second_payment_obligation',true,
        'issue_date',(coalesce(v_invoice.finalized_at,v_event.event_created_at) at time zone 'Asia/Singapore')::date,'due_date',(v_invoice.due_at at time zone 'Asia/Singapore')::date,
        'service_period_start',v_period_start,'service_period_end',v_period_end,'seller',app.v156_seller_snapshot(v_profile),
        'customer',v_customer,'subtotal_cents',v_invoice.subtotal_ex_tax_cents,'tax_cents',v_invoice.tax_cents,
        'total_cents',v_invoice.total_cents,'amount_paid_cents',v_invoice.amount_paid_cents,'balance_due_cents',v_invoice.amount_remaining_cents,
        'currency',v_invoice.currency,'payment_status',v_invoice.status,
        'line_items',jsonb_build_array(jsonb_build_object('description','Peekaa '||coalesce(v_subscription.cadence,'subscription')||' subscription','quantity',1,'unit_amount_cents',v_invoice.subtotal_ex_tax_cents)),
        'bank_transfer_reference',v_number||' – '||(v_customer->>'legal_entity_name'));
      insert into public.platform_subscription_documents_v156(document_type,document_number,business_id,prospect_id,seller_profile_id,
        provider_invoice_id,provider_subscription_id,issue_date,due_date,service_period_start,service_period_end,currency,
        subtotal_cents,tax_cents,total_cents,amount_paid_cents,balance_due_cents,snapshot,snapshot_sha256,finalized_at,
        operation_key,request_hash,source_event_id)
      values('invoice',v_number,v_event.business_id,v_prospect,v_profile.id,v_invoice.provider_invoice_id,v_invoice.provider_subscription_id,
        (coalesce(v_invoice.finalized_at,v_event.event_created_at) at time zone 'Asia/Singapore')::date,(v_invoice.due_at at time zone 'Asia/Singapore')::date,
        v_period_start,v_period_end,v_invoice.currency,v_invoice.subtotal_ex_tax_cents,v_invoice.tax_cents,v_invoice.total_cents,
        v_invoice.amount_paid_cents,v_invoice.amount_remaining_cents,v_snapshot,encode(extensions.digest(v_snapshot::text,'sha256'),'hex'),clock_timestamp(),
        (md5('v156-invoice:'||v_invoice.provider_invoice_id))::uuid,encode(extensions.digest(v_snapshot::text,'sha256'),'hex'),p_event_id) returning * into v_invoice_doc;
      insert into public.platform_subscription_document_events_v156(document_id,status,source_type,source_id)
      values(v_invoice_doc.id,case when v_invoice.paid_normalized then 'paid' else 'open' end,'stripe_event',p_event_id);
    end if;
    if v_event.event_type='invoice.payment_failed' then
      perform app.v156_upsert_task('payment-failed:'||v_invoice.provider_invoice_id,'payment_failed',v_event.business_id,v_prospect,v_invoice.provider_subscription_id,v_invoice.provider_invoice_id,'urgent',clock_timestamp(),'Follow up failed subscription payment',p_event_id);
    elsif v_event.event_type='invoice.payment_action_required' then
      perform app.v156_upsert_task('payment-action:'||v_invoice.provider_invoice_id,'payment_action_required',v_event.business_id,v_prospect,v_invoice.provider_subscription_id,v_invoice.provider_invoice_id,'urgent',clock_timestamp(),'Customer payment action is required',p_event_id);
    elsif v_event.event_type='invoice.paid' then
      update public.platform_subscription_tasks_v156 set status='completed',completed_at=clock_timestamp(),resolution='Payment recovered',updated_at=clock_timestamp()
      where business_id=v_event.business_id and provider_invoice_id=v_invoice.provider_invoice_id and status='open' and task_type in ('payment_failed','payment_action_required','past_due');
      insert into public.platform_subscription_document_events_v156(document_id,status,source_type,source_id)
      values(v_invoice_doc.id,'paid','stripe_event',p_event_id) on conflict do nothing;
      select * into v_receipt_doc from public.platform_subscription_documents_v156 where provider_invoice_id=v_invoice.provider_invoice_id and document_type='receipt';
      if not found then
        v_number:=app.v156_next_document_number('receipt',(v_invoice.paid_at at time zone 'Asia/Singapore')::date);
        v_snapshot:=jsonb_build_object('document_type','receipt','number',v_number,'related_invoice_number',v_invoice_doc.document_number,
          'stripe_invoice_id',v_invoice.provider_invoice_id,'stripe_payment_reference',v_invoice.provider_payment_intent_id,
          'seller',app.v156_seller_snapshot(v_profile),'customer',v_customer,'payment_date',v_invoice.paid_at,
          'payment_method','stripe','payment_method_label','Payment received via Stripe','amount_received_cents',v_invoice.amount_paid_cents,'currency',v_invoice.currency,
          'service_period_start',v_period_start,'service_period_end',v_period_end,'remaining_balance_cents',v_invoice.amount_remaining_cents);
        insert into public.platform_subscription_documents_v156(document_type,document_number,business_id,prospect_id,seller_profile_id,
          provider_invoice_id,provider_subscription_id,original_document_id,issue_date,service_period_start,service_period_end,currency,
          subtotal_cents,tax_cents,total_cents,amount_paid_cents,balance_due_cents,snapshot,snapshot_sha256,finalized_at,operation_key,request_hash,source_event_id)
        values('receipt',v_number,v_event.business_id,v_prospect,v_profile.id,v_invoice.provider_invoice_id,v_invoice.provider_subscription_id,
          v_invoice_doc.id,(v_invoice.paid_at at time zone 'Asia/Singapore')::date,v_period_start,v_period_end,v_invoice.currency,
          v_invoice.amount_paid_cents,0,v_invoice.amount_paid_cents,v_invoice.amount_paid_cents,0,v_snapshot,
          encode(extensions.digest(v_snapshot::text,'sha256'),'hex'),clock_timestamp(),(md5('v156-receipt:'||v_invoice.provider_invoice_id))::uuid,
          encode(extensions.digest(v_snapshot::text,'sha256'),'hex'),p_event_id) returning * into v_receipt_doc;
        insert into public.platform_subscription_document_events_v156(document_id,status,source_type,source_id) values(v_receipt_doc.id,'issued','stripe_event',p_event_id);
      end if;
      select * into v_summary_doc from public.platform_subscription_documents_v156 where provider_invoice_id=v_invoice.provider_invoice_id and document_type='subscription_summary';
      if not found then
        v_number:=app.v156_next_document_number('subscription_summary',(v_invoice.paid_at at time zone 'Asia/Singapore')::date);
        v_snapshot:=jsonb_build_object('document_type','subscription_summary','number',v_number,'business',v_customer,
          'plan',coalesce(v_subscription.cadence,'subscription'),'billing_interval',v_subscription.cadence,
          'active_since',v_subscription.created_at,'paid_period_start',v_period_start,'paid_period_end',v_period_end,
          'next_renewal',case when not v_subscription.cancel_at_period_end then (v_subscription.current_period_end at time zone 'Asia/Singapore')::date end,
          'scheduled_end',case when v_subscription.cancel_at_period_end then (v_subscription.current_period_end at time zone 'Asia/Singapore')::date end,
          'no_scheduled_end',not v_subscription.cancel_at_period_end,'seller',app.v156_seller_snapshot(v_profile));
        insert into public.platform_subscription_documents_v156(document_type,document_number,business_id,prospect_id,seller_profile_id,
          provider_invoice_id,provider_subscription_id,original_document_id,issue_date,service_period_start,service_period_end,currency,
          subtotal_cents,total_cents,amount_paid_cents,balance_due_cents,snapshot,snapshot_sha256,finalized_at,operation_key,request_hash,source_event_id)
        values('subscription_summary',v_number,v_event.business_id,v_prospect,v_profile.id,v_invoice.provider_invoice_id,v_invoice.provider_subscription_id,
          v_invoice_doc.id,(v_invoice.paid_at at time zone 'Asia/Singapore')::date,v_period_start,v_period_end,v_invoice.currency,0,0,0,0,v_snapshot,
          encode(extensions.digest(v_snapshot::text,'sha256'),'hex'),clock_timestamp(),(md5('v156-summary:'||v_invoice.provider_invoice_id))::uuid,
          encode(extensions.digest(v_snapshot::text,'sha256'),'hex'),p_event_id) returning * into v_summary_doc;
        insert into public.platform_subscription_document_events_v156(document_id,status,source_type,source_id) values(v_summary_doc.id,'finalized','stripe_event',p_event_id);
      end if;
      insert into public.platform_subscription_lifecycle_events_v156(business_id,provider_subscription_id,lifecycle_status,snapshot,source_type,source_id,occurred_at)
      values(v_event.business_id,v_invoice.provider_subscription_id,'payment_received',jsonb_build_object('paid_through',v_period_end,'next_renewal',(v_subscription.current_period_end at time zone 'Asia/Singapore')::date,'invoice_id',v_invoice.provider_invoice_id),'stripe_event',p_event_id,v_invoice.paid_at) on conflict do nothing;
      if v_prospect is not null then
        select current_stage_key into v_previous_stage from public.sme_prospects where id=v_prospect for update;
        if v_previous_stage not in ('client','account_created','onboarding','activated') then
          insert into public.sme_prospect_stage_history(prospect_id,from_stage_key,to_stage_key,reason_code,reason_detail,occurred_at)
          values(v_prospect,v_previous_stage,'client','verified_payment','Stripe invoice.paid event '||p_event_id,v_invoice.paid_at);
          update public.sme_prospects set current_stage_key='client',stage_entered_at=clock_timestamp(),version=version+1,updated_at=clock_timestamp() where id=v_prospect;
        end if;
        if not exists(select 1 from public.sme_prospect_activities where prospect_id=v_prospect and activity_type='payment' and detail='event:'||p_event_id) then
          insert into public.sme_prospect_activities(prospect_id,consultant_id,activity_type,summary,detail,occurred_at)
          select v_prospect,assigned_consultant_id,'payment','Verified subscription payment received','event:'||p_event_id,v_invoice.paid_at from public.sme_prospects where id=v_prospect;
        end if;
      end if;
      perform app.v156_upsert_task('onboarding:'||v_event.business_id||':'||v_invoice.provider_subscription_id,'onboarding',v_event.business_id,v_prospect,v_invoice.provider_subscription_id,v_invoice.provider_invoice_id,'high',clock_timestamp()+interval '1 day','Schedule subscription onboarding',p_event_id);
      select array_agg(email order by recipient_role,email) filter(where recipient_role='primary'),array_agg(email order by recipient_role,email) filter(where recipient_role<>'primary') into v_recipient,v_cc from public.platform_billing_contacts_v156 where active and (business_id=v_event.business_id or prospect_id=v_prospect);
      if v_profile.internal_copy_email is not null then select array_agg(distinct address) into v_cc from unnest(coalesce(v_cc,'{}'::text[])||array[v_profile.internal_copy_email]) address where not(address=any(v_recipient));end if;
      select count(*)=1 into v_first from public.billing_provider_invoices where business_id=v_event.business_id and paid_normalized and paid_at<=v_invoice.paid_at;
      v_docs:=array[v_invoice_doc.id,v_receipt_doc.id,v_summary_doc.id];
      if v_first then select q.id into v_quote from public.platform_subscription_documents_v156 q where q.prospect_id=v_prospect and q.document_type='quotation' and q.finalized_at is not null and q.expiry_date>=(v_invoice.paid_at at time zone 'Asia/Singapore')::date
        and (select e.status from public.platform_subscription_document_events_v156 e where e.document_id=q.id order by e.occurred_at desc,e.id desc limit 1) in ('sent','accepted') order by q.finalized_at desc limit 1;if v_quote is not null then v_docs:=array_append(v_docs,v_quote);end if;end if;
      insert into public.platform_subscription_deliveries_v156(delivery_key,business_id,provider_invoice_id,delivery_type,document_ids,recipients,cc_recipients,subject)
      values('stripe-paid:'||v_invoice.provider_invoice_id,v_event.business_id,v_invoice.provider_invoice_id,case when v_first then 'first_payment_pack' else 'renewal_payment_pack' end,v_docs,v_recipient,coalesce(v_cc,'{}'),'Payment received – Peekaa subscription for '||(v_customer->>'business_display_name')) on conflict(delivery_key) do nothing;
    end if;
  elsif v_event.event_type like 'customer.subscription.%' then
    select * into v_subscription from public.billing_provider_subscriptions where provider_subscription_id=v_event.object_id;if not found then return jsonb_build_object('status','ignored');end if;
    v_status:=case when v_subscription.cancel_at_period_end then 'cancel_at_period_end' when v_subscription.status='trialing' then 'trial' when v_subscription.status='active' then 'active' when v_subscription.status='incomplete' then 'payment_incomplete' when v_subscription.status='past_due' then 'past_due' when v_subscription.status='paused' then 'paused' when v_subscription.status='canceled' then 'cancelled' else 'payment_incomplete' end;
    insert into public.platform_subscription_lifecycle_events_v156(business_id,provider_subscription_id,lifecycle_status,snapshot,source_type,source_id,occurred_at)
    values(v_event.business_id,v_subscription.provider_subscription_id,v_status,jsonb_build_object('canonical_status',v_subscription.status,
      'start_date',v_subscription.created_at,'trial_end',v_subscription.trial_end,'paid_period_start',v_subscription.current_period_start,
      'paid_period_end',v_subscription.current_period_end,'billing_cycle_anchor',v_subscription.billing_cycle_anchor,
      'cancel_at_period_end',v_subscription.cancel_at_period_end,'scheduled_end',case when v_subscription.cancel_at_period_end then v_subscription.current_period_end end,
      'actual_end',v_subscription.ended_at,'no_scheduled_end',not v_subscription.cancel_at_period_end and v_subscription.ended_at is null),
      'stripe_event',p_event_id,v_event.event_created_at) on conflict do nothing;
    if v_subscription.cancel_at_period_end then perform app.v156_upsert_task('cancel-at-end:'||v_subscription.provider_subscription_id,'cancel_at_period_end',v_event.business_id,v_prospect,v_subscription.provider_subscription_id,null,'high',coalesce(v_subscription.current_period_end,clock_timestamp()),'Subscription is scheduled to end',p_event_id);end if;
  end if;
  return jsonb_build_object('status','processed');
end $$;
revoke all on function app.v156_prepare_billing_event(text) from public,anon,authenticated;
grant execute on function app.v156_prepare_billing_event(text) to service_role;

create or replace function public.platform_send_quotation_v156(p_document uuid,p_idempotency_key uuid)
returns jsonb language plpgsql security definer set search_path to 'pg_catalog','public','app','extensions','pg_temp' as $$
declare v_actor uuid:=auth.uid();v_doc public.platform_subscription_documents_v156%rowtype;v_customer jsonb;v_delivery public.platform_subscription_deliveries_v156%rowtype;v_to text[];v_cc text[];v_internal text;v_hash text;v_replay jsonb;
begin
  select * into v_doc from public.platform_subscription_documents_v156 where id=p_document and document_type='quotation' and finalized_at is not null;
  if not found then raise exception 'finalized quotation was not found' using errcode='22023';end if;
  if v_actor is null or not app.v156_can_prospect(v_doc.prospect_id,'rw') then raise exception 'CRM write access is required' using errcode='42501';end if;
  v_hash:=encode(extensions.digest(jsonb_build_object('document',p_document)::text,'sha256'),'hex');
  perform pg_advisory_xact_lock(hashtextextended('v156-send-quote:'||p_idempotency_key::text,156));
  v_replay:=app.v156_operation_replay(p_idempotency_key,'send_quotation',v_actor,v_hash);if v_replay is not null then return v_replay;end if;
  select array_agg(email order by email) filter(where recipient_role='primary'),array_agg(email order by recipient_role,email) filter(where recipient_role<>'primary') into v_to,v_cc from public.platform_billing_contacts_v156 where active and prospect_id=v_doc.prospect_id;
  if coalesce(cardinality(v_to),0)=0 then raise exception 'primary billing recipient is required' using errcode='22023';end if;
  select internal_copy_email into v_internal from public.platform_billing_profiles_v156 where id=v_doc.seller_profile_id;
  if v_internal is not null then select array_agg(distinct address) into v_cc from unnest(coalesce(v_cc,'{}'::text[])||array[v_internal]) address where not(address=any(v_to));end if;
  v_customer:=v_doc.snapshot->'customer';
  insert into public.platform_subscription_deliveries_v156(delivery_key,business_id,prospect_id,provider_invoice_id,delivery_type,document_ids,recipients,cc_recipients,subject)
  values('quotation:'||p_document,v_doc.business_id,v_doc.prospect_id,null,'quotation',array[p_document],v_to,coalesce(v_cc,'{}'),'Peekaa quotation for '||coalesce(v_customer->>'business_display_name',v_customer->>'legal_entity_name'))
  on conflict(delivery_key) do update set updated_at=platform_subscription_deliveries_v156.updated_at returning * into v_delivery;
  -- "Sent" is recorded by v156_service_finish_delivery only after the provider
  -- accepts the message.  Queueing is not delivery evidence.
  return app.v156_store_operation(p_idempotency_key,'send_quotation',v_actor,v_hash,jsonb_build_object('delivery',to_jsonb(v_delivery),'document_number',v_doc.document_number));
end $$;

create or replace function public.platform_create_manual_invoice_v156(p_business uuid,p_issue_date date,p_due_date date,
  p_service_start date,p_service_end date,p_line_items jsonb,p_discount_cents bigint,p_idempotency_key uuid)
returns jsonb language plpgsql security definer set search_path to 'pg_catalog','public','app','extensions','pg_temp' as $$
declare v_actor uuid:=auth.uid();v_profile public.platform_billing_profiles_v156%rowtype;v_customer jsonb;v_doc public.platform_subscription_documents_v156%rowtype;v_subtotal bigint;v_tax bigint;v_total bigint;v_number text;v_snapshot jsonb;v_hash text;v_to text[];v_cc text[];
begin
  if v_actor is null or not app.v156_can('rw') then raise exception 'billing write access is required' using errcode='42501';end if;
  if p_business is null or p_due_date<p_issue_date or p_service_end<p_service_start or jsonb_typeof(p_line_items)<>'array' or jsonb_array_length(p_line_items)=0 or coalesce(p_discount_cents,0)<0 then raise exception 'valid manual invoice terms are required' using errcode='22023';end if;
  select * into v_profile from public.platform_billing_profiles_v156 order by version desc limit 1;if not app.v156_profile_ready(v_profile) then raise exception 'seller legal, GST and payment settings are incomplete' using errcode='22023';end if;
  v_customer:=app.v156_customer_snapshot(p_business,null);if v_customer is null then raise exception 'primary billing contact is required' using errcode='22023';end if;
  v_subtotal:=coalesce((select sum((line->>'quantity')::numeric*(line->>'unit_amount_cents')::bigint) from jsonb_array_elements(p_line_items) line),0);
  v_tax:=case when v_profile.gst_status='registered' then round((v_subtotal-coalesce(p_discount_cents,0))*v_profile.gst_rate_bps::numeric/10000) else 0 end;v_total:=v_subtotal-coalesce(p_discount_cents,0)+v_tax;
  if v_total<=0 then raise exception 'manual invoice total must be positive' using errcode='22023';end if;
  v_hash:=encode(extensions.digest(jsonb_build_object('business',p_business,'issue',p_issue_date,'due',p_due_date,'service_start',p_service_start,'service_end',p_service_end,'lines',p_line_items,'discount',p_discount_cents)::text,'sha256'),'hex');
  select * into v_doc from public.platform_subscription_documents_v156 where operation_key=p_idempotency_key;
  if found then if v_doc.request_hash<>v_hash then raise exception 'idempotency key conflict' using errcode='22023';end if;return jsonb_build_object('document',to_jsonb(v_doc),'replayed',true);end if;
  v_number:=app.v156_next_document_number('invoice',p_issue_date);
  v_snapshot:=jsonb_build_object('document_type','invoice','number',v_number,'issue_date',p_issue_date,'due_date',p_due_date,'service_period_start',p_service_start,'service_period_end',p_service_end,'seller',app.v156_seller_snapshot(v_profile),'customer',v_customer,'line_items',p_line_items,'discount_cents',coalesce(p_discount_cents,0),'subtotal_cents',v_subtotal,'tax_cents',v_tax,'total_cents',v_total,'amount_paid_cents',0,'balance_due_cents',v_total,'currency','SGD','payment_status','open','payment_method','bank_transfer');
  insert into public.platform_subscription_documents_v156(document_type,document_number,business_id,seller_profile_id,issue_date,due_date,service_period_start,service_period_end,subtotal_cents,discount_cents,tax_cents,total_cents,balance_due_cents,snapshot,snapshot_sha256,finalized_at,operation_key,request_hash,created_by)
  values('invoice',v_number,p_business,v_profile.id,p_issue_date,p_due_date,p_service_start,p_service_end,v_subtotal,coalesce(p_discount_cents,0),v_tax,v_total,v_total,v_snapshot,encode(extensions.digest(v_snapshot::text,'sha256'),'hex'),clock_timestamp(),p_idempotency_key,v_hash,v_actor) returning * into v_doc;
  insert into public.platform_subscription_document_events_v156(document_id,status,source_type,source_id,actor) values(v_doc.id,'open','admin',p_idempotency_key::text,v_actor);
  select array_agg(email order by email) filter(where recipient_role='primary'),array_agg(email order by recipient_role,email) filter(where recipient_role<>'primary') into v_to,v_cc from public.platform_billing_contacts_v156 where active and business_id=p_business;
  if v_profile.internal_copy_email is not null then select array_agg(distinct address) into v_cc from unnest(coalesce(v_cc,'{}'::text[])||array[v_profile.internal_copy_email]) address where not(address=any(v_to));end if;
  insert into public.platform_subscription_deliveries_v156(delivery_key,business_id,delivery_type,document_ids,recipients,cc_recipients,subject)
  values('manual-invoice:'||v_doc.id,p_business,'manual_invoice',array[v_doc.id],v_to,coalesce(v_cc,'{}'),'Peekaa invoice '||v_number||' for '||(v_customer->>'business_display_name'));
  insert into public.platform_subscription_dispatch_audit_v156(action,entity_type,entity_id,detail,actor) values('manual_invoice_finalized','document',v_doc.id,jsonb_build_object('document_number',v_number),v_actor);
  return jsonb_build_object('document',to_jsonb(v_doc),'replayed',false);
end $$;

create or replace function public.platform_prepare_manual_evidence_upload_v156(p_invoice uuid,p_filename text,p_content_type text,p_idempotency_key uuid)
returns jsonb language plpgsql security definer set search_path to 'pg_catalog','public','app','pg_temp' as $$
declare v_actor uuid:=auth.uid();v_doc public.platform_subscription_documents_v156%rowtype;v_extension text;v_path text;
begin
  if v_actor is null or not app.v156_can('rw') then raise exception 'billing write access is required' using errcode='42501';end if;
  select * into v_doc from public.platform_subscription_documents_v156 where id=p_invoice and document_type='invoice' and provider_invoice_id is null and finalized_at is not null;
  if not found then raise exception 'manual invoice was not found' using errcode='22023';end if;
  if p_content_type not in ('application/pdf','image/jpeg','image/png') then raise exception 'payment evidence must be PDF, JPEG or PNG' using errcode='22023';end if;
  v_extension:=case p_content_type when 'application/pdf' then 'pdf' when 'image/jpeg' then 'jpg' else 'png' end;
  v_path:='platform-subscriptions/manual-evidence/'||v_doc.business_id||'/'||v_doc.id||'/'||p_idempotency_key||'.'||v_extension;
  insert into public.platform_subscription_dispatch_audit_v156(action,entity_type,entity_id,detail,actor)
  values('manual_evidence_upload_authorised','invoice',v_doc.id,jsonb_build_object('object_path',v_path,'filename',left(p_filename,180),'content_type',p_content_type),v_actor);
  return jsonb_build_object('bucket_id','sme-private','object_path',v_path,'content_type',p_content_type,'expires_in',300);
end $$;

create or replace function public.platform_request_manual_evidence_read_v156(p_payment uuid)
returns jsonb language plpgsql stable security definer set search_path to 'pg_catalog','public','app','pg_temp' as $$
declare v_actor uuid:=auth.uid();v_payment public.platform_manual_payments_v156%rowtype;
begin
  if v_actor is null or not app.is_super_admin() then raise exception 'super admin verification is required' using errcode='42501';end if;
  select * into v_payment from public.platform_manual_payments_v156 where id=p_payment;if not found then raise exception 'manual payment was not found' using errcode='22023';end if;
  return jsonb_build_object('bucket_id','sme-private','object_path',v_payment.evidence_object_path,'expires_in',300);
end $$;

create or replace function public.platform_record_manual_payment_v156(p_invoice uuid,p_amount_cents bigint,p_payment_reference text,
  p_value_date date,p_bank_account_last4 text,p_evidence_object_path text,p_idempotency_key uuid)
returns jsonb language plpgsql security definer set search_path to 'pg_catalog','public','app','extensions','pg_temp' as $$
declare v_actor uuid:=auth.uid();v_doc public.platform_subscription_documents_v156%rowtype;v_payment public.platform_manual_payments_v156%rowtype;v_hash text;
begin
  if v_actor is null or not app.v156_can('rw') then raise exception 'billing write access is required' using errcode='42501';end if;
  select * into v_doc from public.platform_subscription_documents_v156 where id=p_invoice and document_type='invoice' and provider_invoice_id is null and finalized_at is not null;if not found then raise exception 'manual invoice was not found' using errcode='22023';end if;
  if p_amount_cents<>v_doc.balance_due_cents or coalesce(btrim(p_payment_reference),'')='' or p_bank_account_last4!~'^[0-9]{4}$'
    or p_evidence_object_path!~('^platform-subscriptions/manual-evidence/'||v_doc.business_id||'/'||v_doc.id||'/[0-9a-f-]+\\.(pdf|jpg|png)$')
    or not exists(select 1 from storage.objects o where o.bucket_id='sme-private' and o.name=p_evidence_object_path)
  then raise exception 'valid private full-payment evidence is required' using errcode='22023';end if;
  v_hash:=encode(extensions.digest(jsonb_build_object('invoice',p_invoice,'amount',p_amount_cents,'reference',p_payment_reference,'value_date',p_value_date,'bank_last4',p_bank_account_last4,'evidence',p_evidence_object_path)::text,'sha256'),'hex');
  select * into v_payment from public.platform_manual_payments_v156 where idempotency_key=p_idempotency_key;
  if found then if v_payment.request_hash<>v_hash then raise exception 'idempotency key conflict' using errcode='22023';end if;return jsonb_build_object('payment',to_jsonb(v_payment),'replayed',true);end if;
  insert into public.platform_manual_payments_v156(invoice_document_id,amount_cents,payment_reference,value_date,bank_account_last4,evidence_object_path,recorded_by,request_hash,idempotency_key)
  values(p_invoice,p_amount_cents,btrim(p_payment_reference),p_value_date,p_bank_account_last4,p_evidence_object_path,v_actor,v_hash,p_idempotency_key) returning * into v_payment;
  insert into public.platform_subscription_dispatch_audit_v156(action,entity_type,entity_id,detail,actor) values('manual_payment_recorded','manual_payment',v_payment.id,jsonb_build_object('invoice',p_invoice,'reference',p_payment_reference),v_actor);
  return jsonb_build_object('payment',to_jsonb(v_payment),'replayed',false);
end $$;

create or replace function public.platform_verify_manual_payment_v156(p_payment uuid,p_decision text,p_reason text,p_idempotency_key uuid)
returns jsonb language plpgsql security definer set search_path to 'pg_catalog','public','app','extensions','pg_temp' as $$
declare v_actor uuid:=auth.uid();v_payment public.platform_manual_payments_v156%rowtype;v_invoice public.platform_subscription_documents_v156%rowtype;v_profile public.platform_billing_profiles_v156%rowtype;v_receipt public.platform_subscription_documents_v156%rowtype;v_customer jsonb;v_snapshot jsonb;v_number text;v_key uuid;v_hash text;v_to text[];v_cc text[];
begin
  if v_actor is null or not app.is_super_admin() then raise exception 'super admin verification is required' using errcode='42501';end if;
  if p_decision not in ('verified','rejected') then raise exception 'manual payment decision is invalid' using errcode='22023';end if;
  select * into v_payment from public.platform_manual_payments_v156 where id=p_payment for update;if not found then raise exception 'manual payment was not found' using errcode='22023';end if;
  if v_payment.status<>'pending_verification' then return jsonb_build_object('payment',to_jsonb(v_payment),'replayed',true);end if;
  if v_payment.recorded_by=v_actor then raise exception 'a second authorised admin must verify manual payment' using errcode='42501';end if;
  update public.platform_manual_payments_v156 set status=p_decision,verified_by=v_actor,verified_at=clock_timestamp(),rejection_reason=case when p_decision='rejected' then nullif(btrim(p_reason),'') end where id=p_payment returning * into v_payment;
  insert into public.platform_subscription_dispatch_audit_v156(action,entity_type,entity_id,detail,actor) values('manual_payment_'||p_decision,'manual_payment',p_payment,jsonb_build_object('reason',nullif(btrim(p_reason),''),'operation_key',p_idempotency_key),v_actor);
  if p_decision='rejected' then return jsonb_build_object('payment',to_jsonb(v_payment),'replayed',false);end if;
  select * into v_invoice from public.platform_subscription_documents_v156 where id=v_payment.invoice_document_id;select * into v_profile from public.platform_billing_profiles_v156 where id=v_invoice.seller_profile_id;v_customer:=v_invoice.snapshot->'customer';
  v_key:=(md5('v156-manual-receipt:'||p_payment))::uuid;select * into v_receipt from public.platform_subscription_documents_v156 where operation_key=v_key;
  if not found then
    v_number:=app.v156_next_document_number('receipt',v_payment.value_date);v_snapshot:=jsonb_build_object('document_type','receipt','number',v_number,'related_invoice_number',v_invoice.document_number,'issue_date',v_payment.value_date,'payment_date',v_payment.value_date,'seller',app.v156_seller_snapshot(v_profile),'customer',v_customer,'service_period_start',v_invoice.service_period_start,'service_period_end',v_invoice.service_period_end,'currency',v_payment.currency,'total_cents',v_payment.amount_cents,'amount_paid_cents',v_payment.amount_cents,'balance_due_cents',0,'payment_method','bank_transfer','payment_method_label','Payment received via bank transfer','payment_reference',v_payment.payment_reference);
    v_hash:=encode(extensions.digest(v_snapshot::text,'sha256'),'hex');
    insert into public.platform_subscription_documents_v156(document_type,document_number,business_id,prospect_id,seller_profile_id,original_document_id,issue_date,service_period_start,service_period_end,currency,subtotal_cents,total_cents,amount_paid_cents,balance_due_cents,snapshot,snapshot_sha256,finalized_at,operation_key,request_hash,created_by)
    values('receipt',v_number,v_invoice.business_id,v_invoice.prospect_id,v_invoice.seller_profile_id,v_invoice.id,v_payment.value_date,v_invoice.service_period_start,v_invoice.service_period_end,v_payment.currency,v_payment.amount_cents,v_payment.amount_cents,v_payment.amount_cents,0,v_snapshot,v_hash,clock_timestamp(),v_key,v_hash,v_actor) returning * into v_receipt;
    insert into public.platform_subscription_document_events_v156(document_id,status,source_type,source_id,actor) values(v_receipt.id,'issued','admin',p_payment::text,v_actor);
    insert into public.platform_subscription_document_events_v156(document_id,status,source_type,source_id,actor) values(v_invoice.id,'paid','admin',p_payment::text,v_actor);
    select array_agg(email order by email) filter(where recipient_role='primary'),array_agg(email order by recipient_role,email) filter(where recipient_role<>'primary') into v_to,v_cc from public.platform_billing_contacts_v156 where active and business_id=v_invoice.business_id;
    if v_profile.internal_copy_email is not null then select array_agg(distinct address) into v_cc from unnest(coalesce(v_cc,'{}'::text[])||array[v_profile.internal_copy_email]) address where not(address=any(v_to));end if;
    insert into public.platform_subscription_deliveries_v156(delivery_key,business_id,delivery_type,document_ids,recipients,cc_recipients,subject)
    values('manual-receipt:'||p_payment,v_invoice.business_id,'manual_receipt',array[v_invoice.id,v_receipt.id],v_to,coalesce(v_cc,'{}'),'Payment received – Peekaa subscription for '||(v_customer->>'business_display_name')) on conflict(delivery_key) do nothing;
    insert into public.platform_subscription_lifecycle_events_v156(business_id,lifecycle_status,snapshot,source_type,source_id)
    values(v_invoice.business_id,'payment_received',jsonb_build_object('manual_payment_id',p_payment,'paid_through',v_invoice.service_period_end,'entitlement_status','manual_policy_review_required'),'manual_payment',p_payment::text) on conflict do nothing;
    perform app.v156_upsert_task('onboarding:manual:'||p_payment,'onboarding',v_invoice.business_id,v_invoice.prospect_id,null,null,'high',clock_timestamp()+interval '1 day','Review manual-payment entitlement and schedule onboarding',null);
  end if;
  return jsonb_build_object('payment',to_jsonb(v_payment),'receipt',to_jsonb(v_receipt),'replayed',false);
end $$;

create or replace function app.v156_billing_event_trigger()
returns trigger language plpgsql security definer set search_path to 'pg_catalog','public','app','pg_temp' as $$
declare v_result jsonb;v_status text;
begin
  if new.processing_status='processed' and old.processing_status is distinct from new.processing_status then
    begin
      v_result:=app.v156_prepare_billing_event(new.event_id);
      v_status:=case when v_result->>'status'='blocked' then 'blocked' when v_result->>'status' like 'ignored%' then 'ignored' else 'prepared' end;
      insert into public.platform_billing_event_preparations_v156(event_pk,event_id,status,reason,last_result,prepared_at)
      values(new.id,new.event_id,v_status,v_result->>'reason',v_result,case when v_status='prepared' then clock_timestamp() end)
      on conflict(event_id) do update set status=excluded.status,reason=excluded.reason,last_result=excluded.last_result,
        attempt_count=platform_billing_event_preparations_v156.attempt_count+1,last_attempt_at=clock_timestamp(),prepared_at=excluded.prepared_at;
    exception when others then
      insert into public.platform_billing_event_preparations_v156(event_pk,event_id,status,reason,last_result)
      values(new.id,new.event_id,'failed',sqlstate,jsonb_build_object('status','failed','sqlstate',sqlstate))
      on conflict(event_id) do update set status='failed',reason=sqlstate,last_result=excluded.last_result,
        attempt_count=platform_billing_event_preparations_v156.attempt_count+1,last_attempt_at=clock_timestamp();
      insert into public.platform_subscription_dispatch_audit_v156(action,entity_type,detail)
      values('billing_event_prepare_failed','stripe_event',jsonb_build_object('event_id',new.event_id,'sqlstate',sqlstate));
    end;
  end if;return new;
end $$;
revoke all on function app.v156_billing_event_trigger() from public,anon,authenticated;
create trigger zz_v156_billing_event after update of processing_status on public.billing_provider_events for each row execute function app.v156_billing_event_trigger();

create or replace function app.v156_replay_blocked_billing_events(p_limit integer default 100)
returns jsonb language plpgsql security definer set search_path to 'pg_catalog','public','app','pg_temp' as $$
declare r record;v_result jsonb;v_status text;v_prepared integer:=0;v_blocked integer:=0;v_failed integer:=0;
begin
  for r in select p.event_id from public.platform_billing_event_preparations_v156 p
    where p.status in ('blocked','failed') and p.last_attempt_at<=clock_timestamp()-interval '1 minute'
    order by p.last_attempt_at,p.event_id for update skip locked limit least(greatest(p_limit,1),500)
  loop
    begin
      v_result:=app.v156_prepare_billing_event(r.event_id);
      v_status:=case when v_result->>'status'='blocked' then 'blocked' when v_result->>'status' like 'ignored%' then 'ignored' else 'prepared' end;
      update public.platform_billing_event_preparations_v156 set status=v_status,reason=v_result->>'reason',last_result=v_result,
        attempt_count=attempt_count+1,last_attempt_at=clock_timestamp(),prepared_at=case when v_status='prepared' then clock_timestamp() end where event_id=r.event_id;
      if v_status='prepared' then v_prepared:=v_prepared+1;else v_blocked:=v_blocked+1;end if;
    exception when others then
      update public.platform_billing_event_preparations_v156 set status='failed',reason=sqlstate,last_result=jsonb_build_object('status','failed','sqlstate',sqlstate),attempt_count=attempt_count+1,last_attempt_at=clock_timestamp() where event_id=r.event_id;
      v_failed:=v_failed+1;
    end;
  end loop;
  return jsonb_build_object('prepared',v_prepared,'blocked_or_ignored',v_blocked,'failed',v_failed);
end $$;
revoke all on function app.v156_replay_blocked_billing_events(integer) from public,anon,authenticated;
grant execute on function app.v156_replay_blocked_billing_events(integer) to service_role;

create or replace function public.platform_generate_subscription_reminders_v156(p_as_of date default (clock_timestamp() at time zone 'Asia/Singapore')::date)
returns jsonb language plpgsql security definer set search_path to 'pg_catalog','public','app','pg_temp' as $$
declare r record;v_count integer:=0;v_day integer;v_prospect uuid;
begin
  if auth.uid() is not null and not app.v156_can('rw') then raise exception 'billing write access is required' using errcode='42501';end if;
  for r in select subscription.* from public.billing_provider_subscriptions subscription where subscription.status in ('active','trialing','past_due') loop
    select id into v_prospect from public.sme_prospects where converted_business_id=r.business_id order by converted_at desc nulls last limit 1;
    if r.status='past_due' then perform app.v156_upsert_task('past-due:'||r.provider_subscription_id,'past_due',r.business_id,v_prospect,r.provider_subscription_id,null,'urgent',p_as_of::timestamptz,'Subscription payment is past due',null);v_count:=v_count+1;end if;
    if r.cadence='annual' and r.current_period_end is not null then
      v_day:=((r.current_period_end at time zone 'Asia/Singapore')::date-p_as_of);
      if v_day in (30,14,7) then perform app.v156_upsert_task('renewal-'||v_day||':'||r.provider_subscription_id||':'||(r.current_period_end::date),'renewal_'||v_day,r.business_id,v_prospect,r.provider_subscription_id,null,case when v_day=7 then 'high' else 'normal' end,p_as_of::timestamptz,'Annual subscription renews in '||v_day||' days',null);v_count:=v_count+1;end if;
    end if;
  end loop;
  return jsonb_build_object('created_or_refreshed',v_count,'as_of',p_as_of);
end $$;

create or replace function public.platform_complete_subscription_task_v156(p_task uuid,p_resolution text,p_idempotency_key uuid)
returns jsonb language plpgsql security definer set search_path to 'pg_catalog','public','app','pg_temp' as $$
declare v_actor uuid:=auth.uid();v_task public.platform_subscription_tasks_v156%rowtype;
begin
  if v_actor is null or not app.v156_can('rw') then raise exception 'billing write access is required' using errcode='42501';end if;
  if length(btrim(coalesce(p_resolution,'')))<3 or p_idempotency_key is null then raise exception 'resolution is required' using errcode='22023';end if;
  update public.platform_subscription_tasks_v156 set status='completed',completed_at=clock_timestamp(),resolution=btrim(p_resolution),updated_at=clock_timestamp() where id=p_task and status='open' returning * into v_task;
  if not found then select * into v_task from public.platform_subscription_tasks_v156 where id=p_task;if not found then raise exception 'task was not found' using errcode='22023';end if;end if;
  insert into public.platform_subscription_dispatch_audit_v156(action,entity_type,entity_id,detail,actor) values('subscription_task_completed','task',p_task,jsonb_build_object('resolution',p_resolution,'operation_key',p_idempotency_key),v_actor);
  return jsonb_build_object('task',to_jsonb(v_task));
end $$;

create or replace function public.platform_get_subscription_operations_v156(p_search text default null,p_status text default null,p_limit integer default 250)
returns jsonb language plpgsql stable security definer set search_path to 'pg_catalog','public','app','pg_temp' as $$
declare v_profile public.platform_billing_profiles_v156%rowtype;
begin
  if auth.uid() is null or not app.v156_can('r') then raise exception 'billing read access is required' using errcode='42501';end if;
  if p_limit not between 1 and 500 then raise exception 'limit is invalid' using errcode='22023';end if;
  select * into v_profile from public.platform_billing_profiles_v156 order by version desc limit 1;
  return jsonb_build_object('profile',to_jsonb(v_profile)-'bank_account_number','bank_account_last4',right(v_profile.bank_account_number,4),'profile_ready',app.v156_profile_ready(v_profile),
    'summary',jsonb_build_object(
      'active',(select count(*) from public.billing_provider_subscriptions where status='active'),
      'new_this_month',(select count(*) from public.billing_provider_subscriptions where created_at>=date_trunc('month',clock_timestamp() at time zone 'Asia/Singapore')),
      'renewing_30',(select count(*) from public.billing_provider_subscriptions where status='active' and current_period_end::date between current_date and current_date+30),
      'renewing_14',(select count(*) from public.billing_provider_subscriptions where status='active' and current_period_end::date between current_date and current_date+14),
      'renewing_7',(select count(*) from public.billing_provider_subscriptions where status='active' and current_period_end::date between current_date and current_date+7),
      'payment_failed',(select count(*) from public.platform_subscription_tasks_v156 where status='open' and task_type='payment_failed'),
      'past_due',(select count(*) from public.billing_provider_subscriptions where status='past_due'),
      'cancel_at_period_end',(select count(*) from public.billing_provider_subscriptions where cancel_at_period_end),
      'cancelled_this_month',(select count(*) from public.billing_provider_subscriptions where status='canceled' and ended_at>=date_trunc('month',clock_timestamp() at time zone 'Asia/Singapore'))),
    'subscriptions',coalesce((select jsonb_agg(to_jsonb(rows) order by rows.next_renewal nulls last,rows.business_name) from (
      select business.id business_id,business.name business_name,subscription.provider_customer_id,subscription.provider_subscription_id,
        subscription.status canonical_status,subscription.cadence billing_interval,subscription.created_at subscription_created_at,
        subscription.current_period_start,subscription.current_period_end,
        case when paid_invoice.period_end is not null then (paid_invoice.period_end at time zone 'Asia/Singapore')::date-1 end paid_through,
        case when not subscription.cancel_at_period_end and subscription.status not in ('canceled') then subscription.current_period_end end next_renewal,
        case when subscription.cancel_at_period_end then subscription.current_period_end end scheduled_end,subscription.ended_at actual_end,
        subscription.cancel_at_period_end,subscription.trial_end,invoice.provider_invoice_id latest_invoice_id,invoice.number latest_invoice_number,
        invoice.status latest_invoice_status,invoice.paid_at latest_payment_at,invoice.amount_paid_cents latest_amount_paid_cents,
        contact.contact_name billing_contact_name,contact.email billing_email,prospect.assigned_consultant_id crm_owner,
        (select e.lifecycle_status from public.platform_subscription_lifecycle_events_v156 e where e.business_id=business.id order by e.occurred_at desc,e.id desc limit 1) lifecycle_status,
        (select count(*) from public.platform_subscription_tasks_v156 task where task.business_id=business.id and task.status='open') open_tasks,
        (select status from public.platform_subscription_deliveries_v156 delivery where delivery.business_id=business.id order by created_at desc limit 1) document_delivery_status
      from public.billing_provider_subscriptions subscription join public.businesses business on business.id=subscription.business_id
      left join lateral(select * from public.billing_provider_invoices i where i.provider_subscription_id=subscription.provider_subscription_id order by coalesce(i.paid_at,i.created_at) desc limit 1) invoice on true
      left join lateral(select * from public.billing_provider_invoices i where i.provider_subscription_id=subscription.provider_subscription_id and i.paid_normalized order by i.paid_at desc nulls last,i.created_at desc limit 1) paid_invoice on true
      left join public.platform_billing_contacts_v156 contact on contact.business_id=business.id and contact.active and contact.recipient_role='primary'
      left join public.sme_prospects prospect on prospect.converted_business_id=business.id
      where (p_search is null or business.name ilike '%'||p_search||'%' or subscription.provider_subscription_id ilike '%'||p_search||'%' or invoice.provider_invoice_id ilike '%'||p_search||'%')
        and (p_status is null or subscription.status=p_status
          or (p_status='renewing_30' and subscription.status='active' and subscription.current_period_end::date between current_date and current_date+30)
          or (p_status='renewing_14' and subscription.status='active' and subscription.current_period_end::date between current_date and current_date+14)
          or (p_status='renewing_7' and subscription.status='active' and subscription.current_period_end::date between current_date and current_date+7)
          or (p_status='payment_failed' and exists(select 1 from public.platform_subscription_tasks_v156 t where t.business_id=business.id and t.status='open' and t.task_type='payment_failed'))
          or (p_status='cancel_at_period_end' and subscription.cancel_at_period_end)) limit p_limit) rows),'[]'::jsonb),
    'tasks',coalesce((select jsonb_agg(to_jsonb(task) order by task.due_at,task.priority desc) from public.platform_subscription_tasks_v156 task where task.status='open'),'[]'::jsonb),
    'documents',coalesce((select jsonb_agg(to_jsonb(doc) order by doc.created_at desc) from (select d.id,d.document_type,d.document_number,d.business_id,d.prospect_id,d.provider_invoice_id,d.provider_subscription_id,d.issue_date,d.due_date,d.service_period_start,d.service_period_end,d.total_cents,d.amount_paid_cents,d.balance_due_cents,d.currency,d.finalized_at,d.created_at,
      (select e.status from public.platform_subscription_document_events_v156 e where e.document_id=d.id order by e.occurred_at desc,e.id desc limit 1) status,
      exists(select 1 from public.platform_subscription_document_files_v156 f where f.document_id=d.id) pdf_ready from public.platform_subscription_documents_v156 d order by d.created_at desc limit p_limit) doc),'[]'::jsonb),
    'deliveries',coalesce((select jsonb_agg(to_jsonb(delivery) order by created_at desc) from (select id,business_id,provider_invoice_id,delivery_type,status,attempt_count,failure_code,failure_reason,last_attempt_at,delivered_at,created_at from public.platform_subscription_deliveries_v156 order by created_at desc limit p_limit) delivery),'[]'::jsonb),
    'manual_payments',coalesce((select jsonb_agg(to_jsonb(payment) order by payment.created_at desc) from (select p.id,p.invoice_document_id,p.amount_cents,p.currency,p.payment_reference,p.value_date,p.bank_account_last4,p.status,p.recorded_by,p.verified_by,p.verified_at,p.rejection_reason,p.created_at,d.business_id,d.document_number from public.platform_manual_payments_v156 p join public.platform_subscription_documents_v156 d on d.id=p.invoice_document_id order by p.created_at desc limit p_limit) payment),'[]'::jsonb));
end $$;

create or replace function public.platform_get_crm_v156(p_search text default null,p_stage text default null,p_limit integer default 250)
returns jsonb language plpgsql stable security definer set search_path to 'pg_catalog','public','app','pg_temp' as $$
begin
  if auth.uid() is null or not (app.is_super_admin() or app.v89_platform_can('onboarding','r') or app.v89_platform_role()='sales_staff') then raise exception 'CRM read access is required' using errcode='42501';end if;
  return jsonb_build_object('stages',(select jsonb_agg(to_jsonb(stage) order by sort_order) from public.sme_pipeline_stages stage),
    'items',coalesce((select jsonb_agg(to_jsonb(row_data) order by row_data.updated_at desc) from (
      select prospect.id prospect_id,company.legal_name,company.trading_name,company.registration_number,prospect.current_stage_key,
        prospect.assigned_consultant_id,prospect.converted_business_id,prospect.stage_entered_at,prospect.next_action_at,prospect.updated_at,
        extract(day from clock_timestamp()-prospect.stage_entered_at)::integer days_in_stage,commercial.lead_source,commercial.expected_plan,
        commercial.billing_interval,commercial.expected_value_cents,commercial.expected_close_date,commercial.quotation_status,commercial.payment_link_status,
        contact.full_name primary_contact,contact.email primary_email,contact.phone primary_phone,
        (select max(a.occurred_at) from public.sme_prospect_activities a where a.prospect_id=prospect.id) last_activity,
        (select min(t.due_at) from public.sme_prospect_tasks t where t.prospect_id=prospect.id and t.status='open') next_follow_up,
        (select e.lifecycle_status from public.platform_subscription_lifecycle_events_v156 e where e.business_id=prospect.converted_business_id order by e.occurred_at desc limit 1) lifecycle_status
      from public.sme_prospects prospect join public.sme_companies company on company.id=prospect.company_id
      left join public.platform_crm_commercial_v156 commercial on commercial.prospect_id=prospect.id
      left join public.sme_prospect_contacts contact on contact.prospect_id=prospect.id and contact.active and contact.is_primary
      where (p_stage is null or prospect.current_stage_key=p_stage) and (p_search is null or company.legal_name ilike '%'||p_search||'%' or company.trading_name ilike '%'||p_search||'%' or company.registration_number ilike '%'||p_search||'%' or contact.email ilike '%'||p_search||'%' or contact.phone ilike '%'||p_search||'%')
        and (app.v89_platform_role()<>'sales_staff' or exists(select 1 from public.platform_consultants c where c.id=prospect.assigned_consultant_id and c.user_id=auth.uid() and c.active))
      order by prospect.updated_at desc limit p_limit) row_data),'[]'::jsonb));
end $$;

create or replace function public.platform_get_prospect_subscription_ops_v156(p_prospect uuid)
returns jsonb language plpgsql stable security definer set search_path to 'pg_catalog','public','app','pg_temp' as $$
begin
  if auth.uid() is null or not app.v156_can_prospect(p_prospect,'r') then raise exception 'CRM read access is required' using errcode='42501';end if;
  if not exists(select 1 from public.sme_prospects where id=p_prospect) then raise exception 'prospect was not found' using errcode='22023';end if;
  return jsonb_build_object(
    'commercial',(select to_jsonb(c) from public.platform_crm_commercial_v156 c where c.prospect_id=p_prospect),
    'billing_contacts',coalesce((select jsonb_agg(to_jsonb(c)-'created_by'-'updated_by' order by case c.recipient_role when 'primary' then 0 else 1 end,c.email) from public.platform_billing_contacts_v156 c where c.prospect_id=p_prospect and c.active),'[]'::jsonb),
    'documents',coalesce((select jsonb_agg(jsonb_build_object('id',d.id,'type',d.document_type,'number',d.document_number,'issue_date',d.issue_date,'expiry_date',d.expiry_date,'total_cents',d.total_cents,'currency',d.currency,'pdf_ready',exists(select 1 from public.platform_subscription_document_files_v156 f where f.document_id=d.id),'status',(select e.status from public.platform_subscription_document_events_v156 e where e.document_id=d.id order by e.occurred_at desc limit 1)) order by d.created_at desc) from public.platform_subscription_documents_v156 d where d.prospect_id=p_prospect),'[]'::jsonb),
    'deliveries',coalesce((select jsonb_agg(to_jsonb(d)-'recipients'-'cc_recipients' order by d.created_at desc) from public.platform_subscription_deliveries_v156 d where d.prospect_id=p_prospect),'[]'::jsonb));
end $$;

create or replace function public.platform_queue_document_resend_v156(p_delivery uuid,p_idempotency_key uuid)
returns jsonb language plpgsql security definer set search_path to 'pg_catalog','public','app','pg_temp' as $$
declare v_actor uuid:=auth.uid();v_source public.platform_subscription_deliveries_v156%rowtype;v_new public.platform_subscription_deliveries_v156%rowtype;
begin
  if v_actor is null or not app.v156_can('rw') then raise exception 'billing write access is required' using errcode='42501';end if;
  select * into v_source from public.platform_subscription_deliveries_v156 where id=p_delivery;if not found then raise exception 'delivery was not found' using errcode='22023';end if;
  insert into public.platform_subscription_deliveries_v156(delivery_key,business_id,prospect_id,provider_invoice_id,delivery_type,document_ids,recipients,cc_recipients,subject,manual_resend_by)
  values('resend:'||p_delivery||':'||p_idempotency_key,v_source.business_id,v_source.prospect_id,v_source.provider_invoice_id,'document_resend',v_source.document_ids,v_source.recipients,v_source.cc_recipients,v_source.subject,v_actor)
  on conflict(delivery_key) do update set updated_at=platform_subscription_deliveries_v156.updated_at returning * into v_new;
  insert into public.platform_subscription_dispatch_audit_v156(action,entity_type,entity_id,detail,actor) values('document_resend_queued','delivery',v_new.id,jsonb_build_object('source_delivery',p_delivery),v_actor);
  insert into public.platform_subscription_document_events_v156(document_id,status,source_type,source_id,actor)
  select document_id,case when d.document_type='receipt' then 'reissued_copy' else coalesce((select e.status from public.platform_subscription_document_events_v156 e where e.document_id=d.id order by e.occurred_at desc,e.id desc limit 1),'finalized') end,'admin','resend:'||v_new.id,v_actor
  from unnest(v_new.document_ids) document_id join public.platform_subscription_documents_v156 d on d.id=document_id on conflict do nothing;
  return jsonb_build_object('delivery',to_jsonb(v_new));
end $$;

create or replace function public.platform_void_document_v156(p_document uuid,p_reason text,p_idempotency_key uuid)
returns jsonb language plpgsql security definer set search_path to 'pg_catalog','public','app','pg_temp' as $$
declare v_actor uuid:=auth.uid();v_doc public.platform_subscription_documents_v156%rowtype;v_existing text;
begin
  if v_actor is null or not app.v156_can('rw') then raise exception 'billing write access is required' using errcode='42501';end if;
  if length(btrim(coalesce(p_reason,'')))<3 then raise exception 'void reason is required' using errcode='22023';end if;
  select * into v_doc from public.platform_subscription_documents_v156 where id=p_document for update;if not found then raise exception 'document was not found' using errcode='22023';end if;
  if v_doc.document_type not in ('quotation','invoice') or (v_doc.document_type='invoice' and v_doc.provider_invoice_id is not null) then raise exception 'Stripe invoices must be voided through Stripe' using errcode='42501';end if;
  select status into v_existing from public.platform_subscription_document_events_v156 where document_id=p_document order by occurred_at desc,id desc limit 1;
  if v_existing in ('paid','void','refunded','partially_refunded') then raise exception 'document cannot be voided in its current state' using errcode='22023';end if;
  insert into public.platform_subscription_document_events_v156(document_id,status,source_type,source_id,actor)
  values(p_document,case when v_doc.document_type='quotation' then 'superseded' else 'void' end,'admin',p_idempotency_key::text,v_actor) on conflict do nothing;
  insert into public.platform_subscription_dispatch_audit_v156(action,entity_type,entity_id,detail,actor) values('document_voided','document',p_document,jsonb_build_object('reason',btrim(p_reason),'document_number',v_doc.document_number),v_actor);
  return jsonb_build_object('document_id',p_document,'document_number',v_doc.document_number,'status',case when v_doc.document_type='quotation' then 'superseded' else 'void' end);
end $$;

create or replace function public.platform_request_document_read_v156(p_document uuid)
returns jsonb language plpgsql stable security definer set search_path to 'pg_catalog','public','app','pg_temp' as $$
declare v_file public.platform_subscription_document_files_v156%rowtype;v_prospect uuid;
begin
  select prospect_id into v_prospect from public.platform_subscription_documents_v156 where id=p_document;
  if auth.uid() is null or not (app.v156_can('r') or (v_prospect is not null and app.v156_can_prospect(v_prospect,'r'))) then raise exception 'document read access is required' using errcode='42501';end if;
  select * into v_file from public.platform_subscription_document_files_v156 where document_id=p_document order by revision desc limit 1;
  if not found then raise exception 'document PDF is not ready' using errcode='22023';end if;
  return jsonb_build_object('bucket_id',v_file.bucket_id,'object_path',v_file.object_path,'filename',(select document_number||'.pdf' from public.platform_subscription_documents_v156 where id=p_document),'expires_in',300);
end $$;

create or replace function public.v156_service_claim_dispatch(p_limit integer default 10)
returns jsonb language plpgsql security definer set search_path to 'pg_catalog','public','app','pg_temp' as $$
declare v_rows jsonb;
begin
  -- A crashed worker's lease expires after fifteen minutes.  Retryable rows
  -- become claimable only at next_attempt_at, preserving exponential backoff.
  with claimed as (select id from public.platform_subscription_deliveries_v156 where
      ((status in ('queued','retryable_failed') and next_attempt_at<=clock_timestamp())
       or (status='processing' and last_attempt_at<clock_timestamp()-interval '15 minutes'))
      order by next_attempt_at,id for update skip locked limit least(greatest(p_limit,1),25)),
  updated as (update public.platform_subscription_deliveries_v156 d set status='processing',attempt_count=attempt_count+1,last_attempt_at=clock_timestamp(),updated_at=clock_timestamp() from claimed where d.id=claimed.id returning d.*)
  select coalesce(jsonb_agg(jsonb_build_object('delivery',to_jsonb(updated),'documents',(select jsonb_agg(jsonb_build_object('id',doc.id,'business_id',doc.business_id,'prospect_id',doc.prospect_id,'number',doc.document_number,'type',doc.document_type,'snapshot',doc.snapshot,'snapshot_sha256',doc.snapshot_sha256,'template_version',doc.template_version,'file',(select to_jsonb(file) from public.platform_subscription_document_files_v156 file where file.document_id=doc.id order by revision desc limit 1)) order by doc.document_type) from public.platform_subscription_documents_v156 doc where doc.id=any(updated.document_ids)))),'[]'::jsonb) into v_rows from updated;
  return v_rows;
end $$;

create or replace function public.v156_service_record_document_file(p_document uuid,p_path text,p_size bigint,p_sha256 text,p_template text)
returns jsonb language plpgsql security definer set search_path to 'pg_catalog','public','app','pg_temp' as $$
declare v_row public.platform_subscription_document_files_v156%rowtype;v_business uuid;v_prospect uuid;v_revision integer;v_expected text;
begin
  select business_id,prospect_id into v_business,v_prospect from public.platform_subscription_documents_v156 where id=p_document and finalized_at is not null;if not found then raise exception 'finalized document was not found' using errcode='22023';end if;
  select coalesce(max(revision),0)+1 into v_revision from public.platform_subscription_document_files_v156 where document_id=p_document;
  v_expected:='platform-subscriptions/'||case when v_business is not null then 'businesses/'||v_business else 'prospects/'||v_prospect end||'/'||p_document||'/r'||v_revision||'.pdf';
  if p_path<>v_expected then raise exception 'document path is invalid' using errcode='22023';end if;
  insert into public.platform_subscription_document_files_v156(document_id,revision,object_path,size_bytes,sha256,template_version)
  values(p_document,v_revision,p_path,p_size,p_sha256,p_template) on conflict(document_id,revision) do update set document_id=excluded.document_id returning * into v_row;
  return to_jsonb(v_row);
end $$;

create or replace function public.v156_service_finish_delivery(p_delivery uuid,p_status text,p_provider_message_id text,p_failure_code text,p_failure_reason text)
returns jsonb language plpgsql security definer set search_path to 'pg_catalog','public','app','pg_temp' as $$
declare v_row public.platform_subscription_deliveries_v156%rowtype;
begin
  if p_status not in ('provider_accepted','delivered','retryable_failed','permanent_failed','provider_unconfigured') then raise exception 'delivery status is invalid' using errcode='22023';end if;
  update public.platform_subscription_deliveries_v156 set status=p_status,provider_message_id=nullif(btrim(p_provider_message_id),''),failure_code=nullif(btrim(p_failure_code),''),failure_reason=left(nullif(btrim(p_failure_reason),''),1000),
    delivered_at=case when p_status='delivered' then clock_timestamp() end,next_attempt_at=case when p_status='retryable_failed' then clock_timestamp()+make_interval(mins=>least(1440,5*(2^least(attempt_count,8)))) else next_attempt_at end,updated_at=clock_timestamp()
  where id=p_delivery and status='processing' returning * into v_row;if not found then raise exception 'processing delivery was not found' using errcode='22023';end if;
  if p_status in ('permanent_failed','provider_unconfigured') then perform app.v156_upsert_task('delivery-failed:'||p_delivery,'invoice_delivery_failed',v_row.business_id,null,null,v_row.provider_invoice_id,'high',clock_timestamp(),'Resolve failed billing document delivery',null);end if;
  if p_status in ('provider_accepted','delivered') and v_row.delivery_type='quotation' and v_row.prospect_id is not null then
    update public.platform_crm_commercial_v156 set quotation_status='sent',updated_at=clock_timestamp() where prospect_id=v_row.prospect_id;
    insert into public.platform_subscription_document_events_v156(document_id,status,source_type,source_id)
    select document_id,'sent','delivery',p_delivery::text from unnest(v_row.document_ids) document_id on conflict do nothing;
    insert into public.sme_prospect_activities(prospect_id,consultant_id,activity_type,summary,detail)
    select v_row.prospect_id,p.assigned_consultant_id,'document_sent','Quotation sent','delivery:'||p_delivery from public.sme_prospects p
    where p.id=v_row.prospect_id and not exists(select 1 from public.sme_prospect_activities a where a.prospect_id=v_row.prospect_id and a.activity_type='document_sent' and a.detail='delivery:'||p_delivery);
  end if;
  insert into public.platform_subscription_dispatch_audit_v156(action,entity_type,entity_id,detail) values('delivery_'||p_status,'delivery',p_delivery,jsonb_build_object('failure_code',p_failure_code,'provider_message_id',p_provider_message_id));
  return to_jsonb(v_row);
end $$;

create or replace function app.v156_run_subscription_automation()
returns jsonb language plpgsql security definer set search_path to 'pg_catalog','public','app','pg_temp' as $$
declare v_url text;v_secret text;v_request bigint;v_replay jsonb;v_reminders jsonb;
begin
  v_replay:=app.v156_replay_blocked_billing_events(100);
  v_reminders:=public.platform_generate_subscription_reminders_v156((clock_timestamp() at time zone 'Asia/Singapore')::date);
  if to_regnamespace('vault') is null or to_regnamespace('net') is null then
    return jsonb_build_object('replay',v_replay,'reminders',v_reminders,'dispatch','extensions_unavailable');
  end if;
  begin
    execute 'select decrypted_secret from vault.decrypted_secrets where name=$1 order by created_at desc limit 1' into v_url using 'v156_supabase_url';
    execute 'select decrypted_secret from vault.decrypted_secrets where name=$1 order by created_at desc limit 1' into v_secret using 'v156_dispatch_secret';
  exception when others then
    return jsonb_build_object('replay',v_replay,'reminders',v_reminders,'dispatch','vault_unavailable');
  end;
  if coalesce(v_url,'')='' or coalesce(v_secret,'')='' then
    return jsonb_build_object('replay',v_replay,'reminders',v_reminders,'dispatch','secret_unconfigured');
  end if;
  execute 'select net.http_post(url := $1, body := ''{}''::jsonb, headers := jsonb_build_object(''content-type'',''application/json'',''x-v156-dispatch-secret'',$2), timeout_milliseconds := 15000)'
    into v_request using rtrim(v_url,'/')||'/functions/v1/subscription-document-dispatch',v_secret;
  return jsonb_build_object('replay',v_replay,'reminders',v_reminders,'dispatch_request_id',v_request);
end $$;
revoke all on function app.v156_run_subscription_automation() from public,anon,authenticated;
grant execute on function app.v156_run_subscription_automation() to service_role;

insert into public.platform_billing_event_preparations_v156(event_pk,event_id,status,reason,last_result,last_attempt_at)
select e.id,e.event_id,'blocked','migration_backfill',jsonb_build_object('status','blocked','reason','migration_backfill'),clock_timestamp()-interval '2 minutes'
from public.billing_provider_events e where e.processing_status='processed' and (e.event_type like 'invoice.%' or e.event_type like 'customer.subscription.%')
on conflict(event_id) do nothing;

do $cron$
begin
  if to_regnamespace('cron') is not null and to_regprocedure('cron.schedule(text,text,text)') is not null then
    if exists(select 1 from cron.job where jobname='nestly-v156-subscription-automation') then perform cron.unschedule('nestly-v156-subscription-automation');end if;
    perform cron.schedule('nestly-v156-subscription-automation','*/5 * * * *',$command$select app.v156_run_subscription_automation()$command$);
  else
    raise notice 'v156: pg_cron is absent; subscription automation is not scheduled';
  end if;
end $cron$;

revoke all on function public.platform_set_billing_profile_v156(jsonb,uuid) from public,anon,authenticated;
revoke all on function public.platform_upsert_billing_contact_v156(jsonb,uuid) from public,anon,authenticated;
revoke all on function public.platform_save_crm_commercial_v156(uuid,jsonb,uuid) from public,anon,authenticated;
revoke all on function public.platform_link_checkout_command_v156(uuid,uuid,uuid) from public,anon,authenticated;
revoke all on function public.platform_finalize_quotation_v156(uuid,date,date,jsonb,text,uuid) from public,anon,authenticated;
revoke all on function public.platform_send_quotation_v156(uuid,uuid) from public,anon,authenticated;
revoke all on function public.platform_create_manual_invoice_v156(uuid,date,date,date,date,jsonb,bigint,uuid) from public,anon,authenticated;
revoke all on function public.platform_prepare_manual_evidence_upload_v156(uuid,text,text,uuid) from public,anon,authenticated;
revoke all on function public.platform_request_manual_evidence_read_v156(uuid) from public,anon,authenticated;
revoke all on function public.platform_record_manual_payment_v156(uuid,bigint,text,date,text,text,uuid) from public,anon,authenticated;
revoke all on function public.platform_verify_manual_payment_v156(uuid,text,text,uuid) from public,anon,authenticated;
revoke all on function public.platform_generate_subscription_reminders_v156(date) from public,anon,authenticated;
revoke all on function public.platform_complete_subscription_task_v156(uuid,text,uuid) from public,anon,authenticated;
revoke all on function public.platform_get_subscription_operations_v156(text,text,integer) from public,anon,authenticated;
revoke all on function public.platform_get_crm_v156(text,text,integer) from public,anon,authenticated;
revoke all on function public.platform_get_prospect_subscription_ops_v156(uuid) from public,anon,authenticated;
revoke all on function public.platform_queue_document_resend_v156(uuid,uuid) from public,anon,authenticated;
revoke all on function public.platform_void_document_v156(uuid,text,uuid) from public,anon,authenticated;
revoke all on function public.platform_request_document_read_v156(uuid) from public,anon,authenticated;
revoke all on function public.v156_service_claim_dispatch(integer) from public,anon,authenticated;
revoke all on function public.v156_service_record_document_file(uuid,text,bigint,text,text) from public,anon,authenticated;
revoke all on function public.v156_service_finish_delivery(uuid,text,text,text,text) from public,anon,authenticated;
grant execute on function public.platform_set_billing_profile_v156(jsonb,uuid) to authenticated;
grant execute on function public.platform_upsert_billing_contact_v156(jsonb,uuid) to authenticated;
grant execute on function public.platform_save_crm_commercial_v156(uuid,jsonb,uuid) to authenticated;
grant execute on function public.platform_link_checkout_command_v156(uuid,uuid,uuid) to authenticated;
grant execute on function public.platform_finalize_quotation_v156(uuid,date,date,jsonb,text,uuid) to authenticated;
grant execute on function public.platform_send_quotation_v156(uuid,uuid) to authenticated;
grant execute on function public.platform_create_manual_invoice_v156(uuid,date,date,date,date,jsonb,bigint,uuid) to authenticated;
grant execute on function public.platform_prepare_manual_evidence_upload_v156(uuid,text,text,uuid) to authenticated;
grant execute on function public.platform_request_manual_evidence_read_v156(uuid) to authenticated;
grant execute on function public.platform_record_manual_payment_v156(uuid,bigint,text,date,text,text,uuid) to authenticated;
grant execute on function public.platform_verify_manual_payment_v156(uuid,text,text,uuid) to authenticated;
grant execute on function public.platform_generate_subscription_reminders_v156(date) to authenticated;
grant execute on function public.platform_complete_subscription_task_v156(uuid,text,uuid) to authenticated;
grant execute on function public.platform_get_subscription_operations_v156(text,text,integer) to authenticated;
grant execute on function public.platform_get_crm_v156(text,text,integer) to authenticated;
grant execute on function public.platform_get_prospect_subscription_ops_v156(uuid) to authenticated;
grant execute on function public.platform_queue_document_resend_v156(uuid,uuid) to authenticated;
grant execute on function public.platform_void_document_v156(uuid,text,uuid) to authenticated;
grant execute on function public.platform_request_document_read_v156(uuid) to authenticated;
grant execute on function public.v156_service_claim_dispatch(integer) to service_role;
grant execute on function public.v156_service_record_document_file(uuid,text,bigint,text,text) to service_role;
grant execute on function public.v156_service_finish_delivery(uuid,text,text,text,text) to service_role;

commit;
