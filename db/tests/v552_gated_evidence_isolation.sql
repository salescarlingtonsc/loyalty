-- Rollback-only acceptance for nestly_v552 — a gated section fails alone, names itself, and the
-- account-opens clamp ends a production outage.
-- Run: supabase db query --linked -f db/tests/v552_gated_evidence_isolation.sql
-- Any row whose value starts with FAIL is a failure. Nothing is committed.
--
-- This runs against PRODUCTION, unauthenticated (auth.uid() is null), so app.v176_gated_evidence
-- takes its drain-impersonation path: it borrows the first row of public.super_admins as reader
-- and restores the prior JWT claims before returning. That path is exercised here as-is — no
-- session is set up by this suite.
--
-- v552 rewrote app.v176_gated_evidence so each of the four consultative sections
-- (consultant_brief, catalogue_affinity, recommendations, account_opens_report) runs in its own
-- exception handler — one failure loses one section, recorded in unavailable_sections as
-- {section, sqlstate} (sqlstate only, never sqlerrm) — and clamps the account-opens range end to
-- the current Singapore date, disclosed under account_opens_range {requested_to, effective_to,
-- clamped}. app.v176_evidence_pack was patched to carry unavailable_sections through
-- evidence_completeness and the clamp disclosure through account_opens.report_range.
--
-- Before v552: a single `exception when others` around all four sections meant that
-- platform_customer_account_opens_v175's correct no-future-dates guard (22023), tripped every
-- time a monthly pack handed it the month's future last day, discarded ALL FOUR sections and
-- returned {available:false}. Every mid-month monthly report in production was silently missing
-- its whole consultative payload.
--
--   01  for every live business with sales, app.v176_gated_evidence(b.id, <current SGT month
--       start>, <current SGT month end>) — a CURRENT-month range whose end is in the future —
--       returns available=true, all four section keys non-null, and account_opens_range.clamped
--       =true with effective_to equal to the current SGT date. Before v552 this returned
--       available=false for every business.
--   02  unavailable_sections is an empty JSON array in the same result — the key EXISTS (not
--       merely absent) and is distinct from null/missing.
--   03  app.v176_evidence_pack(b.id, 'monthly', <same range>) has
--       evidence_completeness.gated_rpcs_available=true,
--       evidence_completeness.unavailable_sections=[], account_opens.report_range.clamped=true,
--       and consultant_brief/catalogue_affinity/recommendations all non-null.
--   04  no sqlerrm text anywhere: the serialized gated result contains neither 'fixture' nor
--       'exception' (cheap tripwire against an sqlerrm leak), and every element of
--       unavailable_sections (if any) has exactly the keys section and sqlstate — nothing else.
--
-- ROLLBACK OF THE MIGRATION ITSELF: v552 replaced app.v176_gated_evidence wholesale (CREATE OR
-- REPLACE), so reverting it means restoring the pre-v552 body verbatim from the migration's own
-- header description: one `exception when others` wrapping the assembly of all four sections,
-- returning `{available:false, reason:'evidence_rpc_unavailable'}` on any failure, with no
-- unavailable_sections key and no account-opens clamp (p_to passed straight through to
-- platform_customer_account_opens_v175). Re-apply that single-handler body via CREATE OR REPLACE
-- to roll back the function; then reverse the two regexp_replace patches to app.v176_evidence_pack
-- by dropping the `report_range` key from account_opens and the `unavailable_sections` key from
-- evidence_completeness (restated as plain `'gated_rpcs_reason', v_gated->>'reason'`). The system
-- prompt in supabase/functions/ai-firm-reports/index.ts ships alongside this migration; reverting
-- the SQL without reverting the prompt leaves the model told to consult keys that no longer exist.

begin;

create temp table _r(check_id text, value text) on commit drop;

-- 01 — current-month range (future end) now succeeds, all four sections present, clamp honest
do $avail$
declare
  b record; ev jsonb;
  d_from date; d_to date; today_sgt date;
  bad integer := 0; note text := '';
begin
  today_sgt := (pg_catalog.now() at time zone 'Asia/Singapore')::date;
  d_from := pg_catalog.date_trunc('month', today_sgt)::date;
  d_to := (pg_catalog.date_trunc('month', today_sgt) + interval '1 month - 1 day')::date;

  for b in
    select bs.id, bs.name from public.businesses bs
     where exists (select 1 from public.sales s where s.business_id = bs.id)
     order by bs.name
  loop
    ev := app.v176_gated_evidence(b.id, d_from, d_to);

    if not coalesce((ev->>'available')::boolean, false) then
      bad := bad + 1;
      note := note || pg_catalog.format('[%s available=%s reason=%s] ',
        b.name, ev->>'available', ev->>'reason');
      continue;
    end if;

    if ev->'consultant_brief' is null or jsonb_typeof(ev->'consultant_brief') = 'null'
       or ev->'catalogue_affinity' is null or jsonb_typeof(ev->'catalogue_affinity') = 'null'
       or ev->'recommendations' is null or jsonb_typeof(ev->'recommendations') = 'null'
       or ev->'account_opens_report' is null or jsonb_typeof(ev->'account_opens_report') = 'null'
    then
      bad := bad + 1;
      note := note || pg_catalog.format('[%s a section is null: brief=%s affinity=%s recs=%s opens=%s] ',
        b.name, jsonb_typeof(ev->'consultant_brief'), jsonb_typeof(ev->'catalogue_affinity'),
        jsonb_typeof(ev->'recommendations'), jsonb_typeof(ev->'account_opens_report'));
    end if;

    if not coalesce((ev->'account_opens_range'->>'clamped')::boolean, false)
       or (ev->'account_opens_range'->>'effective_to')::date is distinct from today_sgt
    then
      bad := bad + 1;
      note := note || pg_catalog.format('[%s clamp not honest: %s (today_sgt=%s)] ',
        b.name, ev->'account_opens_range', today_sgt);
    end if;
  end loop;

  insert into _r values ('01 current-month future-end range now available, all sections present',
    case when bad = 0 then 'PASS' else pg_catalog.format('FAIL %s: %s', bad, note) end);
end
$avail$;

-- 02 — unavailable_sections is an empty array (key EXISTS, distinct from absent/null)
do $empty$
declare
  b record; ev jsonb;
  d_from date; d_to date; today_sgt date;
  bad integer := 0; note text := '';
begin
  today_sgt := (pg_catalog.now() at time zone 'Asia/Singapore')::date;
  d_from := pg_catalog.date_trunc('month', today_sgt)::date;
  d_to := (pg_catalog.date_trunc('month', today_sgt) + interval '1 month - 1 day')::date;

  for b in
    select bs.id, bs.name from public.businesses bs
     where exists (select 1 from public.sales s where s.business_id = bs.id)
     order by bs.name
  loop
    ev := app.v176_gated_evidence(b.id, d_from, d_to);

    if not (ev ? 'unavailable_sections') then
      bad := bad + 1;
      note := note || pg_catalog.format('[%s unavailable_sections key absent] ', b.name);
    elsif jsonb_typeof(ev->'unavailable_sections') is distinct from 'array' then
      bad := bad + 1;
      note := note || pg_catalog.format('[%s unavailable_sections is %s, not an array] ',
        b.name, jsonb_typeof(ev->'unavailable_sections'));
    elsif pg_catalog.jsonb_array_length(ev->'unavailable_sections') <> 0 then
      bad := bad + 1;
      note := note || pg_catalog.format('[%s unavailable_sections not empty: %s] ',
        b.name, ev->'unavailable_sections');
    end if;
  end loop;

  insert into _r values ('02 unavailable_sections is an empty array (present, not absent)',
    case when bad = 0 then 'PASS' else pg_catalog.format('FAIL %s: %s', bad, note) end);
end
$empty$;

-- 03 — the evidence pack passes availability + clamp disclosure through
do $pack$
declare
  b record; pack jsonb; comp jsonb; opens jsonb;
  d_from date; d_to date;
  bad integer := 0; note text := '';
begin
  d_from := pg_catalog.date_trunc('month',
    (pg_catalog.now() at time zone 'Asia/Singapore')::date)::date;
  d_to := (pg_catalog.date_trunc('month',
    (pg_catalog.now() at time zone 'Asia/Singapore')::date) + interval '1 month - 1 day')::date;

  for b in
    select bs.id, bs.name from public.businesses bs
     where exists (select 1 from public.sales s where s.business_id = bs.id)
     order by bs.name
  loop
    pack := app.v176_evidence_pack(b.id, 'monthly', d_from, d_to);
    comp := pack->'evidence_completeness';
    opens := pack->'account_opens';

    if not coalesce((comp->>'gated_rpcs_available')::boolean, false) then
      bad := bad + 1;
      note := note || pg_catalog.format('[%s gated_rpcs_available=%s] ', b.name,
        comp->>'gated_rpcs_available');
    end if;

    if not (comp ? 'unavailable_sections')
       or jsonb_typeof(comp->'unavailable_sections') is distinct from 'array'
       or pg_catalog.jsonb_array_length(comp->'unavailable_sections') <> 0 then
      bad := bad + 1;
      note := note || pg_catalog.format('[%s evidence_completeness.unavailable_sections=%s] ',
        b.name, comp->'unavailable_sections');
    end if;

    if opens is null or jsonb_typeof(opens->'report_range') is distinct from 'object'
       or not coalesce((opens->'report_range'->>'clamped')::boolean, false) then
      bad := bad + 1;
      note := note || pg_catalog.format('[%s account_opens.report_range=%s] ',
        b.name, opens->'report_range');
    end if;

    if pack->'consultant_brief' is null or jsonb_typeof(pack->'consultant_brief') = 'null'
       or pack->'catalogue_affinity' is null or jsonb_typeof(pack->'catalogue_affinity') = 'null'
       or pack->'recommendations' is null or jsonb_typeof(pack->'recommendations') = 'null'
    then
      bad := bad + 1;
      note := note || pg_catalog.format('[%s pack missing a healthy section: brief=%s affinity=%s recs=%s] ',
        b.name, jsonb_typeof(pack->'consultant_brief'), jsonb_typeof(pack->'catalogue_affinity'),
        jsonb_typeof(pack->'recommendations'));
    end if;
  end loop;

  insert into _r values ('03 evidence pack carries availability + clamp disclosure',
    case when bad = 0 then 'PASS' else pg_catalog.format('FAIL %s: %s', bad, note) end);
end
$pack$;

-- 04 — no sqlerrm leakage, and unavailable_sections elements carry exactly {section, sqlstate}
do $noleak$
declare
  b record; ev jsonb; serialized text;
  elem jsonb; keys text;
  d_from date; d_to date;
  bad integer := 0; note text := '';
begin
  d_from := pg_catalog.date_trunc('month',
    (pg_catalog.now() at time zone 'Asia/Singapore')::date)::date;
  d_to := (pg_catalog.date_trunc('month',
    (pg_catalog.now() at time zone 'Asia/Singapore')::date) + interval '1 month - 1 day')::date;

  for b in
    select bs.id, bs.name from public.businesses bs
     where exists (select 1 from public.sales s where s.business_id = bs.id)
     order by bs.name
  loop
    ev := app.v176_gated_evidence(b.id, d_from, d_to);
    serialized := ev::text;

    if serialized ilike '%fixture%' or serialized ilike '%exception%' then
      bad := bad + 1;
      note := note || pg_catalog.format('[%s payload contains a raw-error tripwire term] ', b.name);
    end if;

    if ev ? 'unavailable_sections' and jsonb_typeof(ev->'unavailable_sections') = 'array' then
      for elem in select * from jsonb_array_elements(ev->'unavailable_sections')
      loop
        select string_agg(k, ',' order by k) into keys
          from jsonb_object_keys(elem) k;
        if keys is distinct from 'section,sqlstate' then
          bad := bad + 1;
          note := note || pg_catalog.format('[%s unavailable_sections element keys=%s elem=%s] ',
            b.name, keys, elem);
        end if;
      end loop;
    end if;
  end loop;

  insert into _r values ('04 no sqlerrm leakage; unavailable_sections elements are section+sqlstate only',
    case when bad = 0 then 'PASS' else pg_catalog.format('FAIL %s: %s', bad, note) end);
end
$noleak$;

select check_id, value from _r order by check_id;

rollback;
