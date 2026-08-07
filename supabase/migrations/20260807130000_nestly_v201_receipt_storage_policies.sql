-- NESTLY v201 — make the receipt bucket usable, and only by the right person.
--
-- v199 created the accounting-private bucket but no storage.objects policy.
-- RLS is on for that table, so the very first browser upload would have been
-- rejected — the receipt flow was API-complete and physically unusable. The
-- bucket also accepted any size and any MIME type, which is not a limit you
-- want on storage holding financial records.
--
-- INSERT and SELECT only, deliberately. There is no UPDATE and no DELETE
-- policy, so a stored receipt cannot be swapped or erased through the API once
-- the books reference it: evidence behind a posted expense has to stay put.

begin;

update storage.buckets
   set file_size_limit = 20971520,
       allowed_mime_types = array['image/jpeg','image/png','image/webp',
                                  'image/heic','application/pdf']
 where id = 'accounting-private';

drop policy if exists accounting_receipts_sa_insert_v201 on storage.objects;
create policy accounting_receipts_sa_insert_v201 on storage.objects
  for insert to authenticated
  with check (
    bucket_id = 'accounting-private'
    and name like 'receipts/%'
    and app.is_super_admin());

drop policy if exists accounting_receipts_sa_read_v201 on storage.objects;
create policy accounting_receipts_sa_read_v201 on storage.objects
  for select to authenticated
  using (
    bucket_id = 'accounting-private'
    and app.is_super_admin());

commit;
