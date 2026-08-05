-- Rollback-only acceptance for NESTLY v175 canonical customer account opens.
-- Run after the complete canonical chain through v175 in a disposable database.
--
-- Proves:
--   * the recorder writes one canonical day row and projects exactly one v100
--     `customer.account_open` server event from it;
--   * a same-day repeat on the same channel is ignored (no count inflation),
--     while a different channel on the same day is its own open;
--   * the platform aggregate returns correct opens, distinct customers and
--     first-time customers across a two-day window, per channel and per day;
--   * an unauthenticated caller and a foreign firm's owner cannot read another
--     firm's aggregate.
begin;

create or replace function pg_temp.as_v175_user(
  p_uid uuid,p_role text default 'authenticated'
) returns void language plpgsql as $$
begin
  execute 'reset role';
  perform set_config('request.jwt.claim.sub','',true);
  perform set_config('request.jwt.claims','{}',true);
  execute format('set local role %I',p_role);
  perform set_config('request.jwt.claim.sub',coalesce(p_uid::text,''),true);
  perform set_config(
    'request.jwt.claims',
    json_build_object('sub',p_uid,'role',p_role)::text,
    true
  );
end
$$;
grant execute on function pg_temp.as_v175_user(uuid,text) to public;

do $v175_account_open$
declare
  v_owner_a uuid:=gen_random_uuid();
  v_owner_b uuid:=gen_random_uuid();
  v_customer uuid:=gen_random_uuid();
  v_identity uuid:=gen_random_uuid();
  v_link uuid:=gen_random_uuid();
  v_business_a uuid:=gen_random_uuid();
  v_business_b uuid:=gen_random_uuid();
  v_client_login uuid:=gen_random_uuid();
  v_client_counter uuid:=gen_random_uuid();
  v_today date;
  v_yesterday date;
  v_result jsonb;
  v_report jsonb;
  v_count bigint;
  v_error text;
begin
  reset role;
  v_today:=(clock_timestamp() at time zone 'Asia/Singapore')::date;
  v_yesterday:=v_today-1;

  insert into auth.users(
    instance_id,id,aud,role,email,encrypted_password,
    email_confirmed_at,created_at,updated_at
  ) values
    ('00000000-0000-0000-0000-000000000000',v_owner_a,
      'authenticated','authenticated',
      'v175-owner-a-'||substr(v_owner_a::text,1,8)||'@example.test',
      '',now(),now(),now()),
    ('00000000-0000-0000-0000-000000000000',v_owner_b,
      'authenticated','authenticated',
      'v175-owner-b-'||substr(v_owner_b::text,1,8)||'@example.test',
      '',now(),now(),now()),
    ('00000000-0000-0000-0000-000000000000',v_customer,
      'authenticated','authenticated',
      'v175-customer-'||substr(v_customer::text,1,8)||'@example.test',
      '',now(),now(),now());

  insert into public.businesses(
    id,name,slug,industry,join_enabled,enabled_modules
  ) values
    (v_business_a,'V175 account open fixture A',
      'v175-open-a-'||substr(v_business_a::text,1,8),'test',true,
      array['dashboard','clients','sales','loyalty','retention','reports']),
    (v_business_b,'V175 account open fixture B',
      'v175-open-b-'||substr(v_business_b::text,1,8),'test',true,
      array['dashboard','clients','sales','loyalty','retention','reports']);

  insert into public.staff(business_id,user_id,role,full_name,active) values
    (v_business_a,v_owner_a,'owner','V175 Owner A',true),
    (v_business_b,v_owner_b,'owner','V175 Owner B',true);
  insert into public.branches(business_id,name,is_default,active) values
    (v_business_a,'Primary',true,true),
    (v_business_b,'Primary',true,true);

  update public.business_workspace_controls_v94
     set approval_status='approved',
         version=version+1,
         decided_by=v_owner_a,
         decided_at=clock_timestamp(),
         decision_reason='rollback-only v175 acceptance fixture',
         updated_at=clock_timestamp()
   where business_id in(v_business_a,v_business_b);

  insert into public.clients(id,business_id,full_name,phone) values
    (v_client_login,v_business_a,'V175 Wallet Customer','81860001'),
    (v_client_counter,v_business_a,'V175 Counter Customer','81860002');

  insert into public.customer_identities(id,auth_user_id,status)
  values(v_identity,v_customer,'active');
  perform set_config('app.customer_link_insert_id',v_link::text,true);
  insert into public.customer_links(
    id,business_id,identity_id,auth_user_id,client_id,state,
    verification_method,verified_at
  ) values(
    v_link,v_business_a,v_identity,v_customer,v_client_login,'verified',
    'email_claim',clock_timestamp()
  );
  perform set_config('app.customer_link_insert_id','',true);

  -- Prior-day evidence is seeded directly through the canonical table so the
  -- two-day window is deterministic. The recorder deliberately clamps stale
  -- timestamps, so it may not be used to backdate.
  insert into public.customer_account_open_days_v175(
    business_id,client_id,auth_user_id,channel,open_date,first_opened_at
  ) values
    (v_business_a,v_client_login,v_customer,'wallet',v_yesterday,
      clock_timestamp()-interval '1 day'),
    (v_business_a,v_client_counter,null,'join',v_yesterday,
      clock_timestamp()-interval '1 day');

  -- 1. The recorder resolves the verified relationship from the login alone.
  v_result:=app.record_customer_account_open_v175(
    v_business_a,v_customer,null,'wallet',clock_timestamp()
  );
  if (v_result->>'recorded')::boolean is not true
     or (v_result->>'open_date')::date<>v_today then
    raise exception 'v175 assert 1 failed: first wallet open not recorded (%)',
      v_result;
  end if;
  select count(*) into v_count
  from public.customer_account_open_days_v175 day_row
  where day_row.business_id=v_business_a
    and day_row.open_date=v_today
    and day_row.channel='wallet';
  if v_count<>1 then
    raise exception 'v175 assert 1 failed: expected 1 wallet day row, got %',
      v_count;
  end if;
  select count(*) into v_count
  from public.customer_account_open_days_v175 day_row
  where day_row.id=(v_result->>'day_id')::uuid
    and day_row.subject_key='client:'||v_client_login::text;
  if v_count<>1 then
    raise exception
      'v175 assert 1 failed: subject was not anchored on the client row';
  end if;

  -- 2. The canonical day row projects exactly one v100 server event.
  select count(*) into v_count
  from public.product_adoption_events_v100 event_row
  where event_row.event_name='customer.account_open'
    and event_row.source_table='customer_account_open_days_v175'
    and event_row.source_id=(v_result->>'day_id')::uuid
    and event_row.source_authority='server'
    and event_row.actor_scope='customer'
    and event_row.business_id=v_business_a;
  if v_count<>1 then
    raise exception 'v175 assert 2 failed: expected 1 v100 event, got %',
      v_count;
  end if;

  -- 3. A same-day, same-channel repeat is ignored.
  v_result:=app.record_customer_account_open_v175(
    v_business_a,v_customer,v_client_login,'wallet',clock_timestamp()
  );
  if (v_result->>'recorded')::boolean is not false then
    raise exception 'v175 assert 3 failed: same-day repeat was recorded again';
  end if;
  select count(*) into v_count
  from public.customer_account_open_days_v175 day_row
  where day_row.business_id=v_business_a
    and day_row.open_date=v_today
    and day_row.channel='wallet';
  if v_count<>1 then
    raise exception
      'v175 assert 3 failed: duplicate day row created (count %)',v_count;
  end if;
  select count(*) into v_count
  from public.product_adoption_events_v100 event_row
  where event_row.event_name='customer.account_open'
    and event_row.business_id=v_business_a;
  if v_count<>3 then
    raise exception
      'v175 assert 3 failed: expected 3 events so far, got %',v_count;
  end if;

  -- 4. A different channel on the same day is its own open.
  v_result:=app.record_customer_account_open_v175(
    v_business_a,v_customer,v_client_login,'booking',clock_timestamp()
  );
  if (v_result->>'recorded')::boolean is not true then
    raise exception 'v175 assert 4 failed: same-day booking open was ignored';
  end if;

  -- 5. A counter-path customer with no login is recorded by client identity.
  v_result:=app.record_customer_account_open_v175(
    v_business_a,null,v_client_counter,'join',clock_timestamp()
  );
  if (v_result->>'recorded')::boolean is not true then
    raise exception 'v175 assert 5 failed: join-channel open was not recorded';
  end if;

  -- 6. An unattributable request records nothing and raises nothing.
  v_result:=app.record_customer_account_open_v175(
    v_business_a,null,null,'join',clock_timestamp()
  );
  if (v_result->>'recorded')::boolean is not false
     or v_result->>'reason'<>'no_identity' then
    raise exception 'v175 assert 6 failed: unattributable open was recorded (%)',
      v_result;
  end if;

  -- 7. The firm's own owner reads a correct two-day aggregate.
  perform pg_temp.as_v175_user(v_owner_a);
  v_report:=public.platform_customer_account_opens_v175(
    v_business_a,v_yesterday,v_today
  );
  if (v_report#>>'{totals,opens}')::bigint<>5
     or (v_report#>>'{totals,distinct_customers}')::bigint<>2
     or (v_report#>>'{totals,first_time_customers}')::bigint<>2 then
    raise exception 'v175 assert 7 failed: window totals are wrong (%)',
      v_report->'totals';
  end if;
  if (
    select count(*)
    from jsonb_array_elements(v_report->'by_channel') channel_row
    where channel_row->>'channel'='wallet'
      and (channel_row->>'opens')::bigint=2
      and (channel_row->>'distinct_customers')::bigint=1
  )<>1 then
    raise exception 'v175 assert 7 failed: wallet channel totals are wrong (%)',
      v_report->'by_channel';
  end if;
  if (
    select count(*)
    from jsonb_array_elements(v_report->'by_channel') channel_row
    where channel_row->>'channel'='join'
      and (channel_row->>'opens')::bigint=2
      and (channel_row->>'distinct_customers')::bigint=1
  )<>1 then
    raise exception 'v175 assert 7 failed: join channel totals are wrong (%)',
      v_report->'by_channel';
  end if;
  if (
    select count(*)
    from jsonb_array_elements(v_report->'daily') daily_row
    where (daily_row->>'date')::date=v_yesterday
      and (daily_row->>'opens')::bigint=2
      and (daily_row->>'distinct_customers')::bigint=2
      and (daily_row->>'first_time_customers')::bigint=2
  )<>1 then
    raise exception 'v175 assert 7 failed: prior-day series is wrong (%)',
      v_report->'daily';
  end if;
  if (
    select count(*)
    from jsonb_array_elements(v_report->'daily') daily_row
    where (daily_row->>'date')::date=v_today
      and (daily_row->>'opens')::bigint=3
      and (daily_row->>'distinct_customers')::bigint=2
      and (daily_row->>'first_time_customers')::bigint=0
  )<>1 then
    raise exception 'v175 assert 7 failed: current-day series is wrong (%)',
      v_report->'daily';
  end if;

  -- 8. A single-day window narrows correctly.
  v_report:=public.platform_customer_account_opens_v175(
    v_business_a,v_today,v_today
  );
  if (v_report#>>'{totals,opens}')::bigint<>3
     or (v_report#>>'{totals,distinct_customers}')::bigint<>2
     or (v_report#>>'{totals,first_time_customers}')::bigint<>0 then
    raise exception 'v175 assert 8 failed: single-day totals are wrong (%)',
      v_report->'totals';
  end if;

  -- 9. A foreign firm's owner cannot read this firm's aggregate.
  perform pg_temp.as_v175_user(v_owner_b);
  begin
    v_report:=public.platform_customer_account_opens_v175(
      v_business_a,v_yesterday,v_today
    );
    raise exception 'v175 assert 9 failed: foreign owner read the aggregate';
  exception when insufficient_privilege then
    null;
  end;

  -- 10. An unauthenticated caller is refused before any scope test.
  execute 'reset role';
  perform set_config('request.jwt.claim.sub','',true);
  perform set_config('request.jwt.claims','{}',true);
  set local role anon;
  begin
    v_report:=public.platform_customer_account_opens_v175(
      v_business_a,v_yesterday,v_today
    );
    raise exception 'v175 assert 10 failed: anon read the aggregate';
  exception
    when invalid_authorization_specification then null;
    when insufficient_privilege then null;
  end;
  execute 'reset role';

  -- 11. The evidence table itself is append-only.
  begin
    update public.customer_account_open_days_v175
       set channel='booking'
     where business_id=v_business_a;
    raise exception 'v175 assert 11 failed: evidence row was updated';
  exception when restrict_violation then
    null;
  end;

  raise notice 'v175 customer account-open acceptance: 11/11 assertions passed';
end
$v175_account_open$;

rollback;
