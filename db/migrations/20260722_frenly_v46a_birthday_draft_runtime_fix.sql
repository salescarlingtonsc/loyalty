-- FRENLY V46A BIRTHDAY DRAFT RUNTIME FIX
--
-- PostgreSQL rejects row-locking statements inside STABLE functions. The C45
-- owner draft reader deliberately takes FOR SHARE so its header and programme
-- rows are observed against a locked draft version; it must therefore be
-- VOLATILE even though it does not mutate application rows.

begin;

alter function public.get_birthday_program_draft(uuid) volatile;

-- Reassert the reviewed browser boundary after the catalog change.
revoke all on function public.get_birthday_program_draft(uuid)
  from public, anon, authenticated;
grant execute on function public.get_birthday_program_draft(uuid)
  to authenticated;

commit;
