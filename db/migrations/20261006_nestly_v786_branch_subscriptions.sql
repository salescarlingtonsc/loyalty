-- nestly_v786 — every new branch is its own Razorpay subscription (2026-09-05).
--
-- OWNER RULINGS (2026-09-05, Subscription page review; they reverse "one card for all" given
-- earlier the same day):
--   1. "change card is allowed per branches. means different payment date is allowed." Every NEW
--      branch gets its own Razorpay subscription from the day it is added — its own card at
--      checkout, its own renewal date, its own billing cycle, its own Stop / Resume.
--   2. The firms already paying ONE company subscription that covers several branches keep it
--      until they choose otherwise ("Keep shared until they choose").
--   3. "Drop tiers, flat price": a branch is SGD 1,188 / year or SGD 148 / month. Customer
--      capacity ceilings disappear from the product.
--   4. "Never lock, only switch off branches" (v784 opened the door; this file is what a lapse
--      does instead: the branch, and only the branch, switches off).
--
-- THE SHAPE. A branch carries billing_mode: 'shared' (the legacy model — one company
-- subscription, quantity = units, v202/v280/v621/v665 unchanged) or 'own' (this file). An 'own'
-- branch has one row in public.branch_subscriptions_v786, which is to the branch what
-- public.subscriptions is to the company: provider ids, status, period, payment truth, the
-- card, the renewal-cancel intent and the scheduled cycle change. Razorpay is told which branch a
-- subscription belongs to through notes.branch_id, exactly as notes.business_id already names
-- the tenant, so every provider object round-trips to its branch without a lookup table.
--
-- ONE PIPELINE, NOT TWO. Webhook, return-hop synthesis and reconciliation recovery all push
-- events through ingest_billing_event_v755 -> apply_razorpay_billing_event_v755. That applier is
-- PATCHED IN PLACE (extract-and-diff, asserted needles) to hand an event that names a branch to
-- app.apply_razorpay_branch_event_v786 and return. The branch applier writes the SAME mirror
-- tables (billing_provider_customers / _subscriptions / _subscription_items / _invoices /
-- billing_payment_attempts / billing_evidence) with the same rank guards, so reconciliation and
-- the payments history read branch subscriptions with no new reader; what differs is only the
-- tenant-level row it updates (branch_subscriptions_v786, never public.subscriptions) and what a
-- paid / halted / cancelled status does (this branch switches on / off, never the company).
--
-- COMMANDS. billing_commands gains command_scope ('business' | 'branch'). A branch command is
-- minted by request_branch_billing_command_v786 (owner-only, flat tier snapshotted onto the
-- row) and claimed by claim_billing_command_v786, which answers the SAME jsonb contract the edge
-- function already executes (plan id, amount, cadence, provider_subscription_id) plus scope and
-- branch_id — and delegates every business-scoped command to claim_billing_command_v130
-- unchanged. The edge function is therefore taught scope, not a second executor.
--
-- WHAT THE SHARED MODEL LOSES: nothing. Its counts (planUnits, v621 activation, the v758 summary)
-- are restricted to billing_mode='shared' so an 'own' branch waiting for its own checkout can
-- never be activated by, or counted into, the company's charge.
--
-- LAPSE. A company subscription that is unpaid 14 days past its period end used to LOCK the
-- workspace (v620). Now app.sweep_lapsed_shared_branches_v786 switches its shared branches off
-- ('suspended', prior state kept) and the next subscription.charged restores them
-- (app.restore_lapsed_shared_branches_v786, spliced into the applier's paid path). An 'own'
-- branch lapses on its own subscription's halted event, in the branch applier.
--
-- Rollback suite: db/tests/v786_branch_subscriptions.sql
begin;

-- =============================================================================================
-- 0 · The live bodies this file patches are what it believes they are.
-- =============================================================================================
do $v786_assert$
declare v_body text;
begin
  v_body := pg_get_functiondef('public.apply_razorpay_billing_event_v755(text)'::regprocedure);
  if position($n$    v_business := app.razorpay_business_v755(v_event.payload);
    if v_business is null then
      raise exception 'Razorpay event cannot be mapped to a business';
    end if;
$n$ in v_body) = 0 then
    raise exception 'v786: apply_razorpay_billing_event_v755 has drifted (business mapping needle)';
  end if;
  if position($n$  v_paid boolean := false;
begin$n$ in v_body) = 0 then
    raise exception 'v786: apply_razorpay_billing_event_v755 has drifted (declare needle)';
  end if;
  if position($n$      'branch_activation',
      app.activate_pending_branches_on_paid_v621(
        v_business,'razorpay-charged:'||p_event_id
      )
    );
  end if;
  return v_result;
end$n$ in v_body) = 0 then
    raise exception 'v786: apply_razorpay_billing_event_v755 has drifted (paid-path needle)';
  end if;
  if position('v786' in v_body) > 0 then
    raise exception 'v786: apply_razorpay_billing_event_v755 already carries v786';
  end if;

  v_body := pg_get_functiondef('app.activate_pending_branches_on_paid_v621(uuid,text)'::regprocedure);
  if position($n$   where b.business_id = p_business and b.billing_state = 'active';$n$ in v_body) = 0
     or position($n$     where b.business_id = p_business and b.billing_state = 'pending_payment'$n$ in v_body) = 0 then
    raise exception 'v786: activate_pending_branches_on_paid_v621 has drifted';
  end if;

  v_body := pg_get_functiondef('public.get_business_billing_v758(uuid)'::regprocedure);
  if position($n$count(*) filter (where branch.billing_state in ('pending_payment','active'))::integer,$n$ in v_body) = 0 then
    raise exception 'v786: get_business_billing_v758 has drifted (billable count needle)';
  end if;

  v_body := pg_get_functiondef('public.get_business_billing_v124(uuid)'::regprocedure);
  if position($n$         and branch.billing_state in ('pending_payment','active')
    ),$n$ in v_body) = 0 then
    raise exception 'v786: get_business_billing_v124 has drifted (billable_branch_count needle)';
  end if;

  v_body := pg_get_functiondef('public.list_due_renewal_cancels_v764()'::regprocedure);
  if position('branch_subscriptions_v786' in v_body) > 0 then
    raise exception 'v786: list_due_renewal_cancels_v764 already carries v786';
  end if;
end
$v786_assert$;

-- =============================================================================================
-- 1 · Schema.
-- =============================================================================================
alter table public.branches
  add column if not exists billing_mode text not null default 'shared';
alter table public.branches drop constraint if exists branches_billing_mode_ck_v786;
alter table public.branches
  add constraint branches_billing_mode_ck_v786 check (billing_mode in ('shared','own'));
comment on column public.branches.billing_mode is
  'v786: shared = a unit of the company subscription (legacy); own = this branch has its own Razorpay subscription in branch_subscriptions_v786.';

alter table public.billing_commands
  add column if not exists command_scope text not null default 'business';
alter table public.billing_commands drop constraint if exists billing_commands_scope_ck_v786;
alter table public.billing_commands
  add constraint billing_commands_scope_ck_v786 check (
    command_scope in ('business','branch')
    and (command_scope <> 'branch' or requested_branch_id is not null)
  );

create table if not exists public.branch_subscriptions_v786 (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  branch_id uuid not null unique references public.branches(id) on delete cascade,
  provider text not null default 'razorpay' check (provider in ('razorpay')),
  provider_customer_id text,
  provider_subscription_id text unique,
  provider_plan_id text,
  status text not null default 'incomplete',
  payment_status text not null default 'not_collected'
    check (payment_status in ('not_collected','paid','failed')),
  cadence text check (cadence in ('monthly','annual')),
  cadence_months smallint,
  currency text not null default 'SGD',
  unit_amount_cents integer check (unit_amount_cents is null or unit_amount_cents >= 0),
  current_period_start timestamptz,
  current_period_end timestamptz,
  next_payment_at timestamptz,
  last_paid_at timestamptz,
  last_paid_invoice_id text,
  cancel_at_period_end boolean not null default false,
  canceled_at timestamptz,
  ended_at timestamptz,
  renewal_cancel_requested_at timestamptz,
  renewal_cancel_sent_at timestamptz,
  scheduled_cadence text check (scheduled_cadence is null or scheduled_cadence in ('monthly','annual')),
  scheduled_plan_id text,
  scheduled_effective_at timestamptz,
  scheduled_amount_cents integer,
  payment_method_kind text check (payment_method_kind is null or payment_method_kind in ('card','paynow','other')),
  payment_method_brand text,
  payment_method_last4 text check (payment_method_last4 is null or payment_method_last4 ~ '^[0-9]{4}$'),
  payment_method_updated_at timestamptz,
  payment_method_source_payment_id text,
  livemode boolean not null default false,
  provider_event_created_at timestamptz,
  provider_event_rank smallint not null default 0,
  payment_event_created_at timestamptz,
  payment_event_rank smallint not null default 0,
  last_event_id text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint branch_subscriptions_cancel_sent_needs_intent_v786
    check (renewal_cancel_sent_at is null or renewal_cancel_requested_at is not null)
);
create index if not exists branch_subscriptions_v786_business_idx
  on public.branch_subscriptions_v786(business_id);
alter table public.branch_subscriptions_v786 enable row level security;
revoke all privileges on table public.branch_subscriptions_v786 from public, anon, authenticated;
grant select on table public.branch_subscriptions_v786 to authenticated;
drop policy if exists branch_subscriptions_v786_owner_read on public.branch_subscriptions_v786;
create policy branch_subscriptions_v786_owner_read
  on public.branch_subscriptions_v786 for select to authenticated
  using (app.is_salon_owner(business_id) or app.is_super_admin());
comment on table public.branch_subscriptions_v786 is
  'v786: one Razorpay subscription per own-billed branch — provider ids, period, payment truth, card, renewal intent, scheduled cycle. Written only by the applier and the service-role RPCs.';

-- =============================================================================================
-- 2 · The flat price. The tier catalogue keeps its rows (the Razorpay plan ids live there); the
--     product now prices every branch from the LOWEST tier of each cadence and never asks about
--     capacity again.
-- =============================================================================================
create or replace function app.billing_flat_tier_v786(p_cadence text)
returns public.billing_capacity_tier_catalog_v664
language sql
stable security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
  select tier.* from public.billing_capacity_tier_catalog_v664 tier
   where tier.currency = 'SGD' and tier.cadence = p_cadence and tier.active
     and tier.effective_from <= now()
     and (tier.effective_to is null or tier.effective_to > now())
     and tier.provider_base_price_id is not null
   order by tier.capacity_ceiling
   limit 1;
$$;
revoke all on function app.billing_flat_tier_v786(text) from public, anon, authenticated;

-- =============================================================================================
-- 3 · Minting a branch command.
-- =============================================================================================
create or replace function public.request_branch_billing_command_v786(
  p_business uuid, p_branch uuid, p_command_type text, p_cadence text, p_idempotency_key uuid
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_actor uuid := auth.uid();
  v_branch public.branches%rowtype;
  v_sub public.branch_subscriptions_v786%rowtype;
  v_tier public.billing_capacity_tier_catalog_v664%rowtype;
  v_catalog public.billing_plan_catalog_v124%rowtype;
  v_cadence text := lower(nullif(btrim(coalesce(p_cadence,'')),''));
  v_fingerprint text;
  v_command public.billing_commands%rowtype;
begin
  if v_actor is null
     or not (app.is_billing_owner_v620(p_business) or app.is_super_admin()) then
    raise exception 'active owner or super-admin access is required' using errcode = '42501';
  end if;
  if p_idempotency_key is null then
    raise exception 'an idempotency key is required' using errcode = '22023';
  end if;
  if p_command_type not in (
      'create_checkout','change_cadence','cancel_at_period_end','resume',
      'update_card','refresh_payment_method'
    ) then
    raise exception 'invalid branch billing command' using errcode = '22023';
  end if;
  select * into v_branch from public.branches
   where id = p_branch and business_id = p_business;
  if not found then
    raise exception 'branch was not found for this business' using errcode = '22023';
  end if;
  if v_branch.billing_mode <> 'own' then
    raise exception 'this branch is covered by the company subscription' using errcode = '22023';
  end if;
  select * into v_sub from public.branch_subscriptions_v786 where branch_id = p_branch;

  if p_command_type in ('create_checkout','change_cadence') then
    if v_cadence is null or v_cadence not in ('monthly','annual') then
      raise exception 'a billing cycle of monthly or annual is required' using errcode = '22023';
    end if;
    v_tier := app.billing_flat_tier_v786(v_cadence);
    if v_tier.id is null then
      raise exception 'this billing cycle is not available for card checkout yet' using errcode = '22023';
    end if;
    /* The v124 catalogue row is still what billing_commands_v124_catalog_check demands for a
       checkout; it names the cadence, nothing else about it is read any more. */
    select * into v_catalog from public.billing_plan_catalog_v124 catalog
     where catalog.currency = 'SGD' and catalog.cadence = v_cadence
       and catalog.active and catalog.effective_from <= now()
       and (catalog.effective_to is null or catalog.effective_to > now())
     order by catalog.effective_from desc limit 1;
    if not found then
      raise exception 'active price catalog entry was not found' using errcode = '22023';
    end if;
  elsif v_cadence is not null then
    raise exception 'a billing cycle is not valid for this command' using errcode = '22023';
  end if;

  if p_command_type = 'create_checkout' then
    if v_sub.provider_subscription_id is not null
       and coalesce(v_sub.status,'') in ('active','past_due','paused')
       and v_sub.payment_status = 'paid' then
      raise exception 'this branch already has a paid subscription' using errcode = '22023';
    end if;
  elsif v_sub.provider_subscription_id is null then
    raise exception 'this branch has no provider subscription to act on' using errcode = '22023';
  end if;
  if p_command_type = 'change_cadence' and v_sub.cadence = v_cadence
     and v_sub.scheduled_cadence is null then
    raise exception 'this branch is already on that billing cycle' using errcode = '22023';
  end if;

  v_fingerprint := encode(extensions.digest(convert_to(
    p_business::text||E'\n'||p_branch::text||E'\n'||p_command_type||E'\n'||coalesce(v_cadence,'')
    ||E'\nv786_branch','utf8'),'sha256'),'hex');
  select * into v_command from public.billing_commands
   where business_id = p_business and command_type = p_command_type
     and idempotency_key = p_idempotency_key;
  if found then
    if v_command.request_fingerprint <> v_fingerprint then
      raise exception 'billing command idempotency key conflicts with another request' using errcode = '22023';
    end if;
  else
    insert into public.billing_commands(
      business_id,command_type,requested_cadence,pricing_model,requested_customer_capacity,
      billing_catalog_id_v124,billing_tier_id_v664,idempotency_key,request_fingerprint,
      requested_by,requested_branch_id,command_scope
    ) values (
      p_business,p_command_type,v_cadence,'v124_customer_capacity',v_tier.capacity_ceiling,
      v_catalog.id,v_tier.id,p_idempotency_key,v_fingerprint,v_actor,p_branch,'branch'
    ) returning * into v_command;
  end if;
  return jsonb_build_object(
    'command_id',v_command.id,'status',v_command.status,'scope','branch',
    'command_type',v_command.command_type,'cadence',v_command.requested_cadence,
    'branch_id',p_branch,'redirect_url',v_command.redirect_url,'requested_at',v_command.requested_at
  );
end
$$;
revoke all on function public.request_branch_billing_command_v786(uuid,uuid,text,text,uuid) from public, anon;
grant execute on function public.request_branch_billing_command_v786(uuid,uuid,text,text,uuid) to authenticated, service_role;

-- =============================================================================================
-- 4 · Claiming: the executor's one door. Business scope delegates to v130 unchanged.
-- =============================================================================================
create or replace function public.claim_billing_command_v786(p_command uuid, p_actor uuid)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_command public.billing_commands%rowtype;
  v_sub public.branch_subscriptions_v786%rowtype;
  v_tier public.billing_capacity_tier_catalog_v664%rowtype;
  v_customer text;
  v_recovery boolean := false;
begin
  select * into v_command from public.billing_commands
   where id = p_command and requested_by = p_actor for update;
  if not found then
    raise exception 'billing command was not found for this actor' using errcode = '42501';
  end if;
  if v_command.command_scope <> 'branch' then
    return public.claim_billing_command_v130(p_command, p_actor);
  end if;
  if v_command.status in ('completed','failed','canceled') then
    return jsonb_build_object(
      'command_id',v_command.id,'status',v_command.status,'scope','branch',
      'command_type',v_command.command_type,'branch_id',v_command.requested_branch_id,
      'provider_object_id',v_command.provider_object_id,
      'redirect_url',v_command.redirect_url,'error_code',v_command.error_code,
      'error_message',v_command.error_message,'pricing_model',v_command.pricing_model
    );
  end if;
  v_recovery := v_command.status in ('processing','uncertain');
  update public.billing_commands set status = 'processing'
   where id = v_command.id and status in ('pending','uncertain')
   returning * into v_command;
  if not found then
    select * into strict v_command from public.billing_commands where id = p_command;
  end if;
  select * into v_sub from public.branch_subscriptions_v786 where branch_id = v_command.requested_branch_id;
  if v_command.requested_cadence is not null then
    select * into v_tier from public.billing_capacity_tier_catalog_v664 tier
     where tier.id = v_command.billing_tier_id_v664;
    if v_tier.id is null or v_tier.provider_base_price_id is null then
      raise exception 'this billing cycle has no provider plan configured' using errcode = '22023';
    end if;
  end if;
  select customer.provider_customer_id into v_customer
    from public.billing_provider_customers customer
   where customer.business_id = v_command.business_id;

  return jsonb_build_object(
    'command_id',v_command.id,'status',v_command.status,'scope','branch',
    'command_type',v_command.command_type,'business_id',v_command.business_id,
    'branch_id',v_command.requested_branch_id,
    'pricing_model','v124_customer_capacity',
    'requested_cadence',v_command.requested_cadence,
    'requested_customer_capacity',v_command.requested_customer_capacity,
    'extra_capacity_blocks',0,
    'provider_idempotency_key','nestly:v786:branch-command:'||v_command.id::text,
    'recovery_required',v_recovery,
    'prior_provider_object_id',v_command.provider_object_id,
    'prior_redirect_url',v_command.redirect_url,
    'prior_error_code',v_command.error_code,
    'currency','SGD',
    'provider_customer_id',coalesce(v_sub.provider_customer_id,v_customer),
    'provider_subscription_id',v_sub.provider_subscription_id,
    'provider_base_price_id',v_tier.provider_base_price_id,
    'base_amount_cents',v_tier.amount_cents,
    'prior_base_amount_cents',v_sub.unit_amount_cents,
    'tax_behavior',coalesce(v_tier.tax_behavior,'exclusive'),
    'self_service_onboarding',false
  );
end
$$;
revoke all on function public.claim_billing_command_v786(uuid,uuid) from public, anon, authenticated;
grant execute on function public.claim_billing_command_v786(uuid,uuid) to service_role;

-- =============================================================================================
-- 5 · Adding a branch: born 'own', unpaid, switched off, with its checkout command in hand.
-- =============================================================================================
create or replace function public.business_add_branch_v786(
  p_business uuid, p_name text, p_address text default null, p_phone text default null,
  p_email text default null, p_copy_from uuid default null, p_cadence text default 'annual',
  p_idempotency_key uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_actor uuid := auth.uid();
  v_branch public.branches%rowtype;
  v_existing public.billing_commands%rowtype;
  v_command jsonb;
  v_copied jsonb := null;
  v_name text := nullif(btrim(coalesce(p_name,'')),'');
  v_cadence text := lower(nullif(btrim(coalesce(p_cadence,'')),''));
begin
  if v_actor is null or not (app.is_salon_owner(p_business) or app.is_super_admin()) then
    raise exception 'owner access is required' using errcode = '42501';
  end if;
  if v_name is null then
    raise exception 'a branch name is required' using errcode = '22023';
  end if;
  if p_idempotency_key is null then
    raise exception 'an idempotency key is required' using errcode = '22023';
  end if;
  if v_cadence is null or v_cadence not in ('monthly','annual') then
    raise exception 'a billing cycle of monthly or annual is required' using errcode = '22023';
  end if;

  select * into v_existing from public.billing_commands
   where business_id = p_business and idempotency_key = p_idempotency_key;
  if found then
    select * into v_branch from public.branches where id = v_existing.requested_branch_id;
    return jsonb_build_object(
      'status','replayed','branch_id',v_existing.requested_branch_id,
      'branch_name',v_branch.name,'billing_state',v_branch.billing_state,
      'command_id',v_existing.id,'command_status',v_existing.status,
      'redirect_url',v_existing.redirect_url);
  end if;

  /* The v665 trigger decides billing_state (a second branch is pending_payment and off); the
     mode is this file's and is set here. */
  insert into public.branches(business_id,name,address,phone,email,active,is_default,billing_state,billing_mode)
  values (p_business,v_name,nullif(btrim(coalesce(p_address,'')),''),
          nullif(btrim(coalesce(p_phone,'')),''),nullif(btrim(coalesce(p_email,'')),''),
          false,false,'pending_payment','own')
  returning * into v_branch;
  if v_branch.billing_state = 'included' then
    /* The FIRST branch of a business is the company's own and is covered by the company plan. */
    perform set_config('app.branch_authority_v621','on',true);
    update public.branches set billing_mode = 'shared', active = true, updated_at = now() where id = v_branch.id;
    perform set_config('app.branch_authority_v621','off',true);
    return jsonb_build_object('status','ok','branch_id',v_branch.id,'branch_name',v_branch.name,
      'billing_state','included','billing_mode','shared','command_id',null);
  end if;

  if p_copy_from is not null then
    v_copied := public.business_copy_branch_settings_v202(p_business,p_copy_from,v_branch.id);
  end if;

  v_command := public.request_branch_billing_command_v786(
    p_business,v_branch.id,'create_checkout',v_cadence,p_idempotency_key);

  return jsonb_build_object(
    'status','ok','branch_id',v_branch.id,'branch_name',v_branch.name,
    'billing_state',v_branch.billing_state,'billing_mode','own','copied',v_copied,
    'command_type','create_checkout','cadence',v_cadence,
    'command_id',v_command->>'command_id','command_status',v_command->>'status');
end
$$;
revoke all on function public.business_add_branch_v786(uuid,text,text,text,text,uuid,text,uuid) from public, anon;
grant execute on function public.business_add_branch_v786(uuid,text,text,text,text,uuid,text,uuid) to authenticated, service_role;

-- =============================================================================================
-- 6 · Which branch an event names.
-- =============================================================================================
create or replace function app.razorpay_branch_v786(p_payload jsonb)
returns uuid
language plpgsql
stable security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_subscription jsonb := p_payload #> '{payload,subscription,entity}';
  v_payment jsonb := p_payload #> '{payload,payment,entity}';
  v_candidate text;
  v_subscription_id text;
  v_branch uuid;
begin
  v_candidate := coalesce(v_subscription #>> '{notes,branch_id}', v_payment #>> '{notes,branch_id}');
  if v_candidate ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'
     and exists (select 1 from public.branches b where b.id = v_candidate::uuid and b.billing_mode = 'own') then
    return v_candidate::uuid;
  end if;
  v_subscription_id := coalesce(v_subscription ->> 'id', v_payment ->> 'subscription_id');
  if v_subscription_id is not null then
    select s.branch_id into v_branch from public.branch_subscriptions_v786 s
     where s.provider_subscription_id = v_subscription_id;
    if found then return v_branch; end if;
  end if;
  return null;
end
$$;
revoke all on function app.razorpay_branch_v786(jsonb) from public, anon, authenticated;

-- =============================================================================================
-- 7 · The branch applier. Same mirrors, same guards; the tenant row is the branch's.
-- =============================================================================================
create or replace function app.apply_razorpay_branch_event_v786(
  p_event_id text, p_business uuid, p_branch uuid, p_rank smallint
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_event public.billing_provider_events%rowtype;
  v_subscription jsonb;
  v_payment jsonb;
  v_branch public.branches%rowtype;
  v_customer text;
  v_subscription_id text;
  v_plan text;
  v_quantity integer;
  v_status text;
  v_raw_status text;
  v_cadence text;
  v_cadence_months integer;
  v_period_start timestamptz;
  v_period_end timestamptz;
  v_charge_at timestamptz;
  v_ended_at timestamptz;
  v_cancel_at_period_end boolean;
  v_invoice text;
  v_amount integer;
  v_currency text;
  v_paid_at timestamptz;
  v_notes jsonb;
  v_reason text;
  v_detail jsonb;
  v_paid boolean := false;
  v_new_state text;
  v_new_active boolean;
  v_new_cancel_at timestamptz;
  v_result jsonb;
begin
  select * into v_event from public.billing_provider_events
   where provider = 'razorpay' and event_id = p_event_id;
  select * into v_branch from public.branches where id = p_branch and business_id = p_business;
  if v_branch.id is null then
    raise exception 'Razorpay branch event names a branch outside its business';
  end if;

  begin
    v_subscription := v_event.payload #> '{payload,subscription,entity}';
    v_payment := v_event.payload #> '{payload,payment,entity}';

    if jsonb_typeof(v_subscription) = 'object' then
      v_subscription_id := v_subscription ->> 'id';
      v_customer := v_subscription ->> 'customer_id';
      v_plan := v_subscription ->> 'plan_id';
      v_quantity := greatest(coalesce((v_subscription->>'quantity')::integer,1),0);
      v_raw_status := v_subscription->>'status';
      v_status := app.razorpay_status_v755(v_raw_status);
      v_period_start := app.razorpay_epoch_v755(v_subscription->'current_start');
      v_period_end := app.razorpay_epoch_v755(v_subscription->'current_end');
      v_charge_at := app.razorpay_epoch_v755(v_subscription->'charge_at');
      v_ended_at := app.razorpay_epoch_v755(v_subscription->'ended_at');
      v_cancel_at_period_end := (
        v_raw_status = 'cancelled' and v_ended_at is null
        and v_period_end is not null and v_period_end > now()
      ) or coalesce((v_subscription->>'has_scheduled_changes')::boolean,false);
      select plan.cadence, plan.cadence_months into v_cadence, v_cadence_months
        from app.razorpay_plan_cadence_v755(v_plan) plan;

      if exists(select 1 from public.billing_provider_subscriptions mirror
                 where mirror.provider_subscription_id = v_subscription_id
                   and mirror.business_id <> p_business) then
        raise exception 'Razorpay subscription is already linked to another business';
      end if;
      if exists(select 1 from public.branch_subscriptions_v786 other
                 where other.provider_subscription_id = v_subscription_id
                   and other.branch_id <> p_branch) then
        raise exception 'Razorpay subscription is already linked to another branch';
      end if;

      if v_customer is not null then
        insert into public.billing_provider_customers(
          business_id,provider,provider_customer_id,currency,livemode,provider_created_at,
          provider_event_created_at,provider_event_rank,last_event_id
        ) values (
          p_business,'razorpay',v_customer,'SGD',v_event.livemode,
          app.razorpay_epoch_v755(v_subscription->'created_at'),
          v_event.event_created_at,p_rank,v_event.event_id
        )
        on conflict(business_id) do update
          set provider_customer_id=excluded.provider_customer_id,
              provider=excluded.provider,
              provider_event_created_at=excluded.provider_event_created_at,
              provider_event_rank=excluded.provider_event_rank,
              last_event_id=excluded.last_event_id,updated_at=now()
        where (excluded.provider_event_created_at,excluded.provider_event_rank)
              >= (billing_provider_customers.provider_event_created_at,
                  billing_provider_customers.provider_event_rank);
      end if;

      insert into public.billing_provider_subscriptions(
        business_id,provider_customer_id,provider_subscription_id,status,
        cadence,cadence_months,currency,current_period_start,current_period_end,
        billing_cycle_anchor,trial_end,cancel_at_period_end,canceled_at,ended_at,
        livemode,provider_event_created_at,provider_event_rank,last_event_id
      ) values (
        p_business,coalesce(v_customer,v_subscription_id),v_subscription_id,v_status,
        v_cadence,v_cadence_months,'SGD',v_period_start,v_period_end,
        app.razorpay_epoch_v755(v_subscription->'start_at'),null,
        v_cancel_at_period_end,
        case when v_raw_status='cancelled' then v_event.event_created_at end,
        v_ended_at,v_event.livemode,v_event.event_created_at,p_rank,v_event.event_id
      )
      on conflict(provider_subscription_id) do update
        set status=excluded.status,cadence=excluded.cadence,
            cadence_months=excluded.cadence_months,currency=excluded.currency,
            current_period_start=excluded.current_period_start,
            current_period_end=excluded.current_period_end,
            billing_cycle_anchor=excluded.billing_cycle_anchor,
            cancel_at_period_end=excluded.cancel_at_period_end,
            canceled_at=excluded.canceled_at,ended_at=excluded.ended_at,
            provider_event_created_at=excluded.provider_event_created_at,
            provider_event_rank=excluded.provider_event_rank,
            last_event_id=excluded.last_event_id,updated_at=now()
      where (excluded.provider_event_created_at,excluded.provider_event_rank)
            >= (billing_provider_subscriptions.provider_event_created_at,
                billing_provider_subscriptions.provider_event_rank);

      if v_plan is not null then
        insert into public.billing_provider_subscription_items(
          provider_subscription_id,provider_item_id,item_role,provider_price_id,
          quantity,unit_amount_cents,currency,interval_name,interval_count,
          current_period_start,current_period_end,provider_event_created_at,
          provider_event_rank,last_event_id
        ) values (
          v_subscription_id,v_subscription_id,
          coalesce(nullif(app.stripe_item_role_v664(v_plan),'other'),'base'),
          v_plan,v_quantity,null,'SGD',
          case when v_cadence_months = 12 then 'year' else 'month' end,
          case when v_cadence_months = 12 then 1 else coalesce(v_cadence_months,1) end,
          v_period_start,v_period_end,v_event.event_created_at,p_rank,v_event.event_id
        )
        on conflict(provider_item_id) do update
          set item_role=excluded.item_role,provider_price_id=excluded.provider_price_id,
              quantity=excluded.quantity,currency=excluded.currency,
              interval_name=excluded.interval_name,interval_count=excluded.interval_count,
              current_period_start=excluded.current_period_start,
              current_period_end=excluded.current_period_end,
              provider_event_created_at=excluded.provider_event_created_at,
              provider_event_rank=excluded.provider_event_rank,
              last_event_id=excluded.last_event_id,updated_at=now()
          where (excluded.provider_event_created_at,excluded.provider_event_rank)
                >= (billing_provider_subscription_items.provider_event_created_at,
                    billing_provider_subscription_items.provider_event_rank);
      end if;

      /* The branch's own row: created by the first event that names it, moved forward only by a
         newer (created_at, rank) than the one it already holds. */
      insert into public.branch_subscriptions_v786(
        business_id,branch_id,provider_customer_id,provider_subscription_id,provider_plan_id,
        status,cadence,cadence_months,unit_amount_cents,current_period_start,current_period_end,
        next_payment_at,cancel_at_period_end,canceled_at,ended_at,livemode,
        provider_event_created_at,provider_event_rank,last_event_id
      ) values (
        p_business,p_branch,v_customer,v_subscription_id,v_plan,
        v_status,v_cadence,v_cadence_months,
        (select tier.amount_cents from public.billing_capacity_tier_catalog_v664 tier
          where tier.provider_base_price_id = v_plan limit 1),
        v_period_start,v_period_end,coalesce(v_charge_at,v_period_end),
        v_cancel_at_period_end,
        case when v_raw_status='cancelled' then v_event.event_created_at end,
        v_ended_at,v_event.livemode,v_event.event_created_at,p_rank,v_event.event_id
      )
      on conflict(branch_id) do update
        set provider_customer_id=coalesce(excluded.provider_customer_id,branch_subscriptions_v786.provider_customer_id),
            provider_subscription_id=excluded.provider_subscription_id,
            provider_plan_id=excluded.provider_plan_id,
            status=excluded.status,cadence=coalesce(excluded.cadence,branch_subscriptions_v786.cadence),
            cadence_months=coalesce(excluded.cadence_months,branch_subscriptions_v786.cadence_months),
            unit_amount_cents=coalesce(excluded.unit_amount_cents,branch_subscriptions_v786.unit_amount_cents),
            current_period_start=coalesce(excluded.current_period_start,branch_subscriptions_v786.current_period_start),
            current_period_end=coalesce(excluded.current_period_end,branch_subscriptions_v786.current_period_end),
            next_payment_at=coalesce(excluded.next_payment_at,branch_subscriptions_v786.next_payment_at),
            cancel_at_period_end=excluded.cancel_at_period_end,
            canceled_at=coalesce(excluded.canceled_at,branch_subscriptions_v786.canceled_at),
            ended_at=excluded.ended_at,livemode=excluded.livemode,
            provider_event_created_at=excluded.provider_event_created_at,
            provider_event_rank=excluded.provider_event_rank,
            last_event_id=excluded.last_event_id,updated_at=now()
      where branch_subscriptions_v786.provider_event_created_at is null
         or (excluded.provider_event_created_at,excluded.provider_event_rank)
            >= (branch_subscriptions_v786.provider_event_created_at,branch_subscriptions_v786.provider_event_rank);
    end if;

    -- paid truth
    if v_event.event_type = 'subscription.charged' and jsonb_typeof(v_payment) = 'object' then
      v_invoice := coalesce(nullif(v_payment->>'invoice_id',''),v_payment->>'id');
      v_notes := case when jsonb_typeof(v_payment->'notes') = 'object' then v_payment->'notes' else '{}'::jsonb end;
      v_reason := lower(nullif(btrim(coalesce(v_notes->>'reason','')),''));
      if v_reason is null or v_reason not in
         ('initial','renewal','branch_added','plan_changed','card_change','capacity_increase','other') then
        v_reason := case when exists(
          select 1 from public.billing_provider_invoices prior_invoice
           where prior_invoice.provider_subscription_id = v_subscription_id
             and prior_invoice.provider_invoice_id <> v_invoice
        ) then 'renewal' else 'initial' end;
      end if;
      v_detail := jsonb_strip_nulls(jsonb_build_object(
        'branch_id', p_branch::text,
        'branch_name', v_branch.name,
        'own_subscription', true,
        'covers_from', coalesce(nullif(btrim(coalesce(v_notes->>'covers_from','')),''),
          to_char(v_period_start at time zone 'Asia/Singapore','YYYY-MM-DD')),
        'covers_until', coalesce(nullif(btrim(coalesce(v_notes->>'covers_until','')),''),
          to_char(v_period_end at time zone 'Asia/Singapore','YYYY-MM-DD'))
      ));
      v_amount := greatest(coalesce((v_payment->>'amount')::integer,0),0);
      v_currency := upper(coalesce(nullif(v_payment->>'currency',''),'SGD'));
      v_paid_at := coalesce(app.razorpay_epoch_v755(v_payment->'created_at'),v_event.event_created_at);
      if exists(select 1 from public.billing_provider_invoices invoice_row
                 where invoice_row.provider_invoice_id=v_invoice and invoice_row.business_id<>p_business) then
        raise exception 'Razorpay payment is already linked to another business';
      end if;

      insert into public.billing_provider_invoices(
        business_id,provider_customer_id,provider_subscription_id,
        provider_invoice_id,provider_payment_intent_id,number,currency,
        collection_method,status,paid_normalized,subtotal_ex_tax_cents,tax_cents,
        total_cents,amount_due_cents,amount_paid_cents,amount_remaining_cents,
        net_cash_ex_tax_cents,period_start,period_end,paid_at,finalized_at,
        livemode,provider_event_created_at,provider_event_rank,last_event_id,reason,detail
      ) values (
        p_business,coalesce(v_customer,v_subscription_id),v_subscription_id,
        v_invoice,v_payment->>'id',v_invoice,v_currency,
        'charge_automatically','paid',true,v_amount,0,
        v_amount,v_amount,v_amount,0,
        v_amount,v_period_start,v_period_end,v_paid_at,v_paid_at,
        v_event.livemode,v_event.event_created_at,p_rank,v_event.event_id,v_reason,v_detail
      )
      on conflict(provider_invoice_id) do update
        set provider_payment_intent_id=coalesce(excluded.provider_payment_intent_id,billing_provider_invoices.provider_payment_intent_id),
            number=coalesce(excluded.number,billing_provider_invoices.number),
            status=excluded.status,paid_normalized=excluded.paid_normalized,
            subtotal_ex_tax_cents=excluded.subtotal_ex_tax_cents,tax_cents=excluded.tax_cents,
            total_cents=excluded.total_cents,amount_due_cents=excluded.amount_due_cents,
            amount_paid_cents=excluded.amount_paid_cents,amount_remaining_cents=excluded.amount_remaining_cents,
            net_cash_ex_tax_cents=excluded.net_cash_ex_tax_cents,
            period_start=excluded.period_start,period_end=excluded.period_end,
            paid_at=excluded.paid_at,finalized_at=excluded.finalized_at,
            reason=coalesce(excluded.reason,billing_provider_invoices.reason),
            detail=coalesce(excluded.detail,billing_provider_invoices.detail),
            provider_event_created_at=excluded.provider_event_created_at,
            provider_event_rank=excluded.provider_event_rank,
            last_event_id=excluded.last_event_id,updated_at=now()
      where (excluded.provider_event_created_at,excluded.provider_event_rank)
            >= (billing_provider_invoices.provider_event_created_at,billing_provider_invoices.provider_event_rank);

      insert into public.billing_payment_attempts(
        business_id,provider_invoice_id,source_event_id,provider_payment_intent_id,
        provider_charge_id,attempt_state,amount_cents,tax_cents,occurred_at,collection_method
      ) values (
        p_business,v_invoice,v_event.event_id,v_payment->>'id',v_payment->>'id',
        'paid',v_amount,0,v_event.event_created_at,'charge_automatically'
      ) on conflict(source_event_id) do nothing;

      update public.branch_subscriptions_v786 s
         set payment_status='paid',last_paid_at=v_paid_at,last_paid_invoice_id=v_invoice,
             payment_event_created_at=v_event.event_created_at,payment_event_rank=p_rank,
             payment_method_kind=case when lower(coalesce(v_payment->>'method',''))='card'
                                       and coalesce(v_payment->'card'->>'last4','') ~ '^[0-9]{4}$'
                                      then 'card' else s.payment_method_kind end,
             payment_method_brand=case when lower(coalesce(v_payment->>'method',''))='card'
                                        and coalesce(v_payment->'card'->>'last4','') ~ '^[0-9]{4}$'
                                       then nullif(v_payment->'card'->>'network','') else s.payment_method_brand end,
             payment_method_last4=case when lower(coalesce(v_payment->>'method',''))='card'
                                        and coalesce(v_payment->'card'->>'last4','') ~ '^[0-9]{4}$'
                                       then v_payment->'card'->>'last4' else s.payment_method_last4 end,
             payment_method_updated_at=case when lower(coalesce(v_payment->>'method',''))='card'
                                             and coalesce(v_payment->'card'->>'last4','') ~ '^[0-9]{4}$'
                                            then v_event.event_created_at else s.payment_method_updated_at end,
             payment_method_source_payment_id=case when lower(coalesce(v_payment->>'method',''))='card'
                                                    and coalesce(v_payment->'card'->>'last4','') ~ '^[0-9]{4}$'
                                                   then v_payment->>'id' else s.payment_method_source_payment_id end,
             updated_at=now()
       where s.branch_id=p_branch
         and (s.payment_event_created_at is null
              or (v_event.event_created_at,p_rank) >= (s.payment_event_created_at,s.payment_event_rank));
      v_paid := true;
    end if;

    if v_event.event_type in ('subscription.pending','subscription.halted') then
      update public.branch_subscriptions_v786 s
         set payment_status='failed',next_payment_at=coalesce(v_charge_at,s.next_payment_at),
             payment_event_created_at=v_event.event_created_at,payment_event_rank=p_rank,updated_at=now()
       where s.branch_id=p_branch
         and (s.payment_event_created_at is null
              or (v_event.event_created_at,p_rank) >= (s.payment_event_created_at,s.payment_event_rank));
    end if;

    -- What this event does to the BRANCH. Only newer events move it (same rank guard as the row).
    select * into v_branch from public.branches where id = p_branch;
    v_new_state := null;
    if v_paid then
      v_new_state := 'active'; v_new_active := true; v_new_cancel_at := null;
    elsif v_event.event_type = 'subscription.halted' then
      v_new_state := 'suspended'; v_new_active := false; v_new_cancel_at := null;
    elsif v_raw_status in ('cancelled','completed','expired') and v_subscription_id is not null then
      if v_raw_status = 'cancelled' and v_ended_at is null and v_period_end is not null and v_period_end > now()
         and v_branch.billing_state in ('active','pending_payment','canceling') then
        v_new_state := 'canceling'; v_new_active := v_branch.active; v_new_cancel_at := v_period_end;
      elsif v_branch.billing_state <> 'unsubscribed' and v_raw_status <> 'expired' then
        v_new_state := 'unsubscribed'; v_new_active := false; v_new_cancel_at := null;
      end if;
    end if;
    if v_new_state is not null and (v_new_state <> v_branch.billing_state or v_new_active <> v_branch.active) then
      perform set_config('app.branch_authority_v621','on',true);
      perform set_config('app.v79_system_transition','on',true);
      update public.branches
         set billing_state = v_new_state,
             billing_state_prior = case when v_new_state in ('suspended','canceling') then v_branch.billing_state else null end,
             billing_cancel_at = v_new_cancel_at,
             active = v_new_active,
             updated_at = now()
       where id = p_branch;
      perform set_config('app.branch_authority_v621','off',true);
      perform set_config('app.v79_system_transition','off',true);
      insert into public.audit_log(business_id,actor,action,entity,entity_id,detail)
      values (p_business,null,'BRANCH_SUBSCRIPTION_STATE_V786','branches',p_branch,
              jsonb_build_object('event_id',v_event.event_id,'event_type',v_event.event_type,
                                 'from',v_branch.billing_state,'to',v_new_state,'active',v_new_active,
                                 'provider_subscription_id',v_subscription_id));
    end if;

    insert into public.billing_evidence(business_id,evidence_type,entity_type,entity_id,content_sha256,external_reference)
    values (p_business,'provider_event','razorpay_event',v_event.event_id,v_event.payload_sha256,v_event.object_id)
    on conflict do nothing;

    update public.billing_provider_events
       set processing_status='processed',business_id=p_business,processed_at=now(),last_error=null
     where id=v_event.id;
    v_result := jsonb_build_object('event_id',p_event_id,'status','processed','business_id',p_business,
                                   'branch_id',p_branch,'scope','branch','paid',v_paid);
  exception when others then
    update public.billing_provider_events
       set processing_status='failed',last_error=left(sqlerrm,2000)
     where id=v_event.id;
    return jsonb_build_object('event_id',p_event_id,'status','failed','error',left(sqlerrm,500),'scope','branch');
  end;
  return v_result;
end
$$;
revoke all on function app.apply_razorpay_branch_event_v786(text,uuid,uuid,smallint) from public, anon, authenticated;

-- =============================================================================================
-- 8 · Lapse and restore for the SHARED model (what replaces the v620 lock).
-- =============================================================================================
create or replace function app.restore_lapsed_shared_branches_v786(p_business uuid, p_evidence text)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare v_branch record; v_restored integer := 0;
begin
  perform set_config('app.branch_authority_v621','on',true);
  perform set_config('app.v79_system_transition','on',true);
  for v_branch in
    select b.id, b.billing_state_prior from public.branches b
     where b.business_id = p_business and b.billing_mode = 'shared'
       and b.billing_state = 'suspended' and b.billing_state_prior in ('included','active')
       and exists (select 1 from public.audit_log a
                    where a.entity = 'branches' and a.entity_id = b.id
                      and a.action = 'BRANCH_OFF_PAYMENT_LAPSED_V786'
                      and a.created_at > coalesce(b.updated_at,now()) - interval '1 minute')
  loop
    update public.branches
       set billing_state = v_branch.billing_state_prior, billing_state_prior = null,
           active = true, updated_at = now()
     where id = v_branch.id;
    insert into public.audit_log(business_id,actor,action,entity,entity_id,detail)
    values (p_business,null,'BRANCH_ON_PAYMENT_RESTORED_V786','branches',v_branch.id,
            jsonb_build_object('evidence',p_evidence,'restored_state',v_branch.billing_state_prior));
    v_restored := v_restored + 1;
  end loop;
  perform set_config('app.branch_authority_v621','off',true);
  perform set_config('app.v79_system_transition','off',true);
  return jsonb_build_object('restored', v_restored);
end
$$;
revoke all on function app.restore_lapsed_shared_branches_v786(uuid,text) from public, anon, authenticated;

create or replace function app.sweep_lapsed_shared_branches_v786()
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare v_row record; v_off integer := 0;
begin
  perform set_config('app.branch_authority_v621','on',true);
  perform set_config('app.v79_system_transition','on',true);
  /* A company subscription the provider was collecting (paid at least once) whose paid period
     ended more than 14 days ago with no newer payment: its shared branches switch off. Demo firms
     and firms that never paid through the provider are never touched — nothing lapsed for them. */
  for v_row in
    select b.id, b.business_id, b.billing_state, b.name
      from public.branches b
      join public.subscriptions s on s.business_id = b.business_id
      join public.businesses biz on biz.id = b.business_id
     where b.billing_mode = 'shared' and b.billing_state in ('included','active') and b.active
       and not biz.is_demo
       and s.billing_provider = 'razorpay' and s.provider_subscription_id is not null
       and s.last_paid_at is not null
       and s.current_period_end is not null
       and s.current_period_end + interval '14 days' < now()
       and (s.payment_status <> 'paid' or s.current_period_end + interval '14 days' < now())
     limit 500
  loop
    update public.branches
       set billing_state = 'suspended', billing_state_prior = v_row.billing_state,
           billing_cancel_at = null, active = false, updated_at = now()
     where id = v_row.id;
    insert into public.audit_log(business_id,actor,action,entity,entity_id,detail)
    values (v_row.business_id,null,'BRANCH_OFF_PAYMENT_LAPSED_V786','branches',v_row.id,
            jsonb_build_object('branch_name',v_row.name,'prior_state',v_row.billing_state,
                               'why','company subscription unpaid 14 days past its period end'));
    v_off := v_off + 1;
  end loop;
  perform set_config('app.branch_authority_v621','off',true);
  perform set_config('app.v79_system_transition','off',true);
  return jsonb_build_object('switched_off', v_off);
end
$$;
revoke all on function app.sweep_lapsed_shared_branches_v786() from public, anon, authenticated;
/* pg_cron replaces a job that already carries this name, so a re-run does not need an unschedule
   (and the local harness's cron stub has no unschedule to call). */
select cron.schedule('nestly-v786-lapsed-branch-sweep','15 20 * * *',
  $$select app.sweep_lapsed_shared_branches_v786()$$);

-- =============================================================================================
-- 9 · Patches to live bodies (extract-and-diff, each needle asserted exactly once).
-- =============================================================================================
do $v786_patch$
declare
  v_body text;
  v_new text;
begin
  -- 9a · the applier hands a branch-named event to the branch applier.
  v_body := pg_get_functiondef('public.apply_razorpay_billing_event_v755(text)'::regprocedure);
  v_new := replace(v_body,
    $n$  v_paid boolean := false;
begin$n$,
    $n$  v_paid boolean := false;
  v_branch_v786 uuid;
begin$n$);
  v_new := replace(v_new,
    $n$    v_business := app.razorpay_business_v755(v_event.payload);
    if v_business is null then
      raise exception 'Razorpay event cannot be mapped to a business';
    end if;
$n$,
    $n$    v_business := app.razorpay_business_v755(v_event.payload);
    if v_business is null then
      raise exception 'Razorpay event cannot be mapped to a business';
    end if;
    /* v786: an event that names a branch belongs to that branch's own subscription. */
    v_branch_v786 := app.razorpay_branch_v786(v_event.payload);
    if v_branch_v786 is not null then
      return app.apply_razorpay_branch_event_v786(p_event_id, v_business, v_branch_v786, v_rank);
    end if;
$n$);
  v_new := replace(v_new,
    $n$      'branch_activation',
      app.activate_pending_branches_on_paid_v621(
        v_business,'razorpay-charged:'||p_event_id
      )
    );
  end if;
  return v_result;
end$n$,
    $n$      'branch_activation',
      app.activate_pending_branches_on_paid_v621(
        v_business,'razorpay-charged:'||p_event_id
      ),
      'lapsed_restore',
      app.restore_lapsed_shared_branches_v786(
        v_business,'razorpay-charged:'||p_event_id
      )
    );
  end if;
  return v_result;
end$n$);
  if v_new = v_body or position('v_branch_v786 := app.razorpay_branch_v786' in v_new) = 0
     or position('restore_lapsed_shared_branches_v786' in v_new) = 0 then
    raise exception 'v786: applier patch did not apply';
  end if;
  execute v_new;

  -- 9b · v621 activation counts and activates SHARED branches only.
  v_body := pg_get_functiondef('app.activate_pending_branches_on_paid_v621(uuid,text)'::regprocedure);
  v_new := replace(v_body,
    $n$   where b.business_id = p_business and b.billing_state = 'active';$n$,
    $n$   where b.business_id = p_business and b.billing_state = 'active' and b.billing_mode = 'shared';$n$);
  v_new := replace(v_new,
    $n$     where b.business_id = p_business and b.billing_state = 'pending_payment'$n$,
    $n$     where b.business_id = p_business and b.billing_state = 'pending_payment' and b.billing_mode = 'shared'$n$);
  if v_new = v_body then raise exception 'v786: v621 activation patch did not apply'; end if;
  execute v_new;

  -- 9c · the company summary counts SHARED billable branches only.
  v_body := pg_get_functiondef('public.get_business_billing_v758(uuid)'::regprocedure);
  v_new := replace(v_body,
    $n$count(*) filter (where branch.billing_state in ('pending_payment','active'))::integer,$n$,
    $n$count(*) filter (where branch.billing_state in ('pending_payment','active') and branch.billing_mode = 'shared')::integer,$n$);
  if v_new = v_body then raise exception 'v786: v758 summary patch did not apply'; end if;
  execute v_new;

  v_body := pg_get_functiondef('public.get_business_billing_v124(uuid)'::regprocedure);
  v_new := replace(v_body,
    $n$         and branch.billing_state in ('pending_payment','active')
    ),$n$,
    $n$         and branch.billing_state in ('pending_payment','active')
         and branch.billing_mode = 'shared'
    ),$n$);
  if v_new = v_body then raise exception 'v786: v124 billable count patch did not apply'; end if;
  execute v_new;
end
$v786_patch$;

-- =============================================================================================
-- 10 · Branch lifecycle RPCs — the v764 set, per branch.
-- =============================================================================================
create or replace function public.set_branch_renewal_intent_v786(p_business uuid, p_branch uuid, p_cancel boolean)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_actor uuid := auth.uid();
  v_sub public.branch_subscriptions_v786%rowtype;
  v_now timestamptz := now();
begin
  if v_actor is null or not (app.is_billing_owner_v620(p_business) or app.is_super_admin()) then
    raise exception 'active owner or super-admin access is required' using errcode = '42501';
  end if;
  if p_cancel is null then
    raise exception 'a renewal intent is required' using errcode = '22023';
  end if;
  select * into v_sub from public.branch_subscriptions_v786
   where branch_id = p_branch and business_id = p_business for update;
  if not found then
    raise exception 'this branch has no subscription of its own' using errcode = '22023';
  end if;
  if v_sub.renewal_cancel_sent_at is not null then
    raise exception 'the renewal cancel has already been sent and cannot be changed' using errcode = '22023';
  end if;
  if (p_cancel and v_sub.renewal_cancel_requested_at is not null)
     or (not p_cancel and v_sub.renewal_cancel_requested_at is null) then
    return jsonb_build_object('status','ok','branch_id',p_branch,'cancel_requested',p_cancel,'unchanged',true,
      'renewal_cancel_requested_at',v_sub.renewal_cancel_requested_at,'current_period_end',v_sub.current_period_end);
  end if;
  update public.branch_subscriptions_v786
     set renewal_cancel_requested_at = case when p_cancel then v_now else null end, updated_at = v_now
   where branch_id = p_branch returning * into v_sub;
  insert into public.audit_log(business_id,actor,action,entity,entity_id,detail)
  values (p_business,v_actor,
          case when p_cancel then 'BRANCH_RENEWAL_CANCEL_REQUESTED_V786' else 'BRANCH_RENEWAL_CANCEL_WITHDRAWN_V786' end,
          'branches',p_branch,
          jsonb_build_object('cancel_requested',p_cancel,'current_period_end',v_sub.current_period_end,
                             'provider_subscription_id',v_sub.provider_subscription_id));
  return jsonb_build_object('status','ok','branch_id',p_branch,'cancel_requested',p_cancel,'unchanged',false,
    'renewal_cancel_requested_at',v_sub.renewal_cancel_requested_at,'current_period_end',v_sub.current_period_end);
end
$$;
revoke all on function public.set_branch_renewal_intent_v786(uuid,uuid,boolean) from public, anon;
grant execute on function public.set_branch_renewal_intent_v786(uuid,uuid,boolean) to authenticated, service_role;

create or replace function public.mark_branch_renewal_cancel_sent_v786(p_branch uuid, p_provider_reference text default null)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare v_sub public.branch_subscriptions_v786%rowtype; v_now timestamptz := now();
begin
  if p_branch is null then
    raise exception 'a branch id is required' using errcode = '22023';
  end if;
  select * into v_sub from public.branch_subscriptions_v786 where branch_id = p_branch for update;
  if not found then
    raise exception 'branch subscription was not found' using errcode = '22023';
  end if;
  if v_sub.renewal_cancel_requested_at is null then
    raise exception 'this branch has no renewal cancel to send' using errcode = '22023';
  end if;
  if v_sub.renewal_cancel_sent_at is not null then
    return jsonb_build_object('status','ok','branch_id',p_branch,'unchanged',true,'renewal_cancel_sent_at',v_sub.renewal_cancel_sent_at);
  end if;
  update public.branch_subscriptions_v786
     set renewal_cancel_sent_at = v_now, cancel_at_period_end = true, updated_at = v_now
   where branch_id = p_branch returning * into v_sub;
  insert into public.audit_log(business_id,actor,action,entity,entity_id,detail)
  values (v_sub.business_id,null,'BRANCH_RENEWAL_CANCEL_SENT_V786','branches',p_branch,
          jsonb_build_object('renewal_cancel_requested_at',v_sub.renewal_cancel_requested_at,'renewal_cancel_sent_at',v_now,
                             'current_period_end',v_sub.current_period_end,'provider_subscription_id',v_sub.provider_subscription_id,
                             'provider_reference',nullif(btrim(coalesce(p_provider_reference,'')),'')));
  return jsonb_build_object('status','ok','branch_id',p_branch,'unchanged',false,'renewal_cancel_sent_at',v_now,
                            'current_period_end',v_sub.current_period_end);
end
$$;
revoke all on function public.mark_branch_renewal_cancel_sent_v786(uuid,text) from public, anon, authenticated;
grant execute on function public.mark_branch_renewal_cancel_sent_v786(uuid,text) to service_role;

/* The due list the nightly reconciler reads now carries BOTH kinds of intent; a branch row names
   its branch_id, a company row does not. The 48h window is unchanged. */
create or replace function public.list_due_renewal_cancels_v764()
returns jsonb
language plpgsql
stable security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare v_rows jsonb;
begin
  select coalesce(jsonb_agg(to_jsonb(due) order by due.current_period_end), '[]'::jsonb) into v_rows
    from (
      select s.business_id, null::uuid as branch_id, s.provider_subscription_id, s.billing_provider,
             s.current_period_end, s.renewal_cancel_requested_at
        from public.subscriptions s
       where s.renewal_cancel_requested_at is not null and s.renewal_cancel_sent_at is null
         and s.provider_subscription_id is not null and s.current_period_end is not null
         and s.current_period_end < now() + interval '48 hours'
         and coalesce(s.status,'') not in ('canceled','incomplete_expired')
      union all
      select b.business_id, b.branch_id, b.provider_subscription_id, b.provider as billing_provider,
             b.current_period_end, b.renewal_cancel_requested_at
        from public.branch_subscriptions_v786 b
       where b.renewal_cancel_requested_at is not null and b.renewal_cancel_sent_at is null
         and b.provider_subscription_id is not null and b.current_period_end is not null
         and b.current_period_end < now() + interval '48 hours'
         and coalesce(b.status,'') not in ('canceled','incomplete_expired')
    ) due;
  return jsonb_build_object('status','ok','due',v_rows);
end
$$;
revoke all on function public.list_due_renewal_cancels_v764() from public, anon, authenticated;
grant execute on function public.list_due_renewal_cancels_v764() to service_role;

create or replace function public.record_branch_billing_schedule_v786(
  p_branch uuid, p_target_cadence text, p_target_plan_id text, p_effective_at timestamptz, p_amount_cents integer
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare v_cadence text := lower(nullif(btrim(coalesce(p_target_cadence,'')),'')); v_sub public.branch_subscriptions_v786%rowtype;
begin
  if p_branch is null then raise exception 'a branch id is required' using errcode = '22023'; end if;
  if v_cadence is null or v_cadence not in ('monthly','annual') then
    raise exception 'a scheduled cadence must be monthly or annual' using errcode = '22023';
  end if;
  if p_effective_at is null then
    raise exception 'a scheduled change needs the date it takes effect' using errcode = '22023';
  end if;
  update public.branch_subscriptions_v786
     set scheduled_cadence = v_cadence, scheduled_plan_id = nullif(btrim(coalesce(p_target_plan_id,'')),''),
         scheduled_effective_at = p_effective_at, scheduled_amount_cents = p_amount_cents, updated_at = now()
   where branch_id = p_branch returning * into v_sub;
  if not found then raise exception 'branch subscription was not found' using errcode = '22023'; end if;
  insert into public.audit_log(business_id,actor,action,entity,entity_id,detail)
  values (v_sub.business_id,null,'BRANCH_BILLING_SCHEDULE_RECORDED_V786','branches',p_branch,
          jsonb_build_object('scheduled_cadence',v_cadence,'scheduled_plan_id',v_sub.scheduled_plan_id,
                             'scheduled_effective_at',p_effective_at,'scheduled_amount_cents',p_amount_cents));
  return jsonb_build_object('status','ok','branch_id',p_branch,'scheduled_cadence',v_cadence,
                            'scheduled_effective_at',p_effective_at,'scheduled_amount_cents',p_amount_cents);
end
$$;
revoke all on function public.record_branch_billing_schedule_v786(uuid,text,text,timestamptz,integer) from public, anon, authenticated;
grant execute on function public.record_branch_billing_schedule_v786(uuid,text,text,timestamptz,integer) to service_role;

create or replace function public.clear_branch_billing_schedule_v786(p_branch uuid, p_reason text default null)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare v_sub public.branch_subscriptions_v786%rowtype; v_had boolean;
begin
  if p_branch is null then raise exception 'a branch id is required' using errcode = '22023'; end if;
  select * into v_sub from public.branch_subscriptions_v786 where branch_id = p_branch for update;
  if not found then raise exception 'branch subscription was not found' using errcode = '22023'; end if;
  v_had := v_sub.scheduled_cadence is not null or v_sub.scheduled_effective_at is not null;
  update public.branch_subscriptions_v786
     set scheduled_cadence = null, scheduled_plan_id = null, scheduled_effective_at = null,
         scheduled_amount_cents = null, updated_at = now()
   where branch_id = p_branch;
  if v_had then
    insert into public.audit_log(business_id,actor,action,entity,entity_id,detail)
    values (v_sub.business_id,null,'BRANCH_BILLING_SCHEDULE_CLEARED_V786','branches',p_branch,
            jsonb_build_object('reason',nullif(btrim(coalesce(p_reason,'')),''),
                               'previous_scheduled_cadence',v_sub.scheduled_cadence,
                               'previous_scheduled_effective_at',v_sub.scheduled_effective_at));
  end if;
  return jsonb_build_object('status','ok','branch_id',p_branch,'cleared',v_had);
end
$$;
revoke all on function public.clear_branch_billing_schedule_v786(uuid,text) from public, anon, authenticated;
grant execute on function public.clear_branch_billing_schedule_v786(uuid,text) to service_role;

create or replace function public.set_branch_payment_method_v786(
  p_branch uuid, p_payment_id text, p_kind text, p_brand text, p_last4 text
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_kind text := lower(nullif(btrim(coalesce(p_kind,'')),''));
  v_last4 text := nullif(btrim(coalesce(p_last4,'')),'');
  v_brand text := nullif(btrim(coalesce(p_brand,'')),'');
  v_updated integer;
begin
  if p_branch is null then raise exception 'a branch id is required' using errcode = '22023'; end if;
  if v_kind is null or v_kind not in ('card','paynow','other') then
    raise exception 'payment method kind must be card, paynow or other' using errcode = '22023';
  end if;
  if (v_kind = 'card' and (v_last4 is null or v_last4 !~ '^[0-9]{4}$'))
     or (v_last4 is not null and v_last4 !~ '^[0-9]{4}$') then
    raise exception 'a card payment method needs exactly four digits' using errcode = '22023';
  end if;
  update public.branch_subscriptions_v786
     set payment_method_kind = v_kind, payment_method_brand = v_brand, payment_method_last4 = v_last4,
         payment_method_updated_at = now(),
         payment_method_source_payment_id = nullif(btrim(coalesce(p_payment_id,'')),''),
         updated_at = now()
   where branch_id = p_branch;
  get diagnostics v_updated = row_count;
  if v_updated = 0 then raise exception 'this branch has no subscription of its own' using errcode = '22023'; end if;
  return jsonb_build_object('status','ok','branch_id',p_branch,'kind',v_kind,'brand',v_brand,'last4',v_last4);
end
$$;
revoke all on function public.set_branch_payment_method_v786(uuid,text,text,text,text) from public, anon, authenticated;
grant execute on function public.set_branch_payment_method_v786(uuid,text,text,text,text) to service_role;

-- =============================================================================================
-- 11 · The page's read: the v758 payload plus every branch's own subscription and the flat price.
-- =============================================================================================
create or replace function public.get_business_billing_v786(p_business uuid)
returns jsonb
language plpgsql
stable security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_payload jsonb := public.get_business_billing_v758(p_business);
  v_branches jsonb;
  v_annual public.billing_capacity_tier_catalog_v664%rowtype := app.billing_flat_tier_v786('annual');
  v_monthly public.billing_capacity_tier_catalog_v664%rowtype := app.billing_flat_tier_v786('monthly');
begin
  select coalesce(jsonb_agg(jsonb_build_object(
           'branch_id', s.branch_id,
           'provider_subscription_id', s.provider_subscription_id,
           'status', s.status,
           'payment_status', s.payment_status,
           'cadence', s.cadence,
           'plan_label', case s.cadence when 'annual' then 'Annual' when 'monthly' then 'Monthly' else null end,
           'unit_amount_cents', s.unit_amount_cents,
           'current_period_start', s.current_period_start,
           'current_period_end', s.current_period_end,
           'renews_at', coalesce(s.next_payment_at, s.current_period_end),
           'last_paid_at', s.last_paid_at,
           'cancel_at_period_end', s.cancel_at_period_end,
           'renewal_cancel_requested_at', s.renewal_cancel_requested_at,
           'renewal_cancel_sent_at', s.renewal_cancel_sent_at,
           'renewal_cancel_final_after', case when s.renewal_cancel_requested_at is not null and s.current_period_end is not null
                                              then s.current_period_end - interval '48 hours' end,
           'scheduled_change', case when s.scheduled_cadence is not null then jsonb_build_object(
               'kind','cadence','cadence',s.scheduled_cadence,
               'plan_label', case s.scheduled_cadence when 'annual' then 'Annual' when 'monthly' then 'Monthly' end,
               'effective_at', s.scheduled_effective_at, 'amount_cents', s.scheduled_amount_cents) end,
           'payment_method', case when s.payment_method_kind is not null then jsonb_build_object(
               'kind', s.payment_method_kind, 'brand', s.payment_method_brand, 'last4', s.payment_method_last4,
               'updated_at', s.payment_method_updated_at) end,
           'state', case
             when s.status = 'canceled' then 'canceled'
             when s.status = 'unpaid' then 'unpaid'
             when s.renewal_cancel_requested_at is not null then 'canceling'
             when s.cancel_at_period_end then 'canceling'
             when s.payment_status = 'failed' then 'past_due'
             when s.status = 'active' and s.payment_status = 'paid' then 'active'
             else 'none' end
         ) order by s.created_at), '[]'::jsonb)
    into v_branches
    from public.branch_subscriptions_v786 s
   where s.business_id = p_business;
  return v_payload || jsonb_build_object(
    'branch_subscriptions', v_branches,
    'flat_price', jsonb_build_object(
      'annual_cents', v_annual.amount_cents, 'monthly_cents', v_monthly.amount_cents,
      'annual_available', v_annual.id is not null, 'monthly_available', v_monthly.id is not null)
  );
end
$$;
/* Restated from get_business_billing_v758's proacl: authenticated + service_role. */
revoke all on function public.get_business_billing_v786(uuid) from public, anon;
grant execute on function public.get_business_billing_v786(uuid) to authenticated, service_role;

comment on function public.get_business_billing_v786(uuid) is
  'v786: get_business_billing_v758 plus branch_subscriptions (one per own-billed branch) and the flat per-branch price.';

commit;
