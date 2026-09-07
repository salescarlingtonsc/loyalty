-- Rollback-only nestly_v813 acceptance: the customer's wallet and the staff's screen read the
-- same pot.
--
-- WHAT THE BUG WAS
--   nestly_v804 taught the five STAFF-side points readers to ask app.programme_balance_scope_v312
--   what a per-programme number MEANS for a firm right now — 'business_pot' sums every pot,
--   'programme_pot' sums the live one — and deliberately left the customer side for later. The
--   customer readers never asked: app.c45_base_actionable_wallet_card filtered on
--   app.live_balance_programme_v381 alone, app.customer_live_loyalty_v384 filtered on its own
--   spine selection alone, and both app.customer_live_loyalty_v384 and
--   public.customer_portal_capabilities reported a HARDCODED 'balance_scope':'programme_pot'.
--
--   Measured on production, read-only, inside a rolled-back transaction (2026-09-07), on a
--   customer whose ledger legitimately spans two pots — 15 live, 116 retired:
--
--     BEFORE  [programme_pot] staff=15  c45=15  v384=15  balance_scope=programme_pot
--     AFTER   [business_pot]  staff=131 c45=15  v384=15  balance_scope=programme_pot
--
--   One pending row in programme_pot_migrations is the only difference between the two lines.
--   In it the counter sees 131 and the customer sees 15, and the wallet still calls the firm
--   'programme_pot' while the server calls it 'business_pot'.
--
-- WHAT THIS SUITE PROVES, against a tenant it builds itself (live points pot 30, retired stamps
-- pot 70, so the two scopes give different, both-legitimate answers):
--    1. programme_pot scope — customer and staff agree on the LIVE pot: the wallet card, the
--       wallet balance, app.client_points_balance_v409 and the staff profile reader all say 30.
--    2. business_pot scope — customer and staff agree on EVERY pot: all four say 100. This is
--       the assertion that fails before the migration, at 30 vs 100.
--    3. business_pot scope, through the real customer session: public.customer_get_wallet()
--       reports 100 for that firm. The base reader being right is not the same claim as the RPC
--       the phone actually calls being right.
--    4. The scope key stops lying: the wallet's programme.balance_scope and every spine in
--       public.customer_portal_capabilities report 'business_pot' in business_pot scope and
--       'programme_pot' once the firm is back in programme_pot scope.
--    5. Sensitivity control — the fix is not "always sum everything". With the pot migration
--       gone, all four readers report the live pot only (30, not 100) again. Without this,
--       assertions 1-3 would pass on readers that had simply dropped the scope rule.
--    6. BOTH filters in each wallet reader carry the rule. The card reports
--       least(ledger, unexpired batches), so a fix applied to the ledger filter alone would be
--       clamped straight back to the live pot's 30 by the batch filter and would look exactly
--       like no fix at all. 100 is reachable only when both filters span every pot.
--    7. A customer with no ledger rows still reports 0, not null, in both scopes.
--
-- Run against production inside this transaction; every fixture row is rolled back:
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f db/tests/v813_wallet_readers_pot_scope.sql
-- Assertions are recorded as rows rather than raised, so one final SELECT reports the whole
-- suite. Any row whose outcome starts with FAIL is a failure.

begin;

create temp table v813_out(seq integer, step text, outcome text) on commit drop;
grant insert, select on v813_out to public;

create or replace function pg_temp.as_v813_system() returns void language plpgsql as $$
begin
  execute 'reset role';
  perform set_config('request.jwt.claim.sub','',true);
  perform set_config('request.jwt.claims','',true);
end
$$;
grant execute on function pg_temp.as_v813_system() to public;

create or replace function pg_temp.as_v813_user(p_uid uuid, p_role text default 'authenticated')
returns void language plpgsql as $$
begin
  execute 'reset role';
  perform set_config('request.jwt.claim.sub','',true);
  perform set_config('request.jwt.claims','{}',true);
  execute format('set local role %I',p_role);
  perform set_config('request.jwt.claim.sub',coalesce(p_uid::text,''),true);
  perform set_config('request.jwt.claims',
    json_build_object('sub',p_uid,'role',p_role)::text,true);
end
$$;
grant execute on function pg_temp.as_v813_user(uuid,text) to public;

-- One append to points_ledger through the single route app.loyalty_ledger_write_guard admits
-- from a system principal, plus its matching batch. The batch MUST match the ledger: a pot whose
-- ledger sum and batch remaining disagree is itself a business_pot trigger in
-- app.programme_balance_scope_v312, and would make the programme_pot half of this suite
-- unreachable.
create or replace function pg_temp.v813_seed_points(
  p_business uuid, p_client uuid, p_programme uuid, p_points integer
) returns void language plpgsql as $$
declare v_id uuid := gen_random_uuid();
begin
  perform app.acquire_loyalty_shared_v480(p_business);
  perform set_config('app.points_ledger_insert_id',v_id::text,true);
  perform set_config('app.points_ledger_write_scope','programme_pot_transfer',true);
  insert into public.points_ledger(id,business_id,client_id,entry_type,points,reference,actor,programme_id)
  values (v_id,p_business,p_client,'adjust',p_points,'v813 seed',null,p_programme);
  perform set_config('app.points_ledger_insert_id','',true);
  perform set_config('app.points_ledger_write_scope','',true);
  insert into public.points_batches(business_id,client_id,programme_id,earned,remaining)
  values (p_business,p_client,p_programme,p_points,p_points);
end
$$;
grant execute on function pg_temp.v813_seed_points(uuid,uuid,uuid,integer) to public;

do $v813_test$
declare
  biz uuid := gen_random_uuid();
  owner_uid uuid := gen_random_uuid();
  cust_uid uuid := gen_random_uuid();
  branch uuid := gen_random_uuid();
  identity_id uuid := gen_random_uuid();
  link_id uuid := gen_random_uuid();
  spine_points uuid;
  spine_stamps uuid;
  c_two uuid := gen_random_uuid();
  c_empty uuid := gen_random_uuid();
  migration uuid := gen_random_uuid();
  v_slug text;
  v_name text;
  v_industry text;
  v_currency text;
  v_modules text[];
  v_scope text;
  v_staff integer;
  v_profile integer;
  v_card integer;
  v_live integer;
  v_wallet jsonb;
  v_caps jsonb;
  v_key text;
  v_scopes text[];
  v_empty_card jsonb;
  v_empty_live jsonb;
begin
  perform pg_temp.as_v813_system();

  -- ============================================================ FIXTURE: a two-pot tenant
  insert into auth.users(instance_id,id,aud,role,email,encrypted_password,
                         email_confirmed_at,created_at,updated_at)
  values ('00000000-0000-0000-0000-000000000000',owner_uid,'authenticated','authenticated',
          'v813-owner-'||substr(owner_uid::text,1,8)||'@example.test','',now(),now(),now()),
         ('00000000-0000-0000-0000-000000000000',cust_uid,'authenticated','authenticated',
          'v813-cust-'||substr(cust_uid::text,1,8)||'@example.test','',now(),now(),now());

  perform set_config('app.v79_system_transition','on',true);
  insert into public.businesses(id,name,slug,industry,currency,enabled_modules,points_mode)
  values (biz,'V813 Two Pots','v813-'||substr(biz::text,1,8),'fnb','SGD',
          array['dashboard','clients','sales','services','till','loyalty'],'redeem');
  perform set_config('app.v79_system_transition','',true);

  update public.business_workspace_controls_v94
     set approval_status='approved', version=version+1, decided_by=owner_uid,
         decided_at=clock_timestamp(), decision_reason='v813 rollback fixture',
         updated_at=clock_timestamp()
   where business_id = biz;
  insert into public.business_subscription_lifecycle_v94(business_id,workspace_paused)
  values (biz,false)
  on conflict (business_id) do update set workspace_paused=false;
  insert into public.subscriptions(business_id,status,payment_status,current_period_end)
  values (biz,'active','paid',now()+interval '30 days')
  on conflict (business_id) do update
    set status='active', payment_status='paid', current_period_end=now()+interval '30 days';
  insert into app.platform_feature_flags(feature_key,enabled)
  values ('customer_wallet',true)
  on conflict (feature_key) do update set enabled = true;

  insert into public.staff(business_id,user_id,role,full_name,active,access_state)
  values (biz,owner_uid,'owner','V813 Owner',true,'approved');
  insert into public.branches(id,business_id,name,active,is_default)
  values (branch,biz,'V813 Main',true,true);

  select id into spine_points from public.business_programmes where business_id=biz and kind='points';
  select id into spine_stamps from public.business_programmes where business_id=biz and kind='stamps';
  update public.business_programmes set active=true  where id=spine_points;
  update public.business_programmes set active=false where id=spine_stamps;

  -- The wallet readers report a balance only for a firm whose loyalty programme is on and
  -- published; without this they are dark and every assertion below would compare 0 with 0.
  insert into public.loyalty_programs(business_id,active,loyalty_model,kind,configuration_status)
  values (biz,true,'points_tiers','points','published')
  on conflict (business_id) do update
    set active=true, loyalty_model='points_tiers', kind='points', configuration_status='published';

  insert into public.clients(id,business_id,full_name,phone) values
    (c_two,biz,'V813 Two Pots','+65 9813 0001'),
    (c_empty,biz,'V813 No Ledger','+65 9813 0002');

  -- A real two-pot history: 30 on the live points programme, 70 left on the retired stamps
  -- programme. points_ledger is append-only, so a firm that ever switched carries both tags —
  -- which is exactly why the two scopes give different, both-legitimate answers.
  perform pg_temp.v813_seed_points(biz,c_two,spine_points,30);
  perform pg_temp.v813_seed_points(biz,c_two,spine_stamps,70);

  -- The customer's own session: identity + verified link, the route-token recipe.
  insert into public.customer_identities(id,auth_user_id,status) values (identity_id,cust_uid,'active');
  perform set_config('app.customer_link_insert_id',link_id::text,true);
  insert into public.customer_links(id,business_id,identity_id,auth_user_id,client_id,state,
                                    verification_method,verified_at)
  values (link_id,biz,identity_id,cust_uid,c_two,'verified','phone_claim',now());
  perform set_config('app.customer_link_insert_id','',true);

  select slug,name,industry,currency,enabled_modules
    into v_slug,v_name,v_industry,v_currency,v_modules
    from public.businesses where id = biz;

  -- ------------------------------------------------------------------ 1. programme_pot scope
  v_scope := app.programme_balance_scope_v312(biz);
  if v_scope <> 'programme_pot' then
    raise exception 'FIXTURE: the fresh firm resolves to %, not programme_pot', v_scope;
  end if;
  v_staff := app.client_points_balance_v409(biz,c_two);
  v_card := (app.c45_base_actionable_wallet_card(
               biz,c_two,v_slug,v_name,v_industry,v_currency,v_modules,now())
             ->'loyalty'->>'balance')::integer;
  v_live := (app.customer_live_loyalty_v384(biz,c_two,v_modules,now())->>'balance')::integer;
  perform pg_temp.as_v813_user(owner_uid);
  v_profile := (public.staff_get_customer_actionable_loyalty_v145(biz,c_two,branch)
                ->>'points_balance')::integer;
  perform pg_temp.as_v813_system();
  if v_staff = 30 and v_profile = 30 and v_card = 30 and v_live = 30 then
    insert into v813_out values (1,'programme_pot scope: customer and staff both report the live pot (30)','PASS');
  else
    insert into v813_out values (1,'programme_pot scope: customer and staff both report the live pot (30)',
      format('FAIL - v409=%s v145=%s c45=%s v384=%s',v_staff,v_profile,v_card,v_live));
  end if;

  -- ------------------------------------------------------------------ 2. business_pot scope
  -- Put the firm in business_pot the way production does: a pot migration that is pending.
  insert into public.programme_pot_migrations(id,business_id,from_programme_id,to_programme_id,status)
  values (migration,biz,spine_stamps,spine_points,'pending');
  v_scope := app.programme_balance_scope_v312(biz);
  if v_scope <> 'business_pot' then
    raise exception 'FIXTURE: with a pending migration the firm resolves to %, not business_pot', v_scope;
  end if;

  v_staff := app.client_points_balance_v409(biz,c_two);
  v_card := (app.c45_base_actionable_wallet_card(
               biz,c_two,v_slug,v_name,v_industry,v_currency,v_modules,now())
             ->'loyalty'->>'balance')::integer;
  v_live := (app.customer_live_loyalty_v384(biz,c_two,v_modules,now())->>'balance')::integer;
  perform pg_temp.as_v813_user(owner_uid);
  v_profile := (public.staff_get_customer_actionable_loyalty_v145(biz,c_two,branch)
                ->>'points_balance')::integer;
  perform pg_temp.as_v813_system();
  if v_staff = 100 and v_profile = 100 and v_card = 100 and v_live = 100 then
    insert into v813_out values (2,'business_pot scope: the customer sees every pot, as staff do','PASS');
  else
    insert into v813_out values (2,'business_pot scope: the customer sees every pot, as staff do',
      format('FAIL - v409=%s v145=%s c45=%s v384=%s; the customer holds 100 '
             || '(30 live points pot + 70 retired stamps pot)',
             v_staff,v_profile,v_card,v_live));
  end if;

  -- ------------------------------------------------------------------ 6. both filters, not one
  -- The card answers least(ledger, unexpired batches). 100 can only come from a reader whose
  -- BATCH filter also spans every pot: with the batch site left pinned to the live programme the
  -- answer is least(100,30)=30, indistinguishable from no fix at all.
  if v_card = 100 and v_live = 100 then
    insert into v813_out values (6,'both the ledger and the batch filter carry the rule (100, not 30)','PASS');
  else
    insert into v813_out values (6,'both the ledger and the batch filter carry the rule (100, not 30)',
      format('FAIL - c45=%s v384=%s; 30 means a batch filter is still pinned to the live pot',
             v_card,v_live));
  end if;

  -- ------------------------------------------------------------------ 3. the real RPC
  perform pg_temp.as_v813_user(cust_uid);
  v_wallet := public.customer_get_wallet();
  v_live := (v_wallet->0->'loyalty'->>'balance')::integer;
  v_key  := v_wallet->0->'loyalty'->'programme'->>'balance_scope';
  v_caps := public.customer_portal_capabilities(v_slug);
  select array_agg(distinct programme->>'balance_scope')
    into v_scopes
    from pg_catalog.jsonb_array_elements(coalesce(v_caps->'programmes','[]'::jsonb)) as e(programme);
  perform pg_temp.as_v813_system();
  if v_live = 100 then
    insert into v813_out values (3,'the RPC the phone calls agrees too: customer_get_wallet() reports 100','PASS');
  else
    insert into v813_out values (3,'the RPC the phone calls agrees too: customer_get_wallet() reports 100',
      format('FAIL - customer_get_wallet() balance=%s',coalesce(v_live::text,'<null>')));
  end if;

  -- ------------------------------------------------------------------ 4. the scope key
  if v_key = 'business_pot' and v_scopes = array['business_pot'] then
    insert into v813_out values (4,'the scope key reports the server''s answer, not a literal','PASS');
  else
    insert into v813_out values (4,'the scope key reports the server''s answer, not a literal',
      format('FAIL - wallet says %s, portal capabilities say %s, the server says business_pot',
             coalesce(v_key,'<null>'),coalesce(v_scopes::text,'<null>')));
  end if;

  -- ------------------------------------------------------------------ 7. a customer with no ledger
  v_empty_card := app.c45_base_actionable_wallet_card(
                    biz,c_empty,v_slug,v_name,v_industry,v_currency,v_modules,now())->'loyalty';
  v_empty_live := app.customer_live_loyalty_v384(biz,c_empty,v_modules,now());
  if jsonb_typeof(v_empty_card->'balance') = 'number' and (v_empty_card->>'balance')::integer = 0
     and jsonb_typeof(v_empty_live->'balance') = 'number' and (v_empty_live->>'balance')::integer = 0 then
    insert into v813_out values (7,'a customer with no ledger rows still reports 0, not null','PASS');
  else
    insert into v813_out values (7,'a customer with no ledger rows still reports 0, not null',
      format('FAIL - c45=%s v384=%s',v_empty_card->'balance',v_empty_live->'balance'));
  end if;

  -- ------------------------------------------------------------------ 5. sensitivity control
  delete from public.programme_pot_migrations where id = migration;
  v_scope := app.programme_balance_scope_v312(biz);
  if v_scope <> 'programme_pot' then
    raise exception 'FIXTURE: without the migration the firm resolves to %, not programme_pot', v_scope;
  end if;
  v_staff := app.client_points_balance_v409(biz,c_two);
  v_card := (app.c45_base_actionable_wallet_card(
               biz,c_two,v_slug,v_name,v_industry,v_currency,v_modules,now())
             ->'loyalty'->>'balance')::integer;
  perform pg_temp.as_v813_user(cust_uid);
  v_wallet := public.customer_get_wallet();
  v_live := (v_wallet->0->'loyalty'->>'balance')::integer;
  v_key  := v_wallet->0->'loyalty'->'programme'->>'balance_scope';
  v_caps := public.customer_portal_capabilities(v_slug);
  select array_agg(distinct programme->>'balance_scope')
    into v_scopes
    from pg_catalog.jsonb_array_elements(coalesce(v_caps->'programmes','[]'::jsonb)) as e(programme);
  perform pg_temp.as_v813_user(owner_uid);
  v_profile := (public.staff_get_customer_actionable_loyalty_v145(biz,c_two,branch)
                ->>'points_balance')::integer;
  perform pg_temp.as_v813_system();
  if v_staff = 30 and v_profile = 30 and v_card = 30 and v_live = 30
     and v_key = 'programme_pot' and v_scopes = array['programme_pot'] then
    insert into v813_out values (5,'sensitivity: back in programme_pot scope every reader says 30 again','PASS');
  else
    insert into v813_out values (5,'sensitivity: back in programme_pot scope every reader says 30 again',
      format('FAIL - v409=%s v145=%s c45=%s wallet=%s key=%s caps=%s; the scope rule may have been '
             || 'dropped rather than corrected',
             v_staff,v_profile,v_card,coalesce(v_live::text,'<null>'),
             coalesce(v_key,'<null>'),coalesce(v_scopes::text,'<null>')));
  end if;
end
$v813_test$;

select seq, step, outcome from v813_out order by seq;

do $v813_gate$
declare v_failed integer;
begin
  select count(*) into v_failed from v813_out where outcome like 'FAIL%';
  if v_failed > 0 then
    raise exception 'nestly_v813 acceptance: % assertion(s) failed', v_failed using errcode = 'XX001';
  end if;
  if (select count(*) from v813_out) <> 7 then
    raise exception 'nestly_v813 acceptance: expected 7 assertions, recorded %',
      (select count(*) from v813_out) using errcode = 'XX001';
  end if;
end
$v813_gate$;

rollback;
