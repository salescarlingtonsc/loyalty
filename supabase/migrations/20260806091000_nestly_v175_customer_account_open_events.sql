-- NESTLY v175 - CANONICAL CUSTOMER ACCOUNT-OPEN EVENT
--
-- Problem: the only "a customer looked at their account" signal today is the
-- OPTIONAL client-recorded v100 interaction `customer.programme_viewed`. It is
-- client-authored, opt-in, and therefore unusable as truth for a growth report
-- that must answer "how many customers opened their account with this firm in
-- this period, whether through the counter/sales path or their own login".
--
-- Shape decision (recorded so it is not re-litigated):
--   v100 owns the adoption-event home. Its server-authored events must carry
--   complete canonical source evidence and are deduplicated by the table
--   constraint (source_table, source_id, event_name). A raw per-day event
--   therefore needs a canonical per-day source ROW - it cannot hang off
--   customer_links (that would collapse to one event per customer forever) and
--   it cannot use idempotency_key (the v100 authority-shape check forbids a key
--   on server events).
--
--   So this migration introduces the canonical day row itself:
--     public.customer_account_open_days_v175
--   one row per (business, customer subject, channel, Singapore calendar day),
--   inserted with ON CONFLICT DO NOTHING. An AFTER INSERT trigger appends the
--   v100 server event `customer.account_open` from that row. Result:
--     * raw events exist, one per customer per channel per day  -> DAU-style,
--     * min(open_date) per subject                              -> first-open,
--     * repeated opens on the same day never inflate counts.
--
--   The customer subject is anchored on the firm-scoped client row whenever one
--   is resolvable (`client:<uuid>`), falling back to the platform login
--   (`auth:<uuid>`) only when no client relationship exists yet. The recorder
--   resolves a verified customer_links client for an authenticated caller so
--   the same human is not counted twice across channels.
--
-- Channels: 'wallet' (personal login opened the firm's programme),
--           'booking' (customer opened/managed their own booking),
--           'join'   (counter/QR sales path opened the relationship).
--
-- Privacy: no contact details, free text, routes, tokens or search terms are
-- stored. Retention mirrors v100 at 400 days with its own bounded purge.

begin;

-- 1) Event kind -------------------------------------------------------------

insert into public.product_adoption_event_taxonomy_v100(
  event_name,source_authority,actor_scope,required_module,required_mode,
  business_scope_required,economic_event,description
) values(
  'customer.account_open','server','customer',null,null,true,false,
  'Canonical per-day evidence that a customer opened their firm account.'
);

-- 2) Canonical per-day source table -----------------------------------------

create table public.customer_account_open_days_v175 (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete restrict,
  client_id uuid,
  auth_user_id uuid,
  channel text not null check (channel in ('wallet','booking','join')),
  open_date date not null,
  subject_key text generated always as (
    coalesce('client:'||client_id::text,'auth:'||auth_user_id::text)
  ) stored,
  first_opened_at timestamptz not null,
  recorded_at timestamptz not null default now(),
  retention_until timestamptz not null default (now()+interval '400 days'),
  constraint customer_account_open_days_v175_client_business_fk
    foreign key (business_id,client_id)
    references public.clients(business_id,id) on delete restrict,
  constraint customer_account_open_days_v175_subject_check check (
    client_id is not null or auth_user_id is not null
  ),
  constraint customer_account_open_days_v175_retention_check check (
    retention_until>=recorded_at+interval '399 days'
    and retention_until<=recorded_at+interval '401 days'
  )
);

create unique index customer_account_open_days_v175_subject_day_uk
  on public.customer_account_open_days_v175(
    business_id,subject_key,channel,open_date
  );
create index customer_account_open_days_v175_business_day_idx
  on public.customer_account_open_days_v175(business_id,open_date,channel);
create index customer_account_open_days_v175_retention_idx
  on public.customer_account_open_days_v175(retention_until);

alter table public.customer_account_open_days_v175
  enable row level security;
revoke all privileges on table public.customer_account_open_days_v175
  from public,anon,authenticated,service_role;

comment on table public.customer_account_open_days_v175 is
  'Append-only canonical evidence of customer account opens, deduplicated per business, customer subject, channel and Singapore calendar day. No contact details, free text, routes or tokens.';

-- 3) Append-only guard (mirrors the v100 retention contract) -----------------

create or replace function app.v175_account_open_immutable_guard()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public, app, pg_temp
as $$
begin
  if tg_op='DELETE'
     and coalesce(
       pg_catalog.current_setting('app.v175_retention_purge',true),''
     )='on'
     and old.retention_until<clock_timestamp() then
    return old;
  end if;
  raise exception 'v175 account-open evidence is append-only'
    using errcode='restrict_violation';
end
$$;
revoke all privileges on function app.v175_account_open_immutable_guard()
  from public,anon,authenticated,service_role;

create trigger customer_account_open_days_v175_immutable
  before update or delete on public.customer_account_open_days_v175
  for each row execute function app.v175_account_open_immutable_guard();

-- 4) v100 event projection ---------------------------------------------------

create or replace function app.capture_customer_account_open_adoption_v175()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public, app, pg_temp
as $$
begin
  perform app.append_server_adoption_event_v100(
    'customer.account_open',new.business_id,null,new.auth_user_id,
    'customer_account_open_days_v175',new.id,'INSERT',new.first_opened_at
  );
  return new;
end
$$;
revoke all privileges on function
  app.capture_customer_account_open_adoption_v175()
  from public,anon,authenticated,service_role;

create trigger customer_account_open_days_adoption_v175
  after insert on public.customer_account_open_days_v175
  for each row
  execute function app.capture_customer_account_open_adoption_v175();

-- 5) Internal recorder -------------------------------------------------------

create or replace function app.record_customer_account_open_v175(
  p_business uuid,
  p_auth_user uuid,
  p_client uuid,
  p_channel text,
  p_occurred_at timestamptz default now()
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public, app, pg_temp
as $$
declare
  v_client uuid:=p_client;
  v_when timestamptz:=coalesce(p_occurred_at,clock_timestamp());
  v_date date;
  v_id uuid;
  v_recorded boolean:=false;
begin
  if p_business is null then
    raise exception 'account-open evidence requires a tenant'
      using errcode='22023';
  end if;
  if p_channel is null or p_channel not in ('wallet','booking','join') then
    raise exception 'unsupported account-open channel: %',p_channel
      using errcode='22023';
  end if;
  -- Clock skew or a stale retry must never fail the customer request; clamp
  -- instead of raising so callers stay fire-and-forget.
  if v_when<clock_timestamp()-interval '24 hours'
     or v_when>clock_timestamp()+interval '5 minutes' then
    v_when:=clock_timestamp();
  end if;
  -- Anchor the subject on the firm-scoped client row whenever the platform
  -- login already has a verified relationship, so one human is not counted as
  -- two subjects across channels.
  if v_client is null and p_auth_user is not null then
    select customer_link.client_id into v_client
    from public.customer_links customer_link
    where customer_link.business_id=p_business
      and customer_link.auth_user_id=p_auth_user
      and customer_link.state='verified'
    limit 1;
  end if;
  if v_client is null and p_auth_user is null then
    return pg_catalog.jsonb_build_object(
      'recorded',false,'reason','no_identity'
    );
  end if;
  v_date:=(v_when at time zone 'Asia/Singapore')::date;

  insert into public.customer_account_open_days_v175(
    business_id,client_id,auth_user_id,channel,open_date,first_opened_at
  ) values(
    p_business,v_client,p_auth_user,p_channel,v_date,v_when
  )
  on conflict (business_id,subject_key,channel,open_date) do nothing
  returning id into v_id;

  if v_id is not null then
    v_recorded:=true;
  else
    select day_row.id into v_id
    from public.customer_account_open_days_v175 day_row
    where day_row.business_id=p_business
      and day_row.channel=p_channel
      and day_row.open_date=v_date
      and day_row.subject_key=coalesce(
        'client:'||v_client::text,'auth:'||p_auth_user::text
      );
  end if;

  return pg_catalog.jsonb_build_object(
    'recorded',v_recorded,'day_id',v_id,'business_id',p_business,
    'channel',p_channel,'open_date',v_date
  );
end
$$;
revoke all privileges on function app.record_customer_account_open_v175(
  uuid,uuid,uuid,text,timestamptz
) from public,anon,authenticated,service_role;

-- 6) Gateway entry points ----------------------------------------------------
-- The public gateway is deliberately identity-blind: it holds a join token, a
-- management token hash or a verified Auth user, never a client id. These
-- wrappers resolve the identity in SQL from evidence the gateway already has,
-- and they never raise on a merely unattributable request.

create or replace function public.internal_record_account_open_join_v175(
  p_join_token text,
  p_phone text
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public, app, pg_temp
as $$
declare
  v_business uuid;
  v_phone text:=app.norm_phone(p_phone);
  v_client uuid;
begin
  if p_join_token is null or v_phone is null then
    return pg_catalog.jsonb_build_object(
      'recorded',false,'reason','no_identity'
    );
  end if;
  select join_qr.business_id into v_business
  from public.business_customer_join_qr_v89 join_qr
  where join_qr.token_hash=app.v89_sha256(p_join_token)
    and join_qr.status='active'
    and join_qr.expires_at>now();
  if v_business is null then
    return pg_catalog.jsonb_build_object(
      'recorded',false,'reason','no_business'
    );
  end if;
  select client.id into v_client
  from public.clients client
  where client.business_id=v_business
    and client.phone_norm=v_phone;
  if v_client is null then
    return pg_catalog.jsonb_build_object(
      'recorded',false,'reason','no_identity'
    );
  end if;
  return app.record_customer_account_open_v175(
    v_business,null,v_client,'join',clock_timestamp()
  );
end
$$;
revoke all privileges on function
  public.internal_record_account_open_join_v175(text,text)
  from public,anon,authenticated,service_role;
grant execute on function
  public.internal_record_account_open_join_v175(text,text) to service_role;

create or replace function
  public.internal_record_account_open_booking_token_v175(p_token_hash text)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public, app, pg_temp
as $$
declare
  v_token app.booking_management_tokens%rowtype;
begin
  if p_token_hash is null or p_token_hash !~ '^[0-9a-f]{64}$' then
    return pg_catalog.jsonb_build_object('recorded',false,'reason','no_token');
  end if;
  select management_token.* into v_token
  from app.booking_management_tokens management_token
  where management_token.token_hash=pg_catalog.decode(p_token_hash,'hex')
    and management_token.revoked_at is null
    and management_token.expires_at>clock_timestamp();
  if not found then
    return pg_catalog.jsonb_build_object('recorded',false,'reason','no_token');
  end if;
  if v_token.customer_client_id is null
     and v_token.authenticated_user_id is null then
    return pg_catalog.jsonb_build_object(
      'recorded',false,'reason','no_identity'
    );
  end if;
  return app.record_customer_account_open_v175(
    v_token.business_id,v_token.authenticated_user_id,
    v_token.customer_client_id,'booking',clock_timestamp()
  );
end
$$;
revoke all privileges on function
  public.internal_record_account_open_booking_token_v175(text)
  from public,anon,authenticated,service_role;
grant execute on function
  public.internal_record_account_open_booking_token_v175(text) to service_role;

-- The wallet channel is the customer's own authenticated portal session. The
-- caller asserts nothing: the verified relationship is proved server-side and
-- the day row is the canonical write.
create or replace function public.customer_record_account_open_v175(
  p_business uuid
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public, app, pg_temp
as $$
declare
  v_actor uuid:=auth.uid();
  v_client uuid;
begin
  if v_actor is null then
    raise exception 'authenticated customer session is required'
      using errcode='28000';
  end if;
  select customer_link.client_id into v_client
  from public.customer_links customer_link
  where customer_link.business_id=p_business
    and customer_link.auth_user_id=v_actor
    and customer_link.state='verified'
  limit 1;
  if v_client is null then
    raise exception 'verified customer relationship is required'
      using errcode='42501';
  end if;
  return app.record_customer_account_open_v175(
    p_business,v_actor,v_client,'wallet',clock_timestamp()
  );
end
$$;
revoke all privileges on function
  public.customer_record_account_open_v175(uuid)
  from public,anon,authenticated,service_role;
grant execute on function
  public.customer_record_account_open_v175(uuid) to authenticated;

-- 7) Per-firm reporting ------------------------------------------------------

create or replace function public.platform_customer_account_opens_v175(
  p_business uuid,
  p_from date default ((now() at time zone 'Asia/Singapore')::date
    -interval '29 days')::date,
  p_to date default (now() at time zone 'Asia/Singapore')::date
)
returns jsonb
language plpgsql
stable
security definer
set search_path = pg_catalog, public, app, pg_temp
as $$
declare
  v_authorized boolean:=false;
  v_today date:=(clock_timestamp() at time zone 'Asia/Singapore')::date;
  v_totals jsonb;
  v_channels jsonb;
  v_daily jsonb;
begin
  if auth.uid() is null then
    raise exception 'authenticated report session is required'
      using errcode='28000';
  end if;
  v_authorized:=
    app.is_super_admin()
    or app.has_perm(p_business,'view_finance')
    or (
      app.v89_can_access_business(p_business)
      and app.v89_platform_can('reports','r')
    );
  if not v_authorized then
    raise exception 'business adoption report is outside role scope'
      using errcode='42501';
  end if;
  if p_business is null
     or p_from is null
     or p_to is null
     or p_to<p_from
     or (p_to-p_from)>366
     or p_to>v_today+1 then
    raise exception
      'report range must be ordered, no longer than 367 days and not future'
      using errcode='22023';
  end if;

  with window_rows as(
    select
      day_row.subject_key,day_row.channel,day_row.open_date
    from public.customer_account_open_days_v175 day_row
    where day_row.business_id=p_business
      and day_row.open_date between p_from and p_to
  ), subject_first as(
    select
      day_row.subject_key,min(day_row.open_date) as first_open_date
    from public.customer_account_open_days_v175 day_row
    where day_row.business_id=p_business
    group by day_row.subject_key
  )
  select
    pg_catalog.jsonb_build_object(
      'opens',(select count(*) from window_rows),
      'distinct_customers',(
        select count(distinct window_row.subject_key) from window_rows window_row
      ),
      'first_time_customers',(
        select count(*)
        from subject_first
        where subject_first.first_open_date between p_from and p_to
      )
    ),
    coalesce((
      select pg_catalog.jsonb_agg(
        pg_catalog.jsonb_build_object(
          'channel',channel_summary.channel,
          'opens',channel_summary.opens,
          'distinct_customers',channel_summary.distinct_customers
        ) order by channel_summary.channel
      )
      from(
        select
          window_row.channel,
          count(*)::bigint as opens,
          count(distinct window_row.subject_key)::bigint
            as distinct_customers
        from window_rows window_row
        group by window_row.channel
      ) channel_summary
    ),'[]'::jsonb),
    coalesce((
      select pg_catalog.jsonb_agg(
        pg_catalog.jsonb_build_object(
          'date',daily_summary.open_date,
          'opens',daily_summary.opens,
          'distinct_customers',daily_summary.distinct_customers,
          'first_time_customers',daily_summary.first_time_customers
        ) order by daily_summary.open_date
      )
      from(
        select
          window_row.open_date,
          count(*)::bigint as opens,
          count(distinct window_row.subject_key)::bigint
            as distinct_customers,
          count(distinct window_row.subject_key) filter(
            where subject_first.first_open_date=window_row.open_date
          )::bigint as first_time_customers
        from window_rows window_row
        join subject_first
          on subject_first.subject_key=window_row.subject_key
        group by window_row.open_date
      ) daily_summary
    ),'[]'::jsonb)
  into v_totals,v_channels,v_daily;

  return pg_catalog.jsonb_build_object(
    'business_id',p_business,
    'from',p_from,
    'to',p_to,
    'timezone','Asia/Singapore',
    'contract_version','v175',
    'dedupe','one event per customer subject per channel per calendar day',
    'totals',v_totals,
    'by_channel',v_channels,
    'daily',v_daily
  );
end
$$;
revoke all privileges on function public.platform_customer_account_opens_v175(
  uuid,date,date
) from public,anon,authenticated,service_role;
grant execute on function public.platform_customer_account_opens_v175(
  uuid,date,date
) to authenticated;

-- 8) Bounded retention -------------------------------------------------------

create or replace function public.purge_customer_account_open_days_v175(
  p_limit integer default 5000
)
returns integer
language plpgsql
security definer
set search_path = pg_catalog, public, app, pg_temp
as $$
declare
  v_deleted integer:=0;
begin
  if p_limit not between 1 and 10000 then
    raise exception 'purge limit must be 1..10000' using errcode='22023';
  end if;
  perform pg_catalog.set_config('app.v175_retention_purge','on',true);
  with expired as(
    select day_row.id
    from public.customer_account_open_days_v175 day_row
    where day_row.retention_until<clock_timestamp()
    order by day_row.retention_until,day_row.id
    limit p_limit
    for update skip locked
  )
  delete from public.customer_account_open_days_v175 day_row
  using expired
  where day_row.id=expired.id;
  get diagnostics v_deleted=row_count;
  perform pg_catalog.set_config('app.v175_retention_purge','',true);
  return v_deleted;
end
$$;
revoke all privileges on function
  public.purge_customer_account_open_days_v175(integer)
  from public,anon,authenticated,service_role;
grant execute on function
  public.purge_customer_account_open_days_v175(integer) to service_role;

do $cron$
begin
  if to_regnamespace('cron') is not null
     and to_regprocedure('cron.schedule(text,text,text)') is not null then
    if exists(
      select 1 from cron.job
      where jobname='nestly-v175-account-open-retention-daily'
    ) then
      perform cron.unschedule('nestly-v175-account-open-retention-daily');
    end if;
    perform cron.schedule(
      'nestly-v175-account-open-retention-daily',
      '50 19 * * *',
      $command$select public.purge_customer_account_open_days_v175(5000)$command$
    );
  else
    raise notice
      'v175: pg_cron is absent; account-open retention purge is not scheduled';
  end if;
end
$cron$;

comment on function public.platform_customer_account_opens_v175(uuid,date,date)
  is 'Per-firm customer account-open report. Opens are deduplicated per customer subject, channel and Singapore calendar day; first_time_customers counts subjects whose earliest open for this firm falls inside the window.';
comment on function public.customer_record_account_open_v175(uuid) is
  'Records a wallet-channel account open for the calling verified customer. The relationship is proved server-side; the caller asserts nothing.';

commit;
