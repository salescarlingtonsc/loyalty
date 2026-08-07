-- v223 acceptance — seating is opt-in, and turning it on is the owner's own call.
-- Rolled back at the end. Set v223.business (an appointment tenant) and v223.owner.

begin;

do $suite$
declare
  v_biz uuid := current_setting('v223.business', true)::uuid;
  v_owner uuid; v_flag boolean; v_hold int; v_overflow text;
  v_pass int := 0; v_fail int := 0; v_log text := '';
begin
  if v_biz is null then raise exception 'set v223.business and v223.owner'; end if;
  select s.user_id into v_owner from public.staff s
  where s.business_id=v_biz and s.role='owner' and s.active limit 1;

  -- The backfill must reflect what a business IS and DOES, not a blanket default.
  select takes_table_reservations into v_flag from public.businesses where id=v_biz;
  if v_flag = false
    then v_pass:=v_pass+1; v_log:=v_log||E'\nPASS 1  an appointment business does not seat guests by default';
    else v_fail:=v_fail+1; v_log:=v_log||E'\nFAIL 1  flag is '||v_flag::text; end if;
  if not exists(select 1 from public.businesses
                where industry='fnb' and takes_table_reservations=false)
    then v_pass:=v_pass+1; v_log:=v_log||E'\nPASS 2  every F&B business kept seating';
    else v_fail:=v_fail+1; v_log:=v_log||E'\nFAIL 2  an F&B business lost seating'; end if;
  if not exists(select 1 from public.businesses b
                where b.takes_table_reservations=false
                  and exists(select 1 from public.booking_tables t where t.business_id=b.id))
    then v_pass:=v_pass+1; v_log:=v_log||E'\nPASS 3  nobody with existing tables was switched off under them';
    else v_fail:=v_fail+1; v_log:=v_log||E'\nFAIL 3  a business with tables lost seating'; end if;

  perform set_config('request.jwt.claims',
    json_build_object('sub', v_owner::text, 'role','authenticated')::text, true);
  perform set_config('role','authenticated', true);

  -- The owner can turn it on without a platform operator.
  perform public.set_booking_settings(v_biz, 15, null, null, null, true);
  select takes_table_reservations into v_flag from public.businesses where id=v_biz;
  if v_flag then v_pass:=v_pass+1; v_log:=v_log||E'\nPASS 4  the owner can switch seating on';
  else v_fail:=v_fail+1; v_log:=v_log||E'\nFAIL 4  flag stayed off'; end if;

  -- A null must leave a stored value alone. This is what lets the spa form omit the seating
  -- controls entirely without wiping the settings behind them.
  update public.businesses set booking_overflow='reject', booking_hold_minutes=30 where id=v_biz;
  perform public.set_booking_settings(v_biz, 20, null, null, null, null);
  select booking_overflow, booking_hold_minutes, takes_table_reservations
    into v_overflow, v_hold, v_flag from public.businesses where id=v_biz;
  if v_overflow='reject' and v_hold=20 and v_flag
    then v_pass:=v_pass+1; v_log:=v_log||E'\nPASS 5  omitted settings are kept, the sent one is applied';
    else v_fail:=v_fail+1; v_log:=v_log||E'\nFAIL 5  overflow='||v_overflow||' hold='||v_hold||' seating='||v_flag::text; end if;

  -- And off again.
  perform public.set_booking_settings(v_biz, 20, null, null, null, false);
  select takes_table_reservations into v_flag from public.businesses where id=v_biz;
  if not v_flag then v_pass:=v_pass+1; v_log:=v_log||E'\nPASS 6  and can switch it back off';
  else v_fail:=v_fail+1; v_log:=v_log||E'\nFAIL 6  flag stayed on'; end if;

  -- Only the owner.
  perform set_config('request.jwt.claims',
    json_build_object('sub', gen_random_uuid()::text, 'role','authenticated')::text, true);
  begin
    perform public.set_booking_settings(v_biz, 20, null, null, null, true);
    v_fail:=v_fail+1; v_log:=v_log||E'\nFAIL 7  a stranger changed booking settings';
  exception when others then
    v_pass:=v_pass+1; v_log:=v_log||E'\nPASS 7  a stranger is refused';
  end;

  raise notice 'V223 acceptance: % passed, % failed%', v_pass, v_fail, v_log;
  if v_fail > 0 then
    raise exception 'V223 acceptance failed: % of %%', v_fail, v_pass+v_fail, v_log;
  end if;
end $suite$;

rollback;
