-- Rollback-only acceptance for v386 — a window on the programme-usage read.
--   supabase db query --linked -f db/tests/v386_dated_programme_usage.sql
-- Any row whose result starts with FAIL is a failure. Nothing is committed.
--
-- Check 03 is the one that protects everybody else: an unbounded v386 call must return exactly
-- what v271 returns, byte for byte. If that ever drifts, the resting card silently changed its
-- figures without anyone asking it to.

begin;

create temp table _r(k text, v text) on commit drop;
create temp table _c(biz uuid, owner uuid, client_a uuid, client_b uuid, prog uuid, slug text) on commit drop;
grant select,insert,update,delete on _r,_c to authenticated;
insert into _c(slug) values ('zz-v386-'||substr(md5(random()::text),1,8));

with i as (insert into public.businesses(name,slug,industry,enabled_modules)
  select 'ZZ V386',slug,'facial',array['loyalty'] from _c returning id)
update _c set biz=(select id from i);
update _c set owner=(select id from auth.users order by created_at limit 1);
insert into public.staff(business_id,user_id,full_name,role,active,access_state)
  select biz,owner,'ZZ V386 owner','owner',true,'approved' from _c;
update public.business_workspace_controls_v94
   set approval_status='approved', version=version+1, decided_at=statement_timestamp(),
       decision_reason='approved synthetic rollback fixture', updated_at=statement_timestamp()
 where business_id=(select biz from _c);

-- Two referrers who qualified on two different Singapore days.
--
-- Referrals, not points, because points_ledger is append-guarded (app.loyalty_ledger_write_guard
-- admits only the eight approved loyalty routes) and forging a row through that handshake would
-- be testing the fixture rather than the window. Referrals carry the same shape the window cares
-- about — one timestamp per customer per programme — and check 03 below pins the points path by
-- proving the unbounded read is still byte-identical to v271.
insert into public.referral_programs(business_id) select biz from _c;

with a as (insert into public.clients(business_id,full_name) select biz,'ZZ A' from _c returning id)
update _c set client_a=(select id from a);
with b as (insert into public.clients(business_id,full_name) select biz,'ZZ B' from _c returning id)
update _c set client_b=(select id from b);

insert into public.referrals(business_id, referrer_client_id, qualified_at)
  select biz, client_a, '2026-08-10 09:00:00+08' from _c;
insert into public.referrals(business_id, referrer_client_id, qualified_at)
  select biz, client_b, '2026-08-20 09:00:00+08' from _c;

select set_config('request.jwt.claims',
  json_build_object('sub',(select owner from _c),'role','authenticated')::text, true);
set local role authenticated;

-- 01 both referrers are visible with no window at all
insert into _r select '01 unbounded counts both',
  case when (public.business_programme_usage_v386((select biz from _c))->'referrals'->>'customers')='2'
       then 'PASS' else 'FAIL got '||coalesce((public.business_programme_usage_v386((select biz from _c))->'referrals'->>'customers'),'null') end;

-- 02 a window that contains only the first qualification counts only that referrer
insert into _r select '02 window narrows to one',
  case when (public.business_programme_usage_v386((select biz from _c),'2026-08-01','2026-08-15')->'referrals'->>'customers')='1'
       then 'PASS' else 'FAIL got '||coalesce((public.business_programme_usage_v386((select biz from _c),'2026-08-01','2026-08-15')->'referrals'->>'customers'),'null') end;

-- 03 THE CONTRACT: unbounded v386 is v271, exactly. `as_of` is now() on both calls and `window`
--    is new, so those two keys are removed before comparing; everything else must be identical.
insert into _r select '03 unbounded equals v271',
  case when ((public.business_programme_usage_v386((select biz from _c)) - 'as_of' - 'window')
           = (public.business_programme_usage_v271((select biz from _c)) - 'as_of'))
       then 'PASS' else 'FAIL the windowless read drifted from v271' end;

-- 04 the window boundary is the whole Singapore day, not a slice of it. The 10 Aug qualification
--    is at 09:00 SGT; a To of exactly 2026-08-10 must still include it.
insert into _r select '04 To includes its whole SGT day',
  case when (public.business_programme_usage_v386((select biz from _c),'2026-08-10','2026-08-10')->'referrals'->>'customers')='1'
       then 'PASS' else 'FAIL the last day of the window was cut short' end;

-- 05 a window before the first qualification contains nobody — and says 0, because referrals
--    ARE measured here; only an unmeasurable programme may answer null
insert into _r select '05 empty window is 0, not null',
  case when (public.business_programme_usage_v386((select biz from _c),'2026-08-01','2026-08-02')->'referrals'->>'customers')='0'
       then 'PASS' else 'FAIL an empty measured window did not answer 0' end;

-- 06 the honesty rule survives the window: a promotion is still unmeasured, never a zero
insert into _r select '06 unmeasured stays null',
  case when (public.business_programme_usage_v386((select biz from _c),'2026-08-01','2026-08-31')->'promotions'->'customers') = 'null'::jsonb
       then 'PASS' else 'FAIL an unmeasurable programme reported a number' end;

-- 07 a backwards window is refused rather than answered with 0
do $$
begin
  perform public.business_programme_usage_v386((select biz from _c),'2026-08-31','2026-08-01');
  insert into _r values ('07 backwards window refused','FAIL it answered instead of refusing');
exception when others then
  insert into _r values ('07 backwards window refused',
    case when SQLSTATE='22023' then 'PASS' else 'FAIL wrong error '||SQLSTATE end);
end $$;

-- 08 the echoed window is what the SERVER used
insert into _r select '08 window echoed back',
  case when (public.business_programme_usage_v386((select biz from _c),'2026-08-01','2026-08-15')->'window'->>'from')='2026-08-01'
        and (public.business_programme_usage_v386((select biz from _c),'2026-08-01','2026-08-15')->'window'->>'to')='2026-08-15'
       then 'PASS' else 'FAIL' end;
reset role;

-- 09 a stranger to this firm cannot read its usage at all, windowed or not
select set_config('request.jwt.claims',
  json_build_object('sub',(select id from auth.users where id<>(select owner from _c) order by created_at limit 1),
                    'role','authenticated')::text, true);
set local role authenticated;
do $$
begin
  perform public.business_programme_usage_v386((select biz from _c),'2026-08-01','2026-08-31');
  insert into _r values ('09 outsider refused','FAIL a non-member read another firm''s usage');
exception when others then
  insert into _r values ('09 outsider refused',
    case when SQLSTATE='42501' then 'PASS' else 'FAIL wrong error '||SQLSTATE end);
end $$;
reset role;

-- 10 anon holds no execute on either overload
insert into _r select '10 anon cannot execute',
  case when has_function_privilege('anon','public.business_programme_usage_v386(uuid,date,date)','execute')
         or has_function_privilege('anon','public.business_programme_usage_v271(uuid)','execute')
       then 'FAIL anon can read programme usage' else 'PASS' end;

select k, v from _r order by k;

rollback;
