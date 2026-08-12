-- NESTLY v282 - COMMUNICATIONS FOUNDATION
--
-- Owner ruling 2026-08-12: "deferred by design - proceed to build all". Four
-- things that were designed, half-built, and then left unfed. Each one is a
-- promise the product already makes to a customer and cannot currently keep.
--
-- 1. WEB PUSH HAS NO TICK. v95 built the subscription store, the lease/claim
--    protocol and the report path; v263 added the consent gate; the dispatcher
--    edge function exists. Nothing ever calls it. A delivery row is created by
--    internal_customer_push_claim_v95 itself, so the entire pipeline is one
--    HTTP POST away from working - and that POST had no scheduler. This adds
--    it, on the v156/v176 pg_net + Vault pattern already reviewed twice.
--
--    Note on shape: this dispatcher is deliberately UNCONDITIONAL. The claim
--    RPC both enqueues new deliveries and leases them, so "is anything
--    pending?" cannot be answered from the deliveries table alone - a fresh
--    inbox event has no delivery row yet. A pending-check that reads only
--    deliveries would silently never fire for the first event of a quiet
--    period, which is precisely the failure mode this migration exists to end.
--    288 no-op POSTs a day is the cheaper mistake.
--
-- 2. A PARKED BOTTLE EXPIRES IN SILENCE. v275/v278/v279 model the keep window
--    and even carry an 'expire' event kind and an 'expired' status - but only a
--    human pressing Notify ever writes anything, and nothing at all flips a
--    bottle when its window closes. So the shelf slowly fills with rows that
--    claim to be in storage, the capacity number lies, and a customer's
--    property quietly lapses with no warning and no record. This adds the daily
--    SGT sweep: expire what has lapsed, and warn N days before (default 7, per
--    business) on the same inbox rails v278's manual Notify uses.
--
--    One deliberate deviation from v278. Manual Notify requires an EXPLICIT v33
--    opt-in row (coalesce(opted_in,false)); the v263 owner ruling is that
--    absence is consent and a customer with no row is reachable. The automated
--    reminder follows v263/v122 (coalesce(opted_in,true) plus the v263
--    category gate), because a scheduled sweep gated on a row nothing writes is
--    a sweep that never sends. An explicit withdrawal still wins, in both
--    stores. v278's manual path is left exactly as it is.
--
-- 3. CONSENT EVIDENCE IS WRITE-ONLY. v92 and v263 both record append-only
--    evidence of every grant and withdrawal, and neither is readable by the
--    person the evidence is about. customer_get_consent_history_v282 returns
--    the caller's own rows and nobody else's.
--
-- 4. PARTNER OBLIGATIONS HAVE NO LEDGER. The consent wording pinned by v265
--    ('2026-08-10-partner-sharing-v3') tells a customer that selected partners
--    may receive their contact details. Nothing records which partner, which
--    customer, or when - so a withdrawal cannot be honoured downstream and no
--    obligation can be evidenced. This adds the registry, the append-only
--    disclosure log and the suppression-instruction record. It deliberately
--    performs NO data distribution: this is the evidence layer the consent
--    already promises, not a new sharing capability.
--
-- PDPA note for counsel, not a compliance claim (same standing caveat as v92,
-- v263 and v265): this migration makes expiry, reminders, consent history and
-- partner suppression recordable and readable. It does not assert that any
-- particular wording, retention period or downstream partner contract is
-- sufficient.

begin;

-- ===========================================================================
-- 1. WEB PUSH - the missing tick
-- ===========================================================================

-- The bottle expiry reminder is a new (source_kind, topic) pair and must be
-- named here or the claim RPC will enqueue nothing for it. Restated in full
-- rather than patched, because this allowlist is the single place the two
-- sides of the pipeline agree; the eight existing pairs are byte-identical to
-- the v263 definition.
create or replace function app.customer_push_event_eligible_v95(
  p_source_kind text, p_topic text
)
returns boolean language sql immutable
set search_path to 'pg_catalog', 'pg_temp'
as $$
  select (p_source_kind, p_topic) in (
    ('c44_actionable_wallet', 'value_expiry'),
    ('c44_actionable_wallet', 'reward_ready'),
    ('c44_actionable_wallet', 'visit_progress'),
    ('c45_birthday_benefit', 'birthday_benefit'),
    ('v33_booking_action', 'booking_updates'),
    ('v48_appointment_reschedule', 'booking_updates'),
    ('v122_promotion_new', 'promotion_alerts'),
    ('v122_promotion_expiry', 'promotion_alerts'),
    ('v282_bottle_expiry', 'value_expiry')
  )
$$;
revoke all on function app.customer_push_event_eligible_v95(text, text)
  from public, anon, authenticated;

-- pg_net + Vault, exactly as app.v156_run_subscription_automation and
-- app.v176_run_scheduled_ai_firm_reports do it. Every absent precondition
-- returns a NAMED reason rather than raising, so a scheduled run that cannot
-- reach the edge function is diagnosable from cron.job_run_details instead of
-- appearing as a bare failure.
create or replace function app.v282_run_customer_push_dispatch()
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_url text;
  v_secret text;
  v_request bigint;
  v_pending integer;
begin
  select count(*)::integer into v_pending
    from public.customer_push_deliveries_v95 delivery
   where delivery.status in ('queued', 'retry')
     and delivery.attempt_count < 5;

  if to_regnamespace('vault') is null or to_regnamespace('net') is null then
    return jsonb_build_object('pending', v_pending, 'dispatch', 'extensions_unavailable');
  end if;
  begin
    execute 'select decrypted_secret from vault.decrypted_secrets where name=$1 order by created_at desc limit 1'
      into v_url using 'v282_supabase_url';
    if coalesce(v_url, '') = '' then
      execute 'select decrypted_secret from vault.decrypted_secrets where name=$1 order by created_at desc limit 1'
        into v_url using 'v156_supabase_url';
    end if;
    execute 'select decrypted_secret from vault.decrypted_secrets where name=$1 order by created_at desc limit 1'
      into v_secret using 'v282_push_dispatch_secret';
  exception when others then
    return jsonb_build_object('pending', v_pending, 'dispatch', 'vault_unavailable');
  end;
  if coalesce(v_url, '') = '' or coalesce(v_secret, '') = '' then
    return jsonb_build_object('pending', v_pending, 'dispatch', 'secret_unconfigured');
  end if;

  -- The header name is the one supabase/functions/_shared/customer-push.ts
  -- compares in constant time; changing either side alone locks the dispatcher
  -- out with a 401 that looks like a healthy deployment.
  execute 'select net.http_post(url := $1, body := ''{}''::jsonb, headers := jsonb_build_object(''content-type'',''application/json'',''x-nestly-push-dispatch-secret'',$2), timeout_milliseconds := 20000)'
    into v_request
    using rtrim(v_url, '/') || '/functions/v1/customer-push-dispatch', v_secret;

  return jsonb_build_object('pending', v_pending, 'dispatch_request_id', v_request);
end
$$;
revoke all privileges on function app.v282_run_customer_push_dispatch()
  from public, anon, authenticated, service_role;
grant execute on function app.v282_run_customer_push_dispatch() to service_role;

-- ===========================================================================
-- 2. BOTTLE EXPIRY SWEEP AND REMINDERS
-- ===========================================================================

-- One number per business, beside the keep window it modifies. Absent column
-- value is the 7-day standard the owner named.
alter table public.bar_bottle_settings
  add column if not exists expiry_reminder_days integer not null default 7;
alter table public.bar_bottle_settings
  drop constraint if exists bar_bottle_settings_expiry_reminder_days_check;
alter table public.bar_bottle_settings
  add constraint bar_bottle_settings_expiry_reminder_days_check
  check (expiry_reminder_days between 1 and 90);
comment on column public.bar_bottle_settings.expiry_reminder_days is
  'How many days before a bottle lapses the automated reminder fires. Absent settings row = 7.';

create or replace function app.bar_expiry_reminder_days_v282(p_business uuid)
returns integer
language sql
stable
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
  select coalesce(
    (select setting.expiry_reminder_days
       from public.bar_bottle_settings setting
      where setting.business_id = p_business),
    7)
$$;
revoke all on function app.bar_expiry_reminder_days_v282(uuid)
  from public, anon, authenticated;

-- The inbox vocabulary is closed on purpose (see v278 section 9). One new
-- source kind, one new title, one new body - restated in full so a
-- create-from-scratch replay lands on the same constraint text.
alter table public.customer_in_app_inbox_events
  drop constraint customer_in_app_inbox_events_source_kind_check,
  add constraint customer_in_app_inbox_events_source_kind_check check (source_kind in (
    'c44_actionable_wallet', 'c45_birthday_benefit', 'v33_booking_action',
    'v48_appointment_reschedule', 'v122_promotion_new', 'v122_promotion_expiry',
    'v278_bottle_reminder', 'v282_bottle_expiry'
  )),
  drop constraint customer_in_app_inbox_events_title_check,
  add constraint customer_in_app_inbox_events_title_check check (title in (
    'Points expire soon', 'Stamps expire soon', 'A reward is ready', 'One visit to go',
    'Birthday benefit ready', 'Appointment request received', 'Appointment time changed',
    'Points expire tomorrow', 'Stamps expire tomorrow', 'Points expire within 3 days',
    'Stamps expire within 3 days', 'Reward unlocked!', 'Quest almost complete',
    'Birthday surprise unlocked', 'New promotion available', 'Promotion ending soon',
    'Your bottle is waiting', 'Your bottle expires soon'
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
    'Open this business wallet to see the bottle being kept for you.',
    'Open this business wallet before the bottle kept for you is collected.'
  ));

-- The inbox reader filters on this; a row written without it here is written
-- and then never shown.
create or replace function app.c46_inbox_source_available(
  p_source_kind text, p_actionable_wallet_enabled boolean
)
returns boolean language sql immutable
set search_path to 'pg_catalog', 'pg_temp'
as $$
  select $1 in (
    'v33_booking_action','v48_appointment_reschedule',
    'v122_promotion_new','v122_promotion_expiry','v278_bottle_reminder',
    'v282_bottle_expiry'
  ) or (
    coalesce($2,false)
    and $1 in ('c44_actionable_wallet','c45_birthday_benefit')
  )
$$;

-- The sweep. Two independent, individually idempotent halves.
--
-- Expiry is idempotent because the UPDATE's own predicate is the thing it
-- destroys: a second run finds no 'stored' row past its window. The event
-- carries an idem_key anyway, so a manual re-run against a hand-edited status
-- still cannot write a second 'expire'.
--
-- Reminders are idempotent because the dedupe_key includes expires_at and the
-- inbox has a unique (identity_id, dedupe_key). Extending a bottle's window is
-- therefore a NEW reminder rather than a suppressed one, which is the correct
-- reading: the customer was told about a deadline that has since moved.
--
-- Only 'stored' bottles are touched. A bottle that is 'called' or 'at_table'
-- is physically in service; expiring it mid-pour would be a data claim about
-- the room that this function is in no position to make.
create or replace function app.v282_sweep_bottle_expiry(p_now timestamptz default now())
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_now timestamptz := coalesce(p_now, now());
  v_expired integer := 0;
  v_reminded integer := 0;
begin
  with lapsed as (
    update public.bar_bottles bottle
       set status = 'expired', updated_at = v_now
     where bottle.status = 'stored'
       and bottle.expires_at <= v_now
    returning bottle.id, bottle.business_id, bottle.expires_at
  ), evidenced as (
    insert into public.bar_bottle_events (
      business_id, bottle_id, kind, actor, idem_key, detail
    )
    select
      lapsed.business_id, lapsed.id, 'expire', null::uuid,
      'v282-expire:' || lapsed.id::text,
      jsonb_build_object('swept_at', v_now, 'expires_at', lapsed.expires_at)
    from lapsed
    on conflict do nothing
    returning 1
  )
  select count(*)::integer into v_expired from lapsed;

  with due as (
    select
      bottle.id as bottle_id,
      bottle.business_id,
      bottle.expires_at,
      link.id as link_id,
      link.identity_id,
      link.auth_user_id,
      link.client_id
    from public.bar_bottles bottle
    join public.customer_links link
      on link.business_id = bottle.business_id
     and link.client_id = bottle.client_id
     and link.state = 'verified'
     and link.unlinked_at is null
    left join public.customer_notification_preferences preference
      on preference.business_id = link.business_id
     and preference.identity_id = link.identity_id
     and preference.auth_user_id = link.auth_user_id
     and preference.link_id = link.id
     and preference.channel = 'in_app'
     and preference.topic = 'value_expiry'
    where bottle.status = 'stored'
      and bottle.expires_at > v_now
      and bottle.expires_at <= v_now
        + make_interval(days => app.bar_expiry_reminder_days_v282(bottle.business_id))
      and coalesce(preference.opted_in, true)
      and app.customer_communication_allows_v263(
        link.identity_id, 'rewards_and_points', 'in_app'
      )
  ), enqueued as (
    insert into public.customer_in_app_inbox_events (
      business_id, identity_id, auth_user_id, link_id, client_id,
      source_kind, topic, route_key, source_fingerprint, dedupe_key,
      title, body, deadline_at
    )
    select
      due.business_id, due.identity_id, due.auth_user_id, due.link_id, due.client_id,
      'v282_bottle_expiry', 'value_expiry', 'wallet_business',
      app.c46_sha256_hex(jsonb_build_object(
        'bottle_id', due.bottle_id, 'expires_at', due.expires_at)::text),
      app.c46_sha256_hex(jsonb_build_object(
        'identity_id', due.identity_id, 'bottle_id', due.bottle_id,
        'expires_at', due.expires_at)::text),
      'Your bottle expires soon',
      'Open this business wallet before the bottle kept for you is collected.',
      due.expires_at
    from due
    on conflict (identity_id, dedupe_key) do nothing
    returning id, business_id
  ), noted as (
    insert into public.bar_bottle_events (
      business_id, bottle_id, kind, actor, idem_key, detail
    )
    select
      due.business_id, due.bottle_id, 'reminder', null::uuid,
      'v282-remind:' || due.bottle_id::text || ':' || due.expires_at::text,
      jsonb_build_object('delivery', 'in_app', 'automated', true,
        'expires_at', due.expires_at)
    from due
    on conflict do nothing
    returning 1
  )
  select count(*)::integer into v_reminded from enqueued;

  return jsonb_build_object(
    'swept_at', v_now, 'expired', v_expired, 'reminded', v_reminded);
end
$$;
revoke all privileges on function app.v282_sweep_bottle_expiry(timestamptz)
  from public, anon, authenticated, service_role;
grant execute on function app.v282_sweep_bottle_expiry(timestamptz) to service_role;

-- The setup screen has to be able to see and set the number, or "per business"
-- is a column nobody can reach.
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
    'reminder_days', app.bar_expiry_reminder_days_v282(p_business),
    'can_edit', app.is_salon_owner(p_business),
    'tiers', v_tiers,
    'products', v_products);
end;
$$;

create or replace function public.bar_save_expiry_reminder_days_v282(
  p_business uuid,
  p_days integer
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_actor uuid := auth.uid();
begin
  perform app.require_bar_business_v275(p_business);
  perform app.require_bar_staff_v275(p_business, true);
  if not app.is_salon_owner(p_business) then
    raise exception 'only an owner may change the reminder window' using errcode = '42501';
  end if;
  if p_days is null or p_days not between 1 and 90 then
    raise exception 'the reminder window must be 1 to 90 days' using errcode = '22023';
  end if;

  insert into public.bar_bottle_settings (business_id, expiry_reminder_days, updated_at, updated_by)
  values (p_business, p_days, now(), v_actor)
  on conflict (business_id) do update
    set expiry_reminder_days = excluded.expiry_reminder_days,
        updated_at = now(),
        updated_by = excluded.updated_by;

  return jsonb_build_object('status', 'ok', 'reminder_days', p_days);
end;
$$;

-- ===========================================================================
-- 3. CONSENT HISTORY - the customer reads their own evidence
-- ===========================================================================

-- Own rows only, and provably so: the identity comes from
-- app.customer_communication_identity_v263() (auth.uid() -> active identity),
-- never from a parameter, so there is no argument a caller can supply to widen
-- the result. Both stores are already append-only, so this is a pure read.
create or replace function public.customer_get_consent_history_v282(
  p_limit integer default 100
)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_actor uuid := auth.uid();
  v_identity uuid := app.customer_communication_identity_v263();
  v_limit integer := least(greatest(coalesce(p_limit, 100), 1), 200);
  v_entries jsonb;
begin
  select coalesce(jsonb_agg(entry order by occurred_at desc, ordering, entry_id), '[]'::jsonb)
    into v_entries
  from (
    select
      audit.occurred_at,
      1 as ordering,
      audit.id as entry_id,
      jsonb_build_object(
        'entry_kind', case when audit.scope = 'all'
          then 'marketing_all_channels' else 'marketing_channel' end,
        'occurred_at', audit.occurred_at,
        'enabled', audit.enabled,
        'category', audit.category,
        'channel', audit.channel,
        'source', audit.source,
        'scope_version', null
      ) as entry
      from public.customer_communication_preference_audit_v263 audit
     where audit.identity_id = v_identity
       and audit.auth_user_id = v_actor

    union all

    select
      consent.occurred_at,
      2 as ordering,
      consent.id as entry_id,
      jsonb_build_object(
        'entry_kind', 'platform_partner_marketing',
        'occurred_at', consent.occurred_at,
        'enabled', consent.opted_in,
        'category', null,
        'channel', null,
        'source', consent.source,
        'scope_version', consent.scope_version
      ) as entry
      from public.customer_platform_marketing_consent_events consent
     where consent.identity_id = v_identity
       and consent.auth_user_id = v_actor

    order by occurred_at desc, ordering, entry_id
    limit v_limit
  ) as history;

  return jsonb_build_object('entries', v_entries, 'limit', v_limit);
end;
$$;

-- ===========================================================================
-- 4. PARTNER OBLIGATIONS
-- ===========================================================================

-- Platform-managed in the house style: RLS on, ZERO policies, ACL revoked from
-- every browser role. The SECURITY DEFINER RPCs below are the only door, and
-- each one holds app.is_super_admin(). No tenant role can read or write any of
-- these three tables, because a partner list is cross-tenant by construction.

create table public.partner_registry_v282 (
  id uuid primary key default gen_random_uuid(),
  name text not null check (length(btrim(name)) between 2 and 120),
  purpose text not null check (length(btrim(purpose)) between 2 and 400),
  status text not null default 'prospective'
    check (status in ('prospective', 'active', 'suspended', 'ended')),
  created_at timestamptz not null default now(),
  created_by uuid,
  updated_at timestamptz not null default now(),
  updated_by uuid,
  constraint partner_registry_v282_name_uk unique (name)
);
comment on table public.partner_registry_v282 is
  'Every selected partner the v265 consent wording can refer to. Platform-managed; no tenant may read or write it.';

alter table public.partner_registry_v282 enable row level security;
revoke all privileges on table public.partner_registry_v282
  from public, anon, authenticated;

create table public.partner_disclosures_v282 (
  id uuid primary key default gen_random_uuid(),
  partner_id uuid not null references public.partner_registry_v282(id) on delete restrict,
  identity_id uuid not null references public.customer_identities(id) on delete restrict,
  auth_user_id uuid not null references auth.users(id) on delete restrict,
  consent_event_id uuid
    references public.customer_platform_marketing_consent_events(id) on delete restrict,
  scope_version text not null check (length(btrim(scope_version)) between 2 and 80),
  dataset text not null check (dataset in ('contact_details', 'marketing_audience')),
  disclosed_at timestamptz not null default now(),
  recorded_at timestamptz not null default now(),
  recorded_by uuid,
  constraint partner_disclosures_v282_identity_auth_fk
    foreign key (identity_id, auth_user_id)
    references public.customer_identities(id, auth_user_id) on delete restrict
);
comment on table public.partner_disclosures_v282 is
  'Append-only record of which partner received which customer, and when. Nothing in this migration writes it automatically: no data distribution exists yet, and this is the evidence the consent already promises.';

alter table public.partner_disclosures_v282 enable row level security;
revoke all privileges on table public.partner_disclosures_v282
  from public, anon, authenticated;

create index partner_disclosures_v282_partner_idx
  on public.partner_disclosures_v282 (partner_id, disclosed_at desc);
create index partner_disclosures_v282_identity_idx
  on public.partner_disclosures_v282 (identity_id, disclosed_at desc);

create trigger partner_disclosures_v282_immutable
before update or delete on public.partner_disclosures_v282
for each row execute function app.v33_append_only_guard();

create table public.partner_suppressions_v282 (
  id uuid primary key default gen_random_uuid(),
  partner_id uuid not null references public.partner_registry_v282(id) on delete restrict,
  identity_id uuid references public.customer_identities(id) on delete restrict,
  auth_user_id uuid references auth.users(id) on delete restrict,
  reason text not null check (reason in (
    'consent_withdrawn', 'account_closed', 'customer_request', 'platform_decision'
  )),
  issued_at timestamptz not null default now(),
  issued_by uuid not null,
  acknowledged_at timestamptz,
  acknowledgement_reference text
    check (acknowledgement_reference is null
      or length(btrim(acknowledgement_reference)) between 1 and 200),
  idempotency_key text
    check (idempotency_key is null or length(btrim(idempotency_key)) between 1 and 120),
  constraint partner_suppressions_v282_identity_auth_ck check (
    (identity_id is null and auth_user_id is null)
    or (identity_id is not null and auth_user_id is not null)
  ),
  constraint partner_suppressions_v282_identity_auth_fk
    foreign key (identity_id, auth_user_id)
    references public.customer_identities(id, auth_user_id) on delete restrict,
  constraint partner_suppressions_v282_acknowledgement_ck check (
    acknowledged_at is not null or acknowledgement_reference is null
  )
);
comment on table public.partner_suppressions_v282 is
  'A suppression INSTRUCTION issued to a partner, and the acknowledgement if one came back. issued_at is evidence that the instruction went out; a null acknowledged_at is evidence that it has not been confirmed - which is a fact worth being able to see, not a gap to hide.';

alter table public.partner_suppressions_v282 enable row level security;
revoke all privileges on table public.partner_suppressions_v282
  from public, anon, authenticated;

create index partner_suppressions_v282_partner_idx
  on public.partner_suppressions_v282 (partner_id, issued_at desc);
create unique index partner_suppressions_v282_idempotency_uk
  on public.partner_suppressions_v282 (partner_id, idempotency_key)
  where idempotency_key is not null;

-- Not the plain append-only guard: an acknowledgement legitimately arrives
-- later. Exactly one transition is permitted - a null acknowledged_at becoming
-- non-null, once - and nothing else about the row may move. Deletes are
-- refused outright.
create or replace function app.v282_partner_suppression_guard()
returns trigger
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
begin
  if tg_op = 'DELETE' then
    raise exception 'a suppression instruction is append-only' using errcode = '23000';
  end if;
  if old.acknowledged_at is not null then
    raise exception 'this suppression instruction is already acknowledged' using errcode = '23000';
  end if;
  if new.acknowledged_at is null then
    raise exception 'only an acknowledgement may amend a suppression instruction'
      using errcode = '23000';
  end if;
  if new.id is distinct from old.id
     or new.partner_id is distinct from old.partner_id
     or new.identity_id is distinct from old.identity_id
     or new.auth_user_id is distinct from old.auth_user_id
     or new.reason is distinct from old.reason
     or new.issued_at is distinct from old.issued_at
     or new.issued_by is distinct from old.issued_by
     or new.idempotency_key is distinct from old.idempotency_key then
    raise exception 'a suppression instruction is append-only' using errcode = '23000';
  end if;
  return new;
end;
$$;

create trigger partner_suppressions_v282_guard
before update or delete on public.partner_suppressions_v282
for each row execute function app.v282_partner_suppression_guard();

-- --- Super-admin RPCs -------------------------------------------------------

create or replace function public.platform_list_partner_obligations_v282(
  p_limit integer default 100
)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_actor uuid := auth.uid();
  v_limit integer;
  v_partners jsonb;
  v_disclosures jsonb;
  v_suppressions jsonb;
begin
  if v_actor is null then
    raise exception 'authenticated platform session is required' using errcode = '28000';
  end if;
  if not app.is_super_admin() then
    raise exception 'partner obligations are super admin only' using errcode = '42501';
  end if;
  if p_limit is null or p_limit not between 1 and 500 then
    raise exception 'row limit must be 1..500' using errcode = '22023';
  end if;
  v_limit := p_limit;

  select coalesce(jsonb_agg(entry order by entry->>'name'), '[]'::jsonb)
    into v_partners
  from (
    select jsonb_build_object(
      'id', partner.id,
      'name', partner.name,
      'purpose', partner.purpose,
      'status', partner.status,
      'created_at', partner.created_at,
      'updated_at', partner.updated_at,
      'disclosure_count', (
        select count(*) from public.partner_disclosures_v282 disclosure
         where disclosure.partner_id = partner.id
      ),
      'open_suppressions', (
        select count(*) from public.partner_suppressions_v282 suppression
         where suppression.partner_id = partner.id
           and suppression.acknowledged_at is null
      )
    ) as entry
    from public.partner_registry_v282 partner
    order by partner.name
    limit v_limit
  ) as partners;

  -- Customers are counted, never listed: a cross-tenant console has no reason
  -- to render a person's identity, and a partner ledger that leaks the roster
  -- it exists to protect would be self-defeating.
  select coalesce(jsonb_agg(entry order by entry->>'disclosed_on' desc), '[]'::jsonb)
    into v_disclosures
  from (
    select jsonb_build_object(
      'partner_id', disclosure.partner_id,
      'partner_name', partner.name,
      'dataset', disclosure.dataset,
      'scope_version', disclosure.scope_version,
      'disclosed_on', to_char(
        date_trunc('day', disclosure.disclosed_at at time zone 'Asia/Singapore'),
        'YYYY-MM-DD'),
      'customers', count(*)
    ) as entry
    from public.partner_disclosures_v282 disclosure
    join public.partner_registry_v282 partner on partner.id = disclosure.partner_id
    group by disclosure.partner_id, partner.name, disclosure.dataset,
             disclosure.scope_version,
             date_trunc('day', disclosure.disclosed_at at time zone 'Asia/Singapore')
    order by date_trunc('day', disclosure.disclosed_at at time zone 'Asia/Singapore') desc
    limit v_limit
  ) as disclosures;

  select coalesce(jsonb_agg(entry order by entry->>'issued_at' desc), '[]'::jsonb)
    into v_suppressions
  from (
    select jsonb_build_object(
      'id', suppression.id,
      'partner_id', suppression.partner_id,
      'partner_name', partner.name,
      'reason', suppression.reason,
      'issued_at', suppression.issued_at,
      'acknowledged_at', suppression.acknowledged_at,
      'acknowledgement_reference', suppression.acknowledgement_reference,
      'scope', case when suppression.identity_id is null
        then 'all_customers' else 'one_customer' end
    ) as entry
    from public.partner_suppressions_v282 suppression
    join public.partner_registry_v282 partner on partner.id = suppression.partner_id
    order by suppression.issued_at desc
    limit v_limit
  ) as suppressions;

  return jsonb_build_object(
    'status', 'ok',
    'partners', v_partners,
    'disclosures', v_disclosures,
    'suppressions', v_suppressions);
end;
$$;

create or replace function public.platform_save_partner_v282(
  p_partner uuid,
  p_name text,
  p_purpose text,
  p_status text
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_actor uuid := auth.uid();
  v_name text := nullif(btrim(coalesce(p_name, '')), '');
  v_purpose text := nullif(btrim(coalesce(p_purpose, '')), '');
  v_status text := lower(btrim(coalesce(p_status, 'prospective')));
  v_id uuid;
begin
  if v_actor is null then
    raise exception 'authenticated platform session is required' using errcode = '28000';
  end if;
  if not app.is_super_admin() then
    raise exception 'the partner registry is super admin only' using errcode = '42501';
  end if;
  if v_name is null or length(v_name) not between 2 and 120 then
    raise exception 'a partner name of 2 to 120 characters is required' using errcode = '22023';
  end if;
  if v_purpose is null or length(v_purpose) not between 2 and 400 then
    raise exception 'a stated purpose of 2 to 400 characters is required' using errcode = '22023';
  end if;
  if v_status not in ('prospective', 'active', 'suspended', 'ended') then
    raise exception 'unsupported partner status' using errcode = '22023';
  end if;

  if p_partner is null then
    insert into public.partner_registry_v282 (name, purpose, status, created_by, updated_by)
    values (v_name, v_purpose, v_status, v_actor, v_actor)
    returning id into v_id;
  else
    update public.partner_registry_v282 partner
       set name = v_name, purpose = v_purpose, status = v_status,
           updated_at = now(), updated_by = v_actor
     where partner.id = p_partner
    returning partner.id into v_id;
    if v_id is null then
      raise exception 'partner not found' using errcode = '22023';
    end if;
  end if;

  return jsonb_build_object('status', 'ok', 'partner_id', v_id);
end;
$$;

create or replace function public.platform_record_partner_suppression_v282(
  p_partner uuid,
  p_reason text,
  p_idempotency_key text,
  p_identity uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_actor uuid := auth.uid();
  v_reason text := lower(btrim(coalesce(p_reason, '')));
  v_key text := nullif(btrim(coalesce(p_idempotency_key, '')), '');
  v_auth uuid;
  v_id uuid;
begin
  if v_actor is null then
    raise exception 'authenticated platform session is required' using errcode = '28000';
  end if;
  if not app.is_super_admin() then
    raise exception 'suppression instructions are super admin only' using errcode = '42501';
  end if;
  if v_key is null then
    raise exception 'idempotency key required' using errcode = '22023';
  end if;
  if v_reason not in ('consent_withdrawn', 'account_closed', 'customer_request', 'platform_decision') then
    raise exception 'unsupported suppression reason' using errcode = '22023';
  end if;
  if not exists (select 1 from public.partner_registry_v282 partner where partner.id = p_partner) then
    raise exception 'partner not found' using errcode = '22023';
  end if;

  select id into v_id from public.partner_suppressions_v282 suppression
   where suppression.partner_id = p_partner and suppression.idempotency_key = v_key;
  if v_id is not null then
    return jsonb_build_object('status', 'duplicate_ignored', 'suppression_id', v_id);
  end if;

  if p_identity is not null then
    select identity.auth_user_id into v_auth
      from public.customer_identities identity
     where identity.id = p_identity;
    if v_auth is null then
      raise exception 'customer not found' using errcode = '22023';
    end if;
  end if;

  insert into public.partner_suppressions_v282 (
    partner_id, identity_id, auth_user_id, reason, issued_by, idempotency_key
  ) values (
    p_partner, p_identity, v_auth, v_reason, v_actor, v_key
  )
  returning id into v_id;

  return jsonb_build_object('status', 'ok', 'suppression_id', v_id);
end;
$$;

create or replace function public.platform_acknowledge_partner_suppression_v282(
  p_suppression uuid,
  p_reference text
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_actor uuid := auth.uid();
  v_reference text := nullif(btrim(coalesce(p_reference, '')), '');
  v_id uuid;
begin
  if v_actor is null then
    raise exception 'authenticated platform session is required' using errcode = '28000';
  end if;
  if not app.is_super_admin() then
    raise exception 'suppression instructions are super admin only' using errcode = '42501';
  end if;
  if v_reference is null or length(v_reference) not between 1 and 200 then
    raise exception 'an acknowledgement reference is required' using errcode = '22023';
  end if;

  update public.partner_suppressions_v282 suppression
     set acknowledged_at = now(), acknowledgement_reference = v_reference
   where suppression.id = p_suppression
     and suppression.acknowledged_at is null
  returning suppression.id into v_id;
  if v_id is null then
    raise exception 'no unacknowledged suppression instruction with that id' using errcode = '22023';
  end if;

  return jsonb_build_object('status', 'ok', 'suppression_id', v_id);
end;
$$;

-- ===========================================================================
-- 5. GRANTS
-- ===========================================================================
-- A create-from-scratch replay would otherwise inherit PostgreSQL's default
-- EXECUTE-to-PUBLIC on every function above. One explicit pair each.

revoke all on function app.bar_expiry_reminder_days_v282(uuid)
  from public, anon, authenticated;
revoke all on function app.v282_partner_suppression_guard()
  from public, anon, authenticated;
revoke all on function public.bar_get_bottle_setup_v278(uuid)
  from public, anon, authenticated;
revoke all on function public.bar_save_expiry_reminder_days_v282(uuid, integer)
  from public, anon, authenticated;
revoke all on function public.customer_get_consent_history_v282(integer)
  from public, anon, authenticated;
revoke all on function public.platform_list_partner_obligations_v282(integer)
  from public, anon, authenticated;
revoke all on function public.platform_save_partner_v282(uuid, text, text, text)
  from public, anon, authenticated;
revoke all on function public.platform_record_partner_suppression_v282(uuid, text, text, uuid)
  from public, anon, authenticated;
revoke all on function public.platform_acknowledge_partner_suppression_v282(uuid, text)
  from public, anon, authenticated;

grant execute on function public.bar_get_bottle_setup_v278(uuid) to authenticated;
grant execute on function public.bar_save_expiry_reminder_days_v282(uuid, integer) to authenticated;
grant execute on function public.customer_get_consent_history_v282(integer) to authenticated;
grant execute on function public.platform_list_partner_obligations_v282(integer) to authenticated;
grant execute on function public.platform_save_partner_v282(uuid, text, text, text) to authenticated;
grant execute on function public.platform_record_partner_suppression_v282(uuid, text, text, uuid) to authenticated;
grant execute on function public.platform_acknowledge_partner_suppression_v282(uuid, text) to authenticated;

comment on function public.customer_get_consent_history_v282(integer) is
  'The caller''s own marketing consent evidence, newest first, from the v263 per-channel audit and the v92 platform/partner consent events. Own rows only; the identity is resolved from the session, never from an argument.';
comment on function app.v282_sweep_bottle_expiry(timestamptz) is
  'Daily SGT sweep: expires lapsed in-storage bottles (one ''expire'' event each) and enqueues expiry reminders N days ahead. Both halves are idempotent - running twice writes nothing the second time.';
comment on function app.v282_run_customer_push_dispatch() is
  'Ticks the customer-push-dispatch edge function. Returns a named reason instead of raising when pg_net, Vault or the secret is absent.';

-- ===========================================================================
-- 6. SCHEDULES
-- ===========================================================================

do $cron$
begin
  if to_regnamespace('cron') is not null
     and to_regprocedure('cron.schedule(text,text,text)') is not null then
    if exists(select 1 from cron.job where jobname = 'nestly-v282-customer-push-dispatch') then
      perform cron.unschedule('nestly-v282-customer-push-dispatch');
    end if;
    perform cron.schedule(
      'nestly-v282-customer-push-dispatch',
      '*/5 * * * *',
      $command$select app.v282_run_customer_push_dispatch()$command$
    );

    if exists(select 1 from cron.job where jobname = 'nestly-v282-bottle-expiry-daily') then
      perform cron.unschedule('nestly-v282-bottle-expiry-daily');
    end if;
    -- 16:10 UTC == 00:10 SGT on the following Singapore calendar day, so a
    -- bottle whose window closes on the 12th is swept early on the 13th.
    perform cron.schedule(
      'nestly-v282-bottle-expiry-daily',
      '10 16 * * *',
      $command$select app.v282_sweep_bottle_expiry()$command$
    );
  else
    raise notice
      'v282: pg_cron is absent; push dispatch and the bottle expiry sweep are not scheduled';
  end if;
end
$cron$;

commit;
