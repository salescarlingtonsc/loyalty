-- Nestly V125: operator no-GST billing boundary.
--
-- NESTLY TECHNOLOGIES PTE. LTD. is not GST-registered. This migration keeps
-- customer-capacity pricing fail-closed at zero tax without changing merchant
-- point-of-sale tax settings, which are a separate business-owned concern.

begin;

create table public.platform_billing_tax_policy_v125 (
  singleton boolean primary key default true check (singleton),
  operator_legal_name text not null
    default 'NESTLY TECHNOLOGIES PTE. LTD.'
    check (operator_legal_name = 'NESTLY TECHNOLOGIES PTE. LTD.'),
  operator_uen text not null default '202634502E'
    check (operator_uen = '202634502E'),
  gst_registered boolean not null default false,
  tax_collection_enabled boolean not null default false,
  provider_price_tax_behavior text not null default 'exclusive'
    check (provider_price_tax_behavior = 'exclusive'),
  effective_from timestamptz not null default '2026-08-01T00:00:00+08:00',
  reviewed_at timestamptz not null default now(),
  constraint platform_billing_tax_policy_v125_no_gst check (
    gst_registered = false
    and tax_collection_enabled = false
  )
);

alter table public.platform_billing_tax_policy_v125 enable row level security;
revoke all privileges on table public.platform_billing_tax_policy_v125
  from public,anon,authenticated;

insert into public.platform_billing_tax_policy_v125(singleton)
values(true)
on conflict(singleton) do update set
  gst_registered=false,
  tax_collection_enabled=false,
  provider_price_tax_behavior='exclusive',
  reviewed_at=now();

alter table public.billing_plan_catalog_v124
  alter column tax_behavior set default 'exclusive',
  add constraint billing_plan_catalog_v125_no_gst_tax_behavior
    check (tax_behavior = 'exclusive') not valid;
alter table public.billing_plan_catalog_v124
  validate constraint billing_plan_catalog_v125_no_gst_tax_behavior;

-- Abort rather than rewrite immutable provider evidence if any historical row
-- still carries tax. Operations must reconcile Stripe and the ledger before
-- this boundary can be installed. The retained assertion is also exercised by
-- rollback acceptance with a synthetic pre-upgrade row.
create or replace function app.assert_no_platform_billing_tax_v125()
returns void
language plpgsql
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
begin
  if exists(select 1 from public.subscriptions where coalesce(period_tax_cents,0)<>0)
     or exists(select 1 from public.billing_provider_invoices where tax_cents<>0)
     or exists(select 1 from public.billing_payment_attempts where tax_cents<>0)
     or exists(select 1 from public.billing_adjustments where tax_cents<>0) then
    raise exception 'V125 preflight failed: existing platform billing tax must be reconciled to zero'
      using errcode='23514';
  end if;
end
$$;
revoke all on function app.assert_no_platform_billing_tax_v125()
  from public,anon,authenticated;

select app.assert_no_platform_billing_tax_v125();

alter table public.subscriptions
  add constraint subscriptions_no_gst_v125_check
    check (coalesce(period_tax_cents,0)=0) not valid;
alter table public.subscriptions
  validate constraint subscriptions_no_gst_v125_check;
alter table public.billing_provider_invoices
  add constraint billing_provider_invoices_no_gst_v125_check
    check (tax_cents=0) not valid;
alter table public.billing_provider_invoices
  validate constraint billing_provider_invoices_no_gst_v125_check;
alter table public.billing_payment_attempts
  add constraint billing_payment_attempts_no_gst_v125_check
    check (tax_cents=0) not valid;
alter table public.billing_payment_attempts
  validate constraint billing_payment_attempts_no_gst_v125_check;
alter table public.billing_adjustments
  add constraint billing_adjustments_no_gst_v125_check
    check (tax_cents=0) not valid;
alter table public.billing_adjustments
  validate constraint billing_adjustments_no_gst_v125_check;

create or replace function app.enforce_subscription_no_gst_v125()
returns trigger
language plpgsql
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
begin
  if tg_table_name='subscriptions'
       and coalesce((to_jsonb(new)->>'period_tax_cents')::integer,0)<>0 then
      raise exception 'V125 GST not charged: subscription tax must be zero'
        using errcode='23514';
    elsif tg_table_name='billing_provider_invoices'
       and coalesce((to_jsonb(new)->>'tax_cents')::integer,0)<>0 then
      raise exception 'V125 GST not charged: invoice tax must be zero'
        using errcode='23514';
    elsif tg_table_name='billing_payment_attempts'
       and coalesce((to_jsonb(new)->>'tax_cents')::integer,0)<>0 then
      raise exception 'V125 GST not charged: payment-attempt tax must be zero'
        using errcode='23514';
    elsif tg_table_name='billing_adjustments'
       and coalesce((to_jsonb(new)->>'tax_cents')::integer,0)<>0 then
      raise exception 'V125 GST not charged: adjustment tax must be zero'
        using errcode='23514';
  end if;
  return new;
end
$$;
revoke all on function app.enforce_subscription_no_gst_v125()
  from public,anon,authenticated;

create trigger subscriptions_no_gst_v125
before insert or update of period_tax_cents
on public.subscriptions
for each row execute function app.enforce_subscription_no_gst_v125();

create trigger billing_provider_invoices_no_gst_v125
before insert or update of tax_cents
on public.billing_provider_invoices
for each row execute function app.enforce_subscription_no_gst_v125();

create trigger billing_payment_attempts_no_gst_v125
before insert or update of tax_cents
on public.billing_payment_attempts
for each row execute function app.enforce_subscription_no_gst_v125();

create trigger billing_adjustments_no_gst_v125
before insert or update of tax_cents
on public.billing_adjustments
for each row execute function app.enforce_subscription_no_gst_v125();

create or replace function public.preview_billing_plan_catalog_v125(
  p_cadence text,
  p_provider_base_price_id text,
  p_provider_capacity_price_id text,
  p_tax_behavior text,
  p_effective_from timestamptz
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
begin
  if p_tax_behavior is distinct from 'exclusive' then
    raise exception 'Nestly is not GST-registered; Stripe prices must use exclusive tax behavior'
      using errcode='22023';
  end if;
  return public.preview_billing_plan_catalog_v124(
    p_cadence,p_provider_base_price_id,p_provider_capacity_price_id,
    'exclusive',p_effective_from
  ) || jsonb_build_object(
    'gst_registered',false,
    'tax_collection_enabled',false,
    'tax_label','GST not charged',
    'tax_cents',0
  );
end
$$;
revoke all on function public.preview_billing_plan_catalog_v125(
  text,text,text,text,timestamptz
) from public,anon,authenticated;
grant execute on function public.preview_billing_plan_catalog_v125(
  text,text,text,text,timestamptz
) to authenticated;

create or replace function public.confirm_billing_plan_catalog_v125(
  p_cadence text,
  p_provider_base_price_id text,
  p_provider_capacity_price_id text,
  p_tax_behavior text,
  p_effective_from timestamptz,
  p_confirmation_hash text,
  p_reason text
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
begin
  if p_tax_behavior is distinct from 'exclusive' then
    raise exception 'Nestly is not GST-registered; Stripe prices must use exclusive tax behavior'
      using errcode='22023';
  end if;
  return public.confirm_billing_plan_catalog_v124(
    p_cadence,p_provider_base_price_id,p_provider_capacity_price_id,
    'exclusive',p_effective_from,p_confirmation_hash,p_reason
  ) || jsonb_build_object(
    'gst_registered',false,
    'tax_collection_enabled',false,
    'tax_label','GST not charged'
  );
end
$$;
revoke all on function public.confirm_billing_plan_catalog_v125(
  text,text,text,text,timestamptz,text,text
) from public,anon,authenticated;
grant execute on function public.confirm_billing_plan_catalog_v125(
  text,text,text,text,timestamptz,text,text
) to authenticated;

create or replace function public.get_billing_plan_catalog_v125()
returns jsonb
language plpgsql
stable
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
begin
  return public.get_billing_plan_catalog_v124();
end
$$;
revoke all on function public.get_billing_plan_catalog_v125()
  from public,anon,authenticated;
grant execute on function public.get_billing_plan_catalog_v125()
  to authenticated;

create or replace function app.assert_billing_json_no_gst_v125(p_payload jsonb)
returns void
language plpgsql
stable
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare v_row jsonb;
begin
  if coalesce((p_payload->>'period_tax_cents')::integer,0)<>0 then
    raise exception 'V125 GST not charged: subscription projection contains tax'
      using errcode='23514';
  end if;
  for v_row in select value from jsonb_array_elements(
    coalesce(p_payload->'invoices','[]'::jsonb)
  ) loop
    if coalesce((v_row->>'tax_cents')::integer,0)<>0 then
      raise exception 'V125 GST not charged: invoice projection contains tax'
        using errcode='23514';
    end if;
  end loop;
  for v_row in select value from jsonb_array_elements(
    coalesce(p_payload->'payment_attempts','[]'::jsonb)
  ) loop
    if coalesce((v_row->>'tax_cents')::integer,0)<>0 then
      raise exception 'V125 GST not charged: payment projection contains tax'
        using errcode='23514';
    end if;
  end loop;
  for v_row in select value from jsonb_array_elements(
    coalesce(p_payload->'adjustments','[]'::jsonb)
  ) loop
    if coalesce((v_row->>'tax_cents')::integer,0)<>0 then
      raise exception 'V125 GST not charged: adjustment projection contains tax'
        using errcode='23514';
    end if;
  end loop;
end
$$;
revoke all on function app.assert_billing_json_no_gst_v125(jsonb)
  from public,anon,authenticated;

create or replace function public.get_business_billing_v125(p_business uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare v_payload jsonb;
begin
  v_payload:=public.get_business_billing_v124(p_business);
  perform app.assert_billing_json_no_gst_v125(v_payload);
  return v_payload || jsonb_build_object(
    'tax_policy',jsonb_build_object(
      'gst_registered',false,
      'tax_collection_enabled',false,
      'provider_price_tax_behavior','exclusive',
      'label','GST not charged',
      'tax_cents',0
    ),
    'amount_due_cents',coalesce((v_payload->>'period_total_cents')::integer,0)
  );
end
$$;
revoke all on function public.get_business_billing_v125(uuid)
  from public,anon,authenticated;
grant execute on function public.get_business_billing_v125(uuid)
  to authenticated;

create or replace function public.platform_get_billing_v125(
  p_business uuid default null,p_limit integer default 100
)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare v_payload jsonb;v_row jsonb;
begin
  v_payload:=public.platform_get_billing_v89(p_business,p_limit);
  for v_row in select value from jsonb_array_elements(coalesce(v_payload,'[]'::jsonb))
  loop
    if coalesce((v_row->>'period_tax_cents')::integer,0)<>0 then
      raise exception 'V125 GST not charged: platform projection contains tax'
        using errcode='23514';
    end if;
  end loop;
  return v_payload;
end
$$;
revoke all on function public.platform_get_billing_v125(uuid,integer)
  from public,anon,authenticated;
grant execute on function public.platform_get_billing_v125(uuid,integer)
  to authenticated;

comment on table public.platform_billing_tax_policy_v125 is
  'V125 operator policy: GST not charged until separately verified registration and a reviewed replacement catalogue.';
comment on function public.get_business_billing_v125(uuid) is
  'Owner/super-admin billing projection that fails closed if any V124-capacity subscription amount contains GST.';

commit;
