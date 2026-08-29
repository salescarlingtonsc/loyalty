-- Rollback-only acceptance: the join sheet's referral code pays BOTH sides — immediately when
-- the programme sets no spending requirement, and on first qualifying spend otherwise
-- (nestly_v612). Run: supabase db query --linked -f db/tests/v612_referral_immediate_when_no_floor.sql
-- Any value starting FAIL is a failure. Nothing is committed.
--
-- Owner ruling 2026-08-30: "allow user to key in referral code so both parties get the rewards.
-- either immediately if no requirements or receive voucher once requirements (spending) is
-- achieved." The floor>0 world must stay EXACTLY the sale-settled v425 engine; only the
-- floor=0 world settles at application.
begin;
create temp table _r(id text, value text) on commit drop;
grant select, insert on all tables in schema pg_temp to authenticated, anon;

-- ── fixture: real tenant (referral programme ON, pays points, friend side on) ──
create temp table _f as
select b.id as biz, b.slug,
  (select br.id from public.branches br where br.business_id=b.id and br.active order by br.is_default desc limit 1) as branch,
  (select s.user_id from public.staff s where s.business_id=b.id and s.role='owner' and s.user_id is not null limit 1) as staff_uid
from public.businesses b where b.slug='ahxiang';
grant select, insert on all tables in schema pg_temp to authenticated, anon;

-- one referrer + three synthetic friends (each scenario needs its own referred customer,
-- because referrals is unique per referred client)
create temp table _ids as
with amy as (
  insert into public.clients(business_id,full_name,phone)
  select biz,'V612 Referrer Amy','80000612' from _f returning id)
select (select id from amy) as a_client,
  gen_random_uuid() as u1, gen_random_uuid() as u2, gen_random_uuid() as u3;
grant select, insert on all tables in schema pg_temp to authenticated, anon;
update public.clients set referral_code='V612AMY' where id=(select a_client from _ids);

do $$
declare f record; i record; u uuid; c uuid; l uuid; n int:=0;
begin
  select * into f from _f; select * into i from _ids;
  foreach u in array array[i.u1,i.u2,i.u3] loop
    n:=n+1;
    insert into auth.users(instance_id,id,aud,role,email,encrypted_password,
                           email_confirmed_at,created_at,updated_at)
    values ('00000000-0000-0000-0000-000000000000',u,'authenticated','authenticated',
            'v612-friend-'||n||'-'||substr(u::text,1,8)||'@example.test','',now(),now(),now());
    insert into public.customer_identities(auth_user_id,status,created_via)
    values (u,'active','wallet_start');
    insert into public.clients(business_id,full_name,phone)
    values (f.biz,'V612 Friend '||n,'8000062'||n) returning id into c;
    l:=gen_random_uuid();
    perform set_config('app.customer_link_insert_id',l::text,true);
    insert into public.customer_links(id,business_id,identity_id,auth_user_id,client_id,state,verification_method,verified_at)
    values (l,f.biz,(select id from public.customer_identities ci where ci.auth_user_id=u limit 1),
            u,c,'verified','qr_join',now());
    perform set_config('app.customer_link_insert_id','',true);
    execute format('create temp table _friend%s as select %L::uuid as client',n,c);
  end loop;
end $$;
grant select, insert on all tables in schema pg_temp to authenticated, anon;

insert into _r select '00 fixture',
  case when (select biz from _f) is null then 'FAIL: tenant missing'
       when not exists(select 1 from public.referral_programs rp,_f f where rp.business_id=f.biz and rp.enabled)
         then 'FAIL: referral programme is off'
       else 'OK' end;

-- ── 01 floor > 0: application records, settles NOTHING, and says so ──────────
update public.referral_programs set min_spend_cents=20000, reward_kind='points'
 where business_id=(select biz from _f);
set local role authenticated;
select set_config('request.jwt.claims',
  json_build_object('sub',(select u1 from _ids),'role','authenticated')::text,true);
create temp table _a1 as
select public.customer_apply_referral_code_v612((select slug from _f),'V612AMY',gen_random_uuid()) as j;
grant select, insert on all tables in schema pg_temp to authenticated, anon;
reset role;
insert into _r select '01 with a floor the reply says on_spend and names the floor',
  case when (j->>'applied')::boolean is not true then 'FAIL: '||j::text
       when j->>'settled' is distinct from 'on_spend' then 'FAIL: settled='||coalesce(j->>'settled','∅')
       when (j->>'min_spend_cents')::int<>20000 then 'FAIL: floor not named'
       else 'OK' end from _a1;
insert into _r select '01a the referral is pending — the v425 sale engine still owns it',
  case when count(*)=1 then 'OK' else 'FAIL' end
from public.referrals r where r.referred_client_id=(select client from _friend1) and r.status='pending';
insert into _r select '01b and no ledger row moved',
  case when exists(select 1 from public.points_ledger l,_ids i
                    where l.client_id in (i.a_client,(select client from _friend1)) and l.reference like 'referral%')
       then 'FAIL: paid before the requirement' else 'OK' end;

-- ── 02 floor = 0: BOTH sides paid immediately at application ─────────────────
update public.referral_programs set min_spend_cents=0
 where business_id=(select biz from _f);
set local role authenticated;
select set_config('request.jwt.claims',
  json_build_object('sub',(select u2 from _ids),'role','authenticated')::text,true);
create temp table _a2 as
select public.customer_apply_referral_code_v612((select slug from _f),'V612AMY',gen_random_uuid()) as j;
grant select, insert on all tables in schema pg_temp to authenticated, anon;
reset role;
insert into _r select '02 no requirement → settled immediately',
  case when (j->>'applied')::boolean is not true then 'FAIL: '||j::text
       when j->>'settled' is distinct from 'immediate' then 'FAIL: settled='||coalesce(j->>'settled','∅')||' '||j::text
       else 'OK' end from _a2;
insert into _r select '02a the referral is rewarded with no sale attached',
  case when count(*)=1 then 'OK' else 'FAIL' end
from public.referrals r where r.referred_client_id=(select client from _friend2)
  and r.status='rewarded' and r.qualified_sale_id is null;
insert into _r select '02b the REFERRER was paid at once',
  coalesce((select 'OK '||l.points||' pts ('||l.reference||')' from public.points_ledger l,_ids i
            where l.client_id=i.a_client and l.entry_type='earn'
              and l.reference='referral applied: no spend requirement' limit 1),
           'FAIL: the referrer got nothing');
insert into _r select '02c the FRIEND was paid at once too',
  coalesce((select 'OK '||l.points||' pts' from public.points_ledger l
            where l.client_id=(select client from _friend2) and l.entry_type='earn'
              and l.reference='referral applied: introduced by a friend' limit 1),
           'FAIL: the friend got nothing');
insert into _r select '02d ledger and batches agree, on the declared pot',
  case when (select count(*) from public.points_ledger l where l.referral_id=(select r.id from public.referrals r where r.referred_client_id=(select client from _friend2)))
          <> (select count(*) from public.points_batches b where b.referral_id=(select r.id from public.referrals r where r.referred_client_id=(select client from _friend2)))
       then 'FAIL: ledger/batch parity broken'
       when exists(select 1 from public.points_ledger l where l.referral_id=(select r.id from public.referrals r where r.referred_client_id=(select client from _friend2)) and l.programme_id is null)
       then 'FAIL: a payout landed outside any pot'
       else 'OK' end;

-- 02e a later sale must NOT pay the same referral again
select set_config('request.jwt.claims',
  json_build_object('sub',(select staff_uid from _f),'role','authenticated')::text,true);
insert into public.sales(business_id,client_id,kind,amount_cents,branch_id)
select f.biz,(select client from _friend2),'service',12345,f.branch from _f f;
reset role;
insert into _r select '02e a later sale does not double-pay a settled referral',
  case when (select count(*) from public.points_ledger l
              where l.referral_id=(select r.id from public.referrals r where r.referred_client_id=(select client from _friend2)))>2
       then 'FAIL: the sale trigger paid again' else 'OK' end;

-- ── 03 floor = 0 but the declared pot is off → fail CLOSED, stays pending ────
update public.business_programmes set active=false
 where business_id=(select biz from _f) and kind='points';
set local role authenticated;
select set_config('request.jwt.claims',
  json_build_object('sub',(select u3 from _ids),'role','authenticated')::text,true);
create temp table _a3 as
select public.customer_apply_referral_code_v612((select slug from _f),'V612AMY',gen_random_uuid()) as j;
grant select, insert on all tables in schema pg_temp to authenticated, anon;
reset role;
insert into _r select '03 pot off → applied but blocked, nothing paid',
  case when (j->>'applied')::boolean is not true then 'FAIL: '||j::text
       when j->>'settled' is distinct from 'blocked' then 'FAIL: settled='||coalesce(j->>'settled','∅')
       else 'OK' end from _a3;
insert into _r select '03a the referral stays pending with the reason recorded',
  case when count(*)=1 then 'OK' else 'FAIL' end
from public.referrals r where r.referred_client_id=(select client from _friend3)
  and r.status='pending' and r.blocked_reason like 'reward_kind_points_requires_active%';
insert into _r select '03b and no ledger row moved for it',
  case when exists(select 1 from public.points_ledger l
                    where l.referral_id=(select r.id from public.referrals r where r.referred_client_id=(select client from _friend3)))
       then 'FAIL' else 'OK' end;

-- ── 04 guards unchanged: self-referral, unknown code, replay ─────────────────
set local role authenticated;
select set_config('request.jwt.claims',
  json_build_object('sub',(select u2 from _ids),'role','authenticated')::text,true);
insert into _r select '04 replay of an applied code answers already_applied',
  case when (public.customer_apply_referral_code_v612((select slug from _f),'V612AMY',gen_random_uuid())->>'reason')='already_applied'
       then 'OK' else 'FAIL' end;
insert into _r select '04a an unknown code is refused',
  case when (public.customer_apply_referral_code_v612((select slug from _f),'V612NOPE',gen_random_uuid())->>'reason')='unknown_code'
       then 'OK' else 'FAIL' end;
reset role;

-- ── 05 access ────────────────────────────────────────────────────────────────
insert into _r select '05 anon cannot execute the new writer',
  case when exists(select 1 from pg_proc p
                    where p.proname='customer_apply_referral_code_v612'
                      and array_to_string(p.proacl,',') like '%anon=%')
       then 'FAIL: anon has a grant' else 'OK' end;
insert into _r select '05a v571 remains deployed for older clients',
  case when to_regprocedure('public.customer_apply_referral_code_v571(text,text,uuid)') is null
       then 'FAIL' else 'OK' end;

select id, value from _r order by id;
rollback;
