-- Peekaa V142 — merchant-owned Stripe Connect onboarding and exact PayNow POS attempts.
--
-- Separation of money authority:
--   * the platform Stripe account remains the authority for Peekaa SaaS subscriptions;
--   * each legal merchant binds one Stripe connected account for its own customer payments;
--   * a browser can request an attempt but can never supply the amount, provider account,
--     provider status, paid timestamp or sale result;
--   * only the Connect webhook service can turn a matching provider success into a sale.

begin;

create table public.merchant_payment_accounts_v142 (
  business_id uuid primary key references public.businesses(id) on delete restrict,
  provider text not null default 'stripe' check (provider = 'stripe'),
  provider_account_id text not null unique check (provider_account_id ~ '^acct_[A-Za-z0-9]+$'),
  livemode boolean not null,
  details_submitted boolean not null default false,
  charges_enabled boolean not null default false,
  payouts_enabled boolean not null default false,
  paynow_capability text not null default 'inactive'
    check (paynow_capability in ('inactive','pending','active','restricted','unavailable')),
  requirements_currently_due jsonb not null default '[]'::jsonb
    check (jsonb_typeof(requirements_currently_due) = 'array'),
  requirements_eventually_due jsonb not null default '[]'::jsonb
    check (jsonb_typeof(requirements_eventually_due) = 'array'),
  disabled_reason text,
  provider_event_created_at timestamptz,
  provider_event_id text,
  created_by uuid not null references auth.users(id) on delete restrict,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (disabled_reason is null or length(disabled_reason) <= 300)
);

create table public.merchant_payment_commands_v142 (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete restrict,
  actor uuid not null references auth.users(id) on delete restrict,
  action text not null check (action in ('create_onboarding_link','refresh_account')),
  livemode boolean not null,
  idempotency_key uuid not null,
  provider_idempotency_key text not null,
  status text not null default 'pending'
    check (status in ('pending','running','completed','recovery_required','failed')),
  provider_account_id text,
  failure_code text,
  started_at timestamptz,
  completed_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (business_id, actor, action, livemode, idempotency_key),
  check (provider_account_id is null or provider_account_id ~ '^acct_[A-Za-z0-9]+$'),
  check (failure_code is null or length(failure_code) <= 120)
);

create table public.pos_payment_attempts_v142 (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete restrict,
  branch_id uuid not null,
  client_id uuid not null,
  staff_id uuid not null,
  created_by uuid not null references auth.users(id) on delete restrict,
  evaluation_id uuid not null,
  provider text not null default 'stripe' check (provider = 'stripe'),
  provider_account_id text not null check (provider_account_id ~ '^acct_[A-Za-z0-9]+$'),
  provider_payment_intent_id text,
  livemode boolean not null,
  amount_cents integer not null check (amount_cents > 0),
  currency text not null check (currency = 'SGD'),
  status text not null default 'prepared'
    check (status in ('prepared','awaiting_payment','processing','succeeded','failed',
                      'canceled','expired','fulfilment_failed','refund_required','refund_pending',
                      'refund_failed','refunded')),
  idempotency_key uuid not null,
  provider_idempotency_key text not null unique,
  sale_id uuid,
  payment_reference text,
  provider_refund_id text,
  refund_failure_reason text,
  failure_code text,
  provider_event_created_at timestamptz,
  provider_event_id text,
  refund_event_created_at timestamptz,
  refund_event_id text,
  paid_at timestamptz,
  qr_activated_at timestamptz,
  expires_at timestamptz not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint pos_payment_attempt_business_idem_v142 unique (business_id, idempotency_key),
  constraint pos_payment_attempt_eval_v142 unique (evaluation_id),
  constraint pos_payment_attempt_branch_v142 foreign key (branch_id, business_id)
    references public.branches(id, business_id) on delete restrict,
  constraint pos_payment_attempt_client_v142 foreign key (client_id, business_id)
    references public.clients(id, business_id) on delete restrict,
  constraint pos_payment_attempt_staff_v142 foreign key (staff_id, business_id)
    references public.staff(id, business_id) on delete restrict,
  constraint pos_payment_attempt_eval_tenant_v142 foreign key (evaluation_id, business_id)
    references public.checkout_evaluations(id, business_id) on delete restrict,
  constraint pos_payment_attempt_sale_v142 foreign key (sale_id, business_id)
    references public.sales(id, business_id) on delete restrict,
  check (provider_payment_intent_id is null or provider_payment_intent_id ~ '^pi_[A-Za-z0-9]+$'),
  check (provider_refund_id is null or provider_refund_id ~ '^re_[A-Za-z0-9]+$'),
  check (payment_reference is null or length(payment_reference) <= 120),
  check (refund_failure_reason is null or length(refund_failure_reason) <= 300),
  check (failure_code is null or length(failure_code) <= 160),
  check ((status = 'succeeded') = (sale_id is not null)),
  check (status not in ('succeeded','refund_required','refund_pending','refund_failed','refunded') or paid_at is not null),
  check (paid_at is null or status in ('succeeded','fulfilment_failed','refund_required','refund_pending','refund_failed','refunded'))
);

create unique index pos_payment_attempt_provider_intent_v142
  on public.pos_payment_attempts_v142(provider_account_id, provider_payment_intent_id)
  where provider_payment_intent_id is not null;
create index pos_payment_attempt_status_v142
  on public.pos_payment_attempts_v142(business_id, status, created_at desc);

create table public.stripe_connect_event_inbox_v142 (
  event_id text primary key check (event_id ~ '^evt_[A-Za-z0-9]+$'),
  connected_account_id text not null check (connected_account_id ~ '^acct_[A-Za-z0-9]+$'),
  event_type text not null,
  object_id text not null,
  livemode boolean not null,
  event_created_at timestamptz not null,
  payload jsonb not null check (jsonb_typeof(payload) = 'object'),
  payload_sha256 text not null check (payload_sha256 ~ '^[0-9a-f]{64}$'),
  processing_status text not null default 'received'
    check (processing_status in ('received','processed','ignored','failed','refund_required',
                                 'refund_pending','refund_failed','refunded')),
  processing_result jsonb,
  received_at timestamptz not null default now(),
  processed_at timestamptz
);

alter table public.merchant_payment_accounts_v142 enable row level security;
alter table public.merchant_payment_commands_v142 enable row level security;
alter table public.pos_payment_attempts_v142 enable row level security;
alter table public.stripe_connect_event_inbox_v142 enable row level security;

revoke all on public.merchant_payment_accounts_v142 from public, anon, authenticated;
revoke all on public.merchant_payment_commands_v142 from public, anon, authenticated;
revoke all on public.pos_payment_attempts_v142 from public, anon, authenticated;
revoke all on public.stripe_connect_event_inbox_v142 from public, anon, authenticated;

create or replace function app.v142_service_guard()
returns void language plpgsql stable security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
begin
  if coalesce(auth.role(), '') <> 'service_role' then
    raise exception 'service role required' using errcode = '42501';
  end if;
end $$;
revoke all on function app.v142_service_guard() from public, anon, authenticated;
grant execute on function app.v142_service_guard() to service_role;

create or replace function app.v142_actor_is_owner(p_business uuid, p_actor uuid)
returns boolean language sql stable security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
  select exists (
    select 1 from public.staff s
     where s.business_id = p_business and s.user_id = p_actor
       and s.role = 'owner' and s.active
  )
$$;
revoke all on function app.v142_actor_is_owner(uuid,uuid) from public, anon, authenticated;
grant execute on function app.v142_actor_is_owner(uuid,uuid) to service_role;

-- Preserve checkout immutability while supporting one provider-owned lifecycle:
-- V142 may extend an unconsumed evaluation just long enough for Stripe's QR,
-- and once an attempt exists no other tab may consume that same evaluation.
create or replace function app.checkout_evaluations_guard()
returns trigger language plpgsql security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare v_reserved_attempt uuid;
begin
  if tg_op = 'DELETE' then
    raise exception 'checkout_evaluations rows are permanent' using errcode = 'restrict_violation';
  end if;
  if new.id is not distinct from old.id and new.business_id is not distinct from old.business_id
     and new.branch_id is not distinct from old.branch_id and new.client_id is not distinct from old.client_id
     and new.server_lines is not distinct from old.server_lines and new.cart_hash is not distinct from old.cart_hash
     and new.config_version_id is not distinct from old.config_version_id
     and new.applied_effects is not distinct from old.applied_effects
     and new.subtotal_cents is not distinct from old.subtotal_cents
     and new.discount_total_cents is not distinct from old.discount_total_cents
     and new.total_cents is not distinct from old.total_cents and new.gst_cents is not distinct from old.gst_cents
     and new.gst_rate_bps is not distinct from old.gst_rate_bps
     and new.created_at is not distinct from old.created_at
     and new.consumed_at is not distinct from old.consumed_at
     and new.consumed_sale_id is not distinct from old.consumed_sale_id
     and new.expires_at is distinct from old.expires_at then
    if coalesce(auth.role(),'')='service_role'
       and current_setting('app.v142_extend_checkout',true)='on'
       and old.consumed_at is null and new.expires_at>old.expires_at
       and new.expires_at<=clock_timestamp()+interval '61 minutes 5 seconds' then
      return new;
    end if;
    raise exception 'checkout evaluation expiry is immutable outside provider reservation'
      using errcode = 'restrict_violation';
  end if;
  if new.id is distinct from old.id or new.business_id is distinct from old.business_id
     or new.branch_id is distinct from old.branch_id or new.client_id is distinct from old.client_id
     or new.server_lines is distinct from old.server_lines or new.cart_hash is distinct from old.cart_hash
     or new.config_version_id is distinct from old.config_version_id
     or new.applied_effects is distinct from old.applied_effects
     or new.subtotal_cents is distinct from old.subtotal_cents
     or new.discount_total_cents is distinct from old.discount_total_cents
     or new.total_cents is distinct from old.total_cents or new.gst_cents is distinct from old.gst_cents
     or new.gst_rate_bps is distinct from old.gst_rate_bps or new.expires_at is distinct from old.expires_at
     or new.created_at is distinct from old.created_at then
    raise exception 'checkout evaluation identity and economics are immutable' using errcode = 'restrict_violation';
  end if;
  if old.consumed_at is null and new.consumed_at is not null then
    select a.id into v_reserved_attempt
      from public.pos_payment_attempts_v142 a
     where a.evaluation_id=old.id
       and a.status in ('prepared','awaiting_payment','processing','fulfilment_failed',
                        'refund_required','refund_pending','refund_failed')
     limit 1;
    if v_reserved_attempt is not null and not (
      coalesce(auth.role(),'')='service_role'
      and current_setting('app.v142_provider_finalize',true)=v_reserved_attempt::text
    ) then
      raise exception 'checkout evaluation is reserved for provider payment'
        using errcode = 'restrict_violation';
    end if;
  end if;
  if old.consumed_at is not null and new.consumed_at is distinct from old.consumed_at then
    raise exception 'checkout evaluation is already consumed (single-use)' using errcode = 'restrict_violation';
  end if;
  if old.consumed_sale_id is not null and new.consumed_sale_id is distinct from old.consumed_sale_id then
    raise exception 'checkout evaluation consumed_sale_id is write-once' using errcode = 'restrict_violation';
  end if;
  return new;
end $$;
revoke all on function app.checkout_evaluations_guard() from public, anon, authenticated;

create or replace function public.get_merchant_payment_status_v142(p_business uuid)
returns jsonb language plpgsql stable security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare v_account public.merchant_payment_accounts_v142%rowtype;
begin
  if auth.uid() is null or not exists (
    select 1 from public.staff s
     where s.business_id = p_business and s.user_id = auth.uid() and s.active
  ) then
    raise exception 'merchant payment status access denied' using errcode = '42501';
  end if;
  select * into v_account from public.merchant_payment_accounts_v142
   where business_id = p_business;
  if not found then
    return jsonb_build_object('business_id',p_business,'status','not_set_up',
      'paynow_ready',false,'requirements_due_count',0);
  end if;
  return jsonb_build_object(
    'business_id', p_business,
    'status', case
      when v_account.charges_enabled and v_account.payouts_enabled
       and v_account.details_submitted and v_account.paynow_capability = 'active' then 'ready'
      when v_account.disabled_reason is not null or v_account.paynow_capability = 'restricted' then 'restricted'
      else 'more_information_needed' end,
    'paynow_ready', v_account.charges_enabled and v_account.payouts_enabled
      and v_account.details_submitted and v_account.paynow_capability = 'active',
    'charges_enabled', v_account.charges_enabled,
    'payouts_enabled', v_account.payouts_enabled,
    'details_submitted', v_account.details_submitted,
    'paynow_capability', v_account.paynow_capability,
    'livemode', v_account.livemode,
    'requirements_due_count', jsonb_array_length(v_account.requirements_currently_due),
    'updated_at', v_account.updated_at
  );
end $$;
revoke all on function public.get_merchant_payment_status_v142(uuid) from public, anon, authenticated;
grant execute on function public.get_merchant_payment_status_v142(uuid) to authenticated;

create or replace function public.begin_merchant_connect_command_v142(
  p_business uuid, p_actor uuid, p_idempotency_key uuid, p_livemode boolean)
returns jsonb language plpgsql security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare v_command public.merchant_payment_commands_v142%rowtype;
        v_account public.merchant_payment_accounts_v142%rowtype;
        v_bound public.merchant_payment_accounts_v142%rowtype;
begin
  perform app.v142_service_guard();
  if not app.v142_actor_is_owner(p_business,p_actor) then
    raise exception 'only the active business owner can set up customer payments' using errcode = '42501';
  end if;
  perform pg_advisory_xact_lock(hashtextextended('v142-connect:'||p_business::text,0));
  select * into v_bound from public.merchant_payment_accounts_v142
   where business_id=p_business;
  if found and v_bound.livemode and not p_livemode then
    raise exception 'live merchant payment binding cannot be downgraded to test mode'
      using errcode='23505';
  end if;
  -- Stripe objects are isolated by mode. A test account must never be retrieved
  -- with a live key; a live setup starts a new, explicitly promoted binding.
  select * into v_account from public.merchant_payment_accounts_v142
   where business_id=p_business and livemode=p_livemode;
  insert into public.merchant_payment_commands_v142(
    business_id,actor,action,livemode,idempotency_key,provider_idempotency_key,status,provider_account_id,started_at)
  values(p_business,p_actor,'create_onboarding_link',p_livemode,p_idempotency_key,
    'peekaa-connect-'||case when p_livemode then 'live-' else 'test-' end||p_business::text,
    'running',v_account.provider_account_id,now())
  on conflict (business_id,actor,action,livemode,idempotency_key) do update
    set status=case when merchant_payment_commands_v142.status='completed' then 'completed' else 'running' end,
        started_at=coalesce(merchant_payment_commands_v142.started_at,now()),updated_at=now()
  returning * into v_command;
  return jsonb_build_object('command_id',v_command.id,'business_id',p_business,
    'status',v_command.status,'provider_idempotency_key',v_command.provider_idempotency_key,
    'provider_account_id',coalesce(v_account.provider_account_id,v_command.provider_account_id),
    'livemode',p_livemode);
end $$;
revoke all on function public.begin_merchant_connect_command_v142(uuid,uuid,uuid,boolean) from public, anon, authenticated;
grant execute on function public.begin_merchant_connect_command_v142(uuid,uuid,uuid,boolean) to service_role;

create or replace function public.complete_merchant_connect_command_v142(
  p_command uuid, p_account_id text, p_livemode boolean, p_details_submitted boolean,
  p_charges_enabled boolean, p_payouts_enabled boolean, p_paynow_capability text,
  p_currently_due jsonb, p_eventually_due jsonb, p_disabled_reason text)
returns jsonb language plpgsql security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare v_command public.merchant_payment_commands_v142%rowtype;
        v_existing public.merchant_payment_accounts_v142%rowtype;
begin
  perform app.v142_service_guard();
  select * into v_command from public.merchant_payment_commands_v142 where id=p_command for update;
  if not found then raise exception 'merchant payment command not found' using errcode='22023'; end if;
  if v_command.livemode is distinct from p_livemode then
    raise exception 'merchant account mode does not match setup command' using errcode='22023';
  end if;
  select * into v_existing from public.merchant_payment_accounts_v142
   where business_id=v_command.business_id;
  if found and (v_existing.provider_account_id is distinct from p_account_id
                or v_existing.livemode is distinct from p_livemode)
     and not (v_existing.livemode=false and p_livemode=true) then
    raise exception 'business payment account is already bound in this mode' using errcode='23505';
  end if;
  insert into public.merchant_payment_accounts_v142(
    business_id,provider_account_id,livemode,details_submitted,charges_enabled,payouts_enabled,
    paynow_capability,requirements_currently_due,requirements_eventually_due,disabled_reason,created_by)
  values(v_command.business_id,p_account_id,p_livemode,coalesce(p_details_submitted,false),
    coalesce(p_charges_enabled,false),coalesce(p_payouts_enabled,false),p_paynow_capability,
    coalesce(p_currently_due,'[]'::jsonb),coalesce(p_eventually_due,'[]'::jsonb),
    nullif(left(coalesce(p_disabled_reason,''),300),''),v_command.actor)
  on conflict (business_id) do update set
    provider_account_id=excluded.provider_account_id,livemode=excluded.livemode,
    details_submitted=excluded.details_submitted,
    charges_enabled=excluded.charges_enabled,payouts_enabled=excluded.payouts_enabled,
    paynow_capability=excluded.paynow_capability,
    requirements_currently_due=excluded.requirements_currently_due,
    requirements_eventually_due=excluded.requirements_eventually_due,
    disabled_reason=excluded.disabled_reason,updated_at=now();
  update public.merchant_payment_commands_v142 set status='completed',provider_account_id=p_account_id,
    completed_at=now(),updated_at=now(),failure_code=null where id=p_command;
  return jsonb_build_object('business_id',v_command.business_id,'status','completed');
end $$;
revoke all on function public.complete_merchant_connect_command_v142(uuid,text,boolean,boolean,boolean,boolean,text,jsonb,jsonb,text) from public, anon, authenticated;
grant execute on function public.complete_merchant_connect_command_v142(uuid,text,boolean,boolean,boolean,boolean,text,jsonb,jsonb,text) to service_role;

create or replace function public.sync_merchant_payment_account_v142(
  p_account_id text, p_livemode boolean, p_details_submitted boolean,
  p_charges_enabled boolean, p_payouts_enabled boolean, p_paynow_capability text,
  p_currently_due jsonb, p_eventually_due jsonb, p_disabled_reason text,
  p_event_id text default null, p_event_created_at timestamptz default null)
returns jsonb language plpgsql security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare v_business uuid;
begin
  perform app.v142_service_guard();
  update public.merchant_payment_accounts_v142 set
    livemode=p_livemode,details_submitted=coalesce(p_details_submitted,false),
    charges_enabled=coalesce(p_charges_enabled,false),payouts_enabled=coalesce(p_payouts_enabled,false),
    paynow_capability=p_paynow_capability,
    requirements_currently_due=coalesce(p_currently_due,'[]'::jsonb),
    requirements_eventually_due=coalesce(p_eventually_due,'[]'::jsonb),
    disabled_reason=nullif(left(coalesce(p_disabled_reason,''),300),''),
    provider_event_id=coalesce(p_event_id,provider_event_id),
    provider_event_created_at=coalesce(p_event_created_at,provider_event_created_at),updated_at=now()
  where provider_account_id=p_account_id
    and livemode=p_livemode
    and (p_event_created_at is null or provider_event_created_at is null or p_event_created_at>=provider_event_created_at)
  returning business_id into v_business;
  return jsonb_build_object('status',case when v_business is null then 'ignored' else 'updated' end,
    'business_id',v_business);
end $$;
revoke all on function public.sync_merchant_payment_account_v142(text,boolean,boolean,boolean,boolean,text,jsonb,jsonb,text,text,timestamptz) from public, anon, authenticated;
grant execute on function public.sync_merchant_payment_account_v142(text,boolean,boolean,boolean,boolean,text,jsonb,jsonb,text,text,timestamptz) to service_role;

create or replace function public.begin_pos_paynow_attempt_v142(
  p_business uuid, p_branch uuid, p_client uuid, p_staff uuid, p_evaluation uuid,
  p_actor uuid, p_idempotency_key uuid, p_livemode boolean)
returns jsonb language plpgsql security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare v_eval public.checkout_evaluations%rowtype;
        v_account public.merchant_payment_accounts_v142%rowtype;
        v_attempt public.pos_payment_attempts_v142%rowtype;
        v_paynow_expires_at timestamptz;
begin
  perform app.v142_service_guard();
  if not exists (select 1 from public.staff s where s.id=p_staff and s.business_id=p_business
    and s.user_id=p_actor and s.active) then
    raise exception 'active staff identity required' using errcode='42501';
  end if;
  perform set_config('request.jwt.claim.sub',p_actor::text,true);
  if not app.has_perm(p_business,'create_sales')
     or not app.can_module_write_at_v94(p_business,p_branch,'till')
     or not app.can_module_read_at_v94(p_business,p_branch,'clients') then
    raise exception 'Record sale access denied at this branch' using errcode='42501';
  end if;
  select * into v_attempt from public.pos_payment_attempts_v142
   where business_id=p_business and idempotency_key=p_idempotency_key;
  if found then
    if v_attempt.branch_id is distinct from p_branch or v_attempt.client_id is distinct from p_client
       or v_attempt.staff_id is distinct from p_staff
       or v_attempt.evaluation_id is distinct from p_evaluation
       or v_attempt.livemode is distinct from p_livemode then
      raise exception 'PayNow attempt key conflicts with another checkout' using errcode='22023';
    end if;
    return jsonb_build_object('attempt_id',v_attempt.id,'business_id',v_attempt.business_id,
      'provider_account_id',v_attempt.provider_account_id,'provider_payment_intent_id',v_attempt.provider_payment_intent_id,
      'provider_idempotency_key',v_attempt.provider_idempotency_key,'amount_cents',v_attempt.amount_cents,
      'currency',v_attempt.currency,'status',v_attempt.status,'expires_at',v_attempt.expires_at,
      'livemode',v_attempt.livemode);
  end if;
  -- If the browser lost its local retry key, the immutable checkout evaluation
  -- still identifies the one existing payment attempt. Recover it instead of
  -- minting another provider charge for the same cart.
  select * into v_attempt from public.pos_payment_attempts_v142
   where business_id=p_business and evaluation_id=p_evaluation;
  if found then
    if v_attempt.branch_id is distinct from p_branch or v_attempt.client_id is distinct from p_client
       or v_attempt.staff_id is distinct from p_staff or v_attempt.created_by is distinct from p_actor
       or v_attempt.livemode is distinct from p_livemode then
      raise exception 'checkout evaluation is already bound to another PayNow authority'
        using errcode='22023';
    end if;
    return jsonb_build_object('attempt_id',v_attempt.id,'business_id',v_attempt.business_id,
      'provider_account_id',v_attempt.provider_account_id,'provider_payment_intent_id',v_attempt.provider_payment_intent_id,
      'provider_idempotency_key',v_attempt.provider_idempotency_key,'amount_cents',v_attempt.amount_cents,
      'currency',v_attempt.currency,'status',v_attempt.status,'expires_at',v_attempt.expires_at,
      'livemode',v_attempt.livemode);
  end if;
  select * into v_eval from public.checkout_evaluations
   where id=p_evaluation and business_id=p_business for update;
  if not found or v_eval.branch_id is distinct from p_branch
     or v_eval.client_id is distinct from p_client or v_eval.consumed_at is not null
     or not exists (select 1 from public.checkout_evaluation_operations o
       where o.business_id=p_business and o.evaluation_id=p_evaluation and o.actor=p_actor) then
    raise exception 'checkout evaluation does not match this sale' using errcode='42501';
  end if;
  if v_eval.expires_at<=now() then
    raise exception 'checkout evaluation expired; check the total again' using errcode='P0001';
  end if;
  if v_eval.total_cents<=0 then
    raise exception 'PayNow requires a positive total' using errcode='22023';
  end if;
  if exists(select 1 from public.checkout_sv_tenders t where t.evaluation_id=v_eval.id and t.status='reserved') then
    raise exception 'remove stored value before creating a PayNow QR' using errcode='22023';
  end if;
  select * into v_account from public.merchant_payment_accounts_v142
   where business_id=p_business and livemode=p_livemode for share;
  if not found or not (v_account.details_submitted and v_account.charges_enabled
      and v_account.payouts_enabled and v_account.paynow_capability='active') then
    raise exception 'business PayNow setup is not ready' using errcode='P0001';
  end if;
  -- A Stripe PayNow QR remains payable for one hour. Reserve the original
  -- immutable evaluation and extend only its expiry to cover that provider
  -- window. There is never a second consumable checkout for the same cart.
  v_paynow_expires_at:=now()+interval '61 minutes';
  perform set_config('app.v142_extend_checkout','on',true);
  update public.checkout_evaluations set expires_at=v_paynow_expires_at where id=p_evaluation;
  perform set_config('app.v142_extend_checkout','off',true);
  insert into public.pos_payment_attempts_v142(
    business_id,branch_id,client_id,staff_id,created_by,evaluation_id,provider_account_id,
    livemode,amount_cents,currency,idempotency_key,provider_idempotency_key,expires_at)
  values(p_business,p_branch,p_client,p_staff,p_actor,p_evaluation,v_account.provider_account_id,
    v_account.livemode,v_eval.total_cents,'SGD',p_idempotency_key,
    'peekaa-pos-'||case when p_livemode then 'live-' else 'test-' end||p_business::text||'-'||p_idempotency_key::text,
    v_paynow_expires_at)
  on conflict (business_id,idempotency_key) do nothing returning * into v_attempt;
  if v_attempt.id is null then
    select * into v_attempt from public.pos_payment_attempts_v142
     where business_id=p_business and idempotency_key=p_idempotency_key;
    if v_attempt.branch_id is distinct from p_branch or v_attempt.client_id is distinct from p_client
       or v_attempt.staff_id is distinct from p_staff
       or v_attempt.evaluation_id is distinct from p_evaluation
       or v_attempt.livemode is distinct from p_livemode then
      raise exception 'PayNow attempt key conflicts with another checkout' using errcode='22023';
    end if;
  end if;
  return jsonb_build_object('attempt_id',v_attempt.id,'business_id',v_attempt.business_id,
    'provider_account_id',v_attempt.provider_account_id,'provider_payment_intent_id',v_attempt.provider_payment_intent_id,
    'provider_idempotency_key',v_attempt.provider_idempotency_key,'amount_cents',v_attempt.amount_cents,
    'currency',v_attempt.currency,'status',v_attempt.status,'expires_at',v_attempt.expires_at,
    'livemode',v_attempt.livemode);
end $$;
revoke all on function public.begin_pos_paynow_attempt_v142(uuid,uuid,uuid,uuid,uuid,uuid,uuid,boolean) from public, anon, authenticated;
grant execute on function public.begin_pos_paynow_attempt_v142(uuid,uuid,uuid,uuid,uuid,uuid,uuid,boolean) to service_role;

create or replace function public.attach_pos_paynow_intent_v142(
  p_attempt uuid, p_account_id text, p_payment_intent_id text, p_provider_status text)
returns jsonb language plpgsql security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare v_attempt public.pos_payment_attempts_v142%rowtype;
begin
  perform app.v142_service_guard();
  select * into v_attempt from public.pos_payment_attempts_v142 where id=p_attempt for update;
  if not found or v_attempt.provider_account_id is distinct from p_account_id then
    raise exception 'payment attempt account mismatch' using errcode='42501';
  end if;
  if v_attempt.provider_payment_intent_id is not null
     and v_attempt.provider_payment_intent_id is distinct from p_payment_intent_id then
    raise exception 'payment attempt is already bound to another provider intent' using errcode='23505';
  end if;
  update public.pos_payment_attempts_v142 set
    provider_payment_intent_id=p_payment_intent_id,
    status=case p_provider_status when 'processing' then 'processing'
      when 'succeeded' then status when 'canceled' then 'canceled'
      when 'requires_payment_method' then 'prepared'
      when 'requires_confirmation' then 'prepared' else 'awaiting_payment' end,
    updated_at=now()
  where id=p_attempt;
  return jsonb_build_object('status','bound','attempt_id',p_attempt);
end $$;
revoke all on function public.attach_pos_paynow_intent_v142(uuid,text,text,text) from public, anon, authenticated;
grant execute on function public.attach_pos_paynow_intent_v142(uuid,text,text,text) to service_role;

create or replace function public.activate_pos_paynow_qr_v142(
  p_attempt uuid, p_account_id text, p_payment_intent_id text)
returns jsonb language plpgsql security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare v_attempt public.pos_payment_attempts_v142%rowtype;
        v_qr_expires_at timestamptz;
begin
  perform app.v142_service_guard();
  select * into v_attempt from public.pos_payment_attempts_v142 where id=p_attempt for update;
  if not found or v_attempt.provider_account_id is distinct from p_account_id
     or v_attempt.provider_payment_intent_id is distinct from p_payment_intent_id then
    raise exception 'PayNow QR activation authority mismatch' using errcode='42501';
  end if;
  if v_attempt.status not in ('awaiting_payment','processing') then
    raise exception 'PayNow attempt cannot activate a QR in this state' using errcode='22023';
  end if;
  if v_attempt.qr_activated_at is null then
    v_qr_expires_at:=clock_timestamp()+interval '61 minutes';
    perform set_config('app.v142_extend_checkout','on',true);
    update public.checkout_evaluations set expires_at=v_qr_expires_at
     where id=v_attempt.evaluation_id and consumed_at is null;
    if not found then
      perform set_config('app.v142_extend_checkout','off',true);
      raise exception 'PayNow checkout is no longer available' using errcode='restrict_violation';
    end if;
    perform set_config('app.v142_extend_checkout','off',true);
    update public.pos_payment_attempts_v142 set qr_activated_at=clock_timestamp(),
      expires_at=v_qr_expires_at,updated_at=now() where id=v_attempt.id
      returning * into v_attempt;
  end if;
  return jsonb_build_object('attempt_id',v_attempt.id,'status',v_attempt.status,
    'qr_activated_at',v_attempt.qr_activated_at,'expires_at',v_attempt.expires_at);
end $$;
revoke all on function public.activate_pos_paynow_qr_v142(uuid,text,text) from public, anon, authenticated;
grant execute on function public.activate_pos_paynow_qr_v142(uuid,text,text) to service_role;

create or replace function public.get_pos_paynow_attempt_v142(p_attempt uuid)
returns jsonb language plpgsql stable security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare v_attempt public.pos_payment_attempts_v142%rowtype;
        v_eval public.checkout_evaluations%rowtype;
        v_client_name text; v_business_name text; v_branch_name text;
        v_points_earned int := 0; v_points_total int := 0; v_items jsonb := '[]'::jsonb;
begin
  select * into v_attempt from public.pos_payment_attempts_v142 where id=p_attempt;
  if not found or auth.uid() is null or not exists (
    select 1 from public.staff s where s.business_id=v_attempt.business_id
     and s.user_id=auth.uid() and s.active
  ) or not app.can_module_read_at_v94(v_attempt.business_id,v_attempt.branch_id,'clients')
    or not (app.can_module_read_at_v94(v_attempt.business_id,v_attempt.branch_id,'till')
         or app.can_module_read_at_v94(v_attempt.business_id,v_attempt.branch_id,'sales'))
  then raise exception 'payment attempt access denied' using errcode='42501'; end if;
  select * into v_eval from public.checkout_evaluations where id=v_attempt.evaluation_id;
  select full_name into v_client_name from public.clients where id=v_attempt.client_id;
  select name into v_business_name from public.businesses where id=v_attempt.business_id;
  select name into v_branch_name from public.branches where id=v_attempt.branch_id;
  if v_attempt.sale_id is not null then
    select coalesce(sum(points),0)::int into v_points_earned from public.points_ledger
     where business_id=v_attempt.business_id and sale_id=v_attempt.sale_id and entry_type='earn';
    select coalesce(sum(points),0)::int into v_points_total from public.points_ledger
     where business_id=v_attempt.business_id and client_id=v_attempt.client_id;
    select coalesce(jsonb_agg(jsonb_build_object('description',description,'qty',qty,
      'line_cents',line_cents,'item_type',item_type) order by created_at,id),'[]'::jsonb)
      into v_items from public.sale_items where business_id=v_attempt.business_id and sale_id=v_attempt.sale_id;
  end if;
  return jsonb_build_object('attempt_id',v_attempt.id,'business_id',v_attempt.business_id,
    'branch_id',v_attempt.branch_id,'amount_cents',v_attempt.amount_cents,'currency',v_attempt.currency,
    'status',case when v_attempt.status in ('prepared','awaiting_payment','processing')
                    and v_attempt.expires_at<=now() then 'expired' else v_attempt.status end,
    'sale_id',v_attempt.sale_id,'payment_reference',v_attempt.payment_reference,
    'provider_refund_id',v_attempt.provider_refund_id,
    'refund_failure_reason',v_attempt.refund_failure_reason,
    'paid_at',v_attempt.paid_at,'expires_at',v_attempt.expires_at,'updated_at',v_attempt.updated_at,
    'customer_name',v_client_name,'business_name',v_business_name,'branch_name',v_branch_name,
    'subtotal_cents',v_eval.subtotal_cents,'discount_total_cents',v_eval.discount_total_cents,
    'gst_cents',v_eval.gst_cents,'server_lines',v_eval.server_lines,'applied_effects',v_eval.applied_effects,
    'points_earned',v_points_earned,'points_total',v_points_total,'items',v_items);
end $$;
revoke all on function public.get_pos_paynow_attempt_v142(uuid) from public, anon, authenticated;
grant execute on function public.get_pos_paynow_attempt_v142(uuid) to authenticated;

create or replace function public.ingest_stripe_connect_event_v142(
  p_event_id text, p_connected_account_id text, p_event_type text, p_object_id text,
  p_livemode boolean, p_event_created_at timestamptz, p_payload jsonb, p_payload_sha256 text)
returns jsonb language plpgsql security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare v_existing public.stripe_connect_event_inbox_v142%rowtype;
        v_inserted boolean := false;
begin
  perform app.v142_service_guard();
  insert into public.stripe_connect_event_inbox_v142(
    event_id,connected_account_id,event_type,object_id,livemode,event_created_at,payload,payload_sha256)
  values(p_event_id,p_connected_account_id,p_event_type,p_object_id,p_livemode,p_event_created_at,p_payload,p_payload_sha256)
  on conflict(event_id) do nothing returning * into v_existing;
  v_inserted:=found;
  if not v_inserted then
    select * into v_existing from public.stripe_connect_event_inbox_v142 where event_id=p_event_id;
  end if;
  if v_existing.payload_sha256 is distinct from p_payload_sha256
     or v_existing.connected_account_id is distinct from p_connected_account_id then
    raise exception 'Stripe Connect event replay conflict' using errcode='22023';
  end if;
  return jsonb_build_object('event_id',p_event_id,'duplicate',not v_inserted);
end $$;
revoke all on function public.ingest_stripe_connect_event_v142(text,text,text,text,boolean,timestamptz,jsonb,text) from public, anon, authenticated;
grant execute on function public.ingest_stripe_connect_event_v142(text,text,text,text,boolean,timestamptz,jsonb,text) to service_role;

create or replace function public.apply_stripe_connect_payment_event_v142(p_event_id text)
returns jsonb language plpgsql security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare v_event public.stripe_connect_event_inbox_v142%rowtype;
        v_attempt public.pos_payment_attempts_v142%rowtype;
        v_object jsonb; v_result jsonb; v_sale uuid; v_previous_sub text;
        v_previous_finalize text;
        v_amount int; v_currency text; v_provider_status text;
begin
  perform app.v142_service_guard();
  select * into v_event from public.stripe_connect_event_inbox_v142 where event_id=p_event_id for update;
  if not found then raise exception 'Connect event not found' using errcode='22023'; end if;
  if v_event.processing_status in ('processed','ignored','refund_required','refund_pending','refund_failed','refunded') then
    return coalesce(v_event.processing_result,jsonb_build_object('status',v_event.processing_status));
  end if;
  if v_event.event_type='account.updated' then
    update public.stripe_connect_event_inbox_v142 set processing_status='ignored',processed_at=now(),
      processing_result=jsonb_build_object('status','account_event_requires_provider_refresh')
      where event_id=p_event_id;
    return jsonb_build_object('status','account_event_requires_provider_refresh');
  end if;
  if v_event.event_type not in ('payment_intent.processing','payment_intent.succeeded',
      'payment_intent.payment_failed','payment_intent.canceled') then
    update public.stripe_connect_event_inbox_v142 set processing_status='ignored',processed_at=now(),
      processing_result=jsonb_build_object('status','ignored_event_type') where event_id=p_event_id;
    return jsonb_build_object('status','ignored_event_type');
  end if;
  v_object:=v_event.payload#>'{data,object}';
  v_amount:=coalesce((v_object->>'amount')::int,0);
  v_currency:=upper(coalesce(v_object->>'currency',''));
  v_provider_status:=coalesce(v_object->>'status','');
  select * into v_attempt from public.pos_payment_attempts_v142
   where provider_account_id=v_event.connected_account_id
     and provider_payment_intent_id=v_event.object_id for update;
  if not found then
    update public.stripe_connect_event_inbox_v142 set processing_status='ignored',processed_at=now(),
      processing_result=jsonb_build_object('status','unknown_payment_intent') where event_id=p_event_id;
    return jsonb_build_object('status','unknown_payment_intent');
  end if;
  if v_attempt.livemode is distinct from v_event.livemode
     or v_amount is distinct from v_attempt.amount_cents or v_currency is distinct from v_attempt.currency
     or coalesce(v_object#>>'{metadata,peekaa_pos_attempt_id}','') is distinct from v_attempt.id::text
     or coalesce(v_object#>>'{metadata,peekaa_business_id}','') is distinct from v_attempt.business_id::text then
    v_result:=case when v_event.event_type='payment_intent.succeeded' and v_provider_status='succeeded'
      then jsonb_build_object('status','refund_required','attempt_id',v_attempt.id,
        'provider_account_id',v_attempt.provider_account_id,'payment_intent_id',v_attempt.provider_payment_intent_id)
      else jsonb_build_object('status','provider_envelope_mismatch','attempt_id',v_attempt.id) end;
    update public.pos_payment_attempts_v142 set
      status=case when v_event.event_type='payment_intent.succeeded' and v_provider_status='succeeded'
        then 'refund_required' else 'fulfilment_failed' end,
      failure_code='provider_envelope_mismatch',
      paid_at=case when v_event.event_type='payment_intent.succeeded' then v_event.event_created_at else paid_at end,
      provider_event_created_at=v_event.event_created_at,provider_event_id=v_event.event_id,updated_at=now()
     where id=v_attempt.id;
    update public.stripe_connect_event_inbox_v142 set
      processing_status=case when v_event.event_type='payment_intent.succeeded' and v_provider_status='succeeded'
        then 'refund_required' else 'failed' end,processed_at=now(),
      processing_result=v_result
     where event_id=p_event_id;
    return v_result;
  end if;
  if v_attempt.status in ('succeeded','refund_required','refund_pending','refund_failed','refunded') then
    v_result:=jsonb_build_object('status',case when v_attempt.status='succeeded' then 'duplicate_ignored'
      else v_attempt.status end,'attempt_id',v_attempt.id,'sale_id',v_attempt.sale_id,
      'refund_id',v_attempt.provider_refund_id);
    update public.stripe_connect_event_inbox_v142 set processing_status='processed',processed_at=now(),processing_result=v_result
     where event_id=p_event_id;
    return v_result;
  end if;
  if v_attempt.provider_event_created_at is not null
     and v_event.event_created_at<v_attempt.provider_event_created_at then
    v_result:=jsonb_build_object('status','stale_event_ignored','attempt_id',v_attempt.id);
    update public.stripe_connect_event_inbox_v142 set processing_status='ignored',processed_at=now(),processing_result=v_result
     where event_id=p_event_id;
    return v_result;
  end if;
  if v_event.event_type='payment_intent.succeeded' and v_provider_status='succeeded' then
    if v_event.event_created_at>v_attempt.expires_at then
      update public.pos_payment_attempts_v142 set status='refund_required',paid_at=v_event.event_created_at,
        failure_code='checkout_evaluation_expired',provider_event_created_at=v_event.event_created_at,
        provider_event_id=v_event.event_id,updated_at=now() where id=v_attempt.id;
      v_result:=jsonb_build_object('status','refund_required','attempt_id',v_attempt.id,
        'provider_account_id',v_attempt.provider_account_id,'payment_intent_id',v_attempt.provider_payment_intent_id);
      update public.stripe_connect_event_inbox_v142 set processing_status='refund_required',processed_at=now(),processing_result=v_result
       where event_id=p_event_id;
      return v_result;
    end if;
    v_previous_sub:=current_setting('request.jwt.claim.sub',true);
    v_previous_finalize:=current_setting('app.v142_provider_finalize',true);
    perform set_config('request.jwt.claim.sub',v_attempt.created_by::text,true);
    perform set_config('app.v142_provider_finalize',v_attempt.id::text,true);
    begin
      v_result:=public.record_cart_sale(v_attempt.business_id,v_attempt.client_id,v_attempt.branch_id,
        v_attempt.staff_id,'paynow','v142-pos-'||v_attempt.id::text,null,v_attempt.evaluation_id,true)::jsonb;
    exception when others then
      perform set_config('request.jwt.claim.sub',coalesce(v_previous_sub,''),true);
      perform set_config('app.v142_provider_finalize',coalesce(v_previous_finalize,''),true);
      update public.pos_payment_attempts_v142 set status='refund_required',paid_at=v_event.event_created_at,
        failure_code=left('sale_finalise:'||sqlstate,160),provider_event_created_at=v_event.event_created_at,
        provider_event_id=v_event.event_id,updated_at=now() where id=v_attempt.id;
      v_result:=jsonb_build_object('status','refund_required','attempt_id',v_attempt.id,
        'provider_account_id',v_attempt.provider_account_id,'payment_intent_id',v_attempt.provider_payment_intent_id);
      update public.stripe_connect_event_inbox_v142 set processing_status='refund_required',processed_at=now(),processing_result=v_result
       where event_id=p_event_id;
      return v_result;
    end;
    perform set_config('request.jwt.claim.sub',coalesce(v_previous_sub,''),true);
    perform set_config('app.v142_provider_finalize',coalesce(v_previous_finalize,''),true);
    v_sale:=nullif(v_result->>'sale_id','')::uuid;
    update public.pos_payment_attempts_v142 set status='succeeded',sale_id=v_sale,
      payment_reference=left(v_attempt.provider_payment_intent_id,120),paid_at=v_event.event_created_at,
      failure_code=null,provider_event_created_at=v_event.event_created_at,provider_event_id=v_event.event_id,updated_at=now()
     where id=v_attempt.id;
    v_result:=jsonb_build_object('status','succeeded','attempt_id',v_attempt.id,'sale_id',v_sale,
      'payment_reference',v_attempt.provider_payment_intent_id);
    update public.stripe_connect_event_inbox_v142 set processing_status='processed',processed_at=now(),processing_result=v_result
     where event_id=p_event_id;
    return v_result;
  end if;
  update public.pos_payment_attempts_v142 set status=case v_event.event_type
      when 'payment_intent.processing' then 'processing'
      when 'payment_intent.canceled' then 'canceled' else 'failed' end,
    failure_code=case when v_event.event_type='payment_intent.payment_failed'
      then left(coalesce(v_object#>>'{last_payment_error,code}','payment_failed'),160) else null end,
    provider_event_created_at=v_event.event_created_at,provider_event_id=v_event.event_id,updated_at=now()
   where id=v_attempt.id;
  v_result:=jsonb_build_object('status',case v_event.event_type
      when 'payment_intent.processing' then 'processing'
      when 'payment_intent.canceled' then 'canceled' else 'failed' end,'attempt_id',v_attempt.id);
  update public.stripe_connect_event_inbox_v142 set processing_status='processed',processed_at=now(),processing_result=v_result
   where event_id=p_event_id;
  return v_result;
end $$;
revoke all on function public.apply_stripe_connect_payment_event_v142(text) from public, anon, authenticated;
grant execute on function public.apply_stripe_connect_payment_event_v142(text) to service_role;

create or replace function public.mark_pos_paynow_refund_state_v142(
  p_attempt uuid, p_event_id text, p_refund_id text, p_provider_status text,
  p_failure_reason text default null)
returns jsonb language plpgsql security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare v_attempt public.pos_payment_attempts_v142%rowtype;
        v_status text;
        v_signed_event boolean;
begin
  perform app.v142_service_guard();
  if p_provider_status not in ('pending','requires_action','succeeded','failed','canceled') then
    raise exception 'unsupported Stripe refund state' using errcode='22023';
  end if;
  select * into v_attempt from public.pos_payment_attempts_v142 where id=p_attempt for update;
  if not found or v_attempt.status not in
      ('refund_required','refund_pending','refund_failed','refunded') then
    raise exception 'payment attempt is not awaiting a refund' using errcode='22023';
  end if;
  if v_attempt.provider_refund_id is not null
     and v_attempt.provider_refund_id is distinct from p_refund_id then
    raise exception 'payment attempt is already bound to another refund' using errcode='23505';
  end if;
  v_signed_event:=current_setting('app.v142_signed_refund_event',true)=p_event_id;
  -- Direct refunds.create responses are requests, not terminal truth. Once any
  -- signed event has been projected, a delayed API response is a strict no-op.
  if not v_signed_event and v_attempt.refund_event_id is not null then
    return jsonb_build_object('status',v_attempt.status,'attempt_id',p_attempt,
      'refund_id',v_attempt.provider_refund_id,'signed_event_preserved',true);
  end if;
  v_status:=case when not v_signed_event then 'refund_pending'
    when p_provider_status='succeeded' then 'refunded'
    when p_provider_status in ('failed','canceled') then 'refund_failed'
    else 'refund_pending' end;
  update public.pos_payment_attempts_v142 set status=v_status,
    provider_refund_id=p_refund_id,
    failure_code=case when v_status='refund_failed' then 'refund_failed'
                      when v_status='refunded' then null else failure_code end,
    refund_failure_reason=case when v_status='refund_failed'
      then left(coalesce(nullif(p_failure_reason,''),'Stripe reported that the refund failed'),300)
      when v_status='refunded' then null else refund_failure_reason end,
    updated_at=now() where id=p_attempt;
  update public.stripe_connect_event_inbox_v142 set processing_status=v_status,
    processing_result=coalesce(processing_result,'{}'::jsonb)||jsonb_build_object(
      'status',v_status,'attempt_id',p_attempt,'refund_id',p_refund_id,
      'provider_refund_status',p_provider_status),
    processed_at=now() where event_id=p_event_id;
  return jsonb_build_object('status',v_status,'attempt_id',p_attempt,'refund_id',p_refund_id);
end $$;
revoke all on function public.mark_pos_paynow_refund_state_v142(uuid,text,text,text,text) from public, anon, authenticated;
grant execute on function public.mark_pos_paynow_refund_state_v142(uuid,text,text,text,text) to service_role;

create or replace function public.apply_stripe_connect_refund_event_v142(p_event_id text)
returns jsonb language plpgsql security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare v_event public.stripe_connect_event_inbox_v142%rowtype;
        v_attempt public.pos_payment_attempts_v142%rowtype;
        v_object jsonb; v_status text; v_failure text; v_result jsonb;
        v_amount int; v_currency text; v_attempt_id uuid; v_payment_intent text;
        v_previous_signed_event text;
begin
  perform app.v142_service_guard();
  select * into v_event from public.stripe_connect_event_inbox_v142 where event_id=p_event_id for update;
  if not found then raise exception 'Connect event not found' using errcode='22023'; end if;
  if v_event.processing_status in ('refunded','refund_failed') then
    return coalesce(v_event.processing_result,jsonb_build_object('status',v_event.processing_status));
  end if;
  if v_event.event_type not in ('refund.updated','refund.failed') then
    raise exception 'event is not a refund state event' using errcode='22023';
  end if;
  v_object:=v_event.payload#>'{data,object}';
  begin v_attempt_id:=nullif(v_object#>>'{metadata,peekaa_pos_attempt_id}','')::uuid;
  exception when others then v_attempt_id:=null; end;
  v_payment_intent:=coalesce(v_object->>'payment_intent','');
  v_amount:=coalesce((v_object->>'amount')::int,0);
  v_currency:=upper(coalesce(v_object->>'currency',''));
  v_status:=case when v_event.event_type='refund.failed' then 'failed'
                 else coalesce(v_object->>'status','') end;
  v_failure:=coalesce(v_object#>>'{failure_reason}',v_object#>>'{failure_balance_transaction}');
  select * into v_attempt from public.pos_payment_attempts_v142
   where id=v_attempt_id and provider_account_id=v_event.connected_account_id
     and provider_payment_intent_id=v_payment_intent for update;
  if not found or v_attempt.livemode is distinct from v_event.livemode
     or v_amount is distinct from v_attempt.amount_cents
     or v_currency is distinct from v_attempt.currency
     or (v_attempt.provider_refund_id is not null
         and v_attempt.provider_refund_id is distinct from v_event.object_id) then
    update public.stripe_connect_event_inbox_v142 set processing_status='failed',processed_at=now(),
      processing_result=jsonb_build_object('status','refund_envelope_mismatch') where event_id=p_event_id;
    return jsonb_build_object('status','refund_envelope_mismatch');
  end if;
  if v_attempt.refund_event_created_at is not null
     and v_event.event_created_at<v_attempt.refund_event_created_at then
    update public.stripe_connect_event_inbox_v142 set processing_status='ignored',processed_at=now(),
      processing_result=jsonb_build_object('status','stale_refund_event_ignored','attempt_id',v_attempt.id)
     where event_id=p_event_id;
    return jsonb_build_object('status','stale_refund_event_ignored','attempt_id',v_attempt.id);
  end if;
  v_previous_signed_event:=current_setting('app.v142_signed_refund_event',true);
  perform set_config('app.v142_signed_refund_event',p_event_id,true);
  begin
    v_result:=public.mark_pos_paynow_refund_state_v142(v_attempt.id,p_event_id,v_event.object_id,
      v_status,v_failure);
  exception when others then
    perform set_config('app.v142_signed_refund_event',coalesce(v_previous_signed_event,''),true);
    raise;
  end;
  perform set_config('app.v142_signed_refund_event',coalesce(v_previous_signed_event,''),true);
  update public.pos_payment_attempts_v142 set refund_event_created_at=v_event.event_created_at,
    refund_event_id=v_event.event_id where id=v_attempt.id;
  return v_result;
end $$;
revoke all on function public.apply_stripe_connect_refund_event_v142(text) from public, anon, authenticated;
grant execute on function public.apply_stripe_connect_refund_event_v142(text) to service_role;

-- No browser table grants were introduced. The only authenticated outputs are
-- bounded status projections; all provider identifiers and event payloads remain private.

commit;
