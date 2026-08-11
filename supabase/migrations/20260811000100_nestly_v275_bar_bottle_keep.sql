-- NESTLY v275 — BAR SECTOR: BOTTLE KEEP
--
-- Owner brief 2026-08-11 (reference product: bottlebank.io): a bar parks a customer's leftover
-- bottle, tracks how full it is and how long it may be kept, and the customer sees that bottle
-- inside the business's page in the customer app. The wedge over the reference product is that
-- Peekaa already owns the retention machinery it lacks: a bottle purchase is an ordinary sale,
-- so it earns points and moves the spend tier with no new plumbing at all.
--
-- OWNER AMENDMENTS that this migration implements literally, overriding the design document:
--
--   1. VIP is the EXISTING tier mechanism. There is deliberately NO per-tier keep-days column on
--      loyalty_tiers and no other tier column anywhere in this file. Tiers move because the
--      bottle purchase is a sale — that is the whole integration, and adding a per-tier keep
--      window would have invented a second, competing source of truth for the same number.
--   2. The keep window is ONE number per business (30 days standard, 1..365), set in Operations
--      setup. Not per tier, not per bottle type, not per branch.
--   3. Storage locations are the bar's OWN list, defined in Operations setup ("Shelf A",
--      "Chiller 2"). Parking picks one; the bottle card shows where it is. They are therefore
--      rows, not free text — a typo'd shelf name is the difference between finding a customer's
--      bottle and losing it, and a free-text column cannot be corrected in one place.
--   4. HARD bar-only gating, SERVER-SIDE. Bottle keep is a SaaS module exclusive to
--      industry='bar'. Hiding the nav is not a gate: anyone can type a hash or call PostgREST
--      directly. EVERY public RPC below calls app.require_bar_business_v275() as its first
--      authorisation step, so a non-bar tenant gets 42501 with a plain message no matter how it
--      arrives. The UI gating in app/app.js is a courtesy on top of this, never instead of it.
--
-- WHAT A BOTTLE IS, AND WHAT IT IS NOT. A parked bottle is the customer's PROPERTY, not stored
-- value. It never touches credit_ledger or points_ledger. Only its purchase sale does, through
-- the ordinary v10 policy engine — which is why the only money-side change here is one new
-- sales.kind ('bottle_keep') and its policy default row. That keeps bottle keep outside the
-- stored-value regulatory surface entirely, and it keeps a single earn path.
--
-- EVIDENCE. bar_bottle_events is append-only (reusing the reviewed v33 guard) and EVERY write in
-- every RPC records exactly one row. A product that stores customers' physical property must be
-- able to answer "my bottle was fuller than that" and "who moved it" with a record, not a
-- recollection; this is the same discipline the credit ledger is held to.
--
-- IDEMPOTENCY. Every mutating RPC takes an idempotency key, and the key is unique on the EVENT
-- table. A double-tapped Park, Fill, Extend, Transfer or Finish therefore returns
-- status='duplicate_ignored' and changes nothing — the evidence row is the dedupe key, so a
-- replay cannot produce a second event either.
--
-- NOT IN THIS INCREMENT (deliberately, per the owner's instruction): the daily expiry sweep
-- cron, and expiry reminders (inbox/push/WhatsApp). Those ride the deferred comms work.
-- expires_at is nevertheless computed and stored correctly on every park and extend, so the
-- sweep is a later cron over an already-correct column rather than a backfill.

begin;

-- ---------------------------------------------------------------------------
-- 1. Sector wiring. 'bar' did not exist as a sector at all (verified against production
--    2026-08-11: sector_profiles held fnb/facial/fitness/salon/massage/other/retail, and no
--    business carried industry='bar'). Without it, industry='bar' is unreachable and the
--    'bottles' module can never be entitled — the hard gate would gate an empty set.
--    A bar takes bookings and seats guests like F&B, so its bundle is the fnb bundle plus
--    bottles plus the packages/memberships a bar genuinely sells. Appointments is included for
--    parity with the fnb bundle; the nav hides it for seated sectors already.
-- ---------------------------------------------------------------------------

insert into public.module_registry (module_key, label, requires_modules, recommended_modules, sort_order)
values ('bottles', 'Bottles', array['clients', 'sales']::text[], '{}'::text[], 105)
on conflict (module_key) do nothing;

insert into public.sector_profiles (sector_key, label, active)
values ('bar', 'Bar / Pub', true)
on conflict (sector_key) do nothing;

insert into public.sector_bundle_versions (sector_key, version, label, modules, status, published_at)
values ('bar', 1, 'Bar core',
  array['dashboard', 'till', 'clients', 'appointments', 'sales', 'services', 'bookings',
        'waitlist', 'inventory', 'bottles', 'loyalty', 'retention', 'referrals', 'memberships',
        'giftcards', 'reports', 'staffperf', 'dailyreport', 'pnl', 'expenses',
        'customerintel']::text[],
  'published', now())
on conflict (sector_key, version) do nothing;

-- ---------------------------------------------------------------------------
-- 2. The sale kind. Buying a bottle IS revenue, IS a visit and DOES earn points — a bar's whole
--    loyalty story is "the bottle you bought moved your tier". The three flags are therefore all
--    true, unlike gift_card (cash collected, not revenue) and package (bought, not visited).
--    Both check constraints and the defaults function are edited from their LIVE definitions
--    with comment-free needles and explicit raises, because the Supabase MCP apply strips
--    full-line comments — a comment-anchored needle matches a psql rehearsal but not production.
-- ---------------------------------------------------------------------------

do $v275_sales_kind$
declare
  v_def text;
begin
  select pg_get_constraintdef(constraint_row.oid) into v_def
    from pg_constraint constraint_row
   where constraint_row.conrelid = 'public.sales'::regclass
     and constraint_row.conname = 'sales_kind_check';
  if v_def is null then
    raise exception 'v275: sales_kind_check not found - refusing to guess the legal kind set';
  end if;
  if position('bottle_keep' in v_def) > 0 then
    return;
  end if;
  if position('''package''' in v_def) = 0 then
    raise exception 'v275: sales_kind_check does not contain the expected package kind';
  end if;
  execute 'alter table public.sales drop constraint sales_kind_check';
  execute 'alter table public.sales add constraint sales_kind_check check (kind in '
       || '(''service'', ''retail'', ''membership'', ''quick_sale'', ''gift_card'', ''package'', ''bottle_keep''))';
end
$v275_sales_kind$;

do $v275_policy_kind$
declare
  v_def text;
begin
  select pg_get_constraintdef(constraint_row.oid) into v_def
    from pg_constraint constraint_row
   where constraint_row.conrelid = 'public.sale_policies'::regclass
     and constraint_row.conname = 'sale_policies_kind_check';
  if v_def is null then
    raise exception 'v275: sale_policies_kind_check not found - refusing to guess the legal kind set';
  end if;
  if position('bottle_keep' in v_def) > 0 then
    return;
  end if;
  if position('''package''' in v_def) = 0 then
    raise exception 'v275: sale_policies_kind_check does not contain the expected package kind';
  end if;
  execute 'alter table public.sale_policies drop constraint sale_policies_kind_check';
  execute 'alter table public.sale_policies add constraint sale_policies_kind_check check (kind in '
       || '(''service'', ''retail'', ''quick_sale'', ''membership'', ''gift_card'', ''package'', ''bottle_keep''))';
end
$v275_policy_kind$;

do $v275_policy_defaults$
declare
  v_def text;
  v_old text;
  v_new text;
begin
  select pg_get_functiondef(proc.oid) into v_def
    from pg_proc proc
    join pg_namespace space on space.oid = proc.pronamespace
   where space.nspname = 'app' and proc.proname = 'sale_policy_defaults';
  if v_def is null then
    raise exception 'v275: app.sale_policy_defaults not found - refusing to guess';
  end if;
  if position('bottle_keep' in v_def) > 0 then
    return;
  end if;
  v_old := '    (''package''::text,    true,  false, true)';
  v_new := '    (''package''::text,    true,  false, true),' || chr(10)
        || '    (''bottle_keep''::text, true,  true,  true)';
  if position(v_old in v_def) = 0 then
    raise exception 'v275: app.sale_policy_defaults package-row needle not found';
  end if;
  v_def := replace(v_def, v_old, v_new);
  execute v_def;
end
$v275_policy_defaults$;

-- ---------------------------------------------------------------------------
-- 3. Tables. RLS on, ZERO policies, ACL revoked from every browser role: these are RPC-only
--    tables in the house style, so a PostgREST caller sees nothing at all and the SECURITY
--    DEFINER functions below are the only door.
-- ---------------------------------------------------------------------------

create table public.bar_bottle_settings (
  business_id uuid primary key references public.businesses(id) on delete cascade,
  keep_days integer not null default 30 check (keep_days between 1 and 365),
  updated_at timestamptz not null default now(),
  updated_by uuid
);
comment on table public.bar_bottle_settings is
  'One keep window per business (owner amendment 2: one number, set in Operations setup). Absent row = the 30-day standard.';

alter table public.bar_bottle_settings enable row level security;
revoke all privileges on table public.bar_bottle_settings from public, anon, authenticated;

create table public.bar_storage_locations (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  name text not null check (length(btrim(name)) between 1 and 60),
  active boolean not null default true,
  sort integer not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint bar_storage_locations_id_business_uk unique (id, business_id),
  constraint bar_storage_locations_business_name_uk unique (business_id, name)
);
comment on table public.bar_storage_locations is
  'The bar''s own shelf/chiller list. Rows rather than free text so a shelf can be renamed in one place instead of drifting across bottles.';

alter table public.bar_storage_locations enable row level security;
revoke all privileges on table public.bar_storage_locations from public, anon, authenticated;

create index bar_storage_locations_business_idx
  on public.bar_storage_locations (business_id, active, sort, name);

create table public.bar_bottles (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete restrict,
  branch_id uuid references public.branches(id) on delete restrict,
  client_id uuid not null references public.clients(id) on delete restrict,
  serial_year integer not null check (serial_year between 2000 and 2999),
  serial_seq integer not null check (serial_seq > 0),
  serial_code text generated always as
    ('PK-' || serial_year::text || '-' || lpad(serial_seq::text, 4, '0')) stored,
  label text check (label is null or length(btrim(label)) between 1 and 120),
  product_id uuid references public.products(id) on delete restrict,
  size_ml integer check (size_ml is null or size_ml between 1 and 20000),
  fill_percent integer not null default 100 check (fill_percent between 0 and 100),
  storage_location_id uuid references public.bar_storage_locations(id) on delete restrict,
  reentry_limit integer check (reentry_limit is null or reentry_limit between 1 and 50),
  status text not null default 'stored'
    check (status in ('stored', 'called', 'at_table', 'finished', 'expired', 'transferred', 'removed')),
  parked_at timestamptz not null default now(),
  expires_at timestamptz not null,
  sale_id uuid references public.sales(id) on delete restrict,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint bar_bottles_serial_uk unique (business_id, serial_year, serial_seq),
  constraint bar_bottles_named check (
    product_id is not null or nullif(btrim(coalesce(label, '')), '') is not null
  ),
  constraint bar_bottles_branch_fk foreign key (branch_id, business_id)
    references public.branches(id, business_id) on delete restrict,
  constraint bar_bottles_client_fk foreign key (client_id, business_id)
    references public.clients(id, business_id) on delete restrict,
  constraint bar_bottles_product_fk foreign key (product_id, business_id)
    references public.products(id, business_id) on delete restrict,
  constraint bar_bottles_location_fk foreign key (storage_location_id, business_id)
    references public.bar_storage_locations(id, business_id) on delete restrict,
  constraint bar_bottles_sale_fk foreign key (sale_id, business_id)
    references public.sales(id, business_id) on delete restrict
);
comment on table public.bar_bottles is
  'One physical parked bottle. Property, not stored value: nothing here touches the credit or points ledgers - only the purchase sale does, through the ordinary v10 policy engine.';

alter table public.bar_bottles enable row level security;
revoke all privileges on table public.bar_bottles from public, anon, authenticated;

create index bar_bottles_business_status_idx
  on public.bar_bottles (business_id, status, expires_at);
create index bar_bottles_client_idx
  on public.bar_bottles (business_id, client_id, status);
create index bar_bottles_branch_idx
  on public.bar_bottles (business_id, branch_id, status);

-- Every table that carries branch_id in this schema gets the same BEFORE INSERT default, so a
-- writer that does not name a branch lands in the firm's default branch rather than nowhere.
create trigger bar_bottles_set_branch
before insert on public.bar_bottles
for each row execute function app.set_row_branch();

create table public.bar_bottle_events (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete restrict,
  bottle_id uuid not null references public.bar_bottles(id) on delete restrict,
  kind text not null
    check (kind in ('park', 'fill', 'status', 'extend', 'transfer', 'finish', 'expire', 'reminder')),
  actor uuid,
  idem_key text check (idem_key is null or length(btrim(idem_key)) between 1 and 120),
  detail jsonb not null default '{}'::jsonb,
  occurred_at timestamptz not null default now()
);
comment on table public.bar_bottle_events is
  'Append-only evidence for every change to a customer''s parked property, and the idempotency key store for every mutating RPC.';

alter table public.bar_bottle_events enable row level security;
revoke all privileges on table public.bar_bottle_events from public, anon, authenticated;

create index bar_bottle_events_bottle_idx
  on public.bar_bottle_events (bottle_id, occurred_at desc, id);

-- The event row IS the dedupe record. A replayed Park/Fill/Extend/Transfer/Finish cannot write a
-- second event, which is what makes "double-tap safe" a property of the schema rather than of
-- the RPC bodies remembering to check.
create unique index bar_bottle_events_idem_uk
  on public.bar_bottle_events (business_id, idem_key)
  where idem_key is not null;

create trigger bar_bottle_events_immutable
before update or delete on public.bar_bottle_events
for each row execute function app.v33_append_only_guard();

-- ---------------------------------------------------------------------------
-- 4. Gates. Two helpers, so the industry rule and the staff rule each exist in exactly one
--    place and every RPC below is visibly holding both.
-- ---------------------------------------------------------------------------

-- Owner amendment 4. This is the module's exclusivity, enforced where it cannot be bypassed.
-- The message is plain English on purpose: it is shown to a human, and it must not leak whether
-- the business exists.
create or replace function app.require_bar_business_v275(p_business uuid)
returns void
language plpgsql
stable
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_industry text;
begin
  if p_business is null then
    raise exception 'business required' using errcode = '22023';
  end if;
  select lower(btrim(coalesce(business.industry, ''))) into v_industry
    from public.businesses business
   where business.id = p_business;
  if coalesce(v_industry, '') <> 'bar' then
    raise exception 'Bottle keep is only available for bar businesses.' using errcode = '42501';
  end if;
end;
$$;
revoke all on function app.require_bar_business_v275(uuid) from public, anon, authenticated;

create or replace function app.require_bar_staff_v275(p_business uuid, p_write boolean)
returns void
language plpgsql
stable
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
begin
  if auth.uid() is null then
    raise exception 'authenticated staff required' using errcode = '28000';
  end if;
  if app.is_salon_owner(p_business) then
    return;
  end if;
  if p_write then
    if app.can_module_write(p_business, 'bottles') then
      return;
    end if;
  elsif app.can_module_read(p_business, 'bottles') then
    return;
  end if;
  raise exception 'bottle keep authorization required' using errcode = '42501';
end;
$$;
revoke all on function app.require_bar_staff_v275(uuid, boolean) from public, anon, authenticated;

create or replace function app.bar_keep_days_v275(p_business uuid)
returns integer
language sql
stable
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
  select coalesce(
    (select setting.keep_days from public.bar_bottle_settings setting
      where setting.business_id = p_business),
    30)
$$;
revoke all on function app.bar_keep_days_v275(uuid) from public, anon, authenticated;

-- One replay probe, used by every mutating RPC. Returns the existing event when the key has
-- already been consumed by this business.
create or replace function app.bar_bottle_replayed_v275(p_business uuid, p_idempotency_key text)
returns uuid
language sql
stable
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
  select event.bottle_id
    from public.bar_bottle_events event
   where event.business_id = p_business
     and event.idem_key = nullif(btrim(coalesce(p_idempotency_key, '')), '')
   limit 1
$$;
revoke all on function app.bar_bottle_replayed_v275(uuid, text) from public, anon, authenticated;

-- The one projection every bottle read uses, so the staff list, the detail dialog and the
-- customer card can never describe the same bottle differently.
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
    -- Days left is computed HERE, once, in SGT, because two surfaces render it and a browser
    -- that computed it from its own clock would disagree with the bar's own screen.
    'days_left', (
      (($1).expires_at at time zone 'Asia/Singapore')::date
      - (now() at time zone 'Asia/Singapore')::date
    ),
    'branch_id', ($1).branch_id,
    'client_id', ($1).client_id,
    'sale_id', ($1).sale_id
  )
$$;
revoke all on function app.bar_bottle_json_v275(public.bar_bottles) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 5. Setup RPCs (Operations setup → Bottle keep).
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
    'can_edit', app.is_salon_owner(p_business),
    'locations', v_locations);
end;
$$;

-- Owner-gated, like every other Operations setup write. Declarative: the caller sends the whole
-- list it wants, and a location that disappears from the list is DEACTIVATED rather than
-- deleted, because bottles still point at it and a deleted shelf would orphan the answer to
-- "where is my bottle".
create or replace function public.bar_save_setup_v275(
  p_business uuid,
  p_keep_days integer,
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
  if p_locations is not null and jsonb_typeof(p_locations) <> 'array' then
    raise exception 'storage locations must be a list' using errcode = '22023';
  end if;

  insert into public.bar_bottle_settings (business_id, keep_days, updated_at, updated_by)
  values (p_business, v_keep, now(), v_actor)
  on conflict (business_id) do update
    set keep_days = excluded.keep_days,
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

  update public.bar_storage_locations location
     set active = false, updated_at = now()
   where location.business_id = p_business
     and location.active
     and not (location.id = any (v_kept));

  return public.bar_get_setup_v275(p_business);
end;
$$;

-- ---------------------------------------------------------------------------
-- 6. Bottle lifecycle RPCs. Each one: industry gate, staff gate, replay probe, row lock,
--    state change, exactly one event.
-- ---------------------------------------------------------------------------

create or replace function public.park_bottle_v275(
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
  v_fill integer := coalesce(p_fill_percent, 100);
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

  v_existing := app.bar_bottle_replayed_v275(p_business, v_key);
  if v_existing is not null then
    select * into v_bottle from public.bar_bottles bottle where bottle.id = v_existing;
    return jsonb_build_object('status', 'duplicate_ignored',
      'bottle', app.bar_bottle_json_v275(v_bottle));
  end if;

  -- Locking the settings row serialises serial allocation for this business. It is the cheapest
  -- correct answer: the alternative (max()+1 with no lock) races two bartenders parking at the
  -- same moment into the same PK-YYYY-NNNN, and a duplicate serial on a physical shelf label is
  -- exactly the failure this module exists to prevent.
  insert into public.bar_bottle_settings (business_id) values (p_business)
  on conflict (business_id) do nothing;
  select setting.keep_days into v_keep
    from public.bar_bottle_settings setting
   where setting.business_id = p_business
     for update;
  v_keep := coalesce(v_keep, 30);

  v_year := extract(year from (now() at time zone 'Asia/Singapore'))::integer;
  select coalesce(max(bottle.serial_seq), 0) + 1 into v_seq
    from public.bar_bottles bottle
   where bottle.business_id = p_business and bottle.serial_year = v_year;

  insert into public.bar_bottles (
    business_id, branch_id, client_id, serial_year, serial_seq, label, product_id,
    size_ml, fill_percent, storage_location_id, reentry_limit, status,
    parked_at, expires_at, sale_id
  ) values (
    p_business, p_branch, p_client, v_year, v_seq, v_label, p_product,
    p_size_ml, v_fill, p_storage_location, p_reentry_limit, 'stored',
    now(), now() + make_interval(days => v_keep), p_sale
  )
  returning * into v_bottle;

  insert into public.bar_bottle_events (business_id, bottle_id, kind, actor, idem_key, detail)
  values (p_business, v_bottle.id, 'park', v_actor, v_key, jsonb_build_object(
    'serial_code', v_bottle.serial_code,
    'client_id', v_bottle.client_id,
    'fill_percent', v_bottle.fill_percent,
    'keep_days', v_keep,
    'expires_at', v_bottle.expires_at,
    'storage_location_id', v_bottle.storage_location_id,
    'sale_id', v_bottle.sale_id));

  return jsonb_build_object('status', 'ok', 'bottle', app.bar_bottle_json_v275(v_bottle));
end;
$$;

create or replace function public.set_bottle_fill_v275(
  p_business uuid,
  p_bottle uuid,
  p_fill_percent integer,
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
  v_before integer;
begin
  perform app.require_bar_business_v275(p_business);
  perform app.require_bar_staff_v275(p_business, true);
  if v_key is null then
    raise exception 'idempotency key required' using errcode = '22023';
  end if;
  if p_fill_percent is null or p_fill_percent < 0 or p_fill_percent > 100 then
    raise exception 'fill must be between 0 and 100' using errcode = '22023';
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
  v_before := v_bottle.fill_percent;

  update public.bar_bottles bottle
     set fill_percent = p_fill_percent, updated_at = now()
   where bottle.id = v_bottle.id
  returning * into v_bottle;

  insert into public.bar_bottle_events (business_id, bottle_id, kind, actor, idem_key, detail)
  values (p_business, v_bottle.id, 'fill', v_actor, v_key,
    jsonb_build_object('from', v_before, 'to', p_fill_percent));

  return jsonb_build_object('status', 'ok', 'bottle', app.bar_bottle_json_v275(v_bottle));
end;
$$;

-- Called / at table / back to storage. The terminal statuses are owned by finish_bottle_v275
-- and by the (later) expiry sweep, so this RPC deliberately refuses them: a bottle must not be
-- retired through the same control that walks it to a table.
create or replace function public.set_bottle_status_v275(
  p_business uuid,
  p_bottle uuid,
  p_status text,
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
  v_status text := lower(btrim(coalesce(p_status, '')));
  v_existing uuid;
  v_bottle public.bar_bottles%rowtype;
  v_before text;
begin
  perform app.require_bar_business_v275(p_business);
  perform app.require_bar_staff_v275(p_business, true);
  if v_key is null then
    raise exception 'idempotency key required' using errcode = '22023';
  end if;
  if v_status not in ('stored', 'called', 'at_table') then
    raise exception 'a bottle on the floor is stored, called or at table' using errcode = '22023';
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
  if v_bottle.status not in ('stored', 'called', 'at_table') then
    raise exception 'this bottle is no longer on the floor' using errcode = '22023';
  end if;
  v_before := v_bottle.status;

  update public.bar_bottles bottle
     set status = v_status, updated_at = now()
   where bottle.id = v_bottle.id
  returning * into v_bottle;

  insert into public.bar_bottle_events (business_id, bottle_id, kind, actor, idem_key, detail)
  values (p_business, v_bottle.id, 'status', v_actor, v_key,
    jsonb_build_object('from', v_before, 'to', v_status));

  return jsonb_build_object('status', 'ok', 'bottle', app.bar_bottle_json_v275(v_bottle));
end;
$$;

-- Extend adds the business's OWN keep window from now (the owner's one number), or accepts an
-- explicit date when the bar has agreed something different with the customer. Extending from
-- NOW rather than from the old expiry is the honest reading of "we'll keep it another month".
create or replace function public.extend_bottle_v275(
  p_business uuid,
  p_bottle uuid,
  p_expires_at timestamptz,
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
  v_before timestamptz;
  v_next timestamptz;
  v_keep integer;
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

  v_keep := app.bar_keep_days_v275(p_business);
  v_next := coalesce(p_expires_at, now() + make_interval(days => v_keep));
  if v_next <= now() then
    raise exception 'the new keep date must be in the future' using errcode = '22023';
  end if;
  if v_next > now() + make_interval(days => 730) then
    raise exception 'a bottle cannot be kept more than two years' using errcode = '22023';
  end if;
  v_before := v_bottle.expires_at;

  update public.bar_bottles bottle
     set expires_at = v_next,
         status = case when bottle.status = 'expired' then 'stored' else bottle.status end,
         updated_at = now()
   where bottle.id = v_bottle.id
  returning * into v_bottle;

  insert into public.bar_bottle_events (business_id, bottle_id, kind, actor, idem_key, detail)
  values (p_business, v_bottle.id, 'extend', v_actor, v_key,
    jsonb_build_object('from', v_before, 'to', v_next, 'keep_days', v_keep,
      'explicit_date', p_expires_at is not null));

  return jsonb_build_object('status', 'ok', 'bottle', app.bar_bottle_json_v275(v_bottle));
end;
$$;

-- Transfer moves the bottle to another customer OF THE SAME BUSINESS (the composite FK makes a
-- cross-tenant client impossible, not merely unlikely). Both parties are named in the event,
-- because the question a dispute asks is "who did it belong to before".
create or replace function public.transfer_bottle_v275(
  p_business uuid,
  p_bottle uuid,
  p_client uuid,
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
begin
  perform app.require_bar_business_v275(p_business);
  perform app.require_bar_staff_v275(p_business, true);
  if v_key is null then
    raise exception 'idempotency key required' using errcode = '22023';
  end if;
  if p_client is null then
    raise exception 'choose the customer to transfer to' using errcode = '22023';
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
  if v_bottle.client_id = p_client then
    raise exception 'that customer already holds this bottle' using errcode = '22023';
  end if;
  v_before := v_bottle.client_id;

  update public.bar_bottles bottle
     set client_id = p_client, updated_at = now()
   where bottle.id = v_bottle.id
  returning * into v_bottle;

  insert into public.bar_bottle_events (business_id, bottle_id, kind, actor, idem_key, detail)
  values (p_business, v_bottle.id, 'transfer', v_actor, v_key,
    jsonb_build_object('from_client_id', v_before, 'to_client_id', p_client));

  return jsonb_build_object('status', 'ok', 'bottle', app.bar_bottle_json_v275(v_bottle));
end;
$$;

create or replace function public.finish_bottle_v275(
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
  v_before text;
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
  if v_bottle.status = 'finished' then
    return jsonb_build_object('status', 'ok', 'bottle', app.bar_bottle_json_v275(v_bottle));
  end if;
  if v_bottle.status in ('transferred', 'removed') then
    raise exception 'this bottle is closed' using errcode = '22023';
  end if;
  v_before := v_bottle.status;

  update public.bar_bottles bottle
     set status = 'finished', fill_percent = 0, updated_at = now()
   where bottle.id = v_bottle.id
  returning * into v_bottle;

  insert into public.bar_bottle_events (business_id, bottle_id, kind, actor, idem_key, detail)
  values (p_business, v_bottle.id, 'finish', v_actor, v_key,
    jsonb_build_object('from', v_before, 'fill_percent_at_finish', 0));

  return jsonb_build_object('status', 'ok', 'bottle', app.bar_bottle_json_v275(v_bottle));
end;
$$;

-- ---------------------------------------------------------------------------
-- 7. Reads.
-- ---------------------------------------------------------------------------

-- One RPC serves the list and the detail dialog: p_bottle non-null returns that bottle plus its
-- full event history. Two functions would have been two projections of the same row, which is
-- how a list and a detail screen start disagreeing.
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
         and (v_status <> '' or bottle.status in ('stored', 'called', 'at_table'))
         and (p_expiring_days is null
              or (bottle.status in ('stored', 'called', 'at_table')
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
  -- shrank when you typed a search would be reporting the search, not the bar.
  select jsonb_build_object(
           'stored', count(*) filter (where bottle.status = 'stored'),
           'called', count(*) filter (where bottle.status = 'called'),
           'at_table', count(*) filter (where bottle.status = 'at_table'),
           'expiring_soon', count(*) filter (
             where bottle.status in ('stored', 'called', 'at_table')
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
               'days_left', (
                 (bottle.expires_at at time zone 'Asia/Singapore')::date
                 - (now() at time zone 'Asia/Singapore')::date
               )) as entry,
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
-- 8. Grants. A create-from-scratch replay would otherwise inherit PostgreSQL's default
--    EXECUTE-to-PUBLIC on every function above.
-- ---------------------------------------------------------------------------

revoke all on function public.bar_get_setup_v275(uuid) from public, anon, authenticated;
revoke all on function public.bar_save_setup_v275(uuid, integer, jsonb) from public, anon, authenticated;
revoke all on function public.park_bottle_v275(uuid, uuid, text, uuid, integer, integer, uuid, integer, uuid, uuid, text) from public, anon, authenticated;
revoke all on function public.set_bottle_fill_v275(uuid, uuid, integer, text) from public, anon, authenticated;
revoke all on function public.set_bottle_status_v275(uuid, uuid, text, text) from public, anon, authenticated;
revoke all on function public.extend_bottle_v275(uuid, uuid, timestamptz, text) from public, anon, authenticated;
revoke all on function public.transfer_bottle_v275(uuid, uuid, uuid, text) from public, anon, authenticated;
revoke all on function public.finish_bottle_v275(uuid, uuid, text) from public, anon, authenticated;
revoke all on function public.list_bar_bottles_v275(uuid, uuid, text, text, integer, uuid, integer) from public, anon, authenticated;
revoke all on function public.customer_get_bottles_v275(text) from public, anon, authenticated;

grant execute on function public.bar_get_setup_v275(uuid) to authenticated;
grant execute on function public.bar_save_setup_v275(uuid, integer, jsonb) to authenticated;
grant execute on function public.park_bottle_v275(uuid, uuid, text, uuid, integer, integer, uuid, integer, uuid, uuid, text) to authenticated;
grant execute on function public.set_bottle_fill_v275(uuid, uuid, integer, text) to authenticated;
grant execute on function public.set_bottle_status_v275(uuid, uuid, text, text) to authenticated;
grant execute on function public.extend_bottle_v275(uuid, uuid, timestamptz, text) to authenticated;
grant execute on function public.transfer_bottle_v275(uuid, uuid, uuid, text) to authenticated;
grant execute on function public.finish_bottle_v275(uuid, uuid, text) to authenticated;
grant execute on function public.list_bar_bottles_v275(uuid, uuid, text, text, integer, uuid, integer) to authenticated;
grant execute on function public.customer_get_bottles_v275(text) to authenticated;

commit;
