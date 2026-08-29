begin;

-- ============================================================================
-- nestly_v612 — the join sheet's referral code pays BOTH sides, and pays NOW
--               when the programme sets no spending requirement.
--
-- Owner ruling (2026-08-30, after the join-QR flow went live on the real
-- device): "this pop up please allow user to key in referral code so both
-- parties get the rewards. either immediately if no requirements or receive
-- voucher once requirements (spending) is achieved."
--
-- What exists already: customer_apply_referral_code_v571 records the referral
-- as status='pending', and app.on_sale_recorded REGION B (v425) settles it —
-- BOTH sides, by declared reward kind — on the referred customer's first
-- REAL sale at or above min_spend_cents. That engine is untouched.
--
-- What this adds: customer_apply_referral_code_v612, the same application
-- guardrail-for-guardrail, plus ONE new behaviour — when the programme's
-- min_spend_cents is 0 ("no requirements"), the referral settles IMMEDIATELY
-- at application, both sides, mirroring REGION B's own semantics:
--   · voucher  → status 'rewarded' + one referral_grants_v420 row per side
--                (the same once-per-side unique index makes replays no-ops);
--   · points/stamps → status 'rewarded' + ledger row + batch per side, on the
--                pot of the DECLARED kind via referral_payout_programme_v425;
--                fail CLOSED with blocked_reason when that pot is off or the
--                amount is unset — the referral stays pending and REGION B
--                settles it the day the firm fixes its configuration.
-- The v425 ruling "a $0 SALE never qualifies a referral" is not weakened: no
-- sale is involved here at all. A floor > 0 keeps today's exact behaviour and
-- the reply says so (settled='on_spend' + the floor), so the sheet can tell
-- the customer which of the two worlds they are in.
--
-- v571 remains deployed and callable for clients shipped before this deploy.
-- ============================================================================

-- An immediate settle has NO qualifying sale, and that is the truth the evidence must be able
-- to record. The v480 provenance capture already writes referrals.qualified_sale_id verbatim;
-- only the NOT NULL stood in the way. The one reader, app.reverse_sale_with_loyalty_v480,
-- matches provenance BY the reversed sale's id — a null row can never be swept into a
-- reversal, which is exactly right: there is no sale whose reversal should claw this back.
alter table app.referral_value_provenance_v480 alter column qualifying_sale_id drop not null;

-- The two provenance captures learn the no-sale settle. The batch capture matched its ledger
-- row with `qualifying_sale_id = v_ref.qualified_sale_id`, and null = null is never true in
-- SQL — a null-safe match is the whole change. The grant capture flatly refused a null sale;
-- it now records the referral's own qualified_sale_id verbatim (null when settled at
-- application), with the same not-found integrity refusal it always had.
create or replace function app.capture_referral_batch_v480()
returns trigger
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $function$
declare v_ref public.referrals%rowtype; v_rows integer;
begin
  if new.referral_id is null then return new; end if;
  select * into v_ref from public.referrals
   where id=new.referral_id and business_id=new.business_id and status='rewarded';
  if not found then raise exception 'referral payout batch has no qualifying referral' using errcode='XX001'; end if;
  update app.referral_value_provenance_v480
     set batch_id=new.id
   where referral_id=v_ref.id and qualifying_sale_id is not distinct from v_ref.qualified_sale_id
     and beneficiary=new.referral_beneficiary and business_id=new.business_id
     and client_id=new.client_id and programme_id=new.programme_id and amount=new.earned
     and batch_id is null;
  get diagnostics v_rows=row_count;
  if v_rows<>1 then raise exception 'referral payout batch has no unique ledger provenance' using errcode='XX001'; end if;
  return new;
end $function$;
revoke all on function app.capture_referral_batch_v480() from public, anon, authenticated;

create or replace function app.capture_referral_grant_v480()
returns trigger
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $function$
declare v_ref public.referrals%rowtype;
begin
  select * into v_ref from public.referrals
   where id=new.referral_id and business_id=new.business_id and status='rewarded';
  if not found then raise exception 'referral voucher has no qualifying referral' using errcode='XX001'; end if;
  -- nestly_v612: a referral settled at application (no spend requirement) has no qualifying
  -- sale; null is the truthful value, and the reversal engine matches by sale id so a null
  -- row can never be swept into a sale reversal.
  insert into app.referral_value_provenance_v480(
    business_id,referral_id,qualifying_sale_id,beneficiary,client_id,benefit_kind,grant_id
  ) values(new.business_id,new.referral_id,v_ref.qualified_sale_id,new.beneficiary,new.client_id,'voucher',new.id);
  return new;
end $function$;
revoke all on function app.capture_referral_grant_v480() from public, anon, authenticated;

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

  -- ── nestly_v612: no spending requirement → settle now, both sides ─────────
  if coalesce(v_prog.min_spend_cents, 0) > 0 then
    return jsonb_build_object('applied', true, 'reason', 'ok', 'referral_id', v_referral,
                              'settled', 'on_spend',
                              'min_spend_cents', v_prog.min_spend_cents);
  end if;

  -- The loyalty ledgers sit behind the v480 transaction fence, exactly as they do for the
  -- sale trigger; an immediate settle is a loyalty value write and takes the same lock.
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

commit;
