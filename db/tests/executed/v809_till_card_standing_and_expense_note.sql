-- Rollback-only nestly_v809 acceptance: the till reads ONE customer card whichever way staff
-- found the customer, it can re-read that card without a phone number, and an expense note can
-- actually be cleared.
--
-- WHAT THE BUGS WERE
--   F020  v474 fixed "15 stamps vs 5 of 10" by adding a stamp_card object to
--         public.lookup_client_by_phone and to nothing else. The two QR entry points that put the
--         SAME customer card on screen — staff_scan_member_qr_v327 and
--         staff_scan_gift_qr_to_till_v666, both built by app.v666_till_customer_card — returned
--         no stamp_card, so the till header fell through to the raw points balance, which on a
--         stamps firm is the POT. The same customer read "18 stamps" when scanned and "3 of 5"
--         when typed in by phone. Owner rule v473: staff read the CARD, never the pot.
--   F057  refreshTillCustomerStandingV408 re-read the balance only through
--         lookup_client_by_phone and bailed when there was no phone. A customer auto-provisioned
--         by a member-QR scan has clients.phone_norm NULL (staff_scan_member_qr_v327 inserts
--         business_id and full_name only), so after a manual redeem, a gift-QR redemption or a
--         gift undo the header kept the pre-redemption figure. 23 of 70 production clients have
--         no phone_norm.
--   F105  public.update_expense_v285 resolved the note as
--         coalesce(nullif(btrim(coalesce(p_note,'')),''), expense.note). NULL meant "unchanged",
--         and an emptied Note field reaches the RPC as NULL — so clearing a note was impossible
--         and the dialog said "Expense corrected" anyway.
--
-- WHAT THIS SUITE PROVES, against two tenants it builds itself, as the real principals:
--    1.  F020 exactly ONE app.till_stamp_card_v809 exists — one authority for the card.
--    2.  F020 the QR card (app.v666_till_customer_card) now CARRIES a stamp_card. This is the
--        assertion that fails on pre-v809: the key was simply absent.
--    3.  F020 the QR card's stamp_card and the phone lookup's stamp_card are IDENTICAL for the
--        same customer — the discrepancy the owner escalated in v474 cannot recur.
--    4.  F020 canonical correctness (protocol §6): reader A == reader B == the RULE. Both agree
--        with app.stamp_progress_v323 itself — slots, the clamped filled, the carry and the pot.
--    5.  F020 control — on a POINTS tenant both readers return stamp_card NULL. The stamps object
--        was added where the model asks for it, not everywhere.
--    6.  F057 exactly ONE public.till_customer_standing_v809 exists (two overloads would answer a
--        named-argument PostgREST call with PGRST203, which is how v410 blocked promotion saves).
--    7.  F057 the standing reader returns the FULL card for a customer who has NO phone at all —
--        precisely the customer lookup_client_by_phone can never serve. Fails on pre-v809: the
--        function does not exist.
--    8.  F057 it agrees with the phone lookup for a customer who HAS a phone, so the till cannot
--        be shown two different standings for one person.
--    9.  F057 negative — somebody who is not a member of the business is refused 42501. The new
--        reader did not become a way in.
--   10.  F105 exactly ONE public.update_expense_v285 exists after the drop-and-recreate.
--   11.  F105 p_clear_note => true actually empties the note. Fails on pre-v809.
--   12.  F105 the FIVE-argument call (p_note null, no flag) still means "unchanged", so nothing
--        that has not been updated is broken.
--   13.  F105 a note is still written when one is given, alongside amount and category.
--   14.  F105 writing a note AND clearing is refused (22023) and the row is left exactly as it was.
--   15.  F105 negative — the finance guard still refuses a non-member (42501), note untouched.
--
-- Run inside this transaction; every fixture row is rolled back:
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f db/tests/v809_till_card_standing_and_expense_note.sql
-- Assertions are recorded as rows so one SELECT reports the whole suite; a final gate makes any
-- FAIL fatal, because scripts/db-tests/run.mjs judges a file purely by psql's exit code.

begin;

create temp table v809_out(seq integer, step text, outcome text) on commit drop;
grant insert, select on v809_out to public;

create or replace function pg_temp.as_v809_system() returns void language plpgsql as $$
begin
  execute 'reset role';
  perform set_config('request.jwt.claim.sub','',true);
  perform set_config('request.jwt.claims','',true);
end
$$;
grant execute on function pg_temp.as_v809_system() to authenticated;

create or replace function pg_temp.as_v809_user(p_uid uuid) returns void language plpgsql as $$
begin
  execute 'reset role';
  perform set_config('request.jwt.claim.sub','',true);
  perform set_config('request.jwt.claims','{}',true);
  execute 'set local role authenticated';
  perform set_config('request.jwt.claim.sub', coalesce(p_uid::text,''), true);
  perform set_config('request.jwt.claims',
    json_build_object('sub',p_uid,'role','authenticated')::text, true);
end
$$;
grant execute on function pg_temp.as_v809_user(uuid) to authenticated;

-- An operational tenant whose owner may work the till AND the expense book: approved workspace,
-- unpaused subscription, a paid subscriptions row (business_operational_v620), the clients, till
-- and expenses modules on, one owner, one default branch.
create or replace function pg_temp.v809_tenant(
  p_business uuid, p_owner uuid, p_branch uuid, p_label text
) returns void language plpgsql as $$
declare
  v_owner_staff uuid;
begin
  insert into auth.users(instance_id,id,aud,role,email,encrypted_password,
                         email_confirmed_at,created_at,updated_at)
  values ('00000000-0000-0000-0000-000000000000',p_owner,'authenticated','authenticated',
          'v809-owner-'||substr(p_owner::text,1,8)||'@example.test','',now(),now(),now())
  on conflict (id) do nothing;

  perform set_config('app.v79_system_transition','on',true);
  insert into public.businesses(id,name,slug,industry,currency,enabled_modules,points_mode)
  values (p_business,'V809 '||p_label,'v809-'||substr(p_business::text,1,8),
          'fnb','SGD',
          array['dashboard','clients','sales','services','till','loyalty','retention','expenses'],
          'redeem');
  perform set_config('app.v79_system_transition','',true);

  update public.business_workspace_controls_v94
     set approval_status='approved', version=version+1, decided_by=p_owner,
         decided_at=clock_timestamp(), decision_reason='v809 rollback fixture',
         updated_at=clock_timestamp()
   where business_id = p_business;
  insert into public.business_subscription_lifecycle_v94(business_id,workspace_paused)
  values (p_business,false)
  on conflict (business_id) do update set workspace_paused=false;
  insert into public.subscriptions(business_id,status,payment_status,current_period_end)
  values (p_business,'active','paid',now()+interval '30 days')
  on conflict (business_id) do update
    set status='active', payment_status='paid', current_period_end=now()+interval '30 days';

  insert into public.staff(business_id,user_id,role,full_name,active,access_state)
  values (p_business,p_owner,'owner','V809 Owner '||p_label,true,'approved')
  returning id into v_owner_staff;
  insert into public.branches(id,business_id,name,active,is_default)
  values (p_branch,p_business,'V809 Main '||p_label,true,true);
  insert into public.staff_branches(business_id,staff_id,branch_id)
  values (p_business,v_owner_staff,p_branch);
end
$$;
grant execute on function pg_temp.v809_tenant(uuid,uuid,uuid,text) to authenticated;

-- One published firm configuration carrying one loyalty programme version, so
-- app.stamp_cycle_version_v416 has a version to pin a card to.
create or replace function pg_temp.v809_publish(
  p_business uuid, p_config uuid, p_owner uuid, p_kind text, p_stamp_target integer
) returns void language plpgsql as $$
begin
  -- Only one row per business may be 'published' (firm_config_one_published_per_business), and
  -- creating the tenant already made one, so this supersedes it exactly as a real publish does.
  update public.firm_config_versions
     set status='superseded', superseded_at=now()-interval '2 days'
   where business_id=p_business and status='published';
  insert into public.firm_config_versions(id,business_id,version_no,status,source,snapshot_hash,
                                          created_by,published_at)
  select p_config,p_business,coalesce(max(version_no),0)+1,'published','manual',
         md5(p_config::text),p_owner,now()-interval '2 days'
    from public.firm_config_versions where business_id=p_business;
  insert into public.loyalty_program_versions(
    config_version_id,business_id,kind,loyalty_model,active,
    earn_points_per_dollar,redeem_points,reward_credit_cents,tier_basis,expiry_mode,
    stamp_target,stamp_per_cents)
  values (p_config,p_business,p_kind,
          case when p_kind='stamps' then 'stamps' else 'points_tiers' end,true,
          1,50,0,'points_earned','none',p_stamp_target,500);
  perform set_config('app.v79_system_transition','on',true);
  update public.businesses set active_config_version_id=p_config where id=p_business;
  perform set_config('app.v79_system_transition','',true);
end
$$;
grant execute on function pg_temp.v809_publish(uuid,uuid,uuid,text,integer) to authenticated;

-- Put p_stamps stamps in one customer's stamp pot, through the one route
-- app.loyalty_ledger_write_guard admits from a system principal.
create or replace function pg_temp.v809_seed_stamps(
  p_business uuid, p_client uuid, p_spine uuid, p_stamps integer
) returns void language plpgsql as $$
declare v_seed uuid := gen_random_uuid();
begin
  perform app.acquire_loyalty_shared_v480(p_business);
  perform set_config('app.points_ledger_insert_id',v_seed::text,true);
  perform set_config('app.points_ledger_write_scope','programme_pot_transfer',true);
  insert into public.points_ledger(id,business_id,client_id,entry_type,points,reference,actor,
                                   programme_id,created_at)
  values (v_seed,p_business,p_client,'adjust',p_stamps,'v809 seed stamps',null,p_spine,
          now()-interval '1 day');
  perform set_config('app.points_ledger_insert_id','',true);
  perform set_config('app.points_ledger_write_scope','',true);
end
$$;
grant execute on function pg_temp.v809_seed_stamps(uuid,uuid,uuid,integer) to authenticated;

do $v809_test$
declare
  -- ---------------------------------------------------------------- the stamps tenant
  bS uuid := gen_random_uuid();
  oS uuid := gen_random_uuid();
  brS uuid := gen_random_uuid();
  cfgS uuid := gen_random_uuid();
  spineS uuid;
  phoned uuid := gen_random_uuid();      -- reachable by phone AND by client id
  phoneless uuid := gen_random_uuid();   -- the member-QR shape: no phone at all
  -- ---------------------------------------------------------------- the points tenant
  bP uuid := gen_random_uuid();
  oP uuid := gen_random_uuid();
  brP uuid := gen_random_uuid();
  cfgP uuid := gen_random_uuid();
  clientP uuid := gen_random_uuid();
  -- ---------------------------------------------------------------- the outsider
  outsider uuid := gen_random_uuid();
  -- ---------------------------------------------------------------- working
  v_count integer;
  v_card jsonb;
  v_lookup json;
  v_standing jsonb;
  v_sp record;
  v_expense uuid;
  v_note text;
  v_err text;
begin
  perform pg_temp.as_v809_system();
  insert into auth.users(instance_id,id,aud,role,email,encrypted_password,
                         email_confirmed_at,created_at,updated_at)
  values ('00000000-0000-0000-0000-000000000000',outsider,'authenticated','authenticated',
          'v809-outsider@example.test','',now(),now(),now());

  -- ============================================================ FIXTURE: the stamps tenant
  perform pg_temp.v809_tenant(bS,oS,brS,'Kopi');
  insert into public.business_programmes(business_id,kind,active,sort)
  values (bS,'stamps',true,3)
  on conflict (business_id,kind) do update set active=true;
  update public.business_programmes set active=false where business_id=bS and kind='points';
  select id into spineS from public.business_programmes where business_id=bS and kind='stamps';

  insert into public.loyalty_programs(business_id,active,loyalty_model,kind,
                                      configuration_status,stamp_target,stamp_per_cents)
  values (bS,true,'stamps','stamps','published',5,500)
  on conflict (business_id) do update
    set active=true, loyalty_model='stamps', kind='stamps',
        configuration_status='published', stamp_target=5, stamp_per_cents=500;
  perform pg_temp.v809_publish(bS,cfgS,oS,'stamps',5);
  update public.loyalty_programs set current_config_version_id=cfgS where business_id=bS;

  insert into public.clients(id,business_id,full_name,phone)
  values (phoned,bS,'V809 Phoned Customer','+65 9809 0001');
  -- The member-QR shape, exactly as staff_scan_member_qr_v327 provisions it: business and name.
  insert into public.clients(id,business_id,full_name)
  values (phoneless,bS,'V809 Peekaa Member');

  -- Eight stamps on a five-slot card: filled clamps to 5, carried is 3, the pot is 8. Three
  -- different numbers, so an assertion cannot pass by coincidence.
  perform pg_temp.v809_seed_stamps(bS,phoned,spineS,8);
  perform pg_temp.v809_seed_stamps(bS,phoneless,spineS,3);

  select * into v_sp from app.stamp_progress_v323(bS,phoned);
  if v_sp.slots is null or v_sp.slots <= 0 then
    raise exception 'FIXTURE: the stamps tenant has no card slots — the trap is not set';
  end if;
  if (select phone_norm from public.clients where id = phoneless) is not null then
    raise exception 'FIXTURE: the phoneless customer has a phone — F057 is not reproduced';
  end if;

  -- ============================================================ FIXTURE: the points tenant
  perform pg_temp.v809_tenant(bP,oP,brP,'Points');
  insert into public.loyalty_programs(business_id,active,loyalty_model,kind,
                                      configuration_status,earn_points_per_dollar,redeem_points)
  values (bP,true,'points_tiers','points','published',1,50)
  on conflict (business_id) do update
    set active=true, loyalty_model='points_tiers', kind='points',
        configuration_status='published';
  perform pg_temp.v809_publish(bP,cfgP,oP,'points',null);
  insert into public.clients(id,business_id,full_name,phone)
  values (clientP,bP,'V809 Points Customer','+65 9809 0002');

  -- ------------------------------------------------------------------ 1. one card authority
  select count(*) into v_count
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'app' and p.proname = 'till_stamp_card_v809';
  if v_count = 1 then
    insert into v809_out values (1,'exactly one app.till_stamp_card_v809 — one authority for the card','PASS');
  else
    insert into v809_out values (1,'exactly one app.till_stamp_card_v809 — one authority for the card',
      format('FAIL - %s found', v_count));
  end if;

  -- ------------------------------------------------------------------ 2. the QR card has one
  v_card := app.v666_till_customer_card(bS, phoned);
  if v_card ? 'stamp_card' and jsonb_typeof(v_card->'stamp_card') = 'object' then
    insert into v809_out values (2,'the QR customer card carries a stamp_card, so the till stops printing the pot','PASS');
  else
    insert into v809_out values (2,'the QR customer card carries a stamp_card, so the till stops printing the pot',
      format('FAIL - stamp_card=%s (points shown instead: %s)',
             coalesce(v_card->>'stamp_card','<absent>'), coalesce(v_card->>'points','<null>')));
  end if;

  -- ------------------------------------------------------------------ 3. both paths agree
  perform pg_temp.as_v809_user(oS);
  v_lookup := public.lookup_client_by_phone(bS, '98090001');
  perform pg_temp.as_v809_system();
  if coalesce(v_lookup->>'status','') <> 'found' then
    raise exception 'FIXTURE: the phone lookup did not find the customer (%)', v_lookup::text;
  end if;
  if (v_lookup::jsonb)->'stamp_card' = v_card->'stamp_card'
     and jsonb_typeof((v_lookup::jsonb)->'stamp_card') = 'object' then
    insert into v809_out values (3,'the scanned card and the typed-in card carry the IDENTICAL stamp card','PASS');
  else
    insert into v809_out values (3,'the scanned card and the typed-in card carry the IDENTICAL stamp card',
      format('FAIL - phone=%s qr=%s',
             coalesce(((v_lookup::jsonb)->'stamp_card')::text,'<absent>'),
             coalesce((v_card->'stamp_card')::text,'<absent>')));
  end if;

  -- ------------------------------------------------------------------ 4. and both agree with the RULE
  if (v_card->'stamp_card'->>'slots')::integer = v_sp.slots
     and (v_card->'stamp_card'->>'filled')::integer
         = least(greatest(coalesce(v_sp.filled,0),0), v_sp.slots)
     and (v_card->'stamp_card'->>'carried')::integer
         = greatest(coalesce(v_sp.filled,0) - v_sp.slots, 0)
     and (v_card->'stamp_card'->>'pot')::integer = v_sp.net_stamps
     and (v_card->'stamp_card'->>'ready')::boolean = v_sp.ready then
    insert into v809_out values (4,'both readers agree with app.stamp_progress_v323 itself, not merely with each other','PASS');
  else
    insert into v809_out values (4,'both readers agree with app.stamp_progress_v323 itself, not merely with each other',
      format('FAIL - card=%s rule slots=%s filled=%s pot=%s ready=%s',
             coalesce((v_card->'stamp_card')::text,'<absent>'),
             v_sp.slots, v_sp.filled, v_sp.net_stamps, v_sp.ready));
  end if;

  -- ------------------------------------------------------------------ 5. control: points tenant
  v_card := app.v666_till_customer_card(bP, clientP);
  perform pg_temp.as_v809_user(oP);
  v_lookup := public.lookup_client_by_phone(bP, '98090002');
  perform pg_temp.as_v809_system();
  if jsonb_typeof(v_card->'stamp_card') = 'null'
     and jsonb_typeof((v_lookup::jsonb)->'stamp_card') = 'null' then
    insert into v809_out values (5,'control: a points tenant gets stamp_card null on BOTH readers','PASS');
  else
    insert into v809_out values (5,'control: a points tenant gets stamp_card null on BOTH readers',
      format('FAIL - qr=%s phone=%s',
             coalesce((v_card->'stamp_card')::text,'<absent>'),
             coalesce(((v_lookup::jsonb)->'stamp_card')::text,'<absent>')));
  end if;

  -- ------------------------------------------------------------------ 6. one standing reader
  select count(*) into v_count
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'till_customer_standing_v809';
  if v_count = 1 then
    insert into v809_out values (6,'exactly one public.till_customer_standing_v809 (no PGRST203)','PASS');
  else
    insert into v809_out values (6,'exactly one public.till_customer_standing_v809 (no PGRST203)',
      format('FAIL - %s found', v_count));
  end if;

  -- ------------------------------------------------------------------ 7. it serves a phoneless customer
  perform pg_temp.as_v809_user(oS);
  /* Wrapped so a missing function records a FAIL row instead of aborting the suite: on pre-v809
     this call raises 42883 and the gate must still see all 15 assertions. */
  v_standing := null; v_err := null;
  begin
    v_standing := public.till_customer_standing_v809(bS, phoneless);
  exception when others then v_err := sqlstate;
  end;
  perform pg_temp.as_v809_system();
  select * into v_sp from app.stamp_progress_v323(bS,phoneless);
  if v_err is null and coalesce(v_standing->>'status','') = 'found'
     and (v_standing->>'client_id')::uuid = phoneless
     and v_standing->>'phone' is null
     and (v_standing->'stamp_card'->>'filled')::integer
         = least(greatest(coalesce(v_sp.filled,0),0), v_sp.slots) then
    insert into v809_out values (7,'the standing reader returns the full card for a customer with NO phone','PASS');
  else
    insert into v809_out values (7,'the standing reader returns the full card for a customer with NO phone',
      format('FAIL - sqlstate=%s standing=%s', coalesce(v_err,'<none>'),
             coalesce(v_standing::text,'<null>')));
  end if;

  -- ------------------------------------------------------------------ 8. and agrees with the phone path
  perform pg_temp.as_v809_user(oS);
  v_standing := null; v_err := null;
  begin
    v_standing := public.till_customer_standing_v809(bS, phoned);
  exception when others then v_err := sqlstate;
  end;
  v_lookup := public.lookup_client_by_phone(bS, '98090001');
  perform pg_temp.as_v809_system();
  if v_err is null and v_standing->'stamp_card' = (v_lookup::jsonb)->'stamp_card'
     and v_standing->>'points' = (v_lookup::jsonb)->>'points'
     and v_standing->>'credit_cents' = (v_lookup::jsonb)->>'credit_cents'
     and v_standing->>'visits' = (v_lookup::jsonb)->>'visits'
     and v_standing->>'can_redeem' = (v_lookup::jsonb)->>'can_redeem' then
    insert into v809_out values (8,'refreshing by client id and by phone report the same standing for one person','PASS');
  else
    insert into v809_out values (8,'refreshing by client id and by phone report the same standing for one person',
      format('FAIL - byid=%s byphone=%s', coalesce(v_standing::text,'<null>'), coalesce(v_lookup::text,'<null>')));
  end if;

  -- ------------------------------------------------------------------ 9. the gate still gates
  perform pg_temp.as_v809_user(outsider);
  v_err := null;
  begin
    perform public.till_customer_standing_v809(bS, phoned);
  exception when others then v_err := sqlstate;
  end;
  perform pg_temp.as_v809_system();
  if v_err = '42501' then
    insert into v809_out values (9,'somebody who is not a member of the business is refused the standing reader (42501)','PASS');
  else
    insert into v809_out values (9,'somebody who is not a member of the business is refused the standing reader (42501)',
      format('FAIL - sqlstate=%s', coalesce(v_err,'<none>')));
  end if;

  -- ============================================================ F105 fixture: one expense
  insert into public.expenses(business_id,branch_id,amount_cents,category,note,created_by)
  values (bS,brS,1234,'Supplies','duplicate of invoice #204, TBD',oS)
  returning id into v_expense;

  -- ------------------------------------------------------------------ 10. one expense RPC
  select count(*) into v_count
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'update_expense_v285';
  if v_count = 1 then
    insert into v809_out values (10,'exactly one public.update_expense_v285 after the recreate (no PGRST203)','PASS');
  else
    insert into v809_out values (10,'exactly one public.update_expense_v285 after the recreate (no PGRST203)',
      format('FAIL - %s overloads', v_count));
  end if;

  -- ------------------------------------------------------------------ 11. clearing works
  perform pg_temp.as_v809_user(oS);
  v_err := null;
  begin
    perform public.update_expense_v285(bS, v_expense, 1234, 'Supplies', null, true);
  exception when others then v_err := sqlstate;
  end;
  perform pg_temp.as_v809_system();
  select note into v_note from public.expenses where id = v_expense;
  if v_err is null and v_note is null then
    insert into v809_out values (11,'p_clear_note => true actually empties the note','PASS');
  else
    insert into v809_out values (11,'p_clear_note => true actually empties the note',
      format('FAIL - sqlstate=%s note=[%s]', coalesce(v_err,'<none>'), coalesce(v_note,'<null>')));
  end if;

  -- ------------------------------------------------------------------ 12. null alone is "unchanged"
  perform pg_temp.as_v809_system();
  update public.expenses set note = 'still relevant' where id = v_expense;
  perform pg_temp.as_v809_user(oS);
  -- The FIVE-argument call: still valid, and still means "leave the note alone".
  perform public.update_expense_v285(bS, v_expense, 4500, 'Supplies', null);
  perform pg_temp.as_v809_system();
  select note into v_note from public.expenses where id = v_expense;
  if v_note = 'still relevant'
     and (select amount_cents from public.expenses where id = v_expense) = 4500 then
    insert into v809_out values (12,'the five-argument call (p_note null, no flag) still leaves the note untouched','PASS');
  else
    insert into v809_out values (12,'the five-argument call (p_note null, no flag) still leaves the note untouched',
      format('FAIL - note=[%s]', coalesce(v_note,'<null>')));
  end if;

  -- ------------------------------------------------------------------ 13. a note is still written
  perform pg_temp.as_v809_user(oS);
  perform public.update_expense_v285(bS, v_expense, 5000, 'Utilities', '  corrected by the bookkeeper  ');
  perform pg_temp.as_v809_system();
  select note into v_note from public.expenses where id = v_expense;
  if v_note = 'corrected by the bookkeeper'
     and (select category from public.expenses where id = v_expense) = 'Utilities'
     and (select amount_cents from public.expenses where id = v_expense) = 5000 then
    insert into v809_out values (13,'a note, a category and an amount are still written together','PASS');
  else
    insert into v809_out values (13,'a note, a category and an amount are still written together',
      format('FAIL - note=[%s]', coalesce(v_note,'<null>')));
  end if;

  -- ------------------------------------------------------------------ 14. both at once is refused
  perform pg_temp.as_v809_user(oS);
  v_err := null;
  begin
    perform public.update_expense_v285(bS, v_expense, 5000, 'Utilities', 'a new note', true);
  exception when others then v_err := sqlstate;
  end;
  perform pg_temp.as_v809_system();
  select note into v_note from public.expenses where id = v_expense;
  if v_err = '22023' and v_note = 'corrected by the bookkeeper' then
    insert into v809_out values (14,'writing a note AND clearing is refused (22023), and the expense is untouched','PASS');
  else
    insert into v809_out values (14,'writing a note AND clearing is refused (22023), and the expense is untouched',
      format('FAIL - sqlstate=%s note=[%s]', coalesce(v_err,'<none>'), coalesce(v_note,'<null>')));
  end if;

  -- ------------------------------------------------------------------ 15. the finance guard still guards
  perform pg_temp.as_v809_user(outsider);
  v_err := null;
  begin
    perform public.update_expense_v285(bS, v_expense, 9900, 'Utilities', null, true);
  exception when others then v_err := sqlstate;
  end;
  perform pg_temp.as_v809_system();
  select note into v_note from public.expenses where id = v_expense;
  if v_err = '42501' and v_note = 'corrected by the bookkeeper' then
    insert into v809_out values (15,'a non-member still cannot correct or clear an expense (42501)','PASS');
  else
    insert into v809_out values (15,'a non-member still cannot correct or clear an expense (42501)',
      format('FAIL - sqlstate=%s note=[%s]', coalesce(v_err,'<none>'), coalesce(v_note,'<null>')));
  end if;
end
$v809_test$;

select seq, step, outcome from v809_out order by seq;

do $v809_gate$
declare v_bad integer; v_all integer;
begin
  select count(*) filter (where outcome not like 'PASS%'), count(*) into v_bad, v_all from v809_out;
  if v_all <> 15 then
    raise exception 'nestly_v809: % of 15 assertions ran — the suite aborted early', v_all;
  end if;
  if v_bad > 0 then
    raise exception 'nestly_v809: % assertion(s) FAILED: %', v_bad,
      (select string_agg(seq || ' ' || step || ' => ' || outcome, ' || ')
         from v809_out where outcome not like 'PASS%');
  end if;
end
$v809_gate$;

rollback;
