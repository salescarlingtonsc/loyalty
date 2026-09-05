-- EXECUTED acceptance fixture for nestly_v788
-- (db/migrations/20261006_nestly_v788_branch_receipt_identity_gst.sql).
--
-- Runs inside ONE transaction ending in ROLLBACK, so it is safe against production.
--
-- WHAT IT PROVES
--   01  the five branch columns and the two branch constraints exist; the evaluation totals
--       check now reads total = subtotal - discount + gst; ps1c_plan_checkout/7 is still
--       callable by nobody through the API.
--   02  the backfill copies a business's legal_name / UEN onto a branch that has none and leaves
--       a branch's own values alone (the migration's UPDATE, re-run on a fresh fixture).
--   03  the kernel, as the real owner principal: the SAME cart priced at a GST-registered
--       branch is subtotal + 9% ON TOP (10000 -> gst 900, total 10900); at a branch that is
--       not registered it is 10000 flat; and switching the SAME branch's flag off makes it
--       flat too. The rate is the branch's, not the business's: businesses.gst_registered stays
--       false throughout. (Two businesses with one default branch each, because a second
--       branch of one business is switched off by the v665 billing trigger until it is paid.)
--   04  rounding is half-up on the bill, once: 3 x 1234 = 3702 -> gst 333 (333.18), total 4035.
--   05  the evaluation row that was minted satisfies the restated constraint (it inserted), and
--       carries the branch's rate in gst_rate_bps.
--   06  a branch of ANOTHER business cannot lend its registration: pricing at business A with
--       business B's branch id is refused by evaluate_checkout before the kernel is reached.

begin;
select set_config('app.v79_system_transition', 'on', true);

create or replace function pg_temp.as_v788_user(
  p_uid uuid,
  p_role text default 'authenticated'
) returns void language plpgsql as $$
begin
  execute format('set local role %I', p_role);
  perform set_config('request.jwt.claim.sub', coalesce(p_uid::text, ''), true);
  perform set_config('request.jwt.claims', json_build_object(
    'sub', p_uid, 'role', p_role
  )::text, true);
end
$$;
grant execute on function pg_temp.as_v788_user(uuid,text) to public;

do $v788_test$
declare
  v_business   uuid;
  v_other_biz  uuid;
  v_slug       text;
  v_gst_branch uuid := gen_random_uuid();
  v_flat_branch uuid := gen_random_uuid();
  v_other_branch uuid := gen_random_uuid();
  v_owner_auth uuid := gen_random_uuid();
  v_staff      uuid;
  v_product    uuid;
  v_product2   uuid;
  v_product_flat uuid;
  v_out        jsonb;
  v_eval       public.checkout_evaluations%rowtype;
  v_cols       int;
  v_def        text;
  v_ok         boolean;
begin
  reset role;

  -- 01 shape ------------------------------------------------------------------------------
  select count(*) into v_cols from information_schema.columns
   where table_schema='public' and table_name='branches'
     and column_name in ('legal_name','registration_number','gst_registered','gst_registration_number','gst_rate_bps');
  if v_cols <> 5 then raise exception '01 FAILED: expected 5 branch identity columns, found %', v_cols; end if;

  select pg_get_constraintdef(oid) into v_def from pg_constraint
   where conrelid='public.checkout_evaluations'::regclass and conname='checkout_evaluations_totals_check';
  if v_def is null or v_def not like '%gst_cents%' then
    raise exception '01 FAILED: totals check does not include gst: %', v_def;
  end if;
  if not exists (select 1 from pg_constraint where conrelid='public.branches'::regclass and conname='branches_gst_rate_bps_v788')
     or not exists (select 1 from pg_constraint where conrelid='public.branches'::regclass and conname='branches_identity_lengths_v788') then
    raise exception '01 FAILED: branch constraints missing';
  end if;
  if has_function_privilege('authenticated','app.ps1c_plan_checkout(uuid,uuid,uuid,jsonb,uuid,uuid,boolean)','execute')
     or has_function_privilege('anon','app.ps1c_plan_checkout(uuid,uuid,uuid,jsonb,uuid,uuid,boolean)','execute') then
    raise exception '01 FAILED: ps1c_plan_checkout is API-callable';
  end if;
  raise notice '01 PASSED: shape';

  -- fixture --------------------------------------------------------------------------------
  insert into public.businesses(name,slug,industry,enabled_modules,legal_name,registration_number)
  values(
    'V788 GST fixture',
    'v788-gst-' || substr(gen_random_uuid()::text,1,8),
    'test',
    array['dashboard','clients','sales','loyalty','till'],
    'V788 FIXTURE PTE. LTD.', 'V788' || substr(replace(gen_random_uuid()::text,'-',''),1,6) || 'A'
  ) returning id,slug into v_business,v_slug;
  insert into public.businesses(name,slug,industry,enabled_modules,legal_name,registration_number)
  values('V788 other firm','v788-other-' || substr(gen_random_uuid()::text,1,8),'test',
         array['dashboard','clients','sales','loyalty','till'],'V788 FIXTURE PTE. LTD.',
         'V788' || substr(replace(gen_random_uuid()::text,'-',''),1,6) || 'B')
  returning id into v_other_biz;
  perform set_config('app.v79_system_transition', '', true);

  -- the flat branch has NO identity of its own; the gst branch has its own name and UEN
  insert into public.branches(id,business_id,name,is_default,active)
  values(v_flat_branch,v_other_biz,'V788 flat branch',true,true);
  insert into public.branches(id,business_id,name,is_default,active,legal_name,registration_number,
                              gst_registered,gst_registration_number,gst_rate_bps)
  values(v_gst_branch,v_business,'V788 GST branch',true,true,'V788 BRANCH TWO PTE. LTD.','V788B0002B',
         true,'M9-0000002-1',900);
  v_other_branch := v_flat_branch;

  -- 02 backfill (the migration's UPDATE, re-run verbatim on this fixture) --------------------
  update public.branches br
     set legal_name = coalesce(br.legal_name, bz.legal_name),
         registration_number = coalesce(br.registration_number, bz.registration_number)
    from public.businesses bz
   where bz.id = br.business_id
     and (bz.legal_name is not null or bz.registration_number is not null)
     and (br.legal_name is null or br.registration_number is null);
  if (select legal_name from public.branches where id=v_flat_branch) <> 'V788 FIXTURE PTE. LTD.'
     or (select registration_number from public.branches where id=v_flat_branch) is null then
    raise exception '02 FAILED: the empty branch did not inherit the business identity';
  end if;
  if (select legal_name from public.branches where id=v_gst_branch) <> 'V788 BRANCH TWO PTE. LTD.'
     or (select registration_number from public.branches where id=v_gst_branch) <> 'V788B0002B' then
    raise exception '02 FAILED: a branch with its own identity was overwritten';
  end if;
  raise notice '02 PASSED: backfill';

  insert into public.business_workspace_controls_v94
    (business_id,approval_status,decided_at,decision_reason)
  values(v_business,'approved',now(),'v788 fixture'),(v_other_biz,'approved',now(),'v788 fixture')
  on conflict (business_id) do update
    set approval_status='approved',decided_at=now(),decision_reason='v788 fixture';
  insert into public.business_subscription_lifecycle_v94(business_id,state,workspace_paused)
  values(v_business,'current',false),(v_other_biz,'current',false)
  on conflict (business_id) do update set state='current',workspace_paused=false;
  insert into public.subscriptions(business_id,status,payment_status,current_period_end)
  values(v_business,'active','paid',now()+interval '30 days'),(v_other_biz,'active','paid',now()+interval '30 days')
  on conflict (business_id) do update
    set status='active',payment_status='paid',current_period_end=now()+interval '30 days';

  insert into auth.users(
    instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at
  ) values(
    '00000000-0000-0000-0000-000000000000',v_owner_auth,'authenticated','authenticated',
    'v788-owner-' || substr(v_owner_auth::text,1,8) || '@example.test','',now(),now(),now()
  );
  insert into public.staff(business_id,user_id,role,active)
  values(v_business,v_owner_auth,'owner',true)
  returning id into v_staff;
  insert into public.staff_branches(business_id,staff_id,branch_id) values (v_business,v_staff,v_gst_branch);
  insert into public.staff(business_id,user_id,role,active)
  values(v_other_biz,v_owner_auth,'owner',true)
  returning id into v_staff;
  insert into public.staff_branches(business_id,staff_id,branch_id) values (v_other_biz,v_staff,v_flat_branch);

  insert into public.products(business_id,name,retail_price_cents,active)
  values(v_business,'V788 ten dollar item',10000,true) returning id into v_product;
  insert into public.products(business_id,name,retail_price_cents,active)
  values(v_other_biz,'V788 ten dollar item',10000,true) returning id into v_product_flat;
  insert into public.products(business_id,name,retail_price_cents,active)
  values(v_business,'V788 odd item',1234,true) returning id into v_product2;

  -- 03 the same cart, two branches -----------------------------------------------------------
  perform pg_temp.as_v788_user(v_owner_auth);
  v_out := public.evaluate_checkout(v_business, v_gst_branch, null::uuid,
    jsonb_build_array(jsonb_build_object('catalog_kind','product','catalog_id',v_product,'qty',1)),
    gen_random_uuid(), null::uuid, false);
  if (v_out->>'subtotal_cents')::int <> 10000 or (v_out->>'gst_cents')::int <> 900
     or (v_out->>'total_cents')::int <> 10900 then
    raise exception '03 FAILED: GST branch priced % (expected subtotal 10000, gst 900, total 10900)', v_out;
  end if;
  v_out := public.evaluate_checkout(v_other_biz, v_flat_branch, null::uuid,
    jsonb_build_array(jsonb_build_object('catalog_kind','product','catalog_id',v_product_flat,'qty',1)),
    gen_random_uuid(), null::uuid, false);
  if (v_out->>'gst_cents')::int <> 0 or (v_out->>'total_cents')::int <> 10000 then
    raise exception '03 FAILED: flat branch priced % (expected gst 0, total 10000)', v_out;
  end if;
  reset role;
  -- the switch is the branch's own: off, and the same cart at the same branch is flat
  update public.branches set gst_registered=false where id=v_gst_branch;
  perform pg_temp.as_v788_user(v_owner_auth);
  v_out := public.evaluate_checkout(v_business, v_gst_branch, null::uuid,
    jsonb_build_array(jsonb_build_object('catalog_kind','product','catalog_id',v_product,'qty',1)),
    gen_random_uuid(), null::uuid, false);
  if (v_out->>'gst_cents')::int <> 0 or (v_out->>'total_cents')::int <> 10000 then
    raise exception '03 FAILED: switched-off branch still priced % (expected gst 0, total 10000)', v_out;
  end if;
  reset role;
  update public.branches set gst_registered=true where id=v_gst_branch;
  if (select gst_registered from public.businesses where id=v_business) then
    raise exception '03 FAILED: the business flag was flipped; the rate must come from the branch';
  end if;
  raise notice '03 PASSED: 9%% on top at the registered branch, nothing at its sibling';

  -- 04 rounding ------------------------------------------------------------------------------
  perform pg_temp.as_v788_user(v_owner_auth);
  v_out := public.evaluate_checkout(v_business, v_gst_branch, null::uuid,
    jsonb_build_array(jsonb_build_object('catalog_kind','product','catalog_id',v_product2,'qty',3)),
    gen_random_uuid(), null::uuid, false);
  if (v_out->>'subtotal_cents')::int <> 3702 or (v_out->>'gst_cents')::int <> 333
     or (v_out->>'total_cents')::int <> 4035 then
    raise exception '04 FAILED: rounding priced % (expected 3702 / 333 / 4035)', v_out;
  end if;
  raise notice '04 PASSED: rounding once on the bill';

  -- 05 the minted row ------------------------------------------------------------------------
  reset role;
  select * into v_eval from public.checkout_evaluations where id=(v_out->>'evaluation_id')::uuid;
  if v_eval.id is null then raise exception '05 FAILED: no evaluation row'; end if;
  if v_eval.total_cents <> v_eval.subtotal_cents - v_eval.discount_total_cents + v_eval.gst_cents
     or v_eval.gst_rate_bps <> 900 or v_eval.branch_id <> v_gst_branch then
    raise exception '05 FAILED: evaluation row shape total=% sub=% disc=% gst=% rate=%',
      v_eval.total_cents, v_eval.subtotal_cents, v_eval.discount_total_cents, v_eval.gst_cents, v_eval.gst_rate_bps;
  end if;
  raise notice '05 PASSED: evaluation row';

  -- 06 another business's branch lends nothing ----------------------------------------------
  perform pg_temp.as_v788_user(v_owner_auth);
  v_ok := false;
  begin
    v_out := public.evaluate_checkout(v_business, v_other_branch, null::uuid,
      jsonb_build_array(jsonb_build_object('catalog_kind','product','catalog_id',v_product,'qty',1)),
      gen_random_uuid(), null::uuid, false);
  exception when others then
    v_ok := sqlerrm like '%belongs to another business%';
    if not v_ok then raise exception '06 FAILED: wrong refusal: %', sqlerrm; end if;
  end;
  if not v_ok then raise exception '06 FAILED: a foreign branch id was accepted'; end if;
  reset role;
  raise notice '06 PASSED: foreign branch refused';

  raise notice 'V788 SUITE: ALL ASSERTIONS PASSED';
end
$v788_test$;

rollback;
