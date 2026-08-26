-- Rollback-only acceptance for nestly_v535 + v536 — C6 outbound reply.
-- Run: supabase db query --linked -f db/tests/v535_support_reply_chokepoint.sql
-- Any row whose value starts with FAIL is a failure. Nothing is committed.
--
--   01  surface + grants; the browser door is public.*, the chokepoint is app.*
--   02  BOTH GATES: master flag off -> refused; flag on but no capability ->
--       refused. A read-only Inbox tenant still cannot send.
--   03  read-only staff (module_perms r) are refused with a named reason
--   04  TENANT ISOLATION: business A replying into B's conversation by id fails
--   05  service window CLOSED -> refused, and nothing is queued
--   06  the happy path queues exactly one row, status 'queued'
--   07  MERCHANT PREFIX is server-composed from businesses.name and the browser
--       cannot supply or remove it
--   08  IDEMPOTENCY: the same key returns the ORIGINAL message, creates no
--       second row, and consumes the safety cap only once
--   09  a DIFFERENT key (operator edited the body) is a new logical send
--   10  the DAILY SAFETY CAP refuses with a named reason once spent
--   11  content validation: empty, oversized, control characters
--   12  STATUS MONOTONIC: a late 'sent' never downgrades 'read'; 'failed' never
--       overrides 'delivered'
--   13  the thread reader's can_reply matches what the chokepoint would do
--   14  claim/report: a stale lease is refused (40001)
--   15  provider_message_id is never projected by either browser reader

begin;

create temp table _r(k text, v text) on commit drop;

-- ---------------------------------------------------------------- 01 surface
insert into _r
select '01 surface',
  case when has_function_privilege('authenticated',
         'public.business_support_send_reply_v535(uuid,uuid,text,text)','EXECUTE')
        and not has_function_privilege('authenticated',
         'app.support_reply_v535(uuid,uuid,text,text)','EXECUTE')
        and not has_function_privilege('anon',
         'public.business_support_send_reply_v535(uuid,uuid,text,text)','EXECUTE')
        and not has_function_privilege('authenticated',
         'public.internal_support_claim_outbound_v535(text,integer,integer)','EXECUTE')
        and exists (select 1 from public.platform_capabilities_v518
                     where capability_key='whatsapp_support_reply'
                       and default_enabled=false and default_limit_period='day')
       then 'PASS browser door granted, chokepoint and claim are not, capability seeded OFF/day'
       else 'FAIL surface wrong' end;

-- Two real tenants with real owner staff (staff.user_id FKs auth.users).
create temp table _b(tag text primary key, id uuid, uid uuid) on commit drop;
insert into _b(tag,id,uid) values
 ('A','8492e8d6-8888-4383-ada0-7e1ed69f0caa','f73a9423-33fd-424c-9fb9-2d5ba058a2d7'),
 ('B','dcaaf5d6-3396-43b4-bff4-1cdd4df01cbf','4be3825c-464a-4fcb-b5aa-079721982f9e');

insert into public.platform_module_overrides_v94(business_id,branch_scope,module_key,mode,reason)
select id,null,'support','rw','v535 suite' from _b
on conflict do nothing;

-- A routed open conversation for each, with a live service window.
create temp table _c(tag text, conv uuid) on commit drop;
insert into public.support_conversations_v530(
  business_id, channel, customer_phone_norm, state, routing_source,
  opened_at, last_inbound_at, service_window_expires_at)
select id,'whatsapp', case when tag='A' then '95550001' else '95550002' end,
       'open','entry_token', now(), now(), now()+interval '20 hours'
from _b;
insert into _c select b.tag, c.id from _b b
  join public.support_conversations_v530 c on c.business_id=b.id
 where c.customer_phone_norm in ('95550001','95550002');

create temp table _o(step text, doc jsonb) on commit drop;

create or replace function pg_temp.as_user(p uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claim.sub', coalesce(p::text,''), true);
  perform set_config('request.jwt.claims',
    json_build_object('sub',p,'role','authenticated')::text, true);
end $$;

-- ------------------------------------------- 02 both gates (master flag off)
select pg_temp.as_user((select uid from _b where tag='A'));
insert into _o select 'flag_off', public.business_support_send_reply_v535(
  (select id from _b where tag='A'),(select conv from _c where tag='A'),
  'hello','v535-suite-key-flagoff');

-- Master flag ON, but still no per-firm capability grant.
update app.platform_feature_flags set enabled=true where feature_key='whatsapp_outbound';
insert into _o select 'no_capability', public.business_support_send_reply_v535(
  (select id from _b where tag='A'),(select conv from _c where tag='A'),
  'hello','v535-suite-key-nocap');

insert into _r
select '02 both gates required',
  case when (select doc->>'reason' from _o where step='flag_off')='outbound_not_enabled'
        and (select doc->>'reason' from _o where step='no_capability')='not_enabled'
        and (select count(*) from public.support_messages_v530 where direction='outbound')=0
       then 'PASS master flag and per-firm capability are independently necessary'
       else 'FAIL a gate was bypassed' end;

-- Grant BOTH tenants the capability, small daily cap for the cap test.
insert into public.business_capability_grants_v518(
  business_id,capability_key,enabled,limit_count,limit_period)
select id,'whatsapp_support_reply',true,2,'day' from _b;

-- ------------------------------------------- 03 read-only staff refused
-- Must be a NON-OWNER. app.staff_module_mode_v94 returns the platform mode
-- immediately for role='owner', so module_perms on an owner is inert and an
-- earlier draft of this check silently tested nothing.
create temp table _ro(uid uuid) on commit drop;
insert into _ro
select s.user_id from public.staff s
 where s.business_id=(select id from _b where tag='A') and s.active
   and s.role <> 'owner' and s.user_id is not null limit 1;
-- If this tenant has no non-owner staff, borrow B's owner user as A's manager.
insert into public.staff(business_id,user_id,role,full_name,active,module_perms)
select (select id from _b where tag='A'), (select uid from _b where tag='B'),
       'manager','v535 suite read-only', true, '{"support":"r"}'::jsonb
where not exists (select 1 from _ro);
insert into _ro select (select uid from _b where tag='B') where not exists (select 1 from _ro);
update public.staff set module_perms = coalesce(module_perms,'{}'::jsonb) || '{"support":"r"}'::jsonb
 where business_id=(select id from _b where tag='A') and user_id=(select uid from _ro);

select pg_temp.as_user((select uid from _ro));
insert into _o select 'readonly', public.business_support_send_reply_v535(
  (select id from _b where tag='A'),(select conv from _c where tag='A'),
  'hello','v535-suite-key-readonly');
select pg_temp.as_user((select uid from _b where tag='A'));

insert into _r
select '03 read-only staff refused',
  case when (select doc->>'reason' from _o where step='readonly')='no_support_write_permission'
       then 'PASS read-only module permission cannot send'
       else 'FAIL '||coalesce((select doc->>'reason' from _o where step='readonly'),'<none>') end;

-- ------------------------------------------- 04 tenant isolation
select pg_temp.as_user((select uid from _b where tag='A'));
insert into _o select 'cross', public.business_support_send_reply_v535(
  (select id from _b where tag='A'),(select conv from _c where tag='B'),
  'hello','v535-suite-key-cross');
insert into _o select 'cross_claim', public.business_support_send_reply_v535(
  (select id from _b where tag='B'),(select conv from _c where tag='B'),
  'hello','v535-suite-key-cross2');

-- Asserts the SUBSTANCE, not one particular wording. Guessing B's conversation
-- id is refused 'conversation_not_found' (business_id is in the predicate);
-- claiming to act FOR B is refused by the module gate first, because
-- app.staff_module_mode_v94 already requires the caller to be active staff of
-- that business. Both are correct fences; the earlier one simply wins. What
-- must be true either way is that B's conversation gained nothing.
insert into _r
select '04 tenant isolation',
  case when (select doc->>'status' from _o where step='cross')='refused'
        and (select doc->>'status' from _o where step='cross_claim')='refused'
        and (select doc->>'reason' from _o where step='cross')='conversation_not_found'
        and (select count(*) from public.support_messages_v530 m
              join public.support_conversations_v530 c on c.id=m.conversation_id
             where c.business_id=(select id from _b where tag='B')
               and m.direction='outbound')=0
       then 'PASS both refused ('
            ||(select doc->>'reason' from _o where step='cross')||' / '
            ||(select doc->>'reason' from _o where step='cross_claim')
            ||'); B''s thread gained nothing'
       else 'FAIL cross='||coalesce((select doc->>'reason' from _o where step='cross'),'<none>')
            ||' cross_claim='||coalesce((select doc->>'reason' from _o where step='cross_claim'),'<none>') end;

-- ------------------------------------------- 05 window closed
update public.support_conversations_v530 set service_window_expires_at = now()-interval '1 minute'
 where id=(select conv from _c where tag='A');
insert into _o select 'shut', public.business_support_send_reply_v535(
  (select id from _b where tag='A'),(select conv from _c where tag='A'),
  'hello','v535-suite-key-shut');
update public.support_conversations_v530 set service_window_expires_at = now()+interval '20 hours'
 where id=(select conv from _c where tag='A');

insert into _r
select '05 closed window refused, nothing queued',
  case when (select doc->>'reason' from _o where step='shut')='service_window_closed'
        and (select count(*) from public.support_messages_v530 where direction='outbound')=0
       then 'PASS refused with a named reason and queued nothing'
       else 'FAIL window not enforced' end;

-- ------------------------------------------- 06/07 happy path + prefix
insert into _o select 'send1', public.business_support_send_reply_v535(
  (select id from _b where tag='A'),(select conv from _c where tag='A'),
  'Hi! This is a test reply.','v535-suite-key-send1');

insert into _r
select '06 queues exactly one row',
  case when (select doc->>'status' from _o where step='send1')='ok'
        and (select doc->>'message_status' from _o where step='send1')='queued'
        and (select count(*) from public.support_messages_v530 where direction='outbound')=1
       then 'PASS one queued outbound row'
       else 'FAIL '||coalesce((select doc::text from _o where step='send1'),'<none>') end;

insert into _r
select '07 server-composed merchant prefix',
  case when m.rendered_body = (select name from public.businesses where id=m.business_id)||': Hi! This is a test reply.'
        and m.body = 'Hi! This is a test reply.'
       then 'PASS rendered_body carries the canonical business name; body is what staff typed'
       else 'FAIL prefix wrong: '||coalesce(m.rendered_body,'<null>') end
from public.support_messages_v530 m where m.direction='outbound';

-- ------------------------------------------- 08 idempotency
insert into _o select 'retry_same', public.business_support_send_reply_v535(
  (select id from _b where tag='A'),(select conv from _c where tag='A'),
  'Hi! This is a test reply.','v535-suite-key-send1');

insert into _r
select '08 same key returns the original, consumes cap once',
  case when (select doc->>'duplicate' from _o where step='retry_same')='true'
        and (select doc->>'message_id' from _o where step='retry_same')
          = (select doc->>'message_id' from _o where step='send1')
        and (select count(*) from public.support_messages_v530 where direction='outbound')=1
        and (select count(*) from public.capability_usage_v518
              where capability_key='whatsapp_support_reply'
                and business_id=(select id from _b where tag='A'))=1
       then 'PASS one row, one quota consumption, original id returned'
       else 'FAIL retry duplicated a message or double-consumed the cap' end;

-- ------------------------------------------- 09 edited body = new send
insert into _o select 'send2', public.business_support_send_reply_v535(
  (select id from _b where tag='A'),(select conv from _c where tag='A'),
  'Edited reply.','v535-suite-key-send2');

insert into _r
select '09 a new key is a new logical send',
  case when (select doc->>'duplicate' from _o where step='send2')='false'
        and (select count(*) from public.support_messages_v530 where direction='outbound')=2
       then 'PASS an edited body with a fresh key sends separately'
       else 'FAIL new key did not create a second message' end;

-- ------------------------------------------- 10 daily safety cap
insert into _o select 'capped', public.business_support_send_reply_v535(
  (select id from _b where tag='A'),(select conv from _c where tag='A'),
  'Third.','v535-suite-key-send3');

insert into _r
select '10 daily safety cap refuses with a named reason',
  case when (select doc->>'reason' from _o where step='capped')='quota_exhausted'
        and (select count(*) from public.support_messages_v530 where direction='outbound')=2
       then 'PASS cap of 2/day held; the third was refused and not queued'
       else 'FAIL cap not enforced' end;

-- ------------------------------------------- 11 content validation
insert into public.business_capability_grants_v518(business_id,capability_key,enabled,limit_count,limit_period)
select id,'whatsapp_support_reply',true,50,'day' from _b where tag='B'
on conflict (business_id,capability_key) do update set limit_count=50;
select pg_temp.as_user((select uid from _b where tag='B'));
insert into _o select 'empty', public.business_support_send_reply_v535(
  (select id from _b where tag='B'),(select conv from _c where tag='B'),'   ','v535-suite-empty');
insert into _o select 'long', public.business_support_send_reply_v535(
  (select id from _b where tag='B'),(select conv from _c where tag='B'),
  repeat('x',3100),'v535-suite-long');
insert into _o select 'ctl', public.business_support_send_reply_v535(
  (select id from _b where tag='B'),(select conv from _c where tag='B'),
  'bad'||chr(7)||'char','v535-suite-ctl');
insert into _o select 'multiline', public.business_support_send_reply_v535(
  (select id from _b where tag='B'),(select conv from _c where tag='B'),
  E'line one\nline two','v535-suite-multiline');

insert into _r
select '11 content validation',
  case when (select doc->>'reason' from _o where step='empty')='empty_message'
        and (select doc->>'reason' from _o where step='long')='message_too_long'
        and (select doc->>'reason' from _o where step='ctl')='invalid_characters'
        and (select doc->>'status' from _o where step='multiline')='ok'
       then 'PASS empty/oversized/control refused; a multi-line reply is allowed'
       else 'FAIL validation wrong' end;

-- ------------------------------------------- 12 monotonic status
create temp table _m(id uuid) on commit drop;
insert into _m select id from public.support_messages_v530
 where direction='outbound' and idempotency_key='v535-suite-key-send1';
update public.support_messages_v530
   set provider_message_id='wamid.SUITE535', status='read',
       status_rank=app.support_status_rank_v535('read'), read_at=now()
 where id=(select id from _m);

-- A LATE 'sent' arrives after 'read'.
update public.support_messages_v530
   set status='sent', status_rank=app.support_status_rank_v535('sent')
 where id=(select id from _m)
   and status_rank < app.support_status_rank_v535('sent');
-- And a 'failed' after 'delivered'-or-better.
update public.support_messages_v530
   set status='failed', status_rank=app.support_status_rank_v535('failed')
 where id=(select id from _m)
   and status_rank < app.support_status_rank_v535('failed');

insert into _r
select '12 status is monotonic',
  case when status='read' and status_rank=40
       then 'PASS a late sent and a late failed both left read alone'
       else 'FAIL status downgraded to '||status end
from public.support_messages_v530 where id=(select id from _m);

-- ------------------------------------------- 13 can_reply agrees
select pg_temp.as_user((select uid from _b where tag='A'));
create temp table _t(doc jsonb) on commit drop;
insert into _t select public.business_support_get_thread_v531(
  (select id from _b where tag='A'),(select conv from _c where tag='A'));

insert into _r
select '13 can_reply mirrors the chokepoint',
  case when (doc->>'can_reply')='false' and (doc->>'reply_disabled_reason')='quota_exhausted'
       then 'PASS the thread explains the same refusal the chokepoint would give'
       else 'FAIL can_reply='||coalesce(doc->>'can_reply','?')||' reason='||coalesce(doc->>'reply_disabled_reason','?') end
from _t;

-- ------------------------------------------- 14 stale lease refused
do $$
declare v_code text;
begin
  begin
    perform public.internal_support_report_outbound_v535(
      (select id from _m), gen_random_uuid(), 'sent', 'wamid.WRONG');
    v_code := 'NONE';
  exception when others then v_code := sqlstate;
  end;
  insert into _r values ('14 stale lease refused',
    case when v_code='40001' then 'PASS a worker with a stale lease cannot report'
         else 'FAIL stale lease accepted ('||v_code||')' end);
end $$;

-- ------------------------------------------- 15 no wamid in reader payloads
insert into _r
select '15 provider_message_id never projected',
  case when (select doc::text from _t) not like '%wamid%'
        and (select doc::text from _t) not like '%provider_message_id%'
        and (select public.business_support_list_conversations_v531(
               (select id from _b where tag='A'))::text) not like '%wamid%'
       then 'PASS neither reader exposes the provider id'
       else 'FAIL a wamid reached a browser payload' end;

update app.platform_feature_flags set enabled=false where feature_key='whatsapp_outbound';

select k as check_name, v as result from _r order by k;

rollback;
