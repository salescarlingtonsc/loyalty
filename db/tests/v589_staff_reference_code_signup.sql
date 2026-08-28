-- Rollback-only acceptance: the staff reference-code sign-up, walked end to end (nestly_v588/v589).
-- Run: supabase db query --linked -f db/tests/v589_staff_reference_code_signup.sql
-- Any value starting FAIL is a failure. Nothing is committed.
--
-- Owner report, pre-go-live 2026-08-29: "even using the reference code to sign up as staff,
-- during sign up process - it is in a mess." This walks the whole journey against a real tenant
-- with the real functions and the real roles: the owner mints a code, opens the screen again,
-- a stranger previews it, a newcomer accepts, previews it again, replays it, somebody else tries
-- to reuse it, the owner approves, and the owner finally rotates it.
--
-- The state assertions deliberately run as the table owner rather than as the newcomer: a
-- teammate parked pending approval cannot SELECT their own staff row, so asserting under their
-- role would measure RLS instead of the write.
begin;
create temp table _r(id text, value text) on commit drop;
grant select, insert, update on all tables in schema pg_temp to authenticated, anon;

-- ── fixture ─────────────────────────────────────────────────────────────────
create temp table _f as
select b.id as biz, b.slug,
       (select s.user_id from public.staff s
         where s.business_id=b.id and s.role='owner' and s.user_id is not null limit 1) as owner_uid,
       (select u.id from auth.users u
         where u.email='qa-golive@example.invalid') as newbie_uid,
       (select u.email from auth.users u where u.email='qa-golive@example.invalid') as newbie_email,
       (select u.id from auth.users u where u.email='qa-frenly-test@example.invalid') as other_uid
from public.businesses b where b.slug='qa-kopi-lab';
grant select, insert, update on all tables in schema pg_temp to authenticated, anon;

insert into _r select '00 fixture',
  case when (select owner_uid from _f) is null then 'FAIL: no owner'
       when (select newbie_uid from _f) is null then 'FAIL: no newbie user'
       when exists(select 1 from public.staff s,_f f where s.business_id=f.biz and s.user_id=f.newbie_uid)
         then 'FAIL: newbie already on this team'
       else 'OK' end;

-- a rota-only teammate the owner wants to give a login to (v11a: user_id nullable)
create temp table _s as
with ins as (
  insert into public.staff(business_id,user_id,role,full_name,active,access_state)
  select biz,null,'staff','V589 Probe Teammate',true,'approved' from _f
  returning id
) select id from ins;
grant select, insert, update on all tables in schema pg_temp to authenticated, anon;

-- ── A01 owner mints a reference code ────────────────────────────────────────
set local role authenticated;
select set_config('request.jwt.claims',
  json_build_object('sub',(select owner_uid from _f),'role','authenticated')::text,true);

create temp table _c1 as
select public.create_staff_reference_code_v217((select biz from _f),(select id from _s),false) as j;
grant select, insert, update on all tables in schema pg_temp to authenticated, anon;

insert into _r select '01 owner mints a reference code',
  case when (j->>'code') is null then 'FAIL: no code returned: '||j::text
       when coalesce((j->>'reused')::boolean,false) then 'FAIL: a first mint reports reuse'
       when (j->>'code') !~ '^[A-Z0-9]{4,32}$' then 'FAIL: unusable code shape '||(j->>'code')
       else 'OK code='||(j->>'code') end from _c1;

-- ── A02 opening the screen again must NOT kill the live code (v588) ─────────
create temp table _c2 as
select public.create_staff_reference_code_v217((select biz from _f),(select id from _s),false) as j;
grant select, insert, update on all tables in schema pg_temp to authenticated, anon;

insert into _r select '02 re-opening returns the SAME live code, marked reused',
  case when (select j->>'code' from _c2) is distinct from (select j->>'code' from _c1)
         then 'FAIL: code changed under the teammate ('||(select j->>'code' from _c1)||' -> '||(select j->>'code' from _c2)||')'
       when coalesce((select (j->>'reused')::boolean from _c2),false) is not true
         then 'FAIL: reuse not reported'
       else 'OK' end;

insert into _r select '02b exactly one pending invite exists for that teammate',
  case when count(*)=1 then 'OK' else 'FAIL: '||count(*)||' pending invites' end
from public.staff_invites i,_f f where i.business_id=f.biz and i.staff_id=(select id from _s) and i.status='pending';

-- ── A03 the sign-up screen previews it before anyone signs in ───────────────
reset role; select set_config('request.jwt.claims',NULL,true);
set local role anon;
create temp table _p1 as select public.preview_staff_invite((select j->>'code' from _c1)) as j;
grant select, insert, update on all tables in schema pg_temp to authenticated, anon;
insert into _r select '03 anon preview names the business and the role',
  case when (j->>'status') <> 'valid' then 'FAIL: status='||coalesce(j->>'status','null')||' '||j::text
       when coalesce(j->>'business_name','')='' then 'FAIL: preview does not name the business'
       when coalesce(j->>'role','')='' then 'FAIL: preview does not name the role'
       else 'OK '||(j->>'business_name')||'/'||(j->>'role') end from _p1;

-- ── A04 the newcomer accepts ────────────────────────────────────────────────
reset role; set local role authenticated;
select set_config('request.jwt.claims',
  json_build_object('sub',(select newbie_uid from _f),'role','authenticated',
                    'email',(select newbie_email from _f))::text,true);
create temp table _a1 as select public.accept_invite((select j->>'code' from _c1)) as j;
grant select, insert, update on all tables in schema pg_temp to authenticated, anon;

insert into _r select '04 accept lands with a business to open, not a dead end',
  case when (j->>'status') <> 'awaiting_approval' then 'FAIL: status='||coalesce(j->>'status','null')
       when coalesce(j->>'business_slug','')='' then 'FAIL: no business_slug — the app cannot navigate'
       when coalesce(j->>'business_name','')='' then 'FAIL: no business_name'
       when coalesce(j->>'message','')='' then 'FAIL: no message for the toast'
       else 'OK '||(j->>'business_slug') end from _a1;

reset role;
insert into _r select '04b the rota-only teammate now owns that login, parked for approval',
  case when count(*)=1 then 'OK' else 'FAIL: '||count(*)||' rows' end
from public.staff s,_f f
where s.id=(select id from _s) and s.user_id=f.newbie_uid and s.access_state='pending';

insert into _r select '04c no duplicate staff row was created',
  case when count(*)=1 then 'OK' else 'FAIL: '||count(*)||' staff rows for the newcomer' end
from public.staff s,_f f where s.business_id=f.biz and s.user_id=f.newbie_uid;

-- ── A05 previewing the code after acceptance is not "invalid" (v588) ────────
reset role; select set_config('request.jwt.claims',NULL,true); set local role anon;
create temp table _p2 as select public.preview_staff_invite((select j->>'code' from _c1)) as j;
grant select, insert, update on all tables in schema pg_temp to authenticated, anon;
insert into _r select '05 a waiting teammate''s code previews as awaiting_approval',
  case when (j->>'status')='awaiting_approval' then 'OK'
       when (j->>'status')='invalid' then 'FAIL: their own code reads as invalid (the v588 bug)'
       else 'FAIL: status='||coalesce(j->>'status','null') end from _p2;

-- ── A06 the same person re-submitting is a replay, not an accusation ────────
reset role; set local role authenticated;
select set_config('request.jwt.claims',
  json_build_object('sub',(select newbie_uid from _f),'role','authenticated',
                    'email',(select newbie_email from _f))::text,true);
create temp table _a2 as select public.accept_invite((select j->>'code' from _c1)) as j;
grant select, insert, update on all tables in schema pg_temp to authenticated, anon;
insert into _r select '06 same-user replay repeats the answer instead of refusing',
  case when coalesce((j->>'replayed')::boolean,false) is not true then 'FAIL: not marked replayed'
       when (j->>'status')<>'awaiting_approval' then 'FAIL: status='||coalesce(j->>'status','null')
       when coalesce(j->>'business_slug','')='' then 'FAIL: replay lost the business'
       else 'OK' end from _a2;

-- ── A07 somebody else's reuse still refuses, verbatim ───────────────────────
do $$
declare v_msg text; v_uid uuid;
begin
  select other_uid into v_uid from _f;
  perform set_config('request.jwt.claims',
    json_build_object('sub',v_uid,'role','authenticated','email','qa-frenly-test@example.invalid')::text,true);
  begin
    perform public.accept_invite((select j->>'code' from _c1));
    v_msg:='FAIL: a stranger reused a spent code';
  exception when others then
    v_msg:=case when sqlerrm like '%already been used%' then 'OK' else 'FAIL: wrong refusal: '||sqlerrm end;
  end;
  insert into _r values('07 a spent code still refuses a different person', v_msg);
end $$;

-- ── A08 owner approves; the replay flips to "open the workspace" ────────────
select set_config('request.jwt.claims',
  json_build_object('sub',(select owner_uid from _f),'role','authenticated')::text,true);
reset role;
update public.staff set access_state='approved' where id=(select id from _s);
set local role authenticated;
select set_config('request.jwt.claims',
  json_build_object('sub',(select newbie_uid from _f),'role','authenticated',
                    'email',(select newbie_email from _f))::text,true);
create temp table _a3 as select public.accept_invite((select j->>'code' from _c1)) as j;
grant select, insert, update on all tables in schema pg_temp to authenticated, anon;
insert into _r select '08 once approved, the same code opens the workspace',
  case when (j->>'status')<>'approved' then 'FAIL: status='||coalesce(j->>'status','null')
       when coalesce(j->>'business_slug','')='' then 'FAIL: nowhere to go'
       else 'OK '||(j->>'message') end from _a3;

-- ── A09 rotation is the only thing that kills a code ───────────────────────
select set_config('request.jwt.claims',
  json_build_object('sub',(select owner_uid from _f),'role','authenticated')::text,true);
create temp table _s2 as
select id from public.staff where id=(select id from _s);
grant select, insert, update on all tables in schema pg_temp to authenticated, anon;
reset role;
insert into public.staff(business_id,user_id,role,full_name,active,access_state)
select biz,null,'staff','V589 Probe Teammate 2',true,'approved' from _f;
set local role authenticated;
create temp table _c3 as
select public.create_staff_reference_code_v217((select biz from _f),
  (select id from public.staff where full_name='V589 Probe Teammate 2'),false) as j;
grant select, insert, update on all tables in schema pg_temp to authenticated, anon;
create temp table _c4 as
select public.create_staff_reference_code_v217((select biz from _f),
  (select id from public.staff where full_name='V589 Probe Teammate 2'),true) as j;
grant select, insert, update on all tables in schema pg_temp to authenticated, anon;
insert into _r select '09 rotate mints a new code and revokes the old one',
  case when (select j->>'code' from _c4)=(select j->>'code' from _c3) then 'FAIL: rotate returned the same code'
       when not exists(select 1 from public.staff_invites where code=(select j->>'code' from _c3) and status='revoked')
         then 'FAIL: the old code was not revoked'
       else 'OK' end;

reset role; select set_config('request.jwt.claims',NULL,true);
select id, value from _r order by id;
rollback;
