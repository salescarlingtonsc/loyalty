-- Rollback-only acceptance for v378 — the promotion finalisation circuit breaker.
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f db/tests/v378_promotion_finalize_breaker.sql
-- Any outcome starting with FAIL is a failure.
--
-- Checks 01-06 and 10 hold the breaker; 07-09 hold that a real save is completely unaffected.
-- Fixture traps are documented in db/tests/v371_programme_off_reaches_customer.sql. Two more here:
-- promotions are rows in business_customer_content_v95 (there is no public.promotions), and the
-- current content/copy versions must be read as postgres — `authenticated` cannot read those
-- tables, and sending anything but the true versions is itself a version conflict, which would
-- test the breaker again rather than the success path.

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
  keyA uuid, keyB uuid, contentV integer, copyV integer,
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
-- Promotions are rows in business_customer_content_v95; create one the way the editor does, so the
-- success check below exercises the real pipeline rather than a hand-made row.
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub',(select ownerA from _c),'role','authenticated')::text, true);
update _c set promoA=gen_random_uuid();
select public.business_create_promotion_draft_v155(
  (select bizA from _c),(select promoA from _c),gen_random_uuid(),'all',null,null,
  'ZZ Audit Offer',null,'A ten percent audit offer for the rehearsal.',null,
  now()-interval '1 day',now()+interval '30 days',
  100,'counter','Show at counter','Ten percent off any visit.',null);
reset role;

-- 1. A definitive refusal returns structured JSON instead of aborting, and is recorded.
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub',(select ownerA from _c),'role','authenticated')::text, true);
update _c set keyA=gen_random_uuid();
insert into _j(k,j) select 'r1', public.business_finalize_promotion_v155(
  (select bizA from _c),(select promoA from _c),'all',null,null,
  'ZZ Audit Offer',null,'A ten percent audit offer for the rehearsal.',null,
  now()-interval '1 day',now()+interval '30 days',
  100,'counter','Show at counter','Ten percent off any visit.',null,true,null,null,null,null,null,
  999::bigint,999::bigint,999::bigint,(select keyA from _c));
reset role;

insert into _r select '01 a definitive refusal returns instead of raising',
  case when (select j->>'code' from _j where k='r1')='promotion_finalize_rejected'
        and (select j->>'blocked' from _j where k='r1')='true'
        and (select j->>'ok' from _j where k='r1')='false'
       then 'PASS' else 'FAIL '||coalesce((select j::text from _j where k='r1'),'<null>') end;
insert into _r select '02 the reason is the real one the pipeline raised',
  case when (select j->>'reason' from _j where k='r1') like 'promotion%conflict'
       then 'PASS' else 'FAIL reason='||coalesce((select j->>'reason' from _j where k='r1'),'<null>') end;
insert into _r select '03 the refusal is RECORDED — the abort used to erase the evidence',
  case when exists(select 1 from public.promotion_finalize_refusals_v378
                    where business_id=(select bizA from _c) and attempt_key=(select keyA from _c)
                      and failures=1 and actor=(select ownerA from _c))
       then 'PASS' else 'FAIL no refusal row' end;

-- 2. Three sends, then the pipeline is not executed at all.
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub',(select ownerA from _c),'role','authenticated')::text, true);
insert into _j(k,j) select 'r2', public.business_finalize_promotion_v155(
  (select bizA from _c),(select promoA from _c),'all',null,null,'ZZ Audit Offer',null,'A ten percent audit offer for the rehearsal.',null,
  now()-interval '1 day',now()+interval '30 days',100,'counter','Show at counter','Ten percent off any visit.',null,true,null,null,null,null,null,
  999::bigint,999::bigint,999::bigint,(select keyA from _c));
insert into _j(k,j) select 'r3', public.business_finalize_promotion_v155(
  (select bizA from _c),(select promoA from _c),'all',null,null,'ZZ Audit Offer',null,'A ten percent audit offer for the rehearsal.',null,
  now()-interval '1 day',now()+interval '30 days',100,'counter','Show at counter','Ten percent off any visit.',null,true,null,null,null,null,null,
  999::bigint,999::bigint,999::bigint,(select keyA from _c));
insert into _j(k,j) select 'r4', public.business_finalize_promotion_v155(
  (select bizA from _c),(select promoA from _c),'all',null,null,'ZZ Audit Offer',null,'A ten percent audit offer for the rehearsal.',null,
  now()-interval '1 day',now()+interval '30 days',100,'counter','Show at counter','Ten percent off any visit.',null,true,null,null,null,null,null,
  999::bigint,999::bigint,999::bigint,(select keyA from _c));
reset role;

insert into _r select '04 the count reaches the ceiling and stops there',
  case when (select failures from public.promotion_finalize_refusals_v378
              where business_id=(select bizA from _c) and attempt_key=(select keyA from _c))=3
       then 'PASS' else 'FAIL failures='||coalesce((select failures::text from public.promotion_finalize_refusals_v378
              where business_id=(select bizA from _c) and attempt_key=(select keyA from _c)),'<none>') end;
insert into _r select '05 the fourth send is answered from the record, not the pipeline',
  case when (select j->>'code' from _j where k='r4')='promotion_finalize_rejected'
        and (select j->>'failures' from _j where k='r4')='3'
       then 'PASS' else 'FAIL '||coalesce((select j::text from _j where k='r4'),'<null>') end;

-- 3. An UNEXPECTED error must still raise — the breaker must never mask a system fault.
do $unexpected$
begin
  perform public.business_finalize_promotion_v155(
    (select bizA from _c),(select promoA from _c),'all',null,null,'ZZ Audit Offer',null,'desc',null,
    now()-interval '1 day',now()+interval '30 days',100,'none',null,null,null,true,null,null,null,null,null,
    999::bigint,999::bigint,999::bigint,null);
  insert into _r values('06 an unexpected failure still raises','FAIL it was swallowed');
exception when others then
  insert into _r values('06 an unexpected failure still raises','PASS');
end
$unexpected$;

-- 4. Success is untouched, and it releases the key.
/* Read the current versions as postgres: `authenticated` cannot read these tables directly, and
   sending anything but the true versions would be a version conflict — testing the breaker again
   instead of the success path. */
update _c set
  contentV=(select content.version from public.business_customer_content_v95 content
             where content.id=(select promoA from _c) and content.content_type='offer'),
  copyV=(select copy.version from public.business_localized_copy_v95 copy
          where copy.business_id=(select bizA from _c) and copy.entity_type='offer'
            and copy.entity_id=(select promoA from _c) and copy.locale='en');
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub',(select ownerA from _c),'role','authenticated')::text, true);
update _c set keyB=gen_random_uuid();
insert into _j(k,j) select 'ok', public.business_finalize_promotion_v155(
  (select bizA from _c),(select promoA from _c),'all',null,null,
  'ZZ Audit Offer Renamed',null,'A ten percent audit offer for the rehearsal.',null,
  now()-interval '1 day',now()+interval '30 days',
  100,'counter','Show at counter','Ten percent off any visit.',null,false,null,null,null,null,null,
  /* The real current versions: the draft creation above bumped them, and sending anything else is
     itself a version conflict — which would test the breaker again rather than the success path. */
  (select contentV from _c)::bigint,(select copyV from _c)::bigint,0::bigint,(select keyB from _c));
reset role;

insert into _r select '07 a real save still succeeds and is not shaped as a refusal',
  case when (select j->>'blocked' from _j where k='ok') is null
        and (select j->>'code' from _j where k='ok') is distinct from 'promotion_finalize_rejected'
       then 'PASS' else 'FAIL '||coalesce(substr((select j::text from _j where k='ok'),1,200),'<null>') end;
insert into _r select '08 the branch_scope contract on the success path is preserved',
  case when (select j ? 'branch_scope' from _j where k='ok') then 'PASS' else 'FAIL no branch_scope' end;
insert into _r select '09 a success leaves no refusal behind for its key',
  case when not exists(select 1 from public.promotion_finalize_refusals_v378
                        where business_id=(select bizA from _c) and attempt_key=(select keyB from _c))
       then 'PASS' else 'FAIL a successful key kept a refusal row' end;
insert into _r select '10 the refusal table is closed to browser roles',
  case when not exists(select 1 from pg_policies where tablename='promotion_finalize_refusals_v378')
        and (select relrowsecurity from pg_class where oid='public.promotion_finalize_refusals_v378'::regclass)
       then 'PASS' else 'FAIL the table is reachable from the API' end;

select k as check_name, v as outcome from _r order by k;

rollback;
