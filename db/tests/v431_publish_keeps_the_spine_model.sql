-- v431 acceptance — publish_loyalty_config carries the spine-authority block, and no accruing
-- tenant's declared model disagrees with its spine. Read-only against production; BEGIN/ROLLBACK
-- for the house atomic-boundary convention.
begin;

do $$
declare
  v_def text;
  v_drift integer;
begin
  select pg_get_functiondef(p.oid) into v_def
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'publish_loyalty_config';

  -- 01  the re-issued body carries the v431 spine-authority block
  if position('nestly_v431' in coalesce(v_def,'')) = 0 then
    raise exception '01 FAIL publish_loyalty_config does not carry the v431 spine-authority block';
  end if;
  raise notice '01 PASS publish re-imposes the spine model';

  -- 02  no tenant with an accruing spine row disagrees with it in loyalty_programs
  select count(*) into v_drift
    from public.loyalty_programs lp
   where exists (select 1 from public.business_programmes s
                  where s.business_id = lp.business_id and s.kind = 'stamps' and s.active)
     and (lp.loyalty_model is distinct from 'stamps' or lp.kind is distinct from 'stamps');
  if v_drift > 0 then
    raise exception '02 FAIL % tenant(s) declare a non-stamps model over an active stamps spine', v_drift;
  end if;
  select count(*) into v_drift
    from public.loyalty_programs lp
   where exists (select 1 from public.business_programmes s
                  where s.business_id = lp.business_id and s.kind = 'points' and s.active)
     and not exists (select 1 from public.business_programmes s2
                      where s2.business_id = lp.business_id and s2.kind = 'stamps' and s2.active)
     and lp.kind is distinct from 'points';
  if v_drift > 0 then
    raise exception '02 FAIL % tenant(s) declare a non-points kind over an active points spine', v_drift;
  end if;
  raise notice '02 PASS every accruing tenant''s declared model matches its spine';
end $$;

rollback;
select 'v431 ALL CHECKS PASSED' as result;
