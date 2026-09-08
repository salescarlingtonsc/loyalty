-- EXECUTED acceptance fixture for nestly_v848
-- (db/migrations/20261008_nestly_v848_reversal_returns_the_voucher_and_the_books.sql).
--
-- Run: LC_ALL=C node scripts/db-tests/run.mjs --migrated-only --filter=v848
--
-- WHY THIS EXISTS. public.welcome_offer_grants_v215 stores the sale that QUALIFIED an offer
-- (qualifying_sale_id — the purchase that met min_spend_cents) apart from the $0 sale that
-- FULFILLED it (redeemed_sale_id). public.reverse_sale already undid every other loyalty
-- consequence of voiding a sale — points clawback, source batches, referral grants, the
-- referral qualification itself — but had no hook into welcome offers. Proven against
-- production on 2026-09-08 in a rolled-back probe: after reversing the $9.00 qualifying sale
-- the grant still read
--   {"status":"redeemed","redeemed_sale_id":"494d68be-…","qualifying_sale_id":"03cc33c4-…"}
-- and grants_still_claimable was 0. The customer's money came back; the free item they had
-- bought with it did not.
--
-- Nothing here is simulated. The tenant is built the way a real one is, the sale goes through
-- public.record_sale_by_phone (the till's own RPC), the redemption through
-- public.staff_redeem_welcome_offer_v215, the reversal through public.reverse_sale, and the
-- staff-side gift reversal through public.staff_reverse_gift_redemption_v665 — every one of them
-- called as an authenticated principal with a real role.
--
-- ASSERTIONS (rows, with a fatal gate at the end):
--   T1  FIXTURE/BEFORE — the redemption really binds the grant to the qualifying sale.
--   T2  THE FIX — after public.reverse_sale voids that qualifying sale the grant is back to
--       'granted' with all six redemption columns cleared. This is the assertion that fails
--       without nestly_v848; before it, the grant stayed 'redeemed'.
--   T3  grants_still_claimable = 1 — the exact number the production probe measured as 0.
--   T4  The return is audited exactly once as WELCOME_OFFER_RETURNED_ON_SALE_REVERSAL_V848, and
--       the audit row names the customer, the qualifying sale and the fulfilment sale.
--   T5  public.reverse_sale reports welcome_offers_returned = 1.
--   T6  IDEMPOTENCY — replaying the identical reversal returns welcome_offers_returned = 0,
--       leaves exactly one claimable grant and writes no second audit row.
--   T7  IDEMPOTENCY, the dangerous one — the customer re-claims the returned voucher against a
--       NEW qualifying sale, and a replay of the FIRST reversal does not take it away from that
--       new sale or hand it back a second time.
--   T8  ORDERING HAZARD — when staff already undid the gift by hand through
--       public.staff_reverse_gift_redemption_v665, reversing the qualifying sale afterwards
--       returns nothing (welcome_offers_returned = 0), leaves exactly one claimable grant, and
--       writes no audit row. A voucher independently reversed is not resurrected twice.
--   T9  NO WIDENED PERMISSION — a 'staff' member (create_sales, no refund_sales) is still
--       refused by public.reverse_sale, and the refusal leaves the grant redeemed.
--   T10 v480's own behaviour is untouched — the same call still reports reversed_cents = 900
--       and still carries its loyalty/referral result keys.
--   T11 OPEN BLOCKER, PINNED NOT FIXED — public.staff_reverse_gift_redemption_v665 still leaves
--       the $0 fulfilment sale on the books, and that sale cannot be retired at all:
--       public.reverse_sale refuses it with 'zero-dollar sale has no package session
--       provenance' (public.reverse_sale_v34_base), and the underlying fence is
--       app.enforce_sale_reversal_bounds' 'zero-dollar reversal requires exact package session
--       provenance'. Closing it needs a new provenance table plus a widened bounds guard on the
--       money path — neither owned by nestly_v848. THIS TEST IS A TRIPWIRE: if it starts
--       failing because the fulfilment sale now carries a reversal, the blocker has been closed
--       elsewhere and this assertion must be rewritten to assert the new behaviour.
--
-- Everything is inside one transaction that rolls back.

begin;

create temporary table v848_out(seq int, step text, outcome text, detail text) on commit drop;

create function pg_temp.v848_note(p_seq int, p_step text, p_ok boolean, p_detail text)
returns void language sql as $$
  insert into v848_out(seq, step, outcome, detail)
  values (p_seq, p_step, case when p_ok then 'PASS' else 'FAIL' end, p_detail);
$$;

do $v848_test$
declare
  v_business uuid := gen_random_uuid();
  v_owner    uuid := gen_random_uuid();
  v_junior   uuid := gen_random_uuid();
  v_branch   uuid := gen_random_uuid();
  v_c1       uuid := gen_random_uuid();
  v_c2       uuid := gen_random_uuid();
  v_c3       uuid := gen_random_uuid();
  v_p1       text := '8186' || lpad((floor(random()*10000))::text, 4, '0');
  v_p2       text := '8187' || lpad((floor(random()*10000))::text, 4, '0');
  v_p3       text := '8188' || lpad((floor(random()*10000))::text, 4, '0');
  v_slug     text := 'v848-acceptance-' || substr(gen_random_uuid()::text, 1, 8);
  v_g1 uuid; v_g2 uuid; v_g3 uuid;
  v_s1 uuid; v_s2 uuid; v_s3 uuid; v_s4 uuid;
  v_fulfil1 uuid; v_fulfil2 uuid;
  v_key1 text := 'v848rev1-' || replace(gen_random_uuid()::text, '-', '');
  v_res jsonb; v_j json; v_row jsonb;
  v_n integer; v_err text; v_state text;
begin
  -- ------------------------------------------------------------------ SECTION 0 · the tenant
  insert into auth.users(instance_id,id,aud,role,email,encrypted_password,
                         email_confirmed_at,created_at,updated_at)
  values ('00000000-0000-0000-0000-000000000000',v_owner,'authenticated','authenticated',
          'v848-owner-'||substr(v_owner::text,1,8)||'@example.test','',now(),now(),now()),
         ('00000000-0000-0000-0000-000000000000',v_junior,'authenticated','authenticated',
          'v848-staff-'||substr(v_junior::text,1,8)||'@example.test','',now(),now(),now());

  insert into public.businesses(id,name,slug,industry,enabled_modules,points_mode)
  values (v_business,'V848 Acceptance',v_slug,'fnb',
          array['dashboard','clients','sales','loyalty','till'],'redeem');
  insert into public.staff(business_id,user_id,role,full_name,active,access_state)
  values (v_business,v_owner,'owner','V848 Owner',true,'approved'),
         (v_business,v_junior,'staff','V848 Junior',true,'approved');
  insert into public.branches(id,business_id,name,is_default,active)
  values (v_branch,v_business,'V848 Main',true,true);
  insert into public.staff_branches(business_id,staff_id,branch_id)
  select v_business, s.id, v_branch from public.staff s where s.business_id=v_business;

  update public.business_workspace_controls_v94
     set approval_status='approved', version=version+1, decided_by=v_owner,
         decided_at=now(), decision_reason='v848 acceptance fixture', updated_at=now()
   where business_id = v_business;
  update public.business_subscription_lifecycle_v94
     set workspace_paused=false where business_id = v_business;
  insert into public.subscriptions(business_id) values (v_business) on conflict do nothing;

  perform set_config('request.jwt.claims',
    json_build_object('sub', v_owner, 'role', 'authenticated')::text, true);

  -- A welcome offer that costs the customer a $5.00 minimum spend to claim.
  perform public.business_set_welcome_offer_v215(
    v_business, true, 500, 'custom', null, null, 'V848 Free Soyabean');

  insert into public.clients(id,business_id,full_name,phone)
  values (v_c1,v_business,'V848 Customer One',v_p1),
         (v_c2,v_business,'V848 Customer Two',v_p2),
         (v_c3,v_business,'V848 Customer Three',v_p3);
  perform app.issue_welcome_offer_v215(v_business, v_c1);
  perform app.issue_welcome_offer_v215(v_business, v_c2);
  perform app.issue_welcome_offer_v215(v_business, v_c3);
  select id into v_g1 from public.welcome_offer_grants_v215 where business_id=v_business and client_id=v_c1;
  select id into v_g2 from public.welcome_offer_grants_v215 where business_id=v_business and client_id=v_c2;
  select id into v_g3 from public.welcome_offer_grants_v215 where business_id=v_business and client_id=v_c3;
  if v_g1 is null or v_g2 is null or v_g3 is null then
    raise exception 'FIXTURE: welcome offer grants were not issued (%/%/%)', v_g1, v_g2, v_g3;
  end if;

  -- ------------------------------------------------------------------ T1 · before
  v_j := public.record_sale_by_phone(v_business, v_p1, 900, 'quick_sale',
           'v848 qualifying sale', null,
           'v848q1-'||replace(gen_random_uuid()::text,'-',''), v_branch, 'cash', null);
  v_s1 := (v_j->>'sale_id')::uuid;
  if v_s1 is null then raise exception 'FIXTURE: the till refused the qualifying sale (%)', v_j::text; end if;

  v_res := public.staff_redeem_welcome_offer_v215(v_business, v_c1, v_branch, v_s1,
             'v848rd1-'||replace(gen_random_uuid()::text,'-',''));
  v_fulfil1 := (v_res->>'sale_id')::uuid;

  select jsonb_build_object('status',g.status,'qualifying_sale_id',g.qualifying_sale_id,
           'redeemed_sale_id',g.redeemed_sale_id) into v_row
    from public.welcome_offer_grants_v215 g where g.id = v_g1;
  perform pg_temp.v848_note(1, 'T1 redemption binds the grant to the qualifying sale',
    (v_row->>'status') = 'redeemed'
      and (v_row->>'qualifying_sale_id')::uuid = v_s1
      and (v_row->>'redeemed_sale_id')::uuid = v_fulfil1,
    v_row::text);

  -- ------------------------------------------------------------------ T2-T5, T10 · the fix
  v_j := public.reverse_sale(v_business, v_s1, 'v848 acceptance reversal of qualifying sale',
           v_key1, 'v848 acceptance', 'none');

  select jsonb_build_object('status',g.status,'qualifying_sale_id',g.qualifying_sale_id,
           'redeemed_sale_id',g.redeemed_sale_id,'redeemed_at',g.redeemed_at,
           'redeemed_by',g.redeemed_by,'redeem_idempotency_key',g.redeem_idempotency_key)
    into v_row from public.welcome_offer_grants_v215 g where g.id = v_g1;
  perform pg_temp.v848_note(2, 'T2 voiding the qualifying sale returns the voucher to granted',
    (v_row->>'status') = 'granted'
      and v_row->>'qualifying_sale_id' is null
      and v_row->>'redeemed_sale_id' is null
      and v_row->>'redeemed_at' is null
      and v_row->>'redeemed_by' is null
      and v_row->>'redeem_idempotency_key' is null,
    v_row::text);

  select count(*) into v_n from public.welcome_offer_grants_v215 g
   where g.business_id=v_business and g.client_id=v_c1 and g.status='granted';
  perform pg_temp.v848_note(3, 'T3 grants_still_claimable is 1 (the production probe measured 0)',
    v_n = 1, 'grants_still_claimable=' || v_n);

  select count(*) into v_n from public.audit_log a
   where a.business_id=v_business
     and a.action='WELCOME_OFFER_RETURNED_ON_SALE_REVERSAL_V848'
     and a.entity_id=v_g1
     and (a.detail->>'client_id')::uuid = v_c1
     and (a.detail->>'qualifying_sale_id')::uuid = v_s1
     and (a.detail->>'fulfilment_sale_id')::uuid = v_fulfil1;
  perform pg_temp.v848_note(4, 'T4 the return is audited once and names customer, qualifying and fulfilment sale',
    v_n = 1, 'matching audit rows=' || v_n);

  perform pg_temp.v848_note(5, 'T5 reverse_sale reports welcome_offers_returned = 1',
    (v_j::jsonb->>'welcome_offers_returned') = '1',
    'welcome_offers_returned=' || coalesce(v_j::jsonb->>'welcome_offers_returned','(absent)'));

  perform pg_temp.v848_note(10, 'T10 v480''s own reversal behaviour is untouched',
    (v_j::jsonb->>'reversed_cents') = '900'
      and v_j::jsonb ? 'loyalty_clawed_back'
      and v_j::jsonb ? 'referral_grants_reversed'
      and v_j::jsonb ? 'operation_id',
    'reversed_cents=' || coalesce(v_j::jsonb->>'reversed_cents','(absent)')
      || ' loyalty_clawed_back=' || coalesce(v_j::jsonb->>'loyalty_clawed_back','(absent)'));

  -- ------------------------------------------------------------------ T6 · replay
  v_j := public.reverse_sale(v_business, v_s1, 'v848 acceptance reversal of qualifying sale',
           v_key1, 'v848 acceptance', 'none');
  select count(*) into v_n from public.welcome_offer_grants_v215 g
   where g.business_id=v_business and g.client_id=v_c1 and g.status='granted';
  perform pg_temp.v848_note(6, 'T6 an identical replay returns nothing a second time',
    (v_j::jsonb->>'replayed') = 'true'
      and (v_j::jsonb->>'welcome_offers_returned') = '0'
      and v_n = 1
      and (select count(*) from public.audit_log a
            where a.business_id=v_business
              and a.action='WELCOME_OFFER_RETURNED_ON_SALE_REVERSAL_V848') = 1,
    'replayed=' || coalesce(v_j::jsonb->>'replayed','(absent)')
      || ' returned=' || coalesce(v_j::jsonb->>'welcome_offers_returned','(absent)')
      || ' claimable=' || v_n);

  -- ------------------------------------------------------------------ T7 · re-claimed, then replayed
  v_j := public.record_sale_by_phone(v_business, v_p1, 900, 'quick_sale',
           'v848 second qualifying sale', null,
           'v848q2-'||replace(gen_random_uuid()::text,'-',''), v_branch, 'cash', null);
  v_s2 := (v_j->>'sale_id')::uuid;
  -- Guarded: without nestly_v848 the voucher was never returned, so this re-claim raises
  -- 'welcome_offer_already_redeemed'. That is itself the defect, and it must be reported as a
  -- FAIL row rather than aborting the file before the gate can count the other failures.
  begin
    v_res := public.staff_redeem_welcome_offer_v215(v_business, v_c1, v_branch, v_s2,
               'v848rd2-'||replace(gen_random_uuid()::text,'-',''));
    v_j := public.reverse_sale(v_business, v_s1, 'v848 acceptance reversal of qualifying sale',
             v_key1, 'v848 acceptance', 'none');
    select jsonb_build_object('status',g.status,'qualifying_sale_id',g.qualifying_sale_id) into v_row
      from public.welcome_offer_grants_v215 g where g.id = v_g1;
    perform pg_temp.v848_note(7, 'T7 a replay does not take back a voucher re-claimed against a later sale',
      (v_row->>'status') = 'redeemed'
        and (v_row->>'qualifying_sale_id')::uuid = v_s2
        and (v_j::jsonb->>'welcome_offers_returned') = '0'
        and (select count(*) from public.audit_log a
              where a.business_id=v_business
                and a.action='WELCOME_OFFER_RETURNED_ON_SALE_REVERSAL_V848') = 1,
      v_row::text || ' returned=' || coalesce(v_j::jsonb->>'welcome_offers_returned','(absent)'));
  exception when others then
    get stacked diagnostics v_err = message_text, v_state = returned_sqlstate;
    perform pg_temp.v848_note(7, 'T7 a replay does not take back a voucher re-claimed against a later sale',
      false, 'the customer could not re-claim the returned voucher at all: ' || v_state || ' ' || v_err);
  end;

  -- ------------------------------------------------------------------ T8 · ordering hazard
  v_j := public.record_sale_by_phone(v_business, v_p2, 900, 'quick_sale',
           'v848 customer two qualifying sale', null,
           'v848q3-'||replace(gen_random_uuid()::text,'-',''), v_branch, 'cash', null);
  v_s3 := (v_j->>'sale_id')::uuid;
  v_res := public.staff_redeem_welcome_offer_v215(v_business, v_c2, v_branch, v_s3,
             'v848rd3-'||replace(gen_random_uuid()::text,'-',''));
  v_fulfil2 := (v_res->>'sale_id')::uuid;

  -- staff undo the gift by hand FIRST
  v_res := public.staff_reverse_gift_redemption_v665(v_business,'welcome',v_g2,
             'v848 acceptance staff-side gift reversal', gen_random_uuid());
  -- ...and only then is the qualifying sale voided
  v_j := public.reverse_sale(v_business, v_s3, 'v848 acceptance reversal after a staff gift reversal',
           'v848rev3-'||replace(gen_random_uuid()::text,'-',''), 'v848 acceptance', 'none');
  select count(*) into v_n from public.welcome_offer_grants_v215 g
   where g.business_id=v_business and g.client_id=v_c2 and g.status='granted';
  perform pg_temp.v848_note(8, 'T8 a voucher already reversed by staff is not resurrected twice',
    (v_j::jsonb->>'welcome_offers_returned') = '0'
      and v_n = 1
      and (select count(*) from public.audit_log a
            where a.business_id=v_business
              and a.action='WELCOME_OFFER_RETURNED_ON_SALE_REVERSAL_V848'
              and a.entity_id=v_g2) = 0,
    'returned=' || coalesce(v_j::jsonb->>'welcome_offers_returned','(absent)')
      || ' claimable=' || v_n);

  -- ------------------------------------------------------------------ T9 · no widened permission
  v_j := public.record_sale_by_phone(v_business, v_p3, 900, 'quick_sale',
           'v848 customer three qualifying sale', null,
           'v848q4-'||replace(gen_random_uuid()::text,'-',''), v_branch, 'cash', null);
  v_s4 := (v_j->>'sale_id')::uuid;
  v_res := public.staff_redeem_welcome_offer_v215(v_business, v_c3, v_branch, v_s4,
             'v848rd4-'||replace(gen_random_uuid()::text,'-',''));

  perform set_config('request.jwt.claims',
    json_build_object('sub', v_junior, 'role', 'authenticated')::text, true);
  begin
    v_j := public.reverse_sale(v_business, v_s4, 'v848 acceptance unauthorised reversal attempt',
             'v848rev4-'||replace(gen_random_uuid()::text,'-',''), 'v848 acceptance', 'none');
    v_err := '(no refusal -- reverse_sale ACCEPTED a staff member without refund_sales)';
    v_state := 'none';
  exception when others then
    get stacked diagnostics v_err = message_text, v_state = returned_sqlstate;
  end;
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_owner, 'role', 'authenticated')::text, true);
  select jsonb_build_object('status',g.status,'qualifying_sale_id',g.qualifying_sale_id) into v_row
    from public.welcome_offer_grants_v215 g where g.id = v_g3;
  perform pg_temp.v848_note(9, 'T9 a staff member without refund_sales is still refused, and the grant is untouched',
    v_state = '42501'
      and (v_row->>'status') = 'redeemed'
      and (v_row->>'qualifying_sale_id')::uuid = v_s4,
    v_state || ' ' || v_err || ' / grant ' || v_row::text);

  -- ------------------------------------------------------------------ T11 · the open blocker, pinned
  select jsonb_build_object('id',s.id,'note',s.note,'amount_cents',s.amount_cents,
           'reversal_of',s.reversal_of,
           'has_reversal_row',exists(select 1 from public.sales r where r.reversal_of = s.id),
           'reward_fulfilment_lines',(select count(*) from public.sale_items si
              where si.sale_id = s.id and si.item_type = 'reward_fulfilment')) into v_row
    from public.sales s where s.id = v_fulfil2;
  begin
    v_j := public.reverse_sale(v_business, v_fulfil2, 'v848 acceptance retire the fulfilment sale',
             'v848rev5-'||replace(gen_random_uuid()::text,'-',''), 'v848 acceptance', 'none');
    v_err := '(no refusal)';
    v_state := 'none';
  exception when others then
    get stacked diagnostics v_err = message_text, v_state = returned_sqlstate;
  end;
  perform pg_temp.v848_note(11,
    'T11 OPEN BLOCKER: the $0 fulfilment sale survives a staff gift reversal and cannot be retired',
    v_row->>'reversal_of' is null
      and (v_row->>'has_reversal_row') = 'false'
      and (v_row->>'amount_cents') = '0'
      and (v_row->>'reward_fulfilment_lines') = '1'
      and v_err = 'zero-dollar sale has no package session provenance',
    v_row::text || ' / reverse_sale said: ' || v_state || ' ' || v_err);
end
$v848_test$;

select seq, step, outcome, detail from v848_out order by seq;

do $gate$
declare v_failed integer;
begin
  select count(*) into v_failed from v848_out where outcome <> 'PASS';
  if v_failed > 0 then
    raise exception 'nestly_v848 acceptance: % assertion(s) FAILED', v_failed;
  end if;
end
$gate$;

rollback;
