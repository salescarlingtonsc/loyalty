-- NESTLY v95 — BASIC CUSTOMER WEB PUSH
--
-- Provider-neutral Web Push delivery for the six reviewed transactional/game
-- inbox facts. Browser principals may manage only their own endpoint through
-- self-scoped RPCs. Raw endpoint/key material and delivery machinery remain
-- private; only service_role may lease work and report provider results.

begin;

create or replace function app.customer_push_endpoint_supported_v95(p_endpoint text)
returns boolean language sql immutable
set search_path to 'pg_catalog','pg_temp'
as $$
  select coalesce($1,'') ~
    '^https://fcm\.googleapis\.com/(wp|fcm/send)/[^/?#[:space:]]+(\?[^#[:space:]]*)?$'
    or coalesce($1,'') ~
    '^https://updates\.push\.services\.mozilla\.com/(wpush/v2|push)/[^/?#[:space:]]+(\?[^#[:space:]]*)?$'
    or coalesce($1,'') ~
    '^https://([a-z0-9-]+\.)+push\.apple\.com/[^#[:space:]]+(\?[^#[:space:]]*)?$'
$$;

create table public.customer_push_subscriptions_v95 (
  id uuid primary key default gen_random_uuid(),
  identity_id uuid not null,
  auth_user_id uuid not null references auth.users(id) on delete restrict,
  endpoint text not null check (
    length(endpoint) between 20 and 2048
    and app.customer_push_endpoint_supported_v95(endpoint)
  ),
  endpoint_hash text not null unique check (endpoint_hash ~ '^[0-9a-f]{64}$'),
  -- PushSubscription.getKey('p256dh') is an uncompressed P-256 public key:
  -- 65 bytes => 87 unpadded base64url characters. auth is 16 bytes => 22.
  p256dh text not null check (length(p256dh)=87 and p256dh ~ '^[A-Za-z0-9_-]{87}$'),
  auth_secret text not null check (length(auth_secret)=22 and auth_secret ~ '^[A-Za-z0-9_-]{22}$'),
  status text not null default 'active' check (status in ('active','revoked')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  revoked_at timestamptz,
  constraint customer_push_subscriptions_v95_identity_auth_fk
    foreign key (identity_id,auth_user_id)
    references public.customer_identities(id,auth_user_id) on delete restrict,
  constraint customer_push_subscriptions_v95_status_time_ck check (
    (status='active' and revoked_at is null)
    or (status='revoked' and revoked_at is not null)
  ),
  constraint customer_push_subscriptions_v95_scope_uk
    unique(id,identity_id,auth_user_id)
);

create index customer_push_subscriptions_v95_active_idx
  on public.customer_push_subscriptions_v95(identity_id,id)
  where status='active';

create table public.customer_push_subscription_operations_v95 (
  id uuid primary key default gen_random_uuid(),
  identity_id uuid not null,
  auth_user_id uuid not null references auth.users(id) on delete restrict,
  operation text not null check (operation in ('register','unregister')),
  idempotency_key uuid not null,
  request_hash text not null check (request_hash ~ '^[0-9a-f]{64}$'),
  response jsonb not null check (jsonb_typeof(response)='object'),
  created_at timestamptz not null default now(),
  constraint customer_push_subscription_operations_v95_identity_auth_fk
    foreign key(identity_id,auth_user_id)
    references public.customer_identities(id,auth_user_id) on delete restrict,
  constraint customer_push_subscription_operations_v95_idempotency_uk
    unique(auth_user_id,idempotency_key)
);

alter table public.customer_in_app_inbox_events
  add constraint customer_in_app_inbox_events_v95_delivery_scope_uk
  unique(id,identity_id,auth_user_id);

create table public.customer_push_deliveries_v95 (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null,
  subscription_id uuid not null,
  identity_id uuid not null,
  auth_user_id uuid not null,
  status text not null default 'queued'
    check(status in ('queued','leased','retry','sent','failed','gone')),
  attempt_count integer not null default 0 check(attempt_count between 0 and 5),
  next_attempt_at timestamptz not null default now(),
  lease_token uuid,
  leased_by uuid,
  lease_until timestamptz,
  last_http_status integer check(last_http_status is null or last_http_status between 100 and 599),
  last_error_code text check(last_error_code is null or length(last_error_code)<=80),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  completed_at timestamptz,
  constraint customer_push_deliveries_v95_event_scope_fk
    foreign key(event_id,identity_id,auth_user_id)
    references public.customer_in_app_inbox_events(id,identity_id,auth_user_id)
    on delete restrict,
  constraint customer_push_deliveries_v95_subscription_scope_fk
    foreign key(subscription_id,identity_id,auth_user_id)
    references public.customer_push_subscriptions_v95(id,identity_id,auth_user_id)
    on delete restrict,
  constraint customer_push_deliveries_v95_dedupe_uk unique(event_id,subscription_id),
  constraint customer_push_deliveries_v95_lease_ck check (
    (status='leased' and lease_token is not null and leased_by is not null and lease_until is not null)
    or (status<>'leased' and lease_token is null and leased_by is null and lease_until is null)
  ),
  constraint customer_push_deliveries_v95_completion_ck check (
    (status in ('sent','failed','gone') and completed_at is not null)
    or (status not in ('sent','failed','gone') and completed_at is null)
  )
);

create index customer_push_deliveries_v95_ready_idx
  on public.customer_push_deliveries_v95(next_attempt_at,created_at,id)
  where status in ('queued','retry');

create table public.customer_push_delivery_results_v95 (
  id uuid primary key default gen_random_uuid(),
  delivery_id uuid not null references public.customer_push_deliveries_v95(id) on delete restrict,
  attempt_number integer not null check(attempt_number between 1 and 5),
  lease_token uuid not null,
  worker_id uuid not null,
  result text not null check(result in ('sent','retry','gone','failed')),
  http_status integer check(http_status is null or http_status between 100 and 599),
  error_code text check(error_code is null or length(error_code)<=80),
  idempotency_key uuid not null,
  request_hash text not null check(request_hash ~ '^[0-9a-f]{64}$'),
  response jsonb not null check(jsonb_typeof(response)='object'),
  created_at timestamptz not null default now(),
  constraint customer_push_delivery_results_v95_idempotency_uk
    unique(delivery_id,idempotency_key)
);

alter table public.customer_push_subscriptions_v95 enable row level security;
alter table public.customer_push_subscription_operations_v95 enable row level security;
alter table public.customer_push_deliveries_v95 enable row level security;
alter table public.customer_push_delivery_results_v95 enable row level security;

revoke all privileges on table public.customer_push_subscriptions_v95
  from public,anon,authenticated;
revoke all privileges on table public.customer_push_subscription_operations_v95
  from public,anon,authenticated;
revoke all privileges on table public.customer_push_deliveries_v95
  from public,anon,authenticated;
revoke all privileges on table public.customer_push_delivery_results_v95
  from public,anon,authenticated;

create trigger customer_push_subscription_operations_v95_immutable
  before update or delete on public.customer_push_subscription_operations_v95
  for each row execute function app.c46_append_only_guard();
create trigger customer_push_delivery_results_v95_immutable
  before update or delete on public.customer_push_delivery_results_v95
  for each row execute function app.c46_append_only_guard();

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
    ('v48_appointment_reschedule','booking_updates')
  )
$$;

create or replace function public.customer_register_push_subscription_v95(
  p_endpoint text,p_p256dh text,p_auth_secret text,p_idempotency_key uuid
)
returns jsonb language plpgsql security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare
  v_actor uuid:=auth.uid(); v_identity uuid; v_endpoint text:=btrim(coalesce(p_endpoint,''));
  v_endpoint_hash text; v_request_hash text; v_prior record;
  v_subscription uuid; v_response jsonb; v_existing record;
  v_active_count integer; v_evicted uuid;
begin
  if v_actor is null then raise exception 'authentication required' using errcode='42501'; end if;
  if p_idempotency_key is null then raise exception 'idempotency key is required' using errcode='22023'; end if;
  if length(v_endpoint) not between 20 and 2048
     or not app.customer_push_endpoint_supported_v95(v_endpoint)
     or length(coalesce(p_p256dh,''))<>87
     or p_p256dh !~ '^[A-Za-z0-9_-]{87}$'
     or length(coalesce(p_auth_secret,''))<>22
     or p_auth_secret !~ '^[A-Za-z0-9_-]{22}$' then
    raise exception 'invalid push subscription' using errcode='22023';
  end if;
  select id into v_identity from public.customer_identities
   where auth_user_id=v_actor and status='active'
   order by created_at,id limit 1;
  if v_identity is null then raise exception 'active customer identity required' using errcode='42501'; end if;
  v_endpoint_hash:=app.c46_sha256_hex(v_endpoint);
  v_request_hash:=app.c46_sha256_hex(jsonb_build_object(
    'operation','register','endpoint_hash',v_endpoint_hash,
    'p256dh_hash',app.c46_sha256_hex(p_p256dh),
    'auth_hash',app.c46_sha256_hex(p_auth_secret)
  )::text);
  perform pg_advisory_xact_lock(hashtextextended(v_actor::text||':'||p_idempotency_key::text,95));
  select request_hash,response into v_prior
    from public.customer_push_subscription_operations_v95
   where auth_user_id=v_actor and idempotency_key=p_idempotency_key;
  if found then
    if v_prior.request_hash<>v_request_hash then
      raise exception 'idempotency key conflict' using errcode='22000';
    end if;
    return v_prior.response;
  end if;
  perform pg_advisory_xact_lock(hashtextextended('v95-push-identity:'||v_identity::text,95));
  if (
    select count(*)>=20
      from public.customer_push_subscription_operations_v95
     where identity_id=v_identity and created_at>now()-interval '10 minutes'
  ) then
    raise exception 'push subscription operation rate exceeded' using errcode='54000';
  end if;
  select id,auth_user_id,status into v_existing
    from public.customer_push_subscriptions_v95
   where endpoint_hash=v_endpoint_hash for update;
  if found and v_existing.auth_user_id<>v_actor then
    raise exception 'push subscription unavailable' using errcode='23505';
  end if;
  if not found or v_existing.status<>'active' then
    select count(*)::integer into v_active_count
      from public.customer_push_subscriptions_v95
     where identity_id=v_identity and auth_user_id=v_actor and status='active';
    if v_active_count>=5 then
      select id into v_evicted
        from public.customer_push_subscriptions_v95
       where identity_id=v_identity and auth_user_id=v_actor and status='active'
       order by updated_at,created_at,id
       for update limit 1;
      update public.customer_push_subscriptions_v95
         set status='revoked',revoked_at=now(),updated_at=now()
       where id=v_evicted;
    end if;
  end if;
  insert into public.customer_push_subscriptions_v95(
    identity_id,auth_user_id,endpoint,endpoint_hash,p256dh,auth_secret,status,revoked_at
  ) values(
    v_identity,v_actor,v_endpoint,v_endpoint_hash,p_p256dh,p_auth_secret,'active',null
  )
  on conflict(endpoint_hash) do update set
    identity_id=excluded.identity_id,p256dh=excluded.p256dh,
    auth_secret=excluded.auth_secret,status='active',revoked_at=null,updated_at=now()
  where customer_push_subscriptions_v95.auth_user_id=v_actor
  returning id into v_subscription;
  if v_subscription is null then
    raise exception 'push subscription unavailable' using errcode='23505';
  end if;
  v_response:=jsonb_build_object(
    'subscription_id',v_subscription,'status','active',
    'evicted_subscription_id',v_evicted
  );
  insert into public.customer_push_subscription_operations_v95(
    identity_id,auth_user_id,operation,idempotency_key,request_hash,response
  ) values(v_identity,v_actor,'register',p_idempotency_key,v_request_hash,v_response);
  return v_response;
end
$$;

create or replace function public.customer_unregister_push_subscription_v95(
  p_subscription uuid,p_idempotency_key uuid
)
returns jsonb language plpgsql security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare
  v_actor uuid:=auth.uid(); v_identity uuid; v_request_hash text;
  v_prior record; v_response jsonb; v_changed boolean:=false;
begin
  if v_actor is null then raise exception 'authentication required' using errcode='42501'; end if;
  if p_subscription is null or p_idempotency_key is null then
    raise exception 'subscription and idempotency key are required' using errcode='22023';
  end if;
  select id into v_identity from public.customer_identities
   where auth_user_id=v_actor and status='active'
   order by created_at,id limit 1;
  if v_identity is null then raise exception 'active customer identity required' using errcode='42501'; end if;
  v_request_hash:=app.c46_sha256_hex(jsonb_build_object(
    'operation','unregister','subscription_id',p_subscription
  )::text);
  perform pg_advisory_xact_lock(hashtextextended(v_actor::text||':'||p_idempotency_key::text,95));
  select request_hash,response into v_prior
    from public.customer_push_subscription_operations_v95
   where auth_user_id=v_actor and idempotency_key=p_idempotency_key;
  if found then
    if v_prior.request_hash<>v_request_hash then
      raise exception 'idempotency key conflict' using errcode='22000';
    end if;
    return v_prior.response;
  end if;
  perform pg_advisory_xact_lock(hashtextextended('v95-push-identity:'||v_identity::text,95));
  if (
    select count(*)>=20
      from public.customer_push_subscription_operations_v95
     where identity_id=v_identity and created_at>now()-interval '10 minutes'
  ) then
    raise exception 'push subscription operation rate exceeded' using errcode='54000';
  end if;
  update public.customer_push_subscriptions_v95
     set status='revoked',revoked_at=coalesce(revoked_at,now()),updated_at=now()
   where id=p_subscription and identity_id=v_identity and auth_user_id=v_actor
  returning true into v_changed;
  v_response:=jsonb_build_object(
    'subscription_id',p_subscription,
    'status',case when coalesce(v_changed,false) then 'revoked' else 'not_found' end
  );
  insert into public.customer_push_subscription_operations_v95(
    identity_id,auth_user_id,operation,idempotency_key,request_hash,response
  ) values(v_identity,v_actor,'unregister',p_idempotency_key,v_request_hash,v_response);
  return v_response;
end
$$;

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
    join public.customer_notification_preferences preference
      on preference.business_id=event.business_id
     and preference.identity_id=event.identity_id
     and preference.auth_user_id=event.auth_user_id
     and preference.link_id=event.link_id
     and preference.channel='in_app'
     and preference.topic=event.topic
     and preference.opted_in
    left join public.customer_in_app_inbox_state state on state.event_id=event.id
    left join public.customer_in_app_inbox_resolutions resolution on resolution.event_id=event.id
   where app.customer_push_event_eligible_v95(event.source_kind,event.topic)
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
      join public.customer_notification_preferences preference
        on preference.business_id=event.business_id
       and preference.identity_id=event.identity_id
       and preference.auth_user_id=event.auth_user_id
       and preference.link_id=event.link_id
       and preference.channel='in_app'
       and preference.topic=event.topic
       and preference.opted_in
      left join public.customer_in_app_inbox_state state
        on state.event_id=event.id
      left join public.customer_in_app_inbox_resolutions resolution
        on resolution.event_id=event.id
     where delivery.status in ('queued','retry')
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

create or replace function public.internal_customer_push_report_v95(
  p_delivery_id uuid,p_lease_token uuid,p_worker_id uuid,p_result text,
  p_http_status integer,p_error_code text,p_retry_after timestamptz,
  p_idempotency_key uuid
)
returns jsonb language plpgsql security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare
  v_delivery public.customer_push_deliveries_v95%rowtype;
  v_hash text; v_prior record; v_response jsonb; v_status text;
begin
  if p_delivery_id is null or p_lease_token is null or p_worker_id is null
     or p_idempotency_key is null or p_result not in ('sent','retry','gone','failed')
     or (p_http_status is not null and p_http_status not between 100 and 599)
     or length(coalesce(p_error_code,''))>80 then
    raise exception 'invalid push delivery result' using errcode='22023';
  end if;
  v_hash:=app.c46_sha256_hex(jsonb_build_object(
    'delivery_id',p_delivery_id,'lease_token',p_lease_token,'worker_id',p_worker_id,
    'result',p_result,'http_status',p_http_status,'error_code',nullif(p_error_code,''),
    'retry_after',p_retry_after
  )::text);
  perform pg_advisory_xact_lock(hashtextextended(p_delivery_id::text||':'||p_idempotency_key::text,95));
  select request_hash,response into v_prior
    from public.customer_push_delivery_results_v95
   where delivery_id=p_delivery_id and idempotency_key=p_idempotency_key;
  if found then
    if v_prior.request_hash<>v_hash then
      raise exception 'idempotency key conflict' using errcode='22000';
    end if;
    return v_prior.response;
  end if;
  select * into v_delivery from public.customer_push_deliveries_v95
   where id=p_delivery_id for update;
  if not found or v_delivery.status<>'leased'
     or v_delivery.lease_token<>p_lease_token
     or v_delivery.leased_by<>p_worker_id
     or v_delivery.lease_until<now() then
    raise exception 'push delivery lease is not current' using errcode='40001';
  end if;
  v_status:=case
    when p_result='sent' then 'sent'
    when p_result='gone' then 'gone'
    when p_result='failed' or v_delivery.attempt_count>=5 then 'failed'
    else 'retry' end;
  v_response:=jsonb_build_object(
    'delivery_id',p_delivery_id,'status',v_status,'attempt',v_delivery.attempt_count
  );
  insert into public.customer_push_delivery_results_v95(
    delivery_id,attempt_number,lease_token,worker_id,result,http_status,error_code,
    idempotency_key,request_hash,response
  ) values(
    p_delivery_id,v_delivery.attempt_count,p_lease_token,p_worker_id,p_result,
    p_http_status,nullif(p_error_code,''),p_idempotency_key,v_hash,v_response
  );
  update public.customer_push_deliveries_v95 set
    status=v_status,lease_token=null,leased_by=null,lease_until=null,
    next_attempt_at=case when v_status='retry'
      then greatest(coalesce(p_retry_after,now()),now()+make_interval(secs=>least(300,15*(2^attempt_count)::integer)))
      else next_attempt_at end,
    last_http_status=p_http_status,last_error_code=nullif(p_error_code,''),
    completed_at=case when v_status in ('sent','failed','gone') then now() else null end,
    updated_at=now()
  where id=p_delivery_id;
  if v_status='gone' then
    update public.customer_push_subscriptions_v95
       set status='revoked',revoked_at=now(),updated_at=now()
     where id=v_delivery.subscription_id;
  end if;
  return v_response;
end
$$;

revoke all on function app.customer_push_event_eligible_v95(text,text)
  from public,anon,authenticated;
revoke all on function app.customer_push_endpoint_supported_v95(text)
  from public,anon,authenticated;
revoke all on function public.customer_register_push_subscription_v95(text,text,text,uuid)
  from public,anon,authenticated;
revoke all on function public.customer_unregister_push_subscription_v95(uuid,uuid)
  from public,anon,authenticated;
revoke all on function public.internal_customer_push_claim_v95(uuid,integer,integer)
  from public,anon,authenticated;
revoke all on function public.internal_customer_push_report_v95(
  uuid,uuid,uuid,text,integer,text,timestamptz,uuid
) from public,anon,authenticated;

grant execute on function public.customer_register_push_subscription_v95(text,text,text,uuid)
  to authenticated;
grant execute on function public.customer_unregister_push_subscription_v95(uuid,uuid)
  to authenticated;
grant execute on function public.internal_customer_push_claim_v95(uuid,integer,integer)
  to service_role;
grant execute on function public.internal_customer_push_report_v95(
  uuid,uuid,uuid,text,integer,text,timestamptz,uuid
) to service_role;

commit;
