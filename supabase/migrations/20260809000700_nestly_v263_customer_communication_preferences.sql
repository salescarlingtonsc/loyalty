-- NESTLY v263 - CUSTOMER COMMUNICATION PREFERENCES
--
-- Owner ruling 2026-08-09, answering the marketing/push audit: promotional push
-- IS intended, "they can switch off or on, default is all on", and one consent
-- tick "would approve all sorts of marketing including push notifications and
-- calling or whatsapp or sms or email". The reference shape the owner supplied
-- is Grab's Communications screen: purpose categories, a channel row per
-- category, most switches on by default.
--
-- Three consequences, all of them structural rather than cosmetic:
--
-- 1. The existing v33 store (public.customer_notification_preferences) is
--    per-business-link, its channel domain is {email,in_app}, and an ABSENT row
--    means DO NOT SEND. That is the opposite of the ruling and it is why the
--    2026-08-09 audit found the table empty and no promotion alert ever
--    delivered. It also cannot carry a per-account preference at all: a person
--    who joins a fourth programme would silently arrive with no preference for
--    it. So V263 stores an ACCOUNT-scoped, DEVIATION-ONLY matrix beside it
--    rather than re-pointing the v33 rows, whose meaning other readers depend
--    on. An explicit v33 withdrawal is still honoured (see the fan-out below);
--    only its default flips.
--
-- 2. Absence means ON. Nothing is written at signup, no backfill exists, and a
--    customer created a minute from now is reachable without a row. Only a
--    deviation is durable.
--
-- 3. Transactional messages are out of scope and must stay that way. The
--    category check constraint below admits exactly three MARKETING categories,
--    and app.communication_category_for_topic_v263 maps the transactional topic
--    'booking_updates' to NULL. A row that suppresses an appointment
--    confirmation therefore cannot be stored, not merely cannot be written.
--
-- PDPA note for counsel, not a compliance claim: this migration makes
-- withdrawal per-channel and all-at-once, and records both directions as
-- append-only evidence. It does not assert that any particular consent wording
-- or retention period is sufficient.

begin;

-- The taxonomy lives in one immutable place because four things must agree on
-- it: the two table constraints, the read RPC that renders the screen, the two
-- write RPCs, and the send-path gate.
create or replace function app.communication_categories_v263()
returns text[]
language sql
immutable
set search_path to 'pg_catalog', 'pg_temp'
as $$
  select array['business_offers', 'rewards_and_points', 'peekaa_updates']::text[]
$$;

create or replace function app.communication_channels_v263()
returns text[]
language sql
immutable
set search_path to 'pg_catalog', 'pg_temp'
as $$
  select array['in_app', 'push', 'email', 'sms', 'whatsapp', 'call']::text[]
$$;

-- 'booking_updates' is deliberately absent: an appointment confirmation is not
-- marketing, so it has no category and therefore no switch anywhere.
create or replace function app.communication_category_for_topic_v263(p_topic text)
returns text
language sql
immutable
set search_path to 'pg_catalog', 'pg_temp'
as $$
  select case p_topic
    when 'promotion_alerts' then 'business_offers'
    when 'marketing' then 'business_offers'
    when 'loyalty_updates' then 'rewards_and_points'
    when 'value_expiry' then 'rewards_and_points'
    when 'reward_ready' then 'rewards_and_points'
    when 'visit_progress' then 'rewards_and_points'
    when 'birthday_benefit' then 'rewards_and_points'
    else null
  end
$$;

create table public.customer_communication_preferences_v263 (
  identity_id uuid not null references public.customer_identities(id) on delete restrict,
  auth_user_id uuid not null references auth.users(id) on delete restrict,
  category text not null check (category in ('business_offers', 'rewards_and_points', 'peekaa_updates')),
  channel text not null check (channel in ('in_app', 'push', 'email', 'sms', 'whatsapp', 'call')),
  enabled boolean not null,
  decided_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (identity_id, category, channel),
  constraint customer_communication_preferences_v263_identity_auth_fk
    foreign key (identity_id, auth_user_id)
    references public.customer_identities(id, auth_user_id) on delete restrict
);
comment on table public.customer_communication_preferences_v263 is
  'Account-scoped marketing category x channel deviations. A missing row is ON. Transactional messages have no category and cannot appear here.';

alter table public.customer_communication_preferences_v263 enable row level security;
revoke all privileges on table public.customer_communication_preferences_v263
  from public, anon, authenticated;

create table public.customer_communication_preference_audit_v263 (
  id uuid primary key default gen_random_uuid(),
  identity_id uuid not null references public.customer_identities(id) on delete restrict,
  auth_user_id uuid not null references auth.users(id) on delete restrict,
  scope text not null check (scope in ('all', 'single')),
  category text check (category in ('business_offers', 'rewards_and_points', 'peekaa_updates')),
  channel text check (channel in ('in_app', 'push', 'email', 'sms', 'whatsapp', 'call')),
  enabled boolean not null,
  source text not null check (source in ('communications_screen')),
  request_hash text not null check (request_hash ~ '^[0-9a-f]{64}$'),
  occurred_at timestamptz not null default now(),
  constraint customer_communication_preference_audit_v263_shape_check check (
    (scope = 'all' and category is null and channel is null)
    or (scope = 'single' and category is not null and channel is not null)
  ),
  constraint customer_communication_preference_audit_v263_identity_auth_fk
    foreign key (identity_id, auth_user_id)
    references public.customer_identities(id, auth_user_id) on delete restrict
);
comment on table public.customer_communication_preference_audit_v263 is
  'Append-only evidence of the single all-channel marketing grant and of every subsequent per-channel withdrawal or re-grant.';

alter table public.customer_communication_preference_audit_v263 enable row level security;
revoke all privileges on table public.customer_communication_preference_audit_v263
  from public, anon, authenticated;

create index customer_communication_preference_audit_v263_identity_idx
  on public.customer_communication_preference_audit_v263 (identity_id, occurred_at desc);

-- Reuses the v33 append-only guard rather than declaring a second one; the
-- error text and the discipline are already the reviewed ones.
create trigger customer_communication_preference_audit_v263_immutable
before update or delete on public.customer_communication_preference_audit_v263
for each row execute function app.v33_append_only_guard();

-- The gate. A NULL category is a transactional message and always passes; that
-- is what makes suppression of a receipt or a booking confirmation impossible
-- through this path rather than merely unlikely.
create or replace function app.customer_communication_allows_v263(
  p_identity uuid,
  p_category text,
  p_channel text
)
returns boolean
language sql
stable
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
  select p_category is null or not exists (
    select 1
      from public.customer_communication_preferences_v263 preference
     where preference.identity_id = p_identity
       and preference.category = p_category
       and preference.channel = p_channel
       and not preference.enabled
  )
$$;
revoke all on function app.customer_communication_allows_v263(uuid, text, text)
  from public, anon, authenticated;

create or replace function app.customer_communication_topic_allows_v263(
  p_identity uuid,
  p_topic text,
  p_channel text
)
returns boolean
language sql
stable
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
  select app.customer_communication_allows_v263(
    p_identity, app.communication_category_for_topic_v263(p_topic), p_channel
  )
$$;
revoke all on function app.customer_communication_topic_allows_v263(uuid, text, text)
  from public, anon, authenticated;

create or replace function app.customer_communication_identity_v263()
returns uuid
language plpgsql
stable
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_actor uuid := auth.uid();
  v_identity uuid;
begin
  if v_actor is null then
    raise exception 'authenticated customer session required' using errcode = '28000';
  end if;
  select identity.id into v_identity
    from public.customer_identities identity
   where identity.auth_user_id = v_actor
     and identity.status = 'active'
   limit 1;
  if v_identity is null then
    raise exception 'active customer account required' using errcode = '42501';
  end if;
  return v_identity;
end;
$$;
revoke all on function app.customer_communication_identity_v263()
  from public, anon, authenticated;

-- The screen renders from exactly this call. Every category x channel is
-- returned with its EFFECTIVE value so the client never has to reproduce the
-- default rule, which is the way a default silently drifts apart from the gate.
create or replace function public.customer_get_communication_preferences_v263()
returns jsonb
language plpgsql
stable
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_identity uuid := app.customer_communication_identity_v263();
  v_result jsonb;
begin
  select jsonb_build_object(
    'categories', coalesce(jsonb_agg(category_row.entry order by category_row.ordinality), '[]'::jsonb),
    'all_enabled', not exists (
      select 1
        from public.customer_communication_preferences_v263 preference
       where preference.identity_id = v_identity
         and not preference.enabled
    )
  )
  into v_result
  from (
    select
      catalog.ordinality,
      jsonb_build_object(
        'category', catalog.category,
        'channels', (
          select coalesce(jsonb_agg(
            jsonb_build_object(
              'channel', channels.channel,
              'enabled', coalesce((
                select preference.enabled
                  from public.customer_communication_preferences_v263 preference
                 where preference.identity_id = v_identity
                   and preference.category = catalog.category
                   and preference.channel = channels.channel
              ), true)
            ) order by channels.ordinality
          ), '[]'::jsonb)
          from unnest(app.communication_channels_v263()) with ordinality
            as channels(channel, ordinality)
        )
      ) as entry
    from unnest(app.communication_categories_v263()) with ordinality
      as catalog(category, ordinality)
  ) as category_row;
  return v_result;
end;
$$;

create or replace function public.customer_set_communication_preference_v263(
  p_category text,
  p_channel text,
  p_enabled boolean
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_actor uuid := auth.uid();
  v_identity uuid := app.customer_communication_identity_v263();
  v_category text := lower(btrim(coalesce(p_category, '')));
  v_channel text := lower(btrim(coalesce(p_channel, '')));
  v_now timestamptz := now();
begin
  if p_enabled is null
     or not (v_category = any (app.communication_categories_v263()))
     or not (v_channel = any (app.communication_channels_v263())) then
    raise exception 'unsupported communication preference' using errcode = '22023';
  end if;

  insert into public.customer_communication_preferences_v263 (
    identity_id, auth_user_id, category, channel, enabled, decided_at, updated_at
  ) values (
    v_identity, v_actor, v_category, v_channel, p_enabled, v_now, v_now
  )
  on conflict (identity_id, category, channel) do update
    set enabled = excluded.enabled,
        decided_at = excluded.decided_at,
        updated_at = excluded.updated_at,
        auth_user_id = excluded.auth_user_id;

  insert into public.customer_communication_preference_audit_v263 (
    identity_id, auth_user_id, scope, category, channel, enabled, source, request_hash
  ) values (
    v_identity, v_actor, 'single', v_category, v_channel, p_enabled, 'communications_screen',
    app.v33_sha256_hex(jsonb_build_object(
      'identity_id', v_identity, 'category', v_category,
      'channel', v_channel, 'enabled', p_enabled
    )::text)
  );

  return jsonb_build_object(
    'category', v_category,
    'channel', v_channel,
    'enabled', p_enabled,
    'decided_at', v_now
  );
end;
$$;

-- The owner's single tick, and its mirror image. Granting DELETES the
-- deviations, which is what restores "absence means on" instead of writing a
-- wall of true rows that would then have to be maintained as the taxonomy
-- grows. Withdrawing writes an explicit false for every pair, so a later added
-- category cannot quietly re-enable itself for someone who said no to
-- everything.
create or replace function public.customer_set_all_communications_v263(p_enabled boolean)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_actor uuid := auth.uid();
  v_identity uuid := app.customer_communication_identity_v263();
  v_now timestamptz := now();
begin
  if p_enabled is null then
    raise exception 'unsupported communication preference' using errcode = '22023';
  end if;

  if p_enabled then
    delete from public.customer_communication_preferences_v263 preference
     where preference.identity_id = v_identity;
  else
    insert into public.customer_communication_preferences_v263 (
      identity_id, auth_user_id, category, channel, enabled, decided_at, updated_at
    )
    select v_identity, v_actor, catalog.category, channels.channel, false, v_now, v_now
      from unnest(app.communication_categories_v263()) as catalog(category)
     cross join unnest(app.communication_channels_v263()) as channels(channel)
    on conflict (identity_id, category, channel) do update
      set enabled = false,
          decided_at = excluded.decided_at,
          updated_at = excluded.updated_at,
          auth_user_id = excluded.auth_user_id;
  end if;

  insert into public.customer_communication_preference_audit_v263 (
    identity_id, auth_user_id, scope, category, channel, enabled, source, request_hash
  ) values (
    v_identity, v_actor, 'all', null, null, p_enabled, 'communications_screen',
    app.v33_sha256_hex(jsonb_build_object(
      'identity_id', v_identity, 'scope', 'all', 'enabled', p_enabled
    )::text)
  );

  return jsonb_build_object('all_enabled', p_enabled, 'decided_at', v_now);
end;
$$;

-- ---------------------------------------------------------------------------
-- Enforcement. A preference nobody reads is theatre, so both existing
-- promotional send paths are replaced in full here rather than spliced.
-- ---------------------------------------------------------------------------

-- Replaces the v255 definition. Two changes, both in the recipients CTE:
-- the v33 preference becomes a LEFT JOIN with coalesce(...,true) so absence is
-- consent (owner ruling) while an EXPLICIT v33 withdrawal still wins, and the
-- V263 account-level switch for offers-in-app is consulted.
create or replace function app.enqueue_promotion_alert_v122(
  p_promotion uuid,
  p_source_kind text
)
returns integer
language plpgsql
security definer
set search_path = pg_catalog, public, app, pg_temp
as $$
declare
  v_content public.business_customer_content_v95%rowtype;
  v_source_version text;
  v_label text;
  v_inserted integer:=0;
begin
  if p_source_kind not in ('v122_promotion_new','v122_promotion_expiry') then
    raise exception 'unsupported promotion alert kind' using errcode='22023';
  end if;
  select * into v_content
  from public.business_customer_content_v95 content
  where content.id=p_promotion
    and content.content_type='offer'
    and content.metadata->>'schema'='nestly.promotion.v104'
    and content.active
    and content.branch_id is null
    and (content.starts_at is null or content.starts_at<=now())
    and content.ends_at>now();
  if not found then return 0; end if;
  if not exists(
    select 1 from public.business_media_assets_v95 asset
    where asset.business_id=v_content.business_id
      and asset.asset_kind='offer'
      and asset.entity_id=v_content.id
      and asset.customer_visible
      and asset.branch_id is null
  ) then
    return 0;
  end if;
  v_source_version:=case when p_source_kind='v122_promotion_new'
    then coalesce(v_content.metadata->>'published_once_at','missing')
    else coalesce(v_content.metadata->>'published_once_at','missing')
      ||':'||v_content.ends_at::text end;

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(
      'v122:promotion-alert:'||v_content.id::text||':'||p_source_kind,0
    )
  );
  if exists(
    select 1 from public.promotion_alert_runs_v122 run
    where run.promotion_id=v_content.id
      and run.source_kind=p_source_kind
      and run.source_version=v_source_version
  ) then
    return 0;
  end if;

  select coalesce(
    (
      select nullif(btrim(left(copy_row.name,200)),'')
      from public.business_localized_copy_v95 copy_row
      where copy_row.business_id=v_content.business_id
        and copy_row.entity_type='offer'
        and copy_row.entity_id=v_content.id
      order by (copy_row.locale='en') desc,copy_row.locale
      limit 1
    ),
    'Promotion'
  ) into v_label;

  with recipients as(
    select
      link.business_id,link.identity_id,link.auth_user_id,
      link.id as link_id,link.client_id
    from public.customer_links link
    left join public.customer_notification_preferences preference
      on preference.business_id=link.business_id
     and preference.identity_id=link.identity_id
     and preference.auth_user_id=link.auth_user_id
     and preference.link_id=link.id
     and preference.channel='in_app'
     and preference.topic='promotion_alerts'
    where link.business_id=v_content.business_id
      and link.state='verified'
      and coalesce(preference.opted_in,true)
      and app.customer_communication_allows_v263(
        link.identity_id,'business_offers','in_app'
      )
  ),
  enqueued as(
    insert into public.customer_in_app_inbox_events(
      business_id,identity_id,auth_user_id,link_id,client_id,
      source_kind,topic,route_key,source_fingerprint,dedupe_key,
      title,body,deadline_at
    )
    select
      recipient.business_id,recipient.identity_id,recipient.auth_user_id,
      recipient.link_id,recipient.client_id,
      p_source_kind,'promotion_alerts','wallet_business',
      app.c46_sha256_hex((jsonb_build_object(
        'promotion_id',v_content.id,'source_kind',p_source_kind,
        'published_once_at',v_content.metadata->>'published_once_at'
      ) || case when p_source_kind='v122_promotion_expiry'
        then jsonb_build_object('ends_at',v_content.ends_at)
        else '{}'::jsonb end)::text),
      app.c46_sha256_hex((jsonb_build_object(
        'business_id',recipient.business_id,'identity_id',recipient.identity_id,
        'promotion_id',v_content.id,'source_kind',p_source_kind,
        'published_once_at',v_content.metadata->>'published_once_at'
      ) || case when p_source_kind='v122_promotion_expiry'
        then jsonb_build_object('ends_at',v_content.ends_at)
        else '{}'::jsonb end)::text),
      case when p_source_kind='v122_promotion_new'
        then 'New promotion available' else 'Promotion ending soon' end,
      case when p_source_kind='v122_promotion_new'
        then 'Open this programme to view the latest promotion.'
        else 'Open this programme before the current promotion ends.' end,
      v_content.ends_at
    from recipients recipient
    on conflict(identity_id,dedupe_key) do nothing
    returning id,business_id,identity_id,link_id,client_id
  ),
  recorded as(
    insert into public.campaign_send_records_v255(
      business_id,campaign_kind,campaign_ref_id,send_kind,campaign_label,
      channel,inbox_event_id,identity_id,link_id,client_id
    )
    select
      enqueued.business_id,'promotion',v_content.id,p_source_kind,v_label,
      'in_app',enqueued.id,enqueued.identity_id,enqueued.link_id,
      enqueued.client_id
    from enqueued
    on conflict do nothing
    returning 1
  )
  select count(*)::integer into v_inserted from enqueued;

  if v_inserted>0 then
    insert into public.promotion_alert_runs_v122(
      promotion_id,source_kind,source_version
    ) values(
      v_content.id,p_source_kind,v_source_version
    ) on conflict do nothing;
  end if;
  return v_inserted;
end
$$;
revoke all privileges on function app.enqueue_promotion_alert_v122(uuid,text)
  from public,anon,authenticated,service_role;

-- Restated verbatim, NOT a change: v255 already added the two v122 promotion
-- source kinds to this allowlist when it fixed the dispatcher, and production
-- was verified to hold exactly these eight pairs before v263 was applied. The
-- definition is repeated here only so the canonical chain replays to the same
-- state; re-running it against production is a no-op. What v263 actually adds
-- is the 'business_offers'/'push' switch below, which is what makes an
-- eligible promotional push optional for the customer receiving it.
create or replace function app.customer_push_event_eligible_v95(
  p_source_kind text,p_topic text
)
returns boolean language sql immutable
set search_path to 'pg_catalog','pg_temp'
as $$
  select (p_source_kind,p_topic) in (
    ('c44_actionable_wallet','value_expiry'),
    ('c44_actionable_wallet','reward_ready'),
    ('c44_actionable_wallet','visit_progress'),
    ('c45_birthday_benefit','birthday_benefit'),
    ('v33_booking_action','booking_updates'),
    ('v48_appointment_reschedule','booking_updates'),
    ('v122_promotion_new','promotion_alerts'),
    ('v122_promotion_expiry','promotion_alerts')
  )
$$;
revoke all on function app.customer_push_event_eligible_v95(text,text)
  from public, anon, authenticated;

-- Replaces the v95 definition. Same two changes in both the enqueue select and
-- the lease candidates: absence of a v33 row is consent, and the V263 'push'
-- switch for the event's category is enforced server-side. The category of
-- 'booking_updates' is NULL, so an appointment push cannot be gated off here.
create or replace function public.internal_customer_push_claim_v95(
  p_worker_id uuid,p_limit integer default 25,p_lease_seconds integer default 60
)
returns jsonb language plpgsql security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare v_limit integer; v_lease interval; v_result jsonb;
begin
  if p_worker_id is null then raise exception 'worker id is required' using errcode='22023'; end if;
  v_limit:=least(greatest(coalesce(p_limit,25),1),100);
  if coalesce(p_lease_seconds,60) not between 15 and 300 then
    raise exception 'lease seconds must be between 15 and 300' using errcode='22023';
  end if;
  v_lease:=make_interval(secs=>p_lease_seconds);

  update public.customer_push_deliveries_v95
     set status=case when attempt_count>=5 then 'failed' else 'retry' end,
         next_attempt_at=case when attempt_count>=5 then next_attempt_at else now() end,
         lease_token=null,leased_by=null,lease_until=null,
         completed_at=case when attempt_count>=5 then now() else null end,
         updated_at=now(),
         last_error_code=case when attempt_count>=5 then 'lease_exhausted' else 'lease_expired' end
   where status='leased' and lease_until<now();

  insert into public.customer_push_deliveries_v95(
    event_id,subscription_id,identity_id,auth_user_id
  )
  select event.id,subscription.id,event.identity_id,event.auth_user_id
    from public.customer_in_app_inbox_events event
    join public.customer_push_subscriptions_v95 subscription
      on subscription.identity_id=event.identity_id
     and subscription.auth_user_id=event.auth_user_id
     and subscription.status='active'
    left join public.customer_notification_preferences preference
      on preference.business_id=event.business_id
     and preference.identity_id=event.identity_id
     and preference.auth_user_id=event.auth_user_id
     and preference.link_id=event.link_id
     and preference.channel='in_app'
     and preference.topic=event.topic
    left join public.customer_in_app_inbox_state state on state.event_id=event.id
    left join public.customer_in_app_inbox_resolutions resolution on resolution.event_id=event.id
   where app.customer_push_event_eligible_v95(event.source_kind,event.topic)
     and coalesce(preference.opted_in,true)
     and app.customer_communication_topic_allows_v263(
       event.identity_id,event.topic,'push'
     )
     and state.dismissed_at is null and resolution.id is null
     and event.created_at>=subscription.created_at
     and (event.deadline_at is null or event.deadline_at>statement_timestamp())
     and not app.c46_in_quiet_hours(
       preference.quiet_hours_timezone,preference.quiet_hours_start,
       preference.quiet_hours_end,statement_timestamp()
     )
  on conflict(event_id,subscription_id) do nothing;

  with candidates as (
    select delivery.id
      from public.customer_push_deliveries_v95 delivery
      join public.customer_push_subscriptions_v95 subscription
        on subscription.id=delivery.subscription_id and subscription.status='active'
      join public.customer_in_app_inbox_events event on event.id=delivery.event_id
      left join public.customer_notification_preferences preference
        on preference.business_id=event.business_id
       and preference.identity_id=event.identity_id
       and preference.auth_user_id=event.auth_user_id
       and preference.link_id=event.link_id
       and preference.channel='in_app'
       and preference.topic=event.topic
      left join public.customer_in_app_inbox_state state
        on state.event_id=event.id
      left join public.customer_in_app_inbox_resolutions resolution
        on resolution.event_id=event.id
     where delivery.status in ('queued','retry')
       and coalesce(preference.opted_in,true)
       and app.customer_communication_topic_allows_v263(
         event.identity_id,event.topic,'push'
       )
       and delivery.next_attempt_at<=now() and delivery.attempt_count<5
       and state.dismissed_at is null and resolution.id is null
       and (event.deadline_at is null or event.deadline_at>statement_timestamp())
       and not app.c46_in_quiet_hours(
         preference.quiet_hours_timezone,preference.quiet_hours_start,
         preference.quiet_hours_end,statement_timestamp()
       )
     order by delivery.next_attempt_at,delivery.created_at,delivery.id
     for update of delivery skip locked
     limit v_limit
  ), leased as (
    update public.customer_push_deliveries_v95 delivery
       set status='leased',attempt_count=attempt_count+1,
           lease_token=gen_random_uuid(),leased_by=p_worker_id,
           lease_until=now()+v_lease,updated_at=now()
      from candidates
     where delivery.id=candidates.id
    returning delivery.*
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'delivery_id',leased.id,'lease_token',leased.lease_token,
    'attempt',leased.attempt_count,'event_id',event.id,
    'business_id',event.business_id,'business_slug',business.slug,
    'source_kind',event.source_kind,'topic',event.topic,
    'title',event.title,'body',event.body,'route_key',event.route_key,
    'deadline_at',event.deadline_at,
    'endpoint',subscription.endpoint,'p256dh',subscription.p256dh,
    'auth',subscription.auth_secret
  ) order by leased.created_at,leased.id),'[]'::jsonb)
  into v_result
  from leased
  join public.customer_in_app_inbox_events event on event.id=leased.event_id
  join public.businesses business on business.id=event.business_id
  join public.customer_push_subscriptions_v95 subscription
    on subscription.id=leased.subscription_id;
  return v_result;
end
$$;

-- A create-from-scratch replay would otherwise inherit PostgreSQL's default
-- EXECUTE-to-PUBLIC on every function above.
revoke all on function public.customer_get_communication_preferences_v263()
  from public, anon, authenticated;
revoke all on function public.customer_set_communication_preference_v263(text, text, boolean)
  from public, anon, authenticated;
revoke all on function public.customer_set_all_communications_v263(boolean)
  from public, anon, authenticated;
revoke all on function public.internal_customer_push_claim_v95(uuid, integer, integer)
  from public, anon, authenticated;

grant execute on function public.customer_get_communication_preferences_v263()
  to authenticated;
grant execute on function public.customer_set_communication_preference_v263(text, text, boolean)
  to authenticated;
grant execute on function public.customer_set_all_communications_v263(boolean)
  to authenticated;
grant execute on function public.internal_customer_push_claim_v95(uuid, integer, integer)
  to service_role;

commit;
