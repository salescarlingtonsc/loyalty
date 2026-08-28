-- ============================================================================
-- nestly_v574 — RETENTION CONTROL PLANE + CONSENT CAPTURE
--
-- Owner rulings 2026-08-28, third wave. Retention stays globally OFF throughout:
-- this migration grants nothing, arms nothing, and sends nothing.
--
-- Three things:
--   A. a CUSTOMER-facing writer for business-scoped WhatsApp marketing consent
--      (v572 requires the evidence; until now nothing could create it)
--   B. a PLATFORM hold — a superadmin emergency stop layered OVER the tenant's
--      own campaign switch, never fused into it
--   C. the proactive APPOINTMENT lane brought under the same canonical
--      business-operational gate, with transactional intent
--
-- ===========================================================================
-- A. WHY THE CUSTOMER WRITES THIS AND STAFF CANNOT
-- ===========================================================================
-- Owner ruling: "Do NOT allow staff to silently manufacture marketing consent
-- on behalf of a customer." So the writer resolves the acting customer from
-- auth.uid() and will not accept a client id from its caller. A staff member
-- calling it authenticates as themselves, has no customer identity, and is
-- refused — they cannot even name the customer they would be consenting for.
--
-- The business is resolved through customer_links state='verified'. An
-- unverified link is not proof that this person owns that client row, and
-- consent recorded against the wrong client is worse than no consent.
--
-- Consent is per (business, channel, purpose). Nothing here lets a grant for
-- one business, one channel, or one purpose leak into another: every row names
-- all three, and the resolver added in v572 matches on all three.
--
-- ===========================================================================
-- B. HOLD IS A LAYER, NOT A SWITCH
-- ===========================================================================
-- bringback_campaigns_v361.active IS the merchant's own preference, set by
-- business_set_bringback_paused_v361 under a tenant-owner guard. A superadmin
-- writing that column would be indistinguishable from the owner pausing it, and
-- the owner's next unpause would silently release a compliance hold.
--
-- So the hold lives in its own table, exactly as platform_module_overrides_v94
-- sits above businesses.enabled_modules. Effective state is
--     tenant active  AND  NOT platform held
-- and releasing a hold restores whatever the merchant had chosen, because their
-- column was never touched.
--
-- Write mechanics follow platform_set_capability_grant_v518: the domain-scoped
-- app.v89_platform_can('automation','rw') guard rather than the blunt
-- is_super_admin(), optimistic concurrency on a version, and a row in the
-- shared audit_log naming the PLATFORM ADMINISTRATOR as actor. The audit never
-- pretends the tenant did this.
--
-- (audit_log's jsonb column is `detail`. `meta` raises 42703 and rolls back the
-- whole RPC — it has caught four separate migrations in this repo.)
--
-- ===========================================================================
-- C. TRANSACTIONAL INTENT IS NOT MARKETING INTENT
-- ===========================================================================
-- The appointment lane is proactive, so it needs the business-operational gate
-- the retention lane got in v572 — a firm whose workspace is closed or paused
-- must not be sending anything at customers. But it is TRANSACTIONAL: a
-- customer who booked an appointment is owed their confirmation.
--
-- app.business_may_initiate_comms_v572 already draws that line: is_synthetic
-- and business_workspace_open_v94 apply to every intent, while the is_demo
-- refusal is scoped to marketing only. So a demo firm keeps demonstrating
-- appointment reminders — which is the point of a demo — and still cannot run
-- marketing at real handsets. Nothing about C6 human support changes.
-- ============================================================================

begin;

-- ---------------------------------------------------------------------------
-- A1. The customer's own consent writer
-- ---------------------------------------------------------------------------
-- SECURITY DEFINER, granted to `authenticated`, but the identity it acts on is
-- always auth.uid()'s — never a parameter. That is what makes it impossible for
-- staff to use: they have no customer_identities row.

-- Replay safety belongs in the database, not only in a lock: without this a
-- double-tapped switch appends two rows saying the same thing.
create unique index if not exists consents_v574_idem_uk
  on public.consents(business_id, client_id, idempotency_key)
  where idempotency_key is not null;

create or replace function public.customer_set_whatsapp_marketing_consent_v574(
  p_business uuid,
  p_opted_in boolean,
  p_idempotency_key text default null
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $fn$
declare
  v_actor uuid := auth.uid();
  v_identity uuid;
  v_client uuid;
  v_biz_name text;
  v_action text;
  v_privacy app.customer_legal_documents%rowtype;
  v_scope constant text := 'v574-business-whatsapp-marketing-v1';
  v_idem text := nullif(btrim(coalesce(p_idempotency_key, '')), '');
  v_existing public.consents%rowtype;
begin
  if v_actor is null then
    raise exception 'sign in required' using errcode = '42501';
  end if;
  if p_business is null or p_opted_in is null then
    raise exception 'business and choice are required' using errcode = '22023';
  end if;

  -- The acting CUSTOMER. A staff member has no row here, so this is where a
  -- staff-manufactured consent dies.
  select ci.id into v_identity
    from public.customer_identities ci
   where ci.auth_user_id = v_actor and ci.status = 'active';
  if v_identity is null then
    raise exception 'only a customer may set their own messaging permission'
      using errcode = '42501';
  end if;

  -- The business must be one this customer has PROVEN they belong to. An
  -- unverified link is not proof of ownership of that client row.
  select l.client_id into v_client
    from public.customer_links l
   where l.identity_id = v_identity
     and l.business_id = p_business
     and l.state = 'verified'
   limit 1;
  if v_client is null then
    return jsonb_build_object('status','refused','reason','not_linked_to_business');
  end if;

  select b.name into v_biz_name from public.businesses b where b.id = p_business;

  v_action := case when p_opted_in then 'granted' else 'withdrawn' end;

  -- The notice is read SERVER-SIDE and pinned. It is deliberately not a
  -- parameter: evidence the caller can choose is not evidence. Copying the v92
  -- doctrine, publishing a new privacy notice HALTS capture rather than
  -- silently recording consent against wording nobody agreed to.
  select * into v_privacy from app.customer_legal_documents d
   where d.document_key = 'privacy' and d.active
   for share;
  if not found
     or v_privacy.document_version <> '2026-08-10'
     or v_privacy.document_sha256 <> '960434af7919e5401b3587111eb746fbba41f739edacd74cb5aeeca0402c224f' then
    raise exception 'the consent notice has changed and this capture path must be revised'
      using errcode = '0A000';
  end if;

  -- Replay: the same key returns the original decision instead of appending a
  -- second identical row. A key reused for the OPPOSITE decision is a client
  -- bug, and is refused rather than silently resolved.
  if v_idem is not null then
    perform pg_advisory_xact_lock(
      hashtextextended('v574:wa-consent:' || v_client::text || ':' || v_idem, 0));
    select * into v_existing from public.consents
     where business_id = p_business and client_id = v_client and idempotency_key = v_idem;
    if found then
      if v_existing.action <> v_action then
        raise exception 'this idempotency key already recorded the opposite choice'
          using errcode = '23505';
      end if;
      return jsonb_build_object('status','ok','duplicate',true,
        'business_id', p_business, 'business_name', v_biz_name,
        'opted_in', p_opted_in,
        'state', app.whatsapp_marketing_consent_v572(p_business, v_client));
    end if;
  end if;

  -- Append. Never update: public.consents is append-only (v572 trigger), so a
  -- withdrawal is a NEW row that outranks the grant by created_at, and the
  -- whole history stays readable.
  insert into public.consents(
    business_id, client_id, channel, purpose, action, source, actor,
    scope_version, notice_version, notice_sha256, request_hash, idempotency_key)
  values (
    p_business, v_client, 'whatsapp', 'marketing', v_action,
    'customer_wallet_whatsapp_v574', v_actor,
    v_scope, v_privacy.document_version, v_privacy.document_sha256,
    app.v31_sha256_hex('v574.wa-marketing:' || p_business::text || ':' || v_client::text
      || ':' || p_opted_in::text || ':' || v_privacy.document_sha256
      || ':' || v_scope || ':' || coalesce(v_idem, 'no-idem')),
    v_idem);

  -- A customer ticking their own WhatsApp switch is a stronger act than the
  -- staff-side PDPA flag, and v572 checks that coarse flag BEFORE this one. If
  -- it were left false the customer would opt in and still be suppressed as
  -- 'consent_missing' — a dead end they could never escape. So a GRANT raises
  -- it. A withdrawal deliberately does not clear it: that flag also covers
  -- email and SMS, and this switch speaks only for WhatsApp.
  if p_opted_in then
    update public.clients
       set marketing_consent = true
     where id = v_client and business_id = p_business
       and coalesce(marketing_consent, false) = false;
  end if;

  return jsonb_build_object(
    'status','ok',
    'business_id', p_business,
    'business_name', v_biz_name,
    'channel','whatsapp', 'purpose','marketing',
    'opted_in', p_opted_in,
    'state', app.whatsapp_marketing_consent_v572(p_business, v_client));
end
$fn$;

-- The five-argument first cut is dropped, not left beside this one: both were
-- callable as (uuid, boolean, text) through their defaults, and two candidates
-- for one call is the PGRST203 ambiguity that has bitten this repo before.
drop function if exists public.customer_set_whatsapp_marketing_consent_v574(uuid, boolean, text, text, text);

revoke all on function public.customer_set_whatsapp_marketing_consent_v574(uuid, boolean, text)
  from public, anon;
grant execute on function public.customer_set_whatsapp_marketing_consent_v574(uuid, boolean, text)
  to authenticated;

comment on function public.customer_set_whatsapp_marketing_consent_v574(uuid, boolean, text) is
  'v574 the ONLY writer of WhatsApp marketing consent. Acts solely on auth.uid()''s own customer identity and a verified link, so staff cannot manufacture consent for someone else: a staff member has no customer_identities row and is refused. Appends to the append-only public.consents; a withdrawal is a new row, never an edit.';

-- A2. What the customer sees: one row per business they belong to.
create or replace function public.customer_get_messaging_permissions_v574()
returns jsonb
language plpgsql
stable
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $fn$
declare
  v_actor uuid := auth.uid();
  v_identity uuid;
  v_rows jsonb;
begin
  if v_actor is null then
    raise exception 'sign in required' using errcode = '42501';
  end if;
  select ci.id into v_identity from public.customer_identities ci
   where ci.auth_user_id = v_actor and ci.status = 'active';
  if v_identity is null then
    return '[]'::jsonb;
  end if;

  select coalesce(jsonb_agg(entry order by entry->>'business_name'), '[]'::jsonb)
    into v_rows
  from (
    select jsonb_build_object(
      'business_id', b.id,
      'business_name', b.name,
      'whatsapp_marketing', app.whatsapp_marketing_consent_v572(b.id, l.client_id)
    ) as entry
    from public.customer_links l
    join public.businesses b on b.id = l.business_id
   where l.identity_id = v_identity and l.state = 'verified'
  ) rows;

  return v_rows;
end
$fn$;

revoke all on function public.customer_get_messaging_permissions_v574() from public, anon;
grant execute on function public.customer_get_messaging_permissions_v574() to authenticated;

-- A3. Staff may LOOK, never TOUCH. Read-only, and it returns a state, not a
-- control: there is deliberately no staff-side setter anywhere in this file.
create or replace function public.staff_get_client_messaging_permission_v574(
  p_business uuid,
  p_client uuid
)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $fn$
declare v_state jsonb;
begin
  if not app.can_module_read(p_business, 'clients') then
    raise exception 'customer read access required' using errcode = '42501';
  end if;
  if not exists (select 1 from public.clients c
                  where c.id = p_client and c.business_id = p_business) then
    raise exception 'customer not found in this business' using errcode = '42704';
  end if;

  v_state := app.whatsapp_marketing_consent_v572(p_business, p_client);

  -- Deliberately narrow: whether they opted in, and when. No actor, no notice
  -- digest, no evidence id — staff need the answer, not the paperwork.
  return jsonb_build_object(
    'channel','whatsapp', 'purpose','marketing',
    'opted_in', coalesce((v_state->>'allowed')::boolean, false),
    'decided_at', v_state->>'decided_at',
    'source', v_state->>'source',
    'settable_by_staff', false);
end
$fn$;

revoke all on function public.staff_get_client_messaging_permission_v574(uuid, uuid)
  from public, anon;
grant execute on function public.staff_get_client_messaging_permission_v574(uuid, uuid)
  to authenticated;

-- ---------------------------------------------------------------------------
-- B1. The platform hold table
-- ---------------------------------------------------------------------------
-- campaign_id NULL = the business's whole retention lane. A row is kept after
-- release (held=false) so the history of who held what, and why, survives.

create table if not exists public.platform_retention_holds_v574(
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  campaign_id uuid references public.bringback_campaigns_v361(id) on delete cascade,
  held boolean not null default true,
  reason text not null check (char_length(btrim(reason)) between 3 and 1000),
  version bigint not null default 1,
  placed_by uuid references auth.users(id),
  placed_at timestamptz not null default now(),
  released_by uuid references auth.users(id),
  released_at timestamptz,
  updated_at timestamptz not null default now()
);

comment on table public.platform_retention_holds_v574 is
  'v574 Peekaa-side emergency stop for a tenant''s proactive retention lane. Layered OVER bringback_campaigns_v361.active, never fused into it: effective = tenant active AND NOT platform held, so releasing a hold restores whatever the merchant had chosen. campaign_id NULL holds the whole business lane.';

create unique index if not exists platform_retention_holds_v574_campaign_uk
  on public.platform_retention_holds_v574(business_id, campaign_id)
  where campaign_id is not null;
create unique index if not exists platform_retention_holds_v574_business_uk
  on public.platform_retention_holds_v574(business_id)
  where campaign_id is null;

alter table public.platform_retention_holds_v574 enable row level security;
revoke all privileges on table public.platform_retention_holds_v574
  from public, anon, authenticated;

-- A tenant may SEE that it is held (and why) — a silent stop is worse than an
-- explained one — but may never write it.
drop policy if exists platform_retention_holds_v574_read on public.platform_retention_holds_v574;
create policy platform_retention_holds_v574_read
  on public.platform_retention_holds_v574 for select
  using (app.is_super_admin() or app.can_module_read(business_id, 'loyalty'));
grant select on public.platform_retention_holds_v574 to authenticated;

-- B2. The resolver
create or replace function app.retention_platform_hold_v574(
  p_business uuid,
  p_campaign uuid default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $fn$
declare v_row public.platform_retention_holds_v574%rowtype;
begin
  -- A business-wide hold outranks anything campaign-specific.
  select * into v_row from public.platform_retention_holds_v574
   where business_id = p_business and campaign_id is null and held
   limit 1;
  if found then
    return jsonb_build_object('held', true, 'scope', 'business',
      'reason', v_row.reason, 'since', v_row.placed_at);
  end if;

  if p_campaign is not null then
    select * into v_row from public.platform_retention_holds_v574
     where business_id = p_business and campaign_id = p_campaign and held
     limit 1;
    if found then
      return jsonb_build_object('held', true, 'scope', 'campaign',
        'reason', v_row.reason, 'since', v_row.placed_at);
    end if;
  end if;

  return jsonb_build_object('held', false);
end
$fn$;

revoke all on function app.retention_platform_hold_v574(uuid, uuid)
  from public, anon, authenticated;
grant execute on function app.retention_platform_hold_v574(uuid, uuid) to service_role;

-- B3. The platform writer
create or replace function public.platform_set_retention_hold_v574(
  p_business uuid,
  p_campaign uuid,
  p_held boolean,
  p_reason text,
  p_expected_version bigint default 0
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $fn$
declare
  v_actor uuid := auth.uid();
  v_current public.platform_retention_holds_v574%rowtype;
  v_version bigint;
begin
  if not app.v89_platform_can('automation', 'rw') then
    raise exception 'platform automation write access required' using errcode = '42501';
  end if;
  if p_held is null then
    raise exception 'hold state is required' using errcode = '22023';
  end if;
  if char_length(btrim(coalesce(p_reason, ''))) < 3 then
    -- A hold without a stated reason is an outage nobody can explain later.
    raise exception 'a hold requires a reason' using errcode = '22023';
  end if;
  if not exists (select 1 from public.businesses where id = p_business) then
    raise exception 'unknown business' using errcode = '22023';
  end if;
  if p_campaign is not null
     and not exists (select 1 from public.bringback_campaigns_v361
                      where id = p_campaign and business_id = p_business) then
    raise exception 'campaign does not belong to this business' using errcode = '22023';
  end if;

  select * into v_current from public.platform_retention_holds_v574
   where business_id = p_business
     and campaign_id is not distinct from p_campaign
   for update;

  if coalesce(p_expected_version, 0) <> coalesce(v_current.version, 0) then
    raise exception 'retention hold changed since it was read' using errcode = '40001';
  end if;

  if v_current.id is null then
    insert into public.platform_retention_holds_v574(
      business_id, campaign_id, held, reason, version,
      placed_by, placed_at,
      released_by, released_at, updated_at)
    values (p_business, p_campaign, p_held, btrim(p_reason), 1,
      case when p_held then v_actor end, now(),
      case when p_held then null else v_actor end,
      case when p_held then null else now() end, now())
    returning version into v_version;
  else
    update public.platform_retention_holds_v574
       set held = p_held,
           reason = btrim(p_reason),
           version = version + 1,
           placed_by = case when p_held then v_actor else placed_by end,
           placed_at = case when p_held then now() else placed_at end,
           released_by = case when p_held then null else v_actor end,
           released_at = case when p_held then null else now() end,
           updated_at = now()
     where id = v_current.id
    returning version into v_version;
  end if;

  -- The actor is the PLATFORM ADMINISTRATOR. Nothing here pretends the tenant
  -- performed this, and the merchant's own bringback_campaigns_v361.active is
  -- not touched by any statement above.
  insert into public.audit_log(business_id, actor, action, entity, entity_id, detail)
  values (p_business, v_actor,
    case when p_held then 'retention.platform_held' else 'retention.platform_released' end,
    'platform_retention_holds_v574', coalesce(p_campaign, p_business),
    jsonb_build_object(
      'scope', case when p_campaign is null then 'business' else 'campaign' end,
      'campaign_id', p_campaign, 'business_id', p_business,
      'reason', btrim(p_reason), 'version', v_version,
      'actor_kind', 'platform_administrator'));

  return jsonb_build_object('status','ok','held',p_held,'version',v_version,
    'scope', case when p_campaign is null then 'business' else 'campaign' end);
end
$fn$;

revoke all on function public.platform_set_retention_hold_v574(uuid, uuid, boolean, text, bigint)
  from public, anon;
grant execute on function public.platform_set_retention_hold_v574(uuid, uuid, boolean, text, bigint)
  to authenticated;

-- B4. The console's roster
create or replace function public.platform_list_retention_holds_v574()
returns jsonb
language plpgsql
stable
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $fn$
declare v_rows jsonb;
begin
  if not app.v89_platform_can('automation', 'r') then
    raise exception 'platform automation read access required' using errcode = '42501';
  end if;

  select coalesce(jsonb_agg(entry order by entry->>'business_name', entry->>'campaign_name'), '[]'::jsonb)
    into v_rows
  from (
    select jsonb_build_object(
      'business_id', b.id, 'business_name', b.name,
      'campaign_id', c.id, 'campaign_name', c.name,
      'tenant_active', c.active,
      'platform_held', coalesce(h.held, false),
      'effective_active', coalesce(c.active, false) and not coalesce(h.held, false)
        and not coalesce(hb.held, false),
      'business_hold', coalesce(hb.held, false),
      'reason', coalesce(h.reason, hb.reason),
      'version', coalesce(h.version, 0),
      'business_hold_version', coalesce(hb.version, 0),
      'placed_at', coalesce(h.placed_at, hb.placed_at)
    ) as entry
    from public.businesses b
    join public.bringback_campaigns_v361 c
      on c.business_id = b.id and c.deleted_at is null
    left join public.platform_retention_holds_v574 h
      on h.business_id = b.id and h.campaign_id = c.id
    left join public.platform_retention_holds_v574 hb
      on hb.business_id = b.id and hb.campaign_id is null
  ) rows;

  return v_rows;
end
$fn$;

revoke all on function public.platform_list_retention_holds_v574() from public, anon;
grant execute on function public.platform_list_retention_holds_v574() to authenticated;

-- ---------------------------------------------------------------------------
-- B5. The retention lane honours the hold
-- ---------------------------------------------------------------------------
-- Re-created from the v572 definition with ONE new branch, placed immediately
-- after the business gate: a hold is a platform decision about this firm, so it
-- belongs beside the other questions about the firm and ahead of every question
-- about the customer.

create or replace function app.v551_enqueue_bringback_send()
returns trigger
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $fn$
declare
  v_client public.clients%rowtype;
  v_biz_name text;
  v_first text;
  v_identity uuid;
  v_reason text := null;
  v_biz jsonb;
  v_hold jsonb;
  v_consent jsonb;
begin
  select * into v_client from public.clients
   where id = new.client_id and business_id = new.business_id;
  if not found then return new; end if;

  select b.name into v_biz_name from public.businesses b where b.id = new.business_id;

  if not app.platform_feature_enabled('whatsapp_outbound') then
    v_reason := 'outbound_off';
  elsif not app.platform_feature_enabled('whatsapp_retention_sends') then
    v_reason := 'retention_sends_off';
  else
    v_biz := app.business_may_initiate_comms_v572(new.business_id, 'whatsapp', 'marketing');
    if not coalesce((v_biz->>'allowed')::boolean, false) then
      v_reason := coalesce(v_biz->>'reason', 'business_not_eligible');
    else
      v_hold := app.retention_platform_hold_v574(new.business_id, new.campaign_id);
      if coalesce((v_hold->>'held')::boolean, false) then
        v_reason := 'platform_hold';
      elsif not coalesce((app.capability_state_v518(new.business_id, 'whatsapp_retention')->>'allowed')::boolean, false) then
        v_reason := 'capability_disabled';
      elsif coalesce(v_client.is_synthetic, false) then
        v_reason := 'synthetic_client';
      elsif not coalesce(v_client.marketing_consent, false) then
        v_reason := 'consent_missing';
      else
        v_consent := app.whatsapp_marketing_consent_v572(new.business_id, new.client_id);
        if not coalesce((v_consent->>'allowed')::boolean, false) then
          v_reason := coalesce(v_consent->>'reason', 'whatsapp_consent_absent');
        else
          select l.identity_id into v_identity
            from public.customer_links l
           where l.business_id = new.business_id and l.client_id = new.client_id
             and l.state = 'verified'
           limit 1;
          if v_identity is not null
             and not app.customer_communication_allows_v263(v_identity, 'business_offers', 'whatsapp') then
            v_reason := 'preference_opt_out';
          elsif v_client.phone_norm is null then
            v_reason := 'no_phone';
          elsif app.retention_in_cooldown_v572(new.business_id, new.client_id) then
            v_reason := 'cooldown_active';
          end if;
        end if;
      end if;
    end if;
  end if;

  v_first := nullif(split_part(btrim(coalesce(v_client.full_name, '')), ' ', 1), '');

  insert into public.retention_sends_v551(
    business_id, client_id, grant_id, template_key, variables,
    recipient_phone_norm, status, status_rank, suppressed_reason)
  values (
    new.business_id, new.client_id, new.id, 'bring_back_v1',
    jsonb_build_object(
      'customer_first_name', coalesce(v_first, 'there'),
      'business_name', coalesce(v_biz_name, 'us'),
      'reward_label', new.reward_label),
    v_client.phone_norm,
    case when v_reason is null then 'queued' else 'suppressed' end,
    case when v_reason is null then 0 else app.v551_retention_status_rank('suppressed') end,
    v_reason)
  on conflict (grant_id) do nothing;

  return new;
exception when others then
  return new;
end
$fn$;

revoke all on function app.v551_enqueue_bringback_send() from public, anon, authenticated;

-- The claim honours it too: a hold placed AFTER a row was queued must stop that
-- row, which is the whole point of an emergency stop.
create or replace function public.internal_retention_claim_v551(
  p_worker_id text, p_limit integer default 20, p_lease_seconds integer default 120)
returns table(message_id uuid, business_id uuid, recipient_phone_norm text,
  template_name text, language_code text, parameter_descriptors jsonb,
  variables jsonb, attempt_count integer, lease_token uuid)
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $fn$
declare
  v_lease uuid := gen_random_uuid();
  v_row record;
  v_quota jsonb;
begin
  update public.retention_sends_v551 s
     set status = 'suppressed', suppressed_reason = 'stale_unsent',
         status_rank = app.v551_retention_status_rank('suppressed')
   where s.status = 'queued' and s.queued_at < now() - interval '7 days';

  update public.retention_sends_v551 s
     set status = 'suppressed', suppressed_reason = 'consent_withdrawn',
         status_rank = app.v551_retention_status_rank('suppressed')
   where s.status = 'queued'
     and (
       exists (select 1 from public.clients c
                where c.id = s.client_id and not coalesce(c.marketing_consent, false))
       or not coalesce((app.whatsapp_marketing_consent_v572(s.business_id, s.client_id)->>'allowed')::boolean, false)
     );

  -- v574: a platform hold suppresses queued work immediately, by name, so an
  -- operator can see WHY the lane went quiet.
  update public.retention_sends_v551 s
     set status = 'suppressed', suppressed_reason = 'platform_hold',
         status_rank = app.v551_retention_status_rank('suppressed')
   where s.status = 'queued'
     and coalesce((app.retention_platform_hold_v574(s.business_id, null)->>'held')::boolean, false);

  for v_row in
    select s.id, s.business_id, s.client_id, s.recipient_phone_norm, s.variables,
           s.attempt_count, t.meta_name, t.language_code, t.parameter_descriptors
      from public.retention_sends_v551 s
      join public.whatsapp_template_registry_v551 t
        on t.template_key = s.template_key and t.status = 'approved'
     where s.status in ('queued','processing')
       and coalesce(s.next_attempt_at, now()) <= now()
       and (s.lease_until is null or s.lease_until < now())
       and app.platform_feature_enabled('whatsapp_outbound')
       and app.platform_feature_enabled('whatsapp_retention_sends')
       and coalesce((app.business_may_initiate_comms_v572(s.business_id,'whatsapp','marketing')->>'allowed')::boolean, false)
       and not coalesce((app.retention_platform_hold_v574(s.business_id, null)->>'held')::boolean, false)
       and not app.retention_in_cooldown_v572(s.business_id, s.client_id, s.id)
     order by s.queued_at
     limit greatest(coalesce(p_limit, 20), 1)
     for update of s skip locked
  loop
    v_quota := app.capability_consume_v518(
      v_row.business_id, 'whatsapp_retention', 'v551:' || v_row.id::text,
      jsonb_build_object('kind','retention_send'));

    if not coalesce((v_quota->>'consumed')::boolean, false) then
      continue;
    end if;

    update public.retention_sends_v551 target
       set status = 'processing',
           status_rank = greatest(target.status_rank, app.v551_retention_status_rank('processing')),
           lease_token = v_lease,
           leased_by = left(coalesce(p_worker_id, 'worker'), 64),
           lease_until = now() + make_interval(secs => greatest(coalesce(p_lease_seconds, 120), 30))
     where target.id = v_row.id;

    message_id := v_row.id;
    business_id := v_row.business_id;
    recipient_phone_norm := v_row.recipient_phone_norm;
    template_name := v_row.meta_name;
    language_code := v_row.language_code;
    parameter_descriptors := v_row.parameter_descriptors;
    variables := v_row.variables;
    attempt_count := v_row.attempt_count;
    lease_token := v_lease;
    return next;
  end loop;

  return;
end
$fn$;

revoke all on function public.internal_retention_claim_v551(text, integer, integer)
  from public, anon, authenticated;
grant execute on function public.internal_retention_claim_v551(text, integer, integer) to service_role;

-- ---------------------------------------------------------------------------
-- C. The appointment lane gets the business gate, at transactional intent
-- ---------------------------------------------------------------------------
-- Re-created from the v557 definition with ONE new gate, inserted exactly where
-- that migration's own comment says the order runs: master flag, then the firm,
-- then the capability, then the recipient.

create or replace function app.whatsapp_enqueue_appointment_notice_v557(
  p_business uuid,
  p_appointment uuid,
  p_kind text
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $fn$
declare
  v_appt public.appointments%rowtype;
  v_client public.clients%rowtype;
  v_state jsonb;
  v_quota jsonb;
  v_biz jsonb;
  v_biz_name text;
  v_service_name text;
  v_idem text;
  v_template text;
  v_when text;
  v_id uuid;
begin
  if p_kind is null or p_kind not in ('appointment_confirmation','appointment_reminder') then
    return jsonb_build_object('status','refused','reason','unknown_kind');
  end if;

  select * into v_appt from public.appointments
   where id = p_appointment and business_id = p_business;
  if not found then
    return jsonb_build_object('status','refused','reason','appointment_not_found');
  end if;
  if v_appt.status <> 'booked' then
    return jsonb_build_object('status','refused','reason','appointment_not_booked');
  end if;

  if not app.platform_feature_enabled('whatsapp_outbound') then
    return jsonb_build_object('status','refused','reason','outbound_not_enabled');
  end if;

  -- v574: may this business initiate customer comms at all? TRANSACTIONAL
  -- intent, so a demo firm keeps working (demonstrating reminders is the point
  -- of a demo) while a closed, paused or synthetic workspace is refused.
  v_biz := app.business_may_initiate_comms_v572(p_business, 'whatsapp', 'transactional');
  if not coalesce((v_biz->>'allowed')::boolean, false) then
    return jsonb_build_object('status','refused',
      'reason', coalesce(v_biz->>'reason', 'business_not_eligible'));
  end if;

  v_state := app.capability_state_v518(p_business, 'whatsapp_appointment_notification');
  if (v_state->>'allowed') is distinct from 'true' then
    return jsonb_build_object('status','refused',
      'reason', coalesce(v_state->>'reason','capability_refused')) || v_state;
  end if;

  select * into v_client from public.clients
   where id = v_appt.client_id and business_id = p_business;
  if not found then
    return jsonb_build_object('status','refused','reason','client_not_found');
  end if;
  if coalesce(v_client.is_synthetic, false) then
    return jsonb_build_object('status','refused','reason','synthetic_client');
  end if;
  if v_client.phone_norm is null then
    return jsonb_build_object('status','refused','reason','no_phone');
  end if;

  select b.name into v_biz_name from public.businesses b where b.id = p_business;
  select s.name into v_service_name from public.services s where s.id = v_appt.service_id;

  if p_kind = 'appointment_confirmation' then
    v_template := 'peekaa_appt_confirmation';
    v_when := to_char(v_appt.starts_at at time zone 'Asia/Singapore', 'Dy DD Mon, HH12:MI AM');
  else
    v_template := 'peekaa_appt_reminder';
    v_when := to_char(v_appt.starts_at at time zone 'Asia/Singapore', 'HH12:MI AM');
  end if;

  v_idem := p_kind || ':' || p_appointment::text || ':'
            || to_char(v_appt.starts_at at time zone 'UTC', 'YYYYMMDD"T"HH24MISS');

  insert into public.whatsapp_template_sends_v557(
    business_id, appointment_id, kind, recipient_phone_norm,
    template_name, language_code, parameters, idempotency_key,
    status, status_rank, attempt_count, queued_at, next_attempt_at)
  values (
    p_business, p_appointment, p_kind, v_client.phone_norm,
    v_template, 'en',
    jsonb_build_array(
      jsonb_build_object('type','text','text', coalesce(nullif(btrim(v_biz_name),''),'Peekaa')),
      jsonb_build_object('type','text','text', coalesce(nullif(btrim(v_service_name),''),'your appointment')),
      jsonb_build_object('type','text','text', v_when)),
    v_idem, 'queued', app.support_status_rank_v535('queued'), 0, now(), now())
  on conflict (business_id, idempotency_key) do nothing
  returning id into v_id;

  if v_id is null then
    return jsonb_build_object('status','ok','duplicate',true,'reason','already_queued');
  end if;

  v_quota := app.capability_consume_v518(
    p_business, 'whatsapp_appointment_notification', v_idem,
    jsonb_build_object('appointment_id', p_appointment, 'kind', p_kind));

  if (v_quota->>'consumed') is distinct from 'true' then
    update public.whatsapp_template_sends_v557
       set status = 'failed',
           status_rank = greatest(status_rank, app.support_status_rank_v535('failed')),
           last_error_code = left(coalesce(v_quota->>'reason','capability_refused'), 64),
           next_attempt_at = null
     where id = v_id;
    return jsonb_build_object('status','refused',
      'reason', coalesce(v_quota->>'reason','capability_refused'),
      'send_id', v_id);
  end if;

  return jsonb_build_object(
    'status','ok','duplicate',false,'send_id',v_id,'kind',p_kind,
    'template_name',v_template,'idempotency_key',v_idem,
    'remaining', v_quota->'remaining');
end
$fn$;

revoke all on function app.whatsapp_enqueue_appointment_notice_v557(uuid, uuid, text)
  from public, anon, authenticated;
grant execute on function app.whatsapp_enqueue_appointment_notice_v557(uuid, uuid, text)
  to service_role;

-- And the appointment claim, for state that changed between queue and dispatch.
create or replace function public.internal_whatsapp_claim_template_sends_v557(
  p_worker_id text,
  p_limit integer default 20,
  p_lease_seconds integer default 120
)
returns table(
  message_id uuid, business_id uuid, recipient_phone_norm text,
  template_name text, language_code text, parameters jsonb,
  attempt_count integer, lease_token uuid)
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $fn$
declare v_lease uuid := gen_random_uuid();
begin
  return query
  with claimable as (
    select m.id
      from public.whatsapp_template_sends_v557 m
     where m.status in ('queued','processing')
       and coalesce(m.next_attempt_at, now()) <= now()
       and (m.lease_until is null or m.lease_until < now())
       -- v574: a workspace that closed after the row was queued stops here.
       and coalesce((app.business_may_initiate_comms_v572(m.business_id,'whatsapp','transactional')->>'allowed')::boolean, false)
     order by m.queued_at
     limit greatest(coalesce(p_limit, 20), 1)
     for update skip locked
  )
  update public.whatsapp_template_sends_v557 target
     set status = 'processing',
         status_rank = greatest(target.status_rank, app.support_status_rank_v535('processing')),
         lease_token = v_lease,
         leased_by = left(coalesce(p_worker_id, 'worker'), 64),
         lease_until = now() + make_interval(secs => greatest(coalesce(p_lease_seconds, 120), 30))
    from claimable
   where target.id = claimable.id
  returning target.id, target.business_id, target.recipient_phone_norm,
            target.template_name, target.language_code, target.parameters,
            target.attempt_count, v_lease;
end
$fn$;

revoke all on function public.internal_whatsapp_claim_template_sends_v557(text, integer, integer)
  from public, anon, authenticated;
grant execute on function public.internal_whatsapp_claim_template_sends_v557(text, integer, integer)
  to service_role;

-- The switch stays off.
update app.platform_feature_flags
   set enabled = false
 where feature_key = 'whatsapp_retention_sends';

commit;
