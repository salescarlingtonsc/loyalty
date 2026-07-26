-- NESTLY v80 - CUSTOMER REGISTRATION LEGAL MANIFEST REBRAND
--
-- Advances the C42 registration targets from the immutable v71 Frenly pages
-- to the owner-approved Nestly Terms and Privacy pages published on
-- 26 July 2026. Existing customer acceptance rows remain append-only because
-- they carry their accepted version and digest independently of this manifest.
--
-- Exact idempotency: each current row must be either the v71 predecessor or
-- the byte-identical v80 target. Any other state aborts instead of overwriting
-- legal evidence.

begin;

lock table app.customer_legal_documents in share row exclusive mode;

do $v80_customer_legal_manifest$
begin
  if not exists (
    select 1
      from app.customer_legal_documents d
     where d.document_key = 'terms'
       and (
         (
           d.document_version = '2026-07-19'
           and d.document_sha256 = '8e113ffa36979cab83fcd84221d0baf1107921d030e353a60af428a1ebce09e4'
           and d.published_at = timestamptz '2026-07-19 00:00:00+08:00'
           and d.active
         )
         or (
           d.document_version = '2026-07-26'
           and d.document_sha256 = '12aff22e35449a889c75d7cb3705a0f7c58a5de333a8b25a81128e89b76b4618'
           and d.published_at = timestamptz '2026-07-26 00:00:00+08:00'
           and d.active
         )
       )
  ) then
    raise exception 'customer legal manifest conflicts with owner-approved Nestly terms'
      using errcode = '23505';
  end if;

  if not exists (
    select 1
      from app.customer_legal_documents d
     where d.document_key = 'privacy'
       and (
         (
           d.document_version = '2026-07-19'
           and d.document_sha256 = '264045b09e5678c0f38ad48d2ce1e2cc9bdd9e1d11593b69b03a8c9c0c2edba2'
           and d.published_at = timestamptz '2026-07-19 00:00:00+08:00'
           and d.active
         )
         or (
           d.document_version = '2026-07-26'
           and d.document_sha256 = 'e3b82c000904491591d1d077052099b50f9a25e5a1ebd1e2a587da0789e274b0'
           and d.published_at = timestamptz '2026-07-26 00:00:00+08:00'
           and d.active
         )
       )
  ) then
    raise exception 'customer legal manifest conflicts with owner-approved Nestly privacy notice'
      using errcode = '23505';
  end if;

  update app.customer_legal_documents d
     set document_version = '2026-07-26',
         document_sha256 = '12aff22e35449a889c75d7cb3705a0f7c58a5de333a8b25a81128e89b76b4618',
         published_at = timestamptz '2026-07-26 00:00:00+08:00',
         updated_at = timestamptz '2026-07-26 00:00:00+08:00'
   where d.document_key = 'terms'
     and d.document_version = '2026-07-19'
     and d.document_sha256 = '8e113ffa36979cab83fcd84221d0baf1107921d030e353a60af428a1ebce09e4'
     and d.published_at = timestamptz '2026-07-19 00:00:00+08:00'
     and d.active;

  update app.customer_legal_documents d
     set document_version = '2026-07-26',
         document_sha256 = 'e3b82c000904491591d1d077052099b50f9a25e5a1ebd1e2a587da0789e274b0',
         published_at = timestamptz '2026-07-26 00:00:00+08:00',
         updated_at = timestamptz '2026-07-26 00:00:00+08:00'
   where d.document_key = 'privacy'
     and d.document_version = '2026-07-19'
     and d.document_sha256 = '264045b09e5678c0f38ad48d2ce1e2cc9bdd9e1d11593b69b03a8c9c0c2edba2'
     and d.published_at = timestamptz '2026-07-19 00:00:00+08:00'
     and d.active;

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
       and d.document_version = '2026-07-26'
       and d.document_sha256 = 'e3b82c000904491591d1d077052099b50f9a25e5a1ebd1e2a587da0789e274b0'
       and d.published_at = timestamptz '2026-07-26 00:00:00+08:00'
       and d.active
     )
  ) <> 2 then
    raise exception 'owner-approved Nestly customer legal manifest was not published exactly'
      using errcode = '23514';
  end if;
end
$v80_customer_legal_manifest$;

commit;
