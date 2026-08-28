-- Acceptance suite for nestly_v572 -- "a module set Off cannot write that module's tables".
-- Runs against PATCHED production inside begin/rollback; nothing persists.
--
-- It uses the REAL reported account rather than a synthetic fixture, because the defect was
-- reported against that account and because minting auth users adds failure modes that have
-- nothing to do with the property under test. Every statement is a read or a rolled-back write.
--
-- The property under test is NOT "reader A agrees with reader B" (v568's lesson: such a check
-- goes tautological the moment both delegate to one core). It states the rule directly:
--   a staff member whose module is Off cannot write that module's tables,
--   AND still reads them (the till depends on it),
--   AND an owner is unaffected.

begin;

create temp table _r(id text primary key, ok boolean, detail text) on commit drop;
grant all on _r to authenticated;

do $fixture$
declare
  v_biz uuid;
  v_denied uuid;   -- auth user of a staff member denied 'services'
  v_owner uuid;
begin
  -- the account the owner reported: an approved, active staff row whose allowlist omits 'services'
  select st.business_id, st.user_id into v_biz, v_denied
  from public.staff st
  where st.active and st.access_state='approved' and st.user_id is not null
    and st.role <> 'owner' and st.modules is not null
    and not (st.modules @> array['services'])
  order by st.id
  limit 1;

  if v_biz is null then
    raise exception 'v572 suite: no module-denied staff account exists to test with';
  end if;

  select st.user_id into v_owner
  from public.staff st
  where st.business_id = v_biz and st.role='owner' and st.active and st.user_id is not null
  limit 1;

  if v_owner is null then
    raise exception 'v572 suite: business % has no owner login to contrast against', v_biz;
  end if;

  perform set_config('test.biz', v_biz::text, true);
  perform set_config('test.denied', v_denied::text, true);
  perform set_config('test.owner', v_owner::text, true);
end
$fixture$;

-- ------------------------------------------------------------------ as the DENIED staff member
do $denied$
declare
  v_biz uuid := current_setting('test.biz')::uuid;
  v_svc uuid;
  v_before int;
  v_after int;
  v_rows int;
  v_read int;
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', current_setting('test.denied'), 'role','authenticated')::text, true);
  set local role authenticated;

  insert into _r values ('A1_authority_says_denied',
    app.can_module_write(v_biz,'services') is false,
    'can_module_write(services) = '||coalesce(app.can_module_write(v_biz,'services')::text,'null'));

  -- A2: the read must SURVIVE -- the till renders the service menu for a till-permitted teammate
  select count(*) into v_read from public.services where business_id = v_biz;
  insert into _r values ('A2_read_preserved', v_read > 0,
    'services rows visible to the denied staff member: '||v_read);

  select id, price_cents into v_svc, v_before
  from public.services where business_id = v_biz order by id limit 1;

  -- A3: the write that PRODUCTION ALLOWED before this migration (SGD 30.00 -> 35.00)
  update public.services set price_cents = price_cents + 500 where id = v_svc;
  get diagnostics v_rows = row_count;
  select price_cents into v_after from public.services where id = v_svc;
  insert into _r values ('A3_update_refused', v_rows = 0 and v_after = v_before,
    'rows_updated='||v_rows||' price_before='||v_before||' price_after='||coalesce(v_after::text,'null'));

  -- A4: insert is refused too (RLS raises rather than returning 0 rows)
  begin
    insert into public.services(business_id, name, price_cents, duration_min)
      values (v_biz, 'v572 suite probe', 100, 10);
    insert into _r values ('A4_insert_refused', false, 'INSERT succeeded -- it must not');
  exception when insufficient_privilege then
    insert into _r values ('A4_insert_refused', true, 'insert refused with 42501');
  end;

  -- A5: delete is refused (the command DELETE is governed by USING alone -- the hole v572 closed
  --     on service_branches; assert the same on services)
  delete from public.services where id = v_svc;
  get diagnostics v_rows = row_count;
  insert into _r values ('A5_delete_refused', v_rows = 0, 'rows_deleted='||v_rows);

  -- A6: waitlist -- the second write production allowed
  begin
    insert into public.waitlist(business_id, name, status)
      values (v_biz, 'v572 suite probe', 'waiting');
    insert into _r values ('A6_waitlist_insert_refused', false, 'INSERT succeeded -- it must not');
  exception when insufficient_privilege then
    insert into _r values ('A6_waitlist_insert_refused', true, 'insert refused with 42501');
  end;

  -- A7: change_requests -- approving a customer's reschedule is an approval, not mere membership
  update public.change_requests set status='approved'
   where business_id = v_biz and status='pending';
  get diagnostics v_rows = row_count;
  insert into _r values ('A7_change_request_approval_refused', v_rows = 0,
    'change_requests approved='||v_rows);

  reset role;
  perform set_config('request.jwt.claims', null, true);
end
$denied$;

-- --------------------------------------------------------------------------- as the OWNER
do $owner$
declare
  v_biz uuid := current_setting('test.biz')::uuid;
  v_svc uuid;
  v_rows int;
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', current_setting('test.owner'), 'role','authenticated')::text, true);
  set local role authenticated;

  insert into _r values ('B1_owner_still_permitted',
    app.can_module_write(v_biz,'services') is true,
    'owner can_module_write(services) = '||coalesce(app.can_module_write(v_biz,'services')::text,'null'));

  select id into v_svc from public.services where business_id = v_biz order by id limit 1;
  update public.services set price_cents = price_cents + 500 where id = v_svc;
  get diagnostics v_rows = row_count;
  insert into _r values ('B2_owner_write_unaffected', v_rows = 1, 'owner rows_updated='||v_rows);

  reset role;
  perform set_config('request.jwt.claims', null, true);
end
$owner$;

-- ------------------------------------------------------- policy shape (no permissive ALL left)
do $shape$
declare
  v_left text;
begin
  select string_agg(c.relname||'.'||pol.polname, ', ') into v_left
  from pg_policy pol join pg_class c on c.oid = pol.polrelid
  where c.relname in ('services','service_products','service_branches','waitlist',
                      'booking_requests','appointment_services')
    and pol.polcmd = '*'
    and pg_get_expr(pol.polqual, pol.polrelid) not like '%is_super_admin%';
  insert into _r values ('C1_no_permissive_all_policy_remains', v_left is null,
    coalesce('still ALL: '||v_left, 'every write command is its own policy'));
end
$shape$;

select id, case when ok then 'PASS' else 'FAIL' end as result, detail from _r order by id;

rollback;
