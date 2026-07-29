-- NESTLY v100 - PRIVACY-SAFE PRODUCT ADOPTION EVENT CONTRACT
--
-- Created with `supabase migration new nestly_v100_product_adoption_events`
-- and renamed so this forward-only migration sorts after v97 and v99.
--
-- Client code may record only the small, explicit interaction allowlist below.
-- Economic and completed-outcome events are database-authored from canonical
-- source rows. Event context excludes contact details, free text, raw routes,
-- tokens and search terms. No analytics provider or connector is introduced.

begin;

create table public.product_adoption_event_taxonomy_v100 (
  event_name text primary key
    check (event_name ~ '^[a-z][a-z0-9_]*\.[a-z][a-z0-9_]*$'),
  source_authority text not null
    check (source_authority in ('client','server')),
  actor_scope text not null
    check (actor_scope in ('customer','merchant','system')),
  required_module text,
  required_mode text check (required_mode is null or required_mode in ('r','rw')),
  business_scope_required boolean not null,
  economic_event boolean not null,
  description text not null check (char_length(description) between 1 and 240),
  created_at timestamptz not null default now(),
  constraint product_adoption_event_taxonomy_v100_module_check check (
    (required_module is null and required_mode is null)
    or (required_module is not null and required_mode is not null)
  )
);

insert into public.product_adoption_event_taxonomy_v100(
  event_name,source_authority,actor_scope,required_module,required_mode,
  business_scope_required,economic_event,description
) values
  ('merchant.workspace_viewed','client','merchant','dashboard','r',true,false,
    'Authenticated merchant opened the workspace home.'),
  ('merchant.grow_opened','client','merchant',null,null,true,false,
    'Authenticated merchant opened the unified Grow workspace.'),
  ('merchant.grow_draft_started','client','merchant','retention','rw',true,false,
    'Authorized merchant began a Grow configuration draft.'),
  ('merchant.counter_action_opened','client','merchant','till','r',true,false,
    'Authorized merchant opened a counter action.'),
  ('merchant.counter_action_started','client','merchant','till','rw',true,false,
    'Authorized merchant began a counter action without asserting completion.'),
  ('merchant.redemption_scan_started','client','merchant','loyalty','rw',true,false,
    'Authorized merchant opened the customer redemption scanner.'),
  ('customer.programme_viewed','client','customer',null,null,true,false,
    'Verified customer opened a linked business programme.'),
  ('customer.qr_join_completed','server','customer',null,null,true,false,
    'Canonical QR join audit evidence recorded a completed relationship.'),
  ('customer.booking_submitted','server','system',null,null,true,false,
    'Canonical booking request was inserted.'),
  ('sale.recorded','server','system',null,null,true,true,
    'Canonical non-reversal sale was inserted.'),
  ('sale.reversed','server','system',null,null,true,true,
    'Canonical reversal sale was inserted.'),
  ('loyalty.redemption_completed','server','system',null,null,true,true,
    'Canonical loyalty redemption was inserted.'),
  ('billing.invoice_paid','server','system',null,null,true,true,
    'Canonical billing invoice first became normalized paid truth.'),
  ('campaign.exposure_verified','server','merchant',null,null,true,false,
    'Immutable v99 campaign exposure evidence was recorded.'),
  ('campaign.return_attributed','server','merchant',null,null,true,true,
    'Immutable post-exposure campaign return evidence was recorded.');

create table public.product_adoption_events_v100 (
  id uuid primary key default gen_random_uuid(),
  event_name text not null
    references public.product_adoption_event_taxonomy_v100(event_name)
    on delete restrict,
  source_authority text not null
    check (source_authority in ('client','server')),
  actor_scope text not null
    check (actor_scope in ('customer','merchant','system')),
  actor_user_id uuid,
  business_id uuid references public.businesses(id) on delete restrict,
  branch_id uuid,
  session_id uuid,
  source_table text,
  source_id uuid,
  source_operation text
    check (
      source_operation is null
      or source_operation in ('INSERT','UPDATE')
    ),
  event_context jsonb not null default '{}'::jsonb
    check (jsonb_typeof(event_context)='object'),
  idempotency_key text
    check (
      idempotency_key is null
      or char_length(btrim(idempotency_key)) between 8 and 200
    ),
  request_hash text
    check (request_hash is null or request_hash ~ '^[0-9a-f]{64}$'),
  occurred_at timestamptz not null,
  received_at timestamptz not null default now(),
  retention_until timestamptz not null default (now()+interval '400 days'),
  constraint product_adoption_events_v100_branch_fk
    foreign key (branch_id,business_id)
    references public.branches(id,business_id) on delete restrict,
  constraint product_adoption_events_v100_scope_check check (
    branch_id is null or business_id is not null
  ),
  constraint product_adoption_events_v100_authority_shape_check check (
    (
      source_authority='client'
      and actor_user_id is not null
      and source_table is null
      and source_id is null
      and source_operation is null
      and idempotency_key is not null
      and request_hash is not null
    )
    or (
      source_authority='server'
      and source_table is not null
      and source_id is not null
      and source_operation is not null
      and idempotency_key is null
      and request_hash is null
    )
  ),
  constraint product_adoption_events_v100_retention_check check (
    retention_until>=received_at+interval '399 days'
    and retention_until<=received_at+interval '401 days'
  ),
  constraint product_adoption_events_v100_server_source_uk
    unique (source_table,source_id,event_name)
);
create unique index product_adoption_events_v100_client_idempotency_uk
  on public.product_adoption_events_v100(actor_user_id,idempotency_key)
  where source_authority='client';
create index product_adoption_events_v100_business_time_idx
  on public.product_adoption_events_v100(
    business_id,occurred_at,event_name
  ) where business_id is not null;
create index product_adoption_events_v100_retention_idx
  on public.product_adoption_events_v100(retention_until);

alter table public.product_adoption_event_taxonomy_v100
  enable row level security;
alter table public.product_adoption_events_v100
  enable row level security;
revoke all privileges on table public.product_adoption_event_taxonomy_v100
  from public,anon,authenticated,service_role;
revoke all privileges on table public.product_adoption_events_v100
  from public,anon,authenticated,service_role;

create or replace function app.v100_adoption_immutable_guard()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public, app, pg_temp
as $$
begin
  if tg_table_name='product_adoption_events_v100'
     and tg_op='DELETE'
     and coalesce(
       pg_catalog.current_setting('app.v100_retention_purge',true),''
     )='on'
     and old.retention_until<clock_timestamp() then
    return old;
  end if;
  raise exception 'v100 adoption contracts and events are append-only'
    using errcode='restrict_violation';
end
$$;
revoke all privileges on function app.v100_adoption_immutable_guard()
  from public,anon,authenticated,service_role;
create trigger product_adoption_event_taxonomy_v100_immutable
  before update or delete on public.product_adoption_event_taxonomy_v100
  for each row execute function app.v100_adoption_immutable_guard();
create trigger product_adoption_events_v100_immutable
  before update or delete on public.product_adoption_events_v100
  for each row execute function app.v100_adoption_immutable_guard();

create or replace function app.append_server_adoption_event_v100(
  p_event_name text,
  p_business uuid,
  p_branch uuid,
  p_actor_user uuid,
  p_source_table text,
  p_source_id uuid,
  p_source_operation text,
  p_occurred_at timestamptz
)
returns uuid
language plpgsql
security definer
set search_path = pg_catalog, public, app, pg_temp
as $$
declare
  v_taxonomy public.product_adoption_event_taxonomy_v100%rowtype;
  v_id uuid:=gen_random_uuid();
begin
  select taxonomy.* into v_taxonomy
  from public.product_adoption_event_taxonomy_v100 taxonomy
  where taxonomy.event_name=p_event_name
    and taxonomy.source_authority='server';
  if not found then
    raise exception 'event is not server-authoritative: %',p_event_name
      using errcode='22023';
  end if;
  if p_source_table is null
     or p_source_id is null
     or p_source_operation not in ('INSERT','UPDATE')
     or p_occurred_at is null then
    raise exception 'complete canonical source evidence is required'
      using errcode='22023';
  end if;
  if v_taxonomy.business_scope_required and p_business is null then
    raise exception 'business-scoped event is missing its tenant'
      using errcode='22023';
  end if;
  insert into public.product_adoption_events_v100(
    id,event_name,source_authority,actor_scope,actor_user_id,
    business_id,branch_id,source_table,source_id,source_operation,
    event_context,occurred_at
  ) values(
    v_id,p_event_name,'server',v_taxonomy.actor_scope,p_actor_user,
    p_business,p_branch,p_source_table,p_source_id,p_source_operation,
    '{}'::jsonb,p_occurred_at
  )
  on conflict (source_table,source_id,event_name) do nothing
  returning id into v_id;
  if v_id is null then
    select event_row.id into v_id
    from public.product_adoption_events_v100 event_row
    where event_row.source_table=p_source_table
      and event_row.source_id=p_source_id
      and event_row.event_name=p_event_name;
  end if;
  return v_id;
end
$$;
revoke all privileges on function app.append_server_adoption_event_v100(
  text,uuid,uuid,uuid,text,uuid,text,timestamptz
) from public,anon,authenticated,service_role;

create or replace function public.record_product_interaction_v100(
  p_event_name text,
  p_business uuid,
  p_branch uuid,
  p_session_id uuid,
  p_idempotency_key text,
  p_occurred_at timestamptz default now(),
  p_context jsonb default '{}'::jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public, app, pg_temp
as $$
declare
  v_actor uuid:=auth.uid();
  v_taxonomy public.product_adoption_event_taxonomy_v100%rowtype;
  v_context jsonb:=coalesce(p_context,'{}'::jsonb);
  v_key text:=btrim(coalesce(p_idempotency_key,''));
  v_hash text;
  v_existing public.product_adoption_events_v100%rowtype;
  v_id uuid:=gen_random_uuid();
begin
  if v_actor is null then
    raise exception 'authenticated interaction session is required'
      using errcode='28000';
  end if;
  select taxonomy.* into v_taxonomy
  from public.product_adoption_event_taxonomy_v100 taxonomy
  where taxonomy.event_name=p_event_name
    and taxonomy.source_authority='client';
  if not found then
    raise exception 'event is not in the client interaction allowlist'
      using errcode='22023';
  end if;
  if char_length(v_key) not between 8 and 200 then
    raise exception 'idempotency key must contain 8..200 characters'
      using errcode='22023';
  end if;
  if p_occurred_at is null
     or p_occurred_at<clock_timestamp()-interval '24 hours'
     or p_occurred_at>clock_timestamp()+interval '5 minutes' then
    raise exception 'interaction time is outside the accepted window'
      using errcode='22023';
  end if;
  if v_taxonomy.business_scope_required and p_business is null then
    raise exception 'interaction requires a business scope'
      using errcode='22023';
  end if;
  if jsonb_typeof(v_context)<>'object'
     or octet_length(v_context::text)>2048
     or exists(
       select 1
       from pg_catalog.jsonb_object_keys(v_context) as context_key(key)
       where context_key.key not in (
         'action_key','entry_point','locale','device_class','install_mode',
         'surface_version','outcome'
       )
     )
     or exists(
       select 1
       from pg_catalog.jsonb_each(v_context) as context_item(key,value)
       where pg_catalog.jsonb_typeof(context_item.value)
               not in ('string','number','boolean','null')
          or (
            pg_catalog.jsonb_typeof(context_item.value)='string'
            and char_length(context_item.value#>>'{}')>80
          )
     ) then
    raise exception
      'context may contain only short privacy-safe allowlisted dimensions'
      using errcode='22023';
  end if;

  if v_taxonomy.actor_scope='customer' then
    if not exists(
      select 1
      from public.customer_links customer_link
      where customer_link.business_id=p_business
        and customer_link.auth_user_id=v_actor
        and customer_link.state='verified'
    ) then
      raise exception 'verified customer relationship is required'
        using errcode='42501';
    end if;
    if p_branch is not null and not exists(
      select 1
      from public.branches branch
      where branch.id=p_branch and branch.business_id=p_business
    ) then
      raise exception 'branch does not belong to this business'
        using errcode='42501';
    end if;
  elsif v_taxonomy.actor_scope='merchant' then
    if not app.is_salon_member(p_business) then
      raise exception 'active merchant membership is required'
        using errcode='42501';
    end if;
    if v_taxonomy.required_module is not null
       and (
         (
           v_taxonomy.required_mode='r'
           and not app.can_module_read(
             p_business,v_taxonomy.required_module
           )
         )
         or (
           v_taxonomy.required_mode='rw'
           and not app.can_module_write(
             p_business,v_taxonomy.required_module
           )
         )
       ) then
      raise exception 'module access does not permit this interaction'
        using errcode='42501';
    end if;
    if p_branch is not null
       and not app.can_see_branch(p_business,p_branch) then
      raise exception 'branch is outside the merchant scope'
        using errcode='42501';
    end if;
  else
    raise exception 'unsupported client actor scope' using errcode='22023';
  end if;

  v_hash:=pg_catalog.encode(
    extensions.digest(
      pg_catalog.convert_to(
        pg_catalog.concat_ws(
          '|','v100.client-interaction',p_event_name,
          coalesce(p_business::text,''),coalesce(p_branch::text,''),
          coalesce(p_session_id::text,''),p_occurred_at::text,v_context::text
        ),
        'UTF8'
      ),
      'sha256'
    ),
    'hex'
  );
  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(
      'v100:interaction:'||v_actor::text||':'||v_key,0
    )
  );
  select event_row.* into v_existing
  from public.product_adoption_events_v100 event_row
  where event_row.actor_user_id=v_actor
    and event_row.idempotency_key=v_key;
  if found then
    if v_existing.request_hash<>v_hash then
      raise exception 'idempotency key conflicts with another interaction'
        using errcode='23505';
    end if;
    return pg_catalog.jsonb_build_object(
      'event_id',v_existing.id,'event_name',v_existing.event_name,
      'recording_status','accepted_interaction_only',
      'business_outcome_asserted',false,'replayed',true
    );
  end if;
  insert into public.product_adoption_events_v100(
    id,event_name,source_authority,actor_scope,actor_user_id,
    business_id,branch_id,session_id,event_context,idempotency_key,
    request_hash,occurred_at
  ) values(
    v_id,p_event_name,'client',v_taxonomy.actor_scope,v_actor,
    p_business,p_branch,p_session_id,v_context,v_key,v_hash,p_occurred_at
  );
  return pg_catalog.jsonb_build_object(
    'event_id',v_id,'event_name',p_event_name,
    'recording_status','accepted_interaction_only',
    'business_outcome_asserted',false,'replayed',false
  );
end
$$;
revoke all privileges on function public.record_product_interaction_v100(
  text,uuid,uuid,uuid,text,timestamptz,jsonb
) from public,anon,authenticated,service_role;
grant execute on function public.record_product_interaction_v100(
  text,uuid,uuid,uuid,text,timestamptz,jsonb
) to authenticated;

create or replace function app.capture_sale_adoption_v100()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public, app, pg_temp
as $$
begin
  perform app.append_server_adoption_event_v100(
    case when new.reversal_of is null
      then 'sale.recorded' else 'sale.reversed' end,
    new.business_id,new.branch_id,null,'sales',new.id,'INSERT',
    coalesce(new.occurred_at,new.created_at)
  );
  return new;
end
$$;
create or replace function app.capture_loyalty_redemption_adoption_v100()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public, app, pg_temp
as $$
begin
  perform app.append_server_adoption_event_v100(
    'loyalty.redemption_completed',new.business_id,null,new.actor,
    'loyalty_redemptions',new.id,'INSERT',new.redeemed_at
  );
  return new;
end
$$;
create or replace function app.capture_billing_paid_adoption_v100()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public, app, pg_temp
as $$
begin
  if tg_op='INSERT' and new.paid_normalized then
    perform app.append_server_adoption_event_v100(
      'billing.invoice_paid',new.business_id,null,null,
      'billing_provider_invoices',new.id,tg_op,
      coalesce(new.paid_at,new.updated_at)
    );
  elsif tg_op='UPDATE'
        and new.paid_normalized
        and not coalesce(old.paid_normalized,false) then
    perform app.append_server_adoption_event_v100(
      'billing.invoice_paid',new.business_id,null,null,
      'billing_provider_invoices',new.id,tg_op,
      coalesce(new.paid_at,new.updated_at)
    );
  end if;
  return new;
end
$$;
create or replace function app.capture_qr_join_adoption_v100()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public, app, pg_temp
as $$
begin
  if new.event_type='qr_join_linked' then
    perform app.append_server_adoption_event_v100(
      'customer.qr_join_completed',new.business_id,null,
      new.actor_auth_user_id,'customer_link_audit_events',new.id,'INSERT',
      new.created_at
    );
  end if;
  return new;
end
$$;
create or replace function app.capture_booking_adoption_v100()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public, app, pg_temp
as $$
begin
  perform app.append_server_adoption_event_v100(
    'customer.booking_submitted',new.business_id,null,null,
    'booking_requests',new.id,'INSERT',new.created_at
  );
  return new;
end
$$;
create or replace function app.capture_campaign_exposure_adoption_v100()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public, app, pg_temp
as $$
begin
  perform app.append_server_adoption_event_v100(
    'campaign.exposure_verified',new.business_id,null,new.recorded_by,
    'retention_campaign_exposures_v99',new.id,'INSERT',new.exposed_at
  );
  return new;
end
$$;
create or replace function app.capture_campaign_attribution_adoption_v100()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public, app, pg_temp
as $$
begin
  perform app.append_server_adoption_event_v100(
    'campaign.return_attributed',new.business_id,null,new.recorded_by,
    'retention_campaign_attributions_v99',new.id,'INSERT',new.returned_at
  );
  return new;
end
$$;

revoke all privileges on function app.capture_sale_adoption_v100()
  from public,anon,authenticated,service_role;
revoke all privileges on function app.capture_loyalty_redemption_adoption_v100()
  from public,anon,authenticated,service_role;
revoke all privileges on function app.capture_billing_paid_adoption_v100()
  from public,anon,authenticated,service_role;
revoke all privileges on function app.capture_qr_join_adoption_v100()
  from public,anon,authenticated,service_role;
revoke all privileges on function app.capture_booking_adoption_v100()
  from public,anon,authenticated,service_role;
revoke all privileges on function app.capture_campaign_exposure_adoption_v100()
  from public,anon,authenticated,service_role;
revoke all privileges on function app.capture_campaign_attribution_adoption_v100()
  from public,anon,authenticated,service_role;

create trigger sales_adoption_v100
  after insert on public.sales
  for each row execute function app.capture_sale_adoption_v100();
create trigger loyalty_redemptions_adoption_v100
  after insert on public.loyalty_redemptions
  for each row execute function app.capture_loyalty_redemption_adoption_v100();
create trigger billing_provider_invoices_paid_adoption_v100
  after insert or update of paid_normalized
  on public.billing_provider_invoices
  for each row execute function app.capture_billing_paid_adoption_v100();
create trigger customer_qr_join_adoption_v100
  after insert on public.customer_link_audit_events
  for each row execute function app.capture_qr_join_adoption_v100();
create trigger booking_requests_adoption_v100
  after insert on public.booking_requests
  for each row execute function app.capture_booking_adoption_v100();
create trigger retention_campaign_exposures_adoption_v100
  after insert on public.retention_campaign_exposures_v99
  for each row execute function app.capture_campaign_exposure_adoption_v100();
create trigger retention_campaign_attributions_adoption_v100
  after insert on public.retention_campaign_attributions_v99
  for each row execute function app.capture_campaign_attribution_adoption_v100();

create or replace function public.get_product_adoption_summary_v100(
  p_business uuid,
  p_from timestamptz default (now()-interval '30 days'),
  p_to timestamptz default now()
)
returns jsonb
language plpgsql
stable
security definer
set search_path = pg_catalog, public, app, pg_temp
as $$
declare
  v_authorized boolean:=false;
  v_totals jsonb;
  v_daily jsonb;
begin
  if auth.uid() is null then
    raise exception 'authenticated report session is required'
      using errcode='28000';
  end if;
  v_authorized:=
    app.is_super_admin()
    or app.has_perm(p_business,'view_finance')
    or (
      app.v89_can_access_business(p_business)
      and app.v89_platform_can('reports','r')
    );
  if not v_authorized then
    raise exception 'business adoption report is outside role scope'
      using errcode='42501';
  end if;
  if p_business is null
     or p_from is null
     or p_to is null
     or p_to<=p_from
     or p_to-p_from>interval '93 days'
     or p_to>clock_timestamp()+interval '5 minutes' then
    raise exception 'report range must be positive and no longer than 93 days'
      using errcode='22023';
  end if;
  select coalesce(
    pg_catalog.jsonb_agg(
      pg_catalog.jsonb_build_object(
        'event_name',summary.event_name,
        'source_authority',summary.source_authority,
        'economic_event',summary.economic_event,
        'event_count',summary.event_count
      )
      order by summary.event_count desc,summary.event_name
    ),
    '[]'::jsonb
  ) into v_totals
  from(
    select
      event_row.event_name,event_row.source_authority,
      taxonomy.economic_event,count(*)::bigint as event_count
    from public.product_adoption_events_v100 event_row
    join public.product_adoption_event_taxonomy_v100 taxonomy
      on taxonomy.event_name=event_row.event_name
    where event_row.business_id=p_business
      and event_row.occurred_at>=p_from
      and event_row.occurred_at<p_to
    group by
      event_row.event_name,event_row.source_authority,
      taxonomy.economic_event
  ) summary;
  select coalesce(
    pg_catalog.jsonb_agg(
      pg_catalog.jsonb_build_object(
        'date',daily.event_date,'client_interactions',daily.client_count,
        'server_outcomes',daily.server_count,
        'economic_events',daily.economic_count
      )
      order by daily.event_date
    ),
    '[]'::jsonb
  ) into v_daily
  from(
    select
      (event_row.occurred_at at time zone 'Asia/Singapore')::date
        as event_date,
      count(*) filter(
        where event_row.source_authority='client'
      )::bigint as client_count,
      count(*) filter(
        where event_row.source_authority='server'
      )::bigint as server_count,
      count(*) filter(
        where taxonomy.economic_event
      )::bigint as economic_count
    from public.product_adoption_events_v100 event_row
    join public.product_adoption_event_taxonomy_v100 taxonomy
      on taxonomy.event_name=event_row.event_name
    where event_row.business_id=p_business
      and event_row.occurred_at>=p_from
      and event_row.occurred_at<p_to
    group by 1
  ) daily;
  return pg_catalog.jsonb_build_object(
    'business_id',p_business,'from',p_from,'to',p_to,
    'taxonomy_version','v100','provider_status','not_configured',
    'privacy_contract',pg_catalog.jsonb_build_object(
      'contact_fields_collected',false,
      'free_text_collected',false,
      'raw_route_or_search_collected',false,
      'event_retention_days',400
    ),
    'totals',v_totals,'daily',v_daily
  );
end
$$;
revoke all privileges on function public.get_product_adoption_summary_v100(
  uuid,timestamptz,timestamptz
) from public,anon,authenticated,service_role;
grant execute on function public.get_product_adoption_summary_v100(
  uuid,timestamptz,timestamptz
) to authenticated;

create or replace function public.purge_product_adoption_events_v100(
  p_limit integer default 5000
)
returns integer
language plpgsql
security definer
set search_path = pg_catalog, public, app, pg_temp
as $$
declare
  v_deleted integer:=0;
begin
  if p_limit not between 1 and 10000 then
    raise exception 'purge limit must be 1..10000' using errcode='22023';
  end if;
  perform pg_catalog.set_config('app.v100_retention_purge','on',true);
  with expired as(
    select event_row.id
    from public.product_adoption_events_v100 event_row
    where event_row.retention_until<clock_timestamp()
    order by event_row.retention_until,event_row.id
    limit p_limit
    for update skip locked
  )
  delete from public.product_adoption_events_v100 event_row
  using expired
  where event_row.id=expired.id;
  get diagnostics v_deleted=row_count;
  perform pg_catalog.set_config('app.v100_retention_purge','',true);
  return v_deleted;
end
$$;
revoke all privileges on function public.purge_product_adoption_events_v100(
  integer
) from public,anon,authenticated,service_role;
grant execute on function public.purge_product_adoption_events_v100(integer)
  to service_role;

-- Daily bounded retention enforcement. Local/rehearsal databases without
-- pg_cron remain usable, while any environment with pg_cron gets exactly one
-- named job whose presence can be checked as release evidence.
do $cron$
begin
  if to_regnamespace('cron') is not null
     and to_regprocedure('cron.schedule(text,text,text)') is not null then
    if exists(
      select 1 from cron.job
      where jobname='nestly-v100-adoption-retention-daily'
    ) then
      perform cron.unschedule('nestly-v100-adoption-retention-daily');
    end if;
    perform cron.schedule(
      'nestly-v100-adoption-retention-daily',
      '40 19 * * *',
      $command$select public.purge_product_adoption_events_v100(5000)$command$
    );
  else
    raise notice
      'v100: pg_cron is absent; adoption retention purge is not scheduled';
  end if;
end
$cron$;

comment on table public.product_adoption_event_taxonomy_v100 is
  'Immutable event allowlist. Client events describe interactions only; server events derive from canonical database writes.';
comment on table public.product_adoption_events_v100 is
  'Append-only privacy-safe adoption evidence. No contact details, free text, provider payloads, raw routes or search terms.';
comment on function public.record_product_interaction_v100(
  text,uuid,uuid,uuid,text,timestamptz,jsonb
) is
  'Records only allowlisted client interactions and never asserts that the requested business outcome completed.';

commit;
