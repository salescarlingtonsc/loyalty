/* nestly_v665 — every branch is charged, and a branch can be unsubscribed on purpose.

   Owner rulings (2026-09-01, following the v664 tier wave):
     · "all branches must be charged - unless user switch it off. (there must be a unsubscribe
        button) and ask for confirmation ... each branches charged the same price as a company.
        so 1 main branch + 1 branch = 2 branch * 1188."
     · Unsubscribing takes effect AT THE END OF THE PAID PERIOD: the branch keeps trading until
       the date already paid for, is not renewed, and nothing is refunded.
     · The main branch MAY be unsubscribed as long as another branch remains — is_default moves
       to a survivor rather than the workspace being left without one.
     · Cubbly's two grandfathered branches stay free ("cubbly is my demo - leave it"), but
       "moving forward this cannot happen": no new branch may be born free.

   Three things this migration does.

   1. NO NEW FREE BRANCHES. branches.billing_state defaulted to 'included' — free forever — and
      SEVEN functions insert into that table. Five of them create the business's FIRST branch,
      which the base unit legitimately covers. public.commit_import_job does not: the Excel
      branch importer inserted extra branches with the default, so a firm could import ten live
      branches and pay for one. Rather than patching six function bodies (and missing the seventh
      written next month), a BEFORE INSERT trigger decides the state from the only fact that
      matters — whether the business already has a branch. The first is 'included'; every other
      is 'pending_payment' and switched off, exactly as business_add_branch_v202 already creates
      them. Existing rows are untouched, so the demo tenant keeps its grandfathered pair.

   2. UNSUBSCRIBE IS A STATE, NOT A DELETION. Two new billing states:
        'canceling'    — paid through billing_cancel_at, still trading, will not renew;
        'unsubscribed' — the date passed, switched off, not charged.
      The daily sweep moves the first to the second. Deleting the branch would have taken its
      appointments, staff assignments and reporting history with it, which is not what "stop
      paying for this shop" means.

   3. STRIPE IS TOLD ONCE, WITH THE RIGHT PRORATION. The unsubscribe mints an ordinary
      change_branches command; the edge function now chooses proration by DIRECTION — a branch
      added mid-period is invoiced for the remaining time (the owner's rule, unchanged), and a
      branch removed mid-period is not credited, it simply lowers the next invoice. One rule,
      no new command type, and the money matches what the page says on both sides.

   TWIN NAME: a parallel session shipped nestly_v665_gift_staging_and_reversal on the same day.
   Two different migrations carry the tag v665; the identities and deploy versions differ, so
   this is a version-number collision between sessions, not a conflict — the repo has recorded
   several of these before (v512, v513, v551).

   Rollback suite: db/tests/v665_branch_subscription_choice.sql */
begin;

-- =============================================================================================
-- 1. The two new states, the date the paid period runs to, and the state to come back to.
-- =============================================================================================
alter table public.branches
  add column if not exists billing_cancel_at timestamptz,
  add column if not exists billing_state_prior text;

alter table public.branches drop constraint if exists branches_billing_state_ck;
alter table public.branches add constraint branches_billing_state_ck
  check (billing_state = any (array['included','pending_payment','active','suspended','canceling','unsubscribed']));

alter table public.branches add constraint branches_billing_cancel_shape_v665
  check ((billing_state = 'canceling') = (billing_cancel_at is not null));

alter table public.branches alter column billing_state set default 'pending_payment';

-- =============================================================================================
-- 2. A branch is born paid-for or born off. Never free.
--    Ordered after aa_branches_inactive_shell_v510 (which owns `active` on insert) and before
--    everything else, so the state it assigns is the one the other guards then judge.
-- =============================================================================================
create or replace function app.assign_branch_billing_state_v665()
returns trigger
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $function$
declare v_has_branch boolean;
begin
  select exists(select 1 from public.branches existing
                 where existing.business_id = new.business_id)
    into v_has_branch;
  if not v_has_branch then
    /* The first branch of a business is the one the base unit of the plan pays for. */
    new.billing_state := 'included';
    new.billing_cancel_at := null;
    return new;
  end if;
  /* Every other branch is another unit of the plan. A caller may only choose between the states
     that mean "this one is being paid for" — anything else (including the old free default and
     any state an importer or a future writer forgets to set) becomes an unpaid, switched-off
     branch that the owner can pay for from the Branches page. */
  if new.billing_state is null or new.billing_state not in ('pending_payment','active') then
    new.billing_state := 'pending_payment';
  end if;
  if new.billing_state = 'pending_payment' then
    new.active := false;
  end if;
  new.billing_cancel_at := null;
  return new;
end
$function$;
revoke all on function app.assign_branch_billing_state_v665() from public, anon, authenticated;

drop trigger if exists ab_branches_billing_state_v665 on public.branches;
create trigger ab_branches_billing_state_v665
  before insert on public.branches
  for each row execute function app.assign_branch_billing_state_v665();

-- =============================================================================================
-- 3. Unsubscribe: confirmed by the owner, effective at the end of what they have paid for.
-- =============================================================================================
create or replace function public.business_unsubscribe_branch_v665(
  p_business uuid,
  p_branch uuid,
  p_idempotency_key uuid
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $function$
declare
  v_actor uuid := auth.uid();
  v_branch public.branches%rowtype;
  v_subscription public.subscriptions%rowtype;
  v_effective timestamptz;
  v_survivors integer;
  v_new_default uuid;
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
  if v_branch.billing_state in ('canceling','unsubscribed') then
    /* Already asked for. Replaying the same intent returns the same answer rather than a second
       billing command. */
    return jsonb_build_object(
      'status','replayed','branch_id',v_branch.id,'branch_name',v_branch.name,
      'billing_state',v_branch.billing_state,'effective_at',v_branch.billing_cancel_at);
  end if;
  if v_branch.billing_state = 'suspended' then
    raise exception 'this branch has already stopped for non-payment' using errcode = '22023';
  end if;

  select count(*)::integer into v_survivors
    from public.branches other
   where other.business_id = p_business and other.id <> p_branch
     and other.billing_state in ('included','pending_payment','active');
  if v_survivors = 0 then
    raise exception 'this is your only subscribed branch — cancel the subscription instead'
      using errcode = '22023';
  end if;

  select * into v_subscription from public.subscriptions where business_id = p_business;
  /* Nothing has been paid for a period that has not been paid: with no provider period the
     branch stops now rather than at a date that does not exist. */
  v_effective := coalesce(v_subscription.current_period_end, now());
  if v_effective < now() then v_effective := now(); end if;

  perform set_config('app.branch_authority_v621','on',true);
  perform set_config('app.v79_system_transition','on',true);

  update public.branches
     set billing_state = 'canceling',
         billing_state_prior = v_branch.billing_state,
         billing_cancel_at = v_effective,
         updated_at = now()
   where id = p_branch;

  /* The owner may unsubscribe the main branch as long as another remains (owner ruling). The
     default flag is not cosmetic — the v11a sales trigger backfills sales.branch_id from it — so
     it moves to the oldest survivor in the same transaction rather than being left dangling. */
  if v_branch.is_default then
    select other.id into v_new_default
      from public.branches other
     where other.business_id = p_business and other.id <> p_branch
       and other.billing_state in ('included','pending_payment','active')
     order by other.created_at
     limit 1;
    update public.branches set is_default = false, updated_at = now() where id = p_branch;
    update public.branches set is_default = true, updated_at = now() where id = v_new_default;
  end if;

  perform set_config('app.branch_authority_v621','off',true);
  perform set_config('app.v79_system_transition','off',true);

  insert into public.audit_log (business_id, actor, action, entity, entity_id, detail)
  values (p_business, v_actor, 'BRANCH_UNSUBSCRIBED_V665', 'branches', p_branch,
          jsonb_build_object(
            'branch_name', v_branch.name,
            'prior_state', v_branch.billing_state,
            'effective_at', v_effective,
            'moved_default_to', v_new_default,
            'operation_key', p_idempotency_key));

  /* Stripe is told now so the NEXT invoice is right; the edge function bills a reduction with
     no proration, which is what "no refund, stops at the end of the period" means in money. */
  if v_subscription.provider_subscription_id is not null then
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
    'billing_state','canceling','effective_at',v_effective,
    'moved_default_to',v_new_default,
    'command_id',v_command->>'command_id');
end
$function$;
revoke all on function public.business_unsubscribe_branch_v665(uuid,uuid,uuid) from public, anon;
grant execute on function public.business_unsubscribe_branch_v665(uuid,uuid,uuid) to service_role, authenticated;

-- =============================================================================================
-- 4. Changed their mind, before the date arrives.
-- =============================================================================================
create or replace function public.business_resubscribe_branch_v665(
  p_business uuid,
  p_branch uuid,
  p_idempotency_key uuid
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
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

  /* A branch that was already free stays free; anything else comes back as a paid branch that
     must be paid for again, because its unit was taken off the provider subscription. */
  v_restored := case when v_branch.billing_state_prior = 'included' then 'included'
                     else 'pending_payment' end;

  perform set_config('app.branch_authority_v621','on',true);
  perform set_config('app.v79_system_transition','on',true);
  update public.branches
     set billing_state = v_restored,
         billing_state_prior = null,
         billing_cancel_at = null,
         active = case when v_restored = 'included' then active else false end,
         updated_at = now()
   where id = p_branch;
  perform set_config('app.branch_authority_v621','off',true);
  perform set_config('app.v79_system_transition','off',true);

  insert into public.audit_log (business_id, actor, action, entity, entity_id, detail)
  values (p_business, v_actor, 'BRANCH_RESUBSCRIBED_V665', 'branches', p_branch,
          jsonb_build_object('branch_name', v_branch.name, 'restored_state', v_restored,
                             'operation_key', p_idempotency_key));

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
revoke all on function public.business_resubscribe_branch_v665(uuid,uuid,uuid) from public, anon;
grant execute on function public.business_resubscribe_branch_v665(uuid,uuid,uuid) to service_role, authenticated;

-- =============================================================================================
-- 5. The date arrives: the branch stops. Runs daily; catches up if a run is missed.
-- =============================================================================================
create or replace function app.run_branch_unsubscribe_sweep_v665()
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $function$
declare v_branch record; v_stopped integer := 0;
begin
  perform set_config('app.branch_authority_v621','on',true);
  perform set_config('app.v79_system_transition','on',true);
  for v_branch in
    select id, business_id, name from public.branches
     where billing_state = 'canceling' and billing_cancel_at <= now()
     order by billing_cancel_at
     limit 500
  loop
    update public.branches
       set billing_state = 'unsubscribed', billing_cancel_at = null,
           active = false, updated_at = now()
     where id = v_branch.id;
    v_stopped := v_stopped + 1;
    insert into public.audit_log (business_id, actor, action, entity, entity_id, detail)
    values (v_branch.business_id, null, 'BRANCH_UNSUBSCRIBE_TOOK_EFFECT_V665', 'branches',
            v_branch.id, jsonb_build_object('branch_name', v_branch.name));
  end loop;
  perform set_config('app.branch_authority_v621','off',true);
  perform set_config('app.v79_system_transition','off',true);
  return jsonb_build_object('stopped', v_stopped);
end
$function$;
revoke all on function app.run_branch_unsubscribe_sweep_v665() from public, anon, authenticated;

select cron.schedule('nestly-v665-branch-unsubscribe','5 20 * * *',
  $cron$select app.run_branch_unsubscribe_sweep_v665()$cron$)
 where not exists (select 1 from cron.job where jobname='nestly-v665-branch-unsubscribe');

commit;
