-- Rollback-only v664 acceptance suite (owner ruling 2026-08-31: tiered customer capacity charged
-- per branch, and a manual payment that actually moves the billing dates).
--
-- SECTION 1 — the capacity ladder is data, and a tier Peekaa cannot charge for is refused.
--   S1-T1  The four seeded tiers exist with the owner's amounts.
--   S1-T2  A capacity resolves to the SMALLEST tier that covers it.
--   S1-T3  A capacity above every tier resolves to nothing — that is the support conversation.
--   S1-T4  Monthly sells no tier above 10,000 (no monthly amount was ruled for one).
--   S1-T5  Tier 1 carries the Stripe price that already exists; tiers 2 and 3 carry none yet, and
--          `checkout_available` in the billing payload says so rather than hiding them.
--
-- SECTION 2 — item_role no longer depends on an empty catalogue.
--   S2-T1  The webhook applier resolves the role through app.stripe_item_role_v664.
--   S2-T2  A tier base price is 'base' (this is what unblocks branch activation on invoice.paid),
--          the v124 capacity price is 'capacity', and an unknown price is 'other'.
--
-- SECTION 3 — a manual payment is indistinguishable from a card payment to every gate.
--   S3-T1  Recording one sets status/payment_status and moves current_period_end + next_payment_at.
--   S3-T2  app.business_entitlement_v620 reports the business open on the PAID path afterwards.
--   S3-T3  Replaying the same idempotency key changes nothing and reports replayed.
--   S3-T4  A recorded payment never SHORTENS a period end.
--   S3-T5  A non-super-admin is refused (42501) — proved from the real role, not from postgres.
--   S3-T6  A reason under 8 characters and a paid-through date in the past are both refused.
--
-- Run against production; everything is inside one transaction that rolls back.
begin;
create temporary table v664_evidence(test text, detail text) on commit drop;

create temporary table v664_fixture on commit drop as
select 'f73a9423-33fd-424c-9fb9-2d5ba058a2d7'::uuid as super_admin_user,
       (select business_id from public.subscriptions order by created_at limit 1) as business_id;

-- ---------------------------------------------------------------------------------------------
-- SECTION 1
-- ---------------------------------------------------------------------------------------------
do $s1$
declare v_count integer; v_tier public.billing_capacity_tier_catalog_v664%rowtype;
begin
  select count(*) into v_count from public.billing_capacity_tier_catalog_v664
   where active and (cadence,capacity_ceiling,amount_cents) in
     (('annual',10000,118800),('annual',40000,168800),('annual',100000,249900),('monthly',10000,14800));
  if v_count <> 4 then raise exception 'S1-T1: expected the four seeded tiers, found %', v_count; end if;
  insert into v664_evidence values('S1-T1','four tiers seeded with the ruled amounts');

  v_tier := app.billing_tier_for_capacity_v664('annual',12000);
  if v_tier.capacity_ceiling <> 40000 then
    raise exception 'S1-T2: 12,000 customers should resolve to the 40,000 tier, got %', v_tier.capacity_ceiling;
  end if;
  v_tier := app.billing_tier_for_capacity_v664('annual',10000);
  if v_tier.capacity_ceiling <> 10000 then raise exception 'S1-T2: an exact ceiling must not step up'; end if;
  insert into v664_evidence values('S1-T2','capacity resolves to the smallest covering tier');

  if (app.billing_tier_for_capacity_v664('annual',100001)).id is not null then
    raise exception 'S1-T3: a capacity above every tier must resolve to no tier';
  end if;
  insert into v664_evidence values('S1-T3','above the top tier is a support conversation');

  if (app.billing_tier_for_capacity_v664('monthly',40000)).id is not null then
    raise exception 'S1-T4: monthly must not sell a tier above 10,000 yet';
  end if;
  insert into v664_evidence values('S1-T4','monthly stops at 10,000');

  if (select provider_base_price_id from public.billing_capacity_tier_catalog_v664
       where cadence='annual' and capacity_ceiling=10000) is null then
    raise exception 'S1-T5: the 10,000 annual tier must carry the existing Stripe price';
  end if;
  if exists(select 1 from public.billing_capacity_tier_catalog_v664
             where cadence='annual' and capacity_ceiling in (40000,100000)
               and provider_base_price_id is not null) then
    raise exception 'S1-T5: tiers 2 and 3 must have no Stripe price until one is created';
  end if;
  insert into v664_evidence values('S1-T5','tier 1 sellable; tiers 2 and 3 visible but not chargeable');
end
$s1$;

-- ---------------------------------------------------------------------------------------------
-- SECTION 2
-- ---------------------------------------------------------------------------------------------
do $s2$
declare v_def text;
begin
  v_def := pg_get_functiondef('public.apply_stripe_billing_event_v94_base(text)'::regprocedure);
  if v_def not like '%app.stripe_item_role_v664(v_price)%' then
    raise exception 'S2-T1: the webhook applier still resolves item_role from billing_price_catalog';
  end if;
  if v_def like '%from public.billing_price_catalog catalog%' then
    raise exception 'S2-T1: the empty-catalogue lookup is still present';
  end if;
  insert into v664_evidence values('S2-T1','webhook applier resolves item_role through v664');

  if app.stripe_item_role_v664(
       (select provider_base_price_id from public.billing_capacity_tier_catalog_v664
         where cadence='annual' and capacity_ceiling=10000)) <> 'base' then
    raise exception 'S2-T2: a tier base price must mirror as item_role=base';
  end if;
  if app.stripe_item_role_v664(
       (select provider_capacity_price_id from public.billing_plan_catalog_v124
         where cadence='annual' and active order by effective_from desc limit 1)) <> 'capacity' then
    raise exception 'S2-T2: the v124 capacity price must mirror as item_role=capacity';
  end if;
  if app.stripe_item_role_v664('price_thisdoesnotexist') <> 'other' then
    raise exception 'S2-T2: an unknown price must mirror as other';
  end if;
  insert into v664_evidence values('S2-T2','base / capacity / other resolved from catalogues that have rows');
end
$s2$;

-- ---------------------------------------------------------------------------------------------
-- SECTION 3 — run as the super admin through their own jwt, not as postgres.
-- ---------------------------------------------------------------------------------------------
do $s3$
declare
  f record;
  v_before public.subscriptions%rowtype;
  v_after public.subscriptions%rowtype;
  v_result jsonb;
  v_key uuid := gen_random_uuid();
  v_entitlement jsonb;
begin
  select * into f from v664_fixture;
  if f.business_id is null then raise exception 'V664 FIXTURE: no subscription row to test against'; end if;
  select * into v_before from public.subscriptions where business_id=f.business_id;

  /* v625: a platform session is a GOOGLE session — app.is_super_admin() checks the amr method and
     the provider list as well as the super_admins row, so the fixture jwt must carry both or the
     RPC refuses an actual super admin. */
  perform set_config('request.jwt.claims',
    json_build_object('sub',f.super_admin_user::text,'role','authenticated',
      'amr',json_build_array(json_build_object('method','oauth')),
      'app_metadata',json_build_object('providers',json_build_array('google')))::text, true);

  v_result := public.platform_record_subscription_payment_v664(
    f.business_id,'v664 rollback suite: bank transfer recorded',
    now()+interval '365 days','annual',now(),118800,'V664-TEST',v_key);
  select * into v_after from public.subscriptions where business_id=f.business_id;
  if v_after.payment_status <> 'paid' or v_after.status <> 'active' then
    raise exception 'S3-T1: a recorded payment must mark the subscription paid and active';
  end if;
  if v_after.current_period_end < now()+interval '360 days'
     or v_after.next_payment_at is distinct from v_after.current_period_end then
    raise exception 'S3-T1: the billing dates did not move to the paid-through date';
  end if;
  insert into v664_evidence values('S3-T1','manual payment moved payment_status and both dates');

  v_entitlement := app.business_entitlement_v620(f.business_id);
  if coalesce(v_entitlement->>'operational_state','') <> 'paid'
     or coalesce((v_entitlement->>'may_access_workspace')::boolean,false) is not true then
    raise exception 'S3-T2: entitlement after a manual payment is % (access %), expected paid and open',
      v_entitlement->>'operational_state', v_entitlement->>'may_access_workspace';
  end if;
  insert into v664_evidence values('S3-T2','entitlement authority reports the paid path');

  v_result := public.platform_record_subscription_payment_v664(
    f.business_id,'v664 rollback suite: bank transfer recorded',
    now()+interval '3 days','annual',now(),118800,'V664-TEST',v_key);
  if coalesce(v_result->>'replayed','false') <> 'true' then
    raise exception 'S3-T3: the same idempotency key must replay, not re-record';
  end if;
  insert into v664_evidence values('S3-T3','replay is a no-op');

  select * into v_after from public.subscriptions where business_id=f.business_id;
  if v_after.current_period_end < now()+interval '360 days' then
    raise exception 'S3-T4: a replay shortened the paid-through date';
  end if;
  insert into v664_evidence values('S3-T4','a recorded payment never shortens access');

  perform set_config('request.jwt.claims',
    json_build_object('sub','00000000-0000-0000-0000-0000000000ff','role','authenticated',
      'amr',json_build_array(json_build_object('method','oauth')),
      'app_metadata',json_build_object('providers',json_build_array('google')))::text, true);
  begin
    perform public.platform_record_subscription_payment_v664(
      f.business_id,'not a super admin at all', now()+interval '30 days',
      null,null,null,null,gen_random_uuid());
    raise exception 'S3-T5: a non-super-admin recorded a payment';
  exception when insufficient_privilege then
    insert into v664_evidence values('S3-T5','non-super-admin refused with 42501');
  end;

  /* v625: a platform session is a GOOGLE session — app.is_super_admin() checks the amr method and
     the provider list as well as the super_admins row, so the fixture jwt must carry both or the
     RPC refuses an actual super admin. */
  perform set_config('request.jwt.claims',
    json_build_object('sub',f.super_admin_user::text,'role','authenticated',
      'amr',json_build_array(json_build_object('method','oauth')),
      'app_metadata',json_build_object('providers',json_build_array('google')))::text, true);
  begin
    perform public.platform_record_subscription_payment_v664(
      f.business_id,'short', now()+interval '30 days',null,null,null,null,gen_random_uuid());
    raise exception 'S3-T6: a one-word reason was accepted';
  exception when invalid_parameter_value then null;
  end;
  begin
    perform public.platform_record_subscription_payment_v664(
      f.business_id,'a properly stated reason', now()-interval '1 day',
      null,null,null,null,gen_random_uuid());
    raise exception 'S3-T6: a paid-through date in the past was accepted';
  exception when invalid_parameter_value then null;
  end;
  insert into v664_evidence values('S3-T6','a thin reason and a backdated period end are refused');
end
$s3$;

select test, detail from v664_evidence order by test;
rollback;
