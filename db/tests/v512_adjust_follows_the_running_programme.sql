-- Rollback-only acceptance for nestly_v512 — an owner's balance correction lands in the
-- programme the customer is actually on.
-- Run: supabase db query --linked -f db/tests/v512_adjust_follows_the_running_programme.sql
-- Any row whose value starts with FAIL is a failure. Nothing is committed.
--
-- adjust_points resolved its pot with `where kind='points'` and NO `active` test. Every business
-- owns all four spine rows from birth, so on a stamp-card business the correction landed in the
-- dormant POINTS pot — invisible to every customer surface (each programme reads its own pot
-- since V312/v381) — and the RPC still returned a cheerful new balance. AhXiang is exactly that
-- shape, and is the tenant holding the S$3,200 sale that earned nothing before v507.
--
--   01  STAMPS: the correction lands in the STAMPS pot, and the stamps balance moves
--   02  the dormant POINTS pot is untouched — this is the bug, pinned
--   03  the stamp batch carries no invented expiry (a card's life is its cycle, not a batch date)
--   04  POINTS is unchanged: a points business still credits the points pot, with its own
--       fixed-expiry rule applied
--   05  with NOTHING running the call REFUSES rather than filling a dormant pot
--   06  the negative path still proves itself against the running pot's batches
begin;

create temp table _r(k text, v text) on commit drop;

create or replace function pg_temp.as_v512_user(p_uid uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claim.sub', coalesce(p_uid::text, ''), true);
  perform set_config('request.jwt.claims',
    json_build_object('sub', p_uid, 'role', 'authenticated')::text, true);
end
$$;
grant execute on function pg_temp.as_v512_user(uuid) to public;

do $$
declare
  v_owner uuid := gen_random_uuid();
  v_biz uuid := gen_random_uuid();          -- stamps business
  v_biz_p uuid := gen_random_uuid();        -- points business
  v_branch uuid := gen_random_uuid();
  v_slug text := 'v512-stamps-' || substr(gen_random_uuid()::text, 1, 8);
  v_slug_p text := 'v512-points-' || substr(gen_random_uuid()::text, 1, 8);
  v_client uuid := gen_random_uuid();
  v_client_p uuid := gen_random_uuid();
  v_stamp_spine uuid; v_points_spine uuid; v_points_spine_p uuid;
  v_bal integer; v_n integer; v_exp timestamptz; v_txt text;
begin
  -- ==========================================================================================
  -- FIXTURE A — a business running the STAMP CARD (points row present but switched off)
  -- ==========================================================================================
  insert into public.businesses(id, name, slug, enabled_modules, points_mode)
  values (v_biz, 'V510 Stamps', v_slug, array['loyalty'], 'redeem');
  insert into auth.users(instance_id, id, aud, role, email, encrypted_password,
                         email_confirmed_at, created_at, updated_at)
  values ('00000000-0000-0000-0000-000000000000', v_owner, 'authenticated', 'authenticated',
          'zz-v510-owner-' || substr(v_owner::text, 1, 8) || '@example.test', '', now(), now(), now());
  insert into public.staff(business_id, user_id, role, active) values (v_biz, v_owner, 'owner', true);
  insert into public.branches(id, business_id, name, is_default, active)
  values (v_branch, v_biz, 'V510 main', true, true);
  update public.business_workspace_controls_v94
     set approval_status='approved', version=version+1, decided_by=v_owner,
         decided_at=clock_timestamp(), decision_reason='v510', updated_at=clock_timestamp()
   where business_id = v_biz;
  insert into public.business_subscription_lifecycle_v94(business_id, workspace_paused)
  values (v_biz, false) on conflict (business_id) do update set workspace_paused=false;
  perform pg_temp.as_v512_user(v_owner);
  insert into public.loyalty_programs(business_id, active, loyalty_model, kind,
                                      configuration_status, stamp_target, stamp_per_cents,
                                      expiry_mode, expiry_days)
  values (v_biz, true, 'stamps', 'stamps', 'published', 5, 500, 'fixed', 90);
  -- The exact AhXiang shape: stamps ON, points row PRESENT but OFF.
  insert into public.business_programmes(business_id, kind, active, sort)
  values (v_biz,'points',false,1),(v_biz,'tiers',false,2),(v_biz,'stamps',true,3),(v_biz,'referral',false,4)
  on conflict (business_id, kind) do update set active = excluded.active;
  select id into v_stamp_spine from public.business_programmes where business_id=v_biz and kind='stamps';
  select id into v_points_spine from public.business_programmes where business_id=v_biz and kind='points';
  insert into public.clients(id, business_id, full_name, phone)
  values (v_client, v_biz, 'V510 Customer', '+65 9510 1001');

  -- ==========================================================================================
  -- 01  THE CORRECTION LANDS IN THE STAMPS POT
  -- ==========================================================================================
  v_bal := public.adjust_points(v_biz, v_client, 3, 'v512: credit visits missed before go-live');
  select coalesce(sum(pl.points),0)::integer into v_n
    from public.points_ledger pl
   where pl.business_id=v_biz and pl.client_id=v_client and pl.programme_id=v_stamp_spine;
  insert into _r values('01_lands_in_running_stamps_pot',
    case when v_n = 3 and v_bal = 3
      then 'PASS 3 stamps credited to the running stamp programme, balance returned 3'
      else 'FAIL stamps_pot=' || v_n || ' returned=' || coalesce(v_bal::text,'null') end);

  -- ==========================================================================================
  -- 02  THE DORMANT POINTS POT IS UNTOUCHED  (the defect, pinned)
  -- ==========================================================================================
  select coalesce(sum(pl.points),0)::integer into v_n
    from public.points_ledger pl
   where pl.business_id=v_biz and pl.client_id=v_client and pl.programme_id=v_points_spine;
  insert into _r values('02_dormant_points_pot_untouched',
    case when v_n = 0
      then 'PASS nothing was written to the switched-off points pot no customer surface reads'
      else 'FAIL ' || v_n || ' points landed in the dormant pot — the v510 defect is back' end);

  -- ==========================================================================================
  -- 03  NO INVENTED BATCH EXPIRY ON A STAMP
  -- ==========================================================================================
  select pb.expires_at into v_exp
    from public.points_batches pb
   where pb.business_id=v_biz and pb.client_id=v_client and pb.programme_id=v_stamp_spine
   order by pb.earned_at desc limit 1;
  insert into _r values('03_stamp_batch_has_no_points_expiry',
    case when v_exp is null
      then 'PASS the stamp batch carries no points-style expiry — its life is the card cycle'
      else 'FAIL stamp batch expires_at=' || v_exp::text end);

  -- ==========================================================================================
  -- 04  POINTS IS UNCHANGED (regression guard on the path that already worked)
  -- ==========================================================================================
  insert into public.businesses(id, name, slug, enabled_modules, points_mode)
  values (v_biz_p, 'V510 Points', v_slug_p, array['loyalty'], 'redeem');
  insert into public.staff(business_id, user_id, role, active) values (v_biz_p, v_owner, 'owner', true);
  insert into public.branches(business_id, name, is_default, active)
  values (v_biz_p, 'V510 P main', true, true);
  update public.business_workspace_controls_v94
     set approval_status='approved', version=version+1, decided_by=v_owner,
         decided_at=clock_timestamp(), decision_reason='v510', updated_at=clock_timestamp()
   where business_id = v_biz_p;
  insert into public.business_subscription_lifecycle_v94(business_id, workspace_paused)
  values (v_biz_p, false) on conflict (business_id) do update set workspace_paused=false;
  insert into public.loyalty_programs(business_id, active, loyalty_model, kind,
                                      configuration_status, earn_points_per_dollar,
                                      expiry_mode, expiry_days)
  values (v_biz_p, true, 'classic', 'points', 'published', 1, 'fixed', 90);
  insert into public.business_programmes(business_id, kind, active, sort)
  values (v_biz_p,'points',true,1),(v_biz_p,'tiers',false,2),(v_biz_p,'stamps',false,3),(v_biz_p,'referral',false,4)
  on conflict (business_id, kind) do update set active = excluded.active;
  select id into v_points_spine_p from public.business_programmes where business_id=v_biz_p and kind='points';
  insert into public.clients(id, business_id, full_name, phone)
  values (v_client_p, v_biz_p, 'V510 P Customer', '+65 9510 2002');

  v_bal := public.adjust_points(v_biz_p, v_client_p, 25, 'v512: points regression guard');
  select coalesce(sum(pl.points),0)::integer into v_n
    from public.points_ledger pl
   where pl.business_id=v_biz_p and pl.client_id=v_client_p and pl.programme_id=v_points_spine_p;
  select pb.expires_at into v_exp
    from public.points_batches pb
   where pb.business_id=v_biz_p and pb.client_id=v_client_p and pb.programme_id=v_points_spine_p
   order by pb.earned_at desc limit 1;
  insert into _r values('04_points_business_unchanged',
    case when v_n = 25 and v_bal = 25 and v_exp is not null
      then 'PASS a points business still credits its points pot, with the fixed-expiry rule applied'
      else 'FAIL pot=' || v_n || ' returned=' || coalesce(v_bal::text,'null')
           || ' expiry=' || coalesce(v_exp::text,'null') end);

  -- ==========================================================================================
  -- 05  NOTHING RUNNING -> REFUSE, do not fill a dormant pot
  -- ==========================================================================================
  update public.business_programmes set active=false where business_id=v_biz_p;
  begin
    perform public.adjust_points(v_biz_p, v_client_p, 5, 'v512: should refuse');
    insert into _r values('05_refuses_when_nothing_runs','FAIL the call succeeded with every programme off');
  exception when others then
    insert into _r values('05_refuses_when_nothing_runs',
      case when sqlerrm like '%no running points or stamp programme%'
        then 'PASS refused in plain words instead of crediting a pot nobody reads'
        else 'FAIL unexpected: [' || sqlstate || '] ' || sqlerrm end);
  end;

  -- ==========================================================================================
  -- 06  THE NEGATIVE PATH STILL PROVES ITSELF AGAINST THE RUNNING POT
  -- ==========================================================================================
  v_bal := public.adjust_points(v_biz, v_client, -2, 'v512: take two stamps back');
  select coalesce(sum(pl.points),0)::integer into v_n
    from public.points_ledger pl
   where pl.business_id=v_biz and pl.client_id=v_client and pl.programme_id=v_stamp_spine;
  insert into _r values('06_negative_drains_running_pot',
    case when v_n = 1 and v_bal = 1
      then 'PASS a negative correction drains the stamp pot''s own batches (3 - 2 = 1)'
      else 'FAIL pot=' || v_n || ' returned=' || coalesce(v_bal::text,'null') end);
  select coalesce(sum(pb.remaining),0)::integer into v_n
    from public.points_batches pb
   where pb.business_id=v_biz and pb.client_id=v_client and pb.programme_id=v_stamp_spine;
  insert into _r values('06_batches_reconcile',
    case when v_n = 1 then 'PASS the stamp batches reconcile to the ledger balance'
         else 'FAIL batches remaining=' || v_n end);
end $$;

select * from _r order by k;
rollback;
