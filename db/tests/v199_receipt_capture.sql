-- Rollback-only v199 acceptance: a scanned receipt reaches the P&L only after a
-- human confirms it, and the same photo can never become two expenses.
begin;

do $v199$
declare
  v_sa uuid; a jsonb; b jsonb; v_receipt uuid; v_n int; v_exp bigint; v_status text;
  v_hash text := repeat('a',64);
begin
  select user_id into v_sa from public.super_admins limit 1;
  if v_sa is null then raise exception 'no super admin configured'; end if;
  perform set_config('request.jwt.claim.sub', v_sa::text, true);
  perform set_config('request.jwt.claims',
    json_build_object('sub',v_sa,'role','authenticated')::text, true);

  -- An accounting identity is a hard precondition for posting anything.
  perform public.platform_set_accounting_policy_v147(
    current_date - 30, 'V199 FIXTURE PTE. LTD.', '200012345A', '1 Test Road, Singapore',
    'registered', 'M90312345A', 900, 12, 31, 'FIX', 'fixture-policy-evidence',
    gen_random_uuid());

  a := public.platform_register_receipt_v199(
    'receipts/2026/08/test.jpg', v_hash, 'image/jpeg', 24000, 'grab.jpg');
  v_receipt := ((a->'receipt')->>'id')::uuid;
  if (a->>'duplicate')::boolean then raise exception 'A: first upload flagged duplicate'; end if;

  -- Content hash is the dedupe key: the same photo cannot become two expenses.
  b := public.platform_register_receipt_v199(
    'receipts/2026/08/copy.jpg', v_hash, 'image/jpeg', 24000, 'copy.jpg');
  if not (b->>'duplicate')::boolean then raise exception 'B: the same photo was accepted twice'; end if;
  select count(*) into v_n from public.platform_accounting_receipts_v199;
  if v_n <> 1 then raise exception 'C: expected 1 receipt row, got %', v_n; end if;

  -- Extraction is a PROPOSAL and must never post.
  perform public.internal_record_receipt_extraction_v199(v_receipt,
    jsonb_build_object('vendor_name','Grab','total_cents',4210,'gst_cents',347,'confidence',0.94));
  select status into v_status from public.platform_accounting_receipts_v199 where id=v_receipt;
  if v_status <> 'extracted' then raise exception 'D: expected extracted, got %', v_status; end if;
  select count(*) into v_n from public.platform_operating_expense_entries_v146;
  if v_n <> 0 then raise exception 'E: extraction posted an expense with no human'; end if;

  -- The human confirms; posting reuses the audited v147 path.
  a := public.platform_post_receipt_expense_v199(v_receipt, current_date-1, 'operations',
    'Grab ride to supplier meeting', 4210, 'Grab Singapore', 'DBS-2026-08-07', '200312345B');
  select count(*) into v_n from public.platform_operating_expense_entries_v146;
  if v_n <> 1 then raise exception 'F: expense was not recorded'; end if;

  -- It reached the journal, so the P&L actually moves.
  select count(*) into v_n from public.platform_accounting_journal_entries_v147;
  if v_n < 1 then raise exception 'G: no journal entry was posted'; end if;
  select (public.platform_get_accounting_books_v147(current_date-2, current_date, 100)
          #>>'{summary,expense_cents}')::bigint into v_exp;
  if v_exp <> 4210 then raise exception 'H: P&L expense should be 4210, got %', v_exp; end if;

  -- The books point at the stored evidence.
  select count(*) into v_n from public.platform_operating_expense_entries_v146
   where evidence_reference='receipts/2026/08/test.jpg';
  if v_n <> 1 then raise exception 'I: books do not reference the stored receipt'; end if;

  begin
    perform public.platform_post_receipt_expense_v199(v_receipt, current_date-1, 'operations',
      'again', 4210, 'Grab Singapore', 'DBS-2026-08-07');
    raise exception 'J: a posted receipt was posted twice';
  exception when sqlstate '22023' then null;
  end;

  -- Browser roles can never write an extraction themselves.
  if has_function_privilege('authenticated',
       'public.internal_record_receipt_extraction_v199(uuid,jsonb,text)','EXECUTE')
     or has_function_privilege('anon',
       'public.internal_record_receipt_extraction_v199(uuid,jsonb,text)','EXECUTE') then
    raise exception 'K: extraction writer is callable by a browser role';
  end if;

  raise notice 'v199 receipt capture: all assertions passed (P&L expense %)', v_exp;
end
$v199$;

rollback;
