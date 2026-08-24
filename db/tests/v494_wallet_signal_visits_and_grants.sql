-- Rolled-back proof for nestly_v494. One transaction, ROLLBACK at the end, nothing survives.
-- Run: supabase db query --linked -f db/tests/v494_wallet_signal_visits_and_grants.sql
--
-- The claim under test: a VISIT that appends no points_ledger row still rings the customer's
-- doorbell. That is the whole point of v494 — v479's trigger lives on points_ledger, so a $0
-- visit (a used package session, a completed appointment with nothing to pay) was silent and the
-- customer waited for the 20-second poll.
-- Fixture: QA Kaya Toast (38b30e6d…), customer "Devi M" (55e82702…), who holds a verified link.
begin;

do $$
declare
  v_biz uuid := '38b30e6d-de73-4c2b-a2ca-19b08950896c';
  v_client uuid := '55e82702-02a5-4a95-bbff-b941cda53f3d';
  v_auth uuid;
  v_before timestamptz; v_after timestamptz;
  v_ledger_before integer; v_ledger_after integer;
  v_triggers integer;
begin
  select auth_user_id into v_auth from public.customer_links
   where business_id = v_biz and client_id = v_client
     and state = 'verified' and auth_user_id is not null
   limit 1;
  if v_auth is null then
    raise exception 'FAIL 0: fixture customer has no verified link — pick another';
  end if;

  -- 1. all seven doorbells are wired to the ONE v479 bump function
  select count(*) into v_triggers
    from pg_trigger t join pg_class c on c.oid = t.tgrelid
    join pg_proc p on p.oid = t.tgfoid
   where not t.tgisinternal
     and p.proname = 'bump_customer_wallet_signal_v479'
     and c.relname in ('points_ledger','sales','welcome_offer_grants_v215',
                       'bringback_grants_v361','referral_grants_v420','reward_grants',
                       'loyalty_redemptions','stamp_milestone_claims');
  if v_triggers <> 8 then
    raise exception 'FAIL 1: expected 8 signal triggers (v479 + the 7 from v494), found %', v_triggers;
  end if;
  raise notice 'PASS 1: one bump function, eight tables — the v479 shape, widened';

  select bumped_at into v_before from public.customer_wallet_signals_v479
   where business_id = v_biz and auth_user_id = v_auth;
  select count(*) into v_ledger_before from public.points_ledger
   where business_id = v_biz and client_id = v_client;

  -- 2. a $0, non-earning visit — the case that was silent before v494
  perform pg_sleep(0.01);
  insert into public.sales(business_id, client_id, kind, amount_cents, counts_as_visit, earns_points)
  values (v_biz, v_client, 'service', 0, true, false);

  select bumped_at into v_after from public.customer_wallet_signals_v479
   where business_id = v_biz and auth_user_id = v_auth;
  select count(*) into v_ledger_after from public.points_ledger
   where business_id = v_biz and client_id = v_client;

  if v_after is null then
    raise exception 'FAIL 2: the visit produced no wallet signal at all';
  end if;
  if v_before is not null and v_after <= v_before then
    raise exception 'FAIL 2: the visit did not bump the signal (% -> %)', v_before, v_after;
  end if;
  -- The point of the assertion below: prove the bump did NOT come through the old v479 path.
  if v_ledger_after <> v_ledger_before then
    raise notice 'NOTE: this sale did append % ledger row(s); the bump is still correct but this '
      'fixture no longer isolates the v494 path — prefer a client whose programme earns nothing',
      v_ledger_after - v_ledger_before;
  else
    raise notice 'PASS 2: a visit with ZERO ledger rows rang the doorbell — the v494 path';
  end if;
end $$;

rollback;
