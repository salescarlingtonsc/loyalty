-- Rollback-only acceptance for the v122 owner seven-workflow phase.
-- Run after the canonical chain through v122 in a disposable database.
begin;

do $v122_contracts$
declare
  v_definition text;
  v_count integer;
begin
  select pg_get_constraintdef(oid) into v_definition
  from pg_constraint
  where conrelid='public.products'::regclass
    and conname='products_cost_cents_check';
  if v_definition is null
     or v_definition not ilike '%cost_cents >= 0%'
     or v_definition not ilike '%cost_cents <= 2147483647%' then
    raise exception 'product cost constraint is absent or no longer fail-closed: %',
      v_definition;
  end if;

  if not exists (
    select 1 from information_schema.columns
    where table_schema='public' and table_name='products'
      and column_name='cost_cents' and data_type='bigint'
      and is_nullable='YES'
  ) then
    raise exception 'products.cost_cents is not a nullable bigint';
  end if;

  if not app.c46_in_app_topic_allowed('promotion_alerts')
     or app.c46_in_app_topic_allowed('marketing') then
    raise exception 'promotion consent topic is not explicit and closed';
  end if;
  if not app.customer_push_event_eligible_v95(
       'v122_promotion_new','promotion_alerts'
     )
     or not app.customer_push_event_eligible_v95(
       'v122_promotion_expiry','promotion_alerts'
     )
     or app.customer_push_event_eligible_v95(
       'v122_promotion_new','booking_updates'
     ) then
    raise exception 'promotion push eligibility is not source/topic bound';
  end if;

  if to_regprocedure(
       'public.customer_get_in_app_inbox_preferences(text)'
     ) is null
     or to_regprocedure(
       'app.enqueue_promotion_alert_v122(uuid,text)'
     ) is null
     or to_regprocedure(
       'app.enqueue_due_promotion_alerts_v122()'
     ) is null
     or to_regprocedure(
       'public.customer_get_pending_promotion_prompt_v122(text)'
     ) is null
     or to_regprocedure(
       'public.owner_list_reward_profitability_products_v122(uuid)'
     ) is null
     or to_regprocedure(
       'public.owner_set_product_cost_v122(uuid,uuid,bigint,bigint)'
     ) is null then
    raise exception 'v122 inbox or promotion alert functions are incomplete';
  end if;

  if has_function_privilege(
       'public',
       'public.customer_get_in_app_inbox_preferences(text)',
       'execute'
     )
     or has_function_privilege(
       'anon',
       'public.customer_get_in_app_inbox_preferences(text)',
       'execute'
     )
     or not has_function_privilege(
       'authenticated',
       'public.customer_get_in_app_inbox_preferences(text)',
       'execute'
     )
     or has_function_privilege(
       'public',
       'public.owner_set_product_cost_v122(uuid,uuid,bigint,bigint)',
       'execute'
     )
     or has_function_privilege(
       'anon',
       'public.owner_set_product_cost_v122(uuid,uuid,bigint,bigint)',
       'execute'
     )
     or not has_function_privilege(
       'authenticated',
       'public.owner_set_product_cost_v122(uuid,uuid,bigint,bigint)',
       'execute'
     ) then
    raise exception 'v122 browser RPC ACL is not authenticated-only';
  end if;

  select count(*) into v_count
  from pg_trigger
  where tgrelid='public.visit_feedback'::regclass
    and tgname='visit_feedback_v122_notify_staff'
    and not tgisinternal
    and tgenabled<>'D';
  if v_count<>1 then
    raise exception 'feedback notification trigger is absent or disabled';
  end if;

  select count(*) into v_count
  from cron.job
  where jobname='nestly-v122-promotion-alerts'
    and schedule='*/15 * * * *'
    and command='select app.enqueue_due_promotion_alerts_v122()';
  if v_count<>1 then
    raise exception 'promotion activation/expiry schedule is absent or duplicated';
  end if;

  if app.enqueue_promotion_alert_v122(
       gen_random_uuid(),'v122_promotion_new'
     )<>0 then
    raise exception 'missing promotion unexpectedly enqueued an alert';
  end if;

  begin
    perform app.enqueue_promotion_alert_v122(
      gen_random_uuid(),'unsupported'
    );
    raise exception 'unsupported promotion source unexpectedly succeeded';
  exception
    when sqlstate '22023' then null;
  end;
end
$v122_contracts$;

create or replace function pg_temp.as_v122_user(p_user uuid)
returns void language plpgsql as $$
begin
  reset role;
  perform set_config('request.jwt.claim.sub',p_user::text,true);
  perform set_config(
    'request.jwt.claims',
    json_build_object('sub',p_user,'role','authenticated')::text,
    true
  );
  execute 'set local role authenticated';
end
$$;
grant execute on function pg_temp.as_v122_user(uuid) to public;

do $v122_two_staff$
declare
  v_owner uuid:=gen_random_uuid();
  v_alina_user uuid:=gen_random_uuid();
  v_maya_user uuid:=gen_random_uuid();
  v_customer_user uuid:=gen_random_uuid();
  v_business uuid;
  v_business_slug text;
  v_branch uuid;
  v_alina_staff uuid;
  v_maya_staff uuid;
  v_service uuid;
  v_product uuid;
  v_client_one uuid;
  v_client_two uuid;
  v_identity uuid;
  v_link uuid;
  v_promotion uuid:=gen_random_uuid();
  v_future_promotion uuid:=gen_random_uuid();
  v_prompt jsonb;
  v_event uuid;
  v_feedback_key uuid:=gen_random_uuid();
  v_feedback_result jsonb;
  v_feedback_id uuid;
  v_local_day timestamp:=
    date_trunc('day',clock_timestamp() at time zone 'Asia/Singapore')
    +interval '2 days';
  v_starts timestamptz;
  v_weekday smallint;
  v_alina_result jsonb;
  v_maya_result jsonb;
begin
  v_starts:=(v_local_day+interval '10 hours')
    at time zone 'Asia/Singapore';
  v_weekday:=extract(dow from v_local_day)::smallint;

  insert into auth.users(
    instance_id,id,aud,role,email,encrypted_password,
    email_confirmed_at,created_at,updated_at
  ) values
    (
      '00000000-0000-0000-0000-000000000000',v_owner,
      'authenticated','authenticated',
      'v122-owner-'||substr(v_owner::text,1,8)||'@example.test',
      '',now(),now(),now()
    ),
    (
      '00000000-0000-0000-0000-000000000000',v_alina_user,
      'authenticated','authenticated',
      'v122-alina-'||substr(v_alina_user::text,1,8)||'@example.test',
      '',now(),now(),now()
    ),
    (
      '00000000-0000-0000-0000-000000000000',v_maya_user,
      'authenticated','authenticated',
      'v122-maya-'||substr(v_maya_user::text,1,8)||'@example.test',
      '',now(),now(),now()
    ),
    (
      '00000000-0000-0000-0000-000000000000',v_customer_user,
      'authenticated','authenticated',
      'v122-customer-'||substr(v_customer_user::text,1,8)||'@example.test',
      '',now(),now(),now()
    );

  v_business_slug:='glow-v122-'||replace(v_owner::text,'-','');
  insert into public.businesses(
    name,slug,industry,enabled_modules,created_at
  ) values(
    'Glow Atelier V122',
    v_business_slug,
    'facial',
    array['dashboard','clients','services','branches','appointments','loyalty'],
    '2000-01-01'
  ) returning id into v_business;
  update public.business_workspace_controls_v94
  set approval_status='approved',version=version+1,
      decided_at=statement_timestamp(),
      decision_reason='approved synthetic V122 rollback fixture',
      updated_at=statement_timestamp()
  where business_id=v_business and approval_status='pending';
  if not found then
    raise exception 'V122 fixture workspace control was not pending';
  end if;

  insert into public.staff(
    business_id,user_id,role,full_name,active,modules,module_perms
  ) values
    (v_business,v_owner,'owner','Olivia Tan',true,null,null),
    (
      v_business,v_alina_user,'staff','Alina Chen',true,
      array['appointments'],'{"appointments":"rw"}'
    ),
    (
      v_business,v_maya_user,'staff','Maya Lim',true,
      array['appointments'],'{"appointments":"rw"}'
    );
  select id into v_alina_staff from public.staff
  where business_id=v_business and user_id=v_alina_user;
  select id into v_maya_staff from public.staff
  where business_id=v_business and user_id=v_maya_user;

  insert into public.branches(
    business_id,name,timezone,active,is_default
  ) values(
    v_business,'Orchard','Asia/Singapore',true,true
  ) returning id into v_branch;
  insert into public.staff_branches(business_id,staff_id,branch_id)
  values
    (v_business,v_alina_staff,v_branch),
    (v_business,v_maya_staff,v_branch);
  insert into public.branch_hours(
    business_id,branch_id,weekday,opens_at,closes_at
  ) values(v_business,v_branch,v_weekday,'09:00','18:00');
  insert into public.staff_hours(
    business_id,staff_id,weekday,starts_at,ends_at
  ) values
    (v_business,v_alina_staff,v_weekday,'09:00','18:00'),
    (v_business,v_maya_staff,v_weekday,'09:00','18:00');
  insert into public.services(
    business_id,name,variant_label,price_cents,duration_min,active,
    buffer_before_min,buffer_after_min
  ) values(
    v_business,'Signature facial','60 min',6800,60,true,15,15
  ) returning id into v_service;
  insert into public.products(
    business_id,name,sku,retail_price_cents,active
  ) values(
    v_business,'Hydration mask','V122-MASK',6800,true
  ) returning id into v_product;
  insert into public.staff_services(business_id,staff_id,service_id)
  values
    (v_business,v_alina_staff,v_service),
    (v_business,v_maya_staff,v_service);
  insert into public.clients(business_id,full_name,phone)
  values(v_business,'Mei Lin','+6581864567')
  returning id into v_client_one;
  insert into public.clients(business_id,full_name,phone)
  values(v_business,'Nur Aisyah','+6581864568')
  returning id into v_client_two;

  insert into public.customer_identities(auth_user_id)
  values(v_customer_user) returning id into v_identity;
  v_link:=gen_random_uuid();
  perform set_config('app.customer_link_insert_id',v_link::text,true);
  insert into public.customer_links(
    id,business_id,identity_id,auth_user_id,client_id,state,
    verification_method,verified_at
  ) values(
    v_link,v_business,v_identity,v_customer_user,v_client_one,'verified',
    'firm_invitation',now()
  );
  perform set_config('app.customer_link_insert_id','',true);
  insert into public.customer_notification_preferences(
    business_id,identity_id,auth_user_id,link_id,client_id,
    channel,topic,opted_in,consent_at
  ) values(
    v_business,v_identity,v_customer_user,v_link,v_client_one,
    'in_app','promotion_alerts',true,now()
  );
  update app.platform_feature_flags
  set enabled=true,changed_at=now()
  where feature_key='customer_in_app_inbox';

  perform set_config('app.v104_promotion_write','on',true);
  insert into public.business_customer_content_v95(
    id,business_id,content_type,branch_id,active,display_order,
    starts_at,ends_at,metadata,updated_by
  ) values(
    v_promotion,v_business,'offer',null,true,1,
    now()-interval '1 hour',now()+interval '10 days',
    jsonb_build_object(
      'schema','nestly.promotion.v104',
      'published_once_at',to_jsonb(now()-interval '1 hour')
    ),v_owner
  );
  insert into public.business_customer_content_v95(
    id,business_id,content_type,branch_id,active,display_order,
    starts_at,ends_at,metadata,updated_by
  ) values(
    v_future_promotion,v_business,'offer',null,true,2,
    now()+interval '1 day',now()+interval '12 days',
    jsonb_build_object(
      'schema','nestly.promotion.v104',
      'published_once_at',to_jsonb(now())
    ),v_owner
  );
  perform set_config('app.v104_promotion_write','',true);
  perform set_config('app.v104_promotion_media_write','on',true);
  insert into public.business_media_assets_v95(
    business_id,asset_kind,entity_id,branch_id,object_path,mime_type,
    width_px,height_px,alt_en,customer_visible,updated_by
  ) values(
    v_business,'offer',v_promotion,null,
    v_business::text||'/offer/'||v_promotion::text||'.png',
    'image/png',1200,800,'Hydration promotion',true,v_owner
  );
  perform set_config('app.v104_promotion_media_write','',true);

  if app.enqueue_promotion_alert_v122(
       v_future_promotion,'v122_promotion_new'
     )<>0 then
    raise exception 'future/media-less promotion unexpectedly enqueued';
  end if;
  if app.enqueue_promotion_alert_v122(
       v_promotion,'v122_promotion_new'
     )<>1 then
    raise exception 'visible promotion did not enqueue exactly one customer event';
  end if;
  if app.enqueue_promotion_alert_v122(
       v_promotion,'v122_promotion_new'
     )<>0 then
    raise exception 'promotion campaign watermark did not prevent repeat fanout';
  end if;

  select id into v_event from public.customer_in_app_inbox_events
  where identity_id=v_identity and source_kind='v122_promotion_new';
  perform pg_temp.as_v122_user(v_customer_user);
  v_prompt:=public.customer_get_pending_promotion_prompt_v122(v_business_slug);
  if v_prompt->>'event_id' is distinct from v_event::text
     or v_prompt->>'promotion_id' is distinct from v_promotion::text then
    raise exception 'unread promotion event did not resolve to its exact prompt: %',
      v_prompt;
  end if;
  perform public.customer_sync_in_app_inbox(v_business_slug,gen_random_uuid());
  reset role;
  if exists(
    select 1 from public.customer_in_app_inbox_resolutions
    where event_id=v_event
  ) then
    raise exception 'generic inbox sync incorrectly resolved a current promotion';
  end if;
  perform pg_temp.as_v122_user(v_customer_user);
  if public.customer_get_pending_promotion_prompt_v122(v_business_slug) is null then
    raise exception 'current promotion disappeared after generic inbox sync';
  end if;
  reset role;

  update public.customer_notification_preferences
  set opted_in=false,updated_at=now()
  where business_id=v_business and link_id=v_link
    and channel='in_app' and topic='promotion_alerts';
  perform pg_temp.as_v122_user(v_customer_user);
  if public.customer_get_pending_promotion_prompt_v122(v_business_slug) is not null then
    raise exception 'opted-out customer still received a promotion popup';
  end if;
  reset role;
  update public.customer_notification_preferences
  set opted_in=true,updated_at=now()
  where business_id=v_business and link_id=v_link
    and channel='in_app' and topic='promotion_alerts';

  perform set_config('app.v104_promotion_write','on',true);
  update public.business_customer_content_v95
  set ends_at=ends_at+interval '1 day'
  where id=v_promotion;
  perform set_config('app.v104_promotion_write','',true);
  if app.enqueue_promotion_alert_v122(
       v_promotion,'v122_promotion_new'
     )<>0 then
    raise exception 'end-date edit created a duplicate new-promotion fanout';
  end if;
  if 1<>(select count(*) from public.customer_in_app_inbox_events
    where identity_id=v_identity and source_kind='v122_promotion_new'
  ) then
    raise exception 'end-date edit duplicated the new-promotion event';
  end if;

  perform pg_temp.as_v122_user(v_customer_user);
  perform public.customer_set_in_app_inbox_state(
    v_business_slug,v_event,'read',gen_random_uuid()
  );
  if public.customer_get_pending_promotion_prompt_v122(v_business_slug) is not null then
    raise exception 'read promotion event still produced a popup';
  end if;
  v_feedback_result:=public.customer_submit_visit_feedback(
    v_business_slug,null,2,'The appointment started late.',v_feedback_key
  );
  v_feedback_id:=(v_feedback_result->>'id')::uuid;
  if (public.customer_submit_visit_feedback(
      v_business_slug,null,2,'The appointment started late.',v_feedback_key
    )->>'id')::uuid is distinct from v_feedback_id then
    raise exception 'feedback idempotency replay returned another record';
  end if;
  reset role;
  if 1<>(select count(*) from public.visit_feedback
    where id=v_feedback_id and business_id=v_business
      and identity_id=v_identity and rating=2
  ) then
    raise exception 'customer feedback did not persist exactly once';
  end if;
  if 1<>(select count(*) from public.notifications
    where business_id=v_business and kind='feedback_new'
      and ref_table='visit_feedback' and ref_id=v_feedback_id
  ) then
    raise exception 'feedback did not create exactly one matching staff notification';
  end if;

  perform pg_temp.as_v122_user(v_owner);
  if (public.owner_list_reward_profitability_products_v122(v_business)
      ->'items'->0->>'id') is distinct from v_product::text then
    raise exception 'owner profitability product list did not return the active product';
  end if;
  if (public.owner_set_product_cost_v122(
      v_business,v_product,2400,null
    )->>'cost_cents')::bigint<>2400 then
    raise exception 'owner product cost did not persist';
  end if;
  if not (public.owner_set_product_cost_v122(
      v_business,v_product,2400,null
    )->>'replayed')::boolean then
    raise exception 'same-value product cost retry was not replay-safe';
  end if;
  v_alina_result:=public.book_appointment_smart_v47(
    v_business,v_client_one,v_branch,v_service,v_starts,60,
    v_alina_staff,'manual','Calendar click: Alina','v122-alina-manual'
  );
  v_maya_result:=public.book_appointment_smart_v47(
    v_business,v_client_two,v_branch,v_service,
    v_starts+interval '2 hours',60,
    v_maya_staff,'manual','Calendar click: Maya','v122-maya-manual'
  );
  reset role;

  if v_alina_result->>'status'<>'booked'
     or v_alina_result->>'staff_id'<>v_alina_staff::text
     or v_maya_result->>'status'<>'booked'
     or v_maya_result->>'staff_id'<>v_maya_staff::text then
    raise exception 'manual two-staff booking receipts are wrong: % / %',
      v_alina_result,v_maya_result;
  end if;
  if 2<>(select count(*) from public.appointments
    where business_id=v_business
      and (
        (
          id=(v_alina_result->>'appointment_id')::uuid
          and staff_id=v_alina_staff
        )
        or (
          id=(v_maya_result->>'appointment_id')::uuid
          and staff_id=v_maya_staff
        )
      )
  ) then
    raise exception 'calendar click bookings did not persist both staff';
  end if;

  perform pg_temp.as_v122_user(v_alina_user);
  begin
    perform public.owner_list_reward_profitability_products_v122(v_business);
    raise exception 'non-owner unexpectedly read reward profitability inputs';
  exception when sqlstate '42501' then null;
  end;
  begin
    perform public.owner_set_product_cost_v122(
      v_business,v_product,2500,2400
    );
    raise exception 'non-owner unexpectedly changed product cost';
  exception when sqlstate '42501' then null;
  end;
  reset role;
end
$v122_two_staff$;

select 'V122 owner seven-workflow acceptance: PASS' as result;
rollback;
