-- Rolled-back acceptance for v285 (audit A4 gap closure). Everything runs inside
-- ONE transaction that is rolled back: no fixture row and no catalogue edit
-- survives.
--
-- CORRECTION (applied to production 2026-08-12, migration `nestly_v285_a4_gap_closure`):
-- this suite previously REPLAYED the migration's whole DDL at the top, because at
-- authoring time the migration was unapplied. Replaying it now would prove nothing
-- about production - it would create the correct shape inside the very transaction
-- that then asserts the shape is correct, so a drifted or half-applied prod would
-- still run green. The splice is therefore REMOVED and every assertion below now
-- reads the DEPLOYED objects: section A interrogates pg_policy as it actually
-- stands, and sections D/E/F call the deployed functions rather than locally
-- redefined copies.
--
-- CORRECTION: the unused `v_denied` declaration is dropped, and each PASS line now
-- records the value it measured (row counts, names, prices) instead of the bare
-- word PASS - a log that only says PASS cannot distinguish a real assertion from
-- one that compared nothing.
--
-- No scaffolding hatch is needed for the bar section: app.require_bar_business_v275
-- reads public.businesses.industry directly (no GUC), and production carries a real
-- bar tenant, so section F exercises the genuine industry gate.
--
-- The block ENDS in `raise exception 'V285_RESULT ALL PASS -- %'`. A bare assert
-- prints nothing when it passes, so a green run would be indistinguishable from a
-- run that asserted nothing; raising prints every measured value AND aborts the
-- transaction, so the suite rolls itself back even when fed to a single-statement
-- executor that never sees the trailing `rollback;`.

begin;

do $v285$
declare
  v_biz uuid; v_owner uuid; v_member uuid; v_member_staff uuid; v_outsider uuid;
  v_branch uuid; v_owner_staff uuid;
  v_policies text; v_forall integer;
  v_deleted integer; v_survives integer; v_readable integer;
  v_bundle uuid; v_name text; v_price integer; v_active boolean; v_rows integer;
  v_expense_id uuid; v_amount integer; v_category text;
  v_bar_biz uuid; v_bar_owner uuid; v_product uuid; v_product_name text; v_product_price integer;
  v_setup jsonb;
  v_log text := '';
begin
  -- ------------------------------------------------------------------
  -- A. The policy shape itself. A single FOR ALL policy whose owner test
  --    lives only in WITH CHECK is exactly the defect being closed, so the
  --    absence of one is asserted, not merely the presence of four.
  -- ------------------------------------------------------------------
  select string_agg(polname, ',' order by polname),
         count(*) filter (where polcmd = '*' and polname <> 'staff_branches_sa_read')
    into v_policies, v_forall
    from pg_policy where polrelid = 'public.staff_branches'::regclass;
  if v_forall <> 0 then
    raise exception 'A: staff_branches still carries a FOR ALL tenant policy (%)', v_policies;
  end if;
  if not (v_policies like '%staff_branches_select%'
          and v_policies like '%staff_branches_insert%'
          and v_policies like '%staff_branches_update%'
          and v_policies like '%staff_branches_delete%') then
    raise exception 'A: staff_branches is missing a per-command policy (%)', v_policies;
  end if;
  v_log := v_log || format('A policy-split=PASS (%s); ', v_policies);

  -- ------------------------------------------------------------------
  -- Fixture. A real owner with a branch, plus a colleague login minted for
  -- this transaction only, plus an outsider who belongs to another tenant.
  -- Ordered so a synthetic 'ZZ%' tenant wins before a live one.
  -- ------------------------------------------------------------------
  select staff_row.business_id, staff_row.user_id, staff_row.id
    into v_biz, v_owner, v_owner_staff
    from public.staff staff_row
    join public.businesses business on business.id = staff_row.business_id
   where staff_row.role = 'owner' and staff_row.active
     and staff_row.access_state = 'approved' and staff_row.user_id is not null
     and exists (select 1 from public.branches branch where branch.business_id = staff_row.business_id)
     -- Both writers under test are module-gated (services / expenses), so the fixture tenant has
     -- to actually run those modules or the suite would report a permission refusal as a defect.
     and 'services' = any(coalesce(business.enabled_modules, '{}'::text[]))
     and 'expenses' = any(coalesce(business.enabled_modules, '{}'::text[]))
     and app.business_workspace_open_v94(staff_row.business_id)
   order by (business.name like 'ZZ%') desc, staff_row.business_id
   limit 1;
  if v_biz is null then
    raise exception 'V285_RESULT SKIPPED -- no approved owner fixture with a branch and both modules';
  end if;
  select id into v_branch from public.branches
   where business_id = v_biz order by is_default desc, id limit 1;

  select staff_row.user_id into v_member
    from public.staff staff_row
   where staff_row.user_id is not null and staff_row.business_id <> v_biz
   order by staff_row.user_id limit 1;
  if v_member is null then
    raise exception 'V285_RESULT SKIPPED -- no second authenticated identity to act as a colleague';
  end if;
  v_outsider := v_member;

  insert into public.staff (business_id, user_id, full_name, role, active, access_state)
  values (v_biz, v_member, 'ZZ V285 Rollback Colleague', 'staff', true, 'approved')
  returning id into v_member_staff;
  insert into public.staff_branches (business_id, staff_id, branch_id)
  values (v_biz, v_owner_staff, v_branch)
  on conflict do nothing;
  v_log := v_log || format('fixture business=%s branch=%s colleague=%s; ', v_biz, v_branch, v_member_staff);

  -- ------------------------------------------------------------------
  -- B. As the colleague: the assignment map is READABLE and NOT writable.
  --    A refused DELETE under RLS is silent - it removes zero rows rather
  --    than raising - so survival of the row is what is asserted.
  -- ------------------------------------------------------------------
  execute 'set local role authenticated';
  perform set_config('request.jwt.claim.sub', v_member::text, true);
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_member, 'role', 'authenticated')::text, true);

  select count(*) into v_readable from public.staff_branches where business_id = v_biz;
  if v_readable < 1 then
    raise exception 'B: a member must still be able to read the branch assignment map';
  end if;

  delete from public.staff_branches
   where business_id = v_biz and staff_id = v_owner_staff and branch_id = v_branch;
  get diagnostics v_deleted = row_count;
  execute 'reset role';
  select count(*) into v_survives from public.staff_branches
   where business_id = v_biz and staff_id = v_owner_staff and branch_id = v_branch;
  if v_deleted <> 0 or v_survives <> 1 then
    raise exception 'B: a member deleted a colleague''s branch assignment (deleted=% survives=%)',
      v_deleted, v_survives;
  end if;
  v_log := v_log || format('B member-delete-refused=PASS (readable=%s deleted=%s survives=%s); ', v_readable, v_deleted, v_survives);

  -- The INSERT half was already owner-only through WITH CHECK; it is pinned so
  -- the split cannot silently loosen it.
  execute 'set local role authenticated';
  begin
    insert into public.staff_branches (business_id, staff_id, branch_id)
    values (v_biz, v_member_staff, v_branch);
    execute 'reset role';
    raise exception 'B: a member inserted a branch assignment';
  exception
    when sqlstate '42501' then
      execute 'reset role';
      v_log := v_log || 'B member-insert-refused=PASS; ';
  end;

  -- ------------------------------------------------------------------
  -- C. As the owner: the same DELETE succeeds.
  -- ------------------------------------------------------------------
  execute 'set local role authenticated';
  perform set_config('request.jwt.claim.sub', v_owner::text, true);
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_owner, 'role', 'authenticated')::text, true);
  delete from public.staff_branches
   where business_id = v_biz and staff_id = v_owner_staff and branch_id = v_branch;
  get diagnostics v_deleted = row_count;
  execute 'reset role';
  if v_deleted <> 1 then
    raise exception 'C: the owner could not delete a branch assignment (deleted=%)', v_deleted;
  end if;
  v_log := v_log || format('C owner-delete=PASS (deleted=%s); ', v_deleted);

  -- The colleague login has now served its purpose. Removing it makes the SAME
  -- identity a genuine outsider for the catalogue denial below - the trap the
  -- v255 and v282 denial matrices both fell into was testing a refusal against
  -- somebody who quietly still had rights.
  delete from public.staff where id = v_member_staff;

  -- ------------------------------------------------------------------
  -- D. Bundles gain edit, enable/disable and delete.
  -- ------------------------------------------------------------------
  insert into public.bundles (business_id, name, price_cents, active)
  values (v_biz, 'ZZ V285 Rollback Bundle', 9900, true)
  returning id into v_bundle;

  perform set_config('request.jwt.claim.sub', v_owner::text, true);
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_owner, 'role', 'authenticated')::text, true);
  perform public.update_service_bundle_v285(
    v_biz, v_bundle, 'ZZ V285 Renamed Bundle', 12345, null, false);
  select name, price_cents, active into v_name, v_price, v_active
    from public.bundles where id = v_bundle;
  if v_name <> 'ZZ V285 Renamed Bundle' or v_price <> 12345 or v_active is not false then
    raise exception 'D: the bundle edit did not land (name=% price=% active=%)',
      v_name, v_price, v_active;
  end if;
  v_log := v_log || format('D bundle-edit=PASS (name=%s price=%s active=%s); ', v_name, v_price, v_active);

  -- An identity with no staff row in this tenant cannot touch the catalogue.
  perform set_config('request.jwt.claim.sub', v_outsider::text, true);
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_outsider, 'role', 'authenticated')::text, true);
  begin
    perform public.delete_service_bundle_v285(v_biz, v_bundle);
    raise exception 'D: an outsider deleted a bundle';
  exception
    when sqlstate '42501' then
      v_log := v_log || 'D bundle-delete-outsider-refused=PASS; ';
  end;

  perform set_config('request.jwt.claim.sub', v_owner::text, true);
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_owner, 'role', 'authenticated')::text, true);
  perform public.delete_service_bundle_v285(v_biz, v_bundle);
  select count(*) into v_rows from public.bundles where id = v_bundle;
  if v_rows <> 0 then
    raise exception 'D: the bundle survived its delete';
  end if;
  select count(*) into v_rows from public.bundle_items where bundle_id = v_bundle;
  if v_rows <> 0 then
    raise exception 'D: bundle membership survived the bundle';
  end if;
  v_log := v_log || 'D bundle-delete=PASS; ';

  -- ------------------------------------------------------------------
  -- E. An active expense can be corrected; a voided one cannot.
  -- ------------------------------------------------------------------
  perform public.create_expense(v_biz, null, 'ZZ V285 Rollback Category', 4200,
    current_date, null, 'V285 rolled-back expense', null, gen_random_uuid());
  select id into v_expense_id from public.expenses
   where business_id = v_biz and category = 'ZZ V285 Rollback Category'
   order by created_at desc limit 1;
  if v_expense_id is null then
    raise exception 'E: create_expense wrote no expense';
  end if;
  perform public.update_expense_v285(v_biz, v_expense_id, 5150, 'ZZ V285 Corrected Category', 'typo fixed');
  select amount_cents, category into v_amount, v_category
    from public.expenses where id = v_expense_id;
  if v_amount <> 5150 or v_category <> 'ZZ V285 Corrected Category' then
    raise exception 'E: the expense correction did not land (amount=% category=%)', v_amount, v_category;
  end if;
  v_log := v_log || format('E expense-edit=PASS (amount=%s category=%s); ', v_amount, v_category);

  perform public.set_expense_void(v_biz, v_expense_id, true);
  begin
    perform public.update_expense_v285(v_biz, v_expense_id, 100, null, null);
    raise exception 'E: a voided expense was edited';
  exception
    when sqlstate '22023' then
      v_log := v_log || 'E voided-expense-refused=PASS; ';
  end;

  -- ------------------------------------------------------------------
  -- F. The bottle catalogue's name and price become editable, while a null
  --    still means "leave this one alone" for every existing caller.
  -- ------------------------------------------------------------------
  select staff_row.business_id, staff_row.user_id into v_bar_biz, v_bar_owner
    from public.staff staff_row
    join public.businesses business on business.id = staff_row.business_id
   where staff_row.role = 'owner' and staff_row.active
     and staff_row.access_state = 'approved' and staff_row.user_id is not null
     and lower(coalesce(business.industry, '')) = 'bar'
   order by staff_row.business_id limit 1;
  if v_bar_biz is null then
    raise exception 'V285_RESULT SKIPPED -- no bar tenant to prove the catalogue edit against';
  end if;
  perform set_config('request.jwt.claim.sub', v_bar_owner::text, true);
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_bar_owner, 'role', 'authenticated')::text, true);
  perform public.bar_save_bottle_product_v278(v_bar_biz, null, 'ZZ V285 Rollback Bottle', 700, 8800);
  select id into v_product from public.products
   where business_id = v_bar_biz and name = 'ZZ V285 Rollback Bottle'
   order by id limit 1;
  if v_product is null then
    raise exception 'F: the bottle was not created';
  end if;
  v_setup := public.bar_save_bottle_product_v278(
    v_bar_biz, v_product, 'ZZ V285 Renamed Bottle', 700, 9900);
  select name, retail_price_cents into v_product_name, v_product_price
    from public.products where id = v_product;
  if v_product_name <> 'ZZ V285 Renamed Bottle' or v_product_price <> 9900 then
    raise exception 'F: the bottle rename/reprice did not land (name=% price=%)',
      v_product_name, v_product_price;
  end if;
  -- Null name and null price must still leave both alone, so the V278 call
  -- sites that only toggle size_ml keep behaving exactly as they did.
  perform public.bar_save_bottle_product_v278(v_bar_biz, v_product, null, 750, null);
  select name, retail_price_cents into v_product_name, v_product_price
    from public.products where id = v_product;
  if v_product_name <> 'ZZ V285 Renamed Bottle' or v_product_price <> 9900 then
    raise exception 'F: a null name or price overwrote the catalogue (name=% price=%)',
      v_product_name, v_product_price;
  end if;
  v_log := v_log || format('F bottle-name-price-edit=PASS (name=%s price=%s); ', v_product_name, v_product_price);

  raise exception 'V285_RESULT ALL PASS -- %', v_log;
end $v285$;

rollback;
