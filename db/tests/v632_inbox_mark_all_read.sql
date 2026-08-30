-- Rollback-only acceptance for nestly_v632 — one control marks the whole inbox read.
-- Run: supabase db query --linked -f db/tests/v632_inbox_mark_all_read.sql
-- Any row whose value starts with FAIL is a failure. Nothing is committed.
--
--   01  one signature, security definer, and anon cannot execute it
--   02  it applies the badge's own definition of unread — identity, verified links, resolutions,
--       dismissals and the source-availability gate, all lifted from the count function
--   03  dismissal stays terminal: a dismissed message is never re-read by the bulk path
--   04  every marked event still writes its own operations row, keyed so a replay collides
--   05  it refuses a caller who is not a verified customer identity

begin;

create temp table _r(check_id text, value text) on commit drop;

insert into _r
select '01 one signature, definer, closed to anon',
  case when count(*)<>1 then 'FAIL: '||count(*)||' overloads of customer_mark_in_app_inbox_read_all_v632'
       when max(case when prosecdef then 1 else 0 end)=0
         then 'FAIL: not security definer, so it cannot write past the inbox RLS'
       when bool_or(has_function_privilege('anon',oid,'execute'))
         then 'FAIL: anon can mark somebody else''s inbox read'
       when not bool_or(has_function_privilege('authenticated',oid,'execute'))
         then 'FAIL: a signed-in customer cannot call it'
       else 'OK' end
from pg_proc where proname='customer_mark_in_app_inbox_read_all_v632' and pronamespace='public'::regnamespace;

/* The badge and the button must agree about what "unread" is, or pressing it leaves a number on
   screen that nothing can clear. Every clause below is one the count function applies. */
insert into _r
select '02 it uses the badge''s own definition of unread',
  case when position('c46_customer_inbox_global_context' in prosrc)=0
         then 'FAIL: it resolves the identity some other way than the reader does'
       when position('cl.state = ''verified''' in prosrc)=0
         then 'FAIL: an unverified link''s messages could be marked read'
       when position('customer_in_app_inbox_resolutions' in prosrc)=0
         then 'FAIL: resolved events are not excluded'
       when position('c46_inbox_source_available' in prosrc)=0
         then 'FAIL: the source-availability gate the badge applies is missing'
       else 'OK' end
from pg_proc where proname='customer_mark_in_app_inbox_read_all_v632' and pronamespace='public'::regnamespace;

insert into _r
select '03 dismissal stays terminal',
  case when position('dismissed_at is null' in prosrc)=0
         then 'FAIL: a dismissed message could be resurrected as unread-then-read'
       when position('dismissed_at = ' in prosrc)>0 or position('dismissed_at=' in prosrc)>0
         then 'FAIL: it writes dismissed_at — only the per-event RPC may decide that'
       else 'OK' end
from pg_proc where proname='customer_mark_in_app_inbox_read_all_v632' and pronamespace='public'::regnamespace;

insert into _r
select '04 evidence per event, keyed so a replay collides',
  case when position('customer_in_app_inbox_state_operations' in prosrc)=0
         then 'FAIL: a bulk read leaves no operations evidence'
       when position('md5(p_idempotency_key::text' in prosrc)=0
         then 'FAIL: the per-event key is not derived from the batch key, so a replay writes a second history'
       when position('on conflict (identity_id,idempotency_key) do nothing' in prosrc)=0
         then 'FAIL: a replayed batch would raise instead of being absorbed'
       else 'OK' end
from pg_proc where proname='customer_mark_in_app_inbox_read_all_v632' and pronamespace='public'::regnamespace;

/* Behavioural, and the one that matters most: a caller with no customer identity must not be able
   to reach anybody's inbox. Run as `authenticated` with a random subject — the shape a stolen or
   forged token would have. */
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
    /* Refused is the pass. WHICH refusal is not pinned: the identity resolver owns that message
       and this suite must not freeze somebody else's wording. */
    v_result:='OK';
  end;
  insert into _r values('05 a caller with no customer identity is refused',v_result);
end
$identity$;

reset role;
select check_id, value from _r order by check_id;

rollback;
