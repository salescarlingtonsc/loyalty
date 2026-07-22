-- FRENLY v47a — remove the retired defaulted phone-sale overload.
-- v47 revoked this legacy signature but left it present, which made every
-- three-to-seven-argument call ambiguous with v47's hardened nine-argument
-- replacement. Removing it is required for deterministic function dispatch.

begin;

drop function if exists public.record_sale_by_phone(
  uuid,text,integer,text,text,uuid,text
);

commit;

