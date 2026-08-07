-- Rolled-back acceptance for v213 — the sales-mix toggle commits and is audited.
begin;
do $$
declare v_biz uuid; v_owner uuid; v_res json; v_audit int;
begin
  select s.business_id, s.user_id into v_biz, v_owner from public.staff s
   where s.role='owner' and s.user_id is not null and s.access_state='approved' limit 1;
  if v_biz is null then raise notice 'no fixture; skipping'; return; end if;
  perform set_config('request.jwt.claims', json_build_object('sub',v_owner,'role','authenticated')::text, true);

  -- the toggle must COMMIT, which it could not while it wrote to a column that does not exist
  v_res := public.business_set_sales_mix_v184(v_biz, true, true);
  assert (v_res->>'status')='ok', 'the toggle must succeed';
  assert (v_res->>'sells_products')::boolean, 'asking for products must enable them';
  assert (v_res->>'sells_services')::boolean, 'asking for services must keep them';
  assert (select 'inventory' = any(enabled_modules) from public.businesses where id=v_biz),
    'the change must actually land on the business row';

  -- and the audit row is the point of the function, not decoration
  select count(*) into v_audit from public.audit_log
   where business_id=v_biz and action='business.sales_mix_changed';
  assert v_audit >= 1, 'the change must be audited';

  -- a business must sell something
  begin
    perform public.business_set_sales_mix_v184(v_biz, false, false);
    raise exception 'a business was allowed to sell nothing';
  exception when sqlstate '22023' then null;
  end;
  raise notice 'v213 acceptance passed';
end$$;
rollback;
