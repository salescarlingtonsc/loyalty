-- Rollback-only acceptance for nestly_v571 — retention lane INERT repair.
-- Run: supabase db query --linked -f db/tests/v571_retention_dispatch_inert_repair.sql
-- Any row whose value starts with FAIL is a failure. Nothing is committed.
--
-- THIS SUITE EXECUTES THE DRIVER. That is the whole point: the v536 defect
-- survived because every test was a rolled-back SQL suite or a source grep, and
-- neither can run a function whose last act is an HTTP POST. Here the real
-- app.v551_run_retention_dispatch is called for every gate, with p_dry_run
-- withholding only the POST — and check 09 proves net.http_request_queue gained
-- nothing while all of it ran.
--
--   01  surface: service_role only; no browser role can dispatch or resolve
--   02  the zero-argument driver is GONE (two overloads would be ambiguous)
--   03  EXECUTED: master flag OFF -> 'retention_disabled' before anything else
--   04  EXECUTED: flag ON, empty queue -> 'idle'
--   05  EXECUTED: flag ON + a queued row + dry run -> 'would_dispatch' at the
--       whatsapp-retention-dispatch endpoint (the repair, proven end to end)
--   06  EXECUTED: unresolvable URL names -> 'base_url_unconfigured'
--   07  EXECUTED: unresolvable secret name -> 'dispatch_secret_unconfigured'
--   08  the resolver returns the endpoint and NEVER the secret
--   09  NO HTTP WAS FIRED by any of the above
--   10  v282 customer push is STILL DEAD (this repair did not revive it)
--   11  the C6 support lane driver is untouched
--   12  the queue is exactly as it was found
--
-- NOT COVERED HERE, deliberately: "wrong dispatch secret -> refused" is a
-- property of the EDGE FUNCTION, and net.http_post inside a transaction is
-- rolled back with it, so no HTTP assertion is possible in this file. That one
-- is proven by a separate live probe against the deployed function with a
-- deliberately wrong secret, expecting 401 and zero claims. See the task report.

begin;

create temp table _r(k text, v text) on commit drop;
create temp table _o(step text, doc jsonb) on commit drop;
create temp table _f(k text primary key, id uuid) on commit drop;

-- Baselines captured BEFORE anything runs, so check 09 and 12 compare against
-- the world as it actually was rather than an assumption about it.
create temp table _base(k text primary key, n bigint) on commit drop;
insert into _base values
  ('http_queue', (select count(*) from net.http_request_queue)),
  ('sends',      (select count(*) from public.retention_sends_v551));

-- ------------------------------------------------------------------ 01 surface
insert into _r
select '01 dispatch surface is service-side only',
  case when not has_function_privilege('anon','app.v551_run_retention_dispatch(boolean)','EXECUTE')
        and not has_function_privilege('authenticated','app.v551_run_retention_dispatch(boolean)','EXECUTE')
        and has_function_privilege('service_role','app.v551_run_retention_dispatch(boolean)','EXECUTE')
        and not has_function_privilege('anon','app.v551_dispatch_target_v571(text[],text)','EXECUTE')
        and not has_function_privilege('authenticated','app.v551_dispatch_target_v571(text[],text)','EXECUTE')
        and has_function_privilege('service_role','app.v551_dispatch_target_v571(text[],text)','EXECUTE')
       then 'PASS neither browser role can dispatch retention or resolve the endpoint'
       else 'FAIL a browser role can reach the dispatch plane' end;

-- ------------------------------------------------- 02 no overload ambiguity
insert into _r
select '02 the zero-argument driver was dropped',
  case when (select count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace
              where n.nspname='app' and p.proname='v551_run_retention_dispatch')=1
        and to_regprocedure('app.v551_run_retention_dispatch(boolean)') is not null
       then 'PASS exactly one signature, so the cron''s no-arg call is unambiguous'
       else 'FAIL two overloads would make v551_run_retention_dispatch() ambiguous' end;

-- ------------------------------------- 03 EXECUTED: the kill switch kills
update app.platform_feature_flags set enabled=false where feature_key='whatsapp_retention_sends';
insert into _o select 'flag_off', app.v551_run_retention_dispatch();

insert into _r
select '03 master flag off stops dispatch outright',
  case when (select doc->>'dispatch' from _o where step='flag_off')='retention_disabled'
       then 'PASS the switch is the first gate and fails closed'
       else 'FAIL '||coalesce((select doc::text from _o where step='flag_off'),'<none>') end;

-- --------------------------------------------- 04 EXECUTED: empty queue idles
update app.platform_feature_flags set enabled=true where feature_key='whatsapp_retention_sends';
insert into _o select 'idle', app.v551_run_retention_dispatch();

insert into _r
select '04 an empty queue is idle, not an error',
  case when (select doc->>'dispatch' from _o where step='idle')='idle'
        and (select doc->>'queued' from _o where step='idle')='0'
       then 'PASS nothing queued, nothing attempted'
       else 'FAIL '||coalesce((select doc::text from _o where step='idle'),'<none>') end;

-- ------------------- 05 EXECUTED: a queued row reaches the correct endpoint
-- The queue row is NOT hand-built. public.bringback_grants_v361 carries an
-- AFTER INSERT trigger (bringback_grants_v361_enqueue_send_v551) that enqueues
-- the send, so granting a voucher IS the enqueue path. An earlier draft of this
-- suite inserted the row itself and collided with the trigger on the UNIQUE
-- grant_id — which is how the automatic path was discovered. Letting the
-- trigger do it tests the real thing and proves the master flag gates enqueue
-- as well as dispatch.
-- The trigger ALWAYS writes a row and marks it status='suppressed' with a
-- suppressed_reason when a gate refuses, rather than dropping the decision on
-- the floor. So "nothing was sent" is asserted as suppressed-by-name, not as
-- an absent row. An earlier draft of this suite asserted absence and failed
-- against correct code — the audit trail is the feature.
create or replace function pg_temp.grant_voucher(p_label text, p_consent boolean)
returns uuid language plpgsql as $gv$
declare v_biz uuid := '8492e8d6-8888-4383-ada0-7e1ed69f0caa';
        v_client uuid; v_camp uuid; v_grant uuid;
begin
  insert into public.clients(business_id, full_name, phone, marketing_consent)
  values (v_biz, 'v571 suite '||p_label,
          '+65 8555 71'||lpad((abs(hashtext(p_label))%90+10)::text,2,'0'), p_consent)
  returning id into v_client;

  insert into public.bringback_campaigns_v361(business_id, name, reward_label, away_days, active)
  values (v_biz, 'v571 suite campaign '||p_label, 'A free coffee', 60, false)
  returning id into v_camp;

  insert into public.bringback_grants_v361(
    business_id, campaign_id, client_id, reward_label, away_days, cycle_key, status, granted_at)
  values (v_biz, v_camp, v_client, 'A free coffee', 60, current_date, 'granted', now())
  returning id into v_grant;

  return v_grant;
end $gv$;

-- 05a with the switch OFF: consent or not, nothing may become sendable.
update app.platform_feature_flags set enabled=false where feature_key='whatsapp_retention_sends';
insert into _f select 'grant_off', pg_temp.grant_voucher('flagoff', true);

insert into _r
select '05a the master flag gates enqueue, not only dispatch',
  case when (select status from public.retention_sends_v551
              where grant_id=(select id from _f where k='grant_off'))='suppressed'
        and (select suppressed_reason from public.retention_sends_v551
              where grant_id=(select id from _f where k='grant_off')) is not null
       then 'PASS a fully consented customer is still suppressed by name while the switch is off'
       else 'FAIL '||coalesce((select status||'/'||coalesce(suppressed_reason,'-')
              from public.retention_sends_v551
             where grant_id=(select id from _f where k='grant_off')),'<no row>') end;

-- 05b switch ON but NO marketing consent: suppressed, named.
update app.platform_feature_flags set enabled=true where feature_key='whatsapp_retention_sends';
insert into _f select 'grant_noconsent', pg_temp.grant_voucher('noconsent', false);

insert into _r
select '05b marketing consent is required, and its absence is recorded',
  case when (select status from public.retention_sends_v551
              where grant_id=(select id from _f where k='grant_noconsent'))='suppressed'
        and (select suppressed_reason from public.retention_sends_v551
              where grant_id=(select id from _f where k='grant_noconsent'))='consent_missing'
       then 'PASS clients.marketing_consent defaults false; a till-created customer is never messaged'
       else 'FAIL '||coalesce((select status||'/'||coalesce(suppressed_reason,'-')
              from public.retention_sends_v551
             where grant_id=(select id from _f where k='grant_noconsent')),'<no row>') end;

-- 05b2 switch ON with consent: the trigger queues a real send, unattended.
insert into _f select 'grant', pg_temp.grant_voucher('flagon', true);

insert into _r
select '05b2 granting a voucher auto-queues a send with no human approval',
  case when (select count(*) from public.retention_sends_v551
              where grant_id=(select id from _f where k='grant'))=1
        and (select status from public.retention_sends_v551
              where grant_id=(select id from _f where k='grant'))='queued'
       then 'PASS the AFTER INSERT trigger IS the enqueue path; nobody approves it'
       else 'FAIL '||coalesce((select status||'/'||coalesce(suppressed_reason,'-')
              from public.retention_sends_v551
             where grant_id=(select id from _f where k='grant')),'<no row>') end;

insert into _o select 'dry_run', app.v551_run_retention_dispatch(true);

insert into _r
select '05 a queued row resolves to the retention endpoint',
  case when (select doc->>'dispatch' from _o where step='dry_run')='would_dispatch'
        and (select (doc->>'queued')::int from _o where step='dry_run') >= 1
        and (select doc->>'endpoint' from _o where step='dry_run')
            like 'https://%/functions/v1/whatsapp-retention-dispatch'
       then 'PASS the repaired lookup reaches whatsapp-retention-dispatch, not the support one'
       else 'FAIL '||coalesce((select doc::text from _o where step='dry_run'),'<none>') end;

-- ------------------------------- 06/07 EXECUTED: both halves fail closed BY NAME
insert into _o select 'no_url', app.v551_dispatch_target_v571(
  array['v571_definitely_absent_url'], 'v536_whatsapp_dispatch_secret');
insert into _o select 'no_secret', app.v551_dispatch_target_v571(
  array['v536_supabase_url','v176_supabase_url'], 'v571_definitely_absent_secret');

insert into _r
select '06 a missing base URL is named, not conflated',
  case when (select doc->>'reason' from _o where step='no_url')='base_url_unconfigured'
        and (select doc->>'ok' from _o where step='no_url')='false'
       then 'PASS the exact defect this migration repairs now reports itself by name'
       else 'FAIL '||coalesce((select doc::text from _o where step='no_url'),'<none>') end;

insert into _r
select '07 a missing dispatch secret is named separately',
  case when (select doc->>'reason' from _o where step='no_secret')='dispatch_secret_unconfigured'
        and (select doc->>'ok' from _o where step='no_secret')='false'
       then 'PASS the two halves of ''secret_unconfigured'' are distinguishable'
       else 'FAIL '||coalesce((select doc::text from _o where step='no_secret'),'<none>') end;

-- ------------------------------------------- 08 the resolver leaks no secret
insert into _o select 'resolve', app.v551_dispatch_target_v571();

insert into _r
select '08 the resolver returns the endpoint and never the secret',
  case when (select doc->>'ok' from _o where step='resolve')='true'
        and (select doc->>'secret_present' from _o where step='resolve')='true'
        and (select (select array_agg(k order by k) from jsonb_object_keys(doc) k)
               from _o where step='resolve')
            = array['endpoint','ok','reason','secret_present']
       then 'PASS exactly four keys; the decrypted secret is not among them'
       else 'FAIL resolver payload shape: '
            ||coalesce((select doc::text from _o where step='resolve'),'<none>') end;

-- ------------------------------------------------------- 09 NOTHING WAS SENT
insert into _r
select '09 no HTTP request was fired by any of the above',
  case when (select count(*) from net.http_request_queue)
            = (select n from _base where k='http_queue')
       then 'PASS every gate above executed with the POST withheld'
       else 'FAIL net.http_request_queue grew during the suite' end;

-- --------------------------------------------- 10 v282 push is still dead
-- Owner ruling: this repair must not revive customer web push, which has its
-- own unreviewed backlog. It is still dead for the ORIGINAL reason - it names
-- vault secrets that do not exist - and this migration created none.
insert into _r
select '10 the v282 customer push dispatcher was not revived',
  case when pg_get_functiondef('app.v282_run_customer_push_dispatch()'::regprocedure) ilike '%v282_supabase_url%'
        and not exists (select 1 from vault.secrets where name in ('v282_supabase_url','v156_supabase_url'))
       then 'PASS v282 still resolves nothing; no vault key was created'
       else 'FAIL v282 push may have been reactivated as a side effect' end;

-- ------------------------------------------ 11 the C6 support lane is untouched
insert into _r
select '11 the support/appointment dispatcher is unchanged',
  case when pg_get_functiondef('app.v536_run_support_dispatch()'::regprocedure) ilike '%support_messages_v530%'
        and pg_get_functiondef('app.v536_run_support_dispatch()'::regprocedure) ilike '%whatsapp_template_sends_v557%'
        and pg_get_functiondef('app.v536_run_support_dispatch()'::regprocedure) ilike '%whatsapp-send-dispatch%'
       then 'PASS C6 support and C7 appointments still share their own driver, unmodified'
       else 'FAIL the support lane was altered by a retention repair' end;

-- ------------------------------------------------- 12 the queue is as found
insert into _r
select '12 the retention queue is unchanged apart from this suite''s own rows',
  case when (select count(*) from public.retention_sends_v551)
            = (select n from _base where k='sends') + 3
        and (select count(*) from public.retention_sends_v551 where status='queued')=1
       then 'PASS exactly the three fixture rows (one queued, two suppressed), all dying with this rollback'
       else 'FAIL the suite disturbed rows it did not create' end;

select k as check_name, v as result from _r order by k;

rollback;
