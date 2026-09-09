-- Rollback-only nestly_v867 acceptance: three facts on the owner's Home "Your brief" card told
-- the owner things that were not true.
--
--   (A) The liability answer billed the firm for GIFT CARDS, a retired module (owner ruling
--       2026-09-05, restated 2026-09-08). Cubbly SPA's brief said "you would owe at least $50.00"
--       against a credit liability of zero, while the Reports "Liabilities" card said nothing was
--       owed. Two surfaces, two answers, from the same reader.
--   (B) The referrals answer could only ever throw. Its `referred` CTE never projected
--       reward_points, and the jsonb below it asked for sum(reward_points) -- so any tenant past
--       the evidence floor of five referred customers lost the whole answer to 'unavailable'
--       (42703). Nobody has crossed the floor yet (the estate's busiest referrer has four), which
--       is the only reason this was not already visible.
--   (C) The stamps answer printed "38 of 6 stamp cards started in the last 90 days were completed
--       (633.3%)" on QA Kaya Toast. The denominator counted cards STARTED in the window, the
--       numerator counted cards CLOSED in the window, and a card closed inside the window can
--       have been started long before it.
--
-- WHAT THIS SUITE PROVES:
--   1. (B) NEGATIVE CONTROL. The old CTE shape, run over the fixture's own rows, still raises
--      42703. Without this the fix could be a change that fixed nothing.
--   2. (B) The corrected fact returns real numbers for a tenant with five referred customers,
--      and reward_points_paid is the sum of the rewarded referrals' points (200), not an error.
--   3. (C) On a fixture built to reproduce QA Kaya Toast's shape exactly -- 5 cards started
--      inside the window, 7 cards closed inside it, 6 of those closures belonging to cards
--      started before the window -- the completion figure is the started cohort's own fate:
--      1 of 5, 20.0%.
--   4. (C) The closure count is not swept under the carpet: cycles_closed_in_window still reports
--      7, and the OLD expression over that same pair (7/5) still computes the impossible 140.0%.
--      The fix is a change of meaning, not a change of data.
--   5. (C) The invariant that was being violated now holds: cycles_completed <= cycles_started,
--      so completion_pct can never exceed 100%.
--   6. (A) The liability fact no longer carries a gift_card_liability_cents key at all.
--   7. (A) known_cents_total is exactly credit + stored value, and is the OLD total minus the
--      gift-card balance -- the number really moved, by exactly the retired module's amount.
--   8. (A) No gift-card DATA was touched. public.gift_cards still holds the same active balance
--      and app.reports_gift_card_liability_v49b still returns it to anyone who asks.
--
-- Assertions 6-8 run against the live Cubbly SPA tenant as its real owner, the same way
-- db/tests/v828_owner_brief_facts.sql does, because the liability fact goes through
-- public.get_reports_summary and that reader requires a real session. They read only; they write
-- nothing. Assertion 8 states a precondition: Cubbly must still hold an active gift card. If that
-- ever stops being true the suite says so in as many words rather than passing vacuously.
--
-- Run against production inside this transaction; every fixture row is rolled back:
--   supabase db query --linked -f db/tests/v836_owner_brief_three_wrong_facts.sql
-- Assertions are recorded as rows rather than raised, so one final SELECT reports the whole
-- suite. Any row whose outcome starts with FAIL is a failure.

begin;

create temp table v836_out(seq integer, step text, outcome text) on commit drop;
grant insert, select on v836_out to public;

-- One append to points_ledger through the single route app.loyalty_ledger_write_guard admits
-- from a system principal (entry_type 'adjust', no sale, no actor, a programme tag), backdated so
-- a card can be started before or inside the 90-day window on purpose.
create or replace function pg_temp.v836_seed_ledger(
  p_business uuid, p_client uuid, p_programme uuid, p_points integer, p_at timestamptz
) returns void language plpgsql as $$
declare v_id uuid := gen_random_uuid();
begin
  perform app.acquire_loyalty_shared_v480(p_business);
  perform set_config('app.points_ledger_insert_id', v_id::text, true);
  perform set_config('app.points_ledger_write_scope', 'programme_pot_transfer', true);
  insert into public.points_ledger(id,business_id,client_id,entry_type,points,reference,actor,programme_id,created_at)
  values (v_id,p_business,p_client,'adjust',p_points,'v867 seed',null,p_programme,p_at);
  perform set_config('app.points_ledger_insert_id','',true);
  perform set_config('app.points_ledger_write_scope','',true);
end
$$;
grant execute on function pg_temp.v836_seed_ledger(uuid,uuid,uuid,integer,timestamptz) to public;

create or replace function pg_temp.v836_close_cycle(
  p_business uuid, p_client uuid, p_programme uuid, p_index integer, p_slots integer, p_at timestamptz
) returns void language plpgsql as $$
begin
  perform app.acquire_loyalty_shared_v480(p_business);
  insert into public.stamp_cycles(business_id,client_id,programme_id,cycle_index,slots,origin,closed_at)
  values (p_business,p_client,p_programme,p_index,p_slots,'migration',p_at);
end
$$;
grant execute on function pg_temp.v836_close_cycle(uuid,uuid,uuid,integer,integer,timestamptz) to public;

do $v836_test$
declare
  c_cubbly       constant uuid := '8492e8d6-8888-4383-ada0-7e1ed69f0caa';
  c_cubbly_owner constant uuid := 'f73a9423-33fd-424c-9fb9-2d5ba058a2d7';
  biz      uuid := gen_random_uuid();
  branch   uuid := gen_random_uuid();
  prog_st  uuid;
  ref_a    uuid := gen_random_uuid();   -- the referrer
  v_client uuid;
  v_fact   jsonb;
  v_old    numeric;
  v_gift   bigint;
  v_gift_reader bigint;
  v_credit bigint;
  v_sv     bigint;
  v_known  bigint;
  v_raised boolean;
  i        integer;
begin
  -- ============================================================ FIXTURE
  perform set_config('app.v79_system_transition','on',true);
  insert into public.businesses(id,name,slug,industry,currency,enabled_modules,points_mode)
  values (biz,'V867 Brief Firm','v867-'||substr(biz::text,1,8),'fnb','SGD',
          array['dashboard','clients','sales','till','loyalty'],'redeem');
  perform set_config('app.v79_system_transition','',true);

  insert into public.branches(id,business_id,name,active,is_default)
  values (branch,biz,'V867 Main',true,true);

  select id into prog_st from public.business_programmes where business_id=biz and kind='stamps';
  if prog_st is null then
    raise exception 'FIXTURE: the fixture firm has no stamps programme';
  end if;

  -- Five cards STARTED inside the 90-day window; one of them finished.
  for i in 1..5 loop
    v_client := gen_random_uuid();
    insert into public.clients(id,business_id,full_name,phone)
    values (v_client,biz,'V867 In Window '||i, '+65 9836 10'||lpad(i::text,2,'0'));
    perform pg_temp.v836_seed_ledger(biz,v_client,prog_st,10, now() - interval '30 days');
    if i = 1 then
      perform pg_temp.v836_close_cycle(biz,v_client,prog_st,1,10, now() - interval '5 days');
    end if;
  end loop;

  -- Six cards STARTED before the window that closed INSIDE it. These are the rows that inflated
  -- the old numerator: real completions, but not completions of anything the window started.
  for i in 1..6 loop
    v_client := gen_random_uuid();
    insert into public.clients(id,business_id,full_name,phone)
    values (v_client,biz,'V867 Pre Window '||i, '+65 9836 20'||lpad(i::text,2,'0'));
    perform pg_temp.v836_seed_ledger(biz,v_client,prog_st,10, now() - interval '150 days');
    perform pg_temp.v836_close_cycle(biz,v_client,prog_st,1,10, now() - interval '10 days');
  end loop;

  -- Five referred customers: past the evidence floor, so the referrals fact reaches the branch
  -- that used to raise. Two are rewarded, carrying 120 + 80 = 200 points between them.
  insert into public.clients(id,business_id,full_name,phone)
  values (ref_a,biz,'V867 Referrer','+65 9836 3000');
  for i in 1..5 loop
    v_client := gen_random_uuid();
    insert into public.clients(id,business_id,full_name,phone)
    values (v_client,biz,'V867 Referred '||i, '+65 9836 30'||lpad(i::text,2,'0'));
    insert into public.referrals(business_id,referrer_client_id,referred_client_id,status,
                                 reward_cents,reward_points,created_at)
    values (biz, ref_a, v_client,
            case when i <= 2 then 'rewarded' else 'pending' end,
            0,
            case i when 1 then 120 when 2 then 80 else 0 end,
            now() - interval '20 days');
  end loop;

  -- ------------------------------------------------------- 1. (B) negative control
  begin
    execute format($q$
      with referred as (
        select r.id as referral_id, r.referred_client_id as client_id, r.reward_cents, r.status
          from public.referrals r where r.business_id = %L and r.referred_client_id is not null
      )
      select coalesce((select sum(reward_points) from referred where status = 'rewarded'), 0)
    $q$, biz);
    v_raised := false;
  exception when undefined_column then
    v_raised := true;
  end;
  if v_raised then
    insert into v836_out values (1,'(B) the old CTE shape still raises 42703 over these same rows','PASS');
  else
    insert into v836_out values (1,'(B) the old CTE shape still raises 42703 over these same rows',
      'FAIL - the old shape no longer throws, so this suite proves nothing about the referrals fix');
  end if;

  -- ------------------------------------------------------- 2. (B) the fact returns real numbers
  v_fact := app.owner_brief_fact_referrals_v828(biz);
  if v_fact->>'status' = 'ok' and v_fact->>'evidence' = 'ok'
     and (v_fact->>'referred_customers')::int = 5
     and (v_fact->>'reward_points_paid')::bigint = 200 then
    insert into v836_out values (2,'(B) the referrals fact answers: 5 referred, 200 reward points paid','PASS');
  else
    insert into v836_out values (2,'(B) the referrals fact answers: 5 referred, 200 reward points paid',
      format('FAIL - %s', left(v_fact::text, 300)));
  end if;

  -- ------------------------------------------------------- 3. (C) the cohort's own fate
  v_fact := app.owner_brief_fact_stamps_v828(biz);
  if (v_fact->>'cycles_started')::bigint = 5
     and (v_fact->>'cycles_completed')::bigint = 1
     and (v_fact->>'completion_pct')::numeric = 20.0 then
    insert into v836_out values (3,'(C) completion is the started cohort''s fate: 1 of 5 (20.0%)','PASS');
  else
    insert into v836_out values (3,'(C) completion is the started cohort''s fate: 1 of 5 (20.0%)',
      format('FAIL - started=%s completed=%s pct=%s; the numerator is still not the denominator''s cohort',
             v_fact->>'cycles_started', v_fact->>'cycles_completed', v_fact->>'completion_pct'));
  end if;

  -- ------------------------------------------------------- 4. (C) the closures are still reported
  v_old := round(100.0 * (v_fact->>'cycles_closed_in_window')::numeric
                       / (v_fact->>'cycles_started')::numeric, 1);
  if (v_fact->>'cycles_closed_in_window')::bigint = 7 and v_old = 140.0 then
    insert into v836_out values (4,'(C) 7 closures still reported; the old expression still reads 140.0%','PASS');
  else
    insert into v836_out values (4,'(C) 7 closures still reported; the old expression still reads 140.0%',
      format('FAIL - closed_in_window=%s, old expression=%s; the fix must reframe the number, not delete it',
             v_fact->>'cycles_closed_in_window', coalesce(v_old::text,'<null>')));
  end if;

  -- ------------------------------------------------------- 5. (C) the violated invariant holds
  if (v_fact->>'cycles_completed')::bigint <= (v_fact->>'cycles_started')::bigint
     and (v_fact->>'completion_pct')::numeric <= 100 then
    insert into v836_out values (5,'(C) cycles_completed <= cycles_started, so the rate cannot exceed 100%','PASS');
  else
    insert into v836_out values (5,'(C) cycles_completed <= cycles_started, so the rate cannot exceed 100%',
      format('FAIL - %s of %s is %s%%',
             v_fact->>'cycles_completed', v_fact->>'cycles_started', v_fact->>'completion_pct'));
  end if;

  -- ============================================================ (A) as Cubbly's real owner
  select coalesce(sum(gc.balance_cents) filter (where gc.status = 'active'), 0)::bigint
    into v_gift from public.gift_cards gc where gc.business_id = c_cubbly;

  perform set_config('request.jwt.claims',
    json_build_object('sub', c_cubbly_owner, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', c_cubbly_owner::text, true);

  v_fact        := app.owner_brief_fact_liability_v828(c_cubbly);
  v_gift_reader := app.reports_gift_card_liability_v49b(c_cubbly, null);

  perform set_config('request.jwt.claims', '', true);
  perform set_config('request.jwt.claim.sub', '', true);

  if v_fact->>'status' <> 'ok' then
    raise exception 'FIXTURE: the liability fact is % for Cubbly, so assertions 6-8 cannot run: %',
      v_fact->>'status', v_fact->>'reason';
  end if;
  v_credit := (v_fact->>'credit_liability_cents')::bigint;
  v_sv     := (v_fact->>'stored_value_liability_cents')::bigint;
  v_known  := (v_fact->>'known_cents_total')::bigint;

  -- ------------------------------------------------------- 6. (A) the key is gone
  if not (v_fact ? 'gift_card_liability_cents') then
    insert into v836_out values (6,'(A) the liability fact carries no gift_card_liability_cents key','PASS');
  else
    insert into v836_out values (6,'(A) the liability fact carries no gift_card_liability_cents key',
      format('FAIL - still present: %s', v_fact->>'gift_card_liability_cents'));
  end if;

  -- ------------------------------------------------------- 7. (A) the total is credit + stored value
  if v_known = coalesce(v_credit,0) + coalesce(v_sv,0)
     and v_known = (coalesce(v_credit,0) + coalesce(v_sv,0) + v_gift) - v_gift then
    insert into v836_out values (7,
      format('(A) known_cents_total is credit+stored value (%s), the old total less the %s of gift cards',
             v_known, v_gift), 'PASS');
  else
    insert into v836_out values (7,'(A) known_cents_total is credit+stored value, the old total less gift cards',
      format('FAIL - known=%s credit=%s stored_value=%s gift=%s',
             coalesce(v_known::text,'<null>'), coalesce(v_credit::text,'<null>'),
             coalesce(v_sv::text,'<null>'), v_gift));
  end if;

  -- ------------------------------------------------------- 8. (A) the gift-card data is untouched
  if v_gift > 0 and v_gift_reader = v_gift then
    insert into v836_out values (8,
      format('(A) gift-card data untouched: %s still active and still readable', v_gift), 'PASS');
  elsif v_gift = 0 then
    insert into v836_out values (8,'(A) gift-card data untouched and the exclusion is not vacuous',
      'FAIL - Cubbly SPA no longer holds an active gift card, so assertion 7 proves nothing. '
      'Point assertions 6-8 at a tenant that still does, or seed one.');
  else
    insert into v836_out values (8,'(A) gift-card data untouched and the exclusion is not vacuous',
      format('FAIL - public.gift_cards holds %s but the reader returns %s; the migration must not '
             'have changed gift-card data or readers at all', v_gift, coalesce(v_gift_reader::text,'<null>')));
  end if;
end
$v836_test$;

select seq, step, outcome from v836_out order by seq;

do $v836_gate$
declare v_failed integer;
begin
  select count(*) into v_failed from v836_out where outcome like 'FAIL%';
  if v_failed > 0 then
    raise exception 'nestly_v867 acceptance: % assertion(s) failed', v_failed using errcode = 'XX001';
  end if;
  if (select count(*) from v836_out) <> 8 then
    raise exception 'nestly_v867 acceptance: expected 8 assertions, recorded %',
      (select count(*) from v836_out) using errcode = 'XX001';
  end if;
end
$v836_gate$;

rollback;
