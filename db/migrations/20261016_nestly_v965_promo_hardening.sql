-- nestly_v965 — three holes an adversarial probe found in the promo path, all closed.
--
-- The owner asked "test to see if it will break". It did, in three places. None of them had
-- misstated money yet; two of them would have, and the first one had already made a firm
-- permanently unable to receive another promo.
--
-- (1) A STRIPE PROMO WAS NEVER MARKED USED — the worst of the three, and made worse by v964.
--     consumed_at is set only by app.promo_consume_v961, which is called from
--     platform_record_subscription_payment_v664 — the MANUAL recorder a card-billed firm never
--     goes through. So after the coupon went live at Stripe the redemption stayed live forever:
--     the firm could never be given a second code (promo_already_held), the console and the
--     merchant's page both said "Live on the card" long after the discount had been spent, and
--     v964 — correctly refusing to forget a live coupon — then made it unremovable too. A firm
--     that received one promo was locked into it permanently.
--
--     The honest signal that a first-payment discount has been spent is a PAID INVOICE arriving
--     after the coupon was attached. app.consume_provider_promos_v965 watches for exactly that and
--     consumes the redemption, recording the invoice that spent it. It runs on its own pg_cron job
--     for the reason v922's applier does: it is pure SQL over our own rows, so it needs no secret
--     and cannot forge a human actor. Deliberately NOT patched into
--     public.apply_stripe_billing_event_v94_base — that is 28 KB of event ordering and rank
--     arithmetic, and a promo is not worth the blast radius of editing it.
--
-- (2) A CANCELED SUBSCRIPTION ACCEPTED A CODE. Redemption checked that a provider subscription id
--     existed, not that it could still be charged. A merchant could redeem against a dead
--     subscription, the coupon command would fail at Stripe, and they would sit on "not on the
--     card yet" forever with no way to understand why. Refused up front now.
--
-- (3) DELETING A CODE WOULD HAVE ERASED ITS REDEMPTION HISTORY. promo_id was ON DELETE CASCADE, so
--     removing a code would take every record of who used it — including CONSUMED ones, which are
--     evidence of a discount actually given. No delete path exists today (the table has no delete
--     policy and the console only retires), which is why this was a latent hole rather than a
--     live one; the cascade is still the wrong answer for financial evidence. ON DELETE RESTRICT:
--     a code that has been used cannot be deleted at all. Retiring it remains the way to take a
--     code out of circulation, and that already leaves redemptions untouched.
--
-- Rollback suite: db/tests/v965_promo_hardening.sql

begin;

-- ---------------------------------------------------------------------------------------------
-- 1. Redemption history outlives the code.
-- ---------------------------------------------------------------------------------------------
alter table public.platform_promo_redemptions_v961
  drop constraint if exists platform_promo_redemptions_v961_promo_id_fkey;
alter table public.platform_promo_redemptions_v961
  add constraint platform_promo_redemptions_v961_promo_id_fkey
  foreign key (promo_id) references public.platform_promo_codes_v961(id) on delete restrict;

-- ---------------------------------------------------------------------------------------------
-- 2. A subscription that cannot be charged cannot hold a coupon.
-- ---------------------------------------------------------------------------------------------
create or replace function public.business_redeem_promo_code_v961(
  p_business uuid, p_code text
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_actor uuid := auth.uid();
  v_is_sa boolean;
  v_code text := upper(btrim(coalesce(p_code, '')));
  v_promo public.platform_promo_codes_v961%rowtype;
  v_existing public.platform_promo_redemptions_v961%rowtype;
  v_row public.platform_promo_redemptions_v961%rowtype;
  v_sub public.subscriptions%rowtype;
begin
  if v_actor is null then
    raise exception 'authenticated account required' using errcode = '28000';
  end if;
  v_is_sa := app.is_super_admin();
  if not v_is_sa and not exists (
    select 1 from public.staff s
     where s.business_id = p_business and s.user_id = v_actor and s.role = 'owner' and s.active
  ) then
    raise exception 'active owner of this business required' using errcode = '42501';
  end if;

  select * into v_sub from public.subscriptions where business_id = p_business;
  if v_sub.business_id is null then
    raise exception 'no subscription exists for this business' using errcode = '42704';
  end if;
  if v_sub.billing_provider = 'razorpay' then
    raise exception 'promo_razorpay_unsupported' using errcode = '22023';
  end if;
  if v_sub.billing_provider not in ('manual', 'stripe') then
    raise exception 'promo_provider_billed' using errcode = '22023';
  end if;
  if v_sub.billing_provider = 'stripe' then
    if v_sub.provider_subscription_id is null then
      raise exception 'promo_no_provider_subscription' using errcode = '22023';
    end if;
    /* nestly_v965: a dead subscription cannot be discounted. Stripe would refuse the coupon and
       the merchant would sit on "not on the card yet" with nothing to act on, so it is refused
       here where the sentence can say why. */
    if v_sub.status in ('canceled', 'incomplete_expired', 'unpaid') then
      raise exception 'promo_subscription_not_chargeable' using errcode = '22023';
    end if;
  end if;

  select * into v_existing from public.platform_promo_redemptions_v961
   where business_id = p_business and removed_at is null for update;
  if v_existing.id is not null then
    if v_existing.consumed_at is not null then
      raise exception 'promo_already_used' using errcode = '22023';
    end if;
    if v_existing.promo_id = (select id from public.platform_promo_codes_v961 where code_norm = v_code) then
      return jsonb_build_object('status', 'already_redeemed', 'redemption_id', v_existing.id,
        'discount_kind', v_existing.discount_kind, 'percent_bps', v_existing.percent_bps,
        'amount_cents', v_existing.amount_cents, 'provider', v_existing.provider,
        'provider_applied_at', v_existing.provider_applied_at);
    end if;
    raise exception 'promo_already_held' using errcode = '22023';
  end if;

  select * into v_promo from public.platform_promo_codes_v961 where code_norm = v_code for update;
  if v_promo.id is null
     or not v_promo.active
     or (v_promo.expires_on is not null and v_promo.expires_on < app.sg_today())
     or (v_promo.restricted_business_id is not null and v_promo.restricted_business_id <> p_business)
     or (v_promo.max_redemptions is not null and v_promo.redeemed_count >= v_promo.max_redemptions)
  then
    raise exception 'promo_code_not_found' using errcode = '22023';
  end if;
  if v_sub.billing_provider = 'stripe' and v_promo.discount_kind = 'amount'
     and v_promo.currency is distinct from v_sub.currency then
    raise exception 'promo_currency_mismatch' using errcode = '22023';
  end if;

  insert into public.platform_promo_redemptions_v961(
    promo_id, business_id, redeemed_by, redeemed_by_super_admin,
    discount_kind, percent_bps, amount_cents, currency, provider)
  values (v_promo.id, p_business, v_actor, v_is_sa,
    v_promo.discount_kind, v_promo.percent_bps, v_promo.amount_cents, v_promo.currency,
    v_sub.billing_provider)
  returning * into v_row;

  update public.platform_promo_codes_v961
     set redeemed_count = redeemed_count + 1, updated_at = now()
   where id = v_promo.id;

  insert into public.audit_log(business_id, actor, action, entity, entity_id, detail)
  values (p_business, v_actor, 'promo_code_redeemed', 'platform_promo_redemptions_v961', v_row.id,
    jsonb_build_object('source', case when v_is_sa then 'platform_console_v961' else 'business_billing_v961' end,
      'code', v_promo.code_norm, 'discount_kind', v_row.discount_kind,
      'percent_bps', v_row.percent_bps, 'amount_cents', v_row.amount_cents,
      'provider', v_sub.billing_provider));

  return jsonb_build_object('status', 'ok', 'redemption_id', v_row.id, 'code', v_promo.code_norm,
    'discount_kind', v_row.discount_kind, 'percent_bps', v_row.percent_bps,
    'amount_cents', v_row.amount_cents, 'currency', v_row.currency,
    'provider', v_sub.billing_provider,
    'needs_provider_coupon', v_sub.billing_provider = 'stripe');
end
$$;

comment on function public.business_redeem_promo_code_v961(uuid, text) is
  'nestly_v961 + v962 + v965: a business owner (or a super admin acting for them) redeems a promo code against their FIRST payment. Manual firms apply it when the payment is recorded; stripe firms arm an apply_promo_coupon billing command. Razorpay is refused (their offers cannot be created by API), and so is a stripe subscription that can no longer be charged.';

-- ---------------------------------------------------------------------------------------------
-- 3. A provider promo is spent when the provider takes a payment after the coupon went on.
-- ---------------------------------------------------------------------------------------------
create or replace function app.consume_provider_promos_v965(p_limit integer default 200)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_row record;
  v_consumed integer := 0;
begin
  for v_row in
    select r.id, r.business_id, r.discount_kind, r.percent_bps, r.amount_cents,
           inv.provider_invoice_id, inv.total_cents, inv.paid_at
    from public.platform_promo_redemptions_v961 r
    join lateral (
      /* the FIRST invoice this provider settled after the coupon went on — that is the one the
         discount came off, and the only one this first-payment promo can be spent against. */
      select i.provider_invoice_id, i.total_cents, i.paid_at
        from public.billing_provider_invoices i
       where i.business_id = r.business_id
         and i.paid_normalized
         and i.paid_at is not null
         and i.paid_at >= r.provider_applied_at
       order by i.paid_at
       limit 1
    ) inv on true
    where r.removed_at is null
      and r.consumed_at is null
      and r.provider_applied_at is not null
    order by r.provider_applied_at
    limit greatest(coalesce(p_limit, 200), 1)
    for update of r skip locked
  loop
    update public.platform_promo_redemptions_v961
       set consumed_at = v_row.paid_at,
           consumed_payment_reference = v_row.provider_invoice_id,
           consumed_list_cents = v_row.total_cents,
           consumed_discount_cents = coalesce(
             app.promo_discount_cents_v961(v_row.discount_kind, v_row.percent_bps,
                                           v_row.amount_cents, v_row.total_cents), 0)
     where id = v_row.id;

    insert into public.audit_log(business_id, actor, action, entity, entity_id, detail)
    values (v_row.business_id, null, 'promo_code_consumed', 'platform_promo_redemptions_v961',
      v_row.id, jsonb_build_object('source', 'app.consume_provider_promos_v965',
        'provider_invoice_id', v_row.provider_invoice_id,
        'invoice_total_cents', v_row.total_cents, 'paid_at', v_row.paid_at));
    v_consumed := v_consumed + 1;
  end loop;
  return jsonb_build_object('consumed', v_consumed, 'ran_at', now());
end
$$;

comment on function app.consume_provider_promos_v965(integer) is
  'nestly_v965: marks a provider-applied promo spent once the provider settles an invoice after the coupon went on. Without it a stripe promo stayed live forever — the firm could never receive another, and v964 correctly refused to remove it.';

revoke all on function app.consume_provider_promos_v965(integer) from public, anon, authenticated;
grant execute on function app.consume_provider_promos_v965(integer) to service_role;

revoke all on function public.business_redeem_promo_code_v961(uuid, text) from public, anon;
grant execute on function public.business_redeem_promo_code_v961(uuid, text) to authenticated, service_role;

do $cron$
begin
  if to_regnamespace('cron') is not null
     and to_regprocedure('cron.schedule(text,text,text)') is not null then
    if exists (select 1 from cron.job where jobname = 'nestly-v965-promo-consume') then
      perform cron.unschedule('nestly-v965-promo-consume');
    end if;
    perform cron.schedule(
      'nestly-v965-promo-consume',
      '*/20 * * * *',
      $command$select app.consume_provider_promos_v965(200)$command$);
  end if;
exception when others then null;
end $cron$;

commit;
