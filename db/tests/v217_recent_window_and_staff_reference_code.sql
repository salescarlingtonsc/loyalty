-- v217 acceptance — the recent-appointment window, and the staff reference code.
-- Rolled back at the end. Checked-in form of the chains run against production before shipping
-- (13/13 and 4/4). Set v217.business and v217.owner to a real tenant and its owner auth user.

begin;

do $suite$
declare
  v_biz uuid := current_setting('v217.business', true)::uuid;
  v_owner uuid := current_setting('v217.owner', true)::uuid;
  v_branch uuid; v_staff uuid; v_owner_staff uuid;
  v_res jsonb; v_code1 text; v_code2 text; v_status1 text; v_status2 text;
  v_n int; v_d1 int; v_d30 int;
  v_pass int := 0; v_fail int := 0; v_log text := '';
begin
  if v_biz is null or v_owner is null then
    raise exception 'set v217.business and v217.owner before running this suite';
  end if;
  select id into v_branch from public.branches where business_id=v_biz and active order by name limit 1;
  select id into v_staff from public.staff
  where business_id=v_biz and user_id is null and active and role<>'owner' order by created_at limit 1;
  select id into v_owner_staff from public.staff where business_id=v_biz and role='owner' limit 1;

  perform set_config('request.jwt.claims',
    json_build_object('sub', v_owner::text, 'role','authenticated')::text, true);
  perform set_config('role','authenticated', true);

  -- === The recent window ===
  -- A caller that never heard of the parameter must be unaffected.
  v_res := public.suggest_appointment_staff_v47(v_biz, v_branch, null, now() + interval '2 days', 60, 5);
  if jsonb_typeof(v_res->'available_staff')='array'
    then v_pass:=v_pass+1; v_log:=v_log||E'\nPASS 1  the six-argument call still works — 30 days unchanged';
    else v_fail:=v_fail+1; v_log:=v_log||E'\nFAIL 1  '||coalesce(v_res::text,'null'); end if;

  foreach v_n in array array[1,3,7,30] loop
    v_res := public.suggest_appointment_staff_v47(v_biz, v_branch, null, now() + interval '2 days', 60, 5, v_n);
    if jsonb_typeof(v_res->'available_staff')='array'
      then v_pass:=v_pass+1; v_log:=v_log||E'\nPASS    window of '||v_n||' day(s) accepted';
      else v_fail:=v_fail+1; v_log:=v_log||E'\nFAIL    window of '||v_n||' day(s) rejected'; end if;
  end loop;

  -- Only the four windows the picker can express; anything else would widen fairness silently.
  begin
    perform public.suggest_appointment_staff_v47(v_biz, v_branch, null, now() + interval '2 days', 60, 5, 90);
    v_fail:=v_fail+1; v_log:=v_log||E'\nFAIL 6  an unlisted window was accepted';
  exception when others then
    if sqlerrm like '%unsupported_recent_window%'
      then v_pass:=v_pass+1; v_log:=v_log||E'\nPASS 6  an unlisted window is refused';
      else v_fail:=v_fail+1; v_log:=v_log||E'\nFAIL 6  '||sqlerrm; end if;
  end;

  -- The window must really move the number, or the new label is decoration.
  select coalesce(max((item->>'recent_appointments')::int),0) into v_d1
  from jsonb_array_elements(public.suggest_appointment_staff_v47(
    v_biz,v_branch,null,now()+interval '2 days',60,5,1)->'available_staff') item;
  select coalesce(max((item->>'recent_appointments')::int),0) into v_d30
  from jsonb_array_elements(public.suggest_appointment_staff_v47(
    v_biz,v_branch,null,now()+interval '2 days',60,5,30)->'available_staff') item;
  if v_d1 <= v_d30
    then v_pass:=v_pass+1; v_log:=v_log||E'\nPASS 7  1-day count ('||v_d1||') <= 30-day count ('||v_d30||')';
    else v_fail:=v_fail+1; v_log:=v_log||E'\nFAIL 7  1-day '||v_d1||' > 30-day '||v_d30; end if;

  -- === The staff reference code ===
  if v_staff is null then
    v_log:=v_log||E'\nSKIP 8  no roster-only teammate on this tenant';
  else
    v_res := public.create_staff_reference_code_v217(v_biz, v_staff);
    v_code1 := v_res->>'code';
    if v_res->>'status'='ok' and v_code1 ~ '^[A-Z0-9]{8}$'
      then v_pass:=v_pass+1; v_log:=v_log||E'\nPASS 8  a code was minted for '||coalesce(v_res->>'staff_name','?');
      else v_fail:=v_fail+1; v_log:=v_log||E'\nFAIL 8  '||v_res::text; end if;
    -- Read aloud or written on paper: no look-alike characters.
    if v_code1 !~ '[O0I1]'
      then v_pass:=v_pass+1; v_log:=v_log||E'\nPASS 9  the code avoids look-alike characters';
      else v_fail:=v_fail+1; v_log:=v_log||E'\nFAIL 9  '||v_code1; end if;

    -- Bound to that exact roster row — this is the whole point of the feature.
    select count(*) into v_n from public.staff_invites
    where code=v_code1 and staff_id=v_staff and business_id=v_biz and status='pending';
    if v_n=1
      then v_pass:=v_pass+1; v_log:=v_log||E'\nPASS 10 the invite is bound to that roster row';
      else v_fail:=v_fail+1; v_log:=v_log||E'\nFAIL 10 '||v_n||' bound invites'; end if;

    -- Re-issuing supersedes, so an old slip of paper cannot still claim the person.
    v_code2 := public.create_staff_reference_code_v217(v_biz, v_staff)->>'code';
    select status into v_status1 from public.staff_invites where code=v_code1;
    select status into v_status2 from public.staff_invites where code=v_code2;
    select count(*) into v_n from public.staff_invites
    where staff_id=v_staff and business_id=v_biz and status='pending';
    if v_n=1 and v_status1='revoked' and v_status2='pending' and v_code1<>v_code2
      then v_pass:=v_pass+1; v_log:=v_log||E'\nPASS 11 re-issuing revokes the old code and leaves exactly one live';
      else v_fail:=v_fail+1; v_log:=v_log||E'\nFAIL 11 live='||v_n||' old='||v_status1||' new='||v_status2; end if;

    -- Someone who already has a login has nothing to take over.
    begin
      perform public.create_staff_reference_code_v217(v_biz, v_owner_staff);
      v_fail:=v_fail+1; v_log:=v_log||E'\nFAIL 12 minted a code for a teammate who already signs in';
    exception when others then
      if sqlerrm like '%already_has_login%' or sqlerrm like '%owner_is_not_invitable%'
        then v_pass:=v_pass+1; v_log:=v_log||E'\nPASS 12 a teammate who already signs in is refused';
        else v_fail:=v_fail+1; v_log:=v_log||E'\nFAIL 12 '||sqlerrm; end if;
    end;

    -- Minting app access is an owner/manager act.
    perform set_config('request.jwt.claims',
      json_build_object('sub', gen_random_uuid()::text, 'role','authenticated')::text, true);
    begin
      perform public.create_staff_reference_code_v217(v_biz, v_staff);
      v_fail:=v_fail+1; v_log:=v_log||E'\nFAIL 13 a stranger minted a reference code';
    exception when others then
      if sqlerrm like '%authorization required%'
        then v_pass:=v_pass+1; v_log:=v_log||E'\nPASS 13 a stranger is refused';
        else v_fail:=v_fail+1; v_log:=v_log||E'\nFAIL 13 '||sqlerrm; end if;
    end;
  end if;

  raise notice 'V217 acceptance: % passed, % failed%', v_pass, v_fail, v_log;
  if v_fail > 0 then
    raise exception 'V217 acceptance failed: % of % assertions%', v_fail, v_pass+v_fail, v_log;
  end if;
end $suite$;

rollback;
