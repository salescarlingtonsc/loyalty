/* nestly_v683 — a referral pays only for a customer who is NEW to that business.

   Audit finding F025 (P2, confirmed against production read-only on 2026-09-02).

   THE DEFECT
     public.customer_apply_referral_code_v612 (and its still-deployed predecessor
     public.customer_apply_referral_code_v571) check that the code exists, that it is not the
     caller's own, and that the caller has not been referred before. Nothing anywhere asks whether
     the referred customer is NEW. The wallet context they run behind
     (app.v32_customer_wallet_context) is satisfied by any verified link, of any tenure, so a
     member of three years with a hundred paid sales passes every guard.

     Two live paths reach it without the customer meaning to invoke anything:
       · the share link #/wallet/<slug>?ref=<CODE> — the router stores the code (app.js
         rememberShareReferralV576) and every subsequent wallet render auto-applies it
         (applyShareReferralV576);
       · the join sheet, which applies a typed code after outcomes 'linked' / 'already_joined',
         i.e. for somebody who was already a member.

     With min_spend_cents = 0 the v612 immediate settle pays BOTH sides at once — points/stamps
     ledger rows or referral_grants_v420 vouchers, with no sale anywhere in the story. With a floor
     the referral sits 'pending' and app.on_sale_recorded REGION B pays both sides on the existing
     regular's very next ordinary purchase. Two long-standing customers can therefore pay each
     other, and no new customer is acquired.

     Every surface promises the opposite: the grow summary says "Paid: After the friend's first
     qualifying visit — never at sign-up", the customer card says the reward follows the friend's
     first spend, and the business copy says "When a new customer joins…".

   THE RULE (owner-facing, one sentence)
     A referral is attributable only when the referred client is new to that business: they have
     NO prior paid sale there, and their verified membership is not older than the join window.

     · "no prior paid sale" is deliberately BROADER than the counts_as_visit predicate
       app.client_qualifying_visits_v677 uses. A gift-card or package purchase is not a visit, but
       it is unmistakably the act of an existing customer. A sale that has been reversed does not
       count (nestly_v677's own rule: a refunded sale is not history the customer keeps), and a
       reversal row is never itself a purchase.
     · "verified membership not older than the join window" is what refuses the member who joined
       months ago and never bought anything — the business has already acquired them, so nobody
       should be paid for introducing them. The window is REFERRAL_NEW_JOIN_WINDOW = 7 days, wide
       enough for every real journey (the join sheet applies a code seconds after joining; a share
       link applies it on the first wallet render after registration) and far short of the tenure
       this defect was paying out on. Membership starts when the link is VERIFIED, so the age is
       measured from coalesce(verified_at, created_at).

   WHAT THIS MIGRATION DOES
     1. app.referral_referred_is_new_v683(business, client) — one authority for "is this client new
        to this business", so the two RPCs cannot drift apart. app-schema, no API grant.
     2. public.customer_apply_referral_code_v612 and public.customer_apply_referral_code_v571 ask
        it before creating a referral, and refuse a non-new customer with errcode 22023 and a
        message the customer can read: "Referral codes are for new customers of this business."
        Nothing else in either function changes — the v612 immediate settle, the fail-closed pot
        handling, the reply shape and every existing reason string are byte-for-byte the ones that
        are live today.
     3. Both functions now resolve an EXISTING referral for the caller BEFORE the new-customer gate
        (a read of public.referrals, then the same insert with the same on-conflict race guard).
        This is what keeps a replay idempotent: a customer who was legitimately attributed as a new
        member and later spends money must keep getting 'already_applied' from the wallet's
        fire-and-forget re-apply, not a refusal that says they are not new.

   WHAT THIS MIGRATION DELIBERATELY DOES NOT DO
     · app.on_sale_recorded REGION B is untouched. The obvious-looking symmetric check — "refuse to
       settle when the referred client already had a sale" — would break the promise it implements:
       the payout is due on the friend's first QUALIFYING sale, and a friend whose first purchase
       was below the floor legitimately settles on a later one. Attribution is where newness is
       decidable, and it is now decided there. Every pending referral in production today was
       attributed to a client with zero prior sales, so nothing in flight changes meaning.
     · public.staff_create_client is untouched: it inserts the referral in the same statement block
       that CREATES the client, so it is structurally new-customer-only already.

   Rollback suite: db/tests/v683_referral_new_customers_only.sql
*/

begin;

-- ─────────────────────────────────────────────────────── 1. one authority for "is this client new"
create or replace function app.referral_referred_is_new_v683(p_business uuid, p_client uuid)
returns boolean
language sql
stable
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $function$
  select p_business is not null
     and p_client is not null
     -- No paid sale they still keep. A reversal row is not a purchase (reversal_of is not null),
     -- and an original that has since been reversed is not one either.
     and not exists (
       select 1
         from public.sales s
        where s.business_id = p_business
          and s.client_id = p_client
          and s.reversal_of is null
          and coalesce(s.amount_cents, 0) > 0
          and not exists (
            select 1 from public.sales r
             where r.business_id = s.business_id and r.reversal_of = s.id
          )
     )
     -- And not a member of longer standing than the join window. Membership starts at
     -- verification; created_at is the fallback for a row that carries no verified_at.
     and not exists (
       select 1
         from public.customer_links l
        where l.business_id = p_business
          and l.client_id = p_client
          and l.state = 'verified'
          and coalesce(l.verified_at, l.created_at) < now() - interval '7 days'
     );
$function$;

comment on function app.referral_referred_is_new_v683(uuid, uuid) is
  'nestly_v683 — true when this client may be attributed as a referred NEW customer of this '
  'business: no paid sale they still keep, and no verified membership older than 7 days. The one '
  'authority for the rule; customer_apply_referral_code_v571/v612 both ask it.';

revoke all on function app.referral_referred_is_new_v683(uuid, uuid) from public, anon, authenticated;

-- ──────────────────────────────────────────── 2. the live RPC: refuse an existing customer, 22023
create or replace function public.customer_apply_referral_code_v612(p_business_slug text, p_code text, p_idempotency_key uuid)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $function$
declare
  v_actor uuid := auth.uid();
  v_context record;
  v_code text := nullif(upper(btrim(coalesce(p_code, ''))), '');
  v_referrer uuid;
  v_existing_referrer uuid;
  v_referral uuid;
  v_prog public.referral_programs%rowtype;
  v_ref_kind text;
  v_ref_points integer;
  v_friend_on boolean;
  v_friend_points integer;
  v_ref_pot uuid;
  v_blocked text;
  v_expires timestamptz;
  v_refcfg record;
  v_earn_id uuid;
  v_friend_earn_id uuid;
  v_settled text;
begin
  if v_actor is null then
    raise exception 'authenticated customer session required' using errcode = '28000';
  end if;
  if p_idempotency_key is null then
    raise exception 'invalid referral request' using errcode = '22023';
  end if;
  if v_code is null then
    return jsonb_build_object('applied', false, 'reason', 'empty');
  end if;
  if char_length(v_code) > 32 then
    return jsonb_build_object('applied', false, 'reason', 'unknown_code');
  end if;

  select context.identity_id, context.business_id, context.client_id
    into v_context
    from app.v32_customer_wallet_context(p_business_slug) context
   limit 1;
  if not found then
    raise exception 'verified customer link required' using errcode = '42501';
  end if;

  select * into v_prog
    from public.referral_programs rp
   where rp.business_id = v_context.business_id;
  if not coalesce(v_prog.enabled, false) then
    return jsonb_build_object('applied', false, 'reason', 'referrals_off');
  end if;

  select c.id into v_referrer
    from public.clients c
   where c.business_id = v_context.business_id
     and c.referral_code = v_code
   limit 1
   for share;
  if v_referrer is null then
    return jsonb_build_object('applied', false, 'reason', 'unknown_code');
  end if;
  if v_referrer = v_context.client_id then
    return jsonb_build_object('applied', false, 'reason', 'self_referral');
  end if;

  -- nestly_v683: an ALREADY attributed customer is answered before the new-customer gate. The
  -- wallet re-applies a stored code on every render; once the friend has spent money they are no
  -- longer "new", and a replay must still say 'already_applied' rather than refuse them.
  select r.id, r.referrer_client_id
    into v_referral, v_existing_referrer
    from public.referrals r
   where r.referred_client_id = v_context.client_id;
  if v_referral is not null then
    if v_existing_referrer = v_referrer then
      return jsonb_build_object('applied', true, 'reason', 'already_applied',
                                'referral_id', v_referral);
    end if;
    return jsonb_build_object('applied', false, 'reason', 'already_referred',
                              'referral_id', v_referral);
  end if;

  -- nestly_v683 (audit F025): a referral is for a NEW customer of this business. Two existing
  -- members could otherwise attribute each other and — with no spending floor — be paid on the
  -- spot, for an acquisition that never happened.
  if not app.referral_referred_is_new_v683(v_context.business_id, v_context.client_id) then
    raise exception 'Referral codes are for new customers of this business' using errcode = '22023';
  end if;

  insert into public.referrals (
    business_id, referrer_client_id, referred_client_id, status
  ) values (
    v_context.business_id, v_referrer, v_context.client_id, 'pending'
  )
  on conflict (referred_client_id) where referred_client_id is not null do nothing
  returning id into v_referral;

  if v_referral is null then
    -- The read above lost a race with a concurrent application; answer it the same way.
    select r.id, r.referrer_client_id
      into v_referral, v_existing_referrer
      from public.referrals r
     where r.referred_client_id = v_context.client_id;
    if v_existing_referrer = v_referrer then
      return jsonb_build_object('applied', true, 'reason', 'already_applied',
                                'referral_id', v_referral);
    end if;
    return jsonb_build_object('applied', false, 'reason', 'already_referred',
                              'referral_id', v_referral);
  end if;

  -- ── nestly_v612: no spending requirement → settle now, both sides ─────────
  if coalesce(v_prog.min_spend_cents, 0) > 0 then
    return jsonb_build_object('applied', true, 'reason', 'ok', 'referral_id', v_referral,
                              'settled', 'on_spend',
                              'min_spend_cents', v_prog.min_spend_cents);
  end if;

  -- The loyalty ledgers sit behind the v480 transaction fence, exactly as they do for the sale
  -- trigger; an immediate settle is a loyalty value write and takes the same lock.
  perform app.acquire_loyalty_shared_v480(v_context.business_id);
  v_ref_kind := lower(btrim(coalesce(v_prog.reward_kind, 'points')));
  v_ref_points := coalesce(v_prog.reward_points, 0);
  v_friend_on := coalesce(v_prog.friend_enabled, true);
  v_friend_points := coalesce(v_prog.friend_reward_points, v_ref_points, 0);
  v_ref_pot := case when v_ref_kind in ('points','stamps')
                    then app.referral_payout_programme_v425(v_context.business_id, v_ref_kind) end;
  v_settled := 'blocked';

  if v_ref_kind = 'voucher' then
    update public.referrals set status = 'rewarded', qualified_at = now(),
           qualified_sale_id = null, blocked_reason = null
     where id = v_referral and status = 'pending';
    if found then
      -- The v421 once-per-side unique index makes any replay a no-op, exactly
      -- as it does for the sale-trigger path.
      insert into public.referral_grants_v420(business_id, client_id, referral_id, beneficiary, reward_label)
      values (v_context.business_id, v_referrer, v_referral, 'referrer',
              coalesce(nullif(btrim(v_prog.reward_label), ''), 'Referral gift'));
      if v_friend_on then
        insert into public.referral_grants_v420(business_id, client_id, referral_id, beneficiary, reward_label)
        values (v_context.business_id, v_context.client_id, v_referral, 'friend',
                coalesce(nullif(btrim(v_prog.friend_reward_label), ''),
                         nullif(btrim(v_prog.reward_label), ''), 'Referral gift'));
      end if;
      v_settled := 'immediate';
    end if;
  elsif v_ref_kind in ('points','stamps') then
    if v_ref_pot is null or v_ref_points <= 0 then
      -- FAIL CLOSED, verbatim REGION B (owner decision C): the referral stays
      -- pending and claimable the day the firm fixes its configuration.
      v_blocked := case when v_ref_pot is null
                        then 'reward_kind_' || v_ref_kind || '_requires_active_' || v_ref_kind || '_programme'
                        else 'reward_amount_not_set' end;
      update public.referrals set blocked_reason = v_blocked
       where id = v_referral and status = 'pending' and blocked_reason is distinct from v_blocked;
    else
      update public.referrals set status = 'rewarded', qualified_at = now(),
             qualified_sale_id = null, reward_points = v_ref_points, blocked_reason = null
       where id = v_referral and status = 'pending';
      if found then
        v_expires := null;
        -- Expiry is a POINTS policy, never a stamps one (REGION B's own rule).
        -- No sale exists, so the config is the business's active one, no branch.
        if v_ref_kind = 'points' then
          select * into v_refcfg from app.resolve_loyalty_branch_config(v_context.business_id, null, null);
          if found and v_refcfg.expiry_mode = 'fixed' then
            v_expires := now() + make_interval(days => v_refcfg.expiry_days);
          end if;
        end if;
        v_earn_id := gen_random_uuid();
        perform set_config('app.points_ledger_insert_id', v_earn_id::text, true);
        perform set_config('app.points_ledger_write_scope', 'referral_reward_points', true);
        insert into public.points_ledger(id, business_id, client_id, entry_type, points, sale_id, reference, actor, programme_id, referral_id, referral_beneficiary)
        values (v_earn_id, v_context.business_id, v_referrer, 'earn', v_ref_points, null,
                'referral applied: no spend requirement', v_actor, v_ref_pot, v_referral, 'referrer');
        perform set_config('app.points_ledger_insert_id', '', true);
        perform set_config('app.points_ledger_write_scope', '', true);
        insert into public.points_batches(business_id, client_id, earned, remaining, sale_id, earned_at, expires_at, programme_id, referral_id, referral_beneficiary)
        values (v_context.business_id, v_referrer, v_ref_points, v_ref_points, null, now(), v_expires, v_ref_pot, v_referral, 'referrer');
        perform app.emit_referral_qualified_v322(v_context.business_id, v_referral, v_referrer, v_context.client_id, v_ref_points, v_earn_id, now(), null);
        if v_friend_on and v_friend_points > 0 then
          v_friend_earn_id := gen_random_uuid();
          perform set_config('app.points_ledger_insert_id', v_friend_earn_id::text, true);
          perform set_config('app.points_ledger_write_scope', 'referral_reward_points', true);
          insert into public.points_ledger(id, business_id, client_id, entry_type, points, sale_id, reference, actor, programme_id, referral_id, referral_beneficiary)
          values (v_friend_earn_id, v_context.business_id, v_context.client_id, 'earn', v_friend_points, null,
                  'referral applied: introduced by a friend', v_actor, v_ref_pot, v_referral, 'friend');
          perform set_config('app.points_ledger_insert_id', '', true);
          perform set_config('app.points_ledger_write_scope', '', true);
          insert into public.points_batches(business_id, client_id, earned, remaining, sale_id, earned_at, expires_at, programme_id, referral_id, referral_beneficiary)
          values (v_context.business_id, v_context.client_id, v_friend_points, v_friend_points, null, now(), v_expires, v_ref_pot, v_referral, 'friend');
        end if;
        v_settled := 'immediate';
      end if;
    end if;
  else
    v_blocked := 'reward_kind_unrecognised';
    update public.referrals set blocked_reason = v_blocked
     where id = v_referral and status = 'pending' and blocked_reason is distinct from v_blocked;
  end if;

  return jsonb_build_object('applied', true, 'reason', 'ok', 'referral_id', v_referral,
                            'settled', v_settled, 'min_spend_cents', 0);
end;
$function$;

revoke all on function public.customer_apply_referral_code_v612(text, text, uuid) from public, anon;
grant execute on function public.customer_apply_referral_code_v612(text, text, uuid) to authenticated, service_role;

-- ───────────────────────── 3. the predecessor RPC, still callable by any bundle shipped pre-v612
create or replace function public.customer_apply_referral_code_v571(p_business_slug text, p_code text, p_idempotency_key uuid)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $function$
declare
  v_actor uuid := auth.uid();
  v_context record;
  v_code text := nullif(upper(btrim(coalesce(p_code, ''))), '');
  v_referrer uuid;
  v_existing_referrer uuid;
  v_referral uuid;
  v_enabled boolean;
begin
  if v_actor is null then
    raise exception 'authenticated customer session required' using errcode = '28000';
  end if;
  if p_idempotency_key is null then
    raise exception 'invalid referral request' using errcode = '22023';
  end if;
  if v_code is null then
    return jsonb_build_object('applied', false, 'reason', 'empty');
  end if;
  if char_length(v_code) > 32 then
    return jsonb_build_object('applied', false, 'reason', 'unknown_code');
  end if;

  select context.identity_id, context.business_id, context.client_id
    into v_context
    from app.v32_customer_wallet_context(p_business_slug) context
   limit 1;
  if not found then
    raise exception 'verified customer link required' using errcode = '42501';
  end if;

  select rp.enabled into v_enabled
    from public.referral_programs rp
   where rp.business_id = v_context.business_id;
  if not coalesce(v_enabled, false) then
    return jsonb_build_object('applied', false, 'reason', 'referrals_off');
  end if;

  select c.id into v_referrer
    from public.clients c
   where c.business_id = v_context.business_id
     and c.referral_code = v_code
   limit 1
   for share;
  if v_referrer is null then
    return jsonb_build_object('applied', false, 'reason', 'unknown_code');
  end if;
  if v_referrer = v_context.client_id then
    return jsonb_build_object('applied', false, 'reason', 'self_referral');
  end if;

  -- nestly_v683: answer an already-attributed customer before the new-customer gate, so a replay
  -- stays idempotent for the rest of that customer's life with the business.
  select r.id, r.referrer_client_id
    into v_referral, v_existing_referrer
    from public.referrals r
   where r.referred_client_id = v_context.client_id;
  if v_referral is not null then
    if v_existing_referrer = v_referrer then
      return jsonb_build_object('applied', true, 'reason', 'already_applied',
                                'referral_id', v_referral);
    end if;
    return jsonb_build_object('applied', false, 'reason', 'already_referred',
                              'referral_id', v_referral);
  end if;

  -- nestly_v683 (audit F025): the same new-customer rule the live v612 RPC enforces, so an older
  -- bundle cannot be the way round it.
  if not app.referral_referred_is_new_v683(v_context.business_id, v_context.client_id) then
    raise exception 'Referral codes are for new customers of this business' using errcode = '22023';
  end if;

  insert into public.referrals (
    business_id, referrer_client_id, referred_client_id, status
  ) values (
    v_context.business_id, v_referrer, v_context.client_id, 'pending'
  )
  on conflict (referred_client_id) where referred_client_id is not null do nothing
  returning id into v_referral;

  if v_referral is null then
    select r.id, r.referrer_client_id
      into v_referral, v_existing_referrer
      from public.referrals r
     where r.referred_client_id = v_context.client_id;
    if v_existing_referrer = v_referrer then
      return jsonb_build_object('applied', true, 'reason', 'already_applied',
                                'referral_id', v_referral);
    end if;
    return jsonb_build_object('applied', false, 'reason', 'already_referred',
                              'referral_id', v_referral);
  end if;

  return jsonb_build_object('applied', true, 'reason', 'ok', 'referral_id', v_referral);
end;
$function$;

revoke all on function public.customer_apply_referral_code_v571(text, text, uuid) from public, anon;
grant execute on function public.customer_apply_referral_code_v571(text, text, uuid) to authenticated, service_role;

commit;
