-- Rollback-only v267 acceptance: the whole sales-force journey, from every
-- side of the boundary.
--
-- Rules under test (owner, 2026-08-10):
--   a consultant manages ONLY the firms assigned to them — read, write, and
--   the v156 commercial surface alike;
--   ONLY the super admin assigns firms, on both RPC generations;
--   an admin keeps all-scope commercial access but cannot assign.
--
-- Production has no grants and no consultants beyond the roster, so the suite
-- seeds two sales reps, one admin, and two assigned prospects, walks the
-- journey, and rolls everything back.
begin;

do $v267$
declare
  v_sa uuid; v_a uuid; v_b uuid; v_c uuid;
  v_con_a uuid; v_con_b uuid;
  v_company uuid; v_p_a uuid; v_p_b uuid;
  v_ver bigint; d jsonb; pipeline jsonb; created jsonb;
begin
  select user_id into v_sa from public.super_admins limit 1;
  if v_sa is null then raise exception 'no super admin configured'; end if;
  select id into v_a from auth.users where id<>v_sa order by created_at limit 1;
  select id into v_b from auth.users where id not in (v_sa,v_a) order by created_at limit 1;
  select id into v_c from auth.users where id not in (v_sa,v_a,v_b) order by created_at limit 1;
  if v_c is null then raise exception 'need three non-SA logins'; end if;
  if exists (select 1 from public.platform_consultants where user_id in (v_a,v_b,v_c)) then
    raise exception 'chosen logins already consultants; pick unused logins'; end if;

  ---------------------------------------------------------------- seed
  insert into public.platform_consultants(user_id,display_name,tier,employment_started_on,active,created_by)
    values (v_a,'ZZ V267 Sales A','junior',current_date,true,v_sa) returning id into v_con_a;
  insert into public.platform_consultants(user_id,display_name,tier,employment_started_on,active,created_by)
    values (v_b,'ZZ V267 Sales B','junior',current_date,true,v_sa) returning id into v_con_b;
  insert into public.platform_access_grants_v89(user_id,role,module_perms,active,created_by,updated_by)
    values (v_a,'sales_staff',jsonb_build_object('onboarding','rw'),true,v_sa,v_sa),
           (v_b,'sales_staff',jsonb_build_object('onboarding','rw'),true,v_sa,v_sa),
           (v_c,'admin',jsonb_build_object('*','rw'),true,v_sa,v_sa);

  insert into public.sme_companies(legal_name,trading_name,industry)
    values ('ZZ V267 JOURNEY PTE LTD','ZZ V267','fnb') returning id into v_company;
  insert into public.sme_prospects(company_id,legacy_stage_raw,assigned_consultant_id)
    values (v_company,'v267-a',v_con_a) returning id into v_p_a;
  insert into public.sme_prospects(company_id,legacy_stage_raw,assigned_consultant_id)
    values (v_company,'v267-b',v_con_b) returning id into v_p_b;

  ---------------------------------------------------------------- as sales A
  perform set_config('request.jwt.claim.sub',v_a::text,true);
  perform set_config('request.jwt.claims',json_build_object('sub',v_a,'role','authenticated')::text,true);

  -- A. scoped detail: own opens, another book's is refused
  d := public.platform_get_my_prospect_v89(v_p_a);
  if d#>>'{prospect,id}' <> v_p_a::text then raise exception 'A: own detail wrong'; end if;
  begin
    perform public.platform_get_my_prospect_v89(v_p_b);
    raise exception 'A: sales read another book''s detail';
  exception when sqlstate '42501' then null; end;

  -- B. scoped stage move: own moves, another book's is refused BEFORE any
  --    version check runs (the gate must come first)
  select version into v_ver from public.sme_prospects where id=v_p_a;
  perform public.platform_move_my_prospect_stage_v89(v_p_a,'appt_set',v_ver,'v267 own move');
  begin
    perform public.platform_move_my_prospect_stage_v89(v_p_b,'appt_set',1,'v267 foreign move');
    raise exception 'B: sales moved another book''s firm';
  exception when sqlstate '42501' then null; end;

  -- C. sales cannot assign, on either RPC generation
  begin
    perform public.platform_assign_prospect_v89(v_p_a,v_con_b,'grab');
    raise exception 'C: sales assigned via v89';
  exception when sqlstate '42501' then null; end;
  begin
    perform public.platform_assign_prospect_v76(v_p_a,v_con_b,1,'v267-x1');
    raise exception 'C: sales assigned via v76';
  exception when sqlstate '42501' then null; end;

  -- D. the v156 hole is closed: onboarding:rw no longer reaches a foreign
  --    prospect through the commercial helper; the rep's own firm still works.
  --    This tests the helper all seven v156 callers share.
  if app.v156_can_prospect(v_p_b,'rw') then
    raise exception 'D: v156_can_prospect still passes on a foreign prospect'; end if;
  if not app.v156_can_prospect(v_p_a,'rw') then
    raise exception 'D: v156_can_prospect refused the sales rep''s own firm'; end if;

  -- E. a self-created prospect self-assigns and lands on the creator's board,
  --    so nothing a rep creates can vanish from their own pipeline
  created := public.platform_create_my_prospect_v89('ZZ V267 SELFMADE','fnb','+65 8000 0009',null,'Ms Tan');
  pipeline := public.platform_crm_pipeline_v226(p_search=>'ZZ V267 SELFMADE');
  if (pipeline->>'total_count')::bigint <> 1 then
    raise exception 'E: self-created firm missing from own pipeline (%)',pipeline->>'total_count'; end if;

  ---------------------------------------------------------------- as ADMIN
  perform set_config('request.jwt.claim.sub',v_c::text,true);
  perform set_config('request.jwt.claims',json_build_object('sub',v_c,'role','authenticated')::text,true);

  -- F. an admin keeps all-scope commercial access, but may NOT assign
  if not app.v156_can_prospect(v_p_b,'rw') then
    raise exception 'F: admin lost commercial access'; end if;
  begin
    perform public.platform_assign_prospect_v89(v_p_a,v_con_b,'admin grab');
    raise exception 'F: an ADMIN assigned a firm — owner rule violated';
  exception when sqlstate '42501' then null; end;
  begin
    select version into v_ver from public.sme_prospects where id=v_p_a;
    perform public.platform_assign_prospect_v76(v_p_a,v_con_b,v_ver,'v267-x2');
    raise exception 'F: an ADMIN assigned via v76';
  exception when sqlstate '42501' then null; end;

  ---------------------------------------------------------------- as SUPER ADMIN
  perform set_config('request.jwt.claim.sub',v_sa::text,true);
  perform set_config('request.jwt.claims',json_build_object('sub',v_sa,'role','authenticated')::text,true);

  -- G. the super admin assigns on both generations, and the firm moves books
  d := public.platform_assign_prospect_v89(v_p_a,v_con_b,'v267 SA reassign');
  if d->>'assigned_consultant_id' <> v_con_b::text then raise exception 'G: v89 assign failed'; end if;
  select version into v_ver from public.sme_prospects where id=v_p_b;
  d := public.platform_assign_prospect_v76(v_p_b,v_con_a,v_ver,'v267-sa-1');
  if (d->>'replayed')::boolean is not false then raise exception 'G: v76 assign failed'; end if;

  -- H. after the reassign, the old rep's access is gone immediately
  perform set_config('request.jwt.claim.sub',v_a::text,true);
  perform set_config('request.jwt.claims',json_build_object('sub',v_a,'role','authenticated')::text,true);
  begin
    perform public.platform_get_my_prospect_v89(v_p_a);
    raise exception 'H: sales kept access after the firm was reassigned away';
  exception when sqlstate '42501' then null; end;

  raise notice 'v267 salesforce journey: all assertions passed';
end $v267$;

rollback;
