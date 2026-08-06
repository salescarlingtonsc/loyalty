-- Rollback-only v180 acceptance: JSON null filters no longer hide the firm
-- directory. Runs the exact payload the platform console sends.
begin;

do $v180t$
declare
  v_sa uuid;
  v_null_payload jsonb := '{"search":null,"sector":null,"lane":null,"attention_severity":null,"attention_due":null}';
  v_res jsonb;
  v_total int;
  v_due_total int;
begin
  select user_id into v_sa from public.super_admins limit 1;
  if v_sa is null then
    raise exception 'no super admin in prod';
  end if;
  perform set_config('request.jwt.claim.sub', v_sa::text, true);
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_sa, 'role', 'authenticated')::text, true);

  -- The console's real payload (all-null keys) must return every firm.
  v_res := public.platform_list_firm_onboarding_v88(v_null_payload, null, 50, null, null);
  v_total := (v_res->>'total_count')::int;
  if v_total < 1 then
    raise exception 'null-key payload still hides firms: total=%', v_total;
  end if;
  if v_total <> (select count(*) from app.platform_firm_rows_v88(clock_timestamp())) then
    raise exception 'null-key payload total % does not match unfiltered rows', v_total;
  end if;

  -- A real boolean filter still filters.
  v_res := public.platform_list_firm_onboarding_v88(
    v_null_payload || '{"attention_due":true}', null, 50, null, null);
  v_due_total := (v_res->>'total_count')::int;
  if v_due_total > v_total then
    raise exception 'attention_due=true returned more rows than unfiltered';
  end if;

  -- Unknown keys still fail closed.
  begin
    perform public.platform_list_firm_onboarding_v88('{"bogus":1}', null, 50, null, null);
    raise exception 'unknown filter key was accepted';
  exception when others then
    if sqlerrm like '%unknown filter key was accepted%' then raise; end if;
  end;

  raise notice 'v180: null-filter fix verified (total=%, due=%)', v_total, v_due_total;
end
$v180t$;

rollback;
