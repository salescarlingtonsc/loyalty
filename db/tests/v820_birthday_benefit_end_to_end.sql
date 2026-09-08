-- Rollback-only end-to-end walk of the BIRTHDAY BENEFIT, run as the REAL principals.
--   supabase db query --linked -f db/tests/v820_birthday_benefit_end_to_end.sql
--
-- Verification only — no migration accompanies this suite. It answers three owner questions
-- (2026-09-08): does the birthday gift come off the bill at checkout; does a NEW customer who
-- signs up inside their birthday window receive it; and does a customer who used it, deleted
-- their account and signed up again NOT receive it twice.
--
-- THE PLATFORM SWITCH. app.platform_feature_flags.customer_birthday_benefits has been FALSE
-- since nestly_v45 created it. Every reader and the redemption authority refuse with 0A000
-- while it is off, and the till and the customer wallet do not paint the card. F1 proves that
-- refusal on the live value; the suite then forces the switch ON inside this transaction so the
-- machinery behind it can be exercised. Turning it on for real is the owner's decision.
--
--   F1  live: with the switch off, the staff reader refuses with 0A000 (nothing reaches anyone)
--
--   ÉLAN Wellness — live programme "10% off the whole bill", birthday MONTH window
--   N1  a brand-new registration (opted in, September birthday) joins ÉLAN today → the entitlement is written FOR them (no "activate" tap), status available
--   N2  the customer's wallet and the staff card both read it as available
--   N3  the till, with the birthday gift staged (p_birthday), quotes 10% off a $108 service
--   N4  finalising writes the "Birthday gift" line, marks the entitlement redeemed and records
--       the redemption in the same transaction; a second staging is refused
--
--   Jess Salon — live programme free item, ±180-day window
--   R1  CONTROL: a fresh member inside the window is granted the gift
--   R2  the counter hands it over (redeemed)
--   R3  the customer deletes their account → a hashed-phone mark is left for Jess Salon and the
--       customer row is anonymised
--   R4  the same phone number registers a NEW account and joins Jess Salon again, inside the
--       window → NO entitlement; the wallet does not invite; the Activate tap is refused
--   R5  CONTROL: a different phone number signing up the same way IS granted (the block is the
--       mark, not the programme)
--   R6  the mark expires: a mark older than 365 days no longer blocks
--
-- evaluate_checkout / customer_activate_birthday_benefit RAISE on refusal; the refusal probes
-- catch that and read the sqlstate / message back.
--
-- NEGATIVE CONTROL: copy this file and, before the suite, add
--     create or replace function app.phone_recently_deleted_v751(p_business uuid, p_client uuid) returns boolean
--       language sql as $$ select false $$;
--   R4 must fail ("granted a second birthday gift") — the assertions read the live guard.

begin;

-- Fixture helpers, temp-schema only (gone at rollback). They write the SAME rows the real
-- registration (customer_register_verified_phone) and the claim routes write, through the same
-- guards: the C42 profile guard wants app.c42_profile_identity, the v31 link guard wants
-- app.customer_link_insert_id — both set transaction-locally here, exactly as the RPCs do.
create function pg_temp.bday_register(p_user uuid, p_ident uuid, p_phone text, p_dob date) returns void
language plpgsql as $f$
begin
  insert into auth.users(instance_id, id, aud, role, phone, phone_confirmed_at, created_at, updated_at,
                         raw_app_meta_data, raw_user_meta_data, is_sso_user, is_anonymous)
  values ('00000000-0000-0000-0000-000000000000', p_user, 'authenticated', 'authenticated', '65'||p_phone, now(), now(), now(),
          '{"provider":"phone","providers":["phone"]}', '{}', false, false);
  insert into public.customer_identities(id, auth_user_id, status, created_via) values (p_ident, p_user, 'active', 'phone_registration');
  perform set_config('app.c42_profile_identity', p_ident::text, true);
  insert into public.customer_profiles(identity_id, auth_user_id, full_name, birth_date, gender, preferred_language)
  values (p_ident, p_user, 'Birthday Tester', p_dob, 'prefer_not_to_say', 'en');
  perform set_config('app.c42_profile_identity', '', true);
  -- registration already seeds an opted-OUT participation row; the customer turns it on in-app
  insert into public.customer_birthday_participation(identity_id, auth_user_id, opted_in) values (p_ident, p_user, true)
  on conflict (identity_id) do update set opted_in = true, updated_at = now();
end $f$;

create function pg_temp.bday_join(p_ident uuid, p_user uuid, p_biz uuid, p_phone text) returns uuid
language plpgsql as $f$
declare v_client uuid; v_link uuid := gen_random_uuid();
begin
  insert into public.clients(business_id, full_name, phone) values (p_biz, 'Birthday Tester', '+65 '||p_phone) returning id into v_client;
  perform set_config('app.customer_link_insert_id', v_link::text, true);
  insert into public.customer_links(id, identity_id, auth_user_id, client_id, business_id, state, verification_method, verified_at)
  values (v_link, p_ident, p_user, v_client, p_biz, 'verified', 'qr_join', now());
  perform set_config('app.customer_link_insert_id', '', true);
  return v_client;
end $f$;

do $suite$
declare
  -- ÉLAN Wellness
  e_biz    constant uuid := '8ccace3a-9736-447e-bb1e-da842622592d';
  e_slug   constant text := 'kky-demo';
  e_owner  constant uuid := '8efcffc8-61a5-4235-ad45-54a8954208f9';
  e_branch constant uuid := '586f4069-12cb-4f54-b37c-8c5742244520';
  e_svc    constant uuid := '8a191981-7df0-44e7-a452-92581e3c8ea3';   -- $108.00
  e_user   constant uuid := gen_random_uuid();                          -- a brand-new registration
  e_ident  constant uuid := gen_random_uuid();
  e_phone  constant text := '81111111';
  -- Jess Salon
  j_biz    constant uuid := '709387ff-5768-4767-9dad-abd665c2bb07';
  j_slug   constant text := 'jess-salon';
  j_owner  constant uuid := 'b8ba53b5-b20d-4d6d-b6fe-66f014758fab';
  j_branch constant uuid := '384be1b4-c9db-46ee-b25f-2c2d617fe26d';
  j_user   constant uuid := gen_random_uuid();                          -- registration A (will delete)
  j_ident  constant uuid := gen_random_uuid();
  j_phone  constant text := '82222222';
  j_phone2 constant text := '83333333';
  j_dob    constant date := '1998-03-15';                             -- inside ±180 days of today

  v_client uuid; v_client2 uuid; v_client3 uuid; v_ent uuid; v_sale uuid;
  v_new_user uuid := gen_random_uuid(); v_new_ident uuid := gen_random_uuid();
  v_eval jsonb; v_res jsonb; v_cust jsonb; v_staff jsonb; v_amt int; v_state text;
  v_lines jsonb;
  n integer := 0;
begin
  -- ------------------------------------------------------------------ F1 the live switch
  n := n + 1;
  if (select enabled from app.platform_feature_flags where feature_key = 'customer_birthday_benefits') then
    raise notice 'F%: customer_birthday_benefits is ON in production (the F1 refusal check is skipped)', n;
  else
    set local role authenticated;
    perform set_config('request.jwt.claims', json_build_object('sub',e_owner,'role','authenticated')::text, true);
    begin
      v_res := public.staff_get_customer_birthday_benefit(e_biz, gen_random_uuid());
      v_state := 'no error';
    exception when others then v_state := sqlstate; end;
    reset role; perform set_config('request.jwt.claims','',true);
    if v_state <> '0A000' then
      raise exception 'F%: with the platform switch OFF the staff reader answered % (expected 0A000)', n, v_state;
    end if;
  end if;
  update app.platform_feature_flags set enabled = true where feature_key = 'customer_birthday_benefits';

  -- =========================================================== ÉLAN: newcomer + checkout
  -- N1 signup inside the window → granted with no tap --------------------------------------
  n := n + 1;
  if exists (select 1 from public.clients where business_id = e_biz and phone_norm = e_phone) then
    raise exception 'N%: fixture drift — % is already an ÉLAN customer', n, e_phone;
  end if;
  perform pg_temp.bday_register(e_user, e_ident, e_phone, '1997-09-20');   -- a September birthday, opted in
  v_client := pg_temp.bday_join(e_ident, e_user, e_biz, e_phone);
  select id into v_ent from public.customer_birthday_entitlements
   where business_id = e_biz and client_id = v_client and status = 'available'
     and valid_from <= now() and valid_until > now();
  if v_ent is null then
    raise exception 'N%: a newcomer inside the birthday window was not granted the gift on joining', n;
  end if;

  -- N2 both readers ------------------------------------------------------------------------
  n := n + 1;
  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub',e_user,'role','authenticated')::text, true);
  v_cust := public.customer_get_birthday_benefit(e_slug);
  perform set_config('request.jwt.claims', json_build_object('sub',e_owner,'role','authenticated')::text, true);
  v_staff := public.staff_get_customer_birthday_benefit(e_biz, v_client);
  reset role; perform set_config('request.jwt.claims','',true);
  if v_cust->>'status' <> 'available' or v_staff->>'status' <> 'available' then
    raise exception 'N%: readers do not both say available (customer % / staff %)', n, left(v_cust::text,200), left(v_staff::text,200);
  end if;

  -- N3 the till quotes it -------------------------------------------------------------------
  n := n + 1;
  v_lines := jsonb_build_array(jsonb_build_object('catalog_kind','service','catalog_id',e_svc,'qty',1));
  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub',e_owner,'role','authenticated')::text, true);
  v_eval := public.evaluate_checkout(e_biz, e_branch, v_client, v_lines, gen_random_uuid(), null::uuid, true);
  reset role; perform set_config('request.jwt.claims','',true);
  select max((e->>'amount_cents')::int) into v_amt
    from jsonb_array_elements(v_eval->'applied_effects') e where e->>'source' = 'birthday_benefit';
  if v_eval->>'status' <> 'ok' or v_amt <> 1080 or (v_eval->>'total_cents')::int <> 9720
     or not exists (select 1 from jsonb_array_elements(v_eval->'applied_effects') e where e->>'birthday_entitlement_id' = v_ent::text) then
    raise exception 'N%: expected 10%% of 10800 = 1080 off → 9720 from entitlement %; got % off, total % (%)',
      n, v_ent, v_amt, v_eval->>'total_cents', left(v_eval::text,400);
  end if;

  -- N4 finalise spends it; second staging refused -------------------------------------------
  n := n + 1;
  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub',e_owner,'role','authenticated')::text, true);
  v_res := public.record_cart_sale(e_biz, v_client, e_branch, null, 'cash', 'bday-e2e-'||gen_random_uuid()::text,
    v_lines, (v_eval->>'evaluation_id')::uuid, true, now(), '[]'::jsonb)::jsonb;
  v_sale := (v_res->>'sale_id')::uuid;
  begin
    v_eval := public.evaluate_checkout(e_biz, e_branch, v_client, v_lines, gen_random_uuid(), null::uuid, true);
    v_state := 'accepted';
  exception when others then v_state := split_part(sqlerrm, ':', 1); end;
  perform set_config('request.jwt.claims', json_build_object('sub',e_user,'role','authenticated')::text, true);
  v_cust := public.customer_get_birthday_benefit(e_slug);
  reset role; perform set_config('request.jwt.claims','',true);
  if v_sale is null then raise exception 'N%: the till returned no sale (%)', n, left(v_res::text,300); end if;
  if (select amount_cents from public.sales where id = v_sale) <> 9720
     or (select count(*) from public.sale_items si where si.sale_id = v_sale and si.item_type = 'studio_discount'
           and si.ref_id = v_ent and si.line_cents = -1080 and si.description like 'Birthday gift:%') <> 1 then
    raise exception 'N%: the sale does not carry the -1080 Birthday gift line (total %)', n, (select amount_cents from public.sales where id = v_sale);
  end if;
  if (select status from public.customer_birthday_entitlements where id = v_ent) <> 'redeemed'
     or not exists (select 1 from public.customer_birthday_redemptions r where r.entitlement_id = v_ent) then
    raise exception 'N%: the entitlement was not spent with the money', n;
  end if;
  if v_state <> 'birthday_benefit_not_available' then
    raise exception 'N%: a second birthday staging on a spent gift answered % (expected birthday_benefit_not_available)', n, v_state;
  end if;
  if v_cust->>'status' = 'available' then
    raise exception 'N%: the wallet still shows the gift as available after it was spent', n;
  end if;

  -- =========================================================== Jess Salon: delete & rejoin
  -- R1 control signup ----------------------------------------------------------------------
  n := n + 1;
  if exists (select 1 from public.clients where business_id = j_biz and phone_norm in (j_phone, j_phone2)) then
    raise exception 'R%: fixture drift — % / % is already a Jess Salon customer', n, j_phone, j_phone2;
  end if;
  perform pg_temp.bday_register(j_user, j_ident, j_phone, j_dob);
  v_client := pg_temp.bday_join(j_ident, j_user, j_biz, j_phone);
  select id into v_ent from public.customer_birthday_entitlements
   where business_id = j_biz and client_id = v_client and status = 'available' and valid_from <= now() and valid_until > now();
  if v_ent is null then raise exception 'R%: control signup inside the window was not granted', n; end if;

  -- R2 handed over at the counter ---------------------------------------------------------------
  n := n + 1;
  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub',j_owner,'role','authenticated')::text, true);
  v_res := public.staff_confirm_birthday_free_item_v752(j_biz, v_client, j_branch, gen_random_uuid());
  reset role; perform set_config('request.jwt.claims','',true);
  if (select status from public.customer_birthday_entitlements where id = v_ent) <> 'redeemed' then
    raise exception 'R%: the free item was not marked redeemed (%)', n, left(v_res::text,300);
  end if;

  -- R3 the customer deletes the account ---------------------------------------------------------
  n := n + 1;
  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub',j_user,'role','authenticated')::text, true);
  v_res := public.customer_delete_account_v749('DELETE', 'bday-e2e-del-'||gen_random_uuid()::text);
  reset role; perform set_config('request.jwt.claims','',true);
  if not exists (select 1 from public.customer_deletion_marks_v751 m
                  where m.business_id = j_biz and m.phone_hash = app.v89_sha256(j_phone) and m.deleted_at > now() - interval '1 minute') then
    raise exception 'R%: deleting the account left no mark for Jess Salon (%)', n, left(v_res::text,300);
  end if;
  if (select phone from public.clients where id = v_client) is not null then
    raise exception 'R%: the deleted customer''s phone was not erased', n;
  end if;

  -- R4 same number, new account, joins again inside the window → nothing ------------------------
  n := n + 1;
  perform pg_temp.bday_register(v_new_user, v_new_ident, j_phone, j_dob);       -- registration B, same number
  v_client2 := pg_temp.bday_join(v_new_ident, v_new_user, j_biz, j_phone);
  if exists (select 1 from public.customer_birthday_entitlements where business_id = j_biz and client_id = v_client2) then
    raise exception 'R%: a number that deleted its account was granted a second birthday gift on rejoining', n;
  end if;
  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub',v_new_user,'role','authenticated')::text, true);
  v_cust := public.customer_get_birthday_benefit(j_slug);
  begin
    v_res := public.customer_activate_birthday_benefit(j_slug, gen_random_uuid());
    v_state := 'accepted';
  exception when others then v_state := sqlstate; end;
  reset role; perform set_config('request.jwt.claims','',true);
  if v_cust->>'status' in ('available','ready_to_activate') then
    raise exception 'R%: the wallet invites the rejoined number to a second gift (%)', n, left(v_cust::text,300);
  end if;
  if v_state <> '42501' then
    raise exception 'R%: the Activate tap answered % for the rejoined number (expected 42501)', n, v_state;
  end if;

  -- R5 control: a different number is unaffected ----------------------------------------------------
  n := n + 1;
  insert into public.clients(business_id, full_name, phone) values (j_biz, 'Fresh Number', '+65 '||j_phone2) returning id into v_client3;
  -- the trigger fires on customer_links; drive the same evaluator the trigger calls, for this identity
  perform app.v753_birthday_evaluate_and_grant(j_biz, v_client3, v_new_ident, j_dob, now());
  if not exists (select 1 from public.customer_birthday_entitlements where business_id = j_biz and client_id = v_client3 and status = 'available') then
    raise exception 'R%: a fresh number inside the window was NOT granted — the block is not the mark', n;
  end if;

  -- R6 the mark expires after 365 days --------------------------------------------------------------
  n := n + 1;
  update public.customer_deletion_marks_v751 set deleted_at = now() - interval '366 days'
   where business_id = j_biz and phone_hash = app.v89_sha256(j_phone);
  perform app.v753_birthday_evaluate_and_grant(j_biz, v_client2, v_new_ident, j_dob, now());
  if not exists (select 1 from public.customer_birthday_entitlements where business_id = j_biz and client_id = v_client2 and status = 'available') then
    raise exception 'R%: a mark older than 365 days still blocks the gift', n;
  end if;

  raise notice 'v820 birthday benefit: % / % assertions passed', n, n;
end
$suite$;

rollback;
