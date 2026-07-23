-- FRENLY v57 - PROGRAM STUDIO PS-1B.1: CATALOG PRICING FAILS CLOSED
--
-- Local review candidate. Production apply needs the owner's RELEASE APPROVED
-- phrase (CLAUDE.md standing gate). PS-1B.1 §1 authorized 2026-07-24 (owner).
--
-- WHY: v56's app.ps1b_catalog_price returned an integer and swallowed EVERY error
-- with `exception when others then return 0`. A missing/renamed/mis-typed catalog
-- reference therefore became an economically meaningful ZERO - a silent-zero the
-- owner has ruled unacceptable before any financial phase. This migration makes
-- pricing return a TYPED result and the non-checkout executor consume it, so a
-- pricing failure produces a logged, evidence-backed rule_effect_log outcome
-- 'failed' (NO entitlement, NO fulfilment, NO reservation, NO $0 promise) instead.
--
-- SCOPE: three surgical changes, nothing else moves.
--   1. app.ps1b_catalog_price(uuid,text,uuid) -> jsonb {status,price_cents,reason}.
--   2. rule_effect_log gains a failure_reason column + reworked CHECK constraints
--      (outcome adds 'failed'; failed <=> failure_reason present).
--   3. app.ps1b_execute_event grant_free_item path consults the typed price and
--      each effect runs in its own subtransaction (poison isolation).
-- Untouched: producer triggers, emit_domain_event, outbox/sweep/captured_messages,
-- shadow evaluator/comparator, redeem/reverse RPCs, registry guard/seed,
-- ps1b_materialise_entitlement, budget arithmetic.

begin;

-- =====================================================================
-- 1. Typed, fail-closed catalog pricing.
--    Return type changes (integer -> jsonb), so DROP then CREATE.
--    status in ok | not_applicable | invalid_kind | not_found | error.
-- =====================================================================
drop function if exists app.ps1b_catalog_price(uuid, text, uuid);
create or replace function app.ps1b_catalog_price(p_business uuid, p_kind text, p_id uuid)
returns jsonb language plpgsql volatile security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare v_price integer; v_found boolean := false;
begin
  -- A missing catalog reference must NEVER become an economically meaningful 0.
  if p_id is null then
    return jsonb_build_object('status', 'not_applicable', 'price_cents', null,
      'reason', 'no catalog reference');
  end if;
  if p_kind is null or p_kind not in ('service', 'product') then
    return jsonb_build_object('status', 'invalid_kind', 'price_cents', null,
      'reason', 'unsupported catalog kind: ' || coalesce(p_kind, '<null>'));
  end if;
  -- One statement per branch: a planning/column defect in one catalog must not
  -- poison the other (plpgsql plans a whole statement at once). NOTE the column
  -- asymmetry: services carry price_cents, products carry retail_price_cents.
  if p_kind = 'service' then
    select s.price_cents into v_price from public.services s
     where s.id = p_id and s.business_id = p_business;
    v_found := found;
  else
    select pr.retail_price_cents into v_price from public.products pr
     where pr.id = p_id and pr.business_id = p_business;
    v_found := found;
  end if;
  if not v_found then
    return jsonb_build_object('status', 'not_found', 'price_cents', null,
      'reason', 'catalog row not found for this business');
  end if;
  -- A genuine, configured catalog price of 0 is still 'ok' (that IS a price).
  return jsonb_build_object('status', 'ok', 'price_cents', v_price, 'reason', null);
exception when others then
  -- Fail CLOSED with structured evidence, NEVER a silent 0. No secrets / raw SQL
  -- in the detail: only the sqlstate, a truncated message, and the inputs.
  insert into public.audit_log(business_id, actor, action, entity, entity_id, detail)
  values(p_business, null, 'PS1B_PRICING_ERROR', 'ps1b_catalog_price', p_id,
    jsonb_build_object('sqlstate', sqlstate, 'reason', left(sqlerrm, 200),
      'kind', p_kind, 'catalog_id', p_id));
  return jsonb_build_object('status', 'error', 'price_cents', null, 'reason', sqlstate);
end $$;
revoke all on function app.ps1b_catalog_price(uuid, text, uuid) from public, anon, authenticated;

-- =====================================================================
-- 2. rule_effect_log: a fourth "value NOT delivered" outcome family.
--    Add failure_reason, then rework the outcome + presence CHECKs. The table is
--    empty on UAT and in any fresh replay at this point, so re-adding CHECKs is
--    safe. Drop the KNOWN named presence constraint explicitly + any auto-named
--    outcome CHECK by conname pattern, then re-add all three as named constraints.
-- =====================================================================
alter table public.rule_effect_log add column failure_reason text;

alter table public.rule_effect_log drop constraint if exists rule_effect_log_fulfilment_presence_check;
alter table public.rule_effect_log drop constraint if exists rule_effect_log_outcome_check;
do $rel_outcome$
declare c record;
begin
  -- Belt-and-suspenders: drop any remaining CHECK on rule_effect_log that governs
  -- `outcome` regardless of the auto name pg assigned. The effect_index check
  -- references `effect_index` (not `outcome`) and is deliberately preserved.
  for c in
    select con.conname
      from pg_catalog.pg_constraint con
      join pg_catalog.pg_class rel on rel.oid = con.conrelid
      join pg_catalog.pg_namespace ns on ns.oid = rel.relnamespace
     where ns.nspname = 'public' and rel.relname = 'rule_effect_log'
       and con.contype = 'c'
       and pg_catalog.pg_get_constraintdef(con.oid) ilike '%outcome%'
  loop
    execute format('alter table public.rule_effect_log drop constraint %I', c.conname);
  end loop;
end $rel_outcome$;

alter table public.rule_effect_log
  add constraint rule_effect_log_outcome_check check (
    outcome in ('fulfilled','shadow','display_perk','notified','budget_exhausted','suppressed','no_op','failed'));
-- a value-PROMISING outcome carries exactly one fulfilment reference; non-value
-- outcomes carry none (§10 N1). Unchanged from v56, re-added by name.
alter table public.rule_effect_log
  add constraint rule_effect_log_fulfilment_presence_check check (
    (outcome = 'fulfilled') = (benefit_fulfilment_id is not null));
-- a 'failed' outcome carries a structured reason and nothing else; every other
-- outcome carries no reason.
alter table public.rule_effect_log
  add constraint rule_effect_log_failure_reason_check check (
    (outcome = 'failed') = (failure_reason is not null));

-- =====================================================================
-- 3. The non-checkout entitlement executor - v56 body EXACTLY, except:
--    (a) grant_free_item consults the TYPED price and fails CLOSED, and
--    (b) each effect runs in its own subtransaction so one poisoned rule/effect
--        cannot wedge its siblings or the event's execution marker.
--    All working v56 paths (send_notification, display_perk, shadow logging,
--    budget_exhausted, fulfilled) behave byte-for-byte identically.
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
              and c.when_event = ev.event_type and c.active loop
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

commit;
