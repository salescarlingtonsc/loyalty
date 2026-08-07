-- Rollback-only v201 acceptance: the receipt bucket is reachable by a super
-- admin, closed to everyone else, and its evidence cannot be swapped or erased.
begin;

do $v201$
declare v_n int; v_limit bigint; v_types text;
begin
  -- The bucket must not be public, and must bound size and type.
  select file_size_limit, array_to_string(allowed_mime_types,',')
    into v_limit, v_types
    from storage.buckets where id='accounting-private' and public = false;
  if v_limit is null then
    raise exception 'A: accounting-private bucket is missing, public, or unbounded';
  end if;
  if v_limit <> 20971520 then
    raise exception 'B: expected a 20 MB cap, got %', v_limit;
  end if;
  if v_types not like '%application/pdf%' or v_types not like '%image/jpeg%' then
    raise exception 'C: bucket does not accept the documented receipt types: %', v_types;
  end if;

  -- Exactly one insert and one select policy, and nothing else.
  select count(*) into v_n from pg_policies
   where schemaname='storage' and tablename='objects'
     and policyname in ('accounting_receipts_sa_insert_v201',
                        'accounting_receipts_sa_read_v201');
  if v_n <> 2 then
    raise exception 'D: expected the two v201 storage policies, found %', v_n;
  end if;

  -- Evidence is immutable through the API: no UPDATE, no DELETE.
  select count(*) into v_n from pg_policies
   where schemaname='storage' and tablename='objects'
     and (qual ilike '%accounting-private%' or with_check ilike '%accounting-private%')
     and cmd in ('UPDATE','DELETE','ALL');
  if v_n <> 0 then
    raise exception 'E: a posted receipt could be swapped or erased (% policies)', v_n;
  end if;

  -- Uploads are confined to the receipts/ prefix and to a super admin.
  if not exists (select 1 from pg_policies
                  where policyname='accounting_receipts_sa_insert_v201'
                    and with_check ilike '%is_super_admin%'
                    and with_check ilike '%receipts/%%') then
    raise exception 'F: insert policy does not require super admin under receipts/';
  end if;
  if not exists (select 1 from pg_policies
                  where policyname='accounting_receipts_sa_read_v201'
                    and qual ilike '%is_super_admin%') then
    raise exception 'G: read policy does not require super admin';
  end if;

  raise notice 'v201 receipt storage: all assertions passed (% byte cap)', v_limit;
end
$v201$;

rollback;
