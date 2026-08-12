-- NESTLY v290 — SERVER-SIDE DEBT CLOSURE
--
-- Six server truths that earlier audits recorded and then deferred. Each one is the half of a
-- gap that cannot be closed in the browser.
--
--   1  staff_services WAS WRITABLE BY ANY MEMBER — the exact defect v285 fixed on staff_branches.
--      v11a created ONE `for all` policy: using app.is_salon_member(business_id), with check
--      app.is_salon_owner(business_id). A WITH CHECK expression is consulted only for the rows a
--      statement WRITES, so DELETE never evaluated the owner half and the member-wide USING clause
--      was the only test it faced. Any staff member could therefore unassign any colleague from any
--      service. v285 deliberately left this table alone ("it carries the same defect and belongs to
--      a different audit's scope"); this is that scope. The shape is identical to v285's: read for
--      members, write for the owner, expressed per command so the owner test is attached to the
--      DELETE path explicitly rather than through a clause DELETE does not evaluate.
--
--   2  THE RESIDUAL BOOKING GATE. v288 made the two decision gates conditional on
--      app.business_has_appointments_module_v288, and then section 8 of db/tests/v288_a2_gap_closure
--      pinned the fact that confirmation STILL failed 42501 — because the confirm path calls
--      public.book_appointment_smart_v47, whose own wrapper demands
--      require_branch_module_v94(...,'appointments','rw') unconditionally, and whose base demands
--      app.can_module_write(p_business,'appointments'). In a sector whose module bundle has no
--      appointments (fnb, bar) that right can never be held by anyone, owner included, so a cafe or
--      bar could only ever DECLINE the bookings its own public page produced.
--      Both gates are made conditional here, and — this is the part v288's decide-gate fix did not
--      need — where appointments is absent the BOOKINGS write boundary is demanded in its place.
--      The call is therefore never unauthorised: it is authorised by the module the request lives
--      in. Where the platform DOES grant appointments (including read-only, which must still
--      refuse) nothing changes at all.
--
--   3  A "CORRECTED" SALE LOOKED LIKE AN UNRELATED REVERSAL PAIR. correct_quick_sale_amount_v84
--      records its three-row chain in public.sale_amount_corrections_v84 (original / reversal /
--      replacement), but staff_get_reversal_workflows returned none of that linkage and public.sales
--      has no corrected_by column — so the Sales ledger's `Corrected` state, which the browser keys
--      on w.correction_sale_id || w.corrected_sale_id || s.corrected_by, was unreachable. A v84
--      amount correction rendered as a reversal and an unrelated new sale.
--      The workflow reader is spliced to carry the linkage that already exists. The key NAMES the
--      client keys on are unchanged; the new keys sit beside them.
--
--   4  THE CUSTOMER BUCKET COUNTS WERE COMPUTED BY PAGING THE WHOLE DIRECTORY. The Customers page
--      called staff_list_customers_v155 once per 100 customers, twice per open, purely to count
--      three inactivity buckets in the browser — 2*ceil(N/100) round trips per open. At the target
--      scale for launch that is the page's dominant cost and its dominant failure mode.
--      staff_customer_bucket_counts_v290 answers all of it in one call, with the SAME authorisation
--      and the SAME branch-scope resolution staff_list_customers_v155 uses (copied, not approximated
--      — see the auth block and the resolve_reporting_branch_scope_v155 call below), so the number
--      on a card can never come from a wider scope than the list beneath it.
--      staff_list_customers_v155 also gains one accepted bucket, 'all_inactive' (last valid visit
--      30 or more complete Singapore days ago). V287 had to narrow the dashboard tile to 30-59
--      precisely because "all inactive" was not expressible as a destination; it is now, so the
--      tile can count what it says it counts and land on exactly that group.
--
--   5  ⚖️ PDPA ERASURE, SERVER HALF. erase_client_v290 ANONYMISES a customer in place rather than
--      deleting the row: the append-only credit and points ledgers reference clients, and CLAUDE.md
--      makes those ledgers the system of record. A hard delete would either break that reference or
--      silently rewrite money history, so identity is removed and the economic record is left exactly
--      as it was. Owner-only. It REFUSES while the business still holds something of the customer's
--      — a positive store-credit balance, any stored-value participation, or any bottle still in
--      storage — because erasing the identity attached to those would strand them.
--      ⚖️ This function is an engineering control, not a legal opinion. Nothing here claims PDPA
--      compliance, and the retention/response obligations around an erasure request are for counsel.
--
--   6  PROMOTIONS COULD BE SHOWN BUT NEVER RECORDED. A published promotion's "Show at counter" call
--      to action changed a button label and nothing else: no staff verification, and no number for
--      the funnel. This reuses the v89 reward-intent shape exactly — a short-lived intent, a token
--      the customer renders as a QR, a staff scan that marks it redeemed once — over two new
--      append-only tables. It computes NO discount and touches no ledger: it RECORDS that a named
--      customer presented a named promotion and that staff accepted it.
--
-- Nothing here writes credit_ledger, points_ledger or sales. No VALUE_TABLE is written.
-- Not applied to production at authoring time. Verified rolled back in
-- db/tests/v290_server_debt_closure.sql.

begin;

-- ---------------------------------------------------------------------------
-- 1. staff_services: read for members, write for the owner, per command.
-- ---------------------------------------------------------------------------

drop policy if exists staff_services_all on public.staff_services;

create policy staff_services_select on public.staff_services
  for select to authenticated
  using (app.is_salon_member(business_id));

create policy staff_services_insert on public.staff_services
  for insert to authenticated
  with check (app.is_salon_owner(business_id));

create policy staff_services_update on public.staff_services
  for update to authenticated
  using (app.is_salon_owner(business_id))
  with check (app.is_salon_owner(business_id));

create policy staff_services_delete on public.staff_services
  for delete to authenticated
  using (app.is_salon_owner(business_id));

revoke all on public.staff_services from anon;
grant select, insert, update, delete on public.staff_services to authenticated;

-- ---------------------------------------------------------------------------
-- 2. The residual booking gate in book_appointment_smart_v47.
-- ---------------------------------------------------------------------------

-- The v94 wrapper. Splice against the DEPLOYED definition, never a guessed one.
do $v290_smart_wrapper$
declare
  v_source text;
  v_hits integer;
  v_needle constant text :=
$needle$  perform app.require_branch_module_v94(
    p_business,p_branch,'appointments','rw'
  );$needle$;
  v_patch constant text :=
$needle$  if app.business_has_appointments_module_v288(p_business,p_branch) then
    perform app.require_branch_module_v94(
      p_business,p_branch,'appointments','rw'
    );
  else
    perform app.require_branch_module_v94(
      p_business,p_branch,'bookings','rw'
    );
  end if;$needle$;
begin
  v_source := pg_get_functiondef(
    'public.book_appointment_smart_v47(uuid,uuid,uuid,uuid,timestamptz,integer,uuid,text,text,text)'::regprocedure);
  if position('business_has_appointments_module_v288' in v_source) > 0 then
    raise notice 'v290: the smart-booking wrapper already carries the sector condition';
    return;
  end if;
  v_hits := (length(v_source) - length(replace(v_source, v_needle, ''))) / length(v_needle);
  if v_hits <> 1 then
    raise exception 'v290: expected exactly 1 appointments gate in the v47 wrapper, found %', v_hits;
  end if;
  execute replace(v_source, v_needle, v_patch);

  v_source := pg_get_functiondef(
    'public.book_appointment_smart_v47(uuid,uuid,uuid,uuid,timestamptz,integer,uuid,text,text,text)'::regprocedure);
  if position('business_has_appointments_module_v288' in v_source) = 0
     or position($check$'bookings','rw'$check$ in v_source) = 0
     or position($check$'appointments','rw'$check$ in v_source) = 0 then
    raise exception 'v290: the sector condition did not land in the v47 wrapper';
  end if;
  raise notice 'v290: smart booking demands appointments where the sector has them, bookings where it does not';
end
$v290_smart_wrapper$;

-- The base function carries the same unconditional demand, combined with can_see_branch.
do $v290_smart_base$
declare
  v_source text;
  v_hits integer;
  v_needle constant text :=
$needle$  if auth.uid() is null
     or not app.can_module_write(p_business, 'appointments')
     or not app.can_see_branch(p_business, p_branch) then$needle$;
  v_patch constant text :=
$needle$  if auth.uid() is null
     or (case
       when app.business_has_appointments_module_v288(p_business, p_branch)
         then not app.can_module_write(p_business, 'appointments')
         else not app.can_module_write(p_business, 'bookings')
     end)
     or not app.can_see_branch(p_business, p_branch) then$needle$;
begin
  v_source := pg_get_functiondef(
    'public.book_appointment_smart_v47_v94_base(uuid,uuid,uuid,uuid,timestamptz,integer,uuid,text,text,text)'::regprocedure);
  if position('business_has_appointments_module_v288' in v_source) > 0 then
    raise notice 'v290: the smart-booking base already carries the sector condition';
    return;
  end if;
  v_hits := (length(v_source) - length(replace(v_source, v_needle, ''))) / length(v_needle);
  if v_hits <> 1 then
    raise exception 'v290: expected exactly 1 appointments gate in the v47 base, found %', v_hits;
  end if;
  execute replace(v_source, v_needle, v_patch);

  v_source := pg_get_functiondef(
    'public.book_appointment_smart_v47_v94_base(uuid,uuid,uuid,uuid,timestamptz,integer,uuid,text,text,text)'::regprocedure);
  if position('business_has_appointments_module_v288' in v_source) = 0
     or position($check$can_module_write(p_business, 'bookings')$check$ in v_source) = 0
     or position($check$can_see_branch(p_business, p_branch)$check$ in v_source) = 0 then
    raise exception 'v290: the sector condition did not land in the v47 base, or a gate was lost';
  end if;
  raise notice 'v290: the smart-booking base now authorises through the module the sector actually has';
end
$v290_smart_base$;

-- ---------------------------------------------------------------------------
-- 3. The correction linkage the Sales ledger already expects.
-- ---------------------------------------------------------------------------

do $v290_reversal_workflows$
declare
  v_source text;
  v_hits integer;
  v_join_needle constant text :=
$needle$        ) pkg on true
       where s.business_id = p_business$needle$;
  v_join_patch constant text :=
$needle$        ) pkg on true
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
       where s.business_id = p_business$needle$;
  v_json_needle constant text :=
$needle$               'is_reversal', s.reversal_of is not null,
               'original_sale_id', s.reversal_of,$needle$;
  v_json_patch constant text :=
$needle$               'is_reversal', s.reversal_of is not null,
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
               'corrected_at', corr.corr_created_at,$needle$;
begin
  v_source := pg_get_functiondef(
    'public.staff_get_reversal_workflows(uuid,uuid,integer,text)'::regprocedure);
  if position('sale_amount_corrections_v84' in v_source) > 0 then
    raise notice 'v290: the reversal-workflow reader already carries the correction linkage';
    return;
  end if;

  v_hits := (length(v_source) - length(replace(v_source, v_join_needle, ''))) / length(v_join_needle);
  if v_hits <> 1 then
    raise exception 'v290: expected exactly 1 package lateral boundary, found %', v_hits;
  end if;
  v_source := replace(v_source, v_join_needle, v_join_patch);

  v_hits := (length(v_source) - length(replace(v_source, v_json_needle, ''))) / length(v_json_needle);
  if v_hits <> 1 then
    raise exception 'v290: expected exactly 1 reversal json anchor, found %', v_hits;
  end if;
  v_source := replace(v_source, v_json_needle, v_json_patch);
  execute v_source;

  v_source := pg_get_functiondef(
    'public.staff_get_reversal_workflows(uuid,uuid,integer,text)'::regprocedure);
  if position('sale_amount_corrections_v84' in v_source) = 0
     or position($check$'correction_sale_id'$check$ in v_source) = 0
     or position($check$'corrected_sale_id'$check$ in v_source) = 0
     or position($check$'reversal_sale_id', case when s.reversal_of is null$check$ in v_source) = 0 then
    raise exception 'v290: the correction linkage did not land, or an existing key was lost';
  end if;
  raise notice 'v290: a corrected sale now names its correction instead of looking like a stray reversal';
end
$v290_reversal_workflows$;

-- ---------------------------------------------------------------------------
-- 4. One call for the inactivity bucket counts, and an expressible "all inactive".
-- ---------------------------------------------------------------------------

do $v290_bucket_arg$
declare
  v_source text;
  v_hits integer;
  v_guard_needle constant text :=
$needle$     and p_inactive_bucket not in ('30_59','60_89','90_plus','never') then$needle$;
  v_guard_patch constant text :=
$needle$     and p_inactive_bucket not in ('30_59','60_89','90_plus','never','all_inactive') then$needle$;
  v_filter_needle constant text :=
$needle$        or (p_inactive_bucket = '90_plus' and visit.last_visit_at is not null
          and ((v_as_of at time zone 'Asia/Singapore')::date-
            (visit.last_visit_at at time zone 'Asia/Singapore')::date) >= 90)$needle$;
  v_filter_patch constant text :=
$needle$        or (p_inactive_bucket = '90_plus' and visit.last_visit_at is not null
          and ((v_as_of at time zone 'Asia/Singapore')::date-
            (visit.last_visit_at at time zone 'Asia/Singapore')::date) >= 90)
        or (p_inactive_bucket = 'all_inactive' and visit.last_visit_at is not null
          and ((v_as_of at time zone 'Asia/Singapore')::date-
            (visit.last_visit_at at time zone 'Asia/Singapore')::date) >= 30)$needle$;
begin
  v_source := pg_get_functiondef(
    'public.staff_list_customers_v155(uuid,text,text,text,uuid[],uuid,integer,integer)'::regprocedure);
  if position('all_inactive' in v_source) > 0 then
    raise notice 'v290: the customer directory already accepts the all_inactive bucket';
    return;
  end if;

  v_hits := (length(v_source) - length(replace(v_source, v_guard_needle, ''))) / length(v_guard_needle);
  if v_hits <> 1 then
    raise exception 'v290: expected exactly 1 bucket guard in v155, found %', v_hits;
  end if;
  v_source := replace(v_source, v_guard_needle, v_guard_patch);

  v_hits := (length(v_source) - length(replace(v_source, v_filter_needle, ''))) / length(v_filter_needle);
  if v_hits <> 1 then
    raise exception 'v290: expected exactly 1 90_plus filter arm in v155, found %', v_hits;
  end if;
  v_source := replace(v_source, v_filter_needle, v_filter_patch);
  execute v_source;

  v_source := pg_get_functiondef(
    'public.staff_list_customers_v155(uuid,text,text,text,uuid[],uuid,integer,integer)'::regprocedure);
  if position($check$'30_59','60_89','90_plus','never','all_inactive'$check$ in v_source) = 0
     or position($check$p_inactive_bucket = 'all_inactive'$check$ in v_source) = 0
     or position($check$p_inactive_bucket = 'never'$check$ in v_source) = 0 then
    raise exception 'v290: the all_inactive bucket did not land, or an existing bucket was lost';
  end if;
  raise notice 'v290: the customer directory can express "all inactive" as a destination';
end
$v290_bucket_arg$;

-- The counts. Authorisation and branch-scope resolution are copied from
-- staff_list_customers_v155 so the card and the list beneath it always agree.
create or replace function public.staff_customer_bucket_counts_v290(
  p_business uuid,
  p_search text default null,
  p_scope_mode text default 'all',
  p_branch_ids uuid[] default array[]::uuid[],
  p_operational_branch uuid default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_as_of timestamptz := statement_timestamp();
  v_search text := lower(btrim(coalesce(p_search,'')));
  v_phone_search text := regexp_replace(coalesce(p_search,''),'[^0-9]','','g');
  v_scope_ids uuid[];
  v_scope_label text;
  v_scope_is_whole_business boolean := false;
  v_result jsonb;
begin
  if length(v_phone_search)=10 and left(v_phone_search,2)='65' then
    v_phone_search := right(v_phone_search,8);
  end if;
  if auth.uid() is null or not app.can_module_read(p_business,'clients') then
    raise exception 'customer read access required' using errcode='42501';
  end if;

  select coalesce(array_agg(scope.branch_id order by scope.branch_name),array[]::uuid[])
    into v_scope_ids
  from app.resolve_reporting_branch_scope_v155(
    p_business,p_scope_mode,p_branch_ids,p_operational_branch
  ) scope;
  v_scope_label := app.reporting_scope_label_v155(
    p_business,p_scope_mode,p_branch_ids,p_operational_branch
  );
  select not exists(
    select 1
    from public.branches branch
    where branch.business_id = p_business
      and coalesce(branch.active,true)
      and not (branch.id = any(v_scope_ids))
  ) into v_scope_is_whole_business;

  with visit_facts as materialized (
    select sale.client_id,max(sale.occurred_at) as last_visit_at
    from public.sales sale
    where sale.business_id = p_business
      and sale.client_id is not null
      and sale.counts_as_visit
      and sale.reversal_of is null
      and sale.occurred_at <= v_as_of
      and sale.branch_id = any(v_scope_ids)
      and not exists(
        select 1 from public.sales reversal
        where reversal.business_id = sale.business_id
          and reversal.reversal_of = sale.id
          and reversal.created_at <= v_as_of
      )
    group by sale.client_id
  ), customer_scope as materialized (
    select distinct sale.client_id
    from public.sales sale
    where sale.business_id = p_business
      and sale.client_id is not null
      and sale.counts_as_visit
      and sale.reversal_of is null
      and sale.branch_id = any(v_scope_ids)
  ), customer_rows as materialized (
    select customer.id,
      case when visit.last_visit_at is null then null
        else ((v_as_of at time zone 'Asia/Singapore')::date-
          (visit.last_visit_at at time zone 'Asia/Singapore')::date)::integer
      end as days_since_last_visit
    from public.clients customer
    left join visit_facts visit on visit.client_id = customer.id
    where customer.business_id = p_business
      and (
        v_scope_is_whole_business
        or exists(select 1 from customer_scope scoped where scoped.client_id = customer.id)
      )
      and (
        v_search = ''
        or position(v_search in lower(customer.full_name)) > 0
        or (length(v_phone_search) >= 4 and
          position(v_phone_search in coalesce(customer.phone_norm,'')) > 0)
      )
  )
  select jsonb_build_object(
    'status','ok',
    'as_of',v_as_of,
    'scope',jsonb_build_object(
      'mode',coalesce(p_scope_mode,'all'),
      'label',v_scope_label,
      'branch_ids',to_jsonb(v_scope_ids),
      'whole_business',v_scope_is_whole_business
    ),
    'counts',jsonb_build_object(
      '30_59',count(*) filter (
        where days_since_last_visit between 30 and 59),
      '60_89',count(*) filter (
        where days_since_last_visit between 60 and 89),
      '90_plus',count(*) filter (
        where days_since_last_visit >= 90),
      'all_inactive',count(*) filter (
        where days_since_last_visit >= 30),
      'never',count(*) filter (
        where v_scope_is_whole_business and days_since_last_visit is null),
      'active',count(*) filter (
        where days_since_last_visit is not null and days_since_last_visit < 30),
      'total',count(*)
    )
  ) into v_result
  from customer_rows;

  return v_result;
end
$$;

revoke all on function public.staff_customer_bucket_counts_v290(uuid, text, text, uuid[], uuid)
  from public, anon;
grant execute on function public.staff_customer_bucket_counts_v290(uuid, text, text, uuid[], uuid)
  to authenticated;

-- ---------------------------------------------------------------------------
-- 5. ⚖️ PDPA erasure, server half.
-- ---------------------------------------------------------------------------

-- Append-only evidence. RLS is enabled with NO policy at all, so the table is unreadable and
-- unwritable through the data API by anyone, super admin included; the two SECURITY DEFINER
-- functions below are the only doors.
create table if not exists public.client_erasures_v290 (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  client_id uuid not null references public.clients(id) on delete restrict,
  actor uuid,
  reason text not null,
  idempotency_key text not null,
  erased_fields jsonb not null,
  created_at timestamptz not null default now()
);
create unique index if not exists client_erasures_v290_idem_uk
  on public.client_erasures_v290 (business_id, idempotency_key);
create unique index if not exists client_erasures_v290_client_uk
  on public.client_erasures_v290 (business_id, client_id);
alter table public.client_erasures_v290 enable row level security;
revoke all on public.client_erasures_v290 from anon, authenticated;

create or replace function public.erase_client_v290(
  p_business uuid,
  p_client uuid,
  p_reason text,
  p_idem text
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_actor uuid := auth.uid();
  v_reason text := nullif(btrim(coalesce(p_reason,'')),'');
  v_key text := nullif(btrim(coalesce(p_idem,'')),'');
  v_client public.clients%rowtype;
  v_existing public.client_erasures_v290%rowtype;
  v_credit bigint := 0;
  v_bottles integer := 0;
  v_sv integer := 0;
  v_fields jsonb;
  v_id uuid;
begin
  if v_actor is null or p_business is null or p_client is null
     or not app.is_salon_owner(p_business) then
    raise exception 'customer erasure requires the workspace owner' using errcode = '42501';
  end if;
  if v_reason is null or char_length(v_reason) not between 4 and 500 then
    raise exception 'an erasure reason of 4 to 500 characters is required' using errcode = '22023';
  end if;
  if v_key is null or char_length(v_key) not between 8 and 200 then
    raise exception 'an idempotency key of 8 to 200 characters is required' using errcode = '22023';
  end if;

  perform pg_advisory_xact_lock(
    hashtextextended(p_business::text||':client-erasure-v290:'||v_key,0));

  select * into v_existing from public.client_erasures_v290 record
   where record.business_id = p_business
     and (record.idempotency_key = v_key or record.client_id = p_client);
  if found then
    if v_existing.client_id is distinct from p_client
       or v_existing.idempotency_key is distinct from v_key then
      raise exception 'this customer or key was already used for a different erasure'
        using errcode = '23505';
    end if;
    return jsonb_build_object('status','duplicate_ignored','erasure_id',v_existing.id,
      'client_id',v_existing.client_id,'erased_at',v_existing.created_at);
  end if;

  select * into v_client from public.clients customer
   where customer.id = p_client and customer.business_id = p_business
   for update;
  if not found then
    raise exception 'customer not found in this business' using errcode = '22023';
  end if;

  -- Three refusals. Each is something the business still HOLDS that belongs to this person; the
  -- identity that names the owner of it cannot be removed while it is outstanding.
  select coalesce(sum(ledger.amount_cents),0)::bigint into v_credit
    from public.credit_ledger ledger
   where ledger.business_id = p_business and ledger.client_id = p_client;
  select count(*)::integer into v_bottles
    from public.bar_bottles bottle
   where bottle.business_id = p_business and bottle.client_id = p_client
     and bottle.status in ('stored','called','at_table','expired');
  -- Stored value blocks on PARTICIPATION, not on a computed balance: the lot/movement sign
  -- convention belongs to PS-2 and this function must never guess a balance in order to decide
  -- whether it is safe to erase somebody. It fails closed.
  select count(*)::integer into v_sv
    from public.sv_lots lot
    join public.sv_accounts account on account.id = lot.account_id
   where account.business_id = p_business and account.client_id = p_client;

  if v_credit > 0 or v_bottles > 0 or v_sv > 0 then
    return jsonb_build_object('status','refused','reason','holdings_outstanding',
      'credit_balance_cents',v_credit,'bottles_in_storage',v_bottles,
      'stored_value_lots',v_sv);
  end if;

  v_fields := jsonb_build_object(
    'full_name',v_client.full_name is not null,
    'phone',v_client.phone is not null,
    'email',v_client.email is not null,
    'birth_date',v_client.birth_date is not null,
    'gender',v_client.gender is not null,
    'notes',v_client.notes is not null,
    'tags',coalesce(cardinality(v_client.tags),0) > 0,
    'referral_code',v_client.referral_code is not null);

  -- Anonymised in place. phone_norm is a GENERATED column and clears itself with phone.
  update public.clients customer
     set full_name = 'Erased customer',
         phone = null,
         email = null,
         birth_date = null,
         gender = null,
         notes = null,
         tags = array[]::text[],
         referral_code = null,
         marketing_consent = false
   where customer.id = p_client and customer.business_id = p_business;

  insert into public.client_erasures_v290(
    business_id, client_id, actor, reason, idempotency_key, erased_fields
  ) values (
    p_business, p_client, v_actor, v_reason, v_key, v_fields
  ) returning id into v_id;

  insert into public.audit_log(business_id, actor, action, entity, entity_id, detail)
  values (
    p_business, v_actor, 'CLIENT_ERASED_V290', 'clients', p_client,
    jsonb_build_object('erasure_id',v_id,'reason',v_reason,'erased_fields',v_fields));

  return jsonb_build_object('status','erased','erasure_id',v_id,'client_id',p_client,
    'erased_fields',v_fields);
end;
$$;

revoke all on function public.erase_client_v290(uuid, uuid, text, text) from public, anon;
grant execute on function public.erase_client_v290(uuid, uuid, text, text) to authenticated;

create or replace function public.list_client_erasures_v290(
  p_business uuid default null,
  p_limit integer default 100
)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_limit integer := least(greatest(coalesce(p_limit,100),1),500);
  v_items jsonb;
begin
  if not app.is_super_admin() then
    raise exception 'platform administrator required' using errcode = '42501';
  end if;
  select coalesce(jsonb_agg(jsonb_build_object(
    'id',record.id,
    'business_id',record.business_id,
    'business_name',business.name,
    'client_id',record.client_id,
    'actor',record.actor,
    'reason',record.reason,
    'erased_fields',record.erased_fields,
    'created_at',record.created_at
  ) order by record.created_at desc, record.id desc),'[]'::jsonb)
    into v_items
    from (
      select * from public.client_erasures_v290 row_in
       where p_business is null or row_in.business_id = p_business
       order by row_in.created_at desc, row_in.id desc
       limit v_limit
    ) record
    left join public.businesses business on business.id = record.business_id;
  return jsonb_build_object('status','ok','limit',v_limit,'items',v_items);
end;
$$;

revoke all on function public.list_client_erasures_v290(uuid, integer) from public, anon;
grant execute on function public.list_client_erasures_v290(uuid, integer) to authenticated;

-- ---------------------------------------------------------------------------
-- 6. Promotion redemption intents.
-- ---------------------------------------------------------------------------

create table if not exists public.promotion_redemption_intents_v290 (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  promotion_id uuid not null references public.business_customer_content_v95(id) on delete cascade,
  identity_id uuid not null,
  auth_user_id uuid not null,
  client_id uuid not null,
  token_hash text not null,
  status text not null default 'pending'
    check (status in ('pending','redeemed','expired')),
  idempotency_key uuid not null,
  request_hash text not null,
  expires_at timestamptz not null,
  redeemed_at timestamptz,
  redeemed_by uuid,
  created_at timestamptz not null default now()
);
create unique index if not exists promotion_redemption_intents_v290_idem_uk
  on public.promotion_redemption_intents_v290 (identity_id, idempotency_key);
create unique index if not exists promotion_redemption_intents_v290_open_uk
  on public.promotion_redemption_intents_v290 (business_id, promotion_id, client_id)
  where status = 'pending';
create index if not exists promotion_redemption_intents_v290_token_ix
  on public.promotion_redemption_intents_v290 (token_hash);
alter table public.promotion_redemption_intents_v290 enable row level security;
revoke all on public.promotion_redemption_intents_v290 from anon, authenticated;

-- Append-only. One row per accepted presentation; nothing updates or deletes it.
create table if not exists public.promotion_redemptions_v290 (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  promotion_id uuid not null references public.business_customer_content_v95(id) on delete cascade,
  intent_id uuid not null references public.promotion_redemption_intents_v290(id) on delete restrict,
  client_id uuid not null,
  branch_id uuid,
  staff_actor uuid not null,
  idempotency_key text not null,
  detail jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);
create unique index if not exists promotion_redemptions_v290_intent_uk
  on public.promotion_redemptions_v290 (intent_id);
create unique index if not exists promotion_redemptions_v290_idem_uk
  on public.promotion_redemptions_v290 (business_id, idempotency_key);
alter table public.promotion_redemptions_v290 enable row level security;
revoke all on public.promotion_redemptions_v290 from anon, authenticated;

create or replace function public.customer_create_promotion_intent_v290(
  p_business uuid,
  p_promotion uuid,
  p_idempotency_key uuid
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_identity uuid;
  v_client uuid;
  v_promotion public.business_customer_content_v95%rowtype;
  v_existing public.promotion_redemption_intents_v290%rowtype;
  v_open public.promotion_redemption_intents_v290%rowtype;
  v_limit integer;
  v_used integer;
  v_token text;
  v_request_hash text;
  v_expires timestamptz := now() + interval '5 minutes';
  v_intent uuid := gen_random_uuid();
begin
  if p_idempotency_key is null or p_business is null or p_promotion is null then
    raise exception 'business, promotion and idempotency key are required' using errcode = '22023';
  end if;
  v_identity := app.v31_current_identity();
  v_request_hash := app.v89_sha256(p_business::text||':promotion:'||p_promotion::text);

  perform pg_advisory_xact_lock(hashtextextended(
    'v290:promotion-intent:'||v_identity::text||':'||p_idempotency_key::text,0));

  select * into v_existing from public.promotion_redemption_intents_v290 intent
   where intent.identity_id = v_identity and intent.idempotency_key = p_idempotency_key
   for update;
  if found then
    if v_existing.request_hash <> v_request_hash then
      raise exception 'idempotency key conflicts with another promotion intent'
        using errcode = '23505';
    end if;
    return jsonb_build_object('status',v_existing.status,'intent_id',v_existing.id,
      'promotion_id',v_existing.promotion_id,'expires_at',v_existing.expires_at,
      'qr_token',app.v89_redemption_token(v_identity,p_business,'promotion_v290',
        v_existing.promotion_id,p_idempotency_key),
      'replayed',true);
  end if;

  select link.client_id into v_client
    from public.customer_links link
   where link.identity_id = v_identity and link.auth_user_id = auth.uid()
     and link.business_id = p_business and link.state = 'verified'
   for share;
  if not found then
    raise exception 'verified customer link required' using errcode = '42501';
  end if;

  select * into v_promotion from public.business_customer_content_v95 content
   where content.id = p_promotion
     and content.business_id = p_business
     and content.content_type = 'offer'
     and content.active
     and content.branch_id is null
     and (content.starts_at is null or content.starts_at <= now())
     and content.ends_at > now();
  if not found then
    raise exception 'this offer is not available' using errcode = '22023';
  end if;

  -- usage_limit is optional promotion metadata, not a column: the offer editor writes a free
  -- jsonb, so a firm that sets one gets it enforced per customer and one that does not is
  -- unaffected. A non-numeric value is ignored rather than treated as zero.
  v_limit := nullif(regexp_replace(coalesce(v_promotion.metadata->>'usage_limit',''),
    '[^0-9]','','g'),'')::integer;
  if v_limit is not null and v_limit > 0 then
    select count(*)::integer into v_used
      from public.promotion_redemptions_v290 used
     where used.business_id = p_business
       and used.promotion_id = p_promotion
       and used.client_id = v_client;
    if v_used >= v_limit then
      raise exception 'offer usage limit reached' using errcode = '23514';
    end if;
  end if;

  -- One live intent per promotion per customer. An earlier one that has run out of time is
  -- retired here rather than blocking the customer forever.
  update public.promotion_redemption_intents_v290 stale
     set status = 'expired'
   where stale.business_id = p_business
     and stale.promotion_id = p_promotion
     and stale.client_id = v_client
     and stale.status = 'pending'
     and stale.expires_at <= now();
  select * into v_open from public.promotion_redemption_intents_v290 intent
   where intent.business_id = p_business
     and intent.promotion_id = p_promotion
     and intent.client_id = v_client
     and intent.status = 'pending';
  if found then
    return jsonb_build_object('status','pending','intent_id',v_open.id,
      'promotion_id',v_open.promotion_id,'expires_at',v_open.expires_at,
      'qr_token',app.v89_redemption_token(v_identity,p_business,'promotion_v290',
        v_open.promotion_id,v_open.idempotency_key),
      'replayed',true);
  end if;

  v_token := app.v89_redemption_token(
    v_identity,p_business,'promotion_v290',p_promotion,p_idempotency_key);

  insert into public.promotion_redemption_intents_v290(
    id,business_id,promotion_id,identity_id,auth_user_id,client_id,
    token_hash,idempotency_key,request_hash,expires_at
  ) values (
    v_intent,p_business,p_promotion,v_identity,auth.uid(),v_client,
    app.v89_sha256(v_token),p_idempotency_key,v_request_hash,v_expires
  );

  return jsonb_build_object('status','pending','intent_id',v_intent,
    'promotion_id',p_promotion,'expires_at',v_expires,'qr_token',v_token,'replayed',false);
end;
$$;

revoke all on function public.customer_create_promotion_intent_v290(uuid, uuid, uuid)
  from public, anon;
grant execute on function public.customer_create_promotion_intent_v290(uuid, uuid, uuid)
  to authenticated;

create or replace function public.staff_redeem_promotion_intent_v290(
  p_business uuid,
  p_token text,
  p_branch uuid,
  p_idempotency_key text
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_actor uuid := auth.uid();
  v_token text := nullif(btrim(coalesce(p_token,'')),'');
  v_key text := nullif(btrim(coalesce(p_idempotency_key,'')),'');
  v_intent public.promotion_redemption_intents_v290%rowtype;
  v_existing public.promotion_redemptions_v290%rowtype;
  v_name text;
  v_customer text;
  v_id uuid;
begin
  -- Either right accepts an offer at the counter: the person who can record the sale, or the
  -- person who administers loyalty (which is what already gates the scanner the browser opens).
  if v_actor is null or p_business is null
     or not (app.can_module_write(p_business,'sales')
       or app.can_module_write(p_business,'loyalty')) then
    raise exception 'staff authorization is required to accept an offer' using errcode = '42501';
  end if;
  if v_token is null or char_length(v_token) not between 20 and 512 then
    raise exception 'a redemption token is required' using errcode = '22023';
  end if;
  if v_key is null or char_length(v_key) not between 8 and 200 then
    raise exception 'an idempotency key of 8 to 200 characters is required' using errcode = '22023';
  end if;

  perform pg_advisory_xact_lock(
    hashtextextended(p_business::text||':promotion-redeem-v290:'||v_key,0));

  select * into v_existing from public.promotion_redemptions_v290 record
   where record.business_id = p_business and record.idempotency_key = v_key;
  if found then
    return jsonb_build_object('status','duplicate_ignored','redemption_id',v_existing.id,
      'intent_id',v_existing.intent_id,'promotion_id',v_existing.promotion_id,
      'redeemed_at',v_existing.created_at);
  end if;

  select * into v_intent from public.promotion_redemption_intents_v290 intent
   where intent.business_id = p_business
     and intent.token_hash = app.v89_sha256(v_token)
   for update;
  if not found then
    raise exception 'this offer code does not belong to this business' using errcode = '22023';
  end if;
  if v_intent.status = 'redeemed' then
    return jsonb_build_object('status','already_redeemed','intent_id',v_intent.id,
      'promotion_id',v_intent.promotion_id,'redeemed_at',v_intent.redeemed_at);
  end if;
  if v_intent.status <> 'pending' or v_intent.expires_at <= now() then
    update public.promotion_redemption_intents_v290 stale
       set status = 'expired'
     where stale.id = v_intent.id and stale.status = 'pending';
    return jsonb_build_object('status','expired','intent_id',v_intent.id,
      'promotion_id',v_intent.promotion_id,'expires_at',v_intent.expires_at);
  end if;
  if p_branch is not null and not app.can_see_branch(p_business,p_branch) then
    raise exception 'this branch is not in your scope' using errcode = '42501';
  end if;

  update public.promotion_redemption_intents_v290 intent
     set status = 'redeemed', redeemed_at = now(), redeemed_by = v_actor
   where intent.id = v_intent.id;

  insert into public.promotion_redemptions_v290(
    business_id,promotion_id,intent_id,client_id,branch_id,staff_actor,idempotency_key,detail
  ) values (
    p_business,v_intent.promotion_id,v_intent.id,v_intent.client_id,p_branch,v_actor,v_key,
    jsonb_build_object('identity_id',v_intent.identity_id,'intent_created_at',v_intent.created_at)
  ) returning id into v_id;

  select coalesce(copy.name,'Offer') into v_name
    from public.business_localized_copy_v95 copy
   where copy.business_id = p_business
     and copy.entity_type = 'offer'
     and copy.entity_id = v_intent.promotion_id
     and copy.locale = 'en';
  select customer.full_name into v_customer
    from public.clients customer
   where customer.id = v_intent.client_id and customer.business_id = p_business;

  insert into public.audit_log(business_id, actor, action, entity, entity_id, detail)
  values (p_business, v_actor, 'PROMOTION_REDEEMED_V290',
    'promotion_redemptions_v290', v_id,
    jsonb_build_object('promotion_id',v_intent.promotion_id,'intent_id',v_intent.id,
      'client_id',v_intent.client_id,'branch_id',p_branch));

  return jsonb_build_object('status','redeemed','redemption_id',v_id,'intent_id',v_intent.id,
    'promotion_id',v_intent.promotion_id,'promotion_name',coalesce(v_name,'Offer'),
    'customer_name',coalesce(v_customer,'Customer'),'redeemed_at',now());
end;
$$;

revoke all on function public.staff_redeem_promotion_intent_v290(uuid, text, uuid, text)
  from public, anon;
grant execute on function public.staff_redeem_promotion_intent_v290(uuid, text, uuid, text)
  to authenticated;

commit;
