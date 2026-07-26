-- Rollback-only v85 polymorphic conversion-guard regression suite.
-- Proves ordinary businesses updates work, converted business identity remains
-- protected, and branch activation is checked only on a branches trigger row.
begin;
\ir fixtures/pristine_chain_fixture.psql

do $v85_test$
declare
  v_business uuid;
  v_other_business uuid;
  v_company uuid;
  v_prospect uuid;
  v_converted_branch uuid;
  v_ordinary_branch uuid;
  v_before timestamptz;
begin
  reset role;
  select business.id, business.created_at
    into v_business, v_before
    from public.businesses business
   order by business.created_at, business.id
   limit 1;
  select business.id
    into v_other_business
    from public.businesses business
   where business.id <> v_business
   order by business.created_at, business.id
   limit 1;
  if v_business is null or v_other_business is null then
    raise exception 'v85 suite requires two pristine businesses';
  end if;

  -- This was the exact v79 failure: a businesses row has no OLD.active field.
  update public.businesses
     set created_at = created_at + interval '1 second'
   where id = v_business;
  if (select created_at from public.businesses where id = v_business)
       is distinct from v_before + interval '1 second' then
    raise exception 'ordinary businesses update did not complete';
  end if;

  insert into public.sme_companies(legal_name, trading_name, industry)
  values('V85 Converted Company Pte Ltd', 'V85 Converted', 'test')
  returning id into v_company;
  insert into public.sme_prospects(company_id, current_stage_key)
  values(v_company, 'client')
  returning id into v_prospect;

  perform set_config('app.v79_system_transition', 'on', true);
  update public.businesses
     set source_prospect_id = v_prospect,
         onboarding_started_at = now(),
         legal_name = 'V85 Converted Company Pte Ltd'
   where id = v_business;
  perform set_config('app.v79_system_transition', '', true);

  -- Non-controlled business fields remain editable after conversion.
  update public.businesses
     set name = name || ' refreshed'
   where id = v_business;

  begin
    update public.businesses
       set legal_name = 'Unauthorized restatement'
     where id = v_business;
    raise exception 'converted business identity update unexpectedly succeeded';
  exception when insufficient_privilege then null;
  end;

  select branch.id into v_converted_branch
    from public.branches branch
   where branch.business_id = v_business
   order by branch.is_default desc, branch.created_at, branch.id
   limit 1;
  select branch.id into v_ordinary_branch
    from public.branches branch
   where branch.business_id = v_other_business
   order by branch.is_default desc, branch.created_at, branch.id
   limit 1;
  if v_converted_branch is null or v_ordinary_branch is null then
    raise exception 'v85 suite requires one branch in each fixture business';
  end if;

  update public.branches set active = false where id = v_converted_branch;
  begin
    update public.branches set active = true where id = v_converted_branch;
    raise exception 'converted branch activation unexpectedly succeeded';
  exception when insufficient_privilege then null;
  end;
  if (select active from public.branches where id = v_converted_branch) then
    raise exception 'converted branch activation was not rolled back';
  end if;

  update public.branches set active = false where id = v_ordinary_branch;
  update public.branches set active = true where id = v_ordinary_branch;
  if not (select active from public.branches where id = v_ordinary_branch) then
    raise exception 'ordinary branch activation was incorrectly blocked';
  end if;
end
$v85_test$;

rollback;
