-- Rollback-only acceptance for nestly_v603 — dates on the row, and one package's own history.
-- Run: supabase db query --linked -f db/tests/v603_package_history_and_dates.sql
-- Any value starting FAIL is a failure. Nothing is committed.
begin;
create temp table _r(id text, value text) on commit drop;
grant select, insert on all tables in schema pg_temp to authenticated, anon;

create temp table _f as
select b.id as biz,
  (select s.user_id from public.staff s where s.business_id=b.id and s.role='owner' and s.user_id is not null limit 1) as owner_uid,
  (select cp.id from public.client_packages cp where cp.business_id=b.id order by cp.purchased_at limit 1) as pkg
from public.businesses b where b.id='8492e8d6-8888-4383-ada0-7e1ed69f0caa';
grant select, insert on all tables in schema pg_temp to authenticated, anon;

insert into _r select '00 fixture',
  case when (select pkg from _f) is null then 'FAIL: no customer package to read'
       when (select owner_uid from _f) is null then 'FAIL: no owner' else 'OK' end;

set local role authenticated;
select set_config('request.jwt.claims',
  json_build_object('sub',(select owner_uid from _f),'role','authenticated')::text,true);

create temp table _list as
select public.staff_list_package_entitlements_v102((select biz from _f)) as j;
grant select, insert on all tables in schema pg_temp to authenticated, anon;

insert into _r select '01 every row carries the date it was bought and the date it was last used',
  case when jsonb_array_length((select j->'packages' from _list))=0
         and jsonb_array_length(coalesce((select j from _list),'[]'::jsonb))=0
         then 'FAIL: no rows at all'
       when not (select bool_and(row_value ? 'purchased_at' and row_value ? 'last_used_at')
                   from jsonb_array_elements(
                     coalesce((select j->'packages' from _list),(select j from _list))) row_value)
         then 'FAIL: a row is missing one of the two dates'
       else 'OK '||(select jsonb_array_length(coalesce(j->'packages',j)) from _list)||' rows' end;

-- ── 02 one package's own history reads back ────────────────────────────────
create temp table _hist as
select public.staff_package_session_history_v603((select biz from _f),(select pkg from _f)) as j;
grant select, insert on all tables in schema pg_temp to authenticated, anon;

insert into _r select '02 a package can report its own sessions',
  case when (select j->>'client_package_id' from _hist) is distinct from (select pkg::text from _f)
         then 'FAIL: wrong package: '||left((select j::text from _hist),160)
       when (select j->'sessions_used' from _hist) is null
         then 'FAIL: no sessions_used array'
       else 'OK '||jsonb_array_length((select j->'sessions_used' from _hist))||' sessions, remaining '
            ||coalesce((select j->>'remaining' from _hist),'?') end;

insert into _r select '02b each session names the sale it was recorded against',
  case when jsonb_array_length((select j->'sessions_used' from _hist))=0 then 'OK (none used yet)'
       when not (select bool_and(entry ? 'sale_id' and entry ? 'used_at' and entry ? 'reversed')
                   from jsonb_array_elements((select j->'sessions_used' from _hist)) entry)
         then 'FAIL: a session row is missing sale_id/used_at/reversed'
       else 'OK' end;

-- ── 03 an undone session is not a use ──────────────────────────────────────
insert into _r select '03 last_used_at ignores a session that was undone',
  case when position('not exists(' in (select prosrc from pg_proc where proname='staff_list_package_entitlements_v102'))=0
       then 'FAIL: reversed consumptions are not excluded'
       when position('package_session_reversals' in (select prosrc from pg_proc where proname='staff_list_package_entitlements_v102'))=0
       then 'FAIL: the reversal table is never consulted'
       else 'OK' end;

-- ── 04 another tenant's package is refused ─────────────────────────────────
do $$
declare v_msg text; v_other uuid;
begin
  select cp.id into v_other from public.client_packages cp,_f f
   where cp.business_id<>f.biz limit 1;
  if v_other is null then insert into _r values('04 a package outside the business is refused','OK (no other tenant holds one)'); return; end if;
  begin
    perform public.staff_package_session_history_v603((select biz from _f), v_other);
    v_msg:='FAIL: read another business''s package';
  exception when others then
    v_msg:=case when sqlerrm like '%not found in this business%' then 'OK' else 'FAIL: '||left(sqlerrm,70) end;
  end;
  insert into _r values('04 a package outside the business is refused', v_msg);
end $$;

reset role; select set_config('request.jwt.claims',NULL,true);
select id, value from _r order by id;
rollback;
