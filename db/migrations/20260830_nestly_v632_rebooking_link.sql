-- NESTLY v632 — Phase A, M5 (A4): explicit rebooking-before-leaving evidence.
-- "Does booking the next visit before leaving improve retention?" is uninstrumented today.
-- One nullable, write-once column on appointments records the DIRECT fact: staff booked the
-- next appointment from the completion screen of a previous one. Per owner ruling D9, any
-- "rebooked within N minutes" heuristic is a read-layer inference labelled as such — it is
-- never written into this column.
begin;

alter table public.appointments add column booked_from_appointment_id uuid;
alter table public.appointments
  add constraint appointments_booked_from_fk
  foreign key (booked_from_appointment_id, business_id)
  references public.appointments (id, business_id);

-- Write-once: NULL -> value exactly once; never value -> value, never value -> NULL.
create or replace function app.appointments_rebook_guard_v632()
returns trigger language plpgsql
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
begin
  if new.booked_from_appointment_id is not distinct from old.booked_from_appointment_id then
    return new;
  end if;
  if old.booked_from_appointment_id is not null then
    raise exception 'rebooking provenance is write-once' using errcode = '42501';
  end if;
  if new.booked_from_appointment_id = new.id then
    raise exception 'an appointment cannot be rebooked from itself' using errcode = '22023';
  end if;
  return new;
end;
$$;
create trigger trg_appointments_rebook_guard_v632
  before update of booked_from_appointment_id on public.appointments
  for each row execute function app.appointments_rebook_guard_v632();

-- The linking RPC the completion screen calls right after creating the next
-- appointment. Same gate family as appointment writes.
create or replace function public.link_rebooked_appointment_v1(
  p_business uuid, p_appointment uuid, p_booked_from uuid)
returns json
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_new public.appointments%rowtype;
  v_from public.appointments%rowtype;
begin
  select * into v_new from public.appointments
   where id = p_appointment and business_id = p_business for update;
  if not found then
    raise exception 'appointment not found' using errcode = '22023';
  end if;
  select * into v_from from public.appointments
   where id = p_booked_from and business_id = p_business;
  if not found then
    raise exception 'source appointment not found in this business' using errcode = '22023';
  end if;
  if auth.uid() is null
     or not app.can_module_write(p_business, 'appointments')
     or not app.can_see_branch(p_business, v_new.branch_id) then
    raise exception 'appointment write access is required' using errcode = '42501';
  end if;
  if v_new.created_at < v_from.created_at then
    raise exception 'the rebooked appointment must be newer than its source' using errcode = '22023';
  end if;
  update public.appointments
     set booked_from_appointment_id = p_booked_from
   where id = p_appointment and business_id = p_business;
  return json_build_object('id', p_appointment, 'booked_from', p_booked_from);
end;
$$;
revoke all on function public.link_rebooked_appointment_v1(uuid,uuid,uuid) from public, anon;
grant execute on function public.link_rebooked_appointment_v1(uuid,uuid,uuid) to authenticated, service_role;

insert into public.analytics_observation_watermarks (metric_key, observed_since, reason)
values ('rebooking_link', now(),
        'rebook-before-leaving is recorded from v632 when staff use the completion screen; history is unrecoverable');

commit;
