-- nestly_v984 — the promo record states the discount that was actually given, or states nothing.
--
-- FOUND BY AUDITING THE MONEY, at the owner's request, after v967 shipped. Two reproducible
-- misstatements, one on each billing path. Neither has touched a real record yet — every promo
-- redemption in production is unconsumed or removed, and every provider invoice carries a zero
-- discount — but both would have written false figures the first time a discount was actually used.
--
-- MANUAL PATH. v961's consumer does not record the discount; it RECOMPUTES one from the list price
-- and writes that. The operator, however, types the discount on the invoice by hand, so the two
-- are free to disagree:
--
--   invoice subtotal 118800, operator entered 0        -> merchant paid 118800, record claimed 23760
--   invoice subtotal 118800, operator entered 50000    -> merchant got 50000 off, record claimed 23760
--
-- The first overstates discounts given and burns a voucher the merchant received nothing for. The
-- second understates it by 262.40. A ledger that computes what should have happened instead of
-- recording what did is not a ledger.
--
-- PROVIDER PATH. Worse, because both halves are wrong. consumed_list_cents was set to the invoice
-- TOTAL — which is already net of the Stripe coupon — and the discount was then recomputed from
-- that same net figure. On a 148.00 invoice discounted 15%, the record would read list 12580 and
-- discount 1887, when the truth is list 14800 and discount 2220.
--
-- AND THE PROVIDER DISCOUNT CANNOT BE RECOVERED FROM WHAT WE STORE. stripe-billing-reconcile
-- captures no discount field at all, and it DERIVES tax as (total - subtotal), so
-- subtotal + tax - total is identically zero by construction for every row — the discount is not
-- merely missing, it is arithmetically invisible. A coupon that makes total < subtotal also drives
-- that derived tax negative, where max(...,0) silently swallows it.
--
-- So this migration does the only honest thing available on each path:
--   * manual   — record the invoice's OWN subtotal_cents and discount_cents, verbatim, no arithmetic
--   * provider — record NOTHING (both columns null: "not captured"), and keep the true observation,
--                the invoice id and total actually charged, in the audit detail
--
-- Null is deliberate and is not the same as zero. Zero asserts "no discount was given"; null admits
-- "Peekaa did not observe it". Recording the figure Stripe really applied needs the reconciler to
-- capture the invoice's discount and its real tax — a separate change, on the edge function, that
-- cannot be verified until a genuinely discounted provider invoice exists.
--
-- A DISCOUNT OF ZERO NO LONGER SPENDS THE VOUCHER. If the invoice gave nothing away the merchant
-- received nothing, so the code stays with them for the next one. Unknown (null) still consumes:
-- eligibility is a separate question from bookkeeping, and leaving provider firms unable to hold a
-- second code is the v965 trap all over again.

begin;

create or replace function app.promo_consume_v984(
  p_business uuid, p_list_cents integer, p_discount_cents integer,
  p_payment_reference text, p_source text
)
returns void
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_row public.platform_promo_redemptions_v961%rowtype;
begin
  select * into v_row from public.platform_promo_redemptions_v961
   where business_id = p_business and removed_at is null and consumed_at is null
   for update skip locked;
  if v_row.id is null then
    return;
  end if;
  /* The invoice gave nothing away, so nothing was spent. Leave the code with the merchant. */
  if p_discount_cents is not null and p_discount_cents <= 0 then
    insert into public.audit_log(business_id, actor, action, entity, entity_id, detail)
    values (p_business, auth.uid(), 'promo_code_not_consumed', 'platform_promo_redemptions_v961',
      v_row.id, jsonb_build_object('source', p_source, 'reason', 'no_discount_given',
        'list_cents', p_list_cents, 'payment_reference', p_payment_reference));
    return;
  end if;

  update public.platform_promo_redemptions_v961
     set consumed_at = now(),
         consumed_payment_reference = p_payment_reference,
         consumed_list_cents = p_list_cents,
         consumed_discount_cents = p_discount_cents
   where id = v_row.id;

  insert into public.audit_log(business_id, actor, action, entity, entity_id, detail)
  values (p_business, auth.uid(), 'promo_code_consumed', 'platform_promo_redemptions_v961',
    v_row.id, jsonb_build_object('source', p_source,
      'discount_kind', v_row.discount_kind, 'percent_bps', v_row.percent_bps,
      'amount_cents', v_row.amount_cents,
      'recorded_list_cents', p_list_cents,
      'recorded_discount_cents', p_discount_cents,
      'discount_observed', p_discount_cents is not null,
      'payment_reference', p_payment_reference));
end
$$;

comment on function app.promo_consume_v984(uuid, integer, integer, text, text) is
  'nestly_v984: spends a promo against a payment, recording the list and discount it is GIVEN rather than recomputing them. Null discount means Peekaa did not observe the figure; zero or less means no discount was given, and the voucher is left unspent.';

revoke all on function app.promo_consume_v984(uuid, integer, integer, text, text) from public, anon, authenticated;

/* nestly_v984: repoint every consumer, by extraction, with asserted-unique needles. */
do $patch$
declare
  v_def text;
  v_hits integer;
  v_target text;
  v_old text;
  v_new text;
  v_targets text[] := array[
    'public.platform_verify_manual_payment_v156',
    'app.consume_provider_promos_v965',
    'public.platform_record_subscription_payment_v664'
  ];
  v_olds text[] := array[
    'perform app.promo_consume_v961(v_invoice.business_id, v_invoice.subtotal_cents::integer, v_payment.payment_reference);',
    E'consumed_list_cents = v_row.total_cents,\n           consumed_discount_cents = coalesce(\n             app.promo_discount_cents_v961(v_row.discount_kind, v_row.percent_bps,\n                                           v_row.amount_cents, v_row.total_cents), 0)',
    'app.promo_consume_v961(p_business, p_amount_cents, p_payment_reference)'
  ];
  v_news text[] := array[
    /* the invoice's own numbers: what was billed, and what was taken off it */
    'perform app.promo_consume_v984(v_invoice.business_id, v_invoice.subtotal_cents::integer, v_invoice.discount_cents::integer, v_payment.payment_reference, ''platform_verify_manual_payment_v156'');',
    E'consumed_list_cents = null,   /* nestly_v984: not captured, see the migration note */\n           consumed_discount_cents = null',
    'app.promo_consume_v984(p_business, null, null, p_payment_reference, ''platform_record_subscription_payment_v664'')'
  ];
  i integer;
begin
  for i in 1 .. array_length(v_targets, 1) loop
    v_target := v_targets[i]; v_old := v_olds[i]; v_new := v_news[i];
    select pg_get_functiondef(p.oid) into v_def
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = split_part(v_target, '.', 1) and p.proname = split_part(v_target, '.', 2);
    if v_def is null then
      raise exception 'v984: % does not exist', v_target;
    end if;
    v_hits := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
    if v_hits <> 1 then
      raise exception 'v984: expected exactly 1 consumer call in %, found %', v_target, v_hits;
    end if;
    execute replace(v_def, v_old, v_new);
  end loop;
end
$patch$;

/* nestly_v984: the audit detail of the provider sweep should say what it did and did not see. */
do $audit$
declare
  v_def text;
  v_old text := E'jsonb_build_object(''source'', ''app.consume_provider_promos_v965'',\n        ''provider_invoice_id'', v_row.provider_invoice_id,\n        ''invoice_total_cents'', v_row.total_cents, ''paid_at'', v_row.paid_at)';
  v_new text := E'jsonb_build_object(''source'', ''app.consume_provider_promos_v965'',\n        ''provider_invoice_id'', v_row.provider_invoice_id,\n        ''invoice_total_cents'', v_row.total_cents, ''paid_at'', v_row.paid_at,\n        ''discount_observed'', false,\n        ''note'', ''nestly_v984: the provider discount is not captured, so no figure is recorded'')';
begin
  select pg_get_functiondef(p.oid) into v_def
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'app' and p.proname = 'consume_provider_promos_v965';
  if (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 then
    raise exception 'v984: expected exactly 1 audit payload in app.consume_provider_promos_v965';
  end if;
  execute replace(v_def, v_old, v_new);
end
$audit$;

/* nestly_v984: nothing may call the recomputing consumer again. PL/pgSQL resolves names at run
   time, so a leftover caller would fail only in production — the three above were repointed first
   and this drop is the proof that none remain. */
do $drop$
declare
  v_stragglers text;
begin
  select string_agg(n.nspname||'.'||p.proname, ', ') into v_stragglers
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    join pg_language l on l.oid = p.prolang
   where l.lanname in ('plpgsql','sql') and p.prokind = 'f'
     and n.nspname in ('public','app')
     and p.proname <> 'promo_consume_v961'
     and pg_get_functiondef(p.oid) like '%promo_consume_v961%';
  if v_stragglers is not null then
    raise exception 'v984: these still call the old consumer: %', v_stragglers;
  end if;
end
$drop$;

drop function if exists app.promo_consume_v961(uuid, integer, text);

commit;
