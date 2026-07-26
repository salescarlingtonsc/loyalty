-- NESTLY v78 - PLATFORM CONSULTANT COMMISSION OPERATIONS
--
-- This is Nestly's own consultant compensation domain. It never reads merchant
-- tender rows, merchant staff or merchant commission views. Accruals are derived
-- only from v77 normalized paid SaaS invoices and their GST-separated cash.

begin;

-- ---------------------------------------------------------------------------
-- 1. Departure truth and versioned commission policy.
-- ---------------------------------------------------------------------------

alter table public.platform_consultants
  add column if not exists departed_at timestamptz;
update public.platform_consultants
   set departed_at=coalesce(departed_at,updated_at,now())
 where not active and departed_at is null;
alter table public.platform_consultants
  drop constraint if exists platform_consultants_active_departure_check;
alter table public.platform_consultants
  add constraint platform_consultants_active_departure_check check (
    (active and departed_at is null)
    or (not active and departed_at is not null)
  );

create table public.consultant_commission_policies (
  id uuid primary key default gen_random_uuid(),
  tier text not null check (tier in ('senior','junior')),
  version integer not null check (version > 0),
  effective_from timestamptz not null,
  effective_to timestamptz,
  first_year_bps integer not null check (first_year_bps between 0 and 10000),
  anniversary_bonus_bps integer not null
    check (anniversary_bonus_bps between 0 and 10000),
  renewal_bps integer not null check (renewal_bps between 0 and 10000),
  constraint consultant_commission_policies_total_rate_check check (
    first_year_bps+anniversary_bonus_bps<=10000
  ),
  basis_rule text not null default 'net_cash_collected_ex_gst_refunds_chargebacks'
    check (basis_rule='net_cash_collected_ex_gst_refunds_chargebacks'),
  setup_fee_included boolean not null default true
    check (setup_fee_included),
  reason text not null check (length(btrim(reason)) between 3 and 1000),
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  constraint consultant_commission_policies_window_check check (
    effective_to is null or effective_to>effective_from
  ),
  unique(tier,version),
  unique(tier,effective_from)
);
create unique index consultant_commission_policies_one_open_uk
  on public.consultant_commission_policies(tier)
  where effective_to is null;

insert into public.consultant_commission_policies(
  tier,version,effective_from,first_year_bps,anniversary_bonus_bps,
  renewal_bps,reason
) values
  ('senior',1,'-infinity',3000,1000,1500,
   'owner seed: first-year base 30%, year-one service bonus 10%, renewals 15%'),
  ('junior',1,'-infinity',2000,500,500,
   'owner seed: first-year base 20%, year-one service bonus 5%, renewals 5%');

create table public.consultant_commission_attributions (
  id uuid primary key default gen_random_uuid(),
  consultant_id uuid not null
    references public.platform_consultants(id) on delete restrict,
  prospect_id uuid not null unique
    references public.sme_prospects(id) on delete restrict,
  business_id uuid not null unique
    references public.businesses(id) on delete restrict,
  onboarding_started_at timestamptz not null,
  reason text not null check (length(btrim(reason)) between 3 and 1000),
  attributed_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now()
);

create table public.consultant_commission_accruals (
  id uuid primary key default gen_random_uuid(),
  attribution_id uuid not null
    references public.consultant_commission_attributions(id) on delete restrict,
  consultant_id uuid not null
    references public.platform_consultants(id) on delete restrict,
  business_id uuid not null references public.businesses(id) on delete restrict,
  invoice_id uuid not null
    references public.billing_provider_invoices(id) on delete restrict,
  provider_invoice_id text not null,
  policy_id uuid not null
    references public.consultant_commission_policies(id) on delete restrict,
  tier_snapshot text not null check (tier_snapshot in ('senior','junior')),
  commission_phase text not null
    check (commission_phase in ('first_year_base','anniversary_bonus','renewal')),
  onboarding_started_at timestamptz not null,
  invoice_paid_at timestamptz not null,
  eligible_at timestamptz not null,
  basis_cents integer not null check (basis_cents > 0),
  rate_bps integer not null check (rate_bps between 0 and 10000),
  commission_cents integer not null check (commission_cents >= 0),
  currency text not null check (currency ~ '^[A-Z]{3}$'),
  status text not null check (
    status in ('accrued','approved','paid','forfeited')
  ),
  approved_by uuid references auth.users(id) on delete set null,
  approved_at timestamptz,
  forfeited_at timestamptz,
  forfeiture_reason text,
  created_at timestamptz not null default now(),
  unique(invoice_id,commission_phase),
  unique(provider_invoice_id,commission_phase),
  constraint consultant_commission_accruals_eligibility_check check (
    eligible_at>=invoice_paid_at
  ),
  constraint consultant_commission_accruals_status_shape check (
    (status='accrued' and approved_at is null and forfeited_at is null)
    or (status in ('approved','paid') and approved_at is not null and forfeited_at is null)
    or (
      status='forfeited' and forfeited_at is not null
      and length(btrim(coalesce(forfeiture_reason,'')))>=3
    )
  )
);
create index consultant_commission_accruals_consultant_idx
  on public.consultant_commission_accruals(consultant_id,status,invoice_paid_at desc);

create table public.consultant_commission_adjustments (
  id uuid primary key default gen_random_uuid(),
  accrual_id uuid not null
    references public.consultant_commission_accruals(id) on delete restrict,
  consultant_id uuid not null
    references public.platform_consultants(id) on delete restrict,
  billing_adjustment_id uuid not null
    references public.billing_adjustments(id) on delete restrict,
  reversal_of uuid unique
    references public.consultant_commission_adjustments(id) on delete restrict,
  adjustment_type text not null
    check (adjustment_type in ('refund','chargeback','reversal')),
  basis_adjustment_cents integer not null,
  rate_bps integer not null check (rate_bps between 0 and 10000),
  commission_adjustment_cents integer not null,
  settlement_status text not null
    check (settlement_status in ('payable','forfeited_to_nestly')),
  occurred_at timestamptz not null,
  created_at timestamptz not null default now(),
  unique(billing_adjustment_id,accrual_id),
  constraint consultant_commission_adjustments_shape_check check (
    (
      adjustment_type in ('refund','chargeback')
      and reversal_of is null
      and basis_adjustment_cents < 0
      and commission_adjustment_cents <= 0
    )
    or (
      adjustment_type='reversal'
      and reversal_of is not null
      and basis_adjustment_cents > 0
      and commission_adjustment_cents >= 0
    )
  )
);
create index consultant_commission_adjustments_consultant_idx
  on public.consultant_commission_adjustments(
    consultant_id,settlement_status,occurred_at desc
  );

create table public.consultant_payout_batches (
  id uuid primary key default gen_random_uuid(),
  currency text not null check (currency ~ '^[A-Z]{3}$'),
  status text not null default 'draft'
    check (status in ('draft','approved','processing','paid','void')),
  note text,
  created_by uuid not null references auth.users(id) on delete restrict,
  created_at timestamptz not null default now(),
  approved_by uuid references auth.users(id) on delete restrict,
  approved_at timestamptz,
  paid_at timestamptz,
  voided_at timestamptz,
  constraint consultant_payout_batches_status_shape check (
    (status='draft' and approved_at is null and paid_at is null and voided_at is null)
    or (status in ('approved','processing') and approved_at is not null and paid_at is null and voided_at is null)
    or (status='paid' and approved_at is not null and paid_at is not null and voided_at is null)
    or (status='void' and paid_at is null and voided_at is not null)
  )
);

create table public.consultant_payout_lines (
  id uuid primary key default gen_random_uuid(),
  batch_id uuid not null
    references public.consultant_payout_batches(id) on delete restrict,
  accrual_id uuid not null
    references public.consultant_commission_accruals(id) on delete restrict,
  consultant_id uuid not null
    references public.platform_consultants(id) on delete restrict,
  amount_cents integer not null check (amount_cents > 0),
  created_at timestamptz not null default now(),
  unique(batch_id,accrual_id)
);
create index consultant_payout_lines_accrual_idx
  on public.consultant_payout_lines(accrual_id);

create table public.consultant_payout_payments (
  id uuid primary key default gen_random_uuid(),
  line_id uuid not null
    references public.consultant_payout_lines(id) on delete restrict,
  amount_cents integer not null check (amount_cents > 0),
  payment_reference text not null unique
    check (length(btrim(payment_reference)) between 3 and 240),
  paid_at timestamptz not null,
  recorded_by uuid not null references auth.users(id) on delete restrict,
  created_at timestamptz not null default now()
);
create index consultant_payout_payments_line_idx
  on public.consultant_payout_payments(line_id,paid_at);

alter table public.consultant_commission_policies enable row level security;
revoke all privileges on table public.consultant_commission_policies from public, anon, authenticated;
alter table public.consultant_commission_attributions enable row level security;
revoke all privileges on table public.consultant_commission_attributions from public, anon, authenticated;
alter table public.consultant_commission_accruals enable row level security;
revoke all privileges on table public.consultant_commission_accruals from public, anon, authenticated;
alter table public.consultant_commission_adjustments enable row level security;
revoke all privileges on table public.consultant_commission_adjustments from public, anon, authenticated;
alter table public.consultant_payout_batches enable row level security;
revoke all privileges on table public.consultant_payout_batches from public, anon, authenticated;
alter table public.consultant_payout_lines enable row level security;
revoke all privileges on table public.consultant_payout_lines from public, anon, authenticated;
alter table public.consultant_payout_payments enable row level security;
revoke all privileges on table public.consultant_payout_payments from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 2. Immutable snapshots and bounded lifecycle transitions.
-- ---------------------------------------------------------------------------

create or replace function app.consultant_policy_guard_v78()
returns trigger
language plpgsql
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
begin
  if tg_op='DELETE' then
    raise exception 'consultant commission policies are versioned, not deleted'
      using errcode='restrict_violation';
  end if;
  if old.effective_to is not null
     or (
       new.id,new.tier,new.version,new.effective_from,new.first_year_bps,
       new.anniversary_bonus_bps,new.renewal_bps,new.basis_rule,
       new.setup_fee_included,new.reason,
       new.created_by,new.created_at
     ) is distinct from (
       old.id,old.tier,old.version,old.effective_from,old.first_year_bps,
       old.anniversary_bonus_bps,old.renewal_bps,old.basis_rule,
       old.setup_fee_included,old.reason,
       old.created_by,old.created_at
     )
     or new.effective_to is null
     or new.effective_to<=new.effective_from then
    raise exception 'only the open policy effective_to may be closed once'
      using errcode='restrict_violation';
  end if;
  return new;
end
$$;
revoke all on function app.consultant_policy_guard_v78()
  from public,anon,authenticated;
create trigger consultant_commission_policies_guard
  before update or delete on public.consultant_commission_policies
  for each row execute function app.consultant_policy_guard_v78();

create or replace function app.consultant_attribution_guard_v78()
returns trigger
language plpgsql
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
begin
  raise exception 'consultant commission attribution is immutable'
    using errcode='restrict_violation';
end
$$;
revoke all on function app.consultant_attribution_guard_v78()
  from public,anon,authenticated;
create trigger consultant_commission_attributions_guard
  before update or delete on public.consultant_commission_attributions
  for each row execute function app.consultant_attribution_guard_v78();

create or replace function app.consultant_accrual_guard_v78()
returns trigger
language plpgsql
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
begin
  if tg_op='DELETE' then
    raise exception 'consultant commission accruals are not deleted'
      using errcode='restrict_violation';
  end if;
  if (
    new.id,new.attribution_id,new.consultant_id,new.business_id,new.invoice_id,
    new.provider_invoice_id,new.policy_id,new.tier_snapshot,new.commission_phase,
    new.onboarding_started_at,new.invoice_paid_at,new.eligible_at,
    new.basis_cents,new.rate_bps,new.commission_cents,new.currency,new.created_at
  ) is distinct from (
    old.id,old.attribution_id,old.consultant_id,old.business_id,old.invoice_id,
    old.provider_invoice_id,old.policy_id,old.tier_snapshot,old.commission_phase,
    old.onboarding_started_at,old.invoice_paid_at,old.eligible_at,
    old.basis_cents,old.rate_bps,old.commission_cents,old.currency,old.created_at
  ) then
    raise exception 'consultant accrual snapshot is immutable'
      using errcode='restrict_violation';
  end if;
  if not (
    (old.status='accrued' and new.status in ('approved','forfeited'))
    or (old.status='approved' and new.status in ('paid','forfeited'))
    or (old.status=new.status)
  ) then
    raise exception 'invalid consultant accrual lifecycle transition'
      using errcode='restrict_violation';
  end if;
  return new;
end
$$;
revoke all on function app.consultant_accrual_guard_v78()
  from public,anon,authenticated;
create trigger consultant_commission_accruals_guard
  before update or delete on public.consultant_commission_accruals
  for each row execute function app.consultant_accrual_guard_v78();

create or replace function app.consultant_append_only_guard_v78()
returns trigger
language plpgsql
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
begin
  raise exception '% is append-only',tg_table_name
    using errcode='restrict_violation';
end
$$;
revoke all on function app.consultant_append_only_guard_v78()
  from public,anon,authenticated;
create trigger consultant_commission_adjustments_append_only
  before update or delete on public.consultant_commission_adjustments
  for each row execute function app.consultant_append_only_guard_v78();
create trigger consultant_payout_payments_append_only
  before update or delete on public.consultant_payout_payments
  for each row execute function app.consultant_append_only_guard_v78();

-- ---------------------------------------------------------------------------
-- 3. Attribution core for v79 conversion and SA wrapper.
-- ---------------------------------------------------------------------------

create or replace function app.attribute_consultant_core_v78(
  p_consultant uuid,
  p_prospect uuid,
  p_business uuid,
  p_onboarding_started_at timestamptz,
  p_reason text,
  p_actor uuid
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_existing public.consultant_commission_attributions%rowtype;
  v_result public.consultant_commission_attributions%rowtype;
begin
  if p_consultant is null or p_prospect is null or p_business is null
     or p_onboarding_started_at is null
     or nullif(btrim(p_reason),'') is null or length(p_reason)>1000 then
    raise exception 'complete consultant attribution is required'
      using errcode='22023';
  end if;
  if not exists(
    select 1 from public.platform_consultants consultant
     where consultant.id=p_consultant
       and consultant.active
       and consultant.departed_at is null
  ) then
    raise exception 'active platform consultant was not found'
      using errcode='22023';
  end if;
  if not exists(
    select 1 from public.sme_prospects prospect
     where prospect.id=p_prospect
       and prospect.assigned_consultant_id=p_consultant
       and prospect.converted_business_id=p_business
  ) then
    raise exception 'converted prospect, business and consultant do not agree'
      using errcode='22023';
  end if;
  select * into v_existing
    from public.consultant_commission_attributions
   where prospect_id=p_prospect or business_id=p_business
   for update;
  if found then
    if v_existing.consultant_id<>p_consultant
       or v_existing.prospect_id<>p_prospect
       or v_existing.business_id<>p_business
       or v_existing.onboarding_started_at<>p_onboarding_started_at then
      raise exception 'consultant attribution conflicts with immutable history'
        using errcode='22023';
    end if;
    return to_jsonb(v_existing);
  end if;
  insert into public.consultant_commission_attributions(
    consultant_id,prospect_id,business_id,onboarding_started_at,reason,attributed_by
  ) values (
    p_consultant,p_prospect,p_business,p_onboarding_started_at,btrim(p_reason),p_actor
  ) returning * into v_result;
  insert into public.audit_log(
    business_id,actor,action,entity,entity_id,detail
  ) values (
    p_business,p_actor,'CONSULTANT_COMMISSION_ATTRIBUTED_V78',
    'consultant_commission_attributions',v_result.id,
    jsonb_build_object(
      'consultant_id',p_consultant,'prospect_id',p_prospect,
      'onboarding_started_at',p_onboarding_started_at,'reason',btrim(p_reason)
    )
  );
  return to_jsonb(v_result);
end
$$;
revoke all on function app.attribute_consultant_core_v78(
  uuid,uuid,uuid,timestamptz,text,uuid
) from public,anon,authenticated;

create or replace function public.attribute_consultant_v78(
  p_consultant uuid,
  p_prospect uuid,
  p_business uuid,
  p_onboarding_started_at timestamptz,
  p_reason text
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
begin
  if auth.uid() is null or not app.is_super_admin() then
    raise exception 'super-admin access is required' using errcode='42501';
  end if;
  return app.attribute_consultant_core_v78(
    p_consultant,p_prospect,p_business,p_onboarding_started_at,p_reason,auth.uid()
  );
end
$$;
revoke all on function public.attribute_consultant_v78(
  uuid,uuid,uuid,timestamptz,text
) from public,anon,authenticated;
grant execute on function public.attribute_consultant_v78(
  uuid,uuid,uuid,timestamptz,text
) to authenticated;

-- ---------------------------------------------------------------------------
-- 4. Paid invoice accrual and refund/chargeback compensation.
-- ---------------------------------------------------------------------------

create or replace function app.accrue_consultant_invoice_v78(p_invoice uuid)
returns uuid
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_invoice public.billing_provider_invoices%rowtype;
  v_attribution public.consultant_commission_attributions%rowtype;
  v_consultant public.platform_consultants%rowtype;
  v_policy public.consultant_commission_policies%rowtype;
  v_status text;
  v_id uuid;
begin
  select * into v_invoice
    from public.billing_provider_invoices
   where id=p_invoice and paid_normalized and paid_at is not null
   for key share;
  if not found or v_invoice.net_cash_ex_tax_cents<=0 then return null; end if;
  select * into v_attribution
    from public.consultant_commission_attributions
   where business_id=v_invoice.business_id;
  if not found then return null; end if;
  select * into strict v_consultant
    from public.platform_consultants where id=v_attribution.consultant_id;
  select * into v_policy
    from public.consultant_commission_policies
   where tier=v_consultant.tier
     and effective_from<=v_invoice.paid_at
     and (effective_to is null or v_invoice.paid_at<effective_to)
   order by version desc limit 1;
  if not found then
    raise exception 'consultant commission policy is missing for paid invoice';
  end if;
  v_status := case
    when v_consultant.active
      and v_consultant.departed_at is null
      and v_consultant.employment_started_on<=v_invoice.paid_at::date
      and v_invoice.paid_at>=v_attribution.onboarding_started_at
      then 'accrued'
    else 'forfeited'
  end;
  if v_invoice.paid_at <
       v_attribution.onboarding_started_at+interval '12 months' then
    insert into public.consultant_commission_accruals(
      attribution_id,consultant_id,business_id,invoice_id,provider_invoice_id,
      policy_id,tier_snapshot,commission_phase,onboarding_started_at,
      invoice_paid_at,eligible_at,basis_cents,rate_bps,commission_cents,
      currency,status,forfeited_at,forfeiture_reason
    ) values (
      v_attribution.id,v_consultant.id,v_invoice.business_id,v_invoice.id,
      v_invoice.provider_invoice_id,v_policy.id,v_consultant.tier,
      'first_year_base',v_attribution.onboarding_started_at,v_invoice.paid_at,
      v_invoice.paid_at,v_invoice.net_cash_ex_tax_cents,
      v_policy.first_year_bps,
      floor(
        v_invoice.net_cash_ex_tax_cents::numeric
        *v_policy.first_year_bps::numeric/10000
      )::integer,
      v_invoice.currency,v_status,
      case when v_status='forfeited' then now() end,
      case when v_status='forfeited'
           then 'consultant inactive or departed at accrual time; forfeited to Nestly' end
    )
    on conflict(invoice_id,commission_phase) do nothing
    returning id into v_id;

    -- The anniversary component is visible from the invoice date for complete
    -- forecasting, but cannot be approved or paid until the first service year
    -- is complete and the consultant is still employed.
    insert into public.consultant_commission_accruals(
      attribution_id,consultant_id,business_id,invoice_id,provider_invoice_id,
      policy_id,tier_snapshot,commission_phase,onboarding_started_at,
      invoice_paid_at,eligible_at,basis_cents,rate_bps,commission_cents,
      currency,status,forfeited_at,forfeiture_reason
    ) values (
      v_attribution.id,v_consultant.id,v_invoice.business_id,v_invoice.id,
      v_invoice.provider_invoice_id,v_policy.id,v_consultant.tier,
      'anniversary_bonus',v_attribution.onboarding_started_at,v_invoice.paid_at,
      v_attribution.onboarding_started_at+interval '12 months',
      v_invoice.net_cash_ex_tax_cents,v_policy.anniversary_bonus_bps,
      floor(
        v_invoice.net_cash_ex_tax_cents::numeric
        *v_policy.anniversary_bonus_bps::numeric/10000
      )::integer,
      v_invoice.currency,v_status,
      case when v_status='forfeited' then now() end,
      case when v_status='forfeited'
           then 'consultant inactive or departed at accrual time; forfeited to Nestly' end
    )
    on conflict(invoice_id,commission_phase) do nothing;
  else
    insert into public.consultant_commission_accruals(
      attribution_id,consultant_id,business_id,invoice_id,provider_invoice_id,
      policy_id,tier_snapshot,commission_phase,onboarding_started_at,
      invoice_paid_at,eligible_at,basis_cents,rate_bps,commission_cents,
      currency,status,forfeited_at,forfeiture_reason
    ) values (
      v_attribution.id,v_consultant.id,v_invoice.business_id,v_invoice.id,
      v_invoice.provider_invoice_id,v_policy.id,v_consultant.tier,
      'renewal',v_attribution.onboarding_started_at,v_invoice.paid_at,
      v_invoice.paid_at,v_invoice.net_cash_ex_tax_cents,v_policy.renewal_bps,
      floor(
        v_invoice.net_cash_ex_tax_cents::numeric
        *v_policy.renewal_bps::numeric/10000
      )::integer,
      v_invoice.currency,v_status,
      case when v_status='forfeited' then now() end,
      case when v_status='forfeited'
           then 'consultant inactive or departed at accrual time; forfeited to Nestly' end
    )
    on conflict(invoice_id,commission_phase) do nothing
    returning id into v_id;
  end if;
  if v_id is null then
    select id into v_id from public.consultant_commission_accruals
     where invoice_id=p_invoice
     order by case commission_phase
       when 'first_year_base' then 1
       when 'renewal' then 2
       else 3
     end
     limit 1;
  end if;
  return v_id;
end
$$;
revoke all on function app.accrue_consultant_invoice_v78(uuid)
  from public,anon,authenticated;

create or replace function app.on_paid_invoice_consultant_v78()
returns trigger
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
begin
  if new.paid_normalized and new.paid_at is not null
     and (tg_op='INSERT' or not coalesce(old.paid_normalized,false)) then
    perform app.accrue_consultant_invoice_v78(new.id);
  end if;
  return new;
end
$$;
revoke all on function app.on_paid_invoice_consultant_v78()
  from public,anon,authenticated;
create trigger billing_invoice_consultant_accrual_v78
  after insert or update of paid_normalized,paid_at
  on public.billing_provider_invoices
  for each row execute function app.on_paid_invoice_consultant_v78();

create or replace function app.adjust_consultant_commission_v78(
  p_billing_adjustment uuid
)
returns uuid
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_adjustment public.billing_adjustments%rowtype;
  v_reversed public.consultant_commission_adjustments%rowtype;
  v_accrual public.consultant_commission_accruals%rowtype;
  v_consultant public.platform_consultants%rowtype;
  v_prior_basis integer;
  v_prior_commission integer;
  v_basis integer;
  v_commission integer;
  v_id uuid;
  v_inserted uuid;
begin
  select * into v_adjustment
    from public.billing_adjustments
   where id=p_billing_adjustment
     and adjustment_type in ('refund','chargeback','reversal')
   for key share;
  if not found then return null; end if;
  if v_adjustment.adjustment_type='reversal' then
    for v_reversed in
      select commission_adjustment.*
        from public.consultant_commission_adjustments commission_adjustment
        join public.billing_adjustments billing_adjustment
          on billing_adjustment.id=commission_adjustment.billing_adjustment_id
       where commission_adjustment.billing_adjustment_id=v_adjustment.reversal_of
         and commission_adjustment.adjustment_type in ('refund','chargeback')
         and billing_adjustment.business_id=v_adjustment.business_id
         and billing_adjustment.provider_invoice_id
               is not distinct from v_adjustment.provider_invoice_id
       order by commission_adjustment.id
       for key share of commission_adjustment
    loop
      select * into strict v_accrual
        from public.consultant_commission_accruals
       where id=v_reversed.accrual_id;
      select * into strict v_consultant
        from public.platform_consultants where id=v_accrual.consultant_id;
      v_inserted:=null;
      insert into public.consultant_commission_adjustments(
        accrual_id,consultant_id,billing_adjustment_id,reversal_of,
        adjustment_type,basis_adjustment_cents,rate_bps,
        commission_adjustment_cents,settlement_status,occurred_at
      ) values (
        v_accrual.id,v_accrual.consultant_id,v_adjustment.id,v_reversed.id,
        'reversal',-v_reversed.basis_adjustment_cents,v_accrual.rate_bps,
        -v_reversed.commission_adjustment_cents,
        case when v_consultant.active and v_consultant.departed_at is null
             then 'payable' else 'forfeited_to_nestly' end,
        v_adjustment.occurred_at
      )
      on conflict(billing_adjustment_id,accrual_id) do nothing
      returning id into v_inserted;
      v_id:=coalesce(v_id,v_inserted);
    end loop;
    return v_id;
  end if;
  for v_accrual in
    select accrual.*
      from public.consultant_commission_accruals accrual
     where accrual.provider_invoice_id=v_adjustment.provider_invoice_id
     order by accrual.commission_phase
  loop
    select * into strict v_consultant
      from public.platform_consultants where id=v_accrual.consultant_id;
    select coalesce(sum(-basis_adjustment_cents),0),
           coalesce(sum(-commission_adjustment_cents),0)
      into v_prior_basis,v_prior_commission
      from public.consultant_commission_adjustments
     where accrual_id=v_accrual.id;
    v_basis := least(
      greatest(-v_adjustment.subtotal_ex_tax_cents,0),
      greatest(v_accrual.basis_cents-v_prior_basis,0)
    );
    v_commission := least(
      floor(v_basis::numeric*v_accrual.rate_bps::numeric/10000)::integer,
      greatest(v_accrual.commission_cents-v_prior_commission,0)
    );
    if v_basis>0 then
      v_inserted:=null;
      insert into public.consultant_commission_adjustments(
        accrual_id,consultant_id,billing_adjustment_id,adjustment_type,
        basis_adjustment_cents,rate_bps,commission_adjustment_cents,
        settlement_status,occurred_at
      ) values (
        v_accrual.id,v_accrual.consultant_id,v_adjustment.id,
        v_adjustment.adjustment_type,-v_basis,v_accrual.rate_bps,-v_commission,
        case when v_consultant.active and v_consultant.departed_at is null
             then 'payable' else 'forfeited_to_nestly' end,
        v_adjustment.occurred_at
      )
      on conflict(billing_adjustment_id,accrual_id) do nothing
      returning id into v_inserted;
      v_id:=coalesce(v_id,v_inserted);
    end if;
  end loop;
  return v_id;
end
$$;
revoke all on function app.adjust_consultant_commission_v78(uuid)
  from public,anon,authenticated;

create or replace function app.on_billing_adjustment_consultant_v78()
returns trigger
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
begin
  if new.adjustment_type in ('refund','chargeback','reversal') then
    perform app.adjust_consultant_commission_v78(new.id);
  end if;
  return new;
end
$$;
revoke all on function app.on_billing_adjustment_consultant_v78()
  from public,anon,authenticated;
create trigger billing_adjustment_consultant_v78
  after insert on public.billing_adjustments
  for each row execute function app.on_billing_adjustment_consultant_v78();

create or replace function app.consultant_anniversary_qualified_v78(
  p_business uuid,
  p_anniversary timestamptz
)
returns boolean
language sql
stable
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
  select coalesce((
    select case
      when subscription.billing_provider='stripe' then exists(
        select 1
          from public.billing_provider_invoices invoice
         where invoice.business_id=p_business
           and invoice.paid_normalized
           and invoice.paid_at>=p_anniversary
      )
      else subscription.status='active'
    end
      from public.subscriptions subscription
     where subscription.business_id=p_business
  ),false)
$$;
revoke all on function app.consultant_anniversary_qualified_v78(
  uuid,timestamptz
) from public,anon,authenticated;

-- Idempotent backfill if v78 follows existing paid/refunded test-mode invoices.
select app.accrue_consultant_invoice_v78(id)
  from public.billing_provider_invoices
 where paid_normalized and paid_at is not null;
select app.adjust_consultant_commission_v78(id)
  from public.billing_adjustments
 where adjustment_type in ('refund','chargeback','reversal')
 order by occurred_at,id;

-- ---------------------------------------------------------------------------
-- 5. Policy, departure, approval and payout RPCs.
-- ---------------------------------------------------------------------------

create or replace function public.create_consultant_commission_policy_v78(
  p_tier text,
  p_first_year_bps integer,
  p_anniversary_bonus_bps integer,
  p_renewal_bps integer,
  p_effective_from timestamptz,
  p_reason text
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_actor uuid:=auth.uid();
  v_prior public.consultant_commission_policies%rowtype;
  v_new public.consultant_commission_policies%rowtype;
begin
  if v_actor is null or not app.is_super_admin() then
    raise exception 'super-admin access is required' using errcode='42501';
  end if;
  if p_tier not in ('senior','junior')
     or p_first_year_bps not between 0 and 10000
     or p_anniversary_bonus_bps not between 0 and 10000
     or p_first_year_bps+p_anniversary_bonus_bps>10000
     or p_renewal_bps not between 0 and 10000
     or p_effective_from is null
     or p_effective_from<now()-interval '5 minutes'
     or nullif(btrim(p_reason),'') is null or length(p_reason)>1000 then
    raise exception 'invalid consultant commission policy' using errcode='22023';
  end if;
  perform pg_advisory_xact_lock(hashtextextended(
    'v78:consultant-policy:'||p_tier,0
  ));
  select * into strict v_prior
    from public.consultant_commission_policies
   where tier=p_tier and effective_to is null
   for update;
  if p_effective_from<=v_prior.effective_from then
    raise exception 'new policy must start after the open version'
      using errcode='22023';
  end if;
  update public.consultant_commission_policies
     set effective_to=p_effective_from
   where id=v_prior.id;
  insert into public.consultant_commission_policies(
    tier,version,effective_from,first_year_bps,anniversary_bonus_bps,
    renewal_bps,reason,created_by
  ) values (
    p_tier,v_prior.version+1,p_effective_from,p_first_year_bps,
    p_anniversary_bonus_bps,p_renewal_bps,btrim(p_reason),v_actor
  ) returning * into v_new;
  insert into public.audit_log(
    business_id,actor,action,entity,entity_id,detail
  ) values (
    null,v_actor,'CONSULTANT_COMMISSION_POLICY_VERSIONED_V78',
    'consultant_commission_policies',v_new.id,
    jsonb_build_object(
      'tier',p_tier,'version',v_new.version,
      'first_year_bps',p_first_year_bps,
      'anniversary_bonus_bps',p_anniversary_bonus_bps,
      'renewal_bps',p_renewal_bps,
      'effective_from',p_effective_from,'reason',btrim(p_reason)
    )
  );
  return to_jsonb(v_new);
end
$$;
revoke all on function public.create_consultant_commission_policy_v78(
  text,integer,integer,integer,timestamptz,text
) from public,anon,authenticated;
grant execute on function public.create_consultant_commission_policy_v78(
  text,integer,integer,integer,timestamptz,text
) to authenticated;

create or replace function app.forfeit_consultant_core_v78(
  p_consultant uuid,
  p_departed_at timestamptz,
  p_reason text,
  p_actor uuid
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_count integer;
  v_row public.platform_consultants%rowtype;
begin
  if p_departed_at is null or p_departed_at>now()+interval '5 minutes'
     or nullif(btrim(p_reason),'') is null or length(p_reason)>1000 then
    raise exception 'valid consultant departure evidence is required'
      using errcode='22023';
  end if;
  select * into v_row from public.platform_consultants
   where id=p_consultant for update;
  if not found then
    raise exception 'platform consultant was not found' using errcode='22023';
  end if;
  update public.platform_consultants
     set active=false,
         departed_at=coalesce(departed_at,p_departed_at),
         updated_at=now()
   where id=p_consultant
   returning * into v_row;
  update public.consultant_commission_accruals
     set status='forfeited',forfeited_at=p_departed_at,
         forfeiture_reason=btrim(p_reason)
   where consultant_id=p_consultant and status in ('accrued','approved');
  get diagnostics v_count=row_count;
  insert into public.audit_log(
    business_id,actor,action,entity,entity_id,detail
  ) values (
    null,p_actor,'CONSULTANT_COMMISSION_FORFEITED_V78',
    'platform_consultants',p_consultant,
    jsonb_build_object(
      'departed_at',v_row.departed_at,'forfeited_accruals',v_count,
      'reason',btrim(p_reason),'previously_paid_final',true
    )
  );
  return jsonb_build_object(
    'consultant',to_jsonb(v_row)-'user_id','forfeited_accruals',v_count
  );
end
$$;
revoke all on function app.forfeit_consultant_core_v78(
  uuid,timestamptz,text,uuid
) from public,anon,authenticated;

create or replace function public.forfeit_consultant_open_commission_v78(
  p_consultant uuid,
  p_departed_at timestamptz,
  p_reason text
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
begin
  if auth.uid() is null or not app.is_super_admin() then
    raise exception 'super-admin access is required' using errcode='42501';
  end if;
  return app.forfeit_consultant_core_v78(
    p_consultant,p_departed_at,p_reason,auth.uid()
  );
end
$$;
revoke all on function public.forfeit_consultant_open_commission_v78(
  uuid,timestamptz,text
) from public,anon,authenticated;
grant execute on function public.forfeit_consultant_open_commission_v78(
  uuid,timestamptz,text
) to authenticated;

-- Preserve v75's exact directory signature while making departure impossible
-- to bypass through the existing platform console.
create or replace function public.platform_upsert_consultant_v75(
  p_consultant uuid,
  p_user uuid,
  p_display_name text,
  p_tier text,
  p_employment_started_on date,
  p_active boolean
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_actor uuid:=auth.uid();
  v_row public.platform_consultants%rowtype;
begin
  if v_actor is null or not app.is_super_admin() then
    raise exception 'super admin access is required' using errcode='42501';
  end if;
  if p_consultant is null then
    insert into public.platform_consultants(
      user_id,display_name,tier,employment_started_on,active,departed_at,created_by
    ) values (
      p_user,btrim(p_display_name),p_tier,p_employment_started_on,
      coalesce(p_active,true),
      case when p_active is false then now() end,v_actor
    ) returning * into v_row;
  else
    if p_active is false then
      perform app.forfeit_consultant_core_v78(
        p_consultant,now(),'directory deactivation via v75 compatibility RPC',v_actor
      );
    end if;
    update public.platform_consultants
       set user_id=p_user,display_name=btrim(p_display_name),tier=p_tier,
           employment_started_on=p_employment_started_on,
           active=coalesce(p_active,active),
           departed_at=case
             when p_active is true then null
             when p_active is false then coalesce(departed_at,now())
             else departed_at
           end,
           updated_at=now()
     where id=p_consultant returning * into v_row;
    if not found then
      raise exception 'platform consultant was not found' using errcode='22023';
    end if;
  end if;
  insert into public.audit_log(
    business_id,actor,action,entity,entity_id,detail
  ) values (
    null,v_actor,'PLATFORM_CONSULTANT_UPSERT_V75','platform_consultants',
    v_row.id,to_jsonb(v_row)-'user_id'
  );
  return jsonb_build_object('consultant',to_jsonb(v_row));
end
$$;
revoke all on function public.platform_upsert_consultant_v75(
  uuid,uuid,text,text,date,boolean
) from public,anon,authenticated;
grant execute on function public.platform_upsert_consultant_v75(
  uuid,uuid,text,text,date,boolean
) to authenticated;

create or replace function public.approve_consultant_accrual_v78(
  p_accrual uuid,
  p_reason text
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_actor uuid:=auth.uid();
  v_row public.consultant_commission_accruals%rowtype;
begin
  if v_actor is null or not app.is_super_admin() then
    raise exception 'super-admin access is required' using errcode='42501';
  end if;
  if nullif(btrim(p_reason),'') is null then
    raise exception 'approval reason is required' using errcode='22023';
  end if;
  select accrual.* into v_row
    from public.consultant_commission_accruals accrual
    join public.platform_consultants consultant
      on consultant.id=accrual.consultant_id
   where accrual.id=p_accrual and accrual.status='accrued'
     and consultant.active and consultant.departed_at is null
     and now()>=accrual.eligible_at
     and (
       accrual.commission_phase<>'anniversary_bonus'
       or app.consultant_anniversary_qualified_v78(
         accrual.business_id,accrual.eligible_at
       )
     )
   for update of accrual;
  if not found then
    raise exception 'active and payable accrued commission was not found'
      using errcode='22023';
  end if;
  update public.consultant_commission_accruals
     set status='approved',approved_by=v_actor,approved_at=now()
   where id=p_accrual returning * into v_row;
  insert into public.audit_log(
    business_id,actor,action,entity,entity_id,detail
  ) values (
    v_row.business_id,v_actor,'CONSULTANT_COMMISSION_APPROVED_V78',
    'consultant_commission_accruals',v_row.id,
    jsonb_build_object('commission_cents',v_row.commission_cents,'reason',btrim(p_reason))
  );
  return to_jsonb(v_row);
end
$$;
revoke all on function public.approve_consultant_accrual_v78(uuid,text)
  from public,anon,authenticated;
grant execute on function public.approve_consultant_accrual_v78(uuid,text)
  to authenticated;

create or replace function public.create_consultant_payout_batch_v78(
  p_currency text,
  p_note text
)
returns uuid
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare v_id uuid;
begin
  if auth.uid() is null or not app.is_super_admin() then
    raise exception 'super-admin access is required' using errcode='42501';
  end if;
  if p_currency !~ '^[A-Z]{3}$' or length(coalesce(p_note,''))>1000 then
    raise exception 'invalid payout batch' using errcode='22023';
  end if;
  insert into public.consultant_payout_batches(currency,note,created_by)
  values(p_currency,nullif(btrim(p_note),''),auth.uid()) returning id into v_id;
  return v_id;
end
$$;
revoke all on function public.create_consultant_payout_batch_v78(text,text)
  from public,anon,authenticated;
grant execute on function public.create_consultant_payout_batch_v78(text,text)
  to authenticated;

create or replace function public.add_consultant_payout_line_v78(
  p_batch uuid,
  p_accrual uuid,
  p_amount_cents integer
)
returns uuid
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_batch public.consultant_payout_batches%rowtype;
  v_accrual public.consultant_commission_accruals%rowtype;
  v_net integer;
  v_allocated integer;
  v_id uuid;
begin
  if auth.uid() is null or not app.is_super_admin() then
    raise exception 'super-admin access is required' using errcode='42501';
  end if;
  select * into v_batch from public.consultant_payout_batches
   where id=p_batch and status='draft' for update;
  if not found then raise exception 'draft payout batch was not found' using errcode='22023'; end if;
  select accrual.* into v_accrual
    from public.consultant_commission_accruals accrual
    join public.platform_consultants consultant on consultant.id=accrual.consultant_id
   where accrual.id=p_accrual and accrual.status in ('approved','paid')
     and consultant.active and consultant.departed_at is null
   for update of accrual;
  if not found or v_accrual.currency<>v_batch.currency then
    raise exception 'approved or reopened paid accrual in batch currency was not found'
      using errcode='22023';
  end if;
  select v_accrual.commission_cents+coalesce(sum(
    case when settlement_status='payable' then commission_adjustment_cents else 0 end
  ),0) into v_net
    from public.consultant_commission_adjustments
   where accrual_id=v_accrual.id;
  select coalesce(sum(amount_cents),0) into v_allocated
    from public.consultant_payout_lines where accrual_id=v_accrual.id;
  if p_amount_cents<=0 or p_amount_cents>greatest(v_net-v_allocated,0) then
    raise exception 'payout line exceeds unallocated consultant commission'
      using errcode='22023';
  end if;
  insert into public.consultant_payout_lines(
    batch_id,accrual_id,consultant_id,amount_cents
  ) values (
    p_batch,p_accrual,v_accrual.consultant_id,p_amount_cents
  ) returning id into v_id;
  return v_id;
end
$$;
revoke all on function public.add_consultant_payout_line_v78(
  uuid,uuid,integer
) from public,anon,authenticated;
grant execute on function public.add_consultant_payout_line_v78(
  uuid,uuid,integer
) to authenticated;

create or replace function public.approve_consultant_payout_batch_v78(p_batch uuid)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare v_row public.consultant_payout_batches%rowtype;
begin
  if auth.uid() is null or not app.is_super_admin() then
    raise exception 'super-admin access is required' using errcode='42501';
  end if;
  select * into v_row from public.consultant_payout_batches
   where id=p_batch and status='draft' for update;
  if not found or not exists(
    select 1 from public.consultant_payout_lines where batch_id=p_batch
  ) then
    raise exception 'non-empty draft payout batch was not found' using errcode='22023';
  end if;
  if exists(
    select 1
      from public.consultant_payout_lines line
      join public.platform_consultants consultant on consultant.id=line.consultant_id
     where line.batch_id=p_batch
       and (not consultant.active or consultant.departed_at is not null)
  ) then
    raise exception 'departed consultant cannot enter an approved payout'
      using errcode='22023';
  end if;
  update public.consultant_payout_batches
     set status='approved',approved_by=auth.uid(),approved_at=now()
   where id=p_batch returning * into v_row;
  return to_jsonb(v_row);
end
$$;
revoke all on function public.approve_consultant_payout_batch_v78(uuid)
  from public,anon,authenticated;
grant execute on function public.approve_consultant_payout_batch_v78(uuid)
  to authenticated;

create or replace function public.record_consultant_payout_v78(
  p_line uuid,
  p_amount_cents integer,
  p_reference text,
  p_paid_at timestamptz
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_actor uuid:=auth.uid();
  v_line public.consultant_payout_lines%rowtype;
  v_batch public.consultant_payout_batches%rowtype;
  v_accrual public.consultant_commission_accruals%rowtype;
  v_consultant public.platform_consultants%rowtype;
  v_line_paid integer;
  v_accrual_paid integer;
  v_net integer;
  v_payment uuid;
begin
  if v_actor is null or not app.is_super_admin() then
    raise exception 'super-admin access is required' using errcode='42501';
  end if;
  if p_amount_cents<=0 or nullif(btrim(p_reference),'') is null
     or length(p_reference)>240 or p_paid_at is null
     or p_paid_at>now()+interval '5 minutes' then
    raise exception 'invalid payout evidence' using errcode='22023';
  end if;
  select * into strict v_line from public.consultant_payout_lines
   where id=p_line for update;
  select * into v_batch from public.consultant_payout_batches
   where id=v_line.batch_id and status in ('approved','processing') for update;
  if not found then raise exception 'approved payout batch was not found' using errcode='22023'; end if;
  select * into strict v_accrual from public.consultant_commission_accruals
   where id=v_line.accrual_id for update;
  select * into strict v_consultant from public.platform_consultants
   where id=v_line.consultant_id for update;
  if not v_consultant.active or v_consultant.departed_at is not null
     or p_paid_at<v_consultant.employment_started_on::timestamptz then
    return app.forfeit_consultant_core_v78(
      v_consultant.id,coalesce(v_consultant.departed_at,now()),
      'payout refused because consultant is inactive or departed',v_actor
    );
  end if;
  select coalesce(sum(amount_cents),0) into v_line_paid
    from public.consultant_payout_payments where line_id=p_line;
  select coalesce(sum(payment.amount_cents),0) into v_accrual_paid
    from public.consultant_payout_lines line
    join public.consultant_payout_payments payment on payment.line_id=line.id
   where line.accrual_id=v_accrual.id;
  select v_accrual.commission_cents+coalesce(sum(
    case when settlement_status='payable' then commission_adjustment_cents else 0 end
  ),0) into v_net
    from public.consultant_commission_adjustments
   where accrual_id=v_accrual.id;
  if p_amount_cents>v_line.amount_cents-v_line_paid
     or p_amount_cents>greatest(v_net-v_accrual_paid,0) then
    raise exception 'partial payout exceeds line or current net payable'
      using errcode='22023';
  end if;
  insert into public.consultant_payout_payments(
    line_id,amount_cents,payment_reference,paid_at,recorded_by
  ) values (
    p_line,p_amount_cents,btrim(p_reference),p_paid_at,v_actor
  ) returning id into v_payment;
  update public.consultant_payout_batches set status='processing'
   where id=v_batch.id and status='approved';
  if v_accrual_paid+p_amount_cents>=v_net then
    update public.consultant_commission_accruals
       set status='paid' where id=v_accrual.id and status='approved';
  end if;
  if not exists(
    select 1
      from public.consultant_payout_lines line
     where line.batch_id=v_batch.id
       and (
         select coalesce(sum(payment.amount_cents),0)
           from public.consultant_payout_payments payment
          where payment.line_id=line.id
       ) < line.amount_cents
  ) then
    update public.consultant_payout_batches
       set status='paid',paid_at=p_paid_at where id=v_batch.id;
  end if;
  return jsonb_build_object(
    'payment_id',v_payment,'line_id',p_line,'amount_cents',p_amount_cents,
    'reference',btrim(p_reference),'paid_at',p_paid_at
  );
end
$$;
revoke all on function public.record_consultant_payout_v78(
  uuid,integer,text,timestamptz
) from public,anon,authenticated;
grant execute on function public.record_consultant_payout_v78(
  uuid,integer,text,timestamptz
) to authenticated;

-- ---------------------------------------------------------------------------
-- 6. Finite SA reporting.
-- ---------------------------------------------------------------------------

create or replace function public.get_consultant_commission_policies_v78()
returns jsonb
language plpgsql
stable
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
begin
  if auth.uid() is null or not app.is_super_admin() then
    raise exception 'super-admin access is required' using errcode='42501';
  end if;
  return coalesce((
    select jsonb_agg(to_jsonb(policy) order by policy.tier,policy.version desc)
      from (
        select id,tier,version,effective_from,effective_to,first_year_bps,
               anniversary_bonus_bps,renewal_bps,basis_rule,
               setup_fee_included,reason,created_at
          from public.consultant_commission_policies
         order by tier,version desc limit 100
      ) policy
  ),'[]'::jsonb);
end
$$;
revoke all on function public.get_consultant_commission_policies_v78()
  from public,anon,authenticated;
grant execute on function public.get_consultant_commission_policies_v78()
  to authenticated;

create or replace function public.get_consultant_commission_dashboard_v78(
  p_consultant uuid default null,
  p_limit integer default 100
)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
begin
  if auth.uid() is null or not app.is_super_admin() then
    raise exception 'super-admin access is required' using errcode='42501';
  end if;
  if p_limit not between 1 and 250 then
    raise exception 'limit must be between 1 and 250' using errcode='22023';
  end if;
  return jsonb_build_object(
    'consultants',coalesce((
      select jsonb_agg(to_jsonb(rows) order by rows.display_name)
      from (
        select consultant.id consultant_id,consultant.display_name,
               consultant.tier,consultant.active,consultant.departed_at,
               coalesce(sum(accrual.commission_cents)
                 filter(
                   where accrual.status='accrued' and now()>=accrual.eligible_at
                 ),0) accrued_cents,
               coalesce(sum(accrual.commission_cents)
                 filter(
                   where accrual.status='accrued' and now()<accrual.eligible_at
                 ),0) pending_anniversary_cents,
               coalesce(sum(accrual.commission_cents)
                 filter(where accrual.status='approved'),0) approved_cents,
               coalesce(sum(accrual.commission_cents)
                 filter(where accrual.status='forfeited'),0) forfeited_cents,
               coalesce((
                 select sum(payment.amount_cents)
                   from public.consultant_payout_lines line
                   join public.consultant_payout_payments payment on payment.line_id=line.id
                  where line.consultant_id=consultant.id
               ),0) paid_cents,
               coalesce((
                 select sum(
                   eligible_accrual.commission_cents+coalesce((
                     select sum(adjustment.commission_adjustment_cents)
                       from public.consultant_commission_adjustments adjustment
                      where adjustment.accrual_id=eligible_accrual.id
                        and adjustment.settlement_status='payable'
                   ),0)
                 )
                   from public.consultant_commission_accruals eligible_accrual
                  where eligible_accrual.consultant_id=consultant.id
                    and eligible_accrual.status<>'forfeited'
                    and now()>=eligible_accrual.eligible_at
                    and (
                      eligible_accrual.commission_phase<>'anniversary_bonus'
                      or app.consultant_anniversary_qualified_v78(
                        eligible_accrual.business_id,eligible_accrual.eligible_at
                      )
                    )
               ),0)
               -coalesce((
                 select sum(payment.amount_cents)
                   from public.consultant_payout_lines line
                   join public.consultant_payout_payments payment on payment.line_id=line.id
                  where line.consultant_id=consultant.id
               ),0) payable_cents
          from public.platform_consultants consultant
          left join public.consultant_commission_accruals accrual
            on accrual.consultant_id=consultant.id
         where p_consultant is null or consultant.id=p_consultant
         group by consultant.id
         order by consultant.display_name limit p_limit
      ) rows
    ),'[]'::jsonb),
    'accruals',coalesce((
      select jsonb_agg(to_jsonb(rows) order by rows.invoice_paid_at desc)
      from (
        select accrual.id,accrual.consultant_id,accrual.business_id,
               accrual.provider_invoice_id,accrual.tier_snapshot,
               accrual.commission_phase,accrual.onboarding_started_at,
               accrual.invoice_paid_at,accrual.basis_cents,accrual.rate_bps,
               accrual.commission_cents,accrual.currency,accrual.status,
               accrual.approved_at,accrual.forfeited_at,accrual.forfeiture_reason,
               accrual.eligible_at,
               accrual.onboarding_started_at+interval '12 months'
                 renewal_rate_starts_at,
               (
                 accrual.status='accrued'
                 and consultant.active and consultant.departed_at is null
                 and now()>=accrual.eligible_at
                 and (
                   accrual.commission_phase<>'anniversary_bonus'
                   or app.consultant_anniversary_qualified_v78(
                     accrual.business_id,accrual.eligible_at
                   )
                 )
               ) approval_eligible,
               (
                 select tenant_subscription.status
                   from public.subscriptions tenant_subscription
                  where tenant_subscription.business_id=accrual.business_id
                  limit 1
               ) tenant_subscription_status,
               coalesce((
                 select sum(adjustment.commission_adjustment_cents)
                   from public.consultant_commission_adjustments adjustment
                  where adjustment.accrual_id=accrual.id
                    and adjustment.settlement_status='payable'
               ),0) adjustment_cents
          from public.consultant_commission_accruals accrual
          join public.platform_consultants consultant
            on consultant.id=accrual.consultant_id
         where p_consultant is null or accrual.consultant_id=p_consultant
         order by accrual.invoice_paid_at desc limit p_limit
      ) rows
    ),'[]'::jsonb),
    'payout_batches',coalesce((
      select jsonb_agg(to_jsonb(batch) order by batch.created_at desc)
      from (
        select id,currency,status,note,created_at,approved_at,paid_at,voided_at
          from public.consultant_payout_batches
         order by created_at desc limit 50
      ) batch
    ),'[]'::jsonb),
    'payout_lines',coalesce((
      select jsonb_agg(to_jsonb(line_rows) order by line_rows.created_at desc)
        from (
          select line.id line_id,line.batch_id,line.accrual_id,line.consultant_id,
                 consultant.display_name consultant_name,line.amount_cents,
                 paid.paid_amount_cents,
                 line.amount_cents-paid.paid_amount_cents remaining_cents,
                 batch.status batch_status,batch.currency,
                 accrual.status accrual_status,
                 (
                   batch.status in ('approved','processing')
                   and accrual.status in ('approved','paid')
                   and consultant.active and consultant.departed_at is null
                   and line.amount_cents-paid.paid_amount_cents>0
                 ) recordable,
                 line.created_at
            from public.consultant_payout_lines line
            join public.consultant_payout_batches batch on batch.id=line.batch_id
            join public.consultant_commission_accruals accrual
              on accrual.id=line.accrual_id
            join public.platform_consultants consultant
              on consultant.id=line.consultant_id
            cross join lateral (
              select coalesce(sum(payment.amount_cents),0)::integer
                       paid_amount_cents
                from public.consultant_payout_payments payment
               where payment.line_id=line.id
            ) paid
           where p_consultant is null or line.consultant_id=p_consultant
           order by line.created_at desc limit p_limit
        ) line_rows
    ),'[]'::jsonb)
  );
end
$$;
revoke all on function public.get_consultant_commission_dashboard_v78(
  uuid,integer
) from public,anon,authenticated;
grant execute on function public.get_consultant_commission_dashboard_v78(
  uuid,integer
) to authenticated;

comment on table public.consultant_commission_accruals is
  'Nestly platform consultant accrual snapshots from normalized SaaS invoice cash ex GST. This is not merchant staff commission.';
comment on function app.attribute_consultant_core_v78(
  uuid,uuid,uuid,timestamptz,text,uuid
) is 'Revoked internal attribution core for atomic v79 conversion after the prospect row is locked and converted.';

commit;
