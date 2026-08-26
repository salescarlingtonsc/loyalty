-- ============================================================================
-- nestly_v550 — the recovered-revenue report: "Peekaa brought back N customers
-- and recovered $X", computed conservatively enough to be clicked into.
--
-- WHY. The 2026-08-26 strategy ruling: the moat metric is attributed recovery,
-- and in a market of inflated claims ("26% ATV increase", "recovers 8–14%") the
-- differentiator is a CONSERVATIVE number the owner can audit. This migration
-- adds the second build of that plan (the attention list was v548):
--   (1) public.attention_outreach_v550 — the record that a staff member actually
--       reached out to a lapsed customer from the attention list (the wa.me tap
--       was invisible to attribution until now);
--   (2) record_attention_outreach_v550 — the only writer, deduped per SG day;
--   (3) get_recovery_report_v550 — the report.
--
-- ATTRIBUTION CONTRACT (every judgement in SQL, nothing invented in the UI):
--   * INTERVENTION = the FIRST of, per client, inside the report window:
--       - a bring-back voucher grant (bringback_grants_v361.granted_at), or
--       - a recorded attention outreach (attention_outreach_v550.occurred_at).
--     One intervention per client per report window — repeat contact does not
--     multiply credit.
--   * LAPSED GUARD: at the intervention moment the client must have >= 1 prior
--     valid visit AND >= 14 whole days since the last one. An intervention on a
--     customer who was coming anyway is EXCLUDED (reported as excluded, never
--     silently absorbed into the win count).
--   * RETURN = at least one valid visit (counts_as_visit, reversal-discounted,
--     positive v106 residual — v108/v548 semantics) within 30 days after the
--     intervention. GROSS RECOVERED = the residual value of the client's valid
--     sales inside that 30-day window, and only that window.
--   * BASELINE = clients of the same business who were similarly lapsed at the
--     window start (>= 1 prior visit, >= 14 days absent) and received NO
--     intervention in the window: the share of them who nevertheless returned
--     within 30 days of the window start. This is what "would have happened
--     anyway".
--   * NET = gross * max(0, 1 - baseline_rate / treated_rate); zero when the
--     treated return rate does not beat the baseline. Reported beside gross,
--     never instead of it, with both cohort sizes visible.
--   * low_confidence = fewer than 10 interventions or fewer than 10 baseline
--     clients — the report says so instead of pretending significance.
--   * The report is business-wide (a voucher grant has no branch), and every
--     count excludes synthetic clients.
--
-- AUTHORIZATION. The report joins customer identities to money, so it demands
-- the same trio the Customer Retention report demands: reports + clients +
-- sales scope (require_module_scope_v145 each; raises 42501/22023 unchanged).
-- The outreach writer demands clients scope. EXECUTE: authenticated only.
--
-- IDEMPOTENT: create-if-not-exists + create-or-replace + idempotent grants.
-- ============================================================================

begin;

create table if not exists public.attention_outreach_v550(
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  client_id uuid not null references public.clients(id) on delete cascade,
  channel text not null default 'whatsapp_manual'
    check (channel in ('whatsapp_manual')),
  source text not null default 'attention_list'
    check (source in ('attention_list')),
  occurred_at timestamptz not null default now(),
  -- The SG calendar day, stored so the once-per-day dedupe can be a plain
  -- unique index (an expression index over a timezone cast is not IMMUTABLE).
  occurred_on date not null default ((now() at time zone 'Asia/Singapore')::date),
  actor uuid,
  constraint attention_outreach_v550_day_uk unique (business_id, client_id, occurred_on)
);
create index if not exists attention_outreach_v550_business_time_idx
  on public.attention_outreach_v550(business_id, occurred_at desc);

-- Outreach happened or it did not: the row is evidence, not state.
create or replace function app.v550_attention_outreach_immutable()
returns trigger language plpgsql as $$
begin
  raise exception 'attention_outreach_v550 rows are immutable evidence'
    using errcode = '42501';
end;
$$;
drop trigger if exists attention_outreach_v550_immutable on public.attention_outreach_v550;
create trigger attention_outreach_v550_immutable
  before update or delete on public.attention_outreach_v550
  for each row execute function app.v550_attention_outreach_immutable();

revoke all on public.attention_outreach_v550 from public, anon, authenticated;
grant select on public.attention_outreach_v550 to authenticated;
alter table public.attention_outreach_v550 enable row level security;
drop policy if exists attention_outreach_v550_read on public.attention_outreach_v550;
create policy attention_outreach_v550_read on public.attention_outreach_v550 for select using (
  app.is_super_admin() or app.can_module_read(business_id, 'clients'));

create or replace function public.record_attention_outreach_v550(
  p_business uuid,
  p_client uuid
)
returns jsonb
language plpgsql
volatile
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
begin
  perform public.require_module_scope_v145(p_business, null, 'clients');
  if not exists (
    select 1 from public.clients c
    where c.id = p_client and c.business_id = p_business
  ) then
    raise exception 'client does not belong to this business'
      using errcode = '22023';
  end if;
  insert into public.attention_outreach_v550(business_id, client_id, actor)
  values (p_business, p_client, auth.uid())
  on conflict (business_id, client_id, occurred_on) do nothing;
  -- Uniform shape whether this tap was the first today or a repeat: the caller
  -- fires and forgets, and a repeat tap is not an error the staff member can act on.
  return jsonb_build_object('status', 'ok');
end;
$$;

comment on function public.record_attention_outreach_v550(uuid, uuid) is
  'Records that staff reached out to a customer from the dashboard attention '
  'list (wa.me tap). One row per business/client/SG-day; repeat taps collapse. '
  'Gated on clients scope; rows are immutable evidence feeding '
  'get_recovery_report_v550.';

revoke all on function public.record_attention_outreach_v550(uuid, uuid) from public, anon;
grant execute on function public.record_attention_outreach_v550(uuid, uuid) to authenticated;
grant execute on function public.record_attention_outreach_v550(uuid, uuid) to service_role;

-- p_to is EXCLUSIVE, matching the report page's existing to+1 convention.
create or replace function public.get_recovery_report_v550(
  p_business uuid,
  p_from date,
  p_to date
)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare
  v_now timestamptz := now();
  v_attr constant integer := 30;   -- attribution window, days
  v_lapse constant integer := 14;  -- minimum absence for an intervention to count
  v_from_ts timestamptz;
  v_to_ts timestamptz;
  v_result jsonb;
begin
  perform public.require_module_scope_v145(p_business, null, 'reports');
  perform public.require_module_scope_v145(p_business, null, 'clients');
  perform public.require_module_scope_v145(p_business, null, 'sales');
  if p_from is null or p_to is null or p_to <= p_from then
    raise exception 'invalid report window' using errcode = '22023';
  end if;
  v_from_ts := p_from::timestamp at time zone 'Asia/Singapore';
  v_to_ts := p_to::timestamp at time zone 'Asia/Singapore';

  with visits as (
    select s.client_id, s.occurred_at,
      app.v106_sale_residual_minor(s.id, v_now) as amount_cents
    from public.sales s
    where s.business_id = p_business
      and s.client_id is not null
      and s.counts_as_visit
      and s.reversal_of is null
      and s.occurred_at < v_now
      and app.v106_sale_residual_minor(s.id, v_now) > 0
      and not exists (
        select 1 from public.sales r
        where r.business_id = s.business_id and r.reversal_of = s.id
      )
  ),
  real_clients as (
    select c.id from public.clients c
    where c.business_id = p_business and coalesce(c.is_synthetic, false) = false
  ),
  interventions_raw as (
    select g.client_id, g.granted_at as at, 'voucher'::text as kind
    from public.bringback_grants_v361 g
    where g.business_id = p_business
      and g.granted_at >= v_from_ts and g.granted_at < v_to_ts
    union all
    select o.client_id, o.occurred_at, 'message'::text
    from public.attention_outreach_v550 o
    where o.business_id = p_business
      and o.occurred_at >= v_from_ts and o.occurred_at < v_to_ts
  ),
  -- One intervention per client per window: the first. Repeat contact never
  -- multiplies credit.
  interventions as (
    select distinct on (i.client_id) i.client_id, i.at, i.kind
    from interventions_raw i
    join real_clients rc on rc.id = i.client_id
    order by i.client_id, i.at, i.kind
  ),
  judged as (
    select i.client_id, i.at, i.kind,
      (select max(v.occurred_at) from visits v
        where v.client_id = i.client_id and v.occurred_at < i.at) as last_visit_before,
      (select count(*) from visits v
        where v.client_id = i.client_id and v.occurred_at < i.at) as prior_visits
    from interventions i
  ),
  eligible as (
    select j.*,
      exists (
        select 1 from visits v
        where v.client_id = j.client_id
          and v.occurred_at > j.at
          and v.occurred_at <= j.at + make_interval(days => v_attr)
      ) as returned,
      coalesce((
        select sum(v.amount_cents) from visits v
        where v.client_id = j.client_id
          and v.occurred_at > j.at
          and v.occurred_at <= j.at + make_interval(days => v_attr)
      ), 0)::bigint as window_cents
    from judged j
    where j.prior_visits >= 1
      and j.last_visit_before is not null
      and j.last_visit_before <= j.at - make_interval(days => v_lapse)
  ),
  excluded as (
    select count(*)::integer as n from judged j
    where not (j.prior_visits >= 1
      and j.last_visit_before is not null
      and j.last_visit_before <= j.at - make_interval(days => v_lapse))
  ),
  -- What would have happened anyway: clients lapsed at the window start with no
  -- intervention in the window, measured over the same 30-day horizon.
  baseline_cohort as (
    select v.client_id,
      max(v.occurred_at) filter (where v.occurred_at < v_from_ts) as last_before
    from visits v
    join real_clients rc on rc.id = v.client_id
    where not exists (select 1 from interventions i where i.client_id = v.client_id)
    group by v.client_id
    having max(v.occurred_at) filter (where v.occurred_at < v_from_ts)
             <= v_from_ts - make_interval(days => v_lapse)
  ),
  baseline as (
    select count(*)::integer as cohort,
      count(*) filter (where exists (
        select 1 from visits v2
        where v2.client_id = b.client_id
          and v2.occurred_at >= v_from_ts
          and v2.occurred_at < v_from_ts + make_interval(days => v_attr)
      ))::integer as returned
    from baseline_cohort b
  ),
  redeemed as (
    select count(*)::integer as n,
      coalesce(sum(app.v106_sale_residual_minor(g.redeemed_sale_id, v_now)), 0)::bigint as cents
    from public.bringback_grants_v361 g
    join real_clients rc on rc.id = g.client_id
    where g.business_id = p_business and g.status = 'redeemed'
      and g.granted_at >= v_from_ts and g.granted_at < v_to_ts
  ),
  monthly as (
    select to_char(e.at at time zone 'Asia/Singapore', 'YYYY-MM') as month,
      count(*)::integer as interventions,
      count(*) filter (where e.returned)::integer as returned,
      coalesce(sum(e.window_cents) filter (where e.returned), 0)::bigint as gross_cents
    from eligible e
    group by 1
  ),
  totals as (
    select
      (select count(*) from eligible)::integer as treated,
      (select count(*) filter (where kind = 'voucher') from eligible)::integer as vouchers,
      (select count(*) filter (where kind = 'message') from eligible)::integer as messages,
      (select count(*) filter (where returned) from eligible)::integer as returned,
      (select coalesce(sum(window_cents) filter (where returned), 0) from eligible)::bigint as gross_cents
  )
  select jsonb_build_object(
    'window', jsonb_build_object(
      'from', p_from, 'to_exclusive', p_to,
      'attribution_days', v_attr, 'min_absence_days', v_lapse),
    'interventions', jsonb_build_object(
      'treated', t.treated, 'vouchers', t.vouchers, 'messages', t.messages,
      'excluded_not_lapsed', (select n from excluded)),
    'returned', jsonb_build_object(
      'count', t.returned,
      'rate_pct', case when t.treated > 0
        then round(t.returned * 100.0 / t.treated, 1) else null end),
    'recovered', jsonb_build_object(
      'gross_cents', t.gross_cents,
      'redeemed_vouchers', (select n from redeemed),
      'redeemed_voucher_cents', (select cents from redeemed)),
    'baseline', jsonb_build_object(
      'cohort', b.cohort, 'returned', b.returned,
      'rate_pct', case when b.cohort > 0
        then round(b.returned * 100.0 / b.cohort, 1) else null end),
    'net', jsonb_build_object(
      'cents', case
        when t.treated = 0 or t.returned = 0 then 0
        when b.cohort = 0 then t.gross_cents
        else greatest(0, round(t.gross_cents
          * (1 - (b.returned::numeric / b.cohort)
               / (t.returned::numeric / t.treated))))::bigint end,
      'method', 'gross scaled by (1 - baseline_rate / treated_rate), floored at zero'),
    'low_confidence', (t.treated < 10 or b.cohort < 10),
    'monthly', (select coalesce(jsonb_agg(jsonb_build_object(
        'month', m.month, 'interventions', m.interventions,
        'returned', m.returned, 'gross_cents', m.gross_cents)
      order by m.month), '[]'::jsonb) from monthly m)
  )
  into v_result
  from totals t, baseline b;

  return v_result;
end;
$$;

comment on function public.get_recovery_report_v550(uuid, date, date) is
  'The recovered-revenue report: interventions (bring-back voucher grants + '
  'recorded attention outreach, first per client per window, lapsed-guarded at '
  '>=14 days absent), returns within a 30-day attribution window, gross '
  'recovered residual value, a no-intervention lapsed baseline, and a net '
  'figure scaled down by the baseline return rate and floored at zero. '
  'Business-wide; synthetic clients excluded everywhere; low_confidence is '
  'raised below 10 treated or 10 baseline clients. Gated on reports + clients '
  '+ sales scope. p_to is exclusive.';

revoke all on function public.get_recovery_report_v550(uuid, date, date) from public, anon;
grant execute on function public.get_recovery_report_v550(uuid, date, date) to authenticated;
grant execute on function public.get_recovery_report_v550(uuid, date, date) to service_role;

commit;

-- ============================================================================
-- VERIFICATION (performed rolled-back against production before apply):
--   db/tests/v550_recovery_report.sql — fixture clients with crafted histories
--   in qa-kaya-toast inside BEGIN/ROLLBACK: outreach dedupe + immutability +
--   membership guard, the lapsed guard excluding a non-lapsed intervention,
--   voucher+message union with first-per-client dedupe, 30-day return window
--   and gross arithmetic, baseline cohort membership, net floor behaviour,
--   monthly bucketing, and the 42501 outsider / anon EXECUTE checks.
-- ============================================================================
