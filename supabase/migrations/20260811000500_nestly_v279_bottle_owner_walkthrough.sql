-- NESTLY v279 — BOTTLE KEEP: THE OWNER'S WALKTHROUGH OF THE LIVE MODULE
--
-- Owner walked the shipped V275/V278 Bottles module end to end on 2026-08-11 and gave eleven
-- rulings. Six of them are server truths and live here; the rest are client work that this file
-- deliberately makes possible rather than merely permitted.
--
--   1  RE-ENTRY IS GONE. "What is the purpose of re-entry? Please remove it." The COLUMN stays —
--      bar_bottles.reentry_limit already holds real numbers for bottles parked before today, and
--      deleting a column of somebody's custody record to tidy a form is not a trade this module
--      makes. What goes is every path that READS or WRITES it: the shared projection stops
--      publishing it, the customer read stops publishing it, and both park functions accept the
--      argument (so a deploy in flight and any external caller keep resolving) and IGNORE it,
--      storing null. The residue is therefore historical and invisible, never re-grown.
--
--   2  RETRIEVED IS TERMINAL. Owner rulings 10 and 13: pressing Retrieved means the bottle went
--      out with the customer and is done. V278 modelled it as a floor state you could walk back
--      from, and shipped a separate Finish beside it — two controls for one physical event, which
--      is how a bar ends up with a shelf list that disagrees with the shelf. 'retrieved' now
--      behaves exactly like 'finished': stored/called/at_table may enter it, and NOTHING leaves
--      it. app.bar_status_transition_allowed_v279 replaces the V278 matrix, and the guard inside
--      set_bottle_status_v275 stops treating a retrieved bottle as being on the floor at all.
--      finish_bottle_v275 stays deployed and callable (a deploy in flight must not break) but the
--      client no longer offers it.
--
--   8  STORAGE CAPACITY. A bar has a finite number of shelf slots, and the honest moment to say so
--      is BEFORE the bottle is taken from the customer. bar_bottle_settings gains one number
--      (default 500, 1..10000); only IN-STORAGE bottles (stored/called/at_table) consume it, since
--      a retrieved bottle has physically left the building. Enforced in EVERY park path — the V275
--      one, the V278 one and the new batch one — because a capacity that the till can walk around
--      is a decoration. The batch path asks for its WHOLE quantity at once, so parking 3 with 2
--      slots left refuses all three rather than half-filling the shelf and erroring.
--
--   5  QUANTITY. "How many bottles" 1..20 on park: N identical unopened bottles are N rows, each
--      with its own serial, because a physical shelf label is per bottle. They are ONE intention,
--      so they are one transaction with one idempotency key — the per-row event keys are derived
--      from it as '<key>#<n>', and the replay probe matches on that prefix and returns the same
--      batch. A second tap therefore cannot produce a second batch, and cannot produce a PARTIAL
--      second batch either, which a per-row key would have allowed the moment one insert failed.
--
--  3/4/9/11  Colour bands, status colours, the Move fix and the final action row are client-side,
--      but two of them need server shape and get it here: the status filter collapses to THREE
--      tabs (Storage / Retrieved / Expired), so list_bar_bottles_v275 learns a 'storage' token
--      meaning the three floor states; and the Bottles KPI shows "N / capacity", so the same read
--      returns in_storage and capacity rather than making the browser compute a number the server
--      is about to enforce.
--
-- SPLICE vs RECREATE, same rule as V278: functions this module wholly owns are RECREATED (they
-- depend on nothing production happens to hold, and the Supabase apply path strips comments);
-- the three settled write functions whose idempotency machinery must not be retyped are SPLICED
-- from their OWN deployed source with comment-free, exactly-once needles and a post-verify against
-- the DEPLOYED definition. Every splice is re-runnable: it returns early when its result is
-- already present, and raises rather than guesses when its needle is not.
--
-- STILL NOT IN THIS INCREMENT: the daily expiry sweep cron, and WhatsApp/email sending. Both ride
-- the deferred comms work exactly as they did at V275 and V278.

begin;

-- ---------------------------------------------------------------------------
-- 1. Schema. One number, and one comment recording that a live column is now write-only history.
-- ---------------------------------------------------------------------------

alter table public.bar_bottle_settings
  add column storage_capacity integer not null default 500
    check (storage_capacity between 1 and 10000);

comment on column public.bar_bottle_settings.storage_capacity is
  'V279 how many bottles this bar can physically hold. Only stored/called/at_table consume a slot; a retrieved bottle has left the building. Enforced in every park path, not merely displayed.';

comment on column public.bar_bottles.reentry_limit is
  'RETIRED at V279 (owner: "what is the purpose of re-entry? please remove it"). The column is kept because bottles parked before V279 carry real values and a custody record is not edited to tidy a form. Nothing reads it and nothing writes it any more: both park functions accept their p_reentry_limit argument and store null.';

-- ---------------------------------------------------------------------------
-- 2. Helpers.
-- ---------------------------------------------------------------------------

create or replace function app.bar_storage_capacity_v279(p_business uuid)
returns integer
language sql
stable
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
  select coalesce(
    (select setting.storage_capacity from public.bar_bottle_settings setting
      where setting.business_id = p_business),
    500)
$$;
revoke all on function app.bar_storage_capacity_v279(uuid) from public, anon, authenticated;

-- In storage means physically on the premises under the bar's care. 'retrieved' is terminal at
-- V279 and 'expired'/'finished'/'transferred'/'removed' were never on the shelf, so the slot is
-- freed the moment a bottle leaves any of the three floor states.
create or replace function app.bar_in_storage_count_v279(p_business uuid)
returns integer
language sql
stable
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
  select count(*)::integer from public.bar_bottles bottle
   where bottle.business_id = p_business
     and bottle.status in ('stored', 'called', 'at_table')
$$;
revoke all on function app.bar_in_storage_count_v279(uuid) from public, anon, authenticated;

-- The refusal every park path holds. p_wanted is the WHOLE batch: a bar with two slots left must
-- be told it cannot take three bottles before it takes the first one off the customer.
create or replace function app.bar_capacity_guard_v279(p_business uuid, p_wanted integer)
returns void
language plpgsql
stable
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_capacity integer;
  v_used integer;
  v_wanted integer := greatest(coalesce(p_wanted, 1), 1);
begin
  v_capacity := app.bar_storage_capacity_v279(p_business);
  v_used := app.bar_in_storage_count_v279(p_business);
  if v_used + v_wanted > v_capacity then
    raise exception 'Storage is full — % of % in use', v_used, v_capacity using errcode = '22023';
  end if;
end;
$$;
revoke all on function app.bar_capacity_guard_v279(uuid, integer) from public, anon, authenticated;

-- Owner rulings 10 and 13. Retrieved is a terminal state, not a floor state you can walk back
-- from: it is the bottle leaving with the customer. Nothing transitions OUT of it, including to
-- itself, so the one-way door is a property of the matrix rather than of the buttons.
create or replace function app.bar_status_transition_allowed_v279(p_from text, p_to text)
returns boolean
language sql
immutable
set search_path to 'pg_catalog', 'pg_temp'
as $$
  select case
    when $1 in ('stored', 'called', 'at_table')
      and $2 in ('stored', 'called', 'at_table', 'retrieved') then true
    else false
  end
$$;
revoke all on function app.bar_status_transition_allowed_v279(text, text) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 3. The shared projection, recreated so the list row, the bottle card, the dashboard and the
--    customer wallet all stop publishing re-entry at the same instant. Recreated rather than
--    spliced: this module wholly owns it.
-- ---------------------------------------------------------------------------

create or replace function app.bar_bottle_json_v275(p_bottle public.bar_bottles)
returns jsonb
language sql
stable
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
  select jsonb_build_object(
    'id', ($1).id,
    'serial_code', ($1).serial_code,
    'label', coalesce(
      nullif(btrim(coalesce(($1).label, '')), ''),
      (select product.name from public.products product where product.id = ($1).product_id)),
    'product_id', ($1).product_id,
    'size_ml', ($1).size_ml,
    'fill_percent', ($1).fill_percent,
    'status', ($1).status,
    'storage_location_id', ($1).storage_location_id,
    'storage_location_name', (
      select location.name from public.bar_storage_locations location
       where location.id = ($1).storage_location_id),
    'parked_at', ($1).parked_at,
    'expires_at', ($1).expires_at,
    'expiry_mode', ($1).expiry_mode,
    'notify_channel', ($1).notify_channel,
    'purchased_on', ($1).purchased_on,
    'tier_name', app.bar_tier_name_v278(($1).business_id, ($1).client_id),
    'days_left', case when ($1).expires_at is null then null else (
      (($1).expires_at at time zone 'Asia/Singapore')::date
      - (now() at time zone 'Asia/Singapore')::date
    ) end,
    'branch_id', ($1).branch_id,
    'client_id', ($1).client_id,
    'sale_id', ($1).sale_id
  )
$$;
revoke all on function app.bar_bottle_json_v275(public.bar_bottles) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 4. Splices against the deployed definitions.
-- ---------------------------------------------------------------------------

-- set_bottle_status_v275 learns that retrieved is terminal. The legal TARGET set is unchanged
-- (a bottle may still be sent out); what changes is that a bottle already sent out is no longer
-- on the floor, and the matrix it is judged by is the V279 one.
do $v279_status_rpc$
declare
  v_source text;
  v_patched text;
  v_hits integer;
  v_needle constant text :=
$needle$  if v_bottle.status not in ('stored', 'called', 'at_table', 'retrieved') then
    raise exception 'this bottle is no longer on the floor' using errcode = '22023';
  end if;
  if not app.bar_status_transition_allowed_v278(v_bottle.status, v_status) then
    raise exception 'bring the bottle back to storage before moving it again' using errcode = '22023';
  end if;$needle$;
  v_patch constant text :=
$needle$  if v_bottle.status not in ('stored', 'called', 'at_table') then
    raise exception 'this bottle has already been sent out' using errcode = '22023';
  end if;
  if not app.bar_status_transition_allowed_v279(v_bottle.status, v_status) then
    raise exception 'this bottle has already been sent out' using errcode = '22023';
  end if;$needle$;
begin
  v_source := pg_get_functiondef('public.set_bottle_status_v275(uuid,uuid,text,text)'::regprocedure);
  if position('bar_status_transition_allowed_v279' in v_source) > 0 then
    raise notice 'v279: set_bottle_status_v275 already treats retrieved as terminal - nothing to do';
    return;
  end if;
  if position('bar_status_transition_allowed_v278' in v_source) = 0 then
    raise exception 'v279: set_bottle_status_v275 does not carry the V278 transition rule - refusing to guess';
  end if;
  v_hits := (length(v_source) - length(replace(v_source, v_needle, ''))) / length(v_needle);
  if v_hits <> 1 then
    raise exception 'v279: expected exactly 1 floor-guard needle in set_bottle_status_v275, found %', v_hits;
  end if;
  v_patched := replace(v_source, v_needle, v_patch);
  execute v_patched;

  -- Verify against the DEPLOYED definition, never against the string we just built.
  v_source := pg_get_functiondef('public.set_bottle_status_v275(uuid,uuid,text,text)'::regprocedure);
  if position('bar_status_transition_allowed_v279' in v_source) = 0
     or position('bar_status_transition_allowed_v278' in v_source) > 0 then
    raise exception 'v279: the terminal-retrieved rule did not land in the deployed function';
  end if;
  raise notice 'v279: set_bottle_status_v275 now treats retrieved as a terminal state';
end
$v279_status_rpc$;

-- park_bottle_v275: capacity, and re-entry stops being written.
do $v279_park_v275$
declare
  v_source text;
  v_patched text;
  v_hits integer;
  v_year_needle constant text :=
$needle$  v_year := extract(year from (now() at time zone 'Asia/Singapore'))::integer;$needle$;
  v_year_patch constant text :=
$needle$  perform app.bar_capacity_guard_v279(p_business, 1);

  v_year := extract(year from (now() at time zone 'Asia/Singapore'))::integer;$needle$;
  v_reentry_needle constant text :=
$needle$    p_size_ml, v_fill, p_storage_location, p_reentry_limit, 'stored',$needle$;
  v_reentry_patch constant text :=
$needle$    p_size_ml, v_fill, p_storage_location, null, 'stored',$needle$;
begin
  v_source := pg_get_functiondef('public.park_bottle_v275(uuid,uuid,text,uuid,integer,integer,uuid,integer,uuid,uuid,text)'::regprocedure);
  if position('bar_capacity_guard_v279' in v_source) > 0 then
    raise notice 'v279: park_bottle_v275 already holds the capacity guard - nothing to do';
    return;
  end if;
  v_hits := (length(v_source) - length(replace(v_source, v_year_needle, ''))) / length(v_year_needle);
  if v_hits <> 1 then
    raise exception 'v279: expected exactly 1 serial-year needle in park_bottle_v275, found %', v_hits;
  end if;
  v_hits := (length(v_source) - length(replace(v_source, v_reentry_needle, ''))) / length(v_reentry_needle);
  if v_hits <> 1 then
    raise exception 'v279: expected exactly 1 re-entry needle in park_bottle_v275, found %', v_hits;
  end if;
  v_patched := replace(v_source, v_year_needle, v_year_patch);
  v_patched := replace(v_patched, v_reentry_needle, v_reentry_patch);
  execute v_patched;

  v_source := pg_get_functiondef('public.park_bottle_v275(uuid,uuid,text,uuid,integer,integer,uuid,integer,uuid,uuid,text)'::regprocedure);
  if position('bar_capacity_guard_v279' in v_source) = 0
     or position('p_reentry_limit, ''stored''' in v_source) > 0 then
    raise exception 'v279: the capacity guard and the re-entry retirement did not land in park_bottle_v275';
  end if;
  raise notice 'v279: park_bottle_v275 now refuses over capacity and stores no re-entry limit';
end
$v279_park_v275$;

-- park_bottle_v278: the same two changes, on the function the client called until today.
do $v279_park_v278$
declare
  v_source text;
  v_patched text;
  v_hits integer;
  v_signature constant text :=
    'public.park_bottle_v278(uuid,uuid,text,uuid,integer,integer,uuid,integer,uuid,uuid,text,date,text,text,date,text)';
  v_year_needle constant text :=
$needle$  v_year := extract(year from (now() at time zone 'Asia/Singapore'))::integer;$needle$;
  v_year_patch constant text :=
$needle$  perform app.bar_capacity_guard_v279(p_business, 1);

  v_year := extract(year from (now() at time zone 'Asia/Singapore'))::integer;$needle$;
  v_reentry_needle constant text :=
$needle$    v_size, v_fill, p_storage_location, p_reentry_limit, 'stored',$needle$;
  v_reentry_patch constant text :=
$needle$    v_size, v_fill, p_storage_location, null, 'stored',$needle$;
begin
  v_source := pg_get_functiondef(v_signature::regprocedure);
  if position('bar_capacity_guard_v279' in v_source) > 0 then
    raise notice 'v279: park_bottle_v278 already holds the capacity guard - nothing to do';
    return;
  end if;
  v_hits := (length(v_source) - length(replace(v_source, v_year_needle, ''))) / length(v_year_needle);
  if v_hits <> 1 then
    raise exception 'v279: expected exactly 1 serial-year needle in park_bottle_v278, found %', v_hits;
  end if;
  v_hits := (length(v_source) - length(replace(v_source, v_reentry_needle, ''))) / length(v_reentry_needle);
  if v_hits <> 1 then
    raise exception 'v279: expected exactly 1 re-entry needle in park_bottle_v278, found %', v_hits;
  end if;
  v_patched := replace(v_source, v_year_needle, v_year_patch);
  v_patched := replace(v_patched, v_reentry_needle, v_reentry_patch);
  execute v_patched;

  v_source := pg_get_functiondef(v_signature::regprocedure);
  if position('bar_capacity_guard_v279' in v_source) = 0
     or position('p_reentry_limit, ''stored''' in v_source) > 0 then
    raise exception 'v279: the capacity guard and the re-entry retirement did not land in park_bottle_v278';
  end if;
  raise notice 'v279: park_bottle_v278 now refuses over capacity and stores no re-entry limit';
end
$v279_park_v278$;

-- ---------------------------------------------------------------------------
-- 5. Reads, recreated. Every one keeps the bar gate as its FIRST authorisation step.
-- ---------------------------------------------------------------------------

create or replace function public.bar_get_setup_v275(p_business uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_locations jsonb;
begin
  perform app.require_bar_business_v275(p_business);
  perform app.require_bar_staff_v275(p_business, false);

  select coalesce(jsonb_agg(jsonb_build_object(
           'id', location.id,
           'name', location.name,
           'active', location.active,
           'sort', location.sort,
           'in_use', exists (
             select 1 from public.bar_bottles bottle
              where bottle.storage_location_id = location.id
                and bottle.status in ('stored', 'called', 'at_table')
           )
         ) order by location.sort, location.name), '[]'::jsonb)
    into v_locations
    from public.bar_storage_locations location
   where location.business_id = p_business;

  return jsonb_build_object(
    'status', 'ok',
    'keep_days', app.bar_keep_days_v275(p_business),
    'storage_capacity', app.bar_storage_capacity_v279(p_business),
    'in_storage', app.bar_in_storage_count_v279(p_business),
    'can_edit', app.is_salon_owner(p_business),
    'locations', v_locations);
end;
$$;

-- The status argument now speaks the THREE tabs the owner asked for. 'storage' is the three floor
-- states as one answer, because "on the shelf" is one idea to a bartender and splitting it across
-- three tabs was three taps to answer one question. The exact status tokens and 'all' still
-- resolve, so nothing that already calls this breaks.
create or replace function public.list_bar_bottles_v275(
  p_business uuid,
  p_branch uuid,
  p_status text,
  p_search text,
  p_expiring_days integer,
  p_bottle uuid,
  p_limit integer
)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_status text := lower(btrim(coalesce(p_status, '')));
  v_search text := nullif(btrim(coalesce(p_search, '')), '');
  v_limit integer := least(greatest(coalesce(p_limit, 100), 1), 200);
  v_storage boolean;
  v_items jsonb;
  v_counts jsonb;
  v_bottle public.bar_bottles%rowtype;
  v_events jsonb;
begin
  perform app.require_bar_business_v275(p_business);
  perform app.require_bar_staff_v275(p_business, false);

  -- Empty and 'storage' are the same question, so the default tab and an explicit Storage tab
  -- cannot drift apart.
  v_storage := v_status in ('', 'storage');

  if p_bottle is not null then
    select * into v_bottle from public.bar_bottles bottle
     where bottle.id = p_bottle and bottle.business_id = p_business;
    if not found then
      raise exception 'bottle not found' using errcode = '22023';
    end if;
    select coalesce(jsonb_agg(jsonb_build_object(
             'id', event.id, 'kind', event.kind, 'detail', event.detail,
             'occurred_at', event.occurred_at,
             'actor_name', staff_row.full_name
           ) order by event.occurred_at desc, event.id desc), '[]'::jsonb)
      into v_events
      from public.bar_bottle_events event
      left join public.staff staff_row
        on staff_row.business_id = p_business and staff_row.user_id = event.actor
     where event.bottle_id = v_bottle.id;
    return jsonb_build_object(
      'status', 'ok',
      'keep_days', app.bar_keep_days_v275(p_business),
      'auto_keep_days', app.bar_keep_days_for_client_v278(p_business, v_bottle.client_id),
      'storage_capacity', app.bar_storage_capacity_v279(p_business),
      'in_storage', app.bar_in_storage_count_v279(p_business),
      'can_write', app.is_salon_owner(p_business) or app.can_module_write(p_business, 'bottles'),
      'bottle', app.bar_bottle_json_v275(v_bottle)
        || jsonb_build_object('client_name', (
             select client.full_name from public.clients client where client.id = v_bottle.client_id
           ))
        || jsonb_build_object('client_phone', (
             select client.phone from public.clients client where client.id = v_bottle.client_id
           )),
      'events', v_events);
  end if;

  select coalesce(jsonb_agg(entry order by ordering_expires, ordering_serial), '[]'::jsonb)
    into v_items
    from (
      select app.bar_bottle_json_v275(bottle)
             || jsonb_build_object('client_name', client.full_name,
                                   'client_phone', client.phone) as entry,
             bottle.expires_at as ordering_expires,
             bottle.serial_seq as ordering_serial
        from public.bar_bottles bottle
        join public.clients client on client.id = bottle.client_id
        left join public.products product on product.id = bottle.product_id
       where bottle.business_id = p_business
         and (p_branch is null or bottle.branch_id = p_branch)
         and (v_status = 'all'
              or (v_storage and bottle.status in ('stored', 'called', 'at_table'))
              or (not v_storage and v_status <> 'all' and bottle.status = v_status))
         and (p_expiring_days is null
              or (bottle.status in ('stored', 'called', 'at_table')
                  and bottle.expires_at is not null
                  and bottle.expires_at <= now() + make_interval(days => p_expiring_days)))
         and (v_search is null
              or client.full_name ilike '%' || v_search || '%'
              or coalesce(client.phone, '') ilike '%' || v_search || '%'
              or bottle.serial_code ilike '%' || v_search || '%'
              or coalesce(bottle.label, '') ilike '%' || v_search || '%'
              or coalesce(product.name, '') ilike '%' || v_search || '%')
       order by bottle.expires_at, bottle.serial_seq
       limit v_limit
    ) page;

  -- The counts describe the WHOLE floor for this branch, never the filtered page: a number that
  -- shrank when you typed a search would be reporting the search, not the bar. 'active' and
  -- 'in_storage' are the same three states under two names because the dashboard reads one and
  -- the capacity gauge reads the other; keeping them one expression stops them disagreeing.
  select jsonb_build_object(
           'stored', count(*) filter (where bottle.status = 'stored'),
           'called', count(*) filter (where bottle.status = 'called'),
           'at_table', count(*) filter (where bottle.status = 'at_table'),
           'retrieved', count(*) filter (where bottle.status = 'retrieved'),
           'expired', count(*) filter (where bottle.status = 'expired'),
           'in_storage', count(*) filter (
             where bottle.status in ('stored', 'called', 'at_table')),
           'active', count(*) filter (
             where bottle.status in ('stored', 'called', 'at_table')),
           'expiring_soon', count(*) filter (
             where bottle.status in ('stored', 'called', 'at_table')
               and bottle.expires_at is not null
               and bottle.expires_at <= now() + make_interval(days => 7)))
    into v_counts
    from public.bar_bottles bottle
   where bottle.business_id = p_business
     and (p_branch is null or bottle.branch_id = p_branch);

  return jsonb_build_object(
    'status', 'ok',
    'as_of', now(),
    'keep_days', app.bar_keep_days_v275(p_business),
    'storage_capacity', app.bar_storage_capacity_v279(p_business),
    'in_storage', app.bar_in_storage_count_v279(p_business),
    'can_write', app.is_salon_owner(p_business) or app.can_module_write(p_business, 'bottles'),
    'counts', v_counts,
    'items', v_items);
end;
$$;

-- The customer side. Retrieved is terminal at V279, so a bottle that has gone out with the
-- customer leaves their wallet card the way a finished one does — the card is "what this bar is
-- holding for you", and a bar that is no longer holding it must not still claim to be.
create or replace function public.customer_get_bottles_v275(p_business_slug text)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_business uuid;
  v_client uuid;
  v_modules text[];
  v_items jsonb;
begin
  select context.business_id, context.client_id, context.enabled_modules
    into v_business, v_client, v_modules
    from app.v32_customer_wallet_context(p_business_slug) context
   limit 1;
  if v_business is null then
    raise exception 'no verified link to this business' using errcode = '42501';
  end if;
  perform app.require_bar_business_v275(v_business);
  if not ('bottles' = any (coalesce(v_modules, '{}'::text[]))) then
    raise exception 'bottle keep is not enabled for this business' using errcode = '42501';
  end if;

  select coalesce(jsonb_agg(entry order by ordering_expires), '[]'::jsonb)
    into v_items
    from (
      select jsonb_build_object(
               'id', bottle.id,
               'serial_code', bottle.serial_code,
               'label', coalesce(nullif(btrim(coalesce(bottle.label, '')), ''), product.name),
               'size_ml', bottle.size_ml,
               'fill_percent', bottle.fill_percent,
               'status', bottle.status,
               'storage_location_name', location.name,
               'parked_at', bottle.parked_at,
               'expires_at', bottle.expires_at,
               'expiry_mode', bottle.expiry_mode,
               'days_left', case when bottle.expires_at is null then null else (
                 (bottle.expires_at at time zone 'Asia/Singapore')::date
                 - (now() at time zone 'Asia/Singapore')::date
               ) end) as entry,
             bottle.expires_at as ordering_expires
        from public.bar_bottles bottle
        left join public.products product on product.id = bottle.product_id
        left join public.bar_storage_locations location on location.id = bottle.storage_location_id
       where bottle.business_id = v_business
         and bottle.client_id = v_client
         and bottle.status in ('stored', 'called', 'at_table')
       order by bottle.expires_at
       limit 50
    ) page;

  return jsonb_build_object('status', 'ok', 'items', v_items);
end;
$$;

-- ---------------------------------------------------------------------------
-- 6. Setup save, with the capacity. A NEW NAME rather than a fourth parameter on
--    bar_save_setup_v275: a second overload differing only in arity is exactly the shape that
--    makes PostgREST's function resolution ambiguous, and V278 already paid that lesson.
--    bar_save_setup_v275 stays deployed and callable.
-- ---------------------------------------------------------------------------

create or replace function public.bar_save_setup_v279(
  p_business uuid,
  p_keep_days integer,
  p_storage_capacity integer,
  p_locations jsonb
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_actor uuid := auth.uid();
  v_keep integer := p_keep_days;
  v_capacity integer := p_storage_capacity;
  v_kept uuid[] := '{}'::uuid[];
  v_entry jsonb;
  v_name text;
  v_id uuid;
  v_found uuid;
  v_sort integer := 0;
begin
  perform app.require_bar_business_v275(p_business);
  if v_actor is null then
    raise exception 'authenticated staff required' using errcode = '28000';
  end if;
  if not app.is_salon_owner(p_business) then
    raise exception 'only the owner can change bottle keep setup' using errcode = '42501';
  end if;
  if v_keep is null or v_keep < 1 or v_keep > 365 then
    raise exception 'keep window must be between 1 and 365 days' using errcode = '22023';
  end if;
  if v_capacity is null or v_capacity < 1 or v_capacity > 10000 then
    raise exception 'storage capacity must be between 1 and 10000 bottles' using errcode = '22023';
  end if;
  if p_locations is not null and jsonb_typeof(p_locations) <> 'array' then
    raise exception 'storage locations must be a list' using errcode = '22023';
  end if;

  insert into public.bar_bottle_settings (business_id, keep_days, storage_capacity, updated_at, updated_by)
  values (p_business, v_keep, v_capacity, now(), v_actor)
  on conflict (business_id) do update
    set keep_days = excluded.keep_days,
        storage_capacity = excluded.storage_capacity,
        updated_at = excluded.updated_at,
        updated_by = excluded.updated_by;

  for v_entry in select value from jsonb_array_elements(coalesce(p_locations, '[]'::jsonb)) loop
    v_name := nullif(btrim(coalesce(v_entry->>'name', '')), '');
    if v_name is null then
      raise exception 'a storage location needs a name' using errcode = '22023';
    end if;
    if length(v_name) > 60 then
      raise exception 'a storage location name is limited to 60 characters' using errcode = '22023';
    end if;
    v_sort := v_sort + 1;
    v_id := nullif(v_entry->>'id', '')::uuid;
    v_found := null;
    if v_id is not null then
      update public.bar_storage_locations location
         set name = v_name, active = true, sort = v_sort, updated_at = now()
       where location.id = v_id and location.business_id = p_business
       returning location.id into v_found;
    end if;
    if v_found is null then
      insert into public.bar_storage_locations (business_id, name, active, sort)
      values (p_business, v_name, true, v_sort)
      on conflict (business_id, name) do update
        set active = true, sort = excluded.sort, updated_at = now()
      returning id into v_found;
    end if;
    v_kept := array_append(v_kept, v_found);
  end loop;

  -- A name that disappears from the list is DEACTIVATED, never deleted: bottles still point at it
  -- and must keep a nameable answer to "where is it".
  update public.bar_storage_locations location
     set active = false, updated_at = now()
   where location.business_id = p_business
     and location.active
     and not (location.id = any (v_kept));

  return public.bar_get_setup_v275(p_business);
end;
$$;

-- ---------------------------------------------------------------------------
-- 7. Park a batch. Owner ruling 5: "how many bottles", 1..20, N identical unopened bottles.
--
--    ONE INTENTION, ONE KEY. The caller sends a single idempotency key for the whole batch. Each
--    bottle's evidence row carries a DERIVED key '<key>#<n>' so the unique index still holds one
--    row per event, and the replay probe matches on the '<key>#' PREFIX and returns the same
--    batch. A per-bottle key from the browser would have let a retry after a partial failure park
--    the remainder as a second batch; a single shared key would have collided on the second row.
--
--    Re-entry is gone: this function has no p_reentry_limit at all and never will.
-- ---------------------------------------------------------------------------

create or replace function public.park_bottles_v279(
  p_business uuid,
  p_client uuid,
  p_label text,
  p_product uuid,
  p_size_ml integer,
  p_fill_percent integer,
  p_storage_location uuid,
  p_branch uuid,
  p_sale uuid,
  p_expiry_mode text,
  p_expiry_date date,
  p_notify_channel text,
  p_note text,
  p_purchased_on date,
  p_quantity integer,
  p_idempotency_key text
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_actor uuid := auth.uid();
  v_key text := nullif(btrim(coalesce(p_idempotency_key, '')), '');
  v_label text := nullif(btrim(coalesce(p_label, '')), '');
  v_note text := nullif(btrim(coalesce(p_note, '')), '');
  v_mode text := lower(btrim(coalesce(nullif(btrim(coalesce(p_expiry_mode, '')), ''), 'auto')));
  v_channel text := lower(btrim(coalesce(nullif(btrim(coalesce(p_notify_channel, '')), ''), 'none')));
  v_fill integer := coalesce(p_fill_percent, 100);
  v_size integer := p_size_ml;
  v_quantity integer := coalesce(p_quantity, 1);
  v_expires timestamptz;
  v_keep integer;
  v_year integer;
  v_seq integer;
  v_index integer;
  v_bottle public.bar_bottles%rowtype;
  v_bottles jsonb := '[]'::jsonb;
begin
  perform app.require_bar_business_v275(p_business);
  perform app.require_bar_staff_v275(p_business, true);
  if v_key is null then
    raise exception 'idempotency key required' using errcode = '22023';
  end if;
  if p_client is null then
    raise exception 'choose a customer' using errcode = '22023';
  end if;
  if v_label is null and p_product is null then
    raise exception 'name the bottle or pick it from the catalogue' using errcode = '22023';
  end if;
  if v_fill < 0 or v_fill > 100 then
    raise exception 'fill must be between 0 and 100' using errcode = '22023';
  end if;
  if v_quantity < 1 or v_quantity > 20 then
    raise exception 'park between 1 and 20 bottles at a time' using errcode = '22023';
  end if;
  if v_channel not in ('whatsapp', 'email', 'none') then
    raise exception 'reminders go by WhatsApp, by email, or not at all' using errcode = '22023';
  end if;
  if v_note is not null and length(v_note) > 500 then
    raise exception 'a note is limited to 500 characters' using errcode = '22023';
  end if;
  if p_purchased_on is not null
     and p_purchased_on > ((now() at time zone 'Asia/Singapore')::date + 1) then
    raise exception 'a bottle cannot have been bought in the future' using errcode = '22023';
  end if;

  -- Replay probe on the batch prefix. left(...) rather than LIKE so a key containing % or _ is
  -- compared literally instead of being read as a pattern.
  select coalesce(jsonb_agg(app.bar_bottle_json_v275(bottle) order by bottle.serial_seq), '[]'::jsonb)
    into v_bottles
    from public.bar_bottle_events event
    join public.bar_bottles bottle on bottle.id = event.bottle_id
   where event.business_id = p_business
     and event.kind = 'park'
     and left(event.idem_key, length(v_key) + 1) = v_key || '#';
  if jsonb_array_length(v_bottles) > 0 then
    return jsonb_build_object('status', 'duplicate_ignored',
      'count', jsonb_array_length(v_bottles),
      'bottles', v_bottles,
      'bottle', v_bottles -> 0);
  end if;

  -- The size ALWAYS comes from the catalogue when a catalogue bottle was picked. The browser is
  -- not trusted to have copied it.
  if p_product is not null then
    select coalesce(product.size_ml, v_size) into v_size
      from public.products product
     where product.id = p_product and product.business_id = p_business;
    if not found then
      raise exception 'that bottle is not in your catalogue' using errcode = '22023';
    end if;
  end if;

  -- Locking the settings row serialises serial allocation for this business, exactly as V275 and
  -- V278 do: a duplicate PK-YYYY-NNNN on a physical shelf label is the failure this module exists
  -- to prevent, and a batch allocates a whole RANGE of them.
  insert into public.bar_bottle_settings (business_id) values (p_business)
  on conflict (business_id) do nothing;
  select setting.keep_days into v_keep
    from public.bar_bottle_settings setting
   where setting.business_id = p_business
     for update;

  -- The WHOLE batch is asked for at once: two free slots refuse three bottles rather than parking
  -- two and failing on the third with a customer's property already behind the bar.
  perform app.bar_capacity_guard_v279(p_business, v_quantity);

  v_expires := app.bar_bottle_expiry_v278(p_business, p_client, v_mode, p_expiry_date);

  v_year := extract(year from (now() at time zone 'Asia/Singapore'))::integer;
  select coalesce(max(bottle.serial_seq), 0) + 1 into v_seq
    from public.bar_bottles bottle
   where bottle.business_id = p_business and bottle.serial_year = v_year;

  v_bottles := '[]'::jsonb;
  for v_index in 1..v_quantity loop
    insert into public.bar_bottles (
      business_id, branch_id, client_id, serial_year, serial_seq, label, product_id,
      size_ml, fill_percent, storage_location_id, reentry_limit, status,
      parked_at, expires_at, sale_id, expiry_mode, notify_channel, purchased_on
    ) values (
      p_business, p_branch, p_client, v_year, v_seq + v_index - 1, v_label, p_product,
      v_size, v_fill, p_storage_location, null, 'stored',
      now(), v_expires, p_sale, v_mode, v_channel, p_purchased_on
    )
    returning * into v_bottle;

    insert into public.bar_bottle_events (business_id, bottle_id, kind, actor, idem_key, detail)
    values (p_business, v_bottle.id, 'park', v_actor, v_key || '#' || v_index, jsonb_build_object(
      'serial_code', v_bottle.serial_code,
      'client_id', v_bottle.client_id,
      'fill_percent', v_bottle.fill_percent,
      'expiry_mode', v_bottle.expiry_mode,
      'expires_at', v_bottle.expires_at,
      'notify_channel', v_bottle.notify_channel,
      'purchased_on', v_bottle.purchased_on,
      'storage_location_id', v_bottle.storage_location_id,
      'sale_id', v_bottle.sale_id,
      'batch_key', v_key,
      'batch_index', v_index,
      'batch_size', v_quantity,
      'note', v_note));

    v_bottles := v_bottles || jsonb_build_array(app.bar_bottle_json_v275(v_bottle));
  end loop;

  return jsonb_build_object('status', 'ok',
    'count', v_quantity,
    'bottles', v_bottles,
    'bottle', v_bottles -> 0);
end;
$$;

-- ---------------------------------------------------------------------------
-- 8. Grants. A create-from-scratch replay would otherwise inherit PostgreSQL's default
--    EXECUTE-to-PUBLIC on every function above. One explicit pair per overload.
-- ---------------------------------------------------------------------------

revoke all on function public.bar_get_setup_v275(uuid) from public, anon, authenticated;
revoke all on function public.list_bar_bottles_v275(uuid, uuid, text, text, integer, uuid, integer) from public, anon, authenticated;
revoke all on function public.customer_get_bottles_v275(text) from public, anon, authenticated;
revoke all on function public.bar_save_setup_v279(uuid, integer, integer, jsonb) from public, anon, authenticated;
revoke all on function public.park_bottles_v279(uuid, uuid, text, uuid, integer, integer, uuid, uuid, uuid, text, date, text, text, date, integer, text) from public, anon, authenticated;

grant execute on function public.bar_get_setup_v275(uuid) to authenticated;
grant execute on function public.list_bar_bottles_v275(uuid, uuid, text, text, integer, uuid, integer) to authenticated;
grant execute on function public.customer_get_bottles_v275(text) to authenticated;
grant execute on function public.bar_save_setup_v279(uuid, integer, integer, jsonb) to authenticated;
grant execute on function public.park_bottles_v279(uuid, uuid, text, uuid, integer, integer, uuid, uuid, uuid, text, date, text, text, date, integer, text) to authenticated;

commit;
