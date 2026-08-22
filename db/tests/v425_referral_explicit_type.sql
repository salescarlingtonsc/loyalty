-- Rollback-only acceptance for v425 — a referral reward has a TYPE, and an untypable reward is
-- never paid.
--   supabase db query --linked -f db/tests/v425_referral_explicit_type.sql
-- FAIL rows are failures. Nothing is committed.
--
-- This suite runs against the two production tenants whose live shapes are the two halves of the
-- defect:
--   Cubbly SPA (8492e8d6…)   stamps spine ON, points spine OFF, referral_programs.reward_kind
--                            'points'. app.referral_payout_programme_v322 is kind-blind, so its
--                            "50 points" referral was resolving to the STAMPS pot and paying 50
--                            stamps — the silent conversion V355 banned, arriving by another door.
--   QA Test Cafe (dcaaf5d6…) points spine ON. Its referral works, and its live retention program
--                            version ("QA Test 2-visit reward", 2 visits / 30 days, config
--                            version 39ac3336…) is the one loop in production that would still
--                            fire — which is what makes §D a real test rather than a vacuous one.
--
-- The mis-configured state §A starts from is written with a direct UPDATE on purpose: after v425
-- the saver REFUSES to create it, so the only way to reproduce what four live firms are already
-- in is to set the row directly. That is the point of the test.
--
-- A companion suite with its own synthetic fixtures, which is the one that was executed against
-- the local validation substrate, is db/tests/executed/v425_referral_typed_payout.sql.

begin;

create temp table _r(k text, v text) on commit drop;

do $$
declare
  v_stamp_biz uuid := '8492e8d6-8888-4383-ada0-7e1ed69f0caa';
  v_pts_biz   uuid := 'dcaaf5d6-3396-43b4-bff4-1cdd4df01cbf';
  v_owner uuid; v_referrer uuid; v_friend uuid; v_ref uuid;
  v_ppot uuid; v_spot uuid;
  v_n integer; v_before integer; v_grants_before integer;
  v_msg text; v_state text; v_res jsonb;
begin
  select id into v_ppot from public.business_programmes where business_id=v_pts_biz   and kind='points';
  select id into v_spot from public.business_programmes where business_id=v_stamp_biz and kind='stamps';

  -- ==========================================================================================
  -- A. THE HEADLINE: a points reward at a stamps-only firm now pays NOTHING, and says so
  -- ==========================================================================================
  update public.referral_programs
     set enabled=true, reward_kind='points', reward_points=50, min_spend_cents=0
   where business_id=v_stamp_biz;

  select id into v_referrer from public.clients
   where business_id=v_stamp_biz and not exists(select 1 from public.referrals r where r.referred_client_id=clients.id)
   order by created_at limit 1;
  select id into v_friend from public.clients
   where business_id=v_stamp_biz and id<>v_referrer
     and not exists(select 1 from public.referrals r where r.referred_client_id=clients.id)
   order by created_at desc limit 1;

  insert into public.referrals(business_id,referrer_client_id,referred_client_id,status)
  values (v_stamp_biz,v_referrer,v_friend,'pending') returning id into v_ref;

  -- Counted with sale_id IS NULL: the ordinary till earn for this sale is a legitimate row and
  -- has nothing to do with the referral. Every referral payout carries sale_id NULL, so that is
  -- the population "was anything paid for the referral?" has to be asked of.
  select count(*) into v_before from public.points_ledger
   where business_id=v_stamp_biz and sale_id is null;
  insert into public.sales(business_id,client_id,amount_cents,kind)
  values (v_stamp_biz,v_friend,10000,'service');

  insert into _r select 'A1_points_reward_is_not_paid_as_stamps',
    case when count(*)=0 then 'PASS THE FIX: the stamp pot received nothing for a points referral'
         else 'FAIL '||count(*)||' referral rows landed in a pot the owner did not name' end
  from public.points_ledger where business_id=v_stamp_biz and sale_id is null
    and reference like 'referral qualified%';
  insert into _r select 'A2_referral_stays_claimable',
    case when status='pending' and qualified_sale_id is null
      then 'PASS still pending, so it settles the day Points is switched back on'
      else 'FAIL status='||status end
  from public.referrals where id=v_ref;
  insert into _r select 'A3_the_reason_is_visible_on_the_row',
    case when blocked_reason='reward_kind_points_requires_active_points_programme'
      then 'PASS the Referrals page can show the firm what to fix'
      else 'FAIL '||coalesce(blocked_reason,'null') end
  from public.referrals where id=v_ref;
  insert into _r select 'A4_no_unit_was_invented_anywhere',
    case when count(*)=v_before then 'PASS not one referral ledger row was written, in any unit'
         else 'FAIL '||(count(*)-v_before)||' new referral rows' end
  from public.points_ledger where business_id=v_stamp_biz and sale_id is null;

  -- ==========================================================================================
  -- B. TYPED STAMPS: the same firm, told to pay stamps, pays STAMPS into the stamp pot
  -- ==========================================================================================
  select user_id into v_owner from public.staff
   where business_id=v_stamp_biz and role='owner' and active and access_state='approved' limit 1;
  perform set_config('request.jwt.claims', json_build_object('sub',v_owner,'role','authenticated')::text, true);

  perform public.save_referral_program_v421(v_stamp_biz, true, 'stamps', 7, null, 0, true, null, null);
  insert into _r select 'B1_stamps_is_a_reward_type_now',
    case when reward_kind='stamps' and reward_points=7 then 'PASS saved, and the amount survived the switch'
         else 'FAIL '||reward_kind||'/'||reward_points end
  from public.referral_programs where business_id=v_stamp_biz;

  insert into public.sales(business_id,client_id,amount_cents,kind)
  values (v_stamp_biz,v_friend,10000,'service');
  insert into _r select 'B2_stamps_referral_pays_the_stamp_pot_only',
    case when count(*)=2 and bool_and(programme_id=v_spot) and bool_and(points=7)
      then 'PASS both sides received 7 stamps, in the stamp pot'
      else 'FAIL '||count(*)||' rows' end
  from public.points_ledger where business_id=v_stamp_biz and sale_id is null
    and reference like 'referral qualified%';
  insert into _r select 'B3_blocked_reason_was_cleared_by_the_payout',
    case when status='rewarded' and blocked_reason is null then 'PASS the marker clears itself'
         else 'FAIL status='||status||' reason='||coalesce(blocked_reason,'null') end
  from public.referrals where id=v_ref;

  -- B4 exactly once, however many more qualifying sales arrive
  insert into public.sales(business_id,client_id,amount_cents,kind) values (v_stamp_biz,v_friend,10000,'service');
  insert into public.sales(business_id,client_id,amount_cents,kind) values (v_stamp_biz,v_friend,10000,'service');
  insert into _r select 'B4_two_sided_payout_is_exactly_once',
    case when count(*)=2 then 'PASS three qualifying sales, one payout per side'
         else 'FAIL '||count(*)||' payout rows' end
  from public.points_ledger where business_id=v_stamp_biz and sale_id is null
    and reference like 'referral qualified%';

  -- B5 the saver refuses the promise this firm cannot keep
  begin
    perform public.save_referral_program_v421(v_stamp_biz, true, 'points', 50, null, 0, true, null, null);
    insert into _r values('B5_saver_refuses_an_unpayable_type','FAIL the unpayable config was accepted');
  exception when others then
    get stacked diagnostics v_msg = message_text, v_state = returned_sqlstate;
    insert into _r values('B5_saver_refuses_an_unpayable_type',
      case when v_state='22023' and v_msg='referral reward type "points" needs the Point system switched on'
        then 'PASS refused with copy the screen can show'
        else 'FAIL '||v_state||' '||v_msg end);
  end;

  -- ==========================================================================================
  -- C. TYPED POINTS at the points firm, and the $0 gate
  -- ==========================================================================================
  select user_id into v_owner from public.staff
   where business_id=v_pts_biz and role='owner' and active and access_state='approved' limit 1;
  perform set_config('request.jwt.claims', json_build_object('sub',v_owner,'role','authenticated')::text, true);
  perform public.save_referral_program_v421(v_pts_biz, true, 'points', 400, null, 0, true, null, null);

  select id into v_referrer from public.clients
   where business_id=v_pts_biz and not exists(select 1 from public.referrals r where r.referred_client_id=clients.id)
   order by created_at limit 1;
  select id into v_friend from public.clients
   where business_id=v_pts_biz and id<>v_referrer
     and not exists(select 1 from public.referrals r where r.referred_client_id=clients.id)
   order by created_at desc limit 1;
  insert into public.referrals(business_id,referrer_client_id,referred_client_id,status)
  values (v_pts_biz,v_referrer,v_friend,'pending') returning id into v_ref;

  -- C1: a $0 sale is a used package session / a no-charge completed appointment / a quick
  -- reversal. Eleven of production's twelve 'service' sales are exactly this. min_spend_cents is
  -- 0 here, so before v425 `amount_cents >= min_spend_cents` waved it straight through.
  insert into public.sales(business_id,client_id,amount_cents,kind)
  values (v_pts_biz,v_friend,0,'service');
  insert into _r select 'C1_zero_dollar_sale_never_qualifies',
    case when status='pending' and blocked_reason is null
      then 'PASS a $0 visit does not buy a referral, and is not an error either'
      else 'FAIL status='||status||' reason='||coalesce(blocked_reason,'null') end
  from public.referrals where id=v_ref;

  insert into public.sales(business_id,client_id,amount_cents,kind)
  values (v_pts_biz,v_friend,10000,'service');
  insert into _r select 'C2_points_referral_pays_the_points_pot_only',
    case when count(*)=2 and bool_and(programme_id=v_ppot) and bool_and(points=400)
      then 'PASS both sides received 400 points, in the points pot'
      else 'FAIL '||count(*)||' rows' end
  from public.points_ledger where business_id=v_pts_biz and sale_id is null
    and reference like 'referral qualified%';

  -- ==========================================================================================
  -- D. THE LEGACY RETENTION LOOP IS OUT OF THE SALE TRIGGER
  -- ==========================================================================================
  -- QA Test Cafe carries the only retention program version in production that this loop could
  -- still fire (2 visits inside 30 days, on the tenant's ACTIVE config version), so the two sales
  -- above are already the second and third visit of the current window. Before v425 that produced
  -- a reward_grants row; the tables and every existing row stay, only this generation path goes.
  select count(*) into v_grants_before from public.reward_grants where business_id=v_pts_biz;
  insert into public.sales(business_id,client_id,amount_cents,kind) values (v_pts_biz,v_friend,10000,'service');
  insert into _r select 'D1_sale_trigger_no_longer_grants_retention_rewards',
    case when count(*)=v_grants_before
      then 'PASS bringback_campaigns_v361 is the only bring-back engine now'
      else 'FAIL the loop granted '||(count(*)-v_grants_before)||' reward(s)' end
  from public.reward_grants where business_id=v_pts_biz;
  insert into _r select 'D2_existing_retention_data_is_untouched',
    case when count(*)=1 then 'PASS the historical grant and its tables are still there'
         else 'FAIL '||count(*)||' historical grants' end
  from public.reward_grants;

  -- ==========================================================================================
  -- E. ONE SWITCH, ONE TRUTH (SA-4), AND THE WARNING THE SCREEN NEEDS
  -- ==========================================================================================
  v_res := public.set_programmes_v314(v_pts_biz, '{"referral":false}'::jsonb, gen_random_uuid());
  insert into _r select 'E1_referral_switch_moves_the_engine_too',
    case when not enabled
      then 'PASS referral_programs.enabled followed the spine in the same transaction'
      else 'FAIL the engine still reads enabled=true' end
  from public.referral_programs where business_id=v_pts_biz;

  perform public.set_programmes_v314(v_pts_biz, '{"referral":true}'::jsonb, gen_random_uuid());
  v_res := public.set_programmes_v314(v_pts_biz, '{"points":false}'::jsonb, gen_random_uuid());
  insert into _r values('E2_switch_reports_a_now_unpayable_referral',
    case when (v_res->>'referral_reward_kind_now_unpayable')::boolean
      then 'PASS switching Points off is allowed AND reported, so the owner can be warned'
      else 'FAIL flag was '||coalesce(v_res->>'referral_reward_kind_now_unpayable','absent') end);
end $$;

select k as check_name, v as result from _r order by k;

rollback;
