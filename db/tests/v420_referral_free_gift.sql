-- Rollback-only acceptance for v420 — a referral may pay a free gift.
--   supabase db query --linked -f db/tests/v420_referral_free_gift.sql
-- Run it as an owner. FAIL rows are failures. Nothing is committed.
--
-- Owner, photo 4: "referral why only points option? can also be free gift." reward_kind has
-- allowed 'voucher' since the column existed and app.on_sale_recorded had NO branch for it, so a
-- firm set to 'voucher' qualified the referral and paid the referrer nothing at all.
--
-- Check 02 is the fix: a friend's first qualifying visit now grants the referrer the named gift.
-- Check 04 proves it does not ALSO pay points, and 08 that switching back to points is lossless.

begin;

create temp table _r(k text,v text) on commit drop;

do $$
declare
  v_biz uuid := '8492e8d6-8888-4383-ada0-7e1ed69f0caa'; v_ref uuid; v_referrer uuid; v_friend uuid; v_branch uuid;
  v_grants integer; v_pts integer; v_msg text; v_ent jsonb; v_res jsonb;
begin
  select id into v_referrer from public.clients where business_id=v_biz order by created_at limit 1;
  select id into v_friend from public.clients where business_id=v_biz and id<>v_referrer order by created_at desc limit 1;
  select id into v_branch from public.branches where business_id=v_biz and active order by is_default desc limit 1;

  -- 00 the owner can now CHOOSE a gift
  perform public.save_referral_program_v420(v_biz, true, 'voucher', null, 'Free Coffee', 5000);
  insert into _r select '00_owner_can_choose_a_gift',
    case when reward_kind='voucher' and reward_label='Free Coffee'
      then 'PASS the programme is set to pay a free gift' else 'FAIL '||reward_kind end
  from public.referral_programs where business_id=v_biz;

  -- 01 naming it is required
  begin
    perform public.save_referral_program_v420(v_biz, true, 'voucher', null, '   ', 5000);
    insert into _r values('01_gift_needs_a_name','FAIL an unnamed gift was accepted');
  exception when others then
    get stacked diagnostics v_msg = message_text;
    insert into _r values('01_gift_needs_a_name',
      case when v_msg like '%name the gift%' then 'PASS '||v_msg else 'FAIL '||v_msg end);
  end;

  -- 02 THE FIX: a friend's first qualifying visit now pays the referrer a gift
  insert into public.referrals(business_id, referrer_client_id, referred_client_id, status)
  values (v_biz, v_referrer, v_friend, 'pending') returning id into v_ref;
  insert into public.sales(business_id, client_id, amount_cents, kind)
  values (v_biz, v_friend, 10000, 'service');

  select count(*) into v_grants from public.referral_grants_v420 where referral_id=v_ref;
  insert into _r values('02_gift_is_granted',
    case when v_grants=1 then 'PASS the referrer was granted a Free Coffee - before v420 a voucher referral paid NOTHING'
         else 'FAIL '||v_grants||' grants' end);
  insert into _r select '03_referral_marked_rewarded',
    case when status='rewarded' then 'PASS the referral qualified' else 'FAIL '||status end
  from public.referrals where id=v_ref;

  -- 04 no points were paid on a gift programme
  select coalesce(sum(points),0) into v_pts from public.points_ledger
   where business_id=v_biz and client_id=v_referrer and reference like 'referral qualified%';
  insert into _r values('04_no_double_payment',
    case when v_pts=0 then 'PASS a gift referral pays a gift, not points as well'
         else 'FAIL it also paid '||v_pts||' points' end);

  -- 05 the till sees it
  v_ent := public.staff_get_customer_entitlements_v102(v_biz, v_referrer);
  insert into _r values('05_counter_sees_it',
    case when v_ent->'referral_offer'->>'reward_label'='Free Coffee'
      then 'PASS the counter offers it when the referrer is looked up'
      else 'FAIL '||coalesce(v_ent->>'referral_offer','null') end);

  -- 06 handing it over records a real visit worth nothing
  v_res := public.staff_redeem_referral_v420(v_biz, v_referrer, v_branch,
    (select id from public.referral_grants_v420 where referral_id=v_ref));
  insert into _r select '06_redeemed_at_zero',
    case when s.amount_cents=0 and s.client_id=v_referrer
      then 'PASS a $0 sale - a real visit, no phantom revenue' else 'FAIL' end
  from public.sales s where s.id=(v_res->>'sale_id')::uuid;

  -- 07 and only once
  begin
    perform public.staff_redeem_referral_v420(v_biz, v_referrer, v_branch,
      (select id from public.referral_grants_v420 where referral_id=v_ref));
    insert into _r values('07_only_once','FAIL the same gift was handed over twice');
  exception when others then
    get stacked diagnostics v_msg = message_text;
    insert into _r values('07_only_once',
      case when v_msg like '%already_redeemed%' then 'PASS a claimed gift cannot be claimed again'
           else 'FAIL '||v_msg end);
  end;

  -- 08 the points path is untouched
  perform public.save_referral_program_v420(v_biz, true, 'points', 50, null, 5000);
  insert into _r select '08_points_still_work',
    case when reward_kind='points' and reward_points=50 and reward_label='Free Coffee'
      then 'PASS switching back keeps the points figure AND remembers the gift name'
      else 'FAIL '||reward_kind||'/'||reward_points||'/'||coalesce(reward_label,'null') end
  from public.referral_programs where business_id=v_biz;
end $$;

insert into _r select '09_no_overload_twin',
  case when count(*)=1 then 'PASS save_referral_program_v322 was not overloaded'
       else 'FAIL '||count(*)||' candidates' end
from pg_proc p join pg_namespace n on n.oid=p.pronamespace
where n.nspname='public' and p.proname='save_referral_program_v322';

insert into _r select '10_not_anon_callable',
  case when count(*)=0 then 'PASS neither new writer is reachable without a session' else 'FAIL' end
from pg_proc p join pg_namespace n on n.oid=p.pronamespace
where n.nspname='public' and p.proname in ('save_referral_program_v420','staff_redeem_referral_v420')
  and has_function_privilege('anon', p.oid, 'execute');

select k as check, v as result from _r order by k;
rollback;
