-- Rollback-only acceptance for Nestly v273 — "never set up" and "nobody used it" must not
-- produce the same number.
-- Run after the canonical chain through v273 in a disposable database:
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f db/tests/v273_usage_null_when_never_set_up.sql
-- Everything runs inside one transaction and is rolled back; nothing is left behind.
--
-- v271 nulled promotion and gift-card usage on the grounds that "a zero would read as measured,
-- and nobody used it", then returned coalesce(...,0) for birthday, welcome and referrals — so a
-- firm that never configured a birthday benefit reported the same 0 as a firm whose benefit ran
-- all year unclaimed. v273 draws the line at programme EXISTENCE, read from each programme's own
-- configuration table.
--
-- This suite therefore asserts BOTH directions. A test that only proved the null case would pass
-- against a function that returned null unconditionally, which would destroy the real zeros.
--
-- Verified against production on 2026-08-10 before this file was written:
--   Cubbly (0 birthday_programs, 0 welcome offers, 0 referral_programs) -> all three NULL
--   business 33773caa (1 referral programme, 0 qualified referrals)     -> referrals = 0
begin;

create or replace function pg_temp.as_v273_user(
  p_uid uuid, p_role text default 'authenticated'
) returns void language plpgsql as $$
begin
  execute 'reset role';
  perform set_config('request.jwt.claim.sub','',true);
  perform set_config('request.jwt.claims','{}',true);
  execute format('set local role %I', p_role);
  perform set_config('request.jwt.claim.sub', coalesce(p_uid::text,''), true);
  perform set_config(
    'request.jwt.claims',
    json_build_object('sub',p_uid,'role',p_role)::text,
    true
  );
end
$$;
grant execute on function pg_temp.as_v273_user(uuid,text) to authenticated, anon;

do $v273$
declare
  v_owner uuid := gen_random_uuid();
  v_business uuid := gen_random_uuid();
  v_json jsonb;
begin
  reset role;
  insert into auth.users(
    instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at
  ) values('00000000-0000-0000-0000-000000000000',v_owner,'authenticated','authenticated',
    'v273-owner-'||substr(v_owner::text,1,8)||'@example.test','',now(),now(),now());

  insert into public.businesses(id,name,slug,industry,enabled_modules)
  values(v_business,'V273 usage fixture','v273-'||substr(v_business::text,1,8),'retail',
         array['dashboard','clients','loyalty']);

  -- app.is_salon_owner is gated on app.business_workspace_open_v94, whose two rows are created by
  -- a trigger on the business insert; the controls check constraint requires the decided_* trio
  -- alongside 'approved'. Without this the RPC refuses 42501 before it can measure anything.
  update public.business_workspace_controls_v94
     set approval_status='approved', decided_by=v_owner, decided_at=now(),
         decision_reason='v273 rollback-only fixture'
   where business_id=v_business;
  update public.business_subscription_lifecycle_v94
     set state='current', workspace_paused=false
   where business_id=v_business;

  insert into public.staff(business_id,user_id,full_name,role,active,access_state)
  values(v_business,v_owner,'V273 owner','owner',true,'approved');

  -- 1. NOTHING configured. All three must be null, not 0.
  perform pg_temp.as_v273_user(v_owner);
  v_json := public.business_programme_usage_v271(v_business);
  reset role;
  if jsonb_typeof(v_json->'birthday'->'customers') <> 'null' then
    raise exception 'v273 FAIL: no birthday programme exists, yet customers is % (a fabricated measurement)',
      v_json->'birthday'->>'customers';
  end if;
  if jsonb_typeof(v_json->'welcome'->'customers') <> 'null' then
    raise exception 'v273 FAIL: no welcome offer exists, yet customers is %',
      v_json->'welcome'->>'customers';
  end if;
  if jsonb_typeof(v_json->'referrals'->'customers') <> 'null' then
    raise exception 'v273 FAIL: no referral programme exists, yet customers is %',
      v_json->'referrals'->>'customers';
  end if;

  -- v271's original nulls must survive the splice.
  if jsonb_typeof(v_json->'promotions'->'customers') <> 'null'
     or jsonb_typeof(v_json->'gift_cards'->'customers') <> 'null' then
    raise exception 'v273 FAIL: v271 promotion/gift-card nulls were lost';
  end if;

  -- 2. THE OTHER DIRECTION, and the one a lazy fix would break: a referral programme that EXISTS
  --    and has no qualified referral is a real measurement and must read 0.
  insert into public.referral_programs(business_id) values(v_business);
  perform pg_temp.as_v273_user(v_owner);
  v_json := public.business_programme_usage_v271(v_business);
  reset role;
  if v_json->'referrals'->>'customers' is distinct from '0' then
    raise exception
      'v273 FAIL: a configured referral programme with no qualified referrals must read 0, got %',
      coalesce(v_json->'referrals'->>'customers','null');
  end if;

  raise notice 'v273 usage-null suite: ALL PASS (unconfigured -> null, configured-but-unused -> 0)';
end
$v273$;

rollback;
