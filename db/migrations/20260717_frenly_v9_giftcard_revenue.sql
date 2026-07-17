-- FRENLY v9 — gift card sales are cash collected, not revenue (and never a loyalty event).
-- (target Supabase project kyzovonwnscrzmkvocid; migration name `frenly_v9_giftcard_revenue`)
--
-- THE BUG
--   public.issue_gift_card() recorded the gift card purchase as `sales.kind = 'retail'`,
--   making it indistinguishable from a real retail sale. Two consequences:
--
--   1. ACCOUNTING. Every consumer of `sales` sums amount_cents with no kind filter, so
--      selling a $25 gift card inflated reported revenue by $25 at PURCHASE time. A gift
--      card sale is cash collected against a liability — it is not revenue until the card
--      is redeemed and the resulting credit is spent on a service/product.
--
--   2. LOYALTY. app.on_sale_recorded() fires on every sales insert and only skipped
--      kind = 'membership', so buying a gift card wrongly (a) earned the PURCHASER points
--      on the card's face value, and (b) counted as a qualifying visit toward retention
--      goals (the visit-count window only excluded 'membership'). Combined with the points
--      earned later when the recipient actually spends the credit, the same dollar earned
--      points twice.
--
-- THE FIX
--   Give gift card sales their own kind, 'gift_card', and treat that kind exactly the way
--   'membership' is already treated inside the loyalty trigger — no points, no points
--   batch, no retention visit, no referral qualification. The row still exists (cash was
--   collected and must be reportable), it just stops masquerading as revenue or a visit.
--
-- WHY REVENUE RECOGNITION IS *NOT* ADDED TO redeem_gift_card()
--   Deliberately left untouched. redeem_gift_card() loads the card balance into
--   credit_ledger as spendable credit; when the customer later spends that credit, staff
--   record a normal kind = 'service' / 'retail' sale — THAT row is the revenue. Inserting a
--   sales row at redemption too would double-count. Redemption is a liability-to-credit
--   transfer, not a sale.
--
-- SAFETY
--   public.sales is empty (0 rows, verified pre-flight) — this is a pre-launch schema, so
--   the check constraint is simply dropped and recreated with no backfill or validation
--   risk, and no rows exist that need reclassifying from 'retail' to 'gift_card'.
--
-- NOT CHANGED (verified, listed so the reviewer doesn't have to re-check)
--   * app.on_sale_stock_deduct() — the other AFTER INSERT trigger on sales. It gates on
--     `new.product_id is not null`, NOT on kind, and gift card sales carry a null
--     product_id, so it never fired for them and still won't. No change needed.
--   * public.redeem_gift_card() — see above.
--   * No view aggregates sales (only client_credit_balance / client_points_balance /
--     product_stock exist), so there is no SQL-side revenue rollup to patch. Revenue is
--     computed client-side in app/index.html — see the UI NOTE at the bottom of this file.
--
-- Style follows v2/v8: plpgsql SECURITY DEFINER + `set search_path = public`; RPCs revoke
-- from public/anon then grant to intended roles.

begin;

-- 1. Allow the new sales kind. ---------------------------------------------------------
--    'gift_card' = cash collected for a gift card; a liability, not revenue, and not a
--    visit. Safe to drop/recreate unvalidated: the table is empty.
alter table public.sales
  drop constraint if exists sales_kind_check;
alter table public.sales
  add constraint sales_kind_check
  check (kind in ('service','retail','membership','quick_sale','gift_card'));

-- 2. issue_gift_card: classify the purchase row correctly. -----------------------------
--    ONLY the sales insert's `kind` changes. The code-generation loop, the gift_cards
--    insert, the is_salon_member guard, the amount > 0 guard and the row_to_json(gc)
--    return shape are preserved byte-for-byte — the UI depends on that shape.
create or replace function public.issue_gift_card(
  p_business uuid, p_amount integer, p_purchaser uuid, p_recipient_email text)
returns json language plpgsql security definer set search_path = public as $$
declare v_code text; gc gift_cards;
begin
  if not app.is_salon_member(p_business) then raise exception 'not a member of this business'; end if;
  if p_amount is null or p_amount <= 0 then raise exception 'amount must be positive'; end if;
  loop
    v_code := 'GC-' || upper(substr(md5(random()::text || clock_timestamp()::text),1,8));
    exit when not exists (select 1 from gift_cards where code = v_code);
  end loop;
  insert into gift_cards (business_id, code, initial_cents, balance_cents,
                          purchaser_client_id, recipient_email)
  values (p_business, v_code, p_amount, p_amount, p_purchaser, p_recipient_email)
  returning * into gc;
  -- was 'retail' (v5) -> cash collected against a liability, never revenue at purchase.
  insert into sales (business_id, client_id, kind, amount_cents, note)
  values (p_business, p_purchaser, 'gift_card', p_amount, 'gift card sold: ' || v_code);
  return row_to_json(gc);
end $$;
-- Staff-only RPC: no anon grant (restated for explicitness; create-or-replace keeps ACLs).
revoke execute on function public.issue_gift_card(uuid, integer, uuid, text) from public, anon;
grant execute on function public.issue_gift_card(uuid, integer, uuid, text) to authenticated;

-- 3. on_sale_recorded: gift card purchases are not loyalty events. ----------------------
--    Two changes only, both mirroring the existing 'membership' treatment:
--      (a) the early-return guard now also short-circuits on kind = 'gift_card' — so no
--          points ledger entry, no points_batches row, no retention loop, and (because the
--          guard returns before it) no referral qualification off a gift card purchase;
--      (b) the retention visit-count window now excludes 'gift_card' as well as
--          'membership' — buying a gift card must not advance a retention goal, including
--          for OTHER sales in the same window that recount the range.
--    Everything else (points math, the `fixed` expiry_mode batch logic, the retention loop
--    with its unique_violation swallow, the referral block) is unchanged from the live v3+
--    definition, which was fetched from the database rather than the stale v2 file on disk.
create or replace function app.on_sale_recorded()
returns trigger language plpgsql security definer set search_path = public as $$
declare lp record; rp record; refrow record; refprog record;
        v_pts integer; v_idx integer; v_count integer; v_earn_id uuid;
        w_start timestamptz; w_end timestamptz;
begin
  if new.client_id is null or new.kind in ('membership','gift_card') then
    return new;
  end if;
  select * into lp from loyalty_programs
    where business_id = new.business_id and active limit 1;
  if found and lp.kind = 'points' then
    v_pts := floor((new.amount_cents / 100.0) * lp.earn_points_per_dollar);
    if v_pts > 0 then
      insert into points_ledger (business_id, client_id, entry_type, points, sale_id, reference)
      values (new.business_id, new.client_id, 'earn', v_pts, new.id, 'auto-earn on sale')
      on conflict do nothing
      returning id into v_earn_id;
      if v_earn_id is not null then
        insert into points_batches (business_id, client_id, earned, remaining, sale_id, earned_at, expires_at)
        values (new.business_id, new.client_id, v_pts, v_pts, new.id, now(),
                case when lp.expiry_mode = 'fixed'
                     then now() + make_interval(days => lp.expiry_days) end);
      end if;
    end if;
  end if;

  for rp in select * from retention_programs
      where business_id = new.business_id and active loop
    v_idx := floor(extract(epoch from (new.occurred_at - rp.starts_on::timestamptz))
                   / (rp.period_days * 86400));
    if v_idx >= 0 then
      w_start := rp.starts_on::timestamptz + make_interval(days => v_idx * rp.period_days);
      w_end   := w_start + make_interval(days => rp.period_days);
      select count(*) into v_count from sales s
        where s.business_id = new.business_id and s.client_id = new.client_id
          and s.kind not in ('membership','gift_card')
          and s.occurred_at >= w_start and s.occurred_at < w_end;
      if v_count >= rp.goal_visits then
        begin
          insert into reward_grants (business_id, program_id, client_id, period_index,
                                     reward_type, reward_value, reward_item)
          values (new.business_id, rp.id, new.client_id, v_idx,
                  rp.reward_type, rp.reward_value, rp.reward_item);
          if rp.reward_type = 'credit' and rp.reward_value > 0 then
            insert into credit_ledger (business_id, client_id, entry_type, amount_cents, reference)
            values (new.business_id, new.client_id, 'loyalty_earn',
                    rp.reward_value::integer, 'retention reward: ' || rp.name);
          end if;
        exception when unique_violation then null;
        end;
      end if;
    end if;
  end loop;

  select r.* into refrow from referrals r
    where r.business_id = new.business_id and r.referred_client_id = new.client_id
      and r.status = 'pending' limit 1;
  if found then
    select * into refprog from referral_programs
      where business_id = new.business_id and enabled limit 1;
    if found and new.amount_cents >= coalesce(refprog.min_spend_cents, 0) then
      update referrals set status = 'rewarded', qualified_at = now(),
             reward_cents = refprog.reward_cents
        where id = refrow.id and status = 'pending';
      if found then
        insert into credit_ledger (business_id, client_id, entry_type, amount_cents, reference)
        values (new.business_id, refrow.referrer_client_id, 'referral_reward',
                refprog.reward_cents, 'referral qualified: first visit completed');
      end if;
    end if;
  end if;
  return new;
end $$;

commit;

-- ------------------------------------------------------------------------------------
-- UI NOTE (out of scope for this migration — app/index.html is owned elsewhere)
-- ------------------------------------------------------------------------------------
-- This migration fixes consequence (2) — loyalty — entirely in the database. It does NOT
-- fix consequence (1) — inflated revenue — because no SQL object computes revenue; the
-- app does, with no kind filter. After this migration lands, app/index.html still needs:
--   * line ~277  `const revenue=sl.reduce((a,s)=>a+s.amount_cents,0)`
--                -> must exclude kind='gift_card' (keep 'membership': membership IS
--                   revenue, and the Reports page already reports it as such).
--   * line ~282  `['Visits (sales)', sl.length]`
--                -> counts every row; should exclude 'membership' AND 'gift_card'
--                   (the membership half of this is a pre-existing v5 bug).
--   * line ~1120 Reports "Revenue by type" byKind rollup
--                -> a 'gift card' row will now appear and be added into Total; it should
--                   be shown as cash collected / deferred, outside the revenue total.
-- ------------------------------------------------------------------------------------

-- ------------------------------------------------------------------------------------
-- MANUAL TEST SCENARIOS
-- ------------------------------------------------------------------------------------
-- Scenario A — Gift card purchase earns nothing (the core regression test):
--   1. Business with an ACTIVE points loyalty_program (kind='points',
--      earn_points_per_dollar = 1, expiry_mode='fixed', expiry_days=365) and a client C.
--   2. select public.issue_gift_card('<biz>', 2500, '<C>', 'gift@example.com');
--      -> returns the gift_cards row JSON unchanged in shape (id, code 'GC-XXXXXXXX',
--         initial_cents 2500, balance_cents 2500, purchaser_client_id, recipient_email).
--   3. select kind, amount_cents from sales where note like 'gift card sold:%';
--      -> exactly one row, kind = 'gift_card' (NOT 'retail'), amount_cents = 2500.
--   4. select count(*) from points_ledger where client_id = '<C>';   -> 0
--      select count(*) from points_batches where client_id = '<C>';  -> 0
--      (Pre-fix this was 25 points + one batch.)
--   5. select count(*) from stock_batches sb where <qty changed>;    -> unchanged
--      (on_sale_stock_deduct gates on product_id, which is null here — regression guard.)
--
-- Scenario B — Gift card purchase does not advance a retention goal:
--   1. Active retention_program: goal_visits = 2, period_days = 30, starts_on = today,
--      reward_type='credit', reward_value = 1000.
--   2. Record ONE real sale for client C: insert into sales(business_id, client_id, kind,
--      amount_cents) values ('<biz>','<C>','service', 5000);
--      -> no reward_grants row yet (1 visit of 2).
--   3. select public.issue_gift_card('<biz>', 2500, '<C>', null);
--      -> STILL no reward_grants row. Pre-fix this was the 2nd "visit" and wrongly granted
--         the reward + $10 credit_ledger entry.
--   4. Record a SECOND real sale (kind='service').
--      -> now exactly one reward_grants row (period_index 0) + one 'loyalty_earn'
--         credit_ledger row for 1000. Proves the gift card row is invisible to the
--         visit-count window even when a later real sale recounts it.
--
-- Scenario C — Gift card purchase does not qualify a referral:
--   1. referral_programs enabled with min_spend_cents = 2000, reward_cents = 500;
--      a referrals row (status='pending', referred_client_id = C, referrer = R).
--   2. select public.issue_gift_card('<biz>', 2500, '<C>', null);   -- 2500 >= 2000
--      -> referrals.status STILL 'pending'; no 'referral_reward' credit_ledger row for R.
--         (The early-return guard fires before the referral block.)
--   3. Record a real kind='service' sale of 2500 for C.
--      -> NOW referrals.status = 'rewarded', qualified_at set, and R gets one 500-cent
--         'referral_reward' credit row.
--
-- Scenario D — Revenue recognition happens once, at spend (not at purchase, not at
--              redemption):
--   1. issue_gift_card('<biz>', 2500, '<C>', null)
--      -> sales: one kind='gift_card' 2500 row.  Revenue (excluding gift_card) = $0. ✓
--   2. select public.redeem_gift_card('<biz>', '<code>', '<D>', null);
--      -> {"loaded_cents":2500, "remaining_cents":0}; gift_cards.status='redeemed';
--         ONE credit_ledger 'gift_card_load' row of 2500 for client D;
--         and NO new sales row (asserted deliberately — a sales insert here would
--         double-count against step 3).
--   3. Client D spends the credit: insert into sales(...) values (..., 'service', 2500);
--      -> Revenue (excluding gift_card) = $25 — recognized exactly once, at spend.
--         D earns 25 points on this sale; the purchaser C earned none. Total points
--         issued for the $25 = 25, not 50 as before the fix.
--
-- Scenario E — Constraint round-trip:
--   1. insert into sales(business_id, client_id, kind, amount_cents)
--      values ('<biz>', null, 'gift_card', 100);            -> accepted (new kind allowed).
--   2. insert into sales(business_id, client_id, kind, amount_cents)
--      values ('<biz>', null, 'giftcard', 100);             -> rejected by sales_kind_check.
--   3. The four legacy kinds ('service','retail','membership','quick_sale') all still
--      insert successfully, and 'membership' still earns nothing (v5 behaviour intact).
-- ------------------------------------------------------------------------------------
