-- NESTLY v633 — Phase A, M6 (A5/D8): forward-only tier history.
-- Tier membership is computed live by app.tier_resolve_v426 (the canonical resolver since
-- five functions were caught disagreeing) and has NO stored history — "was she Gold when
-- she redeemed in March" is unanswerable, and the resolver's past answers cannot be
-- reproduced safely. From v633, every observed change in the resolver's answer appends one
-- transition event. NO historical events are fabricated (owner ruling): each customer's
-- first event is their first observed state, previous_tier_id null, reason
-- 'initial_observation'.
--
-- Mechanism: app.tier_observe_v1 re-runs the canonical resolver (never a second opinion —
-- the v426 lesson) and compares against a small current-state anchor. Observation hooks are
-- ADDITIVE AFTER triggers on the tables whose rows can move the basis: sales (visits/spend),
-- points_ledger (points/expiry/adjust), loyalty_tiers (ladder edits/publishes -> per-business
-- sweep). A nightly sweep catches time-window drift (bases that decay without any write).
-- The sales/points triggers are named zzz_* so they fire after trg_sale_recorded has written
-- the earn rows the basis depends on (same-event triggers fire alphabetically).
begin;

-- ---------------------------------------------------------------------------
-- 1. Tables.
-- ---------------------------------------------------------------------------
create table public.tier_transition_events (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  client_id uuid not null,
  programme_id uuid,
  previous_tier_id uuid,
  new_tier_id uuid,
  at timestamptz not null default clock_timestamp(),
  trigger_kind text not null check (trigger_kind in
    ('sale','ledger','config_change','sweep','manual_adjust')),
  trigger_ref uuid,
  reason text,
  resolved_snapshot jsonb not null,
  created_at timestamptz not null default now()
);
create index tier_transition_events_client_idx
  on public.tier_transition_events (business_id, client_id, at);
alter table public.tier_transition_events enable row level security;
create policy tier_transitions_member_read on public.tier_transition_events
  for select to authenticated
  using (app.is_salon_member(business_id) or app.is_super_admin());
revoke all on public.tier_transition_events from public, anon, authenticated;
grant select on public.tier_transition_events to authenticated;

create or replace function app.tier_transition_events_guard_v633()
returns trigger language plpgsql
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
begin
  raise exception 'tier_transition_events is append-only' using errcode = '42501';
end;
$$;
create trigger trg_tier_transition_events_append_only
  before update or delete on public.tier_transition_events
  for each row execute function app.tier_transition_events_guard_v633();

-- Anchor: purely a change detector, not an authority — the resolver stays the
-- only opinion about tiers. Internal, no API surface.
create table app.tier_state_current (
  business_id uuid not null references public.businesses(id) on delete cascade,
  client_id uuid not null,
  tier_id uuid,
  as_of timestamptz not null default clock_timestamp(),
  primary key (business_id, client_id)
);
revoke all on app.tier_state_current from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 2. The observer.
-- ---------------------------------------------------------------------------
create or replace function app.tier_observe_v1(
  p_business uuid, p_client uuid, p_trigger_kind text, p_trigger_ref uuid default null)
returns void
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_resolved jsonb;
  v_new_tier uuid;
  v_anchor app.tier_state_current%rowtype;
  v_programme uuid;
begin
  if p_business is null or p_client is null then return; end if;
  v_resolved := app.tier_resolve_v426(p_business, p_client);
  if v_resolved is null then return; end if;
  v_new_tier := nullif(v_resolved #>> '{current,id}', '')::uuid;
  v_programme := app.live_balance_programme_v381(p_business);

  select * into v_anchor from app.tier_state_current
   where business_id = p_business and client_id = p_client
   for update;

  if not found then
    insert into app.tier_state_current (business_id, client_id, tier_id)
    values (p_business, p_client, v_new_tier)
    on conflict (business_id, client_id) do nothing;
    -- First observation is only an event when the ladder actually places the
    -- customer somewhere; "never had a tier, still has none" is not history.
    if v_new_tier is not null then
      insert into public.tier_transition_events
        (business_id, client_id, programme_id, previous_tier_id, new_tier_id,
         trigger_kind, trigger_ref, reason, resolved_snapshot)
      values
        (p_business, p_client, v_programme, null, v_new_tier,
         p_trigger_kind, p_trigger_ref, 'initial_observation',
         jsonb_build_object('basis', v_resolved->'basis', 'current', v_resolved->'current',
                            'tiers_running', v_resolved->'tiers_running'));
    end if;
    return;
  end if;

  if v_anchor.tier_id is not distinct from v_new_tier then
    return;
  end if;

  update app.tier_state_current
     set tier_id = v_new_tier, as_of = clock_timestamp()
   where business_id = p_business and client_id = p_client;

  insert into public.tier_transition_events
    (business_id, client_id, programme_id, previous_tier_id, new_tier_id,
     trigger_kind, trigger_ref, reason, resolved_snapshot)
  values
    (p_business, p_client, v_programme, v_anchor.tier_id, v_new_tier,
     p_trigger_kind, p_trigger_ref,
     case when v_new_tier is null then 'left_ladder' else 'threshold_change' end,
     jsonb_build_object('basis', v_resolved->'basis', 'current', v_resolved->'current',
                        'tiers_running', v_resolved->'tiers_running'));
end;
$$;
revoke all on function app.tier_observe_v1(uuid,uuid,text,uuid) from public, anon, authenticated;
grant execute on function app.tier_observe_v1(uuid,uuid,text,uuid) to service_role;

-- ---------------------------------------------------------------------------
-- 3. Observation hooks. Cheap (one resolver call) and idempotent (no-op when
--    nothing changed). Errors must never break a sale: observe defensively.
-- ---------------------------------------------------------------------------
create or replace function app.tier_observe_from_sale_v633()
returns trigger language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
begin
  if new.client_id is not null then
    begin
      perform app.tier_observe_v1(new.business_id, new.client_id, 'sale', new.id);
    exception when others then
      raise warning 'v633 tier observation failed for sale %: %', new.id, sqlerrm;
    end;
  end if;
  return new;
end;
$$;
create trigger zzz_tier_observe_sale_v633
  after insert on public.sales
  for each row execute function app.tier_observe_from_sale_v633();

create or replace function app.tier_observe_from_ledger_v633()
returns trigger language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
begin
  begin
    perform app.tier_observe_v1(new.business_id, new.client_id, 'ledger', new.id);
  exception when others then
    raise warning 'v633 tier observation failed for ledger row %: %', new.id, sqlerrm;
  end;
  return new;
end;
$$;
create trigger zzz_tier_observe_ledger_v633
  after insert on public.points_ledger
  for each row
  when (new.entry_type <> 'earn')
  execute function app.tier_observe_from_ledger_v633();
-- (earn rows are covered by the sale hook in the same transaction; expiry,
--  redeem and adjust rows arrive without a sale.)

-- Ladder edits re-place everyone: sweep the business.
create or replace function app.tier_sweep_business_v1(p_business uuid)
returns integer
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_client uuid;
  v_count integer := 0;
begin
  for v_client in
    select c.id from public.clients c
     where c.business_id = p_business
       and not coalesce(c.is_synthetic, false)
       and (exists (select 1 from public.points_ledger pl
                     where pl.business_id = p_business and pl.client_id = c.id)
         or exists (select 1 from public.sales s
                     where s.business_id = p_business and s.client_id = c.id))
  loop
    begin
      perform app.tier_observe_v1(p_business, v_client, 'config_change', null);
    exception when others then
      raise warning 'v633 tier sweep failed for client %: %', v_client, sqlerrm;
    end;
    v_count := v_count + 1;
  end loop;
  return v_count;
end;
$$;
revoke all on function app.tier_sweep_business_v1(uuid) from public, anon, authenticated;
grant execute on function app.tier_sweep_business_v1(uuid) to service_role;

create or replace function app.tier_observe_from_ladder_v633()
returns trigger language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
begin
  begin
    perform app.tier_sweep_business_v1(coalesce(new.business_id, old.business_id));
  exception when others then
    raise warning 'v633 tier ladder sweep failed: %', sqlerrm;
  end;
  return coalesce(new, old);
end;
$$;
create trigger zzz_tier_observe_ladder_v633
  after insert or update on public.loyalty_tiers
  for each row execute function app.tier_observe_from_ladder_v633();

-- Nightly drift sweep (time-window bases move without writes).
create or replace function app.run_tier_observe_sweep_v633()
returns integer
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_business uuid;
  v_total integer := 0;
begin
  for v_business in
    select b.id from public.businesses b
     where exists (select 1 from public.loyalty_tiers t
                    where t.business_id = b.id and t.deleted_at is null)
  loop
    v_total := v_total + coalesce(app.tier_sweep_business_v1(v_business), 0);
  end loop;
  return v_total;
end;
$$;
revoke all on function app.run_tier_observe_sweep_v633() from public, anon, authenticated;
grant execute on function app.run_tier_observe_sweep_v633() to service_role;

select cron.schedule(
  'nestly-v633-tier-observe-daily',
  '25 18 * * *',  -- 02:25 SGT, after the points-expiry sweeps have run
  $cron$select app.run_tier_observe_sweep_v633();$cron$
);

-- ---------------------------------------------------------------------------
-- 4. Watermark. No backfill by ruling: history begins at first observation.
-- ---------------------------------------------------------------------------
insert into public.analytics_observation_watermarks (metric_key, observed_since, reason)
values ('tier_history', now(),
        'tier transitions observed from v633 via the canonical resolver; no historical tier events are fabricated');

commit;
