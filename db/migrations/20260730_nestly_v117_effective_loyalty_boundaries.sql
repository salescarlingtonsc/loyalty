-- NESTLY v117 — EFFECTIVE LOYALTY AND BRANCH WRITER BOUNDARIES
--
-- Forward-only local review candidate. This migration makes customer-facing
-- capability projection and merchant economic writers consume the same v94
-- firm/branch policy. It also removes every browser-callable downgrade path
-- superseded here. No production action is authorized by this file.

begin;

-- Partial gift-card loads are economic writes. Keep one immutable receipt per
-- logical browser attempt so a timeout/reconnect retry cannot load the same
-- card value twice while a positive balance remains.
create table if not exists public.gift_card_redeem_operations_v117 (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id)
    on delete cascade,
  branch_id uuid not null,
  actor uuid not null references auth.users(id) on delete restrict,
  idempotency_key uuid not null,
  request_hash text not null check (request_hash ~ '^[0-9a-f]{64}$'),
  status text not null check (status='completed'),
  gift_card_id uuid not null,
  client_id uuid not null,
  amount_cents integer not null check (amount_cents>0),
  result jsonb not null check (jsonb_typeof(result)='object'),
  created_at timestamptz not null default now(),
  unique (business_id,idempotency_key),
  foreign key (branch_id,business_id)
    references public.branches(id,business_id) on delete restrict,
  foreign key (gift_card_id,business_id)
    references public.gift_cards(id,business_id) on delete restrict,
  foreign key (client_id,business_id)
    references public.clients(id,business_id) on delete restrict
);

comment on table public.gift_card_redeem_operations_v117 is
  'v117 immutable idempotency receipts for exact-branch gift-card redemption.';

alter table public.gift_card_redeem_operations_v117
  enable row level security;
revoke all privileges on table public.gift_card_redeem_operations_v117
  from public,anon,authenticated;
drop trigger if exists gift_card_redeem_operations_v117_immutable_guard
  on public.gift_card_redeem_operations_v117;
create trigger gift_card_redeem_operations_v117_immutable_guard
  before update or delete on public.gift_card_redeem_operations_v117
  for each row execute function app.v41_operation_immutable_guard();

-- Customer surfaces have no selected merchant branch. A module is available
-- when it is effective at firm scope or at any active branch. Exact merchant
-- writes still require the selected branch and never use this aggregate helper.
create or replace function app.business_module_enabled_at_v117(
  p_business uuid,
  p_module text,
  p_branch uuid default null
)
returns boolean
language sql
stable
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
  select app.business_workspace_open_v94(p_business)
    and case
      when p_branch is not null then
        exists(
          select 1
          from public.branches branch
          cross join lateral app.effective_platform_module_mode_v94(
            p_business,branch.id,p_module
          ) resolved
          where branch.id=p_branch
            and branch.business_id=p_business
            and branch.active
            and resolved.mode in ('r','rw')
        )
      else
        case when exists(
          select 1
          from public.branches branch
          where branch.business_id=p_business
            and branch.active
        ) then exists(
          select 1
          from public.branches branch
          cross join lateral app.effective_platform_module_mode_v94(
            p_business,branch.id,p_module
          ) resolved
          where branch.business_id=p_business
            and branch.active
            and resolved.mode in ('r','rw')
        ) else exists(
          select 1
          from app.effective_platform_module_mode_v94(
            p_business,null,p_module
          ) resolved
          where resolved.mode in ('r','rw')
        )
        end
    end
$$;

revoke all on function app.business_module_enabled_at_v117(uuid,text,uuid)
  from public,anon,authenticated;

-- Customer-initiated actions are only actionable when at least one exact
-- branch can complete the corresponding write. Read-only module access may
-- still project balances/history, but must never advertise or prepare an
-- unfulfillable QR, booking, or appointment mutation.
create or replace function app.business_module_writable_at_v117(
  p_business uuid,
  p_module text,
  p_branch uuid default null
)
returns boolean
language sql
stable
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
  select app.business_workspace_open_v94(p_business)
    and case
      when p_branch is not null then exists(
        select 1
        from public.branches branch
        cross join lateral app.effective_platform_module_mode_v94(
          p_business,branch.id,p_module
        ) resolved
        where branch.id=p_branch
          and branch.business_id=p_business
          and branch.active
          and resolved.mode='rw'
      )
      when exists(
        select 1 from public.branches branch
        where branch.business_id=p_business and branch.active
      ) then exists(
        select 1
        from public.branches branch
        cross join lateral app.effective_platform_module_mode_v94(
          p_business,branch.id,p_module
        ) resolved
        where branch.business_id=p_business
          and branch.active
          and resolved.mode='rw'
      )
      else exists(
        select 1
        from app.effective_platform_module_mode_v94(
          p_business,null,p_module
        ) resolved
        where resolved.mode='rw'
      )
    end
$$;

revoke all on function app.business_module_writable_at_v117(uuid,text,uuid)
  from public,anon,authenticated;

create or replace function app.v89_business_module_enabled(
  p_business uuid,p_module text
)
returns boolean
language sql
stable
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
  select app.business_module_writable_at_v117(p_business,p_module,null)
$$;

revoke all on function app.v89_business_module_enabled(uuid,text)
  from public,anon,authenticated;

-- Keep the canonical customer scope resolver, but project only modules that
-- survive current workspace, firm and branch policy.
create or replace function app.v32_customer_wallet_context(
  p_business_slug text default null
)
returns table (
  identity_id uuid,
  business_id uuid,
  client_id uuid,
  business_name text,
  business_slug text,
  business_industry text,
  business_currency text,
  enabled_modules text[]
)
language plpgsql
stable
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare
  v_actor uuid:=auth.uid();
  v_slug text:=nullif(lower(btrim(coalesce(p_business_slug,''))),'');
begin
  if v_actor is null then
    raise exception 'authenticated customer session required'
      using errcode='28000';
  end if;
  if not app.platform_feature_enabled('customer_wallet') then
    raise exception 'customer wallet is not enabled' using errcode='0A000';
  end if;
  perform 1
  from public.customer_identities identity
  where identity.auth_user_id=v_actor and identity.status='active';
  if not found then
    raise exception 'active customer identity required' using errcode='42501';
  end if;

  return query
  select identity.id,link.business_id,link.client_id,
    business.name,business.slug,business.industry,business.currency,
    coalesce(array(
      select key.module_key
      from (
        select unnest(coalesce(business.enabled_modules,'{}'::text[])) module_key
        union
        select override_row.module_key
        from public.platform_module_overrides_v94 override_row
        where override_row.business_id=business.id
      ) key
      where app.business_module_enabled_at_v117(
        business.id,key.module_key,null
      )
      order by key.module_key
    ),'{}'::text[])
  from public.customer_identities identity
  join public.customer_links link
    on link.identity_id=identity.id
   and link.auth_user_id=v_actor
   and link.state='verified'
  join public.businesses business on business.id=link.business_id
  where identity.auth_user_id=v_actor
    and identity.status='active'
    and (v_slug is null or business.slug=v_slug)
  order by business.slug,link.id;
end
$$;

revoke all on function app.v32_customer_wallet_context(text)
  from public,anon,authenticated;

-- A workspace-level navigation projection represents the union of the
-- current actor's accessible active branches. Exact branch projections remain
-- exact. This makes a branch-only enable reachable without widening writers.
create or replace function app.staff_module_mode_at_or_any_v117(
  p_business uuid,
  p_branch uuid,
  p_module text
)
returns text
language sql
stable
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
  with candidate_modes as (
    select app.staff_module_mode_v94(
      p_business,p_branch,p_module
    ) access_mode
    where p_branch is not null
    union all
    select app.staff_module_mode_v94(
      p_business,null,p_module
    )
    where p_branch is null
      and not exists(
        select 1
        from public.branches branch
        where branch.business_id=p_business
          and branch.active
      )
    union all
    select app.staff_module_mode_v94(
      p_business,branch.id,p_module
    )
    from public.branches branch
    where p_branch is null
      and branch.business_id=p_business
      and branch.active
      and app.can_see_branch(p_business,branch.id)
  )
  select case
    when bool_or(access_mode='rw') then 'rw'
    when bool_or(access_mode='r') then 'r'
    else 'disabled'
  end
  from candidate_modes
$$;

revoke all on function app.staff_module_mode_at_or_any_v117(uuid,uuid,text)
  from public,anon,authenticated;

create or replace function app.staff_module_perms_at_v115(
  p_business uuid,
  p_branch uuid default null
)
returns jsonb
language sql
stable
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
  with actor_staff as (
    select staff_row.*
    from public.staff staff_row
    where staff_row.business_id=p_business
      and staff_row.user_id=auth.uid()
      and staff_row.active
    order by case when staff_row.role='owner' then 0 else 1 end,
      staff_row.created_at,staff_row.id
    limit 1
  ),
  module_keys as (
    select unnest(coalesce(business.enabled_modules,'{}'::text[])) module_key
    from public.businesses business
    where business.id=p_business
    union
    select override_row.module_key
    from public.platform_module_overrides_v94 override_row
    where override_row.business_id=p_business
  ),
  resolved as (
    select module_keys.module_key,
      app.staff_module_mode_at_or_any_v117(
        p_business,p_branch,module_keys.module_key
      ) access_mode,
      actor_staff.role
    from module_keys
    cross join actor_staff
  )
  select coalesce(
    jsonb_object_agg(resolved.module_key,resolved.access_mode)
      filter(where resolved.access_mode in ('r','rw')
        and (
          resolved.role='owner'
          or resolved.module_key not in ('branches','settings','setup')
        )
        and (
          resolved.module_key not in ('expenses','pnl')
          or 'view_finance'=any(app.role_perms(resolved.role))
        )
      ),
    '{}'::jsonb
  )
  from resolved
$$;

revoke all on function app.staff_module_perms_at_v115(uuid,uuid)
  from public,anon,authenticated;

create or replace function public.merchant_scan_redemption_qr_v117(
  p_business uuid,
  p_branch uuid,
  p_qr_token text,
  p_idempotency_key uuid
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare
  v_intent public.customer_redemption_intents_v89%rowtype;
  v_result jsonb;
  v_redemption uuid;
  v_operation uuid;
  v_operation_type text;
  v_program public.loyalty_programs%rowtype;
  v_reward_version public.loyalty_reward_versions%rowtype;
  v_current_quote jsonb;
  v_customer_name text;
  v_reward_label text;
begin
  if p_idempotency_key is null or length(coalesce(p_qr_token,''))<32 then
    raise exception 'invalid redemption QR scan' using errcode='22023';
  end if;
  if not app.can_module_write_at_v94(p_business,p_branch,'loyalty')
     or not app.has_perm(p_business,'create_sales') then
    raise exception 'merchant loyalty redemption access is required'
      using errcode='42501';
  end if;
  if p_branch is null
     or not exists(
       select 1
       from public.branches branch
       where branch.id=p_branch
         and branch.business_id=p_business
         and branch.active
     ) then
    raise exception 'an active business branch is required'
      using errcode='22023';
  end if;
  if not app.can_see_branch(p_business,p_branch) then
    raise exception 'redemption branch scope is not permitted'
      using errcode='42501';
  end if;

  perform pg_advisory_xact_lock(hashtextextended(
    'v117:scan:'||p_business::text||':'||app.v89_sha256(p_qr_token),0));
  select *
    into v_intent
    from public.customer_redemption_intents_v89 intent
   where intent.business_id=p_business
     and intent.token_hash=app.v89_sha256(p_qr_token)
   for update;
  if not found then
    raise exception 'redemption QR is invalid' using errcode='22023';
  end if;

  if v_intent.status='completed' then
    insert into public.customer_redemption_events_v89(
      intent_id,business_id,actor,event_type,idempotency_key,detail
    ) values(
      v_intent.id,p_business,auth.uid(),'scan_replayed',p_idempotency_key,
      jsonb_build_object(
        'redemption_kind',v_intent.redemption_kind,
        'redemption_id',v_intent.redemption_id,
        'operation_id',v_intent.completion_operation_id,
        'branch_id',p_branch
      )
    )
    on conflict(intent_id,event_type,idempotency_key) do nothing;
    return v_intent.completion_result||jsonb_build_object('replayed',true);
  end if;
  if v_intent.status<>'pending' then
    raise exception 'redemption QR is no longer pending' using errcode='22023';
  end if;
  if v_intent.expires_at<=now() then
    perform set_config('app.v89_redemption_intent_id',v_intent.id::text,true);
    update public.customer_redemption_intents_v89
       set status='expired'
     where id=v_intent.id;
    perform set_config('app.v89_redemption_intent_id','',true);
    insert into public.customer_redemption_events_v89(
      intent_id,business_id,actor,event_type,idempotency_key,detail
    ) values(
      v_intent.id,p_business,auth.uid(),'intent_expired',p_idempotency_key,
      jsonb_build_object('expired_at',v_intent.expires_at,'branch_id',p_branch)
    );
    return jsonb_build_object(
      'intent_id',v_intent.id,
      'status','expired',
      'expires_at',v_intent.expires_at,
      'branch_id',p_branch,
      'replayed',false
    );
  end if;
  if not app.platform_feature_enabled('customer_qr_redemption')
     or not coalesce((
       select capability.redemption_enabled
         from public.business_customer_capabilities_v89 capability
        where capability.business_id=p_business
     ),false)
     or not app.v89_business_module_enabled(p_business,'loyalty') then
    raise exception 'customer redemption is disabled for this business'
      using errcode='42501';
  end if;

  select *
    into v_program
    from public.loyalty_programs program
   where program.id=v_intent.quoted_program_id
     and program.business_id=p_business
     and program.active
   for share;
  if not found then
    raise exception 'redemption configuration changed; create a new QR'
      using errcode='23514';
  end if;
  select client.full_name
    into v_customer_name
    from public.clients client
   where client.id=v_intent.client_id
     and client.business_id=p_business;

  if v_intent.redemption_kind='classic_points' then
    v_current_quote:=jsonb_build_object(
      'program_id',v_program.id,
      'config_version_id',v_program.current_config_version_id,
      'loyalty_model',v_program.loyalty_model,
      'kind',v_program.kind,
      'points_spent',v_program.redeem_points,
      'credit_cents',v_program.reward_credit_cents
    );
    if v_current_quote is distinct from v_intent.quoted_terms then
      raise exception 'classic redemption terms changed; create a new QR'
        using errcode='23514';
    end if;
    v_reward_label:='Store credit';
    v_operation_type:='redeem_points';
    -- The public legacy wrapper authorizes at firm scope. This branch-aware
    -- scanner has already locked and proven the exact branch permission, so it
    -- calls the private canonical writer and keeps every economic invariant
    -- and idempotency record without widening browser execution rights.
    v_result:=app.redeem_points_v40_internal(
      p_business,v_intent.client_id,'v117:'||v_intent.id::text
    )::jsonb;
  else
    select reward_version.*
      into v_reward_version
      from public.loyalty_reward_versions reward_version
      join public.businesses business
        on business.id=reward_version.business_id
     where reward_version.id=v_intent.quoted_reward_version_id
       and reward_version.reward_id=v_intent.reward_id
       and reward_version.business_id=p_business
       and reward_version.config_version_id=business.active_config_version_id
       and reward_version.active
     for share;
    if not found
       or exists(
         select 1
           from public.loyalty_reward_services restriction
          where restriction.reward_version_id=v_intent.quoted_reward_version_id
       )
       or exists(
         select 1
           from public.loyalty_reward_products restriction
          where restriction.reward_version_id=v_intent.quoted_reward_version_id
       ) then
      raise exception 'catalog redemption terms changed; create a new QR'
        using errcode='23514';
    end if;
    if exists(
      select 1
        from public.loyalty_reward_branches restriction
       where restriction.reward_version_id=v_intent.quoted_reward_version_id
    ) and not exists(
      select 1
        from public.loyalty_reward_branches restriction
       where restriction.reward_version_id=v_intent.quoted_reward_version_id
         and restriction.branch_id=p_branch
    ) then
      raise exception 'reward is not eligible at this branch'
        using errcode='23514';
    end if;
    v_current_quote:=jsonb_build_object(
      'program_id',v_program.id,
      'config_version_id',v_reward_version.config_version_id,
      'reward_version_id',v_reward_version.id,
      'reward_id',v_intent.reward_id,
      'points_spent',v_reward_version.cost_points,
      'credit_cents',v_reward_version.credit_cents,
      'fulfillment_kind',v_reward_version.fulfillment_kind,
      'claim_available_from',v_reward_version.claim_available_from,
      'claim_available_until',v_reward_version.claim_available_until,
      'usage_limit',v_reward_version.usage_limit,
      'active',v_reward_version.active
    );
    if v_current_quote is distinct from v_intent.quoted_terms then
      raise exception 'catalog redemption terms changed; create a new QR'
        using errcode='23514';
    end if;
    v_reward_label:=coalesce(v_reward_version.customer_name,'Reward');
    v_operation_type:='redeem_reward';
    -- As above, avoid the legacy firm-scoped public wrapper after the exact
    -- branch authorization. The private canonical writer is not executable by
    -- browser roles and still records the normal redemption/provenance chain.
    v_result:=app.redeem_reward_core(
      p_business,
      v_intent.client_id,
      v_intent.reward_id,
      'v117:'||v_intent.id::text,
      p_branch,
      null,
      null
    )::jsonb;
  end if;

  select operation.id
    into v_operation
    from public.loyalty_operations operation
   where operation.business_id=p_business
     and operation.operation_type=v_operation_type
     and operation.idempotency_key='v117:'||v_intent.id::text
     and operation.status='completed';
  if not found then
    raise exception 'canonical redemption operation was not recorded'
      using errcode='40001';
  end if;
  if v_intent.redemption_kind='catalog_reward' then
    select provenance.redemption_id
      into v_redemption
      from public.loyalty_redemption_provenance provenance
     where provenance.business_id=p_business
       and provenance.operation_id=v_operation;
    if not found then
      raise exception 'canonical catalog redemption was not recorded'
        using errcode='40001';
    end if;
  end if;

  v_result:=jsonb_build_object(
    'intent_id',v_intent.id,
    'status','completed',
    'redemption_kind',v_intent.redemption_kind,
    'completed_at',now(),
    'branch_id',p_branch,
    'operation_id',v_operation,
    'redemption_id',v_redemption,
    'customer_name',v_customer_name,
    'reward_label',v_reward_label,
    'points_spent',v_intent.quoted_points_spent,
    'credit_cents',v_intent.quoted_credit_cents,
    'result',v_result,
    'replayed',false
  );
  perform set_config('app.v89_redemption_intent_id',v_intent.id::text,true);
  update public.customer_redemption_intents_v89
     set status='completed',
         completed_at=now(),
         completed_by=auth.uid(),
         completion_idempotency_key=p_idempotency_key,
         redemption_id=v_redemption,
         completion_operation_id=v_operation,
         completion_result=v_result
   where id=v_intent.id;
  perform set_config('app.v89_redemption_intent_id','',true);
  insert into public.customer_redemption_events_v89(
    intent_id,business_id,actor,event_type,idempotency_key,detail
  ) values(
    v_intent.id,p_business,auth.uid(),'scan_completed',p_idempotency_key,
    jsonb_build_object(
      'redemption_kind',v_intent.redemption_kind,
      'redemption_id',v_redemption,
      'operation_id',v_operation,
      'branch_id',p_branch
    )
  );
  return v_result;
end
$$;

-- New gift-card value may only be issued through a branch where Gift cards is
-- writable. The immutable sale now records that exact branch.
create or replace function public.issue_gift_card_at_branch_v117(
  p_business uuid,
  p_branch uuid,
  p_amount integer,
  p_purchaser uuid,
  p_recipient_email text,
  p_idempotency_key uuid
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare
  v_actor uuid:=auth.uid();
  v_staff uuid;
  v_email text:=nullif(lower(btrim(p_recipient_email)),'');
  v_payload jsonb;
  v_hash text;
  v_existing public.gift_card_issue_operations%rowtype;
  v_code text;
  v_card public.gift_cards%rowtype;
  v_sale public.sales%rowtype;
  v_result jsonb;
begin
  if v_actor is null
     or not app.can_module_write_at_v94(
       p_business,p_branch,'giftcards'
     )
     or not app.has_perm(p_business,'create_sales') then
    raise exception 'branch-effective giftcards and create-sales authorization is required'
      using errcode='42501';
  end if;
  perform 1
  from public.branches branch
  where branch.id=p_branch
    and branch.business_id=p_business
    and branch.active
    and app.can_see_branch(p_business,branch.id)
  for share;
  if not found then
    raise exception 'active visible gift-card branch is required'
      using errcode='42501';
  end if;
  select staff_row.id into v_staff
  from public.staff staff_row
  where staff_row.business_id=p_business
    and staff_row.user_id=v_actor
    and staff_row.active
    and 'create_sales'=any(app.role_perms(staff_row.role))
  order by case when staff_row.role='owner' then 0 else 1 end,
    staff_row.created_at
  limit 1
  for update;
  if not found then
    raise exception 'active staff authorization is required'
      using errcode='42501';
  end if;
  if p_idempotency_key is null or p_amount is null or p_amount<=0
     or p_amount>100000000
     or (v_email is not null and char_length(v_email)>320) then
    raise exception 'invalid gift-card issuance request' using errcode='22023';
  end if;
  if p_purchaser is not null and not exists(
    select 1
    from public.clients client
    where client.id=p_purchaser and client.business_id=p_business
  ) then
    raise exception 'purchaser does not belong to this business'
      using errcode='22023';
  end if;
  v_payload:=jsonb_build_object(
    'amount_cents',p_amount,
    'branch_id',p_branch,
    'business_id',p_business,
    'purchaser_client_id',p_purchaser,
    'recipient_email',v_email
  );
  v_hash:=app.v41_request_hash(v_payload::text);
  perform pg_advisory_xact_lock(hashtextextended(
    'v117:gift-card:'||p_business::text||':'||p_idempotency_key::text,0
  ));
  select * into v_existing
  from public.gift_card_issue_operations operation
  where operation.business_id=p_business
    and operation.idempotency_key=p_idempotency_key
  for update;
  if found then
    if v_existing.actor is distinct from v_actor
       or v_existing.request_hash<>v_hash then
      raise exception 'idempotency key conflicts with another gift-card request'
        using errcode='23505';
    end if;
    select * into v_card
    from public.gift_cards card
    where card.id=v_existing.gift_card_id
      and card.business_id=p_business
    for share;
    return jsonb_build_object(
      'status','completed',
      'gift_card_id',v_existing.gift_card_id,
      'sale_id',v_existing.sale_id,
      'code',v_card.code,
      'initial_cents',v_existing.amount_cents,
      'balance_cents',v_existing.amount_cents,
      'branch_id',p_branch,
      'replayed',true
    );
  end if;
  if not coalesce((
    select business.gift_card_sales_enabled
    from public.businesses business
    where business.id=p_business
  ),false) then
    raise exception 'gift_card_sales_disabled' using errcode='55000';
  end if;
  perform app.sv_legacy_issue_guard(p_business,'gift_card');
  loop
    v_code:='GC-'||upper(substr(md5(
      gen_random_uuid()::text||clock_timestamp()::text
    ),1,12));
    exit when not exists(
      select 1 from public.gift_cards card where card.code=v_code
    );
  end loop;
  insert into public.gift_cards(
    business_id,code,initial_cents,balance_cents,
    purchaser_client_id,recipient_email
  ) values(
    p_business,v_code,p_amount,p_amount,p_purchaser,v_email
  )
  returning * into v_card;
  insert into public.sales(
    business_id,client_id,kind,amount_cents,note,staff_id,branch_id
  ) values(
    p_business,p_purchaser,'gift_card',p_amount,
    'gift card liability issued',v_staff,p_branch
  )
  returning * into v_sale;
  v_result:=jsonb_build_object(
    'status','completed',
    'gift_card_id',v_card.id,
    'sale_id',v_sale.id,
    'code',v_card.code,
    'initial_cents',v_card.initial_cents,
    'balance_cents',v_card.balance_cents,
    'branch_id',p_branch,
    'replayed',false
  );
  insert into public.gift_card_issue_operations(
    business_id,actor,idempotency_key,request_hash,status,
    amount_cents,gift_card_id,sale_id
  ) values(
    p_business,v_actor,p_idempotency_key,v_hash,'completed',
    p_amount,v_card.id,v_sale.id
  );
  return v_result;
end
$$;

-- Redeeming an already-issued card fulfils an existing liability. It remains
-- available through an exact Till + Clients branch even when new Gift cards
-- issuance is disabled.
create or replace function public.redeem_gift_card_at_branch_v117(
  p_business uuid,
  p_branch uuid,
  p_code text,
  p_client uuid,
  p_amount integer,
  p_idempotency_key uuid
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare
  v_actor uuid:=auth.uid();
  v_result jsonb;
  v_payload jsonb;
  v_hash text;
  v_existing public.gift_card_redeem_operations_v117%rowtype;
  v_gift_card uuid;
begin
  if v_actor is null
     or not app.can_module_write_at_v94(p_business,p_branch,'till')
     or not app.can_module_read_at_v94(p_business,p_branch,'clients')
     or not app.has_perm(p_business,'create_sales') then
    raise exception 'branch-effective Till, Clients and create-sales authorization is required'
      using errcode='42501';
  end if;
  perform 1
  from public.branches branch
  where branch.id=p_branch
    and branch.business_id=p_business
    and branch.active
    and app.can_see_branch(p_business,branch.id)
  for share;
  if not found then
    raise exception 'active visible redemption branch is required'
      using errcode='42501';
  end if;
  if p_idempotency_key is null
     or p_code is null
     or btrim(p_code)=''
     or p_client is null
     or (p_amount is not null and p_amount<=0) then
    raise exception 'invalid gift-card redemption request'
      using errcode='22023';
  end if;
  v_payload:=jsonb_build_object(
    'amount_cents',p_amount,
    'branch_id',p_branch,
    'business_id',p_business,
    'client_id',p_client,
    'code',upper(btrim(p_code))
  );
  v_hash:=app.v41_request_hash(v_payload::text);
  perform pg_advisory_xact_lock(hashtextextended(
    'v117:gift-card-redeem:'||p_business::text||':'||
      p_idempotency_key::text,0
  ));
  select * into v_existing
  from public.gift_card_redeem_operations_v117 operation
  where operation.business_id=p_business
    and operation.idempotency_key=p_idempotency_key;
  if found then
    if v_existing.actor is distinct from v_actor
       or v_existing.request_hash<>v_hash then
      raise exception
        'idempotency key conflicts with another gift-card redemption'
        using errcode='23505';
    end if;
    return v_existing.result||jsonb_build_object('replayed',true);
  end if;
  v_result:=public.redeem_gift_card(
    p_business,p_code,p_client,p_amount
  )::jsonb;
  select card.id into v_gift_card
  from public.gift_cards card
  where card.business_id=p_business
    and upper(card.code)=upper(btrim(p_code));
  if not found then
    raise exception 'gift-card redemption receipt could not be resolved'
      using errcode='40001';
  end if;
  v_result:=v_result||jsonb_build_object(
    'branch_id',p_branch,
    'replayed',false
  );
  insert into public.gift_card_redeem_operations_v117(
    business_id,branch_id,actor,idempotency_key,request_hash,status,
    gift_card_id,client_id,amount_cents,result
  ) values(
    p_business,p_branch,v_actor,p_idempotency_key,v_hash,'completed',
    v_gift_card,p_client,(v_result->>'loaded_cents')::integer,v_result
  );
  return v_result;
end
$$;

create or replace function public.business_has_active_gift_liability_v117(
  p_business uuid,
  p_branch uuid
)
returns boolean
language plpgsql
stable
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
begin
  if auth.uid() is null
     or not app.can_module_write_at_v94(p_business,p_branch,'till')
     or not app.can_module_read_at_v94(p_business,p_branch,'clients')
     or not app.has_perm(p_business,'create_sales') then
    raise exception 'branch-effective Till, Clients and create-sales authorization is required'
      using errcode='42501';
  end if;
  return exists(
    select 1
    from public.gift_cards card
    where card.business_id=p_business
      and card.status='active'
      and card.balance_cents>0
  );
end
$$;

-- Retire every less-scoped browser path. SECURITY DEFINER successors retain
-- owner-internal access while authenticated browser callers cannot downgrade.
revoke all on function public.merchant_scan_redemption_qr_v89(uuid,text,uuid)
  from public,anon,authenticated;
revoke all on function public.merchant_scan_redemption_qr_v93(
  uuid,uuid,text,uuid
) from public,anon,authenticated;
revoke all on function public.issue_gift_card(uuid,integer,uuid,text,uuid)
  from public,anon,authenticated;
revoke all on function public.redeem_gift_card_v41(uuid,text,uuid,integer)
  from public,anon,authenticated;
revoke all on function public.redeem_gift_card(uuid,text,uuid,integer)
  from public,anon,authenticated;

revoke all on function public.merchant_scan_redemption_qr_v117(
  uuid,uuid,text,uuid
) from public,anon,authenticated;
revoke all on function public.issue_gift_card_at_branch_v117(
  uuid,uuid,integer,uuid,text,uuid
) from public,anon,authenticated;
-- Earlier local v117 drafts exposed a five-argument branch wrapper without an
-- idempotency key. A pristine canonical chain has never created it, while an
-- upgraded development database may still retain it. Remove it conditionally
-- so both clean installs and upgrades converge on the keyed contract.
drop function if exists public.redeem_gift_card_at_branch_v117(
  uuid,uuid,text,uuid,integer
);
revoke all on function public.redeem_gift_card_at_branch_v117(
  uuid,uuid,text,uuid,integer,uuid
) from public,anon,authenticated;
revoke all on function public.business_has_active_gift_liability_v117(
  uuid,uuid
) from public,anon,authenticated;

grant execute on function public.merchant_scan_redemption_qr_v117(
  uuid,uuid,text,uuid
) to authenticated;
grant execute on function public.issue_gift_card_at_branch_v117(
  uuid,uuid,integer,uuid,text,uuid
) to authenticated;
grant execute on function public.redeem_gift_card_at_branch_v117(
  uuid,uuid,text,uuid,integer,uuid
) to authenticated;
grant execute on function public.business_has_active_gift_liability_v117(
  uuid,uuid
) to authenticated;

commit;
