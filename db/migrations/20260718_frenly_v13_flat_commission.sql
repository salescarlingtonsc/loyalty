-- FRENLY v13 — FLAT-AMOUNT-PER-SERVICE COMMISSION (rebased onto the post-v20 engine).
-- Applied to production gadpooereceldfpfxsod as migration `frenly_v13_flat_commission`.
--
-- ORDER NOTE: v13 occupies the schema's logical commission slot (it extends v12's snapshot),
-- but because v14 (idem_key) and v20 (reversal_of + full-reversal engine + branch visibility)
-- were already live when this landed, its `create or replace` bodies for sales_immutable_guard /
-- on_sale_commission_snapshot / sale_commission are written as a MINIMAL MERGE onto those live
-- objects — preserving reversal handling and branch visibility while adding commission_flat_cents.
-- An earlier draft that predated v20 would have REGRESSED the immutability guard (dropping the
-- reversal_* / idem_key / attribution columns from its frozen tuples); this is the corrected
-- version. Full original design rationale (Q1..Q14) is preserved in git history.
--
-- DESIGN SUMMARY:
--   * services.commission_flat_cents = CONFIG lever (NULL = no flat / use %, 0 = real flat-zero).
--   * sales.commission_flat_cents    = IMMUTABLE per-sale snapshot (NULL = not flat, consult rate).
--   * FLAT WINS over % when the snapshot IS NOT NULL (0 included) — never nullif, never `> 0`.
--   * No-staff / commission_starts_on gate / $0-sale all fold to NULL (Q13 defers $0 to no-pay).
--   * A REVERSAL sale copies the original's flat snapshot (like it copies the rate) and the view
--     negates it in full — consistent with v20's full-reversal-only model (partial refunds are
--     rejected upstream), so a reversed flat commission claws back exactly what was earned.
--   * "The platform provides the MECHANISM, never the numbers" — every field NULL until a firm
--     sets it; a firm with no config pays no commission. Firms may use %, flat, none, or a mix
--     per service, all at once.
-- Verified against production: structural (guard/trigger/view merged, reversal + branch vis
-- preserved), behavioral (flat holds across prices, %=derived, flat-zero beats %, reverse_sale
-- full clawback nets -flat), all in rolled-back transactions leaving no data.

begin;

-- 1. CONFIG lever (per-service flat, in cents). NULL = use %, 0 = real flat-zero that beats %.
alter table public.services
  add column if not exists commission_flat_cents integer
    check (commission_flat_cents is null or commission_flat_cents >= 0);
comment on column public.services.commission_flat_cents is
  'CONFIG: flat commission in cents paid when THIS service is performed, overriding the percentage '
  '(services.commission_bps / staff.commission_service_bps) when set. NULL = no flat, use the '
  'percentage path. 0 = a REAL flat-zero that beats any percentage (never read as "unset"; no nullif). '
  'Set by the business; the platform provides the field, never the number.';

-- 2. IMMUTABLE per-sale snapshot of the resolved flat amount (or NULL for a non-flat sale).
alter table public.sales
  add column if not exists commission_flat_cents integer
    check (commission_flat_cents is null or commission_flat_cents >= 0);
comment on column public.sales.commission_flat_cents is
  'IMMUTABLE SNAPSHOT of the resolved FLAT commission in cents as of record time, or NULL if this '
  'sale is not flat-commission (then commission_rate_bps applies). When NOT NULL this value IS the '
  'commission and WINS over commission_rate_bps (0 is a real flat-zero). A reversal sale copies the '
  'original sale''s snapshot. Payroll reads public.sale_commission.commission_cents, never this raw.';

-- 2.1 FLAT RESOLVER — mirrors app.commission_rate_bps''s join shape and no-staff/gate guards so the
--     two never disagree about WHETHER commission applies. No nullif (a flat 0 stays 0); no coalesce
--     (exactly one flat level). $0-amount sales fold to NULL (Q13; delete that line to enable).
create or replace function app.commission_flat_cents(
  p_business     uuid,
  p_kind         text,
  p_staff        uuid,
  p_appointment  uuid,
  p_occurred_at  timestamptz,
  p_amount_cents integer)
returns integer language sql stable security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp' as $$
  select case
           when st.id is null then null
           when st.commission_starts_on is not null
                and (p_occurred_at at time zone 'Asia/Singapore')::date < st.commission_starts_on
                then null
           when coalesce(p_amount_cents, 0) <= 0 then null
           when p_kind = 'service' then svc.commission_flat_cents
           else null
         end
  from (select 1) _
  left join public.staff st       on st.id  = p_staff and st.business_id = p_business
  left join public.appointments a on a.id   = p_appointment
  left join public.services svc   on svc.id = a.service_id
$$;

-- 3. PAYROLL INDEX — extend v12''s partial index to also catch pure-flat rows (% resolves to 0).
drop index if exists public.sales_commission_payroll_idx;
create index if not exists sales_commission_payroll_idx
  on public.sales (business_id, staff_id, occurred_at)
  where staff_id is not null
    and (commission_rate_bps > 0 or commission_flat_cents > 0);

-- 4. SNAPSHOT TRIGGER — REBASED onto v20''s body: keep the reversal branch (copy the original''s
--    snapshot), and resolve BOTH rate and flat for a normal sale.
create or replace function app.on_sale_commission_snapshot()
returns trigger language plpgsql security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp' as $$
declare
  o public.sales%rowtype;
begin
  if new.reversal_of is not null then
    select * into o
      from public.sales
     where id = new.reversal_of
       and business_id = new.business_id;
    if not found then
      raise exception 'original sale not found for commission reversal %', new.reversal_of;
    end if;
    new.commission_rate_bps := o.commission_rate_bps;
    new.commission_flat_cents := o.commission_flat_cents;
    new.commission_resolved_at := o.commission_resolved_at;
    return new;
  end if;

  new.commission_rate_bps := app.commission_rate_bps(
    new.business_id, new.kind, new.staff_id, new.appointment_id, new.occurred_at);
  new.commission_flat_cents := app.commission_flat_cents(
    new.business_id, new.kind, new.staff_id, new.appointment_id, new.occurred_at, new.amount_cents);
  new.commission_resolved_at := now();
  return new;
end $$;

-- 5. IMMUTABILITY GUARD — REBASED onto v20''s body: freeze commission_flat_cents in BOTH windows,
--    preserving every v14/v20 column (idem_key, branch/staff attribution, reversal_* metadata).
create or replace function app.sales_immutable_guard()
returns trigger language plpgsql security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp' as $$
declare
  v_reclassify text;
  v_backfill text;
begin
  if tg_op = 'DELETE' then
    raise exception 'sales is append-only: DELETE is not permitted (sale %). Use append-only reversal rows.',
      old.id
      using errcode = 'restrict_violation';
  end if;

  v_reclassify := nullif(current_setting('app.reclassify_sale', true), '');
  v_backfill := nullif(current_setting('app.sales_backfill', true), '');

  if v_reclassify is not null and v_reclassify = old.id::text then
    if (new.id, new.business_id, new.client_id, new.kind, new.amount_cents, new.occurred_at,
        new.created_at, new.note, new.appointment_id, new.product_id, new.qty,
        new.counts_as_visit, new.earns_points, new.policy_resolved_at,
        new.commission_rate_bps, new.commission_resolved_at,
        new.idem_key,
        new.branch_id, new.staff_id, new.reversal_of, new.reversal_reason,
        new.reversal_actor, new.reversal_idempotency_key, new.commission_flat_cents)
       is distinct from
       (old.id, old.business_id, old.client_id, old.kind, old.amount_cents, old.occurred_at,
        old.created_at, old.note, old.appointment_id, old.product_id, old.qty,
        old.counts_as_visit, old.earns_points, old.policy_resolved_at,
        old.commission_rate_bps, old.commission_resolved_at,
        old.idem_key,
        old.branch_id, old.staff_id, old.reversal_of, old.reversal_reason,
        old.reversal_actor, old.reversal_idempotency_key, old.commission_flat_cents)
    then
      raise exception 'reclassification of sale % may change counts_as_revenue and nothing else',
        old.id
        using errcode = 'restrict_violation';
    end if;
    return new;
  end if;

  if v_backfill is not null then
    if (new.id, new.business_id, new.client_id, new.kind, new.amount_cents, new.occurred_at,
        new.created_at, new.note, new.appointment_id, new.product_id, new.qty,
        new.counts_as_revenue, new.counts_as_visit, new.earns_points, new.policy_resolved_at,
        new.commission_rate_bps, new.commission_resolved_at,
        new.idem_key,
        new.branch_id, new.staff_id, new.reversal_of, new.reversal_reason,
        new.reversal_actor, new.reversal_idempotency_key, new.commission_flat_cents)
       is distinct from
       (old.id, old.business_id, old.client_id, old.kind, old.amount_cents, old.occurred_at,
        old.created_at, old.note, old.appointment_id, old.product_id, old.qty,
        old.counts_as_revenue, old.counts_as_visit, old.earns_points, old.policy_resolved_at,
        old.commission_rate_bps, old.commission_resolved_at,
        old.idem_key,
        old.branch_id, old.staff_id, old.reversal_of, old.reversal_reason,
        old.reversal_actor, old.reversal_idempotency_key, old.commission_flat_cents)
    then
      raise exception 'backfill window "%" may not change economic facts, attribution, snapshots, or reversal metadata of sale %',
        v_backfill, old.id
        using errcode = 'restrict_violation';
    end if;
    return new;
  end if;

  raise exception 'sales is append-only: UPDATE is not permitted (sale %)', old.id
    using errcode = 'restrict_violation';
end $$;

-- 6. VIEW — REBASED onto v20''s body: flat wins when the snapshot IS NOT NULL (negated in full for a
--    reversal row), else v20''s reversal-aware percentage arithmetic. Preserves branch visibility.
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
       case
         when s.commission_flat_cents is not null then
           case when s.reversal_of is not null and s.amount_cents < 0
                then - s.commission_flat_cents
                else s.commission_flat_cents end
         when s.reversal_of is not null and s.amount_cents < 0
           then - floor(((- s.amount_cents)::numeric * s.commission_rate_bps::numeric) / 10000.0)::integer
         else floor((s.amount_cents::numeric * s.commission_rate_bps::numeric) / 10000.0)::integer
       end                   as commission_cents,
       s.commission_flat_cents as flat_cents
from public.sales s
where app.has_perm(s.business_id, 'view_finance') and app.can_see_branch(s.business_id, s.branch_id);

commit;
