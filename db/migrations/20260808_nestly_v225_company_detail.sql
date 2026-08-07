-- NESTLY v225 — everything about one company, in one read.
--
-- The Companies directory (v203, function platform_company_directory_v202)
-- answers "who do I chase today". Clicking a row has to answer the next
-- question — "what is the story with this firm" — without the operator
-- opening four screens and reconciling them by eye.
--
-- One RPC, not several, for the same reason the directory is one RPC: a drawer
-- assembled from four calls can show four mutually inconsistent snapshots of a
-- firm whose subscription moved between them.
--
-- What the drawer needs, and where it comes from:
--   identity + sector          public.businesses (+ branch count)
--   subscription + collection  public.subscriptions; billing_provider='stripe'
--                              is auto-collect, everything else is a chase.
--                              Same rule as v203 — stated once per read, never
--                              a second definition of "auto".
--   outstanding                unpaid platform_subscription_documents_v156
--                              invoices; days outstanding is measured from the
--                              OLDEST unpaid due date, because that is the age
--                              of the debt, not of the newest invoice.
--   payment history            invoices and their receipts, newest first, with
--                              the manual-payment record attached where one
--                              exists so the operator can see proof state
--                              (recorded / verified / rejected) inline.
--   contacts                   sme_prospect_contacts on the originating
--                              prospect — businesses carry no contact of their
--                              own, so a firm created outside the CRM shows an
--                              empty contact list rather than a wrong one.
--   consultant                 platform_consultants via the prospect.
--
-- Money is returned in cents and never pre-formatted: the console is
-- trilingual and formats currency per locale.
--
-- Access is super-admin only, matching the directory it is reached from.
-- Consultant-scoped access is deliberately NOT added here; when CRM becomes a
-- consultant-scoped module it gets its own entry point rather than widening
-- this one.

begin;

create or replace function public.platform_company_detail_v225(
  p_business uuid,
  p_payment_limit integer default 24
) returns jsonb language plpgsql security definer stable
set search_path to 'pg_catalog','public','app','pg_temp' as $$
declare
  v_limit integer := least(greatest(coalesce(p_payment_limit,24),1),200);
  v_today date := (clock_timestamp() at time zone 'Asia/Singapore')::date;
  v_company jsonb; v_subscription jsonb; v_outstanding jsonb;
  v_contacts jsonb; v_consultant jsonb; v_payments jsonb; v_lifecycle jsonb;
  v_prospect uuid;
begin
  if auth.uid() is null or not app.is_super_admin() then
    raise exception 'super-admin access is required' using errcode='42501';
  end if;
  if p_business is null then
    raise exception 'a company is required' using errcode='22023';
  end if;

  select b.source_prospect_id,
         jsonb_build_object(
           'id', b.id,
           'name', b.name,
           'legal_name', b.legal_name,
           'slug', b.slug,
           'sector', coalesce(nullif(btrim(b.industry),''),'unclassified'),
           'registration_number', b.registration_number,
           'currency', b.currency,
           'created_at', b.created_at,
           'onboarding_started_at', b.onboarding_started_at,
           'activated_at', b.activated_at,
           'is_demo', b.is_demo,
           'is_synthetic', b.is_synthetic,
           'branch_count', (select count(*) from public.branches br
                             where br.business_id = b.id and br.active),
           'seat_count', (select count(*) from public.staff st
                           where st.business_id = b.id
                             and st.user_id is not null and st.active))
    into v_prospect, v_company
    from public.businesses b
   where b.id = p_business;

  if v_company is null then
    raise exception 'company not found' using errcode='P0002';
  end if;

  select jsonb_build_object(
           'status', s.status,
           'payment_status', s.payment_status,
           'billing_provider', s.billing_provider,
           'collection_mode', case when s.billing_provider='stripe' then 'auto' else 'chase' end,
           'billing_cadence', s.billing_cadence,
           'cadence_months', s.cadence_months,
           'plan_code', s.plan_code,
           'product_code', s.product_code,
           'currency', s.currency,
           'base_price_cents', s.base_price_cents,
           'included_seats', s.included_seats,
           'per_seat_price_cents', s.per_seat_price_cents,
           'seat_limit', s.seat_limit,
           'period_total_cents', s.period_total_cents,
           'trial_ends_at', s.trial_ends_at,
           'current_period_start', s.current_period_start,
           'current_period_end', s.current_period_end,
           'next_payment_at', s.next_payment_at,
           'last_paid_at', s.last_paid_at,
           'cancel_at_period_end', s.cancel_at_period_end,
           'canceled_at', s.canceled_at,
           -- Positive = days until due; negative = days already overdue.
           -- Identical arithmetic to v203 so a row and its drawer never
           -- disagree about whether a firm is late.
           'days_until_due', case when s.next_payment_at is not null
             then ((s.next_payment_at at time zone 'Asia/Singapore')::date - v_today) end)
    into v_subscription
    from public.subscriptions s
   where s.business_id = p_business;

  -- Unpaid invoices only. A credit note or receipt carries no balance to chase.
  select jsonb_build_object(
           'open_invoice_count', count(*),
           'balance_due_cents', coalesce(sum(d.balance_due_cents),0),
           'currency', min(d.currency),
           'oldest_due_date', min(d.due_date),
           'days_outstanding', case when min(d.due_date) is not null
             then greatest(v_today - min(d.due_date), 0) end)
    into v_outstanding
    from public.platform_subscription_documents_v156 d
   where d.business_id = p_business
     and d.document_type = 'invoice'
     and coalesce(d.balance_due_cents,0) > 0;

  select coalesce(jsonb_agg(jsonb_build_object(
           'id', c.id,
           'full_name', c.full_name,
           'title', c.title,
           'email', c.email,
           'phone', c.phone,
           'is_primary', c.is_primary)
         order by c.is_primary desc, c.created_at), '[]'::jsonb)
    into v_contacts
    from public.sme_prospect_contacts c
   where c.prospect_id = v_prospect and c.active;

  select jsonb_build_object(
           'id', consultant.id,
           'display_name', consultant.display_name,
           'active', consultant.active)
    into v_consultant
    from public.sme_prospects prospect
    join public.platform_consultants consultant
      on consultant.id = prospect.assigned_consultant_id
   where prospect.id = v_prospect;

  -- Payment history: every financial document, newest first, with its manual
  -- payment record inline. A firm on auto-collect simply has no manual rows.
  select coalesce(jsonb_agg(to_jsonb(row) order by
           row.issue_date desc nulls last, row.created_at desc), '[]'::jsonb)
    into v_payments
    from (
      select d.id, d.document_type, d.document_number,
             d.issue_date, d.due_date,
             d.service_period_start, d.service_period_end,
             d.currency, d.total_cents, d.amount_paid_cents, d.balance_due_cents,
             d.created_at,
             m.status         as manual_status,
             m.value_date     as manual_value_date,
             m.payment_reference as manual_reference,
             m.bank_account_last4 as manual_bank_last4,
             m.amount_cents   as manual_amount_cents,
             m.verified_at    as manual_verified_at,
             m.rejection_reason as manual_rejection_reason
        from public.platform_subscription_documents_v156 d
        left join lateral (
          select status, value_date, payment_reference, bank_account_last4,
                 amount_cents, verified_at, rejection_reason
            from public.platform_manual_payments_v156
           where invoice_document_id = d.id
           order by (status='verified') desc, created_at desc
           limit 1) m on true
       where d.business_id = p_business
       order by d.issue_date desc nulls last, d.created_at desc
       limit v_limit) row;

  select coalesce(jsonb_agg(jsonb_build_object(
           'lifecycle_status', e.lifecycle_status,
           'source_type', e.source_type,
           'occurred_at', e.occurred_at)
         order by e.occurred_at desc), '[]'::jsonb)
    into v_lifecycle
    from (select lifecycle_status, source_type, occurred_at
            from public.platform_subscription_lifecycle_events_v156
           where business_id = p_business
           order by occurred_at desc
           limit 10) e;

  return jsonb_build_object(
    'today', v_today,
    'company', v_company,
    'subscription', v_subscription,
    'outstanding', coalesce(v_outstanding, jsonb_build_object(
      'open_invoice_count',0,'balance_due_cents',0,
      'currency',null,'oldest_due_date',null,'days_outstanding',null)),
    'contacts', coalesce(v_contacts,'[]'::jsonb),
    'consultant', v_consultant,
    'payments', coalesce(v_payments,'[]'::jsonb),
    'payments_truncated', (select count(*) > v_limit
       from public.platform_subscription_documents_v156
      where business_id = p_business),
    'lifecycle', coalesce(v_lifecycle,'[]'::jsonb));
end $$;

revoke all on function public.platform_company_detail_v225(uuid,integer)
  from public, anon, authenticated;
grant execute on function public.platform_company_detail_v225(uuid,integer)
  to authenticated;

commit;
