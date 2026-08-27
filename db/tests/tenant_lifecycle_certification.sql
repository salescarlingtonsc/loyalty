-- ============================================================================================
-- NEW-TENANT LIFECYCLE CERTIFICATION — rollback-only, against production, at the real RPC level.
--
-- Run: supabase db query --linked -f db/tests/tenant_lifecycle_certification.sql
--      (the Supabase CLI is linked from the repo root; pass the absolute path from elsewhere)
--
-- WHAT THIS IS
--   This suite IS the new-tenant certification the platform's acceptance criteria reference.
--   It walks ONE brand-new business through its whole loyalty life — birth, points, a customer,
--   a sale, the wallet, the catalogue, unrelated edits, a switch to stamps, a completed card,
--   loyalty off, loyalty back on — calling the SAME server functions the product calls, in the
--   same order the product calls them, against the live production schema. Everything runs
--   inside begin;…rollback; so nothing is committed; step 20 proves that from outside the
--   transaction.
--
-- SEVERITY OF A FAIL
--   Any row in _r whose value starts with 'FAIL' is a release blocker. A FAIL here means a
--   business that signs up today cannot complete the journey the product promises — it is not a
--   test-fixture problem. Steps 09/11/15 (Invariant F) and 13 (Invariant G) and 16 (Invariant C)
--   are the highest severity: they catch silent cross-contamination between a tenant's
--   programmes, which no single-screen test can see.
--
-- COVERAGE LEVEL PER STEP (honest accounting — see the per-step notes in the body)
--   RPC LEVEL (the real writer the product calls):
--     01 birth (mirrors platform_decide_business_application_v105's own body, incl. the guarded
--        onboarding-preset insert and the v565 ensure fallback)
--     02 business_set_earning_rule_v359 / create_loyalty_config_draft /
--        save_loyalty_reward_draft / publish_loyalty_config / set_programmes_v314
--     04 record_sale_by_phone (the till's own writer -> record_quick_sale -> the earn triggers)
--     09/15 create_loyalty_config_draft + publish_loyalty_config
--     10 business_set_welcome_offer_v215      11/17 business_set_social_links_v418
--     12 set_programmes_v314 + business_set_stamp_card_length_v414 + business_set_earning_rule_v359
--     18b-18e the return leg, stamps -> points, through the same switchboard
--     14c app.redeem_reward_core             16/18 set_programmes_v314 + publish_loyalty_config
--     19 business_set_loyalty_model_v353 and the same writers again
--   SERVER-HALF LEVEL (the screen is browser-only; this asserts the data the screen paints from):
--     03 customer identity/link minting — the real route is the Turnstile-gated edge gateway,
--        which cannot be called from SQL; the rows it writes are minted here exactly as the
--        v31 link-immutability guard requires (app.customer_link_insert_id).
--     05 points_ledger        06 app.c45_base_actionable_wallet_card (hero card)
--     07 app.customer_live_loyalty_v384 (wallet)
--     08 public.customer_get_reward_catalog + app.reward_availability_v432 +
--        public.customer_get_business_presentation_v95, all called AS THE CUSTOMER
--     13 points_ledger pot separation        14a/14b app.stamp_progress_v323 + the catalogue
--     20 leak check
--   NOT COVERED HERE, deliberately: the QR redemption intent/scan handshake
--     (customer_create_redemption_intent + the merchant scan) — two-party, browser+camera, and
--     already certified by db/tests/v89_customer_qr_redemption_concurrency.sh. Step 14c
--     exercises app.redeem_reward_core, which is the minting core both paths converge on.
--
-- THE INVARIANTS THIS SUITE EXISTS TO DEFEND
--   A/F  An edit to one programme, or to something that is not loyalty at all, changes NOTHING
--        about the rest of the loyalty state. Steps 09, 11 and 15 hash the whole state before
--        and after and compare.
--   G    Pots do not leak. Earning stamps must not touch the points pot (step 13).
--   C    "Off" means off everywhere at once — business row, hero, wallet, catalogue,
--        presentation and the redemption path all agree (step 16).
--   Two-path equivalence: a tenant configured through Settings first and a tenant configured
--        through Grow first end in the SAME runtime state (step 19). Historical metadata
--        (version counts, recommendation_source) may differ; runtime state may not.
--
-- TWO THINGS THE FIXTURE HAD TO LEARN, WORTH KNOWING BEFORE EDITING THIS FILE
--   1. One transaction has one now(). Every version published here therefore shares a
--      published_at, and app.stamp_cycle_version_v416 picks a customer's card by "the newest
--      version published at or before their first stamp" — a tie it cannot break. Left alone, a
--      completed card pinned an arbitrary version that had no gift in it and the catalogue came
--      back empty. pg_temp.lc_age() ages superseded versions by a day after each publish, which
--      is what real elapsed time would have done. Call it after every publish you add.
--   2. A full stamp card does not sit "ready". The engine closes it into a public.stamp_cycles
--      row the moment the last stamp lands, and the gift is claimed against that CLOSED cycle
--      (app.reward_availability_v432's second arm). Step 14a accepts either shape and says which
--      one it saw.
--   Also: a stamp card with no gift at its last stamp is not publishable —
--   app.stamp_config_edit_commit_v433 pends it with blockers. So both paths in step 19
--   necessarily finish through the same draft->publish; the SEQUENCE differs, the END STATE
--   must not, and that is what 19a-19d measure.
--
-- FIXTURE NAMESPACE: every id created here is 1abe0e00-0000-4000-8000-… ("lifecycle").
-- ============================================================================================

begin;

create temp table _r(check_id text, value text) on commit drop;

-- One count of everything this suite can create, by uuid namespace. Used twice: before any
-- fixture exists (part one) and after the rollback (part two).
create function pg_temp.lc_leak_count() returns bigint language sql stable as $fn$
  select (select count(*) from public.businesses            where id::text          like '1abe0e00-%')
       + (select count(*) from public.clients               where id::text          like '1abe0e00-%')
       + (select count(*) from public.staff                 where id::text          like '1abe0e00-%')
       + (select count(*) from public.branches              where id::text          like '1abe0e00-%')
       + (select count(*) from public.customer_links        where id::text          like '1abe0e00-%')
       + (select count(*) from public.customer_identities   where id::text          like '1abe0e00-%')
       + (select count(*) from public.birthday_programs     where id::text          like '1abe0e00-%')
       + (select count(*) from auth.users                   where id::text          like '1abe0e00-%')
       + (select count(*) from public.points_ledger         where business_id::text like '1abe0e00-%')
       + (select count(*) from public.sales                 where business_id::text like '1abe0e00-%')
       + (select count(*) from public.loyalty_programs      where business_id::text like '1abe0e00-%')
       + (select count(*) from public.firm_config_versions  where business_id::text like '1abe0e00-%')
$fn$;

-- ============ 20 leak, part one: nothing from an EARLIER run of this suite is still here =====
-- Measured before a single fixture row exists, so a non-zero count can only mean a previous run
-- committed something it should not have. Part two runs after the rollback, at the foot of the
-- file, and raises loudly rather than returning a row (a result set there would hide this report).
do $leak$
declare v_total bigint;
begin
  select pg_temp.lc_leak_count() into v_total;
  insert into _r values ('20 leak: no fixture from any earlier run survives',
    case when v_total = 0 then 'OK' else 'FAIL: '||v_total||' row(s) left over from a previous run' end);
end $leak$;

-- --------------------------------------------------------------------------------------------
-- helpers
-- --------------------------------------------------------------------------------------------

-- Impersonate a real auth user, the way PostgREST does, so every SECURITY DEFINER RPC that
-- reads auth.uid() runs as that person. NOTHING is stubbed in this suite: the owner gates
-- (app.is_salon_owner / app.c45_owner_loyalty_write / app.has_perm) are satisfied by a REAL
-- approved owner staff row, exactly as they are in production.
create function pg_temp.lc_as(p_uid uuid) returns void language plpgsql as $fn$
begin
  if p_uid is null then
    perform set_config('request.jwt.claims','',true);
    perform set_config('request.jwt.claim.sub','',true);
  else
    perform set_config('request.jwt.claims',
      jsonb_build_object('sub',p_uid,'role','authenticated','aud','authenticated')::text,true);
    perform set_config('request.jwt.claim.sub',p_uid::text,true);
  end if;
end $fn$;

-- The whole loyalty runtime state of a business in one string: the live programme row, the
-- spine's active-set, and every customer pot balance. Invariants A/F/G are "this did not move".
create function pg_temp.lc_hash(p_biz uuid) returns text language sql stable as $fn$
  select md5(
    coalesce((select lp.kind||'|'||lp.loyalty_model||'|'||lp.active::text
                   ||'|'||coalesce(lp.earn_points_per_dollar::text,'-')
                   ||'|'||coalesce(lp.redeem_points::text,'-')
                   ||'|'||coalesce(lp.reward_credit_cents::text,'-')
                   ||'|'||coalesce(lp.tier_basis,'-')
                   ||'|'||coalesce(lp.expiry_mode,'-')
                   ||'|'||coalesce(lp.expiry_days::text,'-')
                   ||'|'||coalesce(lp.stamp_target::text,'-')
                   ||'|'||coalesce(lp.stamp_per_cents::text,'-')
                   ||'|'||coalesce(lp.stamp_validity_days::text,'-')
                   ||'|'||coalesce(lp.stamp_reward_expiry_days::text,'-')
                   ||'|'||coalesce(lp.configuration_status,'-')
                from public.loyalty_programs lp where lp.business_id=p_biz),'NOROW')
    ||'#'||coalesce((select string_agg(sp.kind||'='||sp.active::text,',' order by sp.kind)
                       from public.business_programmes sp where sp.business_id=p_biz),'-')
    ||'#'||coalesce((select string_agg(pot.pid||':'||pot.bal,',' order by pot.pid) from (
                       select coalesce(pl.programme_id::text,'null') as pid, sum(pl.points)::text as bal
                         from public.points_ledger pl where pl.business_id=p_biz
                        group by 1) pot),'-')
  )
$fn$;

-- The runtime half of the programme row — the fields two identically-configured tenants must
-- agree on. business_id, recommendation_source, current_config_version_id and the timestamps
-- are deliberately excluded: those are historical metadata.
create function pg_temp.lc_runtime(p_biz uuid) returns text language sql stable as $fn$
  select coalesce((select lp.kind||'|'||lp.loyalty_model||'|'||lp.active::text
                 ||'|'||coalesce(lp.earn_points_per_dollar::text,'-')
                 ||'|'||coalesce(lp.redeem_points::text,'-')
                 ||'|'||coalesce(lp.reward_credit_cents::text,'-')
                 ||'|'||coalesce(lp.tier_basis,'-')
                 ||'|'||coalesce(lp.expiry_mode,'-')
                 ||'|'||coalesce(lp.expiry_days::text,'-')
                 ||'|'||coalesce(lp.stamp_target::text,'-')
                 ||'|'||coalesce(lp.stamp_per_cents::text,'-')
                 ||'|'||coalesce(lp.stamp_validity_days::text,'-')
                 ||'|'||coalesce(lp.stamp_reward_expiry_days::text,'-')
              from public.loyalty_programs lp where lp.business_id=p_biz),'NOROW')
$fn$;

-- ONE TRANSACTION HAS ONE now(). Every version this suite publishes therefore carries the SAME
-- published_at, and app.stamp_cycle_version_v416 resolves a customer's card by "the newest
-- version published at or before the first stamp landed" — a tie it cannot break, so it pinned
-- an arbitrary one and the customer's completed card pointed at a configuration with no gift in
-- it. A real tenant configures over minutes. This ages every superseded version by a day after
-- each publish so the ordering the engine relies on exists inside the transaction too. It is a
-- clock compensation, not a behaviour change: only published_at on already-superseded rows moves.
create function pg_temp.lc_age(p_biz uuid) returns void language plpgsql as $fn$
begin
  update public.firm_config_versions fcv
     set published_at = fcv.published_at - interval '1 day'
   where fcv.business_id = p_biz
     and fcv.published_at is not null
     and fcv.id is distinct from
         (select b.active_config_version_id from public.businesses b where b.id = p_biz);
end $fn$;

-- Birth a tenant EXACTLY the way public.platform_decide_business_application_v105 shapes one:
-- the sector bundle's modules, an approved owner staff row, a default branch, staff_branches,
-- the workspace control flipped to approved, then the owner-guarded onboarding-preset insert
-- with the nestly_v565 ensure fallback behind it. No shortcut, no stub.
create function pg_temp.lc_birth(p_biz uuid, p_owner uuid, p_staff uuid, p_branch uuid,
                                 p_name text, p_slug text, p_email text)
returns void language plpgsql as $fn$
declare v_mods text[];
begin
  insert into auth.users(instance_id,id,aud,role,email,encrypted_password,
                         email_confirmed_at,created_at,updated_at)
  values ('00000000-0000-0000-0000-000000000000',p_owner,'authenticated','authenticated',
          p_email,'',now(),now(),now());
  select bundle.modules into v_mods from public.sector_bundle_versions bundle
   where bundle.sector_key='fnb' and bundle.status='published' limit 1;
  insert into public.businesses(id,name,slug,industry,enabled_modules)
  values (p_biz,p_name,p_slug,'fnb',
          coalesce(v_mods,array['dashboard','clients','sales','loyalty','retention']));
  insert into public.staff(id,business_id,user_id,role,full_name,active)
  values (p_staff,p_biz,p_owner,'owner',p_name||' owner',true);
  insert into public.branches(id,business_id,name,is_default,active)
  values (p_branch,p_biz,p_name,true,true);
  insert into public.staff_branches(business_id,staff_id,branch_id)
  values (p_biz,p_staff,p_branch);
  update public.business_workspace_controls_v94
     set approval_status='approved',version=version+1,decided_at=now(),updated_at=now()
   where business_id=p_biz;
  perform pg_temp.lc_as(p_owner);
  if app.c45_owner_loyalty_write(p_biz) then
    insert into public.loyalty_programs(business_id,kind,earn_points_per_dollar,redeem_points,
      reward_credit_cents,active,loyalty_model,configuration_status,recommendation_source)
    values (p_biz,'points',1,800,2000,false,'classic','draft','onboarding_preset')
    on conflict(business_id) do nothing;
  end if;
  if not exists(select 1 from public.loyalty_programs lp where lp.business_id=p_biz) then
    perform app.ensure_loyalty_program_row(p_biz,'onboarding_preset');
  end if;
  perform pg_temp.lc_as(null);
end $fn$;

-- Mint a verified customer: auth user, customer identity, client row, verified link. The real
-- route is the Turnstile-gated edge gateway (unreachable from SQL); these are the rows it
-- writes, announced to app.v31_link_immutable_guard the same way the claim route announces them.
create function pg_temp.lc_customer(p_biz uuid, p_user uuid, p_ident uuid, p_link uuid,
                                    p_client uuid, p_name text, p_phone text, p_email text)
returns void language plpgsql as $fn$
begin
  insert into auth.users(instance_id,id,aud,role,email,encrypted_password,
                         email_confirmed_at,created_at,updated_at)
  values ('00000000-0000-0000-0000-000000000000',p_user,'authenticated','authenticated',
          p_email,'',now(),now(),now());
  insert into public.customer_identities(id,auth_user_id,status) values (p_ident,p_user,'active');
  insert into public.clients(id,business_id,full_name,phone)
  values (p_client,p_biz,p_name,p_phone);
  perform set_config('app.customer_link_insert_id',p_link::text,true);
  insert into public.customer_links(id,business_id,identity_id,auth_user_id,client_id,state,
                                    verification_method,verified_at)
  values (p_link,p_biz,p_ident,p_user,p_client,'verified','qr_join',now());
  perform set_config('app.customer_link_insert_id','',true);
end $fn$;

-- ============ 01 birth =======================================================================
do $s01$
declare
  v_biz uuid := '1abe0e00-0000-4000-8000-000000000001';
  v_row public.loyalty_programs%rowtype;
  v_ver_no integer; v_ver_status text; v_active uuid; v_spine text;
begin
  perform pg_temp.lc_birth(v_biz,'1abe0e00-0000-4000-8000-0000000000a1',
    '1abe0e00-0000-4000-8000-0000000000a2','1abe0e00-0000-4000-8000-0000000000a3',
    'Lifecycle Cert A','lifecycle-cert-a-rolled-back','lifecycle-cert-a@example.test');

  select * into v_row from public.loyalty_programs where business_id=v_biz;
  select fcv.version_no, fcv.status into v_ver_no, v_ver_status
    from public.firm_config_versions fcv where fcv.business_id=v_biz order by fcv.version_no limit 1;
  select b.active_config_version_id into v_active from public.businesses b where b.id=v_biz;
  select string_agg(sp.kind||'='||sp.active::text,',' order by sp.kind) into v_spine
    from public.business_programmes sp where sp.business_id=v_biz;

  insert into _r values ('01 birth: a new tenant is born whole, with no manual repair',
    case when v_row.business_id is null then 'FAIL: no loyalty_programs row'
         when v_row.kind is distinct from 'points' then 'FAIL: kind='||coalesce(v_row.kind,'NULL')
         when v_row.loyalty_model is distinct from 'classic' then 'FAIL: model='||coalesce(v_row.loyalty_model,'NULL')
         when v_row.redeem_points is distinct from 800 or v_row.reward_credit_cents is distinct from 2000
           then 'FAIL: the onboarding preset is not intact'
         when v_row.active then 'FAIL: a newborn tenant must not be running loyalty yet'
         when v_ver_no is distinct from 1 then 'FAIL: first version_no='||coalesce(v_ver_no::text,'NONE')
         when v_ver_status is distinct from 'published' then 'FAIL: version 1 is '||coalesce(v_ver_status,'NULL')
         when v_active is null then 'FAIL: no active_config_version_id'
         when not exists(select 1 from public.loyalty_program_versions lpv
                          where lpv.business_id=v_biz and lpv.config_version_id=v_active)
           then 'FAIL: version 1 carries no typed loyalty row'
         when v_spine is distinct from 'points=false,referral=false,stamps=false,tiers=false'
           then 'FAIL: spine='||coalesce(v_spine,'NULL')
         else 'OK' end);
exception when others then
  insert into _r values ('01 birth: a new tenant is born whole, with no manual repair','FAIL: '||sqlerrm);
end $s01$;

-- ============ 02 configure points ============================================================
do $s02$
declare
  v_biz uuid := '1abe0e00-0000-4000-8000-000000000001';
  v_owner uuid := '1abe0e00-0000-4000-8000-0000000000a1';
  v_draft json; v_ver uuid; v_saved json; v_reward uuid;
  v_row public.loyalty_programs%rowtype; v_live uuid; v_points uuid;
begin
  perform pg_temp.lc_as(v_owner);
  perform public.business_set_earning_rule_v359(v_biz, 2, null, null, null, null, null);
  perform public.set_programmes_v314(v_biz, jsonb_build_object('points',true),
                                     '1abe0e00-0000-4000-8000-0000000000c1');
  v_draft := public.create_loyalty_config_draft(v_biz);
  v_ver := (v_draft->>'version_id')::uuid;
  v_saved := public.save_loyalty_reward_draft(v_ver, null, jsonb_build_object(
    'internal_name','LC free kopi','customer_name','Free kopi','fulfillment_kind','manual_item',
    'cost_points',10,'credit_cents',0,'estimated_cost_cents',0,'active',true,'sort',0));
  v_reward := (v_saved->>'reward_id')::uuid;
  perform public.publish_loyalty_config(v_ver);
  perform pg_temp.lc_age(v_biz);
  perform pg_temp.lc_as(null);

  select * into v_row from public.loyalty_programs where business_id=v_biz;
  select b.active_config_version_id into v_live from public.businesses b where b.id=v_biz;
  select sp.id into v_points from public.business_programmes sp
   where sp.business_id=v_biz and sp.kind='points';

  insert into _r values ('02 points: earn rate, one gift, published, programme on',
    case when v_row.earn_points_per_dollar is distinct from 2
           then 'FAIL: earn rate='||coalesce(v_row.earn_points_per_dollar::text,'NULL')
         when not v_row.active then 'FAIL: the programme is not running'
         when v_row.loyalty_model is distinct from 'classic' then 'FAIL: model='||coalesce(v_row.loyalty_model,'NULL')
         when v_live is distinct from v_ver then 'FAIL: publish did not move the live pointer'
         when not exists(select 1 from public.loyalty_reward_versions rv
                          where rv.config_version_id=v_live and rv.reward_id=v_reward
                            and rv.active and rv.cost_points=10 and rv.programme_id=v_points)
           then 'FAIL: the gift is not live on the points spine at 10 points'
         when not exists(select 1 from public.loyalty_rewards r
                          where r.id=v_reward and r.active and not r.paused)
           then 'FAIL: publish did not bring the live gift row into service'
         else 'OK' end);
exception when others then
  perform pg_temp.lc_as(null);
  insert into _r values ('02 points: earn rate, one gift, published, programme on','FAIL: '||sqlerrm);
end $s02$;

-- ============ 03 customer ====================================================================
do $s03$
declare
  v_biz uuid := '1abe0e00-0000-4000-8000-000000000001';
  v_ctx integer;
begin
  perform pg_temp.lc_customer(v_biz,'1abe0e00-0000-4000-8000-000000000012',
    '1abe0e00-0000-4000-8000-000000000013','1abe0e00-0000-4000-8000-000000000014',
    '1abe0e00-0000-4000-8000-000000000011','LC customer one','81860001',
    'lifecycle-cert-c1@example.test');

  perform pg_temp.lc_as('1abe0e00-0000-4000-8000-000000000012');
  select count(*) into v_ctx from app.v32_customer_wallet_context('lifecycle-cert-a-rolled-back');
  perform pg_temp.lc_as(null);

  insert into _r values ('03 customer: a verified member exists and resolves to this tenant',
    case when v_ctx = 1 then 'OK'
         else 'FAIL: the wallet context resolved '||v_ctx||' row(s) for the new member' end);
exception when others then
  perform pg_temp.lc_as(null);
  insert into _r values ('03 customer: a verified member exists and resolves to this tenant','FAIL: '||sqlerrm);
end $s03$;

-- ============ 04 sale (the till's own writer) ================================================
do $s04$
declare
  v_biz uuid := '1abe0e00-0000-4000-8000-000000000001';
  v_res json;
begin
  perform pg_temp.lc_as('1abe0e00-0000-4000-8000-0000000000a1');
  v_res := public.record_sale_by_phone(v_biz,'81860001',500,'quick_sale','lifecycle cert sale 1',
             '1abe0e00-0000-4000-8000-0000000000a2','lifecycle-cert-sale-1',
             '1abe0e00-0000-4000-8000-0000000000a3','cash');
  perform pg_temp.lc_as(null);
  insert into _r values ('04 sale: SGD 5 recorded through the till writer',
    case when v_res->>'status' <> 'ok' then 'FAIL: status='||coalesce(v_res->>'status','NULL')
         when (v_res->>'points_earned')::integer <> 10
           then 'FAIL: points_earned='||coalesce(v_res->>'points_earned','NULL')||' (expected 10)'
         else 'OK' end);
exception when others then
  perform pg_temp.lc_as(null);
  insert into _r values ('04 sale: SGD 5 recorded through the till writer','FAIL: '||sqlerrm);
end $s04$;

-- ============ 05 ledger ======================================================================
do $s05$
declare
  v_biz uuid := '1abe0e00-0000-4000-8000-000000000001';
  v_client uuid := '1abe0e00-0000-4000-8000-000000000011';
  v_points uuid; v_in_pot integer; v_elsewhere integer;
begin
  select sp.id into v_points from public.business_programmes sp
   where sp.business_id=v_biz and sp.kind='points';
  select coalesce(sum(pl.points),0) into v_in_pot from public.points_ledger pl
   where pl.business_id=v_biz and pl.client_id=v_client and pl.programme_id=v_points;
  select coalesce(sum(pl.points),0) into v_elsewhere from public.points_ledger pl
   where pl.business_id=v_biz and pl.client_id=v_client
     and pl.programme_id is distinct from v_points;
  insert into _r values ('05 ledger: +10 landed in the POINTS pot and nowhere else',
    case when v_in_pot <> 10 then 'FAIL: points pot holds '||v_in_pot
         when v_elsewhere <> 0 then 'FAIL: '||v_elsewhere||' unit(s) landed outside the points pot'
         else 'OK' end);
exception when others then
  insert into _r values ('05 ledger: +10 landed in the POINTS pot and nowhere else','FAIL: '||sqlerrm);
end $s05$;

-- ============ 06 hero card ===================================================================
do $s06$
declare
  v_biz uuid := '1abe0e00-0000-4000-8000-000000000001';
  v_card jsonb; v_b public.businesses%rowtype;
begin
  select * into v_b from public.businesses where id=v_biz;
  v_card := app.c45_base_actionable_wallet_card(v_biz,'1abe0e00-0000-4000-8000-000000000011',
    v_b.slug, v_b.name, v_b.industry, 'SGD', v_b.enabled_modules, now());
  insert into _r values ('06 hero: the wallet card reports loyalty on with a balance of 10',
    case when (v_card->'loyalty'->>'enabled')::boolean is not true then 'FAIL: hero says loyalty is off'
         when (v_card->'loyalty'->>'balance')::integer <> 10
           then 'FAIL: hero balance='||coalesce(v_card->'loyalty'->>'balance','NULL')
         when v_card->'loyalty'->>'unit' <> 'points'
           then 'FAIL: hero unit='||coalesce(v_card->'loyalty'->>'unit','NULL')
         else 'OK' end);
exception when others then
  insert into _r values ('06 hero: the wallet card reports loyalty on with a balance of 10','FAIL: '||sqlerrm);
end $s06$;

-- ============ 07 wallet ======================================================================
do $s07$
declare
  v_biz uuid := '1abe0e00-0000-4000-8000-000000000001';
  v_live jsonb; v_mods text[]; v_points uuid;
begin
  select enabled_modules into v_mods from public.businesses where id=v_biz;
  select sp.id into v_points from public.business_programmes sp
   where sp.business_id=v_biz and sp.kind='points';
  v_live := app.customer_live_loyalty_v384(v_biz,'1abe0e00-0000-4000-8000-000000000011',v_mods,now());
  insert into _r values ('07 wallet: the live reader agrees with the hero, on the same pot',
    case when (v_live->>'enabled')::boolean is not true then 'FAIL: wallet says loyalty is off'
         when (v_live->>'balance')::integer <> 10
           then 'FAIL: wallet balance='||coalesce(v_live->>'balance','NULL')
         when (v_live->'programme'->>'id')::uuid is distinct from v_points
           then 'FAIL: wallet is reading a different programme pot'
         when v_live->>'unit' <> 'points' then 'FAIL: unit='||coalesce(v_live->>'unit','NULL')
         else 'OK' end);
exception when others then
  insert into _r values ('07 wallet: the live reader agrees with the hero, on the same pot','FAIL: '||sqlerrm);
end $s07$;

-- ============ 08 catalogue ===================================================================
do $s08$
declare
  v_biz uuid := '1abe0e00-0000-4000-8000-000000000001';
  v_client uuid := '1abe0e00-0000-4000-8000-000000000011';
  v_cat jsonb; v_pres jsonb; v_core_names text; v_cat_names text; v_pres_names text;
  v_core_remaining text; v_cat_quantity text;
begin
  select string_agg(core.customer_name,',' order by core.customer_name),
         coalesce(string_agg(core.remaining_units::text||'/'||core.availability||'/'||core.quantity::text,
                             ',' order by core.customer_name),'-')
    into v_core_names, v_core_remaining
    from app.reward_availability_v432(v_biz,v_client,now()) core
   where core.availability not in ('not_started','ended');

  perform pg_temp.lc_as('1abe0e00-0000-4000-8000-000000000012');
  v_cat := public.customer_get_reward_catalog('lifecycle-cert-a-rolled-back');
  v_pres := public.customer_get_business_presentation_v95(v_biz);
  perform pg_temp.lc_as(null);

  select string_agg(item->>'customer_name',',' order by item->>'customer_name')
    into v_cat_names from jsonb_array_elements(v_cat->'rewards') item;
  select coalesce(string_agg((item->>'availability')||'/'||(item->>'quantity'),',' order by item->>'customer_name'),'-')
    into v_cat_quantity from jsonb_array_elements(v_cat->'rewards') item;
  select string_agg(item->>'name',',' order by item->>'name')
    into v_pres_names from jsonb_array_elements(v_pres->'catalogue'->'rewards') item;

  insert into _r values ('08 catalogue: one gift, and every customer reader lists the same one',
    case when coalesce(v_core_names,'') <> 'Free kopi'
           then 'FAIL: the availability core lists ['||coalesce(v_core_names,'')||']'
         when coalesce(v_cat_names,'') <> 'Free kopi'
           then 'FAIL: the reward catalogue lists ['||coalesce(v_cat_names,'')||']'
         when coalesce(v_pres_names,'') <> 'Free kopi'
           then 'FAIL: the presentation lists ['||coalesce(v_pres_names,'')||']'
         -- remaining_units is "how many more units before this gift is affordable", not stock:
         -- 10 points against a 10-point gift is 0 remaining and one claimable arm.
         when v_core_remaining <> '0/available_at_counter/1'
           then 'FAIL: the core says '||v_core_remaining||', expected 0/available_at_counter/1'
         when v_cat_quantity <> 'available_at_counter/1'
           then 'FAIL: the catalogue says '||v_cat_quantity||', the core says '||v_core_remaining
         else 'OK' end);
exception when others then
  perform pg_temp.lc_as(null);
  insert into _r values ('08 catalogue: one gift, and every customer reader lists the same one','FAIL: '||sqlerrm);
end $s08$;

-- ============ 09 an unrelated programme is edited and published (Invariant F) ================
do $s09$
declare
  v_biz uuid := '1abe0e00-0000-4000-8000-000000000001';
  v_owner uuid := '1abe0e00-0000-4000-8000-0000000000a1';
  v_before text; v_after text; v_draft json; v_ver uuid; v_prog uuid;
begin
  v_before := pg_temp.lc_hash(v_biz);
  perform pg_temp.lc_as(v_owner);
  v_draft := public.create_loyalty_config_draft(v_biz);
  v_ver := (v_draft->>'version_id')::uuid;
  insert into public.birthday_programs(id,business_id)
  values ('1abe0e00-0000-4000-8000-000000000041',v_biz)
  on conflict (id) do nothing;
  select bp.id into v_prog from public.birthday_programs bp where bp.business_id=v_biz limit 1;
  insert into public.birthday_program_versions(program_id,config_version_id,business_id,active,
    customer_label,customer_description,customer_terms,fulfillment_kind,manual_item,
    window_days_before,window_days_after,window_mode,sort)
  values (v_prog,v_ver,v_biz,true,'Birthday treat','A slice on us','One per birthday',
          'free_item','Cake slice',7,7,'days',0);
  perform public.publish_loyalty_config(v_ver);
  perform pg_temp.lc_age(v_biz);
  perform pg_temp.lc_as(null);
  v_after := pg_temp.lc_hash(v_biz);

  insert into _r values ('09 invariant F: publishing a birthday edit moves no loyalty state',
    case when not exists(select 1 from public.birthday_program_versions bpv
                          where bpv.business_id=v_biz and bpv.config_version_id=v_ver)
           then 'FAIL: the birthday edit did not survive its own publish'
         when v_before = v_after then 'OK'
         else 'FAIL: loyalty state changed '||v_before||' -> '||v_after end);
exception when others then
  perform pg_temp.lc_as(null);
  insert into _r values ('09 invariant F: publishing a birthday edit moves no loyalty state','FAIL: '||sqlerrm);
end $s09$;

-- ============ 10 welcome offer (the nestly_v560 zero-sale rule) ==============================
do $s10$
declare
  v_biz uuid := '1abe0e00-0000-4000-8000-000000000001';
  v_spent uuid := '1abe0e00-0000-4000-8000-000000000011';
  v_fresh uuid := '1abe0e00-0000-4000-8000-000000000015';
  v_res jsonb; v_spent_grant integer; v_fresh_grant integer;
begin
  -- a second member who has never bought anything, minted BEFORE the offer is saved
  perform pg_temp.lc_customer(v_biz,'1abe0e00-0000-4000-8000-000000000016',
    '1abe0e00-0000-4000-8000-000000000017','1abe0e00-0000-4000-8000-000000000018',
    v_fresh,'LC customer two','81860002','lifecycle-cert-c2@example.test');

  perform pg_temp.lc_as('1abe0e00-0000-4000-8000-0000000000a1');
  v_res := public.business_set_welcome_offer_v215(v_biz,true,1000,'custom',null,30,'Free first kopi');
  perform pg_temp.lc_as(null);

  select count(*) into v_spent_grant from public.welcome_offer_grants_v215 g
   where g.business_id=v_biz and g.client_id=v_spent;
  select count(*) into v_fresh_grant from public.welcome_offer_grants_v215 g
   where g.business_id=v_biz and g.client_id=v_fresh and g.min_spend_cents=1000;

  insert into _r values ('10 welcome offer: granted only to the member who never bought',
    case when v_res->>'status' <> 'ok' then 'FAIL: save returned '||coalesce(v_res->>'status','NULL')
         when (v_res->>'active')::boolean is not true then 'FAIL: the offer did not go active'
         when v_spent_grant <> 0
           then 'FAIL: the member with a sale was granted a welcome offer'
         when v_fresh_grant <> 1
           then 'FAIL: the zero-sale member got '||v_fresh_grant||' grant(s), expected 1'
         else 'OK' end);
exception when others then
  perform pg_temp.lc_as(null);
  insert into _r values ('10 welcome offer: granted only to the member who never bought','FAIL: '||sqlerrm);
end $s10$;

-- ============ 11 an unrelated profile change (Invariant F) ===================================
do $s11$
declare
  v_biz uuid := '1abe0e00-0000-4000-8000-000000000001';
  v_before text; v_after text; v_res jsonb;
begin
  v_before := pg_temp.lc_hash(v_biz);
  perform pg_temp.lc_as('1abe0e00-0000-4000-8000-0000000000a1');
  v_res := public.business_set_social_links_v418(v_biz,
    jsonb_build_array(jsonb_build_object('platform','instagram',
      'url','https://instagram.com/lifecyclecert')));
  perform pg_temp.lc_as(null);
  v_after := pg_temp.lc_hash(v_biz);
  insert into _r values ('11 invariant F: saving a social link moves no loyalty state',
    case when v_before = v_after then 'OK'
         else 'FAIL: loyalty state changed '||v_before||' -> '||v_after end);
exception when others then
  perform pg_temp.lc_as(null);
  insert into _r values ('11 invariant F: saving a social link moves no loyalty state','FAIL: '||sqlerrm);
end $s11$;

-- ============ 12 switch points -> stamps, then shape the card the real way ===================
do $s12$
declare
  v_biz uuid := '1abe0e00-0000-4000-8000-000000000001';
  v_owner uuid := '1abe0e00-0000-4000-8000-0000000000a1';
  v_row public.loyalty_programs%rowtype;
  v_draft json; v_ver uuid; v_saved json; v_reward uuid; v_stamps uuid; v_live uuid;
  v_exclusive text := 'not tested';
begin
  perform pg_temp.lc_as(v_owner);
  -- the exclusivity guard first: stamps ON while points is still ON must be refused
  begin
    perform public.set_programmes_v314(v_biz, jsonb_build_object('stamps',true),
                                       '1abe0e00-0000-4000-8000-0000000000c2');
    v_exclusive := 'FAIL: the stamp card was allowed to run alongside points';
  exception when sqlstate '22023' then
    v_exclusive := case when position('The stamp card runs on its own.' in sqlerrm) > 0
                        then 'ok' else 'FAIL: refused, but not by the exclusivity rule: '||sqlerrm end;
  end;

  perform public.set_programmes_v314(v_biz,
    jsonb_build_object('stamps',true,'points',false),'1abe0e00-0000-4000-8000-0000000000c3');
  perform public.business_set_stamp_card_length_v414(v_biz, 5);
  perform pg_temp.lc_age(v_biz);
  perform public.business_set_earning_rule_v359(v_biz, null, 500, null, null, null, null);
  v_draft := public.create_loyalty_config_draft(v_biz);
  v_ver := (v_draft->>'version_id')::uuid;
  v_saved := public.save_loyalty_reward_draft(v_ver, null, jsonb_build_object(
    'internal_name','LC full card gift','customer_name','Free pastry','fulfillment_kind','manual_item',
    'cost_points',5,'credit_cents',0,'estimated_cost_cents',0,'active',true,'sort',0));
  v_reward := (v_saved->>'reward_id')::uuid;
  perform public.publish_loyalty_config(v_ver);
  perform pg_temp.lc_age(v_biz);
  perform pg_temp.lc_as(null);

  select * into v_row from public.loyalty_programs where business_id=v_biz;
  select sp.id into v_stamps from public.business_programmes sp
   where sp.business_id=v_biz and sp.kind='stamps';
  select b.active_config_version_id into v_live from public.businesses b where b.id=v_biz;

  insert into _r values ('12 switch: points off, a 5-stamp card on, with a gift at the last slot',
    case when v_exclusive <> 'ok' then v_exclusive
         when v_row.loyalty_model is distinct from 'stamps'
           then 'FAIL: loyalty_model='||coalesce(v_row.loyalty_model,'NULL')
         when v_row.stamp_target is distinct from 5
           then 'FAIL: stamp_target='||coalesce(v_row.stamp_target::text,'NULL')
         when v_row.stamp_per_cents is distinct from 500
           then 'FAIL: stamp_per_cents='||coalesce(v_row.stamp_per_cents::text,'NULL')
         when app.programme_running_v371(v_biz,'points')
           then 'FAIL: the points programme is still running'
         when not app.programme_running_v371(v_biz,'stamps')
           then 'FAIL: the stamp card is not running'
         when not exists(select 1 from public.loyalty_reward_versions rv
                          where rv.config_version_id=v_live and rv.reward_id=v_reward
                            and rv.active and rv.cost_points=5 and rv.programme_id=v_stamps)
           then 'FAIL: the stamp gift is not live on the stamps spine at 5 stamps'
         else 'OK' end);
exception when others then
  perform pg_temp.lc_as(null);
  insert into _r values ('12 switch: points off, a 5-stamp card on, with a gift at the last slot','FAIL: '||sqlerrm);
end $s12$;

-- ============ 13 stamp earn, and the pots do not leak (Invariant G) ==========================
do $s13$
declare
  v_biz uuid := '1abe0e00-0000-4000-8000-000000000001';
  v_client uuid := '1abe0e00-0000-4000-8000-000000000011';
  v_points uuid; v_stamps uuid; v_p integer; v_s integer; v_res json;
begin
  select sp.id into v_points from public.business_programmes sp where sp.business_id=v_biz and sp.kind='points';
  select sp.id into v_stamps from public.business_programmes sp where sp.business_id=v_biz and sp.kind='stamps';
  perform pg_temp.lc_as('1abe0e00-0000-4000-8000-0000000000a1');
  v_res := public.record_sale_by_phone(v_biz,'81860001',2500,'quick_sale','lifecycle cert sale 2',
             '1abe0e00-0000-4000-8000-0000000000a2','lifecycle-cert-sale-2',
             '1abe0e00-0000-4000-8000-0000000000a3','cash');
  perform pg_temp.lc_as(null);
  select coalesce(sum(pl.points),0) into v_p from public.points_ledger pl
   where pl.business_id=v_biz and pl.client_id=v_client and pl.programme_id=v_points;
  select coalesce(sum(pl.points),0) into v_s from public.points_ledger pl
   where pl.business_id=v_biz and pl.client_id=v_client and pl.programme_id=v_stamps;
  insert into _r values ('13 invariant G: SGD 25 makes 5 stamps and leaves the points pot alone',
    case when v_s <> 5 then 'FAIL: the stamps pot holds '||v_s||' (expected 5)'
         when v_p <> 10 then 'FAIL: the parked points pot moved to '||v_p||' (expected 10)'
         else 'OK' end);
exception when others then
  perform pg_temp.lc_as(null);
  insert into _r values ('13 invariant G: SGD 25 makes 5 stamps and leaves the points pot alone','FAIL: '||sqlerrm);
end $s13$;

-- ============ 14 a completed card, and the gift actually mints ===============================
do $s14$
declare
  v_biz uuid := '1abe0e00-0000-4000-8000-000000000001';
  v_client uuid := '1abe0e00-0000-4000-8000-000000000011';
  v_prog record; v_avail record; v_reward uuid; v_after integer; v_all text;
begin
  select * into v_prog from app.stamp_progress_v323(v_biz,v_client);
  -- A card that fills up does not sit "ready": the engine closes it into a stamp_cycle the moment
  -- the last stamp lands, and the gift is then claimed against that closed cycle. Both shapes are
  -- accepted here, because both mean "this customer has finished a card".
  insert into _r values ('14a completion: the fifth stamp completes a card',
    case when v_prog.programme_id is null then 'FAIL: no stamp programme was found'
         when v_prog.slots is distinct from 5 then 'FAIL: slots='||coalesce(v_prog.slots::text,'NULL')
         when v_prog.net_stamps is distinct from 5
           then 'FAIL: net stamps='||coalesce(v_prog.net_stamps::text,'NULL')
         when v_prog.ready then 'OK (an open card reads ready)'
         when exists (select 1 from public.stamp_cycles sc
                       where sc.business_id=v_biz and sc.client_id=v_client
                         and sc.slots=5 and sc.origin in ('completed','claimed'))
           then 'OK (the card closed into a completed cycle)'
         else 'FAIL: five stamps landed but no card is either ready or closed' end);

  select string_agg(core.customer_name||'/'||core.availability||'/'||core.cost_points::text,',')
    into v_all from app.reward_availability_v432(v_biz,v_client,now()) core;
  select * into v_avail from app.reward_availability_v432(v_biz,v_client,now()) core
   where core.customer_name='Free pastry';
  v_reward := v_avail.reward_id;
  insert into _r values ('14b completion: the stamp gift is offered as claimable',
    case when v_reward is null
           then 'FAIL: the stamp gift is not in the catalogue at all; the catalogue holds ['
                ||coalesce(v_all,'')||']'
         when v_avail.availability <> 'available_at_counter'
           then 'FAIL: availability='||coalesce(v_avail.availability,'NULL')
         when v_avail.cost_points is distinct from 5
           then 'FAIL: cost='||coalesce(v_avail.cost_points::text,'NULL')
         else 'OK' end);

  if v_reward is null then
    insert into _r values ('14c completion: redeeming mints the gift and closes the claim',
      'FAIL: not attempted — 14b found no claimable gift');
    return;
  end if;

  begin
    perform pg_temp.lc_as('1abe0e00-0000-4000-8000-0000000000a1');
    perform app.redeem_reward_core(v_biz,v_client,v_reward,'lifecycle-cert-redeem-1',
                                   '1abe0e00-0000-4000-8000-0000000000a3',null,null);
    perform pg_temp.lc_as(null);
    select count(*) into v_after from app.reward_availability_v432(v_biz,v_client,now()) core
     where core.reward_id=v_reward and core.availability='available_at_counter';
    insert into _r values ('14c completion: redeeming mints the gift and closes the claim',
      case when not exists(select 1 from public.loyalty_redemptions lr
                            where lr.business_id=v_biz and lr.client_id=v_client and lr.reward_id=v_reward)
             then 'FAIL: no redemption row was written'
           when v_after <> 0
             then 'FAIL: the same card can be claimed again — the gift is still offered'
           else 'OK' end);
  exception when others then
    perform pg_temp.lc_as(null);
    insert into _r values ('14c completion: redeeming mints the gift and closes the claim','FAIL: '||sqlerrm);
  end;
exception when others then
  perform pg_temp.lc_as(null);
  insert into _r values ('14z a completed card','FAIL: '||sqlerrm);
end $s14$;

-- ============ 15 an unrelated publish, again (Invariants A/F) ================================
do $s15$
declare
  v_biz uuid := '1abe0e00-0000-4000-8000-000000000001';
  v_before text; v_after text; v_draft json; v_ver uuid; v_prog uuid;
begin
  v_before := pg_temp.lc_hash(v_biz);
  perform pg_temp.lc_as('1abe0e00-0000-4000-8000-0000000000a1');
  v_draft := public.create_loyalty_config_draft(v_biz);
  v_ver := (v_draft->>'version_id')::uuid;
  select bp.id into v_prog from public.birthday_programs bp where bp.business_id=v_biz limit 1;
  -- The draft creator CLONES every birthday version into the new draft, so the second edit is an
  -- UPDATE of the clone — which is exactly what the birthday editor does on a second visit.
  update public.birthday_program_versions bpv
     set customer_description='Two slices on us', window_days_before=14, window_days_after=14
   where bpv.business_id=v_biz and bpv.config_version_id=v_ver and bpv.program_id=v_prog;
  if not found then
    insert into _r values ('15 invariant A/F: the stamp card survives an unrelated publish intact',
      'FAIL: the new draft did not carry the birthday programme forward');
    return;
  end if;
  perform public.publish_loyalty_config(v_ver);
  perform pg_temp.lc_age(v_biz);
  perform pg_temp.lc_as(null);
  v_after := pg_temp.lc_hash(v_biz);
  insert into _r values ('15 invariant A/F: the stamp card survives an unrelated publish intact',
    case when v_before = v_after then 'OK'
         else 'FAIL: loyalty state changed '||v_before||' -> '||v_after end);
exception when others then
  perform pg_temp.lc_as(null);
  insert into _r values ('15 invariant A/F: the stamp card survives an unrelated publish intact','FAIL: '||sqlerrm);
end $s15$;

-- ============ 16 loyalty OFF means off in EVERY reader (Invariant C) =========================
do $s16$
declare
  v_biz uuid := '1abe0e00-0000-4000-8000-000000000001';
  v_client uuid := '1abe0e00-0000-4000-8000-000000000011';
  v_b public.businesses%rowtype;
  v_card jsonb; v_live jsonb; v_pres jsonb; v_core integer; v_pres_n integer;
  v_cat text; v_reach text; v_reward uuid;
begin
  select r.id into v_reward from public.loyalty_rewards r
   where r.business_id=v_biz and r.customer_name='Free pastry' limit 1;

  perform pg_temp.lc_as('1abe0e00-0000-4000-8000-0000000000a1');
  perform public.set_programmes_v314(v_biz, jsonb_build_object('stamps',false),
                                     '1abe0e00-0000-4000-8000-0000000000c4');
  perform pg_temp.lc_as(null);

  select * into v_b from public.businesses where id=v_biz;
  v_card := app.c45_base_actionable_wallet_card(v_biz,v_client,v_b.slug,v_b.name,v_b.industry,
                                                'SGD',v_b.enabled_modules,now());
  v_live := app.customer_live_loyalty_v384(v_biz,v_client,v_b.enabled_modules,now());
  select count(*) into v_core from app.reward_availability_v432(v_biz,v_client,now()) core
   where core.availability not in ('not_started','ended');

  perform pg_temp.lc_as('1abe0e00-0000-4000-8000-000000000012');
  begin
    v_cat := case when jsonb_array_length(
      (public.customer_get_reward_catalog('lifecycle-cert-a-rolled-back'))->'rewards') = 0
      then 'empty' else 'FAIL: the reward catalogue still lists gifts' end;
  exception when sqlstate '42501' then
    v_cat := 'empty';  -- the catalogue refuses outright once the programme is not running
  end;
  v_pres := public.customer_get_business_presentation_v95(v_biz);
  perform pg_temp.lc_as(null);
  select count(*) into v_pres_n from jsonb_array_elements(v_pres->'catalogue'->'rewards');

  perform pg_temp.lc_as('1abe0e00-0000-4000-8000-0000000000a1');
  begin
    perform app.redeem_reward_core(v_biz,v_client,v_reward,'lifecycle-cert-redeem-off',
                                   '1abe0e00-0000-4000-8000-0000000000a3',null,null);
    v_reach := 'FAIL: a gift was redeemed while the programme was switched off';
  exception when others then
    v_reach := 'unreachable';
  end;
  perform pg_temp.lc_as(null);

  insert into _r values ('16 invariant C: off in the business row, hero, wallet, catalogue, presentation and the counter',
    case when (select lp.active from public.loyalty_programs lp where lp.business_id=v_biz)
           then 'FAIL: loyalty_programs.active is still true'
         when (v_card->'loyalty'->>'enabled')::boolean is not false then 'FAIL: the hero still says enabled'
         when (v_card->'loyalty'->>'balance')::integer <> 0 then 'FAIL: the hero still shows a balance'
         when (v_live->>'enabled')::boolean is not false then 'FAIL: the wallet still says enabled'
         when v_core <> 0 then 'FAIL: the availability core still offers '||v_core||' gift(s)'
         when v_cat <> 'empty' then v_cat
         when v_pres_n <> 0 then 'FAIL: the presentation still lists '||v_pres_n||' gift(s)'
         when v_reach <> 'unreachable' then v_reach
         else 'OK' end);
exception when others then
  perform pg_temp.lc_as(null);
  insert into _r values ('16 invariant C: off in the business row, hero, wallet, catalogue, presentation and the counter','FAIL: '||sqlerrm);
end $s16$;

-- ============ 17 an unrelated setting while off ==============================================
do $s17$
declare
  v_biz uuid := '1abe0e00-0000-4000-8000-000000000001';
  v_before text; v_after text;
begin
  v_before := pg_temp.lc_hash(v_biz);
  perform pg_temp.lc_as('1abe0e00-0000-4000-8000-0000000000a1');
  perform public.business_set_social_links_v418(v_biz,
    jsonb_build_array(jsonb_build_object('platform','instagram',
      'url','https://instagram.com/lifecyclecert2')));
  perform pg_temp.lc_as(null);
  v_after := pg_temp.lc_hash(v_biz);
  insert into _r values ('17 an unrelated save while loyalty is off does not wake it',
    case when v_before <> v_after then 'FAIL: loyalty state changed '||v_before||' -> '||v_after
         when (select lp.active from public.loyalty_programs lp where lp.business_id=v_biz)
           then 'FAIL: loyalty came back on by itself'
         else 'OK' end);
exception when others then
  perform pg_temp.lc_as(null);
  insert into _r values ('17 an unrelated save while loyalty is off does not wake it','FAIL: '||sqlerrm);
end $s17$;

-- ============ 18 back on, restored — and a stale draft still cannot publish ==================
do $s18$
declare
  v_biz uuid := '1abe0e00-0000-4000-8000-000000000001';
  v_client uuid := '1abe0e00-0000-4000-8000-000000000011';
  v_row public.loyalty_programs%rowtype; v_b public.businesses%rowtype;
  v_card jsonb; v_live jsonb; v_prog record;
  v_d1 json; v_d2 json; v_stale text := 'not tested';
begin
  perform pg_temp.lc_as('1abe0e00-0000-4000-8000-0000000000a1');
  perform public.set_programmes_v314(v_biz, jsonb_build_object('stamps',true),
                                     '1abe0e00-0000-4000-8000-0000000000c5');
  -- two drafts opened against the SAME live pointer; publishing the first makes the second stale
  v_d1 := public.create_loyalty_config_draft(v_biz);
  v_d2 := public.create_loyalty_config_draft(v_biz);
  perform public.publish_loyalty_config((v_d1->>'version_id')::uuid);
  perform pg_temp.lc_age(v_biz);
  begin
    perform public.publish_loyalty_config((v_d2->>'version_id')::uuid);
    v_stale := 'FAIL: a stale draft was published over the live pointer';
  exception when sqlstate '23514' then
    v_stale := case when sqlerrm like 'stale_draft:%' then 'ok'
                    else 'FAIL: refused, but not as stale_draft: '||sqlerrm end;
  end;
  perform pg_temp.lc_as(null);

  select * into v_row from public.loyalty_programs where business_id=v_biz;
  select * into v_b from public.businesses where id=v_biz;
  v_card := app.c45_base_actionable_wallet_card(v_biz,v_client,v_b.slug,v_b.name,v_b.industry,
                                                'SGD',v_b.enabled_modules,now());
  v_live := app.customer_live_loyalty_v384(v_biz,v_client,v_b.enabled_modules,now());
  select * into v_prog from app.stamp_progress_v323(v_biz,v_client);

  insert into _r values ('18 back on: the card comes back exactly as it was, and nothing resurrects',
    case when v_row.stamp_target is distinct from 5 then 'FAIL: stamp_target='||coalesce(v_row.stamp_target::text,'NULL')
         when v_row.stamp_per_cents is distinct from 500 then 'FAIL: stamp_per_cents='||coalesce(v_row.stamp_per_cents::text,'NULL')
         when v_row.loyalty_model is distinct from 'stamps' then 'FAIL: model='||coalesce(v_row.loyalty_model,'NULL')
         when not v_row.active then 'FAIL: loyalty_programs.active did not come back'
         when (v_card->'loyalty'->>'enabled')::boolean is not true then 'FAIL: the hero is still off'
         when (v_live->>'enabled')::boolean is not true then 'FAIL: the wallet is still off'
         when v_prog.slots is distinct from 5 then 'FAIL: the card length did not survive the pause'
         when v_stale <> 'ok' then v_stale
         else 'OK' end);
exception when others then
  perform pg_temp.lc_as(null);
  insert into _r values ('18 back on: the card comes back exactly as it was, and nothing resurrects','FAIL: '||sqlerrm);
end $s18$;

-- ============ 18b-18e the other direction: stamps -> points =================================
-- The criteria demand BOTH directions. Step 12 proved points -> stamps; this proves the return
-- leg on the same tenant, with the same pot-isolation rule (Invariant G) applied backwards:
-- the stamp pot must PARK, byte-identical — not convert into points, not be zeroed.
do $s18b$
declare
  v_biz uuid := '1abe0e00-0000-4000-8000-000000000001';
  v_client uuid := '1abe0e00-0000-4000-8000-000000000011';
  v_points uuid; v_stamps uuid;
  v_s_before integer; v_p_before integer; v_s_after integer; v_p_after integer;
  v_row public.loyalty_programs%rowtype;
begin
  select sp.id into v_points from public.business_programmes sp
   where sp.business_id=v_biz and sp.kind='points';
  select sp.id into v_stamps from public.business_programmes sp
   where sp.business_id=v_biz and sp.kind='stamps';
  select coalesce(sum(pl.points),0) into v_s_before from public.points_ledger pl
   where pl.business_id=v_biz and pl.client_id=v_client and pl.programme_id=v_stamps;
  select coalesce(sum(pl.points),0) into v_p_before from public.points_ledger pl
   where pl.business_id=v_biz and pl.client_id=v_client and pl.programme_id=v_points;

  perform pg_temp.lc_as('1abe0e00-0000-4000-8000-0000000000a1');
  perform public.set_programmes_v314(v_biz,
    jsonb_build_object('points',true,'stamps',false),'1abe0e00-0000-4000-8000-0000000000c6');
  perform pg_temp.lc_as(null);

  select * into v_row from public.loyalty_programs where business_id=v_biz;
  select coalesce(sum(pl.points),0) into v_s_after from public.points_ledger pl
   where pl.business_id=v_biz and pl.client_id=v_client and pl.programme_id=v_stamps;
  select coalesce(sum(pl.points),0) into v_p_after from public.points_ledger pl
   where pl.business_id=v_biz and pl.client_id=v_client and pl.programme_id=v_points;

  insert into _r values ('18b switch back: stamps off, points on, the programme stays live',
    case when v_row.loyalty_model is distinct from 'classic'
           then 'FAIL: loyalty_model='||coalesce(v_row.loyalty_model,'NULL')||' (expected classic)'
         when v_row.kind is distinct from 'points'
           then 'FAIL: kind='||coalesce(v_row.kind,'NULL')
         when not v_row.active then 'FAIL: loyalty_programs.active went false across the switch'
         when not app.programme_running_v371(v_biz,'points') then 'FAIL: points is not running'
         when app.programme_running_v371(v_biz,'stamps') then 'FAIL: the stamp card is still running'
         else 'OK' end);

  -- The points pot is the 10 earned in step 04, untouched since: step 14c redeemed a STAMP gift,
  -- which can only ever spend stamps.
  insert into _r values ('18c invariant G backwards: the stamp pot parks and the points pot is exactly as step 05 left it',
    case when v_s_after <> v_s_before
           then 'FAIL: the stamp pot moved '||v_s_before||' -> '||v_s_after||' across the switch'
         when v_p_after <> v_p_before
           then 'FAIL: the points pot moved '||v_p_before||' -> '||v_p_after||' across the switch'
         when v_p_after <> 10
           then 'FAIL: the points pot holds '||v_p_after||', but step 05 left it holding 10'
         else 'OK (stamps parked at '||v_s_after||', points still 10)' end);
exception when others then
  perform pg_temp.lc_as(null);
  insert into _r values ('18z switch back to points','FAIL: '||sqlerrm);
end $s18b$;

do $s18d$
declare
  v_biz uuid := '1abe0e00-0000-4000-8000-000000000001';
  v_client uuid := '1abe0e00-0000-4000-8000-000000000011';
  v_points uuid; v_stamps uuid; v_s_before integer; v_p integer; v_s integer; v_res json;
begin
  select sp.id into v_points from public.business_programmes sp where sp.business_id=v_biz and sp.kind='points';
  select sp.id into v_stamps from public.business_programmes sp where sp.business_id=v_biz and sp.kind='stamps';
  select coalesce(sum(pl.points),0) into v_s_before from public.points_ledger pl
   where pl.business_id=v_biz and pl.client_id=v_client and pl.programme_id=v_stamps;

  perform pg_temp.lc_as('1abe0e00-0000-4000-8000-0000000000a1');
  v_res := public.record_sale_by_phone(v_biz,'81860001',500,'quick_sale','lifecycle cert sale 3',
             '1abe0e00-0000-4000-8000-0000000000a2','lifecycle-cert-sale-3',
             '1abe0e00-0000-4000-8000-0000000000a3','cash');
  perform pg_temp.lc_as(null);

  select coalesce(sum(pl.points),0) into v_p from public.points_ledger pl
   where pl.business_id=v_biz and pl.client_id=v_client and pl.programme_id=v_points;
  select coalesce(sum(pl.points),0) into v_s from public.points_ledger pl
   where pl.business_id=v_biz and pl.client_id=v_client and pl.programme_id=v_stamps;

  insert into _r values ('18d earning after the switch back lands in the POINTS pot only',
    case when v_res->>'status' <> 'ok' then 'FAIL: status='||coalesce(v_res->>'status','NULL')
         when (v_res->>'points_earned')::integer <> 10
           then 'FAIL: points_earned='||coalesce(v_res->>'points_earned','NULL')||' (expected 10)'
         when v_p <> 20 then 'FAIL: the points pot holds '||v_p||' (expected 20)'
         when v_s <> v_s_before
           then 'FAIL: the parked stamp pot moved '||v_s_before||' -> '||v_s||' on a points sale'
         else 'OK' end);
exception when others then
  perform pg_temp.lc_as(null);
  insert into _r values ('18d earning after the switch back lands in the POINTS pot only','FAIL: '||sqlerrm);
end $s18d$;

do $s18e$
declare
  v_biz uuid := '1abe0e00-0000-4000-8000-000000000001';
  v_client uuid := '1abe0e00-0000-4000-8000-000000000011';
  v_b public.businesses%rowtype; v_card jsonb; v_live jsonb; v_points uuid; v_names text;
begin
  select * into v_b from public.businesses where id=v_biz;
  select sp.id into v_points from public.business_programmes sp where sp.business_id=v_biz and sp.kind='points';
  v_card := app.c45_base_actionable_wallet_card(v_biz,v_client,v_b.slug,v_b.name,v_b.industry,
                                                'SGD',v_b.enabled_modules,now());
  v_live := app.customer_live_loyalty_v384(v_biz,v_client,v_b.enabled_modules,now());
  select coalesce(string_agg(core.customer_name,',' order by core.customer_name),'')
    into v_names from app.reward_availability_v432(v_biz,v_client,now()) core;

  insert into _r values ('18e both readers follow the switch back, and the catalogue swaps with it',
    case when (v_card->'loyalty'->>'enabled')::boolean is not true then 'FAIL: the hero is off'
         when v_card->'loyalty'->>'unit' <> 'points'
           then 'FAIL: the hero unit is '||coalesce(v_card->'loyalty'->>'unit','NULL')
         when (v_card->'loyalty'->>'balance')::integer <> 20
           then 'FAIL: the hero balance is '||coalesce(v_card->'loyalty'->>'balance','NULL')
         when (v_live->>'enabled')::boolean is not true then 'FAIL: the wallet is off'
         when v_live->>'unit' <> 'points'
           then 'FAIL: the wallet unit is '||coalesce(v_live->>'unit','NULL')
         when (v_live->>'balance')::integer <> 20
           then 'FAIL: the wallet balance is '||coalesce(v_live->>'balance','NULL')
         when (v_live->'programme'->>'id')::uuid is distinct from v_points
           then 'FAIL: the wallet is reading a pot that is not the points spine'
         when v_names <> 'Free kopi'
           then 'FAIL: the catalogue holds ['||v_names||'], expected only the points gift'
         else 'OK' end);
exception when others then
  insert into _r values ('18e both readers follow the switch back, and the catalogue swaps with it','FAIL: '||sqlerrm);
end $s18e$;

-- ============ 18f the parked pot may not lend its gifts to the live card ======================
-- nestly_v568 (owner, KKY demo 2026-08-28): tenant A now runs POINTS with a PARKED stamp card
-- behind it, and both pots carry a gift priced 5. The survivor arm of app.reward_availability_v432
-- used to admit any reward version in the closed cycle's config whose cost fitted the card,
-- whatever pot it belonged to — so the parked pot's gift was offered as a stamp gift the
-- redemption core would then refuse. The certification carries the shape from here on: a gift
-- may only be offered when its OWN programme is running.
do $s18f$
declare
  v_biz uuid := '1abe0e00-0000-4000-8000-000000000001';
  v_client uuid := '1abe0e00-0000-4000-8000-0000000000b4';
  v_offered text; v_offside text;
begin
  select string_agg(distinct lr.customer_name||' ['||coalesce(sp.kind,'none')||']', ', ')
    into v_offside
    from app.reward_availability_v432(v_biz, v_client, now()) core
    join public.loyalty_rewards lr on lr.id=core.reward_id
    left join public.business_programmes sp on sp.id=lr.programme_id
   where not exists (select 1 from public.business_programmes sp2
                      where sp2.id=lr.programme_id and sp2.active);
  select string_agg(distinct core.unit, ', ') into v_offered
    from app.reward_availability_v432(v_biz, v_client, now()) core;
  insert into _r values ('18f the parked pot lends nothing to the live programme',
    case when v_offside is not null then 'FAIL: offered from a parked pot: '||v_offside
         when v_offered is distinct from 'points'
           then 'FAIL: the live unit should be points only, got '||coalesce(v_offered,'<none>')
         else 'OK' end);
exception when others then
  insert into _r values ('18f the parked pot lends nothing to the live programme','FAIL: '||sqlerrm);
end $s18f$;

-- ============ 18g a teammate's login is only live once the owner approves it =================
-- nestly_v569 (owner, 2026-08-28): public.accept_invite always writes access_state='pending' and
-- the owner releases it with decide_staff_access_v207. Until v569 three readers ignored that
-- state — the roster called the teammate active, get_my_personas routed her into a workspace RLS
-- refused, and she was billed as a seat. Tenant creation IS a lifecycle scenario, so the shape
-- is certified here: pending is refused everywhere and unbilled; approval releases access, the
-- persona answer and the seat together.
do $s18g$
declare
  v_biz uuid := '1abe0e00-0000-4000-8000-000000000001';
  v_owner uuid := '1abe0e00-0000-4000-8000-0000000000a1';
  v_mate uuid := '1abe0e00-0000-4000-8000-0000000000f1';
  v_staff_mate uuid;
  v_access boolean; v_state text; v_seats_pending integer; v_seats_after integer; v_res jsonb;
begin
  insert into auth.users(instance_id,id,aud,role,email,encrypted_password,
                         email_confirmed_at,created_at,updated_at)
  values ('00000000-0000-0000-0000-000000000000',v_mate,'authenticated','authenticated',
          'lc-teammate-'||v_mate||'@example.test','',now(),now(),now());
  insert into public.staff(business_id, user_id, role, full_name, active, access_state)
  values (v_biz, v_mate, 'staff', 'LC teammate', true, 'pending') returning id into v_staff_mate;

  perform pg_temp.lc_as(v_mate);
  select (persona->>'workspace_access')::boolean, persona->>'access_state'
    into v_access, v_state
    from jsonb_array_elements(public.get_my_personas()->'staff') persona
   where (persona->>'business_id')::uuid = v_biz;
  perform pg_temp.lc_as(null);
  select app.billable_seats(v_biz) into v_seats_pending;

  perform pg_temp.lc_as(v_owner);
  v_res := public.decide_staff_access_v207(v_biz, v_staff_mate, true);
  perform pg_temp.lc_as(v_mate);
  select (persona->>'workspace_access')::boolean
    into v_access
    from jsonb_array_elements(public.get_my_personas()->'staff') persona
   where (persona->>'business_id')::uuid = v_biz;
  perform pg_temp.lc_as(null);
  select app.billable_seats(v_biz) into v_seats_after;

  insert into _r values ('18g a login is live only once the owner approves it',
    case when v_state is distinct from 'pending' then 'FAIL: the persona hid access_state'
         when v_res->>'access_state' is distinct from 'approved' then 'FAIL: approval said '||coalesce(v_res::text,'?')
         when v_access is not true then 'FAIL: still refused after approval'
         when v_seats_after <> v_seats_pending + 1
           then 'FAIL: seats went '||v_seats_pending||' -> '||v_seats_after||' (approval should add exactly one)'
         else 'OK' end);
exception when others then
  insert into _r values ('18g a login is live only once the owner approves it','FAIL: '||sqlerrm);
end $s18g$;

-- ============ 18h a module switched Off is off at the reader, not just in the rail ============
-- nestly_v570 (owner, 2026-08-28): an owner set a teammate's Dashboard module to Off and the
-- teammate still read the firm's revenue — the router exempted the dashboard by name, the rail
-- listed it, and the reader gated on the ROLE permission view_sales, which every 'staff' role
-- carries. "OFF means OFF everywhere" is a guarantee this certification already makes for
-- programmes; it is made here for module permissions too, at the reader, because that is the
-- boundary a hidden nav entry is not.
do $s18h$
declare
  v_biz uuid := '1abe0e00-0000-4000-8000-000000000001';
  v_mate uuid := '1abe0e00-0000-4000-8000-0000000000f2';
  v_staff uuid; v_branch uuid; v_served boolean := true; v_permitted boolean := false;
begin
  select id into v_branch from public.branches where business_id=v_biz and active order by created_at limit 1;
  insert into auth.users(instance_id,id,aud,role,email,encrypted_password,
                         email_confirmed_at,created_at,updated_at)
  values ('00000000-0000-0000-0000-000000000000',v_mate,'authenticated','authenticated',
          'lc-denied-'||v_mate||'@example.test','',now(),now(),now());
  -- an allowlist that grants the till and omits the dashboard: the owner's explicit Off
  insert into public.staff(business_id,user_id,role,full_name,active,access_state,modules)
  values (v_biz,v_mate,'staff','LC denied teammate',true,'approved',array['till','clients'])
  returning id into v_staff;
  insert into public.staff_branches(business_id, staff_id, branch_id)
  values (v_biz, v_staff, v_branch);

  perform pg_temp.lc_as(v_mate);
  v_permitted := app.can_module(v_biz,'dashboard');
  begin
    perform public.get_dashboard_summary_v155(v_biz, current_date-30, current_date,
                                              'current', array[]::uuid[], v_branch);
  exception when others then v_served := false;
  end;
  perform pg_temp.lc_as(null);

  insert into _r values ('18h a module set Off is refused at the reader, not just hidden',
    case when v_permitted then 'FAIL: the module authority still grants the denied teammate'
         when v_served then 'FAIL: the reader served a dashboard the owner switched off'
         else 'OK' end);
exception when others then
  insert into _r values ('18h a module set Off is refused at the reader, not just hidden','FAIL: '||sqlerrm);
end $s18h$;

-- ============ 19 two-path equivalence ========================================================
-- Tenant A reached its final state through Grow (draft -> publish). Tenant B reaches the SAME
-- state through Settings first (business_set_loyalty_model_v353 as the very first touch). The
-- runtime state must be identical; the history behind it need not be.
do $s19$
declare
  v_a uuid := '1abe0e00-0000-4000-8000-000000000001';
  v_b uuid := '1abe0e00-0000-4000-8000-000000000002';
  v_a_run text; v_b_run text; v_a_spine text; v_b_spine text;
  v_a_wo text; v_b_wo text;
  v_a_card jsonb; v_b_card jsonb; v_a_live jsonb; v_b_live jsonb;
  v_ab public.businesses%rowtype; v_bb public.businesses%rowtype;
  v_a_cust uuid := '1abe0e00-0000-4000-8000-000000000019';
  v_draft json; v_ver uuid;
  v_b_cust uuid := '1abe0e00-0000-4000-8000-000000000021';
  v_shape_a text; v_shape_b text;
begin
  -- ---- tenant B, born identically, then configured SETTINGS-FIRST ----
  perform pg_temp.lc_birth(v_b,'1abe0e00-0000-4000-8000-0000000000b1',
    '1abe0e00-0000-4000-8000-0000000000b2','1abe0e00-0000-4000-8000-0000000000b3',
    'Lifecycle Cert B','lifecycle-cert-b-rolled-back','lifecycle-cert-b@example.test');
  perform pg_temp.lc_as('1abe0e00-0000-4000-8000-0000000000b1');
  perform public.business_set_loyalty_model_v353(v_b,'stamps');           -- the FIRST touch
  perform public.set_programmes_v314(v_b, jsonb_build_object('stamps',true),
                                     '1abe0e00-0000-4000-8000-0000000000d1');
  perform public.business_set_stamp_card_length_v414(v_b, 5);
  perform pg_temp.lc_age(v_b);
  perform public.business_set_earning_rule_v359(v_b, 2, 500, null, null, null, null);
  -- The gift has no Settings writer: a stamp card with nothing at its last stamp is not
  -- publishable (app.stamp_config_edit_commit_v433 pends it), so both paths necessarily finish
  -- through the same draft->publish. That is the point: the SEQUENCE differs, the END STATE
  -- must not.
  v_draft := public.create_loyalty_config_draft(v_b);
  v_ver := (v_draft->>'version_id')::uuid;
  perform public.save_loyalty_reward_draft(v_ver, null, jsonb_build_object(
    'internal_name','LC full card gift','customer_name','Free pastry','fulfillment_kind','manual_item',
    'cost_points',5,'credit_cents',0,'estimated_cost_cents',0,'active',true,'sort',0));
  perform public.publish_loyalty_config(v_ver);
  perform pg_temp.lc_age(v_b);
  -- and the same return leg tenant A walked in 18b, so the two tenants are compared in the same
  -- final state: a parked stamp card behind a running points programme.
  perform public.set_programmes_v314(v_b, jsonb_build_object('points',true,'stamps',false),
                                     '1abe0e00-0000-4000-8000-0000000000d2');
  perform public.business_set_welcome_offer_v215(v_b,true,1000,'custom',null,30,'Free first kopi');
  perform pg_temp.lc_as(null);

  -- ---- a same-shaped customer on each tenant: one verified member, one SGD 25 sale ----
  perform pg_temp.lc_customer(v_a,'1abe0e00-0000-4000-8000-00000000001a',
    '1abe0e00-0000-4000-8000-00000000001b','1abe0e00-0000-4000-8000-00000000001c',
    v_a_cust,'LC A twin','81860003','lifecycle-cert-a-twin@example.test');
  perform pg_temp.lc_customer(v_b,'1abe0e00-0000-4000-8000-000000000022',
    '1abe0e00-0000-4000-8000-000000000023','1abe0e00-0000-4000-8000-000000000024',
    v_b_cust,'LC B twin','81860004','lifecycle-cert-b-twin@example.test');
  perform pg_temp.lc_as('1abe0e00-0000-4000-8000-0000000000a1');
  perform public.record_sale_by_phone(v_a,'81860003',2500,'quick_sale','lifecycle cert twin A',
    '1abe0e00-0000-4000-8000-0000000000a2','lifecycle-cert-twin-a',
    '1abe0e00-0000-4000-8000-0000000000a3','cash');
  perform pg_temp.lc_as('1abe0e00-0000-4000-8000-0000000000b1');
  perform public.record_sale_by_phone(v_b,'81860004',2500,'quick_sale','lifecycle cert twin B',
    '1abe0e00-0000-4000-8000-0000000000b2','lifecycle-cert-twin-b',
    '1abe0e00-0000-4000-8000-0000000000b3','cash');
  perform pg_temp.lc_as(null);

  v_a_run := pg_temp.lc_runtime(v_a);
  v_b_run := pg_temp.lc_runtime(v_b);
  select string_agg(sp.kind||'='||sp.active::text,',' order by sp.kind) into v_a_spine
    from public.business_programmes sp where sp.business_id=v_a;
  select string_agg(sp.kind||'='||sp.active::text,',' order by sp.kind) into v_b_spine
    from public.business_programmes sp where sp.business_id=v_b;
  select wo.active::text||'|'||wo.min_spend_cents||'|'||wo.reward_catalog_kind||'|'
         ||coalesce(wo.reward_label,'-')||'|'||coalesce(wo.expiry_days::text,'-')
    into v_a_wo from public.business_welcome_offers_v215 wo where wo.business_id=v_a;
  select wo.active::text||'|'||wo.min_spend_cents||'|'||wo.reward_catalog_kind||'|'
         ||coalesce(wo.reward_label,'-')||'|'||coalesce(wo.expiry_days::text,'-')
    into v_b_wo from public.business_welcome_offers_v215 wo where wo.business_id=v_b;

  select * into v_ab from public.businesses where id=v_a;
  select * into v_bb from public.businesses where id=v_b;
  v_a_card := app.c45_base_actionable_wallet_card(v_a,v_a_cust,v_ab.slug,'X','fnb','SGD',v_ab.enabled_modules,now());
  v_b_card := app.c45_base_actionable_wallet_card(v_b,v_b_cust,v_bb.slug,'X','fnb','SGD',v_bb.enabled_modules,now());
  v_a_live := app.customer_live_loyalty_v384(v_a,v_a_cust,v_ab.enabled_modules,now());
  v_b_live := app.customer_live_loyalty_v384(v_b,v_b_cust,v_bb.enabled_modules,now());
  -- shape, not identity: programme ids differ by construction, balances and switches may not
  v_shape_a := (v_a_card->'loyalty'->>'enabled')||'/'||(v_a_card->'loyalty'->>'unit')||'/'
             ||(v_a_card->'loyalty'->>'balance')||'/'||(v_a_live->>'enabled')||'/'
             ||coalesce(v_a_live->>'unit','-')||'/'||(v_a_live->>'balance');
  v_shape_b := (v_b_card->'loyalty'->>'enabled')||'/'||(v_b_card->'loyalty'->>'unit')||'/'
             ||(v_b_card->'loyalty'->>'balance')||'/'||(v_b_live->>'enabled')||'/'
             ||coalesce(v_b_live->>'unit','-')||'/'||(v_b_live->>'balance');

  insert into _r values ('19a two paths: the live programme row is identical',
    case when v_a_run = v_b_run then 'OK' else 'FAIL: A['||v_a_run||'] B['||v_b_run||']' end);
  insert into _r values ('19b two paths: the spine active-set is identical',
    case when v_a_spine = v_b_spine then 'OK'
         else 'FAIL: A['||coalesce(v_a_spine,'-')||'] B['||coalesce(v_b_spine,'-')||']' end);
  insert into _r values ('19c two paths: the welcome offer is identical',
    case when v_a_wo is not distinct from v_b_wo then 'OK'
         else 'FAIL: A['||coalesce(v_a_wo,'-')||'] B['||coalesce(v_b_wo,'-')||']' end);
  insert into _r values ('19d two paths: a same-shaped member gets the same answer from both readers',
    case when v_shape_a = v_shape_b then 'OK ('||v_shape_a||')'
         else 'FAIL: A['||v_shape_a||'] B['||v_shape_b||']' end);
exception when others then
  perform pg_temp.lc_as(null);
  insert into _r values ('19z two-path equivalence','FAIL: '||sqlerrm);
end $s19$;

select * from _r order by check_id;

rollback;

-- ============ 20 leak, part two: after the rollback, outside the transaction =================
-- A DO block, not a select: a trailing result set would replace the report above in the CLI's
-- output. Green runs say nothing here; a leak aborts the run with this message.
do $leakafter$
declare v_total bigint;
begin
  select (select count(*) from public.businesses            where id::text          like '1abe0e00-%')
       + (select count(*) from public.clients               where id::text          like '1abe0e00-%')
       + (select count(*) from public.staff                 where id::text          like '1abe0e00-%')
       + (select count(*) from public.branches              where id::text          like '1abe0e00-%')
       + (select count(*) from public.customer_links        where id::text          like '1abe0e00-%')
       + (select count(*) from public.customer_identities   where id::text          like '1abe0e00-%')
       + (select count(*) from public.birthday_programs     where id::text          like '1abe0e00-%')
       + (select count(*) from auth.users                   where id::text          like '1abe0e00-%')
       + (select count(*) from public.points_ledger         where business_id::text like '1abe0e00-%')
       + (select count(*) from public.sales                 where business_id::text like '1abe0e00-%')
       + (select count(*) from public.loyalty_programs      where business_id::text like '1abe0e00-%')
       + (select count(*) from public.firm_config_versions  where business_id::text like '1abe0e00-%')
    into v_total;
  if v_total <> 0 then
    raise exception 'LIFECYCLE CERT LEAK: % fixture row(s) survived the rollback', v_total;
  end if;
end $leakafter$;
