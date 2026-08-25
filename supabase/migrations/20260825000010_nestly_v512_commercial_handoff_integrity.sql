-- NESTLY v512 - THE COMMERCIAL HANDOFF HOLDS ITS SHAPE
--
-- P3 of the Peekaa operating system, built on the already-applied v510/v511.
--
-- v510 made CLOSED_WON create an inactive, payment-ready workspace and bound
-- entitlement to independently verified backend payment evidence
-- (app.v510_verified_initial_payment).  What it did not do is hold the
-- COMMERCIAL side of that handoff still:
--
--   * an accepted commercial version carried no attribution, so nobody could
--     say afterwards which salesperson originated the lead and which one
--     closed it,
--   * a discount had nowhere to live at all, so a price concession was
--     invisible to the platform and impossible to gate,
--   * verified payment moved the merchant lifecycle but accrued nothing:
--     v78's accrual engine only fires from a Stripe invoice with a
--     consultant_commission_attributions row, so an assisted manual sale --
--     the pilot's normal shape -- earned a consultant exactly nothing and
--     left no record saying why.
--
-- Every invariant below is a trigger or a constraint on the table itself, not
-- a rule inside an RPC, because the writers are plural: v76's move_stage,
-- v317's restored copy of it and v510's platform_transition_lead_v510 all
-- insert commercial terms, and two independent projections (Stripe invoice
-- paid, manual payment verified) both mean "the money arrived".
--
-- NOT IN SCOPE (P6): reversal / clawback semantics when a paid invoice is
-- later refunded or charged back.  v78 already models that for its own
-- accruals; the v512 accrual is append-only and deliberately silent about it.
--
-- Nothing here weakens a v510 guard.  CLOSED_WON still cannot create
-- entitlement, and app.v510_guard_paid_handoff is untouched.

begin;

-- ---------------------------------------------------------------------------
-- 1. Discount shape and attribution on the accepted commercial version.
-- ---------------------------------------------------------------------------

-- One formula for "how big is this discount", used by the stored column that
-- readers see and by the acceptance trigger that gates on it.  A BEFORE
-- trigger cannot read a generated column (PostgreSQL computes those after
-- BEFORE triggers run), so without a shared function the threshold check and
-- the reported percentage would be two hand-copied expressions free to drift.
create or replace function app.v512_discount_pct(p_list integer,p_discount integer)
returns numeric language sql immutable
set search_path to 'pg_catalog','pg_temp' as $$
  select case
    when p_list is null or p_list<=0 then 0::numeric
    else round(coalesce(p_discount,0)::numeric*100/p_list::numeric,4)
  end
$$;
revoke all on function app.v512_discount_pct(integer,integer) from public,anon,authenticated;

alter table public.sme_commercial_terms
  add column if not exists list_value_cents integer,
  add column if not exists discount_cents integer not null default 0,
  add column if not exists discount_reason text,
  add column if not exists discount_approved_by uuid references auth.users(id) on delete restrict,
  add column if not exists discount_approved_at timestamptz,
  add column if not exists source_consultant_id uuid references public.platform_consultants(id) on delete restrict,
  add column if not exists closing_consultant_id uuid references public.platform_consultants(id) on delete restrict;

alter table public.sme_commercial_terms
  add column if not exists discount_pct numeric(7,4)
    generated always as (app.v512_discount_pct(list_value_cents,discount_cents)) stored;

-- A discount is only real if the list price it came off is recorded, and the
-- accepted value must be that list price less the concession.  Without this a
-- "discount" is a decorative number a maker-checker rule could never bind to.
alter table public.sme_commercial_terms
  drop constraint if exists sme_commercial_terms_v512_discount_shape;
alter table public.sme_commercial_terms
  add constraint sme_commercial_terms_v512_discount_shape check (
    discount_cents>=0
    and (discount_cents=0 or list_value_cents is not null)
    and (list_value_cents is null or list_value_cents>=0)
    and (list_value_cents is null or discount_cents<=list_value_cents)
    and (list_value_cents is null or list_value_cents=accepted_value_cents+discount_cents)
    and (discount_reason is null or length(btrim(discount_reason)) between 3 and 500)
    and (discount_cents>0 or discount_reason is null)
  );

alter table public.sme_commercial_terms
  drop constraint if exists sme_commercial_terms_v512_discount_approval_shape;
alter table public.sme_commercial_terms
  add constraint sme_commercial_terms_v512_discount_approval_shape check (
    (discount_approved_by is null and discount_approved_at is null)
    or (discount_approved_by is not null and discount_approved_at is not null and discount_cents>0)
  );

create index if not exists sme_commercial_terms_v512_closing_idx
  on public.sme_commercial_terms(closing_consultant_id,accepted_at desc)
  where closing_consultant_id is not null;

-- ---------------------------------------------------------------------------
-- 2. Discount maker-checker MECHANISM.  No policy is invented here.
-- ---------------------------------------------------------------------------
--
-- The platform ships with NO row in this table.  With no row, no acceptance is
-- ever gated -- exactly today's behaviour.  A row is a deliberate owner
-- decision: "a discount above this percentage needs a second signature".
-- Most specific wins: a row naming the plan beats the plan_code-null default.
--
-- Priced by the platform, never by a firm and never by the salesperson whose
-- discount it constrains: RLS on, no grants, no policies.  The only write path
-- is the super-admin RPC below, mirroring consultant_commission_policies (v78)
-- and subscriptions/super_admins (v14).
create table if not exists public.platform_discount_policies_v512 (
  id uuid primary key default gen_random_uuid(),
  plan_code text check (plan_code is null or length(btrim(plan_code)) between 1 and 80),
  threshold_pct numeric(7,4) not null check (threshold_pct>=0 and threshold_pct<=100),
  reason text not null check (length(btrim(reason)) between 3 and 1000),
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_by uuid references auth.users(id) on delete set null,
  updated_at timestamptz not null default now()
);
create unique index if not exists platform_discount_policies_v512_plan_uk
  on public.platform_discount_policies_v512(plan_code) where plan_code is not null;
create unique index if not exists platform_discount_policies_v512_default_uk
  on public.platform_discount_policies_v512((plan_code is null)) where plan_code is null;
alter table public.platform_discount_policies_v512 enable row level security;
revoke all privileges on table public.platform_discount_policies_v512 from public,anon,authenticated;

create or replace function app.v512_discount_threshold_pct(p_plan_code text)
returns numeric language sql stable security definer
set search_path to 'pg_catalog','public','app','pg_temp' as $$
  select policy.threshold_pct
    from public.platform_discount_policies_v512 policy
   where policy.plan_code is null
      or btrim(policy.plan_code)=btrim(coalesce(p_plan_code,''))
   order by (policy.plan_code is null)
   limit 1
$$;
revoke all on function app.v512_discount_threshold_pct(text) from public,anon,authenticated;

create or replace function public.platform_set_discount_policy_v512(
  p_plan_code text,p_threshold_pct numeric,p_reason text
) returns jsonb language plpgsql security definer
set search_path to 'pg_catalog','public','app','pg_temp' as $$
declare v_actor uuid:=auth.uid();v_row public.platform_discount_policies_v512%rowtype;v_plan text;
begin
  if v_actor is null or not app.is_super_admin() then
    raise exception 'super-admin access is required' using errcode='42501';end if;
  v_plan:=nullif(btrim(coalesce(p_plan_code,'')),'');
  if p_threshold_pct is null or p_threshold_pct<0 or p_threshold_pct>100
     or nullif(btrim(coalesce(p_reason,'')),'') is null or length(p_reason)>1000 then
    raise exception 'a discount threshold between 0 and 100 and a reason are required' using errcode='22023';end if;
  perform pg_advisory_xact_lock(hashtextextended('v512:discount-policy:'||coalesce(v_plan,'*'),0));
  select * into v_row from public.platform_discount_policies_v512
   where plan_code is not distinct from v_plan for update;
  if found then
    update public.platform_discount_policies_v512
       set threshold_pct=p_threshold_pct,reason=btrim(p_reason),
           updated_by=v_actor,updated_at=clock_timestamp()
     where id=v_row.id returning * into v_row;
  else
    insert into public.platform_discount_policies_v512(plan_code,threshold_pct,reason,created_by,updated_by)
    values(v_plan,p_threshold_pct,btrim(p_reason),v_actor,v_actor) returning * into v_row;
  end if;
  insert into public.audit_log(business_id,actor,action,entity,entity_id,detail)
  values(null,v_actor,'PLATFORM_DISCOUNT_POLICY_SET_V512','platform_discount_policies_v512',v_row.id,
    jsonb_build_object('plan_code',v_plan,'threshold_pct',p_threshold_pct,'reason',btrim(p_reason)));
  return to_jsonb(v_row);
end $$;
revoke all on function public.platform_set_discount_policy_v512(text,numeric,text) from public,anon,authenticated;
grant execute on function public.platform_set_discount_policy_v512(text,numeric,text) to authenticated;

create or replace function public.platform_clear_discount_policy_v512(p_plan_code text)
returns jsonb language plpgsql security definer
set search_path to 'pg_catalog','public','app','pg_temp' as $$
declare v_actor uuid:=auth.uid();v_row public.platform_discount_policies_v512%rowtype;v_plan text;
begin
  if v_actor is null or not app.is_super_admin() then
    raise exception 'super-admin access is required' using errcode='42501';end if;
  v_plan:=nullif(btrim(coalesce(p_plan_code,'')),'');
  perform pg_advisory_xact_lock(hashtextextended('v512:discount-policy:'||coalesce(v_plan,'*'),0));
  delete from public.platform_discount_policies_v512
   where plan_code is not distinct from v_plan returning * into v_row;
  if v_row.id is null then return jsonb_build_object('cleared',false,'plan_code',v_plan);end if;
  insert into public.audit_log(business_id,actor,action,entity,entity_id,detail)
  values(null,v_actor,'PLATFORM_DISCOUNT_POLICY_CLEARED_V512','platform_discount_policies_v512',v_row.id,
    jsonb_build_object('plan_code',v_plan,'threshold_pct',v_row.threshold_pct));
  return jsonb_build_object('cleared',true,'plan_code',v_plan,'threshold_pct',v_row.threshold_pct);
end $$;
revoke all on function public.platform_clear_discount_policy_v512(text) from public,anon,authenticated;
grant execute on function public.platform_clear_discount_policy_v512(text) to authenticated;

-- ---------------------------------------------------------------------------
-- 3. Acceptance captures attribution and honours the maker-checker rule.
-- ---------------------------------------------------------------------------
--
-- Acceptance IS the insert: a commercial version is written already accepted
-- or signed (v76 acceptance check, v510 CLOSED_WON evidence), and the row is
-- immutable afterwards.  So attribution is captured here, defaulted from the
-- lead's own ownership at that moment, and never asked for again.
create or replace function app.v512_capture_terms_attribution()
returns trigger language plpgsql security definer
set search_path to 'pg_catalog','public','app','pg_temp' as $$
declare
  v_threshold numeric;v_pct numeric;v_approver_is_closer boolean;
begin
  if new.contract_status not in ('accepted','signed') then return new;end if;

  if new.closing_consultant_id is null then
    select prospect.assigned_consultant_id into new.closing_consultant_id
      from public.sme_prospects prospect where prospect.id=new.prospect_id;
  end if;
  if new.source_consultant_id is null then
    select assignment.consultant_id into new.source_consultant_id
      from public.sme_prospect_assignments assignment
     where assignment.prospect_id=new.prospect_id and assignment.consultant_id is not null
     order by assignment.created_at,assignment.id
     limit 1;
  end if;
  -- A lead nobody was ever assigned to was originated by whoever closed it.
  if new.source_consultant_id is null then
    new.source_consultant_id:=new.closing_consultant_id;
  end if;

  v_pct:=app.v512_discount_pct(new.list_value_cents,new.discount_cents);
  v_threshold:=app.v512_discount_threshold_pct(new.plan_code);
  if v_threshold is not null and v_pct>v_threshold then
    if new.discount_approved_by is null then
      raise exception 'a % percent discount exceeds the configured % percent threshold and needs a second approver',
        v_pct,v_threshold using errcode='23514';
    end if;
    select consultant.user_id=new.discount_approved_by into v_approver_is_closer
      from public.platform_consultants consultant where consultant.id=new.closing_consultant_id;
    if coalesce(v_approver_is_closer,false) then
      raise exception 'a discount may not be approved by the salesperson closing the deal'
        using errcode='23514';
    end if;
  end if;
  return new;
end $$;
revoke all on function app.v512_capture_terms_attribution() from public,anon,authenticated;
drop trigger if exists aa_sme_commercial_terms_v512_acceptance on public.sme_commercial_terms;
create trigger aa_sme_commercial_terms_v512_acceptance
  before insert on public.sme_commercial_terms
  for each row execute function app.v512_capture_terms_attribution();

-- ---------------------------------------------------------------------------
-- 4. An accepted version is frozen.  Amendment is the next version row.
-- ---------------------------------------------------------------------------
--
-- v76 already refuses every UPDATE and DELETE on this table through
-- app.v75_immutable_guard, and that stays.  This guard is named to sort FIRST
-- so the reason a caller is refused is the specific one -- the economics of an
-- accepted agreement are frozen -- rather than the blanket table message, and
-- so the invariant survives any future relaxation of the blanket guard.
create or replace function app.v512_freeze_accepted_terms()
returns trigger language plpgsql
set search_path to 'pg_catalog','public','app','pg_temp' as $$
begin
  if old.contract_status not in ('accepted','signed') then
    return case when tg_op='DELETE' then old else new end;
  end if;
  if tg_op='DELETE' then
    raise exception 'an accepted commercial version is history and may not be deleted'
      using errcode='restrict_violation';
  end if;
  if (
    new.prospect_id,new.version,new.plan_code,new.product_code,new.billing_cycle,new.seats,
    new.currency,new.accepted_value_cents,new.list_value_cents,new.discount_cents,
    new.discount_reason,new.discount_approved_by,new.discount_approved_at,
    new.owner_email,new.onboarding_owner_consultant_id,new.target_go_live,new.accepted_at,
    new.source_consultant_id,new.closing_consultant_id
  ) is distinct from (
    old.prospect_id,old.version,old.plan_code,old.product_code,old.billing_cycle,old.seats,
    old.currency,old.accepted_value_cents,old.list_value_cents,old.discount_cents,
    old.discount_reason,old.discount_approved_by,old.discount_approved_at,
    old.owner_email,old.onboarding_owner_consultant_id,old.target_go_live,old.accepted_at,
    old.source_consultant_id,old.closing_consultant_id
  ) then
    raise exception 'accepted commercial terms are frozen; amend by accepting the next version'
      using errcode='restrict_violation';
  end if;
  return new;
end $$;
revoke all on function app.v512_freeze_accepted_terms() from public,anon,authenticated;
drop trigger if exists aa_sme_commercial_terms_v512_frozen on public.sme_commercial_terms;
create trigger aa_sme_commercial_terms_v512_frozen
  before update or delete on public.sme_commercial_terms
  for each row execute function app.v512_freeze_accepted_terms();

-- ---------------------------------------------------------------------------
-- 5. Verified initial payment accrues commission exactly once.
-- ---------------------------------------------------------------------------
--
-- Keyed on (commercial_terms_id, obligation period) -- the obligation the
-- money settled -- not on the evidence row, because the same obligation can be
-- projected from either rail and each projection can replay.
create table if not exists public.sme_commission_accruals_v512 (
  id uuid primary key default gen_random_uuid(),
  commercial_terms_id uuid not null references public.sme_commercial_terms(id) on delete restrict,
  terms_version integer not null check (terms_version>0),
  prospect_id uuid not null references public.sme_prospects(id) on delete restrict,
  business_id uuid not null references public.businesses(id) on delete restrict,
  obligation_period_start date not null,
  obligation_period_end date not null,
  source_consultant_id uuid references public.platform_consultants(id) on delete restrict,
  closing_consultant_id uuid references public.platform_consultants(id) on delete restrict,
  policy_id uuid references public.consultant_commission_policies(id) on delete restrict,
  tier_snapshot text check (tier_snapshot is null or tier_snapshot in ('senior','junior')),
  rate_bps integer not null check (rate_bps between 0 and 10000),
  rate_source text not null check (rate_source in ('consultant_commission_policy_v78','unresolved')),
  zero_rate_reason text,
  basis_cents bigint not null check (basis_cents>=0),
  basis_source text not null check (basis_source in
    ('stripe_invoice_net_cash_ex_tax','manual_invoice_total_ex_tax')),
  commission_cents bigint not null check (commission_cents>=0),
  currency text not null check (currency ~ '^[A-Z]{3}$'),
  payment_source text not null check (payment_source in ('stripe_invoice','manual_payment')),
  payment_evidence_id uuid not null,
  payment_verified_at timestamptz not null,
  created_at timestamptz not null default clock_timestamp(),
  constraint sme_commission_accruals_v512_period_check check (obligation_period_end>=obligation_period_start),
  constraint sme_commission_accruals_v512_rate_shape check (
    (rate_bps>0 and zero_rate_reason is null and rate_source='consultant_commission_policy_v78'
      and policy_id is not null and tier_snapshot is not null)
    or (rate_bps=0 and length(btrim(coalesce(zero_rate_reason,'')))>=3)
  ),
  constraint sme_commission_accruals_v512_unresolved_shape check (
    rate_source='consultant_commission_policy_v78'
    or (rate_source='unresolved' and policy_id is null and rate_bps=0)
  ),
  -- The arithmetic is the invariant, not a comment about the invariant.
  constraint sme_commission_accruals_v512_amount_check check (
    commission_cents=floor(basis_cents::numeric*rate_bps::numeric/10000)::bigint
  ),
  constraint sme_commission_accruals_v512_obligation_uk
    unique(commercial_terms_id,obligation_period_start,obligation_period_end)
);
create index if not exists sme_commission_accruals_v512_consultant_idx
  on public.sme_commission_accruals_v512(closing_consultant_id,payment_verified_at desc);
create index if not exists sme_commission_accruals_v512_business_idx
  on public.sme_commission_accruals_v512(business_id);
alter table public.sme_commission_accruals_v512 enable row level security;
revoke all privileges on table public.sme_commission_accruals_v512 from public,anon,authenticated;

-- Append-only.  Reversal semantics are P6; until then an accrual that turned
-- out to be wrong is a fact about what the platform believed, not a draft.
create or replace function app.v512_accrual_append_only_guard()
returns trigger language plpgsql
set search_path to 'pg_catalog','public','app','pg_temp' as $$
begin
  raise exception 'commission accruals are append-only; reversal is not modelled yet'
    using errcode='restrict_violation';
end $$;
revoke all on function app.v512_accrual_append_only_guard() from public,anon,authenticated;
drop trigger if exists sme_commission_accruals_v512_append_only on public.sme_commission_accruals_v512;
create trigger sme_commission_accruals_v512_append_only
  before update or delete on public.sme_commission_accruals_v512
  for each row execute function app.v512_accrual_append_only_guard();

create or replace function app.v512_accrue_initial_commission(p_business uuid)
returns uuid language plpgsql security definer
set search_path to 'pg_catalog','public','app','pg_temp' as $$
declare
  v_evidence jsonb;v_source text;v_evidence_id uuid;v_verified timestamptz;
  v_sub public.subscriptions%rowtype;v_terms public.sme_commercial_terms%rowtype;
  v_consultant public.platform_consultants%rowtype;v_policy public.consultant_commission_policies%rowtype;
  v_basis bigint;v_basis_source text;v_rate integer:=0;v_rate_source text:='unresolved';
  v_reason text;v_policy_id uuid;v_tier text;v_id uuid;
begin
  if p_business is null then return null;end if;
  v_evidence:=app.v510_verified_initial_payment(p_business);
  if v_evidence is null then return null;end if;
  v_source:=v_evidence->>'source';
  v_evidence_id:=(v_evidence->>'evidence_id')::uuid;
  v_verified:=(v_evidence->>'verified_at')::timestamptz;

  -- Serialize the two projections against each other.  The unique constraint
  -- is the real defence; the lock stops two concurrent verifications from
  -- racing into the same insert and turning a duplicate into a caller error.
  perform pg_advisory_xact_lock(hashtextextended('v512:commission:'||p_business,0));

  select subscription.* into v_sub
    from public.subscriptions subscription
    join public.sme_commercial_terms terms on terms.id=subscription.commercial_terms_id
   where subscription.business_id=p_business
     and terms.contract_status in ('accepted','signed')
     and terms.accepted_value_cents>0;
  if not found or v_sub.obligation_period_start is null or v_sub.obligation_period_end is null then
    return null;end if;
  select * into v_terms from public.sme_commercial_terms where id=v_sub.commercial_terms_id;

  if exists(select 1 from public.sme_commission_accruals_v512
    where commercial_terms_id=v_terms.id
      and obligation_period_start=v_sub.obligation_period_start
      and obligation_period_end=v_sub.obligation_period_end) then
    return null;end if;

  if v_source='stripe_invoice' then
    select invoice.net_cash_ex_tax_cents into v_basis
      from public.billing_provider_invoices invoice where invoice.id=v_evidence_id;
    v_basis_source:='stripe_invoice_net_cash_ex_tax';
  else
    select greatest(document.total_cents-document.tax_cents,0) into v_basis
      from public.platform_manual_payments_v156 payment
      join public.platform_subscription_documents_v156 document
        on document.id=payment.invoice_document_id
     where payment.id=v_evidence_id;
    v_basis_source:='manual_invoice_total_ex_tax';
  end if;
  if v_basis is null then return null;end if;

  -- The rate is v78's, read as of the moment the money was verified.  Where
  -- v78 has nothing to say, the accrual still exists and says so: a silent
  -- skip would be indistinguishable from "this sale earned nothing", and an
  -- invented rate would be worse.
  if v_terms.closing_consultant_id is null then
    v_reason:='the accepted commercial terms carry no closing consultant to pay';
  else
    select * into v_consultant from public.platform_consultants
     where id=v_terms.closing_consultant_id;
    if not found then
      v_reason:='the closing consultant on the commercial terms no longer exists';
    else
      select * into v_policy from public.consultant_commission_policies
       where tier=v_consultant.tier
         and effective_from<=v_verified
         and (effective_to is null or v_verified<effective_to)
       order by version desc limit 1;
      if not found then
        v_reason:='no v78 consultant commission policy is effective for tier '
          ||v_consultant.tier||' at the verified payment time';
      else
        v_rate:=v_policy.first_year_bps;
        v_rate_source:='consultant_commission_policy_v78';
        v_policy_id:=v_policy.id;
        v_tier:=v_consultant.tier;
        if v_rate=0 then
          v_reason:='v78 policy '||v_policy.tier||' v'||v_policy.version
            ||' sets a zero first-year rate';
        end if;
      end if;
    end if;
  end if;

  insert into public.sme_commission_accruals_v512(
    commercial_terms_id,terms_version,prospect_id,business_id,
    obligation_period_start,obligation_period_end,source_consultant_id,closing_consultant_id,
    policy_id,tier_snapshot,rate_bps,rate_source,zero_rate_reason,basis_cents,basis_source,
    commission_cents,currency,payment_source,payment_evidence_id,payment_verified_at
  ) values(
    v_terms.id,v_terms.version,v_terms.prospect_id,p_business,
    v_sub.obligation_period_start,v_sub.obligation_period_end,
    v_terms.source_consultant_id,v_terms.closing_consultant_id,
    v_policy_id,v_tier,v_rate,v_rate_source,v_reason,v_basis,v_basis_source,
    floor(v_basis::numeric*v_rate::numeric/10000)::bigint,
    v_sub.currency,v_source,v_evidence_id,v_verified
  )
  on conflict on constraint sme_commission_accruals_v512_obligation_uk do nothing
  returning id into v_id;
  if v_id is null then return null;end if;

  insert into public.audit_log(business_id,actor,action,entity,entity_id,detail)
  values(p_business,auth.uid(),'SME_COMMISSION_ACCRUED_V512','sme_commission_accruals_v512',v_id,
    jsonb_build_object('commercial_terms_id',v_terms.id,'terms_version',v_terms.version,
      'obligation_period_start',v_sub.obligation_period_start,
      'obligation_period_end',v_sub.obligation_period_end,
      'closing_consultant_id',v_terms.closing_consultant_id,
      'source_consultant_id',v_terms.source_consultant_id,
      'rate_bps',v_rate,'rate_source',v_rate_source,'zero_rate_reason',v_reason,
      'basis_cents',v_basis,'payment_source',v_source));
  return v_id;
end $$;
revoke all on function app.v512_accrue_initial_commission(uuid) from public,anon,authenticated;

create or replace function app.v512_project_invoice_commission()
returns trigger language plpgsql security definer
set search_path to 'pg_catalog','public','app','pg_temp' as $$
begin
  perform app.v512_accrue_initial_commission(new.business_id);
  return null;
end $$;
revoke all on function app.v512_project_invoice_commission() from public,anon,authenticated;
drop trigger if exists zz_billing_provider_invoices_v512_commission on public.billing_provider_invoices;
create trigger zz_billing_provider_invoices_v512_commission
  after insert or update of paid_normalized,status,amount_paid_cents,amount_remaining_cents
  on public.billing_provider_invoices
  for each row execute function app.v512_project_invoice_commission();

create or replace function app.v512_project_manual_payment_commission()
returns trigger language plpgsql security definer
set search_path to 'pg_catalog','public','app','pg_temp' as $$
declare v_business uuid;
begin
  if new.status<>'verified' then return null;end if;
  select document.business_id into v_business
    from public.platform_subscription_documents_v156 document
   where document.id=new.invoice_document_id;
  perform app.v512_accrue_initial_commission(v_business);
  return null;
end $$;
revoke all on function app.v512_project_manual_payment_commission() from public,anon,authenticated;
drop trigger if exists zz_platform_manual_payments_v512_commission on public.platform_manual_payments_v156;
create trigger zz_platform_manual_payments_v512_commission
  after update of status on public.platform_manual_payments_v156
  for each row execute function app.v512_project_manual_payment_commission();

-- ---------------------------------------------------------------------------
-- 6. Wire the discount fields through the canonical CLOSED_WON writer.
-- ---------------------------------------------------------------------------
--
-- Patch only the commercial-terms INSERT inside v510's transition RPC, and
-- fail the migration if its source has drifted, rather than re-declaring two
-- hundred lines of stage machinery this change has no opinion about.  Same
-- technique v510 used on v156's evidence-path validator.
do $$
declare
  v_definition text;v_columns_old text;v_columns_new text;v_values_old text;v_values_new text;
begin
  select pg_get_functiondef(
    'public.platform_transition_lead_v510(uuid,text,bigint,text,timestamptz,text,text,jsonb,jsonb,uuid)'::regprocedure
  ) into v_definition;

  v_columns_old:=E'      contract_status,accepted_at,notes,created_by\n    ) values(';
  v_columns_new:=E'      contract_status,accepted_at,notes,created_by,\n'
    ||E'      list_value_cents,discount_cents,discount_reason,discount_approved_by,discount_approved_at\n'
    ||E'    ) values(';
  v_values_old:=E'      p_commercial_terms->>''contract_status'',clock_timestamp(),p_commercial_terms->>''notes'',v_actor);';
  v_values_new:=E'      p_commercial_terms->>''contract_status'',clock_timestamp(),p_commercial_terms->>''notes'',v_actor,\n'
    ||E'      nullif(p_commercial_terms->>''list_value_cents'','''')::integer,\n'
    ||E'      greatest(coalesce((p_commercial_terms->>''discount_cents'')::integer,0),0),\n'
    ||E'      nullif(btrim(coalesce(p_commercial_terms->>''discount_reason'','''')),''''),\n'
    ||E'      nullif(p_commercial_terms->>''discount_approved_by'','''')::uuid,\n'
    ||E'      case when nullif(p_commercial_terms->>''discount_approved_by'','''') is not null\n'
    ||E'        then clock_timestamp() end);';

  if strpos(v_definition,v_columns_new)>0 and strpos(v_definition,v_values_new)>0 then
    return;
  end if;
  if length(v_definition)-length(replace(v_definition,v_columns_old,''))<>length(v_columns_old)
     or length(v_definition)-length(replace(v_definition,v_values_old,''))<>length(v_values_old) then
    raise exception 'v510 commercial-terms writer has an unexpected shape; refusing to patch it blind';
  end if;
  v_definition:=replace(v_definition,v_columns_old,v_columns_new);
  v_definition:=replace(v_definition,v_values_old,v_values_new);
  execute v_definition;
end $$;

comment on table public.sme_commission_accruals_v512 is
  'One immutable accrual per accepted commercial obligation, written when initial payment is first verified by either rail. Rate is v78''s, read at that moment; rate 0 always names its reason. Reversal is P6.';
comment on table public.platform_discount_policies_v512 is
  'Optional discount maker-checker thresholds. No row means nothing is gated. Platform-priced: RLS on, no grants, no policies, super-admin RPC only.';

commit;
