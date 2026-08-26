-- Rollback-only acceptance for nestly_v545 — the AI evidence pack is programme-aware and unit-safe.
-- Run: supabase db query --linked -f db/tests/v545_programme_aware_loyalty_evidence.sql
-- Any row whose value starts with FAIL is a failure. Nothing is committed.
--
-- v545 did two things to app.v179_business_insights (the AI report's evidence) and, for the loyalty
-- half, app.v177_overview (the superadmin mirror):
--
--   (a) the `loyalty` block stopped summing every programme pot. Cubbly SPA was handing the model
--       points_outstanding_total 3155 = 2341 live POINTS + 814 dormant STAMPS, a figure with no
--       unit, while the per-pot breakdown that would have revealed the mix was set to null exactly
--       when the pots were split. There is now no total at all, by design.
--   (b) `repeat_rate_pct` was renamed to `existing_customer_return_rate_pct`. NO ARITHMETIC MOVED.
--       The field always computed the share of a period's customers who had bought before it; the
--       name invited the model to narrate it as a repeat rate, and it did: production report
--       522fa492 reads "Repeat rate this month is 0%. All 3 customers served were new" for a month
--       in which one customer visited fifteen times.
--
--   01  no live business is handed a cross-programme loyalty total, under any field name
--   02  for every split-pot business, active_programme.outstanding equals the live pot alone
--   03  active_programme.unit always matches the business's own running programme kind
--   04  no payload contains the arithmetic sum of two pots
--   05  the superadmin mirror agrees with the AI pack, business by business
--   06  the retention rename is name-only: the value equals the pre-v545 expression exactly
--   07  a business with no running programme reports is_running=false, not a guessed pot
--
-- ROLLBACK OF THE MIGRATION ITSELF: both functions were patched by text substitution from their
-- live bodies; the replaced fragments are quoted verbatim in the migration file. To revert, restore
-- those fragments. Reverting restores a cross-unit total in the model's evidence and is only
-- appropriate if the programme-aware shape is itself found faulty. Note the edge function's system
-- prompt ships alongside and refers to active_programme/historical_programmes by name — reverting
-- the SQL without reverting supabase/functions/ai-firm-reports/index.ts leaves the model reading
-- fields that no longer exist.

begin;

create temp table _r(check_id text, value text) on commit drop;

-- 01 — no cross-programme total anywhere in either function's source or output
insert into _r
select '01 no cross-programme total field',
       case when count(*) = 0 then 'PASS'
            else 'FAIL ' || string_agg(proname, ', ') end
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'app' and p.proname in ('v179_business_insights','v177_overview')
   and pg_get_functiondef(p.oid) like '%points_outstanding_total%';

-- 02/03/04/07 — walk every live business and interrogate the real payload
do $probe$
declare
  b record; ev jsonb; live_pot bigint; live_prog uuid; live_kind text; bad integer := 0; note text := '';
begin
  for b in
    select bs.id, bs.name from public.businesses bs
     where exists (select 1 from public.points_ledger pl where pl.business_id = bs.id)
     order by bs.name
  loop
    ev := app.v179_business_insights(b.id, (current_date - 30), current_date,
                                     (current_date - 60), (current_date - 31))->'loyalty';
    live_prog := app.live_balance_programme_v381(b.id);
    select bp.kind into live_kind from public.business_programmes bp where bp.id = live_prog;
    select coalesce(sum(points),0) into live_pot from public.points_ledger
     where business_id = b.id and programme_id is not distinct from live_prog;

    if live_prog is null then
      -- 07: nothing running must be stated, not guessed
      if coalesce((ev->'active_programme'->>'is_running')::boolean, true)
         or (ev->'active_programme'->>'outstanding') is not null then
        bad := bad + 1; note := note || format('[%s stated a pot with nothing running] ', b.name);
      end if;
    else
      -- 02
      if coalesce((ev->'active_programme'->>'outstanding')::bigint, -1) <> live_pot then
        bad := bad + 1;
        note := note || format('[%s outstanding=%s live pot=%s] ',
          b.name, ev->'active_programme'->>'outstanding', live_pot);
      end if;
      -- 03
      if (ev->'active_programme'->>'unit') is distinct from live_kind then
        bad := bad + 1;
        note := note || format('[%s unit=%s programme kind=%s] ',
          b.name, ev->'active_programme'->>'unit', live_kind);
      end if;
      -- 04: the sum of the live pot and any single dormant pot must appear nowhere
      if exists (
        select 1 from public.points_ledger pl
         where pl.business_id = b.id and pl.programme_id is distinct from live_prog
         group by pl.programme_id
        having ev::text like ('%' || (live_pot + sum(pl.points))::text || '%')
           and sum(pl.points) <> 0
      ) then
        bad := bad + 1; note := note || format('[%s payload contains a cross-pot sum] ', b.name);
      end if;
    end if;
  end loop;

  insert into _r values ('02-04,07 per-business pot truth',
    case when bad = 0 then 'PASS' else format('FAIL %s problem(s): %s', bad, note) end);
end
$probe$;

-- 05 — the superadmin mirror must not disagree with the AI pack
do $mirror$
declare b record; a jsonb; m jsonb; bad integer := 0; note text := '';
begin
  for b in
    select bs.id, bs.name from public.businesses bs
     where exists (select 1 from public.points_ledger pl where pl.business_id = bs.id)
  loop
    a := app.v179_business_insights(b.id, (current_date - 30), current_date,
                                    (current_date - 60), (current_date - 31))->'loyalty'->'active_programme';
    m := app.v177_overview(b.id, null)->'outstanding'->'active_programme';
    if (a->>'outstanding') is distinct from (m->>'outstanding')
       or (a->>'unit') is distinct from (m->>'unit') then
      bad := bad + 1;
      note := note || format('[%s pack=%s/%s mirror=%s/%s] ', b.name,
        a->>'outstanding', a->>'unit', m->>'outstanding', m->>'unit');
    end if;
  end loop;
  insert into _r values ('05 mirror agrees with pack',
    case when bad = 0 then 'PASS' else format('FAIL %s: %s', bad, note) end);
end
$mirror$;

-- 06 — the rename moved a name, not a number. Recompute the pre-v545 expression independently
--      (share of the window's transacting customers who were NOT new) and demand equality.
do $rename$
declare b record; ev jsonb; expected numeric; bad integer := 0; note text := '';
begin
  for b in select id, name from public.businesses order by name limit 40 loop
    ev := app.v179_business_insights(b.id, (current_date - 30), current_date,
                                     (current_date - 60), (current_date - 31))->'retention';

    if ev ? 'repeat_rate_pct' then
      bad := bad + 1; note := note || format('[%s still ships repeat_rate_pct] ', b.name); continue;
    end if;
    if not (ev ? 'existing_customer_return_rate_pct') then
      bad := bad + 1; note := note || format('[%s is missing the renamed field] ', b.name); continue;
    end if;

    -- Independent recomputation of the pre-v545 expression from raw rows. This does NOT call
    -- v179: it rebuilds the definition the field always had (a customer is "new" when their first
    -- ever counts_as_visit sale falls inside the window), replicating v179's own reversal filter
    -- and its Asia/Singapore bounds with an inclusive end date, so exact equality is demanded.
    with ls as (
      select s.client_id, s.occurred_at, s.counts_as_visit
        from public.sales s
       where s.business_id = b.id and s.reversal_of is null and s.client_id is not null
         and not exists (select 1 from public.sales r
                          where r.business_id = s.business_id and r.reversal_of = s.id)
    ), first_seen as (
      select client_id, min(occurred_at) filter (where counts_as_visit) as first_visit_at
        from ls group by client_id
    ), wc as (
      select ls.client_id,
             count(*) filter (where ls.counts_as_visit) as visits,
             bool_and(first_seen.first_visit_at
                      >= (current_date - 30)::timestamp at time zone 'Asia/Singapore') as is_new
        from ls join first_seen on first_seen.client_id = ls.client_id
       where ls.occurred_at >= (current_date - 30)::timestamp at time zone 'Asia/Singapore'
         and ls.occurred_at <  (current_date + 1)::timestamp at time zone 'Asia/Singapore'
       group by ls.client_id
    )
    select case when count(*) filter (where visits > 0) = 0 then null
                else round(100.0 * count(*) filter (where not is_new and visits > 0)
                           / count(*) filter (where visits > 0), 1) end
      into expected from wc;

    if (ev->>'existing_customer_return_rate_pct')::numeric is distinct from expected then
      bad := bad + 1;
      note := note || format('[%s renamed field=%s independently computed=%s] ',
        b.name, ev->>'existing_customer_return_rate_pct', expected);
    end if;
  end loop;
  insert into _r values ('06 rename is name-only',
    case when bad = 0 then 'PASS' else format('FAIL %s: %s', bad, note) end);
end
$rename$;

select check_id, value from _r order by check_id;

rollback;
