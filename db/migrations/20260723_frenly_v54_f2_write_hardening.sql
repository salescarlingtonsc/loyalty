-- FRENLY v54 — F2 value-write hardening (PS-0 HARD findings 1–3 + the two /3 overloads).
-- Forward-only. Verified by db/tests/v54_f2_write_hardening.sql (rollback-only) before apply.
--
-- WHAT THIS CLOSES (PS-0 WRITER_AUDIT.md §5a + registry hard_findings)
--   (a) Browser-direct value writes: app/index.html inserts `expenses` (:7003) and
--       `stock_batches` (:6500) via raw PostgREST — no RPC, no idempotency, no audit
--       parity. Both are RLS-gated owner/finance actions, but a double-tap duplicates a
--       P&L cost row / an inventory batch (over-counting on-hand, skewing FEFO).
--   (b) sell_package/3 and enroll_membership_v41/3 remain EXECUTE-granted to authenticated
--       AND are still directly UI-called; their idempotent /4 successors already ship (v51a).
--
-- THE FIX
--   1. A keyed, append-only op-ledger (public.f2_write_operations) — the exact
--      gift_card_issue_operations / sale_intent_operations (v41 / v51a) mechanism: keyed
--      (business_id, idempotency_key), sha256 request hash for conflict detection, cached
--      result, RLS + revoke-all (internal only), reusing the v41 immutability guard trigger.
--   2. public.create_expense(...) and public.receive_stock(...): SECURITY DEFINER, pinned
--      search_path, authenticated-only, derive the actor from auth.uid(), enforce active
--      staff + module-write + (for expenses) finance permission, validate the payload,
--      write the value row + an audit_log row + the op-ledger row ATOMICALLY (one txn),
--      idempotent replay, and a v41-style 23505 conflict on key reuse with a different hash.
--   3. Revoke the two browser-direct write boundaries (grants + write-permitting FOR ALL
--      RLS policies) so `expenses` / `stock_batches` are server-mediated only; SELECT is
--      byte-identical.
--   4. Revoke EXECUTE on the non-idempotent /3 overloads from every browser principal.
--
-- SCHEMA-HONESTY NOTES (do not silently pretend the directive's generic checklist fits)
--   * `stock_batches` (frenly_init) has ONLY (id, product_id, qty, expires_on, received_on)
--     and NO business_id — the tenant boundary rides product_id. receive_stock therefore
--     gates cross-tenant access by requiring the product to belong to p_business (verified,
--     then insert). The table has NO unit-cost / batch-reference / branch columns, so the
--     directive's "validate unit cost, batch" items are INAPPLICABLE to the current schema,
--     and a full inventory-movement ledger is explicitly OUT OF F2 SCOPE (a later PS phase).
--   * `expenses` already carries a table-level audit trigger (trg_expenses_audit → app.audit);
--     create_expense additionally writes ONE explicit semantic audit_log row (action
--     'expense_create') for parity with receive_stock (stock_batches has NO audit trigger),
--     so a completed expense create produces two audit rows (the generic INSERT trigger row
--     plus the semantic row); receive_stock produces exactly one (the semantic row).
--   * occurred_on / received_on inherit the v52 SGT column default
--     ((timezone('Asia/Singapore', now()))::date); passing NULL falls through to that default
--     via an identically-computed expression here, so a NULL date is the SGT "today".
--
-- CALLER DISCOVERY for the /3 revokes (grep across app/, supabase/functions/, migration bodies)
--   sell_package(  3-arg call sites: app/index.html:6539 (standalone Packages page) and the
--     v51a wrapper public.sell_package(uuid,uuid,uuid,uuid) body (delegates to /3). After
--     this revoke the ONLY legitimate remaining caller of /3 is its own /4 wrapper, which is
--     SECURITY DEFINER (owner-executed) and therefore UNAFFECTED by the authenticated revoke.
--     The standalone UI 3-arg call must migrate to the 4-arg overload (app/ scope — a parallel
--     agent owns app/index.html).
--   enroll_membership_v41(  3-arg call sites: app/index.html:5816 (standalone Memberships page)
--     and the v51a wrapper public.enroll_membership_v41(uuid,uuid,uuid,uuid) body (delegates
--     to /3). Same conclusion: only the definer-owned /4 wrapper legitimately calls /3 after
--     this revoke; the standalone UI must move to /4.
--   No Edge Function references either /3 overload (supabase/functions grep: none).
--
-- DIRECT-WRITE BOUNDARY being closed (how the browser insert succeeds today)
--   expenses:      table grant `select, insert, update, delete ... to authenticated` (v11b)
--                  + FOR ALL policy `expenses_all` (using/check app.has_perm(view_finance), v11b).
--   stock_batches: NO explicit grant (Supabase default-privileges grant ALL on new public
--                  tables to authenticated) + FOR ALL policy `stock_batches_all`
--                  (using/check app.can_module(products.business_id,'inventory'), v14b).
--   We revoke the write grants and replace each FOR ALL policy with a SELECT-only policy
--   carrying the identical USING clause, so reads are unchanged and the super-admin sa_read
--   policies stay intact. Internal SECURITY DEFINER writers (app.run_expense_recurrences →
--   expenses; app.on_sale_stock_deduct / app.on_appointment_completed / public.commit_import_job
--   → stock_batches) run as the function owner, bypass RLS, and keep the owner's table
--   privileges — the revoke does not touch them (verified: all are SECURITY DEFINER).

begin;

-- ---------------------------------------------------------------------------
-- 1. Keyed, append-only idempotency ledger for the two hardened value writes.
--    Precedent: public.gift_card_issue_operations (v41), public.sale_intent_operations (v51a).
-- ---------------------------------------------------------------------------
create table public.f2_write_operations (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  actor uuid not null references auth.users(id) on delete restrict,
  operation_type text not null check (operation_type in ('expense_create', 'stock_receive')),
  idempotency_key uuid not null,
  request_hash text not null check (request_hash ~ '^[0-9a-f]{64}$'),
  status text not null check (status in ('completed')),
  result jsonb not null check (jsonb_typeof(result) = 'object'),
  created_at timestamptz not null default now(),
  unique (business_id, actor, operation_type, idempotency_key),
  unique (business_id, idempotency_key)
);
comment on table public.f2_write_operations is
  'v54 append-only, internal-only idempotency + provenance ledger for create_expense / receive_stock; keyed (business_id, idempotency_key) with a sha256 request hash and cached result.';
create index f2_write_operations_business_idx
  on public.f2_write_operations(business_id, created_at);

alter table public.f2_write_operations enable row level security;
revoke all privileges on table public.f2_write_operations from public, anon, authenticated;

-- Reuse the v41 generic append-only guard (before update or delete -> raise 55000).
create trigger f2_write_operations_immutable_guard
  before update or delete on public.f2_write_operations
  for each row execute function app.v41_operation_immutable_guard();

-- ---------------------------------------------------------------------------
-- 2. public.create_expense(...) — keyed, audited P&L cost writer.
--    Finance gate: app.has_perm(business,'view_finance'). Per the owner directive,
--    'view_finance' is the ONLY finance permission in app.role_perms (owner / manager /
--    bookkeeper carry it; staff / frontdesk / stylist / receptionist do NOT), so it is the
--    correct and only finance authority to enforce here.
-- ---------------------------------------------------------------------------
create or replace function public.create_expense(
  p_business uuid,
  p_branch uuid,
  p_category text,
  p_amount_cents integer,
  p_occurred_on date,
  p_supplier text,
  p_description text,
  p_note text,
  p_idempotency_key uuid)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_actor uuid := auth.uid();
  v_staff uuid;
  v_category text := nullif(btrim(p_category), '');
  v_supplier text := nullif(btrim(p_supplier), '');
  v_description text := nullif(btrim(p_description), '');
  v_note text := nullif(btrim(p_note), '');
  v_sgt_today date := (timezone('Asia/Singapore', now()))::date;
  v_occurred date := coalesce(p_occurred_on, (timezone('Asia/Singapore', now()))::date);
  v_payload jsonb;
  v_hash text;
  v_existing public.f2_write_operations%rowtype;
  v_expense_id uuid;
  v_result jsonb;
begin
  if v_actor is null then
    raise exception 'authenticated staff required' using errcode = '42501';
  end if;
  if p_idempotency_key is null then
    raise exception 'an expense idempotency key is required' using errcode = '22023';
  end if;
  -- Active staff of THIS business, module-write on expenses, and the finance permission.
  select s.id into v_staff
    from public.staff s
   where s.business_id = p_business
     and s.user_id = v_actor
     and s.active
   order by case when s.role = 'owner' then 0 else 1 end, s.created_at
   limit 1
   for update;
  if v_staff is null
     or not app.can_module_write(p_business, 'expenses')
     or not app.has_perm(p_business, 'view_finance') then
    raise exception 'active expenses-module write authorization with view_finance is required'
      using errcode = '42501';
  end if;

  -- Payload validation (fail-closed).
  if v_category is null or char_length(v_category) < 1 or char_length(v_category) > 80 then
    raise exception 'expense category must be 1..80 characters' using errcode = '22023';
  end if;
  if p_amount_cents is null or p_amount_cents < 1 or p_amount_cents > 100000000 then
    raise exception 'expense amount must be between 1 and 100000000 cents' using errcode = '22023';
  end if;
  if v_supplier is not null and char_length(v_supplier) > 160 then
    raise exception 'expense supplier is too long' using errcode = '22023';
  end if;
  if v_description is not null and char_length(v_description) > 500 then
    raise exception 'expense description is too long' using errcode = '22023';
  end if;
  if v_note is not null and char_length(v_note) > 500 then
    raise exception 'expense note is too long' using errcode = '22023';
  end if;
  if v_occurred > v_sgt_today + 1
     or v_occurred < (v_sgt_today - interval '5 years')::date then
    raise exception 'expense date is outside the accepted window' using errcode = '22023';
  end if;
  if p_branch is not null and not exists (
    select 1 from public.branches b
     where b.id = p_branch and b.business_id = p_business and b.active
  ) then
    raise exception 'expense branch does not belong to this business or is inactive'
      using errcode = '22023';
  end if;

  v_payload := jsonb_build_object(
    'amount_cents', p_amount_cents,
    'branch_id', p_branch,
    'business_id', p_business,
    'category', v_category,
    'description', v_description,
    'note', v_note,
    'occurred_on', v_occurred,
    'supplier', v_supplier
  );
  v_hash := app.v41_request_hash(v_payload::text);
  perform pg_advisory_xact_lock(hashtextextended(
    'v54:expense:' || p_business::text || ':' || p_idempotency_key::text, 0));

  select * into v_existing
    from public.f2_write_operations o
   where o.business_id = p_business and o.idempotency_key = p_idempotency_key
   for update;
  if found then
    if v_existing.actor is distinct from v_actor
       or v_existing.operation_type <> 'expense_create'
       or v_existing.request_hash <> v_hash then
      raise exception 'idempotency key conflicts with another expense request'
        using errcode = '23505';
    end if;
    return jsonb_build_object(
      'status', 'duplicate_ignored',
      'expense_id', (v_existing.result->>'expense_id')::uuid,
      'replayed', true
    );
  end if;

  -- Value row + explicit semantic audit row, in this one transaction.
  insert into public.expenses (
    business_id, branch_id, category, supplier, description,
    amount_cents, occurred_on, note, created_by
  ) values (
    p_business, p_branch, v_category, v_supplier, v_description,
    p_amount_cents, v_occurred, v_note, v_actor
  ) returning id into v_expense_id;

  insert into public.audit_log (business_id, actor, action, entity, entity_id, detail)
  values (p_business, v_actor, 'expense_create', 'expenses', v_expense_id,
          jsonb_build_object(
            'idempotency_key', p_idempotency_key,
            'amount_cents', p_amount_cents,
            'category', v_category,
            'branch_id', p_branch,
            'occurred_on', v_occurred));

  v_result := jsonb_build_object('status', 'ok', 'expense_id', v_expense_id, 'replayed', false);
  insert into public.f2_write_operations (
    business_id, actor, operation_type, idempotency_key, request_hash, status, result
  ) values (
    p_business, v_actor, 'expense_create', p_idempotency_key, v_hash, 'completed', v_result);
  return v_result;
end $$;

revoke all privileges on function
  public.create_expense(uuid, uuid, text, integer, date, text, text, text, uuid)
  from public, anon, authenticated;
grant execute on function public.create_expense(
  uuid, uuid, text, integer, date, text, text, text, uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- 3. public.receive_stock(...) — keyed, audited inventory-batch writer.
--    Cross-tenant gate: stock_batches has NO business_id, so the product-belongs-to-business
--    check IS the tenant boundary. Row locking: receiving is append-only (one new batch),
--    so beyond the advisory lock (idempotency) no additional row lock is needed — FEFO
--    deduction (app.on_sale_stock_deduct) locks the batch rows it decrements itself.
-- ---------------------------------------------------------------------------
create or replace function public.receive_stock(
  p_business uuid,
  p_product uuid,
  p_qty integer,
  p_expires_on date,
  p_received_on date,
  p_idempotency_key uuid)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_actor uuid := auth.uid();
  v_staff uuid;
  v_sgt_today date := (timezone('Asia/Singapore', now()))::date;
  v_received date := coalesce(p_received_on, (timezone('Asia/Singapore', now()))::date);
  v_payload jsonb;
  v_hash text;
  v_existing public.f2_write_operations%rowtype;
  v_batch_id uuid;
  v_result jsonb;
begin
  if v_actor is null then
    raise exception 'authenticated staff required' using errcode = '42501';
  end if;
  if p_idempotency_key is null then
    raise exception 'a stock-receive idempotency key is required' using errcode = '22023';
  end if;
  select s.id into v_staff
    from public.staff s
   where s.business_id = p_business
     and s.user_id = v_actor
     and s.active
   order by case when s.role = 'owner' then 0 else 1 end, s.created_at
   limit 1
   for update;
  if v_staff is null or not app.can_module_write(p_business, 'inventory') then
    raise exception 'active inventory-module write authorization is required'
      using errcode = '42501';
  end if;

  -- THE cross-tenant gate: an active product that belongs to p_business.
  if p_product is null or not exists (
    select 1 from public.products p
     where p.id = p_product and p.business_id = p_business and p.active
  ) then
    raise exception 'stock product does not belong to this business or is inactive'
      using errcode = '22023';
  end if;
  if p_qty is null or p_qty < 1 or p_qty > 1000000 then
    raise exception 'received quantity must be between 1 and 1000000' using errcode = '22023';
  end if;
  if v_received > v_sgt_today + 1
     or v_received < (v_sgt_today - interval '5 years')::date then
    raise exception 'received date is outside the accepted window' using errcode = '22023';
  end if;
  if p_expires_on is not null and p_expires_on <= v_received then
    raise exception 'expiry date must be strictly after the received date' using errcode = '22023';
  end if;

  v_payload := jsonb_build_object(
    'business_id', p_business,
    'expires_on', p_expires_on,
    'product_id', p_product,
    'qty', p_qty,
    'received_on', v_received
  );
  v_hash := app.v41_request_hash(v_payload::text);
  perform pg_advisory_xact_lock(hashtextextended(
    'v54:stock:' || p_business::text || ':' || p_idempotency_key::text, 0));

  select * into v_existing
    from public.f2_write_operations o
   where o.business_id = p_business and o.idempotency_key = p_idempotency_key
   for update;
  if found then
    if v_existing.actor is distinct from v_actor
       or v_existing.operation_type <> 'stock_receive'
       or v_existing.request_hash <> v_hash then
      raise exception 'idempotency key conflicts with another stock-receive request'
        using errcode = '23505';
    end if;
    return jsonb_build_object(
      'status', 'duplicate_ignored',
      'stock_batch_id', (v_existing.result->>'stock_batch_id')::uuid,
      'replayed', true
    );
  end if;

  insert into public.stock_batches (product_id, qty, expires_on, received_on)
  values (p_product, p_qty, p_expires_on, v_received)
  returning id into v_batch_id;

  insert into public.audit_log (business_id, actor, action, entity, entity_id, detail)
  values (p_business, v_actor, 'stock_receive', 'stock_batches', v_batch_id,
          jsonb_build_object(
            'idempotency_key', p_idempotency_key,
            'product_id', p_product,
            'qty', p_qty,
            'expires_on', p_expires_on,
            'received_on', v_received));

  v_result := jsonb_build_object('status', 'ok', 'stock_batch_id', v_batch_id, 'replayed', false);
  insert into public.f2_write_operations (
    business_id, actor, operation_type, idempotency_key, request_hash, status, result
  ) values (
    p_business, v_actor, 'stock_receive', p_idempotency_key, v_hash, 'completed', v_result);
  return v_result;
end $$;

revoke all privileges on function
  public.receive_stock(uuid, uuid, integer, date, date, uuid)
  from public, anon, authenticated;
grant execute on function public.receive_stock(
  uuid, uuid, integer, date, date, uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- 4. Close the two browser-direct write boundaries. SELECT stays byte-identical
--    (same USING predicate on a SELECT-only policy); only INSERT/UPDATE/DELETE are removed.
-- ---------------------------------------------------------------------------
-- expenses: replace FOR ALL (v11b) with SELECT-only; revoke the write grant.
drop policy if exists expenses_all on public.expenses;
create policy expenses_select on public.expenses for select to authenticated
  using (app.has_perm(business_id, 'view_finance'));
revoke insert, update, delete on table public.expenses from public, anon, authenticated;

-- stock_batches: replace FOR ALL (v14b) with SELECT-only; revoke the (default-privilege) write grant.
drop policy if exists stock_batches_all on public.stock_batches;
create policy stock_batches_select on public.stock_batches for select to authenticated
  using (exists (
    select 1 from public.products p
     where p.id = stock_batches.product_id and app.can_module(p.business_id, 'inventory')));
revoke insert, update, delete on table public.stock_batches from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 5. Revoke EXECUTE on the two non-idempotent /3 overloads from every browser principal.
--    Their idempotent /4 successors (v51a) remain granted; the /4 wrappers are
--    SECURITY DEFINER and call /3 as the function owner, so they keep working.
-- ---------------------------------------------------------------------------
revoke execute on function public.sell_package(uuid, uuid, uuid)
  from public, anon, authenticated;
revoke execute on function public.enroll_membership_v41(uuid, uuid, uuid)
  from public, anon, authenticated;

commit;
