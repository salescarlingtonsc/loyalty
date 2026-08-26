-- EXECUTED golden fixture for nestly_v555 — an untrustworthy pot shows NO balance (LOYALTY-008,
-- owner ruling: fail-closed).
--
-- app.programme_balance_scope_v312 says 'business_pot' when pot data cannot be trusted (a pot
-- migration in flight, or ledger/batches disagreeing). The readers used to respond by summing
-- every pot — the cross-unit merge of the 940-for-139 incident. Now no row qualifies.
--
-- Seeded like v545: a live points pot of 1319 and a dormant stamps pot of 577, both primes, so
-- the merged figure 1896 can arise no other way — if it appears after the trust signal drops,
-- the merge branch is back.
--
--   B1  healthy tenant: v409 returns the LIVE pot (1319) — the ruling changed nothing here
--   B2  a pending pot migration flips the scope to business_pot
--   B3  under business_pot, v409 returns 0 — never 1896, never 1319-over-untrusted-tags
--   B4  staff_list_customers_v155 (the live directory RPC, executed for real under a seeded
--       owner) shows the same 0 — staff and primitive agree while the pots are untrusted
--   B5  the migration resolving (status='complete') restores the live-pot answer untouched
--
-- Named for v555: B3 and B4 must FAIL against the frozen baseline (which answers 1896).
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

  -- B3 — fail closed: zero, never the merge
  bal := app.client_points_balance_v409(b, c1);
  if bal = 1896 then
    insert into _fail values ('B3','the cross-unit merge is back: 1319 + 577 = 1896 was returned');
  elsif bal is distinct from 0 then
    insert into _fail values ('B3', format('untrusted pot returned %s, expected 0', bal));
  end if;

  -- B4 — the live directory RPC agrees, executed for real
  perform set_config('request.jwt.claim.sub', u::text, true);
  perform set_config('request.jwt.claims', json_build_object(
    'sub',u,'role','authenticated','aud','authenticated')::text, true);
  res := public.staff_list_customers_v155(b, null, null, 'all', array[]::uuid[], null, 100, 0);
  select (customer->>'points')::bigint into listed
    from jsonb_array_elements(res->'customers') customer
   where customer->>'id' = c1::text;
  if listed is distinct from 0 then
    insert into _fail values ('B4', format('the directory lists %s while the pot is untrusted, expected 0', listed));
  end if;

  -- B5 — trust restored, answer restored
  update public.programme_pot_migrations set status='complete', completed_at=now() where id=v_mig;
  bal := app.client_points_balance_v409(b, c1);
  if bal is distinct from 1319 then
    insert into _fail values ('B5', format('after the migration completed the balance is %s, expected 1319', bal));
  end if;
end
$v555$;

select case when count(*)=0 then 'PASS — an untrustworthy pot shows no balance'
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
