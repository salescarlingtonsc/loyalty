-- nestly_v768 — "Keep" on a stopping branch that is already paid keeps it ON (2026-09-05).
--
-- OBSERVED LIVE (test mode, Cafe Only, 2026-09-05 04:26Z): East Wing was added and its year paid
-- (SGD 1,188, invoice inv_TYDW4Sm0wi8Jv7, covers until 5 Sep 2027). "Switch off" scheduled it to
-- stop at renewal — correct. "Keep" then set it to pending_payment / inactive: the page said
-- "Awaiting payment", the Branches page said "Nothing at it can take a booking or a sale yet",
-- and the toast told the owner to pay for it again. The branch's unit was still on the Razorpay
-- subscription (quantity 2, reduction scheduled for cycle end); nothing had been refunded; the
-- owner had simply changed their mind inside the period they had paid for.
--
-- WHY v665 DID THAT. Under Stripe, business_unsubscribe_branch_v665's change_branches command
-- removed the unit from the provider subscription at once ("Stripe is told now"), so Keep had to
-- treat the branch as unpaid and buy the unit back. Under Razorpay (v764) a decrease is PATCHed
-- with schedule_change_at=cycle_end: the unit stays on the subscription, and the paid period
-- keeps running until the renewal date. Keep is therefore `cancel_scheduled_changes`, not a new
-- purchase, and the branch simply returns to the state it was in before Switch off.
--
-- WHAT CHANGES
--   business_resubscribe_branch_v665 restores billing_state_prior when it is 'active' (paid) or
--   'included' (free), keeping `active` as it was; only a branch that had never been paid
--   (prior 'pending_payment', or no prior) comes back as pending_payment. The change_branches
--   command is still requested so the edge function withdraws the provider's scheduled
--   reduction (units equal + has_scheduled_changes → cancel_scheduled_changes, no charge).
--   Grants restated verbatim from the live proacl.

begin;

create or replace function public.business_resubscribe_branch_v665(
  p_business uuid, p_branch uuid, p_idempotency_key uuid
) returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public, app, pg_temp
as $function$
declare
  v_actor uuid := auth.uid();
  v_branch public.branches%rowtype;
  v_subscription public.subscriptions%rowtype;
  v_restored text;
  v_command jsonb := null;
  v_cadence text;
  v_capacity integer;
begin
  if v_actor is null or not (app.is_salon_owner(p_business) or app.is_super_admin()) then
    raise exception 'owner access is required' using errcode = '42501';
  end if;
  if p_idempotency_key is null then
    raise exception 'an idempotency key is required' using errcode = '22023';
  end if;
  select * into v_branch from public.branches
   where id = p_branch and business_id = p_business for update;
  if not found then
    raise exception 'branch was not found for this business' using errcode = '22023';
  end if;
  if v_branch.billing_state <> 'canceling' then
    raise exception 'only a branch that is stopping can be kept' using errcode = '22023';
  end if;

  /* v768: the branch goes back to what it was. A paid branch's unit is still on the provider
     subscription until the renewal date (the reduction was scheduled for cycle end, never
     applied), so it is still paid for and stays on. A free branch stays free. Only a branch
     that had never been paid comes back as pending_payment. */
  v_restored := case
    when v_branch.billing_state_prior in ('included','active') then v_branch.billing_state_prior
    else 'pending_payment' end;

  perform set_config('app.branch_authority_v621','on',true);
  perform set_config('app.v79_system_transition','on',true);
  update public.branches
     set billing_state = v_restored,
         billing_state_prior = null,
         billing_cancel_at = null,
         active = case when v_restored = 'pending_payment' then false else active end,
         updated_at = now()
   where id = p_branch;
  perform set_config('app.branch_authority_v621','off',true);
  perform set_config('app.v79_system_transition','off',true);

  insert into public.audit_log (business_id, actor, action, entity, entity_id, detail)
  values (p_business, v_actor, 'BRANCH_RESUBSCRIBED_V665', 'branches', p_branch,
          jsonb_build_object('branch_name', v_branch.name, 'restored_state', v_restored,
                             'prior_state', v_branch.billing_state_prior,
                             'operation_key', p_idempotency_key));

  /* The provider still holds a scheduled reduction for this unit; the change_branches command
     withdraws it (or, for a never-paid branch, starts the charge). */
  select * into v_subscription from public.subscriptions where business_id = p_business;
  if v_subscription.provider_subscription_id is not null and v_restored <> 'included' then
    v_cadence := coalesce(nullif(v_subscription.billing_cadence,''),'annual');
    select terms.customer_capacity into v_capacity
      from public.billing_subscription_terms_v124 terms where terms.business_id = p_business;
    if v_capacity is null then
      v_capacity := (app.billing_tier_for_capacity_v664(
        v_cadence,
        greatest(1,(select count(*)::integer from public.clients c where c.business_id = p_business))
      )).capacity_ceiling;
    end if;
    v_command := public.request_billing_command_v124(
      p_business,'change_branches',v_cadence,v_capacity,p_idempotency_key);
  end if;

  return jsonb_build_object(
    'status','ok','branch_id',p_branch,'branch_name',v_branch.name,
    'billing_state',v_restored,'command_id',v_command->>'command_id');
end
$function$;

comment on function public.business_resubscribe_branch_v665(uuid,uuid,uuid) is
  'nestly_v768: Keep returns a stopping branch to the state it was in — a paid branch stays on '
  'and paid until renewal; the change_branches command withdraws the provider''s scheduled '
  'reduction.';

revoke all on function public.business_resubscribe_branch_v665(uuid,uuid,uuid) from public, anon;
grant execute on function public.business_resubscribe_branch_v665(uuid,uuid,uuid) to authenticated;

commit;
