-- NESTLY v199 — scan a receipt, have it read for you, then post it to the books.
--
-- Owner: "allowing me to upload doc or scan receipts - auto add into the
-- bookkeeping ... keep track my expenses and profitability."
--
-- What already existed: a real double-entry spine. 15 accounts,
-- platform_record_operating_expense_v147 -> platform_operating_expense_entries_v146
-- -> trigger platform_expense_post_v147 -> journal entries -> the profit figure in
-- platform_get_accounting_books_v147. Expense rows are immutable by trigger, and
-- nothing can post until an accounting identity exists.
--
-- What was missing: any way to get a receipt INTO that spine. evidence_reference
-- was a free-text box, so the document itself lived nowhere.
--
-- This adds the capture half and stops exactly where judgement begins:
--
--     upload -> extract (AI reads it) -> A HUMAN CONFIRMS -> post
--
-- The AI never writes the books. It only proposes vendor/date/amount/GST, which a
-- super admin edits and approves; posting then goes through the SAME v147 RPC that
-- a hand-typed expense uses, so every guarantee that path already has — immutability,
-- idempotency, the journal trigger, the policy precondition — applies unchanged.
-- Getting this backwards (auto-posting what an OCR guessed) is how bookkeeping
-- silently goes wrong, and it is the one shortcut deliberately not taken here.
--
-- The stored object is the audit evidence: a receipt is content-hashed, so
-- photographing the same receipt twice cannot post the same expense twice, and the
-- posted expense's evidence_reference points at the exact stored file.

begin;

-- Private bucket. Receipts are financial records and must never be public.
insert into storage.buckets(id, name, public)
values ('accounting-private','accounting-private', false)
on conflict (id) do nothing;

create table if not exists public.platform_accounting_receipts_v199(
  id uuid primary key default gen_random_uuid(),
  storage_path text not null unique,
  content_sha256 text not null unique
    check (content_sha256 ~ '^[0-9a-f]{64}$'),
  mime_type text not null check (mime_type in
    ('image/jpeg','image/png','image/webp','image/heic','application/pdf')),
  byte_size integer not null check (byte_size between 1 and 20971520),
  original_filename text,
  status text not null default 'uploaded' check (status in
    ('uploaded','extracted','extraction_failed','posted','discarded')),
  extracted jsonb,
  extraction_error text,
  extracted_at timestamptz,
  expense_entry_id uuid references public.platform_operating_expense_entries_v146(id),
  posted_at timestamptz,
  posted_by uuid references auth.users(id),
  discarded_at timestamptz,
  discarded_by uuid references auth.users(id),
  discard_reason text,
  uploaded_by uuid not null references auth.users(id),
  created_at timestamptz not null default now(),
  -- A receipt is posted exactly when it carries the expense it produced.
  constraint receipt_posted_shape check (
    (status='posted' and expense_entry_id is not null and posted_at is not null)
    or (status<>'posted' and expense_entry_id is null and posted_at is null)),
  constraint receipt_discarded_shape check (
    (status='discarded' and discarded_at is not null)
    or (status<>'discarded' and discarded_at is null))
);

alter table public.platform_accounting_receipts_v199 enable row level security;
-- Deliberately no policy, and the browser roles are stripped of table rights
-- outright: like every other platform table, reads and writes go through the
-- SECURITY DEFINER RPCs below, never PostgREST. Receipts are financial records,
-- so "no policy" alone is not stated clearly enough — the ACL says it too.
revoke all on table public.platform_accounting_receipts_v199 from anon, authenticated;

create index if not exists platform_accounting_receipts_v199_queue_idx
  on public.platform_accounting_receipts_v199(created_at)
  where status='uploaded';

comment on table public.platform_accounting_receipts_v199 is
  'v199 receipt capture. A stored receipt is proposed by AI extraction and posted only after a human confirms; posting reuses platform_record_operating_expense_v147.';

-- Register a file the client has just uploaded to the private bucket. The hash is
-- the dedupe key: the same photo can never become two expenses.
create or replace function public.platform_register_receipt_v199(
  p_storage_path text, p_content_sha256 text, p_mime_type text,
  p_byte_size integer, p_original_filename text default null
) returns jsonb language plpgsql security definer
set search_path to 'pg_catalog','public','app','pg_temp' as $$
declare v_actor uuid:=auth.uid(); v_row public.platform_accounting_receipts_v199%rowtype;
begin
  if v_actor is null or not app.is_super_admin() then
    raise exception 'super-admin access is required' using errcode='42501';
  end if;
  if coalesce(btrim(p_storage_path),'')='' or p_storage_path not like 'receipts/%' then
    raise exception 'receipts must be stored under receipts/' using errcode='22023';
  end if;

  select * into v_row from public.platform_accounting_receipts_v199
   where content_sha256=p_content_sha256;
  if found then
    -- Same bytes as something already captured: hand back what exists rather
    -- than creating a second route to the same expense.
    return jsonb_build_object('receipt',to_jsonb(v_row),'duplicate',true);
  end if;

  insert into public.platform_accounting_receipts_v199(
    storage_path,content_sha256,mime_type,byte_size,original_filename,uploaded_by)
  values(btrim(p_storage_path),p_content_sha256,p_mime_type,p_byte_size,
    nullif(btrim(coalesce(p_original_filename,'')),''),v_actor)
  returning * into v_row;

  insert into public.audit_log(business_id,actor,action,entity,entity_id,detail)
  values(null,v_actor,'PLATFORM_RECEIPT_REGISTERED_V199',
    'platform_accounting_receipts_v199',v_row.id,
    jsonb_build_object('bytes',p_byte_size,'mime',p_mime_type));
  return jsonb_build_object('receipt',to_jsonb(v_row),'duplicate',false);
end $$;

create or replace function public.platform_list_receipts_v199(
  p_status text default null, p_limit integer default 50
) returns jsonb language plpgsql security definer
set search_path to 'pg_catalog','public','app','pg_temp' as $$
declare v_limit integer:=least(greatest(coalesce(p_limit,50),1),200);
begin
  if auth.uid() is null or not app.is_super_admin() then
    raise exception 'super-admin access is required' using errcode='42501';
  end if;
  if p_status is not null and p_status not in
     ('uploaded','extracted','extraction_failed','posted','discarded') then
    raise exception 'unknown receipt status' using errcode='22023';
  end if;
  return jsonb_build_object(
    'items',coalesce((select jsonb_agg(to_jsonb(row) order by row.created_at desc)
      from (select * from public.platform_accounting_receipts_v199 receipt
             where p_status is null or receipt.status=p_status
             order by receipt.created_at desc limit v_limit) row),'[]'::jsonb),
    'counts',(select jsonb_object_agg(status,n) from
      (select status,count(*) n from public.platform_accounting_receipts_v199
        group by status) totals));
end $$;

-- Written by the OCR worker (service role only). Extraction is a PROPOSAL: it
-- never advances a receipt past 'extracted'.
create or replace function public.internal_record_receipt_extraction_v199(
  p_receipt uuid, p_extracted jsonb, p_error text default null
) returns jsonb language plpgsql security definer
set search_path to 'pg_catalog','public','app','pg_temp' as $$
declare v_row public.platform_accounting_receipts_v199%rowtype;
begin
  if current_setting('role',true) is distinct from 'service_role'
     and auth.role() is distinct from 'service_role' then
    raise exception 'service role is required' using errcode='42501';
  end if;
  update public.platform_accounting_receipts_v199
     set status=case when p_error is not null then 'extraction_failed' else 'extracted' end,
         extracted=case when p_error is null then p_extracted end,
         extraction_error=left(nullif(btrim(coalesce(p_error,'')),''),400),
         extracted_at=now()
   where id=p_receipt and status in ('uploaded','extraction_failed')
  returning * into v_row;
  if not found then
    return jsonb_build_object('updated',false,'receipt',p_receipt);
  end if;
  return jsonb_build_object('updated',true,'receipt',to_jsonb(v_row));
end $$;

-- The human decision. Every figure posted is the one the operator confirmed,
-- not the one the model guessed, and the stored file becomes the evidence.
create or replace function public.platform_post_receipt_expense_v199(
  p_receipt uuid, p_expense_date date, p_category text, p_description text,
  p_amount_cents integer, p_counterparty_name text,
  p_payment_reference text, p_counterparty_registration_number text default null,
  p_idempotency_key uuid default gen_random_uuid()
) returns jsonb language plpgsql security definer
set search_path to 'pg_catalog','public','app','pg_temp' as $$
declare
  v_actor uuid:=auth.uid(); v_row public.platform_accounting_receipts_v199%rowtype;
  v_result jsonb; v_entry uuid;
begin
  if v_actor is null or not app.is_super_admin() then
    raise exception 'super-admin access is required' using errcode='42501';
  end if;
  select * into v_row from public.platform_accounting_receipts_v199
   where id=p_receipt for update;
  if not found then raise exception 'receipt not found' using errcode='22023'; end if;
  if v_row.status='posted' then
    raise exception 'this receipt is already posted' using errcode='22023';
  end if;
  if v_row.status='discarded' then
    raise exception 'this receipt was discarded' using errcode='22023';
  end if;

  -- Reuses the audited, immutable, journal-posting expense path unchanged. The
  -- stored object is the evidence reference, so the books point at the file.
  v_result := public.platform_record_operating_expense_v147(
    p_expense_date, p_category, p_description, p_amount_cents,
    p_counterparty_name, p_counterparty_registration_number,
    p_payment_reference, v_row.storage_path, p_idempotency_key);
  v_entry := ((v_result->'entry')->>'id')::uuid;

  update public.platform_accounting_receipts_v199
     set status='posted', expense_entry_id=v_entry, posted_at=now(), posted_by=v_actor
   where id=p_receipt;

  insert into public.audit_log(business_id,actor,action,entity,entity_id,detail)
  values(null,v_actor,'PLATFORM_RECEIPT_POSTED_V199',
    'platform_accounting_receipts_v199',p_receipt,
    jsonb_build_object('expense_entry',v_entry,'amount_cents',p_amount_cents,
      'confirmed_by_human',true));
  return jsonb_build_object('receipt',p_receipt,'expense',v_result);
end $$;

create or replace function public.platform_discard_receipt_v199(
  p_receipt uuid, p_reason text
) returns jsonb language plpgsql security definer
set search_path to 'pg_catalog','public','app','pg_temp' as $$
declare v_actor uuid:=auth.uid(); v_row public.platform_accounting_receipts_v199%rowtype;
begin
  if v_actor is null or not app.is_super_admin() then
    raise exception 'super-admin access is required' using errcode='42501';
  end if;
  if coalesce(btrim(p_reason),'')='' then
    raise exception 'a reason is required to discard a receipt' using errcode='22023';
  end if;
  update public.platform_accounting_receipts_v199
     set status='discarded', discarded_at=now(), discarded_by=v_actor,
         discard_reason=btrim(p_reason)
   where id=p_receipt and status<>'posted'
  returning * into v_row;
  if not found then
    raise exception 'only an unposted receipt can be discarded' using errcode='22023';
  end if;
  insert into public.audit_log(business_id,actor,action,entity,entity_id,detail)
  values(null,v_actor,'PLATFORM_RECEIPT_DISCARDED_V199',
    'platform_accounting_receipts_v199',p_receipt,
    jsonb_build_object('reason',btrim(p_reason)));
  return jsonb_build_object('receipt',to_jsonb(v_row));
end $$;

-- The worker claims one receipt at a time, so a slow OCR call never blocks the batch.
create or replace function public.internal_claim_receipt_for_extraction_v199()
returns jsonb language plpgsql security definer
set search_path to 'pg_catalog','public','app','pg_temp' as $$
declare v_row public.platform_accounting_receipts_v199%rowtype;
begin
  if current_setting('role',true) is distinct from 'service_role'
     and auth.role() is distinct from 'service_role' then
    raise exception 'service role is required' using errcode='42501';
  end if;
  select * into v_row from public.platform_accounting_receipts_v199
   where status='uploaded'
   order by created_at
   for update skip locked
   limit 1;
  if not found then return jsonb_build_object('claimed',false); end if;
  return jsonb_build_object('claimed',true,'receipt',jsonb_build_object(
    'id',v_row.id,'storage_path',v_row.storage_path,'mime_type',v_row.mime_type));
end $$;

revoke all on function public.platform_register_receipt_v199(text,text,text,integer,text)
  from public, anon, authenticated;
revoke all on function public.platform_list_receipts_v199(text,integer)
  from public, anon, authenticated;
revoke all on function public.platform_post_receipt_expense_v199(uuid,date,text,text,integer,text,text,text,uuid)
  from public, anon, authenticated;
revoke all on function public.platform_discard_receipt_v199(uuid,text)
  from public, anon, authenticated;
revoke all on function public.internal_record_receipt_extraction_v199(uuid,jsonb,text)
  from public, anon, authenticated;
revoke all on function public.internal_claim_receipt_for_extraction_v199()
  from public, anon, authenticated;
grant execute on function public.platform_register_receipt_v199(text,text,text,integer,text) to authenticated;
grant execute on function public.platform_list_receipts_v199(text,integer) to authenticated;
grant execute on function public.platform_post_receipt_expense_v199(uuid,date,text,text,integer,text,text,text,uuid) to authenticated;
grant execute on function public.platform_discard_receipt_v199(uuid,text) to authenticated;
grant execute on function public.internal_record_receipt_extraction_v199(uuid,jsonb,text) to service_role;
grant execute on function public.internal_claim_receipt_for_extraction_v199() to service_role;

commit;
