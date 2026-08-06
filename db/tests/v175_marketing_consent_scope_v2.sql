-- Rollback-only acceptance for V175 marketing consent scope v2.
-- Run after the canonical chain through v175 in a disposable local database.
--
-- Proves:
--   * the active Privacy Notice is the 2026-08-06 document with the approved
--     digest;
--   * prepare, capture and reader all pin the SAME active document (the
--     earlier drift that broke evidence matching is repaired);
--   * the events table accepts both scope versions and no true preference
--     survives without matching v2 evidence.
begin;

do $$
declare
  v_doc app.customer_legal_documents%rowtype;
  v_def text;
  v_bad integer;
begin
  select * into v_doc from app.customer_legal_documents
   where document_key='privacy' and active;
  if not found or v_doc.document_version<>'2026-08-06'
     or v_doc.document_sha256<>'b9aa956263f0ac12d85be069ee05b4960b4130be33289c06df1e4eee59c59245' then
    raise exception 'v175 FAIL: active privacy notice is not the approved 2026-08-06 document';
  end if;

  select pg_get_functiondef(p.oid) into v_def
    from pg_proc p join pg_namespace n on n.oid=p.pronamespace
   where n.nspname='app' and p.proname='v92_prepare_platform_marketing_preference';
  if v_def not like '%2026-08-06-selected-partners-v2%'
     or v_def not like '%b9aa956263f0ac12d85be069ee05b4960b4130be33289c06df1e4eee59c59245%' then
    raise exception 'v175 FAIL: prepare trigger does not pin the v2 scope and active digest';
  end if;

  select pg_get_functiondef(p.oid) into v_def
    from pg_proc p join pg_namespace n on n.oid=p.pronamespace
   where n.nspname='app' and p.proname='v92_capture_platform_marketing_consent';
  if v_def not like '%b9aa956263f0ac12d85be069ee05b4960b4130be33289c06df1e4eee59c59245%' then
    raise exception 'v175 FAIL: capture trigger does not require the active 2026-08-06 digest';
  end if;

  select pg_get_functiondef(p.oid) into v_def
    from pg_proc p join pg_namespace n on n.oid=p.pronamespace
   where n.nspname='public' and p.proname='customer_get_platform_marketing_preference';
  if v_def not like '%2026-08-06-selected-partners-v2%'
     or v_def not like '%b9aa956263f0ac12d85be069ee05b4960b4130be33289c06df1e4eee59c59245%' then
    raise exception 'v175 FAIL: preference reader does not accept the v2 scope and digest';
  end if;

  if (select pg_get_constraintdef(oid) from pg_constraint
       where conrelid='public.customer_platform_marketing_consent_events'::regclass
         and conname='customer_platform_marketing_consent_events_scope_version_check')
     not like '%2026-08-06-selected-partners-v2%' then
    raise exception 'v175 FAIL: events scope constraint does not admit the v2 scope';
  end if;

  select count(*) into v_bad from public.customer_registration_preferences p
   where p.platform_marketing_opted_in
     and (p.marketing_scope_version is distinct from '2026-08-06-selected-partners-v2'
       or p.marketing_privacy_sha256 is distinct from 'b9aa956263f0ac12d85be069ee05b4960b4130be33289c06df1e4eee59c59245');
  if v_bad<>0 then
    raise exception 'v175 FAIL: % opted-in preference rows carry non-v2 scope evidence', v_bad;
  end if;

  raise notice 'v175 PASS: privacy 2026-08-06 active; consent pins consistent; v2 scope admitted';
end $$;

rollback;
