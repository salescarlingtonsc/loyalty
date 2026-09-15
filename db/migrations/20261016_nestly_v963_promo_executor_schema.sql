-- nestly_v963 — the promo executor RPCs move to public, because PostgREST could not reach them.
--
-- FOUND BY RUNNING IT. v962 deployed, a real promo code was applied to a stripe firm through the
-- console, and the command failed with 'promo intent read rejected' — v962's OWN error, so the
-- deployed branch was executing correctly and the Stripe call was never reached. The cause: the
-- executor is an EDGE FUNCTION talking over PostgREST, and PostgREST exposes the `public` schema.
-- app.promo_provider_intent_v962 and app.promo_provider_applied_v962 were in `app`, so
-- `admin.rpc('promo_provider_intent_v962', …)` resolved to nothing. Every other admin.rpc call in
-- that function names a PUBLIC function (claim_billing_command_v786, complete_billing_command_v77,
-- set_billing_payment_method_v758) — v962 broke the pattern without noticing.
--
-- No SQL caller referenced either function (checked with pg_get_functiondef across public and app
-- before dropping — the lesson of the "dropping SQL objects breaks callers silently" rule), so the
-- move is safe and the edge function needs NO change: it already calls the bare names, which
-- resolve to public.
--
-- The bodies below are v962's, lifted verbatim with only the schema changed. service_role only:
-- these are the executor's hands, never a browser's, and public.list_due_renewal_cancels_v764 is
-- the precedent for an executor RPC living in public with exactly that grant.
--
-- Rollback suite: db/tests/v963_promo_executor_schema.sql

begin;

create or replace function public.promo_provider_intent_v962(p_business uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_row public.platform_promo_redemptions_v961%rowtype;
  v_code text;
  v_sub public.subscriptions%rowtype;
begin
  select * into v_row from public.platform_promo_redemptions_v961
   where business_id = p_business and removed_at is null and consumed_at is null
     and provider_applied_at is null;
  if v_row.id is null then
    return jsonb_build_object('has_intent', false);
  end if;
  select * into v_sub from public.subscriptions where business_id = p_business;
  select code_norm into v_code from public.platform_promo_codes_v961 where id = v_row.promo_id;
  return jsonb_build_object(
    'has_intent', true,
    'redemption_id', v_row.id,
    'code', v_code,
    'discount_kind', v_row.discount_kind,
    'percent_bps', v_row.percent_bps,
    'amount_cents', v_row.amount_cents,
    'currency', v_row.currency,
    'provider', coalesce(v_row.provider, v_sub.billing_provider),
    'provider_subscription_id', v_sub.provider_subscription_id);
end
$$;

create or replace function public.promo_provider_applied_v962(
  p_redemption uuid, p_coupon_id text, p_error text
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_row public.platform_promo_redemptions_v961%rowtype;
begin
  select * into v_row from public.platform_promo_redemptions_v961
   where id = p_redemption for update;
  if v_row.id is null then
    raise exception 'promo redemption was not found' using errcode = '42704';
  end if;
  if v_row.removed_at is not null then
    -- Removed while the provider call was in flight. Recording success would leave a live coupon
    -- attached to a subscription with nothing here to explain it, so it is recorded as an error.
    update public.platform_promo_redemptions_v961
       set provider_error = coalesce(nullif(btrim(coalesce(p_error,'')),''),
             'redemption was removed before the provider call returned; coupon '||coalesce(p_coupon_id,'?')||' may be attached at the provider')
     where id = p_redemption;
    return jsonb_build_object('status','removed_in_flight','redemption_id',p_redemption);
  end if;

  if nullif(btrim(coalesce(p_error, '')), '') is not null then
    update public.platform_promo_redemptions_v961
       set provider_error = left(btrim(p_error), 1000), provider_coupon_id = p_coupon_id
     where id = p_redemption;
    insert into public.audit_log(business_id, actor, action, entity, entity_id, detail)
    values (v_row.business_id, null, 'promo_provider_coupon_failed',
      'platform_promo_redemptions_v961', p_redemption,
      jsonb_build_object('source','app.promo_provider_applied_v962','error',left(btrim(p_error),1000),
        'coupon_id', p_coupon_id));
    return jsonb_build_object('status','error','redemption_id',p_redemption);
  end if;

  update public.platform_promo_redemptions_v961
     set provider_coupon_id = p_coupon_id,
         provider_applied_at = now(),
         provider_error = null
   where id = p_redemption;

  insert into public.audit_log(business_id, actor, action, entity, entity_id, detail)
  values (v_row.business_id, null, 'promo_provider_coupon_applied',
    'platform_promo_redemptions_v961', p_redemption,
    jsonb_build_object('source','app.promo_provider_applied_v962','coupon_id',p_coupon_id,
      'provider', v_row.provider, 'discount_kind', v_row.discount_kind,
      'percent_bps', v_row.percent_bps, 'amount_cents', v_row.amount_cents));

  return jsonb_build_object('status','ok','redemption_id',p_redemption,'coupon_id',p_coupon_id);
end
$$;
comment on function public.promo_provider_intent_v962(uuid) is
  'nestly_v962 + v963: the pending, not-yet-applied promo for one business, as the billing executor needs it. In public because PostgREST — which is how the edge function reaches it — does not expose the app schema.';
comment on function public.promo_provider_applied_v962(uuid, text, text) is
  'nestly_v962 + v963: the billing executor records the coupon it created at the provider, or the error it hit. In public for the same reason.';

revoke all on function public.promo_provider_intent_v962(uuid) from public, anon, authenticated;
grant execute on function public.promo_provider_intent_v962(uuid) to service_role;
revoke all on function public.promo_provider_applied_v962(uuid, text, text) from public, anon, authenticated;
grant execute on function public.promo_provider_applied_v962(uuid, text, text) to service_role;

-- One authority per fact: the app.* pair is gone, not left as a second copy that could drift.
drop function if exists app.promo_provider_intent_v962(uuid);
drop function if exists app.promo_provider_applied_v962(uuid, text, text);

commit;
