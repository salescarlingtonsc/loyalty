-- FRENLY v51b — staff_get_client_credit_history: bounded Customer-360 money timeline.
-- Forward-only; rehearsal + db/tests/v51b_client_credit_history.sql verify it.
--
-- WHY
--   Customer 360's timeline cannot show a customer's raw in-store-credit movements or the
--   gift cards they bought: public.credit_ledger has no browser SELECT surface (only the
--   client_credit_balance aggregate view is readable) and staff_list_gift_cards has no
--   per-client filter. This adds ONE bounded, module-gated SECURITY DEFINER read.
--
-- AUTHORIZATION GATE — precedent and justification
--   Two precedents were weighed. v49b (reports) gates on
--   has_perm('view_sales') + can_module_read('reports'); v40 (reversal workflows) gates on
--   has_perm('refund_sales'). This surface is the Customer-360 (clients) page, so the module
--   gate is can_module_read('clients') — the same module every other customer read uses.
--   For the PERMISSION we choose view_finance, NOT view_sales: credit_ledger rows are raw
--   financial-liability movements (in-store credit the firm owes the customer), the exact
--   data class public.financial_operations protects with view_finance. view_finance also
--   correctly DENIES frontdesk and stylist (who hold only view_sales/create_sales) while
--   admitting owner and manager — the right audience for a customer's money ledger. Net gate:
--   can_module_read('clients') AND has_perm('view_finance'). Output is bearer-safe (gift-card
--   codes are masked to a 4-char suffix exactly as staff_list_gift_cards does) and exposes no
--   PII beyond what the customers page already shows.

begin;

create or replace function public.staff_get_client_credit_history(
  p_business uuid,
  p_client uuid,
  p_limit integer default 50)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_actor uuid := auth.uid();
  v_staff uuid;
  v_limit integer := least(greatest(coalesce(p_limit, 50), 1), 200);
  v_credit jsonb := '[]'::jsonb;
  v_cards jsonb := '[]'::jsonb;
begin
  if v_actor is null then
    raise exception 'authenticated staff required' using errcode = '42501';
  end if;
  if not app.can_module_read(p_business, 'clients')
     or not app.has_perm(p_business, 'view_finance') then
    raise exception 'active customers-module read and finance authorization is required'
      using errcode = '42501';
  end if;
  select s.id into v_staff
    from public.staff s
   where s.business_id = p_business
     and s.user_id = v_actor
     and s.active
     and 'view_finance' = any (app.role_perms(s.role))
   order by case when s.role = 'owner' then 0 else 1 end, s.created_at, s.id
   limit 1;
  if not found then
    raise exception 'active staff authorization is required' using errcode = '42501';
  end if;
  if not exists (
    select 1 from public.clients c where c.id = p_client and c.business_id = p_business
  ) then
    raise exception 'customer not found in this business' using errcode = '42501';
  end if;

  -- Raw in-store-credit movements for this customer, most recent first, bounded.
  select coalesce(jsonb_agg(jsonb_build_object(
    'entry_id', x.id,
    'entry_type', x.entry_type,
    'amount_cents', x.amount_cents,
    'reference', x.reference,
    'created_at', x.created_at
  ) order by x.created_at desc, x.id desc), '[]'::jsonb)
    into v_credit
    from (
      select cl.id, cl.entry_type, cl.amount_cents, cl.reference, cl.created_at
        from public.credit_ledger cl
       where cl.business_id = p_business
         and cl.client_id = p_client
       order by cl.created_at desc, cl.id desc
       limit v_limit
    ) x;

  -- Gift cards this customer purchased (bearer-safe: masked code suffix only).
  select coalesce(jsonb_agg(jsonb_build_object(
    'gift_card_id', y.id,
    'code_suffix', right(y.code, 4),
    'initial_cents', y.initial_cents,
    'balance_cents', y.balance_cents,
    'status', y.status,
    'created_at', y.created_at
  ) order by y.created_at desc, y.id desc), '[]'::jsonb)
    into v_cards
    from (
      select g.id, g.code, g.initial_cents, g.balance_cents, g.status, g.created_at
        from public.gift_cards g
       where g.business_id = p_business
         and g.purchaser_client_id = p_client
       order by g.created_at desc, g.id desc
       limit v_limit
    ) y;

  return jsonb_build_object(
    'status', 'ok',
    'client_id', p_client,
    'limit', v_limit,
    'credit_entries', v_credit,
    'credit_entry_count', jsonb_array_length(v_credit),
    'gift_cards', v_cards,
    'gift_card_count', jsonb_array_length(v_cards)
  );
end $$;

revoke all privileges on function public.staff_get_client_credit_history(uuid, uuid, integer)
  from public, anon, authenticated;
grant execute on function public.staff_get_client_credit_history(uuid, uuid, integer)
  to authenticated;

commit;
