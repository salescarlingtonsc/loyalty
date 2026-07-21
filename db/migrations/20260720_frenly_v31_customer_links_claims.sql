-- FRENLY v31 - CUSTOMER LINKS, CLAIMS, INVITATIONS, AND UNLINKING
--
-- Local review candidate. Do not apply until the phase release gate is accepted.
-- Customer identity is deliberately independent from staff membership. A link is
-- created only by a confirmed auth email match to exactly one unclaimed client,
-- or by a firm-issued opaque invitation. Names and phone numbers are never used.

begin;

insert into app.platform_feature_flags(feature_key, enabled)
values ('customer_claims', false)
on conflict (feature_key) do nothing;

create table public.customer_links (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete restrict,
  identity_id uuid not null references public.customer_identities(id) on delete restrict,
  auth_user_id uuid not null references auth.users(id) on delete restrict,
  client_id uuid not null,
  state text not null check (state in ('pending', 'verified', 'rejected', 'unlinked')),
  verification_method text not null check (verification_method in ('email_claim', 'firm_invitation')),
  verified_at timestamptz,
  unlinked_at timestamptz,
  unlinked_by_auth_user_id uuid references auth.users(id) on delete restrict,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint customer_links_identity_auth_fk
    foreign key (identity_id, auth_user_id)
    references public.customer_identities(id, auth_user_id) on delete restrict,
  constraint customer_links_client_business_fk
    foreign key (client_id, business_id)
    references public.clients(id, business_id) on delete restrict,
  constraint customer_links_state_time_check check (
    (state = 'verified' and verified_at is not null and unlinked_at is null and unlinked_by_auth_user_id is null)
    or (state = 'unlinked' and verified_at is not null and unlinked_at is not null and unlinked_by_auth_user_id is not null)
    or (state in ('pending', 'rejected') and verified_at is null and unlinked_at is null and unlinked_by_auth_user_id is null)
  ),
  constraint customer_links_id_business_uk unique (id, business_id),
  constraint customer_links_id_business_client_uk unique (id, business_id, client_id),
  constraint customer_links_id_business_identity_uk unique (id, business_id, identity_id)
);

-- The client row is the business-owned relationship. A platform identity can have
-- one active relationship in each firm, enabling a wallet made of separate firm cards.
alter table public.clients
  add constraint clients_business_id_id_uk unique (business_id, id);

alter table public.customer_links
  drop constraint customer_links_client_business_fk,
  add constraint customer_links_client_business_fk
    foreign key (business_id, client_id)
    references public.clients(business_id, id) on delete restrict;

create unique index customer_links_one_verified_identity_per_client_uk
  on public.customer_links (business_id, client_id) where state = 'verified';
create unique index customer_links_one_verified_relationship_per_firm_uk
  on public.customer_links (business_id, identity_id) where state = 'verified';
create index customer_links_identity_state_idx
  on public.customer_links (identity_id, state, created_at desc);
create index customer_links_business_client_state_idx
  on public.customer_links (business_id, client_id, state);

create table public.customer_link_claim_attempts (
  id uuid primary key default gen_random_uuid(),
  identity_id uuid not null references public.customer_identities(id) on delete restrict,
  auth_user_id uuid not null references auth.users(id) on delete restrict,
  business_id uuid references public.businesses(id) on delete restrict,
  link_id uuid,
  operation text not null check (operation in ('email_claim', 'invitation_claim')),
  idempotency_key text not null check (length(btrim(idempotency_key)) >= 8),
  request_hash text not null check (request_hash ~ '^[0-9a-f]{64}$'),
  outcome text not null check (outcome in ('linked', 'not_linked', 'rate_limited')),
  response jsonb not null check (jsonb_typeof(response) = 'object'),
  created_at timestamptz not null default now(),
  constraint customer_link_claim_attempts_identity_auth_fk
    foreign key (identity_id, auth_user_id)
    references public.customer_identities(id, auth_user_id) on delete restrict,
  constraint customer_link_claim_attempts_link_business_fk
    foreign key (link_id, business_id)
    references public.customer_links(id, business_id) on delete restrict,
  constraint customer_link_claim_attempts_link_scope_check check (
    link_id is null or business_id is not null
  ),
  constraint customer_link_claim_attempts_idempotency_uk
    unique (identity_id, operation, idempotency_key)
);
create index customer_link_claim_attempts_rate_idx
  on public.customer_link_claim_attempts (identity_id, operation, created_at desc);

create table public.customer_link_invitations (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete restrict,
  client_id uuid not null,
  issued_by_auth_user_id uuid not null references auth.users(id) on delete restrict,
  token_hash text not null unique check (token_hash ~ '^[0-9a-f]{64}$'),
  recipient_email_hash text not null check (recipient_email_hash ~ '^[0-9a-f]{64}$'),
  state text not null default 'issued' check (state in ('issued', 'claimed', 'revoked')),
  expires_at timestamptz not null,
  claimed_at timestamptz,
  claimed_by_identity_id uuid references public.customer_identities(id) on delete restrict,
  claimed_link_id uuid,
  created_at timestamptz not null default now(),
  constraint customer_link_invitations_client_business_fk
    foreign key (client_id, business_id)
    references public.clients(id, business_id) on delete restrict,
  constraint customer_link_invitations_claimed_link_tenant_fk
    foreign key (claimed_link_id, business_id, client_id)
    references public.customer_links(id, business_id, client_id) on delete restrict,
  constraint customer_link_invitations_expiry_check
    check (expires_at > created_at and expires_at <= created_at + interval '30 days'),
  constraint customer_link_invitations_claim_check check (
    (state = 'claimed' and claimed_at is not null and claimed_by_identity_id is not null and claimed_link_id is not null)
    or (state in ('issued', 'revoked') and claimed_at is null and claimed_by_identity_id is null and claimed_link_id is null)
  )
);
create index customer_link_invitations_client_state_idx
  on public.customer_link_invitations (business_id, client_id, state, expires_at desc);
alter table public.customer_link_invitations
  add constraint customer_link_invitations_id_business_client_uk unique (id, business_id, client_id);

-- Issuance has a durable request hash but never stores the raw invitation token.
create table public.customer_link_invitation_issues (
  id uuid primary key default gen_random_uuid(),
  invitation_id uuid not null unique,
  business_id uuid not null references public.businesses(id) on delete restrict,
  client_id uuid not null,
  issued_by_auth_user_id uuid not null references auth.users(id) on delete restrict,
  idempotency_key text not null check (length(btrim(idempotency_key)) >= 8),
  request_hash text not null check (request_hash ~ '^[0-9a-f]{64}$'),
  created_at timestamptz not null default now(),
  constraint customer_link_invitation_issues_client_business_fk
    foreign key (client_id, business_id)
    references public.clients(id, business_id) on delete restrict,
  constraint customer_link_invitation_issues_invitation_tenant_fk
    foreign key (invitation_id, business_id, client_id)
    references public.customer_link_invitations(id, business_id, client_id) on delete restrict,
  constraint customer_link_invitation_issues_idempotency_uk
    unique (business_id, issued_by_auth_user_id, idempotency_key)
);

create table public.customer_link_audit_events (
  id uuid primary key default gen_random_uuid(),
  identity_id uuid references public.customer_identities(id) on delete restrict,
  actor_auth_user_id uuid not null references auth.users(id) on delete restrict,
  business_id uuid references public.businesses(id) on delete restrict,
  client_id uuid,
  link_id uuid,
  invitation_id uuid,
  event_type text not null check (event_type in (
  'email_claim_linked', 'email_claim_not_linked', 'email_claim_rate_limited',
  'invitation_issued', 'invitation_claim_linked', 'invitation_claim_not_linked',
    'invitation_claim_rate_limited', 'link_unlinked'
  )),
  idempotency_key text not null check (length(btrim(idempotency_key)) >= 8),
  request_hash text not null check (request_hash ~ '^[0-9a-f]{64}$'),
  response jsonb not null check (jsonb_typeof(response) = 'object'),
  created_at timestamptz not null default now(),
  constraint customer_link_audit_events_client_business_fk
    foreign key (client_id, business_id)
    references public.clients(id, business_id) on delete restrict,
  constraint customer_link_audit_events_link_tenant_fk
    foreign key (link_id, business_id, client_id)
    references public.customer_links(id, business_id, client_id) on delete restrict,
  constraint customer_link_audit_events_link_scope_check check (
    link_id is null or (business_id is not null and client_id is not null)
  ),
  constraint customer_link_audit_events_invitation_tenant_fk
    foreign key (invitation_id, business_id, client_id)
    references public.customer_link_invitations(id, business_id, client_id) on delete restrict,
  constraint customer_link_audit_events_invitation_scope_check check (
    invitation_id is null or (business_id is not null and client_id is not null)
  ),
  constraint customer_link_audit_events_idempotency_uk
    unique nulls not distinct (identity_id, actor_auth_user_id, event_type, idempotency_key)
);
create index customer_link_audit_events_identity_time_idx
  on public.customer_link_audit_events (identity_id, created_at desc);

create table public.customer_link_unlink_events (
  id uuid primary key default gen_random_uuid(),
  link_id uuid not null,
  identity_id uuid not null references public.customer_identities(id) on delete restrict,
  actor_auth_user_id uuid not null references auth.users(id) on delete restrict,
  business_id uuid not null references public.businesses(id) on delete restrict,
  client_id uuid not null,
  idempotency_key text not null check (length(btrim(idempotency_key)) >= 8),
  request_hash text not null check (request_hash ~ '^[0-9a-f]{64}$'),
  response jsonb not null check (jsonb_typeof(response) = 'object'),
  created_at timestamptz not null default now(),
  constraint customer_link_unlink_events_client_business_fk
    foreign key (client_id, business_id) references public.clients(id, business_id) on delete restrict,
  constraint customer_link_unlink_events_link_tenant_fk
    foreign key (link_id, business_id, client_id)
    references public.customer_links(id, business_id, client_id) on delete restrict,
  constraint customer_link_unlink_events_idempotency_uk unique (identity_id, idempotency_key)
);

alter table public.customer_links enable row level security;
alter table public.customer_link_claim_attempts enable row level security;
alter table public.customer_link_invitations enable row level security;
alter table public.customer_link_invitation_issues enable row level security;
alter table public.customer_link_audit_events enable row level security;
alter table public.customer_link_unlink_events enable row level security;

-- Links, proofs, issued token hashes, and audit records are deliberately RPC-only.
revoke all privileges on table public.customer_links from public, anon, authenticated;
revoke all privileges on table public.customer_link_claim_attempts from public, anon, authenticated;
revoke all privileges on table public.customer_link_invitations from public, anon, authenticated;
revoke all privileges on table public.customer_link_invitation_issues from public, anon, authenticated;
revoke all privileges on table public.customer_link_audit_events from public, anon, authenticated;
revoke all privileges on table public.customer_link_unlink_events from public, anon, authenticated;

create or replace function app.v31_sha256_hex(p_value text)
returns text
language sql
immutable
set search_path to 'pg_catalog', 'extensions', 'pg_temp'
as $$
  select encode(extensions.digest(convert_to($1, 'UTF8'), 'sha256'), 'hex')
$$;

create or replace function app.v31_current_identity()
returns uuid
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_actor uuid := auth.uid();
  v_identity_id uuid;
begin
  if v_actor is null then
    raise exception 'authenticated customer session required' using errcode = '28000';
  end if;
  select ci.id into v_identity_id
    from public.customer_identities ci
   where ci.auth_user_id = v_actor and ci.status = 'active';
  if v_identity_id is null then
    raise exception 'an independent active customer identity is required' using errcode = '42501';
  end if;
  return v_identity_id;
end;
$$;

create or replace function app.v31_link_immutable_guard()
returns trigger
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_insert_id text := nullif(current_setting('app.customer_link_insert_id', true), '');
  v_transition_id text := nullif(current_setting('app.customer_link_transition_id', true), '');
begin
  if tg_op = 'INSERT' then
    if v_insert_id is distinct from new.id::text or new.state <> 'verified' or new.verified_at is null then
      raise exception 'customer links may only be created by a verified claim route' using errcode = '42501';
    end if;
    return new;
  end if;
  if tg_op = 'DELETE' then
    raise exception 'customer links are retained as relationship evidence' using errcode = '23000';
  end if;
  if v_transition_id is distinct from old.id::text
     or old.state <> 'verified' or new.state <> 'unlinked'
     or (new.id, new.business_id, new.identity_id, new.auth_user_id, new.client_id,
         new.verification_method, new.verified_at, new.created_at)
        is distinct from
        (old.id, old.business_id, old.identity_id, old.auth_user_id, old.client_id,
         old.verification_method, old.verified_at, old.created_at)
     or new.unlinked_at is null or new.unlinked_by_auth_user_id is null then
    raise exception 'customer links may only transition verified -> unlinked through the self-service route'
      using errcode = '23000';
  end if;
  return new;
end;
$$;

create trigger customer_links_immutable_guard
  before insert or update or delete on public.customer_links
  for each row execute function app.v31_link_immutable_guard();

create or replace function app.v31_invitation_guard()
returns trigger
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_claim_id text := nullif(current_setting('app.customer_link_invitation_claim_id', true), '');
begin
  if tg_op = 'DELETE' then
    raise exception 'customer link invitations are retained as audit evidence' using errcode = '23000';
  end if;
  if old.state <> 'issued' or new.state <> 'claimed' or v_claim_id is distinct from old.id::text
     or (new.id, new.business_id, new.client_id, new.issued_by_auth_user_id, new.token_hash,
         new.recipient_email_hash, new.expires_at, new.created_at)
        is distinct from
        (old.id, old.business_id, old.client_id, old.issued_by_auth_user_id, old.token_hash,
         old.recipient_email_hash, old.expires_at, old.created_at)
     or new.claimed_at is null or new.claimed_by_identity_id is null or new.claimed_link_id is null then
    raise exception 'an invitation may only transition issued -> claimed through its token route'
      using errcode = '23000';
  end if;
  return new;
end;
$$;

create trigger customer_link_invitations_transition_guard
  before update or delete on public.customer_link_invitations
  for each row execute function app.v31_invitation_guard();

create or replace function app.v31_evidence_immutable_guard()
returns trigger
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
begin
  raise exception '% is append-only evidence', tg_table_name using errcode = '23000';
end;
$$;

create trigger customer_link_claim_attempts_immutable_guard
  before update or delete on public.customer_link_claim_attempts
  for each row execute function app.v31_evidence_immutable_guard();
create trigger customer_link_invitation_issues_immutable_guard
  before update or delete on public.customer_link_invitation_issues
  for each row execute function app.v31_evidence_immutable_guard();
create trigger customer_link_audit_events_immutable_guard
  before update or delete on public.customer_link_audit_events
  for each row execute function app.v31_evidence_immutable_guard();
create trigger customer_link_unlink_events_immutable_guard
  before update or delete on public.customer_link_unlink_events
  for each row execute function app.v31_evidence_immutable_guard();

create or replace function public.customer_claim_link_by_email(
  p_business_slug text,
  p_idempotency_key text
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_actor uuid := auth.uid();
  v_identity uuid;
  v_slug text := lower(btrim(coalesce(p_business_slug, '')));
  v_email text;
  v_email_confirmed_at timestamptz;
  v_business uuid;
  v_existing public.customer_link_claim_attempts%rowtype;
  v_link_id uuid;
  v_client_id uuid;
  v_candidate_ids uuid[];
  v_candidate_count integer := 0;
  v_request_hash text;
  v_outcome text;
  v_response jsonb;
  v_event_type text;
begin
  if not app.platform_feature_enabled('customer_claims') then
    raise exception 'customer access is unavailable' using errcode = '0A000';
  end if;
  v_identity := app.v31_current_identity();
  if p_idempotency_key is null or length(btrim(p_idempotency_key)) < 8 then
    raise exception 'idempotency key must contain at least 8 characters' using errcode = '22023';
  end if;
  p_idempotency_key := btrim(p_idempotency_key);
  v_request_hash := app.v31_sha256_hex('v31.email_claim:' || v_slug);
  perform pg_advisory_xact_lock(hashtextextended(
    'v31:email-claim:' || v_identity::text || ':' || p_idempotency_key, 0
  ));

  select * into v_existing
    from public.customer_link_claim_attempts a
   where a.identity_id = v_identity and a.operation = 'email_claim'
     and a.idempotency_key = p_idempotency_key;
  if found then
    if v_existing.request_hash is distinct from v_request_hash then
      raise exception 'idempotency key was already used for another claim request' using errcode = '22023';
    end if;
    return v_existing.response;
  end if;

  -- Exactly one normalized candidate is required. Duplicate or ambiguous legacy
  -- records receive the same generic response as an unavailable relationship.
  if (select count(*) from public.customer_link_claim_attempts a
       where a.identity_id = v_identity and a.operation = 'email_claim'
         and a.created_at >= now() - interval '15 minutes'
         and a.outcome <> 'rate_limited') >= 5 then
    v_outcome := 'rate_limited';
    v_response := jsonb_build_object('outcome', 'try_later', 'retry_after_seconds', 900);
    v_event_type := 'email_claim_rate_limited';
  else
    select u.email, u.email_confirmed_at into v_email, v_email_confirmed_at
      from auth.users u where u.id = v_actor for share;
    select b.id into v_business from public.businesses b where b.slug = v_slug for share;

    if v_email_confirmed_at is null or nullif(btrim(v_email), '') is null or v_business is null then
      v_outcome := 'not_linked';
      v_response := jsonb_build_object('outcome', 'no_link_created');
      v_event_type := 'email_claim_not_linked';
    else
      perform pg_advisory_xact_lock(hashtextextended('v31:business-link:' || v_business::text, 0));
      select l.id, l.client_id into v_link_id, v_client_id from public.customer_links l
       where l.identity_id = v_identity and l.business_id = v_business and l.state = 'verified'
       for update;
      if found then
        v_outcome := 'linked';
        v_response := jsonb_build_object('outcome', 'linked');
        v_event_type := 'email_claim_linked';
      else
        select coalesce(array_agg(c.id order by c.id), '{}'::uuid[]), count(*)::integer
          into v_candidate_ids, v_candidate_count
          from public.clients c
         where c.business_id = v_business
           and lower(btrim(coalesce(c.email, ''))) = lower(btrim(v_email))
           and nullif(btrim(c.email), '') is not null
           and not exists (
             select 1 from public.customer_links linked
              where linked.client_id = c.id and linked.state = 'verified'
           );
        if v_candidate_count = 1 then
          v_link_id := gen_random_uuid();
          v_client_id := v_candidate_ids[1];
          perform set_config('app.customer_link_insert_id', v_link_id::text, true);
          insert into public.customer_links (
            id, business_id, identity_id, auth_user_id, client_id, state,
            verification_method, verified_at
          ) values (
            v_link_id, v_business, v_identity, v_actor, v_candidate_ids[1], 'verified',
            'email_claim', now()
          );
          perform set_config('app.customer_link_insert_id', '', true);
          v_outcome := 'linked';
          v_response := jsonb_build_object('outcome', 'linked');
          v_event_type := 'email_claim_linked';
        else
          v_outcome := 'not_linked';
          v_response := jsonb_build_object('outcome', 'no_link_created');
          v_event_type := 'email_claim_not_linked';
        end if;
      end if;
    end if;
  end if;

  insert into public.customer_link_claim_attempts (
    identity_id, auth_user_id, business_id, link_id, operation, idempotency_key,
    request_hash, outcome, response
  ) values (
    v_identity, v_actor, v_business, v_link_id, 'email_claim', p_idempotency_key,
    v_request_hash, v_outcome, v_response
  );
  insert into public.customer_link_audit_events (
    identity_id, actor_auth_user_id, business_id, client_id, link_id, event_type,
    idempotency_key, request_hash, response
  ) values (
    v_identity, v_actor, v_business, v_client_id, v_link_id, v_event_type,
    p_idempotency_key, v_request_hash, v_response
  );
  return v_response;
end;
$$;

create or replace function public.customer_issue_link_invitation(
  p_business uuid,
  p_client uuid,
  p_idempotency_key text,
  p_expires_in_minutes integer default 10080
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_actor uuid := auth.uid();
  v_request_hash text;
  v_existing public.customer_link_invitation_issues%rowtype;
  v_invitation_id uuid := gen_random_uuid();
  v_token text;
  v_expires_at timestamptz;
  v_recipient_email text;
begin
  if v_actor is null then raise exception 'authenticated staff session required' using errcode = '28000'; end if;
  if not app.platform_feature_enabled('customer_claims') then
    raise exception 'customer access is unavailable' using errcode = '0A000';
  end if;
  if p_idempotency_key is null or length(btrim(p_idempotency_key)) < 8 then
    raise exception 'idempotency key must contain at least 8 characters' using errcode = '22023';
  end if;
  if p_expires_in_minutes is null or p_expires_in_minutes < 5 or p_expires_in_minutes > 43200 then
    raise exception 'invitation expiry must be between 5 minutes and 30 days' using errcode = '22023';
  end if;
  p_idempotency_key := btrim(p_idempotency_key);
  v_request_hash := app.v31_sha256_hex(
    'v31.invitation_issue:' || p_business::text || ':' || p_client::text || ':' || p_expires_in_minutes::text
  );
  perform pg_advisory_xact_lock(hashtextextended(
    'v31:invitation-issue:' || p_business::text || ':' || v_actor::text || ':' || p_idempotency_key, 0
  ));
  if not app.is_salon_owner(p_business) then
    raise exception 'owner only' using errcode = '42501';
  end if;
  perform 1 from public.businesses b where b.id = p_business for share;
  select nullif(lower(btrim(c.email)), '') into v_recipient_email
    from public.clients c
   where c.id = p_client and c.business_id = p_business
   for share;
  if not found then raise exception 'client does not belong to this business' using errcode = '23503'; end if;
  if v_recipient_email is null then
    raise exception 'customer invitation requires an email on the client record' using errcode = '22023';
  end if;

  select * into v_existing from public.customer_link_invitation_issues i
   where i.business_id = p_business and i.issued_by_auth_user_id = v_actor
     and i.idempotency_key = p_idempotency_key;
  if found then
    if v_existing.request_hash is distinct from v_request_hash then
      raise exception 'idempotency key was already used for another invitation request' using errcode = '22023';
    end if;
    -- The raw secret is purposefully unavailable after its initial response.
    return jsonb_build_object(
      'outcome', 'invitation_already_issued', 'invitation_id', v_existing.invitation_id,
      'token', null
    );
  end if;
  perform pg_advisory_xact_lock(hashtextextended(
    'v31:invitation-issue-rate:' || p_business::text || ':' || v_actor::text, 0
  ));
  if (
    select count(*) from public.customer_link_invitation_issues i
     where i.business_id = p_business
       and i.issued_by_auth_user_id = v_actor
       and i.created_at >= now() - interval '15 minutes'
  ) >= 20 then
    raise exception 'try later' using errcode = '54000';
  end if;

  v_expires_at := now() + make_interval(mins => p_expires_in_minutes);
  v_token := encode(extensions.gen_random_bytes(32), 'hex');
  insert into public.customer_link_invitations (
    id, business_id, client_id, issued_by_auth_user_id, token_hash,
    recipient_email_hash, expires_at
  ) values (
    v_invitation_id, p_business, p_client, v_actor, app.v31_sha256_hex(v_token),
    app.v31_sha256_hex('v31.invitation-email:' || v_recipient_email), v_expires_at
  );
  insert into public.customer_link_invitation_issues (
    invitation_id, business_id, client_id, issued_by_auth_user_id, idempotency_key, request_hash
  ) values (
    v_invitation_id, p_business, p_client, v_actor, p_idempotency_key, v_request_hash
  );
  insert into public.customer_link_audit_events (
    actor_auth_user_id, business_id, client_id, invitation_id, event_type,
    idempotency_key, request_hash, response
  ) values (
    v_actor, p_business, p_client, v_invitation_id, 'invitation_issued',
    p_idempotency_key, v_request_hash,
    jsonb_build_object('outcome', 'invitation_issued', 'invitation_id', v_invitation_id, 'expires_at', v_expires_at)
  );
  return jsonb_build_object(
    'outcome', 'invitation_issued', 'invitation_id', v_invitation_id,
    'token', v_token, 'expires_at', v_expires_at
  );
end;
$$;

create or replace function public.customer_claim_link_invitation(
  p_token text,
  p_idempotency_key text
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_actor uuid := auth.uid();
  v_identity uuid;
  v_token_hash text := app.v31_sha256_hex(coalesce(p_token, ''));
  v_request_hash text := app.v31_sha256_hex('v31.invitation_claim:' || coalesce(p_token, ''));
  v_existing public.customer_link_claim_attempts%rowtype;
  v_invite public.customer_link_invitations%rowtype;
  v_link_id uuid;
  v_outcome text;
  v_response jsonb;
  v_event_type text;
  v_auth_email text;
  v_email_confirmed_at timestamptz;
begin
  if not app.platform_feature_enabled('customer_claims') then
    raise exception 'customer access is unavailable' using errcode = '0A000';
  end if;
  v_identity := app.v31_current_identity();
  if p_idempotency_key is null or length(btrim(p_idempotency_key)) < 8 then
    raise exception 'idempotency key must contain at least 8 characters' using errcode = '22023';
  end if;
  p_idempotency_key := btrim(p_idempotency_key);
  perform pg_advisory_xact_lock(hashtextextended(
    'v31:invitation-claim:' || v_identity::text || ':' || p_idempotency_key, 0
  ));
  select * into v_existing from public.customer_link_claim_attempts a
   where a.identity_id = v_identity and a.operation = 'invitation_claim'
     and a.idempotency_key = p_idempotency_key;
  if found then
    if v_existing.request_hash is distinct from v_request_hash then
      raise exception 'idempotency key was already used for another invitation claim' using errcode = '22023';
    end if;
    return v_existing.response;
  end if;

  if (select count(*) from public.customer_link_claim_attempts a
       where a.identity_id = v_identity and a.operation = 'invitation_claim'
         and a.created_at >= now() - interval '15 minutes'
         and a.outcome <> 'rate_limited') >= 5 then
    v_outcome := 'rate_limited';
    v_response := jsonb_build_object('outcome', 'try_later', 'retry_after_seconds', 900);
    v_event_type := 'invitation_claim_rate_limited';
  else
    select lower(btrim(u.email)), u.email_confirmed_at
      into v_auth_email, v_email_confirmed_at
      from auth.users u where u.id = v_actor for share;
    select * into v_invite from public.customer_link_invitations i
     where i.token_hash = v_token_hash for update;
    if found then
      perform pg_advisory_xact_lock(hashtextextended('v31:business-link:' || v_invite.business_id::text, 0));
      if v_invite.state = 'claimed' and v_invite.claimed_by_identity_id = v_identity then
        v_link_id := v_invite.claimed_link_id;
        v_outcome := 'linked';
        v_response := jsonb_build_object('outcome', 'linked');
        v_event_type := 'invitation_claim_linked';
      elsif v_invite.state = 'issued' and v_invite.expires_at > now()
        and v_email_confirmed_at is not null
        and v_invite.recipient_email_hash = app.v31_sha256_hex(
          'v31.invitation-email:' || coalesce(v_auth_email, '')
        )
        and not exists (
          select 1 from public.customer_links l
           where l.identity_id = v_identity and l.business_id = v_invite.business_id and l.state = 'verified'
        )
        and not exists (
          select 1 from public.customer_links l
           where l.client_id = v_invite.client_id and l.state = 'verified'
        ) then
        v_link_id := gen_random_uuid();
        perform set_config('app.customer_link_insert_id', v_link_id::text, true);
        insert into public.customer_links (
          id, business_id, identity_id, auth_user_id, client_id, state,
          verification_method, verified_at
        ) values (
          v_link_id, v_invite.business_id, v_identity, v_actor, v_invite.client_id,
          'verified', 'firm_invitation', now()
        );
        perform set_config('app.customer_link_insert_id', '', true);
        perform set_config('app.customer_link_invitation_claim_id', v_invite.id::text, true);
        update public.customer_link_invitations
           set state = 'claimed', claimed_at = now(), claimed_by_identity_id = v_identity,
               claimed_link_id = v_link_id
         where id = v_invite.id;
        perform set_config('app.customer_link_invitation_claim_id', '', true);
        v_outcome := 'linked';
        v_response := jsonb_build_object('outcome', 'linked');
        v_event_type := 'invitation_claim_linked';
      else
        v_outcome := 'not_linked';
        v_response := jsonb_build_object('outcome', 'no_link_created');
        v_event_type := 'invitation_claim_not_linked';
      end if;
    else
      v_outcome := 'not_linked';
      v_response := jsonb_build_object('outcome', 'no_link_created');
      v_event_type := 'invitation_claim_not_linked';
    end if;
  end if;

  insert into public.customer_link_claim_attempts (
    identity_id, auth_user_id, business_id, link_id, operation, idempotency_key,
    request_hash, outcome, response
  ) values (
    v_identity, v_actor, v_invite.business_id, v_link_id, 'invitation_claim',
    p_idempotency_key, v_request_hash, v_outcome, v_response
  );
  insert into public.customer_link_audit_events (
    identity_id, actor_auth_user_id, business_id, client_id, link_id, invitation_id,
    event_type, idempotency_key, request_hash, response
  ) values (
    v_identity, v_actor, v_invite.business_id, v_invite.client_id, v_link_id, v_invite.id,
    v_event_type, p_idempotency_key, v_request_hash, v_response
  );
  return v_response;
end;
$$;

create or replace function public.customer_unlink_business_link(
  p_business_slug text,
  p_idempotency_key text
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_actor uuid := auth.uid();
  v_identity uuid;
  v_slug text := lower(btrim(coalesce(p_business_slug, '')));
  v_business uuid;
  v_link public.customer_links%rowtype;
  v_request_hash text;
  v_existing public.customer_link_audit_events%rowtype;
  v_response jsonb;
begin
  if not app.platform_feature_enabled('customer_claims') then
    raise exception 'customer access is unavailable' using errcode = '0A000';
  end if;
  v_identity := app.v31_current_identity();
  if p_idempotency_key is null or length(btrim(p_idempotency_key)) < 8 then
    raise exception 'idempotency key must contain at least 8 characters' using errcode = '22023';
  end if;
  p_idempotency_key := btrim(p_idempotency_key);
  v_request_hash := app.v31_sha256_hex('v31.unlink:' || v_slug);
  perform pg_advisory_xact_lock(hashtextextended(
    'v31:unlink:' || v_identity::text || ':' || p_idempotency_key, 0
  ));
  select * into v_existing from public.customer_link_audit_events a
   where a.identity_id = v_identity and a.actor_auth_user_id = v_actor
     and a.event_type = 'link_unlinked' and a.idempotency_key = p_idempotency_key;
  if found then
    if v_existing.request_hash is distinct from v_request_hash then
      raise exception 'idempotency key was already used for another unlink request' using errcode = '22023';
    end if;
    return v_existing.response;
  end if;
  perform pg_advisory_xact_lock(hashtextextended(
    'v31:unlink-rate:' || v_identity::text, 0
  ));
  if (
    select count(*) from public.customer_link_audit_events a
     where a.identity_id = v_identity
       and a.actor_auth_user_id = v_actor
       and a.event_type = 'link_unlinked'
       and a.created_at >= now() - interval '15 minutes'
  ) >= 10 then
    raise exception 'try later' using errcode = '54000';
  end if;

  select b.id into v_business from public.businesses b where b.slug = v_slug for share;
  if v_business is not null then
    select * into v_link from public.customer_links l
     where l.identity_id = v_identity and l.business_id = v_business and l.state = 'verified'
     for update;
  end if;
  if found then
    perform set_config('app.customer_link_transition_id', v_link.id::text, true);
    update public.customer_links
       set state = 'unlinked', unlinked_at = now(), unlinked_by_auth_user_id = v_actor,
           updated_at = now()
     where id = v_link.id;
    perform set_config('app.customer_link_transition_id', '', true);
    v_response := jsonb_build_object('outcome', 'unlinked');
  else
    v_response := jsonb_build_object('outcome', 'already_unlinked');
  end if;
  insert into public.customer_link_audit_events (
    identity_id, actor_auth_user_id, business_id, client_id, link_id, event_type,
    idempotency_key, request_hash, response
  ) values (
    v_identity, v_actor, v_business, v_link.client_id, v_link.id, 'link_unlinked',
    p_idempotency_key, v_request_hash, v_response
  );
  if v_link.id is not null then
    insert into public.customer_link_unlink_events (
      link_id, identity_id, actor_auth_user_id, business_id, client_id,
      idempotency_key, request_hash, response
    ) values (
      v_link.id, v_identity, v_actor, v_business, v_link.client_id,
      p_idempotency_key, v_request_hash, v_response
    );
  end if;
  return v_response;
end;
$$;

revoke all on function app.v31_sha256_hex(text) from public, anon, authenticated;
revoke all on function app.v31_current_identity() from public, anon, authenticated;
revoke all on function app.v31_link_immutable_guard() from public, anon, authenticated;
revoke all on function app.v31_invitation_guard() from public, anon, authenticated;
revoke all on function app.v31_evidence_immutable_guard() from public, anon, authenticated;
revoke all on function public.customer_claim_link_by_email(text, text) from public, anon, authenticated;
revoke all on function public.customer_issue_link_invitation(uuid, uuid, text, integer) from public, anon, authenticated;
revoke all on function public.customer_claim_link_invitation(text, text) from public, anon, authenticated;
revoke all on function public.customer_unlink_business_link(text, text) from public, anon, authenticated;
grant execute on function public.customer_claim_link_by_email(text, text) to authenticated;
grant execute on function public.customer_issue_link_invitation(uuid, uuid, text, integer) to authenticated;
grant execute on function public.customer_claim_link_invitation(text, text) to authenticated;
grant execute on function public.customer_unlink_business_link(text, text) to authenticated;

commit;
