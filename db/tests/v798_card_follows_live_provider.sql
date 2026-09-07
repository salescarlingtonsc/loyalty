-- nestly_v798 rollback suite — a card is named only by the provider billing today.
--
-- Runs inside ONE transaction ending in ROLLBACK, so it is safe against production.
--
-- WHAT IT PROVES
--   A  no reader names a card stored by a provider that is no longer the platform provider —
--      the console and the business page both, since the console gained the display in v797.
--   B  a firm on the CURRENT provider still gets its card (the gate refuses stale rows, not all).
--   C  the two readers agree: what the business is told and what an operator is told is one fact.
--   D  ACLs unchanged on both.
begin;

do $v798$
declare
  v_sa uuid;
  v_live text := app.platform_billing_provider_v792();
  v_stale record;
  v_current record;
  v_console jsonb; v_business jsonb;
  v_acl text;
begin
  reset role;

  select user_id into v_sa from public.super_admins limit 1;
  if v_sa is null then raise exception 'no super admin configured'; end if;
  perform set_config('request.jwt.claim.sub', v_sa::text, true);
  perform set_config('request.jwt.claims', json_build_object(
    'sub', v_sa, 'role', 'authenticated',
    'amr', json_build_array(json_build_object('method','oauth')),
    'app_metadata', json_build_object('providers', json_build_array('google'))
  )::text, true);

  -- A · a firm whose stored card belongs to a RETIRED provider names no card anywhere.
  select c.business_id, c.provider, c.payment_method_last4 into v_stale
    from public.billing_provider_customers c
   where c.payment_method_kind is not null and c.provider <> v_live
   limit 1;
  if v_stale.business_id is not null then
    v_console  := public.platform_get_business_payments_v779(v_stale.business_id);
    v_business := public.get_business_billing_v758(v_stale.business_id);
    if v_console#>>'{payment_method,last4}' is not null then
      raise exception 'A1: the console named a % card (%) that cannot be charged',
        v_stale.provider, v_console#>>'{payment_method,last4}';
    end if;
    if v_business#>>'{payment_method,last4}' is not null then
      raise exception 'A2: the business page named a % card that cannot be charged', v_stale.provider;
    end if;
    if exists (select 1 from jsonb_array_elements(v_console->'branches') b
                where b#>>'{payment_method,last4}' is not null) then
      raise exception 'A3: a branch named a retired-provider card';
    end if;
  else
    raise notice 'v798: no retired-provider card stored — A skipped';
  end if;

  -- B · the gate refuses STALE rows, not every row.
  select c.business_id, c.payment_method_kind into v_current
    from public.billing_provider_customers c
   where c.payment_method_kind is not null and c.provider = v_live
   limit 1;
  if v_current.business_id is not null then
    v_console  := public.platform_get_business_payments_v779(v_current.business_id);
    v_business := public.get_business_billing_v758(v_current.business_id);
    if v_console#>>'{payment_method,kind}' is null then
      raise exception 'B1: a card on the CURRENT provider was hidden from the console';
    end if;
    if v_business#>>'{payment_method,kind}' is null then
      raise exception 'B2: a card on the CURRENT provider was hidden from the business';
    end if;
    -- C · one fact, two readers.
    if coalesce(v_console#>>'{payment_method,last4}','')
       is distinct from coalesce(v_business#>>'{payment_method,last4}','')
       or coalesce(v_console#>>'{payment_method,kind}','')
       is distinct from coalesce(v_business#>>'{payment_method,kind}','') then
      raise exception 'C: the console (%) and the business page (%) disagree about the card',
        v_console->'payment_method', v_business->'payment_method';
    end if;
  else
    raise notice 'v798: no card on the current provider yet — B/C skipped';
  end if;

  -- D · ACLs unchanged.
  select proacl::text into v_acl from pg_proc
   where oid = 'public.get_business_billing_v758(uuid)'::regprocedure;
  if v_acl not like '%authenticated=X%' or v_acl like '%anon=X%' then
    raise exception 'D1: unexpected ACL on get_business_billing_v758: %', v_acl;
  end if;
  select proacl::text into v_acl from pg_proc
   where oid = 'public.platform_get_business_payments_v779(uuid)'::regprocedure;
  if v_acl not like '%authenticated=X%' or v_acl like '%anon=X%' then
    raise exception 'D2: unexpected ACL on platform_get_business_payments_v779: %', v_acl;
  end if;

  raise notice 'v798 card follows the live provider: all assertions passed (live provider %)', v_live;
end
$v798$;

rollback;
