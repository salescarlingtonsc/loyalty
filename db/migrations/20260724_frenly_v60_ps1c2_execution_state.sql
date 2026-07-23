-- FRENLY v60 - PROGRAM STUDIO PS-1C.2: TRUTHFUL EXECUTION STATE + EMERGENCY PAUSE
--
-- Local review candidate. Production apply needs the owner's RELEASE APPROVED phrase
-- (CLAUDE.md standing gate). PS-1C is already authorized (docs/design/ps0/PS-GATES.md);
-- this is a truthfulness + control increment ON TOP of the v58/v59 checkout kernel and
-- the v55 authoring surface. It lands NO new financial-execution engine: it derives an
-- honest server-side execution state, adds an emergency-pause control table, and gives
-- that pause TEETH inside the two live studio engines (the checkout kernel plan and the
-- non-checkout executor). No new studio ledger scope; no credit_ledger / points_ledger
-- write; benefit_registry execution AUTHORITY is never mutated.
--
-- THE DEFECT THIS FIXES (real, cross-phase)
--   app.ps1a_studio_rule_state() returned 'ready_for_activation' for EVERY published
--   studio rule. But since PS-1C the checkout + recurring families are studio-
--   authoritative and GENUINELY execute (the kernel applies apply_discount_* discounts
--   synchronously; the executor materialises grant_free_item entitlements). So the owner
--   UI could truthfully read "Ready for activation" for a rule that is ALREADY changing
--   checkout totals. This migration replaces that with a server-derived 9-state model and
--   repoints both callers (get_programs_overview, get_program_rules_draft). The old
--   function is kept (revoked, unused) as history.
--
-- WHAT THIS ADDS
--   1. app.ps1c2_effect_family / app.ps1c2_effect_state - per-effect truth
--      (live | shadow | unbuilt), registry-driven for checkout/recurring/tier;
--      points_loyalty is a documented shadow special case; comms + unknown fail closed
--      to unbuilt. ps1b_effect_family is UNTOUCHED (a dedicated ps1c2 helper adds the
--      comms classification and fails unknown closed).
--   2. app.ps1c2_rule_state - the 9-state aggregate (draft/validation_failed/validated/
--      live/partially_live/shadow_testing/ready_for_activation/paused/retired), including
--      the active-emergency-pause -> paused and superseded -> retired rules.
--   3. get_programs_overview surfaces per-effect 'effect_states' + 'aggregate_state'
--      (and keeps 'execution_state' = the same value for back-compat).
--   4. public.studio_rule_emergency_pauses - a write-once (lift-once) pause table with a
--      one-active-pause-per-(business,rule) partial-unique, plus the owner-only RPCs
--      emergency_pause_studio_rule / lift_emergency_pause (audited).
--   5. ENFORCEMENT (the teeth): app.ps1b_execute_event's compiled-rule loop AND
--      app.ps1c_plan_checkout's candidate-gather loop now SKIP any rule with an active
--      emergency pause. A pause stops NEW effects; it deletes NO historical fulfilment /
--      discount / reservation / audit row.
--   6. public.set_studio_rule_active - the NORMAL, versioned pause/resume: clone the
--      active published config to a draft, flip ONLY this rule's active flag, publish
--      atomically through the existing immutable lifecycle (owner-only, audited).
--   7. public.preview_publish_impact - owner-only publish preview: per-rule + per-effect
--      state_after_publish, financial / customer_facing flags, and the
--      requires_confirmation gate.
--
-- SUPERSEDES the PS-1A "NEVER claim a studio rule is operating" posture FOR the studio-
-- authoritative families ONLY: the states are SERVER-DERIVED truth (the checkout and
-- recurring engines really execute), never a browser-computed label.
--
-- §6 PERMISSION COPY (honest, Option A): custom manually-priced checkout lines are
-- **owner and manager only**. The `custom_price_lines` permission is carried by those two
-- roles (v59 app.role_perms); it is NOT individually owner-grantable to a till operator -
-- granting it means promoting that login to manager. No role_perms change here (docs +
-- header wording only; see docs/design/ps0/CHECKOUT_KERNEL_PATHS.md).

begin;

-- =====================================================================
-- 1. Per-effect FAMILY classifier (ps1c2-local; ps1b_effect_family untouched).
--    Mirrors ps1b_effect_family's checkout/recurring/tier/points_loyalty mapping
--    EXACTLY, adds send_notification -> 'comms', and fails an unknown effect closed
--    to 'unknown' (ps1b_effect_family lumps unknowns into points_loyalty; here they
--    must resolve to 'unbuilt', so they get their own family).
-- =====================================================================
create or replace function app.ps1c2_effect_family(p_effect_type text)
returns text language sql immutable
set search_path to 'pg_catalog', 'pg_temp'
as $$
  select case p_effect_type
    when 'apply_discount_pct'    then 'checkout'
    when 'apply_discount_amount' then 'checkout'
    when 'grant_free_item'       then 'recurring'
    when 'display_perk'          then 'recurring'
    when 'tier_multiplier'       then 'tier'
    when 'grant_credit'          then 'points_loyalty'
    when 'earn_bonus_points'     then 'points_loyalty'
    when 'earn_bonus_stamps'     then 'points_loyalty'
    when 'send_notification'     then 'comms'
    else 'unknown'
  end
$$;
revoke all on function app.ps1c2_effect_family(text) from public, anon, authenticated;

-- =====================================================================
-- 2. Per-effect STATE (live | shadow | unbuilt), derived from the effect's family
--    and that family's actual execution engine TODAY.
--      * checkout/recurring/tier  -> registry cutover_status (studio=live, shadow=shadow,
--        else unbuilt); a missing registry row fails closed to unbuilt.
--      * points_loyalty           -> 'shadow' (executor shadow-logs; the LEGACY trigger
--        stays authoritative; the studio path never posts real points/credit).
--      * comms / unknown          -> 'unbuilt' (no real comms connected; fail closed).
-- =====================================================================
create or replace function app.ps1c2_effect_state(p_business uuid, p_effect_type text)
returns text language plpgsql stable security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare v_family text; v_cut text;
begin
  v_family := app.ps1c2_effect_family(p_effect_type);
  if v_family = 'points_loyalty' then
    return 'shadow';
  elsif v_family in ('comms', 'unknown') then
    return 'unbuilt';
  end if;
  -- checkout / recurring / tier: registry-driven cutover.
  select cutover_status into v_cut from public.benefit_registry
   where business_id = p_business and source_engine = v_family;
  if not found then return 'unbuilt'; end if;   -- fail closed
  return case v_cut
    when 'studio' then 'live'
    when 'shadow' then 'shadow'
    else 'unbuilt'                                -- legacy / unbuilt / rolled_back
  end;
end $$;
revoke all on function app.ps1c2_effect_state(uuid, text) from public, anon, authenticated;

-- Per-effect projection for the owner UI: [{effect_index, effect_type, family, state}].
create or replace function app.ps1c2_rule_effect_states(p_business uuid, p_rule_id uuid)
returns jsonb language plpgsql stable security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare v public.program_rules%rowtype; v_out jsonb;
begin
  select * into v from public.program_rules where id = p_rule_id;
  if not found then return '[]'::jsonb; end if;
  select coalesce(jsonb_agg(jsonb_build_object(
      'effect_index', (t.idx - 1),
      'effect_type', t.e->>'effect_type',
      'family', app.ps1c2_effect_family(t.e->>'effect_type'),
      'state', app.ps1c2_effect_state(p_business, t.e->>'effect_type')
    ) order by t.idx), '[]'::jsonb)
    into v_out
    from jsonb_array_elements(coalesce(v.then_effects, '[]'::jsonb)) with ordinality as t(e, idx);
  return v_out;
end $$;
revoke all on function app.ps1c2_rule_effect_states(uuid, uuid) from public, anon, authenticated;

-- =====================================================================
-- 3. The truthful 9-state aggregate. p_rule_id is the SURROGATE program_rules.id
--    (both callers pass the surrogate id, exactly as ps1a_studio_rule_state did); the
--    logical rule_id spanning versions is read off the row for the emergency-pause check.
-- =====================================================================
create or replace function app.ps1c2_rule_state(
  p_business uuid, p_rule_id uuid, p_config_status text, p_active boolean)
returns text language plpgsql stable security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v public.program_rules%rowtype; v_err text[];
  e jsonb; v_state text; v_n int := 0; v_live int := 0; v_shadow int := 0;
begin
  select * into v from public.program_rules where id = p_rule_id;
  if not found then return 'validation_failed'; end if;

  if p_config_status = 'draft' then
    -- Authoring context: validate the draft rule.
    v_err := app.program_rule_errors(p_business, jsonb_build_object(
      'schema_version', v.schema_version, 'when_event', v.when_event, 'if_conditions', v.if_conditions,
      'then_effects', v.then_effects, 'with_params', v.with_params,
      'during_schedule', v.during_schedule, 'using_stacking', v.using_stacking));
    if coalesce(array_length(v_err, 1), 0) > 0 then return 'validation_failed'; end if;
    if jsonb_array_length(coalesce(v.then_effects, '[]'::jsonb)) = 0 then return 'draft'; end if;
    return 'validated';
  elsif p_config_status = 'abandoned' then
    return 'draft';        -- a thrown-away draft; never activated
  elsif p_config_status = 'superseded' then
    return 'retired';      -- was published, now replaced by a newer published version
  elsif p_config_status = 'published' then
    -- (a) an ACTIVE emergency pause on the logical rule_id wins over everything.
    if exists (select 1 from public.studio_rule_emergency_pauses ep
                where ep.business_id = p_business and ep.rule_id = v.rule_id and ep.lifted_at is null) then
      return 'paused';
    end if;
    -- (b) a normal (versioned) pause.
    if not coalesce(p_active, v.active) then return 'paused'; end if;
    -- (c) derive over the per-effect states.
    for e in select * from jsonb_array_elements(coalesce(v.then_effects, '[]'::jsonb)) loop
      v_n := v_n + 1;
      v_state := app.ps1c2_effect_state(p_business, e->>'effect_type');
      if v_state = 'live' then v_live := v_live + 1;
      elsif v_state = 'shadow' then v_shadow := v_shadow + 1;
      end if;
    end loop;
    if v_n = 0 then return 'validated'; end if;               -- defensive
    if v_live = v_n then return 'live'; end if;
    if v_live > 0 then return 'partially_live'; end if;
    if v_shadow > 0 then return 'shadow_testing'; end if;
    return 'ready_for_activation';                            -- all unbuilt
  end if;
  return 'validated';                                         -- defensive
end $$;
revoke all on function app.ps1c2_rule_state(uuid, uuid, text, boolean) from public, anon, authenticated;

-- =====================================================================
-- 4. studio_rule_emergency_pauses - a write-once (lift-once) control table. A pause
--    stops a live studio rule from producing NEW effects WITHOUT touching the immutable
--    config lifecycle and WITHOUT deleting any historical value row. RLS: owner + super
--    admin READ; browser WRITES revoked (only the definer RPCs write).
--    No composite FK to program_rules(rule_id,business_id) exists (rule_id spans config
--    versions, so it is not unique with business_id); the RPC enforces rule existence.
-- =====================================================================
create table public.studio_rule_emergency_pauses (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  rule_id uuid not null,                       -- LOGICAL rule id (spans config versions)
  actor uuid not null,
  reason text not null check (char_length(btrim(reason)) >= 3),
  paused_at timestamptz not null default now(),
  lifted_at timestamptz,
  lifted_by uuid,
  created_at timestamptz not null default now(),
  constraint studio_rule_emergency_pauses_lift_presence_check check (
    (lifted_at is null) = (lifted_by is null))
);
-- Exactly one ACTIVE pause per (business, rule).
create unique index studio_rule_emergency_pauses_active_uk
  on public.studio_rule_emergency_pauses (business_id, rule_id) where lifted_at is null;
create index studio_rule_emergency_pauses_rule_idx
  on public.studio_rule_emergency_pauses (business_id, rule_id, paused_at);

-- Write-once guard (entitlement-guard pattern): no delete; the identity is immutable;
-- lifted_at/lifted_by are settable exactly ONCE (an already-lifted row is frozen).
create or replace function app.studio_rule_emergency_pauses_guard()
returns trigger language plpgsql security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
begin
  if tg_op = 'DELETE' then
    raise exception 'studio_rule_emergency_pauses is append-only' using errcode = 'restrict_violation';
  end if;
  if old.lifted_at is not null then
    raise exception 'emergency pause is already lifted (write-once)' using errcode = 'restrict_violation';
  end if;
  if new.business_id is distinct from old.business_id
     or new.rule_id is distinct from old.rule_id
     or new.actor is distinct from old.actor
     or new.reason is distinct from old.reason
     or new.paused_at is distinct from old.paused_at
     or new.created_at is distinct from old.created_at then
    raise exception 'emergency pause identity is immutable' using errcode = 'restrict_violation';
  end if;
  if new.lifted_at is null or new.lifted_by is null then
    raise exception 'lifting an emergency pause requires lifted_at and lifted_by' using errcode = 'restrict_violation';
  end if;
  return new;
end $$;
revoke all on function app.studio_rule_emergency_pauses_guard() from public, anon, authenticated;
create trigger trg_studio_rule_emergency_pauses_guard
  before update or delete on public.studio_rule_emergency_pauses
  for each row execute function app.studio_rule_emergency_pauses_guard();

alter table public.studio_rule_emergency_pauses enable row level security;
create policy studio_rule_emergency_pauses_owner_read on public.studio_rule_emergency_pauses
  for select to authenticated using (app.is_salon_owner(business_id));
create policy studio_rule_emergency_pauses_sa_read on public.studio_rule_emergency_pauses
  for select to authenticated using (app.is_super_admin());
revoke all on public.studio_rule_emergency_pauses from public, anon, authenticated;
grant select on public.studio_rule_emergency_pauses to authenticated;

-- =====================================================================
-- 5. Emergency pause + lift RPCs (owner-only, audited, idempotent).
-- =====================================================================
create or replace function public.emergency_pause_studio_rule(
  p_business uuid, p_rule_id uuid, p_reason text)
returns jsonb language plpgsql security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare v_reason text := btrim(coalesce(p_reason, '')); v_id uuid;
begin
  if not app.is_salon_owner(p_business) then raise exception 'owner only' using errcode = '42501'; end if;
  if char_length(v_reason) < 3 then
    raise exception 'an emergency pause requires a reason of at least 3 characters' using errcode = '22023';
  end if;
  if not exists (select 1 from public.program_rules where rule_id = p_rule_id and business_id = p_business) then
    raise exception 'program rule not found in this business' using errcode = '42501';
  end if;
  -- Idempotent: an existing active pause is returned unchanged (also wins the race).
  insert into public.studio_rule_emergency_pauses(business_id, rule_id, actor, reason)
  values(p_business, p_rule_id, auth.uid(), v_reason)
  on conflict (business_id, rule_id) where lifted_at is null do nothing
  returning id into v_id;
  if v_id is null then
    select id into v_id from public.studio_rule_emergency_pauses
     where business_id = p_business and rule_id = p_rule_id and lifted_at is null;
    return jsonb_build_object('status', 'ok', 'pause_id', v_id, 'business_id', p_business,
      'rule_id', p_rule_id, 'replayed', true);
  end if;
  insert into public.audit_log(business_id, actor, action, entity, entity_id, detail)
  values(p_business, auth.uid(), 'STUDIO_RULE_EMERGENCY_PAUSE', 'program_rules', p_rule_id,
    jsonb_build_object('rule_id', p_rule_id, 'reason', v_reason, 'pause_id', v_id));
  return jsonb_build_object('status', 'ok', 'pause_id', v_id, 'business_id', p_business,
    'rule_id', p_rule_id, 'replayed', false);
end $$;
revoke all on function public.emergency_pause_studio_rule(uuid, uuid, text) from public, anon;

create or replace function public.lift_emergency_pause(
  p_business uuid, p_rule_id uuid, p_reason text default null)
returns jsonb language plpgsql security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare v_id uuid; v_reason text := nullif(btrim(coalesce(p_reason, '')), '');
begin
  if not app.is_salon_owner(p_business) then raise exception 'owner only' using errcode = '42501'; end if;
  update public.studio_rule_emergency_pauses
     set lifted_at = now(), lifted_by = auth.uid()
   where business_id = p_business and rule_id = p_rule_id and lifted_at is null
   returning id into v_id;
  if v_id is null then
    return jsonb_build_object('status', 'ok', 'business_id', p_business, 'rule_id', p_rule_id,
      'lifted', false, 'replayed', true);
  end if;
  insert into public.audit_log(business_id, actor, action, entity, entity_id, detail)
  values(p_business, auth.uid(), 'STUDIO_RULE_EMERGENCY_PAUSE_LIFTED', 'program_rules', p_rule_id,
    jsonb_build_object('rule_id', p_rule_id, 'pause_id', v_id, 'reason', v_reason));
  return jsonb_build_object('status', 'ok', 'business_id', p_business, 'rule_id', p_rule_id,
    'lifted', true, 'pause_id', v_id, 'replayed', false);
end $$;
revoke all on function public.lift_emergency_pause(uuid, uuid, text) from public, anon;

-- =====================================================================
-- 6. set_studio_rule_active - the NORMAL, versioned pause/resume. Clones the active
--    published config to a draft, flips ONLY this rule's active flag, and publishes it
--    through the existing immutable lifecycle (create_loyalty_config_draft +
--    publish_loyalty_config). Never mutates a published version in place. Owner-only,
--    audited. A no-op (already in the requested state) creates no version.
-- =====================================================================
create or replace function public.set_studio_rule_active(
  p_business uuid, p_rule_id uuid, p_active boolean)
returns jsonb language plpgsql security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare v_active_cfg uuid; v_current boolean; v_draft uuid; v_pub jsonb; v_new uuid;
begin
  if not app.is_salon_owner(p_business) then raise exception 'owner only' using errcode = '42501'; end if;
  if p_active is null then raise exception 'p_active is required' using errcode = '22023'; end if;
  select active_config_version_id into v_active_cfg from public.businesses where id = p_business;
  if v_active_cfg is null then raise exception 'no active published configuration' using errcode = '22023'; end if;
  select active into v_current from public.program_rules
   where rule_id = p_rule_id and config_version_id = v_active_cfg and business_id = p_business;
  if not found then raise exception 'program rule not found in the active configuration' using errcode = '42501'; end if;
  if v_current = p_active then
    return jsonb_build_object('status', 'ok', 'rule_id', p_rule_id, 'active', p_active,
      'changed', false, 'config_version_id', v_active_cfg);
  end if;

  v_draft := (public.create_loyalty_config_draft(p_business, v_active_cfg, 'studio_rule_active_set')::jsonb->>'version_id')::uuid;
  update public.program_rules set active = p_active
   where rule_id = p_rule_id and config_version_id = v_draft and business_id = p_business;
  if not found then raise exception 'cloned draft did not contain the target rule' using errcode = 'XX001'; end if;
  perform app.refresh_loyalty_config_snapshot(v_draft);
  v_pub := public.publish_loyalty_config(v_draft)::jsonb;
  v_new := (v_pub->>'version_id')::uuid;
  insert into public.audit_log(business_id, actor, action, entity, entity_id, detail)
  values(p_business, auth.uid(), 'STUDIO_RULE_ACTIVE_SET', 'program_rules', p_rule_id,
    jsonb_build_object('rule_id', p_rule_id, 'active', p_active, 'from_config', v_active_cfg, 'new_config', v_new));
  return jsonb_build_object('status', 'ok', 'rule_id', p_rule_id, 'active', p_active,
    'changed', true, 'config_version_id', v_new);
end $$;
revoke all on function public.set_studio_rule_active(uuid, uuid, boolean) from public, anon;

-- =====================================================================
-- 7. preview_publish_impact - owner-only publish preview. For the DRAFT about to publish,
--    returns per-rule + per-effect state_after_publish, financial / customer_facing flags,
--    and the aggregate. requires_confirmation is TRUE iff any effect of an ACTIVE rule
--    would be live AND (financial OR customer_facing). state_after_publish uses the same
--    per-effect logic as runtime: the registry cutover is already global, so publishing
--    the draft changes nothing about a family's execution engine - only which rules feed
--    it. financial = checkout | points_loyalty | (recurring grant_free_item);
--    customer_facing = comms | checkout | recurring | points_loyalty.
-- =====================================================================
create or replace function public.preview_publish_impact(p_config_version_id uuid)
returns jsonb language plpgsql stable security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_header public.firm_config_versions%rowtype; r public.program_rules%rowtype;
  v_eff jsonb; v_effs jsonb; v_idx int; v_family text; v_state text; v_fin boolean; v_cf boolean;
  v_rules jsonb := '[]'::jsonb; v_any_live_fin boolean := false; v_any_live_cf boolean := false;
begin
  select * into v_header from public.firm_config_versions where id = p_config_version_id;
  if not found or not app.is_salon_owner(v_header.business_id) then
    raise exception 'owner only' using errcode = '42501';
  end if;
  for r in select * from public.program_rules
            where config_version_id = p_config_version_id and business_id = v_header.business_id
            order by sort, rule_id loop
    v_effs := '[]'::jsonb; v_idx := 0;
    for v_eff in select * from jsonb_array_elements(coalesce(r.then_effects, '[]'::jsonb)) loop
      v_family := app.ps1c2_effect_family(v_eff->>'effect_type');
      v_state := app.ps1c2_effect_state(v_header.business_id, v_eff->>'effect_type');
      v_fin := (v_family = 'checkout') or (v_family = 'points_loyalty')
               or (v_family = 'recurring' and v_eff->>'effect_type' = 'grant_free_item');
      v_cf := v_family in ('comms', 'checkout', 'recurring', 'points_loyalty');
      -- Only an ACTIVE rule can actually activate value on publish.
      if r.active and v_state = 'live' and v_fin then v_any_live_fin := true; end if;
      if r.active and v_state = 'live' and v_cf  then v_any_live_cf  := true; end if;
      v_effs := v_effs || jsonb_build_array(jsonb_build_object(
        'effect_index', v_idx, 'effect_type', v_eff->>'effect_type', 'family', v_family,
        'state_after_publish', v_state, 'financial', v_fin, 'customer_facing', v_cf));
      v_idx := v_idx + 1;
    end loop;
    v_rules := v_rules || jsonb_build_array(jsonb_build_object(
      'rule_id', r.rule_id, 'name', r.name, 'active', r.active,
      'aggregate_state_after_publish', app.ps1c2_rule_state(v_header.business_id, r.id, 'published', r.active),
      'effects', v_effs));
  end loop;
  return jsonb_build_object(
    'config_version_id', p_config_version_id,
    'business_id', v_header.business_id,
    'status', v_header.status,
    'rules', v_rules,
    'will_activate_live_financial', v_any_live_fin,
    'will_activate_customer_facing', v_any_live_cf,
    'requires_confirmation', v_any_live_fin or v_any_live_cf);
end $$;
revoke all on function public.preview_publish_impact(uuid) from public, anon;

-- =====================================================================
-- 8. ENFORCEMENT (the teeth) - non-checkout executor. This is the v57 body BYTE-FOR-BYTE,
--    with EXACTLY ONE added predicate on the compiled-rule loop's WHERE clause: skip any
--    rule with an active emergency pause. Nothing else changes. A paused rule stops NEW
--    effects; NO historical fulfilment / entitlement / shadow / log row is deleted.
-- =====================================================================
create or replace function app.ps1b_execute_event(p_event uuid)
returns integer language plpgsql security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  ev public.domain_events%rowtype; v_active uuid; r record; v_effect jsonb;
  v_idx integer; v_type text; v_family text; v_auth text; v_cut text;
  v_period text; v_pkey text; v_period_start timestamptz; v_period_end timestamptz;
  v_face integer; v_cap integer; v_valid_until timestamptz; v_ent uuid; v_outcome text;
  v_ful uuid; v_key text; v_count integer := 0; v_has_notify boolean := false;
  -- v57: typed catalog pricing (fail-closed) inputs.
  v_price jsonb; v_pstatus text; v_preason text; v_amt integer;
begin
  select * into ev from public.domain_events where event_id = p_event;
  if not found then return 0; end if;
  if exists(select 1 from public.domain_event_execution where event_id = p_event) then return 0; end if;
  select active_config_version_id into v_active from public.businesses where id = ev.business_id;

  for r in select * from public.program_rules_compiled c
            where c.business_id = ev.business_id and c.config_version_id = v_active
              and c.when_event = ev.event_type and c.active
              -- PS-1C.2 teeth: an active emergency pause removes the rule (stops NEW
              -- effects; deletes no historical fulfilment/entitlement/shadow/log row).
              and not exists (select 1 from public.studio_rule_emergency_pauses ep
                               where ep.business_id = ev.business_id and ep.rule_id = c.rule_id
                                 and ep.lifted_at is null) loop
    if not app.ps1b_eval_conditions(ev.payload, r.compiled->'if') then continue; end if;
    v_idx := 0;
    for v_effect in select * from jsonb_array_elements(coalesce(r.compiled->'then', '[]'::jsonb)) loop
      -- v57: process each effect in its own subtransaction. WHEN OTHERS records a
      -- structured 'failed' outcome (fail CLOSED) and continues to the next effect;
      -- the event still receives its execution marker below, so a poisoned rule can
      -- never wedge the sweep.
      begin
        v_type := v_effect->>'effect_type';
        v_family := app.ps1b_effect_family(v_type);
        select execution_authority, cutover_status into v_auth, v_cut
          from public.benefit_registry where business_id = ev.business_id and source_engine = v_family;

        if v_type = 'send_notification' then
          insert into public.event_outbox(business_id, event_id, consumer)
          values(ev.business_id, p_event, 'comms') on conflict (event_id, consumer) do nothing;
          v_has_notify := true;
          insert into public.rule_effect_log(business_id, event_id, rule_id, effect_index, effect_type, outcome, config_version_id)
          values(ev.business_id, p_event, r.rule_id, v_idx, v_type, 'notified', v_active)
          on conflict (event_id, rule_id, effect_index) do nothing;

        elsif v_type = 'display_perk' then
          insert into public.rule_effect_log(business_id, event_id, rule_id, effect_index, effect_type, outcome, config_version_id)
          values(ev.business_id, p_event, r.rule_id, v_idx, v_type, 'display_perk', v_active)
          on conflict (event_id, rule_id, effect_index) do nothing;

        elsif v_type = 'grant_free_item' and v_auth = 'studio_executor' and v_cut = 'studio' then
          -- The ONE value-PROMISING path the PS-1B executor fulfils. The face value
          -- comes from the TYPED catalog price (v57): a missing / renamed / mis-typed
          -- catalog NEVER silently becomes an economically meaningful 0.
          v_price := app.ps1b_catalog_price(ev.business_id, v_effect->>'catalog_kind', nullif(v_effect->>'catalog_id','')::uuid);
          v_pstatus := v_price->>'status';
          v_preason := v_price->>'reason';
          v_amt := nullif(v_effect->>'amount_cents','')::integer;
          v_face := null;
          if v_pstatus = 'ok' then
            v_face := nullif(v_price->>'price_cents','')::integer;
          elsif v_pstatus = 'not_applicable' and v_amt is not null then
            -- Documented fallback: no catalog reference, but the effect carries an
            -- explicit owner-authored face value.
            v_face := v_amt;
          end if;
          if v_face is null then
            -- Fail CLOSED: invalid_kind / not_found / error, or not_applicable with no
            -- amount_cents. No entitlement, no fulfilment, no reservation.
            insert into public.rule_effect_log(business_id, event_id, rule_id, effect_index, effect_type, outcome, failure_reason, config_version_id)
            values(ev.business_id, p_event, r.rule_id, v_idx, v_type, 'failed',
              'price:' || coalesce(v_pstatus, 'null') || ':' || coalesce(v_preason, ''), v_active)
            on conflict (event_id, rule_id, effect_index) do nothing;
          else
            v_period := coalesce(r.compiled->'with'->>'budget_period', r.compiled->'during'->>'period', 'monthly');
            v_pkey := app.ps1b_period_key(ev.occurred_at, v_period);
            v_period_start := (app.ps1b_period_key(ev.occurred_at, v_period) || case v_period when 'daily' then '' when 'annual' then '-01-01' else '-01' end)::timestamptz;
            v_period_end := v_period_start + case v_period when 'daily' then interval '1 day' when 'annual' then interval '1 year' else interval '1 month' end;
            v_cap := nullif(r.compiled->'with'->>'budget_cap_cents','')::integer;
            v_valid_until := ev.occurred_at + (coalesce(nullif(r.compiled->'with'->>'entitlement_expiry_days','')::integer, 30) || ' days')::interval;
            select entitlement_id, outcome into v_ent, v_outcome from app.ps1b_materialise_entitlement(
              ev.business_id, ev.subject_client_id, r.rule_id, v_active, v_pkey, 'free_item',
              jsonb_build_object('rule_id', r.rule_id, 'effect', v_effect, 'source_engine', 'recurring'),
              ev.occurred_at, v_valid_until, v_face, v_cap, v_period_start, v_period_end);
            if v_outcome = 'budget_exhausted' then
              insert into public.rule_effect_log(business_id, event_id, rule_id, effect_index, effect_type, outcome, config_version_id)
              values(ev.business_id, p_event, r.rule_id, v_idx, v_type, 'budget_exhausted', v_active)
              on conflict (event_id, rule_id, effect_index) do nothing;
            else
              v_key := 'recurring:' || r.rule_id::text || ':' || ev.subject_client_id::text || ':' || v_pkey;
              insert into public.benefit_fulfilments(
                business_id, canonical_benefit_key, source_engine, fulfilment_kind, client_id, detail_ref,
                face_value_cents, estimated_cost_cents, cost_basis, cost_confidence, config_version_id, occurred_at)
              values(ev.business_id, v_key, 'recurring', 'recurring_perk', ev.subject_client_id, v_ent,
                v_face, v_face, 'catalog_cost', 'medium', v_active, ev.occurred_at)
              on conflict (business_id, canonical_benefit_key) do nothing
              returning id into v_ful;
              if v_ful is null then select id into v_ful from public.benefit_fulfilments
                 where business_id = ev.business_id and canonical_benefit_key = v_key; end if;
              insert into public.rule_effect_log(business_id, event_id, rule_id, effect_index, effect_type, outcome, benefit_fulfilment_id, config_version_id)
              values(ev.business_id, p_event, r.rule_id, v_idx, v_type, 'fulfilled', v_ful, v_active)
              on conflict (event_id, rule_id, effect_index) do nothing;
            end if;
          end if;

        else
          -- Everything else (value-moving effects, tier, checkout, or a legacy
          -- family) is SHADOW-LOGGED in PS-1B. No value moves.
          insert into public.benefit_shadow_evaluations(
            business_id, event_id, source_engine, rule_id, would_be_canonical_key, client_id,
            fulfilment_kind, face_value_cents, estimated_cost_cents, cost_basis, cost_confidence, config_version_id)
          values(ev.business_id, p_event, v_family, r.rule_id,
            v_family || ':' || r.rule_id::text || ':' || coalesce(ev.subject_client_id::text,'-') || ':' || v_idx::text,
            ev.subject_client_id, v_type,
            coalesce(nullif(v_effect->>'amount_cents','')::integer, 0),
            coalesce(nullif(v_effect->>'amount_cents','')::integer, 0), 'margin_band', 'low', v_active)
          on conflict (business_id, would_be_canonical_key, event_id) do nothing;
          insert into public.rule_effect_log(business_id, event_id, rule_id, effect_index, effect_type, outcome, config_version_id)
          values(ev.business_id, p_event, r.rule_id, v_idx, v_type, 'shadow', v_active)
          on conflict (event_id, rule_id, effect_index) do nothing;
        end if;
      exception when others then
        -- A poisoned effect (e.g. a malformed compiled payload). The subtransaction
        -- rollback undoes any partial write from THIS effect only; record a
        -- structured 'failed' outcome so the failure is evidence, not a silent gap.
        insert into public.rule_effect_log(business_id, event_id, rule_id, effect_index, effect_type, outcome, failure_reason, config_version_id)
        values(ev.business_id, p_event, r.rule_id, v_idx, coalesce(v_type, 'unknown'), 'failed',
          sqlstate || ':' || left(sqlerrm, 180), v_active)
        on conflict (event_id, rule_id, effect_index) do nothing;
      end;
      v_idx := v_idx + 1;
      v_count := v_count + 1;
    end loop;
  end loop;

  insert into public.domain_event_execution(event_id, business_id, effect_count)
  values(p_event, ev.business_id, v_count) on conflict (event_id) do nothing;
  return v_count;
end $$;
revoke all on function app.ps1b_execute_event(uuid) from public, anon, authenticated;

-- =====================================================================
-- 9. ENFORCEMENT (the teeth) - checkout kernel plan. This is the v59 body BYTE-FOR-BYTE,
--    with EXACTLY ONE added predicate on the candidate-gather loop's WHERE clause: skip
--    any rule with an active emergency pause. Nothing else changes. Custom-line handling,
--    price rejection, discount gathering/application, budget projection, GST extraction,
--    and the typed zero-total result are preserved verbatim from v59.
-- =====================================================================
create or replace function app.ps1c_plan_checkout(
  p_business uuid, p_branch uuid, p_client uuid, p_lines jsonb, p_config uuid)
returns jsonb language plpgsql stable security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_line jsonb; v_ord int := 0; v_n int;
  v_kind text[]; v_id uuid[]; v_name text[]; v_unit int[]; v_qty int[]; v_ltot int[]; v_rem int[];
  v_entered_by uuid[]; v_lreason text[];
  v_subtotal bigint := 0; v_price jsonb; v_pstatus text; v_nm text;
  v_server jsonb := '[]'::jsonb; v_entry jsonb;
  v_payload jsonb; v_active_rules boolean := (p_config is not null);
  r record; v_eff jsonb; v_idx int; v_etype text; v_ckind text; v_cid uuid; v_level text;
  v_stackable boolean; v_cap int; v_period text;
  v_cand jsonb := '[]'::jsonb;   -- gathered discount candidates
  v_applied jsonb := '[]'::jsonb;
  v_total_discount bigint := 0; v_any_line boolean := false; v_any_bill boolean := false;
  c jsonb; v_target int; v_base int; v_d int; v_reason text; v_suppressed boolean;
  v_ps timestamptz; v_pe timestamptz; v_committed int; v_projected int;
  v_rule_proj jsonb := '{}'::jsonb; v_gst_reg boolean; v_gst_bps int; v_total int; v_gst int;
  j int;
  -- custom-line locals
  v_desc text; v_camt numeric; v_creason text; v_limit int; v_may_custom boolean;
  v_key text;
begin
  if jsonb_typeof(p_lines) <> 'array' then
    return jsonb_build_object('status', 'invalid', 'reason', 'lines must be a JSON array');
  end if;
  v_n := jsonb_array_length(p_lines);
  if v_n < 1 or v_n > 50 then
    return jsonb_build_object('status', 'invalid', 'reason', 'a cart must have between 1 and 50 lines');
  end if;

  -- The manual-price cap and the caller's manual-price authority are resolved ONCE.
  -- app.is_salon_owner / app.has_perm read auth.uid() (the evaluating staff), which is
  -- valid inside this definer function (it is only ever called by evaluate_checkout,
  -- which has already established an authenticated actor with create_sales).
  select coalesce(custom_line_limit_cents, 50000) into v_limit from public.businesses where id = p_business;
  v_limit := coalesce(v_limit, 50000);
  v_may_custom := app.is_salon_owner(p_business) or app.has_perm(p_business, 'custom_price_lines');

  -- 4.1 Resolve every line (fail closed). Read catalog_kind FIRST, then branch:
  --     custom lines are self-priced-and-audited; service/product lines are catalog
  --     priced and reject ALL price keys.
  for v_line in select * from jsonb_array_elements(p_lines) loop
    v_ord := v_ord + 1;
    v_ckind := v_line->>'catalog_kind';
    if v_ckind is null or v_ckind not in ('service', 'product', 'custom') then
      return jsonb_build_object('status', 'bad_kind', 'line', v_ord,
        'reason', 'catalog_kind must be service, product or custom');
    end if;

    if v_ckind = 'custom' then
      -- Custom line accepts ONLY {catalog_kind, description, amount_cents, reason, qty}.
      -- Any other key (a price key, a catalog_id, anything) is rejected as invalid.
      for v_key in select jsonb_object_keys(v_line) loop
        if v_key not in ('catalog_kind', 'description', 'amount_cents', 'reason', 'qty') then
          return jsonb_build_object('status', 'custom_line_invalid', 'line', v_ord,
            'reason', 'custom_line_invalid: a custom line carries only catalog_kind, description, amount_cents and reason');
        end if;
      end loop;
      if not v_may_custom then
        return jsonb_build_object('status', 'custom_line_denied', 'line', v_ord,
          'reason', 'custom_line_denied: you do not have permission to enter a manual price (custom_price_lines)');
      end if;
      -- qty must be exactly 1 (absent defaults to 1).
      if v_line ? 'qty' then
        if jsonb_typeof(v_line->'qty') is distinct from 'number'
           or (v_line->>'qty')::numeric <> 1 then
          return jsonb_build_object('status', 'custom_line_invalid', 'line', v_ord,
            'reason', 'custom_line_invalid: a custom line quantity is always 1');
        end if;
      end if;
      -- amount_cents must be a whole positive number within the firm limit.
      if jsonb_typeof(v_line->'amount_cents') is distinct from 'number' then
        return jsonb_build_object('status', 'custom_line_invalid', 'line', v_ord,
          'reason', 'custom_line_invalid: a custom line requires a numeric amount_cents');
      end if;
      v_camt := (v_line->>'amount_cents')::numeric;
      if v_camt <> trunc(v_camt) or v_camt < 1 then
        return jsonb_build_object('status', 'custom_line_invalid', 'line', v_ord,
          'reason', 'custom_line_invalid: amount_cents must be a whole number of at least 1 cent');
      end if;
      if v_camt > v_limit then
        return jsonb_build_object('status', 'custom_line_limit', 'line', v_ord,
          'reason', 'custom_line_limit: amount_cents exceeds this business''s manual-price limit of '
                    || v_limit || ' cents');
      end if;
      -- description and reason are mandatory, 3..200 chars after trim.
      v_desc := btrim(coalesce(v_line->>'description', ''));
      v_creason := btrim(coalesce(v_line->>'reason', ''));
      if length(v_desc) < 3 or length(v_desc) > 200 then
        return jsonb_build_object('status', 'custom_line_invalid', 'line', v_ord,
          'reason', 'custom_line_invalid: a custom line needs a description of 3 to 200 characters');
      end if;
      if length(v_creason) < 3 or length(v_creason) > 200 then
        return jsonb_build_object('status', 'custom_line_invalid', 'line', v_ord,
          'reason', 'custom_line_invalid: a custom line needs a reason of 3 to 200 characters');
      end if;
      v_kind := array_append(v_kind, 'custom');
      v_id := array_append(v_id, null::uuid);
      v_name := array_append(v_name, v_desc);
      v_unit := array_append(v_unit, v_camt::int);
      v_qty := array_append(v_qty, 1);
      v_ltot := array_append(v_ltot, v_camt::int);
      v_rem := array_append(v_rem, v_camt::int);
      v_entered_by := array_append(v_entered_by, auth.uid());
      v_lreason := array_append(v_lreason, v_creason);
      v_subtotal := v_subtotal + v_camt::int;
      continue;
    end if;

    -- service / product line: NOTHING is client-priceable.
    if v_line ? 'unit_price_cents' or v_line ? 'price_cents' or v_line ? 'amount_cents'
       or v_line ? 'line_total_cents' or v_line ? 'unit_cents' or v_line ? 'discount' then
      return jsonb_build_object('status', 'client_priced', 'line', v_ord,
        'reason', 'checkout lines carry catalog_kind + catalog_id + qty ONLY; nothing is client-priceable');
    end if;
    if jsonb_typeof(v_line->'qty') is distinct from 'number' then
      return jsonb_build_object('status', 'bad_qty', 'line', v_ord, 'reason', 'qty must be a number');
    end if;
    if (v_line->>'qty')::numeric <> trunc((v_line->>'qty')::numeric)
       or (v_line->>'qty')::numeric < 1 or (v_line->>'qty')::numeric > 1000000 then
      return jsonb_build_object('status', 'bad_qty', 'line', v_ord, 'reason', 'qty must be a whole number 1..1000000');
    end if;
    v_cid := nullif(v_line->>'catalog_id', '')::uuid;
    v_price := app.ps1b_catalog_price(p_business, v_ckind, v_cid);
    v_pstatus := v_price->>'status';
    if v_pstatus <> 'ok' then
      return jsonb_build_object('status', 'price_error', 'line', v_ord, 'catalog_kind', v_ckind,
        'catalog_id', v_cid, 'reason', v_pstatus || ':' || coalesce(v_price->>'reason', ''));
    end if;
    if v_ckind = 'service' then
      select name into v_nm from public.services where id = v_cid and business_id = p_business;
    else
      select name into v_nm from public.products where id = v_cid and business_id = p_business;
    end if;
    v_kind := array_append(v_kind, v_ckind);
    v_id := array_append(v_id, v_cid);
    v_name := array_append(v_name, coalesce(v_nm, v_ckind));
    v_unit := array_append(v_unit, (v_price->>'price_cents')::int);
    v_qty := array_append(v_qty, (v_line->>'qty')::int);
    v_ltot := array_append(v_ltot, (v_price->>'price_cents')::int * (v_line->>'qty')::int);
    v_rem := array_append(v_rem, (v_price->>'price_cents')::int * (v_line->>'qty')::int);
    v_entered_by := array_append(v_entered_by, null::uuid);
    v_lreason := array_append(v_lreason, null::text);
    v_subtotal := v_subtotal + ((v_price->>'price_cents')::int * (v_line->>'qty')::int);
  end loop;

  if v_subtotal <= 0 then
    return jsonb_build_object('status', 'invalid', 'reason', 'a checkout must total more than zero');
  end if;
  if v_subtotal > 2147483647 then
    return jsonb_build_object('status', 'invalid', 'reason', 'checkout subtotal exceeds the supported maximum');
  end if;

  for j in 1 .. array_length(v_kind, 1) loop
    v_entry := jsonb_build_object(
      'catalog_kind', v_kind[j], 'catalog_id', v_id[j], 'name', v_name[j],
      'unit_price_cents', v_unit[j], 'qty', v_qty[j], 'line_total_cents', v_ltot[j]);
    if v_kind[j] = 'custom' then
      -- entered_by + reason are server-owned provenance, frozen inside the immutable
      -- token; they are NOT part of the price-relevant cart_hash projection.
      v_entry := v_entry || jsonb_build_object('entered_by', v_entered_by[j], 'reason', v_lreason[j]);
    end if;
    v_server := v_server || jsonb_build_array(v_entry);
  end loop;

  -- 4.2 Gather discount candidates from ACTIVE sale.completed rules. Custom lines have
  --     a null catalog_id so a line-level discount never matches them; bill discounts
  --     apply to the whole discounted subtotal, custom amounts included.
  v_payload := jsonb_build_object('amount_cents', v_subtotal, 'kind', 'cart_sale',
    'branch_id', to_jsonb(p_branch::text), 'client_id', to_jsonb(coalesce(p_client::text, '')),
    'counts_as_visit', true, 'earns_points', true);
  if v_active_rules then
    for r in select c2.rule_id, c2.compiled from public.program_rules_compiled c2
              where c2.business_id = p_business and c2.config_version_id = p_config
                and c2.when_event = 'sale.completed' and c2.active
                -- PS-1C.2 teeth: an active emergency pause removes the rule from candidate
                -- gathering (stops NEW discounts; deletes no historical discount line).
                and not exists (select 1 from public.studio_rule_emergency_pauses ep
                                 where ep.business_id = p_business and ep.rule_id = c2.rule_id
                                   and ep.lifted_at is null)
              order by c2.rule_id loop
      if not app.ps1b_eval_conditions(v_payload, r.compiled->'if') then continue; end if;
      v_stackable := coalesce((r.compiled->'using'->>'stackable')::boolean, true);
      v_cap := nullif(r.compiled->'with'->>'budget_cap_cents', '')::int;
      v_period := coalesce(r.compiled->'with'->>'budget_period', 'monthly');
      v_idx := 0;
      for v_eff in select * from jsonb_array_elements(coalesce(r.compiled->'then', '[]'::jsonb)) loop
        v_etype := v_eff->>'effect_type';
        if v_etype in ('apply_discount_pct', 'apply_discount_amount') then
          v_ckind := nullif(v_eff->>'catalog_kind', '');
          v_cid := nullif(v_eff->>'catalog_id', '')::uuid;
          v_level := case when v_ckind is not null and v_cid is not null then 'line' else 'bill' end;
          v_cand := v_cand || jsonb_build_array(jsonb_build_object(
            'rule_id', r.rule_id, 'effect_index', v_idx, 'effect_type', v_etype, 'level', v_level,
            'catalog_kind', v_ckind, 'catalog_id', v_cid,
            'discount_pct', v_eff->>'discount_pct', 'amount_cents', v_eff->>'amount_cents',
            'stackable', v_stackable, 'cap_cents', v_cap, 'period', v_period));
        end if;
        v_idx := v_idx + 1;
      end loop;
    end loop;
  end if;

  -- 4.3 Apply candidates in deterministic order (line effects first, then bill).
  for c in
    select e from jsonb_array_elements(v_cand) e
     order by (e->>'level') desc,
              (e->>'rule_id'), (e->>'effect_index')::int
  loop
    v_suppressed := false; v_reason := null; v_d := 0; v_target := null;
    v_stackable := (c->>'stackable')::boolean;
    v_cap := nullif(c->>'cap_cents', '')::int;
    v_period := c->>'period';

    if not v_stackable and ((c->>'level' = 'line' and v_any_line) or (c->>'level' = 'bill' and v_any_bill)) then
      v_suppressed := true; v_reason := 'stacking';
    end if;

    if not v_suppressed then
      if c->>'level' = 'line' then
        v_target := null;
        for j in 1 .. array_length(v_kind, 1) loop
          if v_kind[j] = (c->>'catalog_kind') and v_id[j] = nullif(c->>'catalog_id', '')::uuid and v_rem[j] > 0 then
            v_target := j; exit;
          end if;
        end loop;
        if v_target is null then
          v_suppressed := true; v_reason := 'no_target';
        else
          v_base := v_rem[v_target];
        end if;
      else
        v_base := (v_subtotal - v_total_discount)::int;
        if v_base <= 0 then v_suppressed := true; v_reason := 'no_target'; end if;
      end if;
    end if;

    if not v_suppressed then
      if c->>'effect_type' = 'apply_discount_pct' then
        v_d := round(v_base::numeric * (c->>'discount_pct')::numeric / 100.0)::int;
      else
        v_d := least((c->>'amount_cents')::int, v_base);
      end if;
      if v_d > v_base then v_d := v_base; end if;
      if v_d < 0 then v_d := 0; end if;
      if v_d = 0 then v_suppressed := true; v_reason := 'no_target'; end if;
    end if;

    v_ps := null; v_pe := null;
    if v_cap is not null then
      select period_start, period_end into v_ps, v_pe from app.ps1c_period_bounds(now(), v_period);
    end if;
    if not v_suppressed and v_cap is not null then
      select coalesce(committed_cents, 0) into v_committed from public.budget_periods
       where business_id = p_business and rule_id = (c->>'rule_id')::uuid and period_start = v_ps;
      v_committed := coalesce(v_committed, 0);
      v_projected := coalesce((v_rule_proj->>(c->>'rule_id'))::int, 0);
      if v_committed + v_projected + v_d > v_cap then
        v_suppressed := true; v_reason := 'budget_exhausted';
      else
        v_rule_proj := v_rule_proj || jsonb_build_object(c->>'rule_id', v_projected + v_d);
      end if;
    end if;

    if v_suppressed then
      v_applied := v_applied || jsonb_build_array(jsonb_build_object(
        'rule_id', c->>'rule_id', 'effect_index', (c->>'effect_index')::int, 'effect_type', c->>'effect_type',
        'level', c->>'level', 'target_line_index', v_target, 'amount_cents', 0,
        'suppressed', true, 'suppression_reason', v_reason,
        'capped', v_cap is not null, 'cap_cents', v_cap,
        'period_start', v_ps, 'period_end', v_pe));
    else
      if c->>'level' = 'line' then
        v_rem[v_target] := v_rem[v_target] - v_d; v_any_line := true;
      else
        v_any_bill := true;
      end if;
      v_total_discount := v_total_discount + v_d;
      v_applied := v_applied || jsonb_build_array(jsonb_build_object(
        'rule_id', c->>'rule_id', 'effect_index', (c->>'effect_index')::int, 'effect_type', c->>'effect_type',
        'level', c->>'level', 'target_line_index', v_target, 'amount_cents', v_d,
        'suppressed', false, 'suppression_reason', null,
        'capped', v_cap is not null, 'cap_cents', v_cap,
        'period_start', v_ps, 'period_end', v_pe));
    end if;
  end loop;

  v_total := (v_subtotal - v_total_discount)::int;

  -- 4.4 Zero-total is a TYPED result (contract B): a fully-discounted cart cannot be
  --     recorded (no zero-value-sale contract exists). Returned BEFORE the token is
  --     minted, so evaluate_checkout never persists an evaluation or an op-ledger row
  --     for it.
  if v_total = 0 then
    return jsonb_build_object('status', 'total_zero_not_supported',
      'reason', 'total_zero_not_supported: this checkout is fully discounted to zero and a zero-value sale is not supported; adjust the cart or the discount');
  end if;

  -- 4.5 GST-INCLUSIVE extraction (informational; total unchanged). ⚖️ reviewable.
  select gst_registered, gst_rate_bps into v_gst_reg, v_gst_bps from public.businesses where id = p_business;
  if coalesce(v_gst_reg, false) and coalesce(v_gst_bps, 0) > 0 then
    v_gst := round(v_total::numeric * v_gst_bps / (10000 + v_gst_bps))::int;
  else
    v_gst_bps := 0; v_gst := 0;
  end if;

  return jsonb_build_object(
    'status', 'ok',
    'server_lines', v_server,
    'subtotal_cents', v_subtotal::int,
    'applied_effects', v_applied,
    'discount_total_cents', v_total_discount::int,
    'total_cents', v_total,
    'gst_cents', v_gst,
    'gst_rate_bps', coalesce(v_gst_bps, 0),
    'cart_hash', app.ps1c_cart_hash(v_server));
end $$;
revoke all on function app.ps1c_plan_checkout(uuid, uuid, uuid, jsonb, uuid) from public, anon, authenticated;

-- =====================================================================
-- 10. Repoint the two callers of the OLD ps1a_studio_rule_state to the new truthful
--     aggregate, and surface the per-effect states + a labelled aggregate in the owner
--     overview. app.ps1a_studio_rule_state is KEPT in place (revoked, unused) as history.
--     get_program_rules_draft body is byte-identical to v55 except the execution_state
--     call. get_programs_overview is byte-identical to v55 except the studio_rules block.
-- =====================================================================
create or replace function public.get_program_rules_draft(p_config_version uuid)
returns jsonb language plpgsql stable security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare v_header public.firm_config_versions%rowtype; v_result jsonb;
begin
  select * into v_header from public.firm_config_versions where id=p_config_version;
  if not found or not app.is_salon_owner(v_header.business_id) then raise exception 'owner only' using errcode='42501'; end if;
  if v_header.status<>'draft' then raise exception 'only a draft program rule set may be read' using errcode='42501'; end if;
  select jsonb_build_object(
    'config_version_id',v_header.id,'business_id',v_header.business_id,'version_no',v_header.version_no,
    'status',v_header.status,'snapshot_hash',v_header.snapshot_hash,
    'rules', coalesce((select jsonb_agg(jsonb_build_object(
        'rule_id',pr.rule_id,'program_rule_id',pr.id,'schema_version',pr.schema_version,'name',pr.name,'active',pr.active,
        'when_event',pr.when_event,'if_conditions',pr.if_conditions,'then_effects',pr.then_effects,
        'with_params',pr.with_params,'during_schedule',pr.during_schedule,'using_stacking',pr.using_stacking,
        'rule_hash',pr.rule_hash,'sort',pr.sort,'notes',pr.notes,
        'execution_state', app.ps1c2_rule_state(v_header.business_id, pr.id, v_header.status, pr.active),
        'validation', public.validate_program_rule(v_header.business_id, jsonb_build_object(
          'schema_version',pr.schema_version,'when_event',pr.when_event,'if_conditions',pr.if_conditions,
          'then_effects',pr.then_effects,'with_params',pr.with_params,'during_schedule',pr.during_schedule,'using_stacking',pr.using_stacking))
      ) order by pr.sort, pr.rule_id) from public.program_rules pr where pr.config_version_id=p_config_version and pr.business_id=v_header.business_id),'[]'::jsonb),
    'allowlists', public.get_rule_allowlists(v_header.business_id)
  ) into v_result;
  return v_result;
end $$;

create or replace function public.get_programs_overview(p_business uuid)
returns jsonb language plpgsql stable security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare v_active uuid; v_result jsonb;
begin
  if not (app.is_salon_owner(p_business) or app.is_super_admin()) then raise exception 'owner only' using errcode='42501'; end if;
  select active_config_version_id into v_active from public.businesses where id=p_business;
  select jsonb_build_object(
    'business_id', p_business,
    'active_config_version_id', v_active,
    'registry', coalesce((select jsonb_agg(jsonb_build_object(
        'source_engine',br.source_engine,'execution_authority',br.execution_authority,
        'cutover_status',br.cutover_status,'canonical_benefit_key_template',br.canonical_benefit_key_template
      ) order by br.source_engine) from public.benefit_registry br where br.business_id=p_business),'[]'::jsonb),
    'legacy_programs', coalesce((select jsonb_agg(jsonb_build_object(
        'source_engine',a.source_engine,'rule_key',a.rule_key,'synthetic_rule_id',a.synthetic_rule_id,
        'native_ref',a.native_ref,'name',a.name,'active',a.active,'when_event',a.when_event,
        'if_conditions',a.if_conditions,'then_effects',a.then_effects,'with_params',a.with_params,
        'during_schedule',a.during_schedule,'using_stacking',a.using_stacking,
        'execution_authority','legacy_trigger','execution_state',a.execution_state
      ) order by a.source_engine, a.rule_key) from public.v_program_rules_all a where a.business_id=p_business),'[]'::jsonb),
    'studio_rules', coalesce((select jsonb_agg(jsonb_build_object(
        'rule_id',s.rule_id,'program_rule_id',s.id,'config_version_id',s.config_version_id,
        'config_status',fv.status,'name',s.name,'active',s.active,'when_event',s.when_event,
        'if_conditions',s.if_conditions,'then_effects',s.then_effects,'with_params',s.with_params,
        'during_schedule',s.during_schedule,'using_stacking',s.using_stacking,'rule_hash',s.rule_hash,
        'source_engine','studio_rule','execution_authority','studio_executor',
        -- PS-1C.2: 'execution_state' (back-compat) == 'aggregate_state' == the truthful
        -- server-derived aggregate; 'effect_states' is the per-effect breakdown;
        -- 'emergency_pause' surfaces the ACTIVE pause (reason/actor/time) so the owner
        -- UI can show WHO suspended the rule, WHY and WHEN (null when none is active).
        'execution_state', app.ps1c2_rule_state(s.business_id, s.id, fv.status, s.active),
        'aggregate_state', app.ps1c2_rule_state(s.business_id, s.id, fv.status, s.active),
        'effect_states', app.ps1c2_rule_effect_states(s.business_id, s.id),
        'emergency_pause', (select jsonb_build_object(
            'pause_id', ep.id, 'reason', ep.reason, 'actor', ep.actor,
            'paused_at', ep.paused_at, 'lifted_at', ep.lifted_at)
          from public.studio_rule_emergency_pauses ep
         where ep.business_id = s.business_id and ep.rule_id = s.rule_id and ep.lifted_at is null
         order by ep.paused_at desc limit 1)
      ) order by fv.status, s.sort, s.rule_id) from public.program_rules s
        join public.firm_config_versions fv on fv.id=s.config_version_id and fv.business_id=s.business_id
       where s.business_id=p_business and fv.status in ('draft','published')),'[]'::jsonb)
  ) into v_result;
  return v_result;
end $$;

-- =====================================================================
-- 11. Function ACLs. The owner-gated RPCs are re-granted to authenticated; the app-schema
--     helpers stay revoked (definer bodies do the privileged work). No RPC mutates a
--     benefit_registry execution authority (PS-1A/PS-1C invariant preserved).
-- =====================================================================
revoke all on function public.get_program_rules_draft(uuid) from public, anon;
revoke all on function public.get_programs_overview(uuid) from public, anon;
grant execute on function public.emergency_pause_studio_rule(uuid, uuid, text) to authenticated;
grant execute on function public.lift_emergency_pause(uuid, uuid, text) to authenticated;
grant execute on function public.set_studio_rule_active(uuid, uuid, boolean) to authenticated;
grant execute on function public.preview_publish_impact(uuid) to authenticated;
grant execute on function public.get_program_rules_draft(uuid) to authenticated;
grant execute on function public.get_programs_overview(uuid) to authenticated;

commit;
