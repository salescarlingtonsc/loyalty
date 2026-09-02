-- NESTLY v683 — Customer Intelligence, phase CI-C: staff identity, rebooking, loyalty
-- programme value, discount dependency, and the marketing attribution taxonomy.
--
-- Closes acceptance checks 39, 40, 51-58 (docs/qa/CI-ACCEPTANCE-VERDICT-2026-09-02.md).
-- Every reader here follows the frozen CI-A/CI-B conventions:
--   * app.ci_access_gate_v667(p_business, p_branch) first (v667); app.ci_no_branch_dimension_v667
--     for a metric with no branch dimension in this schema.
--   * the v672 statistical authority embedded, never reimplemented: app.subgroup_evidence_v1,
--     app.rate_block_v1, app.distribution_block_v1, app.comparisons_note_v1
--     (docs/design/ci/CI-STAT-AUTHORITY-CONTRACT.md).
--   * "time_basis" naming the timestamp used, Asia/Singapore date bucketing.
--   * the three-part sale filter every v650/v667/v673 reader already uses: reversal_of is null,
--     no later row reverses it, and the client is not synthetic — plus counts_as_revenue /
--     counts_as_visit respected per kind.
--   * app.metric_observed_since_v1 where a watermark exists.
-- Proof: db/tests/executed/v683_corpus_behavioural_authorities.sql.
--
-- ============================================================================================
-- 1. STAFF IDENTITY (check 39) — what schema exists, and the one gap this migration closes
-- ============================================================================================
-- Read from the live migration history, not memory:
--   * appointments.staff_id (v11a)      — the BOOKED/ASSIGNED staff member. Single-column FK to
--     staff(id) (Q13, still open) — carried onto the completion sale by v12a's resolver, which
--     RAISES on a cross-tenant reference rather than forwarding it.
--   * sales.staff_id (v11a)             — the CREDITED staff for the whole sale: set directly by
--     record_quick_sale/record_cart_sale, or carried from appointments.staff_id at completion.
--   * sale_items.staff_id (v51)         — the per-LINE staff, composite FK'd to staff(id,
--     business_id) from day one (v51 already learned the v12a lesson).
--   * financial_operations.actor (v630) — auth.uid() of whoever recorded a quick-sale operation.
--     This is the closest existing thing to "the till operator", but it lives on the reservation
--     record, not on the sale itself, and nothing joins it back generically (financial_operations
--     also covers non-sale operation_types). There is NO column on `sales` naming who was
--     physically operating the till when it was inserted.
--
-- So per the task brief's own conditional ("if the till operator is not persisted on sales, add
-- it"): it is not, and this migration adds `sales.operator_user_id`. NO BACKFILL, deliberately,
-- in the tradition v12a set: there is no reconstructable "who was at the till" for a historical
-- row (financial_operations.actor exists for quick-sale rows but not for appointment-completion
-- or membership/gift-card rows, and inventing a partial backfill would make coverage look better
-- than it honestly is for the rows it silently skipped). Every sale from this migration forward
-- carries it; get_ci_staff_identity_v1's coverage rate_block makes the transition visible rather
-- than hiding it.
--
-- appointments.actual_provider_staff_id is new and DISTINCT from appointments.staff_id on
-- purpose: staff_id is who was BOOKED (set at scheduling, possibly reassigned before the visit);
-- actual_provider_staff_id is who ACTUALLY performed the service, set once at completion by
-- set_actual_provider_v683. Learning v12a's Q13 lesson directly: the new column's FK is the
-- COMPOSITE (actual_provider_staff_id, business_id) -> staff(id, business_id) from day one, so a
-- cross-tenant assignment is impossible at the schema level rather than merely tripwired at one
-- call site.
begin;

-- Shared helper (used by every rate-like field this migration adds below the staff-performance
-- reader): app.rate_block_v1 already refuses to manufacture a pct from a zero denominator, but it
-- has no opinion on the v672 sample floor, because it never sees the evidence block. A rate whose
-- denominator is small but nonzero (e.g. 2 mature redemptions, floor 5) still produces a "50.0%"
-- from rate_block_v1 alone — a verdict from below the floor. This wrapper keeps rate_block_v1 as
-- the one authority for numerator/denominator/pct arithmetic and adds exactly one rule on top:
-- when the caller's own subgroup_evidence_v1 block says 'insufficient', the pct is nulled while
-- numerator and denominator (counts) are left exactly as computed.
create or replace function app.rate_block_floor_gated_v683(p_num bigint, p_den bigint, p_evidence jsonb)
returns jsonb
language sql immutable
set search_path to 'pg_catalog', 'app', 'pg_temp'
as $$
  select case when (p_evidence->>'status') = 'ok'
           then app.rate_block_v1(p_num, p_den)
           else jsonb_set(app.rate_block_v1(p_num, p_den), '{pct}', 'null'::jsonb)
         end
$$;
revoke all on function app.rate_block_floor_gated_v683(bigint,bigint,jsonb) from public, anon, authenticated;
grant execute on function app.rate_block_floor_gated_v683(bigint,bigint,jsonb) to authenticated, service_role;

alter table public.sales add column operator_user_id uuid;
alter table public.sales
  add constraint sales_operator_user_fk
  foreign key (operator_user_id) references auth.users(id) on delete set null;

comment on column public.sales.operator_user_id is
  'v683: auth.uid() of whoever the till session belonged to at INSERT time. Defaulted by '
  'trg_sales_operator_default_v683 when the writer does not set it explicitly. Write-once in '
  'practice: trg_sales_immutable_guard (v10.1) blocks every UPDATE on this table, this column '
  'included, so there is no separate guard to add. NOT backfilled for rows inserted before this '
  'migration (no such row records who operated the till) — those rows stay NULL forever, which '
  'get_ci_staff_identity_v1 reports as coverage, not silence.';

create or replace function app.sales_operator_default_v683()
returns trigger
language plpgsql
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
begin
  if new.operator_user_id is null then
    new.operator_user_id := auth.uid();
  end if;
  return new;
end;
$$;

-- BEFORE INSERT, and named zzz_* is unnecessary here (nothing else on this table reads
-- operator_user_id), but the trigger must run BEFORE trg_sales_default_branch and friends have a
-- chance to matter, which a bare BEFORE INSERT already guarantees regardless of name — Postgres
-- fires same-timing triggers in name order, and this one has no ordering dependency on any other
-- BEFORE INSERT trigger on this table, so no zzz_ prefix is needed.
create trigger trg_sales_operator_default_v683
  before insert on public.sales
  for each row execute function app.sales_operator_default_v683();

alter table public.appointments add column actual_provider_staff_id uuid;
alter table public.appointments
  add constraint appointments_actual_provider_id_business_fk
  foreign key (actual_provider_staff_id, business_id)
  references public.staff(id, business_id);

comment on column public.appointments.actual_provider_staff_id is
  'v683: who ACTUALLY performed the service, set once at completion via '
  'public.set_actual_provider_v683. Distinct from staff_id (who was BOOKED/assigned at scheduling '
  'time, and may have been reassigned before the visit happened). Composite FK to staff(id, '
  'business_id) from day one — appointments.staff_id is a single-column FK and can reference '
  'another tenant''s staff row (v12a Q13, still open); this column does not repeat that mistake.';

create or replace function public.set_actual_provider_v683(
  p_business uuid, p_appointment uuid, p_staff uuid)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_appt public.appointments%rowtype;
begin
  select * into v_appt from public.appointments
   where id = p_appointment and business_id = p_business
   for update;
  if not found then
    raise exception 'appointment not found' using errcode = '22023';
  end if;
  if auth.uid() is null
     or not app.can_module_write(p_business, 'appointments')
     or not app.can_see_branch(p_business, v_appt.branch_id) then
    raise exception 'appointment write access is required' using errcode = '42501';
  end if;
  if p_staff is not null
     and not exists (select 1 from public.staff st
                      where st.id = p_staff and st.business_id = p_business) then
    raise exception 'staff % does not belong to business %', p_staff, p_business
      using errcode = '22023';
  end if;
  update public.appointments
     set actual_provider_staff_id = p_staff
   where id = p_appointment and business_id = p_business;
  return jsonb_build_object('id', p_appointment, 'actual_provider_staff_id', p_staff);
end;
$$;
revoke all on function public.set_actual_provider_v683(uuid,uuid,uuid) from public, anon;
grant execute on function public.set_actual_provider_v683(uuid,uuid,uuid) to authenticated, service_role;

-- --------------------------------------------------------------------------------------------
-- get_ci_staff_identity_v1 — per-sale identity coverage. Population: sales in [p_from,p_to]
-- (Asia/Singapore, occurred_at), the standard three-part exclusion filter, branch-scoped when
-- p_branch is given. No revenue/visit restriction — this is an IDENTITY coverage question, not
-- a financial one, so a $0 or non-counting sale still has an identity worth reporting on.
-- Capped at 500 rows (the v667 category_customers convention) with the fact stated, never
-- silently truncated.
-- --------------------------------------------------------------------------------------------
create or replace function public.get_ci_staff_identity_v1(
  p_business uuid, p_from date, p_to date, p_branch uuid default null)
returns jsonb
language plpgsql stable security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_rows jsonb;
  v_total integer;
  v_booked integer;
  v_credited integer;
  v_line integer;
  v_operator integer;
  v_actual integer;
begin
  perform app.ci_access_gate_v667(p_business, p_branch);

  with pop as (
    select s.id as sale_id, s.appointment_id, s.staff_id as credited_staff_id,
           s.operator_user_id, a.staff_id as booked_staff_id,
           a.actual_provider_staff_id as actual_provider
      from public.sales s
      join public.clients c on c.id = s.client_id
      left join public.appointments a on a.id = s.appointment_id and a.business_id = s.business_id
     where s.business_id = p_business
       and (p_branch is null or s.branch_id = p_branch)
       and s.reversal_of is null
       and not exists (select 1 from public.sales r where r.reversal_of = s.id)
       and not coalesce(c.is_synthetic, false)
       and (s.occurred_at at time zone 'Asia/Singapore')::date between p_from and p_to
  ),
  pop_lines as (
    select p.*,
           (select jsonb_agg(distinct si.staff_id) filter (where si.staff_id is not null)
              from public.sale_items si
             where si.sale_id = p.sale_id and si.item_type = 'service') as line_staff
      from pop p
  )
  select
      count(*),
      count(*) filter (where booked_staff_id is not null),
      count(*) filter (where credited_staff_id is not null),
      count(*) filter (where line_staff is not null),
      count(*) filter (where operator_user_id is not null),
      count(*) filter (where actual_provider is not null)
    into v_total, v_booked, v_credited, v_line, v_operator, v_actual
    from pop_lines;

  with pop as (
    select s.id as sale_id, s.appointment_id, s.staff_id as credited_staff_id,
           s.operator_user_id, a.staff_id as booked_staff_id,
           a.actual_provider_staff_id as actual_provider
      from public.sales s
      join public.clients c on c.id = s.client_id
      left join public.appointments a on a.id = s.appointment_id and a.business_id = s.business_id
     where s.business_id = p_business
       and (p_branch is null or s.branch_id = p_branch)
       and s.reversal_of is null
       and not exists (select 1 from public.sales r where r.reversal_of = s.id)
       and not coalesce(c.is_synthetic, false)
       and (s.occurred_at at time zone 'Asia/Singapore')::date between p_from and p_to
  ),
  pop_lines as (
    select p.*,
           (select jsonb_agg(distinct si.staff_id) filter (where si.staff_id is not null)
              from public.sale_items si
             where si.sale_id = p.sale_id and si.item_type = 'service') as line_staff
      from pop p
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'sale_id', sale_id,
           'booked_staff_id', booked_staff_id,
           'credited_staff_id', credited_staff_id,
           'line_staff', coalesce(line_staff, '[]'::jsonb),
           'operator_user_id', operator_user_id,
           'actual_provider', actual_provider)), '[]'::jsonb)
    into v_rows
    from (select * from pop_lines order by sale_id limit 500) x;

  return jsonb_build_object(
    'scope', jsonb_build_object('business_id', p_business, 'branch_id', p_branch,
                                'from', p_from, 'to', p_to),
    'time_basis', 'sale_occurred_at',
    'sales', v_rows,
    'truncated', v_total > 500,
    'coverage', jsonb_build_object(
      'total_sales', v_total,
      'booked_staff_id', app.rate_block_v1(v_booked, v_total),
      'credited_staff_id', app.rate_block_v1(v_credited, v_total),
      'line_staff', app.rate_block_v1(v_line, v_total),
      'operator_user_id', app.rate_block_v1(v_operator, v_total),
      'actual_provider', app.rate_block_v1(v_actual, v_total)));
end;
$$;
revoke all on function public.get_ci_staff_identity_v1(uuid,date,date,uuid) from public, anon;
grant execute on function public.get_ci_staff_identity_v1(uuid,date,date,uuid) to authenticated, service_role;

-- ============================================================================================
-- 2. MIX-ADJUSTED STAFF PERFORMANCE (check 40)
-- ============================================================================================
-- "Credited staff" here means sale_items.staff_id — the per-LINE attribution (v51), which is the
-- finest attribution the schema carries and the one a mix-adjustment needs (a mix is a property
-- of individual service lines, not of a whole multi-line sale). This is a deliberately different
-- meaning of "credited" from get_ci_staff_identity_v1's credited_staff_id (sales.staff_id, the
-- whole-sale attribution) — the two readers answer different questions and are not meant to
-- agree number-for-number.
--
-- Firm-wide average ticket per service is computed over the SAME population the analysis scopes
-- to (branch-filtered when p_branch is given) — deliberately: comparing a staff member against a
-- firm average computed from a DIFFERENT branch's price list would be comparing them against
-- prices they were never in a position to charge.
create or replace function public.get_ci_staff_performance_v1(
  p_business uuid, p_from date, p_to date, p_branch uuid default null)
returns jsonb
language plpgsql stable security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_staff jsonb;
  v_examined integer;
begin
  perform app.ci_access_gate_v667(p_business, p_branch);

  with lines as (
    select si.staff_id, si.ref_id as service_id, si.line_cents
      from public.sale_items si
      join public.sales s on s.id = si.sale_id
      join public.clients c on c.id = s.client_id
     where si.business_id = p_business
       and si.item_type = 'service'
       and si.ref_id is not null
       and (p_branch is null or s.branch_id = p_branch)
       and s.reversal_of is null
       and not exists (select 1 from public.sales r where r.reversal_of = s.id)
       and coalesce(s.counts_as_revenue, false)
       and not coalesce(c.is_synthetic, false)
       and (s.occurred_at at time zone 'Asia/Singapore')::date between p_from and p_to
  ),
  firm_service_avg as (
    select service_id, avg(line_cents) as avg_ticket
      from lines
     group by service_id
  ),
  staff_service as (
    select l.staff_id, l.service_id, count(*) as visits, sum(l.line_cents) as revenue
      from lines l
     where l.staff_id is not null
     group by l.staff_id, l.service_id
  ),
  staff_totals as (
    select staff_id,
           sum(visits) as total_visits,
           sum(revenue) as actual_revenue_cents,
           sum(visits * fsa.avg_ticket) as expected_revenue_cents
      from staff_service ss
      join firm_service_avg fsa on fsa.service_id = ss.service_id
     group by staff_id
  )
  select count(*) into v_examined from staff_totals;

  with lines as (
    select si.staff_id, si.ref_id as service_id, si.line_cents
      from public.sale_items si
      join public.sales s on s.id = si.sale_id
      join public.clients c on c.id = s.client_id
     where si.business_id = p_business
       and si.item_type = 'service'
       and si.ref_id is not null
       and (p_branch is null or s.branch_id = p_branch)
       and s.reversal_of is null
       and not exists (select 1 from public.sales r where r.reversal_of = s.id)
       and coalesce(s.counts_as_revenue, false)
       and not coalesce(c.is_synthetic, false)
       and (s.occurred_at at time zone 'Asia/Singapore')::date between p_from and p_to
  ),
  staff_service as (
    select l.staff_id, l.service_id, count(*) as visits, sum(l.line_cents) as revenue
      from lines l
     where l.staff_id is not null
     group by l.staff_id, l.service_id
  ),
  firm_service_avg as (
    select service_id, avg(line_cents) as avg_ticket
      from lines
     group by service_id
  ),
  staff_totals as (
    select ss.staff_id,
           sum(ss.visits)::integer as total_visits,
           sum(ss.revenue)::bigint as actual_revenue_cents,
           round(sum(ss.visits * fsa.avg_ticket))::bigint as expected_revenue_cents
      from staff_service ss
      join firm_service_avg fsa on fsa.service_id = ss.service_id
     group by ss.staff_id
  ),
  scored as (
    select t.*, app.subgroup_evidence_v1(t.total_visits) as evidence
      from staff_totals t
  )
  -- CI-STAT-AUTHORITY-CONTRACT: raw COUNTS may display at any n, but a rate-like VERDICT
  -- (revenue_per_visit_cents, the adjusted index, and the expected-revenue figure it is derived
  -- from) is null the moment evidence is below the floor — an index computed from 4 visits is a
  -- verdict from below the floor, exactly the failure mode the authority exists to prevent.
  select coalesce(jsonb_agg(jsonb_build_object(
           'staff_id', t.staff_id,
           'full_name', st.full_name,
           'unadjusted', jsonb_build_object(
             'revenue_cents', t.actual_revenue_cents,
             'visits', t.total_visits,
             'revenue_per_visit_cents',
               case when (t.evidence->>'status') = 'ok' and t.total_visits > 0
                 then round(t.actual_revenue_cents::numeric / t.total_visits, 2)
                 else null end),
           'adjusted', jsonb_build_object(
             'expected_revenue_cents',
               case when (t.evidence->>'status') = 'ok'
                 then t.expected_revenue_cents else null end,
             'index',
               case when (t.evidence->>'status') = 'ok' and t.expected_revenue_cents > 0
                 then round(t.actual_revenue_cents::numeric / t.expected_revenue_cents, 2)
                 else null end),
           'evidence', t.evidence)
         order by t.actual_revenue_cents desc), '[]'::jsonb)
    into v_staff
    from scored t
    left join public.staff st on st.id = t.staff_id and st.business_id = p_business;

  return jsonb_build_object(
    'scope', jsonb_build_object('business_id', p_business, 'branch_id', p_branch,
                                'from', p_from, 'to', p_to),
    'time_basis', 'sale_occurred_at',
    'staff', v_staff,
    'comparisons', app.comparisons_note_v1(v_examined, v_examined),
    'note', 'adjusted.index = actual revenue / expected revenue, where expected revenue is this '
            'staff member''s own visit counts per service priced at the firm-wide average ticket '
            'for that service. 1.00 means the staff member performs exactly at the firm average '
            'given their own service mix; it does not mean they earn the same raw revenue as '
            'anyone else.');
end;
$$;
revoke all on function public.get_ci_staff_performance_v1(uuid,date,date,uuid) from public, anon;
grant execute on function public.get_ci_staff_performance_v1(uuid,date,date,uuid) to authenticated, service_role;

-- ============================================================================================
-- 3. REBOOKING (checks 51-53)
-- ============================================================================================
-- Cohorts are defined on the appointment's OWN booked_from_appointment_id (v632): "rebooked" =
-- this appointment was itself created from a prior appointment's completion screen; "other" =
-- it was booked through any other channel (portal, phone, walk-in, or a normal staff booking).
-- The "visit" anchor is the completed appointment's linked sale (one_sale_per_appointment, v6),
-- filtered through the same three-part exclusion every other reader uses. "Within window" asks
-- whether that same client had ANOTHER qualifying visit within 60 days after this one — testing
-- whether a rebooked-at-departure visit is followed by continued engagement, not whether the
-- rebooking itself "worked" (the rebooked appointment already IS the next visit).
--
-- JUDGEMENT CALL, stated plainly because it drives the mandatory limitation: this is an
-- observational comparison between two self-selected groups. A customer whose staff member
-- rebooked them at departure was not randomly assigned to that treatment — staff more often
-- rebook customers who are already engaged, and customers more often accept a rebooking offer
-- when they already intend to return. So a higher within-window rate in the "rebooked" cohort is
-- exactly as consistent with "already-loyal customers get rebooked AND return" as it is with
-- "getting rebooked makes customers return". The reader states this in a fixed limitation string
-- (check 53) and evidence_class is always 'ASSOCIATION', never anything stronger.
create or replace function public.get_ci_rebooking_v1(
  p_business uuid, p_from date, p_to date, p_branch uuid default null)
returns jsonb
language plpgsql stable security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_today date := (now() at time zone 'Asia/Singapore')::date;
  v_window_days constant integer := 60;
  v_rebooked jsonb;
  v_other jsonb;
begin
  perform app.ci_access_gate_v667(p_business, p_branch);

  with visits as (
    select a.id as appt_id, a.client_id, a.service_id,
           a.booked_from_appointment_id is not null as is_rebooked,
           (s.occurred_at at time zone 'Asia/Singapore')::date as visit_date,
           s.occurred_at as visit_at
      from public.appointments a
      join public.sales s on s.appointment_id = a.id and s.business_id = a.business_id
      join public.clients c on c.id = a.client_id
     where a.business_id = p_business
       and a.status = 'completed'
       and (p_branch is null or s.branch_id = p_branch)
       and s.reversal_of is null
       and not exists (select 1 from public.sales r where r.reversal_of = s.id)
       and coalesce(s.counts_as_visit, false)
       and not coalesce(c.is_synthetic, false)
       and (s.occurred_at at time zone 'Asia/Singapore')::date between p_from and p_to
  ),
  scored as (
    select v.*,
           (v.visit_date + v_window_days) <= v_today as is_mature,
           exists (
             select 1 from public.sales s2
             where s2.business_id = p_business
               and s2.client_id = v.client_id
               and coalesce(s2.counts_as_visit, false)
               and s2.reversal_of is null
               and not exists (select 1 from public.sales r2 where r2.reversal_of = s2.id)
               and s2.occurred_at > v.visit_at
               and s2.occurred_at <= v.visit_at + make_interval(days => v_window_days)
           ) as returned_within_window
      from visits v
  ),
  cohort as (
    select is_rebooked,
           count(*) as n,
           count(*) filter (where is_mature) as n_mature,
           count(*) filter (where is_mature and returned_within_window) as n_returned,
           jsonb_agg(jsonb_build_object('service_id', service_id)) as svc_raw
      from scored
     group by is_rebooked
  ),
  composition as (
    select is_rebooked, service_id, count(*) as n
      from scored
     where service_id is not null
     group by is_rebooked, service_id
  )
  select
    (select jsonb_build_object(
       'n', c.n,
       'evidence', app.subgroup_evidence_v1(c.n_mature::integer),
       'immature', c.n - c.n_mature,
       'within_window', app.rate_block_floor_gated_v683(c.n_returned, c.n_mature, app.subgroup_evidence_v1(c.n_mature::integer)),
       'composition', coalesce((
         select jsonb_agg(jsonb_build_object(
                  'service_id', cm.service_id,
                  'share', app.rate_block_v1(cm.n, c.n))
                order by cm.n desc)
           from composition cm where cm.is_rebooked = true), '[]'::jsonb))
       from cohort c where c.is_rebooked = true),
    (select jsonb_build_object(
       'n', c.n,
       'evidence', app.subgroup_evidence_v1(c.n_mature::integer),
       'immature', c.n - c.n_mature,
       'within_window', app.rate_block_floor_gated_v683(c.n_returned, c.n_mature, app.subgroup_evidence_v1(c.n_mature::integer)),
       'composition', coalesce((
         select jsonb_agg(jsonb_build_object(
                  'service_id', cm.service_id,
                  'share', app.rate_block_v1(cm.n, c.n))
                order by cm.n desc)
           from composition cm where cm.is_rebooked = false), '[]'::jsonb))
       from cohort c where c.is_rebooked = false)
    into v_rebooked, v_other;

  return jsonb_build_object(
    'scope', jsonb_build_object('business_id', p_business, 'branch_id', p_branch,
                                'from', p_from, 'to', p_to),
    'time_basis', 'sale_occurred_at',
    'window_days', v_window_days,
    'cohorts', jsonb_build_object(
      'rebooked_at_departure', coalesce(v_rebooked,
        jsonb_build_object('n', 0, 'evidence', app.subgroup_evidence_v1(0),
                            'immature', 0, 'within_window', app.rate_block_v1(0,0),
                            'composition', '[]'::jsonb)),
      'other', coalesce(v_other,
        jsonb_build_object('n', 0, 'evidence', app.subgroup_evidence_v1(0),
                            'immature', 0, 'within_window', app.rate_block_v1(0,0),
                            'composition', '[]'::jsonb))),
    'evidence_class', 'ASSOCIATION',
    'limitation', 'Association only: customers who rebook at departure are not a random draw. '
      'This comparison does not establish that rebooking improves subsequent return; the '
      'difference may simply reflect that already more loyal customers are the ones who rebook.');
end;
$$;
revoke all on function public.get_ci_rebooking_v1(uuid,date,date,uuid) from public, anon;
grant execute on function public.get_ci_rebooking_v1(uuid,date,date,uuid) to authenticated, service_role;

commit;

-- ============================================================================================
-- 4. LOYALTY PROGRAMMES (checks 54-55)
-- ============================================================================================
-- SCHEMA FOUND, per programme type (grep'd from the live migration history, not assumed):
--   points   — public.business_programmes (kind='points', v308 spine) for participation/active;
--              public.loyalty_redemptions (v23, consumes_balance=true since v323) for the
--              redemption event, redeemed_at.
--   stamps   — public.business_programmes (kind='stamps') for participation/active;
--              public.stamp_milestone_claims (v323), programme_id -> business_programmes(id,
--              business_id), claimed_at, for the redemption event. (Not reward_grants /
--              retention_programs — that is a SEPARATE, older visit-goal reward engine (v2/v9/
--              v10) that predates the versioned stamp card; it is not read here because it is not
--              what public.business_programmes(kind='stamps') actually drives.)
--   tiers    — public.business_programmes (kind='tiers') for participation/active;
--              public.tier_transition_events (v633, new_tier_id is not null) for "currently
--              enrolled in a tier"; public.benefit_fulfilments (v56/v370,
--              fulfilment_kind='checkout_discount', canonical_benefit_key like 'tierdiscount:%')
--              for the redemption event (a tier discount applied at checkout), occurred_at.
--   referral — public.business_programmes (kind='referral') for participation/active;
--              public.referrals (status='rewarded', qualified_at) for the redemption event.
--   welcome  — public.business_welcome_offers_v215 (active) for configuration;
--              public.welcome_offer_grants_v215 (status='redeemed', redeemed_at) for the
--              redemption event. NOT part of the v308 four-programme spine (spine is points/
--              tiers/stamps/referral only) — configuration existence is its own signal here.
--   birthday — public.birthday_program_versions (any row = configured) for configuration;
--              public.customer_birthday_redemptions (operation_kind='redemption', active=true)
--              for the redemption event, created_at.
--   bring-back — public.bringback_campaigns_v361 (active, not deleted) for configuration;
--              public.bringback_grants_v361 (status='redeemed', redeemed_at) for the redemption
--              event. public.growth_execution_results_v108 (recommendation_type =
--              'lapsed_high_value_bring_back') is a SEPARATE, earlier-built, measured
--              treatment/holdout bring-back mechanism with real incrementality data — linked into
--              this programme's incrementality field when it exists, exactly per the task brief.
--
-- All seven programme types share the same "eligible" population (a firm's addressable
-- customers in the window: non-synthetic clients with >=1 qualifying visit in [p_from,p_to]) so
-- participation rates are comparable across programmes. "Enrolled" is programme-specific and
-- computed over the customer's ENTIRE history (not window-boxed) because "has this customer ever
-- engaged with this programme" is what "enrolled" means; the redemption EVENTS themselves stay
-- window + maturity-boxed like every other CI-B/CI-C reader.
begin;

-- Internal helper, not an API surface: the SAME "eligible" population set-based, reused both to
-- COUNT eligible customers and to INTERSECT each programme's "enrolled" count against it, so
-- enrolled can never exceed eligible (a client who engaged with a programme but had no
-- qualifying visit in this window is real, but is out of scope for a rate computed against this
-- window's addressable population).
create or replace function app.ci_loyalty_eligible_v683(p_business uuid, p_from date, p_to date)
returns table (client_id uuid)
language sql stable security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
  select distinct c.id
    from public.clients c
    join public.sales s on s.client_id = c.id and s.business_id = p_business
   where c.business_id = p_business
     and not coalesce(c.is_synthetic, false)
     and coalesce(s.counts_as_visit, false)
     and s.reversal_of is null
     and not exists (select 1 from public.sales r where r.reversal_of = s.id)
     and (s.occurred_at at time zone 'Asia/Singapore')::date between p_from and p_to
$$;
revoke all on function app.ci_loyalty_eligible_v683(uuid,date,date) from public, anon, authenticated;
grant execute on function app.ci_loyalty_eligible_v683(uuid,date,date) to service_role;

-- Internal helper, not an API surface: given a jsonb array of {"client_id","at"} redemption
-- events, returns the maturity-gated paid-return-within-30d rate_block and the cadence-based
-- cannibalisation proxy. One pass, one set of subqueries, reused by all seven programme blocks
-- below instead of being copy-pasted seven times (the v672 lesson: one authority, not N floors).
create or replace function app.ci_loyalty_outcomes_v683(p_business uuid, p_events jsonb)
returns jsonb
language plpgsql stable security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_today date := (now() at time zone 'Asia/Singapore')::date;
  v_total integer; v_mature integer; v_returned integer; v_within integer; v_known integer;
begin
  with ev as (
    select (e->>'client_id')::uuid as client_id, (e->>'at')::timestamptz as at
      from jsonb_array_elements(coalesce(p_events, '[]'::jsonb)) e
  ),
  scored as (
    select ev.client_id, ev.at,
           ((ev.at at time zone 'Asia/Singapore')::date + 30) <= v_today as is_mature,
           exists (
             select 1 from public.sales s
             where s.business_id = p_business and s.client_id = ev.client_id
               and coalesce(s.counts_as_visit, false)
               and s.reversal_of is null
               and not exists (select 1 from public.sales r where r.reversal_of = s.id)
               and s.occurred_at > ev.at
               and s.occurred_at <= ev.at + interval '30 days'
           ) as returned,
           (app.customer_cadence_v1(p_business, ev.client_id, ev.at)->>'deviation_state') as state
      from ev
  )
  select count(*),
         count(*) filter (where is_mature),
         count(*) filter (where is_mature and returned),
         count(*) filter (where is_mature and state = 'within_cycle'),
         count(*) filter (where is_mature and state is not null)
    into v_total, v_mature, v_returned, v_within, v_known
    from scored;

  -- CI-STAT-AUTHORITY-CONTRACT: paid_return_within_30d and cannibalisation_proxy.within_cycle are
  -- rate-like verdicts, each floor-gated on ITS OWN denominator (redemptions_mature for the
  -- return rate; v_known — mature redemptions with a resolvable cadence state — for the
  -- cannibalisation proxy, which can differ when a mature redemption's client has no prior visit
  -- at all to score). The raw counts (redemptions_total/mature/immature) are never gated.
  return jsonb_build_object(
    'redemptions_total', v_total,
    'redemptions_mature', v_mature,
    'immature', v_total - v_mature,
    'paid_return_within_30d',
      app.rate_block_floor_gated_v683(v_returned, v_mature, app.subgroup_evidence_v1(v_mature)),
    'cannibalisation_proxy', jsonb_build_object(
      'within_cycle',
        app.rate_block_floor_gated_v683(v_within, v_known, app.subgroup_evidence_v1(v_known)),
      'note', 'A redemption scored ''within_cycle'' at the moment it happened means the '
              'customer''s own visit rhythm already put them due to come in anyway; ''overdue''/'
              '''due''/''late'' means the redemption coincides with a visit outside their usual '
              'rhythm. This is a proxy, not a measured incremental effect — see the '
              'incrementality field.'));
end;
$$;
revoke all on function app.ci_loyalty_outcomes_v683(uuid,jsonb) from public, anon, authenticated;
grant execute on function app.ci_loyalty_outcomes_v683(uuid,jsonb) to service_role;

create or replace function public.get_ci_loyalty_programmes_v1(
  p_business uuid, p_from date, p_to date, p_branch uuid default null)
returns jsonb
language plpgsql stable security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_eligible integer;
  v_incrementality_unavailable constant jsonb :=
    jsonb_build_object('status', 'unavailable',
      'reason', 'no holdout; see v108 for the measured bring-back path');
  v_points jsonb; v_stamps jsonb; v_tiers jsonb; v_referral jsonb;
  v_welcome jsonb; v_birthday jsonb; v_bringback jsonb;

  v_spine_points record; v_spine_stamps record; v_spine_tiers record; v_spine_referral record;
  v_enrolled integer; v_events jsonb; v_outcomes jsonb;
  v_bb_incrementality jsonb;
begin
  perform app.ci_access_gate_v667(p_business, p_branch);
  perform app.ci_no_branch_dimension_v667(p_branch, 'loyalty programmes');

  select count(*) into v_eligible from app.ci_loyalty_eligible_v683(p_business, p_from, p_to);

  -- ---------------------------------------------------------------------------------------
  -- points
  -- ---------------------------------------------------------------------------------------
  select * into v_spine_points from public.business_programmes
   where business_id = p_business and kind = 'points';
  if not found then
    v_points := jsonb_build_object('status', 'not_configured');
  else
    select count(distinct pl.client_id) into v_enrolled
      from public.points_ledger pl
      join public.clients c on c.id = pl.client_id
      join app.ci_loyalty_eligible_v683(p_business, p_from, p_to) el on el.client_id = pl.client_id
     where pl.business_id = p_business and not coalesce(c.is_synthetic, false);
    select coalesce(jsonb_agg(jsonb_build_object('client_id', lr.client_id, 'at', lr.redeemed_at)), '[]'::jsonb)
      into v_events
      from public.loyalty_redemptions lr
     where lr.business_id = p_business
       and coalesce(lr.consumes_balance, true)
       and (lr.redeemed_at at time zone 'Asia/Singapore')::date between p_from and p_to;
    v_outcomes := app.ci_loyalty_outcomes_v683(p_business, v_events);
    v_points := jsonb_build_object(
      'status', 'ready',
      'programme_active', v_spine_points.active,
      'participation', app.rate_block_v1(v_enrolled, v_eligible),
      'redemptions', v_outcomes->'redemptions_total',
      'immature', v_outcomes->'immature',
      'paid_return_within_30d', v_outcomes->'paid_return_within_30d',
      'cannibalisation_proxy', v_outcomes->'cannibalisation_proxy',
      'incrementality', v_incrementality_unavailable);
  end if;

  -- ---------------------------------------------------------------------------------------
  -- stamps
  -- ---------------------------------------------------------------------------------------
  select * into v_spine_stamps from public.business_programmes
   where business_id = p_business and kind = 'stamps';
  if not found or to_regclass('public.stamp_milestone_claims') is null then
    v_stamps := jsonb_build_object('status', 'not_configured');
  else
    select count(distinct smc.client_id) into v_enrolled
      from public.stamp_milestone_claims smc
      join public.clients c on c.id = smc.client_id
      join app.ci_loyalty_eligible_v683(p_business, p_from, p_to) el on el.client_id = smc.client_id
     where smc.business_id = p_business and smc.programme_id = v_spine_stamps.id
       and not coalesce(c.is_synthetic, false);
    select coalesce(jsonb_agg(jsonb_build_object('client_id', smc.client_id, 'at', smc.claimed_at)), '[]'::jsonb)
      into v_events
      from public.stamp_milestone_claims smc
     where smc.business_id = p_business and smc.programme_id = v_spine_stamps.id
       and (smc.claimed_at at time zone 'Asia/Singapore')::date between p_from and p_to;
    v_outcomes := app.ci_loyalty_outcomes_v683(p_business, v_events);
    v_stamps := jsonb_build_object(
      'status', 'ready',
      'programme_active', v_spine_stamps.active,
      'participation', app.rate_block_v1(v_enrolled, v_eligible),
      'redemptions', v_outcomes->'redemptions_total',
      'immature', v_outcomes->'immature',
      'paid_return_within_30d', v_outcomes->'paid_return_within_30d',
      'cannibalisation_proxy', v_outcomes->'cannibalisation_proxy',
      'incrementality', v_incrementality_unavailable);
  end if;

  -- ---------------------------------------------------------------------------------------
  -- tiers
  -- ---------------------------------------------------------------------------------------
  select * into v_spine_tiers from public.business_programmes
   where business_id = p_business and kind = 'tiers';
  if not found then
    v_tiers := jsonb_build_object('status', 'not_configured');
  else
    select count(distinct t.client_id) into v_enrolled
      from (
        select distinct on (te.client_id) te.client_id, te.new_tier_id
          from public.tier_transition_events te
         where te.business_id = p_business
         order by te.client_id, te.at desc
      ) t
      join public.clients c on c.id = t.client_id
      join app.ci_loyalty_eligible_v683(p_business, p_from, p_to) el on el.client_id = t.client_id
     where t.new_tier_id is not null and not coalesce(c.is_synthetic, false);
    select coalesce(jsonb_agg(jsonb_build_object('client_id', bf.client_id, 'at', bf.occurred_at)), '[]'::jsonb)
      into v_events
      from public.benefit_fulfilments bf
     where bf.business_id = p_business
       and bf.fulfilment_kind = 'checkout_discount'
       and bf.canonical_benefit_key like 'tierdiscount:%'
       and bf.client_id is not null
       and (bf.occurred_at at time zone 'Asia/Singapore')::date between p_from and p_to;
    v_outcomes := app.ci_loyalty_outcomes_v683(p_business, v_events);
    v_tiers := jsonb_build_object(
      'status', 'ready',
      'programme_active', v_spine_tiers.active,
      'participation', app.rate_block_v1(v_enrolled, v_eligible),
      'redemptions', v_outcomes->'redemptions_total',
      'immature', v_outcomes->'immature',
      'paid_return_within_30d', v_outcomes->'paid_return_within_30d',
      'cannibalisation_proxy', v_outcomes->'cannibalisation_proxy',
      'incrementality', v_incrementality_unavailable);
  end if;

  -- ---------------------------------------------------------------------------------------
  -- referral
  -- ---------------------------------------------------------------------------------------
  select * into v_spine_referral from public.business_programmes
   where business_id = p_business and kind = 'referral';
  if not found then
    v_referral := jsonb_build_object('status', 'not_configured');
  else
    select count(distinct r.referrer_client_id) into v_enrolled
      from public.referrals r
      join public.clients c on c.id = r.referrer_client_id
      join app.ci_loyalty_eligible_v683(p_business, p_from, p_to) el on el.client_id = r.referrer_client_id
     where r.business_id = p_business and not coalesce(c.is_synthetic, false);
    select coalesce(jsonb_agg(jsonb_build_object('client_id', r.referrer_client_id, 'at', r.qualified_at)), '[]'::jsonb)
      into v_events
      from public.referrals r
     where r.business_id = p_business and r.status = 'rewarded' and r.qualified_at is not null
       and (r.qualified_at at time zone 'Asia/Singapore')::date between p_from and p_to;
    v_outcomes := app.ci_loyalty_outcomes_v683(p_business, v_events);
    v_referral := jsonb_build_object(
      'status', 'ready',
      'programme_active', v_spine_referral.active,
      'participation', app.rate_block_v1(v_enrolled, v_eligible),
      'redemptions', v_outcomes->'redemptions_total',
      'immature', v_outcomes->'immature',
      'paid_return_within_30d', v_outcomes->'paid_return_within_30d',
      'cannibalisation_proxy', v_outcomes->'cannibalisation_proxy',
      'incrementality', v_incrementality_unavailable);
  end if;

  -- ---------------------------------------------------------------------------------------
  -- welcome (not part of the v308 spine — configuration lives on its own table)
  -- ---------------------------------------------------------------------------------------
  if not exists (select 1 from public.business_welcome_offers_v215 where business_id = p_business) then
    v_welcome := jsonb_build_object('status', 'not_configured');
  else
    select count(distinct g.client_id) into v_enrolled
      from public.welcome_offer_grants_v215 g
      join public.clients c on c.id = g.client_id
      join app.ci_loyalty_eligible_v683(p_business, p_from, p_to) el on el.client_id = g.client_id
     where g.business_id = p_business and not coalesce(c.is_synthetic, false);
    select coalesce(jsonb_agg(jsonb_build_object('client_id', g.client_id, 'at', g.redeemed_at)), '[]'::jsonb)
      into v_events
      from public.welcome_offer_grants_v215 g
     where g.business_id = p_business and g.status = 'redeemed'
       and (g.redeemed_at at time zone 'Asia/Singapore')::date between p_from and p_to;
    v_outcomes := app.ci_loyalty_outcomes_v683(p_business, v_events);
    v_welcome := jsonb_build_object(
      'status', 'ready',
      'programme_active', (select active from public.business_welcome_offers_v215 where business_id = p_business),
      'participation', app.rate_block_v1(v_enrolled, v_eligible),
      'redemptions', v_outcomes->'redemptions_total',
      'immature', v_outcomes->'immature',
      'paid_return_within_30d', v_outcomes->'paid_return_within_30d',
      'cannibalisation_proxy', v_outcomes->'cannibalisation_proxy',
      'incrementality', v_incrementality_unavailable);
  end if;

  -- ---------------------------------------------------------------------------------------
  -- birthday
  -- ---------------------------------------------------------------------------------------
  if not exists (select 1 from public.birthday_program_versions where business_id = p_business) then
    v_birthday := jsonb_build_object('status', 'not_configured');
  else
    select count(distinct e.client_id) into v_enrolled
      from public.customer_birthday_entitlements e
      join public.clients c on c.id = e.client_id
      join app.ci_loyalty_eligible_v683(p_business, p_from, p_to) el on el.client_id = e.client_id
     where e.business_id = p_business and not coalesce(c.is_synthetic, false);
    select coalesce(jsonb_agg(jsonb_build_object('client_id', r.client_id, 'at', r.created_at)), '[]'::jsonb)
      into v_events
      from public.customer_birthday_redemptions r
     where r.business_id = p_business and r.operation_kind = 'redemption' and r.active
       and (r.created_at at time zone 'Asia/Singapore')::date between p_from and p_to;
    v_outcomes := app.ci_loyalty_outcomes_v683(p_business, v_events);
    v_birthday := jsonb_build_object(
      'status', 'ready',
      'programme_active', exists (select 1 from public.birthday_program_versions
                                    where business_id = p_business and active),
      'participation', app.rate_block_v1(v_enrolled, v_eligible),
      'redemptions', v_outcomes->'redemptions_total',
      'immature', v_outcomes->'immature',
      'paid_return_within_30d', v_outcomes->'paid_return_within_30d',
      'cannibalisation_proxy', v_outcomes->'cannibalisation_proxy',
      'incrementality', v_incrementality_unavailable);
  end if;

  -- ---------------------------------------------------------------------------------------
  -- bring-back — the only programme where a measured incrementality path (v108) may exist.
  -- ---------------------------------------------------------------------------------------
  if not exists (select 1 from public.bringback_campaigns_v361
                  where business_id = p_business and deleted_at is null) then
    v_bringback := jsonb_build_object('status', 'not_configured');
  else
    select count(distinct g.client_id) into v_enrolled
      from public.bringback_grants_v361 g
      join public.clients c on c.id = g.client_id
      join app.ci_loyalty_eligible_v683(p_business, p_from, p_to) el on el.client_id = g.client_id
     where g.business_id = p_business and not coalesce(c.is_synthetic, false);
    select coalesce(jsonb_agg(jsonb_build_object('client_id', g.client_id, 'at', g.redeemed_at)), '[]'::jsonb)
      into v_events
      from public.bringback_grants_v361 g
     where g.business_id = p_business and g.status = 'redeemed'
       and (g.redeemed_at at time zone 'Asia/Singapore')::date between p_from and p_to;
    v_outcomes := app.ci_loyalty_outcomes_v683(p_business, v_events);

    if to_regclass('public.growth_execution_results_v108') is not null then
      select coalesce(jsonb_agg(jsonb_build_object(
               'execution_id', ger.execution_id, 'result_status', ger.result_status,
               'result', ger.result, 'finalized_at', ger.finalized_at)), '[]'::jsonb)
        into v_bb_incrementality
        from public.growth_execution_results_v108 ger
        join public.growth_executions_v108 ge on ge.id = ger.execution_id
        join public.growth_recommendations_v108 gr on gr.id = ge.recommendation_id
       where ger.business_id = p_business
         and gr.recommendation_type = 'lapsed_high_value_bring_back';
      if jsonb_array_length(v_bb_incrementality) = 0 then
        v_bb_incrementality := jsonb_build_object('status', 'unavailable',
          'reason', 'no finalized v108 measured bring-back execution for this business yet');
      else
        v_bb_incrementality := jsonb_build_object('status', 'measured', 'source', 'v108',
          'executions', v_bb_incrementality);
      end if;
    else
      v_bb_incrementality := v_incrementality_unavailable;
    end if;

    v_bringback := jsonb_build_object(
      'status', 'ready',
      'programme_active', exists (select 1 from public.bringback_campaigns_v361
                                    where business_id = p_business and deleted_at is null and active),
      'participation', app.rate_block_v1(v_enrolled, v_eligible),
      'redemptions', v_outcomes->'redemptions_total',
      'immature', v_outcomes->'immature',
      'paid_return_within_30d', v_outcomes->'paid_return_within_30d',
      'cannibalisation_proxy', v_outcomes->'cannibalisation_proxy',
      'incrementality', v_bb_incrementality);
  end if;

  return jsonb_build_object(
    'scope', jsonb_build_object('business_id', p_business, 'from', p_from, 'to', p_to),
    'time_basis', 'redemption_event_at',
    'eligible_customers', v_eligible,
    'programmes', jsonb_build_object(
      'points', v_points, 'stamps', v_stamps, 'tiers', v_tiers, 'referral', v_referral,
      'welcome', v_welcome, 'birthday', v_birthday, 'bring_back', v_bringback));
end;
$$;
revoke all on function public.get_ci_loyalty_programmes_v1(uuid,date,date,uuid) from public, anon;
grant execute on function public.get_ci_loyalty_programmes_v1(uuid,date,date,uuid) to authenticated, service_role;

commit;

-- ============================================================================================
-- 5. DISCOUNT DEPENDENCY (checks 56-57)
-- ============================================================================================
-- A discount, whichever of v657's two shapes it takes (whole-bill or one-item) and whichever
-- engine applied it (a Studio promo rule via v58/v59/v67/v573, or the automatic tier discount
-- via v370), lands on the sale as exactly one thing: a public.sale_items row with
-- item_type='studio_discount' and a negative line_cents (v58's amount-sign check). That is the
-- one place this reader looks — it does not need to know which shape or which engine produced
-- it, because both write the same signal.
create or replace function public.get_ci_discount_dependency_v1(
  p_business uuid, p_from date, p_to date, p_branch uuid default null)
returns jsonb
language plpgsql stable security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_classes jsonb;
  v_full_price_repeat integer;
  v_reminder jsonb;
  v_reminder_count integer;
  v_candidates jsonb;
  v_floor constant integer := 5;
begin
  perform app.ci_access_gate_v667(p_business, p_branch);

  -- One WITH chain, not several: a CTE only lives for the single SQL statement that declares
  -- it, so `classified` (and the organic-cadence scoring built on it) has to be computed and
  -- consumed here in one query rather than re-declared per statement.
  with pop as (
    select s.id as sale_id, s.client_id, s.occurred_at,
           exists (select 1 from public.sale_items d
                     where d.sale_id = s.id and d.item_type = 'studio_discount' and d.line_cents < 0
                  ) as is_discounted
      from public.sales s
      join public.clients c on c.id = s.client_id
     where s.business_id = p_business
       and s.client_id is not null
       and (p_branch is null or s.branch_id = p_branch)
       and s.reversal_of is null
       and not exists (select 1 from public.sales r where r.reversal_of = s.id)
       and coalesce(s.counts_as_visit, false)
       and not coalesce(c.is_synthetic, false)
       and (s.occurred_at at time zone 'Asia/Singapore')::date between p_from and p_to
  ),
  per_client as (
    select client_id,
           count(*) filter (where not is_discounted) as full_price_visits,
           count(*) filter (where is_discounted) as discounted_visits,
           count(*) as all_visits
      from pop
     group by client_id
  ),
  classified as (
    select *,
           case
             when all_visits < 3 then 'insufficient'
             when (100.0 * discounted_visits / all_visits) < 20 then 'organic'
             when (100.0 * discounted_visits / all_visits) >= 60 then 'discount_dependent'
             else 'mixed'
           end as class
      from per_client
  ),
  organic_scored as (
    select oc.client_id, c.full_name,
           (app.customer_cadence_v1(p_business, oc.client_id, now())->>'deviation_state') as state
      from (select client_id from classified where class = 'organic') oc
      join public.clients c on c.id = oc.client_id
  ),
  reminder_agg as (
    select
      count(*) filter (where state = 'overdue') as n_overdue,
      coalesce(jsonb_agg(jsonb_build_object(
          'client_id', client_id, 'full_name', full_name,
          'action', jsonb_build_object('who', 'front desk', 'what', 'send a reminder, no incentive',
                                        'why', 'organic returner; discount unnecessary'))
               ) filter (where state = 'overdue'), '[]'::jsonb) as candidates
      from organic_scored
  )
  -- Each class's 'share' (this class's population share of every classified customer) is a
  -- rate-like verdict floor-gated on THAT CLASS'S OWN evidence — a class with n=1 (e.g. an
  -- 'insufficient' or thinly-populated 'mixed' cell) reports its share's pct as null, count
  -- (n) unaffected.
  select
      count(*) filter (where full_price_visits >= 2),
      jsonb_build_object(
        'organic', jsonb_build_object(
          'n', count(*) filter (where class = 'organic'),
          'evidence', app.subgroup_evidence_v1((count(*) filter (where class = 'organic'))::integer),
          'share', app.rate_block_floor_gated_v683(count(*) filter (where class = 'organic'), count(*),
                     app.subgroup_evidence_v1((count(*) filter (where class = 'organic'))::integer))),
        'discount_dependent', jsonb_build_object(
          'n', count(*) filter (where class = 'discount_dependent'),
          'evidence', app.subgroup_evidence_v1((count(*) filter (where class = 'discount_dependent'))::integer),
          'share', app.rate_block_floor_gated_v683(count(*) filter (where class = 'discount_dependent'), count(*),
                     app.subgroup_evidence_v1((count(*) filter (where class = 'discount_dependent'))::integer))),
        'mixed', jsonb_build_object(
          'n', count(*) filter (where class = 'mixed'),
          'evidence', app.subgroup_evidence_v1((count(*) filter (where class = 'mixed'))::integer),
          'share', app.rate_block_floor_gated_v683(count(*) filter (where class = 'mixed'), count(*),
                     app.subgroup_evidence_v1((count(*) filter (where class = 'mixed'))::integer))),
        'insufficient', jsonb_build_object(
          'n', count(*) filter (where class = 'insufficient'),
          'evidence', app.subgroup_evidence_v1((count(*) filter (where class = 'insufficient'))::integer),
          'share', app.rate_block_floor_gated_v683(count(*) filter (where class = 'insufficient'), count(*),
                     app.subgroup_evidence_v1((count(*) filter (where class = 'insufficient'))::integer)))),
      (select n_overdue from reminder_agg),
      (select candidates from reminder_agg)
    into v_full_price_repeat, v_classes, v_reminder_count, v_candidates
    from classified;

  -- reminder_only_candidates: organic returners who are overdue right now per their own cadence.
  -- Small-cell floor applies (identity-bearing list), same k=5 convention as v667.
  if v_reminder_count > 0 and v_reminder_count < v_floor then
    v_reminder := jsonb_build_object(
      'candidates', '[]'::jsonb,
      'suppressed', jsonb_build_object('reason', 'below_small_cell_floor', 'floor', v_floor,
                                        'cohort_size', v_reminder_count));
  else
    v_reminder := jsonb_build_object('candidates', v_candidates, 'suppressed', null);
  end if;

  return jsonb_build_object(
    'scope', jsonb_build_object('business_id', p_business, 'branch_id', p_branch,
                                'from', p_from, 'to', p_to),
    'time_basis', 'sale_occurred_at',
    'classes', v_classes,
    'full_price_repeat_customers', v_full_price_repeat,
    'reminder_only_candidates', v_reminder);
end;
$$;
revoke all on function public.get_ci_discount_dependency_v1(uuid,date,date,uuid) from public, anon;
grant execute on function public.get_ci_discount_dependency_v1(uuid,date,date,uuid) to authenticated, service_role;

commit;

-- ============================================================================================
-- 6. ATTRIBUTION TAXONOMY (check 58)
-- ============================================================================================
-- SCHEMA FOUND: public.campaign_send_records_v255 (v255) records that a send happened
-- (occurred_at, channel in 'in_app'/'web_push'/'none', inbox_event_id for in_app). There is no
-- pre-send queue/targeting table shared across all three campaign_kind values, no delivery
-- receipt table for either channel, and no two-way reply mechanism anywhere in this schema — so
-- 'contacted', 'queued', 'delivered' and 'replied' are honestly not_observed rather than
-- approximated from 'sent'. 'read' IS observable, but only for channel='in_app', via
-- public.customer_in_app_inbox_state.read_at (v46) keyed on inbox_event_id — scoped explicitly
-- to that channel rather than silently applied to the whole population. 'redeemed' has no common
-- key back to a send record across the three kind-specific redemption ledgers (Studio promo
-- redemption, retention reward_grants, growth entitlements) so it stays not_observed;
-- 'associated_purchase' is directly computable (a qualifying paid visit within 30 days of the
-- send, same population rules as everywhere else) and is reported. 'incremental' reuses the same
-- v108 measured-experiment link as the bring-back loyalty block, for campaign_kind='growth' sends.
create or replace function public.get_ci_marketing_funnel_v1(
  p_business uuid, p_from date, p_to date, p_branch uuid default null)
returns jsonb
language plpgsql stable security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_sent integer;
  v_sent_in_app integer;
  v_read_in_app integer;
  v_mature integer;
  v_returned integer;
  v_incremental jsonb;
  v_not_observed constant jsonb := jsonb_build_object('status', 'not_observed');
  v_today date := (now() at time zone 'Asia/Singapore')::date;
begin
  perform app.ci_access_gate_v667(p_business, p_branch);
  perform app.ci_no_branch_dimension_v667(p_branch, 'the marketing funnel');

  with sends as (
    select csr.id, csr.client_id, csr.channel, csr.inbox_event_id, csr.occurred_at,
           csr.campaign_kind
      from public.campaign_send_records_v255 csr
      join public.clients c on c.id = csr.client_id
     where csr.business_id = p_business
       and not coalesce(c.is_synthetic, false)
       and (csr.occurred_at at time zone 'Asia/Singapore')::date between p_from and p_to
  )
  select count(*), count(*) filter (where channel = 'in_app') into v_sent, v_sent_in_app from sends;

  select count(*) into v_read_in_app
    from (select distinct s.id from public.campaign_send_records_v255 s
           join public.clients c on c.id = s.client_id
           join public.customer_in_app_inbox_state st on st.event_id = s.inbox_event_id
          where s.business_id = p_business
            and not coalesce(c.is_synthetic, false)
            and s.channel = 'in_app'
            and st.read_at is not null
            and (s.occurred_at at time zone 'Asia/Singapore')::date between p_from and p_to) x;

  with sends as (
    select csr.id, csr.client_id, csr.occurred_at
      from public.campaign_send_records_v255 csr
      join public.clients c on c.id = csr.client_id
     where csr.business_id = p_business
       and not coalesce(c.is_synthetic, false)
       and (csr.occurred_at at time zone 'Asia/Singapore')::date between p_from and p_to
  ),
  scored as (
    select sn.*,
           ((sn.occurred_at at time zone 'Asia/Singapore')::date + 30) <= v_today as is_mature,
           exists (
             select 1 from public.sales s2
              where s2.business_id = p_business and s2.client_id = sn.client_id
                and coalesce(s2.counts_as_visit, false)
                and s2.reversal_of is null
                and not exists (select 1 from public.sales r2 where r2.reversal_of = s2.id)
                and s2.occurred_at > sn.occurred_at
                and s2.occurred_at <= sn.occurred_at + interval '30 days'
           ) as returned
      from sends sn
  )
  select count(*) filter (where is_mature), count(*) filter (where is_mature and returned)
    into v_mature, v_returned
    from scored;

  if to_regclass('public.growth_execution_results_v108') is not null then
    select case when count(*) = 0
             then jsonb_build_object('status', 'unavailable')
             else jsonb_build_object('status', 'measured', 'source', 'v108',
                    'executions_finalized', count(*))
           end
      into v_incremental
      from public.growth_execution_results_v108 ger
      join public.growth_executions_v108 ge on ge.id = ger.execution_id
     where ger.business_id = p_business;
  else
    v_incremental := jsonb_build_object('status', 'unavailable');
  end if;

  return jsonb_build_object(
    'scope', jsonb_build_object('business_id', p_business, 'from', p_from, 'to', p_to),
    'time_basis', 'send_occurred_at',
    'stages', jsonb_build_object(
      'contacted', v_not_observed,
      'queued', v_not_observed,
      'sent', jsonb_build_object('status', 'ok', 'count', v_sent),
      'delivered', v_not_observed,
      'read', jsonb_build_object('status', 'ok', 'scope', 'in_app channel only',
                'evidence', app.subgroup_evidence_v1(v_sent_in_app),
                'rate', app.rate_block_floor_gated_v683(v_read_in_app, v_sent_in_app,
                          app.subgroup_evidence_v1(v_sent_in_app))),
      'replied', v_not_observed,
      'redeemed', v_not_observed,
      'associated_purchase', jsonb_build_object('status', 'ok',
                'immature', v_sent - v_mature,
                'evidence', app.subgroup_evidence_v1(v_mature),
                'rate', app.rate_block_floor_gated_v683(v_returned, v_mature,
                          app.subgroup_evidence_v1(v_mature)))),
    'incremental', v_incremental);
end;
$$;
revoke all on function public.get_ci_marketing_funnel_v1(uuid,date,date,uuid) from public, anon;
grant execute on function public.get_ci_marketing_funnel_v1(uuid,date,date,uuid) to authenticated, service_role;

commit;
