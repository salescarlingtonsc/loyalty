-- nestly_v316_repair_taxonomy_and_match_queue
--
-- Two failures the v315 sweep did not catch.
--
-- 1. platform_crm_prospecting_taxonomy_v297 still built a 'score_weights' key
--    from public.sme_lead_score_weights, dropped in v313. This is the FIRST
--    call the Prospecting route makes, so the entire route rendered
--    "Prospecting unavailable" — the console was never at fault.
--
--    The v315 residual scan missed it because it searched for the literal
--    'sme_lead_scores', and the surviving reference is 'sme_lead_score_weights'
--    — a different string that pattern cannot match. A guard is only as good as
--    its pattern. db/tests/v315_lead_score_reference_repair.sql now matches
--    '%lead_score%' so any member of the family is caught.
--
-- 2. platform_merchant_matches_v312 ordered a jsonb_agg by a bare column
--    outside the aggregate, which Postgres rejects at run time. It was never
--    exercised: an earlier probe called it inside a block whose result set was
--    not returned, so the failure stayed invisible. Ordering now sits inside
--    the aggregate.

begin;

do $repair_taxonomy$
declare parts text[]; i int; j int; d text;
begin
  select string_to_array(pg_get_functiondef(p.oid), E'\n') into parts
    from pg_proc p join pg_namespace n on n.oid=p.pronamespace
   where n.nspname='public' and p.proname='platform_crm_prospecting_taxonomy_v297';

  i := null;
  for j in 1..array_length(parts,1) loop
    if parts[j] like '%''score_weights'', coalesce(%' then i := j; exit; end if;
  end loop;
  if i is null then raise exception 'taxonomy repair: score_weights key not found'; end if;
  if parts[i+2] not like '%sme_lead_score_weights%' then
    raise exception 'taxonomy repair: unexpected shape at line %', i+2;
  end if;

  -- The key is the LAST entry of the jsonb_build_object, so the preceding
  -- line's trailing comma goes with it.
  parts[i-1] := regexp_replace(parts[i-1], ',\s*$', '');
  parts := parts[1:i-1] || parts[i+3:array_length(parts,1)];
  d := array_to_string(parts, E'\n');

  if d like '%lead_score%' then
    raise exception 'taxonomy repair failed: a lead_score reference survived';
  end if;
  execute d;
end $repair_taxonomy$;

create or replace function public.platform_merchant_matches_v312(p_limit integer default 50)
returns jsonb
language plpgsql
stable security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $function$
begin
  perform app.v297_assert_prospecting('r');
  if not (app.is_super_admin() or app.v89_platform_role()='admin') then
    raise exception 'merchant match review requires admin' using errcode='42501';
  end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
        'id', t.id, 'company_id', t.company_id, 'business_id', t.business_id,
        'company_name', t.company_name, 'merchant_name', t.merchant_name,
        'company_postal', t.company_postal, 'merchant_postal', t.merchant_postal,
        'match_basis', t.match_basis, 'created_at', t.created_at)
      order by t.created_at desc)
    from (
      select m.id, m.company_id, m.business_id, m.match_basis, m.created_at,
             coalesce(c.trading_name, c.legal_name) as company_name,
             coalesce(b.legal_name, b.name) as merchant_name,
             l.postal_code as company_postal, b.postal_code as merchant_postal
        from public.sme_merchant_match_candidates m
        join public.sme_companies c on c.id=m.company_id
        join public.businesses b on b.id=m.business_id
        left join public.sme_company_locations l on l.company_id=c.id and l.is_primary
       where m.status='pending'
       order by m.created_at desc
       limit greatest(least(coalesce(p_limit,50),200),1)
    ) t), '[]'::jsonb);
end $function$;

revoke all on function public.platform_merchant_matches_v312(integer) from public, anon;
grant execute on function public.platform_merchant_matches_v312(integer) to authenticated;

do $verify$
declare v_left text;
begin
  select string_agg(n.nspname||'.'||p.proname, ', ') into v_left
    from pg_proc p join pg_namespace n on n.oid=p.pronamespace
   where n.nspname in ('public','app') and p.prokind='f'
     and pg_get_functiondef(p.oid) like '%lead_score%';
  if v_left is not null then
    raise exception 'lead_score references still present in: %', v_left;
  end if;
end $verify$;

commit;
