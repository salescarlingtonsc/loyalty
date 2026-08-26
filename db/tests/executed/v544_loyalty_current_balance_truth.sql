-- EXECUTED golden fixture for LOYALTY_CURRENT_BALANCE_V1 — the canonical current-balance contract.
--
-- WHY THIS FILE EXISTS
-- On 2026-08-26 a customer-facing reader was measured showing a real Cubbly SPA customer a balance
-- of 940 when their spendable balance was 139: 139 live POINTS plus 801 dormant STAMPS, added
-- together and labelled "points". Five real customers across three production tenants were
-- affected, in BOTH switch directions. This is the same defect shape as the historical 855-vs-758
-- incident, and it had reappeared because each reader re-implemented "the customer's balance"
-- instead of asking one primitive.
--
-- THE CONTRACT — LOYALTY_CURRENT_BALANCE_V1
--   A customer's current balance is the net of public.points_ledger for that (business, client)
--   restricted to the business's ACTIVE accruing programme pot, and it is meaningless without the
--   unit of that pot. Hard invariants, each asserted below:
--     I1  points and stamps are NEVER added together
--     I2  balances from different programme pots are NEVER added into the display balance
--     I3  a dormant/deactivated pot never contaminates the current balance
--     I4  a points business displays points; I5 a stamps business displays stamps
--     I6  there is no implicit conversion between the two units
--     I7  history may be retained, but is not the current balance
--     I8  business configuration decides the active programme; the reader never guesses
--     I9  every current-balance reader derives from the same primitive
--   Canonical primitive: app.client_points_balance_v409(business, client), which resolves the
--   live pot via app.live_balance_programme_v381 and the safety scope via
--   app.programme_balance_scope_v312.
--
-- NON-CIRCULAR ORACLE — this is the point of the file.
-- Expected balances are NOT obtained by calling the function under test. Each fixture row below
-- declares its expected balance and unit as a LITERAL, derived by hand from the raw ledger rows
-- the fixture seeds. If the primitive and every reader agree with the literal, they are right; if
-- they agree with each other but not the literal, they are consistently wrong and this fails.
--
-- CASES
--   A  live POINTS + dormant STAMPS   139 live / 801 dormant  -> 139 points   (never 940)
--   B  live STAMPS + dormant POINTS    15 live / 116 dormant  -> 15 stamps    (never 131)
--   C  live points only                                       -> its own total
--   D  live stamps only                                       -> its own total
--   E  two dormant programmes + one active                    -> active only
--   H  zero active balance + dormant history                  -> 0, in the ACTIVE unit
--   I  no active programme at all                             -> null balance, null unit, refuses
--   M  same customer in two businesses                        -> isolated
--   N  two customers in one business                          -> isolated
--   K  earn + redeem nets within the active pot
--   J  a manual adjustment lands in, and only in, the active pot
--
-- Cases F and G (switch directions) are covered structurally by A and B, which ARE the two
-- directions: A is a tenant that switched stamps->points, B is one that switched points->stamps.
--
-- NAMED FOR v544, NOT THE WATERMARK. The fix is pending migration v544, so this file cannot pass
-- against the frozen v422 baseline — and should not. The harness reports a test named above the
-- watermark as n/a in the baseline phase and gates it on the migrated phase, which is exactly the
-- semantics wanted here. The fails-before-fix property was proved separately and more strongly, by
-- reverting ONLY the v95 body on the migrated schema and re-running: cases A (940 vs 139),
-- B (131 vs 15) and E/H (250 vs 0) fail, and pass again once v544 is re-applied.
--
-- The whole file is one transaction and rolls back. Failures RAISE.

\set ON_ERROR_STOP on

begin;

create temp table _fixture(
  case_id      text primary key,
  business_id  uuid,
  client_id    uuid,
  live_kind    text,          -- the unit the business is configured for
  expect_bal   integer,       -- HAND-DERIVED from the seeded rows, never from the function
  expect_unit  text,
  note         text
) on commit drop;

create temp table _fail(case_id text, detail text) on commit drop;

/* public.points_ledger is protected by loyalty_ledger_write_guard: every row must carry a
   per-row token (app.points_ledger_insert_id) and name one of nine approved routes
   (app.points_ledger_write_scope), and the row shape must match that route. The fixture seeds
   through the real 'programme_pot_transfer' route — the one that exists to move value between
   pots — instead of disabling the trigger. A fixture that switches off the guard it runs under
   would not resemble production.
   HONEST LIMIT: every seeded row is therefore entry_type='adjust'. This file proves POT SCOPING
   of the net balance, which is the contract under test; it does not exercise earn/redeem/expire
   entry-type semantics, which belong to the engine suites. */
create or replace function pg_temp.seed_pot(p_business uuid, p_client uuid, p_programme uuid, p_points integer)
returns void language plpgsql as $seed$
declare v_id uuid := gen_random_uuid();
begin
  perform set_config('app.points_ledger_insert_id', v_id::text, true);
  perform set_config('app.points_ledger_write_scope', 'programme_pot_transfer', true);
  insert into public.points_ledger (id, business_id, client_id, programme_id, points, entry_type, actor, sale_id)
  values (v_id, p_business, p_client, p_programme, p_points, 'adjust', null, null);
end
$seed$;

do $loyalty$
declare
  -- one business per case so pot shapes cannot interfere
  b_a uuid := '00000000-0000-4000-8000-00000000a001';  -- live points + dormant stamps
  b_b uuid := '00000000-0000-4000-8000-00000000a002';  -- live stamps + dormant points
  b_c uuid := '00000000-0000-4000-8000-00000000a003';  -- live points only
  b_d uuid := '00000000-0000-4000-8000-00000000a004';  -- live stamps only
  b_e uuid := '00000000-0000-4000-8000-00000000a005';  -- two dormant + one active
  b_i uuid := '00000000-0000-4000-8000-00000000a006';  -- no active programme
  /* A "customer" in Peekaa is one clients row PER BUSINESS, linked across businesses by phone.
     clients.id is a global primary key, so the same uuid cannot appear twice — CASE M is therefore
     two distinct rows sharing one phone, which is what the product actually models. */
  c_a1 uuid := '00000000-0000-4000-8000-00000000c001';
  c_a2 uuid := '00000000-0000-4000-8000-00000000c002';
  c_b  uuid := '00000000-0000-4000-8000-00000000c003';
  c_c  uuid := '00000000-0000-4000-8000-00000000c004';
  c_d  uuid := '00000000-0000-4000-8000-00000000c005';
  c_e  uuid := '00000000-0000-4000-8000-00000000c006';
  c_i  uuid := '00000000-0000-4000-8000-00000000c007';
  v_shared_phone text := '80000001';
  v_auth  uuid := '00000000-0000-4000-8000-0000000000a1';
  v_ident uuid := '00000000-0000-4000-8000-0000000000a2';
  v_bid uuid; v_cid uuid;
  v_live uuid;
  v_dorm uuid;
begin
  -- ---------------------------------------------------------------- businesses and customers
  insert into public.businesses (id, name, slug) values
    (b_a,'ZZ loyalty A','zz-loy-a'), (b_b,'ZZ loyalty B','zz-loy-b'),
    (b_c,'ZZ loyalty C','zz-loy-c'), (b_d,'ZZ loyalty D','zz-loy-d'),
    (b_e,'ZZ loyalty E','zz-loy-e'), (b_i,'ZZ loyalty I','zz-loy-i');

  /* v95 refuses without an active branch (active_branch_required) — it renders a business page,
     which is branch-scoped. One active branch per fixture business. */
  insert into public.branches (business_id, name, active)
  select b, 'Main', true from unnest(array[b_a,b_b,b_c,b_d,b_e,b_i]) b;

  insert into public.clients (id, business_id, full_name, phone) values
    (c_a1,b_a,'Fixture Customer One', v_shared_phone),
    (c_a2,b_a,'Fixture Customer Two','80000002'),
    (c_b, b_b,'Fixture Customer One','80000003'),
    (c_c, b_c,'Fixture Customer One','80000004'),
    (c_d, b_d,'Fixture Customer One', v_shared_phone),  -- CASE M: same person, other business
    (c_e, b_e,'Fixture Customer One','80000006'),
    (c_i, b_i,'Fixture Customer One','80000007');

  /* nestly_v480 fences every loyalty-value write behind a per-business advisory lock
     (app.loyalty_fence_key_v480 / require_loyalty_shared_v480). The fixture takes the fence the
     same way a real writer does rather than disabling the guard — a test that switches off the
     protection it is meant to run under proves nothing about production. */
  /* The fence arrived in v480, after this file's watermark, so it is taken only when present —
     the harness runs this against the frozen v422 baseline as well as the migrated schema. */
  if to_regprocedure('app.loyalty_fence_key_v480(uuid)') is not null then
    perform pg_advisory_xact_lock(app.loyalty_fence_key_v480(b))
       from unnest(array[b_a,b_b,b_c,b_d,b_e,b_i]) b;
  end if;

  /* Creating a business mints its four programme spine rows. Set exactly one active per case;
     I8 says configuration decides, so the fixture configures rather than the reader guessing. */
  update public.business_programmes set active=false where business_id in (b_a,b_b,b_c,b_d,b_e,b_i);

  -- CASE A: live POINTS, dormant STAMPS  (a stamps -> points switch)
  update public.business_programmes set active=true  where business_id=b_a and kind='points';
  select id into v_live from public.business_programmes where business_id=b_a and kind='points';
  select id into v_dorm from public.business_programmes where business_id=b_a and kind='stamps';
  perform pg_temp.seed_pot(b_a,c_a1,v_live,200);   -- live points
  perform pg_temp.seed_pot(b_a,c_a1,v_live,-61);   -- net 139 live points
  perform pg_temp.seed_pot(b_a,c_a1,v_dorm,801);   -- 801 dormant stamps
  perform pg_temp.seed_pot(b_a,c_a2,v_live,45);    -- CASE N isolation
  insert into _fixture values
    ('A',b_a,c_a1,'points',139,'points','139 live points beside 801 dormant stamps; never 940'),
    ('N',b_a,c_a2,'points',45,'points','second customer in the same business is unaffected');

  -- CASE B: live STAMPS, dormant POINTS  (a points -> stamps switch)
  update public.business_programmes set active=true where business_id=b_b and kind='stamps';
  select id into v_live from public.business_programmes where business_id=b_b and kind='stamps';
  select id into v_dorm from public.business_programmes where business_id=b_b and kind='points';
  perform pg_temp.seed_pot(b_b,c_b,v_live,15);
  perform pg_temp.seed_pot(b_b,c_b,v_dorm,116);
  insert into _fixture values ('B',b_b,c_b,'stamps',15,'stamps','15 live stamps beside 116 dormant points; never 131');

  -- CASE C: live points only, with earn + redeem (CASE K) and an adjustment (CASE J)
  update public.business_programmes set active=true where business_id=b_c and kind='points';
  select id into v_live from public.business_programmes where business_id=b_c and kind='points';
  perform pg_temp.seed_pot(b_c,c_c,v_live,500);
  perform pg_temp.seed_pot(b_c,c_c,v_live,-200);
  perform pg_temp.seed_pot(b_c,c_c,v_live,30);
  insert into _fixture values ('C/K/J',b_c,c_c,'points',330,'points','500 earned - 200 redeemed + 30 adjusted');

  -- CASE D: live stamps only
  update public.business_programmes set active=true where business_id=b_d and kind='stamps';
  select id into v_live from public.business_programmes where business_id=b_d and kind='stamps';
  perform pg_temp.seed_pot(b_d,c_d,v_live,7);
  insert into _fixture values ('D',b_d,c_d,'stamps',7,'stamps','stamps business shows stamps');

  -- CASE E + H: two dormant pots, active pot NETS TO ZERO
  update public.business_programmes set active=true where business_id=b_e and kind='points';
  select id into v_live from public.business_programmes where business_id=b_e and kind='points';
  perform pg_temp.seed_pot(b_e,c_e,v_live,60);
  perform pg_temp.seed_pot(b_e,c_e,v_live,-60);
  perform pg_temp.seed_pot(b_e,c_e,bp.id,250) from public.business_programmes bp
   where bp.business_id=b_e and bp.kind='stamps';
  insert into _fixture values ('E/H',b_e,c_e,'points',0,'points','active pot nets to zero; 250 dormant stamps must not surface');

  -- CASE M: the same customer id in a DIFFERENT business must be isolated
  select id into v_live from public.business_programmes where business_id=b_c and kind='points';
  insert into _fixture values ('M',b_d,c_d,'stamps',7,'stamps','same client uuid, different business, different answer');

  /* app.programme_balance_scope_v312 flips a WHOLE TENANT to the unscoped 'business_pot' fallback
     if any client's ledger net disagrees with their batch remaining. A fixture that seeded ledger
     rows alone would therefore be testing the fallback, not the contract — the first run of this
     file did exactly that and the canonical primitive "failed" for the wrong reason. Real tenants
     are consistent (Cubbly: 9 client/programme pairs, 0 mismatched), so the fixture mirrors that
     and keeps every case on the scoped path. The fallback itself is recorded separately as
     LOYALTY-008: when scope resolution is unsafe the primitive silently sums incompatible pots,
     which contradicts invariants I1-I3. That is a product decision, not something this file
     changes unilaterally. */
  insert into public.points_batches (business_id, client_id, programme_id, earned, remaining, earned_at)
  select pl.business_id, pl.client_id, pl.programme_id,
         greatest(sum(pl.points),0), sum(pl.points), now()
    from public.points_ledger pl
   where pl.business_id in (b_a,b_b,b_c,b_d,b_e,b_i)
   group by pl.business_id, pl.client_id, pl.programme_id
  having sum(pl.points) <> 0;

  /* The real customer-facing reader resolves the customer through
     auth.uid() -> app.v31_current_identity() -> public.customer_links(state='verified'), and reads
     its unit from an ACTIVE public.loyalty_programs row. Seeding all three lets the fixture call
     customer_get_business_presentation_v95 ITSELF rather than re-implementing its query — the
     first draft of this file simulated the reader inline, which meant that assertion could never
     pass no matter what the fix did. A simulated reader proves nothing about the reader. */
  insert into auth.users (id, email) values (v_auth,'zz-loyalty-fixture@example.test')
  on conflict (id) do nothing;
  insert into public.customer_identities (id, auth_user_id, status)
  values (v_ident, v_auth, 'active') on conflict (id) do nothing;

  /* public.customer_links is guarded by v31_link_immutable_guard: a link may only be created by a
     route that declares the row id in app.customer_link_insert_id, and only in the 'verified'
     shape. The fixture declares each row the way a real claim route does. */
  declare v_link uuid; begin
    for v_link, v_bid, v_cid in
      select gen_random_uuid(), x.b, x.c from (values (b_a,c_a1),(b_b,c_b),(b_c,c_c),(b_d,c_d),(b_e,c_e)) x(b,c)
    loop
      perform set_config('app.customer_link_insert_id', v_link::text, true);
      insert into public.customer_links (id, business_id, identity_id, auth_user_id, client_id,
                                         state, verification_method, verified_at)
      values (v_link, v_bid, v_ident, v_auth, v_cid, 'verified', 'phone_claim', now());
    end loop;
  end;

  insert into public.loyalty_programs (business_id, loyalty_model, active, configuration_status)
  /* loyalty_model is one of classic | points_tiers | stamps; v95 maps anything that is not
     'stamps' to the unit 'points'. A points business is therefore 'points_tiers' here. */
  values (b_a,'points_tiers',true,'published'),(b_b,'stamps',true,'published'),
         (b_c,'points_tiers',true,'published'),(b_d,'stamps',true,'published'),
         (b_e,'points_tiers',true,'published')
  on conflict do nothing;

  -- CASE I: no active programme at all  -- CASE I: no active programme at all
  perform pg_temp.seed_pot(b_i,c_i,bp.id,90) from public.business_programmes bp
   where bp.business_id=b_i and bp.kind='points';
  -- deliberately no _fixture row: case I is asserted separately, since its contract is "refuse"
end
$loyalty$;

-- ============================ ASSERTIONS ============================
-- 1. The canonical primitive matches the hand-derived literal for every case.
insert into _fail
select f.case_id,
       format('canonical app.client_points_balance_v409 returned %s, fixture says %s (%s)',
              app.client_points_balance_v409(f.business_id, f.client_id), f.expect_bal, f.note)
from _fixture f
where app.client_points_balance_v409(f.business_id, f.client_id) is distinct from f.expect_bal;

-- 2. I8: the live pot the resolver picks must be the one the business configured active.
insert into _fail
select f.case_id,
       format('live pot resolved to kind %s, business is configured for %s',
              coalesce((select bp.kind from public.business_programmes bp
                         where bp.id = app.live_balance_programme_v381(f.business_id)),'<none>'),
              f.expect_unit)
from _fixture f
where coalesce((select bp.kind from public.business_programmes bp
                 where bp.id = app.live_balance_programme_v381(f.business_id)),'<none>')
      is distinct from f.expect_unit;

-- 3. I1/I2/I3: the naive all-pot sum must NOT equal the contract wherever a dormant pot exists.
--    This is the assertion that would have caught the production defect: it proves the fixture
--    actually contains contamination, so a passing test cannot be a vacuous one.
insert into _fail
select f.case_id,
       format('fixture is toothless: all-pot sum %s equals the expected %s, so this case cannot detect pot bleed',
              (select coalesce(sum(pl.points),0) from public.points_ledger pl
                where pl.business_id=f.business_id and pl.client_id=f.client_id), f.expect_bal)
from _fixture f
where f.case_id in ('A','B','E/H')
  and (select coalesce(sum(pl.points),0) from public.points_ledger pl
        where pl.business_id=f.business_id and pl.client_id=f.client_id) = f.expect_bal;

-- 4. THE LIVE READER, actually invoked. customer_get_business_presentation_v95 is the
--    customer-facing one (app/app.js:12590). It is called as the seeded customer, and BOTH the
--    balance and its unit are checked: a number without its unit is not proof (I4/I5).
do $reader$
declare r record; v_payload jsonb; v_bal integer; v_unit text; v_found boolean;
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub','00000000-0000-4000-8000-0000000000a1','role','authenticated')::text, true);
  for r in select * from _fixture where case_id in ('A','B','C/K/J','D','E/H') loop
    v_bal := null; v_unit := null; v_found := false;
    begin
      v_payload := public.customer_get_business_presentation_v95(r.business_id, null, 'en');
    exception when others then
      insert into _fail values (r.case_id, 'reader v95 raised: '||sqlerrm);
      continue;
    end;
    select (value->>'balance')::integer, value->>'unit', true
      into v_bal, v_unit, v_found
      from jsonb_each(v_payload) where value ? 'balance' and value ? 'unit' limit 1;
    if not coalesce(v_found,false) then
      insert into _fail values (r.case_id,
        'reader v95 returned no balance/unit pair: '||left(v_payload::text,200));
    else
      if v_bal is distinct from r.expect_bal then
        insert into _fail values (r.case_id,
          format('LIVE READER v95 balance=%s, contract says %s (%s)', v_bal, r.expect_bal, r.note));
      end if;
      if v_unit is distinct from r.expect_unit then
        insert into _fail values (r.case_id,
          format('LIVE READER v95 unit=%s, business is configured for %s', v_unit, r.expect_unit));
      end if;
    end if;
  end loop;
end
$reader$;

-- 5. CASE I: no active programme. The resolver must return NULL rather than guessing a pot.
insert into _fail
select 'I',
       format('with no active programme the live pot resolved to %s; the reader must not guess',
              app.live_balance_programme_v381('00000000-0000-4000-8000-00000000a006'::uuid))
where app.live_balance_programme_v381('00000000-0000-4000-8000-00000000a006'::uuid) is not null;

-- 6. I6: no implicit conversion. Assert no case's expected balance is a scaled version of the
--    dormant pot, which is what a conversion would look like.
insert into _fail
select f.case_id, 'expected balance equals the DORMANT pot total — a conversion or a swap'
from _fixture f
where f.expect_bal <> 0
  and f.expect_bal = (select coalesce(sum(pl.points),0) from public.points_ledger pl
                       where pl.business_id=f.business_id and pl.client_id=f.client_id
                         and pl.programme_id is distinct from app.live_balance_programme_v381(f.business_id));

select case when count(*)=0
         then 'PASS — LOYALTY_CURRENT_BALANCE_V1 holds for every fixture case'
         else 'FAIL' end as verdict,
       count(*) as failures
from _fail;

select case_id, detail from _fail order by case_id;

do $verdict$
declare v integer;
begin
  select count(*) into v from _fail;
  if v > 0 then
    raise exception 'LOYALTY_CURRENT_BALANCE_V1: % assertion(s) failed - see the rows above', v;
  end if;
end
$verdict$;

rollback;
