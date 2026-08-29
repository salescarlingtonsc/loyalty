-- NESTLY v622 — a super admin acts through declared, audited RPCs, never raw table writes.
--
-- Two direct-write policies die here:
--   · subscriptions_sa_write (v14b) — an ALL-command policy letting any super-admin session
--     PATCH /rest/v1/subscriptions on any tenant: no reason, no audit, no column limit. It was
--     also the only de-facto "extend trial" mechanism, which is exactly why it must become an
--     RPC: with v620 entitlement live, trial_ends_at IS operational access.
--   · the is_super_admin() arm on the three sale_policies write policies (v102) — sale
--     accounting semantics are tenant configuration; the platform reads, it does not silently
--     rewrite. (The v14 invariant said no tenant-table write policy ORs in is_super_admin;
--     v102 violated it.)
--
-- Their replacements are narrow: platform_adjust_subscription_v622 (trial runway + note only,
-- reason mandatory, before/after audited) and platform_set_workspace_pause_v622 (the manual
-- pause/resume lever the console never had — until now the ONLY pause was the dunning cron,
-- and the only unpause RPC was never wired to any UI).

begin;

create or replace function public.platform_adjust_subscription_v622(
  p_business uuid,
  p_reason text,
  p_trial_ends_at timestamptz default null,
  p_note text default null
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_before public.subscriptions%rowtype;
  v_after public.subscriptions%rowtype;
begin
  if not app.is_super_admin() then
    raise exception 'super_admin_required' using errcode = '42501';
  end if;
  if length(coalesce(btrim(p_reason), '')) < 8 then
    raise exception 'a reason of at least 8 characters is required' using errcode = '22023';
  end if;
  if p_trial_ends_at is null and p_note is null then
    raise exception 'nothing to adjust' using errcode = '22023';
  end if;
  if p_trial_ends_at is not null and p_trial_ends_at > now() + interval '180 days' then
    raise exception 'trial runway beyond 180 days is not adjustable here' using errcode = '22023';
  end if;

  select * into v_before from public.subscriptions where business_id = p_business for update;
  if v_before.business_id is null then
    raise exception 'no subscription exists for this business' using errcode = '42704';
  end if;

  update public.subscriptions
     set trial_ends_at = coalesce(p_trial_ends_at, trial_ends_at),
         note = coalesce(p_note, note),
         updated_at = now()
   where business_id = p_business
  returning * into v_after;

  insert into public.audit_log (business_id, actor, action, entity, entity_id, detail)
  values (p_business, auth.uid(), 'PLATFORM_SUBSCRIPTION_ADJUSTED_V622', 'subscriptions', p_business,
          jsonb_build_object(
            'reason', btrim(p_reason),
            'before', jsonb_build_object('trial_ends_at', v_before.trial_ends_at, 'note', v_before.note),
            'after',  jsonb_build_object('trial_ends_at', v_after.trial_ends_at,  'note', v_after.note)
          ));

  return jsonb_build_object('business_id', p_business,
                            'trial_ends_at', v_after.trial_ends_at,
                            'entitlement', app.business_entitlement_v620(p_business));
end
$$;
revoke all on function public.platform_adjust_subscription_v622(uuid, text, timestamptz, text) from public, anon;
grant execute on function public.platform_adjust_subscription_v622(uuid, text, timestamptz, text) to authenticated;

create or replace function public.platform_set_workspace_pause_v622(
  p_business uuid,
  p_paused boolean,
  p_reason text
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_before public.business_subscription_lifecycle_v94%rowtype;
begin
  if not app.is_super_admin() then
    raise exception 'super_admin_required' using errcode = '42501';
  end if;
  if length(coalesce(btrim(p_reason), '')) < 8 then
    raise exception 'a reason of at least 8 characters is required' using errcode = '22023';
  end if;

  select * into v_before from public.business_subscription_lifecycle_v94
   where business_id = p_business for update;
  if v_before.business_id is null then
    raise exception 'no lifecycle row exists for this business' using errcode = '42704';
  end if;

  /* The v94 shape CHECK is strict: 'paused' requires overdue_day>=14, a provider_invoice_id,
     a due_date and paused_at; 'current' requires overdue_day IS NULL. A manual platform pause
     satisfies the paused arm with explicit manual markers rather than loosening the CHECK. */
  update public.business_subscription_lifecycle_v94
     set workspace_paused = p_paused,
         state = case when p_paused then 'paused' else 'current' end,
         overdue_day = case when p_paused then greatest(coalesce(overdue_day, 14), 14) else null end,
         provider_invoice_id = case when p_paused
           then coalesce(provider_invoice_id, 'platform-manual-pause') else provider_invoice_id end,
         due_date = case when p_paused then coalesce(due_date, current_date) else due_date end,
         paused_at = case when p_paused then now() else paused_at end,
         recovered_at = case when p_paused then recovered_at else now() end,
         version = version + 1,
         updated_at = now()
   where business_id = p_business;

  insert into public.audit_log (business_id, actor, action, entity, entity_id, detail)
  values (p_business, auth.uid(), 'PLATFORM_WORKSPACE_PAUSE_V622', 'business_subscription_lifecycle_v94', p_business,
          jsonb_build_object('reason', btrim(p_reason),
                             'before', jsonb_build_object('workspace_paused', v_before.workspace_paused, 'state', v_before.state),
                             'after',  jsonb_build_object('workspace_paused', p_paused)));

  return jsonb_build_object('business_id', p_business, 'workspace_paused', p_paused,
                            'entitlement', app.business_entitlement_v620(p_business));
end
$$;
revoke all on function public.platform_set_workspace_pause_v622(uuid, boolean, text) from public, anon;
grant execute on function public.platform_set_workspace_pause_v622(uuid, boolean, text) to authenticated;

-- The direct-write doors close only after the replacements above exist.
drop policy if exists subscriptions_sa_write on public.subscriptions;

drop policy if exists sale_policies_owner_insert_v102 on public.sale_policies;
create policy sale_policies_owner_insert_v102 on public.sale_policies
  for insert to authenticated
  with check (app.is_salon_owner(business_id));

drop policy if exists sale_policies_owner_update_v102 on public.sale_policies;
create policy sale_policies_owner_update_v102 on public.sale_policies
  for update to authenticated
  using (app.is_salon_owner(business_id))
  with check (app.is_salon_owner(business_id));

drop policy if exists sale_policies_owner_delete_v102 on public.sale_policies;
create policy sale_policies_owner_delete_v102 on public.sale_policies
  for delete to authenticated
  using (app.is_salon_owner(business_id));

commit;
