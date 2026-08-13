-- nestly_v317_restore_wrongly_dropped_dependencies
--
-- The v313 cleanup dropped 11 functions and 3 tables based on a scan of what
-- the SHIPPED FRONTEND calls. That scan never asked which functions call EACH
-- OTHER. Two dropped objects had live callers, and both callers were silently
-- broken:
--
--   * public.platform_move_prospect_stage_v76 was dropped, but
--     public.platform_move_prospect_stage_v86 — the function the console
--     actually calls to move a prospect through the pipeline — calls it
--     internally. Moving a prospect through the pipeline was broken from the
--     moment v313 landed.
--
--   * public.sme_import_batch_reversals was dropped, but
--     public.platform_get_import_batch_v86 reads it to report whether a batch
--     has been reversed. Its companion detail table,
--     public.sme_import_reversal_rows, is restored alongside it for the same
--     reason: platform_move_prospect_stage_v76's caller graph and the import
--     batch reversal flow both depend on this pair of tables together.
--
-- A re-scan of the other 14 objects v313 dropped confirmed they genuinely
-- have no caller left in the schema; only these two are restored here.
--
-- Two deliberate corrections are made to the restored function, not a byte-
-- for-byte revival of the pre-v313 body:
--
--   1. The npu_1..npu_6 activity branch is removed. Those pipeline stages no
--      longer exist, so the branch was unreachable dead code even before v313.
--
--   2. The hard-coded system-stage list is replaced by a lookup on
--      public.sme_pipeline_stages.is_system. 'onboarding' is now a normal
--      rep-facing stage, and the old hard-coded list refused every move into
--      it — a second, independent bug that predates v313 and would have
--      resurfaced the moment the table was restored verbatim.
--
-- The restored function definition below is copied EXACTLY as it currently
-- runs in production (confirmed via pg_get_functiondef against
-- gadpooereceldfpfxsod immediately before writing this migration), so it
-- already reflects both corrections.

begin;

create table if not exists public.sme_import_batch_reversals (
  batch_id uuid primary key references public.sme_prospect_import_batches(id) on delete restrict,
  reversed_by uuid references auth.users(id) on delete set null,
  reversed_at timestamptz not null default now(),
  reason text not null check (length(btrim(reason)) between 2 and 1000),
  reversed_insert_rows integer not null check (reversed_insert_rows >= 0),
  unlinked_merge_rows integer not null check (unlinked_merge_rows >= 0)
);

alter table public.sme_import_batch_reversals enable row level security;
revoke all on table public.sme_import_batch_reversals from anon, authenticated;

create table if not exists public.sme_import_reversal_rows (
  batch_id uuid not null references public.sme_prospect_import_batches(id) on delete restrict,
  import_row_id uuid not null references public.sme_prospect_import_rows(id) on delete restrict,
  prior_decision text not null check (prior_decision in ('insert','merge')),
  prior_prospect_id uuid not null,
  prior_company_id uuid,
  prior_source_lineage_id uuid,
  reversed_at timestamptz not null default now(),
  primary key(batch_id,import_row_id)
);

alter table public.sme_import_reversal_rows enable row level security;
revoke all on table public.sme_import_reversal_rows from anon, authenticated;

CREATE OR REPLACE FUNCTION public.platform_move_prospect_stage_v76(p_prospect uuid, p_to_stage text, p_expected_version bigint, p_reason_code text DEFAULT NULL::text, p_reason_detail text DEFAULT NULL::text, p_commercial_terms jsonb DEFAULT NULL::jsonb, p_idempotency_key text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'app', 'pg_temp'
AS $function$
declare
  v_actor uuid:=auth.uid();v_hash text;v_replay jsonb;v_row public.sme_prospects%rowtype;
  v_from text;v_event uuid;v_activity uuid;v_terms_version integer;v_response jsonb;
  v_lost_codes constant text[]:=array[
    'no_response','not_interested','no_budget','timing','chose_competitor',
    'missing_required_feature','procurement_security_blocker','price',
    'internal_priority_changed','business_ceased','duplicate','bad_fit','other'
  ];
begin
  if not app.is_platform_operator_v75() then raise exception 'platform operator access is required' using errcode='42501';end if;
  if not exists(select 1 from public.sme_pipeline_stages where stage_key=p_to_stage) then
    raise exception 'unknown SME stage' using errcode='22023';end if;
  -- System-managed stages are driven by the conversion machinery, never chosen
  -- by hand. Read the flag rather than a hard-coded list, so the guard tracks
  -- the pipeline instead of drifting from it.
  if exists(select 1 from public.sme_pipeline_stages where stage_key=p_to_stage and is_system) then
    raise exception 'this SME stage is system-managed and requires conversion evidence'
      using errcode='42501';end if;
  if p_to_stage='lost' and (p_reason_code is null or not (p_reason_code=any(v_lost_codes))) then
    raise exception 'Lost requires a structured reason code' using errcode='22023';end if;
  if p_to_stage='lost' and p_reason_code='other' and length(btrim(coalesce(p_reason_detail,'')))<3 then
    raise exception 'Lost reason other requires detail' using errcode='22023';end if;
  if p_to_stage='client' and (
    p_commercial_terms is null or jsonb_typeof(p_commercial_terms)<>'object'
    or coalesce(p_commercial_terms->>'plan_code','')=''
    or coalesce(p_commercial_terms->>'product_code','')=''
    or coalesce(p_commercial_terms->>'billing_cycle','') not in ('quarterly','half_yearly','annual')
    or coalesce((p_commercial_terms->>'seats')::integer,0)<=0
    or coalesce(p_commercial_terms->>'currency','')!~'^[A-Z]{3}$'
    or coalesce(p_commercial_terms->>'owner_email','') not like '%@%'
    or coalesce(p_commercial_terms->>'contract_status','') not in ('accepted','signed')
  ) then raise exception 'Client requires accepted commercial fields' using errcode='22023';end if;
  v_hash:=app.v76_sha256_hex(jsonb_build_object('prospect',p_prospect,'to',p_to_stage,
    'version',p_expected_version,'reason_code',p_reason_code,'reason_detail',p_reason_detail,
    'commercial_terms',p_commercial_terms)::text);
  v_replay:=app.v76_replay(v_actor,'move_stage',p_idempotency_key,v_hash);if v_replay is not null then return v_replay;end if;
  select * into v_row from public.sme_prospects where id=p_prospect and version=p_expected_version for update;
  if not found then raise exception 'prospect version conflict' using errcode='40001';end if;
  v_from:=v_row.current_stage_key;
  update public.sme_prospects set current_stage_key=p_to_stage,legacy_stage_raw=null,
    stage_entered_at=now(),version=version+1,updated_by=v_actor,updated_at=now()
   where id=p_prospect returning * into v_row;
  insert into public.sme_prospect_stage_history(prospect_id,from_stage_key,to_stage_key,reason_code,reason_detail,actor)
  values(p_prospect,v_from,p_to_stage,p_reason_code,nullif(btrim(p_reason_detail),''),v_actor) returning id into v_event;
  if p_commercial_terms is not null then
    select coalesce(max(version),0)+1 into v_terms_version from public.sme_commercial_terms where prospect_id=p_prospect;
    insert into public.sme_commercial_terms(
      prospect_id,version,plan_code,product_code,billing_cycle,seats,currency,
      accepted_value_cents,owner_email,onboarding_owner_consultant_id,target_go_live,
      contract_status,accepted_at,notes,created_by
    ) values(p_prospect,v_terms_version,btrim(p_commercial_terms->>'plan_code'),
      btrim(p_commercial_terms->>'product_code'),p_commercial_terms->>'billing_cycle',
      (p_commercial_terms->>'seats')::integer,p_commercial_terms->>'currency',
      coalesce((p_commercial_terms->>'accepted_value_cents')::integer,0),
      lower(btrim(p_commercial_terms->>'owner_email')),
      nullif(p_commercial_terms->>'onboarding_owner_consultant_id','')::uuid,
      nullif(p_commercial_terms->>'target_go_live','')::date,
      p_commercial_terms->>'contract_status',
      case when p_commercial_terms->>'contract_status' in ('accepted','signed')
        then coalesce((p_commercial_terms->>'accepted_at')::timestamptz,now()) else null end,
      p_commercial_terms->>'notes',v_actor);
  end if;
  insert into public.audit_log(business_id,actor,action,entity,entity_id,detail)
  values(null,v_actor,'SME_PROSPECT_STAGE_MOVED_V76','sme_prospects',p_prospect,
    jsonb_build_object('from_stage',v_from,'to_stage',p_to_stage,'reason_code',p_reason_code,
      'new_version',v_row.version,'commercial_terms_version',v_terms_version));
  v_response:=jsonb_build_object('replayed',false,'prospect',app.sme_prospect_card_v76(p_prospect),
    'stage_event',(select to_jsonb(h) from public.sme_prospect_stage_history h where id=v_event),
    'activity',(select to_jsonb(a) from public.sme_prospect_activities a where id=v_activity));
  perform app.v76_store_receipt(v_actor,'move_stage',p_idempotency_key,v_hash,v_response);return v_response;
end
$function$
;

revoke all on function public.platform_move_prospect_stage_v76(uuid,text,bigint,text,text,jsonb,text) from public, anon;
grant execute on function public.platform_move_prospect_stage_v76(uuid,text,bigint,text,text,jsonb,text) to authenticated;

commit;
