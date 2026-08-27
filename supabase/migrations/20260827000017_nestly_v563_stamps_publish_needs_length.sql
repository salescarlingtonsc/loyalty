-- nestly_v563 -- a stamps tenant can never publish without a card length, and KKY's card gets one.
--
-- THE DEFECT (owner, three screenshots 2026-08-27 18:07-18:38): the business editor showed a
-- 15-slot card, the customer hero said "0 of 5 stamps", a customer with EIGHTEEN collected
-- stamps was told their Free upsize was "ready -- show this at the counter" yet held no
-- claimable reward, and the hero called that same gift "Not on the current card".
--
-- ONE ROOT: loyalty_programs.stamp_target was NULL on a LIVE stamps tenant. The publish guards
-- that exist to forbid exactly that ("a live stamp card needs a number of stamps" / "...a gift
-- at the last stamp") were keyed on the DRAFT'S loyalty_model -- a stale 'classic' clone, the
-- same stale-snapshot class nestly_v559 closed for `active` -- so they never fired. Every
-- surface then invented its own answer for the missing number: the editor drew its never-set
-- 15-slot canvas, the customer surfaces fell back to the next gift's slot (5), and
-- app.stamp_progress_v323's ready flag (stamp_target IS NOT NULL and filled >= stamp_target)
-- was unsatisfiable, so no reward could ever be minted however many stamps were collected.
--
-- THE FIX: the stamps validations now fire whenever the tenant WILL LIVE as stamps (draft model
-- OR spine), and they judge the EFFECTIVE config -- the draft's value where it carries one, the
-- live row's where the stale clone never held stamp fields. The live-row copy inherits the
-- stamp numbers the same way (coalesce), so a clone can no longer erase them. The backfill sets
-- the one broken tenant's card length to its own highest live gift slot (KKY demo: 5 -- the only
-- length that satisfies the gift-at-last-stamp invariant without inventing gifts).
--
-- ROLLBACK: db/tests/v563_stamps_publish_needs_length.sql

begin;

do $pre$
begin
  if position('v_eff_target' in pg_get_functiondef('public.publish_loyalty_config(uuid)'::regprocedure)) > 0 then
    raise exception 'v563: publish_loyalty_config already carries the spine-keyed stamp guards';
  end if;
  if position('active=(v_spine_points or v_spine_stamps)' in pg_get_functiondef('public.publish_loyalty_config(uuid)'::regprocedure)) = 0 then
    raise exception 'v563: expected the v559 shape to patch -- re-derive from the live definition';
  end if;
end
$pre$;

CREATE OR REPLACE FUNCTION public.publish_loyalty_config(p_version uuid)
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'app', 'pg_temp'
AS $function$
declare v_header public.firm_config_versions%rowtype; v_typed public.loyalty_program_versions%rowtype; v_prior uuid;
  v_rule public.program_rules%rowtype; v_rule_errs text[]; v_active_rule_count integer;
  v_tier_carry_ids uuid[]; v_tier_carry_paused boolean[]; v_tier_carry_deleted timestamptz[];
  v_spine_stamps boolean; v_spine_points boolean; -- nestly_v431
  v_eff_target integer; v_eff_per_cents integer; -- nestly_v563
begin
  perform app.acquire_loyalty_exclusive_v480((select business_id from public.firm_config_versions where id = p_version));
  select * into v_header from public.firm_config_versions where id=p_version for update;
  if not found or not app.c45_owner_loyalty_write(v_header.business_id) then raise exception 'owner loyalty configuration access required' using errcode='42501'; end if;
  if v_header.status<>'draft' then raise exception 'only a draft may be published'; end if;
  perform 1 from public.businesses where id=v_header.business_id for update;
  select * into v_typed from public.loyalty_program_versions where config_version_id=p_version;
  -- nestly_v563: the spine is read HERE now (v559 read it just before the live-row write), because
  -- the stamps validations below must know it too. The later block reuses these variables.
  select coalesce(bool_or(spine.active) filter (where spine.kind='stamps'),false),
         coalesce(bool_or(spine.active) filter (where spine.kind='points'),false)
    into v_spine_stamps, v_spine_points
    from public.business_programmes spine
   where spine.business_id=v_header.business_id;
  -- nestly_v563 (KKY demo, 2026-08-27). These validations were keyed on v_typed.loyalty_model —
  -- the DRAFT'S clone of a stale flag (the same class of stale snapshot nestly_v559 documented).
  -- KKY's draft said 'classic' while the spine ran stamps, so every stamps check was silently
  -- skipped and the tenant published with stamp_target NULL. The fallout was three different
  -- answers to one question: the editor drew its 15-slot never-set canvas, the customer hero
  -- showed progress toward the next GIFT (5), and stamp_progress_v323's ready flag — literally
  -- `stamp_target is not null and filled >= stamp_target` — could never be true, so a customer
  -- with 18 collected stamps was told "ready — show this at the counter" by one reader while the
  -- claimable reward the words promised was never minted, and the hero called the gift "Not on
  -- the current card" (slot 5 past a NULL-length card). One missing number, four surfaces.
  -- The checks now fire whenever the tenant WILL LIVE as stamps (draft model OR spine), and they
  -- judge the EFFECTIVE config: the draft's value where it carries one, the live row's where the
  -- draft is a stale clone that never held stamp fields — a clone must inherit, never erase
  -- (v559's rule, extended from `active` to the stamp numbers).
  v_eff_target := coalesce(v_typed.stamp_target,
    (select prog.stamp_target from public.loyalty_programs prog where prog.business_id=v_header.business_id));
  v_eff_per_cents := coalesce(v_typed.stamp_per_cents,
    (select prog.stamp_per_cents from public.loyalty_programs prog where prog.business_id=v_header.business_id));
  if (v_typed.loyalty_model = 'stamps' or v_spine_stamps) and coalesce(v_eff_per_cents,0)<=0 then raise exception 'active stamps configuration requires spend per stamp' using errcode='23514'; end if;
  if v_typed.loyalty_model = 'stamps' or v_spine_stamps then
    if coalesce(v_eff_target,0)<=0 then
      raise exception 'a live stamp card needs a number of stamps' using errcode='23514';
    end if;
    if exists(select 1 from public.loyalty_reward_versions rv join public.business_programmes spine on spine.id=rv.programme_id
               where rv.config_version_id=p_version and rv.business_id=v_header.business_id and rv.active and spine.kind='stamps' and rv.cost_points>v_eff_target) then
      raise exception 'a stamp gift sits past the last stamp on the card' using errcode='23514';
    end if;
    if not exists(select 1 from public.loyalty_reward_versions rv join public.business_programmes spine on spine.id=rv.programme_id
                   where rv.config_version_id=p_version and rv.business_id=v_header.business_id and rv.active and spine.kind='stamps' and rv.cost_points=v_eff_target) then
      raise exception 'a live stamp card needs a gift at the last stamp' using errcode='23514';
    end if;
  end if;
  if exists(select 1 from public.retention_program_versions rv left join public.firm_reward_taxonomy t on t.id=rv.reward_taxonomy_id and t.business_id=rv.business_id where rv.config_version_id=p_version and rv.business_id=v_header.business_id and rv.active and coalesce(t.active,false)=false) then
    raise exception 'active retention programs cannot publish a retired taxonomy' using errcode='23514';
  end if;
  if exists(select 1 from public.birthday_program_versions bp where bp.config_version_id=p_version and bp.business_id=v_header.business_id and bp.active and bp.window_days_before+bp.window_days_after+1>365) then
    raise exception 'birthday benefit windows may not overlap annually' using errcode='23514';
  end if;
  for v_rule in select * from public.program_rules where config_version_id=p_version and business_id=v_header.business_id loop
    v_rule_errs := app.program_rule_errors(v_header.business_id, jsonb_build_object(
      'schema_version',v_rule.schema_version,'when_event',v_rule.when_event,'if_conditions',v_rule.if_conditions,
      'then_effects',v_rule.then_effects,'with_params',v_rule.with_params,'during_schedule',v_rule.during_schedule,'using_stacking',v_rule.using_stacking));
    if coalesce(array_length(v_rule_errs,1),0)>0 then
      raise exception 'cannot publish: program rule % is invalid (%)', v_rule.name, array_to_string(v_rule_errs,', ') using errcode='23514';
    end if;
  end loop;
  select count(*) into v_active_rule_count from public.program_rules where config_version_id=p_version and business_id=v_header.business_id and active;
  if v_active_rule_count>200 then
    raise exception 'cannot publish: too many active program rules (%)', v_active_rule_count using errcode='23514';
  end if;
  perform app.refresh_loyalty_config_snapshot(p_version);
  select * into v_header from public.firm_config_versions where id=p_version;
  select active_config_version_id into v_prior from public.businesses where id=v_header.business_id;
  update public.firm_config_versions set status='superseded',superseded_at=now() where id=v_prior and status='published';
  update public.firm_config_versions set status='published',published_at=now() where id=p_version;
  update public.businesses set active_config_version_id=p_version where id=v_header.business_id;
  -- nestly_v559: the spine is read FIRST, because `active` below is ITS answer now, not the
  -- draft's. v_typed.active is a snapshot of whatever the base version happened to carry when
  -- the draft was cloned; publishing a birthday gift from a draft whose base version said
  -- active=false was switching the whole live points programme off for every customer while the
  -- spine (and the earn engine, which follows the spine) kept running -- points the customer
  -- could neither see nor redeem. Publishing configures; the switchboard switches (owner ruling
  -- R6, and the same expression set_programmes_v314's v514 sync writes).
  if v_typed.active is distinct from (v_spine_points or v_spine_stamps) then
    insert into public.audit_log(business_id,actor,action,entity,entity_id,detail)
    values (v_header.business_id, auth.uid(), 'loyalty_active.draft_flag_ignored', 'loyalty_programs', v_header.business_id,
            jsonb_build_object('source','publish_loyalty_config','draft_active',v_typed.active,
                               'spine_active',(v_spine_points or v_spine_stamps),'config_version_id',p_version));
  end if;
  update public.loyalty_programs set kind=v_typed.kind,loyalty_model=v_typed.loyalty_model,active=(v_spine_points or v_spine_stamps),earn_points_per_dollar=v_typed.earn_points_per_dollar,redeem_points=v_typed.redeem_points,reward_credit_cents=v_typed.reward_credit_cents,stamp_target=coalesce(v_typed.stamp_target,loyalty_programs.stamp_target),stamp_per_cents=coalesce(v_typed.stamp_per_cents,loyalty_programs.stamp_per_cents),stamp_validity_days=v_typed.stamp_validity_days,stamp_reward_expiry_days=v_typed.stamp_reward_expiry_days,tier_basis=v_typed.tier_basis,expiry_mode=v_typed.expiry_mode,expiry_days=v_typed.expiry_days,configuration_status='published',current_config_version_id=p_version where business_id=v_header.business_id;
  if v_spine_stamps then
    update public.loyalty_programs
       set loyalty_model='stamps', kind='stamps'
     where business_id=v_header.business_id
       and (loyalty_model is distinct from 'stamps' or kind is distinct from 'stamps');
  elsif v_spine_points then
    update public.loyalty_programs
       set loyalty_model=case when loyalty_model in ('classic','points_tiers') then loyalty_model else 'classic' end,
           kind='points'
     where business_id=v_header.business_id
       and (kind is distinct from 'points' or loyalty_model not in ('classic','points_tiers'));
  end if;
  if found and (v_spine_stamps or v_spine_points) then
    insert into public.audit_log(business_id,actor,action,entity,entity_id,detail)
    values (v_header.business_id, auth.uid(), 'loyalty_model.synced_to_spine', 'loyalty_programs', v_header.business_id,
            jsonb_build_object('source','publish_loyalty_config','spine_stamps',v_spine_stamps,'spine_points',v_spine_points,'config_version_id',p_version));
  end if;
  update public.loyalty_rewards r set programme_id=rv.programme_id,name=rv.customer_name,internal_name=rv.internal_name,customer_name=rv.customer_name,description=rv.description,fulfillment_kind=rv.fulfillment_kind,taxonomy_label=rv.taxonomy_label,cost_points=rv.cost_points,credit_cents=rv.credit_cents,estimated_cost_cents=rv.estimated_cost_cents,active=rv.active,sort=rv.sort,claim_available_from=rv.claim_available_from,claim_available_until=rv.claim_available_until,entitlement_expiry_days=rv.entitlement_expiry_days,instructions=rv.instructions,terms=rv.terms,image_ref=rv.image_ref,usage_limit=rv.usage_limit,min_tier_id=rv.min_tier_id,min_tier_threshold=rv.min_tier_threshold,current_config_version_id=p_version from public.loyalty_reward_versions rv where rv.reward_id=r.id and rv.business_id=r.business_id and rv.config_version_id=p_version;
  select array_agg(id), array_agg(paused), array_agg(deleted_at)
    into v_tier_carry_ids, v_tier_carry_paused, v_tier_carry_deleted
    from public.loyalty_tiers
   where business_id=v_header.business_id and (paused or deleted_at is not null);
  delete from public.loyalty_tiers where business_id=v_header.business_id;
  insert into public.loyalty_tiers(id,business_id,name,threshold,points_multiplier,perk_note,sort,effective_from,expires_at) select tier_id,business_id,name,threshold,points_multiplier,perk_note,sort,effective_from,expires_at from public.loyalty_tier_versions where config_version_id=p_version and business_id=v_header.business_id and active;
  if v_tier_carry_ids is not null then
    update public.loyalty_tiers t set paused=c.paused,deleted_at=c.deleted_at
      from (select unnest(v_tier_carry_ids) as id, unnest(v_tier_carry_paused) as paused, unnest(v_tier_carry_deleted) as deleted_at) c
     where c.id=t.id and t.business_id=v_header.business_id;
  end if;
  update public.retention_programs rp set name=rv.name,active=(rv.active and rp.deleted_at is null),goal_visits=rv.goal_visits,period_days=rv.period_days,starts_on=rv.starts_on,reward_taxonomy_id=rv.reward_taxonomy_id,reward_type=rv.fulfillment_kind,reward_value=coalesce(rv.discount_percent,rv.credit_cents,0),reward_item=rv.manual_item,current_config_version_id=p_version from public.retention_program_versions rv where rv.program_id=rp.id and rv.business_id=rp.business_id and rv.config_version_id=p_version and rp.business_id=v_header.business_id;
  perform app.compile_program_rules(p_version);
  insert into public.audit_log(business_id,actor,action,entity,entity_id,detail)
  values(v_header.business_id,auth.uid(),'PUBLISH_CONFIG','firm_config_versions',p_version,jsonb_build_object('prior_version_id',v_prior,'new_version_id',p_version,'snapshot_hash',v_header.snapshot_hash,'birthday_program_count',(select count(*) from public.birthday_program_versions where config_version_id=p_version),'program_rule_count',(select count(*) from public.program_rules where config_version_id=p_version)));
  return json_build_object('version_id',p_version,'version_no',v_header.version_no,'status','published');
end $function$;

-- CREATE OR REPLACE preserves grants; restated per governance (same ACL as v559 restated).
revoke all on function public.publish_loyalty_config(uuid) from public, anon;
grant execute on function public.publish_loyalty_config(uuid) to authenticated, service_role;

-- ============ BACKFILL: the live stamps tenant whose card has no length =======================
-- target := the tenant's own highest ACTIVE stamp gift slot on the LIVE version -- the only
-- number that satisfies "a gift at the last stamp" without inventing gifts. A stamps tenant
-- with no gift at all is left untouched: there is no honest length to give it, and the new
-- guard will name what is missing at its next publish.
do $backfill$
declare r record; v_len integer;
begin
  for r in
    select b.id as business_id
      from public.businesses b
      join public.business_programmes spine
        on spine.business_id=b.id and spine.kind='stamps' and spine.active
      join public.loyalty_programs lp on lp.business_id=b.id
     where coalesce(lp.stamp_target,0)<=0
  loop
    select max(rv.cost_points)::integer into v_len
      from public.loyalty_reward_versions rv
      join public.business_programmes sp on sp.id=rv.programme_id and sp.kind='stamps'
      join public.businesses b on b.id=rv.business_id
     where rv.business_id=r.business_id
       and rv.config_version_id=b.active_config_version_id and rv.active;
    if coalesce(v_len,0) > 0 then
      update public.loyalty_programs set stamp_target=v_len where business_id=r.business_id;
      insert into public.audit_log(business_id, actor, action, entity, entity_id, detail)
      values (r.business_id, null, 'stamp_target.backfilled_from_gifts_v563', 'loyalty_programs',
              r.business_id, jsonb_build_object('stamp_target', v_len,
                'source','nestly_v563_backfill',
                'reason','live stamps tenant published with no card length; the spine-keyed guard now forbids the state'));
    end if;
  end loop;
end
$backfill$;

commit;
