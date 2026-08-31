-- NESTLY v661 — atomically claim receipt OCR work and recover abandoned claims.

begin;

alter table public.platform_accounting_receipts_v199
  drop constraint if exists platform_accounting_receipts_v199_status_check;
alter table public.platform_accounting_receipts_v199
  add column if not exists extraction_claimed_at timestamptz,
  add constraint platform_accounting_receipts_v199_status_check check (status in
    ('uploaded','processing','extracted','extraction_failed','posted','discarded'));

create index if not exists platform_accounting_receipts_v661_claim_idx
  on public.platform_accounting_receipts_v199(status, extraction_claimed_at, created_at)
  where status in ('uploaded','processing');

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
     ('uploaded','processing','extracted','extraction_failed','posted','discarded') then
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

create or replace function public.internal_claim_receipt_for_extraction_v199()
returns jsonb language plpgsql security definer
set search_path to 'pg_catalog','public','app','pg_temp' as $$
declare v_row public.platform_accounting_receipts_v199%rowtype;
begin
  if current_setting('role',true) is distinct from 'service_role'
     and auth.role() is distinct from 'service_role' then
    raise exception 'service role is required' using errcode='42501';
  end if;

  with next_receipt as (
    select id
      from public.platform_accounting_receipts_v199
     where status='uploaded'
        or (status='processing' and extraction_claimed_at < now()-interval '5 minutes')
     order by created_at
     for update skip locked
     limit 1
  )
  update public.platform_accounting_receipts_v199 receipt
     set status='processing', extraction_claimed_at=now()
    from next_receipt
   where receipt.id=next_receipt.id
  returning receipt.* into v_row;

  if not found then return jsonb_build_object('claimed',false); end if;
  return jsonb_build_object('claimed',true,'receipt',jsonb_build_object(
    'id',v_row.id,'storage_path',v_row.storage_path,'mime_type',v_row.mime_type));
end $$;

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
         extracted_at=now(), extraction_claimed_at=null
   where id=p_receipt and status='processing'
  returning * into v_row;
  if not found then return jsonb_build_object('updated',false,'receipt',p_receipt); end if;
  return jsonb_build_object('updated',true,'receipt',to_jsonb(v_row));
end $$;

revoke all on function public.internal_claim_receipt_for_extraction_v199() from public, anon, authenticated;
revoke all on function public.internal_record_receipt_extraction_v199(uuid,jsonb,text) from public, anon, authenticated;
revoke all on function public.platform_list_receipts_v199(text,integer) from public, anon, authenticated;
grant execute on function public.internal_claim_receipt_for_extraction_v199() to service_role;
grant execute on function public.internal_record_receipt_extraction_v199(uuid,jsonb,text) to service_role;
grant execute on function public.platform_list_receipts_v199(text,integer) to authenticated;

commit;
