-- nestly_v787 — every live business is on the Pipeline.
--
-- OWNER, 2026-09-06: "where is all my businesses? i do not see them in the kanban." Ruling (asked,
-- answered): create CRM records for them — each live business gets a record in the Closed lane,
-- linked to its workspace, so notes, follow-ups, appointments, branches and payments all work on
-- it, and future self-serve signups get a record automatically.
--
-- WHY THEY WERE MISSING. Every one of the 21 live businesses signed up on its own through
-- create_business; none came through the CRM's conversion flow, so none had an sme_prospects row.
-- The retired Onboarding board papered over that by merging the business directory into its
-- "Case won" lane; the Pipeline (v785) reads the CRM alone — as it should, because a note or a
-- follow-up has to live on a record.
--
-- WHAT THIS ADDS
--   app.v787_ensure_business_prospect(p_business)  idempotent: returns the prospect already linked
--     to the business (sme_prospects.converted_business_id, UNIQUE), else the prospect the
--     conversion flow is about to link (businesses.source_prospect_id), else creates ONE company
--     + ONE prospect in the Closed lane ('activated' when a subscription is active or trialing,
--     'account_created' otherwise), with stage history and source lineage. Synthetic businesses
--     are skipped.
--   platform_pipeline_sync_live_firms_v787()  a super admin's or admin's console calls it as the
--     Pipeline loads: every non-synthetic business without a record gets one. Deliberately NOT a
--     trigger on businesses: the executed access-boundary fixtures (v667, v720, v721, v736, v741)
--     insert a business and then their OWN prospect pointing at it, and an AFTER INSERT trigger
--     would have taken the UNIQUE converted_business_id slot first. A read-time sync collides with
--     nothing and still catches a signup on the next Pipeline load.
--   a one-time backfill of every existing non-synthetic business.
--
-- WHAT THIS DELIBERATELY DOES NOT DO. It never sets businesses.source_prospect_id: v79's
-- conversion guard treats that column as "identity and activation are controlled by the CRM" and
-- would from then on refuse a legal-name change or switching a branch back on for a self-serve
-- workspace. The link lives on the prospect (converted_business_id), which is what the Pipeline
-- board, drawer and payments read.
--
-- ownership_state is 'closed' (no owner, no queue) — the v510 ownership-shape check's third arm, and
-- exactly what a won firm is; app.v510_prospect_operating_guard exempts converted rows, so no
-- next-action deadline is demanded of a firm that is already live.

begin;

create or replace function app.v787_ensure_business_prospect(p_business uuid)
returns uuid
language plpgsql
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $function$
declare
  v_biz public.businesses%rowtype;
  v_existing uuid;
  v_company uuid;
  v_prospect uuid;
  v_actor uuid;
  v_stage text;
  v_sector text;
begin
  if p_business is null then return null; end if;
  select * into v_biz from public.businesses where id = p_business;
  if not found or coalesce(v_biz.is_synthetic, false) then return null; end if;

  select id into v_existing from public.sme_prospects where converted_business_id = p_business limit 1;
  if found then return v_existing; end if;

  -- The CRM conversion flow inserts the business with source_prospect_id set and links the prospect
  -- itself in the same transaction; creating a second record here would collide with that link.
  if v_biz.source_prospect_id is not null then
    select id into v_existing from public.sme_prospects where id = v_biz.source_prospect_id;
    if found then return v_existing; end if;
  end if;

  v_actor := coalesce(
    auth.uid(),
    (select s.user_id from public.staff s where s.business_id = p_business and s.role = 'owner' and s.user_id is not null
       order by s.created_at limit 1),
    (select sa.user_id from public.super_admins sa order by sa.created_at limit 1));
  if v_actor is null then return null; end if;

  v_sector := case when exists (select 1 from public.sector_profiles sp where sp.sector_key = v_biz.industry)
                   then v_biz.industry end;
  v_stage := case when exists (select 1 from public.subscriptions s where s.business_id = p_business and s.status in ('active','trialing'))
                    or exists (select 1 from public.billing_provider_subscriptions b where b.business_id = p_business and b.status = 'active')
                  then 'activated' else 'account_created' end;

  insert into public.sme_companies(legal_name, trading_name, registration_number, industry, sector_key)
  values (coalesce(nullif(btrim(v_biz.legal_name), ''), v_biz.name), v_biz.name, v_biz.registration_number, v_biz.industry, v_sector)
  returning id into v_company;

  insert into public.sme_prospects(company_id, current_stage_key, stage_entered_at,
    converted_business_id, converted_at, converted_by, ownership_state, queue_key, next_action_type,
    created_by, created_at, updated_by, updated_at)
  values (v_company, v_stage, v_biz.created_at, p_business, v_biz.created_at, v_actor, 'closed', null, 'none',
    v_actor, v_biz.created_at, v_actor, v_biz.created_at)
  returning id into v_prospect;

  insert into public.sme_prospect_stage_history(prospect_id, from_stage_key, to_stage_key, reason_code, reason_detail, actor, occurred_at)
  values (v_prospect, null, v_stage, 'self_serve_workspace',
    'Live workspace registered on the Pipeline (nestly_v787); signed up through create_business, not the CRM conversion flow',
    v_actor, v_biz.created_at);

  insert into public.sme_prospect_source_lineage(prospect_id, source_system, source_type, external_id, detail, created_by)
  values (v_prospect, 'peekaa_self_serve', 'website', p_business::text,
    jsonb_build_object('business_id', p_business, 'slug', v_biz.slug, 'registered_by', 'nestly_v787'), v_actor);

  return v_prospect;
end
$function$;

-- The read-time sync the console calls as the Pipeline loads.
create or replace function public.platform_pipeline_sync_live_firms_v787()
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $function$
declare
  v_role text := app.v89_platform_role();
  v_row record;
  v_registered integer := 0;
  v_ids uuid[] := '{}';
  v_prospect uuid;
begin
  if auth.uid() is null or v_role not in ('super_admin','admin') or not app.v89_platform_can('onboarding','rw') then
    raise exception 'pipeline sync requires an admin with onboarding write access' using errcode='42501';
  end if;
  for v_row in
    select b.id from public.businesses b
     where coalesce(b.is_synthetic,false) = false
       and not exists (select 1 from public.sme_prospects p where p.converted_business_id = b.id)
     order by b.created_at, b.id
     limit 200
  loop
    v_prospect := app.v787_ensure_business_prospect(v_row.id);
    if v_prospect is not null then v_registered := v_registered + 1; v_ids := v_ids || v_row.id; end if;
  end loop;
  return jsonb_build_object('registered', v_registered, 'business_ids', to_jsonb(v_ids), 'as_of', clock_timestamp());
end
$function$;

-- An earlier draft of this migration installed an AFTER INSERT trigger; it is removed wherever it exists.
drop trigger if exists zz_businesses_pipeline_record_v787 on public.businesses;
drop function if exists app.v787_business_prospect_trigger();

comment on function app.v787_ensure_business_prospect(uuid) is
  'nestly_v787: idempotent — the CRM record for a live business (Closed lane), created on demand; never touches businesses.source_prospect_id (v79 guard).';
comment on function public.platform_pipeline_sync_live_firms_v787() is
  'nestly_v787: registers every unregistered live business on the Pipeline; called by an admin console as the board loads (no trigger — see header).';

-- Backfill: every existing non-synthetic business, oldest first.
do $$
declare v_row record; v_made integer := 0;
begin
  for v_row in select id from public.businesses where coalesce(is_synthetic, false) = false order by created_at, id loop
    if app.v787_ensure_business_prospect(v_row.id) is not null then v_made := v_made + 1; end if;
  end loop;
  raise notice 'nestly_v787: % live businesses now carry a Pipeline record', v_made;
end $$;

revoke all on function app.v787_ensure_business_prospect(uuid) from public, anon, authenticated;
grant execute on function app.v787_ensure_business_prospect(uuid) to service_role;
revoke all on function public.platform_pipeline_sync_live_firms_v787() from public, anon;
grant execute on function public.platform_pipeline_sync_live_firms_v787() to authenticated, service_role;

commit;
