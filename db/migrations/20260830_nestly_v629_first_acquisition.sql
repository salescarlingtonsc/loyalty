-- NESTLY v629 — Phase A, M2 (A1): durable FIRST-ACQUISITION provenance on the customer record.
-- Owner ruling D1 (2026-08-30): first acquisition is a different concept from later marketing
-- touches (those live in v635's association ledger, never here). Three write-once columns on
-- public.clients, auto-set by every creation path, 'unknown' explicitly supported, provable-only
-- backfill — never guessed.
--
-- Mechanism: each of the eight verified client-creation writers publishes a transaction-local
-- context (set_config) immediately before its INSERT; a BEFORE INSERT trigger reads it. A writer
-- this migration does not know about (future paths) produces 'unknown', visibly — never null,
-- never a guess. The writers are patched in place from their live production definitions with
-- single-occurrence anchors (v460/v544 house pattern), so this migration cannot silently apply
-- to a drifted body.
--
-- The eight creation paths (verified against production 2026-08-30):
--   staff_create_client            -> 'staff_created' | 'referral' (when p_referrer_code given)
--   quick_add_client               -> 'walk_in_till'
--   internal_public_join_v89       -> 'qr_join'
--   join_program (legacy twin)     -> 'qr_join'
--   customer_join_business_from_qr_v89_base_v90 -> 'qr_join'
--   staff_scan_member_qr_v327      -> 'qr_scan_provisioned'
--   app.upsert_portal_client       -> 'portal_booking'
--   commit_import_job              -> 'csv_import' (+ ref = import job id)
-- For 'referral', first_acquired_ref stays null by design: public.referrals.referred_client_id
-- is already the durable reference; duplicating it risks divergence.
begin;

-- ---------------------------------------------------------------------------
-- 1. Columns. Existing rows become 'unknown' and are upgraded only by the
--    provable backfill below.
-- ---------------------------------------------------------------------------
alter table public.clients
  add column first_acquired_via text not null default 'unknown'
    check (first_acquired_via in
      ('staff_created','qr_join','qr_scan_provisioned','portal_booking',
       'csv_import','wallet_signup','referral','campaign','walk_in_till','unknown')),
  add column first_acquired_ref uuid,
  add column first_acquired_evidence text not null default 'unknown'
    check (first_acquired_evidence in ('recorded_at_creation','backfilled_provable','unknown'));

-- ---------------------------------------------------------------------------
-- 2. BEFORE INSERT: read the writer-published context. Ref is honoured only
--    for via values that define a ref source (csv_import here; portal_booking
--    sets no GUC ref — its booking_request linkage is backfilled by the same
--    provable join used below, run forward by v637's funnel work if needed).
-- ---------------------------------------------------------------------------
create or replace function app.clients_first_acquisition_default_v629()
returns trigger language plpgsql
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_via text := coalesce(nullif(current_setting('app.first_acquired_via', true), ''), 'unknown');
begin
  if v_via not in ('staff_created','qr_join','qr_scan_provisioned','portal_booking',
                   'csv_import','wallet_signup','referral','campaign','walk_in_till') then
    v_via := 'unknown';
  end if;
  new.first_acquired_via := v_via;
  new.first_acquired_evidence := case when v_via = 'unknown' then 'unknown' else 'recorded_at_creation' end;
  new.first_acquired_ref := case
    when v_via = 'csv_import'
      then nullif(current_setting('app.first_acquired_ref', true), '')::uuid
    else null end;
  return new;
end;
$$;
create trigger trg_clients_first_acquisition_v629
  before insert on public.clients
  for each row execute function app.clients_first_acquisition_default_v629();

-- ---------------------------------------------------------------------------
-- 3. Write-once guard on UPDATE. Allowed transitions only:
--    - the one-time provable upgrade: evidence 'unknown' -> 'backfilled_provable'
--      (via may change in that same upgrade);
--    - ref NULL -> value while evidence is being upgraded, or value -> NULL
--      (erasure clears refs); never value -> different value.
--    Rows whose acquisition fields are untouched pass through (erase_client_v290
--    updates other columns on the same row).
-- ---------------------------------------------------------------------------
create or replace function app.clients_first_acquisition_guard_v629()
returns trigger language plpgsql
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
begin
  if new.first_acquired_via is not distinct from old.first_acquired_via
     and new.first_acquired_evidence is not distinct from old.first_acquired_evidence
     and new.first_acquired_ref is not distinct from old.first_acquired_ref then
    return new;
  end if;
  if old.first_acquired_evidence = 'unknown'
     and new.first_acquired_evidence = 'backfilled_provable'
     and (old.first_acquired_ref is null or new.first_acquired_ref is not distinct from old.first_acquired_ref
          or new.first_acquired_ref is null) then
    return new;
  end if;
  if new.first_acquired_via is not distinct from old.first_acquired_via
     and new.first_acquired_evidence is not distinct from old.first_acquired_evidence
     and new.first_acquired_ref is null then
    return new; -- clearing the ref alone (erasure) is always permitted
  end if;
  raise exception 'first-acquisition provenance is write-once (client %, % -> %)',
    old.id, old.first_acquired_evidence, new.first_acquired_evidence
    using errcode = '42501';
end;
$$;
create trigger trg_clients_first_acquisition_guard_v629
  before update on public.clients
  for each row execute function app.clients_first_acquisition_guard_v629();

-- ---------------------------------------------------------------------------
-- 4. Patch the eight writers in place. Each patch: read the live definition,
--    assert its anchor occurs exactly once, inject the context line(s), execute.
-- ---------------------------------------------------------------------------
do $patch$
declare
  r record;
  v_def text;
  v_anchor text;
  v_inject text;
  v_count integer;
  v_targets constant jsonb := jsonb_build_array(
    jsonb_build_object(
      'fn', 'public.commit_import_job(uuid)',
      'anchor', E'      insert into public.clients\n        (business_id, full_name, phone, email, gender, birth_date, notes)',
      'inject', E'      perform set_config(''app.first_acquired_via'',''csv_import'',true);\n      perform set_config(''app.first_acquired_ref'', v_job.id::text, true);\n'),
    jsonb_build_object(
      'fn', 'public.customer_join_business_from_qr_v89_base_v90(text,uuid)',
      'anchor', E'      insert into public.clients(\n        business_id,full_name,phone,birth_date,marketing_consent',
      'inject', E'      perform set_config(''app.first_acquired_via'',''qr_join'',true);\n'),
    jsonb_build_object(
      'fn', 'public.internal_public_join_v89(text,text,text,text,boolean)',
      'anchor', E'  insert into public.clients(\n    business_id,full_name,phone,email,marketing_consent',
      'inject', E'  perform set_config(''app.first_acquired_via'',''qr_join'',true);\n'),
    jsonb_build_object(
      'fn', 'public.join_program(text,text,text,text,boolean)',
      'anchor', E'  insert into public.clients (business_id, full_name, phone, email, marketing_consent)\n  values (v_biz,',
      'inject', E'  perform set_config(''app.first_acquired_via'',''qr_join'',true);\n'),
    jsonb_build_object(
      'fn', 'public.quick_add_client(uuid,text,text,boolean)',
      'anchor', E'  insert into public.clients (business_id, full_name, phone, marketing_consent)',
      'inject', E'  perform set_config(''app.first_acquired_via'',''walk_in_till'',true);\n'),
    jsonb_build_object(
      'fn', 'public.staff_create_client(uuid,uuid,text,text,text,date,text,boolean,text,text)',
      'anchor', E'  insert into public.clients (\n    business_id, full_name, phone, email, birth_date, gender, marketing_consent',
      'inject', E'  perform set_config(''app.first_acquired_via'',\n    case when nullif(btrim(p_referrer_code),'''') is not null then ''referral'' else ''staff_created'' end, true);\n'),
    jsonb_build_object(
      'fn', 'public.staff_scan_member_qr_v327(uuid,text)',
      'anchor', E'    insert into public.clients (business_id, full_name)',
      'inject', E'    perform set_config(''app.first_acquired_via'',''qr_scan_provisioned'',true);\n'),
    jsonb_build_object(
      'fn', 'app.upsert_portal_client(uuid,text,text,text)',
      'anchor', E'  insert into public.clients (business_id, full_name, phone, email, marketing_consent)\n  values (p_biz,',
      'inject', E'  perform set_config(''app.first_acquired_via'',''portal_booking'',true);\n')
  );
  v_item jsonb;
begin
  for v_item in select * from jsonb_array_elements(v_targets) loop
    v_anchor := v_item->>'anchor';
    v_inject := v_item->>'inject';
    select pg_get_functiondef(to_regprocedure(v_item->>'fn')) into v_def;
    if v_def is null then
      raise exception 'v629: function % not found', v_item->>'fn';
    end if;
    v_count := (length(v_def) - length(replace(v_def, v_anchor, ''))) / length(v_anchor);
    if v_count <> 1 then
      raise exception 'v629: anchor for % occurs % times (expected exactly 1) — live body drifted, refuse to patch',
        v_item->>'fn', v_count;
    end if;
    v_def := replace(v_def, v_anchor, v_inject || v_anchor);
    execute v_def;
  end loop;
end;
$patch$;

-- CREATE OR REPLACE preserves existing grants; restate the live ACLs verbatim
-- (read from pg_proc before this migration was written):
revoke all on function public.commit_import_job(uuid) from public, anon;
revoke all on function public.customer_join_business_from_qr_v89_base_v90(text,uuid) from public, anon;
revoke all on function public.internal_public_join_v89(text,text,text,text,boolean) from public, anon;
revoke all on function public.join_program(text,text,text,text,boolean) from public, anon;
revoke all on function public.quick_add_client(uuid,text,text,boolean) from public, anon;
revoke all on function public.staff_create_client(uuid,uuid,text,text,text,date,text,boolean,text,text) from public, anon;
revoke all on function public.staff_scan_member_qr_v327(uuid,text) from public, anon;
revoke all on function app.upsert_portal_client(uuid,text,text,text) from public, anon;
-- ACLs restated verbatim from live proacl (read 2026-08-30):
grant execute on function public.internal_public_join_v89(text,text,text,text,boolean) to service_role;
grant execute on function public.join_program(text,text,text,text,boolean) to service_role;
revoke all on function public.customer_join_business_from_qr_v89_base_v90(text,uuid) from authenticated, service_role; -- live: postgres only
revoke all on function app.upsert_portal_client(uuid,text,text,text) from authenticated, service_role;                 -- live: postgres only
grant execute on function public.commit_import_job(uuid) to authenticated, service_role;
grant execute on function public.quick_add_client(uuid,text,text,boolean) to service_role;
grant execute on function public.staff_create_client(uuid,uuid,text,text,text,date,text,boolean,text,text) to authenticated, service_role;
grant execute on function public.staff_scan_member_qr_v327(uuid,text) to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 5. Provable-only backfill, strongest evidence first; each row upgraded at
--    most once (the guard enforces it; the where-clauses respect it).
-- ---------------------------------------------------------------------------
-- 5a. Referral: the referrals row IS the proof.
update public.clients c
   set first_acquired_via = 'referral',
       first_acquired_evidence = 'backfilled_provable'
  from public.referrals r
 where r.referred_client_id = c.id
   and r.business_id = c.business_id
   and c.first_acquired_evidence = 'unknown';

-- 5b. QR self-signup: the v89 audit row names the client.
update public.clients c
   set first_acquired_via = 'qr_join',
       first_acquired_evidence = 'backfilled_provable'
  from public.audit_log a
 where a.action = 'CUSTOMER_QR_SIGNUP_V89'
   and a.business_id = c.business_id
   and a.entity_id = c.id
   and c.first_acquired_evidence = 'unknown';

-- 5c. Member-QR auto-provision: the v327 audit row names the client.
update public.clients c
   set first_acquired_via = 'qr_scan_provisioned',
       first_acquired_evidence = 'backfilled_provable'
  from public.audit_log a
 where a.action = 'AUTO_PROVISION_CLIENT_FROM_MEMBER_QR_V327'
   and a.business_id = c.business_id
   and a.entity_id = c.id
   and c.first_acquired_evidence = 'unknown';

-- 5d. Portal booking: the booking request references the client it created,
--     and the client row was born inside that request's window.
update public.clients c
   set first_acquired_via = 'portal_booking',
       first_acquired_ref = br.id,
       first_acquired_evidence = 'backfilled_provable'
  from public.booking_requests br
 where br.customer_client_id = c.id
   and br.business_id = c.business_id
   and c.created_at between br.created_at - interval '10 minutes'
                         and br.created_at + interval '10 minutes'
   and c.first_acquired_evidence = 'unknown';

-- Everything else remains 'unknown' / 'unknown' — explicitly, never guessed.
-- (CSV import staging rows are ephemeral in production; no import backfill is
-- attempted because no durable proof survives.)

-- ---------------------------------------------------------------------------
-- 6. Watermark.
-- ---------------------------------------------------------------------------
insert into public.analytics_observation_watermarks (metric_key, observed_since, reason)
values ('first_acquisition', now(),
        'first_acquired_* recorded at creation from v629 onward; earlier rows are backfilled-provable or unknown');

commit;
