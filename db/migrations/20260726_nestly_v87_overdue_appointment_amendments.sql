-- NESTLY v87 — overdue booked appointment amendments
-- Keep v48's audited, replay-safe scheduling contract, but permit a still-booked
-- overdue record to be moved to a valid future slot. Terminal records remain immutable.

begin;

do $migration$
declare
  v_signature constant regprocedure :=
    'public.reschedule_appointment_v48(uuid,uuid,timestamptz,integer,uuid,text,uuid)'::regprocedure;
  v_definition text;
  v_old_guard constant text :=
    'if v_appointment.status<>''booked'' or v_appointment.starts_at<=clock_timestamp() then';
  v_new_guard constant text :=
    'if v_appointment.status<>''booked'' then';
  v_old_message constant text :=
    'only a future booked appointment can be changed';
  v_new_message constant text :=
    'only a booked appointment can be amended';
begin
  select pg_get_functiondef(v_signature) into v_definition;

  if strpos(v_definition,v_old_guard)=0 or strpos(v_definition,v_old_message)=0 then
    raise exception
      'v87 expected the canonical v48 appointment status guard; refusing an unsafe rewrite'
      using errcode='55000';
  end if;

  v_definition:=replace(v_definition,v_old_guard,v_new_guard);
  v_definition:=replace(v_definition,v_old_message,v_new_message);
  execute v_definition;
end
$migration$;

revoke all privileges on function public.reschedule_appointment_v48(
  uuid,uuid,timestamptz,integer,uuid,text,uuid)
  from public, anon, authenticated;
grant execute on function public.reschedule_appointment_v48(
  uuid,uuid,timestamptz,integer,uuid,text,uuid)
  to authenticated;

notify pgrst, 'reload schema';

commit;
