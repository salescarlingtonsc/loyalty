-- nestly_v564 -- a draft can neither time-machine nor erase.
--
-- THE DEFECT. A configuration draft is a full CLONE of a version, and publishing it overwrites
-- the live rows wholesale from the draft's own version rows -- loyalty settings UPDATEd, tiers
-- DELETEd and re-INSERTed, rewards and retention rows UPDATEd. Two consequences had no guard:
--
--   (1) TIME MACHINE. A draft records the version it was cloned from. Nothing checked that the
--       business was still ON that version at publish time. Open the editor, publish something
--       else from another surface (the birthday editor, the wizard, a rule toggle -- five RPCs
--       publish on their own), then save the first draft, and every change made in between is
--       silently reverted. Prod holds 13 open drafts and ALL THIRTEEN are behind their business's
--       live pointer; one of them would set earn_points_per_dollar from 1 to 100 on publish.
--
--   (2) ERASURE. loyalty_program_versions has 13 typed columns. app.seed_loyalty_config_version
--       named 11 of them and create_grow_config_draft_v138 named 11 -- stamp_validity_days and
--       stamp_reward_expiry_days were simply absent -- so those drafts were born with NULLs in
--       columns the live row had real values in, and publish copied the NULLs straight over. A
--       card's stamp validity and a stamp gift's expiry were erased by a draft that never
--       mentioned them. This is the same shape nestly_v563 closed for stamp_target and
--       stamp_per_cents, in the two columns v563 did not reach.
--
-- Two smaller members of the same family travel with them: app.stamp_config_edit_commit_v433
-- still keyed the editor's copy of the publish guards on the DRAFT'S loyalty_model (v563 re-keyed
-- publish_loyalty_config's, so the two now disagreed and a stale clone would raise mid-save
-- instead of pending with guidance), and app.resolve_loyalty_branch_config still answered
-- `active` from the version row's snapshot flag rather than the business_programmes spine --
-- the authority nestly_v559 established.
--
-- THE FIX, in five parts:
--   1. publish_loyalty_config refuses a STALE draft (23514 'stale_draft: ...'), with carve-outs
--      for a business that has never published and for a draft that IS the live pointer.
--   2. publish_loyalty_config coalesces stamp_validity_days and stamp_reward_expiry_days against
--      the live row (v563's pattern), and refuses an effective expiry_mode='fixed' with no days.
--   3. Both draft creators name all 13 typed columns and seed them from the LIVE programme row,
--      falling back to the base version only where the live row holds no value; the seed trigger
--      names all 13 from NEW.
--   4. stamp_config_edit_commit_v433 takes v563's spine-keyed, effective-value gate.
--   5. resolve_loyalty_branch_config derives `active` from the spine.
--
-- No caller reads `active` off resolve_loyalty_branch_config today (app.on_sale_recorded iterates
-- business_programmes directly), so part 5 changes no live behaviour -- it removes a wrong answer
-- before something reads it.
--
-- ROLLBACK: db/tests/v564_draft_cannot_time_machine.sql

begin;

-- ============ PRECONDITIONS: the exact pre-shape this migration patches ======================
do $pre$
declare v_def text;
begin
  v_def := pg_get_functiondef('public.publish_loyalty_config(uuid)'::regprocedure);
  if position('v_eff_target' in v_def) = 0 then
    raise exception 'v564: expected the nestly_v563 shape of publish_loyalty_config -- re-derive from the live definition';
  end if;
  if position('stale_draft' in v_def) > 0 then
    raise exception 'v564: publish_loyalty_config already refuses stale drafts';
  end if;
  if position('stamp_validity_days=v_typed.stamp_validity_days' in v_def) = 0 then
    raise exception 'v564: expected publish_loyalty_config to copy stamp_validity_days raw -- re-derive';
  end if;

  v_def := pg_get_functiondef('public.create_loyalty_config_draft(uuid,uuid,text)'::regprocedure);
  if position('from public.loyalty_program_versions where config_version_id=v_base;' in v_def) = 0 then
    raise exception 'v564: expected create_loyalty_config_draft to clone from the base version -- re-derive';
  end if;

  v_def := pg_get_functiondef('public.create_grow_config_draft_v138(uuid,uuid,text)'::regprocedure);
  if position('stamp_validity_days' in v_def) > 0 then
    raise exception 'v564: create_grow_config_draft_v138 already names all 13 typed columns';
  end if;

  v_def := pg_get_functiondef('app.seed_loyalty_config_version()'::regprocedure);
  if position('stamp_validity_days' in v_def) > 0 then
    raise exception 'v564: app.seed_loyalty_config_version already names all 13 typed columns';
  end if;

  v_def := pg_get_functiondef('app.stamp_config_edit_commit_v433(uuid,uuid)'::regprocedure);
  if position('if v_typed.loyalty_model = ''stamps'' then' in v_def) = 0 then
    raise exception 'v564: expected the draft-model-keyed gate in stamp_config_edit_commit_v433 -- re-derive';
  end if;

  v_def := pg_get_functiondef('app.resolve_loyalty_branch_config(uuid,uuid,uuid)'::regprocedure);
  if position('coalesce(o.active, d.active)' in v_def) = 0 then
    raise exception 'v564: expected resolve_loyalty_branch_config to answer active from the version row -- re-derive';
  end if;
end
$pre$;

-- ============ 1 + 2: publish refuses a stale draft, and stops erasing =======================
CREATE OR REPLACE FUNCTION public.publish_loyalty_config(p_version uuid)
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'app', 'pg_temp'
AS $function$
declare v_header public.firm_config_versions%rowtype; v_typed public.loyalty_program_versions%rowtype; v_prior uuid;
  v_rule public.program_rules%rowtype; v_rule_errs text[]; v_active_rule_count integer;
  v_tier_carry_ids uuid[]; v_tier_carry_paused boolean[]; v_tier_carry_deleted timestamptz[];
  v_spine_stamps boolean; v_spine_points boolean; v_spine_tiers boolean; -- nestly_v431, tiers nestly_v565
  v_eff_target integer; v_eff_per_cents integer; -- nestly_v563
  v_biz_active uuid; v_eff_expiry_mode text; v_eff_expiry_days integer; -- nestly_v564
begin
  perform app.acquire_loyalty_exclusive_v480((select business_id from public.firm_config_versions where id = p_version));
  select * into v_header from public.firm_config_versions where id=p_version for update;
  if not found or not app.c45_owner_loyalty_write(v_header.business_id) then raise exception 'owner loyalty configuration access required' using errcode='42501'; end if;
  if v_header.status<>'draft' then raise exception 'only a draft may be published'; end if;
  perform 1 from public.businesses where id=v_header.business_id for update;
  -- nestly_v564: a draft may not TIME-MACHINE. Every draft records the version it was cloned
  -- from (based_on_version_id); publishing overwrites the live rows wholesale from the draft's
  -- own version rows. So a draft cloned from version N, left open while someone published
  -- N+1..N+k, does not merge -- it silently reverts every change made since it was opened
  -- (tiers are DELETEd and re-INSERTed from the draft's tier versions; loyalty settings, rewards
  -- and retention rows are overwritten from the draft's). Prod carried 13 such open drafts, one
  -- of which would have multiplied a tenant's earn rate 1 -> 100 on publish.
  -- The predicate refuses only what is genuinely behind:
  --   * a business that has NEVER published (active pointer NULL) must still publish its first
  --     version, so a NULL pointer is never stale;
  --   * a draft that IS the active pointer is the current state by definition (the pre-v507
  --     seeded version-1 shape, born 'draft' and claiming the pointer) and cannot be behind
  --     itself;
  --   * a NULL based_on with a non-NULL pointer that is not this row IS stale -- the only NULL
  --     based_on writer is app.seed_loyalty_config_version, which writes a business's FIRST
  --     version and claims the pointer only while it is NULL; if the pointer has since moved to
  --     another version, that seed row is a leftover from before this business went live.
  -- Every normal creator already bases on the live pointer: create_loyalty_config_draft and
  -- create_grow_config_draft_v138 both resolve v_base := coalesce(p_based_on,
  -- app.active_config_version(...) , loyalty_programs.current_config_version_id), and every
  -- caller in app-business.js passes the current version (owner_editor, owner_reward_editor,
  -- owner_tier_editor, owner_retention_editor, owner_birthday_editor, owner_setup_wizard_v301,
  -- grow_*_edit) or NULL. The wizard clears state.basedOn after each publish, so its next draft
  -- re-resolves against the new pointer.
  select b.active_config_version_id into v_biz_active from public.businesses b where b.id=v_header.business_id;
  if v_biz_active is not null
     and v_biz_active is distinct from p_version
     and v_header.based_on_version_id is distinct from v_biz_active then
    raise exception 'stale_draft: this draft was based on an older version of your setup — open the editor again and re-apply the change' using errcode='23514';
  end if;
  select * into v_typed from public.loyalty_program_versions where config_version_id=p_version;
  -- nestly_v563: the spine is read HERE now (v559 read it just before the live-row write), because
  -- the stamps validations below must know it too. The later block reuses these variables.
  select coalesce(bool_or(spine.active) filter (where spine.kind='stamps'),false),
         coalesce(bool_or(spine.active) filter (where spine.kind='points'),false),
         coalesce(bool_or(spine.active) filter (where spine.kind='tiers'),false)
    into v_spine_stamps, v_spine_points, v_spine_tiers
    from public.business_programmes spine
   where spine.business_id=v_header.business_id;
  -- nestly_v563 (KKY demo, 2026-08-27). These validations were keyed on v_typed.loyalty_model --
  -- the DRAFT'S clone of a stale flag (the same class of stale snapshot nestly_v559 documented).
  -- KKY's draft said 'classic' while the spine ran stamps, so every stamps check was silently
  -- skipped and the tenant published with stamp_target NULL. The fallout was three different
  -- answers to one question: the editor drew its 15-slot never-set canvas, the customer hero
  -- showed progress toward the next GIFT (5), and stamp_progress_v323's ready flag -- literally
  -- `stamp_target is not null and filled >= stamp_target` -- could never be true, so a customer
  -- with 18 collected stamps was told "ready -- show this at the counter" by one reader while the
  -- claimable reward the words promised was never minted, and the hero called the gift "Not on
  -- the current card" (slot 5 past a NULL-length card). One missing number, four surfaces.
  -- The checks now fire whenever the tenant WILL LIVE as stamps (draft model OR spine), and they
  -- judge the EFFECTIVE config: the draft's value where it carries one, the live row's where the
  -- draft is a stale clone that never held stamp fields -- a clone must inherit, never erase
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
  -- nestly_v564: the same effective-config rule v563 gave the stamp numbers, applied to points
  -- expiry. 'fixed' with no number of days is not a configuration -- app.on_sale_recorded builds
  -- the expiry as `now()+make_interval(days=>lp.expiry_days)`, which is NULL for a NULL day
  -- count, so every point earned under it would be minted with no expiry at all while the
  -- Loyalty page said points expire. loyalty_program_versions.expiry_mode is NOT NULL, so the
  -- coalesce below can only fall through when there is no typed row at all -- a state the live
  -- row UPDATE further down already rejects on loyalty_programs.kind's NOT NULL -- and the
  -- effective mode is therefore the draft's own in every reachable case.
  v_eff_expiry_mode := coalesce(v_typed.expiry_mode,
    (select prog.expiry_mode from public.loyalty_programs prog where prog.business_id=v_header.business_id));
  v_eff_expiry_days := coalesce(v_typed.expiry_days,
    (select prog.expiry_days from public.loyalty_programs prog where prog.business_id=v_header.business_id));
  if v_eff_expiry_mode = 'fixed' and coalesce(v_eff_expiry_days,0) <= 0 then
    raise exception 'points expiry is set to fixed but has no number of days' using errcode='23514';
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
  -- nestly_v559: the spine is the authority on `active`; a disagreeing draft flag is recorded,
  -- not obeyed. (Spine variables were read above, before the validations.)
  if v_typed.active is distinct from (v_spine_points or v_spine_stamps or v_spine_tiers) then
    insert into public.audit_log(business_id,actor,action,entity,entity_id,detail)
    values (v_header.business_id, auth.uid(), 'loyalty_active.draft_flag_ignored', 'loyalty_programs', v_header.business_id,
            jsonb_build_object('source','publish_loyalty_config','draft_active',v_typed.active,
                               'spine_active',(v_spine_points or v_spine_stamps or v_spine_tiers),'config_version_id',p_version));
  end if;
  update public.loyalty_programs set kind=v_typed.kind,loyalty_model=v_typed.loyalty_model,active=(v_spine_points or v_spine_stamps or v_spine_tiers),earn_points_per_dollar=v_typed.earn_points_per_dollar,redeem_points=v_typed.redeem_points,reward_credit_cents=v_typed.reward_credit_cents,stamp_target=coalesce(v_typed.stamp_target,loyalty_programs.stamp_target),stamp_per_cents=coalesce(v_typed.stamp_per_cents,loyalty_programs.stamp_per_cents),stamp_validity_days=coalesce(v_typed.stamp_validity_days,loyalty_programs.stamp_validity_days),stamp_reward_expiry_days=coalesce(v_typed.stamp_reward_expiry_days,loyalty_programs.stamp_reward_expiry_days),tier_basis=v_typed.tier_basis,expiry_mode=v_typed.expiry_mode,expiry_days=v_typed.expiry_days,configuration_status='published',current_config_version_id=p_version where business_id=v_header.business_id;
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

-- CREATE OR REPLACE preserves grants; restated per governance (proacl verbatim: postgres,
-- service_role, authenticated).
revoke all on function public.publish_loyalty_config(uuid) from public, anon;
grant execute on function public.publish_loyalty_config(uuid) to authenticated, service_role;

-- ============ 3a: the loyalty draft creator clones what is LIVE, all 13 columns =============
CREATE OR REPLACE FUNCTION public.create_loyalty_config_draft(p_business uuid, p_based_on uuid DEFAULT NULL::uuid, p_source text DEFAULT 'manual'::text)
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'app', 'pg_temp'
AS $function$
declare
  v_actor uuid:=auth.uid();
  v_base uuid;
  v_id uuid;
  v_no integer;
  v_typed public.loyalty_program_versions%rowtype;
begin
  if not app.c45_owner_loyalty_write(p_business) then
    raise exception 'owner loyalty configuration access required' using errcode='42501';
  end if;
  perform 1 from public.businesses where id=p_business for update;
  v_base:=coalesce(
    p_based_on,
    app.active_config_version(p_business),
    (select current_config_version_id from public.loyalty_programs where business_id=p_business)
  );
  select * into v_typed from public.loyalty_program_versions
  where config_version_id=v_base and business_id=p_business;
  if not found then raise exception 'base configuration not found'; end if;
  select coalesce(max(version_no),0)+1 into v_no
  from public.firm_config_versions where business_id=p_business;
  v_id:=gen_random_uuid();
  insert into public.firm_config_versions(
    id,business_id,version_no,status,based_on_version_id,source,snapshot_hash,created_by
  ) values(
    v_id,p_business,v_no,'draft',v_base,
    coalesce(nullif(btrim(p_source),''),'manual'),
    md5((to_jsonb(v_typed)-'config_version_id')::text),v_actor
  );
  insert into public.loyalty_program_versions(
    config_version_id,business_id,kind,loyalty_model,active,
    earn_points_per_dollar,redeem_points,reward_credit_cents,stamp_target,
    stamp_per_cents,tier_basis,expiry_mode,expiry_days,stamp_validity_days,
    stamp_reward_expiry_days
  )
  -- nestly_v564: a draft is a clone of what is LIVE, not of the version it is based on. The
  -- base version is a historical snapshot; the live public.loyalty_programs row is what the
  -- counter, the customer app and the earn engine actually read. Cloning the snapshot is how a
  -- stale draft became a time machine: open the editor, publish something else, then save the
  -- first draft and the live row is rewritten from a version that is weeks old. The base row is
  -- kept only as the fallback for a column the live row has never held a value for.
  select v_id, base.business_id,
    coalesce(live.kind,base.kind),
    coalesce(live.loyalty_model,base.loyalty_model),
    coalesce(live.active,base.active),
    coalesce(live.earn_points_per_dollar,base.earn_points_per_dollar),
    coalesce(live.redeem_points,base.redeem_points),
    coalesce(live.reward_credit_cents,base.reward_credit_cents),
    coalesce(live.stamp_target,base.stamp_target),
    coalesce(live.stamp_per_cents,base.stamp_per_cents),
    coalesce(live.tier_basis,base.tier_basis),
    coalesce(live.expiry_mode,base.expiry_mode),
    coalesce(live.expiry_days,base.expiry_days),
    coalesce(live.stamp_validity_days,base.stamp_validity_days),
    coalesce(live.stamp_reward_expiry_days,base.stamp_reward_expiry_days)
  from public.loyalty_program_versions base
  left join public.loyalty_programs live on live.business_id=base.business_id
  where base.config_version_id=v_base and base.business_id=p_business;
  insert into public.loyalty_tier_versions(
    tier_id,config_version_id,business_id,name,threshold,points_multiplier,
    perk_note,sort,active,effective_from,expires_at
  )
  select tier_id,v_id,business_id,name,threshold,points_multiplier,
    perk_note,sort,active,effective_from,expires_at
  from public.loyalty_tier_versions where config_version_id=v_base;
  perform app.refresh_loyalty_config_snapshot(v_id);
  return json_build_object('version_id',v_id,'version_no',v_no,'status','draft');
end
$function$;

-- proacl verbatim: postgres, authenticated, service_role.
revoke all on function public.create_loyalty_config_draft(uuid,uuid,text) from public, anon;
grant execute on function public.create_loyalty_config_draft(uuid,uuid,text) to authenticated, service_role;

-- ============ 3b: the Grow draft creator, same rule + the two columns it never named ========
CREATE OR REPLACE FUNCTION public.create_grow_config_draft_v138(p_business uuid, p_based_on uuid DEFAULT NULL::uuid, p_source text DEFAULT 'grow_shared_edit'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'app', 'pg_temp'
AS $function$
declare
  v_actor uuid:=auth.uid();
  v_base uuid;
  v_existing public.firm_config_versions%rowtype;
  v_typed public.loyalty_program_versions%rowtype;
  v_id uuid;
  v_no integer;
  v_snapshot_hash text;
begin
  if v_actor is null or not app.is_salon_owner(p_business)
     or not (
       app.can_module_write(p_business,'loyalty')
       or app.can_module_write(p_business,'retention')
     ) then
    raise exception 'owner Grow configuration access required' using errcode='42501';
  end if;
  if p_source not in ('grow_shared_edit','grow_retention_edit','grow_reward_edit') then
    raise exception 'invalid Grow draft source' using errcode='22023';
  end if;

  perform 1 from public.businesses where id=p_business for update;
  if not found then
    raise exception 'business is unavailable' using errcode='22023';
  end if;
  perform pg_advisory_xact_lock(hashtextextended('v138:grow-draft:'||p_business::text,0));
  v_base:=coalesce(
    p_based_on,
    app.active_config_version(p_business),
    (select current_config_version_id from public.loyalty_programs where business_id=p_business)
  );
  if v_base is null or not exists(
    select 1 from public.firm_config_versions
     where id=v_base and business_id=p_business and status='published'
  ) then
    raise exception 'published base configuration not found' using errcode='22023';
  end if;

  select * into v_existing from public.firm_config_versions
   where business_id=p_business and based_on_version_id=v_base and status='draft'
   order by version_no desc limit 1 for update;
  if found then
    return jsonb_build_object(
      'version_id',v_existing.id,'version_no',v_existing.version_no,
      'status','draft','snapshot_hash',v_existing.snapshot_hash,
      'replayed',true,'published',false
    );
  end if;

  select * into v_typed from public.loyalty_program_versions
   where config_version_id=v_base and business_id=p_business;
  if not found then
    raise exception 'base Loyalty configuration not found' using errcode='22023';
  end if;
  select coalesce(max(version_no),0)+1 into v_no
    from public.firm_config_versions where business_id=p_business;
  v_id:=gen_random_uuid();
  insert into public.firm_config_versions(
    id,business_id,version_no,status,based_on_version_id,source,snapshot_hash,created_by
  ) values(
    v_id,p_business,v_no,'draft',v_base,p_source,
    md5((to_jsonb(v_typed)-'config_version_id')::text),v_actor
  );
  perform set_config('app.v138_grow_draft_id',v_id::text,true);
  perform set_config('app.v138_grow_draft_actor',v_actor::text,true);
  -- nestly_v564: all THIRTEEN typed columns, seeded from the LIVE programme row. This insert
  -- named eleven -- stamp_validity_days and stamp_reward_expiry_days were simply absent, so a
  -- Grow draft was born with NULLs in them and publish copied those NULLs straight over a live
  -- card's stamp validity and gift expiry. (publish now coalesces those two as well, so the
  -- erasure is closed from both ends.) The clone follows LIVE, not the base snapshot, for the
  -- same reason create_loyalty_config_draft does.
  insert into public.loyalty_program_versions(
    config_version_id,business_id,kind,loyalty_model,active,
    earn_points_per_dollar,redeem_points,reward_credit_cents,
    stamp_target,stamp_per_cents,tier_basis,expiry_mode,expiry_days,
    stamp_validity_days,stamp_reward_expiry_days
  ) select
    v_id, base.business_id,
    coalesce(live.kind,base.kind),
    coalesce(live.loyalty_model,base.loyalty_model),
    coalesce(live.active,base.active),
    coalesce(live.earn_points_per_dollar,base.earn_points_per_dollar),
    coalesce(live.redeem_points,base.redeem_points),
    coalesce(live.reward_credit_cents,base.reward_credit_cents),
    coalesce(live.stamp_target,base.stamp_target),
    coalesce(live.stamp_per_cents,base.stamp_per_cents),
    coalesce(live.tier_basis,base.tier_basis),
    coalesce(live.expiry_mode,base.expiry_mode),
    coalesce(live.expiry_days,base.expiry_days),
    coalesce(live.stamp_validity_days,base.stamp_validity_days),
    coalesce(live.stamp_reward_expiry_days,base.stamp_reward_expiry_days)
  from public.loyalty_program_versions base
  left join public.loyalty_programs live on live.business_id=base.business_id
  where base.config_version_id=v_base and base.business_id=p_business;
  perform set_config('app.v138_grow_draft_id','',true);
  perform set_config('app.v138_grow_draft_actor','',true);
  insert into public.loyalty_tier_versions(
    tier_id,config_version_id,business_id,name,threshold,
    points_multiplier,perk_note,sort,active
  ) select
    tier_id,v_id,business_id,name,threshold,
    points_multiplier,perk_note,sort,active
  from public.loyalty_tier_versions
  where config_version_id=v_base and business_id=p_business;
  perform app.refresh_loyalty_config_snapshot(v_id);
  select snapshot_hash into v_snapshot_hash
    from public.firm_config_versions where id=v_id;
  insert into public.audit_log(business_id,actor,action,entity,entity_id,detail)
  values(p_business,v_actor,'CREATE_GROW_DRAFT','firm_config_versions',v_id,
    jsonb_build_object('based_on_version_id',v_base,'source',p_source,'published',false));
  return jsonb_build_object(
    'version_id',v_id,'version_no',v_no,'status','draft',
    'snapshot_hash',v_snapshot_hash,'replayed',false,'published',false
  );
end $function$;

-- proacl verbatim: postgres, authenticated, service_role.
revoke all on function public.create_grow_config_draft_v138(uuid,uuid,text) from public, anon;
grant execute on function public.create_grow_config_draft_v138(uuid,uuid,text) to authenticated, service_role;

-- ============ 3c: the seed trigger names all 13 typed columns ===============================
CREATE OR REPLACE FUNCTION app.seed_loyalty_config_version()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'app', 'pg_temp'
AS $function$
declare v_id uuid := gen_random_uuid();
begin
  if new.current_config_version_id is not null then return new; end if;
  -- nestly_v507: born 'published', whatever word the inserting path used. The status of a firm's
  -- FIRST version is not a decision anyone makes — there is nothing yet to review, nothing to
  -- compare against, and no earlier version to keep serving while this one is drafted.
  insert into public.firm_config_versions(
    id,business_id,version_no,status,source,snapshot_hash,created_by,published_at
  ) values (
    v_id,new.business_id,1,'published',coalesce(new.recommendation_source,'initial'),
    md5((to_jsonb(new)-'id'-'business_id'-'current_config_version_id')::text),
    auth.uid(),now()
  );
  -- nestly_v564: all THIRTEEN typed columns. This seed named eleven, so a business's FIRST
  -- version recorded NULL stamp validity and NULL gift expiry even when the inserting row
  -- carried them -- version 1 disagreed with the live row it was seeded FROM on day one, and
  -- the first draft cloned from it inherited the hole.
  insert into public.loyalty_program_versions (
    config_version_id,business_id,kind,loyalty_model,active,earn_points_per_dollar,
    redeem_points,reward_credit_cents,stamp_target,stamp_per_cents,tier_basis,expiry_mode,expiry_days,
    stamp_validity_days,stamp_reward_expiry_days
  ) values (
    v_id,new.business_id,new.kind,new.loyalty_model,new.active,
    new.earn_points_per_dollar,new.redeem_points,new.reward_credit_cents,new.stamp_target,
    new.stamp_per_cents,new.tier_basis,new.expiry_mode,new.expiry_days,
    new.stamp_validity_days,new.stamp_reward_expiry_days
  );
  -- The base row must not keep saying 'draft' about a version that is live, or the Loyalty page
  -- and the engine would read two different answers to the same question.
  update public.loyalty_programs
     set current_config_version_id=v_id, configuration_status='published'
   where id=new.id;
  -- Never clobber a version a business is already serving: this trigger only ever seeds a FIRST
  -- one, so it claims the pointer only when nothing holds it.
  update public.businesses set active_config_version_id=v_id
   where id=new.business_id and active_config_version_id is null;
  return new;
end $function$;

-- proacl verbatim: postgres only (no anon/authenticated/service_role execute).
revoke all on function app.seed_loyalty_config_version() from public, anon, authenticated, service_role;

-- ============ 4: the editor's copy of the publish guards, spine-keyed (v563's rule) =========
CREATE OR REPLACE FUNCTION app.stamp_config_edit_commit_v433(p_business uuid, p_version uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'app', 'pg_temp'
AS $function$
declare
  v_typed public.loyalty_program_versions%rowtype;
  v_blockers jsonb := '[]'::jsonb;
  v_spine_stamps boolean; v_eff_target integer; v_eff_per_cents integer; -- nestly_v564
begin
  if not exists (select 1 from public.firm_config_versions
                  where id = p_version and business_id = p_business and status = 'draft') then
    return jsonb_build_object('publish_status', 'published', 'published_version_id', p_version);
  end if;
  select * into v_typed from public.loyalty_program_versions
   where config_version_id = p_version and business_id = p_business;
  -- The same shape rules publish_loyalty_config enforces, checked FIRST so an incomplete
  -- two-part edit pends with owner-language guidance instead of raising mid-save.
  -- nestly_v564: v563's rule, applied to the editor's own copy of the publish guards. These
  -- blockers were keyed on the DRAFT'S loyalty_model and judged the DRAFT'S stamp numbers, so a
  -- stale 'classic' clone skipped every one of them and the owner's save sailed through to
  -- publish_loyalty_config -- which since v563 keys on the spine and would raise mid-save, the
  -- exact outcome this pending/blockers path exists to prevent. Same gate, same effective
  -- values, so the two agree again.
  select coalesce(bool_or(spine.active) filter (where spine.kind='stamps'),false)
    into v_spine_stamps
    from public.business_programmes spine
   where spine.business_id = p_business;
  v_eff_target := coalesce(v_typed.stamp_target,
    (select prog.stamp_target from public.loyalty_programs prog where prog.business_id = p_business));
  v_eff_per_cents := coalesce(v_typed.stamp_per_cents,
    (select prog.stamp_per_cents from public.loyalty_programs prog where prog.business_id = p_business));
  if v_typed.loyalty_model = 'stamps' or v_spine_stamps then
    if coalesce(v_eff_per_cents, 0) <= 0 then
      v_blockers := v_blockers || jsonb_build_object(
        'code', 'stamp_spend_missing',
        'message', 'set how much a customer spends for 1 stamp to finish this change');
    end if;
    if coalesce(v_eff_target, 0) <= 0 then
      v_blockers := v_blockers || jsonb_build_object(
        'code', 'stamp_length_missing',
        'message', 'set how many stamps the card has to finish this change');
    else
      if exists (select 1 from public.loyalty_reward_versions rv
                   join public.business_programmes spine on spine.id = rv.programme_id
                  where rv.config_version_id = p_version and rv.business_id = p_business
                    and rv.active and spine.kind = 'stamps'
                    and rv.cost_points > v_eff_target) then
        v_blockers := v_blockers || jsonb_build_object(
          'code', 'stamp_gift_past_end',
          'message', format('a gift sits past stamp %s — move or remove it to finish this change', v_eff_target));
      end if;
      if not exists (select 1 from public.loyalty_reward_versions rv
                       join public.business_programmes spine on spine.id = rv.programme_id
                      where rv.config_version_id = p_version and rv.business_id = p_business
                        and rv.active and spine.kind = 'stamps'
                        and rv.cost_points = v_eff_target) then
        v_blockers := v_blockers || jsonb_build_object(
          'code', 'stamp_final_gift_missing',
          'message', format('add a gift at stamp %s to finish this change', v_eff_target));
      end if;
    end if;
  end if;
  if jsonb_array_length(v_blockers) > 0 then
    return jsonb_build_object('publish_status', 'pending',
      'draft_version_id', p_version, 'blockers', v_blockers);
  end if;
  perform public.publish_loyalty_config(p_version);
  return jsonb_build_object('publish_status', 'published', 'published_version_id', p_version);
end;
$function$;

-- proacl verbatim: postgres only (no anon/authenticated/service_role execute).
revoke all on function app.stamp_config_edit_commit_v433(uuid,uuid) from public, anon, authenticated, service_role;

-- ============ 5: the branch config resolver answers `active` from the spine =================
CREATE OR REPLACE FUNCTION app.resolve_loyalty_branch_config(p_business_id uuid, p_branch_id uuid, p_config_version_id uuid DEFAULT NULL::uuid)
 RETURNS TABLE(business_id uuid, config_version_id uuid, branch_id uuid, source text, kind text, loyalty_model text, active boolean, earn_points_per_dollar numeric, redeem_points integer, reward_credit_cents integer, stamp_target integer, stamp_per_cents integer, tier_basis text, expiry_mode text, expiry_days integer)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'app', 'pg_temp'
AS $function$
declare
  v_config_version_id uuid;
begin
  if p_branch_id is not null
     and not exists (
       select 1 from public.branches b
        where b.id = p_branch_id and b.business_id = p_business_id
     ) then
    raise exception 'branch does not belong to business' using errcode = 'foreign_key_violation';
  end if;

  v_config_version_id := coalesce(
    p_config_version_id,
    app.active_config_version(p_business_id)
  );

  -- A newly onboarded firm may still have only its inactive draft. In that
  -- case there is no earn configuration and recording a sale remains valid.
  if v_config_version_id is null then
    return;
  end if;

  if not exists (
    select 1 from public.firm_config_versions v
     where v.id = v_config_version_id and v.business_id = p_business_id
  ) then
    raise exception 'configuration version does not belong to business'
      using errcode = 'foreign_key_violation';
  end if;

  return query
  select d.business_id,
         d.config_version_id,
         p_branch_id,
         case when o.branch_id is null then 'firm_default' else 'branch_override' end,
         d.kind,
         d.loyalty_model,
         -- nestly_v564: `active` is the SPINE's answer, never the version row's. d.active is a
         -- snapshot of whatever flag the draft that produced this version happened to carry
         -- (nestly_v559 removed the same field's authority from publish_loyalty_config for
         -- exactly this reason, and set_programmes_v314's v514 sync writes this expression).
         -- The branch override still wins where a branch has one -- that is a per-branch
         -- decision, not a stale snapshot.
         coalesce(o.active, (select coalesce(bool_or(spine.active),false)
                               from public.business_programmes spine
                              where spine.business_id = d.business_id
                                and spine.kind in ('points','stamps','tiers'))),
         coalesce(o.earn_points_per_dollar, d.earn_points_per_dollar),
         d.redeem_points,
         d.reward_credit_cents,
         d.stamp_target,
         coalesce(o.stamp_per_cents, d.stamp_per_cents),
         d.tier_basis,
         coalesce(o.expiry_mode, d.expiry_mode),
         coalesce(o.expiry_days, d.expiry_days)
    from public.loyalty_program_versions d
    left join public.loyalty_branch_overrides o
      on o.config_version_id = d.config_version_id
     and o.business_id = d.business_id
     and o.branch_id is not distinct from p_branch_id
   where d.business_id = p_business_id
     and d.config_version_id = v_config_version_id;
end
$function$;

-- proacl verbatim: postgres only (no anon/authenticated/service_role execute).
revoke all on function app.resolve_loyalty_branch_config(uuid,uuid,uuid) from public, anon, authenticated, service_role;

commit;
