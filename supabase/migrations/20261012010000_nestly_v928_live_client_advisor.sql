-- nestly_v928 — a live client's advisor can be changed, without unfreezing anything else.
--
-- WHAT v922 GOT WRONG, found by driving the deployed console rather than by reading the writer.
-- v922 un-hid the "Change advisor" control for a converted firm on the reasoning that
-- platform_transfer_lead_v510's stage/queue side effects are all guarded by
-- `when current_stage_key='new_lead'`, so on a live client it would only reassign and audit. That
-- reading of the FUNCTION was right and still incomplete: public.sme_prospects carries a TABLE
-- trigger, app.guard_converted_prospect_v79, which refuses any UPDATE that changes
-- current_stage_key, assigned_consultant_id or company_id once converted_business_id is set —
-- unless the v79 onboarding GUC is on. So the control appeared and every save returned
-- 42501 'converted prospect lifecycle is controlled by v79 onboarding'.
--
-- WHY THE GUARD IS RIGHT AND STAYS. A live client's SALES STAGE is owned by v79 onboarding, not by
-- whoever has the record open; letting the console move it would put two authorities on one fact.
-- The guard's mistake is only that it freezes the advisor along with the stage — and the advisor
-- is precisely the thing that has to stay changeable, because app.assigned_consultant_v94 reads
-- sme_prospects.assigned_consultant_id to decide which consultant may read that firm's reports.
-- Staff leave; a firm's advisor outlives its onboarding.
--
-- WHAT THIS DOES. Not a loosened guard — a second, narrower door beside it:
--
--   app.guard_converted_prospect_v79 now lets an UPDATE through when, and only when, ALL of:
--     * current_stage_key is unchanged,
--     * company_id is unchanged,
--     * assigned_consultant_id is the thing that changed, and
--     * app.v928_advisor_change is 'on'.
--   Anything else on a converted row raises exactly as before. A caller holding this GUC cannot
--   move a stage, so the v79 authority is untouched. It is deliberately NOT the v79 GUC: reusing
--   that one would have handed every advisor change the power to move the lifecycle too.
--
--   public.platform_set_firm_advisor_v928(business, consultant, reason) is the only thing that
--   sets it — super-admin, one transaction, `set_config(..., true)` so it cannot leak past the
--   statement, writing assigned_consultant_id and nothing else. It does NOT touch
--   current_stage_key, ownership_state or queue_key: a live client is not sitting in a sales
--   queue, and v510's queue bookkeeping would be a lie on a converted record.
--
--   Passing a NULL consultant unassigns, which is how a departing advisor is removed. Assignments
--   are recorded in sme_prospect_assignments (which needs a consultant, so an unassign writes the
--   audit row only) and every call writes public.audit_log either way.
--
-- Rollback suite: db/tests/v928_live_client_advisor.sql

begin;

-- ---------------------------------------------------------------------------------------------
-- 1. The guard gains one exception, scoped to the advisor and nothing else.
-- ---------------------------------------------------------------------------------------------
create or replace function app.guard_converted_prospect_v79()
returns trigger
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
begin
  -- nestly_v928: an advisor-only change, carrying its own GUC, is allowed through. Stage and
  -- company must both be untouched for this arm to apply, so it can never become a stage move.
  if old.converted_business_id is not null
     and new.current_stage_key is not distinct from old.current_stage_key
     and new.company_id is not distinct from old.company_id
     and new.assigned_consultant_id is distinct from old.assigned_consultant_id
     and coalesce(current_setting('app.v928_advisor_change', true), '') = 'on' then
    return new;
  end if;
  if old.converted_business_id is not null and (
    new.current_stage_key is distinct from old.current_stage_key
    or new.assigned_consultant_id is distinct from old.assigned_consultant_id
    or new.company_id is distinct from old.company_id
  ) and coalesce(current_setting('app.v79_system_transition',true),'')<>'on' then
    raise exception 'converted prospect lifecycle is controlled by v79 onboarding' using errcode='42501';
  end if;
  return new;
end
$$;

comment on function app.guard_converted_prospect_v79() is
  'nestly_v79 + v928: a converted prospect''s stage, advisor and company are frozen against ordinary writes. v79 onboarding passes app.v79_system_transition; an advisor-only change passes app.v928_advisor_change and can change nothing else.';

-- ---------------------------------------------------------------------------------------------
-- 2. The only caller that may set that GUC.
-- ---------------------------------------------------------------------------------------------
create or replace function public.platform_set_firm_advisor_v928(
  p_business uuid,
  p_consultant uuid,
  p_reason text
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_actor uuid := auth.uid();
  v_prospect public.sme_prospects%rowtype;
  v_before uuid;
  v_name text;
begin
  if v_actor is null or not app.is_super_admin() then
    raise exception 'super_admin_required' using errcode = '42501';
  end if;
  if length(btrim(coalesce(p_reason, ''))) not between 3 and 1000 then
    raise exception 'advisor_change_reason_required' using errcode = '22023';
  end if;

  select * into v_prospect
  from public.sme_prospects prospect
  where prospect.converted_business_id = p_business
    and prospect.archived_at is null
  order by prospect.converted_at nulls last, prospect.id
  limit 1
  for update;
  if v_prospect.id is null then
    raise exception 'no live client record exists for this business' using errcode = '42704';
  end if;

  if p_consultant is not null then
    select consultant.display_name into v_name
    from public.platform_consultants consultant
    where consultant.id = p_consultant and consultant.active;
    if v_name is null then
      raise exception 'active consultant was not found' using errcode = '22023';
    end if;
  end if;

  v_before := v_prospect.assigned_consultant_id;
  if v_before is not distinct from p_consultant then
    -- Nothing to do, and saying so beats writing an audit row that records no change.
    return jsonb_build_object('status','unchanged','prospect_id',v_prospect.id,
      'business_id',p_business,'consultant_id',p_consultant,'version',v_prospect.version);
  end if;

  perform set_config('app.v928_advisor_change', 'on', true);
  update public.sme_prospects
     set assigned_consultant_id = p_consultant,
         owner_assigned_at = case when p_consultant is null then null else clock_timestamp() end,
         version = version + 1,
         updated_by = v_actor,
         updated_at = clock_timestamp()
   where id = v_prospect.id
  returning * into v_prospect;
  perform set_config('app.v928_advisor_change', 'off', true);

  if p_consultant is not null then
    insert into public.sme_prospect_assignments(prospect_id,consultant_id,assigned_by,reason)
    values (v_prospect.id, p_consultant, v_actor, btrim(p_reason));
  end if;

  insert into public.audit_log(business_id,actor,action,entity,entity_id,detail)
  values (p_business, v_actor, 'firm_advisor_changed', 'sme_prospects', v_prospect.id,
    jsonb_build_object(
      'source','platform_console_v928',
      'reason', btrim(p_reason),
      'from_consultant', v_before,
      'to_consultant', p_consultant,
      'to_consultant_name', v_name));

  return jsonb_build_object('status','ok','prospect_id',v_prospect.id,'business_id',p_business,
    'consultant_id',p_consultant,'consultant_name',v_name,'version',v_prospect.version);
end
$$;

comment on function public.platform_set_firm_advisor_v928(uuid, uuid, text) is
  'nestly_v928: super-admin sets or clears the advisor on a LIVE client (a converted prospect), through the advisor-only exception in app.guard_converted_prospect_v79. Changes assigned_consultant_id and nothing else; never moves the sales stage.';

revoke all on function public.platform_set_firm_advisor_v928(uuid, uuid, text) from public, anon;
grant execute on function public.platform_set_firm_advisor_v928(uuid, uuid, text) to authenticated, service_role;

commit;
