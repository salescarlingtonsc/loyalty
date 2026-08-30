-- Rollback-only v645 acceptance suite: app.run_messaging_retention_v645() redacts aged
-- terminal send rows (params/phone/wamid) without disturbing status truth. Note: inserting
-- a bringback grant fires the v551 enqueue trigger, which creates the retention_sends_v551
-- row itself — this suite ages THAT genuine row into redaction range rather than forging one,
-- the same discipline the source production validation used.
-- Run after the complete canonical chain through v645 in a disposable database (or as a
-- rolled-back transaction directly against a prod-shaped instance).
begin;

do $fixture$
declare
  v_owner uuid := gen_random_uuid();
  v_business uuid := gen_random_uuid();
  v_service uuid := gen_random_uuid();
  v_client uuid;
begin
  reset role;
  insert into auth.users(
    instance_id,id,aud,role,email,encrypted_password,
    email_confirmed_at,created_at,updated_at
  ) values (
    '00000000-0000-0000-0000-000000000000',v_owner,
    'authenticated','authenticated',
    'phasebc-owner-'||substr(v_owner::text,1,8)||'@example.test',
    '',now(),now(),now()
  );
  insert into public.businesses(
    id,name,slug,industry,join_enabled,enabled_modules
  ) values (
    v_business,'Phase BC fixture',
    'phasebc-'||substr(v_business::text,1,8),'facial',true,
    array['dashboard','clients','sales','till','appointments','loyalty','reports','services']
  );
  insert into public.staff(business_id,user_id,role,full_name,active)
  values (v_business,v_owner,'owner','Phase BC Owner',true);
  insert into public.branches(business_id,name,is_default,active)
  values (v_business,'Primary',true,true);
  update public.business_workspace_controls_v94
     set approval_status='approved',version=version+1,decided_at=clock_timestamp(),
         decision_reason='phase-bc rollback validation fixture',updated_at=clock_timestamp()
   where business_id=v_business;
  insert into public.subscriptions(business_id,status,trial_ends_at)
  values (v_business,'trialing', now() + interval '7 days');
  insert into public.services(id,business_id,name,price_cents,duration_min,active,category)
  values (v_service,v_business,'Signature Glass Skin Facial',12000,60,true,'Facial');
  insert into public.clients (business_id, full_name, phone)
  values (v_business,'Consented','82220001') returning id into v_client;

  perform set_config('phasebc.owner', v_owner::text, true);
  perform set_config('phasebc.business', v_business::text, true);
  perform set_config('phasebc.service', v_service::text, true);
  perform set_config('phasebc.client', v_client::text, true);
end
$fixture$;

create or replace function pg_temp.as_postgres() returns void language plpgsql as $$
begin
  execute 'reset role';
  perform set_config('request.jwt.claim.sub','',true);
  perform set_config('request.jwt.claims','{}',true);
end;
$$;
grant execute on function pg_temp.as_postgres() to public;

-- ---------------------------------------------------------------------------
-- B. v645 redaction honours terminal/age rules and keeps status truth
-- ---------------------------------------------------------------------------
do $b$
declare
  v_business uuid := current_setting('phasebc.business')::uuid;
  v_client uuid := current_setting('phasebc.client')::uuid;
  v_id uuid;
  v_row public.retention_sends_v551%rowtype;
  v_res jsonb;
begin
  perform pg_temp.as_postgres();
  declare v_campaign uuid := gen_random_uuid(); v_grant uuid := gen_random_uuid();
  begin
    insert into public.bringback_campaigns_v361 (id, business_id, name, reward_label, away_days)
    values (v_campaign, v_business, 'Fixture campaign', 'Free drink', 30);
    insert into public.bringback_grants_v361 (id, business_id, campaign_id, client_id, reward_label, away_days, cycle_key)
    values (v_grant, v_business, v_campaign, v_client, 'Free drink', 30, current_date);
    -- the v551 enqueue trigger already created the send row for this grant;
    -- age that genuine row into redaction range instead of forging one.
    update public.retention_sends_v551
       set queued_at = now() - interval '120 days',
           variables = coalesce(variables, '{"x":1}'::jsonb),
           recipient_phone_norm = coalesce(recipient_phone_norm, '82220001')
     where grant_id = v_grant
     returning id into v_id;
    if v_id is null then
      raise exception 'B0: expected the v551 enqueue trigger to create a send row';
    end if;
  end;
  v_res := app.run_messaging_retention_v645();
  select * into v_row from public.retention_sends_v551 where id = v_id;
  if v_row.variables is not null or v_row.recipient_phone_norm is not null then
    raise exception 'B1: aged terminal send must be redacted';
  end if;
  if v_row.status is null or v_row.suppressed_reason is null then
    raise exception 'B2: redaction must not touch status truth (status %, reason %)', v_row.status, v_row.suppressed_reason;
  end if;
  raise notice 'B OK: messaging retention (redacted % rows)', v_res->'redacted';
end
$b$;

reset role;
rollback;
