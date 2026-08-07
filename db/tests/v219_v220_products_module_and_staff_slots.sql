-- v219 + v220 acceptance. Rolled back at the end. Checked-in form of the chains run against
-- production before shipping (6/6 and 5/5 + 2/2).
-- Set v219.business (a services tenant), v219.products_business and v219.owner.

begin;

do $suite$
declare
  v_biz uuid := current_setting('v219.business', true)::uuid;
  v_prod_biz uuid := current_setting('v219.products_business', true)::uuid;
  v_owner uuid; v_branch uuid; v_mods jsonb; v_mode text; v_src text;
  v_a uuid; v_b uuid; v_start timestamptz; v_n int; v_others int; v_with int;
  v_pass int := 0; v_fail int := 0; v_log text := '';
begin
  if v_biz is null then raise exception 'set v219.business and v219.owner'; end if;

  -- === v219: Products follows the business's own entitlement ===
  select s.user_id into v_owner from public.staff s
  where s.business_id=v_biz and s.role='owner' and s.active limit 1;
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_owner::text, 'role','authenticated')::text, true);
  perform set_config('role','authenticated', true);

  v_mods := to_jsonb(public.get_my_modules(v_biz))->'modules';
  if v_mods ? 'inventory'
    then v_pass:=v_pass+1; v_log:=v_log||E'\nPASS 1  the owner now has the Products module';
    else v_fail:=v_fail+1; v_log:=v_log||E'\nFAIL 1  '||v_mods::text; end if;
  -- customerintel is platform-only and must stay withheld.
  if not (v_mods ? 'customerintel')
    then v_pass:=v_pass+1; v_log:=v_log||E'\nPASS 2  customerintel stays platform-only';
    else v_fail:=v_fail+1; v_log:=v_log||E'\nFAIL 2  customerintel leaked in'; end if;

  if v_prod_biz is not null then
    perform set_config('role','postgres', true);
    select s.user_id into v_owner from public.staff s
    where s.business_id=v_prod_biz and s.role='owner' and s.active limit 1;
    perform set_config('request.jwt.claims',
      json_build_object('sub', v_owner::text, 'role','authenticated')::text, true);
    perform set_config('role','authenticated', true);
    v_mods := to_jsonb(public.get_my_modules(v_prod_biz))->'modules';
    if v_mods ? 'inventory'
      then v_pass:=v_pass+1; v_log:=v_log||E'\nPASS 3  a products tenant can manage what it already sells';
      else v_fail:=v_fail+1; v_log:=v_log||E'\nFAIL 3  '||v_mods::text; end if;
  end if;

  -- A platform operator can still withhold it per firm, and per branch.
  perform set_config('role','postgres', true);
  insert into public.platform_module_overrides_v94(business_id,branch_scope,module_key,mode,reason)
  values (v_biz,null,'inventory','disabled','v219 acceptance');
  select resolved.mode, resolved.source into v_mode, v_src
  from app.effective_platform_module_mode_v94(v_biz,null,'inventory') resolved;
  if v_mode='disabled' and v_src='firm_override'
    then v_pass:=v_pass+1; v_log:=v_log||E'\nPASS 4  a firm override can still withhold products';
    else v_fail:=v_fail+1; v_log:=v_log||E'\nFAIL 4  '||coalesce(v_mode,'null')||'/'||coalesce(v_src,'null'); end if;

  select id into v_branch from public.branches where business_id=v_biz and active order by name limit 1;
  insert into public.platform_module_overrides_v94(business_id,branch_scope,module_key,mode,reason)
  values (v_biz,v_branch,'inventory','rw','v219 acceptance');
  select resolved.mode, resolved.source into v_mode, v_src
  from app.effective_platform_module_mode_v94(v_biz,v_branch,'inventory') resolved;
  if v_mode='rw' and v_src='branch_override'
    then v_pass:=v_pass+1; v_log:=v_log||E'\nPASS 5  a branch override still beats the firm setting';
    else v_fail:=v_fail+1; v_log:=v_log||E'\nFAIL 5  '||coalesce(v_mode,'null')||'/'||coalesce(v_src,'null'); end if;

  delete from public.platform_module_overrides_v94 where business_id=v_biz and module_key='inventory';
  select resolved.mode, resolved.source into v_mode, v_src
  from app.effective_platform_module_mode_v94(v_biz,null,'inventory') resolved;
  if v_mode='rw' and v_src='sector_entitlement'
    then v_pass:=v_pass+1; v_log:=v_log||E'\nPASS 6  with no override it follows the business own entitlement';
    else v_fail:=v_fail+1; v_log:=v_log||E'\nFAIL 6  '||coalesce(v_mode,'null')||'/'||coalesce(v_src,'null'); end if;

  -- === v220: suggested TIMES belong to the chosen teammate ===
  select s.user_id into v_owner from public.staff s
  where s.business_id=v_biz and s.role='owner' and s.active limit 1;
  select id into v_branch from public.branches where business_id=v_biz and active order by name limit 1;
  select id into v_a from public.staff where business_id=v_biz and active and role<>'owner' order by created_at limit 1;
  select id into v_b from public.staff where business_id=v_biz and active and role<>'owner' and id<>v_a order by created_at limit 1;
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_owner::text, 'role','authenticated')::text, true);
  perform set_config('role','authenticated', true);

  -- Walk forward to a time where somebody is genuinely free, so the comparison is meaningful.
  for v_n in 0..40 loop
    v_start := (date_trunc('day', now() at time zone 'Asia/Singapore') + interval '3 days'
                + interval '10 hours' + (v_n * interval '15 minutes')) at time zone 'Asia/Singapore';
    select jsonb_array_length(public.suggest_appointment_staff_v47(
      v_biz,v_branch,null,v_start,60,5,30,null)->'available_staff') into v_n;
    exit when v_n > 0;
  end loop;

  select count(*) into v_others from jsonb_array_elements(public.suggest_appointment_staff_v47(
    v_biz,v_branch,null,v_start,60,5,30,v_a)->'next_best_slots') slot
  where (slot->>'staff_id')::uuid <> v_a;
  if v_others=0
    then v_pass:=v_pass+1; v_log:=v_log||E'\nPASS 7  with a teammate chosen, no other teammate''s times are offered';
    else v_fail:=v_fail+1; v_log:=v_log||E'\nFAIL 7  '||v_others||' foreign slots'; end if;

  if v_b is not null then
    select count(*) into v_others from jsonb_array_elements(public.suggest_appointment_staff_v47(
      v_biz,v_branch,null,v_start,60,5,30,v_b)->'next_best_slots') slot
    where (slot->>'staff_id')::uuid <> v_b;
    if v_others=0
      then v_pass:=v_pass+1; v_log:=v_log||E'\nPASS 8  and the same holds for a different teammate';
      else v_fail:=v_fail+1; v_log:=v_log||E'\nFAIL 8  '||v_others||' foreign slots'; end if;
  end if;

  -- available_staff must NOT be filtered — switching to whoever is free is the other way out
  -- of a clash, and filtering it would remove that.
  select jsonb_array_length(public.suggest_appointment_staff_v47(
    v_biz,v_branch,null,v_start,60,5,30,v_a)->'available_staff') into v_with;
  select jsonb_array_length(public.suggest_appointment_staff_v47(
    v_biz,v_branch,null,v_start,60,5,30,null)->'available_staff') into v_n;
  if v_with = v_n
    then v_pass:=v_pass+1; v_log:=v_log||E'\nPASS 9  the free-staff list is unfiltered ('||v_with||' either way)';
    else v_fail:=v_fail+1; v_log:=v_log||E'\nFAIL 9  '||v_n||' vs '||v_with; end if;

  -- Every existing six-argument caller must be untouched.
  if jsonb_typeof(public.suggest_appointment_staff_v47(v_biz,v_branch,null,v_start,60,5)->'available_staff')='array'
    then v_pass:=v_pass+1; v_log:=v_log||E'\nPASS 10 the older call signature still works';
    else v_fail:=v_fail+1; v_log:=v_log||E'\nFAIL 10 older signature broke'; end if;

  raise notice 'V219/V220 acceptance: % passed, % failed%', v_pass, v_fail, v_log;
  if v_fail > 0 then
    raise exception 'V219/V220 acceptance failed: % of %%', v_fail, v_pass+v_fail, v_log;
  end if;
end $suite$;

rollback;
