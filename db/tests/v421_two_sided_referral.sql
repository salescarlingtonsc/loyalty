-- Rollback-only acceptance for v421 — the friend gets the reward too.
--   supabase db query --linked -f db/tests/v421_two_sided_referral.sql
-- Run it as an owner. FAIL rows are failures. Nothing is committed.
--
-- Owner, 2026-08-21: "yes make the friend get the reward too." Until v421 app.on_sale_recorded
-- paid one side of a referral — the referrer — and nothing anywhere paid the friend.
--
-- The gift path runs on Cubbly SPA (stamps firm, so the points lane is inert there) and the points
-- path on QA Test Cafe (points spine active), which is the only way to exercise both lanes.

begin;

create temp table _r(k text,v text) on commit drop;

do $$
declare
  v_gift_biz uuid := '8492e8d6-8888-4383-ada0-7e1ed69f0caa';
  v_pts_biz  uuid := 'dcaaf5d6-3396-43b4-bff4-1cdd4df01cbf';
  v_ref uuid; v_referrer uuid; v_friend uuid; v_branch uuid;
  v_referrer_grant uuid; v_friend_grant uuid; v_owner uuid;
  v_n integer; v_pts_referrer integer; v_pts_friend integer; v_msg text; v_ent jsonb;
begin
  -- ==========================================================================================
  -- A. THE GIFT LANE
  -- ==========================================================================================
  -- Act as the firm's own owner: these writers are gated on app.can_module_write, which reads
  -- auth.uid(). Running the suite as postgres would prove nothing about who may call them.
  select user_id into v_owner from public.staff where business_id=v_gift_biz and role='owner' and active limit 1;
  perform set_config('request.jwt.claims', json_build_object('sub',v_owner,'role','authenticated')::text, true);

  select id into v_referrer from public.clients where business_id=v_gift_biz order by created_at limit 1;
  select id into v_friend from public.clients where business_id=v_gift_biz and id<>v_referrer order by created_at desc limit 1;
  select id into v_branch from public.branches where business_id=v_gift_biz and active order by is_default desc limit 1;

  perform public.save_referral_program_v421(v_gift_biz, true, 'voucher', null, 'Free Coffee', 5000,
                                            true, null, null);

  insert into public.referrals(business_id, referrer_client_id, referred_client_id, status)
  values (v_gift_biz, v_referrer, v_friend, 'pending') returning id into v_ref;
  insert into public.sales(business_id, client_id, amount_cents, kind)
  values (v_gift_biz, v_friend, 10000, 'service');

  select id into v_referrer_grant from public.referral_grants_v420 where referral_id=v_ref and beneficiary='referrer';
  select id into v_friend_grant   from public.referral_grants_v420 where referral_id=v_ref and beneficiary='friend';

  insert into _r values('01_referrer_still_paid',
    case when v_referrer_grant is not null then 'PASS the referrer''s gift is unchanged'
         else 'FAIL the referrer was not granted anything' end);
  insert into _r values('02_friend_paid_too',
    case when v_friend_grant is not null then 'PASS THE FIX: the friend was granted a gift as well'
         else 'FAIL the friend got nothing' end);
  insert into _r select '03_friend_grant_belongs_to_the_friend',
    case when client_id=v_friend then 'PASS it is held against the friend, not the referrer'
         else 'FAIL it was written against '||client_id end
  from public.referral_grants_v420 where id=v_friend_grant;
  insert into _r select '04_friend_gift_defaults_to_the_same_thing',
    case when reward_label='Free Coffee' then 'PASS an unset friend gift means the same gift'
         else 'FAIL '||reward_label end
  from public.referral_grants_v420 where id=v_friend_grant;

  -- 05 the counter offers the friend theirs when the FRIEND is looked up
  v_ent := public.staff_get_customer_entitlements_v102(v_gift_biz, v_friend);
  insert into _r values('05_counter_sees_the_friends_gift',
    case when v_ent->'referral_offer'->>'reward_label'='Free Coffee'
      then 'PASS looking the friend up offers it' else 'FAIL '||coalesce(v_ent->>'referral_offer','null') end);

  -- 06 handing the friend's over does not touch the referrer's
  perform public.staff_redeem_referral_v420(v_gift_biz, v_friend, v_branch, v_friend_grant);
  insert into _r select '06_two_sides_redeem_independently',
    case when (select status from public.referral_grants_v420 where id=v_friend_grant)='redeemed'
          and (select status from public.referral_grants_v420 where id=v_referrer_grant)='granted'
      then 'PASS the friend claimed theirs; the referrer''s is still waiting' else 'FAIL' end;

  -- 07 a replayed sale pays neither side twice
  insert into public.sales(business_id, client_id, amount_cents, kind)
  values (v_gift_biz, v_friend, 10000, 'service');
  select count(*) into v_n from public.referral_grants_v420 where referral_id=v_ref;
  insert into _r values('07_replay_pays_nobody_twice',
    case when v_n=2 then 'PASS still exactly one gift per side' else 'FAIL '||v_n||' grants' end);

  -- 08 a firm may switch the friend's side back off
  perform public.save_referral_program_v421(v_gift_biz, true, 'voucher', null, 'Free Coffee', 5000,
                                            false, null, null);
  select id into v_referrer from public.clients where business_id=v_gift_biz order by created_at limit 1;
  select id into v_friend from public.clients where business_id=v_gift_biz and id<>v_referrer order by created_at desc offset 1 limit 1;
  insert into public.referrals(business_id, referrer_client_id, referred_client_id, status)
  values (v_gift_biz, v_referrer, v_friend, 'pending') returning id into v_ref;
  insert into public.sales(business_id, client_id, amount_cents, kind)
  values (v_gift_biz, v_friend, 10000, 'service');
  select count(*) into v_n from public.referral_grants_v420 where referral_id=v_ref;
  insert into _r values('08_friend_side_can_be_switched_off',
    case when v_n=1 and exists(select 1 from public.referral_grants_v420 where referral_id=v_ref and beneficiary='referrer')
      then 'PASS friend_enabled=false restores the one-sided payout' else 'FAIL '||v_n||' grants' end);

  -- ==========================================================================================
  -- B. THE POINTS LANE
  -- ==========================================================================================
  select user_id into v_owner from public.staff where business_id=v_pts_biz and role='owner' and active limit 1;
  perform set_config('request.jwt.claims', json_build_object('sub',v_owner,'role','authenticated')::text, true);

  select id into v_referrer from public.clients where business_id=v_pts_biz order by created_at limit 1;
  select id into v_friend from public.clients where business_id=v_pts_biz and id<>v_referrer order by created_at desc limit 1;

  perform public.save_referral_program_v421(v_pts_biz, true, 'points', 400, null, 0, true, null, null);
  insert into public.referrals(business_id, referrer_client_id, referred_client_id, status)
  values (v_pts_biz, v_referrer, v_friend, 'pending') returning id into v_ref;
  insert into public.sales(business_id, client_id, amount_cents, kind)
  values (v_pts_biz, v_friend, 10000, 'service');

  select coalesce(sum(points),0) into v_pts_referrer from public.points_ledger
   where business_id=v_pts_biz and client_id=v_referrer and reference='referral qualified: first visit completed';
  select coalesce(sum(points),0) into v_pts_friend from public.points_ledger
   where business_id=v_pts_biz and client_id=v_friend and reference='referral qualified: introduced by a friend';
  insert into _r values('09_points_referrer_unchanged',
    case when v_pts_referrer=400 then 'PASS the referrer still gets 400' else 'FAIL '||v_pts_referrer end);
  insert into _r values('10_points_friend_paid_the_same',
    case when v_pts_friend=400 then 'PASS THE FIX: the friend gets 400 too, with no figure set'
         else 'FAIL '||v_pts_friend end);
  insert into _r select '11_friend_points_have_a_batch',
    case when count(*)=1 then 'PASS the friend''s points can actually be spent (a batch exists)'
         else 'FAIL '||count(*)||' batches' end
  from public.points_batches where business_id=v_pts_biz and client_id=v_friend and sale_id is null and earned=400;

  -- 12 a firm may pay the friend a different figure
  select id into v_friend from public.clients where business_id=v_pts_biz and id<>v_referrer order by created_at offset 1 limit 1;
  perform public.save_referral_program_v421(v_pts_biz, true, 'points', 400, null, 0, true, 100, null);
  insert into public.referrals(business_id, referrer_client_id, referred_client_id, status)
  values (v_pts_biz, v_referrer, v_friend, 'pending') returning id into v_ref;
  insert into public.sales(business_id, client_id, amount_cents, kind)
  values (v_pts_biz, v_friend, 10000, 'service');
  select coalesce(sum(points),0) into v_pts_friend from public.points_ledger
   where business_id=v_pts_biz and client_id=v_friend and reference='referral qualified: introduced by a friend';
  insert into _r values('12_friend_figure_can_differ',
    case when v_pts_friend=100 then 'PASS the friend''s own figure is honoured' else 'FAIL '||v_pts_friend end);

  -- 13 a negative friend figure is refused
  begin
    perform public.save_referral_program_v421(v_pts_biz, true, 'points', 400, null, 0, true, -5, null);
    insert into _r values('13_negative_friend_points_refused','FAIL a negative figure was accepted');
  exception when others then
    get stacked diagnostics v_msg = message_text;
    insert into _r values('13_negative_friend_points_refused',
      case when v_msg like '%cannot be negative%' then 'PASS '||v_msg else 'FAIL '||v_msg end);
  end;
end $$;

-- 14 the customer's own card now describes both sides (read as the firm; the RPC itself needs a
-- customer session, so the columns it reads are checked directly).
insert into _r select '14_card_reads_both_sides',
  case when pg_get_functiondef(p.oid) like '%friend_reward_points%'
        and pg_get_functiondef(p.oid) like '%reward_label%'
    then 'PASS the customer read carries the gift name and the friend''s share'
    else 'FAIL the customer read was not updated' end
from pg_proc p join pg_namespace n on n.oid=p.pronamespace
where n.nspname='public' and p.proname='customer_get_referral_card_v300';

select k, v from _r order by k;
rollback;
