-- Nestly v220 — next best times follow the teammate who was actually chosen.
--
-- Owner: "i selected kelvin - why it show devi next best time? - please make sure when selected
-- the staff, it will show the user's next best timings - not other staff - although fair
-- rotation."
--
-- V217 fixed the headline sentence but not this list. next_best_slots walks forward in
-- 15-minute steps and, at each step, picks whichever teammate is fairest — so choosing Kelvin
-- and being offered Devi's times is the rotation answering a question the owner did not ask.
-- When a specific teammate is chosen, the alternative TIMES should be theirs.
--
-- p_staff is optional and defaults to null, so auto-assign is unchanged: with no chosen person
-- the fair rotation still decides who each suggested time belongs to. available_staff is
-- deliberately NOT filtered — the owner must still be able to see and switch to someone free,
-- which is the other half of the clash prompt this feeds.

begin;

do $patch$
declare d text; n text;
begin
  select pg_get_functiondef(p.oid) into d from pg_proc p join pg_namespace ns on ns.oid=p.pronamespace
  where ns.nspname='public' and p.proname='suggest_appointment_staff_v47_v94_base';
  if position('p_staff' in d) > 0 then raise notice 'base already staff-aware'; return; end if;

  n := replace(d, 'p_recent_days integer DEFAULT 30)',
                  'p_recent_days integer DEFAULT 30, p_staff uuid DEFAULT NULL)');
  if n = d then raise exception 'v220: base signature anchor not found'; end if;
  d := n;

  -- Restrict only the forward-looking slot search, inside its own loop.
  n := replace(d,
E'     where s.business_id=p_business and s.active\n       and app.staff_free_for_appointment_v47(\n             p_business,s.id,p_branch,p_service,v_candidate,',
E'     where s.business_id=p_business and s.active\n       and (p_staff is null or s.id = p_staff)\n       and app.staff_free_for_appointment_v47(\n             p_business,s.id,p_branch,p_service,v_candidate,');
  if n = d then raise exception 'v220: base next-slot anchor not found'; end if;
  execute n;
end $patch$;

do $patch$
declare d text; n text;
begin
  select pg_get_functiondef(p.oid) into d from pg_proc p join pg_namespace ns on ns.oid=p.pronamespace
  where ns.nspname='public' and p.proname='suggest_appointment_staff_v47';
  if position('p_staff' in d) > 0 then raise notice 'wrapper already staff-aware'; return; end if;

  n := replace(d, 'p_recent_days integer DEFAULT 30)',
                  'p_recent_days integer DEFAULT 30, p_staff uuid DEFAULT NULL)');
  if n = d then raise exception 'v220: wrapper signature anchor not found'; end if;
  d := n;
  n := replace(d, 'p_duration_minutes,p_limit,p_recent_days',
                  'p_duration_minutes,p_limit,p_recent_days,p_staff');
  if n = d then raise exception 'v220: wrapper delegation anchor not found'; end if;
  execute n;
end $patch$;

drop function if exists public.suggest_appointment_staff_v47(uuid,uuid,uuid,timestamptz,integer,integer,integer);
drop function if exists public.suggest_appointment_staff_v47_v94_base(uuid,uuid,uuid,timestamptz,integer,integer,integer);

revoke all on function public.suggest_appointment_staff_v47(uuid,uuid,uuid,timestamptz,integer,integer,integer,uuid)
  from public, anon;
grant execute on function public.suggest_appointment_staff_v47(uuid,uuid,uuid,timestamptz,integer,integer,integer,uuid)
  to authenticated;
revoke all on function public.suggest_appointment_staff_v47_v94_base(uuid,uuid,uuid,timestamptz,integer,integer,integer,uuid)
  from public, anon, authenticated;

commit;
