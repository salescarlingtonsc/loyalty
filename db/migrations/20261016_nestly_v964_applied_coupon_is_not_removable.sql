-- nestly_v964 — a promo whose coupon is LIVE at Stripe cannot be quietly removed here.
--
-- FOUND BY USING IT. Closing the v962 loop end-to-end, a real Stripe coupon was created for a firm
-- and then the redemption was removed from the firm record. Peekaa forgot the promo; STRIPE DID
-- NOT. The coupon stayed attached to the subscription and would still have come off the next
-- invoice, with nothing in Peekaa to explain why the firm was charged less.
--
-- v961's platform_remove_promo_redemption_v961 already refuses a CONSUMED redemption ("history is
-- not removed"). It was written before v962 existed, so it had no idea a redemption could also be
-- live at a payment provider. This adds that second refusal.
--
-- WHY REFUSE RATHER THAN DETACH. Detaching would mean another provider round trip that can fail
-- halfway, and a half-detached discount is exactly the ambiguity this is trying to prevent. The
-- honest answer is that the discount already exists somewhere Peekaa does not own: the console
-- says so and names the coupon, and the person removes it in Stripe. A promo that has NOT reached
-- Stripe is still freely removable, which is the case that actually needs the button.

begin;

create or replace function public.platform_remove_promo_redemption_v961(
  p_business uuid, p_reason text
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_actor uuid := auth.uid();
  v_row public.platform_promo_redemptions_v961%rowtype;
begin
  if v_actor is null or not app.is_super_admin() then
    raise exception 'super_admin_required' using errcode = '42501';
  end if;
  if length(btrim(coalesce(p_reason, ''))) not between 3 and 1000 then
    raise exception 'promo_reason_required' using errcode = '22023';
  end if;
  select * into v_row from public.platform_promo_redemptions_v961
   where business_id = p_business and removed_at is null for update;
  if v_row.id is null then
    raise exception 'no_promo_to_remove' using errcode = '42704';
  end if;
  if v_row.consumed_at is not null then
    raise exception 'promo_already_used' using errcode = '22023';
  end if;
  /* nestly_v964: the discount already exists at the provider. Forgetting it here would leave the
     merchant quietly discounted with no record of why. */
  if v_row.provider_applied_at is not null then
    raise exception 'promo_live_at_provider' using errcode = '22023';
  end if;

  update public.platform_promo_redemptions_v961
     set removed_at = now(), removed_by = v_actor, removed_reason = btrim(p_reason)
   where id = v_row.id;
  update public.platform_promo_codes_v961
     set redeemed_count = greatest(redeemed_count - 1, 0), updated_at = now()
   where id = v_row.promo_id;

  insert into public.audit_log(business_id, actor, action, entity, entity_id, detail)
  values (p_business, v_actor, 'promo_redemption_removed', 'platform_promo_redemptions_v961',
    v_row.id, jsonb_build_object('source', 'platform_console_v961', 'reason', btrim(p_reason),
      'promo_id', v_row.promo_id));

  return jsonb_build_object('status', 'ok', 'business_id', p_business);
end
$$;

comment on function public.platform_remove_promo_redemption_v961(uuid, text) is
  'nestly_v961 + v964: super-admin removes a PENDING promo redemption and returns the allowance to the code. Refuses one already consumed (history) or already live at the provider (v964 — Stripe would still discount the invoice).';

revoke all on function public.platform_remove_promo_redemption_v961(uuid, text) from public, anon;
grant execute on function public.platform_remove_promo_redemption_v961(uuid, text) to authenticated, service_role;

commit;
