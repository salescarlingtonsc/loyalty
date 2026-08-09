-- Nestly v258 — the recommended draft inherits the LIVE programme status.
--
-- Owner report (item 6): "published points system, but still shows paused."
--
-- Trace, against production:
--   * publish_loyalty_config copies the draft's own flag:
--       update public.loyalty_programs set ... active=v_typed.active,
--         configuration_status='published' ...
--     so publishing is faithful. It is not losing the owner's choice.
--   * generate_retention_recommendation clones the live version (create_loyalty_config_draft
--     copies `active` across), and then immediately overwrites it:
--       perform public.save_loyalty_config_draft(v_draft_id, jsonb_build_object(
--         'kind','points','active',false, ...));
--     Every recommended draft is therefore born Paused, whatever the live programme was.
--   * Cubbly 8492e8d6-8888-4383-ada0-7e1ed69f0caa shows the sequence exactly:
--       v18 owner_reward_editor        published  active=true
--       v19 catalog_recommendation_v128 published active=false   <- silently paused
--       v20 catalog_recommendation_v128 published active=false
--     loyalty_programs is now active=false with configuration_status='published' — the owner's
--     "published, but still paused".
--
-- Fix: a recommendation changes the NUMBERS it recommends. It has no opinion about whether the
-- firm is trading, so it must carry the live status forward instead of asserting false. A firm
-- with no live programme still starts Paused, which is the correct default for a first draft.
--
-- Only the `active` argument of the first save changes; everything else is reproduced verbatim.
--
-- Applied to production 2026-08-09 after diffing the rewritten body against the live
-- pg_get_functiondef: the only differences are the v_base_active declaration, the lookup, and
-- 'active',false -> 'active',v_base_active. Nothing else was dropped by the rewrite.
-- Acceptance run against production inside an aborted transaction:
--   [1] recommended draft inherited active=true; [2] publish kept active=true status=published;
--   [3] deliberate Pause still publishes paused (no always-active rule).

begin;

create or replace function public.generate_retention_recommendation(
  p_business uuid, p_idempotency_key text
) returns json
language plpgsql
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $function$
declare
  v_actor uuid:=auth.uid(); v_run public.retention_recommendation_runs%rowtype;
  v_business public.businesses%rowtype; v_base uuid; v_draft json; v_draft_id uuid;
  v_existing_draft uuid; v_service_count integer; v_product_count integer;
  v_branch_count integer; v_avg_service integer; v_avg_product integer;
  v_reference_price integer; v_model text; v_stamp_cents integer;
  v_reward_cost integer; v_metrics jsonb; v_recommendation jsonb;
  v_base_active boolean;
begin
  if not app.c45_owner_loyalty_write(p_business)
     or not app.can_module_write_at_v94(p_business,null,'loyalty') then
    raise exception 'owner loyalty configuration access required'
      using errcode='42501';
  end if;
  if p_idempotency_key is null or length(btrim(p_idempotency_key))<8 then
    raise exception 'idempotency key must contain at least 8 characters'
      using errcode='22023';
  end if;
  p_idempotency_key:=btrim(p_idempotency_key);

  -- The business row serializes different request keys too. A second tab that
  -- began from a stale no-draft snapshot will observe and resume the first
  -- tab's committed draft after acquiring this lock.
  select * into v_business from public.businesses
   where id=p_business for update;
  if not found then raise exception 'business not found'; end if;

  select count(*)::integer,coalesce(round(avg(price_cents)),0)::integer
    into v_service_count,v_avg_service from public.services
   where business_id=p_business and active;
  select count(*)::integer,coalesce(round(avg(retail_price_cents)),0)::integer
    into v_product_count,v_avg_product from public.products
   where business_id=p_business and active;
  select count(*)::integer into v_branch_count from public.branches
   where business_id=p_business and active;
  v_reference_price:=case
    when v_avg_service>0 and v_avg_product>0
      then round((v_avg_service+v_avg_product)/2.0)
    else greatest(v_avg_service,v_avg_product,1000)
  end;
  v_metrics:=jsonb_build_object(
    'industry',coalesce(v_business.industry,'other'),
    'active_services',v_service_count,
    'active_products',v_product_count,
    'active_branches',v_branch_count,
    'average_service_cents',v_avg_service,
    'average_product_cents',v_avg_product,
    'reference_price_cents',v_reference_price
  );

  -- Preserve exact replay before considering any other editable draft.
  select * into v_run from public.retention_recommendation_runs
   where business_id=p_business and idempotency_key=p_idempotency_key
   for update;
  if found then
    if v_run.request_hash<>md5(v_metrics::text) then
      raise exception 'idempotency key conflicts with changed business inputs'
        using errcode='22023';
    end if;
    if v_run.status='draft_ready' then return v_run.recommendation::json; end if;
    raise exception 'recommendation is already being generated'
      using errcode='55P03';
  end if;

  select coalesce(v_business.active_config_version_id,lp.current_config_version_id)
    into v_base from public.loyalty_programs lp
   where lp.business_id=p_business;
  if v_base is null then
    raise exception 'loyalty draft is missing for this business';
  end if;

  select version.id into v_existing_draft
    from public.firm_config_versions version
   where version.business_id=p_business
     and version.status='draft'
     and version.based_on_version_id=v_base
   order by version.version_no desc
   limit 1;
  if v_existing_draft is not null then
    select programme.loyalty_model into v_model
      from public.loyalty_program_versions programme
     where programme.business_id=p_business
       and programme.config_version_id=v_existing_draft;
    return json_build_object(
      'run_id',null,
      'draft_config_version_id',v_existing_draft,
      'status','existing_draft',
      'published',false,
      'resumed_existing',true,
      'model',v_model,
      'rationale','Existing editable draft resumed; no recommendation replaced it.',
      'input_metrics',v_metrics
    );
  end if;

  insert into public.retention_recommendation_runs(
    business_id,idempotency_key,request_hash,status,input_metrics,created_by
  ) values(
    p_business,p_idempotency_key,md5(v_metrics::text),'generating',v_metrics,v_actor
  );

  -- V75 governs these exact current sector keys. Legacy synonyms remain for
  -- already-created businesses that have not yet been normalized.
  v_model:=case
    when lower(coalesce(v_business.industry,'other'))
      in ('fnb','food_beverage','cafe','restaurant') then 'stamps'
    when lower(coalesce(v_business.industry,'other'))
      in ('salon','spa','facial','massage','fitness','retail') then 'points_tiers'
    else 'classic'
  end;
  v_stamp_cents:=greatest(
    100,round((v_reference_price/2.0)/100.0)::integer*100
  );
  v_reward_cost:=greatest(
    5,case when v_model='stamps' then 8
      else ceil((v_reference_price/100.0)*5)::integer end
  );

  -- V258: the recommendation owns the NUMBERS, never the trading status. Read the live
  -- version's own flag and carry it forward, so a live Active programme is never silently
  -- paused by publishing a recommended draft. A firm with no live programme keeps the old
  -- behaviour: its first draft starts Paused.
  select base.active into v_base_active
    from public.loyalty_program_versions base
   where base.config_version_id=v_base
     and base.business_id=p_business;
  v_base_active:=coalesce(v_base_active,false);

  v_draft:=public.create_loyalty_config_draft(
    p_business,v_base,'catalog_recommendation_v128'
  );
  v_draft_id:=(v_draft->>'version_id')::uuid;
  perform public.save_loyalty_config_draft(v_draft_id,jsonb_build_object(
    'kind','points','active',v_base_active,'loyalty_model',v_model,
    'earn_points_per_dollar',1,'redeem_points',greatest(100,v_reward_cost),
    'reward_credit_cents',0,
    'stamp_per_cents',case when v_model='stamps' then v_stamp_cents else null end,
    'expiry_mode','none','expiry_days',null
  ));
  -- V197: only seed a starting reward when the draft has none. The draft is cloned from the
  -- live config, so a firm that already published a reward would otherwise gain a duplicate on
  -- every recommend -> publish cycle.
  if v_model in ('stamps','points_tiers')
     and not exists (
       select 1 from public.loyalty_reward_versions existing
        where existing.business_id = p_business
          and existing.config_version_id = v_draft_id
          and existing.active
     ) then
    perform public.save_loyalty_config_draft(v_draft_id,jsonb_build_object(
      'reward',jsonb_build_object(
        'business_id',p_business,
        'name','Recommended return reward',
        'customer_name','A thank-you on your next visits',
        'description','Suggested starting benefit. Replace this with an item or service that fits your margins.',
        'fulfillment_kind','manual_item',
        'cost_points',v_reward_cost,
        'credit_cents',0,
        'estimated_cost_cents',0,
        'active',true,
        'usage_limit',null
      ),
      'reward_branch_ids','[]'::jsonb,
      'reward_service_ids','[]'::jsonb,
      'reward_product_ids','[]'::jsonb
    ));
  end if;

  v_recommendation:=jsonb_build_object(
    'run_id',(
      select id from public.retention_recommendation_runs
       where business_id=p_business and idempotency_key=p_idempotency_key
    ),
    'draft_config_version_id',v_draft_id,
    'status','draft_ready',
    'published',false,
    'resumed_existing',false,
    'model',v_model,
    'reference_price_cents',v_reference_price,
    'suggested_spend_per_stamp_cents',
      case when v_model='stamps' then v_stamp_cents else null end,
    'suggested_reward_cost',
      case when v_model in ('stamps','points_tiers') then v_reward_cost else null end,
    'rationale',case
      when v_model='stamps'
        then 'Frequent-purchase catalog: a visible stamp goal is simple at the counter.'
      when v_model='points_tiers'
        then 'Repeat-service catalog: flexible rewards preserve margin and support progression.'
      else 'Limited catalog signal: start with simple points and review after real sales history.'
    end,
    'input_metrics',v_metrics
  );
  update public.retention_recommendation_runs
     set status='draft_ready',recommendation=v_recommendation,
       draft_config_version_id=v_draft_id,completed_at=now()
   where business_id=p_business and idempotency_key=p_idempotency_key;
  return v_recommendation::json;
end $function$;

-- CREATE OR REPLACE preserves an existing function's ACL, so production stayed closed to
-- PUBLIC across this change. A fresh replay of the canonical chain would not: a newly
-- created function carries PostgreSQL's default EXECUTE grant to PUBLIC, which on a
-- SECURITY DEFINER owner-only RPC would hand anon the ability to mint loyalty drafts.
-- Stating the intended ACL here makes the replayed database identical to production.
revoke all on function public.generate_retention_recommendation(uuid,text) from public;
revoke all on function public.generate_retention_recommendation(uuid,text) from anon;
grant execute on function public.generate_retention_recommendation(uuid,text) to authenticated;

commit;
