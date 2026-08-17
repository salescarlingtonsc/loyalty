-- Rollback-only acceptance for v376 — the customer is never offered store credit either.
--   supabase db query --linked -f db/tests/v376_no_classic_redemption_offer.sql
-- Any row whose result starts with FAIL is a failure. Nothing is committed.
--
-- v375 retired the classic model in the business-side reader and made redeem_points refuse, but
-- customer_get_business_actions_v89 still built a "Redeem N points" action for a classic tenant.
-- Nine production programmes matched that branch and one had customer redemption enabled, so a
-- customer could still have prepared a QR for a redemption the counter would now refuse. The
-- fixture is that exact tenant shape: classic, 150 points, SGD 1.50 of credit, redemption on.
begin;

create temp table _r(k text, v text) on commit drop;
create temp table _c(biz uuid, br uuid, owner uuid, slug text, draft uuid, prog uuid, cli uuid, rw uuid, userC uuid, identC uuid, linkC uuid) on commit drop;
grant select,insert,update,delete on _r,_c to authenticated;
insert into _c(slug,prog) values ('zz-v376-'||substr(md5(random()::text),1,8), gen_random_uuid());

with i as (insert into public.businesses(name,slug,enabled_modules)
  select 'ZZ V376',slug,array['loyalty'] from _c returning id)
update _c set biz=(select id from i);
with i as (insert into public.branches(business_id,name) select biz,'Main' from _c returning id)
update _c set br=(select id from i);
with i as (insert into auth.users(id,instance_id,aud,role,email,encrypted_password,
    email_confirmed_at,created_at,updated_at)
  values (gen_random_uuid(),'00000000-0000-0000-0000-000000000000','authenticated','authenticated',
    'zz-v376-'||substr(md5(random()::text),1,8)||'@example.test','x',now(),now(),now()) returning id)
update _c set owner=(select id from i);
insert into public.staff(business_id,user_id,role,active,access_state,full_name)
  select biz,owner,'owner',true,'approved','ZZ V376 Owner' from _c;
-- the owner write gate needs an approved, unpaused workspace (a trigger seeds both rows)
insert into public.business_workspace_controls_v94(business_id,approval_status,decided_by,decided_at,decision_reason)
select biz,'approved',owner,now(),'v376 fixture' from _c
on conflict (business_id) do update set approval_status='approved',
  decided_by=excluded.decided_by, decided_at=excluded.decided_at, decision_reason=excluded.decision_reason;
insert into public.business_subscription_lifecycle_v94(business_id,workspace_paused)
select biz,false from _c on conflict (business_id) do update set workspace_paused=false;

-- A minimum published loyalty configuration for the draft to be based on.
insert into public.firm_config_versions(id,business_id,version_no,status,source,snapshot_hash,created_by)
select cfg,biz,1,'draft','manual',md5('v376-base'),owner from (select *, gen_random_uuid() as cfg from _c) x;
update _c set draft=(select id from public.firm_config_versions where business_id=(select biz from _c));
select set_config('request.jwt.claims',
  json_build_object('sub',(select owner from _c),'role','authenticated')::text,true);
insert into public.loyalty_program_versions(config_version_id,business_id,kind,loyalty_model,active,
  earn_points_per_dollar,redeem_points,reward_credit_cents,tier_basis,expiry_mode)
select draft,biz,'points','classic',true,1,150,150,'points_earned','none' from _c;
select set_config('request.jwt.claims','{}',true);
update public.firm_config_versions set status='published',published_at=now()
 where id=(select draft from _c);
-- a trigger already created this row on business insert, so the fixture UPDATES it into the
-- owner's exact live shape: classic, 150 points, SGD 1.50 of credit.
insert into public.loyalty_programs(business_id,kind,active,loyalty_model,configuration_status,current_config_version_id)
select biz,'points',true,'classic','published',draft from _c
on conflict (business_id) do update set kind='points',active=true,loyalty_model='classic',
  configuration_status='published',current_config_version_id=excluded.current_config_version_id;
update public.loyalty_programs set redeem_points=150,reward_credit_cents=150,earn_points_per_dollar=1
 where business_id=(select biz from _c);
select set_config('app.v79_system_transition','on',true);
update public.businesses set active_config_version_id=(select draft from _c) where id=(select biz from _c);
select set_config('app.v79_system_transition','off',true);



-- A linked customer identity — customer_get_business_actions_v89 answers as the CUSTOMER, so the
-- fixture has to be one (v31_current_identity refuses otherwise), and redemption must be enabled
-- or the action would report 'disabled' for a reason that has nothing to do with this change.
with i as (insert into public.clients(business_id,full_name,phone)
  select biz,'ZZ V376 Customer','8'||substr((random()*90000000+10000000)::bigint::text,1,7) from _c returning id)
update _c set cli=(select id from i);
with i as (insert into auth.users(id,instance_id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at)
  values (gen_random_uuid(),'00000000-0000-0000-0000-000000000000','authenticated','authenticated',
          'zz-v376-cust-'||substr(md5(random()::text),1,8)||'@example.test','x',now(),now(),now()) returning id)
update _c set userC=(select id from i);
with i as (insert into public.customer_identities(auth_user_id,status,created_via)
  select userC,'active','wallet_start' from _c returning id)
update _c set identC=(select id from i);
update _c set linkC=gen_random_uuid();
select set_config('app.customer_link_insert_id',(select linkC::text from _c),true);
insert into public.customer_links(id,business_id,identity_id,auth_user_id,client_id,state,verification_method,verified_at)
select linkC,biz,identC,userC,cli,'verified','qr_join',now() from _c;
select set_config('app.customer_link_insert_id','',true);
insert into public.business_customer_capabilities_v89(business_id,redemption_enabled,booking_enabled)
select biz,true,false from _c
on conflict (business_id) do update set redemption_enabled=true;

create or replace function pg_temp.actions_v376() returns jsonb language sql security definer as $$
  select coalesce(public.customer_get_business_actions_v89((select biz from _c))->'redemption','{}'::jsonb)
$$;
grant execute on function pg_temp.actions_v376() to authenticated;

select set_config('request.jwt.claims',
  json_build_object('sub',(select userC from _c),'role','authenticated')::text,true);
set local role authenticated;

-- 01 — the defect, on whatever definition is live right now.
insert into _r select '01 pre-fix offers a credit redemption',
  case when pg_temp.actions_v376()->'classic' is not null and pg_temp.actions_v376()->'classic' <> 'null'::jsonb
    then 'PASS (a classic tenant''s customer was offered '||coalesce(pg_temp.actions_v376()#>>'{classic,name}','a redemption')||')'
    else 'INFO already withdrawn' end;

reset role;
CREATE OR REPLACE FUNCTION public.customer_get_business_actions_v89(p_business uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'app', 'pg_temp'
AS $function$
declare
  v_identity uuid;v_client uuid;v_result jsonb;
  v_balance integer;v_batch_balance integer;
  v_program public.loyalty_programs%rowtype;
  v_stamps_programme uuid;v_stamp_filled integer;v_stamp_cycle integer;
begin
  v_identity:=app.v31_current_identity();
  select link.client_id into v_client from public.customer_links link
  where link.identity_id=v_identity and link.auth_user_id=auth.uid()
    and link.business_id=p_business and link.state='verified';
  if not found then raise exception 'verified customer link required' using errcode='42501';end if;
  select coalesce(sum(points),0)::integer into v_balance from public.points_ledger
    where business_id=p_business and client_id=v_client;
  select coalesce(sum(remaining),0)::integer into v_batch_balance
    from public.points_batches
    where business_id=p_business and client_id=v_client and remaining>0;
  select spine.id into v_stamps_programme from public.business_programmes spine
    where spine.business_id=p_business and spine.kind='stamps';
  select coalesce(sp.filled,0),coalesce(sp.cycle_index,0)
    into v_stamp_filled,v_stamp_cycle
    from app.stamp_progress_v323(p_business,v_client) sp;
  select * into v_program from public.loyalty_programs program
    where program.business_id=p_business and program.active
    order by program.id limit 1;
  select jsonb_build_object(
    'business',jsonb_build_object('id',business.id,'slug',business.slug,
      'name',business.name,'industry',business.industry,'currency',business.currency),
    'booking',jsonb_build_object('enabled',
      coalesce(capability.booking_enabled,false)
      and app.v89_business_module_enabled(p_business,'bookings') and exists(
        select 1 from public.services service where service.business_id=p_business
          and service.active and service.show_on_booking_page),
      'public_slug',case when coalesce(capability.booking_enabled,false)
        and app.v89_business_module_enabled(p_business,'bookings') and exists(
        select 1 from public.services service where service.business_id=p_business
          and service.active and service.show_on_booking_page)
        then business.slug else null end),
    'redemption',jsonb_build_object(
      'enabled',coalesce(capability.redemption_enabled,false)
        and app.v89_business_module_enabled(p_business,'loyalty')
        and v_program.id is not null,
      -- v376: the points-for-store-credit action is never offered. v375 retired the model and made
      -- app.redeem_points_v40_internal refuse, so leaving this in place would have shown a customer
      -- a redemption their own counter could no longer honour.
      'classic',null::jsonb),
    'appointment_changes',jsonb_build_object(
      'enabled',coalesce(capability.appointment_changes_enabled,false)
        and app.v89_business_module_enabled(p_business,'appointments')),
    'rewards',coalesce((
      select jsonb_agg(jsonb_build_object(
        'id',reward.id,'name',coalesce(reward.customer_name,reward.name),
        'redemption_kind','catalog_reward',
        'cost_points',reward_version.cost_points,
        'availability',case
          when not coalesce(capability.redemption_enabled,false)
            or not app.v89_business_module_enabled(p_business,'loyalty')
            then 'disabled'
          when reward_version.claim_available_from is not null
            and reward_version.claim_available_from>now() then 'not_started'
          when reward_version.claim_available_until is not null
            and reward_version.claim_available_until<=now() then 'ended'
          when reward_version.usage_limit is not null and (
            select count(*) from public.loyalty_redemptions redemption
            where redemption.business_id=p_business
              and redemption.client_id=v_client
              and redemption.reward_id=reward.id
          )>=reward_version.usage_limit then 'limit_reached'
          when v_stamps_programme is not null and reward.programme_id=v_stamps_programme
            and exists(select 1 from public.stamp_milestone_claims claim
                        where claim.business_id=p_business and claim.client_id=v_client
                          and claim.programme_id=v_stamps_programme
                          and claim.cycle_index=coalesce(v_stamp_cycle,0)
                          and claim.reward_id=reward.id)
            then 'limit_reached'
          when (case when v_stamps_programme is not null and reward.programme_id=v_stamps_programme
                     then coalesce(v_stamp_filled,0)
                     else least(v_balance,v_batch_balance) end)<reward_version.cost_points
            then 'insufficient_balance'
          else 'available_at_counter' end
      ) order by reward.sort,reward.id)
      from public.loyalty_rewards reward
      join public.loyalty_reward_versions reward_version
        on reward_version.reward_id=reward.id
       and reward_version.business_id=reward.business_id
      where reward.business_id=p_business and reward.active and not reward.paused
        and exists(select 1 from public.business_programmes spine
                    where spine.id=reward.programme_id and spine.active)
        and reward_version.config_version_id=business.active_config_version_id
        and reward_version.active
        -- Customer QR redemption carries no visit context in v89. Restricted
        -- rewards remain visible through the ordinary wallet catalog, but are
        -- truthfully excluded from this actionable scan list.
        and not exists(select 1 from public.loyalty_reward_branches restriction
          where restriction.reward_version_id=reward_version.id)
        and not exists(select 1 from public.loyalty_reward_services restriction
          where restriction.reward_version_id=reward_version.id)
        and not exists(select 1 from public.loyalty_reward_products restriction
          where restriction.reward_version_id=reward_version.id)
    ),'[]'::jsonb)
  ) into v_result
  from public.businesses business
  left join public.business_customer_capabilities_v89 capability
    on capability.business_id=business.id
  where business.id=p_business;
  return v_result;
end
$function$;

select set_config('request.jwt.claims',
  json_build_object('sub',(select userC from _c),'role','authenticated')::text,true);
set local role authenticated;

-- 02 — no customer is offered points-for-credit any more.
insert into _r select '02 the credit redemption is withdrawn',
  case when coalesce(pg_temp.actions_v376()->'classic','null'::jsonb)='null'::jsonb
  then 'PASS' else 'FAIL still offered: '||pg_temp.actions_v376()::text end;

-- 03 — and the rest of the payload is untouched, so nothing else was collateral.
insert into _r select '03 the redemption capability itself still reports',
  case when pg_temp.actions_v376() ? 'enabled'
  then 'PASS' else 'FAIL the redemption block lost its shape: '||pg_temp.actions_v376()::text end;

reset role;
select k as check, v as result from _r order by k;

rollback;
