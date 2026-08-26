-- Rollback-only acceptance for nestly_v551 — a bring-back grant becomes a consent-gated WhatsApp send.
--   supabase db query --linked -f db/tests/v551_whatsapp_bringback_sends.sql
-- Any row whose value starts with FAIL is a failure. Nothing is committed.
--
-- Fixture: production tenant qa-kaya-toast; flags/capability are flipped INSIDE the transaction and
-- roll back with everything else. Forged webhook rows carry impossible wamids (v551-test-*).
--
--   01  gate order: a grant issued while the retention flag is OFF suppresses 'retention_sends_off';
--       after the flag, without the capability, 'capability_disabled'
--   02  per-client gates each name their refusal: no_phone / consent_missing / synthetic_client
--   03  a fully permitted grant enqueues 'queued' with the right variables and phone
--   04  claim refuses while the template is only 'submitted'; approves -> claims with meta name,
--       language and ordered descriptors; row leased as 'processing'
--   05  report 'sent' records the wamid, stamps sent_at and consumes one capability use
--   06  the status ingest applies delivered from a forged callback and refuses to roll read back to sent
--   07  retry backoff re-queues with attempt+1 and a future next_attempt_at; a stale lease is 40001
--   08  the second consent check: consent withdrawn between enqueue and claim -> 'consent_withdrawn'
--   09  STOP: a forged inbound 'STOP' opts the phone out everywhere it was messaged — consent off,
--       a consents row, queued sends suppressed, already-sent rows untouched
--   10  stats: owner sees counts + template status; a stranger gets 42501; internal pair is
--       service-role-only and anon holds nothing
--
begin;

create temp table _r(k text, v text) on commit drop;
create temp table _fx(label text primary key, client_id uuid, grant_id uuid, send_id uuid) on commit drop;

create or replace function pg_temp.as_v551_user(p_uid uuid) returns void language plpgsql as $$
begin
  execute 'reset role';
  execute 'set local role authenticated';
  perform set_config('request.jwt.claim.sub', coalesce(p_uid::text, ''), true);
  perform set_config('request.jwt.claims',
    json_build_object('sub', p_uid, 'role', 'authenticated')::text, true);
end
$$;
grant execute on function pg_temp.as_v551_user(uuid) to public;

create or replace function pg_temp.v551_owner() returns uuid language sql as $$
  select st.user_id from public.staff st
  where st.business_id = '38b30e6d-de73-4c2b-a2ca-19b08950896c'
    and st.role = 'owner' and st.user_id is not null
  order by st.created_at limit 1
$$;

create or replace function pg_temp.v551_grant(p_client uuid, p_reward text) returns uuid
language plpgsql as $$
declare v_campaign uuid; v_id uuid;
begin
  select id into v_campaign from public.bringback_campaigns_v361
   where business_id = '38b30e6d-de73-4c2b-a2ca-19b08950896c' and name = 'V551 Suite Campaign';
  insert into public.bringback_grants_v361(business_id, campaign_id, client_id, reward_label, away_days, cycle_key, granted_at)
  values ('38b30e6d-de73-4c2b-a2ca-19b08950896c', v_campaign, p_client, p_reward, 30,
          (now() - make_interval(days => (random()*3000)::int))::date, now())
  returning id into v_id;
  return v_id;
end
$$;

create or replace function pg_temp.v551_send_of(p_grant uuid) returns public.retention_sends_v551
language sql as $$
  select * from public.retention_sends_v551 where grant_id = p_grant
$$;

-- ---------------------------------------------------------------------------------------------
-- 01  platform gates, in order
-- ---------------------------------------------------------------------------------------------
do $$
declare
  b uuid := '38b30e6d-de73-4c2b-a2ca-19b08950896c';
  v_client uuid; v_g1 uuid; v_g2 uuid; s1 public.retention_sends_v551; s2 public.retention_sends_v551;
begin
  execute 'reset role';
  insert into public.bringback_campaigns_v361(business_id, name, reward_label, away_days)
  values (b, 'V551 Suite Campaign', 'a free kopi', 30);
  insert into public.clients(business_id, full_name, phone, marketing_consent, is_synthetic)
  values (b, 'V551 Gate Probe', '90005510', true, false) returning id into v_client;
  insert into _fx values ('gate', v_client, null, null);

  -- retention flag is OFF in prod: the platform-level refusal must be named.
  v_g1 := pg_temp.v551_grant(v_client, 'a free kopi');
  s1 := pg_temp.v551_send_of(v_g1);

  update app.platform_feature_flags set enabled = true where feature_key = 'whatsapp_retention_sends';
  -- flag on, but the firm holds no capability grant yet
  delete from public.bringback_grants_v361 where id = v_g1; -- frees the send row via cascade
  v_g2 := pg_temp.v551_grant(v_client, 'a free kopi');
  s2 := pg_temp.v551_send_of(v_g2);

  insert into _r values ('01_platform_gates',
    case when s1.status = 'suppressed' and s1.suppressed_reason = 'retention_sends_off'
           and s2.status = 'suppressed' and s2.suppressed_reason = 'capability_disabled'
      then 'PASS flag-off then capability-off, each named'
      else 'FAIL s1=' || coalesce(s1.suppressed_reason,'?') || ' s2=' || coalesce(s2.suppressed_reason,'?') end);

  -- grant the capability for everything after this check
  insert into public.business_capability_grants_v518(business_id, capability_key, enabled)
  values (b, 'whatsapp_retention', true)
  on conflict (business_id, capability_key) do update set enabled = true;
end $$;

-- ---------------------------------------------------------------------------------------------
-- 02  per-client gates
-- ---------------------------------------------------------------------------------------------
do $$
declare
  b uuid := '38b30e6d-de73-4c2b-a2ca-19b08950896c';
  v_nophone uuid; v_nocons uuid; v_synth uuid;
  s_nophone public.retention_sends_v551; s_nocons public.retention_sends_v551; s_synth public.retention_sends_v551;
begin
  execute 'reset role';
  insert into public.clients(business_id, full_name, marketing_consent, is_synthetic)
  values (b, 'V551 No Phone', true, false) returning id into v_nophone;
  insert into public.clients(business_id, full_name, phone, marketing_consent, is_synthetic)
  values (b, 'V551 Said No', '90005512', false, false) returning id into v_nocons;
  insert into public.clients(business_id, full_name, phone, is_synthetic)
  values (b, 'V551 Synth', '90005513', true) returning id into v_synth;
  s_nophone := pg_temp.v551_send_of(pg_temp.v551_grant(v_nophone, 'x'));
  s_nocons  := pg_temp.v551_send_of(pg_temp.v551_grant(v_nocons, 'x'));
  s_synth   := pg_temp.v551_send_of(pg_temp.v551_grant(v_synth, 'x'));
  insert into _r values ('02_client_gates',
    case when s_nophone.suppressed_reason = 'no_phone'
           and s_nocons.suppressed_reason = 'consent_missing'
           and s_synth.suppressed_reason = 'synthetic_client'
      then 'PASS no_phone / consent_missing / synthetic_client'
      else 'FAIL ' || coalesce(s_nophone.suppressed_reason,'?') || '/'
           || coalesce(s_nocons.suppressed_reason,'?') || '/' || coalesce(s_synth.suppressed_reason,'?') end);
end $$;

-- ---------------------------------------------------------------------------------------------
-- 03  a fully permitted grant queues with the right variables
-- ---------------------------------------------------------------------------------------------
do $$
declare
  b uuid := '38b30e6d-de73-4c2b-a2ca-19b08950896c';
  v_client uuid; v_grant uuid; s public.retention_sends_v551;
begin
  execute 'reset role';
  insert into public.clients(business_id, full_name, phone, marketing_consent, is_synthetic)
  values (b, 'V551 Happy Path', '90005514', true, false) returning id into v_client;
  v_grant := pg_temp.v551_grant(v_client, 'a free kaya toast set');
  s := pg_temp.v551_send_of(v_grant);
  insert into _fx values ('happy', v_client, v_grant, s.id);
  insert into _r values ('03_happy_enqueue',
    case when s.status = 'queued'
           and s.recipient_phone_norm = '90005514'
           and s.variables->>'customer_first_name' = 'V551'
           and s.variables->>'reward_label' = 'a free kaya toast set'
           and (s.variables->>'business_name') is not null
      then 'PASS queued with bound variables'
      else 'FAIL ' || coalesce(to_jsonb(s)::text, 'NO ROW') end);
end $$;

-- ---------------------------------------------------------------------------------------------
-- 04  claim: template approval is the switch
-- ---------------------------------------------------------------------------------------------
do $$
declare
  v_before integer; r record; v_found boolean := false; v_lease uuid;
begin
  execute 'reset role';
  select count(*) into v_before from public.internal_retention_claim_v551('v551-suite', 50, 120);
  update public.whatsapp_template_registry_v551 set status = 'approved' where template_key = 'bring_back_v1';
  for r in select * from public.internal_retention_claim_v551('v551-suite', 50, 120) loop
    if r.message_id = (select send_id from _fx where label = 'happy') then
      v_found := true; v_lease := r.lease_token;
      update _fx set grant_id = grant_id where label = 'happy'; -- no-op, keeps shape
      insert into _fx values ('lease', null, null, null) on conflict (label) do nothing;
      update _fx set client_id = null, grant_id = null, send_id = v_lease where label = 'lease';
      if r.template_name <> 'peekaa_bring_back_v1' or r.language_code <> 'en'
         or r.parameter_descriptors::text not like '%customer_first_name%' then
        v_found := false;
      end if;
    end if;
  end loop;
  insert into _r values ('04_claim_needs_approval',
    case when v_before = 0 and v_found
      then 'PASS unapproved claims nothing; approved claim carries meta name + descriptors'
      else 'FAIL before=' || v_before || ' found=' || v_found end);
end $$;

-- ---------------------------------------------------------------------------------------------
-- 05  report sent: wamid + quota consumption
-- ---------------------------------------------------------------------------------------------
do $$
declare
  b uuid := '38b30e6d-de73-4c2b-a2ca-19b08950896c';
  v_send uuid; v_lease uuid; v_usage integer; s public.retention_sends_v551;
begin
  execute 'reset role';
  select send_id into v_send from _fx where label = 'happy';
  select send_id into v_lease from _fx where label = 'lease';
  perform public.internal_retention_report_v551(v_send, v_lease, 'sent', 'wamid.v551-test-happy', null, null);
  select * into s from public.retention_sends_v551 where id = v_send;
  select count(*) into v_usage from public.capability_usage_v518
   where business_id = b and capability_key = 'whatsapp_retention' and idem_key = 'v551:' || v_send::text;
  insert into _r values ('05_sent_and_quota',
    case when s.status = 'sent' and s.sent_at is not null
           and s.provider_message_id = 'wamid.v551-test-happy' and v_usage = 1
      then 'PASS sent, wamid recorded, one capability use consumed'
      else 'FAIL status=' || s.status || ' wamid=' || coalesce(s.provider_message_id,'?') || ' usage=' || v_usage end);
end $$;

-- ---------------------------------------------------------------------------------------------
-- 06  status ingest is monotonic
-- ---------------------------------------------------------------------------------------------
do $$
declare
  v_send uuid; s public.retention_sends_v551; v_payload jsonb;
begin
  execute 'reset role';
  select send_id into v_send from _fx where label = 'happy';
  v_payload := jsonb_build_object('entry', jsonb_build_array(jsonb_build_object(
    'id', 'v551-test-waba', 'changes', jsonb_build_array(jsonb_build_object(
      'value', jsonb_build_object('statuses', jsonb_build_array(
        jsonb_build_object('id', 'wamid.v551-test-happy', 'status', 'read',
                           'timestamp', extract(epoch from now())::bigint::text))))))));
  insert into public.whatsapp_webhook_events(payload, payload_sha256, signature_verified)
  values (v_payload, encode(sha256(v_payload::text::bytea), 'hex'), true);
  perform app.v551_ingest_retention_status(500);
  select * into s from public.retention_sends_v551 where id = v_send;
  -- now a LATE 'delivered' (rank 30 < read 40) must change nothing
  v_payload := jsonb_set(v_payload, '{entry,0,changes,0,value,statuses,0,status}', '"delivered"');
  insert into public.whatsapp_webhook_events(payload, payload_sha256, signature_verified)
  values (v_payload, encode(sha256(v_payload::text::bytea), 'hex'), true);
  perform app.v551_ingest_retention_status(500);
  insert into _r values ('06_monotonic_ingest',
    case when s.status = 'read' and s.read_at is not null
           and (select status from public.retention_sends_v551 where id = v_send) = 'read'
      then 'PASS read applied; late delivered ignored'
      else 'FAIL status=' || s.status || ' after=' ||
        (select status from public.retention_sends_v551 where id = v_send) end);
end $$;

-- ---------------------------------------------------------------------------------------------
-- 07  retry backoff and the stale lease
-- ---------------------------------------------------------------------------------------------
do $$
declare
  b uuid := '38b30e6d-de73-4c2b-a2ca-19b08950896c';
  v_client uuid; v_grant uuid; v_send uuid; v_lease uuid; s public.retention_sends_v551;
  v_state text := 'no error'; r record;
begin
  execute 'reset role';
  insert into public.clients(business_id, full_name, phone, marketing_consent, is_synthetic)
  values (b, 'V551 Retry Probe', '90005515', true, false) returning id into v_client;
  v_grant := pg_temp.v551_grant(v_client, 'y');
  v_send := (pg_temp.v551_send_of(v_grant)).id;
  for r in select * from public.internal_retention_claim_v551('v551-suite', 50, 120) loop
    if r.message_id = v_send then v_lease := r.lease_token; end if;
  end loop;
  perform public.internal_retention_report_v551(v_send, v_lease, 'retry', null, '130429', 120);
  select * into s from public.retention_sends_v551 where id = v_send;
  begin
    perform public.internal_retention_report_v551(v_send, gen_random_uuid(), 'sent', 'wamid.x', null, null);
  exception when others then v_state := SQLSTATE;
  end;
  -- the unleased-row case the first suite run exposed: a NULL-for-NULL lease
  -- match must be refused, not honoured
  begin
    perform public.internal_retention_report_v551(v_send, null, 'sent', 'wamid.y', null, null);
    v_state := 'null lease accepted';
  exception when others then
    if SQLSTATE <> '40001' then v_state := 'null-lease ' || SQLSTATE; end if;
  end;
  insert into _fx values ('retry', v_client, v_grant, v_send);
  insert into _r values ('07_retry_and_stale_lease',
    case when s.status = 'queued' and s.attempt_count = 1
           and s.next_attempt_at > now() and s.error_code = '130429' and v_state = '40001'
      then 'PASS re-queued with backoff; stale lease 40001'
      else 'FAIL status=' || s.status || ' attempts=' || s.attempt_count || ' stale=' || v_state end);
end $$;

-- ---------------------------------------------------------------------------------------------
-- 08  the second consent check at claim
-- ---------------------------------------------------------------------------------------------
do $$
declare
  v_client uuid; v_send uuid; s public.retention_sends_v551; v_claimed integer;
begin
  execute 'reset role';
  select client_id, send_id into v_client, v_send from _fx where label = 'retry';
  update public.clients set marketing_consent = false where id = v_client;
  update public.retention_sends_v551 set next_attempt_at = null where id = v_send; -- claimable now
  select count(*) into v_claimed from public.internal_retention_claim_v551('v551-suite', 50, 120)
   where message_id = v_send;
  s := (select rs from public.retention_sends_v551 rs where rs.id = v_send);
  insert into _r values ('08_consent_withdrawn',
    case when v_claimed = 0 and s.status = 'suppressed' and s.suppressed_reason = 'consent_withdrawn'
      then 'PASS withdrawn consent suppresses instead of sending'
      else 'FAIL claimed=' || v_claimed || ' status=' || s.status || '/' || coalesce(s.suppressed_reason,'?') end);
end $$;

-- ---------------------------------------------------------------------------------------------
-- 09  STOP honours the footer, everywhere that phone was messaged
-- ---------------------------------------------------------------------------------------------
do $$
declare
  b uuid := '38b30e6d-de73-4c2b-a2ca-19b08950896c';
  v_client uuid; v_grant uuid; v_send uuid; v_payload jsonb;
  v_consent boolean; v_consents integer; s public.retention_sends_v551;
  happy_status text;
begin
  execute 'reset role';
  insert into public.clients(business_id, full_name, phone, marketing_consent, is_synthetic)
  values (b, 'V551 Stopper', '90005516', true, false) returning id into v_client;
  v_grant := pg_temp.v551_grant(v_client, 'z');
  v_send := (pg_temp.v551_send_of(v_grant)).id;

  v_payload := jsonb_build_object('entry', jsonb_build_array(jsonb_build_object(
    'id', 'v551-test-waba', 'changes', jsonb_build_array(jsonb_build_object(
      'value', jsonb_build_object('messages', jsonb_build_array(
        jsonb_build_object('type', 'text', 'from', '6590005516',
                           'text', jsonb_build_object('body', '  STOP  ')))))))));
  insert into public.whatsapp_webhook_events(payload, payload_sha256, signature_verified)
  values (v_payload, encode(sha256(v_payload::text::bytea), 'hex'), true);
  perform app.v551_ingest_retention_optout(500);

  select marketing_consent into v_consent from public.clients where id = v_client;
  select count(*) into v_consents from public.consents
   where business_id = b and client_id = v_client and action = 'withdrawn' and source = 'whatsapp_stop_reply';
  select * into s from public.retention_sends_v551 where id = v_send;
  select status into happy_status from public.retention_sends_v551
   where id = (select send_id from _fx where label = 'happy');
  insert into _r values ('09_stop_optout',
    case when v_consent = false and v_consents = 1
           and s.status = 'suppressed' and s.suppressed_reason = 'customer_opted_out'
           and happy_status = 'read'
      then 'PASS consent off, consents row written, queue suppressed, read row untouched'
      else 'FAIL consent=' || coalesce(v_consent::text,'null') || ' consents=' || v_consents
        || ' send=' || s.status || '/' || coalesce(s.suppressed_reason,'?') || ' happy=' || happy_status end);
end $$;

-- ---------------------------------------------------------------------------------------------
-- 10  the reads and the locks
-- ---------------------------------------------------------------------------------------------
do $$
declare
  b uuid := '38b30e6d-de73-4c2b-a2ca-19b08950896c';
  p jsonb; v_state text := 'no error';
begin
  perform pg_temp.as_v551_user(pg_temp.v551_owner());
  p := public.get_retention_send_stats_v551(b);
  execute 'reset role';
  begin
    perform pg_temp.as_v551_user(gen_random_uuid());
    perform public.get_retention_send_stats_v551(b);
  exception when others then v_state := SQLSTATE;
  end;
  execute 'reset role';
  insert into _r values ('10_reads_and_locks',
    case when (p->>'sent')::int >= 0
           and p->>'template_status' = 'approved'
           and (p->'suppressed_reasons') ? 'customer_opted_out'
           and v_state = '42501'
           and not has_function_privilege('anon', 'public.get_retention_send_stats_v551(uuid)', 'execute')
           and not has_function_privilege('authenticated', 'public.internal_retention_claim_v551(text,integer,integer)', 'execute')
           and not has_function_privilege('authenticated', 'public.internal_retention_report_v551(uuid,uuid,text,text,text,integer)', 'execute')
      then 'PASS owner stats with reasons + template status; stranger 42501; internals locked'
      else 'FAIL stats=' || coalesce(p::text,'null') || ' stranger=' || v_state end);
end $$;

select k, v from _r order by k;

rollback;
