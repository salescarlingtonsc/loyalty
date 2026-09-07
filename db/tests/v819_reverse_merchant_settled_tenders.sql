-- nestly_v819 rollback suite.
--
-- Reverses a REAL card sale against an applied database and checks that every money
-- invariant still balances, inside a transaction that is ROLLED BACK.
--
--   supabase db query --linked -f db/tests/v819_reverse_merchant_settled_tenders.sql
--
-- Before the migration was applied it was run the same way with the migration prepended and
-- its trailing `commit;` stripped. That is how the sixth site was found: assertion 3 was
-- refused by app.payment_write_guard, which carried its own copy of the cash/credit rule.
--   sed '$d' db/migrations/20261007_nestly_v819_*.sql > /tmp/v819.sql
--   cat db/tests/v819_reverse_merchant_settled_tenders.sql >> /tmp/v819.sql

begin;

do $suite$
declare
  c_biz    constant uuid := '8ccace3a-9736-447e-bb1e-da842622592d';  -- ÉLAN Wellness
  c_owner  constant uuid := '8efcffc8-61a5-4235-ad45-54a8954208f9';  -- Kiat Ke Ying (owner)
  c_branch constant uuid := '586f4069-12cb-4f54-b37c-8c5742244520';
  c_card_sale uuid;   -- chosen below; owner photo 3 was ec2f3685… , SGD 88.00 by card
  v_amount integer;
  v_client uuid;
  v_sale   uuid;
  v_result jsonb;
  v_got    integer;
  v_txt    text;
  n        integer := 0;
begin
  ---------------------------------------------------------- the refusal is gone for card

  -- Any card-tendered sale that has not been reversed yet. Chosen rather than hardcoded so
  -- the suite keeps working once the sale in the photo is reversed for real.
  n := n + 1;
  select s.id, s.amount_cents into c_card_sale, v_amount
    from public.sales s
   where s.business_id = c_biz and s.reversal_of is null and s.amount_cents > 0
     and not exists (select 1 from public.sales r where r.reversal_of = s.id)
     and exists (select 1 from public.payments p
                  where p.sale_id = s.id and p.method = 'card' and p.amount_cents > 0)
     and not exists (select 1 from public.payments p
                      where p.sale_id = s.id and p.method <> 'card')
   order by s.occurred_at
   limit 1;
  if c_card_sale is null then
    raise exception 'A%: no un-reversed card-only sale to reverse', n;
  end if;

  -- Reverse it as the OWNER, through the public wrapper the dialog actually calls.
  n := n + 1;
  set local role authenticated;
  perform set_config('request.jwt.claims',
    json_build_object('sub', c_owner, 'role', 'authenticated')::text, true);
  v_result := public.reverse_sale(c_biz, c_card_sale, 'v812 suite', 'v812-suite-card', null, 'none');
  reset role;
  perform set_config('request.jwt.claims', '', true);
  if v_result is null then
    raise exception 'A%: reversing a card sale returned nothing', n;
  end if;

  -- A compensating sale row exists, for the exact negative of the original.
  n := n + 1;
  select id into v_sale from public.sales where reversal_of = c_card_sale;
  if v_sale is null then
    raise exception 'A%: no reversal sale row was written', n;
  end if;
  n := n + 1;
  select amount_cents into v_got from public.sales where id = v_sale;
  if v_got is distinct from -v_amount then
    raise exception 'A%: the reversal booked %c, expected %c', n, v_got, -v_amount;
  end if;

  -- A negative CARD payment was written — the bookkeeping record of a refund the business
  -- makes on its own terminal.
  n := n + 1;
  select count(*)::integer into v_got from public.payments
   where sale_id = c_card_sale and kind = 'refund' and method = 'card' and amount_cents = -v_amount;
  if v_got <> 1 then
    raise exception 'A%: % card refund rows were written, expected exactly 1', n, v_got;
  end if;

  -- The method is recorded honestly: not silently reclassified as cash.
  n := n + 1;
  if exists (select 1 from public.payments
              where sale_id = c_card_sale and kind = 'refund' and method = 'cash') then
    raise exception 'A%: a card refund was recorded as cash', n;
  end if;

  -- Payments for this sale now net to zero.
  n := n + 1;
  select coalesce(sum(amount_cents), 0)::integer into v_got
    from public.payments where sale_id = c_card_sale;
  if v_got <> 0 then
    raise exception 'A%: payments for the reversed sale net to %c, expected 0', n, v_got;
  end if;

  -- The evidence links balance — the invariant v20 raises on if the arithmetic drifts.
  n := n + 1;
  select coalesce(sum(amount_cents), 0)::integer into v_got
    from public.sale_reversal_payment_links where original_sale_id = c_card_sale;
  if v_got <> v_amount then
    raise exception 'A%: reversal evidence links total %c, expected %c', n, v_got, v_amount;
  end if;
  n := n + 1;
  select method into v_txt from public.sale_reversal_payment_links
   where original_sale_id = c_card_sale;
  if v_txt is distinct from 'card' then
    raise exception 'A%: the evidence link recorded method "%", expected card', n, v_txt;
  end if;

  -- The effects record stops claiming provider settlement is what is blocking anything.
  n := n + 1;
  select pg_get_functiondef(p.oid) into v_txt
    from pg_proc p join pg_namespace nn on nn.oid = p.pronamespace
   where nn.nspname = 'public' and p.proname = 'reverse_sale_v20_base';
  if position('disabled_until_provider_settlement_integration' in v_txt) > 0 then
    raise exception 'A%: the effects record still says provider settlement is disabled', n;
  end if;
  n := n + 1;
  if position('bookkeeping_only_merchant_settles_on_own_terminal' in v_txt) = 0 then
    raise exception 'A%: the effects record does not say what actually happens', n;
  end if;

  -- No grant was invented on the internal base function.
  n := n + 1;
  if exists (select 1 from pg_proc p join pg_namespace nn on nn.oid = p.pronamespace
              where nn.nspname = 'public' and p.proname = 'reverse_sale_v20_base'
                and has_function_privilege('authenticated', p.oid, 'execute')) then
    raise exception 'A%: reverse_sale_v20_base became directly callable by authenticated', n;
  end if;

  ------------------------------------------------------------- what must still refuse

  -- A gift-card tender is still refused. It cannot be exercised end to end because
  -- app.payment_write_guard refuses a gift_card payment outright, so the reversal refusal
  -- is asserted where it lives — it exists so the first such tender, whenever that guard
  -- lifts, cannot slip through a reversal path that stopped thinking about it.
  n := n + 1;
  if position('and p.method = ''gift_card''' in v_txt) = 0 then
    raise exception 'A%: the reversal no longer refuses a gift-card tender', n;
  end if;
  n := n + 1;
  if position('the gift card balance would not be restored' in v_txt) = 0 then
    raise exception 'A%: the gift-card refusal lost its explanation', n;
  end if;

  -- The write guard still refuses everything but a negative refund linked to a sale.
  n := n + 1;
  select pg_get_functiondef(p.oid) into v_txt
    from pg_proc p join pg_namespace nn on nn.oid = p.pronamespace
   where nn.nspname = 'app' and p.proname = 'payment_write_guard';
  if position('gift-card tender is disabled' in v_txt) = 0 then
    raise exception 'A%: the write guard stopped refusing gift-card tender', n;
  end if;
  n := n + 1;
  if position('record_payment may only post non-credit positive' in v_txt) = 0
     or position('credit_tender payment shape is invalid' in v_txt) = 0
     or position('unknown internal payment write scope' in v_txt) = 0 then
    raise exception 'A%: the write guard lost one of its other scopes', n;
  end if;

  -- A cash sale still reverses exactly as before — the change must not have moved cash.
  n := n + 1;
  select id into v_sale from public.sales s
   where s.business_id = c_biz and s.reversal_of is null and s.amount_cents > 0
     and not exists (select 1 from public.sales r where r.reversal_of = s.id)
     and exists (select 1 from public.payments p
                  where p.sale_id = s.id and p.method = 'cash' and p.amount_cents > 0)
     and not exists (select 1 from public.payments p
                      where p.sale_id = s.id and p.method <> 'cash')
   limit 1;
  if v_sale is null then
    raise exception 'A%: no un-reversed cash-only sale to prove cash is unchanged', n;
  end if;
  set local role authenticated;
  perform set_config('request.jwt.claims',
    json_build_object('sub', c_owner, 'role', 'authenticated')::text, true);
  -- accept_loyalty_shortfall: some historical cash sales have points that were since
  -- spent, and the v480 clawback guard stops the plain wrapper on those. That guard is
  -- untouched by v812 and is not what this assertion is about.
  v_result := public.reverse_sale_accept_loyalty_shortfall_v480(
                c_biz, v_sale, 'v812 suite', 'v812-suite-cash', null, 'none');
  reset role;
  perform set_config('request.jwt.claims', '', true);
  select coalesce(sum(amount_cents), 0)::integer into v_got
    from public.payments where sale_id = v_sale;
  if v_got <> 0 then
    raise exception 'A%: a cash sale no longer nets to zero after reversal (%c)', n, v_got;
  end if;

  raise notice 'nestly_v819: % / % assertions passed', n, n;
end
$suite$;

rollback;
