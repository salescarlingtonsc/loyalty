-- nestly_v772 — "Copy settings from" a branch copies the branch's own setup, never its people
-- (owner ruling 2026-09-05).
--
-- OWNER: "who works there should not be ported over — different staff manage different branches,
-- unless the owner indicates that a staff member works in multiple selected branches. The rest
-- should follow the main branch." And: "rewards must be the same for every branch."
--
-- business_copy_branch_settings_v202 copied staff_branches too, so a new outlet was born with the
-- main outlet's whole roster assigned to it. Staff assignment is a deliberate per-branch decision
-- made on the Staff Members page; it is no longer part of a copy. Opening hours, breaks and the
-- services offered are still copied. Loyalty branch overrides are still copied so a new branch
-- starts identical to the one it copies (the owner's "rewards must be the same"); products,
-- prices and the loyalty programme itself are firm-wide and need no copy.
--
-- Grants restated verbatim from the live proacl.

begin;

create or replace function public.business_copy_branch_settings_v202(
  p_business uuid, p_from uuid, p_to uuid
) returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public, app, pg_temp
as $function$
declare
  v_hours integer := 0; v_breaks integer := 0; v_services integer := 0;
  v_loyalty integer := 0; v_live uuid;
begin
  if auth.uid() is null or not (app.is_salon_owner(p_business) or app.is_super_admin()) then
    raise exception 'owner access is required' using errcode='42501';
  end if;
  if p_from is null or p_to is null or p_from = p_to then
    raise exception 'a source and a different destination branch are required' using errcode='22023';
  end if;
  if not exists (select 1 from public.branches where id=p_from and business_id=p_business)
     or not exists (select 1 from public.branches where id=p_to and business_id=p_business) then
    raise exception 'both branches must belong to this business' using errcode='42501';
  end if;

  insert into public.branch_hours(business_id,branch_id,weekday,opens_at,closes_at)
  select p_business,p_to,h.weekday,h.opens_at,h.closes_at
    from public.branch_hours h
   where h.business_id=p_business and h.branch_id=p_from
     and not exists (
       select 1 from public.branch_hours e
        where e.business_id=p_business and e.branch_id=p_to and e.weekday=h.weekday
          and e.opens_at=h.opens_at and e.closes_at=h.closes_at);
  get diagnostics v_hours = row_count;

  insert into public.branch_breaks(business_id,branch_id,weekday,starts_at,ends_at)
  select p_business,p_to,b.weekday,b.starts_at,b.ends_at
    from public.branch_breaks b
   where b.business_id=p_business and b.branch_id=p_from
     and not exists (
       select 1 from public.branch_breaks e
        where e.business_id=p_business and e.branch_id=p_to and e.weekday=b.weekday
          and e.starts_at=b.starts_at and e.ends_at=b.ends_at);
  get diagnostics v_breaks = row_count;

  insert into public.service_branches(business_id,service_id,branch_id)
  select p_business,s.service_id,p_to from public.service_branches s
   where s.business_id=p_business and s.branch_id=p_from
  on conflict do nothing;
  get diagnostics v_services = row_count;

  /* v772: staff_branches is deliberately NOT copied. Who works at a branch is assigned per
     branch on the Staff Members page (owner ruling 2026-09-05). */

  select fcv.id into v_live from public.firm_config_versions fcv
   where fcv.business_id=p_business and fcv.status='published'
   order by fcv.published_at desc nulls last limit 1;
  if v_live is not null then
    insert into public.loyalty_branch_overrides(
      config_version_id,business_id,branch_id,active,earn_points_per_dollar,
      stamp_per_cents,expiry_mode,expiry_days)
    select o.config_version_id,p_business,p_to,o.active,o.earn_points_per_dollar,
           o.stamp_per_cents,o.expiry_mode,o.expiry_days
      from public.loyalty_branch_overrides o
     where o.business_id=p_business and o.branch_id=p_from
       and o.config_version_id=v_live
    on conflict do nothing;
    get diagnostics v_loyalty = row_count;
  end if;

  return jsonb_build_object(
    'status','ok','from_branch',p_from,'to_branch',p_to,
    'opening_hours',v_hours,'breaks',v_breaks,'services',v_services,
    'staff_assignments',0,'loyalty_overrides',v_loyalty,
    'products_note','products are firm-wide and need no copy');
end
$function$;

comment on function public.business_copy_branch_settings_v202(uuid,uuid,uuid) is
  'nestly_v772: copies opening hours, breaks, services offered and loyalty overrides from one '
  'branch to another. Staff assignments are never copied (owner ruling 2026-09-05).';

revoke all on function public.business_copy_branch_settings_v202(uuid,uuid,uuid) from public, anon;
grant execute on function public.business_copy_branch_settings_v202(uuid,uuid,uuid) to authenticated, service_role;

commit;
