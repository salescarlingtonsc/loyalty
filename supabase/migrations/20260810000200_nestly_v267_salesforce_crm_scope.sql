-- NESTLY v267 — the sales force works only its own book, and only the super
-- admin hands firms out. Shipped ahead of sales operations going live, after a
-- release audit of every CRM gate.
--
-- FIX 1 — app.v156_can_prospect had a scope hole that made its own scoping
-- clause dead code. The old body:
--
--   is_super_admin()
--   or v89_platform_can('onboarding', p_mode)        <- passes for sales_staff
--   or (role='sales_staff' and assigned-to-me)       <- therefore unreachable
--
-- v89_platform_can returns true for a sales_staff whose grant carries the
-- onboarding module, so the second clause admitted them to ANY prospect and
-- the assigned-only clause after it never decided anything. Seven commercial
-- functions inherit this helper — quotations (save/finalize/send), billing
-- contact, Stripe checkout link, document read, subscription ops — meaning a
-- consultant could issue a quotation against another consultant's firm.
--
-- The helper is now role-aware: admin keeps all-scope (their job), and
-- sales_staff must BOTH hold the module mode AND be the assigned consultant.
-- The old sales clause also never checked p_mode, so a read-only sales grant
-- would have satisfied 'rw' — closed in the same breath.
--
-- FIX 2+3 — owner rule (2026-08-10): ONLY the super admin assigns firms to
-- consultants. Both assignment generations said admin-or-SA:
--   platform_assign_prospect_v89: role in ('super_admin','admin')
--   platform_assign_prospect_v76: is_platform_operator_v75()  (same set)
-- Both now require app.is_super_admin(). Tightening one and not the other
-- would have left the rule unenforced through the older door. Bodies are
-- otherwise unchanged (v76 keeps its replay/idempotency machinery verbatim).
--
-- The console matches: the Change-owner button and the scoped-surface assign
-- control render only for the super admin, so no role is shown a button the
-- database will refuse.
--
-- Verified rolled-back on production first (db/tests/v267_salesforce_crm_scope.sql,
-- assertions A–H covering sales/admin/super-admin from every side), then applied.

begin;

create or replace function app.v156_can_prospect(p_prospect uuid, p_mode text default 'r')
returns boolean language sql stable security definer
set search_path to 'pg_catalog','public','app','pg_temp' as $$
  select coalesce(
    app.is_super_admin()
    or (app.v89_platform_role()='admin'
        and app.v89_platform_can('onboarding',p_mode))
    or (app.v89_platform_role()='sales_staff'
        and app.v89_platform_can('onboarding',p_mode)
        and exists(
          select 1 from public.sme_prospects prospect
          join public.platform_consultants consultant
            on consultant.id=prospect.assigned_consultant_id
          where prospect.id=p_prospect
            and consultant.user_id=auth.uid()
            and consultant.active))
  ,false)
$$;

create or replace function public.platform_assign_prospect_v89(p_prospect uuid, p_consultant uuid, p_reason text default null)
returns jsonb language plpgsql security definer
set search_path to 'pg_catalog','public','app','pg_temp' as $$
begin
  if not app.is_super_admin() then
    raise exception 'only the super admin may assign firms to consultants'
      using errcode='42501';
  end if;
  if p_consultant is not null and not exists(
    select 1 from public.platform_consultants consultant
    where consultant.id=p_consultant and consultant.active
  ) then raise exception 'active consultant is required' using errcode='22023';end if;
  perform 1 from public.sme_prospects where id=p_prospect for update;
  if not found then raise exception 'prospect was not found' using errcode='22023';end if;
  update public.sme_prospects set assigned_consultant_id=p_consultant,
    updated_by=auth.uid(),updated_at=now(),version=version+1
    where id=p_prospect;
  insert into public.sme_prospect_assignments(
    prospect_id,consultant_id,assigned_by,reason
  ) values(p_prospect,p_consultant,auth.uid(),nullif(btrim(p_reason),''));
  return jsonb_build_object('prospect_id',p_prospect,
    'assigned_consultant_id',p_consultant,'status','assigned');
end $$;

create or replace function public.platform_assign_prospect_v76(p_prospect uuid, p_consultant uuid, p_expected_version bigint, p_idempotency_key text)
returns jsonb language plpgsql security definer
set search_path to 'pg_catalog','public','app','pg_temp' as $$
declare v_actor uuid:=auth.uid();v_hash text;v_replay jsonb;v_row public.sme_prospects%rowtype;v_response jsonb;
begin
  if not app.is_super_admin() then
    raise exception 'only the super admin may assign firms to consultants'
      using errcode='42501';
  end if;
  if p_consultant is not null and not exists(select 1 from public.platform_consultants where id=p_consultant and active) then
    raise exception 'active consultant was not found' using errcode='22023'; end if;
  v_hash:=app.v76_sha256_hex(jsonb_build_object('prospect',p_prospect,'version',p_expected_version,'consultant',p_consultant)::text);
  v_replay:=app.v76_replay(v_actor,'assign_prospect',p_idempotency_key,v_hash);if v_replay is not null then return v_replay;end if;
  update public.sme_prospects set assigned_consultant_id=p_consultant,version=version+1,updated_by=v_actor,updated_at=now()
   where id=p_prospect and version=p_expected_version returning * into v_row;
  if not found then raise exception 'prospect version conflict' using errcode='40001';end if;
  insert into public.sme_prospect_assignments(prospect_id,consultant_id,assigned_by,reason)
  values(p_prospect,p_consultant,v_actor,'platform assignment');
  insert into public.audit_log(business_id,actor,action,entity,entity_id,detail)
  values(null,v_actor,'SME_PROSPECT_ASSIGNED_V76','sme_prospects',p_prospect,
    jsonb_build_object('consultant_id',p_consultant,'new_version',v_row.version));
  v_response:=jsonb_build_object('replayed',false,'prospect',app.sme_prospect_card_v76(p_prospect));
  perform app.v76_store_receipt(v_actor,'assign_prospect',p_idempotency_key,v_hash,v_response);return v_response;
end $$;

revoke all on function public.platform_assign_prospect_v89(uuid,uuid,text)
  from public, anon, authenticated;
grant execute on function public.platform_assign_prospect_v89(uuid,uuid,text)
  to authenticated;

revoke all on function public.platform_assign_prospect_v76(uuid,uuid,bigint,text)
  from public, anon, authenticated;
grant execute on function public.platform_assign_prospect_v76(uuid,uuid,bigint,text)
  to authenticated;

commit;
