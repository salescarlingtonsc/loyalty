-- FRENLY v64 - PROGRAM STUDIO PS-2A INCREMENT D: STORED-VALUE PAUSE/KILL CONTROLS + CUTOVER PREVIEW
--
-- Local review candidate. Production apply needs the owner's RELEASE APPROVED phrase
-- (CLAUDE.md standing gate). Builds on Increment A (v61) + B (v62) + C (v63) under the SAME
-- PS-2 authorization - no new phase, no cutover, no spendable value, no real comms. This
-- migration IMPLEMENTS docs/design/ps2/PS2A_INCREMENT_D_CONTRACT.md §1-§3 over the parent
-- docs/design/ps2/PS2A_STORED_VALUE_CONTRACT.md §8 (pause policy) + §9 (permissions); the UI
-- (§4) ships in app/index.html separately.
--
-- WHAT INCREMENT D ADDS:
--   1. public.sv_pauses - a DEDICATED stored-value pause table (NOT the rule pause
--      studio_rule_emergency_pauses, which is keyed on a rule_id with rule-engine semantics).
--      Ledger authority needs business/asset scope + operation-family granularity (contract §8):
--      scope in ('all','earn','redeem'). Append-only, write-once (lift-once) guard mirrored from
--      studio_rule_emergency_pauses; one ACTIVE pause per (business, asset, scope) via a partial
--      unique index; RLS owner+super-admin READ; browser writes revoked.
--   2. public.sv_pause / public.sv_lift_pause - owner-only, audited (SV_PAUSE / SV_PAUSE_LIFTED),
--      idempotent (an active pause of a scope is returned replayed:true; a lift-of-none is a
--      no-op replayed:true). No history deletion; NO implicit lift (publishing a configuration
--      version cannot lift an sv pause - they are unrelated surfaces).
--   3. app.sv_pause_active(business, asset, family) - the internal gate helper. family 'earn'
--      matches an active 'all' OR 'earn' pause; 'redeem' matches 'all' OR 'redeem'; 'all_only'
--      matches 'all' ONLY (for the expiry sweep, which is neither an earn nor a redeem).
--   4. THE TEETH - the Increment-C/A value RPCs are CREATE OR REPLACE'd adding ONLY the pause
--      gate (byte-identical to v61/v63 otherwise; a predecessor byte-diff shows only the guard):
--        * sv_topup + sv_grant (v61): 'all'/'earn' pause blocks new earns  -> 22023 'sv_paused'.
--        * sv_spend + sv_reserve (v63): 'all'/'redeem' pause blocks spend/reserve -> 22023.
--        * sv_reverse_spend (v63): a reversal is a redeem-side correction -> 'all'/'redeem'.
--        * refund_sv_operation (v63): a refund returns customer cash = an earn-side correction
--          -> 'all'/'earn'.
--        * sv_expire_due (v63): the expiry sweep is a system op -> blocked by 'all' ONLY.
--      PINNED POLICY (contract §8): an 'earn' pause does NOT block spend - customers keep
--      spending value they already hold; only a 'redeem'/'all' pause stops spend. sv_release is
--      DELIBERATELY NOT gated: it returns held value to available (the redeem-family's "undo"),
--      never a new redemption - contract §1 lists exactly the seven RPCs above and omits release.
--      Historical rows are NEVER touched by any pause. The v63 sv_not_live gate stays the FIRST
--      check; the pause gate is the SECOND, independent gate. Since every value RPC already
--      hard-refuses unless authority='live' (unreachable in PS-2A), the pause is a second
--      independent gate; both are tested independently.
--   5. public.get_sv_authority_overview(business) - owner/super-admin read: authority_state,
--      spendable=(state='live'), shadow_testing, the latest reconciliation summary, the active
--      pauses, and can_cutover HARDCODED false (no cutover action exists in PS-2A).
--   6. public.preview_sv_cutover(business) - owner-only read: what a cutover WOULD require and
--      its current blockers; ready HARDCODED false. NO function that performs a cutover exists.
--
-- CHECKOUT KERNEL + PS-1C.2 studio pause: UNCHANGED. ps1c_plan_checkout / record_cart_sale /
--   evaluate_checkout and studio_rule_emergency_pauses / ps1b_execute_event are NOT redefined
--   here. sv_authority is only READ (never transitioned); no 'live'/'ready_for_cutover' anywhere.
--   points_ledger / credit_ledger / gift_cards / benefit_registry untouched.

begin;

-- =====================================================================
-- 1. public.sv_pauses - the DEDICATED stored-value pause table. Distinct from
--    studio_rule_emergency_pauses (rule-engine semantics on rule_id): ledger authority needs
--    business/asset scope + operation-family granularity (contract §8). Append-only, write-once
--    (lift-once). A pause stops NEW operations of its family WITHOUT deleting any historical
--    movement/lot/reservation. Owner + super-admin READ; browser WRITES revoked (definer RPCs
--    only). Composite tenant uniqueness (id, business_id) for the sv-family convention.
-- =====================================================================
create table public.sv_pauses (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  asset text not null default 'stored_value' check (asset = 'stored_value'),
  scope text not null check (scope in ('all', 'earn', 'redeem')),
  actor uuid not null,
  reason text not null check (char_length(btrim(reason)) >= 3),
  paused_at timestamptz not null default now(),
  lifted_at timestamptz,
  lifted_by uuid,
  created_at timestamptz not null default now(),
  constraint sv_pauses_id_business_uk unique (id, business_id),
  constraint sv_pauses_lift_presence_check check ((lifted_at is null) = (lifted_by is null))
);
-- Exactly one ACTIVE pause per (business, asset, scope). Matches the sv_pause ON CONFLICT target.
create unique index sv_pauses_active_uk
  on public.sv_pauses (business_id, asset, scope) where lifted_at is null;
create index sv_pauses_scope_idx
  on public.sv_pauses (business_id, asset, scope, paused_at);

-- Write-once guard (entitlement-guard pattern, mirrored from app.studio_rule_emergency_pauses_guard):
-- no delete; identity is immutable; lifted_at/lifted_by are settable EXACTLY ONCE (an already-
-- lifted row is frozen). A pause is thus append-only history that can be lifted a single time.
create or replace function app.sv_pauses_guard()
returns trigger language plpgsql security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
begin
  if tg_op = 'DELETE' then
    raise exception 'sv_pauses is append-only' using errcode = 'restrict_violation';
  end if;
  if old.lifted_at is not null then
    raise exception 'stored-value pause is already lifted (write-once)' using errcode = 'restrict_violation';
  end if;
  if new.business_id is distinct from old.business_id
     or new.asset is distinct from old.asset
     or new.scope is distinct from old.scope
     or new.actor is distinct from old.actor
     or new.reason is distinct from old.reason
     or new.paused_at is distinct from old.paused_at
     or new.created_at is distinct from old.created_at then
    raise exception 'stored-value pause identity is immutable' using errcode = 'restrict_violation';
  end if;
  if new.lifted_at is null or new.lifted_by is null then
    raise exception 'lifting a stored-value pause requires lifted_at and lifted_by' using errcode = 'restrict_violation';
  end if;
  return new;
end $$;
revoke all on function app.sv_pauses_guard() from public, anon, authenticated;
create trigger sv_pauses_guard
  before update or delete on public.sv_pauses
  for each row execute function app.sv_pauses_guard();

alter table public.sv_pauses enable row level security;
create policy sv_pauses_owner_read on public.sv_pauses
  for select to authenticated using (app.is_salon_owner(business_id));
create policy sv_pauses_sa_read on public.sv_pauses
  for select to authenticated using (app.is_super_admin());
revoke all on public.sv_pauses from public, anon, authenticated;
grant select on public.sv_pauses to authenticated;

-- =====================================================================
-- 2. app.sv_pause_active - the internal gate helper. Returns true when an active (unlifted)
--    sv_pause of the requested FAMILY exists. An 'all' pause always blocks; 'earn' additionally
--    matches an 'earn' pause; 'redeem' additionally matches a 'redeem' pause; 'all_only' matches
--    ONLY an 'all' pause (the expiry sweep, which is neither an earn nor a redeem). Any other
--    family value still fails safe: it blocks only when an 'all' pause is active. Definer,
--    revoked from browsers (the value RPCs read it).
-- =====================================================================
create or replace function app.sv_pause_active(p_business uuid, p_asset text, p_family text)
returns boolean language sql stable security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
  select exists (
    select 1 from public.sv_pauses p
     where p.business_id = p_business
       and p.asset = coalesce(p_asset, 'stored_value')
       and p.lifted_at is null
       and (
         p.scope = 'all'
         or (p_family = 'earn' and p.scope = 'earn')
         or (p_family = 'redeem' and p.scope = 'redeem')
       )
  )
$$;
revoke all on function app.sv_pause_active(uuid, text, text) from public, anon, authenticated;

-- =====================================================================
-- 3. public.sv_pause - owner-only, audited pause. Idempotent: an existing ACTIVE pause of this
--    scope is returned unchanged (replayed:true) and also wins the race (ON CONFLICT ... DO
--    NOTHING against the partial unique index). Reason >= 3 chars. Audit SV_PAUSE.
-- =====================================================================
create or replace function public.sv_pause(
  p_business uuid, p_asset text, p_scope text, p_reason text)
returns jsonb language plpgsql security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_actor uuid := auth.uid();
  v_asset text := coalesce(p_asset, 'stored_value');
  v_reason text := btrim(coalesce(p_reason, ''));
  v_id uuid;
begin
  if not app.is_salon_owner(p_business) then
    raise exception 'owner only' using errcode = '42501';
  end if;
  if v_asset <> 'stored_value' then
    raise exception 'stored-value pause supports only the stored_value asset' using errcode = '22023';
  end if;
  if p_scope is null or p_scope not in ('all', 'earn', 'redeem') then
    raise exception 'a stored-value pause scope must be all, earn or redeem' using errcode = '22023';
  end if;
  if char_length(v_reason) < 3 then
    raise exception 'a stored-value pause requires a reason of at least 3 characters' using errcode = '22023';
  end if;

  -- Idempotent: an existing active pause of this scope is returned unchanged (also wins the race).
  insert into public.sv_pauses(business_id, asset, scope, actor, reason)
  values (p_business, v_asset, p_scope, v_actor, v_reason)
  on conflict (business_id, asset, scope) where lifted_at is null do nothing
  returning id into v_id;
  if v_id is null then
    select id into v_id from public.sv_pauses
     where business_id = p_business and asset = v_asset and scope = p_scope and lifted_at is null;
    return jsonb_build_object('status', 'ok', 'pause_id', v_id, 'business_id', p_business,
      'asset', v_asset, 'scope', p_scope, 'replayed', true);
  end if;

  insert into public.audit_log(business_id, actor, action, entity, entity_id, detail)
  values (p_business, v_actor, 'SV_PAUSE', 'sv_pauses', v_id, jsonb_build_object(
    'asset', v_asset, 'scope', p_scope, 'reason', v_reason, 'pause_id', v_id));
  return jsonb_build_object('status', 'ok', 'pause_id', v_id, 'business_id', p_business,
    'asset', v_asset, 'scope', p_scope, 'replayed', false);
end $$;
revoke all on function public.sv_pause(uuid, text, text, text) from public, anon, authenticated;
grant execute on function public.sv_pause(uuid, text, text, text) to authenticated;

-- =====================================================================
-- 4. public.sv_lift_pause - owner-only, audited lift of the ACTIVE pause of a scope. A lift of a
--    scope with no active pause is an idempotent no-op (replayed:true, lifted:false). Lifting one
--    scope restores only that operation family; a separately-paused scope stays blocked. The
--    write-once guard freezes an already-lifted row. Audit SV_PAUSE_LIFTED. NO implicit lift path
--    exists anywhere else (a configuration publish cannot lift an sv pause).
-- =====================================================================
create or replace function public.sv_lift_pause(
  p_business uuid, p_asset text, p_scope text, p_reason text default null)
returns jsonb language plpgsql security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_actor uuid := auth.uid();
  v_asset text := coalesce(p_asset, 'stored_value');
  v_reason text := nullif(btrim(coalesce(p_reason, '')), '');
  v_id uuid;
begin
  if not app.is_salon_owner(p_business) then
    raise exception 'owner only' using errcode = '42501';
  end if;
  if v_asset <> 'stored_value' then
    raise exception 'stored-value pause supports only the stored_value asset' using errcode = '22023';
  end if;
  if p_scope is null or p_scope not in ('all', 'earn', 'redeem') then
    raise exception 'a stored-value pause scope must be all, earn or redeem' using errcode = '22023';
  end if;

  update public.sv_pauses
     set lifted_at = now(), lifted_by = v_actor
   where business_id = p_business and asset = v_asset and scope = p_scope and lifted_at is null
   returning id into v_id;
  if v_id is null then
    return jsonb_build_object('status', 'ok', 'business_id', p_business, 'asset', v_asset,
      'scope', p_scope, 'lifted', false, 'replayed', true);
  end if;

  insert into public.audit_log(business_id, actor, action, entity, entity_id, detail)
  values (p_business, v_actor, 'SV_PAUSE_LIFTED', 'sv_pauses', v_id, jsonb_build_object(
    'asset', v_asset, 'scope', p_scope, 'pause_id', v_id, 'reason', v_reason));
  return jsonb_build_object('status', 'ok', 'business_id', p_business, 'asset', v_asset,
    'scope', p_scope, 'lifted', true, 'pause_id', v_id, 'replayed', false);
end $$;
revoke all on function public.sv_lift_pause(uuid, text, text, text) from public, anon, authenticated;
grant execute on function public.sv_lift_pause(uuid, text, text, text) to authenticated;

-- =====================================================================
-- 5. THE TEETH - the Increment-A/C value RPCs, CREATE OR REPLACE'd adding ONLY the pause gate.
--    Each body below is BYTE-IDENTICAL to its v61/v63 predecessor except for the single inserted
--    guard block (a predecessor diff shows only the addition). The v63 sv_not_live gate is
--    preserved as the FIRST check; the pause gate is the SECOND, independent gate.
-- =====================================================================

-- 5a. public.sv_topup (v61) + earn pause gate.
create or replace function public.sv_topup(
  p_business uuid, p_client uuid, p_plan_version uuid, p_idempotency_key uuid)
returns jsonb language plpgsql security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_actor uuid := auth.uid();
  v_hash text;
  v_existing public.sv_operations%rowtype;
  v_pv public.sv_plan_versions%rowtype;
  v_state text;
  v_account uuid;
  v_op uuid := gen_random_uuid();
  v_paid_lot uuid := gen_random_uuid();
  v_bonus_lot uuid;
  v_paid_seq bigint;
  v_bonus_seq bigint;
  v_paid_expiry timestamptz;
  v_bonus_expiry timestamptz;
  v_result jsonb;
begin
  if not app.is_salon_owner(p_business) then
    raise exception 'owner only' using errcode = '42501';
  end if;
  if p_idempotency_key is null then
    raise exception 'a stored-value top-up idempotency key is required' using errcode = '22023';
  end if;

  -- Canonical request: business + client + plan version. A different plan version or client
  -- under the same key is a hash conflict -> fail closed.
  v_hash := app.ps1b_sha256(jsonb_build_object(
    'op', 'topup', 'business_id', p_business, 'client_id', p_client,
    'plan_version_id', p_plan_version)::text);

  perform pg_advisory_xact_lock(hashtextextended(
    'v61:sv_topup:' || p_business::text || ':' || p_idempotency_key::text, 0));

  select * into v_existing from public.sv_operations o
   where o.business_id = p_business and o.operation_type = 'topup' and o.idempotency_key = p_idempotency_key
   for update;
  if found then
    if v_existing.request_hash <> v_hash then
      raise exception 'idempotency key conflicts with a different stored-value top-up' using errcode = '22023';
    end if;
    return v_existing.result;
  end if;

  -- Validate the plan version belongs to this business (BEFORE any write, so a bad reference
  -- leaves no op/lot/movement row - the whole function is one statement in the caller txn).
  select * into v_pv from public.sv_plan_versions
   where id = p_plan_version and business_id = p_business;
  if not found then
    raise exception 'stored-value plan version does not belong to this business' using errcode = '22023';
  end if;
  if not exists (select 1 from public.clients c where c.id = p_client and c.business_id = p_business) then
    raise exception 'stored-value top-up client does not belong to this business' using errcode = '22023';
  end if;

  -- Authority earn gate (sv_pauses arrives in Increment D). unbuilt/shadow_testing/
  -- reconciliation_blocked/ready_for_cutover all permit minting into the shadow ledger;
  -- paused/retired refuse. A missing row fails closed to refuse.
  select state into v_state from public.sv_authority
   where business_id = p_business and asset = 'stored_value';
  if v_state is null then
    raise exception 'stored-value authority is not initialised for this business' using errcode = '22023';
  end if;
  if v_state in ('paused', 'retired') then
    raise exception 'stored-value earning is % for this business', v_state using errcode = '22023';
  end if;

  -- PS-2A Increment D pause gate (contract D §1/§8): an active 'all' or 'earn' sv_pause blocks
  -- new earns. This block is the ONLY addition over the v61 body; everything else is byte-identical.
  if app.sv_pause_active(p_business, 'stored_value', 'earn') then
    raise exception 'sv_paused: stored-value earns are paused' using errcode = '22023';
  end if;

  v_account := app.sv_ensure_account(p_business, p_client);

  -- Expiry computed per class independently from the plan snapshot (same term here, stored
  -- as its own key on each lot so a future differential-expiry plan and the expiry sweep
  -- treat paid and bonus independently - PS-0 expiry independence).
  v_paid_expiry := case when v_pv.expiry_days is null then null
                        else now() + (v_pv.expiry_days || ' days')::interval end;
  v_bonus_expiry := case when v_pv.expiry_days is null then null
                         else now() + (v_pv.expiry_days || ' days')::interval end;
  v_paid_seq := nextval('app.sv_earned_seq');

  -- Build the cached result FIRST (lot ids pre-generated) so the op row stores it once and
  -- an identical retry replays it verbatim.
  if v_pv.bonus_cents > 0 then
    v_bonus_lot := gen_random_uuid();
    v_bonus_seq := nextval('app.sv_earned_seq');
  end if;

  v_result := jsonb_build_object(
    'status', 'ok',
    'operation_id', v_op,
    'account_id', v_account,
    'asset', 'stored_value',
    'plan_version_id', p_plan_version,
    'paid_lot', jsonb_build_object(
      'lot_id', v_paid_lot, 'class', 'paid', 'minted_cents', v_pv.price_cents,
      'expiry_key', v_paid_expiry, 'earned_seq', v_paid_seq),
    'bonus_lot', case when v_pv.bonus_cents > 0 then jsonb_build_object(
      'lot_id', v_bonus_lot, 'class', 'bonus', 'minted_cents', v_pv.bonus_cents,
      'expiry_key', v_bonus_expiry, 'earned_seq', v_bonus_seq) else null end,
    'minted', jsonb_build_object(
      'paid_cents', v_pv.price_cents, 'bonus_cents', v_pv.bonus_cents,
      'total_cents', v_pv.price_cents + v_pv.bonus_cents));

  insert into public.sv_operations(id, business_id, operation_type, idempotency_key, request_hash, actor, result)
  values (v_op, p_business, 'topup', p_idempotency_key, v_hash, v_actor, v_result);

  insert into public.sv_lots(id, business_id, account_id, operation_id, class, minted_cents, expiry_key, earned_seq, plan_version_id)
  values (v_paid_lot, p_business, v_account, v_op, 'paid', v_pv.price_cents, v_paid_expiry, v_paid_seq, p_plan_version);
  insert into public.sv_lot_movements(business_id, account_id, lot_id, operation_id, kind, cents)
  values (p_business, v_account, v_paid_lot, v_op, 'issue', v_pv.price_cents);

  if v_pv.bonus_cents > 0 then
    insert into public.sv_lots(id, business_id, account_id, operation_id, class, minted_cents, expiry_key, earned_seq, plan_version_id)
    values (v_bonus_lot, p_business, v_account, v_op, 'bonus', v_pv.bonus_cents, v_bonus_expiry, v_bonus_seq, p_plan_version);
    insert into public.sv_lot_movements(business_id, account_id, lot_id, operation_id, kind, cents)
    values (p_business, v_account, v_bonus_lot, v_op, 'issue', v_pv.bonus_cents);
  end if;

  insert into public.audit_log(business_id, actor, action, entity, entity_id, detail)
  values (p_business, v_actor, 'SV_TOPUP', 'sv_accounts', v_account, jsonb_build_object(
    'operation_id', v_op, 'plan_version_id', p_plan_version,
    'paid_cents', v_pv.price_cents, 'bonus_cents', v_pv.bonus_cents));

  return v_result;
end $$;
revoke all on function public.sv_topup(uuid, uuid, uuid, uuid) from public, anon, authenticated;
grant execute on function public.sv_topup(uuid, uuid, uuid, uuid) to authenticated;

-- 5b. public.sv_grant (v61) + earn pause gate.
create or replace function public.sv_grant(
  p_business uuid, p_client uuid, p_cents int, p_reason text, p_idempotency_key uuid)
returns jsonb language plpgsql security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_actor uuid := auth.uid();
  v_reason text := btrim(coalesce(p_reason, ''));
  v_hash text;
  v_existing public.sv_operations%rowtype;
  v_state text;
  v_account uuid;
  v_op uuid := gen_random_uuid();
  v_lot uuid := gen_random_uuid();
  v_seq bigint;
  v_result jsonb;
begin
  if not app.is_salon_owner(p_business) then
    raise exception 'owner only' using errcode = '42501';
  end if;
  if p_idempotency_key is null then
    raise exception 'a stored-value grant idempotency key is required' using errcode = '22023';
  end if;
  if p_cents is null or p_cents < 1 then
    raise exception 'a stored-value grant must be a whole number of at least 1 cent' using errcode = '22023';
  end if;
  if char_length(v_reason) < 3 then
    raise exception 'a stored-value grant requires a reason of at least 3 characters' using errcode = '22023';
  end if;

  v_hash := app.ps1b_sha256(jsonb_build_object(
    'op', 'grant', 'business_id', p_business, 'client_id', p_client,
    'cents', p_cents, 'reason', v_reason)::text);

  perform pg_advisory_xact_lock(hashtextextended(
    'v61:sv_grant:' || p_business::text || ':' || p_idempotency_key::text, 0));

  select * into v_existing from public.sv_operations o
   where o.business_id = p_business and o.operation_type = 'grant' and o.idempotency_key = p_idempotency_key
   for update;
  if found then
    if v_existing.request_hash <> v_hash then
      raise exception 'idempotency key conflicts with a different stored-value grant' using errcode = '22023';
    end if;
    return v_existing.result;
  end if;

  if not exists (select 1 from public.clients c where c.id = p_client and c.business_id = p_business) then
    raise exception 'stored-value grant client does not belong to this business' using errcode = '22023';
  end if;
  select state into v_state from public.sv_authority
   where business_id = p_business and asset = 'stored_value';
  if v_state is null then
    raise exception 'stored-value authority is not initialised for this business' using errcode = '22023';
  end if;
  if v_state in ('paused', 'retired') then
    raise exception 'stored-value earning is % for this business', v_state using errcode = '22023';
  end if;

  -- PS-2A Increment D pause gate (contract D §1/§8): an active 'all' or 'earn' sv_pause blocks
  -- new earns. This block is the ONLY addition over the v61 body; everything else is byte-identical.
  if app.sv_pause_active(p_business, 'stored_value', 'earn') then
    raise exception 'sv_paused: stored-value earns are paused' using errcode = '22023';
  end if;

  v_account := app.sv_ensure_account(p_business, p_client);
  v_seq := nextval('app.sv_earned_seq');
  v_result := jsonb_build_object(
    'status', 'ok',
    'operation_id', v_op,
    'account_id', v_account,
    'asset', 'stored_value',
    'bonus_lot', jsonb_build_object(
      'lot_id', v_lot, 'class', 'bonus', 'minted_cents', p_cents,
      'expiry_key', null, 'earned_seq', v_seq),
    'minted', jsonb_build_object('paid_cents', 0, 'bonus_cents', p_cents, 'total_cents', p_cents),
    'reason', v_reason);

  insert into public.sv_operations(id, business_id, operation_type, idempotency_key, request_hash, actor, result)
  values (v_op, p_business, 'grant', p_idempotency_key, v_hash, v_actor, v_result);
  insert into public.sv_lots(id, business_id, account_id, operation_id, class, minted_cents, expiry_key, earned_seq, plan_version_id)
  values (v_lot, p_business, v_account, v_op, 'bonus', p_cents, null, v_seq, null);
  insert into public.sv_lot_movements(business_id, account_id, lot_id, operation_id, kind, cents)
  values (p_business, v_account, v_lot, v_op, 'issue', p_cents);
  insert into public.audit_log(business_id, actor, action, entity, entity_id, detail)
  values (p_business, v_actor, 'SV_GRANT', 'sv_accounts', v_account, jsonb_build_object(
    'operation_id', v_op, 'cents', p_cents, 'reason', v_reason));

  return v_result;
end $$;
revoke all on function public.sv_grant(uuid, uuid, integer, text, uuid) from public, anon, authenticated;
grant execute on function public.sv_grant(uuid, uuid, integer, text, uuid) to authenticated;

-- 5c. public.sv_reserve (v63) + redeem pause gate.
create or replace function public.sv_reserve(
  p_business uuid, p_account uuid, p_cents integer, p_idempotency_key uuid)
returns jsonb language plpgsql security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_actor uuid := auth.uid();
  v_hash text;
  v_existing public.sv_operations%rowtype;
  v_op uuid := gen_random_uuid();
  v_res uuid := gen_random_uuid();
  v_available integer;
  v_result jsonb;
begin
  if not app.is_salon_owner(p_business) then
    raise exception 'owner only' using errcode = '42501';
  end if;
  -- HARD SAFETY GATE: value only moves when stored value is the authority (unreachable in PS-2A).
  if coalesce((select state from public.sv_authority
                where business_id = p_business and asset = 'stored_value'), 'unbuilt') <> 'live' then
    raise exception 'sv_not_live: stored value is not the authority for this business' using errcode = '22023';
  end if;

  -- PS-2A Increment D pause gate (SECOND gate, independent of the sv_not_live gate above;
  -- contract D §1/§8): an active 'all' or 'redeem' sv_pause blocks spends/reservations. An 'earn'
  -- pause deliberately does NOT block spend. This block is the ONLY addition over the v63 body.
  if app.sv_pause_active(p_business, 'stored_value', 'redeem') then
    raise exception 'sv_paused: stored-value redemptions are paused' using errcode = '22023';
  end if;
  if p_idempotency_key is null then
    raise exception 'a stored-value reserve idempotency key is required' using errcode = '22023';
  end if;
  if p_cents is null or p_cents < 1 then
    raise exception 'a stored-value reserve must be a whole number of at least 1 cent' using errcode = '22023';
  end if;
  if not exists (select 1 from public.sv_accounts a where a.id = p_account and a.business_id = p_business) then
    raise exception 'stored-value account does not belong to this business' using errcode = '22023';
  end if;

  perform pg_advisory_xact_lock(hashtextextended('v63:sv_acct:' || p_business::text || ':' || p_account::text, 0));
  perform pg_advisory_xact_lock(hashtextextended('v63:sv_reserve:' || p_business::text || ':' || p_idempotency_key::text, 0));

  select * into v_existing from public.sv_operations o
   where o.business_id = p_business and o.operation_type = 'reserve' and o.idempotency_key = p_idempotency_key
   for update;
  v_hash := app.ps1b_sha256(jsonb_build_object(
    'op', 'reserve', 'business_id', p_business, 'account_id', p_account, 'cents', p_cents)::text);
  if found then
    if v_existing.request_hash <> v_hash then
      raise exception 'idempotency key conflicts with a different stored-value reserve' using errcode = '22023';
    end if;
    return v_existing.result;
  end if;

  v_available := app.sv_available_balance(p_business, p_account);
  if p_cents > v_available then
    raise exception 'insufficient stored value to reserve (% requested, % available)', p_cents, v_available
      using errcode = '22023';
  end if;

  v_result := jsonb_build_object(
    'status', 'ok', 'operation_id', v_op, 'reservation_id', v_res, 'account_id', p_account,
    'amount_cents', p_cents, 'reservation_status', 'active',
    'available_after_cents', v_available - p_cents);

  insert into public.sv_operations(id, business_id, operation_type, idempotency_key, request_hash, actor, result)
  values (v_op, p_business, 'reserve', p_idempotency_key, v_hash, v_actor, v_result);
  insert into public.sv_reservations(id, business_id, account_id, operation_id, amount_cents, status)
  values (v_res, p_business, p_account, v_op, p_cents, 'active');
  insert into public.audit_log(business_id, actor, action, entity, entity_id, detail)
  values (p_business, v_actor, 'SV_RESERVE', 'sv_reservations', v_res, jsonb_build_object(
    'operation_id', v_op, 'account_id', p_account, 'amount_cents', p_cents));

  return v_result;
end $$;
revoke all on function public.sv_reserve(uuid, uuid, integer, uuid) from public, anon, authenticated;
grant execute on function public.sv_reserve(uuid, uuid, integer, uuid) to authenticated;

-- 5d. public.sv_spend (v63) + redeem pause gate. NOTE: an 'earn' pause does NOT reach here
--     (family 'redeem'), so customers keep spending held value under an earn pause (contract §8).
create or replace function public.sv_spend(
  p_business uuid, p_account uuid, p_cents integer, p_idempotency_key uuid)
returns jsonb language plpgsql security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_actor uuid := auth.uid();
  v_hash text;
  v_existing public.sv_operations%rowtype;
  v_op uuid := gen_random_uuid();
  v_available integer;
  v_plan jsonb;
  v_entry jsonb;
  v_result jsonb;
begin
  if not app.is_salon_owner(p_business) then
    raise exception 'owner only' using errcode = '42501';
  end if;
  if coalesce((select state from public.sv_authority
                where business_id = p_business and asset = 'stored_value'), 'unbuilt') <> 'live' then
    raise exception 'sv_not_live: stored value is not the authority for this business' using errcode = '22023';
  end if;

  -- PS-2A Increment D pause gate (SECOND gate, independent of the sv_not_live gate above;
  -- contract D §1/§8): an active 'all' or 'redeem' sv_pause blocks spends/reservations. An 'earn'
  -- pause deliberately does NOT block spend. This block is the ONLY addition over the v63 body.
  if app.sv_pause_active(p_business, 'stored_value', 'redeem') then
    raise exception 'sv_paused: stored-value redemptions are paused' using errcode = '22023';
  end if;
  if p_idempotency_key is null then
    raise exception 'a stored-value spend idempotency key is required' using errcode = '22023';
  end if;
  if p_cents is null or p_cents < 1 then
    raise exception 'a stored-value spend must be a whole number of at least 1 cent' using errcode = '22023';
  end if;
  if not exists (select 1 from public.sv_accounts a where a.id = p_account and a.business_id = p_business) then
    raise exception 'stored-value account does not belong to this business' using errcode = '22023';
  end if;

  perform pg_advisory_xact_lock(hashtextextended('v63:sv_acct:' || p_business::text || ':' || p_account::text, 0));
  perform pg_advisory_xact_lock(hashtextextended('v63:sv_spend:' || p_business::text || ':' || p_idempotency_key::text, 0));

  select * into v_existing from public.sv_operations o
   where o.business_id = p_business and o.operation_type = 'spend' and o.idempotency_key = p_idempotency_key
   for update;
  v_hash := app.ps1b_sha256(jsonb_build_object(
    'op', 'spend', 'business_id', p_business, 'account_id', p_account, 'cents', p_cents)::text);
  if found then
    if v_existing.request_hash <> v_hash then
      raise exception 'idempotency key conflicts with a different stored-value spend' using errcode = '22023';
    end if;
    return v_existing.result;   -- duplicate spend, same key -> ONE effect, replayed result
  end if;

  -- Deterministic FEFO row locks over the accounts lot set (one-winner; the fresh READ COMMITTED
  -- snapshot after the advisory lock + these locks sees a concurrent winning transaction committed movements).
  perform 1 from public.sv_lots l
   where l.business_id = p_business and l.account_id = p_account
   order by l.expiry_key asc nulls last, l.earned_seq asc, l.id asc
   for update;

  v_available := app.sv_available_balance(p_business, p_account);
  if p_cents > v_available then
    raise exception 'insufficient stored value to spend (% requested, % available)', p_cents, v_available
      using errcode = '22023';   -- refuse BEFORE any write: no partial movement
  end if;

  v_plan := app.sv_allocate_spend(p_business, p_account, p_cents);
  if (v_plan->>'ok')::boolean is not true then
    raise exception 'stored-value allocation failed: %', coalesce(v_plan->>'reason', 'unknown') using errcode = '22023';
  end if;

  v_result := jsonb_build_object(
    'status', 'ok', 'operation_id', v_op, 'account_id', p_account, 'spend_cents', p_cents,
    'paid_draw_cents', (v_plan->>'paid_draw')::int, 'bonus_draw_cents', (v_plan->>'bonus_draw')::int,
    'plan', v_plan->'plan', 'available_after_cents', v_available - p_cents);

  insert into public.sv_operations(id, business_id, operation_type, idempotency_key, request_hash, actor, result)
  values (v_op, p_business, 'spend', p_idempotency_key, v_hash, v_actor, v_result);
  for v_entry in select * from jsonb_array_elements(v_plan->'plan') loop
    insert into public.sv_lot_movements(business_id, account_id, lot_id, operation_id, kind, cents)
    values (p_business, p_account, (v_entry->>'lot_id')::uuid, v_op, 'spend', (v_entry->>'cents')::int);
  end loop;
  insert into public.audit_log(business_id, actor, action, entity, entity_id, detail)
  values (p_business, v_actor, 'SV_SPEND', 'sv_accounts', p_account, jsonb_build_object(
    'operation_id', v_op, 'spend_cents', p_cents,
    'paid_draw_cents', (v_plan->>'paid_draw')::int, 'bonus_draw_cents', (v_plan->>'bonus_draw')::int));

  return v_result;
end $$;
revoke all on function public.sv_spend(uuid, uuid, integer, uuid) from public, anon, authenticated;
grant execute on function public.sv_spend(uuid, uuid, integer, uuid) to authenticated;

-- 5e. public.sv_reverse_spend (v63) + redeem pause gate (a reversal is a redeem-side correction).
create or replace function public.sv_reverse_spend(
  p_business uuid, p_spend_operation uuid, p_idempotency_key uuid)
returns jsonb language plpgsql security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_actor uuid := auth.uid();
  v_hash text;
  v_existing public.sv_operations%rowtype;
  v_op uuid := gen_random_uuid();
  v_account uuid;
  v_spend_type text;
  v_restored jsonb := '[]'::jsonb;
  v_restored_total bigint := 0;
  v_reexpired_total bigint := 0;
  m record;
  v_amt bigint;
  v_expiry timestamptz;
  v_reexpired boolean;
  v_result jsonb;
begin
  if not app.is_salon_owner(p_business) then
    raise exception 'owner only' using errcode = '42501';
  end if;
  if coalesce((select state from public.sv_authority
                where business_id = p_business and asset = 'stored_value'), 'unbuilt') <> 'live' then
    raise exception 'sv_not_live: stored value is not the authority for this business' using errcode = '22023';
  end if;

  -- PS-2A Increment D pause gate (contract D §1: a reversal of a spend is a redeem-side
  -- correction, so an active 'all' or 'redeem' sv_pause blocks it). Second gate, independent of
  -- sv_not_live; this block is the ONLY addition over the v63 body.
  if app.sv_pause_active(p_business, 'stored_value', 'redeem') then
    raise exception 'sv_paused: stored-value redemptions are paused' using errcode = '22023';
  end if;
  if p_idempotency_key is null then
    raise exception 'a stored-value reverse idempotency key is required' using errcode = '22023';
  end if;

  -- The spend operation must exist, be a 'spend', and belong to this business.
  select o.operation_type into v_spend_type from public.sv_operations o
   where o.id = p_spend_operation and o.business_id = p_business;
  if v_spend_type is null then
    raise exception 'stored-value spend operation not found in this business' using errcode = '22023';
  end if;
  if v_spend_type <> 'spend' then
    raise exception 'stored-value reverse target is not a spend operation' using errcode = '22023';
  end if;

  select account_id into v_account from public.sv_lot_movements
   where business_id = p_business and operation_id = p_spend_operation and kind = 'spend'
   order by id limit 1;
  if v_account is null then
    raise exception 'stored-value spend operation wrote no spend movements to reverse' using errcode = '22023';
  end if;

  perform pg_advisory_xact_lock(hashtextextended('v63:sv_acct:' || p_business::text || ':' || v_account::text, 0));
  perform pg_advisory_xact_lock(hashtextextended('v63:sv_reverse:' || p_business::text || ':' || p_idempotency_key::text, 0));

  select * into v_existing from public.sv_operations o
   where o.business_id = p_business and o.operation_type = 'reverse' and o.idempotency_key = p_idempotency_key
   for update;
  v_hash := app.ps1b_sha256(jsonb_build_object(
    'op', 'reverse', 'business_id', p_business, 'spend_operation_id', p_spend_operation)::text);
  if found then
    if v_existing.request_hash <> v_hash then
      raise exception 'idempotency key conflicts with a different stored-value reverse' using errcode = '22023';
    end if;
    return v_existing.result;   -- same key -> idempotent replay
  end if;

  -- BOUND: a spend op is reversed at most once. Any prior reverse of THIS spend op (under a
  -- different key) is over-reversal -> fail.
  if exists (
    select 1 from public.sv_operations o
     where o.business_id = p_business and o.operation_type = 'reverse'
       and o.result->>'spend_operation_id' = p_spend_operation::text) then
    raise exception 'stored-value spend operation is already reversed (over-reversal refused)' using errcode = '22023';
  end if;

  -- Compute the restore-then-expire plan FIRST (sv_operations is append-only/immutable, so the
  -- op row must be inserted ONCE with its final result before the movements it anchors).
  for m in
    select mv.lot_id, mv.cents
      from public.sv_lot_movements mv
     where mv.business_id = p_business and mv.operation_id = p_spend_operation and mv.kind = 'spend'
     order by mv.id
  loop
    v_amt := -m.cents;   -- positive restore amount
    if v_amt <= 0 then continue; end if;
    v_restored_total := v_restored_total + v_amt;
    select expiry_key into v_expiry from public.sv_lots where id = m.lot_id and business_id = p_business;
    v_reexpired := (v_expiry is not null and v_expiry <= now());
    if v_reexpired then
      v_reexpired_total := v_reexpired_total + v_amt;
    end if;
    v_restored := v_restored || jsonb_build_array(jsonb_build_object(
      'lot_id', m.lot_id, 'restored_cents', v_amt::int, 're_expired', v_reexpired));
  end loop;

  v_result := jsonb_build_object(
    'status', 'ok', 'operation_id', v_op, 'spend_operation_id', p_spend_operation, 'account_id', v_account,
    'restored_cents', v_restored_total::int, 're_expired_cents', v_reexpired_total::int,
    'net_restored_cents', (v_restored_total - v_reexpired_total)::int, 'restored', v_restored);

  insert into public.sv_operations(id, business_id, operation_type, idempotency_key, request_hash, actor, result)
  values (v_op, p_business, 'reverse', p_idempotency_key, v_hash, v_actor, v_result);

  -- Apply: a 'reversal' (+) per lot, immediately followed by a '-expiry' when the restored lot
  -- is now past its expiry_key (restore-then-expire; an expired lot is never silently resurrected).
  for m in
    select mv.lot_id, mv.cents
      from public.sv_lot_movements mv
     where mv.business_id = p_business and mv.operation_id = p_spend_operation and mv.kind = 'spend'
     order by mv.id
  loop
    v_amt := -m.cents;
    if v_amt <= 0 then continue; end if;
    insert into public.sv_lot_movements(business_id, account_id, lot_id, operation_id, kind, cents)
    values (p_business, v_account, m.lot_id, v_op, 'reversal', v_amt::int);
    select expiry_key into v_expiry from public.sv_lots where id = m.lot_id and business_id = p_business;
    if v_expiry is not null and v_expiry <= now() then
      insert into public.sv_lot_movements(business_id, account_id, lot_id, operation_id, kind, cents)
      values (p_business, v_account, m.lot_id, v_op, 'expiry', (-v_amt)::int);
    end if;
  end loop;

  insert into public.audit_log(business_id, actor, action, entity, entity_id, detail)
  values (p_business, v_actor, 'SV_REVERSE_SPEND', 'sv_accounts', v_account, jsonb_build_object(
    'operation_id', v_op, 'spend_operation_id', p_spend_operation,
    'restored_cents', v_restored_total::int, 're_expired_cents', v_reexpired_total::int));

  return v_result;
end $$;
revoke all on function public.sv_reverse_spend(uuid, uuid, uuid) from public, anon, authenticated;
grant execute on function public.sv_reverse_spend(uuid, uuid, uuid) to authenticated;

-- 5f. public.refund_sv_operation (v63) + earn pause gate (a refund is an earn-side cash return).
create or replace function public.refund_sv_operation(
  p_business uuid, p_topup_operation uuid, p_cash_cents integer, p_idempotency_key uuid)
returns jsonb language plpgsql security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_actor uuid := auth.uid();
  v_hash text;
  v_existing public.sv_operations%rowtype;
  v_op uuid := gen_random_uuid();
  v_account uuid;
  v_topup_type text;
  v_plan jsonb;
  v_entry jsonb;
  v_result jsonb;
begin
  if not app.is_salon_owner(p_business) then
    raise exception 'owner only' using errcode = '42501';
  end if;
  if coalesce((select state from public.sv_authority
                where business_id = p_business and asset = 'stored_value'), 'unbuilt') <> 'live' then
    raise exception 'sv_not_live: stored value is not the authority for this business' using errcode = '22023';
  end if;

  -- PS-2A Increment D pause gate (contract D §1: a refund returns customer cash = an earn-side
  -- correction, so an active 'all' or 'earn' sv_pause blocks it). Second gate, independent of
  -- sv_not_live; this block is the ONLY addition over the v63 body.
  if app.sv_pause_active(p_business, 'stored_value', 'earn') then
    raise exception 'sv_paused: stored-value earns are paused' using errcode = '22023';
  end if;
  if p_idempotency_key is null then
    raise exception 'a stored-value refund idempotency key is required' using errcode = '22023';
  end if;

  select o.operation_type into v_topup_type from public.sv_operations o
   where o.id = p_topup_operation and o.business_id = p_business;
  if v_topup_type is null then
    raise exception 'stored-value top-up operation not found in this business' using errcode = '22023';
  end if;

  select account_id into v_account from public.sv_lots
   where business_id = p_business and operation_id = p_topup_operation and class = 'paid'
   order by earned_seq asc, id asc limit 1;
  if v_account is null then
    raise exception 'stored-value operation has no paid lot to refund' using errcode = '22023';
  end if;

  perform pg_advisory_xact_lock(hashtextextended('v63:sv_acct:' || p_business::text || ':' || v_account::text, 0));
  perform pg_advisory_xact_lock(hashtextextended('v63:sv_refund:' || p_business::text || ':' || p_idempotency_key::text, 0));

  select * into v_existing from public.sv_operations o
   where o.business_id = p_business and o.operation_type = 'refund' and o.idempotency_key = p_idempotency_key
   for update;
  v_hash := app.ps1b_sha256(jsonb_build_object(
    'op', 'refund', 'business_id', p_business, 'topup_operation_id', p_topup_operation,
    'cash_cents', p_cash_cents)::text);
  if found then
    if v_existing.request_hash <> v_hash then
      raise exception 'idempotency key conflicts with a different stored-value refund' using errcode = '22023';
    end if;
    return v_existing.result;
  end if;

  -- FEFO row locks over the operations lots (one-winner vs a concurrent spend on the same account).
  perform 1 from public.sv_lots l
   where l.business_id = p_business and l.account_id = v_account
   order by l.expiry_key asc nulls last, l.earned_seq asc, l.id asc
   for update;

  v_plan := app.sv_plan_refund(p_business, p_topup_operation, p_cash_cents);
  if (v_plan->>'ok')::boolean is not true then
    raise exception 'stored-value refund failed: %', coalesce(v_plan->>'reason', 'unknown') using errcode = '22023';
  end if;

  v_result := jsonb_build_object(
    'status', 'ok', 'operation_id', v_op, 'topup_operation_id', p_topup_operation, 'account_id', v_account,
    'cash_cents', (v_plan->>'cash_cents')::int, 'clawback_cents', (v_plan->>'clawback_cents')::int,
    'final', (v_plan->>'final')::boolean, 'plan', v_plan->'plan');

  insert into public.sv_operations(id, business_id, operation_type, idempotency_key, request_hash, actor, result)
  values (v_op, p_business, 'refund', p_idempotency_key, v_hash, v_actor, v_result);
  for v_entry in select * from jsonb_array_elements(v_plan->'plan') loop
    insert into public.sv_lot_movements(business_id, account_id, lot_id, operation_id, kind, cents)
    values (p_business, v_account, (v_entry->>'lot_id')::uuid, v_op, v_entry->>'kind', (v_entry->>'cents')::int);
  end loop;
  insert into public.audit_log(business_id, actor, action, entity, entity_id, detail)
  values (p_business, v_actor, 'SV_REFUND', 'sv_accounts', v_account, jsonb_build_object(
    'operation_id', v_op, 'topup_operation_id', p_topup_operation,
    'cash_cents', (v_plan->>'cash_cents')::int, 'clawback_cents', (v_plan->>'clawback_cents')::int));

  return v_result;
end $$;
revoke all on function public.refund_sv_operation(uuid, uuid, integer, uuid) from public, anon, authenticated;
grant execute on function public.refund_sv_operation(uuid, uuid, integer, uuid) to authenticated;

-- 5g. public.sv_expire_due (v63) + all-only pause gate (the expiry sweep is a system operation).
create or replace function public.sv_expire_due(p_business uuid, p_limit integer default 1000)
returns jsonb language plpgsql security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_actor uuid := auth.uid();
  v_op uuid := gen_random_uuid();
  v_limit integer := least(greatest(coalesce(p_limit, 1000), 1), 100000);
  v_acc uuid;
  l record;
  v_rem integer;
  v_expired_lots integer := 0;
  v_expired_cents bigint := 0;
  v_details jsonb := '[]'::jsonb;
begin
  if not app.is_salon_owner(p_business) then
    raise exception 'owner only' using errcode = '42501';
  end if;
  if coalesce((select state from public.sv_authority
                where business_id = p_business and asset = 'stored_value'), 'unbuilt') <> 'live' then
    raise exception 'sv_not_live: stored value is not the authority for this business' using errcode = '22023';
  end if;

  -- PS-2A Increment D pause gate (contract D §1: expiry is a system sweep, not an earn or a
  -- redeem, so ONLY an 'all' sv_pause blocks it). Second gate, independent of sv_not_live;
  -- this block is the ONLY addition over the v63 body.
  if app.sv_pause_active(p_business, 'stored_value', 'all_only') then
    raise exception 'sv_paused: stored value is paused' using errcode = '22023';
  end if;

  -- Serialize per touched account (ascending order -> deadlock-free vs per-account spend locks).
  for v_acc in
    select distinct l2.account_id from public.sv_lots l2
     where l2.business_id = p_business and l2.expiry_key is not null and l2.expiry_key <= now()
     order by l2.account_id
  loop
    perform pg_advisory_xact_lock(hashtextextended('v63:sv_acct:' || p_business::text || ':' || v_acc::text, 0));
  end loop;

  -- Compute the sweep plan under FOR UPDATE row locks (sv_operations is append-only, so the anchor
  -- op is inserted ONCE with its final result). Locking the candidate lots holds them for the txn.
  for l in
    select ll.id as lot_id, ll.account_id
      from public.sv_lots ll
     where ll.business_id = p_business and ll.expiry_key is not null and ll.expiry_key <= now()
     order by ll.account_id, ll.expiry_key asc, ll.earned_seq asc, ll.id asc
     for update
  loop
    exit when v_expired_lots >= v_limit;
    v_rem := app.sv_lot_remaining(l.lot_id);
    if v_rem is null or v_rem <= 0 then continue; end if;   -- spent / already-expired -> skip
    v_expired_lots := v_expired_lots + 1;
    v_expired_cents := v_expired_cents + v_rem;
    v_details := v_details || jsonb_build_array(jsonb_build_object(
      'lot_id', l.lot_id, 'account_id', l.account_id, 'expired_cents', v_rem));
  end loop;

  insert into public.sv_operations(id, business_id, operation_type, idempotency_key, request_hash, actor, result)
  values (v_op, p_business, 'expire', gen_random_uuid(),
    app.ps1b_sha256(jsonb_build_object('op', 'expire', 'business_id', p_business, 'at', now())::text),
    v_actor, jsonb_build_object('status', 'ok', 'expired_lots', v_expired_lots,
      'expired_cents', v_expired_cents::int, 'details', v_details));

  for l in select value from jsonb_array_elements(v_details) as t(value) loop
    insert into public.sv_lot_movements(business_id, account_id, lot_id, operation_id, kind, cents)
    values (p_business, (l.value->>'account_id')::uuid, (l.value->>'lot_id')::uuid, v_op, 'expiry',
      (-(l.value->>'expired_cents')::int)::int);
  end loop;

  if v_expired_lots > 0 then
    insert into public.audit_log(business_id, actor, action, entity, entity_id, detail)
    values (p_business, v_actor, 'SV_EXPIRE_SWEEP', 'sv_accounts', v_op, jsonb_build_object(
      'operation_id', v_op, 'expired_lots', v_expired_lots, 'expired_cents', v_expired_cents::int));
  end if;

  return jsonb_build_object('status', 'ok', 'operation_id', v_op,
    'expired_lots', v_expired_lots, 'expired_cents', v_expired_cents::int, 'details', v_details);
end $$;
revoke all on function public.sv_expire_due(uuid, integer) from public, anon, authenticated;
grant execute on function public.sv_expire_due(uuid, integer) to authenticated;

-- =====================================================================
-- 6. public.get_sv_authority_overview - owner/super-admin read that the D UI renders VERBATIM.
--    Carries the raw authority_state, spendable=(state='live') (always false in PS-2A), the
--    shadow_testing flag, the latest reconciliation summary (has_run/status/discrepancy_count),
--    the ACTIVE pauses (scope/reason/actor/paused_at), and can_cutover HARDCODED false (no
--    cutover action exists). Fail-closed: a missing authority row reads as 'unbuilt'.
-- =====================================================================
create or replace function public.get_sv_authority_overview(p_business uuid)
returns jsonb language plpgsql stable security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_asset text := 'stored_value';
  v_state text;
  v_snapshot public.sv_reconciliation_snapshots%rowtype;
  v_has_run boolean;
  v_pauses jsonb;
begin
  if not (app.is_salon_owner(p_business) or app.is_super_admin()) then
    raise exception 'not permitted to view stored-value authority for this business' using errcode = '42501';
  end if;

  select coalesce(state, 'unbuilt') into v_state from public.sv_authority
   where business_id = p_business and asset = v_asset;
  v_state := coalesce(v_state, 'unbuilt');   -- fail closed if no authority row

  select * into v_snapshot from public.sv_reconciliation_snapshots
   where business_id = p_business and asset = v_asset
   order by captured_at desc, id desc limit 1;
  v_has_run := found;

  select coalesce(jsonb_agg(jsonb_build_object(
      'scope', p.scope, 'reason', p.reason, 'actor', p.actor, 'paused_at', p.paused_at)
      order by p.scope, p.paused_at desc), '[]'::jsonb)
    into v_pauses
    from public.sv_pauses p
   where p.business_id = p_business and p.asset = v_asset and p.lifted_at is null;

  return jsonb_build_object(
    'business_id', p_business,
    'asset', v_asset,
    'authority_state', v_state,
    'spendable', (v_state = 'live'),
    'shadow_testing', (v_state = 'shadow_testing'),
    'reconciliation', jsonb_build_object(
      'has_run', v_has_run,
      'status', case when v_has_run then v_snapshot.status else null end,
      'discrepancy_count', case when v_has_run then v_snapshot.discrepancy_count else 0 end),
    'active_pauses', v_pauses,
    'can_cutover', false);   -- HARDCODED false: no cutover action exists in PS-2A
end $$;
revoke all on function public.get_sv_authority_overview(uuid) from public, anon, authenticated;
grant execute on function public.get_sv_authority_overview(uuid) to authenticated;

-- =====================================================================
-- 7. public.preview_sv_cutover - owner-only read describing what a cutover WOULD require and its
--    current blockers. ready is HARDCODED false (authority can never reach ready_for_cutover in
--    PS-2A, and NO function performs a cutover). blocking_reasons enumerates the real blockers:
--    authority not live, reconciliation not run / not clean, an active all-scope pause, and the
--    standing "cutover is a future authorized phase" gate. This RPC only READS - it moves nothing.
-- =====================================================================
create or replace function public.preview_sv_cutover(p_business uuid)
returns jsonb language plpgsql stable security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_asset text := 'stored_value';
  v_state text;
  v_snapshot public.sv_reconciliation_snapshots%rowtype;
  v_has_run boolean;
  v_rec_status text;
  v_disc int;
  v_reasons jsonb := '[]'::jsonb;
begin
  if not app.is_salon_owner(p_business) then
    raise exception 'owner only' using errcode = '42501';
  end if;

  select coalesce(state, 'unbuilt') into v_state from public.sv_authority
   where business_id = p_business and asset = v_asset;
  v_state := coalesce(v_state, 'unbuilt');   -- fail closed if no authority row

  select * into v_snapshot from public.sv_reconciliation_snapshots
   where business_id = p_business and asset = v_asset
   order by captured_at desc, id desc limit 1;
  v_has_run := found;
  v_rec_status := case when v_has_run then v_snapshot.status else null end;
  v_disc := case when v_has_run then v_snapshot.discrepancy_count else 0 end;

  -- Real blockers. ready is ALWAYS false in PS-2A regardless of these (no cutover action exists).
  if v_state <> 'live' then
    v_reasons := v_reasons || jsonb_build_array(
      'authority is ' || v_state || ' (it must be live to cut over, which is unreachable in PS-2A)');
  end if;
  if not v_has_run then
    v_reasons := v_reasons || jsonb_build_array('reconciliation has not been run');
  elsif v_disc > 0 then
    v_reasons := v_reasons || jsonb_build_array(
      'reconciliation has ' || v_disc || ' open discrepancy(ies); it must be clean');
  end if;
  if app.sv_pause_active(p_business, v_asset, 'all_only') then
    v_reasons := v_reasons || jsonb_build_array('an all-scope stored-value pause is active');
  end if;
  -- Standing blocker: cutover is a future authorized phase; no function performs it.
  v_reasons := v_reasons || jsonb_build_array(
    'cutover is a future authorized phase - no cutover action exists in PS-2A');

  return jsonb_build_object(
    'business_id', p_business,
    'asset', v_asset,
    'authority_state', v_state,
    'reconciliation_status', v_rec_status,
    'discrepancy_count', v_disc,
    'blocking_reasons', v_reasons,
    'ready', false);   -- HARDCODED false: PS-2A ships a preview only, never a cutover action
end $$;
revoke all on function public.preview_sv_cutover(uuid) from public, anon, authenticated;
grant execute on function public.preview_sv_cutover(uuid) to authenticated;

commit;
