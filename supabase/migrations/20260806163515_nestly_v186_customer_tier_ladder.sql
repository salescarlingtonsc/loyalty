-- v186 — the customer sees the whole tier ladder, not just the rung they are on.
--
-- Owner, 2026-08-07: "i want to see different tiers (and its benefits) and shows his current tier
-- — maybe can put black and white (mask) other tiers (still can see the benefits but very obvious
-- that is not their tier)." A ladder you cannot see is not a ladder; naming what Gold unlocks is
-- the whole reason a member climbs.
--
-- This adds a `tiers` array to the SAME function and signature, so every existing caller keeps
-- working and no grant changes: current/next/progress_percent/basis/metric are untouched. Each
-- entry carries the tier's own benefits plus two derived flags the client must not have to
-- compute — `achieved` (the customer's metric has passed the threshold) and `current` (the exact
-- rung the server placed them on). The same effective_from / expires_at window that already
-- decides current and next decides membership of the list, so a scheduled tier cannot appear in
-- the ladder before it applies.

begin;

create or replace function public.customer_get_effective_tier_v143(p_business uuid)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public, app, pg_temp
as $$
declare
  v_identity uuid;
  v_client uuid;
  v_basis text;
  v_metric numeric:=0;
  v_current public.loyalty_tiers%rowtype;
  v_next public.loyalty_tiers%rowtype;
  v_progress numeric:=0;
  v_tiers jsonb;
begin
  if auth.uid() is null then
    raise exception 'authenticated customer session required' using errcode='28000';
  end if;
  v_identity:=app.v31_current_identity();
  select link.client_id into v_client
  from public.customer_links link
  where link.identity_id=v_identity
    and link.auth_user_id=auth.uid()
    and link.business_id=p_business
    and link.state='verified';
  if not found then
    raise exception 'verified customer link required' using errcode='42501';
  end if;
  if not app.business_module_enabled_at_v117(p_business,'loyalty',null)
     or not exists(
       select 1 from public.loyalty_programs
       where business_id=p_business and active
     ) then
    raise exception 'loyalty module is unavailable for this business' using errcode='42501';
  end if;

  select coalesce(tier_basis,'visits') into v_basis
  from public.loyalty_programs
  where business_id=p_business and active
  limit 1;
  if v_basis='spend' then
    select coalesce(sum(amount_cents),0)/100.0 into v_metric from public.sales
    where business_id=p_business and client_id=v_client and counts_as_revenue;
  elsif v_basis='points_earned' then
    select coalesce(sum(points),0) into v_metric from public.points_ledger
    where business_id=p_business and client_id=v_client and entry_type='earn';
  else
    select count(*) into v_metric from public.sales
    where business_id=p_business and client_id=v_client and counts_as_visit;
  end if;

  select * into v_current from public.loyalty_tiers
  where business_id=p_business
    and threshold<=v_metric
    and (effective_from is null or effective_from<=statement_timestamp())
    and (expires_at is null or expires_at>statement_timestamp())
  order by threshold desc,sort desc,id limit 1;
  select * into v_next from public.loyalty_tiers
  where business_id=p_business
    and threshold>coalesce(v_current.threshold,-1)
    and (effective_from is null or effective_from<=statement_timestamp())
    and (expires_at is null or expires_at>statement_timestamp())
  order by threshold,sort,id limit 1;
  if v_next.id is not null then
    v_progress:=greatest(0,least(100,round(
      (v_metric-coalesce(v_current.threshold,0))*100
      /nullif(v_next.threshold-coalesce(v_current.threshold,0),0),2
    )));
  elsif v_current.id is not null then
    v_progress:=100;
  end if;

  -- v186: the full ladder, lowest rung first, in the same effective window as current/next.
  select coalesce(jsonb_agg(jsonb_build_object(
    'id',ladder.id,
    'label',ladder.name,
    'threshold',ladder.threshold,
    'achieved',ladder.threshold<=v_metric,
    'current',ladder.id=v_current.id,
    'benefits',coalesce((
      select jsonb_agg(btrim(benefit) order by ordinal)
      from regexp_split_to_table(coalesce(ladder.perk_note,''),E'\\r?\\n')
        with ordinality as item(benefit,ordinal)
      where btrim(benefit)<>''
    ),'[]'::jsonb)
  ) order by ladder.threshold,ladder.sort,ladder.id),'[]'::jsonb) into v_tiers
  from public.loyalty_tiers ladder
  where ladder.business_id=p_business
    and (ladder.effective_from is null or ladder.effective_from<=statement_timestamp())
    and (ladder.expires_at is null or ladder.expires_at>statement_timestamp());

  return jsonb_build_object('tier',jsonb_build_object(
    'label',v_current.name,
    'current',case when v_current.id is null then null else jsonb_build_object(
      'id',v_current.id,'label',v_current.name,'threshold',v_current.threshold,
      'metric',v_metric,'benefits',coalesce((
        select jsonb_agg(btrim(benefit) order by ordinal)
        from regexp_split_to_table(coalesce(v_current.perk_note,''),E'\\r?\\n')
          with ordinality as item(benefit,ordinal)
        where btrim(benefit)<>''
      ),'[]'::jsonb)
    ) end,
    'next',case when v_next.id is null then null else jsonb_build_object(
      'id',v_next.id,'label',v_next.name,'threshold',v_next.threshold,
      'benefits',coalesce((
        select jsonb_agg(btrim(benefit) order by ordinal)
        from regexp_split_to_table(coalesce(v_next.perk_note,''),E'\\r?\\n')
          with ordinality as item(benefit,ordinal)
        where btrim(benefit)<>''
      ),'[]'::jsonb)
    ) end,
    'tiers',v_tiers,
    'progress_percent',v_progress,'basis',v_basis,'metric',v_metric
  ));
end
$$;

revoke all on function public.customer_get_effective_tier_v143(uuid) from public, anon;
grant execute on function public.customer_get_effective_tier_v143(uuid) to authenticated;
grant execute on function public.customer_get_effective_tier_v143(uuid) to service_role;

commit;
