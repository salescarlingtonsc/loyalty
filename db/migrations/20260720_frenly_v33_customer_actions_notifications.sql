-- FRENLY v33 - CUSTOMER APPOINTMENT ACTIONS AND NOTIFICATION EVIDENCE
--
-- Local review candidate. This is deliberately an append-only customer request
-- boundary. It does not alter appointments, legacy change_requests, Turnstile
-- gateway functions, opaque management tokens, or invoke a delivery provider.

begin;

-- A composite key lets an action request prove that its appointment belongs to
-- the verified customer relationship without trusting a caller-supplied client.
alter table public.appointments
  add constraint appointments_id_business_client_uk unique (id, business_id, client_id);

create table public.customer_appointment_action_requests (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete restrict,
  identity_id uuid not null references public.customer_identities(id) on delete restrict,
  auth_user_id uuid not null references auth.users(id) on delete restrict,
  link_id uuid not null,
  client_id uuid not null,
  appointment_id uuid not null,
  action text not null check (action in ('cancel', 'reschedule')),
  proposed_at timestamptz,
  note text,
  status text not null default 'pending' check (status = 'pending'),
  idempotency_key text not null check (length(btrim(idempotency_key)) >= 8),
  request_hash text not null check (request_hash ~ '^[0-9a-f]{64}$'),
  created_at timestamptz not null default now(),
  constraint customer_appointment_action_requests_shape_check check (
    (action = 'cancel' and proposed_at is null)
    or (action = 'reschedule' and proposed_at is not null)
  ),
  constraint customer_appointment_action_requests_note_check check (
    note is null or (length(note) between 1 and 750 and note = btrim(note))
  ),
  constraint customer_appointment_action_requests_identity_auth_fk
    foreign key (identity_id, auth_user_id)
    references public.customer_identities(id, auth_user_id) on delete restrict,
  constraint customer_appointment_action_requests_link_scope_fk
    foreign key (link_id, business_id, client_id)
    references public.customer_links(id, business_id, client_id) on delete restrict,
  constraint customer_appointment_action_requests_appointment_scope_fk
    foreign key (appointment_id, business_id, client_id)
    references public.appointments(id, business_id, client_id) on delete restrict,
  constraint customer_appointment_action_requests_identity_idempotency_uk
    unique (identity_id, idempotency_key),
  constraint customer_appointment_action_requests_id_business_uk
    unique (id, business_id)
);

create index customer_appointment_action_requests_rate_idx
  on public.customer_appointment_action_requests (identity_id, created_at desc);
create index customer_appointment_action_requests_appointment_idx
  on public.customer_appointment_action_requests (business_id, appointment_id, created_at desc);

create table public.customer_notification_preferences (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete restrict,
  identity_id uuid not null references public.customer_identities(id) on delete restrict,
  auth_user_id uuid not null references auth.users(id) on delete restrict,
  link_id uuid not null,
  client_id uuid not null,
  channel text not null check (channel in ('email', 'in_app')),
  topic text not null check (topic in ('marketing', 'booking_updates', 'loyalty_updates')),
  opted_in boolean not null,
  consent_at timestamptz not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint customer_notification_preferences_identity_auth_fk
    foreign key (identity_id, auth_user_id)
    references public.customer_identities(id, auth_user_id) on delete restrict,
  constraint customer_notification_preferences_link_scope_fk
    foreign key (link_id, business_id, client_id)
    references public.customer_links(id, business_id, client_id) on delete restrict,
  constraint customer_notification_preferences_business_link_channel_topic_uk
    unique (business_id, link_id, channel, topic)
);

create table public.customer_preference_audit (
  id uuid primary key default gen_random_uuid(),
  preference_id uuid not null references public.customer_notification_preferences(id) on delete restrict,
  business_id uuid not null references public.businesses(id) on delete restrict,
  identity_id uuid not null references public.customer_identities(id) on delete restrict,
  auth_user_id uuid not null references auth.users(id) on delete restrict,
  link_id uuid not null,
  client_id uuid not null,
  channel text not null check (channel in ('email', 'in_app')),
  topic text not null check (topic in ('marketing', 'booking_updates', 'loyalty_updates')),
  opted_in boolean not null,
  consent_at timestamptz not null,
  idempotency_key text not null check (length(btrim(idempotency_key)) >= 8),
  request_hash text not null check (request_hash ~ '^[0-9a-f]{64}$'),
  created_at timestamptz not null default now(),
  constraint customer_preference_audit_link_scope_fk
    foreign key (link_id, business_id, client_id)
    references public.customer_links(id, business_id, client_id) on delete restrict,
  constraint customer_preference_audit_identity_idempotency_uk
    unique (identity_id, idempotency_key)
);

-- This is evidence for a future worker, not an assertion that any external
-- delivery system has accepted or delivered anything.
create table public.customer_notification_outbox (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete restrict,
  identity_id uuid not null references public.customer_identities(id) on delete restrict,
  link_id uuid not null,
  client_id uuid not null,
  action_request_id uuid,
  event_type text not null check (event_type in ('appointment_action_requested')),
  topic text not null check (topic = 'booking_updates'),
  channel text not null check (channel = 'in_app'),
  delivery_status text not null check (delivery_status in ('pending', 'suppressed', 'failed')),
  created_at timestamptz not null default now(),
  constraint customer_notification_outbox_link_scope_fk
    foreign key (link_id, business_id, client_id)
    references public.customer_links(id, business_id, client_id) on delete restrict,
  constraint customer_notification_outbox_request_scope_fk
    foreign key (action_request_id, business_id)
    references public.customer_appointment_action_requests(id, business_id) on delete restrict,
  constraint customer_notification_outbox_action_channel_uk
    unique (action_request_id, channel)
);

alter table public.customer_appointment_action_requests enable row level security;
alter table public.customer_notification_preferences enable row level security;
alter table public.customer_preference_audit enable row level security;
alter table public.customer_notification_outbox enable row level security;

revoke all privileges on table public.customer_appointment_action_requests
  from public, anon, authenticated;
revoke all privileges on table public.customer_notification_preferences
  from public, anon, authenticated;
revoke all privileges on table public.customer_preference_audit
  from public, anon, authenticated;
revoke all privileges on table public.customer_notification_outbox
  from public, anon, authenticated;

create or replace function app.v33_sha256_hex(p_value text)
returns text
language sql
immutable
set search_path to 'pg_catalog', 'extensions', 'pg_temp'
as $$
  select encode(extensions.digest(convert_to($1, 'UTF8'), 'sha256'), 'hex')
$$;

create or replace function app.v33_append_only_guard()
returns trigger
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
begin
  raise exception '% is append-only evidence', tg_table_name using errcode = '23000';
end;
$$;

create trigger customer_appointment_action_requests_immutable_guard
  before update or delete on public.customer_appointment_action_requests
  for each row execute function app.v33_append_only_guard();
create trigger customer_preference_audit_immutable_guard
  before update or delete on public.customer_preference_audit
  for each row execute function app.v33_append_only_guard();
create trigger customer_notification_outbox_immutable_guard
  before update or delete on public.customer_notification_outbox
  for each row execute function app.v33_append_only_guard();

create or replace function public.customer_request_appointment_action(
  p_business_slug text,
  p_appointment uuid,
  p_action text,
  p_proposed_at timestamptz,
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
  v_slug text := lower(btrim(coalesce(p_business_slug, '')));
  v_action text := lower(btrim(coalesce(p_action, '')));
  v_note text := nullif(btrim(coalesce(p_note, '')), '');
  v_identity_id uuid;
  v_link_id uuid;
  v_business_id uuid;
  v_client_id uuid;
  v_enabled_modules text[];
  v_request_id uuid;
  v_existing public.customer_appointment_action_requests%rowtype;
  v_request_hash text;
  v_response jsonb;
begin
  if v_actor is null then
    raise exception 'authenticated customer session required' using errcode = '28000';
  end if;
  if not app.platform_feature_enabled('customer_actions') then
    raise exception 'verified customer link and appointment required' using errcode = '42501';
  end if;
  if p_idempotency_key is null or length(btrim(p_idempotency_key)) < 8 then
    raise exception 'idempotency key must contain at least 8 characters' using errcode = '22023';
  end if;
  if v_action not in ('cancel', 'reschedule') then
    raise exception 'action must be cancel or reschedule' using errcode = '22023';
  end if;
  if v_action = 'cancel' and p_proposed_at is not null then
    raise exception 'cancel requests cannot include a proposed time' using errcode = '22023';
  end if;
  if v_action = 'reschedule' and (p_proposed_at is null or p_proposed_at <= now()) then
    raise exception 'reschedule time must be in the future' using errcode = '22023';
  end if;
  if v_note is not null and length(v_note) > 750 then
    raise exception 'note must not exceed 750 characters' using errcode = '22023';
  end if;

  p_idempotency_key := btrim(p_idempotency_key);
  v_request_hash := app.v33_sha256_hex(jsonb_build_object(
    'business_slug', v_slug,
    'appointment', p_appointment,
    'action', v_action,
    'proposed_at', p_proposed_at,
    'note', v_note
  )::text);
  perform pg_advisory_xact_lock(hashtextextended(
    'v33:appointment-action:' || v_actor::text || ':' || p_idempotency_key, 0
  ));

  select * into v_existing
    from public.customer_appointment_action_requests r
   where r.identity_id = (
           select ci.id from public.customer_identities ci
            where ci.auth_user_id = v_actor and ci.status = 'active'
         )
     and r.idempotency_key = p_idempotency_key;
  if found then
    if v_existing.request_hash is distinct from v_request_hash then
      raise exception 'idempotency key was already used for another action request' using errcode = '22023';
    end if;
    return jsonb_build_object('request_id', v_existing.id, 'status', v_existing.status);
  end if;

  -- The slug merely narrows the verified customer relationship. The actual
  -- business, client, identity, and link are all derived from auth.uid().
  select ci.id, l.id, l.business_id, l.client_id, coalesce(b.enabled_modules, '{}'::text[])
    into v_identity_id, v_link_id, v_business_id, v_client_id, v_enabled_modules
    from public.customer_identities ci
    join public.customer_links l
      on l.identity_id = ci.id
     and l.auth_user_id = v_actor
     and l.state = 'verified'
    join public.businesses b on b.id = l.business_id
   where ci.auth_user_id = v_actor
     and ci.status = 'active'
     and b.slug = v_slug
   limit 1;
  if not found or not ('appointments' = any(v_enabled_modules)) then
    raise exception 'verified customer link and appointment required' using errcode = '42501';
  end if;

  perform 1
    from public.appointments a
   where a.id = p_appointment
     and a.business_id = v_business_id
     and a.client_id = v_client_id
     and a.status = 'booked'
     and a.starts_at > now()
   for share;
  if not found then
    raise exception 'verified customer link and appointment required' using errcode = '42501';
  end if;

  if (select count(*) from public.customer_appointment_action_requests r
       where r.identity_id = v_identity_id
         and r.created_at >= now() - interval '15 minutes') >= 5 then
    raise exception 'too many appointment action requests; try later' using errcode = '42901';
  end if;

  v_request_id := gen_random_uuid();
  insert into public.customer_appointment_action_requests (
    id, business_id, identity_id, auth_user_id, link_id, client_id,
    appointment_id, action, proposed_at, note, idempotency_key, request_hash
  ) values (
    v_request_id, v_business_id, v_identity_id, v_actor, v_link_id, v_client_id,
    p_appointment, v_action, p_proposed_at, v_note, p_idempotency_key, v_request_hash
  );
  insert into public.customer_notification_outbox (
    business_id, identity_id, link_id, client_id, action_request_id,
    event_type, topic, channel, delivery_status
  ) values (
    v_business_id, v_identity_id, v_link_id, v_client_id, v_request_id,
    'appointment_action_requested', 'booking_updates', 'in_app',
    case when not app.platform_feature_enabled('customer_notifications') or exists (
      select 1 from public.customer_notification_preferences p
       where p.business_id = v_business_id
         and p.link_id = v_link_id
         and p.channel = 'in_app'
         and p.topic = 'booking_updates'
         and not p.opted_in
    ) then 'suppressed' else 'pending' end
  );

  v_response := jsonb_build_object('request_id', v_request_id, 'status', 'pending');
  return v_response;
end;
$$;

create or replace function public.customer_get_notification_preferences(p_business_slug text)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_actor uuid := auth.uid();
  v_identity_id uuid;
  v_link_id uuid;
  v_business_id uuid;
begin
  if v_actor is null then
    raise exception 'authenticated customer session required' using errcode = '28000';
  end if;
  if not app.platform_feature_enabled('customer_notifications') then
    raise exception 'verified customer link required' using errcode = '42501';
  end if;
  select ci.id, l.id, l.business_id
    into v_identity_id, v_link_id, v_business_id
    from public.customer_identities ci
    join public.customer_links l
      on l.identity_id = ci.id and l.auth_user_id = v_actor and l.state = 'verified'
    join public.businesses b on b.id = l.business_id
   where ci.auth_user_id = v_actor and ci.status = 'active'
     and b.slug = lower(btrim(coalesce(p_business_slug, '')))
   limit 1;
  if not found then
    raise exception 'verified customer link required' using errcode = '42501';
  end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'channel', p.channel,
      'topic', p.topic,
      'opted_in', p.opted_in,
      'consent_at', p.consent_at
    ) order by p.channel, p.topic)
      from public.customer_notification_preferences p
     where p.business_id = v_business_id
       and p.identity_id = v_identity_id
       and p.link_id = v_link_id
  ), '[]'::jsonb);
end;
$$;

create or replace function public.customer_set_notification_preference(
  p_business_slug text,
  p_channel text,
  p_topic text,
  p_opted_in boolean,
  p_idempotency_key text
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_actor uuid := auth.uid();
  v_channel text := lower(btrim(coalesce(p_channel, '')));
  v_topic text := lower(btrim(coalesce(p_topic, '')));
  v_identity_id uuid;
  v_link_id uuid;
  v_business_id uuid;
  v_client_id uuid;
  v_preference_id uuid;
  v_existing public.customer_preference_audit%rowtype;
  v_request_hash text;
  v_now timestamptz := now();
begin
  if v_actor is null then
    raise exception 'authenticated customer session required' using errcode = '28000';
  end if;
  if not app.platform_feature_enabled('customer_notifications') then
    raise exception 'verified customer link required' using errcode = '42501';
  end if;
  if p_idempotency_key is null or length(btrim(p_idempotency_key)) < 8 then
    raise exception 'idempotency key must contain at least 8 characters' using errcode = '22023';
  end if;
  if v_channel not in ('email', 'in_app') or v_topic not in ('marketing', 'booking_updates', 'loyalty_updates')
     or p_opted_in is null then
    raise exception 'unsupported notification preference' using errcode = '22023';
  end if;
  p_idempotency_key := btrim(p_idempotency_key);
  v_request_hash := app.v33_sha256_hex(jsonb_build_object(
    'business_slug', lower(btrim(coalesce(p_business_slug, ''))),
    'channel', v_channel, 'topic', v_topic, 'opted_in', p_opted_in
  )::text);
  perform pg_advisory_xact_lock(hashtextextended(
    'v33:notification-preference:' || v_actor::text || ':' || p_idempotency_key, 0
  ));

  select ci.id, l.id, l.business_id, l.client_id
    into v_identity_id, v_link_id, v_business_id, v_client_id
    from public.customer_identities ci
    join public.customer_links l
      on l.identity_id = ci.id and l.auth_user_id = v_actor and l.state = 'verified'
    join public.businesses b on b.id = l.business_id
   where ci.auth_user_id = v_actor and ci.status = 'active'
     and b.slug = lower(btrim(coalesce(p_business_slug, '')))
   limit 1;
  if not found then
    raise exception 'verified customer link required' using errcode = '42501';
  end if;

  select * into v_existing
    from public.customer_preference_audit a
   where a.identity_id = v_identity_id and a.idempotency_key = p_idempotency_key;
  if found then
    if v_existing.request_hash is distinct from v_request_hash then
      raise exception 'idempotency key was already used for another preference' using errcode = '22023';
    end if;
    return jsonb_build_object(
      'channel', v_existing.channel,
      'topic', v_existing.topic,
      'opted_in', v_existing.opted_in,
      'consent_at', v_existing.consent_at
    );
  end if;

  insert into public.customer_notification_preferences (
    business_id, identity_id, auth_user_id, link_id, client_id,
    channel, topic, opted_in, consent_at, updated_at
  ) values (
    v_business_id, v_identity_id, v_actor, v_link_id, v_client_id,
    v_channel, v_topic, p_opted_in, v_now, v_now
  )
  on conflict (business_id, link_id, channel, topic) do update
    set opted_in = excluded.opted_in,
        consent_at = excluded.consent_at,
        updated_at = excluded.updated_at
  returning id into v_preference_id;

  insert into public.customer_preference_audit (
    preference_id, business_id, identity_id, auth_user_id, link_id, client_id,
    channel, topic, opted_in, consent_at, idempotency_key, request_hash
  ) values (
    v_preference_id, v_business_id, v_identity_id, v_actor, v_link_id, v_client_id,
    v_channel, v_topic, p_opted_in, v_now, p_idempotency_key, v_request_hash
  );
  return jsonb_build_object(
    'channel', v_channel,
    'topic', v_topic,
    'opted_in', p_opted_in,
    'consent_at', v_now
  );
end;
$$;

revoke all on function app.v33_sha256_hex(text) from public, anon, authenticated;
revoke all on function app.v33_append_only_guard() from public, anon, authenticated;
revoke all on function public.customer_request_appointment_action(p_business_slug text,
  p_appointment uuid,
  p_action text,
  p_proposed_at timestamptz,
  p_note text,
  p_idempotency_key text) from public, anon, authenticated;
revoke all on function public.customer_get_notification_preferences(text)
  from public, anon, authenticated;
revoke all on function public.customer_set_notification_preference(
  text, text, text, boolean, text
) from public, anon, authenticated;

grant execute on function public.customer_request_appointment_action(p_business_slug text,
  p_appointment uuid,
  p_action text,
  p_proposed_at timestamptz,
  p_note text,
  p_idempotency_key text) to authenticated;
grant execute on function public.customer_get_notification_preferences(text)
  to authenticated;
grant execute on function public.customer_set_notification_preference(
  text, text, text, boolean, text
) to authenticated;

commit;
