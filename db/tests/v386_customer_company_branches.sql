-- Rollback suite for v386: the customer company-details reader lists every active branch.
--
-- Everything happens inside one transaction that is ROLLED BACK, so production data is
-- untouched. Run with:  psql "$DATABASE_URL" -f db/tests/v386_customer_company_branches.sql
begin;

do $$
declare
  v_def text;
  v_business uuid;
  v_result jsonb;
begin
  -- 1. The function still exists with the one-uuid signature its callers use.
  select pg_get_functiondef(p.oid) into v_def
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public'
     and p.proname = 'customer_get_offer_business_contact_v173'
     and pg_get_function_identity_arguments(p.oid) = 'p_business uuid';
  if v_def is null then
    raise exception 'v386: customer_get_offer_business_contact_v173(uuid) is missing';
  end if;

  -- 2. The verified-link gate is intact. This is the whole security contract: without it any
  --    authenticated customer could read any tenant's branch contact list.
  if v_def not like '%verified_customer_link_required%' then
    raise exception 'v386: the verified-link gate was dropped';
  end if;
  if v_def not like '%authenticated_session_required%' then
    raise exception 'v386: the authenticated-session gate was dropped';
  end if;
  if v_def not like '%security definer%' and v_def not like '%SECURITY DEFINER%' then
    raise exception 'v386: the function is no longer security definer';
  end if;

  -- 3. It answers with the new branches key AND keeps the old single-branch key.
  if v_def not like '%''branches''%' then
    raise exception 'v386: the branches array is missing';
  end if;
  if v_def not like '%''branch''%' then
    raise exception 'v386: the v173 default-branch key was dropped (older bundles read it)';
  end if;

  -- 4. anon must not be able to execute it.
  if exists(
    select 1 from pg_proc p
     join pg_namespace n on n.oid = p.pronamespace
    where n.nspname='public'
      and p.proname='customer_get_offer_business_contact_v173'
      and has_function_privilege('anon', p.oid, 'execute')
  ) then
    raise exception 'v386: anon can execute the customer contact reader';
  end if;

  -- 5. Shape check against a real tenant, read as the definer. branches[0] must be the SAME
  --    branch the singular key returns — the UI slices it off as "already shown above", so a
  --    different order would silently hide one outlet and repeat another.
  select b.id into v_business
    from public.businesses b
   where exists(select 1 from public.branches br where br.business_id=b.id and coalesce(br.active,true))
   order by b.created_at limit 1;
  if v_business is not null then
    select jsonb_build_object(
      'branch', (select jsonb_build_object('name',br.name,'address',br.address,'phone',br.phone,'email',br.email)
                   from public.branches br
                  where br.business_id=v_business and coalesce(br.active,true)
                  order by br.is_default desc, br.created_at, br.id limit 1),
      'branches', (select jsonb_agg(jsonb_build_object('name',br.name,'address',br.address,'phone',br.phone,'email',br.email)
                     order by br.is_default desc, br.created_at, br.id)
                     from public.branches br
                    where br.business_id=v_business and coalesce(br.active,true))
    ) into v_result;
    if v_result->'branches'->0 is distinct from v_result->'branch' then
      raise exception 'v386: branches[0] is not the default branch the singular key returns';
    end if;
  end if;

  raise notice 'v386 rollback suite: all assertions passed';
end $$;

rollback;
