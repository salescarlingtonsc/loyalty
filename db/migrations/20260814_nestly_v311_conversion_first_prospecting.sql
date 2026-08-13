-- nestly_v311_conversion_first_prospecting
--
-- Owner directive 2026-08-14: the prospecting system exists for ONE purpose —
-- converting non-Peekaa businesses into Peekaa merchants. Not for predicting
-- which lead is good.
--
-- This migration does five things:
--
--   1. MERCHANT IDENTITY. Until now "is this already a Peekaa merchant?" was
--      answered by sme_prospects.converted_business_id, which is only ever set
--      by our own conversion RPC. A business that signed up directly — every one
--      of the 11 merchants live today — was invisible to that check, so Google
--      would rediscover it and a rep would cold-call an existing customer.
--      businesses now carries place_id + postal_code, sme_companies carries the
--      identity link, and a matcher fills both automatically.
--
--   2. UNCERTAIN MATCHES GO TO A HUMAN. A confident match (same Place ID, or
--      same normalized name AND same postal code) links silently. A weaker match
--      (same name, no postal corroboration) is queued for review instead of
--      being applied — a false auto-match silently deletes a real prospect from
--      the sales list, which is worse than a duplicate.
--
--   3. PIPELINE REPLACED. The inherited 19 stages were another business's sales
--      motion (six separate "no pick up" stages, site visits, quotations). They
--      become the owner's lifecycle: prospect → assigned → contacted →
--      interested → appointment → onboarding → merchant, plus six closed states.
--      'client' and 'account_created' survive as HIDDEN system stages because
--      convert_sme_prospect_v79 — which writes subscriptions and is therefore
--      billing-critical — hard-depends on both. Hiding them keeps the rep-facing
--      pipeline at the requested size without touching billing code.
--
--   4. LEAD SCORING DELETED. Explicit owner instruction: no scores, no weights,
--      no signals. We measure conversion instead of predicting it.
--
--   5. DEAD WEIGHT REMOVED. Only what a dependency scan proved unreachable:
--      three tables and eleven functions with zero references from any shipped
--      frontend, edge function, or live RPC. Everything else stays — the other
--      45 sme_* tables are empty because the CRM has not been used in production
--      yet, NOT because they are dead code.

begin;

-- ---------------------------------------------------------------------------
-- 1. Merchant identity on the live merchant table
-- ---------------------------------------------------------------------------
alter table public.businesses
  add column if not exists place_id text,
  add column if not exists postal_code text;

comment on column public.businesses.place_id is
  'Google Place ID of this merchant''s premises. Permanently storable (GMP Service Specific Terms §3) and the strongest key for "is this discovered business already ours?".';

create unique index if not exists businesses_place_id_key
  on public.businesses(place_id) where place_id is not null;

alter table public.sme_companies
  add column if not exists peekaa_business_id uuid references public.businesses(id) on delete set null,
  add column if not exists merchant_linked_at timestamptz,
  add column if not exists merchant_link_basis text;

comment on column public.sme_companies.peekaa_business_id is
  'Identity link: this discovered company IS this Peekaa merchant. Distinct from sme_prospects.converted_business_id, which records that WE converted them. Either one makes the business ineligible for prospecting.';

create index if not exists sme_companies_peekaa_business_idx
  on public.sme_companies(peekaa_business_id) where peekaa_business_id is not null;

-- ---------------------------------------------------------------------------
-- 2. Review queue for uncertain matches
-- ---------------------------------------------------------------------------
create table if not exists public.sme_merchant_match_candidates(
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.sme_companies(id) on delete cascade,
  business_id uuid not null references public.businesses(id) on delete cascade,
  match_basis text not null check (match_basis in ('place_id','name_postal','name_only')),
  status text not null default 'pending' check (status in ('pending','confirmed','rejected')),
  decided_by uuid,
  decided_at timestamptz,
  created_at timestamptz not null default now(),
  unique (company_id, business_id)
);
alter table public.sme_merchant_match_candidates enable row level security;

create index if not exists sme_merchant_match_pending_idx
  on public.sme_merchant_match_candidates(created_at desc) where status='pending';

-- ---------------------------------------------------------------------------
-- 3. The matcher
-- ---------------------------------------------------------------------------
-- Confident basis links immediately; a name-only agreement is queued instead.
-- Reuses app.normalized_business_identity_v79 so this matcher and the existing
-- v79 duplicate-workspace guard agree on what "the same business" means.
create or replace function app.v311_match_merchants(p_company uuid default null)
returns jsonb
language plpgsql
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $function$
declare
  v_linked integer := 0; v_queued integer := 0; r record;
begin
  for r in
    select c.id as company_id,
           c.legal_name, c.trading_name,
           src.source_id as place_id,
           l.postal_code
      from public.sme_companies c
      left join public.sme_company_sources src
             on src.company_id=c.id and src.source='google_places'
      left join public.sme_company_locations l
             on l.company_id=c.id and l.is_primary
     where c.peekaa_business_id is null
       and (p_company is null or c.id = p_company)
  loop
    -- (a) Place ID is exact identity — link without asking.
    update public.sme_companies c
       set peekaa_business_id = b.id, merchant_linked_at = now(), merchant_link_basis = 'place_id'
      from public.businesses b
     where c.id = r.company_id and r.place_id is not null and b.place_id = r.place_id;
    if found then v_linked := v_linked + 1; continue; end if;

    -- (b) Same normalized name AND same postal code — two independent
    --     agreements, treated as confident.
    update public.sme_companies c
       set peekaa_business_id = b.id, merchant_linked_at = now(), merchant_link_basis = 'name_postal'
      from public.businesses b
     where c.id = r.company_id
       and r.postal_code is not null and b.postal_code is not null
       and btrim(r.postal_code) = btrim(b.postal_code)
       and app.normalized_business_identity_v79(coalesce(b.legal_name, b.name))
         = app.normalized_business_identity_v79(coalesce(r.legal_name, r.trading_name));
    if found then v_linked := v_linked + 1; continue; end if;

    -- (c) Name agrees but nothing corroborates it. Queue, do not apply:
    --     "Kim's Kitchen" in Bedok is not "Kim's Kitchen" in Jurong.
    insert into public.sme_merchant_match_candidates(company_id, business_id, match_basis)
    select r.company_id, b.id, 'name_only'
      from public.businesses b
     where app.normalized_business_identity_v79(coalesce(b.legal_name, b.name))
         = app.normalized_business_identity_v79(coalesce(r.legal_name, r.trading_name))
       and coalesce(b.is_demo,false) = false
     on conflict (company_id, business_id) do nothing;
    if found then v_queued := v_queued + 1; end if;
  end loop;

  return jsonb_build_object('linked', v_linked, 'queued_for_review', v_queued);
end $function$;

-- A newly created merchant must immediately stop appearing as a prospect.
create or replace function app.v311_on_business_merchant_link()
returns trigger
language plpgsql
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $function$
begin
  perform app.v311_match_merchants(null);
  return null;
end $function$;

drop trigger if exists businesses_v311_merchant_link on public.businesses;
create trigger businesses_v311_merchant_link
  after insert or update of place_id, postal_code, legal_name, name
  on public.businesses
  for each statement execute function app.v311_on_business_merchant_link();

-- ---------------------------------------------------------------------------
-- 4. The conversion pipeline
-- ---------------------------------------------------------------------------
alter table public.sme_pipeline_stages
  add column if not exists kind text not null default 'active',
  add column if not exists is_system boolean not null default false;

comment on column public.sme_pipeline_stages.kind is
  'active = working the deal | won = a Peekaa merchant | closed = no longer workable';
comment on column public.sme_pipeline_stages.is_system is
  'true = driven by machinery (conversion/billing), hidden from the rep-facing pipeline.';

-- The table was hard-locked to the inherited 19 stages: CHECK (sort_order
-- between 1 and 19), UNIQUE (sort_order), UNIQUE (label). That is why the
-- vocabulary cannot be replaced additively — there is no free slot to write a
-- new stage into until a retired one is removed. Widen the range so the closed
-- states can live in their own numbering band (20+) and the active pipeline
-- keeps room to grow.
alter table public.sme_pipeline_stages
  drop constraint if exists sme_pipeline_stages_sort_order_check;
alter table public.sme_pipeline_stages
  add constraint sme_pipeline_stages_sort_order_check
  check (sort_order >= 1 and sort_order <= 99);

-- Re-point the three existing prospects and their history off the retired keys
-- BEFORE the vocabulary changes, so nothing is orphaned.
update public.sme_prospects set current_stage_key = case current_stage_key
  when 'appt_set' then 'appointment'
  when 'npu_1' then 'no_response'   when 'npu_2' then 'no_response'
  when 'npu_3' then 'no_response'   when 'npu_4' then 'no_response'
  when 'npu_5' then 'no_response'   when 'npu_6' then 'no_response'
  when 'call_back' then 'contacted' when 'reschedule' then 'appointment'
  when 'meeting_sent' then 'appointment' when 'site_visit' then 'appointment'
  when 'quotation_sent' then 'interested' when 'pending_decision' then 'interested'
  else current_stage_key end
where current_stage_key in ('appt_set','npu_1','npu_2','npu_3','npu_4','npu_5','npu_6',
                            'call_back','reschedule','meeting_sent','site_visit',
                            'quotation_sent','pending_decision');

-- sme_prospect_stage_history also carries FKs to the stage vocabulary on BOTH
-- ends, so it has to be remapped before the retired keys can go.
update public.sme_prospect_stage_history set from_stage_key = case from_stage_key
  when 'appt_set' then 'appointment'
  when 'npu_1' then 'no_response'   when 'npu_2' then 'no_response'
  when 'npu_3' then 'no_response'   when 'npu_4' then 'no_response'
  when 'npu_5' then 'no_response'   when 'npu_6' then 'no_response'
  when 'call_back' then 'contacted' when 'reschedule' then 'appointment'
  when 'meeting_sent' then 'appointment' when 'site_visit' then 'appointment'
  when 'quotation_sent' then 'interested' when 'pending_decision' then 'interested'
  else from_stage_key end
where from_stage_key in ('appt_set','npu_1','npu_2','npu_3','npu_4','npu_5','npu_6',
                         'call_back','reschedule','meeting_sent','site_visit',
                         'quotation_sent','pending_decision');

update public.sme_prospect_stage_history set to_stage_key = case to_stage_key
  when 'appt_set' then 'appointment'
  when 'npu_1' then 'no_response'   when 'npu_2' then 'no_response'
  when 'npu_3' then 'no_response'   when 'npu_4' then 'no_response'
  when 'npu_5' then 'no_response'   when 'npu_6' then 'no_response'
  when 'call_back' then 'contacted' when 'reschedule' then 'appointment'
  when 'meeting_sent' then 'appointment' when 'site_visit' then 'appointment'
  when 'quotation_sent' then 'interested' when 'pending_decision' then 'interested'
  else to_stage_key end
where to_stage_key in ('appt_set','npu_1','npu_2','npu_3','npu_4','npu_5','npu_6',
                       'call_back','reschedule','meeting_sent','site_visit',
                       'quotation_sent','pending_decision');

delete from public.sme_stage_entry_requirements
 where stage_key in ('appt_set','npu_1','npu_2','npu_3','npu_4','npu_5','npu_6',
                     'call_back','reschedule','meeting_sent','site_visit',
                     'quotation_sent','pending_decision');

delete from public.sme_pipeline_stages
 where stage_key in ('appt_set','npu_1','npu_2','npu_3','npu_4','npu_5','npu_6',
                     'call_back','reschedule','meeting_sent','site_visit',
                     'quotation_sent','pending_decision');

insert into public.sme_pipeline_stages(stage_key, label, sort_order, kind, is_system) values
  ('new_lead','Prospect',1,'active',false),
  ('assigned','Assigned',2,'active',false),
  ('contacted','Contacted',3,'active',false),
  ('interested','Interested',4,'active',false),
  ('appointment','Appointment',5,'active',false),
  ('client','Deal agreed',6,'active',true),
  ('onboarding','Onboarding',7,'active',false),
  ('account_created','Workspace created',8,'active',true),
  ('activated','Peekaa merchant',9,'won',false),
  ('not_interested','Not interested',20,'closed',false),
  ('no_response','No response',21,'closed',false),
  ('invalid_contact','Invalid contact',22,'closed',false),
  ('closed_business','Closed business',23,'closed',false),
  ('do_not_contact','Do not contact',24,'closed',false),
  ('lost','Lost',25,'closed',false)
on conflict (stage_key) do update
  set label=excluded.label, sort_order=excluded.sort_order,
      kind=excluded.kind, is_system=excluded.is_system;

-- app.validate_stage_entry_v86 raises 'unknown SME stage requirement' for any
-- stage with no requirements row, so every new stage needs one or it would be
-- unreachable. They are deliberately PERMISSIVE (no required evidence keys):
-- the owner asked for a pipeline a rep can update in one tap, not an evidence
-- checklist. The closed states are marked terminal.
insert into public.sme_stage_entry_requirements(
  stage_key, description, required_keys, system_managed, terminal_confirmation, evidence_schema_version) values
  ('assigned','Assigned to a consultant','{}'::text[],false,false,1),
  ('contacted','A contact attempt was made','{}'::text[],false,false,1),
  ('interested','The business expressed interest','{}'::text[],false,false,1),
  ('appointment','A meeting is scheduled','{}'::text[],false,false,1),
  ('not_interested','Declined the offer','{}'::text[],false,true,1),
  ('no_response','No answer after repeated attempts','{}'::text[],false,true,1),
  ('invalid_contact','Contact details do not work','{}'::text[],false,true,1),
  ('closed_business','The business has closed down','{}'::text[],false,true,1),
  ('do_not_contact','Asked not to be contacted again','{}'::text[],false,true,1)
on conflict (stage_key) do update
  set description=excluded.description, required_keys=excluded.required_keys,
      terminal_confirmation=excluded.terminal_confirmation;

-- ---------------------------------------------------------------------------
-- 5. Lead scoring: gone
-- ---------------------------------------------------------------------------
drop function if exists app.v297_refresh_lead_score(uuid);
drop function if exists app.v297_lead_score(uuid);
drop table if exists public.sme_lead_scores;
drop table if exists public.sme_lead_score_weights;

-- ---------------------------------------------------------------------------
-- 6. Proven-unreachable surface only
-- ---------------------------------------------------------------------------
drop function if exists public.platform_assign_prospect_v76(uuid,uuid,bigint,text);
drop function if exists public.platform_get_crm_v156(text,text,integer);
drop function if exists public.platform_get_prospect_workspace_v86(uuid,timestamptz);
drop function if exists public.platform_get_sme_board_v76(uuid);
drop function if exists public.platform_list_prospects_v86(jsonb,timestamptz,integer,timestamptz,uuid);
drop function if exists public.platform_move_prospect_stage_v76(uuid,text,bigint,text,text,jsonb,text);
drop function if exists public.platform_refresh_prospect_quality_v86(uuid);
drop function if exists public.platform_request_prospect_document_read_v86(uuid);
drop function if exists public.platform_reverse_prospect_import_v86(uuid,text);
drop function if exists public.platform_rollback_prospect_import_v86(uuid,text);
drop function if exists public.platform_stage_prospect_import_v86(text,text,jsonb,jsonb,text);

drop table if exists public.sme_import_reversal_rows;
drop table if exists public.sme_import_batch_reversals;
drop table if exists public.sme_data_quality_rule_versions;

-- Link every business that already exists (the whole point of §1).
select app.v311_match_merchants(null);

commit;
