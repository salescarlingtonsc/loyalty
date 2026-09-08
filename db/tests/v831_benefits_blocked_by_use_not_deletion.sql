-- nestly_v831 rollback suite — the owner's rule, executed.
--
-- OWNER, 2026-09-09: "if customer used welcome rewards / birthday rewards / referral from company
-- A and did not use for company B ... upon deletion and resign up > will not enjoy the same
-- benefit anymore for company A, while company B will still get to enjoy all benefits as yet to
-- use up. for birthday ... not able to enjoy this year's birthday, subsequent years still able."
--
-- Run inside a transaction against production and ROLLED BACK. Company A is Jess Salon and
-- company B is Cubbly SPA — both real tenants with a live welcome offer, so the gates are
-- exercised against real configuration rather than a synthetic fixture that could disagree with
-- it. The customer is synthetic (+65 8000 0831) and never commits.
--
-- Thirteen assertions. Two of them are NEGATIVE CONTROLS (A11, A13): they remove the mark and
-- prove the refusals above were caused by the mark and not by some unrelated gate.

\set ON_ERROR_STOP on

begin;

do $suite$
declare
  a uuid := '709387ff-5768-4767-9dad-abd665c2bb07';  -- company A: Jess Salon
  b uuid := '8492e8d6-8888-4383-ada0-7e1ed69f0caa';  -- company B: Cubbly SPA
  ph text := '80000831';
  c_a uuid; c_b uuid; c_a2 uuid; c_b2 uuid;
  g_a uuid; g_b uuid; g uuid; s_a uuid;
  n integer := 0;
begin
  -- ---------------------------------------------------------------------------------------
  -- Given: the same person joins both companies.
  -- ---------------------------------------------------------------------------------------
  insert into public.clients(business_id, full_name, phone) values (a, 'v831 subject', ph)
    returning id into c_a;
  insert into public.clients(business_id, full_name, phone) values (b, 'v831 subject', ph)
    returning id into c_b;

  g_a := app.issue_welcome_offer_v215(a, c_a);
  g_b := app.issue_welcome_offer_v215(b, c_b);

  n := n + 1;
  if g_a is null then raise exception 'A1 failed: no welcome gift at company A on first join'; end if;
  n := n + 1;
  if g_b is null then raise exception 'A2 failed: no welcome gift at company B on first join'; end if;

  -- ---------------------------------------------------------------------------------------
  -- When: they USE it at A, and leave B's untouched.
  -- ---------------------------------------------------------------------------------------
  -- Redeemed the way the counter does it: welcome_offer_grants_v215_redeem_shape refuses a
  -- 'redeemed' row with no sale behind it, and the $0 reward-fulfilment sale is that sale.
  perform app.acquire_loyalty_shared_v480(a);
  insert into public.sales(business_id, client_id, kind, amount_cents, note)
  values (a, c_a, 'service', 0, 'v831 suite: welcome gift redeemed')
  returning id into s_a;
  update public.welcome_offer_grants_v215
     set status = 'redeemed', redeemed_at = now(), redeemed_sale_id = s_a
   where id = g_a;

  n := n + 1;
  if not app.benefit_consumed_v831(a, c_a, 'welcome', 'once') then
    raise exception 'A3 failed: redeeming at A left no consumption mark';
  end if;
  n := n + 1;
  if app.benefit_consumed_v831(b, c_b, 'welcome', 'once') then
    raise exception 'A4 failed: an untouched gift at B was marked as consumed';
  end if;

  -- ---------------------------------------------------------------------------------------
  -- When: they delete the account and sign up again. v749 anonymises the old rows (the number
  -- goes) and the rejoin creates brand new client rows carrying the same number.
  -- ---------------------------------------------------------------------------------------
  update public.clients set full_name = 'Erased customer', phone = null
   where id in (c_a, c_b);
  insert into public.clients(business_id, full_name, phone) values (a, 'v831 subject again', ph)
    returning id into c_a2;
  insert into public.clients(business_id, full_name, phone) values (b, 'v831 subject again', ph)
    returning id into c_b2;

  -- Then: A refuses, B still pays. This is the owner's sentence, executed.
  n := n + 1;
  if app.issue_welcome_offer_v215(a, c_a2) is not null then
    raise exception 'A5 failed: company A gave a second welcome gift to a number that used it';
  end if;
  n := n + 1;
  g := app.issue_welcome_offer_v215(b, c_b2);
  if g is null then
    raise exception 'A6 failed: company B withheld a welcome gift that was never used up';
  end if;

  -- ---------------------------------------------------------------------------------------
  -- Referral: paid once here, never again — whoever refers them. The gate takes only
  -- (business, referred customer), so a different referrer's code cannot change the answer.
  -- ---------------------------------------------------------------------------------------
  perform app.mark_benefit_consumed_v831(a, c_a2, 'referral_friend', 'once', 'v831_suite', null);
  n := n + 1;
  if app.referral_referred_is_new_v683(a, c_a2) then
    raise exception 'A7 failed: company A still treats a paid-out number as a new customer';
  end if;
  n := n + 1;
  if not app.referral_referred_is_new_v683(b, c_b2) then
    raise exception 'A8 failed: company B refused a referral it never paid';
  end if;

  -- ---------------------------------------------------------------------------------------
  -- Birthday: this year is spent, next year is not, and B is untouched.
  -- ---------------------------------------------------------------------------------------
  perform app.mark_benefit_consumed_v831(a, c_a2, 'birthday', '2026', 'v831_suite', null);
  n := n + 1;
  if not app.benefit_consumed_v831(a, c_a2, 'birthday', '2026') then
    raise exception 'A9 failed: this year''s birthday was not recorded as used at A';
  end if;
  n := n + 1;
  if app.benefit_consumed_v831(a, c_a2, 'birthday', '2027') then
    raise exception 'A10 failed: using 2026 also blocked 2027 — the old 365-day bug';
  end if;
  n := n + 1;
  if app.benefit_consumed_v831(b, c_b2, 'birthday', '2026') then
    raise exception 'A11 failed: a birthday used at A was counted against B';
  end if;

  -- ---------------------------------------------------------------------------------------
  -- NEGATIVE CONTROLS. Reverse the redemption; the mark must go and the gift must come back.
  -- If these pass while A5 also passed, A5 was caused by the mark and nothing else.
  -- ---------------------------------------------------------------------------------------
  update public.welcome_offer_grants_v215
     set status = 'granted', redeemed_at = null, redeemed_sale_id = null
   where id = g_a;
  n := n + 1;
  if app.benefit_consumed_v831(a, c_a2, 'welcome', 'once') then
    raise exception 'A12 failed: reversing the redemption left the mark standing';
  end if;
  n := n + 1;
  if app.issue_welcome_offer_v215(a, c_a2) is null then
    raise exception 'A13 failed (negative control): with the mark gone A still refused, so A5 proved nothing';
  end if;

  raise notice 'nestly_v831 suite: % assertions passed', n;
end
$suite$;

select 'v831 suite passed' as result;

rollback;
