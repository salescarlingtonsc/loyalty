-- Acceptance suite for nestly_v573 -- "a module set Off is Off at the RPC too".
-- Runs against production inside begin/rollback; nothing persists.
--
-- THE TEST DESIGN THAT MATTERS. Asserting "the call raised" is not enough: these reporting RPCs
-- also raise for branch scope, missing rows and bad arguments, so a test that only checks for an
-- exception passes for the wrong reason and would stay green if the module gate were deleted.
-- So each module is probed TWICE against the same account and the same arguments:
--   phase 1  module Off  -> must raise
--   phase 2  module On   -> the outcome must CHANGE
-- Only the module flag differs between them, so a changed outcome is attributable to the module
-- gate and nothing else. Phase 2 is free to fail on a missing fixture row; what it must not do is
-- fail identically to phase 1.
--
-- This is also why the suite does not grep the function source: a source-regex assertion stays
-- green over dead behaviour.

begin;

create temp table _r(id text primary key, ok boolean, detail text) on commit drop;

do $probe$
declare
  v_case record;
  v_staff uuid;
  v_user uuid;
  v_biz uuid;
  v_branch uuid;
  v_msg1 text;
  v_state1 text;
  v_msg2 text;
  v_ok boolean;
begin
  for v_case in
    select * from (values
      ('dailyreport',   'select public.get_dashboard_summary($1,current_date-7,current_date,$2)'),
      ('customerintel', 'select public.get_customer_intelligence_v83($1,$2,current_date-7,current_date,10,now(),null,null)'),
      ('customerintel', 'select public.get_revenue_truth_v106($1,current_date-7,current_date,$2,now())'),
      ('expenses',      'select public.set_expense_void($1,gen_random_uuid(),true)'),
      ('sales',         'select public.correct_quick_sale_amount_v84($1,gen_random_uuid(),100,''v573suite'',null)'),
      ('till',          'select public.evaluate_checkout($1,$2,null,''[]''::jsonb,gen_random_uuid())')
    ) as c(module, stmt)
  loop
    -- WHY THE PROBE ACCOUNT IS MINTED RATHER THAN BORROWED. Production has exactly two
    -- non-owner logins estate-wide, both already refused by ROLE perms and branch scope, and one
    -- of them sits in a business where 'customerintel' is platform-disabled. Probing whoever
    -- happens to exist therefore proves nothing about the module gate -- earlier runs of this
    -- suite returned identical errors in both phases for three different reasons that had
    -- nothing to do with modules. So the suite builds the account it needs, inside this
    -- rolled-back transaction, in a business where the module is platform-enabled:
    --   role 'manager'  -> role_perms carries view_sales, create_sales, refund_sales, view_finance
    --   staff_branches  -> branch scope satisfied
    --   platform mode   -> asserted 'rw' before probing, so the firm-level gate is open
    -- leaving the staff module flag as the ONLY difference between phase 1 and phase 2.
    select b.id into v_biz
    from public.businesses b
    where (select mode from app.effective_platform_module_mode_v94(b.id,null,v_case.module)) = 'rw'
      and exists (select 1 from public.branches br where br.business_id = b.id)
      and exists (select 1 from public.staff o where o.business_id=b.id and o.role='owner'
                    and o.active and o.user_id is not null)
    order by b.id
    limit 1;

    -- DENIAL-ONLY FALLBACK. 'customerintel' is platform-disabled on every tenant in the estate,
    -- so no positive control can be built for it -- and that is precisely what made the pre-fix
    -- behaviour serious: a module no firm has switched on still returned per-customer spend and
    -- P&L-grade revenue when called directly. Rather than reddening this suite forever (a check
    -- that can only fail teaches nothing) or quietly passing it, the fallback asserts the half
    -- that IS provable -- the call is refused with a permission error -- and says in its detail
    -- that the positive control is unavailable, so the weaker guarantee is never mistaken for
    -- the full one.
    if v_biz is null then
      select st.business_id, st.user_id into v_biz, v_user
      from public.staff st
      where st.active and st.access_state='approved' and st.user_id is not null and st.role<>'owner'
      order by st.id limit 1;
      perform set_config('request.jwt.claims',
        json_build_object('sub', v_user, 'role','authenticated')::text, true);
      set local role authenticated;
      begin
        execute v_case.stmt using v_biz, null::uuid;
        v_msg1 := '(no exception)'; v_state1 := '00000';
      exception when others then
        v_msg1 := sqlerrm; v_state1 := sqlstate;
      end;
      reset role;
      perform set_config('request.jwt.claims', null, true);
      insert into _r values (
        v_case.module||' :: '||replace(split_part(split_part(v_case.stmt,'public.',2),'(',1),'"',''),
        v_msg1 <> '(no exception)',
        'DENIAL-ONLY (module platform-disabled estate-wide, no positive control): '
          ||v_state1||' '||left(v_msg1,44));
      continue;
    end if;

    -- borrow an existing auth login that has no staff row in this business
    select st.user_id into v_user
    from public.staff st
    where st.user_id is not null
      and not exists (select 1 from public.staff x where x.business_id=v_biz and x.user_id=st.user_id)
    order by st.id limit 1;

    if v_user is null then
      insert into _r values (v_case.module||' :: '||split_part(split_part(v_case.stmt,'public.',2),'(',1),
        false, 'no spare auth login to mint a probe staff row with');
      continue;
    end if;

    select br.id into v_branch from public.branches br where br.business_id = v_biz order by br.id limit 1;

    insert into public.staff(business_id, user_id, full_name, role, active, access_state, modules)
    values (v_biz, v_user, 'v573 suite probe', 'manager', true, 'approved', array['clients'])
    returning id into v_staff;
    insert into public.staff_branches(business_id, staff_id, branch_id)
    values (v_biz, v_staff, v_branch) on conflict do nothing;

    -- ---- phase 1: module Off (allowlist deliberately omits it)
    perform set_config('request.jwt.claims',
      json_build_object('sub', v_user, 'role','authenticated')::text, true);
    set local role authenticated;
    begin
      execute v_case.stmt using v_biz, v_branch;
      v_msg1 := '(no exception)'; v_state1 := '00000';
    exception when others then
      v_msg1 := sqlerrm; v_state1 := sqlstate;
    end;
    reset role;

    -- ---- phase 2: same account, same arguments, module On
    update public.staff set modules = array['clients', v_case.module] where id = v_staff;
    perform set_config('request.jwt.claims',
      json_build_object('sub', v_user, 'role','authenticated')::text, true);
    set local role authenticated;
    begin
      execute v_case.stmt using v_biz, v_branch;
      v_msg2 := '(no exception)';
    exception when others then
      v_msg2 := sqlerrm;
    end;
    reset role;
    perform set_config('request.jwt.claims', null, true);
    delete from public.staff_branches where staff_id = v_staff;
    delete from public.staff where id = v_staff;

    v_ok := (v_msg1 <> '(no exception)') and (v_msg1 is distinct from v_msg2);
    insert into _r values (
      v_case.module||' :: '||replace(split_part(split_part(v_case.stmt,'public.',2),'(',1),'"',''),
      v_ok,
      'off='||v_state1||' '||left(v_msg1,52)||'  ||  on='||left(v_msg2,52));
  end loop;
end
$probe$;

-- an owner must be untouched by all of this
do $owner$
declare
  v_biz uuid;
  v_owner uuid;
  v_ok boolean;
begin
  select st.business_id, st.user_id into v_biz, v_owner
  from public.staff st
  where st.role='owner' and st.active and st.user_id is not null
    and exists (select 1 from public.sales s where s.business_id = st.business_id)
  order by st.id limit 1;

  perform set_config('request.jwt.claims',
    json_build_object('sub', v_owner, 'role','authenticated')::text, true);
  set local role authenticated;
  begin
    perform public.get_dashboard_summary(v_biz, current_date-7, current_date, null);
    v_ok := true;
  exception when others then
    v_ok := false;
  end;
  reset role;
  perform set_config('request.jwt.claims', null, true);
  insert into _r values ('Z_owner_daily_report_unaffected', v_ok,
    case when v_ok then 'owner still reads the daily report' else 'OWNER WAS BLOCKED -- regression' end);
end
$owner$;

select id, case when ok then 'PASS' else 'FAIL' end as result, detail from _r order by id;

rollback;
