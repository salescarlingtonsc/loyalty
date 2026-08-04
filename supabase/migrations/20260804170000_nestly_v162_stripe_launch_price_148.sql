-- V162: owner-confirmed launch price correction.
-- Monthly base is SGD 148/month; annual remains SGD 1,188/year.
-- Included capacity remains 1,000 customer profiles, with +1,000 capacity
-- priced at SGD 10/month or SGD 120/year.

do $v162_no_active_149_catalog$
begin
  if exists(
    select 1
      from public.billing_plan_catalog_v124
     where currency='SGD'
       and cadence='monthly'
       and active
       and effective_to is null
       and base_amount_cents=14900
  ) then
    raise exception 'retire the active SGD 149 monthly Stripe catalogue row before applying V162'
      using errcode='23514';
  end if;
end
$v162_no_active_149_catalog$;

alter table public.billing_plan_catalog_v124
  drop constraint if exists billing_plan_catalog_v124_cadence_pair;

alter table public.billing_plan_catalog_v124
  add constraint billing_plan_catalog_v124_cadence_pair check (
    (cadence = 'monthly' and cadence_months = 1
      and capacity_block_amount_cents = 1000
      and (
        base_amount_cents = 14800
        or (
          base_amount_cents = 14900
          and active = false
          and effective_to is not null
        )
      ))
    or
    (cadence = 'annual' and cadence_months = 12
      and base_amount_cents = 118800
      and capacity_block_amount_cents = 12000)
  );

create or replace function public.preview_billing_plan_catalog_v124(
  p_cadence text,
  p_provider_base_price_id text,
  p_provider_capacity_price_id text,
  p_tax_behavior text,
  p_effective_from timestamptz
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_actor uuid:=auth.uid();
  v_base integer;
  v_addon integer;
  v_hash text;
begin
  if v_actor is null or not app.is_super_admin() then
    raise exception 'super-admin access is required' using errcode='42501';
  end if;
  if p_cadence not in ('monthly','annual')
     or p_provider_base_price_id !~ '^price_[A-Za-z0-9_]+$'
     or p_provider_capacity_price_id !~ '^price_[A-Za-z0-9_]+$'
     or p_provider_base_price_id=p_provider_capacity_price_id
     or p_tax_behavior not in ('inclusive','exclusive','unspecified')
     or p_effective_from is null then
    raise exception 'invalid V124 Stripe price proposal' using errcode='22023';
  end if;
  v_base:=case p_cadence when 'monthly' then 14800 else 118800 end;
  v_addon:=case p_cadence when 'monthly' then 1000 else 12000 end;
  v_hash:=encode(extensions.digest(convert_to(
    'SGD'||E'\n'||p_cadence||E'\n'||p_provider_base_price_id||E'\n'
    ||p_provider_capacity_price_id||E'\n'||v_base::text||E'\n'||v_addon::text
    ||E'\n1000\n1000\n16800\n'||p_tax_behavior||E'\n'||p_effective_from::text,
    'utf8'),'sha256'),'hex');
  return jsonb_build_object(
    'currency','SGD','cadence',p_cadence,
    'base_amount_cents',v_base,'capacity_block_amount_cents',v_addon,
    'included_customer_capacity',1000,'capacity_block_size',1000,
    'compare_at_monthly_cents',16800,'tax_behavior',p_tax_behavior,
    'effective_from',p_effective_from,'confirmation_hash',v_hash
  );
end
$$;

revoke all on function public.preview_billing_plan_catalog_v124(
  text,text,text,text,timestamptz
) from public,anon,authenticated;
grant execute on function public.preview_billing_plan_catalog_v124(
  text,text,text,text,timestamptz
) to authenticated;

create or replace function public.confirm_billing_plan_catalog_v124(
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
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_actor uuid:=auth.uid();
  v_preview jsonb;
  v_row public.billing_plan_catalog_v124%rowtype;
begin
  if v_actor is null or not app.is_super_admin() then
    raise exception 'super-admin access is required' using errcode='42501';
  end if;
  if length(btrim(coalesce(p_reason,''))) < 8 then
    raise exception 'an audit reason is required' using errcode='22023';
  end if;
  v_preview:=public.preview_billing_plan_catalog_v124(
    p_cadence,p_provider_base_price_id,p_provider_capacity_price_id,
    p_tax_behavior,p_effective_from
  );
  if p_confirmation_hash is distinct from v_preview->>'confirmation_hash' then
    raise exception 'V124 Stripe price confirmation is stale' using errcode='22023';
  end if;
  update public.billing_plan_catalog_v124
     set active=false,effective_to=p_effective_from
   where currency='SGD' and cadence=p_cadence
     and active and effective_to is null;
  insert into public.billing_plan_catalog_v124(
    currency,cadence,cadence_months,provider_base_price_id,
    provider_capacity_price_id,base_amount_cents,
    included_customer_capacity,capacity_block_size,
    capacity_block_amount_cents,compare_at_monthly_cents,
    tax_behavior,effective_from,created_by
  ) values (
    'SGD',p_cadence,case p_cadence when 'monthly' then 1 else 12 end,
    p_provider_base_price_id,p_provider_capacity_price_id,
    case p_cadence when 'monthly' then 14800 else 118800 end,
    1000,1000,case p_cadence when 'monthly' then 1000 else 12000 end,
    16800,p_tax_behavior,p_effective_from,v_actor
  ) returning * into v_row;
  insert into public.audit_log(business_id,actor,action,entity,entity_id,detail)
  values (null,v_actor,'billing.v162_catalog_confirmed','billing_plan_catalog_v124',
    v_row.id,jsonb_build_object('reason',btrim(p_reason),'proposal',v_preview));
  return to_jsonb(v_row);
end
$$;

revoke all on function public.confirm_billing_plan_catalog_v124(
  text,text,text,text,timestamptz,text,text
) from public,anon,authenticated;
grant execute on function public.confirm_billing_plan_catalog_v124(
  text,text,text,text,timestamptz,text,text
) to authenticated;

-- The public Terms changed only to replace the launch monthly amount from
-- SGD 149 to SGD 148. Publish a new active Terms manifest version so new
-- self-service purchasers accept the exact current bytes while historical
-- acceptance rows remain untouched.
do $v162_terms_manifest$
begin
  if not exists(
    select 1 from app.customer_legal_documents
     where document_key='terms' and active
       and document_version='2026-08-03'
       and document_sha256='1c7437280e9ba8386b5ef3998a919fefcdeca8e06cc497b31621633ae23dab04'
  ) then
    raise exception 'current terms manifest does not match the reviewed V144 baseline'
      using errcode='23505';
  end if;

  update app.customer_legal_documents
     set document_version='2026-08-04',
         document_sha256='012e09a4a7b6df2a5acc9da3b6512c1cfeb42e903fd8306f6ff09866a9f1e4a5',
         published_at=timestamptz '2026-08-04 17:00:00+08:00',
         updated_at=timestamptz '2026-08-04 17:00:00+08:00'
   where document_key='terms' and active;
end
$v162_terms_manifest$;

alter table public.self_serve_business_onboarding_v130
  alter column legal_document_version set default '2026-08-04';

do $v162_start_function$
declare
  v_identity regprocedure:=to_regprocedure(
    'public.start_self_serve_business_v130(text,text,text,text,text,text,text,integer,boolean,uuid)'
  );
  v_definition text;
  v_updated text;
begin
  if v_identity is null then
    raise exception 'V130 self-service start function is unavailable' using errcode='0A000';
  end if;
  select pg_get_functiondef(v_identity) into v_definition;
  v_updated:=replace(v_definition,'2026-08-03','2026-08-04');
  if v_updated=v_definition then
    raise exception 'V130 legal version constant was not found' using errcode='23514';
  end if;
  execute v_updated;
end
$v162_start_function$;
