-- FRENLY v41 — transactional customer modules and bearer-safe gift-card reads.
-- Forward-only. This migration has not been applied to any remote database.

begin;

create or replace function app.v41_request_hash(p_value text)
returns text
language sql
immutable
strict
set search_path to 'pg_catalog', 'extensions', 'pg_temp'
as $$
  select encode(extensions.digest(convert_to(p_value, 'UTF8'), 'sha256'), 'hex')
$$;

revoke all privileges on function app.v41_request_hash(text)
  from public, anon, authenticated;

-- The deployable canonical history contains v14b's app.can_module() but not the
-- source-only v14 read/write split. Define that split forward here so a clean
-- canonical apply is self-contained. NULL preserves v14b behavior exactly.
alter table public.staff add column if not exists module_perms jsonb;
alter table public.staff
  add constraint staff_module_perms_v41_shape_check check (
    module_perms is null
    or (
      jsonb_typeof(module_perms) = 'object'
      and not jsonb_path_exists(module_perms, '$.* ? (@ != "r" && @ != "rw")')
    )
  );
comment on column public.staff.module_perms is
  'Per-module read/write override: NULL inherits legacy modules, r is read-only, rw is read/write.';

create or replace function app.can_module_read(p_business uuid, p_module text)
returns boolean
language sql
stable
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
  select exists (
    select 1 from public.staff s
     where s.business_id = p_business
       and s.user_id = auth.uid()
       and s.active
       and (
         s.role = 'owner'
         or (s.module_perms is not null and s.module_perms ? p_module)
         or (s.module_perms is null and (s.modules is null or p_module = any(s.modules)))
       )
  )
$$;

create or replace function app.can_module_write(p_business uuid, p_module text)
returns boolean
language sql
stable
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
  select exists (
    select 1 from public.staff s
     where s.business_id = p_business
       and s.user_id = auth.uid()
       and s.active
       and (
         s.role = 'owner'
         or (s.module_perms is not null and s.module_perms ->> p_module = 'rw')
         or (s.module_perms is null and (s.modules is null or p_module = any(s.modules)))
       )
  )
$$;

revoke all privileges on function app.can_module_read(uuid,text)
  from public, anon, authenticated;
grant execute on function app.can_module_read(uuid,text) to authenticated;
revoke all privileges on function app.can_module_write(uuid,text)
  from public, anon, authenticated;
grant execute on function app.can_module_write(uuid,text) to authenticated;

create or replace function app.staff_module_perms(p_business uuid)
returns jsonb
language sql
stable
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
  select coalesce(jsonb_object_agg(e.module_name, e.access_mode), '{}'::jsonb)
    from (
      select module_name,
             case when s.role = 'owner' or s.module_perms is null
                  then 'rw' else s.module_perms ->> module_name end as access_mode
        from public.staff s
        join public.businesses b on b.id = s.business_id
        cross join lateral unnest(b.enabled_modules) as enabled(module_name)
       where s.business_id = p_business
         and s.user_id = auth.uid()
         and s.active
         and (
           s.role = 'owner'
           or (s.module_perms is not null and s.module_perms ? module_name)
           or (s.module_perms is null and (s.modules is null or module_name = any(s.modules)))
         )
    ) e
$$;

create or replace function app.staff_modules(p_business uuid)
returns text[]
language sql
stable
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
  select coalesce(array_agg(k order by k), array[]::text[])
    from jsonb_object_keys(app.staff_module_perms(p_business)) as keys(k)
$$;

create or replace function public.get_my_modules(p_business uuid)
returns json
language sql
stable
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
  select json_build_object(
    'modules', to_json(app.staff_modules(p_business)),
    'module_perms', app.staff_module_perms(p_business),
    'role', (select s.role from public.staff s
              where s.business_id = p_business and s.user_id = auth.uid() and s.active
              order by case when s.role = 'owner' then 0 else 1 end, s.created_at limit 1),
    'is_super_admin', app.is_super_admin()
  )
$$;

create or replace function public.get_my_personas()
returns jsonb
language plpgsql
stable
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_actor uuid := auth.uid();
  v_staff jsonb := '[]'::jsonb;
  v_customer jsonb := '[]'::jsonb;
  v_default_route text := '#/';
begin
  if v_actor is null then
    raise exception 'authenticated session required' using errcode = '28000';
  end if;
  select coalesce(jsonb_agg(jsonb_build_object(
    'business_slug', b.slug,
    'business_name', b.name,
    'role', s.role,
    'modules', app.staff_modules(s.business_id)
  ) order by b.name, b.slug), '[]'::jsonb)
    into v_staff
    from public.staff s
    join public.businesses b on b.id = s.business_id
   where s.user_id = v_actor and s.active;
  if app.platform_feature_enabled('customer_identity')
     and app.platform_feature_enabled('customer_claims')
     and app.platform_feature_enabled('customer_wallet') then
    select coalesce(jsonb_agg(jsonb_build_object(
      'business_slug', b.slug,
      'business_name', b.name
    ) order by b.name, b.slug), '[]'::jsonb)
      into v_customer
      from public.customer_identities ci
      join public.customer_links l
        on l.identity_id = ci.id
       and l.auth_user_id = v_actor
       and l.state = 'verified'
      join public.businesses b on b.id = l.business_id
     where ci.auth_user_id = v_actor and ci.status = 'active';
  end if;
  if jsonb_array_length(v_staff) > 0 then
    v_default_route := '#/workspace/' || (v_staff->0->>'business_slug') || '/dashboard';
  elsif jsonb_array_length(v_customer) > 0 then
    v_default_route := '#/wallet';
  elsif app.platform_feature_enabled('customer_identity') then
    v_default_route := '#/claim';
  end if;
  return jsonb_build_object(
    'staff', v_staff,
    'customer', v_customer,
    'default_route', v_default_route
  );
end
$$;

revoke all privileges on function app.staff_module_perms(uuid)
  from public, anon, authenticated;
revoke all privileges on function app.staff_modules(uuid)
  from public, anon, authenticated;
revoke all privileges on function public.get_my_modules(uuid)
  from public, anon, authenticated;
grant execute on function public.get_my_modules(uuid) to authenticated;
revoke all privileges on function public.get_my_personas()
  from public, anon, authenticated;
grant execute on function public.get_my_personas() to authenticated;

alter table public.consents
  add constraint consents_id_business_uk unique (id, business_id);
alter table public.gift_cards
  add constraint gift_cards_id_business_uk unique (id, business_id);

create table public.customer_staff_operations (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  actor uuid not null references auth.users(id) on delete restrict,
  operation_type text not null check (operation_type in ('create_client', 'consent_transition')),
  idempotency_key uuid not null,
  request_hash text not null check (request_hash ~ '^[0-9a-f]{64}$'),
  status text not null check (status in ('completed')),
  requested_marketing_consent boolean not null,
  client_id uuid not null,
  consent_event_id uuid not null,
  referral_id uuid,
  created_at timestamptz not null default now(),
  unique (business_id, actor, operation_type, idempotency_key),
  unique (business_id, idempotency_key),
  foreign key (client_id, business_id)
    references public.clients(id, business_id) on delete restrict,
  foreign key (consent_event_id, business_id)
    references public.consents(id, business_id) on delete restrict,
  foreign key (referral_id, business_id)
    references public.referrals(id, business_id) on delete restrict
);

comment on table public.customer_staff_operations is
  'v41 append-only immutable idempotency and provenance records for staff customer mutations.';

create table public.gift_card_issue_operations (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  actor uuid not null references auth.users(id) on delete restrict,
  idempotency_key uuid not null,
  request_hash text not null check (request_hash ~ '^[0-9a-f]{64}$'),
  status text not null check (status in ('completed')),
  amount_cents integer not null check (amount_cents > 0),
  gift_card_id uuid not null,
  sale_id uuid not null,
  created_at timestamptz not null default now(),
  unique (business_id, actor, idempotency_key),
  unique (business_id, idempotency_key),
  foreign key (gift_card_id, business_id)
    references public.gift_cards(id, business_id) on delete restrict,
  foreign key (sale_id, business_id)
    references public.sales(id, business_id) on delete restrict
);

comment on table public.gift_card_issue_operations is
  'v41 append-only immutable issuance provenance containing only a hash, safe facts, and exact card/sale identifiers.';

alter table public.customer_staff_operations enable row level security;
alter table public.gift_card_issue_operations enable row level security;
revoke all privileges on table public.customer_staff_operations from public, anon, authenticated;
revoke all privileges on table public.gift_card_issue_operations from public, anon, authenticated;

create or replace function app.v41_operation_immutable_guard()
returns trigger
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
begin
  raise exception '% is append-only and immutable', tg_table_name
    using errcode = '55000';
end
$$;

revoke all privileges on function app.v41_operation_immutable_guard()
  from public, anon, authenticated;
create trigger customer_staff_operations_immutable_guard
  before update or delete on public.customer_staff_operations
  for each row execute function app.v41_operation_immutable_guard();
create trigger gift_card_issue_operations_immutable_guard
  before update or delete on public.gift_card_issue_operations
  for each row execute function app.v41_operation_immutable_guard();

create or replace function public.staff_create_client(
  p_business uuid,
  p_idempotency_key uuid,
  p_full_name text,
  p_phone text default null,
  p_email text default null,
  p_birth_date date default null,
  p_gender text default null,
  p_marketing_consent boolean default false,
  p_referrer_code text default null,
  p_source text default 'staff customer form')
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_actor uuid := auth.uid();
  v_staff uuid;
  v_name text := nullif(btrim(p_full_name), '');
  v_phone text := nullif(btrim(p_phone), '');
  v_email text := nullif(lower(btrim(p_email)), '');
  v_gender text := nullif(lower(btrim(p_gender)), '');
  v_referrer_code text := nullif(upper(btrim(p_referrer_code)), '');
  v_source text := coalesce(nullif(btrim(p_source), ''), 'staff customer form');
  v_payload jsonb;
  v_hash text;
  v_existing public.customer_staff_operations%rowtype;
  v_client public.clients%rowtype;
  v_consent_id uuid;
  v_referrer uuid;
  v_referral_id uuid;
  v_result jsonb;
begin
  if v_actor is null or not app.can_module_write(p_business, 'clients') then
    raise exception 'active clients-module write authorization is required'
      using errcode = '42501';
  end if;
  if v_referrer_code is not null
     and not app.can_module_write(p_business, 'referrals') then
    raise exception 'active referrals-module write authorization is required for referral links'
      using errcode = '42501';
  end if;
  select s.id into v_staff
    from public.staff s
   where s.business_id = p_business
     and s.user_id = v_actor
     and s.active
   order by case when s.role = 'owner' then 0 else 1 end, s.created_at
   limit 1
   for update;
  if not found then
    raise exception 'active staff authorization is required'
      using errcode = '42501';
  end if;
  if p_idempotency_key is null or v_name is null or char_length(v_name) < 2
     or char_length(v_name) > 200
     or (v_gender is not null and v_gender not in ('female', 'male', 'other'))
     or (v_phone is not null and char_length(v_phone) > 80)
     or (v_email is not null and char_length(v_email) > 320)
     or char_length(v_source) > 200 then
    raise exception 'invalid customer request' using errcode = '22023';
  end if;

  v_payload := jsonb_build_object(
    'birth_date', p_birth_date,
    'business_id', p_business,
    'email', v_email,
    'full_name', v_name,
    'gender', v_gender,
    'marketing_consent', coalesce(p_marketing_consent, false),
    'phone', v_phone,
    'referrer_code', v_referrer_code,
    'source', v_source
  );
  v_hash := app.v41_request_hash(v_payload::text);
  perform pg_advisory_xact_lock(hashtextextended(
    'v41:customer:' || p_business::text || ':' || p_idempotency_key::text, 0));

  select * into v_existing
    from public.customer_staff_operations o
   where o.business_id = p_business
     and o.idempotency_key = p_idempotency_key
   for update;
  if found then
    if v_existing.actor is distinct from v_actor
       or v_existing.operation_type <> 'create_client'
       or v_existing.request_hash <> v_hash then
      raise exception 'idempotency key conflicts with another customer request'
        using errcode = '23505';
    end if;
    return jsonb_build_object(
      'status', 'completed',
      'client_id', v_existing.client_id,
      'marketing_consent', v_existing.requested_marketing_consent,
      'consent_event_id', v_existing.consent_event_id,
      'referral_id', v_existing.referral_id
    );
  end if;

  insert into public.clients (
    business_id, full_name, phone, email, birth_date, gender, marketing_consent
  ) values (
    p_business, v_name, v_phone, v_email, p_birth_date, v_gender,
    coalesce(p_marketing_consent, false)
  ) returning * into v_client;

  insert into public.consents (
    business_id, client_id, channel, action, source, actor
  ) values (
    p_business, v_client.id, 'marketing',
    case when coalesce(p_marketing_consent, false) then 'granted' else 'withdrawn' end,
    v_source, v_actor
  ) returning id into v_consent_id;

  if v_referrer_code is not null then
    select c.id into v_referrer
      from public.clients c
     where c.business_id = p_business
       and c.referral_code = v_referrer_code
     limit 1
     for share;
    if not found or v_referrer = v_client.id then
      raise exception 'referrer code does not belong to this business'
        using errcode = '22023';
    end if;
    insert into public.referrals (
      business_id, referrer_client_id, referred_client_id, status
    ) values (
      p_business, v_referrer, v_client.id, 'pending'
    ) returning id into v_referral_id;
  end if;

  v_result := jsonb_build_object(
    'status', 'completed',
    'client_id', v_client.id,
    'marketing_consent', v_client.marketing_consent,
    'consent_event_id', v_consent_id,
    'referral_id', v_referral_id
  );
  insert into public.customer_staff_operations (
    business_id, actor, operation_type, idempotency_key, request_hash, status,
    requested_marketing_consent, client_id, consent_event_id, referral_id
  ) values (
    p_business, v_actor, 'create_client', p_idempotency_key, v_hash, 'completed',
    v_client.marketing_consent, v_client.id, v_consent_id, v_referral_id
  );
  return v_result;
end
$$;

create or replace function public.staff_set_marketing_consent(
  p_business uuid,
  p_client uuid,
  p_idempotency_key uuid,
  p_marketing_consent boolean,
  p_source text default 'staff client page')
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_actor uuid := auth.uid();
  v_staff uuid;
  v_source text := coalesce(nullif(btrim(p_source), ''), 'staff client page');
  v_payload jsonb;
  v_hash text;
  v_existing public.customer_staff_operations%rowtype;
  v_client public.clients%rowtype;
  v_consent_id uuid;
  v_result jsonb;
begin
  if v_actor is null or not app.can_module_write(p_business, 'clients') then
    raise exception 'active clients-module write authorization is required'
      using errcode = '42501';
  end if;
  select s.id into v_staff
    from public.staff s
   where s.business_id = p_business
     and s.user_id = v_actor
     and s.active
   order by case when s.role = 'owner' then 0 else 1 end, s.created_at
   limit 1
   for update;
  if not found then
    raise exception 'active staff authorization is required'
      using errcode = '42501';
  end if;
  if p_client is null or p_idempotency_key is null or p_marketing_consent is null
     or char_length(v_source) > 200 then
    raise exception 'invalid consent request' using errcode = '22023';
  end if;

  v_payload := jsonb_build_object(
    'business_id', p_business,
    'client_id', p_client,
    'marketing_consent', p_marketing_consent,
    'source', v_source
  );
  v_hash := app.v41_request_hash(v_payload::text);
  perform pg_advisory_xact_lock(hashtextextended(
    'v41:customer:' || p_business::text || ':' || p_idempotency_key::text, 0));

  select * into v_existing
    from public.customer_staff_operations o
   where o.business_id = p_business
     and o.idempotency_key = p_idempotency_key
   for update;
  if found then
    if v_existing.actor is distinct from v_actor
       or v_existing.operation_type <> 'consent_transition'
       or v_existing.request_hash <> v_hash then
      raise exception 'idempotency key conflicts with another customer request'
        using errcode = '23505';
    end if;
    return jsonb_build_object(
      'status', 'completed',
      'client_id', v_existing.client_id,
      'marketing_consent', v_existing.requested_marketing_consent,
      'consent_event_id', v_existing.consent_event_id
    );
  end if;

  select * into v_client
    from public.clients c
   where c.id = p_client
     and c.business_id = p_business
   for update;
  if not found then
    raise exception 'client does not belong to this business'
      using errcode = '22023';
  end if;
  if v_client.marketing_consent = p_marketing_consent then
    raise exception 'requested consent state is already current'
      using errcode = '22023';
  end if;

  update public.clients
     set marketing_consent = p_marketing_consent
   where id = p_client and business_id = p_business;
  insert into public.consents (
    business_id, client_id, channel, action, source, actor
  ) values (
    p_business, p_client, 'marketing',
    case when p_marketing_consent then 'granted' else 'withdrawn' end,
    v_source, v_actor
  ) returning id into v_consent_id;

  v_result := jsonb_build_object(
    'status', 'completed',
    'client_id', p_client,
    'marketing_consent', p_marketing_consent,
    'consent_event_id', v_consent_id
  );
  insert into public.customer_staff_operations (
    business_id, actor, operation_type, idempotency_key, request_hash, status,
    requested_marketing_consent, client_id, consent_event_id
  ) values (
    p_business, v_actor, 'consent_transition', p_idempotency_key, v_hash, 'completed',
    p_marketing_consent, p_client, v_consent_id
  );
  return v_result;
end
$$;

create or replace function public.issue_gift_card(
  p_business uuid,
  p_amount integer,
  p_purchaser uuid,
  p_recipient_email text,
  p_idempotency_key uuid)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_actor uuid := auth.uid();
  v_staff uuid;
  v_email text := nullif(lower(btrim(p_recipient_email)), '');
  v_payload jsonb;
  v_hash text;
  v_existing public.gift_card_issue_operations%rowtype;
  v_code text;
  v_card public.gift_cards%rowtype;
  v_sale public.sales%rowtype;
  v_result jsonb;
begin
  if v_actor is null
     or not app.can_module_write(p_business, 'giftcards')
     or not app.has_perm(p_business, 'create_sales') then
    raise exception 'active giftcards-module and create-sales authorization is required'
      using errcode = '42501';
  end if;
  select s.id into v_staff
    from public.staff s
   where s.business_id = p_business
     and s.user_id = v_actor
     and s.active
     and 'create_sales' = any (app.role_perms(s.role))
   order by case when s.role = 'owner' then 0 else 1 end, s.created_at
   limit 1
   for update;
  if not found then
    raise exception 'active staff authorization is required'
      using errcode = '42501';
  end if;
  if p_idempotency_key is null or p_amount is null or p_amount <= 0
     or p_amount > 100000000 or (v_email is not null and char_length(v_email) > 320) then
    raise exception 'invalid gift-card issuance request'
      using errcode = '22023';
  end if;
  if p_purchaser is not null and not exists (
    select 1 from public.clients c
     where c.id = p_purchaser and c.business_id = p_business
  ) then
    raise exception 'purchaser does not belong to this business'
      using errcode = '22023';
  end if;

  v_payload := jsonb_build_object(
    'amount_cents', p_amount,
    'business_id', p_business,
    'purchaser_client_id', p_purchaser,
    'recipient_email', v_email
  );
  v_hash := app.v41_request_hash(v_payload::text);
  perform pg_advisory_xact_lock(hashtextextended(
    'v41:gift-card:' || p_business::text || ':' || p_idempotency_key::text, 0));

  select * into v_existing
    from public.gift_card_issue_operations o
   where o.business_id = p_business
     and o.idempotency_key = p_idempotency_key
   for update;
  if found then
    if v_existing.actor is distinct from v_actor
       or v_existing.request_hash <> v_hash then
      raise exception 'idempotency key conflicts with another gift-card request'
        using errcode = '23505';
    end if;
    select * into v_card
      from public.gift_cards g
     where g.id = v_existing.gift_card_id
       and g.business_id = p_business
     for share;
    return jsonb_build_object(
      'status', 'completed',
      'gift_card_id', v_existing.gift_card_id,
      'sale_id', v_existing.sale_id,
      'code', v_card.code,
      'initial_cents', v_existing.amount_cents,
      'balance_cents', v_existing.amount_cents
    );
  end if;

  if p_purchaser is not null then
    perform 1 from public.clients c
     where c.id = p_purchaser and c.business_id = p_business
     for share;
    if not found then
      raise exception 'purchaser does not belong to this business'
        using errcode = '22023';
    end if;
  end if;
  loop
    v_code := 'GC-' || upper(substr(md5(gen_random_uuid()::text || clock_timestamp()::text), 1, 12));
    exit when not exists (select 1 from public.gift_cards g where g.code = v_code);
  end loop;
  insert into public.gift_cards (
    business_id, code, initial_cents, balance_cents,
    purchaser_client_id, recipient_email
  ) values (
    p_business, v_code, p_amount, p_amount, p_purchaser, v_email
  ) returning * into v_card;
  insert into public.sales (
    business_id, client_id, kind, amount_cents, note, staff_id
  ) values (
    p_business, p_purchaser, 'gift_card', p_amount,
    'gift card liability issued', v_staff
  ) returning * into v_sale;

  v_result := jsonb_build_object(
    'status', 'completed',
    'gift_card_id', v_card.id,
    'sale_id', v_sale.id,
    'code', v_card.code,
    'initial_cents', v_card.initial_cents,
    'balance_cents', v_card.balance_cents
  );
  insert into public.gift_card_issue_operations (
    business_id, actor, idempotency_key, request_hash, status,
    amount_cents, gift_card_id, sale_id
  ) values (
    p_business, v_actor, p_idempotency_key, v_hash, 'completed',
    p_amount, v_card.id, v_sale.id
  );
  return v_result;
end
$$;

create or replace function public.staff_list_gift_cards(
  p_business uuid,
  p_limit integer default 100)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_actor uuid := auth.uid();
  v_staff uuid;
  v_limit integer := least(greatest(coalesce(p_limit, 100), 1), 100);
  v_result jsonb;
begin
  if v_actor is null or not app.can_module_read(p_business, 'giftcards') then
    raise exception 'active giftcards-module read authorization is required'
      using errcode = '42501';
  end if;
  select s.id into v_staff
    from public.staff s
   where s.business_id = p_business
     and s.user_id = v_actor
     and s.active
   order by case when s.role = 'owner' then 0 else 1 end, s.created_at
   limit 1;
  if not found then
    raise exception 'active staff authorization is required'
      using errcode = '42501';
  end if;
  select coalesce(jsonb_agg(jsonb_build_object(
    'gift_card_id', x.id,
    'code_suffix', right(x.code, 4),
    'initial_cents', x.initial_cents,
    'balance_cents', x.balance_cents,
    'status', x.status,
    'created_at', x.created_at
  ) order by x.created_at desc, x.id), '[]'::jsonb)
    into v_result
    from (
      select g.id, g.code, g.initial_cents, g.balance_cents, g.status, g.created_at
        from public.gift_cards g
       where g.business_id = p_business
       order by g.created_at desc, g.id
       limit v_limit
    ) x;
  return v_result;
end
$$;

create or replace function public.save_referral_program(
  p_business uuid,
  p_enabled boolean,
  p_reward_cents integer,
  p_min_spend_cents integer)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_actor uuid := auth.uid();
  v_staff uuid;
  v_program public.referral_programs%rowtype;
begin
  if v_actor is null or not app.can_module_write(p_business, 'referrals') then
    raise exception 'active referrals-module write authorization is required'
      using errcode = '42501';
  end if;
  select s.id into v_staff from public.staff s
   where s.business_id = p_business and s.user_id = v_actor and s.active
   order by case when s.role = 'owner' then 0 else 1 end, s.created_at limit 1 for update;
  if not found then raise exception 'active staff authorization is required' using errcode='42501'; end if;
  if p_enabled is null or p_reward_cents is null or p_reward_cents < 0
     or p_min_spend_cents is null or p_min_spend_cents < 0 then
    raise exception 'invalid referral program' using errcode='22023';
  end if;
  insert into public.referral_programs (business_id, enabled, reward_cents, min_spend_cents)
  values (p_business, p_enabled, p_reward_cents, p_min_spend_cents)
  on conflict (business_id) do update set
    enabled = excluded.enabled,
    reward_cents = excluded.reward_cents,
    min_spend_cents = excluded.min_spend_cents
  returning * into v_program;
  return jsonb_build_object('status','completed','program_id',v_program.id,
    'enabled',v_program.enabled,'reward_cents',v_program.reward_cents,
    'min_spend_cents',v_program.min_spend_cents);
end
$$;

create or replace function public.save_membership_plan(
  p_business uuid,
  p_plan uuid,
  p_name text,
  p_price_cents integer,
  p_cadence text,
  p_credit_cents integer,
  p_discount_pct numeric,
  p_active boolean)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_actor uuid := auth.uid();
  v_staff uuid;
  v_name text := nullif(btrim(p_name), '');
  v_plan public.membership_plans%rowtype;
begin
  if v_actor is null or not app.can_module_write(p_business, 'memberships') then
    raise exception 'active memberships-module write authorization is required'
      using errcode = '42501';
  end if;
  select s.id into v_staff from public.staff s
   where s.business_id=p_business and s.user_id=v_actor and s.active
   order by case when s.role='owner' then 0 else 1 end,s.created_at limit 1 for update;
  if not found then raise exception 'active staff authorization is required' using errcode='42501'; end if;
  if v_name is null or char_length(v_name)>200 or p_price_cents is null or p_price_cents<0
     or p_cadence not in ('monthly','annual') or p_credit_cents is null or p_credit_cents<0
     or p_discount_pct is null or p_discount_pct<0 or p_discount_pct>100 or p_active is null then
    raise exception 'invalid membership plan' using errcode='22023';
  end if;
  if p_plan is null then
    insert into public.membership_plans
      (business_id,name,price_cents,cadence,credit_cents,discount_pct,active)
    values (p_business,v_name,p_price_cents,p_cadence,p_credit_cents,p_discount_pct,p_active)
    returning * into v_plan;
  else
    perform 1 from public.membership_plans p
     where p.id=p_plan and p.business_id=p_business for update;
    if not found then raise exception 'membership plan does not belong to this business' using errcode='22023'; end if;
    update public.membership_plans set name=v_name,price_cents=p_price_cents,
      cadence=p_cadence,credit_cents=p_credit_cents,discount_pct=p_discount_pct,active=p_active
     where id=p_plan and business_id=p_business returning * into v_plan;
  end if;
  return jsonb_build_object('status','completed','plan_id',v_plan.id,'name',v_plan.name,
    'price_cents',v_plan.price_cents,'cadence',v_plan.cadence,'credit_cents',v_plan.credit_cents,
    'discount_pct',v_plan.discount_pct,'active',v_plan.active);
end
$$;

create or replace function public.set_membership_status(
  p_business uuid,
  p_membership uuid,
  p_status text)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_actor uuid := auth.uid();
  v_staff uuid;
  v_membership public.memberships%rowtype;
begin
  if v_actor is null or not app.can_module_write(p_business, 'memberships') then
    raise exception 'active memberships-module write authorization is required'
      using errcode='42501';
  end if;
  select s.id into v_staff from public.staff s
   where s.business_id=p_business and s.user_id=v_actor and s.active
   order by case when s.role='owner' then 0 else 1 end,s.created_at limit 1 for update;
  if not found then raise exception 'active staff authorization is required' using errcode='42501'; end if;
  if p_status not in ('active','paused','cancel_at_period_end','cancelled') then
    raise exception 'invalid membership status' using errcode='22023';
  end if;
  select * into v_membership from public.memberships m
   where m.id=p_membership and m.business_id=p_business for update;
  if not found then raise exception 'membership does not belong to this business' using errcode='22023'; end if;
  update public.memberships set status=p_status
   where id=p_membership and business_id=p_business returning * into v_membership;
  return jsonb_build_object('status','completed','membership_id',v_membership.id,
    'membership_status',v_membership.status);
end
$$;

create or replace function public.enroll_membership_v41(
  p_business uuid,
  p_client uuid,
  p_plan uuid)
returns json
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare v_actor uuid:=auth.uid(); v_staff uuid; v_result json;
begin
  if v_actor is null or not app.can_module_write(p_business,'memberships')
     or not app.has_perm(p_business,'create_sales') then
    raise exception 'active memberships-module and create-sales authorization is required' using errcode='42501';
  end if;
  select s.id into v_staff from public.staff s
   where s.business_id=p_business and s.user_id=v_actor and s.active
     and 'create_sales'=any(app.role_perms(s.role))
   order by case when s.role='owner' then 0 else 1 end,s.created_at limit 1 for update;
  if not found then raise exception 'active staff authorization is required' using errcode='42501'; end if;
  v_result:=public.enroll_membership(p_business,p_client,p_plan);
  return v_result;
end
$$;

create or replace function public.redeem_gift_card_v41(
  p_business uuid,
  p_code text,
  p_client uuid,
  p_amount integer default null)
returns json
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare v_actor uuid:=auth.uid(); v_staff uuid; v_result json;
begin
  if v_actor is null or not app.can_module_write(p_business,'giftcards')
     or not app.has_perm(p_business,'create_sales') then
    raise exception 'active giftcards-module and create-sales authorization is required' using errcode='42501';
  end if;
  select s.id into v_staff from public.staff s
   where s.business_id=p_business and s.user_id=v_actor and s.active
     and 'create_sales'=any(app.role_perms(s.role))
   order by case when s.role='owner' then 0 else 1 end,s.created_at limit 1 for update;
  if not found then raise exception 'active staff authorization is required' using errcode='42501'; end if;
  v_result:=public.redeem_gift_card(p_business,p_code,p_client,p_amount);
  return v_result;
end
$$;

-- Till lookups return customer identity and balances from SECURITY DEFINER code,
-- so sales permission alone is insufficient: the actor must also retain clients read.
create or replace function public.lookup_client_by_phone(
  p_business uuid,
  p_phone text)
returns json
language plpgsql
stable
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_norm text;
  c public.clients%rowtype;
  lp record;
  v_points integer;
  v_credit integer;
  v_visits integer;
begin
  if not app.has_perm(p_business, 'create_sales')
     or not app.can_module_read(p_business, 'clients') then
    raise exception 'clients read and create-sales authorization is required'
      using errcode = '42501';
  end if;
  v_norm := app.norm_phone(p_phone);
  if v_norm is null then
    return json_build_object('status','invalid',
      'message','Enter the customer''s 8-digit mobile number.');
  end if;
  select * into c from public.clients
   where business_id = p_business and phone_norm = v_norm;
  if not found then
    return json_build_object('status','not_found','phone',v_norm);
  end if;
  select coalesce(sum(points),0) into v_points
    from public.points_ledger where business_id=p_business and client_id=c.id;
  select coalesce(sum(amount_cents),0) into v_credit
    from public.credit_ledger where business_id=p_business and client_id=c.id;
  select count(*) into v_visits
    from public.sales where business_id=p_business and client_id=c.id and counts_as_visit;
  select * into lp from public.loyalty_programs
   where business_id=p_business and active limit 1;
  return json_build_object(
    'status','found','client_id',c.id,'full_name',c.full_name,'phone',c.phone_norm,
    'points',v_points,'credit_cents',v_credit,'visits',v_visits,
    'redeem_points',lp.redeem_points,'reward_credit_cents',lp.reward_credit_cents,
    'can_redeem',(lp.redeem_points is not null and v_points>=lp.redeem_points),
    'points_to_next',greatest(coalesce(lp.redeem_points,0)-v_points,0),
    'member_since',c.created_at);
end
$$;

create or replace function public.record_sale_by_phone(
  p_business uuid,
  p_phone text,
  p_amount_cents integer,
  p_kind text default 'quick_sale',
  p_note text default null,
  p_staff uuid default null,
  p_idem text default null)
returns json
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_norm text;
  c public.clients%rowtype;
  s public.sales%rowtype;
  v_points_before integer;
  v_points_after integer;
  v_earned integer;
begin
  if not app.has_perm(p_business, 'create_sales')
     or not app.can_module_read(p_business, 'clients') then
    raise exception 'clients read and create-sales authorization is required'
      using errcode = '42501';
  end if;
  if p_amount_cents is null or p_amount_cents <= 0 then
    raise exception 'Enter the amount paid.' using errcode = '22023';
  end if;
  if p_kind not in ('service','retail','quick_sale','membership','gift_card','package') then
    raise exception 'unknown sale kind: %',p_kind using errcode = '22023';
  end if;
  v_norm := app.norm_phone(p_phone);
  if v_norm is null then
    raise exception 'Enter a valid 8-digit mobile number.' using errcode = '22023';
  end if;
  select * into c from public.clients
   where business_id=p_business and phone_norm=v_norm;
  if not found then
    raise exception 'No customer with number %. Add them first.',v_norm using errcode = '22023';
  end if;
  if p_idem is not null then
    perform pg_advisory_xact_lock(hashtextextended(
      'v41:till-sale:' || p_business::text || ':' || p_idem, 0));
    select * into s from public.sales
     where business_id=p_business and idem_key=p_idem;
    if found then
      if s.client_id is distinct from c.id
         or s.amount_cents is distinct from p_amount_cents
         or s.kind is distinct from p_kind
         or s.note is distinct from coalesce(p_note,'till: '||v_norm)
         or s.staff_id is distinct from p_staff then
        raise exception 'idempotency key conflicts with another Till sale request'
          using errcode = '23505';
      end if;
      select coalesce(sum(points),0) into v_points_after
        from public.points_ledger where business_id=p_business and client_id=c.id;
      return json_build_object('status','duplicate_ignored','sale_id',s.id,
        'client_id',c.id,'full_name',c.full_name,'points',v_points_after);
    end if;
  end if;
  select coalesce(sum(points),0) into v_points_before
    from public.points_ledger where business_id=p_business and client_id=c.id;
  insert into public.sales (business_id,client_id,kind,amount_cents,note,staff_id,idem_key)
  values (p_business,c.id,p_kind,p_amount_cents,
          coalesce(p_note,'till: '||v_norm),p_staff,p_idem)
  returning * into s;
  select coalesce(sum(points),0) into v_points_after
    from public.points_ledger where business_id=p_business and client_id=c.id;
  v_earned:=v_points_after-v_points_before;
  return json_build_object('status','ok','sale_id',s.id,
    'client_id',c.id,'full_name',c.full_name,
    'amount_cents',s.amount_cents,'kind',s.kind,
    'points_earned',v_earned,'points',v_points_after,
    'counts_as_revenue',s.counts_as_revenue,'counts_as_visit',s.counts_as_visit);
end
$$;

-- Loyalty redemption is a customer-wallet mutation. Legacy v24/v27 entry
-- points checked sales permission but predated the v41 r/rw module override,
-- so a staff role with create_sales could mutate a read-only loyalty module.
alter function public.redeem_points(uuid,uuid,text) rename to redeem_points_v40_internal;
alter function public.redeem_points_v40_internal(uuid,uuid,text) set schema app;
revoke all privileges on function app.redeem_points_v40_internal(uuid,uuid,text)
  from public, anon, authenticated;

create or replace function public.redeem_points(
  p_business uuid,
  p_client uuid,
  p_idempotency_key text)
returns json
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
begin
  if not app.can_module_write(p_business, 'loyalty') then
    raise exception 'loyalty write authorization is required'
      using errcode = '42501';
  end if;
  return app.redeem_points_v40_internal(
    p_business, p_client, p_idempotency_key);
end
$$;

create or replace function public.redeem_reward(
  p_business uuid,
  p_client uuid,
  p_reward uuid,
  p_idempotency_key text default null)
returns json
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
begin
  if not app.can_module_write(p_business, 'loyalty') then
    raise exception 'loyalty write authorization is required'
      using errcode = '42501';
  end if;
  return app.redeem_reward_core(
    p_business, p_client, p_reward, p_idempotency_key,
    null, null, null);
end
$$;

create or replace function public.redeem_reward_at_context(
  p_business uuid,
  p_client uuid,
  p_reward uuid,
  p_idempotency_key text,
  p_branch uuid default null,
  p_service uuid default null,
  p_product uuid default null)
returns json
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
begin
  if not app.can_module_write(p_business, 'loyalty') then
    raise exception 'loyalty write authorization is required'
      using errcode = '42501';
  end if;
  return app.redeem_reward_core(
    p_business, p_client, p_reward, p_idempotency_key,
    p_branch, p_service, p_product);
end
$$;

-- Replace inherited member-wide policies with module-specific read policies.
drop policy if exists consents_select on public.consents;
drop policy if exists consents_insert on public.consents;
drop policy if exists referrals_all on public.referrals;
drop policy if exists refprog_all on public.referral_programs;
drop policy if exists gift_cards_all on public.gift_cards;
drop policy if exists plans_all on public.membership_plans;
drop policy if exists memberships_select on public.memberships;
drop policy if exists memberships_update on public.memberships;
drop policy if exists clients_all on public.clients;
drop policy if exists clients_read on public.clients;
drop policy if exists clients_ins on public.clients;
drop policy if exists clients_upd on public.clients;
drop policy if exists clients_del on public.clients;

create policy clients_v41_read on public.clients for select to authenticated
  using (app.can_module_read(business_id, 'clients'));
create policy consents_v41_read on public.consents for select to authenticated
  using (app.can_module_read(business_id, 'clients'));
create policy referrals_v41_read on public.referrals for select to authenticated
  using (app.can_module_read(business_id, 'referrals'));
create policy referral_programs_v41_read on public.referral_programs for select to authenticated
  using (app.can_module_read(business_id, 'referrals'));
create policy membership_plans_v41_read on public.membership_plans for select to authenticated
  using (app.can_module_read(business_id, 'memberships'));
create policy memberships_v41_read on public.memberships for select to authenticated
  using (app.can_module_read(business_id, 'memberships'));

revoke insert, update, delete, truncate on table public.clients from public, anon, authenticated;
revoke insert, update, delete, truncate on table public.consents from public, anon, authenticated;
revoke insert, update, delete, truncate on table public.referrals from public, anon, authenticated;
revoke insert, update, delete, truncate on table public.referral_programs from public, anon, authenticated;
revoke all privileges on table public.gift_cards from public, anon, authenticated;
revoke insert, update, delete, truncate on table public.membership_plans from public, anon, authenticated;
revoke insert, update, delete, truncate on table public.memberships from public, anon, authenticated;

revoke all privileges on function public.quick_add_client(uuid,text,text,boolean)
  from public, anon, authenticated;
revoke all privileges on function public.issue_gift_card(uuid,integer,uuid,text)
  from public, anon, authenticated;
revoke all privileges on function public.redeem_gift_card(uuid,text,uuid,integer)
  from public, anon, authenticated;
revoke all privileges on function public.enroll_membership(uuid,uuid,uuid)
  from public, anon, authenticated;

revoke all privileges on function public.staff_create_client(uuid,uuid,text,text,text,date,text,boolean,text,text)
  from public, anon, authenticated;
grant execute on function public.staff_create_client(uuid,uuid,text,text,text,date,text,boolean,text,text)
  to authenticated;
revoke all privileges on function public.staff_set_marketing_consent(uuid,uuid,uuid,boolean,text)
  from public, anon, authenticated;
grant execute on function public.staff_set_marketing_consent(uuid,uuid,uuid,boolean,text)
  to authenticated;
revoke all privileges on function public.issue_gift_card(uuid,integer,uuid,text,uuid)
  from public, anon, authenticated;
grant execute on function public.issue_gift_card(uuid,integer,uuid,text,uuid)
  to authenticated;
revoke all privileges on function public.staff_list_gift_cards(uuid,integer)
  from public, anon, authenticated;
grant execute on function public.staff_list_gift_cards(uuid,integer)
  to authenticated;
revoke all privileges on function public.save_referral_program(uuid,boolean,integer,integer)
  from public, anon, authenticated;
grant execute on function public.save_referral_program(uuid,boolean,integer,integer)
  to authenticated;
revoke all privileges on function public.save_membership_plan(uuid,uuid,text,integer,text,integer,numeric,boolean)
  from public, anon, authenticated;
grant execute on function public.save_membership_plan(uuid,uuid,text,integer,text,integer,numeric,boolean)
  to authenticated;
revoke all privileges on function public.set_membership_status(uuid,uuid,text)
  from public, anon, authenticated;
grant execute on function public.set_membership_status(uuid,uuid,text)
  to authenticated;
revoke all privileges on function public.enroll_membership_v41(uuid,uuid,uuid)
  from public, anon, authenticated;
grant execute on function public.enroll_membership_v41(uuid,uuid,uuid)
  to authenticated;
revoke all privileges on function public.redeem_gift_card_v41(uuid,text,uuid,integer)
  from public, anon, authenticated;
grant execute on function public.redeem_gift_card_v41(uuid,text,uuid,integer)
  to authenticated;
revoke all privileges on function public.lookup_client_by_phone(uuid,text)
  from public, anon, authenticated;
grant execute on function public.lookup_client_by_phone(uuid,text)
  to authenticated;
revoke all privileges on function public.record_sale_by_phone(uuid,text,integer,text,text,uuid,text)
  from public, anon, authenticated;
grant execute on function public.record_sale_by_phone(uuid,text,integer,text,text,uuid,text)
  to authenticated;
revoke all privileges on function public.redeem_points(uuid,uuid,text)
  from public, anon, authenticated;
grant execute on function public.redeem_points(uuid,uuid,text)
  to authenticated;
revoke all privileges on function public.redeem_reward(uuid,uuid,uuid,text)
  from public, anon, authenticated;
grant execute on function public.redeem_reward(uuid,uuid,uuid,text)
  to authenticated;
revoke all privileges on function public.redeem_reward_at_context(uuid,uuid,uuid,text,uuid,uuid,uuid)
  from public, anon, authenticated;
grant execute on function public.redeem_reward_at_context(uuid,uuid,uuid,text,uuid,uuid,uuid)
  to authenticated;

commit;
