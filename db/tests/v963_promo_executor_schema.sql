-- nestly_v963 rollback suite — the promo executor RPCs are reachable where the executor looks.
--
-- Run inside a transaction against production and ROLLED BACK.
--
-- The whole point of v963 is a REACHABILITY fact, so that is what is asserted: the two functions
-- exist in `public` (which PostgREST exposes) and not in `app` (which it does not), carry the
-- service_role-only grant, and still behave exactly as v962's suite proved.

\set ON_ERROR_STOP on

begin;

do $suite$
declare
  sa uuid; owner_s uuid := gen_random_uuid();
  biz uuid := gen_random_uuid();
  got jsonb; intent jsonb; red uuid; n integer := 0;
  row_r public.platform_promo_redemptions_v961%rowtype;
begin
  select user_id into sa from public.super_admins limit 1;
  if sa is null then raise exception 'A0 failed: no super admin to impersonate'; end if;

  -- ------------------------------------------------------------------ reachability
  n := n + 1;
  if not exists(select 1 from pg_proc p join pg_namespace ns on ns.oid=p.pronamespace
                 where ns.nspname='public' and p.proname='promo_provider_intent_v962') then
    raise exception 'A% failed: the intent RPC is not in public, so PostgREST cannot reach it', n; end if;
  n := n + 1;
  if not exists(select 1 from pg_proc p join pg_namespace ns on ns.oid=p.pronamespace
                 where ns.nspname='public' and p.proname='promo_provider_applied_v962') then
    raise exception 'A% failed: the applied RPC is not in public', n; end if;
  n := n + 1;
  if exists(select 1 from pg_proc p join pg_namespace ns on ns.oid=p.pronamespace
             where ns.nspname='app' and p.proname like 'promo_provider%v962') then
    raise exception 'A% failed: an app.* copy survives and can drift from the public one', n; end if;

  -- service_role only: the executor's hands are never a browser's
  n := n + 1;
  if has_function_privilege('authenticated','public.promo_provider_intent_v962(uuid)','execute')
     or has_function_privilege('anon','public.promo_provider_intent_v962(uuid)','execute') then
    raise exception 'A% failed: a browser role can read the executor intent', n; end if;
  n := n + 1;
  if not has_function_privilege('service_role','public.promo_provider_applied_v962(uuid,text,text)','execute') then
    raise exception 'A% failed: service_role cannot record the applied coupon', n; end if;

  -- ------------------------------------------------------------------ behaviour is v962's
  insert into auth.users(id,email) values (owner_s,'zz-v963@example.test') on conflict (id) do nothing;
  insert into public.businesses(id,name,slug,industry,join_enabled,enabled_modules)
  values (biz,'V963 fixture','v963-'||substr(biz::text,1,8),'test',true,array['dashboard']);
  insert into public.subscriptions(business_id,billing_provider,status,payment_status,currency,provider_subscription_id)
  values (biz,'stripe','active','paid','SGD','sub_v963fixture');
  insert into public.staff(business_id,user_id,role,active,full_name) values (biz,owner_s,'owner',true,'V963 Owner');

  perform set_config('request.jwt.claims', jsonb_build_object(
    'sub', sa, 'role', 'authenticated',
    'amr', jsonb_build_array(jsonb_build_object('method','oauth')),
    'app_metadata', jsonb_build_object('providers', jsonb_build_array('google')))::text, true);
  perform set_config('request.jwt.claim.sub', sa::text, true);

  perform public.platform_create_promo_code_v961('V963PCT','percent',2500,null,biz,null,null,'suite');
  got := public.business_redeem_promo_code_v961(biz,'V963PCT');
  red := (got->>'redemption_id')::uuid;

  n := n + 1;
  intent := public.promo_provider_intent_v962(biz);
  if (intent->>'has_intent') <> 'true' or (intent->>'percent_bps') <> '2500'
     or (intent->>'provider_subscription_id') <> 'sub_v963fixture' then
    raise exception 'A% failed: the public intent RPC does not answer: %', n, intent; end if;

  n := n + 1;
  got := public.promo_provider_applied_v962(red,'coupon_v963','');
  select * into row_r from public.platform_promo_redemptions_v961 where id=red;
  if (got->>'status') <> 'ok' or row_r.provider_coupon_id <> 'coupon_v963'
     or row_r.provider_applied_at is null then
    raise exception 'A% failed: the public applied RPC did not record the coupon', n; end if;

  n := n + 1;
  if (public.promo_provider_intent_v962(biz)->>'has_intent') <> 'false' then
    raise exception 'A% failed: an applied coupon is still offered to the executor', n; end if;

  raise notice 'v963 suite: % assertions passed', n;
end
$suite$;

rollback;
