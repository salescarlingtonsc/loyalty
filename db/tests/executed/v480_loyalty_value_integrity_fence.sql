-- Rollback-only P0 acceptance for v480 loyalty serialization, conservation,
-- reversal clawback and owner-only shortfall evidence.
\set ON_ERROR_STOP on
begin;

create temp table p0_proof_results(
  scenario text, phase text, ledger_balance integer, batch_balance integer,
  source_earn integer, source_batch_remaining integer,
  redemption_count integer, benefit_count integer, reversal_count integer
);
create function pg_temp.v480_suppress_batch_drain()
returns trigger language plpgsql as $$
begin
  if current_setting('app.v480_test_suppress_batch_drain',true)='on' then return old; end if;
  return new;
end $$;
create trigger zz_v480_test_suppress_batch_drain
before update on public.points_batches
for each row execute function pg_temp.v480_suppress_batch_drain();

do $proof$
declare
  v_owner uuid := gen_random_uuid();
  v_business uuid := gen_random_uuid();
  v_branch uuid := gen_random_uuid();
  v_client_unspent uuid := gen_random_uuid();
  v_client_spent uuid := gen_random_uuid();
  v_client_correction uuid := gen_random_uuid();
  v_config uuid := gen_random_uuid();
  v_points_programme uuid;
  v_reward uuid := gen_random_uuid();
  v_reward_version uuid := gen_random_uuid();
  v_staff uuid;
  v_sale_unspent uuid;
  v_sale_spent uuid;
  v_sale_correction uuid;
  v_result jsonb;
  v_adjust_key uuid := gen_random_uuid();
  v_refused boolean := false;
begin
  if has_function_privilege('authenticated','public.reverse_sale_v480_base(uuid,uuid,text,text,text,text)','execute')
     or has_function_privilege('authenticated','public.reverse_sale_v40_base(uuid,uuid,text,text,text,text)','execute')
     or has_function_privilege('authenticated','public.reverse_sale_v34_base(uuid,uuid,text,text,text,text)','execute')
     or has_function_privilege('authenticated','public.reverse_sale_v20_base(uuid,uuid,text,text,text,text)','execute') then
    raise exception 'an authenticated reversal-base bypass remains';
  end if;
  if has_function_privilege('anon','public.adjust_points(uuid,uuid,integer,text)','execute')
     or not has_function_privilege('authenticated','public.adjust_points(uuid,uuid,integer,text)','execute') then
    raise exception 'staged stale-client adjustment ACL is wrong';
  end if;
  insert into auth.users(instance_id,id,aud,role,email,encrypted_password,
                         email_confirmed_at,created_at,updated_at)
  values('00000000-0000-0000-0000-000000000000',v_owner,'authenticated','authenticated',
         'p0-refund-'||substr(v_owner::text,1,8)||'@example.test','',now(),now(),now());

  insert into public.businesses(id,name,slug,industry,is_synthetic,enabled_modules)
  values(v_business,'P0 refund proof','p0-refund-'||substr(v_business::text,1,8),'test',true,
         array['dashboard','clients','sales','till','loyalty','retention']);
  insert into public.staff(business_id,user_id,role,full_name,active)
  values(v_business,v_owner,'owner','P0 owner',true) returning id into v_staff;
  insert into public.branches(id,business_id,name,is_default,active)
  values(v_branch,v_business,'P0 main',true,true);
  update public.business_workspace_controls_v94
     set approval_status='approved',version=version+1,decided_by=v_owner,
         decided_at=clock_timestamp(),decision_reason='P0 rollback proof',updated_at=clock_timestamp()
   where business_id=v_business;
  insert into public.business_subscription_lifecycle_v94(business_id,workspace_paused)
  values(v_business,false)
  on conflict(business_id) do update set workspace_paused=false;

  perform set_config('request.jwt.claim.sub',v_owner::text,true);
  perform set_config('request.jwt.claims',json_build_object('sub',v_owner,'role','authenticated')::text,true);

  insert into public.firm_config_versions(id,business_id,version_no,status,source,snapshot_hash,created_by)
  values(v_config,v_business,1,'draft','manual',md5('p0-refund-proof'),v_owner);
  insert into public.loyalty_program_versions(
    config_version_id,business_id,kind,loyalty_model,active,
    earn_points_per_dollar,redeem_points,reward_credit_cents,tier_basis,expiry_mode)
  values(v_config,v_business,'points','points_tiers',true,1,50,0,'points_earned','none');
  update public.firm_config_versions set status='published',published_at=clock_timestamp()
   where id=v_config;
  insert into public.loyalty_programs(
    business_id,kind,active,loyalty_model,configuration_status,current_config_version_id)
  values(v_business,'points',true,'points_tiers','published',v_config);
  perform set_config('app.v79_system_transition','on',true);
  update public.businesses set active_config_version_id=v_config where id=v_business;
  perform set_config('app.v79_system_transition','',true);
  select id into v_points_programme from public.business_programmes
   where business_id=v_business and kind='points';
  update public.business_programmes set active=true where id=v_points_programme;

  insert into public.loyalty_rewards(
    id,business_id,name,internal_name,customer_name,fulfillment_kind,
    estimated_cost_cents,cost_points,credit_cents,active,programme_id,current_config_version_id)
  values(v_reward,v_business,'P0 reward','P0 reward','P0 reward','manual_item',
         500,50,0,true,v_points_programme,v_config);
  insert into public.loyalty_reward_versions(
    id,config_version_id,business_id,reward_id,internal_name,customer_name,
    fulfillment_kind,estimated_cost_cents,cost_points,credit_cents,active,programme_id)
  values(v_reward_version,v_config,v_business,v_reward,'P0 reward','P0 reward',
         'manual_item',500,50,0,true,v_points_programme);

  insert into public.clients(id,business_id,full_name) values
    (v_client_unspent,v_business,'P0 refund unspent'),
    (v_client_spent,v_business,'P0 refund spent'),
    (v_client_correction,v_business,'P0 amount correction');

  v_sale_unspent := (public.record_quick_sale(
    v_business,10000,'cash',v_client_unspent,v_staff,v_branch,
    'P0 refund proof unspent','p0-refund-unspent-sale',true
  )::jsonb #>> '{sale,id}')::uuid;
  insert into p0_proof_results
  select 'unspent','after_earn',coalesce(sum(l.points),0)::integer,
    coalesce((select sum(pb.remaining) from public.points_batches pb where pb.business_id=v_business and pb.client_id=v_client_unspent),0)::integer,
    coalesce(sum(l.points) filter(where l.sale_id=v_sale_unspent and l.entry_type='earn'),0)::integer,
    coalesce((select sum(pb.remaining) from public.points_batches pb where pb.business_id=v_business and pb.client_id=v_client_unspent and pb.sale_id=v_sale_unspent),0)::integer,
    (select count(*) from public.loyalty_redemptions r where r.business_id=v_business and r.client_id=v_client_unspent)::integer,
    (select count(*) from public.loyalty_redemptions r where r.business_id=v_business and r.client_id=v_client_unspent)::integer,
    (select count(*) from public.sales s where s.business_id=v_business and s.reversal_of=v_sale_unspent)::integer
  from public.points_ledger l where l.business_id=v_business and l.client_id=v_client_unspent;

  v_result := public.reverse_sale(v_business,v_sale_unspent,
    'P0 refund proof unspent reversal','p0-refund-unspent-reversal','P0 proof','none')::jsonb;
  if (v_result->>'loyalty_clawed_back')::integer<>100
     or (v_result->>'loyalty_shortfall')::integer<>0 then
    raise exception 'unspent reversal did not claw back the exact source earn: %',v_result;
  end if;
  insert into p0_proof_results
  select 'unspent','after_refund',coalesce(sum(l.points),0)::integer,
    coalesce((select sum(pb.remaining) from public.points_batches pb where pb.business_id=v_business and pb.client_id=v_client_unspent),0)::integer,
    coalesce(sum(l.points) filter(where l.sale_id=v_sale_unspent and l.entry_type='earn'),0)::integer,
    coalesce((select sum(pb.remaining) from public.points_batches pb where pb.business_id=v_business and pb.client_id=v_client_unspent and pb.sale_id=v_sale_unspent),0)::integer,
    (select count(*) from public.loyalty_redemptions r where r.business_id=v_business and r.client_id=v_client_unspent)::integer,
    (select count(*) from public.loyalty_redemptions r where r.business_id=v_business and r.client_id=v_client_unspent)::integer,
    (select count(*) from public.sales s where s.business_id=v_business and s.reversal_of=v_sale_unspent)::integer
  from public.points_ledger l where l.business_id=v_business and l.client_id=v_client_unspent;

  if (select coalesce(sum(points),0) from public.points_ledger
       where business_id=v_business and client_id=v_client_unspent)<>0
     or (select coalesce(sum(remaining),0) from public.points_batches
       where business_id=v_business and client_id=v_client_unspent)<>0 then
    raise exception 'unspent reversal did not conserve ledger/batch zero';
  end if;
  begin
    perform public.redeem_reward_at_context(
      v_business,v_client_unspent,v_reward,'p0-refund-after-refund-redeem',v_branch,null,null);
    raise exception 'refunded source points still funded a reward';
  exception when check_violation then null;
  end;

  v_sale_spent := (public.record_quick_sale(
    v_business,10000,'cash',v_client_spent,v_staff,v_branch,
    'P0 refund proof spent','p0-refund-spent-sale',true
  )::jsonb #>> '{sale,id}')::uuid;
  v_result := public.redeem_reward_at_context(
    v_business,v_client_spent,v_reward,'p0-refund-before-refund-redeem',v_branch,null,null
  )::jsonb;
  insert into p0_proof_results
  select 'spent','after_spend_before_refund',coalesce(sum(l.points),0)::integer,
    coalesce((select sum(pb.remaining) from public.points_batches pb where pb.business_id=v_business and pb.client_id=v_client_spent),0)::integer,
    coalesce(sum(l.points) filter(where l.sale_id=v_sale_spent and l.entry_type='earn'),0)::integer,
    coalesce((select sum(pb.remaining) from public.points_batches pb where pb.business_id=v_business and pb.client_id=v_client_spent and pb.sale_id=v_sale_spent),0)::integer,
    (select count(*) from public.loyalty_redemptions r where r.business_id=v_business and r.client_id=v_client_spent)::integer,
    (select count(*) from public.loyalty_redemptions r where r.business_id=v_business and r.client_id=v_client_spent)::integer,
    (select count(*) from public.sales s where s.business_id=v_business and s.reversal_of=v_sale_spent)::integer
  from public.points_ledger l where l.business_id=v_business and l.client_id=v_client_spent;

  begin
    perform public.reverse_sale(v_business,v_sale_spent,
      'P0 refund proof spent reversal','p0-refund-spent-reversal','P0 proof','none');
  exception when sqlstate '55000' then
    if position('loyalty_already_spent' in sqlerrm)=0 then raise; end if;
    v_refused:=true;
  end;
  if not v_refused or exists(select 1 from public.sales where business_id=v_business and reversal_of=v_sale_spent) then
    raise exception 'ordinary spent-points refund did not fail closed and roll back';
  end if;
  v_result := public.reverse_sale_accept_loyalty_shortfall_v480(v_business,v_sale_spent,
    'P0 refund proof spent reversal','p0-refund-spent-reversal','P0 proof','none')::jsonb;
  if (v_result->>'loyalty_shortfall')::integer<>50
     or not (v_result->>'loyalty_shortfall_accepted')::boolean then
    raise exception 'owner override did not record the exact shortfall: %',v_result;
  end if;
  if (select count(*) from public.sale_loyalty_reversal_evidence_v480
       where business_id=v_business and original_sale_id=v_sale_spent
         and accepted_shortfall=50 and override_accepted)<>1 then
    raise exception 'owner shortfall evidence is absent or not unique';
  end if;

  -- Idempotent adjustment: exact replay returns the same balance and changed
  -- payload is rejected without a second ledger effect.
  v_result:=public.adjust_points_v480(v_business,v_client_unspent,10,'v480 proof adjustment',v_adjust_key);
  if (v_result->>'balance')::integer<>10 then raise exception 'adjustment returned wrong balance'; end if;
  v_result:=public.adjust_points_v480(v_business,v_client_unspent,10,'v480 proof adjustment',v_adjust_key);
  if not (v_result->>'replayed')::boolean then raise exception 'adjustment replay was not identified'; end if;
  begin
    perform public.adjust_points_v480(v_business,v_client_unspent,11,'v480 proof adjustment',v_adjust_key);
    raise exception 'changed adjustment payload reused an idempotency key';
  exception when unique_violation then null;
  end;
  if (select count(*) from app.loyalty_adjustment_operations_v480
       where business_id=v_business and idempotency_key=v_adjust_key and status='completed')<>1 then
    raise exception 'adjustment operation evidence is not exactly once';
  end if;
  perform set_config('app.v480_test_suppress_batch_drain','on',true);
  begin
    perform public.adjust_points_v480(v_business,v_client_unspent,-5,
      'v480 disappearing batch proof',gen_random_uuid());
    raise exception 'a suppressed batch drain still committed its ledger debit';
  exception when sqlstate 'XX001' then
    if position('batch delta does not reconcile' in sqlerrm)=0 then raise; end if;
  end;
  perform set_config('app.v480_test_suppress_batch_drain','',true);
  if (select coalesce(sum(points),0) from public.points_ledger
       where business_id=v_business and client_id=v_client_unspent)<>10
     or (select coalesce(sum(remaining),0) from public.points_batches
       where business_id=v_business and client_id=v_client_unspent)<>10 then
    raise exception 'failed drain left a debit or batch mutation behind';
  end if;

  -- The v84 amount-correction route owns its own exact clawback and calls the
  -- renamed reversal base, so v480 must not compensate the source points twice.
  v_sale_correction := (public.record_quick_sale(
    v_business,10000,'cash',v_client_correction,v_staff,v_branch,
    'P0 correction proof','p0-v480-correction-sale',true
  )::jsonb #>> '{sale,id}')::uuid;
  v_result:=public.correct_quick_sale_amount_v84(
    v_business,v_sale_correction,12000,'p0-v480-correction-operation','v480 proof'
  );
  if (v_result->>'points_removed')::integer<>100
     or (v_result->>'points_earned')::integer<>120 then
    raise exception 'amount correction did not compensate loyalty exactly once: %',v_result;
  end if;
  if (select coalesce(sum(points),0) from public.points_ledger
       where business_id=v_business and client_id=v_client_correction)<>120
     or (select coalesce(sum(remaining),0) from public.points_batches
       where business_id=v_business and client_id=v_client_correction)<>120 then
    raise exception 'amount correction left loyalty ledger/batches divergent';
  end if;

  -- A transaction that already entered a shared writer cannot attempt an
  -- in-place exclusive conversion upgrade (the classic self-deadlock shape).
  begin
    perform public.business_switch_to_stamps_v384(v_business,false,null,gen_random_uuid());
    raise exception 'shared-to-exclusive conversion upgrade unexpectedly succeeded';
  exception when deadlock_detected then
    if position('unsafe loyalty fence upgrade' in sqlerrm)=0 then raise; end if;
  end;
  if (select conversions_enabled from app.loyalty_integrity_control_v480 where singleton) then
    raise exception 'conversion unexpectedly enabled before proof-gate approval';
  end if;

  insert into p0_proof_results
  select 'spent','after_owner_override',coalesce(sum(l.points),0)::integer,
    coalesce((select sum(pb.remaining) from public.points_batches pb where pb.business_id=v_business and pb.client_id=v_client_spent),0)::integer,
    coalesce(sum(l.points) filter(where l.sale_id=v_sale_spent and l.entry_type='earn'),0)::integer,
    coalesce((select sum(pb.remaining) from public.points_batches pb where pb.business_id=v_business and pb.client_id=v_client_spent and pb.sale_id=v_sale_spent),0)::integer,
    (select count(*) from public.loyalty_redemptions r where r.business_id=v_business and r.client_id=v_client_spent)::integer,
    (select count(*) from public.loyalty_redemptions r where r.business_id=v_business and r.client_id=v_client_spent)::integer,
    (select count(*) from public.sales s where s.business_id=v_business and s.reversal_of=v_sale_spent)::integer
  from public.points_ledger l where l.business_id=v_business and l.client_id=v_client_spent;
end
$proof$;

table p0_proof_results;
rollback;
