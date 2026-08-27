-- Rollback-only acceptance for nestly_v560 — the welcome offer and the birthday treat reach
-- the customers who already exist.
-- Run: supabase db query --linked -f db/tests/v560_welcome_and_birthday_reach_customers.sql
-- Any row whose value starts with FAIL is a failure. Nothing is committed.
--
--   01  shapes: neither birthday function joins loyalty_program_versions any more, and
--       business_set_welcome_offer_v215 carries the v560 grant pass.
--   02  data: for every business whose welcome offer is ACTIVE, every zero-sale client holds a
--       grant — the invariant the backfill established and the patched writer preserves.
--   03  end to end, rolled back: a fixture business whose loyalty_program_versions row says
--       active=FALSE, with a live birthday programme, still answers ready_to_activate for an
--       opted-in customer in their window. (app.c45_customer_birthday_benefit_for_context is
--       app-internal — no auth session needed — so this exercises the real function on this
--       database. The welcome writer's end-to-end ran on a local cluster: it needs auth.uid(),
--       which this suite must not stub on production.)
--
-- ROLLBACK: reverting v560 means restoring the lpv.active joins in both birthday functions and
-- deleting the grant pass from business_set_welcome_offer_v215. Only appropriate if the owner
-- decides a pre-existing zero-sale customer should NOT receive a newly configured welcome
-- offer, and that the birthday treat should stay hidden whenever the accruing programme's
-- version flag is false — both the opposite of the 2026-08-27 rulings.

begin;

create temp table _r(check_id text, value text) on commit drop;

do $shape$
declare v_c45 text; v_act text; v_wel text;
begin
  v_c45 := pg_get_functiondef('app.c45_customer_birthday_benefit_for_context(uuid,uuid,uuid,date,timestamptz)'::regprocedure);
  v_act := pg_get_functiondef('public.customer_activate_birthday_benefit(text,uuid)'::regprocedure);
  v_wel := pg_get_functiondef('public.business_set_welcome_offer_v215(uuid,boolean,integer,text,uuid,integer,text)'::regprocedure);
  insert into _r values ('01 function shapes',
    -- the v560 comments in both bodies legitimately NAME the table; only a real join fails.
    case when v_c45 ~* 'join\s+public\.loyalty_program_versions'
      then 'FAIL: the birthday context reader still joins loyalty_program_versions'
      when v_act ~* 'join\s+public\.loyalty_program_versions'
      then 'FAIL: customer_activate_birthday_benefit still joins loyalty_program_versions'
      when position('WELCOME_OFFER_GRANTED_TO_EXISTING_V560' in v_wel) = 0
      then 'FAIL: the welcome writer has no v560 grant pass'
      else 'OK' end);
end
$shape$;

do $data$
declare v_missing integer;
begin
  select count(*) into v_missing
    from public.business_welcome_offers_v215 offer
    join public.clients c on c.business_id = offer.business_id
   where offer.active
     and not exists (select 1 from public.sales s
                      where s.business_id = offer.business_id and s.client_id = c.id
                        and s.reversal_of is null)
     and not exists (select 1 from public.welcome_offer_grants_v215 g
                      where g.business_id = offer.business_id and g.client_id = c.id);
  insert into _r values ('02 every zero-sale client of an active offer holds a grant',
    case when v_missing = 0 then 'OK' else 'FAIL: '||v_missing||' client(s) without a grant' end);
end
$data$;

-- The status/version guards call the owner predicate; stubbed IN THIS TRANSACTION ONLY, exactly
-- as the v559 suite does, and rolled back with everything else.
create or replace function app.c45_owner_loyalty_write(p_business_id uuid)
returns boolean language sql stable as $stub$ select true $stub$;

do $birthday$
declare
  v_biz uuid := 'cafe0560-0000-4000-8000-000000000001';
  v_ver uuid := 'cafe0560-0000-4000-8000-000000000002';
  v_client uuid := 'cafe0560-0000-4000-8000-000000000003';
  v_identity uuid := 'cafe0560-0000-4000-8000-000000000004';
  v_answer jsonb;
begin
  insert into public.businesses(id, name, slug, industry, enabled_modules, active_config_version_id)
  values (v_biz, 'v560 fixture', 'v560-fixture-rolled-back', 'fnb', '{loyalty}', null);
  insert into public.firm_config_versions(id, business_id, version_no, status, snapshot_hash)
  values (v_ver, v_biz,
          (select coalesce(max(version_no),0)+1 from public.firm_config_versions where business_id = v_biz),
          'draft', md5('v560-fixture'));
  update public.businesses set active_config_version_id = v_ver where id = v_biz;
  -- the stale flag this migration makes irrelevant to birthdays:
  insert into public.loyalty_program_versions(config_version_id, business_id, kind, loyalty_model, active,
    earn_points_per_dollar, redeem_points, reward_credit_cents, tier_basis, expiry_mode)
  values (v_ver, v_biz, 'points', 'classic', false, 1, 100, 500, 'visits', 'none');
  insert into public.birthday_programs(id, business_id)
  values ('cafe0560-0000-4000-8000-000000000005', v_biz);
  insert into public.birthday_program_versions(config_version_id, business_id, program_id, active, sort,
    customer_label, customer_description, customer_terms, fulfillment_kind, discount_percent,
    window_mode, window_days_before, window_days_after)
  values (v_ver, v_biz, 'cafe0560-0000-4000-8000-000000000005', true, 0,
          'Birthday treat', 'fixture', 'fixture terms', 'discount_pct', 20, 'month', 0, 0);
  -- version rows are immutable once published (the v416-family guards), so the config is
  -- promoted only AFTER its rows exist -- the same order every real publish follows.
  update public.firm_config_versions set status='published', published_at=now() where id = v_ver;
  insert into public.clients(id, business_id, full_name) values (v_client, v_biz, 'v560 fixture client');
  -- participation hangs off a customer identity, which hangs off an auth user; any EXISTING
  -- auth id satisfies both fks without creating one, and every row here is rolled back. The
  -- context reader checks opted_in by identity alone (the auth_user_id gate belongs to the
  -- activate RPC, not exercised here).
  insert into public.customer_identities(id, auth_user_id)
  select v_identity, u.id from auth.users u limit 1;
  insert into public.customer_birthday_participation(identity_id, auth_user_id, opted_in)
  select v_identity, u.id, true from auth.users u limit 1
  on conflict (identity_id) do update set opted_in = true;
  v_answer := app.c45_customer_birthday_benefit_for_context(
    v_biz, v_client, v_identity,
    make_date(1990, extract(month from (now() at time zone 'Asia/Singapore'))::int, 15), now());
  insert into _r values ('03 birthday resolves despite loyalty_program_versions.active=false',
    case when v_answer->>'status' = 'ready_to_activate' then 'OK'
         else 'FAIL: '||coalesce(v_answer::text, 'NULL — still hidden') end);
exception when others then
  insert into _r values ('03 birthday resolves despite loyalty_program_versions.active=false',
    'FAIL: '||sqlerrm);
end
$birthday$;

select * from _r order by check_id;

rollback;
