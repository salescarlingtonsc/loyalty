begin;

do $$
begin
  if not exists (
    select 1 from information_schema.columns
     where table_schema='public' and table_name='platform_accounting_receipts_v199'
       and column_name='extraction_claimed_at'
  ) then raise exception 'v661 extraction claim column is missing'; end if;
  if not exists (
    select 1 from pg_indexes where schemaname='public'
      and indexname='platform_accounting_receipts_v661_claim_idx'
  ) then raise exception 'v661 receipt claim index is missing'; end if;
end $$;

rollback;
