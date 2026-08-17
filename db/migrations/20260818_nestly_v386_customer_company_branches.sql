-- v386: the customer "Company details" sheet shows every branch, not just the default one.
--
-- Owner annotation (photo 2, 2026-08-17): "put other branches here too", drawn beside the
-- single address line in the company-details modal.
--
-- customer_get_offer_business_contact_v173 answers with ONE branch — a `limit 1` lateral
-- ordered by is_default — because v173 built it for the offer-detail sheet, where one
-- contact line was the whole requirement. A multi-outlet business (the product's own target
-- customer: "multi-outlet SME, 2-20 locations") therefore showed its customer a single
-- address and no way to learn the others existed.
--
-- This replaces the function in place rather than adding a v386 twin, so both callers (the
-- offer sheet and the company-details modal) gain the list from one definition and cannot
-- drift apart. The existing `branch` key is UNCHANGED — same default-branch object, same
-- shape, same null-when-absent behaviour — so the v173 offer sheet keeps rendering exactly
-- what it renders today against an older cached bundle. A new `branches` array is added
-- alongside it: every active branch, default first, each with the same four public contact
-- fields the default branch already exposes. Nothing new is disclosed about a branch that
-- the default-branch object would not already disclose about that same branch.
--
-- The verified-link gate is unchanged and deliberately restated verbatim: only an
-- authenticated customer with a `verified` customer_links row for this exact business may
-- read it, the caller cannot nominate an identity or a tenant, and anon execution stays
-- revoked.
begin;

create or replace function public.customer_get_offer_business_contact_v173(p_business uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare
  v_actor uuid := auth.uid();
  v_identity uuid;
  v_result jsonb;
begin
  if v_actor is null then
    raise exception 'authenticated_session_required' using errcode='28000';
  end if;
  if p_business is null then
    raise exception 'business_required' using errcode='22023';
  end if;
  v_identity := app.v31_current_identity();
  if not exists(
    select 1 from public.customer_links link
    where link.identity_id = v_identity
      and link.auth_user_id = v_actor
      and link.business_id = p_business
      and link.state = 'verified'
  ) then
    raise exception 'verified_customer_link_required' using errcode='42501';
  end if;

  select jsonb_build_object(
    'business', jsonb_build_object(
      'id', business.id,
      'slug', business.slug,
      'name', business.name
    ),
    'branch', case when branch.id is null then null else jsonb_build_object(
      'name', branch.name,
      'address', branch.address,
      'phone', branch.phone,
      'email', branch.email
    ) end,
    -- v386: every active branch, default first, then oldest first — the SAME ordering the
    -- default-branch lateral uses, so branches[0] is always the object in `branch`.
    'branches', coalesce(all_branches.items, '[]'::jsonb)
  ) into v_result
  from public.businesses business
  left join lateral (
    select b.id, b.name, b.address, b.phone, b.email
    from public.branches b
    where b.business_id = business.id and coalesce(b.active,true)
    order by b.is_default desc, b.created_at, b.id
    limit 1
  ) branch on true
  left join lateral (
    select jsonb_agg(jsonb_build_object(
      'name', b.name,
      'address', b.address,
      'phone', b.phone,
      'email', b.email
    ) order by b.is_default desc, b.created_at, b.id) as items
    from public.branches b
    where b.business_id = business.id and coalesce(b.active,true)
  ) all_branches on true
  where business.id = p_business;

  return v_result;
end
$$;

comment on function public.customer_get_offer_business_contact_v173(uuid) is
  'Default-branch contact plus (v386) every active branch, for the customer offer-detail and company-details sheets; requires an auth.uid() verified customer link to the business.';

revoke all on function public.customer_get_offer_business_contact_v173(uuid) from public,anon;
grant execute on function public.customer_get_offer_business_contact_v173(uuid) to authenticated;

commit;
