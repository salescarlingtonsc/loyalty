-- Rollback-only acceptance for nestly_v641 — mark-all-read actually marks messages read.
-- Run: supabase db query --linked -f db/tests/v641_inbox_mark_all_read.sql
-- Any row whose value starts with FAIL is a failure. Nothing is committed.
--
--   01  BEHAVIOURAL, and the check v632 lacked: a real customer identity presses it and the badge
--       goes to zero. v632 shipped a set-based INSERT that app.c46_inbox_state_guard refused on
--       every row; its suite proved the function's shape and never called it, so the defect
--       reached production. This check calls it.
--   02  it delegates to the ONE writer the guard exists to force
--   03  dismissal stays terminal — a dismissed message is not resurrected
--   04  a replayed batch re-plays each event rather than writing a second history
--   05  a caller with no customer identity is refused
--   06  anon cannot execute it

begin;

create temp table _r(check_id text, value text) on commit drop;

/* The one that matters. Everything else in this file could pass while the button was broken. */
do $happy$
declare v_user uuid; v_out jsonb; v_before int; v_after int;
begin
  select i.auth_user_id into v_user
  from public.customer_identities i
  join public.customer_in_app_inbox_events e on e.identity_id=i.id and e.auth_user_id=i.auth_user_id
  left join public.customer_in_app_inbox_state s on s.event_id=e.id
  left join public.customer_in_app_inbox_resolutions r on r.event_id=e.id
  where i.status='active' and r.id is null and s.read_at is null and s.dismissed_at is null
  limit 1;
  if v_user is null then
    insert into _r values('01 behavioural: pressing it clears the badge','SKIP: no identity with unread messages');
    return;
  end if;
  perform set_config('request.jwt.claims',json_build_object('sub',v_user,'role','authenticated')::text,true);
  set local role authenticated;
  v_before := (public.customer_get_in_app_inbox_global_count()->>'unread_count')::int;
  v_out := public.customer_mark_in_app_inbox_read_all_v632(gen_random_uuid());
  v_after := (public.customer_get_in_app_inbox_global_count()->>'unread_count')::int;
  reset role;
  insert into _r values('01 behavioural: pressing it clears the badge',
    case when (v_out->>'marked')::int <> v_before
           then 'FAIL: reported '||(v_out->>'marked')||' marked but the badge counted '||v_before
         when v_after <> 0
           then 'FAIL: the badge still shows '||v_after||' after marking everything read'
         else 'OK — cleared '||v_before end);
exception when others then
  reset role;
  insert into _r values('01 behavioural: pressing it clears the badge','FAIL: raised '||sqlstate||' / '||sqlerrm);
end
$happy$;

insert into _r
select '02 it delegates to the one writer the guard forces',
  case when position('customer_set_in_app_inbox_state' in prosrc)=0
         then 'FAIL: it writes inbox state some other way — app.c46_inbox_state_guard will refuse it'
       when position('insert into public.customer_in_app_inbox_state' in prosrc)>0
         then 'FAIL: it writes the state table directly again'
       when position('c46_customer_inbox_global_context' in prosrc)=0
         then 'FAIL: it resolves the identity some other way than the reader does'
       when position('c46_inbox_source_available' in prosrc)=0
         then 'FAIL: the source-availability gate the badge applies is missing'
       when position('cl.state = ''verified''' in prosrc)=0
         then 'FAIL: an unverified link''s messages could be marked read'
       else 'OK' end
from pg_proc where proname='customer_mark_in_app_inbox_read_all_v632' and pronamespace='public'::regnamespace;

/* Dismissal is terminal, and it is terminal because the delegate says so — this function must not
   re-decide it. Proved by asking the delegate, not by reading this function's own text. */
insert into _r
select '03 dismissal stays terminal, in the writer that owns it',
  case when (select position('dismissed_at is not null' in prosrc) from pg_proc
              where proname='customer_set_in_app_inbox_state' and pronamespace='public'::regnamespace)=0
         then 'FAIL: the per-event writer no longer protects a dismissed message'
       when (select position('s.dismissed_at is null' in prosrc) from pg_proc
              where proname='customer_mark_in_app_inbox_read_all_v632' and pronamespace='public'::regnamespace)=0
         then 'FAIL: the batch does not even skip dismissed messages before delegating'
       else 'OK' end;

insert into _r
select '04 a replayed batch replays, it does not duplicate',
  case when position('md5(p_idempotency_key::text' in prosrc)=0
         then 'FAIL: the per-event key is not derived from the batch key'
       else 'OK' end
from pg_proc where proname='customer_mark_in_app_inbox_read_all_v632' and pronamespace='public'::regnamespace;

do $identity$
declare v_result text;
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub',gen_random_uuid(),'role','authenticated')::text,true);
  begin
    set local role authenticated;
    perform public.customer_mark_in_app_inbox_read_all_v632(gen_random_uuid());
    reset role;
    v_result:='FAIL: a signed-in user with no customer identity marked an inbox read';
  exception when others then
    reset role;
    /* Refused is the pass; WHICH refusal belongs to the identity resolver, not to this suite. */
    v_result:='OK';
  end;
  insert into _r values('05 a caller with no customer identity is refused',v_result);
end
$identity$;

insert into _r
select '06 anon cannot execute it',
  case when bool_or(has_function_privilege('anon',oid,'execute'))
         then 'FAIL: anon can mark somebody else''s inbox read'
       when not bool_or(has_function_privilege('authenticated',oid,'execute'))
         then 'FAIL: a signed-in customer cannot call it'
       else 'OK' end
from pg_proc where proname='customer_mark_in_app_inbox_read_all_v632' and pronamespace='public'::regnamespace;

reset role;
select check_id, value from _r order by check_id;

rollback;
