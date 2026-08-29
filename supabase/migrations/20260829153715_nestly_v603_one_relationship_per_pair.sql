-- nestly_v603 -- exactly one relationship per table pair (P0 hotfix for the v602 PGRST201 regression).
--
-- v602 added 31 same-business composite FKs while KEEPING the original simple FKs ("step 6 --
-- remove the redundant simple FK -- is deliberately a separate migration"). That was correct for
-- rollback hygiene but wrong for PostgREST: two foreign keys between the same pair of tables make
-- every embed ambiguous, and PostgREST refuses with PGRST201 ("more than one relationship was
-- found") rather than guessing. Live impact observed on the Bookings screen within minutes of
-- v602 applying: booking_requests->services, change_requests->appointments; the same ambiguity
-- also hits waitlist->services, sales->clients and service_products->services embeds.
--
-- The fix is v602's own step 6, promoted to now: drop the 31 redundant simple FKs. Nothing is
-- lost -- each composite FK is strictly as strong on every axis the simple FK covered:
--   * existence: business_id is NOT NULL on every child, so a non-null reference column is always
--     checked against the parent (MATCH SIMPLE only skips when a referencing column is NULL,
--     which is exactly when the simple FK skipped too);
--   * ON DELETE: preserved verb-for-verb by v602, with SET NULL column-scoped so only the
--     reference is nulled;
--   * embeds: PostgREST resolves a single remaining (composite) FK per pair unambiguously --
--     no app-side !fkey pins reference any of the 31 dropped names (verified by grep across
--     app/*.js and edge functions before writing this).
--
-- Guarded: each drop runs ONLY after proving the matching composite FK exists AND is validated.
-- If any composite is missing this migration aborts leaving the simple FK in place -- it never
-- leaves a pair with zero relationships.
--
-- Rollback: re-add the 31 simple FKs by name (their exact definitions are recorded in
-- docs/qa/audit-artifacts/tenant-simple-fk-inventory-2026-08-29.csv).

begin;

do $guard$
declare
  pair text[];
  pairs text[][] := array[
    ['appointment_services',     'appointment_services_appointment_id_fkey',        'appointment_services_appointment_business_fkey'],
    ['appointment_services',     'appointment_services_service_id_fkey',            'appointment_services_service_business_fkey'],
    ['booking_requests',         'booking_requests_appointment_id_fkey',            'booking_requests_appointment_business_fkey'],
    ['booking_requests',         'booking_requests_branch_id_fkey',                 'booking_requests_branch_business_fkey'],
    ['booking_requests',         'booking_requests_service_id_fkey',                'booking_requests_service_business_fkey'],
    ['booking_requests',         'booking_requests_staff_id_fkey',                  'booking_requests_staff_business_fkey'],
    ['booking_requests',         'booking_requests_table_type_id_fkey',             'booking_requests_table_type_business_fkey'],
    ['change_requests',          'change_requests_appointment_id_fkey',             'change_requests_appointment_business_fkey'],
    ['reward_grants',            'reward_grants_client_id_fkey',                    'reward_grants_client_business_fkey'],
    ['sales',                    'sales_appointment_id_fkey',                       'sales_appointment_business_fkey'],
    ['sales',                    'sales_client_id_fkey',                            'sales_client_business_fkey'],
    ['sales',                    'sales_product_id_fkey',                           'sales_product_business_fkey'],
    ['service_products',         'service_products_product_id_fkey',                'service_products_product_business_fkey'],
    ['service_products',         'service_products_service_id_fkey',                'service_products_service_business_fkey'],
    ['waitlist',                 'waitlist_client_id_fkey',                         'waitlist_client_business_fkey'],
    ['waitlist',                 'waitlist_service_id_fkey',                        'waitlist_service_business_fkey'],
    ['waitlist',                 'waitlist_table_type_id_fkey',                     'waitlist_table_type_business_fkey'],
    ['branch_breaks',            'branch_breaks_branch_id_fkey',                    'branch_breaks_branch_business_fkey'],
    ['branch_hours',             'branch_hours_branch_id_fkey',                     'branch_hours_branch_business_fkey'],
    ['bringback_grants_v361',    'bringback_grants_v361_campaign_id_fkey',          'bringback_grants_v361_campaign_business_fkey'],
    ['bringback_grants_v361',    'bringback_grants_v361_client_id_fkey',            'bringback_grants_v361_client_business_fkey'],
    ['bringback_grants_v361',    'bringback_grants_v361_redeemed_sale_id_fkey',     'bringback_grants_v361_redeemed_sale_business_fkey'],
    ['client_packages',          'client_packages_client_id_fkey',                  'client_packages_client_business_fkey'],
    ['client_packages',          'client_packages_plan_id_fkey',                    'client_packages_plan_business_fkey'],
    ['points_batches',           'points_batches_client_id_fkey',                   'points_batches_client_business_fkey'],
    ['points_batches',           'points_batches_programme_fk',                     'points_batches_programme_business_fkey'],
    ['points_batches',           'points_batches_sale_id_fkey',                     'points_batches_sale_business_fkey'],
    ['staff_hours',              'staff_hours_staff_id_fkey',                       'staff_hours_staff_business_fkey'],
    ['staff_invites',            'staff_invites_staff_id_fkey',                     'staff_invites_staff_business_fkey'],
    ['staff_off_days',           'staff_off_days_staff_id_fkey',                    'staff_off_days_staff_business_fkey'],
    ['staff_recurring_off_days', 'staff_recurring_off_days_staff_id_fkey',          'staff_recurring_off_days_staff_business_fkey']
  ];
begin
  foreach pair slice 1 in array pairs loop
    if not exists (
      select 1 from pg_constraint
       where conname = pair[3]
         and conrelid = ('public.' || pair[1])::regclass
         and contype = 'f' and convalidated
    ) then
      raise exception 'v603: composite FK % on %.% is missing or NOT VALID -- refusing to drop the simple FK %',
        pair[3], 'public', pair[1], pair[2];
    end if;
    execute format('alter table public.%I drop constraint if exists %I', pair[1], pair[2]);
  end loop;
end
$guard$;

do $post$
declare
  v_left text;
begin
  -- exactly one FK must remain for each of the 31 (child, referenced-columns) relationships
  select string_agg(distinct conrelid::regclass::text, ', ') into v_left
  from pg_constraint
  where contype = 'f'
    and conname in (
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
    );
  if v_left is not null then
    raise exception 'v603: simple FKs survived the drop on: %', v_left;
  end if;
end
$post$;

commit;
