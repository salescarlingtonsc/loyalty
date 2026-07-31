-- NESTLY v108 — MEASURED BRING-BACK LOOP
--
-- One deliberately narrow closed-loop growth product:
--   trustworthy lapse evidence -> owner approval -> consent-aware in-app offer
--   -> deterministic treatment/holdout -> single-use QR entitlement
--   -> reversal-aware outcome -> confidence-qualified incremental revenue.
--
-- Financial figures are deterministic SQL outputs. This migration never claims
-- incremental profit because general cost-of-goods coverage is not yet complete.

begin;

insert into app.platform_feature_flags(feature_key, enabled)
values ('growth_closed_loop_v108', false)
on conflict (feature_key) do nothing;

create table public.growth_policies_v108 (
  business_id uuid primary key references public.businesses(id) on delete restrict,
  observation_days integer not null default 180 check (observation_days between 60 and 730),
  minimum_prior_visits integer not null default 3 check (minimum_prior_visits between 2 and 20),
  lapse_multiplier numeric(5,2) not null default 1.50 check (lapse_multiplier between 1.10 and 5.00),
  minimum_lapse_days integer not null default 14 check (minimum_lapse_days between 3 and 365),
  minimum_identity_coverage_bps integer not null default 6000
    check (minimum_identity_coverage_bps between 0 and 10000),
  minimum_audience integer not null default 20 check (minimum_audience between 10 and 5000),
  holdout_percent integer not null default 20 check (holdout_percent between 10 and 50),
  minimum_arm_size integer not null default 5 check (minimum_arm_size between 3 and 1000),
  frequency_cap_days integer not null default 30 check (frequency_cap_days between 7 and 365),
  attribution_days integer not null default 14 check (attribution_days between 3 and 90),
  default_credit_cents integer not null default 300 check (default_credit_cents between 100 and 2000),
  maximum_credit_cents integer not null default 1000 check (maximum_credit_cents between 100 and 5000),
  enabled boolean not null default true,
  policy_version text not null default 'bring_back_v1'
    check (policy_version ~ '^bring_back_v[0-9]+$'),
  updated_by uuid references auth.users(id) on delete restrict,
  updated_at timestamptz not null default now(),
  constraint growth_policies_v108_credit_check
    check (default_credit_cents <= maximum_credit_cents)
);

create table public.growth_recommendations_v108 (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete restrict,
  branch_id uuid,
  recommendation_type text not null check (recommendation_type = 'lapsed_high_value_bring_back'),
  policy_version text not null,
  generated_at timestamptz not null default statement_timestamp(),
  valid_until timestamptz not null,
  observation_start timestamptz not null,
  observation_end timestamptz not null,
  comparison_start timestamptz not null,
  comparison_end timestamptz not null,
  finding text not null check (length(btrim(finding)) between 1 and 1000),
  supporting_evidence jsonb not null check (jsonb_typeof(supporting_evidence) = 'array'),
  baseline jsonb not null check (jsonb_typeof(baseline) = 'object'),
  opportunity jsonb not null check (jsonb_typeof(opportunity) = 'object'),
  expected_incremental_revenue jsonb not null
    check (jsonb_typeof(expected_incremental_revenue) = 'object'),
  expected_incremental_gross_profit jsonb,
  confidence jsonb not null check (jsonb_typeof(confidence) = 'object'),
  assumptions jsonb not null check (jsonb_typeof(assumptions) = 'array'),
  recommended_action jsonb not null check (jsonb_typeof(recommended_action) = 'object'),
  recommended_channel text not null check (recommended_channel = 'in_app'),
  recommended_offer jsonb not null check (jsonb_typeof(recommended_offer) = 'object'),
  estimated_cost_cents bigint not null check (estimated_cost_cents >= 0),
  audience_size integer not null check (audience_size >= 0),
  excluded_size integer not null check (excluded_size >= 0),
  frequency_cap_days integer not null check (frequency_cap_days between 7 and 365),
  approval_required boolean not null default true check (approval_required),
  success_metric text not null check (success_metric = 'incremental_completed_purchase_revenue'),
  attribution_window_days integer not null check (attribution_window_days between 3 and 90),
  holdout_percent integer not null check (holdout_percent between 10 and 50),
  stop_conditions jsonb not null check (jsonb_typeof(stop_conditions) = 'object'),
  status text not null check (status in (
    'presented', 'suppressed', 'accepted', 'dismissed', 'expired', 'executed', 'completed'
  )),
  suppression_reasons jsonb not null default '[]'::jsonb
    check (jsonb_typeof(suppression_reasons) = 'array'),
  data_freshness_at timestamptz not null,
  data_coverage jsonb not null check (jsonb_typeof(data_coverage) = 'object'),
  dedupe_key text not null unique check (dedupe_key ~ '^[0-9a-f]{64}$'),
  created_by uuid,
  created_at timestamptz not null default now(),
  constraint growth_recommendations_v108_branch_business_fk
    foreign key (branch_id, business_id)
    references public.branches(id, business_id) on delete restrict,
  constraint growth_recommendations_v108_window_check check (
    observation_start < observation_end
    and comparison_start < comparison_end
    and valid_until > generated_at
  ),
  constraint growth_recommendations_v108_no_profit_claim check (
    expected_incremental_gross_profit is null
  ),
  constraint growth_recommendations_v108_id_business_uk unique (id, business_id)
);

create index growth_recommendations_v108_business_status_idx
  on public.growth_recommendations_v108
  (business_id, status, generated_at desc);

create table public.growth_recommendation_members_v108 (
  id uuid primary key default gen_random_uuid(),
  recommendation_id uuid not null,
  business_id uuid not null,
  client_id uuid not null,
  eligible boolean not null,
  exclusion_reason text check (
    exclusion_reason is null or exclusion_reason in (
      'not_lapsed', 'insufficient_history', 'no_verified_link', 'no_marketing_consent',
      'frequency_cap', 'active_experiment'
    )
  ),
  prior_visits integer not null check (prior_visits >= 0),
  last_visit_at timestamptz,
  cadence_days numeric(10,2),
  lapse_days integer,
  average_transaction_cents bigint not null default 0 check (average_transaction_cents >= 0),
  historical_revenue_cents bigint not null default 0 check (historical_revenue_cents >= 0),
  evidence jsonb not null check (jsonb_typeof(evidence) = 'object'),
  created_at timestamptz not null default now(),
  constraint growth_recommendation_members_v108_recommendation_fk
    foreign key (recommendation_id, business_id)
    references public.growth_recommendations_v108(id, business_id) on delete restrict,
  constraint growth_recommendation_members_v108_client_fk
    foreign key (business_id, client_id)
    references public.clients(business_id, id) on delete restrict,
  constraint growth_recommendation_members_v108_reason_check check (
    (eligible and exclusion_reason is null)
    or (not eligible and exclusion_reason is not null)
  ),
  constraint growth_recommendation_members_v108_member_uk
    unique (recommendation_id, client_id)
);

create index growth_recommendation_members_v108_preview_idx
  on public.growth_recommendation_members_v108
  (recommendation_id, eligible, historical_revenue_cents desc, client_id);

create table public.growth_recommendation_decisions_v108 (
  id uuid primary key default gen_random_uuid(),
  recommendation_id uuid not null,
  business_id uuid not null,
  decision text not null check (decision in ('accepted', 'dismissed', 'expired')),
  reason text check (reason is null or length(reason) <= 500),
  actor uuid not null references auth.users(id) on delete restrict,
  idempotency_key uuid not null,
  request_hash text not null check (request_hash ~ '^[0-9a-f]{64}$'),
  decided_at timestamptz not null default statement_timestamp(),
  created_at timestamptz not null default now(),
  constraint growth_recommendation_decisions_v108_recommendation_fk
    foreign key (recommendation_id, business_id)
    references public.growth_recommendations_v108(id, business_id) on delete restrict,
  constraint growth_recommendation_decisions_v108_one_decision_uk unique (recommendation_id),
  constraint growth_recommendation_decisions_v108_idempotency_uk
    unique (business_id, actor, idempotency_key)
);

create table public.growth_executions_v108 (
  id uuid primary key default gen_random_uuid(),
  recommendation_id uuid not null unique,
  business_id uuid not null references public.businesses(id) on delete restrict,
  branch_id uuid,
  channel text not null check (channel = 'in_app'),
  offer_type text not null check (offer_type = 'credit_cents'),
  offer_value_cents integer not null check (offer_value_cents between 100 and 5000),
  offer_label text not null check (
    offer_label in ('welcome_back', 'member_thank_you', 'simple_saving')
  ),
  currency text not null check (currency ~ '^[A-Z]{3}$'),
  offer_timezone text not null check (
    offer_timezone = btrim(offer_timezone)
    and length(offer_timezone) between 1 and 64
  ),
  offer_expires_at timestamptz not null,
  governed_copy_schema text not null default 'nestly.growth_offer_copy',
  governed_copy_version integer not null default 1 check (governed_copy_version = 1),
  governed_copy jsonb not null check (
    jsonb_typeof(governed_copy) = 'object'
    and governed_copy ?& array[
      'schema', 'version', 'title', 'body', 'cta_label', 'cta_destination',
      'eligibility', 'conditions', 'locked_facts'
    ]
    and governed_copy ->> 'schema' = governed_copy_schema
    and (governed_copy ->> 'version')::integer = governed_copy_version
    and governed_copy ->> 'cta_destination' = 'customer_growth_offer_qr'
    and governed_copy ->> 'cta_label' = 'Redeem now'
    and jsonb_typeof(governed_copy -> 'eligibility') = 'object'
    and jsonb_typeof(governed_copy -> 'conditions') = 'object'
    and jsonb_typeof(governed_copy -> 'locked_facts') = 'object'
    and governed_copy #>> '{locked_facts,template_id}' = offer_label
    and (governed_copy #>> '{locked_facts,offer_value_cents}')::integer
      = offer_value_cents
    and governed_copy #>> '{locked_facts,currency}' = currency
    and (governed_copy #>> '{locked_facts,expires_at}')::timestamptz
      = offer_expires_at
    and governed_copy #>> '{locked_facts,timezone}' = offer_timezone
    and (governed_copy #>> '{conditions,expires_at}')::timestamptz
      = offer_expires_at
    and governed_copy #>> '{conditions,timezone}' = offer_timezone
    and (governed_copy #>> '{eligibility,business_id}')::uuid = business_id
    and (governed_copy #>> '{eligibility,branch_id}')::uuid
      is not distinct from branch_id
  ),
  budget_cap_cents bigint not null check (budget_cap_cents >= 0),
  holdout_percent integer not null check (holdout_percent between 10 and 50),
  attribution_window_days integer not null check (attribution_window_days between 3 and 90),
  minimum_arm_size integer not null check (minimum_arm_size between 3 and 1000),
  status text not null default 'running'
    check (status in ('running', 'cancelled', 'completed')),
  approved_by uuid not null references auth.users(id) on delete restrict,
  approved_at timestamptz not null default statement_timestamp(),
  started_at timestamptz not null default statement_timestamp(),
  ends_at timestamptz not null,
  cancelled_at timestamptz,
  completed_at timestamptz,
  idempotency_key uuid not null,
  request_hash text not null check (request_hash ~ '^[0-9a-f]{64}$'),
  created_at timestamptz not null default now(),
  constraint growth_executions_v108_recommendation_fk
    foreign key (recommendation_id, business_id)
    references public.growth_recommendations_v108(id, business_id) on delete restrict,
  constraint growth_executions_v108_branch_business_fk
    foreign key (branch_id, business_id)
    references public.branches(id, business_id) on delete restrict,
  constraint growth_executions_v108_id_business_uk unique (id, business_id),
  constraint growth_executions_v108_idempotency_uk
    unique (business_id, approved_by, idempotency_key),
  constraint growth_executions_v108_window_check check (
    ends_at > started_at
    and offer_expires_at > started_at
    and offer_expires_at <= ends_at
  ),
  constraint growth_executions_v108_state_check check (
    (status = 'running' and cancelled_at is null and completed_at is null)
    or (status = 'cancelled' and cancelled_at is not null and completed_at is null)
    or (status = 'completed' and cancelled_at is null and completed_at is not null)
  )
);

create table public.growth_execution_members_v108 (
  id uuid primary key default gen_random_uuid(),
  execution_id uuid not null,
  business_id uuid not null,
  recommendation_member_id uuid not null unique,
  client_id uuid not null,
  assignment text not null check (assignment in ('treatment', 'holdout')),
  assignment_rank integer not null check (assignment_rank > 0),
  assignment_score text not null check (assignment_score ~ '^[0-9a-f]{64}$'),
  created_at timestamptz not null default now(),
  constraint growth_execution_members_v108_execution_fk
    foreign key (execution_id, business_id)
    references public.growth_executions_v108(id, business_id) on delete restrict,
  constraint growth_execution_members_v108_recommendation_member_fk
    foreign key (recommendation_member_id)
    references public.growth_recommendation_members_v108(id) on delete restrict,
  constraint growth_execution_members_v108_client_fk
    foreign key (business_id, client_id)
    references public.clients(business_id, id) on delete restrict,
  constraint growth_execution_members_v108_member_uk unique (execution_id, client_id),
  constraint growth_execution_members_v108_id_business_uk unique (id, business_id)
);

create index growth_execution_members_v108_client_idx
  on public.growth_execution_members_v108(business_id, client_id, execution_id);

create table public.growth_deliveries_v108 (
  id uuid primary key default gen_random_uuid(),
  execution_id uuid not null,
  execution_member_id uuid not null,
  business_id uuid not null,
  client_id uuid not null,
  identity_id uuid,
  link_id uuid,
  assignment text not null check (assignment in ('treatment', 'holdout')),
  channel text not null check (channel = 'in_app'),
  delivery_status text not null check (delivery_status in (
    'delivered', 'held_out', 'suppressed', 'failed', 'cancelled'
  )),
  suppression_reason text check (
    suppression_reason is null or suppression_reason in (
      'holdout', 'consent_withdrawn', 'quiet_hours', 'frequency_cap',
      'link_unavailable', 'budget_cap', 'execution_cancelled'
    )
  ),
  title text,
  body text,
  estimated_cost_cents integer not null default 0 check (estimated_cost_cents >= 0),
  delivered_at timestamptz,
  provider_message_id text,
  retry_count integer not null default 0 check (retry_count between 0 and 5),
  created_at timestamptz not null default now(),
  constraint growth_deliveries_v108_execution_fk
    foreign key (execution_id, business_id)
    references public.growth_executions_v108(id, business_id) on delete restrict,
  constraint growth_deliveries_v108_member_fk
    foreign key (execution_member_id, business_id)
    references public.growth_execution_members_v108(id, business_id) on delete restrict,
  constraint growth_deliveries_v108_client_fk
    foreign key (business_id, client_id)
    references public.clients(business_id, id) on delete restrict,
  constraint growth_deliveries_v108_link_fk
    foreign key (link_id, business_id, client_id)
    references public.customer_links(id, business_id, client_id) on delete restrict,
  constraint growth_deliveries_v108_identity_fk
    foreign key (identity_id)
    references public.customer_identities(id) on delete restrict,
  constraint growth_deliveries_v108_member_uk unique (execution_member_id),
  constraint growth_deliveries_v108_shape_check check (
    (delivery_status = 'delivered'
      and assignment = 'treatment'
      and identity_id is not null and link_id is not null
      and delivered_at is not null and suppression_reason is null
      and title is not null and body is not null)
    or (delivery_status = 'held_out'
      and assignment = 'holdout' and suppression_reason = 'holdout'
      and delivered_at is null and estimated_cost_cents = 0)
    or (delivery_status in ('suppressed', 'failed', 'cancelled')
      and suppression_reason is not null and delivered_at is null)
  )
);

create index growth_deliveries_v108_frequency_idx
  on public.growth_deliveries_v108
  (business_id, client_id, delivered_at desc)
  where delivery_status = 'delivered';

create table public.growth_entitlements_v108 (
  id uuid primary key default gen_random_uuid(),
  delivery_id uuid not null unique references public.growth_deliveries_v108(id) on delete restrict,
  execution_id uuid not null,
  business_id uuid not null,
  client_id uuid not null,
  identity_id uuid not null references public.customer_identities(id) on delete restrict,
  entitlement_type text not null check (entitlement_type = 'credit_cents'),
  value_cents integer not null check (value_cents between 100 and 5000),
  estimated_cost_cents integer not null check (estimated_cost_cents between 0 and 5000),
  status text not null default 'issued'
    check (status in ('issued', 'redeemed', 'expired', 'cancelled', 'reversed')),
  issued_at timestamptz not null default statement_timestamp(),
  expires_at timestamptz not null,
  redeemed_at timestamptz,
  redeemed_sale_id uuid,
  reversed_at timestamptz,
  created_at timestamptz not null default now(),
  constraint growth_entitlements_v108_execution_fk
    foreign key (execution_id, business_id)
    references public.growth_executions_v108(id, business_id) on delete restrict,
  constraint growth_entitlements_v108_client_fk
    foreign key (business_id, client_id)
    references public.clients(business_id, id) on delete restrict,
  constraint growth_entitlements_v108_sale_fk
    foreign key (redeemed_sale_id, business_id)
    references public.sales(id, business_id) on delete restrict,
  constraint growth_entitlements_v108_id_business_uk unique (id, business_id),
  constraint growth_entitlements_v108_expiry_check check (expires_at > issued_at),
  constraint growth_entitlements_v108_state_check check (
    (status = 'issued' and redeemed_at is null and redeemed_sale_id is null and reversed_at is null)
    or (status = 'redeemed' and redeemed_at is not null and redeemed_sale_id is not null and reversed_at is null)
    or (status = 'reversed' and redeemed_at is not null and redeemed_sale_id is not null and reversed_at is not null)
    or (status in ('expired', 'cancelled')
      and redeemed_at is null and redeemed_sale_id is null and reversed_at is null)
  )
);

create table public.growth_entitlement_events_v108 (
  id uuid primary key default gen_random_uuid(),
  entitlement_id uuid not null,
  business_id uuid not null,
  event_type text not null check (event_type in (
    'issued', 'qr_prepared', 'redeemed', 'expired', 'cancelled', 'reversed'
  )),
  actor uuid references auth.users(id) on delete restrict,
  sale_id uuid,
  idempotency_key uuid not null,
  detail jsonb not null default '{}'::jsonb check (jsonb_typeof(detail) = 'object'),
  occurred_at timestamptz not null default statement_timestamp(),
  created_at timestamptz not null default now(),
  constraint growth_entitlement_events_v108_entitlement_fk
    foreign key (entitlement_id, business_id)
    references public.growth_entitlements_v108(id, business_id) on delete restrict,
  constraint growth_entitlement_events_v108_sale_fk
    foreign key (sale_id, business_id)
    references public.sales(id, business_id) on delete restrict,
  constraint growth_entitlement_events_v108_idempotency_uk
    unique (entitlement_id, event_type, idempotency_key)
);

create table public.growth_redemption_intents_v108 (
  id uuid primary key default gen_random_uuid(),
  entitlement_id uuid not null,
  business_id uuid not null,
  identity_id uuid not null references public.customer_identities(id) on delete restrict,
  token_hash text not null unique check (token_hash ~ '^[0-9a-f]{64}$'),
  idempotency_key uuid not null,
  request_hash text not null check (request_hash ~ '^[0-9a-f]{64}$'),
  status text not null default 'pending'
    check (status in ('pending', 'completed', 'expired', 'cancelled')),
  expires_at timestamptz not null,
  completed_at timestamptz,
  created_at timestamptz not null default now(),
  constraint growth_redemption_intents_v108_entitlement_fk
    foreign key (entitlement_id, business_id)
    references public.growth_entitlements_v108(id, business_id) on delete restrict,
  constraint growth_redemption_intents_v108_idempotency_uk
    unique (identity_id, idempotency_key),
  constraint growth_redemption_intents_v108_state_check check (
    (status = 'pending' and completed_at is null)
    or (status = 'completed' and completed_at is not null)
    or (status in ('expired', 'cancelled') and completed_at is null)
  )
);

create table public.growth_outcomes_v108 (
  id uuid primary key default gen_random_uuid(),
  execution_id uuid not null,
  execution_member_id uuid not null,
  business_id uuid not null,
  client_id uuid not null,
  sale_id uuid not null,
  assignment text not null check (assignment in ('treatment', 'holdout')),
  outcome_kind text not null check (outcome_kind = 'qualifying_purchase'),
  occurred_at timestamptz not null,
  revenue_cents bigint not null,
  overlap_count integer not null default 1 check (overlap_count >= 1),
  causal_eligible boolean not null,
  created_at timestamptz not null default now(),
  constraint growth_outcomes_v108_execution_fk
    foreign key (execution_id, business_id)
    references public.growth_executions_v108(id, business_id) on delete restrict,
  constraint growth_outcomes_v108_member_fk
    foreign key (execution_member_id, business_id)
    references public.growth_execution_members_v108(id, business_id) on delete restrict,
  constraint growth_outcomes_v108_sale_fk
    foreign key (sale_id, business_id)
    references public.sales(id, business_id) on delete restrict,
  constraint growth_outcomes_v108_first_member_outcome_uk
    unique (execution_id, client_id),
  constraint growth_outcomes_v108_sale_execution_uk
    unique (execution_id, sale_id)
);

create table public.growth_execution_results_v108 (
  id uuid primary key default gen_random_uuid(),
  execution_id uuid not null unique,
  business_id uuid not null,
  policy_version text not null,
  result jsonb not null check (jsonb_typeof(result) = 'object'),
  prediction jsonb not null check (jsonb_typeof(prediction) = 'object'),
  calibration jsonb not null check (jsonb_typeof(calibration) = 'object'),
  result_status text not null check (result_status in (
    'inconclusive', 'invalid', 'won', 'neutral', 'lost'
  )),
  finalized_by uuid not null references auth.users(id) on delete restrict,
  idempotency_key uuid not null,
  request_hash text not null check (request_hash ~ '^[0-9a-f]{64}$'),
  finalized_at timestamptz not null default statement_timestamp(),
  created_at timestamptz not null default now(),
  constraint growth_execution_results_v108_execution_fk
    foreign key (execution_id, business_id)
    references public.growth_executions_v108(id, business_id) on delete restrict,
  constraint growth_execution_results_v108_actor_idem_uk
    unique (business_id, finalized_by, idempotency_key)
);

create unique index growth_entitlement_events_v108_redeem_actor_idem_uidx
  on public.growth_entitlement_events_v108(
    business_id, actor, event_type, idempotency_key
  )
  where actor is not null and event_type = 'redeemed';

insert into app.v89_token_secrets(secret_key, secret_value)
values ('growth_redemption_v108', extensions.gen_random_bytes(32))
on conflict (secret_key) do nothing;

alter table public.growth_policies_v108 enable row level security;
alter table public.growth_recommendations_v108 enable row level security;
alter table public.growth_recommendation_members_v108 enable row level security;
alter table public.growth_recommendation_decisions_v108 enable row level security;
alter table public.growth_executions_v108 enable row level security;
alter table public.growth_execution_members_v108 enable row level security;
alter table public.growth_deliveries_v108 enable row level security;
alter table public.growth_entitlements_v108 enable row level security;
alter table public.growth_entitlement_events_v108 enable row level security;
alter table public.growth_redemption_intents_v108 enable row level security;
alter table public.growth_outcomes_v108 enable row level security;
alter table public.growth_execution_results_v108 enable row level security;

revoke all privileges on table public.growth_policies_v108,
  public.growth_recommendations_v108, public.growth_recommendation_members_v108,
  public.growth_recommendation_decisions_v108, public.growth_executions_v108,
  public.growth_execution_members_v108, public.growth_deliveries_v108,
  public.growth_entitlements_v108, public.growth_entitlement_events_v108,
  public.growth_redemption_intents_v108, public.growth_outcomes_v108,
  public.growth_execution_results_v108
from public, anon, authenticated;

grant select on table public.growth_policies_v108,
  public.growth_recommendations_v108, public.growth_recommendation_members_v108,
  public.growth_recommendation_decisions_v108, public.growth_executions_v108,
  public.growth_execution_members_v108, public.growth_deliveries_v108,
  public.growth_entitlements_v108, public.growth_entitlement_events_v108,
  public.growth_outcomes_v108, public.growth_execution_results_v108
to authenticated;

create policy growth_policies_v108_finance_read on public.growth_policies_v108
  for select to authenticated using (
    app.has_perm(business_id, 'view_finance')
    and app.can_module_read(business_id, 'retention')
    and app.can_see_branch(business_id, null)
  );
create policy growth_policies_v108_sa_read on public.growth_policies_v108
  for select to authenticated using (app.is_super_admin());

create policy growth_recommendations_v108_finance_read on public.growth_recommendations_v108
  for select to authenticated using (
    app.has_perm(business_id, 'view_finance')
    and app.can_module_read(business_id, 'retention')
    and app.can_see_branch(business_id, branch_id)
  );
create policy growth_recommendations_v108_sa_read on public.growth_recommendations_v108
  for select to authenticated using (app.is_super_admin());

do $growth_v108_read_policies$
declare
  v_table text;
  v_scope_sql text;
begin
  foreach v_table in array array[
    'growth_recommendation_members_v108', 'growth_recommendation_decisions_v108',
    'growth_executions_v108', 'growth_execution_members_v108', 'growth_deliveries_v108',
    'growth_entitlements_v108', 'growth_entitlement_events_v108',
    'growth_outcomes_v108', 'growth_execution_results_v108'
  ] loop
    v_scope_sql := case
      when v_table = 'growth_executions_v108' then
        'app.can_see_branch(business_id, branch_id)'
      when v_table in ('growth_recommendation_members_v108', 'growth_recommendation_decisions_v108') then
        format('exists (
          select 1 from public.growth_recommendations_v108 scope_row
          where scope_row.id = %1$I.recommendation_id
            and scope_row.business_id = %1$I.business_id
            and app.can_see_branch(scope_row.business_id, scope_row.branch_id)
        )', v_table)
      when v_table in ('growth_execution_members_v108', 'growth_deliveries_v108',
                       'growth_entitlements_v108', 'growth_outcomes_v108',
                       'growth_execution_results_v108') then
        format('exists (
          select 1 from public.growth_executions_v108 scope_row
          where scope_row.id = %1$I.execution_id
            and scope_row.business_id = %1$I.business_id
            and app.can_see_branch(scope_row.business_id, scope_row.branch_id)
        )', v_table)
      when v_table = 'growth_entitlement_events_v108' then
        'exists (
          select 1
          from public.growth_entitlements_v108 entitlement_scope
          join public.growth_executions_v108 execution_scope
            on execution_scope.id = entitlement_scope.execution_id
           and execution_scope.business_id = entitlement_scope.business_id
          where entitlement_scope.id = growth_entitlement_events_v108.entitlement_id
            and entitlement_scope.business_id = growth_entitlement_events_v108.business_id
            and app.can_see_branch(execution_scope.business_id, execution_scope.branch_id)
        )'
    end;
    execute format(
      'create policy %1$I_finance_read on public.%1$I for select to authenticated using (
         app.has_perm(business_id, ''view_finance'')
         and app.can_module_read(business_id, ''retention'')
         and (%2$s)
       )', v_table, v_scope_sql
    );
    execute format(
      'create policy %1$I_sa_read on public.%1$I for select to authenticated using (
         app.is_super_admin()
       )', v_table
    );
  end loop;
end $growth_v108_read_policies$;

create or replace function app.growth_v108_immutable()
returns trigger language plpgsql security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
begin
  raise exception 'growth evidence is append-only' using errcode = '23000';
end $$;

create or replace function app.growth_v108_guard_status()
returns trigger language plpgsql security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
begin
  if tg_op = 'DELETE' then
    raise exception 'growth lifecycle rows cannot be deleted' using errcode = '23000';
  end if;
  if new.id is distinct from old.id
     or new.business_id is distinct from old.business_id
     or new.created_at is distinct from old.created_at then
    raise exception 'growth row identity is immutable' using errcode = '23000';
  end if;
  return new;
end $$;

create or replace function app.growth_v108_guard_outcome_residual()
returns trigger language plpgsql security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
begin
  if tg_op = 'DELETE'
     or pg_trigger_depth() < 2
     or (to_jsonb(new) - 'revenue_cents')
          is distinct from (to_jsonb(old) - 'revenue_cents')
     or new.revenue_cents is distinct from
          app.v106_sale_residual_minor(old.sale_id, clock_timestamp()) then
    raise exception 'growth evidence is append-only' using errcode = '23000';
  end if;
  return new;
end $$;

create trigger growth_recommendation_members_v108_immutable
  before update or delete on public.growth_recommendation_members_v108
  for each row execute function app.growth_v108_immutable();
create trigger growth_recommendation_decisions_v108_immutable
  before update or delete on public.growth_recommendation_decisions_v108
  for each row execute function app.growth_v108_immutable();
create trigger growth_execution_members_v108_immutable
  before update or delete on public.growth_execution_members_v108
  for each row execute function app.growth_v108_immutable();
create trigger growth_deliveries_v108_immutable
  before update or delete on public.growth_deliveries_v108
  for each row execute function app.growth_v108_immutable();
create trigger growth_entitlement_events_v108_immutable
  before update or delete on public.growth_entitlement_events_v108
  for each row execute function app.growth_v108_immutable();
create trigger growth_outcomes_v108_immutable
  before update or delete on public.growth_outcomes_v108
  for each row execute function app.growth_v108_guard_outcome_residual();
create trigger growth_execution_results_v108_immutable
  before update or delete on public.growth_execution_results_v108
  for each row execute function app.growth_v108_immutable();

create trigger growth_recommendations_v108_guard
  before update or delete on public.growth_recommendations_v108
  for each row execute function app.growth_v108_guard_status();
create trigger growth_executions_v108_guard
  before update or delete on public.growth_executions_v108
  for each row execute function app.growth_v108_guard_status();
create trigger growth_entitlements_v108_guard
  before update or delete on public.growth_entitlements_v108
  for each row execute function app.growth_v108_guard_status();
create trigger growth_redemption_intents_v108_guard
  before update or delete on public.growth_redemption_intents_v108
  for each row execute function app.growth_v108_guard_status();

create or replace function app.growth_v108_token(
  p_identity uuid,
  p_business uuid,
  p_entitlement uuid,
  p_idempotency uuid
)
returns text language sql stable security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
  select encode(extensions.hmac(
    convert_to(concat_ws(':', p_identity, p_business, p_entitlement, p_idempotency), 'UTF8'),
    secret.secret_value, 'sha256'), 'hex')
  from app.v89_token_secrets secret
  where secret.secret_key = 'growth_redemption_v108'
$$;

create or replace function app.growth_v108_effective_parameters(p_business uuid)
returns jsonb language sql stable security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
  select jsonb_build_object(
    'source', 'growth_policy_v108',
    'lineage', jsonb_build_object(
      'policy_version', p.policy_version,
      'updated_at', p.updated_at
    ),
    'parameters', jsonb_build_object(
      'minimum_prior_visits', p.minimum_prior_visits,
      'cadence_multiplier', p.lapse_multiplier,
      'minimum_lapse_days', p.minimum_lapse_days,
      'minimum_audience', p.minimum_audience
    ),
    'suppression_reasons', '[]'::jsonb
  )
  from public.growth_policies_v108 p
  where p.business_id = p_business
$$;

create or replace function public.refresh_growth_recommendation_v108(
  p_business uuid,
  p_branch uuid default null
)
returns jsonb language plpgsql security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_actor uuid := auth.uid();
  v_now timestamptz := statement_timestamp();
  v_policy public.growth_policies_v108%rowtype;
  v_recommendation uuid := gen_random_uuid();
  v_total_revenue bigint := 0;
  v_identified_revenue bigint := 0;
  v_total_sales integer := 0;
  v_identified_sales integer := 0;
  v_coverage_bps integer := 0;
  v_eligible integer := 0;
  v_excluded integer := 0;
  v_avg_value bigint := 0;
  v_confidence_bps integer := 0;
  v_status text;
  v_suppressions jsonb := '[]'::jsonb;
  v_dedupe text;
  v_existing uuid;
  v_member_fingerprint text;
  v_currency text;
  v_effective_policy jsonb;
begin
  if v_actor is null or (
     not app.is_super_admin()
     and (
       not app.has_perm(p_business, 'view_finance')
       or not app.can_module_read(p_business, 'retention')
     )
  ) then
    raise exception 'finance and retention access required' using errcode = '42501';
  end if;
  if not app.can_see_branch(p_business, p_branch) then
    raise exception 'branch is outside actor scope' using errcode = '42501';
  end if;
  if p_branch is not null and not exists (
    select 1 from public.branches b where b.id = p_branch and b.business_id = p_business
  ) then
    raise exception 'branch does not belong to business' using errcode = '22023';
  end if;
  if not app.platform_feature_enabled('growth_closed_loop_v108') then
    raise exception 'growth closed loop is not enabled' using errcode = '0A000';
  end if;
  select upper(currency) into strict v_currency
  from public.businesses where id = p_business;

  insert into public.growth_policies_v108(business_id, updated_by)
  values (p_business, v_actor)
  on conflict (business_id) do nothing;
  select * into v_policy from public.growth_policies_v108 where business_id = p_business;
  v_effective_policy := app.growth_v108_effective_parameters(p_business);

  select
    coalesce(sum(app.v106_sale_residual_minor(s.id, v_now))
      filter (where s.counts_as_revenue), 0),
    coalesce(sum(app.v106_sale_residual_minor(s.id, v_now)) filter (
      where s.counts_as_revenue and s.client_id is not null
    ), 0),
    count(*) filter (where s.counts_as_revenue),
    count(*) filter (where s.counts_as_revenue and s.client_id is not null)
  into v_total_revenue, v_identified_revenue, v_total_sales, v_identified_sales
  from public.sales s
  where s.business_id = p_business
    and (p_branch is null or s.branch_id = p_branch)
    and s.occurred_at >= v_now - interval '90 days'
    and s.occurred_at < v_now
    and s.reversal_of is null
    and not exists (
      select 1 from public.sales r
      where r.business_id = s.business_id and r.reversal_of = s.id
    );

  v_coverage_bps := case when v_total_revenue > 0
    then least(10000, (v_identified_revenue * 10000 / v_total_revenue)::integer)
    else 0 end;

  create temporary table if not exists pg_temp.growth_candidates_v108 (
    client_id uuid primary key,
    prior_visits integer,
    last_visit_at timestamptz,
    cadence_days numeric,
    lapse_days integer,
    average_transaction_cents bigint,
    historical_revenue_cents bigint,
    eligible boolean,
    exclusion_reason text
  ) on commit drop;
  truncate pg_temp.growth_candidates_v108;

  insert into pg_temp.growth_candidates_v108
  with visits as (
    select s.client_id, s.occurred_at,
      app.v106_sale_residual_minor(s.id, v_now) as amount_cents,
      extract(epoch from (
        s.occurred_at - lag(s.occurred_at) over (
          partition by s.client_id order by s.occurred_at, s.id
        )
      )) / 86400.0 as interval_days
    from public.sales s
    where s.business_id = p_business
      and (p_branch is null or s.branch_id = p_branch)
      and s.client_id is not null
      and s.counts_as_visit
      and s.reversal_of is null
      and app.v106_sale_residual_minor(s.id, v_now) > 0
      and s.occurred_at >= v_now - make_interval(days => v_policy.observation_days)
      and s.occurred_at < v_now
      and not exists (
        select 1 from public.sales r
        where r.business_id = s.business_id and r.reversal_of = s.id
      )
  ),
  metrics as (
    select v.client_id,
      count(*)::integer as prior_visits,
      max(v.occurred_at) as last_visit_at,
      percentile_cont(0.5) within group (order by v.interval_days)
        filter (where v.interval_days is not null) as cadence_days,
      floor(extract(epoch from (v_now - max(v.occurred_at))) / 86400)::integer as lapse_days,
      round(avg(v.amount_cents))::bigint as average_transaction_cents,
      sum(v.amount_cents)::bigint as historical_revenue_cents
    from visits v
    group by v.client_id
  ),
  judged as (
    select m.*,
      case
        when m.prior_visits <
          (v_effective_policy #>> '{parameters,minimum_prior_visits}')::integer
          then 'insufficient_history'
        when m.cadence_days is null then 'insufficient_history'
        when m.lapse_days < greatest(
          (v_effective_policy #>> '{parameters,minimum_lapse_days}')::integer,
          ceil(m.cadence_days
            * (v_effective_policy #>> '{parameters,cadence_multiplier}')::numeric
          )::integer
        ) then 'not_lapsed'
        when not exists (
          select 1 from public.customer_links l
          where l.business_id = p_business and l.client_id = m.client_id
            and l.state = 'verified'
        ) then 'no_verified_link'
        when not exists (
          select 1
          from public.customer_notification_preferences p
          join public.customer_links l
            on l.id = p.link_id and l.business_id = p.business_id
          where p.business_id = p_business and p.client_id = m.client_id
            and p.channel = 'in_app' and p.topic = 'marketing'
            and p.opted_in and l.state = 'verified'
        ) then 'no_marketing_consent'
        when exists (
          select 1 from public.growth_deliveries_v108 d
          where d.business_id = p_business and d.client_id = m.client_id
            and d.delivery_status = 'delivered'
            and d.delivered_at >= v_now - make_interval(days => v_policy.frequency_cap_days)
        ) then 'frequency_cap'
        when exists (
          select 1
          from public.growth_execution_members_v108 em
          join public.growth_executions_v108 e on e.id = em.execution_id
          where em.business_id = p_business and em.client_id = m.client_id
            and e.status = 'running' and e.ends_at > v_now
        ) then 'active_experiment'
        else null
      end as exclusion_reason
    from metrics m
  )
  select j.client_id, j.prior_visits, j.last_visit_at, j.cadence_days,
    j.lapse_days, j.average_transaction_cents, j.historical_revenue_cents,
    j.exclusion_reason is null, j.exclusion_reason
  from judged j;

  select count(*) filter (where eligible), count(*) filter (where not eligible),
    coalesce(round(avg(average_transaction_cents) filter (where eligible)), 0)::bigint
  into v_eligible, v_excluded, v_avg_value
  from pg_temp.growth_candidates_v108;

  v_confidence_bps := least(9500,
    greatest(0, v_coverage_bps * 7 / 10)
      + least(2500, v_eligible * 100)
  );

  if not v_policy.enabled then
    v_suppressions := v_suppressions || jsonb_build_array('policy_disabled');
  end if;
  if v_total_sales < 50 then
    v_suppressions := v_suppressions || jsonb_build_array('cold_start_under_50_sales');
  end if;
  if v_coverage_bps < v_policy.minimum_identity_coverage_bps then
    v_suppressions := v_suppressions || jsonb_build_array('identity_coverage_below_threshold');
  end if;
  if v_eligible < (v_effective_policy #>> '{parameters,minimum_audience}')::integer then
    v_suppressions := v_suppressions || jsonb_build_array('audience_below_minimum');
  end if;
  v_suppressions := v_suppressions
    || coalesce(v_effective_policy -> 'suppression_reasons', '[]'::jsonb);
  if floor(v_eligible * v_policy.holdout_percent / 100.0) < v_policy.minimum_arm_size
     or v_eligible - floor(v_eligible * v_policy.holdout_percent / 100.0)
        < v_policy.minimum_arm_size then
    v_suppressions := v_suppressions || jsonb_build_array('experiment_arms_too_small');
  end if;
  v_status := case when jsonb_array_length(v_suppressions) = 0
    then 'presented' else 'suppressed' end;

  select encode(extensions.digest(convert_to(
    coalesce(jsonb_agg(jsonb_build_array(
      c.client_id, c.eligible, c.exclusion_reason, c.prior_visits,
      c.last_visit_at, round(c.cadence_days, 2), c.lapse_days,
      c.average_transaction_cents, c.historical_revenue_cents
    ) order by c.client_id)::text, '[]'), 'UTF8'
  ), 'sha256'), 'hex')
  into v_member_fingerprint
  from pg_temp.growth_candidates_v108 c;

  v_dedupe := encode(extensions.digest(convert_to(concat_ws(':',
    'v108', p_business, coalesce(p_branch::text, 'all'), v_policy.policy_version,
    date_trunc('day', v_now)::text, v_status,
    v_currency, v_total_sales, v_identified_sales, v_total_revenue,
    v_identified_revenue, v_eligible, v_excluded, v_avg_value,
    v_policy.default_credit_cents, v_policy.maximum_credit_cents,
    v_policy.frequency_cap_days, v_policy.attribution_days,
    v_policy.minimum_arm_size, v_policy.holdout_percent,
    v_member_fingerprint, v_effective_policy::text
  ), 'UTF8'), 'sha256'), 'hex');

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended('growth-v108-refresh:' || v_dedupe, 0)
  );
  select r.id into v_existing
  from public.growth_recommendations_v108 r where r.dedupe_key = v_dedupe;
  if found then
    return jsonb_build_object('recommendation_id', v_existing, 'replayed', true);
  end if;

  insert into public.growth_recommendations_v108(
    id, business_id, branch_id, recommendation_type, policy_version,
    generated_at, valid_until, observation_start, observation_end,
    comparison_start, comparison_end, finding, supporting_evidence, baseline,
    opportunity, expected_incremental_revenue, expected_incremental_gross_profit,
    confidence, assumptions, recommended_action, recommended_channel,
    recommended_offer, estimated_cost_cents, audience_size, excluded_size,
    success_metric, frequency_cap_days, attribution_window_days, holdout_percent,
    stop_conditions,
    status, suppression_reasons, data_freshness_at, data_coverage, dedupe_key, created_by
  ) values (
    v_recommendation, p_business, p_branch, 'lapsed_high_value_bring_back',
    v_policy.policy_version, v_now, v_now + interval '24 hours',
    v_now - make_interval(days => v_policy.observation_days), v_now,
    v_now - interval '180 days', v_now - interval '90 days',
    case when v_status = 'presented'
      then v_eligible || ' previously active customers are beyond their observed visit cadence.'
      else 'No reliable bring-back action is available yet.' end,
    jsonb_build_array(
      jsonb_build_object('metric', 'eligible_customers', 'value', v_eligible),
      jsonb_build_object('metric', 'identified_revenue_coverage_bps', 'value', v_coverage_bps),
      jsonb_build_object('metric', 'average_historical_transaction_cents', 'value', v_avg_value)
      ,jsonb_build_object('metric', 'effective_policy_lineage', 'value', v_effective_policy)
    ),
    jsonb_build_object(
      'total_sales_90d', v_total_sales,
      'identified_sales_90d', v_identified_sales,
      'total_revenue_cents_90d', v_total_revenue,
      'identified_revenue_cents_90d', v_identified_revenue
    ),
    jsonb_build_object(
      'eligible_customers', v_eligible,
      'historical_average_transaction_cents', v_avg_value
    ),
    jsonb_build_object(
      'currency', v_currency,
      'status', 'withheld_uncalibrated',
      'kind', 'incremental_revenue_not_yet_available',
      'reason', 'no completed calibrated experiment evidence'
    ),
    null,
    jsonb_build_object(
      'score_bps', v_confidence_bps,
      'score_kind', 'data_quality_only',
      'level', case
        when v_confidence_bps >= 8000 then 'high'
        when v_confidence_bps >= 6500 then 'medium'
        else 'low'
      end,
      'reasons', jsonb_build_array(
        'identity coverage and audience size determine confidence',
        'causal result remains unavailable until a valid holdout completes'
      )
    ),
    jsonb_build_array(
      'future behaviour may differ from historical cadence',
      'expected revenue is a range, not a guarantee',
      'gross profit is unavailable until item cost coverage is complete'
    ),
    jsonb_build_object(
      'label', 'Approve measured bring-back',
      'channel', 'in_app',
      'requires_owner_approval', true
    ),
    'in_app',
    jsonb_build_object(
      'type', 'credit_cents',
      'value_cents', v_policy.default_credit_cents,
      'currency', v_currency,
      'expires_in_days', 7
    ),
    greatest(0,
      (v_eligible - floor(v_eligible * v_policy.holdout_percent / 100.0)::integer)
        * v_policy.default_credit_cents
    ),
    v_eligible, v_excluded, 'incremental_completed_purchase_revenue',
    v_policy.frequency_cap_days,
    v_policy.attribution_days, v_policy.holdout_percent,
    jsonb_build_object(
      'budget_cap_cents',
      v_eligible * v_policy.maximum_credit_cents,
      'one_active_experiment_per_customer', true,
      'consent_rechecked_at_execution', true,
      'minimum_arm_size', v_policy.minimum_arm_size
    ),
    v_status, v_suppressions, v_now,
    jsonb_build_object(
      'identified_revenue_bps', v_coverage_bps,
      'total_sales', v_total_sales,
      'identified_sales', v_identified_sales,
      'effective_policy', v_effective_policy,
      'as_of', v_now
    ),
    v_dedupe, v_actor
  );

  insert into public.growth_recommendation_members_v108(
    recommendation_id, business_id, client_id, eligible, exclusion_reason,
    prior_visits, last_visit_at, cadence_days, lapse_days,
    average_transaction_cents, historical_revenue_cents, evidence
  )
  select v_recommendation, p_business, c.client_id, c.eligible, c.exclusion_reason,
    c.prior_visits, c.last_visit_at, round(c.cadence_days, 2), c.lapse_days,
    c.average_transaction_cents, c.historical_revenue_cents,
    jsonb_build_object(
      'prior_visits', c.prior_visits,
      'last_visit_at', c.last_visit_at,
      'observed_median_cadence_days', round(c.cadence_days, 2),
      'days_since_last_visit', c.lapse_days,
      'historical_average_transaction_cents', c.average_transaction_cents
    )
  from pg_temp.growth_candidates_v108 c;

  insert into public.audit_log(business_id, actor, action, entity, entity_id, detail)
  values (p_business, v_actor, 'REFRESH_GROWTH_RECOMMENDATION_V108',
    'growth_recommendations_v108', v_recommendation,
    jsonb_build_object('status', v_status, 'eligible', v_eligible,
      'excluded', v_excluded, 'coverage_bps', v_coverage_bps));

  return jsonb_build_object(
    'recommendation_id', v_recommendation,
    'status', v_status,
    'eligible', v_eligible,
    'excluded', v_excluded,
    'coverage_bps', v_coverage_bps,
    'suppression_reasons', v_suppressions,
    'replayed', false
  );
end $$;

create or replace function public.get_growth_daily_briefing_v108(
  p_business uuid,
  p_branch uuid default null
)
returns jsonb language plpgsql stable security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_recommendation public.growth_recommendations_v108%rowtype;
  v_result public.growth_execution_results_v108%rowtype;
  v_execution public.growth_executions_v108%rowtype;
  v_live_measurement jsonb;
begin
  if auth.uid() is null or (
     not app.is_super_admin()
     and (
       not app.has_perm(p_business, 'view_finance')
       or not app.can_module_read(p_business, 'retention')
     )
  ) then
    raise exception 'finance and retention access required' using errcode = '42501';
  end if;
  if not app.can_see_branch(p_business, p_branch) then
    raise exception 'branch is outside actor scope' using errcode = '42501';
  end if;

  select * into v_recommendation
  from public.growth_recommendations_v108 r
  where r.business_id = p_business
    and r.branch_id is not distinct from p_branch
  order by r.generated_at desc, r.id desc limit 1;

  select result_row.* into v_result
  from public.growth_execution_results_v108 result_row
  join public.growth_executions_v108 result_execution
    on result_execution.id = result_row.execution_id
   and result_execution.business_id = result_row.business_id
  where result_row.business_id = p_business
    and result_execution.branch_id is not distinct from p_branch
  order by result_row.finalized_at desc, result_row.id desc limit 1;

  select execution_row.* into v_execution
  from public.growth_executions_v108 execution_row
  where execution_row.business_id = p_business
    and execution_row.branch_id is not distinct from p_branch
    and execution_row.status = 'running'
  order by execution_row.started_at desc, execution_row.id desc
  limit 1;

  if v_execution.id is not null then
    v_live_measurement := public.get_growth_execution_result_v108(v_execution.id);
  end if;

  return jsonb_build_object(
    'contract_version', 'growth_daily_briefing_v108',
    'generated_at', coalesce(v_recommendation.generated_at, statement_timestamp()),
    'as_of', v_recommendation.data_freshness_at,
    'data_status', case
      when v_recommendation.id is null then 'not_computed'
      when v_recommendation.status = 'suppressed' then 'insufficient_evidence'
      when v_recommendation.valid_until <= statement_timestamp() then 'stale'
      else 'ready'
    end,
    'coverage', coalesce(v_recommendation.data_coverage, '{}'::jsonb),
    'top_action', case
      when v_recommendation.id is null
        or v_recommendation.status <> 'presented'
        or v_recommendation.valid_until <= statement_timestamp()
      then null
      else jsonb_build_object(
        'recommendation_id', v_recommendation.id,
        'type', v_recommendation.recommendation_type,
        'title', 'Bring back customers whose usual visit is overdue',
        'finding', v_recommendation.finding,
        'evidence', v_recommendation.supporting_evidence,
        'observation_window', jsonb_build_object(
          'start', v_recommendation.observation_start,
          'end', v_recommendation.observation_end
        ),
        'comparison_window', jsonb_build_object(
          'start', v_recommendation.comparison_start,
          'end', v_recommendation.comparison_end
        ),
        'audience', jsonb_build_object(
          'eligible', v_recommendation.audience_size,
          'excluded', v_recommendation.excluded_size,
          'treatment', v_recommendation.audience_size
            - floor(v_recommendation.audience_size * v_recommendation.holdout_percent / 100.0)::integer,
          'holdout', floor(
            v_recommendation.audience_size * v_recommendation.holdout_percent / 100.0
          )::integer
        ),
        'expected_incremental_revenue', v_recommendation.expected_incremental_revenue,
        'estimated_cost_cents', v_recommendation.estimated_cost_cents,
        'confidence', v_recommendation.confidence,
        'action', v_recommendation.recommended_action
          || v_recommendation.recommended_offer
          || jsonb_build_object(
            'offer',
            concat(
              coalesce(v_recommendation.recommended_offer ->> 'currency', 'UNSUPPORTED'),
              ' ',
              to_char(
                coalesce((v_recommendation.recommended_offer ->> 'value_cents')::bigint, 0)
                  / 100.0,
                'FM999999990.00'
              ),
              ' in-store credit on one eligible return visit'
            )
          )
          || jsonb_build_object('expires_at', v_recommendation.valid_until),
        'measurement', jsonb_build_object(
          'method', 'randomized_intent_to_treat_holdout',
          'attribution_days', v_recommendation.attribution_window_days,
          'minimum_sample', (v_recommendation.stop_conditions ->> 'minimum_arm_size')::integer,
          'status', 'not_started'
        ),
        'status', v_recommendation.status
      )
    end,
    'suppressions', coalesce(v_recommendation.suppression_reasons, '[]'::jsonb),
    'active_execution', case when v_execution.id is null then null else
      jsonb_build_object(
        'execution_id', v_execution.id,
        'recommendation_id', v_execution.recommendation_id,
        'branch_id', v_execution.branch_id,
        'currency', v_execution.currency,
        'status', v_execution.status,
        'started_at', v_execution.started_at,
        'ends_at', v_execution.ends_at,
        'governed_copy', v_execution.governed_copy,
        'delivery', jsonb_build_object(
          'queued', (
            select count(*) from public.growth_deliveries_v108 delivery
            where delivery.execution_id = v_execution.id
              and delivery.delivery_status = 'queued'
          ),
          'scheduled', (
            select count(*) from public.growth_deliveries_v108 delivery
            where delivery.execution_id = v_execution.id
              and delivery.delivery_status = 'scheduled'
          ),
          'delivering', (
            select count(*) from public.growth_deliveries_v108 delivery
            where delivery.execution_id = v_execution.id
              and delivery.delivery_status = 'delivering'
          ),
          'delivered', (
            select count(*) from public.growth_deliveries_v108 delivery
            where delivery.execution_id = v_execution.id
              and delivery.delivery_status = 'delivered'
          ),
          'held_out', (
            select count(*) from public.growth_deliveries_v108 delivery
            where delivery.execution_id = v_execution.id
              and delivery.delivery_status = 'held_out'
          ),
          'suppressed', (
            select count(*) from public.growth_deliveries_v108 delivery
            where delivery.execution_id = v_execution.id
              and delivery.delivery_status = 'suppressed'
          ),
          'failed', (
            select count(*) from public.growth_deliveries_v108 delivery
            where delivery.execution_id = v_execution.id
              and delivery.delivery_status = 'failed'
          ),
          'cancelled', (
            select count(*) from public.growth_deliveries_v108 delivery
            where delivery.execution_id = v_execution.id
              and delivery.delivery_status = 'cancelled'
          )
        ),
        'arms', jsonb_build_object(
          'treatment', (
            select count(*) from public.growth_execution_members_v108 member
            where member.execution_id = v_execution.id
              and member.assignment = 'treatment'
          ),
          'holdout', (
            select count(*) from public.growth_execution_members_v108 member
            where member.execution_id = v_execution.id
              and member.assignment = 'holdout'
          )
        ),
        'provisional_measurement', v_live_measurement
      )
    end,
    'latest_completed_action', case when v_result.id is null then null else
      jsonb_build_object(
        'execution_id', v_result.execution_id,
        'status', v_result.result_status,
        'result', v_result.result,
        'prediction', v_result.prediction,
        'calibration', v_result.calibration,
        'finalized_at', v_result.finalized_at
      )
    end
  );
end $$;

create or replace function public.preview_growth_recommendation_v108(
  p_business uuid,
  p_recommendation uuid,
  p_limit integer default 100
)
returns jsonb language plpgsql stable security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare v_row public.growth_recommendations_v108%rowtype;
begin
  if auth.uid() is null or (
     not app.is_super_admin()
     and (
       not app.has_perm(p_business, 'view_finance')
       or not app.can_module_read(p_business, 'retention')
     )
  ) then
    raise exception 'finance and retention access required' using errcode = '42501';
  end if;
  if coalesce(p_limit, 0) not between 1 and 200 then
    raise exception 'preview limit must be 1..200' using errcode = '22023';
  end if;
  select * into v_row from public.growth_recommendations_v108
  where id = p_recommendation and business_id = p_business;
  if not found then raise exception 'recommendation not found'; end if;
  if not app.can_see_branch(v_row.business_id, v_row.branch_id) then
    raise exception 'recommendation branch is outside actor scope' using errcode = '42501';
  end if;
  return jsonb_build_object(
    'recommendation_id', v_row.id,
    'status', v_row.status,
    'eligible_count', v_row.audience_size,
    'excluded_count', v_row.excluded_size,
    'eligible', coalesce((
      select jsonb_agg(jsonb_build_object(
        'client_id', m.client_id, 'evidence', m.evidence
      ) order by m.historical_revenue_cents desc, m.client_id)
      from (
        select * from public.growth_recommendation_members_v108
        where recommendation_id = p_recommendation and eligible
        order by historical_revenue_cents desc, client_id limit p_limit
      ) m
    ), '[]'::jsonb),
    'excluded_by_reason', coalesce((
      select jsonb_object_agg(reason, count_rows)
      from (
        select exclusion_reason as reason, count(*) as count_rows
        from public.growth_recommendation_members_v108
        where recommendation_id = p_recommendation and not eligible
        group by exclusion_reason
      ) excluded
    ), '{}'::jsonb)
  );
end $$;

create or replace function public.dismiss_growth_recommendation_v108(
  p_business uuid,
  p_recommendation uuid,
  p_reason text,
  p_idempotency_key uuid
)
returns jsonb language plpgsql security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_actor uuid := auth.uid();
  v_existing public.growth_recommendation_decisions_v108%rowtype;
  v_rec public.growth_recommendations_v108%rowtype;
  v_request_hash text;
begin
  if not app.is_salon_owner(p_business) then
    raise exception 'owner only' using errcode = '42501';
  end if;
  v_request_hash := encode(extensions.digest(convert_to(jsonb_build_object(
    'business_id', p_business,
    'recommendation_id', p_recommendation,
    'decision', 'dismissed',
    'reason', nullif(btrim(coalesce(p_reason, '')), '')
  )::text, 'UTF8'), 'sha256'), 'hex');
  select * into v_existing from public.growth_recommendation_decisions_v108
  where business_id = p_business and actor = v_actor and idempotency_key = p_idempotency_key;
  if found then
    if v_existing.request_hash <> v_request_hash then
      raise exception 'idempotency key reused with a different dismissal request'
        using errcode = '23505';
    end if;
    return jsonb_build_object('recommendation_id', v_existing.recommendation_id,
      'decision', v_existing.decision, 'replayed', true);
  end if;
  select * into v_rec from public.growth_recommendations_v108
  where id = p_recommendation and business_id = p_business for update;
  if not found then raise exception 'recommendation not found'; end if;
  if not app.can_see_branch(v_rec.business_id, v_rec.branch_id) then
    raise exception 'recommendation branch is outside actor scope' using errcode = '42501';
  end if;
  update public.growth_recommendations_v108
  set status = 'dismissed'
  where id = p_recommendation and business_id = p_business
    and status = 'presented' and valid_until > statement_timestamp();
  if not found then raise exception 'recommendation is not dismissible'; end if;
  insert into public.growth_recommendation_decisions_v108(
    recommendation_id, business_id, decision, reason, actor, idempotency_key,
    request_hash
  ) values (
    p_recommendation, p_business, 'dismissed',
    nullif(btrim(coalesce(p_reason, '')), ''), v_actor, p_idempotency_key,
    v_request_hash
  );
  return jsonb_build_object('recommendation_id', p_recommendation,
    'decision', 'dismissed', 'replayed', false);
end $$;

create or replace function public.approve_growth_recommendation_v108(
  p_business uuid,
  p_recommendation uuid,
  p_offer_value_cents integer,
  p_offer_label text,
  p_idempotency_key uuid
)
returns jsonb language plpgsql security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_actor uuid := auth.uid();
  v_rec public.growth_recommendations_v108%rowtype;
  v_policy public.growth_policies_v108%rowtype;
  v_execution uuid := gen_random_uuid();
  v_existing public.growth_executions_v108%rowtype;
  v_holdout integer;
  v_queued integer := 0;
  v_scheduled integer := 0;
  v_heldout integer := 0;
  v_suppressed integer := 0;
  v_spend bigint := 0;
  v_request_hash text;
  v_currency text;
  v_offer_timezone text;
  v_offer_expires_at timestamptz;
  v_template_title text;
  v_template_lead text;
  v_governed_copy jsonb;
  v_ends_at timestamptz;
  v_effective_policy jsonb;
begin
  if not app.is_salon_owner(p_business) then
    raise exception 'owner only' using errcode = '42501';
  end if;
  if p_offer_value_cents is null then
    raise exception 'offer value is required' using errcode = '22023';
  end if;
  if p_offer_label is null
     or p_offer_label not in (
       'welcome_back', 'member_thank_you', 'simple_saving'
     ) then
    raise exception 'offer template must be welcome_back, member_thank_you, or simple_saving'
      using errcode = '22023';
  end if;
  v_request_hash := encode(extensions.digest(convert_to(jsonb_build_object(
    'business_id', p_business,
    'recommendation_id', p_recommendation,
    'offer_value_cents', p_offer_value_cents,
    'offer_label', btrim(p_offer_label)
  )::text, 'UTF8'), 'sha256'), 'hex');

  select * into v_existing from public.growth_executions_v108
  where business_id = p_business and approved_by = v_actor
    and idempotency_key = p_idempotency_key;
  if found then
    if v_existing.request_hash <> v_request_hash then
      raise exception 'idempotency key reused with a different approval request'
        using errcode = '23505';
    end if;
    return jsonb_build_object('execution_id', v_existing.id, 'replayed', true);
  end if;

  perform pg_advisory_xact_lock(hashtextextended(
    'growth-v108-membership:' || p_business::text, 0
  ));
  perform pg_advisory_xact_lock(hashtextextended(
    'growth-v108-approve:' || p_recommendation::text, 0
  ));
  select * into v_rec from public.growth_recommendations_v108
  where id = p_recommendation and business_id = p_business for update;
  if not found then raise exception 'recommendation not found'; end if;
  select * into v_policy from public.growth_policies_v108 where business_id = p_business;
  v_effective_policy := app.growth_v108_effective_parameters(p_business);
  if not app.can_see_branch(v_rec.business_id, v_rec.branch_id) then
    raise exception 'recommendation branch is outside actor scope' using errcode = '42501';
  end if;
  if not app.platform_feature_enabled('growth_closed_loop_v108')
     or not app.can_module_read(p_business, 'retention') then
    raise exception 'growth feature or retention entitlement is no longer enabled'
      using errcode = '42501';
  end if;
  if v_policy.enabled is distinct from true
     or v_rec.policy_version <> v_policy.policy_version
     -- Source availability is timestamped observation evidence.  It is kept on
     -- the recommendation for audit, but its moving `as_of` value is not policy
     -- configuration and must not make the next approval statement stale.
     or (
       (v_rec.data_coverage -> 'effective_policy') - 'source_availability'
     ) is distinct from (
       v_effective_policy - 'source_availability'
     ) then
    raise exception 'recommendation policy is disabled or stale'
      using errcode = '42501';
  end if;
  if v_rec.status <> 'presented' or v_rec.valid_until <= statement_timestamp() then
    raise exception 'recommendation is no longer executable' using errcode = '42501';
  end if;
  if p_offer_value_cents not between 100 and v_policy.maximum_credit_cents then
    raise exception 'offer exceeds configured economic guardrail' using errcode = '22023';
  end if;

  v_holdout := greatest(v_policy.minimum_arm_size,
    floor(v_rec.audience_size * v_rec.holdout_percent / 100.0)::integer);
  if v_rec.audience_size - v_holdout < v_policy.minimum_arm_size then
    raise exception 'audience is too small for a valid measured execution'
      using errcode = '22023';
  end if;
  if exists (
    select 1
    from public.growth_recommendation_members_v108 candidate
    join public.growth_execution_members_v108 active_member
      on active_member.business_id = candidate.business_id
     and active_member.client_id = candidate.client_id
    join public.growth_executions_v108 active_execution
      on active_execution.id = active_member.execution_id
     and active_execution.business_id = active_member.business_id
    where candidate.recommendation_id = v_rec.id
      and candidate.business_id = p_business
      and candidate.eligible
      and active_execution.status = 'running'
      and active_execution.ends_at > statement_timestamp()
  ) then
    raise exception 'recommendation overlaps an active customer experiment'
      using errcode = '23P01';
  end if;
  select upper(currency) into strict v_currency
  from public.businesses where id = p_business;
  select reporting.timezone into strict v_offer_timezone
  from app.v106_reporting_contract(
    -- Reporting-contract rows are appended with clock_timestamp().  Use the
    -- same clock here so a newly onboarded firm can approve its first
    -- recommendation in the transaction that creates its branch.
    p_business, v_rec.branch_id, clock_timestamp()
  ) reporting;
  v_ends_at := statement_timestamp()
    + make_interval(days => v_rec.attribution_window_days);
  v_offer_expires_at := least(
    statement_timestamp() + interval '7 days', v_ends_at
  );
  select template.title, template.lead
  into strict v_template_title, v_template_lead
  from (values
    (
      'welcome_back'::text,
      'A welcome-back thank-you is waiting'::text,
      'We would love to welcome you back.'::text
    ),
    (
      'member_thank_you',
      'A member thank-you is waiting',
      'Thank you for being part of our community.'
    ),
    (
      'simple_saving',
      'A saving is ready for you',
      'Enjoy a little saving on your next eligible visit.'
    )
  ) template(template_id, title, lead)
  where template.template_id = p_offer_label;
  v_governed_copy := jsonb_build_object(
    'schema', 'nestly.growth_offer_copy',
    'version', 1,
    'title', v_template_title,
    'body', concat(
      v_template_lead, ' Enjoy ', v_currency, ' ',
      to_char(p_offer_value_cents / 100.0, 'FM999999990.00'),
      ' in credit before ',
      to_char(v_offer_expires_at at time zone v_offer_timezone, 'DD Mon YYYY'),
      ' (', v_offer_timezone, ').'
    ),
    'cta_label', 'Redeem now',
    'cta_destination', 'customer_growth_offer_qr',
    'eligibility', jsonb_build_object(
      'business_id', p_business,
      'branch_id', v_rec.branch_id,
      'recommendation_id', v_rec.id,
      'eligible_member_snapshot', true,
      'verified_customer_link_required', true,
      'marketing_consent_required', true,
      'one_active_experiment_per_customer', true
    ),
    'conditions', jsonb_build_object(
      'single_use', true,
      'qualifying_completed_sale_required', true,
      'sale_after_issuance_required', true,
      'exact_branch_when_scoped', true,
      'expires_at', v_offer_expires_at,
      'timezone', v_offer_timezone
    ),
    'locked_facts', jsonb_build_object(
      'template_id', p_offer_label,
      'offer_value_cents', p_offer_value_cents,
      'currency', v_currency,
      'expires_at', v_offer_expires_at,
      'timezone', v_offer_timezone,
      'branch_id', v_rec.branch_id,
      'recommendation_id', v_rec.id,
      'cta_label', 'Redeem now',
      'cta_destination', 'customer_growth_offer_qr'
    )
  );

  insert into public.growth_executions_v108(
    id, recommendation_id, business_id, branch_id, channel, offer_type,
    offer_value_cents, offer_label, currency, offer_timezone,
    offer_expires_at, governed_copy,
    budget_cap_cents, holdout_percent,
    attribution_window_days, minimum_arm_size, approved_by, ends_at, idempotency_key,
    request_hash
  ) values (
    v_execution, v_rec.id, p_business, v_rec.branch_id, 'in_app', 'credit_cents',
    p_offer_value_cents, p_offer_label, v_currency, v_offer_timezone,
    v_offer_expires_at, v_governed_copy,
    (v_rec.audience_size - v_holdout) * p_offer_value_cents,
    v_rec.holdout_percent, v_rec.attribution_window_days,
    v_policy.minimum_arm_size, v_actor,
    v_ends_at, p_idempotency_key, v_request_hash
  );

  insert into public.growth_execution_members_v108(
    execution_id, business_id, recommendation_member_id, client_id,
    assignment, assignment_rank, assignment_score
  )
  select v_execution, p_business, ranked.id, ranked.client_id,
    case when ranked.assignment_rank <= v_holdout then 'holdout' else 'treatment' end,
    ranked.assignment_rank, ranked.assignment_score
  from (
    select m.id, m.client_id,
      encode(extensions.digest(convert_to(
        v_execution::text || ':' || m.client_id::text, 'UTF8'
      ), 'sha256'), 'hex') as assignment_score,
      row_number() over (order by
        encode(extensions.digest(convert_to(
          v_execution::text || ':' || m.client_id::text, 'UTF8'
        ), 'sha256'), 'hex'),
        m.client_id
      )::integer as assignment_rank
    from public.growth_recommendation_members_v108 m
    where m.recommendation_id = v_rec.id and m.business_id = p_business and m.eligible
  ) ranked;

  insert into public.growth_deliveries_v108(
    execution_id, execution_member_id, business_id, client_id,
    identity_id, link_id, assignment, channel, delivery_status,
    suppression_reason, title, body, estimated_cost_cents, delivered_at
  )
  select v_execution, em.id, p_business, em.client_id,
    link.identity_id, link.id, em.assignment, 'in_app',
    case
      when em.assignment = 'holdout' then 'held_out'
      when link.id is null then 'suppressed'
      when pref.opted_in is distinct from true then 'suppressed'
      when delivery_gate.in_quiet_hours then 'suppressed'
      when delivery_gate.frequency_capped then 'suppressed'
      else 'delivered'
    end,
    case
      when em.assignment = 'holdout' then 'holdout'
      when link.id is null then 'link_unavailable'
      when pref.opted_in is distinct from true then 'consent_withdrawn'
      when delivery_gate.in_quiet_hours then 'quiet_hours'
      when delivery_gate.frequency_capped then 'frequency_cap'
      else null
    end,
    case when delivery_gate.can_deliver
      then v_governed_copy ->> 'title' else null end,
    case when delivery_gate.can_deliver
      then v_governed_copy ->> 'body' else null end,
    case when delivery_gate.can_deliver
      then p_offer_value_cents else 0 end,
    case when delivery_gate.can_deliver
      then statement_timestamp() else null end
  from public.growth_execution_members_v108 em
  left join lateral (
    select l.* from public.customer_links l
    where l.business_id = p_business and l.client_id = em.client_id and l.state = 'verified'
    order by l.verified_at desc, l.id limit 1
  ) link on true
  left join lateral (
    select p.* from public.customer_notification_preferences p
    where p.business_id = p_business and p.client_id = em.client_id
      and p.link_id = link.id and p.channel = 'in_app' and p.topic = 'marketing'
    order by p.updated_at desc, p.id limit 1
  ) pref on true
  cross join lateral (
    select
      app.c46_in_quiet_hours(
        pref.quiet_hours_timezone, pref.quiet_hours_start,
        pref.quiet_hours_end, statement_timestamp()
      ) as in_quiet_hours,
      exists (
        select 1 from public.growth_deliveries_v108 prior
        where prior.business_id = p_business and prior.client_id = em.client_id
          and prior.delivery_status = 'delivered'
          and prior.delivered_at >= statement_timestamp()
            - make_interval(days => v_policy.frequency_cap_days)
      ) as frequency_capped
  ) delivery_state
  cross join lateral (
    select (
      em.assignment = 'treatment'
      and link.id is not null
      and pref.opted_in is true
      and not delivery_state.in_quiet_hours
      and not delivery_state.frequency_capped
    ) as can_deliver,
    delivery_state.in_quiet_hours,
    delivery_state.frequency_capped
  ) delivery_gate
  where em.execution_id = v_execution;

  insert into public.growth_entitlements_v108(
    delivery_id, execution_id, business_id, client_id, identity_id,
    entitlement_type, value_cents, estimated_cost_cents, expires_at
  )
  select d.id, v_execution, p_business, d.client_id, d.identity_id,
    'credit_cents', p_offer_value_cents, p_offer_value_cents,
    v_offer_expires_at
  from public.growth_deliveries_v108 d
  where d.execution_id = v_execution and d.delivery_status = 'delivered';

  insert into public.growth_entitlement_events_v108(
    entitlement_id, business_id, event_type, actor, idempotency_key, detail
  )
  select e.id, p_business, 'issued', v_actor,
    extensions.uuid_generate_v5(p_idempotency_key, e.id::text),
    jsonb_build_object('execution_id', v_execution, 'value_cents', e.value_cents)
  from public.growth_entitlements_v108 e where e.execution_id = v_execution;

  select
    count(*) filter (where delivery_status = 'queued'),
    count(*) filter (where delivery_status = 'scheduled'),
    count(*) filter (where delivery_status = 'held_out'),
    count(*) filter (where delivery_status = 'suppressed'),
    coalesce(sum(estimated_cost_cents) filter (
      where delivery_status in ('queued', 'scheduled')
    ), 0)
  into v_queued, v_scheduled, v_heldout, v_suppressed, v_spend
  from public.growth_deliveries_v108 where execution_id = v_execution;

  update public.growth_recommendations_v108 set status = 'executed'
  where id = v_rec.id and business_id = p_business;
  insert into public.growth_recommendation_decisions_v108(
    recommendation_id, business_id, decision, actor, idempotency_key, request_hash
  ) values (
    v_rec.id, p_business, 'accepted', v_actor, p_idempotency_key, v_request_hash
  );
  insert into public.audit_log(business_id, actor, action, entity, entity_id, detail)
  values (p_business, v_actor, 'APPROVE_GROWTH_RECOMMENDATION_V108',
    'growth_executions_v108', v_execution,
    jsonb_build_object(
      'queued', v_queued,
      'scheduled', v_scheduled,
      'held_out', v_heldout,
      'suppressed', v_suppressed,
      'estimated_cost_cents', v_spend
    ));

  return jsonb_build_object(
    'execution_id', v_execution,
    'recommendation_id', v_rec.id,
    'delivery', jsonb_build_object(
      'queued', v_queued,
      'scheduled', v_scheduled,
      'held_out', v_heldout,
      'suppressed', v_suppressed
    ),
    'estimated_cost_cents', v_spend,
    'currency', v_currency,
    'governed_copy', v_governed_copy,
    'measurement', jsonb_build_object(
      'method', 'randomized_intent_to_treat_holdout',
      'status', 'running',
      'ends_at', statement_timestamp() + make_interval(days => v_rec.attribution_window_days)
    ),
    'replayed', false
  );
end $$;

create or replace function public.customer_get_growth_offers_v108(
  p_business uuid
)
returns jsonb language plpgsql volatile security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare v_identity uuid; v_client uuid;
begin
  select i.id, l.client_id into v_identity, v_client
  from public.customer_identities i
  join public.customer_links l on l.identity_id = i.id and l.auth_user_id = i.auth_user_id
  where i.auth_user_id = auth.uid() and i.status = 'active'
    and l.business_id = p_business and l.state = 'verified';
  if v_identity is null then raise exception 'verified customer link required' using errcode = '42501'; end if;

  with expired as (
    update public.growth_entitlements_v108
    set status = 'expired'
    where business_id = p_business and identity_id = v_identity and status = 'issued'
      and expires_at <= statement_timestamp()
    returning id, business_id, expires_at
  )
  insert into public.growth_entitlement_events_v108(
    entitlement_id, business_id, event_type, actor, idempotency_key, detail
  )
  select expired.id, expired.business_id, 'expired', auth.uid(),
    extensions.uuid_generate_v5(expired.id, 'expired'),
    jsonb_build_object('expired_at', expired.expires_at)
  from expired
  on conflict do nothing;

  return jsonb_build_object(
    'business_id', p_business,
    'offers', coalesce((
      select jsonb_agg(jsonb_build_object(
        'entitlement_id', e.id,
        'label', x.offer_label,
        'type', e.entitlement_type,
        'value_cents', e.value_cents,
        'currency', x.currency,
        'governed_copy', x.governed_copy,
        'status', e.status,
        'issued_at', e.issued_at,
        'expires_at', e.expires_at,
        'redeemed_at', e.redeemed_at
      ) order by e.issued_at desc, e.id desc)
      from public.growth_entitlements_v108 e
      join public.growth_executions_v108 x on x.id = e.execution_id
      where e.business_id = p_business and e.identity_id = v_identity and e.client_id = v_client
    ), '[]'::jsonb)
  );
end $$;

create or replace function public.customer_prepare_growth_offer_qr_v108(
  p_entitlement uuid,
  p_idempotency_key uuid
)
returns jsonb language plpgsql security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_identity uuid;
  v_entitlement public.growth_entitlements_v108%rowtype;
  v_execution public.growth_executions_v108%rowtype;
  v_intent public.growth_redemption_intents_v108%rowtype;
  v_token text;
  v_request_hash text;
  v_now timestamptz := statement_timestamp();
begin
  select id into v_identity from public.customer_identities
  where auth_user_id = auth.uid() and status = 'active';
  if v_identity is null then raise exception 'active customer identity required' using errcode = '42501'; end if;
  select * into v_entitlement from public.growth_entitlements_v108
  where id = p_entitlement and identity_id = v_identity for update;
  if not found then raise exception 'offer not found'; end if;
  if v_entitlement.status <> 'issued' or v_entitlement.expires_at <= v_now then
    raise exception 'offer is not redeemable' using errcode = '42501';
  end if;
  v_request_hash := encode(extensions.digest(convert_to(jsonb_build_object(
    'identity_id', v_identity,
    'entitlement_id', p_entitlement
  )::text, 'UTF8'), 'sha256'), 'hex');
  v_token := app.growth_v108_token(
    v_identity, v_entitlement.business_id, v_entitlement.id, p_idempotency_key
  );
  select * into v_intent from public.growth_redemption_intents_v108
  where identity_id = v_identity and idempotency_key = p_idempotency_key;
  if found then
    if v_intent.request_hash <> v_request_hash then
      raise exception 'idempotency key reused with a different QR request'
        using errcode = '23505';
    end if;
    return jsonb_build_object(
      'intent_id', v_intent.id, 'token', v_token, 'expires_at', v_intent.expires_at,
      'replayed', true
    );
  end if;
  insert into public.growth_redemption_intents_v108(
    entitlement_id, business_id, identity_id, token_hash, idempotency_key,
    request_hash, expires_at
  ) values (
    v_entitlement.id, v_entitlement.business_id, v_identity,
    encode(extensions.digest(convert_to(v_token, 'UTF8'), 'sha256'), 'hex'),
    p_idempotency_key, v_request_hash,
    least(v_now + interval '5 minutes', v_entitlement.expires_at)
  ) returning * into v_intent;
  insert into public.growth_entitlement_events_v108(
    entitlement_id, business_id, event_type, actor, idempotency_key, detail
  ) values (
    v_entitlement.id, v_entitlement.business_id, 'qr_prepared', auth.uid(),
    p_idempotency_key, jsonb_build_object('intent_id', v_intent.id)
  );
  return jsonb_build_object(
    'intent_id', v_intent.id, 'token', v_token, 'expires_at', v_intent.expires_at,
    'replayed', false
  );
end $$;

create or replace function public.redeem_growth_offer_v108(
  p_business uuid,
  p_token text,
  p_sale uuid,
  p_idempotency_key uuid
)
returns jsonb language plpgsql security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_actor uuid := auth.uid();
  v_intent public.growth_redemption_intents_v108%rowtype;
  v_entitlement public.growth_entitlements_v108%rowtype;
  v_execution public.growth_executions_v108%rowtype;
  v_sale public.sales%rowtype;
  v_existing public.growth_entitlement_events_v108%rowtype;
  -- Sale creation may use wall-clock time inside a larger transaction.  The
  -- redemption cutoff must use the same advancing clock so an immediately
  -- completed sale is not misclassified as future-dated.
  v_now timestamptz := clock_timestamp();
  v_request_hash text;
  v_receipt jsonb;
begin
  if v_actor is null
     or not app.has_perm(p_business, 'create_sales')
     or not app.can_module_read(p_business, 'retention') then
    raise exception 'sales and retention access required' using errcode = '42501';
  end if;
  select * into v_intent from public.growth_redemption_intents_v108
  where business_id = p_business
    and token_hash = encode(extensions.digest(convert_to(p_token, 'UTF8'), 'sha256'), 'hex')
  for update;
  if not found then raise exception 'invalid offer QR'; end if;
  v_request_hash := encode(extensions.digest(convert_to(jsonb_build_object(
    'business_id', p_business,
    'intent_id', v_intent.id,
    'entitlement_id', v_intent.entitlement_id,
    'sale_id', p_sale
  )::text, 'UTF8'), 'sha256'), 'hex');
  select * into v_existing from public.growth_entitlement_events_v108
  where business_id = p_business
    and actor = v_actor
    and event_type = 'redeemed'
    and idempotency_key = p_idempotency_key;
  if found then
    if v_existing.detail ->> 'request_hash' <> v_request_hash then
      raise exception 'idempotency key reused with a different redemption request'
        using errcode = '23505';
    end if;
    return v_existing.detail -> 'receipt';
  end if;
  if v_intent.status <> 'pending' or v_intent.expires_at <= v_now then
    raise exception 'offer QR is no longer valid' using errcode = '42501';
  end if;
  select * into v_entitlement from public.growth_entitlements_v108
  where id = v_intent.entitlement_id and business_id = p_business for update;
  if v_entitlement.status <> 'issued' or v_entitlement.expires_at <= v_now then
    raise exception 'offer is no longer redeemable' using errcode = '42501';
  end if;
  select * into strict v_execution
  from public.growth_executions_v108
  where id = v_entitlement.execution_id and business_id = p_business;
  if not app.can_see_branch(v_execution.business_id, v_execution.branch_id) then
    raise exception 'offer branch is outside actor scope' using errcode = '42501';
  end if;
  select * into v_sale from public.sales
  where id = p_sale and business_id = p_business for share;
  if not found or v_sale.client_id <> v_entitlement.client_id
     or not v_sale.counts_as_visit or not v_sale.counts_as_revenue
     or v_sale.reversal_of is not null
     or v_sale.amount_cents <= 0
     or v_sale.created_at > v_now
     or v_sale.occurred_at > v_now
     or app.v106_sale_residual_minor(v_sale.id, v_now) <= 0
     or exists (
       select 1 from public.sales reversal
       where reversal.business_id = v_sale.business_id
         and reversal.reversal_of = v_sale.id
         and reversal.created_at <= v_now
     )
     or v_sale.created_at < greatest(v_entitlement.issued_at, v_execution.started_at)
     or v_sale.occurred_at < greatest(v_entitlement.issued_at, v_execution.started_at)
     or v_sale.occurred_at >= least(v_entitlement.expires_at, v_execution.ends_at)
     or (v_execution.branch_id is not null
         and v_sale.branch_id is distinct from v_execution.branch_id)
     or not app.can_see_branch(v_sale.business_id, v_sale.branch_id) then
    raise exception 'offer must attach to this customer''s qualifying sale'
      using errcode = '22023';
  end if;
  v_receipt := jsonb_build_object(
    'entitlement_id', v_entitlement.id,
    'sale_id', p_sale,
    'value_cents', v_entitlement.value_cents,
    'status', 'redeemed'
  );
  update public.growth_entitlements_v108
  set status = 'redeemed', redeemed_at = v_now, redeemed_sale_id = p_sale
  where id = v_entitlement.id;
  update public.growth_redemption_intents_v108
  set status = 'completed', completed_at = v_now
  where id = v_intent.id;
  insert into public.growth_entitlement_events_v108(
    entitlement_id, business_id, event_type, actor, sale_id, idempotency_key, detail
  ) values (
    v_entitlement.id, p_business, 'redeemed', v_actor, p_sale, p_idempotency_key,
    jsonb_build_object(
      'intent_id', v_intent.id,
      'value_cents', v_entitlement.value_cents,
      'request_hash', v_request_hash,
      'receipt', v_receipt
    )
  );
  return v_receipt;
end $$;

create or replace function app.capture_growth_outcome_v108()
returns trigger language plpgsql security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_overlap integer;
  -- Sales can be stamped with clock_timestamp() by a checkout performed
  -- earlier in the same outer transaction.
  v_now timestamptz := clock_timestamp();
begin
  if new.reversal_of is not null then
    update public.growth_entitlements_v108 e
    set status = 'reversed', reversed_at = statement_timestamp()
    where e.business_id = new.business_id and e.redeemed_sale_id = new.reversal_of
      and e.status = 'redeemed';
    insert into public.growth_entitlement_events_v108(
      entitlement_id, business_id, event_type, sale_id, idempotency_key, detail
    )
    select e.id, e.business_id, 'reversed', new.id,
      extensions.uuid_generate_v5(e.id, new.id::text),
      jsonb_build_object('reversal_sale_id', new.id, 'original_sale_id', new.reversal_of)
    from public.growth_entitlements_v108 e
    where e.business_id = new.business_id and e.redeemed_sale_id = new.reversal_of
      and e.status = 'reversed'
    on conflict do nothing;
    update public.growth_outcomes_v108
    set revenue_cents = app.v106_sale_residual_minor(new.reversal_of, v_now)
    where business_id = new.business_id and sale_id = new.reversal_of;
    return new;
  end if;
  if new.client_id is null or not new.counts_as_visit or not new.counts_as_revenue
     or new.created_at > v_now or new.occurred_at > v_now
     or app.v106_sale_residual_minor(new.id, v_now) <= 0 then
    return new;
  end if;
  select count(*) into v_overlap
  from public.growth_execution_members_v108 em
  join public.growth_executions_v108 e on e.id = em.execution_id
  where em.business_id = new.business_id and em.client_id = new.client_id
    and e.status = 'running'
    and (e.branch_id is null or e.branch_id = new.branch_id)
    and new.occurred_at >= e.started_at and new.occurred_at < e.ends_at;
  insert into public.growth_outcomes_v108(
    execution_id, execution_member_id, business_id, client_id, sale_id,
    assignment, outcome_kind, occurred_at, revenue_cents, overlap_count, causal_eligible
  )
  select e.id, em.id, new.business_id, new.client_id, new.id,
    em.assignment, 'qualifying_purchase', new.occurred_at,
    app.v106_sale_residual_minor(new.id, v_now),
    greatest(v_overlap, 1), v_overlap = 1
  from public.growth_execution_members_v108 em
  join public.growth_executions_v108 e on e.id = em.execution_id
  where em.business_id = new.business_id and em.client_id = new.client_id
    and e.status = 'running'
    and (e.branch_id is null or e.branch_id = new.branch_id)
    and new.occurred_at >= e.started_at and new.occurred_at < e.ends_at
  on conflict (execution_id, client_id) do nothing;
  return new;
end $$;

create trigger capture_growth_outcome_v108
after insert on public.sales
for each row execute function app.capture_growth_outcome_v108();

create or replace function app.refresh_growth_outcome_residual_v108()
returns trigger language plpgsql security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_now timestamptz := clock_timestamp();
begin
  update public.growth_outcomes_v108
  set revenue_cents = app.v106_sale_residual_minor(new.sale_id, v_now)
  where business_id = new.business_id and sale_id = new.sale_id;
  return new;
end $$;

create trigger refresh_growth_outcome_residual_v108
after insert on public.commerce_refund_allocations_v106
for each row execute function app.refresh_growth_outcome_residual_v108();

create or replace function app.get_growth_execution_result_at_v108(
  p_execution uuid,
  p_as_of timestamptz
)
returns jsonb language plpgsql stable security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_execution public.growth_executions_v108%rowtype;
  v_t_members integer := 0; v_h_members integer := 0;
  v_t_buyers integer := 0; v_h_buyers integer := 0;
  v_t_revenue bigint := 0; v_h_revenue bigint := 0;
  v_t_rate numeric := 0; v_h_rate numeric := 0;
  v_lift numeric := 0; v_se numeric := 0;
  v_aov numeric := 0;
  v_estimate bigint := 0; v_low bigint := 0; v_high bigint := 0;
  v_overlap integer := 0;
  v_measurement text;
begin
  if p_as_of is null then
    raise exception 'reporting cutoff is required'
      using errcode = '22004';
  end if;
  select * into v_execution from public.growth_executions_v108 where id = p_execution;
  if not found then raise exception 'execution not found'; end if;
  if auth.uid() is null or (
     not app.is_super_admin()
     and (
       not app.has_perm(v_execution.business_id, 'view_finance')
       or not app.can_module_read(v_execution.business_id, 'retention')
     )
  ) then
    raise exception 'finance and retention access required' using errcode = '42501';
  end if;
  if not app.can_see_branch(v_execution.business_id, v_execution.branch_id) then
    raise exception 'execution branch is outside actor scope' using errcode = '42501';
  end if;
  with member_result as (
    select em.assignment, em.client_id,
      exists (
        select 1 from public.sales s
        where s.business_id = v_execution.business_id and s.client_id = em.client_id
          and s.counts_as_visit and s.counts_as_revenue and s.reversal_of is null
          and s.created_at <= p_as_of and s.occurred_at <= p_as_of
          and (v_execution.branch_id is null or s.branch_id = v_execution.branch_id)
          and s.occurred_at >= v_execution.started_at and s.occurred_at < v_execution.ends_at
          and app.v106_sale_residual_minor(s.id, p_as_of) > 0
      ) as purchased,
      coalesce((
        select sum(app.v106_sale_residual_minor(s.id, p_as_of))
        from public.sales s
        where s.business_id = v_execution.business_id and s.client_id = em.client_id
          and s.counts_as_revenue and s.reversal_of is null
          and s.created_at <= p_as_of and s.occurred_at <= p_as_of
          and (v_execution.branch_id is null or s.branch_id = v_execution.branch_id)
          and s.occurred_at >= v_execution.started_at and s.occurred_at < v_execution.ends_at
          and app.v106_sale_residual_minor(s.id, p_as_of) > 0
      ), 0)::bigint as revenue_cents
    from public.growth_execution_members_v108 em
    where em.execution_id = p_execution
  )
  select
    count(*) filter (where assignment = 'treatment'),
    count(*) filter (where assignment = 'holdout'),
    count(*) filter (where assignment = 'treatment' and purchased),
    count(*) filter (where assignment = 'holdout' and purchased),
    coalesce(sum(revenue_cents) filter (where assignment = 'treatment'), 0),
    coalesce(sum(revenue_cents) filter (where assignment = 'holdout'), 0)
  into v_t_members, v_h_members, v_t_buyers, v_h_buyers, v_t_revenue, v_h_revenue
  from member_result;

  select count(*) into v_overlap
  from public.growth_outcomes_v108 outcome
  where outcome.execution_id = p_execution
    and not outcome.causal_eligible
    and outcome.occurred_at <= p_as_of
    and app.v106_sale_residual_minor(outcome.sale_id, p_as_of) > 0;
  v_t_rate := case when v_t_members > 0 then v_t_buyers::numeric / v_t_members else 0 end;
  v_h_rate := case when v_h_members > 0 then v_h_buyers::numeric / v_h_members else 0 end;
  v_lift := v_t_rate - v_h_rate;
  v_se := case when v_t_members > 0 and v_h_members > 0 then sqrt(
    greatest(0, v_t_rate * (1 - v_t_rate) / v_t_members)
    + greatest(0, v_h_rate * (1 - v_h_rate) / v_h_members)
  ) else 0 end;
  v_aov := case when v_t_buyers + v_h_buyers > 0
    then (v_t_revenue + v_h_revenue)::numeric / (v_t_buyers + v_h_buyers)
    else 0 end;
  v_estimate := round(v_lift * v_t_members * v_aov);
  v_low := round((v_lift - 1.96 * v_se) * v_t_members * v_aov);
  v_high := round((v_lift + 1.96 * v_se) * v_t_members * v_aov);
  v_measurement := case
    when v_overlap > 0 then 'invalid_overlap'
    when v_t_members < v_execution.minimum_arm_size
      or v_h_members < v_execution.minimum_arm_size then 'inconclusive_small_sample'
    when p_as_of < v_execution.ends_at then 'provisional'
    else 'final'
  end;
  return jsonb_build_object(
    'execution_id', p_execution,
    'business_id', v_execution.business_id,
    'as_of', p_as_of,
    'status', v_execution.status,
    'window', jsonb_build_object('start', v_execution.started_at, 'end', v_execution.ends_at),
    'method', 'randomized_intent_to_treat_holdout',
    'measurement_status', v_measurement,
    'arms', jsonb_build_object(
      'treatment', jsonb_build_object(
        'members', v_t_members, 'buyers', v_t_buyers,
        'conversion_rate_bps', round(v_t_rate * 10000),
        'associated_revenue_cents', v_t_revenue
      ),
      'holdout', jsonb_build_object(
        'members', v_h_members, 'buyers', v_h_buyers,
        'conversion_rate_bps', round(v_h_rate * 10000),
        'associated_revenue_cents', v_h_revenue
      )
    ),
    'incremental_conversion_lift_bps', round(v_lift * 10000),
    'estimated_incremental_revenue', case
      when v_measurement in ('invalid_overlap', 'inconclusive_small_sample') then null
      else jsonb_build_object(
        'currency', v_execution.currency, 'point_estimate_cents', v_estimate,
        'low_cents', least(v_low, v_high), 'high_cents', greatest(v_low, v_high),
        'confidence_level', 'approximate_95_percent'
      )
    end,
    'incremental_gross_profit', null,
    'cost', jsonb_build_object(
      'estimated_offer_cost_cents', coalesce((
        select sum(d.estimated_cost_cents) from public.growth_deliveries_v108 d
        where d.execution_id = p_execution and d.delivery_status = 'delivered'
      ), 0),
      'actual_redeemed_cost_cents', coalesce((
        select sum(e.estimated_cost_cents) from public.growth_entitlements_v108 e
        where e.execution_id = p_execution and e.status = 'redeemed'
      ), 0),
      'reversed_offer_cost_cents', coalesce((
        select sum(e.estimated_cost_cents) from public.growth_entitlements_v108 e
        where e.execution_id = p_execution and e.status = 'reversed'
      ), 0)
    ),
    'overlap_outcomes', v_overlap,
    'limitations', jsonb_build_array(
      'revenue result is not gross profit',
      'confidence interval uses a transparent normal approximation',
      'small or overlapping experiments are suppressed'
    )
  );
end $$;

create or replace function public.get_growth_execution_result_v108(
  p_execution uuid
)
returns jsonb language plpgsql security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  -- Freeze one live reporting cutoff for the entire projection.
  v_as_of timestamptz := clock_timestamp();
begin
  return app.get_growth_execution_result_at_v108(p_execution, v_as_of);
end $$;

create or replace function public.finalize_growth_execution_v108(
  p_business uuid,
  p_execution uuid,
  p_idempotency_key uuid
)
returns jsonb language plpgsql security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_actor uuid := auth.uid();
  v_execution public.growth_executions_v108%rowtype;
  v_rec public.growth_recommendations_v108%rowtype;
  v_result jsonb;
  v_status text;
  v_estimate bigint;
  v_low bigint;
  v_high bigint;
  v_request_hash text;
  v_existing public.growth_execution_results_v108%rowtype;
  v_receipt jsonb;
  -- Freeze one finalization cutoff and persist the result derived from it.
  v_now timestamptz := clock_timestamp();
begin
  if not app.is_salon_owner(p_business) then
    raise exception 'owner only' using errcode = '42501';
  end if;
  v_request_hash := encode(extensions.digest(convert_to(jsonb_build_object(
    'business_id', p_business,
    'execution_id', p_execution
  )::text, 'UTF8'), 'sha256'), 'hex');
  select * into v_existing
  from public.growth_execution_results_v108
  where business_id = p_business and finalized_by = v_actor
    and idempotency_key = p_idempotency_key;
  if found then
    if v_existing.request_hash <> v_request_hash then
      raise exception 'idempotency key reused with a different finalization request'
        using errcode = '23505';
    end if;
    return v_existing.result
      || jsonb_build_object('result_status', v_existing.result_status);
  end if;
  select * into v_execution from public.growth_executions_v108
  where id = p_execution and business_id = p_business for update;
  if not found then raise exception 'execution not found'; end if;
  if not app.can_see_branch(v_execution.business_id, v_execution.branch_id) then
    raise exception 'execution branch is outside actor scope' using errcode = '42501';
  end if;
  if v_execution.status = 'completed' then
    raise exception 'execution was finalized with another idempotency key'
      using errcode = '23505';
  end if;
  if v_execution.status <> 'running' or v_execution.ends_at > v_now then
    raise exception 'execution cannot be finalized before its measurement window closes'
      using errcode = '42501';
  end if;
  select * into v_rec from public.growth_recommendations_v108
  where id = v_execution.recommendation_id;
  v_result := app.get_growth_execution_result_at_v108(p_execution, v_now);
  v_estimate := (v_result #>> '{estimated_incremental_revenue,point_estimate_cents}')::bigint;
  v_low := (v_result #>> '{estimated_incremental_revenue,low_cents}')::bigint;
  v_high := (v_result #>> '{estimated_incremental_revenue,high_cents}')::bigint;
  v_status := case
    when v_result ->> 'measurement_status' = 'invalid_overlap' then 'invalid'
    when v_result ->> 'measurement_status' <> 'final' then 'inconclusive'
    when v_low > 0 then 'won'
    when v_high < 0 then 'lost'
    else 'inconclusive'
  end;
  insert into public.growth_execution_results_v108(
    execution_id, business_id, policy_version, result, prediction, calibration,
    result_status, finalized_by, idempotency_key, request_hash
  ) values (
    p_execution, p_business, v_rec.policy_version, v_result,
    v_rec.expected_incremental_revenue,
    jsonb_build_object(
      'prediction_low_cents', (v_rec.expected_incremental_revenue ->> 'low_cents')::bigint,
      'prediction_high_cents', (v_rec.expected_incremental_revenue ->> 'high_cents')::bigint,
      'observed_point_estimate_cents', v_estimate,
      'inside_predicted_range', case when v_estimate is null then null else
        v_estimate between
          (v_rec.expected_incremental_revenue ->> 'low_cents')::bigint
          and (v_rec.expected_incremental_revenue ->> 'high_cents')::bigint
      end,
      'policy_adjusted_automatically', false
    ),
    v_status, v_actor, p_idempotency_key, v_request_hash
  );
  update public.growth_executions_v108
  set status = 'completed', completed_at = v_now
  where id = p_execution;
  update public.growth_recommendations_v108
  set status = 'completed' where id = v_rec.id;
  insert into public.audit_log(business_id, actor, action, entity, entity_id, detail)
  values (p_business, v_actor, 'FINALIZE_GROWTH_EXECUTION_V108',
    'growth_executions_v108', p_execution,
    jsonb_build_object('result_status', v_status, 'idempotency_key', p_idempotency_key));
  return v_result || jsonb_build_object('result_status', v_status);
end $$;

revoke all privileges on function app.growth_v108_immutable(),
  app.growth_v108_guard_outcome_residual(),
  app.growth_v108_guard_status(),
  app.growth_v108_token(uuid, uuid, uuid, uuid),
  app.growth_v108_effective_parameters(uuid),
  app.get_growth_execution_result_at_v108(uuid, timestamptz),
  app.capture_growth_outcome_v108(),
  app.refresh_growth_outcome_residual_v108()
from public, anon, authenticated;

revoke all privileges on function public.refresh_growth_recommendation_v108(uuid, uuid)
from public, anon;
revoke all privileges on function public.get_growth_daily_briefing_v108(uuid, uuid)
from public, anon;
revoke all privileges on function public.preview_growth_recommendation_v108(uuid, uuid, integer)
from public, anon;
revoke all privileges on function public.dismiss_growth_recommendation_v108(uuid, uuid, text, uuid)
from public, anon;
revoke all privileges on function public.approve_growth_recommendation_v108(uuid, uuid, integer, text, uuid)
from public, anon;
revoke all privileges on function public.customer_get_growth_offers_v108(uuid)
from public, anon;
revoke all privileges on function public.customer_prepare_growth_offer_qr_v108(uuid, uuid)
from public, anon;
revoke all privileges on function public.redeem_growth_offer_v108(uuid, text, uuid, uuid)
from public, anon;
revoke all privileges on function public.get_growth_execution_result_v108(uuid)
from public, anon;
revoke all privileges on function public.finalize_growth_execution_v108(uuid, uuid, uuid)
from public, anon;

grant execute on function public.refresh_growth_recommendation_v108(uuid, uuid),
  public.get_growth_daily_briefing_v108(uuid, uuid),
  public.preview_growth_recommendation_v108(uuid, uuid, integer),
  public.dismiss_growth_recommendation_v108(uuid, uuid, text, uuid),
  public.approve_growth_recommendation_v108(uuid, uuid, integer, text, uuid),
  public.customer_get_growth_offers_v108(uuid),
  public.customer_prepare_growth_offer_qr_v108(uuid, uuid),
  public.redeem_growth_offer_v108(uuid, text, uuid, uuid),
  public.get_growth_execution_result_v108(uuid),
  public.finalize_growth_execution_v108(uuid, uuid, uuid)
to authenticated;

insert into public.audit_log(business_id, actor, action, entity, entity_id, detail)
select b.id, null, 'INSTALL_GROWTH_CLOSED_LOOP_V108',
  'businesses', b.id,
  jsonb_build_object(
    'feature_flag', 'growth_closed_loop_v108',
    'default_enabled', false,
    'incremental_profit_supported', false
  )
from public.businesses b;

commit;
