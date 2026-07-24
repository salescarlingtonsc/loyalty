-- FRENLY v66 - PS-2 LIVE INCREMENT: STAFF-ASSISTED TOP-UP SALE + TILL (DB layer)
--
-- Implements directive §3 + the owner's mandatory v66 safety contract + the 11 corrections. Pinned
-- contract: docs/design/ps2/PS2_LIVE_V66_TOPUP_SALE_CONTRACT.md (rev 3). Forward-only; v61-v65b untouched.
-- The migration creates ZERO lots/movements/payments; prod authority stays 'unbuilt' for every real
-- business. record_sv_topup_sale is the ONLY authoritative mint; the old sv_topup/sv_grant browser paths
-- are retired/gated. Real value only mints when authority='live'; shadow/ready allow synthetic test only.

begin;

-- =====================================================================
-- 1. Structural synthetic markers (correction 7). Default false => every existing entity is REAL.
-- =====================================================================
alter table public.businesses add column is_synthetic boolean not null default false;
alter table public.clients    add column is_synthetic boolean not null default false;

-- true if any stored-value / payment / sale / entitlement evidence exists for the entity (for the
-- true->false unmark guard). client-scoped when p_client is given, else business-scoped.
create or replace function app.sv_has_synthetic_evidence(p_business uuid, p_client uuid)
returns boolean language plpgsql stable security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
begin
  return exists (select 1 from public.sv_operations o where o.business_id = p_business)
      or exists (select 1 from public.sv_lots l where l.business_id = p_business
                  and (p_client is null or l.account_id in (select id from public.sv_accounts a where a.business_id = p_business and a.client_id = p_client)))
      or exists (select 1 from public.sv_topup_payments pm where pm.business_id = p_business and (p_client is null or pm.client_id = p_client));
end $$;
revoke all on function app.sv_has_synthetic_evidence(uuid, uuid) from public, anon, authenticated;

-- is_synthetic may change ONLY when a super-admin or a trusted backend role acts; unmark (true->false)
-- is refused while synthetic evidence remains. Owners cannot self-mark.
create or replace function app.is_synthetic_guard()
returns trigger language plpgsql security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_priv boolean := app.is_super_admin() or session_user in ('postgres','service_role','supabase_admin');
  v_biz uuid; v_cli uuid;
begin
  if tg_op = 'INSERT' then
    if new.is_synthetic and not v_priv then
      raise exception 'only a super-admin may create a synthetic entity' using errcode = '42501';
    end if;
    return new;
  end if;
  if new.is_synthetic is distinct from old.is_synthetic then
    if not v_priv then raise exception 'only a super-admin may change the synthetic marker' using errcode = '42501'; end if;
    if old.is_synthetic and not new.is_synthetic then
      if tg_table_name = 'clients' then v_biz := new.business_id; v_cli := new.id;
      else v_biz := new.id; v_cli := null; end if;
      if app.sv_has_synthetic_evidence(v_biz, v_cli) then
        raise exception 'cannot clear the synthetic marker while synthetic stored-value evidence remains' using errcode = '22023';
      end if;
    end if;
  end if;
  return new;
end $$;
revoke all on function app.is_synthetic_guard() from public, anon, authenticated;
create trigger businesses_is_synthetic_guard before insert or update on public.businesses
  for each row execute function app.is_synthetic_guard();
create trigger clients_is_synthetic_guard before insert or update on public.clients
  for each row execute function app.is_synthetic_guard();

-- Structural exclusion: synthetic businesses never appear in billing.
create or replace view public.v_business_billing as
 select b.id as business_id, b.name as business_name,
    coalesce(sub.status, 'trialing') as status,
    coalesce(sub.currency, 'SGD') as currency,
    coalesce(sub.base_price_cents, 2500) as base_price_cents,
    coalesce(sub.included_seats, 1) as included_seats,
    coalesce(sub.per_seat_price_cents, 1000) as per_seat_price_cents,
    app.billable_seats(b.id) as billable_seats,
    greatest(app.billable_seats(b.id) - coalesce(sub.included_seats, 1), 0) as extra_seats,
    coalesce(sub.base_price_cents, 2500) + greatest(app.billable_seats(b.id) - coalesce(sub.included_seats, 1), 0) * coalesce(sub.per_seat_price_cents, 1000) as monthly_total_cents,
    sub.trial_ends_at, sub.current_period_start, sub.current_period_end
   from public.businesses b
   left join public.subscriptions sub on sub.business_id = b.id
  where b.is_synthetic = false;

-- =====================================================================
-- 2. Payment evidence: immutable original + append-only events (corrections 2/3).
-- =====================================================================
create table public.sv_topup_payments (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  branch_id uuid not null,
  client_id uuid not null,
  operation_id uuid not null,
  plan_version_id uuid not null,
  amount_cents integer not null check (amount_cents > 0),
  currency text not null,
  method text not null check (method in ('cash','card_terminal','paynow','manual','test')),
  reference text,
  reference_norm text generated always as (lower(btrim(reference))) stored,
  confirmation_mode text not null check (confirmation_mode in ('cash_received','staff_attested','synthetic_test')),
  actor uuid,
  confirmed_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  constraint sv_topup_payments_id_business_uk unique (id, business_id),
  constraint sv_topup_payments_operation_uk unique (operation_id),
  constraint sv_topup_payments_operation_fk foreign key (operation_id, business_id)
    references public.sv_operations(id, business_id) on delete restrict
);
-- non-cash double-funding guard (correction 8): one success per (business, method, normalised reference).
create unique index sv_topup_payments_noncash_ref_uk on public.sv_topup_payments (business_id, method, reference_norm)
  where method <> 'cash' and reference_norm is not null;
create index sv_topup_payments_client_idx on public.sv_topup_payments (business_id, client_id, created_at);
create trigger sv_topup_payments_immutable_guard before update or delete on public.sv_topup_payments
  for each row execute function app.sv_immutable_guard();
alter table public.sv_topup_payments enable row level security;
create policy sv_topup_payments_owner_read on public.sv_topup_payments for select to authenticated using (app.is_salon_owner(business_id));
create policy sv_topup_payments_sa_read on public.sv_topup_payments for select to authenticated using (app.is_super_admin());
revoke all on public.sv_topup_payments from public, anon, authenticated;
grant select on public.sv_topup_payments to authenticated;

create table public.sv_topup_payment_events (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  payment_id uuid not null,
  event_type text not null check (event_type in ('confirmed','reversed','chargeback','correction')),
  operation_id uuid,
  actor uuid,
  reason text,
  created_at timestamptz not null default now(),
  constraint sv_topup_payment_events_payment_fk foreign key (payment_id, business_id)
    references public.sv_topup_payments(id, business_id) on delete restrict
);
create index sv_topup_payment_events_payment_idx on public.sv_topup_payment_events (business_id, payment_id, created_at);
create trigger sv_topup_payment_events_immutable_guard before update or delete on public.sv_topup_payment_events
  for each row execute function app.sv_immutable_guard();
alter table public.sv_topup_payment_events enable row level security;
create policy sv_topup_payment_events_owner_read on public.sv_topup_payment_events for select to authenticated using (app.is_salon_owner(business_id));
create policy sv_topup_payment_events_sa_read on public.sv_topup_payment_events for select to authenticated using (app.is_super_admin());
revoke all on public.sv_topup_payment_events from public, anon, authenticated;
grant select on public.sv_topup_payment_events to authenticated;

-- =====================================================================
-- 3. Close the alternate mint paths (correction 1). record_sv_topup_sale is the only authoritative mint.
-- =====================================================================
create or replace function public.sv_topup(
  p_business uuid, p_client uuid, p_plan_version uuid, p_idempotency_key uuid)
returns jsonb language plpgsql security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
begin
  raise exception 'use_record_sv_topup_sale: sv_topup is retired; call record_sv_topup_sale (payment evidence + authority safety required)' using errcode = '22023';
end $$;
revoke all on function public.sv_topup(uuid, uuid, uuid, uuid) from public, anon, authenticated;

create or replace function public.sv_grant(
  p_business uuid, p_client uuid, p_cents int, p_reason text, p_idempotency_key uuid)
returns jsonb language plpgsql security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
begin
  raise exception 'sv_grant_unavailable_v66: direct stored-value grants are not available in v66' using errcode = '22023';
end $$;
revoke all on function public.sv_grant(uuid, uuid, integer, text, uuid) from public, anon, authenticated;

-- =====================================================================
-- 4. Helpers.
-- =====================================================================
-- dedicated top-up permission (correction 4): owner or manager or explicit sell_topups grant.
create or replace function app.can_sell_topups(p_business uuid)
returns boolean language sql stable security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
  select app.is_salon_owner(p_business)
    or exists (select 1 from public.staff s
        where s.business_id = p_business and s.user_id = auth.uid() and s.active
          and (s.role = 'manager' or coalesce((s.module_perms->>'sell_topups')::boolean, false)))
$$;
revoke all on function app.can_sell_topups(uuid) from public, anon, authenticated;

-- current sellable version (correction 5): highest version_no whose effective_at is null or <= now().
create or replace function app.current_sellable_sv_version(p_business uuid, p_plan uuid)
returns uuid language sql stable security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
  select pv.id from public.sv_plan_versions pv
   where pv.business_id = p_business and pv.plan_id = p_plan
     and (pv.effective_at is null or pv.effective_at <= now())
   order by pv.version_no desc limit 1
$$;
revoke all on function app.current_sellable_sv_version(uuid, uuid) from public, anon, authenticated;

-- total OUTSTANDING value incl. reserved (correction 6): gross of active reservations.
create or replace function app.sv_total_outstanding(p_business uuid, p_account uuid)
returns integer language sql stable security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
  select coalesce((select sum(m.cents) from public.sv_lot_movements m
                    where m.business_id = p_business and m.account_id = p_account), 0)::integer
$$;
revoke all on function app.sv_total_outstanding(uuid, uuid) from public, anon, authenticated;

-- count a client's prior top-ups of a PLAN (any version), optionally within a window.
create or replace function app.sv_topup_count(p_business uuid, p_account uuid, p_plan uuid, p_since timestamptz)
returns integer language sql stable security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
  select count(distinct o.id)::integer
    from public.sv_operations o
    join public.sv_lots l on l.operation_id = o.id and l.business_id = o.business_id
   where o.business_id = p_business and o.operation_type = 'topup' and l.account_id = p_account
     and l.plan_version_id in (select id from public.sv_plan_versions where plan_id = p_plan and business_id = p_business)
     and (p_since is null or o.created_at >= p_since)
$$;
revoke all on function app.sv_topup_count(uuid, uuid, uuid, timestamptz) from public, anon, authenticated;

-- =====================================================================
-- 5. set_synthetic_marker (correction 7) - super-admin only, audited. Guard enforces the invariants.
-- =====================================================================
create or replace function public.set_synthetic_marker(
  p_business uuid, p_client uuid, p_is_synthetic boolean, p_reason text)
returns jsonb language plpgsql security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare v_actor uuid := auth.uid(); v_reason text := nullif(btrim(coalesce(p_reason,'')),'');
begin
  if not app.is_super_admin() then raise exception 'super-admin only' using errcode = '42501'; end if;
  if v_reason is null or char_length(v_reason) < 3 then raise exception 'a reason of at least 3 characters is required' using errcode = '22023'; end if;
  if p_client is null then
    update public.businesses set is_synthetic = p_is_synthetic where id = p_business;
    if not found then raise exception 'business not found' using errcode = '22023'; end if;
  else
    update public.clients set is_synthetic = p_is_synthetic where id = p_client and business_id = p_business;
    if not found then raise exception 'client not found in business' using errcode = '22023'; end if;
  end if;
  insert into public.audit_log(business_id, actor, action, entity, entity_id, detail)
  values (p_business, v_actor, 'SV_SYNTHETIC_MARKER_SET', case when p_client is null then 'businesses' else 'clients' end,
    coalesce(p_client, p_business), jsonb_build_object('is_synthetic', p_is_synthetic, 'reason', v_reason));
  return jsonb_build_object('status','ok','business_id',p_business,'client_id',p_client,'is_synthetic',p_is_synthetic);
end $$;
revoke all on function public.set_synthetic_marker(uuid, uuid, boolean, text) from public, anon, authenticated;
grant execute on function public.set_synthetic_marker(uuid, uuid, boolean, text) to authenticated;

-- =====================================================================
-- 6. app.sv_topup_projection - shared read used by preview + get_sellable + record (server-authoritative
--    projection + blockers for one (branch, client, version)). READ-only, no DML.
-- =====================================================================
create or replace function app.sv_topup_projection(p_business uuid, p_branch uuid, p_client uuid, p_plan_version uuid)
returns jsonb language plpgsql stable security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  pv public.sv_plan_versions%rowtype; v_plan_active boolean; v_state text; v_biz_synth boolean; v_client_synth boolean;
  v_account uuid; v_outstanding integer := 0; v_blockers text[] := '{}'; v_window_used integer := 0; v_lifetime_used integer := 0;
  v_currency text; v_total integer;
begin
  select * into pv from public.sv_plan_versions where id = p_plan_version and business_id = p_business;
  if not found then return jsonb_build_object('ok', false, 'blockers', to_jsonb(array['plan version not in this business'])); end if;
  select active into v_plan_active from public.sv_plans where id = pv.plan_id and business_id = p_business;
  v_total := pv.price_cents + pv.bonus_cents;
  select coalesce(state,'unbuilt') into v_state from public.sv_authority where business_id = p_business and asset = 'stored_value';
  v_state := coalesce(v_state,'unbuilt');
  select b.is_synthetic, b.currency into v_biz_synth, v_currency from public.businesses b where b.id = p_business;
  select c.is_synthetic into v_client_synth from public.clients c where c.id = p_client and c.business_id = p_business;

  if not coalesce(v_plan_active,false) then v_blockers := array_append(v_blockers,'plan is retired'); end if;
  if pv.effective_at is not null and pv.effective_at > now() then v_blockers := array_append(v_blockers,'plan version is not yet effective'); end if;
  if p_plan_version is distinct from app.current_sellable_sv_version(p_business, pv.plan_id) then v_blockers := array_append(v_blockers,'not the current sellable version'); end if;
  if pv.eligible_branch_ids is not null and not (p_branch = any(pv.eligible_branch_ids)) then v_blockers := array_append(v_blockers,'branch not eligible for this plan'); end if;
  if pv.topup_purchase_earns_points then v_blockers := array_append(v_blockers,'points-on-topup is not yet supported'); end if;
  if v_state = 'unbuilt' then v_blockers := array_append(v_blockers,'stored value is not ready for top-ups');
  elsif v_state in ('shadow_testing','ready_for_cutover') then
    if not (coalesce(v_biz_synth,false) and coalesce(v_client_synth,false)) then v_blockers := array_append(v_blockers,'only synthetic test top-ups are permitted in this authority state'); end if;
  elsif v_state = 'live' then
    if coalesce(v_biz_synth,false) or coalesce(v_client_synth,false) then v_blockers := array_append(v_blockers,'a synthetic entity cannot transact on a live business'); end if;
  else v_blockers := array_append(v_blockers,'stored value is '||v_state); end if;

  select id into v_account from public.sv_accounts where business_id = p_business and client_id = p_client and asset = 'stored_value';
  if v_account is not null then
    v_outstanding := app.sv_total_outstanding(p_business, v_account);
    if pv.purchase_window_days is not null then
      v_window_used := app.sv_topup_count(p_business, v_account, pv.plan_id, now() - (pv.purchase_window_days||' days')::interval);
    end if;
    v_lifetime_used := app.sv_topup_count(p_business, v_account, pv.plan_id, null);
  end if;
  if pv.max_balance_cents is not null and v_outstanding + v_total > pv.max_balance_cents then v_blockers := array_append(v_blockers,'maximum balance would be exceeded'); end if;
  if pv.purchase_window_days is not null and pv.purchase_max_in_window is not null and v_window_used >= pv.purchase_max_in_window then v_blockers := array_append(v_blockers,'purchase frequency limit reached'); end if;
  if pv.purchase_lifetime_cap is not null and v_lifetime_used >= pv.purchase_lifetime_cap then v_blockers := array_append(v_blockers,'lifetime purchase cap reached'); end if;

  return jsonb_build_object(
    'ok', (array_length(v_blockers,1) is null),
    'plan_id', pv.plan_id, 'version_id', pv.id, 'version_no', pv.version_no, 'plan_name', pv.customer_facing_name,
    'price_cents', pv.price_cents, 'bonus_cents', pv.bonus_cents, 'total_usable_cents', v_total,
    'effective_discount_bps', app.sv_plan_effective_discount_bps(pv.price_cents, pv.bonus_cents),
    'paid_expiry_days', pv.paid_expiry_days, 'bonus_expiry_days', pv.bonus_expiry_days,
    'min_spend_cents', pv.min_spend_cents, 'stacking_policy', pv.stacking_policy, 'max_balance_cents', pv.max_balance_cents,
    'purchase_window_days', pv.purchase_window_days, 'purchase_max_in_window', pv.purchase_max_in_window,
    'purchase_lifetime_cap', pv.purchase_lifetime_cap, 'refund_policy', pv.refund_policy, 'spend_order', pv.spend_order,
    'topup_purchase_earns_points', pv.topup_purchase_earns_points, 'customer_terms', pv.customer_terms,
    'eligible_branch_ids', to_jsonb(pv.eligible_branch_ids), 'eligible_service_ids', to_jsonb(pv.eligible_service_ids),
    'currency', coalesce(v_currency,'SGD'),
    'account_outstanding_cents', v_outstanding, 'projected_account_total_cents', v_outstanding + v_total,
    'window_used', v_window_used, 'window_remaining', case when pv.purchase_max_in_window is null then null else greatest(pv.purchase_max_in_window - v_window_used, 0) end,
    'lifetime_used', v_lifetime_used, 'lifetime_remaining', case when pv.purchase_lifetime_cap is null then null else greatest(pv.purchase_lifetime_cap - v_lifetime_used, 0) end,
    'authority_state', v_state, 'spendable', (v_state = 'live'),
    'reference_required', true, 'blockers', to_jsonb(v_blockers));
end $$;
revoke all on function app.sv_topup_projection(uuid, uuid, uuid, uuid) from public, anon, authenticated;

-- =====================================================================
-- 7. get_sellable_sv_topup_plans (correction 5) + preview_sv_topup_sale (correction 10) - owner/staff read.
-- =====================================================================
create or replace function public.get_sellable_sv_topup_plans(p_business uuid, p_branch uuid, p_client uuid)
returns jsonb language plpgsql stable security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare v_rows jsonb;
begin
  if not app.can_sell_topups(p_business) then raise exception 'not permitted to sell top-ups for this business' using errcode = '42501'; end if;
  select coalesce(jsonb_agg(app.sv_topup_projection(p_business, p_branch, p_client, cur.vid) order by cur.name), '[]'::jsonb)
    into v_rows
    from (select s.id as plan_id, s.name, app.current_sellable_sv_version(p_business, s.id) as vid
            from public.sv_plans s where s.business_id = p_business and s.active) cur
   where cur.vid is not null;
  return jsonb_build_object('business_id', p_business, 'branch_id', p_branch, 'client_id', p_client, 'plans', v_rows);
end $$;
revoke all on function public.get_sellable_sv_topup_plans(uuid, uuid, uuid) from public, anon, authenticated;
grant execute on function public.get_sellable_sv_topup_plans(uuid, uuid, uuid) to authenticated;

create or replace function public.preview_sv_topup_sale(p_business uuid, p_branch uuid, p_client uuid, p_plan_version uuid, p_payment jsonb default '{}'::jsonb)
returns jsonb language plpgsql stable security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare v_proj jsonb;
begin
  if not app.can_sell_topups(p_business) then raise exception 'not permitted to sell top-ups for this business' using errcode = '42501'; end if;
  if not exists (select 1 from public.clients c where c.id = p_client and c.business_id = p_business) then
    raise exception 'customer not in this business' using errcode = '22023'; end if;
  v_proj := app.sv_topup_projection(p_business, p_branch, p_client, p_plan_version);
  return v_proj || jsonb_build_object('preview', true, 'advisory_only', true);
end $$;
revoke all on function public.preview_sv_topup_sale(uuid, uuid, uuid, uuid, jsonb) from public, anon, authenticated;
grant execute on function public.preview_sv_topup_sale(uuid, uuid, uuid, uuid, jsonb) to authenticated;

-- =====================================================================
-- 8. record_sv_topup_sale - THE authoritative op (correction 11). Atomic, keyed, fail-closed.
-- =====================================================================
create or replace function public.record_sv_topup_sale(
  p_business uuid, p_branch uuid, p_client uuid, p_plan_version uuid, p_payment jsonb, p_idempotency_key uuid)
returns jsonb language plpgsql security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_actor uuid := auth.uid();
  pv public.sv_plan_versions%rowtype; v_plan_active boolean; v_state text; v_biz_synth boolean; v_client_synth boolean;
  v_biz_currency text;
  v_method text; v_currency text; v_amount integer; v_reference text; v_ref_norm text; v_staff_confirmed boolean;
  v_confirmation_mode text;
  v_hash text; v_existing public.sv_operations%rowtype;
  v_account uuid; v_outstanding integer;
  v_op uuid := gen_random_uuid(); v_paid_lot uuid := gen_random_uuid(); v_bonus_lot uuid; v_payment_id uuid := gen_random_uuid();
  v_paid_seq bigint; v_bonus_seq bigint; v_paid_expiry timestamptz; v_bonus_expiry timestamptz;
  v_result jsonb;
begin
  -- permission + branch
  if not app.can_sell_topups(p_business) then raise exception 'not permitted to sell top-ups for this business' using errcode = '42501'; end if;
  if not app.can_see_branch(p_business, p_branch) then raise exception 'no access to this branch' using errcode = '42501'; end if;
  if not exists (select 1 from public.branches b where b.id = p_branch and b.business_id = p_business and b.active) then
    raise exception 'branch is not part of this business or is inactive' using errcode = '22023'; end if;

  -- payment shape
  if p_payment is null or jsonb_typeof(p_payment) <> 'object' then raise exception 'payment must be a JSON object' using errcode = '22023'; end if;
  v_method := lower(btrim(coalesce(p_payment->>'method','')));
  if v_method not in ('cash','card_terminal','paynow','manual','test') then raise exception 'invalid payment method' using errcode = '22023'; end if;
  if not app.sv_jsonb_is_int(p_payment->'amount_cents') then raise exception 'payment amount_cents must be a whole number' using errcode = '22023'; end if;
  v_amount := (p_payment->>'amount_cents')::integer;
  v_currency := upper(btrim(coalesce(p_payment->>'currency','')));
  v_reference := nullif(btrim(p_payment->>'reference'), '');
  v_ref_norm := lower(v_reference);
  v_staff_confirmed := coalesce((p_payment->>'staff_confirmed')::boolean, false);

  -- customer + plan version
  select c.is_synthetic into v_client_synth from public.clients c where c.id = p_client and c.business_id = p_business;
  if not found then raise exception 'customer not in this business' using errcode = '22023'; end if;
  select * into pv from public.sv_plan_versions where id = p_plan_version and business_id = p_business;
  if not found then raise exception 'plan version not in this business' using errcode = '22023'; end if;
  select active into v_plan_active from public.sv_plans where id = pv.plan_id and business_id = p_business;
  if not coalesce(v_plan_active,false) then raise exception 'plan is retired' using errcode = '22023'; end if;
  if pv.effective_at is not null and pv.effective_at > now() then raise exception 'plan version is not yet effective' using errcode = '22023'; end if;
  if p_plan_version is distinct from app.current_sellable_sv_version(p_business, pv.plan_id) then raise exception 'not_current_version: only the current sellable plan version may be sold' using errcode = '22023'; end if;
  if pv.eligible_branch_ids is not null and not (p_branch = any(pv.eligible_branch_ids)) then raise exception 'branch is not eligible for this plan' using errcode = '22023'; end if;

  -- authority + synthetic gate
  select is_synthetic, currency into v_biz_synth, v_biz_currency from public.businesses where id = p_business;
  select coalesce(state,'unbuilt') into v_state from public.sv_authority where business_id = p_business and asset = 'stored_value';
  v_state := coalesce(v_state,'unbuilt');
  if v_state = 'unbuilt' then
    raise exception 'sv_not_ready: stored value is not ready for top-ups' using errcode = '22023';
  elsif v_state in ('shadow_testing','ready_for_cutover') then
    if not (coalesce(v_biz_synth,false) and coalesce(v_client_synth,false)) then raise exception 'only synthetic test top-ups are permitted in %', v_state using errcode = '22023'; end if;
    if v_method <> 'test' then raise exception 'only the test payment method is permitted in synthetic testing' using errcode = '22023'; end if;
  elsif v_state = 'live' then
    if coalesce(v_biz_synth,false) or coalesce(v_client_synth,false) then raise exception 'a synthetic entity cannot transact on a live business' using errcode = '22023'; end if;
    if v_method = 'test' then raise exception 'the test payment method is not permitted on a live business' using errcode = '22023'; end if;
  else
    raise exception 'stored value is % for this business', v_state using errcode = '22023';
  end if;

  -- earn pause
  if app.sv_pause_active(p_business, 'stored_value', 'earn') then raise exception 'sv_paused: stored-value earns are paused' using errcode = '22023'; end if;

  -- currency + amount + reference/attestation
  if v_currency <> upper(coalesce(v_biz_currency,'SGD')) then raise exception 'currency_mismatch: payment currency must be %', upper(coalesce(v_biz_currency,'SGD')) using errcode = '22023'; end if;
  if v_amount <> pv.price_cents then raise exception 'payment amount must equal the plan price (%.0f cents)', pv.price_cents::numeric using errcode = '22023'; end if;
  if v_method in ('card_terminal','paynow','manual') then
    if v_reference is null then raise exception 'a payment reference is required for this method' using errcode = '22023'; end if;
    if not v_staff_confirmed then raise exception 'explicit staff confirmation is required for this method' using errcode = '22023'; end if;
  end if;

  -- points policy (correction / directive §5)
  if pv.topup_purchase_earns_points then
    return jsonb_build_object('status','policy_not_yet_supported','reason','points-on-topup is not supported in this pilot');
  end if;

  -- idempotency envelope
  v_hash := app.ps1b_sha256(jsonb_build_object('op','topup_sale','business',p_business,'branch',p_branch,'client',p_client,
    'plan_version',p_plan_version,'method',v_method,'amount',v_amount,'currency',v_currency,'reference',v_ref_norm)::text);
  perform pg_advisory_xact_lock(hashtextextended('v66:topupsale:'||p_business::text||':'||p_idempotency_key::text, 0));
  select * into v_existing from public.sv_operations o
   where o.business_id = p_business and o.operation_type = 'topup' and o.idempotency_key = p_idempotency_key for update;
  if found then
    if v_existing.request_hash <> v_hash then raise exception 'idempotency key conflicts with a different top-up request' using errcode = '22023'; end if;
    return v_existing.result;
  end if;

  -- account lock + limits (max-balance on TOTAL OUTSTANDING incl reserved)
  perform pg_advisory_xact_lock(hashtextextended('v66:acct:'||p_business::text||':'||p_client::text, 0));
  v_account := app.sv_ensure_account(p_business, p_client);
  perform 1 from public.sv_accounts where id = v_account and business_id = p_business for update;

  -- FINALISATION RE-VALIDATION (close authority-state + version TOCTOU): re-read the authority row and the
  -- current sellable version under READ COMMITTED after the account lock, so a concurrent authority
  -- transition or a newly-effective version committed since the early checks cannot slip a mint through a
  -- stale state. No yield point exists between this re-check and the inserts below.
  select coalesce(state,'unbuilt') into v_state from public.sv_authority where business_id = p_business and asset = 'stored_value';
  v_state := coalesce(v_state,'unbuilt');
  if v_state = 'unbuilt' then
    raise exception 'sv_not_ready: stored value is not ready for top-ups' using errcode = '22023';
  elsif v_state in ('shadow_testing','ready_for_cutover') then
    if not (coalesce(v_biz_synth,false) and coalesce(v_client_synth,false)) or v_method <> 'test' then
      raise exception 'top-up is no longer permitted under the current authority state (%)', v_state using errcode = '22023'; end if;
  elsif v_state = 'live' then
    if coalesce(v_biz_synth,false) or coalesce(v_client_synth,false) or v_method = 'test' then
      raise exception 'top-up is no longer permitted under the current authority state (live)' using errcode = '22023'; end if;
  else
    raise exception 'stored value is % for this business', v_state using errcode = '22023';
  end if;
  if p_plan_version is distinct from app.current_sellable_sv_version(p_business, pv.plan_id) then
    raise exception 'not_current_version: the sellable plan version changed before finalisation' using errcode = '22023';
  end if;

  if pv.max_balance_cents is not null then
    v_outstanding := app.sv_total_outstanding(p_business, v_account);
    if v_outstanding + (pv.price_cents + pv.bonus_cents) > pv.max_balance_cents then
      raise exception 'max_balance_exceeded: this top-up would exceed the customer maximum balance' using errcode = '22023'; end if;
  end if;
  if pv.purchase_window_days is not null and pv.purchase_max_in_window is not null
     and app.sv_topup_count(p_business, v_account, pv.plan_id, now() - (pv.purchase_window_days||' days')::interval) >= pv.purchase_max_in_window then
    raise exception 'purchase_window_cap: purchase frequency limit reached' using errcode = '22023'; end if;
  if pv.purchase_lifetime_cap is not null
     and app.sv_topup_count(p_business, v_account, pv.plan_id, null) >= pv.purchase_lifetime_cap then
    raise exception 'lifetime_cap: lifetime purchase cap reached' using errcode = '22023'; end if;
  -- non-cash reference pre-check (partial unique index is the hard guarantee)
  if v_method <> 'cash' and v_ref_norm is not null
     and exists (select 1 from public.sv_topup_payments where business_id = p_business and method = v_method and reference_norm = v_ref_norm) then
    raise exception 'duplicate_payment_reference: this payment reference has already funded a top-up' using errcode = '22023'; end if;

  -- MINT (paid + bonus lots, independent expiry, immutable plan_version_id preserved)
  v_confirmation_mode := case v_method when 'cash' then 'cash_received' when 'test' then 'synthetic_test' else 'staff_attested' end;
  v_paid_seq := nextval('app.sv_earned_seq');
  v_paid_expiry := case when pv.paid_expiry_days is null then null else now() + (pv.paid_expiry_days||' days')::interval end;
  if pv.bonus_cents > 0 then
    v_bonus_lot := gen_random_uuid(); v_bonus_seq := nextval('app.sv_earned_seq');
    v_bonus_expiry := case when pv.bonus_expiry_days is null then null else now() + (pv.bonus_expiry_days||' days')::interval end;
  end if;

  v_result := jsonb_build_object(
    'status','ok','operation_id',v_op,'account_id',v_account,'payment_id',v_payment_id,'plan_version_id',p_plan_version,
    'paid_lot', jsonb_build_object('lot_id',v_paid_lot,'class','paid','minted_cents',pv.price_cents,'expiry_key',v_paid_expiry),
    'bonus_lot', case when pv.bonus_cents > 0 then jsonb_build_object('lot_id',v_bonus_lot,'class','bonus','minted_cents',pv.bonus_cents,'expiry_key',v_bonus_expiry) else null end,
    'cash_collected_cents', v_amount, 'paid_value_issued_cents', pv.price_cents, 'bonus_value_issued_cents', pv.bonus_cents,
    'total_value_issued_cents', pv.price_cents + pv.bonus_cents, 'account_total_after_cents', app.sv_total_outstanding(p_business, v_account) + pv.price_cents + pv.bonus_cents,
    'payment', jsonb_build_object('method',v_method,'reference',v_reference,'confirmation_mode',v_confirmation_mode,'currency',v_currency),
    'authority_state', v_state, 'spendable', (v_state = 'live'),
    'accounting', jsonb_build_object('cash_collected_cents', v_amount, 'paid_value_liability_cents', pv.price_cents, 'bonus_value_promotional_exposure_cents', pv.bonus_cents, 'is_revenue', false));

  insert into public.sv_operations(id,business_id,operation_type,idempotency_key,request_hash,actor,result)
  values (v_op,p_business,'topup',p_idempotency_key,v_hash,v_actor,v_result);
  insert into public.sv_lots(id,business_id,account_id,operation_id,class,minted_cents,expiry_key,earned_seq,plan_version_id)
  values (v_paid_lot,p_business,v_account,v_op,'paid',pv.price_cents,v_paid_expiry,v_paid_seq,p_plan_version);
  insert into public.sv_lot_movements(business_id,account_id,lot_id,operation_id,kind,cents)
  values (p_business,v_account,v_paid_lot,v_op,'issue',pv.price_cents);
  if pv.bonus_cents > 0 then
    insert into public.sv_lots(id,business_id,account_id,operation_id,class,minted_cents,expiry_key,earned_seq,plan_version_id)
    values (v_bonus_lot,p_business,v_account,v_op,'bonus',pv.bonus_cents,v_bonus_expiry,v_bonus_seq,p_plan_version);
    insert into public.sv_lot_movements(business_id,account_id,lot_id,operation_id,kind,cents)
    values (p_business,v_account,v_bonus_lot,v_op,'issue',pv.bonus_cents);
  end if;
  insert into public.sv_topup_payments(id,business_id,branch_id,client_id,operation_id,plan_version_id,amount_cents,currency,method,reference,confirmation_mode,actor,confirmed_at)
  values (v_payment_id,p_business,p_branch,p_client,v_op,p_plan_version,v_amount,v_currency,v_method,v_reference,v_confirmation_mode,v_actor,now());
  insert into public.sv_topup_payment_events(business_id,payment_id,event_type,operation_id,actor,reason)
  values (p_business,v_payment_id,'confirmed',v_op,v_actor,'top-up confirmed at sale');
  insert into public.audit_log(business_id,actor,action,entity,entity_id,detail)
  values (p_business,v_actor,'SV_TOPUP_SALE','sv_accounts',v_account,jsonb_build_object(
    'operation_id',v_op,'payment_id',v_payment_id,'plan_version_id',p_plan_version,'method',v_method,
    'paid_cents',pv.price_cents,'bonus_cents',pv.bonus_cents,'confirmation_mode',v_confirmation_mode));

  return v_result;
end $$;
revoke all on function public.record_sv_topup_sale(uuid, uuid, uuid, uuid, jsonb, uuid) from public, anon, authenticated;
grant execute on function public.record_sv_topup_sale(uuid, uuid, uuid, uuid, jsonb, uuid) to authenticated;

commit;
