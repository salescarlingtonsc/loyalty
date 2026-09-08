-- NESTLY v848 — voiding a sale gives the customer back the voucher that sale paid for.
--
-- WHAT WENT WRONG. public.welcome_offer_grants_v215 records, on redemption, the sale that
-- QUALIFIED the offer (qualifying_sale_id — the customer's $9.00 purchase that met
-- min_spend_cents) separately from the $0 sale that FULFILLED it (redeemed_sale_id — the
-- "welcome offer redeemed: Free Soyabean" row). public.reverse_sale already knows how to undo
-- the loyalty consequences of voiding the qualifying sale: it claws points back, zeroes the
-- source batches, reverses referral grants through app.referral_value_provenance_v480 and puts
-- a rewarded referral back to 'pending'. It has no hook whatsoever into welcome offers.
--
-- REPRODUCED against production on 2026-09-08 inside one begin/rollback probe: a welcome offer
-- with min_spend_cents = 500 was granted, a $9.00 till sale recorded through
-- public.record_sale_by_phone, the offer redeemed against it, and then that qualifying sale
-- reversed through public.reverse_sale. The reversal reported
--   {"reversed_cents":900,"refunded_payment_cents":900,"loyalty_clawed_back":0,"replayed":false}
-- and wrote its reversal row, and the grant was left reading
--   {"status":"redeemed","redeemed_at":"2026-09-08T16:23:57.424846+00:00",
--    "redeemed_sale_id":"494d68be-…","qualifying_sale_id":"03cc33c4-…"}
-- with grants_still_claimable = 0, while sale 03cc33c4-… now carried a reversal row. The
-- customer paid $9.00, the shop gave the $9.00 back, and the customer silently lost the free
-- item they had bought with it. The grant also went on pointing at a voided sale, so
-- welcome_offer_grants_v215 disagreed with public.sales about whether that purchase happened.
--
-- WHAT THIS MIGRATION DOES. public.reverse_sale — today a one-line LANGUAGE sql wrapper around
-- app.reverse_sale_with_loyalty_v480(…, false) — becomes a LANGUAGE plpgsql function that calls
-- exactly that same expression, unchanged, and then returns any welcome offer whose
-- qualifying_sale_id is the sale just voided to 'granted'. The reset is the same single
-- statement public.staff_reverse_gift_redemption_v665 already uses (status, redeemed_at,
-- redeemed_sale_id, redeemed_by, qualifying_sale_id, redeem_idempotency_key in one UPDATE),
-- because welcome_offer_grants_v215_redeem_shape refuses every half-way state — that CHECK is
-- the protection, not an obstacle, and it is left exactly as it is.
--
-- IDEMPOTENCY — "reversing twice must not return the voucher twice". Three independent locks,
-- and the migration relies on all three rather than on any one of them:
--   (1) the UPDATE predicate is `status = 'redeemed' AND qualifying_sale_id = p_sale`, so a
--       grant already returned (status 'granted', qualifying_sale_id NULL) can never match;
--   (2) app.sale_loyalty_reversal_operations_v480 makes an exact replay of the same
--       (business, idempotency_key) return the stored result before any state transition, so a
--       replayed call reaches the loop with nothing left to do;
--   (3) the grant can never come to point at this sale again: public.staff_redeem_welcome_offer_v215
--       accepts a qualifying sale only `where sale.reversal_of is null and not exists (select 1
--       from public.sales reversal where reversal.reversal_of = sale.id)`, and this sale now has
--       a reversal row.
--   The audit row is written only when the UPDATE actually matched (GET DIAGNOSTICS), so a
--   second call audits nothing either.
--
-- THE ORDERING HAZARD, deliberately handled. If a staff member had already undone the gift
-- through public.staff_reverse_gift_redemption_v665, that function set status='granted' AND
-- qualifying_sale_id=NULL — so the predicate skips it and the voucher is not resurrected a
-- second time. The `FOR UPDATE` on the grant serialises the two paths in either order: whoever
-- commits second sees a grant that no longer matches its predicate (v665 raises
-- 'gift_reversal_target_not_found'; this path is a no-op).
--
-- WHY 'granted' AND NOT A NEW STATUS. welcome_offer_grants_v215_status_check allows exactly
-- granted | redeemed | expired, and v665 — the only other path that un-redeems a welcome offer —
-- returns it to 'granted'. An expired grant returned to 'granted' is caught on the next redeem
-- attempt by staff_redeem_welcome_offer_v215's own expires_at check, which flips it to
-- 'expired'. Same behaviour as v665; no new state, no widened allowlist.
--
-- WHAT THIS MIGRATION DOES NOT TOUCH.
--   * app.reverse_sale_with_loyalty_v480 — called with the identical seven arguments, including
--     the literal `false` for p_accept_shortfall. Every permission check, provenance fence,
--     lock, shortfall rule and evidence row inside it is untouched, and none is bypassed: the
--     voucher return happens strictly AFTER it returns, so any refusal it raises aborts the
--     whole statement and the grant is never touched.
--   * refund_sales. public.reverse_sale gains no permission check of its own and loses none;
--     authorisation stays exactly where it is, in app.reverse_sale_with_loyalty_v480 →
--     public.reverse_sale_v480_base / v40_base / v34_base / v20_base.
--   * public.staff_reverse_gift_redemption_v665, public.staff_redeem_welcome_offer_v215,
--     public.welcome_offer_grants_v215 (columns, constraints, indexes, RLS), public.sales and
--     every guard on it.
--
-- ============================================================================================
-- TWO OPEN BLOCKERS, REPORTED NOT HALF-FIXED. Both need functions outside this change's
-- ownership; neither is closed by widening a guard from here.
--
-- BLOCKER 1 — the shortfall entry points still do not return the voucher.
--   public.refund_sale and public.reverse_sale_fast_v84 both call public.reverse_sale and so
--   inherit this fix. The two owner-override entry points,
--   public.reverse_sale_accept_loyalty_shortfall_v480 and
--   public.reverse_sale_fast_accept_loyalty_shortfall_v480, call
--   app.reverse_sale_with_loyalty_v480(…, true) DIRECTLY and still do not. Closing that means
--   moving this block into app.reverse_sale_with_loyalty_v480 itself — which is where it
--   belongs, and which this change does not own. Duplicating the block into two more functions
--   this change does not own would be worse than reporting it.
--
-- BLOCKER 2 — the $0 fulfilment sale of a reversed gift cannot be retired at all.
--   public.staff_reverse_gift_redemption_v665 restores a welcome / bring-back / referral grant
--   to 'granted' but leaves the $0 sale that recorded the hand-over on the books, with a
--   sale_items line item_type='reward_fulfilment'. Redeem again and the item is recorded as
--   handed over twice. Four routes to retire it were tried against production on 2026-09-08 in
--   a rolled-back probe, and every one of them is refused by a guard this change must not
--   weaken:
--     * public.reverse_sale on the fulfilment sale
--         → P0001 "zero-dollar sale has no package session provenance"
--           (public.reverse_sale_v34_base: a $0 sale is reversible only as a package session)
--     * a hand-written compensating row, exactly the shape reverse_sale_v34_base builds, with
--       app.sale_reversal_insert_id / app.sale_reversal_original_id set
--         → 42501 "zero-dollar reversal requires exact package session provenance"
--           (app.enforce_sale_reversal_bounds)
--     * a plain UPDATE marking the row
--         → 23001 "sales is append-only: UPDATE is not permitted"  (app.sales_immutable_guard)
--     * an UPDATE inside the app.sales_backfill window
--         → 23001 "backfill window … may not change economic facts, attribution, snapshots, or
--           reversal metadata"
--   So the house pattern for retiring a $0 sale is a compensating row PLUS a provenance table
--   the bounds guard admits — which is exactly what public.package_session_reversals is. Doing
--   the same for gift fulfilment means a new provenance table and a widened
--   app.enforce_sale_reversal_bounds. That guard sits on the money path and is not owned here.
--   nestly_v665's own header records the omission as deliberate for that reason ("loosening a
--   guard on the money path to tidy a $0 row would be a far worse trade"), so this is a
--   standing design decision to reopen with its owner, not an oversight to patch.
--   The same shape applies to all three gift kinds: public.staff_redeem_bringback_v361 and
--   public.staff_redeem_referral_v420 write the identical $0 sale + 'reward_fulfilment' line
--   (read from production with pg_get_functiondef), and v665's bringback / referral branches
--   update only the grant. 'tier_perk' writes no sale at all, so it is unaffected.
--   Assertion T11 of the acceptance suite pins this gap so it cannot be mistaken for a fix.
-- ============================================================================================
--
-- ACCEPTANCE: db/tests/v848_reversal_returns_the_voucher_and_the_books.sql (and the identical
-- db/tests/executed/ copy). Replay:
--   LC_ALL=C node scripts/db-tests/run.mjs --migrated-only --filter=v848

begin;

set local search_path = pg_catalog, public, app, pg_temp;

-- ============================================================================================
-- 1 · PRE-FLIGHT — the live wrapper is the one this migration was written against.
-- ============================================================================================
do $v848_pre$
declare
  v_def text;
  v_body text;
  v_n integer;
begin
  select pg_get_functiondef(p.oid) into v_def
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'reverse_sale'
     and pg_get_function_identity_arguments(p.oid) = 'p_business uuid, p_sale uuid, p_reason text, p_idempotency_key text, p_reference text, p_restock_policy text';
  if v_def is null then
    raise exception 'v848: public.reverse_sale(uuid,uuid,text,text,text,text) is not present';
  end if;

  /* It is still the thin LANGUAGE sql wrapper, and it still delegates to v480 with
     p_accept_shortfall = false.  If somebody has already given it a body of its own, this
     migration would silently throw that work away. */
  select count(*) into v_n from regexp_matches(v_def, '\n LANGUAGE sql\n', 'g');
  if v_n <> 1 then
    raise exception 'v848: public.reverse_sale is no longer the LANGUAGE sql wrapper (found % '
      'declarations) -- production has drifted; re-read pg_get_functiondef before replacing it', v_n;
  end if;
  select count(*) into v_n from regexp_matches(
    v_def, 'select app\.reverse_sale_with_loyalty_v480\(\$1,\$2,\$3,\$4,\$5,\$6,false\)', 'g');
  if v_n <> 1 then
    raise exception 'v848: the live public.reverse_sale body does not delegate to '
      'app.reverse_sale_with_loyalty_v480($1..$6,false) exactly once (found %) -- production has drifted', v_n;
  end if;
  select count(*) into v_n from regexp_matches(v_def, 'SECURITY DEFINER', 'g');
  if v_n <> 1 then
    raise exception 'v848: public.reverse_sale is not SECURITY DEFINER -- the replacement below '
      'would change how it runs';
  end if;

  /* The delegate itself, with the exact seven-argument signature carried forward. */
  if to_regprocedure('app.reverse_sale_with_loyalty_v480(uuid,uuid,text,text,text,text,boolean)') is null then
    raise exception 'v848: app.reverse_sale_with_loyalty_v480(uuid,uuid,text,text,text,text,boolean) is not present '
      '-- nestly_v480 must be applied first';
  end if;

  /* The grant table this migration writes: the nine columns it reads and writes, and the CHECK
     that makes the reset have to be one statement. */
  select count(*) into v_n
    from information_schema.columns
   where table_schema = 'public' and table_name = 'welcome_offer_grants_v215'
     and column_name in ('status','redeemed_at','redeemed_sale_id','redeemed_by',
                         'qualifying_sale_id','redeem_idempotency_key','business_id','client_id','reward_label');
  if v_n <> 9 then
    raise exception 'v848: public.welcome_offer_grants_v215 does not carry the 9 columns this '
      'migration reads and writes (found %)', v_n;
  end if;
  if not exists (
    select 1 from pg_constraint
     where conrelid = 'public.welcome_offer_grants_v215'::regclass
       and conname = 'welcome_offer_grants_v215_redeem_shape') then
    raise exception 'v848: welcome_offer_grants_v215_redeem_shape is gone -- the one-statement '
      'reset this migration performs is no longer protected by it';
  end if;
  if not exists (
    select 1 from pg_constraint
     where conrelid = 'public.welcome_offer_grants_v215'::regclass
       and conname = 'welcome_offer_grants_v215_status_check'
       and pg_get_constraintdef(oid) like '%''granted''%') then
    raise exception 'v848: welcome_offer_grants_v215_status_check no longer allows ''granted'' -- '
      'the status this migration returns a voucher to';
  end if;

  /* The idempotency guarantee leans on the redeemer refusing a reversed sale as a qualifying
     sale.  If that clause has gone, the third lock described in the header is not real. */
  select pg_get_functiondef(p.oid) into v_body
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'staff_redeem_welcome_offer_v215';
  if v_body is null then
    raise exception 'v848: public.staff_redeem_welcome_offer_v215 is not present';
  end if;
  select count(*) into v_n from regexp_matches(v_body, 'sale\.reversal_of is null', 'g');
  if v_n <> 1 then
    raise exception 'v848: public.staff_redeem_welcome_offer_v215 no longer refuses a reversed '
      'sale as a qualifying sale (found % occurrences of the clause) -- v848''s idempotency '
      'argument depends on it', v_n;
  end if;
  select count(*) into v_n from regexp_matches(v_body, 'where reversal\.reversal_of = sale\.id', 'g');
  if v_n <> 1 then
    raise exception 'v848: public.staff_redeem_welcome_offer_v215 no longer refuses an '
      'already-reversed qualifying sale (found % occurrences) -- v848''s idempotency argument '
      'depends on it', v_n;
  end if;

  /* The reset statement this migration copies from v665, still shaped the way it is copied.
     The trailing comma is what makes this the welcome branch and not the bring-back one. */
  select pg_get_functiondef(p.oid) into v_body
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'staff_reverse_gift_redemption_v665';
  if v_body is null then
    raise exception 'v848: public.staff_reverse_gift_redemption_v665 is not present '
      '-- nestly_v665 must be applied first';
  end if;
  select count(*) into v_n from regexp_matches(v_body,
    'set status = ''granted'', redeemed_at = null, redeemed_sale_id = null, redeemed_by = null,\n *qualifying_sale_id = null, redeem_idempotency_key = null', 'g');
  if v_n <> 1 then
    raise exception 'v848: public.staff_reverse_gift_redemption_v665 no longer performs the '
      'six-column welcome-offer reset this migration mirrors exactly once (found %) -- the two '
      'paths would diverge', v_n;
  end if;

  /* BLOCKER 2 is pinned by the acceptance suite on the exact wording of these two refusals.
     Assert here that both still say what the suite expects, so a drifted guard shows up as a
     refusal to apply rather than as a mystifying test failure. */
  select pg_get_functiondef(p.oid) into v_body
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'reverse_sale_v34_base';
  if v_body is null
     or position('zero-dollar sale has no package session provenance' in v_body) = 0 then
    raise exception 'v848: public.reverse_sale_v34_base no longer refuses a $0 sale with '
      '"zero-dollar sale has no package session provenance" -- BLOCKER 2 as pinned by the v848 '
      'acceptance suite has changed; re-read it before applying';
  end if;
  select pg_get_functiondef(p.oid) into v_body
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'app' and p.proname = 'enforce_sale_reversal_bounds';
  if v_body is null
     or position('zero-dollar reversal requires exact package session provenance' in v_body) = 0 then
    raise exception 'v848: app.enforce_sale_reversal_bounds no longer carries the zero-dollar '
      'package-session fence -- BLOCKER 2 has changed; re-read it before applying';
  end if;
end
$v848_pre$;

-- ============================================================================================
-- 2 · public.reverse_sale — the same delegation, plus the voucher the voided sale paid for.
-- ============================================================================================
create or replace function public.reverse_sale(
  p_business uuid,
  p_sale uuid,
  p_reason text,
  p_idempotency_key text,
  p_reference text default null::text,
  p_restock_policy text default 'none'::text)
returns json
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $function$
declare
  v_result json;
  v_actor uuid := auth.uid();
  v_returned integer := 0;
  v_hit integer;
  v_grant record;
begin
  -- Unchanged: every authorisation, provenance and loyalty consequence of a reversal still
  -- lives here, and is still asked FIRST.  A refusal raised in here aborts the statement, so
  -- nothing below can run against a sale that was not actually reversed.
  v_result := app.reverse_sale_with_loyalty_v480(
    p_business, p_sale, p_reason, p_idempotency_key, p_reference, p_restock_policy, false);

  -- nestly_v848: the customer met a minimum spend to claim a welcome offer, and that spend has
  -- just been given back.  The offer goes back to them.  FOR UPDATE serialises this against
  -- public.staff_reverse_gift_redemption_v665, which un-redeems the same grant by hand.
  for v_grant in
    select g.id, g.client_id, g.reward_label, g.redeemed_sale_id
      from public.welcome_offer_grants_v215 g
     where g.business_id = p_business
       and g.qualifying_sale_id = p_sale
       and g.status = 'redeemed'
     order by g.id
     for update
  loop
    -- The predicate is repeated on the UPDATE so the returned-already case is a no-op rather
    -- than a second return, and so the row-count below is the truth about what changed.
    update public.welcome_offer_grants_v215
       set status = 'granted', redeemed_at = null, redeemed_sale_id = null, redeemed_by = null,
           qualifying_sale_id = null, redeem_idempotency_key = null
     where id = v_grant.id
       and business_id = p_business
       and status = 'redeemed'
       and qualifying_sale_id = p_sale;
    get diagnostics v_hit = row_count;
    if v_hit > 0 then
      v_returned := v_returned + v_hit;
      insert into public.audit_log(business_id, actor, action, entity, entity_id, detail)
      values (p_business, v_actor, 'WELCOME_OFFER_RETURNED_ON_SALE_REVERSAL_V848',
              'welcome_offer_grants_v215', v_grant.id,
        jsonb_build_object('client_id', v_grant.client_id,
                           'reward_label', v_grant.reward_label,
                           'qualifying_sale_id', p_sale,
                           'fulfilment_sale_id', v_grant.redeemed_sale_id,
                           'reversal_sale_id', nullif(v_result->>'reversal_sale_id','')::uuid,
                           'reason', btrim(coalesce(p_reason,'')),
                           'idempotency_key', btrim(coalesce(p_idempotency_key,''))));
    end if;
  end loop;

  return (v_result::jsonb || jsonb_build_object('welcome_offers_returned', v_returned))::json;
end
$function$;

comment on function public.reverse_sale(uuid, uuid, text, text, text, text) is
  'nestly_v848: delegates to app.reverse_sale_with_loyalty_v480(...,false) exactly as before, '
  'then returns to ''granted'' any welcome offer whose qualifying_sale_id is the sale just '
  'voided. Idempotent (the predicate is status=''redeemed'' AND qualifying_sale_id=the sale) '
  'and audited as WELCOME_OFFER_RETURNED_ON_SALE_REVERSAL_V848. It adds no permission check '
  'and removes none: refund_sales is still enforced inside the delegate.';

-- ============================================================================================
-- 3 · ACLs — restated exactly as production held them (postgres, authenticated, service_role).
--     PUBLIC and anon had no EXECUTE and gain none.
-- ============================================================================================
revoke all on function public.reverse_sale(uuid, uuid, text, text, text, text) from public;
revoke all on function public.reverse_sale(uuid, uuid, text, text, text, text) from anon;
grant execute on function public.reverse_sale(uuid, uuid, text, text, text, text) to authenticated;
grant execute on function public.reverse_sale(uuid, uuid, text, text, text, text) to service_role;

-- ============================================================================================
-- 4 · VERIFY — prove it on a real tenant, then leave production exactly as it was found.
--     Everything the fixture writes lives inside the $v848_fixture$ sub-transaction, which is
--     always rolled back by the ZZ848 sentinel.  The row-count checks either side are the proof
--     that it was.
-- ============================================================================================
do $v848_verify$
declare
  v_before jsonb;
  v_after  jsonb;
  v_key    text;
begin
  select jsonb_build_object(
           'users',      (select count(*) from auth.users),
           'businesses', (select count(*) from public.businesses),
           'clients',    (select count(*) from public.clients),
           'sales',      (select count(*) from public.sales),
           'grants',     (select count(*) from public.welcome_offer_grants_v215),
           'audit',      (select count(*) from public.audit_log))
    into v_before;

  begin
    declare
      v_business uuid := gen_random_uuid();
      v_owner    uuid := gen_random_uuid();
      v_branch   uuid := gen_random_uuid();
      v_client   uuid := gen_random_uuid();
      v_phone    text := '8186' || lpad((floor(random()*10000))::text, 4, '0');
      v_slug     text := 'v848-verify-' || substr(gen_random_uuid()::text, 1, 8);
      v_grant    uuid;
      v_qsale    uuid;
      v_res      jsonb;
      v_j        json;
      v_status   text;
      v_qsid     uuid;
      v_n        integer;
    begin
      insert into auth.users(instance_id,id,aud,role,email,encrypted_password,
                             email_confirmed_at,created_at,updated_at)
      values ('00000000-0000-0000-0000-000000000000',v_owner,'authenticated','authenticated',
              'v848-'||substr(v_owner::text,1,8)||'@example.test','',now(),now(),now());
      insert into public.businesses(id,name,slug,industry,enabled_modules,points_mode)
      values (v_business,'V848 Verify',v_slug,'fnb',
              array['dashboard','clients','sales','loyalty','till'],'redeem');
      insert into public.staff(business_id,user_id,role,full_name,active,access_state)
      values (v_business,v_owner,'owner','V848 Owner',true,'approved');
      insert into public.branches(id,business_id,name,is_default,active)
      values (v_branch,v_business,'V848 Main',true,true);
      insert into public.staff_branches(business_id,staff_id,branch_id)
      select v_business, s.id, v_branch from public.staff s
       where s.business_id=v_business and s.user_id=v_owner;
      update public.business_workspace_controls_v94
         set approval_status='approved', version=version+1, decided_by=v_owner,
             decided_at=now(), decision_reason='v848 verify', updated_at=now()
       where business_id = v_business;
      update public.business_subscription_lifecycle_v94
         set workspace_paused=false where business_id = v_business;
      insert into public.subscriptions(business_id) values (v_business) on conflict do nothing;

      perform set_config('request.jwt.claims',
        json_build_object('sub', v_owner, 'role', 'authenticated')::text, true);

      perform public.business_set_welcome_offer_v215(
        v_business, true, 500, 'custom', null, null, 'V848 Free Soyabean');
      insert into public.clients(id,business_id,full_name,phone)
      values (v_client,v_business,'V848 Customer',v_phone);
      perform app.issue_welcome_offer_v215(v_business, v_client);
      select id into v_grant from public.welcome_offer_grants_v215
       where business_id=v_business and client_id=v_client;
      if v_grant is null then
        raise exception 'v848 VERIFY fixture: no welcome offer grant was issued';
      end if;

      v_j := public.record_sale_by_phone(v_business, v_phone, 900, 'quick_sale',
               'v848 verify qualifying sale', null,
               'v848q-'||replace(gen_random_uuid()::text,'-',''), v_branch, 'cash', null);
      v_qsale := (v_j->>'sale_id')::uuid;
      if v_qsale is null then
        raise exception 'v848 VERIFY fixture: the till refused the qualifying sale (%)', v_j::text;
      end if;

      v_res := public.staff_redeem_welcome_offer_v215(v_business, v_client, v_branch, v_qsale,
                 'v848r-'||replace(gen_random_uuid()::text,'-',''));
      select status, qualifying_sale_id into v_status, v_qsid
        from public.welcome_offer_grants_v215 where id = v_grant;
      if v_status <> 'redeemed' or v_qsid is distinct from v_qsale then
        raise exception 'v848 VERIFY fixture: after redeeming, the grant reads %/% ', v_status, v_qsid;
      end if;

      -- ---- the fix
      v_j := public.reverse_sale(v_business, v_qsale, 'v848 verify reversal of qualifying sale',
               'v848rev-'||replace(gen_random_uuid()::text,'-',''), 'v848 verify', 'none');

      select status, qualifying_sale_id into v_status, v_qsid
        from public.welcome_offer_grants_v215 where id = v_grant;
      if v_status <> 'granted' then
        raise exception 'v848 VERIFY FAILED: the grant is still % after its qualifying sale was voided', v_status;
      end if;
      if v_qsid is not null then
        raise exception 'v848 VERIFY FAILED: the returned grant still points at qualifying sale %', v_qsid;
      end if;
      if (v_j::jsonb->>'welcome_offers_returned') is distinct from '1' then
        raise exception 'v848 VERIFY FAILED: reverse_sale reported welcome_offers_returned=%',
          coalesce(v_j::jsonb->>'welcome_offers_returned','(absent)');
      end if;
      select count(*) into v_n from public.welcome_offer_grants_v215
       where business_id=v_business and client_id=v_client and status='granted';
      if v_n <> 1 then
        raise exception 'v848 VERIFY FAILED: grants_still_claimable = %, expected 1', v_n;
      end if;
      select count(*) into v_n from public.audit_log
       where business_id=v_business and action='WELCOME_OFFER_RETURNED_ON_SALE_REVERSAL_V848';
      if v_n <> 1 then
        raise exception 'v848 VERIFY FAILED: % audit row(s) for the returned voucher, expected 1', v_n;
      end if;

      -- ---- and the loyalty behaviour v480 already owned is still intact
      if (v_j::jsonb->>'reversed_cents') is distinct from '900' then
        raise exception 'v848 VERIFY FAILED: reverse_sale reported reversed_cents=%',
          coalesce(v_j::jsonb->>'reversed_cents','(absent)');
      end if;

      raise notice 'v848 verify: grant % returned to granted, 1 audit row, reversed_cents 900', v_grant;
      raise exception using errcode = 'ZZ848', message = 'v848 verify sentinel';
    end;
  exception
    when sqlstate 'ZZ848' then
      null;   -- the fixture is rolled back; production is untouched
  end;

  perform set_config('request.jwt.claims', '', true);

  select jsonb_build_object(
           'users',      (select count(*) from auth.users),
           'businesses', (select count(*) from public.businesses),
           'clients',    (select count(*) from public.clients),
           'sales',      (select count(*) from public.sales),
           'grants',     (select count(*) from public.welcome_offer_grants_v215),
           'audit',      (select count(*) from public.audit_log))
    into v_after;

  foreach v_key in array array['users','businesses','clients','sales','grants','audit'] loop
    if (v_before->>v_key) is distinct from (v_after->>v_key) then
      raise exception 'v848 VERIFY LEAK: % went from % to % -- the verify fixture escaped its sub-transaction',
        v_key, v_before->>v_key, v_after->>v_key;
    end if;
  end loop;

  raise notice 'v848 verify: no row leaked (%)', v_after::text;
end
$v848_verify$;

commit;
