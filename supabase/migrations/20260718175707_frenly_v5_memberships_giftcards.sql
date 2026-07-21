-- FRENLY v5 — memberships (plans, enroll, daily renewals) + gift cards (issue/redeem).
-- Manual-billing model (benchmark's region-agnostic core); Stripe auto-charge = later.

-- 1) Plans + memberships
create table public.membership_plans (
  id            uuid primary key default gen_random_uuid(),
  business_id   uuid not null references public.businesses(id) on delete cascade,
  name          text not null,
  price_cents   integer not null check (price_cents >= 0),
  cadence       text not null default 'monthly' check (cadence in ('monthly','annual')),
  credit_cents  integer not null default 0 check (credit_cents >= 0),
  discount_pct  numeric not null default 0 check (discount_pct >= 0 and discount_pct <= 100),
  active        boolean not null default true,
  created_at    timestamptz not null default now()
);
create index on public.membership_plans (business_id);

create table public.memberships (
  id                    uuid primary key default gen_random_uuid(),
  business_id           uuid not null references public.businesses(id) on delete cascade,
  client_id             uuid not null references public.clients(id) on delete cascade,
  plan_id               uuid not null references public.membership_plans(id) on delete restrict,
  status                text not null default 'active'
                        check (status in ('active','paused','cancel_at_period_end','cancelled')),
  started_at            timestamptz not null default now(),
  current_period_start  timestamptz not null default now(),
  current_period_end    timestamptz not null,
  created_at            timestamptz not null default now()
);
create index on public.memberships (business_id, status, current_period_end);
create unique index one_live_membership_per_client on public.memberships (business_id, client_id)
  where status in ('active','paused','cancel_at_period_end');

alter table public.membership_plans enable row level security;
alter table public.memberships enable row level security;
create policy plans_all on public.membership_plans for all to authenticated
  using (app.is_salon_member(business_id)) with check (app.is_salon_member(business_id));
create policy memberships_select on public.memberships for select to authenticated
  using (app.is_salon_member(business_id));
create policy memberships_update on public.memberships for update to authenticated
  using (app.is_salon_member(business_id));

create trigger trg_audit_memberships after insert or update on public.memberships
  for each row execute function app.audit();

-- 2) Membership sales must NOT earn points / count as retention visits / qualify referrals
create or replace function app.on_sale_recorded()
returns trigger language plpgsql security definer set search_path = public as $$
declare lp record; rp record; refrow record; refprog record;
        v_pts integer; v_idx integer; v_count integer; v_earn_id uuid;
        w_start timestamptz; w_end timestamptz;
begin
  if new.client_id is null or new.kind = 'membership' then
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
          and s.kind <> 'membership'
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

-- 3) Enroll (atomic: membership + first charge as sale + first-period credit)
create or replace function public.enroll_membership(p_business uuid, p_client uuid, p_plan uuid)
returns json language plpgsql security definer set search_path = public as $$
declare plan record; m memberships; v_end timestamptz;
begin
  if not app.is_salon_member(p_business) then raise exception 'not a member of this business'; end if;
  select * into plan from membership_plans where id = p_plan and business_id = p_business and active;
  if not found then raise exception 'plan not found or inactive'; end if;
  v_end := now() + case when plan.cadence = 'annual'
                        then make_interval(years => 1) else make_interval(months => 1) end;
  insert into memberships (business_id, client_id, plan_id, current_period_start, current_period_end)
  values (p_business, p_client, p_plan, now(), v_end) returning * into m;
  insert into sales (business_id, client_id, kind, amount_cents, note)
  values (p_business, p_client, 'membership', plan.price_cents, 'membership charge: ' || plan.name);
  if plan.credit_cents > 0 then
    insert into credit_ledger (business_id, client_id, entry_type, amount_cents, reference)
    values (p_business, p_client, 'membership_credit', plan.credit_cents,
            'membership period credit: ' || plan.name);
  end if;
  return row_to_json(m);
end $$;
revoke execute on function public.enroll_membership(uuid, uuid, uuid) from public, anon;
grant execute on function public.enroll_membership(uuid, uuid, uuid) to authenticated;

-- 4) Daily renewals (skip paused; honor cancel-at-period-end; never double-charge;
--    catches up multiple missed periods, bounded)
create or replace function app.run_membership_renewals()
returns void language plpgsql security definer set search_path = public as $$
declare m record; plan record; guard integer;
begin
  for m in select * from memberships
      where status in ('active','cancel_at_period_end') and current_period_end <= now() loop
    if m.status = 'cancel_at_period_end' then
      update memberships set status = 'cancelled' where id = m.id;
      continue;
    end if;
    select * into plan from membership_plans where id = m.plan_id;
    guard := 0;
    while m.current_period_end <= now() and guard < 24 loop
      m.current_period_start := m.current_period_end;
      m.current_period_end := m.current_period_end +
        case when plan.cadence = 'annual' then make_interval(years => 1)
             else make_interval(months => 1) end;
      insert into sales (business_id, client_id, kind, amount_cents, note)
      values (m.business_id, m.client_id, 'membership', plan.price_cents,
              'membership renewal: ' || plan.name);
      if plan.credit_cents > 0 then
        insert into credit_ledger (business_id, client_id, entry_type, amount_cents, reference)
        values (m.business_id, m.client_id, 'membership_credit', plan.credit_cents,
                'membership period credit: ' || plan.name);
      end if;
      guard := guard + 1;
    end loop;
    update memberships set current_period_start = m.current_period_start,
      current_period_end = m.current_period_end where id = m.id;
  end loop;
end $$;

do $$
begin
  perform cron.schedule('frenly-membership-renewals','10 19 * * *','select app.run_membership_renewals()');
exception when others then
  raise notice 'cron scheduling skipped: %', sqlerrm;
end $$;

-- 5) Gift cards: issue + redeem-to-credit
create or replace function public.issue_gift_card(p_business uuid, p_amount integer,
  p_purchaser uuid, p_recipient_email text)
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
  insert into sales (business_id, client_id, kind, amount_cents, note)
  values (p_business, p_purchaser, 'retail', p_amount, 'gift card sold: ' || v_code);
  return row_to_json(gc);
end $$;
revoke execute on function public.issue_gift_card(uuid, integer, uuid, text) from public, anon;
grant execute on function public.issue_gift_card(uuid, integer, uuid, text) to authenticated;

create or replace function public.redeem_gift_card(p_business uuid, p_code text,
  p_client uuid, p_amount integer default null)
returns json language plpgsql security definer set search_path = public as $$
declare gc gift_cards; v_amt integer;
begin
  if not app.is_salon_member(p_business) then raise exception 'not a member of this business'; end if;
  select * into gc from gift_cards
    where business_id = p_business and code = upper(trim(p_code)) for update;
  if not found then raise exception 'gift card not found'; end if;
  if gc.status <> 'active' then raise exception 'gift card is %', gc.status; end if;
  v_amt := coalesce(p_amount, gc.balance_cents);
  if v_amt <= 0 or v_amt > gc.balance_cents then
    raise exception 'invalid amount: card balance is %', gc.balance_cents;
  end if;
  update gift_cards set balance_cents = balance_cents - v_amt,
    status = case when balance_cents - v_amt = 0 then 'redeemed' else 'active' end
    where id = gc.id;
  insert into credit_ledger (business_id, client_id, entry_type, amount_cents, reference)
  values (p_business, p_client, 'gift_card_load', v_amt, 'gift card redeemed: ' || gc.code);
  return json_build_object('code', gc.code, 'loaded_cents', v_amt,
                           'remaining_cents', gc.balance_cents - v_amt);
end $$;
revoke execute on function public.redeem_gift_card(uuid, text, uuid, integer) from public, anon;
grant execute on function public.redeem_gift_card(uuid, text, uuid, integer) to authenticated;