-- NESTLY v86 - ENTERPRISE SME CRM COMPLETION
--
-- Additive, backend-only completion of the v76/v79 SME operating model.
-- This migration creates versioned typed records, declarative stage evidence,
-- private-document signing seams, reviewable/reversible imports, weighted data
-- quality, and finite snapshot/keyset readers. It creates only the private,
-- constrained Storage bucket required by the signing seam; it does not create
-- browser Storage policies, upload an object, or change v76/v79 signatures.

begin;

-- ---------------------------------------------------------------------------
-- Typed, append-only extensions. Accepted/source facts are preserved by version
-- rather than overwritten in the v76 identity records.
-- ---------------------------------------------------------------------------

create table public.sme_company_profile_versions (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.sme_companies(id) on delete restrict,
  version integer not null check (version > 0),
  registration_country text check (registration_country is null or registration_country ~ '^[A-Z]{2}$'),
  entity_type text check (entity_type is null or entity_type in
    ('sole_proprietor','partnership','llp','private_limited','public_limited','charity_non_profit','other')),
  incorporated_on date,
  business_status text check (business_status is null or business_status in ('active','dormant','ceased','unknown')),
  registered_address text,
  operating_address text,
  postal_code text,
  country_code text check (country_code is null or country_code ~ '^[A-Z]{2}$'),
  region_state text,
  service_areas text[] not null default '{}',
  main_business_activity text,
  secondary_business_activities text[] not null default '{}',
  sub_industry text,
  business_description text,
  whatsapp_original text,
  whatsapp_e164 text check (whatsapp_e164 is null or whatsapp_e164 ~ '^\+[1-9][0-9]{7,14}$'),
  social_profiles jsonb not null default '{}'::jsonb check (jsonb_typeof(social_profiles)='object'),
  directory_profile_url text,
  directory_code text,
  public_rating numeric(3,2) check (public_rating is null or public_rating between 0 and 5),
  public_review_count integer check (public_review_count is null or public_review_count >= 0),
  rating_source text,
  employee_range text,
  expected_seats integer check (expected_seats is null or expected_seats > 0),
  location_count integer check (location_count is null or location_count > 0),
  years_in_business integer check (years_in_business is null or years_in_business >= 0),
  annual_revenue_band text,
  customer_type text check (customer_type is null or customer_type in ('b2b','b2c','both')),
  operating_model text,
  products_services text[] not null default '{}',
  monthly_volume integer check (monthly_volume is null or monthly_volume >= 0),
  seasonal_periods text[] not null default '{}',
  geographic_coverage text[] not null default '{}',
  internal_languages text[] not null default '{}',
  existing_tools text[] not null default '{}',
  existing_crm text,
  existing_accounting text,
  manual_workflows text,
  required_integrations text[] not null default '{}',
  migration_volume integer check (migration_volume is null or migration_volume >= 0),
  digital_maturity text check (digital_maturity is null or digital_maturity in ('low','medium','high')),
  technical_capability text,
  procurement_security_requirements text,
  regulatory_compliance_needs text,
  organisation_structure text,
  parent_company text,
  ownership_model text check (ownership_model is null or ownership_model in ('independent','franchise','group','other')),
  certifications text[] not null default '{}',
  current_competitors text[] not null default '{}',
  verification_status text not null default 'unverified'
    check (verification_status in ('unverified','source_only','confirmed','rejected','expired')),
  verified_at timestamptz,
  verification_notes text,
  source_name text,
  source_url text,
  source_value jsonb not null default '{}'::jsonb check (jsonb_typeof(source_value)='object'),
  captured_at timestamptz,
  confirmed_value jsonb not null default '{}'::jsonb check (jsonb_typeof(confirmed_value)='object'),
  confirmed_by uuid references auth.users(id) on delete set null,
  confirmed_at timestamptz,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  unique(company_id,version),
  constraint sme_company_profile_confirmation_shape check (
    (confirmed_at is null and confirmed_by is null)
    or (confirmed_at is not null and confirmed_by is not null)
  )
);

create table public.sme_contact_profile_versions (
  id uuid primary key default gen_random_uuid(),
  contact_id uuid not null references public.sme_prospect_contacts(id) on delete restrict,
  version integer not null check (version > 0),
  preferred_name text,
  department_function text,
  decision_role text check (decision_role is null or decision_role in
    ('decision_maker','champion','influencer','finance','it','operations','user','gatekeeper')),
  decision_authority_level text,
  mobile_original text,
  mobile_e164 text check (mobile_e164 is null or mobile_e164 ~ '^\+[1-9][0-9]{7,14}$'),
  office_phone_original text,
  office_phone_e164 text check (office_phone_e164 is null or office_phone_e164 ~ '^\+[1-9][0-9]{7,14}$'),
  whatsapp_original text,
  whatsapp_e164 text check (whatsapp_e164 is null or whatsapp_e164 ~ '^\+[1-9][0-9]{7,14}$'),
  preferred_channel text check (preferred_channel is null or preferred_channel in
    ('phone','sms','whatsapp','email','video','in_person')),
  preferred_language text,
  timezone text,
  contact_hours text,
  profile_url text,
  is_billing_contact boolean not null default false,
  is_technical_admin boolean not null default false,
  is_authorised_signatory boolean not null default false,
  consent_basis text,
  marketing_opt_in boolean not null default false,
  opted_in_at timestamptz,
  opt_in_source text,
  do_not_contact boolean not null default false,
  last_contacted_at timestamptz,
  next_follow_up_at timestamptz,
  notes text,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  unique(contact_id,version),
  constraint sme_contact_opt_in_shape check (
    not marketing_opt_in or (opted_in_at is not null and length(btrim(coalesce(opt_in_source,''))) >= 2)
  )
);

create index sme_contact_email_normalized_v86_idx
  on public.sme_prospect_contacts(lower(btrim(email)))
  where email is not null and length(btrim(email)) > 0;
create index sme_contact_mobile_e164_v86_idx
  on public.sme_contact_profile_versions(mobile_e164)
  where mobile_e164 is not null;

create table public.sme_qualification_detail_versions (
  id uuid primary key default gen_random_uuid(),
  prospect_id uuid not null references public.sme_prospects(id) on delete restrict,
  version integer not null check (version > 0),
  primary_problem text,
  why_change text,
  existing_workflow text,
  current_tool_vendor text,
  pain_points text[] not null default '{}',
  consequence_of_inaction text,
  desired_outcome text,
  required_features text[] not null default '{}',
  nice_to_have_features text[] not null default '{}',
  success_criteria text[] not null default '{}',
  expected_user_count integer check (expected_user_count is null or expected_user_count > 0),
  expected_usage_volume integer check (expected_usage_volume is null or expected_usage_volume >= 0),
  required_integrations text[] not null default '{}',
  required_migration text,
  security_requirements text[] not null default '{}',
  compliance_requirements text[] not null default '{}',
  decision_maker_contact_id uuid references public.sme_prospect_contacts(id) on delete restrict,
  champion_contact_id uuid references public.sme_prospect_contacts(id) on delete restrict,
  budget_owner_contact_id uuid references public.sme_prospect_contacts(id) on delete restrict,
  budget_status text check (budget_status is null or budget_status in
    ('unknown','allocated','requested','approved','insufficient')),
  budget_min_cents bigint check (budget_min_cents is null or budget_min_cents >= 0),
  budget_max_cents bigint check (budget_max_cents is null or budget_max_cents >= 0),
  expected_subscription_cents bigint check (expected_subscription_cents is null or expected_subscription_cents >= 0),
  expected_setup_fee_cents bigint check (expected_setup_fee_cents is null or expected_setup_fee_cents >= 0),
  purchase_timeframe text,
  target_go_live date,
  procurement_process text,
  legal_review_required boolean not null default false,
  security_review_required boolean not null default false,
  competitors_considered text[] not null default '{}',
  decision_criteria text[] not null default '{}',
  decision_date date,
  main_objection text,
  risk_level text check (risk_level is null or risk_level in ('low','medium','high','blocked')),
  fit_score smallint check (fit_score is null or fit_score between 0 and 100),
  intent_score smallint check (intent_score is null or intent_score between 0 and 100),
  qualification_status text check (qualification_status is null or qualification_status in
    ('unqualified','discovery','qualified','disqualified','won')),
  disqualification_reason text,
  system_suggested_score smallint check (system_suggested_score is null or system_suggested_score between 0 and 100),
  score_reasons text[] not null default '{}',
  human_confirmed_score smallint check (human_confirmed_score is null or human_confirmed_score between 0 and 100),
  confirmed_by uuid references auth.users(id) on delete set null,
  confirmed_at timestamptz,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  unique(prospect_id,version),
  constraint sme_qualification_budget_shape check (
    budget_min_cents is null or budget_max_cents is null or budget_min_cents <= budget_max_cents
  ),
  constraint sme_qualification_human_confirmation_shape check (
    (human_confirmed_score is null and confirmed_by is null and confirmed_at is null)
    or (human_confirmed_score is not null and confirmed_by is not null and confirmed_at is not null)
  )
);

create table public.sme_activity_detail_versions (
  id uuid primary key default gen_random_uuid(),
  activity_id uuid not null references public.sme_prospect_activities(id) on delete restrict,
  version integer not null check (version > 0),
  contact_id uuid references public.sme_prospect_contacts(id) on delete restrict,
  outcome text,
  disposition text,
  duration_seconds integer check (duration_seconds is null or duration_seconds >= 0),
  direction text check (direction is null or direction in ('inbound','outbound','internal')),
  channel text check (channel is null or channel in
    ('phone','sms','whatsapp','email','video','in_person','system','other')),
  next_action text,
  next_action_owner uuid references auth.users(id) on delete set null,
  next_action_due_at timestamptz,
  meeting_at timestamptz,
  meeting_url text,
  meeting_location text,
  calendar_event_id text,
  recording_transcript_url text,
  attachments jsonb not null default '[]'::jsonb check (jsonb_typeof(attachments)='array'),
  created_source text not null default 'manual'
    check (created_source in ('manual','integration','automation','import')),
  supersedes_activity_id uuid references public.sme_prospect_activities(id) on delete restrict,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  unique(activity_id,version)
);

create table public.sme_commercial_detail_versions (
  id uuid primary key default gen_random_uuid(),
  commercial_terms_id uuid not null references public.sme_commercial_terms(id) on delete restrict,
  version integer not null check (version > 0),
  unit_price_cents bigint check (unit_price_cents is null or unit_price_cents >= 0),
  discount_basis_points integer check (discount_basis_points is null or discount_basis_points between 0 and 10000),
  discount_reason text,
  discount_approved_by uuid references auth.users(id) on delete set null,
  tax_treatment text check (tax_treatment is null or tax_treatment in ('exclusive','inclusive','exempt','out_of_scope')),
  setup_fee_cents bigint check (setup_fee_cents is null or setup_fee_cents >= 0),
  contract_term_months integer check (contract_term_months is null or contract_term_months > 0),
  trial_starts_on date,
  trial_ends_on date,
  subscription_starts_on date,
  subscription_ends_on date,
  renewal_on date,
  payment_terms_days integer check (payment_terms_days is null or payment_terms_days >= 0),
  proposal_version text,
  proposal_sent_at timestamptz,
  proposal_expires_at timestamptz,
  contract_sent_at timestamptz,
  contract_signed_at timestamptz,
  signatory_contact_id uuid references public.sme_prospect_contacts(id) on delete restrict,
  purchase_order_required boolean not null default false,
  purchase_order_number text,
  subscription_status text,
  payment_status text,
  first_payment_at timestamptz,
  amount_collected_cents bigint check (amount_collected_cents is null or amount_collected_cents >= 0),
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  unique(commercial_terms_id,version),
  constraint sme_commercial_trial_shape check (
    trial_starts_on is null or trial_ends_on is null or trial_starts_on <= trial_ends_on
  )
);

create table public.sme_conversion_configuration_versions (
  id uuid primary key default gen_random_uuid(),
  prospect_id uuid not null references public.sme_prospects(id) on delete restrict,
  version integer not null check (version > 0),
  workspace_name text,
  legal_name text,
  registration_number text,
  workspace_slug text,
  primary_owner_contact_id uuid references public.sme_prospect_contacts(id) on delete restrict,
  owner_email text,
  owner_phone text,
  administrator_emails text[] not null default '{}',
  team_member_emails text[] not null default '{}',
  role_template_key text,
  seat_limit integer check (seat_limit is null or seat_limit > 0),
  plan_code text,
  billing_cycle text check (billing_cycle is null or billing_cycle in ('quarterly','half_yearly','annual')),
  trial_starts_on date,
  trial_ends_on date,
  billing_contact_id uuid references public.sme_prospect_contacts(id) on delete restrict,
  invoice_address text,
  gst_registration_number text,
  invoice_prefix text,
  currency text check (currency is null or currency ~ '^[A-Z]{3}$'),
  timezone text,
  locale text,
  date_format text,
  logo_document_id uuid,
  brand_primary_color text check (brand_primary_color is null or brand_primary_color ~ '^#[0-9A-Fa-f]{6}$'),
  brand_secondary_color text check (brand_secondary_color is null or brand_secondary_color ~ '^#[0-9A-Fa-f]{6}$'),
  sender_name text,
  welcome_message text,
  custom_domain text,
  default_terms_document_id uuid,
  payment_instructions_masked text,
  workflow_template_key text,
  notification_preferences jsonb not null default '{}'::jsonb check (jsonb_typeof(notification_preferences)='object'),
  required_integrations text[] not null default '{}',
  data_import_status text check (data_import_status is null or data_import_status in
    ('not_required','not_started','in_progress','completed','blocked')),
  security_policy text,
  require_two_factor boolean not null default false,
  retention_policy_days integer check (retention_policy_days is null or retention_policy_days > 0),
  support_owner uuid references auth.users(id) on delete set null,
  customer_success_consultant_id uuid references public.platform_consultants(id) on delete restrict,
  target_go_live date,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  unique(prospect_id,version)
);

-- ---------------------------------------------------------------------------
-- Declarative stage-entry catalogue and immutable transition evidence.
-- System-managed v79 stages remain system-managed.
-- ---------------------------------------------------------------------------

create table public.sme_stage_entry_requirements (
  stage_key text primary key references public.sme_pipeline_stages(stage_key) on delete restrict,
  evidence_schema_version integer not null default 1 check (evidence_schema_version > 0),
  required_keys text[] not null,
  system_managed boolean not null default false,
  terminal_confirmation boolean not null default false,
  description text not null,
  updated_at timestamptz not null default now()
);

insert into public.sme_stage_entry_requirements(
  stage_key,required_keys,system_managed,terminal_confirmation,description
) values
  ('new_lead',array['source'],false,false,'Company name or registration number, source and created timestamp'),
  ('appt_set',array['appointment_at','appointment_owner','next_action_at'],false,false,'Primary contact, valid channel and appointment'),
  ('npu_1',array['attempt_at','channel'],false,false,'Automatic NPU attempt and next attempt or terminal disposition'),
  ('npu_2',array['attempt_at','channel'],false,false,'Automatic NPU attempt and next attempt or terminal disposition'),
  ('npu_3',array['attempt_at','channel'],false,false,'Automatic NPU attempt and next attempt or terminal disposition'),
  ('npu_4',array['attempt_at','channel'],false,false,'Automatic NPU attempt and next attempt or terminal disposition'),
  ('npu_5',array['attempt_at','channel'],false,false,'Automatic NPU attempt and next attempt or terminal disposition'),
  ('npu_6',array['attempt_at','channel'],false,false,'Automatic NPU attempt and next attempt or terminal disposition'),
  ('call_back',array['callback_at','assigned_person','context'],false,false,'Callback time, assignee and context'),
  ('reschedule',array['previous_meeting_reference','new_meeting_at','reschedule_reason'],false,false,'Previous meeting, new time and reason'),
  ('meeting_sent',array['meeting_at','meeting_channel','attendees'],false,false,'Confirmed time, channel/location, attendees and meeting reference'),
  ('pending_decision',array['qualification_summary','decision_maker','key_objection','proposed_plan','proposed_value_cents','next_action_at'],false,false,'Decision context and next action'),
  ('client',array['explicit_confirmation'],false,true,'Accepted commercial snapshot and explicit confirmation'),
  ('account_created',array['conversion_id'],true,false,'Transactional v79 conversion evidence'),
  ('onboarding',array['checklist_id'],true,false,'Evidence-backed v79 onboarding checklist'),
  ('activated',array['activation_event_id'],true,true,'Evidence-backed v79 activation'),
  ('lost',array['reason_code','context','recontact_permission'],false,true,'Structured loss evidence and recontact ruling');

create table public.sme_stage_entry_evidence (
  id uuid primary key default gen_random_uuid(),
  prospect_id uuid not null references public.sme_prospects(id) on delete restrict,
  stage_key text not null references public.sme_stage_entry_requirements(stage_key) on delete restrict,
  prospect_version bigint not null check (prospect_version > 0),
  schema_version integer not null check (schema_version > 0),
  evidence jsonb not null check (jsonb_typeof(evidence)='object'),
  actor uuid not null references auth.users(id) on delete restrict,
  created_at timestamptz not null default now(),
  unique(prospect_id,prospect_version,stage_key)
);
create index sme_stage_entry_evidence_timeline_idx
  on public.sme_stage_entry_evidence(prospect_id,created_at desc,id desc);

-- ---------------------------------------------------------------------------
-- Private-document metadata and short-lived signing-request seams.
-- This is runtime infrastructure only: no object is uploaded and no browser
-- policy is installed. All object operations remain in the trusted signer.
-- ---------------------------------------------------------------------------

insert into storage.buckets as bucket(
  id,name,public,file_size_limit,allowed_mime_types
) values(
  'sme-private','sme-private',false,26214400,
  array[
    'application/pdf','text/csv',
    'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
    'image/png','image/jpeg','image/webp','application/zip'
  ]::text[]
)
on conflict(id) do update set
  name=excluded.name,
  public=false,
  file_size_limit=excluded.file_size_limit,
  allowed_mime_types=excluded.allowed_mime_types;

create table public.sme_document_versions (
  id uuid primary key default gen_random_uuid(),
  logical_document_id uuid not null,
  version integer not null check (version > 0),
  prospect_id uuid not null references public.sme_prospects(id) on delete restrict,
  company_id uuid references public.sme_companies(id) on delete restrict,
  contact_id uuid references public.sme_prospect_contacts(id) on delete restrict,
  document_type text not null check (document_type in
    ('company_registration','company_profile','accreditation','proposal','signed_agreement',
     'purchase_order','data_processing_agreement','security_questionnaire','migration_template',
     'price_catalogue','branding_asset','implementation_note','other')),
  original_filename text not null check (length(btrim(original_filename)) between 1 and 240),
  bucket_id text not null default 'sme-private' check (bucket_id='sme-private'),
  object_path text not null unique check (object_path ~ '^prospects/[0-9a-f-]{36}/[0-9a-f-]{36}/v[0-9]+/[^/]+$'),
  mime_type text not null check (mime_type in
    ('application/pdf','text/csv','application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
     'image/png','image/jpeg','image/webp','application/zip')),
  size_bytes bigint not null check (size_bytes between 1 and 26214400),
  sha256 text check (sha256 is null or sha256 ~ '^[0-9a-f]{64}$'),
  status text not null check (status in ('reserved','uploaded','verified','rejected','expired','superseded')),
  expires_on date,
  verification_status text not null default 'pending'
    check (verification_status in ('pending','verified','rejected','not_required')),
  verified_by uuid references auth.users(id) on delete set null,
  verified_at timestamptz,
  notes text,
  uploaded_by uuid references auth.users(id) on delete set null,
  uploaded_at timestamptz,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  unique(logical_document_id,version),
  constraint sme_document_verification_shape check (
    verification_status<>'verified' or (verified_by is not null and verified_at is not null)
  )
);
create index sme_document_versions_prospect_idx
  on public.sme_document_versions(prospect_id,created_at desc,id desc);

create table public.sme_document_signing_requests (
  id uuid primary key default gen_random_uuid(),
  document_version_id uuid not null references public.sme_document_versions(id) on delete restrict,
  purpose text not null check (purpose in ('upload','read')),
  token_hash text not null unique check (token_hash ~ '^[0-9a-f]{64}$'),
  requested_by uuid not null references auth.users(id) on delete restrict,
  expires_at timestamptz not null,
  consumed_at timestamptz,
  created_at timestamptz not null default now(),
  constraint sme_document_signing_expiry_check check (expires_at > created_at)
);
create index sme_document_signing_requests_expiry_idx
  on public.sme_document_signing_requests(expires_at) where consumed_at is null;

-- ---------------------------------------------------------------------------
-- Import mappings, decisions, dedupe review and reversible commit provenance.
-- ---------------------------------------------------------------------------

create table public.sme_import_field_definitions (
  canonical_field text primary key check (canonical_field ~ '^[a-z][a-z0-9_]*$'),
  label text not null,
  data_type text not null check (data_type in ('text','email','phone','url','integer','postal_code','stage')),
  single_value boolean not null default true,
  required boolean not null default false,
  synonyms text[] not null,
  sort_order integer not null unique check (sort_order > 0)
);

insert into public.sme_import_field_definitions(
  canonical_field,label,data_type,single_value,required,synonyms,sort_order
) values
  ('company_name','Company name','text',true,true,array['company name','company','firm','legal name'],1),
  ('contact_name','Contact name','text',true,false,array['contact name','contact person'],2),
  ('job_title','Job title','text',true,false,array['job title','designation'],3),
  ('phone','Phone','phone',false,false,array['phone','mobile','contact number','tel'],4),
  ('email','Email','email',true,false,array['email','email address'],5),
  ('address','Registered address','text',true,false,array['address','registered address'],6),
  ('postal_code','Postal code','postal_code',true,false,array['postal code','postal','zip'],7),
  ('registration_number','Registration number','text',true,false,array['uen','registration number','entity number'],8),
  ('directory_code','Directory code','text',true,false,array['directory code'],9),
  ('rating','Public rating','text',true,false,array['rating','star rating'],10),
  ('review_count','Review count','integer',true,false,array['reviews','review count'],11),
  ('region','Region','text',true,false,array['region','area','zone'],12),
  ('website','Website','url',true,false,array['website'],13),
  ('industry','Industry','text',true,false,array['industry'],14),
  ('employee_count','Employee count','integer',true,false,array['employee count','headcount','team size'],15),
  ('notes','Notes','text',true,false,array['notes','remarks'],16),
  ('stage','Stage','stage',true,false,array['stage','status','pipeline stage'],17);

create table public.sme_import_column_mappings (
  batch_id uuid not null references public.sme_prospect_import_batches(id) on delete restrict,
  source_header text not null,
  canonical_field text references public.sme_import_field_definitions(canonical_field) on delete restrict,
  custom_label text,
  confidence numeric(4,3) not null default 1 check (confidence between 0 and 1),
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  primary key(batch_id,source_header),
  constraint sme_import_mapping_target_check check (
    canonical_field is not null or length(btrim(coalesce(custom_label,''))) >= 2
  )
);
create unique index sme_import_single_value_mapping_uk
  on public.sme_import_column_mappings(batch_id,canonical_field)
  where canonical_field is not null;

create table public.sme_import_dedupe_candidates (
  import_row_id uuid not null references public.sme_prospect_import_rows(id) on delete restrict,
  candidate_prospect_id uuid not null references public.sme_prospects(id) on delete restrict,
  match_basis text not null check (match_basis in
    ('registration_number','domain','email','phone','company_name_postal','similar_name')),
  score numeric(5,2) not null check (score between 0 and 100),
  evidence jsonb not null default '{}'::jsonb check (jsonb_typeof(evidence)='object'),
  created_at timestamptz not null default now(),
  primary key(import_row_id,candidate_prospect_id,match_basis)
);

create table public.sme_import_row_decision_versions (
  id uuid primary key default gen_random_uuid(),
  import_row_id uuid not null references public.sme_prospect_import_rows(id) on delete restrict,
  version integer not null check (version > 0),
  decision text not null check (decision in ('insert','skip','merge','review')),
  candidate_prospect_id uuid references public.sme_prospects(id) on delete restrict,
  reason text,
  decided_by uuid references auth.users(id) on delete set null,
  decided_at timestamptz not null default now(),
  unique(import_row_id,version),
  constraint sme_import_row_merge_shape check (
    decision<>'merge' or candidate_prospect_id is not null
  )
);

create table public.sme_import_commit_ledger (
  id uuid primary key default gen_random_uuid(),
  batch_id uuid not null references public.sme_prospect_import_batches(id) on delete restrict,
  import_row_id uuid not null unique references public.sme_prospect_import_rows(id) on delete restrict,
  decision text not null check (decision in ('insert','merge')),
  prospect_id uuid not null references public.sme_prospects(id) on delete restrict,
  company_id uuid references public.sme_companies(id) on delete restrict,
  source_lineage_id uuid references public.sme_prospect_source_lineage(id) on delete restrict,
  prospect_version_at_commit bigint not null check (prospect_version_at_commit > 0),
  committed_by uuid references auth.users(id) on delete set null,
  committed_at timestamptz not null default now()
);

create table public.sme_import_batch_reversals (
  batch_id uuid primary key references public.sme_prospect_import_batches(id) on delete restrict,
  reversed_by uuid references auth.users(id) on delete set null,
  reversed_at timestamptz not null default now(),
  reason text not null check (length(btrim(reason)) between 2 and 1000),
  reversed_insert_rows integer not null check (reversed_insert_rows >= 0),
  unlinked_merge_rows integer not null check (unlinked_merge_rows >= 0)
);

create table public.sme_import_reversal_rows (
  batch_id uuid not null references public.sme_prospect_import_batches(id) on delete restrict,
  import_row_id uuid not null references public.sme_prospect_import_rows(id) on delete restrict,
  prior_decision text not null check (prior_decision in ('insert','merge')),
  prior_prospect_id uuid not null,
  prior_company_id uuid,
  prior_source_lineage_id uuid,
  reversed_at timestamptz not null default now(),
  primary key(batch_id,import_row_id)
);

-- ---------------------------------------------------------------------------
-- Weighted data-quality rules and immutable snapshots.
-- ---------------------------------------------------------------------------

create table public.sme_data_quality_rule_versions (
  id uuid primary key default gen_random_uuid(),
  rule_key text not null check (rule_key ~ '^[a-z][a-z0-9_]*$'),
  version integer not null check (version > 0),
  label text not null,
  weight smallint not null check (weight between 0 and 100),
  severity text not null check (severity in ('info','warning','blocking')),
  active boolean not null default true,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  unique(rule_key,version)
);

insert into public.sme_data_quality_rule_versions(rule_key,version,label,weight,severity) values
  ('company_name',1,'Company name',15,'blocking'),
  ('registration_or_domain',1,'Registration number or verified domain',15,'warning'),
  ('primary_contact',1,'Primary contact',15,'blocking'),
  ('valid_contact_method',1,'Valid contact method',10,'blocking'),
  ('source_attribution',1,'Source attribution',10,'warning'),
  ('assigned_owner',1,'Assigned owner',10,'warning'),
  ('contact_basis',1,'Consent or contact basis',5,'warning'),
  ('next_action',1,'Next action',5,'warning'),
  ('recent_activity',1,'Recent activity',5,'warning'),
  ('qualification',1,'Qualification evidence',5,'info'),
  ('commercial_context',1,'Commercial context',5,'info');

create table public.sme_data_quality_snapshots (
  id uuid primary key default gen_random_uuid(),
  prospect_id uuid not null references public.sme_prospects(id) on delete restrict,
  score smallint not null check (score between 0 and 100),
  earned_weight smallint not null check (earned_weight between 0 and 100),
  total_weight smallint not null check (total_weight between 1 and 100),
  rule_results jsonb not null check (jsonb_typeof(rule_results)='array'),
  duplicate_flags jsonb not null default '[]'::jsonb check (jsonb_typeof(duplicate_flags)='array'),
  evaluated_at timestamptz not null default now(),
  evaluated_by uuid references auth.users(id) on delete set null
);
create index sme_data_quality_snapshots_latest_idx
  on public.sme_data_quality_snapshots(prospect_id,evaluated_at desc,id desc);

-- Every exposed table is deny-by-default. Browser access is only through the
-- finite reviewed functions below.
alter table public.sme_company_profile_versions enable row level security;
alter table public.sme_contact_profile_versions enable row level security;
alter table public.sme_qualification_detail_versions enable row level security;
alter table public.sme_activity_detail_versions enable row level security;
alter table public.sme_commercial_detail_versions enable row level security;
alter table public.sme_conversion_configuration_versions enable row level security;
alter table public.sme_stage_entry_requirements enable row level security;
alter table public.sme_stage_entry_evidence enable row level security;
alter table public.sme_document_versions enable row level security;
alter table public.sme_document_signing_requests enable row level security;
alter table public.sme_import_field_definitions enable row level security;
alter table public.sme_import_column_mappings enable row level security;
alter table public.sme_import_dedupe_candidates enable row level security;
alter table public.sme_import_row_decision_versions enable row level security;
alter table public.sme_import_commit_ledger enable row level security;
alter table public.sme_import_batch_reversals enable row level security;
alter table public.sme_import_reversal_rows enable row level security;
alter table public.sme_data_quality_rule_versions enable row level security;
alter table public.sme_data_quality_snapshots enable row level security;

revoke all privileges on table public.sme_company_profile_versions from public,anon,authenticated;
revoke all privileges on table public.sme_contact_profile_versions from public,anon,authenticated;
revoke all privileges on table public.sme_qualification_detail_versions from public,anon,authenticated;
revoke all privileges on table public.sme_activity_detail_versions from public,anon,authenticated;
revoke all privileges on table public.sme_commercial_detail_versions from public,anon,authenticated;
revoke all privileges on table public.sme_conversion_configuration_versions from public,anon,authenticated;
revoke all privileges on table public.sme_stage_entry_requirements from public,anon,authenticated;
revoke all privileges on table public.sme_stage_entry_evidence from public,anon,authenticated;
revoke all privileges on table public.sme_document_versions from public,anon,authenticated;
revoke all privileges on table public.sme_document_signing_requests from public,anon,authenticated;
revoke all privileges on table public.sme_import_field_definitions from public,anon,authenticated;
revoke all privileges on table public.sme_import_column_mappings from public,anon,authenticated;
revoke all privileges on table public.sme_import_dedupe_candidates from public,anon,authenticated;
revoke all privileges on table public.sme_import_row_decision_versions from public,anon,authenticated;
revoke all privileges on table public.sme_import_commit_ledger from public,anon,authenticated;
revoke all privileges on table public.sme_import_batch_reversals from public,anon,authenticated;
revoke all privileges on table public.sme_import_reversal_rows from public,anon,authenticated;
revoke all privileges on table public.sme_data_quality_rule_versions from public,anon,authenticated;
revoke all privileges on table public.sme_data_quality_snapshots from public,anon,authenticated;

create trigger sme_company_profile_versions_immutable_v86
  before update or delete on public.sme_company_profile_versions
  for each row execute function app.v75_immutable_guard();
create trigger sme_contact_profile_versions_immutable_v86
  before update or delete on public.sme_contact_profile_versions
  for each row execute function app.v75_immutable_guard();
create trigger sme_qualification_detail_versions_immutable_v86
  before update or delete on public.sme_qualification_detail_versions
  for each row execute function app.v75_immutable_guard();
create trigger sme_activity_detail_versions_immutable_v86
  before update or delete on public.sme_activity_detail_versions
  for each row execute function app.v75_immutable_guard();
create trigger sme_commercial_detail_versions_immutable_v86
  before update or delete on public.sme_commercial_detail_versions
  for each row execute function app.v75_immutable_guard();
create trigger sme_conversion_configuration_versions_immutable_v86
  before update or delete on public.sme_conversion_configuration_versions
  for each row execute function app.v75_immutable_guard();
create trigger sme_stage_entry_evidence_immutable_v86
  before update or delete on public.sme_stage_entry_evidence
  for each row execute function app.v75_immutable_guard();
create trigger sme_import_row_decisions_immutable_v86
  before update or delete on public.sme_import_row_decision_versions
  for each row execute function app.v75_immutable_guard();
create trigger sme_data_quality_rules_immutable_v86
  before update or delete on public.sme_data_quality_rule_versions
  for each row execute function app.v75_immutable_guard();
create trigger sme_data_quality_snapshots_immutable_v86
  before update or delete on public.sme_data_quality_snapshots
  for each row execute function app.v75_immutable_guard();

-- ---------------------------------------------------------------------------
-- Shared validation/authorization helpers.
-- ---------------------------------------------------------------------------

create or replace function app.v86_assert_object_keys(
  p_value jsonb,p_allowed text[],p_label text
) returns void
language plpgsql immutable
set search_path to 'pg_catalog','pg_temp'
as $$
declare v_unknown text[];
begin
  if p_value is null or jsonb_typeof(p_value)<>'object' then
    raise exception '% must be an object',p_label using errcode='22023';
  end if;
  select array_agg(key order by key) into v_unknown
    from jsonb_object_keys(p_value) key where not (key=any(p_allowed));
  if cardinality(v_unknown)>0 then
    raise exception 'unsupported % fields: %',p_label,array_to_string(v_unknown,', ')
      using errcode='22023';
  end if;
end
$$;
revoke all on function app.v86_assert_object_keys(jsonb,text[],text) from public,anon,authenticated;

create or replace function app.can_access_prospect_sensitive_v86(p_prospect uuid)
returns boolean language sql stable security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
  select app.is_super_admin() or exists(
    select 1
      from public.sme_prospects prospect
      join public.platform_consultants consultant
        on consultant.id=prospect.assigned_consultant_id
     where prospect.id=p_prospect and consultant.user_id=auth.uid() and consultant.active
  )
$$;
revoke all on function app.can_access_prospect_sensitive_v86(uuid) from public,anon,authenticated;

create or replace function app.v86_next_version(p_table regclass,p_parent_column text,p_parent uuid)
returns integer language plpgsql volatile security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare v_version integer;
begin
  if p_parent_column !~ '^[a-z][a-z0-9_]*$' then
    raise exception 'invalid version parent column' using errcode='22023';
  end if;
  execute format('select coalesce(max(version),0)+1 from %s where %I=$1',p_table,p_parent_column)
    into v_version using p_parent;
  return v_version;
end
$$;
revoke all on function app.v86_next_version(regclass,text,uuid) from public,anon,authenticated;

create or replace function app.v86_normalize_text(p_value text)
returns text language sql immutable
set search_path to 'pg_catalog','pg_temp'
as $$ select nullif(regexp_replace(lower(btrim(coalesce(p_value,''))),'[^a-z0-9]+','','g'),'') $$;
revoke all on function app.v86_normalize_text(text) from public,anon,authenticated;

create or replace function app.v86_normalize_phone(p_value text)
returns text language sql immutable
set search_path to 'pg_catalog','pg_temp'
as $$
  select case
    when regexp_replace(coalesce(p_value,''),'[^0-9+]','','g') ~ '^\+[1-9][0-9]{7,14}$'
      then regexp_replace(p_value,'[^0-9+]','','g')
    when regexp_replace(coalesce(p_value,''),'[^0-9]','','g') ~ '^[89][0-9]{7}$'
      then '+65'||regexp_replace(p_value,'[^0-9]','','g')
    else null end
$$;
revoke all on function app.v86_normalize_phone(text) from public,anon,authenticated;

create or replace function app.v86_normalize_domain(p_value text)
returns text language sql immutable
set search_path to 'pg_catalog','pg_temp'
as $$
  select nullif(split_part(regexp_replace(lower(btrim(coalesce(p_value,''))),
    '^(https?://)?(www\.)?','','i'),'/',1),'')
$$;
revoke all on function app.v86_normalize_domain(text) from public,anon,authenticated;

create or replace function app.v86_import_value(
  p_raw jsonb,p_batch uuid,p_field text
) returns text language sql stable security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
  select nullif(btrim(p_raw->>mapping.source_header),'')
    from public.sme_import_column_mappings mapping
   where mapping.batch_id=p_batch and mapping.canonical_field=p_field
   limit 1
$$;
revoke all on function app.v86_import_value(jsonb,uuid,text) from public,anon,authenticated;

-- ---------------------------------------------------------------------------
-- Versioned typed write contracts.
-- ---------------------------------------------------------------------------

create or replace function public.platform_record_company_profile_v86(
  p_company uuid,p_profile jsonb
) returns jsonb language plpgsql security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare v_actor uuid:=auth.uid();v_version integer;v_row public.sme_company_profile_versions%rowtype;
begin
  if not app.is_platform_operator_v75() then raise exception 'platform operator access is required' using errcode='42501';end if;
  if not exists(select 1 from public.sme_companies where id=p_company) then raise exception 'SME company was not found' using errcode='22023';end if;
  perform app.v86_assert_object_keys(p_profile,array[
    'registration_country','entity_type','incorporated_on','business_status','registered_address',
    'operating_address','postal_code','country_code','region_state','service_areas',
    'main_business_activity','secondary_business_activities','sub_industry','business_description',
    'whatsapp_original','whatsapp_e164','social_profiles','directory_profile_url','directory_code',
    'public_rating','public_review_count','rating_source','employee_range','expected_seats',
    'location_count','years_in_business','annual_revenue_band','customer_type','operating_model',
    'products_services','monthly_volume','seasonal_periods','geographic_coverage','internal_languages',
    'existing_tools','existing_crm','existing_accounting','manual_workflows','required_integrations',
    'migration_volume','digital_maturity','technical_capability','procurement_security_requirements',
    'regulatory_compliance_needs','organisation_structure','parent_company','ownership_model',
    'certifications','current_competitors','verification_status','verified_at','verification_notes',
    'source_name','source_url','source_value','captured_at','confirmed_value','confirmed'
  ],'company profile');
  v_version:=app.v86_next_version('public.sme_company_profile_versions','company_id',p_company);
  insert into public.sme_company_profile_versions(
    company_id,version,registration_country,entity_type,incorporated_on,business_status,
    registered_address,operating_address,postal_code,country_code,region_state,service_areas,
    main_business_activity,secondary_business_activities,sub_industry,business_description,
    whatsapp_original,whatsapp_e164,social_profiles,directory_profile_url,directory_code,
    public_rating,public_review_count,rating_source,employee_range,expected_seats,location_count,
    years_in_business,annual_revenue_band,customer_type,operating_model,products_services,
    monthly_volume,seasonal_periods,geographic_coverage,internal_languages,existing_tools,
    existing_crm,existing_accounting,manual_workflows,required_integrations,migration_volume,
    digital_maturity,technical_capability,procurement_security_requirements,
    regulatory_compliance_needs,organisation_structure,parent_company,ownership_model,
    certifications,current_competitors,verification_status,verified_at,verification_notes,
    source_name,source_url,source_value,captured_at,confirmed_value,confirmed_by,confirmed_at,created_by
  ) values(
    p_company,v_version,nullif(upper(p_profile->>'registration_country'),''),
    nullif(p_profile->>'entity_type',''),nullif(p_profile->>'incorporated_on','')::date,
    nullif(p_profile->>'business_status',''),nullif(p_profile->>'registered_address',''),
    nullif(p_profile->>'operating_address',''),nullif(p_profile->>'postal_code',''),
    nullif(upper(p_profile->>'country_code'),''),nullif(p_profile->>'region_state',''),
    coalesce(array(select jsonb_array_elements_text(p_profile->'service_areas')),'{}'),
    nullif(p_profile->>'main_business_activity',''),
    coalesce(array(select jsonb_array_elements_text(p_profile->'secondary_business_activities')),'{}'),
    nullif(p_profile->>'sub_industry',''),nullif(p_profile->>'business_description',''),
    nullif(p_profile->>'whatsapp_original',''),nullif(p_profile->>'whatsapp_e164',''),
    coalesce(p_profile->'social_profiles','{}'),nullif(p_profile->>'directory_profile_url',''),
    nullif(p_profile->>'directory_code',''),nullif(p_profile->>'public_rating','')::numeric,
    nullif(p_profile->>'public_review_count','')::integer,nullif(p_profile->>'rating_source',''),
    nullif(p_profile->>'employee_range',''),nullif(p_profile->>'expected_seats','')::integer,
    nullif(p_profile->>'location_count','')::integer,nullif(p_profile->>'years_in_business','')::integer,
    nullif(p_profile->>'annual_revenue_band',''),nullif(p_profile->>'customer_type',''),
    nullif(p_profile->>'operating_model',''),
    coalesce(array(select jsonb_array_elements_text(p_profile->'products_services')),'{}'),
    nullif(p_profile->>'monthly_volume','')::integer,
    coalesce(array(select jsonb_array_elements_text(p_profile->'seasonal_periods')),'{}'),
    coalesce(array(select jsonb_array_elements_text(p_profile->'geographic_coverage')),'{}'),
    coalesce(array(select jsonb_array_elements_text(p_profile->'internal_languages')),'{}'),
    coalesce(array(select jsonb_array_elements_text(p_profile->'existing_tools')),'{}'),
    nullif(p_profile->>'existing_crm',''),nullif(p_profile->>'existing_accounting',''),
    nullif(p_profile->>'manual_workflows',''),
    coalesce(array(select jsonb_array_elements_text(p_profile->'required_integrations')),'{}'),
    nullif(p_profile->>'migration_volume','')::integer,nullif(p_profile->>'digital_maturity',''),
    nullif(p_profile->>'technical_capability',''),
    nullif(p_profile->>'procurement_security_requirements',''),
    nullif(p_profile->>'regulatory_compliance_needs',''),
    nullif(p_profile->>'organisation_structure',''),nullif(p_profile->>'parent_company',''),
    nullif(p_profile->>'ownership_model',''),
    coalesce(array(select jsonb_array_elements_text(p_profile->'certifications')),'{}'),
    coalesce(array(select jsonb_array_elements_text(p_profile->'current_competitors')),'{}'),
    coalesce(nullif(p_profile->>'verification_status',''),'unverified'),
    nullif(p_profile->>'verified_at','')::timestamptz,nullif(p_profile->>'verification_notes',''),
    nullif(p_profile->>'source_name',''),nullif(p_profile->>'source_url',''),
    coalesce(p_profile->'source_value','{}'),nullif(p_profile->>'captured_at','')::timestamptz,
    coalesce(p_profile->'confirmed_value','{}'),
    case when coalesce((p_profile->>'confirmed')::boolean,false) then v_actor end,
    case when coalesce((p_profile->>'confirmed')::boolean,false) then now() end,v_actor
  ) returning * into v_row;
  insert into public.audit_log(business_id,actor,action,entity,entity_id,detail)
  values(null,v_actor,'SME_COMPANY_PROFILE_RECORDED_V86','sme_company_profile_versions',v_row.id,
    jsonb_build_object('company_id',p_company,'version',v_version));
  return jsonb_build_object('profile',to_jsonb(v_row));
end
$$;

create or replace function public.platform_record_contact_profile_v86(
  p_contact uuid,p_profile jsonb
) returns jsonb language plpgsql security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare v_actor uuid:=auth.uid();v_version integer;v_row public.sme_contact_profile_versions%rowtype;
begin
  if not app.is_platform_operator_v75() then raise exception 'platform operator access is required' using errcode='42501';end if;
  if not exists(select 1 from public.sme_prospect_contacts where id=p_contact) then raise exception 'SME contact was not found' using errcode='22023';end if;
  perform app.v86_assert_object_keys(p_profile,array[
    'preferred_name','department_function','decision_role','decision_authority_level',
    'mobile_original','office_phone_original','whatsapp_original','preferred_channel',
    'preferred_language','timezone','contact_hours','profile_url','is_billing_contact',
    'is_technical_admin','is_authorised_signatory','consent_basis','marketing_opt_in',
    'opted_in_at','opt_in_source','do_not_contact','last_contacted_at','next_follow_up_at','notes'
  ],'contact profile');
  v_version:=app.v86_next_version('public.sme_contact_profile_versions','contact_id',p_contact);
  insert into public.sme_contact_profile_versions(
    contact_id,version,preferred_name,department_function,decision_role,decision_authority_level,
    mobile_original,mobile_e164,office_phone_original,office_phone_e164,
    whatsapp_original,whatsapp_e164,preferred_channel,preferred_language,timezone,contact_hours,
    profile_url,is_billing_contact,is_technical_admin,is_authorised_signatory,consent_basis,
    marketing_opt_in,opted_in_at,opt_in_source,do_not_contact,last_contacted_at,
    next_follow_up_at,notes,created_by
  ) values(
    p_contact,v_version,nullif(p_profile->>'preferred_name',''),
    nullif(p_profile->>'department_function',''),nullif(p_profile->>'decision_role',''),
    nullif(p_profile->>'decision_authority_level',''),nullif(p_profile->>'mobile_original',''),
    app.v86_normalize_phone(p_profile->>'mobile_original'),nullif(p_profile->>'office_phone_original',''),
    app.v86_normalize_phone(p_profile->>'office_phone_original'),nullif(p_profile->>'whatsapp_original',''),
    app.v86_normalize_phone(p_profile->>'whatsapp_original'),nullif(p_profile->>'preferred_channel',''),
    nullif(p_profile->>'preferred_language',''),nullif(p_profile->>'timezone',''),
    nullif(p_profile->>'contact_hours',''),nullif(p_profile->>'profile_url',''),
    coalesce((p_profile->>'is_billing_contact')::boolean,false),
    coalesce((p_profile->>'is_technical_admin')::boolean,false),
    coalesce((p_profile->>'is_authorised_signatory')::boolean,false),
    nullif(p_profile->>'consent_basis',''),coalesce((p_profile->>'marketing_opt_in')::boolean,false),
    nullif(p_profile->>'opted_in_at','')::timestamptz,nullif(p_profile->>'opt_in_source',''),
    coalesce((p_profile->>'do_not_contact')::boolean,false),
    nullif(p_profile->>'last_contacted_at','')::timestamptz,
    nullif(p_profile->>'next_follow_up_at','')::timestamptz,nullif(p_profile->>'notes',''),v_actor
  ) returning * into v_row;
  insert into public.audit_log(business_id,actor,action,entity,entity_id,detail)
  select null,v_actor,'SME_CONTACT_PROFILE_RECORDED_V86','sme_contact_profile_versions',v_row.id,
    jsonb_build_object('contact_id',p_contact,'prospect_id',contact.prospect_id,'version',v_version)
    from public.sme_prospect_contacts contact where contact.id=p_contact;
  return jsonb_build_object('profile',to_jsonb(v_row));
end
$$;

create or replace function public.platform_record_qualification_v86(
  p_prospect uuid,p_profile jsonb
) returns jsonb language plpgsql security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare v_actor uuid:=auth.uid();v_version integer;v_row public.sme_qualification_detail_versions%rowtype;
begin
  if not app.is_platform_operator_v75() then raise exception 'platform operator access is required' using errcode='42501';end if;
  if not exists(select 1 from public.sme_prospects where id=p_prospect) then raise exception 'prospect was not found' using errcode='22023';end if;
  perform app.v86_assert_object_keys(p_profile,array[
    'primary_problem','why_change','existing_workflow','current_tool_vendor','pain_points',
    'consequence_of_inaction','desired_outcome','required_features','nice_to_have_features',
    'success_criteria','expected_user_count','expected_usage_volume','required_integrations',
    'required_migration','security_requirements','compliance_requirements',
    'decision_maker_contact_id','champion_contact_id','budget_owner_contact_id','budget_status',
    'budget_min_cents','budget_max_cents','expected_subscription_cents','expected_setup_fee_cents',
    'purchase_timeframe','target_go_live','procurement_process','legal_review_required',
    'security_review_required','competitors_considered','decision_criteria','decision_date',
    'main_objection','risk_level','fit_score','intent_score','qualification_status',
    'disqualification_reason','system_suggested_score','score_reasons','human_confirmed_score'
  ],'qualification profile');
  v_version:=app.v86_next_version('public.sme_qualification_detail_versions','prospect_id',p_prospect);
  insert into public.sme_qualification_detail_versions(
    prospect_id,version,primary_problem,why_change,existing_workflow,current_tool_vendor,
    pain_points,consequence_of_inaction,desired_outcome,required_features,nice_to_have_features,
    success_criteria,expected_user_count,expected_usage_volume,required_integrations,
    required_migration,security_requirements,compliance_requirements,decision_maker_contact_id,
    champion_contact_id,budget_owner_contact_id,budget_status,budget_min_cents,budget_max_cents,
    expected_subscription_cents,expected_setup_fee_cents,purchase_timeframe,target_go_live,
    procurement_process,legal_review_required,security_review_required,competitors_considered,
    decision_criteria,decision_date,main_objection,risk_level,fit_score,intent_score,
    qualification_status,disqualification_reason,system_suggested_score,score_reasons,
    human_confirmed_score,confirmed_by,confirmed_at,created_by
  ) values(
    p_prospect,v_version,nullif(p_profile->>'primary_problem',''),nullif(p_profile->>'why_change',''),
    nullif(p_profile->>'existing_workflow',''),nullif(p_profile->>'current_tool_vendor',''),
    coalesce(array(select jsonb_array_elements_text(p_profile->'pain_points')),'{}'),
    nullif(p_profile->>'consequence_of_inaction',''),nullif(p_profile->>'desired_outcome',''),
    coalesce(array(select jsonb_array_elements_text(p_profile->'required_features')),'{}'),
    coalesce(array(select jsonb_array_elements_text(p_profile->'nice_to_have_features')),'{}'),
    coalesce(array(select jsonb_array_elements_text(p_profile->'success_criteria')),'{}'),
    nullif(p_profile->>'expected_user_count','')::integer,
    nullif(p_profile->>'expected_usage_volume','')::integer,
    coalesce(array(select jsonb_array_elements_text(p_profile->'required_integrations')),'{}'),
    nullif(p_profile->>'required_migration',''),
    coalesce(array(select jsonb_array_elements_text(p_profile->'security_requirements')),'{}'),
    coalesce(array(select jsonb_array_elements_text(p_profile->'compliance_requirements')),'{}'),
    nullif(p_profile->>'decision_maker_contact_id','')::uuid,
    nullif(p_profile->>'champion_contact_id','')::uuid,
    nullif(p_profile->>'budget_owner_contact_id','')::uuid,nullif(p_profile->>'budget_status',''),
    nullif(p_profile->>'budget_min_cents','')::bigint,nullif(p_profile->>'budget_max_cents','')::bigint,
    nullif(p_profile->>'expected_subscription_cents','')::bigint,
    nullif(p_profile->>'expected_setup_fee_cents','')::bigint,
    nullif(p_profile->>'purchase_timeframe',''),nullif(p_profile->>'target_go_live','')::date,
    nullif(p_profile->>'procurement_process',''),
    coalesce((p_profile->>'legal_review_required')::boolean,false),
    coalesce((p_profile->>'security_review_required')::boolean,false),
    coalesce(array(select jsonb_array_elements_text(p_profile->'competitors_considered')),'{}'),
    coalesce(array(select jsonb_array_elements_text(p_profile->'decision_criteria')),'{}'),
    nullif(p_profile->>'decision_date','')::date,nullif(p_profile->>'main_objection',''),
    nullif(p_profile->>'risk_level',''),nullif(p_profile->>'fit_score','')::smallint,
    nullif(p_profile->>'intent_score','')::smallint,nullif(p_profile->>'qualification_status',''),
    nullif(p_profile->>'disqualification_reason',''),
    nullif(p_profile->>'system_suggested_score','')::smallint,
    coalesce(array(select jsonb_array_elements_text(p_profile->'score_reasons')),'{}'),
    nullif(p_profile->>'human_confirmed_score','')::smallint,
    case when p_profile?'human_confirmed_score' then v_actor end,
    case when p_profile?'human_confirmed_score' then now() end,v_actor
  ) returning * into v_row;
  insert into public.audit_log(business_id,actor,action,entity,entity_id,detail)
  values(null,v_actor,'SME_QUALIFICATION_RECORDED_V86','sme_qualification_detail_versions',v_row.id,
    jsonb_build_object('prospect_id',p_prospect,'version',v_version,
      'human_confirmed',v_row.human_confirmed_score is not null));
  return jsonb_build_object('qualification',to_jsonb(v_row));
end
$$;

create or replace function public.platform_record_activity_detail_v86(
  p_activity uuid,p_detail jsonb
) returns jsonb language plpgsql security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare v_actor uuid:=auth.uid();v_version integer;v_row public.sme_activity_detail_versions%rowtype;
begin
  if not app.is_platform_operator_v75() then raise exception 'platform operator access is required' using errcode='42501';end if;
  if not exists(select 1 from public.sme_prospect_activities where id=p_activity) then raise exception 'activity was not found' using errcode='22023';end if;
  perform app.v86_assert_object_keys(p_detail,array[
    'contact_id','outcome','disposition','duration_seconds','direction','channel','next_action',
    'next_action_owner','next_action_due_at','meeting_at','meeting_url','meeting_location',
    'calendar_event_id','recording_transcript_url','attachments','created_source','supersedes_activity_id'
  ],'activity detail');
  v_version:=app.v86_next_version('public.sme_activity_detail_versions','activity_id',p_activity);
  insert into public.sme_activity_detail_versions(
    activity_id,version,contact_id,outcome,disposition,duration_seconds,direction,channel,
    next_action,next_action_owner,next_action_due_at,meeting_at,meeting_url,meeting_location,
    calendar_event_id,recording_transcript_url,attachments,created_source,supersedes_activity_id,created_by
  ) values(
    p_activity,v_version,nullif(p_detail->>'contact_id','')::uuid,nullif(p_detail->>'outcome',''),
    nullif(p_detail->>'disposition',''),nullif(p_detail->>'duration_seconds','')::integer,
    nullif(p_detail->>'direction',''),nullif(p_detail->>'channel',''),
    nullif(p_detail->>'next_action',''),nullif(p_detail->>'next_action_owner','')::uuid,
    nullif(p_detail->>'next_action_due_at','')::timestamptz,
    nullif(p_detail->>'meeting_at','')::timestamptz,nullif(p_detail->>'meeting_url',''),
    nullif(p_detail->>'meeting_location',''),nullif(p_detail->>'calendar_event_id',''),
    nullif(p_detail->>'recording_transcript_url',''),coalesce(p_detail->'attachments','[]'),
    coalesce(nullif(p_detail->>'created_source',''),'manual'),
    nullif(p_detail->>'supersedes_activity_id','')::uuid,v_actor
  ) returning * into v_row;
  insert into public.audit_log(business_id,actor,action,entity,entity_id,detail)
  select null,v_actor,'SME_ACTIVITY_DETAIL_RECORDED_V86','sme_activity_detail_versions',v_row.id,
    jsonb_build_object('activity_id',p_activity,'prospect_id',activity.prospect_id,'version',v_version)
    from public.sme_prospect_activities activity where activity.id=p_activity;
  return jsonb_build_object('activity_detail',to_jsonb(v_row));
end
$$;

create or replace function public.platform_record_commercial_detail_v86(
  p_commercial_terms uuid,p_detail jsonb
) returns jsonb language plpgsql security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare v_actor uuid:=auth.uid();v_version integer;v_row public.sme_commercial_detail_versions%rowtype;
begin
  if not app.is_platform_operator_v75() then raise exception 'platform operator access is required' using errcode='42501';end if;
  if not exists(select 1 from public.sme_commercial_terms where id=p_commercial_terms) then raise exception 'commercial terms were not found' using errcode='22023';end if;
  perform app.v86_assert_object_keys(p_detail,array[
    'unit_price_cents','discount_basis_points','discount_reason','discount_approved_by',
    'tax_treatment','setup_fee_cents','contract_term_months','trial_starts_on','trial_ends_on',
    'subscription_starts_on','subscription_ends_on','renewal_on','payment_terms_days',
    'proposal_version','proposal_sent_at','proposal_expires_at','contract_sent_at',
    'contract_signed_at','signatory_contact_id','purchase_order_required','purchase_order_number',
    'subscription_status','payment_status','first_payment_at','amount_collected_cents'
  ],'commercial detail');
  v_version:=app.v86_next_version('public.sme_commercial_detail_versions','commercial_terms_id',p_commercial_terms);
  insert into public.sme_commercial_detail_versions(
    commercial_terms_id,version,unit_price_cents,discount_basis_points,discount_reason,
    discount_approved_by,tax_treatment,setup_fee_cents,contract_term_months,trial_starts_on,
    trial_ends_on,subscription_starts_on,subscription_ends_on,renewal_on,payment_terms_days,
    proposal_version,proposal_sent_at,proposal_expires_at,contract_sent_at,contract_signed_at,
    signatory_contact_id,purchase_order_required,purchase_order_number,subscription_status,
    payment_status,first_payment_at,amount_collected_cents,created_by
  ) values(
    p_commercial_terms,v_version,nullif(p_detail->>'unit_price_cents','')::bigint,
    nullif(p_detail->>'discount_basis_points','')::integer,nullif(p_detail->>'discount_reason',''),
    nullif(p_detail->>'discount_approved_by','')::uuid,nullif(p_detail->>'tax_treatment',''),
    nullif(p_detail->>'setup_fee_cents','')::bigint,
    nullif(p_detail->>'contract_term_months','')::integer,
    nullif(p_detail->>'trial_starts_on','')::date,nullif(p_detail->>'trial_ends_on','')::date,
    nullif(p_detail->>'subscription_starts_on','')::date,
    nullif(p_detail->>'subscription_ends_on','')::date,nullif(p_detail->>'renewal_on','')::date,
    nullif(p_detail->>'payment_terms_days','')::integer,nullif(p_detail->>'proposal_version',''),
    nullif(p_detail->>'proposal_sent_at','')::timestamptz,
    nullif(p_detail->>'proposal_expires_at','')::timestamptz,
    nullif(p_detail->>'contract_sent_at','')::timestamptz,
    nullif(p_detail->>'contract_signed_at','')::timestamptz,
    nullif(p_detail->>'signatory_contact_id','')::uuid,
    coalesce((p_detail->>'purchase_order_required')::boolean,false),
    nullif(p_detail->>'purchase_order_number',''),nullif(p_detail->>'subscription_status',''),
    nullif(p_detail->>'payment_status',''),nullif(p_detail->>'first_payment_at','')::timestamptz,
    nullif(p_detail->>'amount_collected_cents','')::bigint,v_actor
  ) returning * into v_row;
  insert into public.audit_log(business_id,actor,action,entity,entity_id,detail)
  select null,v_actor,'SME_COMMERCIAL_DETAIL_RECORDED_V86','sme_commercial_detail_versions',v_row.id,
    jsonb_build_object('commercial_terms_id',p_commercial_terms,'prospect_id',terms.prospect_id,'version',v_version)
    from public.sme_commercial_terms terms where terms.id=p_commercial_terms;
  return jsonb_build_object('commercial_detail',to_jsonb(v_row));
end
$$;

create or replace function public.platform_record_conversion_configuration_v86(
  p_prospect uuid,p_configuration jsonb
) returns jsonb language plpgsql security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare v_actor uuid:=auth.uid();v_version integer;v_row public.sme_conversion_configuration_versions%rowtype;
begin
  if not app.is_platform_operator_v75() then raise exception 'platform operator access is required' using errcode='42501';end if;
  if not exists(select 1 from public.sme_prospects where id=p_prospect) then raise exception 'prospect was not found' using errcode='22023';end if;
  perform app.v86_assert_object_keys(p_configuration,array[
    'workspace_name','legal_name','registration_number','workspace_slug','primary_owner_contact_id',
    'owner_email','owner_phone','administrator_emails','team_member_emails','role_template_key',
    'seat_limit','plan_code','billing_cycle','trial_starts_on','trial_ends_on','billing_contact_id',
    'invoice_address','gst_registration_number','invoice_prefix','currency','timezone','locale',
    'date_format','logo_document_id','brand_primary_color','brand_secondary_color','sender_name',
    'welcome_message','custom_domain','default_terms_document_id','payment_instructions_masked',
    'workflow_template_key','notification_preferences','required_integrations','data_import_status',
    'security_policy','require_two_factor','retention_policy_days','support_owner',
    'customer_success_consultant_id','target_go_live'
  ],'conversion configuration');
  v_version:=app.v86_next_version('public.sme_conversion_configuration_versions','prospect_id',p_prospect);
  insert into public.sme_conversion_configuration_versions(
    prospect_id,version,workspace_name,legal_name,registration_number,workspace_slug,
    primary_owner_contact_id,owner_email,owner_phone,administrator_emails,team_member_emails,
    role_template_key,seat_limit,plan_code,billing_cycle,trial_starts_on,trial_ends_on,
    billing_contact_id,invoice_address,gst_registration_number,invoice_prefix,currency,timezone,
    locale,date_format,logo_document_id,brand_primary_color,brand_secondary_color,sender_name,
    welcome_message,custom_domain,default_terms_document_id,payment_instructions_masked,
    workflow_template_key,notification_preferences,required_integrations,data_import_status,
    security_policy,require_two_factor,retention_policy_days,support_owner,
    customer_success_consultant_id,target_go_live,created_by
  ) values(
    p_prospect,v_version,nullif(p_configuration->>'workspace_name',''),
    nullif(p_configuration->>'legal_name',''),nullif(p_configuration->>'registration_number',''),
    nullif(p_configuration->>'workspace_slug',''),
    nullif(p_configuration->>'primary_owner_contact_id','')::uuid,
    nullif(lower(p_configuration->>'owner_email'),''),
    nullif(p_configuration->>'owner_phone',''),
    coalesce(array(select lower(value) from jsonb_array_elements_text(p_configuration->'administrator_emails') value),'{}'),
    coalesce(array(select lower(value) from jsonb_array_elements_text(p_configuration->'team_member_emails') value),'{}'),
    nullif(p_configuration->>'role_template_key',''),nullif(p_configuration->>'seat_limit','')::integer,
    nullif(p_configuration->>'plan_code',''),nullif(p_configuration->>'billing_cycle',''),
    nullif(p_configuration->>'trial_starts_on','')::date,
    nullif(p_configuration->>'trial_ends_on','')::date,
    nullif(p_configuration->>'billing_contact_id','')::uuid,
    nullif(p_configuration->>'invoice_address',''),
    nullif(p_configuration->>'gst_registration_number',''),nullif(p_configuration->>'invoice_prefix',''),
    nullif(upper(p_configuration->>'currency'),''),nullif(p_configuration->>'timezone',''),
    nullif(p_configuration->>'locale',''),nullif(p_configuration->>'date_format',''),
    nullif(p_configuration->>'logo_document_id','')::uuid,
    nullif(p_configuration->>'brand_primary_color',''),
    nullif(p_configuration->>'brand_secondary_color',''),nullif(p_configuration->>'sender_name',''),
    nullif(p_configuration->>'welcome_message',''),nullif(p_configuration->>'custom_domain',''),
    nullif(p_configuration->>'default_terms_document_id','')::uuid,
    nullif(p_configuration->>'payment_instructions_masked',''),
    nullif(p_configuration->>'workflow_template_key',''),
    coalesce(p_configuration->'notification_preferences','{}'),
    coalesce(array(select jsonb_array_elements_text(p_configuration->'required_integrations')),'{}'),
    nullif(p_configuration->>'data_import_status',''),nullif(p_configuration->>'security_policy',''),
    coalesce((p_configuration->>'require_two_factor')::boolean,false),
    nullif(p_configuration->>'retention_policy_days','')::integer,
    nullif(p_configuration->>'support_owner','')::uuid,
    nullif(p_configuration->>'customer_success_consultant_id','')::uuid,
    nullif(p_configuration->>'target_go_live','')::date,v_actor
  ) returning * into v_row;
  insert into public.audit_log(business_id,actor,action,entity,entity_id,detail)
  values(null,v_actor,'SME_CONVERSION_CONFIGURATION_RECORDED_V86',
    'sme_conversion_configuration_versions',v_row.id,
    jsonb_build_object('prospect_id',p_prospect,'version',v_version));
  return jsonb_build_object('configuration',to_jsonb(v_row));
end
$$;

create or replace function public.platform_upsert_prospect_contact_v86(
  p_prospect uuid,p_contact uuid,p_base jsonb,p_profile jsonb,
  p_expected_version bigint,p_idempotency_key text
) returns jsonb language plpgsql security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare
  v_actor uuid:=auth.uid();v_hash text;v_replay jsonb;v_contact public.sme_prospect_contacts%rowtype;
  v_prospect public.sme_prospects%rowtype;v_profile jsonb;v_response jsonb;
begin
  if not app.is_platform_operator_v75() then raise exception 'platform operator access is required' using errcode='42501';end if;
  perform app.require_idempotency_key_v79(p_idempotency_key);
  perform app.v86_assert_object_keys(p_base,array[
    'full_name','title','email','phone','is_primary','active'
  ],'contact base');
  if length(btrim(coalesce(p_base->>'full_name','')))<2
    or (nullif(btrim(p_base->>'email'),'') is null and nullif(btrim(p_base->>'phone'),'') is null) then
    raise exception 'contact name and email or phone are required' using errcode='22023';end if;
  v_hash:=app.v76_sha256_hex(jsonb_build_object(
    'prospect',p_prospect,'contact',p_contact,'base',p_base,'profile',p_profile,
    'expected_version',p_expected_version
  )::text);
  v_replay:=app.v76_replay(v_actor,'upsert_contact_v86',p_idempotency_key,v_hash);
  if v_replay is not null then return v_replay;end if;
  update public.sme_prospects set version=version+1,updated_by=v_actor,updated_at=now()
   where id=p_prospect and version=p_expected_version returning * into v_prospect;
  if not found then raise exception 'prospect version conflict' using errcode='40001';end if;
  if coalesce((p_base->>'is_primary')::boolean,false) then
    update public.sme_prospect_contacts set is_primary=false,updated_at=now()
      where prospect_id=p_prospect and is_primary and (p_contact is null or id<>p_contact);
  end if;
  if p_contact is null then
    insert into public.sme_prospect_contacts(
      prospect_id,full_name,title,email,phone,is_primary,active
    ) values(
      p_prospect,btrim(p_base->>'full_name'),nullif(btrim(p_base->>'title'),''),
      nullif(lower(btrim(p_base->>'email')),''),nullif(btrim(p_base->>'phone'),''),
      coalesce((p_base->>'is_primary')::boolean,false),
      coalesce((p_base->>'active')::boolean,true)
    ) returning * into v_contact;
  else
    update public.sme_prospect_contacts set
      full_name=btrim(p_base->>'full_name'),title=nullif(btrim(p_base->>'title'),''),
      email=nullif(lower(btrim(p_base->>'email')),''),phone=nullif(btrim(p_base->>'phone'),''),
      is_primary=coalesce((p_base->>'is_primary')::boolean,is_primary),
      active=coalesce((p_base->>'active')::boolean,active),updated_at=now()
     where id=p_contact and prospect_id=p_prospect returning * into v_contact;
    if not found then raise exception 'prospect contact was not found' using errcode='22023';end if;
  end if;
  if p_profile is not null then
    v_profile:=public.platform_record_contact_profile_v86(v_contact.id,p_profile)->'profile';
  end if;
  insert into public.audit_log(business_id,actor,action,entity,entity_id,detail)
  values(null,v_actor,'SME_PROSPECT_CONTACT_UPSERTED_V86','sme_prospect_contacts',v_contact.id,
    jsonb_build_object('prospect_id',p_prospect,'new_prospect_version',v_prospect.version,
      'created',p_contact is null,'profile_recorded',v_profile is not null));
  v_response:=jsonb_build_object('replayed',false,'contact',to_jsonb(v_contact),
    'profile',v_profile,'prospect_version',v_prospect.version);
  perform app.v76_store_receipt(v_actor,'upsert_contact_v86',p_idempotency_key,v_hash,v_response);
  return v_response;
end
$$;

-- ---------------------------------------------------------------------------
-- Stage validation and evidence-backed move. This is the v86 contract for all
-- human-managed moves; v79 remains the authority for system-managed stages.
-- ---------------------------------------------------------------------------

create or replace function app.validate_stage_entry_v86(
  p_prospect uuid,p_stage text,p_evidence jsonb,p_commercial_terms jsonb
) returns void language plpgsql stable security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare v_rule public.sme_stage_entry_requirements%rowtype;v_missing text[];
begin
  select * into v_rule from public.sme_stage_entry_requirements where stage_key=p_stage;
  if not found then raise exception 'unknown SME stage requirement' using errcode='22023';end if;
  if v_rule.system_managed then
    raise exception 'this SME stage is system-managed and requires conversion evidence' using errcode='42501';
  end if;
  if p_evidence is null or jsonb_typeof(p_evidence)<>'object' then
    raise exception 'stage entry evidence must be an object' using errcode='22023';
  end if;
  select array_agg(key order by key) into v_missing
    from unnest(v_rule.required_keys) key
   where not (p_evidence?key) or p_evidence->>key is null or btrim(p_evidence->>key)='';
  if cardinality(v_missing)>0 then
    raise exception 'stage % is missing evidence: %',p_stage,array_to_string(v_missing,', ')
      using errcode='22023';
  end if;
  if p_stage='new_lead' and not exists(
    select 1 from public.sme_prospects prospect join public.sme_companies company on company.id=prospect.company_id
     where prospect.id=p_prospect and coalesce(company.legal_name,company.trading_name,company.registration_number) is not null
       and exists(select 1 from public.sme_prospect_source_lineage source where source.prospect_id=p_prospect)
  ) then raise exception 'New Lead requires company identity and source' using errcode='22023';
  elsif p_stage='appt_set' and not exists(
    select 1 from public.sme_prospect_contacts contact where contact.prospect_id=p_prospect and contact.active
      and (contact.email is not null or contact.phone is not null)
  ) then raise exception 'Appointment Set requires a primary contact with a valid channel' using errcode='22023';
  elsif p_stage like 'npu_%' and not (p_evidence?'next_attempt_at' or p_evidence?'terminal_disposition') then
    raise exception 'NPU requires next attempt or terminal disposition' using errcode='22023';
  elsif p_stage='meeting_sent' and not (p_evidence?'meeting_url' or p_evidence?'physical_location') then
    raise exception 'Meeting Link Sent requires a meeting URL or physical location' using errcode='22023';
  elsif p_stage='pending_decision' and not (p_evidence?'decision_at' or p_evidence?'next_follow_up_at') then
    raise exception 'Pending Decision requires decision date or next follow-up' using errcode='22023';
  elsif p_stage='client' and (
    coalesce((p_evidence->>'explicit_confirmation')::boolean,false)=false
    or p_commercial_terms is null or jsonb_typeof(p_commercial_terms)<>'object'
    or coalesce(p_commercial_terms->>'plan_code','')=''
    or coalesce(p_commercial_terms->>'product_code','')=''
    or coalesce((p_commercial_terms->>'seats')::integer,0)<=0
    or coalesce((p_commercial_terms->>'accepted_value_cents')::bigint,-1)<0
    or coalesce(p_commercial_terms->>'currency','')!~'^[A-Z]{3}$'
    or coalesce(p_commercial_terms->>'contract_status','') not in ('accepted','signed')
    or coalesce(p_commercial_terms->>'owner_email','') not like '%@%'
    or nullif(p_commercial_terms->>'onboarding_owner_consultant_id','') is null
    or nullif(p_commercial_terms->>'target_go_live','') is null
  ) then raise exception 'Client requires explicit confirmation and complete commercial evidence' using errcode='22023';
  elsif p_stage='lost' and (
    coalesce(p_evidence->>'reason_code','') not in
      ('no_response','not_interested','no_budget','timing','chose_competitor',
       'missing_required_feature','procurement_security_blocker','price',
       'internal_priority_changed','business_ceased','duplicate','bad_fit','other')
    or (coalesce((p_evidence->>'recontact_permission')::boolean,false)
      and not p_evidence?'recontact_at')
  ) then raise exception 'Lost requires a valid reason and conditional recontact date' using errcode='22023';
  end if;
end
$$;
revoke all on function app.validate_stage_entry_v86(uuid,text,jsonb,jsonb) from public,anon,authenticated;

create or replace function public.platform_move_prospect_stage_v86(
  p_prospect uuid,p_to_stage text,p_expected_version bigint,p_entry_evidence jsonb,
  p_commercial_terms jsonb default null,p_idempotency_key text default null
) returns jsonb language plpgsql security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare v_actor uuid:=auth.uid();v_rule public.sme_stage_entry_requirements%rowtype;v_result jsonb;
begin
  if not app.is_platform_operator_v75() then raise exception 'platform operator access is required' using errcode='42501';end if;
  perform app.validate_stage_entry_v86(p_prospect,p_to_stage,p_entry_evidence,p_commercial_terms);
  select * into strict v_rule from public.sme_stage_entry_requirements where stage_key=p_to_stage;
  insert into public.sme_stage_entry_evidence(
    prospect_id,stage_key,prospect_version,schema_version,evidence,actor
  ) values(p_prospect,p_to_stage,p_expected_version,v_rule.evidence_schema_version,p_entry_evidence,v_actor);
  v_result:=public.platform_move_prospect_stage_v76(
    p_prospect,p_to_stage,p_expected_version,
    case when p_to_stage='lost' then p_entry_evidence->>'reason_code' end,
    case when p_to_stage='lost' then p_entry_evidence->>'context' end,
    p_commercial_terms,p_idempotency_key
  );
  insert into public.audit_log(business_id,actor,action,entity,entity_id,detail)
  values(null,v_actor,'SME_PROSPECT_STAGE_EVIDENCE_RECORDED_V86','sme_prospects',p_prospect,
    jsonb_build_object('to_stage',p_to_stage,'prospect_version',p_expected_version,
      'evidence_schema_version',v_rule.evidence_schema_version));
  return v_result||jsonb_build_object('entry_evidence_recorded',true);
end
$$;

-- ---------------------------------------------------------------------------
-- Private document signing request seams. A trusted Edge worker exchanges the
-- one-time token for a Storage signed URL; SQL never creates a public URL.
-- ---------------------------------------------------------------------------

create or replace function public.platform_request_prospect_document_upload_v86(
  p_prospect uuid,p_document_type text,p_original_filename text,p_mime_type text,
  p_size_bytes bigint,p_logical_document uuid default null,p_notes text default null
) returns jsonb language plpgsql security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare
  v_actor uuid:=auth.uid();v_company uuid;v_logical uuid:=coalesce(p_logical_document,gen_random_uuid());
  v_version integer;v_document public.sme_document_versions%rowtype;v_token text;v_request uuid;
  v_safe_name text;
begin
  if not app.can_access_prospect_sensitive_v86(p_prospect) then
    raise exception 'assigned consultant or super admin access is required' using errcode='42501';end if;
  select company_id into v_company from public.sme_prospects where id=p_prospect;
  if v_company is null then raise exception 'prospect was not found' using errcode='22023';end if;
  select coalesce(max(version),0)+1 into v_version
    from public.sme_document_versions where logical_document_id=v_logical;
  v_safe_name:=left(regexp_replace(lower(btrim(p_original_filename)),'[^a-z0-9._-]+','_','g'),180);
  if v_safe_name='' then raise exception 'document filename is invalid' using errcode='22023';end if;
  insert into public.sme_document_versions(
    logical_document_id,version,prospect_id,company_id,document_type,original_filename,
    object_path,mime_type,size_bytes,status,notes,uploaded_by,created_by
  ) values(
    v_logical,v_version,p_prospect,v_company,p_document_type,btrim(p_original_filename),
    'prospects/'||p_prospect||'/'||v_logical||'/v'||v_version||'/'||v_safe_name,
    p_mime_type,p_size_bytes,'reserved',nullif(btrim(p_notes),''),v_actor,v_actor
  ) returning * into v_document;
  v_token:=encode(extensions.gen_random_bytes(24),'hex');
  insert into public.sme_document_signing_requests(
    document_version_id,purpose,token_hash,requested_by,expires_at
  ) values(v_document.id,'upload',app.v76_sha256_hex(v_token),v_actor,now()+interval '10 minutes')
  returning id into v_request;
  insert into public.audit_log(business_id,actor,action,entity,entity_id,detail)
  values(null,v_actor,'SME_DOCUMENT_UPLOAD_REQUESTED_V86','sme_document_versions',v_document.id,
    jsonb_build_object('prospect_id',p_prospect,'document_type',p_document_type,
      'mime_type',p_mime_type,'size_bytes',p_size_bytes,'request_id',v_request));
  return jsonb_build_object(
    'request_id',v_request,'exchange_token',v_token,'expires_at',now()+interval '10 minutes',
    'document_version_id',v_document.id,'logical_document_id',v_logical,'version',v_version,
    'bucket_id',v_document.bucket_id,'object_path',v_document.object_path,
    'signed_url',null,'requires_trusted_signer',true
  );
end
$$;

create or replace function public.platform_request_prospect_document_read_v86(
  p_document_version uuid
) returns jsonb language plpgsql security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare v_actor uuid:=auth.uid();v_document public.sme_document_versions%rowtype;v_token text;v_request uuid;
begin
  select * into v_document from public.sme_document_versions where id=p_document_version;
  if not found then raise exception 'document was not found' using errcode='22023';end if;
  if not app.can_access_prospect_sensitive_v86(v_document.prospect_id) then
    raise exception 'assigned consultant or super admin access is required' using errcode='42501';end if;
  if v_document.status not in ('uploaded','verified') then
    raise exception 'document is not available for reading' using errcode='22023';end if;
  v_token:=encode(extensions.gen_random_bytes(24),'hex');
  insert into public.sme_document_signing_requests(
    document_version_id,purpose,token_hash,requested_by,expires_at
  ) values(v_document.id,'read',app.v76_sha256_hex(v_token),v_actor,now()+interval '5 minutes')
  returning id into v_request;
  insert into public.audit_log(business_id,actor,action,entity,entity_id,detail)
  values(null,v_actor,'SME_DOCUMENT_READ_REQUESTED_V86','sme_document_versions',v_document.id,
    jsonb_build_object('prospect_id',v_document.prospect_id,'request_id',v_request));
  return jsonb_build_object(
    'request_id',v_request,'exchange_token',v_token,'expires_at',now()+interval '5 minutes',
    'document_version_id',v_document.id,'bucket_id',v_document.bucket_id,
    'object_path',v_document.object_path,'signed_url',null,'requires_trusted_signer',true
  );
end
$$;

create or replace function public.service_consume_document_signing_request_v86(
  p_request uuid,p_exchange_token text,p_actor uuid
) returns jsonb language plpgsql security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare v_request public.sme_document_signing_requests%rowtype;v_document public.sme_document_versions%rowtype;
begin
  select * into v_request from public.sme_document_signing_requests where id=p_request for update;
  if p_actor is null or not found or v_request.requested_by<>p_actor
    or v_request.consumed_at is not null or v_request.expires_at<=now()
    or v_request.token_hash<>app.v76_sha256_hex(coalesce(p_exchange_token,'')) then
    raise exception 'document signing request is invalid or expired' using errcode='22023';end if;
  update public.sme_document_signing_requests set consumed_at=now() where id=v_request.id;
  select * into strict v_document from public.sme_document_versions where id=v_request.document_version_id;
  return jsonb_build_object(
    'purpose',v_request.purpose,'bucket_id',v_document.bucket_id,'object_path',v_document.object_path,
    'mime_type',v_document.mime_type,'size_bytes',v_document.size_bytes,
    'original_filename',v_document.original_filename,
    'expires_at',v_request.expires_at,'document_version_id',v_document.id,
    'requested_by',v_request.requested_by
  );
end
$$;

create or replace function public.service_get_consumed_document_upload_v86(
  p_request uuid,p_actor uuid
) returns jsonb language plpgsql security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare v_request public.sme_document_signing_requests%rowtype;v_document public.sme_document_versions%rowtype;
begin
  select * into v_request from public.sme_document_signing_requests where id=p_request;
  if p_actor is null or not found or v_request.requested_by<>p_actor
    or v_request.purpose<>'upload' or v_request.consumed_at is null
    or v_request.expires_at<=now() then
    raise exception 'consumed upload signing request was not found or has expired' using errcode='22023';end if;
  select * into v_document from public.sme_document_versions
    where id=v_request.document_version_id;
  if not found or v_document.status<>'reserved' then
    raise exception 'reserved document upload target was not found' using errcode='22023';end if;
  return jsonb_build_object(
    'request_id',v_request.id,'purpose',v_request.purpose,
    'bucket_id',v_document.bucket_id,'object_path',v_document.object_path,
    'mime_type',v_document.mime_type,'size_bytes',v_document.size_bytes,
    'original_filename',v_document.original_filename,
    'expires_at',v_request.expires_at,'document_version_id',v_document.id,
    'requested_by',v_request.requested_by
  );
end
$$;

create or replace function public.service_finalize_document_upload_v86(
  p_request uuid,p_sha256 text,p_observed_size_bytes bigint,p_actor uuid
) returns jsonb language plpgsql security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare v_request public.sme_document_signing_requests%rowtype;v_document public.sme_document_versions%rowtype;
begin
  select * into v_request from public.sme_document_signing_requests where id=p_request for update;
  if p_actor is null or not found or v_request.requested_by<>p_actor
    or v_request.purpose<>'upload' or v_request.consumed_at is null
    or v_request.expires_at<=now() then
    raise exception 'consumed upload signing request was not found or has expired' using errcode='22023';end if;
  select * into v_document from public.sme_document_versions
    where id=v_request.document_version_id for update;
  if v_document.status<>'reserved' or p_observed_size_bytes<>v_document.size_bytes
    or p_sha256!~'^[0-9a-f]{64}$' then
    raise exception 'uploaded object metadata does not match its reservation' using errcode='22023';end if;
  update public.sme_document_versions set status='uploaded',sha256=p_sha256,uploaded_at=now()
    where id=v_document.id returning * into v_document;
  insert into public.audit_log(business_id,actor,action,entity,entity_id,detail)
  values(null,v_request.requested_by,'SME_DOCUMENT_UPLOAD_FINALIZED_V86',
    'sme_document_versions',v_document.id,
    jsonb_build_object('prospect_id',v_document.prospect_id,'request_id',p_request,
      'size_bytes',p_observed_size_bytes));
  return jsonb_build_object('document',to_jsonb(v_document)-'object_path');
end
$$;

-- ---------------------------------------------------------------------------
-- Import analysis, explicit decisions, commit and guarded reversal.
-- ---------------------------------------------------------------------------

create or replace function public.platform_analyse_prospect_import_v86(
  p_batch uuid,p_column_mapping jsonb
) returns jsonb language plpgsql security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare
  v_actor uuid:=auth.uid();v_batch public.sme_prospect_import_batches%rowtype;
  v_pair record;v_row public.sme_prospect_import_rows%rowtype;v_normal jsonb;
  v_company text;v_uen text;v_email text;v_phone text;v_domain text;v_postal text;v_stage text;
  v_errors text[];v_candidate record;v_candidate_count integer;v_status text;
  v_valid integer:=0;v_unmapped integer:=0;v_conflict integer:=0;v_invalid integer:=0;
begin
  if not app.is_platform_operator_v75() then raise exception 'platform operator access is required' using errcode='42501';end if;
  select * into v_batch from public.sme_prospect_import_batches where id=p_batch for update;
  if not found or v_batch.status<>'staged' then raise exception 'staged import batch was not found' using errcode='22023';end if;
  if p_column_mapping is null or jsonb_typeof(p_column_mapping)<>'object' then
    raise exception 'column mapping must be an object of canonical field to source header' using errcode='22023';end if;
  delete from public.sme_import_column_mappings where batch_id=p_batch;
  for v_pair in select key canonical_field,value source_header from jsonb_each_text(p_column_mapping)
  loop
    if v_pair.canonical_field like 'custom__%' then
      if substring(v_pair.canonical_field from 9)!~'^[a-z][a-z0-9_]{1,62}$' then
        raise exception 'invalid custom import field: %',v_pair.canonical_field using errcode='22023';end if;
      insert into public.sme_import_column_mappings(
        batch_id,source_header,canonical_field,custom_label,created_by
      ) values(p_batch,v_pair.source_header,null,
        replace(initcap(replace(substring(v_pair.canonical_field from 9),'_',' ')),'  ',' '),v_actor);
    else
      if not exists(select 1 from public.sme_import_field_definitions where canonical_field=v_pair.canonical_field) then
        raise exception 'unknown canonical import field: %',v_pair.canonical_field using errcode='22023';end if;
      insert into public.sme_import_column_mappings(batch_id,source_header,canonical_field,created_by)
      values(p_batch,v_pair.source_header,v_pair.canonical_field,v_actor);
    end if;
  end loop;
  if not exists(select 1 from public.sme_import_column_mappings where batch_id=p_batch and canonical_field='company_name') then
    raise exception 'company_name mapping is required' using errcode='22023';end if;
  delete from public.sme_import_dedupe_candidates where import_row_id in(
    select id from public.sme_prospect_import_rows where batch_id=p_batch);
  for v_row in select * from public.sme_prospect_import_rows where batch_id=p_batch order by row_number for update
  loop
    v_company:=app.v86_import_value(v_row.raw_payload,p_batch,'company_name');
    v_uen:=app.v86_import_value(v_row.raw_payload,p_batch,'registration_number');
    v_email:=lower(app.v86_import_value(v_row.raw_payload,p_batch,'email'));
    v_phone:=app.v86_normalize_phone(app.v86_import_value(v_row.raw_payload,p_batch,'phone'));
    v_domain:=app.v86_normalize_domain(app.v86_import_value(v_row.raw_payload,p_batch,'website'));
    v_postal:=app.v86_import_value(v_row.raw_payload,p_batch,'postal_code');
    v_stage:=app.map_sme_stage_v76(app.v86_import_value(v_row.raw_payload,p_batch,'stage'));
    v_errors:='{}';
    if v_company is null then v_errors:=array_append(v_errors,'company_name_required');end if;
    if v_email is not null and v_email!~'^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$' then
      v_errors:=array_append(v_errors,'invalid_email');end if;
    if app.v86_import_value(v_row.raw_payload,p_batch,'phone') is not null and v_phone is null then
      v_errors:=array_append(v_errors,'invalid_phone');end if;
    if v_postal is not null and v_postal!~'^[A-Za-z0-9 -]{3,12}$' then
      v_errors:=array_append(v_errors,'invalid_postal_code');end if;
    if v_uen is not null and v_uen!~'^[A-Za-z0-9-]{5,32}$' then
      v_errors:=array_append(v_errors,'invalid_registration_number');end if;
    v_normal:=jsonb_build_object(
      'company_name',v_company,'registration_number',nullif(upper(v_uen),''),
      'contact_name',app.v86_import_value(v_row.raw_payload,p_batch,'contact_name'),
      'job_title',app.v86_import_value(v_row.raw_payload,p_batch,'job_title'),
      'email',v_email,'phone_e164',v_phone,'website_domain',v_domain,'postal_code',v_postal,
      'address',app.v86_import_value(v_row.raw_payload,p_batch,'address'),
      'directory_code',app.v86_import_value(v_row.raw_payload,p_batch,'directory_code'),
      'rating',app.v86_import_value(v_row.raw_payload,p_batch,'rating'),
      'review_count',app.v86_import_value(v_row.raw_payload,p_batch,'review_count'),
      'region',app.v86_import_value(v_row.raw_payload,p_batch,'region'),
      'industry',app.v86_import_value(v_row.raw_payload,p_batch,'industry'),
      'employee_count',app.v86_import_value(v_row.raw_payload,p_batch,'employee_count'),
      'notes',app.v86_import_value(v_row.raw_payload,p_batch,'notes'),
      'raw_stage',app.v86_import_value(v_row.raw_payload,p_batch,'stage'),'mapped_stage_key',v_stage
    );
    v_candidate_count:=0;
    for v_candidate in
      select prospect.id,
        case
          when v_uen is not null and lower(btrim(company.registration_number))=lower(btrim(v_uen)) then 'registration_number'
          when v_domain is not null and app.v86_normalize_domain(company.website)=v_domain then 'domain'
          when v_email is not null and (
            lower(btrim(company.email))=v_email or exists(select 1 from public.sme_prospect_contacts c where c.prospect_id=prospect.id and lower(btrim(c.email))=v_email)
          ) then 'email'
          when v_phone is not null and (
            app.v86_normalize_phone(company.phone)=v_phone or exists(select 1 from public.sme_prospect_contacts c where c.prospect_id=prospect.id and app.v86_normalize_phone(c.phone)=v_phone)
          ) then 'phone'
          when app.v86_normalize_text(coalesce(company.legal_name,company.trading_name))=app.v86_normalize_text(v_company)
            and (v_postal is null or coalesce(profile.postal_code,'')=v_postal) then 'company_name_postal'
          else 'similar_name' end match_basis,
        case
          when v_uen is not null and lower(btrim(company.registration_number))=lower(btrim(v_uen)) then 100
          when v_domain is not null and app.v86_normalize_domain(company.website)=v_domain then 95
          when v_email is not null and (
            lower(btrim(company.email))=v_email or exists(select 1 from public.sme_prospect_contacts c where c.prospect_id=prospect.id and lower(btrim(c.email))=v_email)
          ) then 90
          when v_phone is not null and (
            app.v86_normalize_phone(company.phone)=v_phone or exists(select 1 from public.sme_prospect_contacts c where c.prospect_id=prospect.id and app.v86_normalize_phone(c.phone)=v_phone)
          ) then 85
          else 70 end score
      from public.sme_prospects prospect
      join public.sme_companies company on company.id=prospect.company_id
      left join lateral(
        select p.* from public.sme_company_profile_versions p where p.company_id=company.id order by p.version desc limit 1
      ) profile on true
      where (v_uen is not null and lower(btrim(company.registration_number))=lower(btrim(v_uen)))
         or (v_domain is not null and app.v86_normalize_domain(company.website)=v_domain)
         or (v_email is not null and (lower(btrim(company.email))=v_email or exists(
           select 1 from public.sme_prospect_contacts c where c.prospect_id=prospect.id and lower(btrim(c.email))=v_email)))
         or (v_phone is not null and (app.v86_normalize_phone(company.phone)=v_phone or exists(
           select 1 from public.sme_prospect_contacts c where c.prospect_id=prospect.id and app.v86_normalize_phone(c.phone)=v_phone)))
         or app.v86_normalize_text(coalesce(company.legal_name,company.trading_name))=app.v86_normalize_text(v_company)
      order by score desc,prospect.created_at limit 20
    loop
      insert into public.sme_import_dedupe_candidates(
        import_row_id,candidate_prospect_id,match_basis,score,evidence
      ) values(v_row.id,v_candidate.id,v_candidate.match_basis,v_candidate.score,
        jsonb_build_object('priority',
          case v_candidate.match_basis when 'registration_number' then 1 when 'domain' then 2
            when 'email' then 3 when 'phone' then 4 else 5 end))
      on conflict do nothing;
      v_candidate_count:=v_candidate_count+1;
    end loop;
    if cardinality(v_errors)>0 then v_status:='invalid';v_invalid:=v_invalid+1;
    elsif v_candidate_count>0 or exists(
      select 1 from public.sme_prospect_import_rows prior
       where prior.batch_id=p_batch and prior.row_number<v_row.row_number and (
         (v_uen is not null and prior.normalized_payload->>'registration_number'=upper(v_uen))
         or (v_domain is not null and prior.normalized_payload->>'website_domain'=v_domain)
         or (v_email is not null and prior.normalized_payload->>'email'=v_email)
         or (v_phone is not null and prior.normalized_payload->>'phone_e164'=v_phone)
       )
    ) then v_status:='conflict';v_conflict:=v_conflict+1;
    elsif v_stage is null and v_normal->>'raw_stage' is not null then v_status:='unmapped';v_unmapped:=v_unmapped+1;
    else v_status:='valid';v_valid:=v_valid+1;end if;
    update public.sme_prospect_import_rows set normalized_payload=v_normal,mapped_stage_key=v_stage,
      raw_stage=v_normal->>'raw_stage',row_status=v_status,errors=v_errors where id=v_row.id;
    insert into public.sme_import_row_decision_versions(
      import_row_id,version,decision,reason,decided_by
    ) values(v_row.id,coalesce((select max(version)+1 from public.sme_import_row_decision_versions where import_row_id=v_row.id),1),
      case when v_status in ('valid','unmapped') then 'insert'
           when v_status='invalid' then 'skip' else 'review' end,
      'v86 normalized import analysis',v_actor);
  end loop;
  update public.sme_prospect_import_batches set valid_rows=v_valid,unmapped_rows=v_unmapped,
    conflict_rows=v_conflict,invalid_rows=v_invalid,skipped_rows=v_invalid where id=p_batch;
  insert into public.audit_log(business_id,actor,action,entity,entity_id,detail)
  values(null,v_actor,'SME_PROSPECT_IMPORT_ANALYSED_V86','sme_prospect_import_batches',p_batch,
    jsonb_build_object('valid_rows',v_valid,'unmapped_rows',v_unmapped,
      'conflict_rows',v_conflict,'invalid_rows',v_invalid));
  return jsonb_build_object('batch_id',p_batch,'valid_rows',v_valid,'unmapped_rows',v_unmapped,
    'conflict_rows',v_conflict,'invalid_rows',v_invalid);
end
$$;

create or replace function public.platform_stage_prospect_import_v86(
  p_source_system text,p_source_name text,p_column_mapping jsonb,p_rows jsonb,
  p_idempotency_key text
) returns jsonb language plpgsql security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare v_staged jsonb;v_analysis jsonb;v_batch uuid;
begin
  if not app.is_platform_operator_v75() then raise exception 'platform operator access is required' using errcode='42501';end if;
  v_staged:=public.platform_stage_prospect_import_v76(
    p_source_system,p_source_name,p_rows,p_idempotency_key
  );
  v_batch:=(v_staged->>'batch_id')::uuid;
  v_analysis:=public.platform_analyse_prospect_import_v86(v_batch,p_column_mapping);
  return v_staged||v_analysis||jsonb_build_object('mapping_applied',true);
end
$$;

create or replace function public.platform_decide_import_row_v86(
  p_import_row uuid,p_decision text,p_candidate_prospect uuid default null,p_reason text default null
) returns jsonb language plpgsql security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare v_actor uuid:=auth.uid();v_version integer;v_batch uuid;v_row public.sme_import_row_decision_versions%rowtype;
begin
  if not app.is_platform_operator_v75() then raise exception 'platform operator access is required' using errcode='42501';end if;
  select batch_id into v_batch from public.sme_prospect_import_rows where id=p_import_row;
  if v_batch is null or not exists(select 1 from public.sme_prospect_import_batches where id=v_batch and status='staged') then
    raise exception 'staged import row was not found' using errcode='22023';end if;
  if p_decision not in ('insert','skip','merge','review') then raise exception 'invalid import decision' using errcode='22023';end if;
  if p_decision='merge' and not exists(
    select 1 from public.sme_import_dedupe_candidates
     where import_row_id=p_import_row and candidate_prospect_id=p_candidate_prospect
  ) then raise exception 'merge requires a reviewed dedupe candidate' using errcode='22023';end if;
  select coalesce(max(version),0)+1 into v_version
    from public.sme_import_row_decision_versions where import_row_id=p_import_row;
  insert into public.sme_import_row_decision_versions(
    import_row_id,version,decision,candidate_prospect_id,reason,decided_by
  ) values(p_import_row,v_version,p_decision,p_candidate_prospect,nullif(btrim(p_reason),''),v_actor)
  returning * into v_row;
  insert into public.audit_log(business_id,actor,action,entity,entity_id,detail)
  values(null,v_actor,'SME_IMPORT_ROW_DECIDED_V86','sme_prospect_import_rows',p_import_row,
    jsonb_build_object('batch_id',v_batch,'decision',p_decision,
      'candidate_prospect_id',p_candidate_prospect,'version',v_version));
  return jsonb_build_object('decision',to_jsonb(v_row));
end
$$;

create or replace function public.platform_commit_prospect_import_v86(
  p_batch uuid
) returns jsonb language plpgsql security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare
  v_actor uuid:=auth.uid();v_batch public.sme_prospect_import_batches%rowtype;v_row record;
  v_company uuid;v_prospect uuid;v_contact uuid;v_source uuid;v_inserted integer:=0;v_merged integer:=0;v_skipped integer:=0;
begin
  if not app.is_platform_operator_v75() then raise exception 'platform operator access is required' using errcode='42501';end if;
  select * into v_batch from public.sme_prospect_import_batches where id=p_batch for update;
  if not found or v_batch.status<>'staged' then raise exception 'staged import batch was not found' using errcode='22023';end if;
  if exists(
    select 1 from public.sme_prospect_import_rows row
    left join lateral(
      select d.* from public.sme_import_row_decision_versions d where d.import_row_id=row.id order by d.version desc limit 1
    ) decision on true
    where row.batch_id=p_batch and (decision.id is null or decision.decision='review')
  ) then raise exception 'all import rows require a final insert, merge or skip decision' using errcode='22023';end if;
  for v_row in
    select row.*,decision.decision,decision.candidate_prospect_id
      from public.sme_prospect_import_rows row
      join lateral(
        select d.* from public.sme_import_row_decision_versions d where d.import_row_id=row.id order by d.version desc limit 1
      ) decision on true
     where row.batch_id=p_batch order by row.row_number for update of row
  loop
    if v_row.decision='skip' then v_skipped:=v_skipped+1;continue;end if;
    if v_row.decision='merge' then
      v_prospect:=v_row.candidate_prospect_id;
      select company_id into v_company from public.sme_prospects where id=v_prospect;
      insert into public.sme_prospect_source_lineage(
        prospect_id,source_system,source_type,external_id,detail,created_by
      ) values(v_prospect,v_batch.source_system,'import',null,
        jsonb_build_object('batch_id',p_batch,'row_number',v_row.row_number,
          'raw_payload',v_row.raw_payload,'merge_decision','reviewed_no_field_overwrite'),v_actor)
      returning id into v_source;
      insert into public.sme_import_commit_ledger(
        batch_id,import_row_id,decision,prospect_id,company_id,source_lineage_id,
        prospect_version_at_commit,committed_by
      ) select p_batch,v_row.id,'merge',prospect.id,prospect.company_id,v_source,prospect.version,v_actor
          from public.sme_prospects prospect where prospect.id=v_prospect;
      update public.sme_prospect_import_rows set row_status='imported',prospect_id=v_prospect where id=v_row.id;
      v_merged:=v_merged+1;continue;
    end if;
    insert into public.sme_companies(
      legal_name,trading_name,registration_number,industry,website,email,phone,address
    ) values(
      v_row.normalized_payload->>'company_name',v_row.normalized_payload->>'company_name',
      nullif(v_row.normalized_payload->>'registration_number',''),
      nullif(v_row.normalized_payload->>'industry',''),
      nullif(v_row.normalized_payload->>'website_domain',''),
      nullif(v_row.normalized_payload->>'email',''),
      nullif(v_row.normalized_payload->>'phone_e164',''),
      jsonb_build_object('registered_address',v_row.normalized_payload->>'address',
        'postal_code',v_row.normalized_payload->>'postal_code')
    ) returning id into v_company;
    insert into public.sme_prospects(
      company_id,current_stage_key,legacy_stage_raw,region,created_by,updated_by
    ) values(v_company,v_row.mapped_stage_key,
      case when v_row.mapped_stage_key is null then v_row.raw_stage end,
      nullif(v_row.normalized_payload->>'region',''),v_actor,v_actor)
    returning id into v_prospect;
    if nullif(v_row.normalized_payload->>'contact_name','') is not null and
       (nullif(v_row.normalized_payload->>'email','') is not null
         or nullif(v_row.normalized_payload->>'phone_e164','') is not null) then
      insert into public.sme_prospect_contacts(
        prospect_id,full_name,title,email,phone,is_primary
      ) values(v_prospect,v_row.normalized_payload->>'contact_name',
        nullif(v_row.normalized_payload->>'job_title',''),
        nullif(v_row.normalized_payload->>'email',''),
        nullif(v_row.normalized_payload->>'phone_e164',''),true) returning id into v_contact;
    end if;
    insert into public.sme_prospect_source_lineage(
      prospect_id,source_system,source_type,external_id,detail,created_by
    ) values(v_prospect,v_batch.source_system,'import',null,
      jsonb_build_object('batch_id',p_batch,'row_number',v_row.row_number,
        'raw_payload',v_row.raw_payload,'normalized_payload',v_row.normalized_payload),v_actor)
    returning id into v_source;
    if v_row.mapped_stage_key is not null then
      insert into public.sme_prospect_stage_history(prospect_id,to_stage_key,reason_code,actor)
      values(v_prospect,v_row.mapped_stage_key,'v86_import',v_actor);
    else
      insert into public.sme_prospect_data_quality_flags(prospect_id,flag_code,severity,detail)
      values(v_prospect,'unmapped_stage','warning','Legacy stage: '||coalesce(v_row.raw_stage,'(blank)'));
    end if;
    insert into public.sme_import_commit_ledger(
      batch_id,import_row_id,decision,prospect_id,company_id,source_lineage_id,
      prospect_version_at_commit,committed_by
    ) values(p_batch,v_row.id,'insert',v_prospect,v_company,v_source,1,v_actor);
    update public.sme_prospect_import_rows set row_status='imported',prospect_id=v_prospect where id=v_row.id;
    v_inserted:=v_inserted+1;
  end loop;
  update public.sme_prospect_import_batches set status='committed',imported_rows=v_inserted+v_merged,
    skipped_rows=v_skipped,committed_at=now() where id=p_batch;
  insert into public.audit_log(business_id,actor,action,entity,entity_id,detail)
  values(null,v_actor,'SME_PROSPECT_IMPORT_COMMITTED_V86','sme_prospect_import_batches',p_batch,
    jsonb_build_object('inserted_rows',v_inserted,'merged_rows',v_merged,'skipped_rows',v_skipped));
  return jsonb_build_object('batch_id',p_batch,'inserted_rows',v_inserted,
    'merged_rows',v_merged,'skipped_rows',v_skipped);
end
$$;

create or replace function public.platform_reverse_prospect_import_v86(
  p_batch uuid,p_reason text
) returns jsonb language plpgsql security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare
  v_actor uuid:=auth.uid();v_line record;v_inserted integer:=0;v_merged integer:=0;
  v_from_stage text;
begin
  if not app.is_super_admin() then raise exception 'super admin access is required' using errcode='42501';end if;
  if length(btrim(coalesce(p_reason,'')))<2 then raise exception 'reversal reason is required' using errcode='22023';end if;
  if not exists(select 1 from public.sme_prospect_import_batches where id=p_batch and status='committed' for update) then
    raise exception 'committed import batch was not found' using errcode='22023';end if;
  if exists(select 1 from public.sme_import_batch_reversals where batch_id=p_batch) then
    raise exception 'import batch is already reversed' using errcode='22023';end if;
  for v_line in select * from public.sme_import_commit_ledger where batch_id=p_batch order by committed_at desc
  loop
    insert into public.sme_import_reversal_rows(
      batch_id,import_row_id,prior_decision,prior_prospect_id,prior_company_id,prior_source_lineage_id
    ) values(p_batch,v_line.import_row_id,v_line.decision,v_line.prospect_id,
      v_line.company_id,v_line.source_lineage_id);
    if v_line.decision='merge' then
      update public.sme_prospect_import_rows set row_status='conflict',prospect_id=null where id=v_line.import_row_id;
      v_merged:=v_merged+1;continue;
    end if;
    if exists(select 1 from public.sme_prospects prospect
      where prospect.id=v_line.prospect_id and (
        prospect.version<>v_line.prospect_version_at_commit or prospect.converted_business_id is not null
        or exists(select 1 from public.sme_prospect_activities a where a.prospect_id=prospect.id)
        or exists(select 1 from public.sme_prospect_tasks t where t.prospect_id=prospect.id)
        or exists(select 1 from public.sme_commercial_terms c where c.prospect_id=prospect.id)
        or exists(select 1 from public.sme_document_versions d where d.prospect_id=prospect.id)
      )
    ) then raise exception 'import batch cannot reverse after a prospect was edited or used' using errcode='55000';end if;
    select current_stage_key into strict v_from_stage
      from public.sme_prospects where id=v_line.prospect_id for update;
    update public.sme_prospects set
      current_stage_key='lost',legacy_stage_raw=null,next_action_at=null,
      stage_entered_at=now(),version=version+1,updated_by=v_actor,updated_at=now()
      where id=v_line.prospect_id;
    insert into public.sme_prospect_stage_history(
      prospect_id,from_stage_key,to_stage_key,reason_code,reason_detail,actor
    ) values(
      v_line.prospect_id,v_from_stage,'lost','import_reversed',
      'Import reversal: '||btrim(p_reason),v_actor
    );
    update public.sme_prospect_import_rows
      set row_status='conflict',prospect_id=null where id=v_line.import_row_id;
    v_inserted:=v_inserted+1;
  end loop;
  insert into public.sme_import_batch_reversals(
    batch_id,reversed_by,reason,reversed_insert_rows,unlinked_merge_rows
  ) values(p_batch,v_actor,btrim(p_reason),v_inserted,v_merged);
  insert into public.audit_log(business_id,actor,action,entity,entity_id,detail)
  values(null,v_actor,'SME_PROSPECT_IMPORT_REVERSED_V86','sme_prospect_import_batches',p_batch,
    jsonb_build_object('reversed_insert_rows',v_inserted,'unlinked_merge_rows',v_merged,
      'reason',btrim(p_reason),'records_preserved_for_audit',true));
  return jsonb_build_object('batch_id',p_batch,'reversed_insert_rows',v_inserted,
    'unlinked_merge_rows',v_merged,'records_preserved_for_audit',true);
end
$$;

create or replace function public.platform_get_import_errors_v86(
  p_batch uuid,p_limit integer default 500,p_after_row integer default null
) returns jsonb language plpgsql stable security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare v_limit integer:=least(greatest(coalesce(p_limit,500),1),500);
begin
  if not app.is_platform_operator_v75() then raise exception 'platform operator access is required' using errcode='42501';end if;
  return jsonb_build_object(
    'batch_id',p_batch,
    'items',coalesce((select jsonb_agg(to_jsonb(page) order by page.row_number) from(
      select row.id import_row_id,row.row_number,row.row_status,row.errors,row.raw_payload,row.normalized_payload,
        (select to_jsonb(decision) from public.sme_import_row_decision_versions decision
          where decision.import_row_id=row.id order by decision.version desc limit 1) latest_decision,
        coalesce((select jsonb_agg(jsonb_build_object(
          'candidate_prospect_id',candidate.candidate_prospect_id,'match_basis',candidate.match_basis,
          'score',candidate.score) order by candidate.score desc)
          from public.sme_import_dedupe_candidates candidate where candidate.import_row_id=row.id),'[]'::jsonb) candidates
      from public.sme_prospect_import_rows row where row.batch_id=p_batch
        and (p_after_row is null or row.row_number>p_after_row)
        and (cardinality(row.errors)>0 or row.row_status in ('conflict','unmapped'))
      order by row.row_number limit v_limit
    ) page),'[]'::jsonb),
    'next_after_row',(select max(page.row_number) from(
      select row.row_number from public.sme_prospect_import_rows row where row.batch_id=p_batch
        and (p_after_row is null or row.row_number>p_after_row)
        and (cardinality(row.errors)>0 or row.row_status in ('conflict','unmapped'))
      order by row.row_number limit v_limit
    ) page),
    'download_format','csv_ready_json'
  );
end
$$;

create or replace function public.platform_get_import_batch_v86(
  p_batch uuid,p_limit integer default 100,p_after_row integer default null
) returns jsonb language plpgsql stable security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare v_limit integer:=least(greatest(coalesce(p_limit,100),1),250);
begin
  if not app.is_platform_operator_v75() then raise exception 'platform operator access is required' using errcode='42501';end if;
  if not exists(select 1 from public.sme_prospect_import_batches where id=p_batch) then
    raise exception 'import batch was not found' using errcode='22023';end if;
  return jsonb_build_object(
    'batch',(select to_jsonb(batch) from public.sme_prospect_import_batches batch where batch.id=p_batch),
    'reversal',(select to_jsonb(reversal) from public.sme_import_batch_reversals reversal where reversal.batch_id=p_batch),
    'mappings',coalesce((select jsonb_agg(to_jsonb(mapping) order by mapping.source_header)
      from public.sme_import_column_mappings mapping where mapping.batch_id=p_batch),'[]'::jsonb),
    'rows',coalesce((select jsonb_agg(to_jsonb(page) order by page.row_number) from(
      select row.id import_row_id,row.row_number,row.row_status,row.errors,row.raw_payload,
        row.normalized_payload,row.mapped_stage_key,row.prospect_id,
        (select to_jsonb(decision) from public.sme_import_row_decision_versions decision
          where decision.import_row_id=row.id order by decision.version desc limit 1) latest_decision,
        coalesce((select jsonb_agg(jsonb_build_object(
          'candidate_prospect_id',candidate.candidate_prospect_id,
          'match_basis',candidate.match_basis,'score',candidate.score,'evidence',candidate.evidence)
          order by candidate.score desc,candidate.candidate_prospect_id)
          from public.sme_import_dedupe_candidates candidate
          where candidate.import_row_id=row.id),'[]'::jsonb) candidates
      from public.sme_prospect_import_rows row where row.batch_id=p_batch
        and (p_after_row is null or row.row_number>p_after_row)
      order by row.row_number limit v_limit
    ) page),'[]'::jsonb),
    'next_after_row',(select max(page.row_number) from(
      select row.row_number from public.sme_prospect_import_rows row where row.batch_id=p_batch
        and (p_after_row is null or row.row_number>p_after_row)
      order by row.row_number limit v_limit
    ) page)
  );
end
$$;

create or replace function public.platform_rollback_prospect_import_v86(
  p_batch uuid,p_reason text
) returns jsonb language sql security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$ select public.platform_reverse_prospect_import_v86(p_batch,p_reason) $$;

create or replace function public.platform_list_prospects_v86(
  p_filters jsonb default '{}'::jsonb,p_snapshot_at timestamptz default null,
  p_limit integer default 100,p_after_updated_at timestamptz default null,p_after_id uuid default null
) returns jsonb language plpgsql stable security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare v_snapshot timestamptz:=coalesce(p_snapshot_at,clock_timestamp());v_limit integer:=least(greatest(coalesce(p_limit,100),1),250);
begin
  if not app.is_platform_operator_v75() then raise exception 'platform operator access is required' using errcode='42501';end if;
  perform app.v86_assert_object_keys(p_filters,array[
    'search','stage','owner','source','region','segment','priority','qualification',
    'next_action_from','next_action_to','onboarding_health'
  ],'prospect filters');
  if (p_after_updated_at is null)<>(p_after_id is null) then
    raise exception 'complete prospect cursor is required' using errcode='22023';end if;
  return jsonb_build_object(
    'snapshot_at',v_snapshot,
    'items',coalesce((select jsonb_agg(page.card order by page.updated_at desc,page.id desc) from(
      select prospect.id,prospect.updated_at,
        app.sme_prospect_card_v76(prospect.id)
        ||jsonb_build_object(
          'quality',(select to_jsonb(snapshot) from public.sme_data_quality_snapshots snapshot
            where snapshot.prospect_id=prospect.id and snapshot.evaluated_at<=v_snapshot
            order by snapshot.evaluated_at desc,snapshot.id desc limit 1),
          'qualification_status',qualification.qualification_status,
          'segment',coalesce(company_profile.customer_type,company_profile.employee_range),
          'onboarding_health',checklist.status
        ) card
      from public.sme_prospects prospect
      join public.sme_companies company on company.id=prospect.company_id
      left join lateral(select source.* from public.sme_prospect_source_lineage source
        where source.prospect_id=prospect.id order by source.created_at limit 1) source on true
      left join lateral(select profile.* from public.sme_company_profile_versions profile
        where profile.company_id=company.id and profile.created_at<=v_snapshot order by profile.version desc limit 1) company_profile on true
      left join lateral(select q.* from public.sme_qualification_detail_versions q
        where q.prospect_id=prospect.id and q.created_at<=v_snapshot order by q.version desc limit 1) qualification on true
      left join public.business_onboarding_checklists checklist
        on checklist.business_id=prospect.converted_business_id
      where prospect.created_at<=v_snapshot
        and (p_after_updated_at is null or (prospect.updated_at,prospect.id)<(p_after_updated_at,p_after_id))
        and (nullif(p_filters->>'stage','') is null or prospect.current_stage_key=p_filters->>'stage'
          or (p_filters->>'stage'='unmapped' and prospect.current_stage_key is null))
        and (nullif(p_filters->>'owner','') is null or prospect.assigned_consultant_id=(p_filters->>'owner')::uuid)
        and (nullif(p_filters->>'source','') is null or source.source_type=p_filters->>'source')
        and (nullif(p_filters->>'region','') is null or prospect.region=p_filters->>'region')
        and (nullif(p_filters->>'segment','') is null
          or coalesce(company_profile.customer_type,company_profile.employee_range)=p_filters->>'segment')
        and (nullif(p_filters->>'priority','') is null or prospect.priority=p_filters->>'priority')
        and (nullif(p_filters->>'qualification','') is null
          or qualification.qualification_status=p_filters->>'qualification')
        and (nullif(p_filters->>'onboarding_health','') is null
          or checklist.status=p_filters->>'onboarding_health')
        and (nullif(p_filters->>'next_action_from','') is null
          or prospect.next_action_at>=(p_filters->>'next_action_from')::timestamptz)
        and (nullif(p_filters->>'next_action_to','') is null
          or prospect.next_action_at<(p_filters->>'next_action_to')::timestamptz)
        and (nullif(p_filters->>'search','') is null
          or app.sme_prospect_search_match_v76(prospect.id,p_filters->>'search'))
      order by prospect.updated_at desc,prospect.id desc limit v_limit
    ) page),'[]'::jsonb),
    'next_cursor',(select jsonb_build_object('updated_at',page.updated_at,'id',page.id) from(
      select prospect.id,prospect.updated_at from public.sme_prospects prospect
      join public.sme_companies company on company.id=prospect.company_id
      left join lateral(select source.* from public.sme_prospect_source_lineage source
        where source.prospect_id=prospect.id order by source.created_at limit 1) source on true
      left join lateral(select profile.* from public.sme_company_profile_versions profile
        where profile.company_id=company.id and profile.created_at<=v_snapshot order by profile.version desc limit 1) company_profile on true
      left join lateral(select q.* from public.sme_qualification_detail_versions q
        where q.prospect_id=prospect.id and q.created_at<=v_snapshot order by q.version desc limit 1) qualification on true
      left join public.business_onboarding_checklists checklist on checklist.business_id=prospect.converted_business_id
      where prospect.created_at<=v_snapshot
        and (p_after_updated_at is null or (prospect.updated_at,prospect.id)<(p_after_updated_at,p_after_id))
        and (nullif(p_filters->>'stage','') is null or prospect.current_stage_key=p_filters->>'stage'
          or (p_filters->>'stage'='unmapped' and prospect.current_stage_key is null))
        and (nullif(p_filters->>'owner','') is null or prospect.assigned_consultant_id=(p_filters->>'owner')::uuid)
        and (nullif(p_filters->>'source','') is null or source.source_type=p_filters->>'source')
        and (nullif(p_filters->>'region','') is null or prospect.region=p_filters->>'region')
        and (nullif(p_filters->>'segment','') is null
          or coalesce(company_profile.customer_type,company_profile.employee_range)=p_filters->>'segment')
        and (nullif(p_filters->>'priority','') is null or prospect.priority=p_filters->>'priority')
        and (nullif(p_filters->>'qualification','') is null or qualification.qualification_status=p_filters->>'qualification')
        and (nullif(p_filters->>'onboarding_health','') is null or checklist.status=p_filters->>'onboarding_health')
        and (nullif(p_filters->>'next_action_from','') is null or prospect.next_action_at>=(p_filters->>'next_action_from')::timestamptz)
        and (nullif(p_filters->>'next_action_to','') is null or prospect.next_action_at<(p_filters->>'next_action_to')::timestamptz)
        and (nullif(p_filters->>'search','') is null or app.sme_prospect_search_match_v76(prospect.id,p_filters->>'search'))
      order by prospect.updated_at desc,prospect.id desc limit v_limit
    ) page order by page.updated_at,page.id limit 1)
  );
end
$$;

create or replace function public.platform_get_prospect_workspace_v86(
  p_prospect uuid,p_snapshot_at timestamptz default null
) returns jsonb language plpgsql stable security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare v_snapshot timestamptz:=coalesce(p_snapshot_at,clock_timestamp());v_business uuid;
begin
  if not app.is_platform_operator_v75() then raise exception 'platform operator access is required' using errcode='42501';end if;
  select converted_business_id into v_business from public.sme_prospects where id=p_prospect;
  return jsonb_build_object(
    'snapshot_at',v_snapshot,'prospect_id',p_prospect,'business_id',v_business,
    'business',(select to_jsonb(business) from public.businesses business where business.id=v_business),
    'branches',coalesce((select jsonb_agg(to_jsonb(branch) order by branch.is_default desc,branch.created_at)
      from public.branches branch where branch.business_id=v_business and branch.created_at<=v_snapshot),'[]'::jsonb),
    'subscription',(select to_jsonb(subscription) from public.subscriptions subscription
      where subscription.business_id=v_business and subscription.created_at<=v_snapshot
      order by subscription.created_at desc limit 1),
    'onboarding',(select jsonb_build_object(
      'checklist',to_jsonb(checklist),
      'items',coalesce((select jsonb_agg(to_jsonb(item) order by item.category,item.item_key)
        from public.business_onboarding_items item where item.checklist_id=checklist.id),'[]'::jsonb))
      from public.business_onboarding_checklists checklist where checklist.business_id=v_business),
    'configuration',(select to_jsonb(config) from public.sme_conversion_configuration_versions config
      where config.prospect_id=p_prospect and config.created_at<=v_snapshot order by config.version desc limit 1)
  );
end
$$;

-- ---------------------------------------------------------------------------
-- Weighted quality evaluation.
-- ---------------------------------------------------------------------------

create or replace function app.v86_quality_rule_pass(p_prospect uuid,p_rule text)
returns boolean language plpgsql stable security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare v_result boolean;
begin
  select case p_rule
    when 'company_name' then coalesce(company.legal_name,company.trading_name) is not null
    when 'registration_or_domain' then company.registration_number is not null
      or app.v86_normalize_domain(company.website) is not null
    when 'primary_contact' then exists(select 1 from public.sme_prospect_contacts c
      where c.prospect_id=prospect.id and c.active and c.is_primary)
    when 'valid_contact_method' then exists(select 1 from public.sme_prospect_contacts c
      where c.prospect_id=prospect.id and c.active and (
        lower(btrim(coalesce(c.email,'')))~'^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$'
        or app.v86_normalize_phone(c.phone) is not null))
    when 'source_attribution' then exists(select 1 from public.sme_prospect_source_lineage s where s.prospect_id=prospect.id)
    when 'assigned_owner' then prospect.assigned_consultant_id is not null
    when 'contact_basis' then exists(select 1 from public.sme_prospect_contacts c
      join lateral(select p.* from public.sme_contact_profile_versions p where p.contact_id=c.id order by p.version desc limit 1) profile on true
      where c.prospect_id=prospect.id and nullif(btrim(profile.consent_basis),'') is not null)
    when 'next_action' then prospect.next_action_at is not null
    when 'recent_activity' then exists(select 1 from public.sme_prospect_activities a
      where a.prospect_id=prospect.id and a.occurred_at>=now()-interval '30 days')
    when 'qualification' then exists(select 1 from public.sme_qualification_detail_versions q where q.prospect_id=prospect.id)
      or exists(select 1 from public.sme_prospect_qualification_versions q where q.prospect_id=prospect.id)
    when 'commercial_context' then exists(select 1 from public.sme_commercial_terms t where t.prospect_id=prospect.id)
      or exists(select 1 from public.sme_qualification_detail_versions q
        where q.prospect_id=prospect.id and q.expected_subscription_cents is not null)
    else false end into v_result
  from public.sme_prospects prospect join public.sme_companies company on company.id=prospect.company_id
  where prospect.id=p_prospect;
  return coalesce(v_result,false);
end
$$;
revoke all on function app.v86_quality_rule_pass(uuid,text) from public,anon,authenticated;

create or replace function public.platform_refresh_prospect_quality_v86(
  p_prospect uuid
) returns jsonb language plpgsql security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare v_actor uuid:=auth.uid();v_total integer;v_earned integer;v_rules jsonb;v_duplicates jsonb;v_snapshot public.sme_data_quality_snapshots%rowtype;
begin
  if not app.is_platform_operator_v75() then raise exception 'platform operator access is required' using errcode='42501';end if;
  if not exists(select 1 from public.sme_prospects where id=p_prospect) then raise exception 'prospect was not found' using errcode='22023';end if;
  with latest_rules as(
    select distinct on(rule_key) * from public.sme_data_quality_rule_versions
    order by rule_key,version desc
  ), evaluated as(
    select rule_key,label,weight,severity,app.v86_quality_rule_pass(p_prospect,rule_key) passed
    from latest_rules where active
  )
  select sum(weight),sum(weight) filter(where passed),
    jsonb_agg(jsonb_build_object('rule_key',rule_key,'label',label,'weight',weight,
      'severity',severity,'passed',passed) order by rule_key)
  into v_total,v_earned,v_rules from evaluated;
  select coalesce(jsonb_agg(flag order by flag->>'type'),'[]'::jsonb) into v_duplicates from(
    select distinct jsonb_build_object('type','duplicate_registration_number','prospect_id',other.id) flag
      from public.sme_prospects target join public.sme_companies company on company.id=target.company_id
      join public.sme_companies other_company on other_company.id<>company.id
        and company.registration_number is not null
        and lower(btrim(other_company.registration_number))=lower(btrim(company.registration_number))
      join public.sme_prospects other on other.company_id=other_company.id where target.id=p_prospect
    union all
    select distinct jsonb_build_object('type','duplicate_domain','prospect_id',other.id)
      from public.sme_prospects target join public.sme_companies company on company.id=target.company_id
      join public.sme_companies other_company on other_company.id<>company.id
        and app.v86_normalize_domain(company.website) is not null
        and app.v86_normalize_domain(other_company.website)=app.v86_normalize_domain(company.website)
      join public.sme_prospects other on other.company_id=other_company.id where target.id=p_prospect
  ) flags;
  insert into public.sme_data_quality_snapshots(
    prospect_id,score,earned_weight,total_weight,rule_results,duplicate_flags,evaluated_by
  ) values(p_prospect,round(100.0*coalesce(v_earned,0)/greatest(v_total,1))::smallint,
    coalesce(v_earned,0),v_total,v_rules,v_duplicates,v_actor) returning * into v_snapshot;
  return jsonb_build_object('snapshot',to_jsonb(v_snapshot));
end
$$;

-- ---------------------------------------------------------------------------
-- Finite snapshot/keyset detail, audit and analytics readers.
-- ---------------------------------------------------------------------------

create or replace function public.platform_get_prospect_detail_v86(
  p_prospect uuid,p_snapshot_at timestamptz default null,p_limit integer default 50
) returns jsonb language plpgsql stable security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare v_snapshot timestamptz:=coalesce(p_snapshot_at,clock_timestamp());v_limit integer:=least(greatest(coalesce(p_limit,50),1),100);
begin
  if not app.is_platform_operator_v75() then raise exception 'platform operator access is required' using errcode='42501';end if;
  if not exists(select 1 from public.sme_prospects where id=p_prospect and created_at<=v_snapshot) then
    raise exception 'prospect was not found' using errcode='22023';end if;
  return jsonb_build_object(
    'snapshot_at',v_snapshot,
    'prospect',(select to_jsonb(p) from public.sme_prospects p where p.id=p_prospect),
    'company',(select to_jsonb(c) from public.sme_companies c join public.sme_prospects p on p.company_id=c.id where p.id=p_prospect),
    'company_profile',(select to_jsonb(profile) from public.sme_company_profile_versions profile
      join public.sme_prospects p on p.company_id=profile.company_id
      where p.id=p_prospect and profile.created_at<=v_snapshot order by profile.version desc limit 1),
    'contacts',coalesce((select jsonb_agg(jsonb_build_object(
      'contact',to_jsonb(contact),'profile',(select to_jsonb(profile)
        from public.sme_contact_profile_versions profile where profile.contact_id=contact.id
          and profile.created_at<=v_snapshot order by profile.version desc limit 1))
      order by contact.is_primary desc,contact.created_at)
      from public.sme_prospect_contacts contact where contact.prospect_id=p_prospect
        and contact.created_at<=v_snapshot),'[]'::jsonb),
    'qualification',(select to_jsonb(q) from public.sme_qualification_detail_versions q
      where q.prospect_id=p_prospect and q.created_at<=v_snapshot order by q.version desc limit 1),
    'commercial_terms',(select jsonb_build_object('terms',to_jsonb(terms),
      'detail',(select to_jsonb(d) from public.sme_commercial_detail_versions d
        where d.commercial_terms_id=terms.id and d.created_at<=v_snapshot order by d.version desc limit 1))
      from public.sme_commercial_terms terms where terms.prospect_id=p_prospect
        and terms.created_at<=v_snapshot order by terms.version desc limit 1),
    'conversion_configuration',(select to_jsonb(config) from public.sme_conversion_configuration_versions config
      where config.prospect_id=p_prospect and config.created_at<=v_snapshot order by config.version desc limit 1),
    'activities',coalesce((select jsonb_agg(to_jsonb(page) order by page.occurred_at desc,page.id desc) from(
      select activity.*, (select to_jsonb(detail) from public.sme_activity_detail_versions detail
        where detail.activity_id=activity.id and detail.created_at<=v_snapshot order by detail.version desc limit 1) extended_detail
      from public.sme_prospect_activities activity where activity.prospect_id=p_prospect
        and activity.created_at<=v_snapshot order by activity.occurred_at desc,activity.id desc limit v_limit
    ) page),'[]'::jsonb),
    'documents',case when app.can_access_prospect_sensitive_v86(p_prospect) then
      coalesce((select jsonb_agg(to_jsonb(page)-'object_path' order by page.created_at desc,page.id desc) from(
        select document.* from public.sme_document_versions document where document.prospect_id=p_prospect
          and document.created_at<=v_snapshot order by document.created_at desc,document.id desc limit v_limit
      ) page),'[]'::jsonb) else '[]'::jsonb end,
    'stage_evidence',coalesce((select jsonb_agg(to_jsonb(page) order by page.created_at desc,page.id desc) from(
      select evidence.* from public.sme_stage_entry_evidence evidence where evidence.prospect_id=p_prospect
        and evidence.created_at<=v_snapshot order by evidence.created_at desc,evidence.id desc limit v_limit
    ) page),'[]'::jsonb),
    'data_quality',(select to_jsonb(snapshot) from public.sme_data_quality_snapshots snapshot
      where snapshot.prospect_id=p_prospect and snapshot.evaluated_at<=v_snapshot
      order by snapshot.evaluated_at desc,snapshot.id desc limit 1),
    'page_limit',v_limit
  );
end
$$;

create or replace function public.platform_list_prospect_audit_v86(
  p_prospect uuid,p_snapshot_at timestamptz default null,p_limit integer default 100,
  p_after_created_at timestamptz default null,p_after_id uuid default null
) returns jsonb language plpgsql stable security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare v_snapshot timestamptz:=coalesce(p_snapshot_at,clock_timestamp());v_limit integer:=least(greatest(coalesce(p_limit,100),1),200);
begin
  if not app.can_access_prospect_sensitive_v86(p_prospect) then
    raise exception 'assigned consultant or super admin access is required' using errcode='42501';end if;
  if (p_after_created_at is null)<>(p_after_id is null) then
    raise exception 'complete audit cursor is required' using errcode='22023';end if;
  return jsonb_build_object(
    'snapshot_at',v_snapshot,
    'items',coalesce((select jsonb_agg(to_jsonb(page) order by page.created_at desc,page.id desc) from(
      select audit.id,audit.actor,audit.action,audit.entity,audit.entity_id,audit.detail,audit.created_at
      from public.audit_log audit where audit.created_at<=v_snapshot and (
        (audit.entity='sme_prospects' and audit.entity_id=p_prospect)
        or audit.detail->>'prospect_id'=p_prospect::text
      ) and (p_after_created_at is null or (audit.created_at,audit.id)<(p_after_created_at,p_after_id))
      order by audit.created_at desc,audit.id desc limit v_limit
    ) page),'[]'::jsonb),
    'next_cursor',(select jsonb_build_object('created_at',page.created_at,'id',page.id) from(
      select audit.id,audit.created_at from public.audit_log audit where audit.created_at<=v_snapshot and (
        (audit.entity='sme_prospects' and audit.entity_id=p_prospect)
        or audit.detail->>'prospect_id'=p_prospect::text
      ) and (p_after_created_at is null or (audit.created_at,audit.id)<(p_after_created_at,p_after_id))
      order by audit.created_at desc,audit.id desc limit v_limit
    ) page order by page.created_at,page.id limit 1)
  );
end
$$;

create or replace function public.platform_get_sme_analytics_v86(
  p_from date,p_to date,p_snapshot_at timestamptz default null,
  p_consultant uuid default null,p_limit integer default 100,p_after_source text default null
) returns jsonb language plpgsql stable security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare
  v_snapshot timestamptz:=coalesce(p_snapshot_at,clock_timestamp());
  v_limit integer:=least(greatest(coalesce(p_limit,100),1),200);
  v_from timestamptz;v_to timestamptz;v_effective_consultant uuid:=p_consultant;
begin
  if not app.is_platform_operator_v75() then raise exception 'platform operator access is required' using errcode='42501';end if;
  if p_from is null or p_to is null or p_from>p_to or p_to-p_from>731 then
    raise exception 'analytics window must contain at most two years' using errcode='22023';end if;
  if not app.is_super_admin() then
    select id into v_effective_consultant from public.platform_consultants
      where user_id=auth.uid() and active;
  end if;
  v_from:=p_from::timestamp at time zone 'Asia/Singapore';
  v_to:=(p_to+1)::timestamp at time zone 'Asia/Singapore';
  return jsonb_build_object(
    'snapshot_at',v_snapshot,'scope',jsonb_build_object('from',p_from,'to',p_to,
      'consultant_id',v_effective_consultant),
    'summary',jsonb_build_object(
      'leads_created',(select count(*) from public.sme_prospects p where p.created_at>=v_from and p.created_at<v_to
        and p.created_at<=v_snapshot and (v_effective_consultant is null or p.assigned_consultant_id=v_effective_consultant)),
      'won',(select count(*) from public.sme_prospect_stage_history h join public.sme_prospects p on p.id=h.prospect_id
        where h.to_stage_key='client' and h.occurred_at>=v_from and h.occurred_at<v_to and h.occurred_at<=v_snapshot
          and (v_effective_consultant is null or p.assigned_consultant_id=v_effective_consultant)),
      'activated',(select count(*) from public.sme_prospect_stage_history h join public.sme_prospects p on p.id=h.prospect_id
        where h.to_stage_key='activated' and h.occurred_at>=v_from and h.occurred_at<v_to and h.occurred_at<=v_snapshot
          and (v_effective_consultant is null or p.assigned_consultant_id=v_effective_consultant)),
      'overdue_next_actions',(select count(*) from public.sme_prospects p where p.next_action_at<v_snapshot
        and p.current_stage_key not in ('lost','activated')
        and (v_effective_consultant is null or p.assigned_consultant_id=v_effective_consultant)),
      'pipeline_value_cents',(select coalesce(sum(terms.accepted_value_cents),0) from public.sme_commercial_terms terms
        join public.sme_prospects p on p.id=terms.prospect_id where terms.created_at<=v_snapshot
          and p.current_stage_key not in ('lost','activated')
          and (v_effective_consultant is null or p.assigned_consultant_id=v_effective_consultant))
    ),
    'stages',coalesce((select jsonb_agg(jsonb_build_object(
      'stage_key',stage.stage_key,'label',stage.label,'current_count',coalesce(metric.current_count,0),
      'entries',coalesce(metric.entries,0),'median_age_days',metric.median_age_days) order by stage.sort_order)
      from public.sme_pipeline_stages stage left join lateral(
        select
          (select count(*) from public.sme_prospects p where p.current_stage_key=stage.stage_key
            and p.created_at<=v_snapshot and (v_effective_consultant is null or p.assigned_consultant_id=v_effective_consultant)) current_count,
          count(*) entries,
          percentile_cont(.5) within group(order by greatest(0,
            extract(epoch from (least(v_snapshot,coalesce(next_event.occurred_at,v_snapshot))-history.occurred_at))/86400)) median_age_days
        from public.sme_prospect_stage_history history
        join public.sme_prospects p on p.id=history.prospect_id
        left join lateral(select h2.occurred_at from public.sme_prospect_stage_history h2
          where h2.prospect_id=history.prospect_id and (h2.occurred_at,h2.id)>(history.occurred_at,history.id)
          order by h2.occurred_at,h2.id limit 1) next_event on true
        where history.to_stage_key=stage.stage_key and history.occurred_at>=v_from
          and history.occurred_at<v_to and history.occurred_at<=v_snapshot
          and (v_effective_consultant is null or p.assigned_consultant_id=v_effective_consultant)
      ) metric on true),'[]'::jsonb),
    'source_page',coalesce((select jsonb_agg(to_jsonb(page) order by page.source_type) from(
      select source.source_type,count(distinct source.prospect_id) leads,
        count(distinct source.prospect_id) filter(where p.converted_business_id is not null) converted
      from public.sme_prospect_source_lineage source join public.sme_prospects p on p.id=source.prospect_id
      where source.created_at>=v_from and source.created_at<v_to and source.created_at<=v_snapshot
        and (p_after_source is null or source.source_type>p_after_source)
        and (v_effective_consultant is null or p.assigned_consultant_id=v_effective_consultant)
      group by source.source_type order by source.source_type limit v_limit
    ) page),'[]'::jsonb),
    'next_after_source',(select max(page.source_type) from(
      select source.source_type from public.sme_prospect_source_lineage source
      join public.sme_prospects p on p.id=source.prospect_id
      where source.created_at>=v_from and source.created_at<v_to and source.created_at<=v_snapshot
        and (p_after_source is null or source.source_type>p_after_source)
        and (v_effective_consultant is null or p.assigned_consultant_id=v_effective_consultant)
      group by source.source_type order by source.source_type limit v_limit
    ) page),
    'loss_reasons',coalesce((select jsonb_agg(jsonb_build_object('reason_code',history.reason_code,'count',history.count)
      order by history.count desc,history.reason_code) from(
      select h.reason_code,count(*) count from public.sme_prospect_stage_history h
      join public.sme_prospects p on p.id=h.prospect_id
      where h.to_stage_key='lost' and h.occurred_at>=v_from and h.occurred_at<v_to
        and h.occurred_at<=v_snapshot and (v_effective_consultant is null or p.assigned_consultant_id=v_effective_consultant)
      group by h.reason_code limit 50
    ) history),'[]'::jsonb),
    'contact_attempt_distribution',coalesce((select jsonb_agg(jsonb_build_object('attempts',attempts,'prospects',count)
      order by attempts) from(
      select attempts,count(*) from(
        select p.id,count(a.id)::integer attempts from public.sme_prospects p
        left join public.sme_prospect_activities a on a.prospect_id=p.id
          and a.activity_type in ('call','npu_attempt','whatsapp','email')
          and a.occurred_at>=v_from and a.occurred_at<v_to and a.occurred_at<=v_snapshot
        where p.created_at<=v_snapshot and (v_effective_consultant is null or p.assigned_consultant_id=v_effective_consultant)
        group by p.id
      ) attempts_by_prospect group by attempts
    ) distribution),'[]'::jsonb)
  );
end
$$;

-- Explicit function ACL. Trusted Storage signer access is service_role only.
revoke all on function public.platform_record_company_profile_v86(uuid,jsonb) from public,anon,authenticated;
revoke all on function public.platform_record_contact_profile_v86(uuid,jsonb) from public,anon,authenticated;
revoke all on function public.platform_record_qualification_v86(uuid,jsonb) from public,anon,authenticated;
revoke all on function public.platform_record_activity_detail_v86(uuid,jsonb) from public,anon,authenticated;
revoke all on function public.platform_record_commercial_detail_v86(uuid,jsonb) from public,anon,authenticated;
revoke all on function public.platform_record_conversion_configuration_v86(uuid,jsonb) from public,anon,authenticated;
revoke all on function public.platform_upsert_prospect_contact_v86(uuid,uuid,jsonb,jsonb,bigint,text) from public,anon,authenticated;
revoke all on function public.platform_move_prospect_stage_v86(uuid,text,bigint,jsonb,jsonb,text) from public,anon,authenticated;
revoke all on function public.platform_request_prospect_document_upload_v86(uuid,text,text,text,bigint,uuid,text) from public,anon,authenticated;
revoke all on function public.platform_request_prospect_document_read_v86(uuid) from public,anon,authenticated;
revoke all on function public.service_consume_document_signing_request_v86(uuid,text,uuid) from public,anon,authenticated;
revoke all on function public.service_get_consumed_document_upload_v86(uuid,uuid) from public,anon,authenticated;
revoke all on function public.service_finalize_document_upload_v86(uuid,text,bigint,uuid) from public,anon,authenticated;
revoke all on function public.platform_analyse_prospect_import_v86(uuid,jsonb) from public,anon,authenticated;
revoke all on function public.platform_stage_prospect_import_v86(text,text,jsonb,jsonb,text) from public,anon,authenticated;
revoke all on function public.platform_decide_import_row_v86(uuid,text,uuid,text) from public,anon,authenticated;
revoke all on function public.platform_commit_prospect_import_v86(uuid) from public,anon,authenticated;
revoke all on function public.platform_reverse_prospect_import_v86(uuid,text) from public,anon,authenticated;
revoke all on function public.platform_get_import_errors_v86(uuid,integer,integer) from public,anon,authenticated;
revoke all on function public.platform_get_import_batch_v86(uuid,integer,integer) from public,anon,authenticated;
revoke all on function public.platform_rollback_prospect_import_v86(uuid,text) from public,anon,authenticated;
revoke all on function public.platform_list_prospects_v86(jsonb,timestamptz,integer,timestamptz,uuid) from public,anon,authenticated;
revoke all on function public.platform_get_prospect_workspace_v86(uuid,timestamptz) from public,anon,authenticated;
revoke all on function public.platform_refresh_prospect_quality_v86(uuid) from public,anon,authenticated;
revoke all on function public.platform_get_prospect_detail_v86(uuid,timestamptz,integer) from public,anon,authenticated;
revoke all on function public.platform_list_prospect_audit_v86(uuid,timestamptz,integer,timestamptz,uuid) from public,anon,authenticated;
revoke all on function public.platform_get_sme_analytics_v86(date,date,timestamptz,uuid,integer,text) from public,anon,authenticated;

grant execute on function public.platform_record_company_profile_v86(uuid,jsonb) to authenticated;
grant execute on function public.platform_record_contact_profile_v86(uuid,jsonb) to authenticated;
grant execute on function public.platform_record_qualification_v86(uuid,jsonb) to authenticated;
grant execute on function public.platform_record_activity_detail_v86(uuid,jsonb) to authenticated;
grant execute on function public.platform_record_commercial_detail_v86(uuid,jsonb) to authenticated;
grant execute on function public.platform_record_conversion_configuration_v86(uuid,jsonb) to authenticated;
grant execute on function public.platform_upsert_prospect_contact_v86(uuid,uuid,jsonb,jsonb,bigint,text) to authenticated;
grant execute on function public.platform_move_prospect_stage_v86(uuid,text,bigint,jsonb,jsonb,text) to authenticated;
grant execute on function public.platform_request_prospect_document_upload_v86(uuid,text,text,text,bigint,uuid,text) to authenticated;
grant execute on function public.platform_request_prospect_document_read_v86(uuid) to authenticated;
grant execute on function public.platform_stage_prospect_import_v86(text,text,jsonb,jsonb,text) to authenticated;
grant execute on function public.platform_analyse_prospect_import_v86(uuid,jsonb) to authenticated;
grant execute on function public.platform_decide_import_row_v86(uuid,text,uuid,text) to authenticated;
grant execute on function public.platform_commit_prospect_import_v86(uuid) to authenticated;
grant execute on function public.platform_reverse_prospect_import_v86(uuid,text) to authenticated;
grant execute on function public.platform_get_import_errors_v86(uuid,integer,integer) to authenticated;
grant execute on function public.platform_get_import_batch_v86(uuid,integer,integer) to authenticated;
grant execute on function public.platform_rollback_prospect_import_v86(uuid,text) to authenticated;
grant execute on function public.platform_list_prospects_v86(jsonb,timestamptz,integer,timestamptz,uuid) to authenticated;
grant execute on function public.platform_get_prospect_workspace_v86(uuid,timestamptz) to authenticated;
grant execute on function public.platform_refresh_prospect_quality_v86(uuid) to authenticated;
grant execute on function public.platform_get_prospect_detail_v86(uuid,timestamptz,integer) to authenticated;
grant execute on function public.platform_list_prospect_audit_v86(uuid,timestamptz,integer,timestamptz,uuid) to authenticated;
grant execute on function public.platform_get_sme_analytics_v86(date,date,timestamptz,uuid,integer,text) to authenticated;
grant execute on function public.service_consume_document_signing_request_v86(uuid,text,uuid) to service_role;
grant execute on function public.service_get_consumed_document_upload_v86(uuid,uuid) to service_role;
grant execute on function public.service_finalize_document_upload_v86(uuid,text,bigint,uuid) to service_role;

commit;
