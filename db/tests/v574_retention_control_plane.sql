-- Rollback-only acceptance for nestly_v574 — retention control plane + consent capture.
-- Run: supabase db query --linked -f db/tests/v574_retention_control_plane.sql
-- Any row whose value starts with FAIL is a failure. Nothing is committed.
--
-- THE STANDING CONSTRAINT, unchanged since v571: retention WhatsApp must remain
-- IMPOSSIBLE. This suite therefore proves the control plane WITHOUT arming it.
-- The master flag is toggled ONLY inside this transaction and restored to false
-- before check 26 reads it; every capability grant is created inside this
-- transaction; no dispatch driver is called without p_dry_run; and check 27
-- proves net.http_request_queue gained nothing while all of it ran.
--
-- Every check EXECUTES the real function. The three definition reads that
-- remain (09c enumeration, 25, 28) are assertions about code that must NOT have
-- changed, and each is paired with an executed assertion where one is possible.
--
--   CONSENT CAPTURE
--   01  a verified customer's own grant appends the evidence v572 demands
--   02  the notice is pinned SERVER-SIDE; the signature has no notice parameter
--   03  TENANT isolation: a grant for A does not make B allowed
--   04  CHANNEL isolation: no sms/email row appears; channel='marketing' is not it
--   05  PURPOSE isolation: purpose='transactional' does not satisfy the resolver
--   06  a withdrawal overrides, and the grant row still EXISTS (append-only)
--   07  grant -> withdraw -> grant leaves 3 rows in order; latest wins
--   08  IDEMPOTENCY: same key = duplicate, no second row; opposite choice = 23505
--   09  STAFF CANNOT MANUFACTURE IT (42501 three ways: writer, RLS, enumeration)
--   10  PDPA erasure still cascades consents away
--   11  no verified link -> 'not_linked_to_business'
--   12  a grant raises clients.marketing_consent; a withdrawal does not clear it
--   PLATFORM HOLD
--   13  a caller without platform automation rw is refused 42501
--   14  a hold does NOT mutate bringback_campaigns_v361.active
--   15  audit_log names the PLATFORM ADMINISTRATOR
--   16  a held business suppresses enqueue by name: 'platform_hold'
--   17  a hold placed AFTER queueing suppresses the queued row at claim time
--   18  RELEASE restores nothing because nothing was taken: active is untouched
--   19  optimistic concurrency: a stale expected version raises 40001
--   20  campaign scope holds one campaign; business scope outranks and holds all
--   21  a reason shorter than 3 characters is refused 22023
--   APPOINTMENT GATE
--   22  a workspace-CLOSED business is now refused 'business_not_active'
--   23  a demo firm passes the business gate at TRANSACTIONAL intent
--   24  the appointment claim filters a business that became ineligible
--   25  C6 human support is unchanged
--   CONTAINMENT
--   26  the switch is off, no tenant is allowed, nothing was ever sent
--   27  net.http_request_queue gained ZERO rows across the whole suite
--   28  v282 customer push is still dead
--   29  baselines: only this suite's own rows exist; nothing pre-existing moved

begin;

create temp table _r(k text, v text) on commit drop;
create temp table _o(step text, doc jsonb) on commit drop;
create temp table _e(step text, sqlstate text, msg text) on commit drop;
create temp table _f(k text primary key, id uuid) on commit drop;
create temp table _n(k text primary key, n bigint) on commit drop;
create temp sequence _phone_seq start 1;

-- Fixture tenants, chosen for what they ARE:
--   A       QA Kopi Lab (Bedok)  open, not demo, not synthetic
--   B       QA Kaya Toast        open, not demo — the second tenant for isolation
--   cubbly  Cubbly SPA           is_demo AND the C6 support pilot
create temp table _biz(k text primary key, id uuid) on commit drop;
insert into _biz values
  ('A',      '8ad4a375-2d42-4e0d-b509-b0e4ed6ccf8c'),
  ('B',      '38b30e6d-de73-4c2b-a2ca-19b08950896c'),
  ('cubbly', '8492e8d6-8888-4383-ada0-7e1ed69f0caa');
-- The workspace-closed firm is RESOLVED, not hardcoded: the point is the state.
insert into _biz
select 'closed', b.id from public.businesses b
 where not app.business_workspace_open_v94(b.id)
   and not coalesce(b.is_synthetic,false)
 order by b.id limit 1;

-- ---------------------------------------------------------------- baselines
-- Captured BEFORE anything runs so 26/27/29 compare against the world as it
-- actually was rather than an assumption about it.
create temp table _base_consents as
  select id, business_id, client_id, channel, purpose, action, source, actor,
         notice_version, notice_sha256, request_hash, idempotency_key, created_at
    from public.consents;
create temp table _base_sends as
  select id, status, suppressed_reason from public.retention_sends_v551;
create temp table _base_audit as select id from public.audit_log;
create temp table _base_camps as
  select id, business_id, active from public.bringback_campaigns_v361;
create temp table _base_tmpl as select id from public.whatsapp_template_sends_v557;

insert into _n values
  ('http_queue',   (select count(*) from net.http_request_queue)),
  ('consents',     (select count(*) from public.consents)),
  ('consents_sms_email',
                   (select count(*) from public.consents where channel in ('sms','email'))),
  ('sends',        (select count(*) from public.retention_sends_v551)),
  ('holds',        (select count(*) from public.platform_retention_holds_v574)),
  ('camps',        (select count(*) from public.bringback_campaigns_v361)),
  ('tmpl',         (select count(*) from public.whatsapp_template_sends_v557)),
  ('retention_flag_on',
     (select count(*) from app.platform_feature_flags
       where feature_key='whatsapp_retention_sends' and enabled)),
  ('cap_allowed',
     (select count(*) from public.businesses b
       where coalesce((app.capability_state_v518(b.id,'whatsapp_retention')->>'allowed')::boolean,false)));

-- ------------------------------------------------------------------ helpers
create or replace function pg_temp.as_user(p uuid) returns void language plpgsql as $f$
begin
  perform set_config('request.jwt.claim.sub', coalesce(p::text,''), true);
  perform set_config('request.jwt.claims',
    json_build_object('sub',p,'role','authenticated')::text, true);
end $f$;

create or replace function pg_temp.mk_auth(p_label text) returns uuid
language plpgsql as $f$
declare v uuid := gen_random_uuid();
begin
  insert into auth.users(instance_id,id,aud,role,email,encrypted_password,
                         email_confirmed_at,created_at,updated_at)
  values ('00000000-0000-0000-0000-000000000000', v, 'authenticated','authenticated',
          'v574-'||p_label||'-'||v||'@example.test','',now(),now(),now());
  return v;
end $f$;

create or replace function pg_temp.mk_client(p_biz uuid, p_label text, p_consent boolean)
returns uuid language plpgsql as $f$
declare v uuid;
begin
  insert into public.clients(business_id, full_name, phone, marketing_consent)
  values (p_biz, 'v574 suite '||p_label,
          '+65 97'||lpad(nextval('_phone_seq')::text, 6, '0'), p_consent)
  returning id into v;
  return v;
end $f$;

create or replace function pg_temp.mk_identity(p_auth uuid) returns uuid
language plpgsql as $f$
declare v uuid;
begin
  insert into public.customer_identities(auth_user_id, status, created_via)
  values (p_auth, 'active', 'wallet_start') returning id into v;
  return v;
end $f$;

-- A verified link, created the only way the v31 guard permits: the row's own id
-- announced in app.customer_link_insert_id, state='verified', verified_at set.
-- The guard also makes a PENDING link uncreatable, which is why check 11 uses a
-- customer with no link at all rather than an unverified one.
create or replace function pg_temp.mk_link(p_biz uuid, p_identity uuid, p_auth uuid,
                                           p_client uuid)
returns uuid language plpgsql as $f$
declare v uuid := gen_random_uuid();
begin
  perform set_config('app.customer_link_insert_id', v::text, true);
  insert into public.customer_links(id, business_id, identity_id, auth_user_id, client_id,
                                    state, verification_method, verified_at)
  values (v, p_biz, p_identity, p_auth, p_client, 'verified', 'qr_join', now());
  perform set_config('app.customer_link_insert_id', '', true);
  return v;
end $f$;

-- A consent row written the OLD way, with an explicit timestamp. Used only to
-- stage HISTORY: public.consents.created_at defaults to now(), which is
-- transaction time, so two writer calls inside one transaction would tie and
-- the resolver's (created_at desc, id desc) order would turn on a random uuid.
-- Production never has that problem — each PostgREST call is its own
-- transaction — so the suite stages the earlier events explicitly and always
-- makes the LATEST, decisive event the real function call.
create or replace function pg_temp.stage_consent(p_biz uuid, p_client uuid, p_action text,
  p_channel text, p_purpose text, p_age interval)
returns uuid language plpgsql as $f$
declare v uuid;
begin
  insert into public.consents(business_id, client_id, channel, purpose, action,
                              source, created_at)
  values (p_biz, p_client, p_channel, p_purpose, p_action, 'v574_suite_history',
          now() - p_age)
  returning id into v;
  return v;
end $f$;

create or replace function pg_temp.try_set_consent(p_biz uuid, p_in boolean, p_key text)
returns jsonb language plpgsql as $f$
begin
  return public.customer_set_whatsapp_marketing_consent_v574(p_biz, p_in, p_key);
exception when others then
  return jsonb_build_object('status','error','sqlstate',sqlstate,'message',sqlerrm);
end $f$;

create or replace function pg_temp.try_hold(p_biz uuid, p_camp uuid, p_held boolean,
  p_reason text, p_ver bigint)
returns jsonb language plpgsql as $f$
begin
  return public.platform_set_retention_hold_v574(p_biz, p_camp, p_held, p_reason, p_ver);
exception when others then
  return jsonb_build_object('status','error','sqlstate',sqlstate,'message',sqlerrm);
end $f$;

-- The RLS question, asked as the role a browser actually holds.
create or replace function pg_temp.try_direct_consent_insert(p_biz uuid, p_client uuid)
returns text language plpgsql as $f$
declare v text;
begin
  begin
    execute 'set local role authenticated';
    execute 'insert into public.consents(business_id, client_id, channel, purpose, action, source)
             values ($1,$2,''whatsapp'',''marketing'',''granted'',''forged'')'
      using p_biz, p_client;
    v := 'inserted';
  exception when others then
    v := sqlstate;
  end;
  execute 'reset role';
  return v;
end $f$;

create or replace function pg_temp.mk_grant(p_biz uuid, p_camp uuid, p_client uuid)
returns uuid language plpgsql as $f$
declare v uuid;
begin
  insert into public.bringback_grants_v361(
    business_id, campaign_id, client_id, reward_label, away_days, cycle_key,
    status, granted_at)
  values (p_biz, p_camp, p_client, 'A free coffee', 60,
          current_date, 'granted', now())
  returning id into v;
  return v;
end $f$;

create or replace function pg_temp.send_of(p_grant uuid)
returns text language sql as $f$
  select coalesce(s.status,'<none>')||'/'||coalesce(s.suppressed_reason,'-')
    from public.retention_sends_v551 s where s.grant_id = p_grant
$f$;

-- =================================================== FIXTURE PEOPLE AND ROWS
insert into _f select 'u_cust1',  pg_temp.mk_auth('cust1');
insert into _f select 'u_cust2',  pg_temp.mk_auth('cust2');
insert into _f select 'u_staff',  pg_temp.mk_auth('staff');
insert into _f select 'u_padmin', pg_temp.mk_auth('padmin');

insert into _f select 'id1', pg_temp.mk_identity((select id from _f where k='u_cust1'));
insert into _f select 'id2', pg_temp.mk_identity((select id from _f where k='u_cust2'));

-- CUST1 belongs, verifiably, to BOTH tenants. That is what makes check 03 real.
insert into _f select 'cA1', pg_temp.mk_client((select id from _biz where k='A'), 'A1', false);
insert into _f select 'cB1', pg_temp.mk_client((select id from _biz where k='B'), 'B1', false);
insert into _f select 'lnkA', pg_temp.mk_link((select id from _biz where k='A'),
  (select id from _f where k='id1'), (select id from _f where k='u_cust1'),
  (select id from _f where k='cA1'));
insert into _f select 'lnkB', pg_temp.mk_link((select id from _biz where k='B'),
  (select id from _f where k='id1'), (select id from _f where k='u_cust1'),
  (select id from _f where k='cB1'));

-- CUST2 is a real wallet customer with an active identity and NO link to BIZ_A.
-- Check 11. (The v31 guard forbids creating an unverified link at all, so
-- "no verified link" is expressed as the only state the database allows.)

-- A REAL staff member of BIZ_A: active, with a login, and no customer identity.
insert into public.staff(business_id, user_id, role, full_name, active)
values ((select id from _biz where k='A'), (select id from _f where k='u_staff'),
        'manager', 'v574 suite staff', true);

-- A REAL platform administrator with automation rw and nothing tenant-side.
insert into public.platform_access_grants_v89(
  user_id, role, module_perms, active, created_by, updated_by)
values ((select id from _f where k='u_padmin'), 'admin',
        '{"automation":"rw"}'::jsonb, true,
        (select id from _f where k='u_padmin'), (select id from _f where k='u_padmin'));

-- ==================================================== CONSENT CAPTURE (01..12)

select pg_temp.as_user((select id from _f where k='u_cust1'));
insert into _o select 'grantA', pg_temp.try_set_consent(
  (select id from _biz where k='A'), true, 'v574-suite-key-1');

insert into _r
select '01 a verified customer writes their own consent, and v572 then allows it',
  case when (select doc->>'status' from _o where step='grantA')='ok'
        and (select count(*) from public.consents
              where client_id=(select id from _f where k='cA1')
                and business_id=(select id from _biz where k='A')
                and channel='whatsapp' and purpose='marketing' and action='granted'
                and source='customer_wallet_whatsapp_v574'
                and actor=(select id from _f where k='u_cust1')
                and request_hash ~ '^[0-9a-f]{64}$')=1
        and coalesce((app.whatsapp_marketing_consent_v572(
              (select id from _biz where k='A'), (select id from _f where k='cA1'))
              ->>'allowed')::boolean,false)
       then 'PASS one row, all five fields correct, 64-hex request_hash, resolver allowed'
       else 'FAIL '||coalesce((select doc::text from _o where step='grantA'),'<none>')
            ||' row='||coalesce((select channel||'/'||purpose||'/'||action||'/'||coalesce(source,'-')
                 ||'/'||coalesce(actor::text,'-')||'/'||coalesce(request_hash,'-')
                 from public.consents where client_id=(select id from _f where k='cA1')),'<no row>') end;

insert into _r
select '02 the notice is pinned server-side and is not a parameter',
  case when (select count(*) from public.consents c, app.customer_legal_documents d
              where c.client_id=(select id from _f where k='cA1')
                and d.document_key='privacy' and d.active
                and c.notice_version=d.document_version
                and c.notice_sha256=d.document_sha256)=1
        and (select count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace
              where n.nspname='public'
                and p.proname='customer_set_whatsapp_marketing_consent_v574')=1
        and (select p.pronargs from pg_proc p join pg_namespace n on n.oid=p.pronamespace
              where n.nspname='public'
                and p.proname='customer_set_whatsapp_marketing_consent_v574')=3
       then 'PASS the written digest equals the active notice, and the caller has no way to name one'
       else 'FAIL pinned='||(select count(*) from public.consents c, app.customer_legal_documents d
              where c.client_id=(select id from _f where k='cA1')
                and d.document_key='privacy' and d.active
                and c.notice_version=d.document_version and c.notice_sha256=d.document_sha256)::text
            ||' overloads='||(select count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace
              where n.nspname='public' and p.proname='customer_set_whatsapp_marketing_consent_v574')::text
            ||' args='||coalesce((select p.pronargs from pg_proc p join pg_namespace n on n.oid=p.pronamespace
              where n.nspname='public' and p.proname='customer_set_whatsapp_marketing_consent_v574')::text,'-') end;

insert into _r
select '03 a grant for one business does not consent for another',
  case when (app.whatsapp_marketing_consent_v572(
               (select id from _biz where k='B'), (select id from _f where k='cB1'))
             ->>'reason')='whatsapp_consent_absent'
        and (select count(*) from public.consents
              where business_id=(select id from _biz where k='B')
                and client_id=(select id from _f where k='cB1'))=0
       then 'PASS the same human, verifiably linked to both tenants, is opted in at exactly one'
       else 'FAIL '||app.whatsapp_marketing_consent_v572(
              (select id from _biz where k='B'), (select id from _f where k='cB1'))::text end;

-- 04 CHANNEL isolation. Two halves: the writer created nothing on another
-- channel, and the legacy channel='marketing' row that this database is full of
-- still does not satisfy the resolver.
insert into _f select 'cA3', pg_temp.mk_client((select id from _biz where k='A'), 'A3', true);
insert into _f select 'evMkt', pg_temp.stage_consent((select id from _biz where k='A'),
  (select id from _f where k='cA3'), 'granted', 'marketing', 'marketing', interval '1 hour');

insert into _r
select '04 the WhatsApp grant is not an SMS or email grant, and ''marketing'' is not ''whatsapp''',
  case when (select count(*) from public.consents
              where client_id in (select id from _f where k in ('cA1','cB1'))
                and channel in ('sms','email'))=0
        and (select count(*) from public.consents where channel in ('sms','email'))
            = (select n from _n where k='consents_sms_email')
        and (app.whatsapp_marketing_consent_v572(
               (select id from _biz where k='A'), (select id from _f where k='cA3'))
             ->>'reason')='whatsapp_consent_absent'
       then 'PASS no sms/email row appeared anywhere, and a channel=''marketing'' grant is still not evidence'
       else 'FAIL sms_email_now='||(select count(*) from public.consents where channel in ('sms','email'))::text
            ||' baseline='||(select n from _n where k='consents_sms_email')::text
            ||' legacy='||app.whatsapp_marketing_consent_v572(
               (select id from _biz where k='A'), (select id from _f where k='cA3'))::text end;

-- 05 PURPOSE isolation, on the SAME channel.
insert into _f select 'cA4', pg_temp.mk_client((select id from _biz where k='A'), 'A4', true);
insert into _f select 'evTxn', pg_temp.stage_consent((select id from _biz where k='A'),
  (select id from _f where k='cA4'), 'granted', 'whatsapp', 'transactional', interval '1 hour');

insert into _r
select '05 marketing consent is not implied by a transactional one',
  case when (app.whatsapp_marketing_consent_v572(
               (select id from _biz where k='A'), (select id from _f where k='cA4'))
             ->>'reason')='whatsapp_consent_absent'
        and (select count(*) from public.consents
              where client_id=(select id from _f where k='cA4') and channel='whatsapp')=1
       then 'PASS the resolver matches on BOTH channel and purpose; a whatsapp/transactional row is not enough'
       else 'FAIL '||app.whatsapp_marketing_consent_v572(
              (select id from _biz where k='A'), (select id from _f where k='cA4'))::text end;

-- 06 WITHDRAWAL. The earlier grant is staged an hour back (see stage_consent's
-- comment); the DECISIVE act — the withdrawal — is the real function.
insert into _f select 'cW', pg_temp.mk_client((select id from _biz where k='A'), 'W', true);
insert into _f select 'evWgrant', pg_temp.stage_consent((select id from _biz where k='A'),
  (select id from _f where k='cW'), 'granted', 'whatsapp', 'marketing', interval '1 hour');

-- cW needs its own person: the writer resolves ONE client per (identity,
-- business), and cust1 already owns cA1 there.
insert into _f select 'u_cust3', pg_temp.mk_auth('cust3');
insert into _f select 'id3', pg_temp.mk_identity((select id from _f where k='u_cust3'));
insert into _f select 'lnkW', pg_temp.mk_link((select id from _biz where k='A'),
  (select id from _f where k='id3'), (select id from _f where k='u_cust3'),
  (select id from _f where k='cW'));

select pg_temp.as_user((select id from _f where k='u_cust3'));
insert into _o select 'withdrawW', pg_temp.try_set_consent(
  (select id from _biz where k='A'), false, 'v574-suite-key-w1');

insert into _r
select '06 a withdrawal overrides, and nothing was edited to make it so',
  case when (select doc->>'status' from _o where step='withdrawW')='ok'
        and (app.whatsapp_marketing_consent_v572(
               (select id from _biz where k='A'), (select id from _f where k='cW'))
             ->>'reason')='whatsapp_consent_withdrawn'
        and coalesce((app.whatsapp_marketing_consent_v572(
               (select id from _biz where k='A'), (select id from _f where k='cW'))
             ->>'allowed')::boolean, true) = false
        and exists (select 1 from public.consents
                     where id=(select id from _f where k='evWgrant') and action='granted')
        and (select count(*) from public.consents
              where client_id=(select id from _f where k='cW'))=2
       then 'PASS a NEW withdrawn row outranks the grant, which is still there, still saying granted'
       else 'FAIL '||coalesce((select doc::text from _o where step='withdrawW'),'<none>')
            ||' resolver='||app.whatsapp_marketing_consent_v572(
               (select id from _biz where k='A'), (select id from _f where k='cW'))::text end;

-- 07 grant -> withdraw -> grant. The first two are staged history; the third,
-- decisive, event is the real writer.
insert into _f select 'u_cust4', pg_temp.mk_auth('cust4');
insert into _f select 'id4', pg_temp.mk_identity((select id from _f where k='u_cust4'));
insert into _f select 'cR', pg_temp.mk_client((select id from _biz where k='A'), 'R', false);
insert into _f select 'lnkR', pg_temp.mk_link((select id from _biz where k='A'),
  (select id from _f where k='id4'), (select id from _f where k='u_cust4'),
  (select id from _f where k='cR'));
insert into _f select 'evR1', pg_temp.stage_consent((select id from _biz where k='A'),
  (select id from _f where k='cR'), 'granted', 'whatsapp','marketing', interval '3 hours');
insert into _f select 'evR2', pg_temp.stage_consent((select id from _biz where k='A'),
  (select id from _f where k='cR'), 'withdrawn', 'whatsapp','marketing', interval '2 hours');

select pg_temp.as_user((select id from _f where k='u_cust4'));
insert into _o select 'regrantR', pg_temp.try_set_consent(
  (select id from _biz where k='A'), true, 'v574-suite-key-r3');

insert into _r
select '07 repeated decisions stay auditable, and the latest one wins',
  case when (select array_agg(action order by created_at, id) from public.consents
              where client_id=(select id from _f where k='cR'))
            = array['granted','withdrawn','granted']
        and (select count(*) from public.consents
              where client_id=(select id from _f where k='cR'))=3
        and coalesce((app.whatsapp_marketing_consent_v572(
              (select id from _biz where k='A'), (select id from _f where k='cR'))
              ->>'allowed')::boolean,false)
        and (app.whatsapp_marketing_consent_v572(
              (select id from _biz where k='A'), (select id from _f where k='cR'))
              ->>'source')='customer_wallet_whatsapp_v574'
       then 'PASS three rows in order, none rewritten, and the resolver reads the newest'
       else 'FAIL actions='||coalesce((select array_agg(action order by created_at, id)
              from public.consents where client_id=(select id from _f where k='cR'))::text,'<none>')
            ||' resolver='||app.whatsapp_marketing_consent_v572(
               (select id from _biz where k='A'), (select id from _f where k='cR'))::text end;

-- 08 IDEMPOTENCY, on the key used by check 01.
select pg_temp.as_user((select id from _f where k='u_cust1'));
insert into _o select 'idem_same', pg_temp.try_set_consent(
  (select id from _biz where k='A'), true, 'v574-suite-key-1');
insert into _o select 'idem_opposite', pg_temp.try_set_consent(
  (select id from _biz where k='A'), false, 'v574-suite-key-1');

insert into _r
select '08 a replayed key is a duplicate; the same key for the opposite choice is 23505',
  case when (select doc->>'duplicate' from _o where step='idem_same')='true'
        and (select doc->>'status' from _o where step='idem_same')='ok'
        and (select count(*) from public.consents
              where client_id=(select id from _f where k='cA1'))=1
        and (select doc->>'sqlstate' from _o where step='idem_opposite')='23505'
        and (select count(*) from public.consents
              where client_id=(select id from _f where k='cA1'))=1
       then 'PASS one row survives both replays; the contradictory replay is refused, not resolved'
       else 'FAIL same='||coalesce((select doc::text from _o where step='idem_same'),'<none>')
            ||' opposite='||coalesce((select doc::text from _o where step='idem_opposite'),'<none>')
            ||' rows='||(select count(*) from public.consents
                          where client_id=(select id from _f where k='cA1'))::text end;

-- 09 STAFF CANNOT MANUFACTURE IT — three independent fences.
select pg_temp.as_user((select id from _f where k='u_staff'));
insert into _o select 'staff_write', pg_temp.try_set_consent(
  (select id from _biz where k='A'), true, 'v574-suite-key-staff');

insert into _r
select '09a a real staff member of that very business is refused 42501',
  case when (select doc->>'sqlstate' from _o where step='staff_write')='42501'
        and (select doc->>'message' from _o where step='staff_write')
            = 'only a customer may set their own messaging permission'
        and (select count(*) from public.consents where source='customer_wallet_whatsapp_v574'
              and actor=(select id from _f where k='u_staff'))=0
       then 'PASS staff have no customer_identities row, so they cannot even name the customer'
       else 'FAIL '||coalesce((select doc::text from _o where step='staff_write'),'<none>') end;

insert into _r
select '09b as role authenticated, a direct INSERT into public.consents is refused',
  case when pg_temp.try_direct_consent_insert(
             (select id from _biz where k='A'), (select id from _f where k='cA1')) = '42501'
        and (select count(*) from public.consents where source='forged')=0
       then 'PASS consents has no INSERT policy at all; the browser role cannot write evidence'
       else 'FAIL direct insert returned '||pg_temp.try_direct_consent_insert(
              (select id from _biz where k='A'), (select id from _f where k='cA1')) end;

insert into _r
select '09c only two functions in the database can write a whatsapp consents row',
  case when (select array_agg(n.nspname||'.'||p.proname order by n.nspname, p.proname)
               from pg_proc p join pg_namespace n on n.oid=p.pronamespace
              where n.nspname in ('public','app')
                and p.prosrc ~* 'insert\s+into\s+(public\.)?consents'
                and p.prosrc ~* '''whatsapp''')
            = array['app.v551_ingest_retention_optout',
                    'public.customer_set_whatsapp_marketing_consent_v574']
        and (select p.prosrc from pg_proc p join pg_namespace n on n.oid=p.pronamespace
              where n.nspname='app' and p.proname='v551_ingest_retention_optout')
            not ilike '%''granted''%'
       then 'PASS the customer''s own writer, plus the STOP ingester which can only ever withdraw'
       else 'FAIL writers='||coalesce((select array_agg(n.nspname||'.'||p.proname order by n.nspname, p.proname)
               from pg_proc p join pg_namespace n on n.oid=p.pronamespace
              where n.nspname in ('public','app')
                and p.prosrc ~* 'insert\s+into\s+(public\.)?consents'
                and p.prosrc ~* '''whatsapp''')::text,'<none>') end;

-- 10 PDPA erasure. consents.client_id is ON DELETE CASCADE and the v572 guard is
-- UPDATE-only, so deleting the human deletes their evidence.
insert into _f select 'cE', pg_temp.mk_client((select id from _biz where k='A'), 'E', true);
insert into _f select 'evE', pg_temp.stage_consent((select id from _biz where k='A'),
  (select id from _f where k='cE'), 'granted', 'whatsapp','marketing', interval '1 hour');
delete from public.clients where id=(select id from _f where k='cE');

insert into _r
select '10 erasing a customer still erases their consent rows',
  case when (select count(*) from public.clients where id=(select id from _f where k='cE'))=0
        and (select count(*) from public.consents where client_id=(select id from _f where k='cE'))=0
       then 'PASS the append-only trigger guards UPDATE only, so PDPA erasure is not blocked'
       else 'FAIL clients='||(select count(*) from public.clients
                where id=(select id from _f where k='cE'))::text
            ||' consents='||(select count(*) from public.consents
                where client_id=(select id from _f where k='cE'))::text end;

-- 11 no verified link.
select pg_temp.as_user((select id from _f where k='u_cust2'));
insert into _o select 'unlinked', pg_temp.try_set_consent(
  (select id from _biz where k='A'), true, 'v574-suite-key-unlinked');

insert into _r
select '11 a customer with no verified link to the business is refused by name',
  case when (select doc->>'status' from _o where step='unlinked')='refused'
        and (select doc->>'reason' from _o where step='unlinked')='not_linked_to_business'
        and (select count(*) from public.consents where actor=(select id from _f where k='u_cust2'))=0
       then 'PASS a wallet identity with no verified link to this firm cannot record consent for it'
       else 'FAIL '||coalesce((select doc::text from _o where step='unlinked'),'<none>') end;

insert into _r
select '12 a grant raises clients.marketing_consent; a withdrawal does not clear it',
  case when (select marketing_consent from public.clients
              where id=(select id from _f where k='cA1'))
        and (select marketing_consent from public.clients
              where id=(select id from _f where k='cW'))
        and (select marketing_consent from public.clients
              where id=(select id from _f where k='cR'))
       then 'PASS the v572 pre-filter can no longer dead-end an opted-in customer, and the flag also speaks for email/SMS'
       else 'FAIL cA1='||(select marketing_consent from public.clients
              where id=(select id from _f where k='cA1'))::text
            ||' cW='||(select marketing_consent from public.clients
              where id=(select id from _f where k='cW'))::text
            ||' cR='||(select marketing_consent from public.clients
              where id=(select id from _f where k='cR'))::text end;

-- ====================================================== PLATFORM HOLD (13..21)

insert into public.bringback_campaigns_v361(business_id, name, reward_label, away_days, active)
values ((select id from _biz where k='A'), 'v574 suite campaign one', 'A free coffee', 60, true);
insert into _f select 'camp1', id from public.bringback_campaigns_v361
 where name='v574 suite campaign one';
insert into public.bringback_campaigns_v361(business_id, name, reward_label, away_days, active)
values ((select id from _biz where k='A'), 'v574 suite campaign two', 'A free coffee', 90, true);
insert into _f select 'camp2', id from public.bringback_campaigns_v361
 where name='v574 suite campaign two';

-- The merchant's own column, snapshotted before a single hold exists.
create temp table _camp_before as
  select id, business_id, active from public.bringback_campaigns_v361;

-- 13 a caller without platform automation rw.
select pg_temp.as_user((select id from _f where k='u_staff'));
insert into _o select 'staff_hold', pg_temp.try_hold(
  (select id from _biz where k='A'), null, true, 'staff attempt', 0);

insert into _r
select '13 a tenant staff member cannot place or lift a platform hold',
  case when (select doc->>'sqlstate' from _o where step='staff_hold')='42501'
        and (select count(*) from public.platform_retention_holds_v574)
            = (select n from _n where k='holds')
       then 'PASS the domain-scoped automation guard refuses, and no row was written'
       else 'FAIL '||coalesce((select doc::text from _o where step='staff_hold'),'<none>') end;

select pg_temp.as_user((select id from _f where k='u_padmin'));

-- 21 a hold nobody can explain later.
insert into _o select 'short_reason', pg_temp.try_hold(
  (select id from _biz where k='A'), null, true, 'x', 0);

insert into _r
select '21 a hold without a stated reason is refused 22023',
  case when (select doc->>'sqlstate' from _o where step='short_reason')='22023'
        and (select count(*) from public.platform_retention_holds_v574)
            = (select n from _n where k='holds')
       then 'PASS a one-character reason is not a reason'
       else 'FAIL '||coalesce((select doc::text from _o where step='short_reason'),'<none>') end;

-- 20a campaign scope.
insert into _o select 'hold_camp1', pg_temp.try_hold(
  (select id from _biz where k='A'), (select id from _f where k='camp1'), true,
  'v574 suite campaign-scoped hold', 0);

insert into _r
select '20a a campaign-scoped hold holds exactly that campaign',
  case when (select doc->>'scope' from _o where step='hold_camp1')='campaign'
        and (app.retention_platform_hold_v574((select id from _biz where k='A'),
               (select id from _f where k='camp1'))->>'held')::boolean
        and not (app.retention_platform_hold_v574((select id from _biz where k='A'),
               (select id from _f where k='camp2'))->>'held')::boolean
        and not (app.retention_platform_hold_v574((select id from _biz where k='A'),
               null)->>'held')::boolean
       then 'PASS campaign one is held; campaign two and the business lane are not'
       else 'FAIL camp1='||app.retention_platform_hold_v574((select id from _biz where k='A'),
              (select id from _f where k='camp1'))::text
            ||' camp2='||app.retention_platform_hold_v574((select id from _biz where k='A'),
              (select id from _f where k='camp2'))::text end;

-- 20b business scope outranks.
insert into _o select 'hold_biz', pg_temp.try_hold(
  (select id from _biz where k='A'), null, true,
  'v574 suite business-wide emergency stop', 0);

insert into _r
select '20b a business-scoped hold outranks and covers every campaign',
  case when (select doc->>'scope' from _o where step='hold_biz')='business'
        and (app.retention_platform_hold_v574((select id from _biz where k='A'),
               (select id from _f where k='camp2'))->>'scope')='business'
        and (app.retention_platform_hold_v574((select id from _biz where k='A'),
               (select id from _f where k='camp1'))->>'scope')='business'
        and (app.retention_platform_hold_v574((select id from _biz where k='A'),
               null)->>'held')::boolean
       then 'PASS the whole lane is held, and the resolver says which decision did it'
       else 'FAIL biz='||coalesce((select doc::text from _o where step='hold_biz'),'<none>')
            ||' camp2='||app.retention_platform_hold_v574((select id from _biz where k='A'),
              (select id from _f where k='camp2'))::text end;

insert into _r
select '14 a hold does not touch the merchant''s own campaign switch',
  case when (select count(*) from _camp_before b
              join public.bringback_campaigns_v361 c on c.id=b.id
             where c.active is distinct from b.active)=0
        and (select count(*) from _camp_before)
            = (select count(*) from public.bringback_campaigns_v361)
        and (select active from public.bringback_campaigns_v361
              where id=(select id from _f where k='camp1'))
       then 'PASS bringback_campaigns_v361.active is byte-identical; the hold lives in its own table'
       else 'FAIL '||(select count(*) from _camp_before b
              join public.bringback_campaigns_v361 c on c.id=b.id
             where c.active is distinct from b.active)::text||' campaign switches moved' end;

insert into _r
select '15 the audit names the PLATFORM ADMINISTRATOR, never the tenant',
  case when (select count(*) from public.audit_log
              where action='retention.platform_held'
                and actor=(select id from _f where k='u_padmin')
                and entity='platform_retention_holds_v574'
                and business_id=(select id from _biz where k='A')
                and detail->>'actor_kind'='platform_administrator'
                and coalesce(btrim(detail->>'reason'),'')<>''
                and id not in (select id from _base_audit))=2
       then 'PASS both holds are on the record, with a reason and an explicit actor_kind'
       else 'FAIL '||coalesce((select string_agg(action||'/'||coalesce(detail->>'actor_kind','-')
              ||'/'||coalesce(detail->>'reason','-'), ' | ')
              from public.audit_log where id not in (select id from _base_audit)
                and entity='platform_retention_holds_v574'),'<no audit rows>') end;

-- 16 EXECUTED: the enqueue path refuses a held business by name. The hold is
-- checked immediately after the business gate, so a plain customer is enough to
-- reach it — which is the point: the stop does not depend on anything else.
update app.platform_feature_flags set enabled=true where feature_key='whatsapp_retention_sends';
insert into _f select 'cH', pg_temp.mk_client((select id from _biz where k='A'), 'H', true);
insert into _f select 'gH', pg_temp.mk_grant((select id from _biz where k='A'),
  (select id from _f where k='camp1'), (select id from _f where k='cH'));

insert into _r
select '16 a held business cannot enqueue, and the reason says so',
  case when pg_temp.send_of((select id from _f where k='gH'))='suppressed/platform_hold'
       then 'PASS granting a voucher under a hold records the refusal by name instead of queueing'
       else 'FAIL '||pg_temp.send_of((select id from _f where k='gH')) end;

-- 19 optimistic concurrency: the business row is now at version 1.
insert into _o select 'stale', pg_temp.try_hold(
  (select id from _biz where k='A'), null, false, 'release with a stale read', 0);

insert into _r
select '19 a stale expected version is refused 40001',
  case when (select doc->>'sqlstate' from _o where step='stale')='40001'
        and (app.retention_platform_hold_v574((select id from _biz where k='A'), null)
             ->>'held')::boolean
       then 'PASS two consoles cannot silently overwrite each other; the hold survived the stale write'
       else 'FAIL '||coalesce((select doc::text from _o where step='stale'),'<none>') end;

-- 18 RELEASE with the correct version.
insert into _o select 'release_biz', pg_temp.try_hold(
  (select id from _biz where k='A'), null, false, 'v574 suite release',
  (select version from public.platform_retention_holds_v574
    where business_id=(select id from _biz where k='A') and campaign_id is null));
insert into _o select 'release_camp1', pg_temp.try_hold(
  (select id from _biz where k='A'), (select id from _f where k='camp1'), false,
  'v574 suite release campaign',
  (select version from public.platform_retention_holds_v574
    where business_id=(select id from _biz where k='A')
      and campaign_id=(select id from _f where k='camp1')));

insert into _r
select '18 releasing restores the merchant''s setting because it was never taken',
  case when (select doc->>'held' from _o where step='release_biz')='false'
        and not (app.retention_platform_hold_v574((select id from _biz where k='A'), null)
                 ->>'held')::boolean
        and not (app.retention_platform_hold_v574((select id from _biz where k='A'),
                 (select id from _f where k='camp1'))->>'held')::boolean
        and (select count(*) from _camp_before b
              join public.bringback_campaigns_v361 c on c.id=b.id
             where c.active is distinct from b.active)=0
        and (select released_by from public.platform_retention_holds_v574
              where business_id=(select id from _biz where k='A') and campaign_id is null)
            =(select id from _f where k='u_padmin')
       then 'PASS the lane is free again, the history row survives, and active is still what the merchant chose'
       else 'FAIL '||coalesce((select doc::text from _o where step='release_biz'),'<none>') end;

-- 17 EXECUTED: a hold placed AFTER a row is queued stops that row at claim time.
-- The row must genuinely QUEUE first, so this fixture satisfies every other gate
-- — capability included, granted inside this transaction and revoked before 26.
insert into public.business_capability_grants_v518(
  business_id, capability_key, enabled, limit_count, limit_period, limit_unlimited, note)
values ((select id from _biz where k='A'), 'whatsapp_retention', true, null, 'day', true,
        'v574 suite fixture — rolled back')
on conflict (business_id, capability_key) do update
  set enabled=excluded.enabled, limit_count=excluded.limit_count,
      limit_period=excluded.limit_period, limit_unlimited=excluded.limit_unlimited;

insert into _f select 'cQ', pg_temp.mk_client((select id from _biz where k='A'), 'Q', true);
insert into _f select 'evQ', pg_temp.stage_consent((select id from _biz where k='A'),
  (select id from _f where k='cQ'), 'granted', 'whatsapp','marketing', interval '1 hour');
insert into _f select 'gQ', pg_temp.mk_grant((select id from _biz where k='A'),
  (select id from _f where k='camp2'), (select id from _f where k='cQ'));

insert into _n select 'queued_ok',
  case when pg_temp.send_of((select id from _f where k='gQ'))='queued/-' then 1 else 0 end;

insert into _o select 'hold_after', pg_temp.try_hold(
  (select id from _biz where k='A'), null, true, 'v574 suite stop after queueing',
  (select version from public.platform_retention_holds_v574
    where business_id=(select id from _biz where k='A') and campaign_id is null));

create temp table _claim_held on commit drop as
  select * from public.internal_retention_claim_v551('v574-suite-hold', 20, 120);

insert into _r
select '17 a hold placed after queueing suppresses the queued row at claim time',
  case when (select n from _n where k='queued_ok')=1
        and (select count(*) from _claim_held
              where message_id=(select id from public.retention_sends_v551
                                 where grant_id=(select id from _f where k='gQ')))=0
        and pg_temp.send_of((select id from _f where k='gQ'))='suppressed/platform_hold'
       then 'PASS the row really was queued, and the emergency stop reached it in flight'
       else 'FAIL queued_first='||(select n from _n where k='queued_ok')::text
            ||' now='||pg_temp.send_of((select id from _f where k='gQ'))
            ||' claimed='||(select count(*) from _claim_held)::text end;

-- Put the lane back the way it was found before containment reads it.
insert into _o select 'release_final', pg_temp.try_hold(
  (select id from _biz where k='A'), null, false, 'v574 suite final release',
  (select version from public.platform_retention_holds_v574
    where business_id=(select id from _biz where k='A') and campaign_id is null));
update app.platform_feature_flags set enabled=false where feature_key='whatsapp_retention_sends';
delete from public.business_capability_grants_v518
 where business_id=(select id from _biz where k='A') and capability_key='whatsapp_retention';

-- =================================================== APPOINTMENT GATE (22..25)

-- 22 a workspace-CLOSED business. The appointment is inserted with staff_id
-- null so the v120 rota guard has nothing to say; the v557 AFTER INSERT trigger
-- fires the real enqueue and discards its answer, so the explicit call below is
-- what this check reads.
insert into _f select 'cClosed', pg_temp.mk_client((select id from _biz where k='closed'), 'closed', true);
insert into public.services(business_id, name, price_cents, duration_min)
values ((select id from _biz where k='closed'), 'v574 suite service', 1000, 30);
insert into _f select 'svcClosed', id from public.services
 where business_id=(select id from _biz where k='closed') and name='v574 suite service';
insert into public.appointments(business_id, client_id, service_id, starts_at, ends_at, status)
values ((select id from _biz where k='closed'), (select id from _f where k='cClosed'),
        (select id from _f where k='svcClosed'), now()+interval '2 days',
        now()+interval '2 days 30 minutes', 'booked');
insert into _f select 'apptClosed', id from public.appointments
 where business_id=(select id from _biz where k='closed')
   and client_id=(select id from _f where k='cClosed');

insert into _o select 'appt_closed', app.whatsapp_enqueue_appointment_notice_v557(
  (select id from _biz where k='closed'), (select id from _f where k='apptClosed'),
  'appointment_confirmation');

insert into _r
select '22 the appointment lane now refuses a workspace-closed business',
  case when (select count(*) from _biz where k='closed')=1
        and (select doc->>'status' from _o where step='appt_closed')='refused'
        and (select doc->>'reason' from _o where step='appt_closed')='business_not_active'
        and (select count(*) from public.whatsapp_template_sends_v557
              where appointment_id=(select id from _f where k='apptClosed'))=0
       then 'PASS the same signal, and the same reason string, the retention lane got in v572'
       else 'FAIL '||coalesce((select doc::text from _o where step='appt_closed'),
              '<no closed business found>') end;

-- 23 a DEMO firm with an open workspace, at TRANSACTIONAL intent.
insert into _f select 'cDemo', pg_temp.mk_client((select id from _biz where k='cubbly'), 'demo', true);
insert into public.services(business_id, name, price_cents, duration_min)
values ((select id from _biz where k='cubbly'), 'v574 suite demo service', 1000, 30);
insert into _f select 'svcDemo', id from public.services
 where business_id=(select id from _biz where k='cubbly') and name='v574 suite demo service';
insert into public.appointments(business_id, client_id, service_id, starts_at, ends_at, status)
values ((select id from _biz where k='cubbly'), (select id from _f where k='cDemo'),
        (select id from _f where k='svcDemo'), now()+interval '2 days',
        now()+interval '2 days 30 minutes', 'booked');
insert into _f select 'apptDemo', id from public.appointments
 where business_id=(select id from _biz where k='cubbly')
   and client_id=(select id from _f where k='cDemo');

insert into _o select 'appt_demo', app.whatsapp_enqueue_appointment_notice_v557(
  (select id from _biz where k='cubbly'), (select id from _f where k='apptDemo'),
  'appointment_confirmation');
insert into _o select 'demo_txn', app.business_may_initiate_comms_v572(
  (select id from _biz where k='cubbly'), 'whatsapp', 'transactional');
insert into _o select 'demo_mkt', app.business_may_initiate_comms_v572(
  (select id from _biz where k='cubbly'), 'whatsapp', 'marketing');

insert into _r
select '23 a demo firm passes the business gate at transactional intent',
  case when (select doc->>'allowed' from _o where step='demo_txn')='true'
        and (select doc->>'is_demo' from _o where step='demo_txn')='true'
        and (select doc->>'reason' from _o where step='demo_mkt')='demo_business_marketing'
        and (select doc->>'reason' from _o where step='appt_demo')
            is distinct from 'demo_business_marketing'
        and (select doc->>'reason' from _o where step='appt_demo')
            is distinct from 'business_not_active'
       then 'PASS the demo refusal stays scoped to marketing; the appointment refusal, if any, is a later gate ('
            ||coalesce((select doc->>'reason' from _o where step='appt_demo'),'none')||')'
       else 'FAIL txn='||coalesce((select doc::text from _o where step='demo_txn'),'<none>')
            ||' appt='||coalesce((select doc::text from _o where step='appt_demo'),'<none>') end;

-- 24 the appointment CLAIM filters a business that became ineligible after the
-- row was queued. BIZ_A is eligible and gets the capability for exactly this.
insert into public.business_capability_grants_v518(
  business_id, capability_key, enabled, limit_count, limit_period, limit_unlimited, note)
values ((select id from _biz where k='A'), 'whatsapp_appointment_notification', true,
        null, 'day', true, 'v574 suite fixture — rolled back')
on conflict (business_id, capability_key) do update
  set enabled=excluded.enabled, limit_count=excluded.limit_count,
      limit_period=excluded.limit_period, limit_unlimited=excluded.limit_unlimited;

insert into _f select 'cAppt', pg_temp.mk_client((select id from _biz where k='A'), 'appt', true);
insert into public.services(business_id, name, price_cents, duration_min)
values ((select id from _biz where k='A'), 'v574 suite A service', 1000, 30);
insert into _f select 'svcA', id from public.services
 where business_id=(select id from _biz where k='A') and name='v574 suite A service';
insert into public.appointments(business_id, client_id, service_id, starts_at, ends_at, status)
values ((select id from _biz where k='A'), (select id from _f where k='cAppt'),
        (select id from _f where k='svcA'), now()+interval '2 days',
        now()+interval '2 days 30 minutes', 'booked');
insert into _f select 'apptA', id from public.appointments
 where business_id=(select id from _biz where k='A')
   and client_id=(select id from _f where k='cAppt');
insert into _f select 'sendA', id from public.whatsapp_template_sends_v557
 where appointment_id=(select id from _f where k='apptA');

insert into _n select 'appt_queued',
  case when (select status from public.whatsapp_template_sends_v557
              where id=(select id from _f where k='sendA'))='queued' then 1 else 0 end;

-- The firm's workspace closes AFTER the confirmation was queued. The control
-- row is snapshotted first and restored verbatim afterwards, so the only thing
-- this proves is the claim's own gate.
create temp table _ctrl_before on commit drop as
  select * from public.business_workspace_controls_v94
   where business_id=(select id from _biz where k='A');

update public.business_workspace_controls_v94
   set approval_status='rejected', decided_at=now(),
       decision_reason='v574 suite — rolled back'
 where business_id=(select id from _biz where k='A');

create temp table _claim_paused on commit drop as
  select * from public.internal_whatsapp_claim_template_sends_v557('v574-suite-paused', 20, 120);

update public.business_workspace_controls_v94 c
   set approval_status=b.approval_status, decided_by=b.decided_by,
       decided_at=b.decided_at, decision_reason=b.decision_reason, version=b.version
  from _ctrl_before b
 where c.business_id=b.business_id;

create temp table _claim_open on commit drop as
  select * from public.internal_whatsapp_claim_template_sends_v557('v574-suite-open', 20, 120);

insert into _r
select '24 the appointment claim drops a business that became ineligible after queueing',
  case when (select n from _n where k='appt_queued')=1
        and (select count(*) from _claim_paused
              where message_id=(select id from _f where k='sendA'))=0
        and (select count(*) from _claim_open
              where message_id=(select id from _f where k='sendA'))=1
        and app.business_workspace_open_v94((select id from _biz where k='A'))
       then 'PASS the queued row is invisible while the workspace is closed and claimable once it reopens, so the check is not vacuous'
       else 'FAIL queued='||(select n from _n where k='appt_queued')::text
            ||' paused='||(select count(*) from _claim_paused)::text
            ||' open='||(select count(*) from _claim_open)::text end;

delete from public.business_capability_grants_v518
 where business_id=(select id from _biz where k='A')
   and capability_key='whatsapp_appointment_notification';

insert into _o select 'cubbly_support', app.capability_state_v518(
  (select id from _biz where k='cubbly'), 'whatsapp_support_reply');

insert into _r
select '25 C6 human support is untouched by any of this',
  case when pg_get_functiondef('app.support_reply_v535'::regproc) ilike '%business_workspace_open_v94%'
        and (select doc->>'allowed' from _o where step='cubbly_support')='true'
        and (select doc->>'reason' from _o where step='cubbly_support')='ok'
       then 'PASS support still carries its own workspace gate and still resolves allowed for the pilot'
       else 'FAIL '||coalesce((select doc::text from _o where step='cubbly_support'),'<none>') end;

-- ======================================================== CONTAINMENT (26..29)

insert into _r
select '26 retention is still globally off, ungranted, and has never sent anything',
  case when (select count(*) from app.platform_feature_flags
              where feature_key='whatsapp_retention_sends' and enabled)=0
        and (select n from _n where k='retention_flag_on')=0
        and (select count(*) from public.businesses b
              where coalesce((app.capability_state_v518(b.id,'whatsapp_retention')
                              ->>'allowed')::boolean,false))=0
        and (select n from _n where k='cap_allowed')=0
        and (select count(*) from public.retention_sends_v551
              where sent_at is not null or delivered_at is not null or read_at is not null
                 or provider_message_id is not null
                 or status in ('sent','delivered','read','accepted'))=0
       then 'PASS switch off before and after, zero tenants allowed, zero retention messages ever sent'
       else 'FAIL flag_on='||(select count(*) from app.platform_feature_flags
              where feature_key='whatsapp_retention_sends' and enabled)::text
            ||' allowed_tenants='||(select count(*) from public.businesses b
              where coalesce((app.capability_state_v518(b.id,'whatsapp_retention')
                              ->>'allowed')::boolean,false))::text
            ||' sent='||(select count(*) from public.retention_sends_v551
              where sent_at is not null or provider_message_id is not null
                 or status in ('sent','delivered','read','accepted'))::text end;

insert into _r
select '27 no HTTP request was fired by any of the above',
  case when (select count(*) from net.http_request_queue)=(select n from _n where k='http_queue')
       then 'PASS every writer, gate, trigger and claim above executed with no POST anywhere'
       else 'FAIL net.http_request_queue grew from '||(select n from _n where k='http_queue')::text
            ||' to '||(select count(*) from net.http_request_queue)::text end;

insert into _r
select '28 the v282 customer push dispatcher is still dead',
  case when pg_get_functiondef('app.v282_run_customer_push_dispatch()'::regprocedure) ilike '%v282_supabase_url%'
        and not exists (select 1 from vault.secrets where name in ('v282_supabase_url','v156_supabase_url'))
       then 'PASS v282 still names a vault key that does not exist; v574 created none'
       else 'FAIL v282 push may have been reactivated as a side effect' end;

insert into _r
select '29 only this suite''s own rows exist, and nothing pre-existing moved',
  case when (select count(*) from _base_consents b
              where not exists (select 1 from public.consents c where c.id=b.id))=0
        and (select count(*) from _base_consents b
              join public.consents c on c.id=b.id
             where (c.business_id,c.client_id,c.channel,c.purpose,c.action,
                    c.source,c.actor,c.created_at)
                is distinct from
                   (b.business_id,b.client_id,b.channel,b.purpose,b.action,
                    b.source,b.actor,b.created_at))=0
        and (select count(*) from public.consents c
              where c.id not in (select id from _base_consents)
                and c.client_id not in (select id from _f))=0
        and (select count(*) from _base_sends b
              join public.retention_sends_v551 s on s.id=b.id
             where s.status is distinct from b.status
                or s.suppressed_reason is distinct from b.suppressed_reason)=0
        and (select count(*) from public.retention_sends_v551 s
              where s.id not in (select id from _base_sends)
                and s.business_id <> (select id from _biz where k='A'))=0
        and (select count(*) from public.platform_retention_holds_v574
              where business_id <> (select id from _biz where k='A'))
            = (select n from _n where k='holds')
        and (select count(*) from public.whatsapp_template_sends_v557
              where id not in (select id from _base_tmpl)
                and business_id <> (select id from _biz where k='A'))=0
       then 'PASS every pre-existing consent, send and hold is byte-identical; every new row belongs to this suite'
       else 'FAIL consents_lost='||(select count(*) from _base_consents b
              where not exists (select 1 from public.consents c where c.id=b.id))::text
            ||' consents_changed='||(select count(*) from _base_consents b
              join public.consents c on c.id=b.id
             where (c.action,c.source,c.created_at) is distinct from (b.action,b.source,b.created_at))::text
            ||' foreign_new_consents='||(select count(*) from public.consents c
              where c.id not in (select id from _base_consents)
                and c.client_id not in (select id from _f))::text
            ||' sends_moved='||(select count(*) from _base_sends b
              join public.retention_sends_v551 s on s.id=b.id
             where s.status is distinct from b.status)::text end;

select k as check_name, v as result from _r order by k;

rollback;
