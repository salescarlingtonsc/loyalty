-- Nestly v229 — a firm chooses ONE use for points: redemption, or tier membership.
--
-- Owner: "firms can only choose 1 if they want to let customer * earn points to redeem ->
-- discounts / vouchers / free xxx * earn points to be tiered member - basic / gold / diamond
-- ... if not the redemption of points will clash with tier membership".
--
-- Mechanically the two do not corrupt each other — loyalty_programs.tier_basis measures
-- LIFETIME earn (visits, spend or points ever earned), so redeeming never drops a tier. The
-- clash is the customer story: "spend your points on rewards" and "your points make you Gold"
-- told at the same time is confusing, and the owner wants a firm to run one model, chosen
-- explicitly at setup. So this is a single nullable choice on the business:
--   'redeem' — points are spent on rewards; tier setup is put away.
--   'tiers'  — points count toward membership tiers; redemption is put away AND refused
--              server-side, so a stale wallet cannot start a redemption the firm no longer runs.
--   null     — not chosen yet; behaves as today until the owner picks (setup prompts them).
--
-- Backfill: every firm with a loyalty programme has been running point REDEMPTION (that is the
-- flow all demo traffic exercises), so they start at 'redeem'. Nobody's live behaviour changes;
-- switching to tiers is a decision the owner takes in setup, with a warning about what it stops.

begin;

alter table public.businesses
  add column if not exists points_mode text
  check (points_mode is null or points_mode in ('redeem','tiers'));

comment on column public.businesses.points_mode is
  'v229: the ONE thing customer points are for. redeem = spend on rewards (tiers put away). '
  'tiers = count toward membership tiers (redemption put away and refused server-side). '
  'null = not chosen yet; setup prompts the owner.';

update public.businesses business
set points_mode='redeem'
where points_mode is null
  and exists(select 1 from public.loyalty_programs prog where prog.business_id=business.id);

-- The one door into point redemption. In tiers mode it is refused with customer-readable
-- wording, BEFORE identity resolution, so the rule holds for every caller and is testable.
do $patch$
declare d text; n text;
begin
  select pg_get_functiondef(p.oid) into d from pg_proc p join pg_namespace ns on ns.oid=p.pronamespace
  where ns.nspname='public' and p.proname='customer_create_redemption_intent_v89';
  if position('points_mode' in d) > 0 then raise notice 'v229: intent gate already present'; return; end if;

  n := replace(d,
E'  if not app.platform_feature_enabled(''customer_qr_redemption'') then
    raise exception ''customer QR redemption is unavailable'' using errcode=''0A000'';
  end if;',
E'  if not app.platform_feature_enabled(''customer_qr_redemption'') then
    raise exception ''customer QR redemption is unavailable'' using errcode=''0A000'';
  end if;
  -- v229: this firm uses points for tier membership, not redemption. Refused here, before
  -- identity resolution, so the rule holds for every caller.
  if exists(select 1 from public.businesses gate
             where gate.id=p_business and gate.points_mode=''tiers'') then
    raise exception ''points here count toward membership tiers and cannot be redeemed''
      using errcode=''0A000'';
  end if;');
  if n = d then raise exception 'v229: intent gate anchor not found'; end if;
  execute n;

  select pg_get_functiondef(p.oid) into d from pg_proc p join pg_namespace ns on ns.oid=p.pronamespace
  where ns.nspname='public' and p.proname='customer_create_redemption_intent_v89';
  if position('points_mode' in d) = 0 then raise exception 'v229: intent gate did not land'; end if;
end $patch$;

commit;
