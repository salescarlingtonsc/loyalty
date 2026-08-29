-- Rollback-only acceptance for nestly_v593 — a prepaid package can be given a life.
-- Run: supabase db query --linked -f db/tests/v593_package_expiry.sql
-- Any row whose value starts with FAIL is a failure. Nothing is committed.
--
--   01  the two columns and the plan constraint exist
--   02  save_package_plan_v102 has ONE signature and it takes p_expiry_days (no PGRST203 twin)
--   03  the deadline helper is SGT end-of-day, and is what the sale calls
--   04  use_package_session_v102 refuses an expired package with its own error
--   05  the two read paths agree: the list derives 'expired', the till withholds it
--   06  no package sold before this migration gained a deadline
--   07  behavioural, as a real owner: save a plan with 30 days, sell it, and read the deadline
--   08  behavioural: a package whose window has closed is refused at use time, and one whose
--       window is open is still used normally

begin;

create temp table _r(check_id text, value text) on commit drop;

insert into _r
select '01 columns and constraint',
  case when (select count(*) from information_schema.columns
              where table_schema='public' and table_name='package_plans'
                and column_name='expiry_days')=0 then 'FAIL: package_plans.expiry_days missing'
       when (select count(*) from information_schema.columns
              where table_schema='public' and table_name='client_packages'
                and column_name in ('expires_at','expiry_days_snapshot'))<>2
         then 'FAIL: client_packages expiry columns missing'
       when (select count(*) from pg_constraint
              where conname='package_plans_expiry_days_ck')=0
         then 'FAIL: the 1..3650 constraint is gone — 0 days would sell a dead package'
       else 'OK' end;

insert into _r
select '02 exactly one save_package_plan_v102, taking p_expiry_days',
  case when count(*)<>1 then 'FAIL: '||count(*)||' overloads — PGRST203 would block every package save'
       when max(case when pg_get_function_arguments(oid) like '%p_expiry_days%' then 1 else 0 end)=0
         then 'FAIL: the surviving signature cannot carry an expiry'
       else 'OK' end
from pg_proc where proname='save_package_plan_v102' and pronamespace='public'::regnamespace;

insert into _r
select '03 the deadline is SGT end-of-day and the sale uses the helper',
  case when (select count(*) from pg_proc
              where proname='package_expires_at_v593' and pronamespace='app'::regnamespace)=0
         then 'FAIL: app.package_expires_at_v593 missing'
       when (select position('package_expires_at_v593' in prosrc) from pg_proc
              where proname='sell_package_v102' and pronamespace='public'::regnamespace)=0
         then 'FAIL: the sale re-derives the deadline instead of calling the one definition'
       when app.package_expires_at_v593('2026-09-01 03:00+08'::timestamptz, 30)
            <> '2026-10-02 00:00+08'::timestamptz - interval '1 microsecond'
         then 'FAIL: 1 Sep + 30 days is not usable through all of 1 Oct SGT'
       when app.package_expires_at_v593(now(), null) is not null
         then 'FAIL: NULL days must mean never expires'
       else 'OK' end;

insert into _r
select '04 an expired package is refused with its own error',
  case when position('package_expired' in prosrc)=0
         then 'FAIL: use_package_session_v102 would still deduct a session after the deadline'
       when position('package_has_no_sessions' in prosrc)=0
         then 'FAIL: the sessions-exhausted guard was lost'
       else 'OK' end
from pg_proc where proname='use_package_session_v102' and pronamespace='public'::regnamespace;

insert into _r
select '05 both read paths know about the deadline',
  case when (select position('''expired''' in prosrc) from pg_proc
              where proname='staff_list_package_entitlements_v102' and pronamespace='public'::regnamespace)=0
         then 'FAIL: the Packages list cannot show an expired package as expired'
       when (select position('expires_at is null or customer_package.expires_at >= now()' in prosrc)
               from pg_proc where proname='staff_get_customer_entitlements_v102'
                and pronamespace='public'::regnamespace)=0
         then 'FAIL: the till would still offer a session it is about to refuse'
       else 'OK' end;

-- Additive, not retroactive: a deadline exists exactly when the terms sold carried one, so no
-- package sold before this migration (every one of which has a NULL snapshot) gains a date.
insert into _r
select '06 a deadline exists only where the terms sold one',
  case when count(*)=0 then 'OK'
       else 'FAIL: '||count(*)||' client_packages row(s) disagree with their own expiry snapshot' end
from public.client_packages
where (expiry_days_snapshot is null) <> (expires_at is null);

/* Behavioural. As a real owner of a real tenant (impersonated for this rolled-back transaction
   only), design a 30-day package, sell it, and prove the deadline is stamped, honoured, and
   enforced. Nothing is committed, so the sale and the session both disappear at rollback. */
do $flow$
declare
  v_biz uuid; v_owner uuid; v_client uuid; v_branch uuid;
  v_plan public.package_plans%rowtype;
  v_sale jsonb; v_pkg public.client_packages%rowtype; v_use jsonb;
  v_r7 text; v_r8 text;
begin
  select s.business_id, s.user_id into v_biz, v_owner
  from public.staff s
  join public.branches b on b.business_id=s.business_id and b.active
  join public.clients c on c.business_id=s.business_id
  where s.role='owner' and s.active and s.user_id is not null
    and exists(select 1 from public.businesses bus
                where bus.id=s.business_id
                  and 'packages'=any(coalesce(bus.enabled_modules,'{}'::text[])))
  limit 1;
  if v_biz is null then
    insert into _r values('07 behavioural: design and sell','SKIP: no tenant with packages, a branch, a customer and an owner login');
    insert into _r values('08 behavioural: expiry is enforced','SKIP: same');
    return;
  end if;
  select id into v_client from public.clients where business_id=v_biz order by created_at limit 1;
  select id into v_branch from public.branches where business_id=v_biz and active order by is_default desc, id limit 1;

  /* Impersonate the real owner ONLY across the RPC calls. The temp result table belongs to the
     superuser session, so the role is handed back before every write to it — running the whole
     block as `authenticated` is what "permission denied for table _r" meant on the first pass. */
  perform set_config('request.jwt.claims',
    json_build_object('sub',v_owner,'role','authenticated')::text, true);

  set local role authenticated;
  select * into v_plan from public.save_package_plan_v102(
    v_biz, null, 'v593 rolled-back probe', 1000, 3, null, true, 30);
  v_sale := public.sell_package_v102(v_biz, v_client, v_plan.id, v_branch, gen_random_uuid());
  reset role;

  select * into v_pkg from public.client_packages
   where id=(v_sale->>'client_package_id')::uuid;

  v_r7 := case when v_plan.expiry_days<>30 then 'FAIL: the plan did not keep 30 days'
               when v_pkg.expiry_days_snapshot<>30 then 'FAIL: the sale did not snapshot the term'
               when v_pkg.expires_at is distinct from app.package_expires_at_v593(v_pkg.purchased_at,30)
                 then 'FAIL: the stamped deadline is not N SGT days after the purchase date'
               else 'OK' end;
  insert into _r values('07 behavioural: design and sell', v_r7);

  -- Open window: the session is used normally.
  set local role authenticated;
  v_use := public.use_package_session_v102(v_biz, v_pkg.id, v_branch, 'v593probe-open-'||v_pkg.id::text);
  reset role;
  if (v_use->>'remaining_after')::int <> 2 then
    insert into _r values('08 behavioural: expiry is enforced','FAIL: a package inside its window could not be used');
    return;
  end if;

  -- Closed window: same package, deadline moved into the past.
  update public.client_packages set expires_at=now()-interval '1 day' where id=v_pkg.id;
  begin
    set local role authenticated;
    v_use := public.use_package_session_v102(v_biz, v_pkg.id, v_branch, 'v593probe-closed-'||v_pkg.id::text);
    reset role;
    v_r8 := 'FAIL: an expired package still paid out a session';
  exception when others then
    reset role;
    v_r8 := case when sqlerrm like '%package_expired%' then 'OK'
                 else 'FAIL: refused, but not as package_expired — '||sqlerrm end;
  end;
  insert into _r values('08 behavioural: expiry is enforced', v_r8);
exception when others then
  reset role;
  insert into _r values('07 behavioural: design and sell','FAIL: raised — '||sqlerrm);
end
$flow$;

reset role;
select check_id, value from _r order by check_id;

rollback;
