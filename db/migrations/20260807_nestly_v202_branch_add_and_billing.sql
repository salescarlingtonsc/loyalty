-- NESTLY v202 — add a branch, bill it, and copy the main branch's settings.
--
-- Owner ruling 2026-08-07: an extra branch costs "same price $99/month billed annually
-- (same as normal)". That is not an add-on price — it is literally another unit of the
-- base plan (billing_plan_catalog_v124 annual, base_amount_cents = 118800/year). So a
-- branch is billed as BASE ITEM QUANTITY, not as a new Stripe price. Nothing in this
-- migration invents an amount; the catalogue stays the single source of price truth.
--
-- Grandfathering: every branch that exists today is stamped 'included'. A firm that
-- already runs three outlets is NOT retro-charged for them — charging for something the
-- owner already had, without asking, is not a thing we do. Only branches created through
-- business_add_branch_v202 from now on enter the paid path.

begin;

-- ---------------------------------------------------------------- branch billing state
alter table public.branches
  add column if not exists billing_state text not null default 'included';

do $$
begin
  if not exists (
    select 1 from pg_constraint where conname='branches_billing_state_ck'
  ) then
    alter table public.branches
      add constraint branches_billing_state_ck
      check (billing_state in ('included','pending_payment','active','suspended'));
  end if;
end$$;

comment on column public.branches.billing_state is
  'included = covered by the base plan or grandfathered; pending_payment = created but not '
  'paid for, never operational; active = paid; suspended = payment lapsed. Operational use '
  'requires app.branch_is_operational_v202().';

-- A branch you have not paid for must not be usable. This is the ONE predicate every
-- caller asks, so a future surface cannot accidentally invent a laxer rule.
create or replace function app.branch_is_operational_v202(p_branch uuid)
returns boolean
language sql
stable
security definer
set search_path = pg_catalog, public, app, pg_temp
as $$
  select coalesce((
    select b.active and b.billing_state in ('included','active')
      from public.branches b where b.id = p_branch
  ), false);
$$;

-- ---------------------------------------------------------- the branch a command pays for
alter table public.billing_commands
  add column if not exists requested_branch_id uuid references public.branches(id);

-- ------------------------------------------------------------------- copy branch settings
-- Copies the settings the owner selected (2026-08-07): opening hours, services, staff
-- assignments and live loyalty overrides. Products are deliberately absent — public.products
-- has no branch dimension, so a product is already available at every branch and there is
-- nothing to copy. Returns what it actually did rather than claiming success.
create or replace function public.business_copy_branch_settings_v202(
  p_business uuid, p_from uuid, p_to uuid
) returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public, app, pg_temp
as $$
declare
  v_hours integer := 0; v_breaks integer := 0; v_services integer := 0;
  v_staff integer := 0; v_loyalty integer := 0; v_live uuid;
begin
  if auth.uid() is null or not (app.is_salon_owner(p_business) or app.is_super_admin()) then
    raise exception 'owner access is required' using errcode='42501';
  end if;
  if p_from is null or p_to is null or p_from = p_to then
    raise exception 'a source and a different destination branch are required' using errcode='22023';
  end if;
  if not exists (select 1 from public.branches where id=p_from and business_id=p_business)
     or not exists (select 1 from public.branches where id=p_to and business_id=p_business) then
    raise exception 'both branches must belong to this business' using errcode='42501';
  end if;

  insert into public.branch_hours(business_id,branch_id,weekday,opens_at,closes_at)
  select p_business,p_to,h.weekday,h.opens_at,h.closes_at
    from public.branch_hours h
   where h.business_id=p_business and h.branch_id=p_from
     and not exists (
       select 1 from public.branch_hours e
        where e.business_id=p_business and e.branch_id=p_to and e.weekday=h.weekday
          and e.opens_at=h.opens_at and e.closes_at=h.closes_at);
  get diagnostics v_hours = row_count;

  insert into public.branch_breaks(business_id,branch_id,weekday,starts_at,ends_at)
  select p_business,p_to,b.weekday,b.starts_at,b.ends_at
    from public.branch_breaks b
   where b.business_id=p_business and b.branch_id=p_from
     and not exists (
       select 1 from public.branch_breaks e
        where e.business_id=p_business and e.branch_id=p_to and e.weekday=b.weekday
          and e.starts_at=b.starts_at and e.ends_at=b.ends_at);
  get diagnostics v_breaks = row_count;

  insert into public.service_branches(business_id,service_id,branch_id)
  select p_business,s.service_id,p_to from public.service_branches s
   where s.business_id=p_business and s.branch_id=p_from
  on conflict do nothing;
  get diagnostics v_services = row_count;

  -- Staff carry the module permissions that decide who can do what at a branch, and a
  -- branch with nobody assigned cannot take a single booking (v118/v119: missing hours and
  -- missing staff are closed, not open). Copying them is what makes the new branch work on
  -- day one; the owner removes whoever does not belong there.
  insert into public.staff_branches(business_id,staff_id,branch_id)
  select p_business,s.staff_id,p_to from public.staff_branches s
   where s.business_id=p_business and s.branch_id=p_from
  on conflict do nothing;
  get diagnostics v_staff = row_count;

  -- Only the LIVE configuration version. Copying an override into a historical published
  -- version would rewrite what a customer was already promised.
  select fcv.id into v_live from public.firm_config_versions fcv
   where fcv.business_id=p_business and fcv.status='published'
   order by fcv.published_at desc nulls last limit 1;
  if v_live is not null then
    insert into public.loyalty_branch_overrides(
      config_version_id,business_id,branch_id,active,earn_points_per_dollar,
      stamp_per_cents,expiry_mode,expiry_days)
    select o.config_version_id,p_business,p_to,o.active,o.earn_points_per_dollar,
           o.stamp_per_cents,o.expiry_mode,o.expiry_days
      from public.loyalty_branch_overrides o
     where o.business_id=p_business and o.branch_id=p_from
       and o.config_version_id=v_live
    on conflict do nothing;
    get diagnostics v_loyalty = row_count;
  end if;

  return jsonb_build_object(
    'status','ok','from_branch',p_from,'to_branch',p_to,
    'opening_hours',v_hours,'breaks',v_breaks,'services',v_services,
    'staff_assignments',v_staff,'loyalty_overrides',v_loyalty,
    'products_note','products are firm-wide and need no copy');
end
$$;

revoke all on function public.business_copy_branch_settings_v202(uuid,uuid,uuid) from public, anon;
grant execute on function public.business_copy_branch_settings_v202(uuid,uuid,uuid) to authenticated;

-- ------------------------------------------------------------------------- add a branch
-- Creates the branch UNPAID and NOT operational, copies the chosen settings, and returns
-- the billing command the caller sends to Stripe. The branch only becomes usable when the
-- webhook confirms payment (business_activate_paid_branches_v202 below).
create or replace function public.business_add_branch_v202(
  p_business uuid,
  p_name text,
  p_address text default null,
  p_phone text default null,
  p_email text default null,
  p_copy_from uuid default null,
  p_idempotency_key uuid default null
) returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public, app, pg_temp
as $$
declare
  v_actor uuid := auth.uid();
  v_branch public.branches%rowtype;
  v_existing public.billing_commands%rowtype;
  v_cadence text;
  v_capacity integer;
  v_subscription text;
  v_command_type text;
  v_command jsonb;
  v_copied jsonb := null;
  v_name text := nullif(btrim(coalesce(p_name,'')),'');
begin
  if v_actor is null or not (app.is_salon_owner(p_business) or app.is_super_admin()) then
    raise exception 'owner access is required' using errcode='42501';
  end if;
  if v_name is null then
    raise exception 'a branch name is required' using errcode='22023';
  end if;
  if p_idempotency_key is null then
    raise exception 'an idempotency key is required' using errcode='22023';
  end if;

  -- Replay: the same key returns the same branch and the same command, so a double-tap or
  -- a retry after a dropped response can never create a second branch or a second charge.
  select * into v_existing from public.billing_commands
   where business_id=p_business and idempotency_key=p_idempotency_key;
  if found then
    select * into v_branch from public.branches where id=v_existing.requested_branch_id;
    return jsonb_build_object(
      'status','replayed','branch_id',v_existing.requested_branch_id,
      'branch_name',v_branch.name,'billing_state',v_branch.billing_state,
      'command_id',v_existing.id,'command_status',v_existing.status,
      'redirect_url',v_existing.redirect_url);
  end if;

  -- A branch is another unit of the SAME plan, so how it gets paid for depends on whether
  -- the firm already has a Stripe subscription to add a unit to.
  --   live subscription -> change_branches, a quantity increase, prorated by Stripe
  --   trialing / none   -> create_checkout, which establishes the subscription INCLUDING
  --                        this branch, so a trialing firm is never dead-ended on a button
  --                        that can only error. Every business in production is trialing
  --                        today, so this is the common path, not the edge case.
  select s.billing_cadence, s.provider_subscription_id, t.customer_capacity
    into v_cadence, v_subscription, v_capacity
    from public.subscriptions s
    left join public.billing_subscription_terms_v124 t on t.business_id=s.business_id
   where s.business_id=p_business;

  -- Owner ruling 2026-08-07: "$99/month billed annually (same as normal)". Annual is the
  -- default when the firm has not chosen a cycle yet; the amount itself always comes from
  -- billing_plan_catalog_v124, never from here.
  v_cadence := coalesce(nullif(v_cadence,''),'annual');
  if v_capacity is null then
    select greatest(1000, ceil(count(*)::numeric/1000)::integer*1000)
      into v_capacity from public.clients where business_id=p_business;
  end if;
  v_command_type := case when nullif(v_subscription,'') is not null
                         then 'change_branches' else 'create_checkout' end;

  insert into public.branches(business_id,name,address,phone,email,active,is_default,billing_state)
  values (p_business,v_name,nullif(btrim(coalesce(p_address,'')),''),
          nullif(btrim(coalesce(p_phone,'')),''),nullif(btrim(coalesce(p_email,'')),''),
          false,false,'pending_payment')
  returning * into v_branch;

  if p_copy_from is not null then
    v_copied := public.business_copy_branch_settings_v202(p_business,p_copy_from,v_branch.id);
  end if;

  v_command := public.request_billing_command_v124(
    p_business,v_command_type,v_cadence,v_capacity,p_idempotency_key);

  update public.billing_commands
     set requested_branch_id=v_branch.id
   where id=(v_command->>'command_id')::uuid;

  return jsonb_build_object(
    'status','ok','branch_id',v_branch.id,'branch_name',v_branch.name,
    'billing_state',v_branch.billing_state,'copied',v_copied,
    'command_type',v_command_type,'cadence',v_cadence,
    'command_id',v_command->>'command_id','command_status',v_command->>'status');
end
$$;

revoke all on function public.business_add_branch_v202(uuid,text,text,text,text,uuid,uuid) from public, anon;
grant execute on function public.business_add_branch_v202(uuid,text,text,text,text,uuid,uuid) to authenticated;

-- --------------------------------------------------------- activation on confirmed payment
-- Called by the billing webhook once Stripe confirms. Deliberately NOT owner-callable: an
-- owner must not be able to flip their own branch to paid.
create or replace function public.business_activate_paid_branches_v202(
  p_business uuid, p_command uuid
) returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public, app, pg_temp
as $$
declare v_branch uuid; v_activated integer := 0;
begin
  if not app.is_super_admin() and auth.uid() is not null then
    raise exception 'payment confirmation is server-side only' using errcode='42501';
  end if;
  select requested_branch_id into v_branch from public.billing_commands
   where id=p_command and business_id=p_business;
  if v_branch is null then
    return jsonb_build_object('status','no_branch','activated',0);
  end if;
  update public.branches
     set billing_state='active', active=true, updated_at=now()
   where id=v_branch and business_id=p_business and billing_state='pending_payment';
  get diagnostics v_activated = row_count;
  return jsonb_build_object('status','ok','branch_id',v_branch,'activated',v_activated);
end
$$;

revoke all on function public.business_activate_paid_branches_v202(uuid,uuid) from public, anon, authenticated;

-- ------------------------------------------------- teach the dispatcher the new command
-- request_billing_command_v124 gains 'change_branches'. Everything else about it is
-- unchanged: same catalogue lookup, same fingerprint, same idempotency contract.
create or replace function public.request_billing_command_v124(
  p_business uuid, p_command_type text, p_cadence text,
  p_customer_capacity integer, p_idempotency_key uuid
) returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public, app, pg_temp
as $function$
declare
  v_actor uuid:=auth.uid();
  v_fingerprint text;
  v_command public.billing_commands%rowtype;
  v_current_customer_count integer;
  v_existing_capacity integer;
  v_catalog public.billing_plan_catalog_v124%rowtype;
begin
  if v_actor is null
     or not (app.is_salon_owner(p_business) or app.is_super_admin()) then
    raise exception 'active owner or super-admin access is required'
      using errcode='42501';
  end if;
  if p_command_type not in (
      'create_checkout','create_portal','change_cadence','change_capacity',
      'change_branches','cancel_at_period_end','resume'
    ) or p_idempotency_key is null then
    raise exception 'invalid billing command' using errcode='22023';
  end if;
  if p_command_type in ('create_checkout','change_cadence','change_capacity','change_branches') then
    if p_cadence not in ('monthly','annual')
       or p_customer_capacity < 1000
       or p_customer_capacity % 1000 <> 0 then
      raise exception 'canonical cadence and customer capacity are required'
        using errcode='22023';
    end if;
    select count(*)::integer into v_current_customer_count
      from public.clients client where client.business_id=p_business;
    if p_customer_capacity < greatest(1000,
         ceil(v_current_customer_count::numeric/1000)::integer*1000) then
      raise exception 'selected capacity is below the current customer count'
        using errcode='22023';
    end if;
    select * into v_catalog
      from public.billing_plan_catalog_v124 catalog
       where catalog.currency='SGD' and catalog.cadence=p_cadence
         and catalog.active and catalog.effective_from<=now()
         and (catalog.effective_to is null or catalog.effective_to>now())
       order by catalog.effective_from desc limit 1;
    if not found then
      raise exception 'active V124 Stripe price catalog entry was not found'
        using errcode='22023';
    end if;
    if p_command_type in ('change_cadence','change_capacity') then
      select terms.customer_capacity into v_existing_capacity
        from public.billing_subscription_terms_v124 terms
       where terms.business_id=p_business;
      if p_command_type='change_capacity' and (
           v_existing_capacity is null
           or p_customer_capacity<=v_existing_capacity
         ) then
        raise exception 'capacity changes must be an increase'
          using errcode='22023';
      elsif p_command_type='change_cadence'
            and v_existing_capacity is not null
            and p_customer_capacity<v_existing_capacity then
        raise exception 'billing-cycle changes cannot decrease customer capacity'
          using errcode='22023';
      end if;
    end if;
  elsif p_cadence is not null or p_customer_capacity is not null then
    raise exception 'cadence and capacity are not valid for this command'
      using errcode='22023';
  end if;

  v_fingerprint:=encode(extensions.digest(convert_to(
    p_business::text||E'\n'||p_command_type||E'\n'||coalesce(p_cadence,'')
    ||E'\n'||coalesce(p_customer_capacity::text,'')
    ||E'\nv124_customer_capacity','utf8'
  ),'sha256'),'hex');
  select * into v_command from public.billing_commands
   where business_id=p_business and command_type=p_command_type
     and idempotency_key=p_idempotency_key;
  if found then
    if v_command.request_fingerprint<>v_fingerprint then
      raise exception 'billing command idempotency key conflicts with another request'
        using errcode='22023';
    end if;
  else
    insert into public.billing_commands(
      business_id,command_type,requested_cadence,pricing_model,
      requested_customer_capacity,billing_catalog_id_v124,
      idempotency_key,request_fingerprint,requested_by
    ) values (
      p_business,p_command_type,p_cadence,'v124_customer_capacity',
      p_customer_capacity,v_catalog.id,p_idempotency_key,v_fingerprint,v_actor
    ) returning * into v_command;
  end if;
  return jsonb_build_object(
    'command_id',v_command.id,'status',v_command.status,
    'command_type',v_command.command_type,'cadence',v_command.requested_cadence,
    'requested_customer_capacity',v_command.requested_customer_capacity,
    'redirect_url',v_command.redirect_url,'requested_at',v_command.requested_at
  );
end
$function$;

-- --------------------------------------------------------------- what the owner can see
create or replace function public.business_list_branches_v202(p_business uuid)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public, app, pg_temp
as $$
declare v_rows jsonb;
begin
  if auth.uid() is null or not (app.is_salon_owner(p_business) or app.is_super_admin()) then
    raise exception 'owner access is required' using errcode='42501';
  end if;
  select coalesce(jsonb_agg(jsonb_build_object(
           'id',b.id,'name',b.name,'address',b.address,'phone',b.phone,
           'active',b.active,'is_default',b.is_default,
           'billing_state',b.billing_state,
           'operational',app.branch_is_operational_v202(b.id)
         ) order by b.is_default desc, b.name), '[]'::jsonb)
    into v_rows from public.branches b where b.business_id=p_business;
  return jsonb_build_object('status','ok','branches',v_rows);
end
$$;

revoke all on function public.business_list_branches_v202(uuid) from public, anon;
grant execute on function public.business_list_branches_v202(uuid) to authenticated;

commit;
