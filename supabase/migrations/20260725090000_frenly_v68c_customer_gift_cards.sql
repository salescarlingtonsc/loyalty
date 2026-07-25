-- FRENLY v68c - CUSTOMER-FACING GIFT-CARD VIEW (BALANCE VISIBILITY, NEVER THE BEARER CODE)
--
-- Pinned contract: docs/design/ps2/PS2_LIVE_V68C_CUSTOMER_GIFT_CARDS_CONTRACT.md. Forward-only.
-- Closes gap B4 from the 2026-07-25 gap register: a customer holds gift-card value they cannot see.
--
-- WHY A MIGRATION AND NOT A UI-ONLY CHANGE. public.gift_cards carries exactly ONE RLS policy -
-- gift_cards_sa_read (super admin) - and v41 revoked every browser privilege on the table. A signed-in
-- customer cannot read it directly and must NOT be granted broad access: the table holds
-- purchaser_client_id, recipient_email and the bearer CODE for the whole tenant. The sanctioned
-- pattern is a SECURITY DEFINER reader scoped to the caller's verified customer link, exactly like
-- every other customer_* getter (v32/v39/v44). This migration adds ONE new function and REPLACES
-- NOTHING: no existing function, view, policy, table, column, grant or trigger is touched.
--
-- §1 IDENTITY GATE - the SAME one every sibling uses, not a second identity path.
--   auth.uid() is not null                          -> else 28000
--   app.v32_customer_wallet_context(p_business_slug) -> else 42501 'verified customer link required'
-- That resolver (v32) is the single scope oracle: it requires an ACTIVE public.customer_identities row
-- for auth.uid(), a public.customer_links row in state 'verified' for that same auth.uid(), the
-- app.platform_feature_enabled('customer_wallet') release gate, and it derives (business_id, client_id)
-- from the LINK - the slug argument is a lookup hint only and can never widen scope. A missing,
-- unlinked or unverified relationship all produce the identical 42501, so this RPC never reveals
-- whether a slug exists. This mirrors public.customer_get_business_summary byte-for-byte in intent.
--
-- §2 MATCHING PREDICATE - what a "customer's gift card" is here, and what it deliberately is NOT.
--   MATCHED ON:  g.business_id = <link business> AND g.purchaser_client_id = <link client>
--   NOT MATCHED ON: g.recipient_email.
-- public.gift_cards offers exactly two customer-shaped columns: purchaser_client_id (a real FK to
-- public.clients, set by public.issue_gift_card from the staff-selected buyer) and recipient_email (a
-- free-text field a staff member types at issue time; NOTHING verifies it, and there is no
-- verified-email contact record on customer_identities to check it against). Matching on it would let
-- anyone who can guess or learn an address claim the card's balance view by typing that address into
-- their own profile - a security defect, not a feature. So the ONLY linkage used is the FK, which the
-- verified customer link already binds to this caller. A gifted-away card therefore stays visible to
-- the BUYER (who paid, and whose liability it is) and invisible to the named recipient until a
-- verified recipient linkage exists - a deliberate, safe, forward-compatible under-inclusion.
-- v_context.client_id is additionally proven NOT NULL in the predicate so the fail-closed behaviour is
-- syntactic rather than an argument about three-valued logic.
--
-- §3 THE CODE IS NEVER RETURNED. A gift-card code is a BEARER instrument: whoever reads it can spend
-- the balance at the counter through public.redeem_gift_card_v41. This is a BALANCE-VISIBILITY view,
-- not a redemption surface, so the projection is an explicit allowlist - id, initial_cents,
-- balance_cents, status, created_at - plus right(code, 4) as a masked display hint, which is the exact
-- masking public.staff_list_gift_cards (v41) and public.staff_get_client_credit_history (v51b) already
-- use on this column. The full code, recipient_email and purchaser_client_id never leave the function.
-- db/tests/v68c_customer_gift_cards.sql scans the returned jsonb for the full code value and fails if
-- it appears anywhere.
--
-- §4 NO MODULE GATE - a deliberate divergence from customer_get_appointments/memberships/packages,
-- which raise 42501 when their module is absent from businesses.enabled_modules. A gift card is money
-- the firm has ALREADY collected and still owes (v9: gift-card sales are cash collected, not revenue;
-- the outstanding balance is reported as liability). enabled_modules is a navigation toggle an owner
-- can flip at any moment, and this repo's own v14 ruling is that app.can_module() deliberately ignores
-- enabled_modules so "turning a module off in Settings must not strand rows". Hiding a customer's
-- already-paid balance because a nav toggle flipped would strand their money. The sections that DO
-- gate are program surfaces whose data is meaningless without the programme; this one is not.
--
-- §5 SHAPE + BOUND. { business:{slug,name,currency}, cards:[...], total_balance_cents, count,
-- truncated }. The empty case returns cards:[] with count 0 and total 0 - never a null-shaped error.
-- `cards` is bounded at 100 newest-first (the same cap public.staff_list_gift_cards uses on this
-- table), but count and total_balance_cents are computed over the FULL matching set so a truncated
-- list can never silently UNDERSTATE the customer's money, and `truncated` says so explicitly. Status
-- is projected verbatim; the shipped engine only ever moves a card active -> redeemed (v20
-- redeem_gift_card sets balance 0 with it), so the total is the spendable balance in practice.
--
-- §6 READ-ONLY. Writes nothing: no ledger, no sale, no idempotency row, no audit row (it is a getter,
-- exactly like every other customer_get_*). No pg_get_functiondef splice is used anywhere.

begin;

-- One firm's gift cards for the calling, verified customer. A missing, unlinked or unverified
-- relationship deliberately produces the same authorization failure; this RPC never reveals whether a
-- slug exists.
create or replace function public.customer_get_gift_cards(p_business_slug text)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_context record;
  v_cards jsonb;
  v_count integer;
  v_total bigint;
begin
  if auth.uid() is null then
    raise exception 'authenticated customer session required' using errcode = '28000';
  end if;

  -- The app context resolves auth.uid() through customer_links with link status = 'verified'.
  select identity_id, business_id, client_id, business_name, business_slug,
         business_industry, business_currency, enabled_modules into v_context
    from app.v32_customer_wallet_context(p_business_slug)
   limit 1;
  if not found then
    raise exception 'verified customer link required' using errcode = '42501';
  end if;

  -- Totals over the FULL matching set, so a bounded list never understates the balance.
  select count(*)::integer, coalesce(sum(g.balance_cents), 0)::bigint
    into v_count, v_total
    from public.gift_cards g
   where g.business_id = v_context.business_id
     and v_context.client_id is not null
     and g.purchaser_client_id = v_context.client_id;

  -- Explicit customer-safe projection. The bearer code is masked to its last 4 characters, the same
  -- masking the two staff readers of this table already use; recipient_email and purchaser_client_id
  -- are never projected.
  select coalesce(jsonb_agg(jsonb_build_object(
    'gift_card_id', listed.id,
    'code_suffix', right(listed.code, 4),
    'initial_cents', listed.initial_cents,
    'balance_cents', listed.balance_cents,
    'status', listed.status,
    'created_at', listed.created_at
  ) order by listed.created_at desc, listed.id desc), '[]'::jsonb)
    into v_cards
    from (
      select g.id, g.code, g.initial_cents, g.balance_cents, g.status, g.created_at
        from public.gift_cards g
       where g.business_id = v_context.business_id
         and v_context.client_id is not null
         and g.purchaser_client_id = v_context.client_id
       order by g.created_at desc, g.id desc
       limit 100
    ) listed;

  return jsonb_build_object(
    'business', jsonb_build_object(
      'slug', v_context.business_slug,
      'name', v_context.business_name,
      'currency', v_context.business_currency
    ),
    'cards', v_cards,
    'count', v_count,
    'total_balance_cents', v_total,
    'truncated', v_count > jsonb_array_length(v_cards)
  );
end;
$$;

revoke all on function public.customer_get_gift_cards(text)
  from public, anon, authenticated;
grant execute on function public.customer_get_gift_cards(text) to authenticated;

do $v68c_postconditions$
begin
  -- the new reader exists, is a definer function with the v21-canonical pinned search_path
  if not exists (
    select 1 from pg_proc p
     where p.oid = 'public.customer_get_gift_cards(text)'::regprocedure
       and p.prosecdef
       and p.provolatile = 's'
       and array_to_string(p.proconfig, ',') = 'search_path=pg_catalog, public, app, pg_temp'
  ) then
    raise exception 'v68c: customer_get_gift_cards is missing, not SECURITY DEFINER/STABLE, or lost its search_path pin';
  end if;
  -- exactly the customer-role ACL: authenticated yes, anon no, PUBLIC no
  if not has_function_privilege('authenticated', 'public.customer_get_gift_cards(text)', 'execute')
     or has_function_privilege('anon', 'public.customer_get_gift_cards(text)', 'execute') then
    raise exception 'v68c: customer_get_gift_cards has the wrong browser-role ACL';
  end if;
  if exists (
    select 1 from pg_proc p
    cross join lateral aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) acl
     where p.oid = 'public.customer_get_gift_cards(text)'::regprocedure
       and acl.grantee = 0
       and acl.privilege_type = 'EXECUTE'
  ) then
    raise exception 'v68c: customer_get_gift_cards retains the default PUBLIC execute grant';
  end if;
  -- gift_cards itself is untouched: RLS on, no browser table grant, still exactly one policy
  if not (select relrowsecurity from pg_class where oid = 'public.gift_cards'::regclass) then
    raise exception 'v68c: gift_cards RLS is off';
  end if;
  if has_table_privilege('authenticated', 'public.gift_cards', 'select')
     or has_table_privilege('anon', 'public.gift_cards', 'select') then
    raise exception 'v68c: gift_cards became directly readable by a browser role';
  end if;
  if (select count(*) from pg_policies where schemaname = 'public' and tablename = 'gift_cards') <> 1 then
    raise exception 'v68c: the gift_cards policy set changed (the definer RPC is the only access path)';
  end if;
  -- the v32 scope resolver stays closed to the browser: it is the gate, not an API
  if has_function_privilege('authenticated', 'app.v32_customer_wallet_context(text)', 'execute')
     or has_function_privilege('anon', 'app.v32_customer_wallet_context(text)', 'execute') then
    raise exception 'v68c: the v32 customer scope resolver leaked to a browser role';
  end if;
end
$v68c_postconditions$;

commit;
