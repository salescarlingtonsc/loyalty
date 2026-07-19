-- Rollback-only assertions for v20 financial engine.
--
-- Run against a disposable database after applying migrations through v20:
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f db/tests/v20_financial_engine.sql
--
-- This file deliberately ends with ROLLBACK. It creates synthetic tenants, users and
-- ledger rows, then proves the financial contract. It is not run by this patch.

begin;

-- Auth helpers used by Supabase auth.uid().
create or replace function pg_temp.as_user(p_uid uuid) returns void
language plpgsql
as $$
begin
  execute 'set local role authenticated';
  perform set_config('request.jwt.claim.sub', p_uid::text, true);
end $$;

create or replace function pg_temp.as_anon() returns void
language plpgsql
as $$
begin
  execute 'set local role anon';
  perform set_config('request.jwt.claim.sub', '', true);
end $$;

create or replace function pg_temp.assert_true(p_ok boolean, p_message text) returns void
language plpgsql
as $$
begin
  if not coalesce(p_ok, false) then
    raise exception 'ASSERTION FAILED: %', p_message;
  end if;
end $$;

create or replace function pg_temp.assert_eq(p_actual anyelement, p_expected anyelement, p_message text)
returns void
language plpgsql
as $$
begin
  if p_actual is distinct from p_expected then
    raise exception 'ASSERTION FAILED: % (actual %, expected %)', p_message, p_actual, p_expected;
  end if;
end $$;

-- v22b revoked the built-in PUBLIC-EXECUTE default on functions created by postgres, so these
-- session-local helpers are born owner-only — but the suite calls them while running under
-- `set local role authenticated/anon`. Grant them back explicitly (pg_temp, rolled back with
-- the transaction; no production surface).
grant execute on function pg_temp.as_user(uuid) to public;
grant execute on function pg_temp.as_anon() to public;
grant execute on function pg_temp.assert_true(boolean, text) to public;
grant execute on function pg_temp.assert_eq(anyelement, anyelement, text) to public;

do $$
declare
  owner_a uuid := gen_random_uuid();
  manager_a uuid := gen_random_uuid();
  staff_a uuid := gen_random_uuid();
  bookkeeper_a uuid := gen_random_uuid();
  owner_b uuid := gen_random_uuid();
  biz_a uuid;
  biz_b uuid;
  branch_a uuid;
  branch_b uuid;
  client_a uuid;
  client_b uuid;
  client_loyalty uuid;
  client_membership uuid;
  client_other uuid;
  client_no_link uuid;
  staff_owner_a uuid;
  staff_manager_a uuid;
  staff_staff_a uuid;
  staff_bookkeeper_a uuid;
  sale_a uuid;
  sale_b uuid;
  card_sale uuid;
  membership_sale uuid;
  negative_method_sale uuid;
  unproven_credit_sale uuid;
  appointment_a uuid;
  appointment_other uuid;
  appointment_sale uuid;
  membership_plan uuid;
  legacy_referral uuid;
  legacy_no_link_referral uuid;
  legacy_sale uuid;
  legacy_candidate_one uuid;
  legacy_candidate_two uuid;
  legacy_no_link_candidate uuid;
  legacy_no_link_candidate_two uuid;
  quick_paid_sale uuid;
  quick_unpaid_sale uuid;
  result jsonb;
  reversal_id uuid;
  credit_payment uuid;
  v_credit_ledger_id uuid;
  seed_credit uuid := gen_random_uuid();
  bad_credit uuid := gen_random_uuid();
  bad_points uuid := gen_random_uuid();
  bad_payment uuid := gen_random_uuid();
  bad_refund uuid := gen_random_uuid();
  bad_credit_payment uuid := gen_random_uuid();
  bad_points_sale uuid;
  points_before int;
  points_after int;
  batch_before int;
  batch_after int;
  report jsonb;
  before_count int;
  after_count int;
  flow_before int;
  flow_after int;
  acl_table text;
  acl_role text;
  acl_priv text;
begin
  execute 'reset role';

  perform pg_temp.assert_true(
    'create_sales' = any (app.role_perms('staff')),
    'actual staff role retains create_sales permission'
  );

  perform pg_temp.assert_true(
    pg_get_function_result(to_regprocedure('public.run_expiry_now(uuid)')) = 'void'
      and (select p.prosecdef
             from pg_catalog.pg_proc p
            where p.oid = to_regprocedure('public.run_expiry_now(uuid)')),
    'manual points-expiry preserves the remote void SECURITY DEFINER contract'
  );
  perform pg_temp.assert_true(
    pg_get_function_result(to_regprocedure('app.run_points_expiry()')) = 'void'
      and (select p.prosecdef
             from pg_catalog.pg_proc p
            where p.oid = to_regprocedure('app.run_points_expiry()')),
    'global points-expiry sweep preserves the remote void SECURITY DEFINER contract'
  );
  perform pg_temp.assert_true(
    pg_get_function_result(
      to_regprocedure('public.redeem_gift_card(uuid,text,uuid,integer)')
    ) = 'json'
      and exists (
        select 1 from pg_catalog.pg_proc p
         where p.oid = to_regprocedure('public.redeem_gift_card(uuid,text,uuid,integer)')
           and p.prosecdef
           and p.pronargdefaults = 1
           and pg_get_expr(p.proargdefaults, 0) = 'NULL::integer'
      ),
    'gift-card redemption preserves json and p_amount DEFAULT NULL ABI'
  );
  perform pg_temp.assert_true(
    pg_get_function_result(to_regprocedure('app.run_membership_renewals()')) = 'void'
      and (select p.prosecdef
             from pg_catalog.pg_proc p
            where p.oid = to_regprocedure('app.run_membership_renewals()')),
    'membership renewal preserves the remote void SECURITY DEFINER contract'
  );

  perform pg_temp.assert_eq(
    (select array_agg(column_name::text order by ordinal_position)
       from information_schema.columns
      where table_schema = 'public'
        and table_name = 'sale_commission'),
    array[
      'sale_id', 'business_id', 'branch_id', 'staff_id', 'kind', 'occurred_at',
      'amount_cents', 'rate_bps', 'commission_cents', 'flat_cents'
    ]::text[],
    'sale_commission preserves v12 percentage columns plus the v13-rebased trailing flat_cents'
  );

  -- v22 reconciliation: v20's original tombstone ('all flat commission artifacts are absent')
  -- is formally superseded — flat commission is the approved owner model, reinstated by the
  -- REBASED v13 and hardened by v22. The contract now asserted is: both flat columns exist,
  -- the resolver exists as SECURITY DEFINER, and it carries the v21-standard owner-only ACL
  -- (not executable by anon, PUBLIC or authenticated — its only caller is the SECURITY
  -- DEFINER snapshot trigger).
  perform pg_temp.assert_true(
    (select count(*) = 2 from information_schema.columns
      where table_schema = 'public'
        and table_name in ('sales', 'services')
        and column_name = 'commission_flat_cents')
    and exists (
      select 1
        from pg_catalog.pg_proc p
        join pg_catalog.pg_namespace n on n.oid = p.pronamespace
       where n.nspname = 'app' and p.proname = 'commission_flat_cents'
         and p.prosecdef
         and not has_function_privilege('anon', p.oid, 'execute')
         and not has_function_privilege('authenticated', p.oid, 'execute')
         and not exists (
           select 1
             from aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) acl
            where acl.grantee = 0 and acl.privilege_type = 'EXECUTE'
         )
    ),
    'v22 reconciled flat commission: artifacts present with owner-only resolver ACL (supersedes the v20 tombstone)'
  );

  foreach acl_table in array array[
    'payments', 'points_ledger', 'credit_ledger', 'financial_operations',
    'sale_reversal_audits', 'sale_reversal_payment_links', 'credit_tenders',
    'legacy_referral_provenance', 'legacy_referral_sale_candidates',
    'legacy_referral_resolution_events'
  ] loop
    perform pg_temp.assert_true(
      not exists (
        select 1
          from information_schema.table_privileges tp
         where tp.table_schema = 'public'
           and tp.table_name = acl_table
           and tp.grantee = 'PUBLIC'
      ),
      format('PUBLIC has no privileges on %s', acl_table)
    );
    foreach acl_role in array array['anon', 'authenticated'] loop
      foreach acl_priv in array array[
        'INSERT', 'UPDATE', 'DELETE', 'TRUNCATE', 'REFERENCES', 'TRIGGER', 'MAINTAIN'
      ] loop
        perform pg_temp.assert_true(
          not has_table_privilege(acl_role, 'public.' || acl_table, acl_priv),
          format('%s has no %s privilege on %s', acl_role, acl_priv, acl_table)
        );
      end loop;
    end loop;
  end loop;

  insert into auth.users(instance_id, id, aud, role, email, encrypted_password, email_confirmed_at, created_at, updated_at)
  values
    ('00000000-0000-0000-0000-000000000000', owner_a, 'authenticated', 'authenticated', 'v20-owner-a@example.test', '', now(), now(), now()),
    ('00000000-0000-0000-0000-000000000000', manager_a, 'authenticated', 'authenticated', 'v20-manager-a@example.test', '', now(), now(), now()),
    ('00000000-0000-0000-0000-000000000000', staff_a, 'authenticated', 'authenticated', 'v20-staff-a@example.test', '', now(), now(), now()),
    ('00000000-0000-0000-0000-000000000000', bookkeeper_a, 'authenticated', 'authenticated', 'v20-bookkeeper-a@example.test', '', now(), now(), now()),
    ('00000000-0000-0000-0000-000000000000', owner_b, 'authenticated', 'authenticated', 'v20-owner-b@example.test', '', now(), now(), now());

  insert into public.businesses(name, slug, industry, enabled_modules)
  values
    ('V20 A', 'v20-a-' || substr(owner_a::text, 1, 8), 'test', array['dashboard','clients','sales'])
  returning id into biz_a;

  insert into public.businesses(name, slug, industry, enabled_modules)
  values
    ('V20 B', 'v20-b-' || substr(owner_b::text, 1, 8), 'test', array['dashboard','clients','sales'])
  returning id into biz_b;

  insert into public.branches(business_id, name, is_default, active)
  values (biz_a, 'A Main', true, true)
  returning id into branch_a;

  insert into public.branches(business_id, name, is_default, active)
  values (biz_b, 'B Main', true, true)
  returning id into branch_b;

  insert into public.staff(
    business_id, user_id, role, full_name, active,
    commission_service_bps, commission_product_bps
  )
  values
    (biz_a, owner_a, 'owner', 'Owner A', true, 1000, 500)
  returning id into staff_owner_a;

  insert into public.staff(business_id, user_id, role, full_name, active)
  values (biz_a, manager_a, 'manager', 'Manager A', true)
  returning id into staff_manager_a;

  insert into public.staff(business_id, user_id, role, full_name, active)
  values (biz_a, staff_a, 'staff', 'Staff A', true)
  returning id into staff_staff_a;

  insert into public.staff(business_id, user_id, role, full_name, active)
  values (biz_a, bookkeeper_a, 'bookkeeper', 'Bookkeeper A', true)
  returning id into staff_bookkeeper_a;

  insert into public.staff(business_id, user_id, role, full_name, active)
  values (biz_b, owner_b, 'owner', 'Owner B', true);

  insert into public.staff_branches(business_id, staff_id, branch_id)
  values
    (biz_a, staff_owner_a, branch_a),
    (biz_a, staff_manager_a, branch_a),
    (biz_a, staff_staff_a, branch_a);

  insert into public.clients(business_id, full_name, phone)
  values (biz_a, 'Client A', '81863833')
  returning id into client_a;

  insert into public.clients(business_id, full_name, phone)
  values (biz_b, 'Client B', '81863834')
  returning id into client_b;

  insert into public.clients(business_id, full_name, phone)
  values (biz_a, 'Loyalty Flow', '81863835')
  returning id into client_loyalty;

  insert into public.clients(business_id, full_name, phone)
  values (biz_a, 'Membership Flow', '81863836')
  returning id into client_membership;

  insert into public.clients(business_id, full_name, phone)
  values (biz_a, 'Other Client', '81863837')
  returning id into client_other;

  insert into public.clients(business_id, full_name, phone)
  values (biz_a, 'No-Link Referral Client', '81863838')
  returning id into client_no_link;

  insert into public.loyalty_programs(
    business_id, kind, earn_points_per_dollar, redeem_points,
    reward_credit_cents, active, expiry_mode, expiry_days
  )
  values (biz_a, 'points', 1, 50, 500, true, 'fixed', 30)
  on conflict (business_id) do update set
    kind = excluded.kind,
    earn_points_per_dollar = excluded.earn_points_per_dollar,
    redeem_points = excluded.redeem_points,
    reward_credit_cents = excluded.reward_credit_cents,
    active = excluded.active,
    expiry_mode = excluded.expiry_mode,
    expiry_days = excluded.expiry_days;

  insert into public.sales
    (business_id, branch_id, staff_id, client_id, kind, amount_cents, occurred_at, note)
  values (biz_b, branch_b, null, null, 'service', 1000,
          '2000-01-01 00:00:00+00', 'other tenant sale')
  returning id into sale_b;

  perform pg_temp.as_user(owner_a);

  insert into public.gift_cards(
    business_id, code, initial_cents, balance_cents, status
  ) values (
    biz_a, 'GC-V20SEED', 6000, 6000, 'active'
  );
  result := public.redeem_gift_card(
    biz_a, ' gc-v20seed ', client_a
  )::jsonb;
  perform pg_temp.assert_eq(
    (result->>'loaded_cents')::int,
    6000,
    'retained gift-card redemption loads exact customer credit'
  );
  perform pg_temp.assert_true(
    exists (
      select 1 from public.credit_ledger cl
       where cl.business_id = biz_a
         and cl.client_id = client_a
         and cl.entry_type = 'gift_card_load'
         and cl.amount_cents = 6000
         and cl.actor = owner_a
    ),
    'gift-card flow uses its validated ledger scope'
  );
  select cl.id into seed_credit
    from public.credit_ledger cl
   where cl.business_id = biz_a
     and cl.client_id = client_a
     and cl.entry_type = 'gift_card_load'
   order by cl.created_at desc
   limit 1;

  execute 'reset role';
  begin
    perform set_config('app.points_ledger_insert_id', gen_random_uuid()::text, true);
    perform set_config('app.points_ledger_write_scope', 'adjust_points', true);
    insert into public.points_ledger(
      id, business_id, client_id, entry_type, points, reference, actor
    ) values (
      bad_points, biz_a, client_a, 'adjust', 1, 'wrong token proof', owner_a
    );
    raise exception 'expected wrong points token to fail';
  exception when insufficient_privilege then
    null;
  end;
  begin
    perform set_config('app.points_ledger_insert_id', bad_points::text, true);
    perform set_config('app.points_ledger_write_scope', 'invented_scope', true);
    insert into public.points_ledger(
      id, business_id, client_id, entry_type, points, reference, actor
    ) values (
      bad_points, biz_a, client_a, 'adjust', 1, 'invalid scope proof', owner_a
    );
    raise exception 'expected invalid points scope to fail';
  exception when insufficient_privilege then
    null;
  end;
  begin
    perform set_config('app.credit_ledger_insert_id', gen_random_uuid()::text, true);
    perform set_config('app.credit_ledger_write_scope', 'redeem_gift_card', true);
    insert into public.credit_ledger(
      id, business_id, client_id, entry_type, amount_cents, reference, actor
    ) values (
      bad_credit, biz_a, client_a, 'gift_card_load', 1, 'wrong token proof', owner_a
    );
    raise exception 'expected wrong credit token to fail';
  exception when insufficient_privilege then
    null;
  end;
  begin
    perform set_config('app.credit_ledger_insert_id', bad_credit::text, true);
    perform set_config('app.credit_ledger_write_scope', 'invented_scope', true);
    insert into public.credit_ledger(
      id, business_id, client_id, entry_type, amount_cents, reference, actor
    ) values (
      bad_credit, biz_a, client_a, 'gift_card_load', 1, 'invalid scope proof', owner_a
    );
    raise exception 'expected invalid credit scope to fail';
  exception when insufficient_privilege then
    null;
  end;
  perform pg_temp.as_user(owner_a);

  perform pg_temp.assert_eq(
    public.adjust_points(biz_a, client_loyalty, 30, 'fifo batch one'), 30,
    'first FIFO points batch is recorded'
  );
  perform pg_temp.assert_eq(
    public.adjust_points(biz_a, client_loyalty, 40, 'fifo batch two'), 70,
    'second FIFO points batch is recorded'
  );
  perform pg_temp.assert_eq(
    public.adjust_points(biz_a, client_loyalty, 50, 'fifo batch three'), 120,
    'third FIFO points batch is recorded'
  );
  execute 'reset role';
  update public.points_batches
     set earned_at = now() - case earned when 30 then interval '3 days'
                                      when 40 then interval '2 days'
                                      else interval '1 day' end,
         expires_at = now() + case earned when 30 then interval '27 days'
                                       when 40 then interval '28 days'
                                       else interval '29 days' end
   where business_id = biz_a and client_id = client_loyalty;
  perform pg_temp.as_user(owner_a);
  perform pg_temp.assert_eq(
    public.adjust_points(biz_a, client_loyalty, -80, 'fifo partial boundary'), 40,
    'negative adjustment drains three ordered batches through a partial boundary'
  );
  perform pg_temp.assert_eq(
    (select array_agg(remaining order by earned_at) from public.points_batches
      where business_id = biz_a and client_id = client_loyalty),
    array[0,0,40]::integer[],
    'FIFO leaves only the partial remainder in the third batch'
  );

  execute 'reset role';
  update public.points_batches set expires_at = now() - interval '1 day'
   where business_id = biz_a and client_id = client_loyalty and remaining > 0;
  perform pg_temp.as_user(owner_a);
  perform public.run_expiry_now(biz_a);
  perform pg_temp.assert_eq(
    (select coalesce(sum(remaining), 0)::integer
       from public.points_batches
      where business_id = biz_a and client_id = client_loyalty),
    0,
    'void manual-expiry RPC drains the exact business-scoped batch balance'
  );
  perform pg_temp.assert_true(
    exists (
      select 1 from public.points_ledger pl
       where pl.business_id = biz_a
         and pl.client_id = client_loyalty
         and pl.entry_type = 'expire'
         and pl.points = -40
         and pl.actor is null
    ),
    'manual points expiry uses the exact validated internal scope'
  );

  perform pg_temp.as_user(owner_b);
  begin
    perform public.run_expiry_now(biz_a);
    raise exception 'expected cross-tenant manual expiry to fail';
  exception when insufficient_privilege then
    null;
  end;
  perform pg_temp.as_user(owner_a);

  perform public.adjust_points(biz_a, client_loyalty, 5, 'cron expiry route');
  execute 'reset role';
  update public.points_batches set expires_at = now() - interval '1 day'
   where business_id = biz_a and client_id = client_loyalty and remaining > 0;
  perform app.run_points_expiry();
  perform pg_temp.assert_eq(
    (select coalesce(sum(remaining), 0)::integer
       from public.points_batches
      where business_id = biz_a and client_id = client_loyalty),
    0,
    'void global expiry sweep reaches the tokenized business writer'
  );
  perform pg_temp.assert_true(
    exists (
      select 1 from public.points_ledger pl
       where pl.business_id = biz_a
         and pl.client_id = client_loyalty
         and pl.entry_type = 'expire'
         and pl.points = -5
         and pl.actor is null
    ),
    'global expiry sweep appends the exact expiry ledger effect'
  );
  perform pg_temp.as_user(owner_a);

  perform public.adjust_points(biz_a, client_loyalty, 100, 'redeemable points seed');
  result := public.redeem_points(biz_a, client_loyalty)::jsonb;
  perform pg_temp.assert_eq(
    (result->>'points_spent')::int,
    50,
    'redeem_points uses active positive points configuration'
  );
  perform pg_temp.assert_eq(
    (select coalesce(sum(remaining), 0)::int from public.points_batches
      where business_id = biz_a and client_id = client_loyalty),
    50,
    'redeem_points drains FIFO points batches'
  );
  perform pg_temp.assert_true(
    exists (
      select 1 from public.credit_ledger cl
       where cl.business_id = biz_a
         and cl.client_id = client_loyalty
         and cl.entry_type = 'loyalty_earn'
         and cl.amount_cents = 500
         and cl.actor = owner_a
    ),
    'redeem_points uses its validated credit scope'
  );

  execute 'reset role';
  update public.loyalty_programs set reward_credit_cents = 0 where business_id = biz_a;
  perform pg_temp.as_user(owner_a);
  begin
    perform public.redeem_points(biz_a, client_loyalty);
    raise exception 'expected zero-credit points configuration to be rejected';
  exception when others then
    perform pg_temp.assert_true(
      sqlerrm like '%no active redeemable points program%',
      'redeem_points rejects zero-credit or non-points configurations'
    );
  end;
  execute 'reset role';
  update public.loyalty_programs set reward_credit_cents = 500 where business_id = biz_a;

  insert into public.membership_plans(
    business_id, name, price_cents, cadence, credit_cents, active
  ) values (
    biz_a, 'V20 Monthly', 8000, 'monthly', 6000, true
  ) returning id into membership_plan;
  perform pg_temp.as_user(owner_a);
  result := public.enroll_membership(
    biz_a, client_membership, membership_plan
  )::jsonb;
  perform pg_temp.assert_true(
    exists (
      select 1
        from public.credit_ledger cl
        join public.sales s on s.id = cl.sale_id and s.business_id = cl.business_id
       where cl.business_id = biz_a
         and cl.client_id = client_membership
         and cl.entry_type = 'membership_credit'
         and cl.amount_cents = 6000
         and cl.actor = owner_a
         and s.kind = 'membership'
         and s.amount_cents = 8000
    ),
    'membership enrollment links exact credit to its charge sale'
  );

  execute 'reset role';
  update public.memberships
     set current_period_start = now() - interval '1 month 1 day',
         current_period_end = now() - interval '1 day'
   where id = (result->>'id')::uuid;
  flow_before := (
    select count(*)::int from public.credit_ledger
     where business_id = biz_a
       and client_id = client_membership
       and entry_type = 'membership_credit'
  );
  perform app.run_membership_renewals();
  flow_after := (
    select count(*)::int from public.credit_ledger
     where business_id = biz_a
       and client_id = client_membership
       and entry_type = 'membership_credit'
  );
  perform pg_temp.assert_eq(
    flow_after - flow_before,
    1,
    'membership renewal appends one validated credit per renewed period'
  );
  perform pg_temp.assert_true(
    (select current_period_end > now()
       from public.memberships
      where id = (result->>'id')::uuid),
    'void membership renewal advances the due membership period'
  );
  perform pg_temp.assert_true(
    not exists (
      select 1 from public.credit_ledger cl
       where cl.business_id = biz_a
         and cl.client_id = client_membership
         and cl.entry_type = 'membership_credit'
         and cl.actor is not null
         and cl.reference like 'membership renewal credit:%'
    ),
    'automated membership renewal records no human actor'
  );
  perform pg_temp.as_user(owner_a);

  begin
    perform public.record_quick_sale(
      biz_a, 100, 'cash', client_a, staff_owner_a, branch_a,
      'missing operation key', null, true
    );
    raise exception 'expected missing quick-sale idempotency key to fail';
  exception when others then
    perform pg_temp.assert_true(
      sqlerrm like '%idempotency key is required%',
      'quick-sale idempotency is mandatory independent of payment creation'
    );
  end;

  result := public.record_quick_sale(
    biz_a, 321, ' CASH ', client_a, staff_owner_a, null,
    '  paid quick sale  ', 'quick-paid-0001', null
  )::jsonb;
  quick_paid_sale := (result->'sale'->>'id')::uuid;
  perform pg_temp.assert_true(
    not (result->>'replayed')::boolean
      and (result->>'payment_id')::uuid is not null,
    'explicit null paid flag canonicalizes to the shipped default true'
  );
  result := public.record_quick_sale(
    biz_a, 321, 'cash', client_a, staff_owner_a, branch_a,
    'paid quick sale', 'quick-paid-0001'
  )::jsonb;
  perform pg_temp.assert_true(
    (result->>'replayed')::boolean
      and (result->'sale'->>'id')::uuid = quick_paid_sale,
    'paid quick-sale replay returns the original sale'
  );
  perform pg_temp.assert_eq(
    (select count(*)::int from public.payments where sale_id = quick_paid_sale), 1,
    'paid quick-sale replay has exactly one payment'
  );
  begin
    perform public.record_quick_sale(
      biz_a, 322, 'cash', client_a, staff_owner_a, branch_a,
      'paid quick sale', 'quick-paid-0001', true
    );
    raise exception 'expected changed quick-sale payload to conflict';
  exception when unique_violation then
    null;
  end;

  result := public.record_quick_sale(
    biz_a, 654, 'paynow', client_a, staff_owner_a, branch_a,
    'unpaid quick sale', 'quick-unpaid-01', false
  )::jsonb;
  quick_unpaid_sale := (result->'sale'->>'id')::uuid;
  result := public.record_quick_sale(
    biz_a, 654, 'paynow', client_a, staff_owner_a, branch_a,
    'unpaid quick sale', 'quick-unpaid-01', false
  )::jsonb;
  perform pg_temp.assert_true(
    (result->>'replayed')::boolean
      and (result->'sale'->>'id')::uuid = quick_unpaid_sale
      and not exists (select 1 from public.payments where sale_id = quick_unpaid_sale),
    'unpaid quick-sale replay is operation-backed without a payment'
  );
  begin
    perform public.record_quick_sale(
      biz_a, 654, 'paynow', client_a, staff_owner_a, branch_a,
      'unpaid quick sale', 'quick-unpaid-01', true
    );
    raise exception 'expected changed paid flag to conflict';
  exception when unique_violation then
    null;
  end;

  insert into public.sales
    (business_id, branch_id, staff_id, client_id, kind, amount_cents, note, idem_key)
  values (biz_a, branch_a, staff_owner_a, client_a, 'service', 10001,
          'v20 service', 'sale-idem-0001')
  returning id into sale_a;

  execute 'reset role';
  insert into public.appointments(
    business_id, branch_id, client_id, staff_id, starts_at, ends_at, status, total_cents
  ) values (
    biz_a, branch_a, client_a, staff_owner_a,
    now() + interval '1 day', now() + interval '1 day 1 hour', 'booked', 500
  ) returning id into appointment_a;
  insert into public.appointments(
    business_id, branch_id, client_id, staff_id, starts_at, ends_at, status, total_cents
  ) values (
    biz_a, branch_a, client_other, staff_owner_a,
    now() + interval '2 days', now() + interval '2 days 1 hour', 'booked', 500
  ) returning id into appointment_other;
  perform pg_temp.as_user(owner_a);
  insert into public.sales(
    business_id, branch_id, staff_id, client_id, kind, amount_cents,
    appointment_id, note
  ) values (
    biz_a, branch_a, staff_owner_a, client_a, 'service', 500,
    appointment_a, 'appointment checkout identity fixture'
  ) returning id into appointment_sale;
  insert into public.sales(
    business_id, branch_id, staff_id, client_id, kind, amount_cents, note
  ) values (
    biz_a, branch_a, staff_owner_a, null, 'gift_card', 100,
    'cross-tenant points FK fixture'
  ) returning id into bad_points_sale;

  points_before := (
    select coalesce(sum(points), 0)::int
      from public.points_ledger
     where business_id = biz_a and client_id = client_a
  );
  batch_before := (
    select coalesce(sum(remaining), 0)::int
      from public.points_batches
     where business_id = biz_a and sale_id = sale_a
  );

  begin
    insert into public.sales(
      business_id, branch_id, staff_id, client_id, kind, amount_cents,
      reversal_reason
    ) values (
      biz_a, branch_a, staff_owner_a, client_a, 'service', 100,
      'metadata on an original sale is forbidden'
    );
    raise exception 'expected original reversal metadata constraint to fail';
  exception when check_violation then
    null;
  end;

  execute 'reset role';
  begin
    perform set_config('app.reclassify_sale', sale_a::text, true);
    update public.sales set idem_key = 'mutated-idem-key' where id = sale_a;
    raise exception 'expected sales.idem_key immutability to fail';
  exception when restrict_violation then
    null;
  end;
  perform set_config('app.reclassify_sale', '', true);
  perform pg_temp.as_user(owner_a);

  begin
    insert into public.credit_ledger
      (business_id, client_id, entry_type, amount_cents, reference)
    values (biz_a, client_a, 'manual_adjust', 1, 'raw credit poison');
    raise exception 'expected raw credit ledger insert denial';
  exception when insufficient_privilege then
    null;
  end;

  begin
    insert into public.points_ledger
      (business_id, client_id, entry_type, points, reference)
    values (biz_a, client_a, 'adjust', 1, 'raw points poison');
    raise exception 'expected raw points ledger insert denial';
  exception when insufficient_privilege then
    null;
  end;

  begin
    insert into public.payments(
      business_id, branch_id, sale_id, client_id, staff_id,
      method, kind, amount_cents, idempotency_key
    ) values (
      biz_a, branch_a, sale_a, client_a, staff_owner_a,
      'cash', 'payment', 1, 'raw-payment-denied'
    );
    raise exception 'expected raw payment insert denial';
  exception when insufficient_privilege then
    null;
  end;

  begin
    truncate table public.payments;
    raise exception 'expected authenticated payment TRUNCATE denial';
  exception when insufficient_privilege then
    null;
  end;
  begin
    truncate table public.points_ledger;
    raise exception 'expected authenticated points TRUNCATE denial';
  exception when insufficient_privilege then
    null;
  end;
  begin
    truncate table public.credit_ledger;
    raise exception 'expected authenticated credit TRUNCATE denial';
  exception when insufficient_privilege then
    null;
  end;

  execute 'reset role';
  begin
    update public.credit_ledger set reference = 'mutated' where id = seed_credit;
    raise exception 'expected credit ledger append-only update guard';
  exception when others then
    perform pg_temp.assert_true(
      sqlstate in ('P0001', '23001')
        and sqlerrm like '%append-only ledger: UPDATE is not permitted%',
      format('credit ledger update failed with expected append-only contract (SQLSTATE %s, message %s)',
             sqlstate, sqlerrm)
    );
  end;
  begin
    update public.points_ledger set reference = 'mutated'
     where business_id = biz_a and sale_id = sale_a;
    raise exception 'expected points ledger append-only update guard';
  exception when others then
    perform pg_temp.assert_true(
      sqlstate in ('P0001', '23001')
        and sqlerrm like '%append-only ledger: UPDATE is not permitted%',
      format('points ledger update failed with expected append-only contract (SQLSTATE %s, message %s)',
             sqlstate, sqlerrm)
    );
  end;
  perform pg_temp.as_user(owner_a);

  execute 'reset role';
  perform set_config('app.credit_ledger_insert_id', bad_credit::text, true);
  perform set_config('app.credit_ledger_write_scope', 'redeem_gift_card', true);
  begin
    insert into public.credit_ledger
      (id, business_id, client_id, entry_type, amount_cents, reference, actor)
    values (bad_credit, biz_a, client_b, 'gift_card_load', 1,
            'cross-tenant client must fail', owner_a);
    raise exception 'expected credit ledger same-tenant client FK to fail';
  exception when foreign_key_violation then
    null;
  end;
  perform set_config('app.credit_ledger_insert_id', '', true);
  perform set_config('app.credit_ledger_write_scope', '', true);

  perform set_config('app.points_ledger_insert_id', bad_points::text, true);
  perform set_config('app.points_ledger_write_scope', 'sale_trigger', true);
  begin
    insert into public.points_ledger
      (id, business_id, client_id, entry_type, points, sale_id, reference, actor)
    values (bad_points, biz_a, client_b, 'earn', 1, bad_points_sale,
            'cross-tenant client must fail', owner_a);
    raise exception 'expected points ledger same-tenant client FK to fail';
  exception when foreign_key_violation then
    null;
  end;
  perform set_config('app.points_ledger_insert_id', '', true);
  perform set_config('app.points_ledger_write_scope', '', true);
  perform pg_temp.as_user(owner_a);

  perform pg_temp.assert_eq(
    (select rate_bps from public.sale_commission where sale_id = sale_a),
    1000,
    'sale commission uses v12 percentage snapshot'
  );
  perform pg_temp.assert_eq(
    (select commission_cents from public.sale_commission where sale_id = sale_a),
    1000,
    'sale commission derives cents from amount and percentage only'
  );

  select public.record_credit_tender(biz_a, sale_a, 2500, 'use customer store credit', 'credit-key-0001')::jsonb
    into result;
  credit_payment := (result->>'payment_id')::uuid;
  v_credit_ledger_id := (result->>'credit_ledger_id')::uuid;

  perform pg_temp.assert_eq(
    (select amount_cents from public.payments where id = credit_payment),
    2500,
    'credit tender creates positive payment'
  );
  perform pg_temp.assert_eq(
    (select amount_cents from public.credit_ledger where id = v_credit_ledger_id),
    -2500,
    'credit tender appends negative credit'
  );
  perform pg_temp.assert_eq(
    (select balance_cents from public.sale_balance where sale_id = sale_a),
    7501,
    'credit tender reduces sale balance without new sale revenue'
  );

  select public.record_credit_tender(biz_a, sale_a, 2500, 'use customer store credit', 'credit-key-0001')::jsonb
    into result;
  perform pg_temp.assert_true((result->>'replayed')::boolean, 'credit tender idempotent replay');
  perform pg_temp.assert_eq(
    (select count(*)::int from public.credit_tenders where sale_id = sale_a),
    1,
    'credit tender replay does not duplicate tender row'
  );
  perform pg_temp.assert_true(
    exists (
      select 1
        from public.financial_operations fo
        join public.credit_tenders ct on ct.operation_id = fo.id
       where fo.business_id = biz_a
         and fo.sale_id = sale_a
         and fo.operation_type = 'credit_tender'
         and fo.status = 'completed'
         and fo.request_hash = md5(fo.request_payload::text)
         and ct.payment_id = credit_payment
         and ct.credit_ledger_id = v_credit_ledger_id
         and ct.amount_cents = 2500
    ),
    'credit tender parent operation is completed with exact child proof'
  );

  begin
    perform public.record_credit_tender(
      biz_a, sale_a, 2400, 'use customer store credit', 'credit-key-0001'
    );
    raise exception 'expected changed amount on credit replay to fail';
  exception when unique_violation then
    null;
  end;

  begin
    perform public.record_credit_tender(
      biz_a, sale_a, 2500, 'different immutable reason', 'credit-key-0001'
    );
    raise exception 'expected changed reason on credit replay to fail';
  exception when unique_violation then
    null;
  end;

  perform pg_temp.as_user(manager_a);
  begin
    perform public.record_credit_tender(
      biz_a, sale_a, 2500, 'use customer store credit', 'credit-key-0001'
    );
    raise exception 'expected different authorized actor replay to fail';
  exception when unique_violation then
    null;
  end;
  perform pg_temp.as_user(owner_a);

  perform pg_temp.as_user(bookkeeper_a);
  begin
    perform public.record_credit_tender(
      biz_a, sale_a, 2500, 'bookkeeper replay must fail before conflict', 'credit-key-0001'
    );
    raise exception 'expected bookkeeper credit replay role denial';
  exception when others then
    perform pg_temp.assert_true(
      sqlstate = '42501'
        and sqlerrm like '%do not have permission to take payment%create_sales%',
      format('unauthorized credit replay is denied before idempotency conflict (SQLSTATE %s, message %s)',
             sqlstate, sqlerrm)
    );
  end;
  perform pg_temp.as_user(owner_a);

  begin
    perform public.record_credit_tender(biz_a, sale_a, 999999, 'overdraft attempt', 'credit-key-overdraft');
    raise exception 'expected overdraft to fail';
  exception when others then
    perform pg_temp.assert_true(sqlerrm like '%exceeds sale balance due%' or sqlerrm like '%insufficient store credit%',
      'credit tender rejects overdraft/race shape');
  end;

  begin
    perform public.record_payment(
      biz_a, 'cash', 100, sale_a, null, client_a, staff_owner_a,
      'payment', branch_a, null, null, null
    );
    raise exception 'expected missing payment idempotency key to fail';
  exception when others then
    perform pg_temp.assert_true(
      sqlerrm like '%idempotency key is required%',
      'record_payment requires an idempotency key'
    );
  end;

  begin
    perform public.record_payment(
      biz_a, 'cash', 100, sale_a, null, client_other, staff_owner_a,
      'payment', branch_a, null, null, 'bad-client-override'
    );
    raise exception 'expected contradictory payment client override to fail';
  exception when others then
    perform pg_temp.assert_true(
      sqlerrm like '%client override conflicts%',
      'record_payment rejects contradictory client override'
    );
  end;

  begin
    perform public.record_payment(
      biz_a, 'cash', 100, sale_a, null, client_a, staff_owner_a,
      'payment', branch_b, null, null, 'bad-branch-override'
    );
    raise exception 'expected contradictory payment branch override to fail';
  exception when others then
    perform pg_temp.assert_true(
      sqlerrm like '%branch override conflicts%',
      'record_payment rejects contradictory branch override before locking'
    );
  end;

  begin
    perform public.record_payment(
      biz_a, 'cash', 100, sale_a, appointment_a, client_a, staff_owner_a,
      'payment', branch_a, null, null, 'bad-sale-appt-link'
    );
    raise exception 'expected unrelated sale/appointment payment to fail';
  exception when others then
    perform pg_temp.assert_true(
      sqlerrm like '%do not describe one checkout%',
      'record_payment requires sale.appointment_id to match'
    );
  end;

  begin
    perform public.record_payment(
      biz_a, 'cash', 100, appointment_sale, appointment_other, client_a,
      staff_owner_a, 'payment', branch_a, null, null, 'bad-appt-identity'
    );
    raise exception 'expected contradictory linked appointment identity to fail';
  exception when others then
    perform pg_temp.assert_true(
      sqlerrm like '%do not describe one checkout%',
      'record_payment rejects a different appointment for a linked sale'
    );
  end;

  perform public.record_payment(
    biz_a, 'cash', 100, appointment_sale, appointment_a, null,
    staff_owner_a, 'payment', null, ' appointment deposit ', ' linked checkout ',
    'good-sale-appt-key'
  );
  perform pg_temp.assert_true(
    exists (
      select 1 from public.payments p
       where p.business_id = biz_a
         and p.sale_id = appointment_sale
         and p.appointment_id = appointment_a
         and p.client_id = client_a
         and p.branch_id = branch_a
         and p.reference = 'appointment deposit'
         and p.note = 'linked checkout'
    ),
    'record_payment derives and stores canonical locked checkout identity'
  );

  begin
    perform public.record_payment(biz_a, 'credit', 100, sale_a, null, client_a, staff_owner_a, 'payment', branch_a, null, null, 'raw-credit-pay');
    raise exception 'expected raw credit payment to fail';
  exception when feature_not_supported then
    null;
  end;

  begin
    perform public.record_payment(biz_a, 'gift_card', 100, sale_a, null, client_a,
      staff_owner_a, 'payment', branch_a, null, null, 'raw-gift-card-pay');
    raise exception 'expected gift-card payment bypass to fail';
  exception when feature_not_supported then
    null;
  end;

  begin
    perform public.record_payment(biz_a, 'cash', 100, sale_a, null, client_a,
      staff_owner_a, 'refund', branch_a, null, null, 'raw-refund-pay');
    raise exception 'expected standalone refund route to fail';
  exception when feature_not_supported then
    null;
  end;

  perform public.record_payment(
    biz_a, 'cash', 7501, sale_a, null, client_a, staff_owner_a,
    'payment', branch_a, 'cash settlement', null, 'cash-pay-0001'
  );

  perform public.record_payment(
    biz_a, 'cash', 7501, sale_a, null, client_a, staff_owner_a,
    'payment', branch_a, '  cash settlement  ', '   ', '  cash-pay-0001  '
  );
  perform pg_temp.assert_eq(
    (select count(*)::int from public.payments
      where business_id = biz_a and idempotency_key = 'cash-pay-0001'),
    1,
    'canonical whitespace replay returns one payment'
  );

  begin
    perform public.record_payment(
      biz_a, 'cash', 7501, sale_a, null, client_a, staff_owner_a,
      'payment', branch_a, 'changed reference', null, 'cash-pay-0001'
    );
    raise exception 'expected changed payment reference replay to fail';
  exception when unique_violation then
    null;
  end;

  begin
    perform public.record_payment(
      biz_a, 'cash', 7501, sale_a, null, client_a, staff_owner_a,
      'payment', branch_a, 'cash settlement', 'changed note', 'cash-pay-0001'
    );
    raise exception 'expected changed payment note replay to fail';
  exception when unique_violation then
    null;
  end;

  begin
    perform public.record_payment(
      biz_a, 'cash', 7500, sale_a, null, client_a, staff_owner_a,
      'payment', branch_a, 'cash settlement', null, 'cash-pay-0001'
    );
    raise exception 'expected payment child key immutable amount mismatch to fail';
  exception when unique_violation then
    null;
  end;

  perform pg_temp.as_user(manager_a);
  begin
    perform public.record_payment(
      biz_a, 'cash', 7501, sale_a, null, client_a, staff_owner_a,
      'payment', branch_a, 'cash settlement', null, 'cash-pay-0001'
    );
    raise exception 'expected payment replay by a different actor to fail';
  exception when unique_violation then
    null;
  end;
  perform pg_temp.as_user(owner_a);

  before_count := (select count(*) from public.sales where reversal_of = sale_a);
  result := public.reverse_sale(biz_a, sale_a, 'full refund before launch pilot', 'reverse-key-0001')::jsonb;
  reversal_id := (result->>'reversal_sale_id')::uuid;
  after_count := (select count(*) from public.sales where reversal_of = sale_a);

  perform pg_temp.assert_eq(before_count, 0, 'no reversal before act');
  perform pg_temp.assert_eq(after_count, 1, 'one reversal after act');
  perform pg_temp.assert_eq(
    (select amount_cents from public.sales where id = reversal_id),
    -10001,
    'full reversal posts negative sale'
  );
  perform pg_temp.assert_eq(
    (result->>'refunded_payment_cents')::int,
    10001,
    'generated refunds exactly equal validated payment total'
  );
  perform pg_temp.assert_true(
    exists (
      select 1
        from public.financial_operations fo
        join public.sale_reversal_audits a on a.operation_id = fo.id
       where fo.business_id = biz_a
         and fo.sale_id = sale_a
         and fo.operation_type = 'sale_reversal'
         and fo.status = 'completed'
         and fo.request_hash = md5(fo.request_payload::text)
         and a.reversal_sale_id = reversal_id
         and a.refunded_payment_cents = 10001
         and a.points_clawed_back = 0
         and a.points_batch_remaining_decremented = 0
    ),
    'reversal parent operation and final audit are exact'
  );
  perform pg_temp.assert_eq(
    (select coalesce(sum(amount_cents), 0)::int
       from public.sale_reversal_payment_links
      where reversal_sale_id = reversal_id),
    10001,
    'refund evidence links equal validated total'
  );
  perform pg_temp.assert_true(
    not exists (
      select 1
        from public.sale_reversal_payment_links
       where reversal_sale_id = reversal_id
         and method not in ('cash', 'credit')
    ),
    'launch refund children use only cash and credit'
  );
  perform pg_temp.assert_eq(
    (select coalesce(sum(amount_cents), 0)::int
       from public.credit_ledger
      where sale_id = reversal_id and entry_type = 'manual_adjust'
        and amount_cents > 0),
    2500,
    'credit restoration exactly equals proven store-credit tender'
  );
  perform pg_temp.assert_eq(
    (select balance_cents from public.sale_balance where sale_id = sale_a),
    0,
    'sale_balance nets full reversal and refunds'
  );
  perform pg_temp.assert_eq(
    (select payment_status from public.sale_balance where sale_id = sale_a),
    'paid',
    'fully reversed sale has no phantom receivable'
  );
  perform pg_temp.assert_eq(
    (select count(*)::int from public.sale_balance where sale_id = reversal_id),
    0,
    'reversal row is excluded from sale_balance'
  );
  perform pg_temp.assert_eq(
    (select coalesce(sum(dm.amount_cents),0)::int
       from public.cash_drawer_movements dm
       join public.payments p on p.id = dm.payment_id
      where dm.business_id = biz_a and p.sale_id = sale_a),
    0,
    'cash drawer nets the reversed sale cash and refund to zero'
  );
  perform pg_temp.assert_eq(
    (select coalesce(sum(commission_cents),0)::int
       from public.sale_commission
      where sale_id in (sale_a, reversal_id)),
    0,
    'percentage-only commission nets original and reversal to zero'
  );
  points_after := (
    select coalesce(sum(points), 0)::int
      from public.points_ledger
     where business_id = biz_a and client_id = client_a
  );
  batch_after := (
    select coalesce(sum(remaining), 0)::int
      from public.points_batches
     where business_id = biz_a and sale_id = sale_a
  );
  perform pg_temp.assert_eq(points_after, points_before,
    'launch reversal does not claw back points without provenance/policy');
  perform pg_temp.assert_eq(batch_after, batch_before,
    'launch reversal does not zero or mutate points batches');
  perform pg_temp.assert_eq(
    (select count(*)::int from public.points_ledger where sale_id = reversal_id),
    0,
    'reversal creates no points adjustment row while clawback is disabled'
  );

  result := public.reverse_sale(biz_a, sale_a, 'full refund before launch pilot', 'reverse-key-0001')::jsonb;
  perform pg_temp.assert_true((result->>'replayed')::boolean, 'sale reversal idempotent replay');
  perform pg_temp.assert_eq(
    (select count(*)::int from public.sales where reversal_of = sale_a),
    1,
    'sale reversal replay does not duplicate'
  );

  begin
    perform public.reverse_sale(
      biz_a, sale_a, 'different immutable reversal reason', 'reverse-key-0001'
    );
    raise exception 'expected changed reversal request on replay to fail';
  exception when unique_violation then
    null;
  end;

  perform pg_temp.as_user(manager_a);
  begin
    perform public.reverse_sale(
      biz_a, sale_a, 'full refund before launch pilot', 'reverse-key-0001'
    );
    raise exception 'expected reversal replay by different authorized actor to fail';
  exception when unique_violation then
    null;
  end;
  perform pg_temp.as_user(owner_a);

  result := public.record_credit_tender(
    biz_a, sale_a, 2500, 'use customer store credit', 'credit-key-0001'
  )::jsonb;
  perform pg_temp.assert_true((result->>'replayed')::boolean,
    'exact credit tender replay remains available after later full reversal');

  begin
    perform public.record_credit_tender(
      biz_a, sale_a, 100, 'new tender after reversal', 'credit-key-after-reversal'
    );
    raise exception 'expected new credit tender after reversal to fail';
  exception when others then
    perform pg_temp.assert_true(sqlerrm like '%reversed sale%',
      'new credit tender is rejected after full reversal');
  end;

  begin
    perform public.record_payment(
      biz_a, 'cash', 100, sale_a, null, client_a, staff_owner_a,
      'payment', branch_a, null, null, 'payment-after-reversal'
    );
    raise exception 'expected positive payment after reversal to fail';
  exception when others then
    perform pg_temp.assert_true(sqlerrm like '%fully reversed sale%',
      'RPC blocks positive payment after full reversal');
  end;

  execute 'reset role';
  perform set_config('app.payment_insert_id', bad_payment::text, true);
  perform set_config('app.payment_write_scope', 'record_payment', true);
  begin
    insert into public.payments(
      id, business_id, branch_id, sale_id, client_id, staff_id,
      method, kind, amount_cents, idempotency_key, created_by
    ) values (
      bad_payment, biz_a, branch_a, sale_a, client_a, staff_owner_a,
      'cash', 'payment', 1, 'structural-after-reversal', owner_a
    );
    raise exception 'expected structural reversed-sale payment guard to fail';
  exception when check_violation then
    null;
  end;
  perform set_config('app.payment_insert_id', '', true);
  perform set_config('app.payment_write_scope', '', true);
  perform pg_temp.as_user(owner_a);

  execute 'reset role';
  update public.staff set active = false where id = staff_owner_a;
  perform pg_temp.as_user(owner_a);
  perform pg_temp.assert_true(
    not app.has_perm(biz_a, 'refund_sales')
    and not app.can_see_branch(biz_a, branch_a),
    'inactive staff loses tenant permission and branch visibility'
  );
  begin
    perform public.reverse_sale(
      biz_a, sale_a, 'full refund before launch pilot', 'reverse-key-0001'
    );
    raise exception 'expected inactive actor replay denial';
  exception when insufficient_privilege then
    null;
  end;
  execute 'reset role';
  update public.staff set active = true where id = staff_owner_a;
  perform pg_temp.as_user(owner_a);

  perform pg_temp.as_user(staff_a);
  begin
    perform public.reverse_sale(biz_a, sale_a, 'staff replay refund should fail', 'reverse-key-0001');
    raise exception 'expected staff reversal replay role denial';
  exception when insufficient_privilege then
    null;
  end;
  perform pg_temp.as_user(owner_a);

  begin
    perform public.reverse_sale(biz_a, sale_a, 'second full refund should fail', 'reverse-key-0002');
    raise exception 'expected double reversal to fail';
  exception when others then
    perform pg_temp.assert_true(sqlerrm like '%already fully reversed%', 'second key double reversal rejected');
  end;

  begin
    perform public.reverse_sale(biz_a, sale_b, 'cross tenant reversal attempt', 'reverse-key-x-tenant');
    raise exception 'expected cross tenant reversal to fail';
  exception when others then
    perform pg_temp.assert_true(sqlerrm like '%sale not found%', 'cross-tenant sale reversal denied');
  end;

  insert into public.sales(business_id, branch_id, staff_id, client_id, kind, amount_cents, note)
  values (biz_a, branch_a, staff_owner_a, client_a, 'service', 1000, 'provider refund test')
  returning id into card_sale;
  perform public.record_payment(
    biz_a, 'card', 1000, card_sale, null, client_a, staff_owner_a,
    'payment', branch_a, null, null, 'card-provider-payment'
  );
  begin
    perform public.reverse_sale(
      biz_a, card_sale, 'provider settlement unavailable', 'reverse-provider-disabled'
    );
    raise exception 'expected provider refund to be launch-disabled';
  exception when feature_not_supported then
    null;
  end;

  insert into public.sales(business_id, branch_id, staff_id, client_id, kind, amount_cents, note)
  values (biz_a, branch_a, staff_owner_a, client_a, 'membership', 1000, 'allowlist test')
  returning id into membership_sale;
  begin
    perform public.reverse_sale(
      biz_a, membership_sale, 'unsupported prepayment reversal', 'reverse-membership-disabled'
    );
    raise exception 'expected non-allowlisted sale kind to fail';
  exception when others then
    perform pg_temp.assert_true(sqlerrm like '%supports only service, retail and quick_sale%',
      'reversal uses a positive sale-kind allowlist');
  end;

  insert into public.sales(business_id, branch_id, staff_id, client_id, kind, amount_cents, note)
  values (biz_a, branch_a, staff_owner_a, client_a, 'service', 1000, 'negative method net test')
  returning id into negative_method_sale;
  perform public.record_payment(
    biz_a, 'card', 100, negative_method_sale, null, client_a, staff_owner_a,
    'payment', branch_a, null, null, 'negative-net-offset-card'
  );
  execute 'reset role';
  perform set_config('app.payment_insert_id', bad_refund::text, true);
  perform set_config('app.payment_write_scope', 'sale_reversal', true);
  insert into public.payments(
    id, business_id, branch_id, sale_id, client_id, staff_id,
    method, kind, amount_cents, idempotency_key, created_by
  ) values (
    bad_refund, biz_a, branch_a, negative_method_sale, client_a, staff_owner_a,
    'cash', 'refund', -100, 'legacy-negative-method', owner_a
  );
  perform set_config('app.payment_insert_id', '', true);
  perform set_config('app.payment_write_scope', '', true);
  perform pg_temp.as_user(owner_a);
  begin
    perform public.reverse_sale(
      biz_a, negative_method_sale, 'negative method net is undefined', 'reverse-negative-method'
    );
    raise exception 'expected negative per-method net rejection';
  exception when others then
    perform pg_temp.assert_true(sqlerrm like '%negative per-method payment net%',
      'negative per-method net is rejected before refund generation');
  end;

  insert into public.sales(business_id, branch_id, staff_id, client_id, kind, amount_cents, note)
  values (biz_a, branch_a, staff_owner_a, client_a, 'service', 1000, 'unproven credit test')
  returning id into unproven_credit_sale;
  execute 'reset role';
  perform set_config('app.payment_insert_id', bad_credit_payment::text, true);
  perform set_config('app.payment_write_scope', 'credit_tender', true);
  insert into public.payments(
    id, business_id, branch_id, sale_id, client_id, staff_id,
    method, kind, amount_cents, idempotency_key, created_by
  ) values (
    bad_credit_payment, biz_a, branch_a, unproven_credit_sale, client_a, staff_owner_a,
    'credit', 'payment', 100, 'unproven-credit-payment', owner_a
  );
  perform set_config('app.payment_insert_id', '', true);
  perform set_config('app.payment_write_scope', '', true);
  perform pg_temp.as_user(owner_a);
  begin
    perform public.reverse_sale(
      biz_a, unproven_credit_sale, 'credit proof is intentionally absent', 'reverse-unproven-credit'
    );
    raise exception 'expected exact credit_tenders proof rejection';
  exception when check_violation then
    null;
  end;

  perform pg_temp.assert_eq(
    (select count(*)::int
       from public.financial_operations
      where idempotency_key in (
        'reverse-provider-disabled', 'reverse-membership-disabled',
        'reverse-negative-method', 'reverse-unproven-credit'
      )),
    0,
    'failed preflight checks create no parent reservation or child side effects'
  );

  execute 'reset role';
  insert into public.referrals(
    business_id, referrer_client_id, referred_client_id,
    status, reward_cents, qualified_at, qualified_sale_id
  ) values (
    biz_a, client_loyalty, client_other,
    'rewarded', 500, now() - interval '1 day', null
  ) returning id into legacy_referral;
  perform pg_temp.as_user(owner_a);

  insert into public.sales(
    business_id, branch_id, staff_id, client_id, kind, amount_cents, note
  ) values (
    biz_a, branch_a, staff_owner_a, client_other, 'service', 700,
    'post-v20 sale after unmatched legacy referral'
  ) returning id into legacy_sale;
  perform public.record_payment(
    biz_a, 'cash', 700, legacy_sale, null, client_other, staff_owner_a,
    'payment', branch_a, null, null, 'legacy-post-v20-payment'
  );
  result := public.reverse_sale(
    biz_a, legacy_sale, 'post-v20 sale has exact referral provenance',
    'legacy-post-v20-reverse'
  )::jsonb;
  perform pg_temp.assert_true(
    (result->>'reversal_sale_id')::uuid is not null,
    'unmatched legacy referral does not block a post-v20 sale reversal'
  );

  insert into public.sales(
    business_id, branch_id, staff_id, client_id, kind, amount_cents, note
  ) values (
    biz_a, branch_a, staff_owner_a, client_other, 'service', 100,
    'ambiguous legacy referral candidate one'
  ) returning id into legacy_candidate_one;
  insert into public.sales(
    business_id, branch_id, staff_id, client_id, kind, amount_cents, note
  ) values (
    biz_a, branch_a, staff_owner_a, client_other, 'service', 100,
    'ambiguous legacy referral candidate two'
  ) returning id into legacy_candidate_two;

  execute 'reset role';
  insert into public.legacy_referral_provenance(
    referral_id, business_id, snapshot_at, candidate_sale_ids, resolution
  ) values (
    legacy_referral, biz_a, now(),
    array[legacy_candidate_one, legacy_candidate_two], 'ambiguous'
  );
  insert into public.legacy_referral_sale_candidates(
    referral_id, business_id, sale_id
  ) values
    (legacy_referral, biz_a, legacy_candidate_one),
    (legacy_referral, biz_a, legacy_candidate_two);
  perform pg_temp.as_user(owner_a);
  begin
    perform public.reverse_sale(
      biz_a, legacy_candidate_one, 'ambiguous legacy candidate needs review',
      'legacy-ambiguous-reverse'
    );
    raise exception 'expected ambiguous pre-v20 referral candidate to require review';
  exception when feature_not_supported then
    null;
  end;

  perform pg_temp.as_user(staff_a);
  begin
    perform public.resolve_legacy_referral(
      biz_a, legacy_referral, legacy_candidate_one,
      'staff must not resolve historical referral provenance'
    );
    raise exception 'expected unauthorized legacy referral resolution to fail';
  exception when insufficient_privilege then
    null;
  end;
  perform pg_temp.as_user(owner_b);
  begin
    perform public.resolve_legacy_referral(
      biz_b, legacy_referral, legacy_candidate_one,
      'cross tenant legacy referral resolution must fail'
    );
    raise exception 'expected cross-tenant legacy referral resolution to fail';
  exception when others then
    perform pg_temp.assert_true(
      sqlerrm like '%provenance was not captured%'
        or sqlerrm like '%not a captured candidate%',
      'cross-tenant referral resolution is rejected without information-bearing replay'
    );
  end;
  perform pg_temp.as_user(owner_a);
  result := public.resolve_legacy_referral(
    biz_a, legacy_referral, legacy_candidate_one,
    'owner selected the documented qualifying sale'
  )::jsonb;
  perform pg_temp.assert_true(
    not (result->>'replayed')::boolean
      and (result->>'selected_sale_id')::uuid = legacy_candidate_one,
    'authorized resolution appends the selected-sale decision'
  );
  execute 'reset role';
  begin
    update public.legacy_referral_resolution_events
       set reason = 'attempted mutation of permanent resolution'
     where referral_id = legacy_referral;
    raise exception 'expected legacy resolution event mutation to fail';
  exception when others then
    perform pg_temp.assert_true(
      sqlstate in ('P0001', '23001')
        and sqlerrm like '%append-only ledger: UPDATE is not permitted%',
      format('legacy resolution update failed with expected append-only contract (SQLSTATE %s, message %s)',
             sqlstate, sqlerrm)
    );
  end;
  perform pg_temp.as_user(owner_a);
  result := public.reverse_sale(
    biz_a, legacy_candidate_one,
    'resolved legacy referral sale is fully reversed',
    'legacy-resolved-reverse'
  )::jsonb;
  perform pg_temp.assert_true(
    (result->'effects'->>'referral_reversed')::boolean
      and exists (
        select 1 from public.credit_ledger cl
         where cl.business_id = biz_a
           and cl.client_id = client_loyalty
           and cl.sale_id = (result->>'reversal_sale_id')::uuid
           and cl.entry_type = 'manual_adjust'
           and cl.amount_cents = -500
      ),
    'selected legacy sale drives the exact referral clawback on reversal'
  );

  execute 'reset role';
  insert into public.referrals(
    business_id, referrer_client_id, referred_client_id,
    status, reward_cents, qualified_at, qualified_sale_id
  ) values (
    biz_a, client_a, client_no_link, 'rewarded', 300,
    now() - interval '2 days', null
  ) returning id into legacy_no_link_referral;
  perform pg_temp.as_user(owner_a);
  insert into public.sales(
    business_id, branch_id, staff_id, client_id, kind, amount_cents, note
  ) values (
    biz_a, branch_a, staff_owner_a, client_no_link, 'service', 90,
    'legacy no-link candidate one'
  ) returning id into legacy_no_link_candidate;
  insert into public.sales(
    business_id, branch_id, staff_id, client_id, kind, amount_cents, note
  ) values (
    biz_a, branch_a, staff_owner_a, client_no_link, 'service', 90,
    'legacy no-link candidate two'
  ) returning id into legacy_no_link_candidate_two;
  execute 'reset role';
  insert into public.legacy_referral_provenance(
    referral_id, business_id, snapshot_at, candidate_sale_ids, resolution
  ) values (
    legacy_no_link_referral, biz_a, now(),
    array[legacy_no_link_candidate, legacy_no_link_candidate_two], 'ambiguous'
  );
  insert into public.legacy_referral_sale_candidates(referral_id, business_id, sale_id)
  values
    (legacy_no_link_referral, biz_a, legacy_no_link_candidate),
    (legacy_no_link_referral, biz_a, legacy_no_link_candidate_two);
  perform pg_temp.as_user(owner_a);
  result := public.resolve_legacy_referral(
    biz_a, legacy_no_link_referral, null,
    'historical evidence cannot support an exact sale link'
  )::jsonb;
  perform pg_temp.assert_true(
    result->>'decision' = 'no_link' and result->>'selected_sale_id' is null,
    'authorized no-link resolution records the explicit immutable decision'
  );
  result := public.reverse_sale(
    biz_a, legacy_no_link_candidate,
    'no-link resolution permits candidate sale reversal',
    'legacy-no-link-reverse'
  )::jsonb;
  perform pg_temp.assert_true(
    not (result->'effects'->>'referral_reversed')::boolean,
    'no-link decision permits reversal without an invented referral clawback'
  );

  begin
    perform public.get_revenue_summary(biz_a, date '2026-07-20', date '2026-07-19', branch_a);
    raise exception 'expected invalid report date range to fail';
  exception when others then
    perform pg_temp.assert_true(sqlerrm like '%p_from must be on or before p_to%',
      'report validates date ordering');
  end;
  begin
    perform public.get_revenue_summary(biz_a, date '2026-07-19', date '2026-07-19', branch_b);
    raise exception 'expected report cross-tenant branch rejection';
  exception when others then
    perform pg_temp.assert_true(sqlerrm like '%branch does not belong%',
      'report enforces branch tenant equality');
  end;

  perform pg_temp.as_user(owner_b);
  insert into public.sales(
    business_id, branch_id, kind, amount_cents, occurred_at, note
  ) values (
    biz_b, branch_b, 'service', 1234, '2026-07-18 16:30:00+00', 'SGT boundary sale'
  );
  report := public.get_revenue_summary(
    biz_b, date '2026-07-19', date '2026-07-19', branch_b
  )::jsonb;
  perform pg_temp.assert_eq(
    (report->>'revenue_accrual_cents')::bigint,
    1234::bigint,
    'report uses explicit Asia/Singapore half-open timestamptz bounds'
  );
  perform pg_temp.as_user(owner_a);

  perform pg_temp.as_user(staff_a);
  begin
    perform public.reverse_sale(biz_a, sale_a, 'staff refund should fail', 'reverse-key-staff');
    raise exception 'expected staff refund role denial';
  exception when insufficient_privilege then
    null;
  end;

  perform pg_temp.as_anon();
  begin
    perform public.record_credit_tender(biz_a, sale_a, 100, 'anon credit tender fail', 'credit-key-anon');
    raise exception 'expected anon tender denial';
  exception when insufficient_privilege then
    null;
  end;
end $$;

rollback;
