-- NESTLY v93 deterministic end-to-end synthetic campaign.
-- Remote-safe only on an approved disposable/rehearsal database. Every row is
-- inside this transaction and the file proves zero residue after ROLLBACK.

begin;

create or replace function pg_temp.as_e2e_user(
  p_uid uuid,p_role text default 'authenticated'
) returns void language plpgsql as $$
begin
  execute format('set local role %I',p_role);
  perform set_config('request.jwt.claim.sub',coalesce(p_uid::text,''),true);
  perform set_config('request.jwt.claims',
    json_build_object('sub',p_uid,'role',p_role)::text,true);
end
$$;
grant execute on function pg_temp.as_e2e_user(uuid,text) to public;

do $campaign$
declare
  v_owner constant uuid:='92000000-0000-4000-8000-000000000101';
  v_manager constant uuid:='92000000-0000-4000-8000-000000000102';
  v_frontdesk constant uuid:='92000000-0000-4000-8000-000000000103';
  v_customer_a constant uuid:='92000000-0000-4000-8000-000000000104';
  v_customer_b constant uuid:='92000000-0000-4000-8000-000000000105';
  v_outsider constant uuid:='92000000-0000-4000-8000-000000000106';
  v_business constant uuid:='92000000-0000-4000-8000-000000000110';
  v_branch constant uuid:='92000000-0000-4000-8000-000000000111';
  v_other_branch constant uuid:='92000000-0000-4000-8000-000000000115';
  v_owner_staff constant uuid:='92000000-0000-4000-8000-000000000112';
  v_manager_staff constant uuid:='92000000-0000-4000-8000-000000000113';
  v_frontdesk_staff constant uuid:='92000000-0000-4000-8000-000000000114';
  v_service_a constant uuid:='92000000-0000-4000-8000-000000000120';
  v_service_b constant uuid:='92000000-0000-4000-8000-000000000121';
  v_product_a constant uuid:='92000000-0000-4000-8000-000000000122';
  v_product_b constant uuid:='92000000-0000-4000-8000-000000000123';
  v_stock_a constant uuid:='92000000-0000-4000-8000-000000000124';
  v_stock_b constant uuid:='92000000-0000-4000-8000-000000000125';
  v_identity_a constant uuid:='92000000-0000-4000-8000-000000000130';
  v_identity_b constant uuid:='92000000-0000-4000-8000-000000000131';
  v_config constant uuid:='92000000-0000-4000-8000-000000000140';
  v_reward constant uuid:='92000000-0000-4000-8000-000000000141';
  v_reward_version constant uuid:='92000000-0000-4000-8000-000000000142';
  v_appointment constant uuid:='92000000-0000-4000-8000-000000000150';
  v_client_a uuid;
  v_client_b uuid;
  v_join_token text;
  v_result jsonb;
  v_history jsonb;
  v_sale uuid;
  v_reversal uuid;
  v_replacement uuid;
  v_intent uuid;
  v_qr_token text;
  v_points_before integer;
  v_redemptions_before integer;
begin
  insert into auth.users(
    instance_id,id,aud,role,email,phone,encrypted_password,email_confirmed_at,
    phone_confirmed_at,created_at,updated_at
  ) values
    ('00000000-0000-0000-0000-000000000000',v_owner,'authenticated',
      'authenticated','nestly-e2e-owner-v92@example.test',null,'',now(),null,now(),now()),
    ('00000000-0000-0000-0000-000000000000',v_manager,'authenticated',
      'authenticated','nestly-e2e-manager-v92@example.test',null,'',now(),null,now(),now()),
    ('00000000-0000-0000-0000-000000000000',v_frontdesk,'authenticated',
      'authenticated','nestly-e2e-frontdesk-v92@example.test',null,'',now(),null,now(),now()),
    ('00000000-0000-0000-0000-000000000000',v_customer_a,'authenticated',
      'authenticated','nestly-e2e-customer-a-v92@example.test','+6599000091','',
      now(),now(),now(),now()),
    ('00000000-0000-0000-0000-000000000000',v_customer_b,'authenticated',
      'authenticated','nestly-e2e-customer-b-v92@example.test','+6599000092','',
      now(),now(),now(),now()),
    ('00000000-0000-0000-0000-000000000000',v_outsider,'authenticated',
      'authenticated','nestly-e2e-outsider-v92@example.test',null,'',now(),null,now(),now());

  insert into public.businesses(
    id,name,slug,industry,currency,is_synthetic,join_enabled,enabled_modules,
    created_at,updated_at
  ) values(
    v_business,'ZZZ SYNTHETIC V92 E2E – Points','zzz-synthetic-v92-points',
    'facial','SGD',true,true,
    array['dashboard','till','clients','appointments','sales','services',
      'bookings','waitlist','inventory','loyalty','reports'],
    now(),now()
  );
  insert into public.branches(id,business_id,name,is_default,active)
  values
    (v_branch,v_business,'Synthetic Orchard Branch',true,true),
    (v_other_branch,v_business,'Synthetic Unassigned Branch',false,true);
  insert into public.staff(
    id,business_id,user_id,role,full_name,active
  ) values
    (v_owner_staff,v_business,v_owner,'owner','Synthetic Owner',true),
    (v_manager_staff,v_business,v_manager,'manager','Synthetic Manager',true),
    (v_frontdesk_staff,v_business,v_frontdesk,'frontdesk','Synthetic Front Desk',true);
  insert into public.staff_branches(business_id,staff_id,branch_id) values
    (v_business,v_owner_staff,v_branch),
    (v_business,v_manager_staff,v_branch),
    (v_business,v_frontdesk_staff,v_branch);

  insert into public.services(
    id,business_id,name,price_cents,duration_min,active,show_on_booking_page
  ) values
    (v_service_a,v_business,'Glow Facial',6800,60,true,true),
    (v_service_b,v_business,'Express Recovery',3800,30,true,true);
  insert into public.products(
    id,business_id,name,sku,retail_price_cents,active
  ) values
    (v_product_a,v_business,'Hydration Serum','SYN-SERUM-01',4200,true),
    (v_product_b,v_business,'Recovery Mask','SYN-MASK-01',1800,true);
  insert into public.stock_batches(
    id,product_id,qty,expires_on,received_on
  ) values
    (v_stock_a,v_product_a,20,current_date+180,current_date),
    (v_stock_b,v_product_b,35,current_date+90,current_date);

  insert into public.customer_identities(
    id,auth_user_id,status,created_via
  ) values
    (v_identity_a,v_customer_a,'active','phone_registration'),
    (v_identity_b,v_customer_b,'active','phone_registration');
  perform set_config('app.c42_profile_identity',v_identity_a::text,true);
  insert into public.customer_profiles(
    identity_id,auth_user_id,full_name,birth_date
  ) values(v_identity_a,v_customer_a,'Synthetic Customer A','1990-01-01');
  perform set_config('app.c42_profile_identity',v_identity_b::text,true);
  insert into public.customer_profiles(
    identity_id,auth_user_id,full_name,birth_date
  ) values(v_identity_b,v_customer_b,'Synthetic Customer B','1991-02-02');
  perform set_config('app.c42_profile_identity','',true);

  perform pg_temp.as_e2e_user(v_owner);
  v_result:=public.business_rotate_customer_join_qr_v90(
    v_business,now()+interval '7 days'
  );
  reset role;
  v_join_token:=v_result->>'join_token';
  if nullif(v_join_token,'') is null then
    raise exception 'campaign did not issue an owner-controlled join token';
  end if;

  perform pg_temp.as_e2e_user(v_customer_a);
  v_result:=public.customer_join_business_from_qr_v89(
    v_join_token,'92000000-0000-4000-8000-000000000160'
  );
  reset role;
  select client_id into v_client_a from public.customer_links
  where business_id=v_business and auth_user_id=v_customer_a
    and identity_id=v_identity_a and state='verified';
  perform pg_temp.as_e2e_user(v_customer_b);
  v_result:=public.customer_join_business_from_qr_v89(
    v_join_token,'92000000-0000-4000-8000-000000000161'
  );
  reset role;
  select client_id into v_client_b from public.customer_links
  where business_id=v_business and auth_user_id=v_customer_b
    and identity_id=v_identity_b and state='verified';
  if v_client_a is null or v_client_b is null or v_client_a=v_client_b then
    raise exception 'QR join did not create two isolated customer relationships';
  end if;
  update public.clients set is_synthetic=true
  where id in(v_client_a,v_client_b) and business_id=v_business;
  if (select count(*) from public.customer_links
      where business_id=v_business and state='verified')<>2 then
    raise exception 'QR join did not produce exactly two verified customer links';
  end if;

  perform pg_temp.as_e2e_user(v_owner);
  v_result:=public.business_set_customer_capabilities_v89(
    v_business,true,true,true
  );
  reset role;
  if not (v_result->>'booking_enabled')::boolean
     or not (v_result->>'redemption_enabled')::boolean then
    raise exception 'owner capability controls did not persist: %',v_result;
  end if;

  insert into public.firm_config_versions(
    id,business_id,version_no,status,source,snapshot_hash,created_by
  ) values(v_config,v_business,1,'draft','manual',md5('nestly:e2e:v92'),v_owner);
  perform set_config('request.jwt.claim.sub',v_owner::text,true);
  perform set_config('request.jwt.claims',json_build_object(
    'sub',v_owner,'role','authenticated')::text,true);
  insert into public.loyalty_program_versions(
    config_version_id,business_id,kind,loyalty_model,active,
    earn_points_per_dollar,redeem_points,reward_credit_cents,tier_basis,
    expiry_mode
  ) values(
    v_config,v_business,'points','points_tiers',true,1,20,0,
    'points_earned','none'
  );
  insert into public.loyalty_rewards(
    id,business_id,name,cost_points,credit_cents,active,internal_name,
    customer_name,fulfillment_kind,estimated_cost_cents
  ) values(
    v_reward,v_business,'Recovery Mask Reward',20,0,true,
    'Recovery Mask Reward','Free Recovery Mask','manual_item',400
  );
  insert into public.loyalty_reward_versions(
    id,reward_id,business_id,config_version_id,internal_name,customer_name,
    fulfillment_kind,cost_points,credit_cents,estimated_cost_cents,active
  ) values(
    v_reward_version,v_reward,v_business,v_config,'Recovery Mask Reward',
    'Free Recovery Mask','manual_item',20,0,400,true
  );
  perform set_config('request.jwt.claim.sub','',true);
  perform set_config('request.jwt.claims','',true);
  update public.firm_config_versions
  set status='published',published_at=now() where id=v_config;
  insert into public.loyalty_programs(
    business_id,kind,active,loyalty_model,configuration_status,
    current_config_version_id
  ) values(
    v_business,'points',true,'points_tiers','published',v_config
  );
  perform set_config('app.v79_system_transition','on',true);
  update public.businesses
  set active_config_version_id=v_config where id=v_business;
  perform set_config('app.v79_system_transition','',true);

  perform pg_temp.as_e2e_user(v_frontdesk);
  v_result:=public.record_quick_sale(
    v_business,2500,'cash',v_client_a,v_frontdesk_staff,v_branch,
    'Synthetic first visit','nestly:e2e:v92:sale:001',true
  )::jsonb;
  reset role;
  v_sale:=(v_result#>>'{sale,id}')::uuid;
  if v_sale is null
     or (select coalesce(sum(points),0) from public.points_ledger
       where business_id=v_business and client_id=v_client_a)<>25 then
    raise exception 'sale and points earn did not reconcile: %',v_result;
  end if;

  perform pg_temp.as_e2e_user(v_customer_a);
  v_history:=public.customer_get_transaction_history_v81(
    'zzz-synthetic-v92-points',jsonb_build_object('limit',20)
  );
  reset role;
  if (select count(*) from jsonb_array_elements(v_history->'items') item
      where (item->>'source_id')::uuid=v_sale
        and (item->>'points_earned')::integer=25)<>1 then
    raise exception 'customer history did not receive the firm-side earn: %',v_history;
  end if;

  perform pg_temp.as_e2e_user(v_manager);
  v_result:=public.correct_quick_sale_amount_v84(
    v_business,v_sale,2800,'nestly:e2e:v92:correct:001',null
  );
  reset role;
  v_reversal:=(v_result->>'reversal_sale_id')::uuid;
  v_replacement:=(v_result->>'replacement_sale_id')::uuid;
  if v_result->>'status'<>'corrected'
     or v_reversal is null or v_replacement is null
     or (select coalesce(sum(points),0) from public.points_ledger
       where business_id=v_business and client_id=v_client_a)<>28 then
    raise exception 'quick amendment did not produce one reconciled replacement: %',
      v_result;
  end if;

  insert into public.appointments(
    id,business_id,branch_id,client_id,staff_id,starts_at,ends_at,status,note
  ) values(
    v_appointment,v_business,v_branch,v_client_a,v_frontdesk_staff,
    now()+interval '2 days',now()+interval '2 days 1 hour','booked',
    'Synthetic appointment'
  );
  insert into public.appointment_services(
    appointment_id,service_id,price_cents
  ) values(v_appointment,v_service_a,6800);

  perform pg_temp.as_e2e_user(v_customer_a);
  v_result:=public.customer_get_appointments_page(
    'zzz-synthetic-v92-points',jsonb_build_object('limit',20)
  );
  reset role;
  if (select count(*) from jsonb_array_elements(v_result->'items') item
      where (item->>'appointment_id')::uuid=v_appointment)<>1 then
    raise exception 'customer appointment view did not sync the firm appointment: %',
      v_result;
  end if;

  select coalesce(sum(points),0)::integer into v_points_before
  from public.points_ledger
  where business_id=v_business and client_id=v_client_a;
  select count(*) into v_redemptions_before
  from public.loyalty_redemptions
  where business_id=v_business and client_id=v_client_a;
  perform pg_temp.as_e2e_user(v_customer_a);
  v_result:=public.customer_create_redemption_intent_v89(
    v_business,v_reward,'92000000-0000-4000-8000-000000000170',
    'catalog_reward'
  );
  reset role;
  v_intent:=(v_result->>'intent_id')::uuid;
  v_qr_token:=v_result->>'qr_token';
  if v_result->>'status'<>'pending'
     or (select coalesce(sum(points),0)::integer from public.points_ledger
       where business_id=v_business and client_id=v_client_a)<>v_points_before
     or (select count(*) from public.loyalty_redemptions
       where business_id=v_business and client_id=v_client_a)<>v_redemptions_before then
    raise exception 'presenting a redemption QR changed value before merchant scan';
  end if;

  begin
    perform pg_temp.as_e2e_user(v_customer_b);
    perform public.customer_get_redemption_intent_v89(v_intent);
    reset role;
    raise exception 'customer B read customer A redemption intent';
  exception when insufficient_privilege then reset role;
  end;
  begin
    perform pg_temp.as_e2e_user(v_outsider);
    perform public.merchant_scan_redemption_qr_v93(
      v_business,v_branch,v_qr_token,
      '92000000-0000-4000-8000-000000000171'
    );
    reset role;
    raise exception 'outsider completed a merchant redemption';
  exception when insufficient_privilege then reset role;
  end;
  begin
    perform pg_temp.as_e2e_user(v_frontdesk);
    perform public.merchant_scan_redemption_qr_v93(
      v_business,v_other_branch,v_qr_token,
      '92000000-0000-4000-8000-000000000174'
    );
    reset role;
    raise exception 'front desk completed a redemption outside its assigned branch';
  exception when insufficient_privilege then reset role;
  end;
  begin
    perform pg_temp.as_e2e_user(v_frontdesk);
    perform public.merchant_scan_redemption_qr_v89(
      v_business,v_qr_token,
      '92000000-0000-4000-8000-000000000175'
    );
    reset role;
    raise exception 'front desk downgraded to the branchless v89 scanner';
  exception when insufficient_privilege then reset role;
  end;
  if (select status from public.customer_redemption_intents_v89
      where id=v_intent)<>'pending'
     or (select count(*) from public.loyalty_redemptions
       where business_id=v_business and client_id=v_client_a)
       <>v_redemptions_before then
    raise exception 'denied legacy scan changed redemption state';
  end if;

  perform pg_temp.as_e2e_user(v_frontdesk);
  v_result:=public.merchant_scan_redemption_qr_v93(
    v_business,v_branch,v_qr_token,
    '92000000-0000-4000-8000-000000000172'
  );
  reset role;
  if v_result->>'status'<>'completed'
     or (v_result->>'points_spent')::integer<>20
     or (select coalesce(sum(points),0)::integer from public.points_ledger
       where business_id=v_business and client_id=v_client_a)<>8
     or (select count(*) from public.loyalty_redemptions
       where business_id=v_business and client_id=v_client_a)
       <>v_redemptions_before+1
     or (select eligibility_snapshot#>>'{selected,branch_id}'
           from public.loyalty_redemptions
          where business_id=v_business
            and client_id=v_client_a
          order by redeemed_at desc,id desc
          limit 1)<>v_branch::text then
    raise exception 'merchant QR scan did not complete exactly one redemption: %',
      v_result;
  end if;

  perform pg_temp.as_e2e_user(v_frontdesk);
  v_result:=public.merchant_scan_redemption_qr_v93(
    v_business,v_branch,v_qr_token,
    '92000000-0000-4000-8000-000000000173'
  );
  reset role;
  if not (v_result->>'replayed')::boolean
     or (select count(*) from public.loyalty_redemptions
       where business_id=v_business and client_id=v_client_a)
       <>v_redemptions_before+1 then
    raise exception 'merchant QR replay produced another economic effect: %',
      v_result;
  end if;

  perform pg_temp.as_e2e_user(v_customer_a);
  v_history:=public.customer_get_transaction_history_v81(
    'zzz-synthetic-v92-points',jsonb_build_object('limit',50)
  );
  reset role;
  if not exists(
    select 1 from jsonb_array_elements(v_history->'items') item
    where (item->>'source_id')::uuid=v_replacement
      and (item->>'points_earned')::integer=28
  ) or not exists(
    select 1 from jsonb_array_elements(v_history->'items') item
    where (item->>'points_redeemed')::integer=20
  ) then
    raise exception 'final customer history omitted earn/amendment/redemption evidence: %',
      v_history;
  end if;

  if (select count(*) from public.captured_messages
      where recipient not like '%@example.test'
        and recipient not like '+65990000%'
        and recipient not like 'synthetic:%')<>0 then
    raise exception 'campaign found a non-synthetic captured-message recipient';
  end if;
end
$campaign$;

rollback;

do $zero_residue$
begin
  if exists(
    select 1 from public.businesses
    where id='92000000-0000-4000-8000-000000000110'
       or slug='zzz-synthetic-v92-points'
  ) or exists(
    select 1 from auth.users
    where id between
      '92000000-0000-4000-8000-000000000101'::uuid
      and '92000000-0000-4000-8000-000000000106'::uuid
  ) then
    raise exception 'v92 synthetic campaign left database residue after rollback';
  end if;
end
$zero_residue$;
