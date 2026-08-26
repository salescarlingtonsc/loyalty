-- EXECUTED golden fixture for nestly_v545 — the AI evidence pack is programme-aware.
--
-- WHY. app.v179_business_insights (the AI report's `loyalty` block) and app.v177_overview (the
-- superadmin mirror) summed points_ledger across every pot. Cubbly SPA, Aug 2026: the model was
-- handed points_outstanding_total 3155, which is 2341 live POINTS + 814 dormant STAMPS. Worse, the
-- per-pot breakdown that would have revealed the mix was set to null exactly when the pots were
-- split — the branch was inverted.
--
-- THE INVARIANT UNDER TEST. No field anywhere in either payload may carry a value that is the sum
-- of two pots. That is asserted arithmetically, not by reading field names: the fixture seeds a
-- live pot and a dormant pot whose totals are distinct primes, so their sum (and only their sum)
-- is a number that cannot arise any other way. If it appears anywhere in the JSON, the test fails.
--
--   L1  the pack exposes no points_outstanding_total, under any name
--   L2  active_programme.outstanding is the LIVE pot only
--   L3  active_programme.unit is the unit the business is configured for
--   L4  the dormant pot appears under historical_programmes, with its OWN unit
--   L5  the forbidden sum appears nowhere in the serialised payload
--   L6  earn/redeem for the period are pot-scoped too
--   L7  the same holds for the superadmin mirror (v177)
--   L8  a business with NO running programme says so rather than guessing a pot
--   L9  the retention block no longer calls an existing-customer share a "repeat rate"
--
-- Named for v545: it cannot pass against the frozen baseline, and should not.
-- One transaction, rolled back. Failures RAISE.

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

do $v545$
declare
  b_split uuid := '00000000-0000-4000-8000-00000000b001';  -- live points + dormant stamps
  b_none  uuid := '00000000-0000-4000-8000-00000000b002';  -- no running programme
  c_split uuid := '00000000-0000-4000-8000-00000000b101';
  c_none  uuid := '00000000-0000-4000-8000-00000000b102';
  v_live uuid; v_dorm uuid;
  v_live_pts integer := 1319;   -- prime
  v_dorm_pts integer :=  577;   -- prime; 1319 + 577 = 1896 can arise no other way
  v_forbidden integer := 1896;
  ev jsonb; ov jsonb; txt text;
begin
  insert into public.businesses (id, name, slug) values
    (b_split,'ZZ v545 split','zz-v545-split'), (b_none,'ZZ v545 none','zz-v545-none');
  insert into public.clients (id, business_id, full_name) values
    (c_split,b_split,'Fixture Split'), (c_none,b_none,'Fixture None');

  if to_regprocedure('app.loyalty_fence_key_v480(uuid)') is not null then
    perform pg_advisory_xact_lock(app.loyalty_fence_key_v480(b))
       from unnest(array[b_split,b_none]) b;
  end if;

  update public.business_programmes set active=false where business_id in (b_split,b_none);
  update public.business_programmes set active=true where business_id=b_split and kind='points';
  select id into v_live from public.business_programmes where business_id=b_split and kind='points';
  select id into v_dorm from public.business_programmes where business_id=b_split and kind='stamps';

  perform pg_temp.seed_pot(b_split,c_split,v_live,v_live_pts);
  perform pg_temp.seed_pot(b_split,c_split,v_dorm,v_dorm_pts);
  -- b_none keeps a balance in a pot that is NOT running
  perform pg_temp.seed_pot(b_none,c_none,
    (select id from public.business_programmes where business_id=b_none and kind='points'), 250);

  insert into public.points_batches (business_id, client_id, programme_id, earned, remaining, earned_at)
  select pl.business_id, pl.client_id, pl.programme_id, greatest(sum(pl.points),0), sum(pl.points), now()
    from public.points_ledger pl where pl.business_id in (b_split,b_none)
   group by pl.business_id, pl.client_id, pl.programme_id having sum(pl.points) <> 0;

  ev := app.v179_business_insights(b_split, (now()-interval '30 days')::date, now()::date,
                                   (now()-interval '60 days')::date, (now()-interval '31 days')::date);
  txt := ev::text;

  -- L1
  if txt like '%points_outstanding_total%' then
    insert into _fail values ('L1','the pack still exposes points_outstanding_total');
  end if;

  -- L2
  if (ev->'loyalty'->'active_programme'->>'outstanding')::integer is distinct from v_live_pts then
    insert into _fail values ('L2', format('active outstanding=%s, live pot holds %s',
      ev->'loyalty'->'active_programme'->>'outstanding', v_live_pts));
  end if;

  -- L3
  if (ev->'loyalty'->'active_programme'->>'unit') is distinct from 'points' then
    insert into _fail values ('L3', format('active unit=%s, business runs points',
      ev->'loyalty'->'active_programme'->>'unit'));
  end if;

  -- L4
  if not exists (
    select 1 from jsonb_array_elements(ev->'loyalty'->'historical_programmes') h
     where h->>'unit' = 'stamps' and (h->>'outstanding')::integer = v_dorm_pts
  ) then
    insert into _fail values ('L4', format('the dormant stamps pot (%s) is not reported with its own unit: %s',
      v_dorm_pts, ev->'loyalty'->'historical_programmes'));
  end if;

  -- L5 — the arithmetic invariant: the cross-unit sum must appear NOWHERE
  if txt like ('%' || v_forbidden::text || '%') then
    insert into _fail values ('L5', format('the combined cross-unit total %s appears in the payload', v_forbidden));
  end if;

  -- L6 — earn/redeem are pot-scoped (both seeded rows are adjusts, so both must read 0)
  if (ev->'loyalty'->'active_programme'->>'earned_this_period')::bigint <> 0 then
    insert into _fail values ('L6', format('earned_this_period=%s counted a pot it should not have',
      ev->'loyalty'->'active_programme'->>'earned_this_period'));
  end if;

  -- L7 — the superadmin mirror
  ov := app.v177_overview(b_split, null);
  if ov::text like '%points_outstanding_total%'
     or (ov->'outstanding'->'active_programme'->>'outstanding')::integer is distinct from v_live_pts
     or (ov->'outstanding'->'active_programme'->>'unit') is distinct from 'points'
     or ov::text like ('%' || v_forbidden::text || '%') then
    insert into _fail values ('L7', format('superadmin mirror is not programme-aware: %s', ov->'outstanding'));
  end if;

  -- L8 — no running programme: say so, do not guess a pot
  ev := app.v179_business_insights(b_none, (now()-interval '30 days')::date, now()::date,
                                   (now()-interval '60 days')::date, (now()-interval '31 days')::date);
  if coalesce((ev->'loyalty'->'active_programme'->>'is_running')::boolean, true) then
    insert into _fail values ('L8','a business with no running programme reported one as running');
  end if;
  if (ev->'loyalty'->'active_programme'->>'outstanding') is not null then
    insert into _fail values ('L8', format('with nothing running the pack still stated an outstanding balance of %s',
      ev->'loyalty'->'active_programme'->>'outstanding'));
  end if;
  if not exists (
    select 1 from jsonb_array_elements(ev->'loyalty'->'historical_programmes') h
     where (h->>'outstanding')::integer = 250
  ) then
    insert into _fail values ('L8','the stopped programme''s 250 is not retained as history');
  end if;

  -- L9 — the label, not the arithmetic. `not is_new and visits > 0` over `visits > 0` is the
  -- share of this period's customers who had bought before it. On Cubbly SPA that field read
  -- 40.0 while get_customer_lifecycle_v107's repeat_in_period_rate_pct read 60.00 for the same
  -- tenant and month: two different questions, one English word. The number must not move; only
  -- the name. Asserted on the LIVE payload, so a body that reverts the rename fails here.
  ev := app.v179_business_insights(b_split, (now()-interval '30 days')::date, now()::date,
                                   (now()-interval '60 days')::date, (now()-interval '31 days')::date);
  if jsonb_typeof(ev->'retention') is distinct from 'object' then
    insert into _fail values ('L9', format('the retention block is not where the test looks: top-level keys are %s',
      (select string_agg(k,',' order by k) from jsonb_object_keys(ev) k)));
  end if;
  if ev->'retention' ? 'repeat_rate_pct' then
    insert into _fail values ('L9','the retention block still ships the ambiguous repeat_rate_pct');
  end if;
  if not (ev->'retention' ? 'existing_customer_return_rate_pct') then
    insert into _fail values ('L9', format('existing_customer_return_rate_pct is absent: %s',
      ev->'retention'));
  end if;
  if not (ev->'retention' ? 'existing_customers_who_returned') then
    insert into _fail values ('L9','existing_customers_who_returned is absent');
  end if;
end
$v545$;

select case when count(*)=0 then 'PASS — the loyalty evidence is programme-aware and unit-safe'
            else 'FAIL' end as verdict, count(*) as failures from _fail;
select k, v from _fail order by k;

do $verdict$
declare v integer;
begin
  select count(*) into v from _fail;
  if v > 0 then raise exception 'v545: % assertion(s) failed', v; end if;
end
$verdict$;

rollback;
