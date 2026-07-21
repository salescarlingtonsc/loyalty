-- FRENLY v12 — COMMISSION is SNAPSHOTTED AT RECORD TIME, not resolved at read time.
-- Sections 1-6 of db/migrations/20260717_frenly_v12_commission_snapshot.sql
-- (own begin;/commit; stripped — apply_migration wraps its own transaction).
-- Applied AFTER frenly_v12a_completion_staff, which fixes Q9 (the blocker named in this
-- file's own header). Q9 fix verified 7/7 rolled-back before this apply.

-- 1. The snapshot. ---------------------------------------------------------------------
alter table public.sales
  add column if not exists commission_rate_bps    integer,
  add column if not exists commission_resolved_at timestamptz;

comment on column public.sales.commission_rate_bps is
  'IMMUTABLE SNAPSHOT of the commission rate in basis points as resolved when this sale was '
  'RECORDED, per v11a''s order (services.commission_bps -> staff.commission_service_bps -> 0 '
  'for kind=service; staff.commission_product_bps -> 0 otherwise), with the '
  'staff.commission_starts_on gate and the no-staff case already FOLDED IN (both yield 0). '
  'Payroll MUST read this column, never staff.commission_*_bps. 0 is a REAL RATE meaning '
  '"no commission", never "unset". There is deliberately NO supported path to change this '
  'after insert — see the header.';
comment on column public.sales.commission_resolved_at is
  'When the commission snapshot was taken (insert time). Backfilled rows carry created_at. '
  'Mirrors policy_resolved_at (v10.1).';

-- 1.1 THE RESOLVER — one definition, used by BOTH the backfill and the trigger. -----------
create or replace function app.commission_rate_bps(
  p_business    uuid,
  p_kind        text,
  p_staff       uuid,
  p_appointment uuid,
  p_occurred_at timestamptz)
returns integer language sql stable security definer set search_path = public as $$
  select case
           when st.id is null then 0
           when st.commission_starts_on is not null
                and (p_occurred_at at time zone 'Asia/Singapore')::date < st.commission_starts_on
                then 0
           else coalesce(
                  case when p_kind = 'service'
                       then coalesce(svc.commission_bps, st.commission_service_bps)
                       else st.commission_product_bps
                  end, 0)
         end
  from (select 1) _
  left join public.staff st       on st.id  = p_staff and st.business_id = p_business
  left join public.appointments a on a.id   = p_appointment
  left join public.services svc   on svc.id = a.service_id
$$;

-- 2. BACKFILL through v10.1's audited window. --------------------------------------------
select app.begin_sales_backfill(
  'frenly_v12_commission_snapshot',
  'populate the new sales.commission_rate_bps / commission_resolved_at snapshot on pre-v12 historical rows');

update public.sales s set
  commission_rate_bps    = app.commission_rate_bps(s.business_id, s.kind, s.staff_id,
                                                   s.appointment_id, s.occurred_at),
  commission_resolved_at = s.created_at
where s.commission_rate_bps is null;

select app.end_sales_backfill();

alter table public.sales
  alter column commission_rate_bps    set not null,
  alter column commission_resolved_at set not null;

-- 3. Indexes. ---------------------------------------------------------------------------
create index if not exists sales_commission_payroll_idx
  on public.sales (business_id, staff_id, occurred_at)
  where staff_id is not null and commission_rate_bps > 0;

-- 4. THE SNAPSHOT TRIGGER — resolve once, at record time. -------------------------------
create or replace function app.on_sale_commission_snapshot()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  new.commission_rate_bps := app.commission_rate_bps(
    new.business_id, new.kind, new.staff_id, new.appointment_id, new.occurred_at);
  new.commission_resolved_at := now();
  return new;
end $$;

drop trigger if exists trg_sale_commission_snapshot on public.sales;
create trigger trg_sale_commission_snapshot
  before insert on public.sales
  for each row execute function app.on_sale_commission_snapshot();

-- 5. EXTEND v10.1'S IMMUTABILITY GUARD to freeze the new columns. ------------------------
create or replace function app.sales_immutable_guard()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_reclassify text; v_backfill text;
begin
  if tg_op = 'DELETE' then
    raise exception 'sales is append-only: DELETE is not permitted (sale %). There is no '
                    'reversal path in this schema yet — refunds/reversals are deferred to '
                    'v11b.', old.id
      using errcode = 'restrict_violation';
  end if;

  v_reclassify := nullif(current_setting('app.reclassify_sale', true), '');
  v_backfill   := nullif(current_setting('app.sales_backfill',  true), '');

  if v_reclassify is not null and v_reclassify = old.id::text then
    if (new.id, new.business_id, new.client_id, new.kind, new.amount_cents, new.occurred_at,
        new.created_at, new.note, new.appointment_id, new.product_id, new.qty,
        new.counts_as_visit, new.earns_points, new.policy_resolved_at,
        new.commission_rate_bps, new.commission_resolved_at)
       is distinct from
       (old.id, old.business_id, old.client_id, old.kind, old.amount_cents, old.occurred_at,
        old.created_at, old.note, old.appointment_id, old.product_id, old.qty,
        old.counts_as_visit, old.earns_points, old.policy_resolved_at,
        old.commission_rate_bps, old.commission_resolved_at)
    then
      raise exception 'reclassification of sale % may change counts_as_revenue and nothing '
                      'else', old.id
        using errcode = 'restrict_violation';
    end if;
    return new;
  end if;

  if v_backfill is not null then
    if (new.id, new.business_id, new.client_id, new.kind, new.amount_cents, new.occurred_at,
        new.created_at, new.note, new.appointment_id, new.product_id, new.qty,
        new.counts_as_revenue, new.counts_as_visit, new.earns_points, new.policy_resolved_at,
        new.commission_rate_bps, new.commission_resolved_at)
       is distinct from
       (old.id, old.business_id, old.client_id, old.kind, old.amount_cents, old.occurred_at,
        old.created_at, old.note, old.appointment_id, old.product_id, old.qty,
        old.counts_as_revenue, old.counts_as_visit, old.earns_points, old.policy_resolved_at,
        old.commission_rate_bps, old.commission_resolved_at)
    then
      raise exception 'backfill window "%" may only populate columns added after v12; it '
                      'may not change any economic fact, the policy snapshot, or the '
                      'commission snapshot of sale %',
                      v_backfill, old.id
        using errcode = 'restrict_violation';
    end if;
    return new;
  end if;

  raise exception 'sales is append-only: UPDATE is not permitted (sale %). Use '
                  'public.reclassify_sale_policy() for an audited revenue restatement, or '
                  'app.begin_sales_backfill() from a migration to populate a new column.',
                  old.id
    using errcode = 'restrict_violation';
end $$;

-- 6. THE VIEW now READS THE SNAPSHOT. ---------------------------------------------------
create or replace view public.sale_commission
with (security_invoker = on) as
select s.id                  as sale_id,
       s.business_id,
       s.branch_id,
       s.staff_id,
       s.kind,
       s.occurred_at,
       s.amount_cents,
       s.commission_rate_bps as rate_bps,
       floor((s.amount_cents * s.commission_rate_bps)::numeric / 10000.0)::integer
                             as commission_cents
from public.sales s
where app.has_perm(s.business_id, 'view_finance');