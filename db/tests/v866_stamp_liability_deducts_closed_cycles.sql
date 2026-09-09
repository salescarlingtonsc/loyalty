-- Rollback-only nestly_v866 acceptance: the owner's stamp liability is the stamps still on
-- cards, and it is the same number the customer's own card shows.
--
-- WHAT THE BUG WAS
--   app.v177_overview (the platform workspace mirror) and app.v179_business_insights (the
--   evidence pack) both reported a pot's `outstanding` as `sum(points_ledger.points)`. For a
--   POINTS pot that is right — a redemption is a negative ledger row. For a STAMPS pot it is
--   not: claiming the final milestone closes a cycle and records the consumed slots in
--   public.stamp_cycles, writing no negative ledger row. So both readers reported LIFETIME
--   stamps as outstanding liability while app.stamp_progress_v323 — the customer's own card —
--   had already deducted them.
--
--   Measured read-only against production, 2026-09-09:
--
--     QA Kaya Toast        reported 1134   closed 527   truly outstanding 607   (+87%)
--     QA Kopi Lab (Bedok)  reported   43   closed  30   truly outstanding  13   (+231%)
--
--   and per customer on QA Kaya Toast the corrected figures (606/0/1/0) reproduce those
--   customers' own cards exactly.
--
-- WHAT THIS SUITE PROVES, against two tenants it builds itself:
--   1. A tenant with stamps earned and NO cycles closed is unchanged — outstanding is still the
--      lifetime figure (46). Without this the "fix" could be an unconditional subtraction.
--   2. Once cycles close, the firm-level reader deducts them: 13, not 46.
--   3. The evidence-pack reader agrees with the mirror: also 13. Two surfaces, one authority.
--   4. The owner's figure EQUALS the sum of the customers' own cards
--      (app.stamp_progress_v323.filled). This is the assertion that makes the two sides of the
--      product unable to disagree; it is the whole point of the migration.
--   5. The clamp is per CUSTOMER, not firm-level. Customer D closed a 10-slot cycle against only
--      3 surviving ledger stamps; a firm-level `greatest(sum(net) - sum(closed), 0)` reads 6 and
--      would silently cancel customer A's genuinely open card. 13 is reachable only per customer.
--   6. A POINTS pot is untouched — still the plain ledger sum (30). The fix must not "improve"
--      the unit it was never about.
--   7. A retired (switched-off) STAMPS pot deducts its closed cycles too: 10, not 20. Whether a
--      retired pot should be reported as outstanding at all is a separate scoping question this
--      migration deliberately does not answer; its arithmetic is still corrected.
--
-- Run against production inside this transaction; every fixture row is rolled back:
--   supabase db query --linked -f db/tests/v835_stamp_liability_deducts_closed_cycles.sql
-- Assertions are recorded as rows rather than raised, so one final SELECT reports the whole
-- suite. Any row whose outcome starts with FAIL is a failure.

begin;

create temp table v835_out(seq integer, step text, outcome text) on commit drop;
grant insert, select on v835_out to public;

-- One append to points_ledger through the single route app.loyalty_ledger_write_guard admits
-- from a system principal (entry_type 'adjust', no sale, no actor, a programme tag), and one
-- stamp_cycles closure through the app.require_loyalty_shared_v480 fence.
create or replace function pg_temp.v835_seed_ledger(
  p_business uuid, p_client uuid, p_programme uuid, p_points integer
) returns void language plpgsql as $$
declare v_id uuid := gen_random_uuid();
begin
  perform app.acquire_loyalty_shared_v480(p_business);
  perform set_config('app.points_ledger_insert_id', v_id::text, true);
  perform set_config('app.points_ledger_write_scope', 'programme_pot_transfer', true);
  insert into public.points_ledger(id,business_id,client_id,entry_type,points,reference,actor,programme_id)
  values (v_id,p_business,p_client,'adjust',p_points,'v866 seed',null,p_programme);
  perform set_config('app.points_ledger_insert_id','',true);
  perform set_config('app.points_ledger_write_scope','',true);
end
$$;
grant execute on function pg_temp.v835_seed_ledger(uuid,uuid,uuid,integer) to public;

create or replace function pg_temp.v835_close_cycle(
  p_business uuid, p_client uuid, p_programme uuid, p_index integer, p_slots integer
) returns void language plpgsql as $$
begin
  perform app.acquire_loyalty_shared_v480(p_business);
  insert into public.stamp_cycles(business_id,client_id,programme_id,cycle_index,slots,origin)
  values (p_business,p_client,p_programme,p_index,p_slots,'migration');
end
$$;
grant execute on function pg_temp.v835_close_cycle(uuid,uuid,uuid,integer,integer) to public;

do $v835_test$
declare
  biz_s uuid := gen_random_uuid();   -- stamps is the live pot
  biz_p uuid := gen_random_uuid();   -- points is the live pot, stamps retired
  branch_s uuid := gen_random_uuid();
  branch_p uuid := gen_random_uuid();
  s_stamps uuid;
  s_points uuid;
  p_stamps uuid;
  p_points uuid;
  c_a uuid := gen_random_uuid();     -- 8 earned, no cycle          -> 8
  c_b uuid := gen_random_uuid();     -- 15 earned, one 10-slot cycle -> 5
  c_c uuid := gen_random_uuid();     -- 20 earned, two 10-slot cycles -> 0
  c_d uuid := gen_random_uuid();     -- 3 earned, one 10-slot cycle  -> 0 (clamped, not -7)
  c_e uuid := gen_random_uuid();     -- 30 on the points pot
  c_f uuid := gen_random_uuid();     -- 20 on the retired stamps pot, one 10-slot cycle
  v_today date := (clock_timestamp() at time zone 'Asia/Singapore')::date;
  v_mirror bigint;
  v_pack bigint;
  v_cards bigint;
  v_firm_level bigint;
  v_hist text;
begin
  -- ============================================================ FIXTURE
  perform set_config('app.v79_system_transition','on',true);
  insert into public.businesses(id,name,slug,industry,currency,enabled_modules,points_mode) values
    (biz_s,'V866 Stamp Firm','v835s-'||substr(biz_s::text,1,8),'fnb','SGD',
     array['dashboard','clients','sales','till','loyalty'],'redeem'),
    (biz_p,'V866 Points Firm','v835p-'||substr(biz_p::text,1,8),'fnb','SGD',
     array['dashboard','clients','sales','till','loyalty'],'redeem');
  perform set_config('app.v79_system_transition','',true);

  insert into public.branches(id,business_id,name,active,is_default) values
    (branch_s,biz_s,'V866 S Main',true,true),
    (branch_p,biz_p,'V866 P Main',true,true);

  select id into s_stamps from public.business_programmes where business_id=biz_s and kind='stamps';
  select id into s_points from public.business_programmes where business_id=biz_s and kind='points';
  select id into p_stamps from public.business_programmes where business_id=biz_p and kind='stamps';
  select id into p_points from public.business_programmes where business_id=biz_p and kind='points';
  update public.business_programmes set active=true  where id in (s_stamps, p_points);
  update public.business_programmes set active=false where id in (s_points, p_stamps);

  if app.live_balance_programme_v381(biz_s) <> s_stamps then
    raise exception 'FIXTURE: the stamp firm''s live pot is not its stamps spine';
  end if;
  if app.live_balance_programme_v381(biz_p) <> p_points then
    raise exception 'FIXTURE: the points firm''s live pot is not its points spine';
  end if;

  insert into public.clients(id,business_id,full_name,phone) values
    (c_a,biz_s,'V866 Mid Cycle',   '+65 9835 0001'),
    (c_b,biz_s,'V866 One Closed',  '+65 9835 0002'),
    (c_c,biz_s,'V866 All Closed',  '+65 9835 0003'),
    (c_d,biz_s,'V866 Over Closed', '+65 9835 0004'),
    (c_e,biz_p,'V866 Points Only', '+65 9835 0005'),
    (c_f,biz_p,'V866 Retired Pot', '+65 9835 0006');

  perform pg_temp.v835_seed_ledger(biz_s,c_a,s_stamps,8);
  perform pg_temp.v835_seed_ledger(biz_s,c_b,s_stamps,15);
  perform pg_temp.v835_seed_ledger(biz_s,c_c,s_stamps,20);
  perform pg_temp.v835_seed_ledger(biz_s,c_d,s_stamps,3);
  perform pg_temp.v835_seed_ledger(biz_p,c_e,p_points,30);
  perform pg_temp.v835_seed_ledger(biz_p,c_f,p_stamps,20);

  -- ------------------------------------------------------- 1. nothing closed yet
  v_mirror := (app.v177_overview(biz_s,null)->'outstanding'->'active_programme'->>'outstanding')::bigint;
  if v_mirror = 46 then
    insert into v835_out values (1,'no cycles closed: outstanding is the lifetime figure (46)','PASS');
  else
    insert into v835_out values (1,'no cycles closed: outstanding is the lifetime figure (46)',
      format('FAIL - mirror=%s; a tenant that has closed nothing must be unchanged',
             coalesce(v_mirror::text,'<null>')));
  end if;

  -- ------------------------------------------------------- close the cycles
  perform pg_temp.v835_close_cycle(biz_s,c_b,s_stamps,1,10);
  perform pg_temp.v835_close_cycle(biz_s,c_c,s_stamps,1,10);
  perform pg_temp.v835_close_cycle(biz_s,c_c,s_stamps,2,10);
  perform pg_temp.v835_close_cycle(biz_s,c_d,s_stamps,1,10);
  perform pg_temp.v835_close_cycle(biz_p,c_f,p_stamps,1,10);

  -- ------------------------------------------------------- 2. the mirror deducts them
  v_mirror := (app.v177_overview(biz_s,null)->'outstanding'->'active_programme'->>'outstanding')::bigint;
  if v_mirror = 13 then
    insert into v835_out values (2,'closed cycles are deducted: the mirror reads 13, not 46','PASS');
  else
    insert into v835_out values (2,'closed cycles are deducted: the mirror reads 13, not 46',
      format('FAIL - mirror=%s; 46 means lifetime stamps are still being called outstanding',
             coalesce(v_mirror::text,'<null>')));
  end if;

  -- ------------------------------------------------------- 3. the evidence pack agrees
  v_pack := (app.v179_business_insights(biz_s, v_today - 29, v_today, v_today - 59, v_today - 30)
             ->'loyalty'->'active_programme'->>'outstanding')::bigint;
  if v_pack = 13 then
    insert into v835_out values (3,'the evidence pack reads the same 13 as the mirror','PASS');
  else
    insert into v835_out values (3,'the evidence pack reads the same 13 as the mirror',
      format('FAIL - pack=%s mirror=%s; two surfaces must not carry two copies of one fact',
             coalesce(v_pack::text,'<null>'), coalesce(v_mirror::text,'<null>')));
  end if;

  -- ------------------------------------------------------- 4. owner == the customers' own cards
  select sum(card.filled) into v_cards
    from (values (c_a),(c_b),(c_c),(c_d)) person(id)
    cross join lateral app.stamp_progress_v323(biz_s, person.id) card
   where card.programme_id = s_stamps;
  if v_cards = v_mirror and v_cards = 13 then
    insert into v835_out values (4,'the owner''s liability equals the sum of the customers'' own cards','PASS');
  else
    insert into v835_out values (4,'the owner''s liability equals the sum of the customers'' own cards',
      format('FAIL - cards=%s mirror=%s; the owner and the customer are reading the same cards '
             || 'and must not report different numbers',
             coalesce(v_cards::text,'<null>'), coalesce(v_mirror::text,'<null>')));
  end if;

  -- ------------------------------------------------------- 5. the clamp is per customer
  -- Customer D closed a 10-slot cycle against 3 surviving stamps. A firm-level
  -- greatest(sum(net) - sum(closed), 0) reads 46 - 40 = 6 and cancels customer A's open card.
  v_firm_level := greatest(46 - 40, 0);
  if v_mirror = 13 and v_mirror <> v_firm_level then
    insert into v835_out values (5,'the clamp is per customer (13), not firm-level (6)','PASS');
  else
    insert into v835_out values (5,'the clamp is per customer (13), not firm-level (6)',
      format('FAIL - mirror=%s, firm-level shortcut=%s; one customer''s over-closed history must '
             || 'not cancel another customer''s open card',
             coalesce(v_mirror::text,'<null>'), v_firm_level));
  end if;

  -- ------------------------------------------------------- 6. a points pot is untouched
  v_mirror := (app.v177_overview(biz_p,null)->'outstanding'->'active_programme'->>'outstanding')::bigint;
  if v_mirror = 30 then
    insert into v835_out values (6,'a points pot still reports the plain ledger sum (30)','PASS');
  else
    insert into v835_out values (6,'a points pot still reports the plain ledger sum (30)',
      format('FAIL - mirror=%s; points redemptions are already negative ledger rows and must not '
             || 'be deducted twice', coalesce(v_mirror::text,'<null>')));
  end if;

  -- ------------------------------------------------------- 7. a retired stamps pot too
  select tag.value->>'outstanding' into v_hist
    from jsonb_array_elements(app.v177_overview(biz_p,null)->'outstanding'->'historical_programmes') tag(value)
   where tag.value->>'unit' = 'stamps';
  if v_hist = '10' then
    insert into v835_out values (7,'a retired stamps pot deducts its closed cycles too (10, not 20)','PASS');
  else
    insert into v835_out values (7,'a retired stamps pot deducts its closed cycles too (10, not 20)',
      format('FAIL - historical stamps=%s; the same defect lives in the historical block',
             coalesce(v_hist::text,'<null>')));
  end if;
end
$v835_test$;

select seq, step, outcome from v835_out order by seq;

do $v835_gate$
declare v_failed integer;
begin
  select count(*) into v_failed from v835_out where outcome like 'FAIL%';
  if v_failed > 0 then
    raise exception 'nestly_v866 acceptance: % assertion(s) failed', v_failed using errcode = 'XX001';
  end if;
  if (select count(*) from v835_out) <> 7 then
    raise exception 'nestly_v866 acceptance: expected 7 assertions, recorded %',
      (select count(*) from v835_out) using errcode = 'XX001';
  end if;
end
$v835_gate$;

rollback;
