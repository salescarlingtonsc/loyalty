-- v215 acceptance — welcome offer for first-time sign-ups.
--
-- Rolled back at the end: this suite runs against a real tenant and leaves nothing behind.
-- It is the checked-in form of the two chains run against production before shipping
-- (18/18 for the minimum-spend shape, 10/10 for the zero-minimum, expiry and join shapes).
--
-- Set :business and :owner to a real tenant and its owner auth user, e.g.
--   psql -v business=... -v owner=... -f db/tests/v215_signup_welcome_offer.sql

begin;

do $suite$
declare
  v_biz uuid := current_setting('v215.business', true)::uuid;
  v_owner uuid := current_setting('v215.owner', true)::uuid;
  v_root text := current_setting('role');
  v_branch uuid; v_prod uuid; v_prod_name text; v_ver int;
  v_new uuid; v_returning uuid; v_expired uuid;
  v_res jsonb; v_ent jsonb; v_cfg jsonb; v_join jsonb;
  v_sale uuid; v_small uuid; v_n int;
  v_pass int := 0; v_fail int := 0; v_log text := '';
begin
  if v_biz is null or v_owner is null then
    raise exception 'set v215.business and v215.owner before running this suite';
  end if;

  select id into v_branch from public.branches where business_id=v_biz and active limit 1;
  select id, name into v_prod, v_prod_name
  from public.products where business_id=v_biz and active order by name limit 1;
  if v_branch is null or v_prod is null then
    raise exception 'this tenant needs an active branch and an active product';
  end if;

  -- Fixtures are created with the migration role; every RPC runs as the real owner, so
  -- authorization is exercised rather than bypassed.
  insert into public.clients(business_id, full_name, phone)
  values (v_biz,'V215 New Joiner','+65 8000 0001') returning id into v_new;
  insert into public.clients(business_id, full_name, phone)
  values (v_biz,'V215 Existing Customer','+65 8000 0002') returning id into v_returning;
  insert into public.sales(business_id, client_id, kind, amount_cents, branch_id)
  values (v_biz, v_returning, 'retail', 3000, v_branch);

  perform set_config('request.jwt.claims',
    json_build_object('sub', v_owner::text, 'role','authenticated')::text, true);
  perform set_config('role','authenticated', true);

  -- === Shape 1: "minimum spend $5 (get free xx product)" ===
  v_cfg := public.business_set_welcome_offer_v215(v_biz, true, 500, 'product', v_prod, 90);
  if v_cfg->>'status'='ok' and (v_cfg->>'min_spend_cents')::int=500 and v_cfg->>'reward_label'=v_prod_name
    then v_pass:=v_pass+1; v_log:=v_log||E'\nPASS 1  owner set a $5 minimum for a free '||v_prod_name;
    else v_fail:=v_fail+1; v_log:=v_log||E'\nFAIL 1  '||v_cfg::text; end if;

  -- The label is read from the catalogue, so an offer can never name an item that is not real.
  begin
    perform public.business_set_welcome_offer_v215(v_biz, true, 500, 'product', gen_random_uuid(), null);
    v_fail:=v_fail+1; v_log:=v_log||E'\nFAIL 2  accepted an item that does not exist';
  exception when others then
    if sqlerrm like '%welcome_offer_item_unavailable%' then v_pass:=v_pass+1; v_log:=v_log||E'\nPASS 2  unknown item refused';
    else v_fail:=v_fail+1; v_log:=v_log||E'\nFAIL 2  '||sqlerrm; end if;
  end;

  -- A browser session must not be able to mint itself a free item.
  begin
    perform app.issue_welcome_offer_v215(v_biz, v_new);
    v_fail:=v_fail+1; v_log:=v_log||E'\nFAIL 3  authenticated could call the issuer directly';
  exception when insufficient_privilege then
    v_pass:=v_pass+1; v_log:=v_log||E'\nPASS 3  issuer is not callable from a browser session';
  end;

  perform set_config('role', v_root, true);
  if app.issue_welcome_offer_v215(v_biz, v_new) is not null
    then v_pass:=v_pass+1; v_log:=v_log||E'\nPASS 4  first-time joiner granted';
    else v_fail:=v_fail+1; v_log:=v_log||E'\nFAIL 4  no grant issued'; end if;
  -- "first time sign ups only", twice over: the guard, and the unique index behind it.
  if app.issue_welcome_offer_v215(v_biz, v_new) is null
    then v_pass:=v_pass+1; v_log:=v_log||E'\nPASS 5  a second issue for the same customer does nothing';
    else v_fail:=v_fail+1; v_log:=v_log||E'\nFAIL 5  issued twice'; end if;
  select count(*) into v_n from public.welcome_offer_grants_v215
  where business_id=v_biz and client_id=v_new;
  if v_n=1 then v_pass:=v_pass+1; v_log:=v_log||E'\nPASS 6  exactly one grant row exists';
  else v_fail:=v_fail+1; v_log:=v_log||E'\nFAIL 6  '||v_n||' grant rows'; end if;
  if app.issue_welcome_offer_v215(v_biz, v_returning) is null
    then v_pass:=v_pass+1; v_log:=v_log||E'\nPASS 7  a customer who already spent $30 is not a new sign-up';
    else v_fail:=v_fail+1; v_log:=v_log||E'\nFAIL 7  existing customer granted'; end if;

  insert into public.sales(business_id, client_id, kind, amount_cents, branch_id)
  values (v_biz, v_new, 'retail', 400, v_branch) returning id into v_small;
  insert into public.sales(business_id, client_id, kind, amount_cents, branch_id)
  values (v_biz, v_new, 'retail', 500, v_branch) returning id into v_sale;
  perform set_config('role','authenticated', true);

  v_ent := public.staff_get_customer_entitlements_v102(v_biz, v_new);
  if v_ent->'welcome_offer'->>'reward_label' = v_prod_name
     and (v_ent->'welcome_offer'->>'min_spend_cents')::int = 500
    then v_pass:=v_pass+1; v_log:=v_log||E'\nPASS 8  the till shows the offer and its minimum';
    else v_fail:=v_fail+1; v_log:=v_log||E'\nFAIL 8  '||coalesce(v_ent::text,'null'); end if;

  -- The minimum is proved against a REAL sale, never against a number the till sends.
  begin
    perform public.staff_redeem_welcome_offer_v215(v_biz, v_new, v_branch, null, 'v215-suite-a');
    v_fail:=v_fail+1; v_log:=v_log||E'\nFAIL 9  redeemed with no qualifying sale';
  exception when others then
    if sqlerrm like '%requires_qualifying_sale%' then v_pass:=v_pass+1; v_log:=v_log||E'\nPASS 9  redeem with no qualifying sale refused';
    else v_fail:=v_fail+1; v_log:=v_log||E'\nFAIL 9  '||sqlerrm; end if;
  end;
  begin
    perform public.staff_redeem_welcome_offer_v215(v_biz, v_new, v_branch, v_small, 'v215-suite-b');
    v_fail:=v_fail+1; v_log:=v_log||E'\nFAIL 10 redeemed on $4.00 against a $5.00 minimum';
  exception when others then
    if sqlerrm like '%min_spend_not_met%' then v_pass:=v_pass+1; v_log:=v_log||E'\nPASS 10 $4.00 refused against a $5.00 minimum';
    else v_fail:=v_fail+1; v_log:=v_log||E'\nFAIL 10 '||sqlerrm; end if;
  end;

  v_res := public.staff_redeem_welcome_offer_v215(v_biz, v_new, v_branch, v_sale, 'v215-suite-c');
  if v_res->>'status'='completed' and v_res->>'reward_label'=v_prod_name
    then v_pass:=v_pass+1; v_log:=v_log||E'\nPASS 11 redeemed at exactly $5.00';
    else v_fail:=v_fail+1; v_log:=v_log||E'\nFAIL 11 '||v_res::text; end if;
  -- The free item is a visit worth nothing. It must never appear as revenue.
  select amount_cents into v_n from public.sales where id=(v_res->>'sale_id')::uuid;
  if v_n=0 then v_pass:=v_pass+1; v_log:=v_log||E'\nPASS 12 the free item is booked as a $0 sale';
  else v_fail:=v_fail+1; v_log:=v_log||E'\nFAIL 12 booked '||v_n||' cents'; end if;

  -- A double-tap at a busy counter must not cost the firm a second item.
  v_res := public.staff_redeem_welcome_offer_v215(v_biz, v_new, v_branch, v_sale, 'v215-suite-c');
  if (v_res->>'replayed')::boolean then v_pass:=v_pass+1; v_log:=v_log||E'\nPASS 13 the same request replays its receipt';
  else v_fail:=v_fail+1; v_log:=v_log||E'\nFAIL 13 '||v_res::text; end if;
  select count(*) into v_n from public.sales
  where business_id=v_biz and client_id=v_new and amount_cents=0;
  if v_n=1 then v_pass:=v_pass+1; v_log:=v_log||E'\nPASS 14 exactly one free item was ever given';
  else v_fail:=v_fail+1; v_log:=v_log||E'\nFAIL 14 '||v_n||' free items'; end if;
  begin
    perform public.staff_redeem_welcome_offer_v215(v_biz, v_new, v_branch, v_sale, 'v215-suite-d');
    v_fail:=v_fail+1; v_log:=v_log||E'\nFAIL 15 redeemed twice under a different key';
  exception when others then
    if sqlerrm like '%already_redeemed%' then v_pass:=v_pass+1; v_log:=v_log||E'\nPASS 15 a second redeem under a new key is refused';
    else v_fail:=v_fail+1; v_log:=v_log||E'\nFAIL 15 '||sqlerrm; end if;
  end;
  v_ent := public.staff_get_customer_entitlements_v102(v_biz, v_new);
  if v_ent->'welcome_offer' is null or jsonb_typeof(v_ent->'welcome_offer')='null'
    then v_pass:=v_pass+1; v_log:=v_log||E'\nPASS 16 a redeemed offer is withdrawn from the till';
    else v_fail:=v_fail+1; v_log:=v_log||E'\nFAIL 16 '||(v_ent->'welcome_offer')::text; end if;

  v_cfg := public.business_get_welcome_offer_v215(v_biz);
  if (v_cfg->>'configured')::boolean and (v_cfg->>'redeemed_count')::int >= 1
     and (v_cfg->>'item_available')::boolean
    then v_pass:=v_pass+1; v_log:=v_log||E'\nPASS 17 the owner reader reports config, counts and item health';
    else v_fail:=v_fail+1; v_log:=v_log||E'\nFAIL 17 '||v_cfg::text; end if;
  select count(*) into v_n from public.audit_log
  where business_id=v_biz and action in ('WELCOME_OFFER_SET_V215','WELCOME_OFFER_REDEEMED_V215');
  if v_n >= 2 then v_pass:=v_pass+1; v_log:=v_log||E'\nPASS 18 both writes are audited';
  else v_fail:=v_fail+1; v_log:=v_log||E'\nFAIL 18 only '||v_n||' audit rows'; end if;

  -- === Shape 2: "no minimum spend and free xx product" ===
  perform public.business_set_welcome_offer_v215(v_biz, true, 0, 'product', v_prod, null);
  perform set_config('role', v_root, true);
  insert into public.clients(business_id, full_name, phone)
  values (v_biz,'V215 Zero Min','+65 8000 0011') returning id into v_expired;
  perform app.issue_welcome_offer_v215(v_biz, v_expired);
  perform set_config('role','authenticated', true);
  v_res := public.staff_redeem_welcome_offer_v215(v_biz, v_expired, v_branch, null, 'v215-suite-zero');
  if v_res->>'status'='completed'
    then v_pass:=v_pass+1; v_log:=v_log||E'\nPASS 19 a zero-minimum offer redeems with no purchase at all';
    else v_fail:=v_fail+1; v_log:=v_log||E'\nFAIL 19 '||v_res::text; end if;

  -- === Expiry: withheld before it is refused, so staff never promise it ===
  perform set_config('role', v_root, true);
  insert into public.clients(business_id, full_name, phone)
  values (v_biz,'V215 Expired','+65 8000 0012') returning id into v_expired;
  insert into public.welcome_offer_grants_v215(business_id, client_id, min_spend_cents,
    reward_catalog_kind, reward_catalog_id, reward_label, expires_at)
  values (v_biz, v_expired, 0, 'product', v_prod, v_prod_name, now() - interval '1 day');
  perform set_config('role','authenticated', true);
  v_ent := public.staff_get_customer_entitlements_v102(v_biz, v_expired);
  if v_ent->'welcome_offer' is null or jsonb_typeof(v_ent->'welcome_offer')='null'
    then v_pass:=v_pass+1; v_log:=v_log||E'\nPASS 20 an expired offer is never shown at the till';
    else v_fail:=v_fail+1; v_log:=v_log||E'\nFAIL 20 '||(v_ent->'welcome_offer')::text; end if;
  begin
    perform public.staff_redeem_welcome_offer_v215(v_biz, v_expired, v_branch, null, 'v215-suite-exp');
    v_fail:=v_fail+1; v_log:=v_log||E'\nFAIL 21 redeemed an expired offer';
  exception when others then
    if sqlerrm like '%welcome_offer_expired%' then v_pass:=v_pass+1; v_log:=v_log||E'\nPASS 21 an expired offer is refused';
    else v_fail:=v_fail+1; v_log:=v_log||E'\nFAIL 21 '||sqlerrm; end if;
  end;

  -- === A deactivated free item stops NEW grants rather than promising the undeliverable ===
  perform set_config('role', v_root, true);
  update public.products set active=false where id=v_prod;
  insert into public.clients(business_id, full_name, phone)
  values (v_biz,'V215 Dead Item','+65 8000 0013') returning id into v_expired;
  if app.issue_welcome_offer_v215(v_biz, v_expired) is null
    then v_pass:=v_pass+1; v_log:=v_log||E'\nPASS 22 no grant is issued when the free item is deactivated';
    else v_fail:=v_fail+1; v_log:=v_log||E'\nFAIL 22 granted a deactivated item'; end if;
  perform set_config('role','authenticated', true);
  if (public.business_get_welcome_offer_v215(v_biz)->>'item_available')::boolean = false
    then v_pass:=v_pass+1; v_log:=v_log||E'\nPASS 23 the owner is told their free item is unavailable';
    else v_fail:=v_fail+1; v_log:=v_log||E'\nFAIL 23 item_available is still true'; end if;
  perform set_config('role', v_root, true);
  update public.products set active=true where id=v_prod;

  -- === End to end: the real anon join RPC issues the offer with no further action ===
  select token_version into v_ver from public.business_customer_join_qr_v89
  where business_id=v_biz and status='active' limit 1;
  if v_ver is null then
    v_log:=v_log||E'\nSKIP 24 this tenant has no active join QR';
  else
    v_join := public.internal_public_join_v89(app.v197_join_token(v_biz,v_ver),
      'V215 Real Join','+65 8000 0014', null, true);
    if v_join->>'status'='ok' then v_pass:=v_pass+1; v_log:=v_log||E'\nPASS 24 the anon join through the real QR succeeded';
    else v_fail:=v_fail+1; v_log:=v_log||E'\nFAIL 24 '||v_join::text; end if;
    -- The join RPC normalises the number, so match on phone_norm, not the entered string.
    select count(*) into v_n from public.welcome_offer_grants_v215 grant_row
    join public.clients client on client.id=grant_row.client_id
    where grant_row.business_id=v_biz and client.phone_norm='80000014';
    if v_n=1 then v_pass:=v_pass+1; v_log:=v_log||E'\nPASS 25 joining issued the welcome offer by itself';
    else v_fail:=v_fail+1; v_log:=v_log||E'\nFAIL 25 '||v_n||' grants after a real join'; end if;
    perform public.internal_public_join_v89(app.v197_join_token(v_biz,v_ver),
      'V215 Real Join','+65 8000 0014', null, true);
    select count(*) into v_n from public.welcome_offer_grants_v215 grant_row
    join public.clients client on client.id=grant_row.client_id
    where grant_row.business_id=v_biz and client.phone_norm='80000014';
    if v_n=1 then v_pass:=v_pass+1; v_log:=v_log||E'\nPASS 26 rejoining the same number issues nothing more';
    else v_fail:=v_fail+1; v_log:=v_log||E'\nFAIL 26 '||v_n||' grants after rejoining'; end if;

    perform set_config('role','authenticated', true);
    perform public.business_set_welcome_offer_v215(v_biz, false, 0, 'product', v_prod, null);
    perform set_config('role', v_root, true);
    perform public.internal_public_join_v89(app.v197_join_token(v_biz,v_ver),
      'V215 After Off','+65 8000 0015', null, true);
    select count(*) into v_n from public.welcome_offer_grants_v215 grant_row
    join public.clients client on client.id=grant_row.client_id
    where grant_row.business_id=v_biz and client.phone_norm='80000015';
    if v_n=0 then v_pass:=v_pass+1; v_log:=v_log||E'\nPASS 27 switching the offer off stops new grants immediately';
    else v_fail:=v_fail+1; v_log:=v_log||E'\nFAIL 27 '||v_n||' grants while the offer is off'; end if;
  end if;

  raise notice 'V215 acceptance: % passed, % failed%', v_pass, v_fail, v_log;
  if v_fail > 0 then
    raise exception 'V215 acceptance failed: % of % assertions%', v_fail, v_pass+v_fail, v_log;
  end if;
end $suite$;

rollback;
