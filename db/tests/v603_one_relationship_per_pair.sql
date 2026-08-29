-- Acceptance suite for nestly_v603 -- exactly one relationship per table pair.
--
-- Runs against PATCHED production inside begin/rollback. The PGRST201 half of the fix (embeds
-- resolve again) is a PostgREST parse-layer behaviour and was proven by REST probes on all seven
-- affected pairs immediately after apply; SQL can only prove the catalog half, which it does here:
-- every one of the 31 redundant simple FKs is gone, every composite survivor is validated, and no
-- (child, parent) pair among the 31 carries more than one foreign key.

begin;

do $t$
declare
  v_bad text;
begin
  -- 1. all 31 simple FKs are gone
  select string_agg(k, ', ') into v_bad
  from unnest(array[
    'appointment_services_appointment_id_fkey','appointment_services_service_id_fkey',
    'booking_requests_appointment_id_fkey','booking_requests_branch_id_fkey',
    'booking_requests_service_id_fkey','booking_requests_staff_id_fkey',
    'booking_requests_table_type_id_fkey','change_requests_appointment_id_fkey',
    'reward_grants_client_id_fkey','sales_appointment_id_fkey','sales_client_id_fkey',
    'sales_product_id_fkey','service_products_product_id_fkey','service_products_service_id_fkey',
    'waitlist_client_id_fkey','waitlist_service_id_fkey','waitlist_table_type_id_fkey',
    'branch_breaks_branch_id_fkey','branch_hours_branch_id_fkey',
    'bringback_grants_v361_campaign_id_fkey','bringback_grants_v361_client_id_fkey',
    'bringback_grants_v361_redeemed_sale_id_fkey','client_packages_client_id_fkey',
    'client_packages_plan_id_fkey','points_batches_client_id_fkey','points_batches_programme_fk',
    'points_batches_sale_id_fkey','staff_hours_staff_id_fkey','staff_invites_staff_id_fkey',
    'staff_off_days_staff_id_fkey','staff_recurring_off_days_staff_id_fkey'
  ]) k
  where exists (select 1 from pg_constraint where conname = k and contype = 'f');
  if v_bad is not null then
    raise exception 'v603: redundant simple FKs still present: %', v_bad;
  end if;

  -- 2. all 31 composite FKs remain and are validated
  select string_agg(k, ', ') into v_bad
  from unnest(array[
    'appointment_services_appointment_business_fkey','appointment_services_service_business_fkey',
    'booking_requests_appointment_business_fkey','booking_requests_branch_business_fkey',
    'booking_requests_service_business_fkey','booking_requests_staff_business_fkey',
    'booking_requests_table_type_business_fkey','change_requests_appointment_business_fkey',
    'reward_grants_client_business_fkey','sales_appointment_business_fkey',
    'sales_client_business_fkey','sales_product_business_fkey',
    'service_products_product_business_fkey','service_products_service_business_fkey',
    'waitlist_client_business_fkey','waitlist_service_business_fkey',
    'waitlist_table_type_business_fkey','branch_breaks_branch_business_fkey',
    'branch_hours_branch_business_fkey','bringback_grants_v361_campaign_business_fkey',
    'bringback_grants_v361_client_business_fkey','bringback_grants_v361_redeemed_sale_business_fkey',
    'client_packages_client_business_fkey','client_packages_plan_business_fkey',
    'points_batches_client_business_fkey','points_batches_programme_business_fkey',
    'points_batches_sale_business_fkey','staff_hours_staff_business_fkey',
    'staff_invites_staff_business_fkey','staff_off_days_staff_business_fkey',
    'staff_recurring_off_days_staff_business_fkey'
  ]) k
  where not exists (select 1 from pg_constraint where conname = k and contype = 'f' and convalidated);
  if v_bad is not null then
    raise exception 'v603: composite FKs missing or NOT VALID: %', v_bad;
  end if;

  -- 3. no affected (child, parent) pair carries more than one FK any more.
  --    reward_grants -> retention_programs is excluded: it has a PRE-EXISTING same-column
  --    duplicate (reward_grants_program_id_fkey + reward_grants_program_business_fk) that
  --    predates v602, is tolerated because reward-grant reads are RPC-only, and belongs to the
  --    platform-wide same-column-duplicate cleanup batch, not this hotfix.
  select string_agg(c || ' -> ' || p || ' (' || n || ')', ', ') into v_bad
  from (
    select conrelid::regclass::text c, confrelid::regclass::text p, count(*) n
    from pg_constraint
    where contype = 'f'
      and conrelid::regclass::text in (
        'appointment_services','booking_requests','change_requests','reward_grants','sales',
        'service_products','waitlist','branch_breaks','branch_hours','bringback_grants_v361',
        'client_packages','points_batches','staff_hours','staff_invites','staff_off_days',
        'staff_recurring_off_days')
    group by 1, 2
    having count(*) > 1
  ) d
  where not (c = 'reward_grants' and p = 'retention_programs');
  if v_bad is not null then
    raise exception 'v603: a pair still carries multiple FKs (PGRST201 would return): %', v_bad;
  end if;

  raise notice 'v603 suite: 31 simple FKs gone, 31 composites validated, one relationship per pair';
end
$t$;

rollback;
