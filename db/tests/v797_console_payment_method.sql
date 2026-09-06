-- nestly_v797 rollback suite — the console can name the card a firm is charged on.
--
-- Runs inside ONE transaction ending in ROLLBACK, so it is safe against production.
--
-- WHAT IT PROVES
--   A  the reader returns a payment_method at company level and on every branch.
--   B  a branch on the company plan reports the COMPANY's card; the resolution is done by the
--      server, so the console cannot disagree with the business's own page about who pays.
--   C  nothing is invented: when the provider gave no digits, last4 stays null rather than
--      becoming a guess.
--   D  the ACL is unchanged (super admin / assigned consultant, reached as authenticated).
begin;

do $v797$
declare
  v_sa uuid;
  v_business uuid;
  v_payload jsonb;
  v_branch jsonb;
  v_acl text;
begin
  reset role;

  select user_id into v_sa from public.super_admins limit 1;
  if v_sa is null then raise exception 'no super admin configured'; end if;
  /* v625: is_super_admin needs the Google-OAuth session shape, not just `sub`. */
  perform set_config('request.jwt.claim.sub', v_sa::text, true);
  perform set_config('request.jwt.claims', json_build_object(
    'sub', v_sa, 'role', 'authenticated',
    'amr', json_build_array(json_build_object('method','oauth')),
    'app_metadata', json_build_object('providers', json_build_array('google'))
  )::text, true);

  -- A firm that actually has a provider customer row, so there is a card question to answer.
  select c.business_id into v_business
    from public.billing_provider_customers c
   where c.payment_method_kind is not null
   limit 1;
  if v_business is null then
    raise notice 'v797: no firm with a recorded payment method yet — shape still checked';
    select id into v_business from public.businesses limit 1;
  end if;

  v_payload := public.platform_get_business_payments_v779(v_business);

  -- A · the key exists on the payload and on every branch, present or null.
  if not (v_payload ? 'payment_method') then
    raise exception 'A1: the payload carries no company payment_method';
  end if;
  if exists (select 1 from jsonb_array_elements(v_payload->'branches') b
              where not (b ? 'payment_method')) then
    raise exception 'A2: a branch carries no payment_method key';
  end if;

  -- B · a branch on the company plan reports the company card, resolved server-side.
  select b into v_branch from jsonb_array_elements(v_payload->'branches') b
   where coalesce(b->>'billing_state','') <> 'own' limit 1;
  if v_branch is not null and v_payload->'payment_method' is not null
     and jsonb_typeof(v_payload->'payment_method') = 'object'
     and v_branch->'payment_method' is distinct from v_payload->'payment_method' then
    raise exception 'B: a company-plan branch does not report the company card (% vs %)',
      v_branch->'payment_method', v_payload->'payment_method';
  end if;

  -- C · no invented digits: whatever last4 the payload carries must match the stored one exactly.
  if exists (
    select 1 from public.billing_provider_customers c
     where c.business_id = v_business
       and coalesce(v_payload#>>'{payment_method,last4}','')
           is distinct from coalesce(c.payment_method_last4,'')) then
    raise exception 'C: the payload last4 does not match the stored last4';
  end if;

  -- D · ACL unchanged.
  select proacl::text into v_acl from pg_proc
   where oid = 'public.platform_get_business_payments_v779(uuid)'::regprocedure;
  if v_acl not like '%authenticated=X%' or v_acl like '%anon=X%' then
    raise exception 'D: unexpected ACL on platform_get_business_payments_v779: %', v_acl;
  end if;

  raise notice 'v797 console payment method: all assertions passed';
end
$v797$;

rollback;
