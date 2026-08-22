-- nestly_v435 — a stamp card may expire, on the rules it started with, without confiscating
-- anything the customer already earned (owner rules 4, 5 and 7, locked 2026-08-22).
--
-- THE RULES.
--   • Validity belongs to the VERSION: loyalty_program_versions.stamp_validity_days. Changing it
--     later never touches existing cards (the pin, nestly_v416/v433). NULL = the card never
--     expires — which is also what every version published before this migration says, so no
--     existing card gains an expiry retroactively.
--   • The clock starts at the FIRST STAMP of the cycle — never at join, never at publish.
--   • On expiry: the incomplete progress lapses (nothing carries), the cycle closes as history
--     (origin='expired', slots = the stamps forfeited, pinned to its version), and the next
--     qualifying earn starts a fresh card on the latest published version. No empty cycles are
--     minted by time alone: a card with zero stamps has no clock.
--   • Milestones the customer had ALREADY EARNED on the expired card survive: they remain
--     claimable at the counter, priced and named by the version they were earned under, one
--     claim per (expired cycle, reward), forever recorded against that cycle.
--   • Rule 7: earned stamp entitlements also remain claimable while the stamp programme is
--     switched OFF (frozen card) — earning stays gated by the spine, redemption of what was
--     already earned does not.
--
-- ENFORCEMENT is write-path + sweep, never read-path: a daily sweep closes due cards, and the
-- redemption path closes a due card before judging a claim (app.redeem_reward_core), as does the
-- earn path (nestly_v436's on_sale_recorded restatement). Readers may therefore lag physical
-- closure by at most a sweep interval; in that window only ALREADY-EARNED claims can succeed —
-- an unearned milestone is refused by the filled check either way, so no value can move wrongly.

begin;

-- ============================================================================================
-- §1  SCHEMA
-- ============================================================================================
alter table public.loyalty_program_versions
  add column if not exists stamp_validity_days integer
  check (stamp_validity_days is null or (stamp_validity_days between 1 and 3650));
comment on column public.loyalty_program_versions.stamp_validity_days is
  'nestly_v435: days a stamp card cycle stays valid, counted from the cycle''s first stamp. NULL = never expires. Version-pinned: an open cycle keeps the validity of the version it started under.';

alter table public.loyalty_programs
  add column if not exists stamp_validity_days integer
  check (stamp_validity_days is null or (stamp_validity_days between 1 and 3650));
comment on column public.loyalty_programs.stamp_validity_days is
  'nestly_v435: display mirror of the active version''s stamp validity. The engine reads the version rows.';

alter table public.stamp_cycles drop constraint if exists stamp_cycles_origin_check;
alter table public.stamp_cycles add constraint stamp_cycles_origin_check
  check (origin = any (array['claimed'::text,'migration'::text,'expired'::text]));
alter table public.stamp_cycles drop constraint if exists stamp_cycles_shape_check;
alter table public.stamp_cycles add constraint stamp_cycles_shape_check
  check (
    ((origin = 'claimed'::text)   and (redemption_id is not null) and (reward_id is not null) and (config_version_id is not null))
    or ((origin = 'migration'::text) and (redemption_id is null) and (reward_id is null))
    or ((origin = 'expired'::text)   and (redemption_id is null) and (reward_id is null) and (config_version_id is not null))
  );
comment on constraint stamp_cycles_shape_check on public.stamp_cycles is
  'claimed = closed by redeeming the final milestone; migration = reserved; expired (nestly_v435) = closed by the card''s validity lapsing — slots records the stamps forfeited, config_version_id the version the card was pinned to.';

-- ============================================================================================
-- §2  THE CLOCK — started_at / expires_at for the OPEN cycle, derived exactly the way the pin
--     itself is (nestly_v416): first positive stamps-pot ledger row after the last closure.
--
--     BOUNDARY FIX carried with it: the pin and the clock both take rows created AT OR AFTER
--     the last closure (>=, was >). now() is transaction-fixed, so a lazy close performed inside
--     the same transaction as the earn that follows it (nestly_v436's sale path) stamps
--     closed_at == the new card's first ledger row. With strict >, that first stamp would be
--     invisible to both readers forever — the new card would have no expiry clock and, worse, a
--     pin that keeps sliding to whatever is active. >= is safe because no closure path writes a
--     positive ledger row: a positive row sharing the closure's instant can only belong to the
--     NEW card.
-- ============================================================================================
create or replace function app.stamp_cycle_version_v416(p_business uuid, p_client uuid, p_programme uuid)
 returns uuid
 language plpgsql
 stable security definer
 set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $function$
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
     not be mistaken for the moment a card was started. nestly_v435: >= not > (see §2 header). */
  select min(pl.created_at) into v_started
    from public.points_ledger pl
   where pl.business_id = p_business and pl.client_id = p_client
     and pl.programme_id = p_programme and pl.points > 0
     and (v_last_close is null or pl.created_at >= v_last_close);

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
end $function$;

create or replace function app.stamp_cycle_deadline_v435(p_business uuid, p_client uuid, p_programme uuid)
returns table(started_at timestamptz, validity_days integer, expires_at timestamptz, config_version_id uuid, filled integer, cycle_index integer)
language sql
stable
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
  with closed as (
    select coalesce(max(sc.closed_at), '-infinity'::timestamptz) as last_close
      from public.stamp_cycles sc
     where sc.business_id = p_business and sc.client_id = p_client and sc.programme_id = p_programme
  ), started as (
    select min(pl.created_at) as at
      from public.points_ledger pl, closed
     where pl.business_id = p_business and pl.client_id = p_client
       and pl.programme_id = p_programme and pl.points > 0
       and pl.created_at >= closed.last_close
  ), pinned as (
    select app.stamp_cycle_version_v416(p_business, p_client, p_programme) as cfg
  ), progress as (
    select sp.filled, sp.cycle_index
      from app.stamp_progress_v323(p_business, p_client) sp
     limit 1
  )
  select started.at,
         lpv.stamp_validity_days,
         case when started.at is not null and lpv.stamp_validity_days is not null
              then started.at + make_interval(days => lpv.stamp_validity_days) end,
         pinned.cfg,
         coalesce(progress.filled, 0),
         coalesce(progress.cycle_index, 0)
    from started
    cross join pinned
    left join public.loyalty_program_versions lpv
      on lpv.config_version_id = pinned.cfg and lpv.business_id = p_business
    left join progress on true
$$;

-- ============================================================================================
-- §3  CLOSE A DUE CARD — the only writer of origin='expired'. Forfeits exactly the stamps the
--     card held (slots = filled at expiry), preserves everything else, and records which
--     version the card was pinned to. Never touches the ledger.
-- ============================================================================================
create or replace function app.stamp_expire_open_cycle_v435(p_business uuid, p_client uuid, p_programme uuid)
returns boolean
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_d record;
begin
  select * into v_d from app.stamp_cycle_deadline_v435(p_business, p_client, p_programme);
  if v_d.expires_at is null or v_d.expires_at > now() or coalesce(v_d.filled, 0) <= 0 then
    return false;
  end if;
  insert into public.stamp_cycles(
    business_id, programme_id, client_id, cycle_index, slots, origin, config_version_id, actor)
  values (p_business, p_programme, p_client, v_d.cycle_index, v_d.filled, 'expired', v_d.config_version_id, null);
  insert into public.audit_log(business_id, actor, action, entity, entity_id, detail)
  values (p_business, null, 'stamp_card.expired', 'stamp_cycles', p_client,
    jsonb_build_object('client_id', p_client, 'programme_id', p_programme,
      'cycle_index', v_d.cycle_index, 'stamps_forfeited', v_d.filled,
      'started_at', v_d.started_at, 'expired_at', v_d.expires_at,
      'config_version_id', v_d.config_version_id));
  return true;
end;
$$;

-- ============================================================================================
-- §4  SWEEP — daily, plus lazy closure on the redemption (below) and earn (nestly_v436) paths.
-- ============================================================================================
create or replace function app.run_stamp_expiry_for_business(p_business uuid)
returns integer
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_spine uuid;
  v_client uuid;
  v_count integer := 0;
begin
  select spine.id into v_spine from public.business_programmes spine
   where spine.business_id = p_business and spine.kind = 'stamps'
   order by spine.sort, spine.id limit 1;
  if v_spine is null then return 0; end if;
  for v_client in
    select distinct pl.client_id from public.points_ledger pl
     where pl.business_id = p_business and pl.programme_id = v_spine and pl.points > 0
  loop
    if app.stamp_expire_open_cycle_v435(p_business, v_client, v_spine) then
      v_count := v_count + 1;
    end if;
  end loop;
  return v_count;
end;
$$;

create or replace function app.run_stamp_expiry()
returns void
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare v_biz uuid;
begin
  for v_biz in
    select distinct spine.business_id
      from public.business_programmes spine
      join public.businesses b on b.id = spine.business_id
      join public.loyalty_program_versions lpv
        on lpv.config_version_id = b.active_config_version_id and lpv.business_id = b.id
     where spine.kind = 'stamps'
       -- The sweep also visits firms whose OPEN cards pin an OLDER version with validity set,
       -- which the active-version filter alone would miss — so the gate is deliberately loose:
       -- any firm where ANY version ever carried a validity.
       and exists (select 1 from public.loyalty_program_versions v2
                    where v2.business_id = b.id and v2.stamp_validity_days is not null)
  loop
    perform app.run_stamp_expiry_for_business(v_biz);
  end loop;
end;
$$;

do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.schedule('nestly-stamp-expiry', '30 19 * * *', 'select app.run_stamp_expiry()');
  end if;
end $$;

-- ============================================================================================
-- §5  DRAFT CLONING CARRIES VALIDITY — create_loyalty_config_draft restated with the column
--     (otherwise every v433 edit split would silently strip the card''s validity).
-- ============================================================================================
create or replace function public.create_loyalty_config_draft(p_business uuid, p_based_on uuid default null::uuid, p_source text default 'manual'::text)
 returns json
 language plpgsql
 security definer
 set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $function$
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
    stamp_per_cents,tier_basis,expiry_mode,expiry_days,stamp_validity_days
  )
  select v_id,business_id,kind,loyalty_model,active,
    earn_points_per_dollar,redeem_points,reward_credit_cents,stamp_target,
    stamp_per_cents,tier_basis,expiry_mode,expiry_days,stamp_validity_days
  from public.loyalty_program_versions where config_version_id=v_base;
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

-- ============================================================================================
-- §6  PUBLISH CARRIES VALIDITY onto the live mirror row — the nestly_v434 body with
--     stamp_validity_days added to the loyalty_programs restatement; everything else identical.
--     (Full body restated because PL/pgSQL functions are replaced whole.)
-- ============================================================================================
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
  -- nestly_v434: guards keyed on the DRAFT's declared model, never on the outgoing spine.
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
  update public.loyalty_programs set kind=v_typed.kind,loyalty_model=v_typed.loyalty_model,active=v_typed.active,earn_points_per_dollar=v_typed.earn_points_per_dollar,redeem_points=v_typed.redeem_points,reward_credit_cents=v_typed.reward_credit_cents,stamp_target=v_typed.stamp_target,stamp_per_cents=v_typed.stamp_per_cents,stamp_validity_days=v_typed.stamp_validity_days,tier_basis=v_typed.tier_basis,expiry_mode=v_typed.expiry_mode,expiry_days=v_typed.expiry_days,configuration_status='published',current_config_version_id=p_version where business_id=v_header.business_id;
  -- nestly_v431: THE PUBLISH CANNOT OVERWRITE THE DECLARED MODEL AGAINST THE SPINE. (Full
  -- rationale in 20260822_nestly_v431_publish_keeps_the_spine_model.sql.)
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
  update public.retention_programs rp set name=rv.name,active=(rv.active and rp.deleted_at is null),goal_visits=rv.goal_visits,period_days=rv.period_days,starts_on=rv.starts_on,reward_taxonomy_id=rv.reward_taxonomy_id,reward_type=rv.fulfillment_kind,reward_value=coalesce(rv.discount_percent,rv.credit_cents,0),reward_item=rv.manual_item,current_config_version_id=p_version from public.retention_program_versions rv where rv.program_id=rp.id and rv.business_id=rp.business_id and rv.config_version_id=p_version and rp.business_id=v_header.business_id;
  perform app.compile_program_rules(p_version);
  insert into public.audit_log(business_id,actor,action,entity,entity_id,detail)
  values(v_header.business_id,auth.uid(),'PUBLISH_CONFIG','firm_config_versions',p_version,jsonb_build_object('prior_version_id',v_prior,'new_version_id',p_version,'snapshot_hash',v_header.snapshot_hash,'birthday_program_count',(select count(*) from public.birthday_program_versions where config_version_id=p_version),'program_rule_count',(select count(*) from public.program_rules where config_version_id=p_version)));
  return json_build_object('version_id',p_version,'version_no',v_header.version_no,'status','published');
end $function$;

-- ============================================================================================
-- §7  EARNING RULE gains the validity field (6-arg replaces the 5-arg to avoid a PGRST203
--     overload ambiguity; the new parameter defaults, so existing named-parameter calls still
--     resolve). Validity routes through the same v433 split/token path as the other stamp rules.
-- ============================================================================================
drop function if exists public.business_set_earning_rule_v359(uuid, numeric, integer, text, integer);

create or replace function public.business_set_earning_rule_v359(
  p_business uuid,
  p_earn_points_per_dollar numeric default null::numeric,
  p_stamp_per_cents integer default null::integer,
  p_expiry_mode text default null::text,
  p_expiry_days integer default null::integer,
  p_stamp_validity_days integer default null::integer)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $function$
declare
  v_mode text := nullif(btrim(coalesce(p_expiry_mode,'')),'');
  v_days integer;
  v_row public.loyalty_programs%rowtype;
  v_active_version uuid;
  v_stamps_active boolean;
  v_target uuid;
  v_split boolean := false;
  -- nestly_v435: 0 is the UI's "never expires" — stored as NULL. Distinguish "not provided"
  -- (parameter null = leave alone) from "clear it" (0).
  v_validity_provided boolean := p_stamp_validity_days is not null;
  v_validity integer := case when coalesce(p_stamp_validity_days, 0) = 0 then null else p_stamp_validity_days end;
  v_commit jsonb := jsonb_build_object('publish_status', 'published');
begin
  if not app.c45_owner_loyalty_write(p_business) then
    raise exception 'owner loyalty configuration access required' using errcode='42501';
  end if;

  if p_earn_points_per_dollar is not null and p_earn_points_per_dollar <= 0 then
    raise exception 'points per dollar must be greater than zero' using errcode='22023';
  end if;
  if p_stamp_per_cents is not null and p_stamp_per_cents <= 0 then
    raise exception 'spend per stamp must be greater than zero' using errcode='22023';
  end if;
  if v_validity is not null and (v_validity < 1 or v_validity > 3650) then
    raise exception 'card validity must be between 1 and 3650 days' using errcode='22023';
  end if;

  if v_mode is not null then
    if v_mode not in ('none','fixed','inactivity') then
      raise exception 'invalid expiry mode' using errcode='22023';
    end if;
    if v_mode = 'none' then
      v_days := null;
    else
      v_days := p_expiry_days;
      if v_days is null or v_days < 1 or v_days > 3650 then
        raise exception 'expiry days must be between 1 and 3650' using errcode='22023';
      end if;
    end if;
  end if;

  insert into public.loyalty_programs(business_id, active, configuration_status,
    earn_points_per_dollar, stamp_per_cents, expiry_mode, expiry_days, stamp_validity_days)
  values (p_business, false, 'draft',
    coalesce(p_earn_points_per_dollar, 1), p_stamp_per_cents,
    coalesce(v_mode, 'none'), v_days, v_validity)
  on conflict (business_id) do update set
    -- NB: must test the PARAMETER, not `excluded`. The INSERT arm defaults an omitted rate to 1,
    -- so `excluded.earn_points_per_dollar` is never null and a coalesce here would silently reset
    -- a saved rate on every unrelated save.
    earn_points_per_dollar = case when p_earn_points_per_dollar is null then public.loyalty_programs.earn_points_per_dollar else excluded.earn_points_per_dollar end,
    stamp_per_cents        = case when p_stamp_per_cents is null then public.loyalty_programs.stamp_per_cents else excluded.stamp_per_cents end,
    expiry_mode            = case when v_mode is null then public.loyalty_programs.expiry_mode else excluded.expiry_mode end,
    expiry_days            = case when v_mode is null then public.loyalty_programs.expiry_days else excluded.expiry_days end,
    stamp_validity_days    = case when not v_validity_provided then public.loyalty_programs.stamp_validity_days else excluded.stamp_validity_days end
  returning * into v_row;

  select b.active_config_version_id into v_active_version
    from public.businesses b where b.id = p_business;
  if v_active_version is not null then
    v_stamps_active := exists (
      select 1 from public.business_programmes spine
       where spine.business_id = p_business and spine.kind = 'stamps' and spine.active);
    if v_stamps_active then
      v_target := app.stamp_config_edit_begin_v433(p_business);
      v_split := (v_target is distinct from v_active_version);
    else
      v_target := v_active_version;
    end if;

    if v_split then
      update public.loyalty_program_versions
         set earn_points_per_dollar = case when p_earn_points_per_dollar is null then earn_points_per_dollar else p_earn_points_per_dollar end,
             stamp_per_cents        = case when p_stamp_per_cents is null then stamp_per_cents else p_stamp_per_cents end,
             expiry_mode            = case when v_mode is null then expiry_mode else v_mode end,
             expiry_days            = case when v_mode is null then expiry_days else v_days end,
             stamp_validity_days    = case when not v_validity_provided then stamp_validity_days else v_validity end
       where config_version_id = v_target and business_id = p_business;
    else
      perform set_config('app.v433_program_edit_version_id', v_target::text, true);
      update public.loyalty_program_versions
         set earn_points_per_dollar = case when p_earn_points_per_dollar is null then earn_points_per_dollar else p_earn_points_per_dollar end,
             stamp_per_cents        = case when p_stamp_per_cents is null then stamp_per_cents else p_stamp_per_cents end,
             expiry_mode            = case when v_mode is null then expiry_mode else v_mode end,
             expiry_days            = case when v_mode is null then expiry_days else v_days end,
             stamp_validity_days    = case when not v_validity_provided then stamp_validity_days else v_validity end
       where config_version_id = v_target and business_id = p_business;
      perform set_config('app.v433_program_edit_version_id', '', true);
    end if;

    if v_split then
      v_commit := app.stamp_config_edit_commit_v433(p_business, v_target);
    end if;
  end if;

  select * into v_row from public.loyalty_programs where business_id = p_business;

  insert into public.audit_log(business_id, actor, action, entity, entity_id, detail)
  values (p_business, auth.uid(), 'earning_rule.updated', 'loyalty_programs', p_business,
    jsonb_build_object('earn_points_per_dollar', v_row.earn_points_per_dollar,
                       'stamp_per_cents', v_row.stamp_per_cents,
                       'expiry_mode', v_row.expiry_mode, 'expiry_days', v_row.expiry_days,
                       'stamp_validity_days', v_row.stamp_validity_days,
                       'version_split', v_split, 'target_version_id', v_target,
                       'publish_status', v_commit->>'publish_status'));

  return jsonb_build_object('status','ok',
    'earn_points_per_dollar', v_row.earn_points_per_dollar,
    'stamp_per_cents', v_row.stamp_per_cents,
    'expiry_mode', v_row.expiry_mode, 'expiry_days', v_row.expiry_days,
    'stamp_validity_days', v_row.stamp_validity_days,
    'version_split', v_split, 'target_version_id', v_target)
    || v_commit;
end
$function$;

-- ============================================================================================
-- §8  ACLS for §1-§7 (the redemption/availability/card readers follow in §9-§11)
-- ============================================================================================
revoke all on function app.stamp_cycle_version_v416(uuid, uuid, uuid) from public, anon, authenticated;
revoke all on function app.stamp_cycle_deadline_v435(uuid, uuid, uuid) from public, anon, authenticated;
revoke all on function app.stamp_expire_open_cycle_v435(uuid, uuid, uuid) from public, anon, authenticated;
revoke all on function app.run_stamp_expiry_for_business(uuid) from public, anon, authenticated;
revoke all on function app.run_stamp_expiry() from public, anon, authenticated;
revoke all on function public.create_loyalty_config_draft(uuid, uuid, text) from public, anon;
grant execute on function public.create_loyalty_config_draft(uuid, uuid, text) to authenticated, service_role;
revoke all on function public.publish_loyalty_config(uuid) from public, anon;
grant execute on function public.publish_loyalty_config(uuid) to authenticated, service_role;
revoke all on function public.business_set_earning_rule_v359(uuid, numeric, integer, text, integer, integer) from public, anon;
grant execute on function public.business_set_earning_rule_v359(uuid, numeric, integer, text, integer, integer) to authenticated, service_role;

-- ============================================================================================
-- §9  REDEMPTION — lazy closure + SURVIVING ENTITLEMENTS + claims-while-off (rules 4, 5, 7).
--     Restatement of app.redeem_reward_core (nestly_v416 base). Three changes, marked:
--       (a) a due stamp card is closed BEFORE the claim is judged (lazy expiry);
--       (b) if the current card cannot honour the claim, the newest EXPIRED cycle that earned
--           this milestone and has not claimed it yet does — priced and versioned by THAT
--           cycle's pinned configuration, never closing anything, never minting a new cycle;
--       (c) the spine-active requirement ('catalog redemption is inactive') now applies to
--           POINTS claims only — a stamp entitlement the customer already earned stays
--           claimable while the stamp programme is switched off (rule 7). Earning stays
--           spine-gated in app.on_sale_recorded, so nothing NEW accrues while off.
-- ============================================================================================
create or replace function app.redeem_reward_core(p_business uuid, p_client uuid, p_reward uuid, p_idempotency_key text, p_branch uuid default null::uuid, p_service uuid default null::uuid, p_product uuid default null::uuid)
 returns json
 language plpgsql
 security definer
 set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $function$
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
  v_survival boolean:=false; v_current_ok boolean; v_srv_cycle integer; v_srv_cfg uuid; -- nestly_v435
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
  if v_programme_kind = 'stamps' then
    -- nestly_v435 (a): a card past its deadline closes NOW, before the claim is judged, so the
    -- pin below already reflects the closed state and a fresh claim can never land on it.
    perform app.stamp_expire_open_cycle_v435(p_business, p_client, v_reward.programme_id);
    select sp.slots,sp.filled,sp.cycle_index into v_stamp_slots,v_stamp_filled,v_cycle_index from app.stamp_progress_v323(p_business,p_client) sp;
    if not found then raise exception 'this business is not running a stamp card' using errcode='XX001'; end if;
    v_config_version := app.stamp_cycle_version_v416(p_business, p_client, v_reward.programme_id);
    select rv.* into v_version from public.loyalty_reward_versions rv where rv.reward_id=p_reward and rv.business_id=p_business and rv.config_version_id=v_config_version;
    v_current_ok := v_version.id is not null and v_version.active and coalesce(v_stamp_slots,0)>0
                    and v_version.cost_points<=v_stamp_slots and v_stamp_filled>=v_version.cost_points;
    if not v_current_ok then
      -- nestly_v435 (b): SURVIVAL. The newest expired cycle on which this milestone was earned
      -- under its own version's rules and never claimed. One claim per (expired cycle, reward),
      -- enforced by the claims table's uniqueness exactly as on a live card.
      select sc.cycle_index, sc.config_version_id into v_srv_cycle, v_srv_cfg
        from public.stamp_cycles sc
       where sc.business_id=p_business and sc.client_id=p_client
         and sc.programme_id=v_reward.programme_id and sc.origin='expired'
         and exists (select 1 from public.loyalty_reward_versions rv
                      where rv.reward_id=p_reward and rv.business_id=p_business
                        and rv.config_version_id=sc.config_version_id and rv.active
                        and rv.cost_points <= sc.slots)
         and not exists (select 1 from public.stamp_milestone_claims claim
                      where claim.business_id=p_business and claim.client_id=p_client
                        and claim.programme_id=v_reward.programme_id
                        and claim.cycle_index=sc.cycle_index and claim.reward_id=p_reward)
       order by sc.cycle_index desc limit 1;
      if found then
        v_survival := true; v_cycle_index := v_srv_cycle; v_config_version := v_srv_cfg;
        select rv.* into v_version from public.loyalty_reward_versions rv where rv.reward_id=p_reward and rv.business_id=p_business and rv.config_version_id=v_srv_cfg;
      end if;
    end if;
  else
    v_config_version := (select b.active_config_version_id from public.businesses b where b.id = p_business);
    select rv.* into v_version from public.loyalty_reward_versions rv where rv.reward_id=p_reward and rv.business_id=p_business and rv.config_version_id=v_config_version;
  end if;
  if v_version.id is null or not v_version.active then raise exception 'reward not found or inactive'; end if;
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
  select spine.kind into v_programme_kind from public.business_programmes spine where spine.id=v_reward_programme;
  -- nestly_v435 (c): points claims still require the programme to be running; a stamp
  -- entitlement the customer already earned stays claimable while the programme is off.
  if v_programme_kind is distinct from 'stamps' and not exists(select 1 from public.business_programmes spine where spine.id=v_reward_programme and spine.active) then raise exception 'catalog redemption is inactive'; end if;
  if v_programme_kind='stamps' then
    v_consumes:=false; v_points_spent:=0;
    if not v_survival then
      if coalesce(v_stamp_slots,0)<=0 then raise exception 'this stamp card has no length set' using errcode='23514'; end if;
      if v_version.cost_points>v_stamp_slots then raise exception 'this gift sits past the end of the stamp card' using errcode='23514'; end if;
      if v_stamp_filled<v_version.cost_points then raise exception 'not enough stamps yet' using errcode='check_violation'; end if;
    end if;
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
        v_version.id,v_redemption_id,v_version.config_version_id,
        (not v_survival) and v_version.cost_points>=v_stamp_slots,v_actor);
      if (not v_survival) and v_version.cost_points>=v_stamp_slots then
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
    'stamp_cycle_index',v_cycle_index,'stamp_card_closed',v_cycle_id is not null,
    'from_expired_card',v_survival);
  perform set_config('app.loyalty_operation_complete_id',v_operation_id::text,true);
  update public.loyalty_operations set status='completed',result=v_result::jsonb,completed_at=now() where id=v_operation_id;
  perform set_config('app.loyalty_operation_complete_id','',true); return v_result;
end $function$;

-- ============================================================================================
-- §10  AVAILABILITY — app.reward_availability_v432 restated so every consumer (customer
--      catalogue, customer actions, staff redeem-now) automatically shows:
--        • surviving entitlements from expired cycles (rule 4/5), and
--        • earned-but-unclaimed stamp milestones while the programme is OFF (rule 7);
--      while points rewards keep requiring a running programme, exactly as before.
--      Signature and column list unchanged — a drop-in for all three readers.
-- ============================================================================================
create or replace function app.reward_availability_v432(
  p_business uuid,
  p_client uuid,
  p_as_of timestamptz default now()
) returns table (
  reward_id uuid,
  reward_version_id uuid,
  customer_name text,
  description text,
  image_ref text,
  terms text,
  instructions text,
  taxonomy_label text,
  fulfillment_kind text,
  cost_points integer,
  credit_cents integer,
  claim_available_from timestamptz,
  claim_available_until timestamptz,
  entitlement_expiry_days integer,
  sort integer,
  source text,
  unit text,
  gate_threshold numeric,
  gate_label text,
  tier_met boolean,
  branch_count integer,
  service_count integer,
  product_count integer,
  used_count integer,
  remaining_units integer,
  availability text
)
language sql
stable
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
  with business as (
    select b.id, b.active_config_version_id
      from public.businesses b
     where b.id = p_business
  ), stamps_spine as (
    -- nestly_v435: no `active` filter any more — a frozen card must still resolve its spine so
    -- earned milestones stay visible while the programme is off. The flag travels instead.
    select spine.id, spine.active from public.business_programmes spine
     where spine.business_id = p_business and spine.kind = 'stamps'
     order by spine.sort, spine.id limit 1
  ), points_spine as (
    select spine.id from public.business_programmes spine
     where spine.business_id = p_business and spine.kind = 'points' and spine.active
     order by spine.sort, spine.id limit 1
  ), stamp as (
    -- filled / cycle_index / slots exactly as redemption reads them (app.stamp_progress_v323).
    select coalesce(sp.slots, 0) as slots,
           coalesce(sp.filled, 0) as filled,
           coalesce(sp.cycle_index, 0) as cycle_index
      from app.stamp_progress_v323(p_business, p_client) sp
     limit 1
  ), pot as (
    -- The points balance a redemption can actually drain: the live points pot, capped by the
    -- proven batch remainder in the same pot (redeem_reward_core requires both).
    select least(
      (select coalesce(sum(pl.points), 0)::integer
         from public.points_ledger pl
        where pl.business_id = p_business and pl.client_id = p_client
          and pl.programme_id = (select id from points_spine)),
      (select coalesce(sum(pb.remaining), 0)::integer
         from public.points_batches pb
        where pb.business_id = p_business and pb.client_id = p_client
          and pb.remaining > 0
          and pb.programme_id = (select id from points_spine))
    ) as balance
  ), metric as (
    select app.v176_tier_gate_metric(p_business, p_client) as value
  ), stamp_version as (
    -- nestly_v416: a stamp gift is judged against the config the customer's OPEN card was
    -- started under — the same version redeem_reward_core will select.
    select case when exists (select 1 from stamps_spine)
      then app.stamp_cycle_version_v416(p_business, p_client, (select id from stamps_spine))
      end as config_version_id
  )
  select ranked.reward_id, ranked.reward_version_id, ranked.customer_name, ranked.description,
         ranked.image_ref, ranked.terms, ranked.instructions, ranked.taxonomy_label,
         ranked.fulfillment_kind, ranked.cost_points, ranked.credit_cents,
         ranked.claim_available_from, ranked.claim_available_until, ranked.entitlement_expiry_days,
         ranked.sort, ranked.source, ranked.unit, ranked.gate_threshold, ranked.gate_label,
         ranked.tier_met, ranked.branch_count, ranked.service_count, ranked.product_count,
         ranked.used_count, ranked.remaining_units, ranked.availability
  from (
    select rows.*, row_number() over (
      partition by rows.reward_id
      order by (rows.availability = 'available_at_counter') desc, rows.arm
    ) as rn
    from (
      select
        live.id as reward_id,
        rv.id as reward_version_id,
        rv.customer_name,
        rv.description,
        rv.image_ref,
        rv.terms,
        rv.instructions,
        rv.taxonomy_label,
        rv.fulfillment_kind,
        rv.cost_points::integer,
        rv.credit_cents::integer,
        rv.claim_available_from,
        rv.claim_available_until,
        rv.entitlement_expiry_days,
        rv.sort::integer,
        case when shape.is_stamp then 'stamp_card' else 'points' end as source,
        case when shape.is_stamp then 'stamps' else 'points' end as unit,
        gate.threshold as gate_threshold,
        gate.label as gate_label,
        case when gate.threshold is null then null
             else metric.value >= gate.threshold end as tier_met,
        scope.branch_count,
        scope.service_count,
        scope.product_count,
        usage.used_count,
        greatest(rv.cost_points - (case when shape.is_stamp
          then coalesce(stamp.filled, 0) else pot.balance end), 0)::integer as remaining_units,
        case
          when rv.claim_available_from is not null and rv.claim_available_from > p_as_of
            then 'not_started'
          when rv.claim_available_until is not null and rv.claim_available_until <= p_as_of
            then 'ended'
          when gate.threshold is not null and metric.value < gate.threshold
            then 'tier_locked'
          when rv.usage_limit is not null and usage.used_count >= rv.usage_limit
            then 'limit_reached'
          when shape.is_stamp
            and (coalesce(stamp.slots, 0) <= 0 or rv.cost_points > coalesce(stamp.slots, 0))
            then 'not_on_card'
          when shape.is_stamp and claimed.this_cycle
            then 'claimed_this_cycle'
          when (case when shape.is_stamp then coalesce(stamp.filled, 0) else pot.balance end)
               < rv.cost_points
            then 'insufficient_balance'
          else 'available_at_counter'
        end as availability,
        -- The programme gate redemption enforces for POINTS: the reward's own spine row must
        -- exist and be active. Rewards with no programme link stay excluded — redeem_reward_core
        -- refuses those (XX001), so listing them would promise a claim the counter cannot honour.
        exists (
          select 1 from public.business_programmes sp2
           where sp2.id = live.programme_id and sp2.active
        ) as programme_active,
        0 as arm
      from business
      join public.loyalty_rewards live
        on live.business_id = business.id
       and live.active
       and not live.paused
      cross join lateral (
        select coalesce(live.programme_id = (select id from stamps_spine), false) as is_stamp
      ) shape
      join public.loyalty_reward_versions rv
        on rv.reward_id = live.id
       and rv.business_id = live.business_id
       and rv.active
       and rv.config_version_id = case when shape.is_stamp
         then coalesce((select sv.config_version_id from stamp_version sv),
                       business.active_config_version_id)
         else business.active_config_version_id end
      left join stamp on true
      cross join pot
      cross join metric
      cross join lateral (
        select app.v176_reward_gate_threshold(p_business, rv.min_tier_id, rv.min_tier_threshold)
                 as threshold,
               app.v176_reward_gate_label(p_business, rv.min_tier_id) as label
      ) gate
      cross join lateral (
        select (select count(*)::integer from public.loyalty_reward_branches e
                 where e.reward_version_id = rv.id) as branch_count,
               (select count(*)::integer from public.loyalty_reward_services e
                 where e.reward_version_id = rv.id) as service_count,
               (select count(*)::integer from public.loyalty_reward_products e
                 where e.reward_version_id = rv.id) as product_count
      ) scope
      cross join lateral (
        select count(*)::integer as used_count
          from public.loyalty_redemptions lr
         where lr.business_id = p_business and lr.client_id = p_client
           and lr.reward_id = live.id
      ) usage
      cross join lateral (
        select exists (
          select 1 from public.stamp_milestone_claims claim
           where claim.business_id = p_business
             and claim.client_id = p_client
             and claim.programme_id = live.programme_id
             and claim.cycle_index = coalesce(stamp.cycle_index, 0)
             and claim.reward_id = live.id
        ) as this_cycle
      ) claimed
      where live.programme_id is not null
        and exists (select 1 from public.business_programmes sp3
                     where sp3.id = live.programme_id)

      union all

      -- nestly_v435 SURVIVAL ARM: milestones earned on EXPIRED cycles and never claimed, offered
      -- under the version that cycle was pinned to. remaining_units is 0 by definition (the
      -- stamps were already earned). Listable regardless of the spine's active flag (rule 7).
      select
        live.id,
        rv.id,
        rv.customer_name,
        rv.description,
        rv.image_ref,
        rv.terms,
        rv.instructions,
        rv.taxonomy_label,
        rv.fulfillment_kind,
        rv.cost_points::integer,
        rv.credit_cents::integer,
        rv.claim_available_from,
        rv.claim_available_until,
        rv.entitlement_expiry_days,
        rv.sort::integer,
        'stamp_card' as source,
        'stamps' as unit,
        gate.threshold,
        gate.label,
        case when gate.threshold is null then null
             else metric.value >= gate.threshold end,
        scope.branch_count,
        scope.service_count,
        scope.product_count,
        usage.used_count,
        0 as remaining_units,
        case
          when rv.claim_available_from is not null and rv.claim_available_from > p_as_of
            then 'not_started'
          when rv.claim_available_until is not null and rv.claim_available_until <= p_as_of
            then 'ended'
          when gate.threshold is not null and metric.value < gate.threshold
            then 'tier_locked'
          when rv.usage_limit is not null and usage.used_count >= rv.usage_limit
            then 'limit_reached'
          else 'available_at_counter'
        end as availability,
        true as programme_active,
        1 as arm
      from public.stamp_cycles sc
      join stamps_spine on stamps_spine.id = sc.programme_id
      join public.loyalty_reward_versions rv
        on rv.business_id = p_business
       and rv.config_version_id = sc.config_version_id
       and rv.active
       and rv.cost_points <= sc.slots
      join public.loyalty_rewards live
        on live.id = rv.reward_id
       and live.business_id = p_business
       and live.active
       and not live.paused
      cross join metric
      cross join lateral (
        select app.v176_reward_gate_threshold(p_business, rv.min_tier_id, rv.min_tier_threshold)
                 as threshold,
               app.v176_reward_gate_label(p_business, rv.min_tier_id) as label
      ) gate
      cross join lateral (
        select (select count(*)::integer from public.loyalty_reward_branches e
                 where e.reward_version_id = rv.id) as branch_count,
               (select count(*)::integer from public.loyalty_reward_services e
                 where e.reward_version_id = rv.id) as service_count,
               (select count(*)::integer from public.loyalty_reward_products e
                 where e.reward_version_id = rv.id) as product_count
      ) scope
      cross join lateral (
        select count(*)::integer as used_count
          from public.loyalty_redemptions lr
         where lr.business_id = p_business and lr.client_id = p_client
           and lr.reward_id = live.id
      ) usage
      where sc.business_id = p_business
        and sc.client_id = p_client
        and sc.origin = 'expired'
        and not exists (
          select 1 from public.stamp_milestone_claims claim
           where claim.business_id = p_business
             and claim.client_id = p_client
             and claim.programme_id = sc.programme_id
             and claim.cycle_index = sc.cycle_index
             and claim.reward_id = rv.reward_id
        )
    ) rows
    -- Rule 7 in one line: a running programme lists everything as before; a stopped STAMP
    -- programme lists only what the customer can genuinely claim right now.
    where rows.programme_active
       or (rows.source = 'stamp_card' and rows.availability = 'available_at_counter')
  ) ranked
  where ranked.rn = 1
$$;

-- ============================================================================================
-- §11  CUSTOMER READERS — the stamp card learns its clock and honours rule 7's ordering;
--      the wallet card's expiry object learns 'days' (for the points explainer).
-- ============================================================================================
create or replace function public.customer_get_stamp_card_v323(p_business_slug text)
 returns jsonb
 language plpgsql
 stable security definer
 set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $function$
declare
  v_context record;
  v_progress record;
  v_milestones jsonb;
  v_metric numeric;
  v_deadline record; -- nestly_v435
  v_spend_per_cents integer; -- nestly_v435
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

  -- nestly_v435: the open card's clock and pinned earn rate, from the version it started under.
  select * into v_deadline from app.stamp_cycle_deadline_v435(
    v_context.business_id, v_context.client_id, v_progress.programme_id);
  select lpv.stamp_per_cents into v_spend_per_cents
    from public.loyalty_program_versions lpv
   where lpv.config_version_id = v_deadline.config_version_id
     and lpv.business_id = v_context.business_id;
  if v_spend_per_cents is null then
    select lp.stamp_per_cents into v_spend_per_cents
      from public.loyalty_programs lp where lp.business_id = v_context.business_id;
  end if;

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
    -- nestly_v435 rule 7 ordering: an EARNED, unclaimed milestone stays claimable at the
    -- counter even while the programme is off; only what is not yet earned freezes.
    'availability', case
      when rung.claim_available_from is not null and now() < rung.claim_available_from
        then 'not_started'
      when rung.claim_available_until is not null and now() >= rung.claim_available_until
        then 'ended'
      when rung.gate_threshold is not null and v_metric < rung.gate_threshold then 'tier_locked'
      when rung.claimed then 'claimed_this_cycle'
      when rung.usage_limit is not null and rung.used_count >= rung.usage_limit
        then 'limit_reached'
      when v_progress.filled >= rung.cost_points then 'available_at_counter'
      when not v_progress.programme_active then 'paused'
      else 'insufficient_stamps'
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
    -- nestly_v435: the card's own rules, from the version this card started under.
    'spend_per_stamp_cents', v_spend_per_cents,
    'validity_days', v_deadline.validity_days,
    'started_at', v_deadline.started_at,
    'expires_at', v_deadline.expires_at,
    'expired', v_deadline.expires_at is not null and v_deadline.expires_at <= now()
               and coalesce(v_progress.filled, 0) > 0,
    'milestones', v_milestones,
    'next_milestone', (
      select rung.value from jsonb_array_elements(v_milestones) as rung(value)
       where (rung.value ->> 'claimed_this_cycle')::boolean is not true
       order by (rung.value ->> 'slot')::integer
       limit 1)
  );
end
$function$;

revoke all on function app.redeem_reward_core(uuid,uuid,uuid,text,uuid,uuid,uuid) from public, anon, authenticated;
revoke all on function app.reward_availability_v432(uuid, uuid, timestamptz) from public, anon, authenticated;
revoke all on function public.customer_get_stamp_card_v323(text) from public, anon;
grant execute on function public.customer_get_stamp_card_v323(text) to authenticated, service_role;

commit;
