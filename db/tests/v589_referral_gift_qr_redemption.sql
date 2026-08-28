-- Rollback-only acceptance: the free-gift referral, from the code to the scanned QR
-- (nestly_v420/v421/v515/v589).
-- Run: supabase db query --linked -f db/tests/v589_referral_gift_qr_redemption.sql
-- Any value starting FAIL is a failure. Nothing is committed.
--
-- The owner asked whether both sides "are able to scan qrcode to redeem". This proves the whole
-- chain: the owner switches the reward to a named free gift (one Save, both doors - nestly_v589),
-- a friend arrives on a referral code, their qualifying visit leaves a gift for EACH side, the
-- friend finds theirs in their own wallet, puts it on screen as a QR, a member of staff scans it,
-- a second scan gives nothing away, and the referrer's gift redeems on its own terms.
--
-- It is a SEPARATE transaction from the points suite on purpose: the v480 loyalty fence refuses
-- to upgrade shared->exclusive, so an owner cannot edit the programme in the same transaction
-- that rang up a sale. That is the fence working, not a limitation of the test.
begin;
create temp table _r(id text, value text) on commit drop;
grant select, insert on all tables in schema pg_temp to authenticated, anon;

create temp table _f as
select b.id as biz, b.slug,
  (select br.id from public.branches br where br.business_id=b.id and br.active order by br.is_default desc limit 1) as branch,
  (select s.user_id from public.staff s where s.business_id=b.id and s.role='owner' and s.user_id is not null limit 1) as staff_uid,
  (select u.id from auth.users u where u.email='qa-frenly-test@example.invalid') as a_uid,
  (select u.id from auth.users u where u.email='ps1b1-synthetic-staff-16acb005@example.test') as c_uid
from public.businesses b where b.slug='ahxiang';
grant select, insert on all tables in schema pg_temp to authenticated, anon;

-- ── the owner switches the referral reward to a named free gift ────────────
-- This is the standalone Referrals page's own Save. nestly_v589 makes it move the programme
-- spine as well, so it is asserted here rather than assumed.
set local role authenticated;
select set_config('request.jwt.claims',
  json_build_object('sub',(select staff_uid from _f),'role','authenticated')::text,true);
select public.save_referral_program_v421((select biz from _f),true,'voucher',0,
  'Free regular kopi',20000,true,0,'Free kaya toast');
reset role;

insert into _r select '01 switching the reward moves BOTH doors together (nestly_v589)',
  case when not exists(select 1 from public.referral_programs rp,_f f
                        where rp.business_id=f.biz and rp.enabled and rp.reward_kind='voucher')
       then 'FAIL: the paying column did not take the change'
       when not exists(select 1 from public.business_programmes sp,_f f
                        where sp.business_id=f.biz and sp.kind='referral' and sp.active)
       then 'FAIL: the spine and the payout engine disagree'
       else 'OK' end;

-- ── two customers: the one who refers, and the friend who arrives ──────────
create temp table _ids as
with a as (insert into public.clients(business_id,full_name,phone)
           select biz,'V589 Referrer Amy','80000589' from _f returning id),
c as (insert into public.clients(business_id,full_name,phone)
      select biz,'V589 Friend Cara','80000591' from _f returning id)
select (select id from a) as a_client, (select id from c) as c_client;
grant select, insert on all tables in schema pg_temp to authenticated, anon;
update public.clients set referral_code='V589AMY' where id=(select a_client from _ids);

do $$
declare f record; i record; v_id uuid; v_uid uuid; v_cli uuid;
begin
  select * into f from _f; select * into i from _ids;
  foreach v_uid in array array[f.a_uid,f.c_uid] loop
    v_cli := case when v_uid=f.a_uid then i.a_client else i.c_client end;
    insert into public.customer_identities(auth_user_id,status,created_via)
    select v_uid,'active','wallet_start'
    where not exists(select 1 from public.customer_identities ci where ci.auth_user_id=v_uid);
    v_id:=gen_random_uuid();
    perform set_config('app.customer_link_insert_id',v_id::text,true);
    insert into public.customer_links(id,business_id,identity_id,auth_user_id,client_id,state,verification_method,verified_at)
    values(v_id,f.biz,(select id from public.customer_identities where auth_user_id=v_uid limit 1),
           v_uid,v_cli,'verified','qr_join',now());
  end loop;
  perform set_config('app.customer_link_insert_id','',true);
end $$;

set local role authenticated;
select set_config('request.jwt.claims',
  json_build_object('sub',(select c_uid from _f),'role','authenticated')::text,true);
insert into _r select '02 the friend applies the referrer''s code',
  case when (public.customer_apply_referral_code_v571((select slug from _f),'V589AMY',gen_random_uuid())->>'applied')::boolean
       then 'OK' else 'FAIL' end;

reset role;
select set_config('request.jwt.claims',
  json_build_object('sub',(select staff_uid from _f),'role','authenticated')::text,true);
insert into public.sales(business_id,client_id,kind,amount_cents,branch_id)
select f.biz,i.c_client,'service',25000,f.branch from _f f,_ids i;

insert into _r select '03 a free-gift referral leaves a gift for EACH side',
  coalesce((select 'OK '||string_agg(g.beneficiary||'="'||g.reward_label||'"/'||g.status,', ' order by g.beneficiary)
            from public.referral_grants_v420 g,_ids i
            where g.client_id in (i.a_client,i.c_client)),'FAIL: no gifts were granted');

insert into _r select '03b each side''s gift names that side''s own reward',
  case when (select count(*) from public.referral_grants_v420 g,_ids i
              where g.client_id=i.a_client and g.beneficiary='referrer'
                and g.reward_label='Free regular kopi' and g.status='granted')=1
        and (select count(*) from public.referral_grants_v420 g,_ids i
              where g.client_id=i.c_client and g.beneficiary='friend'
                and g.reward_label='Free kaya toast' and g.status='granted')=1
       then 'OK' else 'FAIL: the two sides are not distinctly rewarded' end;

-- Before any QR exists: can the friend FIND the gift in their own wallet at all?
set local role authenticated;
select set_config('request.jwt.claims',
  json_build_object('sub',(select c_uid from _f),'role','authenticated')::text,true);
create temp table _ent as select public.customer_get_entitlements_v427((select slug from _f)) as j;
grant select, insert on all tables in schema pg_temp to authenticated, anon;
reset role;
insert into _r select '03c the friend sees the gift in their own wallet',
  case when (select j::text from _ent) like '%Free kaya toast%' then 'OK'
       else 'FAIL: the gift is granted but the customer cannot see it: '
            ||left((select j::text from _ent),300) end;

create temp table _grants as
select (select g.id from public.referral_grants_v420 g,_ids i
         where g.client_id=i.c_client and g.beneficiary='friend') as friend_grant,
       (select g.id from public.referral_grants_v420 g,_ids i
         where g.client_id=i.a_client and g.beneficiary='referrer') as referrer_grant;
grant select, insert on all tables in schema pg_temp to authenticated, anon;

-- ── the friend puts the gift on screen; a member of staff scans it ─────────
set local role authenticated;
select set_config('request.jwt.claims',
  json_build_object('sub',(select c_uid from _f),'role','authenticated')::text,true);
create temp table _qr as
select public.customer_create_gift_intent_v515((select biz from _f),'referral',
  (select friend_grant from _grants),gen_random_uuid()) as j;
grant select, insert on all tables in schema pg_temp to authenticated, anon;

insert into _r select '04 the friend can put their gift on screen as a QR',
  case when coalesce((select j->>'qr_token' from _qr),'')='' then 'FAIL: no QR token: '||(select j::text from _qr)
       when length((select j->>'qr_token' from _qr))<32 then 'FAIL: token too short to scan'
       else 'OK '||coalesce((select j->>'gift_kind' from _qr),'?')||'/'||coalesce((select j->>'reward_label' from _qr),'?') end;

select set_config('request.jwt.claims',
  json_build_object('sub',(select staff_uid from _f),'role','authenticated')::text,true);
create temp table _scan as
select public.staff_scan_gift_qr_v515((select biz from _f),(select branch from _f),
  (select j->>'qr_token' from _qr),null,gen_random_uuid()) as j;
grant select, insert on all tables in schema pg_temp to authenticated, anon;

reset role;
insert into _r select '05 staff scanning that QR redeems the gift',
  case when (select g.status from public.referral_grants_v420 g,_grants gr where g.id=gr.friend_grant)<>'redeemed'
       then 'FAIL: the gift was not redeemed: '||(select j::text from _scan)
       else 'OK '||coalesce((select j->>'status' from _scan),'')||' '||coalesce((select j->>'reward_label' from _scan),'') end;

set local role authenticated;
select set_config('request.jwt.claims',
  json_build_object('sub',(select staff_uid from _f),'role','authenticated')::text,true);
create temp table _scan2 as
select public.staff_scan_gift_qr_v515((select biz from _f),(select branch from _f),
  (select j->>'qr_token' from _qr),null,gen_random_uuid()) as j;
grant select, insert on all tables in schema pg_temp to authenticated, anon;
reset role;

insert into _r select '06 scanning the same QR twice gives away only one gift',
  case when coalesce((select (j->>'replayed')::boolean from _scan2),false) is not true
       then 'FAIL: the second scan was not a replay: '||(select j::text from _scan2)
       when (select count(*) from public.sales sa,_ids i
              where sa.client_id=i.c_client and sa.note like 'referral gift redeemed%')>1
       then 'FAIL: two redemption sales were written'
       else 'OK' end;

insert into _r select '07 the referrer''s gift is untouched by the friend redeeming theirs',
  case when (select g.status from public.referral_grants_v420 g,_grants gr where g.id=gr.referrer_grant)='granted'
       then 'OK' else 'FAIL: it moved' end;

set local role authenticated;
select set_config('request.jwt.claims',
  json_build_object('sub',(select staff_uid from _f),'role','authenticated')::text,true);
select public.staff_redeem_referral_v420((select biz from _f),(select a_client from _ids),
  (select branch from _f),(select referrer_grant from _grants));
reset role;
insert into _r select '08 and the referrer redeems theirs independently',
  case when (select g.status from public.referral_grants_v420 g,_grants gr where g.id=gr.referrer_grant)='redeemed'
       then 'OK' else 'FAIL' end;

do $$
declare v_msg text;
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub',(select staff_uid from _f),'role','authenticated')::text,true);
  begin
    perform public.staff_redeem_referral_v420((select biz from _f),(select a_client from _ids),
      (select branch from _f),(select referrer_grant from _grants));
    v_msg:='FAIL: a spent gift was redeemed a second time';
  exception when others then
    v_msg:=case when sqlerrm like '%already_redeemed%' then 'OK' else 'FAIL: '||sqlerrm end;
  end;
  insert into _r values('09 a spent gift refuses a second redemption', v_msg);
end $$;

select id, value from _r order by id;
rollback;
