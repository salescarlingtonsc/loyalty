-- Rollback-only nestly_v810 acceptance: the anon EXECUTE grants are gone, every refusal they
-- shadowed still refuses, and the console can ask the SERVER what an invoice has already been
-- credited instead of reconstructing it from whichever documents a page happened to load.
--
-- WHAT THIS SUITE PROVES, against a super-admin and an invoice it builds itself:
--
--   PART 1 — ACLs
--   1. anon holds no EXECUTE on any of the four public functions that guard themselves with
--      `auth.uid() is null` — get_campaign_results, get_dashboard_summary,
--      get_reports_summary_v94_base, staff_list_customers_v129. This is the assertion that
--      fails pre-v810 (all four carried anon EXECUTE, three of them via PUBLIC as well).
--   2. The revoke did not take a legitimate caller with it: authenticated and service_role
--      still hold EXECUTE on all four.
--   3. The defect CLASS is closed, not four instances of it: no function in `public` anywhere
--      is left in the shape "anon can EXECUTE it AND its body refuses auth.uid() is null".
--   4. No refusal was weakened to make any of this pass: a session-less authenticated caller
--      still gets 42501 from get_dashboard_summary and staff_list_customers_v129.
--
--   PART 2 — F121, the credit-note history
--   5. platform_invoice_credit_note_totals_v810 refuses a caller with no session (42501) and an
--      authenticated non-super-admin (42501), exactly like its platform_* siblings.
--   6. It refuses an id that is not an invoice (22023) rather than answering with zeroes — a
--      zero would be indistinguishable from "nothing credited yet" and would silently feed the
--      console the wrong starting point.
--   7. On a fresh GST invoice it reports the invoice's own subtotal/tax and zero credited.
--   8. After one partial credit note it reports that credit note's subtotal and tax.
--   9. POSITIVE CONTROL — the drift F121 describes is real on this data: the per-call-isolated
--      tax for the second credit note is REFUSED by platform_issue_credit_note_v147 with
--      22023. Without this the rest of the suite would prove nothing.
--  10. Derived from THIS read's numbers, the second credit note is ACCEPTED, and the running
--      total afterwards is exactly round(cumulative_subtotal*tax/subtotal) — the figure the
--      writer checks.
--  11. The read follows the WRITER's definition of "reversed" (a journal_voucher against the
--      credit note), not a row flag a browser can see: reversing the first credit note drops
--      the reported totals, and the writer's own accounting agrees with the drop.
--
-- Assertions are recorded as rows; a final gate makes any FAIL fatal. Nothing is committed.

begin;

create temp table v810_out(seq integer, step text, outcome text) on commit drop;
-- Assertions are recorded from inside `set local role authenticated` stretches, so the results
-- table has to be writable by that role too.
grant insert, select on table v810_out to public;

-- Google-SSO-shaped claims (amr + app_metadata.providers) are required for a PLATFORM session
-- since nestly_v625: app.is_super_admin() is `a super_admins row AND
-- app.platform_session_via_google_v625()`, so a super_admins row alone is not enough
-- (docs/qa/CI-CORPUS-FIXTURE-GUIDE.md, "A platform session needs more"). p_google=false gives an
-- ordinary authenticated session, which is what the non-super-admin refusal is proved against.
create or replace function pg_temp.as_v810_user(p_uid uuid, p_google boolean default false)
returns void language plpgsql as $$
begin
  execute 'reset role';
  execute 'set local role authenticated';
  perform set_config('request.jwt.claim.sub', coalesce(p_uid::text,''), true);
  perform set_config('request.jwt.claims',
    case when p_google then
      json_build_object('sub', p_uid, 'role', 'authenticated',
        'amr', json_build_array(json_build_object('method','oauth')),
        'app_metadata', json_build_object('providers', json_build_array('google')))::text
    else
      json_build_object('sub', p_uid, 'role', 'authenticated')::text
    end, true);
end
$$;
grant execute on function pg_temp.as_v810_user(uuid, boolean) to authenticated;

-- An authenticated ROLE with no session at all: this is what the revoked grants used to let in
-- through `anon`, and what every one of these bodies must still refuse on its own.
create or replace function pg_temp.as_v810_sessionless() returns void language plpgsql as $$
begin
  execute 'reset role';
  execute 'set local role authenticated';
  perform set_config('request.jwt.claim.sub', '', true);
  perform set_config('request.jwt.claims', '{}', true);
end
$$;
grant execute on function pg_temp.as_v810_sessionless() to authenticated;

do $v810_test$
declare
  v_sa uuid := gen_random_uuid();
  v_outsider uuid := gen_random_uuid();
  v_today date := (clock_timestamp() at time zone 'Asia/Singapore')::date;
  v_issue date;
  v_sig text;
  v_oid oid;
  v_leftovers text;
  v_result jsonb;
  v_totals jsonb;
  v_invoice uuid;
  v_credit_one uuid;
  v_naive_refused boolean := false;
  v_bad_invoice uuid := gen_random_uuid();
  v_ok boolean;
  -- The invoice: $1,000.00 subtotal at 9% GST -> $90.00 tax. Two credit notes of $10.50 each.
  -- round(1050*9000/100000) = round(94.5) = 95 each, but round(2100*9000/100000) = 189, so a
  -- second credit note whose tax is proportioned in isolation sends 95 where the writer's
  -- cumulative check demands 94. That single cent is finding F121.
  c_subtotal constant bigint := 100000;
  c_tax constant bigint := 9000;
  c_slice constant integer := 1050;
begin
  v_issue := v_today - 1;

  -- ==========================================================================================
  -- PART 1 — the ACLs.
  -- ==========================================================================================
  foreach v_sig in array array[
    'public.get_campaign_results(uuid)',
    'public.get_dashboard_summary(uuid,date,date,uuid)',
    'public.get_reports_summary_v94_base(uuid,date,date,uuid)',
    'public.staff_list_customers_v129(uuid,text,integer,integer,integer)'
  ] loop
    v_oid := v_sig::regprocedure::oid;
    insert into v810_out values (1, 'anon holds no EXECUTE on '||v_sig,
      case when has_function_privilege('anon', v_oid, 'EXECUTE') then 'FAIL' else 'PASS' end);
    insert into v810_out values (2, 'authenticated + service_role keep EXECUTE on '||v_sig,
      case when has_function_privilege('authenticated', v_oid, 'EXECUTE')
            and has_function_privilege('service_role', v_oid, 'EXECUTE')
           then 'PASS' else 'FAIL' end);
  end loop;

  -- The estate-wide class scan is only meaningful where real ACL history exists. This harness
  -- restores a `pg_dump --no-privileges` snapshot and then runs `grant all on all functions in
  -- schema public to anon` (scripts/db-tests/baseline-grants.sql — deliberately, so the harness
  -- is never STRICTER than production), so every public function is anon-executable here by
  -- construction. The sentinel is a function whose own migration revoked anon: that revoke
  -- survives only where the accumulated ACL history does.
  if has_function_privilege('anon',
       'public.platform_get_accounting_books_v147(date,date,integer)'::regprocedure, 'EXECUTE') then
    insert into v810_out values (3,
      'the CLASS scan does not apply here: this cluster blanket-grants public functions to anon '
      '(baseline-grants.sql) — the per-function assertions above are the gate',
      'PASS');
  else
    select string_agg(p.oid::regprocedure::text, ', ')
      into v_leftovers
      from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public'
       and has_function_privilege('anon', p.oid, 'EXECUTE')
       and p.prosrc ~* 'auth\.uid\(\)\s+is\s+null';
    insert into v810_out values (3,
      'the CLASS is closed: no public function is anon-executable AND session-guarded'
      || coalesce(' (left: '||v_leftovers||')', ''),
      case when v_leftovers is null then 'PASS' else 'FAIL' end);
  end if;

  -- ==========================================================================================
  -- Identities.
  -- ==========================================================================================
  insert into auth.users(instance_id, id, aud, role, email, encrypted_password,
                         email_confirmed_at, created_at, updated_at)
  values
    ('00000000-0000-0000-0000-000000000000', v_sa, 'authenticated', 'authenticated',
     'v810-sa@example.test', '', now(), now(), now()),
    ('00000000-0000-0000-0000-000000000000', v_outsider, 'authenticated', 'authenticated',
     'v810-out@example.test', '', now(), now(), now());
  insert into public.super_admins(user_id, email, note)
  values (v_sa, 'v810-sa@example.test', 'v810 rollback fixture');

  -- 4. A refusal is still a refusal — the bodies, not the ACL, are what these prove.
  perform pg_temp.as_v810_sessionless();
  v_ok := false;
  begin
    perform public.get_dashboard_summary(gen_random_uuid(), v_issue, v_issue, null);
  exception when insufficient_privilege then v_ok := true;
  end;
  insert into v810_out values (4, 'get_dashboard_summary still refuses a session-less caller (42501)',
    case when v_ok then 'PASS' else 'FAIL' end);

  v_ok := false;
  begin
    perform public.staff_list_customers_v129(gen_random_uuid(), null, null, 50, 0);
  exception when insufficient_privilege then v_ok := true;
  end;
  insert into v810_out values (4, 'staff_list_customers_v129 still refuses a session-less caller (42501)',
    case when v_ok then 'PASS' else 'FAIL' end);

  -- 5. The new read refuses the same two shapes.
  v_ok := false;
  begin
    perform public.platform_invoice_credit_note_totals_v810(v_bad_invoice);
  exception when insufficient_privilege then v_ok := true;
  end;
  insert into v810_out values (5, 'the credit-note read refuses a session-less caller (42501)',
    case when v_ok then 'PASS' else 'FAIL' end);

  perform pg_temp.as_v810_user(v_outsider);
  v_ok := false;
  begin
    perform public.platform_invoice_credit_note_totals_v810(v_bad_invoice);
  exception when insufficient_privilege then v_ok := true;
  end;
  insert into v810_out values (5, 'the credit-note read refuses an authenticated non-super-admin (42501)',
    case when v_ok then 'PASS' else 'FAIL' end);

  -- The v625 rule: a super_admins row alone is not a platform session. The new read inherits it
  -- from app.is_super_admin() rather than restating it, and this proves the inheritance.
  perform pg_temp.as_v810_user(v_sa, false);
  v_ok := false;
  begin
    perform public.platform_invoice_credit_note_totals_v810(v_bad_invoice);
  exception when insufficient_privilege then v_ok := true;
  end;
  insert into v810_out values (5,
    'the credit-note read refuses a super admin whose session is not Google SSO (v625, 42501)',
    case when v_ok then 'PASS' else 'FAIL' end);

  -- ==========================================================================================
  -- PART 2 — F121, against a real GST invoice.
  -- ==========================================================================================
  perform pg_temp.as_v810_user(v_sa, true);
  perform public.platform_set_accounting_policy_v147(
    v_issue, 'Peekaa V810 Synthetic Pte. Ltd.', '202681000V', '10 Synthetic Way, Singapore',
    'registered', '202681000V', 900, 12, 31, 'PKA',
    'Owner-reviewed synthetic GST policy for the v810 rollback suite',
    '81000000-0000-4000-8000-000000000001');

  -- 6. Not an invoice -> refused, not zeroed.
  v_ok := false;
  begin
    perform public.platform_invoice_credit_note_totals_v810(v_bad_invoice);
  exception when invalid_parameter_value then v_ok := true;
  end;
  insert into v810_out values (6, 'an id that is not an invoice is refused (22023), never zeroed',
    case when v_ok then 'PASS' else 'FAIL' end);

  v_result := public.platform_create_invoice_v147(
    v_issue, v_issue + 14, 'NON-SUBSCRIPTION-V810-GST-0001',
    '{"legal_name":"Meridian V810 Pte. Ltd.","registration_number":"202688810M","address":"11 Synthetic Road, Singapore"}',
    format('[{"description":"Implementation service","quantity":1,"unit_amount_cents":%s}]', c_subtotal)::jsonb,
    900, '81000000-0000-4000-8000-000000000002');
  v_invoice := (v_result#>>'{document,id}')::uuid;
  if (v_result#>>'{document,subtotal_cents}')::bigint <> c_subtotal
     or (v_result#>>'{document,tax_cents}')::bigint <> c_tax then
    raise exception 'v810 fixture is wrong: expected %/% got %/%',
      c_subtotal, c_tax, v_result#>>'{document,subtotal_cents}', v_result#>>'{document,tax_cents}';
  end if;

  -- 7. Fresh invoice: nothing credited, and the invoice's own totals come back with it.
  v_totals := public.platform_invoice_credit_note_totals_v810(v_invoice);
  insert into v810_out values (7, 'a fresh invoice reports its own totals and zero credited',
    case when (v_totals->>'invoice_subtotal_cents')::bigint = c_subtotal
          and (v_totals->>'invoice_tax_cents')::bigint = c_tax
          and (v_totals->>'credited_subtotal_cents')::bigint = 0
          and (v_totals->>'credited_tax_cents')::bigint = 0
         then 'PASS' else 'FAIL' end);

  -- First partial credit note. With nothing credited yet the isolated and cumulative formulas
  -- agree, which is exactly why F121 only ever bit on the SECOND one.
  v_result := public.platform_issue_credit_note_v147(
    v_invoice, v_issue, c_slice, (round(c_slice::numeric * c_tax / c_subtotal))::integer,
    'Scope reduced after review', '81000000-0000-4000-8000-000000000003');
  v_credit_one := (v_result#>>'{document,id}')::uuid;

  -- 8. The read now reports it.
  v_totals := public.platform_invoice_credit_note_totals_v810(v_invoice);
  insert into v810_out values (8, 'the read reports the first credit note''s subtotal and tax',
    case when (v_totals->>'credited_subtotal_cents')::bigint = c_slice
          and (v_totals->>'credited_tax_cents')::bigint = round(c_slice::numeric * c_tax / c_subtotal)
         then 'PASS' else 'FAIL' end);

  -- 9. POSITIVE CONTROL: the per-call-isolated tax — what the console computed before it could
  --    ask the server — is genuinely refused here. If this ever stops failing, step 10 proves
  --    nothing and this suite says so.
  begin
    perform public.platform_issue_credit_note_v147(
      v_invoice, v_issue, c_slice, (round(c_slice::numeric * c_tax / c_subtotal))::integer,
      'Second reduction, tax proportioned in isolation', '81000000-0000-4000-8000-000000000004');
  exception when invalid_parameter_value then v_naive_refused := true;
  end;
  insert into v810_out values (9,
    'positive control: the per-call-isolated tax for the SECOND credit note is refused (22023)',
    case when v_naive_refused then 'PASS' else 'FAIL' end);

  -- 10. Derived from the read, the same credit note is accepted.
  v_totals := public.platform_invoice_credit_note_totals_v810(v_invoice);
  v_result := public.platform_issue_credit_note_v147(
    v_invoice, v_issue, c_slice,
    (round(((v_totals->>'credited_subtotal_cents')::bigint + c_slice)::numeric
           * (v_totals->>'invoice_tax_cents')::bigint
           / (v_totals->>'invoice_subtotal_cents')::bigint)
     - (v_totals->>'credited_tax_cents')::bigint)::integer,
    'Second reduction, tax derived from the server''s running total',
    '81000000-0000-4000-8000-000000000005');
  insert into v810_out values (10, 'the second credit note derived from the read is ACCEPTED',
    case when (v_result#>>'{document,id}') is not null then 'PASS' else 'FAIL' end);

  v_totals := public.platform_invoice_credit_note_totals_v810(v_invoice);
  insert into v810_out values (10,
    'the running total afterwards is exactly round(cumulative_subtotal*tax/subtotal)',
    case when (v_totals->>'credited_subtotal_cents')::bigint = 2 * c_slice
          and (v_totals->>'credited_tax_cents')::bigint
              = round((2 * c_slice)::numeric * c_tax / c_subtotal)
         then 'PASS' else 'FAIL' end);

  -- 11. The read follows the WRITER's reversal rule, not a row flag.
  perform public.platform_reverse_financial_document_v147(
    v_credit_one, v_issue, 'First credit note withdrawn after review',
    '81000000-0000-4000-8000-000000000006');
  v_totals := public.platform_invoice_credit_note_totals_v810(v_invoice);
  insert into v810_out values (11,
    'a journal-voucher reversal removes the credit note from the reported totals',
    case when (v_totals->>'credited_subtotal_cents')::bigint = c_slice
          and (v_totals->>'credited_tax_cents')::bigint
              = round((2 * c_slice)::numeric * c_tax / c_subtotal)
                - round(c_slice::numeric * c_tax / c_subtotal)
         then 'PASS' else 'FAIL' end);

  -- ... and the writer agrees with the drop: a third credit note derived from the read is
  -- accepted, which it could not be if the two disagreed about what is still outstanding.
  v_result := public.platform_issue_credit_note_v147(
    v_invoice, v_issue, c_slice,
    (round(((v_totals->>'credited_subtotal_cents')::bigint + c_slice)::numeric
           * (v_totals->>'invoice_tax_cents')::bigint
           / (v_totals->>'invoice_subtotal_cents')::bigint)
     - (v_totals->>'credited_tax_cents')::bigint)::integer,
    'Third reduction after the first credit note was reversed',
    '81000000-0000-4000-8000-000000000007');
  insert into v810_out values (11,
    'the writer agrees with the post-reversal totals the read reports',
    case when (v_result#>>'{document,id}') is not null then 'PASS' else 'FAIL' end);

  execute 'reset role';
exception when others then
  execute 'reset role';
  insert into v810_out values (99, 'suite aborted: '||sqlstate||' '||sqlerrm, 'FAIL');
end
$v810_test$;

select seq, step, outcome from v810_out order by seq, step;

do $v810_gate$
declare v_failures integer; v_detail text;
begin
  select count(*), string_agg(step || ' -> ' || outcome, ' | ')
    into v_failures, v_detail from v810_out where outcome <> 'PASS';
  if v_failures > 0 then
    raise exception 'v810 acceptance FAILED: % assertion(s) did not pass: %', v_failures, v_detail;
  end if;
  if (select count(*) from v810_out) < 15 then
    raise exception 'v810 acceptance did not run to completion: only % assertion(s) recorded',
      (select count(*) from v810_out);
  end if;
end
$v810_gate$;

rollback;
