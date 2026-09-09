-- EXECUTED golden fixture for nestly_v555 — an untrustworthy pot shows NO balance (LOYALTY-008,
-- owner ruling: fail-closed).
--
-- SUPERSEDED by nestly_v804 (20261006) and nestly_v815 (20261007) — see below. The fixture is
-- kept and updated rather than deleted because B1/B2/B5 (the scope-detection plumbing) are still
-- exactly right; only the B3/B4 fail-closed EXPECTATION changed.
--
-- app.programme_balance_scope_v312 says 'business_pot' when pot data cannot be trusted (a pot
-- migration in flight, or ledger/batches disagreeing). At the time v555 was written the readers
-- responded to that by summing NOTHING (0) — the fail-closed ruling this fixture encoded.
--
-- nestly_v804 (F079) later found that same "sum nothing" predicate in
-- app.client_points_balance_v409 and public.staff_list_customers_v155 (among others) and treated
-- it AS THE BUG: "'business_pot' means 'sum every programme'; the expression says 'sum nothing'."
-- It flipped the predicate so business_pot now sums every pot — precisely the 1319+577=1896
-- merge this fixture was written to prove could never reappear. nestly_v815 then went further and
-- made the same merged total SPENDABLE at redemption. Both are owner-reviewed, production-proved
-- migrations, not accidents; LOYALTY-008's fail-closed contract for these two readers is no
-- longer the product's behaviour.
--
-- Seeded like v545: a live points pot of 1319 and a dormant stamps pot of 577, both primes, so
-- the merged figure 1896 can arise no other way — this fixture now asserts that 1896 IS what
-- surfaces once the scope drops to business_pot (v804's rule), not that it is suppressed.
--
--   B1  healthy tenant: v409 returns the LIVE pot (1319) — unaffected by v804/v815
--   B2  a pending pot migration flips the scope to business_pot
--   B3  under business_pot, v409 now returns the MERGED pot 1896 (nestly_v804 F079 fix)
--   B4  staff_list_customers_v155 (the live directory RPC, executed for real under a seeded
--       owner) shows the same 1896 — staff and primitive still agree, now on the merged total
--   B5  the migration resolving (status='complete') restores the live-pot answer untouched
--
-- One transaction, rolled back.

\set ON_ERROR_STOP on

begin;

create temp table _fail(k text, v text) on commit drop;

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

do $v555$
declare
  b uuid := '00000000-0000-4000-8000-0000000a5001';
  c1 uuid := '00000000-0000-4000-8000-0000000a5101';
  u uuid := '00000000-0000-4000-8000-0000000a5201';
  v_live uuid; v_dorm uuid; v_mig uuid; bal integer; res jsonb; listed bigint;
begin
  insert into auth.users (id, email) values (u, 'zz-v555-owner@example.test');
  insert into public.businesses (id, name, slug) values (b,'ZZ v555 pot','zz-v555-pot');
  update public.business_workspace_controls_v94
     set approval_status='approved', decided_at=now(), decision_reason='v555 fixture approval'
   where business_id=b;
  -- v620: business_operational_v620 additionally requires a paid (or trialing) subscriptions
  -- row on top of the approved workspace above.
  insert into public.subscriptions (business_id, status, payment_status, current_period_end)
  values (b, 'active', 'paid', now() + interval '30 days')
  on conflict (business_id) do update
    set status='active', payment_status='paid', current_period_end=now() + interval '30 days';
  insert into public.staff (business_id, user_id, role, full_name, active)
  values (b, u, 'owner', 'Fixture Owner', true);
  insert into public.clients (id, business_id, full_name) values (c1,b,'Fixture Prue');

  if to_regprocedure('app.loyalty_fence_key_v480(uuid)') is not null then
    perform pg_advisory_xact_lock(app.loyalty_fence_key_v480(b));
  end if;
  update public.business_programmes set active=false where business_id=b;
  update public.business_programmes set active=true where business_id=b and kind='points';
  select id into v_live from public.business_programmes where business_id=b and kind='points';
  select id into v_dorm from public.business_programmes where business_id=b and kind='stamps';

  perform pg_temp.seed_pot(b, c1, v_live, 1319);
  perform pg_temp.seed_pot(b, c1, v_dorm,  577);
  insert into public.points_batches (business_id, client_id, programme_id, earned, remaining, earned_at)
  select pl.business_id, pl.client_id, pl.programme_id, greatest(sum(pl.points),0), sum(pl.points), now()
    from public.points_ledger pl where pl.business_id = b
   group by 1,2,3 having sum(pl.points) <> 0;

  -- B1 — healthy: the live pot, exactly
  if app.programme_balance_scope_v312(b) is distinct from 'programme_pot' then
    insert into _fail values ('B1', format('seed is not healthy: scope=%s', app.programme_balance_scope_v312(b)));
  end if;
  bal := app.client_points_balance_v409(b, c1);
  if bal is distinct from 1319 then
    insert into _fail values ('B1', format('healthy balance=%s, expected the live pot 1319', bal));
  end if;

  -- B2 — a pending pot migration drops the trust signal
  insert into public.programme_pot_migrations (business_id, from_programme_id, to_programme_id, status)
  values (b, v_dorm, v_live, 'pending') returning id into v_mig;
  if app.programme_balance_scope_v312(b) is distinct from 'business_pot' then
    insert into _fail values ('B2', format('pending migration did not flip the scope: %s',
      app.programme_balance_scope_v312(b)));
  end if;

  -- B3 — nestly_v804 (F079): business_pot means "sum every programme", so the merged 1896 is now
  -- the correct answer here, not the fail-closed 0 this fixture asserted before v804.
  bal := app.client_points_balance_v409(b, c1);
  if bal is distinct from 1896 then
    insert into _fail values ('B3', format('untrusted pot returned %s, expected the merged pot 1896 (nestly_v804)', bal));
  end if;

  -- B4 — the live directory RPC agrees, executed for real, on the same merged total (nestly_v804)
  perform set_config('request.jwt.claim.sub', u::text, true);
  perform set_config('request.jwt.claims', json_build_object(
    'sub',u,'role','authenticated','aud','authenticated')::text, true);
  res := public.staff_list_customers_v155(b, null, null, 'all', array[]::uuid[], null, 100, 0);
  select (customer->>'points')::bigint into listed
    from jsonb_array_elements(res->'customers') customer
   where customer->>'id' = c1::text;
  if listed is distinct from 1896 then
    insert into _fail values ('B4', format('the directory lists %s while the pot is untrusted, expected the merged pot 1896 (nestly_v804)', listed));
  end if;

  -- B5 — trust restored, answer restored
  update public.programme_pot_migrations set status='complete', completed_at=now() where id=v_mig;
  bal := app.client_points_balance_v409(b, c1);
  if bal is distinct from 1319 then
    insert into _fail values ('B5', format('after the migration completed the balance is %s, expected 1319', bal));
  end if;
end
$v555$;

select case when count(*)=0 then 'PASS — business_pot scope sums every pot (nestly_v804/v815)'
            else 'FAIL' end as verdict, count(*) as failures from _fail;
select k, v from _fail order by k;

do $verdict$
declare v integer;
begin
  select count(*) into v from _fail;
  if v > 0 then raise exception 'v555: % assertion(s) failed', v; end if;
end
$verdict$;

rollback;
