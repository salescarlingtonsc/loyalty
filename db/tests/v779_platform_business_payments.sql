-- nestly_v779 rollback suite — the platform console reads a firm's payments, branch by branch.
--
-- Runs inside ONE transaction ending in ROLLBACK, so it is safe against production.
--
-- WHAT IT PROVES
--   01  public.platform_get_business_payments_v779(uuid) exists, is STABLE and SECURITY DEFINER,
--       granted to authenticated and service_role, not to anon or public.
--   02  a caller with no platform grant and no assignment is refused 42501 — the same scope the
--       firm record already enforces (app.platform_firm_report_access_v94).
--   03  a super admin reads the synthetic firm: both branches, the subscription, and the invoice
--       rows carry reason + detail (branch_added names its branch; capacity_increase its sizes),
--       newest first.
--   04  a null business is refused 22023; an unknown business is refused P0002 for a super admin.

begin;

create temp table _v779(id int generated always as identity, check_name text, ok boolean, detail text) on commit drop;
grant all on _v779 to public;

create or replace function pg_temp.as_v779_user(p_uid uuid, p_role text default 'authenticated')
returns void language plpgsql as $$
begin
  execute format('set local role %I', p_role);
  perform set_config('request.jwt.claim.sub', coalesce(p_uid::text, ''), true);
  -- v625: a platform session must be a Google OAuth session; the claims say so, as the real JWT does.
  perform set_config('request.jwt.claims', jsonb_build_object('sub', p_uid, 'role', p_role,
    'amr', jsonb_build_array(jsonb_build_object('method','oauth')),
    'app_metadata', jsonb_build_object('provider','google','providers',jsonb_build_array('email','google')))::text, true);
end
$$;
grant execute on function pg_temp.as_v779_user(uuid,text) to public;

-- 01 shape and grants
insert into _v779(check_name, ok, detail)
select '01 function exists, stable, definer',
  p.provolatile='s' and p.prosecdef,
  format('volatile=%s definer=%s', p.provolatile, p.prosecdef)
from pg_proc p join pg_namespace n on n.oid=p.pronamespace
where n.nspname='public' and p.proname='platform_get_business_payments_v779';

insert into _v779(check_name, ok, detail)
select '01 grants: authenticated + service_role yes, anon + public no',
  has_function_privilege('authenticated','public.platform_get_business_payments_v779(uuid)','execute')
  and has_function_privilege('service_role','public.platform_get_business_payments_v779(uuid)','execute')
  and not has_function_privilege('anon','public.platform_get_business_payments_v779(uuid)','execute'),
  'proacl='||coalesce((select proacl::text from pg_proc where proname='platform_get_business_payments_v779'),'<null>');

do $$
declare
  v_biz uuid := gen_random_uuid();
  v_main uuid := gen_random_uuid(); v_second uuid := gen_random_uuid();
  v_sa uuid := gen_random_uuid(); v_stranger uuid := gen_random_uuid();
  v_sa_email text := 'v779-sa-'||replace(v_sa::text,'-','')||'@example.invalid';
  v_out jsonb; v_code text; v_ok boolean;
begin
  insert into auth.users(id, email, instance_id, aud, role, created_at, updated_at, raw_app_meta_data, raw_user_meta_data)
  values (v_sa, v_sa_email, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', now(), now(), '{}'::jsonb, '{}'::jsonb),
         (v_stranger, 'v779-x-'||replace(v_stranger::text,'-','')||'@example.invalid', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', now(), now(), '{}'::jsonb, '{}'::jsonb);
  insert into public.super_admins(user_id, email) values (v_sa, v_sa_email);

  insert into public.businesses(id, name, slug, industry)
  values (v_biz, 'V779 Cubbly SPA', 'v779-cubbly-'||left(replace(v_biz::text,'-',''),8), 'beauty');
  -- The default branch may already have been auto-created by the businesses trigger; it is
  -- renamed rather than duplicated.
  update public.branches set id=v_main, name='V779 Orchard' where business_id=v_biz and is_default;
  if not found then
    insert into public.branches(id, business_id, name, is_default, active, billing_state)
    values (v_main, v_biz, 'V779 Orchard', true, true, 'included');
  end if;
  insert into public.branches(id, business_id, name, is_default, active, billing_state)
  values (v_second, v_biz, 'V779 Kopitiam 2', false, true, 'active');

  insert into public.billing_provider_subscriptions(business_id, provider_customer_id, provider_subscription_id, status, cadence, cadence_months, currency,
    current_period_start, current_period_end, livemode, provider_event_created_at, provider_event_rank, last_event_id)
  values (v_biz, 'cust_v779', 'sub_v779', 'active', 'annual', 12, 'SGD', '2026-09-05 09:59+00', '2027-09-04 16:00+00', false, now(), 1, 'evt_v779_sub');
  insert into public.billing_provider_invoices(business_id, provider_customer_id, provider_subscription_id, provider_invoice_id, provider_payment_intent_id,
    currency, status, paid_normalized, subtotal_ex_tax_cents, tax_cents, total_cents, amount_due_cents, amount_paid_cents, amount_remaining_cents,
    period_start, period_end, paid_at, livemode, reason, detail, provider_event_created_at, provider_event_rank, last_event_id)
  values
    (v_biz, 'cust_v779', 'sub_v779', 'inv_v779_initial', 'pay_v779_1', 'SGD', 'paid', true, 118800, 0, 118800, 118800, 118800, 0,
      '2026-09-05 09:59+00', '2027-09-04 16:00+00', '2026-09-05 09:59+00', false, 'initial',
      '{"covers_from":"2026-09-05","covers_until":"2027-09-05"}'::jsonb, now(), 1, 'evt_v779_1'),
    (v_biz, 'cust_v779', 'sub_v779', 'inv_v779_branch', 'pay_v779_2', 'SGD', 'paid', true, 118800, 0, 118800, 118800, 118800, 0,
      '2026-09-05 09:59+00', '2027-09-04 16:00+00', '2026-09-05 10:15+00', false, 'branch_added',
      jsonb_build_object('branch_id', v_second, 'branch_name', 'V779 Kopitiam 2', 'covers_from', '2026-09-05', 'covers_until', '2027-09-05'), now(), 2, 'evt_v779_2'),
    (v_biz, 'cust_v779', 'sub_v779', 'inv_v779_capacity', 'pay_v779_3', 'SGD', 'paid', true, 100000, 0, 100000, 100000, 100000, 0,
      '2026-09-05 09:59+00', '2027-09-04 16:00+00', '2026-09-05 10:17+00', false, 'capacity_increase',
      '{"capacity_from":"10000","capacity_to":"40000","covers_from":"2026-09-05","covers_until":"2027-09-05"}'::jsonb, now(), 3, 'evt_v779_3');

  -- 02 a stranger is refused
  begin
    perform pg_temp.as_v779_user(v_stranger);
    v_out := public.platform_get_business_payments_v779(v_biz);
    v_code := 'no error';
  exception when others then v_code := sqlstate;
  end;
  reset role;
  insert into _v779(check_name, ok, detail) values ('02 no grant, no assignment → 42501', v_code='42501', 'sqlstate='||v_code);

  -- 03 the super admin reads the firm
  perform pg_temp.as_v779_user(v_sa);
  v_out := public.platform_get_business_payments_v779(v_biz);
  reset role;
  insert into _v779(check_name, ok, detail) values ('03 business named',
    v_out->'business'->>'name'='V779 Cubbly SPA', v_out->'business'->>'name');
  insert into _v779(check_name, ok, detail) values ('03 both branches, default first',
    jsonb_array_length(v_out->'branches')=2 and (v_out->'branches'->0->>'is_default')::boolean,
    (v_out->'branches')::text);
  insert into _v779(check_name, ok, detail) values ('03 subscription period and cadence',
    v_out->'subscription'->>'cadence'='annual' and (v_out->'subscription'->>'current_period_end') is not null,
    (v_out->'subscription')::text);
  insert into _v779(check_name, ok, detail) values ('03 three invoices, newest first',
    jsonb_array_length(v_out->'invoices')=3 and v_out->'invoices'->0->>'reason'='capacity_increase'
      and v_out->'invoices'->2->>'reason'='initial',
    (select string_agg(x->>'reason', ',') from jsonb_array_elements(v_out->'invoices') x));
  insert into _v779(check_name, ok, detail) values ('03 branch charge names its branch',
    exists (select 1 from jsonb_array_elements(v_out->'invoices') x
            where x->>'reason'='branch_added' and x->'detail'->>'branch_id'=v_second::text
              and x->'detail'->>'branch_name'='V779 Kopitiam 2'),
    'branch_added detail carries branch_id + branch_name');
  insert into _v779(check_name, ok, detail) values ('03 capacity charge carries its sizes',
    exists (select 1 from jsonb_array_elements(v_out->'invoices') x
            where x->>'reason'='capacity_increase' and x->'detail'->>'capacity_to'='40000'),
    'capacity_increase detail carries capacity_to');

  -- 04 refusals
  begin
    perform pg_temp.as_v779_user(v_sa);
    v_out := public.platform_get_business_payments_v779(null);
    v_code := 'no error';
  exception when others then v_code := sqlstate;
  end;
  reset role;
  insert into _v779(check_name, ok, detail) values ('04 null business → 22023', v_code='22023', 'sqlstate='||v_code);
  begin
    perform pg_temp.as_v779_user(v_sa);
    v_out := public.platform_get_business_payments_v779(gen_random_uuid());
    v_code := 'no error';
  exception when others then v_code := sqlstate;
  end;
  reset role;
  insert into _v779(check_name, ok, detail) values ('04 unknown business → P0002', v_code='P0002', 'sqlstate='||v_code);
end
$$;

select check_name, ok, detail from _v779 order by id;
select count(*) filter (where not ok) as failures, count(*) as checks from _v779;

rollback;
