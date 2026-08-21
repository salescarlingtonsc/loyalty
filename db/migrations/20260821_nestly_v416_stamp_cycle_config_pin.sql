-- nestly_v416 — a stamp card belongs to the setup it was started under.
--
-- OWNER RULING (2026-08-21, answering the stamp-card questions): when a gift changes, the change
-- applies "only from their next card" — a customer part-way through keeps the deal they started.
-- Together with photo 2's "pressing save would publish to live", that is the whole contract:
-- publish immediately, but never move the goalposts under someone who is already collecting.
--
-- WHAT WAS ACTUALLY WRONG. Three reads all resolved a firm's gifts through
-- businesses.active_config_version_id — i.e. whatever the owner published most recently:
--     customer_get_stamp_card_v323 -> join loyalty_reward_versions on b.active_config_version_id
--     app.redeem_reward_core       -> select rv.* into v_version ... on b.active_config_version_id
--     app.stamp_progress_v323      -> slots from loyalty_programs.stamp_target (the LIVE column)
-- So a customer on 4 of 5 stamps whose firm published a new setup found their card had silently
-- become a different card: different gifts, different milestones, and a different length.
--
-- WHAT THIS DOES. One resolver, app.stamp_cycle_version_v416, answers "which published
-- configuration governs this client's OPEN card", and all three reads ask it instead:
--   * no stamps on the current card -> today's active version. They have not started a card, so
--     there is nothing to protect and they get the newest setup. This is what makes the ruling
--     work: finishing a card and starting the next one picks up every change.
--   * otherwise -> the version that was in force when the FIRST stamp of this card landed.
-- firm_config_versions is already a complete history: exactly one row is 'published' at a time,
-- every superseded row keeps its published_at, and the timestamps are strictly increasing per
-- business. Superseded versions are deliberately INCLUDED — a mid-card customer is precisely the
-- one who must still be served an older one.
--
-- NO NEW TABLE, NO NEW WRITE. The cycle boundary is already recorded (stamp_cycles.closed_at) and
-- so is the first stamp (points_ledger). Nothing new is written on the sale path, on the claim
-- path, or by the daily jobs; this migration only changes how three existing reads choose a
-- version. That matters because the claim path is next to the money kernel and the smallest
-- change that can be correct is the one to make there.
--
-- A CONSEQUENCE, STATED ON PURPOSE. A gift added after a customer started their card is not on
-- that card — they cannot see it and cannot claim it until the card resets. That IS the ruling,
-- and both the customer's view and the counter now agree about it, which they did not before:
-- the card could show a gift the till would then refuse, or refuse one the card had shown.

begin;

-- ============================================================================================
-- 1. THE RESOLVER
-- ============================================================================================
create or replace function app.stamp_cycle_version_v416(
  p_business uuid, p_client uuid, p_programme uuid
)
returns uuid
language plpgsql
stable
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare
  v_last_close timestamptz;
  v_started timestamptz;
  v_version uuid;
begin
  if p_business is null or p_client is null or p_programme is null then
    return (select b.active_config_version_id from public.businesses b where b.id = p_business);
  end if;

  select max(sc.closed_at) into v_last_close
    from public.stamp_cycles sc
   where sc.business_id = p_business and sc.client_id = p_client
     and sc.programme_id = p_programme;

  /* The first stamp of the CURRENT card: the earliest positive ledger row for this programme
     since the last card closed. Only positive rows count — a correction that removes stamps must
     not be mistaken for the moment a card was started. */
  select min(pl.created_at) into v_started
    from public.points_ledger pl
   where pl.business_id = p_business and pl.client_id = p_client
     and pl.programme_id = p_programme and pl.points > 0
     and (v_last_close is null or pl.created_at > v_last_close);

  if v_started is null then
    -- Nothing collected on this card yet: no promise has been made, so the newest setup applies.
    return (select b.active_config_version_id from public.businesses b where b.id = p_business);
  end if;

  select fcv.id into v_version
    from public.firm_config_versions fcv
   where fcv.business_id = p_business
     and fcv.published_at is not null
     and fcv.published_at <= v_started
   order by fcv.published_at desc
   limit 1;

  /* A card started before this firm ever published one falls back to the active version rather
     than to nothing — a customer must never be left with no card at all. */
  return coalesce(v_version,
    (select b.active_config_version_id from public.businesses b where b.id = p_business));
end $$;

revoke all on function app.stamp_cycle_version_v416(uuid,uuid,uuid) from public, anon, authenticated;

comment on function app.stamp_cycle_version_v416(uuid,uuid,uuid) is
  'v416: the published configuration governing a client''s OPEN stamp card - the version in force '
  'when its first stamp landed, or the active version when the card is empty. Read by '
  'app.stamp_progress_v323, public.customer_get_stamp_card_v323 and app.redeem_reward_core so all '
  'three agree about which card a customer is actually filling.';

-- ============================================================================================
-- 2. THE CARD'S LENGTH FOLLOWS THE CARD
-- ============================================================================================
-- Identical to the v323 body except for `slots`, which was read from the LIVE
-- loyalty_programs.stamp_target and is now read from the pinned version's own
-- loyalty_program_versions.stamp_target. The live column remains the fallback: versions published
-- before frenly v322 R5 carry a null stamp_target, and those cards must keep working.
create or replace function app.stamp_progress_v323(p_business uuid, p_client uuid)
returns table(programme_id uuid, programme_active boolean, running_since timestamp with time zone,
              paused_since timestamp with time zone, slots integer, net_stamps integer,
              closed_slots integer, filled integer, cycle_index integer, ready boolean,
              pot_migrated boolean)
language sql
stable
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
  select spine.id,
         spine.active,
         spine.activated_at,
         spine.deactivated_at,
         target.stamp_target,
         coalesce(led.net, 0)::integer,
         coalesce(cyc.closed, 0)::integer,
         greatest(coalesce(led.net, 0) - coalesce(cyc.closed, 0), 0)::integer,
         coalesce(cyc.cycles, 0)::integer,
         target.stamp_target is not null
           and target.stamp_target > 0
           and greatest(coalesce(led.net, 0) - coalesce(cyc.closed, 0), 0) >= target.stamp_target,
         exists (select 1 from public.programme_pot_migrations m
                  where m.business_id = p_business and m.from_programme_id = spine.id)
    from public.business_programmes spine
    cross join lateral (
      select coalesce(
        (select lpv.stamp_target from public.loyalty_program_versions lpv
          where lpv.config_version_id
                = app.stamp_cycle_version_v416(p_business, p_client, spine.id)),
        (select prog.stamp_target from public.loyalty_programs prog
          where prog.business_id = p_business order by prog.id limit 1)
      ) as stamp_target
    ) target
    left join lateral (
      select coalesce(sum(pl.points), 0) as net
        from public.points_ledger pl
       where pl.business_id = p_business and pl.client_id = p_client
         and pl.programme_id = spine.id
    ) led on true
    left join lateral (
      select coalesce(sum(sc.slots), 0) as closed, count(*)::integer as cycles
        from public.stamp_cycles sc
       where sc.business_id = p_business and sc.client_id = p_client
         and sc.programme_id = spine.id
    ) cyc on true
   where spine.business_id = p_business and spine.kind = 'stamps'
$$;


-- ============================================================================================
-- 3. THE CUSTOMER'S CARD
-- ============================================================================================
-- v323's body, EXTRACTED from production and diffed rather than retyped: exactly one join
-- condition changed (5 lines, all shown in the commit). Every other clause — the availability
-- ladder, claimed_this_cycle, the tier gate, stamps_to_go — is byte-for-byte what shipped.
CREATE OR REPLACE FUNCTION public.customer_get_stamp_card_v323(p_business_slug text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'app', 'pg_temp'
AS $function$
declare
  v_context record;
  v_progress record;
  v_milestones jsonb;
  v_metric numeric;
begin
  if auth.uid() is null then
    raise exception 'authenticated customer session required' using errcode = '28000';
  end if;
  select * into v_context from app.v32_customer_wallet_context(p_business_slug) limit 1;
  if not found then
    raise exception 'verified customer link required' using errcode = '42501';
  end if;

  if not ('loyalty' = any(v_context.enabled_modules)) then
    return jsonb_build_object('enabled', false);
  end if;
  select * into v_progress
    from app.stamp_progress_v323(v_context.business_id, v_context.client_id) limit 1;
  if not found then
    return jsonb_build_object('enabled', false);
  end if;

  v_metric := app.v176_tier_gate_metric(v_context.business_id, v_context.client_id);

  select coalesce(jsonb_agg(jsonb_build_object(
    'reward_id', rung.reward_id,
    'name', rung.customer_name,
    'slot', rung.cost_points,
    'is_final', rung.cost_points >= coalesce(v_progress.slots, 0)
                and coalesce(v_progress.slots, 0) > 0,
    'claimed_this_cycle', rung.claimed,
    'description', rung.description,
    'image_ref', rung.image_ref,
    'terms', rung.terms,
    'instructions', rung.instructions,
    'availability', case
      when not v_progress.programme_active then 'paused'
      when rung.claim_available_from is not null and now() < rung.claim_available_from
        then 'not_started'
      when rung.claim_available_until is not null and now() >= rung.claim_available_until
        then 'ended'
      when rung.gate_threshold is not null and v_metric < rung.gate_threshold then 'tier_locked'
      when rung.claimed then 'claimed_this_cycle'
      when rung.usage_limit is not null and rung.used_count >= rung.usage_limit
        then 'limit_reached'
      when v_progress.filled < rung.cost_points then 'insufficient_stamps'
      else 'available_at_counter'
    end,
    'stamps_to_go', greatest(rung.cost_points - v_progress.filled, 0)
  ) order by rung.cost_points, rung.customer_name), '[]'::jsonb)
  into v_milestones
  from (
    select rv.reward_id, rv.customer_name, rv.cost_points, rv.description, rv.image_ref,
           rv.terms, rv.instructions, rv.claim_available_from, rv.claim_available_until,
           rv.usage_limit,
           app.v176_reward_gate_threshold(v_context.business_id, rv.min_tier_id,
             rv.min_tier_threshold) as gate_threshold,
           (select count(*)::integer from public.loyalty_redemptions lr
             where lr.business_id = v_context.business_id
               and lr.client_id = v_context.client_id
               and lr.reward_id = rv.reward_id) as used_count,
           exists (select 1 from public.stamp_milestone_claims claim
                    where claim.business_id = v_context.business_id
                      and claim.client_id = v_context.client_id
                      and claim.programme_id = v_progress.programme_id
                      and claim.cycle_index = v_progress.cycle_index
                      and claim.reward_id = rv.reward_id) as claimed
      from public.businesses b
      join public.loyalty_reward_versions rv
        /* nestly_v416: the customer's OPEN card, not whatever the firm published last. */
        on rv.business_id = b.id and rv.active
       and rv.config_version_id = app.stamp_cycle_version_v416(
             v_context.business_id, v_context.client_id, v_progress.programme_id)
     where b.id = v_context.business_id
       and rv.programme_id = v_progress.programme_id
  ) rung;

  return jsonb_build_object(
    'enabled', true,
    'contract', 'v323',
    'unit', 'stamps',
    'running', v_progress.programme_active,
    'running_since', v_progress.running_since,
    'paused_since', v_progress.paused_since,
    'slots', v_progress.slots,
    'filled', v_progress.filled,
    'shown_filled', case when coalesce(v_progress.slots, 0) > 0
                         then least(v_progress.filled, v_progress.slots)
                         else v_progress.filled end,
    'carried', case when coalesce(v_progress.slots, 0) > 0
                    then greatest(v_progress.filled - v_progress.slots, 0) else 0 end,
    'cycle_index', v_progress.cycle_index,
    'lifetime', v_progress.net_stamps,
    'ready', v_progress.ready,
    'pot_migrated', v_progress.pot_migrated,
    'milestones', v_milestones,
    'next_milestone', (
      select rung.value from jsonb_array_elements(v_milestones) as rung(value)
       where (rung.value ->> 'claimed_this_cycle')::boolean is not true
       order by (rung.value ->> 'slot')::integer
       limit 1)
  );
end
$function$;

revoke all on function public.customer_get_stamp_card_v323(text) from public, anon;
grant execute on function public.customer_get_stamp_card_v323(text) to authenticated, service_role;

-- ============================================================================================
-- 4. THE COUNTER
-- ============================================================================================
-- Same method: extracted, one statement replaced and one declaration added, diffed to prove it.
-- Nothing about idempotency, the operations lock, eligibility, usage limits, the tier gate, the
-- points path or the cycle close is touched. A points redemption resolves exactly the version it
-- always did.
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
  v_consumes boolean:=true; v_points_spent integer; v_cycle_id uuid; v_config_version uuid;
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
  -- nestly_v416: WHICH published configuration this redemption is judged against. For a stamp
  -- card it is the one the customer's OPEN card was started under, so the counter and the card in
  -- their hand cannot disagree; for points there are no cycles and it stays the active version.
  -- The kind is read off the LIVE reward row because v_version is what we are about to select.
  select spine.kind into v_programme_kind from public.business_programmes spine
   where spine.id = v_reward.programme_id and spine.business_id = p_business;
  v_config_version := case when v_programme_kind = 'stamps'
    then app.stamp_cycle_version_v416(p_business, p_client, v_reward.programme_id)
    else (select b.active_config_version_id from public.businesses b where b.id = p_business) end;
  select rv.* into v_version from public.loyalty_reward_versions rv where rv.reward_id=p_reward and rv.business_id=p_business and rv.config_version_id=v_config_version;
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

revoke all on function app.redeem_reward_core(uuid,uuid,uuid,text,uuid,uuid,uuid) from public, anon, authenticated;

commit;
