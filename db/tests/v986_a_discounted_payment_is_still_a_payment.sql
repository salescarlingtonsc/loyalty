-- nestly_v986 acceptance — a discounted payment is still a payment.
--
-- Run:  supabase db query --linked -f db/tests/v986_a_discounted_payment_is_still_a_payment.sql
-- Ends by raising V986_RESULT so nothing commits. PASS is an exception saying ALL PASS.
--
-- PROVEN RED FIRST, against production, before the migration existed. Same firm, same settled
-- payment, one variable -- the promo:
--
--     first invoice 100 (full)      -> active     / paid          / source=provider_invoice_self_serve
--     first invoice  85 (15% off)   -> incomplete / not_collected / source=NONE
--   and once activated_at is set, the second arm reads:
--     paid full price               -> active   / join_enabled=true  / 1 active branch
--     paid with 15% promo           -> past_due / join_enabled=FALSE / 0 active branches
--
-- Assertion 2 below keeps that red inside the green: it asserts the OLD predicate
-- (amount_paid_cents = period_total_cents) still does NOT hold for the discounted invoice, so if
-- someone ever restores the old rule the suite says so instead of quietly passing.
--
-- Subject: Hairdressing @ Choa Chu Kang, the one live Stripe payer. Its own invoice is removed
-- inside the transaction so the invoice under test is the FIRST -- which is what a first-payment
-- promo actually discounts.

begin;

do $v986$
declare
  n integer := 0;
  v_biz uuid := '386a7e7b-e234-4eb8-8d73-ecee21834e26';
  v_sub text := 'sub_1UCaf5LjvwAsL93HgquLMyLC';
  v_tmpl public.billing_provider_invoices%rowtype;
  v_period integer;
  v_state text;
  v_join boolean;
  v_branches integer;
  v_refused boolean;

begin
  select period_total_cents into v_period from public.subscriptions where business_id = v_biz;
  select * into v_tmpl from public.billing_provider_invoices
   where provider_subscription_id = v_sub order by created_at desc limit 1;
  if v_tmpl.business_id is null then
    raise exception 'V986 INCONCLUSIVE: the subject has no invoice to clone';
  end if;

  -- ==========================================================================================
  -- 1 · THE CONSTRAINT CAN NOW HOLD A DISCOUNT -- and still refuses an inconsistent row.
  -- ==========================================================================================
  delete from public.billing_provider_invoices where business_id = v_biz;

  insert into public.billing_provider_invoices
    (business_id, provider_customer_id, provider_subscription_id, provider_invoice_id,
     currency, collection_method, status, paid_normalized,
     subtotal_ex_tax_cents, tax_cents, discount_cents, total_cents,
     amount_due_cents, amount_paid_cents, amount_remaining_cents, net_cash_ex_tax_cents,
     period_start, period_end, paid_at, finalized_at, livemode,
     provider_event_created_at, provider_event_rank, last_event_id)
  values (v_biz, v_tmpl.provider_customer_id, v_sub, 'in_V986_discounted',
     v_tmpl.currency, v_tmpl.collection_method, 'paid', true,
     v_period, 0, (v_period * 15) / 100, v_period - (v_period * 15) / 100,
     v_period - (v_period * 15) / 100, v_period - (v_period * 15) / 100, 0,
     v_period - (v_period * 15) / 100,
     v_tmpl.period_start, v_tmpl.period_end, v_tmpl.paid_at, v_tmpl.finalized_at, v_tmpl.livemode,
     v_tmpl.provider_event_created_at, v_tmpl.provider_event_rank, 'evt_v986_disc');
  n := n + 1;

  v_refused := false;
  begin
    update public.billing_provider_invoices
       set discount_cents = discount_cents + 1   /* total no longer equals subtotal - discount + tax */
     where provider_invoice_id = 'in_V986_discounted';
  exception when check_violation then v_refused := true;
  end;
  if not v_refused then
    raise exception 'V986 ASSERT 1 FAILED: the identity CHECK accepted total <> subtotal - discount + tax';
  end if;
  n := n + 1;

  -- ==========================================================================================
  -- 2 · THE OLD RULE WOULD STILL MISS IT. This is the red, kept inside the green.
  -- ==========================================================================================
  if exists (select 1 from public.billing_provider_invoices
              where provider_invoice_id = 'in_V986_discounted'
                and amount_paid_cents = v_period) then
    raise exception 'V986 ASSERT 2 FAILED: the discounted invoice pays the list price, so this suite is not testing a discount';
  end if;
  n := n + 1;

  -- ==========================================================================================
  -- 3 · AND THE NEW RULE FINDS IT. The firm paid; the firm reads as paid.
  -- ==========================================================================================
  perform app.v510_sync_payment_readiness(v_biz, null);
  select status||' / '||payment_status||' / '||coalesce(initial_payment_source,'NONE')
    into v_state from public.subscriptions where business_id = v_biz;
  if v_state <> 'active / paid / provider_invoice_self_serve' then
    raise exception 'V986 ASSERT 3 FAILED: a discounted first payment reads as "%"', v_state;
  end if;
  n := n + 1;

  -- ==========================================================================================
  -- 4 · A LIVE FIRM KEEPS ITS DOORS OPEN. This is the harm the defect actually did.
  -- ==========================================================================================
  update public.businesses set activated_at = now(), join_enabled = true where id = v_biz;
  update public.branches set active = true where business_id = v_biz;
  perform app.v510_sync_payment_readiness(v_biz, null);

  select b.join_enabled, (select count(*) from public.branches br
                           where br.business_id = v_biz and br.active)
    into v_join, v_branches
    from public.businesses b where b.id = v_biz;
  if not v_join or v_branches = 0 then
    raise exception 'V986 ASSERT 4 FAILED: an activated firm that paid with a promo lost join_enabled=% / active branches=%',
      v_join, v_branches;
  end if;
  n := n + 1;

  -- ==========================================================================================
  -- 5 · FAIL CLOSED. Settling only part of a discounted invoice is not payment.
  -- ==========================================================================================
  update public.billing_provider_invoices
     set amount_paid_cents = greatest(total_cents - 1, 0),
         amount_remaining_cents = least(total_cents, 1)
   where provider_invoice_id = 'in_V986_discounted';
  perform app.v510_sync_payment_readiness(v_biz, null);
  select status||' / '||payment_status into v_state
    from public.subscriptions where business_id = v_biz;
  if v_state = 'active / paid' then
    raise exception 'V986 ASSERT 5 FAILED: an underpaid discounted invoice was accepted as payment';
  end if;
  n := n + 1;

  -- ==========================================================================================
  -- 6 · THE CONTROL. Full price, paid in full, still reads as paid -- so assertion 3 is measuring
  --     the discount and not merely the fact that an invoice exists.
  -- ==========================================================================================
  delete from public.billing_provider_invoices where business_id = v_biz;
  insert into public.billing_provider_invoices
    (business_id, provider_customer_id, provider_subscription_id, provider_invoice_id,
     currency, collection_method, status, paid_normalized,
     subtotal_ex_tax_cents, tax_cents, discount_cents, total_cents,
     amount_due_cents, amount_paid_cents, amount_remaining_cents, net_cash_ex_tax_cents,
     period_start, period_end, paid_at, finalized_at, livemode,
     provider_event_created_at, provider_event_rank, last_event_id)
  values (v_biz, v_tmpl.provider_customer_id, v_sub, 'in_V986_full',
     v_tmpl.currency, v_tmpl.collection_method, 'paid', true,
     v_period, 0, 0, v_period,
     v_period, v_period, 0, v_period,
     v_tmpl.period_start, v_tmpl.period_end, v_tmpl.paid_at, v_tmpl.finalized_at, v_tmpl.livemode,
     v_tmpl.provider_event_created_at, v_tmpl.provider_event_rank, 'evt_v986_full');
  perform app.v510_sync_payment_readiness(v_biz, null);
  select status||' / '||payment_status into v_state
    from public.subscriptions where business_id = v_biz;
  if v_state <> 'active / paid' then
    raise exception 'V986 ASSERT 6 FAILED: a full-price payment reads as "%"', v_state;
  end if;
  n := n + 1;

  -- ==========================================================================================
  -- 7 · D23 CAN ACTUALLY FIRE. A scanner rule that has never been seen to detect anything is a
  --     comment. This forces the exact state D23 exists for and checks it reports, then clears it
  --     and checks it goes quiet -- both directions, on a real row.
  -- ==========================================================================================
  update public.subscriptions set payment_status = 'not_collected' where business_id = v_biz;
  select count(*) into v_branches
    from public.subscriptions s
    join public.billing_provider_invoices i
      on i.business_id = s.business_id and i.provider_subscription_id = s.provider_subscription_id
   where s.business_id = v_biz
     and i.paid_normalized and i.status = 'paid' and i.amount_remaining_cents = 0
     and i.amount_paid_cents = i.total_cents
     and i.subtotal_ex_tax_cents = s.period_total_cents
     and coalesce(s.payment_status,'') <> 'paid'
     and not exists (select 1 from public.billing_adjustments a
                      where a.provider_invoice_id = i.provider_invoice_id
                        and a.adjustment_type in ('refund','chargeback'));
  if v_branches <> 1 then
    raise exception 'V986 ASSERT 7 FAILED: D23 did not report a firm that paid in full and reads unpaid (saw %)', v_branches;
  end if;

  update public.subscriptions set payment_status = 'paid' where business_id = v_biz;
  select count(*) into v_branches
    from public.subscriptions s
    join public.billing_provider_invoices i
      on i.business_id = s.business_id and i.provider_subscription_id = s.provider_subscription_id
   where s.business_id = v_biz
     and i.paid_normalized and i.status = 'paid' and i.amount_remaining_cents = 0
     and i.amount_paid_cents = i.total_cents
     and i.subtotal_ex_tax_cents = s.period_total_cents
     and coalesce(s.payment_status,'') <> 'paid';
  if v_branches <> 0 then
    raise exception 'V986 ASSERT 7 FAILED: D23 still reports the firm after it reads as paid';
  end if;
  n := n + 1;

  raise exception 'V986_RESULT ALL PASS (% assertions)', n;
end
$v986$;

rollback;
