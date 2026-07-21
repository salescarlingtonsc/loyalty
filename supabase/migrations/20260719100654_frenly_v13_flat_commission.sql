alter table public.services
  add column if not exists commission_flat_cents integer
    check (commission_flat_cents is null or commission_flat_cents >= 0);
comment on column public.services.commission_flat_cents is
  'CONFIG: flat commission in cents paid when THIS service is performed, overriding the percentage when set. NULL = no flat, use the percentage path. 0 = a REAL flat-zero that beats any percentage (no nullif). Set by the business; the platform provides the field, never the number.';

alter table public.sales
  add column if not exists commission_flat_cents integer
    check (commission_flat_cents is null or commission_flat_cents >= 0);
comment on column public.sales.commission_flat_cents is
  'IMMUTABLE SNAPSHOT of the resolved FLAT commission in cents at record time, or NULL if not flat-commission (then commission_rate_bps applies). When NOT NULL this WINS over the rate (0 is a real flat-zero). A reversal sale copies the original sale snapshot. Payroll reads public.sale_commission.commission_cents.';

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

drop index if exists public.sales_commission_payroll_idx;
create index if not exists sales_commission_payroll_idx
  on public.sales (business_id, staff_id, occurred_at)
  where staff_id is not null
    and (commission_rate_bps > 0 or commission_flat_cents > 0);

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