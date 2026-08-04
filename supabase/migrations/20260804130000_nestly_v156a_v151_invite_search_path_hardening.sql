-- Peekaa V156a: forward-only hardening for the already-deployed V151 invite RPCs.
-- Function bodies and role grants remain unchanged; only name resolution is pinned.
begin;

alter function public.preview_staff_invite(text)
  set search_path to pg_catalog, public;

alter function public.accept_invite(text)
  set search_path to pg_catalog, public;

commit;
