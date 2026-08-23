-- Rollback-only executed P0 proof: a qualifying sale owns every referral benefit
-- it caused (both sides, points/stamps/vouchers), and reversal cannot leave that
-- value spendable without either failing closed or recording an owner override.
\set ON_ERROR_STOP on
begin;

insert into public.module_registry(module_key,label,requires_modules,sort_order) values
  ('dashboard','Dashboard','{}',10),('clients','Customers','{}',30),
  ('sales','Sales','{}',50),('services','Services','{}',60),
  ('loyalty','Loyalty','{clients,sales}',120),('referrals','Referrals','{clients,sales}',140)
on conflict (module_key) do nothing;

insert into public.product_adoption_event_taxonomy_v100
  (event_name,source_authority,actor_scope,business_scope_required,economic_event,description) values
  ('sale.recorded','server','system',true,true,'Canonical non-reversal sale was inserted.'),
  ('sale.reversed','server','system',true,true,'Canonical reversal sale was inserted.'),
  ('loyalty.redemption_completed','server','system',true,true,'Canonical loyalty redemption was inserted.')
on conflict (event_name) do nothing;

do $proof$
declare
  v_owner uuid:=gen_random_uuid(); v_slug text:=substr(md5(random()::text),1,8);
  v_pbiz uuid; v_sbiz uuid; v_vbiz uuid; v_pbranch uuid; v_sbranch uuid; v_vbranch uuid;
  v_pstaff uuid; v_sstaff uuid; v_vstaff uuid; v_ppot uuid; v_spot uuid;
  v_referrer uuid; v_friend uuid; v_ref uuid; v_sale uuid; v_sale2 uuid; v_grant uuid;
  v_credit_id uuid;
  v_cfg uuid; v_reward uuid:=gen_random_uuid(); v_reward_version uuid:=gen_random_uuid();
  v_out jsonb; v_refused boolean; v_key text;
begin
  insert into auth.users(id,instance_id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at)
  values(v_owner,'00000000-0000-0000-0000-000000000000','authenticated','authenticated',
         'zz-v480-ref-'||v_slug||'@example.test','x',now(),now(),now());
  perform set_config('request.jwt.claim.sub',v_owner::text,true);
  perform set_config('request.jwt.claims',json_build_object('sub',v_owner,'role','authenticated')::text,true);

  insert into public.businesses(name,slug,enabled_modules) values
    ('ZZ V480 referral points','zz-v480-rp-'||v_slug,'{dashboard,clients,sales,services,loyalty,referrals}') returning id into v_pbiz;
  insert into public.businesses(name,slug,enabled_modules) values
    ('ZZ V480 referral stamps','zz-v480-rs-'||v_slug,'{dashboard,clients,sales,services,loyalty,referrals}') returning id into v_sbiz;
  insert into public.businesses(name,slug,enabled_modules) values
    ('ZZ V480 referral voucher','zz-v480-rv-'||v_slug,'{dashboard,clients,sales,services,loyalty,referrals}') returning id into v_vbiz;
  insert into public.branches(business_id,name) values(v_pbiz,'Main') returning id into v_pbranch;
  insert into public.branches(business_id,name) values(v_sbiz,'Main') returning id into v_sbranch;
  insert into public.branches(business_id,name) values(v_vbiz,'Main') returning id into v_vbranch;
  insert into public.staff(business_id,user_id,role,active,access_state,full_name) values
    (v_pbiz,v_owner,'owner',true,'approved','V480 owner') returning id into v_pstaff;
  insert into public.staff(business_id,user_id,role,active,access_state,full_name) values
    (v_sbiz,v_owner,'owner',true,'approved','V480 owner') returning id into v_sstaff;
  insert into public.staff(business_id,user_id,role,active,access_state,full_name) values
    (v_vbiz,v_owner,'owner',true,'approved','V480 owner') returning id into v_vstaff;
  insert into public.business_workspace_controls_v94(business_id,approval_status,decided_by,decided_at,decision_reason)
  values(v_pbiz,'approved',v_owner,now(),'v480 referral proof'),
        (v_sbiz,'approved',v_owner,now(),'v480 referral proof'),
        (v_vbiz,'approved',v_owner,now(),'v480 referral proof')
  on conflict(business_id) do update set approval_status='approved',decided_by=excluded.decided_by,
    decided_at=excluded.decided_at,decision_reason=excluded.decision_reason;
  insert into public.business_subscription_lifecycle_v94(business_id,workspace_paused)
  values(v_pbiz,false),(v_sbiz,false),(v_vbiz,false)
  on conflict(business_id) do update set workspace_paused=false;

  -- Configure every business before the first SHARED value writer; this proves
  -- the supported EXCLUSIVE→SHARED order and never attempts an unsafe upgrade.
  perform public.business_set_earning_rule_v359(v_pbiz,1.0,null,'none',null);
  perform public.publish_loyalty_config((select current_config_version_id from public.loyalty_programs where business_id=v_pbiz limit 1));
  perform public.set_programmes_v314(v_pbiz,'{"points":true,"referral":true}'::jsonb,gen_random_uuid());
  perform public.save_referral_program_v421(v_pbiz,true,'points',100,null,0,true,100,null);

  perform public.business_set_earning_rule_v359(v_sbiz,1.0,null,'none',null);
  perform public.publish_loyalty_config((select current_config_version_id from public.loyalty_programs where business_id=v_sbiz limit 1));
  perform public.set_programmes_v314(v_sbiz,'{"stamps":true,"referral":true}'::jsonb,gen_random_uuid());
  update public.loyalty_programs set active=true,stamp_per_cents=1000 where business_id=v_sbiz;
  perform public.save_referral_program_v421(v_sbiz,true,'stamps',7,null,0,true,7,null);

  perform public.business_set_earning_rule_v359(v_vbiz,1.0,null,'none',null);
  perform public.publish_loyalty_config((select current_config_version_id from public.loyalty_programs where business_id=v_vbiz limit 1));
  perform public.set_programmes_v314(v_vbiz,'{"points":true,"referral":true}'::jsonb,gen_random_uuid());
  perform public.save_referral_program_v421(v_vbiz,true,'voucher',null,'Free Coffee',0,true,null,'Free Coffee');

  select id into v_ppot from public.business_programmes where business_id=v_pbiz and kind='points';
  select id into v_spot from public.business_programmes where business_id=v_sbiz and kind='stamps';
  select current_config_version_id into v_cfg from public.loyalty_programs where business_id=v_pbiz limit 1;
  insert into public.loyalty_rewards(id,business_id,name,internal_name,customer_name,fulfillment_kind,
    estimated_cost_cents,cost_points,credit_cents,active,programme_id,current_config_version_id)
  values(v_reward,v_pbiz,'Referral spend proof','Referral spend proof','Referral spend proof','manual_item',
         500,50,0,true,v_ppot,v_cfg);
  insert into public.loyalty_reward_versions(id,config_version_id,business_id,reward_id,internal_name,
    customer_name,fulfillment_kind,estimated_cost_cents,cost_points,credit_cents,active,programme_id)
  values(v_reward_version,v_cfg,v_pbiz,v_reward,'Referral spend proof','Referral spend proof',
         'manual_item',500,50,0,true,v_ppot);

  -- POINTS, spent: 100 to each referral side plus the friend's ordinary earn.
  insert into public.clients(business_id,full_name) values(v_pbiz,'P referrer') returning id into v_referrer;
  insert into public.clients(business_id,full_name) values(v_pbiz,'P friend') returning id into v_friend;
  insert into public.referrals(business_id,referrer_client_id,referred_client_id,status)
  values(v_pbiz,v_referrer,v_friend,'pending') returning id into v_ref;
  insert into public.sales(business_id,client_id,kind,amount_cents,branch_id,staff_id)
  values(v_pbiz,v_friend,'service',10000,v_pbranch,v_pstaff) returning id into v_sale;
  if (select count(*) from app.referral_value_provenance_v480 where referral_id=v_ref
       and benefit_kind='points' and ledger_id is not null and batch_id is not null)<>2 then
    raise exception 'two-sided points provenance was not captured';
  end if;
  perform public.redeem_reward_at_context(v_pbiz,v_referrer,v_reward,'v480-referral-spend-proof',v_pbranch,null,null);
  v_refused:=false;
  begin
    perform public.reverse_sale(v_pbiz,v_sale,'spent referral reversal','v480-referral-spent','proof','none');
  exception when sqlstate '55000' then v_refused:=position('loyalty_already_spent' in sqlerrm)>0; end;
  if not v_refused then raise exception 'ordinary reversal accepted spent referral points'; end if;
  v_out:=public.reverse_sale_accept_loyalty_shortfall_v480(
    v_pbiz,v_sale,'spent referral reversal','v480-referral-spent-owner','proof','none')::jsonb;
  if (v_out->>'referral_loyalty_shortfall')::integer<>50
     or (select count(*) from public.loyalty_redemptions where business_id=v_pbiz and client_id=v_referrer)<>1 then
    raise exception 'owner referral override lost the shortfall or issued reward: %',v_out;
  end if;
  if exists(select 1 from public.points_batches where business_id=v_pbiz and sale_id=v_sale and remaining<>0) then
    raise exception 'points referral reversal left source batches spendable';
  end if;
  if not exists(select 1 from public.referrals where id=v_ref and status='pending'
    and qualified_at is null and qualified_sale_id is null and reward_points=0 and reward_cents=0) then
    raise exception 'points referral was not reset after compensated reversal';
  end if;
  if not (public.reverse_sale_accept_loyalty_shortfall_v480(
      v_pbiz,v_sale,'spent referral reversal','v480-referral-spent-owner','proof','none')::jsonb->>'replayed')::boolean then
    raise exception 'points referral reversal replay was not idempotent';
  end if;
  insert into public.sales(business_id,client_id,kind,amount_cents,branch_id,staff_id)
  values(v_pbiz,v_friend,'service',10000,v_pbranch,v_pstaff) returning id into v_sale2;
  if not exists(select 1 from public.referrals where id=v_ref and status='rewarded'
       and qualified_sale_id=v_sale2 and reward_points=100)
     or (select count(*) from app.referral_value_provenance_v480
          where referral_id=v_ref and qualifying_sale_id=v_sale2 and benefit_kind='points')<>2
     or (select count(distinct beneficiary) from app.referral_value_provenance_v480
          where referral_id=v_ref and qualifying_sale_id=v_sale2)<>2 then
    raise exception 'points referral did not requalify exactly once per beneficiary';
  end if;

  -- LEGACY CREDIT, unspent: pre-v322 rows are compensated and reset inside
  -- reverse_sale_v20_base. v480 must accept that exact already-reset state,
  -- preserve the one credit clawback, and replay without duplicating it.
  insert into public.clients(business_id,full_name) values(v_pbiz,'C referrer') returning id into v_referrer;
  insert into public.clients(business_id,full_name) values(v_pbiz,'C friend') returning id into v_friend;
  insert into public.sales(business_id,client_id,kind,amount_cents,branch_id,staff_id)
  values(v_pbiz,v_friend,'service',10000,v_pbranch,v_pstaff) returning id into v_sale;
  insert into public.referrals(business_id,referrer_client_id,referred_client_id,status,
    qualified_at,qualified_sale_id,reward_cents,reward_points)
  values(v_pbiz,v_referrer,v_friend,'rewarded',now(),v_sale,500,0) returning id into v_ref;
  v_credit_id:=gen_random_uuid();
  perform set_config('app.credit_ledger_insert_id',v_credit_id::text,true);
  perform set_config('app.credit_ledger_write_scope','sale_trigger',true);
  insert into public.credit_ledger(id,business_id,client_id,entry_type,amount_cents,reference,sale_id,actor)
  values(v_credit_id,v_pbiz,v_referrer,'referral_reward',500,'v480 historical credit fixture',v_sale,v_owner);
  perform set_config('app.credit_ledger_insert_id','',true);
  perform set_config('app.credit_ledger_write_scope','',true);
  v_key:='v480-legacy-credit-reverse';
  v_out:=public.reverse_sale(v_pbiz,v_sale,'legacy credit referral reversal',v_key,'proof','none')::jsonb;
  if not exists(select 1 from public.referrals where id=v_ref and status='pending'
       and qualified_at is null and qualified_sale_id is null and reward_cents=0 and reward_points=0)
     or (select count(*) from public.credit_ledger where business_id=v_pbiz
          and client_id=v_referrer and entry_type='manual_adjust' and amount_cents=-500
          and sale_id=(v_out->>'reversal_sale_id')::uuid)<>1 then
    raise exception 'legacy credit referral reversal did not compensate and reset exactly once: %',v_out;
  end if;
  if not (public.reverse_sale(v_pbiz,v_sale,'legacy credit referral reversal',v_key,'proof','none')::jsonb->>'replayed')::boolean
     or (select count(*) from public.credit_ledger where business_id=v_pbiz
          and client_id=v_referrer and entry_type='manual_adjust' and amount_cents=-500)<>1 then
    raise exception 'legacy credit referral reversal replay duplicated compensation';
  end if;

  -- LEGACY CREDIT, missing immutable payout child: a mutable referral row is
  -- not authority to manufacture a negative customer balance. The sale and
  -- referral remain untouched until an explicit reconciliation supplies proof.
  insert into public.clients(business_id,full_name) values(v_pbiz,'C2 referrer') returning id into v_referrer;
  insert into public.clients(business_id,full_name) values(v_pbiz,'C2 friend') returning id into v_friend;
  insert into public.sales(business_id,client_id,kind,amount_cents,branch_id,staff_id)
  values(v_pbiz,v_friend,'service',10000,v_pbranch,v_pstaff) returning id into v_sale;
  insert into public.referrals(business_id,referrer_client_id,referred_client_id,status,
    qualified_at,qualified_sale_id,reward_cents,reward_points)
  values(v_pbiz,v_referrer,v_friend,'rewarded',now(),v_sale,700,0) returning id into v_ref;
  begin
    perform public.reverse_sale(v_pbiz,v_sale,'missing credit proof reversal',
      'v481-missing-credit-proof','proof','none');
    raise exception 'missing historical credit provenance did not fail closed';
  exception when sqlstate '55000' then
    if position('historical referral credit provenance requires reconciliation' in sqlerrm)=0 then
      raise;
    end if;
  end;
  if exists(select 1 from public.sales where reversal_of=v_sale)
     or not exists(select 1 from public.referrals where id=v_ref and status='rewarded'
       and qualified_sale_id=v_sale and reward_cents=700)
     or exists(select 1 from public.credit_ledger where business_id=v_pbiz
       and client_id=v_referrer and sale_id=v_sale and amount_cents<0) then
    raise exception 'missing-credit fail-closed probe changed accounting state';
  end if;

  -- STAMPS, unspent: ordinary reversal claws both sides and the sale earn.
  insert into public.clients(business_id,full_name) values(v_sbiz,'S referrer') returning id into v_referrer;
  insert into public.clients(business_id,full_name) values(v_sbiz,'S friend') returning id into v_friend;
  insert into public.referrals(business_id,referrer_client_id,referred_client_id,status)
  values(v_sbiz,v_referrer,v_friend,'pending') returning id into v_ref;
  insert into public.sales(business_id,client_id,kind,amount_cents,branch_id,staff_id)
  values(v_sbiz,v_friend,'service',10000,v_sbranch,v_sstaff) returning id into v_sale;
  v_key:='v480-stamp-referral-reverse';
  v_out:=public.reverse_sale(v_sbiz,v_sale,'stamp referral reversal',v_key,'proof','none')::jsonb;
  if (v_out->>'referral_loyalty_clawed_back')::integer<>14
     or exists(select 1 from public.points_batches where business_id=v_sbiz and sale_id=v_sale and remaining<>0) then
    raise exception 'stamp referral reversal did not reclaim both sides: %',v_out;
  end if;
  if not (public.reverse_sale(v_sbiz,v_sale,'stamp referral reversal',v_key,'proof','none')::jsonb->>'replayed')::boolean then
    raise exception 'referral reversal exact replay was not idempotent';
  end if;
  begin
    perform public.reverse_sale(v_sbiz,v_sale,'changed request',v_key,'proof','none');
    raise exception 'changed reversal payload reused an idempotency key';
  exception when unique_violation then null; end;
  if not exists(select 1 from public.referrals where id=v_ref and status='pending'
    and qualified_at is null and qualified_sale_id is null and reward_points=0 and reward_cents=0) then
    raise exception 'stamp referral was not reset after compensated reversal';
  end if;
  insert into public.sales(business_id,client_id,kind,amount_cents,branch_id,staff_id)
  values(v_sbiz,v_friend,'service',10000,v_sbranch,v_sstaff) returning id into v_sale2;
  if not exists(select 1 from public.referrals where id=v_ref and status='rewarded'
       and qualified_sale_id=v_sale2 and reward_points=7)
     or (select count(*) from app.referral_value_provenance_v480
          where referral_id=v_ref and qualifying_sale_id=v_sale2 and benefit_kind='stamps')<>2
     or (select count(distinct beneficiary) from app.referral_value_provenance_v480
          where referral_id=v_ref and qualifying_sale_id=v_sale2)<>2 then
    raise exception 'stamp referral did not requalify exactly once per beneficiary';
  end if;

  -- VOUCHER, unspent: both grants become reversed and disappear from entitlements.
  insert into public.clients(business_id,full_name) values(v_vbiz,'V referrer') returning id into v_referrer;
  insert into public.clients(business_id,full_name) values(v_vbiz,'V friend') returning id into v_friend;
  insert into public.referrals(business_id,referrer_client_id,referred_client_id,status)
  values(v_vbiz,v_referrer,v_friend,'pending') returning id into v_ref;
  insert into public.sales(business_id,client_id,kind,amount_cents,branch_id,staff_id)
  values(v_vbiz,v_friend,'service',10000,v_vbranch,v_vstaff) returning id into v_sale;
  v_out:=public.reverse_sale(v_vbiz,v_sale,'voucher reversal','v480-voucher-unspent','proof','none')::jsonb;
  if (v_out->>'referral_grants_reversed')::integer<>2
     or (select count(*) from public.referral_grants_v420 where referral_id=v_ref and status='reversed')<>2 then
    raise exception 'unspent referral vouchers survived reversal: %',v_out;
  end if;
  if not exists(select 1 from public.referrals where id=v_ref and status='pending'
    and qualified_at is null and qualified_sale_id is null and reward_points=0 and reward_cents=0) then
    raise exception 'voucher referral was not reset after compensated reversal';
  end if;
  insert into public.sales(business_id,client_id,kind,amount_cents,branch_id,staff_id)
  values(v_vbiz,v_friend,'service',10000,v_vbranch,v_vstaff) returning id into v_sale2;
  if not exists(select 1 from public.referrals where id=v_ref and status='rewarded'
       and qualified_sale_id=v_sale2)
     or (select count(*) from app.referral_value_provenance_v480
          where referral_id=v_ref and qualifying_sale_id=v_sale2 and benefit_kind='voucher')<>2
     or (select count(distinct beneficiary) from app.referral_value_provenance_v480
          where referral_id=v_ref and qualifying_sale_id=v_sale2)<>2
     or (select count(*) from public.referral_grants_v420 where referral_id=v_ref and status='granted')<>2 then
    raise exception 'voucher referral did not requalify exactly once per beneficiary';
  end if;

  -- VOUCHER, redeemed: ordinary reversal fails; owner records one retained
  -- benefit, reverses the other, and never invents a replacement grant.
  insert into public.clients(business_id,full_name) values(v_vbiz,'V2 referrer') returning id into v_referrer;
  insert into public.clients(business_id,full_name) values(v_vbiz,'V2 friend') returning id into v_friend;
  insert into public.referrals(business_id,referrer_client_id,referred_client_id,status)
  values(v_vbiz,v_referrer,v_friend,'pending') returning id into v_ref;
  insert into public.sales(business_id,client_id,kind,amount_cents,branch_id,staff_id)
  values(v_vbiz,v_friend,'service',10000,v_vbranch,v_vstaff) returning id into v_sale;
  select id into v_grant from public.referral_grants_v420
   where referral_id=v_ref and beneficiary='referrer';
  perform public.staff_redeem_referral_v420(v_vbiz,v_referrer,v_vbranch,v_grant);
  v_refused:=false;
  begin
    perform public.reverse_sale(v_vbiz,v_sale,'redeemed voucher reversal','v480-voucher-spent','proof','none');
  exception when sqlstate '55000' then v_refused:=position('loyalty_already_spent' in sqlerrm)>0; end;
  if not v_refused then raise exception 'ordinary reversal accepted a redeemed referral voucher'; end if;
  v_out:=public.reverse_sale_accept_loyalty_shortfall_v480(
    v_vbiz,v_sale,'redeemed voucher reversal','v480-voucher-spent-owner','proof','none')::jsonb;
  if (v_out->>'referral_grants_shortfall')::integer<>1
     or (v_out->>'referral_grants_reversed')::integer<>1
     or (select count(*) from public.referral_grants_v420 where referral_id=v_ref)<>2 then
    raise exception 'voucher owner override evidence is not exact: %',v_out;
  end if;
end
$proof$;

select 'v480 referral reversal: PASS' as result;
rollback;
