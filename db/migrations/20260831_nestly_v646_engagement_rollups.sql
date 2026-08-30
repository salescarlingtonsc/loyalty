-- NESTLY v646 — Phase B, B3 (owner ruling D10): aggregate-before-purge.
-- Long-horizon Customer Intelligence trends collide with the 400-day purge on the raw
-- behavioural tables. What survives is IDENTITY-FREE by construction: month × business ×
-- event/channel counts, with distinct-actor counts stored as bare integers computed at
-- rollup time — no actor list, hash, or anything re-identifiable. Retention: indefinite,
-- because the D10 test (no personal data) is met structurally, not by policy.
-- Per-customer longitudinal behaviour deliberately CANNOT be reconstructed from these
-- tables; anything needing it computes inside the raw 400-day window and says so.
begin;

create table public.engagement_monthly_rollup_v1 (
  business_id uuid not null references public.businesses(id) on delete cascade,
  month date not null check (date_trunc('month', month)::date = month),
  event_name text not null,
  actor_scope text not null check (actor_scope in ('customer','merchant','system')),
  event_count bigint not null check (event_count >= 0),
  distinct_actor_count integer not null check (distinct_actor_count >= 0),
  created_at timestamptz not null default now(),
  primary key (business_id, month, event_name, actor_scope)
);
create table public.account_open_monthly_rollup_v1 (
  business_id uuid not null references public.businesses(id) on delete cascade,
  month date not null check (date_trunc('month', month)::date = month),
  channel text not null,
  open_days bigint not null check (open_days >= 0),
  distinct_subject_count integer not null check (distinct_subject_count >= 0),
  created_at timestamptz not null default now(),
  primary key (business_id, month, channel)
);
alter table public.engagement_monthly_rollup_v1 enable row level security;
alter table public.account_open_monthly_rollup_v1 enable row level security;
create policy engagement_rollup_member_read on public.engagement_monthly_rollup_v1
  for select to authenticated using (app.is_salon_member(business_id) or app.is_super_admin());
create policy account_open_rollup_member_read on public.account_open_monthly_rollup_v1
  for select to authenticated using (app.is_salon_member(business_id) or app.is_super_admin());
revoke all on public.engagement_monthly_rollup_v1 from public, anon, authenticated;
revoke all on public.account_open_monthly_rollup_v1 from public, anon, authenticated;
grant select on public.engagement_monthly_rollup_v1 to authenticated;
grant select on public.account_open_monthly_rollup_v1 to authenticated;

create or replace function app.rollup_guard_v646()
returns trigger language plpgsql
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
begin
  raise exception 'monthly rollups are append-only' using errcode = '42501';
end;
$$;
create trigger trg_engagement_rollup_append_only
  before update or delete on public.engagement_monthly_rollup_v1
  for each row execute function app.rollup_guard_v646();
create trigger trg_account_open_rollup_append_only
  before update or delete on public.account_open_monthly_rollup_v1
  for each row execute function app.rollup_guard_v646();

-- Roll up one CLOSED month. Idempotent: existing keys are skipped, never rewritten
-- (a re-run after new late rows would otherwise mutate history).
create or replace function app.run_engagement_rollup_v646(p_month date default null)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_month date := coalesce(date_trunc('month', p_month)::date,
                           (date_trunc('month', now() at time zone 'Asia/Singapore') - interval '1 month')::date);
  v_eng integer; v_open integer;
begin
  if v_month >= date_trunc('month', now() at time zone 'Asia/Singapore')::date then
    raise exception 'only closed months are rolled up' using errcode = '22023';
  end if;

  insert into public.engagement_monthly_rollup_v1
    (business_id, month, event_name, actor_scope, event_count, distinct_actor_count)
  select e.business_id, v_month, e.event_name, e.actor_scope,
         count(*), count(distinct e.actor_user_id)
    from public.product_adoption_events_v100 e
   where e.business_id is not null
     and (e.occurred_at at time zone 'Asia/Singapore')::date >= v_month
     and (e.occurred_at at time zone 'Asia/Singapore')::date < (v_month + interval '1 month')::date
   group by e.business_id, e.event_name, e.actor_scope
  on conflict (business_id, month, event_name, actor_scope) do nothing;
  get diagnostics v_eng = row_count;

  insert into public.account_open_monthly_rollup_v1
    (business_id, month, channel, open_days, distinct_subject_count)
  select a.business_id, v_month, a.channel, count(*), count(distinct a.subject_key)
    from public.customer_account_open_days_v175 a
   where a.open_date >= v_month
     and a.open_date < (v_month + interval '1 month')::date
   group by a.business_id, a.channel
  on conflict (business_id, month, channel) do nothing;
  get diagnostics v_open = row_count;

  return jsonb_build_object('month', v_month, 'engagement_rows', v_eng, 'account_open_rows', v_open);
end;
$$;
revoke all on function app.run_engagement_rollup_v646(date) from public, anon, authenticated;
grant execute on function app.run_engagement_rollup_v646(date) to service_role;

-- Backfill every closed month still inside the raw window.
do $backfill$
declare
  v_month date;
begin
  for v_month in
    select distinct date_trunc('month', occurred_at at time zone 'Asia/Singapore')::date
      from public.product_adoption_events_v100
     where date_trunc('month', occurred_at at time zone 'Asia/Singapore')::date
           < date_trunc('month', now() at time zone 'Asia/Singapore')::date
     order by 1
  loop
    perform app.run_engagement_rollup_v646(v_month);
  end loop;
end;
$backfill$;

select cron.schedule(
  'nestly-v646-engagement-rollup-monthly',
  '15 19 1 * *',
  $cron$select app.run_engagement_rollup_v646();$cron$
);

insert into public.analytics_observation_watermarks (metric_key, observed_since, reason)
values ('engagement_rollups', now(),
        'monthly identity-free engagement/account-open rollups exist from v646; backfilled over the surviving raw window only');

commit;
