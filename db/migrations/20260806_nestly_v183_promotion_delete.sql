-- V183 — promotions can be deleted/retired (owner: "I can edit but i cannot delete T.T").
-- APPLIED TO PRODUCTION 2026-08-06 via MCP apply_migration in three parts
-- (nestly_v183_delete_promotion, nestly_v183a_delete_promotion_content_type_fix,
--  nestly_v183b/c_..._guard_guc). This file records the resulting contract.
--
-- Offers could be created, edited and published but never removed, so a typo lived in the
-- "Your promotions" list forever. There was no delete or archive RPC of any kind.
--
-- SEMANTICS, deliberately split:
--   * A DRAFT (active=false) is HARD-deleted with its localized copy and branch scopes. No
--     customer has ever seen it, so a tombstone would be clutter with no audit value.
--   * A PUBLISHED offer is RETIRED: active=false and ends_at pulled back to now. It leaves every
--     customer surface immediately, but the row survives because promotion_alert_runs_v122 and
--     business_promotion_attempt_receipts_v104 reference the id, and because it is the record of
--     what was actually advertised.
--
-- THREE THINGS THE FIRST DRAFT GOT WRONG, each caught by rolled-back verification before any UI
-- was wired to it:
--   1. Promotions are stored with content_type='offer', not 'promotion'. The original filter
--      matched nothing and would have raised "promotion not found" for every real offer.
--   2. business_customer_content_v95 is protected by app.v104_promotion_write_guard, which
--      rejects any write touching an offer unless the GUC app.v104_promotion_write is 'on'.
--   3. business_localized_copy_v95 has its OWN guard and its own GUC
--      (app.v104_promotion_copy_write). Both GUCs are set transaction-local and cleared before
--      returning, so nothing leaks to a later statement on the same connection.
--
-- VERIFIED against production inside rolled-back transactions on 2026-08-06:
--   draft hard-delete removes the row and its localized copy; published retire keeps the row with
--   active=false and ends_at<=now(); the guard still blocks the same DELETE when the GUC is unset;
--   an unauthenticated caller is refused by the module-write check.
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
  if not app.can_module_write_at_v94(p_business, null, 'promotions') then
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

commit;
