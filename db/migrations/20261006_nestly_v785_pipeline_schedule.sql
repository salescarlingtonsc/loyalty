-- nestly_v785 — the Pipeline: a firm's next appointment, next follow-up and notes, for the
-- platform console's new CRM home.
--
-- OWNER, 2026-09-05 (three photos, four rulings): "create a new module 'Pipeline' ... inside will
-- manage everything on CRM". Photo 2 is the look (Peekaa red, five lanes, a business drawer);
-- photo 3 is what the drawer must carry — NEXT APPOINTMENT (with a time, synced to a calendar),
-- NEXT FOLLOW-UP (a date, shown on the card as "Due in 7D / Due tomorrow / Due today / Overdue
-- 2D") and LAST EDITED ("not last contacted — based on any change done to this exact business").
-- Notes take text and attached documents, each with its timestamp. Everything is Asia/Singapore.
-- Rulings: proposal = the Pending Decision lane, then Closed; Pipeline replaces the Onboarding
-- board as the CRM home; calendar = the console's own list plus an .ics file (no OAuth yet).
--
-- WHAT THIS ADDS
--   sme_prospects.next_appointment_at  timestamptz — the meeting, with its time.
--   sme_prospects.next_follow_up_on    date        — the follow-up day (SG calendar day).
--   Both are OWNER-FACING facts on the prospect itself. next_action_at (v76) stays and is kept in
--   step (the appointment if set, else the follow-up at 09:00 SGT) whenever that lands inside the
--   stage's operating SLA (app.v510_prospect_operating_guard refuses anything later), so older
--   screens keep agreeing with the new one wherever they can.
--   updated_at is already the "last edited" clock: every write here bumps it and the version.
--
--   app.v785_lane(stage)                         the five-lane mapping — ONE authority, read by the
--                                                console, never re-derived there.
--   platform_pipeline_board_v785(...)            STABLE read: every scoped prospect as a card with
--                                                lane, schedule, owner, contact, last activity,
--                                                follow_up_days (SG), payment_due; the consultant
--                                                list; who "mine" is. KPIs are counted client-side
--                                                from the same rows so they can never disagree.
--   platform_pipeline_prospect_v785(p_prospect)  STABLE read: one prospect for the drawer —
--                                                company, contacts, activities (with attachments),
--                                                tasks, documents (sensitive scope only), the
--                                                converted business and its branches.
--   platform_pipeline_set_schedule_v785(...)     write: the two dates (+ next_action_at mirror),
--                                                optimistic version, a system activity line.
--   platform_pipeline_add_note_v785(...)         write: a 'note' activity with its attachments
--                                                (document versions uploaded through the v86
--                                                vault) in sme_activity_detail_versions.attachments.
--
-- SCOPE (unchanged from the CRM): app.v89_platform_can('onboarding', r|rw) plus
-- app.v89_can_access_prospect — a super admin and an admin see every firm; sales_staff see the firms
-- assigned to them. Documents follow app.can_access_prospect_sensitive_v86 exactly as v86 does.

begin;

alter table public.sme_prospects
  add column if not exists next_appointment_at timestamptz,
  add column if not exists next_follow_up_on date;

comment on column public.sme_prospects.next_appointment_at is
  'nestly_v785: the next appointment with this firm, with its time (Asia/Singapore in the UI). Synced to the console calendar list and exported as .ics.';
comment on column public.sme_prospects.next_follow_up_on is
  'nestly_v785: the next follow-up day (SG calendar day). Cards show it as Due in N D / Due today / Overdue N D.';

create index if not exists sme_prospects_v785_follow_up_idx
  on public.sme_prospects(next_follow_up_on) where archived_at is null;
create index if not exists sme_prospects_v785_appointment_idx
  on public.sme_prospects(next_appointment_at) where archived_at is null;

-- ---------------------------------------------------------------------------------------------
-- The five lanes. Owner 2026-09-05: "proposal = Pending Decision -> afterwards will be Closed".
-- 'NPU / Proposal' is the lane between the meeting and the sent proposal: interested firms a
-- proposal is being prepared for, and the ones parked to nurture. Anything closed without a win
-- reports 'lost' and the console shows it inside Closed, marked.
-- ---------------------------------------------------------------------------------------------
create or replace function app.v785_lane(p_stage text)
returns text
language sql
immutable
as $function$
  select case
    when p_stage is null or p_stage in ('new_lead','assigned') then 'new_lead'
    when p_stage in ('contacted','appointment') then 'contact'
    when p_stage in ('interested','nurture') then 'proposal'
    when p_stage = 'proposal' then 'pending_decision'
    when p_stage in ('closed_won','client','account_created','onboarding','activated') then 'closed'
    else 'lost'
  end
$function$;

-- ---------------------------------------------------------------------------------------------
-- The board.
-- ---------------------------------------------------------------------------------------------
create or replace function public.platform_pipeline_board_v785(
  p_scope text default 'all',
  p_consultant uuid default null,
  p_search text default null,
  p_limit integer default 400
)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $function$
declare
  v_role text := app.v89_platform_role();
  v_self uuid := app.v226_self_consultant();
  v_filter uuid;
  v_scope text;
  v_limit integer := least(greatest(coalesce(p_limit,400),1),1000);
  v_today date := app.sg_today();
  v_items jsonb;
begin
  if auth.uid() is null or v_role is null or not app.v89_platform_can('onboarding','r') then
    raise exception 'pipeline access is required' using errcode='42501';
  end if;
  if v_role = 'sales_staff' then
    if p_consultant is not null and p_consultant is distinct from v_self then
      raise exception 'a consultant may only read their own assigned firms' using errcode='42501';
    end if;
    v_scope := 'own'; v_filter := v_self;
    if v_self is null then
      return jsonb_build_object('items','[]'::jsonb,'scope','own','consultant_unlinked',true,
        'self_consultant',null,'consultant',null,'consultants','[]'::jsonb,'today',v_today,
        'as_of',clock_timestamp());
    end if;
  elsif coalesce(p_scope,'all') = 'mine' then
    v_scope := 'mine'; v_filter := v_self;
    if v_self is null then
      return jsonb_build_object('items','[]'::jsonb,'scope','mine','consultant_unlinked',true,
        'self_consultant',null,'consultant',null,'today',v_today,'as_of',clock_timestamp(),
        'consultants',coalesce((select jsonb_agg(jsonb_build_object('id',c.id,'display_name',c.display_name) order by c.display_name)
          from public.platform_consultants c where c.active),'[]'::jsonb));
    end if;
  else
    v_scope := 'all'; v_filter := p_consultant;
  end if;

  select jsonb_agg(jsonb_build_object(
      'id', s.id, 'prospect_id', s.id, 'company_id', s.company_id,
      'company_name', coalesce(s.trading_name, s.legal_name, 'Unnamed prospect'),
      'legal_name', s.legal_name, 'trading_name', s.trading_name,
      'sector_key', s.sector_key, 'industry', s.industry,
      'current_stage_key', s.current_stage_key, 'lane', app.v785_lane(s.current_stage_key),
      'version', s.version, 'priority', s.priority, 'region', s.region,
      'assigned_consultant_id', s.assigned_consultant_id, 'consultant_name', s.consultant_name,
      'next_action_at', s.next_action_at, 'next_action_type', s.next_action_type,
      'next_appointment_at', s.next_appointment_at, 'next_follow_up_on', s.next_follow_up_on,
      'follow_up_days', case when s.next_follow_up_on is null then null else (s.next_follow_up_on - v_today) end,
      'last_contact_at', s.last_contact_at, 'updated_at', s.updated_at, 'created_at', s.created_at,
      'stage_entered_at', s.stage_entered_at,
      'converted_business_id', s.business_id, 'business_name', s.business_name,
      'branch_count', case when s.business_id is null then s.location_count else s.branch_count end,
      'payment_due', s.payment_due,
      'next_task', s.next_task, 'primary_contact', s.primary_contact, 'last_activity', s.last_activity)
    order by (s.next_follow_up_on is null), s.next_follow_up_on, s.updated_at desc)
  into v_items
  from (
    select prospect.id, prospect.company_id, prospect.current_stage_key, prospect.version, prospect.priority,
      prospect.region, prospect.assigned_consultant_id, prospect.next_action_at, prospect.next_action_type,
      prospect.next_appointment_at, prospect.next_follow_up_on, prospect.last_contact_at, prospect.updated_at,
      prospect.created_at, prospect.stage_entered_at,
      company.legal_name, company.trading_name, company.sector_key, company.industry,
      consultant.display_name consultant_name,
      business.id business_id, business.name business_name,
      (select count(*) from public.branches b where b.business_id = business.id) branch_count,
      (select count(*) from public.sme_company_locations l where l.company_id = company.id) location_count,
      (business.id is not null and (
         exists (select 1 from public.branches b where b.business_id = business.id and b.billing_state in ('pending_payment','suspended'))
         or exists (select 1 from public.billing_provider_invoices i where i.business_id = business.id
                      and coalesce(i.amount_remaining_cents,0) > 0 and i.status not in ('paid','void','voided','uncollectible')))) payment_due,
      (select jsonb_build_object('id', t.id, 'title', t.title, 'due_at', t.due_at)
         from public.sme_prospect_tasks t where t.prospect_id = prospect.id and t.status = 'open'
         order by t.due_at nulls last, t.created_at limit 1) next_task,
      (select jsonb_build_object('id', c.id, 'full_name', c.full_name, 'title', c.title, 'phone', c.phone,
                                 'email', c.email, 'whatsapp_number', c.whatsapp_number)
         from public.sme_prospect_contacts c where c.prospect_id = prospect.id and c.active
         order by c.is_primary desc, c.created_at limit 1) primary_contact,
      (select jsonb_build_object('id', a.id, 'activity_type', a.activity_type, 'summary', a.summary, 'occurred_at', a.occurred_at)
         from public.sme_prospect_activities a where a.prospect_id = prospect.id
         order by a.occurred_at desc, a.id desc limit 1) last_activity
    from public.sme_prospects prospect
    join public.sme_companies company on company.id = prospect.company_id
    left join public.platform_consultants consultant on consultant.id = prospect.assigned_consultant_id
    left join public.businesses business on business.id = prospect.converted_business_id
    where prospect.archived_at is null and prospect.merged_into_prospect_id is null
      and (v_filter is null or prospect.assigned_consultant_id = v_filter)
      and app.sme_prospect_search_match_v76(prospect.id, p_search)
    order by (prospect.next_follow_up_on is null), prospect.next_follow_up_on, prospect.updated_at desc
    limit v_limit
  ) s;

  return jsonb_build_object(
    'items', coalesce(v_items, '[]'::jsonb),
    'scope', v_scope, 'role', v_role, 'consultant', v_filter, 'self_consultant', v_self,
    'consultant_unlinked', false, 'today', v_today, 'as_of', clock_timestamp(),
    'consultants', case when v_role = 'sales_staff' then '[]'::jsonb else coalesce((
        select jsonb_agg(jsonb_build_object('id', c.id, 'display_name', c.display_name,
          'n', (select count(*) from public.sme_prospects p where p.archived_at is null and p.assigned_consultant_id = c.id))
          order by c.display_name)
        from public.platform_consultants c where c.active), '[]'::jsonb) end
  );
end
$function$;

-- ---------------------------------------------------------------------------------------------
-- One prospect, for the drawer.
-- ---------------------------------------------------------------------------------------------
create or replace function public.platform_pipeline_prospect_v785(p_prospect uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $function$
declare
  v_prospect public.sme_prospects%rowtype;
  v_sensitive boolean;
begin
  if p_prospect is null then
    raise exception 'prospect is required' using errcode='22023';
  end if;
  if auth.uid() is null or not app.v89_platform_can('onboarding','r') or not app.v89_can_access_prospect(p_prospect) then
    raise exception 'scoped pipeline read access is required' using errcode='42501';
  end if;
  select * into v_prospect from public.sme_prospects where id = p_prospect;
  if not found then
    raise exception 'prospect not found' using errcode='P0002';
  end if;
  v_sensitive := app.can_access_prospect_sensitive_v86(p_prospect);

  return jsonb_build_object(
    'as_of', clock_timestamp(), 'today', app.sg_today(),
    'prospect', to_jsonb(v_prospect) || jsonb_build_object('lane', app.v785_lane(v_prospect.current_stage_key)),
    'company', (select to_jsonb(c) from public.sme_companies c where c.id = v_prospect.company_id),
    'consultant', (select jsonb_build_object('id', c.id, 'display_name', c.display_name, 'active', c.active)
                     from public.platform_consultants c where c.id = v_prospect.assigned_consultant_id),
    'contacts', coalesce((select jsonb_agg(to_jsonb(c) order by c.is_primary desc, c.created_at, c.id)
                            from public.sme_prospect_contacts c where c.prospect_id = p_prospect and c.active), '[]'::jsonb),
    'activities', coalesce((select jsonb_agg(to_jsonb(page) order by page.occurred_at desc, page.id desc) from (
        select a.*, (select d.attachments from public.sme_activity_detail_versions d
                       where d.activity_id = a.id order by d.version desc limit 1) attachments
        from public.sme_prospect_activities a where a.prospect_id = p_prospect
        order by a.occurred_at desc, a.id desc limit 200) page), '[]'::jsonb),
    'tasks', coalesce((select jsonb_agg(to_jsonb(t) order by (t.status <> 'open'), t.due_at nulls last, t.created_at desc)
                         from (select * from public.sme_prospect_tasks where prospect_id = p_prospect
                               order by (status <> 'open'), due_at nulls last, created_at desc limit 50) t), '[]'::jsonb),
    'documents', case when v_sensitive then coalesce((select jsonb_agg(jsonb_build_object(
          'id', d.id, 'logical_document_id', d.logical_document_id, 'version', d.version,
          'document_type', d.document_type, 'original_filename', d.original_filename,
          'mime_type', d.mime_type, 'size_bytes', d.size_bytes, 'status', d.status, 'created_at', d.created_at)
          order by d.created_at desc, d.id desc)
        from public.sme_document_versions d where d.prospect_id = p_prospect), '[]'::jsonb) else '[]'::jsonb end,
    'documents_visible', v_sensitive,
    'business', (select jsonb_build_object('id', b.id, 'name', b.name, 'slug', b.slug, 'industry', b.industry,
        'branches', coalesce((select jsonb_agg(jsonb_build_object('id', br.id, 'name', br.name, 'is_default', br.is_default,
            'active', br.active, 'billing_state', br.billing_state, 'address', br.address)
            order by br.is_default desc, br.created_at, br.name)
          from public.branches br where br.business_id = b.id), '[]'::jsonb))
      from public.businesses b where b.id = v_prospect.converted_business_id),
    'stage_history', coalesce((select jsonb_agg(to_jsonb(h) order by h.occurred_at desc)
        from (select * from public.sme_prospect_stage_history where prospect_id = p_prospect
              order by occurred_at desc limit 30) h), '[]'::jsonb)
  );
end
$function$;

-- ---------------------------------------------------------------------------------------------
-- The schedule: next appointment (with time) and next follow-up (a day).
-- ---------------------------------------------------------------------------------------------
create or replace function public.platform_pipeline_set_schedule_v785(
  p_prospect uuid,
  p_expected_version bigint,
  p_next_appointment_at timestamptz,
  p_next_follow_up_on date,
  p_note text default null
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $function$
declare
  v_actor uuid := auth.uid();
  v_row public.sme_prospects%rowtype;
  v_mirror timestamptz;
  v_sla interval;
  v_summary text;
begin
  if v_actor is null or not app.v89_platform_can('onboarding','rw') or not app.v89_can_access_prospect(p_prospect) then
    raise exception 'scoped pipeline write access is required' using errcode='42501';
  end if;
  perform app.v184_assert_prospect_active(p_prospect);
  -- next_action_at is the older readers' fact; it follows the appointment when there is one, else
  -- the follow-up day at 09:00 Asia/Singapore — but ONLY inside the stage's operating SLA, which
  -- app.v510_prospect_operating_guard enforces on every row. A follow-up the owner sets seven days
  -- out on a one-day-SLA stage is theirs to set; the SLA clock (next_action_at) is left where it is.
  v_mirror := coalesce(p_next_appointment_at,
    case when p_next_follow_up_on is null then null
         else (p_next_follow_up_on::timestamp + interval '9 hours') at time zone 'Asia/Singapore' end);
  select stage.operating_sla into v_sla
    from public.sme_prospects prospect
    left join public.sme_pipeline_stages stage on stage.stage_key = prospect.current_stage_key
   where prospect.id = p_prospect;
  update public.sme_prospects set
    next_appointment_at = p_next_appointment_at,
    next_follow_up_on = p_next_follow_up_on,
    next_action_at = case when v_mirror is not null and (v_sla is null or v_mirror <= clock_timestamp() + v_sla)
                          then v_mirror else next_action_at end,
    version = version + 1, updated_by = v_actor, updated_at = now()
  where id = p_prospect and version = p_expected_version
  returning * into v_row;
  if not found then
    raise exception 'prospect version conflict' using errcode='40001';
  end if;
  v_summary := concat_ws(' · ',
    case when p_next_appointment_at is null then 'No appointment'
         else 'Appointment ' || to_char(p_next_appointment_at at time zone 'Asia/Singapore', 'DD Mon YYYY HH24:MI') end,
    case when p_next_follow_up_on is null then 'No follow-up'
         else 'Follow-up ' || to_char(p_next_follow_up_on, 'DD Mon YYYY') end);
  insert into public.sme_prospect_activities(prospect_id, consultant_id, activity_type, summary, detail, occurred_at, created_by)
  values (p_prospect, app.v226_self_consultant(), 'system', left('Schedule updated: ' || v_summary, 240),
          nullif(btrim(coalesce(p_note,'')),''), now(), v_actor);
  return jsonb_build_object('id', v_row.id, 'version', v_row.version,
    'next_appointment_at', v_row.next_appointment_at, 'next_follow_up_on', v_row.next_follow_up_on,
    'next_action_at', v_row.next_action_at, 'updated_at', v_row.updated_at,
    'follow_up_days', case when v_row.next_follow_up_on is null then null else (v_row.next_follow_up_on - app.sg_today()) end);
end
$function$;

-- ---------------------------------------------------------------------------------------------
-- A note, with its attachments.
-- p_attachments: [{document_version_id, logical_document_id, original_filename, mime_type, size_bytes}]
-- — each one a document already uploaded and verified through the v86 vault for THIS prospect.
-- A document version that belongs to another prospect is refused rather than linked.
-- ---------------------------------------------------------------------------------------------
create or replace function public.platform_pipeline_add_note_v785(
  p_prospect uuid,
  p_body text,
  p_attachments jsonb default '[]'::jsonb,
  p_idempotency_key text default null
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $function$
declare
  v_actor uuid := auth.uid();
  v_body text := btrim(coalesce(p_body,''));
  v_attachments jsonb := coalesce(p_attachments,'[]'::jsonb);
  v_activity public.sme_prospect_activities%rowtype;
  v_summary text;
  v_foreign integer;
begin
  if v_actor is null or not app.v89_platform_can('onboarding','rw') or not app.v89_can_access_prospect(p_prospect) then
    raise exception 'scoped pipeline write access is required' using errcode='42501';
  end if;
  perform app.v184_assert_prospect_active(p_prospect);
  if jsonb_typeof(v_attachments) <> 'array' then
    raise exception 'attachments must be an array' using errcode='22023';
  end if;
  if length(v_body) < 1 and jsonb_array_length(v_attachments) = 0 then
    raise exception 'a note needs text or an attachment' using errcode='22023';
  end if;
  if length(v_body) > 4000 then
    raise exception 'a note is at most 4000 characters' using errcode='22023';
  end if;
  select count(*) into v_foreign
    from jsonb_array_elements(v_attachments) att
    where not exists (select 1 from public.sme_document_versions d
                       where d.id = nullif(att->>'document_version_id','')::uuid and d.prospect_id = p_prospect);
  if v_foreign > 0 then
    raise exception 'attachment does not belong to this prospect' using errcode='22023';
  end if;
  -- A double-tap replays the same note rather than writing it twice.
  if p_idempotency_key is not null then
    select * into v_activity from public.sme_prospect_activities a
     where a.prospect_id = p_prospect and a.activity_type = 'note' and a.created_by = v_actor
       and a.created_at > now() - interval '10 minutes'
       and coalesce(a.detail,'') = v_body
     order by a.created_at desc limit 1;
    if found then
      return jsonb_build_object('activity_id', v_activity.id, 'occurred_at', v_activity.occurred_at, 'replayed', true);
    end if;
  end if;
  v_summary := left(regexp_replace(v_body, '\s+', ' ', 'g'), 240);
  if length(v_summary) < 2 then
    v_summary := 'Note' || case when jsonb_array_length(v_attachments) > 0
      then ' with ' || jsonb_array_length(v_attachments) || ' attachment' || case when jsonb_array_length(v_attachments) = 1 then '' else 's' end
      else '' end;
  end if;
  insert into public.sme_prospect_activities(prospect_id, consultant_id, activity_type, summary, detail, occurred_at, created_by)
  values (p_prospect, app.v226_self_consultant(), 'note', v_summary, nullif(v_body,''), now(), v_actor)
  returning * into v_activity;
  if jsonb_array_length(v_attachments) > 0 then
    insert into public.sme_activity_detail_versions(activity_id, version, attachments, created_source, created_by)
    values (v_activity.id, 1, v_attachments, 'manual', v_actor);
  end if;
  -- A note is an edit to this firm's record: the "last edited" clock moves.
  update public.sme_prospects set version = version + 1, updated_by = v_actor, updated_at = now() where id = p_prospect;
  return jsonb_build_object('activity_id', v_activity.id, 'occurred_at', v_activity.occurred_at,
    'attachment_count', jsonb_array_length(v_attachments), 'replayed', false);
end
$function$;

comment on function public.platform_pipeline_board_v785(text,uuid,text,integer) is
  'nestly_v785: the Pipeline board — every scoped prospect as a card with lane, schedule, owner and follow_up_days (Asia/Singapore). Scope = app.v89_platform_can(onboarding,r); sales_staff see their own book.';
comment on function public.platform_pipeline_prospect_v785(uuid) is
  'nestly_v785: one prospect for the Pipeline drawer — company, contacts, activities with attachments, tasks, documents (sensitive scope), converted business and branches.';
comment on function public.platform_pipeline_set_schedule_v785(uuid,bigint,timestamptz,date,text) is
  'nestly_v785: sets next_appointment_at and next_follow_up_on (mirrors next_action_at), bumps version/updated_at, logs a system activity.';
comment on function public.platform_pipeline_add_note_v785(uuid,text,jsonb,text) is
  'nestly_v785: adds a note activity with vault-uploaded attachments recorded in sme_activity_detail_versions.attachments; moves the last-edited clock.';

-- app.* is internal: the browser roles never execute it directly (v720 access-boundary fixture).
-- The public SECURITY DEFINER readers above call it as the owner.
revoke all on function app.v785_lane(text) from public, anon, authenticated;
grant execute on function app.v785_lane(text) to service_role;
revoke all on function public.platform_pipeline_board_v785(text,uuid,text,integer) from public, anon;
grant execute on function public.platform_pipeline_board_v785(text,uuid,text,integer) to authenticated, service_role;
revoke all on function public.platform_pipeline_prospect_v785(uuid) from public, anon;
grant execute on function public.platform_pipeline_prospect_v785(uuid) to authenticated, service_role;
revoke all on function public.platform_pipeline_set_schedule_v785(uuid,bigint,timestamptz,date,text) from public, anon;
grant execute on function public.platform_pipeline_set_schedule_v785(uuid,bigint,timestamptz,date,text) to authenticated, service_role;
revoke all on function public.platform_pipeline_add_note_v785(uuid,text,jsonb,text) from public, anon;
grant execute on function public.platform_pipeline_add_note_v785(uuid,text,jsonb,text) to authenticated, service_role;

commit;
