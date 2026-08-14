-- nestly_v326_points_gift_lifecycle
--
-- Owner's Points System redesign (5-photo flow, see docs/qa/evidence/V324-POINTS-SYSTEM-PAGE-*
-- and memory claim-v324-points-system-page): gifts get a real third state — On (live) / Off
-- (paused, still exists, NOT in History) / Deleted (moved to History) — and every change to a
-- gift (pause, delete, create) takes effect IMMEDIATELY, bypassing the draft/publish cycle the
-- rest of loyalty_rewards normally goes through. Confirmed via AskUserQuestion 2026-08-14.
--
-- WHY THIS TOOK A FULL AUDIT BEFORE ANY SQL WAS WRITTEN. loyalty_rewards is read by five
-- customer/staff-facing functions that gate real redemption. An immediate write to this table
-- that those functions don't know about would let a "paused" or "deleted" gift stay redeemable —
-- a correctness bug, not a cosmetic one. Twelve functions referencing loyalty_rewards.active were
-- read in full (pg_get_functiondef) before this file was drafted:
--
--   MUST GATE on paused (customer/staff redemption or actionable-list paths):
--     customer_create_redemption_intent_v89, customer_get_business_actions_v89,
--     customer_get_business_presentation_v95, staff_get_customer_actionable_loyalty_v145,
--     app.redeem_reward_core (see below — this one needed a deeper fix, not just a filter).
--   NO CHANGE NEEDED (owner-facing counts/analytics, or display-only for an already-created
--   intent, never a redemption gate):
--     customer_get_home_offers_v167, staff_get_customer_entitlements_v102,
--     app.v177_programmes, business_programme_usage_v271, app.clone_reward_versions_for_config.
--   publish_loyalty_config: its reward-materialization UPDATE sets an explicit column list
--     (active, sort, cost_points, ...). paused is deliberately NOT in that list — publishing an
--     unrelated draft (e.g. a Tier ladder edit) must never touch a gift's paused state. Verified
--     by reading the exact UPDATE statement; no change made here, and none should ever be made.
--   save_loyalty_reward_draft: only INSERTs loyalty_rewards on first creation of a NEW draft
--     reward; the column default (false) covers paused with no change to the function.
--
-- THE REDEEM_REWARD_CORE LANDMINE. Every other redemption/actionable function already checks
-- loyalty_rewards.active directly. app.redeem_reward_core (staff-assisted, in-person redemption)
-- does not — it loads the live row only to confirm the reward exists, then gates purely on
-- loyalty_reward_versions.active at the business's active_config_version_id. That version row is
-- protected by trg_loyalty_reward_versions_immutable: once its config_version_id's status is
-- 'published', UPDATE/DELETE on it raises 'published reward configuration is immutable'. So an
-- immediate pause/delete on loyalty_rewards CANNOT be mirrored onto the published version row —
-- it is permanently frozen by design. Which means redeem_reward_core, unpatched, would let staff
-- complete an in-person redemption of a gift the owner just paused or deleted, because it never
-- looks at the row immediate-write actually touches. Fixed by making it check v_reward.active and
-- v_reward.paused directly (the row it already loads), independent of the immutable snapshot.
--
-- THE STALE-DRAFT RESURRECTION RISK. Deleting a gift sets loyalty_rewards.active=false directly.
-- If a draft was already open (cloned) before the delete, that draft's own loyalty_reward_versions
-- row for this reward still says active=true — and publish_loyalty_config's materialization does
-- an unconditional `active=rv.active` from whatever config_version the owner publishes. Publish an
-- unrelated draft later (say a Tier edit in progress) and the deleted gift's active flag would flip
-- back to true, undoing the delete everywhere, not just in redeem_reward_core. Guarded by also
-- writing false onto the open draft's own version row (allowed — only a *published* version's row
-- is immutable; a draft's own row can still be edited, same as save_loyalty_reward_draft already
-- does today). Pause never needs this: paused is not a column on loyalty_reward_versions at all,
-- so publish can never see it, let alone revert it.
--
-- CREATE mirrors the redemption-terms row, not just the live row. cost_points/credit_cents/
-- fulfillment_kind/etc for an actual redemption are read from loyalty_reward_versions at
-- active_config_version_id — never from loyalty_rewards — in every one of the four gated
-- functions above. A new gift is therefore only actually redeemable if a matching version row
-- exists at the business's *currently published* config_version_id, not just a loyalty_rewards
-- row. INSERT (unlike UPDATE/DELETE) into an already-published config version's row set is not
-- blocked by the immutability trigger, and is exactly how clone_reward_versions_for_config already
-- adds rows to a config version after the fact — an append, not a rewrite of history. This is the
-- same reason app.reward_programme_default_v313 / app.reward_programme_tenant_guard_v313 fire on
-- INSERT for both tables: programme_id is intentionally auto-derived, not supplied by this RPC.
--
-- Every new RPC uses app.c45_owner_loyalty_write(p_business) — the exact authorization
-- set_programmes_v314 (the v322 R6 "Live for customers" switches this same page reuses) and
-- publish_loyalty_config already use. Every write is audit_log'd, matching CLAUDE.md's "every
-- sensitive write audited" and the business_delete_promotion_v183 precedent for immediate writes.

begin;

alter table public.loyalty_rewards
  add column paused boolean not null default false;

comment on column public.loyalty_rewards.paused is
  'V326 immediate-write pause: temporarily withheld from redemption without deleting the gift. '
  'Not part of loyalty_reward_versions or the draft/publish cycle — publish_loyalty_config must '
  'never reference this column, and no migration should ever add it to loyalty_reward_versions.';

-- app.redeem_reward_core: gate on the live, mutable row (loyalty_rewards.active / .paused), not
-- only the immutable published-version snapshot it already checks. Everything else about this
-- function — the stamp/points branching, the eligibility joins, the ledger writes — is unchanged;
-- only the reward-lookup guard clause gains the two extra conditions.
CREATE OR REPLACE FUNCTION app.redeem_reward_core(p_business uuid, p_client uuid, p_reward uuid, p_idempotency_key text, p_branch uuid DEFAULT NULL::uuid, p_service uuid DEFAULT NULL::uuid, p_product uuid DEFAULT NULL::uuid)
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'app', 'pg_temp'
AS $function$
declare
  lp public.loyalty_programs%rowtype; v_reward public.loyalty_rewards%rowtype;
  v_version public.loyalty_reward_versions%rowtype; v_balance integer; v_batch_balance integer;
  v_remaining integer; v_take integer; v_batch record; v_actor uuid:=auth.uid(); v_staff uuid;
  v_points_id uuid:=gen_random_uuid(); v_credit_id uuid; v_operation_id uuid:=gen_random_uuid();
  v_redemption_id uuid:=gen_random_uuid(); v_provenance_id uuid:=gen_random_uuid();
  v_payload jsonb; v_operation public.loyalty_operations%rowtype; v_rows integer;
  v_usage integer; v_eligibility jsonb; v_result json; v_reward_programme uuid;
  v_programme_kind text; v_stamp_slots integer; v_stamp_filled integer; v_cycle_index integer;
  v_consumes boolean:=true; v_points_spent integer; v_cycle_id uuid;
begin
  if p_idempotency_key is null or length(btrim(p_idempotency_key))<8 then raise exception 'idempotency key must contain at least 8 characters' using errcode='22023'; end if;
  p_idempotency_key:=btrim(p_idempotency_key);
  if not app.has_perm(p_business,'create_sales') then raise exception 'not authorized' using errcode='42501'; end if;
  perform 1 from public.businesses where id=p_business for share;
  select s.id into v_staff from public.staff s where s.business_id=p_business and s.user_id=v_actor and s.active and 'create_sales'=any(app.role_perms(s.role)) limit 1 for update;
  if not found then raise exception 'active staff authorization required' using errcode='42501'; end if;
  perform 1 from public.clients c where c.id=p_client and c.business_id=p_business for update;
  if not found then raise exception 'client does not belong to this business'; end if;
  if p_branch is not null and not exists(select 1 from public.branches where id=p_branch and business_id=p_business) then raise exception 'branch does not belong to business'; end if;
  if not app.can_see_branch(p_business,p_branch) then
    raise exception 'redemption branch scope is not permitted' using errcode='42501';
  end if;
  if p_service is not null and not exists(select 1 from public.services where id=p_service and business_id=p_business) then raise exception 'service does not belong to business'; end if;
  if p_product is not null and not exists(select 1 from public.products where id=p_product and business_id=p_business) then raise exception 'product does not belong to business'; end if;
  v_payload:=jsonb_build_object('business_id',p_business,'client_id',p_client,'reward_id',p_reward,'branch_id',p_branch,'service_id',p_service,'product_id',p_product);
  perform set_config('app.loyalty_operation_insert_id',v_operation_id::text,true);
  insert into public.loyalty_operations(id,business_id,client_id,reward_id,operation_type,actor,idempotency_key,request_payload,request_hash)
  values(v_operation_id,p_business,p_client,p_reward,'redeem_reward',v_actor,p_idempotency_key,v_payload,md5(v_payload::text))
  on conflict(business_id,operation_type,idempotency_key) do nothing;
  get diagnostics v_rows=row_count; perform set_config('app.loyalty_operation_insert_id','',true);
  if v_rows=0 then
    select * into v_operation from public.loyalty_operations where business_id=p_business and operation_type='redeem_reward' and idempotency_key=p_idempotency_key for update;
    if v_operation.actor is distinct from v_actor or v_operation.request_hash is distinct from md5(v_payload::text) then raise exception 'idempotency conflict' using errcode='23505'; end if;
    if v_operation.status='completed' then return v_operation.result::json; end if;
    raise exception 'redemption already in progress' using errcode='55P03';
  end if;
  select * into lp from public.loyalty_programs where business_id=p_business limit 1;
  if not found then raise exception 'catalog redemption is inactive'; end if;
  select * into v_reward from public.loyalty_rewards where id=p_reward and business_id=p_business;
  if not found then raise exception 'reward not found in this business'; end if;
  -- V326: the live row is mutable and is what pause/delete actually write. The version row below
  -- is an immutable published snapshot that pause/delete cannot touch (trg_loyalty_reward_versions_immutable)
  -- — so this check, not that one, is what makes an immediate pause or delete actually block redemption here.
  if not v_reward.active then raise exception 'reward not found or inactive'; end if;
  if v_reward.paused then raise exception 'reward is currently paused' using errcode='22023'; end if;
  select rv.* into v_version from public.loyalty_reward_versions rv join public.businesses b on b.active_config_version_id=rv.config_version_id where rv.reward_id=p_reward and rv.business_id=p_business;
  if not found or not v_version.active then raise exception 'reward not found or inactive'; end if;
  if v_version.claim_available_from is not null and v_version.claim_available_from>now() then raise exception 'reward unavailable'; end if;
  if v_version.claim_available_until is not null and v_version.claim_available_until<=now() then raise exception 'reward expired'; end if;
  select jsonb_build_object(
    'branch_ids',coalesce((select jsonb_agg(branch_id order by branch_id) from public.loyalty_reward_branches where reward_version_id=v_version.id),'[]'::jsonb),
    'service_ids',coalesce((select jsonb_agg(service_id order by service_id) from public.loyalty_reward_services where reward_version_id=v_version.id),'[]'::jsonb),
    'product_ids',coalesce((select jsonb_agg(product_id order by product_id) from public.loyalty_reward_products where reward_version_id=v_version.id),'[]'::jsonb),
    'selected',jsonb_build_object('branch_id',p_branch,'service_id',p_service,'product_id',p_product)) into v_eligibility;
  if exists(select 1 from public.loyalty_reward_branches where reward_version_id=v_version.id) and not exists(select 1 from public.loyalty_reward_branches where reward_version_id=v_version.id and branch_id=p_branch) then raise exception 'reward not eligible at branch'; end if;
  if exists(select 1 from public.loyalty_reward_services where reward_version_id=v_version.id) and not exists(select 1 from public.loyalty_reward_services where reward_version_id=v_version.id and service_id=p_service) then raise exception 'reward not eligible for service'; end if;
  if exists(select 1 from public.loyalty_reward_products where reward_version_id=v_version.id) and not exists(select 1 from public.loyalty_reward_products where reward_version_id=v_version.id and product_id=p_product) then raise exception 'reward not eligible for product'; end if;
  select count(*)::integer into v_usage from public.loyalty_redemptions where business_id=p_business and client_id=p_client and reward_id=p_reward;
  if v_version.usage_limit is not null and v_usage>=v_version.usage_limit then
    raise exception 'reward usage limit reached' using errcode='check_violation';
  end if;
  if app.v176_reward_gate_threshold(p_business, v_version.min_tier_id, v_version.min_tier_threshold) is not null and app.v176_tier_gate_metric(p_business, p_client) < app.v176_reward_gate_threshold(p_business, v_version.min_tier_id, v_version.min_tier_threshold) then
    raise exception 'reward requires a higher membership tier' using errcode='check_violation';
  end if;
  select coalesce(sum(points),0)::integer into v_balance from public.points_ledger where business_id=p_business and client_id=p_client;
  v_reward_programme:=v_version.programme_id;
  if v_reward_programme is null then raise exception 'reward programme is not resolvable for this business' using errcode='XX001'; end if;
  if not exists(select 1 from public.business_programmes spine where spine.id=v_reward_programme and spine.business_id=p_business) then raise exception 'reward programme does not belong to this business' using errcode='42501'; end if;
  if not exists(select 1 from public.business_programmes spine where spine.id=v_reward_programme and spine.active) then raise exception 'catalog redemption is inactive'; end if;
  select spine.kind into v_programme_kind from public.business_programmes spine where spine.id=v_reward_programme;
  if v_programme_kind='stamps' then
    v_consumes:=false; v_points_spent:=0;
    select sp.slots,sp.filled,sp.cycle_index into v_stamp_slots,v_stamp_filled,v_cycle_index from app.stamp_progress_v323(p_business,p_client) sp;
    if not found then raise exception 'this business is not running a stamp card' using errcode='XX001'; end if;
    if coalesce(v_stamp_slots,0)<=0 then raise exception 'this stamp card has no length set' using errcode='23514'; end if;
    if v_version.cost_points>v_stamp_slots then raise exception 'this gift sits past the end of the stamp card' using errcode='23514'; end if;
    if v_stamp_filled<v_version.cost_points then raise exception 'not enough stamps yet' using errcode='check_violation'; end if;
  else
    v_points_spent:=v_version.cost_points;
    select coalesce(sum(remaining),0)::integer into v_batch_balance from public.points_batches where business_id=p_business and client_id=p_client and programme_id=v_reward_programme;
    if v_balance<v_version.cost_points or v_batch_balance<v_version.cost_points then raise exception 'insufficient proven points' using errcode='check_violation'; end if;
  end if;
  insert into public.loyalty_redemptions(id,business_id,client_id,reward_id,reward_name,points_spent,credit_cents,actor,reward_version_id,reward_snapshot,eligibility_snapshot,fulfillment_kind,entitlement_expires_at,usage_number,consumes_balance)
  values(v_redemption_id,p_business,p_client,p_reward,v_version.customer_name,v_points_spent,v_version.credit_cents,v_actor,v_version.id,
    to_jsonb(v_version)-'id'-'config_version_id'-'business_id'-'created_at',v_eligibility,v_version.fulfillment_kind,
    case when v_version.entitlement_expiry_days is null then null else now()+make_interval(days=>v_version.entitlement_expiry_days) end,v_usage+1,v_consumes);
  insert into public.loyalty_redemption_provenance
    (id,business_id,client_id,operation_id,redemption_id,points_ledger_id,credit_ledger_id,config_version_id,consumes_balance)
  values(v_provenance_id,p_business,p_client,v_operation_id,v_redemption_id,case when v_consumes then v_points_id end,
    case when v_version.credit_cents>0 then gen_random_uuid() end,v_version.config_version_id,v_consumes)
  returning credit_ledger_id into v_credit_id;
  if v_consumes then
  v_remaining:=v_version.cost_points;
  for v_batch in select id,remaining from public.points_batches where business_id=p_business and client_id=p_client and remaining>0 and programme_id=v_reward_programme order by expires_at nulls last,earned_at,id for update loop
    exit when v_remaining=0; v_take:=least(v_batch.remaining,v_remaining);
    update public.points_batches set remaining=remaining-v_take where id=v_batch.id;
    insert into public.loyalty_redemption_batch_drains
      (provenance_id,business_id,client_id,redemption_id,points_batch_id,drained_points)
    values(v_provenance_id,p_business,p_client,v_redemption_id,v_batch.id,v_take);
    v_remaining:=v_remaining-v_take;
  end loop;
  perform set_config('app.points_ledger_insert_id',v_points_id::text,true); perform set_config('app.points_ledger_write_scope','redeem_points',true);
  insert into public.points_ledger(id,business_id,client_id,entry_type,points,reference,actor,programme_id) values(v_points_id,p_business,p_client,'redeem',-v_version.cost_points,'reward: '||v_version.customer_name,v_actor,v_reward_programme);
  perform set_config('app.points_ledger_insert_id','',true); perform set_config('app.points_ledger_write_scope','',true);
  else
    begin
      insert into public.stamp_milestone_claims(
        business_id,programme_id,client_id,cycle_index,slot_position,reward_id,reward_version_id,
        redemption_id,config_version_id,is_final,actor)
      values(p_business,v_reward_programme,p_client,v_cycle_index,v_version.cost_points,p_reward,
        v_version.id,v_redemption_id,v_version.config_version_id,v_version.cost_points>=v_stamp_slots,v_actor);
      if v_version.cost_points>=v_stamp_slots then
        v_cycle_id:=gen_random_uuid();
        insert into public.stamp_cycles(
          id,business_id,programme_id,client_id,cycle_index,slots,origin,redemption_id,reward_id,
          config_version_id,actor)
        values(v_cycle_id,p_business,v_reward_programme,p_client,v_cycle_index,v_stamp_slots,'claimed',
          v_redemption_id,p_reward,v_version.config_version_id,v_actor);
      end if;
    exception when unique_violation then
      raise exception 'this stamp gift has already been claimed on this card' using errcode='23505';
    end;
  end if;
  if v_credit_id is not null then
    perform set_config('app.credit_ledger_insert_id',v_credit_id::text,true); perform set_config('app.credit_ledger_write_scope','redeem_points',true);
    insert into public.credit_ledger(id,business_id,client_id,entry_type,amount_cents,reference,actor) values(v_credit_id,p_business,p_client,'loyalty_earn',v_version.credit_cents,'loyalty reward: '||v_version.customer_name,v_actor);
    perform set_config('app.credit_ledger_insert_id','',true); perform set_config('app.credit_ledger_write_scope','',true);
  end if;
  v_result:=json_build_object('ok',true,'redemption_id',v_redemption_id,
    'reward_version_id',v_version.id,'reward',v_version.customer_name,
    'points_spent',v_points_spent,'credit_cents',v_version.credit_cents,
    'consumes_balance',v_consumes,
    'stamp_slot',case when v_programme_kind='stamps' then v_version.cost_points end,
    'stamp_cycle_index',v_cycle_index,'stamp_card_closed',v_cycle_id is not null);
  perform set_config('app.loyalty_operation_complete_id',v_operation_id::text,true);
  update public.loyalty_operations set status='completed',result=v_result::jsonb,completed_at=now() where id=v_operation_id;
  perform set_config('app.loyalty_operation_complete_id','',true); return v_result;
end $function$;

-- customer_create_redemption_intent_v89: exclude paused gifts from self-serve QR redemption.
CREATE OR REPLACE FUNCTION public.customer_create_redemption_intent_v89(p_business uuid, p_reward uuid, p_idempotency_key uuid, p_redemption_kind text DEFAULT 'catalog_reward'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'app', 'extensions', 'pg_temp'
AS $function$
declare
  v_identity uuid;v_client uuid;v_reward public.loyalty_rewards%rowtype;
  v_program public.loyalty_programs%rowtype;
  v_reward_version public.loyalty_reward_versions%rowtype;
  v_existing public.customer_redemption_intents_v89%rowtype;
  v_token text;v_hash text;v_request_hash text;
  v_quote jsonb;
  v_balance integer;v_batch_balance integer;v_cost_points integer;
  v_kind text:=lower(btrim(coalesce(p_redemption_kind,'')));
  v_intent uuid:=gen_random_uuid();
  v_expires timestamptz:=now()+interval '5 minutes';v_response jsonb;
  v_intent_programme uuid;
  v_intent_programme_kind text;
  v_stamp_filled integer;
  v_stamp_cycle integer;
begin
  if p_idempotency_key is null then
    raise exception 'idempotency key is required' using errcode='22023';
  end if;
  if v_kind not in ('classic_points','catalog_reward') then
    raise exception 'unsupported redemption kind' using errcode='22023';
  end if;
  if (v_kind='classic_points' and p_reward is not null)
     or (v_kind='catalog_reward' and p_reward is null) then
    raise exception 'redemption kind and reward do not match' using errcode='22023';
  end if;
  if not app.platform_feature_enabled('customer_qr_redemption') then
    raise exception 'customer QR redemption is unavailable' using errcode='0A000';
  end if;
  -- v229: this firm uses points for tier membership, not redemption. Refused here, before
  -- identity resolution, so the rule holds for every caller.
  if not exists(select 1 from public.business_programmes spine
             where spine.business_id=p_business and spine.active
               and spine.kind in ('points','stamps')) then
    raise exception 'this business is not running a programme you can redeem from'
      using errcode='0A000';
  end if;
  v_identity:=app.v31_current_identity();
  v_request_hash:=app.v89_sha256(p_business::text||':'||v_kind||':'||
    coalesce(p_reward::text,'classic'));
  perform pg_advisory_xact_lock(hashtextextended(
    'v89:redemption-intent:'||v_identity::text||':'||p_idempotency_key::text,0));
  select * into v_existing from public.customer_redemption_intents_v89 intent
  where intent.identity_id=v_identity and intent.idempotency_key=p_idempotency_key
  for update;
  if found then
    if v_existing.request_hash<>v_request_hash then
      raise exception 'idempotency key conflicts with another redemption intent'
        using errcode='23505';
    end if;
    return jsonb_build_object('intent_id',v_existing.id,'status',v_existing.status,
      'redemption_kind',v_existing.redemption_kind,
      'qr_token',app.v89_redemption_token(v_identity,p_business,
        v_existing.redemption_kind,v_existing.reward_id,p_idempotency_key),
      'expires_at',v_existing.expires_at,'replayed',true);
  end if;
  if not coalesce((select capability.redemption_enabled
    from public.business_customer_capabilities_v89 capability
    where capability.business_id=p_business),false)
     or not app.v89_business_module_enabled(p_business,'loyalty') then
    raise exception 'customer redemption is disabled for this business'
      using errcode='42501';
  end if;
  select link.client_id into v_client from public.customer_links link
  where link.identity_id=v_identity and link.auth_user_id=auth.uid()
    and link.business_id=p_business and link.state='verified' for share;
  if not found then raise exception 'verified customer link required' using errcode='42501';end if;
  select * into v_program from public.loyalty_programs program
  where program.business_id=p_business and program.active order by program.id limit 1;
  if not found then raise exception 'loyalty redemption is unavailable' using errcode='22023';end if;
  if v_kind='classic_points' then
    if v_program.kind<>'points' or v_program.loyalty_model<>'classic'
       or v_program.redeem_points<=0 or v_program.reward_credit_cents<=0 then
      raise exception 'classic points redemption is unavailable' using errcode='22023';
    end if;
    v_cost_points:=v_program.redeem_points;
    v_quote:=jsonb_build_object(
      'program_id',v_program.id,
      'config_version_id',v_program.current_config_version_id,
      'loyalty_model',v_program.loyalty_model,'kind',v_program.kind,
      'points_spent',v_program.redeem_points,
      'credit_cents',v_program.reward_credit_cents);
  else
    if not exists(select 1 from public.business_programmes spine
                   where spine.business_id=p_business and spine.active
                     and spine.kind in ('points','stamps')) then
      raise exception 'catalog redemption is unavailable' using errcode='22023';
    end if;
    select * into v_reward from public.loyalty_rewards reward
    where reward.id=p_reward and reward.business_id=p_business and reward.active and not reward.paused;
    if not found then
      raise exception 'reward is unavailable' using errcode='22023';
    end if;
    select reward_version.* into v_reward_version
    from public.loyalty_reward_versions reward_version
    join public.businesses business on business.id=reward_version.business_id
    where reward_version.reward_id=p_reward
      and reward_version.business_id=p_business
      and reward_version.config_version_id=business.active_config_version_id
      and reward_version.active;
    if not found
       or (v_reward_version.claim_available_from is not null
         and v_reward_version.claim_available_from>now())
       or (v_reward_version.claim_available_until is not null
         and v_reward_version.claim_available_until<=now()) then
      raise exception 'reward is unavailable' using errcode='22023';
    end if;
    if exists(select 1 from public.loyalty_reward_branches restriction
         where restriction.reward_version_id=v_reward_version.id)
       or exists(select 1 from public.loyalty_reward_services restriction
         where restriction.reward_version_id=v_reward_version.id)
       or exists(select 1 from public.loyalty_reward_products restriction
         where restriction.reward_version_id=v_reward_version.id) then
      raise exception 'context-restricted rewards require staff-assisted redemption'
        using errcode='22023';
    end if;
    if v_reward_version.usage_limit is not null and (
      select count(*) from public.loyalty_redemptions redemption
      where redemption.business_id=p_business
        and redemption.client_id=v_client and redemption.reward_id=p_reward
    )>=v_reward_version.usage_limit then
      raise exception 'reward usage limit reached' using errcode='23514';
    end if;
    v_cost_points:=v_reward_version.cost_points;
    v_quote:=jsonb_build_object(
      'program_id',v_program.id,
      'config_version_id',v_reward_version.config_version_id,
      'reward_version_id',v_reward_version.id,'reward_id',p_reward,
      'points_spent',v_reward_version.cost_points,
      'credit_cents',v_reward_version.credit_cents,
      'fulfillment_kind',v_reward_version.fulfillment_kind,
      'claim_available_from',v_reward_version.claim_available_from,
      'claim_available_until',v_reward_version.claim_available_until,
      'usage_limit',v_reward_version.usage_limit,
      'active',v_reward_version.active);
  end if;
  v_intent_programme:=case when v_kind='catalog_reward' then v_reward_version.programme_id
    else (select spine.id from public.business_programmes spine
           where spine.business_id=p_business and spine.kind='points') end;
  if v_intent_programme is null then
    raise exception 'redemption programme is not resolvable for this business' using errcode='XX001';
  end if;
  if not exists(select 1 from public.business_programmes spine
                 where spine.id=v_intent_programme and spine.active) then
    raise exception 'this reward''s programme is not running right now' using errcode='0A000';
  end if;
  select spine.kind into v_intent_programme_kind from public.business_programmes spine
   where spine.id=v_intent_programme;
  if v_intent_programme_kind='stamps' then
    select sp.filled,sp.cycle_index into v_stamp_filled,v_stamp_cycle
      from app.stamp_progress_v323(p_business,v_client) sp;
    if not found then
      raise exception 'this business is not running a stamp card' using errcode='23514';
    end if;
    if coalesce(v_stamp_filled,0)<v_cost_points then
      raise exception 'not enough stamps yet' using errcode='23514';
    end if;
    if exists(select 1 from public.stamp_milestone_claims claim
               where claim.business_id=p_business and claim.client_id=v_client
                 and claim.programme_id=v_intent_programme
                 and claim.cycle_index=v_stamp_cycle
                 and (claim.slot_position=v_cost_points or claim.reward_id=p_reward)) then
      raise exception 'this stamp gift has already been claimed on this card' using errcode='23514';
    end if;
  else
  select coalesce(sum(points),0)::integer into v_balance from public.points_ledger
  where business_id=p_business and client_id=v_client;
  select coalesce(sum(remaining),0)::integer into v_batch_balance
    from public.points_batches
    where business_id=p_business and client_id=v_client and remaining>0
      and programme_id=v_intent_programme;
  if least(v_balance,v_batch_balance)<v_cost_points then
    raise exception 'insufficient points' using errcode='23514';
  end if;
  end if;
  v_token:=app.v89_redemption_token(
    v_identity,p_business,v_kind,p_reward,p_idempotency_key);
  v_hash:=app.v89_sha256(v_token);
  insert into public.customer_redemption_intents_v89(
    id,business_id,identity_id,auth_user_id,client_id,redemption_kind,reward_id,
    quoted_program_id,quoted_config_version_id,quoted_reward_version_id,
    quoted_points_spent,quoted_credit_cents,quoted_terms,
    token_hash,idempotency_key,request_hash,expires_at
  ) values(
    v_intent,p_business,v_identity,auth.uid(),v_client,v_kind,p_reward,
    v_program.id,
    case when v_kind='catalog_reward' then v_reward_version.config_version_id
      else v_program.current_config_version_id end,
    case when v_kind='catalog_reward' then v_reward_version.id else null end,
    v_cost_points,
    case when v_kind='catalog_reward' then v_reward_version.credit_cents
      else v_program.reward_credit_cents end,
    v_quote,
    v_hash,p_idempotency_key,v_request_hash,v_expires
  );
  insert into public.customer_redemption_events_v89(
    intent_id,business_id,actor,event_type,idempotency_key,detail
  ) values(
    v_intent,p_business,auth.uid(),'intent_created',p_idempotency_key,
    jsonb_build_object('redemption_kind',v_kind,'reward_id',p_reward,
      'expires_at',v_expires)
  );
  v_response:=jsonb_build_object('intent_id',v_intent,'status','pending',
    'redemption_kind',v_kind,'qr_token',v_token,'expires_at',v_expires,
    'replayed',false);
  return v_response;
end
$function$;

revoke execute on function public.customer_create_redemption_intent_v89(uuid, uuid, uuid, text) from public;

-- customer_get_business_actions_v89: exclude paused gifts from the customer actionable list.
CREATE OR REPLACE FUNCTION public.customer_get_business_actions_v89(p_business uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'app', 'pg_temp'
AS $function$
declare
  v_identity uuid;v_client uuid;v_result jsonb;
  v_balance integer;v_batch_balance integer;
  v_program public.loyalty_programs%rowtype;
  v_stamps_programme uuid;v_stamp_filled integer;v_stamp_cycle integer;
begin
  v_identity:=app.v31_current_identity();
  select link.client_id into v_client from public.customer_links link
  where link.identity_id=v_identity and link.auth_user_id=auth.uid()
    and link.business_id=p_business and link.state='verified';
  if not found then raise exception 'verified customer link required' using errcode='42501';end if;
  select coalesce(sum(points),0)::integer into v_balance from public.points_ledger
    where business_id=p_business and client_id=v_client;
  select coalesce(sum(remaining),0)::integer into v_batch_balance
    from public.points_batches
    where business_id=p_business and client_id=v_client and remaining>0;
  select spine.id into v_stamps_programme from public.business_programmes spine
    where spine.business_id=p_business and spine.kind='stamps';
  select coalesce(sp.filled,0),coalesce(sp.cycle_index,0)
    into v_stamp_filled,v_stamp_cycle
    from app.stamp_progress_v323(p_business,v_client) sp;
  select * into v_program from public.loyalty_programs program
    where program.business_id=p_business and program.active
    order by program.id limit 1;
  select jsonb_build_object(
    'business',jsonb_build_object('id',business.id,'slug',business.slug,
      'name',business.name,'industry',business.industry,'currency',business.currency),
    'booking',jsonb_build_object('enabled',
      coalesce(capability.booking_enabled,false)
      and app.v89_business_module_enabled(p_business,'bookings') and exists(
        select 1 from public.services service where service.business_id=p_business
          and service.active and service.show_on_booking_page),
      'public_slug',case when coalesce(capability.booking_enabled,false)
        and app.v89_business_module_enabled(p_business,'bookings') and exists(
        select 1 from public.services service where service.business_id=p_business
          and service.active and service.show_on_booking_page)
        then business.slug else null end),
    'redemption',jsonb_build_object(
      'enabled',coalesce(capability.redemption_enabled,false)
        and app.v89_business_module_enabled(p_business,'loyalty')
        and v_program.id is not null,
      'classic',case when v_program.loyalty_model='classic'
        and v_program.kind='points'
        and v_program.redeem_points>0 and v_program.reward_credit_cents>0
        then jsonb_build_object(
          'redemption_kind','classic_points',
          'name',concat('Redeem ',v_program.redeem_points,' points'),
          'cost_points',v_program.redeem_points,
          'credit_cents',v_program.reward_credit_cents,
          'availability',case
            when not coalesce(capability.redemption_enabled,false)
              or not app.v89_business_module_enabled(p_business,'loyalty')
              then 'disabled'
            when least(v_balance,v_batch_balance)<v_program.redeem_points
              then 'insufficient_balance'
            else 'available_at_counter' end)
        else null end),
    'appointment_changes',jsonb_build_object(
      'enabled',coalesce(capability.appointment_changes_enabled,false)
        and app.v89_business_module_enabled(p_business,'appointments')),
    'rewards',coalesce((
      select jsonb_agg(jsonb_build_object(
        'id',reward.id,'name',coalesce(reward.customer_name,reward.name),
        'redemption_kind','catalog_reward',
        'cost_points',reward_version.cost_points,
        'availability',case
          when not coalesce(capability.redemption_enabled,false)
            or not app.v89_business_module_enabled(p_business,'loyalty')
            then 'disabled'
          when reward_version.claim_available_from is not null
            and reward_version.claim_available_from>now() then 'not_started'
          when reward_version.claim_available_until is not null
            and reward_version.claim_available_until<=now() then 'ended'
          when reward_version.usage_limit is not null and (
            select count(*) from public.loyalty_redemptions redemption
            where redemption.business_id=p_business
              and redemption.client_id=v_client
              and redemption.reward_id=reward.id
          )>=reward_version.usage_limit then 'limit_reached'
          when v_stamps_programme is not null and reward.programme_id=v_stamps_programme
            and exists(select 1 from public.stamp_milestone_claims claim
                        where claim.business_id=p_business and claim.client_id=v_client
                          and claim.programme_id=v_stamps_programme
                          and claim.cycle_index=coalesce(v_stamp_cycle,0)
                          and claim.reward_id=reward.id)
            then 'limit_reached'
          when (case when v_stamps_programme is not null and reward.programme_id=v_stamps_programme
                     then coalesce(v_stamp_filled,0)
                     else least(v_balance,v_batch_balance) end)<reward_version.cost_points
            then 'insufficient_balance'
          else 'available_at_counter' end
      ) order by reward.sort,reward.id)
      from public.loyalty_rewards reward
      join public.loyalty_reward_versions reward_version
        on reward_version.reward_id=reward.id
       and reward_version.business_id=reward.business_id
      where reward.business_id=p_business and reward.active and not reward.paused
        and exists(select 1 from public.business_programmes spine
                    where spine.id=reward.programme_id and spine.active)
        and reward_version.config_version_id=business.active_config_version_id
        and reward_version.active
        -- Customer QR redemption carries no visit context in v89. Restricted
        -- rewards remain visible through the ordinary wallet catalog, but are
        -- truthfully excluded from this actionable scan list.
        and not exists(select 1 from public.loyalty_reward_branches restriction
          where restriction.reward_version_id=reward_version.id)
        and not exists(select 1 from public.loyalty_reward_services restriction
          where restriction.reward_version_id=reward_version.id)
        and not exists(select 1 from public.loyalty_reward_products restriction
          where restriction.reward_version_id=reward_version.id)
    ),'[]'::jsonb)
  ) into v_result
  from public.businesses business
  left join public.business_customer_capabilities_v89 capability
    on capability.business_id=business.id
  where business.id=p_business;
  return v_result;
end
$function$;

revoke execute on function public.customer_get_business_actions_v89(uuid) from public;

-- customer_get_business_presentation_v95: exclude paused gifts from the customer catalogue.
CREATE OR REPLACE FUNCTION public.customer_get_business_presentation_v95(p_business uuid, p_branch uuid DEFAULT NULL::uuid, p_locale text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'app', 'pg_temp'
AS $function$
declare
  v_actor uuid:=auth.uid();v_identity uuid;v_client uuid;v_branch uuid:=p_branch;
  v_locale text;v_programme uuid;v_balance integer:=0;v_unit text:='points';
  v_metric numeric:=0;v_basis text;v_points_programme uuid;
  v_current public.loyalty_tiers%rowtype;
  v_next public.loyalty_tiers%rowtype;v_progress numeric:=0;v_result jsonb;
begin
  if v_actor is null then raise exception 'authenticated_session_required'
    using errcode='28000';end if;
  if p_locale is not null and p_locale not in ('en','zh-CN') then
    raise exception 'unsupported_locale' using errcode='22023';end if;
  v_identity:=app.v31_current_identity();
  select link.client_id into v_client from public.customer_links link
  where link.identity_id=v_identity and link.auth_user_id=v_actor
    and link.business_id=p_business and link.state='verified';
  if not found then raise exception 'verified_customer_link_required'
    using errcode='42501';end if;
  v_locale:=coalesce(
    p_locale,(select locale from public.customer_locale_preferences_v95
      where auth_user_id=v_actor),'en'
  );
  if v_branch is null then
    select id into v_branch from public.branches
    where business_id=p_business and active
    order by is_default desc,created_at,id limit 1;
  end if;
  if v_branch is null or not exists(
    select 1 from public.branches
    where id=v_branch and business_id=p_business and active
  ) then raise exception 'active_branch_required' using errcode='22023';end if;
  select id,case when loyalty_model='stamps' then 'stamps' else 'points' end,
    coalesce(tier_basis,'visits')
  into v_programme,v_unit,v_basis
  from public.loyalty_programs
  where business_id=p_business and active
  order by (current_config_version_id is not null) desc,id limit 1;
  select coalesce(sum(points),0)::integer into v_balance
  from public.points_ledger
  where business_id=p_business and client_id=v_client;
  if v_basis='spend' then
    select coalesce(sum(amount_cents),0)/100.0 into v_metric from public.sales
    where business_id=p_business and client_id=v_client and counts_as_revenue;
  elsif v_basis='points_earned' then
    select spine.id into v_points_programme
    from public.business_programmes spine
    where spine.business_id=p_business and spine.kind='points';
    if v_points_programme is null then
      select coalesce(sum(points),0) into v_metric from public.points_ledger
      where business_id=p_business and client_id=v_client and entry_type='earn';
    else
      select coalesce(sum(ledger.points),0) into v_metric from public.points_ledger ledger
      where ledger.business_id=p_business and ledger.client_id=v_client
        and ledger.entry_type='earn' and ledger.programme_id=v_points_programme;
    end if;
  else
    select count(*) into v_metric from public.sales
    where business_id=p_business and client_id=v_client and counts_as_visit;
  end if;
  select * into v_current from public.loyalty_tiers
  where business_id=p_business and threshold<=v_metric
  order by threshold desc,sort desc,id limit 1;
  select * into v_next from public.loyalty_tiers
  where business_id=p_business and threshold>coalesce(v_current.threshold,-1)
  order by threshold,sort,id limit 1;
  if v_next.id is not null then
    v_progress:=greatest(0,least(100,round(
      (v_metric-coalesce(v_current.threshold,0))*100
      /nullif(v_next.threshold-coalesce(v_current.threshold,0),0),2
    )));
  elsif v_current.id is not null then v_progress:=100;end if;

  with programme_copy as (
    select copy.* from public.business_localized_copy_v95 copy
    where copy.business_id=p_business and copy.entity_type='programme'
      and copy.entity_id=v_programme and copy.locale=v_locale
    limit 1
  ), programme_english as (
    select copy.* from public.business_localized_copy_v95 copy
    where copy.business_id=p_business and copy.entity_type='programme'
      and copy.entity_id=v_programme and copy.locale='en'
    limit 1
  ), visible_media as (
    select distinct on(asset.asset_kind,asset.entity_id)
      asset.asset_kind,asset.entity_id,
      app.v95_public_media_url(asset.object_path) url
    from public.business_media_assets_v95 asset
    where asset.business_id=p_business and asset.customer_visible
      and (asset.branch_id is null or asset.branch_id=v_branch)
    order by asset.asset_kind,asset.entity_id,
      (asset.branch_id=v_branch) desc,asset.updated_at desc,asset.id
  ), benefits as (
    select coalesce(jsonb_agg(jsonb_build_object(
      'id',content.id,
      'name',coalesce(copy.name,english.name,'Benefit'),
      'tagline',coalesce(copy.tagline,english.tagline),
      'description',coalesce(copy.description,english.description),
      'image_url',media.url,'metadata',content.metadata
    ) order by content.display_order,content.id),'[]'::jsonb) value
    from public.business_customer_content_v95 content
    left join public.business_localized_copy_v95 copy
      on copy.business_id=p_business and copy.entity_type='benefit'
      and copy.entity_id=content.id and copy.locale=v_locale
    left join public.business_localized_copy_v95 english
      on english.business_id=p_business and english.entity_type='benefit'
      and english.entity_id=content.id and english.locale='en'
    left join visible_media media
      on media.asset_kind='benefit' and media.entity_id=content.id
    where content.business_id=p_business and content.content_type='benefit'
      and content.active and (content.branch_id is null or content.branch_id=v_branch)
      and (content.starts_at is null or content.starts_at<=now())
      and (content.ends_at is null or content.ends_at>now())
  ), offers as (
    select coalesce(jsonb_agg(jsonb_build_object(
      'id',content.id,
      'name',coalesce(copy.name,english.name,'Offer'),
      'tagline',coalesce(copy.tagline,english.tagline),
      'description',coalesce(copy.description,english.description),
      'terms',coalesce(copy.terms,english.terms),
      'image_url',media.url,'starts_at',content.starts_at,
      'ends_at',content.ends_at,'metadata',content.metadata
    ) order by content.display_order,content.id),'[]'::jsonb) value
    from public.business_customer_content_v95 content
    left join public.business_localized_copy_v95 copy
      on copy.business_id=p_business and copy.entity_type='offer'
      and copy.entity_id=content.id and copy.locale=v_locale
    left join public.business_localized_copy_v95 english
      on english.business_id=p_business and english.entity_type='offer'
      and english.entity_id=content.id and english.locale='en'
    left join visible_media media
      on media.asset_kind='offer' and media.entity_id=content.id
    where content.business_id=p_business and content.content_type='offer'
      and content.active and (content.branch_id is null or content.branch_id=v_branch)
      and (content.starts_at is null or content.starts_at<=now())
      and (content.ends_at is null or content.ends_at>now())
  ), services_json as (
    select coalesce(jsonb_agg(jsonb_build_object(
      'id',service.id,'name',coalesce(copy.name,english.name,service.name),
      'description',coalesce(copy.description,english.description),
      'image_url',media.url,'price_cents',service.price_cents,
      'duration_min',service.duration_min
    ) order by service.name,service.id),'[]'::jsonb) value
    from public.services service
    left join public.business_localized_copy_v95 copy
      on copy.business_id=p_business and copy.entity_type='service'
      and copy.entity_id=service.id and copy.locale=v_locale
    left join public.business_localized_copy_v95 english
      on english.business_id=p_business and english.entity_type='service'
      and english.entity_id=service.id and english.locale='en'
    left join visible_media media
      on media.asset_kind='service' and media.entity_id=service.id
    where service.business_id=p_business and service.active
      and service.show_on_booking_page
      and (not exists(select 1 from public.service_branches configured
        where configured.business_id=p_business and configured.service_id=service.id)
        or exists(select 1 from public.service_branches available
          where available.business_id=p_business and available.service_id=service.id
            and available.branch_id=v_branch))
  ), products_json as (
    select coalesce(jsonb_agg(jsonb_build_object(
      'id',product.id,'name',coalesce(copy.name,english.name,product.name),
      'description',coalesce(copy.description,english.description),
      'image_url',media.url,'price_cents',product.retail_price_cents
    ) order by product.name,product.id),'[]'::jsonb) value
    from public.products product
    left join public.business_localized_copy_v95 copy
      on copy.business_id=p_business and copy.entity_type='product'
      and copy.entity_id=product.id and copy.locale=v_locale
    left join public.business_localized_copy_v95 english
      on english.business_id=p_business and english.entity_type='product'
      and english.entity_id=product.id and english.locale='en'
    left join visible_media media
      on media.asset_kind='product' and media.entity_id=product.id
    where product.business_id=p_business and product.active
  ), rewards_json as (
    select coalesce(jsonb_agg(jsonb_build_object(
      'id',reward.id,'name',coalesce(copy.name,english.name,reward.name),
      'description',coalesce(copy.description,english.description),
      'terms',coalesce(copy.terms,english.terms),
      'image_url',media.url,
      'metadata',jsonb_build_object(
        'cost_points',reward.cost_points,'credit_cents',reward.credit_cents
      )
    ) order by reward.sort,reward.id),'[]'::jsonb) value
    from public.loyalty_rewards reward
    left join public.business_localized_copy_v95 copy
      on copy.business_id=p_business and copy.entity_type='reward'
      and copy.entity_id=reward.id and copy.locale=v_locale
    left join public.business_localized_copy_v95 english
      on english.business_id=p_business and english.entity_type='reward'
      and english.entity_id=reward.id and english.locale='en'
    left join visible_media media
      on media.asset_kind='reward' and media.entity_id=reward.id
    where reward.business_id=p_business and reward.active and not reward.paused
  )
  select jsonb_build_object(
    'business_id',business.id,'branch_id',v_branch,'locale',v_locale,
    'available_locales',jsonb_build_array('en','zh-CN'),
    'brand',jsonb_build_object(
      'logo_url',app.v95_public_media_url(logo.object_path),
      'hero_image_url',app.v95_public_media_url(hero.object_path),
      'hero_color',brand.hero_color
    ),
    'programme',jsonb_build_object(
      'id',v_programme,
      'name',coalesce(programme_copy.name,programme_english.name,
        business.name||' Loyalty'),
      'tagline',coalesce(programme_copy.tagline,programme_english.tagline),
      'description',coalesce(
        programme_copy.description,programme_english.description
      ),
      'balance',v_balance,'unit',v_unit,
      'tier',jsonb_build_object(
        'label',coalesce(tier_copy.name,tier_english.name,v_current.name),
        'current',case when v_current.id is null then null else jsonb_build_object(
          'id',v_current.id,'threshold',v_current.threshold,'metric',v_metric
        ) end,
        'next',case when v_next.id is null then null else jsonb_build_object(
          'id',v_next.id,'label',coalesce(next_copy.name,next_english.name,v_next.name),
          'threshold',v_next.threshold
        ) end,
        'progress_percent',v_progress
      ),
      'benefits',benefits.value,'offers',offers.value
    ),
    'catalogue',jsonb_build_object(
      'services',services_json.value,'products',products_json.value,
      'rewards',rewards_json.value
    ),
    'capabilities',jsonb_build_object(
      'booking_enabled',coalesce(capability.booking_enabled,false)
        and app.v89_business_module_enabled(p_business,'bookings')
        and jsonb_array_length(services_json.value)>0,
      'redemption_enabled',coalesce(capability.redemption_enabled,false)
        and app.v89_business_module_enabled(p_business,'loyalty')
        and v_programme is not null,
      'appointment_changes_enabled',
        coalesce(capability.appointment_changes_enabled,false)
        and app.v89_business_module_enabled(p_business,'appointments')
    )
  ) into v_result
  from public.businesses business
  join public.business_brand_presentation_v95 brand
    on brand.business_id=business.id
  left join public.business_media_assets_v95 logo
    on logo.id=brand.logo_asset_id and logo.customer_visible
    and (logo.branch_id is null or logo.branch_id=v_branch)
  left join public.business_media_assets_v95 hero
    on hero.id=brand.hero_asset_id and hero.customer_visible
    and (hero.branch_id is null or hero.branch_id=v_branch)
  left join public.business_customer_capabilities_v89 capability
    on capability.business_id=business.id
  left join programme_copy on true
  left join programme_english on true
  left join public.business_localized_copy_v95 tier_copy
    on tier_copy.business_id=p_business and tier_copy.entity_type='tier'
    and tier_copy.entity_id=v_current.id and tier_copy.locale=v_locale
  left join public.business_localized_copy_v95 tier_english
    on tier_english.business_id=p_business and tier_english.entity_type='tier'
    and tier_english.entity_id=v_current.id and tier_english.locale='en'
  left join public.business_localized_copy_v95 next_copy
    on next_copy.business_id=p_business and next_copy.entity_type='tier'
    and next_copy.entity_id=v_next.id and next_copy.locale=v_locale
  left join public.business_localized_copy_v95 next_english
    on next_english.business_id=p_business and next_english.entity_type='tier'
    and next_english.entity_id=v_next.id and next_english.locale='en'
  cross join benefits cross join offers cross join services_json
  cross join products_json cross join rewards_json
  where business.id=p_business;
  return v_result;
end
$function$;

revoke execute on function public.customer_get_business_presentation_v95(uuid, uuid, text) from public;

-- staff_get_customer_actionable_loyalty_v145: exclude paused gifts from the till's candidate list.
CREATE OR REPLACE FUNCTION public.staff_get_customer_actionable_loyalty_v145(p_business uuid, p_client uuid, p_branch uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'app', 'pg_temp'
AS $function$
declare
  v_as_of timestamptz := statement_timestamp();
  v_result jsonb;
begin
  perform public.require_module_scope_v145(
    p_business, p_branch, 'clients'
  );
  perform public.require_module_scope_v145(
    p_business, p_branch, 'loyalty'
  );
  if not exists (
    select 1
      from public.clients client
     where client.id = p_client
       and client.business_id = p_business
  ) then
    raise exception 'customer not found in business'
      using errcode = '22023';
  end if;

  with program as (
    select
      loyalty.id,
      loyalty.kind,
      loyalty.loyalty_model,
      loyalty.earn_points_per_dollar,
      loyalty.redeem_points,
      loyalty.reward_credit_cents,
      loyalty.stamp_per_cents,
      loyalty.expiry_mode,
      loyalty.configuration_status,
      coalesce(loyalty.active, false)
        and loyalty.configuration_status = 'published' as enabled,
      business.active_config_version_id
    from public.businesses business
    left join public.loyalty_programs loyalty
      on loyalty.business_id = business.id
    where business.id = p_business
  ), ledger_balance as (
    select greatest(coalesce(sum(ledger.points), 0), 0)::integer as units
      from public.points_ledger ledger
     where ledger.business_id = p_business
       and ledger.client_id = p_client
  ), unexpired_batches as (
    select
      batch.id,
      batch.remaining,
      batch.earned_at,
      batch.expires_at,
      sum(batch.remaining) over (
        order by batch.expires_at nulls last, batch.earned_at, batch.id
        rows between unbounded preceding and current row
      )::bigint as cumulative_remaining
      from public.points_batches batch
     where batch.business_id = p_business
       and batch.client_id = p_client
       and batch.remaining > 0
       and (batch.expires_at is null or batch.expires_at > v_as_of)
  ), batch_balance as (
    select coalesce(sum(batch.remaining), 0)::integer as units
      from unexpired_batches batch
  ), loyalty_balance as (
    select case when program.enabled
      then greatest(least(ledger_balance.units, batch_balance.units), 0)
      else 0 end::integer as units
      from program cross join ledger_balance cross join batch_balance
  ), actionable_batches as (
    select
      batch.expires_at,
      least(
        batch.remaining::bigint,
        greatest(
          loyalty_balance.units::bigint
            - (batch.cumulative_remaining - batch.remaining::bigint),
          0
        )
      )::integer as actionable_remaining
      from unexpired_batches batch
      cross join loyalty_balance
     where loyalty_balance.units > 0
       and batch.cumulative_remaining - batch.remaining::bigint
           < loyalty_balance.units::bigint
  ), next_expiry as (
    select batch.expires_at,
           sum(batch.actionable_remaining)::integer as units
      from actionable_batches batch
     where batch.expires_at is not null
       and batch.actionable_remaining > 0
     group by batch.expires_at
     order by batch.expires_at
     limit 1
  ), credit_balance as (
    select greatest(coalesce(sum(ledger.amount_cents), 0), 0)::integer
      as balance_cents
      from public.credit_ledger ledger
     where ledger.business_id = p_business
       and ledger.client_id = p_client
  ), redemption_capability as (
    select (
      program.enabled
      and app.platform_feature_enabled('customer_qr_redemption')
      and coalesce(capability.redemption_enabled, false)
    ) as enabled
    from program
    left join public.business_customer_capabilities_v89 capability
      on capability.business_id = p_business
  ), candidate_rewards as (
    select
      'classic'::text as source,
      null::uuid as reward_id,
      concat(
        'SGD ',
        (program.reward_credit_cents::numeric / 100)::numeric(12,2),
        ' credit'
      )::text as name,
      program.redeem_points::integer as cost_units,
      program.reward_credit_cents::integer as credit_cents,
      'credit'::text as fulfillment_kind,
      0::integer as sort_order,
      greatest(program.redeem_points - loyalty_balance.units, 0)::integer
        as remaining_units,
      (redemption_capability.enabled
        and loyalty_balance.units >= program.redeem_points) as available_now
    from program
    cross join loyalty_balance
    cross join redemption_capability
    where program.enabled
      and program.loyalty_model = 'classic'
      and program.kind = 'points'
      and program.redeem_points > 0
      and program.reward_credit_cents > 0

    union all

    select
      'catalog'::text as source,
      reward_version.reward_id,
      reward_version.customer_name as name,
      reward_version.cost_points::integer as cost_units,
      reward_version.credit_cents::integer,
      reward_version.fulfillment_kind,
      reward_version.sort::integer as sort_order,
      greatest(reward_version.cost_points - loyalty_balance.units, 0)::integer
        as remaining_units,
      (redemption_capability.enabled
        and loyalty_balance.units >= reward_version.cost_points) as available_now
    from program
    cross join loyalty_balance
    cross join redemption_capability
    join public.loyalty_reward_versions reward_version
      on reward_version.business_id = p_business
     and reward_version.config_version_id = program.active_config_version_id
     and reward_version.active
    join public.loyalty_rewards reward
      on reward.id = reward_version.reward_id
     and reward.business_id = reward_version.business_id
     and reward.active
     and not reward.paused
    left join lateral (
      select count(*)::integer as used_count
        from public.loyalty_redemptions redemption
       where redemption.business_id = p_business
         and redemption.client_id = p_client
         and redemption.reward_id = reward_version.reward_id
    ) usage on true
    where program.enabled
      and program.loyalty_model <> 'classic'
      and (reward_version.claim_available_from is null
        or reward_version.claim_available_from <= v_as_of)
      and (reward_version.claim_available_until is null
        or reward_version.claim_available_until > v_as_of)
      and (reward_version.usage_limit is null
        or usage.used_count < reward_version.usage_limit)
      and not exists (
        select 1 from public.loyalty_reward_branches restriction
         where restriction.reward_version_id = reward_version.id
      )
      and not exists (
        select 1 from public.loyalty_reward_services restriction
         where restriction.reward_version_id = reward_version.id
      )
      and not exists (
        select 1 from public.loyalty_reward_products restriction
         where restriction.reward_version_id = reward_version.id
      )
  ), reward_list as (
    select coalesce(jsonb_agg(jsonb_build_object(
      'source', candidate.source,
      'reward_id', candidate.reward_id,
      'name', candidate.name,
      'cost_units', candidate.cost_units,
      'credit_cents', candidate.credit_cents,
      'fulfillment_kind', candidate.fulfillment_kind,
      'remaining_units', candidate.remaining_units,
      'available_now', candidate.available_now
    ) order by candidate.remaining_units, candidate.sort_order,
      lower(candidate.name), candidate.reward_id nulls first), '[]'::jsonb)
      as rewards
      from candidate_rewards candidate
  ), next_reward as (
    select jsonb_build_object(
      'source', candidate.source,
      'reward_id', candidate.reward_id,
      'name', candidate.name,
      'cost_units', candidate.cost_units,
      'credit_cents', candidate.credit_cents,
      'fulfillment_kind', candidate.fulfillment_kind,
      'remaining_units', candidate.remaining_units,
      'available_now', candidate.available_now
    ) as reward
    from candidate_rewards candidate
    order by candidate.remaining_units, candidate.sort_order,
      lower(candidate.name), candidate.reward_id nulls first
    limit 1
  )
  select jsonb_build_object(
    'as_of', v_as_of,
    'program', case when program.id is null then null else jsonb_build_object(
      'id', program.id,
      'active', program.enabled,
      'kind', program.kind,
      'model', program.loyalty_model,
      'unit', case when program.loyalty_model = 'stamps'
        then 'stamps' else 'points' end,
      'earn_points_per_dollar', program.earn_points_per_dollar,
      'stamp_per_cents', program.stamp_per_cents,
      'redeem_points', program.redeem_points,
      'reward_credit_cents', program.reward_credit_cents,
      'expiry_mode', program.expiry_mode,
      'configuration_status', program.configuration_status
    ) end,
    'points_balance', loyalty_balance.units,
    'credit_balance_cents', credit_balance.balance_cents,
    'expiry', case
      when not program.enabled or program.expiry_mode = 'none'
        or next_expiry.expires_at is null then null
      else jsonb_build_object(
        'expires_at', next_expiry.expires_at,
        'units', next_expiry.units
      ) end,
    'redemption_enabled', redemption_capability.enabled,
    'rewards', reward_list.rewards,
    'next_reward', next_reward.reward
  ) into v_result
  from program
  cross join loyalty_balance
  cross join credit_balance
  cross join redemption_capability
  cross join reward_list
  left join next_expiry on true
  left join next_reward on true;

  return v_result;
end;
$function$;

revoke execute on function public.staff_get_customer_actionable_loyalty_v145(uuid, uuid, uuid) from public;

-- ============================================================================================
-- THREE NEW IMMEDIATE-WRITE RPCS (V326). Same authorization as set_programmes_v314 and
-- publish_loyalty_config: app.c45_owner_loyalty_write. Every write is audit_log'd.
-- ============================================================================================

CREATE OR REPLACE FUNCTION public.business_set_reward_paused_v326(p_business uuid, p_reward uuid, p_paused boolean)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'app', 'pg_temp'
AS $function$
declare
  v_row public.loyalty_rewards%rowtype;
begin
  if not app.c45_owner_loyalty_write(p_business) then
    raise exception 'owner loyalty configuration access required' using errcode='42501';
  end if;
  select * into v_row from public.loyalty_rewards
   where id=p_reward and business_id=p_business and active
   for update;
  if not found then
    raise exception 'gift not found in this business' using errcode='42704';
  end if;
  if v_row.paused is distinct from p_paused then
    update public.loyalty_rewards set paused=p_paused
     where id=p_reward and business_id=p_business;
    insert into public.audit_log(business_id,actor,action,entity,entity_id,detail)
    values(p_business,auth.uid(),case when p_paused then 'reward.paused' else 'reward.unpaused' end,
      'loyalty_rewards',p_reward,jsonb_build_object('name',coalesce(v_row.customer_name,v_row.name)));
  end if;
  return jsonb_build_object('status','ok','reward_id',p_reward,'paused',p_paused);
end
$function$;

revoke execute on function public.business_set_reward_paused_v326(uuid, uuid, boolean) from public;
grant execute on function public.business_set_reward_paused_v326(uuid, uuid, boolean) to authenticated;

CREATE OR REPLACE FUNCTION public.business_delete_reward_v326(p_business uuid, p_reward uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'app', 'pg_temp'
AS $function$
declare
  v_row public.loyalty_rewards%rowtype;
  v_draft_version uuid;
begin
  if not app.c45_owner_loyalty_write(p_business) then
    raise exception 'owner loyalty configuration access required' using errcode='42501';
  end if;
  select * into v_row from public.loyalty_rewards
   where id=p_reward and business_id=p_business and active
   for update;
  if not found then
    raise exception 'gift not found in this business' using errcode='42704';
  end if;

  update public.loyalty_rewards set active=false, paused=false
   where id=p_reward and business_id=p_business;

  -- V326: keep any currently OPEN draft's own version row in sync so that publishing an
  -- unrelated draft later cannot resurrect this delete. A *published* version row cannot be
  -- touched here (trg_loyalty_reward_versions_immutable) and does not need to be — nothing reads
  -- loyalty_reward_versions.active off a published row as a delete gate outside of the redeem
  -- paths, which now check loyalty_rewards.active/paused directly (see app.redeem_reward_core).
  select id into v_draft_version from public.firm_config_versions
   where business_id=p_business and status='draft' limit 1;
  if v_draft_version is not null then
    update public.loyalty_reward_versions set active=false
     where reward_id=p_reward and business_id=p_business
       and config_version_id=v_draft_version and active;
  end if;

  insert into public.audit_log(business_id,actor,action,entity,entity_id,detail)
  values(p_business,auth.uid(),'reward.deleted','loyalty_rewards',p_reward,
    jsonb_build_object('name',coalesce(v_row.customer_name,v_row.name)));

  return jsonb_build_object('status','ok','reward_id',p_reward,'mode','deleted');
end
$function$;

revoke execute on function public.business_delete_reward_v326(uuid, uuid) from public;
grant execute on function public.business_delete_reward_v326(uuid, uuid) to authenticated;

CREATE OR REPLACE FUNCTION public.business_create_reward_v326(p_business uuid, p_programme uuid, p_name text, p_points integer, p_credit_cents integer DEFAULT 0)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'app', 'pg_temp'
AS $function$
declare
  v_reward_id uuid:=gen_random_uuid();
  v_name text:=nullif(btrim(coalesce(p_name,'')),'');
  v_kind text:=case when coalesce(p_credit_cents,0)>0 then 'credit' else 'manual_item' end;
  v_active_version uuid;
  v_sort integer;
begin
  if not app.c45_owner_loyalty_write(p_business) then
    raise exception 'owner loyalty configuration access required' using errcode='42501';
  end if;
  if v_name is null then
    raise exception 'gift name is required' using errcode='22023';
  end if;
  if p_points is null or p_points<=0 then
    raise exception 'points must be a positive number' using errcode='22023';
  end if;
  if p_credit_cents is not null and p_credit_cents<0 then
    raise exception 'credit_cents cannot be negative' using errcode='22023';
  end if;
  if not exists(select 1 from public.business_programmes spine
                 where spine.id=p_programme and spine.business_id=p_business) then
    raise exception 'programme does not belong to this business' using errcode='42501';
  end if;
  select active_config_version_id into v_active_version
    from public.businesses where id=p_business;
  if v_active_version is null then
    raise exception 'this business has no published loyalty configuration yet' using errcode='XX001';
  end if;

  select coalesce(max(sort),0)+1 into v_sort from public.loyalty_rewards where business_id=p_business;

  -- Live row. programme_id is supplied explicitly (it is NOT NULL and this business may run
  -- more than one programme); app.reward_programme_tenant_guard_v313 still validates it belongs
  -- to p_business on insert.
  insert into public.loyalty_rewards(
    id,business_id,name,internal_name,customer_name,fulfillment_kind,cost_points,credit_cents,
    estimated_cost_cents,active,paused,sort,programme_id,current_config_version_id
  ) values(
    v_reward_id,p_business,v_name,v_name,v_name,v_kind,p_points,coalesce(p_credit_cents,0),
    coalesce(p_credit_cents,0),true,false,v_sort,p_programme,v_active_version
  );

  -- V326: the redemption-terms row every gated read actually joins against (cost_points,
  -- credit_cents, fulfillment_kind — never loyalty_rewards' own copies of those). Appending a
  -- row to an already-published config version is allowed (only UPDATE/DELETE on it are blocked
  -- by trg_loyalty_reward_versions_immutable) and is how a brand-new gift becomes redeemable
  -- immediately, without the owner opening or publishing a draft.
  insert into public.loyalty_reward_versions(
    reward_id,business_id,config_version_id,internal_name,customer_name,fulfillment_kind,
    cost_points,credit_cents,estimated_cost_cents,active,sort,programme_id
  ) values(
    v_reward_id,p_business,v_active_version,v_name,v_name,v_kind,
    p_points,coalesce(p_credit_cents,0),coalesce(p_credit_cents,0),true,v_sort,p_programme
  );

  insert into public.audit_log(business_id,actor,action,entity,entity_id,detail)
  values(p_business,auth.uid(),'reward.created','loyalty_rewards',v_reward_id,
    jsonb_build_object('name',v_name,'cost_points',p_points,'credit_cents',coalesce(p_credit_cents,0)));

  return jsonb_build_object('status','ok','reward_id',v_reward_id,'name',v_name,
    'cost_points',p_points,'credit_cents',coalesce(p_credit_cents,0));
end
$function$;

revoke execute on function public.business_create_reward_v326(uuid, uuid, text, integer, integer) from public;
grant execute on function public.business_create_reward_v326(uuid, uuid, text, integer, integer) to authenticated;

commit;
