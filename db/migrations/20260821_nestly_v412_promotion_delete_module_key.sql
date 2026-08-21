-- nestly_v412 — the promotion delete gate names a module that does not exist (P0).
--
-- SYMPTOM (owner, 2026-08-21, Hougang ABC): "End" on a live offer and "Delete" on a draft both
-- show `promotion write access required`. The OWNER of the business is refused.
--
-- CAUSE. public.business_delete_promotion_v183 opens with
--     app.can_module_write_at_v94(p_business, null, 'promotions')
-- which resolves through app.staff_module_mode_v94 -> app.effective_platform_module_mode_v94,
-- whose final fallback is:
--     select case when p_module = any(business.enabled_modules) then 'rw' else 'disabled' end
--
-- `promotions` IS NOT A MODULE. The authoritative registry (frenly_v24b) defines 21 keys —
-- appointments, bookings, branches, clients, dailyreport, dashboard, expenses, giftcards,
-- inventory, loyalty, memberships, packages, pnl, referrals, reports, retention, sales, services,
-- staffperf, till, waitlist — and `promotions` is not among them. It is absent from the sector
-- entitlements, absent from the client MODULES map, and no migration has ever written it into
-- businesses.enabled_modules. So the fallback returns 'disabled' for every business, and
-- staff_module_mode_v94 returns BEFORE it reads the staff role — which is why an owner is refused
-- exactly like a receptionist. Broken for every tenant since v183 shipped (2026-08-06).
--
-- Every other call site in the schema passes a real key (till, sales, clients, reports, loyalty,
-- appointments). 'promotions' is used exactly once: here. Both "End" (retire a live offer) and
-- "Delete" (drop a draft) call this one RPC, which is why neither worked.
--
-- FIX. Gate on 'loyalty' — the module the CLIENT already requires for this exact surface: app.js
-- builds its promotions read as `S.myRole==='owner' && modules.includes('loyalty')`, and Limited
-- Offer sits under Rewards & Offer in the nav. This makes the server agree with the authorisation
-- the product already applies rather than inventing a new entitlement.
--
-- THE BODY BELOW IS v183's, BYTE FOR BYTE, WITH ONE STRING CHANGED. It was extracted from
-- db/migrations/20260806_nestly_v183_promotion_delete.sql programmatically and diffed, because a
-- hand-retyped version of it silently dropped the audit_log insert, the promotion_branch_scopes
-- v154/v155 cleanup, updated_by/updated_at, and changed the returned JSON shape. Nothing about the
-- retire/hard-delete split, the version check or the GUC handling is touched.
--
-- NOT CHOSEN, and why: registering 'promotions' as a real module would also work, but it is a new
-- entitlement surface — a registry row, sector-entitlement placement and a backfill into every
-- business's enabled_modules — and it would let a firm be sold "promotions" separately from
-- loyalty, which is not how the product is packaged today.
--
-- REVERSIBLE: re-running v183 restores the previous body (and the outage).

begin;

create or replace function public.business_delete_promotion_v183(
  p_business uuid, p_promotion_id uuid, p_expected_version bigint default null
)
returns json
language plpgsql
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare
  v_row public.business_customer_content_v95%rowtype;
  v_mode text;
begin
  if not app.can_module_write_at_v94(p_business, null, 'loyalty') then
    raise exception 'promotion write access required' using errcode='42501';
  end if;
  select * into v_row from public.business_customer_content_v95
   where business_id = p_business and id = p_promotion_id and content_type = 'offer'
   for update;
  if not found then
    raise exception 'promotion not found in this business' using errcode='42704';
  end if;
  if p_expected_version is not null and v_row.version is distinct from p_expected_version then
    raise exception 'this promotion changed in another tab; reopen it and try again'
      using errcode='40001';
  end if;

  perform set_config('app.v104_promotion_write','on',true);
  perform set_config('app.v104_promotion_copy_write','on',true);

  if coalesce(v_row.active,false) then
    v_mode := 'retired';
    update public.business_customer_content_v95
       set active=false, ends_at=least(coalesce(ends_at,now()),now()),
           version=version+1, updated_by=auth.uid(), updated_at=now()
     where id=p_promotion_id and business_id=p_business;
  else
    v_mode := 'deleted';
    delete from public.promotion_branch_scopes_v155
     where promotion_id=p_promotion_id and business_id=p_business;
    delete from public.promotion_branch_scopes_v154
     where promotion_id=p_promotion_id and business_id=p_business;
    delete from public.business_localized_copy_v95
     where business_id=p_business and entity_type='offer' and entity_id=p_promotion_id;
    delete from public.business_customer_content_v95
     where id=p_promotion_id and business_id=p_business;
  end if;

  perform set_config('app.v104_promotion_write','',true);
  perform set_config('app.v104_promotion_copy_write','',true);

  insert into public.audit_log(business_id, actor, action, entity, entity_id, meta)
  values (p_business, auth.uid(), 'promotion.'||v_mode, 'promotion', p_promotion_id,
          jsonb_build_object('was_published', coalesce(v_row.active,false)));
  return json_build_object('status','ok','mode',v_mode,'promotion_id',p_promotion_id);
end $$;

revoke all on function public.business_delete_promotion_v183(uuid,uuid,bigint) from public, anon;
grant execute on function public.business_delete_promotion_v183(uuid,uuid,bigint) to authenticated;

comment on function public.business_delete_promotion_v183(uuid,uuid,bigint) is
  'v412: retire a published promotion or hard-delete a draft. Gated on the loyalty module - v183 '
  'gated on ''promotions'', which is not a registered module, so every caller including the owner '
  'was refused.';

commit;
