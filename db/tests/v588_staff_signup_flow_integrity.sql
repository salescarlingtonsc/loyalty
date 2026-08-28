-- Rollback-only acceptance for nestly_v588 — the staff sign-up flow stops contradicting itself.
-- Run: supabase db query --linked -f db/tests/v588_staff_signup_flow_integrity.sql
-- Any row whose value starts with FAIL is a failure. Nothing is committed.
--
--   01  accept_invite replays for the SAME user instead of refusing, and now names the business.
--   02  every original refusal for a DIFFERENT user is byte-preserved.
--   03  preview_staff_invite knows 'awaiting_approval' and no longer calls that code invalid.
--   04  create_staff_reference_code_v217 returns the live code instead of killing it; p_rotate
--       is the only path that revokes; exactly ONE overload exists (PGRST203 guard).
--   05  grants: anon can still preview, only authenticated may accept or mint.
--   06  behavioural replay: the accepted Jess Salon invite answers its own accepter again.

begin;

create temp table _r(check_id text, value text) on commit drop;

insert into _r
select '01 same-user replay returns the answer again, with the business named',
  case when position('inv.accepted_user_id = auth.uid()' in prosrc) = 0
         then 'FAIL: no same-user replay branch'
       when position('''replayed'', true' in prosrc) = 0
         then 'FAIL: a replay is not marked as one'
       when position('''business_slug'', b.slug' in prosrc) = 0
         then 'FAIL: the reply still cannot open its own workspace'
       else 'OK' end
from pg_proc where proname='accept_invite' and pronamespace='public'::regnamespace;

insert into _r
select '02 every refusal for a different user is preserved',
  case when position('company invite has already been used' in prosrc) = 0 then 'FAIL: already-used gone'
       when position('company invite has been revoked' in prosrc) = 0 then 'FAIL: revoked gone'
       when position('company invite has expired' in prosrc) = 0 then 'FAIL: expired gone'
       when position('company invite is restricted to another email' in prosrc) = 0 then 'FAIL: email restriction gone'
       when position('access_state = ''pending''' in prosrc) = 0 then 'FAIL: the v569 approval park is gone'
       else 'OK' end
from pg_proc where proname='accept_invite' and pronamespace='public'::regnamespace;

insert into _r
select '03 preview knows awaiting_approval',
  case when position('when inv.status = ''awaiting_approval'' then ''awaiting_approval''' in prosrc) = 0
         then 'FAIL: a waiting teammate''s code still previews as invalid'
       else 'OK' end
from pg_proc where proname='preview_staff_invite' and pronamespace='public'::regnamespace;

insert into _r
select '04 the reference code survives being looked at, and one overload exists',
  case when count(*) <> 1 then 'FAIL: '||count(*)||' overloads — PGRST203 territory'
       when bool_or(position('''reused'',true' in prosrc) > 0) = false
         then 'FAIL: no reuse branch — every open still kills the live code'
       when bool_or(position('coalesce(p_rotate, false)' in prosrc) > 0) = false
         then 'FAIL: rotation is not an explicit choice'
       else 'OK' end
from pg_proc where proname='create_staff_reference_code_v217' and pronamespace='public'::regnamespace;

insert into _r
select '05 grants unchanged in intent',
  case when bool_or(proname='preview_staff_invite' and array_to_string(proacl,',') like '%anon=X%') = false
         then 'FAIL: anon can no longer preview an invite before signing up'
       when bool_or(proname='accept_invite' and array_to_string(proacl,',') like '%anon=X%')
         then 'FAIL: anon can accept'
       when bool_or(proname='create_staff_reference_code_v217' and array_to_string(proacl,',') like '%anon=X%')
         then 'FAIL: anon can mint reference codes'
       else 'OK' end
from pg_proc where pronamespace='public'::regnamespace
  and proname in ('preview_staff_invite','accept_invite','create_staff_reference_code_v217');

/* Behavioural: replay the REAL accepted invite as its own accepter, inside this rolled-back
   transaction. auth.uid() reads request.jwt.claims, so the accepter is impersonated for this
   transaction only. Skipped with a reason if no accepted invite exists. */
do $flow$
declare v_inv record; v_result json;
begin
  select i.code, i.accepted_user_id, b.slug into v_inv
  from public.staff_invites i join public.businesses b on b.id=i.business_id
  where i.status in ('awaiting_approval','accepted') and i.accepted_user_id is not null
  order by i.created_at desc limit 1;

  if v_inv is null then
    insert into _r values('06 behavioural replay','SKIP: no accepted invite exists to replay');
    return;
  end if;

  perform set_config('request.jwt.claims',
    json_build_object('sub',v_inv.accepted_user_id,'role','authenticated')::text, true);

  v_result := public.accept_invite(v_inv.code);

  insert into _r values('06 behavioural replay',
    case when (v_result->>'replayed') is distinct from 'true'
           then 'FAIL: the accepter''s own return was not treated as a replay: '||coalesce(v_result::text,'null')
         when coalesce(v_result->>'business_slug','') = '' then 'FAIL: replay does not name the workspace'
         when v_result->>'business_slug' is distinct from v_inv.slug then 'FAIL: wrong business'
         else 'OK' end);
exception when others then
  insert into _r values('06 behavioural replay','FAIL: replay raised — '||sqlerrm);
end
$flow$;

select check_id, value from _r order by check_id;

rollback;
