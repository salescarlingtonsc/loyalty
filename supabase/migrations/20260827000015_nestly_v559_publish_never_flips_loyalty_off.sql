-- nestly_v559 -- publishing a draft may never switch the live loyalty programme off.
--
-- THE DEFECT (found 2026-08-27, owner: "why does every new firm keep having issues while my
-- test tenants work? I already fixed it once, but still the same issue").
--
--   public.publish_loyalty_config copied `active` from the draft's typed row:
--       update public.loyalty_programs set ... active=v_typed.active ...
--   and the draft creators (create_loyalty_config_draft / create_grow_config_draft_v138) clone
--   the typed row -- `active` included -- from the BASE VERSION. So a tenant whose published
--   loyalty_program_versions row says active=false re-applies that false to the LIVE
--   public.loyalty_programs row on EVERY subsequent publish, whatever the publish was about.
--
--   KKY demo (8ccace3a) is the recorded case: the nestly_v514 backfill set the live row
--   active=true on 2026-08-25 20:38 (audit: loyalty_active.synced_to_spine), and the owner's
--   birthday-gift publish on 2026-08-27 08:43 (a draft cloned from a version carrying
--   active=false, program_rule_count 0) silently put it back to false. The spine
--   (business_programmes points) stayed active the whole time, and the earn engine follows the
--   spine -- so the customer EARNED 25 points (points_ledger 08:59:33) that the hero card,
--   the reward catalog and the redemption QR all refused to show, because those readers gate on
--   loyalty_programs.active:
--       app.c45_base_actionable_wallet_card   (hero card -- forced balance to 0)
--       app.customer_redemption_reachable_v521 (the redeem QR)
--       public.customer_get_reward_catalog     (the gifts list)
--       app.run_points_expiry / _for_business  (the nightly sweep skips the firm)
--       public.customer_explore_businesses_v244 / customer_list_business_directory_v242
--   This is why the owner's long-standing tenants (Cubbly SPA: version rows say active=true)
--   never show the problem while new firms (KKY demo, HENG HENG 888 -- version rows seeded
--   active=false by the onboarding preset / published-paused wizard runs) break again after
--   every "fix": the fixes patched the live row, the version rows kept the lie, and the next
--   publish re-applied it.
--
-- THE FIX. Owner ruling R6 (v322): publishing CONFIGURES, the switchboard SWITCHES. So publish
-- now writes `active` from the spine -- the same (points or stamps running) expression the
-- v514 sync inside set_programmes_v314 writes -- and the draft's own flag is recorded in
-- audit_log (loyalty_active.draft_flag_ignored) whenever it disagreed, instead of being obeyed.
-- The wizard path is unaffected: it applies its switches through set_programmes_v314 AFTER
-- publishing, which was always the half that actually moved the spine.
--
-- The backfill then re-syncs every currently-diverged tenant (KKY demo and HENG HENG 888 at the
-- time of writing) -- and this time the fix holds, because the door it came through is closed.
--
-- Deliberately NOT changed: loyalty_program_versions rows (immutable records of what a draft
-- said); the draft creators (their clone of `active` is now inert at publish time); and the
-- seven lp.active readers above, which become correct the moment the column is kept in sync.
--
-- ROLLBACK: db/tests/v559_publish_never_flips_loyalty_off.sql

begin;

-- Precondition: the function still has the exact shape this patch was cut from. If someone has
-- already changed the copy, this migration must be re-derived, not applied blind.
do $pre$
begin
  if position('active=v_typed.active' in pg_get_functiondef('public.publish_loyalty_config(uuid)'::regprocedure)) = 0 then
    raise exception 'v559: publish_loyalty_config no longer copies active=v_typed.active -- re-derive this patch from the live definition';
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
begin
  perform app.acquire_loyalty_exclusive_v480((select business_id from public.firm_config_versions where id = p_version));
  select * into v_header from public.firm_config_versions where id=p_version for update;
  if not found or not app.c45_owner_loyalty_write(v_header.business_id) then raise exception 'owner loyalty configuration access required' using errcode='42501'; end if;
  if v_header.status<>'draft' then raise exception 'only a draft may be published'; end if;
  perform 1 from public.businesses where id=v_header.business_id for update;
  select * into v_typed from public.loyalty_program_versions where config_version_id=p_version;
  if v_typed.loyalty_model = 'stamps' and coalesce(v_typed.stamp_per_cents,0)<=0 then raise exception 'active stamps configuration requires spend per stamp' using errcode='23514'; end if;
  if v_typed.loyalty_model = 'stamps' then
    if coalesce(v_typed.stamp_target,0)<=0 then
      raise exception 'a live stamp card needs a number of stamps' using errcode='23514';
    end if;
    if exists(select 1 from public.loyalty_reward_versions rv join public.business_programmes spine on spine.id=rv.programme_id
               where rv.config_version_id=p_version and rv.business_id=v_header.business_id and rv.active and spine.kind='stamps' and rv.cost_points>v_typed.stamp_target) then
      raise exception 'a stamp gift sits past the last stamp on the card' using errcode='23514';
    end if;
    if not exists(select 1 from public.loyalty_reward_versions rv join public.business_programmes spine on spine.id=rv.programme_id
                   where rv.config_version_id=p_version and rv.business_id=v_header.business_id and rv.active and spine.kind='stamps' and rv.cost_points=v_typed.stamp_target) then
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
  select coalesce(bool_or(spine.active) filter (where spine.kind='stamps'),false),
         coalesce(bool_or(spine.active) filter (where spine.kind='points'),false)
    into v_spine_stamps, v_spine_points
    from public.business_programmes spine
   where spine.business_id=v_header.business_id;
  if v_typed.active is distinct from (v_spine_points or v_spine_stamps) then
    insert into public.audit_log(business_id,actor,action,entity,entity_id,detail)
    values (v_header.business_id, auth.uid(), 'loyalty_active.draft_flag_ignored', 'loyalty_programs', v_header.business_id,
            jsonb_build_object('source','publish_loyalty_config','draft_active',v_typed.active,
                               'spine_active',(v_spine_points or v_spine_stamps),'config_version_id',p_version));
  end if;
  update public.loyalty_programs set kind=v_typed.kind,loyalty_model=v_typed.loyalty_model,active=(v_spine_points or v_spine_stamps),earn_points_per_dollar=v_typed.earn_points_per_dollar,redeem_points=v_typed.redeem_points,reward_credit_cents=v_typed.reward_credit_cents,stamp_target=v_typed.stamp_target,stamp_per_cents=v_typed.stamp_per_cents,stamp_validity_days=v_typed.stamp_validity_days,stamp_reward_expiry_days=v_typed.stamp_reward_expiry_days,tier_basis=v_typed.tier_basis,expiry_mode=v_typed.expiry_mode,expiry_days=v_typed.expiry_days,configuration_status='published',current_config_version_id=p_version where business_id=v_header.business_id;
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

-- CREATE OR REPLACE preserves grants; restated per governance so the intent is explicit.
-- Live proacl before this migration: {postgres=X/postgres,service_role=X/postgres,authenticated=X/postgres}
revoke all on function public.publish_loyalty_config(uuid) from public, anon;
grant execute on function public.publish_loyalty_config(uuid) to authenticated, service_role;

-- ============ BACKFILL: re-sync every tenant the old publish path has already diverged =========
-- The same expression the function now writes. Audited per business under the same action name
-- the v514 sync uses, so the trail reads as one story.
do $backfill$
declare r record; v_truth boolean;
begin
  for r in
    select lp.business_id, lp.active as lp_active,
           exists(select 1 from public.business_programmes bp
                   where bp.business_id = lp.business_id and bp.active
                     and bp.kind in ('points','stamps')) as spine_running
      from public.loyalty_programs lp
  loop
    v_truth := r.spine_running;
    if r.lp_active is distinct from v_truth then
      update public.loyalty_programs
         set active = v_truth
       where business_id = r.business_id;
      insert into public.audit_log(business_id, actor, action, entity, entity_id, detail)
      values (r.business_id, null, 'loyalty_active.synced_to_spine', 'loyalty_programs', r.business_id,
              jsonb_build_object('active', v_truth, 'source', 'nestly_v559_backfill',
                                 'was', r.lp_active));
    end if;
  end loop;
end
$backfill$;

commit;
