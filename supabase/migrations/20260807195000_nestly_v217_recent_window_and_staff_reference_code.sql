-- Nestly v217 — the fairness window becomes the owner's, and a reference code that
-- lets a teammate take over their existing roster record.
--
-- Two owner reports, both about work already half-built.
--
-- (6) "recent appointment - how recent? maybe can reset per day/3 days/week/month?
--     (let user to toggle & decide)".
--     `recent_appointments` was a hardcoded interval '30 days' inside the ranking query, so the
--     number printed on each staff button had no stated meaning and no way to change it. It is
--     now a parameter, bounded to the four windows the picker offers, defaulting to 30 so every
--     existing caller is unchanged. It drives BOTH the count and the fairness ordering — a
--     window that moved the label but not the ranking would be a lie.
--
-- (3) "there must be a reference code here - example kelvin sign up an account and input the
--     reference code - he will be tagged into the business (so we dont need to duplicate any
--     data over, he can just take over as the staff)".
--     accept_invite ALREADY does the hard half: when staff_invites.staff_id is set it upgrades
--     that existing roster row, so name, job title, commission, working hours, rota and every
--     past sale stay attached to the same person, and parks them in access_state='pending' for
--     owner approval. What was missing is that nothing could ever SET staff_id —
--     create_invite(business, role, email) has no way to name a teammate, so every code created
--     a SECOND staff row and the roster data had to be re-keyed by hand. The only new thing
--     needed is a way to mint a code bound to one roster teammate.

begin;

do $patch$
declare d text; n text;
begin
  select pg_get_functiondef(p.oid) into d from pg_proc p join pg_namespace ns on ns.oid=p.pronamespace
  where ns.nspname='public' and p.proname='suggest_appointment_staff_v47_v94_base';
  if position('p_recent_days' in d) > 0 then raise notice 'base already parameterised'; return; end if;

  n := replace(d, 'p_limit integer DEFAULT 5)',
                  'p_limit integer DEFAULT 5, p_recent_days integer DEFAULT 30)');
  if n = d then raise exception 'v217: base signature anchor not found'; end if;
  d := n;

  n := replace(d, E'$function$\ndeclare\n',
                  E'$function$\ndeclare\n  v_recent_days integer := coalesce(p_recent_days, 30);\n');
  if n = d then raise exception 'v217: base declare anchor not found'; end if;
  d := n;

  -- Bounded to the four windows the picker offers. An arbitrary integer would let a caller
  -- widen fairness silently; these are the only meanings the label can express.
  n := replace(d, E'\nbegin\n  if auth.uid() is null',
    E'\nbegin\n  if v_recent_days not in (1, 3, 7, 30) then'
    || E'\n    raise exception ''unsupported_recent_window'' using errcode=''22023'';'
    || E'\n  end if;'
    || E'\n  if auth.uid() is null');
  if n = d then raise exception 'v217: base guard anchor not found'; end if;
  d := n;

  n := replace(d, 'a.starts_at >= now() - interval ''30 days''',
                  'a.starts_at >= now() - make_interval(days => v_recent_days)');
  if n = d then raise exception 'v217: base recent-window anchor not found'; end if;

  execute n;
end $patch$;

do $patch$
declare d text; n text;
begin
  select pg_get_functiondef(p.oid) into d from pg_proc p join pg_namespace ns on ns.oid=p.pronamespace
  where ns.nspname='public' and p.proname='suggest_appointment_staff_v47';
  if position('p_recent_days' in d) > 0 then raise notice 'wrapper already parameterised'; return; end if;

  n := replace(d, 'p_limit integer DEFAULT 5)',
                  'p_limit integer DEFAULT 5, p_recent_days integer DEFAULT 30)');
  if n = d then raise exception 'v217: wrapper signature anchor not found'; end if;
  d := n;
  n := replace(d, 'p_business,p_branch,p_service,p_starts,p_duration_minutes,p_limit',
                  'p_business,p_branch,p_service,p_starts,p_duration_minutes,p_limit,p_recent_days');
  if n = d then raise exception 'v217: wrapper delegation anchor not found'; end if;
  execute n;
end $patch$;

-- The 6-argument overloads are now ambiguous with the 7-argument defaults, so they go.
drop function if exists public.suggest_appointment_staff_v47(uuid,uuid,uuid,timestamptz,integer,integer);
drop function if exists public.suggest_appointment_staff_v47_v94_base(uuid,uuid,uuid,timestamptz,integer,integer);

revoke all on function public.suggest_appointment_staff_v47(uuid,uuid,uuid,timestamptz,integer,integer,integer)
  from public, anon;
grant execute on function public.suggest_appointment_staff_v47(uuid,uuid,uuid,timestamptz,integer,integer,integer)
  to authenticated;
revoke all on function public.suggest_appointment_staff_v47_v94_base(uuid,uuid,uuid,timestamptz,integer,integer,integer)
  from public, anon, authenticated;

create or replace function public.create_staff_reference_code_v217(
  p_business uuid, p_staff uuid)
returns jsonb language plpgsql security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $fn$
declare
  v_actor uuid := auth.uid();
  v_staff public.staff%rowtype;
  v_code text;
  v_invite uuid;
  v_expires timestamptz := now() + interval '14 days';
begin
  if v_actor is null then
    raise exception 'authenticated staff required' using errcode='42501';
  end if;
  -- Granting app access is an owner/manager act, exactly like create_invite.
  if not (app.is_salon_owner(p_business) or app.has_perm(p_business,'manage_staff')) then
    raise exception 'staff reference code authorization required' using errcode='42501';
  end if;

  select * into v_staff from public.staff
  where id = p_staff and business_id = p_business
  for update;
  if not found then
    raise exception 'staff_member_not_found' using errcode='22023';
  end if;
  if v_staff.user_id is not null then
    raise exception 'staff_member_already_has_login' using errcode='22023';
  end if;
  if not coalesce(v_staff.active, true) then
    raise exception 'staff_member_inactive' using errcode='22023';
  end if;
  if v_staff.role = 'owner' then
    raise exception 'owner_is_not_invitable' using errcode='22023';
  end if;

  -- One live code per teammate. Re-issuing supersedes the previous one so an old slip of paper
  -- cannot still claim the same person after the owner has re-thought it.
  update public.staff_invites set status='revoked'
  where business_id = p_business and staff_id = p_staff and status = 'pending';

  -- Unambiguous alphabet: no O/0, no I/1, so a handwritten code is readable by someone who may
  -- not read English well. accept_invite upper-cases and strips spaces and dashes already.
  loop
    v_code := (select string_agg(substr('ABCDEFGHJKLMNPQRSTUVWXYZ23456789',
                (floor(random()*32)+1)::int, 1), '')
               from generate_series(1,8));
    exit when not exists(select 1 from public.staff_invites where code = v_code);
  end loop;

  insert into public.staff_invites(business_id, email, role, code, status, expires_at, staff_id)
  values (p_business, nullif(btrim(coalesce(v_staff.email,'')),''), v_staff.role, v_code,
          'pending', v_expires, p_staff)
  returning id into v_invite;

  insert into public.audit_log(business_id, actor, action, entity, entity_id, detail)
  values (p_business, v_actor, 'STAFF_REFERENCE_CODE_CREATED_V217', 'staff_invites', v_invite,
          jsonb_build_object('staff_id', p_staff, 'role', v_staff.role,
                             'staff_name', v_staff.full_name));

  return jsonb_build_object('status','ok','code',v_code,'invite_id',v_invite,
    'staff_id',p_staff,'staff_name',v_staff.full_name,'role',v_staff.role,
    'expires_at',v_expires,
    'restricted_to_email', nullif(btrim(coalesce(v_staff.email,'')),''));
end
$fn$;

revoke all on function public.create_staff_reference_code_v217(uuid,uuid) from public, anon;
grant execute on function public.create_staff_reference_code_v217(uuid,uuid) to authenticated;

commit;
