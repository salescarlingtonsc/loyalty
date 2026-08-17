-- Rollback-only acceptance for v385 — the Business Profile save, and industry_label.
--   supabase db query --linked -f db/tests/v385_profile_save_and_industry_label.sql
-- Any row whose result starts with FAIL is a failure. Nothing is committed.
--
-- The check that matters is 03: before v385 that exact UPDATE raised
--   42501 permission denied for function v311_match_merchants
-- for EVERY owner on the platform, because v313's businesses trigger calls a function no client
-- role may execute and the trigger function was not SECURITY DEFINER.

begin;

create temp table _r(k text, v text) on commit drop;
create temp table _c(biz uuid, owner uuid, slug text) on commit drop;
grant select,insert,update,delete on _r,_c to authenticated;
insert into _c(slug) values ('zz-v385-'||substr(md5(random()::text),1,8));

-- A firm with a real owner login, so the RLS path under test is the production one.
with i as (insert into public.businesses(name,slug,industry,enabled_modules)
  select 'ZZ V385',slug,'facial',array['appointments'] from _c returning id)
update _c set biz=(select id from i);
update _c set owner=(select id from auth.users order by created_at limit 1);
insert into public.staff(business_id,user_id,full_name,role,active,access_state)
  select biz,owner,'ZZ V385 owner','owner',true,'approved' from _c;

-- app.is_salon_owner also demands an OPEN workspace (app.business_workspace_open_v94), which a
-- freshly seeded firm does not have. Same approval fixture the v107 suite uses.
update public.business_workspace_controls_v94
   set approval_status='approved', version=version+1,
       decided_at=statement_timestamp(),
       decision_reason='approved synthetic rollback fixture',
       updated_at=statement_timestamp()
 where business_id=(select biz from _c);

-- 01 the trigger function runs as its definer
insert into _r select '01 trigger security definer',
  case when p.prosecdef then 'PASS' else 'FAIL not security definer' end
  from pg_proc p join pg_namespace n on n.oid=p.pronamespace
 where n.nspname='app' and p.proname='v311_on_business_merchant_link';

-- 02 and the matcher is still closed to every client role
insert into _r select '02 matcher not client-callable',
  case when has_function_privilege('authenticated','app.v311_match_merchants(uuid)','execute')
         or has_function_privilege('anon','app.v311_match_merchants(uuid)','execute')
       then 'FAIL a client role can call the matcher' else 'PASS' end;

-- 03 THE BUG: an owner saves their own Business Profile, as the owner, through RLS
select set_config('request.jwt.claims',
  json_build_object('sub',(select owner from _c),'role','authenticated')::text, true);
set local role authenticated;
do $$
declare v_rows int;
begin
  update public.businesses
     set name='ZZ V385 renamed', legal_name='ZZ V385 PTE. LTD.',
         industry='facial', industry_label='Facial studio'
   where id=(select biz from _c);
  get diagnostics v_rows = row_count;
  -- An UPDATE that RLS filters to nothing raises NOTHING, so a bare "no exception" is not a
  -- pass. The row count is what proves the owner's save actually landed.
  insert into _r values ('03 owner saves profile',
    case when v_rows=1 then 'PASS' else 'FAIL policy filtered the update to '||v_rows||' rows' end);
exception when others then
  insert into _r values ('03 owner saves profile','FAIL '||SQLSTATE||' '||SQLERRM);
end $$;
insert into _r select '03b uid matches the fixture owner',
  case when auth.uid()=(select owner from _c) then 'PASS' else 'FAIL uid is '||coalesce(auth.uid()::text,'null') end;
reset role;

-- 04 the wording was actually stored
insert into _r select '04 industry_label stored',
  case when (select industry_label from public.businesses where id=(select biz from _c))='Facial studio'
       then 'PASS' else 'FAIL not stored' end;

-- 05 blank-but-present wording is refused; NULL is the way to say "use the sector"
do $$
begin
  update public.businesses set industry_label='   ' where id=(select biz from _c);
  insert into _r values ('05 blank wording refused','FAIL a whitespace-only label was accepted');
exception when check_violation then
  insert into _r values ('05 blank wording refused','PASS');
end $$;

-- 06 over-length wording is refused
do $$
begin
  update public.businesses set industry_label=repeat('x',61) where id=(select biz from _c);
  insert into _r values ('06 over-length wording refused','FAIL 61 characters were accepted');
exception when check_violation then
  insert into _r values ('06 over-length wording refused','PASS');
end $$;

-- 07 a staff member who is not the owner still cannot save the profile
insert into public.staff(business_id,user_id,full_name,role,active,access_state)
  select biz,(select id from auth.users where id<>(select owner from _c) order by created_at limit 1),
         'ZZ V385 staff','staff',true,'approved' from _c;
select set_config('request.jwt.claims',
  json_build_object('sub',(select user_id from public.staff where business_id=(select biz from _c) and role='staff'),
                    'role','authenticated')::text, true);
set local role authenticated;
do $$
declare v_rows int;
begin
  update public.businesses set name='ZZ V385 by staff' where id=(select biz from _c);
  get diagnostics v_rows = row_count;
  insert into _r values ('07 non-owner cannot save',
    case when v_rows=0 then 'PASS' else 'FAIL a non-owner updated the row' end);
exception when others then
  insert into _r values ('07 non-owner cannot save','PASS refused: '||SQLSTATE);
end $$;
reset role;

-- 08 the customer read carries the new key
insert into _r select '08 summary emits industry_label',
  case when position('industry_label' in
        pg_get_functiondef('public.customer_get_business_summary(text)'::regprocedure))>0
       then 'PASS' else 'FAIL key missing from the customer summary' end;

select k, v from _r order by k;

rollback;
