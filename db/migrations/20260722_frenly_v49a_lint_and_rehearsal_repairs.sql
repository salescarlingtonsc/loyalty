-- Frenly v49a: forward-only lint remediation for the canonical v48/v49 chain.
-- This migration intentionally repairs catalog definitions without rewriting history.

begin;

do $migration$
declare
  v_definition text;
  v_needle text;
  v_replacement text;
  v_occurrences integer;
begin
  -- v20 used an untyped empty-array literal. Guard the exact predecessor body before
  -- replacing it so a changed historical definition fails closed.
  select pg_get_functiondef(
           'public.reclassify_sale_policy(uuid,boolean,text)'::regprocedure
         )
    into strict v_definition;
  v_needle := '  v_reversal_ids uuid[] := ''{}'';';
  v_replacement := '  v_reversal_ids uuid[] := ''{}''::uuid[];';
  v_occurrences := (length(v_definition) - length(replace(v_definition, v_needle, '')))
                   / length(v_needle);
  if v_occurrences <> 1 then
    raise exception 'unexpected reclassify_sale_policy predecessor definition';
  end if;
  execute replace(v_definition, v_needle, v_replacement);

  -- v34 renamed the v20 implementation to reverse_sale_v20_base. Repair that exact
  -- retained implementation while preserving its signature, attributes, and body.
  select pg_get_functiondef(
           'public.reverse_sale_v20_base(uuid,uuid,text,text,text,text)'::regprocedure
         )
    into strict v_definition;
  v_needle := '  v_payment_ids uuid[] := ''{}'';';
  v_replacement := '  v_payment_ids uuid[] := ''{}''::uuid[];';
  v_occurrences := (length(v_definition) - length(replace(v_definition, v_needle, '')))
                   / length(v_needle);
  if v_occurrences <> 1 then
    raise exception 'unexpected reverse_sale_v20_base predecessor definition';
  end if;
  execute replace(v_definition, v_needle, v_replacement);

  -- Remove the unused v27 draft-editor variable from the exact current definition.
  select pg_get_functiondef(
           'public.save_loyalty_reward_draft(uuid,uuid,jsonb,jsonb)'::regprocedure
         )
    into strict v_definition;
  v_needle := E'  v_key text;\n';
  v_occurrences := (length(v_definition) - length(replace(v_definition, v_needle, '')))
                   / length(v_needle);
  if v_occurrences <> 1 then
    raise exception 'unexpected save_loyalty_reward_draft predecessor definition';
  end if;
  execute replace(v_definition, v_needle, '');
end
$migration$;

create or replace function app.suggest_appointment_reschedule_v48(
  p_business uuid,
  p_appointment uuid,
  p_branch uuid,
  p_service uuid,
  p_starts timestamptz,
  p_duration_minutes integer,
  p_limit integer default 5
)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_now timestamptz := statement_timestamp();
  v_ends timestamptz := p_starts + make_interval(mins=>p_duration_minutes);
  v_timezone text;
  v_day_end timestamptz;
  v_candidate timestamptz;
  v_available jsonb := '[]'::jsonb;
  v_next jsonb := '[]'::jsonb;
  v_staff record;
begin
  select branch.timezone into v_timezone from public.branches branch
   where branch.id=p_branch and branch.business_id=p_business and branch.active;
  if not found then raise exception 'active branch not found' using errcode='22023'; end if;
  v_day_end:=(((p_starts at time zone v_timezone)::date+1)::timestamp at time zone v_timezone);

  select coalesce(jsonb_agg(jsonb_build_object(
           'staff_id',ranked.id,'staff_name',ranked.full_name,
           'calendar_color',ranked.calendar_color,'recent_appointments',ranked.recent_appointments
         ) order by ranked.recent_appointments,ranked.last_assigned nulls first,
                    ranked.full_name,ranked.id),'[]'::jsonb)
    into v_available
    from (
      select staff.id,staff.full_name,staff.calendar_color,
             (select count(*)::integer from public.appointments recent
               where recent.business_id=p_business and recent.staff_id=staff.id
                 and recent.status in ('booked','completed')
                 and recent.starts_at>=v_now-interval '30 days') recent_appointments,
             (select max(recent.created_at) from public.appointments recent
               where recent.business_id=p_business and recent.staff_id=staff.id
                 and recent.status in ('booked','completed')) last_assigned
        from public.staff staff
        join public.staff_branches staff_branch
          on staff_branch.business_id=staff.business_id and staff_branch.staff_id=staff.id
         and staff_branch.branch_id=p_branch
       where staff.business_id=p_business and staff.active
         and app.staff_free_for_appointment_v47(
           p_business,staff.id,p_branch,p_service,p_starts,v_ends,p_appointment)
       order by recent_appointments,last_assigned nulls first,staff.full_name,staff.id
       limit p_limit
    ) ranked;

  v_candidate:=p_starts+interval '15 minutes';
  while v_candidate+make_interval(mins=>p_duration_minutes)<=v_day_end
        and jsonb_array_length(v_next)<2 loop
    select staff.id,staff.full_name,staff.calendar_color into v_staff
      from public.staff staff
      join public.staff_branches staff_branch
        on staff_branch.business_id=staff.business_id and staff_branch.staff_id=staff.id
       and staff_branch.branch_id=p_branch
     where staff.business_id=p_business and staff.active
       and app.staff_free_for_appointment_v47(
         p_business,staff.id,p_branch,p_service,v_candidate,
         v_candidate+make_interval(mins=>p_duration_minutes),p_appointment)
     order by
       (select count(*) from public.appointments recent
         where recent.business_id=p_business and recent.staff_id=staff.id
           and recent.status in ('booked','completed')
           and recent.starts_at>=v_now-interval '30 days'),
       (select max(recent.created_at) from public.appointments recent
         where recent.business_id=p_business and recent.staff_id=staff.id
           and recent.status in ('booked','completed')) nulls first,
       staff.full_name,staff.id
     limit 1;
    if found then
      v_next:=v_next||jsonb_build_array(jsonb_build_object(
        'starts_at',v_candidate,
        'ends_at',v_candidate+make_interval(mins=>p_duration_minutes),
        'staff_id',v_staff.id,'staff_name',v_staff.full_name,
        'calendar_color',v_staff.calendar_color
      ));
    end if;
    v_candidate:=v_candidate+interval '15 minutes';
  end loop;
  return jsonb_build_object(
    'requested_starts_at',p_starts,'requested_ends_at',v_ends,
    'available_staff',v_available,'recommended_staff_id',v_available#>>'{0,staff_id}',
    'next_best_slots',v_next
  );
end
$$;

-- Reassert the intended least-privilege surfaces explicitly after replacements.
revoke all privileges on function app.suggest_appointment_reschedule_v48(
  uuid,uuid,uuid,uuid,timestamptz,integer,integer)
  from public, anon, authenticated;
revoke all privileges on function public.reverse_sale_v20_base(
  uuid,uuid,text,text,text,text)
  from public, anon, authenticated;
revoke all privileges on function public.save_loyalty_reward_draft(
  uuid,uuid,jsonb,jsonb)
  from public, anon, authenticated;
revoke all privileges on function public.reclassify_sale_policy(uuid,boolean,text)
  from public, anon;
grant execute on function public.reclassify_sale_policy(uuid,boolean,text)
  to authenticated;

commit;
