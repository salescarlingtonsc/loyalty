-- Rollback-only v225 acceptance: one read tells the whole story of one firm.
--
-- Production carries no financial documents and no manual payments yet, and no
-- business is linked to an originating prospect, so this suite SEEDS the shapes
-- it asserts on and rolls the whole lot back. Asserting only against live rows
-- would prove nothing about outstanding balances or payment history — the very
-- things the drawer exists to show.
begin;

do $v225$
declare
  v_sa uuid; v_other uuid;
  v_company uuid; v_prospect uuid; v_sme uuid; v_seller uuid;
  v_inv_open uuid; v_inv_paid uuid;
  v_today date := (clock_timestamp() at time zone 'Asia/Singapore')::date;
  d jsonb; row jsonb; dir jsonb;
begin
  select user_id into v_sa from public.super_admins limit 1;
  if v_sa is null then raise exception 'no super admin configured'; end if;
  select id into v_other from auth.users where id <> v_sa limit 1;
  select id into v_seller from public.platform_billing_profiles_v156 limit 1;
  if v_seller is null then raise exception 'no billing profile configured'; end if;

  perform set_config('request.jwt.claim.sub', v_sa::text, true);
  perform set_config('request.jwt.claims',
    json_build_object('sub',v_sa,'role','authenticated')::text, true);

  ---------------------------------------------------------------- seed
  insert into public.sme_companies(legal_name, trading_name, industry)
    values ('ZZ V225 ACCEPTANCE PTE LTD','ZZ V225','cafe') returning id into v_sme;
  insert into public.sme_prospects(company_id, legacy_stage_raw)
    values (v_sme,'v225-acceptance') returning id into v_prospect;
  -- Deliberately inserted secondary-first: the RPC, not the insert order, must
  -- put the primary contact at the top of the drawer.
  insert into public.sme_prospect_contacts(prospect_id, full_name, title, email, phone, is_primary, active)
    values (v_prospect,'ZZ Second Contact','Manager','second@example.test','+65 8000 0002',false,true),
           (v_prospect,'ZZ Primary Contact','Owner','primary@example.test','+65 8000 0001',true,true),
           (v_prospect,'ZZ Departed Contact','Ex','gone@example.test','+65 8000 0003',false,false);

  insert into public.businesses(name, slug, industry, legal_name, source_prospect_id, is_synthetic)
    values ('ZZ V225 Acceptance Cafe','zz-v225-acceptance','cafe',
            'ZZ V225 ACCEPTANCE PTE LTD', v_prospect, true)
    returning id into v_company;

  insert into public.subscriptions(business_id, status, billing_provider, billing_cadence,
      cadence_months, currency, base_price_cents, next_payment_at, current_period_start, current_period_end)
    values (v_company,'active','manual','monthly',1,'SGD',9900,
            ((v_today - 5)::timestamp at time zone 'Asia/Singapore'),
            ((v_today - 35)::timestamp at time zone 'Asia/Singapore'),
            ((v_today - 5)::timestamp at time zone 'Asia/Singapore'));

  -- Two invoices: one settled, one still open and 12 days past its due date,
  -- plus a receipt, so "outstanding" has something to exclude as well as count.
  insert into public.platform_subscription_documents_v156(
      document_type, document_number, business_id, seller_profile_id, issue_date, due_date,
      subtotal_cents, discount_cents, tax_cents, total_cents, amount_paid_cents, balance_due_cents,
      finalized_at, snapshot_sha256, operation_key, request_hash)
    values ('invoice','ZZ-V225-OPEN', v_company, v_seller, v_today - 26, v_today - 12,
            9900,0,0,9900,0,9900, clock_timestamp(), repeat('a',64), gen_random_uuid(), repeat('b',64))
    returning id into v_inv_open;
  insert into public.platform_subscription_documents_v156(
      document_type, document_number, business_id, seller_profile_id, issue_date, due_date,
      subtotal_cents, discount_cents, tax_cents, total_cents, amount_paid_cents, balance_due_cents,
      finalized_at, snapshot_sha256, operation_key, request_hash)
    values ('invoice','ZZ-V225-PAID', v_company, v_seller, v_today - 56, v_today - 42,
            9900,0,0,9900,9900,0, clock_timestamp(), repeat('c',64), gen_random_uuid(), repeat('d',64))
    returning id into v_inv_paid;
  insert into public.platform_subscription_documents_v156(
      document_type, document_number, business_id, seller_profile_id, issue_date,
      subtotal_cents, discount_cents, tax_cents, total_cents, amount_paid_cents, balance_due_cents,
      finalized_at, snapshot_sha256, operation_key, request_hash)
    values ('receipt','ZZ-V225-RCPT', v_company, v_seller, v_today - 41,
            9900,0,0,9900,9900,0, clock_timestamp(), repeat('e',64), gen_random_uuid(), repeat('f',64));

  insert into public.platform_manual_payments_v156(
      invoice_document_id, amount_cents, payment_reference, value_date,
      bank_account_last4, evidence_object_path, status, recorded_by,
      request_hash, idempotency_key)
    values (v_inv_open, 9900, 'ZZ-V225-REF-001', v_today - 1, '4417',
            'platform-subscriptions/manual-evidence/zz-v225.pdf',
            'pending_verification', v_sa, repeat('1',64), gen_random_uuid());

  ---------------------------------------------------------------- assertions
  d := public.platform_company_detail_v225(v_company);

  -- A. Identity.
  if d#>>'{company,id}' <> v_company::text then raise exception 'A: wrong company returned'; end if;
  if d#>>'{company,sector}' <> 'cafe' then raise exception 'A: sector not carried through'; end if;
  if d#>>'{company,legal_name}' is null then raise exception 'A: legal name missing'; end if;

  -- B. The drawer and the directory must never disagree about lateness or
  --    collection mode; both derive them from the same rule.
  dir := public.platform_company_directory_v202(p_search=>'ZZ V225 Acceptance');
  select i into row from jsonb_array_elements(dir->'items') i
   where i->>'id' = v_company::text;
  if row is null then raise exception 'B: seeded company absent from the directory'; end if;
  if (row->>'days_until_due') is distinct from (d#>>'{subscription,days_until_due}') then
    raise exception 'B: drawer says % days, directory says %',
      d#>>'{subscription,days_until_due}', row->>'days_until_due';
  end if;
  if (row->>'collection_mode') is distinct from (d#>>'{subscription,collection_mode}') then
    raise exception 'B: collection mode disagrees between drawer and directory';
  end if;
  if d#>>'{subscription,collection_mode}' <> 'chase' then
    raise exception 'B: a manual-billing firm must be a chase, got %', d#>>'{subscription,collection_mode}';
  end if;
  if (d#>>'{subscription,days_until_due}')::int <> -5 then
    raise exception 'B: expected 5 days overdue, got %', d#>>'{subscription,days_until_due}';
  end if;

  -- C. Outstanding counts unpaid invoices only, and ages the debt from the
  --    OLDEST unpaid due date.
  if (d#>>'{outstanding,open_invoice_count}')::int <> 1 then
    raise exception 'C: expected 1 open invoice, got %', d#>>'{outstanding,open_invoice_count}';
  end if;
  if (d#>>'{outstanding,balance_due_cents}')::bigint <> 9900 then
    raise exception 'C: outstanding balance is %, expected 9900', d#>>'{outstanding,balance_due_cents}';
  end if;
  if (d#>>'{outstanding,days_outstanding}')::int <> 12 then
    raise exception 'C: expected 12 days outstanding, got %', d#>>'{outstanding,days_outstanding}';
  end if;

  -- D. Payment history returns every document, newest first.
  if jsonb_array_length(d->'payments') <> 3 then
    raise exception 'D: expected 3 documents, got %', jsonb_array_length(d->'payments');
  end if;
  if (d#>>'{payments,0,document_number}') <> 'ZZ-V225-OPEN' then
    raise exception 'D: payment history is not newest-first, first row is %',
      d#>>'{payments,0,document_number}';
  end if;

  -- E. The manual payment travels with its invoice, so proof state is visible
  --    without opening a second screen.
  select i into row from jsonb_array_elements(d->'payments') i
   where i->>'id' = v_inv_open::text;
  if row->>'manual_status' <> 'pending_verification' then
    raise exception 'E: manual payment state missing on the open invoice, got %', row->>'manual_status';
  end if;
  if row->>'manual_bank_last4' <> '4417' or row->>'manual_reference' <> 'ZZ-V225-REF-001' then
    raise exception 'E: manual payment evidence fields did not travel with the invoice';
  end if;
  select i into row from jsonb_array_elements(d->'payments') i
   where i->>'id' = v_inv_paid::text;
  if row->>'manual_status' is not null then
    raise exception 'E: an unrelated manual payment leaked onto the settled invoice';
  end if;

  -- F. Contacts come from the originating prospect, primary first, inactive out.
  if jsonb_array_length(d->'contacts') <> 2 then
    raise exception 'F: expected 2 active contacts, got %', jsonb_array_length(d->'contacts');
  end if;
  if (d#>>'{contacts,0,full_name}') <> 'ZZ Primary Contact' then
    raise exception 'F: primary contact is not first, got %', d#>>'{contacts,0,full_name}';
  end if;
  if (d#>>'{contacts,0,phone}') is null then
    raise exception 'F: contact phone missing — call and WhatsApp would be dead buttons';
  end if;

  -- G. The payment limit is honoured and announces its own truncation.
  d := public.platform_company_detail_v225(v_company, 1);
  if jsonb_array_length(d->'payments') <> 1 then
    raise exception 'G: payment limit ignored, got % rows', jsonb_array_length(d->'payments');
  end if;
  if (d->>'payments_truncated')::boolean is not true then
    raise exception 'G: truncation was not reported';
  end if;

  -- H. A firm with no prospect returns an empty contact list rather than
  --    borrowing somebody else's.
  d := public.platform_company_detail_v225(
    (select id from public.businesses where source_prospect_id is null limit 1));
  if jsonb_array_length(d->'contacts') <> 0 then
    raise exception 'H: a prospect-less firm was given contacts';
  end if;

  -- I. Unknown company is an error, not an empty drawer that looks like a
  --    company with nothing in it.
  begin
    perform public.platform_company_detail_v225(gen_random_uuid());
    raise exception 'I: an unknown company id was accepted';
  exception when sqlstate 'P0002' then null;
  end;

  -- J. Access is super-admin only.
  if v_other is not null then
    perform set_config('request.jwt.claim.sub', v_other::text, true);
    perform set_config('request.jwt.claims',
      json_build_object('sub',v_other,'role','authenticated')::text, true);
    begin
      perform public.platform_company_detail_v225(v_company);
      raise exception 'J: a non-super-admin read a company drawer';
    exception when sqlstate '42501' then null;
    end;
  end if;

  raise notice 'v225 company detail: all assertions passed';
end $v225$;

rollback;
