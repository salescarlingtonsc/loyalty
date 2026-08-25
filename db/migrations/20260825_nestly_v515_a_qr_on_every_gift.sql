-- nestly_v515 — every gift a customer holds carries a QR they can show at the counter.
--
-- OWNER RULING (2026-08-25, photo 2): "all rewards and gifts must have a qrcode tagged to it for
-- customer to press and let business scan."
--
-- WHAT EXISTED. Only CATALOGUE rewards (public.loyalty_rewards, bought with points or stamps) had
-- a customer QR. The four things a customer is GIVEN — the welcome gift, a bring-back voucher, a
-- referral gift and a tier perk — were redeemable only by staff pressing "Give" at the till. The
-- customer card for them carried no button at all, and said so in a comment: "offering a QR here
-- would be a button that leads nowhere". This migration is what makes it lead somewhere.
--
-- WHY A SIBLING TABLE AND NOT A WIDENED customer_redemption_intents_v89. That table carries live
-- money-moving redemption evidence and its constraints make a free gift literally
-- unrepresentable:
--   * _quoted_points_spent_check   CHECK (quoted_points_spent > 0)  — every gift costs 0
--   * _redemption_kind_check       kind IN ('classic_points','catalog_reward')
--   * _kind_shape_check            hard-codes reward_id + config/reward version for catalog_reward
--   * _state_check                 a completed row needs redemption_id (FK loyalty_redemptions)
--                                  AND completion_operation_id (FK loyalty_operations) — none of
--                                  the four gift redeemers writes either table
--   * quoted_program_id            NOT NULL FK loyalty_programs
--   * and the RPC refuses outright unless an active points/stamps spine row exists, which locks
--     out a tiers-only firm
-- Loosening any of those to admit a gift would weaken the CATALOGUE path as a side effect. The
-- risk is not the new kind; it is relaxing state_check on the path that already works.
-- promotion_redemption_intents_v290 and growth_redemption_intents_v108 are the same shape already
-- — this is the third instance of an established pattern, not an invention.
--
-- THE TOKEN LAYER NEEDS NO CHANGE. app.v89_redemption_token(identity, business, kind, uuid, idem)
-- is already polymorphic: customer_create_promotion_intent_v290 passes the kind 'promotion_v290'
-- and a business_customer_content_v95 id in the slot named p_reward. Verified before relying on it.
--
-- SETTLEMENT REUSES THE FOUR EXISTING WRITERS, deliberately. Each is SECURITY DEFINER and
-- re-checks auth.uid() plus its OWN permission predicate — v215 wants create_sales, v361 wants
-- till or loyalty, v420 wants till or referrals, v365 wants till or loyalty. auth.uid() reads the
-- request JWT and is unaffected by definer nesting, so the three different predicates survive
-- intact rather than being flattened into one. The dispatcher adds no permission logic of its own.
--
-- OWNER DECISIONS ENCODED HERE (2026-08-25):
--   * an UNLIMITED automatic tier perk (limit_count is null) gets NO QR — evaluate_checkout
--     already applies it at payment, so a QR would both burn a usage record for an unmetered
--     benefit and risk double-applying the discount.
--   * a gift tied to a branch/service/product keeps staff-assisted redemption; a QR cannot prove
--     the customer is buying the right item.
--
-- THE "1 PER MONTH" ALLOWANCE. staff_issue_tier_benefit_v365 does
-- `v_key := coalesce(p_idempotency_key, gen_random_uuid())` — a NULL key silently becomes fresh
-- and BURNS A SECOND ALLOWANCE instead of replaying. The dispatcher therefore passes the intent
-- id as the key, which is deterministic per QR, so tier_benefit_issues_v365_idem_uk catches every
-- retry. The period is pinned at mint and re-checked at scan: a QR minted at 23:58 on 31 Aug and
-- scanned at 00:01 on 1 Sep must not silently spend September's allowance.

begin;

create table if not exists public.customer_gift_intents_v515(
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  identity_id uuid not null references public.customer_identities(id) on delete restrict,
  auth_user_id uuid not null,
  client_id uuid not null references public.clients(id) on delete cascade,

  gift_kind text not null,
  grant_id uuid,                                                   -- welcome / bringback / referral
  benefit_id uuid references public.tier_benefits_v365(id) on delete restrict,

  quoted_label text not null,
  quoted_min_spend_cents integer not null default 0,
  quoted_period_key text,
  quoted_terms jsonb not null default '{}'::jsonb,

  token_hash text not null,
  idempotency_key uuid not null,
  request_hash text not null,
  status text not null default 'pending',
  expires_at timestamptz not null,
  completed_at timestamptz,
  completed_by uuid,
  completion_result jsonb,
  created_at timestamptz not null default now(),

  constraint customer_gift_intents_v515_kind_check
    check (gift_kind = any (array['welcome','bringback','referral','tier_perk'])),
  -- The three grant tables are DIFFERENT tables, so a polymorphic FK is impossible; integrity is
  -- gift_kind + this shape check + the settlement RPC re-reading the real row `for update`.
  -- tier_benefits_v365 is one table, so benefit_id gets a real FK above.
  constraint customer_gift_intents_v515_shape_check
    check ((gift_kind in ('welcome','bringback','referral')
            and grant_id is not null and benefit_id is null and quoted_period_key is null)
        or (gift_kind = 'tier_perk'
            and grant_id is null and benefit_id is not null)),
  constraint customer_gift_intents_v515_status_check
    check (status = any (array['pending','completed','expired','cancelled'])),
  constraint customer_gift_intents_v515_state_check
    check ((status = 'pending'   and completed_at is null and completion_result is null)
        or (status = 'completed' and completed_at is not null and completion_result is not null)
        or (status in ('expired','cancelled') and completed_at is null)),
  constraint customer_gift_intents_v515_token_hash_check check (token_hash ~ '^[0-9a-f]{64}$'),
  constraint customer_gift_intents_v515_request_hash_check check (request_hash ~ '^[0-9a-f]{64}$'),
  -- 15 minutes, not the catalogue path's 5: a min-spend welcome gift cannot be scanned until the
  -- sale has been rung up, which is a real counter interval.
  constraint customer_gift_intents_v515_expiry_check
    check (expires_at > created_at and expires_at <= created_at + interval '30 minutes'),
  constraint customer_gift_intents_v515_min_spend_check check (quoted_min_spend_cents >= 0)
);

create unique index if not exists customer_gift_intents_v515_token_hash_key
  on public.customer_gift_intents_v515 (token_hash);
create unique index if not exists customer_gift_intents_v515_idem_uk
  on public.customer_gift_intents_v515 (identity_id, idempotency_key);
-- One live QR per gift per customer: a second pending mint for the same target is refused rather
-- than leaving two tokens that could each be scanned.
create unique index if not exists customer_gift_intents_v515_open_uk
  on public.customer_gift_intents_v515 (business_id, gift_kind, coalesce(grant_id, benefit_id), client_id)
  where status = 'pending';
create index if not exists customer_gift_intents_v515_client_idx
  on public.customer_gift_intents_v515 (business_id, client_id, status);

alter table public.customer_gift_intents_v515 enable row level security;
-- Zero policies, and revoked from the browser roles: identical posture to
-- customer_redemption_intents_v89. Every read and write goes through a SECURITY DEFINER RPC.
revoke all on public.customer_gift_intents_v515 from anon, authenticated;

-- Append-only provenance, modelled on app.v89_redemption_intent_guard.
create or replace function app.v515_gift_intent_guard()
returns trigger
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $function$
begin
  if tg_op = 'DELETE' then
    raise exception 'gift redemption intents are append-only' using errcode = '23001';
  end if;
  if new.business_id     is distinct from old.business_id
   or new.identity_id    is distinct from old.identity_id
   or new.auth_user_id   is distinct from old.auth_user_id
   or new.client_id      is distinct from old.client_id
   or new.gift_kind      is distinct from old.gift_kind
   or new.grant_id       is distinct from old.grant_id
   or new.benefit_id     is distinct from old.benefit_id
   or new.quoted_label   is distinct from old.quoted_label
   or new.quoted_min_spend_cents is distinct from old.quoted_min_spend_cents
   or new.quoted_period_key is distinct from old.quoted_period_key
   or new.quoted_terms   is distinct from old.quoted_terms
   or new.token_hash     is distinct from old.token_hash
   or new.idempotency_key is distinct from old.idempotency_key
   or new.request_hash   is distinct from old.request_hash
   or new.created_at     is distinct from old.created_at then
    raise exception 'gift redemption intent provenance is immutable' using errcode = '23001';
  end if;
  return new;
end
$function$;

drop trigger if exists trg_customer_gift_intents_v515_guard on public.customer_gift_intents_v515;
create trigger trg_customer_gift_intents_v515_guard
  before delete or update on public.customer_gift_intents_v515
  for each row execute function app.v515_gift_intent_guard();

-- ---------------------------------------------------------------------------------------------
-- THE FOUR RPCs, exactly as they stand in production (pulled with pg_get_functiondef so this file
-- and the database cannot drift). Three are the customer's side of one intent — mint, poll,
-- cancel — modelled on their customer_*_redemption_intent_v89 twins. The fourth is the counter's
-- dispatcher, and is the ONLY place the four gift families are distinguished.
CREATE OR REPLACE FUNCTION public.customer_cancel_gift_intent_v515(p_intent uuid, p_idempotency_key uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'app', 'pg_temp'
AS $function$
declare v_actor uuid := auth.uid(); v_row public.customer_gift_intents_v515%rowtype;
begin
  if v_actor is null then
    raise exception 'authenticated customer session required' using errcode='28000';
  end if;
  select * into v_row from public.customer_gift_intents_v515
   where id = p_intent and auth_user_id = v_actor for update;
  if not found then
    raise exception 'gift intent not found' using errcode='42501';
  end if;
  if v_row.status = 'completed' then
    return jsonb_build_object('status','completed','replayed',true,'result',v_row.completion_result);
  end if;
  if v_row.status = 'pending' then
    update public.customer_gift_intents_v515 set status='cancelled' where id=v_row.id;
  end if;
  return jsonb_build_object('status','cancelled','replayed',v_row.status<>'pending');
end
$function$
;

CREATE OR REPLACE FUNCTION public.customer_create_gift_intent_v515(p_business uuid, p_gift_kind text, p_target uuid, p_idempotency_key uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'app', 'pg_temp'
AS $function$
declare
  v_actor uuid := auth.uid();
  v_kind text := lower(btrim(coalesce(p_gift_kind,'')));
  v_identity uuid; v_client uuid;
  v_existing public.customer_gift_intents_v515%rowtype;
  v_request_hash text; v_token text; v_id uuid := gen_random_uuid();
  v_label text; v_min_spend integer := 0; v_period_key text; v_terms jsonb := '{}'::jsonb;
  v_benefit public.tier_benefits_v365%rowtype;
  v_tier public.loyalty_tiers%rowtype;
  v_used integer;
begin
  if v_actor is null then
    raise exception 'authenticated customer session required' using errcode='28000';
  end if;
  if p_idempotency_key is null then
    raise exception 'idempotency key is required' using errcode='22023';
  end if;
  if v_kind not in ('welcome','bringback','referral','tier_perk') then
    raise exception 'unsupported gift kind' using errcode='22023';
  end if;
  if p_target is null then
    raise exception 'gift target is required' using errcode='22023';
  end if;

  select ci.id, l.client_id into v_identity, v_client
    from public.customer_identities ci
    join public.customer_links l
      on l.identity_id = ci.id and l.auth_user_id = v_actor and l.state = 'verified'
   where ci.auth_user_id = v_actor and ci.status = 'active' and l.business_id = p_business
   limit 1;
  if v_identity is null then
    raise exception 'verified customer link required' using errcode='42501';
  end if;
  if not app.v89_business_module_enabled(p_business,'loyalty') then
    raise exception 'this business is not running a customer programme' using errcode='42501';
  end if;

  v_request_hash := app.v89_sha256(p_business::text||':'||v_kind||':'||p_target::text);
  perform pg_advisory_xact_lock(hashtextextended(
    'v515:gift-intent:'||v_identity::text||':'||p_idempotency_key::text, 0));

  select * into v_existing from public.customer_gift_intents_v515 intent
   where intent.identity_id = v_identity and intent.idempotency_key = p_idempotency_key
   for update;
  if found then
    if v_existing.request_hash <> v_request_hash then
      raise exception 'idempotency key conflicts with another gift intent' using errcode='23505';
    end if;
    return jsonb_build_object('intent_id',v_existing.id,'status',v_existing.status,
      'gift_kind',v_existing.gift_kind,'reward_label',v_existing.quoted_label,
      'min_spend_cents',v_existing.quoted_min_spend_cents,
      'qr_token',app.v89_redemption_token(v_identity,p_business,
        v_existing.gift_kind||'_v515',coalesce(v_existing.grant_id,v_existing.benefit_id),
        p_idempotency_key),
      'expires_at',v_existing.expires_at,'replayed',true);
  end if;

  -- Stand down any stale pending QR for this same gift so open_uk cannot block a fresh one.
  update public.customer_gift_intents_v515
     set status='expired'
   where business_id=p_business and client_id=v_client and status='pending'
     and coalesce(grant_id,benefit_id)=p_target and expires_at<=now();

  if v_kind = 'welcome' then
    select g.reward_label, coalesce(g.min_spend_cents,0) into v_label, v_min_spend
      from public.welcome_offer_grants_v215 g
     where g.id=p_target and g.business_id=p_business and g.client_id=v_client
       and g.status='granted' and (g.expires_at is null or g.expires_at>now());
    if v_label is null then
      raise exception 'this welcome gift is not available' using errcode='22023';
    end if;
  elsif v_kind = 'bringback' then
    select g.reward_label into v_label
      from public.bringback_grants_v361 g
     where g.id=p_target and g.business_id=p_business and g.client_id=v_client
       and g.status='granted' and (g.expires_at is null or g.expires_at>now());
    if v_label is null then
      raise exception 'this bring-back voucher is not available' using errcode='22023';
    end if;
  elsif v_kind = 'referral' then
    select g.reward_label into v_label
      from public.referral_grants_v420 g
     where g.id=p_target and g.business_id=p_business and g.client_id=v_client
       and g.status='granted' and (g.expires_at is null or g.expires_at>now());
    if v_label is null then
      raise exception 'this referral gift is not available' using errcode='22023';
    end if;
  else
    select * into v_benefit from public.tier_benefits_v365 b
     where b.id=p_target and b.business_id=p_business and b.active and b.deleted_at is null;
    if not found then
      raise exception 'this perk is not available' using errcode='22023';
    end if;
    -- Owner ruling: an UNLIMITED automatic perk gets no QR — checkout already applies it.
    if v_benefit.limit_count is null then
      raise exception 'this perk is applied automatically at payment' using errcode='22023';
    end if;
    select * into v_tier from public.loyalty_tiers t
     where t.id=v_benefit.tier_id and t.business_id=p_business;
    if not found or coalesce(v_tier.paused,false) or v_tier.deleted_at is not null then
      raise exception 'this perk is not available' using errcode='22023';
    end if;
    if coalesce((select ct.threshold from app.v365_client_tier(p_business, v_client) ct), -1)
       < coalesce(v_tier.threshold, 0) then
      raise exception 'this perk belongs to a tier you have not reached' using errcode='22023';
    end if;
    if v_benefit.limit_period = 'birthday_month'
       and not app.v367_in_birthday_month(v_client, now()) then
      raise exception 'this perk is only available in your birthday month' using errcode='22023';
    end if;
    v_period_key := app.v365_period_key(v_benefit.limit_period, now());
    select count(*) into v_used from public.tier_benefit_issues_v365 i
     where i.benefit_id=v_benefit.id and i.client_id=v_client and i.period_key=v_period_key;
    if v_used >= v_benefit.limit_count then
      raise exception 'you have used this perk for this period' using errcode='22023';
    end if;
    v_label := v_benefit.label;
    v_terms := jsonb_build_object('limit_count',v_benefit.limit_count,
                 'limit_period',v_benefit.limit_period,'used',v_used);
  end if;

  insert into public.customer_gift_intents_v515(
    id, business_id, identity_id, auth_user_id, client_id, gift_kind,
    grant_id, benefit_id, quoted_label, quoted_min_spend_cents, quoted_period_key,
    quoted_terms, token_hash, idempotency_key, request_hash, expires_at
  ) values (
    v_id, p_business, v_identity, v_actor, v_client, v_kind,
    case when v_kind='tier_perk' then null else p_target end,
    case when v_kind='tier_perk' then p_target else null end,
    v_label, v_min_spend, v_period_key, v_terms,
    app.v89_sha256(app.v89_redemption_token(v_identity,p_business,v_kind||'_v515',p_target,p_idempotency_key)),
    p_idempotency_key, v_request_hash, now() + interval '15 minutes'
  );

  v_token := app.v89_redemption_token(v_identity,p_business,v_kind||'_v515',p_target,p_idempotency_key);
  return jsonb_build_object('intent_id',v_id,'status','pending','gift_kind',v_kind,
    'reward_label',v_label,'min_spend_cents',v_min_spend,
    'qr_token',v_token,'expires_at',now()+interval '15 minutes','replayed',false);
end
$function$
;

CREATE OR REPLACE FUNCTION public.customer_get_gift_intent_v515(p_intent uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'app', 'pg_temp'
AS $function$
declare v_actor uuid := auth.uid(); v_row public.customer_gift_intents_v515%rowtype;
begin
  if v_actor is null then
    raise exception 'authenticated customer session required' using errcode='28000';
  end if;
  select * into v_row from public.customer_gift_intents_v515
   where id = p_intent and auth_user_id = v_actor;
  if not found then
    raise exception 'gift intent not found' using errcode='42501';
  end if;
  return jsonb_build_object('intent_id',v_row.id,
    'status', case when v_row.status='pending' and v_row.expires_at<=now() then 'expired' else v_row.status end,
    'gift_kind',v_row.gift_kind,'reward_label',v_row.quoted_label,
    'min_spend_cents',v_row.quoted_min_spend_cents,'expires_at',v_row.expires_at,
    'result',v_row.completion_result);
end
$function$
;

CREATE OR REPLACE FUNCTION public.staff_scan_gift_qr_v515(p_business uuid, p_branch uuid, p_qr_token text, p_sale uuid, p_idempotency_key uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'app', 'pg_temp'
AS $function$
declare
  v_actor uuid := auth.uid();
  v_intent public.customer_gift_intents_v515%rowtype;
  v_benefit public.tier_benefits_v365%rowtype;
  v_period_now text;
  v_result jsonb;
  v_customer text;
begin
  if v_actor is null then
    raise exception 'authenticated staff required' using errcode='42501';
  end if;
  if p_qr_token is null or length(btrim(p_qr_token)) < 32 then
    raise exception 'gift QR is invalid' using errcode='22023';
  end if;
  if p_idempotency_key is null then
    raise exception 'idempotency key is required' using errcode='22023';
  end if;

  perform pg_advisory_xact_lock(hashtextextended(
    'v515:scan:'||p_business::text||':'||app.v89_sha256(p_qr_token), 0));

  select * into v_intent from public.customer_gift_intents_v515
   where business_id = p_business and token_hash = app.v89_sha256(p_qr_token)
   for update;
  if not found then
    raise exception 'gift QR is invalid' using errcode='22023';
  end if;

  if v_intent.status = 'completed' then
    return coalesce(v_intent.completion_result,'{}'::jsonb) || jsonb_build_object('replayed',true);
  end if;
  if v_intent.status in ('expired','cancelled') then
    return jsonb_build_object('status',v_intent.status,'gift_kind',v_intent.gift_kind,
      'reward_label',v_intent.quoted_label);
  end if;
  if v_intent.expires_at <= now() then
    update public.customer_gift_intents_v515 set status='expired' where id=v_intent.id;
    return jsonb_build_object('status','expired','gift_kind',v_intent.gift_kind,
      'reward_label',v_intent.quoted_label);
  end if;

  -- The quote re-check, the analogue of v117's `current quote is distinct from quoted_terms`.
  -- A perk QR minted at 23:58 on the 31st must not silently spend NEXT period's allowance.
  if v_intent.gift_kind = 'tier_perk' then
    select * into v_benefit from public.tier_benefits_v365 where id = v_intent.benefit_id;
    if not found then
      raise exception 'this perk no longer exists' using errcode='23514';
    end if;
    v_period_now := app.v365_period_key(v_benefit.limit_period, now());
    if v_period_now is distinct from v_intent.quoted_period_key then
      raise exception 'this perk''s period rolled over; ask the customer for a new QR'
        using errcode='23514';
    end if;
  end if;

  if v_intent.gift_kind = 'welcome' then
    v_result := public.staff_redeem_welcome_offer_v215(
      p_business, v_intent.client_id, p_branch, p_sale, 'v515:'||v_intent.id::text);
  elsif v_intent.gift_kind = 'bringback' then
    v_result := public.staff_redeem_bringback_v361(
      p_business, v_intent.client_id, p_branch, v_intent.grant_id);
  elsif v_intent.gift_kind = 'referral' then
    v_result := public.staff_redeem_referral_v420(
      p_business, v_intent.client_id, p_branch, v_intent.grant_id);
  else
    -- The intent id as the key is LOAD-BEARING: staff_issue_tier_benefit_v365 turns a NULL key
    -- into a fresh uuid, which would burn a second allowance instead of replaying.
    v_result := public.staff_issue_tier_benefit_v365(
      p_business, v_intent.client_id, v_intent.benefit_id, p_branch, v_intent.id);
  end if;

  select c.full_name into v_customer from public.clients c where c.id = v_intent.client_id;

  v_result := coalesce(v_result,'{}'::jsonb) || jsonb_build_object(
    'status','completed','gift_kind',v_intent.gift_kind,
    'reward_label',v_intent.quoted_label,'customer_name',v_customer,
    'branch_id',p_branch,'intent_id',v_intent.id);

  update public.customer_gift_intents_v515
     set status='completed', completed_at=now(), completed_by=v_actor, completion_result=v_result
   where id = v_intent.id;

  return v_result;
end
$function$
;

revoke all on function public.customer_create_gift_intent_v515(uuid,text,uuid,uuid) from public, anon;
grant execute on function public.customer_create_gift_intent_v515(uuid,text,uuid,uuid) to authenticated;
revoke all on function public.customer_get_gift_intent_v515(uuid) from public, anon;
grant execute on function public.customer_get_gift_intent_v515(uuid) to authenticated;
revoke all on function public.customer_cancel_gift_intent_v515(uuid,uuid) from public, anon;
grant execute on function public.customer_cancel_gift_intent_v515(uuid,uuid) to authenticated;
revoke all on function public.staff_scan_gift_qr_v515(uuid,uuid,text,uuid,uuid) from public, anon;
grant execute on function public.staff_scan_gift_qr_v515(uuid,uuid,text,uuid,uuid) to authenticated;

commit;
