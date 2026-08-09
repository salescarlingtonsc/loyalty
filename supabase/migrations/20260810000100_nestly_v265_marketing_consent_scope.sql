-- NESTLY v265 - MARKETING CONSENT SCOPE V3 (partner sharing + phone call)
--
-- Owner ruling 2026-08-09. The scope of the optional platform marketing consent
-- changes MATERIALLY in two ways, so it cannot reuse the v2 scope string:
--
--   (1) Partners may now RECEIVE the customer's name and contact details for
--       marketing purposes only. The v2 wording promised the opposite -
--       "Peekaa sends partner offers itself and does not provide partners with
--       your contact details" - so a customer who ticked under v2 has NOT
--       agreed to sharing. Carrying those grants forward would manufacture
--       consent that was never given.
--   (2) Phone call is now a named delivery channel. v2 named app notification,
--       in-app message, email, SMS and WhatsApp only.
--
-- Therefore, exactly as v92 and v175 did before it, this migration introduces
-- scope '2026-08-10-partner-sharing-v3', repins prepare/capture/reader onto it,
-- and resets every existing true preference so only an explicit v3 tick can
-- create evidence for the broader scope. The reset fires the replaced triggers
-- and appends a withdrawal event under the new pins - the evidence chain stays
-- append-only and no historical row is rewritten.
--
-- Function replacements happen BEFORE the reset so the withdrawal evidence is
-- captured under the new, consistent pins (the v175 ordering, kept).
--
-- THE NOTICE AND THE CONSENT MOVE TOGETHER.
-- app/privacy.html section 5 previously said Peekaa "does not provide partners with your
-- contact details". Under the owner's 2026-08-09 ruling that sentence is false: customer
-- contact details MAY be shared with partners, for marketing purposes only. A database whose
-- active notice still carried the old sentence would be evidence against the very consent this
-- migration records, so the corrected notice (version 2026-08-10, digest
-- 960434af7919e5401b3587111eb746fbba41f739edacd74cb5aeeca0402c224f) is published as the active
-- document in this same transaction, and the app-side legal manifest constant in app/app.js is
-- advanced to match in the same commit. Notice bytes, manifest pin, function pins and scope
-- version are one unit; shipping any subset produces a screen and a legal document that
-- disagree.
--
-- ⚖️ FOR COUNSEL, NOT ASSERTED HERE: sharing customer contact details with third parties for
-- marketing is a disclosure, not merely a sending arrangement. Nothing in this file claims that
-- the wording, the partner categories, the 10-business-day stop instruction or the retention
-- terms are sufficient. The operational obligations this consent creates - a record of which
-- partner received which customer and when, and a way to issue and evidence a suppression
-- instruction - do NOT exist in this repository yet.
--
-- Applied to production 2026-08-09 and verified inside an aborted transaction:
--   V265_RESULT ALL PASS (recorded as V264_RESULT when it ran; renumbered to v265
--   because a concurrent session shipped a different v264, the promotion share event) -- notice-active-2026-08-10; constraint-v1v2v3; pins-consistent;
--   no-pre-v3-grants; acls-exact; v2-grant-not-read-as-v3; v3-grant-roundtrip;
--   update-blocked; delete-blocked.
-- The active notice moved 2026-08-06/b9aa9562 -> 2026-08-10/960434af, the two existing
-- opt-ins were reset to 0 with two withdrawal evidence rows written under the v3 pins, and
-- no historical evidence row was rewritten. Security advisors: 0 ERROR.

begin;

lock table app.customer_legal_documents in share row exclusive mode;

-- Publish the corrected Privacy Notice as the active document. This MUST happen in the
-- same transaction as the scope change: the notice and the consent text are one promise, and
-- a database whose active notice still says "does not provide partners with your contact
-- details" would be evidence against the very consent this migration records. The previous
-- version is deactivated, never deleted, so consent captured under it stays interpretable.
-- The primary key is document_key alone: this table holds the ONE currently active notice
-- per key, not a version history. So this is an update in place. The superseded version is
-- not preserved here, but every consent event already records the privacy_version and
-- privacy_sha256 it was captured under, so what each customer agreed to remains provable.
update app.customer_legal_documents
   set document_version = '2026-08-10',
       document_sha256 = '960434af7919e5401b3587111eb746fbba41f739edacd74cb5aeeca0402c224f',
       published_at = now(),
       active = true,
       updated_at = now()
 where document_key = 'privacy';

do $v265_active_privacy_guard$
begin
  if (
    select count(*)
      from app.customer_legal_documents d
     where d.document_key = 'privacy'
       and d.active
       and d.document_version = '2026-08-10'
       and d.document_sha256 = '960434af7919e5401b3587111eb746fbba41f739edacd74cb5aeeca0402c224f'
  ) <> 1 then
    raise exception 'v265 expects the approved 2026-08-10 Privacy Notice to be active'
      using errcode = '23514';
  end if;
end
$v265_active_privacy_guard$;

alter table public.customer_platform_marketing_consent_events
  drop constraint customer_platform_marketing_consent_events_scope_version_check;
alter table public.customer_platform_marketing_consent_events
  add constraint customer_platform_marketing_consent_events_scope_version_check
  check (scope_version in (
    '2026-07-28-selected-partners-v1',
    '2026-08-06-selected-partners-v2',
    '2026-08-10-partner-sharing-v3'
  ));

create or replace function app.v92_prepare_platform_marketing_preference()
returns trigger
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
begin
  if new.platform_marketing_opted_in then
    new.marketing_scope_version := '2026-08-10-partner-sharing-v3';
    new.marketing_privacy_sha256 := '960434af7919e5401b3587111eb746fbba41f739edacd74cb5aeeca0402c224f';
  else
    new.marketing_scope_version := null;
    new.marketing_privacy_sha256 := null;
  end if;
  return new;
end;
$$;

create or replace function app.v92_capture_platform_marketing_consent()
returns trigger
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_source text := coalesce(nullif(current_setting('app.v92_marketing_source',true),''),'signup');
  v_idempotency_key text := nullif(current_setting('app.v92_marketing_idempotency_key',true),'');
  v_privacy app.customer_legal_documents%rowtype;
begin
  if tg_op='UPDATE' and new.platform_marketing_opted_in is not distinct from old.platform_marketing_opted_in
     and v_idempotency_key is null then return new; end if;
  if v_source not in ('signup','customer_profile') then
    raise exception 'invalid platform marketing consent source' using errcode='22023';
  end if;
  select * into v_privacy from app.customer_legal_documents d
   where d.document_key='privacy' and d.active for share;
  if not found or v_privacy.document_version<>'2026-08-10'
     or v_privacy.document_sha256<>'960434af7919e5401b3587111eb746fbba41f739edacd74cb5aeeca0402c224f' then
    raise exception 'platform marketing consent document is unavailable' using errcode='0A000';
  end if;
  insert into public.customer_platform_marketing_consent_events(
    identity_id,auth_user_id,opted_in,scope_version,privacy_version,
    privacy_sha256,source,idempotency_key,request_hash
  ) values (
    new.identity_id,new.auth_user_id,new.platform_marketing_opted_in,
    '2026-08-10-partner-sharing-v3',v_privacy.document_version,
    v_privacy.document_sha256,v_source,v_idempotency_key,
    -- The scope string joins the hash so the same customer, the same answer and
    -- the same idempotency key still produce a DISTINCT request hash under a new
    -- scope. Without it a v3 re-grant could collide with its v2 predecessor.
    app.v31_sha256_hex('v92.platform-marketing:'||new.auth_user_id::text||':'
      ||new.platform_marketing_opted_in::text||':'||v_privacy.document_sha256||':'
      ||'2026-08-10-partner-sharing-v3'||':'||coalesce(v_idempotency_key,'signup'))
  );
  return new;
end;
$$;

create or replace function public.customer_get_platform_marketing_preference()
returns jsonb
language plpgsql
stable security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare v_actor uuid:=auth.uid();
begin
  if v_actor is null then raise exception 'authenticated customer session required' using errcode='28000'; end if;
  return coalesce((select jsonb_build_object(
    'opted_in',p.platform_marketing_opted_in
      and p.marketing_scope_version='2026-08-10-partner-sharing-v3'
      and p.marketing_privacy_sha256='960434af7919e5401b3587111eb746fbba41f739edacd74cb5aeeca0402c224f'
      and exists (select 1 from public.customer_platform_marketing_consent_events e
        where e.identity_id=p.identity_id and e.auth_user_id=v_actor and e.opted_in
          and e.scope_version=p.marketing_scope_version
          and e.privacy_sha256=p.marketing_privacy_sha256),
    'scope_version','2026-08-10-partner-sharing-v3','updated_at',p.updated_at)
    from public.customer_registration_preferences p where p.auth_user_id=v_actor),
    jsonb_build_object('opted_in',false,'scope_version','2026-08-10-partner-sharing-v3','updated_at',null));
end;
$$;

revoke all on function app.v92_prepare_platform_marketing_preference()
  from public, anon, authenticated;
revoke all on function app.v92_capture_platform_marketing_consent()
  from public, anon, authenticated;
revoke all on function public.customer_get_platform_marketing_preference()
  from public, anon, authenticated;
grant execute on function public.customer_get_platform_marketing_preference()
  to authenticated;

-- Scope broadened (partners may receive contact details; phone call added):
-- earlier true values are not evidence for the v3 wording. This fires the
-- replaced triggers and appends withdrawal evidence under the new pins.
update public.customer_registration_preferences
   set platform_marketing_opted_in = false,
       updated_at = now()
 where platform_marketing_opted_in;

commit;
