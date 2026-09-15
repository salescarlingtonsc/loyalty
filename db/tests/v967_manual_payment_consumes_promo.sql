-- nestly_v967 rollback suite — verifying a manual payment spends the firm's voucher.
\set ON_ERROR_STOP on
begin;
do $suite$
declare
  sa1 uuid; sa2 uuid; owner_a uuid := gen_random_uuid();
  biz uuid := gen_random_uuid(); biz2 uuid := gen_random_uuid();
  got jsonb; red uuid; n integer := 0; seen text;
  inv uuid; pay uuid; inv2 uuid; pay2 uuid;
  row_r public.platform_promo_redemptions_v961%rowtype;
  today date := (now() at time zone 'Asia/Singapore')::date;
  ev_path text; ev_path2 text;
  claims_sa1 text; claims_sa2 text;
begin
  select user_id into sa1 from public.super_admins order by user_id limit 1;
  select user_id into sa2 from public.super_admins where user_id <> sa1 order by user_id limit 1;
  if sa1 is null or sa2 is null then
    raise exception 'A0 failed: v967 needs two super admins (dual control); found %', (select count(*) from public.super_admins);
  end if;
  claims_sa1 := jsonb_build_object('sub',sa1,'role','authenticated',
    'amr',jsonb_build_array(jsonb_build_object('method','oauth')),
    'app_metadata',jsonb_build_object('providers',jsonb_build_array('google')))::text;
  claims_sa2 := jsonb_build_object('sub',sa2,'role','authenticated',
    'amr',jsonb_build_array(jsonb_build_object('method','oauth')),
    'app_metadata',jsonb_build_object('providers',jsonb_build_array('google')))::text;

  insert into auth.users(id,email) values (owner_a,'zz-v967@example.test') on conflict (id) do nothing;
  insert into public.businesses(id,name,slug,industry,join_enabled,enabled_modules) values
    (biz ,'V967 firm','v967-a-'||substr(biz::text,1,8),'test',true,array['dashboard']),
    (biz2,'V967 reject','v967-r-'||substr(biz2::text,1,8),'test',true,array['dashboard']);
  insert into public.subscriptions(business_id,billing_provider,status,payment_status,currency) values
    (biz ,'manual','active','paid','SGD'),
    (biz2,'manual','active','paid','SGD');
  insert into public.staff(business_id,user_id,role,active,full_name) values (biz,owner_a,'owner',true,'V967 Owner');
  -- a manual invoice cannot be raised without a primary billing contact (v156)
  insert into public.platform_billing_contacts_v156(business_id,business_display_name,legal_entity_name,
    billing_address,contact_name,email,recipient_role,created_by,updated_by)
  values
    (biz ,'V967 firm','V967 FIRM PTE. LTD.', jsonb_build_object('line1','1 Test Road','postal','000001'),
     'V967 Billing','zz-v967-billing@example.test','primary',sa1,sa1),
    (biz2,'V967 reject','V967 REJECT PTE. LTD.', jsonb_build_object('line1','2 Test Road','postal','000002'),
     'V967 Billing','zz-v967-billing2@example.test','primary',sa1,sa1);

  perform set_config('request.jwt.claims', claims_sa1, true);
  perform set_config('request.jwt.claim.sub', sa1::text, true);

  got := public.platform_create_promo_code_v961('V967PCT','percent',2000,null,null,null,null,'suite');
  got := public.business_redeem_promo_code_v961(biz,'V967PCT');
  red := (got->>'redemption_id')::uuid;

  -- a $1,188.00 annual invoice with the 20% (=$237.60) the operator entered
  got := public.platform_create_manual_invoice_v156(biz, today, today, today, today + 365,
    jsonb_build_array(jsonb_build_object('description','Peekaa subscription','quantity',1,
      'unit_amount_cents',118800)), 23760, gen_random_uuid());
  inv := (got->'document'->>'id')::uuid;
  if inv is null then inv := (got->>'id')::uuid; end if;
  if inv is null then raise exception 'A0 failed: no invoice id in %', got; end if;

  -- the RPC insists the private evidence object really exists, so put one there
  ev_path := 'platform-subscriptions/manual-evidence/'||biz||'/'||inv||'/'||gen_random_uuid()||'.pdf';
  insert into storage.objects(bucket_id,name) values ('sme-private', ev_path);
  got := public.platform_record_manual_payment_v156(inv, 95040, 'PAY-V967-001', today, '6357',
    ev_path, gen_random_uuid());
  pay := (got->'payment'->>'id')::uuid;
  if pay is null then pay := (got->>'id')::uuid; end if;
  if pay is null then raise exception 'A0 failed: no payment id in %', got; end if;

  -- (1) recording alone must NOT spend the voucher — a second admin may still reject it
  n := n + 1;
  if (select consumed_at from public.platform_promo_redemptions_v961 where id=red) is not null then
    raise exception 'A% failed: recording a payment spent the voucher before it was verified', n; end if;

  -- (2) the recorder cannot verify their own payment (v156 dual control, untouched by v967)
  n := n + 1;
  begin
    perform public.platform_verify_manual_payment_v156(pay,'verified',null,gen_random_uuid());
    raise exception 'A% failed: the same admin verified their own recorded payment', n;
  exception when sqlstate '42501' then null; end;

  -- (3) the second admin verifies: receipt, period move, and now the voucher
  perform set_config('request.jwt.claims', claims_sa2, true);
  perform set_config('request.jwt.claim.sub', sa2::text, true);
  n := n + 1;
  got := public.platform_verify_manual_payment_v156(pay,'verified',null,gen_random_uuid());
  select * into row_r from public.platform_promo_redemptions_v961 where id=red;
  if row_r.consumed_at is null then
    raise exception 'A% failed: a verified manual payment did not spend the voucher', n; end if;
  n := n + 1;
  if row_r.consumed_payment_reference <> 'PAY-V967-001' then
    raise exception 'A% failed: consumed against reference %, expected PAY-V967-001', n,
      coalesce(row_r.consumed_payment_reference,'<null>'); end if;

  -- (4) the record describes the deal that was struck: list is the SUBTOTAL, not the cash received
  n := n + 1;
  if row_r.consumed_list_cents <> 118800 then
    raise exception 'A% failed: consumed_list_cents is % not the 118800 subtotal (the discounted cash would be 95040)',
      n, row_r.consumed_list_cents; end if;
  n := n + 1;
  if row_r.consumed_discount_cents <> 23760 then
    raise exception 'A% failed: consumed_discount_cents is % not 23760 (20%% of 118800)',
      n, row_r.consumed_discount_cents; end if;

  -- (5) and the firm is no longer holding an unspent code
  n := n + 1;
  got := public.business_get_promo_state_v961(biz);
  if (got->>'consumed_at') is null then
    raise exception 'A% failed: the promo card still shows an unspent code: %', n, got; end if;

  -- (6) a REJECTED payment leaves the voucher alone
  perform set_config('request.jwt.claims', claims_sa1, true);
  perform set_config('request.jwt.claim.sub', sa1::text, true);
  perform public.platform_create_promo_code_v961('V967REJ','percent',2000,null,null,null,null,'suite');
  got := public.business_redeem_promo_code_v961(biz2,'V967REJ');
  got := public.platform_create_manual_invoice_v156(biz2, today, today, today, today + 365,
    jsonb_build_array(jsonb_build_object('description','Peekaa subscription','quantity',1,
      'unit_amount_cents',118800)), 23760, gen_random_uuid());
  inv2 := coalesce((got->'document'->>'id')::uuid, (got->>'id')::uuid);
  ev_path2 := 'platform-subscriptions/manual-evidence/'||biz2||'/'||inv2||'/'||gen_random_uuid()||'.pdf';
  insert into storage.objects(bucket_id,name) values ('sme-private', ev_path2);
  got := public.platform_record_manual_payment_v156(inv2, 95040, 'PAY-V967-REJ', today, '6357',
    ev_path2, gen_random_uuid());
  pay2 := coalesce((got->'payment'->>'id')::uuid, (got->>'id')::uuid);
  perform set_config('request.jwt.claims', claims_sa2, true);
  perform set_config('request.jwt.claim.sub', sa2::text, true);
  perform public.platform_verify_manual_payment_v156(pay2,'rejected','suite: evidence refused',gen_random_uuid());
  n := n + 1;
  if (select consumed_at from public.platform_promo_redemptions_v961
       where business_id=biz2 and removed_at is null) is not null then
    raise exception 'A% failed: a REJECTED manual payment spent the voucher', n; end if;

  raise notice 'v967 suite: % assertions passed', n;
end
$suite$;
rollback;
