-- Nestly v332 — Lifestyle bring-back rules get a real delete -> History state
--
-- Owner ruling ("proceed all at once", 2026-08-15): Lifestyle bring-back rules (public.
-- retention_programs, the "Lifestyle" / bring-back promotions surface) is the fourth and last of
-- the four Growth lifecycle pages (points gifts v326, tiers v331, memberships v329) to get a real
-- soft-delete instead of "pause only". retention_programs.active already IS the existing pause/
-- resume flag (wired through save_retention_program_draft), so this migration follows the same
-- shape as v326/v329/v331: add deleted_at, add an immediate-write delete RPC, and patch every
-- reader that needs to stop treating a deleted rule as live.
--
-- Pre-migration audit found a landmine that is DIFFERENT from, and materially harder than, either
-- v329's plan-history case or v331's tier case:
--
--   retention_program_versions carries its own trigger, trg_guard_retention_program_version
--   (app.guard_retention_program_version), that blocks INSERT *and* UPDATE *and* DELETE the
--   moment the row's config_version_id points at a firm_config_versions row whose status is not
--   'draft'. This is stricter than loyalty_tier_versions' own trg_loyalty_tier_versions_immutable,
--   which v331's header explicitly notes "only blocks UPDATE/DELETE" (INSERT into a published
--   version is allowed there). For retention, an already-published snapshot row's `active` flag
--   can NEVER be forced false directly, by any writer, including this migration's own delete RPC
--   running SECURITY DEFINER -- the trigger fires regardless of role.
--
--   app.on_sale_recorded() (the trigger that actually grants retention reward_grants on every
--   qualifying sale) reads ONLY public.retention_program_versions at new.config_version_id (the
--   sale's business's currently PUBLISHED snapshot) -- never public.retention_programs. Because
--   that published snapshot row is immutable, a delete that only sets retention_programs.deleted_at
--   would NOT stop new reward grants: on_sale_recorded would keep reading the frozen active=true
--   row until the business's next full config publish. The fix here is therefore NOT "patch the
--   published version row" (impossible) but "patch on_sale_recorded to also require the LIVE
--   retention_programs.deleted_at is null" -- the live table is mutable, the frozen snapshot is
--   the historical record of what was true at that publish, and on_sale_recorded now consults
--   both. The identical reasoning applies to public.issue_campaign_offer, the other place that
--   inserts a NEW reward_grants row (for an already-active retention campaign) by resolving the
--   same frozen published retention_program_versions row.
--
--   The resurrection risk this creates is therefore NOT "one pre-existing open draft could
--   resurrect the delete" (v326's risk) or "every future publish forgets the flag" (v331's risk,
--   solved with a capture/restore because tiers are wiped by a delete+reinsert on every publish).
--   Retention's own publish mechanism (public.publish_loyalty_config) does an UPDATE of the live
--   retention_programs row FROM whatever the publishing draft's own retention_program_versions row
--   says -- including `active`. Because that source row can carry a stale `active=true` (cloned
--   from the frozen published snapshot before the delete, or left stale in an already-open draft),
--   publish_loyalty_config is patched to compute `active = rv.active and rp.deleted_at is null` --
--   a permanent, publish-time force that durably protects a deleted program against EVERY future
--   publish, of every draft, forever, the same "table-snapshot carry-over, not tied to any specific
--   draft" philosophy v331 used for tiers, but simpler here because retention_programs.deleted_at
--   itself is never one of the columns publish_loyalty_config's UPDATE touches, so it is naturally
--   immune to being reset by any publish, present or future.
--
-- What this migration does:
--   1. retention_programs gets `deleted_at timestamptz`. `active` is untouched in meaning (still
--      the pre-existing pause/resume flag) but a delete now sets both together, matching v329's and
--      v331's exact precedent shape (business_delete_membership_plan_v329, business_delete_tier_v331).
--   2. app.on_sale_recorded() and public.issue_campaign_offer are patched to additionally require
--      the live retention_programs row's deleted_at is null before granting a NEW reward -- this is
--      the actual "stop it immediately" mechanism (see above; touching retention_program_versions
--      directly is not possible once it is published).
--   3. public.publish_loyalty_config's retention sync is patched so a publish can never resurrect a
--      deleted program's `active` flag, regardless of which draft published it or when that draft
--      was created -- the durable resurrection guard.
--   4. app.clone_retention_program_versions_on_draft() (the "clone from the based-on version" draft
--      trigger) is patched to skip a deleted program entirely, so a deleted rule never even appears
--      as an editable row in any FUTURE draft (belt-and-suspenders alongside #3; keeps the draft
--      editor's own listing consistent with History state).
--   5. Every other live reader of retention_programs / retention_program_versions is patched or
--      deliberately left alone -- see the per-function comments below for the reasoning in each
--      case. The full audit trail (which functions were patched and why, which were not and why
--      not) is reproduced in this session's report; the short version is: anything that could
--      create a NEW customer-facing promise (a wallet-card "you're 1 visit away" prompt, a brand
--      new campaign, retiring the reward taxonomy a still-referenced deleted program used to use,
--      materializing or resaving a deleted program's row inside a draft) is patched; anything that
--      only ever reports on ALREADY-GRANTED rewards, ALREADY-POSTED credit, or ALREADY-EXISTING
--      campaigns (reward_grants, credit_ledger, retention_campaigns, staff_get_reward_entitlements_v99,
--      business_programme_usage_v271, list_retention_campaigns) is left untouched, matching the
--      house rule that a delete must never rewrite history.
--   6. A new immediate-write RPC business_delete_retention_program_v332(p_business,p_program) --
--      same authorization as public.save_retention_program_draft (app.is_salon_owner, the actual
--      gate that function uses today; NOT app.can_module_write, which is what a naive reading of
--      the v329/v331 precedents alone would have suggested -- retention drafting has never been
--      module-write-gated).

begin;

alter table public.retention_programs add column if not exists deleted_at timestamptz;
comment on column public.retention_programs.deleted_at is
  'v332: set once, by business_delete_retention_program_v332, when an owner deletes a Lifestyle '
  'bring-back rule from the Growth page. NULL = not deleted. Deleting also sets active=false, the '
  'same pre-existing pause/resume flag save_retention_program_draft''s UI toggle already used. '
  'Because retention_program_versions rows on an already-published config version are immutable '
  '(trg_guard_retention_program_version), this column -- not that frozen snapshot -- is what '
  'app.on_sale_recorded / public.issue_campaign_offer check to stop granting new rewards '
  'immediately, and what public.publish_loyalty_config checks to keep a deleted rule dead across '
  'every future publish.';

-- 2a. app.on_sale_recorded -- the sale trigger that actually grants retention reward_grants. Full
-- body verbatim; the only change is the retention loop's source query, which now joins the LIVE
-- retention_programs row and requires deleted_at is null (see migration header for why this,
-- rather than touching retention_program_versions, is the only place this can be enforced).
CREATE OR REPLACE FUNCTION app.on_sale_recorded()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'app', 'pg_temp'
AS $function$
declare lp record; rp record; refrow record; refprog record; v_tier public.loyalty_tiers%rowtype;
  v_refcfg record; v_ref_prog uuid; v_ref_points integer;
  v_pts integer; v_idx integer; v_count integer; v_earn_id uuid; v_credit_id uuid;
  w_start timestamptz; w_end timestamptz;
  v_prog record; v_rows integer; v_expires timestamptz; v_earn_rows integer; v_batch_rows integer;
begin
  if new.reversal_of is not null or new.client_id is null or not(new.earns_points or new.counts_as_visit) then return new; end if;
  if new.earns_points
     and exists(
       select 1
       from app.effective_platform_module_mode_v94(
         new.business_id,new.branch_id,'loyalty'
       ) effective
       where effective.mode='rw'
     ) then
    select * into lp from app.resolve_loyalty_branch_config(new.business_id,new.branch_id,new.config_version_id);
    if found then
      for v_prog in
        select spine.id, spine.kind
          from public.business_programmes spine
         where spine.business_id=new.business_id
           and spine.active
           and spine.kind in ('points','stamps')
         order by spine.sort
      loop
        v_earn_id:=gen_random_uuid(); v_rows:=0; v_pts:=0; v_expires:=null;
        if v_prog.kind='stamps' then
          v_pts:=case when coalesce(lp.stamp_per_cents,0)>0 then floor(new.amount_cents::numeric/lp.stamp_per_cents) else 0 end;
        elsif v_prog.kind='points' then
          v_pts:=case when coalesce(lp.earn_points_per_dollar,0)>0 then floor((new.amount_cents/100.0)*lp.earn_points_per_dollar) else 0 end;
          select * into v_tier from app.loyalty_tier_for(new.business_id,new.client_id);
          if v_tier.id is not null and v_tier.points_multiplier>1 then v_pts:=floor(v_pts*v_tier.points_multiplier); end if;
          v_expires:=case when lp.expiry_mode='fixed' then now()+make_interval(days=>lp.expiry_days) end;
        else
          v_pts:=0;
        end if;
        if v_pts>0 then
          perform set_config('app.points_ledger_insert_id',v_earn_id::text,true); perform set_config('app.points_ledger_write_scope','sale_trigger',true);
          insert into public.points_ledger(id,business_id,client_id,entry_type,points,sale_id,reference,actor,programme_id)
          values(v_earn_id,new.business_id,new.client_id,'earn',v_pts,new.id,'auto-earn on sale',auth.uid(),v_prog.id)
          on conflict (sale_id,programme_id) where entry_type='earn' and sale_id is not null do nothing;
          get diagnostics v_rows=row_count;
          perform set_config('app.points_ledger_insert_id','',true); perform set_config('app.points_ledger_write_scope','',true);
          if v_rows=1 then
            insert into public.points_batches(business_id,client_id,earned,remaining,sale_id,earned_at,expires_at,programme_id)
            values(new.business_id,new.client_id,v_pts,v_pts,new.id,now(),v_expires,v_prog.id);
          end if;
        end if;
      end loop;
      select count(*) into v_earn_rows from public.points_ledger l where l.sale_id=new.id and l.entry_type='earn';
      select count(*) into v_batch_rows from public.points_batches b where b.sale_id=new.id;
      if v_earn_rows<>v_batch_rows then
        raise exception 'earn loop left ledger/batch parity broken for sale %',new.id using errcode='XX001';
      end if;
    end if;
  end if;
  if new.counts_as_visit then
    -- v332: only loop over a retention program version whose LIVE retention_programs row is not
    -- deleted. retention_program_versions.active alone is not enough once the row belongs to an
    -- already-published config version, because that row is frozen (trg_guard_retention_program_
    -- version blocks any UPDATE the moment its config_version_id is not a draft) -- so a delete can
    -- only ever be observed here through the live table, not the snapshot.
    for rp in select rpv.* from public.retention_program_versions rpv
      join public.retention_programs prog
        on prog.id=rpv.program_id and prog.business_id=rpv.business_id
       where rpv.business_id=new.business_id and rpv.config_version_id=new.config_version_id
         and rpv.active and prog.deleted_at is null
    loop
      v_idx:=floor(extract(epoch from(new.occurred_at-rp.starts_on::timestamptz))/(rp.period_days*86400));
      if v_idx>=0 then
        w_start:=rp.starts_on::timestamptz+make_interval(days=>v_idx*rp.period_days); w_end:=w_start+make_interval(days=>rp.period_days);
        select count(*) into v_count from public.sales s where s.business_id=new.business_id and s.client_id=new.client_id and s.counts_as_visit and s.reversal_of is null and not exists(select 1 from public.sales r where r.business_id=s.business_id and r.reversal_of=s.id) and s.occurred_at>=w_start and s.occurred_at<w_end;
        if v_count>=rp.goal_visits then
          begin
            insert into public.reward_grants(business_id,program_id,client_id,period_index,reward_type,reward_value,reward_item,config_version_id,retention_program_version_id)
            values(new.business_id,rp.program_id,new.client_id,v_idx,rp.fulfillment_kind,coalesce(rp.discount_percent,rp.credit_cents,0),rp.manual_item,new.config_version_id,rp.id);
            if rp.fulfillment_kind='credit' and rp.credit_cents>0 then
              v_credit_id:=gen_random_uuid(); perform set_config('app.credit_ledger_insert_id',v_credit_id::text,true); perform set_config('app.credit_ledger_write_scope','sale_trigger',true);
              insert into public.credit_ledger(id,business_id,client_id,entry_type,amount_cents,reference,sale_id,actor) values(v_credit_id,new.business_id,new.client_id,'loyalty_earn',rp.credit_cents,'retention reward: '||rp.name,new.id,auth.uid());
              perform set_config('app.credit_ledger_insert_id','',true); perform set_config('app.credit_ledger_write_scope','',true);
            end if;
          exception when unique_violation then null; end;
        end if;
      end if;
    end loop;
    select r.* into refrow from public.referrals r where r.business_id=new.business_id and r.referred_client_id=new.client_id and r.status='pending' limit 1;
    if found then
      select * into refprog from public.referral_programs where business_id=new.business_id and enabled limit 1;
      if found and new.amount_cents>=coalesce(refprog.min_spend_cents,0) then
        v_ref_prog:=case when refprog.reward_kind='points' then app.referral_payout_programme_v322(new.business_id) end;
        v_ref_points:=coalesce(refprog.reward_points,0);
        if v_ref_prog is not null and v_ref_points>0 then
          update public.referrals set status='rewarded',qualified_at=now(),qualified_sale_id=new.id,reward_points=v_ref_points where id=refrow.id and status='pending';
          if found then
            v_expires:=null;
            select * into v_refcfg from app.resolve_loyalty_branch_config(new.business_id,new.branch_id,new.config_version_id);
            if found and v_refcfg.expiry_mode='fixed' then v_expires:=now()+make_interval(days=>v_refcfg.expiry_days); end if;
            v_earn_id:=gen_random_uuid();
            perform set_config('app.points_ledger_insert_id',v_earn_id::text,true); perform set_config('app.points_ledger_write_scope','referral_reward_points',true);
            insert into public.points_ledger(id,business_id,client_id,entry_type,points,sale_id,reference,actor,programme_id)
            values(v_earn_id,new.business_id,refrow.referrer_client_id,'earn',v_ref_points,null,'referral qualified: first visit completed',auth.uid(),v_ref_prog);
            perform set_config('app.points_ledger_insert_id','',true); perform set_config('app.points_ledger_write_scope','',true);
            insert into public.points_batches(business_id,client_id,earned,remaining,sale_id,earned_at,expires_at,programme_id)
            values(new.business_id,refrow.referrer_client_id,v_ref_points,v_ref_points,null,now(),v_expires,v_ref_prog);
            perform app.emit_referral_qualified_v322(new.business_id,refrow.id,refrow.referrer_client_id,new.client_id,v_ref_points,v_earn_id,now(),new.config_version_id);
          end if;
        end if;
      end if;
    end if;
  end if;
  return new;
end
$function$;
revoke all privileges on function app.on_sale_recorded() from public, anon, authenticated;

-- 2b. public.issue_campaign_offer -- the only OTHER place that inserts a NEW reward_grants row for
-- a retention program (a campaign-issued offer under an already-active campaign). Same immutable-
-- snapshot reasoning as on_sale_recorded: the published retention_program_versions row this
-- resolves is frozen, so the live retention_programs.deleted_at is joined in directly. Full body
-- verbatim, one added join.
CREATE OR REPLACE FUNCTION public.issue_campaign_offer(p_business uuid, p_campaign uuid, p_client uuid, p_idempotency_key text, p_offer_cost_cents bigint DEFAULT NULL::bigint, p_reward_grant_id uuid DEFAULT NULL::uuid)
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'app', 'pg_temp'
AS $function$
declare
  v_actor uuid:=auth.uid();
  v_campaign public.retention_campaigns%rowtype;
  v_rule public.retention_program_versions%rowtype;
  v_existing public.retention_campaign_grants%rowtype;
  v_existing_entitlement public.reward_grants%rowtype;
  v_existing_exposure public.retention_campaign_exposures_v99%rowtype;
  v_key text:=btrim(coalesce(p_idempotency_key,''));
  v_offer_cost bigint;
  v_issued_cost bigint;
  v_hash text;
  v_campaign_grant uuid:=gen_random_uuid();
  v_entitlement uuid;
  v_repaired boolean:=false;
  v_has_existing boolean:=false;
begin
  if v_actor is null
     or not app.is_salon_owner(p_business)
     or not app.can_module_write(p_business,'retention') then
    raise exception 'active owner retention write authorization is required'
      using errcode='42501';
  end if;
  if char_length(v_key) not between 8 and 200 then
    raise exception 'idempotency key must contain 8..200 characters'
      using errcode='22023';
  end if;
  if p_reward_grant_id is not null then
    raise exception
      'campaign reward entitlement is server-issued; reward grant input must be null'
      using errcode='22023';
  end if;
  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(
      'v99:issue:'||p_business::text||':'||v_key,0
    )
  );
  select campaign.* into v_campaign
  from public.retention_campaigns campaign
  where campaign.id=p_campaign
    and campaign.business_id=p_business
  for update;
  if not found then
    raise exception 'campaign not found in this business'
      using errcode='22023';
  end if;
  if v_campaign.status<>'active' then
    raise exception 'offers require an active campaign'
      using errcode='object_not_in_prerequisite_state';
  end if;
  if not exists(
    select 1
    from public.retention_campaign_members member
    where member.campaign_id=p_campaign
      and member.business_id=p_business
      and member.client_id=p_client
      and member.assignment='treatment'
  ) then
    raise exception 'only a treatment member can receive the campaign reward'
      using errcode='42501';
  end if;
  -- v332: also require the live retention_programs row this campaign targets to still be
  -- undeleted. The rule.active check below only tests the frozen PUBLISHED snapshot, which
  -- cannot be forced false once published -- see migration header.
  select rule.* into v_rule
  from public.retention_program_versions rule
  join public.firm_config_versions config
    on config.id=rule.config_version_id
   and config.business_id=rule.business_id
   and config.status='published'
  join public.businesses business
    on business.id=rule.business_id
   and business.active_config_version_id=config.id
  join public.retention_programs prog
    on prog.id=rule.program_id
   and prog.business_id=rule.business_id
   and prog.deleted_at is null
  where rule.id=v_campaign.retention_program_version_id
    and rule.program_id=v_campaign.program_id
    and rule.business_id=p_business
    and rule.config_version_id=v_campaign.config_version_id
    and rule.active;
  if not found then
    raise exception
      'campaign reward is no longer an active published entitlement'
      using errcode='object_not_in_prerequisite_state';
  end if;
  if v_rule.fulfillment_kind='credit' then
    v_offer_cost:=v_rule.credit_cents::bigint;
    if p_offer_cost_cents is not null
       and p_offer_cost_cents<>v_offer_cost then
      raise exception
        'credit campaign cost must equal the published credit entitlement'
        using errcode='22023';
    end if;
  else
    v_offer_cost:=coalesce(p_offer_cost_cents,0);
  end if;
  if v_offer_cost<0 then
    raise exception 'offer cost cannot be negative' using errcode='22023';
  end if;

  v_hash:=pg_catalog.encode(
    extensions.digest(
      pg_catalog.convert_to(
        pg_catalog.concat_ws(
          '|','v99.campaign-entitlement',p_business::text,
          p_campaign::text,p_client::text,v_rule.id::text,
          v_rule.config_version_id::text,v_rule.fulfillment_kind,
          coalesce(v_rule.discount_percent::text,''),
          coalesce(v_rule.credit_cents::text,''),
          coalesce(v_rule.manual_item,''),v_offer_cost::text
        ),
        'UTF8'
      ),
      'sha256'
    ),
    'hex'
  );

  select campaign_grant.* into v_existing
  from public.retention_campaign_grants campaign_grant
  where campaign_grant.business_id=p_business
    and campaign_grant.idempotency_key=v_key;
  if found and (
    v_existing.campaign_id<>p_campaign
    or v_existing.client_id<>p_client
  ) then
    raise exception
      'idempotency key conflicts with another campaign entitlement'
      using errcode='23505';
  end if;
  if not found then
    select campaign_grant.* into v_existing
    from public.retention_campaign_grants campaign_grant
    where campaign_grant.campaign_id=p_campaign
      and campaign_grant.client_id=p_client;
  end if;
  v_has_existing:=found;
  if v_has_existing and v_existing.request_hash is not null
     and v_existing.request_hash<>v_hash then
    raise exception
      'campaign member already has different entitlement terms'
      using errcode='23505';
  end if;
  if v_has_existing and v_existing.offer_cost_cents<>v_offer_cost then
    raise exception
      'legacy campaign offer cost differs from the published entitlement'
      using errcode='23505';
  end if;
  if v_has_existing and v_existing.reward_grant_id is not null then
    select reward.* into v_existing_entitlement
    from public.reward_grants reward
    where reward.id=v_existing.reward_grant_id
      and reward.business_id=p_business
      and reward.client_id=p_client
      and reward.campaign_id=p_campaign
      and reward.campaign_assignment='treatment'
      and reward.retention_program_version_id=v_rule.id
      and reward.config_version_id=v_rule.config_version_id;
    if found then
      select exposure.* into v_existing_exposure
      from public.retention_campaign_exposures_v99 exposure
      where exposure.campaign_grant_id=v_existing.id;
      return pg_catalog.jsonb_build_object(
        'campaign_id',p_campaign,
        'client_id',p_client,
        'campaign_grant_id',v_existing.id,
        'grant_id',v_existing.id,
        'reward_grant_id',v_existing_entitlement.id,
        'entitlement_status',v_existing_entitlement.status,
        'fulfillment_kind',v_existing_entitlement.fulfillment_kind,
        'reward_label',v_existing_entitlement.reward_label,
        'offer_cost_cents',v_existing.offer_cost_cents,
        'exposure_status',case
          when v_existing_exposure.id is null
            then 'awaiting_manual_attestation'
          else 'verified'
        end,
        'exposure_id',v_existing_exposure.id,
        'exposed_at',v_existing_exposure.exposed_at,
        'exposure_channel',v_existing_exposure.channel,
        'delivery_provider_status','not_configured',
        'customer_history_visible',true,
        'economic_value_posted',false,
        'redemption_mode','merchant_fulfilment_pending',
        'replayed',true,
        'legacy_link_repaired',false
      );
    end if;
  end if;

  if not v_has_existing and v_campaign.budget_cap_cents>0 then
    select coalesce(sum(campaign_grant.offer_cost_cents),0)
    into v_issued_cost
    from public.retention_campaign_grants campaign_grant
    where campaign_grant.campaign_id=p_campaign
      and campaign_grant.business_id=p_business;
    if v_issued_cost+v_offer_cost>v_campaign.budget_cap_cents then
      raise exception 'campaign budget cap exceeded'
        using errcode='check_violation';
    end if;
  end if;

  insert into public.reward_grants(
    business_id,program_id,client_id,period_index,reward_type,
    reward_value,reward_item,status,granted_at,config_version_id,
    retention_program_version_id,campaign_id,campaign_assignment
  ) values(
    p_business,v_rule.program_id,p_client,0,v_rule.fulfillment_kind,
    coalesce(v_rule.discount_percent,v_rule.credit_cents,0),
    v_rule.manual_item,'granted',clock_timestamp(),v_rule.config_version_id,
    v_rule.id,p_campaign,'treatment'
  )
  returning id into v_entitlement;

  if v_has_existing then
    update public.retention_campaign_grants
    set reward_grant_id=v_entitlement,
        request_hash=v_hash
    where id=v_existing.id
    returning * into v_existing;
    v_campaign_grant:=v_existing.id;
    v_repaired:=true;
  else
    insert into public.retention_campaign_grants(
      id,campaign_id,business_id,client_id,assignment,reward_grant_id,
      offer_cost_cents,idempotency_key,issued_by,request_hash
    ) values(
      v_campaign_grant,p_campaign,p_business,p_client,'treatment',
      v_entitlement,v_offer_cost,v_key,v_actor,v_hash
    );
  end if;
  insert into public.audit_log(
    business_id,actor,action,entity,entity_id,detail
  ) values(
    p_business,v_actor,'ISSUE_CAMPAIGN_ENTITLEMENT_V99',
    'retention_campaign_grants',v_campaign_grant,
    pg_catalog.jsonb_build_object(
      'campaign_id',p_campaign,
      'client_id',p_client,
      'reward_grant_id',v_entitlement,
      'retention_program_version_id',v_rule.id,
      'fulfillment_kind',v_rule.fulfillment_kind,
      'offer_cost_cents',v_offer_cost,
      'legacy_link_repaired',v_repaired,
      'delivery_provider_status','not_configured'
    )
  );
  return pg_catalog.jsonb_build_object(
    'campaign_id',p_campaign,
    'client_id',p_client,
    'campaign_grant_id',v_campaign_grant,
    'grant_id',v_campaign_grant,
    'reward_grant_id',v_entitlement,
    'entitlement_status','granted',
    'fulfillment_kind',v_rule.fulfillment_kind,
    'reward_label',(
      select reward.reward_label
      from public.reward_grants reward
      where reward.id=v_entitlement
    ),
    'offer_cost_cents',v_offer_cost,
    'exposure_status','awaiting_manual_attestation',
    'delivery_provider_status','not_configured',
    'customer_history_visible',true,
    'economic_value_posted',false,
    'redemption_mode','merchant_fulfilment_pending',
    'replayed',v_repaired,
    'legacy_link_repaired',v_repaired
  );
end
$function$;
revoke all privileges on function public.issue_campaign_offer(uuid,uuid,uuid,text,bigint,uuid) from public, anon, authenticated;
grant execute on function public.issue_campaign_offer(uuid,uuid,uuid,text,bigint,uuid) to authenticated;

-- 3. public.publish_loyalty_config -- THE resurrection guard. Full body verbatim; the only change
-- is the retention sync UPDATE's `active` expression, which now ANDs in the live row's own
-- deleted_at is null. retention_programs.deleted_at is never one of the columns this UPDATE
-- touches, so once set it survives every publish untouched -- this one-line change is therefore a
-- permanent, durable guard against every future publish of every draft, not a one-off fix for
-- whichever draft happened to be open at delete time (the same "table-snapshot carry-over"
-- philosophy v331 used for loyalty_tiers.paused/deleted_at, simpler here because retention has no
-- delete+reinsert to survive -- only a plain UPDATE whose source value needed correcting).
CREATE OR REPLACE FUNCTION public.publish_loyalty_config(p_version uuid)
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'app', 'pg_temp'
AS $function$
declare v_header public.firm_config_versions%rowtype; v_typed public.loyalty_program_versions%rowtype; v_prior uuid;
  v_rule public.program_rules%rowtype; v_rule_errs text[]; v_active_rule_count integer;
  v_tier_carry_ids uuid[]; v_tier_carry_paused boolean[]; v_tier_carry_deleted timestamptz[];
begin
  select * into v_header from public.firm_config_versions where id=p_version for update;
  if not found or not app.c45_owner_loyalty_write(v_header.business_id) then raise exception 'owner loyalty configuration access required' using errcode='42501'; end if;
  if v_header.status<>'draft' then raise exception 'only a draft may be published'; end if;
  perform 1 from public.businesses where id=v_header.business_id for update;
  select * into v_typed from public.loyalty_program_versions where config_version_id=p_version;
  if exists(select 1 from public.business_programmes spine where spine.business_id=v_header.business_id and spine.kind='stamps' and spine.active) and coalesce(v_typed.stamp_per_cents,0)<=0 then raise exception 'active stamps configuration requires spend per stamp' using errcode='23514'; end if;
  if exists(select 1 from public.business_programmes spine where spine.business_id=v_header.business_id and spine.kind='stamps' and spine.active) then
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
revoke all privileges on function public.publish_loyalty_config(uuid) from public, anon, authenticated;
grant execute on function public.publish_loyalty_config(uuid) to authenticated;

-- 4. app.clone_retention_program_versions_on_draft -- the "clone from based-on version" draft
-- trigger. Full body verbatim, one added join: skip a deleted program entirely so it never
-- reappears as an editable row in any future draft (belt-and-suspenders alongside #3 -- publish
-- would force it back to active=false regardless, but there is no reason to let it be editable).
CREATE OR REPLACE FUNCTION app.clone_retention_program_versions_on_draft()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'app', 'pg_temp'
AS $function$
begin
  if new.status='draft' and new.based_on_version_id is not null then
    insert into public.retention_program_versions(
      program_id,config_version_id,business_id,name,active,goal_visits,
      period_days,starts_on,reward_taxonomy_id,fulfillment_kind,
      discount_percent,credit_cents,manual_item,sort,
      customer_description,staff_description
    )
    select rv.program_id,new.id,new.business_id,rv.name,rv.active,rv.goal_visits,
           rv.period_days,rv.starts_on,rv.reward_taxonomy_id,t.fulfillment_kind,
           rv.discount_percent,rv.credit_cents,rv.manual_item,rv.sort,
           rv.customer_description,rv.staff_description
      from public.retention_program_versions rv
      join public.firm_reward_taxonomy t
        on t.id=rv.reward_taxonomy_id and t.business_id=rv.business_id
      join public.retention_programs prog
        on prog.id=rv.program_id and prog.business_id=rv.business_id
       and prog.deleted_at is null
     where rv.config_version_id=new.based_on_version_id
       and rv.business_id=new.business_id;
  end if;
  return new;
end $function$;
revoke all privileges on function app.clone_retention_program_versions_on_draft() from public, anon, authenticated;

-- 5. app.c45_base_actionable_wallet_card -- the customer wallet card's "you're 1 visit away from a
-- reward" prompt. Full body verbatim, one added join on the retention_windows CTE: a customer must
-- never be shown live progress toward a deleted bring-back rule.
CREATE OR REPLACE FUNCTION app.c45_base_actionable_wallet_card(p_business_id uuid, p_client_id uuid, p_business_slug text, p_business_name text, p_business_industry text, p_business_currency text, p_enabled_modules text[], p_as_of timestamp with time zone)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'app', 'pg_temp'
AS $function$
  with program as (
    select
      'loyalty' = any(p_enabled_modules) and coalesce(lp.active, false) as enabled,
      case when 'loyalty' = any(p_enabled_modules) and coalesce(lp.active, false)
        then case when lp.loyalty_model = 'stamps' then 'stamps' else 'points' end
      end as unit,
      case when 'loyalty' = any(p_enabled_modules) and coalesce(lp.active, false)
        then lp.loyalty_model
      end as model,
      case when 'loyalty' = any(p_enabled_modules) and coalesce(lp.active, false)
        then coalesce(lp.expiry_mode, 'none')
        else 'none'
      end as expiry_mode
    from (select 1) scope
    left join public.loyalty_programs lp on lp.business_id = p_business_id
  ), ledger_balance as (
    select greatest(coalesce(sum(pl.points), 0), 0)::integer as units
      from public.points_ledger pl
     where pl.business_id = p_business_id
       and pl.client_id = p_client_id
  -- A ledger balance can lag or lead batch rows during a repair or reversal.
  -- The customer projection therefore allocates only the proven balance over
  -- unexpired batches in the same FEFO order used for redemption. Expiry
  -- bands and next_expiry_at are derived from that capped allocation, never
  -- from raw batches that the customer cannot currently spend.
  ), unexpired_batches as (
    select
      pb.id,
      pb.remaining,
      pb.earned_at,
      pb.expires_at,
      sum(pb.remaining) over (
        order by pb.expires_at nulls last, pb.earned_at, pb.id
        rows between unbounded preceding and current row
      )::bigint as cumulative_remaining
      from public.points_batches pb
     where pb.business_id = p_business_id
       and pb.client_id = p_client_id
       and pb.remaining > 0
       and (pb.expires_at is null or pb.expires_at > p_as_of)
  ), batch_balance as (
    select coalesce(sum(remaining), 0)::integer as unexpired_units
      from unexpired_batches
  ), loyalty_balance as (
    select
      program.enabled,
      program.model,
      program.unit,
      program.expiry_mode,
      case when program.enabled
        then greatest(least(ledger_balance.units, batch_balance.unexpired_units), 0)
        else 0 end as balance
      from program cross join ledger_balance cross join batch_balance
  ), actionable_batches as (
    select
      ub.expires_at,
      least(
        ub.remaining::bigint,
        greatest(
          loyalty_balance.balance::bigint
            - (ub.cumulative_remaining - ub.remaining::bigint),
          0
        )
      )::integer as actionable_remaining
      from unexpired_batches ub
      cross join loyalty_balance
     where loyalty_balance.enabled
       and loyalty_balance.balance > 0
       and ub.cumulative_remaining - ub.remaining::bigint < loyalty_balance.balance::bigint
  ), expiry_balance as (
    select
      coalesce(sum(actionable_remaining) filter (
        where expires_at > p_as_of
          and expires_at <= p_as_of + interval '7 days'
      ), 0)::integer as expiring_7_units,
      coalesce(sum(actionable_remaining) filter (
        where expires_at > p_as_of
          and expires_at <= p_as_of + interval '30 days'
      ), 0)::integer as expiring_30_units,
      min(expires_at) filter (
        where actionable_remaining > 0
          and expires_at > p_as_of
          and expires_at <= p_as_of + interval '30 days'
      ) as next_expiry_at
      from actionable_batches
  ), loyalty as (
    select
      loyalty_balance.enabled,
      loyalty_balance.model,
      loyalty_balance.unit,
      loyalty_balance.expiry_mode,
      loyalty_balance.balance,
      case when loyalty_balance.enabled and loyalty_balance.expiry_mode <> 'none'
        then expiry_balance.expiring_7_units else 0 end as expiring_7_units,
      case when loyalty_balance.enabled and loyalty_balance.expiry_mode <> 'none'
        then expiry_balance.expiring_30_units else 0 end as expiring_units,
      case when loyalty_balance.enabled and loyalty_balance.expiry_mode <> 'none'
             and expiry_balance.expiring_30_units > 0
        then expiry_balance.next_expiry_at else null end as next_expiry_at
      from loyalty_balance cross join expiry_balance
  ), credit as (
    select greatest(coalesce(sum(cl.amount_cents), 0), 0)::integer as balance_cents
      from public.credit_ledger cl
     where cl.business_id = p_business_id
       and cl.client_id = p_client_id
  ), packages as (
    select coalesce(sum(cp.remaining), 0)::integer as sessions_remaining
      from public.client_packages cp
     where cp.business_id = p_business_id
       and cp.client_id = p_client_id
       and cp.status = 'active'
       and cp.remaining > 0
  ), reward_candidate as (
    select
      rv.customer_name as name,
      rv.cost_points::integer as cost_units,
      greatest(rv.cost_points - loyalty.balance, 0)::integer as remaining_units,
      loyalty.balance >= rv.cost_points as available_now
      from public.businesses b
      join public.loyalty_reward_versions rv
        on rv.business_id = b.id
       and rv.config_version_id = b.active_config_version_id
       and rv.active
      cross join loyalty
      left join lateral (
        select count(*)::integer as used_count
          from public.loyalty_redemptions lr
         where lr.business_id = p_business_id
           and lr.client_id = p_client_id
           and lr.reward_id = rv.reward_id
      ) usage on true
     where b.id = p_business_id
       and loyalty.enabled
       and (rv.claim_available_from is null or rv.claim_available_from <= p_as_of)
       and (rv.claim_available_until is null or rv.claim_available_until > p_as_of)
       and (rv.usage_limit is null or usage.used_count < rv.usage_limit)
     order by greatest(rv.cost_points - loyalty.balance, 0), rv.sort,
              lower(rv.customer_name), rv.reward_id
     limit 1
  ), retention_windows as (
    select
      rv.program_id,
      rv.goal_visits,
      rv.sort,
      rv.name,
      rv.customer_description,
      rv.starts_on::timestamptz
        + make_interval(days => (
          floor(extract(epoch from (p_as_of - rv.starts_on::timestamptz))
            / (rv.period_days * 86400))::integer * rv.period_days
        )) as period_start,
      rv.starts_on::timestamptz
        + make_interval(days => (
          (floor(extract(epoch from (p_as_of - rv.starts_on::timestamptz))
            / (rv.period_days * 86400))::integer + 1) * rv.period_days
        )) as period_end
      from public.businesses b
      join public.retention_program_versions rv
        on rv.business_id = b.id
       and rv.config_version_id = b.active_config_version_id
       and rv.active
      join public.retention_programs prog
        on prog.id = rv.program_id
       and prog.business_id = rv.business_id
       and prog.deleted_at is null
     where b.id = p_business_id
       and p_as_of >= rv.starts_on::timestamptz
  ), visit_candidate as (
    select
      w.program_id,
      w.period_end,
      w.goal_visits,
      w.customer_description,
      greatest(w.goal_visits - count(s.id)::integer, 0)::integer as visits_remaining
      from retention_windows w
      left join public.sales s
        on s.business_id = p_business_id
       and s.client_id = p_client_id
       and s.counts_as_visit
       and s.reversal_of is null
       and s.occurred_at >= w.period_start
       and s.occurred_at < w.period_end
       and not exists (
         select 1 from public.sales reversal
          where reversal.business_id = s.business_id and reversal.reversal_of = s.id
       )
     group by w.program_id, w.goal_visits, w.period_end, w.sort, w.name, w.customer_description
     order by greatest(w.goal_visits - count(s.id)::integer, 0),
              w.period_end, w.sort, lower(w.name), w.program_id
     limit 1
  ), action as (
    select
      case
        when loyalty.expiring_7_units > 0 then 'expiring_within_7_days'
        when coalesce(reward_candidate.available_now, false) then 'reward_available'
        when loyalty.expiring_units > 0 then 'expiring_within_30_days'
        when visit_candidate.visits_remaining = 1 then 'one_qualifying_visit_remaining'
        when reward_candidate.name is not null then 'reward_progress'
        else 'none'
      end as reason,
      case
        when loyalty.expiring_7_units > 0 then loyalty.next_expiry_at
        when loyalty.expiring_units > 0 then loyalty.next_expiry_at
        when visit_candidate.visits_remaining = 1 then visit_candidate.period_end
        else null
      end as deadline_at,
      case
        when loyalty.expiring_7_units > 0 then 1
        when coalesce(reward_candidate.available_now, false) then 2
        when loyalty.expiring_units > 0 then 3
        when visit_candidate.visits_remaining = 1 then 4
        when reward_candidate.name is not null then 5
        else 6
      end as sort_band,
      case when reward_candidate.name is not null
        then reward_candidate.remaining_units else 0 end as sort_units
      from loyalty
      left join reward_candidate on true
      left join visit_candidate on true
  )
  select jsonb_build_object(
    'business', jsonb_build_object(
      'slug', p_business_slug,
      'name', p_business_name,
      'industry', p_business_industry,
      'currency', p_business_currency
    ),
    'loyalty', jsonb_build_object(
      'enabled', loyalty.enabled,
      'model', loyalty.model,
      'unit', loyalty.unit,
      'balance', loyalty.balance
    ),
    'credit', jsonb_build_object(
      'balance_cents', credit.balance_cents
    ),
    'packages', jsonb_build_object(
      'sessions_remaining', case when 'packages' = any(p_enabled_modules)
        then packages.sessions_remaining else 0 end
    ),
    'expiry', jsonb_build_object(
      'mode', loyalty.expiry_mode,
      'expiring_within_7_days', loyalty.expiring_7_units,
      'expiring_units', loyalty.expiring_units,
      'next_expiry_at', loyalty.next_expiry_at
    ),
    'next_eligible_reward', case when reward_candidate.name is null then null else
      jsonb_build_object(
        'name', reward_candidate.name,
        'cost_units', reward_candidate.cost_units,
        'remaining_units', reward_candidate.remaining_units,
        'available_now', reward_candidate.available_now
      ) end,
    'visits_remaining', visit_candidate.visits_remaining,
    'visit_progress', case when visit_candidate.visits_remaining is null then null else
      jsonb_build_object(
        'remaining', visit_candidate.visits_remaining,
        'goal_visits', visit_candidate.goal_visits,
        'period_ends_at', visit_candidate.period_end,
        'customer_description', visit_candidate.customer_description
      ) end,
    'action', jsonb_build_object(
      'reason', action.reason,
      'deadline_at', action.deadline_at,
      'sort_band', action.sort_band,
      'sort_units', action.sort_units
    )
  )
    from loyalty
    cross join credit
    cross join packages
    left join reward_candidate on true
    left join visit_candidate on true
    cross join action;
$function$;
revoke all privileges on function app.c45_base_actionable_wallet_card(uuid,uuid,text,text,text,text,text[],timestamp with time zone) from public, anon, authenticated;

-- 6. app.v177_programmes -- setup-wizard / diagnostic counts. Full body verbatim, deleted_at
-- filter only on both retention counts (a deleted rule should count toward neither "active" nor
-- "total configured", mirroring v331's category-4 treatment of app.business_programmes_v307: a
-- diagnostic must not report a deleted row as "still configured").
CREATE OR REPLACE FUNCTION app.v177_programmes(p_business uuid)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'app', 'pg_temp'
AS $function$
  select pg_catalog.jsonb_build_object(
    'loyalty', coalesce((
      select jsonb_build_object(
        'configured', true,
        'active', program.active,
        'loyalty_model', program.loyalty_model,
        'configuration_status', program.configuration_status,
        'earn_points_per_dollar', program.earn_points_per_dollar,
        'redeem_points', program.redeem_points,
        'reward_credit_cents', program.reward_credit_cents,
        'stamp_target', program.stamp_target,
        'stamp_per_cents', program.stamp_per_cents,
        'expiry_mode', program.expiry_mode,
        'expiry_days', program.expiry_days
      )
      from public.loyalty_programs program
      where program.business_id = p_business
      order by program.active desc, program.id
      limit 1
    ), jsonb_build_object('configured', false)),
    'rewards', jsonb_build_object(
      'active', (
        select count(*) from public.loyalty_rewards reward
        where reward.business_id = p_business and reward.active
      ),
      'total', (
        select count(*) from public.loyalty_rewards reward
        where reward.business_id = p_business
      )
    ),
    'tiers', (
      select count(*) from public.loyalty_tiers tier
      where tier.business_id = p_business
    ),
    'promotions', jsonb_build_object(
      'active_retention_programmes', (
        select count(*) from public.retention_programs program
        where program.business_id = p_business and program.active and program.deleted_at is null
      ),
      'total_retention_programmes', (
        select count(*) from public.retention_programs program
        where program.business_id = p_business and program.deleted_at is null
      ),
      'active_campaigns', (
        select count(*) from public.retention_campaigns campaign
        where campaign.business_id = p_business
          and campaign.status = 'active'
      )
    ),
    'referral', coalesce((
      select jsonb_build_object(
        'configured', true,
        'enabled', program.enabled,
        'reward_cents', program.reward_cents,
        'min_spend_cents', program.min_spend_cents
      )
      from public.referral_programs program
      where program.business_id = p_business
      order by program.created_at desc, program.id
      limit 1
    ), jsonb_build_object('configured', false))
  )
$function$;
revoke all privileges on function app.v177_programmes(uuid) from public, anon, authenticated;

-- 7. public.save_reward_taxonomy -- "can this reward type be retired" guard. Full body verbatim,
-- one added join: a deleted (and now functionally inert, thanks to #2 above) retention program
-- must not go on blocking the owner from retiring the reward taxonomy it used to use.
CREATE OR REPLACE FUNCTION public.save_reward_taxonomy(p_business uuid, p_taxonomy_id uuid, p_taxonomy jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'app', 'pg_temp'
AS $function$
declare v_row public.firm_reward_taxonomy%rowtype; v_id uuid:=coalesce(p_taxonomy_id,gen_random_uuid());
  v_label text; v_kind text; v_active boolean; v_sort integer;
begin
  if not app.is_salon_owner(p_business) then raise exception 'owner only' using errcode='42501'; end if;
  perform 1 from public.businesses where id=p_business for update;
  if p_taxonomy is null or jsonb_typeof(p_taxonomy)<>'object' then raise exception 'taxonomy must be a JSON object' using errcode='22023'; end if;
  if exists(select 1 from jsonb_object_keys(p_taxonomy) k where k not in('label','fulfillment_kind','active','sort')) then
    raise exception 'taxonomy contains unsupported fields' using errcode='22023';
  end if;
  if p_taxonomy_id is not null then
    select * into v_row from public.firm_reward_taxonomy where id=p_taxonomy_id and business_id=p_business for update;
    if not found then raise exception 'taxonomy does not belong to this business' using errcode='42501'; end if;
  end if;
  v_label:=coalesce(nullif(btrim(p_taxonomy->>'label'),''),v_row.label);
  v_kind:=coalesce(nullif(p_taxonomy->>'fulfillment_kind',''),v_row.fulfillment_kind);
  v_active:=case when p_taxonomy?'active' then (p_taxonomy->>'active')::boolean else coalesce(v_row.active,true) end;
  v_sort:=case when p_taxonomy?'sort' then (p_taxonomy->>'sort')::integer else coalesce(v_row.sort,0) end;
  if v_label is null or char_length(v_label) not between 2 and 80
     or v_kind not in('discount_pct','free_item','credit') or v_sort not between 0 and 10000 then
    raise exception 'invalid taxonomy values' using errcode='22023';
  end if;
  if p_taxonomy_id is not null and v_kind is distinct from v_row.fulfillment_kind then
    raise exception 'reward fulfillment behavior is immutable; create a new reward type' using errcode='23001';
  end if;
  if p_taxonomy_id is not null and not v_active and exists(
    select 1
      from public.retention_program_versions rv
      join public.businesses b
        on b.id=rv.business_id and b.active_config_version_id=rv.config_version_id
      join public.retention_programs prog
        on prog.id=rv.program_id and prog.business_id=rv.business_id
       and prog.deleted_at is null
     where rv.business_id=p_business
       and rv.reward_taxonomy_id=p_taxonomy_id
       and rv.active
  ) then
    raise exception 'publish a replacement or disable the live retention program before retiring this taxonomy'
      using errcode='23514';
  end if;
  insert into public.firm_reward_taxonomy(id,business_id,label,fulfillment_kind,active,sort,created_by)
  values(v_id,p_business,v_label,v_kind,v_active,v_sort,auth.uid())
  on conflict(id) do update set label=excluded.label,active=excluded.active,sort=excluded.sort;
  return jsonb_build_object('id',v_id,'label',v_label,'fulfillment_kind',v_kind,'active',v_active,'sort',v_sort);
end $function$;
revoke all privileges on function public.save_reward_taxonomy(uuid,uuid,jsonb) from public, anon, authenticated;
grant execute on function public.save_reward_taxonomy(uuid,uuid,jsonb) to authenticated;

-- 8. public.create_retention_campaign -- "new campaign creation" must be refused against a
-- deleted program (the one case the task's own framing calls out explicitly). Full body verbatim,
-- one added check.
CREATE OR REPLACE FUNCTION public.create_retention_campaign(p_business uuid, p_program_version_id uuid, p_name text, p_audience_criteria jsonb, p_holdout_percent integer DEFAULT 10, p_budget_cap_cents bigint DEFAULT 0, p_attribution_window_days integer DEFAULT 30, p_expected_cost_cents bigint DEFAULT NULL::bigint, p_expected_upside_cents bigint DEFAULT NULL::bigint, p_explanation text DEFAULT NULL::text)
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'app', 'pg_temp'
AS $function$
declare
  v_actor uuid := auth.uid();
  v_rule public.retention_program_versions%rowtype;
  v_campaign_id uuid := gen_random_uuid();
  v_name text := btrim(coalesce(p_name, ''));
begin
  if not app.is_salon_owner(p_business) then
    raise exception 'owner only' using errcode = '42501';
  end if;
  perform 1 from public.businesses where id = p_business for share;
  if char_length(v_name) not between 1 and 120 then
    raise exception 'campaign name must be 1..120 characters' using errcode = '22023';
  end if;
  if p_audience_criteria is null or jsonb_typeof(p_audience_criteria) <> 'object' then
    raise exception 'audience criteria must be a JSON object' using errcode = '22023';
  end if;
  if coalesce(p_holdout_percent, -1) not between 0 and 90 then
    raise exception 'holdout percent must be between 0 and 90' using errcode = '22023';
  end if;
  if coalesce(p_budget_cap_cents, 0) < 0 then
    raise exception 'budget cap cannot be negative' using errcode = '22023';
  end if;
  if coalesce(p_attribution_window_days, 0) not between 1 and 365 then
    raise exception 'attribution window must be between 1 and 365 days' using errcode = '22023';
  end if;
  if p_explanation is not null and char_length(p_explanation) > 4000 then
    raise exception 'explanation is limited to 4000 characters' using errcode = '22023';
  end if;
  select * into v_rule from public.retention_program_versions
   where id = p_program_version_id and business_id = p_business;
  if not found then
    raise exception 'retention program version does not belong to this business' using errcode = '22023';
  end if;
  if exists(
    select 1 from public.retention_programs prog
     where prog.id = v_rule.program_id and prog.business_id = p_business and prog.deleted_at is not null
  ) then
    raise exception 'cannot create a campaign for a deleted bring-back rule' using errcode = '22023';
  end if;

  insert into public.retention_campaigns(
    id, business_id, retention_program_version_id, program_id, config_version_id,
    name, audience_criteria, holdout_percent, budget_cap_cents,
    expected_cost_cents, expected_upside_cents, attribution_window_days,
    explanation, status, created_by
  ) values (
    v_campaign_id, p_business, v_rule.id, v_rule.program_id, v_rule.config_version_id,
    v_name, p_audience_criteria, coalesce(p_holdout_percent, 10), coalesce(p_budget_cap_cents, 0),
    p_expected_cost_cents, p_expected_upside_cents, coalesce(p_attribution_window_days, 30),
    nullif(btrim(coalesce(p_explanation, '')), ''), 'draft', v_actor
  );
  insert into public.audit_log(business_id, actor, action, entity, entity_id, detail)
  values (p_business, v_actor, 'CREATE_RETENTION_CAMPAIGN', 'retention_campaigns', v_campaign_id,
    jsonb_build_object('retention_program_version_id', v_rule.id, 'holdout_percent', coalesce(p_holdout_percent, 10)));
  return json_build_object(
    'campaign_id', v_campaign_id, 'status', 'draft',
    'retention_program_version_id', v_rule.id, 'holdout_percent', coalesce(p_holdout_percent, 10),
    'attribution_window_days', coalesce(p_attribution_window_days, 30)
  );
end $function$;
revoke all privileges on function public.create_retention_campaign(uuid,uuid,text,jsonb,integer,bigint,integer,bigint,bigint,text) from public, anon, authenticated;
grant execute on function public.create_retention_campaign(uuid,uuid,text,jsonb,integer,bigint,integer,bigint,bigint,text) to authenticated;

-- 9. public.ensure_published_retention_in_draft_v138 -- materializes a published rule into an
-- editable draft row. The resurrection guard, applied the same way v329 applied it to
-- save_membership_plan's UPDATE path: refuse outright, rather than letting a deleted program
-- become editable (again) inside any draft. Full body verbatim, one added check.
CREATE OR REPLACE FUNCTION public.ensure_published_retention_in_draft_v138(p_config_version uuid, p_program uuid, p_expected_snapshot_hash text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'app', 'pg_temp'
AS $function$
declare
  v_draft public.firm_config_versions%rowtype;
  v_source public.retention_program_versions%rowtype;
  v_active_config uuid;
  v_new_version uuid;
  v_snapshot_hash text;
begin
  select * into v_draft from public.firm_config_versions
   where id=p_config_version for update;
  if not found or not app.is_salon_owner(v_draft.business_id)
     or not app.can_module_write(v_draft.business_id,'retention') then
    raise exception 'owner retention configuration access required' using errcode='42501';
  end if;
  if v_draft.status<>'draft' then
    raise exception 'only a draft may receive an editable bring-back rule' using errcode='22023';
  end if;
  if not exists(
    select 1 from public.retention_programs prog
     where prog.id=p_program and prog.business_id=v_draft.business_id and prog.deleted_at is null
  ) then
    raise exception 'retention program does not belong to this business, or is already deleted' using errcode='22023';
  end if;
  select id into v_new_version from public.retention_program_versions
   where config_version_id=p_config_version and business_id=v_draft.business_id
     and program_id=p_program;
  if found then
    return jsonb_build_object('program_id',p_program,
      'retention_program_version_id',v_new_version,
      'config_version_id',p_config_version,'snapshot_hash',v_draft.snapshot_hash,
      'replayed',true,'published',false);
  end if;
  if p_expected_snapshot_hash is not null
     and v_draft.snapshot_hash is distinct from p_expected_snapshot_hash then
    raise exception 'draft configuration changed; reload before editing this bring-back rule'
      using errcode='40001';
  end if;
  select active_config_version_id into v_active_config
    from public.businesses where id=v_draft.business_id for share;
  select * into v_source from public.retention_program_versions
   where config_version_id=v_active_config and business_id=v_draft.business_id
     and program_id=p_program;
  if not found then
    raise exception 'published bring-back rule is unavailable' using errcode='22023';
  end if;
  insert into public.retention_program_versions(
    program_id,config_version_id,business_id,name,active,goal_visits,period_days,
    starts_on,reward_taxonomy_id,fulfillment_kind,discount_percent,credit_cents,
    manual_item,sort,customer_description,staff_description
  ) values(
    v_source.program_id,p_config_version,v_source.business_id,v_source.name,
    v_source.active,v_source.goal_visits,v_source.period_days,v_source.starts_on,
    v_source.reward_taxonomy_id,v_source.fulfillment_kind,v_source.discount_percent,
    v_source.credit_cents,v_source.manual_item,v_source.sort,
    v_source.customer_description,v_source.staff_description
  ) on conflict(program_id,config_version_id) do nothing returning id into v_new_version;
  if v_new_version is null then
    select id into v_new_version from public.retention_program_versions
     where config_version_id=p_config_version and business_id=v_draft.business_id
       and program_id=p_program;
  end if;
  perform app.refresh_loyalty_config_snapshot(p_config_version);
  select snapshot_hash into v_snapshot_hash from public.firm_config_versions
   where id=p_config_version;
  insert into public.audit_log(business_id,actor,action,entity,entity_id,detail)
  values(v_draft.business_id,auth.uid(),'MATERIALIZE_RETENTION_DRAFT',
    'retention_program_versions',p_program,jsonb_build_object(
      'draft_config_version_id',p_config_version,
      'source_config_version_id',v_active_config,
      'retention_program_version_id',v_new_version,'published',false));
  return jsonb_build_object('program_id',p_program,
    'retention_program_version_id',v_new_version,
    'config_version_id',p_config_version,'snapshot_hash',v_snapshot_hash,
    'replayed',false,'published',false);
end $function$;
revoke all privileges on function public.ensure_published_retention_in_draft_v138(uuid,uuid,text) from public, anon, authenticated;
grant execute on function public.ensure_published_retention_in_draft_v138(uuid,uuid,text) to authenticated;

-- 10. public.save_retention_program_draft -- the draft editor's own save/edit RPC. The resurrection
-- guard, applied a second time (defense-in-depth alongside #3 and #9): a draft that was already
-- open when the program was deleted still has its own retention_program_versions row (this
-- migration's new RPC flips its `active` to false, but the row still exists), so without this
-- check the owner could still successfully re-edit it -- including flipping `active` back to true
-- inside that one draft -- even though #3 guarantees that edit can never actually resurrect the
-- live program at publish time. Refusing outright here is clearer than silently allowing an edit
-- that would be force-overridden later. Full body verbatim, one added check.
CREATE OR REPLACE FUNCTION public.save_retention_program_draft(p_config_version uuid, p_program_id uuid, p_program jsonb, p_expected_snapshot_hash text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'app', 'pg_temp'
AS $function$
declare v_header public.firm_config_versions%rowtype; v_existing public.retention_program_versions%rowtype;
  v_tax public.firm_reward_taxonomy%rowtype; v_program_id uuid:=p_program_id;
  v_id uuid; v_hash text; v_name text; v_active boolean; v_goal integer; v_period integer;
  v_starts date; v_tax_id uuid; v_discount numeric; v_credit integer; v_item text;
  v_sort integer; v_customer text; v_staff text;
begin
  if p_program_id is null then
    raise exception 'a stable program id is required for retry-safe creation' using errcode='22023';
  end if;
  if p_program is null or jsonb_typeof(p_program)<>'object' then
    raise exception 'retention program must be a JSON object' using errcode='22023';
  end if;
  if exists(select 1 from jsonb_object_keys(p_program) k where k not in(
    'name','active','goal_visits','period_days','starts_on','reward_taxonomy_id',
    'discount_percent','credit_cents','manual_item','sort','customer_description','staff_description'
  )) then raise exception 'retention program contains unsupported fields' using errcode='22023'; end if;
  select * into v_header from public.firm_config_versions where id=p_config_version for update;
  if not found or not app.is_salon_owner(v_header.business_id) then raise exception 'owner only' using errcode='42501'; end if;
  if v_header.status<>'draft' then raise exception 'only a draft retention program may be edited' using errcode='42501'; end if;
  perform 1 from public.businesses where id=v_header.business_id for share;
  if p_expected_snapshot_hash is null then
    raise exception 'expected snapshot hash is required' using errcode='22023';
  end if;
  select * into v_existing from public.retention_program_versions
   where program_id=v_program_id and config_version_id=p_config_version and business_id=v_header.business_id;
  if v_existing.id is null and exists(select 1 from public.retention_programs where id=p_program_id) then
    if exists(select 1 from public.retention_programs where id=p_program_id and business_id<>v_header.business_id) then
      raise exception 'retention program does not belong to this business' using errcode='42501';
    end if;
    raise exception 'retention program is not part of this draft' using errcode='22023';
  end if;
  if v_existing.id is not null and exists(
    select 1 from public.retention_programs prog
     where prog.id=v_program_id and prog.business_id=v_header.business_id and prog.deleted_at is not null
  ) then
    raise exception 'retention program does not belong to this business, or is already deleted' using errcode='22023';
  end if;
  v_name:=coalesce(nullif(btrim(p_program->>'name'),''),v_existing.name);
  v_active:=case when p_program?'active' then (p_program->>'active')::boolean else coalesce(v_existing.active,true) end;
  v_goal:=case when p_program?'goal_visits' then (p_program->>'goal_visits')::integer else v_existing.goal_visits end;
  v_period:=case when p_program?'period_days' then (p_program->>'period_days')::integer else v_existing.period_days end;
  v_starts:=case when p_program?'starts_on' then (p_program->>'starts_on')::date else coalesce(v_existing.starts_on,(timezone('Asia/Singapore', now()))::date) end;
  v_tax_id:=case when p_program?'reward_taxonomy_id' then (p_program->>'reward_taxonomy_id')::uuid else v_existing.reward_taxonomy_id end;
  v_discount:=case when p_program?'discount_percent' then nullif(p_program->>'discount_percent','')::numeric else v_existing.discount_percent end;
  v_credit:=case when p_program?'credit_cents' then nullif(p_program->>'credit_cents','')::integer else v_existing.credit_cents end;
  v_item:=case when p_program?'manual_item' then nullif(btrim(p_program->>'manual_item'),'') else v_existing.manual_item end;
  v_sort:=case when p_program?'sort' then (p_program->>'sort')::integer else coalesce(v_existing.sort,0) end;
  v_customer:=case when p_program?'customer_description' then nullif(btrim(p_program->>'customer_description'),'') else v_existing.customer_description end;
  v_staff:=case when p_program?'staff_description' then nullif(btrim(p_program->>'staff_description'),'') else v_existing.staff_description end;
  if v_name is null or v_goal is null or v_goal<=0 or v_period is null or v_period<=0 or v_tax_id is null then
    raise exception 'name, positive goal/period, and reward taxonomy are required' using errcode='22023';
  end if;
  select * into v_tax from public.firm_reward_taxonomy where id=v_tax_id and business_id=v_header.business_id and active;
  if not found then raise exception 'reward taxonomy is missing, retired, or belongs to another business' using errcode='22023'; end if;
  if (v_tax.fulfillment_kind='discount_pct' and not(coalesce(v_discount,0)>0 and v_discount<=100))
     or (v_tax.fulfillment_kind='credit' and coalesce(v_credit,0)<=0)
     or (v_tax.fulfillment_kind='free_item' and char_length(coalesce(v_item,''))<2) then
    raise exception 'retention reward parameters do not match the immutable fulfillment kind' using errcode='22023';
  end if;
  if v_tax.fulfillment_kind<>'discount_pct' then v_discount:=null; end if;
  if v_tax.fulfillment_kind<>'credit' then v_credit:=null; end if;
  if v_tax.fulfillment_kind<>'free_item' then v_item:=null; end if;
  if v_header.snapshot_hash is distinct from p_expected_snapshot_hash then
    if v_existing.id is not null
       and (v_existing.name,v_existing.active,v_existing.goal_visits,v_existing.period_days,
            v_existing.starts_on,v_existing.reward_taxonomy_id,v_existing.discount_percent,
            v_existing.credit_cents,v_existing.manual_item,v_existing.sort,
            v_existing.customer_description,v_existing.staff_description)
           is not distinct from
           (v_name,v_active,v_goal,v_period,v_starts,v_tax.id,v_discount,v_credit,v_item,
            v_sort,v_customer,v_staff) then
      return jsonb_build_object('program_id',v_program_id,
        'retention_program_version_id',v_existing.id,'config_version_id',p_config_version,
        'status','draft','snapshot_hash',v_header.snapshot_hash,'replayed',true);
    end if;
    raise exception 'draft configuration changed; reload before saving' using errcode='40001';
  end if;
  if v_existing.id is null then
    insert into public.retention_programs(
      id,business_id,name,goal_visits,period_days,reward_taxonomy_id,reward_type,
      reward_value,reward_item,starts_on,active,current_config_version_id
    ) values(v_program_id,v_header.business_id,v_name,v_goal,v_period,v_tax.id,v_tax.fulfillment_kind,
      coalesce(v_discount,v_credit,0),v_item,v_starts,false,null);
  end if;
  insert into public.retention_program_versions(
    program_id,config_version_id,business_id,name,active,goal_visits,period_days,
    starts_on,reward_taxonomy_id,fulfillment_kind,
    discount_percent,credit_cents,manual_item,sort,customer_description,staff_description
  ) values(v_program_id,p_config_version,v_header.business_id,v_name,v_active,v_goal,v_period,
    v_starts,v_tax.id,v_tax.fulfillment_kind,v_discount,v_credit,v_item,v_sort,v_customer,v_staff)
  on conflict(program_id,config_version_id) do update set
    name=excluded.name,active=excluded.active,goal_visits=excluded.goal_visits,
    period_days=excluded.period_days,starts_on=excluded.starts_on,
    reward_taxonomy_id=excluded.reward_taxonomy_id,
    fulfillment_kind=excluded.fulfillment_kind,discount_percent=excluded.discount_percent,
    credit_cents=excluded.credit_cents,manual_item=excluded.manual_item,sort=excluded.sort,
    customer_description=excluded.customer_description,staff_description=excluded.staff_description
  returning id into v_id;
  perform app.refresh_loyalty_config_snapshot(p_config_version);
  select snapshot_hash into v_hash from public.firm_config_versions where id=p_config_version;
  return jsonb_build_object('program_id',v_program_id,'retention_program_version_id',v_id,
    'config_version_id',p_config_version,'status','draft','snapshot_hash',v_hash,'replayed',false);
end $function$;
revoke all privileges on function public.save_retention_program_draft(uuid,uuid,jsonb,text) from public, anon, authenticated;
grant execute on function public.save_retention_program_draft(uuid,uuid,jsonb,text) to authenticated;

-- 11. The new immediate-write delete RPC. Authorization mirrors public.save_retention_program_draft
-- exactly (app.is_salon_owner, the SAME gate that function already uses today -- NOT
-- app.can_module_write, which the v329/v331 precedents alone would suggest but which retention
-- drafting has never actually used).
create or replace function public.business_delete_retention_program_v332(p_business uuid, p_program uuid)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_row public.retention_programs%rowtype;
begin
  if not app.is_salon_owner(p_business) then
    raise exception 'owner only' using errcode='42501';
  end if;

  update public.retention_programs
     set active=false, deleted_at=now()
   where id=p_program and business_id=p_business and deleted_at is null
  returning * into v_row;
  if not found then
    raise exception 'retention program does not belong to this business, or is already deleted' using errcode='22023';
  end if;

  -- app.on_sale_recorded / public.issue_campaign_offer both now check retention_programs.deleted_at
  -- directly (see migration header) -- the update above is ALREADY sufficient to stop new reward
  -- grants immediately, because retention_program_versions rows on an already-published config
  -- version are immutable (trg_guard_retention_program_version) and can never be forced false
  -- directly. This second write is a UI-consistency nicety, not the resurrection guard itself:
  -- every currently-open draft (there is normally at most one, but this updates all of them, not
  -- just one) gets its OWN editable retention_program_versions row set to active=false too, so the
  -- Bring-back editor immediately shows the rule as off if the owner has a draft open right now.
  -- publish_loyalty_config is separately, durably patched to force active=false at every future
  -- publish regardless of what any draft's row says (see its own comment) -- that is what actually
  -- makes this delete permanent.
  update public.retention_program_versions rpv
     set active=false
    from public.firm_config_versions fcv
   where fcv.id=rpv.config_version_id
     and fcv.business_id=p_business
     and fcv.status='draft'
     and rpv.program_id=p_program
     and rpv.business_id=p_business
     and rpv.active;

  insert into public.audit_log(business_id,actor,action,entity,entity_id,detail)
  values(p_business,auth.uid(),'DELETE_RETENTION_PROGRAM','retention_programs',p_program,
    jsonb_build_object('name',v_row.name,'goal_visits',v_row.goal_visits,'period_days',v_row.period_days));

  return jsonb_build_object('status','ok','program_id',p_program,'mode','deleted');
end
$$;
revoke all privileges on function public.business_delete_retention_program_v332(uuid,uuid) from public, anon, authenticated;
grant execute on function public.business_delete_retention_program_v332(uuid,uuid) to authenticated;

commit;
