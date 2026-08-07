-- Rollback-only v226 acceptance: the server, not the client, decides whose
-- firms a CRM caller can see.
--
-- Production has no platform access grants and no assigned prospects, so the
-- whole point of this module — one consultant's book being invisible to
-- another — cannot be observed against live rows. The suite seeds two
-- consultants, two logins and three prospects, proves the boundary from both
-- sides, and rolls everything back.
begin;

do $v226$
declare
  v_sa uuid; v_user_a uuid; v_user_b uuid; v_user_c uuid;
  v_con_a uuid; v_con_b uuid;
  v_company uuid; v_p_a uuid; v_p_b uuid; v_p_none uuid;
  a jsonb; b jsonb; all_scope jsonb;
begin
  select user_id into v_sa from public.super_admins limit 1;
  if v_sa is null then raise exception 'no super admin configured'; end if;
  select id into v_user_a from auth.users where id <> v_sa order by created_at limit 1;
  select id into v_user_b from auth.users where id not in (v_sa, v_user_a) order by created_at limit 1;
  select id into v_user_c from auth.users where id not in (v_sa, v_user_a, v_user_b) order by created_at limit 1;
  if v_user_a is null or v_user_b is null or v_user_c is null then
    raise exception 'need three non-super-admin logins to prove the boundary';
  end if;
  -- These logins must not already be consultants, or the seeded rows collide
  -- with the live roster on the UNIQUE(user_id) constraint.
  if exists (select 1 from public.platform_consultants
              where user_id in (v_user_a, v_user_b, v_user_c)) then
    raise exception 'chosen logins are already consultants; pick unused logins';
  end if;

  ---------------------------------------------------------------- seed
  insert into public.platform_consultants(user_id, display_name, tier, employment_started_on, active, created_by)
    values (v_user_a,'ZZ Consultant A','junior',current_date,true,v_sa) returning id into v_con_a;
  insert into public.platform_consultants(user_id, display_name, tier, employment_started_on, active, created_by)
    values (v_user_b,'ZZ Consultant B','junior',current_date,true,v_sa) returning id into v_con_b;

  -- Three logins hold the consultant role. C deliberately has NO consultant
  -- record, which is the fail-closed case asserted in G.
  insert into public.platform_access_grants_v89(user_id, role, module_perms, active, created_by, updated_by)
    values (v_user_a,'sales_staff',jsonb_build_object('onboarding','rw'),true,v_sa,v_sa),
           (v_user_b,'sales_staff',jsonb_build_object('onboarding','rw'),true,v_sa,v_sa),
           (v_user_c,'sales_staff',jsonb_build_object('onboarding','rw'),true,v_sa,v_sa);

  insert into public.sme_companies(legal_name, trading_name, industry)
    values ('ZZ V226 ACCEPTANCE PTE LTD','ZZ V226','cafe') returning id into v_company;
  insert into public.sme_prospects(company_id, legacy_stage_raw, assigned_consultant_id)
    values (v_company,'v226-a',v_con_a) returning id into v_p_a;
  insert into public.sme_prospects(company_id, legacy_stage_raw, assigned_consultant_id)
    values (v_company,'v226-b',v_con_b) returning id into v_p_b;
  insert into public.sme_prospects(company_id, legacy_stage_raw, assigned_consultant_id)
    values (v_company,'v226-none',null) returning id into v_p_none;

  ---------------------------------------------------------------- A. consultant sees only their own book
  perform set_config('request.jwt.claim.sub', v_user_a::text, true);
  perform set_config('request.jwt.claims',
    json_build_object('sub',v_user_a,'role','authenticated')::text, true);
  a := public.platform_crm_pipeline_v226();

  if a->>'scope' <> 'own' then
    raise exception 'A: a consultant must be scoped to own, got %', a->>'scope';
  end if;
  if exists (select 1 from jsonb_array_elements(a->'items') i
              where i->>'id' in (v_p_b::text, v_p_none::text)) then
    raise exception 'A: a consultant read a firm that is not assigned to them';
  end if;
  if not exists (select 1 from jsonb_array_elements(a->'items') i
                  where i->>'id' = v_p_a::text) then
    raise exception 'A: a consultant cannot see their own assigned firm';
  end if;

  ---------------------------------------------------------------- B. omitting the filter must not widen the scope
  -- This is the failure mode the old reader had: p_consultant was a filter, so
  -- leaving it out returned everything.
  if (a->>'total_count')::bigint <> 1 then
    raise exception 'B: omitting p_consultant widened a consultant scope to % rows',
      a->>'total_count';
  end if;

  ---------------------------------------------------------------- C. asking for someone else's book is refused
  begin
    perform public.platform_crm_pipeline_v226(p_consultant => v_con_b);
    raise exception 'C: a consultant read another consultant''s book';
  exception when sqlstate '42501' then null;
  end;
  -- Passing their OWN id is allowed — it is the same book, stated explicitly.
  if (public.platform_crm_pipeline_v226(p_consultant => v_con_a)->>'total_count')::bigint <> 1 then
    raise exception 'C: a consultant naming their own id was refused their own book';
  end if;

  ---------------------------------------------------------------- D. facets never leak other books
  if jsonb_array_length(a->'consultants') <> 0 then
    raise exception 'D: a consultant was shown the roster of other books';
  end if;
  if (select coalesce(sum((s->>'n')::bigint),0) from jsonb_array_elements(a->'stages') s) > 1 then
    raise exception 'D: stage facets counted firms outside the consultant scope';
  end if;

  ---------------------------------------------------------------- E. the boundary holds from the other side
  perform set_config('request.jwt.claim.sub', v_user_b::text, true);
  perform set_config('request.jwt.claims',
    json_build_object('sub',v_user_b,'role','authenticated')::text, true);
  b := public.platform_crm_pipeline_v226();
  if exists (select 1 from jsonb_array_elements(b->'items') i
              where i->>'id' = v_p_a::text) then
    raise exception 'E: consultant B read consultant A''s firm';
  end if;

  ---------------------------------------------------------------- F. a departed consultant loses the book
  update public.platform_consultants set active=false, departed_at=now() where id=v_con_b;
  b := public.platform_crm_pipeline_v226();
  if (b->>'consultant_unlinked')::boolean is not true then
    raise exception 'F: a deactivated consultant was not unlinked';
  end if;
  if jsonb_array_length(b->'items') <> 0 then
    raise exception 'F: a deactivated consultant still read % firms',
      jsonb_array_length(b->'items');
  end if;
  update public.platform_consultants set active=true, departed_at=null where id=v_con_b;

  ---------------------------------------------------------------- G. an unlinked sales_staff sees nothing, not everything
  perform set_config('request.jwt.claim.sub', v_user_c::text, true);
  perform set_config('request.jwt.claims',
    json_build_object('sub',v_user_c,'role','authenticated')::text, true);
  b := public.platform_crm_pipeline_v226();
  if (b->>'consultant_unlinked')::boolean is not true
     or (b->>'total_count')::bigint <> 0
     or jsonb_array_length(b->'items') <> 0 then
    raise exception 'G: a sales_staff with no consultant record did not fail closed (% rows)',
      b->>'total_count';
  end if;

  ---------------------------------------------------------------- H. super admin sees every book and can filter
  perform set_config('request.jwt.claim.sub', v_sa::text, true);
  perform set_config('request.jwt.claims',
    json_build_object('sub',v_sa,'role','authenticated')::text, true);
  all_scope := public.platform_crm_pipeline_v226(p_search => 'ZZ V226');

  if all_scope->>'scope' <> 'all' then
    raise exception 'H: a super admin must have all scope, got %', all_scope->>'scope';
  end if;
  if (all_scope->>'total_count')::bigint <> 3 then
    raise exception 'H: a super admin saw % of the 3 seeded firms', all_scope->>'total_count';
  end if;
  if jsonb_array_length(all_scope->'consultants') < 2 then
    raise exception 'H: a super admin was not offered the consultant filter';
  end if;
  if (public.platform_crm_pipeline_v226(p_search=>'ZZ V226',p_consultant=>v_con_a)->>'total_count')::bigint <> 1 then
    raise exception 'H: the super admin consultant filter did not narrow the pipeline';
  end if;

  ---------------------------------------------------------------- I. cards carry what the AI report action needs
  if not exists (select 1 from jsonb_array_elements(all_scope->'items') i
                  where i ? 'can_request_ai_report' and i ? 'converted_business_id') then
    raise exception 'I: cards do not carry the fields the AI report action depends on';
  end if;
  -- Nothing seeded here is converted, so nothing may claim it can be reported on.
  if exists (select 1 from jsonb_array_elements(all_scope->'items') i
              where (i->>'can_request_ai_report')::boolean
                and i->>'converted_business_id' is null) then
    raise exception 'I: an unconverted firm offered an AI report';
  end if;

  ---------------------------------------------------------------- J. no platform access at all is refused
  delete from public.platform_access_grants_v89 where user_id in (v_user_a, v_user_b, v_user_c);
  perform set_config('request.jwt.claim.sub', v_user_a::text, true);
  perform set_config('request.jwt.claims',
    json_build_object('sub',v_user_a,'role','authenticated')::text, true);
  begin
    perform public.platform_crm_pipeline_v226();
    raise exception 'J: a login with no platform grant read the CRM';
  exception when sqlstate '42501' then null;
  end;

  raise notice 'v226 CRM consultant scope: all assertions passed';
end $v226$;

rollback;
