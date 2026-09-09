-- nestly_v876 — a stamp card that opens with carried-over stamps keeps its clock and its version.
--
-- WHAT WAS LIVE, AND WHY IT IS WRONG. When a card completes with stamps to spare, the surplus
-- rolls onto the next card (v496). Both card authorities decide when that next card STARTED by
-- finding the earliest positive ledger row written after the previous card closed:
--   app.stamp_cycle_version_v416 -> which published config the card is pinned to;
--   app.stamp_cycle_deadline_v435 -> started_at, and expires_at = started_at + validity.
-- A card that opens purely from carried stamps has no positive ledger row after the close —
-- the stamps arrived before it — so started_at was NULL. Two consequences: the card never
-- expires (no deadline), and v416 falls through to "nothing collected yet, so the newest setup
-- applies" and re-pins the card to whatever config is live NOW, defeating the per-cycle pin.
-- The customer's card silently changed its rules and lost its clock at the exact moment it
-- rolled over. A separate latent fault in v435: its progress lookup took `limit 1` over
-- app.stamp_progress_v323 with no programme filter, so a tenant holding a paused second stamp
-- programme could read the wrong card's filled/cycle_index.
--
-- THE FIX. If no positive row has landed since the last close but the card already holds stamps,
-- the card started when the previous one closed: started_at := last close. v416 pins the
-- version published at that instant, exactly as it does for a card started by a new stamp.
-- "Holds stamps" is computed directly in v416 — ledger net minus closed slots for this customer
-- and programme, the same arithmetic app.stamp_progress_v323 uses — because v323 itself calls
-- v416 to pin the card, so v416 must never call v323 (the first draft did, and the rolled-back
-- dry run against production recursed to the stack limit). v435 keeps reading v323 (it is not
-- on v323's call path) but its progress lookup is now filtered to the programme asked about.
-- A card with nothing on it at all still behaves as before — no promise has been made yet, so
-- the newest setup applies.

begin;

create or replace function app.stamp_cycle_version_v416(p_business uuid, p_client uuid, p_programme uuid)
returns uuid
language plpgsql
stable security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $function$
declare
  v_last_close timestamptz;
  v_started timestamptz;
  v_version uuid;
  v_carried integer;
begin
  if p_business is null or p_client is null or p_programme is null then
    return (select b.active_config_version_id from public.businesses b where b.id = p_business);
  end if;

  select max(sc.closed_at) into v_last_close
    from public.stamp_cycles sc
   where sc.business_id = p_business and sc.client_id = p_client
     and sc.programme_id = p_programme;

  /* The first stamp of the CURRENT card: the earliest positive ledger row for this programme
     since the last card closed. Only positive rows count — a correction that removes stamps must
     not be mistaken for the moment a card was started. nestly_v435: >= not > (see §2 header). */
  select min(pl.created_at) into v_started
    from public.points_ledger pl
   where pl.business_id = p_business and pl.client_id = p_client
     and pl.programme_id = p_programme and pl.points > 0
     and (v_last_close is null or pl.created_at >= v_last_close);

  /* nestly_v876: a card opened by carried-over stamps has no positive row after the close, but
     it is not empty. It started when the previous card closed, and is pinned to the config
     published at that instant — the same rule as a card started by a fresh stamp. The card's
     content is ledger net minus closed slots (app.stamp_progress_v323's model, computed here
     directly: v323 calls THIS function to pin the card, so this function must not call v323). */
  if v_started is null and v_last_close is not null then
    select greatest(
             coalesce((select sum(pl.points) from public.points_ledger pl
                        where pl.business_id = p_business and pl.client_id = p_client
                          and pl.programme_id = p_programme), 0)
           - coalesce((select sum(sc.slots) from public.stamp_cycles sc
                        where sc.business_id = p_business and sc.client_id = p_client
                          and sc.programme_id = p_programme), 0),
             0)::integer
      into v_carried;
    if coalesce(v_carried, 0) > 0 then
      v_started := v_last_close;
    end if;
  end if;

  if v_started is null then
    -- Nothing collected on this card yet: no promise has been made, so the newest setup applies.
    return (select b.active_config_version_id from public.businesses b where b.id = p_business);
  end if;

  select fcv.id into v_version
    from public.firm_config_versions fcv
   where fcv.business_id = p_business
     and fcv.published_at is not null
     and fcv.published_at <= v_started
   order by fcv.published_at desc
   limit 1;

  /* A card started before this firm ever published one falls back to the active version rather
     than to nothing — a customer must never be left with no card at all. */
  return coalesce(v_version,
    (select b.active_config_version_id from public.businesses b where b.id = p_business));
end $function$;

create or replace function app.stamp_cycle_deadline_v435(p_business uuid, p_client uuid, p_programme uuid)
returns table(started_at timestamp with time zone, validity_days integer, expires_at timestamp with time zone, config_version_id uuid, filled integer, cycle_index integer)
language sql
stable security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $function$
  with closed as (
    select max(sc.closed_at) as last_close
      from public.stamp_cycles sc
     where sc.business_id = p_business and sc.client_id = p_client and sc.programme_id = p_programme
  ), progress as (
    -- nestly_v876: THIS programme's card, not whichever row limit 1 happened to return.
    select sp.filled, sp.cycle_index
      from app.stamp_progress_v323(p_business, p_client) sp
     where sp.programme_id = p_programme
     limit 1
  ), started as (
    -- nestly_v876: the earliest positive row since the last close, else — when the card already
    -- holds carried-over stamps — the close itself. Same rule as app.stamp_cycle_version_v416.
    select coalesce(
             (select min(pl.created_at)
                from public.points_ledger pl, closed
               where pl.business_id = p_business and pl.client_id = p_client
                 and pl.programme_id = p_programme and pl.points > 0
                 and pl.created_at >= coalesce(closed.last_close, '-infinity'::timestamptz)),
             case when coalesce((select filled from progress), 0) > 0
                  then (select last_close from closed) end
           ) as at
  ), pinned as (
    select app.stamp_cycle_version_v416(p_business, p_client, p_programme) as cfg
  )
  select started.at,
         lpv.stamp_validity_days,
         case when started.at is not null and lpv.stamp_validity_days is not null
              then started.at + make_interval(days => lpv.stamp_validity_days) end,
         pinned.cfg,
         coalesce(progress.filled, 0),
         coalesce(progress.cycle_index, 0)
    from started
    cross join pinned
    left join public.loyalty_program_versions lpv
      on lpv.config_version_id = pinned.cfg and lpv.business_id = p_business
    left join progress on true
$function$;

-- ACLs restated verbatim from prod (nestly_v876): both are owner-only internals.
revoke all on function app.stamp_cycle_version_v416(uuid,uuid,uuid) from public;
revoke all on function app.stamp_cycle_deadline_v435(uuid,uuid,uuid) from public;

do $verify$
begin
  if position('v_started := v_last_close' in pg_get_functiondef('app.stamp_cycle_version_v416(uuid,uuid,uuid)'::regprocedure)) = 0 then
    raise exception 'nestly_v876: stamp_cycle_version_v416 has no carried-card fallback' using errcode = 'XX001';
  end if;
  if position('from app.stamp_progress_v323(' in pg_get_functiondef('app.stamp_cycle_version_v416(uuid,uuid,uuid)'::regprocedure)) > 0 then
    raise exception 'nestly_v876: stamp_cycle_version_v416 must not call stamp_progress_v323 (v323 calls v416)' using errcode = 'XX001';
  end if;
  if position('where sp.programme_id = p_programme' in pg_get_functiondef('app.stamp_cycle_deadline_v435(uuid,uuid,uuid)'::regprocedure)) = 0 then
    raise exception 'nestly_v876: stamp_cycle_deadline_v435 progress lookup is not programme-scoped' using errcode = 'XX001';
  end if;
end
$verify$;

commit;
