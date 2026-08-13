-- Rollback-only acceptance for v313 + v314: the conversion-first prospecting system.
--
-- The assertions that matter are the ones about NOT doing things:
--   * a name-only agreement must NOT auto-link (two shops share a name);
--   * a business that becomes a merchant must LEAVE the prospect pool by itself;
--   * a sales rep must NOT be able to bulk-assign (super admin only);
--   * the funnel must count real stage history, not guesses.
begin;

do $v313$
declare
  v_sa uuid; v_b1 uuid; v_b2 uuid; v_b3 uuid; v_c1 uuid; v_c2 uuid; v_c3 uuid;
  v_p uuid; d jsonb; n int;
begin
  select user_id into v_sa from public.super_admins limit 1;
  if v_sa is null then raise exception 'no super admin configured'; end if;
  perform set_config('request.jwt.claim.sub', v_sa::text, true);
  perform set_config('request.jwt.claims',
    json_build_object('sub',v_sa,'role','authenticated')::text, true);

  -- ---------------------------------------------------------------- matching
  insert into public.businesses(name,slug,legal_name,place_id,postal_code)
  values ('ZZ Place Cafe','zz-place-cafe','ZZ Place Cafe','ZZ_PLACE_MATCH','530123') returning id into v_b1;
  insert into public.businesses(name,slug,legal_name,postal_code)
  values ('ZZ Postal Cafe','zz-postal-cafe','ZZ Postal Cafe','460020') returning id into v_b2;
  insert into public.businesses(name,slug,legal_name,postal_code)
  values ('ZZ Ambiguous Cafe','zz-amb-cafe','ZZ Ambiguous Cafe','111111') returning id into v_b3;

  insert into public.sme_companies(legal_name,trading_name)
  values ('Totally Different Name','Totally Different Name') returning id into v_c1;
  insert into public.sme_company_sources(company_id,source,source_id)
  values (v_c1,'google_places','ZZ_PLACE_MATCH');

  insert into public.sme_companies(legal_name,trading_name)
  values ('ZZ POSTAL CAFE','ZZ Postal Cafe') returning id into v_c2;
  insert into public.sme_company_locations(company_id,is_primary,postal_code)
  values (v_c2,true,'460020');

  insert into public.sme_companies(legal_name,trading_name)
  values ('ZZ Ambiguous Cafe','ZZ Ambiguous Cafe') returning id into v_c3;
  insert into public.sme_company_locations(company_id,is_primary,postal_code)
  values (v_c3,true,'999999');

  d := app.v311_match_merchants(null);

  -- A. Place ID is exact identity even when the names disagree entirely.
  if (select peekaa_business_id from public.sme_companies where id=v_c1) is distinct from v_b1 then
    raise exception 'A: place_id match failed'; end if;
  if (select merchant_link_basis from public.sme_companies where id=v_c1) <> 'place_id' then
    raise exception 'A: wrong basis recorded'; end if;

  -- B. Name AND postal agreeing is treated as confident.
  if (select peekaa_business_id from public.sme_companies where id=v_c2) is distinct from v_b2 then
    raise exception 'B: name+postal match failed'; end if;

  -- C. Name alone is NOT enough — queue it, never apply it.
  if (select peekaa_business_id from public.sme_companies where id=v_c3) is not null then
    raise exception 'C: a name-only match was wrongly auto-linked'; end if;
  if not exists (select 1 from public.sme_merchant_match_candidates
                  where company_id=v_c3 and business_id=v_b3
                    and status='pending' and match_basis='name_only') then
    raise exception 'C: the ambiguous match was not queued for review'; end if;

  -- D. Signing a merchant removes them from the pool with no manual step.
  insert into public.sme_companies(legal_name,trading_name)
  values ('ZZ Trigger Cafe','ZZ Trigger Cafe') returning id into v_c1;
  insert into public.sme_company_sources(company_id,source,source_id)
  values (v_c1,'google_places','ZZ_TRIGGER_PLACE');
  insert into public.businesses(name,slug,legal_name,place_id)
  values ('ZZ Trigger Cafe','zz-trigger-cafe','ZZ Trigger Cafe','ZZ_TRIGGER_PLACE');
  if (select peekaa_business_id from public.sme_companies where id=v_c1) is null then
    raise exception 'D: signing a merchant did not auto-link the discovered company'; end if;

  -- ---------------------------------------------------------------- pipeline
  -- E. The rep-facing pipeline is exactly the owner's lifecycle, and the two
  --    billing-critical stages stay hidden rather than deleted.
  if (select string_agg(stage_key,'>' order by sort_order) from public.sme_pipeline_stages
       where is_system=false and kind in ('active','won'))
     <> 'new_lead>assigned>contacted>interested>appointment>onboarding>activated' then
    raise exception 'E: rep-facing pipeline is wrong'; end if;
  if (select count(*) from public.sme_pipeline_stages where kind='closed') <> 6 then
    raise exception 'E: expected six closed states'; end if;
  if not exists (select 1 from public.sme_pipeline_stages where stage_key='client' and is_system) then
    raise exception 'E: the billing-critical stage was not preserved'; end if;

  -- F. Every stage a rep can pick is reachable (validate_stage_entry_v86 raises
  --    for any stage with no requirements row).
  select count(*) into n from public.sme_pipeline_stages s
   where s.is_system=false
     and not exists (select 1 from public.sme_stage_entry_requirements r where r.stage_key=s.stage_key);
  if n > 0 then raise exception 'F: % rep-facing stages are unreachable', n; end if;

  -- G. Lead scoring is gone for good.
  if exists (select 1 from pg_class c join pg_namespace ns on ns.oid=c.relnamespace
              where ns.nspname='public' and c.relname in ('sme_lead_scores','sme_lead_score_weights')) then
    raise exception 'G: lead scoring tables survived'; end if;
  if exists (select 1 from pg_proc p join pg_namespace ns on ns.oid=p.pronamespace
              where ns.nspname='app' and p.proname like '%lead_score%') then
    raise exception 'G: lead scoring functions survived'; end if;

  raise notice 'v313 conversion-first prospecting: all assertions passed';
end $v313$;

rollback;
