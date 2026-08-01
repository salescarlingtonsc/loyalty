-- Rollback-only acceptance for Nestly V130 self-service business onboarding.
-- Run after the complete canonical chain on a disposable database.
begin;

create or replace function pg_temp.as_v130_user(
  p_uid uuid,
  p_role text default 'authenticated'
) returns void language plpgsql as $$
begin
  execute format('set local role %I',p_role);
  perform set_config('request.jwt.claim.sub',coalesce(p_uid::text,''),true);
  perform set_config(
    'request.jwt.claims',
    json_build_object('sub',p_uid,'role',p_role)::text,
    true
  );
end
$$;
grant execute on function pg_temp.as_v130_user(uuid,text) to public;

create or replace function pg_temp.assert_v130_payment_rejected(
  p_business uuid,p_case text
) returns void language plpgsql as $$
declare
  v_subtotal integer:=142800;
  v_tax integer:=0;
  v_total integer:=142800;
  v_paid integer:=142800;
  v_remaining integer:=0;
  v_cadence text:='annual';
  v_capacity integer:=3000;
  v_blocks integer:=3;
  v_currency text:='SGD';
  v_base_price text:='price_v130_annual_base';
  v_capacity_price text:='price_v130_annual_capacity';
begin
  if p_case='wrong_price' then
    v_base_price:='price_v130_wrong_base';
  elsif p_case='wrong_cadence' then
    v_cadence:='monthly';
    v_base_price:='price_v130_monthly_base';
    v_capacity_price:='price_v130_monthly_capacity';
  elsif p_case='wrong_capacity' then
    v_capacity:=2000;v_blocks:=2;
  elsif p_case='nonzero_tax' then
    v_subtotal:=141800;v_tax:=1000;
  elsif p_case='wrong_total' then
    v_subtotal:=142700;v_total:=142700;v_paid:=142700;
  elsif p_case='amount_remaining' then
    v_paid:=142700;v_remaining:=100;
  elsif p_case='wrong_currency' then
    v_currency:='USD';
  else
    raise exception 'unknown V130 negative payment case';
  end if;
  insert into public.billing_subscription_terms_v124(
    business_id,provider_subscription_id,cadence,customer_capacity,
    capacity_blocks,provider_base_price_id,provider_capacity_item_id,
    provider_capacity_price_id,provider_event_created_at,last_event_id
  ) values(
    p_business,'sub_v130_'||p_case,v_cadence,v_capacity,v_blocks,
    v_base_price,'si_v130_'||p_case,v_capacity_price,now(),
    'evt_v130_terms_'||p_case
  );
  insert into public.billing_provider_invoices(
    business_id,provider_customer_id,provider_subscription_id,
    provider_invoice_id,currency,status,paid_normalized,
    subtotal_ex_tax_cents,tax_cents,total_cents,amount_due_cents,
    amount_paid_cents,amount_remaining_cents,paid_at,livemode,
    provider_event_created_at,provider_event_rank,last_event_id
  ) values(
    p_business,'cus_v130','sub_v130_'||p_case,'in_v130_'||p_case,
    v_currency,'paid',true,v_subtotal,v_tax,v_total,v_total,v_paid,v_remaining,
    now(),false,now(),100,'evt_v130_invoice_'||p_case
  );
  if app.business_workspace_open_v94(p_business)
     or not exists(
       select 1 from public.self_serve_business_onboarding_v130
        where business_id=p_business and status='payment_pending'
     ) then
    raise exception 'V130 accepted invalid payment case %',p_case
      using errcode='P0002';
  end if;
  -- Force rollback of this negative fixture, including any money-back row, so
  -- the same staged workspace can exercise the next independent mismatch.
  raise exception 'v130_expected_negative_rollback' using errcode='P0001';
exception
  when sqlstate 'P0001' then return;
  when check_violation then
    if p_case='nonzero_tax'
       and sqlerrm='V125 GST not charged: invoice tax must be zero' then
      -- V125 rejects non-zero tax at the invoice boundary before V130 can
      -- evaluate activation. That stronger fail-closed result is the expected
      -- outcome for this negative fixture.
      return;
    end if;
    raise;
  when others then raise;
end
$$;
grant execute on function pg_temp.assert_v130_payment_rejected(uuid,text) to public;

do $v130_test$
declare
  v_owner uuid:=gen_random_uuid();
  v_non_loyalty_owner uuid:=gen_random_uuid();
  v_outsider uuid:=gen_random_uuid();
  v_superadmin uuid:=gen_random_uuid();
  v_bundle uuid;
  v_result jsonb;
  v_replay jsonb;
  v_command jsonb;
  v_business uuid;
  v_setup_key uuid:=gen_random_uuid();
  v_checkout_key uuid:=gen_random_uuid();
  v_denied boolean:=false;
  v_paid_at timestamptz:='2026-08-01 10:30:00+00';
begin
  insert into auth.users(
    instance_id,id,aud,role,email,encrypted_password,
    email_confirmed_at,created_at,updated_at
  ) values
    ('00000000-0000-0000-0000-000000000000',v_owner,
     'authenticated','authenticated','sofia.v130@example.test','',now(),now(),now()),
    ('00000000-0000-0000-0000-000000000000',v_non_loyalty_owner,
     'authenticated','authenticated','nonloyalty.v130@example.test','',now(),now(),now()),
    ('00000000-0000-0000-0000-000000000000',v_outsider,
     'authenticated','authenticated','outsider.v130@example.test','',now(),now(),now()),
    ('00000000-0000-0000-0000-000000000000',v_superadmin,
     'authenticated','authenticated','superadmin.v130@example.test','',now(),now(),now());
  insert into public.super_admins(user_id,email,note)
  values(v_superadmin,'superadmin.v130@example.test','V130 rollback-only payment guard');

  insert into public.sector_profiles(sector_key,label,active)
  values('v130_facial','V130 Facial and Spa',true)
  on conflict(sector_key) do update set active=true;
  insert into public.sector_bundle_versions(
    sector_key,version,label,status,modules,published_at
  ) values(
    'v130_facial',1,'V130 Facial and Spa launch',
    'published',array['dashboard','clients','appointments','loyalty'],now()
  ) returning id into v_bundle;
  insert into public.sector_profiles(sector_key,label,active)
  values('v130_no_loyalty','V130 Non-loyalty sector',true)
  on conflict(sector_key) do update set active=true;
  insert into public.sector_bundle_versions(
    sector_key,version,label,status,modules,published_at
  ) values(
    'v130_no_loyalty',1,'V130 Non-loyalty launch',
    'published',array['dashboard','clients'],now()
  );

  update public.billing_plan_catalog_v124
     set active=false,effective_to=now()
   where currency='SGD' and cadence in ('annual','monthly')
     and active and effective_to is null;
  insert into public.billing_plan_catalog_v124(
    currency,cadence,cadence_months,provider_base_price_id,
    provider_capacity_price_id,base_amount_cents,
    capacity_block_amount_cents,tax_behavior,effective_from
  ) values
    ('SGD','annual',12,'price_v130_annual_base','price_v130_annual_capacity',
     118800,12000,'exclusive',now()-interval '1 second'),
    ('SGD','monthly',1,'price_v130_monthly_base','price_v130_monthly_capacity',
     14900,1000,'exclusive',now()-interval '1 second');

  perform pg_temp.as_v130_user(v_non_loyalty_owner);
  v_result:=public.get_self_serve_checkout_v130(null);
  if exists(
    select 1 from jsonb_array_elements(v_result->'sectors') sector
     where sector->>'sector_key'='v130_no_loyalty'
  ) then
    raise exception 'V132 offered a sector that cannot accept the included Loyalty programme';
  end if;
  v_denied:=false;
  begin
    perform public.start_self_serve_business_v130(
      'No Loyalty Owner','No Loyalty Studio',
      'no-loyalty-v130-'||substr(v_non_loyalty_owner::text,1,8),
      'v130_no_loyalty','202688888N','en','annual',1000,true,gen_random_uuid()
    );
  exception when check_violation then
    if sqlerrm='self-service launch requires a published Loyalty-capable sector' then
      v_denied:=true;
    else
      raise;
    end if;
  end;
  reset role;
  if not v_denied
     or exists(
       select 1 from public.businesses
        where slug='no-loyalty-v130-'||substr(v_non_loyalty_owner::text,1,8)
     )
     or exists(select 1 from public.staff where user_id=v_non_loyalty_owner) then
    raise exception 'V132 staged or retained a non-Loyalty self-service workspace';
  end if;

  perform pg_temp.as_v130_user(v_owner);
  v_result:=public.start_self_serve_business_v130(
    'Sofia Ng','Radiant Skin Studio','radiant-v130-'||substr(v_owner::text,1,8),
    'v130_facial','202699999N','en','annual',3000,true,v_setup_key
  );
  reset role;
  v_business:=(v_result->>'business_id')::uuid;
  if v_result->>'status'<>'payment_pending'
     or coalesce((v_result->>'workspace_access')::boolean,true)
     or (v_result->>'total_cents')::integer<>142800 then
    raise exception 'V130 staged workspace did not retain the exact locked selection';
  end if;
  if (select count(*) from public.businesses where id=v_business)<>1
     or (select count(*) from public.staff where business_id=v_business and user_id=v_owner and role='owner' and active)<>1
     or (select count(*) from public.branches where business_id=v_business and is_default and active)<>1
     or (select count(*) from public.subscriptions where business_id=v_business and status='incomplete' and billing_provider='stripe')<>1 then
    raise exception 'V130 did not create exactly one locked workspace identity';
  end if;
  if app.business_workspace_open_v94(v_business)
     or exists(select 1 from public.business_sector_assignments where business_id=v_business)
     or exists(select 1 from public.loyalty_programs where business_id=v_business) then
    raise exception 'V130 exposed tenant configuration before provider-confirmed payment';
  end if;

  -- Legacy Firm 360 decisions must have zero effect on payment-managed firms.
  perform pg_temp.as_v130_user(v_superadmin);
  v_result:=public.get_self_serve_checkout_v130(v_business);
  if v_result->'onboarding'->>'status'<>'payment_pending' then
    raise exception 'V130 did not expose the safe payment-managed marker to Firm 360';
  end if;
  begin
    perform public.platform_decide_business_approval_v94(
      v_business,'approved','manual approval must be denied',
      (select version from public.business_workspace_controls_v94 where business_id=v_business)
    );
  exception when insufficient_privilege then v_denied:=true;
  end;
  if not v_denied then raise exception 'V130 allowed manual approval without payment';end if;
  v_denied:=false;
  begin
    perform public.platform_decide_business_approval_v94(
      v_business,'rejected','manual rejection must be denied',
      (select version from public.business_workspace_controls_v94 where business_id=v_business)
    );
  exception when insufficient_privilege then v_denied:=true;
  end;
  reset role;
  if not v_denied
     or (select approval_status from public.business_workspace_controls_v94 where business_id=v_business)<>'pending'
     or exists(
       select 1 from public.business_workspace_control_audit_v94
        where business_id=v_business and event_type in ('firm_approved','firm_rejected')
     ) then
    raise exception 'V130 manual decision guard changed payment-managed state';
  end if;

  perform pg_temp.as_v130_user(v_owner);
  v_replay:=public.start_self_serve_business_v130(
    'Sofia Ng','Radiant Skin Studio','radiant-v130-'||substr(v_owner::text,1,8),
    'v130_facial','202699999N','en','annual',3000,true,v_setup_key
  );
  if v_replay->>'business_id'<>v_result->>'business_id'
     or not (v_replay->>'replayed')::boolean then
    raise exception 'V130 exact setup retry did not reuse the workspace';
  end if;
  begin
    perform public.start_self_serve_business_v130(
      'Sofia Ng','Radiant Skin Studio','radiant-v130-'||substr(v_owner::text,1,8),
      'v130_facial','202699999N','en','monthly',3000,true,v_setup_key
    );
  exception when invalid_parameter_value then v_denied:=true;
  end;
  if not v_denied then raise exception 'V130 accepted an edited setup replay';end if;
  v_result:=public.get_self_serve_checkout_v130(v_business);
  if v_result->'onboarding'->>'status'<>'payment_pending'
     or (v_result->'onboarding'->>'total_cents')::integer<>142800
     or jsonb_array_length(v_result->'plans')<>2
     or coalesce((v_result->>'gst_registered')::boolean,true) then
    raise exception 'V130 pending owner reader is incomplete or incorrectly taxed';
  end if;
  v_command:=public.request_self_serve_checkout_v130(
    v_business,'annual',3000,v_checkout_key
  );
  v_replay:=public.request_self_serve_checkout_v130(
    v_business,'annual',3000,gen_random_uuid()
  );
  reset role;
  if v_command->>'command_id'<>v_replay->>'command_id'
     or not (v_replay->>'replayed')::boolean
     or (select count(*) from public.billing_commands where business_id=v_business)<>1 then
    raise exception 'V130 checkout retry created a duplicate command';
  end if;
  update public.billing_commands
     set status='completed',requested_at=now()-interval '23 hours 1 minute',
         redirect_url='https://checkout.stripe.test/expired-v130'
   where id=(v_command->>'command_id')::uuid;
  perform pg_temp.as_v130_user(v_owner);
  v_replay:=public.request_self_serve_checkout_v130(
    v_business,'annual',3000,gen_random_uuid()
  );
  reset role;
  if v_replay->>'command_id'=v_command->>'command_id'
     or (select count(*) from public.billing_commands where business_id=v_business)<>2 then
    raise exception 'V130 did not rotate an expired Checkout session safely';
  end if;
  v_command:=v_replay;

  v_denied:=false;
  perform pg_temp.as_v130_user(v_outsider);
  begin
    perform public.get_self_serve_checkout_v130(v_business);
  exception when insufficient_privilege then v_denied:=true;
  end;
  if not v_denied then raise exception 'V130 outsider read pending onboarding';end if;
  v_denied:=false;
  begin
    perform public.request_self_serve_checkout_v130(
      v_business,'annual',3000,gen_random_uuid()
    );
  exception when insufficient_privilege then v_denied:=true;
  end;
  reset role;
  if not v_denied then raise exception 'V130 outsider requested Checkout';end if;

  perform pg_temp.as_v130_user(null,'service_role');
  v_result:=public.claim_billing_command_v130(
    (v_command->>'command_id')::uuid,v_owner
  );
  reset role;
  if not coalesce((v_result->>'self_service_onboarding')::boolean,false)
     or v_result->>'provider_base_price_id'<>'price_v130_annual_base'
     or v_result->>'provider_capacity_price_id'<>'price_v130_annual_capacity'
     or (v_result->>'extra_capacity_blocks')::integer<>2 then
    raise exception 'V130 did not bind self-service Checkout to server catalogue truth';
  end if;

  perform pg_temp.assert_v130_payment_rejected(v_business,'wrong_price');
  perform pg_temp.assert_v130_payment_rejected(v_business,'wrong_cadence');
  perform pg_temp.assert_v130_payment_rejected(v_business,'wrong_capacity');
  perform pg_temp.assert_v130_payment_rejected(v_business,'nonzero_tax');
  perform pg_temp.assert_v130_payment_rejected(v_business,'wrong_total');
  perform pg_temp.assert_v130_payment_rejected(v_business,'amount_remaining');
  perform pg_temp.assert_v130_payment_rejected(v_business,'wrong_currency');

  insert into public.billing_subscription_terms_v124(
    business_id,provider_subscription_id,cadence,customer_capacity,
    capacity_blocks,provider_base_price_id,provider_capacity_item_id,
    provider_capacity_price_id,
    provider_event_created_at,last_event_id
  ) values(
    v_business,'sub_v130_paid','annual',3000,3,
    'price_v130_annual_base','si_v130_paid',
    'price_v130_annual_capacity',now(),'evt_v130_terms'
  );
  insert into public.billing_provider_invoices(
    business_id,provider_customer_id,provider_subscription_id,
    provider_invoice_id,currency,status,paid_normalized,
    subtotal_ex_tax_cents,tax_cents,total_cents,amount_due_cents,
    amount_paid_cents,amount_remaining_cents,paid_at,livemode,
    provider_event_created_at,provider_event_rank,last_event_id
  ) values(
    v_business,'cus_v130','sub_v130_wrong','in_v130_wrong','SGD','paid',true,
    142800,0,142800,142800,142800,0,v_paid_at-interval '1 minute',false,
    v_paid_at-interval '59 seconds',100,'evt_v130_wrong'
  );
  if app.business_workspace_open_v94(v_business) then
    raise exception 'V130 opened on a paid invoice for the wrong subscription';
  end if;
  insert into public.billing_provider_invoices(
    business_id,provider_customer_id,provider_subscription_id,
    provider_invoice_id,currency,status,paid_normalized,
    subtotal_ex_tax_cents,tax_cents,total_cents,amount_due_cents,
    amount_paid_cents,amount_remaining_cents,paid_at,livemode,
    provider_event_created_at,provider_event_rank,last_event_id
  ) values(
    v_business,'cus_v130','sub_v130_paid','in_v130_paid','SGD','paid',true,
    142800,0,142800,142800,142800,0,v_paid_at,false,
    v_paid_at+interval '1 second',100,'evt_v130_paid'
  );
  if auth.uid() is not null
     or coalesce(current_setting('request.jwt.claims',true)::jsonb->>'role','')<>'service_role' then
    raise exception 'V132 did not restore the provider request claims after draft seeding';
  end if;
  if not app.business_workspace_open_v94(v_business)
     or not exists(select 1 from public.self_serve_business_onboarding_v130 where business_id=v_business and status='active' and activation_invoice_id='in_v130_paid')
     or not exists(select 1 from public.business_sector_assignments where business_id=v_business and bundle_version_id=v_bundle)
     or not exists(
       select 1 from public.loyalty_programs programme
       join public.firm_config_versions version
         on version.id=programme.current_config_version_id
        and version.business_id=programme.business_id
      where programme.business_id=v_business
        and programme.configuration_status='draft' and not programme.active
        and programme.recommendation_source='self_service_onboarding_preset'
        and version.status='draft' and version.created_by=v_owner
     )
     or not exists(select 1 from public.billing_money_back_windows_v124 where business_id=v_business and first_paid_invoice_id='in_v130_paid' and money_back_request_until=v_paid_at+interval '30 days') then
    raise exception 'V130 matching provider-paid evidence did not atomically open the workspace';
  end if;
  if not exists(
    select 1 from public.business_workspace_control_audit_v94
     where business_id=v_business
       and event_type='self_service_payment_confirmed'
       and reason='provider-confirmed self-service subscription payment'
  ) then
    raise exception 'V130 activation audit is missing';
  end if;
  update public.billing_provider_invoices
     set paid_normalized=paid_normalized,paid_at=paid_at
   where provider_invoice_id='in_v130_paid';
  if (select count(*) from public.business_workspace_control_audit_v94
       where business_id=v_business and event_type='self_service_payment_confirmed')<>1 then
    raise exception 'V130 duplicate provider evidence duplicated activation';
  end if;
end
$v130_test$;

rollback;
