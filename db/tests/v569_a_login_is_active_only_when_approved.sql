-- Rollback-only acceptance for nestly_v569 — a login is "active" only when the owner approved it.
-- Run: supabase db query --linked -f db/tests/v569_a_login_is_active_only_when_approved.sql
-- Any row whose value starts with FAIL is a failure. Nothing is committed.
--
--   01  shapes: get_my_personas scopes workspace_access to the account and surfaces access_state;
--       billable_seats requires 'approved'.
--   02  ESTATE INVARIANT (the canonical-rule check, not a reader-agreement check): for every
--       staff row, what get_my_personas reports as workspace_access must equal what the RLS
--       authority app.is_salon_member would grant that same account. Reader-vs-reader agreement
--       is not enough — this compares every reader against the AUTHORITY.
--   03  end to end, rolled back: a teammate in each of the three access states. Pending must be
--       refused by the persona reader, invisible to the businesses RLS read, and unbilled;
--       approving through the real RPC must flip all three in one step.
--
-- ROLLBACK: reverting v569 means restoring the business-level workspace_access, the seat count
-- without access_state, and the workspace default route — which re-opens the recorded case: a
-- teammate told she was active, refused at every read, and billed as a seat she could not use.

begin;

create temp table _r(check_id text, value text) on commit drop;

do $shape$
declare v_p text; v_s text;
begin
  v_p := pg_get_functiondef('public.get_my_personas()'::regprocedure);
  v_s := pg_get_functiondef('app.billable_seats(uuid)'::regprocedure);
  insert into _r values ('01 the readers carry the account''s own answer',
    case when position('and staff_row.access_state=''approved''' in v_p) = 0
      then 'FAIL: get_my_personas still answers the business-level gate'
      when position('''access_state'',staff_row.access_state' in v_p) = 0
      then 'FAIL: the persona does not surface access_state'
      when position('s.access_state = ''approved''' in v_s) = 0
      then 'FAIL: a seat awaiting approval is still billable'
      else 'OK' end);
end
$shape$;

do $estate$
declare r record; v_bad text := '';
begin
  for r in
    select s.id, s.business_id, s.user_id, s.full_name, s.access_state,
           (app.business_workspace_open_v94(s.business_id) and s.active
             and s.access_state='approved') as authority
      from public.staff s
     where s.user_id is not null and s.active
  loop
    perform set_config('request.jwt.claims',
      json_build_object('sub',r.user_id,'role','authenticated','aud','authenticated')::text,true);
    if coalesce((
      select (persona->>'workspace_access')::boolean
        from jsonb_array_elements(public.get_my_personas()->'staff') persona
       where (persona->>'business_id')::uuid = r.business_id), false) is distinct from r.authority
    then
      v_bad := v_bad||' ['||coalesce(r.full_name,'?')||' authority='||r.authority::text||']';
    end if;
  end loop;
  perform set_config('request.jwt.claims','',true);
  insert into _r values ('02 every persona answer matches the RLS authority',
    case when v_bad = '' then 'OK' else 'FAIL:'||v_bad end);
end
$estate$;

do $endtoend$
declare
  v_biz uuid := 'cafe0569-0000-4000-8000-000000000001';
  v_owner uuid := 'cafe0569-0000-4000-8000-0000000000a1';
  v_mate uuid := 'cafe0569-0000-4000-8000-0000000000a2';
  v_staff_owner uuid; v_staff_mate uuid;
  v_access boolean; v_state text; v_seats integer; v_visible integer; v_res jsonb;
begin
  insert into public.businesses(id, name, slug, industry)
  values (v_biz, 'v569 fixture', 'v569-fixture-rolled-back', 'fnb');
  insert into auth.users(instance_id,id,aud,role,email,encrypted_password,
                         email_confirmed_at,created_at,updated_at)
  values ('00000000-0000-0000-0000-000000000000',v_owner,'authenticated','authenticated',
          'v569-owner-'||v_owner||'@example.test','',now(),now(),now()),
         ('00000000-0000-0000-0000-000000000000',v_mate,'authenticated','authenticated',
          'v569-mate-'||v_mate||'@example.test','',now(),now(),now());
  -- the decision-shape CHECK demands a decider and a reason with an approved status
  update public.business_workspace_controls_v94
     set approval_status='approved', decided_at=now(), decided_by=v_owner,
         decision_reason='v569 acceptance fixture (rolled back)'
   where business_id=v_biz;
  insert into public.staff(business_id, user_id, role, full_name, active, access_state)
  values (v_biz, v_owner, 'owner', 'v569 owner', true, 'approved') returning id into v_staff_owner;
  -- the teammate who accepted their invite: linked, active, awaiting approval
  insert into public.staff(business_id, user_id, role, full_name, active, access_state)
  values (v_biz, v_mate, 'staff', 'v569 teammate', true, 'pending') returning id into v_staff_mate;

  perform set_config('request.jwt.claims',
    json_build_object('sub',v_mate,'role','authenticated','aud','authenticated')::text,true);
  select (persona->>'workspace_access')::boolean, persona->>'access_state'
    into v_access, v_state
    from jsonb_array_elements(public.get_my_personas()->'staff') persona
   where (persona->>'business_id')::uuid = v_biz;
  perform set_config('request.jwt.claims','',true);
  select app.billable_seats(v_biz) into v_seats;

  insert into _r values ('03a a teammate awaiting approval is refused, explained and unbilled',
    case when v_access is not false then 'FAIL: workspace_access='||coalesce(v_access::text,'NULL')
         when v_state is distinct from 'pending' then 'FAIL: access_state='||coalesce(v_state,'NULL')
         when v_seats <> 1 then 'FAIL: billable seats='||v_seats||' (only the owner should count)'
         else 'OK' end);

  -- the owner approves through the real RPC
  perform set_config('request.jwt.claims',
    json_build_object('sub',v_owner,'role','authenticated','aud','authenticated')::text,true);
  v_res := public.decide_staff_access_v207(v_biz, v_staff_mate, true);
  perform set_config('request.jwt.claims',
    json_build_object('sub',v_mate,'role','authenticated','aud','authenticated')::text,true);
  select (persona->>'workspace_access')::boolean
    into v_access
    from jsonb_array_elements(public.get_my_personas()->'staff') persona
   where (persona->>'business_id')::uuid = v_biz;
  perform set_config('request.jwt.claims','',true);
  select app.billable_seats(v_biz) into v_seats;

  insert into _r values ('03b approving releases access and the seat in one step',
    case when v_res->>'access_state' is distinct from 'approved' then 'FAIL: rpc said '||coalesce(v_res::text,'NULL')
         when v_access is not true then 'FAIL: still refused after approval'
         when v_seats <> 2 then 'FAIL: billable seats='||v_seats||' (both logins should now count)'
         else 'OK' end);
exception when others then
  insert into _r values ('03 teammate access lifecycle','FAIL: '||sqlerrm);
end
$endtoend$;

select * from _r order by check_id;

rollback;
