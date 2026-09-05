-- nestly_v777 — the referred friend can see the reward they are working towards.
--
-- OWNER, 2026-09-05 (photos 1-3): "once joined the referral code > join the business > i need a
-- pop up to tell user the rewards (in this case spend $5 to receive extra 50 points). it can
-- stay inside the Points & gifts module until the rewards is given then remove it away".
--
-- One read, answered from the row app.on_sale_recorded REGION B actually pays from: the
-- customer's own public.referrals row at this business. While it is 'pending' the card shows the
-- floor (a single sale of at least min_spend_cents — REGION B is per sale, not cumulative) and
-- the friend's points, resolved exactly as customer_get_referral_card_v300 resolves them; once
-- REGION B has paid ('rewarded') or the firm has switched the programme off, the card goes.
-- 'blocked_reason' (the programme's pot is missing) is surfaced so the customer is not promised
-- points the till cannot pay.

begin;

create or replace function public.customer_get_referral_pending_v777(p_business_slug text)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $function$
declare
  v_actor uuid := auth.uid();
  v_context record;
  v_ref public.referrals%rowtype;
  v_program record;
  v_referrer text;
  v_friend_points integer;
begin
  if v_actor is null then
    raise exception 'authenticated customer session required' using errcode = '28000';
  end if;
  if not app.platform_feature_enabled('customer_wallet') then
    raise exception 'customer wallet is not enabled' using errcode = '0A000';
  end if;
  select identity_id, business_id, client_id, business_currency, enabled_modules
    into v_context
    from app.v32_customer_wallet_context(p_business_slug)
   limit 1;
  if not found then
    raise exception 'verified customer link required' using errcode = '42501';
  end if;
  select r.* into v_ref from public.referrals r
   where r.business_id = v_context.business_id and r.referred_client_id = v_context.client_id
   order by r.created_at desc limit 1;
  if not found then
    return jsonb_build_object('pending', false, 'status', 'none');
  end if;
  if v_ref.status <> 'pending' then
    return jsonb_build_object('pending', false, 'status', v_ref.status,
      'reward_points', coalesce(v_ref.reward_points, 0), 'qualified_at', v_ref.qualified_at);
  end if;
  select rp.enabled, rp.reward_points, rp.reward_kind, rp.reward_label,
         rp.min_spend_cents, rp.friend_enabled, rp.friend_reward_points, rp.friend_reward_label
    into v_program
    from public.referral_programs rp where rp.business_id = v_context.business_id limit 1;
  if not found or not coalesce(v_program.enabled, false)
     or 'referrals' <> all(coalesce(v_context.enabled_modules, '{}'::text[])) then
    return jsonb_build_object('pending', false, 'status', 'programme_off');
  end if;
  v_friend_points := case when coalesce(v_program.friend_enabled, true)
    then coalesce(v_program.friend_reward_points, v_program.reward_points, 0) else 0 end;
  select split_part(btrim(coalesce(c.full_name, '')), ' ', 1) into v_referrer
    from public.clients c where c.id = v_ref.referrer_client_id;
  return jsonb_build_object(
    'pending', true,
    'status', 'pending',
    'min_spend_cents', coalesce(v_program.min_spend_cents, 0),
    'currency', coalesce(v_context.business_currency, 'SGD'),
    'friend_enabled', coalesce(v_program.friend_enabled, true),
    'friend_reward_points', v_friend_points,
    'friend_reward_label', case when coalesce(v_program.friend_enabled, true)
      then coalesce(v_program.friend_reward_label, v_program.reward_label) end,
    'reward_kind', coalesce(v_program.reward_kind, 'points'),
    'referrer_first_name', nullif(v_referrer, ''),
    'blocked_reason', v_ref.blocked_reason,
    'since', v_ref.created_at
  );
end
$function$;
revoke all on function public.customer_get_referral_pending_v777(text) from public, anon;
grant execute on function public.customer_get_referral_pending_v777(text) to authenticated, service_role;
comment on function public.customer_get_referral_pending_v777(text) is
  'nestly_v777. The signed-in customer''s own referral at this business, as the friend: pending '
  '(floor + points still to earn) or settled. Read-only; the row REGION B pays from.';

commit;
