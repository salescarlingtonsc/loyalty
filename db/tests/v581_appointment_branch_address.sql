-- Rollback-only acceptance for nestly_v581 — a customer's booking row can say where it was.
-- Run: supabase db query --linked -f db/tests/v581_appointment_branch_address.sql
-- Any row whose value starts with FAIL is a failure. Nothing is committed.
--
--   01  the payload carries branch_address at all.
--   02  it is the BRANCH's address, not the business's — a multi-branch firm must not label an
--       Orchard booking with its head office.
--   03  a blank address arrives as NULL, so the row omits the line instead of printing an empty
--       one.
--   04  the function is still gated on a verified customer link, still SECURITY DEFINER, and still
--       keeps its parameter default (dropping it raises 42P13 on the next replace).

begin;

create temp table _r(check_id text, value text) on commit drop;

insert into _r
select '01 the appointments payload carries branch_address',
  case when position('''branch_address'', branch_address' in prosrc) > 0 then 'OK'
       else 'FAIL: customer_get_appointments_page does not return branch_address' end
from pg_proc where proname = 'customer_get_appointments_page' and pronamespace = 'public'::regnamespace;

insert into _r
select '02 the address comes from the branch, not the business',
  case when position('nullif(btrim(br.address)' in prosrc) > 0 then 'OK'
       else 'FAIL: branch_address is not read from public.branches' end
from pg_proc where proname = 'customer_get_appointments_page' and pronamespace = 'public'::regnamespace;

insert into _r
select '03 a blank branch address normalises to NULL',
  case when position('nullif(btrim(br.address), '''')' in prosrc) > 0 then 'OK'
       else 'FAIL: a whitespace-only address would print as an empty line' end
from pg_proc where proname = 'customer_get_appointments_page' and pronamespace = 'public'::regnamespace;

insert into _r
select '04 access and signature are unchanged',
  case when not prosecdef then 'FAIL: no longer SECURITY DEFINER'
       when position('verified customer link required' in prosrc) = 0
         then 'FAIL: the verified-link gate is gone'
       when pg_get_function_arguments(oid) not like '%DEFAULT%'
         then 'FAIL: the p_cursor default was dropped (42P13 territory)'
       else 'OK' end
from pg_proc where proname = 'customer_get_appointments_page' and pronamespace = 'public'::regnamespace;

/* The behavioural proof: read a real customer's own appointments and check the address that comes
   back is the one on that appointment's branch. Skipped with a reason rather than passing
   vacuously when no such booking exists. */
do $flow$
declare
  v_uid uuid; v_slug text; r jsonb; v_expected text; v_got text;
begin
  select cl.auth_user_id, b.slug into v_uid, v_slug
    from public.customer_links cl
    join public.businesses b on b.id = cl.business_id
    join public.appointments a on a.client_id = cl.client_id and a.business_id = cl.business_id
    join public.branches br on br.id = a.branch_id and nullif(btrim(br.address),'') is not null
   where cl.auth_user_id is not null and cl.state = 'verified' and b.slug is not null
   limit 1;

  if v_uid is null then
    insert into _r values ('05 the address returned is the booking''s own branch',
      'SKIPPED: no verified customer has an appointment at a branch with an address on file');
    return;
  end if;

  perform set_config('role','authenticated',true);
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_uid::text, 'role', 'authenticated')::text, true);
  select public.customer_get_appointments_page(v_slug, '{"limit":5}'::jsonb) into r;
  reset role;

  select nullif(btrim(br.address),'') into v_expected
    from public.appointments a
    join public.branches br on br.id = a.branch_id
   where a.id = ((r->'items'->0->>'appointment_id')::uuid);
  v_got := r->'items'->0->>'branch_address';

  insert into _r
  select '05 the address returned is the booking''s own branch',
    case when v_got is not distinct from v_expected then 'OK'
         else 'FAIL: returned ' || coalesce(v_got,'null') || ', branch holds ' || coalesce(v_expected,'null') end;
exception when others then
  reset role;
  insert into _r values ('05 the address returned is the booking''s own branch',
    'FAIL: ' || sqlstate || ' ' || left(sqlerrm, 160));
end
$flow$;

select * from _r order by check_id;

rollback;
