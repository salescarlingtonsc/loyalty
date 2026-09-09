-- nestly_v871 — a points-to-stamps conversion can be reversed at its recorded rate, a parked
--               pot is visible to the customer, and the wallet promises only what the counter honours.
--
-- OWNER, 2026-09-09: the 75,800-point / 758-stamp movement on Cubbly SPA "was not using points to
-- buy stamps — it was a switch program by the boss from points to stamps and it was converted."
--
-- WHAT WAS LIVE, AND WHY IT IS WRONG. Three things on one card.
--
--   1. business_switch_to_stamps_v384 converts a customer's points into stamps at the owner's
--      chosen rate and records the conversion (public.programme_stamp_conversions_v384). There
--      is no inverse. When the owner later switched back to points, set_programmes_v314 parked
--      the stamps pot untouched (V355, deliberate) — but the balance readers show only the live
--      pot (app.live_balance_programme_v381), so the converted stamps vanished from every
--      screen: Cubbly SPA customer 268cb96d saw 76,950 points become 1,150, and 801 stamps
--      (758 converted + 43 earned while stamps was live) appear nowhere. The only escape hatch,
--      app.migrate_programme_pot_v312, moves units 1:1 — it would return 758 POINTS for 75,800
--      spent, a 100x haircut. Estate-wide 1,314 units are parked across 4 tenants.
--
--   2. The parked pot is invisible. V355 says a switched-off programme's balance must not be
--      converted on a plain toggle; it does not say the customer should be unable to SEE it.
--
--   3. app.c45_base_actionable_wallet_card judged a reward "available now" as
--      `loyalty.balance >= rv.cost_points` — the LIFETIME stamp pot — while the counter judges
--      readiness on the OPEN card (app.customer_ready_reward_count_v465, the one availability
--      core, v432). A stamps customer whose current card is empty was told "reward is ready at
--      the counter": 4 of 11 non-synthetic customers across the two stamps tenants. The same
--      candidate also ignored app.reward_live_on_offer_v805, naming a gift the owner had
--      switched OFF as the next reward.
--
-- THE FIX.
--
--   A. public.business_switch_to_points_v871(p_business, p_idempotency_key): the inverse of
--      v384, at the RECORDED points_per_stamp of the tenant's latest conversion. Per customer it
--      returns only what the conversion issued and the customer still holds
--      (least(issued, current stamps)) — stamps since spent stay spent, stamps since earned
--      stay stamps — writing the same ledger pair shape v384 wrote (guarded insert ids, the
--      'programme_pot_transfer' write scope), moving batches FEFO, recording the reversal in
--      public.programme_stamp_reversals_v871 for idempotent replay, then switching the spine
--      back to points through set_programmes_v314 exactly as v384 switched it away. Pre- and
--      post-state conservation is asserted as in v384.
--
--   B. The wallet card reports 'parked_programmes': every non-live points/stamps pot the customer
--      holds units in, with its unit and paused_since. Read-only; nothing moves.
--
--   C. The wallet card's 'available_now' and the action band read the canonical readiness core
--      already computed in the same function (ready.payload), the stamps candidate measures
--      "remaining" against the open card (app.stamp_progress_v323), and a reward that is not
--      live on offer (app.reward_live_on_offer_v805) is never the next reward.
--
-- The wallet card is 333 lines and everything else in it is right, so C is applied by the
-- extract-and-diff method (v416): each fragment must be present exactly once or the migration
-- aborts.

begin;

-- ---------------------------------------------------------------------------------------------
-- A. the reverse conversion
-- ---------------------------------------------------------------------------------------------
create table if not exists public.programme_stamp_reversals_v871 (
  id                   uuid primary key default gen_random_uuid(),
  business_id          uuid not null references public.businesses(id),
  idempotency_key      uuid not null,
  -- programme_stamp_conversions_v384 is keyed (business_id, idempotency_key); it has no surrogate id.
  conversion_key       uuid not null,
  points_programme_id  uuid not null,
  stamps_programme_id  uuid not null,
  points_per_stamp     integer not null check (points_per_stamp > 0),
  restored_customers   integer not null default 0,
  returned_stamps      integer not null default 0,
  restored_points      integer not null default 0,
  response             jsonb not null,
  created_at           timestamptz not null default now(),
  unique (business_id, idempotency_key),
  foreign key (business_id, conversion_key)
    references public.programme_stamp_conversions_v384(business_id, idempotency_key)
);
alter table public.programme_stamp_reversals_v871 enable row level security;
-- Owner-side read only; every write goes through the RPC below (SECURITY DEFINER).
drop policy if exists programme_stamp_reversals_v871_owner_read on public.programme_stamp_reversals_v871;
create policy programme_stamp_reversals_v871_owner_read on public.programme_stamp_reversals_v871
  for select to authenticated
  using (app.c45_owner_loyalty_write(business_id) or app.is_super_admin());
revoke all on table public.programme_stamp_reversals_v871 from public, anon;
grant select on table public.programme_stamp_reversals_v871 to authenticated, service_role;

create or replace function public.business_switch_to_points_v871(p_business uuid, p_idempotency_key uuid)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $function$
declare
  v_conv public.programme_stamp_conversions_v384%rowtype;
  v_existing jsonb;
  v_tiers boolean;
  v_switch jsonb;
  v_row record;
  v_batch record;
  v_left integer;
  v_take integer;
  v_customers integer := 0;
  v_stamps integer := 0;
  v_points integer := 0;
  v_response jsonb;
  v_return_ledger_id uuid;
  v_restore_ledger_id uuid;
begin
  perform app.acquire_loyalty_exclusive_v480(p_business);
  if not (select conversions_enabled from app.loyalty_integrity_control_v480 where singleton) then
    raise exception 'loyalty conversion is temporarily disabled' using errcode = '55000';
  end if;
  if p_idempotency_key is null then
    raise exception 'idempotency key is required' using errcode = '22023';
  end if;
  if not app.c45_owner_loyalty_write(p_business) then
    raise exception 'not allowed' using errcode = '42501';
  end if;

  perform pg_advisory_xact_lock(hashtextextended('v384:stamp-switch:'||p_business::text, 0));

  select response into v_existing
    from public.programme_stamp_reversals_v871
   where business_id = p_business and idempotency_key = p_idempotency_key;
  if found then
    return v_existing;
  end if;

  -- The conversion being reversed: the tenant's latest recorded one. Its rate is the only
  -- lawful rate to restore at — the 1:1 pot transfer would return 758 points for 75,800 spent.
  select * into v_conv
    from public.programme_stamp_conversions_v384
   where business_id = p_business
   order by created_at desc, idempotency_key desc
   limit 1;
  if not found then
    raise exception 'no recorded points-to-stamps conversion to reverse for this business'
      using errcode = '22023';
  end if;
  if exists (select 1 from public.programme_stamp_reversals_v871 r
              where r.business_id = p_business and r.conversion_key = v_conv.idempotency_key) then
    raise exception 'this conversion has already been reversed' using errcode = '23505';
  end if;

  -- Pre-state conservation, as v384 asserts before it moves anything.
  if exists (
    select 1 from
      (select client_id,programme_id,sum(points)::integer total from public.points_ledger
        where business_id=p_business and programme_id in (v_conv.points_programme_id, v_conv.stamps_programme_id)
        group by client_id,programme_id) l
      full join
      (select client_id,programme_id,sum(remaining)::integer total from public.points_batches
        where business_id=p_business and programme_id in (v_conv.points_programme_id, v_conv.stamps_programme_id)
        group by client_id,programme_id) b
      using(client_id,programme_id)
     where coalesce(l.total,0)<>coalesce(b.total,0)
  ) then raise exception 'stamp reversal pre-state is not conserved' using errcode='XX001'; end if;

  for v_row in
    with issued as (
      -- what THIS conversion gave each customer: the ledger rows v384 wrote into the stamps pot.
      select pl.client_id, sum(pl.points)::integer as stamps_issued
        from public.points_ledger pl
       where pl.business_id = p_business
         and pl.programme_id = v_conv.stamps_programme_id
         and pl.entry_type = 'adjust'
         and pl.reference = 'stamp conversion: stamps issued'
         and pl.created_at >= v_conv.created_at - interval '1 minute'
       group by pl.client_id
    ), held as (
      select pl.client_id, greatest(sum(pl.points), 0)::integer as stamps_held
        from public.points_ledger pl
       where pl.business_id = p_business and pl.programme_id = v_conv.stamps_programme_id
       group by pl.client_id
    )
    select i.client_id,
           least(i.stamps_issued, coalesce(h.stamps_held, 0))::integer as stamps_to_return
      from issued i
      left join held h on h.client_id = i.client_id
     where least(i.stamps_issued, coalesce(h.stamps_held, 0)) > 0
     order by i.client_id
  loop
    -- Take the returned stamps out of the stamps batches, oldest first (v384's FEFO order).
    v_left := v_row.stamps_to_return;
    for v_batch in
      select id, remaining
        from public.points_batches
       where business_id = p_business
         and client_id = v_row.client_id
         and programme_id = v_conv.stamps_programme_id
         and remaining > 0
       order by expires_at nulls last, earned_at, id
         for update
    loop
      exit when v_left = 0;
      v_take := least(v_batch.remaining, v_left);
      update public.points_batches set remaining = remaining - v_take where id = v_batch.id;
      v_left := v_left - v_take;
    end loop;
    if v_left <> 0 then
      raise exception 'could not prove stamp batch reversal for customer %', v_row.client_id
        using errcode = '23514';
    end if;

    -- The same guarded ledger handshake v384 uses (v403): publish each id before its insert.
    v_return_ledger_id := gen_random_uuid();
    perform set_config('app.points_ledger_insert_id', v_return_ledger_id::text, true);
    perform set_config('app.points_ledger_write_scope', 'programme_pot_transfer', true);
    insert into public.points_ledger(id,business_id,client_id,entry_type,points,sale_id,reference,actor,programme_id)
    values (v_return_ledger_id, p_business, v_row.client_id, 'adjust', -v_row.stamps_to_return,
            null, 'stamp reversal: stamps returned', null, v_conv.stamps_programme_id);
    v_restore_ledger_id := gen_random_uuid();
    perform set_config('app.points_ledger_insert_id', v_restore_ledger_id::text, true);
    insert into public.points_ledger(id,business_id,client_id,entry_type,points,sale_id,reference,actor,programme_id)
    values (v_restore_ledger_id, p_business, v_row.client_id, 'adjust', v_row.stamps_to_return * v_conv.points_per_stamp,
            null, 'stamp reversal: points restored', null, v_conv.points_programme_id);
    perform set_config('app.points_ledger_insert_id', '', true);
    perform set_config('app.points_ledger_write_scope', '', true);

    insert into public.points_batches(business_id,client_id,earned,remaining,sale_id,earned_at,expires_at,programme_id)
    values (p_business, v_row.client_id,
            v_row.stamps_to_return * v_conv.points_per_stamp, v_row.stamps_to_return * v_conv.points_per_stamp,
            null, statement_timestamp(), null, v_conv.points_programme_id);

    v_customers := v_customers + 1;
    v_stamps := v_stamps + v_row.stamps_to_return;
    v_points := v_points + v_row.stamps_to_return * v_conv.points_per_stamp;
  end loop;

  -- Post-state conservation.
  if exists (
    select 1 from
      (select client_id,programme_id,sum(points)::integer total from public.points_ledger
        where business_id=p_business and programme_id in (v_conv.points_programme_id, v_conv.stamps_programme_id)
        group by client_id,programme_id) l
      full join
      (select client_id,programme_id,sum(remaining)::integer total from public.points_batches
        where business_id=p_business and programme_id in (v_conv.points_programme_id, v_conv.stamps_programme_id)
        group by client_id,programme_id) b
      using(client_id,programme_id)
     where coalesce(l.total,0)<>coalesce(b.total,0)
  ) then raise exception 'stamp reversal post-state is not conserved' using errcode='XX001'; end if;

  -- Switch the spine back the way v384 switched it away. Tiers keep whatever they are today.
  select coalesce(bool_or(bp.active), false) into v_tiers
    from public.business_programmes bp
   where bp.business_id = p_business and bp.kind = 'tiers';
  v_switch := public.set_programmes_v314(
    p_business,
    jsonb_build_object('points', true, 'stamps', false, 'tiers', v_tiers),
    p_idempotency_key);

  v_response := jsonb_build_object(
    'ok', true,
    'reversed_conversion_key', v_conv.idempotency_key,
    'points_per_stamp', v_conv.points_per_stamp,
    'customers', v_customers,
    'stamps_returned', v_stamps,
    'points_restored', v_points,
    'programmes', v_switch->'programmes');

  insert into public.programme_stamp_reversals_v871(
    business_id, idempotency_key, conversion_key, points_programme_id, stamps_programme_id,
    points_per_stamp, restored_customers, returned_stamps, restored_points, response)
  values (p_business, p_idempotency_key, v_conv.idempotency_key, v_conv.points_programme_id, v_conv.stamps_programme_id,
          v_conv.points_per_stamp, v_customers, v_stamps, v_points, v_response);

  return v_response;
exception when others then
  perform set_config('app.points_ledger_insert_id', '', true);
  perform set_config('app.points_ledger_write_scope', '', true);
  raise;
end;
$function$;

-- Same ACL as its inverse, public.business_switch_to_stamps_v384 (restated verbatim from prod).
revoke all on function public.business_switch_to_points_v871(uuid,uuid) from public, anon;
grant execute on function public.business_switch_to_points_v871(uuid,uuid) to authenticated, service_role;

-- ---------------------------------------------------------------------------------------------
-- B + C. the wallet card: parked pots visible; readiness from the one availability core
-- ---------------------------------------------------------------------------------------------
do $patch$
declare
  v_sig constant regprocedure :=
    'app.c45_base_actionable_wallet_card(uuid,uuid,text,text,text,text,text[],timestamptz)'::regprocedure;
  v_src text := pg_get_functiondef(v_sig);
  v_pair record;
  v_hits integer;
begin
  for v_pair in
    select * from (values
      -- C1. the stamps candidate measures "remaining" against the OPEN card, not the lifetime pot,
      --     and a new CTE reads that card once. Inserted just before reward_candidate.
      (E'  ), reward_candidate as (\n    select\n      rv.customer_name as name,\n      rv.cost_points::integer as cost_units,\n      greatest(rv.cost_points - loyalty.balance, 0)::integer as remaining_units,\n      loyalty.balance >= rv.cost_points as available_now',
       E'  ), open_card as (\n    -- nestly_v871: the customer''s current stamp card (the one availability model, v323/v432).\n    select coalesce(sp.filled, 0)::integer as filled\n      from app.stamp_progress_v323(p_business_id, p_client_id) sp, pot\n     where sp.programme_id = pot.live\n     limit 1\n  ), reward_candidate as (\n    select\n      rv.customer_name as name,\n      rv.cost_points::integer as cost_units,\n      greatest(rv.cost_points - case when loyalty.unit = ''stamps''\n                                     then coalesce((select filled from open_card), 0)\n                                     else loyalty.balance end, 0)::integer as remaining_units,\n      loyalty.balance >= rv.cost_points as available_now',
       'C1 open-card remaining'),
      -- C2. a reward that is not live on offer is never the next reward. The anchor is the
      --     `live_reward.paused` line ALONE: production's body (applied through the MCP, which
      --     strips comments) runs straight on to `or exists (`, while the repo-built body the
      --     scratch harness replays keeps V372's comment block in between. One line matches both.
      (E'              live_reward.paused\n',
       E'              live_reward.paused\n              /* nestly_v871 */\n              or not app.reward_live_on_offer_v805(live_reward.active, live_reward.withdrawn_at,\n                     exists (select 1 from public.business_programmes ss\n                              where ss.id = live_reward.programme_id and ss.kind = ''stamps''))\n',
       'C2 live on offer'),
      -- C3. the action band reads the canonical readiness core.
      (E'        when coalesce(reward_candidate.available_now, false) then ''reward_available''',
       E'        when reward_candidate.name is not null and coalesce((ready.payload->>''count'')::integer, 0) > 0 then ''reward_available'' /* nestly_v871 */',
       'C3 action reason'),
      (E'        when coalesce(reward_candidate.available_now, false) then 2',
       E'        when reward_candidate.name is not null and coalesce((ready.payload->>''count'')::integer, 0) > 0 then 2',
       'C3 action band'),
      (E'      from loyalty\n      left join reward_candidate on true\n      left join visit_candidate on true\n  )',
       E'      from loyalty\n      cross join ready\n      left join reward_candidate on true\n      left join visit_candidate on true\n  ), parked as (\n    -- nestly_v871 (B): pots this customer holds units in that are not the live one. Read-only.\n    select coalesce(jsonb_agg(jsonb_build_object(\n             ''programme_id'', t.programme_id, ''unit'', bp.kind, ''balance'', t.units,\n             ''paused_since'', bp.deactivated_at) order by bp.sort, bp.id), ''[]''::jsonb) as programmes\n      from (\n        select pl.programme_id, sum(pl.points)::integer as units\n          from public.points_ledger pl, pot\n         where pl.business_id = p_business_id and pl.client_id = p_client_id\n           and pot.scope = ''programme_pot''\n           and pl.programme_id is distinct from pot.live\n         group by pl.programme_id\n        having sum(pl.points) > 0\n      ) t\n      join public.business_programmes bp\n        on bp.id = t.programme_id and bp.business_id = p_business_id and bp.kind in (''points'',''stamps'')\n  )',
       'C3/B action from + parked'),
      -- C4. the payload's own available_now, and the parked list.
      (E'        ''available_now'', reward_candidate.available_now,',
       E'        ''available_now'', coalesce((ready.payload->>''count'')::integer, 0) > 0, /* nestly_v871 */',
       'C4 payload available_now'),
      (E'    ''ready_count'', (ready.payload->>''count'')::integer,',
       E'    ''parked_programmes'', parked.programmes, /* nestly_v871 */\n    ''ready_count'', (ready.payload->>''count'')::integer,',
       'B payload parked'),
      (E'    cross join ready\n    cross join action;',
       E'    cross join ready\n    cross join parked\n    cross join action;',
       'B final from')
    ) as t(old_text, new_text, label)
  loop
    v_hits := (length(v_src) - length(replace(v_src, v_pair.old_text, ''))) / length(v_pair.old_text);
    if v_hits <> 1 then
      raise exception 'nestly_v871: fragment "%" found % times in c45_base_actionable_wallet_card (expected exactly 1)',
        v_pair.label, v_hits using errcode = 'XX001';
    end if;
    v_src := replace(v_src, v_pair.old_text, v_pair.new_text);
  end loop;
  execute v_src;
end
$patch$;

-- ACL restated verbatim from prod: owner-only internal, called by the customer wallet readers.
revoke all on function app.c45_base_actionable_wallet_card(uuid,uuid,text,text,text,text,text[],timestamptz) from public;

do $verify$
declare v_def text := pg_get_functiondef(
  'app.c45_base_actionable_wallet_card(uuid,uuid,text,text,text,text,text[],timestamptz)'::regprocedure);
begin
  if position('''parked_programmes'', parked.programmes' in v_def) = 0
     or position('app.reward_live_on_offer_v805(live_reward.active' in v_def) = 0
     or position('''available_now'', coalesce((ready.payload->>''count'')::integer, 0) > 0' in v_def) = 0
     or position('''available_now'', reward_candidate.available_now,' in v_def) > 0 then
    raise exception 'nestly_v871: wallet card was not patched' using errcode = 'XX001';
  end if;
  if to_regprocedure('public.business_switch_to_points_v871(uuid,uuid)') is null then
    raise exception 'nestly_v871: reverse conversion RPC missing' using errcode = 'XX001';
  end if;
end
$verify$;

commit;
