-- nestly_v819 — a card or PayNow sale can be reversed, as a bookkeeping record.
--
-- NUMBERING: written and applied as nestly_v812 alongside its sibling (now v818); both were
-- renumbered when a parallel session's own nestly_v811 reached origin/main first and took the
-- deploy slot. Nothing in the change moved with the number.
--
-- Owner photo 3 ringed the Reverse sale dialog: "Why reversal refused? If use other card
-- or paynow then can't reverse sale?"
--
--     Reversal refused. launch refunds support only cash and proven store credit;
--     provider-settled methods are disabled
--
-- The reading is exactly right. Production, the sale in the photo:
--
--     sales    ec2f3685…  quick_sale  SGD 88.00
--     payments            method = card, kind = payment, 8800c
--
-- public.reverse_sale_v20_base has refused every method but cash and store credit since
-- v20. Cash sales reverse (there are eight cash refunds on the estate); every card and
-- PayNow sale — 38 of them — has been unreversible since the day it was taken.
--
-- WHY IT WAS WRITTEN THAT WAY, and why that reasoning no longer holds. v20 was written
-- expecting Peekaa to settle card payments itself one day, and refused to write a refund
-- it could not carry out at the provider: the response still says
-- 'provider_refunds', 'disabled_until_provider_settlement_integration'. But Peekaa is not
-- the acquirer for an in-store card or PayNow payment and is not becoming one — the salon
-- takes those on their own terminal. So there is no provider for Peekaa to call, no
-- settlement to wait for, and the refusal protects nothing. It only stops the books being
-- corrected, and a wrong sale that cannot be reversed is the worse outcome: the till, the
-- loyalty ledger, the points and the day's revenue all keep counting a sale that was
-- refunded on the terminal an hour ago.
--
-- OWNER RULING, 2026-09-07: a card or PayNow sale reverses as a BOOKKEEPING record. Peekaa
-- writes the negative payment, unwinds the sale, points and loyalty exactly as it does for
-- cash, and the money itself is refunded by the business on their own terminal. Peekaa
-- never claims to have moved it.
--
-- WHAT STILL REFUSES, and this is deliberate:
--   * gift_card. Peekaa OWNS that balance. A bookkeeping-only reversal would leave the
--     customer's gift card short by the amount they just had refunded, so it is refused
--     rather than silently mis-stated. app.payment_write_guard already refuses a gift-card
--     tender outright ("disabled until payments link to immutable gift-card consumption
--     evidence"), so no such payment can exist yet and this refusal is unreachable today —
--     it is written anyway so the first one, whenever that guard lifts, cannot slip through
--     a reversal path that had stopped thinking about it.
--   * store credit keeps its full proof requirement — every positive credit payment must
--     still be the exact child of a credit_tenders row and its negative ledger spend, and
--     is still restored to the customer's balance on reversal. Nothing about credit moves.
--   * every other invariant: overpaid sales, negative per-method nets, the validated total
--     equalling the sale's payment net, the refund evidence links balancing. Untouched.
--
-- The rule lived in SIX places: five inside one 25KB function, and a sixth in the payment
-- write guard, which independently refuses any reversal payment that is not cash or
-- credit. The rolled-back suite found the sixth by reversing a real card sale and being
-- refused by it, which is why that suite exists. The five in reverse_sale_v20_base are
-- applied against the live body by anchored replacement rather than by restating a
-- function this migration has no business rewriting; every anchor must match or the
-- migration raises and rolls back, because a partial edit would leave the refund
-- arithmetic disagreeing with the methods it may refund, and the function's own equality
-- checks would then refuse at run time for every sale, cash included.

begin;

-- The sixth site. Restated in full rather than patched: it is short, and the shape of what
-- each write scope may post is exactly the kind of rule that should be readable whole.
create or replace function app.payment_write_guard()
returns trigger
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $function$
declare
  v_payment_token text;
  v_scope text;
begin
  v_payment_token := nullif(current_setting('app.payment_insert_id', true), '');
  v_scope := nullif(current_setting('app.payment_write_scope', true), '');
  if v_payment_token is distinct from new.id::text then
    raise exception 'payments may only be posted through an approved payment RPC'
      using errcode = '42501';
  end if;

  if new.method = 'gift_card' then
    raise exception 'gift-card tender is disabled until payments link to immutable gift-card consumption evidence'
      using errcode = 'feature_not_supported';
  end if;

  if v_scope = 'record_payment' then
    if new.kind not in ('payment', 'deposit', 'no_show_fee')
       or new.method in ('credit', 'gift_card') then
      raise exception 'record_payment may only post non-credit positive payment/deposit/no-show rows'
        using errcode = '42501';
    end if;
  elsif v_scope = 'credit_tender' then
    if new.method <> 'credit' or new.kind <> 'payment' or new.amount_cents <= 0 then
      raise exception 'credit_tender payment shape is invalid'
        using errcode = '42501';
    end if;
  elsif v_scope = 'sale_reversal' then
    -- nestly_v819: was `new.method not in ('cash','credit')`. A card or PayNow sale is
    -- settled on the business's own terminal, so its reversal is a bookkeeping record and
    -- the negative payment must be allowed to carry the method it actually reverses —
    -- recording a card refund as cash would put the drawer out. gift_card is already
    -- refused above, so the shape check no longer needs to name methods at all.
    if new.kind <> 'refund'
       or new.amount_cents >= 0
       or new.sale_id is null then
      raise exception 'sale_reversal may only post negative refunds linked to a sale'
        using errcode = '42501';
    end if;
  else
    raise exception 'unknown internal payment write scope'
      using errcode = '42501';
  end if;

  if new.sale_id is not null then
    if exists (
      select 1
        from public.sales s
       where s.id = new.sale_id
         and s.business_id = new.business_id
         and s.reversal_of is not null
    ) then
      raise exception 'payments cannot attach to a reversal sale';
    end if;

    if new.kind <> 'refund' and exists (
      select 1
        from public.sales r
       where r.business_id = new.business_id
         and r.reversal_of = new.sale_id
    ) then
      raise exception 'positive payment is forbidden on a fully reversed sale'
        using errcode = 'check_violation';
    end if;
  end if;

  if new.kind <> 'refund' and new.sale_id is null and new.appointment_id is not null
     and exists (
       select 1
         from public.sales s
         join public.sales r
           on r.business_id = s.business_id
          and r.reversal_of = s.id
        where s.business_id = new.business_id
          and s.appointment_id = new.appointment_id
     ) then
    raise exception 'positive appointment payment is forbidden after its completed sale was reversed'
      using errcode = 'check_violation';
  end if;

  return new;
end
$function$;

revoke all on function app.payment_write_guard() from public, anon, authenticated;

do $do$
declare
  v_old text;
  v_new text;
  v_step text;

  -- 1. The refusal itself: refuse only what Peekaa cannot honestly unwind.
  a_guard constant text :=
'     group by p.method
    having sum(p.amount_cents) > 0
       and p.method not in (''cash'', ''credit'')
  ) then
    raise exception ''launch refunds support only cash and proven store credit; provider-settled methods are disabled''
      using errcode = ''feature_not_supported'';
  end if;';
  b_guard constant text :=
'     group by p.method
    having sum(p.amount_cents) > 0
       and p.method = ''gift_card''
  ) then
    -- nestly_v819: card, PayNow, bank transfer and other are settled on the business''s own
    -- terminal, so Peekaa reverses them as a bookkeeping record. A gift card is the one
    -- tender Peekaa itself holds the balance for, and a bookkeeping-only reversal would
    -- leave the customer short, so it is still refused.
    raise exception ''a sale tendered with a gift card cannot be reversed here: the gift card balance would not be restored''
      using errcode = ''feature_not_supported'';
  end if;';

  -- 2. The total the refund is checked against must cover every method it may now refund.
  a_validated constant text :=
'       group by p.method
      having sum(p.amount_cents) > 0
         and p.method in (''cash'', ''credit'')
    ) m;';
  b_validated constant text :=
'       group by p.method
      having sum(p.amount_cents) > 0
         and p.method <> ''gift_card''   -- nestly_v819
    ) m;';

  -- 3. …and so must the loop that actually writes the refunds.
  a_loop constant text :=
'       and p.method in (''cash'', ''credit'')
     group by p.method
    having sum(p.amount_cents) > 0
  loop';
  b_loop constant text :=
'       and p.method <> ''gift_card''   -- nestly_v819
     group by p.method
    having sum(p.amount_cents) > 0
  loop';

  -- 4/5. The effects record must stop describing a rule that no longer exists.
  a_effects constant text :=
'    ''refund_methods'', jsonb_build_array(''cash'', ''credit''),
    ''provider_refunds'', ''disabled_until_provider_settlement_integration'',';
  b_effects constant text :=
'    ''refund_methods'', jsonb_build_array(''cash'', ''card'', ''paynow'', ''bank_transfer'', ''credit'', ''other''),
    ''provider_refunds'', ''bookkeeping_only_merchant_settles_on_own_terminal'',';
begin
  select pg_get_functiondef(p.oid) into v_old
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'reverse_sale_v20_base';
  if v_old is null then
    raise exception 'nestly_v819: public.reverse_sale_v20_base not found';
  end if;

  v_new := v_old;
  v_step := 'the method refusal';
  v_new := replace(v_new, a_guard, b_guard);
  if v_new = v_old then
    raise exception 'nestly_v819: % did not match the live body; re-derive the anchor', v_step;
  end if;

  v_step := 'the validated refundable total';
  if position(a_validated in v_new) = 0 then
    raise exception 'nestly_v819: % did not match the live body; re-derive the anchor', v_step;
  end if;
  v_new := replace(v_new, a_validated, b_validated);

  v_step := 'the refund loop';
  if position(a_loop in v_new) = 0 then
    raise exception 'nestly_v819: % did not match the live body; re-derive the anchor', v_step;
  end if;
  v_new := replace(v_new, a_loop, b_loop);

  v_step := 'the effects record';
  if position(a_effects in v_new) = 0 then
    raise exception 'nestly_v819: % did not match the live body; re-derive the anchor', v_step;
  end if;
  v_new := replace(v_new, a_effects, b_effects);

  execute v_new;
end
$do$;

-- Restated from the live proacl, which is `postgres=X/postgres` and NOTHING else. This is
-- an internal base of the reverse_sale wrapper chain — the SECURITY DEFINER wrappers are
-- what the browser calls, and they are what carry the authenticated grant. Granting
-- execute here would hand every signed-in user a direct call on the reversal engine,
-- bypassing the wrappers. So the revoke is restated and no grant is added.
revoke all on function public.reverse_sale_v20_base(uuid, uuid, text, text, text, text)
  from public, anon, authenticated;

commit;
