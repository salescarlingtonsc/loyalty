-- Rollback-only V257 acceptance suite: a cart containing a bundle must FINALISE.
-- Run after the canonical chain through v257 in a disposable database:
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f db/tests/v257_bundle_finalise_rehash.sql
-- Everything runs inside one transaction and is rolled back; nothing is left behind.
--
-- What it pins, in order:
--   1. evaluate_checkout expands a bundle and stamps each expanded line with its origin.
--   2. record_cart_sale finalises that token — the regression: before v257 the finaliser
--      re-priced the expanded lines at their services' LIST prices, the cart hash never
--      matched, and every attempt raised stale_evaluation, forever.
--   3. the recorded money is the BUNDLE's, not the sum of the parts.
--   4. genuine drift still fails stale: change the bundle's price after the evaluation and
--      the finalise must refuse. The guard is redirected, never removed.
begin;

create or replace function pg_temp.as_v257_user(
  p_uid uuid,p_role text default 'authenticated'
) returns void language plpgsql as $$
begin
  execute 'reset role';
  perform set_config('request.jwt.claim.sub','',true);
  perform set_config('request.jwt.claims','{}',true);
  execute format('set local role %I',p_role);
  perform set_config('request.jwt.claim.sub',coalesce(p_uid::text,''),true);
  perform set_config(
    'request.jwt.claims',
    json_build_object('sub',p_uid,'role',p_role)::text,
    true
  );
end
$$;
grant execute on function pg_temp.as_v257_user(uuid,text) to authenticated,anon;

do $v257$
declare
  v_owner uuid:=gen_random_uuid();
  v_business uuid:=gen_random_uuid();
  v_branch uuid:=gen_random_uuid();
  v_staff uuid:=gen_random_uuid();
  v_client uuid:=gen_random_uuid();
  v_svc_a uuid:=gen_random_uuid();
  v_svc_b uuid:=gen_random_uuid();
  v_bundle uuid:=gen_random_uuid();
  v_eval jsonb;
  v_sale json;
  v_sale_id uuid;
  v_lines jsonb;
  v_bundle_lines int;
  v_items_total bigint;
  v_failed boolean;
begin
  reset role;
  insert into auth.users(
    instance_id,id,aud,role,email,encrypted_password,
    email_confirmed_at,created_at,updated_at
  ) values(
    '00000000-0000-0000-0000-000000000000',v_owner,
    'authenticated','authenticated',
    'v257-owner-'||substr(v_owner::text,1,8)||'@example.test',
    '',now(),now(),now()
  );

  insert into public.businesses(id,name,slug,industry,join_enabled,enabled_modules)
  values(v_business,'V257 bundle finalise fixture',
    'v257-bundle-'||substr(v_business::text,1,8),'test',false,
    array['till','sales','services','packages']);

  -- app.has_perm gates every till RPC on app.business_workspace_open_v94, so the fixture
  -- business must be an approved, unpaused workspace or evaluate_checkout refuses with 42501
  -- before it ever prices a line. The control rows are created by a trigger on the business
  -- insert, so these are updates, and 'approved' requires a decided_by/decided_at pair.
  update public.business_workspace_controls_v94
     set approval_status='approved',decided_by=v_owner,decided_at=now(),
         decision_reason='v257 rollback-only fixture'
   where business_id=v_business;
  update public.business_subscription_lifecycle_v94
     set state='current',workspace_paused=false
   where business_id=v_business;
  if not app.business_workspace_open_v94(v_business) then
    raise exception 'v257: fixture workspace is not open - the suite would fail for the wrong reason';
  end if;

  insert into public.branches(id,business_id,name,active,is_default)
  values(v_branch,v_business,'Primary',true,true);

  insert into public.staff(id,business_id,user_id,role,full_name,active)
  values(v_staff,v_business,v_owner,'owner','V257 owner',true);

  insert into public.clients(id,business_id,full_name,phone)
  values(v_client,v_business,'V257 customer','81860257');

  -- Two 30.00 services inside an 80.00 bundle. The whole point of the bundle is that
  -- 80.00 <> 30.00 + 30.00, which is precisely the shape that could not be finalised.
  insert into public.services(id,business_id,name,price_cents,duration_min,active) values
    (v_svc_a,v_business,'V257 facial',3000,60,true),
    (v_svc_b,v_business,'V257 spa',3000,60,true);
  insert into public.bundles(id,business_id,name,price_cents,active)
  values(v_bundle,v_business,'V257 rainbow special',8000,true);
  insert into public.bundle_items(bundle_id,service_id) values
    (v_bundle,v_svc_a),(v_bundle,v_svc_b);

  perform pg_temp.as_v257_user(v_owner);

  -- 1. Evaluate a cart of one bundle at qty 2 plus one loose service: 160.00 + 30.00.
  v_eval := public.evaluate_checkout(
    v_business,v_branch,v_client,
    jsonb_build_array(
      jsonb_build_object('catalog_kind','bundle','catalog_id',v_bundle,'qty',2),
      jsonb_build_object('catalog_kind','service','catalog_id',v_svc_a,'qty',1)),
    gen_random_uuid());
  if v_eval->>'status' <> 'ok' then
    raise exception 'v257: the bundle cart could not be evaluated: %',v_eval;
  end if;
  if (v_eval->>'total_cents')::int <> 19000 then
    raise exception 'v257: bundle cart priced % cents, expected 19000',v_eval->>'total_cents';
  end if;

  select count(*) into v_bundle_lines
  from jsonb_array_elements(v_eval->'server_lines') l
  where nullif(l->>'bundle_id','')::uuid = v_bundle
    and (l->>'bundle_qty')::int = 2;
  if v_bundle_lines <> 2 then
    raise exception 'v257: expected 2 lines stamped with their bundle origin, found %',v_bundle_lines;
  end if;
  if exists(select 1 from jsonb_array_elements(v_eval->'server_lines') l
             where nullif(l->>'bundle_id','')::uuid = v_bundle
               and (l->>'unit_price_cents')::int <> 8000) then
    raise exception 'v257: bundle lines were not allocated from the bundle price';
  end if;

  -- 2. THE REGRESSION. Before v257 this raised
  --    'stale_evaluation: catalog prices changed since evaluation; re-evaluate'
  --    on every attempt, so the sale could never be recorded.
  v_sale := public.record_cart_sale(
    p_business=>v_business,p_client=>v_client,p_branch=>v_branch,p_staff=>v_staff,
    p_method=>'cash',p_idempotency_key=>'v257-finalise-'||substr(v_bundle::text,1,8),
    p_lines=>null,p_evaluation_id=>(v_eval->>'evaluation_id')::uuid,p_paid=>true);
  if (v_sale::jsonb->>'status') <> 'ok' then
    raise exception 'v257: the bundle cart did not finalise: %',v_sale;
  end if;
  v_sale_id := (v_sale::jsonb->>'sale_id')::uuid;

  -- 3. The money recorded is the bundle's, not the sum of the parts (which would be 90.00).
  reset role;
  if (select amount_cents from public.sales where id=v_sale_id) <> 19000 then
    raise exception 'v257: the parent sale did not record the bundle total';
  end if;
  select coalesce(sum(line_cents),0) into v_items_total
  from public.sale_items where sale_id=v_sale_id and item_type='service';
  if v_items_total <> 19000 then
    raise exception 'v257: sale_items summed % cents, expected 19000',v_items_total;
  end if;
  if not exists(select 1 from public.sale_items
                 where sale_id=v_sale_id and ref_id=v_svc_b and unit_cents=8000) then
    raise exception 'v257: the bundle member service was not recorded at its allocated share';
  end if;

  -- 4. Real drift must still fail stale. Re-evaluate, then move the bundle's price under it.
  perform pg_temp.as_v257_user(v_owner);
  v_eval := public.evaluate_checkout(
    v_business,v_branch,v_client,
    jsonb_build_array(jsonb_build_object('catalog_kind','bundle','catalog_id',v_bundle,'qty',1)),
    gen_random_uuid());
  reset role;
  update public.bundles set price_cents=9900 where id=v_bundle;
  perform pg_temp.as_v257_user(v_owner);
  v_failed := false;
  begin
    perform public.record_cart_sale(
      p_business=>v_business,p_client=>v_client,p_branch=>v_branch,p_staff=>v_staff,
      p_method=>'cash',p_idempotency_key=>'v257-drift-'||substr(v_bundle::text,1,8),
      p_lines=>null,p_evaluation_id=>(v_eval->>'evaluation_id')::uuid,p_paid=>true);
  exception when others then
    v_failed := true;
    if sqlerrm not like '%stale_evaluation%' then
      raise exception 'v257: a repriced bundle failed with the wrong error: %',sqlerrm;
    end if;
  end;
  if not v_failed then
    raise exception 'v257: a bundle repriced after evaluation was finalised at the old price';
  end if;

  reset role;
  raise notice 'v257 bundle finalise suite: ALL PASS';
end
$v257$;

reset role;
rollback;
