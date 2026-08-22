-- nestly_v464 — an EARNED stamp reward may be given a shelf life (owner ruling R3(e), 2026-08-23).
--
-- THE RULING, verbatim in effect: per programme the owner may set "rewards expire N days after
-- being earned". OPTIONAL — blank/absent = never expires, which is exactly today's behaviour.
-- Applies only to rewards earned AFTER the setting exists; nothing a customer already holds may
-- change. The customer sees the expiry date on each earned reward. Expiry removes the reward and
-- leaves a history entry the customer and the owner can both see.
--
-- WHERE IT LIVES. Inside the v433–v437 stamp lifecycle, not beside it:
--   • the setting is a VERSIONED CONFIG field — loyalty_program_versions.stamp_reward_expiry_days,
--     mirrored onto loyalty_programs for display, cloned by create_loyalty_config_draft, carried
--     by publish_loyalty_config, written through business_set_earning_rule_v359 on the same v433
--     split/commit path stamp_per_cents and stamp_validity_days already take;
--   • the deadline is judged by ONE calculation, app.stamp_reward_expiry_v464, which the
--     availability core (v432), app.redeem_reward_core, the customer's stamp card and the till
--     all read — the v432 one-availability-core invariant, unbroken;
--   • the sweep is the v435 shape: a daily pg_cron job over the businesses that have ever
--     published a reward expiry, plus nothing else. No new scheduler.
--
-- WHY THE DEADLINE IS PINNED AT EARN TIME — AND WHY THAT MEANS PINNED TO THE CARD'S VERSION.
-- A reward must carry the deadline it was earned under, or a later edit would shorten a promise
-- the customer is already holding. In this engine the rules an earned stamp reward is judged by
-- are ALREADY pinned, and they are pinned as a set: v416 fixes a card to the configuration in
-- force when its FIRST STAMP landed, and v433/v435/v436 then price it, name it, size it, rate it
-- and time it from that one version. The reward expiry joins that set rather than inventing a
-- second, finer pin of its own. Three consequences, all of them the ones the ruling asks for:
--   (1) NON-RETROACTIVE, FOR FREE. Every version published before this migration carries NULL, so
--       every card open today resolves NULL and every reward on it never expires. There is no
--       backfill and no row is touched.
--   (2) A LATER CHANGE NEVER REACHES AN OPEN CARD. Setting or shortening the expiry writes a NEW
--       version (v433's split); the customer's open card keeps pointing at the old one. Their
--       rewards keep the deadline — or the absence of one — they were earned under.
--   (3) IT IS THE CONSERVATIVE READING. A card started before the setting existed gives its
--       rewards no expiry even if the customer earns them after the owner switched it on. That is
--       stricter than the ruling requires ("earned after the setting"), and it is the only reading
--       consistent with the card in the customer's hand: one card, one set of rules, start to
--       finish. The owner's change reaches them on their next card.
-- The moment of earning is therefore not a second pin but a MEASUREMENT, and it is derived rather
-- than materialised: app.stamp_reward_earned_at_v464 finds the ledger row that carried the
-- customer's running total up through the milestone. Deriving it (a) adds no writer to
-- app.on_sale_recorded, which nestly_v436 owns and which is not the place to grow a per-milestone
-- insert loop; (b) is automatically right for stamps that arrive from a referral payout or a pot
-- conversion, neither of which passes through the sale trigger; and (c) is right for every card
-- already open on the day this ships, with no backfill.
--
-- SURVIVAL OF CARD EXPIRY IS UNCHANGED (v435 rules 4/5/7 — protected). A milestone earned on a
-- card that later lapsed stays claimable exactly as before; the reward deadline is a SEPARATE and
-- purely additive clock that only exists when the owner set one. A reward with no expiry survives
-- card expiry forever, as today. A reward with an expiry dies on its own date whether its card is
-- open, lapsed or frozen — which is the point of the ruling, and does not weaken the survival
-- rule: survival says the card lapsing must not confiscate what was earned, not that what was
-- earned can never have a shelf life of its own.
--
-- ENFORCEMENT is read-path AND sweep, deliberately unlike v435. v435 could not judge on read
-- because closing a card MOVES value (the stamps are forfeited and a new cycle begins), so a
-- STABLE reader must not do it. Withdrawing an earned reward moves nothing: it is a predicate over
-- earned_at + N days. Judging it in app.stamp_reward_expiry_v464 means the customer's wallet, the
-- till and app.redeem_reward_core agree to the second, with no sweep lag in which the counter
-- would still honour something the wallet had already withdrawn. The sweep exists to RECORD the
-- event — the history entry the ruling asks for — and its row then becomes the authority, so a
-- later stamp correction cannot un-expire a reward the customer was already told had lapsed.

begin;

-- ============================================================================================
-- §1  SCHEMA — the versioned setting, its display mirror, and the expiry evidence table
-- ============================================================================================
alter table public.loyalty_program_versions
  add column if not exists stamp_reward_expiry_days integer
  check (stamp_reward_expiry_days is null or (stamp_reward_expiry_days between 1 and 3650));
comment on column public.loyalty_program_versions.stamp_reward_expiry_days is
  'nestly_v464: days an EARNED stamp reward stays claimable, counted from the moment the customer''s stamps reached it. NULL = never expires. Version-pinned: a reward is judged by the version its card was started under, so changing this never touches a reward a customer already holds.';

alter table public.loyalty_programs
  add column if not exists stamp_reward_expiry_days integer
  check (stamp_reward_expiry_days is null or (stamp_reward_expiry_days between 1 and 3650));
comment on column public.loyalty_programs.stamp_reward_expiry_days is
  'nestly_v464: display mirror of the active version''s earned-reward expiry. The engine reads the version rows.';

-- One row per reward the sweep has withdrawn. Append-only evidence, the shape
-- public.stamp_cycles and public.stamp_milestone_claims already carry: no write policy at all,
-- every insert through SECURITY DEFINER, the v34 immutability guard on delete/update.
create table if not exists public.stamp_reward_expiries_v464 (
  id                 uuid primary key default gen_random_uuid(),
  business_id        uuid not null references public.businesses(id) on delete cascade,
  programme_id       uuid not null,
  client_id          uuid not null,
  cycle_index        integer not null,
  reward_id          uuid not null,
  reward_version_id  uuid,
  config_version_id  uuid,
  reward_name        text not null,
  cost_points        integer not null,
  earned_at          timestamptz not null,
  expires_at         timestamptz not null,
  expiry_days        integer not null,
  recorded_at        timestamptz not null default now(),
  constraint stamp_reward_expiries_v464_cycle_check check (cycle_index >= 0),
  constraint stamp_reward_expiries_v464_days_check  check (expiry_days between 1 and 3650),
  constraint stamp_reward_expiries_v464_programme_fk foreign key (programme_id, business_id)
    references public.business_programmes(id, business_id) on delete restrict,
  constraint stamp_reward_expiries_v464_client_fk foreign key (client_id, business_id)
    references public.clients(id, business_id) on delete restrict,
  constraint stamp_reward_expiries_v464_reward_fk foreign key (reward_id, business_id)
    references public.loyalty_rewards(id, business_id) on delete restrict,
  constraint stamp_reward_expiries_v464_version_fk foreign key (reward_version_id, business_id)
    references public.loyalty_reward_versions(id, business_id) on delete restrict,
  constraint stamp_reward_expiries_v464_config_fk foreign key (config_version_id, business_id)
    references public.firm_config_versions(id, business_id) on delete restrict,
  -- The idempotency key. One withdrawal per (customer, card, reward) — a milestone becomes
  -- claimable again on the NEXT card because cycle_index moves, exactly as
  -- stamp_milestone_claims works.
  constraint stamp_reward_expiries_v464_uk
    unique (business_id, client_id, programme_id, cycle_index, reward_id)
);

create index if not exists stamp_reward_expiries_v464_client_idx
  on public.stamp_reward_expiries_v464 (business_id, client_id, programme_id);

comment on table public.stamp_reward_expiries_v464 is
  'nestly_v464 (owner ruling R3(e)): one row per EARNED stamp reward withdrawn because the owner''s '
  'per-programme deadline passed before the customer claimed it. Written only by '
  'app.stamp_reward_expire_due_v464. It is both the customer''s history entry and the owner''s trail, '
  'and once written it is the authority: the availability core and app.redeem_reward_core refuse the '
  'reward on the strength of this row alone, so a later stamp correction cannot un-expire it.';

do $$
begin
  if not exists (select 1 from pg_trigger
                  where tgname = 'trg_stamp_reward_expiries_v464_immutable') then
    create trigger trg_stamp_reward_expiries_v464_immutable
      before delete or update on public.stamp_reward_expiries_v464
      for each row execute function app.v34_immutable_evidence_guard();
  end if;
end $$;

alter table public.stamp_reward_expiries_v464 enable row level security;

drop policy if exists stamp_reward_expiries_v464_read on public.stamp_reward_expiries_v464;
create policy stamp_reward_expiries_v464_read on public.stamp_reward_expiries_v464
  for select using (app.is_salon_member(business_id));
drop policy if exists stamp_reward_expiries_v464_sa_read on public.stamp_reward_expiries_v464;
create policy stamp_reward_expiries_v464_sa_read on public.stamp_reward_expiries_v464
  for select using (app.is_super_admin());
-- NO write policy, deliberately. The sweep is the only writer and it is SECURITY DEFINER.

-- Schema public carries a Supabase DEFAULT ACL granting ALL to anon and authenticated on every
-- new table, so `authenticated` must be named in the revoke or it keeps INSERT/UPDATE/DELETE on
-- an evidence table (the trap v323 documented and this file inherits).
revoke all on public.stamp_reward_expiries_v464 from public, anon, authenticated;
grant select on public.stamp_reward_expiries_v464 to authenticated;
grant all    on public.stamp_reward_expiries_v464 to service_role, postgres;

-- The append-only guard on public.loyalty_program_versions has an allowlist of the columns the
-- owner's earning-rule editor may change in place, and nestly_v433 wrote it with a comment saying
-- stamp_validity_days was listed AHEAD of that column landing so the guard would not need another
-- restatement. The same courtesy is now owed to this one: without it, a firm whose stamps spine is
-- switched off takes business_set_earning_rule_v359's non-split branch, writes straight to the
-- published version, and is refused with 'published configuration rows are immutable'. Everything
-- else in this body is byte-identical to the deployed nestly_v433 version.
create or replace function app.loyalty_version_immutable_guard()
 returns trigger
 language plpgsql
 security definer
 set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $function$
declare
  v_status text;
  -- nestly_v433: the earning/card-shape columns the owner's stamp and earning-rule editors own.
  -- stamp_validity_days is listed ahead of the column landing (nestly_v435) so this guard does
  -- not need a third restatement. nestly_v464 adds stamp_reward_expiry_days on the same footing.
  v_owner_editable constant text[] := array[
    'stamp_target','stamp_per_cents','stamp_validity_days','stamp_reward_expiry_days',
    'earn_points_per_dollar','expiry_mode','expiry_days'];
begin
  if tg_op = 'DELETE' then
    raise exception 'configuration versions are append-only' using errcode='restrict_violation';
  end if;
  select status into v_status from public.firm_config_versions
   where id = old.config_version_id;
  if v_status <> 'draft' then
    if tg_op = 'UPDATE'
       and nullif(current_setting('app.v433_program_edit_version_id', true), '') = old.config_version_id::text
       and (to_jsonb(new) - v_owner_editable) = (to_jsonb(old) - v_owner_editable) then
      return new;
    end if;
    raise exception 'published configuration rows are immutable' using errcode='restrict_violation';
  end if;
  return new;
end;
$function$;

revoke all on function app.loyalty_version_immutable_guard() from public, anon, authenticated;

-- ============================================================================================
-- §2  THE ONE CALCULATION
--
--     app.stamp_cycle_window_v464   — every card this customer has held on this programme, as a
--                                     half-open time window [from, to). Boundaries are v435's:
--                                     a row AT OR AFTER a closure belongs to the NEW card.
--     app.stamp_reward_earned_at_v464 — the moment a level was reached inside a window: the LAST
--                                     upward crossing, so a correction that removes stamps and a
--                                     later re-earn are read as one honest "earned now", not as a
--                                     deadline that already ran out months ago.
--     app.stamp_reward_expiry_v464  — earned_at + the version's expiry days. NULL if the version
--                                     set none, or if the level was never reached. THIS is what
--                                     every surface calls; nothing else recomputes it.
-- ============================================================================================
create or replace function app.stamp_cycle_window_v464(
  p_business uuid, p_client uuid, p_programme uuid)
returns table(cycle_index integer, origin text, config_version_id uuid, slots integer,
              window_from timestamptz, window_to timestamptz)
language sql
stable
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
  with closed as (
    select sc.cycle_index, sc.origin, sc.config_version_id, sc.slots, sc.closed_at,
           lag(sc.closed_at) over (order by sc.closed_at, sc.cycle_index) as prev_close
      from public.stamp_cycles sc
     where sc.business_id = p_business
       and sc.client_id = p_client
       and sc.programme_id = p_programme
  )
  select closed.cycle_index, closed.origin, closed.config_version_id, closed.slots,
         coalesce(closed.prev_close, '-infinity'::timestamptz), closed.closed_at
    from closed
  union all
  -- The OPEN card. Its index is the number of cards already closed (the definition
  -- app.stamp_progress_v323 uses), its version the v416 pin, and it has no end.
  select (select count(*)::integer from public.stamp_cycles sc2
           where sc2.business_id = p_business and sc2.client_id = p_client
             and sc2.programme_id = p_programme),
         'open',
         app.stamp_cycle_version_v416(p_business, p_client, p_programme),
         null::integer,
         (select coalesce(max(sc3.closed_at), '-infinity'::timestamptz) from public.stamp_cycles sc3
           where sc3.business_id = p_business and sc3.client_id = p_client
             and sc3.programme_id = p_programme),
         'infinity'::timestamptz
$$;

comment on function app.stamp_cycle_window_v464(uuid, uuid, uuid) is
  'nestly_v464: every stamp card this customer has held on this programme as a half-open time '
  'window, closed cards and the open one alike, each with the configuration version it is pinned '
  'to. The boundary rule is nestly_v435''s: a ledger row sharing a closure''s instant belongs to '
  'the card that closure started.';

create or replace function app.stamp_reward_earned_at_v464(
  p_business uuid, p_client uuid, p_programme uuid,
  p_from timestamptz, p_to timestamptz, p_level integer)
returns timestamptz
language sql
stable
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
  -- The LAST row that carried the running total up through the level. max() rather than min()
  -- because a stamps pot can go down as well as up (a sale reversal, a v84 amount correction, a
  -- pot transfer): if the customer fell below the milestone and earned back up to it, the reward
  -- they are holding now was earned on the way back up, and a deadline measured from the first
  -- crossing could have lapsed before they ever held it again. A level of 0 or less is read as 1
  -- so a zero-cost gift is "earned" at the card's first stamp rather than never.
  select max(t.created_at)
    from (
      select pl.created_at,
             sum(pl.points) over (order by pl.created_at, pl.id) as running,
             sum(pl.points) over (order by pl.created_at, pl.id) - pl.points as running_before
        from public.points_ledger pl
       where pl.business_id = p_business
         and pl.client_id = p_client
         and pl.programme_id = p_programme
         and pl.created_at >= p_from
         and pl.created_at < p_to
    ) t
   where t.running        >= greatest(coalesce(p_level, 0), 1)
     and t.running_before  < greatest(coalesce(p_level, 0), 1)
$$;

create or replace function app.stamp_reward_expiry_v464(
  p_business uuid, p_client uuid, p_programme uuid, p_cycle_index integer, p_level integer)
returns table(earned_at timestamptz, expiry_days integer, expires_at timestamptz)
language sql
stable
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
  with w as (
    select cw.cycle_index, cw.config_version_id, cw.window_from, cw.window_to
      from app.stamp_cycle_window_v464(p_business, p_client, p_programme) cw
     where cw.cycle_index = p_cycle_index
     order by cw.window_from desc
     limit 1
  ), days as (
    -- The PIN. The days come from the version the CARD was started under, never from whatever the
    -- owner published since — that is what makes this non-retroactive.
    select lpv.stamp_reward_expiry_days as value
      from w
      join public.loyalty_program_versions lpv
        on lpv.config_version_id = w.config_version_id
       and lpv.business_id = p_business
  ), earned as (
    select app.stamp_reward_earned_at_v464(p_business, p_client, p_programme,
             w.window_from, w.window_to, p_level) as at
      from w
  )
  -- Zero rows when this customer has no such card, which every caller reads as "no deadline":
  -- the scalar sub-selects yield NULL and the sweep's lateral simply has nothing to visit.
  select earned.at, days.value,
         case when earned.at is not null and days.value is not null
              then earned.at + make_interval(days => days.value) end
    from earned
    left join days on true
$$;

comment on function app.stamp_reward_expiry_v464(uuid, uuid, uuid, integer, integer) is
  'nestly_v464 (owner ruling R3(e)): THE deadline calculation for one earned stamp milestone — the '
  'moment it was earned, the days its card''s pinned version allows, and the resulting date. Read by '
  'app.reward_availability_v432, app.redeem_reward_core, public.customer_get_stamp_card_v323 and the '
  'sweep, so the wallet, the counter and the cron can never disagree. NULL expires_at = never '
  'expires, which is every card open before this migration shipped.';

-- ============================================================================================
-- §3  THE AVAILABILITY CORE — app.reward_availability_v432 gains reward_expires_at and the
--     'reward_expired' state. The OUT columns change, so this is a drop/create rather than a
--     replace; all three readers over it are PL/pgSQL and resolve the name at run time, so the
--     drop breaks nothing between here and their restatements below.
--     Everything else in this body is byte-identical to the deployed nestly_v435 §10.
-- ============================================================================================
drop function if exists app.reward_availability_v432(uuid, uuid, timestamptz);
create or replace function app.reward_availability_v432(
  p_business uuid,
  p_client uuid,
  p_as_of timestamptz default now()
) returns table (
  reward_id uuid,
  reward_version_id uuid,
  customer_name text,
  description text,
  image_ref text,
  terms text,
  instructions text,
  taxonomy_label text,
  fulfillment_kind text,
  cost_points integer,
  credit_cents integer,
  claim_available_from timestamptz,
  claim_available_until timestamptz,
  entitlement_expiry_days integer,
  sort integer,
  source text,
  unit text,
  gate_threshold numeric,
  gate_label text,
  tier_met boolean,
  branch_count integer,
  service_count integer,
  product_count integer,
  used_count integer,
  remaining_units integer,
  reward_expires_at timestamptz,
  availability text
)
language sql
stable
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
  with business as (
    select b.id, b.active_config_version_id
      from public.businesses b
     where b.id = p_business
  ), stamps_spine as (
    -- nestly_v435: no `active` filter any more — a frozen card must still resolve its spine so
    -- earned milestones stay visible while the programme is off. The flag travels instead.
    select spine.id, spine.active from public.business_programmes spine
     where spine.business_id = p_business and spine.kind = 'stamps'
     order by spine.sort, spine.id limit 1
  ), points_spine as (
    select spine.id from public.business_programmes spine
     where spine.business_id = p_business and spine.kind = 'points' and spine.active
     order by spine.sort, spine.id limit 1
  ), stamp as (
    -- filled / cycle_index / slots exactly as redemption reads them (app.stamp_progress_v323).
    select coalesce(sp.slots, 0) as slots,
           coalesce(sp.filled, 0) as filled,
           coalesce(sp.cycle_index, 0) as cycle_index
      from app.stamp_progress_v323(p_business, p_client) sp
     limit 1
  ), pot as (
    -- The points balance a redemption can actually drain: the live points pot, capped by the
    -- proven batch remainder in the same pot (redeem_reward_core requires both).
    select least(
      (select coalesce(sum(pl.points), 0)::integer
         from public.points_ledger pl
        where pl.business_id = p_business and pl.client_id = p_client
          and pl.programme_id = (select id from points_spine)),
      (select coalesce(sum(pb.remaining), 0)::integer
         from public.points_batches pb
        where pb.business_id = p_business and pb.client_id = p_client
          and pb.remaining > 0
          and pb.programme_id = (select id from points_spine))
    ) as balance
  ), metric as (
    select app.v176_tier_gate_metric(p_business, p_client) as value
  ), stamp_version as (
    -- nestly_v416: a stamp gift is judged against the config the customer's OPEN card was
    -- started under — the same version redeem_reward_core will select.
    select case when exists (select 1 from stamps_spine)
      then app.stamp_cycle_version_v416(p_business, p_client, (select id from stamps_spine))
      end as config_version_id
  )
  select ranked.reward_id, ranked.reward_version_id, ranked.customer_name, ranked.description,
         ranked.image_ref, ranked.terms, ranked.instructions, ranked.taxonomy_label,
         ranked.fulfillment_kind, ranked.cost_points, ranked.credit_cents,
         ranked.claim_available_from, ranked.claim_available_until, ranked.entitlement_expiry_days,
         ranked.sort, ranked.source, ranked.unit, ranked.gate_threshold, ranked.gate_label,
         ranked.tier_met, ranked.branch_count, ranked.service_count, ranked.product_count,
         ranked.used_count, ranked.remaining_units, ranked.reward_expires_at,
         ranked.availability
  from (
    select rows.*, row_number() over (
      partition by rows.reward_id
      order by (rows.availability = 'available_at_counter') desc, rows.arm
    ) as rn
    from (
      select
        live.id as reward_id,
        rv.id as reward_version_id,
        rv.customer_name,
        rv.description,
        rv.image_ref,
        rv.terms,
        rv.instructions,
        rv.taxonomy_label,
        rv.fulfillment_kind,
        rv.cost_points::integer,
        rv.credit_cents::integer,
        rv.claim_available_from,
        rv.claim_available_until,
        rv.entitlement_expiry_days,
        rv.sort::integer,
        case when shape.is_stamp then 'stamp_card' else 'points' end as source,
        case when shape.is_stamp then 'stamps' else 'points' end as unit,
        gate.threshold as gate_threshold,
        gate.label as gate_label,
        case when gate.threshold is null then null
             else metric.value >= gate.threshold end as tier_met,
        scope.branch_count,
        scope.service_count,
        scope.product_count,
        usage.used_count,
        greatest(rv.cost_points - (case when shape.is_stamp
          then coalesce(stamp.filled, 0) else pot.balance end), 0)::integer as remaining_units,
        expiry.expires_at as reward_expires_at,
        case
          when rv.claim_available_from is not null and rv.claim_available_from > p_as_of
            then 'not_started'
          when rv.claim_available_until is not null and rv.claim_available_until <= p_as_of
            then 'ended'
          when gate.threshold is not null and metric.value < gate.threshold
            then 'tier_locked'
          when rv.usage_limit is not null and usage.used_count >= rv.usage_limit
            then 'limit_reached'
          when shape.is_stamp
            and (coalesce(stamp.slots, 0) <= 0 or rv.cost_points > coalesce(stamp.slots, 0))
            then 'not_on_card'
          when shape.is_stamp and claimed.this_cycle
            then 'claimed_this_cycle'
          -- nestly_v464 (owner ruling R3(e)): an earned milestone whose owner-set deadline has
          -- passed is withdrawn. `recorded` makes the sweep's history row the authority once it
          -- exists, so a later stamp correction can never un-expire what the customer was already
          -- told had lapsed.
          when shape.is_stamp and (expiry.recorded
               or (expiry.expires_at is not null and expiry.expires_at <= p_as_of))
            then 'reward_expired'
          when (case when shape.is_stamp then coalesce(stamp.filled, 0) else pot.balance end)
               < rv.cost_points
            then 'insufficient_balance'
          else 'available_at_counter'
        end as availability,
        -- The programme gate redemption enforces for POINTS: the reward's own spine row must
        -- exist and be active. Rewards with no programme link stay excluded — redeem_reward_core
        -- refuses those (XX001), so listing them would promise a claim the counter cannot honour.
        exists (
          select 1 from public.business_programmes sp2
           where sp2.id = live.programme_id and sp2.active
        ) as programme_active,
        0 as arm
      from business
      join public.loyalty_rewards live
        on live.business_id = business.id
       and live.active
       and not live.paused
      cross join lateral (
        select coalesce(live.programme_id = (select id from stamps_spine), false) as is_stamp
      ) shape
      join public.loyalty_reward_versions rv
        on rv.reward_id = live.id
       and rv.business_id = live.business_id
       and rv.active
       and rv.config_version_id = case when shape.is_stamp
         then coalesce((select sv.config_version_id from stamp_version sv),
                       business.active_config_version_id)
         else business.active_config_version_id end
      left join stamp on true
      cross join pot
      cross join metric
      cross join lateral (
        select app.v176_reward_gate_threshold(p_business, rv.min_tier_id, rv.min_tier_threshold)
                 as threshold,
               app.v176_reward_gate_label(p_business, rv.min_tier_id) as label
      ) gate
      cross join lateral (
        select (select count(*)::integer from public.loyalty_reward_branches e
                 where e.reward_version_id = rv.id) as branch_count,
               (select count(*)::integer from public.loyalty_reward_services e
                 where e.reward_version_id = rv.id) as service_count,
               (select count(*)::integer from public.loyalty_reward_products e
                 where e.reward_version_id = rv.id) as product_count
      ) scope
      cross join lateral (
        select count(*)::integer as used_count
          from public.loyalty_redemptions lr
         where lr.business_id = p_business and lr.client_id = p_client
           and lr.reward_id = live.id
      ) usage
      cross join lateral (
        select exists (
          select 1 from public.stamp_milestone_claims claim
           where claim.business_id = p_business
             and claim.client_id = p_client
             and claim.programme_id = live.programme_id
             and claim.cycle_index = coalesce(stamp.cycle_index, 0)
             and claim.reward_id = live.id
        ) as this_cycle
      ) claimed
      cross join lateral (
        -- nestly_v464: the deadline this EARNED milestone carries, from the one calculation
        -- (app.stamp_reward_expiry_v464). Null for a points reward, for a milestone the customer
        -- has not reached, and for a card pinned to a version that set no reward expiry.
        select case when shape.is_stamp then (
                 select x.expires_at
                   from app.stamp_reward_expiry_v464(p_business, p_client, live.programme_id,
                          coalesce(stamp.cycle_index, 0), rv.cost_points) x) end as expires_at,
               case when shape.is_stamp then exists (
                 select 1 from public.stamp_reward_expiries_v464 e
                  where e.business_id = p_business and e.client_id = p_client
                    and e.programme_id = live.programme_id
                    and e.cycle_index = coalesce(stamp.cycle_index, 0)
                    and e.reward_id = live.id) else false end as recorded
      ) expiry
      where live.programme_id is not null
        and exists (select 1 from public.business_programmes sp3
                     where sp3.id = live.programme_id)

      union all

      -- nestly_v435 SURVIVAL ARM: milestones earned on EXPIRED cycles and never claimed, offered
      -- under the version that cycle was pinned to. remaining_units is 0 by definition (the
      -- stamps were already earned). Listable regardless of the spine's active flag (rule 7).
      select
        live.id,
        rv.id,
        rv.customer_name,
        rv.description,
        rv.image_ref,
        rv.terms,
        rv.instructions,
        rv.taxonomy_label,
        rv.fulfillment_kind,
        rv.cost_points::integer,
        rv.credit_cents::integer,
        rv.claim_available_from,
        rv.claim_available_until,
        rv.entitlement_expiry_days,
        rv.sort::integer,
        'stamp_card' as source,
        'stamps' as unit,
        gate.threshold,
        gate.label,
        case when gate.threshold is null then null
             else metric.value >= gate.threshold end,
        scope.branch_count,
        scope.service_count,
        scope.product_count,
        usage.used_count,
        0 as remaining_units,
        expiry.expires_at as reward_expires_at,
        case
          when rv.claim_available_from is not null and rv.claim_available_from > p_as_of
            then 'not_started'
          when rv.claim_available_until is not null and rv.claim_available_until <= p_as_of
            then 'ended'
          when gate.threshold is not null and metric.value < gate.threshold
            then 'tier_locked'
          when rv.usage_limit is not null and usage.used_count >= rv.usage_limit
            then 'limit_reached'
          -- nestly_v464: the survivor's own deadline, judged exactly as on a live card.
          when expiry.recorded
               or (expiry.expires_at is not null and expiry.expires_at <= p_as_of)
            then 'reward_expired'
          else 'available_at_counter'
        end as availability,
        true as programme_active,
        1 as arm
      from public.stamp_cycles sc
      join stamps_spine on stamps_spine.id = sc.programme_id
      join public.loyalty_reward_versions rv
        on rv.business_id = p_business
       and rv.config_version_id = sc.config_version_id
       and rv.active
       and rv.cost_points <= sc.slots
      join public.loyalty_rewards live
        on live.id = rv.reward_id
       and live.business_id = p_business
       and live.active
       and not live.paused
      cross join metric
      cross join lateral (
        select app.v176_reward_gate_threshold(p_business, rv.min_tier_id, rv.min_tier_threshold)
                 as threshold,
               app.v176_reward_gate_label(p_business, rv.min_tier_id) as label
      ) gate
      cross join lateral (
        select (select count(*)::integer from public.loyalty_reward_branches e
                 where e.reward_version_id = rv.id) as branch_count,
               (select count(*)::integer from public.loyalty_reward_services e
                 where e.reward_version_id = rv.id) as service_count,
               (select count(*)::integer from public.loyalty_reward_products e
                 where e.reward_version_id = rv.id) as product_count
      ) scope
      cross join lateral (
        select count(*)::integer as used_count
          from public.loyalty_redemptions lr
         where lr.business_id = p_business and lr.client_id = p_client
           and lr.reward_id = live.id
      ) usage
      cross join lateral (
        -- nestly_v464: a SURVIVING milestone carries the deadline of the cycle that earned it.
        select (select x.expires_at
                  from app.stamp_reward_expiry_v464(p_business, p_client, sc.programme_id,
                         sc.cycle_index, rv.cost_points) x) as expires_at,
               exists (select 1 from public.stamp_reward_expiries_v464 e
                        where e.business_id = p_business and e.client_id = p_client
                          and e.programme_id = sc.programme_id
                          and e.cycle_index = sc.cycle_index
                          and e.reward_id = rv.reward_id) as recorded
      ) expiry
      where sc.business_id = p_business
        and sc.client_id = p_client
        and sc.origin = 'expired'
        and not exists (
          select 1 from public.stamp_milestone_claims claim
           where claim.business_id = p_business
             and claim.client_id = p_client
             and claim.programme_id = sc.programme_id
             and claim.cycle_index = sc.cycle_index
             and claim.reward_id = rv.reward_id
        )
    ) rows
    -- Rule 7 in one line: a running programme lists everything as before; a stopped STAMP
    -- programme lists only what the customer can genuinely claim right now.
    where rows.programme_active
       or (rows.source = 'stamp_card' and rows.availability = 'available_at_counter')
  ) ranked
  where ranked.rn = 1
$$;

-- ============================================================================================
-- §4  REDEMPTION — the nestly_v435 §9 body with ONE addition, marked: an earned stamp reward
--     whose owner-set deadline has passed is refused here, in the authority every redemption
--     surface goes through (till, QR scanner, v404 manual redemption).
-- ============================================================================================
create or replace function app.redeem_reward_core(p_business uuid, p_client uuid, p_reward uuid, p_idempotency_key text, p_branch uuid default null::uuid, p_service uuid default null::uuid, p_product uuid default null::uuid)
 returns json
 language plpgsql
 security definer
 set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $function$
declare
  lp public.loyalty_programs%rowtype; v_reward public.loyalty_rewards%rowtype;
  v_version public.loyalty_reward_versions%rowtype; v_balance integer; v_batch_balance integer;
  v_remaining integer; v_take integer; v_batch record; v_actor uuid:=auth.uid(); v_staff uuid;
  v_points_id uuid:=gen_random_uuid(); v_credit_id uuid; v_operation_id uuid:=gen_random_uuid();
  v_redemption_id uuid:=gen_random_uuid(); v_provenance_id uuid:=gen_random_uuid();
  v_payload jsonb; v_operation public.loyalty_operations%rowtype; v_rows integer;
  v_usage integer; v_eligibility jsonb; v_result json; v_reward_programme uuid;
  v_programme_kind text; v_stamp_slots integer; v_stamp_filled integer; v_cycle_index integer;
  v_consumes boolean:=true; v_points_spent integer; v_cycle_id uuid; v_config_version uuid;
  v_survival boolean:=false; v_current_ok boolean; v_srv_cycle integer; v_srv_cfg uuid; -- nestly_v435
  v_reward_expiry timestamptz; -- nestly_v464
begin
  if p_idempotency_key is null or length(btrim(p_idempotency_key))<8 then raise exception 'idempotency key must contain at least 8 characters' using errcode='22023'; end if;
  p_idempotency_key:=btrim(p_idempotency_key);
  if not app.has_perm(p_business,'create_sales') then raise exception 'not authorized' using errcode='42501'; end if;
  perform 1 from public.businesses where id=p_business for share;
  select s.id into v_staff from public.staff s where s.business_id=p_business and s.user_id=v_actor and s.active and 'create_sales'=any(app.role_perms(s.role)) limit 1 for update;
  if not found then raise exception 'active staff authorization required' using errcode='42501'; end if;
  perform 1 from public.clients c where c.id=p_client and c.business_id=p_business for update;
  if not found then raise exception 'client does not belong to this business'; end if;
  if p_branch is not null and not exists(select 1 from public.branches where id=p_branch and business_id=p_business) then raise exception 'branch does not belong to business'; end if;
  if not app.can_see_branch(p_business,p_branch) then
    raise exception 'redemption branch scope is not permitted' using errcode='42501';
  end if;
  if p_service is not null and not exists(select 1 from public.services where id=p_service and business_id=p_business) then raise exception 'service does not belong to business'; end if;
  if p_product is not null and not exists(select 1 from public.products where id=p_product and business_id=p_business) then raise exception 'product does not belong to business'; end if;
  v_payload:=jsonb_build_object('business_id',p_business,'client_id',p_client,'reward_id',p_reward,'branch_id',p_branch,'service_id',p_service,'product_id',p_product);
  perform set_config('app.loyalty_operation_insert_id',v_operation_id::text,true);
  insert into public.loyalty_operations(id,business_id,client_id,reward_id,operation_type,actor,idempotency_key,request_payload,request_hash)
  values(v_operation_id,p_business,p_client,p_reward,'redeem_reward',v_actor,p_idempotency_key,v_payload,md5(v_payload::text))
  on conflict(business_id,operation_type,idempotency_key) do nothing;
  get diagnostics v_rows=row_count; perform set_config('app.loyalty_operation_insert_id','',true);
  if v_rows=0 then
    select * into v_operation from public.loyalty_operations where business_id=p_business and operation_type='redeem_reward' and idempotency_key=p_idempotency_key for update;
    if v_operation.actor is distinct from v_actor or v_operation.request_hash is distinct from md5(v_payload::text) then raise exception 'idempotency conflict' using errcode='23505'; end if;
    if v_operation.status='completed' then return v_operation.result::json; end if;
    raise exception 'redemption already in progress' using errcode='55P03';
  end if;
  select * into lp from public.loyalty_programs where business_id=p_business limit 1;
  if not found then raise exception 'catalog redemption is inactive'; end if;
  select * into v_reward from public.loyalty_rewards where id=p_reward and business_id=p_business;
  if not found then raise exception 'reward not found in this business'; end if;
  -- V326: the live row is mutable and is what pause/delete actually write. The version row below
  -- is an immutable published snapshot that pause/delete cannot touch (trg_loyalty_reward_versions_immutable)
  -- — so this check, not that one, is what makes an immediate pause or delete actually block redemption here.
  if not v_reward.active then raise exception 'reward not found or inactive'; end if;
  if v_reward.paused then raise exception 'reward is currently paused' using errcode='22023'; end if;
  -- nestly_v416: WHICH published configuration this redemption is judged against. For a stamp
  -- card it is the one the customer's OPEN card was started under, so the counter and the card in
  -- their hand cannot disagree; for points there are no cycles and it stays the active version.
  -- The kind is read off the LIVE reward row because v_version is what we are about to select.
  select spine.kind into v_programme_kind from public.business_programmes spine
   where spine.id = v_reward.programme_id and spine.business_id = p_business;
  if v_programme_kind = 'stamps' then
    -- nestly_v435 (a): a card past its deadline closes NOW, before the claim is judged, so the
    -- pin below already reflects the closed state and a fresh claim can never land on it.
    perform app.stamp_expire_open_cycle_v435(p_business, p_client, v_reward.programme_id);
    select sp.slots,sp.filled,sp.cycle_index into v_stamp_slots,v_stamp_filled,v_cycle_index from app.stamp_progress_v323(p_business,p_client) sp;
    if not found then raise exception 'this business is not running a stamp card' using errcode='XX001'; end if;
    v_config_version := app.stamp_cycle_version_v416(p_business, p_client, v_reward.programme_id);
    select rv.* into v_version from public.loyalty_reward_versions rv where rv.reward_id=p_reward and rv.business_id=p_business and rv.config_version_id=v_config_version;
    v_current_ok := v_version.id is not null and v_version.active and coalesce(v_stamp_slots,0)>0
                    and v_version.cost_points<=v_stamp_slots and v_stamp_filled>=v_version.cost_points;
    if not v_current_ok then
      -- nestly_v435 (b): SURVIVAL. The newest expired cycle on which this milestone was earned
      -- under its own version's rules and never claimed. One claim per (expired cycle, reward),
      -- enforced by the claims table's uniqueness exactly as on a live card.
      select sc.cycle_index, sc.config_version_id into v_srv_cycle, v_srv_cfg
        from public.stamp_cycles sc
       where sc.business_id=p_business and sc.client_id=p_client
         and sc.programme_id=v_reward.programme_id and sc.origin='expired'
         and exists (select 1 from public.loyalty_reward_versions rv
                      where rv.reward_id=p_reward and rv.business_id=p_business
                        and rv.config_version_id=sc.config_version_id and rv.active
                        and rv.cost_points <= sc.slots)
         and not exists (select 1 from public.stamp_milestone_claims claim
                      where claim.business_id=p_business and claim.client_id=p_client
                        and claim.programme_id=v_reward.programme_id
                        and claim.cycle_index=sc.cycle_index and claim.reward_id=p_reward)
       order by sc.cycle_index desc limit 1;
      if found then
        v_survival := true; v_cycle_index := v_srv_cycle; v_config_version := v_srv_cfg;
        select rv.* into v_version from public.loyalty_reward_versions rv where rv.reward_id=p_reward and rv.business_id=p_business and rv.config_version_id=v_srv_cfg;
      end if;
    end if;
    -- nestly_v464 (owner ruling R3(e)): an EARNED stamp reward may carry an owner-set deadline,
    -- pinned to the configuration the card was started under. Refused here, in the same authority
    -- that enforces every other claim rule, so the till, the QR scanner and v404's manual
    -- redemption all refuse identically and the availability core's 'reward_expired' can never be
    -- a promise the counter would still honour. An unearned milestone has no deadline (nothing was
    -- earned), so this fires only on the two arms above.
    if v_version.id is not null and (coalesce(v_current_ok,false) or v_survival) then
      select x.expires_at into v_reward_expiry
        from app.stamp_reward_expiry_v464(p_business, p_client, v_reward.programme_id,
               v_cycle_index, v_version.cost_points) x;
      if exists (select 1 from public.stamp_reward_expiries_v464 e
                  where e.business_id=p_business and e.client_id=p_client
                    and e.programme_id=v_reward.programme_id
                    and e.cycle_index=v_cycle_index and e.reward_id=p_reward) then
        raise exception 'this reward has expired and can no longer be claimed' using errcode='check_violation';
      end if;
      if v_reward_expiry is not null and v_reward_expiry <= now() then
        raise exception 'this reward expired on %', to_char(v_reward_expiry at time zone 'Asia/Singapore', 'DD Mon YYYY')
          using errcode='check_violation';
      end if;
    end if;
  else
    v_config_version := (select b.active_config_version_id from public.businesses b where b.id = p_business);
    select rv.* into v_version from public.loyalty_reward_versions rv where rv.reward_id=p_reward and rv.business_id=p_business and rv.config_version_id=v_config_version;
  end if;
  if v_version.id is null or not v_version.active then raise exception 'reward not found or inactive'; end if;
  if v_version.claim_available_from is not null and v_version.claim_available_from>now() then raise exception 'reward unavailable'; end if;
  if v_version.claim_available_until is not null and v_version.claim_available_until<=now() then raise exception 'reward expired'; end if;
  select jsonb_build_object(
    'branch_ids',coalesce((select jsonb_agg(branch_id order by branch_id) from public.loyalty_reward_branches where reward_version_id=v_version.id),'[]'::jsonb),
    'service_ids',coalesce((select jsonb_agg(service_id order by service_id) from public.loyalty_reward_services where reward_version_id=v_version.id),'[]'::jsonb),
    'product_ids',coalesce((select jsonb_agg(product_id order by product_id) from public.loyalty_reward_products where reward_version_id=v_version.id),'[]'::jsonb),
    'selected',jsonb_build_object('branch_id',p_branch,'service_id',p_service,'product_id',p_product)) into v_eligibility;
  if exists(select 1 from public.loyalty_reward_branches where reward_version_id=v_version.id) and not exists(select 1 from public.loyalty_reward_branches where reward_version_id=v_version.id and branch_id=p_branch) then raise exception 'reward not eligible at branch'; end if;
  if exists(select 1 from public.loyalty_reward_services where reward_version_id=v_version.id) and not exists(select 1 from public.loyalty_reward_services where reward_version_id=v_version.id and service_id=p_service) then raise exception 'reward not eligible for service'; end if;
  if exists(select 1 from public.loyalty_reward_products where reward_version_id=v_version.id) and not exists(select 1 from public.loyalty_reward_products where reward_version_id=v_version.id and product_id=p_product) then raise exception 'reward not eligible for product'; end if;
  select count(*)::integer into v_usage from public.loyalty_redemptions where business_id=p_business and client_id=p_client and reward_id=p_reward;
  if v_version.usage_limit is not null and v_usage>=v_version.usage_limit then
    raise exception 'reward usage limit reached' using errcode='check_violation';
  end if;
  if app.v176_reward_gate_threshold(p_business, v_version.min_tier_id, v_version.min_tier_threshold) is not null and app.v176_tier_gate_metric(p_business, p_client) < app.v176_reward_gate_threshold(p_business, v_version.min_tier_id, v_version.min_tier_threshold) then
    raise exception 'reward requires a higher membership tier' using errcode='check_violation';
  end if;
  select coalesce(sum(points),0)::integer into v_balance from public.points_ledger where business_id=p_business and client_id=p_client;
  v_reward_programme:=v_version.programme_id;
  if v_reward_programme is null then raise exception 'reward programme is not resolvable for this business' using errcode='XX001'; end if;
  if not exists(select 1 from public.business_programmes spine where spine.id=v_reward_programme and spine.business_id=p_business) then raise exception 'reward programme does not belong to this business' using errcode='42501'; end if;
  select spine.kind into v_programme_kind from public.business_programmes spine where spine.id=v_reward_programme;
  -- nestly_v435 (c): points claims still require the programme to be running; a stamp
  -- entitlement the customer already earned stays claimable while the programme is off.
  if v_programme_kind is distinct from 'stamps' and not exists(select 1 from public.business_programmes spine where spine.id=v_reward_programme and spine.active) then raise exception 'catalog redemption is inactive'; end if;
  if v_programme_kind='stamps' then
    v_consumes:=false; v_points_spent:=0;
    if not v_survival then
      if coalesce(v_stamp_slots,0)<=0 then raise exception 'this stamp card has no length set' using errcode='23514'; end if;
      if v_version.cost_points>v_stamp_slots then raise exception 'this gift sits past the end of the stamp card' using errcode='23514'; end if;
      if v_stamp_filled<v_version.cost_points then raise exception 'not enough stamps yet' using errcode='check_violation'; end if;
    end if;
  else
    v_points_spent:=v_version.cost_points;
    select coalesce(sum(remaining),0)::integer into v_batch_balance from public.points_batches where business_id=p_business and client_id=p_client and programme_id=v_reward_programme;
    if v_balance<v_version.cost_points or v_batch_balance<v_version.cost_points then raise exception 'insufficient proven points' using errcode='check_violation'; end if;
  end if;
  insert into public.loyalty_redemptions(id,business_id,client_id,reward_id,reward_name,points_spent,credit_cents,actor,reward_version_id,reward_snapshot,eligibility_snapshot,fulfillment_kind,entitlement_expires_at,usage_number,consumes_balance)
  values(v_redemption_id,p_business,p_client,p_reward,v_version.customer_name,v_points_spent,v_version.credit_cents,v_actor,v_version.id,
    to_jsonb(v_version)-'id'-'config_version_id'-'business_id'-'created_at',v_eligibility,v_version.fulfillment_kind,
    case when v_version.entitlement_expiry_days is null then null else now()+make_interval(days=>v_version.entitlement_expiry_days) end,v_usage+1,v_consumes);
  insert into public.loyalty_redemption_provenance
    (id,business_id,client_id,operation_id,redemption_id,points_ledger_id,credit_ledger_id,config_version_id,consumes_balance)
  values(v_provenance_id,p_business,p_client,v_operation_id,v_redemption_id,case when v_consumes then v_points_id end,
    case when v_version.credit_cents>0 then gen_random_uuid() end,v_version.config_version_id,v_consumes)
  returning credit_ledger_id into v_credit_id;
  if v_consumes then
  v_remaining:=v_version.cost_points;
  for v_batch in select id,remaining from public.points_batches where business_id=p_business and client_id=p_client and remaining>0 and programme_id=v_reward_programme order by expires_at nulls last,earned_at,id for update loop
    exit when v_remaining=0; v_take:=least(v_batch.remaining,v_remaining);
    update public.points_batches set remaining=remaining-v_take where id=v_batch.id;
    insert into public.loyalty_redemption_batch_drains
      (provenance_id,business_id,client_id,redemption_id,points_batch_id,drained_points)
    values(v_provenance_id,p_business,p_client,v_redemption_id,v_batch.id,v_take);
    v_remaining:=v_remaining-v_take;
  end loop;
  perform set_config('app.points_ledger_insert_id',v_points_id::text,true); perform set_config('app.points_ledger_write_scope','redeem_points',true);
  insert into public.points_ledger(id,business_id,client_id,entry_type,points,reference,actor,programme_id) values(v_points_id,p_business,p_client,'redeem',-v_version.cost_points,'reward: '||v_version.customer_name,v_actor,v_reward_programme);
  perform set_config('app.points_ledger_insert_id','',true); perform set_config('app.points_ledger_write_scope','',true);
  else
    begin
      insert into public.stamp_milestone_claims(
        business_id,programme_id,client_id,cycle_index,slot_position,reward_id,reward_version_id,
        redemption_id,config_version_id,is_final,actor)
      values(p_business,v_reward_programme,p_client,v_cycle_index,v_version.cost_points,p_reward,
        v_version.id,v_redemption_id,v_version.config_version_id,
        (not v_survival) and v_version.cost_points>=v_stamp_slots,v_actor);
      if (not v_survival) and v_version.cost_points>=v_stamp_slots then
        v_cycle_id:=gen_random_uuid();
        insert into public.stamp_cycles(
          id,business_id,programme_id,client_id,cycle_index,slots,origin,redemption_id,reward_id,
          config_version_id,actor)
        values(v_cycle_id,p_business,v_reward_programme,p_client,v_cycle_index,v_stamp_slots,'claimed',
          v_redemption_id,p_reward,v_version.config_version_id,v_actor);
      end if;
    exception when unique_violation then
      raise exception 'this stamp gift has already been claimed on this card' using errcode='23505';
    end;
  end if;
  if v_credit_id is not null then
    perform set_config('app.credit_ledger_insert_id',v_credit_id::text,true); perform set_config('app.credit_ledger_write_scope','redeem_points',true);
    insert into public.credit_ledger(id,business_id,client_id,entry_type,amount_cents,reference,actor) values(v_credit_id,p_business,p_client,'loyalty_earn',v_version.credit_cents,'loyalty reward: '||v_version.customer_name,v_actor);
    perform set_config('app.credit_ledger_insert_id','',true); perform set_config('app.credit_ledger_write_scope','',true);
  end if;
  v_result:=json_build_object('ok',true,'redemption_id',v_redemption_id,
    'reward_version_id',v_version.id,'reward',v_version.customer_name,
    'points_spent',v_points_spent,'credit_cents',v_version.credit_cents,
    'consumes_balance',v_consumes,
    'stamp_slot',case when v_programme_kind='stamps' then v_version.cost_points end,
    'stamp_cycle_index',v_cycle_index,'stamp_card_closed',v_cycle_id is not null,
    'from_expired_card',v_survival);
  perform set_config('app.loyalty_operation_complete_id',v_operation_id::text,true);
  update public.loyalty_operations set status='completed',result=v_result::jsonb,completed_at=now() where id=v_operation_id;
  perform set_config('app.loyalty_operation_complete_id','',true); return v_result;
end $function$;
-- ============================================================================================
-- §5  THE SWEEP — the v435 shape, one job later in the same evening. It WRITES THE HISTORY
--     ENTRY; it does not decide anything the readers have not already decided, and it moves no
--     stamps, no ledger row and no cycle. Idempotent by the table's own unique key.
--
--     WHICH CARDS IT VISITS: the open card and every card that lapsed ('expired'), because those
--     are exactly the two arms app.reward_availability_v432 offers rewards from. A card that was
--     COMPLETED ('claimed') carries no surviving entitlements — v435's survival arm is scoped to
--     origin='expired' — so there is nothing on it left to withdraw.
-- ============================================================================================
create or replace function app.stamp_reward_expire_due_v464(
  p_business uuid, p_client uuid, p_programme uuid)
returns integer
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_count integer := 0;
  v_filled integer;
  v_row record;
begin
  select coalesce(sp.filled, 0) into v_filled
    from app.stamp_progress_v323(p_business, p_client) sp limit 1;
  v_filled := coalesce(v_filled, 0);

  for v_row in
    select w.cycle_index, w.origin, w.config_version_id,
           rv.reward_id, rv.id as reward_version_id, rv.customer_name, rv.cost_points,
           x.earned_at, x.expiry_days, x.expires_at
      from app.stamp_cycle_window_v464(p_business, p_client, p_programme) w
      join public.loyalty_reward_versions rv
        on rv.business_id = p_business
       and rv.config_version_id = w.config_version_id
       and rv.active
       and rv.programme_id = p_programme
      -- The live row's own state, exactly as the availability core reads it: a gift the owner has
      -- already paused or retired is not on offer, so withdrawing it again would write a history
      -- entry for something the customer was no longer being shown.
      join public.loyalty_rewards live
        on live.id = rv.reward_id
       and live.business_id = p_business
       and live.active
       and not live.paused
      cross join lateral app.stamp_reward_expiry_v464(p_business, p_client, p_programme,
                           w.cycle_index, rv.cost_points) x
     where w.origin in ('open', 'expired')
       and x.expires_at is not null
       and x.expires_at <= now()
       -- Earned, on this card: the same "filled >= cost" the availability core applies to the
       -- open card, and the same "cost <= slots" v435 applies to a lapsed one.
       and rv.cost_points <= case when w.origin = 'open' then v_filled else coalesce(w.slots, 0) end
       and not exists (
         select 1 from public.stamp_milestone_claims claim
          where claim.business_id = p_business and claim.client_id = p_client
            and claim.programme_id = p_programme and claim.cycle_index = w.cycle_index
            and claim.reward_id = rv.reward_id)
       and not exists (
         select 1 from public.stamp_reward_expiries_v464 e
          where e.business_id = p_business and e.client_id = p_client
            and e.programme_id = p_programme and e.cycle_index = w.cycle_index
            and e.reward_id = rv.reward_id)
  loop
    insert into public.stamp_reward_expiries_v464(
      business_id, programme_id, client_id, cycle_index, reward_id, reward_version_id,
      config_version_id, reward_name, cost_points, earned_at, expires_at, expiry_days)
    values (p_business, p_programme, p_client, v_row.cycle_index, v_row.reward_id,
            v_row.reward_version_id, v_row.config_version_id, v_row.customer_name,
            v_row.cost_points, v_row.earned_at, v_row.expires_at, v_row.expiry_days)
    on conflict on constraint stamp_reward_expiries_v464_uk do nothing;
    if found then
      insert into public.audit_log(business_id, actor, action, entity, entity_id, detail)
      values (p_business, null, 'stamp_reward.expired', 'stamp_reward_expiries_v464', p_client,
        jsonb_build_object('client_id', p_client, 'programme_id', p_programme,
          'cycle_index', v_row.cycle_index, 'cycle_origin', v_row.origin,
          'reward_id', v_row.reward_id, 'reward_name', v_row.customer_name,
          'cost_points', v_row.cost_points, 'earned_at', v_row.earned_at,
          'expires_at', v_row.expires_at, 'expiry_days', v_row.expiry_days,
          'config_version_id', v_row.config_version_id));
      v_count := v_count + 1;
    end if;
  end loop;
  return v_count;
end;
$$;

create or replace function app.run_stamp_reward_expiry_for_business(p_business uuid)
returns integer
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_spine uuid;
  v_client uuid;
  v_count integer := 0;
begin
  -- No `active` filter, matching v435's survival rule 7: a frozen programme still holds earned
  -- rewards, and a deadline the owner set does not pause because collecting did.
  select spine.id into v_spine from public.business_programmes spine
   where spine.business_id = p_business and spine.kind = 'stamps'
   order by spine.sort, spine.id limit 1;
  if v_spine is null then return 0; end if;
  for v_client in
    select distinct pl.client_id from public.points_ledger pl
     where pl.business_id = p_business and pl.programme_id = v_spine and pl.points > 0
  loop
    v_count := v_count + app.stamp_reward_expire_due_v464(p_business, v_client, v_spine);
  end loop;
  return v_count;
end;
$$;

create or replace function app.run_stamp_reward_expiry()
returns void
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare v_biz uuid;
begin
  for v_biz in
    select distinct spine.business_id
      from public.business_programmes spine
     where spine.kind = 'stamps'
       -- Deliberately loose, for v435's reason: an OPEN card may pin an older version that set a
       -- deadline while the active one no longer does, so the gate is "any version this firm ever
       -- published carried one", not "the active version carries one".
       and exists (select 1 from public.loyalty_program_versions v2
                    where v2.business_id = spine.business_id
                      and v2.stamp_reward_expiry_days is not null)
  loop
    perform app.run_stamp_reward_expiry_for_business(v_biz);
  end loop;
end;
$$;

do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.schedule('nestly-stamp-reward-expiry', '45 19 * * *',
                          'select app.run_stamp_reward_expiry()');
  end if;
end $$;

-- ============================================================================================
-- §6  CUSTOMER READERS — the catalogue, the stamp card and the history list carry the date.
--     Bodies as deployed (nestly_v432 §2, nestly_v435 §11, nestly_v422) with the marked additions.
-- ============================================================================================
create or replace function public.customer_get_reward_catalog(p_business_slug text)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_context record;
  v_result jsonb;
  v_balance_scope text;
begin
  if auth.uid() is null then
    raise exception 'authenticated customer session required' using errcode = '28000';
  end if;
  select * into v_context from app.v32_customer_wallet_context(p_business_slug) limit 1;
  if not found then
    raise exception 'verified customer link required' using errcode = '42501';
  end if;
  if not ('loyalty' = any(v_context.enabled_modules)) or not exists (
    select 1 from public.loyalty_programs lp
     where lp.business_id = v_context.business_id and lp.active
  ) then
    raise exception 'loyalty module is unavailable for this business' using errcode = '42501';
  end if;

  -- nestly_v432: availability is the ONE core calculation the staff redeem-now list and the
  -- customer hero list also read, so the counter and Customer View cannot disagree about what
  -- is redeemable. Restricted rewards stay visible here with their eligibility scope, exactly
  -- as before.
  select coalesce(jsonb_agg(jsonb_build_object(
    'customer_name', core.customer_name,
    'description', core.description,
    'image_ref', core.image_ref,
    'terms', core.terms,
    'instructions', core.instructions,
    'taxonomy_label', core.taxonomy_label,
    'fulfillment_kind', core.fulfillment_kind,
    'cost_points', core.cost_points,
    'claim_available_from', core.claim_available_from,
    'claim_available_until', core.claim_available_until,
    'entitlement_expiry_days', core.entitlement_expiry_days,
    -- nestly_v464: the day this EARNED reward stops being claimable. Null when the
    -- owner set no expiry, or when the customer has not earned it yet.
    'expires_at', core.reward_expires_at,
    'availability', core.availability,
    'claim_method', 'counter',
    'source', core.source,
    'unit', core.unit,
    'tier_requirement', case when core.gate_threshold is null then null else jsonb_build_object(
      'tier_label', core.gate_label,
      'threshold', core.gate_threshold,
      'met', coalesce(core.tier_met, false)
    ) end,
    'eligibility', jsonb_build_object(
      'branches', jsonb_build_object('scope', case when core.branch_count = 0 then 'all' else 'restricted' end, 'count', core.branch_count),
      'services', jsonb_build_object('scope', case when core.service_count = 0 then 'all' else 'restricted' end, 'count', core.service_count),
      'products', jsonb_build_object('scope', case when core.product_count = 0 then 'all' else 'restricted' end, 'count', core.product_count)
    )
  ) order by core.sort, core.customer_name), '[]'::jsonb)
  into v_result
  from app.reward_availability_v432(v_context.business_id, v_context.client_id, now()) core;

  -- v230/v241: the one owner choice for what points are FOR, so the wallet tells one
  -- story. As an OBJECT: appending to the rewards array made the mode unreadable (v241).
  v_balance_scope := app.programme_balance_scope_v312(v_context.business_id);
  return jsonb_build_object(
    'rewards', coalesce(v_result, '[]'::jsonb),
    'points_mode', (select points_mode from public.businesses where id = v_context.business_id),
    'programmes_contract', 'v310',
    'balance_scope', v_balance_scope,
    'programmes', jsonb_build_array(jsonb_build_object(
      'kind', case when exists (
                     select 1 from public.loyalty_programs programme_v310
                      where programme_v310.business_id = v_context.business_id
                        and programme_v310.loyalty_model = 'stamps')
                   then 'stamps' else 'points' end,
      'balance_scope', v_balance_scope,
      'rewards', coalesce(v_result, '[]'::jsonb))));
end;
$$;

create or replace function public.customer_get_stamp_card_v323(p_business_slug text)
 returns jsonb
 language plpgsql
 stable security definer
 set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $function$
declare
  v_context record;
  v_progress record;
  v_milestones jsonb;
  v_metric numeric;
  v_deadline record; -- nestly_v435
  v_spend_per_cents integer; -- nestly_v435
begin
  if auth.uid() is null then
    raise exception 'authenticated customer session required' using errcode = '28000';
  end if;
  select * into v_context from app.v32_customer_wallet_context(p_business_slug) limit 1;
  if not found then
    raise exception 'verified customer link required' using errcode = '42501';
  end if;

  if not ('loyalty' = any(v_context.enabled_modules)) then
    return jsonb_build_object('enabled', false);
  end if;
  select * into v_progress
    from app.stamp_progress_v323(v_context.business_id, v_context.client_id) limit 1;
  if not found then
    return jsonb_build_object('enabled', false);
  end if;

  v_metric := app.v176_tier_gate_metric(v_context.business_id, v_context.client_id);

  -- nestly_v435: the open card's clock and pinned earn rate, from the version it started under.
  select * into v_deadline from app.stamp_cycle_deadline_v435(
    v_context.business_id, v_context.client_id, v_progress.programme_id);
  select lpv.stamp_per_cents into v_spend_per_cents
    from public.loyalty_program_versions lpv
   where lpv.config_version_id = v_deadline.config_version_id
     and lpv.business_id = v_context.business_id;
  if v_spend_per_cents is null then
    select lp.stamp_per_cents into v_spend_per_cents
      from public.loyalty_programs lp where lp.business_id = v_context.business_id;
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
    'reward_id', rung.reward_id,
    'name', rung.customer_name,
    'slot', rung.cost_points,
    'is_final', rung.cost_points >= coalesce(v_progress.slots, 0)
                and coalesce(v_progress.slots, 0) > 0,
    'claimed_this_cycle', rung.claimed,
    'description', rung.description,
    'image_ref', rung.image_ref,
    'terms', rung.terms,
    'instructions', rung.instructions,
    -- nestly_v435 rule 7 ordering: an EARNED, unclaimed milestone stays claimable at the
    -- counter even while the programme is off; only what is not yet earned freezes.
    'availability', case
      when rung.claim_available_from is not null and now() < rung.claim_available_from
        then 'not_started'
      when rung.claim_available_until is not null and now() >= rung.claim_available_until
        then 'ended'
      when rung.gate_threshold is not null and v_metric < rung.gate_threshold then 'tier_locked'
      when rung.claimed then 'claimed_this_cycle'
      -- nestly_v464: the owner-set deadline on an earned milestone, judged by the same
      -- calculation the availability core and app.redeem_reward_core read.
      when rung.reward_expiry_recorded
           or (rung.reward_expires_at is not null and rung.reward_expires_at <= now())
        then 'reward_expired'
      when rung.usage_limit is not null and rung.used_count >= rung.usage_limit
        then 'limit_reached'
      when v_progress.filled >= rung.cost_points then 'available_at_counter'
      when not v_progress.programme_active then 'paused'
      else 'insufficient_stamps'
    end,
    'stamps_to_go', greatest(rung.cost_points - v_progress.filled, 0),
    -- nestly_v464: the date the customer must use this earned gift by. Null = never.
    'expires_at', rung.reward_expires_at
  ) order by rung.cost_points, rung.customer_name), '[]'::jsonb)
  into v_milestones
  from (
    select rv.reward_id, rv.customer_name, rv.cost_points, rv.description, rv.image_ref,
           rv.terms, rv.instructions, rv.claim_available_from, rv.claim_available_until,
           rv.usage_limit,
           app.v176_reward_gate_threshold(v_context.business_id, rv.min_tier_id,
             rv.min_tier_threshold) as gate_threshold,
           (select count(*)::integer from public.loyalty_redemptions lr
             where lr.business_id = v_context.business_id
               and lr.client_id = v_context.client_id
               and lr.reward_id = rv.reward_id) as used_count,
           exists (select 1 from public.stamp_milestone_claims claim
                    where claim.business_id = v_context.business_id
                      and claim.client_id = v_context.client_id
                      and claim.programme_id = v_progress.programme_id
                      and claim.cycle_index = v_progress.cycle_index
                      and claim.reward_id = rv.reward_id) as claimed,
           (select x.expires_at
              from app.stamp_reward_expiry_v464(v_context.business_id, v_context.client_id,
                     v_progress.programme_id, v_progress.cycle_index, rv.cost_points) x)
             as reward_expires_at,
           exists (select 1 from public.stamp_reward_expiries_v464 e
                    where e.business_id = v_context.business_id
                      and e.client_id = v_context.client_id
                      and e.programme_id = v_progress.programme_id
                      and e.cycle_index = v_progress.cycle_index
                      and e.reward_id = rv.reward_id) as reward_expiry_recorded
      from public.businesses b
      join public.loyalty_reward_versions rv
        /* nestly_v416: the customer's OPEN card, not whatever the firm published last. */
        on rv.business_id = b.id and rv.active
       and rv.config_version_id = app.stamp_cycle_version_v416(
             v_context.business_id, v_context.client_id, v_progress.programme_id)
     where b.id = v_context.business_id
       and rv.programme_id = v_progress.programme_id
  ) rung;

  return jsonb_build_object(
    'enabled', true,
    'contract', 'v323',
    'unit', 'stamps',
    'running', v_progress.programme_active,
    'running_since', v_progress.running_since,
    'paused_since', v_progress.paused_since,
    'slots', v_progress.slots,
    'filled', v_progress.filled,
    'shown_filled', case when coalesce(v_progress.slots, 0) > 0
                         then least(v_progress.filled, v_progress.slots)
                         else v_progress.filled end,
    'carried', case when coalesce(v_progress.slots, 0) > 0
                    then greatest(v_progress.filled - v_progress.slots, 0) else 0 end,
    'cycle_index', v_progress.cycle_index,
    'lifetime', v_progress.net_stamps,
    'ready', v_progress.ready,
    'pot_migrated', v_progress.pot_migrated,
    -- nestly_v435: the card's own rules, from the version this card started under.
    'spend_per_stamp_cents', v_spend_per_cents,
    'validity_days', v_deadline.validity_days,
    'started_at', v_deadline.started_at,
    'expires_at', v_deadline.expires_at,
    'expired', v_deadline.expires_at is not null and v_deadline.expires_at <= now()
               and coalesce(v_progress.filled, 0) > 0,
    'milestones', v_milestones,
    'next_milestone', (
      select rung.value from jsonb_array_elements(v_milestones) as rung(value)
       where (rung.value ->> 'claimed_this_cycle')::boolean is not true
       order by (rung.value ->> 'slot')::integer
       limit 1)
  );
end
$function$;

create or replace function public.customer_get_reward_history_v422(
  p_business_slug text,
  p_limit integer default 50
)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $function$
declare
  v_context record;
  v_limit integer := least(greatest(coalesce(p_limit, 50), 1), 100);
  v_items jsonb;
begin
  if auth.uid() is null then
    raise exception 'authenticated customer session required' using errcode = '28000';
  end if;

  -- Identity, business and client all come from here. Nothing about WHO is being asked about is
  -- taken from an argument.
  select * into v_context
    from app.v32_customer_wallet_context(p_business_slug)
   limit 1;
  if not found then
    raise exception 'verified customer link required' using errcode = '42501';
  end if;

  select coalesce(jsonb_agg(item order by redeemed_at desc, id desc), '[]'::jsonb)
    into v_items
    from (
      select claimed.id, claimed.redeemed_at, claimed.item
        from (
          select redemption.id,
                 redemption.redeemed_at,
                 jsonb_build_object(
                   'id', redemption.id,
                   'source', 'reward',
                   'reward_name', redemption.reward_name,
                   'redeemed_at', redemption.redeemed_at,
                   -- The cost is printed back to the customer in the unit they paid in. A
                   -- stamp-card milestone is claimed without consuming a balance (v323), so
                   -- points_spent is 0 on those rows and the client prints no cost line rather
                   -- than "0 points".
                   'points_spent', redemption.points_spent,
                   'consumes_balance', redemption.consumes_balance,
                   'fulfillment_kind', redemption.fulfillment_kind,
                   -- image_ref is read from the snapshot the redemption itself stored, not from
                   -- the live reward: a gift whose photo the firm has since changed should appear
                   -- in history as the thing the customer actually received.
                   'image_ref', nullif(redemption.reward_snapshot->>'image_ref', ''),
                   'sale_id', null
                 ) as item
            from public.loyalty_redemptions redemption
           where redemption.business_id = v_context.business_id
             and redemption.client_id = v_context.client_id
             and not exists (
               select 1
                 from public.loyalty_redemption_reversals reversal
                where reversal.business_id = redemption.business_id
                  and reversal.redemption_id = redemption.id
             )

          union all

          -- nestly_v427: the three granted entitlements, once the counter has actually handed
          -- them over. A grant with status='redeemed' always has redeemed_at set — the
          -- <table>_redeem_shape check constraint enforces it — so the ordering key is never null.
          select welcome.id, welcome.redeemed_at,
                 jsonb_build_object(
                   'id', welcome.id, 'source', 'welcome',
                   'reward_name', welcome.reward_label,
                   'redeemed_at', welcome.redeemed_at,
                   'points_spent', 0, 'consumes_balance', false,
                   'fulfillment_kind', null, 'image_ref', null,
                   'sale_id', welcome.redeemed_sale_id)
            from public.welcome_offer_grants_v215 welcome
           where welcome.business_id = v_context.business_id
             and welcome.client_id = v_context.client_id
             and welcome.status = 'redeemed'
             and welcome.redeemed_at is not null

          union all

          select bringback.id, bringback.redeemed_at,
                 jsonb_build_object(
                   'id', bringback.id, 'source', 'bringback',
                   'reward_name', bringback.reward_label,
                   'redeemed_at', bringback.redeemed_at,
                   'points_spent', 0, 'consumes_balance', false,
                   'fulfillment_kind', null, 'image_ref', null,
                   'sale_id', bringback.redeemed_sale_id)
            from public.bringback_grants_v361 bringback
           where bringback.business_id = v_context.business_id
             and bringback.client_id = v_context.client_id
             and bringback.status = 'redeemed'
             and bringback.redeemed_at is not null

          union all

          select referral.id, referral.redeemed_at,
                 jsonb_build_object(
                   'id', referral.id, 'source', 'referral',
                   'reward_name', referral.reward_label,
                   'redeemed_at', referral.redeemed_at,
                   'points_spent', 0, 'consumes_balance', false,
                   'fulfillment_kind', null, 'image_ref', null,
                   'sale_id', referral.redeemed_sale_id)
            from public.referral_grants_v420 referral
           where referral.business_id = v_context.business_id
             and referral.client_id = v_context.client_id
             and referral.status = 'redeemed'
             and referral.redeemed_at is not null

          union all

          -- nestly_v464 (owner ruling R3(e)): "expiry removes the reward with a history entry".
          -- A reward the customer earned and lost has to be accounted for somewhere they can see,
          -- or it simply vanishes from the wallet. It joins this list as a FIFTH source rather
          -- than a second list, so one screen answers "what happened to my rewards?". The date
          -- slot carries the expiry instant so the merged ordering stays chronological; `source`
          -- tells the client this row is a loss, not a claim, and its own pill says so.
          -- These rows are written only by app.stamp_reward_expire_due_v464; nothing here derives
          -- or decides anything.
          select lapsed.id, lapsed.expires_at,
                 jsonb_build_object(
                   'id', lapsed.id, 'source', 'expired',
                   'reward_name', lapsed.reward_name,
                   'redeemed_at', lapsed.expires_at,
                   'expired_at', lapsed.expires_at,
                   'earned_at', lapsed.earned_at,
                   'points_spent', 0, 'consumes_balance', false,
                   'fulfillment_kind', null, 'image_ref', null,
                   'sale_id', null)
            from public.stamp_reward_expiries_v464 lapsed
           where lapsed.business_id = v_context.business_id
             and lapsed.client_id = v_context.client_id
        ) claimed
       -- The limit is applied to the MERGED list, not per source: a customer with 60 points
       -- redemptions and one free coffee last week must still see the coffee.
       order by claimed.redeemed_at desc, claimed.id desc
       limit v_limit
    ) as recent;

  return jsonb_build_object(
    'contract', 'v422',
    'business_id', v_context.business_id,
    'items', v_items
  );
end
$function$;

-- NOTE ON public.customer_get_business_actions_v89: it is NOT restated. It selects
-- core.availability straight from the core, so 'reward_expired' reaches it unchanged, and the
-- client's copy map has a safe default for a value it does not know (nestly_v399). Adding a field
-- to a reader that does not need one would only widen the restatement surface.

-- ============================================================================================
-- §7  STAFF REDEEM-NOW — the nestly_v432 §4 body, carrying the date. The list itself already
--     narrows to ('available_at_counter','insufficient_balance'), so an expired reward simply
--     stops being offered; the refusal sentence, if a stale list is acted on, comes from §4.
-- ============================================================================================
create or replace function public.staff_get_customer_actionable_loyalty_v145(p_business uuid, p_client uuid, p_branch uuid default null::uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_as_of timestamptz := statement_timestamp();
  v_result jsonb;
  -- v381: which pot this balance is, and whether this tenant's pots are safe to read per programme
  v_balance_scope text := app.programme_balance_scope_v312(p_business);
  v_live_programme uuid := app.live_balance_programme_v381(p_business);
begin
  perform public.require_module_scope_v145(
    p_business, p_branch, 'clients'
  );
  perform public.require_module_scope_v145(
    p_business, p_branch, 'loyalty'
  );
  if not exists (
    select 1
      from public.clients client
     where client.id = p_client
       and client.business_id = p_business
  ) then
    raise exception 'customer not found in business'
      using errcode = '22023';
  end if;

  with program as (
    select
      loyalty.id,
      loyalty.kind,
      loyalty.loyalty_model,
      loyalty.earn_points_per_dollar,
      loyalty.redeem_points,
      loyalty.reward_credit_cents,
      loyalty.stamp_per_cents,
      loyalty.expiry_mode,
      loyalty.configuration_status,
      coalesce(loyalty.active, false)
        and loyalty.configuration_status = 'published' as enabled,
      business.active_config_version_id
    from public.businesses business
    left join public.loyalty_programs loyalty
      on loyalty.business_id = business.id
    where business.id = p_business
  ), ledger_balance as (
    select greatest(coalesce(sum(ledger.points), 0), 0)::integer as units
      from public.points_ledger ledger
     where ledger.business_id = p_business
       and ledger.client_id = p_client
       -- v381: the balance is the LIVE programme's pot, never every pot added together
       and (v_balance_scope <> 'programme_pot'
            or ledger.programme_id is not distinct from v_live_programme)
  ), unexpired_batches as (
    select
      batch.id,
      batch.remaining,
      batch.earned_at,
      batch.expires_at,
      sum(batch.remaining) over (
        order by batch.expires_at nulls last, batch.earned_at, batch.id
        rows between unbounded preceding and current row
      )::bigint as cumulative_remaining
      from public.points_batches batch
     where batch.business_id = p_business
       and batch.client_id = p_client
       and batch.remaining > 0
       and (v_balance_scope <> 'programme_pot'
            or batch.programme_id is not distinct from v_live_programme)
       and (batch.expires_at is null or batch.expires_at > v_as_of)
  ), batch_balance as (
    select coalesce(sum(batch.remaining), 0)::integer as units
      from unexpired_batches batch
  ), loyalty_balance as (
    select case when program.enabled
      then greatest(least(ledger_balance.units, batch_balance.units), 0)
      else 0 end::integer as units
      from program cross join ledger_balance cross join batch_balance
  ), actionable_batches as (
    select
      batch.expires_at,
      least(
        batch.remaining::bigint,
        greatest(
          loyalty_balance.units::bigint
            - (batch.cumulative_remaining - batch.remaining::bigint),
          0
        )
      )::integer as actionable_remaining
      from unexpired_batches batch
      cross join loyalty_balance
     where loyalty_balance.units > 0
       and batch.cumulative_remaining - batch.remaining::bigint
           < loyalty_balance.units::bigint
  ), next_expiry as (
    select batch.expires_at,
           sum(batch.actionable_remaining)::integer as units
      from actionable_batches batch
     where batch.expires_at is not null
       and batch.actionable_remaining > 0
     group by batch.expires_at
     order by batch.expires_at
     limit 1
  ), credit_balance as (
    select greatest(coalesce(sum(ledger.amount_cents), 0), 0)::integer
      as balance_cents
      from public.credit_ledger ledger
     where ledger.business_id = p_business
       and ledger.client_id = p_client
  ), redemption_capability as (
    select (
      program.enabled
      and app.platform_feature_enabled('customer_qr_redemption')
      and coalesce(capability.redemption_enabled, false)
    ) as enabled
    from program
    left join public.business_customer_capabilities_v89 capability
      on capability.business_id = p_business
  ), candidate_rewards as (
    -- nestly_v432: the rows come from the ONE availability core the customer's own surfaces
    -- read (app.reward_availability_v432), so this list can never offer a gift the counter
    -- would refuse. Only two states are actionable at a till: redeemable now, or genuine
    -- progress toward a gift ("5 more stamps"). Everything else — wrong programme, off the
    -- card, claimed on this card, tier-locked, expired, limit reached — is simply not listed.
    -- Restricted rewards stay excluded as before: v404 manual redemption carries no service
    -- or product context.
    select
      core.source,
      core.availability,
      core.unit,
      core.reward_id,
      core.customer_name as name,
      core.cost_points as cost_units,
      core.credit_cents,
      core.fulfillment_kind,
      core.sort as sort_order,
      core.remaining_units,
      core.reward_expires_at,
      (redemption_capability.enabled
        and core.availability = 'available_at_counter') as available_now
    from app.reward_availability_v432(p_business, p_client, v_as_of) core
    cross join redemption_capability
    where core.branch_count = 0
      and core.service_count = 0
      and core.product_count = 0
      and core.availability in ('available_at_counter', 'insufficient_balance')
  ), reward_list as (
    select coalesce(jsonb_agg(jsonb_build_object(
      'source', candidate.source,
      'availability', candidate.availability,
      'unit', candidate.unit,
      'reward_id', candidate.reward_id,
      'name', candidate.name,
      'cost_units', candidate.cost_units,
      'credit_cents', candidate.credit_cents,
      'fulfillment_kind', candidate.fulfillment_kind,
      'remaining_units', candidate.remaining_units,
      'expires_at', candidate.reward_expires_at,
      'available_now', candidate.available_now
    ) order by candidate.remaining_units, candidate.sort_order,
      lower(candidate.name), candidate.reward_id nulls first), '[]'::jsonb)
      as rewards
      from candidate_rewards candidate
  ), next_reward as (
    select jsonb_build_object(
      'source', candidate.source,
      'availability', candidate.availability,
      'unit', candidate.unit,
      'reward_id', candidate.reward_id,
      'name', candidate.name,
      'cost_units', candidate.cost_units,
      'credit_cents', candidate.credit_cents,
      'fulfillment_kind', candidate.fulfillment_kind,
      'remaining_units', candidate.remaining_units,
      'expires_at', candidate.reward_expires_at,
      'available_now', candidate.available_now
    ) as reward
    from candidate_rewards candidate
    order by candidate.remaining_units, candidate.sort_order,
      lower(candidate.name), candidate.reward_id nulls first
    limit 1
  )
  select jsonb_build_object(
    'as_of', v_as_of,
    'program', case when program.id is null then null else jsonb_build_object(
      'id', program.id,
      'active', program.enabled,
      'kind', program.kind,
      'model', program.loyalty_model,
      'unit', case when program.loyalty_model = 'stamps'
        then 'stamps' else 'points' end,
      'earn_points_per_dollar', program.earn_points_per_dollar,
      'stamp_per_cents', program.stamp_per_cents,
      'redeem_points', program.redeem_points,
      'reward_credit_cents', program.reward_credit_cents,
      'expiry_mode', program.expiry_mode,
      'configuration_status', program.configuration_status
    ) end,
    'points_balance', loyalty_balance.units,
    'credit_balance_cents', credit_balance.balance_cents,
    'expiry', case
      when not program.enabled or program.expiry_mode = 'none'
        or next_expiry.expires_at is null then null
      else jsonb_build_object(
        'expires_at', next_expiry.expires_at,
        'units', next_expiry.units
      ) end,
    'redemption_enabled', redemption_capability.enabled,
    'rewards', reward_list.rewards,
    'next_reward', next_reward.reward
  ) into v_result
  from program
  cross join loyalty_balance
  cross join credit_balance
  cross join redemption_capability
  cross join reward_list
  left join next_expiry on true
  left join next_reward on true;

  return v_result;
end;
$$;

-- ============================================================================================
-- §8  OWNER WRITE PATH — the setting is saved, cloned into every draft, and carried by publish.
--     business_set_earning_rule_v359 goes 6-arg -> 7-arg; the 6-arg is dropped first so no
--     PGRST203 overload ambiguity can appear (the nestly_v435 precedent). Every new parameter
--     defaults, so existing positional and named calls resolve unchanged.
-- ============================================================================================
drop function if exists public.business_set_earning_rule_v359(uuid, numeric, integer, text, integer, integer);
create or replace function public.business_set_earning_rule_v359(
  p_business uuid,
  p_earn_points_per_dollar numeric default null::numeric,
  p_stamp_per_cents integer default null::integer,
  p_expiry_mode text default null::text,
  p_expiry_days integer default null::integer,
  p_stamp_validity_days integer default null::integer,
  p_stamp_reward_expiry_days integer default null::integer)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $function$
declare
  v_mode text := nullif(btrim(coalesce(p_expiry_mode,'')),'');
  v_days integer;
  v_row public.loyalty_programs%rowtype;
  v_active_version uuid;
  v_stamps_active boolean;
  v_target uuid;
  v_split boolean := false;
  -- nestly_v435: 0 is the UI's "never expires" — stored as NULL. Distinguish "not provided"
  -- (parameter null = leave alone) from "clear it" (0).
  v_validity_provided boolean := p_stamp_validity_days is not null;
  v_validity integer := case when coalesce(p_stamp_validity_days, 0) = 0 then null else p_stamp_validity_days end;
  -- nestly_v464: the SAME convention for the earned-reward deadline. 0 is the UI's "never
  -- expires" and is stored as NULL; a null PARAMETER means "not provided, leave it alone", so a
  -- points-only save can never clear a stamps tenant's reward expiry as a side effect.
  v_reward_expiry_provided boolean := p_stamp_reward_expiry_days is not null;
  v_reward_expiry integer := case when coalesce(p_stamp_reward_expiry_days, 0) = 0 then null else p_stamp_reward_expiry_days end;
  v_commit jsonb := jsonb_build_object('publish_status', 'published');
begin
  if not app.c45_owner_loyalty_write(p_business) then
    raise exception 'owner loyalty configuration access required' using errcode='42501';
  end if;

  if p_earn_points_per_dollar is not null and p_earn_points_per_dollar <= 0 then
    raise exception 'points per dollar must be greater than zero' using errcode='22023';
  end if;
  if p_stamp_per_cents is not null and p_stamp_per_cents <= 0 then
    raise exception 'spend per stamp must be greater than zero' using errcode='22023';
  end if;
  if v_validity is not null and (v_validity < 1 or v_validity > 3650) then
    raise exception 'card validity must be between 1 and 3650 days' using errcode='22023';
  end if;
  if v_reward_expiry is not null and (v_reward_expiry < 1 or v_reward_expiry > 3650) then
    raise exception 'reward expiry must be between 1 and 3650 days' using errcode='22023';
  end if;

  if v_mode is not null then
    if v_mode not in ('none','fixed','inactivity') then
      raise exception 'invalid expiry mode' using errcode='22023';
    end if;
    if v_mode = 'none' then
      v_days := null;
    else
      v_days := p_expiry_days;
      if v_days is null or v_days < 1 or v_days > 3650 then
        raise exception 'expiry days must be between 1 and 3650' using errcode='22023';
      end if;
    end if;
  end if;

  insert into public.loyalty_programs(business_id, active, configuration_status,
    earn_points_per_dollar, stamp_per_cents, expiry_mode, expiry_days, stamp_validity_days,
    stamp_reward_expiry_days)
  values (p_business, false, 'draft',
    coalesce(p_earn_points_per_dollar, 1), p_stamp_per_cents,
    coalesce(v_mode, 'none'), v_days, v_validity, v_reward_expiry)
  on conflict (business_id) do update set
    -- NB: must test the PARAMETER, not `excluded`. The INSERT arm defaults an omitted rate to 1,
    -- so `excluded.earn_points_per_dollar` is never null and a coalesce here would silently reset
    -- a saved rate on every unrelated save.
    earn_points_per_dollar = case when p_earn_points_per_dollar is null then public.loyalty_programs.earn_points_per_dollar else excluded.earn_points_per_dollar end,
    stamp_per_cents        = case when p_stamp_per_cents is null then public.loyalty_programs.stamp_per_cents else excluded.stamp_per_cents end,
    expiry_mode            = case when v_mode is null then public.loyalty_programs.expiry_mode else excluded.expiry_mode end,
    expiry_days            = case when v_mode is null then public.loyalty_programs.expiry_days else excluded.expiry_days end,
    stamp_validity_days    = case when not v_validity_provided then public.loyalty_programs.stamp_validity_days else excluded.stamp_validity_days end,
    stamp_reward_expiry_days = case when not v_reward_expiry_provided then public.loyalty_programs.stamp_reward_expiry_days else excluded.stamp_reward_expiry_days end
  returning * into v_row;

  select b.active_config_version_id into v_active_version
    from public.businesses b where b.id = p_business;
  if v_active_version is not null then
    v_stamps_active := exists (
      select 1 from public.business_programmes spine
       where spine.business_id = p_business and spine.kind = 'stamps' and spine.active);
    if v_stamps_active then
      v_target := app.stamp_config_edit_begin_v433(p_business);
      v_split := (v_target is distinct from v_active_version);
    else
      v_target := v_active_version;
    end if;

    if v_split then
      update public.loyalty_program_versions
         set earn_points_per_dollar = case when p_earn_points_per_dollar is null then earn_points_per_dollar else p_earn_points_per_dollar end,
             stamp_per_cents        = case when p_stamp_per_cents is null then stamp_per_cents else p_stamp_per_cents end,
             expiry_mode            = case when v_mode is null then expiry_mode else v_mode end,
             expiry_days            = case when v_mode is null then expiry_days else v_days end,
             stamp_validity_days    = case when not v_validity_provided then stamp_validity_days else v_validity end,
             stamp_reward_expiry_days = case when not v_reward_expiry_provided then stamp_reward_expiry_days else v_reward_expiry end
       where config_version_id = v_target and business_id = p_business;
    else
      perform set_config('app.v433_program_edit_version_id', v_target::text, true);
      update public.loyalty_program_versions
         set earn_points_per_dollar = case when p_earn_points_per_dollar is null then earn_points_per_dollar else p_earn_points_per_dollar end,
             stamp_per_cents        = case when p_stamp_per_cents is null then stamp_per_cents else p_stamp_per_cents end,
             expiry_mode            = case when v_mode is null then expiry_mode else v_mode end,
             expiry_days            = case when v_mode is null then expiry_days else v_days end,
             stamp_validity_days    = case when not v_validity_provided then stamp_validity_days else v_validity end,
             stamp_reward_expiry_days = case when not v_reward_expiry_provided then stamp_reward_expiry_days else v_reward_expiry end
       where config_version_id = v_target and business_id = p_business;
      perform set_config('app.v433_program_edit_version_id', '', true);
    end if;

    if v_split then
      v_commit := app.stamp_config_edit_commit_v433(p_business, v_target);
    end if;
  end if;

  select * into v_row from public.loyalty_programs where business_id = p_business;

  insert into public.audit_log(business_id, actor, action, entity, entity_id, detail)
  values (p_business, auth.uid(), 'earning_rule.updated', 'loyalty_programs', p_business,
    jsonb_build_object('earn_points_per_dollar', v_row.earn_points_per_dollar,
                       'stamp_per_cents', v_row.stamp_per_cents,
                       'expiry_mode', v_row.expiry_mode, 'expiry_days', v_row.expiry_days,
                       'stamp_validity_days', v_row.stamp_validity_days,
                       'stamp_reward_expiry_days', v_row.stamp_reward_expiry_days,
                       'version_split', v_split, 'target_version_id', v_target,
                       'publish_status', v_commit->>'publish_status'));

  return jsonb_build_object('status','ok',
    'earn_points_per_dollar', v_row.earn_points_per_dollar,
    'stamp_per_cents', v_row.stamp_per_cents,
    'expiry_mode', v_row.expiry_mode, 'expiry_days', v_row.expiry_days,
    'stamp_validity_days', v_row.stamp_validity_days,
    'stamp_reward_expiry_days', v_row.stamp_reward_expiry_days,
    'version_split', v_split, 'target_version_id', v_target)
    || v_commit;
end
$function$;

create or replace function public.create_loyalty_config_draft(p_business uuid, p_based_on uuid default null::uuid, p_source text default 'manual'::text)
 returns json
 language plpgsql
 security definer
 set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $function$
declare
  v_actor uuid:=auth.uid();
  v_base uuid;
  v_id uuid;
  v_no integer;
  v_typed public.loyalty_program_versions%rowtype;
begin
  if not app.c45_owner_loyalty_write(p_business) then
    raise exception 'owner loyalty configuration access required' using errcode='42501';
  end if;
  perform 1 from public.businesses where id=p_business for update;
  v_base:=coalesce(
    p_based_on,
    app.active_config_version(p_business),
    (select current_config_version_id from public.loyalty_programs where business_id=p_business)
  );
  select * into v_typed from public.loyalty_program_versions
  where config_version_id=v_base and business_id=p_business;
  if not found then raise exception 'base configuration not found'; end if;
  select coalesce(max(version_no),0)+1 into v_no
  from public.firm_config_versions where business_id=p_business;
  v_id:=gen_random_uuid();
  insert into public.firm_config_versions(
    id,business_id,version_no,status,based_on_version_id,source,snapshot_hash,created_by
  ) values(
    v_id,p_business,v_no,'draft',v_base,
    coalesce(nullif(btrim(p_source),''),'manual'),
    md5((to_jsonb(v_typed)-'config_version_id')::text),v_actor
  );
  insert into public.loyalty_program_versions(
    config_version_id,business_id,kind,loyalty_model,active,
    earn_points_per_dollar,redeem_points,reward_credit_cents,stamp_target,
    stamp_per_cents,tier_basis,expiry_mode,expiry_days,stamp_validity_days,
    stamp_reward_expiry_days
  )
  select v_id,business_id,kind,loyalty_model,active,
    earn_points_per_dollar,redeem_points,reward_credit_cents,stamp_target,
    stamp_per_cents,tier_basis,expiry_mode,expiry_days,stamp_validity_days,
    stamp_reward_expiry_days
  from public.loyalty_program_versions where config_version_id=v_base;
  insert into public.loyalty_tier_versions(
    tier_id,config_version_id,business_id,name,threshold,points_multiplier,
    perk_note,sort,active,effective_from,expires_at
  )
  select tier_id,v_id,business_id,name,threshold,points_multiplier,
    perk_note,sort,active,effective_from,expires_at
  from public.loyalty_tier_versions where config_version_id=v_base;
  perform app.refresh_loyalty_config_snapshot(v_id);
  return json_build_object('version_id',v_id,'version_no',v_no,'status','draft');
end
$function$;

create or replace function public.publish_loyalty_config(p_version uuid)
 returns json
 language plpgsql
 security definer
 set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $function$
declare v_header public.firm_config_versions%rowtype; v_typed public.loyalty_program_versions%rowtype; v_prior uuid;
  v_rule public.program_rules%rowtype; v_rule_errs text[]; v_active_rule_count integer;
  v_tier_carry_ids uuid[]; v_tier_carry_paused boolean[]; v_tier_carry_deleted timestamptz[];
  v_spine_stamps boolean; v_spine_points boolean; -- nestly_v431
begin
  select * into v_header from public.firm_config_versions where id=p_version for update;
  if not found or not app.c45_owner_loyalty_write(v_header.business_id) then raise exception 'owner loyalty configuration access required' using errcode='42501'; end if;
  if v_header.status<>'draft' then raise exception 'only a draft may be published'; end if;
  perform 1 from public.businesses where id=v_header.business_id for update;
  select * into v_typed from public.loyalty_program_versions where config_version_id=p_version;
  -- nestly_v434: guards keyed on the DRAFT's declared model, never on the outgoing spine.
  if v_typed.loyalty_model = 'stamps' and coalesce(v_typed.stamp_per_cents,0)<=0 then raise exception 'active stamps configuration requires spend per stamp' using errcode='23514'; end if;
  if v_typed.loyalty_model = 'stamps' then
    if coalesce(v_typed.stamp_target,0)<=0 then
      raise exception 'a live stamp card needs a number of stamps' using errcode='23514';
    end if;
    if exists(select 1 from public.loyalty_reward_versions rv join public.business_programmes spine on spine.id=rv.programme_id
               where rv.config_version_id=p_version and rv.business_id=v_header.business_id and rv.active and spine.kind='stamps' and rv.cost_points>v_typed.stamp_target) then
      raise exception 'a stamp gift sits past the last stamp on the card' using errcode='23514';
    end if;
    if not exists(select 1 from public.loyalty_reward_versions rv join public.business_programmes spine on spine.id=rv.programme_id
                   where rv.config_version_id=p_version and rv.business_id=v_header.business_id and rv.active and spine.kind='stamps' and rv.cost_points=v_typed.stamp_target) then
      raise exception 'a live stamp card needs a gift at the last stamp' using errcode='23514';
    end if;
  end if;
  if exists(select 1 from public.retention_program_versions rv left join public.firm_reward_taxonomy t on t.id=rv.reward_taxonomy_id and t.business_id=rv.business_id where rv.config_version_id=p_version and rv.business_id=v_header.business_id and rv.active and coalesce(t.active,false)=false) then
    raise exception 'active retention programs cannot publish a retired taxonomy' using errcode='23514';
  end if;
  if exists(select 1 from public.birthday_program_versions bp where bp.config_version_id=p_version and bp.business_id=v_header.business_id and bp.active and bp.window_days_before+bp.window_days_after+1>365) then
    raise exception 'birthday benefit windows may not overlap annually' using errcode='23514';
  end if;
  for v_rule in select * from public.program_rules where config_version_id=p_version and business_id=v_header.business_id loop
    v_rule_errs := app.program_rule_errors(v_header.business_id, jsonb_build_object(
      'schema_version',v_rule.schema_version,'when_event',v_rule.when_event,'if_conditions',v_rule.if_conditions,
      'then_effects',v_rule.then_effects,'with_params',v_rule.with_params,'during_schedule',v_rule.during_schedule,'using_stacking',v_rule.using_stacking));
    if coalesce(array_length(v_rule_errs,1),0)>0 then
      raise exception 'cannot publish: program rule % is invalid (%)', v_rule.name, array_to_string(v_rule_errs,', ') using errcode='23514';
    end if;
  end loop;
  select count(*) into v_active_rule_count from public.program_rules where config_version_id=p_version and business_id=v_header.business_id and active;
  if v_active_rule_count>200 then
    raise exception 'cannot publish: too many active program rules (%)', v_active_rule_count using errcode='23514';
  end if;
  perform app.refresh_loyalty_config_snapshot(p_version);
  select * into v_header from public.firm_config_versions where id=p_version;
  select active_config_version_id into v_prior from public.businesses where id=v_header.business_id;
  update public.firm_config_versions set status='superseded',superseded_at=now() where id=v_prior and status='published';
  update public.firm_config_versions set status='published',published_at=now() where id=p_version;
  update public.businesses set active_config_version_id=p_version where id=v_header.business_id;
  update public.loyalty_programs set kind=v_typed.kind,loyalty_model=v_typed.loyalty_model,active=v_typed.active,earn_points_per_dollar=v_typed.earn_points_per_dollar,redeem_points=v_typed.redeem_points,reward_credit_cents=v_typed.reward_credit_cents,stamp_target=v_typed.stamp_target,stamp_per_cents=v_typed.stamp_per_cents,stamp_validity_days=v_typed.stamp_validity_days,stamp_reward_expiry_days=v_typed.stamp_reward_expiry_days,tier_basis=v_typed.tier_basis,expiry_mode=v_typed.expiry_mode,expiry_days=v_typed.expiry_days,configuration_status='published',current_config_version_id=p_version where business_id=v_header.business_id;
  -- nestly_v431: THE PUBLISH CANNOT OVERWRITE THE DECLARED MODEL AGAINST THE SPINE. (Full
  -- rationale in 20260822_nestly_v431_publish_keeps_the_spine_model.sql.)
  select coalesce(bool_or(spine.active) filter (where spine.kind='stamps'),false),
         coalesce(bool_or(spine.active) filter (where spine.kind='points'),false)
    into v_spine_stamps, v_spine_points
    from public.business_programmes spine
   where spine.business_id=v_header.business_id;
  if v_spine_stamps then
    update public.loyalty_programs
       set loyalty_model='stamps', kind='stamps'
     where business_id=v_header.business_id
       and (loyalty_model is distinct from 'stamps' or kind is distinct from 'stamps');
  elsif v_spine_points then
    update public.loyalty_programs
       set loyalty_model=case when loyalty_model in ('classic','points_tiers') then loyalty_model else 'classic' end,
           kind='points'
     where business_id=v_header.business_id
       and (kind is distinct from 'points' or loyalty_model not in ('classic','points_tiers'));
  end if;
  if found and (v_spine_stamps or v_spine_points) then
    insert into public.audit_log(business_id,actor,action,entity,entity_id,detail)
    values (v_header.business_id, auth.uid(), 'loyalty_model.synced_to_spine', 'loyalty_programs', v_header.business_id,
            jsonb_build_object('source','publish_loyalty_config','spine_stamps',v_spine_stamps,'spine_points',v_spine_points,'config_version_id',p_version));
  end if;
  update public.loyalty_rewards r set programme_id=rv.programme_id,name=rv.customer_name,internal_name=rv.internal_name,customer_name=rv.customer_name,description=rv.description,fulfillment_kind=rv.fulfillment_kind,taxonomy_label=rv.taxonomy_label,cost_points=rv.cost_points,credit_cents=rv.credit_cents,estimated_cost_cents=rv.estimated_cost_cents,active=rv.active,sort=rv.sort,claim_available_from=rv.claim_available_from,claim_available_until=rv.claim_available_until,entitlement_expiry_days=rv.entitlement_expiry_days,instructions=rv.instructions,terms=rv.terms,image_ref=rv.image_ref,usage_limit=rv.usage_limit,min_tier_id=rv.min_tier_id,min_tier_threshold=rv.min_tier_threshold,current_config_version_id=p_version from public.loyalty_reward_versions rv where rv.reward_id=r.id and rv.business_id=r.business_id and rv.config_version_id=p_version;
  select array_agg(id), array_agg(paused), array_agg(deleted_at)
    into v_tier_carry_ids, v_tier_carry_paused, v_tier_carry_deleted
    from public.loyalty_tiers
   where business_id=v_header.business_id and (paused or deleted_at is not null);
  delete from public.loyalty_tiers where business_id=v_header.business_id;
  insert into public.loyalty_tiers(id,business_id,name,threshold,points_multiplier,perk_note,sort,effective_from,expires_at) select tier_id,business_id,name,threshold,points_multiplier,perk_note,sort,effective_from,expires_at from public.loyalty_tier_versions where config_version_id=p_version and business_id=v_header.business_id and active;
  if v_tier_carry_ids is not null then
    update public.loyalty_tiers t set paused=c.paused,deleted_at=c.deleted_at
      from (select unnest(v_tier_carry_ids) as id, unnest(v_tier_carry_paused) as paused, unnest(v_tier_carry_deleted) as deleted_at) c
     where c.id=t.id and t.business_id=v_header.business_id;
  end if;
  update public.retention_programs rp set name=rv.name,active=(rv.active and rp.deleted_at is null),goal_visits=rv.goal_visits,period_days=rv.period_days,starts_on=rv.starts_on,reward_taxonomy_id=rv.reward_taxonomy_id,reward_type=rv.fulfillment_kind,reward_value=coalesce(rv.discount_percent,rv.credit_cents,0),reward_item=rv.manual_item,current_config_version_id=p_version from public.retention_program_versions rv where rv.program_id=rp.id and rv.business_id=rp.business_id and rv.config_version_id=p_version and rp.business_id=v_header.business_id;
  perform app.compile_program_rules(p_version);
  insert into public.audit_log(business_id,actor,action,entity,entity_id,detail)
  values(v_header.business_id,auth.uid(),'PUBLISH_CONFIG','firm_config_versions',p_version,jsonb_build_object('prior_version_id',v_prior,'new_version_id',p_version,'snapshot_hash',v_header.snapshot_hash,'birthday_program_count',(select count(*) from public.birthday_program_versions where config_version_id=p_version),'program_rule_count',(select count(*) from public.program_rules where config_version_id=p_version)));
  return json_build_object('version_id',p_version,'version_no',v_header.version_no,'status','published');
end $function$;

-- ============================================================================================
-- §9  ACLS — restated for every function this migration issues or re-issues (preflight rule)
-- ============================================================================================
revoke all on function app.stamp_cycle_window_v464(uuid, uuid, uuid) from public, anon, authenticated;
revoke all on function app.stamp_reward_earned_at_v464(uuid, uuid, uuid, timestamptz, timestamptz, integer) from public, anon, authenticated;
revoke all on function app.stamp_reward_expiry_v464(uuid, uuid, uuid, integer, integer) from public, anon, authenticated;
revoke all on function app.stamp_reward_expire_due_v464(uuid, uuid, uuid) from public, anon, authenticated;
revoke all on function app.run_stamp_reward_expiry_for_business(uuid) from public, anon, authenticated;
revoke all on function app.run_stamp_reward_expiry() from public, anon, authenticated;
revoke all on function app.reward_availability_v432(uuid, uuid, timestamptz) from public, anon, authenticated;
revoke all on function app.redeem_reward_core(uuid, uuid, uuid, text, uuid, uuid, uuid) from public, anon, authenticated;

revoke all on function public.customer_get_reward_catalog(text) from public, anon;
grant execute on function public.customer_get_reward_catalog(text) to authenticated, service_role;

revoke all on function public.customer_get_stamp_card_v323(text) from public, anon;
grant execute on function public.customer_get_stamp_card_v323(text) to authenticated, service_role;

revoke all on function public.customer_get_reward_history_v422(text, integer) from public, anon;
grant execute on function public.customer_get_reward_history_v422(text, integer) to authenticated, service_role;

revoke all on function public.staff_get_customer_actionable_loyalty_v145(uuid, uuid, uuid) from public, anon;
grant execute on function public.staff_get_customer_actionable_loyalty_v145(uuid, uuid, uuid) to authenticated, service_role;

revoke all on function public.create_loyalty_config_draft(uuid, uuid, text) from public, anon;
grant execute on function public.create_loyalty_config_draft(uuid, uuid, text) to authenticated, service_role;

revoke all on function public.publish_loyalty_config(uuid) from public, anon;
grant execute on function public.publish_loyalty_config(uuid) to authenticated, service_role;

revoke all on function public.business_set_earning_rule_v359(uuid, numeric, integer, text, integer, integer, integer) from public, anon;
grant execute on function public.business_set_earning_rule_v359(uuid, numeric, integer, text, integer, integer, integer) to authenticated, service_role;

commit;
