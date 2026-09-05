-- NESTLY v772 — five read-only Owner-brief readers: cash gap, staff rebooking, reward
-- popularity, visit rhythm, demographic totals.
--
-- Contract: docs/design/ci/CI-STAT-AUTHORITY-CONTRACT.md (v672, frozen). Envelope: the v680
-- family as re-emitted by nestly_v693 (app.ci_envelope_v680 + app.ci_exclusion_counts_v680).
-- Visit-day authority: app.ci_visit_day_v699. Fixture guide: docs/qa/CI-CORPUS-FIXTURE-GUIDE.md.
-- Proven by db/tests/executed/v772_corpus_owner_brief_readers.sql (predetermined truth table,
-- exact assertions, rolled back).
--
-- WHAT THIS ADDS. Five new SECURITY DEFINER readers, all gated first by
-- app.ci_access_gate_v667(p_business, p_branch), all wrapped in the frozen v680 envelope, all
-- read-only (no table in this migration is written, created or altered):
--
--   public.get_ci_cash_gap_v1              money recorded vs money collected
--   public.get_ci_staff_rebooking_v1       does a customer come back after seeing this person
--   public.get_ci_reward_popularity_v1     which rewards are actually redeemed
--   public.get_ci_visit_rhythm_v1          which days and which two-hour blocks are quiet
--   public.get_ci_demographic_totals_v1    who the customers are, and what they buy
--
-- ---------------------------------------------------------------------------------------------
-- DESIGN DECISIONS
-- ---------------------------------------------------------------------------------------------
--
-- 1. ONE QUALIFYING-SALE PREDICATE, SPELLED OUT IN EVERY READER. Each reader scopes on
--    business, optional branch, `s.created_at <= p_as_of`, `s.reversal_of is null`, no
--    surviving reversal (`not exists (... r.reversal_of = s.id and r.created_at <= p_as_of)`),
--    a non-synthetic client, and `app.ci_visit_day_v699(s.occurred_at)` inside the window.
--    That is v694's predicate, character for character in shape, and it deliberately gates the
--    reversal lookup on p_as_of — which app.analytics_sale_class_v1 (v628), the helper
--    get_ci_daypart_v1 uses, does NOT. See decision 8 for why get_ci_visit_rhythm_v1 is still
--    identical to the daypart reader in every case a caller can actually produce.
--
-- 2. ANONYMOUS SALES (client_id is null) are INCLUDED wherever the question is about money —
--    a walk-in who paid nothing is still an unpaid ticket — and EXCLUDED wherever the question
--    is about a person (cohorts, demographics, per-customer outstanding), because a null
--    identity cannot be followed to a second visit or resolved to an age band. Every reader
--    that excludes them says so in its own payload (`anonymous_visits`, or the envelope's
--    shared `exclusions.anonymous_sales`) rather than dropping them silently. The clients join
--    is therefore a LEFT join with `not coalesce(c.is_synthetic, false)`: a null row cannot be
--    synthetic, so anonymous sales survive the synthetic filter by construction.
--
-- 3. NO BARE PERCENTAGE, EVER. Every rate travels as app.rate_block_v1 (numerator, denominator,
--    pct) and every pct is NULL — never 0.0 — when the denominator is zero or the subgroup is
--    below the k=5 evidence floor. Below-floor suppression nulls the pct with
--    `jsonb_set(..., '{pct}', 'null'::jsonb)` so numerator and denominator still travel, which
--    is v694's rule and the reason a suppressed cell is still auditable.
--
-- 4. CUSTOMER NAMES ARE MODULE-GATED, SOFTLY. get_ci_cash_gap_v1 is the only reader here that
--    would otherwise emit a customer's name. public.get_attention_list_v548 — the existing
--    "who owes you / who to chase" surface — gates names through
--    public.require_module_scope_v145(p_business, p_branch, 'clients'), whose own module
--    predicate is the `clients` module. This reader asks the same question of the same module,
--    `app.can_module(p_business, 'clients')`, but answers it SOFTLY: a caller without the
--    clients module still gets every figure, with `client_name` null and `names_visible`
--    false, instead of a 42501 that would deny an entitled finance reader the whole cash gap
--    over a PII field they never asked for. CONSEQUENCE, ACCEPTED: app.can_module resolves
--    through app.can_module_read_at_v94, which answers for a super admin (true) and for the
--    firm's own staff, but NOT for an assigned platform consultant who cleared
--    app.ci_access_gate_v667 through the platform arm — that consultant sees the money and no
--    names. That is the conservative direction and it is the one we take deliberately: a
--    consultant advising on a cash gap does not need the debtors' names to do it.
--
-- 5. A REFUND IS ALREADY NEGATIVE. public.payments enforces
--    `(kind = 'refund' and amount_cents < 0) or (kind <> 'refund' and amount_cents > 0)`
--    (nestly_v11b). So `paid_cents` is the PLAIN SIGNED SUM of the payment and refund rows
--    attached to a sale, not `sum(payment) - sum(refund)`: writing the subtraction against a
--    ledger that already stores refunds negative would ADD the refund back and overstate
--    collections by twice the refund. `refunds_cents` is reported as a positive magnitude
--    (`-sum(...)`) because "we refunded $30" reads better than "we refunded -$30", and the
--    payload says which.
--
-- 6. DEPOSITS AND NO-SHOW FEES ARE REPORTED, NOT COUNTED. public.payments.kind admits four
--    values ('payment', 'deposit', 'no_show_fee', 'refund'), not two. `paid_cents` counts
--    'payment' and 'refund' only — a deposit is money taken before the sale existed and a
--    no-show fee is not payment for the ticket it hangs off. Both are nonetheless real money
--    that touched an in-scope sale, so they are emitted as `unapplied_payment_kinds` with an
--    explicit note. Nothing that reached a scoped sale is dropped without appearing somewhere.
--
-- 7. STAFF ARE ATTRIBUTED AT SALE LEVEL, NOT LINE LEVEL. public.get_ci_staff_performance_v1
--    (nestly_v683, re-emitted by v699) attributes through `sale_items.staff_id`. In production
--    `sales.staff_id` is populated on roughly nine sales in ten while `sale_items.staff_id` is
--    populated on under half, which is why that reader returns an empty staff list for a real
--    tenant. get_ci_staff_rebooking_v1 therefore attributes a SALE to
--    `coalesce(s.staff_id, <the single distinct non-null sale_items.staff_id on that sale>)` —
--    the line-level fallback fires only when the ticket is unambiguous (exactly one distinct
--    non-null line staff), because a two-stylist ticket has no single owner and guessing one
--    would invent an attribution the data does not contain. A sale that resolves to no staff
--    is counted into `unattributed_visits`, never silently dropped.
--
-- 8. get_ci_visit_rhythm_v1's VISIT IS get_ci_daypart_v1's VISIT. Both count qualifying sale
--    ROWS (not distinct customer-days): daypart's `count(*) filter (where include_visit)` is
--    the definition, and this reader reproduces it, so `days[].visits` for a given date equals
--    the daypart reader's own weekday and hour totals for that same date. Two documented
--    differences, neither reachable at a default call: (a) the reversal lookup here is gated on
--    p_as_of (decision 1), so the two readers can differ only for a historical p_as_of that
--    predates a reversal's created_at; (b) bucketing here is fixed to Asia/Singapore through
--    app.ci_visit_day_v699, the frozen v699 authority, while nestly_v698 gave the daypart
--    reader a per-branch bucket timezone — the two agree for every firm whose branches resolve
--    to Asia/Singapore, which app.ci_bucket_tz_v698 also returns as its default when branches
--    disagree or none exists. The visit-day authority is deliberately not re-derived here.
--    Note that this reader's grain is a SALE ROW, so `visit_definition` is stated in the
--    payload as such and it is NOT the (client, calendar-day) grain v699 froze for
--    per-customer visit counting; get_ci_staff_rebooking_v1, which counts customers, uses the
--    v699 grain instead. Two questions, two grains, both named in the payload.
--
-- 9. REDEMPTIONS ARE BUSINESS-WIDE. public.loyalty_redemptions carries no branch. When
--    p_branch is passed, get_ci_reward_popularity_v1 still RUNS the gate (so a branch that
--    belongs to another firm is refused, never quietly ignored) and then reports on the whole
--    business, saying so in `scope_note`. Its `eligible_customers` denominator IS branch-
--    filtered, because that figure comes from sales; the payload names both facts rather than
--    pretending the mismatch away.
--
-- 10. A REWARD WITH NO REDEMPTIONS STILL APPEARS. The rewards list is the union of (a) every
--    reward redeemed in the window and (b) every reward currently `active and not paused` in
--    public.loyalty_rewards. A live reward nobody redeemed is the single most actionable row
--    this reader can emit, and omitting it would make the list a description of what happened
--    instead of an answer to "which of my rewards is not working". Rewards that no longer have
--    a loyalty_rewards row (redemption history for a hard-deleted reward) carry `active` and
--    `paused` as null rather than a fabricated false.
--    public.loyalty_redemptions.reward_id is nullable; a redemption with no reward_id cannot
--    be attributed to a reward row and is reported in `unattributed_redemptions` while still
--    counting toward `totals.redemptions` (so `share_of_redemptions` denominators stay honest).
--
-- 11. SUPPRESSED IS NOT ZERO. get_ci_visit_rhythm_v1's `age_by_block` emits a cell with
--    `visits: null, suppressed: true` below the k=5 floor rather than dropping it or printing
--    a real small number. Only cells with at least one visit are emitted: a cell with zero
--    visits has nothing to suppress and printing 72 zero cells would bury the twelve that
--    matter. `coverage.age_known` states how much of the identified population resolved an age
--    band at all, so a thin grid can be told apart from a grid that is thin because nobody
--    gave a birth date.
--
-- 12. DEMOGRAPHICS COME FROM THE GATE-FREE CORE. app.customer_demographics_core_v674, never
--    the public app.customer_demographics_v1 wrapper — v674 design decision 8: this reader has
--    already cleared app.ci_access_gate_v667, and routing per-client classification back
--    through the merchant-only wrapper would double-gate and wrongly 42501 an entitled
--    platform consultant. The core resolves wallet-attested values ahead of staff-entered
--    ones, masks 'prefer_not_to_say' to null, and returns v674's own age bands
--    (under_20, 20_24, 25_30, 31_40, 41_50, 51_plus). No reader here reads clients.gender or
--    clients.birth_date directly.
--
-- 13. EVIDENCE FLOORS. k=5 everywhere the subject is people (a staff member's matured cohort,
--    a reward's redeemers, a demographic cell, an age-by-block cell), and k=4 for
--    get_ci_visit_rhythm_v1's weekdays — the subject there is the number of OCCURRENCES of a
--    weekday inside the window, and four Mondays is the smallest count from which "Mondays are
--    quiet" is worth saying at all. Both floors travel in the payload via
--    app.subgroup_evidence_v1, which names its own floor, so neither is a hidden constant.
--
-- 14. NO CAUSAL CLAIM. get_ci_staff_rebooking_v1 carries evidence_class 'ASSOCIATION' and an
--    explicit limitation: which customers a staff member serves is not random, so a higher
--    return rate is an association, not proof the staff member caused it. The cash-gap reader
--    is 'DIRECT_FACT' — it reports rows, not inferences — with a basis_note that names the one
--    thing it genuinely cannot tell apart: a sale with no payment row is either unpaid or was
--    paid without being recorded.
--
-- 15. WINDOW ARITHMETIC. p_to is INCLUSIVE everywhere (`between p_from and p_to` on the
--    v699 visit day). get_ci_staff_rebooking_v1's return lookup deliberately reads sales up to
--    `p_to + p_window_days`, because a cohort pair whose first visit is on p_to can only return
--    after the window closes; the cohort itself is still drawn from inside [p_from, p_to], the
--    way public.get_ci_funnel_conversion_v1 already separates its population from its lookup
--    set. Unlike that reader, the lookup set here IS branch-filtered when p_branch is given, so
--    "came back" means "came back within the scope the caller asked about".
--
-- 16. NO NEW TABLES, NO NEW HELPERS, NO WRITES. Everything above is expressed inline against
--    existing frozen authorities (ci_access_gate_v667, ci_visit_day_v699, ci_envelope_v680,
--    ci_exclusion_counts_v680, rate_block_v1, subgroup_evidence_v1,
--    customer_demographics_core_v674, can_module, metric_observed_since_v1). This migration
--    creates five functions and grants them; it alters no table and inserts no row.
begin;

-- ---------------------------------------------------------------------------------------------
-- 1 · public.get_ci_cash_gap_v1 — money recorded versus money collected.
-- ---------------------------------------------------------------------------------------------
create or replace function public.get_ci_cash_gap_v1(
  p_business uuid, p_from date, p_to date, p_branch uuid default null,
  p_as_of timestamptz default clock_timestamp())
returns jsonb
language plpgsql stable security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_today  date;
  v_names  boolean;
  v_result jsonb;
begin
  perform app.ci_access_gate_v667(p_business, p_branch);
  if p_from is null or p_to is null or p_from > p_to then
    raise exception 'invalid date range' using errcode = '22023';
  end if;
  v_today := app.ci_visit_day_v699(p_as_of);
  -- Design decision 4: the same module get_attention_list_v548 gates its names on, asked
  -- softly. A caller without it gets every number and no names.
  v_names := coalesce(app.can_module(p_business, 'clients'), false);

  with scope_sales as (
    -- The clients join happens exactly ONCE, here, alongside the synthetic guard: every later
    -- block reads full_name off this row rather than re-joining public.clients inside an
    -- aggregate, which is what keeps app.ci_synthetic_scan_mixed_v744 honest about this reader
    -- (an aggregate over public.clients in a window with no is_synthetic marker is exactly the
    -- shape that scanner exists to catch, and re-joining for a name would look like one).
    select s.id, s.client_id, s.kind, s.amount_cents, s.occurred_at,
           app.ci_visit_day_v699(s.occurred_at) as visit_day,
           c.full_name as client_name
      from public.sales s
      left join public.clients c on c.id = s.client_id and c.business_id = p_business
     where s.business_id = p_business
       and (p_branch is null or s.branch_id = p_branch)
       and s.created_at <= p_as_of
       and s.reversal_of is null
       and not exists (select 1 from public.sales r
                        where r.reversal_of = s.id and r.created_at <= p_as_of)
       and not coalesce(c.is_synthetic, false)
       and coalesce(s.counts_as_revenue, false)
       and app.ci_visit_day_v699(s.occurred_at) between p_from and p_to
  ),
  scope_pay as (
    -- Payment rows attached to an in-scope sale. Not window-filtered on their own occurred_at:
    -- a payment settled a fortnight after the ticket still settles THAT ticket.
    select p.id, p.sale_id, p.kind, p.method, p.amount_cents
      from public.payments p
      join scope_sales ss on ss.id = p.sale_id
     where p.business_id = p_business
       and p.created_at <= p_as_of
  ),
  paid as (
    select ss.id as sale_id,
           -- Design decision 5: refunds are stored negative, so this is a plain signed sum.
           coalesce(sum(sp.amount_cents) filter (where sp.kind in ('payment', 'refund')), 0)::bigint
             as paid_cents
      from scope_sales ss
      left join scope_pay sp on sp.sale_id = ss.id
     group by ss.id
  ),
  sale_state as (
    select ss.id, ss.client_id, ss.kind, ss.occurred_at, ss.visit_day, ss.client_name,
           ss.amount_cents::bigint as amount_cents,
           pd.paid_cents,
           least(pd.paid_cents, ss.amount_cents::bigint)         as collected_cents,
           greatest(ss.amount_cents::bigint - pd.paid_cents, 0)  as outstanding_cents,
           greatest(pd.paid_cents - ss.amount_cents::bigint, 0)  as overpaid_cents,
           case when pd.paid_cents >= ss.amount_cents::bigint then 'fully'
                when pd.paid_cents > 0                       then 'partly'
                else 'unpaid' end                              as pay_state
      from scope_sales ss
      join paid pd on pd.sale_id = ss.id
  ),
  win_pay as (
    -- Every collection-shaped payment row whose OWN day falls in the window, scoped to the
    -- branch when one was asked for. Used only to find the ones that reach no in-scope sale.
    select p.id, p.sale_id, p.amount_cents
      from public.payments p
     where p.business_id = p_business
       and (p_branch is null or p.branch_id = p_branch)
       and p.created_at <= p_as_of
       and p.kind = 'payment'
       and app.ci_visit_day_v699(p.occurred_at) between p_from and p_to
  ),
  totals as (
    select count(*)::bigint                                             as sales_count,
           coalesce(sum(amount_cents), 0)::bigint                       as revenue_recorded_cents,
           coalesce(sum(collected_cents), 0)::bigint                    as collected_cents,
           coalesce(sum(outstanding_cents), 0)::bigint                  as outstanding_cents,
           coalesce(sum(overpaid_cents), 0)::bigint                     as overpaid_cents,
           count(*) filter (where pay_state = 'fully')::bigint          as sales_fully_paid,
           count(*) filter (where pay_state = 'partly')::bigint         as sales_partly_paid,
           count(*) filter (where pay_state = 'unpaid')::bigint         as sales_unpaid
      from sale_state
  )
  select jsonb_build_object(
    'scope', jsonb_build_object('business_id', p_business, 'branch_id', p_branch,
                                'from', p_from, 'to', p_to),
    'totals', jsonb_build_object(
      'revenue_recorded_cents', t.revenue_recorded_cents,
      'collected_cents', t.collected_cents,
      'outstanding_cents', t.outstanding_cents,
      'overpaid_cents', t.overpaid_cents,
      'sales_count', t.sales_count,
      'sales_fully_paid', t.sales_fully_paid,
      'sales_partly_paid', t.sales_partly_paid,
      'sales_unpaid', t.sales_unpaid,
      'collected_share', app.rate_block_v1(t.collected_cents, t.revenue_recorded_cents)),
    'by_method', coalesce((
      select jsonb_agg(jsonb_build_object(
               'method', m.method, 'cents', m.cents, 'payments', m.payments)
             order by m.cents desc, m.method)
        from (select sp.method,
                     sum(sp.amount_cents)::bigint as cents,
                     count(*)::bigint             as payments
                from scope_pay sp
               where sp.kind = 'payment'
               group by sp.method) m), '[]'::jsonb),
    'refunds_cents', coalesce((
      -- Positive magnitude of the negative refund rows (design decision 5).
      select -sum(sp.amount_cents)::bigint from scope_pay sp where sp.kind = 'refund'), 0),
    'unapplied_payment_kinds', coalesce((
      select jsonb_agg(jsonb_build_object(
               'kind', k.kind, 'cents', k.cents, 'payments', k.payments)
             order by k.kind)
        from (select sp.kind,
                     sum(sp.amount_cents)::bigint as cents,
                     count(*)::bigint             as payments
                from scope_pay sp
               where sp.kind in ('deposit', 'no_show_fee')
               group by sp.kind) k), '[]'::jsonb),
    'unapplied_note',
      'Deposits and no-show fees touched these sales but are not counted as collected against '
      'them: a deposit is money taken before the sale existed and a no-show fee is not payment '
      'for the ticket it hangs off.',
    'unlinked_payments', (
      select jsonb_build_object(
               'count', count(*)::bigint,
               'cents', coalesce(sum(wp.amount_cents), 0)::bigint)
        from win_pay wp
       where wp.sale_id is null
          or not exists (select 1 from scope_sales ss where ss.id = wp.sale_id)),
    'unlinked_note',
      'Payments in this window that reach no in-scope sale -- no sale_id at all, or a sale '
      'outside this reader''s scope. Reported so the money is visible; never added to collected.',
    'outstanding_sales', coalesce((
      select jsonb_agg(jsonb_build_object(
               'sale_id', o.id,
               'occurred_at', o.occurred_at,
               'kind', o.kind,
               'client_id', o.client_id,
               'client_name', case when v_names then o.full_name else null end,
               'amount_cents', o.amount_cents,
               'paid_cents', o.paid_cents,
               'outstanding_cents', o.outstanding_cents,
               'days_outstanding', o.days_outstanding)
             order by o.outstanding_cents desc, o.id)
        from (select ss.id, ss.occurred_at, ss.kind, ss.client_id, ss.amount_cents,
                     ss.paid_cents, ss.outstanding_cents,
                     (v_today - ss.visit_day) as days_outstanding,
                     ss.client_name as full_name
                from sale_state ss
               where ss.outstanding_cents > 0
               order by ss.outstanding_cents desc, ss.id
               limit 50) o), '[]'::jsonb),
    'outstanding_by_customer', coalesce((
      select jsonb_agg(jsonb_build_object(
               'client_id', c2.client_id,
               'client_name', case when v_names then c2.full_name else null end,
               'sales', c2.sales,
               'outstanding_cents', c2.outstanding_cents)
             order by c2.outstanding_cents desc, c2.client_id)
        from (select ss.client_id,
                     count(*)::bigint                  as sales,
                     sum(ss.outstanding_cents)::bigint as outstanding_cents,
                     min(ss.client_name)               as full_name
                from sale_state ss
               where ss.outstanding_cents > 0
                 and ss.client_id is not null
               group by ss.client_id
               order by sum(ss.outstanding_cents) desc, ss.client_id
               limit 20) c2), '[]'::jsonb),
    'names_visible', v_names,
    'names_note',
      'Customer names are shown only to a caller who holds the clients module, the same module '
      'get_attention_list_v548 requires; every figure is shown either way.',
    'time_basis', 'sale_occurred_at',
    'basis_note',
      'A sale with no payment row is either unpaid or was paid without being recorded; this '
      'reader cannot tell the two apart.',
    'evidence_class', 'DIRECT_FACT',
    'observed_since', app.metric_observed_since_v1('ci_cash_gap', p_business))
    into v_result
    from totals t;

  return app.ci_envelope_v680('ci_cash_gap_v1', p_business, p_branch, p_from, p_to,
    p_as_of, app.ci_exclusion_counts_v680(p_business, p_branch, p_from, p_to, p_as_of), v_result);
end;
$$;
revoke all on function public.get_ci_cash_gap_v1(uuid,date,date,uuid,timestamptz)
  from public, anon;
grant execute on function public.get_ci_cash_gap_v1(uuid,date,date,uuid,timestamptz)
  to authenticated, service_role;

-- ---------------------------------------------------------------------------------------------
-- 2 · public.get_ci_staff_rebooking_v1 — does a customer come back after seeing this person.
--     Argument order mirrors public.get_ci_funnel_conversion_v1: p_window_days sits BEFORE
--     p_branch, so both cohort readers read the same way at a call site.
-- ---------------------------------------------------------------------------------------------
create or replace function public.get_ci_staff_rebooking_v1(
  p_business uuid, p_from date, p_to date, p_window_days integer default 60,
  p_branch uuid default null, p_as_of timestamptz default clock_timestamp())
returns jsonb
language plpgsql stable security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_today  date;
  v_result jsonb;
begin
  perform app.ci_access_gate_v667(p_business, p_branch);
  if p_from is null or p_to is null or p_from > p_to then
    raise exception 'invalid date range' using errcode = '22023';
  end if;
  if p_window_days is null or p_window_days <= 0 then
    raise exception 'window days must be a positive integer' using errcode = '22023';
  end if;
  v_today := app.ci_visit_day_v699(p_as_of);

  with valid as (
    -- The lookup set: qualifying sales from p_from through p_to + p_window_days, so a pair
    -- whose first visit lands on p_to can still be observed returning (design decision 15).
    select s.id, s.client_id, s.staff_id, s.amount_cents,
           app.ci_visit_day_v699(s.occurred_at) as visit_day,
           coalesce(s.counts_as_visit, false)   as is_visit,
           coalesce(s.counts_as_revenue, false) as is_revenue
      from public.sales s
      left join public.clients c on c.id = s.client_id
     where s.business_id = p_business
       and (p_branch is null or s.branch_id = p_branch)
       and s.created_at <= p_as_of
       and s.reversal_of is null
       and not exists (select 1 from public.sales r
                        where r.reversal_of = s.id and r.created_at <= p_as_of)
       and not coalesce(c.is_synthetic, false)
       and (coalesce(s.counts_as_visit, false) or coalesce(s.counts_as_revenue, false))
       and app.ci_visit_day_v699(s.occurred_at) between p_from and (p_to + p_window_days)
  ),
  attr as (
    -- Design decision 7: sale-level attribution, with a line-level fallback that fires only
    -- when the ticket names exactly one distinct staff member.
    select v.id, v.client_id, v.amount_cents, v.visit_day, v.is_visit, v.is_revenue,
           coalesce(v.staff_id, li.only_staff) as staff_key
      from valid v
      left join lateral (
        select case when count(distinct si.staff_id) = 1
                    then (array_agg(distinct si.staff_id))[1] end as only_staff
          from public.sale_items si
         where si.sale_id = v.id
           and si.business_id = p_business
           and si.staff_id is not null
      ) li on true
  ),
  -- every identified customer-day with a qualifying visit anywhere in the lookup range
  client_days as (
    select distinct a.client_id, a.visit_day
      from attr a
     where a.is_visit and a.client_id is not null
  ),
  -- the same, split by attributed staff (only rows that HAVE a staff member)
  staff_days as (
    select distinct a.client_id, a.staff_key, a.visit_day
      from attr a
     where a.is_visit and a.client_id is not null and a.staff_key is not null
  ),
  -- the cohort grain: one row per (customer, visit-day, staff) INSIDE the requested window
  win_visits as (
    select distinct a.client_id, a.visit_day, a.staff_key
      from attr a
     where a.is_visit
       and a.client_id is not null
       and a.visit_day between p_from and p_to
  ),
  visit_agg as (
    select wv.staff_key,
           count(*)::bigint                    as visits,
           count(distinct wv.client_id)::bigint as customers
      from win_visits wv
     where wv.staff_key is not null
     group by wv.staff_key
  ),
  rev_agg as (
    select a.staff_key, coalesce(sum(a.amount_cents), 0)::bigint as revenue_cents
      from attr a
     where a.is_revenue
       and a.staff_key is not null
       and a.visit_day between p_from and p_to
     group by a.staff_key
  ),
  pair_first as (
    select wv.client_id, wv.staff_key, min(wv.visit_day) as first_day
      from win_visits wv
     where wv.staff_key is not null
     group by wv.client_id, wv.staff_key
  ),
  pair_scored as (
    select pf.client_id, pf.staff_key, pf.first_day,
           (pf.first_day + p_window_days <= v_today) as matured,
           exists (select 1 from client_days cd
                    where cd.client_id = pf.client_id
                      and cd.visit_day >  pf.first_day
                      and cd.visit_day <= pf.first_day + p_window_days) as returned_any,
           exists (select 1 from staff_days sd
                    where sd.client_id = pf.client_id
                      and sd.staff_key = pf.staff_key
                      and sd.visit_day >  pf.first_day
                      and sd.visit_day <= pf.first_day + p_window_days) as returned_same
      from pair_first pf
  ),
  pair_agg as (
    select ps.staff_key,
           count(*) filter (where ps.matured)::bigint          as matured,
           count(*) filter (where not ps.matured)::bigint      as immature,
           count(*) filter (where ps.matured and ps.returned_any)::bigint  as returned_any,
           count(*) filter (where ps.matured and ps.returned_same)::bigint as returned_same
      from pair_scored ps
     group by ps.staff_key
  ),
  -- firm cohort: the same computation with no staff split (a client's FIRST attributed visit)
  client_first as (
    select wv.client_id, min(wv.visit_day) as first_day
      from win_visits wv
     where wv.staff_key is not null
     group by wv.client_id
  ),
  client_scored as (
    select cf.client_id, cf.first_day,
           (cf.first_day + p_window_days <= v_today) as matured,
           exists (select 1 from client_days cd
                    where cd.client_id = cf.client_id
                      and cd.visit_day >  cf.first_day
                      and cd.visit_day <= cf.first_day + p_window_days) as returned_any
      from client_first cf
  ),
  firm_agg as (
    select count(*) filter (where cs.matured)::bigint     as matured,
           count(*) filter (where not cs.matured)::bigint as immature,
           count(*) filter (where cs.matured and cs.returned_any)::bigint as returned_any
      from client_scored cs
  ),
  firm_block as (
    select fa.matured, fa.immature, fa.returned_any,
           app.subgroup_evidence_v1(fa.matured::int) as evidence,
           case when app.subgroup_evidence_v1(fa.matured::int)->>'status' = 'ok'
                then app.rate_block_v1(fa.returned_any, fa.matured)
                else jsonb_set(app.rate_block_v1(fa.returned_any, fa.matured),
                               '{pct}', 'null'::jsonb) end as returned_any_block
      from firm_agg fa
  ),
  staff_rows as (
    select va.staff_key,
           va.visits, va.customers,
           coalesce(ra.revenue_cents, 0) as revenue_cents,
           coalesce(pa.matured, 0)       as matured,
           coalesce(pa.immature, 0)      as immature,
           coalesce(pa.returned_any, 0)  as returned_any,
           coalesce(pa.returned_same, 0) as returned_same,
           app.subgroup_evidence_v1(coalesce(pa.matured, 0)::int) as evidence
      from visit_agg va
      left join rev_agg  ra on ra.staff_key = va.staff_key
      left join pair_agg pa on pa.staff_key = va.staff_key
  ),
  staff_scored as (
    select sr.*,
           case when sr.evidence->>'status' = 'ok'
                then app.rate_block_v1(sr.returned_any, sr.matured)
                else jsonb_set(app.rate_block_v1(sr.returned_any, sr.matured),
                               '{pct}', 'null'::jsonb) end as returned_any_block,
           case when sr.evidence->>'status' = 'ok'
                then app.rate_block_v1(sr.returned_same, sr.matured)
                else jsonb_set(app.rate_block_v1(sr.returned_same, sr.matured),
                               '{pct}', 'null'::jsonb) end as returned_same_block
      from staff_rows sr
  )
  select jsonb_build_object(
    'scope', jsonb_build_object('business_id', p_business, 'branch_id', p_branch,
                                'from', p_from, 'to', p_to),
    'window_days', p_window_days,
    'visit_definition',
      'one per customer per calendar day (Asia/Singapore) per attributed staff member; a split '
      'bill counts once',
    'firm', (
      select jsonb_build_object(
               'matured', fb.matured,
               'immature', fb.immature,
               'returned_any', fb.returned_any_block,
               'evidence', fb.evidence)
        from firm_block fb),
    'staff', coalesce((
      select jsonb_agg(jsonb_build_object(
               'staff_id', sc.staff_key,
               'full_name', st.full_name,
               'active', st.active,
               'visits', sc.visits,
               'customers', sc.customers,
               'revenue_cents', sc.revenue_cents,
               'revenue_per_visit_cents',
                 case when sc.visits > 0
                      then round(sc.revenue_cents::numeric / sc.visits)::bigint
                      else null end,
               'matured', sc.matured,
               'immature', sc.immature,
               'returned_any', sc.returned_any_block,
               'returned_same_staff', sc.returned_same_block,
               'vs_firm_points',
                 case when (sc.returned_any_block->>'pct') is not null
                       and (fb.returned_any_block->>'pct') is not null
                      then round((sc.returned_any_block->>'pct')::numeric
                                 - (fb.returned_any_block->>'pct')::numeric, 1)
                      else null end,
               'evidence', sc.evidence)
             order by sc.visits desc, sc.staff_key)
        from staff_scored sc
        cross join firm_block fb
        left join public.staff st
          on st.id = sc.staff_key and st.business_id = p_business), '[]'::jsonb),
    'unattributed_visits', coalesce((
      select count(*)::bigint from win_visits wv where wv.staff_key is null), 0),
    'anonymous_visits', coalesce((
      select count(*)::bigint from attr a
       where a.is_visit and a.client_id is null
         and a.visit_day between p_from and p_to), 0),
    'anonymous_note',
      'Anonymous sales carry no identity, so they cannot be deduplicated into customer-days or '
      'followed to a return; the figure counts qualifying sale rows and is excluded from every '
      'cohort above.',
    'time_basis', 'sale_occurred_at',
    'evidence_class', 'ASSOCIATION',
    'limitation',
      'Which customers a staff member serves is not random; a higher return rate is an '
      'association, not proof the staff member caused it.',
    'observed_since', app.metric_observed_since_v1('ci_staff_rebooking', p_business))
    into v_result;

  return app.ci_envelope_v680('ci_staff_rebooking_v1', p_business, p_branch, p_from, p_to,
    p_as_of, app.ci_exclusion_counts_v680(p_business, p_branch, p_from, p_to, p_as_of), v_result);
end;
$$;
revoke all on function public.get_ci_staff_rebooking_v1(uuid,date,date,integer,uuid,timestamptz)
  from public, anon;
grant execute on function public.get_ci_staff_rebooking_v1(uuid,date,date,integer,uuid,timestamptz)
  to authenticated, service_role;

-- ---------------------------------------------------------------------------------------------
-- 3 · public.get_ci_reward_popularity_v1 — which rewards are actually redeemed.
-- ---------------------------------------------------------------------------------------------
create or replace function public.get_ci_reward_popularity_v1(
  p_business uuid, p_from date, p_to date, p_branch uuid default null,
  p_as_of timestamptz default clock_timestamp())
returns jsonb
language plpgsql stable security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_result jsonb;
begin
  perform app.ci_access_gate_v667(p_business, p_branch);
  if p_from is null or p_to is null or p_from > p_to then
    raise exception 'invalid date range' using errcode = '22023';
  end if;

  with reds as (
    select lr.id, lr.client_id, lr.reward_id, lr.reward_name, lr.points_spent, lr.redeemed_at
      from public.loyalty_redemptions lr
      left join public.clients c
        on c.id = lr.client_id and c.business_id = p_business
     where lr.business_id = p_business
       and lr.redeemed_at <= p_as_of
       and app.ci_visit_day_v699(lr.redeemed_at) between p_from and p_to
       and not coalesce(c.is_synthetic, false)
       and not exists (select 1 from public.loyalty_redemption_reversals rr
                        where rr.redemption_id = lr.id
                          and rr.business_id = p_business
                          and rr.created_at <= p_as_of)
  ),
  eligible as (
    -- Branch-filtered, unlike the redemptions above (design decision 9).
    select count(distinct s.client_id)::bigint as customers
      from public.sales s
      join public.clients c on c.id = s.client_id
     where s.business_id = p_business
       and (p_branch is null or s.branch_id = p_branch)
       and s.created_at <= p_as_of
       and s.client_id is not null
       and s.reversal_of is null
       and not exists (select 1 from public.sales r
                        where r.reversal_of = s.id and r.created_at <= p_as_of)
       and not coalesce(c.is_synthetic, false)
       and coalesce(s.counts_as_visit, false)
       and app.ci_visit_day_v699(s.occurred_at) between p_from and p_to
  ),
  totals as (
    select count(*)::bigint                                  as redemptions,
           count(distinct r.client_id)::bigint                as customers,
           coalesce(sum(r.points_spent), 0)::bigint           as points_spent
      from reds r
  ),
  red_by_reward as (
    select r.reward_id,
           count(*)::bigint                        as redemptions,
           count(distinct r.client_id)::bigint     as customers,
           coalesce(sum(r.points_spent), 0)::bigint as points_spent,
           (array_agg(r.reward_name order by r.redeemed_at desc, r.id))[1] as latest_name
      from reds r
     where r.reward_id is not null
     group by r.reward_id
  ),
  live_rewards as (
    select lw.id
      from public.loyalty_rewards lw
     where lw.business_id = p_business
       and lw.active
       and not lw.paused
  ),
  reward_keys as (
    select reward_id from red_by_reward
    union
    select id from live_rewards
  ),
  rows_built as (
    select rk.reward_id,
           coalesce(lw.customer_name, lw.name, rbr.latest_name) as reward_name,
           lw.active, lw.paused,
           coalesce(rbr.redemptions, 0)  as redemptions,
           coalesce(rbr.customers, 0)    as customers,
           coalesce(rbr.points_spent, 0) as points_spent,
           app.subgroup_evidence_v1(coalesce(rbr.customers, 0)::int) as evidence
      from reward_keys rk
      left join red_by_reward rbr on rbr.reward_id = rk.reward_id
      left join public.loyalty_rewards lw
        on lw.id = rk.reward_id and lw.business_id = p_business
  ),
  rows_scored as (
    select rb.*,
           case when rb.evidence->>'status' = 'ok'
                then app.rate_block_v1(rb.redemptions, t.redemptions)
                else jsonb_set(app.rate_block_v1(rb.redemptions, t.redemptions),
                               '{pct}', 'null'::jsonb) end as share_of_redemptions,
           case when rb.evidence->>'status' = 'ok'
                then app.rate_block_v1(rb.customers, e.customers)
                else jsonb_set(app.rate_block_v1(rb.customers, e.customers),
                               '{pct}', 'null'::jsonb) end as redeemers_share
      from rows_built rb, totals t, eligible e
  )
  select jsonb_build_object(
    'scope', jsonb_build_object('business_id', p_business, 'branch_id', p_branch,
                                'from', p_from, 'to', p_to),
    'scope_note',
      'Redemptions are business-wide; the branch filter does not apply to this reader.',
    'rewards', coalesce((
      select jsonb_agg(jsonb_build_object(
               'reward_id', rs.reward_id,
               'reward_name', rs.reward_name,
               'active', rs.active,
               'paused', rs.paused,
               'redemptions', rs.redemptions,
               'customers', rs.customers,
               'points_spent', rs.points_spent,
               'share_of_redemptions', rs.share_of_redemptions,
               'redeemers_share', rs.redeemers_share,
               'evidence', rs.evidence)
             order by rs.redemptions desc, rs.reward_name, rs.reward_id)
        from rows_scored rs), '[]'::jsonb),
    'unattributed_redemptions', (
      select jsonb_build_object(
               'redemptions', count(*)::bigint,
               'customers', count(distinct r.client_id)::bigint,
               'points_spent', coalesce(sum(r.points_spent), 0)::bigint)
        from reds r where r.reward_id is null),
    'unattributed_note',
      'Redemption rows whose reward_id is null cannot be attributed to a reward; they still '
      'count toward totals.redemptions so every share denominator stays honest.',
    'totals', jsonb_build_object(
      'redemptions', t.redemptions,
      'customers', t.customers,
      'points_spent', t.points_spent,
      'eligible_customers', e.customers),
    'time_basis', 'redemption_redeemed_at',
    'evidence_class', 'DIRECT_FACT',
    'limitation',
      'Counts points and stamp reward redemptions only; welcome, birthday, bring-back and '
      'referral gifts are granted rather than redeemed and are reported by '
      'get_ci_loyalty_programmes_v1.',
    'observed_since', app.metric_observed_since_v1('ci_reward_popularity', p_business))
    into v_result
    from totals t, eligible e;

  return app.ci_envelope_v680('ci_reward_popularity_v1', p_business, p_branch, p_from, p_to,
    p_as_of, app.ci_exclusion_counts_v680(p_business, p_branch, p_from, p_to, p_as_of), v_result);
end;
$$;
revoke all on function public.get_ci_reward_popularity_v1(uuid,date,date,uuid,timestamptz)
  from public, anon;
grant execute on function public.get_ci_reward_popularity_v1(uuid,date,date,uuid,timestamptz)
  to authenticated, service_role;

-- ---------------------------------------------------------------------------------------------
-- 4 · public.get_ci_visit_rhythm_v1 — which days and which two-hour blocks are quiet.
--     A day's `visits` here equals public.get_ci_daypart_v1's weekday and hour totals for the
--     same day: same qualifying predicate, same sale-row grain (design decision 8).
-- ---------------------------------------------------------------------------------------------
create or replace function public.get_ci_visit_rhythm_v1(
  p_business uuid, p_from date, p_to date, p_branch uuid default null,
  p_as_of timestamptz default clock_timestamp())
returns jsonb
language plpgsql stable security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_len      integer;
  v_prev_to  date;
  v_prev_from date;
  v_result   jsonb;
begin
  perform app.ci_access_gate_v667(p_business, p_branch);
  if p_from is null or p_to is null or p_from > p_to then
    raise exception 'invalid date range' using errcode = '22023';
  end if;
  v_len       := (p_to - p_from) + 1;
  v_prev_to   := p_from - 1;
  v_prev_from := p_from - v_len;

  with base as (
    -- Both windows in one pass; `in_window` separates the requested window from the one
    -- immediately before it.
    select s.id, s.client_id, s.amount_cents,
           app.ci_visit_day_v699(s.occurred_at)          as visit_day,
           (s.occurred_at at time zone 'Asia/Singapore') as local_ts,
           coalesce(s.counts_as_visit, false)            as is_visit,
           coalesce(s.counts_as_revenue, false)          as is_revenue,
           (app.ci_visit_day_v699(s.occurred_at) between p_from and p_to) as in_window
      from public.sales s
      left join public.clients c on c.id = s.client_id
     where s.business_id = p_business
       and (p_branch is null or s.branch_id = p_branch)
       and s.created_at <= p_as_of
       and s.reversal_of is null
       and not exists (select 1 from public.sales r
                        where r.reversal_of = s.id and r.created_at <= p_as_of)
       and not coalesce(c.is_synthetic, false)
       and (coalesce(s.counts_as_visit, false) or coalesce(s.counts_as_revenue, false))
       and app.ci_visit_day_v699(s.occurred_at) between v_prev_from and p_to
  ),
  cur as (select * from base where in_window),
  prev as (select * from base where not in_window),
  cal as (
    select d::date as the_day, extract(isodow from d)::int as dow
      from generate_series(p_from::timestamp, p_to::timestamp, interval '1 day') d
  ),
  day_agg as (
    select c.visit_day,
           count(*) filter (where c.is_visit)::bigint                              as visits,
           coalesce(sum(c.amount_cents) filter (where c.is_revenue), 0)::bigint    as revenue_cents,
           count(distinct c.client_id) filter (where c.is_visit
                                                 and c.client_id is not null)::bigint
                                                                                   as identified_customers
      from cur c
     group by c.visit_day
  ),
  days as (
    select cal.the_day, cal.dow,
           case cal.dow when 1 then 'Monday' when 2 then 'Tuesday' when 3 then 'Wednesday'
                        when 4 then 'Thursday' when 5 then 'Friday' when 6 then 'Saturday'
                        else 'Sunday' end as label,
           coalesce(da.visits, 0)               as visits,
           coalesce(da.revenue_cents, 0)        as revenue_cents,
           coalesce(da.identified_customers, 0) as identified_customers
      from cal
      left join day_agg da on da.visit_day = cal.the_day
  ),
  cur_tot as (
    select coalesce(sum(d.visits), 0)::bigint        as visits,
           coalesce(sum(d.revenue_cents), 0)::bigint as revenue_cents
      from days d
  ),
  prev_tot as (
    select count(*) filter (where p.is_visit)::bigint                           as visits,
           coalesce(sum(p.amount_cents) filter (where p.is_revenue), 0)::bigint as revenue_cents
      from prev p
  ),
  weekday_occ as (
    select cal.dow, count(*)::bigint as occurrences from cal group by cal.dow
  ),
  weekdays as (
    select g.dow,
           case g.dow when 1 then 'Monday' when 2 then 'Tuesday' when 3 then 'Wednesday'
                      when 4 then 'Thursday' when 5 then 'Friday' when 6 then 'Saturday'
                      else 'Sunday' end as label,
           coalesce(sum(d.visits), 0)::bigint        as visits,
           coalesce(sum(d.revenue_cents), 0)::bigint as revenue_cents,
           coalesce(max(wo.occurrences), 0)::bigint  as occurrences
      from generate_series(1, 7) as g(dow)
      left join days d on d.dow = g.dow
      left join weekday_occ wo on wo.dow = g.dow
     group by g.dow
  ),
  weekday_rows as (
    select w.*,
           -- Visits per occurrence is a COUNT PER DAY, not a percentage: emitted as a plain
           -- 1dp number, null when the weekday never occurs inside the window.
           case when w.occurrences > 0
                then round(w.visits::numeric / w.occurrences, 1) else null end as per_occurrence,
           app.subgroup_evidence_v1(w.occurrences::int, 4) as evidence
      from weekdays w
  ),
  weekday_ranked as (
    select wr.* from weekday_rows wr
     where wr.evidence->>'status' = 'ok' and wr.per_occurrence is not null
  ),
  blocks as (
    select g.b as block_start,
           (case when g.b = 0 then '12am' when g.b < 12 then g.b || 'am'
                 when g.b = 12 then '12pm' else (g.b - 12) || 'pm' end)
           || '–' ||
           (case when (g.b + 2) % 24 = 0  then '12am'
                 when (g.b + 2) % 24 < 12 then ((g.b + 2) % 24) || 'am'
                 when (g.b + 2) % 24 = 12 then '12pm'
                 else (((g.b + 2) % 24) - 12) || 'pm' end) as label
      from generate_series(0, 22, 2) as g(b)
  ),
  block_agg as (
    select (extract(hour from c.local_ts)::int / 2) * 2 as block_start,
           count(*) filter (where c.is_visit)::bigint                              as visits,
           coalesce(sum(c.amount_cents) filter (where c.is_revenue), 0)::bigint    as revenue_cents,
           count(distinct c.visit_day) filter (where c.is_visit)::bigint           as days_with_visits
      from cur c
     group by 1
  ),
  block_rows as (
    select b.block_start, b.label,
           coalesce(ba.visits, 0)            as visits,
           coalesce(ba.revenue_cents, 0)     as revenue_cents,
           coalesce(ba.days_with_visits, 0)  as days_with_visits
      from blocks b
      left join block_agg ba on ba.block_start = b.block_start
  ),
  block_scored as (
    select br.*, app.rate_block_v1(br.visits, ct.visits) as share
      from block_rows br, cur_tot ct
  ),
  open_blocks as (
    select bs.* from block_scored bs where bs.days_with_visits >= 3
  ),
  -- age-by-block: identified visits only, classified through the gate-free v674 core
  ident as (
    select c.id, c.client_id, (extract(hour from c.local_ts)::int / 2) * 2 as block_start
      from cur c
     where c.is_visit and c.client_id is not null
  ),
  ident_clients as (
    select distinct client_id from ident
  ),
  classified as (
    select ic.client_id, d.dem->>'age_band' as age_band
      from ident_clients ic
      cross join lateral (
        select app.customer_demographics_core_v674(p_business, ic.client_id) as dem
      ) d
  ),
  age_cells as (
    select i.block_start, cl.age_band, count(*)::bigint as visits
      from ident i
      join classified cl on cl.client_id = i.client_id
     where cl.age_band is not null
     group by i.block_start, cl.age_band
  ),
  age_cov as (
    select count(*)::bigint as identified_visits,
           count(*) filter (where cl.age_band is not null)::bigint as age_known_visits
      from ident i
      left join classified cl on cl.client_id = i.client_id
  )
  select jsonb_build_object(
    'scope', jsonb_build_object('business_id', p_business, 'branch_id', p_branch,
                                'from', p_from, 'to', p_to),
    'visit_definition',
      'one qualifying sale row (the same grain public.get_ci_daypart_v1 counts), bucketed on '
      'the Asia/Singapore calendar day and hour of sale_occurred_at',
    'days', coalesce((
      select jsonb_agg(jsonb_build_object(
               'date', d.the_day, 'dow', d.dow, 'label', d.label,
               'visits', d.visits, 'revenue_cents', d.revenue_cents,
               'identified_customers', d.identified_customers)
             order by d.the_day)
        from days d), '[]'::jsonb),
    'previous', jsonb_build_object(
      'from', v_prev_from, 'to', v_prev_to,
      'visits', pt.visits, 'revenue_cents', pt.revenue_cents),
    'change', jsonb_build_object(
      'visits_pct',
        case when pt.visits > 0
             then round(100.0 * (ct.visits - pt.visits)::numeric / pt.visits, 1)
             else null end,
      'revenue_pct',
        case when pt.revenue_cents > 0
             then round(100.0 * (ct.revenue_cents - pt.revenue_cents)::numeric / pt.revenue_cents, 1)
             else null end),
    'weekdays', coalesce((
      select jsonb_agg(jsonb_build_object(
               'dow', wr.dow, 'label', wr.label, 'visits', wr.visits,
               'occurrences', wr.occurrences, 'per_occurrence', wr.per_occurrence,
               'revenue_cents', wr.revenue_cents, 'evidence', wr.evidence)
             order by wr.dow)
        from weekday_rows wr), '[]'::jsonb),
    'slowest_weekdays', coalesce((
      select jsonb_agg(jsonb_build_object(
               'dow', q.dow, 'label', q.label, 'visits', q.visits,
               'occurrences', q.occurrences, 'per_occurrence', q.per_occurrence)
             order by q.per_occurrence, q.dow)
        from (select * from weekday_ranked
               order by per_occurrence asc, dow asc limit 2) q), '[]'::jsonb),
    'busiest_weekdays', coalesce((
      select jsonb_agg(jsonb_build_object(
               'dow', q.dow, 'label', q.label, 'visits', q.visits,
               'occurrences', q.occurrences, 'per_occurrence', q.per_occurrence)
             order by q.per_occurrence desc, q.dow)
        from (select * from weekday_ranked
               order by per_occurrence desc, dow asc limit 2) q), '[]'::jsonb),
    'hour_blocks', coalesce((
      select jsonb_agg(jsonb_build_object(
               'block_start', bs.block_start, 'label', bs.label, 'visits', bs.visits,
               'revenue_cents', bs.revenue_cents, 'days_with_visits', bs.days_with_visits,
               'share', bs.share)
             order by bs.block_start)
        from block_scored bs), '[]'::jsonb),
    'open_blocks', coalesce((
      select jsonb_agg(jsonb_build_object(
               'block_start', ob.block_start, 'label', ob.label, 'visits', ob.visits,
               'days_with_visits', ob.days_with_visits)
             order by ob.block_start)
        from open_blocks ob), '[]'::jsonb),
    'open_block_rule', 'a two-hour block counts as open when it saw visits on at least 3 days',
    'slowest_blocks', coalesce((
      select jsonb_agg(jsonb_build_object(
               'block_start', q.block_start, 'label', q.label, 'visits', q.visits,
               'days_with_visits', q.days_with_visits)
             order by q.visits, q.block_start)
        from (select * from open_blocks
               order by visits asc, block_start asc limit 2) q), '[]'::jsonb),
    'busiest_blocks', coalesce((
      select jsonb_agg(jsonb_build_object(
               'block_start', q.block_start, 'label', q.label, 'visits', q.visits,
               'days_with_visits', q.days_with_visits)
             order by q.visits desc, q.block_start)
        from (select * from open_blocks
               order by visits desc, block_start asc limit 2) q), '[]'::jsonb),
    'age_by_block', coalesce((
      select jsonb_agg(jsonb_build_object(
               'block_start', ac.block_start,
               'label', b.label,
               'age_band', ac.age_band,
               'visits', case when ac.visits >= 5 then ac.visits else null end,
               'suppressed', ac.visits < 5)
             order by ac.block_start, ac.age_band)
        from age_cells ac
        join blocks b on b.block_start = ac.block_start), '[]'::jsonb),
    'age_by_block_note',
      'A cell below the shared 5-visit floor keeps its place and reports visits as null with '
      'suppressed true; it is never dropped and never printed as zero.',
    'coverage', jsonb_build_object(
      'age_known', app.rate_block_v1(av.age_known_visits, av.identified_visits)),
    'time_basis', 'sale_occurred_at',
    'basis_note',
      'Bucketed on sale_occurred_at -- the till timestamp a sale was RECORDED at -- converted '
      'to Asia/Singapore. This is TILL time, not arrival time or service-start time: neither is '
      'captured anywhere in this schema today, so a customer who waited before being served, or '
      'a booking whose service began well before checkout, is bucketed by when the sale closed, '
      'not by when they walked in.',
    'evidence_class', 'DIRECT_FACT',
    'observed_since', app.metric_observed_since_v1('ci_visit_rhythm', p_business))
    into v_result
    from cur_tot ct, prev_tot pt, age_cov av;

  return app.ci_envelope_v680('ci_visit_rhythm_v1', p_business, p_branch, p_from, p_to,
    p_as_of, app.ci_exclusion_counts_v680(p_business, p_branch, p_from, p_to, p_as_of), v_result);
end;
$$;
revoke all on function public.get_ci_visit_rhythm_v1(uuid,date,date,uuid,timestamptz)
  from public, anon;
grant execute on function public.get_ci_visit_rhythm_v1(uuid,date,date,uuid,timestamptz)
  to authenticated, service_role;

-- ---------------------------------------------------------------------------------------------
-- 5 · public.get_ci_demographic_totals_v1 — who the customers are, and what they buy.
-- ---------------------------------------------------------------------------------------------
create or replace function public.get_ci_demographic_totals_v1(
  p_business uuid, p_from date, p_to date, p_branch uuid default null,
  p_as_of timestamptz default clock_timestamp())
returns jsonb
language plpgsql stable security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_result jsonb;
begin
  perform app.ci_access_gate_v667(p_business, p_branch);
  if p_from is null or p_to is null or p_from > p_to then
    raise exception 'invalid date range' using errcode = '22023';
  end if;

  with valid as (
    select s.id, s.client_id, s.amount_cents,
           coalesce(s.counts_as_visit, false)   as is_visit,
           coalesce(s.counts_as_revenue, false) as is_revenue
      from public.sales s
      join public.clients c on c.id = s.client_id
     where s.business_id = p_business
       and (p_branch is null or s.branch_id = p_branch)
       and s.created_at <= p_as_of
       and s.client_id is not null
       and s.reversal_of is null
       and not exists (select 1 from public.sales r
                        where r.reversal_of = s.id and r.created_at <= p_as_of)
       and not coalesce(c.is_synthetic, false)
       and (coalesce(s.counts_as_visit, false) or coalesce(s.counts_as_revenue, false))
       and app.ci_visit_day_v699(s.occurred_at) between p_from and p_to
  ),
  population as (
    -- Identified, non-synthetic customers with at least one qualifying VISIT in the window.
    select v.client_id,
           coalesce(sum(v.amount_cents) filter (where v.is_revenue), 0)::bigint as revenue_cents
      from valid v
     group by v.client_id
    having bool_or(v.is_visit)
  ),
  classified as (
    select p.client_id, p.revenue_cents,
           d.dem->>'age_band' as age_band,
           d.dem->>'gender'   as gender
      from population p
      cross join lateral (
        select app.customer_demographics_core_v674(p_business, p.client_id) as dem
      ) d
  ),
  pop_tot as (
    select count(*)::bigint                                                     as customers,
           coalesce(sum(revenue_cents), 0)::bigint                              as revenue_cents,
           count(*) filter (where gender is not null)::bigint                   as gender_known,
           count(*) filter (where age_band is not null)::bigint                 as age_known,
           coalesce(sum(revenue_cents) filter (where gender is not null), 0)::bigint
                                                                                as gender_known_revenue,
           coalesce(sum(revenue_cents) filter (where age_band is not null), 0)::bigint
                                                                                as age_known_revenue
      from classified
  ),
  gender_rows as (
    select cl.gender,
           count(*)::bigint                        as customers,
           coalesce(sum(cl.revenue_cents), 0)::bigint as revenue_cents
      from classified cl
     where cl.gender is not null
     group by cl.gender
  ),
  age_rows as (
    select cl.age_band,
           count(*)::bigint                        as customers,
           coalesce(sum(cl.revenue_cents), 0)::bigint as revenue_cents
      from classified cl
     where cl.age_band is not null
     group by cl.age_band
  ),
  -- ------------------------------------------------------------------ catalogue items
  lines as (
    select si.item_type,
           coalesce(si.ref_id, si.product_id) as item_id,
           si.description,
           si.line_cents,
           v.client_id
      from public.sale_items si
      join valid v on v.id = si.sale_id
     where si.business_id = p_business
       and v.is_revenue
  ),
  item_tot as (
    select l.item_id, l.description, l.item_type,
           coalesce(sum(l.line_cents), 0)::bigint  as revenue_cents,
           count(distinct l.client_id)::bigint     as buyers
      from lines l
     group by l.item_id, l.description, l.item_type
     order by coalesce(sum(l.line_cents), 0) desc, l.description, l.item_id
     limit 15
  ),
  item_buyer as (
    select distinct it.item_id, it.description, it.item_type, l.client_id
      from item_tot it
      join lines l
        on l.item_id is not distinct from it.item_id
       and l.description is not distinct from it.description
       and l.item_type = it.item_type
  ),
  item_buyer_rev as (
    select it.item_id, it.description, it.item_type, l.client_id,
           coalesce(sum(l.line_cents), 0)::bigint as revenue_cents
      from item_tot it
      join lines l
        on l.item_id is not distinct from it.item_id
       and l.description is not distinct from it.description
       and l.item_type = it.item_type
     group by it.item_id, it.description, it.item_type, l.client_id
  ),
  item_known as (
    select ib.item_id, ib.description, ib.item_type,
           count(*) filter (where cl.gender is not null)::bigint   as buyers_known_gender,
           count(*) filter (where cl.age_band is not null)::bigint as buyers_known_age
      from item_buyer ib
      left join classified cl on cl.client_id = ib.client_id
     group by ib.item_id, ib.description, ib.item_type
  ),
  item_gender as (
    select ibr.item_id, ibr.description, ibr.item_type, cl.gender,
           count(*)::bigint                          as buyers,
           coalesce(sum(ibr.revenue_cents), 0)::bigint as revenue_cents
      from item_buyer_rev ibr
      join classified cl on cl.client_id = ibr.client_id
     where cl.gender is not null
     group by ibr.item_id, ibr.description, ibr.item_type, cl.gender
  ),
  item_age as (
    select ibr.item_id, ibr.description, ibr.item_type, cl.age_band,
           count(*)::bigint                          as buyers,
           coalesce(sum(ibr.revenue_cents), 0)::bigint as revenue_cents
      from item_buyer_rev ibr
      join classified cl on cl.client_id = ibr.client_id
     where cl.age_band is not null
     group by ibr.item_id, ibr.description, ibr.item_type, cl.age_band
  )
  select jsonb_build_object(
    'scope', jsonb_build_object('business_id', p_business, 'branch_id', p_branch,
                                'from', p_from, 'to', p_to),
    'population', jsonb_build_object(
      'customers', pt.customers, 'revenue_cents', pt.revenue_cents),
    'gender', coalesce((
      select jsonb_agg(jsonb_build_object(
               'gender', gr.gender,
               'customers', gr.customers,
               'share', case when app.subgroup_evidence_v1(pt.gender_known::int)->>'status' = 'ok'
                             then app.rate_block_v1(gr.customers, pt.gender_known)
                             else jsonb_set(app.rate_block_v1(gr.customers, pt.gender_known),
                                            '{pct}', 'null'::jsonb) end,
               'revenue_cents', gr.revenue_cents)
             order by gr.customers desc, gr.gender)
        from gender_rows gr), '[]'::jsonb),
    'unknown_gender', jsonb_build_object(
      'customers', pt.customers - pt.gender_known,
      'revenue_cents', pt.revenue_cents - pt.gender_known_revenue),
    'age_bands', coalesce((
      select jsonb_agg(jsonb_build_object(
               'age_band', ar.age_band,
               'customers', ar.customers,
               'share', case when app.subgroup_evidence_v1(pt.age_known::int)->>'status' = 'ok'
                             then app.rate_block_v1(ar.customers, pt.age_known)
                             else jsonb_set(app.rate_block_v1(ar.customers, pt.age_known),
                                            '{pct}', 'null'::jsonb) end,
               'revenue_cents', ar.revenue_cents)
             order by case ar.age_band
                        when 'under_20' then 1 when '20_24' then 2 when '25_30' then 3
                        when '31_40'    then 4 when '41_50' then 5 else 6 end,
                      ar.age_band)
        from age_rows ar), '[]'::jsonb),
    'unknown_age', jsonb_build_object(
      'customers', pt.customers - pt.age_known,
      'revenue_cents', pt.revenue_cents - pt.age_known_revenue),
    'evidence', jsonb_build_object(
      'gender', app.subgroup_evidence_v1(pt.gender_known::int),
      'age_band', app.subgroup_evidence_v1(pt.age_known::int)),
    'coverage', jsonb_build_object(
      'gender_known', app.rate_block_v1(pt.gender_known, pt.customers),
      'age_known', app.rate_block_v1(pt.age_known, pt.customers)),
    'by_item', coalesce((
      select jsonb_agg(jsonb_build_object(
               'item_id', it.item_id,
               'item_name', it.description,
               'item_type', it.item_type,
               'revenue_cents', it.revenue_cents,
               'buyers', it.buyers,
               'buyers_known_gender', ik.buyers_known_gender,
               'buyers_known_age', ik.buyers_known_age,
               'by_gender', coalesce((
                 select jsonb_agg(jsonb_build_object(
                          'gender', ig.gender,
                          'buyers', ig.buyers,
                          'revenue_cents', ig.revenue_cents,
                          'share_of_item_buyers',
                            case when app.subgroup_evidence_v1(ig.buyers::int)->>'status' = 'ok'
                                 then app.rate_block_v1(ig.buyers, ik.buyers_known_gender)
                                 else jsonb_set(
                                        app.rate_block_v1(ig.buyers, ik.buyers_known_gender),
                                        '{pct}', 'null'::jsonb) end,
                          'evidence', app.subgroup_evidence_v1(ig.buyers::int))
                        order by ig.buyers desc, ig.gender)
                   from item_gender ig
                  where ig.item_id is not distinct from it.item_id
                    and ig.description is not distinct from it.description
                    and ig.item_type = it.item_type), '[]'::jsonb),
               'by_age_band', coalesce((
                 select jsonb_agg(jsonb_build_object(
                          'age_band', ia.age_band,
                          'buyers', ia.buyers,
                          'revenue_cents', ia.revenue_cents,
                          'share_of_item_buyers',
                            case when app.subgroup_evidence_v1(ia.buyers::int)->>'status' = 'ok'
                                 then app.rate_block_v1(ia.buyers, ik.buyers_known_age)
                                 else jsonb_set(
                                        app.rate_block_v1(ia.buyers, ik.buyers_known_age),
                                        '{pct}', 'null'::jsonb) end,
                          'evidence', app.subgroup_evidence_v1(ia.buyers::int))
                        order by ia.buyers desc, ia.age_band)
                   from item_age ia
                  where ia.item_id is not distinct from it.item_id
                    and ia.description is not distinct from it.description
                    and ia.item_type = it.item_type), '[]'::jsonb))
             order by it.revenue_cents desc, it.description, it.item_id)
        from item_tot it
        left join item_known ik
          on ik.item_id is not distinct from it.item_id
         and ik.description is not distinct from it.description
         and ik.item_type = it.item_type), '[]'::jsonb),
    'item_share_note',
      'share_of_item_buyers is measured against that item''s buyers whose gender (or age) is '
      'known, not against every buyer -- the same known-population denominator the top-level '
      'shares use. Both numbers travel inside each rate block.',
    'time_basis', 'sale_occurred_at',
    'evidence_class', 'DIRECT_FACT',
    'limitation',
      'Gender and date of birth are known only for customers who gave them when creating their '
      'Peekaa account or whose profile a staff member completed; walk-ins added at the till '
      'have neither until someone records it.',
    'observed_since', app.metric_observed_since_v1('ci_demographic_totals', p_business))
    into v_result
    from pop_tot pt;

  return app.ci_envelope_v680('ci_demographic_totals_v1', p_business, p_branch, p_from, p_to,
    p_as_of, app.ci_exclusion_counts_v680(p_business, p_branch, p_from, p_to, p_as_of), v_result);
end;
$$;
revoke all on function public.get_ci_demographic_totals_v1(uuid,date,date,uuid,timestamptz)
  from public, anon;
grant execute on function public.get_ci_demographic_totals_v1(uuid,date,date,uuid,timestamptz)
  to authenticated, service_role;

commit;
