-- Rollback-only v80 Nestly customer legal manifest acceptance suite.
-- Run after the canonical chain through v80 in a disposable rehearsal database.
begin;

do $v80_test$
begin
  if to_regprocedure('public.customer_get_platform_marketing_preference()') is not null then
    if (
      select count(*)
        from app.customer_legal_documents d
       where (
         d.document_key = 'terms'
         and d.document_version = '2026-07-26'
         and d.document_sha256 = '12aff22e35449a889c75d7cb3705a0f7c58a5de333a8b25a81128e89b76b4618'
         and d.published_at = timestamptz '2026-07-26 00:00:00+08:00'
         and d.active
       ) or (
         d.document_key = 'privacy'
         and d.document_version = '2026-07-28'
         and d.document_sha256 = '49b83b2300f42f447b8b7cbf42a1ff8a5aa4661f054aab15de53f8d41135f5f5'
         and d.published_at = timestamptz '2026-07-28 00:00:00+08:00'
         and d.active
       )
    ) <> 2 then
      raise exception 'later authoritative Nestly legal manifest is not exact';
    end if;
  elsif (
    select count(*)
      from app.customer_legal_documents d
     where (
       d.document_key = 'terms'
       and d.document_version = '2026-07-26'
       and d.document_sha256 = '12aff22e35449a889c75d7cb3705a0f7c58a5de333a8b25a81128e89b76b4618'
       and d.published_at = timestamptz '2026-07-26 00:00:00+08:00'
       and d.active
     ) or (
       d.document_key = 'privacy'
       and d.document_version = '2026-07-26'
       and d.document_sha256 = 'e3b82c000904491591d1d077052099b50f9a25e5a1ebd1e2a587da0789e274b0'
       and d.published_at = timestamptz '2026-07-26 00:00:00+08:00'
       and d.active
     )
  ) <> 2 then
    raise exception 'v80 owner-approved Nestly legal manifest is not exact';
  end if;

  if has_table_privilege('anon', 'app.customer_legal_documents', 'select')
     or has_table_privilege('authenticated', 'app.customer_legal_documents', 'select')
     or has_table_privilege('anon', 'app.customer_legal_documents', 'insert')
     or has_table_privilege('authenticated', 'app.customer_legal_documents', 'insert')
     or has_table_privilege('anon', 'app.customer_legal_documents', 'update')
     or has_table_privilege('authenticated', 'app.customer_legal_documents', 'update')
     or has_table_privilege('anon', 'app.customer_legal_documents', 'delete')
     or has_table_privilege('authenticated', 'app.customer_legal_documents', 'delete') then
    raise exception 'v80 widened browser access to the private legal manifest';
  end if;

  raise notice 'v80 Nestly customer legal manifest suite: ALL PASS';
end
$v80_test$;

rollback;
