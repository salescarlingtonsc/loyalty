-- Rollback-only acceptance for nestly_v572 — retention safety hardening.
-- Run: supabase db query --linked -f db/tests/v572_retention_safety_hardening.sql
-- Any row whose value starts with FAIL is a failure. Nothing is committed.
--
-- THE STANDING CONSTRAINT: retention WhatsApp must remain IMPOSSIBLE. This
-- suite therefore proves the hardening WITHOUT arming anything. The master
-- flag is toggled ONLY inside this transaction (and the rollback restores it),
-- the capability grants that the quota checks need are created inside this
-- transaction, the dispatch driver is only ever called with p_dry_run => true,
-- and check 21 proves net.http_request_queue gained nothing while all of it ran.
--
-- Every check EXECUTES the real function. No check reads pg_get_functiondef as
-- a substitute for behaviour; the two definition reads that remain (09, 22) are
-- assertions about code that must NOT have changed, paired with an executed
-- assertion where one is possible.
--
--   CONSENT
--   01  clients.marketing_consent alone is not consent -> whatsapp_consent_absent
--   02  a real (marketing, whatsapp, granted) row passes the gate and queues
--   03  a later withdrawal flips it back -> whatsapp_consent_withdrawn
--   04  consents refuses UPDATE (23000) but still allows DELETE (PDPA erasure)
--   05  none of the 8 pre-existing marketing_consent=true clients is grandfathered
--   BUSINESS ELIGIBILITY
--   06  a demo firm is refused MARKETING but allowed SUPPORT (scoping matters)
--   07  a workspace-closed firm is refused 'business_not_active'
--   08  unknown channel and unknown intent refuse by name, never transactional
--   09  the C6 support lane is unchanged and still allowed with its 25/day cap
--   COOLDOWN
--   10  two DIFFERENT campaigns, same customer -> the second is cooldown_active
--   11  suppressed and failed rows do NOT start a cooldown
--   12  the window is 30 days
--   QUOTA
--   13  NO OVERSHOOT: cap 3, 7 queued, claim 7 -> exactly 3 leased, 4 left
--   14  IDEMPOTENT RE-CLAIM: an expired lease re-leases and spends nothing
--   15  RELEASE: a template_fault gives the unit back; used drops by exactly 1
--   16  NO RELEASE ON SENT: an accepted message stays spent
--   17  net counting is backward compatible for ordinary usage rows
--   BYPASS RESISTANCE
--   18  flag off -> the claim RPC itself returns zero rows (a valid POST claims nothing)
--   19  a non-approved template registry row -> zero rows
--   CONTAINMENT
--   20  the dry-run driver returns 'retention_disabled' while the flag is off
--   21  net.http_request_queue gained ZERO rows across the whole suite
--   22  v282 customer push is still dead
--   23  baselines: only this suite's own rows exist; nothing pre-existing moved

begin;

create temp table _r(k text, v text) on commit drop;
create temp table _o(step text, doc jsonb) on commit drop;
create temp table _f(k text primary key, id uuid) on commit drop;
create temp table _n(k text primary key, n bigint) on commit drop;
create temp sequence _phone_seq start 1;

-- Fixture tenants, chosen for what they ARE, not for convenience:
--   BIZ_A  QA Kopi Lab (Bedok)  open, not demo, not synthetic -> consent/cooldown
--   BIZ_B  QA Kaya Toast        open, not demo, not synthetic -> quota
--   CUBBLY Cubbly SPA           is_demo AND the C6 support pilot -> eligibility
create temp table _biz(k text primary key, id uuid) on commit drop;
insert into _biz values
  ('A',      '8ad4a375-2d42-4e0d-b509-b0e4ed6ccf8c'),
  ('B',      '38b30e6d-de73-4c2b-a2ca-19b08950896c'),
  ('cubbly', '8492e8d6-8888-4383-ada0-7e1ed69f0caa');
-- A workspace-closed firm is resolved, not hardcoded: the point is the state,
-- and which row happens to hold it is not this suite's business.
insert into _biz
select 'closed', b.id from public.businesses b
 where not app.business_workspace_open_v94(b.id)
 order by b.id limit 1;

-- ---------------------------------------------------------------- baselines
-- Captured BEFORE anything runs so 21 and 23 compare against the world as it
-- actually was rather than an assumption about it.
create temp table _base_sends as
  select id, status, suppressed_reason from public.retention_sends_v551;
create temp table _base_consented as
  select c.id, c.business_id from public.clients c where coalesce(c.marketing_consent,false);

insert into _n values
  ('http_queue', (select count(*) from net.http_request_queue)),
  ('sends',      (select count(*) from public.retention_sends_v551)),
  ('consents',   (select count(*) from public.consents)),
  ('usage_B',    (select count(*) from public.capability_usage_v518
                   where business_id=(select id from _biz where k='B')
                     and capability_key='whatsapp_retention'
                     and coalesce(detail->>'kind','') <> 'release')),
  ('cubbly_support_used',
     (select (app.capability_state_v518((select id from _biz where k='cubbly'),
              'whatsapp_support_reply')->>'used')::bigint));

-- ------------------------------------------------------------------ helpers
create or replace function pg_temp.mk_client(p_biz uuid, p_label text, p_consent boolean)
returns uuid language plpgsql as $f$
declare v uuid;
begin
  insert into public.clients(business_id, full_name, phone, marketing_consent)
  values (p_biz, 'v572 suite '||p_label,
          '+65 96'||lpad(nextval('_phone_seq')::text, 6, '0'), p_consent)
  returning id into v;
  return v;
end $f$;

create or replace function pg_temp.mk_consent(p_biz uuid, p_client uuid, p_action text)
returns uuid language plpgsql as $f$
declare v uuid;
begin
  insert into public.consents(business_id, client_id, channel, purpose, action, source, created_at)
  values (p_biz, p_client, 'whatsapp', 'marketing', p_action, 'v572_suite', clock_timestamp())
  returning id into v;
  return v;
end $f$;

-- Grants a voucher the way production does: an INSERT on bringback_grants_v361,
-- whose AFTER INSERT trigger IS the enqueue path. Nothing hand-builds a send row.
create or replace function pg_temp.mk_grant(p_biz uuid, p_client uuid, p_label text)
returns uuid language plpgsql as $f$
declare v_camp uuid; v_grant uuid;
begin
  insert into public.bringback_campaigns_v361(business_id, name, reward_label, away_days, active)
  values (p_biz, 'v572 suite campaign '||p_label, 'A free coffee', 60, false)
  returning id into v_camp;
  insert into public.bringback_grants_v361(
    business_id, campaign_id, client_id, reward_label, away_days, cycle_key, status, granted_at)
  values (p_biz, v_camp, p_client, 'A free coffee', 60, current_date, 'granted', now())
  returning id into v_grant;
  return v_grant;
end $f$;

create or replace function pg_temp.send_of(p_grant uuid)
returns text language sql as $f$
  select coalesce(s.status,'<none>')||'/'||coalesce(s.suppressed_reason,'-')
    from public.retention_sends_v551 s where s.grant_id = p_grant
$f$;

-- Exception-catching probes for check 04. A failed statement inside plpgsql
-- unwinds only its own subtransaction, so the suite survives it.
create or replace function pg_temp.try_update_consent(p_id uuid)
returns text language plpgsql as $f$
begin
  update public.consents set source = 'tampered' where id = p_id;
  return 'no_error';
exception when others then return sqlstate;
end $f$;

create or replace function pg_temp.try_delete_consent(p_id uuid)
returns text language plpgsql as $f$
declare n integer;
begin
  delete from public.consents where id = p_id;
  get diagnostics n = row_count;
  return 'deleted:'||n;
exception when others then return sqlstate;
end $f$;

-- ----------------------------------------------- arm the lane, IN-TRANSACTION
-- Everything below needs the platform switch on and a capability granted. Both
-- exist only inside this transaction and both die with the rollback.
update app.platform_feature_flags set enabled = true where feature_key = 'whatsapp_retention_sends';

insert into public.business_capability_grants_v518(
  business_id, capability_key, enabled, limit_count, limit_period, limit_unlimited, note)
values ((select id from _biz where k='A'), 'whatsapp_retention', true, null, 'day', true,
        'v572 suite fixture — rolled back'),
       ((select id from _biz where k='B'), 'whatsapp_retention', true, 3, 'day', false,
        'v572 suite fixture — rolled back')
on conflict (business_id, capability_key) do update
   set enabled = excluded.enabled, limit_count = excluded.limit_count,
       limit_period = excluded.limit_period, limit_unlimited = excluded.limit_unlimited;

-- ======================================================== CONSENT (01 .. 05)

-- Customer A1 has clients.marketing_consent = true and NOTHING else. That is
-- exactly the state all 8 production rows are in.
insert into _f select 'cA1', pg_temp.mk_client((select id from _biz where k='A'), 'A1', true);
insert into _f select 'gA1a', pg_temp.mk_grant((select id from _biz where k='A'),
                                (select id from _f where k='cA1'), 'A1a');

insert into _r
select '01 the till tick alone does not authorise a WhatsApp send',
  case when pg_temp.send_of((select id from _f where k='gA1a')) = 'suppressed/whatsapp_consent_absent'
       then 'PASS marketing_consent=true with no (marketing,whatsapp) row is suppressed by name'
       else 'FAIL '||pg_temp.send_of((select id from _f where k='gA1a')) end;

-- Now the evidence the resolver actually demands.
insert into _f select 'evA1grant', pg_temp.mk_consent((select id from _biz where k='A'),
                                    (select id from _f where k='cA1'), 'granted');
insert into _f select 'gA1b', pg_temp.mk_grant((select id from _biz where k='A'),
                                (select id from _f where k='cA1'), 'A1b');

insert into _r
select '02 one (marketing, whatsapp, granted) row passes the consent gate',
  case when pg_temp.send_of((select id from _f where k='gA1b')) = 'queued/-'
        and coalesce((app.whatsapp_marketing_consent_v572(
              (select id from _biz where k='A'), (select id from _f where k='cA1'))
              ->>'allowed')::boolean, false)
       then 'PASS the same customer now queues; the resolver reports allowed'
       else 'FAIL '||pg_temp.send_of((select id from _f where k='gA1b'))
            ||' resolver='||app.whatsapp_marketing_consent_v572(
               (select id from _biz where k='A'), (select id from _f where k='cA1'))::text end;

-- A later withdrawal on the same pair. Latest event wins over an append-only
-- stream; the grant is still there and is still not the answer.
insert into _f select 'evA1wd', pg_temp.mk_consent((select id from _biz where k='A'),
                                 (select id from _f where k='cA1'), 'withdrawn');
insert into _f select 'gA1c', pg_temp.mk_grant((select id from _biz where k='A'),
                                (select id from _f where k='cA1'), 'A1c');

insert into _r
select '03 a later withdrawal wins over the earlier grant',
  case when pg_temp.send_of((select id from _f where k='gA1c')) = 'suppressed/whatsapp_consent_withdrawn'
        and (app.whatsapp_marketing_consent_v572(
              (select id from _biz where k='A'), (select id from _f where k='cA1'))
              ->>'evidence_id')::uuid = (select id from _f where k='evA1wd')
        and (select count(*) from public.consents
              where client_id=(select id from _f where k='cA1'))=2
       then 'PASS latest-event-wins, and the grant row was appended to, not edited'
       else 'FAIL '||pg_temp.send_of((select id from _f where k='gA1c'))
            ||' evidence='||app.whatsapp_marketing_consent_v572(
               (select id from _biz where k='A'), (select id from _f where k='cA1'))::text end;

-- 04 append-only, but erasable. The guard is UPDATE-only on purpose:
-- consents.client_id is ON DELETE CASCADE from clients, so a DELETE guard would
-- break the PDPA erasure the evidence exists to serve.
insert into _f select 'evDel', pg_temp.mk_consent((select id from _biz where k='A'),
                                (select id from _f where k='cA1'), 'granted');

insert into _r
select '04 consents refuses UPDATE but still permits DELETE',
  case when pg_temp.try_update_consent((select id from _f where k='evA1grant')) = '23000'
        and (select source from public.consents where id=(select id from _f where k='evA1grant')) is distinct from 'tampered'
        and pg_temp.try_delete_consent((select id from _f where k='evDel')) = 'deleted:1'
       then 'PASS 23000 on UPDATE, row untouched; DELETE still works for client erasure'
       else 'FAIL update='||pg_temp.try_update_consent((select id from _f where k='evA1grant'))
            ||' delete='||pg_temp.try_delete_consent((select id from _f where k='evDel')) end;

insert into _r
select '05 nobody in production is grandfathered',
  case when (select count(*) from _base_consented) = 8
        and (select count(*) from _base_consented b
              where coalesce((app.whatsapp_marketing_consent_v572(b.business_id, b.id)
                              ->>'allowed')::boolean, false)) = 0
       then 'PASS all 8 pre-existing marketing_consent=true clients still fail the WhatsApp gate'
       else 'FAIL '||(select count(*) from _base_consented)::text||' consented clients, '
            ||(select count(*) from _base_consented b
                where coalesce((app.whatsapp_marketing_consent_v572(b.business_id, b.id)
                                ->>'allowed')::boolean, false))::text||' of them pass' end;

-- ============================================ BUSINESS ELIGIBILITY (06 .. 09)

insert into _o select 'demo_mkt', app.business_may_initiate_comms_v572(
  (select id from _biz where k='cubbly'), 'whatsapp', 'marketing');
insert into _o select 'demo_sup', app.business_may_initiate_comms_v572(
  (select id from _biz where k='cubbly'), 'whatsapp', 'support');

insert into _r
select '06 a demo firm is refused marketing yet still allowed support',
  case when (select doc->>'reason' from _o where step='demo_mkt')='demo_business_marketing'
        and (select doc->>'allowed' from _o where step='demo_mkt')='false'
        and (select doc->>'allowed' from _o where step='demo_sup')='true'
       then 'PASS the demo refusal is intent-scoped, so adopting this resolver cannot break C6'
       else 'FAIL marketing='||(select doc::text from _o where step='demo_mkt')
            ||' support='||(select doc::text from _o where step='demo_sup') end;

insert into _o select 'closed', app.business_may_initiate_comms_v572(
  (select id from _biz where k='closed'), 'whatsapp', 'marketing');

insert into _r
select '07 a workspace-closed firm may not initiate comms',
  case when (select count(*) from _biz where k='closed')=1
        and (select doc->>'reason' from _o where step='closed')='business_not_active'
       then 'PASS the same signal, and the same reason string, that support has used since v535'
       else 'FAIL '||coalesce((select doc::text from _o where step='closed'),'<no closed business found>') end;

insert into _o select 'bad_channel', app.business_may_initiate_comms_v572(
  (select id from _biz where k='A'), 'carrier_pigeon', 'marketing');
insert into _o select 'bad_intent', app.business_may_initiate_comms_v572(
  (select id from _biz where k='A'), 'whatsapp', 'nudge');
insert into _o select 'null_intent', app.business_may_initiate_comms_v572(
  (select id from _biz where k='A'), 'whatsapp', null);

insert into _r
select '08 an unknown channel or intent refuses by name, never as transactional',
  case when (select doc->>'reason' from _o where step='bad_channel')='channel_unknown'
        and (select doc->>'reason' from _o where step='bad_intent')='intent_unknown'
        and (select doc->>'reason' from _o where step='null_intent')='intent_unknown'
        and (select count(*) from _o where step in ('bad_channel','bad_intent','null_intent')
              and doc->>'allowed'='true')=0
       then 'PASS an unrecognised question is refused, not answered with the permissive default'
       else 'FAIL '||(select string_agg(step||'='||doc::text, ' ') from _o
                       where step in ('bad_channel','bad_intent','null_intent')) end;

insert into _o select 'cubbly_support_cap', app.capability_state_v518(
  (select id from _biz where k='cubbly'), 'whatsapp_support_reply');

insert into _r
select '09 the C6 support lane is untouched and still allowed',
  case when pg_get_functiondef('app.support_reply_v535'::regproc) ilike '%business_workspace_open_v94%'
        and (select doc->>'allowed' from _o where step='cubbly_support_cap')='true'
        and (select doc->>'reason' from _o where step='cubbly_support_cap')='ok'
        and (select doc->>'limit_count' from _o where step='cubbly_support_cap')='25'
        and (select doc->>'limit_period' from _o where step='cubbly_support_cap')='day'
       then 'PASS support still carries its own workspace gate and its 25/day pilot cap'
       else 'FAIL '||coalesce((select doc::text from _o where step='cubbly_support_cap'),'<none>') end;

-- ======================================================= COOLDOWN (10 .. 12)

-- Customer A2, fully consented, granted a voucher by TWO DIFFERENT campaigns.
insert into _f select 'cA2', pg_temp.mk_client((select id from _biz where k='A'), 'A2', true);
insert into _f select 'evA2', pg_temp.mk_consent((select id from _biz where k='A'),
                               (select id from _f where k='cA2'), 'granted');
insert into _f select 'gA2a', pg_temp.mk_grant((select id from _biz where k='A'),
                                (select id from _f where k='cA2'), 'A2a');
insert into _f select 'gA2b', pg_temp.mk_grant((select id from _biz where k='A'),
                                (select id from _f where k='cA2'), 'A2b');

insert into _r
select '10 two campaigns cannot each message the same customer',
  case when pg_temp.send_of((select id from _f where k='gA2a')) = 'queued/-'
        and pg_temp.send_of((select id from _f where k='gA2b')) = 'suppressed/cooldown_active'
        and (select campaign_id from public.bringback_grants_v361 where id=(select id from _f where k='gA2a'))
            <> (select campaign_id from public.bringback_grants_v361 where id=(select id from _f where k='gA2b'))
       then 'PASS the cooldown holds ACROSS campaigns, not merely per grant'
       else 'FAIL first='||pg_temp.send_of((select id from _f where k='gA2a'))
            ||' second='||pg_temp.send_of((select id from _f where k='gA2b')) end;

-- 11 A config fault must not silence a customer for a month. Two halves:
--    (a) customer A1's only earlier rows were SUPPRESSED, and its later grant
--        still queued (asserted in 02) rather than hitting cooldown_active;
--    (b) a FAILED row, asserted directly against the cooldown predicate.
insert into _f select 'cA3', pg_temp.mk_client((select id from _biz where k='A'), 'A3', true);
insert into _f select 'evA3', pg_temp.mk_consent((select id from _biz where k='A'),
                               (select id from _f where k='cA3'), 'granted');
insert into _f select 'gA3', pg_temp.mk_grant((select id from _biz where k='A'),
                              (select id from _f where k='cA3'), 'A3');
update public.retention_sends_v551
   set status='failed', status_rank=app.v551_retention_status_rank('failed'), failed_at=now()
 where grant_id=(select id from _f where k='gA3');

insert into _r
select '11 a suppressed or failed row starts no cooldown',
  case when not app.retention_in_cooldown_v572(
             (select id from _biz where k='A'), (select id from _f where k='cA3'))
        and pg_temp.send_of((select id from _f where k='gA1b')) = 'queued/-'
        and not app.retention_in_cooldown_v572(
             (select id from _biz where k='A'), (select id from _f where k='cA1'),
             (select id from public.retention_sends_v551 where grant_id=(select id from _f where k='gA1b')))
       then 'PASS neither a never-delivered failure nor a suppression can mute a customer'
       else 'FAIL failed_client_in_cooldown='
            ||app.retention_in_cooldown_v572((select id from _biz where k='A'),
                 (select id from _f where k='cA3'))::text
            ||' A1b='||pg_temp.send_of((select id from _f where k='gA1b')) end;

insert into _r
select '12 the cooldown window is 30 days',
  case when app.retention_cooldown_days_v572() = 30
       then 'PASS one call site, one number, 30 days'
       else 'FAIL app.retention_cooldown_days_v572() = '||app.retention_cooldown_days_v572()::text end;

-- ========================================================== QUOTA (13 .. 17)
-- BIZ_B is capped at 3/day (granted above, inside this transaction). Seven
-- DISTINCT customers are used so the cooldown cannot interfere with the count:
-- this check is about the quota and nothing else.
--
-- internal_retention_claim_v551 is a PLATFORM-WIDE claim: it sweeps every
-- business, not one. The consent and cooldown fixtures above left live rows at
-- BIZ_A (which holds an UNLIMITED grant), and an earlier draft of this suite
-- counted those in the lease and read 4 where the cap said 3 — a false alarm
-- against correct code. The BIZ_A fixture is therefore parked first, so the
-- overshoot question is asked of exactly one capped tenant. The precondition
-- below asserts the parking worked: if any row outside BIZ_B is still claimable
-- when check 13 runs, check 13 fails loudly rather than measuring the wrong set.
update public.retention_sends_v551
   set status = 'suppressed', suppressed_reason = 'v572_suite_parked',
       status_rank = app.v551_retention_status_rank('suppressed')
 where business_id = (select id from _biz where k='A')
   and status in ('queued','processing');

do $seed$
declare i integer; v_biz uuid; v_client uuid;
begin
  select id into v_biz from _biz where k='B';
  for i in 1..7 loop
    v_client := pg_temp.mk_client(v_biz, 'B'||i, true);
    perform pg_temp.mk_consent(v_biz, v_client, 'granted');
    perform pg_temp.mk_grant(v_biz, v_client, 'B'||i);
  end loop;
end $seed$;

insert into _n select 'queued_B_before', count(*) from public.retention_sends_v551
 where business_id=(select id from _biz where k='B') and status='queued';
insert into _n select 'claimable_elsewhere', count(*) from public.retention_sends_v551
 where business_id <> (select id from _biz where k='B') and status in ('queued','processing');

create temp table _c1 on commit drop as
  select * from public.internal_retention_claim_v551('v572-suite', 7, 120);

insert into _r
select '13 a batch cannot overshoot the cap',
  case when (select n from _n where k='queued_B_before')=7
        and (select n from _n where k='claimable_elsewhere')=0
        and (select count(*) from _c1)=3
        and (select count(*) from public.retention_sends_v551
              where business_id=(select id from _biz where k='B') and status='queued')=4
        and (select count(*) from public.capability_usage_v518
              where business_id=(select id from _biz where k='B')
                and capability_key='whatsapp_retention'
                and coalesce(detail->>'kind','') <> 'release')
            = (select n from _n where k='usage_B') + 3
       then 'PASS 7 asked, cap 3: exactly 3 leased, 4 left queued, exactly 3 units reserved'
       else 'FAIL queued_before='||(select n from _n where k='queued_B_before')::text
            ||' claimable_elsewhere='||(select n from _n where k='claimable_elsewhere')::text
            ||' leased='||(select count(*) from _c1)::text
            ||' still_queued='||(select count(*) from public.retention_sends_v551
                 where business_id=(select id from _biz where k='B') and status='queued')::text
            ||' usage='||(select count(*) from public.capability_usage_v518
                 where business_id=(select id from _biz where k='B')
                   and capability_key='whatsapp_retention'
                   and coalesce(detail->>'kind','') <> 'release')::text end;

-- 14 The worker died holding the lease. The row must come back, and it must
-- come back FREE: the idem key is the row's own id, so the consume is a
-- duplicate and the cap does not drift downward across retries.
update public.retention_sends_v551
   set lease_until = now() - interval '1 hour'
 where id in (select message_id from _c1);

create temp table _c2 on commit drop as
  select * from public.internal_retention_claim_v551('v572-suite-2', 7, 120);

insert into _r
select '14 re-claiming an expired lease spends nothing',
  case when (select count(*) from _c2)=3
        and (select count(*) from _c2 where message_id in (select message_id from _c1))=3
        and (select count(*) from public.capability_usage_v518
              where business_id=(select id from _biz where k='B')
                and capability_key='whatsapp_retention'
                and coalesce(detail->>'kind','') <> 'release')
            = (select n from _n where k='usage_B') + 3
        and (select count(*) from public.retention_sends_v551
              where business_id=(select id from _biz where k='B') and status='queued')=4
       then 'PASS the same three rows re-leased on idem key v551:<id>; usage did not grow'
       else 'FAIL released='||(select count(*) from _c2)::text
            ||' same='||(select count(*) from _c2 where message_id in (select message_id from _c1))::text
            ||' usage='||(select count(*) from public.capability_usage_v518
                 where business_id=(select id from _biz where k='B')
                   and capability_key='whatsapp_retention'
                   and coalesce(detail->>'kind','') <> 'release')::text end;

insert into _f select 'fault_row', (select message_id from _c2 order by message_id limit 1);
insert into _f select 'sent_row',  (select message_id from _c2 order by message_id offset 1 limit 1);

insert into _n select 'used_before_release',
  (app.capability_state_v518((select id from _biz where k='B'),'whatsapp_retention')->>'used')::bigint;

insert into _o select 'report_fault', public.internal_retention_report_v551(
  (select id from _f where k='fault_row'),
  (select lease_token from _c2 where message_id=(select id from _f where k='fault_row')),
  'template_fault');

insert into _n select 'used_after_release',
  (app.capability_state_v518((select id from _biz where k='B'),'whatsapp_retention')->>'used')::bigint;

insert into _r
select '15 a template fault gives the merchant the unit back',
  case when (select doc->>'quota_released' from _o where step='report_fault')='true'
        and (select count(*) from public.capability_usage_v518
              where business_id=(select id from _biz where k='B')
                and capability_key='whatsapp_retention'
                and detail->>'kind'='release')=1
        and (select n from _n where k='used_after_release')
            = (select n from _n where k='used_before_release') - 1
        and (select count(*) from public.capability_usage_v518
              where business_id=(select id from _biz where k='B')
                and capability_key='whatsapp_retention'
                and idem_key='v551:'||(select id from _f where k='fault_row')::text)=1
       then 'PASS a compensating row is APPENDED (the reservation is untouched) and used drops by exactly 1'
       else 'FAIL report='||(select doc::text from _o where step='report_fault')
            ||' used '||(select n from _n where k='used_before_release')::text
            ||' -> '||(select n from _n where k='used_after_release')::text end;

insert into _o select 'report_sent', public.internal_retention_report_v551(
  (select id from _f where k='sent_row'),
  (select lease_token from _c2 where message_id=(select id from _f where k='sent_row')),
  'sent', 'wamid.v572-suite-not-real');

insert into _r
select '16 an accepted message stays spent',
  case when (select doc->>'quota_released' from _o where step='report_sent')='false'
        and (app.capability_state_v518((select id from _biz where k='B'),'whatsapp_retention')->>'used')::bigint
            = (select n from _n where k='used_after_release')
        and (select count(*) from public.capability_usage_v518
              where business_id=(select id from _biz where k='B')
                and capability_key='whatsapp_retention'
                and detail->>'kind'='release')=1
       then 'PASS once Meta accepted it, no unit comes back'
       else 'FAIL report='||(select doc::text from _o where step='report_sent')
            ||' used='||(app.capability_state_v518((select id from _biz where k='B'),
                          'whatsapp_retention')->>'used') end;

-- 17 Every historical usage row, and every row from the support and appointment
-- lanes, carries no detail->>'kind'. Net counting must count them exactly +1.
insert into public.capability_usage_v518(business_id, capability_key, period_key, idem_key, detail, consumed_at)
select (select id from _biz where k='cubbly'), 'whatsapp_support_reply',
       app.v365_period_key('day', now()), 'v572-suite-ordinary-'||g,
       case g when 1 then '{}'::jsonb
              when 2 then '{}'::jsonb
              when 3 then jsonb_build_object('note','no kind key at all')
              else jsonb_build_object('kind','support_reply') end,
       now()
from generate_series(1,4) g;

insert into _r
select '17 ordinary usage rows still count exactly as before',
  case when (app.capability_state_v518((select id from _biz where k='cubbly'),
              'whatsapp_support_reply')->>'used')::bigint
            = (select n from _n where k='cubbly_support_used') + 4
        and (app.capability_state_v518((select id from _biz where k='cubbly'),
              'whatsapp_support_reply')->>'allowed')='true'
       then 'PASS four rows without a release kind moved used by exactly four; support is unaffected'
       else 'FAIL used='||(app.capability_state_v518((select id from _biz where k='cubbly'),
                            'whatsapp_support_reply')->>'used')
            ||' baseline='||(select n from _n where k='cubbly_support_used')::text end;

-- =============================================== BYPASS RESISTANCE (18 .. 19)
-- 18 is the direct-POST question. An attacker holding a valid dispatch secret
-- reaches the edge function, which calls this RPC. With the master flag off the
-- RPC itself hands out nothing, so the secret buys no messages. Four rows are
-- still queued and one quota unit is still free, so a pass here is not vacuous.

update app.platform_feature_flags set enabled = false where feature_key = 'whatsapp_retention_sends';

create temp table _c_flagoff on commit drop as
  select * from public.internal_retention_claim_v551('v572-suite-bypass', 7, 120);

insert into _r
select '18 with the flag off the claim RPC itself yields nothing',
  case when (select count(*) from _c_flagoff)=0
        and (select count(*) from public.retention_sends_v551
              where business_id=(select id from _biz where k='B') and status='queued')=4
        and ((app.capability_state_v518((select id from _biz where k='B'),
              'whatsapp_retention')->>'used')::bigint) < 3
       then 'PASS a valid secret posted straight at the edge function claims zero rows'
       else 'FAIL claimed='||(select count(*) from _c_flagoff)::text
            ||' queued='||(select count(*) from public.retention_sends_v551
                 where business_id=(select id from _biz where k='B') and status='queued')::text end;

-- 19 The registry is the other floor under the lane: an un-approved template
-- must not be dispatchable even when everything else is satisfied.
update app.platform_feature_flags set enabled = true where feature_key = 'whatsapp_retention_sends';
update public.whatsapp_template_registry_v551 set status='paused' where template_key='bring_back_v1';

create temp table _c_paused on commit drop as
  select * from public.internal_retention_claim_v551('v572-suite-template', 7, 120);

update public.whatsapp_template_registry_v551 set status='approved' where template_key='bring_back_v1';

create temp table _c_approved on commit drop as
  select * from public.internal_retention_claim_v551('v572-suite-template2', 7, 120);

insert into _r
select '19 an un-approved template claims nothing',
  case when (select count(*) from _c_paused)=0
        and (select count(*) from _c_approved)=1
       then 'PASS status<>approved yields zero; restoring approval yields the one remaining quota unit, so 19 is not vacuous'
       else 'FAIL paused='||(select count(*) from _c_paused)::text
            ||' approved='||(select count(*) from _c_approved)::text end;

-- ==================================================== CONTAINMENT (20 .. 23)

update app.platform_feature_flags set enabled = false where feature_key = 'whatsapp_retention_sends';
insert into _o select 'dispatch', app.v551_run_retention_dispatch(true);

insert into _r
select '20 the dispatch driver refuses while the switch is off',
  case when (select doc->>'dispatch' from _o where step='dispatch')='retention_disabled'
       then 'PASS the master switch is still the first gate, even in dry run'
       else 'FAIL '||coalesce((select doc::text from _o where step='dispatch'),'<none>') end;

insert into _r
select '21 no HTTP request was fired by any of the above',
  case when (select count(*) from net.http_request_queue) = (select n from _n where k='http_queue')
       then 'PASS every gate, claim, report and dispatch above executed with the POST withheld'
       else 'FAIL net.http_request_queue grew from '||(select n from _n where k='http_queue')::text
            ||' to '||(select count(*) from net.http_request_queue)::text end;

insert into _r
select '22 the v282 customer push dispatcher is still dead',
  case when pg_get_functiondef('app.v282_run_customer_push_dispatch()'::regprocedure) ilike '%v282_supabase_url%'
        and not exists (select 1 from vault.secrets where name in ('v282_supabase_url','v156_supabase_url'))
       then 'PASS v282 still names a vault key that does not exist; v572 created none'
       else 'FAIL v282 push may have been reactivated as a side effect' end;

-- 23 The fixture is exactly 13 send rows: 3 for customer A1 (absent, queued,
-- withdrawn), 2 for A2 (queued, cooldown), 1 for A3 (failed), 7 for BIZ_B.
-- Nothing pre-existing may have changed status, and nothing outside this
-- transaction's own tenants may have been touched.
insert into _r
select '23 only this suite''s own rows exist, and nothing pre-existing moved',
  case when (select count(*) from public.retention_sends_v551) = (select n from _n where k='sends') + 13
        and (select count(*) from public.retention_sends_v551 s
              where s.id not in (select id from _base_sends)
                and s.business_id not in (select id from _biz where k in ('A','B')))=0
        and (select count(*) from _base_sends b
              join public.retention_sends_v551 s on s.id=b.id
             where s.status is distinct from b.status
                or s.suppressed_reason is distinct from b.suppressed_reason)=0
        and (select count(*) from _base_sends b
             where not exists (select 1 from public.retention_sends_v551 s where s.id=b.id))=0
       then 'PASS 13 fixture rows, all inside the two fixture tenants; every pre-existing row is byte-identical'
       else 'FAIL sends '||(select n from _n where k='sends')::text||' -> '
            ||(select count(*) from public.retention_sends_v551)::text
            ||', moved='||(select count(*) from _base_sends b
                 join public.retention_sends_v551 s on s.id=b.id
                where s.status is distinct from b.status
                   or s.suppressed_reason is distinct from b.suppressed_reason)::text end;

select k as check_name, v as result from _r order by k;

rollback;
