-- nestly_v990 — provider-cleared cash must prove it came from a live invoice.
--
-- v989 guarded the ledger against sandbox money and was INCOMPLETE. Found by checking rather than
-- assuming: after applying it, 22 of the 66 queued revenue slices were blocked and 44 were not.
--
-- v989 asked "is there a billing_provider_invoices row for this period that is NOT livemode". That
-- catches a period whose invoice_reference is a Stripe invoice id. It does nothing for the other
-- four periods, whose invoice_reference is a bare UUID with no matching row at all - the retired
-- Razorpay firms (see nestly_v984). Absence of evidence read as evidence of innocence, and 44
-- slices worth 447,868 cents stayed armed to recognise from 2026-10-04.
--
-- THE RULE THAT ACTUALLY HOLDS: money sitting in a PROVIDER clearing account must be traceable to
-- a live provider invoice. Account 1010 exists precisely because a payment processor is holding
-- that cash; if no livemode invoice can be produced for it, the processor is not holding it and it
-- is not revenue. Stated positively - prove it is live - rather than negatively, so a missing row,
-- a retired provider, a renamed id or a provider we have not integrated yet all fail closed.
--
-- Manual firms are deliberately untouched. They clear through 1000, are invoiced by hand and pay by
-- bank transfer, and have no provider invoice to produce. The guard only speaks about 1010.
--
-- Measured against production before applying: 66 of 66 pending slices blocked, 0 manual periods
-- affected.

begin;

do $patch$
declare
  v_def text;
  v_hits integer;
begin
  -- (1) recognition: a slice may only be earned if its period's cash is provably live
  select pg_get_functiondef(p.oid) into v_def
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'app' and p.proname = 'v200_recognize_due_months';
  v_hits := (length(v_def) - length(replace(v_def,
    $old1$       and not exists (select 1 from public.billing_provider_invoices bad
                        where bad.provider_invoice_id = p.invoice_reference
                          and not coalesce(bad.livemode,false))$old1$, ''))) /
    length($len1$       and not exists (select 1 from public.billing_provider_invoices bad
                        where bad.provider_invoice_id = p.invoice_reference
                          and not coalesce(bad.livemode,false))$len1$);
  if v_hits <> 1 then
    raise exception 'v990: expected exactly 1 v989 recognition guard, found %', v_hits;
  end if;
  execute replace(v_def,
    $old2$       and not exists (select 1 from public.billing_provider_invoices bad
                        where bad.provider_invoice_id = p.invoice_reference
                          and not coalesce(bad.livemode,false))$old2$,
    $new2$       /* nestly_v990: cash held by a payment processor must be traceable to a LIVE
          invoice. Stated positively so a missing row, a retired provider or an id we cannot
          match all fail closed. Manual periods clear through 1000 and are untouched. */
       and (p.cash_account_code <> '1010'
            or exists (select 1 from public.billing_provider_invoices good
                        where good.provider_invoice_id = p.invoice_reference
                          and coalesce(good.livemode,false)))$new2$);

  -- (2) capture: never open a deferral period for provider cash that cannot prove itself
  select pg_get_functiondef(p.oid) into v_def
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'app' and p.proname = 'v200_capture_paid_periods';
  v_hits := (length(v_def) - length(replace(v_def,
    $old3$       and not exists (select 1 from public.billing_provider_invoices bad
                        where bad.provider_invoice_id = nullif(btrim(coalesce(s.last_paid_invoice_id,'')),'')
                          and not coalesce(bad.livemode,false))$old3$, ''))) /
    length($len3$       and not exists (select 1 from public.billing_provider_invoices bad
                        where bad.provider_invoice_id = nullif(btrim(coalesce(s.last_paid_invoice_id,'')),'')
                          and not coalesce(bad.livemode,false))$len3$);
  if v_hits <> 1 then
    raise exception 'v990: expected exactly 1 v989 capture guard, found %', v_hits;
  end if;
  execute replace(v_def,
    $old4$       and not exists (select 1 from public.billing_provider_invoices bad
                        where bad.provider_invoice_id = nullif(btrim(coalesce(s.last_paid_invoice_id,'')),'')
                          and not coalesce(bad.livemode,false))$old4$,
    $new4$       /* nestly_v990: a provider-billed subscription must produce a LIVE paid invoice
          before its cash is deferred. A manual firm has no provider subscription and passes. */
       and (s.provider_subscription_id is null
            or exists (select 1 from public.billing_provider_invoices good
                        where good.provider_invoice_id = nullif(btrim(coalesce(s.last_paid_invoice_id,'')),'')
                          and coalesce(good.livemode,false)))$new4$);
end
$patch$;

commit;
