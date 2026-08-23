-- nestly_v469 — a redeemed welcome offer says what it was (owner photo 11, 2026-08-23).
--
-- THE MARK. On the till receipt: "Free Soyabean given free — welcome offer used." The owner wrote
-- "Welcome rewards redeemed - should also reflect in customer portal". It reaches the customer's
-- reward history and now celebrates there (V468-E) — but on the Activity feed the same event read
-- as "Retail purchase — SGD 0.00", because staff_redeem_welcome_offer_v215 records the free item
-- as a zero-value sale whose only identifying text is sales.note, and no customer-facing reader
-- selects that column. Same for bring-back vouchers (v361) and referral gifts (v420).
--
-- WHY A DERIVED LABEL AND NEVER sales.note ITSELF. The obvious fix is to add 'note' to the
-- payload. It is the wrong fix: sales.note is free text a staff member types, and production
-- currently holds — checked, not assumed — 'till: 81863833' (a phone number), 'Nestly quick
-- reversal: Staff note: admin error', and 'fsfdfdddfdfdfdf: mistakeeeeeeeeee'. Shipping that
-- column to a customer's phone would publish the shop's internal remarks about them.
-- So the note is read and reduced to a gift name INSIDE the query, and only when it matches one of
-- the three prefixes the grant writers themselves emit:
--     'welcome offer redeemed: '  ·  'bring-back voucher redeemed: '  ·  'referral gift redeemed: '
-- What survives is the text after the colon, which is the gift's own customer-facing name — the
-- same string the customer was shown when they were offered it. Every other note, including every
-- note a human typed, resolves to null and nothing is added to the row.
--
-- WHERE IT LIVES. In the v167 wrapper, not in v81. v81 is the shared base read with other callers;
-- v167 is the customer wallet's own decorator and already joins this customer's sales to add
-- package provenance. The new join is scoped identically — business_id AND client_id AND the row's
-- own source_id — so it can only ever see the caller's own sale.
--
-- ADDITIVE AND REVERSIBLE. Rows gain a 'grant_label' key that is null for everything except these
-- grants; no existing key changes, so a client that does not read it is unaffected. One
-- CREATE OR REPLACE over an existing signature; no table, column or row is touched. Grants restate
-- the live proacl verbatim (postgres, authenticated, service_role — never anon).

begin;

CREATE OR REPLACE FUNCTION public.customer_get_transaction_history_v167(p_business_slug text, p_cursor jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'app', 'pg_temp'
AS $function$
declare
  v_context record;
  v_result jsonb;
  v_items jsonb;
begin
  if auth.uid() is null then
    raise exception 'authenticated customer session required' using errcode = '28000';
  end if;

  select * into v_context
    from app.v32_customer_wallet_context(p_business_slug)
   limit 1;
  if not found then
    raise exception 'verified customer link required' using errcode = '42501';
  end if;

  v_result := public.customer_get_transaction_history_v81(p_business_slug, p_cursor);

  select coalesce(jsonb_agg(
    (case
      when item->>'source_kind' = 'sale' and package_use.id is not null then
        item || jsonb_build_object(
          'is_package_session', true,
          'package_name', customer_package.plan_name_snapshot,
          'package_purchased_at', customer_package.purchased_at,
          'package_reference', left(customer_package.id::text, 8)
        )
      else item || jsonb_build_object('is_package_session', false)
    end)
    /* V426: additive. Every item gains an `entry` key so the client can switch on it; a
       conversion or pot-transfer row gains the fields needed to render the pair as one event.
       Nothing is removed — the raw ledger lines are still there for a client that does not
       collapse them. */
    || coalesce(conversion.tag, '{"entry": null}'::jsonb)
    /* V469: a customer-safe name for a $0 grant sale. See the header for why this is a DERIVED
       label and never sales.note itself. */
    || jsonb_build_object('grant_label', grant_sale_v469.grant_label)
    order by ordinal
  ), '[]'::jsonb) into v_items
    from jsonb_array_elements(coalesce(v_result->'items', '[]'::jsonb))
         with ordinality listed(item, ordinal)
    left join public.package_session_consumptions package_use
      on listed.item->>'source_kind' = 'sale'
     and package_use.business_id = v_context.business_id
     and package_use.client_id = v_context.client_id
     and package_use.sale_id = nullif(listed.item->>'source_id', '')::uuid
    left join public.client_packages customer_package
      on customer_package.business_id = package_use.business_id
     and customer_package.client_id = package_use.client_id
     and customer_package.id = package_use.client_package_id
    /* V469: the note is read here and IMMEDIATELY reduced to the gift name, inside the query, so
       no raw note ever reaches the payload. Scoped to this customer's own sale in this business,
       exactly like the package join above. */
    left join lateral (
      select case
        when sale_v469.note like 'welcome offer redeemed: %'
          then nullif(btrim(substring(sale_v469.note from 'welcome offer redeemed: (.*)$')), '')
        when sale_v469.note like 'bring-back voucher redeemed: %'
          then nullif(btrim(substring(sale_v469.note from 'bring-back voucher redeemed: (.*)$')), '')
        when sale_v469.note like 'referral gift redeemed: %'
          then nullif(btrim(substring(sale_v469.note from 'referral gift redeemed: (.*)$')), '')
      end as grant_label
      from public.sales sale_v469
      where listed.item->>'source_kind' = 'sale'
        and sale_v469.id = nullif(listed.item->>'source_id', '')::uuid
        and sale_v469.business_id = v_context.business_id
        and sale_v469.client_id = v_context.client_id
    ) grant_sale_v469 on true
    left join lateral (
      select app.conversion_tag_v426(
        v_context.business_id, v_context.client_id,
        case when listed.item->>'source_kind' = 'points_ledger'
          then nullif(listed.item->>'source_id', '')::uuid end
      ) as tag
    ) conversion on true;

  return jsonb_set(v_result, '{items}', v_items, true);
end;
$function$;

revoke all on function public.customer_get_transaction_history_v167(text, jsonb) from public, anon;
grant execute on function public.customer_get_transaction_history_v167(text, jsonb) to authenticated, service_role;

commit;
