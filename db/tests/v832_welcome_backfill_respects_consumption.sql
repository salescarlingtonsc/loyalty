-- nestly_v832 rollback suite — the owner pressing Save must not re-gift a number that used it.
--
-- The hole v832 closes: public.business_set_welcome_offer_v215 mass-grants the welcome gift on an
-- ACTIVE save to every client with no non-reversed sale, by direct insert, never asking the gate.
-- Its ON CONFLICT protects only clients who already hold a grant, and a deleted-and-rejoined
-- customer is a NEW client row. So the owner changing the reward item and pressing Save silently
-- handed a second welcome gift to every number v831 had just refused at sign-up.
--
-- Run inside a transaction against production and ROLLED BACK. Tenant: Jess Salon — a real
-- welcome offer ('Hair Cut (Director)', service, no minimum, 60-day expiry), re-saved on its OWN
-- current settings so the suite never proposes a configuration the owner did not choose. The
-- customer is synthetic (+65 8000 0835) and never commits.
--
-- Eight assertions. A6 is the NEGATIVE CONTROL: it removes the mark and re-saves, and the gift
-- must come back — without it, A4 would prove only that the save granted nobody anything.

\set ON_ERROR_STOP on

begin;

do $suite$
declare
  biz uuid := '709387ff-5768-4767-9dad-abd665c2bb07';   -- Jess Salon
  staff_uid uuid := 'b8ba53b5-b20d-4d6d-b6fe-66f014758fab';
  br uuid;
  ph text := '80000835';
  c1 uuid; c2 uuid; g1 uuid; s1 uuid; g_forced uuid;
  o record;
  n integer := 0;
  err text;
begin
  select id into br from public.branches where business_id = biz and active order by created_at limit 1;
  select * into o from public.business_welcome_offers_v215 where business_id = biz;
  if br is null or o.business_id is null then raise exception 'setup: Jess Salon has no branch or no welcome offer'; end if;
  perform set_config('request.jwt.claims',
    json_build_object('sub', staff_uid::text, 'role', 'authenticated')::text, true);
  perform app.acquire_loyalty_shared_v480(biz);

  -- Given: a customer who used the welcome gift, then deleted and signed up again.
  insert into public.clients(business_id, full_name, phone) values (biz, 'v832 subject', ph)
    returning id into c1;
  g1 := app.issue_welcome_offer_v215(biz, c1);
  n := n + 1;
  if g1 is null then raise exception 'A1 failed: setup could not grant the welcome gift'; end if;

  insert into public.sales(business_id, client_id, kind, amount_cents, note)
  values (biz, c1, 'service', 0, 'v832 suite: welcome gift redeemed') returning id into s1;
  update public.welcome_offer_grants_v215
     set status='redeemed', redeemed_at=now(), redeemed_sale_id=s1 where id = g1;
  n := n + 1;
  if not app.benefit_consumed_v831(biz, c1, 'welcome', 'once') then
    raise exception 'A2 failed: setup did not record the consumption';
  end if;

  update public.clients set full_name='Erased customer', phone=null where id = c1;
  insert into public.clients(business_id, full_name, phone) values (biz, 'v832 subject again', ph)
    returning id into c2;
  n := n + 1;
  if app.issue_welcome_offer_v215(biz, c2) is not null then
    raise exception 'A3 failed: v831 itself regressed — sign-up re-granted a used welcome gift';
  end if;

  -- WHEN: the owner opens the Welcome offer editor and presses Save, unchanged and still active.
  perform public.business_set_welcome_offer_v215(
    biz, true, o.min_spend_cents, o.reward_catalog_kind, o.reward_catalog_id,
    o.expiry_days, o.custom_label);
  n := n + 1;
  if exists (select 1 from public.welcome_offer_grants_v215 g
              where g.business_id = biz and g.client_id = c2) then
    raise exception 'A4 failed: pressing Save re-gifted a number that had already used its welcome gift';
  end if;

  -- And the save must still reach an ordinary customer who never used one.
  n := n + 1;
  if not exists (select 1 from public.welcome_offer_grants_v215 g
                  join public.clients c on c.id = g.client_id
                 where g.business_id = biz and c.phone_norm is distinct from app.norm_phone(ph)) then
    raise exception 'A5 failed: the save granted nobody at all — the gate is over-blocking';
  end if;

  -- NEGATIVE CONTROL: drop the mark, save again, and the gift must come back. If it does not,
  -- A4 proved nothing about the mark.
  delete from public.benefit_consumption_marks_v831
   where business_id = biz and benefit_kind = 'welcome' and phone_hash = app.v89_sha256(app.norm_phone(ph));
  perform public.business_set_welcome_offer_v215(
    biz, true, o.min_spend_cents, o.reward_catalog_kind, o.reward_catalog_id,
    o.expiry_days, o.custom_label);
  n := n + 1;
  if not exists (select 1 from public.welcome_offer_grants_v215 g
                  where g.business_id = biz and g.client_id = c2) then
    raise exception 'A6 failed (negative control): with the mark gone the save STILL withheld the gift, so A4 proved nothing';
  end if;

  -- LAYER TWO: even a grant that some future writer creates in defiance of the rule must not be
  -- redeemable at the counter. Put the mark back, leave the grant standing, and try to redeem.
  perform app.mark_benefit_consumed_v831(biz, c2, 'welcome', 'once', 'v832_suite', null);
  select id into g_forced from public.welcome_offer_grants_v215
   where business_id = biz and client_id = c2;
  n := n + 1;
  if g_forced is null then raise exception 'A7 failed: setup lost the forced grant'; end if;

  begin
    perform public.staff_redeem_welcome_offer_v215(biz, c2, br, null, 'v832-suite-key-0001');
    raise exception 'A8 failed: the counter redeemed a welcome gift for a number that had already used one';
  exception
    when sqlstate '22023' then
      get stacked diagnostics err = message_text;
      if err is distinct from 'welcome_offer_already_used_by_this_number' then
        raise exception 'A8 failed: refused for the wrong reason (%)', err;
      end if;
      n := n + 1;
  end;

  raise notice 'nestly_v832 suite: % assertions passed', n;
end
$suite$;

select 'v832 suite passed' as result;

rollback;
