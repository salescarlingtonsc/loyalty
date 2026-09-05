-- nestly_v785 rollback suite — the Pipeline: schedule, notes, board and drawer reads.
--
-- Runs inside ONE transaction ending in ROLLBACK, so it is safe against production.
--
-- WHAT IT PROVES
--   01  the two columns exist; the four functions exist with the right volatility and grants
--       (authenticated + service_role, never anon/public).
--   02  app.v785_lane maps every stage into exactly one of the five lanes (+ 'lost').
--   03  as a super admin (Google session): set a schedule — version +1, next_action_at mirrors the
--       appointment, a system activity is written; follow_up_days is counted in SG days.
--   04  a stale version is refused 40001; a stranger is refused 42501 on every function.
--   05  a note with an attachment is written with its detail version; an attachment from another
--       prospect is refused; the same note replays under an idempotency key; the last-edited
--       clock moved.
--   06  the board lists the prospect in the lane its stage maps to, with follow_up_days,
--       consultant name and primary contact; the drawer read carries the note with attachments.

begin;

create temp table _v785(id int generated always as identity, check_name text, ok boolean, detail text) on commit drop;
grant all on _v785 to public;

create or replace function pg_temp.as_v785_user(p_uid uuid, p_role text default 'authenticated')
returns void language plpgsql as $$
begin
  execute format('set local role %I', p_role);
  perform set_config('request.jwt.claim.sub', coalesce(p_uid::text, ''), true);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', p_uid, 'role', p_role,
    'amr', jsonb_build_array(jsonb_build_object('method','oauth')),
    'app_metadata', jsonb_build_object('provider','google','providers',jsonb_build_array('email','google')))::text, true);
end
$$;
grant execute on function pg_temp.as_v785_user(uuid,text) to public;

-- 01 shape
insert into _v785(check_name, ok, detail)
select '01 columns exist', count(*) = 2, string_agg(column_name, ',')
from information_schema.columns where table_schema='public' and table_name='sme_prospects'
  and column_name in ('next_appointment_at','next_follow_up_on');

insert into _v785(check_name, ok, detail)
select '01 functions: volatility as declared',
  bool_and(case p.proname
    when 'platform_pipeline_board_v785' then p.provolatile='s'
    when 'platform_pipeline_prospect_v785' then p.provolatile='s'
    when 'platform_pipeline_set_schedule_v785' then p.provolatile='v'
    when 'platform_pipeline_add_note_v785' then p.provolatile='v'
    when 'v785_lane' then p.provolatile='i' end) and count(*) = 5,
  string_agg(p.proname||'='||p.provolatile::text, ',')
from pg_proc p join pg_namespace n on n.oid=p.pronamespace
where p.proname in ('platform_pipeline_board_v785','platform_pipeline_prospect_v785',
  'platform_pipeline_set_schedule_v785','platform_pipeline_add_note_v785','v785_lane');

insert into _v785(check_name, ok, detail)
select '01 grants: authenticated + service_role yes, anon no',
  has_function_privilege('authenticated','public.platform_pipeline_board_v785(text,uuid,text,integer)','execute')
  and has_function_privilege('authenticated','public.platform_pipeline_prospect_v785(uuid)','execute')
  and has_function_privilege('authenticated','public.platform_pipeline_set_schedule_v785(uuid,bigint,timestamptz,date,text)','execute')
  and has_function_privilege('authenticated','public.platform_pipeline_add_note_v785(uuid,text,jsonb,text)','execute')
  and has_function_privilege('service_role','public.platform_pipeline_board_v785(text,uuid,text,integer)','execute')
  and not has_function_privilege('anon','public.platform_pipeline_board_v785(text,uuid,text,integer)','execute')
  and not has_function_privilege('anon','public.platform_pipeline_add_note_v785(uuid,text,jsonb,text)','execute'),
  'grants checked on four functions';

-- 02 lanes
insert into _v785(check_name, ok, detail)
select '02 every stage maps to one lane',
  app.v785_lane('new_lead')='new_lead' and app.v785_lane('assigned')='new_lead' and app.v785_lane(null)='new_lead'
  and app.v785_lane('contacted')='contact' and app.v785_lane('appointment')='contact'
  and app.v785_lane('interested')='proposal' and app.v785_lane('nurture')='proposal'
  and app.v785_lane('proposal')='pending_decision'
  and app.v785_lane('closed_won')='closed' and app.v785_lane('activated')='closed' and app.v785_lane('onboarding')='closed'
  and app.v785_lane('lost')='lost' and app.v785_lane('not_interested')='lost',
  'owner ruling: proposal = Pending Decision, then Closed';

do $$
declare
  v_company uuid := gen_random_uuid(); v_prospect uuid := gen_random_uuid(); v_other uuid := gen_random_uuid();
  v_other_company uuid := gen_random_uuid();
  v_sa uuid := gen_random_uuid(); v_stranger uuid := gen_random_uuid(); v_consultant uuid := gen_random_uuid();
  v_sa_email text := 'v785-sa-'||replace(v_sa::text,'-','')||'@example.invalid';
  v_doc uuid := gen_random_uuid(); v_doc_other uuid := gen_random_uuid();
  v_logical uuid := gen_random_uuid(); v_logical_other uuid := gen_random_uuid();
  v_out jsonb; v_code text; v_version bigint; v_updated timestamptz; v_note uuid;
  v_follow date := app.sg_today() + 3;
  -- inside the proposal stage's one-day SLA, so next_action_at may mirror it
  v_appt timestamptz := date_trunc('minute', now()) + interval '2 hours';
begin
  insert into auth.users(id, email, instance_id, aud, role, created_at, updated_at, raw_app_meta_data, raw_user_meta_data)
  values (v_sa, v_sa_email, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', now(), now(), '{}'::jsonb, '{}'::jsonb),
         (v_stranger, 'v785-x-'||replace(v_stranger::text,'-','')||'@example.invalid', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', now(), now(), '{}'::jsonb, '{}'::jsonb);
  insert into public.super_admins(user_id, email) values (v_sa, v_sa_email);
  insert into public.platform_consultants(id, user_id, display_name, tier, employment_started_on, active)
  values (v_consultant, v_sa, 'V785 Jeya', 'senior', current_date, true);

  -- sector_key is a foreign key into sector_profiles; the suite does not depend on any one sector.
  insert into public.sme_companies(id, legal_name, trading_name, industry) values
    (v_company, 'V785 JESS SALON PTE. LTD.', 'V785 Jess Salon', 'Beauty & Wellness'),
    (v_other_company, 'V785 OTHER PTE. LTD.', 'V785 Other', 'F&B');
  -- app.v510_prospect_operating_guard: an active lead has an owner or a queue, and a next action
  -- inside the stage SLA.
  insert into public.sme_prospects(id, company_id, current_stage_key, assigned_consultant_id, ownership_state, queue_key, next_action_at, next_action_type) values
    (v_prospect, v_company, 'proposal', v_consultant, 'owned', null, now() + interval '30 minutes', 'follow_up'),
    (v_other, v_other_company, 'new_lead', null, 'queued', 'triage', now() + interval '30 minutes', 'triage');
  insert into public.sme_prospect_contacts(prospect_id, full_name, title, phone, email, is_primary)
  values (v_prospect, 'Sarah Tan', 'Owner', '+65 9123 4567', 'sarah@example.invalid', true);
  -- object_path must be prospects/<prospect>/<logical>/v<n>/<name>, exactly as the v86 vault writes it.
  insert into public.sme_document_versions(id, logical_document_id, version, prospect_id, company_id, document_type, original_filename,
    bucket_id, object_path, mime_type, size_bytes, status, uploaded_by, created_by)
  values (v_doc, v_logical, 1, v_prospect, v_company, 'other', 'quote.pdf', 'sme-private', 'prospects/'||v_prospect||'/'||v_logical||'/v1/quote.pdf', 'application/pdf', 1234, 'verified', v_sa, v_sa),
         (v_doc_other, v_logical_other, 1, v_other, v_other_company, 'other', 'other.pdf', 'sme-private', 'prospects/'||v_other||'/'||v_logical_other||'/v1/other.pdf', 'application/pdf', 99, 'verified', v_sa, v_sa);

  select version, updated_at into v_version, v_updated from public.sme_prospects where id = v_prospect;

  -- 03 schedule
  perform pg_temp.as_v785_user(v_sa);
  v_out := public.platform_pipeline_set_schedule_v785(v_prospect, v_version, v_appt, v_follow, 'Booked by phone');
  reset role;
  insert into _v785(check_name, ok, detail) values ('03 version +1 and both dates stored',
    (v_out->>'version')::bigint = v_version + 1
      and (v_out->>'next_appointment_at')::timestamptz = v_appt and (v_out->>'next_follow_up_on')::date = v_follow,
    v_out::text);
  insert into _v785(check_name, ok, detail) values ('03 next_action_at mirrors an appointment inside the SLA',
    (v_out->>'next_action_at')::timestamptz = v_appt, v_out->>'next_action_at');
  insert into _v785(check_name, ok, detail) values ('03 follow_up_days counted in SG days',
    (v_out->>'follow_up_days')::int = 3, v_out->>'follow_up_days');
  insert into _v785(check_name, ok, detail) values ('03 a system activity was written',
    exists (select 1 from public.sme_prospect_activities a where a.prospect_id = v_prospect and a.activity_type = 'system'
              and a.summary like 'Schedule updated:%' and a.detail = 'Booked by phone'),
    (select string_agg(summary, ' | ') from public.sme_prospect_activities where prospect_id = v_prospect));

  -- 04 refusals
  begin
    perform pg_temp.as_v785_user(v_sa);
    v_out := public.platform_pipeline_set_schedule_v785(v_prospect, v_version, null, null, null); -- stale version
    v_code := 'no error';
  exception when others then v_code := sqlstate;
  end;
  reset role;
  insert into _v785(check_name, ok, detail) values ('04 stale version → 40001', v_code = '40001', 'sqlstate='||v_code);

  begin
    perform pg_temp.as_v785_user(v_stranger);
    v_out := public.platform_pipeline_board_v785('all', null, null, 100);
    v_code := 'no error';
  exception when others then v_code := sqlstate;
  end;
  reset role;
  insert into _v785(check_name, ok, detail) values ('04 stranger board → 42501', v_code = '42501', 'sqlstate='||v_code);
  begin
    perform pg_temp.as_v785_user(v_stranger);
    v_out := public.platform_pipeline_prospect_v785(v_prospect);
    v_code := 'no error';
  exception when others then v_code := sqlstate;
  end;
  reset role;
  insert into _v785(check_name, ok, detail) values ('04 stranger drawer → 42501', v_code = '42501', 'sqlstate='||v_code);
  begin
    perform pg_temp.as_v785_user(v_stranger);
    v_out := public.platform_pipeline_add_note_v785(v_prospect, 'hello', '[]'::jsonb, null);
    v_code := 'no error';
  exception when others then v_code := sqlstate;
  end;
  reset role;
  insert into _v785(check_name, ok, detail) values ('04 stranger note → 42501', v_code = '42501', 'sqlstate='||v_code);

  -- 05 notes
  select updated_at into v_updated from public.sme_prospects where id = v_prospect;
  perform pg_temp.as_v785_user(v_sa);
  v_out := public.platform_pipeline_add_note_v785(v_prospect, 'Client wants to discuss with partner.',
    jsonb_build_array(jsonb_build_object('document_version_id', v_doc, 'original_filename', 'quote.pdf', 'mime_type', 'application/pdf', 'size_bytes', 1234)),
    'idem-v785-1');
  reset role;
  v_note := (v_out->>'activity_id')::uuid;
  insert into _v785(check_name, ok, detail) values ('05 note written with one attachment',
    (v_out->>'attachment_count')::int = 1 and (v_out->>'replayed')::boolean = false
      and exists (select 1 from public.sme_prospect_activities a where a.id = v_note and a.activity_type = 'note' and a.detail = 'Client wants to discuss with partner.')
      and exists (select 1 from public.sme_activity_detail_versions d where d.activity_id = v_note and d.attachments->0->>'document_version_id' = v_doc::text),
    v_out::text);
  insert into _v785(check_name, ok, detail) values ('05 the last-edited clock moved',
    (select updated_at from public.sme_prospects where id = v_prospect) >= v_updated
      and (select version from public.sme_prospects where id = v_prospect) = v_version + 2,
    'version='||(select version from public.sme_prospects where id = v_prospect));
  perform pg_temp.as_v785_user(v_sa);
  v_out := public.platform_pipeline_add_note_v785(v_prospect, 'Client wants to discuss with partner.', '[]'::jsonb, 'idem-v785-1');
  reset role;
  insert into _v785(check_name, ok, detail) values ('05 same note replays under the key',
    (v_out->>'replayed')::boolean = true and (v_out->>'activity_id')::uuid = v_note, v_out::text);
  begin
    perform pg_temp.as_v785_user(v_sa);
    v_out := public.platform_pipeline_add_note_v785(v_prospect, 'wrong doc',
      jsonb_build_array(jsonb_build_object('document_version_id', v_doc_other)), null);
    v_code := 'no error';
  exception when others then v_code := sqlstate;
  end;
  reset role;
  insert into _v785(check_name, ok, detail) values ('05 another prospect''s document → 22023', v_code = '22023', 'sqlstate='||v_code);
  begin
    perform pg_temp.as_v785_user(v_sa);
    v_out := public.platform_pipeline_add_note_v785(v_prospect, '   ', '[]'::jsonb, null);
    v_code := 'no error';
  exception when others then v_code := sqlstate;
  end;
  reset role;
  insert into _v785(check_name, ok, detail) values ('05 empty note → 22023', v_code = '22023', 'sqlstate='||v_code);

  -- 06 board + drawer
  perform pg_temp.as_v785_user(v_sa);
  v_out := public.platform_pipeline_board_v785('all', null, 'V785 Jess', 100);
  reset role;
  insert into _v785(check_name, ok, detail) values ('06 board: the prospect sits in pending_decision with its schedule',
    exists (select 1 from jsonb_array_elements(v_out->'items') x
             where x->>'id' = v_prospect::text and x->>'lane' = 'pending_decision'
               and (x->>'follow_up_days')::int = 3 and x->>'consultant_name' = 'V785 Jeya'
               and x->'primary_contact'->>'full_name' = 'Sarah Tan'
               and x->>'company_name' = 'V785 Jess Salon'
               and x->'last_activity'->>'activity_type' = 'note'),
    (select x::text from jsonb_array_elements(v_out->'items') x where x->>'id' = v_prospect::text));
  insert into _v785(check_name, ok, detail) values ('06 board: self consultant and consultant list present',
    v_out->>'self_consultant' = v_consultant::text and jsonb_array_length(v_out->'consultants') >= 1 and v_out->>'scope' = 'all',
    'self='||coalesce(v_out->>'self_consultant','<null>'));
  perform pg_temp.as_v785_user(v_sa);
  v_out := public.platform_pipeline_board_v785('mine', null, null, 100);
  reset role;
  insert into _v785(check_name, ok, detail) values ('06 board: mine = the firms assigned to me',
    v_out->>'scope' = 'mine' and (select bool_and(x->>'assigned_consultant_id' = v_consultant::text) from jsonb_array_elements(v_out->'items') x)
      and exists (select 1 from jsonb_array_elements(v_out->'items') x where x->>'id' = v_prospect::text),
    'n='||jsonb_array_length(v_out->'items'));
  perform pg_temp.as_v785_user(v_sa);
  v_out := public.platform_pipeline_prospect_v785(v_prospect);
  reset role;
  insert into _v785(check_name, ok, detail) values ('06 drawer: note carries its attachment, documents visible to the super admin',
    exists (select 1 from jsonb_array_elements(v_out->'activities') a where a->>'id' = v_note::text
              and a->'attachments'->0->>'original_filename' = 'quote.pdf')
      and (v_out->>'documents_visible')::boolean and jsonb_array_length(v_out->'documents') = 1
      and v_out->'prospect'->>'lane' = 'pending_decision' and jsonb_array_length(v_out->'contacts') = 1,
    left(v_out::text, 400));
end
$$;

select check_name, ok, detail from _v785 order by id;
select count(*) filter (where not ok) as failures, count(*) as checks from _v785;

rollback;
