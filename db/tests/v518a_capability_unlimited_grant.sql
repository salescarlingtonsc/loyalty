-- Rollback-only acceptance for nestly_v518 — superadmin capability grants,
-- sector eligibility and monthly quota.
-- Run: supabase db query --linked -f db/tests/v518_capability_grants_and_quota.sql
-- Any row whose value starts with FAIL is a failure. Nothing is committed.
--
-- Fixture: one synthetic business per scenario, so nothing depends on which real
-- tenants happen to exist.
--
--   01  surface: RLS on every table, no anon grants, append-only meter
--   02  ABSENCE IS NOT PERMISSION — a firm with no grant row inherits the
--       registry default, which is OFF for the seeded capability
--   03  ELIGIBILITY (b): a firm without the required module is refused with
--       'module_not_enabled', even when a superadmin explicitly enabled it —
--       eligibility outranks the grant
--   04  an industry allowlist refuses a firm outside it, and admits one inside
--   05  THE QUOTA (c): enable with limit 3, consume 3, prove the 4th is refused
--       'quota_exhausted' and that remaining counts down 2,1,0
--   06  IDEMPOTENCY: the same idem_key consumed twice charges ONCE and reports
--       duplicate=true — a retried send must not spend the merchant's allowance
--   07  PERIOD ROLLOVER: usage in last month does not count against this month,
--       and period_key is the stored v365 Asia/Singapore bucket
--   08  a NULL limit is unlimited and reports remaining as null, never a fake
--       ceiling
--   09  the superadmin setter refuses a non-platform caller (42501) and refuses
--       a stale expected_version (40001)
--   10  the consume path refuses an empty idempotency key
--   11  TENANT ISOLATION: business A's usage never counts against business B
--
-- NOTE on shape: a function that INSERTs is invisible to the SAME statement's
-- snapshot, so every check that calls a writer does so in its own statement.

begin;

create temp table _r(k text, v text) on commit drop;

-- ---------------------------------------------------------------- 01 surface
insert into _r
select '01 surface',
  case when (select bool_and(relrowsecurity) from pg_class
              where oid in ('public.platform_capabilities_v518'::regclass,
                            'public.business_capability_grants_v518'::regclass,
                            'public.capability_usage_v518'::regclass))
        and not has_table_privilege('anon','public.capability_usage_v518','SELECT')
        and not has_table_privilege('authenticated','public.capability_usage_v518','SELECT')
        and not has_table_privilege('authenticated','public.business_capability_grants_v518','INSERT')
        and exists (select 1 from pg_trigger
                     where tgrelid='public.capability_usage_v518'::regclass
                       and tgname='capability_usage_v518_immutable')
       then 'PASS rls on all three, meter append-only, no tenant writes'
       else 'FAIL surface is reachable or mutable' end;

-- Synthetic tenants. is_synthetic keeps them out of any real report.
create temp table _b(tag text primary key, id uuid) on commit drop;
insert into _b values ('nomod', gen_random_uuid()), ('ok', gen_random_uuid()),
                      ('other_industry', gen_random_uuid()), ('isolate', gen_random_uuid());

insert into public.businesses(id, name, slug, industry, enabled_modules)
select id, 'v518 suite ' || tag, 'v518-suite-' || replace(id::text,'-',''),
       case when tag = 'other_industry' then 'fnb' else 'salon' end,
       case when tag = 'nomod' then array['dashboard']::text[]
            else array['dashboard','appointments']::text[] end
from _b;

-- ------------------------------------------------- 02 absence is not permission
create temp table _s(tag text, doc jsonb) on commit drop;
insert into _s select 'ok_before',
  app.capability_state_v518((select id from _b where tag='ok'), 'whatsapp_appointment_notification');

insert into _r
select '02 absence inherits OFF',
  case when doc->>'allowed' = 'false' and doc->>'reason' = 'not_enabled'
        and (doc->>'limit_count')::int = 200 and doc->>'limit_period' = 'month'
       then 'PASS no grant row = registry default = off, with the default limit visible'
       else 'FAIL ' || coalesce(doc->>'reason','<none>') end
from _s where tag='ok_before';

-- ------------------------------- 03 eligibility outranks an explicit grant
insert into public.business_capability_grants_v518(business_id, capability_key, enabled, granted_by)
select id, 'whatsapp_appointment_notification', true, null from _b where tag='nomod';

insert into _s select 'nomod',
  app.capability_state_v518((select id from _b where tag='nomod'), 'whatsapp_appointment_notification');

insert into _r
select '03 module gate outranks the grant',
  case when doc->>'allowed' = 'false' and doc->>'reason' = 'module_not_enabled'
        and doc->'required_modules' ? 'appointments'
       then 'PASS a superadmin ON cannot bypass a missing module'
       else 'FAIL ' || coalesce(doc->>'reason','<none>') end
from _s where tag='nomod';

-- ---------------------------------------------------- 04 industry allowlist
update public.platform_capabilities_v518
   set eligible_industries = array['salon']
 where capability_key = 'whatsapp_appointment_notification';

insert into public.business_capability_grants_v518(business_id, capability_key, enabled, granted_by)
select id, 'whatsapp_appointment_notification', true, null from _b where tag='other_industry';

insert into _s select 'fnb',
  app.capability_state_v518((select id from _b where tag='other_industry'), 'whatsapp_appointment_notification');
insert into _s select 'salon_ok',
  app.capability_state_v518((select id from _b where tag='ok'), 'whatsapp_appointment_notification');

insert into _r
select '04 industry allowlist',
  case when (select doc->>'reason' from _s where tag='fnb') = 'industry_not_eligible'
        and (select doc->>'industry' from _s where tag='fnb') = 'fnb'
        -- the salon firm is still merely 'not_enabled', i.e. it passed eligibility
        and (select doc->>'reason' from _s where tag='salon_ok') = 'not_enabled'
       then 'PASS outside the allowlist refused, inside it passes eligibility'
       else 'FAIL ' || coalesce((select doc->>'reason' from _s where tag='fnb'),'<none>') end;

update public.platform_capabilities_v518
   set eligible_industries = null
 where capability_key = 'whatsapp_appointment_notification';

-- --------------------------------------------------------- 05 the quota
insert into public.business_capability_grants_v518(
  business_id, capability_key, enabled, limit_count, limit_period, granted_by)
select id, 'whatsapp_appointment_notification', true, 3, 'month', null from _b where tag='ok';

create temp table _c(step text, doc jsonb) on commit drop;
insert into _c select 'c1', app.capability_consume_v518((select id from _b where tag='ok'),
  'whatsapp_appointment_notification', 'v518-suite-key-1');
insert into _c select 'c2', app.capability_consume_v518((select id from _b where tag='ok'),
  'whatsapp_appointment_notification', 'v518-suite-key-2');
insert into _c select 'c3', app.capability_consume_v518((select id from _b where tag='ok'),
  'whatsapp_appointment_notification', 'v518-suite-key-3');
insert into _c select 'c4', app.capability_consume_v518((select id from _b where tag='ok'),
  'whatsapp_appointment_notification', 'v518-suite-key-4');

insert into _r
select '05 quota counts down and then refuses',
  case when (select (doc->>'remaining')::int from _c where step='c1') = 2
        and (select (doc->>'remaining')::int from _c where step='c2') = 1
        and (select (doc->>'remaining')::int from _c where step='c3') = 0
        and (select doc->>'consumed' from _c where step='c4') = 'false'
        and (select doc->>'reason' from _c where step='c4') = 'quota_exhausted'
        and (select count(*) from public.capability_usage_v518 u join _b b on b.id=u.business_id
              where b.tag='ok') = 3
       then 'PASS 2,1,0 then refused; exactly 3 usage rows'
       else 'FAIL quota not enforced' end;

-- ------------------------------------------------------ 06 idempotency
insert into _c select 'retry', app.capability_consume_v518((select id from _b where tag='ok'),
  'whatsapp_appointment_notification', 'v518-suite-key-1');

insert into _r
select '06 a retry does not spend the allowance',
  case when (select doc->>'duplicate' from _c where step='retry') = 'true'
        and (select doc->>'consumed' from _c where step='retry') = 'true'
        and (select count(*) from public.capability_usage_v518 u join _b b on b.id=u.business_id
              where b.tag='ok') = 3
       then 'PASS same idem_key charged once, reported duplicate'
       else 'FAIL a retry consumed a second time' end;

-- --------------------------------------------------- 07 period rollover
insert into public.capability_usage_v518(business_id, capability_key, period_key, idem_key)
select id, 'whatsapp_appointment_notification',
       app.v365_period_key('month', now() - interval '40 days'), 'v518-suite-lastmonth'
from _b where tag='ok';

insert into _s select 'rollover',
  app.capability_state_v518((select id from _b where tag='ok'), 'whatsapp_appointment_notification');

insert into _r
select '07 last month does not count against this month',
  case when (select (doc->>'used')::int from _s where tag='rollover') = 3
        and (select doc->>'period_key' from _s where tag='rollover')
          = to_char(timezone('Asia/Singapore', now()), 'YYYY-MM')
       then 'PASS used still 3; period_key is the SGT month bucket'
       else 'FAIL rollover leaked across periods' end;

-- ------------------------------------------------------- 08 unlimited
-- v518a. NULL limit_count means INHERIT (so it resolves to the registry's 200),
-- which is why "unlimited for this firm" needs its own bit. Both states are
-- asserted here, because conflating them was the original defect.
update public.business_capability_grants_v518 set limit_count = null
 where business_id = (select id from _b where tag='ok');

insert into _s select 'inherit',
  app.capability_state_v518((select id from _b where tag='ok'), 'whatsapp_appointment_notification');

update public.business_capability_grants_v518
   set limit_count = null, limit_unlimited = true
 where business_id = (select id from _b where tag='ok');

insert into _s select 'unlimited',
  app.capability_state_v518((select id from _b where tag='ok'), 'whatsapp_appointment_notification');

insert into _r
select '08 inherit and unlimited are different states',
  case when (select (doc->>'limit_count')::int from _s where tag='inherit') = 200
        and (select doc->>'allowed' from _s where tag='unlimited') = 'true'
        and (select doc->'remaining' from _s where tag='unlimited') = 'null'::jsonb
        and (select doc->'limit_count' from _s where tag='unlimited') = 'null'::jsonb
       then 'PASS NULL inherits 200; limit_unlimited reports no ceiling at all'
       else 'FAIL ' || coalesce((select doc::text from _s where tag='unlimited'),'<none>') end;

-- The contradiction must be unstorable, not merely discouraged.
do $$
declare v_code text;
begin
  begin
    update public.business_capability_grants_v518
       set limit_unlimited = true, limit_count = 50
     where business_id = (select id from _b where tag='ok');
    v_code := 'NONE';
  exception when others then v_code := sqlstate;
  end;
  insert into _r values ('08b uncapped and capped is unstorable',
    case when v_code = '23514' then 'PASS check constraint refused the contradiction'
         else 'FAIL a firm could be both uncapped and capped (' || v_code || ')' end);
end $$;

-- --------------------------------------------------- 09 the setter's guards
do $$
declare v_noplat text; v_stale text; v_uid uuid := gen_random_uuid(); v_biz uuid;
begin
  select id into v_biz from _b where tag='ok';
  perform set_config('request.jwt.claim.sub', v_uid::text, true);
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_uid, 'role', 'authenticated')::text, true);
  begin
    perform public.platform_set_capability_grant_v518(
      v_biz, 'whatsapp_appointment_notification', true, 10, 'month', null, 0);
    v_noplat := 'NONE';
  exception when others then v_noplat := sqlstate;
  end;

  -- Now as a real super admin, but with a stale version.
  select user_id into v_uid from public.super_admins order by created_at limit 1;
  perform set_config('request.jwt.claim.sub', coalesce(v_uid::text,''), true);
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_uid, 'role', 'authenticated')::text, true);
  begin
    perform public.platform_set_capability_grant_v518(
      v_biz, 'whatsapp_appointment_notification', true, 10, 'month', null, 0);
    v_stale := 'NONE';
  exception when others then v_stale := sqlstate;
  end;
  perform set_config('request.jwt.claim.sub', '', true);
  perform set_config('request.jwt.claims', '', true);

  insert into _r values ('09 setter guards',
    case when v_noplat = '42501' and v_stale = '40001'
         then 'PASS non-platform 42501, stale version 40001'
         else 'FAIL noplat=' || v_noplat || ' stale=' || v_stale end);
end $$;

-- --------------------------------------------- 10 idempotency key required
do $$
declare v_code text;
begin
  begin
    perform app.capability_consume_v518((select id from _b where tag='ok'),
      'whatsapp_appointment_notification', '   ');
    v_code := 'NONE';
  exception when others then v_code := sqlstate;
  end;
  insert into _r values ('10 idem key required',
    case when v_code = '22023' then 'PASS blank idempotency key refused'
         else 'FAIL consumed without an idempotency key (' || v_code || ')' end);
end $$;

-- ------------------------------------------------- 11 tenant isolation
insert into public.business_capability_grants_v518(
  business_id, capability_key, enabled, limit_count, limit_period, granted_by)
select id, 'whatsapp_appointment_notification', true, 2, 'month', null from _b where tag='isolate';

insert into _s select 'isolate',
  app.capability_state_v518((select id from _b where tag='isolate'), 'whatsapp_appointment_notification');

insert into _r
select '11 tenant isolation',
  case when doc->>'allowed' = 'true' and (doc->>'used')::int = 0 and (doc->>'remaining')::int = 2
       then 'PASS business A''s 4 usage rows do not touch business B'
       else 'FAIL usage leaked across tenants: ' || doc::text end
from _s where tag='isolate';

select k as check_name, v as result from _r order by k;

rollback;
