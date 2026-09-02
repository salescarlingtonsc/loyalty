-- NESTLY v676 — re-tapping "Show QR at counter" reopens the pending gift QR.
--
-- Audit findings F048 (client) / F056 (server), both P1/CONFIRMED, one defect.
--
-- What was wrong: customer_create_gift_intent_v515 (v515a, last rewritten by v665) knows only
-- ONE kind of replay — the same idempotency key from the same identity. Its stand-down only
-- expires pending rows whose expires_at has ALREADY passed. So a customer who closed the QR
-- sheet by any route except the red "Cancel redemption" — the labelled "Close — keep pending"
-- button, the X, Escape, a backdrop tap, Android Back, or simply navigating away — left a live
-- pending row behind, and the next tap on the same gift arrived with a fresh key, missed the
-- replay branch, survived the stand-down, and hit the partial unique index
--   customer_gift_intents_v515_open_uk (business_id, gift_kind, coalesce(grant_id,benefit_id),
--                                       client_id) where status='pending'
-- with SQLSTATE 23505. The app has no friendly sentence for that, so the customer saw
-- "This gift could not be prepared right now. Please try again." on every retry for the
-- remainder of the 15-minute TTL, with nothing for the counter to scan.
--
-- What this changes, and what it deliberately does not:
--
--   1. A still-live pending QR for the SAME gift, held by the SAME signed-in customer, is now
--      REOPENED: the same intent id, the same qr_token, the same expires_at, replayed=true.
--      The token is re-derived from the STORED row (its identity and its own idempotency key),
--      so it hashes to the token_hash already on the row and the counter's scanner accepts it.
--      Nothing new is inserted, no TTL is extended, no quota moves — this is the row the
--      customer already has, handed back.
--
--   2. The one-pending-per-GIFT rule is unchanged. The reopen lookup matches the open_uk index
--      column for column (business, gift_kind, target, client), so a second pending intent for a
--      DIFFERENT gift still mints normally and a second pending intent for the SAME gift is
--      still impossible. This is not "one pending intent per customer" and never was.
--
--   3. A per-gift advisory lock is taken before the lookup. The existing lock is keyed on
--      (identity, idempotency_key), which is exactly the wrong key for this race: two re-taps
--      carry two DIFFERENT keys, so they did not serialise against each other and both could
--      reach the insert. Locking the gift makes reopen-or-insert atomic.
--
--   4. The insert keeps a unique_violation handler as the floor. With the lock above, the only
--      way to reach it is a pending row for this client held by a DIFFERENT login (a second
--      verified auth user on the same client record). That row is not ours to hand over —
--      customer_get_gift_intent_v515 and customer_cancel_gift_intent_v515 both gate on
--      auth_user_id = auth.uid(), so returning it would produce a QR the holder could neither
--      poll nor cancel. It becomes a sentence the app can show instead of a raw 23505.
--
-- Nothing else in the function moves: the same eligibility rules, the same four gift families,
-- the same 15-minute TTL, the same refusal of an unlimited automatic perk, the same grants.

begin;

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
  -- v676: and a SECOND lock on the gift itself. The lock above is keyed on the idempotency key,
  -- so two re-taps (two different keys) never serialised against each other; this one is what
  -- makes the reopen-or-insert below atomic for the row open_uk actually protects.
  perform pg_advisory_xact_lock(hashtextextended(
    'v676:gift-target:'||p_business::text||':'||v_client::text||':'||v_kind||':'||p_target::text, 0));

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

  /* v676 (F048/F056): a STILL-LIVE pending QR for this same gift is the customer's own QR — they
     closed the sheet and came back. Hand the same one back rather than raising 23505 at them.
     The lookup matches open_uk column for column, plus auth_user_id, because the poll and cancel
     RPCs both gate on auth.uid() and a QR its holder cannot cancel would be worse than none. */
  select * into v_existing from public.customer_gift_intents_v515 intent
   where intent.business_id = p_business
     and intent.client_id = v_client
     and intent.gift_kind = v_kind
     and coalesce(intent.grant_id, intent.benefit_id) = p_target
     and intent.status = 'pending'
     and intent.expires_at > now()
     and intent.auth_user_id = v_actor
   for update;
  if found then
    return jsonb_build_object('intent_id',v_existing.id,'status',v_existing.status,
      'gift_kind',v_existing.gift_kind,'reward_label',v_existing.quoted_label,
      'min_spend_cents',v_existing.quoted_min_spend_cents,
      'qr_token',app.v89_redemption_token(v_existing.identity_id,p_business,
        v_existing.gift_kind||'_v515',coalesce(v_existing.grant_id,v_existing.benefit_id),
        v_existing.idempotency_key),
      'expires_at',v_existing.expires_at,'replayed',true);
  end if;

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
     where i.benefit_id=v_benefit.id and i.client_id=v_client and i.period_key=v_period_key
       and i.reversed_at is null;
    if v_used >= v_benefit.limit_count then
      raise exception 'you have used this perk for this period' using errcode='22023';
    end if;
    v_label := v_benefit.label;
    v_terms := jsonb_build_object('limit_count',v_benefit.limit_count,
                 'limit_period',v_benefit.limit_period,'used',v_used);
  end if;

  begin
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
  exception when unique_violation then
    /* v676: the floor under the reopen. Past the gift lock, the only row that can still hold
       open_uk is a live pending QR on this client held by ANOTHER verified login — and that one
       is not ours to hand over, because its holder is the only principal who may poll or cancel
       it. Say so in a sentence the customer can act on instead of a raw constraint name. */
    raise exception 'this gift already has a QR open at the counter — use it, or wait for it to expire'
      using errcode='22023';
  end;

  v_token := app.v89_redemption_token(v_identity,p_business,v_kind||'_v515',p_target,p_idempotency_key);
  return jsonb_build_object('intent_id',v_id,'status','pending','gift_kind',v_kind,
    'reward_label',v_label,'min_spend_cents',v_min_spend,
    'qr_token',v_token,'expires_at',now()+interval '15 minutes','replayed',false);
end
$function$
;

-- The live ACL, restated verbatim so this migration cannot widen it by omission.
revoke all on function public.customer_create_gift_intent_v515(uuid,text,uuid,uuid)
  from public, anon;
grant execute on function public.customer_create_gift_intent_v515(uuid,text,uuid,uuid)
  to authenticated, service_role;

commit;
