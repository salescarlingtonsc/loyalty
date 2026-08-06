-- NESTLY v175 - MARKETING CONSENT SCOPE V2 (Peekaa-sends partner model)
--
-- Owner-approved 2026-08-06. Three things:
--
-- (1) Advances the active Privacy Notice to the 6 August 2026 wording that
--     names the delivery channels (app notification, in-app message, email,
--     SMS, WhatsApp) and states that Peekaa sends partner offers itself and
--     does not provide partners with contact details. Terms are untouched.
--
-- (2) Introduces marketing consent scope '2026-08-06-selected-partners-v2'
--     for the new explicit-channel wording shown at signup and in Profile.
--     Prior true values are reset so only an explicit v2 choice creates
--     evidence for the broader channel scope (mirrors the v92 precedent).
--
-- (3) Repairs the consent-evidence chain: since the 2026-08-03 privacy
--     advance, app.v92_prepare_platform_marketing_preference still stamped
--     the older 67e51a… digest while the capture trigger recorded the active
--     8e152d… digest, so customer_get_platform_marketing_preference computed
--     opted_in=false for every grant made under that build. All three
--     functions now pin the same active document.
--
-- Function replacements happen BEFORE the preference reset so the reset's
-- withdrawal evidence is captured under the new, consistent pins.

begin;

lock table app.customer_legal_documents in share row exclusive mode;

do $v175_marketing_consent_scope_v2$
begin
  if not exists (
    select 1
      from app.customer_legal_documents d
     where d.document_key = 'privacy'
       and (
         (
           d.document_version = '2026-08-03'
           and d.document_sha256 = '8e152d208b271da5a1f71630b17c5c82e8b7bd930c5508da8b4d95597c0a1568'
           and d.active
         )
         or (
           d.document_version = '2026-08-06'
           and d.document_sha256 = 'b9aa956263f0ac12d85be069ee05b4960b4130be33289c06df1e4eee59c59245'
           and d.active
         )
       )
  ) then
    raise exception 'customer legal manifest conflicts with approved Peekaa privacy notice'
      using errcode = '23505';
  end if;

  update app.customer_legal_documents d
     set document_version = '2026-08-06',
         document_sha256 = 'b9aa956263f0ac12d85be069ee05b4960b4130be33289c06df1e4eee59c59245',
         published_at = timestamptz '2026-08-06 00:00:00+08:00',
         updated_at = timestamptz '2026-08-06 00:00:00+08:00'
   where d.document_key = 'privacy'
     and d.document_version = '2026-08-03'
     and d.document_sha256 = '8e152d208b271da5a1f71630b17c5c82e8b7bd930c5508da8b4d95597c0a1568'
     and d.active;

  if (
    select count(*)
      from app.customer_legal_documents d
     where d.document_key = 'privacy'
       and d.document_version = '2026-08-06'
       and d.document_sha256 = 'b9aa956263f0ac12d85be069ee05b4960b4130be33289c06df1e4eee59c59245'
       and d.active
  ) <> 1 then
    raise exception 'approved Peekaa privacy notice was not published exactly'
      using errcode = '23514';
  end if;
end
$v175_marketing_consent_scope_v2$;

alter table public.customer_platform_marketing_consent_events
  drop constraint customer_platform_marketing_consent_events_scope_version_check;
alter table public.customer_platform_marketing_consent_events
  add constraint customer_platform_marketing_consent_events_scope_version_check
  check (scope_version in (
    '2026-07-28-selected-partners-v1',
    '2026-08-06-selected-partners-v2'
  ));

create or replace function app.v92_prepare_platform_marketing_preference()
returns trigger
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
begin
  if new.platform_marketing_opted_in then
    new.marketing_scope_version := '2026-08-06-selected-partners-v2';
    new.marketing_privacy_sha256 := 'b9aa956263f0ac12d85be069ee05b4960b4130be33289c06df1e4eee59c59245';
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
  if not found or v_privacy.document_version<>'2026-08-06'
     or v_privacy.document_sha256<>'b9aa956263f0ac12d85be069ee05b4960b4130be33289c06df1e4eee59c59245' then
    raise exception 'platform marketing consent document is unavailable' using errcode='0A000';
  end if;
  insert into public.customer_platform_marketing_consent_events(
    identity_id,auth_user_id,opted_in,scope_version,privacy_version,
    privacy_sha256,source,idempotency_key,request_hash
  ) values (
    new.identity_id,new.auth_user_id,new.platform_marketing_opted_in,
    '2026-08-06-selected-partners-v2',v_privacy.document_version,
    v_privacy.document_sha256,v_source,v_idempotency_key,
    app.v31_sha256_hex('v92.platform-marketing:'||new.auth_user_id::text||':'
      ||new.platform_marketing_opted_in::text||':'||v_privacy.document_sha256||':'
      ||coalesce(v_idempotency_key,'signup'))
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
      and p.marketing_scope_version='2026-08-06-selected-partners-v2'
      and p.marketing_privacy_sha256='b9aa956263f0ac12d85be069ee05b4960b4130be33289c06df1e4eee59c59245'
      and exists (select 1 from public.customer_platform_marketing_consent_events e
        where e.identity_id=p.identity_id and e.auth_user_id=v_actor and e.opted_in
          and e.scope_version=p.marketing_scope_version
          and e.privacy_sha256=p.marketing_privacy_sha256),
    'scope_version','2026-08-06-selected-partners-v2','updated_at',p.updated_at)
    from public.customer_registration_preferences p where p.auth_user_id=v_actor),
    jsonb_build_object('opted_in',false,'scope_version','2026-08-06-selected-partners-v2','updated_at',null));
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

-- Scope broadened (explicit channels): earlier true values cannot be carried
-- forward as evidence for the v2 wording. This fires the replaced triggers,
-- appending withdrawal evidence under the new consistent pins.
update public.customer_registration_preferences
   set platform_marketing_opted_in = false,
       updated_at = now()
 where platform_marketing_opted_in;

commit;
