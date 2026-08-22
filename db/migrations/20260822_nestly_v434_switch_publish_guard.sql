-- nestly_v434 — a stamps business can switch to Points + Tiers through the wizard (P1 from the
-- 2026-08-22 real-business simulation; owner rule 12, locked 2026-08-22).
--
-- THE DEFECT, proven live: publish_loyalty_config's stamp-card validation was keyed on the
-- CURRENT spine ("is stamps running right now?"), so a draft whose whole point is to switch the
-- business AWAY from stamps was validated as if it were a stamp card. Compounding it,
-- save_loyalty_reward_draft wrote no programme link, and the v313 auto-tagger then filed the
-- wizard's new points gifts under the RUNNING (stamps) programme — so the switching draft
-- carried a "stamp gift" costing 120 stamps and the publish died with "a stamp gift sits past
-- the last stamp on the card", with a Retry that could never succeed. The only way to switch
-- was an undocumented second route (the Points tile).
--
-- THE FIX. Two writers move to the DRAFT's own declaration:
--   1. publish_loyalty_config keys its stamps guards on v_typed.loyalty_model — the model the
--      draft is publishing INTO — not on the outgoing spine. A stamps draft is validated as a
--      stamp card wherever it is published; a points draft never is. (v433's edit splits publish
--      clones whose model is 'stamps', so every mid-life stamp edit keeps full validation.)
--   2. save_loyalty_reward_draft resolves the programme link from the draft's declared model, so
--      a gift authored while switching binds to the programme the draft is switching TO. Both
--      the live row and the version row carry it explicitly; the auto-tagger no longer decides.
-- Everything else in publish_loyalty_config is byte-identical to the nestly_v431 body,
-- including the v431 spine-authority block (the SPINE still owns which engine runs — a publish
-- still cannot flip the live model against it; the wizard switches the spine first).

begin;

create or replace function public.publish_loyalty_config(p_version uuid)
 returns json
 language plpgsql
 security definer
 set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $function$
declare v_header public.firm_config_versions%rowtype; v_typed public.loyalty_program_versions%rowtype; v_prior uuid;
  v_rule public.program_rules%rowtype; v_rule_errs text[]; v_active_rule_count integer;
  v_tier_carry_ids uuid[]; v_tier_carry_paused boolean[]; v_tier_carry_deleted timestamptz[];
  v_spine_stamps boolean; v_spine_points boolean; -- nestly_v431
begin
  select * into v_header from public.firm_config_versions where id=p_version for update;
  if not found or not app.c45_owner_loyalty_write(v_header.business_id) then raise exception 'owner loyalty configuration access required' using errcode='42501'; end if;
  if v_header.status<>'draft' then raise exception 'only a draft may be published'; end if;
  perform 1 from public.businesses where id=v_header.business_id for update;
  select * into v_typed from public.loyalty_program_versions where config_version_id=p_version;
  -- nestly_v434: the stamp-card guards are keyed on the DRAFT's declared model — what this
  -- publish turns on — never on the outgoing spine. A draft that switches a stamps firm to
  -- points must not be validated as a stamp card (that is the exact bug that made the switch
  -- wizard unpublishable); a draft that IS a stamp card is validated as one even before the
  -- spine has been switched over.
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
  update public.loyalty_programs set kind=v_typed.kind,loyalty_model=v_typed.loyalty_model,active=v_typed.active,earn_points_per_dollar=v_typed.earn_points_per_dollar,redeem_points=v_typed.redeem_points,reward_credit_cents=v_typed.reward_credit_cents,stamp_target=v_typed.stamp_target,stamp_per_cents=v_typed.stamp_per_cents,tier_basis=v_typed.tier_basis,expiry_mode=v_typed.expiry_mode,expiry_days=v_typed.expiry_days,configuration_status='published',current_config_version_id=p_version where business_id=v_header.business_id;
  -- ==========================================================================================
  -- nestly_v431: THE PUBLISH CANNOT OVERWRITE THE DECLARED MODEL AGAINST THE SPINE.
  -- v354 made loyalty_programs.loyalty_model/kind FOLLOW public.business_programmes on a
  -- switch (set_programmes_v314), and v426 unified every resolver on the spine. But the UPDATE
  -- directly above still restates loyalty_model/kind from the DRAFT snapshot (v_typed) — so
  -- publishing any draft cloned before the firm's last points<->stamps switch silently reverted
  -- the declared model. Observed live in the 2026-08-22 go-live battery: minutes after the v426
  -- backfill set Cubbly to stamps/stamps, one birthday save (draft cloned pre-backfill)
  -- published loyalty_model back to 'points_tiers' over an active stamps spine. Nothing that
  -- pays reads the column any more, but every label that still does (owner overview unit, the
  -- usage panel's stamp-card gate, programme_running_v371's no-spine fallback) went stale.
  -- The rule, owner-locked: the spine says which engine runs; a publish may change everything
  -- about the catalogue except that.
  select coalesce(bool_or(spine.active) filter (where spine.kind='stamps'),false),
         coalesce(bool_or(spine.active) filter (where spine.kind='points'),false)
    into v_spine_stamps, v_spine_points
    from public.business_programmes spine
   where spine.business_id=v_header.business_id;
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
  -- v332: `active` is now `rv.active and rp.deleted_at is null` -- rv.active alone can be a stale
  -- true (cloned from a frozen published snapshot before the program was deleted, or left stale in
  -- a draft this migration's delete RPC never touched). rp.deleted_at is the live, durable truth;
  -- it is not one of this UPDATE's target columns, so it can never be reset by this statement.
  update public.retention_programs rp set name=rv.name,active=(rv.active and rp.deleted_at is null),goal_visits=rv.goal_visits,period_days=rv.period_days,starts_on=rv.starts_on,reward_taxonomy_id=rv.reward_taxonomy_id,reward_type=rv.fulfillment_kind,reward_value=coalesce(rv.discount_percent,rv.credit_cents,0),reward_item=rv.manual_item,current_config_version_id=p_version from public.retention_program_versions rv where rv.program_id=rp.id and rv.business_id=rp.business_id and rv.config_version_id=p_version and rp.business_id=v_header.business_id;
  perform app.compile_program_rules(p_version);
  insert into public.audit_log(business_id,actor,action,entity,entity_id,detail)
  values(v_header.business_id,auth.uid(),'PUBLISH_CONFIG','firm_config_versions',p_version,jsonb_build_object('prior_version_id',v_prior,'new_version_id',p_version,'snapshot_hash',v_header.snapshot_hash,'birthday_program_count',(select count(*) from public.birthday_program_versions where config_version_id=p_version),'program_rule_count',(select count(*) from public.program_rules where config_version_id=p_version)));
  return json_build_object('version_id',p_version,'version_no',v_header.version_no,'status','published');
end $function$;

-- ============================================================================================
-- §2  DRAFT GIFTS BIND TO THE PROGRAMME THE DRAFT DECLARES
-- ============================================================================================
create or replace function public.save_loyalty_reward_draft(p_config_version uuid, p_reward_id uuid, p_reward jsonb, p_eligibility jsonb default '{}'::jsonb)
 returns json
 language plpgsql
 security definer
 set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $function$
declare
  v_header public.firm_config_versions%rowtype;
  v_existing public.loyalty_reward_versions%rowtype;
  v_reward_id uuid := coalesce(p_reward_id, gen_random_uuid());
  v_version_id uuid;
  v_internal_name text;
  v_customer_name text;
  v_description text;
  v_kind text;
  v_taxonomy text;
  v_cost integer;
  v_credit integer;
  v_estimated integer;
  v_active boolean;
  v_sort integer;
  v_claim_from timestamptz;
  v_claim_until timestamptz;
  v_entitlement_days integer;
  v_instructions text;
  v_terms text;
  v_image text;
  v_limit integer;
  v_min_tier_id uuid;
  v_min_tier_threshold integer;
  v_programme uuid; -- nestly_v434
begin
  if p_reward is null or jsonb_typeof(p_reward) <> 'object' then
    raise exception 'reward must be a JSON object' using errcode = '22023';
  end if;
  if p_eligibility is null or jsonb_typeof(p_eligibility) <> 'object' then
    raise exception 'eligibility must be a JSON object' using errcode = '22023';
  end if;
  if exists (
    select 1 from jsonb_object_keys(p_reward) k
     where k not in (
       'id','business_id','name','internal_name','customer_name','description','fulfillment_kind','taxonomy_label',
       'cost_points','credit_cents','estimated_cost_cents','active','sort',
       'claim_available_from','claim_available_until','entitlement_expiry_days',
       'instructions','terms','image_ref','usage_limit','min_tier_id','min_tier_threshold'
     )
  ) then raise exception 'reward contains unsupported fields' using errcode = '22023'; end if;
  if exists (select 1 from jsonb_object_keys(p_eligibility) k where k not in ('branches','services','products')) then
    raise exception 'eligibility contains unsupported fields' using errcode = '22023';
  end if;
  if jsonb_typeof(coalesce(p_eligibility->'branches','[]'::jsonb)) <> 'array'
     or jsonb_typeof(coalesce(p_eligibility->'services','[]'::jsonb)) <> 'array'
     or jsonb_typeof(coalesce(p_eligibility->'products','[]'::jsonb)) <> 'array' then
    raise exception 'each eligibility value must be an array' using errcode = '22023';
  end if;
  if jsonb_array_length(coalesce(p_eligibility->'branches','[]'::jsonb)) > 500
     or jsonb_array_length(coalesce(p_eligibility->'services','[]'::jsonb)) > 500
     or jsonb_array_length(coalesce(p_eligibility->'products','[]'::jsonb)) > 500 then
    raise exception 'eligibility arrays may contain at most 500 items' using errcode = '22023';
  end if;

  select * into v_header from public.firm_config_versions where id = p_config_version for update;
  if not found or not app.is_salon_owner(v_header.business_id) then
    raise exception 'owner only' using errcode = '42501';
  end if;
  if v_header.status <> 'draft' then raise exception 'only a draft reward configuration may be edited'; end if;
  if p_reward ? 'business_id' and (p_reward->>'business_id')::uuid is distinct from v_header.business_id then
    raise exception 'reward business does not match configuration business' using errcode = '42501';
  end if;
  if p_reward_id is not null and not exists (
    select 1 from public.loyalty_rewards where id = p_reward_id and business_id = v_header.business_id
  ) then raise exception 'reward does not belong to this business' using errcode = '42501'; end if;

  -- nestly_v434: the gift belongs to the programme this DRAFT declares, not to whichever spine
  -- happens to be running while the owner is mid-switch. Before this, the auto-tagger filed a
  -- switching wizard's points gifts under the outgoing stamps programme, and the publish guard
  -- then (correctly) refused them as impossible stamp gifts.
  select case when lpv.loyalty_model = 'stamps'
              then (select spine.id from public.business_programmes spine
                     where spine.business_id = v_header.business_id and spine.kind = 'stamps'
                     order by spine.sort, spine.id limit 1)
              else (select spine.id from public.business_programmes spine
                     where spine.business_id = v_header.business_id and spine.kind = 'points'
                     order by spine.sort, spine.id limit 1) end
    into v_programme
    from public.loyalty_program_versions lpv
   where lpv.config_version_id = p_config_version and lpv.business_id = v_header.business_id;

  select * into v_existing from public.loyalty_reward_versions
   where reward_id = v_reward_id and config_version_id = p_config_version for update;

  v_internal_name := coalesce(nullif(btrim(p_reward->>'internal_name'),''), nullif(btrim(p_reward->>'name'),''), v_existing.internal_name);
  v_customer_name := coalesce(nullif(btrim(p_reward->>'customer_name'),''), v_existing.customer_name);
  v_description := case when p_reward ? 'description' then nullif(p_reward->>'description','') else v_existing.description end;
  v_kind := coalesce(p_reward->>'fulfillment_kind', v_existing.fulfillment_kind, 'credit');
  v_taxonomy := case when p_reward ? 'taxonomy_label' then nullif(btrim(p_reward->>'taxonomy_label'),'') else v_existing.taxonomy_label end;
  v_cost := coalesce((p_reward->>'cost_points')::integer, v_existing.cost_points);
  v_credit := coalesce((p_reward->>'credit_cents')::integer, v_existing.credit_cents, 0);
  v_estimated := coalesce((p_reward->>'estimated_cost_cents')::integer, v_existing.estimated_cost_cents, v_credit);
  v_active := case when p_reward ? 'active' then (p_reward->>'active')::boolean else coalesce(v_existing.active, true) end;
  v_sort := coalesce((p_reward->>'sort')::integer, v_existing.sort, 0);
  v_claim_from := case when p_reward ? 'claim_available_from' then nullif(p_reward->>'claim_available_from','')::timestamptz else v_existing.claim_available_from end;
  v_claim_until := case when p_reward ? 'claim_available_until' then nullif(p_reward->>'claim_available_until','')::timestamptz else v_existing.claim_available_until end;
  v_entitlement_days := case when p_reward ? 'entitlement_expiry_days' then nullif(p_reward->>'entitlement_expiry_days','')::integer else v_existing.entitlement_expiry_days end;
  v_instructions := case when p_reward ? 'instructions' then nullif(p_reward->>'instructions','') else v_existing.instructions end;
  v_terms := case when p_reward ? 'terms' then nullif(p_reward->>'terms','') else v_existing.terms end;
  v_image := case when p_reward ? 'image_ref' then nullif(p_reward->>'image_ref','') else v_existing.image_ref end;
  v_limit := case when p_reward ? 'usage_limit' then nullif(p_reward->>'usage_limit','')::integer else v_existing.usage_limit end;
  if v_internal_name is null or v_customer_name is null or v_cost is null then
    raise exception 'internal_name, customer_name, and cost_points are required' using errcode = '22023';
  end if;
  if v_kind not in ('credit','manual_item') then raise exception 'unsupported fulfillment kind' using errcode = '22023'; end if;
  if (v_kind='credit' and v_credit <= 0) or (v_kind='manual_item' and v_credit <> 0) then
    raise exception 'credit rewards need positive credit; manual-item rewards must have zero credit' using errcode = '22023';
  end if;

  if not found then
    insert into public.loyalty_rewards (
      id, business_id, name, internal_name, customer_name, description, fulfillment_kind,
      taxonomy_label, cost_points, credit_cents, estimated_cost_cents, active, sort,
      claim_available_from, claim_available_until, entitlement_expiry_days, instructions, terms,
      image_ref, usage_limit, programme_id, current_config_version_id
    ) values (
      v_reward_id, v_header.business_id, v_customer_name, v_internal_name, v_customer_name,
      v_description, v_kind, v_taxonomy, v_cost, v_credit, v_estimated, false, v_sort,
      v_claim_from, v_claim_until, v_entitlement_days, v_instructions, v_terms, v_image, v_limit,
      v_programme, p_config_version
    );
  elsif v_programme is not null then
    -- An existing gift being edited inside a switching draft moves with the draft's declaration.
    update public.loyalty_rewards set programme_id = v_programme
     where id = v_reward_id and business_id = v_header.business_id
       and programme_id is distinct from v_programme;
  end if;

  v_min_tier_id := nullif(btrim(coalesce(p_reward->>'min_tier_id','')),'')::uuid;
  v_min_tier_threshold := nullif(btrim(coalesce(p_reward->>'min_tier_threshold','')),'')::integer;
  if v_min_tier_threshold is not null and v_min_tier_threshold < 0 then
    raise exception 'min_tier_threshold must be zero or greater' using errcode = '22023';
  end if;
  insert into public.loyalty_reward_versions (
    reward_id, business_id, config_version_id, internal_name, customer_name, description,
    fulfillment_kind, taxonomy_label, cost_points, credit_cents, estimated_cost_cents, active,
    sort, claim_available_from, claim_available_until, entitlement_expiry_days, instructions,
    terms, image_ref, usage_limit, min_tier_id, min_tier_threshold, programme_id
  ) values (
    v_reward_id, v_header.business_id, p_config_version, v_internal_name, v_customer_name,
    v_description, v_kind, v_taxonomy, v_cost, v_credit, v_estimated, v_active, v_sort,
    v_claim_from, v_claim_until, v_entitlement_days, v_instructions, v_terms, v_image, v_limit, v_min_tier_id, v_min_tier_threshold,
    v_programme
  ) on conflict (reward_id, config_version_id) do update set
    min_tier_id = excluded.min_tier_id, min_tier_threshold = excluded.min_tier_threshold,
    internal_name = excluded.internal_name, customer_name = excluded.customer_name,
    description = excluded.description, fulfillment_kind = excluded.fulfillment_kind,
    taxonomy_label = excluded.taxonomy_label, cost_points = excluded.cost_points,
    credit_cents = excluded.credit_cents, estimated_cost_cents = excluded.estimated_cost_cents,
    active = excluded.active, sort = excluded.sort, claim_available_from = excluded.claim_available_from,
    claim_available_until = excluded.claim_available_until,
    entitlement_expiry_days = excluded.entitlement_expiry_days, instructions = excluded.instructions,
    terms = excluded.terms, image_ref = excluded.image_ref,
    usage_limit = excluded.usage_limit,
    programme_id = excluded.programme_id
  returning id into v_version_id;

  delete from public.loyalty_reward_branches where reward_version_id = v_version_id;
  delete from public.loyalty_reward_services where reward_version_id = v_version_id;
  delete from public.loyalty_reward_products where reward_version_id = v_version_id;
  insert into public.loyalty_reward_branches (reward_version_id, reward_id, business_id, branch_id)
  select v_version_id, v_reward_id, v_header.business_id, x.value::uuid
    from jsonb_array_elements_text(coalesce(p_eligibility->'branches','[]'::jsonb)) x;
  insert into public.loyalty_reward_services (reward_version_id, reward_id, business_id, service_id)
  select v_version_id, v_reward_id, v_header.business_id, x.value::uuid
    from jsonb_array_elements_text(coalesce(p_eligibility->'services','[]'::jsonb)) x;
  insert into public.loyalty_reward_products (reward_version_id, reward_id, business_id, product_id)
  select v_version_id, v_reward_id, v_header.business_id, x.value::uuid
    from jsonb_array_elements_text(coalesce(p_eligibility->'products','[]'::jsonb)) x;
  perform app.refresh_loyalty_config_snapshot(p_config_version);
  return json_build_object('reward_id', v_reward_id, 'reward_version_id', v_version_id, 'status', 'draft');
end $function$;

-- ============================================================================================
-- §3  ACLS
-- ============================================================================================
revoke all on function public.publish_loyalty_config(uuid) from public, anon;
grant execute on function public.publish_loyalty_config(uuid) to authenticated, service_role;
revoke all on function public.save_loyalty_reward_draft(uuid, uuid, jsonb, jsonb) from public, anon;
grant execute on function public.save_loyalty_reward_draft(uuid, uuid, jsonb, jsonb) to authenticated, service_role;

commit;
