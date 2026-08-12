-- NESTLY v285: close the A4 audit gaps on Reports, Operations setup and Settings.
--
-- 1. STAFF <-> BRANCH ASSIGNMENT WAS WRITABLE BY ANY MEMBER (security).
--    v11a created ONE `FOR ALL` policy on public.staff_branches:
--        using (app.is_salon_member(business_id))
--        with check (app.is_salon_owner(business_id))
--    A WITH CHECK expression is only consulted for the rows a statement WRITES —
--    INSERT and UPDATE. DELETE has no WITH CHECK at all, so the owner-only half of
--    that policy never applied to it and the member-wide USING clause was the only
--    test a DELETE ever faced. Any staff member of the tenant could therefore
--    unassign any colleague from any branch, and because v17's app.can_see_branch()
--    reads exactly this table, that is a live privilege change: an employee could
--    remove a colleague's branch assignment and blank their reports, or (with an
--    INSERT they could not perform) at least deny access they were granted.
--    The fix is the shape every neighbouring config table already uses — read for
--    members, write for the owner — expressed as per-command policies so the
--    owner test is attached to the DELETE path explicitly rather than by way of a
--    clause DELETE does not evaluate. staff_services is deliberately NOT changed
--    here: it carries the same defect and belongs to a different audit's scope.
--
-- 2. BUNDLES HAD NO EDIT, NO ENABLE/DISABLE AND NO DELETE.
--    public.bundles / public.bundle_items carry READ-only RLS (v123), so the
--    catalogue could be created and then never corrected. Two SECURITY DEFINER
--    writers are added with the same authorization create_service_bundle_v123
--    uses (app.can_module_write(business,'services')) and the same validation
--    bounds, so a bundle can be renamed, repriced, re-membered, switched off and
--    removed without opening any table grant.
--
-- 3. EXPENSES COULD BE VOIDED BUT NOT CORRECTED. public.expenses is also
--    READ-only to the browser; a typo in an amount or a category could only be
--    voided and retyped, which leaves two rows where the business made one cost.
--    update_expense_v285 corrects an ACTIVE expense in place under the same
--    view_finance permission set_expense_void already requires, and refuses a
--    voided row (a voided expense is evidence, not a draft).
--
-- 4. THE BOTTLE CATALOGUE COULD NOT BE RENAMED OR REPRICED. The update branch of
--    bar_save_bottle_product_v278 ignored p_name and p_price_cents entirely, so
--    the two fields the owner types when ADDING a bottle became unreachable the
--    moment it existed. The function is replaced at the SAME signature (no new
--    overload — the PostgREST ambiguity lesson of V278/V279) so that a supplied
--    name or price is applied and a null still means "leave this alone", which
--    keeps every existing call site byte-compatible.
--
-- Not applied to production at authoring time. Verified rolled back in
-- db/tests/v285_a4_gap_closure.sql.

begin;

-- 1. staff_branches: read for members, write for the owner, per command.
drop policy if exists staff_branches_all on public.staff_branches;

create policy staff_branches_select on public.staff_branches
  for select to authenticated
  using (app.is_salon_member(business_id));

create policy staff_branches_insert on public.staff_branches
  for insert to authenticated
  with check (app.is_salon_owner(business_id));

create policy staff_branches_update on public.staff_branches
  for update to authenticated
  using (app.is_salon_owner(business_id))
  with check (app.is_salon_owner(business_id));

create policy staff_branches_delete on public.staff_branches
  for delete to authenticated
  using (app.is_salon_owner(business_id));

revoke all on public.staff_branches from anon;
grant select, insert, update, delete on public.staff_branches to authenticated;

-- 2a. Edit one bundle: name, price, membership and active state.
create or replace function public.update_service_bundle_v285(
  p_business uuid,
  p_bundle uuid,
  p_name text,
  p_price_cents integer,
  p_service_ids uuid[],
  p_active boolean
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_actor uuid := auth.uid();
  v_name text := nullif(btrim(coalesce(p_name, '')), '');
  v_service_ids uuid[];
  v_bundle public.bundles%rowtype;
begin
  if v_actor is null or p_business is null or p_bundle is null
     or not app.can_module_write(p_business, 'services') then
    raise exception 'permission denied' using errcode = '42501';
  end if;

  select * into v_bundle
    from public.bundles bundle
   where bundle.id = p_bundle and bundle.business_id = p_business
     for update;
  if not found then
    raise exception 'bundle not found' using errcode = '22023';
  end if;

  if v_name is not null and char_length(v_name) not between 2 and 120 then
    raise exception 'invalid service bundle' using errcode = '22023';
  end if;
  if p_price_cents is not null and p_price_cents not between 0 and 100000000 then
    raise exception 'invalid service bundle' using errcode = '22023';
  end if;

  if p_service_ids is not null then
    select array_agg(service_id order by service_id)
      into v_service_ids
      from (
        select distinct candidate as service_id
          from unnest(p_service_ids) candidate
         where candidate is not null
      ) normalized;
    if cardinality(coalesce(v_service_ids, array[]::uuid[])) not between 2 and 50 then
      raise exception 'a bundle holds between 2 and 50 services' using errcode = '22023';
    end if;
    if (
      select count(*)
        from public.services service
       where service.business_id = p_business
         and service.active
         and service.id = any(v_service_ids)
    ) <> cardinality(v_service_ids) then
      raise exception 'bundle services must be active in this business'
        using errcode = '22023';
    end if;
  end if;

  update public.bundles bundle
     set name = coalesce(v_name, bundle.name),
         price_cents = coalesce(p_price_cents, bundle.price_cents),
         active = coalesce(p_active, bundle.active)
   where bundle.id = p_bundle and bundle.business_id = p_business;

  if v_service_ids is not null then
    delete from public.bundle_items item where item.bundle_id = p_bundle;
    insert into public.bundle_items (bundle_id, service_id)
    select p_bundle, service_id from unnest(v_service_ids) service_id;
  end if;

  insert into public.audit_log (business_id, actor, action, entity, entity_id, detail)
  values (
    p_business, v_actor, 'SERVICE_BUNDLE_UPDATE', 'bundles', p_bundle,
    jsonb_build_object(
      'name', v_name,
      'price_cents', p_price_cents,
      'active', p_active,
      'service_count', cardinality(coalesce(v_service_ids, array[]::uuid[]))
    )
  );

  return jsonb_build_object('status', 'updated', 'bundle_id', p_bundle);
end;
$$;

-- 2b. Remove one bundle. bundle_items is deleted explicitly rather than relying on
-- a cascade so the audit row describes exactly what left the catalogue.
create or replace function public.delete_service_bundle_v285(
  p_business uuid,
  p_bundle uuid
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_actor uuid := auth.uid();
  v_bundle public.bundles%rowtype;
  v_items integer;
begin
  if v_actor is null or p_business is null or p_bundle is null
     or not app.can_module_write(p_business, 'services') then
    raise exception 'permission denied' using errcode = '42501';
  end if;

  select * into v_bundle
    from public.bundles bundle
   where bundle.id = p_bundle and bundle.business_id = p_business
     for update;
  if not found then
    raise exception 'bundle not found' using errcode = '22023';
  end if;

  delete from public.bundle_items item where item.bundle_id = p_bundle;
  get diagnostics v_items = row_count;
  delete from public.bundles bundle
   where bundle.id = p_bundle and bundle.business_id = p_business;

  insert into public.audit_log (business_id, actor, action, entity, entity_id, detail)
  values (
    p_business, v_actor, 'SERVICE_BUNDLE_DELETE', 'bundles', p_bundle,
    jsonb_build_object('name', v_bundle.name, 'price_cents', v_bundle.price_cents,
                       'service_count', v_items)
  );

  return jsonb_build_object('status', 'deleted', 'bundle_id', p_bundle);
end;
$$;

-- 3. Correct an active expense in place.
create or replace function public.update_expense_v285(
  p_business uuid,
  p_expense uuid,
  p_amount_cents integer,
  p_category text,
  p_note text
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_actor uuid := auth.uid();
  v_category text := nullif(btrim(coalesce(p_category, '')), '');
  v_row public.expenses%rowtype;
begin
  if v_actor is null or p_business is null or p_expense is null
     or not app.has_perm(p_business, 'view_finance') then
    raise exception 'permission denied' using errcode = '42501';
  end if;
  if p_amount_cents is not null and p_amount_cents not between 1 and 100000000 then
    raise exception 'the amount is not a valid cost' using errcode = '22023';
  end if;
  if v_category is not null and char_length(v_category) not between 2 and 120 then
    raise exception 'a category is between 2 and 120 characters' using errcode = '22023';
  end if;
  if p_note is not null and char_length(p_note) > 500 then
    raise exception 'a note is limited to 500 characters' using errcode = '22023';
  end if;

  select * into v_row
    from public.expenses expense
   where expense.id = p_expense and expense.business_id = p_business
     for update;
  if not found then
    raise exception 'expense not found' using errcode = '22023';
  end if;
  if v_row.voided_at is not null then
    raise exception 'a voided expense cannot be edited' using errcode = '22023';
  end if;

  update public.expenses expense
     set amount_cents = coalesce(p_amount_cents, expense.amount_cents),
         category = coalesce(v_category, expense.category),
         note = coalesce(nullif(btrim(coalesce(p_note, '')), ''), expense.note)
   where expense.id = p_expense and expense.business_id = p_business
  returning * into v_row;

  insert into public.audit_log (business_id, actor, action, entity, entity_id, detail)
  values (
    p_business, v_actor, 'EXPENSE_UPDATE', 'expenses', p_expense,
    jsonb_build_object('amount_cents', v_row.amount_cents, 'category', v_row.category)
  );

  return to_jsonb(v_row);
end;
$$;

-- 4. The bottle catalogue's name and price become editable. Same signature, same
-- null-means-unchanged contract for every existing caller.
create or replace function public.bar_save_bottle_product_v278(
  p_business uuid,
  p_product uuid,
  p_name text,
  p_size_ml integer,
  p_price_cents integer
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_actor uuid := auth.uid();
  v_name text := nullif(btrim(coalesce(p_name, '')), '');
  v_updated uuid;
begin
  perform app.require_bar_business_v275(p_business);
  if v_actor is null then
    raise exception 'authenticated staff required' using errcode = '28000';
  end if;
  if not app.is_salon_owner(p_business) then
    raise exception 'only the owner can change the bottle catalogue' using errcode = '42501';
  end if;
  if p_size_ml is not null and (p_size_ml < 100 or p_size_ml > 5000) then
    raise exception 'a bottle is between 100ml and 5000ml' using errcode = '22023';
  end if;
  if v_name is not null and length(v_name) > 120 then
    raise exception 'a bottle name is limited to 120 characters' using errcode = '22023';
  end if;
  if p_price_cents is not null and (p_price_cents < 0 or p_price_cents > 2147483647) then
    raise exception 'the price is not a valid amount' using errcode = '22023';
  end if;

  if p_product is null then
    if v_name is null then
      raise exception 'name the bottle' using errcode = '22023';
    end if;
    if p_size_ml is null then
      raise exception 'a new bottle needs its size in millilitres' using errcode = '22023';
    end if;
    insert into public.products (business_id, name, retail_price_cents, size_ml, active)
    values (p_business, v_name, coalesce(p_price_cents, 0), p_size_ml, true);
  else
    -- size_ml is still written unconditionally: clearing the box is how the owner
    -- says "this is no longer a bottle", so null there is a VALUE, not an omission.
    -- Name and price keep the opposite contract — null leaves them alone.
    update public.products product
       set size_ml = p_size_ml,
           name = coalesce(v_name, product.name),
           retail_price_cents = coalesce(p_price_cents, product.retail_price_cents)
     where product.id = p_product and product.business_id = p_business
    returning product.id into v_updated;
    if v_updated is null then
      raise exception 'product not found' using errcode = '22023';
    end if;
  end if;

  return public.bar_get_bottle_setup_v278(p_business);
end;
$$;

revoke all on function public.update_service_bundle_v285(uuid, uuid, text, integer, uuid[], boolean) from public, anon, authenticated;
revoke all on function public.delete_service_bundle_v285(uuid, uuid) from public, anon, authenticated;
revoke all on function public.update_expense_v285(uuid, uuid, integer, text, text) from public, anon, authenticated;
revoke all on function public.bar_save_bottle_product_v278(uuid, uuid, text, integer, integer) from public, anon, authenticated;

grant execute on function public.update_service_bundle_v285(uuid, uuid, text, integer, uuid[], boolean) to authenticated;
grant execute on function public.delete_service_bundle_v285(uuid, uuid) to authenticated;
grant execute on function public.update_expense_v285(uuid, uuid, integer, text, text) to authenticated;
grant execute on function public.bar_save_bottle_product_v278(uuid, uuid, text, integer, integer) to authenticated;

commit;
