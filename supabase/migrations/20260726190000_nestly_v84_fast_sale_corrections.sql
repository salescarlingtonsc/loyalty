-- NESTLY v84 - FAST, APPEND-ONLY SALE CORRECTIONS
-- Local build candidate. Do not apply to production before independent review.
--
-- A wrong quick-sale amount is corrected atomically by:
--   1. reversing the immutable original through the existing proven compensation engine;
--   2. removing the original sale's wholly-unspent point earn with explicit evidence;
--   3. recording a replacement quick sale through the existing financial writer; and
--   4. linking the full original -> reversal -> replacement chain in an append-only audit.
-- The original sale is never updated.

begin;

create table public.sale_amount_corrections_v84 (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete restrict,
  branch_id uuid not null,
  original_sale_id uuid not null,
  reversal_sale_id uuid not null,
  replacement_sale_id uuid not null,
  actor uuid not null,
  original_amount_cents integer not null check (original_amount_cents > 0),
  corrected_amount_cents integer not null check (corrected_amount_cents > 0),
  points_removed integer not null default 0 check (points_removed >= 0),
  points_compensation_ledger_id uuid,
  note text,
  idempotency_key text not null check (length(btrim(idempotency_key)) between 8 and 200),
  request_payload jsonb not null check (jsonb_typeof(request_payload) = 'object'),
  request_hash text not null check (request_hash = md5(request_payload::text)),
  result jsonb not null check (jsonb_typeof(result) = 'object'),
  created_at timestamptz not null default now(),
  constraint sale_amount_corrections_v84_changed_amount_ck
    check (corrected_amount_cents <> original_amount_cents),
  constraint sale_amount_corrections_v84_points_evidence_ck
    check (
      (points_removed = 0 and points_compensation_ledger_id is null)
      or (points_removed > 0 and points_compensation_ledger_id is not null)
    ),
  constraint sale_amount_corrections_v84_branch_fk
    foreign key (branch_id,business_id)
    references public.branches(id,business_id) on delete restrict,
  constraint sale_amount_corrections_v84_original_fk
    foreign key (original_sale_id,business_id)
    references public.sales(id,business_id) on delete restrict,
  constraint sale_amount_corrections_v84_reversal_fk
    foreign key (reversal_sale_id,business_id)
    references public.sales(id,business_id) on delete restrict,
  constraint sale_amount_corrections_v84_replacement_fk
    foreign key (replacement_sale_id,business_id)
    references public.sales(id,business_id) on delete restrict,
  constraint sale_amount_corrections_v84_points_compensation_fk
    foreign key (points_compensation_ledger_id,business_id)
    references public.points_ledger(id,business_id) on delete restrict,
  constraint sale_amount_corrections_v84_original_once unique (original_sale_id),
  constraint sale_amount_corrections_v84_reversal_once unique (reversal_sale_id),
  constraint sale_amount_corrections_v84_replacement_once unique (replacement_sale_id),
  constraint sale_amount_corrections_v84_idempotency_uk unique (business_id,idempotency_key)
);

create index sale_amount_corrections_v84_business_time_idx
  on public.sale_amount_corrections_v84(business_id,created_at desc,id desc);

alter table public.sale_amount_corrections_v84 enable row level security;
create policy sale_amount_corrections_v84_select
  on public.sale_amount_corrections_v84
  for select
  to authenticated
  using (
    app.has_perm(business_id,'view_finance')
    and app.can_see_branch(business_id,branch_id)
  );

revoke all privileges on table public.sale_amount_corrections_v84
  from public, anon, authenticated;
grant select on table public.sale_amount_corrections_v84 to authenticated;

create trigger trg_sale_amount_corrections_v84_append_only
  before update or delete on public.sale_amount_corrections_v84
  for each row execute function app.forbid_mutation();

comment on table public.sale_amount_corrections_v84 is
  'Append-only original -> reversal -> loyalty compensation -> replacement evidence for an atomic v84 amount correction.';

create or replace function public.reverse_sale_fast_v84(
  p_business uuid,
  p_sale uuid,
  p_note text,
  p_idempotency_key text
)
returns json
language sql
security invoker
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
  select public.reverse_sale(
    p_business,
    p_sale,
    case
      when nullif(btrim(p_note),'') is null then 'Staff-confirmed sale reversal'
      else 'Staff note: ' || btrim(p_note)
    end,
    p_idempotency_key,
    'Nestly quick reversal',
    'none'
  )
$$;

revoke all privileges on function public.reverse_sale_fast_v84(uuid,uuid,text,text)
  from public, anon, authenticated;
grant execute on function public.reverse_sale_fast_v84(uuid,uuid,text,text)
  to authenticated;

comment on function public.reverse_sale_fast_v84(uuid,uuid,text,text) is
  'Optional-note adapter over the existing exact reversal engine; authorization and compensation remain in reverse_sale.';

-- Normal reverse_sale intentionally keeps earned loyalty points. Amount correction is
-- different: it appends a replacement sale, so retaining the original earn would duplicate
-- value. Add one tightly-shaped, v84-only negative adjustment route. The compensation must
-- link to the reversal sale and the caller must still hold the source batch completely
-- unspent; correct_quick_sale_amount_v84 enforces and records both facts atomically.
create or replace function app.loyalty_ledger_write_guard()
returns trigger
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_token text;
  v_scope text;
begin
  if tg_table_name='points_ledger' then
    v_token:=nullif(current_setting('app.points_ledger_insert_id',true),'');
    v_scope:=nullif(current_setting('app.points_ledger_write_scope',true),'');
    if v_token is distinct from new.id::text or v_scope not in
       ('sale_trigger','redeem_points','adjust_points','points_expiry',
        'redemption_reversal','sale_amount_correction_v84') then
      raise exception 'points_ledger may only be appended by approved loyalty routes'
        using errcode='42501';
    end if;
    if (v_scope='sale_trigger'
          and (new.entry_type<>'earn' or new.points<=0 or new.sale_id is null))
       or (v_scope='redeem_points'
          and (new.entry_type<>'redeem' or new.points>=0 or new.sale_id is not null))
       or (v_scope='adjust_points'
          and (new.entry_type<>'adjust' or new.points=0 or new.sale_id is not null
               or new.actor is distinct from auth.uid()))
       or (v_scope='points_expiry'
          and (new.entry_type<>'expire' or new.points>=0 or new.sale_id is not null
               or new.actor is not null))
       or (v_scope='redemption_reversal'
          and (new.entry_type<>'adjust' or new.points<=0 or new.sale_id is not null
               or new.actor is distinct from auth.uid()))
       or (v_scope='sale_amount_correction_v84'
          and (new.entry_type<>'adjust' or new.points>=0 or new.sale_id is null
               or new.actor is distinct from auth.uid())) then
      raise exception 'points ledger entry does not match its internal route'
        using errcode='check_violation';
    end if;
  elsif tg_table_name='credit_ledger' then
    v_token:=nullif(current_setting('app.credit_ledger_insert_id',true),'');
    v_scope:=nullif(current_setting('app.credit_ledger_write_scope',true),'');
    if v_token is distinct from new.id::text or v_scope not in
       ('sale_trigger','redeem_points','redeem_gift_card','enroll_membership',
        'membership_renewal','credit_tender','sale_reversal','redemption_reversal') then
      raise exception 'credit_ledger may only be appended by approved routes'
        using errcode='42501';
    end if;
    if (v_scope='sale_trigger'
          and (new.entry_type not in ('loyalty_earn','referral_reward')
               or new.amount_cents<=0 or new.sale_id is null))
       or (v_scope='redeem_points'
          and (new.entry_type<>'loyalty_earn' or new.amount_cents<=0
               or new.sale_id is not null or new.payment_id is not null
               or new.actor is distinct from auth.uid()))
       or (v_scope='redeem_gift_card'
          and (new.entry_type<>'gift_card_load' or new.amount_cents<=0
               or new.sale_id is not null or new.payment_id is not null
               or new.actor is distinct from auth.uid()))
       or (v_scope='enroll_membership'
          and (new.entry_type<>'membership_credit' or new.amount_cents<=0
               or new.sale_id is null or new.payment_id is not null
               or new.actor is distinct from auth.uid()))
       or (v_scope='membership_renewal'
          and (new.entry_type<>'membership_credit' or new.amount_cents<=0
               or new.sale_id is null or new.payment_id is not null
               or new.actor is not null))
       or (v_scope='credit_tender'
          and (new.entry_type<>'spend' or new.amount_cents>=0
               or new.sale_id is null or new.payment_id is null
               or new.actor is distinct from auth.uid()))
       or (v_scope='sale_reversal'
          and (new.entry_type<>'manual_adjust' or new.amount_cents=0
               or new.sale_id is null or new.actor is distinct from auth.uid()))
       or (v_scope='redemption_reversal'
          and (new.entry_type<>'manual_adjust' or new.amount_cents>=0
               or new.sale_id is not null or new.payment_id is not null
               or new.actor is distinct from auth.uid())) then
      raise exception 'credit ledger entry does not match its internal route'
        using errcode='check_violation';
    end if;
  else
    raise exception 'unexpected loyalty ledger table';
  end if;
  return new;
end
$$;

revoke all privileges on function app.loyalty_ledger_write_guard()
  from public, anon, authenticated;

create or replace function public.correct_quick_sale_amount_v84(
  p_business uuid,
  p_sale uuid,
  p_corrected_amount_cents integer,
  p_idempotency_key text,
  p_note text default null
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
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
  v_points_earned integer := 0;
  v_result jsonb;
begin
  if v_actor is null
     or not app.has_perm(p_business,'refund_sales')
     or not app.has_perm(p_business,'create_sales') then
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
         or not exists (
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
  v_reverse := public.reverse_sale(
    p_business,
    v_original.id,
    'Amount corrected from '||v_original.amount_cents::text
      ||' to '||p_corrected_amount_cents::text||' cents'
      ||case when v_note is null then '' else ' · Staff note: '||v_note end,
    'v84:'||md5(v_key)||':reverse',
    'Nestly amount correction',
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
    insert into public.points_ledger(
      id,business_id,client_id,entry_type,points,sale_id,reference,actor
    ) values (
      v_points_compensation_id,p_business,v_original.client_id,'adjust',
      -v_original_points,v_reversal_sale,
      'sale amount correction: remove original earn for sale '||v_original.id,
      v_actor
    );
    perform set_config('app.points_ledger_insert_id','',true);
    perform set_config('app.points_ledger_write_scope','',true);

    update public.points_batches batch
       set remaining=0
     where batch.business_id=p_business
       and batch.client_id=v_original.client_id
       and batch.sale_id=v_original.id
       and batch.remaining=batch.earned;
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
    'points_earned',v_points_earned,
    'refunded_payment_cents',coalesce((v_reverse->>'refunded_payment_cents')::integer,0),
    'replacement_payment_id',nullif(v_replacement->>'payment_id','')::uuid,
    'replayed',false
  );

  insert into public.sale_amount_corrections_v84(
    business_id,branch_id,original_sale_id,reversal_sale_id,replacement_sale_id,
    actor,original_amount_cents,corrected_amount_cents,points_removed,
    points_compensation_ledger_id,note,idempotency_key,request_payload,request_hash,result
  ) values (
    p_business,v_original.branch_id,v_original.id,v_reversal_sale,v_replacement_sale,
    v_actor,v_original.amount_cents,p_corrected_amount_cents,v_original_points,
    v_points_compensation_id,v_note,v_key,v_payload,v_hash,v_result
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
$$;

revoke all privileges on function public.correct_quick_sale_amount_v84(uuid,uuid,integer,text,text)
  from public, anon, authenticated;
grant execute on function public.correct_quick_sale_amount_v84(uuid,uuid,integer,text,text)
  to authenticated;

comment on function public.correct_quick_sale_amount_v84(uuid,uuid,integer,text,text) is
  'Atomically reverses a positive quick sale, removes a wholly-unspent original point earn, and records its corrected append-only replacement; partial/mixed/non-cash paid states refuse.';

commit;
