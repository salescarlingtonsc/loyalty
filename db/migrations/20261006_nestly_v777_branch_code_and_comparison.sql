-- NESTLY v777 — every branch gets a human code, and the branches can be compared side by side.
--
-- Contract: docs/design/ci/CI-STAT-AUTHORITY-CONTRACT.md (v672, frozen). Envelope: the v680
-- family as re-emitted by nestly_v693 (app.ci_envelope_v680 + app.ci_exclusion_counts_v680).
-- Visit-day authority: app.ci_visit_day_v699. Gate: app.ci_access_gate_v667 as widened by
-- nestly_v721. Fixture guide: docs/qa/CI-CORPUS-FIXTURE-GUIDE.md.
-- Proven by db/tests/executed/v777_corpus_branch_code_and_comparison.sql (predetermined truth
-- table, exact assertions, rolled back).
--
-- WHAT THIS ADDS
--
--   public.branches.code                    a short human label, unique inside the firm
--   app.branch_code_backfill_v777()         codes every branch that has none, deterministically
--   app.branch_code_default_v777()          BEFORE INSERT: fills a null code with the next Bnn
--   public.get_ci_branch_directory_v1       which outlets exist, and what they are called
--   public.get_ci_branch_comparison_v1      how the outlets compare over one window
--
-- ---------------------------------------------------------------------------------------------
-- DESIGN DECISIONS
-- ---------------------------------------------------------------------------------------------
--
-- 1. A COMPANY ALREADY HAS A HUMAN CODE: businesses.slug. No second column is added for the
--    firm. Only the branch was unnamed in any short, stable, speakable way — "the Tampines one"
--    is not a key an owner can put on a receipt, a rota or a comparison table. code is that key.
--
-- 2. THE CODE SHAPE IS ^[A-Z0-9]{2,8}$ AND THE UNIQUENESS IS PER FIRM. Two firms may both call
--    their flagship 'MAIN'; one firm may not. The check is deliberately permissive about what an
--    owner may LATER rename a branch to (any 2-8 upper alphanumerics) and deliberately exact
--    about what the system GENERATES ('B' + a zero-padded ordinal). Lowercase is refused rather
--    than silently upcased: an owner who types 'main' should be told, not quietly overruled, and
--    the generator never produces a value the check could reject.
--
-- 3. THE BACKFILL IS DETERMINISTIC, IT IS A RULE RATHER THAN AN ACCIDENT, AND IT IS A FUNCTION
--    RATHER THAN A ONE-OFF STATEMENT. Inside each business the uncoded branches are ordered
--    (is_default desc, created_at, id) and numbered upward from the firm's highest existing Bnn:
--    on a virgin estate every firm's highest is 0, so the numbering starts at B01, B02, B03 ...
--    The default branch is always B01 because it is the one the firm was born with (nestly_v11a
--    §1.6/§1.9) and the one every branch-less sale still lands on (app.set_row_branch);
--    created_at then id makes the rest total and reproducible, which is what lets the fixture
--    assert 'B02' rather than "some code".
--
--    IT IS app.branch_code_backfill_v777(), CALLED ONCE HERE, AND THAT IS DELIBERATE. Written
--    inline as a bare UPDATE it would have been untestable: an acceptance fixture runs AFTER the
--    migration, so by then every branch already has a code and every assertion about the
--    ordering is vacuous — measured, not assumed (the first draft of this fixture asserted
--    exactly that and stayed green when the `is_default desc` was removed from the ordering,
--    because the harness database holds no branch older than the fixture's own). As a function
--    the rule can be driven again, over rows whose codes have been deliberately cleared, with a
--    default branch that is NOT the earliest created — a shape the BEFORE INSERT trigger can
--    never produce and therefore can never prove. It is also idempotent and re-runnable by
--    construction: it only ever touches `code is null`, and it numbers upward from what a firm
--    already holds, so a re-run never reuses or reassigns a code.
--
-- 4. THE TRIGGER FILLS, IT NEVER OVERWRITES. A caller that supplies a code keeps it, verbatim —
--    that is what makes the four existing writers of public.branches safe: public.create_branch
--    (nestly_v202/v280), public.create_business (v11a §1.9), the onboarding/activation RPCs
--    (v79/v130/v167/v169/v510/v565) and the v11a backfill all insert without naming `code`, so
--    every one of them now gets a generated one for free and none of them changes. v202's
--    `insert ... returning * into v_branch` even carries the new code straight back into the
--    RPC's own JSON response, unmodified.
--
--    NEXT-FREE MEANS max(existing numeric suffix) + 1, NOT count + 1. A firm whose B02 was
--    renamed 'MAIN' has {B01, MAIN, B03}; count+1 would produce B03 and collide. The generator
--    reads only codes matching ^B[0-9]+$, takes the largest, and adds one, so a renamed or
--    hand-chosen code can never make the next generated one collide. Padding is lpad(n, 2, '0'),
--    which is 'B01'..'B99' and then naturally 'B100', 'B101' — the width grows, the prefix does
--    not, and the check constraint has room to 'B9999999'. app.branch_code_backfill_v777() is the
--    same rule applied to a SET — highest existing Bnn plus the row's ordinal — which is why the
--    two agree by construction rather than by coincidence; the fixture nonetheless drives both
--    against one firm and asserts they never collide, because "by construction" is exactly the
--    kind of claim that stops being true after an edit.
--
--    CONCURRENCY, STATED RATHER THAN PRETENDED AWAY: two simultaneous inserts for the same firm
--    can both read the same maximum and both propose the same code. The unique index is the
--    authority; the loser gets 23505 and retries. A firm adds a branch a few times a year, so a
--    serialising advisory lock would cost more than it buys.
--
-- 5. RENAMING A CODE NEEDS NO NEW RPC. An owner already passes the branches UPDATE policy, and
--    the check constraint plus the unique index are the whole rule: an UPDATE to a code another
--    branch of the same firm already holds fails with 23505, and a malformed one with 23514.
--    Adding a rename RPC now would be a second authority for a rule the table already enforces.
--
-- 6. THE TWO READERS GATE THROUGH app.ci_access_gate_v667, BUSINESS-WIDE, AND THEN AGAIN PER
--    BRANCH. The first call is app.ci_access_gate_v667(p_business, null) — the same firm-wide
--    entitlement every other business-wide CI reader asks for (the v650 quartet,
--    get_ci_demographic_totals_v1, get_ci_visit_rhythm_v1). The second is the SAME GATE, once per
--    branch, wrapped in an exception block that swallows exactly 42501 and nothing else:
--
--        begin  perform app.ci_access_gate_v667(p_business, v_id);  ... visible
--        exception when insufficient_privilege then null;  ... hidden
--
--    This deliberately does NOT restate the rule. nestly_v721 put branch scope inside the gate
--    (`auth.uid() is not null and not app.v176_can_read_firm_report(...) and not
--    app.can_see_branch(...)`), and that predicate has three arms — the sessionless internal
--    drain (v713), the platform arm (super admin or assigned consultant, neither of whom holds a
--    staff row and so is refused by app.can_see_branch), and the merchant arm. Re-deriving it
--    here with app.can_see_branch alone would hide EVERY branch from a consultant and from the
--    drain. Calling the gate itself cannot drift from the gate.
--
--    CONSEQUENCE, MEASURED AND ACCEPTED: today no caller can reach these readers and still be
--    missing a branch. v721's own firm-wide rule refuses a branch-restricted employee at the
--    FIRST gate call (p_branch null resolves app.can_see_branch to owner/admin/super-admin only),
--    and everyone who survives it — owner, admin-class role, super admin, assigned consultant,
--    the drain — sees every branch. So `branches_hidden` is 0 for every caller the product can
--    produce right now. It is emitted, and the per-branch gate is run, because the alternative is
--    a reader that silently starts leaking the day the firm-wide rule is relaxed. The fixture
--    proves the refusal that is actually reachable (a branch-restricted employee is refused
--    outright, 42501) rather than asserting a partial view no principal can currently hold.
--
-- 7. ONE QUALIFYING-SALE PREDICATE, THE SAME ONE v772 SPELLED OUT. business, `s.created_at <=
--    p_as_of`, `s.reversal_of is null`, no surviving reversal gated on p_as_of, a non-synthetic
--    client, at least one of counts_as_visit / counts_as_revenue, and
--    `app.ci_visit_day_v699(s.occurred_at) between p_from and p_to`. Per branch it gains exactly
--    `s.branch_id = <this branch>`. Nothing else differs, so a branch's `visits` is the subset of
--    get_ci_visit_rhythm_v1's own window total that carries that branch id.
--
-- 8. THE VISIT GRAIN IS THE SALE ROW, IDENTICAL TO get_ci_visit_rhythm_v1. `visits` is
--    `count(*) filter (where counts_as_visit)`, not distinct customer-days: the two readers
--    answer the same question at the same grain and must agree, and `business.visits` here equals
--    that reader's `current.visits` for the same window (nestly_v775). `customers` is the
--    distinct IDENTIFIED count — an anonymous ticket is a visit and is not a person.
--
-- 9. NEW CUSTOMERS ARE FIRST-EVER, FIRM-WIDE, ATTRIBUTED TO THE BRANCH THAT SAW THEM. A customer
--    is new to the firm once. The lookup takes every qualifying VISIT the customer ever made at
--    this business — no branch filter, no window floor, only `created_at <= p_as_of` — orders it
--    (visit_day, occurred_at, id) and keeps the first row. That row's branch gets the credit, and
--    only if its visit-day falls inside [p_from, p_to]. Deliberately firm-wide: a customer whose
--    first visit was at the Tampines outlet is not "new" to Jurong the following week, and
--    counting them twice is exactly the double-count the payload's own limitation warns about for
--    `customers`. The first-ever lookup is NOT restricted to branches the caller can see —
--    "first ever" is a fact about the customer, not about the reader — but a first visit at a
--    hidden branch simply credits no visible branch, so nothing leaks.
--
-- 10. SHARES ARE MEASURED AGAINST THE WHOLE FIRM, AND THE REMAINDER IS NAMED. share_of_visits and
--    share_of_revenue are app.rate_block_v1 over `business.visits` / `business.revenue_cents`,
--    which are business-wide: every branch, including one the caller cannot see, plus every
--    qualifying sale that carries no branch id at all. The shares therefore need not sum to 100,
--    and rather than leave that unexplained the payload emits `branches_hidden` and
--    `unattributed_visits` beside them. A denominator that quietly shrank to "the branches you
--    happen to see" would make each branch look larger than it is.
--
-- 11. DEMOGRAPHICS COME FROM THE GATE-FREE CORE, exactly as get_ci_demographic_totals_v1 reads
--    them: app.customer_demographics_core_v674(business, client), never the merchant-only
--    app.customer_demographics_v1 wrapper (v674 decision 8 — this reader has already cleared the
--    CI gate and double-gating would 42501 an entitled consultant). The per-branch population is
--    that branch's identified visiting customers; `unknown_gender` sits OUTSIDE the share
--    denominator, which is the known-population rule v694 froze and v772 followed.
--
-- 12. NO BARE PERCENTAGE. Every rate travels as app.rate_block_v1 and every pct is NULL — never
--    0.0 — below the k=5 evidence floor, nulled with jsonb_set so numerator and denominator still
--    travel and a suppressed cell stays auditable. `top_age_band` is the band with the most
--    customers ONLY when that band's own app.subgroup_evidence_v1 is 'ok'; otherwise null, never
--    a two-customer band dressed up as a finding.
--
-- 13. WEEKDAYS USE THE k=4 OCCURRENCE FLOOR, get_ci_visit_rhythm_v1's floor, for the same reason:
--    the subject is how many times a weekday OCCURRED in the window, and four Mondays is the
--    smallest count from which "Mondays are quiet here" is worth saying. per_occurrence is a
--    count per day at 1dp, not a percentage. A weekday with zero visits still ranks — a branch
--    that is shut on Sunday is precisely what "slowest" should surface — and both fields are null
--    when no weekday clears the floor (a window shorter than four weeks).
--
-- 14. top_item GROUPS THE WAY get_ci_demographic_totals_v1.by_item GROUPS: by
--    (coalesce(ref_id, product_id), description, item_type) over the revenue-counting lines of
--    IDENTIFIED sales, so `buyers` is a distinct-customer count and an anonymous ticket
--    contributes neither a buyer nor revenue to the item. Ordered revenue desc, then description,
--    then item id; null when the branch sold no identified line at all.
--
-- 15. NO NEW TABLES, NO NEW HELPERS BEYOND THE TRIGGER, NO WRITES BY THE READERS. One column, one
--    check, one unique index, one deterministic backfill, one BEFORE INSERT trigger, two
--    read-only SECURITY DEFINER functions expressed against existing frozen authorities.
--
-- ROLLBACK: drop trigger trg_branches_code_default_v777 on public.branches; drop function
-- app.branch_code_default_v777(); drop function app.branch_code_backfill_v777(); drop function
-- public.get_ci_branch_comparison_v1(uuid,date,date,timestamptz); drop function
-- public.get_ci_branch_directory_v1(uuid); drop index public.branches_code_unique_v777;
-- alter table public.branches drop constraint branches_code_shape_v777; alter table
-- public.branches drop column code.

begin;

-- ---------------------------------------------------------------------------------------------
-- 1 · public.branches.code — the column, the shape, the uniqueness.
-- ---------------------------------------------------------------------------------------------
alter table public.branches add column if not exists code text;

comment on column public.branches.code is
  'nestly_v777: a short human label for this outlet, unique inside the business. Generated as '
  'B01, B02, ... by app.branch_code_default_v777() when an insert omits it; an owner may rename '
  'it to any 2-8 character A-Z0-9 string through a normal UPDATE.';

-- The deterministic backfill (decision 3), as a function so that the rule can be executed —
-- and therefore proven — after this migration has already run.
create or replace function app.branch_code_backfill_v777()
returns integer
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_rows integer;
begin
  with taken as (
    -- what each firm already holds, so a re-run numbers upward instead of reusing
    select br.business_id,
           coalesce(max((substring(br.code from '^B([0-9]+)$'))::integer), 0) as high
      from public.branches br
     where br.code ~ '^B[0-9]+$'
     group by br.business_id
  ),
  ranked as (
    select br.id, br.business_id,
           row_number() over (partition by br.business_id
                              order by br.is_default desc, br.created_at, br.id) as ordinal
      from public.branches br
     where br.code is null
  )
  update public.branches b
     set code = 'B' || lpad((coalesce(t.high, 0) + r.ordinal)::text, 2, '0')
    from ranked r
    left join taken t on t.business_id = r.business_id
   where b.id = r.id
     and b.code is null;
  get diagnostics v_rows = row_count;
  return v_rows;
end;
$$;
revoke all on function app.branch_code_backfill_v777() from public, anon, authenticated;

-- On this estate every branch is uncoded, so every firm's `high` is 0 and the numbering starts
-- at B01. Idempotent: a second call touches nothing, because nothing is null any more.
select app.branch_code_backfill_v777();

alter table public.branches
  drop constraint if exists branches_code_shape_v777;
alter table public.branches
  add constraint branches_code_shape_v777
  check (code is null or code ~ '^[A-Z0-9]{2,8}$');

create unique index if not exists branches_code_unique_v777
  on public.branches (business_id, code);

-- ---------------------------------------------------------------------------------------------
-- 2 · app.branch_code_default_v777 — fill a null code, never touch a supplied one.
-- ---------------------------------------------------------------------------------------------
create or replace function app.branch_code_default_v777()
returns trigger
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_next integer;
begin
  -- Decision 4: a supplied code is the caller's, verbatim. Only a null one is generated.
  if new.code is not null then
    return new;
  end if;
  -- max(numeric suffix) + 1, over this firm's generated-shape codes only, so a renamed branch
  -- can never make the next generated code collide.
  select coalesce(max((substring(br.code from '^B([0-9]+)$'))::integer), 0) + 1
    into v_next
    from public.branches br
   where br.business_id = new.business_id
     and br.code ~ '^B[0-9]+$';
  new.code := 'B' || lpad(v_next::text, 2, '0');
  return new;
end;
$$;
revoke all on function app.branch_code_default_v777() from public, anon, authenticated;

drop trigger if exists trg_branches_code_default_v777 on public.branches;
create trigger trg_branches_code_default_v777
  before insert on public.branches
  for each row execute function app.branch_code_default_v777();

-- ---------------------------------------------------------------------------------------------
-- 3 · public.get_ci_branch_directory_v1 — which outlets exist, and what they are called.
-- ---------------------------------------------------------------------------------------------
create or replace function public.get_ci_branch_directory_v1(p_business uuid)
returns jsonb
language plpgsql stable security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_id      uuid;
  v_visible uuid[] := array[]::uuid[];
  v_result  jsonb;
begin
  perform app.ci_access_gate_v667(p_business, null);

  -- Decision 6: the same gate, once per branch. 42501 means "not yours to see"; anything else
  -- is a fault and propagates.
  for v_id in
    select br.id from public.branches br where br.business_id = p_business order by br.id
  loop
    begin
      perform app.ci_access_gate_v667(p_business, v_id);
      v_visible := v_visible || v_id;
    exception when insufficient_privilege then
      null;
    end;
  end loop;

  select jsonb_build_object(
    'business', jsonb_build_object('id', b.id, 'name', b.name, 'slug', b.slug),
    'branches', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', br.id, 'code', br.code, 'name', br.name,
               'active', br.active, 'is_default', br.is_default)
             order by br.code, br.id)
        from public.branches br
       where br.business_id = p_business
         and br.id = any(v_visible)), '[]'::jsonb),
    'branches_hidden', (
      select count(*) from public.branches br
       where br.business_id = p_business and br.active and not (br.id = any(v_visible))),
    'code_rule',
      'A branch code is unique inside the business and is generated as B01, B02, ... when a '
      'branch is created without one. The company''s own code is its slug.',
    'evidence_class', 'DIRECT_FACT')
    into v_result
    from public.businesses b
   where b.id = p_business;

  if v_result is null then
    raise exception 'business not found' using errcode = '42501';
  end if;
  return v_result;
end;
$$;
revoke all on function public.get_ci_branch_directory_v1(uuid) from public, anon;
grant execute on function public.get_ci_branch_directory_v1(uuid) to authenticated, service_role;

-- ---------------------------------------------------------------------------------------------
-- 4 · public.get_ci_branch_comparison_v1 — how the outlets compare over one window.
-- ---------------------------------------------------------------------------------------------
create or replace function public.get_ci_branch_comparison_v1(
  p_business uuid, p_from date, p_to date,
  p_as_of timestamptz default clock_timestamp())
returns jsonb
language plpgsql stable security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_id      uuid;
  v_visible uuid[] := array[]::uuid[];
  v_hidden  bigint;
  v_result  jsonb;
begin
  perform app.ci_access_gate_v667(p_business, null);
  if p_from is null or p_to is null or p_from > p_to then
    raise exception 'invalid date range' using errcode = '22023';
  end if;

  for v_id in
    select br.id from public.branches br where br.business_id = p_business order by br.id
  loop
    begin
      perform app.ci_access_gate_v667(p_business, v_id);
      v_visible := v_visible || v_id;
    exception when insufficient_privilege then
      null;
    end;
  end loop;

  select count(*) into v_hidden
    from public.branches br
   where br.business_id = p_business and br.active and not (br.id = any(v_visible));

  with br as (
    -- ACTIVE branches the caller may see. A retired branch keeps its history and its directory
    -- row; it is not a thing to compare this window's trading on.
    select b.id, b.code, b.name, b.is_default
      from public.branches b
     where b.business_id = p_business and b.active and b.id = any(v_visible)
  ),
  scoped as (
    -- Decision 7: v772's qualifying-sale predicate, business-wide, once.
    select s.id, s.client_id, s.branch_id, s.amount_cents,
           app.ci_visit_day_v699(s.occurred_at)   as visit_day,
           coalesce(s.counts_as_visit, false)     as is_visit,
           coalesce(s.counts_as_revenue, false)   as is_revenue
      from public.sales s
      left join public.clients c on c.id = s.client_id
     where s.business_id = p_business
       and s.created_at <= p_as_of
       and s.reversal_of is null
       and not exists (select 1 from public.sales r
                        where r.reversal_of = s.id and r.created_at <= p_as_of)
       and not coalesce(c.is_synthetic, false)
       and (coalesce(s.counts_as_visit, false) or coalesce(s.counts_as_revenue, false))
       and app.ci_visit_day_v699(s.occurred_at) between p_from and p_to
  ),
  biz_tot as (
    select count(*) filter (where sc.is_visit)::bigint                              as visits,
           coalesce(sum(sc.amount_cents) filter (where sc.is_revenue), 0)::bigint    as revenue_cents,
           count(distinct sc.client_id) filter (where sc.is_visit
                                                  and sc.client_id is not null)::bigint
                                                                                     as customers,
           count(*) filter (where sc.is_visit and sc.branch_id is null)::bigint      as unattributed_visits
      from scoped sc
  ),
  cur as (
    select sc.* from scoped sc join br on br.id = sc.branch_id
  ),
  first_visit as (
    -- Decision 9: the customer's first-ever qualifying VISIT at this business, any branch.
    select distinct on (s.client_id)
           s.client_id, s.branch_id,
           app.ci_visit_day_v699(s.occurred_at) as visit_day
      from public.sales s
      join public.clients c on c.id = s.client_id
     where s.business_id = p_business
       and s.client_id is not null
       and s.created_at <= p_as_of
       and s.reversal_of is null
       and not exists (select 1 from public.sales r
                        where r.reversal_of = s.id and r.created_at <= p_as_of)
       and not coalesce(c.is_synthetic, false)
       and coalesce(s.counts_as_visit, false)
     order by s.client_id, app.ci_visit_day_v699(s.occurred_at), s.occurred_at, s.id
  ),
  new_cust as (
    select fv.branch_id, count(*)::bigint as new_customers
      from first_visit fv
     where fv.visit_day between p_from and p_to
       and fv.branch_id is not null
     group by fv.branch_id
  ),
  branch_agg as (
    select br.id as branch_id,
           count(c.id) filter (where c.is_visit)::bigint                            as visits,
           coalesce(sum(c.amount_cents) filter (where c.is_revenue), 0)::bigint     as revenue_cents,
           count(distinct c.client_id) filter (where c.is_visit
                                                 and c.client_id is not null)::bigint
                                                                                     as customers
      from br left join cur c on c.branch_id = br.id
     group by br.id
  ),
  branch_clients as (
    select distinct c.branch_id, c.client_id
      from cur c
     where c.is_visit and c.client_id is not null
  ),
  classified as (
    -- Decision 11: the gate-free v674 core, one call per (branch, customer).
    select bc.branch_id, bc.client_id,
           d.dem->>'gender'   as gender,
           d.dem->>'age_band' as age_band
      from branch_clients bc
      cross join lateral (
        select app.customer_demographics_core_v674(p_business, bc.client_id) as dem
      ) d
  ),
  dem_tot as (
    select cl.branch_id,
           count(*)::bigint                                       as customers,
           count(*) filter (where cl.gender is not null)::bigint   as gender_known,
           count(*) filter (where cl.age_band is not null)::bigint as age_known
      from classified cl group by cl.branch_id
  ),
  gender_rows as (
    select cl.branch_id, cl.gender, count(*)::bigint as customers
      from classified cl where cl.gender is not null group by cl.branch_id, cl.gender
  ),
  age_rows as (
    select cl.branch_id, cl.age_band, count(*)::bigint as customers
      from classified cl where cl.age_band is not null group by cl.branch_id, cl.age_band
  ),
  top_band as (
    select distinct on (ar.branch_id) ar.branch_id, ar.age_band, ar.customers
      from age_rows ar
     where app.subgroup_evidence_v1(ar.customers::int)->>'status' = 'ok'
     order by ar.branch_id, ar.customers desc,
              case ar.age_band
                when 'under_20' then 1 when '20_24' then 2 when '25_30' then 3
                when '31_40'    then 4 when '41_50' then 5 else 6 end,
              ar.age_band
  ),
  cal as (
    select d::date as the_day, extract(isodow from d)::int as dow
      from generate_series(p_from::timestamp, p_to::timestamp, interval '1 day') d
  ),
  weekday_occ as (
    select cal.dow, count(*)::bigint as occurrences from cal group by cal.dow
  ),
  branch_weekday as (
    select br.id as branch_id, g.dow,
           case g.dow when 1 then 'Monday' when 2 then 'Tuesday' when 3 then 'Wednesday'
                      when 4 then 'Thursday' when 5 then 'Friday' when 6 then 'Saturday'
                      else 'Sunday' end                                as label,
           count(c.id) filter (where c.is_visit)::bigint               as visits
      from br
      cross join generate_series(1, 7) as g(dow)
      left join cur c
        on c.branch_id = br.id
       and extract(isodow from c.visit_day)::int = g.dow
     group by br.id, g.dow
  ),
  branch_weekday_rows as (
    -- Decision 13: k=4 OCCURRENCES, and per_occurrence is a count per day, not a percentage.
    select bw.branch_id, bw.dow, bw.label, bw.visits, wo.occurrences,
           case when wo.occurrences > 0
                then round(bw.visits::numeric / wo.occurrences, 1) else null end as per_occurrence,
           app.subgroup_evidence_v1(wo.occurrences::int, 4) as evidence
      from branch_weekday bw
      join weekday_occ wo on wo.dow = bw.dow
  ),
  weekday_ranked as (
    select wr.* from branch_weekday_rows wr
     where wr.evidence->>'status' = 'ok' and wr.per_occurrence is not null
  ),
  busiest_wd as (
    select distinct on (q.branch_id) q.branch_id, q.label, q.per_occurrence
      from weekday_ranked q order by q.branch_id, q.per_occurrence desc, q.dow
  ),
  slowest_wd as (
    select distinct on (q.branch_id) q.branch_id, q.label, q.per_occurrence
      from weekday_ranked q order by q.branch_id, q.per_occurrence asc, q.dow
  ),
  lines as (
    -- Decision 14: get_ci_demographic_totals_v1.by_item's grouping and its identified-only base.
    select c.branch_id, si.item_type,
           coalesce(si.ref_id, si.product_id) as item_id,
           si.description, si.line_cents, c.client_id
      from public.sale_items si
      join cur c on c.id = si.sale_id
     where si.business_id = p_business
       and c.is_revenue
       and c.client_id is not null
  ),
  item_tot as (
    select l.branch_id, l.item_id, l.description, l.item_type,
           coalesce(sum(l.line_cents), 0)::bigint as revenue_cents,
           count(distinct l.client_id)::bigint    as buyers
      from lines l
     group by l.branch_id, l.item_id, l.description, l.item_type
  ),
  top_item as (
    select distinct on (it.branch_id)
           it.branch_id, it.item_id, it.description, it.item_type, it.revenue_cents, it.buyers
      from item_tot it
     order by it.branch_id, it.revenue_cents desc, it.description, it.item_id
  )
  select jsonb_build_object(
    'scope', jsonb_build_object('business_id', p_business, 'branch_id', null,
                                'from', p_from, 'to', p_to),
    'visit_definition',
      'one qualifying sale row (the same grain public.get_ci_visit_rhythm_v1 counts), attributed '
      'to the branch the sale was recorded at',
    'business', jsonb_build_object(
      'visits', bt.visits, 'revenue_cents', bt.revenue_cents, 'customers', bt.customers),
    'branches_compared', (select count(*) from br),
    'branches_hidden', v_hidden,
    'unattributed_visits', bt.unattributed_visits,
    'unattributed_note',
      'A qualifying sale that carries no branch id belongs to the business and to no outlet; it '
      'is counted in business.visits and in no branch row, so the branch shares need not sum to '
      '100.',
    'branches', coalesce((
      select jsonb_agg(jsonb_build_object(
               'branch', jsonb_build_object(
                 'id', br.id, 'code', br.code, 'name', br.name, 'is_default', br.is_default),
               'visits', ba.visits,
               'revenue_cents', ba.revenue_cents,
               'customers', ba.customers,
               'new_customers', coalesce(nc.new_customers, 0),
               'share_of_visits', app.rate_block_v1(ba.visits, bt.visits),
               'share_of_revenue', app.rate_block_v1(ba.revenue_cents, bt.revenue_cents),
               'gender', coalesce((
                 select jsonb_agg(jsonb_build_object(
                          'gender', gr.gender,
                          'customers', gr.customers,
                          'share',
                            case when app.subgroup_evidence_v1(dt.gender_known::int)->>'status' = 'ok'
                                 then app.rate_block_v1(gr.customers, dt.gender_known)
                                 else jsonb_set(app.rate_block_v1(gr.customers, dt.gender_known),
                                                '{pct}', 'null'::jsonb) end)
                        order by gr.customers desc, gr.gender)
                   from gender_rows gr where gr.branch_id = br.id), '[]'::jsonb),
               'unknown_gender', coalesce(dt.customers, 0) - coalesce(dt.gender_known, 0),
               'age_bands', coalesce((
                 select jsonb_agg(jsonb_build_object(
                          'age_band', ar.age_band,
                          'customers', ar.customers,
                          'share',
                            case when app.subgroup_evidence_v1(dt.age_known::int)->>'status' = 'ok'
                                 then app.rate_block_v1(ar.customers, dt.age_known)
                                 else jsonb_set(app.rate_block_v1(ar.customers, dt.age_known),
                                                '{pct}', 'null'::jsonb) end)
                        order by case ar.age_band
                                   when 'under_20' then 1 when '20_24' then 2 when '25_30' then 3
                                   when '31_40'    then 4 when '41_50' then 5 else 6 end,
                                 ar.age_band)
                   from age_rows ar where ar.branch_id = br.id), '[]'::jsonb),
               'unknown_age', coalesce(dt.customers, 0) - coalesce(dt.age_known, 0),
               'coverage', jsonb_build_object(
                 'gender_known', app.rate_block_v1(coalesce(dt.gender_known, 0),
                                                   coalesce(dt.customers, 0)),
                 'age_known',    app.rate_block_v1(coalesce(dt.age_known, 0),
                                                   coalesce(dt.customers, 0))),
               'evidence', jsonb_build_object(
                 'gender',    app.subgroup_evidence_v1(coalesce(dt.gender_known, 0)::int),
                 'age_band',  app.subgroup_evidence_v1(coalesce(dt.age_known, 0)::int)),
               'top_age_band',
                 case when tb.age_band is null then null
                      else jsonb_build_object('age_band', tb.age_band, 'customers', tb.customers)
                 end,
               'busiest_weekday',
                 case when bwd.label is null then null
                      else jsonb_build_object('label', bwd.label,
                                              'per_occurrence', bwd.per_occurrence) end,
               'slowest_weekday',
                 case when swd.label is null then null
                      else jsonb_build_object('label', swd.label,
                                              'per_occurrence', swd.per_occurrence) end,
               'top_item',
                 case when ti.branch_id is null then null
                      else jsonb_build_object('item_name', ti.description,
                                              'item_type', ti.item_type,
                                              'revenue_cents', ti.revenue_cents,
                                              'buyers', ti.buyers) end)
             order by br.code, br.id)
        from br
        join branch_agg ba on ba.branch_id = br.id
        left join new_cust  nc  on nc.branch_id  = br.id
        left join dem_tot   dt  on dt.branch_id  = br.id
        left join top_band  tb  on tb.branch_id  = br.id
        left join busiest_wd bwd on bwd.branch_id = br.id
        left join slowest_wd swd on swd.branch_id = br.id
        left join top_item  ti  on ti.branch_id  = br.id), '[]'::jsonb),
    'weekday_floor',
      'A weekday is ranked only once it occurs at least 4 times inside the window; '
      'per_occurrence is visits per occurrence of that weekday, to 1 decimal place.',
    'time_basis', 'sale_occurred_at',
    'evidence_class', 'DIRECT_FACT',
    'limitation',
      'Branches are compared on where the sale was recorded. A customer who visits two branches '
      'is counted at each.',
    'observed_since', app.metric_observed_since_v1('ci_branch_comparison', p_business))
    into v_result
    from biz_tot bt;

  return app.ci_envelope_v680('ci_branch_comparison_v1', p_business, null, p_from, p_to,
    p_as_of, app.ci_exclusion_counts_v680(p_business, null, p_from, p_to, p_as_of), v_result);
end;
$$;
revoke all on function public.get_ci_branch_comparison_v1(uuid,date,date,timestamptz)
  from public, anon;
grant execute on function public.get_ci_branch_comparison_v1(uuid,date,date,timestamptz)
  to authenticated, service_role;

commit;
