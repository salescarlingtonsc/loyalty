-- Rollback-only v639 acceptance suite: the corrective appointment_status_events
-- backfill reads the real audit_log APPOINTMENT_STATUS detail keys, 'to' and
-- 'from' (v631's original backfill used the wrong key, 'status', and matched
-- zero rows in production). Re-runs the same backfill statement v639 applied,
-- against a fresh audit_log row, and asserts the recovered from/to values.
-- Run after the complete canonical chain through v639 in a disposable database.
begin;

do $fixture$
declare
  v_owner uuid := gen_random_uuid();
  v_business uuid := gen_random_uuid();
  v_service uuid := gen_random_uuid();
begin
  reset role;
  insert into auth.users(
    instance_id,id,aud,role,email,encrypted_password,
    email_confirmed_at,created_at,updated_at
  ) values (
    '00000000-0000-0000-0000-000000000000',v_owner,
    'authenticated','authenticated',
    'phasea-owner-'||substr(v_owner::text,1,8)||'@example.test',
    '',now(),now(),now()
  );
  insert into public.businesses(
    id,name,slug,industry,join_enabled,enabled_modules
  ) values (
    v_business,'Phase A fixture',
    'phasea-'||substr(v_business::text,1,8),'test',true,
    array['dashboard','clients','sales','till','appointments','bookings','loyalty','reports','services']
  );
  insert into public.staff(business_id,user_id,role,full_name,active)
  values (v_business,v_owner,'owner','Phase A Owner',true);
  insert into public.branches(business_id,name,is_default,active)
  values (v_business,'Primary',true,true);
  update public.business_workspace_controls_v94
     set approval_status='approved',version=version+1,decided_at=clock_timestamp(),
         decision_reason='phase-a rollback validation fixture',updated_at=clock_timestamp()
   where business_id=v_business;
  insert into public.services(id,business_id,name,price_cents,duration_min,active)
  values (v_service,v_business,'Fixture Facial',8000,60,true);
  -- v620 entitlement gate: a workspace is operational only with an approved control
  -- row AND a live subscription (trialing or paid).
  insert into public.subscriptions(business_id,status,trial_ends_at)
  values (v_business,'trialing', now() + interval '7 days');

  perform set_config('phasea.owner', v_owner::text, true);
  perform set_config('phasea.business', v_business::text, true);
  perform set_config('phasea.service', v_service::text, true);
end
$fixture$;

create or replace function pg_temp.as_user(p_uid uuid) returns void language plpgsql as $$
begin
  execute 'reset role';
  perform set_config('request.jwt.claim.sub','',true);
  perform set_config('request.jwt.claims','{}',true);
  execute 'set local role authenticated';
  perform set_config('request.jwt.claim.sub',p_uid::text,true);
  perform set_config('request.jwt.claims',
    json_build_object('sub',p_uid,'role','authenticated')::text,true);
end;
$$;
create or replace function pg_temp.as_postgres() returns void language plpgsql as $$
begin
  execute 'reset role';
  perform set_config('request.jwt.claim.sub','',true);
  perform set_config('request.jwt.claims','{}',true);
end;
$$;
grant execute on function pg_temp.as_user(uuid) to public;
grant execute on function pg_temp.as_postgres() to public;

-- ---------------------------------------------------------------------------
-- v639: the backfill query shape reads audit_log.detail->>'to' / ->>'from'
-- ---------------------------------------------------------------------------
do $v639$
declare
  v_owner uuid := current_setting('phasea.owner')::uuid;
  v_business uuid := current_setting('phasea.business')::uuid;
  v_service uuid := current_setting('phasea.service')::uuid;
  v_client uuid;
  v_appt uuid := gen_random_uuid();
  v_at timestamptz := now() - interval '3 days';
  v_evt record;
begin
  perform pg_temp.as_postgres();
  insert into public.clients (business_id, full_name, phone, birth_date)
  values (v_business,'Backfill Customer','81110053','1990-01-01') returning id into v_client;
  insert into public.appointments (id,business_id,client_id,service_id,starts_at,ends_at,status,total_cents)
  values (v_appt,v_business,v_client,v_service, now() - interval '2 hours', now() - interval '1 hour','booked',8000);

  -- Simulate a pre-v631 audit trail row using the real production key shape
  -- ('to'/'from'), predating this suite's own status-change trigger coverage.
  insert into public.audit_log (business_id, actor, action, entity, entity_id, detail, created_at)
  values (v_business, v_owner, 'APPOINTMENT_STATUS', 'appointments', v_appt,
          jsonb_build_object('from','booked','to','no_show'), v_at);

  -- Re-run the exact v639 corrective backfill statement against this fresh row.
  insert into public.appointment_status_events
    (business_id, appointment_id, from_status, to_status, at, actor, actor_kind, note)
  select a.business_id, a.entity_id,
         a.detail->>'from',
         a.detail->>'to',
         a.created_at, a.actor, 'system', 'backfill:audit_log'
    from public.audit_log a
   where a.action = 'APPOINTMENT_STATUS'
     and a.entity = 'appointments'
     and a.detail->>'to' is not null
     and exists (select 1 from public.appointments ap
                  where ap.id = a.entity_id and ap.business_id = a.business_id)
     and not exists (select 1 from public.appointment_status_events e
                      where e.appointment_id = a.entity_id
                        and e.to_status = a.detail->>'to'
                        and e.at = a.created_at);

  select * into v_evt from public.appointment_status_events
   where appointment_id = v_appt and to_status = 'no_show';
  if not found then
    raise exception 'v639-1: backfill produced no row for the fresh audit_log entry';
  end if;
  if v_evt.from_status <> 'booked' then
    raise exception 'v639-2: backfill recovered wrong from_status: %', v_evt.from_status;
  end if;
  if v_evt.note <> 'backfill:audit_log' then
    raise exception 'v639-3: backfill row missing its provenance note';
  end if;
  raise notice 'v639 OK: backfill reads audit_log to/from keys';
end
$v639$;

reset role;
rollback;
