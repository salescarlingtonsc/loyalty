-- nestly_v967 — a voucher is spent when the manual payment for it is verified.
--
-- FOUND BY USING IT, as a real user, through the console. A 20% code was applied to a manually
-- billed firm and the promo card said, in its own words:
--
--     "Charge the merchant this much less on their first payment.
--      Recording that payment uses the code up."
--
-- The second sentence was false. v961 hung consumption on
-- platform_record_subscription_payment_v664 — and NOTHING calls that function. Not the platform
-- console, not the business app, not an edge function, not another database function; the only
-- mention of it anywhere outside the migrations is a line in the writer registry. So on the path
-- the product actually uses, the code stayed "Waiting for the first payment" for ever: the firm
-- went on holding a voucher it had already been given the money off, the console kept showing a
-- promise it could not keep, and before v966 that firm could never be given another code.
--
-- This is the same defect class v965 closed for Stripe. v961 was written for a manual-billing
-- flow that was never the one in the product.
--
-- THE REAL FLOW is dual-control and lives in v156: a manual invoice is raised, one super admin
-- records the payment with bank evidence, and a DIFFERENT super admin verifies it, which issues
-- the receipt and moves the billing period (app.v680_manual_payment_period). Verification is the
-- honest moment to spend the voucher — not the recording, which a second person may still reject.
-- Rejection returns before this point, so a refused payment leaves the code untouched.
--
-- WHY THE SUBTOTAL AND NOT THE AMOUNT COLLECTED. The operator enters the discount on the invoice,
-- so the cash received is already net of it. Passing the collected amount would state the promo
-- against the discounted figure and under-record what the merchant was given. The invoice
-- subtotal is the list price the discount came off, so consumed_list_cents and
-- consumed_discount_cents describe the deal as it was actually struck.
--
-- platform_record_subscription_payment_v664 is deliberately left alone. It is unreachable rather
-- than wrong, and removing its promo hook would be a second change with no caller to benefit.

begin;

/* nestly_v967: patched by extraction, with an asserted-unique needle, so nothing else in this
   long function moves. The needle is the last statement of the verified branch. */
do $patch$
declare
  v_def text;
  v_hits integer;
  v_old text := 'perform app.v680_manual_payment_period(v_payment.id,v_actor);';
  v_new text;
begin
  select pg_get_functiondef(p.oid) into v_def
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'platform_verify_manual_payment_v156';
  if v_def is null then
    raise exception 'v967: public.platform_verify_manual_payment_v156 does not exist';
  end if;
  v_hits := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if v_hits <> 1 then
    raise exception 'v967: expected exactly 1 occurrence of the period-move call, found %', v_hits;
  end if;

  v_new := v_old
    || E'\n  /* nestly_v967: the money is verified, so the voucher this firm was holding is spent.'
    || E'\n     The list price is the invoice SUBTOTAL, before the discount the operator entered, so'
    || E'\n     the discount recorded here is the one the merchant actually received.'
    || E'\n     The invoice money columns are bigint and the consumer takes integer, so the cast is'
    || E'\n     explicit rather than left for Postgres to guess at. */'
    || E'\n  perform app.promo_consume_v961(v_invoice.business_id, v_invoice.subtotal_cents::integer, v_payment.payment_reference);';

  execute replace(v_def, v_old, v_new);
end
$patch$;

comment on function public.platform_verify_manual_payment_v156(uuid, text, text, uuid) is
  'nestly_v156 + v967: the second super admin verifies manual payment evidence, which issues the receipt, moves the billing period and — since v967 — spends any promo code the firm was holding. A rejection returns before all three.';

commit;
