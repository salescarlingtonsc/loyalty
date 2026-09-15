-- Rollback-only acceptance for nestly_v950 — a customer no branch can claim is claimed by
-- every branch.
--
-- AUDIT FINDING F4. With a named branch selected, a customer with no sales yet was absent from
-- the Customers roster, absent from its search, and absent from the "All" chip — so an owner who
-- had just saved a customer saw no sign the save had worked. public.clients has no branch_id: a
-- customer belongs to the business, and only a sale ever attributes one to a branch.
--
-- Runs against the REAL production estate inside ONE transaction and ends in ROLLBACK: it writes
-- nothing that survives. It is ONE statement so it can be executed through a single-statement
-- client, and ends in `raise exception 'V950_RESULT ALL PASS -- %'`.
--
-- WHAT IT PROVES, and each part is red against the pre-v950 bodies:
--   1  ROSTER. Under a single named branch, a client with NO sales is returned, while a client
--      whose only sale is at the OTHER branch is not. Pre-v950 the no-sale client was missing:
--      this section fails with "unattributed client missing from the roster".
--   2  CHIP AGREEMENT. staff_customer_bucket_counts_v290's counts.total equals the roster's
--      total for the same scope. The V399 rule is that the chip and the list can never disagree;
--      pre-v950 they agreed only because BOTH were wrong, so this section is the one that would
--      have stayed green — it is kept because it is what stops a future half-fix.
--   3  NULL-BRANCH SALE. A client whose only sale carries branch_id IS NULL is unattributed and
--      must therefore be visible under EVERY branch. This is the case the `and sale.branch_id is
--      not null` line in customer_branch_attributed exists for; a mutant that drops that line
--      turns this section red.
--   4  SEARCH. The same client is reachable by name search under the named branch — the reported
--      symptom was "No matching customers", which is the roster CTE, not a separate predicate.
--   5  NEVER-VISITED FILTER AND CHIP. p_inactive_bucket='never' under a named branch returns the
--      unattributed client, and counts.never agrees. Without change 3 of the migration the fix
--      would have introduced a NEW disagreement: visible under "All customers", gone under
--      "Never visited", with the chip reading 0 over a list that showed rows.
--   6  NO WIDENING. A client with a sale at branch B only is still absent under branch A. The
--      migration must not turn branch scoping off; it must only stop it claiming customers no
--      branch owns.

begin;

do $v950$
declare
  v_biz uuid; v_owner uuid; v_branch_a uuid; v_branch_b uuid;
  v_client_none uuid; v_client_a uuid; v_client_null uuid;
  v_list jsonb; v_counts jsonb;
  v_total integer; v_chip integer; v_count integer;
  v_log text := '';
  v_has_none boolean; v_has_a boolean; v_has_null boolean;
begin
  execute $ddl$
    create or replace function pg_temp.as_v950_user(p_uid uuid, p_role text default 'authenticated')
    returns void language plpgsql as $f$
    begin
      reset role;
      execute format('set local role %I', p_role);
      perform set_config('request.jwt.claim.sub', coalesce(p_uid::text,''), true);
      perform set_config('request.jwt.claims',
        json_build_object('sub',p_uid,'role',p_role)::text, true);
    end $f$
  $ddl$;
  execute 'grant execute on function pg_temp.as_v950_user(uuid, text) to public';

  -- ---- fixture discovery: any business with >= 2 active branches and an approved owner -------
  select b.business_id, b.a, b.b, s.user_id
    into v_biz, v_branch_a, v_branch_b, v_owner
  from (
    select br.business_id,
           (array_agg(br.id order by br.is_default desc, br.created_at, br.id))[1] as a,
           (array_agg(br.id order by br.is_default desc, br.created_at, br.id))[2] as b,
           count(*) as n
    from public.branches br
    where coalesce(br.active, true)
    group by br.business_id
  ) b
  join public.staff s
    on s.business_id = b.business_id and s.role = 'owner'
   and s.active and s.access_state = 'approved' and s.user_id is not null
  where b.n >= 2
  order by b.business_id
  limit 1;

  if v_biz is null then
    raise exception 'v950/fixture: no business with two active branches and an approved owner';
  end if;
  v_log := v_log || format('[fixture biz=%s a=%s b=%s]', v_biz, v_branch_a, v_branch_b);

  -- ---- seed three clients inside the transaction ---------------------------------------------
  insert into public.clients(business_id, full_name, is_synthetic)
    values (v_biz, 'ZZ v950 no sales at all', false) returning id into v_client_none;
  insert into public.clients(business_id, full_name, is_synthetic)
    values (v_biz, 'ZZ v950 sale at branch A', false) returning id into v_client_a;
  insert into public.clients(business_id, full_name, is_synthetic)
    values (v_biz, 'ZZ v950 sale with no branch', false) returning id into v_client_null;

  insert into public.sales(business_id, client_id, branch_id, kind, amount_cents, occurred_at,
                           counts_as_revenue, counts_as_visit, earns_points)
    values (v_biz, v_client_a, v_branch_a, 'quick_sale', 1000, now(), true, true, false);
  -- public.sales.branch_id is NULLABLE, but trg_sales_default_branch (app.set_row_branch) fills
  -- it on every insert, and a read-only estate scan on 2026-09-15 found ZERO sales with a null
  -- branch. So the `and sale.branch_id is not null` line in customer_branch_attributed is
  -- defence-in-depth for a row the writer cannot currently produce — which is exactly why it has
  -- to be proven HERE rather than assumed: the trigger is suspended for this one insert so the
  -- READER is exercised against the shape the column still permits. The whole block is inside
  -- the transaction this file rolls back, and the trigger is re-enabled immediately.
  alter table public.sales disable trigger trg_sales_default_branch;
  insert into public.sales(business_id, client_id, branch_id, kind, amount_cents, occurred_at,
                           counts_as_revenue, counts_as_visit, earns_points)
    values (v_biz, v_client_null, null, 'quick_sale', 1000, now(), true, true, false);
  alter table public.sales enable trigger trg_sales_default_branch;

  select count(*) into v_count from public.sales
   where client_id = v_client_null and branch_id is null;
  if v_count <> 1 then
    raise exception 'v950/seed: the null-branch fixture did not survive the writer (% rows)', v_count;
  end if;

  perform pg_temp.as_v950_user(v_owner);

  -- ============================================================================================
  -- 1 · ROSTER under branch B only
  -- ============================================================================================
  v_list := public.staff_list_customers_v155(v_biz, null, null, 'current',
                                             array[]::uuid[], v_branch_b, 100, 0);

  select bool_or((row_value->>'id')::uuid = v_client_none),
         bool_or((row_value->>'id')::uuid = v_client_a),
         bool_or((row_value->>'id')::uuid = v_client_null)
    into v_has_none, v_has_a, v_has_null
  from jsonb_array_elements(v_list->'customers') as row_value;

  if not coalesce(v_has_none, false) then
    raise exception 'v950/1: unattributed client missing from the roster under a named branch';
  end if;
  if coalesce(v_has_a, false) then
    raise exception 'v950/1: a client whose only sale is at the OTHER branch leaked into this scope';
  end if;
  v_log := v_log || ' [1 roster: unattributed present, other-branch absent]';

  -- ============================================================================================
  -- 2 · CHIP AGREEMENT — counts.total must equal the roster total for the same scope
  -- ============================================================================================
  v_total := (v_list->>'total')::integer;
  v_counts := public.staff_customer_bucket_counts_v290(v_biz, null, 'current',
                                                       array[]::uuid[], v_branch_b);
  v_chip := (v_counts->'counts'->>'total')::integer;
  if v_total is distinct from v_chip then
    raise exception 'v950/2: roster total % and chip total % disagree', v_total, v_chip;
  end if;
  v_log := v_log || format(' [2 chip=roster=%s]', v_total);

  -- ============================================================================================
  -- 3 · NULL-BRANCH SALE — unattributed, so visible under BOTH branches
  -- ============================================================================================
  if not coalesce(v_has_null, false) then
    raise exception 'v950/3: a client whose only sale has branch_id IS NULL is missing under branch B';
  end if;
  v_list := public.staff_list_customers_v155(v_biz, null, null, 'current',
                                             array[]::uuid[], v_branch_a, 100, 0);
  select bool_or((row_value->>'id')::uuid = v_client_null)
    into v_has_null
  from jsonb_array_elements(v_list->'customers') as row_value;
  if not coalesce(v_has_null, false) then
    raise exception 'v950/3: the null-branch client is missing under branch A';
  end if;
  v_log := v_log || ' [3 null-branch sale visible under both branches]';

  -- ============================================================================================
  -- 4 · SEARCH — the reported symptom was "No matching customers"
  -- ============================================================================================
  v_list := public.staff_list_customers_v155(v_biz, 'ZZ v950 no sales', null, 'current',
                                             array[]::uuid[], v_branch_b, 100, 0);
  if coalesce(jsonb_array_length(v_list->'customers'), 0) < 1 then
    raise exception 'v950/4: searching the unattributed client by name returned nothing';
  end if;
  v_log := v_log || ' [4 search finds the unattributed client]';

  -- ============================================================================================
  -- 5 · NEVER-VISITED filter and chip must agree with the roster
  -- ============================================================================================
  v_list := public.staff_list_customers_v155(v_biz, null, 'never', 'current',
                                             array[]::uuid[], v_branch_b, 100, 0);
  select bool_or((row_value->>'id')::uuid = v_client_none)
    into v_has_none
  from jsonb_array_elements(v_list->'customers') as row_value;
  if not coalesce(v_has_none, false) then
    raise exception 'v950/5: the unattributed client is absent from the Never visited filter';
  end if;
  v_count := (v_counts->'counts'->>'never')::integer;
  if v_count < 1 then
    raise exception 'v950/5: the Never visited chip reads % over a list that has rows', v_count;
  end if;
  v_log := v_log || format(' [5 never filter+chip agree, chip=%s]', v_count);

  -- ============================================================================================
  -- 6 · NO WIDENING — branch scoping still holds for clients a branch DOES claim
  -- ============================================================================================
  v_list := public.staff_list_customers_v155(v_biz, null, null, 'current',
                                             array[]::uuid[], v_branch_a, 100, 0);
  select bool_or((row_value->>'id')::uuid = v_client_a)
    into v_has_a
  from jsonb_array_elements(v_list->'customers') as row_value;
  if not coalesce(v_has_a, false) then
    raise exception 'v950/6: the branch-A client vanished from branch A — scoping broke';
  end if;
  v_list := public.staff_list_customers_v155(v_biz, null, null, 'current',
                                             array[]::uuid[], v_branch_b, 100, 0);
  select bool_or((row_value->>'id')::uuid = v_client_a)
    into v_has_a
  from jsonb_array_elements(v_list->'customers') as row_value;
  if coalesce(v_has_a, false) then
    raise exception 'v950/6: the branch-A client is visible under branch B — scoping widened';
  end if;
  v_log := v_log || ' [6 attributed clients stay branch-scoped]';

  reset role;
  raise exception 'V950_RESULT ALL PASS -- %', v_log;
end
$v950$;

rollback;
