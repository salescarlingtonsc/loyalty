-- nestly_v565 -- every business is born the same.
--
-- THE DEFECT: a Peekaa tenant's loyalty configuration hangs off ONE row -- public.loyalty_programs
-- -- and five different code paths created businesses, each with its own opinion about that row.
-- start_self_serve_business_v130 deferred it to the Stripe-payment trigger; v95's activation
-- inserted it unconditionally; platform_decide_business_application_v105 and
-- platform_activate_approved_application_v169 inserted it only if app.c45_owner_loyalty_write
-- said yes and SILENTLY SKIPPED it otherwise; convert_sme_prospect_v79 never inserted it at all.
-- Three Settings RPCs (business_set_loyalty_model_v353, business_set_earning_rule_v359,
-- business_set_tier_basis_v347) then each bootstrapped the missing row with their OWN narrower
-- column set, so which columns a firm's loyalty row carried depended on which screen it happened
-- to touch first.
--
-- WHAT IT COST: public.create_loyalty_config_draft resolves a base version from that row; with no
-- row there is no version 1, so it raises 'base configuration not found' and the tenant can never
-- open Grow. TWO LIVE TENANTS are in exactly that state today ('Bear Bear Cafe' and the v518
-- concurrency probe): zero loyalty_programs rows, active_config_version_id NULL.
--
-- THE FIX: app.ensure_loyalty_program_row is the ONE birth of that row -- idempotent, the full
-- onboarding preset (earn 1, redeem 800, reward credit 2000c, classic, inactive, draft), every
-- column the richest creation path sets. Every ad-hoc bootstrapper now calls it. The two platform
-- paths no longer fail silently: if the owner guard refuses, the definer helper creates the row
-- and says so in audit_log. create_loyalty_config_draft creates the row rather than dead-ending.
-- The two stranded tenants are repaired. app.seed_loyalty_config_version (v507, "born live") does
-- the rest -- version 1, published, in the same transaction as the insert.
--
-- TWO MORE TRUTHS, same theme -- a programme that is on must BE on:
--   * v514 synced loyalty_programs.active = (points OR stamps). A business running Tier
--     membership alone therefore synced itself to active=false and every customer surface that
--     gates on that flag went dark while the business read "Tiers: On". Tiers join the formula.
--   * set_programmes_v314 let referral be switched ON with no public.referral_programs row behind
--     it. v425 (a) deliberately declines to invent one -- correct -- but the result was a switch
--     that read live and paid nobody. Turning referral on now requires its reward to exist first.
--
-- NOT CHANGED HERE: the stamps-exclusivity guard, every RPC's own update logic, the c45 owner
-- guard itself, and public.publish_loyalty_config (its own copy of the active formula is folded
-- into nestly_v564 to keep these two migrations from colliding on one function).
--
-- ROLLBACK: db/tests/v565_every_business_born_the_same.sql

begin;

-- ============ PRECONDITIONS: the shapes this migration expects to find =======================
do $pre$
begin
  if to_regprocedure('app.ensure_loyalty_program_row(uuid,text)') is not null then
    raise exception 'v565: app.ensure_loyalty_program_row already exists -- re-derive from live';
  end if;
  if position('insert into public.loyalty_programs(business_id, loyalty_model, kind, active, configuration_status)'
       in pg_get_functiondef('public.business_set_loyalty_model_v353(uuid,text)'::regprocedure)) = 0 then
    raise exception 'v565: business_set_loyalty_model_v353 no longer carries its own bootstrap insert';
  end if;
  if position('insert into public.loyalty_programs(business_id, tier_basis, active, configuration_status)'
       in pg_get_functiondef('public.business_set_tier_basis_v347(uuid,text)'::regprocedure)) = 0 then
    raise exception 'v565: business_set_tier_basis_v347 no longer carries its own bootstrap insert';
  end if;
  if position('on conflict (business_id) do update set'
       in pg_get_functiondef('public.business_set_earning_rule_v359(uuid,numeric,integer,text,integer,integer,integer)'::regprocedure)) = 0 then
    raise exception 'v565: business_set_earning_rule_v359 no longer carries its own bootstrap upsert';
  end if;
  if position('if not found then raise exception ''base configuration not found''; end if;'
       in pg_get_functiondef('public.create_loyalty_config_draft(uuid,uuid,text)'::regprocedure)) = 0 then
    raise exception 'v565: create_loyalty_config_draft no longer carries the base-not-found dead end';
  end if;
  if position('if app.c45_owner_loyalty_write(v_business.id) then'
       in pg_get_functiondef('public.platform_decide_business_application_v105(uuid,text,text,bigint,uuid)'::regprocedure)) = 0
   or position('if app.c45_owner_loyalty_write(v_business.id) then'
       in pg_get_functiondef('public.platform_activate_approved_application_v169(uuid,uuid)'::regprocedure)) = 0 then
    raise exception 'v565: a platform application path no longer carries the guarded preset insert';
  end if;
  if position('set active = (v_points or v_stamps)'
       in pg_get_functiondef('public.set_programmes_v314(uuid,jsonb,uuid)'::regprocedure)) = 0 then
    raise exception 'v565: set_programmes_v314 does not carry the v514 active formula -- re-derive from live';
  end if;
  if position('v_tiers' in pg_get_functiondef('public.set_programmes_v314(uuid,jsonb,uuid)'::regprocedure)) > 0 then
    raise exception 'v565: set_programmes_v314 already captures the tiers spine';
  end if;
  -- The whole "born live" claim rests on this trigger: the insert below publishes version 1.
  if not exists (
    select 1 from pg_trigger t
     where t.tgrelid='public.loyalty_programs'::regclass
       and t.tgname='trg_seed_loyalty_config_version' and not t.tgisinternal
  ) then
    raise exception 'v565: app.seed_loyalty_config_version no longer fires on loyalty_programs insert';
  end if;
end
$pre$;

-- ============ THE ONE BIRTH OF A TENANT'S LOYALTY ROW ========================================
-- The column list and values below are copied verbatim from the richest existing creation path,
-- public.platform_decide_business_application_v105 (identical in v169,
-- activate_approved_business_application_v95 and app.activate_self_serve_paid_v130, which differ
-- only in recommendation_source). Nothing here turns anything ON: active=false and
-- configuration_status='draft', which is also what loyalty_programs_configuration_status_check
-- requires of each other (draft => not active). What the owner switches on, the owner switches on.
--
-- ON CONFLICT DO NOTHING makes it idempotent and makes it safe to call from a path that does not
-- know whether the row exists -- which is every path.
CREATE OR REPLACE FUNCTION app.ensure_loyalty_program_row(p_business uuid, p_source text DEFAULT 'bootstrap'::text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'app', 'pg_temp'
AS $function$
begin
  if p_business is null then
    raise exception 'business is required' using errcode='22023';
  end if;
  insert into public.loyalty_programs(
    business_id,kind,earn_points_per_dollar,redeem_points,
    reward_credit_cents,active,loyalty_model,configuration_status,
    recommendation_source
  ) values(
    p_business,'points',1,800,2000,false,'classic','draft',
    coalesce(nullif(btrim(coalesce(p_source,'')),''),'bootstrap')
  ) on conflict(business_id) do nothing;
end
$function$;

-- No API role may call this directly: it is a definer helper invoked only from SECURITY DEFINER
-- callers that have already established who the caller is and what they may do. Mirrors every
-- app.* sibling (app.active_config_version, app.c45_owner_loyalty_write,
-- app.seed_loyalty_config_version: proacl '{postgres=X/postgres}').
revoke all on function app.ensure_loyalty_program_row(uuid,text) from public, anon, authenticated, service_role;

-- ============ THE AD-HOC BOOTSTRAPPERS NOW ASK THE HELPER =================================
CREATE OR REPLACE FUNCTION public.business_set_loyalty_model_v353(p_business uuid, p_model text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'app', 'pg_temp'
AS $function$
declare
  v_kind text;
begin
  perform app.acquire_loyalty_exclusive_v480(p_business);
  if not app.c45_owner_loyalty_write(p_business) then
    raise exception 'owner loyalty configuration access required' using errcode='42501';
  end if;
  if p_model is null or p_model not in ('classic','points_tiers','stamps') then
    raise exception 'invalid loyalty model' using errcode='22023';
  end if;
  v_kind := case when p_model='stamps' then 'stamps' else 'points' end;

  -- nestly_v565: the ad-hoc bootstrap that used to live here inserted a NARROWER row than every
  -- creation path -- loyalty_model and kind only, no earn rate, no redeem_points, no
  -- reward_credit_cents. A tenant that reached Settings before it reached onboarding was born
  -- different from its neighbours. One helper now owns the birth of the row, with the full
  -- onboarding preset, and this RPC only does what its name says: set the model.
  perform app.ensure_loyalty_program_row(p_business, 'settings_bootstrap');
  update public.loyalty_programs
     set loyalty_model=p_model, kind=v_kind
   where business_id=p_business;

  insert into public.audit_log(business_id,actor,action,entity,entity_id,detail)
  values(p_business,auth.uid(),'loyalty_model.updated','loyalty_programs',p_business,
    jsonb_build_object('loyalty_model',p_model,'kind',v_kind));

  return jsonb_build_object('status','ok','loyalty_model',p_model,'kind',v_kind);
end
$function$;
CREATE OR REPLACE FUNCTION public.business_set_earning_rule_v359(p_business uuid, p_earn_points_per_dollar numeric DEFAULT NULL::numeric, p_stamp_per_cents integer DEFAULT NULL::integer, p_expiry_mode text DEFAULT NULL::text, p_expiry_days integer DEFAULT NULL::integer, p_stamp_validity_days integer DEFAULT NULL::integer, p_stamp_reward_expiry_days integer DEFAULT NULL::integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'app', 'pg_temp'
AS $function$
declare
  v_mode text := nullif(btrim(coalesce(p_expiry_mode,'')),'');
  v_days integer;
  v_row public.loyalty_programs%rowtype;
  v_active_version uuid;
  v_stamps_active boolean;
  v_target uuid;
  v_split boolean := false;
  v_validity_provided boolean := p_stamp_validity_days is not null;
  v_validity integer := case when coalesce(p_stamp_validity_days, 0) = 0 then null else p_stamp_validity_days end;
  v_reward_expiry_provided boolean := p_stamp_reward_expiry_days is not null;
  v_reward_expiry integer := case when coalesce(p_stamp_reward_expiry_days, 0) = 0 then null else p_stamp_reward_expiry_days end;
  v_commit jsonb := jsonb_build_object('publish_status', 'published');
begin
  perform app.acquire_loyalty_exclusive_v480(p_business);
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
  if v_reward_expiry is not null and (v_reward_expiry < 1 or v_reward_expiry > 3650) then
    raise exception 'reward expiry must be between 1 and 3650 days' using errcode='22023';
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

  -- nestly_v565: the bootstrap half of this upsert is gone -- app.ensure_loyalty_program_row owns
  -- the birth of the row for every path, with the full onboarding preset. What remains is exactly
  -- the DO UPDATE branch this statement always took for an existing row, unchanged: a NULL
  -- parameter still means "leave this field alone".
  perform app.ensure_loyalty_program_row(p_business, 'settings_bootstrap');
  update public.loyalty_programs set
    earn_points_per_dollar = case when p_earn_points_per_dollar is null then public.loyalty_programs.earn_points_per_dollar else p_earn_points_per_dollar end,
    stamp_per_cents        = case when p_stamp_per_cents is null then public.loyalty_programs.stamp_per_cents else p_stamp_per_cents end,
    expiry_mode            = case when v_mode is null then public.loyalty_programs.expiry_mode else v_mode end,
    expiry_days            = case when v_mode is null then public.loyalty_programs.expiry_days else v_days end,
    stamp_validity_days    = case when not v_validity_provided then public.loyalty_programs.stamp_validity_days else v_validity end,
    stamp_reward_expiry_days = case when not v_reward_expiry_provided then public.loyalty_programs.stamp_reward_expiry_days else v_reward_expiry end
  where public.loyalty_programs.business_id = p_business
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
             stamp_validity_days    = case when not v_validity_provided then stamp_validity_days else v_validity end,
             stamp_reward_expiry_days = case when not v_reward_expiry_provided then stamp_reward_expiry_days else v_reward_expiry end
       where config_version_id = v_target and business_id = p_business;
    else
      perform set_config('app.v433_program_edit_version_id', v_target::text, true);
      update public.loyalty_program_versions
         set earn_points_per_dollar = case when p_earn_points_per_dollar is null then earn_points_per_dollar else p_earn_points_per_dollar end,
             stamp_per_cents        = case when p_stamp_per_cents is null then stamp_per_cents else p_stamp_per_cents end,
             expiry_mode            = case when v_mode is null then expiry_mode else v_mode end,
             expiry_days            = case when v_mode is null then expiry_days else v_days end,
             stamp_validity_days    = case when not v_validity_provided then stamp_validity_days else v_validity end,
             stamp_reward_expiry_days = case when not v_reward_expiry_provided then stamp_reward_expiry_days else v_reward_expiry end
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
                       'stamp_reward_expiry_days', v_row.stamp_reward_expiry_days,
                       'version_split', v_split, 'target_version_id', v_target,
                       'publish_status', v_commit->>'publish_status'));

  return jsonb_build_object('status','ok',
    'earn_points_per_dollar', v_row.earn_points_per_dollar,
    'stamp_per_cents', v_row.stamp_per_cents,
    'expiry_mode', v_row.expiry_mode, 'expiry_days', v_row.expiry_days,
    'stamp_validity_days', v_row.stamp_validity_days,
    'stamp_reward_expiry_days', v_row.stamp_reward_expiry_days,
    'version_split', v_split, 'target_version_id', v_target)
    || v_commit;
end
$function$;
CREATE OR REPLACE FUNCTION public.business_set_tier_basis_v347(p_business uuid, p_basis text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'app', 'pg_temp'
AS $function$
declare
  v_basis text := nullif(btrim(coalesce(p_basis,'')),'');
begin
  perform app.acquire_loyalty_exclusive_v480(p_business);
  if not app.c45_owner_loyalty_write(p_business) then
    raise exception 'owner loyalty configuration access required' using errcode='42501';
  end if;
  if v_basis is null or v_basis not in ('visits','spend','points_earned') then
    raise exception 'invalid tier basis' using errcode='22023';
  end if;

  -- nestly_v565: this path used to birth the row with tier_basis alone. Every column the
  -- onboarding preset sets was left at its table default, so a business that saved a tier basis
  -- first held a different row from one that came through onboarding. app.ensure_loyalty_program_row
  -- is now the single birth, and this RPC only sets the basis.
  perform app.ensure_loyalty_program_row(p_business, 'settings_bootstrap');
  update public.loyalty_programs
     set tier_basis=v_basis
   where business_id=p_business;

  insert into public.audit_log(business_id,actor,action,entity,entity_id,detail)
  values(p_business,auth.uid(),'tier_basis.updated','loyalty_programs',p_business,
    jsonb_build_object('tier_basis',v_basis));

  return jsonb_build_object('status','ok','tier_basis',v_basis);
end
$function$;

-- ============ GROW NO LONGER DEAD-ENDS ON A MISSING ROW ===================================
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
  if not found then
    -- nestly_v565: 'base configuration not found' was the dead end every tenant born without a
    -- loyalty_programs row hit -- it could never open Grow, because the first thing Grow does is
    -- ask for a draft and there was nothing to base one on. Give the business the row it should
    -- have been born with; app.seed_loyalty_config_version then publishes version 1 (v507, "born
    -- live"), and the base resolves on the retry below. Only a base that is STILL missing raises.
    perform app.ensure_loyalty_program_row(p_business, 'draft_bootstrap');
    v_base:=coalesce(
      p_based_on,
      app.active_config_version(p_business),
      (select current_config_version_id from public.loyalty_programs where business_id=p_business)
    );
    select * into v_typed from public.loyalty_program_versions
    where config_version_id=v_base and business_id=p_business;
    if not found then raise exception 'base configuration not found'; end if;
  end if;
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
  -- (merged nestly_v564 + nestly_v565: bootstrap above, clone-from-live below -- both
  --  migrations replace this function; this v565 copy is derived FROM v564's so the later
  --  apply cannot undo the earlier one.)
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

-- ============ THE PLATFORM PATHS FAIL LOUDLY, NEVER SILENTLY ==============================
CREATE OR REPLACE FUNCTION public.platform_decide_business_application_v105(p_application uuid, p_decision text, p_reason text, p_expected_version bigint, p_idempotency_key uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'app', 'pg_temp'
AS $function$
declare
  v_actor uuid:=auth.uid();
  v_v277_prior_sub text:=current_setting('request.jwt.claim.sub',true);
  v_v277_prior_claims text:=current_setting('request.jwt.claims',true);
  v_reason text:=case
    when p_decision='approved' then 'Approved by Super Admin'
    else btrim(coalesce(p_reason,''))
  end;
  v_request_hash text;
  v_receipt public.platform_application_decision_receipts_v105%rowtype;
  v_application public.business_applications_v95%rowtype;
  v_owner uuid;
  v_bundle public.sector_bundle_versions%rowtype;
  v_business public.businesses%rowtype;
  v_staff uuid;
  v_branch uuid;
  v_slug_base text;
  v_slug text;
  v_suffix integer:=0;
  v_response jsonb;
begin
  if not app.is_super_admin() then
    raise exception 'super_admin_required' using errcode='42501';
  end if;
  if p_application is null or p_idempotency_key is null
     or p_decision not in ('approved','rejected')
     or length(v_reason) not between 3 and 1000
     or p_expected_version is null
  then
    raise exception 'valid decision, reason, version and idempotency key are required'
      using errcode='22023';
  end if;

  v_request_hash:=app.v95_sha256(concat_ws('|',
    p_application::text,p_decision,v_reason,p_expected_version::text
  ));
  perform pg_advisory_xact_lock(hashtextextended(p_idempotency_key::text,105));

  select * into v_receipt
    from public.platform_application_decision_receipts_v105 receipt
   where receipt.idempotency_key=p_idempotency_key
   for update;
  if found then
    if v_receipt.actor<>v_actor
       or v_receipt.application_id<>p_application
       or v_receipt.request_hash<>v_request_hash then
      raise exception 'application_decision_idempotency_conflict'
        using errcode='22023';
    end if;
    select * into v_application
      from public.business_applications_v95 application
     where application.id=p_application
     for update;
    if v_application.status not in (v_receipt.decision,'consumed') then
      raise exception 'application_decision_receipt_state_conflict'
        using errcode='40001';
    end if;
    return jsonb_build_object(
      'application_id',p_application,
      'status',v_application.status,
      'version',v_application.version,
      'business_id',v_application.consumed_business_id,
      'workspace_created',v_application.status='consumed',
      'workspace_access',v_application.status='consumed',
      'replayed',true,
      'response_version',v_receipt.response_version
    );
  end if;

  select * into v_application
    from public.business_applications_v95 application
   where application.id=p_application
   for update;
  if not found then
    raise exception 'application_not_found' using errcode='22023';
  end if;
  if v_application.status<>'submitted' then
    raise exception 'application_is_not_pending' using errcode='23514';
  end if;
  if v_application.version<>p_expected_version then
    raise exception 'application_version_conflict' using errcode='40001';
  end if;

  if p_decision='rejected' then
    update public.business_applications_v95
       set status='rejected',version=version+1,decided_by=v_actor,
           decided_at=now(),decision_reason=v_reason,updated_at=now()
     where id=p_application
     returning * into v_application;
    insert into public.business_application_audit_v95(
      application_id,event_type,actor,prior_status,new_status,reason
    ) values(
      p_application,'rejected',v_actor,'submitted','rejected',v_reason
    );
    insert into public.platform_application_decision_receipts_v105(
      idempotency_key,application_id,actor,request_hash,decision,
      invitation_id,response_version
    ) values(
      p_idempotency_key,p_application,v_actor,v_request_hash,'rejected',
      null,1
    ) returning * into v_receipt;
    return jsonb_build_object(
      'application_id',p_application,'status','rejected',
      'version',v_application.version,'workspace_created',false,
      'workspace_access',false,'replayed',false,'response_version',1
    );
  end if;

  select user_row.id into v_owner
    from auth.users user_row
   where lower(user_row.email)=v_application.contact_email
     and coalesce(user_row.email_confirmed_at,user_row.confirmed_at) is not null
   order by user_row.created_at asc,user_row.id asc
   limit 1;
  if v_owner is null then
    raise exception 'owner_account_not_found_for_application' using errcode='42501';
  end if;
  if exists(select 1 from public.staff staff_row where staff_row.user_id=v_owner) then
    raise exception 'owner_account_already_has_workspace' using errcode='42501';
  end if;

  select * into v_bundle
    from public.sector_bundle_versions
   where sector_key=v_application.sector_key and status='published';
  if not found then
    raise exception 'published_sector_required' using errcode='23514';
  end if;

  v_slug_base:=lower(regexp_replace(v_application.business_name,'[^a-zA-Z0-9]+','-','g'));
  v_slug_base:=trim(both '-' from v_slug_base);
  if length(v_slug_base)<3 then
    v_slug_base:='business-'||left(v_application.public_reference::text,8);
  end if;
  v_slug_base:=left(v_slug_base,60);
  v_slug:=v_slug_base;
  while exists(select 1 from public.businesses where slug=v_slug) loop
    v_suffix:=v_suffix+1;
    v_slug:=left(v_slug_base,55)||'-'||v_suffix::text;
  end loop;

  update public.business_applications_v95
     set status='approved',version=version+1,decided_by=v_actor,
         decided_at=now(),decision_reason=v_reason,updated_at=now()
   where id=p_application
   returning * into v_application;
  insert into public.business_application_audit_v95(
    application_id,event_type,actor,prior_status,new_status,reason
  ) values(
    p_application,'approved',v_actor,'submitted','approved',v_reason
  );

  update public.business_application_invitations_v95 invitation
     set revoked_at=coalesce(invitation.revoked_at,now())
   where invitation.application_id=p_application
     and invitation.revoked_at is null
     and invitation.consumed_at is null;

  insert into public.businesses(name,slug,industry,enabled_modules)
  values(v_application.business_name,v_slug,v_application.sector_key,v_bundle.modules)
  returning * into v_business;
  insert into public.staff(business_id,user_id,role,full_name,active)
  values(v_business.id,v_owner,'owner',v_application.contact_name,true)
  returning id into v_staff;
  insert into public.branches(business_id,name,is_default,active)
  values(v_business.id,v_application.business_name,true,true)
  returning id into v_branch;
  insert into public.staff_branches(business_id,staff_id,branch_id)
  values(v_business.id,v_staff,v_branch);

  update public.business_workspace_controls_v94
     set approval_status='approved',version=version+1,
         decided_by=v_actor,decided_at=v_application.decided_at,
         decision_reason='direct super-admin application approval '||v_application.id,
         updated_at=now()
   where business_id=v_business.id;
  insert into public.business_workspace_control_audit_v94(
    business_id,actor,event_type,prior_status,new_status,reason,control_version
  ) values(
    v_business.id,v_actor,'application_activated','pending','approved',
    'direct super-admin application approval',2
  );
  /*
    V169 removed the loyalty_programs seed from here and V277 restored it, just below, under the owner identity (the app.activate_self_serve_paid_v130 shape). Do not remove it again: without it public.create_loyalty_config_draft raises base configuration not found and the tenant can never open Grow. The V169 note that followed is kept for history and its closing claim - that the owner could just build the programme in Grow - was wrong.

    It fired seed_loyalty_config_version(), whose version row trips
    app.c45_loyalty_program_version_write_guard. That guard requires
    app.c45_owner_loyalty_write(business) -> app.is_salon_owner(business) -> an ACTIVE owner
    staff row whose user_id = auth.uid(). During approval auth.uid() is the SUPER ADMIN, who by
    design is never tenant staff, so the guard raised 42501 and rolled back the ENTIRE approval.
    Result: no approval had ever succeeded (zero DIRECT_APPLICATION_APPROVED_ACTIVATED_V167 rows
    in audit_log as of 2026-08-05); approved owners were left with no workspace and no login.

    The seeded row was an INACTIVE 'draft' preset, so omitting it costs the owner nothing: they
    create their programme through Grow as the owner, where the guard legitimately passes. This
    keeps the guard's security property intact - no new super-admin write path into tenant
    loyalty configuration.
  */
  perform set_config('request.jwt.claim.sub',v_owner::text,true);
  perform set_config('request.jwt.claims',
    jsonb_build_object('sub',v_owner,'role','authenticated','aud','authenticated')::text,true);
  if app.c45_owner_loyalty_write(v_business.id) then
    insert into public.loyalty_programs(
      business_id,kind,earn_points_per_dollar,redeem_points,
      reward_credit_cents,active,loyalty_model,configuration_status,
      recommendation_source
    ) values(
      v_business.id,'points',1,800,2000,false,'classic','draft',
      'onboarding_preset'
    ) on conflict(business_id) do nothing;
  end if;
  -- nestly_v565: the insert above is guarded by app.c45_owner_loyalty_write, and when that guard
  -- says no it says nothing -- the workspace was created anyway, without its loyalty row, and the
  -- owner met 'base configuration not found' the first time they opened Grow. Two live tenants
  -- reached that state. The guard stays (it is what keeps the SUPER ADMIN out of tenant loyalty
  -- configuration under their own identity), but its refusal may no longer be silent: this
  -- context is already authorised to create the business itself, so the row is created through
  -- the definer helper and the fact is recorded. A tenant is never born without it again.
  if not exists(select 1 from public.loyalty_programs lp where lp.business_id=v_business.id) then
    perform app.ensure_loyalty_program_row(v_business.id,'onboarding_preset');
    insert into public.audit_log(
      business_id,actor,action,entity,entity_id,detail
    ) values(
      v_business.id,v_actor,'loyalty_core.seeded_v565','loyalty_programs',v_business.id,
      jsonb_build_object(
        'source','platform_decide_business_application_v105',
        'recommendation_source','onboarding_preset',
        'reason','the owner-guarded onboarding preset insert did not happen; every business is born with its loyalty row'
      )
    );
  end if;
  perform set_config('request.jwt.claim.sub',coalesce(v_v277_prior_sub,''),true);
  perform set_config('request.jwt.claims',coalesce(v_v277_prior_claims,''),true);
  insert into public.subscriptions(business_id) values(v_business.id)
  on conflict(business_id) do nothing;
  insert into public.business_sector_assignments(
    business_id,bundle_version_id,version,assigned_by
  ) values(v_business.id,v_bundle.id,1,v_actor);

  update public.business_applications_v95
     set status='consumed',version=version+1,consumed_business_id=v_business.id,
         consumed_by=v_owner,consumed_at=now(),updated_at=now()
   where id=v_application.id
   returning * into v_application;

  v_response:=jsonb_build_object(
    'application_id',v_application.id,'status','consumed',
    'business_id',v_business.id,'business_slug',v_business.slug,
    'owner_staff_id',v_staff,'default_branch_id',v_branch,
    'workspace_created',true,'workspace_access',true,
    'approved_email',v_application.contact_email,
    'replayed',false,'response_version',1
  );

  insert into public.business_application_audit_v95(
    application_id,event_type,actor,prior_status,new_status,reason,detail
  ) values(
    v_application.id,'invitation_consumed',v_owner,'approved','consumed',
    'super-admin approval activated existing owner account directly',
    jsonb_build_object('business_id',v_business.id,'approved_by',v_actor)
  );
  insert into public.audit_log(
    business_id,actor,action,entity,entity_id,detail
  ) values(
    v_business.id,v_actor,'DIRECT_APPLICATION_APPROVED_ACTIVATED_V167',
    'businesses',v_business.id,jsonb_build_object(
      'application_id',v_application.id,
      'owner_user_id',v_owner,
      'sector_bundle_version_id',v_bundle.id
    )
  );
  insert into public.platform_application_decision_receipts_v105(
    idempotency_key,application_id,actor,request_hash,decision,
    invitation_id,response_version
  ) values(
    p_idempotency_key,p_application,v_actor,v_request_hash,'approved',
    null,1
  ) returning * into v_receipt;

  return v_response;
end
$function$;
CREATE OR REPLACE FUNCTION public.platform_activate_approved_application_v169(p_application uuid, p_idempotency_key uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'app', 'pg_temp'
AS $function$
declare
  v_actor uuid:=auth.uid();
  v_v277_prior_sub text:=current_setting('request.jwt.claim.sub',true);
  v_v277_prior_claims text:=current_setting('request.jwt.claims',true);
  v_application public.business_applications_v95%rowtype;
  v_owner uuid;
  v_bundle public.sector_bundle_versions%rowtype;
  v_business public.businesses%rowtype;
  v_staff uuid;
  v_branch uuid;
  v_slug_base text;
  v_slug text;
  v_suffix integer:=0;
begin
  if not app.is_super_admin() then
    raise exception 'super_admin_required' using errcode='42501';
  end if;
  if p_application is null or p_idempotency_key is null then
    raise exception 'application and idempotency key are required' using errcode='22023';
  end if;

  perform pg_advisory_xact_lock(hashtextextended(p_idempotency_key::text,169));

  select * into v_application
    from public.business_applications_v95 application
   where application.id=p_application
   for update;
  if not found then
    raise exception 'application_not_found' using errcode='22023';
  end if;

  if v_application.status='consumed' then
    return jsonb_build_object(
      'application_id',v_application.id,'status','consumed',
      'business_id',v_application.consumed_business_id,
      'workspace_created',false,'workspace_access',true,'replayed',true
    );
  end if;
  if v_application.status<>'approved' then
    raise exception 'application_is_not_approved' using errcode='23514';
  end if;

  select user_row.id into v_owner
    from auth.users user_row
   where lower(user_row.email)=lower(v_application.contact_email)
     and coalesce(user_row.email_confirmed_at,user_row.confirmed_at) is not null
   order by user_row.created_at asc,user_row.id asc
   limit 1;
  if v_owner is null then
    raise exception 'owner_account_not_found_for_application' using errcode='42501';
  end if;
  if exists(select 1 from public.staff staff_row where staff_row.user_id=v_owner) then
    raise exception 'owner_account_already_has_workspace' using errcode='42501';
  end if;

  select * into v_bundle
    from public.sector_bundle_versions
   where sector_key=v_application.sector_key and status='published';
  if not found then
    raise exception 'published_sector_required' using errcode='23514';
  end if;

  v_slug_base:=lower(regexp_replace(v_application.business_name,'[^a-zA-Z0-9]+','-','g'));
  v_slug_base:=trim(both '-' from v_slug_base);
  if length(v_slug_base)<3 then
    v_slug_base:='business-'||left(v_application.public_reference::text,8);
  end if;
  v_slug_base:=left(v_slug_base,60);
  v_slug:=v_slug_base;
  while exists(select 1 from public.businesses where slug=v_slug) loop
    v_suffix:=v_suffix+1;
    v_slug:=left(v_slug_base,55)||'-'||v_suffix::text;
  end loop;

  update public.business_application_invitations_v95 invitation
     set revoked_at=coalesce(invitation.revoked_at,now())
   where invitation.application_id=p_application
     and invitation.revoked_at is null
     and invitation.consumed_at is null;

  insert into public.businesses(name,slug,industry,enabled_modules)
  values(v_application.business_name,v_slug,v_application.sector_key,v_bundle.modules)
  returning * into v_business;
  insert into public.staff(business_id,user_id,role,full_name,active)
  values(v_business.id,v_owner,'owner',v_application.contact_name,true)
  returning id into v_staff;
  insert into public.branches(business_id,name,is_default,active)
  values(v_business.id,v_application.business_name,true,true)
  returning id into v_branch;
  insert into public.staff_branches(business_id,staff_id,branch_id)
  values(v_business.id,v_staff,v_branch);

  update public.business_workspace_controls_v94
     set approval_status='approved',version=version+1,
         decided_by=coalesce(v_application.decided_by,v_actor),
         decided_at=coalesce(v_application.decided_at,now()),
         decision_reason='V169 activation of pre-V167 approved application '||v_application.id,
         updated_at=now()
   where business_id=v_business.id;
  insert into public.business_workspace_control_audit_v94(
    business_id,actor,event_type,prior_status,new_status,reason,control_version
  ) values(
    v_business.id,v_actor,'application_activated','pending','approved',
    'V169 activation of pre-V167 approved application',2
  );

  perform set_config('request.jwt.claim.sub',v_owner::text,true);
  perform set_config('request.jwt.claims',
    jsonb_build_object('sub',v_owner,'role','authenticated','aud','authenticated')::text,true);
  if app.c45_owner_loyalty_write(v_business.id) then
    insert into public.loyalty_programs(
      business_id,kind,earn_points_per_dollar,redeem_points,
      reward_credit_cents,active,loyalty_model,configuration_status,
      recommendation_source
    ) values(
      v_business.id,'points',1,800,2000,false,'classic','draft',
      'onboarding_preset'
    ) on conflict(business_id) do nothing;
  end if;
  -- nestly_v565: the insert above is guarded by app.c45_owner_loyalty_write, and when that guard
  -- says no it says nothing -- the workspace was created anyway, without its loyalty row, and the
  -- owner met 'base configuration not found' the first time they opened Grow. Two live tenants
  -- reached that state. The guard stays (it is what keeps the SUPER ADMIN out of tenant loyalty
  -- configuration under their own identity), but its refusal may no longer be silent: this
  -- context is already authorised to create the business itself, so the row is created through
  -- the definer helper and the fact is recorded. A tenant is never born without it again.
  if not exists(select 1 from public.loyalty_programs lp where lp.business_id=v_business.id) then
    perform app.ensure_loyalty_program_row(v_business.id,'onboarding_preset');
    insert into public.audit_log(
      business_id,actor,action,entity,entity_id,detail
    ) values(
      v_business.id,v_actor,'loyalty_core.seeded_v565','loyalty_programs',v_business.id,
      jsonb_build_object(
        'source','platform_activate_approved_application_v169',
        'recommendation_source','onboarding_preset',
        'reason','the owner-guarded onboarding preset insert did not happen; every business is born with its loyalty row'
      )
    );
  end if;
  perform set_config('request.jwt.claim.sub',coalesce(v_v277_prior_sub,''),true);
  perform set_config('request.jwt.claims',coalesce(v_v277_prior_claims,''),true);
  insert into public.subscriptions(business_id) values(v_business.id)
  on conflict(business_id) do nothing;
  insert into public.business_sector_assignments(
    business_id,bundle_version_id,version,assigned_by
  ) values(v_business.id,v_bundle.id,1,v_actor);

  update public.business_applications_v95
     set status='consumed',version=version+1,consumed_business_id=v_business.id,
         consumed_by=v_owner,consumed_at=now(),updated_at=now()
   where id=v_application.id
   returning * into v_application;

  insert into public.business_application_audit_v95(
    application_id,event_type,actor,prior_status,new_status,reason,detail
  ) values(
    v_application.id,'invitation_consumed',v_owner,'approved','consumed',
    'V169 activated an application approved before direct activation shipped',
    jsonb_build_object('business_id',v_business.id,'activated_by',v_actor)
  );
  insert into public.audit_log(
    business_id,actor,action,entity,entity_id,detail
  ) values(
    v_business.id,v_actor,'STRANDED_APPLICATION_ACTIVATED_V169',
    'businesses',v_business.id,jsonb_build_object(
      'application_id',v_application.id,
      'owner_user_id',v_owner,
      'sector_bundle_version_id',v_bundle.id,
      'originally_decided_at',v_application.decided_at
    )
  );

  return jsonb_build_object(
    'application_id',v_application.id,'status','consumed',
    'business_id',v_business.id,'business_slug',v_business.slug,
    'owner_staff_id',v_staff,'default_branch_id',v_branch,
    'workspace_created',true,'workspace_access',true,
    'approved_email',v_application.contact_email,'replayed',false
  );
end
$function$;

-- ============ TIERS ARE A LIVE PROGRAMME, AND REFERRAL NEEDS ITS REWARD ===================
CREATE OR REPLACE FUNCTION public.set_programmes_v314(p_business uuid, p_switches jsonb, p_idempotency_key uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'app', 'pg_temp'
AS $function$
declare
  v_actor uuid := auth.uid();
  v_hash text;
  v_rows integer;
  v_existing public.programme_switch_operations_v314%rowtype;
  v_kind text;
  v_want boolean;
  v_before boolean;
  v_changes jsonb := '[]'::jsonb;
  v_result jsonb;
  v_points boolean;
  v_stamps boolean;
  v_tiers boolean; -- nestly_v565
  v_points_before boolean;
  v_stamps_before boolean;
  v_from uuid;
  v_to uuid;
  v_migration uuid;
  v_after_points boolean;
  v_after_tiers boolean;
  v_after_stamps boolean;
  v_model text;
  v_program_kind text;
  v_referral_want boolean;
  v_ref_unpayable boolean;
begin
  perform app.acquire_loyalty_exclusive_v480(p_business);
  if p_business is null or p_idempotency_key is null then
    raise exception 'business and idempotency key are required' using errcode = '22023';
  end if;
  if p_switches is null or jsonb_typeof(p_switches) <> 'object' then
    raise exception 'switches must be a JSON object' using errcode = '22023';
  end if;
  if jsonb_typeof(p_switches) = 'object' and exists (
    select 1 from jsonb_object_keys(p_switches) key
     where key not in ('points','tiers','stamps','referral')
  ) then
    raise exception 'switches may only name points, tiers, stamps or referral'
      using errcode = '22023';
  end if;
  if exists (
    select 1 from jsonb_each(p_switches) entry
     where jsonb_typeof(entry.value) <> 'boolean'
  ) then
    raise exception 'every switch must be true or false' using errcode = '22023';
  end if;
  if p_switches = '{}'::jsonb then
    raise exception 'at least one switch is required' using errcode = '22023';
  end if;

  if not app.c45_owner_loyalty_write(p_business) then
    raise exception 'owner loyalty configuration access required' using errcode = '42501';
  end if;

  v_hash := md5(p_business::text || ':' || (
    select coalesce(string_agg(key || '=' || (p_switches ->> key), ',' order by key), '')
      from jsonb_object_keys(p_switches) key
  ));

  insert into public.programme_switch_operations_v314
    (business_id, idempotency_key, actor, request_hash)
  values (p_business, p_idempotency_key, v_actor, v_hash)
  on conflict (business_id, idempotency_key) do nothing;
  get diagnostics v_rows = row_count;
  if v_rows = 0 then
    select * into strict v_existing from public.programme_switch_operations_v314
     where business_id = p_business and idempotency_key = p_idempotency_key
       for update;
    if v_existing.request_hash is distinct from v_hash then
      raise exception 'idempotency key conflicts with another programme switch'
        using errcode = '23505';
    end if;
    if v_existing.result is not null then
      return v_existing.result;
    end if;
    raise exception 'programme switch already in progress' using errcode = '55P03';
  end if;

  perform 1 from public.businesses target where target.id = p_business for update;
  if not found then
    raise exception 'business does not exist' using errcode = '42501';
  end if;

  select coalesce(bool_or(spine.active) filter (where spine.kind = 'points'), false),
         coalesce(bool_or(spine.active) filter (where spine.kind = 'stamps'), false)
    into v_points_before, v_stamps_before
    from public.business_programmes spine
   where spine.business_id = p_business;

  insert into public.business_programmes (business_id, kind, active, sort, activated_at)
  select p_business, model.kind, model.running,
         (case model.kind
            when 'points' then 1 when 'tiers' then 2 when 'stamps' then 3 when 'referral' then 4
          end)::smallint,
         case when model.running then now() end
    from app.business_programmes_v307(p_business) model
  on conflict (business_id, kind) do nothing;

  select coalesce((p_switches ->> 'points')::boolean,
                  bool_or(spine.active) filter (where spine.kind = 'points'), false),
         coalesce((p_switches ->> 'tiers')::boolean,
                  bool_or(spine.active) filter (where spine.kind = 'tiers'), false),
         coalesce((p_switches ->> 'stamps')::boolean,
                  bool_or(spine.active) filter (where spine.kind = 'stamps'), false)
    into v_after_points, v_after_tiers, v_after_stamps
    from public.business_programmes spine
   where spine.business_id = p_business;

  if v_after_stamps and (v_after_points or v_after_tiers) then
    raise exception 'The stamp card runs on its own. Turn Points & gifts and Tier membership off '
      'before turning the stamp card on, or turn the stamp card off to run points and tiers.'
      using errcode = '22023';
  end if;

  -- nestly_v565: v425 (a) below deliberately refuses to INVENT a referral configuration, and it is
  -- right not to -- but the switch was still allowed to go on with no public.referral_programs row
  -- behind it. The owner then read "Referral: On" while app.on_sale_recorded found no enabled
  -- programme and paid nobody: live to the business, silent to every friend who was referred.
  -- Turning referral ON now requires the reward to exist first. Turning it OFF with no row stays
  -- the no-op it always was -- there is nothing to switch off.
  if coalesce((p_switches ->> 'referral')::boolean, false)
     and not exists (select 1 from public.referral_programs rp where rp.business_id = p_business) then
    raise exception 'referral_needs_configuration: save the referral reward first — a referral switched on with no reward would look live and pay nothing'
      using errcode = '22023';
  end if;

  for v_kind, v_want in
    select entry.key, (entry.value)::boolean
      from jsonb_each_text(p_switches) entry
     order by case entry.key
                when 'points' then 1 when 'tiers' then 2 when 'stamps' then 3 else 4 end
  loop
    select spine.active into v_before
      from public.business_programmes spine
     where spine.business_id = p_business and spine.kind = v_kind
       for update;
    if not found then
      raise exception 'business % has no % programme row', p_business, v_kind
        using errcode = 'XX001';
    end if;
    if v_before is distinct from v_want then
      update public.business_programmes spine
         set active = v_want,
             activated_at = case when v_want and not spine.active then now()
                                 else spine.activated_at end,
             deactivated_at = case when spine.active and not v_want then now()
                                   else spine.deactivated_at end
       where spine.business_id = p_business and spine.kind = v_kind;
      v_changes := v_changes || jsonb_build_object('kind', v_kind, 'from', v_before, 'to', v_want);
      insert into public.audit_log (business_id, actor, action, entity, entity_id, detail)
      select p_business, v_actor, 'PROGRAMME_SWITCH_V314', 'business_programmes', spine.id,
             jsonb_build_object('kind', v_kind, 'from', v_before, 'to', v_want,
                                'source', 'set_programmes_v314')
        from public.business_programmes spine
       where spine.business_id = p_business and spine.kind = v_kind;
    end if;
  end loop;

  -- v425 (a): the referral spine and referral_programs.enabled are ONE decision, so they move
  -- together or the engine and the switch disagree. Only an existing row is synced: this is not
  -- the place to invent a referral configuration a firm has never filled in -- with no row,
  -- app.on_sale_recorded finds no enabled programme and pays nothing, which is what an
  -- unconfigured referral should do.
  v_referral_want := (p_switches ->> 'referral')::boolean;
  if v_referral_want is not null then
    update public.referral_programs rp
       set enabled = v_referral_want
     where rp.business_id = p_business
       and rp.enabled is distinct from v_referral_want;
    if found then
      insert into public.audit_log(business_id, actor, action, entity, entity_id, detail)
      select p_business, v_actor, 'referral_enabled.synced_to_spine', 'referral_programs', rp.id,
             jsonb_build_object('enabled', v_referral_want, 'source', 'set_programmes_v314')
        from public.referral_programs rp where rp.business_id = p_business;
    end if;
  end if;

  select coalesce(bool_or(spine.active) filter (where spine.kind = 'points'), false),
         coalesce(bool_or(spine.active) filter (where spine.kind = 'stamps'), false),
         coalesce(bool_or(spine.active) filter (where spine.kind = 'tiers'), false)
    into v_points, v_stamps, v_tiers
    from public.business_programmes spine
   where spine.business_id = p_business;

  -- V355: THE POT MIGRATION IS GONE FROM THIS PATH, DELIBERATELY.
  -- Owner ruling 2026-08-16: "i just want to ensure that the points doesn't flow to become
  -- stamps, if points is off - it will be switch off and show no. of stamps. not conveniently
  -- convert all the points into stamps." V312 used to move every client's balance from the
  -- outgoing programme's pot into the incoming one on a points<->stamps switch, so a firm that
  -- toggled the stamp card on saw 75,877 POINTS reappear as 75,877 STAMPS -- a unit the customer
  -- never earned. Cubbly's own trail shows it firing four times in ninety seconds of toggling.
  -- points_ledger.programme_id already keeps the two pots apart; leaving them apart IS the fix.
  -- A programme that is switched off now simply parks its pot untouched, and the customer sees
  -- only the live programme's own balance, which is what "turned off" should mean. The machinery
  -- (programme_pot_migrations, app.migrate_programme_pot_v312, run_programme_pot_migrations_v312)
  -- is intentionally left in place and callable for a deliberate, super-admin-initiated move --
  -- it is only no longer fired automatically by an owner flipping a switch.
  -- V354: the spine has just moved, so the declared model follows it, in this same transaction.
  -- Without this the two disagree the moment an owner switches back (the live defect above).
  -- nestly_v514: the customer surfaces gate on loyalty_programs.active while this switch moves
  -- the spine, so the two must move together or the business reads On while the customer reads
  -- nothing. (v_points or v_stamps) is the same expression app.c45_base_actionable_wallet_card
  -- computes as engine.running, so the two conditions are now one fact.
  -- nestly_v565: tiers join the formula. v514 wrote `active = (v_points or v_stamps)`, so a
  -- business running Tier membership ALONE synced its loyalty row to active=false and every
  -- customer surface that gates on loyalty_programs.active showed nothing -- the business read
  -- "Tiers: On" and the customer read a dead wallet. Tier membership is a live loyalty programme;
  -- it counts.
  update public.loyalty_programs
     set active = (v_points or v_stamps or v_tiers)
   where business_id = p_business
     and active is distinct from (v_points or v_stamps or v_tiers);
  if found then
    insert into public.audit_log(business_id, actor, action, entity, entity_id, detail)
    values (p_business, v_actor, 'loyalty_active.synced_to_spine', 'loyalty_programs', p_business,
      jsonb_build_object('active', (v_points or v_stamps or v_tiers), 'source', 'set_programmes_v314'));
  end if;
  v_model := case when v_stamps then 'stamps' else 'classic' end;
  v_program_kind := case when v_stamps then 'stamps' else 'points' end;
  update public.loyalty_programs
     set loyalty_model = v_model, kind = v_program_kind
   where business_id = p_business
     and (loyalty_model is distinct from v_model or kind is distinct from v_program_kind);
  if found then
    insert into public.audit_log(business_id, actor, action, entity, entity_id, detail)
    values (p_business, v_actor, 'loyalty_model.synced_to_spine', 'loyalty_programs', p_business,
      jsonb_build_object('loyalty_model', v_model, 'kind', v_program_kind,
                         'source', 'set_programmes_v314'));
  end if;

  -- v425 (b): computed AFTER the spine has moved, so it describes the world the owner has just
  -- created. TRUE means "the referral programme is on, its reward is points or stamps, and that
  -- pot is not running" -- exactly the state app.on_sale_recorded will now refuse to pay.
  select coalesce(rp.enabled, false)
     and lower(btrim(coalesce(rp.reward_kind,'points'))) in ('points','stamps')
     and app.referral_payout_programme_v425(p_business, rp.reward_kind) is null
    into v_ref_unpayable
    from public.referral_programs rp
   where rp.business_id = p_business;
  v_ref_unpayable := coalesce(v_ref_unpayable, false);

  v_result := jsonb_build_object(
    'business_id', p_business,
    'changed', v_changes,
    'pot_migration_id', v_migration,
    'referral_reward_kind_now_unpayable', v_ref_unpayable,
    'programmes', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', spine.id,
               'kind', spine.kind,
               'active', spine.active,
               'running_since', spine.activated_at,
               'paused_since', spine.deactivated_at) order by spine.sort)
        from public.business_programmes spine
       where spine.business_id = p_business), '[]'::jsonb));

  update public.programme_switch_operations_v314
     set result = v_result
   where business_id = p_business and idempotency_key = p_idempotency_key;

  return v_result;
end
$function$;

-- CREATE OR REPLACE preserves grants; restated per governance, verbatim from the live proacl
-- ('{postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}' for all seven).
revoke all on function public.business_set_loyalty_model_v353(uuid,text) from public, anon;
grant execute on function public.business_set_loyalty_model_v353(uuid,text) to authenticated, service_role;
revoke all on function public.business_set_earning_rule_v359(uuid,numeric,integer,text,integer,integer,integer) from public, anon;
grant execute on function public.business_set_earning_rule_v359(uuid,numeric,integer,text,integer,integer,integer) to authenticated, service_role;
revoke all on function public.business_set_tier_basis_v347(uuid,text) from public, anon;
grant execute on function public.business_set_tier_basis_v347(uuid,text) to authenticated, service_role;
revoke all on function public.create_loyalty_config_draft(uuid,uuid,text) from public, anon;
grant execute on function public.create_loyalty_config_draft(uuid,uuid,text) to authenticated, service_role;
revoke all on function public.platform_decide_business_application_v105(uuid,text,text,bigint,uuid) from public, anon;
grant execute on function public.platform_decide_business_application_v105(uuid,text,text,bigint,uuid) to authenticated, service_role;
revoke all on function public.platform_activate_approved_application_v169(uuid,uuid) from public, anon;
grant execute on function public.platform_activate_approved_application_v169(uuid,uuid) to authenticated, service_role;
revoke all on function public.set_programmes_v314(uuid,jsonb,uuid) from public, anon;
grant execute on function public.set_programmes_v314(uuid,jsonb,uuid) to authenticated, service_role;

-- ============ BACKFILL: the tenants already born without their loyalty row ===================
-- Two live tenants today. Each gets the same preset every other business was born with, plus the
-- version 1 the seed trigger publishes in this same transaction, plus an audit row naming why.
-- Idempotent: a second run finds no business missing the row, so the loop body never executes and
-- no duplicate audit rows are written.
do $backfill$
declare r record; v_seeded integer := 0;
begin
  for r in
    select b.id as business_id, b.name
      from public.businesses b
      left join public.loyalty_programs lp on lp.business_id=b.id
     where lp.business_id is null
     order by b.created_at
  loop
    perform app.ensure_loyalty_program_row(r.business_id, 'v565_backfill');
    insert into public.audit_log(business_id, actor, action, entity, entity_id, detail)
    values (r.business_id, null, 'loyalty_core.seeded_v565', 'loyalty_programs', r.business_id,
            jsonb_build_object(
              'source','nestly_v565_backfill',
              'recommendation_source','v565_backfill',
              'reason','the business was created with no loyalty_programs row, so it had no config version 1 and public.create_loyalty_config_draft raised base configuration not found -- the tenant could never open Grow'));
    v_seeded := v_seeded + 1;
  end loop;
  raise notice 'v565 backfill: % business(es) given their loyalty row', v_seeded;
end
$backfill$;

-- The invariant this migration exists to establish, asserted before it commits.
do $invariant$
declare v_bad integer;
begin
  select count(*) into v_bad
    from public.businesses b
    left join public.loyalty_programs lp on lp.business_id=b.id
   where lp.business_id is null;
  if v_bad > 0 then
    raise exception 'v565: % business(es) still have no loyalty_programs row', v_bad;
  end if;
end
$invariant$;

commit;
