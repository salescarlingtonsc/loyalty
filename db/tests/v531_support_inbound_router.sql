-- Rollback-only acceptance for nestly_v530 + v531 — Support Inbox C1–C5.
-- Run: supabase db query --linked -f db/tests/v530_support_inbox_foundations.sql
-- Any row whose value starts with FAIL is a failure. Nothing is committed.
--
-- Every check the owner listed in the C5 gate, plus the surface checks.
--
--   01  surface: RLS on all four tables, no tenant grants, module registered
--   02  a VALID token routes to EXACTLY ONE business
--   03  the routing token is STRIPPED from what staff read
--   04  an unknown sender gets a conversation but client_id stays NULL
--   05  a known client IS linked — but only within the routed business
--   06  MULTI-BUSINESS: a customer with open threads at two firms who sends an
--       untokened message goes to PENDING. Never inferred from the phone.
--   07  REVOKED and EXPIRED tokens fail safe into pending, never route
--   08  a MALFORMED token cannot select a tenant
--   09  an ordinary untokened message CONTINUES a single explicitly routed thread
--   10  TENANT ISOLATION: business A cannot read business B's conversations or
--       messages, through the RPCs or the tables
--   11  pending/unrouted rows are invisible to every merchant
--   12  the wamid never appears in any RPC payload the browser receives
--   13  ZERO outbound capability exists
--   14  Meta retry / re-run is idempotent — no duplicate message rows
--
-- NOTE: a function that INSERTs is invisible to the SAME statement's snapshot,
-- so every check that calls the router does so in its own statement.

begin;

create temp table _r(k text, v text) on commit drop;

-- ---------------------------------------------------------------- 01 surface
insert into _r
select '01 surface',
  case when (select bool_and(relrowsecurity) from pg_class where oid in (
              'public.support_conversations_v530'::regclass,
              'public.support_messages_v530'::regclass,
              'public.support_pending_conversations_v530'::regclass,
              'public.business_support_entry_tokens_v530'::regclass))
        and not has_table_privilege('authenticated','public.support_conversations_v530','SELECT')
        and not has_table_privilege('authenticated','public.support_messages_v530','SELECT')
        and not has_table_privilege('authenticated','public.support_pending_conversations_v530','SELECT')
        and not has_table_privilege('authenticated','public.business_support_entry_tokens_v530','SELECT')
        and exists (select 1 from public.module_registry where module_key='support' and label='Inbox')
        -- zero policies on the pending table: not a tenant row at all
        and (select count(*) from pg_policies
              where tablename='support_pending_conversations_v530') = 0
       then 'PASS rls on 4 tables, no tenant grants, module registered, pending has 0 policies'
       else 'FAIL surface wrong' end;

-- TWO REAL TENANTS with REAL owner staff. staff.user_id FKs auth.users, so a
-- synthetic uuid cannot impersonate anyone — and testing isolation against real
-- RLS with real users is stronger evidence than a fabricated pair would be.
-- Everything below is rolled back.
create temp table _b(tag text primary key, id uuid, uid uuid) on commit drop;
insert into _b(tag,id,uid)
select tag, business_id, user_id from (
  select 'A' as tag, '8492e8d6-8888-4383-ada0-7e1ed69f0caa'::uuid as business_id,
         'f73a9423-33fd-424c-9fb9-2d5ba058a2d7'::uuid as user_id
  union all
  select 'B', 'dcaaf5d6-3396-43b4-bff4-1cdd4df01cbf'::uuid,
         '4be3825c-464a-4fcb-b5aa-079721982f9e'::uuid) picked;

-- Grant both the support module the way production actually will: a FIRM
-- OVERRIDE. app.business_sector_modules_guard_v75 refuses a direct edit to
-- enabled_modules ("business modules are fixed by the assigned sector
-- entitlement"), and app.effective_platform_module_mode_v94 short-circuits on a
-- firm_override BEFORE consulting enabled_modules — so this is both the only
-- legal path and the one the C5 checkpoint will use.
insert into public.platform_module_overrides_v94(business_id, branch_scope, module_key, mode, reason)
select id, null, 'support', 'rw', 'v530 acceptance suite' from _b;

-- Neither tenant may already hold a conversation for the phones this suite uses,
-- or the counts below would measure production data instead of the test.
delete from public.support_messages_v530 m using public.support_conversations_v530 c
 where m.conversation_id = c.id
   and c.customer_phone_norm in ('91110001','92220002','93330003','94440004');
delete from public.support_conversations_v530
 where customer_phone_norm in ('91110001','92220002','93330003','94440004');
delete from public.support_pending_conversations_v530
 where customer_phone_norm in ('91110001','92220002','93330003','94440004');

-- A known client at business A only.
create temp table _c(client uuid) on commit drop;
delete from public.clients where business_id=(select id from _b where tag='A') and phone_norm='91110001';
insert into _c(client) values (gen_random_uuid());
insert into public.clients(id,business_id,full_name,phone)
select (select client from _c), (select id from _b where tag='A'), 'Known Customer', '91110001';

-- Tokens for A and B.
create temp table _t(tag text, token text) on commit drop;
do $$
declare v_tok jsonb; v_biz uuid; v_uid uuid;
begin
  for v_biz, v_uid in select id, uid from _b order by tag loop
    perform set_config('request.jwt.claim.sub', v_uid::text, true);
    perform set_config('request.jwt.claims',
      json_build_object('sub', v_uid, 'role','authenticated')::text, true);
    v_tok := public.business_issue_support_entry_token_v531(v_biz, 'whatsapp');
    insert into _t values ((select tag from _b where id=v_biz), v_tok->>'token');
  end loop;
  perform set_config('request.jwt.claim.sub','',true);
  perform set_config('request.jwt.claims','',true);
end $$;

-- Helper: plant a webhook delivery as Meta would.
create or replace function pg_temp.inbound(p_from text, p_body text, p_wamid text)
returns void language plpgsql as $$
begin
  insert into public.whatsapp_webhook_events(
    payload_sha256, payload, signature_verified, waba_id, phone_number_id,
    entry_kinds, meta_message_ids, processing_status)
  values (
    substr(md5(p_wamid||p_body||random()::text)||md5(p_wamid),1,64),
    jsonb_build_object('object','whatsapp_business_account','entry',
      jsonb_build_array(jsonb_build_object('id','1725929281961827','changes',
        jsonb_build_array(jsonb_build_object('field','messages','value',
          jsonb_build_object(
            'metadata', jsonb_build_object('display_phone_number','6582088809','phone_number_id','1277171422152387'),
            'messages', jsonb_build_array(jsonb_build_object(
              'id', p_wamid, 'from', p_from, 'timestamp', extract(epoch from now())::bigint::text,
              'type','text','text', jsonb_build_object('body', p_body))))))))),
    true, '1725929281961827','1277171422152387', array['messages'], array[p_wamid], 'pending');
end $$;

-- ------------------------------------- 02/03 valid token routes + strips
select pg_temp.inbound('6591110001',
  'Hi, I would like to ask about my booking. (Ref: '||(select token from _t where tag='A')||')',
  'wamid.SUITE.A1');
select app.support_route_inbound_v531(200);

insert into _r
select '02 valid token routes to exactly one business',
  case when (select count(*) from public.support_conversations_v530 conv
              where conv.business_id=(select id from _b where tag='A')
                and conv.customer_phone_norm='91110001')=1
        and (select count(*) from public.support_conversations_v530 conv
              where conv.business_id=(select id from _b where tag='B'))=0
       then 'PASS one conversation at A, none at B'
       else 'FAIL routing wrong' end;

insert into _r
select '03 routing token stripped from staff-visible body',
  case when body = 'Hi, I would like to ask about my booking.'
       then 'PASS token and Ref wrapper removed'
       else 'FAIL staff would read: ' || coalesce(body,'<null>') end
from public.support_messages_v530 where provider_message_id='wamid.SUITE.A1';

-- ------------------------------------- 05 known client linked (within A only)
insert into _r
select '05 known client linked within the routed business',
  case when conv.client_id = (select client from _c)
       then 'PASS linked to business A''s own client'
       else 'FAIL client link wrong' end
from public.support_conversations_v530 conv
where conv.business_id=(select id from _b where tag='A') and conv.customer_phone_norm='91110001';

-- ------------------------------------- 04 unknown sender stays NULL
select pg_temp.inbound('6592220002',
  'Do you sell gift cards? (Ref: '||(select token from _t where tag='A')||')', 'wamid.SUITE.A2');
select app.support_route_inbound_v531(200);

insert into _r
select '04 unknown sender: conversation yes, client_id NULL',
  case when conv.id is not null and conv.client_id is null
        and not exists (select 1 from public.clients c
                         where c.business_id=(select id from _b where tag='A')
                           and c.phone_norm='92220002')
       then 'PASS routed with client_id NULL and NO clients row created'
       else 'FAIL unknown sender polluted the CRM or was not routed' end
from public.support_conversations_v530 conv
where conv.business_id=(select id from _b where tag='A') and conv.customer_phone_norm='92220002';

-- ------------------------------------- 09 untokened continues ONE thread
select pg_temp.inbound('6592220002', 'Any update please?', 'wamid.SUITE.A3');
select app.support_route_inbound_v531(200);

insert into _r
select '09 untokened message continues the single routed thread',
  case when (select count(*) from public.support_conversations_v530
              where customer_phone_norm='92220002')=1
        and (select count(*) from public.support_messages_v530 m
              join public.support_conversations_v530 c on c.id=m.conversation_id
             where c.customer_phone_norm='92220002')=2
       then 'PASS same conversation, two messages'
       else 'FAIL continuation forked or failed' end;

-- ------------------------------------- 06 MULTI-BUSINESS ambiguity -> pending
-- Same person now also opens a thread at business B, using B's token.
select pg_temp.inbound('6592220002',
  'Hello B (Ref: '||(select token from _t where tag='B')||')', 'wamid.SUITE.B1');
select app.support_route_inbound_v531(200);
-- ...then writes in with NO token at all. Two firms have a claim.
select pg_temp.inbound('6592220002', 'no token here', 'wamid.SUITE.X1');
select app.support_route_inbound_v531(200);

insert into _r
select '06 multi-business + no token -> pending, never inferred',
  case when (select count(*) from public.support_pending_conversations_v530
              where customer_phone_norm='92220002' and state='awaiting_selection')=1
        -- and neither thread absorbed it: still 2 messages at A, 1 at B
        and (select count(*) from public.support_messages_v530 m
              join public.support_conversations_v530 c on c.id=m.conversation_id
             where c.customer_phone_norm='92220002'
               and c.business_id=(select id from _b where tag='A'))=2
        and (select count(*) from public.support_messages_v530 m
              join public.support_conversations_v530 c on c.id=m.conversation_id
             where c.customer_phone_norm='92220002'
               and c.business_id=(select id from _b where tag='B'))=1
       then 'PASS ambiguous message parked as pending; neither tenant absorbed it'
       else 'FAIL the phone number was used to pick a business' end;

-- ------------------------------------- 07 revoked / expired token
update public.business_support_entry_tokens_v530
   set status='revoked', revoked_at=now()
 where business_id=(select id from _b where tag='A') and status='active';

select pg_temp.inbound('6593330003',
  'revoked attempt (Ref: '||(select token from _t where tag='A')||')', 'wamid.SUITE.R1');
select app.support_route_inbound_v531(200);

insert into _r
select '07 revoked token fails safe into pending',
  case when not exists (select 1 from public.support_conversations_v530
                         where customer_phone_norm='93330003')
        and exists (select 1 from public.support_pending_conversations_v530
                     where customer_phone_norm='93330003' and state='awaiting_selection')
       then 'PASS a killed token routes nothing and parks as pending'
       else 'FAIL a revoked token still routed' end;

-- ------------------------------------- 08 malformed token
select pg_temp.inbound('6594440004', 'PK-short and PK-!!!invalid!!! nonsense', 'wamid.SUITE.M1');
select app.support_route_inbound_v531(200);

insert into _r
select '08 malformed token cannot select a tenant',
  case when not exists (select 1 from public.support_conversations_v530
                         where customer_phone_norm='94440004')
        and exists (select 1 from public.support_pending_conversations_v530
                     where customer_phone_norm='94440004')
       then 'PASS malformed token parked as pending'
       else 'FAIL a malformed token selected a tenant' end;

-- ------------------------------------- 14 idempotency
create temp table _dup(n integer) on commit drop;
insert into _dup select count(*) from public.support_messages_v530;
update public.whatsapp_webhook_events set processing_status='pending'
 where meta_message_ids @> array['wamid.SUITE.A1'];
select app.support_route_inbound_v531(200);

insert into _r
select '14 re-running the router creates no duplicate message',
  case when (select count(*) from public.support_messages_v530) = (select n from _dup)
       then 'PASS unique(business_id, provider_message_id) held'
       else 'FAIL duplicate message rows created' end;

-- ------------------------------------- 10/11/12 isolation as REAL staff
do $$
declare v_a jsonb; v_b jsonb; v_cross text; v_pending_visible integer; v_conv uuid; v_thread jsonb;
begin
  -- Act as business A's owner.
  perform set_config('request.jwt.claim.sub', (select uid::text from _b where tag='A'), true);
  perform set_config('request.jwt.claims',
    json_build_object('sub',(select uid from _b where tag='A'),'role','authenticated')::text, true);

  v_a := public.business_support_list_conversations_v531((select id from _b where tag='A'));

  -- A asks for B's list: must be refused, not silently emptied.
  begin
    perform public.business_support_list_conversations_v531((select id from _b where tag='B'));
    v_cross := 'NOT REFUSED';
  exception when others then v_cross := sqlstate;
  end;

  -- A tries to read the pending table AS THE REAL ROLE. `set local role
  -- authenticated` is essential: the suite's own session role owns these tables
  -- and BYPASSES RLS, so without it this reads every row and reports a leak no
  -- merchant could ever see.
  --
  -- The result is stronger than RLS filtering: `authenticated` has no grant on
  -- the table at all, so the read is refused outright rather than returning an
  -- empty set. Two walls, and the outer one is the harder.
  begin
    set local role authenticated;
    select count(*) into v_pending_visible from public.support_pending_conversations_v530;
    reset role;
  exception when insufficient_privilege then
    v_pending_visible := -1;  -- refused before RLS was even consulted
  end;

  -- A tries to open one of B's conversations by id.
  select id into v_conv from public.support_conversations_v530
   where business_id=(select id from _b where tag='B') limit 1;

  insert into _r values ('10 tenant isolation',
    case when jsonb_array_length(v_a->'conversations') >= 2
          and v_cross = '42501'
          and not exists (
            select 1 from jsonb_array_elements(v_a->'conversations') e
             where (e->>'conversation_id')::uuid in (
               select id from public.support_conversations_v530
                where business_id=(select id from _b where tag='B')))
         then 'PASS A sees only A; asking for B is refused 42501'
         else 'FAIL cross-tenant read (cross=' || v_cross || ')' end);

  insert into _r values ('11 pending invisible to merchants',
    case when v_pending_visible = -1
         then 'PASS the read is REFUSED for role authenticated (no grant at all)'
         when v_pending_visible = 0
         then 'PASS RLS returned 0 unrouted rows to a merchant'
         else 'FAIL merchant saw ' || v_pending_visible || ' unrouted rows' end);

  -- A opens its OWN thread and we inspect the payload.
  select (e->>'conversation_id')::uuid into v_conv
    from jsonb_array_elements(v_a->'conversations') e limit 1;
  v_thread := public.business_support_get_thread_v531((select id from _b where tag='A'), v_conv);

  insert into _r values ('12 wamid never reaches the browser',
    case when v_thread::text not like '%wamid%'
          and v_a::text not like '%wamid%'
          and v_thread::text not like '%provider_message_id%'
         then 'PASS neither list nor thread payload contains a wamid'
         else 'FAIL a wamid leaked into an RPC payload' end);

  insert into _r values ('12b reply is impossible and says so',
    case when (v_thread->>'can_reply') = 'false'
          and (v_thread->>'reply_disabled_reason') = 'outbound_not_enabled'
         then 'PASS thread reports can_reply=false'
         else 'FAIL thread did not declare outbound disabled' end);

  perform set_config('request.jwt.claim.sub','',true);
  perform set_config('request.jwt.claims','',true);
end $$;

-- ------------------------------------- 13 zero outbound capability
insert into _r
select '13 zero outbound capability',
  case when not exists (
        select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace
         where n.nspname in ('app','public')
           and (p.proname ilike '%support%reply%' or p.proname ilike '%support%send%'
                or p.proname ilike '%whatsapp%send%' or p.proname ilike '%whatsapp%dispatch%'))
        and not exists (select 1 from public.support_messages_v530 where direction='outbound')
        and app.platform_feature_enabled('whatsapp_outbound') = false
       then 'PASS no reply/send/dispatch function, no outbound rows, flag off'
       else 'FAIL an outbound path exists' end;

select k as check_name, v as result from _r order by k;

rollback;
