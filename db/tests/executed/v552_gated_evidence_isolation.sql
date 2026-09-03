-- EXECUTED golden fixture for nestly_v552 — gated sections fail alone, name themselves, and the
-- account-opens clamp survives a future period end.
--
-- WHY. app.v176_gated_evidence wrapped four consultative RPCs in one `when others` that discarded
-- the error: one failure removed all four sections and told the model nothing. In production the
-- failing one was account_opens' correct no-future-dates guard meeting the monthly pack's future
-- month-end — every mid-month monthly report silently lost all four sections.
--
--   G1  a FUTURE period end now yields all four sections, with the clamp disclosed
--   G2  isolation: ONE stubbed-to-fail RPC loses exactly its own section; the other three
--       survive, and unavailable_sections names the casualty with a sqlstate (never sqlerrm)
--   G3  the evidence pack passes unavailable_sections through evidence_completeness and
--       carries the clamp disclosure under account_opens.report_range
--
-- The isolation stub is created INSIDE this rolled-back transaction, so nothing persists.
-- Named for v552: G1-G3 must FAIL against the frozen baseline. One transaction, rolled back.

\set ON_ERROR_STOP on

begin;

create temp table _fail(k text, v text) on commit drop;

do $v552$
declare
  b uuid := '00000000-0000-4000-8000-00000000e001';
  c1 uuid := '00000000-0000-4000-8000-00000000e101';
  sa uuid := '00000000-0000-4000-8000-00000000e201';
  d_from date := current_date - 10;
  d_to_future date := current_date + 3;   -- a "month end" that has not happened yet
  g jsonb; pack jsonb;
begin
  -- the drain path impersonates the first super admin; the harness has none, so seed one
  insert into auth.users (id, email) values (sa, 'zz-v552-sa@example.test');
  insert into public.super_admins (user_id, email) values (sa, 'zz-v552-sa@example.test');

  insert into public.businesses (id, name, slug) values (b,'ZZ v552 gated','zz-v552-gated');
  insert into public.clients (id, business_id, full_name) values (c1,b,'Fixture Gale');
  insert into public.sales (business_id, client_id, kind, amount_cents, occurred_at) values
    (b, c1, 'quick_sale', 900, (current_date - 2)::timestamp at time zone 'Asia/Singapore');

  -- G1 — future period end: all four sections, clamp disclosed
  g := app.v176_gated_evidence(b, d_from, d_to_future);
  if not coalesce((g->>'available')::boolean, false) then
    insert into _fail values ('G1', format('future period end still sinks the sections: %s / %s',
      g->>'reason', g->'unavailable_sections'));
  end if;
  if g->'account_opens_report' is null or jsonb_typeof(g->'account_opens_report') = 'null' then
    insert into _fail values ('G1','account_opens_report is missing despite the clamp');
  end if;
  if not coalesce((g->'account_opens_range'->>'clamped')::boolean, false)
     or (g->'account_opens_range'->>'effective_to')::date is distinct from
        (now() at time zone 'Asia/Singapore')::date
     or (g->'account_opens_range'->>'requested_to')::date is distinct from d_to_future then
    insert into _fail values ('G1', format('clamp not disclosed honestly: %s', g->'account_opens_range'));
  end if;

  -- G2 — isolation: stub ONE rpc to fail, inside this rolled-back transaction
  create or replace function public.platform_get_catalogue_affinity_v94(
    p_business uuid, p_branch uuid, p_from date, p_to date, p_limit integer default 25)
  returns jsonb language plpgsql as $stub$
  begin
    raise exception 'v552 fixture stub failure';
  end
  $stub$;

  g := app.v176_gated_evidence(b, d_from, d_to_future);
  if coalesce((g->>'available')::boolean, true) then
    insert into _fail values ('G2','available stayed true with a failing section');
  end if;
  if (g->>'reason') is distinct from 'sections_unavailable' then
    insert into _fail values ('G2', format('reason=%s, expected sections_unavailable', g->>'reason'));
  end if;
  if jsonb_typeof(g->'catalogue_affinity') is distinct from 'null' then
    insert into _fail values ('G2','the failing section still delivered a payload');
  end if;
  /* recommendations CALLS catalogue affinity internally, so stubbing affinity legitimately
     takes recommendations down with it - a real dependency this fixture documents rather than
     denies. The isolation claim is about the two INDEPENDENT sections surviving. */
  if jsonb_typeof(g->'consultant_brief') = 'null' or g->'consultant_brief' is null
     or jsonb_typeof(g->'account_opens_report') = 'null' then
    insert into _fail values ('G2','an INDEPENDENT healthy section was lost with the failing one — isolation is broken');
  end if;
  if (select coalesce(string_agg(u->>'section', ',' order by u->>'section'), '')
        from jsonb_array_elements(g->'unavailable_sections') u)
     is distinct from 'catalogue_affinity,recommendations'
     or exists (select 1 from jsonb_array_elements(g->'unavailable_sections') u
                 where coalesce(u->>'sqlstate','') = '') then
    insert into _fail values ('G2', format('unavailable_sections wrong: %s', g->'unavailable_sections'));
  end if;
  if g::text like '%v552 fixture stub failure%' then
    insert into _fail values ('G2','sqlerrm text leaked into the payload — only sqlstate may appear');
  end if;

  -- G3 — the pack passes it through (stub still failing)
  -- NESTLY v720: app.v176_evidence_pack now gates a sessionless caller on
  -- app.v676_internal_drain_active() (belt-and-braces alongside its owner-only ACL). The real
  -- production caller opens this window itself (public.internal_claim_ai_firm_report_v176, see
  -- db/migrations/20260920_nestly_v720_evidence_pack_grants.sql step 2b); this fixture calls the
  -- function directly, one layer inside that worker, so it opens the same window.
  perform app.v676_open_internal_drain();
  pack := app.v176_evidence_pack(b, 'monthly', d_from, d_to_future);
  perform app.v676_close_internal_drain();
  if not exists (
    select 1 from jsonb_array_elements(pack->'evidence_completeness'->'unavailable_sections') u
     where u->>'section' = 'catalogue_affinity'
  ) then
    insert into _fail values ('G3', format('evidence_completeness does not name the withheld section: %s',
      pack->'evidence_completeness'));
  end if;
  if jsonb_typeof(pack->'account_opens'->'report_range') is distinct from 'object' then
    insert into _fail values ('G3','account_opens.report_range is missing from the pack');
  end if;
  if jsonb_typeof(pack->'consultant_brief') = 'null' then
    insert into _fail values ('G3','the pack lost a healthy section');
  end if;
end
$v552$;

select case when count(*)=0 then 'PASS — gated sections fail alone and name themselves'
            else 'FAIL' end as verdict, count(*) as failures from _fail;
select k, v from _fail order by k;

do $verdict$
declare v integer;
begin
  select count(*) into v from _fail;
  if v > 0 then raise exception 'v552: % assertion(s) failed', v; end if;
end
$verdict$;

rollback;
