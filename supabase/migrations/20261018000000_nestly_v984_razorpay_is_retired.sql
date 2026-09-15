-- nestly_v984 — Razorpay is retired, and the database can no longer say otherwise (2026-09-16).
--
-- OWNER, 2026-09-16: "i am only using stripe, no more razor pay".
--
-- This is a RESTATEMENT the code had already half-absorbed. nestly_v792 (2026-09-06) introduced
-- app.platform_billing_provider_v792() — "the provider the platform bills through" — and ruled
-- that "a subscription left behind on a retired provider reads as unpaid". nestly_v798 applied the
-- same rule to the stored card, and its own header says in as many words: "Those subscriptions are
-- Razorpay SANDBOX artifacts: no money ever moved, and Razorpay is retired".
--
-- So two readers already treat Razorpay as retired. The STORED STATE never caught up, and neither
-- did the constraint, so the database still holds six subscriptions that claim a provider the
-- platform does not bill through -- and would accept a seventh.
--
-- WHAT IS ACTUALLY THERE, measured before touching anything:
--   subscriptions                6 rows billing_provider='razorpay', ALL on is_demo firms,
--                                all status 'active', all annual, next_payment_at 2027-09-0[34]
--   billing_provider_events      34 razorpay events, EVERY ONE livemode=false, none after
--                                2026-09-05; the first Stripe event is 2026-09-06
--   edge secrets                 RAZORPAY_KEY_ID/_KEY_SECRET carry the same digests as
--                                TEST_KEY_ID/TEST_KEY_SECRET, which is razorpay-mode.ts's own
--                                documented pre-go-live state: "before go-live these are
--                                themselves test keys". The platform set WAS the sandbox.
--   branch_subscriptions_v786    0 rows of any provider
-- Razorpay never went live. No money has ever moved through it and none ever could have. That is
-- what makes this a cleanup rather than a billing migration -- and it is ASSERTED below rather
-- than merely stated here, so a replay against a different reality stops instead of proceeding.
--
-- WHY RE-POINT THE ROWS INSTEAD OF PATCHING EACH READER. Three readers currently answer the
-- question "what does billing_provider='razorpay' mean?" and they do not agree:
--   get_business_billing_v786  (v792)  -> no plan, "Not paid yet"          [retired-provider rule]
--   get_business_billing_v758  (v798)  -> no card shown                    [retired-provider rule]
--   business_redeem_promo_code_v961    -> raise 'promo_razorpay_unsupported'  [hardcoded name]
-- The third is why those six firms cannot redeem a promo code today. Patching it would make four
-- readers to keep in step; removing the value they disagree about leaves nothing to disagree over.
-- CLAUDE.md: "one authority per fact; fix the shared path, not each caller."
--
-- THE PROVIDER IDS GO WITH IT. All six carry provider_customer_id 'cust_TXtuRBwVvgDij2' -- the
-- exact id whose appearance in a Stripe call caused v792 ("No such customer: 'cust_TXtuRBwVvgDij2'").
-- v792 stopped the claim from HANDING it over; this removes it from the row, so there is no longer
-- an id to hand. The history is not lost: billing_provider_customers keeps its razorpay row and all
-- 34 events stay. State is corrected; the record of what happened is not.
--
-- WHY 'manual' AND NOT 'canceled'. These are demo firms that are meant to keep working, and
-- 'manual' is what every other non-provider firm on this estate already reads (15 rows). A manual
-- subscription is also promo-redeemable (v967), which is the live symptom closing.
--
-- STATUS MOVES, AND THAT IS THE POINT -- stated here because the first draft of this header
-- claimed it would not, and production proved otherwise. subscriptions_payment_link_v510 is an
-- AFTER UPDATE trigger that recomputes payment readiness from
-- app.v510_verified_initial_payment(), whose self-serve arm accepts evidence when
--   billing_provider in ('stripe','razorpay') and provider_subscription_id is not null
-- with NO livemode test. So six firms were reading status='active', payment_status='paid' on the
-- strength of a Razorpay SANDBOX invoice. Re-pointing them removes that evidence, the trigger
-- re-runs, and all six become status='incomplete', payment_status='not_collected'.
--
-- That is a correction, not a casualty: it is what get_business_billing_v786 has been telling
-- those firms on screen since v792 ("Not paid yet"). The stored status has finally caught up with
-- the reader. Measured after the fact -- 'active' -> 'incomplete' on exactly the six, and
-- period / next_payment_at / cancel_at_period_end all unchanged.
--
-- The trigger has a DESTRUCTIVE arm that did not fire, and it is worth naming because it is the
-- one thing that could have made this migration harmful: when evidence disappears from a business
-- with activated_at set, v510_sync_payment_readiness sets businesses.join_enabled=false and
-- deactivates every branch. All six have activated_at IS NULL, so the projection went to
-- 'incomplete' rather than 'past_due' and that arm was never reached. Verified on production
-- afterwards: join_enabled still true on all six, branch counts unchanged, and businesses.updated_at
-- still holds its pre-migration value on every one of them.
--
-- FAIL CLOSED. The CHECK drops 'razorpay'. After this, apply_razorpay_billing_event_v755 cannot
-- write the value even if something called it -- which is the point: the four razorpay-* edge
-- functions are undeployed alongside this migration, and a constraint is what makes that stick
-- from the database's side rather than a matter of remembering.
--
-- The history tables (billing_provider_events / _customers / the catalogues) deliberately KEEP
-- 'razorpay' in their CHECKs. They record what happened, and what happened included Razorpay.
--
-- Scanner: D22 in db/tests/tenant_divergence_scan.sql.
-- Rollback suite: db/tests/v984_razorpay_is_retired.sql

begin;

-- =============================================================================================
-- 0 · Reality is what this migration was written against.
-- =============================================================================================
do $v984_assert$
declare
  v_live integer;
  v_nondemo integer;
  v_branch integer;
begin
  if app.platform_billing_provider_v792() <> 'stripe' then
    raise exception 'v984: the platform bills through %, not stripe -- refusing to retire razorpay',
      app.platform_billing_provider_v792();
  end if;

  /* A live-mode razorpay event would mean real money moved there, and every sentence above would
     be wrong. Stop rather than re-point a row that might still be owed a refund. */
  select count(*) into v_live from public.billing_provider_events
   where provider = 'razorpay' and livemode is true;
  if v_live > 0 then
    raise exception 'v984: % live-mode razorpay events exist -- this is not a sandbox retirement', v_live;
  end if;

  /* A paying firm on razorpay would need a commercial decision, not a migration. */
  select count(*) into v_nondemo
    from public.subscriptions s join public.businesses b on b.id = s.business_id
   where s.billing_provider = 'razorpay' and coalesce(b.is_demo, false) is false;
  if v_nondemo > 0 then
    raise exception 'v984: % non-demo firms are on razorpay -- refusing to re-point them', v_nondemo;
  end if;

  select count(*) into v_branch from public.branch_subscriptions_v786 where provider = 'razorpay';
  if v_branch > 0 then
    raise exception 'v984: % razorpay branch subscriptions exist -- not covered by this migration', v_branch;
  end if;
end
$v984_assert$;

-- =============================================================================================
-- 1 · The audit entry is written BEFORE the update, from the rows as they still are.
-- =============================================================================================
insert into public.audit_log (business_id, actor, action, entity, entity_id, detail)
select s.business_id,
       null,
       'billing.provider.retired',
       'subscriptions',
       s.business_id,
       jsonb_build_object(
         'migration', 'nestly_v984',
         'reason', 'razorpay retired (owner, 2026-09-16); sandbox-only, no live-mode event ever recorded',
         'from_billing_provider', s.billing_provider,
         'to_billing_provider', 'manual',
         'provider_customer_id', s.provider_customer_id,
         'provider_subscription_id', s.provider_subscription_id,
         'provider_base_item_id', s.provider_base_item_id
       )
  from public.subscriptions s
 where s.billing_provider = 'razorpay';

-- =============================================================================================
-- 2 · The rows stop claiming a provider the platform does not bill through.
-- =============================================================================================
update public.subscriptions
   set billing_provider = 'manual',
       provider_customer_id = null,
       provider_subscription_id = null,
       provider_base_item_id = null
 where billing_provider = 'razorpay';

-- =============================================================================================
-- 3 · And cannot start again.
-- =============================================================================================
alter table public.subscriptions drop constraint if exists subscriptions_billing_provider_check;
alter table public.subscriptions
  add constraint subscriptions_billing_provider_check
  check (billing_provider = any (array['manual'::text, 'stripe'::text]));

alter table public.branch_subscriptions_v786 drop constraint if exists branch_subscriptions_v786_provider_check;
alter table public.branch_subscriptions_v786
  add constraint branch_subscriptions_v786_provider_check check (provider in ('stripe'));

comment on constraint subscriptions_billing_provider_check on public.subscriptions is
  'nestly_v984: razorpay is retired (owner, 2026-09-16). The platform bills through app.platform_billing_provider_v792(); a subscription may only name that provider or none at all.';

-- =============================================================================================
-- 4 · Nothing was left behind.
-- =============================================================================================
do $v984_verify$
declare v_left integer;
begin
  select count(*) into v_left from public.subscriptions where billing_provider = 'razorpay';
  if v_left <> 0 then
    raise exception 'v984: % razorpay subscriptions survived the update', v_left;
  end if;
  select count(*) into v_left from public.subscriptions
   where billing_provider = 'manual'
     and (provider_customer_id is not null or provider_subscription_id is not null
          or provider_base_item_id is not null);
  if v_left <> 0 then
    raise exception 'v984: % manual subscriptions still carry provider ids', v_left;
  end if;
end
$v984_verify$;

commit;
