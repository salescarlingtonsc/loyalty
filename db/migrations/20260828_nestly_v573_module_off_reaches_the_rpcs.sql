-- nestly_v573 -- the module toggle reaches the RPC readers and writers too.
--
-- CONTEXT. The owner asked for the v570 audit to be run across every other module. Two audits
-- were run: one over all 176 RLS-carrying tables (fixed in nestly_v572), and one mapping every
-- module key to its principal RPC reader/writer. This migration closes what the second found.
--
-- THE PATTERN, third time now (v570 dashboard, v572 tables, v573 RPCs): Peekaa has TWO
-- permission systems -- ROLE permissions (app.has_perm: view_sales, view_finance, create_sales,
-- refund_sales) and MODULE permissions (app.can_module, the per-staff Off switches the owner
-- actually sets in the UI). Where a function asked only the ROLE, the owner's module switch was
-- decorative. Every role in role_perms('staff') carries view_sales and create_sales by
-- definition, so "gated on view_sales" means "gated on being staff".
--
-- WHAT THIS CLOSES (module -> what an explicitly-denied teammate could still do):
--   dailyreport   get_dashboard_summary (the LEGACY overload behind Daily report) -- returned the
--                 day's revenue, visits and sale mix. Literally the v570 defect on a second page;
--                 v570 fixed _v155 and this overload sat beside it, unfixed.
--   customerintel get_customer_intelligence_v83 + its two export RPCs -- per-customer spend,
--                 visit history and a DOWNLOADABLE export; and get_revenue_truth_v106,
--                 get_period_economics_v109, get_revenue_driver_decomposition_v109,
--                 get_effective_sector_policy_v109 -- P&L-grade revenue, margin and drivers.
--   expenses      set_expense_void, update_expense_v285 -- void and edit expense records. Their
--                 own sibling create_expense was ALREADY module-gated, which is the tell.
--   sales         correct_quick_sale_amount_v84, staff_get_reversal_workflows -- correct and
--                 reverse sales, moving money and loyalty with them.
--   till          record_cart_sale (both overloads), evaluate_checkout,
--                 reserve_checkout_sv_tender -- finalise a cart and tender stored value.
--
-- METHOD. Every definition below was extracted from live production with pg_get_functiondef and
-- patched by a single anchored replacement asserted to match exactly once, so nothing else in
-- these bodies changed. Grants are restated verbatim from the live proacl.
--
-- WHY IT IS SAFE FOR EXISTING ACCOUNTS (app.staff_module_mode_v94, measured for v570 and again
-- for v572): role='owner' returns the platform mode so owners always pass; a staff row with
-- modules IS NULL and no module_perms map resolves 'rw' so inherit-staff always pass; only an
-- explicit denial is refused. Estate measurement taken before writing this: 17 owners and 0
-- inherit-staff are unaffected; 2 configured staff accounts lose exactly the surfaces their own
-- owner already switched Off. That is the fix working, not collateral damage.
--
-- The module check is added ALONGSIDE the existing role check, never instead of it -- these
-- surfaces keep every finance/refund restriction they already had.
--
-- ROLLBACK: db/tests/v573_module_off_reaches_the_rpcs.sql

begin;

do $pre$
declare
  v_missing text;
begin
  if to_regprocedure('app.can_module(uuid,text)') is null then
    raise exception 'v573: app.can_module(uuid,text) is missing -- the authority this migration delegates to';
  end if;
  -- Drift check. The bodies below were extracted from live production with pg_get_functiondef,
  -- so the thing that would make replaying them dangerous is an overload having MOVED or gone --
  -- that would mean these bodies no longer correspond to what production runs. Presence of the
  -- module gate is NOT an error: this migration is idempotent by construction (every statement
  -- is CREATE OR REPLACE plus an explicit grant restatement), so replaying it is a no-op.
  select string_agg(sig, ', ') into v_missing
  from unnest(array[
    'public.correct_quick_sale_amount_v84(uuid,uuid,integer,text,text)',
    'public.create_customer_intelligence_export_v83(uuid,uuid,date,date)',
    'public.evaluate_checkout(uuid,uuid,uuid,jsonb,uuid)',
    'public.get_customer_intelligence_export_page_v83(uuid,integer,integer)',
    'public.get_dashboard_summary(uuid,date,date,uuid)',
    'public.get_revenue_truth_v106(uuid,date,date,uuid,timestamptz)',
    'public.reserve_checkout_sv_tender(uuid,uuid,integer,uuid)',
    'public.set_expense_void(uuid,uuid,boolean)',
    'public.update_expense_v285(uuid,uuid,integer,text,text)'
  ]) sig
  where to_regprocedure(sig) is null;
  if v_missing is not null then
    raise exception 'v573: expected overloads are absent (%) -- production has drifted; re-derive these bodies from the live definitions before applying', v_missing;
  end if;
end
$pre$;

CREATE OR REPLACE FUNCTION public.correct_quick_sale_amount_v84(p_business uuid, p_sale uuid, p_corrected_amount_cents integer, p_idempotency_key text, p_note text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'app', 'pg_temp'
AS $function$
declare
  v_actor uuid := auth.uid();
  v_key text := nullif(btrim(p_idempotency_key),'');
  v_note text := nullif(btrim(p_note),'');
  v_original public.sales%rowtype;
  v_existing public.sale_amount_corrections_v84%rowtype;
  v_payload jsonb;
  v_hash text;
  v_reverse jsonb;
  v_replacement jsonb;
  v_reversal_sale uuid;
  v_replacement_sale uuid;
  v_method text;
  v_paid boolean;
  v_payment_net_cents integer := 0;
  v_nonzero_payment_methods integer := 0;
  v_positive_payment_methods integer := 0;
  v_original_points integer := 0;
  v_original_batch_earned integer := 0;
  v_original_batch_remaining integer := 0;
  v_points_compensation_id uuid;
  v_earn_programme record;
  v_points_compensation_ids uuid[] := array[]::uuid[];
  v_points_removed_by_programme jsonb := '{}'::jsonb;
  v_points_earned integer := 0;
  v_result jsonb;
begin
  perform app.acquire_loyalty_shared_v480(p_business);
  perform app.lock_refund_staff_v480(p_business);
  if v_actor is null
     or not app.has_perm(p_business,'refund_sales')
     or not app.has_perm(p_business,'create_sales')
     or not app.can_module(p_business,'sales') then
    raise exception 'sale correction requires active create-sales and refund-sales authorization'
      using errcode='42501';
  end if;
  if v_key is null or length(v_key) not between 8 and 200 then
    raise exception 'idempotency key must contain 8 to 200 characters'
      using errcode='22023';
  end if;
  if coalesce(p_corrected_amount_cents,0) <= 0 then
    raise exception 'corrected sale amount must be positive'
      using errcode='22023';
  end if;

  select * into v_original
    from public.sales
   where id=p_sale and business_id=p_business;
  if not found then
    raise exception 'sale not found in this business' using errcode='42501';
  end if;
  if not app.can_see_branch(p_business,v_original.branch_id) then
    raise exception 'sale branch scope is not permitted' using errcode='42501';
  end if;

  -- Authorization precedes the attacker-selected idempotency lock.
  perform pg_advisory_xact_lock(
    hashtextextended(p_business::text||':sale-correction-v84:'||v_key,0)
  );

  v_payload := jsonb_build_object(
    'business_id',p_business,
    'sale_id',p_sale,
    'branch_id',v_original.branch_id,
    'actor',v_actor,
    'original_amount_cents',v_original.amount_cents,
    'corrected_amount_cents',p_corrected_amount_cents,
    'note',v_note
  );
  v_hash := md5(v_payload::text);

  select * into v_existing
    from public.sale_amount_corrections_v84 correction
   where correction.business_id=p_business
     and correction.idempotency_key=v_key;
  if found then
    if v_existing.original_sale_id is distinct from p_sale
       or v_existing.request_hash is distinct from v_hash
       or v_existing.request_payload is distinct from v_payload then
      raise exception 'sale-correction idempotency key conflicts with a changed request'
        using errcode='23505';
    end if;
    if not exists (
      select 1
        from public.sales original
        join public.sales reversal
          on reversal.id=v_existing.reversal_sale_id
         and reversal.business_id=original.business_id
         and reversal.reversal_of=original.id
        join public.sales replacement
          on replacement.id=v_existing.replacement_sale_id
         and replacement.business_id=original.business_id
       where original.id=v_existing.original_sale_id
         and original.business_id=v_existing.business_id
         and original.amount_cents=v_existing.original_amount_cents
         and reversal.amount_cents=-v_existing.original_amount_cents
         and replacement.amount_cents=v_existing.corrected_amount_cents
    ) then
      raise exception 'completed sale correction is missing exact sale-chain evidence'
        using errcode='XX001';
    end if;
    if (v_existing.points_removed=0
          and v_existing.points_compensation_ledger_id is not null)
       or (v_existing.points_removed>0 and (
         v_existing.points_compensation_ledger_id is null
         or not coalesce(case
              when v_existing.points_compensation_ledger_ids is null
               and v_existing.points_removed_by_programme is null
              then exists (
                select 1
                  from public.points_ledger compensation
                 where compensation.id=v_existing.points_compensation_ledger_id
                   and compensation.business_id=v_existing.business_id
                   and compensation.client_id=(
                     select original.client_id
                       from public.sales original
                      where original.id=v_existing.original_sale_id
                        and original.business_id=v_existing.business_id
                   )
                   and compensation.sale_id=v_existing.reversal_sale_id
                   and compensation.entry_type='adjust'
                   and compensation.points=-v_existing.points_removed
              )
              else (
                select jsonb_typeof(v_existing.points_removed_by_programme)='object'
                   and coalesce(array_length(v_existing.points_compensation_ledger_ids,1),0)>0
                   and count(*)=coalesce(array_length(v_existing.points_compensation_ledger_ids,1),0)
                   and coalesce(sum(compensation.points),0)=-v_existing.points_removed
                   and count(*) filter (
                         where (v_existing.points_removed_by_programme
                                  ->>compensation.programme_id::text)::integer
                               is distinct from -compensation.points)=0
                   and count(distinct compensation.programme_id)=(
                         select count(*)
                           from jsonb_object_keys(v_existing.points_removed_by_programme))
                  from public.points_ledger compensation
                 where compensation.id=any(v_existing.points_compensation_ledger_ids)
                   and compensation.business_id=v_existing.business_id
                   and compensation.client_id=(
                     select original.client_id
                       from public.sales original
                      where original.id=v_existing.original_sale_id
                        and original.business_id=v_existing.business_id
                   )
                   and compensation.sale_id=v_existing.reversal_sale_id
                   and compensation.entry_type='adjust'
              )
            end,false)
         or exists (
           select 1
             from public.points_batches batch
            where batch.business_id=v_existing.business_id
              and batch.sale_id=v_existing.original_sale_id
              and batch.remaining<>0
         )
       )) then
      raise exception 'completed sale correction is missing exact loyalty compensation evidence'
        using errcode='XX001';
    end if;
    return v_existing.result || jsonb_build_object('replayed',true);
  end if;

  select * into v_original
    from public.sales
   where id=p_sale and business_id=p_business
   for update;
  if not found
     or not app.has_perm(p_business,'refund_sales')
     or not app.has_perm(p_business,'create_sales')
     or not app.can_see_branch(p_business,v_original.branch_id) then
    raise exception 'sale correction authorization changed while locking'
      using errcode='42501';
  end if;
  if v_original.reversal_of is not null
     or v_original.amount_cents <= 0
     or v_original.kind <> 'quick_sale' then
    raise exception 'only a positive original quick sale can use fast amount correction'
      using errcode='22023';
  end if;
  if p_corrected_amount_cents=v_original.amount_cents then
    raise exception 'corrected amount is unchanged' using errcode='22023';
  end if;
  if exists (
    select 1 from public.sales reversal
     where reversal.business_id=p_business and reversal.reversal_of=v_original.id
  ) then
    raise exception 'sale is already reversed; correct the active replacement instead'
      using errcode='23505';
  end if;
  if exists (
    select 1 from public.sale_amount_corrections_v84 correction
     where correction.original_sale_id=v_original.id
  ) then
    raise exception 'sale was already corrected; correct the active replacement instead'
      using errcode='23505';
  end if;
  if v_original.staff_id is not null and not exists (
    select 1 from public.staff staff
     where staff.id=v_original.staff_id
       and staff.business_id=p_business
       and staff.active
  ) then
    raise exception 'the originally tagged team member is inactive; use reversal and a new sale'
      using errcode='55000';
  end if;

  -- Lock the customer before inspecting FEFO point batches. A fast correction can remove
  -- only the exact, wholly-unspent earn created by the source sale. If any of that earn was
  -- consumed, the coherent automatic path no longer exists and the whole correction refuses
  -- before reverse_sale writes anything.
  if v_original.client_id is not null then
    perform 1
      from public.clients client
     where client.id=v_original.client_id
       and client.business_id=p_business
     for update;
    if not found then
      raise exception 'sale customer no longer belongs to this business' using errcode='XX001';
    end if;
  end if;
  select coalesce(sum(ledger.points),0)::integer
    into v_original_points
    from public.points_ledger ledger
   where ledger.business_id=p_business
     and ledger.sale_id=v_original.id
     and ledger.entry_type='earn';
  if v_original_points>0 then
    if v_original.client_id is null then
      raise exception 'sale earn has no customer provenance' using errcode='XX001';
    end if;
    perform 1
      from public.points_batches batch
     where batch.business_id=p_business
       and batch.client_id=v_original.client_id
       and batch.sale_id=v_original.id
     order by batch.id
     for update;
    select coalesce(sum(batch.earned),0)::integer,
           coalesce(sum(batch.remaining),0)::integer
      into v_original_batch_earned,v_original_batch_remaining
      from public.points_batches batch
     where batch.business_id=p_business
       and batch.client_id=v_original.client_id
       and batch.sale_id=v_original.id;
    if v_original_batch_earned<>v_original_points
       or v_original_batch_remaining<>v_original_points then
      raise exception 'original loyalty points are not wholly unspent; fast correction requires manual loyalty reconciliation'
        using errcode='55000';
    end if;
  elsif exists (
    select 1
      from public.points_batches batch
     where batch.business_id=p_business
       and batch.sale_id=v_original.id
  ) then
    raise exception 'sale points batch has no matching immutable earn' using errcode='XX001';
  end if;

  -- The creation request is valid only as an unpaid method preference. Paid state is derived
  -- from the CURRENT net payment journal under the locked sale, so later payments are never
  -- silently discarded. Fast correction supports exactly unpaid (net zero) or fully-paid
  -- single-method cash. Partial, mixed, overpaid, credit and provider-settled cases refuse.
  select nullif(operation.request_payload->>'method','')
    into v_method
    from public.financial_operations operation
   where operation.business_id=p_business
     and operation.sale_id=v_original.id
     and operation.operation_type='quick_sale'
     and operation.status='completed'
   order by operation.completed_at desc,operation.id desc
   limit 1;
  if not found then
    raise exception 'quick-sale creation evidence is missing' using errcode='XX001';
  end if;
  if v_method not in ('cash','card','paynow','bank_transfer','other') then
    raise exception 'the original unpaid method preference cannot be reproduced by quick sale'
      using errcode='0A000';
  end if;
  with method_nets as (
    select payment.method,sum(payment.amount_cents)::integer as net_cents
      from public.payments payment
     where payment.business_id=p_business
       and (
         payment.sale_id=v_original.id
         or (
           payment.sale_id is null
           and v_original.appointment_id is not null
           and payment.appointment_id=v_original.appointment_id
         )
       )
     group by payment.method
  )
  select coalesce(sum(net_cents),0)::integer,
         count(*) filter (where net_cents<>0)::integer,
         count(*) filter (where net_cents>0)::integer,
         min(method) filter (where net_cents>0)
    into v_payment_net_cents,v_nonzero_payment_methods,
         v_positive_payment_methods,v_method
    from method_nets;
  if v_payment_net_cents=0 and v_nonzero_payment_methods=0 then
    v_paid:=false;
    select nullif(operation.request_payload->>'method','')
      into v_method
      from public.financial_operations operation
     where operation.business_id=p_business
       and operation.sale_id=v_original.id
       and operation.operation_type='quick_sale'
       and operation.status='completed'
     order by operation.completed_at desc,operation.id desc
     limit 1;
  elsif v_payment_net_cents=v_original.amount_cents
        and v_nonzero_payment_methods=1
        and v_positive_payment_methods=1
        and v_method='cash' then
    v_paid:=true;
  else
    raise exception 'fast correction supports only net-unpaid or fully-paid single-method cash sales; current payment state is % cents across % nonzero methods',
      v_payment_net_cents,v_nonzero_payment_methods
      using errcode='0A000';
  end if;

  -- These two calls execute in this function's transaction. Any refusal or failure in
  -- either call rolls back both operations and the audit link.
  v_reverse := public.reverse_sale_v480_base(
    p_business,
    v_original.id,
    'Amount corrected from '||v_original.amount_cents::text
      ||' to '||p_corrected_amount_cents::text||' cents'
      ||case when v_note is null then '' else ' · Staff note: '||v_note end,
    'v84:'||md5(v_key)||':reverse',
    'Peekaa amount correction',
    'none'
  )::jsonb;
  v_reversal_sale := nullif(v_reverse->>'reversal_sale_id','')::uuid;
  if v_reversal_sale is null then
    raise exception 'sale correction did not produce reversal evidence' using errcode='XX001';
  end if;

  if v_original_points>0 then
    v_points_compensation_id:=gen_random_uuid();
    perform set_config(
      'app.points_ledger_insert_id',v_points_compensation_id::text,true
    );
    perform set_config(
      'app.points_ledger_write_scope','sale_amount_correction_v84',true
    );
    null;
    for v_earn_programme in
      select ledger.programme_id as programme_id,
             coalesce(sum(ledger.points),0)::integer as points
        from public.points_ledger ledger
       where ledger.business_id=p_business
         and ledger.sale_id=v_original.id
         and ledger.entry_type='earn'
       group by ledger.programme_id
       order by ledger.programme_id
    loop
      if v_earn_programme.points<=0 then continue; end if;
      v_points_compensation_id:=gen_random_uuid();
      perform set_config(
        'app.points_ledger_insert_id',v_points_compensation_id::text,true
      );
      perform set_config(
        'app.points_ledger_write_scope','sale_amount_correction_v84',true
      );
      insert into public.points_ledger(
        id,business_id,client_id,entry_type,points,sale_id,reference,actor,programme_id
      ) values (
        v_points_compensation_id,p_business,v_original.client_id,'adjust',
        -v_earn_programme.points,v_reversal_sale,
        'sale amount correction: remove original earn for sale '||v_original.id,
        v_actor,v_earn_programme.programme_id
      );
      perform set_config('app.points_ledger_insert_id','',true);
      perform set_config('app.points_ledger_write_scope','',true);

      update public.points_batches batch
         set remaining=0
       where batch.business_id=p_business
         and batch.client_id=v_original.client_id
         and batch.sale_id=v_original.id
         and batch.programme_id=v_earn_programme.programme_id
         and batch.remaining=batch.earned;

      v_points_compensation_ids:=v_points_compensation_ids||v_points_compensation_id;
      v_points_removed_by_programme:=v_points_removed_by_programme
        ||jsonb_build_object(v_earn_programme.programme_id::text,v_earn_programme.points);
    end loop;
    v_points_compensation_id:=v_points_compensation_ids[1];
    if (select coalesce(sum(ledger.points),0)::integer
          from public.points_ledger ledger
         where ledger.business_id=p_business
           and ledger.client_id=v_original.client_id)
       <> (select coalesce(sum(batch.remaining),0)::integer
             from public.points_batches batch
            where batch.business_id=p_business
              and batch.client_id=v_original.client_id) then
      raise exception 'points ledger and batch cache diverged during sale correction'
        using errcode='XX001';
    end if;
    if exists (
      select 1
        from (select ledger.programme_id,sum(ledger.points) as total
                from public.points_ledger ledger
               where ledger.business_id=p_business
                 and ledger.client_id=v_original.client_id
               group by ledger.programme_id) led
        full join (select batch.programme_id,sum(batch.remaining) as total
                     from public.points_batches batch
                    where batch.business_id=p_business
                      and batch.client_id=v_original.client_id
                    group by batch.programme_id) bat
          on bat.programme_id=led.programme_id
       where coalesce(led.total,0)<>coalesce(bat.total,0)
    ) then
      raise exception 'per-programme points ledger and batch cache diverged during sale correction'
        using errcode='XX001';
    end if;
  end if;

  v_replacement := public.record_quick_sale(
    p_business=>p_business,
    p_amount_cents=>p_corrected_amount_cents,
    p_method=>v_method,
    p_client=>v_original.client_id,
    p_staff=>v_original.staff_id,
    p_branch=>v_original.branch_id,
    p_note=>v_original.note,
    p_idempotency_key=>'v84:'||md5(v_key)||':replacement',
    p_paid=>v_paid
  )::jsonb;
  v_replacement_sale := nullif(v_replacement #>> '{sale,id}','')::uuid;
  if v_replacement_sale is null then
    raise exception 'sale correction did not produce replacement evidence' using errcode='XX001';
  end if;

  select coalesce(sum(points),0)::integer
    into v_points_earned
    from public.points_ledger
   where business_id=p_business
     and sale_id=v_replacement_sale
     and entry_type='earn';
  if v_original.client_id is not null
     and (select coalesce(sum(ledger.points),0)::integer
            from public.points_ledger ledger
           where ledger.business_id=p_business
             and ledger.client_id=v_original.client_id)
         <> (select coalesce(sum(batch.remaining),0)::integer
               from public.points_batches batch
              where batch.business_id=p_business
                and batch.client_id=v_original.client_id) then
    raise exception 'replacement sale left points ledger and batch cache inconsistent'
      using errcode='XX001';
  end if;

  v_result := jsonb_build_object(
    'status','corrected',
    'original_sale_id',v_original.id,
    'reversal_sale_id',v_reversal_sale,
    'replacement_sale_id',v_replacement_sale,
    'original_amount_cents',v_original.amount_cents,
    'corrected_amount_cents',p_corrected_amount_cents,
    'branch_id',v_original.branch_id,
    'client_id',v_original.client_id,
    'staff_id',v_original.staff_id,
    'payment_method',v_method,
    'paid',v_paid,
    'current_payment_cents',v_payment_net_cents,
    'points_removed',v_original_points,
    'points_compensation_ledger_id',v_points_compensation_id,
    'points_compensation_ledger_ids',to_jsonb(v_points_compensation_ids),
    'points_removed_by_programme',v_points_removed_by_programme,
    'points_earned',v_points_earned,
    'refunded_payment_cents',coalesce((v_reverse->>'refunded_payment_cents')::integer,0),
    'replacement_payment_id',nullif(v_replacement->>'payment_id','')::uuid,
    'replayed',false
  );

  insert into public.sale_amount_corrections_v84(
    business_id,branch_id,original_sale_id,reversal_sale_id,replacement_sale_id,
    actor,original_amount_cents,corrected_amount_cents,points_removed,
    points_compensation_ledger_id,points_compensation_ledger_ids,
    points_removed_by_programme,note,idempotency_key,request_payload,request_hash,result
  ) values (
    p_business,v_original.branch_id,v_original.id,v_reversal_sale,v_replacement_sale,
    v_actor,v_original.amount_cents,p_corrected_amount_cents,v_original_points,
    v_points_compensation_id,v_points_compensation_ids,
    v_points_removed_by_programme,v_note,v_key,v_payload,v_hash,v_result
  );

  insert into public.audit_log(business_id,actor,action,entity,entity_id,detail)
  values (
    p_business,v_actor,'SALE_AMOUNT_CORRECTED_V84','sales',v_original.id,
    jsonb_build_object(
      'original_sale_id',v_original.id,
      'reversal_sale_id',v_reversal_sale,
      'replacement_sale_id',v_replacement_sale,
      'original_amount_cents',v_original.amount_cents,
      'corrected_amount_cents',p_corrected_amount_cents,
      'branch_id',v_original.branch_id,
      'client_id',v_original.client_id,
      'staff_id',v_original.staff_id,
      'current_payment_cents',v_payment_net_cents,
      'points_removed',v_original_points,
      'points_compensation_ledger_id',v_points_compensation_id,
      'note',v_note
    )
  );

  return v_result;
end
$function$;
revoke all on function public.correct_quick_sale_amount_v84(p_business uuid, p_sale uuid, p_corrected_amount_cents integer, p_idempotency_key text, p_note text) from public;
revoke all on function public.correct_quick_sale_amount_v84(p_business uuid, p_sale uuid, p_corrected_amount_cents integer, p_idempotency_key text, p_note text) from postgres;
grant execute on function public.correct_quick_sale_amount_v84(p_business uuid, p_sale uuid, p_corrected_amount_cents integer, p_idempotency_key text, p_note text) to postgres;
revoke all on function public.correct_quick_sale_amount_v84(p_business uuid, p_sale uuid, p_corrected_amount_cents integer, p_idempotency_key text, p_note text) from service_role;
grant execute on function public.correct_quick_sale_amount_v84(p_business uuid, p_sale uuid, p_corrected_amount_cents integer, p_idempotency_key text, p_note text) to service_role;
revoke all on function public.correct_quick_sale_amount_v84(p_business uuid, p_sale uuid, p_corrected_amount_cents integer, p_idempotency_key text, p_note text) from authenticated;
grant execute on function public.correct_quick_sale_amount_v84(p_business uuid, p_sale uuid, p_corrected_amount_cents integer, p_idempotency_key text, p_note text) to authenticated;

CREATE OR REPLACE FUNCTION public.create_customer_intelligence_export_v83(p_business uuid, p_branch uuid DEFAULT NULL::uuid, p_from date DEFAULT (((now() AT TIME ZONE 'Asia/Singapore'::text))::date - 365), p_to date DEFAULT ((now() AT TIME ZONE 'Asia/Singapore'::text))::date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'app', 'pg_temp'
AS $function$
declare
  v_actor uuid:=auth.uid();
  v_export uuid:=gen_random_uuid();
  v_snapshot timestamptz:=clock_timestamp();
  v_expires timestamptz:=v_snapshot+interval '24 hours';
  v_page jsonb;
  v_cursor jsonb;
  v_customer jsonb;
  v_ordinal integer:=0;
begin
  if v_actor is null then
    raise exception 'authenticated_user_required' using errcode='42501';
  end if;
  if not app.has_perm(p_business,'view_finance')
     or not app.can_module(p_business,'customerintel') then
    raise exception 'view_finance_required' using errcode='42501';
  end if;
  delete from public.customer_intelligence_exports_v83
  where requested_by=v_actor and expires_at<=clock_timestamp();

  v_page:=public.get_customer_intelligence_v83(
    p_business,p_branch,p_from,p_to,500,v_snapshot,null,null
  );
  insert into public.customer_intelligence_exports_v83(
    id,business_id,branch_id,requested_by,from_date,to_date,snapshot_at,
    expires_at,scope,methodology,data_quality,summary,forecast,total_customers
  ) values (
    v_export,p_business,p_branch,v_actor,p_from,p_to,v_snapshot,v_expires,
    v_page->'scope',v_page->'methodology',v_page->'data_quality',
    v_page->'summary',v_page->'forecast',
    coalesce((v_page#>>'{pagination,total_customers}')::integer,0)
  );

  loop
    for v_customer in select value from jsonb_array_elements(v_page->'customers')
    loop
      v_ordinal:=v_ordinal+1;
      insert into public.customer_intelligence_export_rows_v83(
        export_id,ordinal,client_id,payload
      ) values (
        v_export,v_ordinal,(v_customer->>'client_id')::uuid,v_customer
      );
    end loop;
    v_cursor:=v_page#>'{pagination,next_cursor}';
    exit when v_cursor is null or v_cursor='null'::jsonb;
    v_page:=public.get_customer_intelligence_v83(
      p_business,p_branch,p_from,p_to,500,v_snapshot,
      (v_cursor->>'customer_since')::timestamptz,
      (v_cursor->>'client_id')::uuid
    );
  end loop;

  return jsonb_build_object(
    'export_id',v_export,'snapshot_at',v_snapshot,'expires_at',v_expires,
    'total_customers',v_ordinal
  );
end
$function$;
revoke all on function public.create_customer_intelligence_export_v83(p_business uuid, p_branch uuid, p_from date, p_to date) from public;
revoke all on function public.create_customer_intelligence_export_v83(p_business uuid, p_branch uuid, p_from date, p_to date) from postgres;
grant execute on function public.create_customer_intelligence_export_v83(p_business uuid, p_branch uuid, p_from date, p_to date) to postgres;
revoke all on function public.create_customer_intelligence_export_v83(p_business uuid, p_branch uuid, p_from date, p_to date) from service_role;
grant execute on function public.create_customer_intelligence_export_v83(p_business uuid, p_branch uuid, p_from date, p_to date) to service_role;
revoke all on function public.create_customer_intelligence_export_v83(p_business uuid, p_branch uuid, p_from date, p_to date) from authenticated;
grant execute on function public.create_customer_intelligence_export_v83(p_business uuid, p_branch uuid, p_from date, p_to date) to authenticated;

CREATE OR REPLACE FUNCTION public.evaluate_checkout(p_business uuid, p_branch uuid, p_client uuid, p_lines jsonb, p_idempotency_key uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'app', 'pg_temp'
AS $function$
declare
  v_actor uuid := auth.uid();
  v_branch uuid;
  v_config uuid;
  v_hash text;
  v_existing public.checkout_evaluation_operations%rowtype;
  v_eval public.checkout_evaluations%rowtype;
  v_plan jsonb;
  v_eval_id uuid;
  v_msg text;
begin
  if v_actor is null then
    raise exception 'authenticated staff required to evaluate a checkout' using errcode = '42501';
  end if;
  if not app.has_perm(p_business, 'create_sales')
     or not app.can_module(p_business, 'till') then
    raise exception 'you do not have permission to price a checkout in this business (create_sales)'
      using errcode = '42501';
  end if;
  if p_idempotency_key is null then
    raise exception 'a checkout evaluation idempotency key is required' using errcode = '22023';
  end if;
  v_branch := coalesce(p_branch, app.default_branch(p_business));
  if v_branch is null or not exists (
    select 1 from public.branches b where b.id = v_branch and b.business_id = p_business and b.active) then
    raise exception 'checkout branch is missing, inactive, or belongs to another business' using errcode = '22023';
  end if;
  if not app.can_see_branch(p_business, v_branch) then
    raise exception 'you are not permitted to price a checkout for this branch scope' using errcode = '42501';
  end if;
  if p_client is not null and not exists (
    select 1 from public.clients c where c.id = p_client and c.business_id = p_business) then
    raise exception 'checkout client does not belong to this business' using errcode = '22023';
  end if;

  v_hash := app.ps1b_sha256(jsonb_build_object(
    'business_id', p_business, 'branch_id', v_branch, 'client_id', p_client, 'lines', p_lines)::text);

  perform pg_advisory_xact_lock(hashtextextended(
    'v58:evaluate:' || p_business::text || ':' || p_idempotency_key::text, 0));

  select * into v_existing from public.checkout_evaluation_operations o
   where o.business_id = p_business and o.idempotency_key = p_idempotency_key for update;
  if found then
    if v_existing.actor is distinct from v_actor or v_existing.request_hash <> v_hash then
      raise exception 'idempotency key conflicts with a different checkout evaluation' using errcode = '22023';
    end if;
    select * into v_eval from public.checkout_evaluations where id = v_existing.evaluation_id;
    if v_eval.consumed_at is not null or v_eval.expires_at <= now() then
      raise exception 'stale: this checkout evaluation is already consumed or expired; re-evaluate' using errcode = '22023';
    end if;
    return jsonb_build_object(
      'status', 'ok', 'replayed', true, 'evaluation_id', v_eval.id, 'expires_at', v_eval.expires_at,
      'server_lines', v_eval.server_lines, 'applied_effects', v_eval.applied_effects,
      'subtotal_cents', v_eval.subtotal_cents, 'discount_total_cents', v_eval.discount_total_cents,
      'total_cents', v_eval.total_cents, 'gst_cents', v_eval.gst_cents,
      'stored_value', app.sv_evaluate_quote(p_business, v_eval.client_id, v_eval.total_cents));
  end if;

  select active_config_version_id into v_config from public.businesses where id = p_business;

  v_plan := app.ps1c_plan_checkout(p_business, v_branch, p_client, p_lines, v_config);
  if v_plan->>'status' <> 'ok' then
    -- Surface the typed status as the message prefix. When the plan already provides a
    -- prefixed human sentence in 'reason' (custom_line_*, total_zero_not_supported) use
    -- it as-is; otherwise compose '<status>: <reason> (line N)'.
    if v_plan->>'reason' is not null and position((v_plan->>'status') || ':' in (v_plan->>'reason')) = 1 then
      v_msg := v_plan->>'reason';
    else
      v_msg := (v_plan->>'status') || ': ' || coalesce(v_plan->>'reason', 'checkout could not be priced')
               || case when v_plan->>'line' is not null then ' (line ' || (v_plan->>'line') || ')' else '' end;
    end if;
    raise exception '%', v_msg using errcode = '22023';
  end if;

  insert into public.checkout_evaluations(
    business_id, branch_id, client_id, server_lines, cart_hash, config_version_id, applied_effects,
    subtotal_cents, discount_total_cents, total_cents, gst_cents, gst_rate_bps, expires_at)
  values(
    p_business, v_branch, p_client, v_plan->'server_lines', v_plan->>'cart_hash', v_config,
    v_plan->'applied_effects', (v_plan->>'subtotal_cents')::int, (v_plan->>'discount_total_cents')::int,
    (v_plan->>'total_cents')::int, (v_plan->>'gst_cents')::int, (v_plan->>'gst_rate_bps')::int,
    now() + interval '10 minutes')
  returning id into v_eval_id;

  insert into public.checkout_evaluation_operations(business_id, actor, idempotency_key, request_hash, evaluation_id)
  values(p_business, v_actor, p_idempotency_key, v_hash, v_eval_id);

  return jsonb_build_object(
    'status', 'ok', 'replayed', false, 'evaluation_id', v_eval_id,
    'expires_at', now() + interval '10 minutes',
    'server_lines', v_plan->'server_lines', 'applied_effects', v_plan->'applied_effects',
    'subtotal_cents', (v_plan->>'subtotal_cents')::int, 'discount_total_cents', (v_plan->>'discount_total_cents')::int,
    'total_cents', (v_plan->>'total_cents')::int, 'gst_cents', (v_plan->>'gst_cents')::int,
    'stored_value', app.sv_evaluate_quote(p_business, p_client, (v_plan->>'total_cents')::int));
end $function$;
revoke all on function public.evaluate_checkout(p_business uuid, p_branch uuid, p_client uuid, p_lines jsonb, p_idempotency_key uuid) from public;
revoke all on function public.evaluate_checkout(p_business uuid, p_branch uuid, p_client uuid, p_lines jsonb, p_idempotency_key uuid) from postgres;
grant execute on function public.evaluate_checkout(p_business uuid, p_branch uuid, p_client uuid, p_lines jsonb, p_idempotency_key uuid) to postgres;
revoke all on function public.evaluate_checkout(p_business uuid, p_branch uuid, p_client uuid, p_lines jsonb, p_idempotency_key uuid) from service_role;
grant execute on function public.evaluate_checkout(p_business uuid, p_branch uuid, p_client uuid, p_lines jsonb, p_idempotency_key uuid) to service_role;
revoke all on function public.evaluate_checkout(p_business uuid, p_branch uuid, p_client uuid, p_lines jsonb, p_idempotency_key uuid) from authenticated;
grant execute on function public.evaluate_checkout(p_business uuid, p_branch uuid, p_client uuid, p_lines jsonb, p_idempotency_key uuid) to authenticated;

CREATE OR REPLACE FUNCTION public.get_customer_intelligence_export_page_v83(p_export uuid, p_after_ordinal integer DEFAULT 0, p_limit integer DEFAULT 500)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'app', 'pg_temp'
AS $function$
declare
  v_actor uuid:=auth.uid();
  v_export public.customer_intelligence_exports_v83%rowtype;
  v_result jsonb;
begin
  if p_after_ordinal is null or p_after_ordinal<0 then
    raise exception 'after_ordinal_must_be_nonnegative' using errcode='22023';
  end if;
  if p_limit is null or p_limit<1 or p_limit>500 then
    raise exception 'limit_must_be_between_1_and_500' using errcode='22023';
  end if;
  select * into v_export
  from public.customer_intelligence_exports_v83 export
  where export.id=p_export and export.requested_by=v_actor;
  if not found then
    raise exception 'export_not_found' using errcode='22023';
  end if;
  if v_export.expires_at<=clock_timestamp() then
    raise exception 'export_expired' using errcode='22023';
  end if;
  if not app.has_perm(v_export.business_id,'view_finance')
     or not app.can_module(v_export.business_id,'customerintel')
     or not app.can_see_branch(v_export.business_id,v_export.branch_id) then
    raise exception 'export_scope_no_longer_permitted' using errcode='42501';
  end if;

  with page as materialized (
    select row.ordinal,row.payload
    from public.customer_intelligence_export_rows_v83 row
    where row.export_id=p_export and row.ordinal>p_after_ordinal
    order by row.ordinal limit p_limit
  )
  select jsonb_build_object(
    'export_id',v_export.id,'snapshot_at',v_export.snapshot_at,
    'expires_at',v_export.expires_at,'scope',v_export.scope,
    'methodology',v_export.methodology,'data_quality',v_export.data_quality,
    'summary',v_export.summary,'forecast',v_export.forecast,
    'customers',coalesce((
      select jsonb_agg(payload order by ordinal) from page
    ),'[]'::jsonb),
    'pagination',jsonb_build_object(
      'limit',p_limit,'total_customers',v_export.total_customers,
      'returned_customers',(select count(*) from page),
      'has_more',coalesce((select max(ordinal) from page),p_after_ordinal)
        <v_export.total_customers,
      'next_ordinal',case
        when coalesce((select max(ordinal) from page),p_after_ordinal)
          <v_export.total_customers
        then (select max(ordinal) from page) else null end
    )
  ) into v_result;
  return v_result;
end
$function$;
revoke all on function public.get_customer_intelligence_export_page_v83(p_export uuid, p_after_ordinal integer, p_limit integer) from public;
revoke all on function public.get_customer_intelligence_export_page_v83(p_export uuid, p_after_ordinal integer, p_limit integer) from postgres;
grant execute on function public.get_customer_intelligence_export_page_v83(p_export uuid, p_after_ordinal integer, p_limit integer) to postgres;
revoke all on function public.get_customer_intelligence_export_page_v83(p_export uuid, p_after_ordinal integer, p_limit integer) from service_role;
grant execute on function public.get_customer_intelligence_export_page_v83(p_export uuid, p_after_ordinal integer, p_limit integer) to service_role;
revoke all on function public.get_customer_intelligence_export_page_v83(p_export uuid, p_after_ordinal integer, p_limit integer) from authenticated;
grant execute on function public.get_customer_intelligence_export_page_v83(p_export uuid, p_after_ordinal integer, p_limit integer) to authenticated;

CREATE OR REPLACE FUNCTION public.get_customer_intelligence_v83(p_business uuid, p_branch uuid DEFAULT NULL::uuid, p_from date DEFAULT (((now() AT TIME ZONE 'Asia/Singapore'::text))::date - 365), p_to date DEFAULT ((now() AT TIME ZONE 'Asia/Singapore'::text))::date, p_limit integer DEFAULT 250, p_snapshot_at timestamp with time zone DEFAULT NULL::timestamp with time zone, p_after_created_at timestamp with time zone DEFAULT NULL::timestamp with time zone, p_after_client uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'app', 'pg_temp'
AS $function$
declare
  v_from_ts timestamptz;
  v_to_ts timestamptz;
  v_snapshot_at timestamptz := coalesce(p_snapshot_at,clock_timestamp());
  v_forecast_end_date date;
  v_forecast_start_date date;
  v_result jsonb;
  v_history_days integer := 0;
  v_active_weeks integer := 0;
  v_completed_transactions integer := 0;
  v_cash_observation_weeks integer := 0;
  v_forecast_eligible boolean;
  v_unmet jsonb := '[]'::jsonb;
  v_weekly_average numeric := 0;
  v_weekly_lower numeric := 0;
  v_weekly_upper numeric := 0;
  v_forecast jsonb;
begin
  if p_business is null then
    raise exception 'business_required' using errcode='22023';
  end if;
  if not app.has_perm(p_business,'view_finance')
     or not app.can_module(p_business,'customerintel') then
    raise exception 'view_finance_required' using errcode='42501';
  end if;
  if p_from is null or p_to is null or p_from>p_to then
    raise exception 'invalid_report_window' using errcode='22023';
  end if;
  if p_to-p_from>1826 then
    raise exception 'report_window_exceeds_five_years' using errcode='22023';
  end if;
  if p_limit is null or p_limit<1 or p_limit>500 then
    raise exception 'limit_must_be_between_1_and_500' using errcode='22023';
  end if;
  if (p_after_created_at is null)<>(p_after_client is null) then
    raise exception 'complete_customer_cursor_required' using errcode='22023';
  end if;
  if p_snapshot_at is not null and p_snapshot_at>clock_timestamp()+interval '1 minute' then
    raise exception 'snapshot_cannot_be_in_the_future' using errcode='22023';
  end if;
  if p_branch is not null and not exists(
    select 1 from public.branches branch
    where branch.id=p_branch and branch.business_id=p_business
  ) then
    raise exception 'branch_not_in_business' using errcode='22023';
  end if;
  if not app.can_see_branch(p_business,p_branch) then
    raise exception 'branch_visibility_required' using errcode='42501';
  end if;

  v_from_ts:=p_from::timestamp at time zone 'Asia/Singapore';
  v_to_ts:=(p_to+1)::timestamp at time zone 'Asia/Singapore';
  -- Sunday is a complete Singapore ISO week; every other p_to excludes its
  -- partial week and anchors on that week's Monday.
  v_forecast_end_date:=case
    when extract(isodow from p_to)::integer=7 then p_to+1
    else p_to-(extract(isodow from p_to)::integer-1)
  end;
  v_forecast_start_date:=v_forecast_end_date-91;

  select coalesce(
    (v_forecast_end_date-1)
      - min((sale.occurred_at at time zone 'Asia/Singapore')::date),0
  )::integer
  into v_history_days
  from public.sales sale
  where sale.business_id=p_business
    and sale.created_at<=v_snapshot_at
    and sale.reversal_of is null
    and sale.amount_cents>0
    and sale.counts_as_revenue
    and sale.occurred_at
      < v_forecast_end_date::timestamp at time zone 'Asia/Singapore'
    and (p_branch is null or sale.branch_id=p_branch)
    and not exists(
      select 1 from public.sales reversal
      where reversal.business_id=sale.business_id
        and reversal.reversal_of=sale.id
        and reversal.created_at<=v_snapshot_at
        and reversal.occurred_at
          < v_forecast_end_date::timestamp at time zone 'Asia/Singapore'
    );

  select count(distinct date_trunc(
           'week',sale.occurred_at at time zone 'Asia/Singapore'
         ))::integer,
         count(*)::integer
  into v_active_weeks,v_completed_transactions
  from public.sales sale
  where sale.business_id=p_business
    and sale.created_at<=v_snapshot_at
    and sale.reversal_of is null
    and sale.amount_cents>0
    and sale.counts_as_revenue
    and sale.occurred_at
      >= v_forecast_start_date::timestamp at time zone 'Asia/Singapore'
    and sale.occurred_at
      < v_forecast_end_date::timestamp at time zone 'Asia/Singapore'
    and (p_branch is null or sale.branch_id=p_branch)
    and not exists(
      select 1 from public.sales reversal
      where reversal.business_id=sale.business_id
        and reversal.reversal_of=sale.id
        and reversal.created_at<=v_snapshot_at
        and reversal.occurred_at
          < v_forecast_end_date::timestamp at time zone 'Asia/Singapore'
    );

  with week_series as (
    select week_start::date
    from generate_series(
      v_forecast_start_date,
      v_forecast_end_date-7,
      interval '1 week'
    ) week_start
  ),weekly as (
    select week.week_start,
           coalesce(sum(payment.amount_cents) filter(
             where payment.method not in ('credit','gift_card')
           ),0)::numeric cash_cents,
           count(payment.id) filter(
             where payment.method not in ('credit','gift_card')
           )::integer payment_count
    from week_series week
    left join public.payments payment
      on payment.business_id=p_business
     and payment.created_at<=v_snapshot_at
     and payment.occurred_at
       >= week.week_start::timestamp at time zone 'Asia/Singapore'
     and payment.occurred_at
       < (week.week_start+7)::timestamp at time zone 'Asia/Singapore'
     and (p_branch is null or payment.branch_id=p_branch)
    group by week.week_start
  )
  select coalesce(avg(cash_cents),0),
         coalesce(percentile_cont(0.20) within group(order by cash_cents),0),
         coalesce(percentile_cont(0.80) within group(order by cash_cents),0),
         count(*) filter(where payment_count>0)::integer
  into v_weekly_average,v_weekly_lower,v_weekly_upper,v_cash_observation_weeks
  from weekly;

  if v_history_days<90 then
    v_unmet:=v_unmet||jsonb_build_array(jsonb_build_object(
      'key','history_days','actual',v_history_days,'required',90
    ));
  end if;
  if v_active_weeks<12 then
    v_unmet:=v_unmet||jsonb_build_array(jsonb_build_object(
      'key','active_weeks','actual',v_active_weeks,'required',12
    ));
  end if;
  if v_completed_transactions<30 then
    v_unmet:=v_unmet||jsonb_build_array(jsonb_build_object(
      'key','completed_transactions','actual',v_completed_transactions,'required',30
    ));
  end if;
  if v_cash_observation_weeks<8 then
    v_unmet:=v_unmet||jsonb_build_array(jsonb_build_object(
      'key','cash_observation_weeks','actual',v_cash_observation_weeks,'required',8
    ));
  end if;
  v_forecast_eligible:=jsonb_array_length(v_unmet)=0;

  if v_forecast_eligible then
    select jsonb_build_object(
      'status','available',
      'method','trailing_13_complete_singapore_calendar_weeks_p20_mean_p80',
      'data_valid_through',p_to,
      'observation_start',v_forecast_start_date,
      'observation_end_exclusive',v_forecast_end_date,
      'complete_weeks',13,
      'partial_report_end_week_excluded',
        extract(isodow from p_to)::integer<>7,
      'weekly_average_cents',round(v_weekly_average)::bigint,
      'weekly_lower_cents',round(v_weekly_lower)::bigint,
      'weekly_upper_cents',round(v_weekly_upper)::bigint,
      'next_90_days',jsonb_build_object(
        'lower_cents',greatest(0,round(v_weekly_lower*90/7))::bigint,
        'expected_cents',greatest(0,round(v_weekly_average*90/7))::bigint,
        'upper_cents',greatest(0,round(v_weekly_upper*90/7))::bigint
      ),
      'months',(
        select jsonb_agg(jsonb_build_object(
          'month_index',month_index,
          'from',month_start,
          'to',month_end,
          'lower_cents',greatest(0,round(
            v_weekly_lower*((month_end-month_start)+1)/7
          ))::bigint,
          'expected_cents',greatest(0,round(
            v_weekly_average*((month_end-month_start)+1)/7
          ))::bigint,
          'upper_cents',greatest(0,round(
            v_weekly_upper*((month_end-month_start)+1)/7
          ))::bigint
        ) order by month_index)
        from (
          select month_index,
                 (p_to+1+make_interval(months=>month_index-1))::date month_start,
                 (p_to+make_interval(months=>month_index))::date month_end
          from generate_series(1,3) month_index
        ) windows
      ),
      'caution','Observed 20th percentile, mean and 80th percentile from 13 complete Singapore calendar weeks; this operating range is not a guarantee.'
    ) into v_forecast;
  else
    v_forecast:=jsonb_build_object(
      'status','insufficient_data',
      'data_valid_through',p_to,
      'observation_start',v_forecast_start_date,
      'observation_end_exclusive',v_forecast_end_date,
      'unmet_thresholds',v_unmet,
      'required_thresholds',jsonb_build_object(
        'history_days',90,'active_weeks',12,
        'completed_transactions',30,'cash_observation_weeks',8
      ),
      'message','A 3-month cash-collection range appears only after enough complete-week evidence exists.'
    );
  end if;

  with period_sales as materialized (
    select sale.*
    from public.sales sale
    where sale.business_id=p_business
      and sale.created_at<=v_snapshot_at
      and sale.occurred_at>=v_from_ts and sale.occurred_at<v_to_ts
      and (p_branch is null or sale.branch_id=p_branch)
  ),valid_period_purchases as materialized (
    select sale.*
    from period_sales sale
    where sale.reversal_of is null and sale.amount_cents>0
      and sale.counts_as_revenue
      and not exists(
        select 1 from public.sales reversal
        where reversal.business_id=sale.business_id
          and reversal.reversal_of=sale.id
          and reversal.created_at<=v_snapshot_at
          and reversal.occurred_at<v_to_ts
      )
  ),valid_period_visits as materialized (
    select sale.*
    from period_sales sale
    where sale.reversal_of is null and sale.amount_cents>0
      and sale.counts_as_visit
      and not exists(
        select 1 from public.sales reversal
        where reversal.business_id=sale.business_id
          and reversal.reversal_of=sale.id
          and reversal.created_at<=v_snapshot_at
          and reversal.occurred_at<v_to_ts
      )
  ),valid_lifetime_purchases as materialized (
    select sale.*
    from public.sales sale
    where sale.business_id=p_business
      and sale.created_at<=v_snapshot_at
      and sale.occurred_at<v_to_ts
      and (p_branch is null or sale.branch_id=p_branch)
      and sale.reversal_of is null and sale.amount_cents>0
      and sale.counts_as_revenue
      and not exists(
        select 1 from public.sales reversal
        where reversal.business_id=sale.business_id
          and reversal.reversal_of=sale.id
          and reversal.created_at<=v_snapshot_at
          and reversal.occurred_at<v_to_ts
      )
  ),period_revenue as (
    select sale.client_id,
           coalesce(sum(sale.amount_cents) filter(
             where sale.counts_as_revenue
           ),0)::bigint net_revenue_cents
    from period_sales sale where sale.client_id is not null
    group by sale.client_id
  ),period_purchases as (
    select sale.client_id,count(*)::integer purchase_count,
           min(sale.occurred_at) period_first_purchase_at,
           max(sale.occurred_at) period_last_purchase_at
    from valid_period_purchases sale where sale.client_id is not null
    group by sale.client_id
  ),period_visits as (
    select sale.client_id,count(*)::integer visit_count
    from valid_period_visits sale where sale.client_id is not null
    group by sale.client_id
  ),period_cash as (
    select coalesce(payment.client_id,sale.client_id) client_id,
           coalesce(sum(payment.amount_cents) filter(
             where payment.method not in ('credit','gift_card')
           ),0)::bigint cash_collected_cents
    from public.payments payment
    left join public.sales sale
      on sale.id=payment.sale_id and sale.business_id=payment.business_id
    where payment.business_id=p_business
      and payment.created_at<=v_snapshot_at
      and payment.occurred_at>=v_from_ts and payment.occurred_at<v_to_ts
      and (p_branch is null or payment.branch_id=p_branch)
      and coalesce(payment.client_id,sale.client_id) is not null
    group by coalesce(payment.client_id,sale.client_id)
  ),lifetime as (
    select sale.client_id,count(*)::integer lifetime_purchase_count,
           min(sale.occurred_at) first_purchase_at,
           max(sale.occurred_at) last_purchase_at,
           count(distinct sale.branch_id)::integer branches_visited,
           case when count(*)<2 then null else round(
             extract(epoch from(max(sale.occurred_at)-min(sale.occurred_at)))
             /86400/(count(*)-1),1
           ) end average_days_between_purchases
    from valid_lifetime_purchases sale where sale.client_id is not null
    group by sale.client_id
  ),client_metrics as materialized (
    select client.id client_id,client.full_name,client.email,client.phone,
           client.created_at customer_since,
           coalesce(revenue.net_revenue_cents,0)::bigint net_revenue_cents,
           coalesce(cash.cash_collected_cents,0)::bigint cash_collected_cents,
           coalesce(purchase.purchase_count,0)::integer purchase_count,
           coalesce(visit.visit_count,0)::integer visit_count,
           purchase.period_first_purchase_at,purchase.period_last_purchase_at,
           lifetime.first_purchase_at,lifetime.last_purchase_at,
           case when lifetime.last_purchase_at is null then null
             else p_to-(lifetime.last_purchase_at at time zone 'Asia/Singapore')::date
           end days_since_last_purchase,
           coalesce(lifetime.branches_visited,0)::integer branches_visited,
           coalesce(lifetime.lifetime_purchase_count,0)::integer lifetime_purchase_count,
           coalesce(purchase.purchase_count,0)>=2 returning_customer,
           case when coalesce(purchase.purchase_count,0)=0 then 0 else round(
             coalesce(revenue.net_revenue_cents,0)::numeric/purchase.purchase_count
           )::bigint end average_revenue_per_purchase_cents,
           lifetime.average_days_between_purchases
    from public.clients client
    left join period_revenue revenue on revenue.client_id=client.id
    left join period_purchases purchase on purchase.client_id=client.id
    left join period_visits visit on visit.client_id=client.id
    left join period_cash cash on cash.client_id=client.id
    left join lifetime on lifetime.client_id=client.id
    where client.business_id=p_business
      and client.created_at<=v_snapshot_at
      and (p_branch is null or lifetime.client_id is not null)
  ),page as materialized (
    select * from client_metrics customer
    where p_after_created_at is null
       or (customer.customer_since,customer.client_id)
          >(p_after_created_at,p_after_client)
    order by customer_since,client_id
    limit p_limit
  ),last_page as (
    select customer_since,client_id
    from page order by customer_since desc,client_id desc limit 1
  ),page_state as (
    select exists(
      select 1 from client_metrics customer,last_page last
      where (customer.customer_since,customer.client_id)
            >(last.customer_since,last.client_id)
    ) has_more
  )
  select jsonb_build_object(
    'generated_at',v_snapshot_at,
    'snapshot_at',v_snapshot_at,
    'scope',jsonb_build_object(
      'business_id',p_business,'business_name',business.name,
      'currency',business.currency,'branch_id',p_branch,'branch_name',branch.name,
      'from',p_from,'to',p_to,'timezone','Asia/Singapore'
    ),
    'methodology',jsonb_build_object(
      'period_metrics','Revenue, cash, active and returning metrics use p_from through p_to.',
      'lifetime_inactivity','Last purchase and inactivity use all valid purchases through p_to.',
      'revenue','Net immutable sales ledger events at the generated-at cutoff.',
      'cash_collected','External payment ledger less refunds; credit and gift-card tenders excluded.',
      'forecast','Thirteen complete Singapore calendar weeks; partial report-end week excluded; p20/mean/p80 range.',
      'returning_customer','At least two completed unreversed revenue transactions in the selected period.',
      'returning_rate_denominator','Active customers with at least one completed period purchase.',
      'pagination','Immutable customer_since/client_id keyset at one generated-at cutoff.'
    ),
    'data_quality',jsonb_build_object(
      'forecast_eligible',v_forecast_eligible,'history_days',v_history_days,
      'active_weeks',v_active_weeks,
      'completed_transactions',v_completed_transactions,
      'cash_observation_weeks',v_cash_observation_weeks,
      'required_thresholds',jsonb_build_object(
        'history_days',90,'active_weeks',12,
        'completed_transactions',30,'cash_observation_weeks',8
      ),'unmet_thresholds',v_unmet
    ),
    'summary',jsonb_build_object(
      'known_customers',(select count(*) from client_metrics),
      'active_customers',(select count(*) from client_metrics where purchase_count>0),
      'returning_customers',(select count(*) from client_metrics where returning_customer),
      'returning_rate_pct',(
        select case when count(*) filter(where purchase_count>0)=0 then 0
          else round(100.0*count(*) filter(where returning_customer)
            /count(*) filter(where purchase_count>0),1) end
        from client_metrics
      ),
      'net_revenue_cents',(select coalesce(sum(net_revenue_cents),0) from client_metrics),
      'cash_collected_cents',(select coalesce(sum(cash_collected_cents),0) from client_metrics),
      'average_revenue_per_active_customer_cents',(
        select case when count(*) filter(where purchase_count>0)=0 then 0
          else round(sum(net_revenue_cents)::numeric
            /count(*) filter(where purchase_count>0))::bigint end
        from client_metrics
      ),
      'average_purchase_frequency_days',(
        select round(avg(average_days_between_purchases),1)
        from client_metrics where average_days_between_purchases is not null
      ),
      'customers_over_90_days_inactive',(
        select count(*) from client_metrics where days_since_last_purchase>90
      )
    ),
    'forecast',v_forecast,
    'customers',coalesce((
      select jsonb_agg(to_jsonb(customer) order by customer_since,client_id)
      from page customer
    ),'[]'::jsonb),
    'pagination',jsonb_build_object(
      'limit',p_limit,'total_customers',(select count(*) from client_metrics),
      'returned_customers',(select count(*) from page),
      'has_more',coalesce((select has_more from page_state),false),
      'next_cursor',case
        when coalesce((select has_more from page_state),false) then (
          select jsonb_build_object(
            'customer_since',customer_since,'client_id',client_id
          ) from last_page
        ) else null end
    )
  ) into v_result
  from public.businesses business
  left join public.branches branch
    on branch.id=p_branch and branch.business_id=business.id
  where business.id=p_business;

  if v_result is null then
    raise exception 'business_not_found' using errcode='22023';
  end if;
  return v_result;
end
$function$;
revoke all on function public.get_customer_intelligence_v83(p_business uuid, p_branch uuid, p_from date, p_to date, p_limit integer, p_snapshot_at timestamp with time zone, p_after_created_at timestamp with time zone, p_after_client uuid) from public;
revoke all on function public.get_customer_intelligence_v83(p_business uuid, p_branch uuid, p_from date, p_to date, p_limit integer, p_snapshot_at timestamp with time zone, p_after_created_at timestamp with time zone, p_after_client uuid) from postgres;
grant execute on function public.get_customer_intelligence_v83(p_business uuid, p_branch uuid, p_from date, p_to date, p_limit integer, p_snapshot_at timestamp with time zone, p_after_created_at timestamp with time zone, p_after_client uuid) to postgres;
revoke all on function public.get_customer_intelligence_v83(p_business uuid, p_branch uuid, p_from date, p_to date, p_limit integer, p_snapshot_at timestamp with time zone, p_after_created_at timestamp with time zone, p_after_client uuid) from service_role;
grant execute on function public.get_customer_intelligence_v83(p_business uuid, p_branch uuid, p_from date, p_to date, p_limit integer, p_snapshot_at timestamp with time zone, p_after_created_at timestamp with time zone, p_after_client uuid) to service_role;
revoke all on function public.get_customer_intelligence_v83(p_business uuid, p_branch uuid, p_from date, p_to date, p_limit integer, p_snapshot_at timestamp with time zone, p_after_created_at timestamp with time zone, p_after_client uuid) from authenticated;
grant execute on function public.get_customer_intelligence_v83(p_business uuid, p_branch uuid, p_from date, p_to date, p_limit integer, p_snapshot_at timestamp with time zone, p_after_created_at timestamp with time zone, p_after_client uuid) to authenticated;

CREATE OR REPLACE FUNCTION public.get_dashboard_summary(p_business uuid, p_from date, p_to date, p_branch uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'app', 'pg_temp'
AS $function$
declare
  v_kpis jsonb;
  v_weekdays jsonb;
  v_revenue_by_day jsonb;
  v_gender jsonb;
  v_age jsonb;
  v_sales_available boolean;
  v_clients_available boolean;
  v_loyalty_available boolean;
  v_credit_liability_available boolean;
begin
  if auth.uid() is null
     or not app.has_perm(p_business, 'view_sales')
     or not app.can_module(p_business, 'dailyreport') then
    raise exception 'you do not have permission to view this dashboard'
      using errcode = '42501';
  end if;
  if p_from is null or p_to is null or p_from > p_to then
    raise exception 'a valid report date range is required'
      using errcode = '22007';
  end if;
  if p_to - p_from > 1826 then
    raise exception 'report date range cannot exceed 1827 days'
      using errcode = '22023';
  end if;
  if p_branch is not null and not exists (
    select 1 from public.branches b
    where b.id = p_branch and b.business_id = p_business
  ) then
    raise exception 'branch does not belong to this business'
      using errcode = '42501';
  end if;
  if not app.can_see_branch(p_business, p_branch) then
    raise exception 'you are not permitted to view this branch scope'
      using errcode = '42501';
  end if;

  v_sales_available := app.metric_module_scope_available_v145(
    p_business, p_branch, 'sales'
  );
  v_clients_available := app.metric_module_scope_available_v145(
    p_business, null, 'clients'
  );
  v_loyalty_available := app.metric_module_scope_available_v145(
    p_business, p_branch, 'loyalty'
  );
  v_credit_liability_available := app.metric_module_scope_available_v145(
    p_business, null, 'sales'
  );
  if not v_sales_available then
    return jsonb_build_object(
      'availability', jsonb_build_object(
        'sales', false,
        'clients', false,
        'loyalty', false,
        'credit_liability', false
      ),
      'scope', jsonb_build_object(
        'timezone', 'Asia/Singapore',
        'from', p_from,
        'to', p_to,
        'branch_id', p_branch,
        'status', 'unavailable_incomplete_sales_scope'
      )
    );
  end if;

  with scoped_sales as (
    select s.*
    from public.sales s
    where s.business_id = p_business
      and s.occurred_at >= (p_from::timestamp at time zone 'Asia/Singapore')
      and s.occurred_at < ((p_to + 1)::timestamp at time zone 'Asia/Singapore')
      and (p_branch is null or s.branch_id = p_branch)
  ), valid_visits as (
    select s.*
    from scoped_sales s
    where s.counts_as_visit
      and s.reversal_of is null
      and not exists (
        select 1
        from public.sales r
        where r.business_id = s.business_id
          and r.reversal_of = s.id
      )
  )
  select jsonb_build_object(
    'visits', (select count(*) from valid_visits),
    'revenue_cents', coalesce((select sum(s.amount_cents) from scoped_sales s where s.counts_as_revenue), 0),
    'unique_customers', (select count(distinct s.client_id) from valid_visits s where s.client_id is not null)
  )
  into v_kpis;

  v_kpis := v_kpis || jsonb_build_object(
    'new_customers', case when v_clients_available then (
      select count(*) from public.clients c
      where c.business_id = p_business
        and c.created_at >= (p_from::timestamp at time zone 'Asia/Singapore')
        and c.created_at < ((p_to + 1)::timestamp at time zone 'Asia/Singapore')
    ) else null end,
    'points_issued', case when v_loyalty_available then (
      select coalesce(sum(pl.points), 0)
      from public.points_ledger pl
      left join public.sales ps
        on ps.id = pl.sale_id
       and ps.business_id = pl.business_id
      where pl.business_id = p_business
        and pl.entry_type = 'earn'
        and pl.created_at >= (p_from::timestamp at time zone 'Asia/Singapore')
        and pl.created_at < ((p_to + 1)::timestamp at time zone 'Asia/Singapore')
        and (p_branch is null or ps.branch_id = p_branch)
    ) else null end,
    'credit_liability_cents', case when v_credit_liability_available then (
      select coalesce(sum(greatest(cb.balance_cents, 0)), 0)
      from public.client_credit_balance cb
      where cb.business_id = p_business
    ) else null end
  );

  with valid_visits as (
    select s.*
    from public.sales s
    where s.business_id = p_business
      and s.counts_as_visit
      and s.reversal_of is null
      and s.occurred_at >= (p_from::timestamp at time zone 'Asia/Singapore')
      and s.occurred_at < ((p_to + 1)::timestamp at time zone 'Asia/Singapore')
      and (p_branch is null or s.branch_id = p_branch)
      and not exists (
        select 1
        from public.sales r
        where r.business_id = s.business_id
          and r.reversal_of = s.id
      )
  )
  select coalesce(jsonb_agg(coalesce(w.visits, 0) order by d.day_no), '[]'::jsonb)
  into v_weekdays
  from generate_series(1, 7) d(day_no)
  left join (
    select extract(isodow from s.occurred_at at time zone 'Asia/Singapore')::int as day_no,
           count(*) as visits
    from valid_visits s
    group by 1
  ) w using (day_no);

  select coalesce(
    jsonb_agg(jsonb_build_object(
      'day', d.sale_day,
      'amount_cents', coalesce(r.amount_cents, 0)
    ) order by d.sale_day),
    '[]'::jsonb)
  into v_revenue_by_day
  from generate_series(p_from::timestamp, p_to::timestamp, interval '1 day') d0(day_value)
  cross join lateral (select d0.day_value::date as sale_day) d
  left join (
    select (s.occurred_at at time zone 'Asia/Singapore')::date as sale_day,
           sum(s.amount_cents) as amount_cents
    from public.sales s
    where s.business_id = p_business
      and s.counts_as_revenue
      and s.occurred_at >= (p_from::timestamp at time zone 'Asia/Singapore')
      and s.occurred_at < ((p_to + 1)::timestamp at time zone 'Asia/Singapore')
      and (p_branch is null or s.branch_id = p_branch)
    group by 1
  ) r using (sale_day);

  if v_clients_available then
  select jsonb_build_object(
    'female', count(*) filter (where c.gender = 'female'),
    'male', count(*) filter (where c.gender = 'male'),
    'other', count(*) filter (where c.gender = 'other'),
    'unknown', count(*) filter (where c.gender is null)
  )
  into v_gender
  from public.clients c
  where c.business_id = p_business;

  select jsonb_build_object(
    'under_25', count(*) filter (where c.birth_date is not null and extract(year from age((timezone('Asia/Singapore', now()))::date, c.birth_date)) < 25),
    'age_25_34', count(*) filter (where c.birth_date is not null and extract(year from age((timezone('Asia/Singapore', now()))::date, c.birth_date)) between 25 and 34),
    'age_35_44', count(*) filter (where c.birth_date is not null and extract(year from age((timezone('Asia/Singapore', now()))::date, c.birth_date)) between 35 and 44),
    'age_45_54', count(*) filter (where c.birth_date is not null and extract(year from age((timezone('Asia/Singapore', now()))::date, c.birth_date)) between 45 and 54),
    'age_55_plus', count(*) filter (where c.birth_date is not null and extract(year from age((timezone('Asia/Singapore', now()))::date, c.birth_date)) >= 55),
    'unknown', count(*) filter (where c.birth_date is null)
  )
  into v_age
  from public.clients c
  where c.business_id = p_business;
  else
    v_gender := null;
    v_age := null;
  end if;

  return v_kpis || jsonb_build_object(
    'visits_by_weekday', v_weekdays,
    'revenue_by_day', v_revenue_by_day,
    'gender_counts', v_gender,
    'age_counts', v_age,
    'availability', jsonb_build_object(
      'sales', true,
      'clients', v_clients_available,
      'loyalty', v_loyalty_available,
      'credit_liability', v_credit_liability_available
    ),
    'scope', jsonb_build_object(
      'timezone', 'Asia/Singapore',
      'from', p_from,
      'to', p_to,
      'branch_id', p_branch,
      'visits', 'selected_period_and_branch_valid_originals',
      'revenue', 'selected_period_and_branch_signed_ledger',
      'unique_customers', 'selected_period_and_branch_customer_records_with_valid_visits',
      'new_customers', case when v_clients_available then 'business_wide_records_added_in_selected_period' else 'unavailable_without_complete_clients_scope' end,
      'points_issued', case
        when not v_loyalty_available then 'unavailable_without_complete_loyalty_scope'
        when p_branch is null then 'business_wide_gross_earn_in_selected_period'
        else 'selected_branch_sale_linked_gross_earn_in_selected_period'
      end,
      'credit_liability', case when v_credit_liability_available
        then 'business_wide_current_signed_credit_ledger_with_complete_business_sales_read'
        else 'unavailable_without_complete_business_sales_scope' end,
      'age_counts', case when v_clients_available then 'business_wide_current' else 'unavailable_without_complete_clients_scope' end
    )
  );
end;
$function$;
revoke all on function public.get_dashboard_summary(p_business uuid, p_from date, p_to date, p_branch uuid) from public;
revoke all on function public.get_dashboard_summary(p_business uuid, p_from date, p_to date, p_branch uuid) from postgres;
grant execute on function public.get_dashboard_summary(p_business uuid, p_from date, p_to date, p_branch uuid) to postgres;
revoke all on function public.get_dashboard_summary(p_business uuid, p_from date, p_to date, p_branch uuid) from service_role;
grant execute on function public.get_dashboard_summary(p_business uuid, p_from date, p_to date, p_branch uuid) to service_role;
revoke all on function public.get_dashboard_summary(p_business uuid, p_from date, p_to date, p_branch uuid) from authenticated;
grant execute on function public.get_dashboard_summary(p_business uuid, p_from date, p_to date, p_branch uuid) to authenticated;

CREATE OR REPLACE FUNCTION public.get_effective_sector_policy_v109(p_business uuid, p_policy_key text DEFAULT 'lapse_detection'::text, p_as_of timestamp with time zone DEFAULT statement_timestamp())
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'app', 'pg_temp'
AS $function$
declare
  v_sector text;
  v_base public.sector_policy_versions_v109%rowtype;
  v_override public.business_sector_policy_overrides_v109%rowtype;
begin
  perform app.v109_require_feature();
  perform app.v109_require_finance_scope(p_business,null);
  if not app.can_module(p_business,'customerintel') then
    raise exception 'customerintel_module_required' using errcode='42501';
  end if;
  if p_as_of is null then
    raise exception 'as-of is required' using errcode='22023';
  end if;
  select lower(b.industry) into v_sector
  from public.businesses b where b.id=p_business;
  if v_sector is null then raise exception 'business not found';end if;
  select * into v_base
  from public.sector_policy_versions_v109 p
  where p.sector_key=v_sector and p.policy_key=p_policy_key
    and p.status='published' and p.effective_from<=p_as_of
    and (p.effective_to is null or p.effective_to>p_as_of)
  order by p.version_no desc limit 1;
  if not found then
    select * into v_base
    from public.sector_policy_versions_v109 p
    where p.sector_key='other' and p.policy_key=p_policy_key
      and p.status='published' and p.effective_from<=p_as_of
      and (p.effective_to is null or p.effective_to>p_as_of)
    order by p.version_no desc limit 1;
  end if;
  if not found then raise exception 'no effective sector policy';end if;
  select * into v_override
  from public.business_sector_policy_overrides_v109 o
  where o.business_id=p_business and o.policy_key=p_policy_key
    and o.base_policy_id=v_base.id and o.effective_from<=p_as_of
    and (o.effective_to is null or o.effective_to>p_as_of)
  order by o.version_no desc limit 1;
  return jsonb_build_object(
    'contract_version','effective_sector_policy_v109',
    'business_id',p_business,
    'requested_sector',v_sector,
    'resolved_sector',v_base.sector_key,
    'used_fallback_sector',v_base.sector_key<>v_sector,
    'policy_key',v_base.policy_key,
    'base_policy',jsonb_build_object(
      'id',v_base.id,'version_no',v_base.version_no,
      'effective_from',v_base.effective_from,'effective_to',v_base.effective_to,
      'evidence_basis',v_base.evidence_basis,'parameters',v_base.parameters,
      'fallback_policy',v_base.fallback_policy,
      'suppression_rules',v_base.suppression_rules,
      'limitations',v_base.limitations
    ),
    'owner_override',case when v_override.id is null then 'null'::jsonb
      else jsonb_build_object(
        'id',v_override.id,'version_no',v_override.version_no,
        'parameters',v_override.override_parameters,
        'reason',v_override.reason,'effective_from',v_override.effective_from,
        'effective_to',v_override.effective_to,'created_by',v_override.created_by
      ) end,
    'effective_parameters',v_base.parameters
      ||coalesce(v_override.override_parameters,'{}'::jsonb),
    'universal_churn_number',null,
    'requires_local_evidence',true
  );
end $function$;
revoke all on function public.get_effective_sector_policy_v109(p_business uuid, p_policy_key text, p_as_of timestamp with time zone) from public;
revoke all on function public.get_effective_sector_policy_v109(p_business uuid, p_policy_key text, p_as_of timestamp with time zone) from postgres;
grant execute on function public.get_effective_sector_policy_v109(p_business uuid, p_policy_key text, p_as_of timestamp with time zone) to postgres;
revoke all on function public.get_effective_sector_policy_v109(p_business uuid, p_policy_key text, p_as_of timestamp with time zone) from authenticated;
grant execute on function public.get_effective_sector_policy_v109(p_business uuid, p_policy_key text, p_as_of timestamp with time zone) to authenticated;
revoke all on function public.get_effective_sector_policy_v109(p_business uuid, p_policy_key text, p_as_of timestamp with time zone) from service_role;
grant execute on function public.get_effective_sector_policy_v109(p_business uuid, p_policy_key text, p_as_of timestamp with time zone) to service_role;

CREATE OR REPLACE FUNCTION public.get_period_economics_v109(p_business uuid, p_from date, p_to date, p_branch uuid DEFAULT NULL::uuid, p_investment_cents bigint DEFAULT NULL::bigint, p_investment_reference text DEFAULT NULL::text, p_as_of timestamp with time zone DEFAULT statement_timestamp())
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'app', 'pg_temp'
AS $function$
declare
  v_sales integer:=0;
  v_covered_sales integer:=0;
  v_sale_lines integer:=0;
  v_covered_sale_lines integer:=0;
  v_ambiguous_sale_lines integer:=0;
  v_revenue bigint:=0;
  v_covered_revenue bigint:=0;
  v_traceable_cogs bigint:=0;
  v_sale_transaction_coverage_bps integer;
  v_sale_revenue_coverage_bps integer;
  v_sale_coverage_passes boolean:=false;
  v_benefits integer:=0;
  v_covered_benefits integer:=0;
  v_benefit_value bigint:=0;
  v_covered_benefit_value bigint:=0;
  v_traceable_benefit_cost bigint:=0;
  v_benefit_coverage_bps integer;
  v_benefit_coverage_passes boolean:=true;
  v_deliveries integer:=0;
  v_covered_deliveries integer:=0;
  v_traceable_delivery_cost bigint:=0;
  v_delivery_coverage_bps integer;
  v_delivery_coverage_passes boolean:=true;
  v_coverage_passes boolean:=false;
  v_gross_profit bigint;
  v_contribution bigint;
  v_growth_investment bigint;
  v_total_investment bigint;
  v_net_return bigint;
  v_roi_bps bigint;
  v_unavailable jsonb:='[]'::jsonb;
  v_currency text;
  v_currency_count integer;
  v_extra_reference text;
begin
  perform app.v109_require_feature();
  perform app.v109_require_finance_scope(p_business,p_branch);
  if not app.can_module(p_business,'customerintel') then
    raise exception 'customerintel_module_required' using errcode='42501';
  end if;
  if p_from is null or p_to is null or p_from>=p_to or p_as_of is null then
    raise exception 'valid half-open local-date period and as-of are required'
      using errcode='22023';
  end if;
  if p_investment_cents is not null and p_investment_cents<0 then
    raise exception 'investment cannot be negative' using errcode='22023';
  end if;
  if p_investment_cents>0
     and length(btrim(coalesce(p_investment_reference,'')))<3 then
    raise exception 'positive additional investment requires a source reference'
      using errcode='22023';
  end if;
  if p_branch is not null and not exists (
    select 1 from public.branches branch_row
    where branch_row.id=p_branch and branch_row.business_id=p_business
  ) then
    raise exception 'branch does not belong to business' using errcode='22023';
  end if;

  select count(distinct contract.currency),min(contract.currency)
  into v_currency_count,v_currency
  from public.sales sale
  cross join lateral app.v106_reporting_contract(
    sale.business_id,sale.branch_id,sale.occurred_at
  ) contract
  where sale.business_id=p_business
    and (p_branch is null or sale.branch_id=p_branch)
    and sale.counts_as_revenue and sale.reversal_of is null
    and sale.created_at<=p_as_of
    and (sale.occurred_at at time zone contract.timezone)::date>=p_from
    and (sale.occurred_at at time zone contract.timezone)::date<p_to;
  if v_currency_count>1 then
    raise exception 'cross-currency reporting periods are not supported'
      using errcode='22023';
  end if;
  if v_currency_count=0 then
    select upper(currency) into strict v_currency
    from public.businesses where id=p_business;
  end if;

  with eligible as (
    select sale.*,contract.currency,
      app.v106_sale_residual_minor(
        sale.id,p_to,p_as_of
      ) as residual_cents
    from public.sales sale
    cross join lateral app.v106_reporting_contract(
      sale.business_id,sale.branch_id,sale.occurred_at
    ) contract
    where sale.business_id=p_business
      and (p_branch is null or sale.branch_id=p_branch)
      and sale.counts_as_revenue and sale.reversal_of is null
      and sale.created_at<=p_as_of
      and (sale.occurred_at at time zone contract.timezone)::date>=p_from
      and (sale.occurred_at at time zone contract.timezone)::date<p_to
      and app.v106_sale_residual_minor(sale.id,p_to,p_as_of)>0
  ), sale_shape as (
    select sale.*,
      exists(
        select 1 from public.sale_items item
        where item.business_id=p_business and item.sale_id=sale.id
      ) as is_itemized,
      coalesce((
        select sum(item.line_cents)
        from public.sale_items item
        where item.business_id=p_business and item.sale_id=sale.id
          and item.line_cents>0
      ),0)::bigint as positive_line_cents
    from eligible sale
  ), itemized_base as (
    select sale.id as sale_id,item.id as cost_line_key,
      sale.branch_id,sale.occurred_at,sale.currency,sale.kind as sale_kind,
      true as is_itemized,item.qty,item.line_cents as source_line_cents,
      case
        when item.item_type='retail' and item.product_id is not null
          then 'product'
        when item.item_type='service' and item.ref_id is not null
          then 'service'
        when item.item_type='package' and item.ref_id is not null
          then 'package'
        else null
      end as desired_scope_kind,
      case
        when item.item_type='retail' and item.product_id is not null
          then item.product_id::text
        when item.item_type in ('service','package') and item.ref_id is not null
          then item.ref_id::text
        else null
      end as desired_scope_key,
      sale.amount_cents as sale_original_cents,
      sale.residual_cents as sale_residual_cents,
      floor(
        sale.residual_cents::numeric*item.line_cents
        /sale.positive_line_cents
      )::bigint as allocated_base_cents,
      mod(
        sale.residual_cents::numeric*item.line_cents,
        sale.positive_line_cents
      ) as allocation_remainder
    from sale_shape sale
    join public.sale_items item
      on item.business_id=p_business and item.sale_id=sale.id
    where sale.is_itemized and sale.positive_line_cents>0
      and item.line_cents>0
  ), itemized_ranked as (
    select itemized_base.*,
      itemized_base.sale_residual_cents
        -sum(itemized_base.allocated_base_cents) over(
          partition by itemized_base.sale_id
        ) as remainder_to_assign,
      row_number() over(
        partition by itemized_base.sale_id
        order by itemized_base.allocation_remainder desc,
          itemized_base.cost_line_key
      ) as allocation_rank
    from itemized_base
  ), economic_lines as (
    select sale_id,cost_line_key,branch_id,occurred_at,currency,sale_kind,
      is_itemized,qty,source_line_cents,desired_scope_kind,desired_scope_key,
      sale_original_cents,sale_residual_cents,
      allocated_base_cents
        +case when allocation_rank<=remainder_to_assign then 1 else 0 end
        as allocated_cents
    from itemized_ranked
    union all
    -- An itemized parent with no positive economic line is never silently
    -- reclassified as a parent sale.  Keep one uncovered line so the report
    -- fails closed while still reconciling its full residual revenue.
    select sale.id,sale.id,sale.branch_id,sale.occurred_at,sale.currency,
      sale.kind,true,coalesce(sale.qty,1),greatest(sale.amount_cents,1),
      null::text,null::text,sale.amount_cents,sale.residual_cents,
      sale.residual_cents
    from sale_shape sale
    where sale.is_itemized and sale.positive_line_cents=0
    union all
    -- Sale-kind fallback exists only for genuinely non-itemized legacy rows.
    select sale.id,sale.id,sale.branch_id,sale.occurred_at,sale.currency,
      sale.kind,false,coalesce(sale.qty,1),greatest(sale.amount_cents,1),
      case when sale.product_id is not null then 'product' else 'sale_kind' end,
      case
        when sale.product_id is not null then sale.product_id::text
        else sale.kind
      end,
      sale.amount_cents,sale.residual_cents,
      sale.residual_cents
    from sale_shape sale
    where not sale.is_itemized
  ), candidate_pool as (
    select line.*,candidate.id as candidate_rule_id,
      candidate.cost_method,candidate.cost_value,
      candidate.effective_from,candidate.version_no,
      case
        when candidate.scope_kind=line.desired_scope_kind
          and candidate.scope_key=line.desired_scope_key then 0
        when not line.is_itemized and candidate.scope_kind='sale_kind'
          and candidate.scope_key=line.sale_kind then 1
        else 2
      end as scope_priority,
      case when candidate.branch_id=line.branch_id then 0 else 1 end
        as branch_priority
    from economic_lines line
    left join public.economic_cost_rules_v109 candidate
      on candidate.business_id=p_business
      and candidate.currency=line.currency
      and (candidate.branch_id is null or candidate.branch_id=line.branch_id)
      and candidate.effective_from<=line.occurred_at
      and (
        candidate.effective_to is null
        or candidate.effective_to>line.occurred_at
      )
      and (
        (
          candidate.scope_kind=line.desired_scope_kind
          and candidate.scope_key=line.desired_scope_key
        )
        or (
          not line.is_itemized
          and line.desired_scope_kind='product'
          and candidate.scope_kind='sale_kind'
          and candidate.scope_key=line.sale_kind
        )
      )
  ), ranked_candidates as (
    select candidate_pool.*,
      row_number() over(
        partition by sale_id,cost_line_key
        order by scope_priority,branch_priority,
          effective_from desc nulls last,version_no desc nulls last
      ) as selection_rank,
      count(candidate_rule_id) over(
        partition by sale_id,cost_line_key,scope_priority,branch_priority,
          effective_from
      ) as equal_precedence_rules
    from candidate_pool
  ), selected as (
    select *,
      candidate_rule_id is not null and equal_precedence_rules=1
        as is_covered,
      candidate_rule_id is not null and equal_precedence_rules>1
        as is_ambiguous,
      case
        when candidate_rule_id is null or equal_precedence_rules<>1 then null
        when cost_method='revenue_bps' then
          round(allocated_cents*cost_value::numeric/10000)::bigint
        when cost_method='fixed_per_unit' then
          round(
            cost_value*qty*sale_residual_cents::numeric
            /greatest(sale_original_cents,1)
          )::bigint
        else null
      end as cost_cents
    from ranked_candidates
    where selection_rank=1
  ), sale_summary as (
    select sale_id,count(*)::integer as eligible_lines,
      count(*) filter(where is_covered)::integer as covered_lines,
      count(*) filter(where is_ambiguous)::integer as ambiguous_lines,
      sum(allocated_cents)::bigint as revenue_cents,
      coalesce(sum(allocated_cents) filter(where is_covered),0)::bigint
        as covered_revenue_cents,
      coalesce(sum(cost_cents) filter(where is_covered),0)::bigint
        as cost_cents
    from selected
    group by sale_id
  )
  select count(*)::integer,
    count(*) filter(
      where covered_lines=eligible_lines and ambiguous_lines=0
    )::integer,
    coalesce(sum(eligible_lines),0)::integer,
    coalesce(sum(covered_lines),0)::integer,
    coalesce(sum(ambiguous_lines),0)::integer,
    coalesce(sum(revenue_cents),0)::bigint,
    coalesce(sum(covered_revenue_cents),0)::bigint,
    coalesce(sum(cost_cents),0)::bigint
  into v_sales,v_covered_sales,v_sale_lines,v_covered_sale_lines,
    v_ambiguous_sale_lines,v_revenue,v_covered_revenue,v_traceable_cogs
  from sale_summary;

  with eligible as (
    select entitlement.id,entitlement.value_cents,
      entitlement.entitlement_type,entitlement.redeemed_at,
      execution_row.branch_id,contract.currency
    from public.growth_entitlements_v108 entitlement
    join public.growth_executions_v108 execution_row
      on execution_row.id=entitlement.execution_id
      and execution_row.business_id=entitlement.business_id
    cross join lateral app.v106_reporting_contract(
      entitlement.business_id,execution_row.branch_id,entitlement.redeemed_at
    ) contract
    left join lateral (
      select event_row.sale_id,reversal_sale.occurred_at
      from public.growth_entitlement_events_v108 event_row
      join public.sales reversal_sale
        on reversal_sale.id=event_row.sale_id
        and reversal_sale.business_id=event_row.business_id
      where event_row.entitlement_id=entitlement.id
        and event_row.business_id=entitlement.business_id
        and event_row.event_type='reversed'
        and event_row.created_at<=p_as_of
        and reversal_sale.created_at<=p_as_of
        and reversal_sale.reversal_of=entitlement.redeemed_sale_id
      order by event_row.created_at desc,event_row.id desc
      limit 1
    ) reversal_evidence on true
    left join lateral app.v106_reporting_contract(
      entitlement.business_id,execution_row.branch_id,
      reversal_evidence.occurred_at
    ) reversal_contract on reversal_evidence.sale_id is not null
    where entitlement.business_id=p_business
      and (p_branch is null or execution_row.branch_id=p_branch)
      and entitlement.redeemed_at is not null
      and entitlement.redeemed_at<=p_as_of
      and (
        entitlement.reversed_at is null
        or entitlement.reversed_at>p_as_of
        or (
          entitlement.reversed_at<=p_as_of
          and reversal_evidence.sale_id is not null
          and (
            reversal_evidence.occurred_at
              at time zone reversal_contract.timezone
          )::date>=p_to
        )
      )
      and (
        entitlement.redeemed_at at time zone contract.timezone
      )::date>=p_from
      and (
        entitlement.redeemed_at at time zone contract.timezone
      )::date<p_to
  ), matched as (
    select benefit.id,benefit.value_cents,rule_row.id as rule_id,
      case
        when rule_row.cost_method='value_bps' then
          round(
            benefit.value_cents*rule_row.cost_value::numeric/10000
          )::bigint
        when rule_row.cost_method='fixed_per_event' then rule_row.cost_value
        else null
      end as cost_cents
    from eligible benefit
    left join lateral (
      select candidate.*
      from public.growth_cost_rules_v114 candidate
      where candidate.business_id=p_business
        and candidate.cost_class='benefit'
        and candidate.scope_key=benefit.entitlement_type
        and candidate.currency=benefit.currency
        and (
          candidate.branch_id is null
          or candidate.branch_id=benefit.branch_id
        )
        and candidate.effective_from<=benefit.redeemed_at
        and (
          candidate.effective_to is null
          or candidate.effective_to>benefit.redeemed_at
        )
      order by
        case when candidate.branch_id=benefit.branch_id then 0 else 1 end,
        candidate.effective_from desc,candidate.version_no desc
      limit 1
    ) rule_row on true
  )
  select count(*),count(*) filter(where rule_id is not null),
    coalesce(sum(value_cents),0),
    coalesce(sum(value_cents) filter(where rule_id is not null),0),
    coalesce(sum(cost_cents) filter(where rule_id is not null),0)
  into v_benefits,v_covered_benefits,v_benefit_value,
    v_covered_benefit_value,v_traceable_benefit_cost
  from matched;

  with eligible as (
    select dispatch.id,dispatch.branch_id,dispatch.provider,
      dispatch.delivered_at,contract.currency
    from public.growth_delivery_dispatches_v110 dispatch
    cross join lateral app.v106_reporting_contract(
      dispatch.business_id,dispatch.branch_id,dispatch.delivered_at
    ) contract
    where dispatch.business_id=p_business
      and (p_branch is null or dispatch.branch_id=p_branch)
      and dispatch.delivered_at is not null
      and dispatch.delivered_at<=p_as_of
      and (
        dispatch.delivered_at at time zone contract.timezone
      )::date>=p_from
      and (
        dispatch.delivered_at at time zone contract.timezone
      )::date<p_to
  ), matched as (
    select delivery.id,rule_row.id as rule_id,
      rule_row.cost_value as cost_cents
    from eligible delivery
    left join lateral (
      select candidate.*
      from public.growth_cost_rules_v114 candidate
      where candidate.business_id=p_business
        and candidate.cost_class='delivery'
        and candidate.scope_key=delivery.provider
        and candidate.currency=delivery.currency
        and (
          candidate.branch_id is null
          or candidate.branch_id=delivery.branch_id
        )
        and candidate.effective_from<=delivery.delivered_at
        and (
          candidate.effective_to is null
          or candidate.effective_to>delivery.delivered_at
        )
      order by
        case when candidate.branch_id=delivery.branch_id then 0 else 1 end,
        candidate.effective_from desc,candidate.version_no desc
      limit 1
    ) rule_row on true
  )
  select count(*),count(*) filter(where rule_id is not null),
    coalesce(sum(cost_cents) filter(where rule_id is not null),0)
  into v_deliveries,v_covered_deliveries,v_traceable_delivery_cost
  from matched;

  v_sale_transaction_coverage_bps:=case
    when v_sales=0 then null
    else round(v_covered_sales*10000.0/v_sales)::integer
  end;
  v_sale_revenue_coverage_bps:=case
    when v_revenue=0 then null
    else round(v_covered_revenue*10000.0/v_revenue)::integer
  end;
  v_sale_coverage_passes:=v_sales>0
    and v_sale_lines>0
    and v_covered_sales=v_sales
    and v_covered_sale_lines=v_sale_lines
    and v_ambiguous_sale_lines=0
    and v_covered_revenue=v_revenue;
  v_benefit_coverage_bps:=case
    when v_benefits=0 then null
    else round(v_covered_benefits*10000.0/v_benefits)::integer
  end;
  v_benefit_coverage_passes:=v_benefits=0
    or v_covered_benefits=v_benefits;
  v_delivery_coverage_bps:=case
    when v_deliveries=0 then null
    else round(v_covered_deliveries*10000.0/v_deliveries)::integer
  end;
  v_delivery_coverage_passes:=v_deliveries=0
    or v_covered_deliveries=v_deliveries;
  v_coverage_passes:=v_sale_coverage_passes
    and v_benefit_coverage_passes and v_delivery_coverage_passes;

  if v_sales=0 then
    v_unavailable:=v_unavailable||jsonb_build_array('no_eligible_sales');
  elsif not v_sale_coverage_passes then
    v_unavailable:=v_unavailable
      ||jsonb_build_array('incomplete_traceable_sale_cost_coverage');
  end if;
  if v_ambiguous_sale_lines>0 then
    v_unavailable:=v_unavailable
      ||jsonb_build_array('ambiguous_traceable_sale_cost_rules');
  end if;
  if not v_benefit_coverage_passes then
    v_unavailable:=v_unavailable
      ||jsonb_build_array('incomplete_traceable_benefit_cost_coverage');
  end if;
  if not v_delivery_coverage_passes then
    v_unavailable:=v_unavailable
      ||jsonb_build_array('incomplete_traceable_delivery_cost_coverage');
  end if;

  if v_coverage_passes then
    v_gross_profit:=v_revenue-v_traceable_cogs;
    v_contribution:=v_gross_profit-v_traceable_benefit_cost
      -v_traceable_delivery_cost;
    v_growth_investment:=v_traceable_benefit_cost+v_traceable_delivery_cost;
    v_total_investment:=v_growth_investment+coalesce(p_investment_cents,0);
    if v_total_investment>0 then
      v_net_return:=v_contribution-coalesce(p_investment_cents,0);
      v_roi_bps:=round(v_net_return*10000.0/v_total_investment);
    else
      v_unavailable:=v_unavailable
        ||jsonb_build_array('positive_traceable_investment_required');
    end if;
  end if;
  v_extra_reference:=nullif(btrim(coalesce(p_investment_reference,'')),'');

  return jsonb_build_object(
    'contract_version','period_economics_v109',
    'cost_contract_version','growth_costs_v114',
    'business_id',p_business,'as_of',p_as_of,
    'period',jsonb_build_object(
      'from',p_from,'to',p_to,'basis','business_local_date'
    ),
    'status',case
      when v_sales=0 then 'no_data'
      when v_coverage_passes then 'ready'
      else 'insufficient_cost_coverage'
    end,
    'coverage',jsonb_build_object(
      'cost_contract_version','growth_costs_v114',
      'eligible_sales',v_sales,'covered_sales',v_covered_sales,
      'eligible_sale_lines',v_sale_lines,
      'covered_sale_lines',v_covered_sale_lines,
      'ambiguous_sale_lines',v_ambiguous_sale_lines,
      'transaction_coverage_bps',v_sale_transaction_coverage_bps,
      'eligible_revenue_cents',v_revenue,
      'covered_revenue_cents',v_covered_revenue,
      'revenue_coverage_bps',v_sale_revenue_coverage_bps,
      'sale_cost_coverage_passes',v_sale_coverage_passes,
      'eligible_redeemed_benefits',v_benefits,
      'covered_redeemed_benefits',v_covered_benefits,
      'eligible_redeemed_benefit_value_cents',v_benefit_value,
      'covered_redeemed_benefit_value_cents',v_covered_benefit_value,
      'benefit_cost_coverage_bps',v_benefit_coverage_bps,
      'benefit_cost_coverage_passes',v_benefit_coverage_passes,
      'eligible_deliveries',v_deliveries,
      'covered_deliveries',v_covered_deliveries,
      'delivery_cost_coverage_bps',v_delivery_coverage_bps,
      'delivery_cost_coverage_passes',v_delivery_coverage_passes,
      'traceable_cost_coverage_passes',v_coverage_passes
    ),
    'profit',case when v_coverage_passes then jsonb_build_object(
      'currency',v_currency,'revenue_cents',v_revenue,
      'traceable_cogs_cents',v_traceable_cogs,
      'gross_profit_before_growth_costs_cents',v_gross_profit,
      'traceable_benefit_cost_cents',v_traceable_benefit_cost,
      'traceable_delivery_cost_cents',v_traceable_delivery_cost,
      'traceable_growth_cost_cents',
        v_traceable_benefit_cost+v_traceable_delivery_cost,
      'total_traceable_cost_cents',
        v_traceable_cogs+v_traceable_benefit_cost+v_traceable_delivery_cost,
      'contribution_after_growth_costs_cents',v_contribution,
      -- Compatibility alias: this is gross profit before growth costs.
      'gross_profit_cents',v_gross_profit
    ) else 'null'::jsonb end,
    'roi',case when v_roi_bps is not null then jsonb_build_object(
      'investment_cents',v_total_investment,
      'traceable_growth_investment_cents',v_growth_investment,
      'additional_investment_cents',coalesce(p_investment_cents,0),
      'investment_reference',case
        when v_extra_reference is null then 'v114 traceable benefit and delivery cost rules'
        else 'v114 traceable growth costs + '||v_extra_reference
      end,
      'additional_investment_reference',v_extra_reference,
      'net_return_cents',v_net_return,
      'return_on_investment_bps',v_roi_bps
    ) else 'null'::jsonb end,
    'unavailable_reasons',v_unavailable,
    'limitations',jsonb_build_array(
      'profit and contribution are returned only at complete sale-line, redeemed-benefit and delivery cost coverage',
      'itemized sale residuals, including in-period refunds, are allocated proportionally with deterministic largest-remainder rounding',
      'fixed unit costs preserve full unit COGS across checkout discounts and are reduced only by the sale refund survival ratio',
      'benefit reversals use the recorded reversal sale business date rather than the entitlement wall-clock update time',
      'sale-kind cost fallback is used only for genuinely non-itemized legacy sales',
      'ROI uses traceable redeemed-benefit and delivered-provider costs plus any separately sourced additional investment',
      'this period result is descriptive and is not a causal increment claim'
    )
  );
end $function$;
revoke all on function public.get_period_economics_v109(p_business uuid, p_from date, p_to date, p_branch uuid, p_investment_cents bigint, p_investment_reference text, p_as_of timestamp with time zone) from public;
revoke all on function public.get_period_economics_v109(p_business uuid, p_from date, p_to date, p_branch uuid, p_investment_cents bigint, p_investment_reference text, p_as_of timestamp with time zone) from postgres;
grant execute on function public.get_period_economics_v109(p_business uuid, p_from date, p_to date, p_branch uuid, p_investment_cents bigint, p_investment_reference text, p_as_of timestamp with time zone) to postgres;
revoke all on function public.get_period_economics_v109(p_business uuid, p_from date, p_to date, p_branch uuid, p_investment_cents bigint, p_investment_reference text, p_as_of timestamp with time zone) from authenticated;
grant execute on function public.get_period_economics_v109(p_business uuid, p_from date, p_to date, p_branch uuid, p_investment_cents bigint, p_investment_reference text, p_as_of timestamp with time zone) to authenticated;
revoke all on function public.get_period_economics_v109(p_business uuid, p_from date, p_to date, p_branch uuid, p_investment_cents bigint, p_investment_reference text, p_as_of timestamp with time zone) from service_role;
grant execute on function public.get_period_economics_v109(p_business uuid, p_from date, p_to date, p_branch uuid, p_investment_cents bigint, p_investment_reference text, p_as_of timestamp with time zone) to service_role;

CREATE OR REPLACE FUNCTION public.get_revenue_driver_decomposition_v109(p_business uuid, p_current_from date, p_current_to date, p_comparison_from date, p_comparison_to date, p_branch uuid DEFAULT NULL::uuid, p_as_of timestamp with time zone DEFAULT statement_timestamp())
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'app', 'pg_temp'
AS $function$
declare
  c_total bigint:=0;
  c_identified bigint:=0;
  c_transactions integer:=0;
  c_clients integer:=0;
  c_total_transactions integer:=0;
  c_itemized_transactions integer:=0;
  c_itemized_revenue bigint:=0;
  p_total bigint:=0;
  p_identified bigint:=0;
  p_transactions integer:=0;
  p_clients integer:=0;
  p_total_transactions integer:=0;
  p_itemized_transactions integer:=0;
  p_itemized_revenue bigint:=0;
  c_anonymous bigint:=0;
  p_anonymous bigint:=0;
  c_coverage integer;
  p_coverage integer;
  c_itemized_transaction_coverage integer;
  p_itemized_transaction_coverage integer;
  c_itemized_revenue_coverage integer;
  p_itemized_revenue_coverage integer;
  p_frequency numeric;
  p_aov numeric;
  c_frequency numeric;
  c_aov numeric;
  d_customer bigint;
  d_frequency bigint;
  d_aov bigint;
  d_anonymous bigint;
  d_residual bigint;
  d_total bigint;
  d_sum bigint;
  v_available boolean:=false;
  v_reason text;
  v_currency text;
  v_currency_count integer;
begin
  perform app.v109_require_feature();
  perform app.v109_require_finance_scope(p_business,p_branch);
  if not app.can_module(p_business,'customerintel') then
    raise exception 'customerintel_module_required' using errcode='42501';
  end if;
  if p_current_from is null
     or p_current_to is null
     or p_comparison_from is null
     or p_comparison_to is null
     or p_current_from>=p_current_to
     or p_comparison_from>=p_comparison_to
     or p_as_of is null then
    raise exception 'valid local-date periods and as-of are required'
      using errcode='22023';
  end if;
  if p_branch is not null and not exists (
    select 1 from public.branches branch
     where branch.id=p_branch and branch.business_id=p_business
  ) then
    raise exception 'branch does not belong to business' using errcode='22023';
  end if;

  select count(distinct contract.currency),min(contract.currency)
    into v_currency_count,v_currency
    from public.sales sale
    cross join lateral app.v106_reporting_contract(
      sale.business_id,sale.branch_id,sale.occurred_at
    ) contract
   where sale.business_id=p_business
     and (p_branch is null or sale.branch_id=p_branch)
     and sale.counts_as_revenue
     and sale.reversal_of is null
     and sale.created_at<=p_as_of
     and (
       (
         (sale.occurred_at at time zone contract.timezone)::date>=p_current_from
         and
         (sale.occurred_at at time zone contract.timezone)::date<p_current_to
       ) or (
         (sale.occurred_at at time zone contract.timezone)::date>=
           p_comparison_from
         and
         (sale.occurred_at at time zone contract.timezone)::date<p_comparison_to
       )
     );
  if v_currency_count>1 then
    raise exception 'cross-currency driver comparisons are not supported'
      using errcode='22023';
  end if;
  if v_currency_count=0 then
    select upper(currency) into strict v_currency
      from public.businesses where id=p_business;
  end if;

  with base as (
    select
      app.v113_effective_client_id(sale.business_id,sale.client_id) as client_id,
      app.v106_sale_residual_minor(
        sale.id,p_current_to,p_as_of
      ) as amount_cents,
      exists (
        select 1
          from public.sale_items item
         where item.business_id=sale.business_id
           and item.sale_id=sale.id
           and item.line_cents>0
      ) as is_itemized
    from public.sales sale
    cross join lateral app.v106_reporting_contract(
      sale.business_id,sale.branch_id,sale.occurred_at
    ) contract
    where sale.business_id=p_business
      and (p_branch is null or sale.branch_id=p_branch)
      and sale.counts_as_revenue
      and sale.reversal_of is null
      and sale.created_at<=p_as_of
      and (sale.occurred_at at time zone contract.timezone)::date>=p_current_from
      and (sale.occurred_at at time zone contract.timezone)::date<p_current_to
      and app.v106_sale_residual_minor(
        sale.id,p_current_to,p_as_of
      )>0
  )
  select coalesce(sum(amount_cents),0),
    coalesce(sum(amount_cents) filter(where client_id is not null),0),
    count(*) filter(where client_id is not null),
    count(distinct client_id) filter(where client_id is not null),
    count(*),
    count(*) filter(where is_itemized),
    coalesce(sum(amount_cents) filter(where is_itemized),0)
  into c_total,c_identified,c_transactions,c_clients,
       c_total_transactions,c_itemized_transactions,c_itemized_revenue
  from base;

  with base as (
    select
      app.v113_effective_client_id(sale.business_id,sale.client_id) as client_id,
      app.v106_sale_residual_minor(
        sale.id,p_comparison_to,p_as_of
      ) as amount_cents,
      exists (
        select 1
          from public.sale_items item
         where item.business_id=sale.business_id
           and item.sale_id=sale.id
           and item.line_cents>0
      ) as is_itemized
    from public.sales sale
    cross join lateral app.v106_reporting_contract(
      sale.business_id,sale.branch_id,sale.occurred_at
    ) contract
    where sale.business_id=p_business
      and (p_branch is null or sale.branch_id=p_branch)
      and sale.counts_as_revenue
      and sale.reversal_of is null
      and sale.created_at<=p_as_of
      and (sale.occurred_at at time zone contract.timezone)::date>=
        p_comparison_from
      and (sale.occurred_at at time zone contract.timezone)::date<
        p_comparison_to
      and app.v106_sale_residual_minor(
        sale.id,p_comparison_to,p_as_of
      )>0
  )
  select coalesce(sum(amount_cents),0),
    coalesce(sum(amount_cents) filter(where client_id is not null),0),
    count(*) filter(where client_id is not null),
    count(distinct client_id) filter(where client_id is not null),
    count(*),
    count(*) filter(where is_itemized),
    coalesce(sum(amount_cents) filter(where is_itemized),0)
  into p_total,p_identified,p_transactions,p_clients,
       p_total_transactions,p_itemized_transactions,p_itemized_revenue
  from base;

  c_anonymous:=c_total-c_identified;
  p_anonymous:=p_total-p_identified;
  c_coverage:=case when c_total=0 then null
    else round(c_identified*10000.0/c_total)::integer end;
  p_coverage:=case when p_total=0 then null
    else round(p_identified*10000.0/p_total)::integer end;
  c_itemized_transaction_coverage:=case when c_total_transactions=0 then null
    else round(c_itemized_transactions*10000.0/c_total_transactions)::integer end;
  p_itemized_transaction_coverage:=case when p_total_transactions=0 then null
    else round(p_itemized_transactions*10000.0/p_total_transactions)::integer end;
  c_itemized_revenue_coverage:=case when c_total=0 then null
    else round(c_itemized_revenue*10000.0/c_total)::integer end;
  p_itemized_revenue_coverage:=case when p_total=0 then null
    else round(p_itemized_revenue*10000.0/p_total)::integer end;
  d_total:=c_total-p_total;
  v_available:=c_clients>0 and p_clients>0
    and c_transactions>0 and p_transactions>0;
  if v_available then
    p_frequency:=p_transactions::numeric/p_clients;
    p_aov:=p_identified::numeric/p_transactions;
    c_frequency:=c_transactions::numeric/c_clients;
    c_aov:=c_identified::numeric/c_transactions;
    d_customer:=round((c_clients-p_clients)*p_frequency*p_aov);
    d_frequency:=round(c_clients*(c_frequency-p_frequency)*p_aov);
    d_aov:=round(c_clients*c_frequency*(c_aov-p_aov));
    d_anonymous:=c_anonymous-p_anonymous;
    d_residual:=d_total-d_customer-d_frequency-d_aov-d_anonymous;
    d_sum:=d_customer+d_frequency+d_aov+d_anonymous+d_residual;
  else
    v_reason:=case
      when p_total=0 then 'comparison_period_has_no_revenue'
      when c_total=0 then 'current_period_has_no_revenue'
      when p_clients=0 or p_transactions=0
        then 'comparison_period_has_no_identified_customer_base'
      else 'current_period_has_no_identified_customer_base'
    end;
  end if;

  return jsonb_build_object(
    'contract_version','revenue_driver_decomposition_v109',
    'business_id',p_business,'as_of',p_as_of,'currency',v_currency,
    'status',case when v_available then 'ready' else 'unavailable' end,
    'unavailable_reason',v_reason,
    'identity_attribution','v111_current_effective_identity',
    'periods',jsonb_build_object(
      'comparison',jsonb_build_object(
        'from',p_comparison_from,'to',p_comparison_to,
        'basis','business_local_date','revenue_cents',p_total,
        'identified_revenue_cents',p_identified,
        'anonymous_revenue_cents',p_anonymous,
        'identified_customers',p_clients,
        'identified_transactions',p_transactions,
        'transactions',p_total_transactions,
        'itemized_transactions',p_itemized_transactions,
        'itemized_revenue_cents',p_itemized_revenue
      ),
      'current',jsonb_build_object(
        'from',p_current_from,'to',p_current_to,
        'basis','business_local_date','revenue_cents',c_total,
        'identified_revenue_cents',c_identified,
        'anonymous_revenue_cents',c_anonymous,
        'identified_customers',c_clients,
        'identified_transactions',c_transactions,
        'transactions',c_total_transactions,
        'itemized_transactions',c_itemized_transactions,
        'itemized_revenue_cents',c_itemized_revenue
      )
    ),
    'coverage',jsonb_build_object(
      'comparison_identified_revenue_bps',p_coverage,
      'current_identified_revenue_bps',c_coverage,
      'comparison_itemized_transaction_bps',p_itemized_transaction_coverage,
      'current_itemized_transaction_bps',c_itemized_transaction_coverage,
      'comparison_itemized_revenue_bps',p_itemized_revenue_coverage,
      'current_itemized_revenue_bps',c_itemized_revenue_coverage,
      'anonymous_revenue_is_separate_driver',true
    ),
    'line_item_analysis',jsonb_build_object(
      'status','coverage_only',
      'price_volume_mix_status','not_claimed',
      'reason',
        'line-level price and mix effects require complete itemization and a versioned taxonomy',
      'causal_claim',false
    ),
    'drivers',case when v_available then jsonb_build_object(
      'identified_customer_count_cents',d_customer,
      'purchase_frequency_cents',d_frequency,
      'average_transaction_value_cents',d_aov,
      'anonymous_revenue_cents',d_anonymous,
      'rounding_residual_cents',d_residual
    ) else 'null'::jsonb end,
    'reconciliation',jsonb_build_object(
      'period_revenue_delta_cents',d_total,
      'sum_driver_contributions_cents',d_sum,
      'rounding_residual_cents',d_residual,
      'reconciles',case when v_available then d_sum=d_total else null end
    ),
    'method',jsonb_build_object(
      'identity',
        'revenue = effective identified customers × purchase frequency × average transaction value + anonymous revenue',
      'identity_resolver','v111_current_effective_identity',
      'order',jsonb_build_array(
        'identified_customer_count','purchase_frequency',
        'average_transaction_value','anonymous_revenue','rounding_residual'
      ),
      'deterministic',true,'causal_claim',false
    )
  );
end
$function$;
revoke all on function public.get_revenue_driver_decomposition_v109(p_business uuid, p_current_from date, p_current_to date, p_comparison_from date, p_comparison_to date, p_branch uuid, p_as_of timestamp with time zone) from public;
revoke all on function public.get_revenue_driver_decomposition_v109(p_business uuid, p_current_from date, p_current_to date, p_comparison_from date, p_comparison_to date, p_branch uuid, p_as_of timestamp with time zone) from postgres;
grant execute on function public.get_revenue_driver_decomposition_v109(p_business uuid, p_current_from date, p_current_to date, p_comparison_from date, p_comparison_to date, p_branch uuid, p_as_of timestamp with time zone) to postgres;
revoke all on function public.get_revenue_driver_decomposition_v109(p_business uuid, p_current_from date, p_current_to date, p_comparison_from date, p_comparison_to date, p_branch uuid, p_as_of timestamp with time zone) from authenticated;
grant execute on function public.get_revenue_driver_decomposition_v109(p_business uuid, p_current_from date, p_current_to date, p_comparison_from date, p_comparison_to date, p_branch uuid, p_as_of timestamp with time zone) to authenticated;
revoke all on function public.get_revenue_driver_decomposition_v109(p_business uuid, p_current_from date, p_current_to date, p_comparison_from date, p_comparison_to date, p_branch uuid, p_as_of timestamp with time zone) from service_role;
grant execute on function public.get_revenue_driver_decomposition_v109(p_business uuid, p_current_from date, p_current_to date, p_comparison_from date, p_comparison_to date, p_branch uuid, p_as_of timestamp with time zone) to service_role;

CREATE OR REPLACE FUNCTION public.get_revenue_truth_v106(p_business uuid, p_from date, p_to date, p_branch uuid DEFAULT NULL::uuid, p_as_of timestamp with time zone DEFAULT clock_timestamp())
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'app', 'pg_temp'
AS $function$
declare
  v_currency text;
  v_period_currency text;
  v_currency_count integer;
  v_timezone text;
  v_result jsonb;
begin
  if auth.uid() is null then
    raise exception 'authentication required' using errcode = '42501';
  end if;
  if p_to <= p_from then
    raise exception 'p_to must be after p_from' using errcode = '22023';
  end if;
  if not (app.is_super_admin()
          or (app.has_perm(p_business, 'view_finance')
              and app.can_module(p_business, 'customerintel'))) then
    raise exception 'finance permission required' using errcode = '42501';
  end if;
  if not app.can_see_branch(p_business, p_branch) then
    raise exception 'branch is outside actor scope' using errcode = '42501';
  end if;
  if p_branch is not null and not exists (
    select 1 from public.branches b
     where b.id = p_branch and b.business_id = p_business
  ) then
    raise exception 'branch does not belong to business' using errcode = '23503';
  end if;
  select upper(b.currency) into strict v_currency
    from public.businesses b where b.id = p_business;
  if p_branch is null then
    v_timezone := 'per_outlet';
  else
    select b.timezone into strict v_timezone
      from public.branches b
     where b.id = p_branch and b.business_id = p_business;
  end if;
  select count(distinct c.currency), min(c.currency)
    into v_currency_count, v_period_currency
    from public.sales s
    cross join lateral app.v106_reporting_contract(
      s.business_id, s.branch_id, s.occurred_at
    ) c
   where s.business_id = p_business
     and s.reversal_of is null
     and s.counts_as_revenue
     and s.created_at <= p_as_of
     and (p_branch is null or s.branch_id = p_branch)
     and (s.occurred_at at time zone c.timezone)::date >= p_from
     and (s.occurred_at at time zone c.timezone)::date < p_to;
  if v_currency_count > 1 then
    raise exception 'cross-currency reporting periods are not supported'
      using errcode = '22023';
  end if;
  if v_currency_count = 1 then
    v_currency := v_period_currency;
  end if;

  with original_sales as materialized (
    select s.id,
           app.v111_effective_client_id(s.business_id, s.client_id) as client_id,
           s.amount_cents, s.occurred_at, s.created_at,
           s.branch_id, c.timezone, c.currency,
           coalesce((
             select abs(sum(r.amount_cents))
             from public.sales r
              cross join lateral app.v106_reporting_contract(
                r.business_id, r.branch_id, r.occurred_at
              ) rc
              where r.business_id = s.business_id
                and r.reversal_of = s.id
                and r.created_at <= p_as_of
                and (r.occurred_at at time zone rc.timezone)::date < p_to
           ), 0)::bigint as native_refund_minor,
           coalesce((
             select sum(a.amount_minor)
               from public.commerce_refund_allocations_v106 a
               join public.commerce_event_reconciliations_v106 rr
                 on rr.id = a.reconciliation_id and rr.business_id = a.business_id
               join public.commerce_events_v106 e
                 on e.id = a.event_id and e.business_id = a.business_id
              where a.business_id = s.business_id
                and a.sale_id = s.id
                and rr.created_at <= p_as_of
                and e.business_date < p_to
           ), 0)::bigint as external_refund_minor,
           exists (
             select 1 from public.sale_items i
              where i.business_id = s.business_id and i.sale_id = s.id
           ) as is_itemized,
           exists (
             select 1
               from public.commerce_event_reconciliations_v106 rr
               join public.commerce_events_v106 e
                 on e.id = rr.event_id
                and e.business_id = rr.business_id
              where rr.business_id = s.business_id
                and rr.sale_id = s.id
                and rr.created_at <= p_as_of
                and e.received_at <= p_as_of
                and e.event_type = 'transaction_completed'
                and e.branch_id is not distinct from s.branch_id
                and e.currency = c.currency
                and e.amount_minor = s.amount_cents
           ) as is_reconciled
      from public.sales s
      cross join lateral app.v106_reporting_contract(
        s.business_id, s.branch_id, s.occurred_at
      ) c
     where s.business_id = p_business
       and s.reversal_of is null
       and s.counts_as_revenue
       and s.created_at <= p_as_of
       and (p_branch is null or s.branch_id = p_branch)
       and (s.occurred_at at time zone c.timezone)::date >= p_from
       and (s.occurred_at at time zone c.timezone)::date < p_to
  ), eligible as (
    select *,
      app.v106_sale_residual_minor(id, p_to, p_as_of) as net_minor
      from original_sales
  ), totals as (
    select
      coalesce(sum(net_minor), 0)::bigint as known_revenue,
      coalesce(sum(net_minor) filter (where client_id is not null), 0)::bigint
        as identified_revenue,
      coalesce(sum(net_minor) filter (where client_id is null), 0)::bigint
        as anonymous_revenue,
      count(*) filter (where net_minor > 0)::bigint as completed_transactions,
      count(*) filter (where net_minor > 0 and client_id is not null)::bigint
        as identified_transactions,
      count(*) filter (where net_minor > 0 and client_id is null)::bigint
        as anonymous_transactions,
      count(*) filter (where net_minor > 0 and is_itemized)::bigint
        as itemized_transactions,
      count(*) filter (where net_minor > 0 and is_reconciled)::bigint
        as reconciled_transactions,
      max(occurred_at) as latest_sale_occurred_at,
      max(created_at) as latest_sale_recorded_at,
      count(*)::bigint as cohort_rows
    from eligible
  ), event_freshness as (
    select max(e.received_at) as latest_external_event_received_at
      from public.commerce_events_v106 e
     where e.business_id = p_business
       and (p_branch is null or e.branch_id = p_branch)
       and e.received_at <= p_as_of
  ), conflict_count as (
    select count(*)::bigint as conflicts
      from public.commerce_event_conflicts_v106 q
      join public.commerce_events_v106 e
        on e.id = q.existing_event_id and e.business_id = q.business_id
     where q.business_id = p_business and q.created_at <= p_as_of
       and (p_branch is null or e.branch_id = p_branch)
  )
  select jsonb_build_object(
    'contract_version', 'v106.1',
    'generated_at', clock_timestamp(),
    'as_of', p_as_of,
    'scope', jsonb_build_object(
      'business_id', p_business,
      'branch_id', p_branch,
      'period', jsonb_build_object(
        'from', p_from,
        'to', p_to,
        'interval', '[from,to)'
      ),
      'timezone', v_timezone,
      'timezone_contract', case when p_branch is null
        then 'per_outlet_effective_timezone'
        else 'selected_outlet_effective_timezone'
      end,
      'currency', v_currency
    ),
    'status', case when t.completed_transactions = 0 then 'no_data' else 'ok' end,
    'totals', jsonb_build_object(
      'known_revenue_minor', t.known_revenue,
      'identified_revenue_minor', t.identified_revenue,
      'anonymous_revenue_minor', t.anonymous_revenue,
      'completed_transactions', t.completed_transactions,
      'identified_transactions', t.identified_transactions,
      'anonymous_transactions', t.anonymous_transactions,
      'itemized_transactions', t.itemized_transactions
    ),
    'coverage', jsonb_build_object(
      'identity_revenue_pct', case when t.known_revenue = 0 then null
        else round(100 * t.identified_revenue::numeric / t.known_revenue, 2) end,
      'identity_transaction_pct', case when t.completed_transactions = 0 then null
        else round(100 * t.identified_transactions::numeric / t.completed_transactions, 2) end,
      'itemization_transaction_pct', case when t.completed_transactions = 0 then null
        else round(100 * t.itemized_transactions::numeric / t.completed_transactions, 2) end,
      'reconciled_transaction_pct', case when t.completed_transactions = 0 then null
        else round(100 * t.reconciled_transactions::numeric / t.completed_transactions, 2) end
    ),
    'freshness', jsonb_build_object(
      'latest_sale_occurred_at', t.latest_sale_occurred_at,
      'latest_sale_recorded_at', t.latest_sale_recorded_at,
      'latest_external_event_received_at', f.latest_external_event_received_at,
      'reconciliation_conflicts', q.conflicts
    ),
    'formula_metadata', jsonb_build_object(
      'version', 'revenue_truth_v106_1',
      'eligible_sale', 'original sale with counts_as_revenue=true and created_at<=as_of',
      'period_assignment', 'sale occurred_at converted by its effective outlet timezone',
      'known_revenue', 'sum(max(original_amount-native_full_reversal-reconciled_external_refund_allocations,0))',
      'identity_split', 'identified iff the v111 current-attribution resolver returns a client_id; otherwise anonymous',
      'identity_attribution', 'immutable sales.client_id is resolved through app.v111_effective_client_id for current synchronized reporting',
      'invariant', 'known_revenue_minor = identified_revenue_minor + anonymous_revenue_minor',
      'refund_cutoff', 'refund business date is before report p_to and recorded by as_of',
      'zero_denominator', 'coverage ratios are null'
    ),
    'limitations', jsonb_build_array(
      'Known revenue covers the Peekaa sales ledger; it is not merchant-total revenue until a POS adapter proves source completeness.',
      'External transaction observations do not affect totals until reconciled to an existing sale.',
      'Legacy pre-v106 facts use an explicit migration-time timezone/currency assumption.',
      'Native reversals are full-sale only; v106 external allocations provide partial-refund attribution without rewriting old ledgers.'
    )
  ) into v_result
  from totals t cross join event_freshness f cross join conflict_count q;

  if (v_result #>> '{totals,known_revenue_minor}')::bigint <>
     (v_result #>> '{totals,identified_revenue_minor}')::bigint +
     (v_result #>> '{totals,anonymous_revenue_minor}')::bigint then
    raise exception 'v106 revenue identity invariant failed'
      using errcode = 'data_exception';
  end if;
  return v_result;
end $function$;
revoke all on function public.get_revenue_truth_v106(p_business uuid, p_from date, p_to date, p_branch uuid, p_as_of timestamp with time zone) from public;
revoke all on function public.get_revenue_truth_v106(p_business uuid, p_from date, p_to date, p_branch uuid, p_as_of timestamp with time zone) from postgres;
grant execute on function public.get_revenue_truth_v106(p_business uuid, p_from date, p_to date, p_branch uuid, p_as_of timestamp with time zone) to postgres;
revoke all on function public.get_revenue_truth_v106(p_business uuid, p_from date, p_to date, p_branch uuid, p_as_of timestamp with time zone) from authenticated;
grant execute on function public.get_revenue_truth_v106(p_business uuid, p_from date, p_to date, p_branch uuid, p_as_of timestamp with time zone) to authenticated;
revoke all on function public.get_revenue_truth_v106(p_business uuid, p_from date, p_to date, p_branch uuid, p_as_of timestamp with time zone) from service_role;
grant execute on function public.get_revenue_truth_v106(p_business uuid, p_from date, p_to date, p_branch uuid, p_as_of timestamp with time zone) to service_role;

CREATE OR REPLACE FUNCTION public.record_cart_sale(p_business uuid, p_client uuid, p_branch uuid, p_staff uuid, p_method text, p_idempotency_key text, p_lines jsonb)
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'app', 'pg_temp'
AS $function$
declare
  v_actor uuid := auth.uid();
  v_key text := nullif(btrim(p_idempotency_key), '');
  v_method text := lower(nullif(btrim(p_method), ''));
  v_types text[] := array['service', 'retail', 'package', 'membership', 'gift_card', 'custom'];
  v_line jsonb;
  v_type text;
  v_ref uuid;
  v_qn numeric;
  v_un numeric;
  v_qty integer;
  v_unit integer;
  v_line_staff uuid;
  v_count integer;
  v_total bigint := 0;
  v_retail_lines integer := 0;
  v_stamp_product uuid;
  v_stamp_qty integer;
  v_financial jsonb;
  v_sale_id uuid;
  v_replayed boolean;
  v_points integer := 0;
  v_items json;
begin
  if v_actor is null then
    raise exception 'authenticated staff required to record a cart sale' using errcode = '42501';
  end if;
  if not app.has_perm(p_business, 'create_sales')
     or not app.can_module(p_business, 'till') then
    raise exception 'you do not have permission to record a sale in this business (create_sales)'
      using errcode = '42501';
  end if;
  if v_key is null or length(v_key) < 8 then
    raise exception 'a cart-sale idempotency key of at least 8 characters is required'
      using errcode = '22023';
  end if;
  if v_method is null or v_method not in ('cash', 'card', 'paynow', 'other') then
    raise exception 'choose Cash, Card, PayNow or Other' using errcode = '22023';
  end if;
  if p_lines is null or jsonb_typeof(p_lines) <> 'array' then
    raise exception 'cart lines must be a JSON array' using errcode = '22023';
  end if;
  v_count := jsonb_array_length(p_lines);
  if v_count < 1 or v_count > 50 then
    raise exception 'a cart must have between 1 and 50 lines' using errcode = '22023';
  end if;
  if p_client is not null and not exists (
    select 1 from public.clients c where c.id = p_client and c.business_id = p_business
  ) then
    raise exception 'cart-sale client does not belong to this business' using errcode = '22023';
  end if;

  -- Validate every line before creating anything.
  for v_line in select * from jsonb_array_elements(p_lines) loop
    v_type := v_line->>'item_type';
    if v_type is null or not (v_type = any (v_types)) then
      raise exception 'unsupported cart line item_type %', coalesce(v_type, '(null)')
        using errcode = '22023';
    end if;
    if jsonb_typeof(v_line->'qty') is distinct from 'number'
       or jsonb_typeof(v_line->'unit_cents') is distinct from 'number' then
      raise exception 'each cart line requires numeric qty and unit_cents' using errcode = '22023';
    end if;
    v_qn := (v_line->>'qty')::numeric;
    v_un := (v_line->>'unit_cents')::numeric;
    if v_qn <> trunc(v_qn) or v_qn <= 0 or v_qn > 1000000 then
      raise exception 'cart line qty must be a whole number between 1 and 1000000'
        using errcode = '22023';
    end if;
    if v_un <> trunc(v_un) or v_un < 0 or v_un > 100000000 then
      raise exception 'cart line unit_cents must be a whole number between 0 and 100000000'
        using errcode = '22023';
    end if;
    v_qty := v_qn::integer;
    v_unit := v_un::integer;
    v_ref := nullif(v_line->>'ref_id', '')::uuid;
    v_line_staff := nullif(v_line->>'staff_id', '')::uuid;

    if v_type = 'service' then
      if v_ref is null or not exists (
        select 1 from public.services s where s.id = v_ref and s.business_id = p_business
      ) then
        raise exception 'service line references a service outside this business'
          using errcode = '22023';
      end if;
    elsif v_type = 'retail' then
      if v_ref is null or not exists (
        select 1 from public.products p where p.id = v_ref and p.business_id = p_business
      ) then
        raise exception 'retail line references a product outside this business'
          using errcode = '22023';
      end if;
      v_retail_lines := v_retail_lines + 1;
      v_stamp_product := v_ref;
      v_stamp_qty := v_qty;
    elsif v_type = 'package' then
      if v_ref is null or not exists (
        select 1 from public.package_plans pp where pp.id = v_ref and pp.business_id = p_business
      ) then
        raise exception 'package line references a plan outside this business'
          using errcode = '22023';
      end if;
    elsif v_type = 'membership' then
      if v_ref is null or not exists (
        select 1 from public.membership_plans mp where mp.id = v_ref and mp.business_id = p_business
      ) then
        raise exception 'membership line references a plan outside this business'
          using errcode = '22023';
      end if;
    else
      -- gift_card / custom carry no typed reference.
      if v_ref is not null then
        raise exception 'a % line must not carry a ref_id', v_type using errcode = '22023';
      end if;
    end if;

    if v_line_staff is not null and not exists (
      select 1 from public.staff s
       where s.id = v_line_staff and s.business_id = p_business and s.active
    ) then
      raise exception 'cart line staff is inactive or outside this business' using errcode = '22023';
    end if;

    v_total := v_total + (v_qty::bigint * v_unit::bigint);
  end loop;

  if v_total <= 0 then
    raise exception 'a cart sale must total more than zero' using errcode = '22023';
  end if;
  if v_total > 2147483647 then
    raise exception 'cart total exceeds the supported maximum' using errcode = '22023';
  end if;

  -- Only a single-retail-line cart can carry the parent product_id/qty that v6 FEFO
  -- (single-product-per-sale) can act on. Otherwise leave product_id NULL: no deduction,
  -- identical to every other checkout surface today.
  if v_retail_lines <> 1 then
    v_stamp_product := null;
    v_stamp_qty := null;
  end if;

  perform set_config('app.cart_line_product_id', coalesce(v_stamp_product::text, ''), true);
  perform set_config('app.cart_line_qty', coalesce(v_stamp_qty::text, ''), true);
  v_financial := public.record_quick_sale(
    p_business => p_business,
    p_amount_cents => v_total::integer,
    p_method => v_method,
    p_client => p_client,
    p_staff => p_staff,
    p_branch => p_branch,
    p_note => 'cart checkout',
    p_idempotency_key => v_key,
    p_paid => true
  )::jsonb;
  perform set_config('app.cart_line_product_id', '', true);
  perform set_config('app.cart_line_qty', '', true);

  v_sale_id := nullif(v_financial #>> '{sale,id}', '')::uuid;
  v_replayed := coalesce((v_financial->>'replayed')::boolean, false);
  if v_sale_id is null then
    raise exception 'cart sale did not produce a parent sale row' using errcode = 'XX001';
  end if;

  -- First run inserts the child lines; a replay already committed them, so skip to avoid
  -- duplicates. sale_id committed <=> its items committed (one transaction), so this holds.
  if not v_replayed then
    insert into public.sale_items(
      sale_id, business_id, item_type, ref_id, description,
      qty, unit_cents, line_cents, product_id, staff_id)
    select v_sale_id,
           p_business,
           e->>'item_type',
           nullif(e->>'ref_id', '')::uuid,
           nullif(e->>'description', ''),
           (e->>'qty')::integer,
           (e->>'unit_cents')::integer,
           (e->>'qty')::integer * (e->>'unit_cents')::integer,
           case when e->>'item_type' = 'retail' then nullif(e->>'ref_id', '')::uuid end,
           nullif(e->>'staff_id', '')::uuid
      from jsonb_array_elements(p_lines) as e;
  end if;

  if p_client is not null then
    select coalesce(sum(pl.points), 0) into v_points
      from public.points_ledger pl
     where pl.business_id = p_business
       and pl.client_id = p_client
       and pl.sale_id = v_sale_id
       and pl.entry_type = 'earn';
  end if;

  select coalesce(json_agg(row_to_json(si) order by si.created_at, si.id), '[]'::json)
    into v_items
    from public.sale_items si
   where si.business_id = p_business and si.sale_id = v_sale_id;

  return json_build_object(
    'status', case when v_replayed then 'duplicate_ignored' else 'ok' end,
    'sale_id', v_sale_id,
    'business_id', p_business,
    'total_cents', v_total,
    'item_count', v_count,
    'replayed', v_replayed,
    'points_earned', case when v_replayed then 0 else v_points end,
    'sale', v_financial->'sale',
    'items', v_items
  );
end $function$;
revoke all on function public.record_cart_sale(p_business uuid, p_client uuid, p_branch uuid, p_staff uuid, p_method text, p_idempotency_key text, p_lines jsonb) from public;
revoke all on function public.record_cart_sale(p_business uuid, p_client uuid, p_branch uuid, p_staff uuid, p_method text, p_idempotency_key text, p_lines jsonb) from postgres;
grant execute on function public.record_cart_sale(p_business uuid, p_client uuid, p_branch uuid, p_staff uuid, p_method text, p_idempotency_key text, p_lines jsonb) to postgres;
revoke all on function public.record_cart_sale(p_business uuid, p_client uuid, p_branch uuid, p_staff uuid, p_method text, p_idempotency_key text, p_lines jsonb) from service_role;
grant execute on function public.record_cart_sale(p_business uuid, p_client uuid, p_branch uuid, p_staff uuid, p_method text, p_idempotency_key text, p_lines jsonb) to service_role;

CREATE OR REPLACE FUNCTION public.record_cart_sale(p_business uuid, p_client uuid, p_branch uuid, p_staff uuid, p_method text, p_idempotency_key text, p_lines jsonb, p_evaluation_id uuid, p_paid boolean DEFAULT true)
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'app', 'pg_temp'
AS $function$
declare
  v_actor uuid := auth.uid();
  v_key text := nullif(btrim(p_idempotency_key), '');
  v_method text := lower(nullif(btrim(p_method), ''));
  v_paid boolean := coalesce(p_paid, true);
  v_eval public.checkout_evaluations%rowtype;
  v_line jsonb; v_ord int; v_rehash text; v_price jsonb;
  v_kind text; v_cid uuid; v_qty int; v_unit int;
  v_reproj jsonb := '[]'::jsonb;
  v257_bundle jsonb; v257_bline jsonb; v257_bid uuid; v257_bqty int;
  v257_cur_bid uuid; v257_cur_bqty int; v257_pos int := 0;
  v_retail_lines int := 0; v_stamp_product uuid; v_stamp_qty int;
  v_financial jsonb; v_sale_id uuid; v_replayed boolean;
  eff jsonb; v_ps timestamptz; v_amt int; v_ful uuid; v_key_ben text; v_rule uuid; v_rule_name text;
  bp record; v_bp_id uuid; v_committed int; v_points int := 0; v_items json;
  -- v67 stored-value tender locals
  v_tender public.checkout_sv_tenders%rowtype; v_has_sv boolean := false;
  v_sv_amount int := 0; v_sv_remainder int := 0; v_spend jsonb; v_sv_json jsonb := null;
begin
  if v_actor is null then
    raise exception 'authenticated staff required to finalise a cart sale' using errcode = '42501';
  end if;
  if not app.has_perm(p_business, 'create_sales')
     or not app.can_module(p_business, 'till') then
    raise exception 'you do not have permission to record a sale in this business (create_sales)' using errcode = '42501';
  end if;
  if v_key is null or length(v_key) < 8 then
    raise exception 'a cart-sale idempotency key of at least 8 characters is required' using errcode = '22023';
  end if;
  if v_method is null or v_method not in ('cash', 'card', 'paynow', 'other') then
    raise exception 'choose Cash, Card, PayNow or Other' using errcode = '22023';
  end if;
  if p_evaluation_id is null then
    raise exception 'the kernel finaliser requires a checkout evaluation token' using errcode = '22023';
  end if;

  -- 8.1 Lock the token. Single-use + tenant + scope validation.
  select * into v_eval from public.checkout_evaluations
   where id = p_evaluation_id and business_id = p_business for update;
  if not found then
    raise exception 'checkout evaluation not found in this business' using errcode = '42501';
  end if;
  if p_branch is not null and p_branch is distinct from v_eval.branch_id then
    raise exception 'stale_evaluation: branch does not match the evaluation token' using errcode = 'P0001';
  end if;
  if p_client is not null and p_client is distinct from v_eval.client_id then
    raise exception 'stale_evaluation: client does not match the evaluation token' using errcode = 'P0001';
  end if;

  -- 8.2 If already consumed: exact replay of THIS key, or a same-token/different-key loser
  --     (which must fail stale, never double-sell).
  if v_eval.consumed_at is not null then
    if exists (select 1 from public.financial_operations fo
                where fo.business_id = p_business and fo.sale_id = v_eval.consumed_sale_id
                  and fo.operation_type = 'quick_sale' and fo.idempotency_key = v_key) then
      select coalesce(sum(pl.points), 0) into v_points from public.points_ledger pl
       where pl.business_id = p_business and pl.sale_id = v_eval.consumed_sale_id and pl.entry_type = 'earn';
      select coalesce(json_agg(row_to_json(si) order by si.created_at, si.id), '[]'::json) into v_items
        from public.sale_items si where si.business_id = p_business and si.sale_id = v_eval.consumed_sale_id;
      return json_build_object('status', 'duplicate_ignored', 'sale_id', v_eval.consumed_sale_id,
        'business_id', p_business, 'total_cents', v_eval.total_cents, 'discount_total_cents', v_eval.discount_total_cents,
        'replayed', true, 'points_earned', 0, 'evaluation_id', v_eval.id, 'items', v_items,
        'stored_value', (select jsonb_build_object('sv_paid_cents', t.reserved_cents,
            'cash_collected_cents', t.cash_remainder_cents) from public.checkout_sv_tenders t
           where t.evaluation_id = v_eval.id and t.status = 'consumed' limit 1));
    end if;
    raise exception 'stale_evaluation: this checkout evaluation was already consumed by another sale' using errcode = 'P0001';
  end if;
  if v_eval.expires_at <= now() then
    raise exception 'stale_evaluation: the checkout evaluation has expired; re-evaluate' using errcode = 'P0001';
  end if;

  -- 8.3 Config drift: the active config version must be UNCHANGED since evaluation.
  if v_eval.config_version_id is distinct from
     (select active_config_version_id from public.businesses where id = p_business) then
    raise exception 'stale_evaluation: the active configuration changed since evaluation; re-evaluate' using errcode = 'P0001';
  end if;

  -- 8.3b Stored-value tender bound to this token? Discover + re-validate gates (TOCTOU). Any drift
  --      (reservation missing/expired/released) -> stale_evaluation so the till re-evaluates once.
  select * into v_tender from public.checkout_sv_tenders
   where business_id = p_business and evaluation_id = v_eval.id and status = 'reserved'
   for update;
  if found then
    v_has_sv := true;
    -- Gate re-validation after the lock (authority live, no synthetic on live, redeem pause, currency).
    perform app.sv_checkout_tender_gate(p_business, v_eval.client_id, v_tender.currency);
    if not exists (select 1 from public.sv_reservations r
                    where r.id = v_tender.reservation_id and r.business_id = p_business and r.status = 'active') then
      raise exception 'stale_evaluation: the stored-value hold is no longer active; re-evaluate' using errcode = 'P0001';
    end if;
    v_sv_amount := least(v_tender.reserved_cents, v_eval.total_cents);
    if v_sv_amount < 1 then
      raise exception 'stale_evaluation: the stored-value hold no longer covers this checkout; re-evaluate' using errcode = 'P0001';
    end if;
    v_sv_remainder := v_eval.total_cents - v_sv_amount;
  elsif exists (select 1 from public.checkout_sv_tenders t
                 where t.business_id = p_business and t.evaluation_id = v_eval.id and t.status = 'released') then
    -- The staff opted into stored value for this token but the hold was released (superseded by a
    -- later checkout for the same customer, or swept). Never silently downgrade to cash: fail stale
    -- so the till re-evaluates once (one winner in a two-token race; the loser gets a typed stale).
    raise exception 'stale_evaluation: the stored-value hold for this checkout was released; re-evaluate' using errcode = 'P0001';
  end if;

  -- 8.4 Price drift: re-resolve every server line and recompute the cart hash. A custom line is
  --     re-projected AS-IS from the immutable token.
  v_ord := 0;
  for v_line in select * from jsonb_array_elements(v_eval.server_lines) loop
    v_ord := v_ord + 1;
    v_kind := v_line->>'catalog_kind';
    v_cid := nullif(v_line->>'catalog_id', '')::uuid;
    v_qty := (v_line->>'qty')::int;
    if v_kind = 'custom' then
      v_unit := (v_line->>'unit_price_cents')::int;
    elsif nullif(v_line->>'bundle_id', '') is not null then
      v257_bid := (v_line->>'bundle_id')::uuid;
      v257_bqty := coalesce(nullif(v_line->>'bundle_qty', '')::int, 1);
      if v257_cur_bid is distinct from v257_bid or v257_cur_bqty is distinct from v257_bqty then
        v257_bundle := app.ps1c_bundle_lines_v204(p_business, v257_bid, v257_bqty);
        if v257_bundle->>'status' <> 'ok' then
          raise exception 'stale_evaluation: bundle on line % can no longer be priced (%); re-evaluate', v_ord, v257_bundle->>'status'
            using errcode = 'P0001';
        end if;
        v257_cur_bid := v257_bid; v257_cur_bqty := v257_bqty; v257_pos := 0;
      end if;
      v257_pos := v257_pos + 1;
      v257_bline := v257_bundle->'lines'->(v257_pos - 1);
      if v257_bline is null or nullif(v257_bline->>'service_id', '')::uuid is distinct from v_cid then
        raise exception 'stale_evaluation: the bundle on line % changed since evaluation; re-evaluate', v_ord
          using errcode = 'P0001';
      end if;
      v_unit := (v257_bline->>'line_cents')::int;
    else
      v_price := app.ps1b_catalog_price(p_business, v_kind, v_cid);
      if v_price->>'status' <> 'ok' then
        raise exception 'stale_evaluation: line % can no longer be priced (%); re-evaluate', v_ord, v_price->>'status'
          using errcode = 'P0001';
      end if;
      v_unit := (v_price->>'price_cents')::int;
      if v_kind = 'product' then v_retail_lines := v_retail_lines + 1; v_stamp_product := v_cid; v_stamp_qty := v_qty; end if;
    end if;
    v_reproj := v_reproj || jsonb_build_array(jsonb_build_object(
      'catalog_kind', v_kind, 'catalog_id', v_cid, 'name', v_line->>'name',
      'unit_price_cents', v_unit, 'qty', v_qty, 'line_total_cents', v_unit * v_qty));
  end loop;
  v_rehash := app.ps1c_cart_hash(v_reproj);
  if v_rehash is distinct from v_eval.cart_hash then
    raise exception 'stale_evaluation: catalog prices changed since evaluation; re-evaluate' using errcode = 'P0001';
  end if;

  -- 8.5 Budget re-check + COMMIT, atomically, under a deterministic
  --     (business_id, rule_id, period_start) lock order.
  for eff in select e from jsonb_array_elements(v_eval.applied_effects) e
              where (e->>'suppressed')::boolean is not true and coalesce((e->>'capped')::boolean, false) loop
    insert into public.budget_periods(business_id, rule_id, period_start, period_end, cap_cents)
    values(p_business, (eff->>'rule_id')::uuid, (eff->>'period_start')::timestamptz,
           (eff->>'period_end')::timestamptz, (eff->>'cap_cents')::int)
    on conflict (business_id, rule_id, period_start) do nothing;
  end loop;
  for bp in select (e->>'rule_id')::uuid as rule_id, (e->>'period_start')::timestamptz as ps,
                    (e->>'cap_cents')::int as cap, sum((e->>'amount_cents')::int) as amt
              from jsonb_array_elements(v_eval.applied_effects) e
             where (e->>'suppressed')::boolean is not true and coalesce((e->>'capped')::boolean, false)
             group by 1, 2, 3
             order by 1, 2 loop
    select coalesce(committed_cents, 0) into v_committed from public.budget_periods
     where business_id = p_business and rule_id = bp.rule_id and period_start = bp.ps
     for update;
    if coalesce(v_committed, 0) + bp.amt > bp.cap then
      raise exception 'stale_evaluation: rule budget was exhausted since evaluation; re-evaluate' using errcode = 'P0001';
    end if;
  end loop;

  -- 8.6 Belt-guard (contract B, v59): a zero total must NEVER create a sale, and must fail as a
  --     TYPED 22023 (not a stale P0001 that would spin a client re-evaluation loop).
  if v_eval.total_cents = 0 then
    raise exception 'total_zero_not_supported: this checkout totals zero after discounts and cannot be recorded; re-price it'
      using errcode = '22023';
  end if;

  -- 8.7 Create the parent sale for the DISCOUNTED total via the kernel candidate. When stored value
  --     tenders any portion, finalise the parent p_paid=false so the finaliser writes NO full-amount
  --     payment (the non-SV remainder is recorded below; the SV portion collects no new cash).
  perform set_config('app.cart_line_product_id',
    coalesce(case when v_retail_lines = 1 then v_stamp_product::text end, ''), true);
  perform set_config('app.cart_line_qty',
    coalesce(case when v_retail_lines = 1 then v_stamp_qty::text end, ''), true);
  v_financial := public.record_quick_sale(
    p_business => p_business, p_amount_cents => v_eval.total_cents, p_method => v_method,
    p_client => v_eval.client_id, p_staff => p_staff, p_branch => v_eval.branch_id, p_note => 'cart checkout (kernel)',
    p_idempotency_key => v_key, p_paid => case when v_has_sv then false else v_paid end)::jsonb;
  perform set_config('app.cart_line_product_id', '', true);
  perform set_config('app.cart_line_qty', '', true);

  v_sale_id := nullif(v_financial #>> '{sale,id}', '')::uuid;
  v_replayed := coalesce((v_financial->>'replayed')::boolean, false);
  if v_sale_id is null then
    raise exception 'kernel finaliser did not produce a parent sale row' using errcode = 'XX001';
  end if;
  if v_replayed then
    raise exception 'stale_evaluation: this idempotency key already produced a sale for a different token' using errcode = 'P0001';
  end if;

  -- 8.8 Write server-line sale_items (positive; custom -> item_type 'custom') then one signed
  --     studio_discount line per applied effect (negative).
  insert into public.sale_items(sale_id, business_id, item_type, ref_id, description, qty, unit_cents, line_cents, product_id)
  select v_sale_id, p_business,
         case e->>'catalog_kind' when 'service' then 'service' when 'product' then 'retail' else 'custom' end,
         nullif(e->>'catalog_id', '')::uuid, e->>'name', (e->>'qty')::int, (e->>'unit_price_cents')::int,
         (e->>'unit_price_cents')::int * (e->>'qty')::int,
         case when e->>'catalog_kind' = 'product' then nullif(e->>'catalog_id', '')::uuid end
    from jsonb_array_elements(v_eval.server_lines) e;

  -- 8.8b One CUSTOM_PRICE_LINE audit row per custom line.
  for eff in select e from jsonb_array_elements(v_eval.server_lines) e where e->>'catalog_kind' = 'custom' loop
    insert into public.audit_log(business_id, actor, action, entity, entity_id, detail)
    values(p_business, v_actor, 'CUSTOM_PRICE_LINE', 'sale_items', v_sale_id,
      jsonb_build_object(
        'description', eff->>'name',
        'amount_cents', (eff->>'unit_price_cents')::int,
        'reason', eff->>'reason',
        'entered_by', eff->>'entered_by'));
  end loop;

  -- 8.9 Per applied (non-suppressed) discount: fulfilment registry row, provenance line, signed
  --     sale_items line, and (if capped) a committed budget reservation.
  for eff in select e from jsonb_array_elements(v_eval.applied_effects) e
              where (e->>'suppressed')::boolean is not true and (e->>'amount_cents')::int > 0
              order by (e->>'rule_id'), (e->>'effect_index')::int loop
    v_rule := (eff->>'rule_id')::uuid;
    v_amt := (eff->>'amount_cents')::int;
    -- V370: an effect with NO rule is the automatic tier discount (app.ps1c_plan_checkout). It is
    -- named by the benefit it came from, and its fulfilment key is keyed on that benefit — the
    -- rule-keyed key would collapse to null and collide with itself.
    if v_rule is null then
      v_rule_name := coalesce(nullif(btrim(coalesce(eff->>'label','')),''), 'Tier discount');
      v_key_ben := 'tierdiscount:' || v_sale_id::text || ':' || coalesce(eff->>'tier_benefit_id','');
    else
      select name into v_rule_name from public.program_rules
        where rule_id = v_rule and config_version_id = v_eval.config_version_id and business_id = p_business;
      v_rule_name := coalesce(v_rule_name, 'Studio discount');
      v_key_ben := 'discount:' || v_sale_id::text || ':' || v_rule::text || ':' || (eff->>'effect_index');
    end if;
    insert into public.benefit_fulfilments(
      business_id, canonical_benefit_key, source_engine, fulfilment_kind, client_id, detail_ref,
      face_value_cents, estimated_cost_cents, cost_basis, cost_confidence, config_version_id, occurred_at)
    values(p_business, v_key_ben, 'checkout', 'checkout_discount', v_eval.client_id, v_sale_id,
      v_amt, v_amt, 'discount_face', 'high', v_eval.config_version_id, now())
    returning id into v_ful;

    -- V370: public.checkout_discount_lines is Studio provenance — rule_id is NOT NULL, its unique
    -- key is (sale_id, rule_id, effect_index), and both reverse_sale and
    -- get_checkout_discount_report key off it. A tier discount has no rule, so it gets no row
    -- there rather than a fabricated one; its money is still fully recorded, by the fulfilment
    -- above and the signed sale_items line below, and it is inside the sale total either way.
    if v_rule is not null then
      insert into public.checkout_discount_lines(
        business_id, sale_id, evaluation_id, rule_id, effect_index, effect_type, level, target_line_index,
        amount_cents, benefit_fulfilment_id, config_version_id)
      values(p_business, v_sale_id, v_eval.id, v_rule, (eff->>'effect_index')::int, eff->>'effect_type',
        eff->>'level', nullif(eff->>'target_line_index', '')::int, v_amt, v_ful, v_eval.config_version_id);
    end if;

    insert into public.sale_items(sale_id, business_id, item_type, ref_id, description, qty, unit_cents, line_cents)
    values(v_sale_id, p_business, 'studio_discount',
      coalesce(v_rule, nullif(eff->>'tier_benefit_id','')::uuid),
      left(case when v_rule is null then 'Tier benefit: ' else 'Discount: ' end || v_rule_name, 200),
      1, -v_amt, -v_amt);

    if coalesce((eff->>'capped')::boolean, false) then
      v_ps := (eff->>'period_start')::timestamptz;
      select id into v_bp_id from public.budget_periods
        where business_id = p_business and rule_id = v_rule and period_start = v_ps;
      insert into public.budget_reservations(business_id, budget_period_id, discount_fulfilment_id, amount_cents)
      values(p_business, v_bp_id, v_ful, v_amt);
      update public.budget_periods set committed_cents = committed_cents + v_amt, updated_at = now()
       where id = v_bp_id;
    end if;
  end loop;

  -- 8.9b Stored-value tender consumption (v67). Release the token hold, then spend the SV portion
  --      via the v63 engine (paid/bonus split per PS-0), record tender evidence, and record only the
  --      non-SV remainder as a payment. All within this atomic transaction with the sale.
  if v_has_sv then
    perform app.sv_release_core(p_business, v_tender.reservation_id, gen_random_uuid());
    v_spend := app.sv_spend_core(p_business, v_tender.account_id, v_sv_amount, gen_random_uuid());
    update public.checkout_sv_tenders
       set status = 'consumed', spend_operation_id = (v_spend->>'operation_id')::uuid, sale_id = v_sale_id,
           sv_paid_cents = (v_spend->>'paid_draw_cents')::int, sv_bonus_cents = (v_spend->>'bonus_draw_cents')::int,
           cash_remainder_cents = v_sv_remainder, updated_at = now()
     where id = v_tender.id;
    if v_sv_remainder > 0 and v_paid then
      perform public.record_payment(
        p_business => p_business, p_method => v_method, p_amount_cents => v_sv_remainder, p_sale => v_sale_id,
        p_client => v_eval.client_id, p_staff => p_staff, p_branch => v_eval.branch_id,
        p_idempotency_key => left(v_key || '-svrem', 255));
    end if;
    insert into public.audit_log(business_id, actor, action, entity, entity_id, detail)
    values(p_business, v_actor, 'SV_CHECKOUT_TENDER_SPENT', 'checkout_sv_tenders', v_tender.id, jsonb_build_object(
      'evaluation_id', v_eval.id, 'sale_id', v_sale_id, 'spend_operation_id', (v_spend->>'operation_id')::uuid,
      'sv_spend_cents', v_sv_amount, 'sv_paid_cents', (v_spend->>'paid_draw_cents')::int,
      'sv_bonus_cents', (v_spend->>'bonus_draw_cents')::int, 'cash_remainder_cents', v_sv_remainder));
    v_sv_json := jsonb_build_object(
      'sv_spend_cents', v_sv_amount, 'sv_paid_cents', (v_spend->>'paid_draw_cents')::int,
      'sv_bonus_cents', (v_spend->>'bonus_draw_cents')::int, 'cash_collected_cents', v_sv_remainder,
      'spend_operation_id', (v_spend->>'operation_id')::uuid);
  end if;

  -- 8.10 Consume the token (single-use).
  update public.checkout_evaluations set consumed_at = now(), consumed_sale_id = v_sale_id
   where id = v_eval.id and consumed_at is null;
  if not found then
    raise exception 'stale_evaluation: token consumed concurrently; re-evaluate' using errcode = 'P0001';
  end if;

  if v_eval.client_id is not null then
    select coalesce(sum(pl.points), 0) into v_points from public.points_ledger pl
     where pl.business_id = p_business and pl.client_id = v_eval.client_id and pl.sale_id = v_sale_id and pl.entry_type = 'earn';
  end if;
  select coalesce(json_agg(row_to_json(si) order by si.created_at, si.id), '[]'::json) into v_items
    from public.sale_items si where si.business_id = p_business and si.sale_id = v_sale_id;

  return json_build_object(
    'status', 'ok', 'sale_id', v_sale_id, 'business_id', p_business,
    'subtotal_cents', v_eval.subtotal_cents, 'discount_total_cents', v_eval.discount_total_cents,
    'total_cents', v_eval.total_cents, 'gst_cents', v_eval.gst_cents,
    'replayed', false, 'points_earned', v_points, 'evaluation_id', v_eval.id,
    'sale', v_financial->'sale', 'items', v_items, 'stored_value', v_sv_json);
end $function$;
revoke all on function public.record_cart_sale(p_business uuid, p_client uuid, p_branch uuid, p_staff uuid, p_method text, p_idempotency_key text, p_lines jsonb, p_evaluation_id uuid, p_paid boolean) from public;
revoke all on function public.record_cart_sale(p_business uuid, p_client uuid, p_branch uuid, p_staff uuid, p_method text, p_idempotency_key text, p_lines jsonb, p_evaluation_id uuid, p_paid boolean) from postgres;
grant execute on function public.record_cart_sale(p_business uuid, p_client uuid, p_branch uuid, p_staff uuid, p_method text, p_idempotency_key text, p_lines jsonb, p_evaluation_id uuid, p_paid boolean) to postgres;
revoke all on function public.record_cart_sale(p_business uuid, p_client uuid, p_branch uuid, p_staff uuid, p_method text, p_idempotency_key text, p_lines jsonb, p_evaluation_id uuid, p_paid boolean) from service_role;
grant execute on function public.record_cart_sale(p_business uuid, p_client uuid, p_branch uuid, p_staff uuid, p_method text, p_idempotency_key text, p_lines jsonb, p_evaluation_id uuid, p_paid boolean) to service_role;
revoke all on function public.record_cart_sale(p_business uuid, p_client uuid, p_branch uuid, p_staff uuid, p_method text, p_idempotency_key text, p_lines jsonb, p_evaluation_id uuid, p_paid boolean) from authenticated;
grant execute on function public.record_cart_sale(p_business uuid, p_client uuid, p_branch uuid, p_staff uuid, p_method text, p_idempotency_key text, p_lines jsonb, p_evaluation_id uuid, p_paid boolean) to authenticated;

CREATE OR REPLACE FUNCTION public.reserve_checkout_sv_tender(p_business uuid, p_evaluation_id uuid, p_requested_cents integer, p_idempotency_key uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'app', 'pg_temp'
AS $function$
declare
  v_actor uuid := auth.uid();
  v_eval public.checkout_evaluations%rowtype;
  v_currency text;
  v_account uuid;
  v_existing public.checkout_sv_tenders%rowtype;
  v_prior public.checkout_sv_tenders%rowtype;
  v_available integer;
  v_amount integer;
  v_reserve jsonb;
  v_row_id uuid := gen_random_uuid();
begin
  if v_actor is null then
    raise exception 'authenticated staff required to add stored value to a checkout' using errcode = '42501';
  end if;
  if not app.has_perm(p_business, 'create_sales')
     or not app.can_module(p_business, 'till') then
    raise exception 'you do not have permission to add stored value to a checkout (create_sales)' using errcode = '42501';
  end if;
  if p_idempotency_key is null then
    raise exception 'a stored-value tender idempotency key is required' using errcode = '22023';
  end if;
  if p_requested_cents is null or p_requested_cents < 1 then
    raise exception 'a stored-value tender must request a whole number of at least 1 cent' using errcode = '22023';
  end if;

  select * into v_eval from public.checkout_evaluations
   where id = p_evaluation_id and business_id = p_business for update;
  if not found then
    raise exception 'checkout evaluation not found in this business' using errcode = '42501';
  end if;
  if not app.can_see_branch(p_business, v_eval.branch_id) then
    raise exception 'you are not permitted to tender for this branch scope' using errcode = '42501';
  end if;
  if v_eval.client_id is null then
    raise exception 'stored value needs a named customer on the checkout' using errcode = '22023';
  end if;
  if v_eval.consumed_at is not null then
    raise exception 'stale_evaluation: this checkout is already finalised; re-evaluate' using errcode = '22023';
  end if;
  if v_eval.expires_at <= now() then
    raise exception 'stale_evaluation: the checkout evaluation has expired; re-evaluate' using errcode = '22023';
  end if;

  -- Tender gate: authority live, no synthetic on live, redeem pause, currency.
  v_currency := app.sv_checkout_tender_gate(p_business, v_eval.client_id, null);

  -- Serialize per (business, evaluation) so a double opt-in is idempotent, not a double reservation.
  perform pg_advisory_xact_lock(hashtextextended('v67:tender:' || p_business::text || ':' || p_evaluation_id::text, 0));

  v_account := app.sv_ensure_account(p_business, v_eval.client_id);

  -- Exact replay: an active tender for THIS evaluation under THIS key returns unchanged.
  select * into v_existing from public.checkout_sv_tenders
   where business_id = p_business and evaluation_id = p_evaluation_id and status = 'reserved'
   order by created_at desc limit 1 for update;
  if found and v_existing.idempotency_key = p_idempotency_key then
    return jsonb_build_object(
      'status', 'ok', 'replayed', true, 'evaluation_id', p_evaluation_id, 'account_id', v_account,
      'reservation_id', v_existing.reservation_id, 'reserved_cents', v_existing.reserved_cents,
      'requested_cents', v_existing.requested_cents, 'bill_total_cents', v_eval.total_cents,
      'remaining_due_cents', greatest(v_eval.total_cents - v_existing.reserved_cents, 0), 'currency', v_currency);
  end if;

  -- Supersede any prior active tender for THIS account (re-evaluation / re-bind releases the prior).
  for v_prior in
    select * from public.checkout_sv_tenders
     where business_id = p_business and account_id = v_account and status = 'reserved'
     for update
  loop
    perform app.sv_release_core(p_business, v_prior.reservation_id, gen_random_uuid());
    update public.checkout_sv_tenders
       set status = 'released', released_reason = 'superseded', updated_at = now()
     where id = v_prior.id;
  end loop;

  v_available := coalesce(app.sv_available_balance(p_business, v_account), 0);
  v_amount := least(p_requested_cents, v_available, v_eval.total_cents);
  if v_amount < 1 then
    raise exception 'sv_no_coverage: this customer has no spendable stored value for this checkout' using errcode = '22023';
  end if;

  v_reserve := app.sv_reserve_core(p_business, v_account, v_amount, p_idempotency_key);

  -- The two unique constraints that can fire here are both "this customer's checkout hold is
  -- already spoken for", and both must reach the till as a TYPED refusal rather than a raw 23505:
  --   * checkout_sv_tenders_reservation_uk - reusing a reserve idempotency key across tokens.
  --     app.sv_reserve_core replays the stored result, so the SUPERSEDED (already released)
  --     reservation_id comes back and collides. Deterministic, not a race.
  --   * checkout_sv_tenders_active_uk - two tokens binding the same account concurrently, where the
  --     loser's supersede scan ran before the winner committed.
  -- Catching here changes nothing else: the idempotent-replay path returned long before this point,
  -- and both advisory locks are transaction-scoped, so the handler perturbs no lock or replay
  -- semantics - it only re-labels an error that already aborted the transaction.
  begin
    insert into public.checkout_sv_tenders(
      id, business_id, evaluation_id, account_id, reservation_id, reserve_operation_id, idempotency_key,
      requested_cents, reserved_cents, currency, status)
    values (
      v_row_id, p_business, p_evaluation_id, v_account,
      (v_reserve->>'reservation_id')::uuid, (v_reserve->>'operation_id')::uuid, p_idempotency_key,
      p_requested_cents, v_amount, v_currency, 'reserved');
  exception when unique_violation then
    raise exception 'sv_tender_conflict: this customer''s stored value is already held by another checkout or tender key; re-evaluate and bind with a fresh key'
      using errcode = '22023';
  end;

  insert into public.audit_log(business_id, actor, action, entity, entity_id, detail)
  values (p_business, v_actor, 'SV_CHECKOUT_TENDER_RESERVED', 'checkout_sv_tenders', v_row_id, jsonb_build_object(
    'evaluation_id', p_evaluation_id, 'account_id', v_account, 'reserved_cents', v_amount,
    'requested_cents', p_requested_cents, 'reservation_id', (v_reserve->>'reservation_id')::uuid));

  return jsonb_build_object(
    'status', 'ok', 'replayed', false, 'evaluation_id', p_evaluation_id, 'account_id', v_account,
    'reservation_id', (v_reserve->>'reservation_id')::uuid, 'reserved_cents', v_amount,
    'requested_cents', p_requested_cents, 'bill_total_cents', v_eval.total_cents,
    'remaining_due_cents', greatest(v_eval.total_cents - v_amount, 0), 'currency', v_currency);
end $function$;
revoke all on function public.reserve_checkout_sv_tender(p_business uuid, p_evaluation_id uuid, p_requested_cents integer, p_idempotency_key uuid) from public;
revoke all on function public.reserve_checkout_sv_tender(p_business uuid, p_evaluation_id uuid, p_requested_cents integer, p_idempotency_key uuid) from postgres;
grant execute on function public.reserve_checkout_sv_tender(p_business uuid, p_evaluation_id uuid, p_requested_cents integer, p_idempotency_key uuid) to postgres;
revoke all on function public.reserve_checkout_sv_tender(p_business uuid, p_evaluation_id uuid, p_requested_cents integer, p_idempotency_key uuid) from service_role;
grant execute on function public.reserve_checkout_sv_tender(p_business uuid, p_evaluation_id uuid, p_requested_cents integer, p_idempotency_key uuid) to service_role;
revoke all on function public.reserve_checkout_sv_tender(p_business uuid, p_evaluation_id uuid, p_requested_cents integer, p_idempotency_key uuid) from authenticated;
grant execute on function public.reserve_checkout_sv_tender(p_business uuid, p_evaluation_id uuid, p_requested_cents integer, p_idempotency_key uuid) to authenticated;

CREATE OR REPLACE FUNCTION public.set_expense_void(p_business uuid, p_expense uuid, p_void boolean)
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'app', 'pg_temp'
AS $function$
declare v_row expenses;
begin
  if not app.has_perm(p_business, 'view_finance')
     or not app.can_module(p_business, 'expenses') then
    raise exception 'you do not have permission to void an expense (view_finance)';
  end if;
  update expenses
     set voided_at = case when p_void then now() else null end,
         voided_by = case when p_void then auth.uid() else null end
   where id = p_expense and business_id = p_business
  returning * into v_row;
  if not found then raise exception 'expense not found'; end if;
  return row_to_json(v_row);
end $function$;
revoke all on function public.set_expense_void(p_business uuid, p_expense uuid, p_void boolean) from public;
revoke all on function public.set_expense_void(p_business uuid, p_expense uuid, p_void boolean) from postgres;
grant execute on function public.set_expense_void(p_business uuid, p_expense uuid, p_void boolean) to postgres;
revoke all on function public.set_expense_void(p_business uuid, p_expense uuid, p_void boolean) from service_role;
grant execute on function public.set_expense_void(p_business uuid, p_expense uuid, p_void boolean) to service_role;
revoke all on function public.set_expense_void(p_business uuid, p_expense uuid, p_void boolean) from authenticated;
grant execute on function public.set_expense_void(p_business uuid, p_expense uuid, p_void boolean) to authenticated;

CREATE OR REPLACE FUNCTION public.staff_get_reversal_workflows(p_business uuid, p_client uuid DEFAULT NULL::uuid, p_limit integer DEFAULT 50, p_mode text DEFAULT 'all'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'app', 'pg_temp'
AS $function$
declare
  v_actor uuid := auth.uid();
  v_staff uuid;
  v_role text;
  v_limit integer := case when p_limit = 0 then null else least(greatest(coalesce(p_limit, 50), 1), 100) end;
  v_mode text := lower(coalesce(nullif(btrim(p_mode), ''), 'all'));
  v_sales_total bigint := 0;
  v_sales jsonb := '[]'::jsonb;
  v_redemptions jsonb := '[]'::jsonb;
begin
  if v_actor is null then
    raise exception 'authenticated staff required' using errcode = '42501';
  end if;
  if v_mode not in ('all','package') then
    raise exception 'unsupported reversal workflow mode %', p_mode using errcode = '22023';
  end if;
  if not app.has_perm(p_business, 'refund_sales')
     or not app.can_module(p_business, 'sales') then
    raise exception 'refund_sales permission required' using errcode = '42501';
  end if;
  select s.id, s.role into v_staff, v_role
    from public.staff s
   where s.business_id = p_business
     and s.user_id = v_actor
     and s.active
     and 'refund_sales' = any(app.role_perms(s.role))
   order by case s.role when 'owner' then 0 when 'manager' then 1 else 2 end,
            s.created_at, s.id
   limit 1;
  if not found then
    raise exception 'active staff authorization required' using errcode = '42501';
  end if;
  if p_client is not null and not exists (
    select 1 from public.clients c
     where c.id = p_client and c.business_id = p_business
  ) then
    raise exception 'customer not found in this business' using errcode = '42501';
  end if;

  select coalesce(jsonb_agg(x.item order by x.occurred_at desc, x.id desc), '[]'::jsonb),
         coalesce(max(x.total_count), 0)
    into v_sales, v_sales_total
    from (
      select s.id, s.occurred_at, count(*) over() as total_count,
             jsonb_build_object(
               'id', s.id,
               'client_id', s.client_id,
               'customer_name', c.full_name,
               'branch_id', s.branch_id,
               'kind', s.kind,
               'amount_cents', s.amount_cents,
               'net_amount_cents', case
                 when s.reversal_of is null then s.amount_cents + coalesce(rev.amount_cents, 0)
                 else coalesce(original.amount_cents, 0) + s.amount_cents
               end,
               'occurred_at', s.occurred_at,
               'note', s.note,
               'is_reversal', s.reversal_of is not null,
               'original_sale_id', s.reversal_of,
               'correction_record_id', corr.correction_id,
               'correction_sale_id', case when corr.corr_original_sale_id = s.id
                 then corr.corr_replacement_sale_id end,
               'corrected_sale_id', case when corr.corr_replacement_sale_id = s.id
                 then corr.corr_original_sale_id end,
               'correction_role', case
                 when corr.corr_original_sale_id = s.id then 'original'
                 when corr.corr_replacement_sale_id = s.id then 'replacement'
                 when corr.corr_reversal_sale_id = s.id then 'reversal'
               end,
               'correction_before_cents', corr.corr_before_cents,
               'correction_after_cents', corr.corr_after_cents,
               'corrected_at', corr.corr_created_at,
               'reversal_sale_id', case when s.reversal_of is null then rev.id else s.id end,
               'reversal_reason', coalesce(rev.reversal_reason, s.reversal_reason),
               'reversed_at', coalesce(rev.occurred_at,
                 case when s.reversal_of is not null then s.occurred_at end),
               'is_package_session', pkg.consumption_id is not null,
               'no_money_refund', pkg.consumption_id is not null,
               'can_reverse', s.reversal_of is null and rev.id is null and (
                 (s.amount_cents > 0 and s.kind in ('service', 'retail', 'quick_sale'))
                 or (s.amount_cents = 0 and pkg.consumption_id is not null)
               ),
               'refusal_reason', case
                 when s.reversal_of is not null then 'This row is already a reversal.'
                 when rev.id is not null then 'This sale is already fully reversed.'
                 when s.amount_cents = 0 and pkg.consumption_id is null then 'This zero-value sale has no package-session provenance.'
                 when s.amount_cents <= 0 then 'This sale has no positive economic amount to reverse.'
                 when s.kind not in ('service', 'retail', 'quick_sale') then 'This sale type has no proven reversal path.'
                 else null
               end,
               'completed_result', coalesce(
                 fin.result,
                 case when pkg.reversal_sale_id is not null then jsonb_build_object(
                   'reversal_sale_id', pkg.reversal_sale_id,
                   'restored_sessions', 1,
                   'refunded_payment_cents', 0,
                   'no_money_refund', true,
                   'replayed', false
                 ) end
               )
             ) as item
        from public.sales s
        left join public.clients c
          on c.id = s.client_id and c.business_id = s.business_id
        left join public.sales original
          on original.id = s.reversal_of and original.business_id = s.business_id
        left join lateral (
          select r.id, r.amount_cents, r.occurred_at, r.reversal_reason
            from public.sales r
           where r.business_id = s.business_id and r.reversal_of = s.id
           order by r.occurred_at, r.id limit 1
        ) rev on true
        left join lateral (
          select jsonb_strip_nulls(jsonb_build_object(
            'reversal_sale_id',fo.result->'reversal_sale_id',
            'reversed_cents',fo.result->'reversed_cents',
            'refunded_payment_cents',fo.result->'refunded_payment_cents',
            'replayed',coalesce(fo.result->'replayed','false'::jsonb)
          )) as result
            from public.financial_operations fo
           where fo.business_id = s.business_id
             and fo.sale_id = s.id
             and fo.operation_type = 'sale_reversal'
             and fo.status = 'completed'
           order by fo.completed_at desc, fo.id desc limit 1
        ) fin on true
        left join lateral (
          select pc.id as consumption_id, pr.reversal_sale_id
            from public.package_session_consumptions pc
            left join public.package_session_reversals pr
              on pr.business_id = pc.business_id and pr.consumption_id = pc.id
           where pc.business_id = s.business_id
             and pc.sale_id = coalesce(s.reversal_of, s.id)
           limit 1
        ) pkg on true
        left join lateral (
          select corr.id as correction_id,
                 corr.original_sale_id as corr_original_sale_id,
                 corr.reversal_sale_id as corr_reversal_sale_id,
                 corr.replacement_sale_id as corr_replacement_sale_id,
                 corr.original_amount_cents as corr_before_cents,
                 corr.corrected_amount_cents as corr_after_cents,
                 corr.created_at as corr_created_at
            from public.sale_amount_corrections_v84 corr
           where corr.business_id = s.business_id
             and (corr.original_sale_id = s.id
               or corr.replacement_sale_id = s.id
               or corr.reversal_sale_id = s.id)
           order by corr.created_at desc, corr.id desc
           limit 1
        ) corr on true
       where s.business_id = p_business
         and (p_client is null or s.client_id = p_client)
         and app.can_see_branch(p_business, s.branch_id)
         and (v_mode = 'all' or pkg.consumption_id is not null)
       order by s.occurred_at desc, s.id desc
       limit v_limit
    ) x;

  select coalesce(jsonb_agg(x.item order by x.redeemed_at desc, x.id desc), '[]'::jsonb)
    into v_redemptions
    from (
      select lr.id, lr.redeemed_at,
             jsonb_build_object(
               'id', lr.id,
               'client_id', lr.client_id,
               'customer_name', c.full_name,
               'branch_id', scope.branch_id,
               'reward_name', lr.reward_name,
               'points_spent', lr.points_spent,
               'credit_cents', lr.credit_cents,
               'fulfillment_kind', lr.fulfillment_kind,
               'redeemed_at', lr.redeemed_at,
               'reversal_id', rr.id,
               'reversed_at', rr.created_at,
               'completed_result', rr.result,
               'has_exact_provenance', prov.id is not null
                 and prov.config_version_id is not distinct from lr.config_version_id
                 and coalesce(drains.drained_points, 0) = lr.points_spent
                 and points_ok.proven
                 and credit_state.proven,
               'credit_may_be_spent', coalesce(credit_state.may_be_spent, false),
               'can_reverse', rr.id is null
                 and prov.id is not null
                 and prov.config_version_id is not distinct from lr.config_version_id
                 and coalesce(drains.drained_points, 0) = lr.points_spent
                 and points_ok.proven
                 and credit_state.proven
                 and not coalesce(credit_state.may_be_spent, false),
               'refusal_reason', case
                 when rr.id is not null then 'This redemption is already reversed.'
                 when prov.id is null then 'Legacy or incomplete redemption provenance cannot be reversed safely.'
                 when prov.config_version_id is distinct from lr.config_version_id then 'Configuration provenance is inconsistent.'
                 when not coalesce(points_ok.proven, false) then 'Original points-ledger provenance is incomplete.'
                 when coalesce(drains.drained_points, 0) <> lr.points_spent then 'FEFO batch-drain provenance does not reconcile.'
                 when not coalesce(credit_state.proven, false) then 'Original loyalty credit provenance is missing or does not match.'
                 when coalesce(credit_state.may_be_spent, false) then 'Reward credit may have been spent; exact compensation is refused.'
                 else null
               end
             ) as item
        from public.loyalty_redemptions lr
        join public.clients c
          on c.id = lr.client_id and c.business_id = lr.business_id
        left join public.loyalty_redemption_provenance prov
          on prov.business_id = lr.business_id and prov.redemption_id = lr.id
        left join public.loyalty_redemption_reversals rr
          on rr.business_id = lr.business_id and rr.redemption_id = lr.id
        left join lateral (
          select nullif(lr.eligibility_snapshot #>> '{selected,branch_id}', '')::uuid as branch_id
        ) scope on true
        left join lateral (
          select coalesce(sum(d.drained_points), 0)::integer as drained_points
            from public.loyalty_redemption_batch_drains d
           where d.business_id = lr.business_id and d.redemption_id = lr.id
        ) drains on true
        left join lateral (
          select exists (
            select 1 from public.points_ledger pl
             where pl.id = prov.points_ledger_id
               and pl.business_id = lr.business_id
               and pl.client_id = lr.client_id
               and pl.points = -lr.points_spent
               and pl.config_version_id = lr.config_version_id
          ) as proven
        ) points_ok on true
        left join lateral (
          select
            case when lr.credit_cents<=0 then true else exists (
              select 1 from public.credit_ledger source
               where source.id=prov.credit_ledger_id
                 and source.business_id=lr.business_id
                 and source.client_id=lr.client_id
                 and source.entry_type='loyalty_earn'
                 and source.amount_cents=lr.credit_cents
                 and source.config_version_id=lr.config_version_id
            ) end as proven,
            case when lr.credit_cents<=0 then false else exists (
              select 1
                from public.credit_ledger source
                join public.credit_ledger spend
                  on spend.business_id=source.business_id
                 and spend.client_id=source.client_id
                 and spend.amount_cents<0
                 and spend.created_at>=source.created_at
                 and spend.id is distinct from rr.reversed_credit_ledger_id
               where source.id=prov.credit_ledger_id
                 and source.business_id=lr.business_id
                 and source.client_id=lr.client_id
                 and source.entry_type='loyalty_earn'
                 and source.amount_cents=lr.credit_cents
                 and source.config_version_id=lr.config_version_id
            ) end as may_be_spent
        ) credit_state on true
       where v_mode = 'all'
         and lr.business_id = p_business
         and (p_client is null or lr.client_id = p_client)
         and app.can_see_branch(p_business, scope.branch_id)
       order by lr.redeemed_at desc, lr.id desc
       limit v_limit
    ) x;

  return jsonb_build_object(
    'can_reverse', true,
    'actor_role', v_role,
    'mode', v_mode,
    'limit', v_limit,
    'bounded', v_limit is not null,
    'total_sales', v_sales_total,
    'may_have_more', case when v_limit is null then false else v_sales_total > v_limit end,
    'sales', v_sales,
    'redemptions', v_redemptions
  );
end $function$;
revoke all on function public.staff_get_reversal_workflows(p_business uuid, p_client uuid, p_limit integer, p_mode text) from public;
revoke all on function public.staff_get_reversal_workflows(p_business uuid, p_client uuid, p_limit integer, p_mode text) from postgres;
grant execute on function public.staff_get_reversal_workflows(p_business uuid, p_client uuid, p_limit integer, p_mode text) to postgres;
revoke all on function public.staff_get_reversal_workflows(p_business uuid, p_client uuid, p_limit integer, p_mode text) from authenticated;
grant execute on function public.staff_get_reversal_workflows(p_business uuid, p_client uuid, p_limit integer, p_mode text) to authenticated;
revoke all on function public.staff_get_reversal_workflows(p_business uuid, p_client uuid, p_limit integer, p_mode text) from service_role;
grant execute on function public.staff_get_reversal_workflows(p_business uuid, p_client uuid, p_limit integer, p_mode text) to service_role;

CREATE OR REPLACE FUNCTION public.update_expense_v285(p_business uuid, p_expense uuid, p_amount_cents integer, p_category text, p_note text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'app', 'pg_temp'
AS $function$
declare
  v_actor uuid := auth.uid();
  v_category text := nullif(btrim(coalesce(p_category, '')), '');
  v_row public.expenses%rowtype;
begin
  if v_actor is null or p_business is null or p_expense is null
     or not app.has_perm(p_business, 'view_finance')
     or not app.can_module(p_business, 'expenses') then
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
$function$;
revoke all on function public.update_expense_v285(p_business uuid, p_expense uuid, p_amount_cents integer, p_category text, p_note text) from public;
revoke all on function public.update_expense_v285(p_business uuid, p_expense uuid, p_amount_cents integer, p_category text, p_note text) from postgres;
grant execute on function public.update_expense_v285(p_business uuid, p_expense uuid, p_amount_cents integer, p_category text, p_note text) to postgres;
revoke all on function public.update_expense_v285(p_business uuid, p_expense uuid, p_amount_cents integer, p_category text, p_note text) from service_role;
grant execute on function public.update_expense_v285(p_business uuid, p_expense uuid, p_amount_cents integer, p_category text, p_note text) to service_role;
revoke all on function public.update_expense_v285(p_business uuid, p_expense uuid, p_amount_cents integer, p_category text, p_note text) from authenticated;
grant execute on function public.update_expense_v285(p_business uuid, p_expense uuid, p_amount_cents integer, p_category text, p_note text) to authenticated;
commit;
