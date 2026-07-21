-- FRENLY v46 — CUSTOMER IN-APP INBOX
--
-- Local, forward-only review candidate. This adds a default-off customer inbox
-- without a delivery provider, an external transport, or a general event-write
-- endpoint. Facts can be derived only from the customer-safe C44/C45 wallet
-- projection and remain private to the verified customer relationship.

begin;

insert into app.platform_feature_flags(feature_key, enabled)
values ('customer_in_app_inbox', false)
on conflict (feature_key) do nothing;

-- C46 extends the reviewed v33 preference/audit authority rather than creating
-- a parallel consent store. Existing v33 readers and writers keep their exact
-- response contract; C46's narrow endpoints own the new quiet-hours fields.
alter table public.customer_notification_preferences
  add column quiet_hours_timezone text,
  add column quiet_hours_start time without time zone,
  add column quiet_hours_end time without time zone,
  add constraint customer_notification_preferences_c46_quiet_hours_shape_check check (
    (quiet_hours_timezone is null and quiet_hours_start is null and quiet_hours_end is null)
    or (
      quiet_hours_timezone = btrim(quiet_hours_timezone)
      and length(quiet_hours_timezone) between 1 and 64
      and quiet_hours_start is not null
      and quiet_hours_end is not null
      and quiet_hours_start <> quiet_hours_end
    )
  );

-- v33 historically accepted broad `marketing`/`loyalty_updates` labels.
-- Preserve those rows as legacy evidence, but make the new C46 subjects
-- explicit. C46's own write/read authority below accepts only the five precise
-- topics; legacy values cannot consent to a newly introduced subject.
alter table public.customer_notification_preferences
  drop constraint customer_notification_preferences_topic_check,
  add constraint customer_notification_preferences_topic_check check (topic in (
    'marketing', 'loyalty_updates',
    'value_expiry', 'reward_ready', 'visit_progress', 'birthday_benefit', 'booking_updates'
  ));

alter table public.customer_preference_audit
  add column quiet_hours_timezone text,
  add column quiet_hours_start time without time zone,
  add column quiet_hours_end time without time zone,
  add constraint customer_preference_audit_c46_quiet_hours_shape_check check (
    (quiet_hours_timezone is null and quiet_hours_start is null and quiet_hours_end is null)
    or (
      quiet_hours_timezone = btrim(quiet_hours_timezone)
      and length(quiet_hours_timezone) between 1 and 64
      and quiet_hours_start is not null
      and quiet_hours_end is not null
      and quiet_hours_start <> quiet_hours_end
    )
  );

alter table public.customer_preference_audit
  drop constraint customer_preference_audit_topic_check,
  add constraint customer_preference_audit_topic_check check (topic in (
    'marketing', 'loyalty_updates',
    'value_expiry', 'reward_ready', 'visit_progress', 'birthday_benefit', 'booking_updates'
  ));

create or replace function app.c46_sha256_hex(p_value text)
returns text language sql immutable
set search_path to 'pg_catalog', 'extensions', 'pg_temp'
as $$
  select encode(extensions.digest(convert_to($1, 'UTF8'), 'sha256'), 'hex')
$$;

-- This is deliberately a closed, small topic set. C46 never treats a generic
-- v33 preference as permission for a new subject matter.
create or replace function app.c46_in_app_topic_allowed(p_topic text)
returns boolean language sql immutable
set search_path to 'pg_catalog', 'pg_temp'
as $$
  select $1 = any (array[
    'value_expiry', 'reward_ready', 'visit_progress', 'birthday_benefit', 'booking_updates'
  ]::text[])
$$;

-- C44 is the safe projection that makes both its own action facts and C45's
-- birthday card available to C46. If that projection is disabled, immutable
-- history remains visible but must never count as unread or expose a route.
-- v33 booking facts do not depend on C44 and remain available.
create or replace function app.c46_inbox_source_available(
  p_source_kind text,
  p_actionable_wallet_enabled boolean
)
returns boolean language sql immutable
set search_path to 'pg_catalog', 'pg_temp'
as $$
  select $1 = 'v33_booking_action'
      or (coalesce($2, false) and $1 in ('c44_actionable_wallet','c45_birthday_benefit'))
$$;

-- IANA names are validated at the write boundary. The database timezone
-- catalogue is the authoritative seam; callers cannot select an arbitrary
-- fixed offset or a browser-local timezone spelling.
create or replace function app.c46_iana_timezone_allowed(p_timezone text)
returns boolean language sql stable security definer
set search_path to 'pg_catalog', 'pg_temp'
as $$
  select exists (
    select 1 from pg_timezone_names where name = nullif(btrim($1), '')
  )
$$;

create or replace function app.c46_in_quiet_hours(
  p_timezone text,
  p_start time without time zone,
  p_end time without time zone,
  p_as_of timestamptz default statement_timestamp()
)
returns boolean language plpgsql stable security definer
set search_path to 'pg_catalog', 'pg_temp'
as $$
declare v_local_time time without time zone;
begin
  if p_timezone is null or p_start is null or p_end is null then return false; end if;
  if not app.c46_iana_timezone_allowed(p_timezone) then return false; end if;
  v_local_time := timezone(p_timezone, p_as_of)::time;
  if p_start < p_end then
    return v_local_time >= p_start and v_local_time < p_end;
  end if;
  -- A half-open window spanning midnight, for example 22:00–08:00.
  return v_local_time >= p_start or v_local_time < p_end;
end;
$$;

-- A slug is only a lookup hint. The complete identity/link/business/client
-- tuple is always re-derived from auth.uid() and a verified customer link.
create or replace function app.c46_customer_inbox_context(p_business_slug text)
returns table (
  identity_id uuid,
  auth_user_id uuid,
  link_id uuid,
  business_id uuid,
  client_id uuid,
  business_slug text,
  business_name text
)
language plpgsql stable security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare v_actor uuid := auth.uid(); v_slug text := lower(btrim(coalesce(p_business_slug, '')));
begin
  if v_actor is null then
    raise exception 'authenticated customer session required' using errcode = '28000';
  end if;
  if not app.platform_feature_enabled('customer_in_app_inbox') then
    raise exception 'customer in-app inbox is not enabled' using errcode = '0A000';
  end if;
  if length(v_slug) not between 2 and 160 then
    raise exception 'invalid business link' using errcode = '22023';
  end if;
  return query
    select ci.id, v_actor, cl.id, cl.business_id, cl.client_id, b.slug, b.name
      from public.customer_identities ci
      join public.customer_links cl
        on cl.identity_id = ci.id and cl.auth_user_id = v_actor and cl.state = 'verified'
      join public.businesses b on b.id = cl.business_id
     where ci.auth_user_id = v_actor and ci.status = 'active' and b.slug = v_slug
     order by cl.id
     limit 1;
  if not found then
    raise exception 'verified customer link required' using errcode = '42501';
  end if;
end;
$$;

create or replace function app.c46_customer_inbox_global_context()
returns table (identity_id uuid, auth_user_id uuid)
language plpgsql stable security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare v_actor uuid := auth.uid();
begin
  if v_actor is null then
    raise exception 'authenticated customer session required' using errcode = '28000';
  end if;
  if not app.platform_feature_enabled('customer_in_app_inbox') then
    raise exception 'customer in-app inbox is not enabled' using errcode = '0A000';
  end if;
  return query select ci.id, v_actor from public.customer_identities ci
   where ci.auth_user_id=v_actor and ci.status='active';
  if not found then raise exception 'active customer identity required' using errcode='42501'; end if;
end;
$$;

create or replace function app.c46_in_app_preference_for_context(
  p_business_id uuid,
  p_identity_id uuid,
  p_link_id uuid,
  p_topic text
)
returns table (
  opted_in boolean,
  quiet_hours_timezone text,
  quiet_hours_start time without time zone,
  quiet_hours_end time without time zone
)
language sql stable security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
  select coalesce(p.opted_in, false), p.quiet_hours_timezone,
         p.quiet_hours_start, p.quiet_hours_end
    from (values (1)) as fallback(one)
    left join public.customer_notification_preferences p
      on p.business_id = $1 and p.identity_id = $2 and p.link_id = $3
     and p.channel = 'in_app' and p.topic = $4
$$;

-- Immutable customer-safe facts. The text is intentionally finite and generic:
-- no DOB, prices, savings estimate, customer identifier, private programme
-- configuration, or provider receipt is stored in the inbox.
create table public.customer_in_app_inbox_events (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete restrict,
  identity_id uuid not null references public.customer_identities(id) on delete restrict,
  auth_user_id uuid not null references auth.users(id) on delete restrict,
  link_id uuid not null,
  client_id uuid not null,
  source_kind text not null check (source_kind in (
    'c44_actionable_wallet', 'c45_birthday_benefit', 'v33_booking_action'
  )),
  topic text not null check (topic in (
    'value_expiry', 'reward_ready', 'visit_progress', 'birthday_benefit', 'booking_updates'
  )),
  route_key text not null check (route_key = 'wallet_business'),
  source_fingerprint text not null check (source_fingerprint ~ '^[0-9a-f]{64}$'),
  dedupe_key text not null check (dedupe_key ~ '^[0-9a-f]{64}$'),
  title text not null check (title in (
    'Points expire soon', 'Stamps expire soon', 'A reward is ready', 'One visit to go',
    'Birthday benefit ready', 'Appointment request received'
  )),
  body text not null check (body in (
    'Open this business wallet to review your points.',
    'Open this business wallet to review your stamps.',
    'Open this business wallet to view the available reward.',
    'One qualifying visit remains before your next reward.',
    'Open this business wallet to view your birthday benefit.',
    'Open this business wallet to review your appointment request.'
  )),
  deadline_at timestamptz,
  observed_at timestamptz not null default statement_timestamp(),
  created_at timestamptz not null default now(),
  constraint customer_in_app_inbox_events_identity_auth_fk
    foreign key (identity_id, auth_user_id)
    references public.customer_identities(id, auth_user_id) on delete restrict,
  constraint customer_in_app_inbox_events_link_scope_fk
    foreign key (link_id, business_id, client_id)
    references public.customer_links(id, business_id, client_id) on delete restrict,
  -- Both link composites are required. A valid business/client link alone
  -- cannot be paired with another customer's identity on an immutable fact.
  constraint customer_in_app_inbox_events_link_identity_scope_fk
    foreign key (link_id, business_id, identity_id)
    references public.customer_links(id, business_id, identity_id) on delete restrict,
  constraint customer_in_app_inbox_events_provenance_uk
    unique (id, business_id, identity_id, client_id, link_id),
  constraint customer_in_app_inbox_events_identity_dedupe_uk
    unique (identity_id, dedupe_key)
);

create index customer_in_app_inbox_events_customer_time_idx
  on public.customer_in_app_inbox_events (identity_id, business_id, created_at desc, id desc);

-- Current read/dismiss state is mutable only through the C46 operation RPC.
-- The append-only operation table preserves each accepted state transition and
-- makes an idempotent replay distinguishable from a fresh state change.
create table public.customer_in_app_inbox_state (
  event_id uuid primary key,
  business_id uuid not null,
  identity_id uuid not null,
  auth_user_id uuid not null references auth.users(id) on delete restrict,
  link_id uuid not null,
  client_id uuid not null,
  read_at timestamptz,
  dismissed_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint customer_in_app_inbox_state_event_scope_fk
    foreign key (event_id, business_id, identity_id, client_id, link_id)
    references public.customer_in_app_inbox_events(id, business_id, identity_id, client_id, link_id)
    on delete restrict,
  constraint customer_in_app_inbox_state_identity_auth_fk
    foreign key (identity_id, auth_user_id)
    references public.customer_identities(id, auth_user_id) on delete restrict,
  constraint customer_in_app_inbox_state_provenance_uk
    unique (event_id, business_id, identity_id, client_id, link_id)
);

create table public.customer_in_app_inbox_state_operations (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null,
  business_id uuid not null,
  identity_id uuid not null,
  auth_user_id uuid not null references auth.users(id) on delete restrict,
  link_id uuid not null,
  client_id uuid not null,
  operation text not null check (operation in ('read', 'unread', 'dismiss')),
  idempotency_key uuid not null,
  request_hash text not null check (request_hash ~ '^[0-9a-f]{64}$'),
  response jsonb not null check (jsonb_typeof(response) = 'object'),
  created_at timestamptz not null default now(),
  constraint customer_in_app_inbox_state_operations_event_scope_fk
    foreign key (event_id, business_id, identity_id, client_id, link_id)
    references public.customer_in_app_inbox_events(id, business_id, identity_id, client_id, link_id)
    on delete restrict,
  constraint customer_in_app_inbox_state_operations_identity_auth_fk
    foreign key (identity_id, auth_user_id)
    references public.customer_identities(id, auth_user_id) on delete restrict,
  constraint customer_in_app_inbox_state_operations_idempotency_uk
    unique (identity_id, idempotency_key)
);

-- Resolution is a new immutable fact, never an update of an earlier wallet or
-- booking event. It preserves the historical notification while taking it out
-- of unread/actionable counts once the authoritative source no longer supports
-- it (for example, points were used or an appointment request was superseded).
create table public.customer_in_app_inbox_resolutions (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null,
  business_id uuid not null,
  identity_id uuid not null,
  auth_user_id uuid not null references auth.users(id) on delete restrict,
  link_id uuid not null,
  client_id uuid not null,
  resolution_kind text not null check (resolution_kind = 'source_no_longer_current'),
  source_fingerprint text not null check (source_fingerprint ~ '^[0-9a-f]{64}$'),
  resolved_at timestamptz not null default statement_timestamp(),
  created_at timestamptz not null default now(),
  constraint customer_in_app_inbox_resolutions_event_scope_fk
    foreign key (event_id, business_id, identity_id, client_id, link_id)
    references public.customer_in_app_inbox_events(id, business_id, identity_id, client_id, link_id)
    on delete restrict,
  constraint customer_in_app_inbox_resolutions_identity_auth_fk
    foreign key (identity_id, auth_user_id)
    references public.customer_identities(id, auth_user_id) on delete restrict,
  constraint customer_in_app_inbox_resolutions_event_uk unique (event_id)
);

create table public.customer_in_app_inbox_sync_operations (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete restrict,
  identity_id uuid not null references public.customer_identities(id) on delete restrict,
  auth_user_id uuid not null references auth.users(id) on delete restrict,
  link_id uuid not null,
  client_id uuid not null,
  idempotency_key uuid not null,
  request_hash text not null check (request_hash ~ '^[0-9a-f]{64}$'),
  response jsonb not null check (jsonb_typeof(response) = 'object'),
  created_at timestamptz not null default now(),
  constraint customer_in_app_inbox_sync_operations_link_scope_fk
    foreign key (link_id, business_id, client_id)
    references public.customer_links(id, business_id, client_id) on delete restrict,
  -- Sync operations are root provenance records, so they carry the same
  -- business/link/identity proof as an event rather than relying on a later
  -- event relationship that may never be created for an opt-out.
  constraint customer_in_app_inbox_sync_operations_link_identity_scope_fk
    foreign key (link_id, business_id, identity_id)
    references public.customer_links(id, business_id, identity_id) on delete restrict,
  constraint customer_in_app_inbox_sync_operations_identity_auth_fk
    foreign key (identity_id, auth_user_id)
    references public.customer_identities(id, auth_user_id) on delete restrict,
  constraint customer_in_app_inbox_sync_operations_idempotency_uk
    unique (identity_id, idempotency_key)
);

create table public.customer_in_app_inbox_global_sync_operations (
  id uuid primary key default gen_random_uuid(),
  identity_id uuid not null references public.customer_identities(id) on delete restrict,
  auth_user_id uuid not null references auth.users(id) on delete restrict,
  idempotency_key uuid not null,
  request_hash text not null check (request_hash ~ '^[0-9a-f]{64}$'),
  response jsonb not null check (jsonb_typeof(response) = 'object'),
  created_at timestamptz not null default now(),
  constraint customer_in_app_inbox_global_sync_operations_identity_auth_fk
    foreign key (identity_id, auth_user_id)
    references public.customer_identities(id, auth_user_id) on delete restrict,
  constraint customer_in_app_inbox_global_sync_operations_idempotency_uk
    unique (identity_id, idempotency_key)
);

alter table public.customer_in_app_inbox_events enable row level security;
alter table public.customer_in_app_inbox_state enable row level security;
alter table public.customer_in_app_inbox_state_operations enable row level security;
alter table public.customer_in_app_inbox_resolutions enable row level security;
alter table public.customer_in_app_inbox_sync_operations enable row level security;
alter table public.customer_in_app_inbox_global_sync_operations enable row level security;
revoke all privileges on table public.customer_in_app_inbox_events from public, anon, authenticated;
revoke all privileges on table public.customer_in_app_inbox_state from public, anon, authenticated;
revoke all privileges on table public.customer_in_app_inbox_state_operations from public, anon, authenticated;
revoke all privileges on table public.customer_in_app_inbox_resolutions from public, anon, authenticated;
revoke all privileges on table public.customer_in_app_inbox_sync_operations from public, anon, authenticated;
revoke all privileges on table public.customer_in_app_inbox_global_sync_operations from public, anon, authenticated;

create or replace function app.c46_append_only_guard()
returns trigger language plpgsql security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
begin
  if tg_op <> 'INSERT' then
    raise exception '% is immutable', tg_table_name using errcode = '23000';
  end if;
  return new;
end;
$$;

create trigger customer_in_app_inbox_events_immutable_guard
  before update or delete on public.customer_in_app_inbox_events
  for each row execute function app.c46_append_only_guard();
create trigger customer_in_app_inbox_state_operations_immutable_guard
  before update or delete on public.customer_in_app_inbox_state_operations
  for each row execute function app.c46_append_only_guard();
create trigger customer_in_app_inbox_resolutions_immutable_guard
  before update or delete on public.customer_in_app_inbox_resolutions
  for each row execute function app.c46_append_only_guard();
create trigger customer_in_app_inbox_sync_operations_immutable_guard
  before update or delete on public.customer_in_app_inbox_sync_operations
  for each row execute function app.c46_append_only_guard();
create trigger customer_in_app_inbox_global_sync_operations_immutable_guard
  before update or delete on public.customer_in_app_inbox_global_sync_operations
  for each row execute function app.c46_append_only_guard();

create or replace function app.c46_inbox_state_guard()
returns trigger language plpgsql security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare v_write_event text := nullif(current_setting('app.c46_inbox_state_event', true), '');
begin
  if tg_op = 'DELETE' then
    raise exception 'customer inbox state is retained as operation evidence' using errcode = '23000';
  end if;
  if v_write_event is distinct from new.event_id::text then
    raise exception 'customer inbox state may only be changed through its operation RPC' using errcode = '42501';
  end if;
  if tg_op = 'UPDATE' and (
    (new.event_id, new.business_id, new.identity_id, new.auth_user_id, new.link_id, new.client_id, new.created_at)
      is distinct from
    (old.event_id, old.business_id, old.identity_id, old.auth_user_id, old.link_id, old.client_id, old.created_at)
  ) then
    raise exception 'customer inbox state provenance is immutable' using errcode = '23000';
  end if;
  new.updated_at := now();
  return new;
end;
$$;

create trigger customer_in_app_inbox_state_guard
  before insert or update or delete on public.customer_in_app_inbox_state
  for each row execute function app.c46_inbox_state_guard();

-- Candidate facts have only four accepted source states. C44/C45 are read
-- through their customer-safe card, never through an owner/staff projection or
-- a caller-provided event payload.
create or replace function app.c46_customer_safe_inbox_candidates(p_card jsonb)
returns table (
  source_kind text, topic text, title text, body text,
  source_fingerprint text, deadline_at timestamptz
)
language sql stable security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
  -- C44 is the only loyalty-unit authority. Preserve that safe, finite unit
  -- label in the immutable fact; do not infer a dollar value or a saving.
  select 'c44_actionable_wallet', 'value_expiry',
         case when p_card#>>'{loyalty,unit}'='stamps' then 'Stamps expire soon' else 'Points expire soon' end,
         case when p_card#>>'{loyalty,unit}'='stamps'
           then 'Open this business wallet to review your stamps.'
           else 'Open this business wallet to review your points.' end,
         app.c46_sha256_hex(jsonb_build_object(
           'source','c44-expiry','within_7',p_card#>>'{expiry,expiring_within_7_days}',
           'within_30',p_card#>>'{expiry,expiring_units}','deadline',p_card#>>'{expiry,next_expiry_at}',
           'unit',p_card#>>'{loyalty,unit}'
         )::text), nullif(p_card#>>'{expiry,next_expiry_at}','')::timestamptz
   where p_card#>>'{loyalty,unit}' in ('points','stamps')
     and coalesce((p_card#>>'{expiry,expiring_units}')::integer, 0) > 0
  union all
  select 'c44_actionable_wallet', 'reward_ready', 'A reward is ready',
         'Open this business wallet to view the available reward.',
         app.c46_sha256_hex(jsonb_build_object(
           'source','c44-reward','name',p_card#>>'{next_eligible_reward,name}',
           'cost',p_card#>>'{next_eligible_reward,cost_units}'
         )::text), null
   where coalesce((p_card#>>'{next_eligible_reward,available_now}')::boolean, false)
  union all
  select 'c44_actionable_wallet', 'visit_progress', 'One visit to go',
         'One qualifying visit remains before your next reward.',
         app.c46_sha256_hex(jsonb_build_object(
           'source','c44-visit','period_end',p_card#>>'{visit_progress,period_ends_at}',
           'goal',p_card#>>'{visit_progress,goal_visits}'
         )::text), nullif(p_card#>>'{visit_progress,period_ends_at}','')::timestamptz
   where coalesce((p_card#>>'{visits_remaining}')::integer, -1) = 1
  union all
  select 'c45_birthday_benefit', 'birthday_benefit', 'Birthday benefit ready',
         'Open this business wallet to view your birthday benefit.',
         app.c46_sha256_hex(jsonb_build_object(
           'source','c45-birthday','status',p_card#>>'{birthday_benefit,status}',
           'until',p_card#>>'{birthday_benefit,validity,available_until}'
         )::text), nullif(p_card#>>'{birthday_benefit,validity,available_until}','')::timestamptz
   where p_card#>>'{birthday_benefit,status}' in ('ready_to_activate', 'available')
$$;

-- v33 has no delivery provider here: its immutable action-request evidence is
-- the authoritative customer action fact. C46 consent is evaluated separately,
-- so an old generic v33 delivery preference cannot suppress a newly opted-in
-- C46 booking update for this same verified link.
create or replace function app.c46_customer_safe_booking_candidates(
  p_business_id uuid,
  p_identity_id uuid,
  p_link_id uuid
)
returns table (
  source_kind text, topic text, title text, body text,
  source_fingerprint text, deadline_at timestamptz
)
language sql stable security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
  select 'v33_booking_action', 'booking_updates', 'Appointment request received',
         'Open this business wallet to review your appointment request.',
         app.c46_sha256_hex(jsonb_build_object(
           'source','v33-booking-action','request_id',r.id,'action',r.action,
           'proposed_at',r.proposed_at,'created_at',r.created_at
         )::text), r.proposed_at
    from public.customer_appointment_action_requests r
   where r.business_id=$1 and r.identity_id=$2 and r.link_id=$3 and r.status='pending'
$$;

create or replace function public.customer_set_in_app_inbox_preferences(
  p_business_slug text,
  p_topic text,
  p_opted_in boolean,
  p_quiet_hours_timezone text,
  p_quiet_hours_start time without time zone,
  p_quiet_hours_end time without time zone,
  p_idempotency_key uuid
)
returns jsonb language plpgsql security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_context record; v_topic text; v_timezone text;
  v_now timestamptz := statement_timestamp(); v_preference_id uuid;
  v_idempotency text; v_request_hash text; v_existing public.customer_preference_audit%rowtype;
begin
  if not app.platform_feature_enabled('customer_in_app_inbox') then
    raise exception 'customer in-app inbox is not enabled' using errcode='0A000';
  end if;
  v_topic:=lower(btrim(coalesce(p_topic, '')));
  v_timezone:=nullif(btrim(coalesce(p_quiet_hours_timezone, '')), '');
  if p_idempotency_key is null or p_opted_in is null or not app.c46_in_app_topic_allowed(v_topic) then
    raise exception 'invalid in-app inbox preference' using errcode = '22023';
  end if;
  if (v_timezone is null and (p_quiet_hours_start is not null or p_quiet_hours_end is not null))
     or (v_timezone is not null and (
       p_quiet_hours_start is null or p_quiet_hours_end is null
       or p_quiet_hours_start = p_quiet_hours_end
       or not app.c46_iana_timezone_allowed(v_timezone)
     )) then
    raise exception 'quiet hours must use a valid IANA timezone and two different times' using errcode = '22023';
  end if;
  select * into v_context from app.c46_customer_inbox_context(p_business_slug);
  -- Linearization point for C46 consent: C45 participation setters already
  -- lock this same active identity row. Taking it before any preference read
  -- or mutation means an opt-out/participation withdrawal and a C46 sync are
  -- ordered as one serial history for this customer.
  perform 1 from public.customer_identities ci
   where ci.id=v_context.identity_id and ci.auth_user_id=v_context.auth_user_id and ci.status='active'
   for update;
  if not found then raise exception 'active customer identity required' using errcode='42501'; end if;
  v_idempotency := 'c46:in-app-preference:' || p_idempotency_key::text;
  v_request_hash := app.c46_sha256_hex(jsonb_build_object(
    'business_slug',v_context.business_slug,'topic',v_topic,'opted_in',p_opted_in,
    'quiet_hours_timezone',v_timezone,'quiet_hours_start',p_quiet_hours_start,
    'quiet_hours_end',p_quiet_hours_end
  )::text);
  perform pg_advisory_xact_lock(hashtextextended(
    'c46:in-app-preference:' || v_context.identity_id::text || ':' || p_idempotency_key::text, 0
  ));
  select * into v_existing from public.customer_preference_audit a
   where a.identity_id = v_context.identity_id and a.idempotency_key = v_idempotency;
  if found then
    if v_existing.request_hash is distinct from v_request_hash then
      raise exception 'idempotency key conflicts with another inbox preference' using errcode = '40001';
    end if;
    return jsonb_build_object('topic',v_existing.topic,'opted_in',v_existing.opted_in,
      'quiet_hours_timezone',v_existing.quiet_hours_timezone,
      'quiet_hours_start',v_existing.quiet_hours_start,'quiet_hours_end',v_existing.quiet_hours_end,
      'consent_at',v_existing.consent_at);
  end if;
  insert into public.customer_notification_preferences(
    business_id,identity_id,auth_user_id,link_id,client_id,channel,topic,opted_in,consent_at,
    quiet_hours_timezone,quiet_hours_start,quiet_hours_end,updated_at
  ) values (
    v_context.business_id,v_context.identity_id,v_context.auth_user_id,v_context.link_id,v_context.client_id,
    'in_app',v_topic,p_opted_in,v_now,v_timezone,p_quiet_hours_start,p_quiet_hours_end,v_now
  ) on conflict (business_id,link_id,channel,topic) do update set
    opted_in=excluded.opted_in,consent_at=excluded.consent_at,
    quiet_hours_timezone=excluded.quiet_hours_timezone,quiet_hours_start=excluded.quiet_hours_start,
    quiet_hours_end=excluded.quiet_hours_end,updated_at=excluded.updated_at
  returning id into v_preference_id;
  insert into public.customer_preference_audit(
    preference_id,business_id,identity_id,auth_user_id,link_id,client_id,channel,topic,opted_in,consent_at,
    quiet_hours_timezone,quiet_hours_start,quiet_hours_end,idempotency_key,request_hash
  ) values (
    v_preference_id,v_context.business_id,v_context.identity_id,v_context.auth_user_id,v_context.link_id,
    v_context.client_id,'in_app',v_topic,p_opted_in,v_now,v_timezone,p_quiet_hours_start,p_quiet_hours_end,
    v_idempotency,v_request_hash
  );
  return jsonb_build_object('topic',v_topic,'opted_in',p_opted_in,
    'quiet_hours_timezone',v_timezone,'quiet_hours_start',p_quiet_hours_start,
    'quiet_hours_end',p_quiet_hours_end,'consent_at',v_now);
end;
$$;

create or replace function public.customer_get_in_app_inbox_preferences(p_business_slug text)
returns jsonb language plpgsql stable security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare v_context record;
begin
  if not app.platform_feature_enabled('customer_in_app_inbox') then
    raise exception 'customer in-app inbox is not enabled' using errcode='0A000';
  end if;
  select * into v_context from app.c46_customer_inbox_context(p_business_slug);
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'topic',topics.topic,'opted_in',coalesce(p.opted_in,false),
      'quiet_hours_timezone',p.quiet_hours_timezone,'quiet_hours_start',p.quiet_hours_start,
      'quiet_hours_end',p.quiet_hours_end
    ) order by topics.topic)
    from (values ('value_expiry'::text),('reward_ready'::text),('visit_progress'::text),
                 ('birthday_benefit'::text),('booking_updates'::text)) topics(topic)
    left join public.customer_notification_preferences p
      on p.business_id=v_context.business_id and p.identity_id=v_context.identity_id
     and p.link_id=v_context.link_id and p.channel='in_app' and p.topic=topics.topic
  ), '[]'::jsonb);
end;
$$;

create or replace function public.customer_sync_in_app_inbox(
  p_business_slug text,
  p_idempotency_key uuid
)
returns jsonb language plpgsql security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_context record; v_existing public.customer_in_app_inbox_sync_operations%rowtype;
  v_request_hash text; v_card jsonb; v_candidate record; v_preference record;
  v_dedupe_key text; v_cycle integer; v_created integer := 0; v_resolved integer := 0; v_rows integer;
  v_response jsonb; v_active_source_keys text[] := '{}'::text[];
  v_actionable_source_available boolean; v_birthday_participating boolean := false;
begin
  if not app.platform_feature_enabled('customer_in_app_inbox') then
    raise exception 'customer in-app inbox is not enabled' using errcode='0A000';
  end if;
  if p_idempotency_key is null then raise exception 'idempotency key is required' using errcode='22023'; end if;
  select * into v_context from app.c46_customer_inbox_context(p_business_slug);
  -- Same linearization point as the C46 preference setter and C45
  -- participation setter. Source, preference, and participation reads below
  -- cannot interleave with an opt-out for this identity.
  perform 1 from public.customer_identities ci
   where ci.id=v_context.identity_id and ci.auth_user_id=v_context.auth_user_id and ci.status='active'
   for update;
  if not found then raise exception 'active customer identity required' using errcode='42501'; end if;
  v_request_hash:=app.c46_sha256_hex(jsonb_build_object('business_slug',v_context.business_slug)::text);
  perform pg_advisory_xact_lock(hashtextextended(
    'c46:in-app-sync:'||v_context.identity_id::text||':'||p_idempotency_key::text,0
  ));
  select * into v_existing from public.customer_in_app_inbox_sync_operations o
   where o.identity_id=v_context.identity_id and o.idempotency_key=p_idempotency_key;
  if found then
    if v_existing.request_hash is distinct from v_request_hash then
      raise exception 'idempotency key conflicts with another inbox sync' using errcode='40001';
    end if;
    return v_existing.response;
  end if;
  v_actionable_source_available:=app.platform_feature_enabled('customer_actionable_wallet');
  if v_actionable_source_available then
    select public.customer_get_actionable_business(v_context.business_slug)->'card' into v_card;
  end if;
  -- C45 participation is a separate platform-wide customer decision. An
  -- entitlement remains visible in C45 after withdrawal, so the C46 inbox
  -- cannot infer eligibility from the wallet card alone. A birthday event
  -- needs both this current participation decision and the precise C46 topic
  -- preference below.
  select coalesce(p.opted_in,false) into v_birthday_participating
    from (select 1) one
    left join public.customer_birthday_participation p on p.identity_id=v_context.identity_id;
  for v_candidate in
    select * from app.c46_customer_safe_booking_candidates(
      v_context.business_id,v_context.identity_id,v_context.link_id
    )
    union all
    select * from app.c46_customer_safe_inbox_candidates(v_card)
     where v_actionable_source_available
  loop
    if v_candidate.topic='birthday_benefit' and not v_birthday_participating then
      -- Do not retain the source key after C45 withdrawal: revalidation below
      -- resolves any old C46 birthday event without changing the entitlement.
      continue;
    end if;
    v_active_source_keys:=array_append(v_active_source_keys,
      v_candidate.source_kind||':'||v_candidate.source_fingerprint);
    select * into v_preference from app.c46_in_app_preference_for_context(
      v_context.business_id,v_context.identity_id,v_context.link_id,v_candidate.topic
    );
    if v_preference.opted_in then
      -- Recurrence is a logical source cycle, not an unstable clock value. A
      -- later identical reward/expiry fact may become true after an immutable
      -- source-no-longer-current resolution; its next resolution ordinal is a
      -- new customer-visible occurrence while concurrent syncs share one key.
      select count(*)::integer into v_cycle
        from public.customer_in_app_inbox_resolutions r
        join public.customer_in_app_inbox_events prior on prior.id=r.event_id
       where prior.business_id=v_context.business_id and prior.identity_id=v_context.identity_id
         and prior.link_id=v_context.link_id and prior.source_kind=v_candidate.source_kind
         and prior.source_fingerprint=v_candidate.source_fingerprint;
      v_dedupe_key:=app.c46_sha256_hex(jsonb_build_object(
        'business_id',v_context.business_id,'identity_id',v_context.identity_id,
        'source_kind',v_candidate.source_kind,'source_fingerprint',v_candidate.source_fingerprint,
        'source_cycle',v_cycle
      )::text);
      insert into public.customer_in_app_inbox_events(
        business_id,identity_id,auth_user_id,link_id,client_id,source_kind,topic,route_key,
        source_fingerprint,dedupe_key,title,body,deadline_at
      ) values (
        v_context.business_id,v_context.identity_id,v_context.auth_user_id,v_context.link_id,
        v_context.client_id,v_candidate.source_kind,v_candidate.topic,'wallet_business',
        v_candidate.source_fingerprint,v_dedupe_key,v_candidate.title,v_candidate.body,v_candidate.deadline_at
      ) on conflict (identity_id,dedupe_key) do nothing;
      get diagnostics v_rows = row_count;
      v_created:=v_created+v_rows;
    end if;
  end loop;
  -- Revalidation evaluates authoritative source independently of C46 topic
  -- consent. Turning a C46 preference off stops future facts but preserves
  -- history; withdrawing the separate C45 birthday participation intentionally
  -- removes only birthday source keys and therefore resolves C46 history.
  insert into public.customer_in_app_inbox_resolutions(
    event_id,business_id,identity_id,auth_user_id,link_id,client_id,resolution_kind,source_fingerprint
  )
  select e.id,e.business_id,e.identity_id,e.auth_user_id,e.link_id,e.client_id,
         'source_no_longer_current',e.source_fingerprint
    from public.customer_in_app_inbox_events e
   where e.business_id=v_context.business_id and e.identity_id=v_context.identity_id
     and e.link_id=v_context.link_id
     and (e.source_kind='v33_booking_action' or v_actionable_source_available)
     and not (e.source_kind||':'||e.source_fingerprint = any(v_active_source_keys))
  on conflict (event_id) do nothing;
  get diagnostics v_resolved = row_count;
  v_response:=jsonb_build_object('created',v_created,'resolved',v_resolved,
    'source_available',v_actionable_source_available);
  insert into public.customer_in_app_inbox_sync_operations(
    business_id,identity_id,auth_user_id,link_id,client_id,idempotency_key,request_hash,response
  ) values (
    v_context.business_id,v_context.identity_id,v_context.auth_user_id,v_context.link_id,
    v_context.client_id,p_idempotency_key,v_request_hash,v_response
  );
  return v_response;
end;
$$;

-- Global My Frenly refresh is deliberately bounded to 100 current verified
-- links. It delegates to the same per-business factual sync and records one
-- parent replay response; no browser supplies an identity, business id, or
-- arbitrary event payload. The stable UUID derivation makes a same-key replay
-- converge on the per-link operations without using current time as dedupe.
create or replace function public.customer_sync_in_app_inbox_global(
  p_idempotency_key uuid
)
returns jsonb language plpgsql security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_context record; v_existing public.customer_in_app_inbox_global_sync_operations%rowtype;
  v_request_hash text; v_link record; v_count integer:=0; v_created integer:=0; v_resolved integer:=0;
  v_truncated boolean:=false; v_child_key uuid; v_child jsonb; v_response jsonb;
begin
  if not app.platform_feature_enabled('customer_in_app_inbox') then
    raise exception 'customer in-app inbox is not enabled' using errcode='0A000';
  end if;
  if p_idempotency_key is null then raise exception 'idempotency key is required' using errcode='22023'; end if;
  select * into v_context from app.c46_customer_inbox_global_context();
  v_request_hash:=app.c46_sha256_hex(jsonb_build_object('scope','my-frenly-inbox')::text);
  perform pg_advisory_xact_lock(hashtextextended(
    'c46:global-in-app-sync:'||v_context.identity_id::text||':'||p_idempotency_key::text,0
  ));
  select * into v_existing from public.customer_in_app_inbox_global_sync_operations o
   where o.identity_id=v_context.identity_id and o.idempotency_key=p_idempotency_key;
  if found then
    if v_existing.request_hash is distinct from v_request_hash then
      raise exception 'idempotency key conflicts with another global inbox sync' using errcode='40001';
    end if;
    return v_existing.response;
  end if;
  -- Child syncs take the shared identity linearization lock. A lexical,
  -- immutable link order prevents this global refresh from changing lock order
  -- between retries or contending callers.
  for v_link in
    select b.slug
      from public.customer_links cl join public.businesses b on b.id=cl.business_id
     where cl.identity_id=v_context.identity_id and cl.auth_user_id=v_context.auth_user_id and cl.state='verified'
     order by b.slug,cl.id limit 101
  loop
    v_count:=v_count+1;
    if v_count>100 then v_truncated:=true; exit; end if;
    v_child_key:=(substr(md5('c46:global:'||p_idempotency_key::text||':'||v_link.slug),1,8)||'-'||
      substr(md5('c46:global:'||p_idempotency_key::text||':'||v_link.slug),9,4)||'-'||
      substr(md5('c46:global:'||p_idempotency_key::text||':'||v_link.slug),13,4)||'-'||
      substr(md5('c46:global:'||p_idempotency_key::text||':'||v_link.slug),17,4)||'-'||
      substr(md5('c46:global:'||p_idempotency_key::text||':'||v_link.slug),21,12))::uuid;
    select public.customer_sync_in_app_inbox(v_link.slug,v_child_key) into v_child;
    v_created:=v_created+coalesce((v_child->>'created')::integer,0);
    v_resolved:=v_resolved+coalesce((v_child->>'resolved')::integer,0);
  end loop;
  v_response:=jsonb_build_object('synced_businesses',least(v_count,100),'created',v_created,
    'resolved',v_resolved,'truncated',v_truncated);
  insert into public.customer_in_app_inbox_global_sync_operations(
    identity_id,auth_user_id,idempotency_key,request_hash,response
  ) values (v_context.identity_id,v_context.auth_user_id,p_idempotency_key,v_request_hash,v_response);
  return v_response;
end;
$$;

create or replace function public.customer_get_in_app_inbox_count(p_business_slug text)
returns jsonb language plpgsql stable security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare v_context record; v_unread integer; v_quiet boolean; v_actionable_source_available boolean;
begin
  if not app.platform_feature_enabled('customer_in_app_inbox') then
    raise exception 'customer in-app inbox is not enabled' using errcode='0A000';
  end if;
  select * into v_context from app.c46_customer_inbox_context(p_business_slug);
  v_actionable_source_available:=app.platform_feature_enabled('customer_actionable_wallet');
  select count(*)::integer into v_unread
    from public.customer_in_app_inbox_events e
    left join public.customer_in_app_inbox_state s on s.event_id=e.id
    left join public.customer_in_app_inbox_resolutions r on r.event_id=e.id
   where e.business_id=v_context.business_id and e.identity_id=v_context.identity_id
     and e.link_id=v_context.link_id and r.id is null and s.dismissed_at is null and s.read_at is null
     and app.c46_inbox_source_available(e.source_kind,v_actionable_source_available);
  select exists (
    select 1 from (values ('value_expiry'::text),('reward_ready'::text),('visit_progress'::text),
                         ('birthday_benefit'::text),('booking_updates'::text)) topics(topic)
    join lateral app.c46_in_app_preference_for_context(
      v_context.business_id,v_context.identity_id,v_context.link_id,topics.topic
    ) p on true
    where p.opted_in and (v_actionable_source_available or topics.topic='booking_updates')
      and app.c46_in_quiet_hours(
      p.quiet_hours_timezone,p.quiet_hours_start,p.quiet_hours_end,statement_timestamp()
    )
  ) into v_quiet;
  return jsonb_build_object('unread_count',v_unread,'quiet_hours_active',v_quiet,
    'actionable_source_available',v_actionable_source_available);
end;
$$;

create or replace function public.customer_list_in_app_inbox(
  p_business_slug text,
  p_cursor jsonb default '{}'::jsonb
)
returns jsonb language plpgsql stable security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_context record; v_limit integer := 20; v_cursor_at timestamptz; v_cursor_id uuid;
  v_has_cursor boolean := false; v_count integer := 0; v_has_more boolean := false;
  v_items jsonb := '[]'::jsonb; v_row record; v_last_at timestamptz; v_last_id uuid;
  v_quiet boolean; v_filter text; v_actionable_source_available boolean;
begin
  if not app.platform_feature_enabled('customer_in_app_inbox') then
    raise exception 'customer in-app inbox is not enabled' using errcode='0A000';
  end if;
  select * into v_context from app.c46_customer_inbox_context(p_business_slug);
  v_actionable_source_available:=app.platform_feature_enabled('customer_actionable_wallet');
  if p_cursor is null then p_cursor:='{}'::jsonb; end if;
  if jsonb_typeof(p_cursor) <> 'object' or p_cursor - 'limit' - 'filter' - 'created_at' - 'event_id' <> '{}'::jsonb then
    raise exception 'invalid inbox cursor' using errcode='22023';
  end if;
  v_filter:=lower(coalesce(p_cursor->>'filter','all'));
  if v_filter not in ('all','unread') then raise exception 'invalid inbox filter' using errcode='22023'; end if;
  if p_cursor ? 'limit' then
    if (p_cursor->>'limit') !~ '^[0-9]{1,2}$' then raise exception 'invalid inbox cursor' using errcode='22023'; end if;
    v_limit:=least(greatest((p_cursor->>'limit')::integer,1),50);
  end if;
  if (p_cursor ? 'created_at') <> (p_cursor ? 'event_id') then
    raise exception 'invalid inbox cursor' using errcode='22023';
  end if;
  if p_cursor ? 'created_at' then
    begin
      v_cursor_at:=(p_cursor->>'created_at')::timestamptz;
      v_cursor_id:=(p_cursor->>'event_id')::uuid;
    exception when others then
      raise exception 'invalid inbox cursor' using errcode='22023';
    end;
    v_has_cursor:=true;
  end if;
  for v_row in
    select e.id,e.title,e.body,e.route_key,e.created_at,e.deadline_at,e.topic,e.source_kind,s.read_at,r.id as resolution_id,
           app.c46_inbox_source_available(e.source_kind,v_actionable_source_available) as source_available
      from public.customer_in_app_inbox_events e
      left join public.customer_in_app_inbox_state s on s.event_id=e.id
      left join public.customer_in_app_inbox_resolutions r on r.event_id=e.id
     where e.business_id=v_context.business_id and e.identity_id=v_context.identity_id
       and e.link_id=v_context.link_id and s.dismissed_at is null
       and (v_filter='all' or (
         r.id is null
         and app.c46_inbox_source_available(e.source_kind,v_actionable_source_available)
         and s.read_at is null
       ))
       and (not v_has_cursor or (e.created_at,e.id) < (v_cursor_at,v_cursor_id))
     order by e.created_at desc,e.id desc
     limit v_limit+1
  loop
    v_count:=v_count+1;
    if v_count > v_limit then v_has_more:=true; exit; end if;
    v_items:=v_items || jsonb_build_array(jsonb_build_object(
      'event_id',v_row.id,'title',v_row.title,'body',v_row.body,
      'route_key',case when v_row.resolution_id is null and v_row.source_available then v_row.route_key else null end,
      'action_available',v_row.resolution_id is null and v_row.source_available,
      'created_at',v_row.created_at,'deadline_at',v_row.deadline_at,'topic',v_row.topic,
      'source',v_row.source_kind,'state',case when v_row.resolution_id is not null then 'resolved'
        when not v_row.source_available then 'source_unavailable'
        when v_row.read_at is null then 'unread' else 'read' end
    ));
    v_last_at:=v_row.created_at; v_last_id:=v_row.id;
  end loop;
  select exists (
    select 1 from (values ('value_expiry'::text),('reward_ready'::text),('visit_progress'::text),
                         ('birthday_benefit'::text),('booking_updates'::text)) topics(topic)
    join lateral app.c46_in_app_preference_for_context(
      v_context.business_id,v_context.identity_id,v_context.link_id,topics.topic
    ) p on true
    where p.opted_in and (v_actionable_source_available or topics.topic='booking_updates')
      and app.c46_in_quiet_hours(
      p.quiet_hours_timezone,p.quiet_hours_start,p.quiet_hours_end,statement_timestamp()
    )
  ) into v_quiet;
  return jsonb_build_object('items',v_items,'next_cursor',case when v_has_more then
    jsonb_build_object('limit',v_limit,'filter',v_filter,'created_at',v_last_at,'event_id',v_last_id) else null end,
    'filter',v_filter,'quiet_hours_active',v_quiet,
    'actionable_source_available',v_actionable_source_available);
end;
$$;

-- My Frenly is a multi-business wallet. These global readers stay self-scoped
-- to the same active identity and current verified links, then group each safe
-- item by its owning business for the bell and cross-program inbox.
create or replace function public.customer_get_in_app_inbox_global_count()
returns jsonb language plpgsql stable security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare v_context record; v_unread integer; v_quiet boolean; v_actionable_source_available boolean;
begin
  if not app.platform_feature_enabled('customer_in_app_inbox') then
    raise exception 'customer in-app inbox is not enabled' using errcode='0A000';
  end if;
  select * into v_context from app.c46_customer_inbox_global_context();
  v_actionable_source_available:=app.platform_feature_enabled('customer_actionable_wallet');
  select count(*)::integer into v_unread
    from public.customer_in_app_inbox_events e
    join public.customer_links cl on cl.id=e.link_id and cl.business_id=e.business_id
      and cl.client_id=e.client_id and cl.identity_id=e.identity_id and cl.auth_user_id=v_context.auth_user_id
      and cl.state='verified'
    left join public.customer_in_app_inbox_state s on s.event_id=e.id
    left join public.customer_in_app_inbox_resolutions r on r.event_id=e.id
   where e.identity_id=v_context.identity_id and e.auth_user_id=v_context.auth_user_id
     and r.id is null and s.dismissed_at is null and s.read_at is null
     and app.c46_inbox_source_available(e.source_kind,v_actionable_source_available);
  select exists (
    select 1 from public.customer_links cl
    join public.customer_notification_preferences p
      on p.business_id=cl.business_id and p.identity_id=cl.identity_id and p.link_id=cl.id
     and p.client_id=cl.client_id and p.channel='in_app' and p.opted_in
    where cl.identity_id=v_context.identity_id and cl.auth_user_id=v_context.auth_user_id and cl.state='verified'
      and p.topic in ('value_expiry','reward_ready','visit_progress','birthday_benefit','booking_updates')
      and (v_actionable_source_available or p.topic='booking_updates')
      and app.c46_in_quiet_hours(p.quiet_hours_timezone,p.quiet_hours_start,p.quiet_hours_end,statement_timestamp())
  ) into v_quiet;
  return jsonb_build_object('unread_count',v_unread,'quiet_hours_active',v_quiet,
    'actionable_source_available',v_actionable_source_available);
end;
$$;

create or replace function public.customer_list_in_app_inbox_global(
  p_cursor jsonb default '{}'::jsonb
)
returns jsonb language plpgsql stable security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_context record; v_limit integer:=20; v_filter text; v_cursor_at timestamptz; v_cursor_id uuid;
  v_has_cursor boolean:=false; v_count integer:=0; v_has_more boolean:=false;
  v_items jsonb:='[]'::jsonb; v_row record; v_last_at timestamptz; v_last_id uuid;
  v_actionable_source_available boolean;
begin
  if not app.platform_feature_enabled('customer_in_app_inbox') then
    raise exception 'customer in-app inbox is not enabled' using errcode='0A000';
  end if;
  select * into v_context from app.c46_customer_inbox_global_context();
  v_actionable_source_available:=app.platform_feature_enabled('customer_actionable_wallet');
  if p_cursor is null then p_cursor:='{}'::jsonb; end if;
  if jsonb_typeof(p_cursor)<>'object'
     or p_cursor-'limit'-'filter'-'created_at'-'event_id'<>'{}'::jsonb then
    raise exception 'invalid inbox cursor' using errcode='22023';
  end if;
  v_filter:=lower(coalesce(p_cursor->>'filter','all'));
  if v_filter not in ('all','unread') then raise exception 'invalid inbox filter' using errcode='22023'; end if;
  if p_cursor ? 'limit' then
    if (p_cursor->>'limit') !~ '^[0-9]{1,2}$' then raise exception 'invalid inbox cursor' using errcode='22023'; end if;
    v_limit:=least(greatest((p_cursor->>'limit')::integer,1),50);
  end if;
  if (p_cursor?'created_at')<>(p_cursor?'event_id') then raise exception 'invalid inbox cursor' using errcode='22023'; end if;
  if p_cursor?'created_at' then
    begin
      v_cursor_at:=(p_cursor->>'created_at')::timestamptz; v_cursor_id:=(p_cursor->>'event_id')::uuid;
    exception when others then raise exception 'invalid inbox cursor' using errcode='22023';
    end;
    v_has_cursor:=true;
  end if;
  for v_row in
    select e.id,e.title,e.body,e.route_key,e.created_at,e.deadline_at,e.topic,e.source_kind,
           b.name as business_name,b.slug as business_slug,s.read_at,r.id as resolution_id,
           app.c46_inbox_source_available(e.source_kind,v_actionable_source_available) as source_available
      from public.customer_in_app_inbox_events e
      join public.customer_links cl on cl.id=e.link_id and cl.business_id=e.business_id
        and cl.client_id=e.client_id and cl.identity_id=e.identity_id and cl.auth_user_id=v_context.auth_user_id
        and cl.state='verified'
      join public.businesses b on b.id=e.business_id
      left join public.customer_in_app_inbox_state s on s.event_id=e.id
      left join public.customer_in_app_inbox_resolutions r on r.event_id=e.id
     where e.identity_id=v_context.identity_id and e.auth_user_id=v_context.auth_user_id
       and s.dismissed_at is null and (v_filter='all' or (
         r.id is null
         and app.c46_inbox_source_available(e.source_kind,v_actionable_source_available)
         and s.read_at is null
       ))
       and (not v_has_cursor or (e.created_at,e.id)<(v_cursor_at,v_cursor_id))
     order by e.created_at desc,e.id desc limit v_limit+1
  loop
    v_count:=v_count+1; if v_count>v_limit then v_has_more:=true; exit; end if;
    v_items:=v_items||jsonb_build_array(jsonb_build_object(
      'event_id',v_row.id,'business',jsonb_build_object('name',v_row.business_name,'slug',v_row.business_slug),
      'route_key',case when v_row.resolution_id is null and v_row.source_available then v_row.route_key else null end,
      'action_available',v_row.resolution_id is null and v_row.source_available,
      'title',v_row.title,'body',v_row.body,'topic',v_row.topic,
      'source',v_row.source_kind,'deadline_at',v_row.deadline_at,'created_at',v_row.created_at,
      'state',case when v_row.resolution_id is not null then 'resolved'
        when not v_row.source_available then 'source_unavailable'
        when v_row.read_at is null then 'unread' else 'read' end
    ));
    v_last_at:=v_row.created_at; v_last_id:=v_row.id;
  end loop;
  return jsonb_build_object('items',v_items,'filter',v_filter,
    'actionable_source_available',v_actionable_source_available,'next_cursor',case when v_has_more then
    jsonb_build_object('limit',v_limit,'filter',v_filter,'created_at',v_last_at,'event_id',v_last_id)
    else null end);
end;
$$;

create or replace function public.customer_set_in_app_inbox_state(
  p_business_slug text,
  p_event_id uuid,
  p_operation text,
  p_idempotency_key uuid
)
returns jsonb language plpgsql security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_context record; v_event public.customer_in_app_inbox_events%rowtype;
  v_operation text; v_existing public.customer_in_app_inbox_state_operations%rowtype;
  v_request_hash text; v_now timestamptz:=statement_timestamp(); v_response jsonb;
  v_state public.customer_in_app_inbox_state%rowtype;
begin
  if not app.platform_feature_enabled('customer_in_app_inbox') then
    raise exception 'customer in-app inbox is not enabled' using errcode='0A000';
  end if;
  v_operation:=lower(btrim(coalesce(p_operation,'')));
  if p_event_id is null or p_idempotency_key is null or v_operation not in ('read','unread','dismiss') then
    raise exception 'invalid inbox state operation' using errcode='22023';
  end if;
  select * into v_context from app.c46_customer_inbox_context(p_business_slug);
  v_request_hash:=app.c46_sha256_hex(jsonb_build_object(
    'business_slug',v_context.business_slug,'event_id',p_event_id,'operation',v_operation
  )::text);
  perform pg_advisory_xact_lock(hashtextextended(
    'c46:in-app-state:'||v_context.identity_id::text||':'||p_idempotency_key::text,0
  ));
  select * into v_existing from public.customer_in_app_inbox_state_operations o
   where o.identity_id=v_context.identity_id and o.idempotency_key=p_idempotency_key;
  if found then
    if v_existing.request_hash is distinct from v_request_hash then
      raise exception 'idempotency key conflicts with another inbox state operation' using errcode='40001';
    end if;
    return v_existing.response;
  end if;
  select * into v_event from public.customer_in_app_inbox_events e
   where e.id=p_event_id and e.business_id=v_context.business_id and e.identity_id=v_context.identity_id
     and e.link_id=v_context.link_id and e.client_id=v_context.client_id
     and not exists (select 1 from public.customer_in_app_inbox_resolutions r where r.event_id=e.id)
   for update;
  if not found then raise exception 'inbox item is unavailable' using errcode='42501'; end if;
  perform set_config('app.c46_inbox_state_event',p_event_id::text,true);
  insert into public.customer_in_app_inbox_state(
    event_id,business_id,identity_id,auth_user_id,link_id,client_id,read_at,dismissed_at
  ) values (
    v_event.id,v_event.business_id,v_event.identity_id,v_event.auth_user_id,v_event.link_id,v_event.client_id,
    case when v_operation in ('read','dismiss') then v_now else null end,
    case when v_operation='dismiss' then v_now else null end
  ) on conflict (event_id) do update set
    -- Dismissal is terminal. A later read/unread request is still recorded as
    -- immutable operation evidence, but may never clear dismissed_at or
    -- resurrect the card. This also makes unread-vs-dismiss races converge on
    -- dismissed regardless of lock acquisition order.
    read_at=case
      when public.customer_in_app_inbox_state.dismissed_at is not null then public.customer_in_app_inbox_state.read_at
      when v_operation='unread' then null
      else coalesce(public.customer_in_app_inbox_state.read_at,v_now)
    end,
    dismissed_at=case
      when public.customer_in_app_inbox_state.dismissed_at is not null then public.customer_in_app_inbox_state.dismissed_at
      when v_operation='dismiss' then v_now
      else null
    end
  returning * into v_state;
  v_response:=jsonb_build_object('event_id',v_event.id,'state',
    case when v_state.dismissed_at is not null then 'dismissed'
         when v_state.read_at is not null then 'read' else 'unread' end
  );
  insert into public.customer_in_app_inbox_state_operations(
    event_id,business_id,identity_id,auth_user_id,link_id,client_id,operation,idempotency_key,request_hash,response
  ) values (
    v_event.id,v_event.business_id,v_event.identity_id,v_event.auth_user_id,v_event.link_id,v_event.client_id,
    v_operation,p_idempotency_key,v_request_hash,v_response
  );
  return v_response;
end;
$$;

-- C45 owns the prior capability response. C46 replaces it forward so clients
-- can fail closed without probing an inbox endpoint when this feature is off.
create or replace function public.get_customer_feature_capabilities()
returns jsonb language plpgsql stable security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
begin
  if auth.uid() is null then raise exception 'authenticated session required' using errcode='28000'; end if;
  return jsonb_build_object(
    'customer_identity',app.platform_feature_enabled('customer_identity'),
    'customer_claims',app.platform_feature_enabled('customer_claims'),
    'customer_wallet',app.platform_feature_enabled('customer_wallet'),
    'customer_actions',app.platform_feature_enabled('customer_actions'),
    'customer_notifications',app.platform_feature_enabled('customer_notifications'),
    'customer_email_otp',app.platform_feature_enabled('customer_email_otp'),
    'customer_phone_otp',app.platform_feature_enabled('customer_phone_otp'),
    'customer_whatsapp_otp',app.platform_feature_enabled('customer_whatsapp_otp'),
    'customer_phone_registration',app.platform_feature_enabled('customer_phone_registration'),
    'customer_phone_claims',app.platform_feature_enabled('customer_phone_claims'),
    'customer_actionable_wallet',app.platform_feature_enabled('customer_actionable_wallet'),
    'customer_birthday_benefits',app.platform_feature_enabled('customer_birthday_benefits'),
    'customer_in_app_inbox',app.platform_feature_enabled('customer_in_app_inbox')
  );
end;
$$;

revoke all on function app.c46_sha256_hex(text) from public, anon, authenticated;
revoke all on function app.c46_in_app_topic_allowed(text) from public, anon, authenticated;
revoke all on function app.c46_inbox_source_available(text,boolean) from public, anon, authenticated;
revoke all on function app.c46_iana_timezone_allowed(text) from public, anon, authenticated;
revoke all on function app.c46_in_quiet_hours(text,time without time zone,time without time zone,timestamptz) from public, anon, authenticated;
revoke all on function app.c46_customer_inbox_context(text) from public, anon, authenticated;
revoke all on function app.c46_customer_inbox_global_context() from public, anon, authenticated;
revoke all on function app.c46_in_app_preference_for_context(uuid,uuid,uuid,text) from public, anon, authenticated;
revoke all on function app.c46_append_only_guard() from public, anon, authenticated;
revoke all on function app.c46_inbox_state_guard() from public, anon, authenticated;
revoke all on function app.c46_customer_safe_inbox_candidates(jsonb) from public, anon, authenticated;
revoke all on function app.c46_customer_safe_booking_candidates(uuid,uuid,uuid) from public, anon, authenticated;
revoke all on function public.customer_set_in_app_inbox_preferences(text,text,boolean,text,time without time zone,time without time zone,uuid) from public, anon, authenticated;
revoke all on function public.customer_get_in_app_inbox_preferences(text) from public, anon, authenticated;
revoke all on function public.customer_sync_in_app_inbox(text,uuid) from public, anon, authenticated;
revoke all on function public.customer_sync_in_app_inbox_global(uuid) from public, anon, authenticated;
revoke all on function public.customer_get_in_app_inbox_count(text) from public, anon, authenticated;
revoke all on function public.customer_list_in_app_inbox(text,jsonb) from public, anon, authenticated;
revoke all on function public.customer_get_in_app_inbox_global_count() from public, anon, authenticated;
revoke all on function public.customer_list_in_app_inbox_global(jsonb) from public, anon, authenticated;
revoke all on function public.customer_set_in_app_inbox_state(text,uuid,text,uuid) from public, anon, authenticated;
revoke all on function public.get_customer_feature_capabilities() from public, anon;

grant execute on function public.customer_set_in_app_inbox_preferences(text,text,boolean,text,time without time zone,time without time zone,uuid) to authenticated;
grant execute on function public.customer_get_in_app_inbox_preferences(text) to authenticated;
grant execute on function public.customer_sync_in_app_inbox(text,uuid) to authenticated;
grant execute on function public.customer_sync_in_app_inbox_global(uuid) to authenticated;
grant execute on function public.customer_get_in_app_inbox_count(text) to authenticated;
grant execute on function public.customer_list_in_app_inbox(text,jsonb) to authenticated;
grant execute on function public.customer_get_in_app_inbox_global_count() to authenticated;
grant execute on function public.customer_list_in_app_inbox_global(jsonb) to authenticated;
grant execute on function public.customer_set_in_app_inbox_state(text,uuid,text,uuid) to authenticated;
grant execute on function public.get_customer_feature_capabilities() to authenticated;

commit;
