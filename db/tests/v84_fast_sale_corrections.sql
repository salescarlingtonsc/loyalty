-- Rollback-only v84 fast sale-correction acceptance suite.
-- Run after the complete canonical chain through v84 in a disposable database.
begin;
-- v79's dual-table activation guard dereferences branches.active while the shared
-- fixture normalizes an existing businesses timestamp. Use the documented seeding
-- seam only around fixture creation; v84 never relies on this setting.
select set_config('app.v79_system_transition','on',true);
\ir fixtures/pristine_chain_fixture.psql
select set_config('app.v79_system_transition','',true);

create or replace function pg_temp.as_v84_user(
  p_uid uuid,
  p_role text default 'authenticated'
) returns void language plpgsql as $$
begin
  execute format('set local role %I',p_role);
  perform set_config('request.jwt.claim.sub',coalesce(p_uid::text,''),true);
  perform set_config('request.jwt.claims',json_build_object(
    'sub',p_uid,'role',p_role
  )::text,true);
end
$$;
grant execute on function pg_temp.as_v84_user(uuid,text) to public;

do $v84$
declare
  v_business uuid;
  v_business_slug text;
  v_owner uuid;
  v_owner_staff uuid;
  v_branch uuid;
  v_client uuid;
  v_spent_client uuid;
  v_customer_user uuid := gen_random_uuid();
  v_customer_identity uuid;
  v_customer_link uuid := gen_random_uuid();
  v_outsider uuid := gen_random_uuid();
  v_original uuid;
  v_second uuid;
  v_unpaid uuid;
  v_unpaid_replacement uuid;
  v_later_paid uuid;
  v_later_paid_replacement uuid;
  v_partial uuid;
  v_mixed uuid;
  v_card_paid uuid;
  v_spent_original uuid;
  v_spent_points integer;
  v_result jsonb;
  v_replay jsonb;
  v_history jsonb;
  v_reversal uuid;
  v_replacement uuid;
  v_second_reversal uuid;
  v_blocked boolean;
  v_definition text;
  v_original_points integer;
  v_reversal_points integer;
begin
  if to_regprocedure(
       'public.correct_quick_sale_amount_v84(uuid,uuid,integer,text,text)'
     ) is null
     or to_regprocedure(
       'public.reverse_sale_fast_v84(uuid,uuid,text,text)'
     ) is null then
    raise exception 'v84 correction RPCs are missing';
  end if;
  if has_function_privilege(
       'anon',
       'public.correct_quick_sale_amount_v84(uuid,uuid,integer,text,text)'::regprocedure,
       'EXECUTE'
     )
     or has_function_privilege(
       'anon',
       'public.reverse_sale_fast_v84(uuid,uuid,text,text)'::regprocedure,
       'EXECUTE'
     )
     or not has_function_privilege(
       'authenticated',
       'public.correct_quick_sale_amount_v84(uuid,uuid,integer,text,text)'::regprocedure,
       'EXECUTE'
     ) then
    raise exception 'v84 correction RPC ACL is not authenticated-only';
  end if;
  select pg_get_functiondef(
    'public.correct_quick_sale_amount_v84(uuid,uuid,integer,text,text)'::regprocedure
  ) into v_definition;
  if v_definition not ilike '%SECURITY DEFINER%'
     or v_definition not ilike '%pg_catalog%public%app%pg_temp%'
     or v_definition not ilike '%public.reverse_sale_v480_base(%'
     or v_definition ilike '%public.reverse_sale(%'
     or v_definition not ilike '%public.record_quick_sale(%' then
    raise exception 'v84 correction boundary does not compose the proven writers safely';
  end if;

  select staff.business_id,business.slug,staff.user_id,staff.id
    into v_business,v_business_slug,v_owner,v_owner_staff
    from public.staff staff
    join public.businesses business on business.id=staff.business_id
   where staff.role='owner'
     and staff.active
     and staff.user_id is not null
   order by staff.created_at,staff.id
   limit 1;
  if v_business is null then
    raise exception 'v84 suite requires an active owner fixture';
  end if;
  select branch.id into v_branch
    from public.branches branch
   where branch.business_id=v_business and branch.active
   order by branch.is_default desc,branch.created_at,branch.id
   limit 1;
  if v_branch is null then
    raise exception 'v84 suite requires an active branch fixture';
  end if;

  reset role;
  insert into auth.users(
    instance_id,id,aud,role,email,encrypted_password,
    email_confirmed_at,created_at,updated_at
  ) values (
    '00000000-0000-0000-0000-000000000000',
    v_outsider,'authenticated','authenticated',
    'v84-outsider-'||substr(v_outsider::text,1,8)||'@example.test',
    '',now(),now(),now()
  );
  insert into public.clients(business_id,full_name)
  values(v_business,'V84 correction customer')
  returning id into v_client;
  insert into public.clients(business_id,full_name)
  values(v_business,'V84 spent-points customer')
  returning id into v_spent_client;

  update app.platform_feature_flags
     set enabled=true,changed_at=now()
   where feature_key in ('customer_claims','customer_wallet');
  insert into auth.users(
    instance_id,id,aud,role,email,encrypted_password,
    email_confirmed_at,created_at,updated_at
  ) values (
    '00000000-0000-0000-0000-000000000000',
    v_customer_user,'authenticated','authenticated',
    'v84-customer-'||substr(v_customer_user::text,1,8)||'@example.test',
    '',now(),now(),now()
  );
  insert into public.customer_identities(auth_user_id,status,created_via)
  values(v_customer_user,'active','wallet_start')
  returning id into v_customer_identity;
  perform set_config('app.customer_link_insert_id',v_customer_link::text,true);
  insert into public.customer_links(
    id,business_id,identity_id,auth_user_id,client_id,state,
    verification_method,verified_at
  ) values (
    v_customer_link,v_business,v_customer_identity,v_customer_user,v_client,
    'verified','email_claim',now()
  );
  perform set_config('app.customer_link_insert_id','',true);

  perform pg_temp.as_v84_user(v_owner);
  v_original := (
    public.record_quick_sale(
      v_business,5500,'cash',v_client,v_owner_staff,v_branch,
      'Original receipt note','v84-original-sale',true
    )::jsonb #>> '{sale,id}'
  )::uuid;
  if v_original is null then
    raise exception 'v84 original sale fixture was not recorded';
  end if;

  v_result := public.correct_quick_sale_amount_v84(
    v_business,v_original,5800,'v84-correct-5500-to-5800',null
  );
  v_reversal := (v_result->>'reversal_sale_id')::uuid;
  v_replacement := (v_result->>'replacement_sale_id')::uuid;
  if v_result->>'status'<>'corrected'
     or (v_result->>'original_amount_cents')::integer<>5500
     or (v_result->>'corrected_amount_cents')::integer<>5800
     or (v_result->>'current_payment_cents')::integer<>5500
     or (v_result->>'points_removed')::integer<>55
     or (v_result->>'points_earned')::integer<>58
     or coalesce((v_result->>'replayed')::boolean,true)
     or v_reversal is null
     or v_replacement is null then
    raise exception 'v84 correction result is incomplete: %',v_result;
  end if;
  reset role;

  if not exists (
    select 1
      from public.sales original
      join public.sales reversal
        on reversal.business_id=original.business_id
       and reversal.reversal_of=original.id
      join public.sales replacement
        on replacement.id=v_replacement
       and replacement.business_id=original.business_id
     where original.id=v_original
       and original.business_id=v_business
       and original.amount_cents=5500
       and original.note='Original receipt note'
       and reversal.id=v_reversal
       and reversal.amount_cents=-5500
       and replacement.amount_cents=5800
       and replacement.client_id is not distinct from original.client_id
       and replacement.branch_id is not distinct from original.branch_id
       and replacement.staff_id is not distinct from original.staff_id
       and replacement.note is not distinct from original.note
  ) then
    raise exception 'v84 changed or lost original sale linkage instead of appending a chain';
  end if;
  if (select coalesce(sum(amount_cents),0) from public.payments
       where business_id=v_business and sale_id=v_original)<>0
     or (select coalesce(sum(amount_cents),0) from public.payments
          where business_id=v_business and sale_id=v_replacement)<>5800 then
    raise exception 'v84 original refund/replacement payment evidence does not reconcile';
  end if;
  select coalesce(sum(points),0)::integer into v_original_points
    from public.points_ledger
   where business_id=v_business and sale_id=v_original;
  select coalesce(sum(points),0)::integer into v_reversal_points
    from public.points_ledger
   where business_id=v_business and sale_id=v_reversal;
  if v_original_points+v_reversal_points<>0 then
    raise exception 'v84 original/reversal points do not net to zero: %, %',
      v_original_points,v_reversal_points;
  end if;
  if (select coalesce(sum(points),0)::integer from public.points_ledger
       where business_id=v_business
         and sale_id in(v_original,v_reversal,v_replacement))
     <> (select coalesce(sum(points),0)::integer from public.points_ledger
          where business_id=v_business and sale_id=v_replacement)
     or (select coalesce(sum(points),0)::integer from public.points_ledger
          where business_id=v_business and sale_id=v_replacement)
        <> (v_result->>'points_earned')::integer then
    raise exception 'v84 correction did not remove original earn and expose replacement earn';
  end if;
  if exists (
    select 1 from public.points_batches batch
     where batch.business_id=v_business
       and batch.sale_id=v_original
       and batch.remaining<>0
  ) or (select coalesce(sum(points),0)::integer
          from public.points_ledger
         where business_id=v_business and client_id=v_client)
       <> (select coalesce(sum(remaining),0)::integer
             from public.points_batches
            where business_id=v_business and client_id=v_client) then
    raise exception 'v84 points batch cache did not remove only the original earn';
  end if;
  if not exists (
    select 1 from public.sale_amount_corrections_v84 correction
     where correction.business_id=v_business
       and correction.original_sale_id=v_original
       and correction.reversal_sale_id=v_reversal
       and correction.replacement_sale_id=v_replacement
       and correction.original_amount_cents=5500
       and correction.corrected_amount_cents=5800
       and correction.points_removed=55
       and correction.points_compensation_ledger_id
           =(v_result->>'points_compensation_ledger_id')::uuid
       and correction.note is null
       and correction.result=v_result
  ) then
    raise exception 'v84 append-only correction evidence is missing';
  end if;
  if not exists (
    select 1
      from public.sale_amount_corrections_v84 correction
      join public.points_ledger compensation
        on compensation.id=correction.points_compensation_ledger_id
       and compensation.business_id=correction.business_id
     where correction.business_id=v_business
       and correction.original_sale_id=v_original
       and compensation.client_id=v_client
       and compensation.sale_id=v_reversal
       and compensation.entry_type='adjust'
       and compensation.points=-55
       and compensation.reference
           ='sale amount correction: remove original earn for sale '||v_original::text
  ) then
    raise exception 'v84 append-only loyalty compensation evidence is missing';
  end if;
  if not exists (
    select 1 from public.audit_log audit
     where audit.business_id=v_business
       and audit.action='SALE_AMOUNT_CORRECTED_V84'
       and audit.entity_id=v_original
       and (audit.detail->>'replacement_sale_id')::uuid=v_replacement
  ) then
    raise exception 'v84 correction audit log evidence is missing';
  end if;

  -- Customer-facing history must show the immutable economic truth end to end:
  -- original earn, explicit removal on the reversal, and replacement earn. The
  -- active net point value is exactly the replacement earn, never both earns.
  perform pg_temp.as_v84_user(v_customer_user);
  v_history:=public.customer_get_transaction_history_v81(
    v_business_slug,jsonb_build_object('limit',20)
  );
  reset role;
  if (select count(*) from jsonb_array_elements(v_history->'items') item
       where (item->>'source_id')::uuid=v_original
         and item->>'status'='reversed'
         and (item->>'points_earned')::integer=55
         and (item->>'points_removed')::integer=0)<>1
     or (select count(*) from jsonb_array_elements(v_history->'items') item
          where (item->>'source_id')::uuid=v_reversal
            and item->>'status'='reversal'
            and (item->>'points_earned')::integer=0
            and (item->>'points_removed')::integer=55)<>1
     or (select count(*) from jsonb_array_elements(v_history->'items') item
          where (item->>'source_id')::uuid=v_replacement
            and item->>'status'='completed'
            and (item->>'points_earned')::integer=58
            and (item->>'points_removed')::integer=0)<>1
     or (select coalesce(sum(
            (item->>'points_earned')::integer-(item->>'points_removed')::integer
          ),0)
           from jsonb_array_elements(v_history->'items') item
          where (item->>'source_id')::uuid
                in(v_original,v_reversal,v_replacement))<>58 then
    raise exception 'v84 customer wallet history did not expose the exact correction point chain: %',
      v_history;
  end if;

  perform pg_temp.as_v84_user(v_owner);
  v_replay := public.correct_quick_sale_amount_v84(
    v_business,v_original,5800,'v84-correct-5500-to-5800',null
  );
  if coalesce((v_replay->>'replayed')::boolean,false) is not true
     or (v_replay->>'reversal_sale_id')::uuid<>v_reversal
     or (v_replay->>'replacement_sale_id')::uuid<>v_replacement then
    raise exception 'v84 exact correction replay changed the result: %',v_replay;
  end if;
  v_blocked:=false;
  begin
    perform public.correct_quick_sale_amount_v84(
      v_business,v_original,5900,'v84-correct-5500-to-5800',null
    );
  exception when unique_violation then
    v_blocked:=true;
  end;
  if not v_blocked then
    raise exception 'v84 changed request reused the correction key';
  end if;
  v_blocked:=false;
  begin
    perform public.correct_quick_sale_amount_v84(
      v_business,v_original,5900,'v84-different-correction-key',null
    );
  exception when unique_violation then
    v_blocked:=true;
  end;
  if not v_blocked then
    raise exception 'v84 corrected the same immutable original twice';
  end if;

  v_second := (
    public.record_quick_sale(
      v_business,1200,'cash',v_client,v_owner_staff,v_branch,
      null,'v84-fast-reverse-source',true
    )::jsonb #>> '{sale,id}'
  )::uuid;
  v_second_reversal := (
    public.reverse_sale_fast_v84(
      v_business,v_second,null,'v84-fast-reverse'
    )::jsonb->>'reversal_sale_id'
  )::uuid;
  reset role;
  if not exists (
    select 1 from public.sales sale
     where sale.id=v_second_reversal
       and sale.business_id=v_business
       and sale.reversal_of=v_second
       and sale.reversal_reason='Staff-confirmed sale reversal'
  ) then
    raise exception 'v84 optional-note fast reversal did not retain auditable system reason';
  end if;

  -- A pre-reversed original is refused before any replacement can be written.
  perform pg_temp.as_v84_user(v_owner);
  v_blocked:=false;
  begin
    perform public.correct_quick_sale_amount_v84(
      v_business,v_second,1300,'v84-pre-reversed-refused',null
    );
  exception when unique_violation then
    v_blocked:=true;
  end;
  if not v_blocked then
    raise exception 'v84 corrected a pre-reversed original';
  end if;

  -- Unpaid originals remain unpaid after the append-only replacement.
  v_unpaid := (
    public.record_quick_sale(
      v_business,700,'cash',v_client,v_owner_staff,v_branch,
      'Unpaid correction fixture','v84-unpaid-source',false
    )::jsonb #>> '{sale,id}'
  )::uuid;
  v_result := public.correct_quick_sale_amount_v84(
    v_business,v_unpaid,900,'v84-unpaid-correction',null
  );
  v_unpaid_replacement := (v_result->>'replacement_sale_id')::uuid;
  reset role;
  if coalesce((v_result->>'paid')::boolean,true)
     or v_result->>'replacement_payment_id' is not null
     or exists (
       select 1 from public.payments payment
        where payment.business_id=v_business
          and payment.sale_id in(v_unpaid,v_unpaid_replacement)
     ) then
    raise exception 'v84 unpaid original gained a payment during correction: %',v_result;
  end if;

  -- Paid state comes from the current net journal, not the creation request.
  -- A sale created unpaid but paid in full later is corrected as fully paid.
  perform pg_temp.as_v84_user(v_owner);
  v_later_paid := (
    public.record_quick_sale(
      v_business,1400,'cash',v_client,v_owner_staff,v_branch,
      'Later paid correction fixture','v84-later-paid-source',false
    )::jsonb #>> '{sale,id}'
  )::uuid;
  perform public.record_payment(
    p_business=>v_business,p_method=>'cash',p_amount_cents=>1400,
    p_sale=>v_later_paid,p_client=>v_client,p_staff=>v_owner_staff,
    p_branch=>v_branch,p_reference=>'V84 later payment',
    p_idempotency_key=>'v84-later-payment'
  );
  v_result:=public.correct_quick_sale_amount_v84(
    v_business,v_later_paid,1500,'v84-later-paid-correction',null
  );
  v_later_paid_replacement:=(v_result->>'replacement_sale_id')::uuid;
  reset role;
  if coalesce((v_result->>'paid')::boolean,false) is not true
     or (v_result->>'current_payment_cents')::integer<>1400
     or (select coalesce(sum(amount_cents),0) from public.payments
          where business_id=v_business and sale_id=v_later_paid)<>0
     or (select coalesce(sum(amount_cents),0) from public.payments
          where business_id=v_business and sale_id=v_later_paid_replacement)<>1500 then
    raise exception 'v84 did not derive and preserve later full cash payment state: %',v_result;
  end if;

  -- Partial, mixed, and provider-settled journals cannot be represented by the
  -- replacement quick-sale writer, so they fail closed before any reversal.
  perform pg_temp.as_v84_user(v_owner);
  v_partial:=(
    public.record_quick_sale(
      v_business,1000,'cash',v_client,v_owner_staff,v_branch,
      null,'v84-partial-source',false
    )::jsonb #>> '{sale,id}'
  )::uuid;
  perform public.record_payment(
    p_business=>v_business,p_method=>'cash',p_amount_cents=>400,
    p_sale=>v_partial,p_client=>v_client,p_staff=>v_owner_staff,
    p_branch=>v_branch,p_idempotency_key=>'v84-partial-payment'
  );
  v_blocked:=false;
  begin
    perform public.correct_quick_sale_amount_v84(
      v_business,v_partial,1200,'v84-partial-refused',null
    );
  exception when feature_not_supported then
    v_blocked:=true;
  end;
  if not v_blocked
     or exists (
       select 1 from public.sales reversal
        where reversal.business_id=v_business and reversal.reversal_of=v_partial
     ) then
    raise exception 'v84 did not fail closed on a partial payment journal';
  end if;

  v_mixed:=(
    public.record_quick_sale(
      v_business,1000,'cash',v_client,v_owner_staff,v_branch,
      null,'v84-mixed-source',false
    )::jsonb #>> '{sale,id}'
  )::uuid;
  perform public.record_payment(
    p_business=>v_business,p_method=>'cash',p_amount_cents=>500,
    p_sale=>v_mixed,p_client=>v_client,p_staff=>v_owner_staff,
    p_branch=>v_branch,p_idempotency_key=>'v84-mixed-cash'
  );
  perform public.record_payment(
    p_business=>v_business,p_method=>'card',p_amount_cents=>500,
    p_sale=>v_mixed,p_client=>v_client,p_staff=>v_owner_staff,
    p_branch=>v_branch,p_idempotency_key=>'v84-mixed-card'
  );
  v_blocked:=false;
  begin
    perform public.correct_quick_sale_amount_v84(
      v_business,v_mixed,1100,'v84-mixed-refused',null
    );
  exception when feature_not_supported then
    v_blocked:=true;
  end;
  if not v_blocked
     or exists (
       select 1 from public.sales reversal
        where reversal.business_id=v_business and reversal.reversal_of=v_mixed
     ) then
    raise exception 'v84 did not fail closed on a mixed payment journal';
  end if;

  v_card_paid:=(
    public.record_quick_sale(
      v_business,1000,'card',v_client,v_owner_staff,v_branch,
      null,'v84-card-source',true
    )::jsonb #>> '{sale,id}'
  )::uuid;
  v_blocked:=false;
  begin
    perform public.correct_quick_sale_amount_v84(
      v_business,v_card_paid,1100,'v84-card-refused',null
    );
  exception when feature_not_supported then
    v_blocked:=true;
  end;
  if not v_blocked
     or exists (
       select 1 from public.sales reversal
        where reversal.business_id=v_business and reversal.reversal_of=v_card_paid
     ) then
    raise exception 'v84 did not fail closed on provider-settled payment state';
  end if;

  -- If any source earn was consumed, exact source removal is no longer provable.
  -- The fast path refuses without reserving a correction or reversing the sale.
  v_spent_original:=(
    public.record_quick_sale(
      v_business,1100,'cash',v_spent_client,v_owner_staff,v_branch,
      null,'v84-spent-points-source',true
    )::jsonb #>> '{sale,id}'
  )::uuid;
  select coalesce(sum(points),0)::integer into v_spent_points
    from public.points_ledger
   where business_id=v_business
     and sale_id=v_spent_original
     and entry_type='earn';
  perform public.adjust_points(
    v_business,v_spent_client,-1,'V84 spent source point fixture'
  );
  v_blocked:=false;
  begin
    perform public.correct_quick_sale_amount_v84(
      v_business,v_spent_original,1200,'v84-spent-points-refused',null
    );
  exception when sqlstate '55000' then
    v_blocked:=true;
  end;
  if v_spent_points<=0
     or not v_blocked
     or exists (
       select 1 from public.sales reversal
        where reversal.business_id=v_business
          and reversal.reversal_of=v_spent_original
     )
     or exists (
       select 1 from public.sale_amount_corrections_v84 correction
        where correction.business_id=v_business
          and correction.original_sale_id=v_spent_original
     ) then
    raise exception 'v84 did not fail closed when original loyalty points were spent';
  end if;

  perform pg_temp.as_v84_user(v_outsider);
  v_blocked:=false;
  begin
    perform public.correct_quick_sale_amount_v84(
      v_business,v_replacement,6000,'v84-outsider-denied',null
    );
  exception when insufficient_privilege then
    v_blocked:=true;
  end;
  if not v_blocked then
    raise exception 'v84 non-staff principal corrected a sale';
  end if;

  reset role;
  raise notice 'v84 fast sale-correction suite: ALL PASS';
end
$v84$;

rollback;
