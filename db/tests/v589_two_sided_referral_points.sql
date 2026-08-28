-- Rollback-only acceptance: a customer refers a friend and BOTH sides are paid (nestly_v421/v589).
-- Run: supabase db query --linked -f db/tests/v589_two_sided_referral_points.sql
-- Any value starting FAIL is a failure. Nothing is committed.
--
-- Run against a live tenant whose referral programme pays points, so the payout programme, the
-- minimum spend and the pot scoping are the tenant's real ones rather than a fixture's. The
-- under-threshold visit is asserted as well as the qualifying one, because "the referral did not
-- pay" and "the referral must not pay yet" look identical from the outside.
begin;
create temp table _r(id text, value text) on commit drop;
grant select, insert on all tables in schema pg_temp to authenticated, anon;

-- ── fixture: two customers of a real tenant whose referral programme is ON ──
create temp table _f as
select b.id as biz, b.slug,
  (select br.id from public.branches br where br.business_id=b.id and br.active order by br.is_default desc limit 1) as branch,
  (select s.user_id from public.staff s where s.business_id=b.id and s.role='owner' and s.user_id is not null limit 1) as staff_uid,
  (select u.id from auth.users u where u.email='qa-frenly-test@example.invalid') as a_uid,
  (select u.id from auth.users u where u.email='qa-golive@example.invalid') as b_uid
from public.businesses b where b.slug='ahxiang';
grant select, insert on all tables in schema pg_temp to authenticated, anon;

create temp table _ids as
with a as (
  insert into public.clients(business_id,full_name,phone)
  select biz,'V589 Referrer Amy','80000589' from _f returning id),
bb as (
  insert into public.clients(business_id,full_name,phone)
  select biz,'V589 Friend Ben','80000590' from _f returning id)
select (select id from a) as a_client, (select id from bb) as b_client;
grant select, insert on all tables in schema pg_temp to authenticated, anon;

-- give the referrer a code we control, and link both customers to a signed-in wallet
update public.clients set referral_code='V589AMY' where id=(select a_client from _ids);

insert into public.customer_identities(auth_user_id,status,created_via)
select f.a_uid,'active','wallet_start' from _f f
where not exists(select 1 from public.customer_identities ci where ci.auth_user_id=f.a_uid);
insert into public.customer_identities(auth_user_id,status,created_via)
select f.b_uid,'active','wallet_start' from _f f
where not exists(select 1 from public.customer_identities ci where ci.auth_user_id=f.b_uid);

/* v31 keeps customer_links write-once behind a verified claim route; the suite announces each
   row id the same way that route does, so the fixture is built through the guard, not around it. */
do $$
declare f record; i record; v_id uuid;
begin
  select * into f from _f; select * into i from _ids;
  foreach v_id in array array[gen_random_uuid(),gen_random_uuid()] loop null; end loop;
  v_id:=gen_random_uuid();
  perform set_config('app.customer_link_insert_id',v_id::text,true);
  insert into public.customer_links(id,business_id,identity_id,auth_user_id,client_id,state,verification_method,verified_at)
  values(v_id,f.biz,(select id from public.customer_identities where auth_user_id=f.a_uid limit 1),
         f.a_uid,i.a_client,'verified','qr_join',now());
  v_id:=gen_random_uuid();
  perform set_config('app.customer_link_insert_id',v_id::text,true);
  insert into public.customer_links(id,business_id,identity_id,auth_user_id,client_id,state,verification_method,verified_at)
  values(v_id,f.biz,(select id from public.customer_identities where auth_user_id=f.b_uid limit 1),
         f.b_uid,i.b_client,'verified','qr_join',now());
  perform set_config('app.customer_link_insert_id','',true);
end $$;

insert into _r select '00 fixture',
  case when (select branch from _f) is null then 'FAIL: no active branch'
       when (select staff_uid from _f) is null then 'FAIL: no owner'
       when not exists(select 1 from public.referral_programs rp,_f f where rp.business_id=f.biz and rp.enabled)
         then 'FAIL: referral programme is off'
       when not exists(select 1 from public.business_programmes sp,_f f
                        where sp.business_id=f.biz and sp.kind='referral' and sp.active)
         then 'FAIL: the referral spine is off (v589 should have aligned it)'
       else 'OK both doors agree the programme is on' end;

-- ── B01 the referrer's own card: what the app promises the customer ────────
set local role authenticated;
select set_config('request.jwt.claims',
  json_build_object('sub',(select a_uid from _f),'role','authenticated')::text,true);
create temp table _card as select public.customer_get_referral_card_v300((select slug from _f)) as j;
grant select, insert on all tables in schema pg_temp to authenticated, anon;

insert into _r select '01 the referrer sees a shareable code, and BOTH sides'' rewards',
  case when (j->>'enabled')::boolean is not true then 'FAIL: card disabled: '||j::text
       when coalesce(j->>'code','')='' then 'FAIL: no code to share'
       when (j->>'friend_enabled')::boolean is not true then 'FAIL: the friend''s side is off'
       when coalesce((j->>'friend_reward_points')::int,0)<=0 then 'FAIL: the friend is promised nothing'
       else 'OK code='||(j->>'code')||' referrer='||(j->>'reward_points')||' friend='||(j->>'friend_reward_points') end
from _card;

-- ── B02 the friend applies it ──────────────────────────────────────────────
select set_config('request.jwt.claims',
  json_build_object('sub',(select b_uid from _f),'role','authenticated')::text,true);
create temp table _apply as
select public.customer_apply_referral_code_v571((select slug from _f),'V589AMY',gen_random_uuid()) as j;
grant select, insert on all tables in schema pg_temp to authenticated, anon;

insert into _r select '02 the friend applies the code',
  case when (j->>'applied')::boolean is not true then 'FAIL: '||j::text else 'OK' end from _apply;

reset role;
insert into _r select '02b a pending referral now links the two customers',
  case when count(*)=1 then 'OK' else 'FAIL: '||count(*)||' pending referrals' end
from public.referrals r,_ids i
where r.referrer_client_id=i.a_client and r.referred_client_id=i.b_client and r.status='pending';

-- self-referral and nonsense codes are still refused
set local role authenticated;
select set_config('request.jwt.claims',
  json_build_object('sub',(select a_uid from _f),'role','authenticated')::text,true);
insert into _r select '02c a customer cannot refer themselves',
  case when (public.customer_apply_referral_code_v571((select slug from _f),'V589AMY',gen_random_uuid())->>'reason')='self_referral'
       then 'OK' else 'FAIL' end;

-- ── B03 the friend's first qualifying visit pays BOTH sides ────────────────
reset role;
/* the visit is rung up by a member of staff at the counter — the branch-module gate reads
   auth.uid(), so the till's own actor is who must be standing here. */
select set_config('request.jwt.claims',
  json_build_object('sub',(select staff_uid from _f),'role','authenticated')::text,true);
/* A visit UNDER the firm's minimum spend must leave the referral pending — the firm decides what
   counts as a real customer, and this tenant's threshold is $200. */
insert into public.sales(business_id,client_id,kind,amount_cents,branch_id)
select f.biz,i.b_client,'service',
  greatest(coalesce((select rp.min_spend_cents from public.referral_programs rp where rp.business_id=f.biz),0)-100,100),
  f.branch from _f f,_ids i;

insert into _r select '03pre a visit under the minimum spend settles nothing',
  case when exists(select 1 from public.referrals r,_ids i where r.referred_client_id=i.b_client and r.status<>'pending')
       then 'FAIL: paid out below the firm''s minimum spend'
       when exists(select 1 from public.points_ledger l,_ids i
                    where l.client_id in (i.a_client,i.b_client) and l.reference like 'referral%')
       then 'FAIL: a referral payout landed below the minimum spend'
       else 'OK still pending' end;

-- and now a visit that does qualify
insert into public.sales(business_id,client_id,kind,amount_cents,branch_id)
select f.biz,i.b_client,'service',
  coalesce((select rp.min_spend_cents from public.referral_programs rp where rp.business_id=f.biz),0)+5000,
  f.branch from _f f,_ids i;

insert into _r select '03 the referral is settled by the friend''s first visit',
  case when count(*)=1 then 'OK' else 'FAIL: status not rewarded' end
from public.referrals r,_ids i where r.referred_client_id=i.b_client and r.status='rewarded';

insert into _r select '03a the REFERRER was paid',
  coalesce((select 'OK '||l.points||' pts ('||l.reference||')' from public.points_ledger l,_ids i
            where l.client_id=i.a_client and l.entry_type='earn' and l.reference like 'referral%'),
           'FAIL: the referrer got nothing');

insert into _r select '03b the FRIEND was paid too (v421 — the point of a two-sided referral)',
  coalesce((select 'OK '||l.points||' pts ('||l.reference||')' from public.points_ledger l,_ids i
            where l.client_id=i.b_client and l.entry_type='earn'
              and l.reference like 'referral%'),'FAIL: the friend got nothing');

insert into _r select '03c both payouts carry a spendable batch on the same pot',
  case when (select count(distinct programme_id) from public.points_batches b,_ids i
              where b.client_id in (i.a_client,i.b_client) and b.sale_id is null)=1
        and (select count(*) from public.points_batches b,_ids i
              where b.client_id in (i.a_client,i.b_client) and b.sale_id is null)=2
       then 'OK' else 'FAIL: '||(select count(*) from public.points_batches b,_ids i
              where b.client_id in (i.a_client,i.b_client) and b.sale_id is null)||' referral batches' end;

-- ── B04 a second visit must not pay again ──────────────────────────────────
insert into public.sales(business_id,client_id,kind,amount_cents,branch_id)
select f.biz,i.b_client,'service',
  coalesce((select rp.min_spend_cents from public.referral_programs rp where rp.business_id=f.biz),0)+9000,
  f.branch from _f f,_ids i;

insert into _r select '04 a later visit never pays the referral twice',
  case when (select count(*) from public.points_ledger l,_ids i
              where l.client_id=i.a_client and l.reference like 'referral%')=1
        and (select count(*) from public.points_ledger l,_ids i
              where l.client_id=i.b_client and l.reference like 'referral%')=1
       then 'OK both sides paid exactly once'
       else 'FAIL: referrer x'||(select count(*) from public.points_ledger l,_ids i
              where l.client_id=i.a_client and l.reference like 'referral%')
          ||', friend x'||(select count(*) from public.points_ledger l,_ids i
              where l.client_id=i.b_client and l.reference like 'referral%') end;

select id, value from _r order by id;
rollback;
