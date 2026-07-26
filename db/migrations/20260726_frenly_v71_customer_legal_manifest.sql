-- FRENLY v71 - OWNER-APPROVED CUSTOMER REGISTRATION LEGAL MANIFEST
--
-- Publishes the already-live Terms and Privacy pages as the exact C42 phone
-- registration acceptance targets. This migration is deliberately data-only:
-- it grants no browser access and changes no registration or legal function.
--
-- Idempotency is exact. A previously published byte-identical manifest is a
-- no-op; any conflicting version, digest, publication time, or active state
-- aborts the transaction rather than silently replacing legal evidence.

begin;

lock table app.customer_legal_documents in share row exclusive mode;

do $v71_customer_legal_manifest$
begin
  if exists (
    select 1
      from app.customer_legal_documents d
     where d.document_key = 'terms'
       and (
         d.document_version <> '2026-07-19'
         or d.document_sha256 <> '8e113ffa36979cab83fcd84221d0baf1107921d030e353a60af428a1ebce09e4'
         or d.published_at <> timestamptz '2026-07-19 00:00:00+08:00'
         or d.active is not true
       )
  ) then
    raise exception 'customer legal manifest conflicts with owner-approved terms'
      using errcode = '23505';
  end if;

  if exists (
    select 1
      from app.customer_legal_documents d
     where d.document_key = 'privacy'
       and (
         d.document_version <> '2026-07-19'
         or d.document_sha256 <> '264045b09e5678c0f38ad48d2ce1e2cc9bdd9e1d11593b69b03a8c9c0c2edba2'
         or d.published_at <> timestamptz '2026-07-19 00:00:00+08:00'
         or d.active is not true
       )
  ) then
    raise exception 'customer legal manifest conflicts with owner-approved privacy notice'
      using errcode = '23505';
  end if;

  insert into app.customer_legal_documents (
    document_key,
    document_version,
    document_sha256,
    published_at,
    active
  )
  values
    (
      'terms',
      '2026-07-19',
      '8e113ffa36979cab83fcd84221d0baf1107921d030e353a60af428a1ebce09e4',
      timestamptz '2026-07-19 00:00:00+08:00',
      true
    ),
    (
      'privacy',
      '2026-07-19',
      '264045b09e5678c0f38ad48d2ce1e2cc9bdd9e1d11593b69b03a8c9c0c2edba2',
      timestamptz '2026-07-19 00:00:00+08:00',
      true
    )
  on conflict (document_key) do nothing;

  if (
    select count(*)
      from app.customer_legal_documents d
     where (
       d.document_key = 'terms'
       and d.document_version = '2026-07-19'
       and d.document_sha256 = '8e113ffa36979cab83fcd84221d0baf1107921d030e353a60af428a1ebce09e4'
       and d.published_at = timestamptz '2026-07-19 00:00:00+08:00'
       and d.active
     ) or (
       d.document_key = 'privacy'
       and d.document_version = '2026-07-19'
       and d.document_sha256 = '264045b09e5678c0f38ad48d2ce1e2cc9bdd9e1d11593b69b03a8c9c0c2edba2'
       and d.published_at = timestamptz '2026-07-19 00:00:00+08:00'
       and d.active
     )
  ) <> 2 then
    raise exception 'owner-approved customer legal manifest was not published exactly'
      using errcode = '23514';
  end if;
end
$v71_customer_legal_manifest$;

commit;
