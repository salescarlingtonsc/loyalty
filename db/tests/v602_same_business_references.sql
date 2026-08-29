-- Acceptance suite for nestly_v602 -- "a child row may not point at another tenant's parent"
-- (SEC-02 batches B1 + B2).
--
-- Runs against PATCHED production inside begin/rollback; nothing persists. It applies nothing:
-- db/migrations/20260829_nestly_v602_same_business_references.sql must already be applied when
-- this runs. Against an UNPATCHED database it is expected to FAIL -- that is the point of it.
--
-- Two real businesses are discovered from live data: A is a business whose owner login can write
-- the appointments/services/waitlist/bookings modules and which owns an appointment, a service, a
-- product and a client; B is any OTHER business owning a service, a product, a client and an
-- appointment. Every behavioural cell then runs as the REAL `authenticated` role with
-- request.jwt.claims set to A's owner -- the strongest legitimate identity inside A -- never as
-- the MCP superuser: a rolled-back suite that keeps superuser rights bypasses both the table
-- GRANTs and RLS and would report green on an untouched database.
--
-- The properties under test:
--   S. structure  -- all 31 composite FKs exist, are VALIDATED, point at the stated parent and
--                    keep the ON DELETE action their simple FK had; the three new parent unique
--                    keys exist; the two derived business_id columns exist NOT NULL; the four
--                    derivation/immutability triggers exist; NOT ONE simple FK was dropped.
--   X. cross-tenant refusal -- for every B1 attachment, an A-owned child row referencing a
--                    B-owned parent UUID is refused (23503 foreign-key violation, or an RLS/
--                    privilege refusal, which is also a refusal).
--   P. same-business writes still succeed -- service_products, appointment_services, waitlist,
--                    booking_requests, change_requests and sales.
--   T. derived tenant column -- the BEFORE INSERT trigger fills business_id when the writer does
--                    not supply it (this is what keeps the existing PostgREST writers working),
--                    and moving a row to another tenant by UPDATE is refused.
--
-- Note on change_requests: the table has NO INSERT policy in production, so a browser INSERT is
-- refused by RLS whatever its parent. The X cell records that refusal; the P cell is therefore
-- run once as the table owner, purely to prove the new composite FK does not block a legitimate
-- same-business row. Both facts are labelled in the output rather than hidden.

begin;

create temp table _r(id text primary key, ok boolean, detail text) on commit drop;
grant all on _r to authenticated;

-- ============================================================================ fixture
do $fixture$
declare
  r record;
  v_owner uuid;
  v_a uuid;
  v_a_owner uuid;
  v_b uuid;
begin
  for r in
    select b.id
    from public.businesses b
    where exists (select 1 from public.appointments a where a.business_id = b.id)
      and exists (select 1 from public.services   s where s.business_id = b.id)
      and exists (select 1 from public.products   p where p.business_id = b.id)
      and exists (select 1 from public.clients    c where c.business_id = b.id)
      and exists (select 1 from public.staff      t where t.business_id = b.id)
      and exists (select 1 from public.branches   n where n.business_id = b.id)
    order by b.id
  loop
    select user_id into v_owner
      from public.staff
     where business_id = r.id and role = 'owner' and active
       and access_state = 'approved' and user_id is not null
     limit 1;
    if v_owner is null then continue; end if;

    perform set_config('request.jwt.claims',
      json_build_object('sub', v_owner, 'role', 'authenticated')::text, true);

    if app.can_module_write(r.id, 'appointments')
       and app.can_module_write(r.id, 'services')
       and app.can_module_write(r.id, 'waitlist')
       and app.can_module_write(r.id, 'bookings') then
      v_a := r.id;
      v_a_owner := v_owner;
      exit;
    end if;
  end loop;
  perform set_config('request.jwt.claims', null, true);

  if v_a is null then
    raise exception 'v602 suite: no business has an owner login that can write appointments/services/waitlist/bookings';
  end if;

  -- B: a DIFFERENT tenant owning every parent kind the negatives need
  select b.id into v_b
  from public.businesses b
  where b.id <> v_a
    and exists (select 1 from public.appointments a where a.business_id = b.id)
    and exists (select 1 from public.services   s where s.business_id = b.id)
    and exists (select 1 from public.products   p where p.business_id = b.id)
    and exists (select 1 from public.clients    c where c.business_id = b.id)
    and exists (select 1 from public.staff      t where t.business_id = b.id)
    and exists (select 1 from public.branches   n where n.business_id = b.id)
  order by b.id
  limit 1;

  if v_b is null then
    raise exception 'v602 suite: no second business owns a full parent set for the cross-tenant matrix';
  end if;

  perform set_config('test.a',       v_a::text,       true);
  perform set_config('test.a_owner', v_a_owner::text, true);
  perform set_config('test.b',       v_b::text,       true);

  perform set_config('test.a_appt',    (select id::text from public.appointments where business_id=v_a order by id limit 1), true);
  perform set_config('test.a_service', (select id::text from public.services     where business_id=v_a order by id limit 1), true);
  perform set_config('test.a_product', (select id::text from public.products     where business_id=v_a order by id limit 1), true);
  perform set_config('test.a_client',  (select id::text from public.clients      where business_id=v_a order by id limit 1), true);
  perform set_config('test.a_staff',   (select id::text from public.staff        where business_id=v_a order by id limit 1), true);
  perform set_config('test.a_branch',  (select id::text from public.branches     where business_id=v_a order by id limit 1), true);

  perform set_config('test.b_appt',    (select id::text from public.appointments where business_id=v_b order by id limit 1), true);
  perform set_config('test.b_service', (select id::text from public.services     where business_id=v_b order by id limit 1), true);
  perform set_config('test.b_product', (select id::text from public.products     where business_id=v_b order by id limit 1), true);
  perform set_config('test.b_client',  (select id::text from public.clients      where business_id=v_b order by id limit 1), true);
  perform set_config('test.b_staff',   (select id::text from public.staff        where business_id=v_b order by id limit 1), true);
  perform set_config('test.b_branch',  (select id::text from public.branches     where business_id=v_b order by id limit 1), true);

  -- booking_tables is EMPTY in production (0 rows platform-wide); the table_type_id cells are
  -- therefore structural only. If a row ever exists, the behavioural cells switch themselves on.
  perform set_config('test.b_table',
    coalesce((select id::text from public.booking_tables where business_id=v_b order by id limit 1), ''), true);
end
$fixture$;

-- ====================================================== S. structure: the 31 composite FKs
do $structure$
declare
  spec text[][] := array[
    -- constraint,                                        child table,               parent table,               ON DELETE (pg_constraint.confdeltype)
    ['appointment_services_appointment_business_fkey',    'appointment_services',    'appointments',             'c'],
    ['appointment_services_service_business_fkey',        'appointment_services',    'services',                 'r'],
    ['booking_requests_appointment_business_fkey',        'booking_requests',        'appointments',             'n'],
    ['booking_requests_branch_business_fkey',             'booking_requests',        'branches',                 'n'],
    ['booking_requests_service_business_fkey',            'booking_requests',        'services',                 'n'],
    ['booking_requests_staff_business_fkey',              'booking_requests',        'staff',                    'n'],
    ['booking_requests_table_type_business_fkey',         'booking_requests',        'booking_tables',           'n'],
    ['change_requests_appointment_business_fkey',         'change_requests',         'appointments',             'c'],
    ['reward_grants_client_business_fkey',                'reward_grants',           'clients',                  'c'],
    ['sales_appointment_business_fkey',                   'sales',                   'appointments',             'n'],
    ['sales_client_business_fkey',                        'sales',                   'clients',                  'n'],
    ['sales_product_business_fkey',                       'sales',                   'products',                 'n'],
    ['service_products_product_business_fkey',            'service_products',        'products',                 'c'],
    ['service_products_service_business_fkey',            'service_products',        'services',                 'c'],
    ['waitlist_client_business_fkey',                     'waitlist',                'clients',                  'n'],
    ['waitlist_service_business_fkey',                    'waitlist',                'services',                 'n'],
    ['waitlist_table_type_business_fkey',                 'waitlist',                'booking_tables',           'n'],
    ['branch_breaks_branch_business_fkey',                'branch_breaks',           'branches',                 'c'],
    ['branch_hours_branch_business_fkey',                 'branch_hours',            'branches',                 'c'],
    ['bringback_grants_v361_campaign_business_fkey',      'bringback_grants_v361',   'bringback_campaigns_v361', 'c'],
    ['bringback_grants_v361_client_business_fkey',        'bringback_grants_v361',   'clients',                  'c'],
    ['bringback_grants_v361_redeemed_sale_business_fkey', 'bringback_grants_v361',   'sales',                    'n'],
    ['client_packages_client_business_fkey',              'client_packages',         'clients',                  'c'],
    ['client_packages_plan_business_fkey',                'client_packages',         'package_plans',            'r'],
    ['points_batches_client_business_fkey',               'points_batches',          'clients',                  'c'],
    ['points_batches_programme_business_fkey',            'points_batches',          'business_programmes',      'r'],
    ['points_batches_sale_business_fkey',                 'points_batches',          'sales',                    'n'],
    ['staff_hours_staff_business_fkey',                   'staff_hours',             'staff',                    'c'],
    ['staff_invites_staff_business_fkey',                 'staff_invites',           'staff',                    'a'],
    ['staff_off_days_staff_business_fkey',                'staff_off_days',          'staff',                    'c'],
    ['staff_recurring_off_days_staff_business_fkey',      'staff_recurring_off_days','staff',                    'c']
  ];
  i int;
  v_missing text := '';
  v_unvalidated text := '';
  v_wrong text := '';
  c record;
begin
  for i in 1 .. array_length(spec, 1) loop
    select con.convalidated, con.confdeltype,
           con.confrelid                as parent_oid,
           con.confrelid::regclass::text as parent,
           array_length(con.conkey, 1)  as ncols
      into c
      from pg_constraint con
     where con.conname = spec[i][1]
       and con.conrelid = ('public.' || spec[i][2])::regclass
       and con.contype = 'f';

    if not found then
      v_missing := v_missing || spec[i][1] || ' ';
    else
      if not c.convalidated then
        v_unvalidated := v_unvalidated || spec[i][1] || ' ';
      end if;
      if c.parent_oid <> ('public.' || spec[i][3])::regclass
         or c.confdeltype <> spec[i][4]::"char"
         or c.ncols <> 2 then
        v_wrong := v_wrong || spec[i][1]
          || '(parent=' || c.parent || ' ondelete=' || c.confdeltype || ' cols=' || c.ncols || ') ';
      end if;
    end if;
  end loop;

  insert into _r values ('S1_all_31_composite_fks_present', v_missing = '',
    coalesce(nullif('missing: ' || v_missing, 'missing: '), 'all 31 present'));
  insert into _r values ('S2_all_31_validated', v_unvalidated = '',
    coalesce(nullif('NOT VALID: ' || v_unvalidated, 'NOT VALID: '), 'all 31 convalidated'));
  insert into _r values ('S3_parent_and_on_delete_preserved', v_wrong = '',
    coalesce(nullif('wrong: ' || v_wrong, 'wrong: '),
      'every composite is 2-column, points at the stated parent and keeps its simple FK ON DELETE action'));
end
$structure$;

do $structure2$
declare
  v_missing text;
begin
  -- S4: the three parent unique keys the migration had to create
  select string_agg(k, ', ') into v_missing
  from unnest(array[
    'booking_tables_id_business_key',
    'bringback_campaigns_v361_id_business_key',
    'package_plans_id_business_key'
  ]) k
  where not exists (select 1 from pg_constraint where conname = k and contype = 'u');
  insert into _r values ('S4_new_parent_unique_keys_present', v_missing is null,
    coalesce('missing: ' || v_missing, 'booking_tables, bringback_campaigns_v361 and package_plans each have (id, business_id)'));

  -- S5: nothing was dropped -- every simple FK the inventory named still stands
  select string_agg(k, ', ') into v_missing
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
  where not exists (select 1 from pg_constraint where conname = k and contype = 'f');
  insert into _r values ('S5_simple_fks_retained', v_missing is null,
    coalesce('dropped: ' || v_missing, 'all 31 original simple FKs still present -- the composite is additive'));

  -- S6: the derived tenant columns exist and are NOT NULL
  insert into _r values ('S6_derived_business_id_not_null',
    (select count(*) from pg_attribute
      where attrelid in ('public.appointment_services'::regclass,'public.service_products'::regclass)
        and attname = 'business_id' and attnotnull and not attisdropped) = 2,
    (select coalesce(string_agg(attrelid::regclass::text || '.business_id notnull=' || attnotnull::text, ', '), 'absent')
       from pg_attribute
      where attrelid in ('public.appointment_services'::regclass,'public.service_products'::regclass)
        and attname = 'business_id' and not attisdropped));

  -- S7: the four triggers
  select string_agg(k, ', ') into v_missing
  from unnest(array[
    'appointment_services_business_v602','appointment_services_business_immutable_v602',
    'service_products_business_v602','service_products_business_immutable_v602'
  ]) k
  where not exists (select 1 from pg_trigger where tgname = k and not tgisinternal);
  insert into _r values ('S7_derivation_and_immutability_triggers_present', v_missing is null,
    coalesce('missing: ' || v_missing, 'both derive-on-insert and both immutability triggers exist'));
end
$structure2$;

-- ================================================ X. cross-tenant refusal, as A's owner login
do $cross$
declare
  v_a       uuid := current_setting('test.a')::uuid;
  v_a_appt  uuid := current_setting('test.a_appt')::uuid;
  v_a_svc   uuid := current_setting('test.a_service')::uuid;
  v_b_appt  uuid := current_setting('test.b_appt')::uuid;
  v_b_svc   uuid := current_setting('test.b_service')::uuid;
  v_b_prod  uuid := current_setting('test.b_product')::uuid;
  v_b_cli   uuid := current_setting('test.b_client')::uuid;
  v_b_staff uuid := current_setting('test.b_staff')::uuid;
  v_b_brnch uuid := current_setting('test.b_branch')::uuid;
  v_b_table text := current_setting('test.b_table');
  v_rows    int;
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', current_setting('test.a_owner'), 'role', 'authenticated')::text, true);
  set local role authenticated;

  -- X1: A's appointment given B's service
  begin
    insert into public.appointment_services(appointment_id, service_id, price_cents)
      values (v_a_appt, v_b_svc, 1000);
    insert into _r values ('X1_appointment_services_foreign_service', false, 'INSERT succeeded -- it must not');
  exception
    when foreign_key_violation then
      insert into _r values ('X1_appointment_services_foreign_service', true, 'refused 23503');
    when insufficient_privilege or check_violation then
      insert into _r values ('X1_appointment_services_foreign_service', true, 'refused '||sqlstate);
    when others then
      insert into _r values ('X1_appointment_services_foreign_service', sqlstate in ('42501','23514'),
        'refused '||sqlstate||': '||sqlerrm);
  end;

  -- X2: B's appointment given A's service (the mirror -- and RLS alone would already refuse this)
  begin
    insert into public.appointment_services(appointment_id, service_id, price_cents)
      values (v_b_appt, v_a_svc, 1000);
    insert into _r values ('X2_appointment_services_foreign_appointment', false, 'INSERT succeeded -- it must not');
  exception when others then
    insert into _r values ('X2_appointment_services_foreign_appointment', true, 'refused '||sqlstate);
  end;

  -- X3: A's service linked to B's product
  begin
    insert into public.service_products(service_id, product_id, qty) values (v_a_svc, v_b_prod, 1);
    insert into _r values ('X3_service_products_foreign_product', false, 'INSERT succeeded -- it must not');
  exception when others then
    insert into _r values ('X3_service_products_foreign_product', sqlstate in ('23503','42501','23514'),
      'refused '||sqlstate);
  end;

  -- X4..X8: booking_requests -- one foreign parent at a time
  begin
    insert into public.booking_requests(business_id, name, appointment_id) values (v_a, 'v602 suite', v_b_appt);
    insert into _r values ('X4_booking_requests_foreign_appointment', false, 'INSERT succeeded -- it must not');
  exception when others then
    insert into _r values ('X4_booking_requests_foreign_appointment', sqlstate in ('23503','42501','23514'), 'refused '||sqlstate);
  end;
  begin
    insert into public.booking_requests(business_id, name, branch_id) values (v_a, 'v602 suite', v_b_brnch);
    insert into _r values ('X5_booking_requests_foreign_branch', false, 'INSERT succeeded -- it must not');
  exception when others then
    insert into _r values ('X5_booking_requests_foreign_branch', sqlstate in ('23503','42501','23514'), 'refused '||sqlstate);
  end;
  begin
    insert into public.booking_requests(business_id, name, service_id) values (v_a, 'v602 suite', v_b_svc);
    insert into _r values ('X6_booking_requests_foreign_service', false, 'INSERT succeeded -- it must not');
  exception when others then
    insert into _r values ('X6_booking_requests_foreign_service', sqlstate in ('23503','42501','23514'), 'refused '||sqlstate);
  end;
  begin
    insert into public.booking_requests(business_id, name, staff_id) values (v_a, 'v602 suite', v_b_staff);
    insert into _r values ('X7_booking_requests_foreign_staff', false, 'INSERT succeeded -- it must not');
  exception when others then
    insert into _r values ('X7_booking_requests_foreign_staff', sqlstate in ('23503','42501','23514'), 'refused '||sqlstate);
  end;
  if v_b_table <> '' then
    begin
      insert into public.booking_requests(business_id, name, table_type_id) values (v_a, 'v602 suite', v_b_table::uuid);
      insert into _r values ('X8_booking_requests_foreign_table', false, 'INSERT succeeded -- it must not');
    exception when others then
      insert into _r values ('X8_booking_requests_foreign_table', sqlstate in ('23503','42501','23514'), 'refused '||sqlstate);
    end;
  else
    insert into _r values ('X8_booking_requests_foreign_table', true,
      'no booking_tables row exists platform-wide; covered structurally by S1-S3 (booking_requests_table_type_business_fkey)');
  end if;

  -- X9: change_requests against B's appointment. There is no INSERT policy on this table in
  --     production, so RLS refuses it before the FK is reached; either refusal is a pass.
  begin
    insert into public.change_requests(business_id, appointment_id, kind)
      values (v_a, v_b_appt, 'reschedule');
    insert into _r values ('X9_change_requests_foreign_appointment', false, 'INSERT succeeded -- it must not');
  exception when others then
    insert into _r values ('X9_change_requests_foreign_appointment', sqlstate in ('23503','42501','23514'),
      'refused '||sqlstate||' (no INSERT policy exists on change_requests; RLS refuses first)');
  end;

  -- X10: reward_grants against B's client. v599 already revoked the browser write verbs, so this
  --      is refused at privilege level; the composite FK is the structural backstop (S1-S3).
  begin
    insert into public.reward_grants(business_id, client_id, status) values (v_a, v_b_cli, 'granted');
    insert into _r values ('X10_reward_grants_foreign_client', false, 'INSERT succeeded -- it must not');
  exception when others then
    insert into _r values ('X10_reward_grants_foreign_client', sqlstate in ('23503','42501','23514'),
      'refused '||sqlstate||' (v599 removed the browser INSERT grant; FK is the structural backstop)');
  end;

  -- X11..X13: sales -- three independent foreign parents
  begin
    insert into public.sales(business_id, kind, amount_cents, client_id) values (v_a, 'service', 0, v_b_cli);
    insert into _r values ('X11_sales_foreign_client', false, 'INSERT succeeded -- it must not');
  exception when others then
    insert into _r values ('X11_sales_foreign_client', sqlstate in ('23503','42501','23514'), 'refused '||sqlstate);
  end;
  begin
    insert into public.sales(business_id, kind, amount_cents, appointment_id) values (v_a, 'service', 0, v_b_appt);
    insert into _r values ('X12_sales_foreign_appointment', false, 'INSERT succeeded -- it must not');
  exception when others then
    insert into _r values ('X12_sales_foreign_appointment', sqlstate in ('23503','42501','23514'), 'refused '||sqlstate);
  end;
  begin
    insert into public.sales(business_id, kind, amount_cents, product_id) values (v_a, 'retail', 0, v_b_prod);
    insert into _r values ('X13_sales_foreign_product', false, 'INSERT succeeded -- it must not');
  exception when others then
    insert into _r values ('X13_sales_foreign_product', sqlstate in ('23503','42501','23514'), 'refused '||sqlstate);
  end;

  -- X14..X16: waitlist
  begin
    insert into public.waitlist(business_id, name, client_id) values (v_a, 'v602 suite', v_b_cli);
    insert into _r values ('X14_waitlist_foreign_client', false, 'INSERT succeeded -- it must not');
  exception when others then
    insert into _r values ('X14_waitlist_foreign_client', sqlstate in ('23503','42501','23514'), 'refused '||sqlstate);
  end;
  begin
    insert into public.waitlist(business_id, name, service_id) values (v_a, 'v602 suite', v_b_svc);
    insert into _r values ('X15_waitlist_foreign_service', false, 'INSERT succeeded -- it must not');
  exception when others then
    insert into _r values ('X15_waitlist_foreign_service', sqlstate in ('23503','42501','23514'), 'refused '||sqlstate);
  end;
  if v_b_table <> '' then
    begin
      insert into public.waitlist(business_id, name, table_type_id) values (v_a, 'v602 suite', v_b_table::uuid);
      insert into _r values ('X16_waitlist_foreign_table', false, 'INSERT succeeded -- it must not');
    exception when others then
      insert into _r values ('X16_waitlist_foreign_table', sqlstate in ('23503','42501','23514'), 'refused '||sqlstate);
    end;
  else
    insert into _r values ('X16_waitlist_foreign_table', true,
      'no booking_tables row exists platform-wide; covered structurally by S1-S3 (waitlist_table_type_business_fkey)');
  end if;

  -- X17: the UPDATE half -- a legitimate A row, created here so the cell can never pass vacuously,
  --      cannot afterwards be re-pointed at a B-owned client.
  declare
    v_wl uuid;
  begin
    insert into public.waitlist(business_id, name, client_id)
      values (v_a, 'v602 suite repoint probe', current_setting('test.a_client')::uuid)
      returning id into v_wl;
    begin
      update public.waitlist set client_id = v_b_cli where id = v_wl;
      get diagnostics v_rows = row_count;
      insert into _r values ('X17_waitlist_repoint_to_foreign_client_refused', false,
        'UPDATE was permitted -- rows_updated=' || v_rows);
    exception when others then
      insert into _r values ('X17_waitlist_repoint_to_foreign_client_refused',
        sqlstate in ('23503','42501','23514'), 'refused '||sqlstate);
    end;
  exception when others then
    insert into _r values ('X17_waitlist_repoint_to_foreign_client_refused', false,
      'probe row could not be created: '||sqlstate||': '||sqlerrm);
  end;

  reset role;
  perform set_config('request.jwt.claims', null, true);
end
$cross$;

-- ============================================== P. same-business writes still succeed
do $same$
declare
  v_a      uuid := current_setting('test.a')::uuid;
  v_a_appt uuid := current_setting('test.a_appt')::uuid;
  v_a_svc  uuid := current_setting('test.a_service')::uuid;
  v_a_prod uuid := current_setting('test.a_product')::uuid;
  v_a_cli  uuid := current_setting('test.a_client')::uuid;
  v_a_stf  uuid := current_setting('test.a_staff')::uuid;
  v_a_brn  uuid := current_setting('test.a_branch')::uuid;
  v_id     uuid;
  v_biz    uuid;
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', current_setting('test.a_owner'), 'role', 'authenticated')::text, true);
  set local role authenticated;

  -- P1 + T1: appointment_services -- the writer supplies no business_id; the trigger derives it
  begin
    insert into public.appointment_services(appointment_id, service_id, price_cents)
      values (v_a_appt, v_a_svc, 1234)
      on conflict (appointment_id, service_id) do update set price_cents = excluded.price_cents;
    select business_id into v_biz from public.appointment_services
      where appointment_id = v_a_appt and service_id = v_a_svc;
    insert into _r values ('P1_appointment_services_same_business_insert', true, 'insert/upsert accepted');
    insert into _r values ('T1_appointment_services_business_derived', v_biz = v_a,
      'derived business_id = ' || coalesce(v_biz::text, 'null') || ' (expected ' || v_a::text || ')');
  exception when others then
    insert into _r values ('P1_appointment_services_same_business_insert', false, 'refused '||sqlstate||': '||sqlerrm);
    insert into _r values ('T1_appointment_services_business_derived', false, 'not reached: '||sqlstate);
  end;

  -- P2 + T2: service_products, through the exact PostgREST upsert the Services screen issues
  begin
    insert into public.service_products(service_id, product_id, qty)
      values (v_a_svc, v_a_prod, 2)
      on conflict (service_id, product_id) do update set qty = excluded.qty;
    select business_id into v_biz from public.service_products
      where service_id = v_a_svc and product_id = v_a_prod;
    insert into _r values ('P2_service_products_same_business_upsert', true, 'upsert accepted');
    insert into _r values ('T2_service_products_business_derived', v_biz = v_a,
      'derived business_id = ' || coalesce(v_biz::text, 'null') || ' (expected ' || v_a::text || ')');
  exception when others then
    insert into _r values ('P2_service_products_same_business_upsert', false, 'refused '||sqlstate||': '||sqlerrm);
    insert into _r values ('T2_service_products_business_derived', false, 'not reached: '||sqlstate);
  end;

  -- T3: moving that row to another tenant by UPDATE is refused by the immutability trigger
  begin
    update public.service_products set business_id = current_setting('test.b')::uuid
     where service_id = v_a_svc and product_id = v_a_prod;
    insert into _r values ('T3_service_products_business_immutable', false, 'UPDATE was permitted -- it must not be');
  exception when others then
    insert into _r values ('T3_service_products_business_immutable', sqlstate in ('23514','23503','42501'),
      'refused '||sqlstate||': '||sqlerrm);
  end;

  -- T4: an UPDATE that merely restates the same business_id must still pass (PostgREST upserts
  --     do exactly this whenever the payload happens to carry the column)
  begin
    update public.service_products set business_id = v_a, qty = 3
     where service_id = v_a_svc and product_id = v_a_prod;
    insert into _r values ('T4_service_products_same_value_update_allowed', true, 'same-value update accepted');
  exception when others then
    insert into _r values ('T4_service_products_same_value_update_allowed', false, 'refused '||sqlstate||': '||sqlerrm);
  end;

  -- P3: waitlist, all three references same-business
  begin
    insert into public.waitlist(business_id, name, client_id, service_id)
      values (v_a, 'v602 suite', v_a_cli, v_a_svc) returning id into v_id;
    insert into _r values ('P3_waitlist_same_business_insert', v_id is not null, 'waitlist row '||coalesce(v_id::text,'null'));
  exception when others then
    insert into _r values ('P3_waitlist_same_business_insert', false, 'refused '||sqlstate||': '||sqlerrm);
  end;

  -- P4: booking_requests, four same-business references at once
  begin
    insert into public.booking_requests(business_id, name, appointment_id, branch_id, service_id, staff_id)
      values (v_a, 'v602 suite', v_a_appt, v_a_brn, v_a_svc, v_a_stf) returning id into v_id;
    insert into _r values ('P4_booking_requests_same_business_insert', v_id is not null,
      'booking_requests row '||coalesce(v_id::text,'null'));
  exception when others then
    insert into _r values ('P4_booking_requests_same_business_insert', false, 'refused '||sqlstate||': '||sqlerrm);
  end;

  -- P5: the optional references may still be NULL -- MATCH SIMPLE is preserved
  begin
    insert into public.booking_requests(business_id, name) values (v_a, 'v602 suite null refs') returning id into v_id;
    insert into _r values ('P5_booking_requests_null_references_allowed', v_id is not null,
      'a request with every optional reference NULL is still accepted (MATCH SIMPLE preserved)');
  exception when others then
    insert into _r values ('P5_booking_requests_null_references_allowed', false, 'refused '||sqlstate||': '||sqlerrm);
  end;

  -- P6: sales with all three same-business references
  begin
    insert into public.sales(business_id, kind, amount_cents, client_id, appointment_id)
      values (v_a, 'service', 100, v_a_cli, v_a_appt) returning id into v_id;
    insert into _r values ('P6_sales_same_business_insert', v_id is not null, 'sale '||coalesce(v_id::text,'null'));
  exception when others then
    insert into _r values ('P6_sales_same_business_insert', false, 'refused '||sqlstate||': '||sqlerrm);
  end;

  reset role;
  perform set_config('request.jwt.claims', null, true);
end
$same$;

-- P7: change_requests has no INSERT policy, so no browser identity can create one. The composite
--     FK must still accept a legitimate same-business row through the owning role -- this proves
--     v602 did not break the server-side path that does create them.
do $same_owner$
declare
  v_a      uuid := current_setting('test.a')::uuid;
  v_a_appt uuid := current_setting('test.a_appt')::uuid;
  v_id     uuid;
begin
  insert into public.change_requests(business_id, appointment_id, kind)
    values (v_a, v_a_appt, 'reschedule') returning id into v_id;
  insert into _r values ('P7_change_requests_same_business_insert', v_id is not null,
    'same-business change request accepted through the owning role: '||coalesce(v_id::text,'null'));
exception when others then
  insert into _r values ('P7_change_requests_same_business_insert', false, 'refused '||sqlstate||': '||sqlerrm);
end
$same_owner$;

select id, case when ok then 'PASS' else 'FAIL' end as result, detail from _r order by id;

rollback;
