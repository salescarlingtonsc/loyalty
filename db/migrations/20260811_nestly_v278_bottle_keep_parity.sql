-- NESTLY v278 — BOTTLE KEEP PARITY WITH THE LIVE REFERENCE BAR
--
-- Owner brief 2026-08-11, from screenshots of the reference product in production use at a real
-- bar. V275 shipped the module (park / fill / floor states / extend / transfer / finish, one keep
-- window per business, the bar's own shelf list, hard bar-only gating). This increment closes the
-- gap between that and what the bar actually does at the counter:
--
--   1  TIERED EXPIRY. Park now asks HOW the bottle expires: Auto (resolve the customer's current
--      loyalty tier, then that tier's keep-days override, else the business default), a Custom
--      date, or No expiry. Per-tier keep-days live in a NEW BAR-SCOPED TABLE, never on
--      loyalty_tiers — the owner ruled at V275 that the tier mechanism is the existing one and
--      gains no bar column. An "edit expiry" control exists for the life of the bottle, and every
--      change records old -> new.
--   2  BOTTLE CATALOGUE WITH SYNCED ML. products.size_ml (nullable) makes a product a bottle. The
--      park dialog then picks the exact bottle and the millilitres come with it, so nobody types
--      "70" for a 700ml bottle at 1am. Free text stays for the bottle that is not in the list.
--   3  LIFECYCLE. A new status 'retrieved' — the bottle is out with the customer at the venue,
--      which is neither "on the shelf" nor "gone". stored/called/at_table stay as floor states.
--   4  NOTES on park and on the card.
--   5  NOTIFY PREFERENCE stored per park (whatsapp/email/none) and a manual Notify action that
--      writes the customer an IN-APP inbox event. Actual WhatsApp/email SENDING stays deferred
--      platform-wide; only the preference and the in-app event are real here.
--   6  PURCHASE DATE.
--   7  MOVE (change storage place), recorded like everything else.
--   8  The customer's TIER NAME on the bottle, read-only and fail-soft.
--
-- WHY THE TIER KEEP-DAYS TABLE HOLDS A SOFT REFERENCE AND NOT A FOREIGN KEY. The brief asked for
-- an FK. It cannot be one, and V176 already found out why: public.publish_loyalty_config does
-- DELETE + INSERT over public.loyalty_tiers on EVERY publish, re-inserting each tier under its
-- stable tier_id. A restricting FK would refuse the delete and brick loyalty publishing for any
-- bar that had ever set a keep-days override; a cascading FK would silently erase the overrides on
-- every publish. So tier_id is a soft reference exactly as loyalty_rewards.min_tier_id is, the
-- save RPC validates it against that business's live tiers at write time, and resolution falls
-- back to the business default the moment it no longer resolves. This is a deliberate deviation
-- from the brief's wording in service of the brief's intent.
--
-- HOW THE EXISTING CLIENT KEEPS WORKING. park_bottle_v275 is untouched and still callable: a
-- deploy in flight cannot break. The five new park inputs arrive on a NEW function name,
-- park_bottle_v278, rather than as defaulted parameters on the old one — a second overload of the
-- same name differing only in arity is precisely the shape that makes PostgREST's function
-- resolution ambiguous, and an ambiguous till is worse than an extra name.
--
-- SPLICE vs RECREATE. Two V275 functions are SPLICED from their own deployed source with
-- comment-free, exactly-once needles and a post-verify (set_bottle_status_v275, whose settled
-- idempotency machinery must not be retyped, and extend_bottle_v275's single UPDATE). Four are
-- RECREATED in full (the three read projections and the shared json helper) because a recreate
-- does not depend on production's bytes at all, and the Supabase apply path strips comments — the
-- fewer needles that must survive that, the better. Nothing here reads a comment.
--
-- STILL NOT IN THIS INCREMENT: the daily expiry sweep cron; WhatsApp/email sending; web push for
-- the new inbox kind (app.customer_push_event_eligible_v95 is deliberately NOT extended — a
-- manual staff tap must not become a new outbound push channel without the owner asking for one).

begin;

-- ---------------------------------------------------------------------------
-- 1. Schema.
-- ---------------------------------------------------------------------------

-- A product IS a bottle when it carries a size. One nullable column rather than a second boolean,
-- because "it is a bottle but we do not know how big" is not a state the park dialog can use: the
-- entire point of the catalogue is that the millilitres stop being typed.
alter table public.products
  add column size_ml integer,
  add constraint products_size_ml_check
    check (size_ml is null or size_ml between 100 and 5000);
comment on column public.products.size_ml is
  'V278 bottle size in millilitres. NOT NULL means this product is a bottle the bar can park; the park dialog fills the size from here so it is never typed.';

alter table public.bar_bottles
  add column expiry_mode text not null default 'auto',
  add column notify_channel text,
  add column purchased_on date,
  add constraint bar_bottles_expiry_mode_check
    check (expiry_mode in ('auto', 'custom', 'none')),
  add constraint bar_bottles_notify_channel_check
    check (notify_channel is null or notify_channel in ('whatsapp', 'email', 'none'));

-- "No expiry" is a real answer at a bar that keeps a regular's bottle indefinitely, so expires_at
-- has to be nullable — and the shape check makes the mode and the date incapable of disagreeing,
-- which is the only way "days left" can be trusted on two surfaces.
alter table public.bar_bottles alter column expires_at drop not null;
alter table public.bar_bottles
  add constraint bar_bottles_expiry_shape_check
    check ((expiry_mode = 'none') = (expires_at is null));

comment on column public.bar_bottles.expiry_mode is
  'V278: auto = the customer''s tier keep-days (else the business default) at park time; custom = an agreed date; none = kept indefinitely, expires_at null.';
comment on column public.bar_bottles.notify_channel is
  'V278 stored per-park reminder preference. WhatsApp and email SENDING are deferred platform-wide; this records what the customer asked for so the later sweep has an answer.';
comment on column public.bar_bottles.purchased_on is
  'V278 the date the bottle was bought, when it differs from the date it was parked.';

-- The floor gains 'retrieved': the bottle is physically out with the customer at the venue. It is
-- not 'at_table' (that is the bar carrying it to a table and bringing it back) and it is not
-- finished. Conflating the two is how a bar loses track of a bottle that walked away.
do $v278_status_check$
declare
  v_def text;
begin
  select pg_get_constraintdef(constraint_row.oid) into v_def
    from pg_constraint constraint_row
   where constraint_row.conrelid = 'public.bar_bottles'::regclass
     and constraint_row.conname = 'bar_bottles_status_check';
  if v_def is null then
    raise exception 'v278: bar_bottles_status_check not found - refusing to guess the legal status set';
  end if;
  if position('retrieved' in v_def) > 0 then
    raise notice 'v278: bar_bottles already knows the retrieved status';
    return;
  end if;
  if position('''at_table''' in v_def) = 0 then
    raise exception 'v278: bar_bottles_status_check does not contain the expected at_table status';
  end if;
  execute 'alter table public.bar_bottles drop constraint bar_bottles_status_check';
  execute 'alter table public.bar_bottles add constraint bar_bottles_status_check check (status in '
       || '(''stored'', ''called'', ''at_table'', ''retrieved'', ''finished'', ''expired'', ''transferred'', ''removed''))';
end
$v278_status_check$;

-- Three new evidence kinds. A note, a move and a purchase-date correction are each a change to the
-- record of somebody's property, so each gets its own row rather than being folded into 'status'.
do $v278_event_kind$
declare
  v_def text;
begin
  select pg_get_constraintdef(constraint_row.oid) into v_def
    from pg_constraint constraint_row
   where constraint_row.conrelid = 'public.bar_bottle_events'::regclass
     and constraint_row.conname = 'bar_bottle_events_kind_check';
  if v_def is null then
    raise exception 'v278: bar_bottle_events_kind_check not found - refusing to guess the legal kind set';
  end if;
  if position('''note''' in v_def) > 0 then
    raise notice 'v278: bar_bottle_events already knows the note kind';
    return;
  end if;
  if position('''reminder''' in v_def) = 0 then
    raise exception 'v278: bar_bottle_events_kind_check does not contain the expected reminder kind';
  end if;
  execute 'alter table public.bar_bottle_events drop constraint bar_bottle_events_kind_check';
  execute 'alter table public.bar_bottle_events add constraint bar_bottle_events_kind_check check (kind in '
       || '(''park'', ''fill'', ''status'', ''extend'', ''transfer'', ''finish'', ''expire'', ''reminder'', '
       || '''note'', ''move'', ''purchase''))';
end
$v278_event_kind$;

-- Bar-scoped, RPC-only, RLS on with zero policies — the house shape for every V275 bottle table.
-- tier_id is a SOFT reference (see the header): the publish cycle owns loyalty_tiers' row identity.
create table public.bar_tier_keep_days_v278 (
  business_id uuid not null references public.businesses(id) on delete cascade,
  tier_id uuid not null,
  keep_days integer not null check (keep_days between 1 and 365),
  updated_at timestamptz not null default now(),
  updated_by uuid,
  primary key (business_id, tier_id)
);
comment on table public.bar_tier_keep_days_v278 is
  'V278 per-tier bottle keep window for a bar. tier_id is a soft reference to loyalty_tiers.id (= loyalty_tier_versions.tier_id): publish_loyalty_config DELETEs and re-INSERTs loyalty_tiers on every publish, so a foreign key here would either block the publish or erase the overrides. Absent row = the business default.';

alter table public.bar_tier_keep_days_v278 enable row level security;
revoke all privileges on table public.bar_tier_keep_days_v278 from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 2. Helpers.
-- ---------------------------------------------------------------------------

-- Owner brief item 8: the tier badge is read-only and must FAIL SOFT. A bar's shelf list is an
-- operational screen; it must not go dark because a loyalty programme is half configured, so every
-- failure here returns a blank badge rather than an error.
create or replace function app.bar_tier_name_v278(p_business uuid, p_client uuid)
returns text
language plpgsql
stable
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_tier public.loyalty_tiers%rowtype;
begin
  if p_business is null or p_client is null then
    return null;
  end if;
  if not exists (select 1 from public.loyalty_tiers tier where tier.business_id = p_business) then
    return null;
  end if;
  select * into v_tier from app.loyalty_tier_for(p_business, p_client);
  return nullif(btrim(coalesce(v_tier.name, '')), '');
exception when others then
  return null;
end;
$$;
revoke all on function app.bar_tier_name_v278(uuid, uuid) from public, anon, authenticated;

-- AUTO expiry, resolved in ONE place so the park preview, the park write and a later edit cannot
-- disagree: the customer's current tier's override, else the business's own keep window, else 30.
create or replace function app.bar_keep_days_for_client_v278(p_business uuid, p_client uuid)
returns integer
language plpgsql
stable
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_tier_id uuid;
  v_days integer;
begin
  -- Only the tier IDENTITY is needed, and taking it as a scalar keeps this resolver out of the
  -- business of holding a whole loyalty_tiers row it would then have to null out on failure.
  begin
    select tier.id into v_tier_id from app.loyalty_tier_for(p_business, p_client) tier;
  exception when others then
    v_tier_id := null;
  end;
  if v_tier_id is not null then
    select keep.keep_days into v_days
      from public.bar_tier_keep_days_v278 keep
     where keep.business_id = p_business and keep.tier_id = v_tier_id;
  end if;
  return coalesce(v_days, app.bar_keep_days_v275(p_business));
end;
$$;
revoke all on function app.bar_keep_days_for_client_v278(uuid, uuid) from public, anon, authenticated;

-- One expiry resolver for park and for edit. A custom date is a SINGAPORE calendar date and the
-- bottle lives until the END of it, because "keep it until the 30th" does not mean "until midnight
-- as the 30th begins".
create or replace function app.bar_bottle_expiry_v278(
  p_business uuid,
  p_client uuid,
  p_mode text,
  p_date date
)
returns timestamptz
language plpgsql
stable
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_mode text := lower(btrim(coalesce(p_mode, '')));
  v_next timestamptz;
begin
  if v_mode = 'none' then
    return null;
  end if;
  if v_mode = 'custom' then
    if p_date is null then
      raise exception 'choose the date the bottle is kept until' using errcode = '22023';
    end if;
    v_next := ((p_date + 1)::timestamp) at time zone 'Asia/Singapore';
    if v_next <= now() then
      raise exception 'the keep date must be in the future' using errcode = '22023';
    end if;
    if v_next > now() + make_interval(days => 730) then
      raise exception 'a bottle cannot be kept more than two years' using errcode = '22023';
    end if;
    return v_next;
  end if;
  if v_mode <> 'auto' then
    raise exception 'expiry is automatic, a chosen date, or none' using errcode = '22023';
  end if;
  return now() + make_interval(days => app.bar_keep_days_for_client_v278(p_business, p_client));
end;
$$;
revoke all on function app.bar_bottle_expiry_v278(uuid, uuid, text, date) from public, anon, authenticated;

-- The floor transition matrix, in one place, so the rule is readable rather than inferred from
-- four nested conditions. 'retrieved' is a one-way door out of the floor states: the bottle is
-- with the customer, and it comes back to STORAGE before it can be called or carried again.
create or replace function app.bar_status_transition_allowed_v278(p_from text, p_to text)
returns boolean
language sql
immutable
set search_path to 'pg_catalog', 'pg_temp'
as $$
  select case
    when $1 = $2 then true
    when $1 in ('stored', 'called', 'at_table')
      and $2 in ('stored', 'called', 'at_table', 'retrieved') then true
    when $1 = 'retrieved' and $2 = 'stored' then true
    else false
  end
$$;
revoke all on function app.bar_status_transition_allowed_v278(text, text) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 3. The shared bottle projection, recreated so the list, the detail sheet and the dashboard card
--    all learn the new facts at once. Recreated rather than spliced: it is fully owned by this
--    module, so retyping it depends on nothing production happens to hold.
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
    'reentry_limit', ($1).reentry_limit,
    'parked_at', ($1).parked_at,
    'expires_at', ($1).expires_at,
    'expiry_mode', ($1).expiry_mode,
    'notify_channel', ($1).notify_channel,
    'purchased_on', ($1).purchased_on,
    -- V278: the customer's current tier, resolved fail-soft. Blank is a legitimate answer (no
    -- programme, no tier reached, tiers mid-publish) and never an error on this screen.
    'tier_name', app.bar_tier_name_v278(($1).business_id, ($1).client_id),
    -- Days left is computed HERE, once, in SGT, because two surfaces render it and a browser
    -- that computed it from its own clock would disagree with the bar's own screen. A bottle with
    -- no expiry returns null, which both surfaces render as "No expiry" rather than as a number.
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
-- 4. Splices against the deployed V275 definitions.
-- ---------------------------------------------------------------------------

-- set_bottle_status_v275 learns 'retrieved' and, more importantly, learns that not every pair of
-- floor states is a legal move. The transition rule is enforced HERE, server-side, because the
-- buttons that offer it are a courtesy: a curl can ask for anything.
do $v278_status_rpc$
declare
  v_source text;
  v_patched text;
  v_hits integer;
  v_target_needle constant text :=
$needle$  if v_status not in ('stored', 'called', 'at_table') then
    raise exception 'a bottle on the floor is stored, called or at table' using errcode = '22023';
  end if;$needle$;
  v_target_patch constant text :=
$needle$  if v_status not in ('stored', 'called', 'at_table', 'retrieved') then
    raise exception 'a bottle on the floor is stored, called, at table or retrieved' using errcode = '22023';
  end if;$needle$;
  v_guard_needle constant text :=
$needle$  if v_bottle.status not in ('stored', 'called', 'at_table') then
    raise exception 'this bottle is no longer on the floor' using errcode = '22023';
  end if;$needle$;
  v_guard_patch constant text :=
$needle$  if v_bottle.status not in ('stored', 'called', 'at_table', 'retrieved') then
    raise exception 'this bottle is no longer on the floor' using errcode = '22023';
  end if;
  if not app.bar_status_transition_allowed_v278(v_bottle.status, v_status) then
    raise exception 'bring the bottle back to storage before moving it again' using errcode = '22023';
  end if;$needle$;
begin
  v_source := pg_get_functiondef('public.set_bottle_status_v275(uuid,uuid,text,text)'::regprocedure);
  if position('bar_status_transition_allowed_v278' in v_source) > 0 then
    raise notice 'v278: set_bottle_status_v275 already validates transitions - nothing to do';
    return;
  end if;

  v_hits := (length(v_source) - length(replace(v_source, v_target_needle, '')))
            / length(v_target_needle);
  if v_hits <> 1 then
    raise exception 'v278: expected exactly 1 target-status needle in set_bottle_status_v275, found %', v_hits;
  end if;
  v_hits := (length(v_source) - length(replace(v_source, v_guard_needle, '')))
            / length(v_guard_needle);
  if v_hits <> 1 then
    raise exception 'v278: expected exactly 1 floor-guard needle in set_bottle_status_v275, found %', v_hits;
  end if;

  v_patched := replace(v_source, v_target_needle, v_target_patch);
  v_patched := replace(v_patched, v_guard_needle, v_guard_patch);
  execute v_patched;

  -- Verify against the DEPLOYED definition, never against the string we just built.
  v_source := pg_get_functiondef('public.set_bottle_status_v275(uuid,uuid,text,text)'::regprocedure);
  if position('bar_status_transition_allowed_v278' in v_source) = 0
     or position($check$'stored', 'called', 'at_table', 'retrieved'$check$ in v_source) = 0 then
    raise exception 'v278: the retrieved transition rules did not land in the deployed function';
  end if;
  raise notice 'v278: set_bottle_status_v275 now validates floor transitions including retrieved';
end
$v278_status_rpc$;

-- extend_bottle_v275 keeps working, but a bottle that was parked with NO expiry has no date to
-- extend: giving it one must also move it off 'none', or the shape check would (correctly) refuse
-- the write. Extending is an explicit agreement to a date, so the mode becomes 'custom'.
do $v278_extend_rpc$
declare
  v_source text;
  v_patched text;
  v_hits integer;
  v_needle constant text :=
$needle$  update public.bar_bottles bottle
     set expires_at = v_next,
         status = case when bottle.status = 'expired' then 'stored' else bottle.status end,
         updated_at = now()$needle$;
  v_patch constant text :=
$needle$  update public.bar_bottles bottle
     set expires_at = v_next,
         expiry_mode = case when bottle.expiry_mode = 'none' then 'custom' else bottle.expiry_mode end,
         status = case when bottle.status = 'expired' then 'stored' else bottle.status end,
         updated_at = now()$needle$;
begin
  v_source := pg_get_functiondef('public.extend_bottle_v275(uuid,uuid,timestamptz,text)'::regprocedure);
  if position('expiry_mode' in v_source) > 0 then
    raise notice 'v278: extend_bottle_v275 already carries the expiry mode - nothing to do';
    return;
  end if;
  v_hits := (length(v_source) - length(replace(v_source, v_needle, ''))) / length(v_needle);
  if v_hits <> 1 then
    raise exception 'v278: expected exactly 1 update needle in extend_bottle_v275, found %', v_hits;
  end if;
  v_patched := replace(v_source, v_needle, v_patch);
  execute v_patched;
  v_source := pg_get_functiondef('public.extend_bottle_v275(uuid,uuid,timestamptz,text)'::regprocedure);
  if position('expiry_mode' in v_source) = 0 then
    raise exception 'v278: the expiry mode did not land in the deployed extend_bottle_v275';
  end if;
  raise notice 'v278: extend_bottle_v275 now revives a no-expiry bottle as a custom date';
end
$v278_extend_rpc$;

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
                and bottle.status in ('stored', 'called', 'at_table', 'retrieved')
           )
         ) order by location.sort, location.name), '[]'::jsonb)
    into v_locations
    from public.bar_storage_locations location
   where location.business_id = p_business;

  return jsonb_build_object(
    'status', 'ok',
    'keep_days', app.bar_keep_days_v275(p_business),
    'can_edit', app.is_salon_owner(p_business),
    'locations', v_locations);
end;
$$;

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
  v_items jsonb;
  v_counts jsonb;
  v_bottle public.bar_bottles%rowtype;
  v_events jsonb;
begin
  perform app.require_bar_business_v275(p_business);
  perform app.require_bar_staff_v275(p_business, false);

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
         and (v_status = '' or v_status = 'all' or bottle.status = v_status)
         and (v_status <> '' or bottle.status in ('stored', 'called', 'at_table', 'retrieved'))
         and (p_expiring_days is null
              or (bottle.status in ('stored', 'called', 'at_table', 'retrieved')
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

  -- The status pills count the WHOLE floor for this branch, never the filtered page: a pill that
  -- shrank when you typed a search would be reporting the search, not the bar. 'active' is the
  -- headline the dashboard card reads; a no-expiry bottle is active but never "expiring soon".
  select jsonb_build_object(
           'stored', count(*) filter (where bottle.status = 'stored'),
           'called', count(*) filter (where bottle.status = 'called'),
           'at_table', count(*) filter (where bottle.status = 'at_table'),
           'retrieved', count(*) filter (where bottle.status = 'retrieved'),
           'active', count(*) filter (
             where bottle.status in ('stored', 'called', 'at_table', 'retrieved')),
           'expiring_soon', count(*) filter (
             where bottle.status in ('stored', 'called', 'at_table', 'retrieved')
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
    'can_write', app.is_salon_owner(p_business) or app.can_module_write(p_business, 'bottles'),
    'counts', v_counts,
    'items', v_items);
end;
$$;

-- The customer side. Identity is resolved SERVER-SIDE through the same verified-link context the
-- rest of the customer wallet uses, so a customer sees only their own bottles at that one
-- business and cannot ask for anyone else's by changing an argument.
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
               'reentry_limit', bottle.reentry_limit,
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
         and bottle.status in ('stored', 'called', 'at_table', 'retrieved')
       order by bottle.expires_at
       limit 50
    ) page;

  return jsonb_build_object('status', 'ok', 'items', v_items);
end;
$$;

-- ---------------------------------------------------------------------------
-- 6. Operations setup → Bottle keep: per-tier keep days and the bottle catalogue.
-- ---------------------------------------------------------------------------

create or replace function public.bar_get_bottle_setup_v278(p_business uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_tiers jsonb;
  v_products jsonb;
begin
  perform app.require_bar_business_v275(p_business);
  perform app.require_bar_staff_v275(p_business, false);

  select coalesce(jsonb_agg(jsonb_build_object(
           'tier_id', tier.id,
           'name', tier.name,
           'threshold', tier.threshold,
           'keep_days', keep.keep_days
         ) order by tier.threshold, tier.sort, tier.id), '[]'::jsonb)
    into v_tiers
    from public.loyalty_tiers tier
    left join public.bar_tier_keep_days_v278 keep
      on keep.business_id = tier.business_id and keep.tier_id = tier.id
   where tier.business_id = p_business;

  select coalesce(jsonb_agg(jsonb_build_object(
           'id', product.id,
           'name', product.name,
           'size_ml', product.size_ml,
           'price_cents', product.retail_price_cents,
           'is_bottle', product.size_ml is not null
         ) order by (product.size_ml is null), product.name, product.id), '[]'::jsonb)
    into v_products
    from public.products product
   where product.business_id = p_business and product.active;

  return jsonb_build_object(
    'status', 'ok',
    'keep_days', app.bar_keep_days_v275(p_business),
    'can_edit', app.is_salon_owner(p_business),
    'tiers', v_tiers,
    'products', v_products);
end;
$$;

-- Declarative, like bar_save_setup_v275: the caller sends the whole tier list it wants, a null
-- keep_days clears that tier's override, and a tier that is not the business's own is refused
-- rather than silently stored — a soft reference earns its keep only if it is validated on write.
create or replace function public.bar_save_tier_keep_days_v278(
  p_business uuid,
  p_tiers jsonb
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_actor uuid := auth.uid();
  v_entry jsonb;
  v_tier uuid;
  v_days integer;
  v_kept uuid[] := '{}'::uuid[];
begin
  perform app.require_bar_business_v275(p_business);
  if v_actor is null then
    raise exception 'authenticated staff required' using errcode = '28000';
  end if;
  if not app.is_salon_owner(p_business) then
    raise exception 'only the owner can change bottle keep setup' using errcode = '42501';
  end if;
  if p_tiers is not null and jsonb_typeof(p_tiers) <> 'array' then
    raise exception 'tier keep windows must be a list' using errcode = '22023';
  end if;

  for v_entry in select value from jsonb_array_elements(coalesce(p_tiers, '[]'::jsonb)) loop
    v_tier := nullif(v_entry->>'tier_id', '')::uuid;
    if v_tier is null then
      raise exception 'a tier keep window needs a tier' using errcode = '22023';
    end if;
    if not exists (select 1 from public.loyalty_tiers tier
                    where tier.id = v_tier and tier.business_id = p_business) then
      raise exception 'that tier does not belong to this business' using errcode = '22023';
    end if;
    v_days := nullif(v_entry->>'keep_days', '')::integer;
    if v_days is null then
      delete from public.bar_tier_keep_days_v278 keep
       where keep.business_id = p_business and keep.tier_id = v_tier;
    else
      if v_days < 1 or v_days > 365 then
        raise exception 'a tier keep window must be between 1 and 365 days' using errcode = '22023';
      end if;
      insert into public.bar_tier_keep_days_v278 (business_id, tier_id, keep_days, updated_at, updated_by)
      values (p_business, v_tier, v_days, now(), v_actor)
      on conflict (business_id, tier_id) do update
        set keep_days = excluded.keep_days,
            updated_at = excluded.updated_at,
            updated_by = excluded.updated_by;
    end if;
    v_kept := array_append(v_kept, v_tier);
  end loop;

  -- A tier absent from the submitted list has no override. Deleting rather than keeping a stale
  -- row means the Auto window can never be governed by a number the owner can no longer see.
  delete from public.bar_tier_keep_days_v278 keep
   where keep.business_id = p_business
     and not (keep.tier_id = any (v_kept));

  return public.bar_get_bottle_setup_v278(p_business);
end;
$$;

-- Mark an existing product as a bottle, unmark it, or quick-add one. p_product null = create.
-- A null p_size_ml on an existing product means "this is not a bottle" and removes it from the
-- park picker without touching the product itself, because a bar still sells it.
create or replace function public.bar_save_bottle_product_v278(
  p_business uuid,
  p_product uuid,
  p_name text,
  p_size_ml integer,
  p_price_cents integer
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_actor uuid := auth.uid();
  v_name text := nullif(btrim(coalesce(p_name, '')), '');
  v_updated uuid;
begin
  perform app.require_bar_business_v275(p_business);
  if v_actor is null then
    raise exception 'authenticated staff required' using errcode = '28000';
  end if;
  if not app.is_salon_owner(p_business) then
    raise exception 'only the owner can change the bottle catalogue' using errcode = '42501';
  end if;
  if p_size_ml is not null and (p_size_ml < 100 or p_size_ml > 5000) then
    raise exception 'a bottle is between 100ml and 5000ml' using errcode = '22023';
  end if;

  if p_product is null then
    if v_name is null then
      raise exception 'name the bottle' using errcode = '22023';
    end if;
    if length(v_name) > 120 then
      raise exception 'a bottle name is limited to 120 characters' using errcode = '22023';
    end if;
    if p_size_ml is null then
      raise exception 'a new bottle needs its size in millilitres' using errcode = '22023';
    end if;
    if p_price_cents is not null and (p_price_cents < 0 or p_price_cents > 2147483647) then
      raise exception 'the price is not a valid amount' using errcode = '22023';
    end if;
    insert into public.products (business_id, name, retail_price_cents, size_ml, active)
    values (p_business, v_name, coalesce(p_price_cents, 0), p_size_ml, true);
  else
    update public.products product
       set size_ml = p_size_ml
     where product.id = p_product and product.business_id = p_business
    returning product.id into v_updated;
    if v_updated is null then
      raise exception 'product not found' using errcode = '22023';
    end if;
  end if;

  return public.bar_get_bottle_setup_v278(p_business);
end;
$$;

-- The park dialog must SHOW the date it is about to write, and under Auto that date depends on the
-- customer that was just chosen. Resolving it in the browser would mean reproducing the tier rule
-- there; asking for it is one small read and keeps a single source of truth for the number.
create or replace function public.bar_client_keep_days_v278(p_business uuid, p_client uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
begin
  perform app.require_bar_business_v275(p_business);
  perform app.require_bar_staff_v275(p_business, false);
  if p_client is null then
    raise exception 'choose a customer' using errcode = '22023';
  end if;
  if not exists (select 1 from public.clients client
                  where client.id = p_client and client.business_id = p_business) then
    raise exception 'customer not found' using errcode = '22023';
  end if;
  return jsonb_build_object(
    'status', 'ok',
    'keep_days', app.bar_keep_days_for_client_v278(p_business, p_client),
    'default_keep_days', app.bar_keep_days_v275(p_business),
    'tier_name', app.bar_tier_name_v278(p_business, p_client));
end;
$$;

-- ---------------------------------------------------------------------------
-- 7. Park, with the reference bar's five extra answers.
-- ---------------------------------------------------------------------------

create or replace function public.park_bottle_v278(
  p_business uuid,
  p_client uuid,
  p_label text,
  p_product uuid,
  p_size_ml integer,
  p_fill_percent integer,
  p_storage_location uuid,
  p_reentry_limit integer,
  p_branch uuid,
  p_sale uuid,
  p_expiry_mode text,
  p_expiry_date date,
  p_notify_channel text,
  p_note text,
  p_purchased_on date,
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
  v_expires timestamptz;
  v_keep integer;
  v_year integer;
  v_seq integer;
  v_existing uuid;
  v_bottle public.bar_bottles%rowtype;
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

  v_existing := app.bar_bottle_replayed_v275(p_business, v_key);
  if v_existing is not null then
    select * into v_bottle from public.bar_bottles bottle where bottle.id = v_existing;
    return jsonb_build_object('status', 'duplicate_ignored',
      'bottle', app.bar_bottle_json_v275(v_bottle));
  end if;

  -- The size ALWAYS comes from the catalogue when a catalogue bottle was picked. The browser is
  -- not trusted to have copied it, because the whole point of item 2 is that it is never typed.
  if p_product is not null then
    select coalesce(product.size_ml, v_size) into v_size
      from public.products product
     where product.id = p_product and product.business_id = p_business;
    if not found then
      raise exception 'that bottle is not in your catalogue' using errcode = '22023';
    end if;
  end if;

  -- Locking the settings row serialises serial allocation for this business, exactly as V275 does:
  -- a duplicate PK-YYYY-NNNN on a physical shelf label is the failure this module exists to
  -- prevent.
  insert into public.bar_bottle_settings (business_id) values (p_business)
  on conflict (business_id) do nothing;
  select setting.keep_days into v_keep
    from public.bar_bottle_settings setting
   where setting.business_id = p_business
     for update;

  v_expires := app.bar_bottle_expiry_v278(p_business, p_client, v_mode, p_expiry_date);

  v_year := extract(year from (now() at time zone 'Asia/Singapore'))::integer;
  select coalesce(max(bottle.serial_seq), 0) + 1 into v_seq
    from public.bar_bottles bottle
   where bottle.business_id = p_business and bottle.serial_year = v_year;

  insert into public.bar_bottles (
    business_id, branch_id, client_id, serial_year, serial_seq, label, product_id,
    size_ml, fill_percent, storage_location_id, reentry_limit, status,
    parked_at, expires_at, sale_id, expiry_mode, notify_channel, purchased_on
  ) values (
    p_business, p_branch, p_client, v_year, v_seq, v_label, p_product,
    v_size, v_fill, p_storage_location, p_reentry_limit, 'stored',
    now(), v_expires, p_sale, v_mode, v_channel, p_purchased_on
  )
  returning * into v_bottle;

  -- Exactly ONE event per write stays true: a park note rides in the park event's detail rather
  -- than becoming a second row, so the idempotency key remains one key for one intention.
  insert into public.bar_bottle_events (business_id, bottle_id, kind, actor, idem_key, detail)
  values (p_business, v_bottle.id, 'park', v_actor, v_key, jsonb_build_object(
    'serial_code', v_bottle.serial_code,
    'client_id', v_bottle.client_id,
    'fill_percent', v_bottle.fill_percent,
    'expiry_mode', v_bottle.expiry_mode,
    'expires_at', v_bottle.expires_at,
    'notify_channel', v_bottle.notify_channel,
    'purchased_on', v_bottle.purchased_on,
    'storage_location_id', v_bottle.storage_location_id,
    'sale_id', v_bottle.sale_id,
    'note', v_note));

  return jsonb_build_object('status', 'ok', 'bottle', app.bar_bottle_json_v275(v_bottle));
end;
$$;

-- ---------------------------------------------------------------------------
-- 8. The card actions: edit expiry, note, move, purchase date, notify.
--    Each holds the industry gate FIRST, then the staff gate, then the replay probe, then the row
--    lock, then exactly one evidence row — the V275 shape, unchanged.
-- ---------------------------------------------------------------------------

create or replace function public.set_bottle_expiry_v278(
  p_business uuid,
  p_bottle uuid,
  p_expiry_mode text,
  p_expiry_date date,
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
  v_mode text := lower(btrim(coalesce(p_expiry_mode, '')));
  v_existing uuid;
  v_bottle public.bar_bottles%rowtype;
  v_before timestamptz;
  v_before_mode text;
  v_next timestamptz;
begin
  perform app.require_bar_business_v275(p_business);
  perform app.require_bar_staff_v275(p_business, true);
  if v_key is null then
    raise exception 'idempotency key required' using errcode = '22023';
  end if;
  if v_mode not in ('auto', 'custom', 'none') then
    raise exception 'expiry is automatic, a chosen date, or none' using errcode = '22023';
  end if;

  v_existing := app.bar_bottle_replayed_v275(p_business, v_key);
  if v_existing is not null then
    select * into v_bottle from public.bar_bottles bottle where bottle.id = v_existing;
    return jsonb_build_object('status', 'duplicate_ignored',
      'bottle', app.bar_bottle_json_v275(v_bottle));
  end if;

  select * into v_bottle from public.bar_bottles bottle
   where bottle.id = p_bottle and bottle.business_id = p_business for update;
  if not found then
    raise exception 'bottle not found' using errcode = '22023';
  end if;
  if v_bottle.status in ('finished', 'transferred', 'removed') then
    raise exception 'this bottle is closed' using errcode = '22023';
  end if;

  v_before := v_bottle.expires_at;
  v_before_mode := v_bottle.expiry_mode;
  v_next := app.bar_bottle_expiry_v278(p_business, v_bottle.client_id, v_mode, p_expiry_date);

  update public.bar_bottles bottle
     set expires_at = v_next,
         expiry_mode = v_mode,
         status = case when bottle.status = 'expired' then 'stored' else bottle.status end,
         updated_at = now()
   where bottle.id = v_bottle.id
  returning * into v_bottle;

  insert into public.bar_bottle_events (business_id, bottle_id, kind, actor, idem_key, detail)
  values (p_business, v_bottle.id, 'extend', v_actor, v_key,
    jsonb_build_object('from', v_before, 'to', v_next,
      'from_mode', v_before_mode, 'to_mode', v_mode, 'edited', true));

  return jsonb_build_object('status', 'ok', 'bottle', app.bar_bottle_json_v275(v_bottle));
end;
$$;

create or replace function public.add_bottle_note_v278(
  p_business uuid,
  p_bottle uuid,
  p_note text,
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
  v_note text := nullif(btrim(coalesce(p_note, '')), '');
  v_existing uuid;
  v_bottle public.bar_bottles%rowtype;
begin
  perform app.require_bar_business_v275(p_business);
  perform app.require_bar_staff_v275(p_business, true);
  if v_key is null then
    raise exception 'idempotency key required' using errcode = '22023';
  end if;
  if v_note is null then
    raise exception 'type the note first' using errcode = '22023';
  end if;
  if length(v_note) > 500 then
    raise exception 'a note is limited to 500 characters' using errcode = '22023';
  end if;

  v_existing := app.bar_bottle_replayed_v275(p_business, v_key);
  if v_existing is not null then
    select * into v_bottle from public.bar_bottles bottle where bottle.id = v_existing;
    return jsonb_build_object('status', 'duplicate_ignored',
      'bottle', app.bar_bottle_json_v275(v_bottle));
  end if;

  select * into v_bottle from public.bar_bottles bottle
   where bottle.id = p_bottle and bottle.business_id = p_business for update;
  if not found then
    raise exception 'bottle not found' using errcode = '22023';
  end if;

  -- A note changes no state; it is pure evidence, which is why the bottle row is only touched to
  -- move its updated_at. The note itself lives in the append-only log where it cannot be edited.
  update public.bar_bottles bottle set updated_at = now() where bottle.id = v_bottle.id
  returning * into v_bottle;

  insert into public.bar_bottle_events (business_id, bottle_id, kind, actor, idem_key, detail)
  values (p_business, v_bottle.id, 'note', v_actor, v_key,
    jsonb_build_object('note', v_note));

  return jsonb_build_object('status', 'ok', 'bottle', app.bar_bottle_json_v275(v_bottle));
end;
$$;

create or replace function public.move_bottle_v278(
  p_business uuid,
  p_bottle uuid,
  p_storage_location uuid,
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
  v_existing uuid;
  v_bottle public.bar_bottles%rowtype;
  v_before uuid;
  v_before_name text;
  v_after_name text;
begin
  perform app.require_bar_business_v275(p_business);
  perform app.require_bar_staff_v275(p_business, true);
  if v_key is null then
    raise exception 'idempotency key required' using errcode = '22023';
  end if;

  v_existing := app.bar_bottle_replayed_v275(p_business, v_key);
  if v_existing is not null then
    select * into v_bottle from public.bar_bottles bottle where bottle.id = v_existing;
    return jsonb_build_object('status', 'duplicate_ignored',
      'bottle', app.bar_bottle_json_v275(v_bottle));
  end if;

  select * into v_bottle from public.bar_bottles bottle
   where bottle.id = p_bottle and bottle.business_id = p_business for update;
  if not found then
    raise exception 'bottle not found' using errcode = '22023';
  end if;
  if v_bottle.status in ('finished', 'transferred', 'removed') then
    raise exception 'this bottle is closed' using errcode = '22023';
  end if;
  if p_storage_location is not null
     and not exists (select 1 from public.bar_storage_locations location
                      where location.id = p_storage_location
                        and location.business_id = p_business
                        and location.active) then
    raise exception 'that storage place is not on your list' using errcode = '22023';
  end if;

  v_before := v_bottle.storage_location_id;
  select location.name into v_before_name from public.bar_storage_locations location
   where location.id = v_before;
  select location.name into v_after_name from public.bar_storage_locations location
   where location.id = p_storage_location;

  update public.bar_bottles bottle
     set storage_location_id = p_storage_location, updated_at = now()
   where bottle.id = v_bottle.id
  returning * into v_bottle;

  insert into public.bar_bottle_events (business_id, bottle_id, kind, actor, idem_key, detail)
  values (p_business, v_bottle.id, 'move', v_actor, v_key,
    jsonb_build_object('from', v_before, 'to', p_storage_location,
      'from_name', v_before_name, 'to_name', v_after_name));

  return jsonb_build_object('status', 'ok', 'bottle', app.bar_bottle_json_v275(v_bottle));
end;
$$;

create or replace function public.set_bottle_purchased_on_v278(
  p_business uuid,
  p_bottle uuid,
  p_purchased_on date,
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
  v_existing uuid;
  v_bottle public.bar_bottles%rowtype;
  v_before date;
begin
  perform app.require_bar_business_v275(p_business);
  perform app.require_bar_staff_v275(p_business, true);
  if v_key is null then
    raise exception 'idempotency key required' using errcode = '22023';
  end if;
  if p_purchased_on is not null
     and p_purchased_on > ((now() at time zone 'Asia/Singapore')::date + 1) then
    raise exception 'a bottle cannot have been bought in the future' using errcode = '22023';
  end if;

  v_existing := app.bar_bottle_replayed_v275(p_business, v_key);
  if v_existing is not null then
    select * into v_bottle from public.bar_bottles bottle where bottle.id = v_existing;
    return jsonb_build_object('status', 'duplicate_ignored',
      'bottle', app.bar_bottle_json_v275(v_bottle));
  end if;

  select * into v_bottle from public.bar_bottles bottle
   where bottle.id = p_bottle and bottle.business_id = p_business for update;
  if not found then
    raise exception 'bottle not found' using errcode = '22023';
  end if;
  v_before := v_bottle.purchased_on;

  update public.bar_bottles bottle
     set purchased_on = p_purchased_on, updated_at = now()
   where bottle.id = v_bottle.id
  returning * into v_bottle;

  insert into public.bar_bottle_events (business_id, bottle_id, kind, actor, idem_key, detail)
  values (p_business, v_bottle.id, 'purchase', v_actor, v_key,
    jsonb_build_object('from', v_before, 'to', p_purchased_on));

  return jsonb_build_object('status', 'ok', 'bottle', app.bar_bottle_json_v275(v_bottle));
end;
$$;

-- ---------------------------------------------------------------------------
-- 9. Notify. WhatsApp and email remain deferred platform-wide, so the honest thing a Notify
--    button can do today is put the message where the customer will actually see it: the in-app
--    inbox the wallet already renders, on the SAME rails V122's promotion alerts use.
--
--    The reuse is not free — the inbox is a deliberately closed vocabulary. Four constraints and
--    one availability function have to learn this kind, and they are extended here rather than
--    worked around, because a free-text inbox would defeat the reason the vocabulary exists (no
--    prices, no identifiers, no private configuration, ever, in a customer notification).
--
--    The customer's own preference still decides. If there is no verified link, or the customer
--    has turned value_expiry off, the RPC records the 'reminder' event anyway and REPORTS which
--    happened, so a bartender is told "no app yet" instead of believing a message was sent.
-- ---------------------------------------------------------------------------

alter table public.customer_in_app_inbox_events
  drop constraint customer_in_app_inbox_events_source_kind_check,
  add constraint customer_in_app_inbox_events_source_kind_check check (source_kind in (
    'c44_actionable_wallet', 'c45_birthday_benefit', 'v33_booking_action',
    'v48_appointment_reschedule', 'v122_promotion_new', 'v122_promotion_expiry',
    'v278_bottle_reminder'
  )),
  drop constraint customer_in_app_inbox_events_title_check,
  add constraint customer_in_app_inbox_events_title_check check (title in (
    'Points expire soon', 'Stamps expire soon', 'A reward is ready', 'One visit to go',
    'Birthday benefit ready', 'Appointment request received', 'Appointment time changed',
    'Points expire tomorrow', 'Stamps expire tomorrow', 'Points expire within 3 days',
    'Stamps expire within 3 days', 'Reward unlocked!', 'Quest almost complete',
    'Birthday surprise unlocked', 'New promotion available', 'Promotion ending soon',
    'Your bottle is waiting'
  )),
  drop constraint customer_in_app_inbox_events_body_check,
  add constraint customer_in_app_inbox_events_body_check check (body in (
    'Open this business wallet to review your points.',
    'Open this business wallet to review your stamps.',
    'Open this business wallet to view the available reward.',
    'One qualifying visit remains before your next reward.',
    'Open this business wallet to view your birthday benefit.',
    'Open this business wallet to review your appointment request.',
    'Open this business wallet to review your updated appointment.',
    'Open this programme now to review your expiring points.',
    'Open this programme now to review your expiring stamps.',
    'Open this programme to view and redeem your reward.',
    'Open this programme to view your birthday benefit.',
    'Open this programme to view the latest promotion.',
    'Open this programme before the current promotion ends.',
    'Open this business wallet to see the bottle being kept for you.'
  ));

-- Without this, the row would be written and then filtered out of every read: the inbox reader
-- asks this function whether a kind is available at all.
create or replace function app.c46_inbox_source_available(
  p_source_kind text, p_actionable_wallet_enabled boolean
)
returns boolean language sql immutable
set search_path to 'pg_catalog','pg_temp'
as $$
  select $1 in (
    'v33_booking_action','v48_appointment_reschedule',
    'v122_promotion_new','v122_promotion_expiry','v278_bottle_reminder'
  ) or (
    coalesce($2,false)
    and $1 in ('c44_actionable_wallet','c45_birthday_benefit')
  )
$$;

create or replace function public.notify_bottle_v278(
  p_business uuid,
  p_bottle uuid,
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
  v_existing uuid;
  v_bottle public.bar_bottles%rowtype;
  v_link public.customer_links%rowtype;
  v_opted boolean := false;
  v_delivery text := 'no_customer_app';
  v_inserted integer := 0;
begin
  perform app.require_bar_business_v275(p_business);
  perform app.require_bar_staff_v275(p_business, true);
  if v_key is null then
    raise exception 'idempotency key required' using errcode = '22023';
  end if;

  v_existing := app.bar_bottle_replayed_v275(p_business, v_key);
  if v_existing is not null then
    select * into v_bottle from public.bar_bottles bottle where bottle.id = v_existing;
    return jsonb_build_object('status', 'duplicate_ignored',
      'bottle', app.bar_bottle_json_v275(v_bottle), 'delivery', 'duplicate_ignored');
  end if;

  select * into v_bottle from public.bar_bottles bottle
   where bottle.id = p_bottle and bottle.business_id = p_business for update;
  if not found then
    raise exception 'bottle not found' using errcode = '22023';
  end if;
  if v_bottle.status in ('finished', 'transferred', 'removed') then
    raise exception 'this bottle is closed' using errcode = '22023';
  end if;

  select * into v_link from public.customer_links link
   where link.business_id = p_business
     and link.client_id = v_bottle.client_id
     and link.state = 'verified'
     and link.unlinked_at is null
   order by link.created_at
   limit 1;

  if v_link.id is not null then
    select coalesce(preference.opted_in, false) into v_opted
      from public.customer_notification_preferences preference
     where preference.business_id = v_link.business_id
       and preference.identity_id = v_link.identity_id
       and preference.auth_user_id = v_link.auth_user_id
       and preference.link_id = v_link.id
       and preference.channel = 'in_app'
       and preference.topic = 'value_expiry';
    v_opted := coalesce(v_opted, false);
    if v_opted then
      insert into public.customer_in_app_inbox_events(
        business_id, identity_id, auth_user_id, link_id, client_id,
        source_kind, topic, route_key, source_fingerprint, dedupe_key,
        title, body, deadline_at
      ) values (
        v_link.business_id, v_link.identity_id, v_link.auth_user_id, v_link.id, v_link.client_id,
        'v278_bottle_reminder', 'value_expiry', 'wallet_business',
        app.c46_sha256_hex(jsonb_build_object(
          'bottle_id', v_bottle.id, 'idem_key', v_key)::text),
        app.c46_sha256_hex(jsonb_build_object(
          'identity_id', v_link.identity_id, 'bottle_id', v_bottle.id, 'idem_key', v_key)::text),
        'Your bottle is waiting',
        'Open this business wallet to see the bottle being kept for you.',
        v_bottle.expires_at
      )
      on conflict (identity_id, dedupe_key) do nothing;
      get diagnostics v_inserted = row_count;
      v_delivery := case when v_inserted > 0 then 'in_app' else 'already_notified' end;
    else
      v_delivery := 'opted_out';
    end if;
  end if;

  insert into public.bar_bottle_events (business_id, bottle_id, kind, actor, idem_key, detail)
  values (p_business, v_bottle.id, 'reminder', v_actor, v_key,
    jsonb_build_object('delivery', v_delivery,
      'notify_channel', v_bottle.notify_channel,
      'expires_at', v_bottle.expires_at));

  return jsonb_build_object('status', 'ok', 'delivery', v_delivery,
    'bottle', app.bar_bottle_json_v275(v_bottle));
end;
$$;

-- ---------------------------------------------------------------------------
-- 10. Grants. A create-from-scratch replay would otherwise inherit PostgreSQL's default
--     EXECUTE-to-PUBLIC on every function above. One explicit pair per overload.
-- ---------------------------------------------------------------------------

revoke all on function public.bar_get_setup_v275(uuid) from public, anon, authenticated;
revoke all on function public.list_bar_bottles_v275(uuid, uuid, text, text, integer, uuid, integer) from public, anon, authenticated;
revoke all on function public.customer_get_bottles_v275(text) from public, anon, authenticated;
revoke all on function public.bar_get_bottle_setup_v278(uuid) from public, anon, authenticated;
revoke all on function public.bar_save_tier_keep_days_v278(uuid, jsonb) from public, anon, authenticated;
revoke all on function public.bar_save_bottle_product_v278(uuid, uuid, text, integer, integer) from public, anon, authenticated;
revoke all on function public.bar_client_keep_days_v278(uuid, uuid) from public, anon, authenticated;
revoke all on function public.park_bottle_v278(uuid, uuid, text, uuid, integer, integer, uuid, integer, uuid, uuid, text, date, text, text, date, text) from public, anon, authenticated;
revoke all on function public.set_bottle_expiry_v278(uuid, uuid, text, date, text) from public, anon, authenticated;
revoke all on function public.add_bottle_note_v278(uuid, uuid, text, text) from public, anon, authenticated;
revoke all on function public.move_bottle_v278(uuid, uuid, uuid, text) from public, anon, authenticated;
revoke all on function public.set_bottle_purchased_on_v278(uuid, uuid, date, text) from public, anon, authenticated;
revoke all on function public.notify_bottle_v278(uuid, uuid, text) from public, anon, authenticated;

grant execute on function public.bar_get_setup_v275(uuid) to authenticated;
grant execute on function public.list_bar_bottles_v275(uuid, uuid, text, text, integer, uuid, integer) to authenticated;
grant execute on function public.customer_get_bottles_v275(text) to authenticated;
grant execute on function public.bar_get_bottle_setup_v278(uuid) to authenticated;
grant execute on function public.bar_save_tier_keep_days_v278(uuid, jsonb) to authenticated;
grant execute on function public.bar_save_bottle_product_v278(uuid, uuid, text, integer, integer) to authenticated;
grant execute on function public.bar_client_keep_days_v278(uuid, uuid) to authenticated;
grant execute on function public.park_bottle_v278(uuid, uuid, text, uuid, integer, integer, uuid, integer, uuid, uuid, text, date, text, text, date, text) to authenticated;
grant execute on function public.set_bottle_expiry_v278(uuid, uuid, text, date, text) to authenticated;
grant execute on function public.add_bottle_note_v278(uuid, uuid, text, text) to authenticated;
grant execute on function public.move_bottle_v278(uuid, uuid, uuid, text) to authenticated;
grant execute on function public.set_bottle_purchased_on_v278(uuid, uuid, date, text) to authenticated;
grant execute on function public.notify_bottle_v278(uuid, uuid, text) to authenticated;

commit;
