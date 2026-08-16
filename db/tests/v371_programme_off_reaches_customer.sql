-- Rollback-only acceptance for v371 — "turned off" must reach the customer.
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f db/tests/v371_programme_off_reaches_customer.sql
-- Any outcome starting with FAIL is a failure.
--
-- Every check below fails on the pre-v371 functions except the isolation ones, which passed
-- already: 05, 06, 09, 10, 11 and 12 are the regressions this migration fixes.
--
-- The fixture is a synthetic two-tenant world built and thrown away inside this transaction, so
-- the suite never depends on the shape of a real tenant. Notes for anyone extending it:
--   * public.customer_links is guarded — set app.customer_link_insert_id to the new row's id.
--   * customer_identities.created_via only allows 'wallet_start' / 'phone_registration'.
--   * the owner write gates need staff.access_state='approved' AND an approved
--     business_workspace_controls_v94 row AND an unpaused business_subscription_lifecycle_v94 row
--     (a trigger seeds the latter two, hence the upserts).
--   * points_ledger is append-guarded: earn points by inserting a real sale and letting the
--     v10 triggers do it.

begin;

-- Shared synthetic two-tenant fixture (rolled back). Creates:
--   business A (owner user, branch, product, loyalty program) + linked customer
--   business B (owner user) + its own client, to prove isolation
create temp table _r(k text, v text) on commit drop;
create temp table _c(
  bizA uuid, bizB uuid, slugA text, slugB text, brA uuid, brB uuid,
  ownerA uuid, ownerB uuid, prodA uuid, svcA uuid,
  userC uuid, identC uuid, cliA uuid, cliB uuid, linkA uuid, lpA uuid, lpB uuid,
  progA uuid, rewardA uuid, tierA uuid, tierB uuid, bringbackA uuid, planA uuid,
  cliPkgA uuid, apptA uuid, promoA uuid
) on commit drop;
-- JSON captures: every customer-facing read is stored here under a key, so the
-- assertions below compare the business's stored config against what the customer RPC answered.
create temp table _j(k text primary key, j jsonb) on commit drop;
grant select,insert,update,delete on _r,_c,_j to authenticated;
insert into _c(slugA,slugB) values
 ('zz-audit-a-'||substr(md5(random()::text),1,8),'zz-audit-b-'||substr(md5(random()::text),1,8));

with i as (insert into public.businesses(name,slug) select 'ZZ Audit A',slugA from _c returning id)
update _c set bizA=(select id from i);
with i as (insert into public.businesses(name,slug) select 'ZZ Audit B',slugB from _c returning id)
update _c set bizB=(select id from i);
with i as (insert into public.branches(business_id,name) select bizA,'Main A' from _c returning id)
update _c set brA=(select id from i);
with i as (insert into public.branches(business_id,name) select bizB,'Main B' from _c returning id)
update _c set brB=(select id from i);

-- owner auth users + staff rows
with i as (insert into auth.users(id,instance_id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at)
  values (gen_random_uuid(),'00000000-0000-0000-0000-000000000000','authenticated','authenticated',
          'zz-owner-a-'||substr(md5(random()::text),1,8)||'@example.test','x',now(),now(),now()) returning id)
update _c set ownerA=(select id from i);
with i as (insert into auth.users(id,instance_id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at)
  values (gen_random_uuid(),'00000000-0000-0000-0000-000000000000','authenticated','authenticated',
          'zz-owner-b-'||substr(md5(random()::text),1,8)||'@example.test','x',now(),now(),now()) returning id)
update _c set ownerB=(select id from i);
insert into public.staff(business_id,user_id,role,active,access_state,full_name) select bizA,ownerA,'owner',true,'approved','ZZ Owner A' from _c;
insert into public.staff(business_id,user_id,role,active,access_state,full_name) select bizB,ownerB,'owner',true,'approved','ZZ Owner B' from _c;
-- workspace must be approved and unpaused for any owner write gate to open
-- (a trigger already seeds both rows when the business is created)
insert into public.business_workspace_controls_v94(business_id,approval_status,decided_by,decided_at,decision_reason)
select bizA,'approved',ownerA,now(),'audit fixture' from _c
on conflict (business_id) do update set approval_status='approved',
  decided_by=excluded.decided_by, decided_at=excluded.decided_at, decision_reason=excluded.decision_reason;
insert into public.business_workspace_controls_v94(business_id,approval_status,decided_by,decided_at,decision_reason)
select bizB,'approved',ownerB,now(),'audit fixture' from _c
on conflict (business_id) do update set approval_status='approved',
  decided_by=excluded.decided_by, decided_at=excluded.decided_at, decision_reason=excluded.decision_reason;
insert into public.business_subscription_lifecycle_v94(business_id,workspace_paused) select bizA,false from _c
on conflict (business_id) do update set workspace_paused=false;
insert into public.business_subscription_lifecycle_v94(business_id,workspace_paused) select bizB,false from _c
on conflict (business_id) do update set workspace_paused=false;

-- catalogue
with i as (insert into public.products(business_id,name,retail_price_cents,active) select bizA,'ZZ Kopi',500,true from _c returning id)
update _c set prodA=(select id from i);
with i as (insert into public.services(business_id,name,price_cents,duration_min,active) select bizA,'ZZ Trim',3000,30,true from _c returning id)
update _c set svcA=(select id from i);

-- customer identity linked to A only
with i as (insert into auth.users(id,instance_id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at)
  values (gen_random_uuid(),'00000000-0000-0000-0000-000000000000','authenticated','authenticated',
          'zz-cust-'||substr(md5(random()::text),1,8)||'@example.test','x',now(),now(),now()) returning id)
update _c set userC=(select id from i);
with i as (insert into public.customer_identities(auth_user_id,status,created_via) select userC,'active','wallet_start' from _c returning id)
update _c set identC=(select id from i);
with i as (insert into public.clients(business_id,full_name,phone,birth_date) select bizA,'ZZ Audit Customer','81990001',(current_date - interval '30 years')::date from _c returning id)
update _c set cliA=(select id from i);
with i as (insert into public.clients(business_id,full_name,phone) select bizB,'ZZ Other Tenant Customer','81990002' from _c returning id)
update _c set cliB=(select id from i);
update _c set linkA=gen_random_uuid();
select set_config('app.customer_link_insert_id',(select linkA::text from _c),true);
insert into public.customer_links(id,business_id,identity_id,auth_user_id,client_id,state,verification_method,verified_at)
select linkA,bizA,identC,userC,cliA,'verified','qr_join',now() from _c;
select set_config('app.customer_link_insert_id','',true);
-- =====================================================================================
-- Business A is brought to the state of a real live tenant: points configured, published and
-- running, a tier the customer already qualifies for, and a gift they can afford.
-- =====================================================================================
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub',(select ownerA from _c),'role','authenticated')::text, true);
select public.business_set_earning_rule_v359((select bizA from _c), 1.0, null, 'none', null);
select public.publish_loyalty_config((select current_config_version_id from public.loyalty_programs where business_id=(select bizA from _c) limit 1));
select public.set_programmes_v314((select bizA from _c),'{"points":true,"tiers":true}'::jsonb,gen_random_uuid());
reset role;
-- publish copies `active` out of the draft, which starts false; a live tenant has it true.
update public.loyalty_programs set active=true where business_id=(select bizA from _c);

set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub',(select ownerA from _c),'role','authenticated')::text, true);
select public.business_create_tier_v331((select bizA from _c),'ZZ Bronze',0,1,'Free coffee');
select public.business_create_reward_v326((select bizA from _c),
  (select id from public.business_programmes where business_id=(select bizA from _c) and kind='points'),
  'ZZ Free Kopi', 5, 0, 'A free kopi', null);
reset role;
update _c set tierA=(select id from public.loyalty_tiers where business_id=(select bizA from _c) and name='ZZ Bronze' limit 1),
              rewardA=(select id from public.loyalty_rewards where business_id=(select bizA from _c) and name='ZZ Free Kopi' limit 1);
-- points are earned the only legitimate way: a real sale, which the v10 triggers turn into ledger rows
insert into public.sales(business_id,client_id,kind,amount_cents,branch_id)
select bizA,cliA,'service',5000,brA from _c;

-- ---------- baseline: everything switched on is visible ----------
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub',(select userC from _c),'role','authenticated')::text, true);
insert into _j(k,j) select 'on_wallet', public.customer_get_actionable_business((select slugA from _c));
insert into _j(k,j) select 'on_tier',   public.customer_get_effective_tier_v143((select bizA from _c));
insert into _j(k,j) select 'on_cat',    public.customer_get_reward_catalog((select slugA from _c));
reset role;

insert into _r select '01 a live points programme is visible to the customer',
  case when (select j->'card'->'loyalty'->>'enabled' from _j where k='on_wallet')='true' then 'PASS'
       else 'FAIL enabled='||coalesce((select j->'card'->'loyalty'->>'enabled' from _j where k='on_wallet'),'<null>') end;
insert into _r select '02 the balance shown is the ledger balance, not a guess',
  case when (select (j->'card'->'loyalty'->>'balance')::numeric from _j where k='on_wallet')
          = (select coalesce(sum(points),0) from public.points_ledger
              where business_id=(select bizA from _c) and client_id=(select cliA from _c))
       then 'PASS' else 'FAIL wallet='||coalesce((select j->'card'->'loyalty'->>'balance' from _j where k='on_wallet'),'<null>')
            ||' ledger='||(select coalesce(sum(points),0)::text from public.points_ledger
                            where business_id=(select bizA from _c) and client_id=(select cliA from _c)) end;
insert into _r select '03 a live tier the customer qualifies for is visible',
  case when (select j->'tier'->>'label' from _j where k='on_tier')='ZZ Bronze' then 'PASS'
       else 'FAIL label='||coalesce((select j->'tier'->>'label' from _j where k='on_tier'),'<null>') end;
insert into _r select '04 a live gift is in the customer catalogue',
  case when (select j::text from _j where k='on_cat') like '%ZZ Free Kopi%' then 'PASS' else 'FAIL gift missing' end;

-- ---------- the owner turns Points & gifts OFF, then back ON ----------
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub',(select ownerA from _c),'role','authenticated')::text, true);
select public.set_programmes_v314((select bizA from _c),'{"points":false}'::jsonb,gen_random_uuid());
select set_config('request.jwt.claims', json_build_object('sub',(select userC from _c),'role','authenticated')::text, true);
insert into _j(k,j) select 'off_wallet', public.customer_get_actionable_business((select slugA from _c));
select set_config('request.jwt.claims', json_build_object('sub',(select ownerA from _c),'role','authenticated')::text, true);
select public.set_programmes_v314((select bizA from _c),'{"points":true}'::jsonb,gen_random_uuid());
select set_config('request.jwt.claims', json_build_object('sub',(select userC from _c),'role','authenticated')::text, true);
insert into _j(k,j) select 'back_on', public.customer_get_actionable_business((select slugA from _c));
reset role;

insert into _r select '05 points switched off stops being shown to the customer',
  case when (select j->'card'->'loyalty'->>'enabled' from _j where k='off_wallet')='false' then 'PASS'
       else 'FAIL the customer still sees enabled='
            ||coalesce((select j->'card'->'loyalty'->>'enabled' from _j where k='off_wallet'),'<null>') end;
insert into _r select '06 a switched-off programme reports no balance either',
  case when (select (j->'card'->'loyalty'->>'balance')::numeric from _j where k='off_wallet')=0 then 'PASS'
       else 'FAIL balance='||coalesce((select j->'card'->'loyalty'->>'balance' from _j where k='off_wallet'),'<null>') end;
insert into _r select '07 switching it back on restores it',
  case when (select j->'card'->'loyalty'->>'enabled' from _j where k='back_on')='true' then 'PASS'
       else 'FAIL enabled='||coalesce((select j->'card'->'loyalty'->>'enabled' from _j where k='back_on'),'<null>') end;

-- ---------- the owner turns Tier membership OFF ----------
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub',(select ownerA from _c),'role','authenticated')::text, true);
select public.business_set_tier_paused_v331((select bizA from _c),(select tierA from _c),true);
select set_config('request.jwt.claims', json_build_object('sub',(select userC from _c),'role','authenticated')::text, true);
insert into _j(k,j) select 'tier_paused', public.customer_get_effective_tier_v143((select bizA from _c));
select set_config('request.jwt.claims', json_build_object('sub',(select ownerA from _c),'role','authenticated')::text, true);
select public.business_set_tier_paused_v331((select bizA from _c),(select tierA from _c),false);
select public.set_programmes_v314((select bizA from _c),'{"tiers":false}'::jsonb,gen_random_uuid());
select set_config('request.jwt.claims', json_build_object('sub',(select userC from _c),'role','authenticated')::text, true);
insert into _j(k,j) select 'off_tier', public.customer_get_effective_tier_v143((select bizA from _c));
reset role;

insert into _r select '08 a per-tier pause still hides just that tier',
  case when (select j->'tier'->>'label' from _j where k='tier_paused') is null then 'PASS'
       else 'FAIL label='||coalesce((select j->'tier'->>'label' from _j where k='tier_paused'),'<null>') end;
insert into _r select '09 tiers switched off empties the customer ladder',
  case when coalesce(jsonb_array_length((select j->'tier'->'tiers' from _j where k='off_tier')),-1)=0
       then 'PASS' else 'FAIL the customer still sees '
            ||coalesce(jsonb_array_length((select j->'tier'->'tiers' from _j where k='off_tier'))::text,'<null>')||' tier(s)' end;
insert into _r select '10 and no current tier label is claimed',
  case when (select j->'tier'->>'label' from _j where k='off_tier') is null then 'PASS'
       else 'FAIL label='||(select j->'tier'->>'label' from _j where k='off_tier') end;

-- ---------- the owner pauses one gift, then unpauses it ----------
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub',(select ownerA from _c),'role','authenticated')::text, true);
select public.business_set_reward_paused_v326((select bizA from _c),(select rewardA from _c),true);
select set_config('request.jwt.claims', json_build_object('sub',(select userC from _c),'role','authenticated')::text, true);
insert into _j(k,j) select 'paused_cat',    public.customer_get_reward_catalog((select slugA from _c));
insert into _j(k,j) select 'paused_wallet', public.customer_get_actionable_business((select slugA from _c));
select set_config('request.jwt.claims', json_build_object('sub',(select ownerA from _c),'role','authenticated')::text, true);
select public.business_set_reward_paused_v326((select bizA from _c),(select rewardA from _c),false);
select set_config('request.jwt.claims', json_build_object('sub',(select userC from _c),'role','authenticated')::text, true);
insert into _j(k,j) select 'unpaused_cat', public.customer_get_reward_catalog((select slugA from _c));
reset role;

insert into _r select '11 a paused gift leaves the customer catalogue',
  case when (select j::text from _j where k='paused_cat') not like '%ZZ Free Kopi%' then 'PASS'
       else 'FAIL the paused gift is still offered' end;
insert into _r select '12 a paused gift is not advertised as the next reward',
  case when coalesce((select j->'card'->'next_eligible_reward'->>'name' from _j where k='paused_wallet'),'') <> 'ZZ Free Kopi'
       then 'PASS' else 'FAIL still advertised: '
            ||(select (j->'card'->'next_eligible_reward')::text from _j where k='paused_wallet') end;
insert into _r select '13 unpausing the gift brings it back',
  case when (select j::text from _j where k='unpaused_cat') like '%ZZ Free Kopi%' then 'PASS'
       else 'FAIL the gift did not come back' end;

-- ---------- tenant isolation ----------
insert into _r select '14 the customer is linked to tenant A only',
  case when (select count(*) from public.customer_links
              where business_id=(select bizB from _c) and auth_user_id=(select userC from _c))=0
       then 'PASS' else 'FAIL the audit customer is linked to the wrong tenant' end;
-- The RPC must refuse outright, not answer with an empty card: business B has no verified link
-- to this customer, so there is nothing for it to say about them.
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub',(select userC from _c),'role','authenticated')::text, true);
do $cross$
begin
  perform public.customer_get_actionable_business((select slugB from _c));
  insert into _r values('15 tenant B refuses a customer it has no link to',
    'FAIL business B answered for a customer it has no verified link to');
exception when others then
  insert into _r values('15 tenant B refuses a customer it has no link to','PASS');
end
$cross$;
reset role;

insert into _r select '16 tenant A''s gift never appears under tenant B',
  case when not exists(select 1 from public.loyalty_rewards
                        where business_id=(select bizB from _c) and name='ZZ Free Kopi')
       then 'PASS' else 'FAIL a tenant A gift is readable as tenant B' end;
insert into _r select '17 tenant A''s tier never appears under tenant B',
  case when not exists(select 1 from public.loyalty_tiers
                        where business_id=(select bizB from _c) and name='ZZ Bronze')
       then 'PASS' else 'FAIL a tenant A tier is readable as tenant B' end;

select k as check_name, v as outcome from _r order by k;

rollback;
