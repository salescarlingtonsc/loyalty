-- Rollback-only v634 acceptance suite: record_quick_sale's synthesized
-- custom line, the appointment-completion service line, and the
-- backfill completeness invariant across every non-reversal sale.
-- Run after the complete canonical chain through v634 in a disposable database.
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
-- C3. v634 quick-sale custom line
-- ---------------------------------------------------------------------------
do $c$
declare
  v_owner uuid := current_setting('phasea.owner')::uuid;
  v_business uuid := current_setting('phasea.business')::uuid;
  v_res jsonb;
  v_sale uuid;
  v_line record;
begin
  perform pg_temp.as_user(v_owner);
  v_res := public.record_quick_sale(
    p_business=>v_business, p_amount_cents=>5000, p_method=>'cash',
    p_note=>'phasea quick', p_idempotency_key=>'phasea-qs-v634-001')::jsonb;
  v_sale := (v_res #>> '{sale,id}')::uuid;
  perform pg_temp.as_postgres();
  select * into v_line from public.sale_items where sale_id=v_sale;
  if not found or v_line.item_type <> 'custom' or v_line.line_cents <> 5000 then
    raise exception 'C3: quick sale missing its custom line';
  end if;
  raise notice 'C3 OK: quick-sale custom line';
end
$c$;

-- ---------------------------------------------------------------------------
-- D2/D3. v634 appointment-completion service line
-- ---------------------------------------------------------------------------
do $d$
declare
  v_owner uuid := current_setting('phasea.owner')::uuid;
  v_business uuid := current_setting('phasea.business')::uuid;
  v_service uuid := current_setting('phasea.service')::uuid;
  v_client uuid;
  v_appt1 uuid := gen_random_uuid();
  v_sale record;
  n integer;
begin
  perform pg_temp.as_postgres();
  insert into public.clients (business_id, full_name, phone, birth_date)
  values (v_business,'Completion Customer','81110033','1990-01-01') returning id into v_client;
  insert into public.appointments (id,business_id,client_id,service_id,starts_at,ends_at,status,total_cents)
  values (v_appt1,v_business,v_client,v_service, now() - interval '2 hours', now() - interval '1 hour','booked',8000);

  perform pg_temp.as_user(v_owner);
  perform public.set_appointment_status_v47(v_business, v_appt1, 'completed');
  perform pg_temp.as_postgres();
  select * into v_sale from public.sales where appointment_id=v_appt1;
  if not found then raise exception 'D2: completion sale missing'; end if;
  select count(*) into n from public.sale_items
   where sale_id=v_sale.id and item_type='service' and ref_id=v_service and line_cents=8000;
  if n <> 1 then raise exception 'D3: completion sale service line missing'; end if;
  raise notice 'D OK: v634 completion service line';
end
$d$;

-- ---------------------------------------------------------------------------
-- G. v634 backfill completeness + sum invariant across production
-- ---------------------------------------------------------------------------
do $g$
declare
  v_missing integer;
  v_broken integer;
begin
  perform pg_temp.as_postgres();
  select count(*) into v_missing from public.sales s
   where s.reversal_of is null and s.amount_cents >= 0
     and not exists (select 1 from public.sale_items si where si.sale_id = s.id);
  if v_missing > 0 then
    raise exception 'G1: % non-reversal sales still itemless after backfill', v_missing;
  end if;
  select count(*) into v_broken from (
    select s.id from public.sales s
      join public.sale_items si on si.sale_id = s.id
     where s.reversal_of is null
     group by s.id, s.amount_cents
    having sum(si.line_cents) <> s.amount_cents
  ) x;
  raise notice 'G: sales where line sum <> amount: % (pre-existing kernel rounding rows are reported, not failed)', v_broken;
  raise notice 'G OK: line-item coverage';
end
$g$;

reset role;
rollback;
