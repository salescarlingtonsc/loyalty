\pset tuples_only on
\pset format unaligned
\pset footer off
\pset pager off

/*
  Supabase cutover reconciliation gate.
  Read-only by design: count(*) and aggregate-only business UUID metrics.
  No customer PII, names, emails, phone numbers, notes, auth hashes, tokens, raw cron commands,
  gift card codes, or storage object names are emitted.
*/

with
params as (
  select :'gate_scope'::text as scope,
         :'gate_project_ref'::text as project_ref
),
tracked_tables(table_name) as (
  values
    ('businesses'), ('staff'), ('clients'), ('sales'), ('appointments'),
    ('booking_requests'), ('payments'), ('expenses'), ('credit_ledger'),
    ('points_ledger'), ('points_batches'), ('gift_cards'), ('memberships'),
    ('membership_plans'), ('client_packages'), ('package_plans'), ('branches'),
    ('staff_branches'), ('service_branches'), ('services'), ('products'),
    ('cash_drawer_sessions'), ('cash_drawer_movements'), ('expense_recurrences'),
    ('subscriptions'), ('module_templates'), ('staff_invites'), ('consents'),
    ('booking_tables'), ('notifications'), ('waitlist')
),
entity_counts_section as (
  select coalesce(jsonb_agg(jsonb_build_object(
           'schema_name', 'public',
           'table_name', table_name,
           'table_exists', to_regclass(format('public.%I', table_name)) is not null,
           'row_count', case
             when to_regclass(format('public.%I', table_name)) is null then null
             else ((xpath('/row/c/text()', query_to_xml(
               format('select count(*)::bigint as c from public.%I', table_name),
               false, true, ''
             )))[1])::text::bigint
           end
         ) order by table_name), '[]'::jsonb) as data
  from tracked_tables
),
tenant_aggregates_section as (
  select case
    when to_regclass('public.businesses') is null then '[]'::jsonb
    else coalesce(
      ((xpath('/row/payload/text()', query_to_xml(
        'select coalesce(jsonb_agg(to_jsonb(t) order by business_id), ''[]''::jsonb)::text as payload from (select b.id::text as business_id' ||
        case when to_regclass('public.staff') is not null
          then ', (select count(*)::bigint from public.staff x where x.business_id = b.id) as staff_count'
          else ', null::bigint as staff_count' end ||
        case when to_regclass('public.clients') is not null
          then ', (select count(*)::bigint from public.clients x where x.business_id = b.id) as client_count'
          else ', null::bigint as client_count' end ||
        case when to_regclass('public.sales') is not null
          then ', (select count(*)::bigint from public.sales x where x.business_id = b.id) as sales_count'
          else ', null::bigint as sales_count' end ||
        case when to_regclass('public.sales') is not null
               and exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'sales' and column_name = 'amount_cents')
          then ', (select coalesce(sum(amount_cents),0)::bigint from public.sales x where x.business_id = b.id) as sales_amount_cents'
          else ', null::bigint as sales_amount_cents' end ||
        case when to_regclass('public.sales') is not null
               and exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'sales' and column_name = 'counts_as_revenue')
               and exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'sales' and column_name = 'amount_cents')
          then ', (select coalesce(sum(amount_cents) filter (where counts_as_revenue),0)::bigint from public.sales x where x.business_id = b.id) as accrual_revenue_cents'
          else ', null::bigint as accrual_revenue_cents' end ||
        case when to_regclass('public.appointments') is not null
          then ', (select count(*)::bigint from public.appointments x where x.business_id = b.id) as appointment_count'
          else ', null::bigint as appointment_count' end ||
        case when to_regclass('public.booking_requests') is not null
          then ', (select count(*)::bigint from public.booking_requests x where x.business_id = b.id) as booking_request_count'
          else ', null::bigint as booking_request_count' end ||
        case when to_regclass('public.payments') is not null
               and exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'payments' and column_name = 'amount_cents')
          then ', (select coalesce(sum(amount_cents),0)::bigint from public.payments x where x.business_id = b.id) as payment_amount_cents'
          else ', null::bigint as payment_amount_cents' end ||
        case when to_regclass('public.gift_cards') is not null
               and exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'gift_cards' and column_name = 'balance_cents')
          then ', (select coalesce(sum(balance_cents),0)::bigint from public.gift_cards x where x.business_id = b.id) as gift_card_liability_cents'
          else ', null::bigint as gift_card_liability_cents' end ||
        case when to_regclass('public.credit_ledger') is not null
               and exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'credit_ledger' and column_name = 'entry_type')
               and exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'credit_ledger' and column_name = 'amount_cents')
          then ', (select coalesce(sum(amount_cents) filter (where entry_type = ''membership_credit''),0)::bigint from public.credit_ledger x where x.business_id = b.id) as member_credit_liability_cents'
          else ', null::bigint as member_credit_liability_cents' end ||
        case when to_regclass('public.memberships') is not null
               and exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'memberships' and column_name = 'status')
          then ', (select count(*)::bigint from public.memberships x where x.business_id = b.id and x.status in (''active'', ''paused'', ''cancel_at_period_end'')) as active_member_count'
          else ', null::bigint as active_member_count' end ||
        ' from public.businesses b) t',
        false, true, ''
      )))[1])::text::jsonb,
      '[]'::jsonb
    )
  end as data
),
orphan_specs(check_name, required_relations, count_sql) as (
  values
    ('staff_missing_business', array['public.staff','public.businesses'], 'select count(*)::bigint from public.staff x left join public.businesses b on b.id = x.business_id where b.id is null'),
    ('clients_missing_business', array['public.clients','public.businesses'], 'select count(*)::bigint from public.clients x left join public.businesses b on b.id = x.business_id where b.id is null'),
    ('sales_missing_business', array['public.sales','public.businesses'], 'select count(*)::bigint from public.sales x left join public.businesses b on b.id = x.business_id where b.id is null'),
    ('appointments_missing_business', array['public.appointments','public.businesses'], 'select count(*)::bigint from public.appointments x left join public.businesses b on b.id = x.business_id where b.id is null'),
    ('sales_client_cross_tenant', array['public.sales','public.clients'], 'select count(*)::bigint from public.sales s join public.clients c on c.id = s.client_id where c.business_id <> s.business_id'),
    ('sales_staff_cross_tenant', array['public.sales','public.staff'], 'select count(*)::bigint from public.sales s join public.staff st on st.id = s.staff_id where st.business_id <> s.business_id'),
    ('sales_branch_cross_tenant', array['public.sales','public.branches'], 'select count(*)::bigint from public.sales s join public.branches br on br.id = s.branch_id where br.business_id <> s.business_id'),
    ('appointments_client_cross_tenant', array['public.appointments','public.clients'], 'select count(*)::bigint from public.appointments a join public.clients c on c.id = a.client_id where c.business_id <> a.business_id'),
    ('appointments_staff_cross_tenant', array['public.appointments','public.staff'], 'select count(*)::bigint from public.appointments a join public.staff st on st.id = a.staff_id where st.business_id <> a.business_id'),
    ('appointments_branch_cross_tenant', array['public.appointments','public.branches'], 'select count(*)::bigint from public.appointments a join public.branches br on br.id = a.branch_id where br.business_id <> a.business_id'),
    ('payments_sale_cross_tenant', array['public.payments','public.sales'], 'select count(*)::bigint from public.payments p join public.sales s on s.id = p.sale_id where s.business_id <> p.business_id'),
    ('payments_appointment_cross_tenant', array['public.payments','public.appointments'], 'select count(*)::bigint from public.payments p join public.appointments a on a.id = p.appointment_id where a.business_id <> p.business_id'),
    ('payments_client_cross_tenant', array['public.payments','public.clients'], 'select count(*)::bigint from public.payments p join public.clients c on c.id = p.client_id where c.business_id <> p.business_id'),
    ('staff_branches_staff_cross_tenant', array['public.staff_branches','public.staff'], 'select count(*)::bigint from public.staff_branches sb join public.staff s on s.id = sb.staff_id where s.business_id <> sb.business_id'),
    ('staff_branches_branch_cross_tenant', array['public.staff_branches','public.branches'], 'select count(*)::bigint from public.staff_branches sb join public.branches b on b.id = sb.branch_id where b.business_id <> sb.business_id'),
    ('service_branches_service_cross_tenant', array['public.service_branches','public.services'], 'select count(*)::bigint from public.service_branches sb join public.services s on s.id = sb.service_id where s.business_id <> sb.business_id'),
    ('service_branches_branch_cross_tenant', array['public.service_branches','public.branches'], 'select count(*)::bigint from public.service_branches sb join public.branches b on b.id = sb.branch_id where b.business_id <> sb.business_id'),
    ('appointment_services_service_cross_tenant', array['public.appointment_services','public.appointments','public.services'], 'select count(*)::bigint from public.appointment_services aps join public.appointments a on a.id = aps.appointment_id join public.services s on s.id = aps.service_id where s.business_id <> a.business_id')
),
orphan_checks_section as (
  select coalesce(jsonb_agg(jsonb_build_object(
           'check_name', check_name,
           'runnable', runnable,
           'orphan_count', case
             when runnable then ((xpath('/row/c/text()', query_to_xml(count_sql, false, true, '')))[1])::text::bigint
             else null
           end
         ) order by check_name), '[]'::jsonb) as data
  from (
    select s.*,
           (select bool_and(to_regclass(rel) is not null) from unnest(required_relations) rel) as runnable
    from orphan_specs s
  ) checks
),
immutable_sales_flags_section as (
  select jsonb_build_object(
    'sales_table_exists', to_regclass('public.sales') is not null,
    'snapshot_columns_present',
      to_regclass('public.sales') is not null
      and exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'sales' and column_name = 'counts_as_revenue')
      and exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'sales' and column_name = 'counts_as_visit')
      and exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'sales' and column_name = 'earns_points')
      and exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'sales' and column_name = 'policy_resolved_at'),
    'missing_snapshot_count',
      case when to_regclass('public.sales') is not null
        and exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'sales' and column_name = 'counts_as_revenue')
        and exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'sales' and column_name = 'counts_as_visit')
        and exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'sales' and column_name = 'earns_points')
        and exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'sales' and column_name = 'policy_resolved_at')
        then ((xpath('/row/c/text()', query_to_xml(
          'select count(*)::bigint as c from public.sales where counts_as_revenue is null or counts_as_visit is null or earns_points is null or policy_resolved_at is null',
          false, true, ''
        )))[1])::text::bigint
        else null
      end,
    'immutable_trigger_present',
      exists (
        select 1
        from pg_trigger t
        join pg_class c on c.oid = t.tgrelid
        join pg_namespace n on n.oid = c.relnamespace
        where n.nspname = 'public'
          and c.relname = 'sales'
          and t.tgname = 'trg_sales_immutable_guard'
          and not t.tgisinternal
      ),
    'mutable_grants', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'grantee', case when acl.grantee = 0 then 'public' else pg_get_userbyid(acl.grantee) end,
        'privilege', acl.privilege_type
      ) order by acl.grantee, acl.privilege_type), '[]'::jsonb)
      from pg_class c
      join pg_namespace n on n.oid = c.relnamespace
      cross join lateral aclexplode(coalesce(c.relacl, acldefault('r', c.relowner))) acl
      where n.nspname = 'public'
        and c.relname = 'sales'
        and (case when acl.grantee = 0 then 'public' else pg_get_userbyid(acl.grantee) end) in ('public','anon','authenticated')
        and acl.privilege_type in ('UPDATE','DELETE','TRUNCATE')
    )
  ) as data
),
points_reconciliation_section as (
  select jsonb_build_object(
    'points_ledger_exists', to_regclass('public.points_ledger') is not null,
    'points_batches_exists', to_regclass('public.points_batches') is not null,
    'client_points_balance_exists', to_regclass('public.client_points_balance') is not null,
    'tenant_rows', case
      when to_regclass('public.businesses') is null or to_regclass('public.points_ledger') is null then '[]'::jsonb
      else coalesce(
        ((xpath('/row/payload/text()', query_to_xml(
          'select coalesce(jsonb_agg(to_jsonb(t) order by business_id), ''[]''::jsonb)::text as payload from (select b.id::text as business_id' ||
          ', (select coalesce(sum(points),0)::bigint from public.points_ledger pl where pl.business_id = b.id) as ledger_points' ||
          case when to_regclass('public.points_batches') is not null
                 and exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'points_batches' and column_name = 'remaining')
            then ', (select coalesce(sum(remaining),0)::bigint from public.points_batches pb where pb.business_id = b.id) as batch_remaining_points'
            else ', null::bigint as batch_remaining_points' end ||
          case when to_regclass('public.client_points_balance') is not null
            then ', (select coalesce(sum(points),0)::bigint from public.client_points_balance cpb where cpb.business_id = b.id) as balance_view_points'
            else ', null::bigint as balance_view_points' end ||
          case when to_regclass('public.client_points_balance') is not null
            then ', (select count(*)::bigint from (select coalesce(l.business_id, v.business_id) as business_id, coalesce(l.client_id, v.client_id) as client_id, coalesce(l.points,0) as ledger_points, coalesce(v.points,0) as view_points from (select business_id, client_id, sum(points)::bigint as points from public.points_ledger group by business_id, client_id) l full outer join public.client_points_balance v on v.business_id = l.business_id and v.client_id = l.client_id) m where m.business_id = b.id and m.ledger_points <> m.view_points) as balance_mismatch_count'
            else ', null::bigint as balance_mismatch_count' end ||
          ' from public.businesses b) t',
          false, true, ''
        )))[1])::text::jsonb,
        '[]'::jsonb
      )
    end
  ) as data
),
credit_reconciliation_section as (
  select jsonb_build_object(
    'credit_ledger_exists', to_regclass('public.credit_ledger') is not null,
    'client_credit_balance_exists', to_regclass('public.client_credit_balance') is not null,
    'tenant_rows', case
      when to_regclass('public.businesses') is null or to_regclass('public.credit_ledger') is null then '[]'::jsonb
      else coalesce(
        ((xpath('/row/payload/text()', query_to_xml(
          'select coalesce(jsonb_agg(to_jsonb(t) order by business_id), ''[]''::jsonb)::text as payload from (select b.id::text as business_id' ||
          ', (select coalesce(sum(amount_cents),0)::bigint from public.credit_ledger cl where cl.business_id = b.id) as ledger_credit_cents' ||
          case when to_regclass('public.client_credit_balance') is not null
            then ', (select coalesce(sum(balance_cents),0)::bigint from public.client_credit_balance ccb where ccb.business_id = b.id) as balance_view_credit_cents'
            else ', null::bigint as balance_view_credit_cents' end ||
          case when to_regclass('public.client_credit_balance') is not null
            then ', (select count(*)::bigint from (select coalesce(l.business_id, v.business_id) as business_id, coalesce(l.client_id, v.client_id) as client_id, coalesce(l.amount_cents,0) as ledger_credit_cents, coalesce(v.balance_cents,0) as view_credit_cents from (select business_id, client_id, sum(amount_cents)::bigint as amount_cents from public.credit_ledger group by business_id, client_id) l full outer join public.client_credit_balance v on v.business_id = l.business_id and v.client_id = l.client_id) m where m.business_id = b.id and m.ledger_credit_cents <> m.view_credit_cents) as balance_mismatch_count'
            else ', null::bigint as balance_mismatch_count' end ||
          ' from public.businesses b) t',
          false, true, ''
        )))[1])::text::jsonb,
        '[]'::jsonb
      )
    end
  ) as data
),
liability_section as (
  select jsonb_build_object(
    'gift_cards_exists', to_regclass('public.gift_cards') is not null,
    'memberships_exists', to_regclass('public.memberships') is not null,
    'credit_ledger_exists', to_regclass('public.credit_ledger') is not null,
    'tenant_rows', case
      when to_regclass('public.businesses') is null then '[]'::jsonb
      else coalesce(
        ((xpath('/row/payload/text()', query_to_xml(
          'select coalesce(jsonb_agg(to_jsonb(t) order by business_id), ''[]''::jsonb)::text as payload from (select b.id::text as business_id' ||
          case when to_regclass('public.gift_cards') is not null
                 and exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'gift_cards' and column_name = 'balance_cents')
            then ', (select coalesce(sum(balance_cents),0)::bigint from public.gift_cards gc where gc.business_id = b.id) as gift_card_liability_cents'
            else ', null::bigint as gift_card_liability_cents' end ||
          case when to_regclass('public.credit_ledger') is not null
                 and exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'credit_ledger' and column_name = 'amount_cents')
                 and exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'credit_ledger' and column_name = 'entry_type')
            then ', (select coalesce(sum(amount_cents) filter (where entry_type = ''membership_credit''),0)::bigint from public.credit_ledger cl where cl.business_id = b.id) as member_credit_liability_cents'
            else ', null::bigint as member_credit_liability_cents' end ||
          case when to_regclass('public.memberships') is not null
                 and exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'memberships' and column_name = 'status')
            then ', (select count(*)::bigint from public.memberships m where m.business_id = b.id and m.status in (''active'', ''paused'', ''cancel_at_period_end'')) as active_member_count'
            else ', null::bigint as active_member_count' end ||
          ' from public.businesses b) t',
          false, true, ''
        )))[1])::text::jsonb,
        '[]'::jsonb
      )
    end
  ) as data
),
cron_duplicate_jobs_section as (
  select case
    when to_regclass('cron.job') is null then '[]'::jsonb
    else coalesce(
      ((xpath('/row/payload/text()', query_to_xml(
        $sql$
          select coalesce(jsonb_agg(jsonb_build_object(
            'job_fingerprint', job_fingerprint,
            'duplicate_count', duplicate_count,
            'schedules', schedules,
            'command_fingerprints', command_fingerprints
          ) order by job_fingerprint), '[]'::jsonb)::text as payload
          from (
            select md5(coalesce(to_jsonb(j)->>'jobname', to_jsonb(j)->>'command', '')) as job_fingerprint,
                   count(*)::bigint as duplicate_count,
                   jsonb_agg(distinct to_jsonb(j)->>'schedule') as schedules,
                   jsonb_agg(distinct md5(coalesce(to_jsonb(j)->>'command', ''))) as command_fingerprints
            from cron.job j
            group by 1
            having count(*) > 1
          ) duplicates
        $sql$,
        false, true, ''
      )))[1])::text::jsonb,
      '[]'::jsonb
    )
  end as data
),
functions_base as (
  select n.nspname as schema_name,
         p.proname as function_name,
         p.oid as function_oid,
         p.proowner,
         p.prosecdef,
         pg_get_function_identity_arguments(p.oid) as identity_arguments,
         (select substring(setting from '^search_path=(.*)$')
          from unnest(coalesce(p.proconfig, array[]::text[])) setting
          where setting like 'search_path=%'
          limit 1) as search_path
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
  where n.nspname in ('public', 'app')
),
function_execute_grants as (
  select f.*,
         case when acl.grantee = 0 then 'public' else pg_get_userbyid(acl.grantee) end as grantee,
         acl.privilege_type
  from functions_base f
  cross join lateral aclexplode(coalesce((select proacl from pg_proc where oid = f.function_oid), acldefault('f', f.proowner))) acl
  where acl.privilege_type = 'EXECUTE'
),
accepted_public_rpc(schema_name, function_name, identity_arguments) as (
  values
    ('public', 'get_business_public', 'p_slug text'),
    ('public', 'get_join_page', 'p_slug text'),
    ('public', 'get_booking_availability', 'p_slug text'),
    ('public', 'request_booking', 'p_slug text, p_name text, p_email text, p_phone text, p_service uuid, p_party integer, p_preferred timestamp with time zone, p_notes text'),
    ('public', 'request_booking', 'p_slug text, p_name text, p_email text, p_phone text, p_service uuid, p_party integer, p_preferred timestamp with time zone, p_notes text, p_table_type uuid, p_consent boolean'),
    ('public', 'join_program', 'p_slug text, p_name text, p_phone text, p_email text, p_consent boolean'),
    ('public', 'enrol_customer', 'p_slug text, p_phone text, p_name text, p_email text, p_consent boolean')
),
known_risk_public_rpc(schema_name, function_name, identity_arguments, risk_code, hardening_required) as (
  values
    ('public', 'list_my_appointments', 'p_slug text, p_phone text', 'PHONE_ONLY_APPOINTMENT_LOOKUP', 'OTP or signed-token proof before returning appointments'),
    ('public', 'request_change', 'p_slug text, p_appointment uuid, p_phone text, p_kind text, p_proposed timestamp with time zone, p_note text', 'PHONE_ONLY_APPOINTMENT_MUTATION', 'OTP or signed-token proof before changing appointments')
),
function_execute_exposure_section as (
  select jsonb_build_object(
    'accepted_public_execute_grants', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'schema_name', g.schema_name,
               'function_name', g.function_name,
               'identity_arguments', g.identity_arguments,
               'grantee', g.grantee,
               'security_definer', g.prosecdef,
               'search_path', g.search_path
             ) order by g.schema_name, g.function_name, g.identity_arguments, g.grantee), '[]'::jsonb)
      from function_execute_grants g
      where g.grantee in ('anon', 'public')
        and exists (
          select 1
          from accepted_public_rpc a
          where a.schema_name = g.schema_name
            and a.function_name = g.function_name
            and a.identity_arguments = g.identity_arguments
        )
    ),
    'known_risk_public_execute_grants', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'schema_name', g.schema_name,
               'function_name', g.function_name,
               'identity_arguments', g.identity_arguments,
               'grantee', g.grantee,
               'security_definer', g.prosecdef,
               'search_path', g.search_path,
               'risk_code', k.risk_code,
               'hardening_required', k.hardening_required
             ) order by g.schema_name, g.function_name, g.identity_arguments, g.grantee), '[]'::jsonb)
      from function_execute_grants g
      join known_risk_public_rpc k
        on k.schema_name = g.schema_name
       and k.function_name = g.function_name
       and k.identity_arguments = g.identity_arguments
      where g.grantee in ('anon', 'public')
    ),
    'unexpected_anon_execute_grants', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'schema_name', schema_name,
               'function_name', function_name,
               'identity_arguments', identity_arguments,
               'grantee', grantee,
               'security_definer', prosecdef,
               'search_path', search_path
             ) order by schema_name, function_name, identity_arguments, grantee), '[]'::jsonb)
      from function_execute_grants g
      where g.grantee = 'anon'
        and not exists (
          select 1
          from accepted_public_rpc a
          where a.schema_name = g.schema_name
            and a.function_name = g.function_name
            and a.identity_arguments = g.identity_arguments
        )
        and not exists (
          select 1
          from known_risk_public_rpc k
          where k.schema_name = g.schema_name
            and k.function_name = g.function_name
            and k.identity_arguments = g.identity_arguments
        )
    ),
    'unexpected_public_execute_grants', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'schema_name', schema_name,
               'function_name', function_name,
               'identity_arguments', identity_arguments,
               'grantee', grantee,
               'security_definer', prosecdef,
               'search_path', search_path
             ) order by schema_name, function_name, identity_arguments, grantee), '[]'::jsonb)
      from function_execute_grants g
      where g.grantee = 'public'
        and not exists (
          select 1
          from accepted_public_rpc a
          where a.schema_name = g.schema_name
            and a.function_name = g.function_name
            and a.identity_arguments = g.identity_arguments
        )
        and not exists (
          select 1
          from known_risk_public_rpc k
          where k.schema_name = g.schema_name
            and k.function_name = g.function_name
            and k.identity_arguments = g.identity_arguments
        )
    ),
    'security_definer_without_search_path', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'schema_name', schema_name,
               'function_name', function_name,
               'identity_arguments', identity_arguments
             ) order by schema_name, function_name, identity_arguments), '[]'::jsonb)
      from functions_base
      where prosecdef and search_path is null
    ),
    'public_security_definer_exposed_to_anon', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'schema_name', schema_name,
               'function_name', function_name,
               'identity_arguments', identity_arguments,
               'grantee', grantee,
               'search_path', search_path
             ) order by schema_name, function_name, identity_arguments, grantee), '[]'::jsonb)
      from function_execute_grants g
      where g.schema_name = 'public'
        and g.prosecdef
        and g.grantee in ('anon', 'public')
        and not exists (
          select 1
          from accepted_public_rpc a
          where a.schema_name = g.schema_name
            and a.function_name = g.function_name
            and a.identity_arguments = g.identity_arguments
        )
    )
  ) as data
)
select jsonb_pretty(jsonb_build_object(
  'kind', 'supabase_cutover_reconciliation_v1',
  'scope', (select scope from params),
  'project_ref', (select project_ref from params),
  'metrics', jsonb_build_object(
    'entity_counts', (select data from entity_counts_section),
    'tenant_aggregates', (select data from tenant_aggregates_section),
    'orphan_checks', (select data from orphan_checks_section),
    'immutable_sales_flags', (select data from immutable_sales_flags_section),
    'points_ledger_reconciliation', (select data from points_reconciliation_section),
    'credit_balance_reconciliation', (select data from credit_reconciliation_section),
    'gift_card_member_liability', (select data from liability_section),
    'duplicate_cron_jobs', (select data from cron_duplicate_jobs_section),
    'function_execute_exposure', (select data from function_execute_exposure_section)
  )
));
