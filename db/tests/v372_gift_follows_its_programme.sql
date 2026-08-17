-- Rollback-only acceptance for v372 — a gift is only offered while its own programme is running.
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f db/tests/v372_gift_follows_its_programme.sql
-- Any outcome starting with FAIL is a failure.
--
-- Checks 02, 03, 04 and 07 fail on the pre-v372 functions. The fixture reproduces Cubbly's live
-- shape exactly: points running, stamps off, and a gift priced in STAMPS that the wallet was
-- reporting `available_now` against a POINTS balance.
--
-- Fixture traps are documented in db/tests/v371_programme_off_reaches_customer.sql.

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
-- Business A: points published and RUNNING, stamps switched off — Cubbly's exact live shape.
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub',(select ownerA from _c),'role','authenticated')::text, true);
select public.business_set_earning_rule_v359((select bizA from _c), 1.0, null, 'none', null);
select public.publish_loyalty_config((select current_config_version_id from public.loyalty_programs where business_id=(select bizA from _c) limit 1));
select public.set_programmes_v314((select bizA from _c),'{"points":true}'::jsonb,gen_random_uuid());
reset role;
update public.loyalty_programs set active=true where business_id=(select bizA from _c);

set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub',(select ownerA from _c),'role','authenticated')::text, true);
-- one gift on the RUNNING points programme, one on the SWITCHED-OFF stamps programme
select public.business_create_reward_v326((select bizA from _c),
  (select id from public.business_programmes where business_id=(select bizA from _c) and kind='points'),
  'ZZ Points Kopi', 500, 0, 'A free kopi', null);
select public.business_create_reward_v326((select bizA from _c),
  (select id from public.business_programmes where business_id=(select bizA from _c) and kind='stamps'),
  'ZZ Stamp Oil', 2, 0, 'Free massage oil', null);
reset role;
-- the customer earns a POINTS balance, which is the unit the stamp gift must never be judged against
insert into public.sales(business_id,client_id,kind,amount_cents,branch_id)
select bizA,cliA,'service',5000,brA from _c;

set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub',(select userC from _c),'role','authenticated')::text, true);
insert into _j(k,j) select 'cat',    public.customer_get_reward_catalog((select slugA from _c));
insert into _j(k,j) select 'wallet', public.customer_get_actionable_business((select slugA from _c));
reset role;

insert into _r select '01 a gift on the running programme is still offered',
  case when (select j::text from _j where k='cat') like '%ZZ Points Kopi%' then 'PASS'
       else 'FAIL the live programme''s own gift disappeared' end;
insert into _r select '02 a gift on a switched-off programme leaves the catalogue',
  case when (select j::text from _j where k='cat') not like '%ZZ Stamp Oil%' then 'PASS'
       else 'FAIL a stamps gift is offered while stamps is switched off' end;
insert into _r select '03 the catalogue holds exactly the running programme''s gift',
  case when (select jsonb_array_length(coalesce(j->'rewards','[]'::jsonb)) from _j where k='cat')=1
       then 'PASS' else 'FAIL count='||coalesce((select jsonb_array_length(coalesce(j->'rewards','[]'::jsonb))::text from _j where k='cat'),'<null>') end;
insert into _r select '04 the wallet never advertises the switched-off programme''s gift',
  case when coalesce((select j->'card'->'next_eligible_reward'->>'name' from _j where k='wallet'),'') <> 'ZZ Stamp Oil'
       then 'PASS' else 'FAIL the wallet offers '||(select (j->'card'->'next_eligible_reward')::text from _j where k='wallet') end;
/* The running programme's gift is deliberately priced out of reach (500 points against a balance
   of 50), so the switched-off programme's 2-unit gift is the one the wallet would otherwise pick
   as "closest" — which is precisely how Cubbly's 2-STAMP gift came to be reported ready against a
   POINTS balance. */
insert into _r select '05 the advertised reward is the live programme''s, and is not falsely ready',
  case when (select j->'card'->'next_eligible_reward'->>'name' from _j where k='wallet')='ZZ Points Kopi'
        and (select j->'card'->'next_eligible_reward'->>'available_now' from _j where k='wallet')='false'
        and (select j->'card'->'loyalty'->>'unit' from _j where k='wallet')='points'
       then 'PASS' else 'FAIL advertised='||coalesce((select (j->'card'->'next_eligible_reward')::text from _j where k='wallet'),'<null>')
            ||' unit='||coalesce((select j->'card'->'loyalty'->>'unit' from _j where k='wallet'),'<null>') end;

-- turning the stamps programme ON (and points off, they are exclusive) swaps which gift is offered
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub',(select ownerA from _c),'role','authenticated')::text, true);
select public.set_programmes_v314((select bizA from _c),'{"points":false,"stamps":true}'::jsonb,gen_random_uuid());
select set_config('request.jwt.claims', json_build_object('sub',(select userC from _c),'role','authenticated')::text, true);
insert into _j(k,j) select 'cat2', public.customer_get_reward_catalog((select slugA from _c));
reset role;

insert into _r select '06 switching the other programme on brings its gift back',
  case when (select j::text from _j where k='cat2') like '%ZZ Stamp Oil%' then 'PASS'
       else 'FAIL the stamps gift did not return when stamps was switched on' end;
insert into _r select '07 and retires the gift of the programme just switched off',
  case when (select j::text from _j where k='cat2') not like '%ZZ Points Kopi%' then 'PASS'
       else 'FAIL the points gift is still offered with points switched off' end;

select k as check_name, v as outcome from _r order by k;

rollback;
