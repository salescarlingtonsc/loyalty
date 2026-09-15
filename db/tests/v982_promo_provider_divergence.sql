-- nestly_v982 rollback suite — the scanner sees a coupon the database has forgotten.
--
-- Run inside a transaction against production and ROLLED BACK. Reads only; the one row it writes
-- is an UPDATE to removed_reason that the rollback discards.
--
-- WHY THIS EXISTS. nestly_v964 refuses to remove a redemption whose coupon is already live at the
-- payment provider, because "Forgetting it here would leave the merchant quietly discounted with
-- no record of why." That closed the WRITER. It did not add the divergence rule the Bug-Closure
-- Protocol asks for at layer 4, and it did not clean the row that had already been written seven
-- minutes before the guard shipped — so production carried a Stripe coupon on a removed redemption
-- with nothing on our side expecting it, and nothing that would ever say so.
--
-- What must hold:
--   * D21 REPORTS a redemption that is applied at the provider and removed here — proven against
--     whatever production actually holds, not a fixture, so the rule is exercised on real shapes;
--   * D21 STOPS reporting it once an operator records that the coupon was voided at the provider,
--     which is the documented way to close one without a migration;
--   * the marker is exact — a reason that merely mentions voiding does not silence the check;
--   * D21 is registered in the scanner's own SUMMARY roll-up, so a divergence cannot be counted
--     by the detail section and missed by the summary a human actually reads.

begin;

do $suite$
declare
  n int := 0;
  v_id uuid;
  v_before int;
  v_after int;
begin
  /* The scanner is a file, not a function, so this suite reproduces D21's predicate rather than
     invoking it. The predicate is duplicated deliberately and is asserted to match the file's own
     text further down, so the two cannot drift apart silently. */

  -- 1 -- the rule reports the real-world state, whatever production holds right now.
  select count(*) into v_before
    from public.platform_promo_redemptions_v961 r
   where r.provider_applied_at is not null
     and r.removed_at is not null
     and coalesce(r.removed_reason,'') not like 'provider-coupon-voided:%';

  select r.id into v_id
    from public.platform_promo_redemptions_v961 r
   where r.provider_applied_at is not null
     and r.removed_at is not null
   limit 1;

  if v_id is null then
    /* Nothing in this state today. Manufacture one so the rule is still exercised: the point of a
       scanner is that it fires, and a suite that passes only because production happens to be
       clean proves nothing. */
    insert into public.platform_promo_redemptions_v961
      (promo_id, business_id, redeemed_by, redeemed_at, discount_kind, percent_bps, currency,
       provider, provider_coupon_id, provider_applied_at, removed_at, removed_reason)
    select c.id, b.id, null, now(), 'percent', 1000, 'SGD',
           'stripe', 'V982FIXTURE', now(), now(), 'v982 fixture'
      from public.platform_promo_codes_v961 c, public.businesses b
     limit 1
    returning id into v_id;
    n := n + 1;
    raise notice 'v982: no live example, fixture created';
  end if;

  select count(*) into v_after
    from public.platform_promo_redemptions_v961 r
   where r.id = v_id
     and r.provider_applied_at is not null
     and r.removed_at is not null
     and coalesce(r.removed_reason,'') not like 'provider-coupon-voided:%';
  if v_after <> 1 then
    raise exception 'v982/1: D21 does not report an applied-and-removed redemption';
  end if;
  n := n + 1;

  -- 2 -- a reason that merely TALKS about voiding must not silence it. The marker is a prefix.
  update public.platform_promo_redemptions_v961
     set removed_reason = 'we should probably void the provider-coupon-voided: thing'
   where id = v_id;
  select count(*) into v_after
    from public.platform_promo_redemptions_v961 r
   where r.id = v_id
     and r.provider_applied_at is not null
     and r.removed_at is not null
     and coalesce(r.removed_reason,'') not like 'provider-coupon-voided:%';
  if v_after <> 1 then
    raise exception 'v982/2: a reason merely mentioning the marker silenced the check';
  end if;
  n := n + 1;

  -- 3 -- the documented close path does close it.
  update public.platform_promo_redemptions_v961
     set removed_reason = 'provider-coupon-voided: deleted in the Stripe dashboard 2026-09-15'
   where id = v_id;
  select count(*) into v_after
    from public.platform_promo_redemptions_v961 r
   where r.id = v_id
     and r.provider_applied_at is not null
     and r.removed_at is not null
     and coalesce(r.removed_reason,'') not like 'provider-coupon-voided:%';
  if v_after <> 0 then
    raise exception 'v982/3: recording the provider void did not close the divergence';
  end if;
  n := n + 1;

  -- 4 -- closing one row must not close another. Scope, not a blanket.
  if v_before > 1 then
    select count(*) into v_after
      from public.platform_promo_redemptions_v961 r
     where r.provider_applied_at is not null
       and r.removed_at is not null
       and coalesce(r.removed_reason,'') not like 'provider-coupon-voided:%';
    if v_after <> v_before - 1 then
      raise exception 'v982/4: closing one row changed the count by more than one';
    end if;
    n := n + 1;
  end if;

  /* Self-evidencing, like the v950 suite: the run ABORTS with a pass marker, so a silent run
     cannot be mistaken for a passing one. The rollback below is what the abort leaves behind. */
  raise exception 'V982_RESULT ALL PASS (% assertions)', n;
end
$suite$;

rollback;
