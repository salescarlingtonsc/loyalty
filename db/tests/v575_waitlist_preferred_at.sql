-- Rollback-only acceptance for nestly_v575 — the waitlist's wanted date and time.
-- Run: supabase db query --linked -f db/tests/v575_waitlist_preferred_at.sql
-- Any row whose value starts with FAIL is a failure. Nothing is committed.
--
--   01  the column exists, is a timestamptz, and is NULLABLE — a NOT NULL here would reject
--       every legacy row and every walk-in added without a time.
--   02  the free-text column is still there and still readable: v575 adds, it does not migrate.
--   03  a row can be written with only a phrase (legacy shape) and with only an instant
--       (v575 shape). Both survive, which is what lets the reader fall back.

begin;

create temp table _r(check_id text, value text) on commit drop;

insert into _r
select '01 preferred_at is a nullable timestamptz',
  case when count(*) = 0 then 'FAIL: column missing'
       when bool_or(data_type <> 'timestamp with time zone') then 'FAIL: wrong type'
       when bool_or(is_nullable = 'NO') then 'FAIL: NOT NULL would reject legacy and untimed rows'
       else 'OK' end
from information_schema.columns
where table_schema = 'public' and table_name = 'waitlist' and column_name = 'preferred_at';

insert into _r
select '02 the legacy free-text window is untouched',
  case when count(*) = 1 then 'OK' else 'FAIL: preferred column was removed' end
from information_schema.columns
where table_schema = 'public' and table_name = 'waitlist' and column_name = 'preferred';

do $flow$
declare v_biz uuid; v_legacy uuid; v_dated uuid;
begin
  select id into v_biz from public.businesses order by created_at limit 1;
  insert into public.waitlist(business_id, name, status, preferred)
    values (v_biz, 'v575 legacy fixture', 'waiting', 'weekday eve') returning id into v_legacy;
  insert into public.waitlist(business_id, name, status, preferred_at)
    values (v_biz, 'v575 dated fixture', 'waiting', now() + interval '1 day') returning id into v_dated;

  insert into _r values ('03a a legacy row still writes with only a phrase',
    case when exists(select 1 from public.waitlist
                      where id = v_legacy and preferred = 'weekday eve' and preferred_at is null)
      then 'OK' else 'FAIL' end);
  insert into _r values ('03b a v575 row writes with only an instant',
    case when exists(select 1 from public.waitlist
                      where id = v_dated and preferred_at is not null and preferred is null)
      then 'OK' else 'FAIL' end);
end;
$flow$;

select check_id, value from _r order by check_id;

rollback;
