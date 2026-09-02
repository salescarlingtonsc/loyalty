-- Rollback-only v683 acceptance suite — a referral pays only for a NEW customer (audit F025).
--
-- THE SCENARIO IS THE ONE FROM THE FINDING. Two long-standing regulars share each other's
-- referral link. With no spending floor, customer_apply_referral_code_v612 used to settle at
-- once and pay both of them, for an acquisition that never happened. After nestly_v683 the
-- attribution is refused, in the customer's own words, with errcode 22023.
--
-- THE FIXTURE IS BUILT HERE, from scratch, inside the transaction: an owner, a business whose
-- referral programme is ON with a $0 floor (so a successful attribution pays IMMEDIATELY and the
-- payout is visible without a sale), an approved workspace, a subscription, and four customers —
--   Amy      the referrer, a client carrying the code
--   Ben      brand new: verified minutes ago, no sales           → must be attributed and paid
--   Cara     an existing customer: verified now, one paid sale   → must be refused
--   Dan      a member of 30 days who has never bought anything   → must be refused
-- Nothing depends on discovering a suitable tenant in whatever database this runs against.
--
-- SECTION 0  fixture
-- SECTION 1  a self-referral is still refused (the v571 guard this must not disturb)
-- SECTION 2  the brand-new customer is attributed AND both sides are paid, at once
-- SECTION 3  a replay is idempotent — including after the friend starts spending, which is
--            precisely what the new gate must not turn into a refusal
-- SECTION 4  the existing customer is refused, 22023, and nothing is written
-- SECTION 5  the long-standing member with no sales is refused the same way
-- SECTION 6  the predecessor RPC (customer_apply_referral_code_v571, still deployed and
--            callable by any bundle shipped before v612) enforces the same rule
--
-- Run: supabase db query --linked -f db/tests/v683_referral_new_customers_only.sql
-- Everything is inside one transaction that rolls back. Any raised exception is a failure.
begin;
create temporary table v683_evidence(test text, detail text) on commit drop;

do $v683$
declare
  v_business  uuid := gen_random_uuid();
  v_branch    uuid := gen_random_uuid();
  v_owner     uuid := gen_random_uuid();
  v_slug      text := 'v683-acceptance-' || substr(gen_random_uuid()::text, 1, 8);
  v_amy       uuid := gen_random_uuid();
  v_ben       uuid := gen_random_uuid();
  v_cara      uuid := gen_random_uuid();
  v_dan       uuid := gen_random_uuid();
  v_ben_user  uuid := gen_random_uuid();
  v_cara_user uuid := gen_random_uuid();
  v_dan_user  uuid := gen_random_uuid();
  v_ben_phone  text := '8683' || lpad((floor(random()*10000))::text, 4, '0');
  v_cara_phone text := '8684' || lpad((floor(random()*10000))::text, 4, '0');
  v_dan_phone  text := '8685' || lpad((floor(random()*10000))::text, 4, '0');
  v_res       jsonb;
  v_sale      jsonb;
  v_referral  uuid;
  v_state     text;
  v_grants    integer;
  v_n         integer;
  v_sqlstate  text;
  v_message   text;
begin
  -- ---------------------------------------------------------------- SECTION 0
  insert into auth.users(instance_id,id,aud,role,email,encrypted_password,
                         email_confirmed_at,created_at,updated_at)
  values ('00000000-0000-0000-0000-000000000000',v_owner,'authenticated','authenticated',
          'v683-owner-'||substr(v_owner::text,1,8)||'@example.test','',now(),now(),now()),
         ('00000000-0000-0000-0000-000000000000',v_ben_user,'authenticated','authenticated',
          'v683-ben-'||substr(v_ben_user::text,1,8)||'@example.test','',now(),now(),now()),
         ('00000000-0000-0000-0000-000000000000',v_cara_user,'authenticated','authenticated',
          'v683-cara-'||substr(v_cara_user::text,1,8)||'@example.test','',now(),now(),now()),
         ('00000000-0000-0000-0000-000000000000',v_dan_user,'authenticated','authenticated',
          'v683-dan-'||substr(v_dan_user::text,1,8)||'@example.test','',now(),now(),now());

  insert into public.businesses(id,name,slug,industry,enabled_modules,points_mode)
  values (v_business,'V683 Acceptance',v_slug,'fnb',
          array['dashboard','clients','sales','loyalty','referrals','till'],'redeem');

  insert into public.staff(business_id,user_id,role,full_name,active,access_state)
  values (v_business,v_owner,'owner','V683 Owner',true,'approved');
  insert into public.branches(id,business_id,name,is_default,active)
  values (v_branch,v_business,'V683 Main',true,true);
  insert into public.staff_branches(business_id,staff_id,branch_id)
  select v_business, s.id, v_branch from public.staff s
   where s.business_id=v_business and s.user_id=v_owner;

  update public.business_workspace_controls_v94
     set approval_status='approved', version=version+1, decided_by=v_owner,
         decided_at=now(), decision_reason='v683 acceptance fixture', updated_at=now()
   where business_id = v_business;
  update public.business_subscription_lifecycle_v94
     set workspace_paused=false where business_id = v_business;
  insert into public.subscriptions(business_id) values (v_business) on conflict do nothing;

  -- The customer app itself must be switched on, or app.v32_customer_wallet_context refuses every
  -- caller with 0A000 before any referral guard is reached. Production has had these on for a
  -- year; a scratch database built from the migrations has not.
  update app.platform_feature_flags set enabled=true, changed_at=now()
   where feature_key in ('customer_identity','customer_claims','customer_wallet');

  -- The referral programme: ON, a FREE GIFT on both sides, and NO spending floor. The $0 floor is
  -- the finding's worst case — v612 settles at application, so an attribution that should never
  -- have happened is paid before anybody could notice.
  insert into public.referral_programs(business_id,enabled,reward_kind,reward_label,
                                       friend_enabled,friend_reward_label,min_spend_cents,reward_points)
  values (v_business,true,'voucher','V683 Referrer gift',true,'V683 Friend gift',0,0)
  on conflict (business_id) do update
     set enabled=true, reward_kind='voucher', reward_label='V683 Referrer gift',
         friend_enabled=true, friend_reward_label='V683 Friend gift', min_spend_cents=0;

  insert into public.clients(id,business_id,full_name,phone)
  values (v_amy, v_business,'V683 Amy (referrer)','8682'||lpad((floor(random()*10000))::text,4,'0')),
         (v_ben, v_business,'V683 Ben (brand new)',  v_ben_phone),
         (v_cara,v_business,'V683 Cara (existing)',  v_cara_phone),
         (v_dan, v_business,'V683 Dan (old member)', v_dan_phone);
  update public.clients set referral_code='V683AMY' where id=v_amy;
  update public.clients set referral_code='V683BEN' where id=v_ben;

  -- Three verified customer links. Ben's and Cara's are minutes old; Dan's is backdated by 30
  -- days at INSERT — now() is frozen for the whole transaction, so a member of long standing can
  -- only be built by writing the older timestamps, never by waiting.
  insert into public.customer_identities(auth_user_id,status,created_via)
  values (v_ben_user,'active','wallet_start'),
         (v_cara_user,'active','wallet_start'),
         (v_dan_user,'active','wallet_start');

  perform set_config('app.customer_link_insert_id', gen_random_uuid()::text, true);
  insert into public.customer_links(id,business_id,identity_id,auth_user_id,client_id,state,
                                    verification_method,verified_at)
  select current_setting('app.customer_link_insert_id')::uuid, v_business, ci.id, v_ben_user, v_ben,
         'verified','qr_join',now()
    from public.customer_identities ci where ci.auth_user_id=v_ben_user;
  perform set_config('app.customer_link_insert_id', gen_random_uuid()::text, true);
  insert into public.customer_links(id,business_id,identity_id,auth_user_id,client_id,state,
                                    verification_method,verified_at)
  select current_setting('app.customer_link_insert_id')::uuid, v_business, ci.id, v_cara_user, v_cara,
         'verified','qr_join',now()
    from public.customer_identities ci where ci.auth_user_id=v_cara_user;
  perform set_config('app.customer_link_insert_id', gen_random_uuid()::text, true);
  insert into public.customer_links(id,business_id,identity_id,auth_user_id,client_id,state,
                                    verification_method,verified_at,created_at,updated_at)
  select current_setting('app.customer_link_insert_id')::uuid, v_business, ci.id, v_dan_user, v_dan,
         'verified','qr_join',now()-interval '30 days',now()-interval '30 days',now()-interval '30 days'
    from public.customer_identities ci where ci.auth_user_id=v_dan_user;
  perform set_config('app.customer_link_insert_id','',true);

  -- Cara's history: one real till sale, through the till's own RPC, as the owner.
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_owner, 'role', 'authenticated')::text, true);
  v_sale := public.record_sale_by_phone(
    v_business, v_cara_phone, 1500, 'quick_sale', 'v683 fixture: Cara is already a customer',
    null, 'v683-'||replace(gen_random_uuid()::text,'-',''), v_branch, 'cash', null)::jsonb;
  if (v_sale->>'status') <> 'ok' then
    raise exception 'FIXTURE: the till refused Cara''s sale (%)', v_sale::text; end if;

  if app.referral_referred_is_new_v683(v_business, v_ben) is not true then
    raise exception 'FIXTURE: Ben should read as new'; end if;
  if app.referral_referred_is_new_v683(v_business, v_cara) is not false then
    raise exception 'FIXTURE: Cara has a paid sale and must not read as new'; end if;
  if app.referral_referred_is_new_v683(v_business, v_dan) is not false then
    raise exception 'FIXTURE: Dan has been a member for 30 days and must not read as new'; end if;
  insert into v683_evidence values('S0',
    'business '||v_business||' — referral ON, voucher both sides, floor $0; Amy=referrer, '
    ||'Ben=new, Cara=1 paid sale, Dan=member since 30 days');

  -- ---------------------------------------------------------------- SECTION 1
  -- Self-referral: unchanged, and answered BEFORE the new-customer gate ever runs.
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_ben_user, 'role', 'authenticated')::text, true);
  v_res := public.customer_apply_referral_code_v612(v_slug, 'V683BEN', gen_random_uuid());
  if coalesce((v_res->>'applied')::boolean, true) is not false
     or v_res->>'reason' <> 'self_referral' then
    raise exception 'S1 FAIL: own code answered %', v_res::text; end if;
  if exists (select 1 from public.referrals r where r.referred_client_id = v_ben) then
    raise exception 'S1 FAIL: a self-referral wrote a referrals row'; end if;
  insert into v683_evidence values('S1','own code → self_referral, nothing written');

  -- ---------------------------------------------------------------- SECTION 2
  -- The brand-new customer: attributed, and — with no floor — both sides paid at once.
  v_res := public.customer_apply_referral_code_v612(v_slug, 'V683AMY', gen_random_uuid());
  if coalesce((v_res->>'applied')::boolean, false) is not true
     or v_res->>'reason' <> 'ok'
     or v_res->>'settled' is distinct from 'immediate' then
    raise exception 'S2 FAIL: a new customer was not attributed and settled (%)', v_res::text; end if;
  v_referral := (v_res->>'referral_id')::uuid;

  select r.status into v_state from public.referrals r where r.id = v_referral;
  if v_state <> 'rewarded' then
    raise exception 'S2 FAIL: referral status is %, expected rewarded', v_state; end if;
  select count(*)::integer into v_grants from public.referral_grants_v420 g
   where g.referral_id = v_referral;
  if v_grants <> 2 then
    raise exception 'S2 FAIL: % grant rows, expected one per side', v_grants; end if;
  if not exists (select 1 from public.referral_grants_v420 g
                  where g.referral_id=v_referral and g.beneficiary='referrer' and g.client_id=v_amy)
     or not exists (select 1 from public.referral_grants_v420 g
                  where g.referral_id=v_referral and g.beneficiary='friend' and g.client_id=v_ben) then
    raise exception 'S2 FAIL: the two grants are not one to Amy and one to Ben'; end if;
  insert into v683_evidence values('S2',
    'brand-new customer attributed (referral '||v_referral||') and both sides paid immediately');

  -- ---------------------------------------------------------------- SECTION 3
  -- Idempotent replay. The wallet re-applies a stored code on every render, so this is the
  -- ordinary case, not an edge one — twice now, and twice again AFTER Ben starts spending, which
  -- is the moment he stops being "new" and a naively-placed gate would start refusing him.
  v_res := public.customer_apply_referral_code_v612(v_slug, 'V683AMY', gen_random_uuid());
  if coalesce((v_res->>'applied')::boolean, false) is not true
     or v_res->>'reason' <> 'already_applied'
     or (v_res->>'referral_id')::uuid <> v_referral then
    raise exception 'S3 FAIL: replay answered %', v_res::text; end if;

  perform set_config('request.jwt.claims',
    json_build_object('sub', v_owner, 'role', 'authenticated')::text, true);
  v_sale := public.record_sale_by_phone(
    v_business, v_ben_phone, 900, 'quick_sale', 'v683: the referred friend''s first visit',
    null, 'v683-'||replace(gen_random_uuid()::text,'-',''), v_branch, 'cash', null)::jsonb;
  if (v_sale->>'status') <> 'ok' then
    raise exception 'FIXTURE: the till refused Ben''s sale (%)', v_sale::text; end if;
  if app.referral_referred_is_new_v683(v_business, v_ben) is not false then
    raise exception 'S3 FAIL: Ben should no longer read as new after a paid sale'; end if;

  perform set_config('request.jwt.claims',
    json_build_object('sub', v_ben_user, 'role', 'authenticated')::text, true);
  v_res := public.customer_apply_referral_code_v612(v_slug, 'V683AMY', gen_random_uuid());
  if coalesce((v_res->>'applied')::boolean, false) is not true
     or v_res->>'reason' <> 'already_applied' then
    raise exception 'S3 FAIL: a customer already attributed was refused once he spent: %', v_res::text; end if;
  select count(*)::integer into v_n from public.referral_grants_v420 g where g.referral_id=v_referral;
  if v_n <> 2 then
    raise exception 'S3 FAIL: replays minted % grant rows', v_n; end if;
  insert into v683_evidence values('S3',
    'three replays → already_applied every time, still exactly 2 grants, including after his first sale');

  -- ---------------------------------------------------------------- SECTION 4
  -- The existing customer. This is the finding: before v683 Cara was attributed and both she and
  -- Amy were paid, here and now, for nothing.
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_cara_user, 'role', 'authenticated')::text, true);
  begin
    v_res := public.customer_apply_referral_code_v612(v_slug, 'V683AMY', gen_random_uuid());
    raise exception 'S4 FAIL: an existing customer was attributed (%)', v_res::text;
  exception when sqlstate '22023' then
    get stacked diagnostics v_message = message_text;
  end;
  if v_message not like '%new customers%' then
    raise exception 'S4 FAIL: the refusal is not readable by a customer: %', v_message; end if;
  if exists (select 1 from public.referrals r where r.referred_client_id = v_cara) then
    raise exception 'S4 FAIL: the refusal still wrote a referrals row'; end if;
  select count(*)::integer into v_n from public.referral_grants_v420 g where g.business_id=v_business;
  if v_n <> 2 then
    raise exception 'S4 FAIL: the refusal paid somebody (% grants)', v_n; end if;
  insert into v683_evidence values('S4','existing customer refused 22023 "'||v_message||'", nothing written, nobody paid');

  -- ---------------------------------------------------------------- SECTION 5
  -- The member of 30 days who never bought anything. No sale to disqualify him — the business
  -- simply acquired him a month ago, so nobody may be paid for introducing him now.
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_dan_user, 'role', 'authenticated')::text, true);
  begin
    v_res := public.customer_apply_referral_code_v612(v_slug, 'V683AMY', gen_random_uuid());
    raise exception 'S5 FAIL: a member of 30 days was attributed (%)', v_res::text;
  exception when sqlstate '22023' then
    get stacked diagnostics v_message = message_text;
  end;
  if exists (select 1 from public.referrals r where r.referred_client_id = v_dan) then
    raise exception 'S5 FAIL: the refusal still wrote a referrals row'; end if;
  insert into v683_evidence values('S5','30-day member with no sales refused 22023 "'||v_message||'"');

  -- ---------------------------------------------------------------- SECTION 6
  -- The predecessor RPC is still deployed and is what an older cached bundle calls. It must not
  -- be the way around the rule — and it must still attribute a genuinely new customer.
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_cara_user, 'role', 'authenticated')::text, true);
  begin
    v_res := public.customer_apply_referral_code_v571(v_slug, 'V683AMY', gen_random_uuid());
    raise exception 'S6 FAIL: the v571 RPC attributed an existing customer (%)', v_res::text;
  exception when sqlstate '22023' then
    get stacked diagnostics v_sqlstate = returned_sqlstate, v_message = message_text;
  end;
  if v_sqlstate <> '22023' or v_message not like '%new customers%' then
    raise exception 'S6 FAIL: v571 refused with % / %', v_sqlstate, v_message; end if;
  if exists (select 1 from public.referrals r where r.referred_client_id = v_cara) then
    raise exception 'S6 FAIL: v571 wrote a referrals row for an existing customer'; end if;
  insert into v683_evidence values('S6','v571 refuses the same customer, same code, same message');
end
$v683$;

select test, detail from v683_evidence order by test;
rollback;
