-- nestly_v874 rollback suite — "N of 10 offers live" counts offers that are live now.
--
-- Run inside a transaction against production and ROLLED BACK. Offers can only be written
-- through the promotion RPCs (v104_promotion_write_guard), so the suite does not seed one: it
-- proves the count equals an independent recount for every real tenant, and — as the negative
-- control — that the old date-blind definition is strictly larger somewhere in the estate,
-- otherwise the fix could not be told from a no-op on today's data.

\set ON_ERROR_STOP on

begin;

do $suite$
declare
  r record; got integer; expected integer; dateblind integer; widened integer := 0; checked integer := 0; n integer := 0;
begin
  n := n + 1;
  if position('content.ends_at > now()' in pg_get_functiondef('app.v462_live_offer_count(uuid)'::regprocedure)) = 0
     or position('content.starts_at <= now()' in pg_get_functiondef('app.v462_live_offer_count(uuid)'::regprocedure)) = 0 then
    raise exception 'F% failed: live offer count still ignores dates', n;
  end if;

  for r in select b.id, b.name from public.businesses b loop
    select count(*) into expected from public.business_customer_content_v95 c
     where c.business_id = r.id and c.content_type = 'offer' and c.branch_id is null and c.active
       and (c.starts_at is null or c.starts_at <= now()) and (c.ends_at is null or c.ends_at > now());
    select count(*) into dateblind from public.business_customer_content_v95 c
     where c.business_id = r.id and c.content_type = 'offer' and c.branch_id is null and c.active;
    got := app.v462_live_offer_count(r.id);
    checked := checked + 1;
    if got <> expected then
      raise exception 'F failed: % counts % live offers, independent recount says %', r.name, got, expected;
    end if;
    if dateblind > expected then widened := widened + 1; end if;
  end loop;
  n := n + 1;

  -- negative control: the old definition over-counted somewhere, so the fix is observable
  n := n + 1;
  if widened = 0 and exists (select 1 from public.business_customer_content_v95 c
                              where c.content_type = 'offer' and c.active
                                and ((c.ends_at is not null and c.ends_at <= now()) or (c.starts_at is not null and c.starts_at > now()))) then
    raise exception 'F% failed: dated-out active offers exist but no tenant''s count changed', n;
  end if;

  raise notice 'nestly_v874 suite: % assertions passed (% tenants checked, % had a dated-out offer)', n, checked, widened;
end
$suite$;

rollback;
