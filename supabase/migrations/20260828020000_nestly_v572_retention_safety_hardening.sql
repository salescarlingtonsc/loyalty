-- ============================================================================
-- nestly_v572 — RETENTION SAFETY HARDENING (still disarmed)
--
-- Owner rulings 2026-08-28. Retention WhatsApp remains IMPOSSIBLE after this
-- migration: whatsapp_retention_sends stays false and no capability is granted.
-- This adds the gates that must exist BEFORE any pilot is approved.
--
-- Five things:
--   1. business-scoped WhatsApp marketing consent, provable on one row
--   2. one canonical "may this business initiate customer comms" resolver
--   3. a 30-day per-recipient cooldown that holds ACROSS campaigns
--   4. quota reserved BEFORE a send can be claimed, with a release policy
--   5. the retention lane rewired through all of the above
--
-- ===========================================================================
-- 1. CONSENT — WHY public.consents AND NOT A NEW TABLE
-- ===========================================================================
-- Owner ruling: do not build a parallel consent system if an existing model can
-- represent this. public.consents already carries business_id, client_id,
-- channel, action ('granted'/'withdrawn'), source, actor and created_at, and
-- v551's own STOP handler already appends to it. It is the only business-scoped,
-- client-keyed, grant/withdraw stream in Peekaa. It is extended, not replaced.
--
-- Its one real defect is that `channel` conflated purpose and channel: a row
-- could say 'marketing' OR 'whatsapp', never both, so no historical row can
-- assert "marketing, over WhatsApp". `purpose` is therefore split out.
--
-- NOTHING IS BACKFILLED AND NO EXISTING WRITER CHANGES. All 18 historical rows
-- keep channel='marketing', which is NOT 'whatsapp', so none of them satisfies
-- the resolver. That is deliberate and is the whole point:
--
--   NOBODY IS GRANDFATHERED. All 8 clients currently holding
--   clients.marketing_consent=true were ticked by STAFF at a till or an admin
--   screen ('admin add-customer', 'till quick add', 'admin client page') — not
--   one came from a customer-facing act, and not one names WhatsApp or pins the
--   wording agreed to. Peekaa has ruled this way twice before: v175 and v265
--   both RESET prior true values rather than carry them forward, on the stated
--   ground that carrying them would manufacture consent that was never given.
--   Extending that precedent costs 8 rows across 3 non-production tenants.
--
-- clients.marketing_consent survives as the staff-facing PDPA flag and a cheap
-- pre-filter. It simply stops being the WhatsApp authority.
--
-- The immutability trigger guards UPDATE ONLY, not DELETE. consents.client_id
-- is ON DELETE CASCADE from clients, so a delete guard would break client
-- erasure — the PDPA right that consent evidence exists to serve.
--
-- ===========================================================================
-- 2. BUSINESS ELIGIBILITY — THE RESOLVER ALREADY EXISTED
-- ===========================================================================
-- Owner ruling: do not invent businesses.suspended. Audit finding: there is no
-- lifecycle column on businesses at all, and the canonical answer is
-- app.business_workspace_open_v94 — approval_status='approved' AND NOT
-- workspace_paused, fail-closed via coalesce(...,false), already governing RLS,
-- module access and login at 30+ call sites.
--
-- AND C6 HUMAN SUPPORT ALREADY GATES ON IT. app.support_reply_v535 has checked
-- business_workspace_open_v94 since v535 shipped, refusing 'business_not_active'.
-- So reusing that signal cannot restrict support: support is not touched by this
-- migration at all. The asymmetry runs the other way — the PROACTIVE lanes never
-- checked it, so a pending or payment-paused firm could be dispatched marketing
-- while its own staff were locked out of the workspace.
--
-- v572 wraps it with the channel/intent questions that are specific to comms:
--   * is_synthetic  -> a fixture firm must never reach a real handset
--   * is_demo       -> refused for MARKETING intent only. Scoping matters:
--                      Cubbly SPA is is_demo=true and is the C6 support pilot,
--                      so an unscoped demo refusal would break support the day
--                      support adopted this resolver.
-- It deliberately does NOT read subscriptions.status (15 of 18 firms are
-- 'trialing'; billing reaches operations only through the graded 14-day
-- lifecycle that already sets workspace_paused), nor activated_at /
-- onboarding_started_at (NULL on all 18 rows — a fail-closed read of a
-- universally NULL column would refuse every business in production).
--
-- ===========================================================================
-- 3. COOLDOWN — 30 DAYS, ACROSS CAMPAIGNS
-- ===========================================================================
-- Owner ruling: at most ONE proactive retention WhatsApp per customer per
-- business per rolling 30 days, and two campaigns must not each send one.
-- The old structure only guaranteed one send per GRANT (unique grant_id), so N
-- active campaigns meant N messages to the same phone on the same night.
--
-- The window counts rows that were sent or are in flight
-- (queued/processing/sent/delivered/read). Suppressed and failed rows never
-- reached the customer, so they must not extend the cooldown — otherwise a
-- config fault would silence a customer for a month.
--
-- Retries and status callbacks cannot double-count by construction: a retry
-- mutates the SAME row (unique grant_id), it never inserts a second one.
--
-- ===========================================================================
-- 4. QUOTA — RESERVE BEFORE CLAIM, RELEASE ON A FAULT
-- ===========================================================================
-- Owner ruling: the consume-after-Meta-accepts model is rejected. It let a batch
-- of up to 20 claimed rows overshoot a 50/day cap, because every row's
-- capability_state was evaluated before any of them consumed.
--
-- Now the claim consumes per row, INSIDE the claim, before the lease is handed
-- out. app.capability_consume_v518 already takes pg_advisory_xact_lock on
-- (business, capability) and re-reads state under that lock, so concurrent
-- workers serialise and the (n+1)th consume sees the nth. The idem key is
-- 'v551:<row id>' — the same key the old report path used — so re-claiming an
-- expired lease returns duplicate:true and cannot consume twice.
--
-- RELEASE POLICY. capability_usage_v518 is append-only (v33 guard, BEFORE
-- DELETE OR UPDATE), so a release cannot delete or edit the reservation; it
-- appends a compensating row and app.capability_state_v518 now counts NET.
-- Released: terminal dispositions that never reached the customer —
-- undeliverable, template_fault, config_fault, failed, failed_retries_exhausted.
-- A template or config fault is Peekaa's mistake and must not spend a merchant's
-- allowance. NOT released: 'sent'. Once Meta accepted it, it is spent.
-- Rows with no 'kind' in detail (every historical row, every other lane) count
-- +1 exactly as before, so support and appointments are unaffected.
-- ============================================================================

begin;

-- ---------------------------------------------------------------------------
-- 1. Consent: split purpose from channel, and pin the evidence
-- ---------------------------------------------------------------------------

alter table public.consents
  add column if not exists purpose text not null default 'marketing',
  add column if not exists scope_version text,
  add column if not exists notice_version text,
  add column if not exists notice_sha256 text,
  add column if not exists request_hash text,
  add column if not exists idempotency_key text;

alter table public.consents drop constraint if exists consents_purpose_check;
alter table public.consents
  add constraint consents_purpose_check
  check (purpose in ('marketing','retention','transactional','service'));

alter table public.consents drop constraint if exists consents_notice_sha_check;
alter table public.consents
  add constraint consents_notice_sha_check
  check (notice_sha256 is null or notice_sha256 ~ '^[0-9a-f]{64}$');

alter table public.consents drop constraint if exists consents_request_hash_check;
alter table public.consents
  add constraint consents_request_hash_check
  check (request_hash is null or request_hash ~ '^[0-9a-f]{64}$');

-- 'marketing' is KEPT in the allowed set so all seven existing writers keep
-- working untouched. It now means "a channel was never named", which is the
-- honest reading of every historical row and precisely why none of them can
-- authorise a WhatsApp send.
alter table public.consents drop constraint if exists consents_channel_check;
alter table public.consents
  add constraint consents_channel_check
  check (channel in ('marketing','any','email','sms','whatsapp','push','in_app','call'));

comment on column public.consents.purpose is
  'v572 why the customer was contacted, split out of `channel` which conflated the two. A WhatsApp marketing send requires purpose=''marketing'' AND channel=''whatsapp'' on the same row; no historical row satisfies both, so nobody is grandfathered.';
comment on column public.consents.notice_sha256 is
  'v572 digest of the exact notice wording the customer agreed to, mirroring the v175/v265 doctrine that the notice and the consent move together.';

create index if not exists consents_v572_channel_purpose_idx
  on public.consents (business_id, client_id, purpose, channel, created_at desc);

-- UPDATE-only. DELETE stays legal so `clients` ON DELETE CASCADE erasure works.
create or replace function app.consents_no_update_v572()
returns trigger language plpgsql
set search_path to 'pg_catalog', 'pg_temp'
as $fn$
begin
  raise exception 'consents is append-only evidence; append a withdrawal instead of editing'
    using errcode = '23000';
end
$fn$;

drop trigger if exists consents_v572_no_update on public.consents;
create trigger consents_v572_no_update
before update on public.consents
for each row execute function app.consents_no_update_v572();

-- The resolver: one row proves business, customer, channel, purpose, the
-- affirmative act, its provenance, its timestamp, and that nothing later
-- withdrew it (latest event wins over an append-only stream).
create or replace function app.whatsapp_marketing_consent_v572(
  p_business uuid,
  p_client uuid
)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $fn$
declare v_row public.consents%rowtype;
begin
  if p_business is null or p_client is null then
    return jsonb_build_object('allowed', false, 'reason', 'consent_subject_missing');
  end if;

  select * into v_row
    from public.consents
   where business_id = p_business
     and client_id = p_client
     and purpose = 'marketing'
     and channel = 'whatsapp'
   order by created_at desc, id desc
   limit 1;

  if not found then
    -- No row has ever asserted marketing-over-WhatsApp for this pair. Not a
    -- refusal to be argued with; simply no evidence, so no send.
    return jsonb_build_object('allowed', false, 'reason', 'whatsapp_consent_absent');
  end if;

  if v_row.action <> 'granted' then
    return jsonb_build_object('allowed', false, 'reason', 'whatsapp_consent_withdrawn',
      'decided_at', v_row.created_at, 'evidence_id', v_row.id);
  end if;

  return jsonb_build_object(
    'allowed', true, 'reason', 'ok',
    'business_id', v_row.business_id, 'client_id', v_row.client_id,
    'channel', v_row.channel, 'purpose', v_row.purpose, 'action', v_row.action,
    'source', v_row.source, 'actor', v_row.actor,
    'scope_version', v_row.scope_version, 'notice_version', v_row.notice_version,
    'notice_sha256', v_row.notice_sha256,
    'decided_at', v_row.created_at, 'evidence_id', v_row.id);
end
$fn$;

revoke all on function app.whatsapp_marketing_consent_v572(uuid, uuid)
  from public, anon, authenticated;
grant execute on function app.whatsapp_marketing_consent_v572(uuid, uuid) to service_role;

-- ---------------------------------------------------------------------------
-- 2. One canonical "may this business speak" resolver
-- ---------------------------------------------------------------------------

create or replace function app.business_may_initiate_comms_v572(
  p_business uuid,
  p_channel text default 'whatsapp',
  p_intent text default 'marketing'
)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $fn$
declare v_biz public.businesses%rowtype;
begin
  if p_business is null then
    return jsonb_build_object('allowed', false, 'reason', 'business_unknown');
  end if;
  if p_channel is null or p_channel not in ('whatsapp','sms','email','push') then
    return jsonb_build_object('allowed', false, 'reason', 'channel_unknown');
  end if;
  -- An unrecognised intent is never quietly treated as transactional.
  if p_intent is null or p_intent not in ('marketing','transactional','support') then
    return jsonb_build_object('allowed', false, 'reason', 'intent_unknown');
  end if;

  select * into v_biz from public.businesses where id = p_business;
  if not found then
    return jsonb_build_object('allowed', false, 'reason', 'business_unknown');
  end if;

  if p_channel = 'whatsapp'
     and not app.platform_feature_enabled('whatsapp_outbound') then
    return jsonb_build_object('allowed', false, 'reason', 'platform_channel_off');
  end if;

  -- THE canonical operational state. Same signal, same reason string, that
  -- app.support_reply_v535 has used since v535.
  if not app.business_workspace_open_v94(p_business) then
    return jsonb_build_object('allowed', false, 'reason', 'business_not_active');
  end if;

  if coalesce(v_biz.is_synthetic, false) then
    return jsonb_build_object('allowed', false, 'reason', 'synthetic_business');
  end if;

  -- Intent-scoped on purpose: a sales-demo firm may legitimately demonstrate
  -- support and transactional flows, but must never run marketing at real
  -- handsets. Cubbly SPA is is_demo=true AND the support pilot, so an unscoped
  -- refusal here would break support.
  if p_intent = 'marketing' and coalesce(v_biz.is_demo, false) then
    return jsonb_build_object('allowed', false, 'reason', 'demo_business_marketing');
  end if;

  return jsonb_build_object('allowed', true, 'reason', 'ok',
    'channel', p_channel, 'intent', p_intent,
    'is_demo', coalesce(v_biz.is_demo, false),
    'is_synthetic', coalesce(v_biz.is_synthetic, false));
end
$fn$;

revoke all on function app.business_may_initiate_comms_v572(uuid, text, text)
  from public, anon, authenticated;
grant execute on function app.business_may_initiate_comms_v572(uuid, text, text) to service_role;

comment on function app.business_may_initiate_comms_v572(uuid, text, text) is
  'v572 the one question "may this business initiate customer communications right now". Wraps the canonical app.business_workspace_open_v94 (which C6 support already enforces) with the channel/intent-specific rules. Does NOT read subscriptions.status; billing reaches operations only through the graded lifecycle that sets workspace_paused.';

-- ---------------------------------------------------------------------------
-- 3. The cooldown
-- ---------------------------------------------------------------------------
-- Pinned to 30 days for V1 by owner ruling; a function rather than a literal so
-- making it configurable later is a one-line change with one call site.

create or replace function app.retention_cooldown_days_v572()
returns integer language sql immutable
set search_path to 'pg_catalog', 'pg_temp'
as $$ select 30 $$;

create or replace function app.retention_in_cooldown_v572(
  p_business uuid,
  p_client uuid,
  p_exclude_send uuid default null
)
returns boolean
language sql
stable
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
  select exists (
    select 1
      from public.retention_sends_v551 s
     where s.business_id = p_business
       and s.client_id = p_client
       and (p_exclude_send is null or s.id <> p_exclude_send)
       -- Reached the customer, or is still on its way. Suppressed and failed
       -- rows never arrived, so they must not silence the customer for a month.
       and s.status in ('queued','processing','sent','delivered','read')
       and coalesce(s.sent_at, s.queued_at)
           > now() - make_interval(days => app.retention_cooldown_days_v572())
  )
$$;

revoke all on function app.retention_in_cooldown_v572(uuid, uuid, uuid)
  from public, anon, authenticated;
grant execute on function app.retention_in_cooldown_v572(uuid, uuid, uuid) to service_role;

create index if not exists retention_sends_v551_cooldown_idx
  on public.retention_sends_v551 (business_id, client_id, queued_at desc)
  where status in ('queued','processing','sent','delivered','read');

-- ---------------------------------------------------------------------------
-- 4a. Quota release, and net counting
-- ---------------------------------------------------------------------------

create or replace function app.capability_release_v572(
  p_business uuid,
  p_capability text,
  p_idem_key text,
  p_reason text default null
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $fn$
declare
  v_original public.capability_usage_v518%rowtype;
  v_release_key text;
begin
  if coalesce(btrim(p_idem_key), '') = '' then
    raise exception 'capability release requires the original idempotency key' using errcode = '22023';
  end if;

  -- The SAME lock expression app.capability_consume_v518 uses, character for
  -- character. A different hash — even a correct-looking one — would put the
  -- release in a different lock space, and a concurrent consume and release
  -- would stop serialising against each other.
  perform pg_advisory_xact_lock(
    hashtextextended(p_business::text || ':' || p_capability, 0));

  select * into v_original from public.capability_usage_v518
   where business_id = p_business and capability_key = p_capability
     and idem_key = btrim(p_idem_key);
  if not found then
    -- Nothing was ever reserved under this key, so there is nothing to give
    -- back. Not an error: a row that failed before it consumed reports the same
    -- terminal disposition as one that failed after.
    return jsonb_build_object('released', false, 'reason', 'nothing_reserved');
  end if;

  v_release_key := 'release:' || btrim(p_idem_key);

  insert into public.capability_usage_v518(
    business_id, capability_key, period_key, idem_key, detail, consumed_at)
  values (p_business, p_capability, v_original.period_key, v_release_key,
    jsonb_build_object('kind','release','releases',btrim(p_idem_key),
      'reason', left(coalesce(p_reason,'unspecified'), 64)), now())
  on conflict (business_id, capability_key, idem_key) do nothing;

  if not found then
    return jsonb_build_object('released', true, 'duplicate', true);
  end if;
  return jsonb_build_object('released', true, 'duplicate', false,
    'period_key', v_original.period_key);
end
$fn$;

revoke all on function app.capability_release_v572(uuid, text, text, text)
  from public, anon, authenticated;
grant execute on function app.capability_release_v572(uuid, text, text, text) to service_role;

comment on function app.capability_release_v572(uuid, text, text, text) is
  'v572 gives back one reserved capability unit by APPENDING a compensating row — capability_usage_v518 is append-only (v33 guard), so a release can never delete or edit the reservation. The release lands in the ORIGINAL period so a refund cannot leak across a period boundary.';

-- capability_state_v518: identical to the v537 definition in every respect
-- except that v_used is now NET of releases. Rows without detail->>'kind'
-- (every historical row and every other lane) still count +1, so the support
-- and appointment lanes are bit-for-bit unaffected.
create or replace function app.capability_state_v518(p_business uuid, p_capability text, p_at timestamptz default now())
returns jsonb
language plpgsql
stable
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $fn$
declare
  v_cap public.platform_capabilities_v518%rowtype;
  v_grant public.business_capability_grants_v518%rowtype;
  v_biz public.businesses%rowtype;
  v_enabled boolean;
  v_limit integer;
  v_period text;
  v_period_key text;
  v_used integer;
  v_module text;
  v_mode text;
  v_missing text[] := '{}';
begin
  select * into v_cap from public.platform_capabilities_v518 where capability_key = p_capability;
  if not found then
    return jsonb_build_object('allowed', false, 'reason', 'capability_unknown');
  end if;
  if not v_cap.active then
    return jsonb_build_object('allowed', false, 'reason', 'capability_inactive');
  end if;

  select * into v_biz from public.businesses where id = p_business;
  if not found then
    return jsonb_build_object('allowed', false, 'reason', 'business_unknown');
  end if;

  if v_cap.eligible_industries is not null
     and not (v_biz.industry = any (v_cap.eligible_industries)) then
    return jsonb_build_object(
      'allowed', false, 'reason', 'industry_not_eligible',
      'industry', v_biz.industry, 'eligible_industries', to_jsonb(v_cap.eligible_industries));
  end if;

  if v_cap.required_modules is not null and array_length(v_cap.required_modules, 1) is not null then
    foreach v_module in array v_cap.required_modules loop
      select resolved.mode into v_mode
        from app.effective_platform_module_mode_v94(p_business, null, v_module) resolved;
      if coalesce(v_mode, 'disabled') = 'disabled' then
        v_missing := v_missing || v_module;
      end if;
    end loop;
    if array_length(v_missing, 1) is not null then
      return jsonb_build_object(
        'allowed', false, 'reason', 'module_not_enabled',
        'required_modules', to_jsonb(v_cap.required_modules),
        'missing_modules', to_jsonb(v_missing));
    end if;
  end if;

  select * into v_grant from public.business_capability_grants_v518
   where business_id = p_business and capability_key = p_capability;

  v_enabled := coalesce(v_grant.enabled, v_cap.default_enabled);
  v_limit   := case when coalesce(v_grant.limit_unlimited, false) then null
                    else coalesce(v_grant.limit_count, v_cap.default_limit_count) end;
  v_period  := coalesce(v_grant.limit_period, v_cap.default_limit_period);
  v_period_key := app.v365_period_key(v_period, p_at);

  -- v572: NET of releases.
  select greatest(
           count(*) filter (where coalesce(detail->>'kind','') <> 'release')
           - count(*) filter (where detail->>'kind' = 'release'), 0)::integer
    into v_used
    from public.capability_usage_v518
   where business_id = p_business
     and capability_key = p_capability
     and period_key = v_period_key;

  if not v_enabled then
    return jsonb_build_object(
      'allowed', false, 'reason', 'not_enabled',
      'limit_count', v_limit, 'limit_period', v_period,
      'period_key', v_period_key, 'used', v_used);
  end if;

  if v_limit is not null and v_used >= v_limit then
    return jsonb_build_object(
      'allowed', false, 'reason', 'quota_exhausted',
      'limit_count', v_limit, 'limit_period', v_period,
      'period_key', v_period_key, 'used', v_used, 'remaining', 0);
  end if;

  return jsonb_build_object(
    'allowed', true, 'reason', 'ok',
    'limit_count', v_limit, 'limit_period', v_period,
    'period_key', v_period_key, 'used', v_used,
    'remaining', case when v_limit is null then null else v_limit - v_used end);
end
$fn$;

-- ---------------------------------------------------------------------------
-- 5. The retention lane, rewired
-- ---------------------------------------------------------------------------
-- Enqueue: same shape as v551 (always writes a row, marking it 'suppressed'
-- with a named reason rather than dropping the decision), with three new gates.
-- Gate ORDER is deliberate: platform, then business, then customer. A refusal
-- should name the party who can fix it, cheapest question first.

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
    -- v572: may this business initiate marketing at all?
    v_biz := app.business_may_initiate_comms_v572(new.business_id, 'whatsapp', 'marketing');
    if not coalesce((v_biz->>'allowed')::boolean, false) then
      v_reason := coalesce(v_biz->>'reason', 'business_not_eligible');
    elsif not coalesce((app.capability_state_v518(new.business_id, 'whatsapp_retention')->>'allowed')::boolean, false) then
      v_reason := 'capability_disabled';
    elsif coalesce(v_client.is_synthetic, false) then
      v_reason := 'synthetic_client';
    elsif not coalesce(v_client.marketing_consent, false) then
      -- Kept as a cheap pre-filter and as the staff-facing PDPA flag. It is no
      -- longer sufficient on its own; the next branch is the authority.
      v_reason := 'consent_missing';
    else
      -- v572: business-scoped, channel-specific, purpose-specific consent.
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
          -- v572: one proactive retention message per customer per business per
          -- 30 days, ACROSS campaigns. Two campaigns cannot each send one.
          v_reason := 'cooldown_active';
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
  -- A voucher is money and a promise; a WhatsApp row is neither. Nothing here
  -- may abort the grant that triggered it.
  return new;
end
$fn$;

revoke all on function app.v551_enqueue_bringback_send() from public, anon, authenticated;

-- Claim: quota is now RESERVED here, per row, before the lease is handed out.
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
  v_taken integer := 0;
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
       -- v572: the business-scoped WhatsApp consent must still hold at claim
       -- time, not merely when the voucher was granted.
       or not coalesce((app.whatsapp_marketing_consent_v572(s.business_id, s.client_id)->>'allowed')::boolean, false)
     );

  -- v572: the row-at-a-time loop replaces the set-based claim precisely because
  -- the quota must be spent BEFORE a row is handed out. The old CTE evaluated
  -- capability_state for every candidate before any of them consumed, so a
  -- batch of 20 could overshoot a cap of 50 by up to 20.
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
       and not app.retention_in_cooldown_v572(s.business_id, s.client_id, s.id)
     order by s.queued_at
     limit greatest(coalesce(p_limit, 20), 1)
     for update of s skip locked
  loop
    -- Reserve. Advisory-locked and idempotent on this row's own key, so a
    -- re-claim after a lease expires returns duplicate:true and spends nothing.
    v_quota := app.capability_consume_v518(
      v_row.business_id, 'whatsapp_retention', 'v551:' || v_row.id::text,
      jsonb_build_object('kind','retention_send'));

    if not coalesce((v_quota->>'consumed')::boolean, false) then
      -- Unpaid rows are simply not handed out. They stay queued for the next
      -- period rather than being failed, because the cap is a pacing device,
      -- not a verdict on the message.
      continue;
    end if;

    update public.retention_sends_v551 target
       set status = 'processing',
           status_rank = greatest(target.status_rank, app.v551_retention_status_rank('processing')),
           lease_token = v_lease,
           leased_by = left(coalesce(p_worker_id, 'worker'), 64),
           lease_until = now() + make_interval(secs => greatest(coalesce(p_lease_seconds, 120), 30))
     where target.id = v_row.id;

    v_taken := v_taken + 1;
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

-- Report: quota is already spent, so 'sent' consumes nothing more; a terminal
-- disposition that never reached the customer gives its reservation back.
create or replace function public.internal_retention_report_v551(
  p_message uuid, p_lease_token uuid, p_disposition text,
  p_provider_message_id text default null, p_error_code text default null,
  p_retry_in_seconds integer default null)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $fn$
declare
  v_row public.retention_sends_v551%rowtype;
  v_released jsonb;
begin
  select * into v_row from public.retention_sends_v551 where id = p_message for update;
  if not found then
    raise exception 'unknown retention send' using errcode = 'P0002';
  end if;
  if v_row.lease_token is null or v_row.lease_token is distinct from p_lease_token then
    raise exception 'stale lease' using errcode = '40001';
  end if;

  if p_disposition = 'sent' then
    -- Already paid for at claim time. Meta accepted it; it stays spent.
    update public.retention_sends_v551
       set status = 'sent',
           status_rank = greatest(status_rank, app.v551_retention_status_rank('sent')),
           sent_at = coalesce(sent_at, now()),
           provider_message_id = coalesce(p_provider_message_id, provider_message_id),
           error_code = null,
           attempt_count = attempt_count + 1,
           lease_token = null, leased_by = null, lease_until = null,
           next_attempt_at = null
     where id = p_message;
  elsif p_disposition = 'retry' then
    -- The reservation is deliberately KEPT across a retry: the same row will be
    -- re-claimed under the same idem key, which returns duplicate:true, so
    -- holding it costs nothing and releasing it would let the cap drift.
    update public.retention_sends_v551
       set status = 'queued',
           status_rank = app.v551_retention_status_rank('queued'),
           error_code = left(coalesce(p_error_code, 'retry'), 64),
           attempt_count = attempt_count + 1,
           lease_token = null, leased_by = null, lease_until = null,
           next_attempt_at = now() + make_interval(secs => greatest(coalesce(p_retry_in_seconds, 60), 15))
     where id = p_message;
  elsif p_disposition in ('undeliverable','template_fault','config_fault','failed','failed_retries_exhausted') then
    -- Never reached the customer. A template or config fault is Peekaa's
    -- mistake and must not spend a merchant's allowance.
    v_released := app.capability_release_v572(
      v_row.business_id, 'whatsapp_retention', 'v551:' || v_row.id::text, p_disposition);
    update public.retention_sends_v551
       set status = p_disposition,
           status_rank = greatest(status_rank, app.v551_retention_status_rank(p_disposition)),
           failed_at = coalesce(failed_at, now()),
           error_code = left(coalesce(p_error_code, p_disposition), 64),
           attempt_count = attempt_count + 1,
           lease_token = null, leased_by = null, lease_until = null,
           next_attempt_at = null
     where id = p_message;
  else
    raise exception 'unknown disposition' using errcode = '22023';
  end if;

  return jsonb_build_object('status', 'ok', 'message_id', p_message,
    'disposition', p_disposition, 'quota_released', coalesce(v_released->>'released','false'));
end
$fn$;

revoke all on function public.internal_retention_report_v551(uuid, uuid, text, text, text, integer)
  from public, anon, authenticated;
grant execute on function public.internal_retention_report_v551(uuid, uuid, text, text, text, integer) to service_role;

-- The switch stays off. Restated so replaying this migration cannot arm anything.
update app.platform_feature_flags
   set enabled = false
 where feature_key = 'whatsapp_retention_sends';

commit;
