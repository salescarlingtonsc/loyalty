-- FRENLY v3 — points expiry (3 modes + sweep), referrals, consent events, audit log.

-- 1) Loyalty expiry config
alter table public.loyalty_programs
  add column expiry_mode text not null default 'none' check (expiry_mode in ('none','inactivity','fixed')),
  add column expiry_days integer not null default 365 check (expiry_days > 0);

-- 2) Points batches (expiry tracking; ledger stays the balance source of truth)
create table public.points_batches (
  id           uuid primary key default gen_random_uuid(),
  business_id  uuid not null references public.businesses(id) on delete cascade,
  client_id    uuid not null references public.clients(id) on delete cascade,
  earned       integer not null check (earned > 0),
  remaining    integer not null check (remaining >= 0),
  sale_id      uuid references public.sales(id) on delete set null,
  earned_at    timestamptz not null default now(),
  expires_at   timestamptz
);
create index on public.points_batches (business_id, client_id, earned_at);
create index on public.points_batches (business_id, expires_at) where expires_at is not null;
alter table public.points_batches enable row level security;
create policy batches_select on public.points_batches for select to authenticated
  using (app.is_salon_member(business_id));

-- backfill batches from existing earns, then drain what was already consumed (FIFO)
insert into public.points_batches (business_id, client_id, earned, remaining, sale_id, earned_at)
  select business_id, client_id, points, points, sale_id, created_at
  from public.points_ledger where entry_type = 'earn' and points > 0;
do $$
declare c record; bt record; v_consumed integer; v_take integer;
begin
  for c in select business_id, client_id,
             -coalesce(sum(points) filter (where points < 0),0) as consumed
           from public.points_ledger group by business_id, client_id loop
    v_consumed := c.consumed;
    if v_consumed > 0 then
      for bt in select id, remaining from public.points_batches
        where business_id = c.business_id and client_id = c.client_id and remaining > 0
        order by earned_at loop
        exit when v_consumed <= 0;
        v_take := least(bt.remaining, v_consumed);
        update public.points_batches set remaining = remaining - v_take where id = bt.id;
        v_consumed := v_consumed - v_take;
      end loop;
    end if;
  end loop;
end $$;

-- 3) Referrals: program config + personal codes
create table public.referral_programs (
  id               uuid primary key default gen_random_uuid(),
  business_id      uuid not null unique references public.businesses(id) on delete cascade,
  enabled          boolean not null default false,
  reward_cents     integer not null default 1000 check (reward_cents >= 0),
  min_spend_cents  integer not null default 0 check (min_spend_cents >= 0),
  created_at       timestamptz not null default now()
);
alter table public.referral_programs enable row level security;
create policy refprog_all on public.referral_programs for all to authenticated
  using (app.is_salon_member(business_id)) with check (app.is_salon_member(business_id));

alter table public.clients add column referral_code text;
create unique index clients_referral_code_key on public.clients (referral_code);

create or replace function app.gen_ref_code()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.referral_code is null then
    loop
      new.referral_code := upper(substr(md5(random()::text || clock_timestamp()::text),1,6));
      exit when not exists (select 1 from clients where referral_code = new.referral_code);
    end loop;
  end if;
  return new;
end $$;
create trigger trg_gen_ref_code before insert on public.clients
  for each row execute function app.gen_ref_code();

do $$
declare c record; v text;
begin
  for c in select id from public.clients where referral_code is null loop
    loop
      v := upper(substr(md5(random()::text || clock_timestamp()::text),1,6));
      exit when not exists (select 1 from public.clients where referral_code = v);
    end loop;
    update public.clients set referral_code = v where id = c.id;
  end loop;
end $$;

-- one referral per referred client, ever
create unique index one_referral_per_referred on public.referrals (referred_client_id)
  where referred_client_id is not null;

-- 4) Consent events (append-only, PDPA) + audit log
create table public.consents (
  id           uuid primary key default gen_random_uuid(),
  business_id  uuid not null references public.businesses(id) on delete cascade,
  client_id    uuid not null references public.clients(id) on delete cascade,
  channel      text not null default 'marketing' check (channel in ('marketing','email','sms','whatsapp')),
  action       text not null check (action in ('granted','withdrawn')),
  source       text,
  actor        uuid,
  created_at   timestamptz not null default now()
);
create index on public.consents (business_id, client_id, created_at);
alter table public.consents enable row level security;
create policy consents_select on public.consents for select to authenticated
  using (app.is_salon_member(business_id));
create policy consents_insert on public.consents for insert to authenticated
  with check (app.is_salon_member(business_id));

create table public.audit_log (
  id           uuid primary key default gen_random_uuid(),
  business_id  uuid,
  actor        uuid,
  action       text not null,
  entity       text not null,
  entity_id    uuid,
  detail       jsonb,
  created_at   timestamptz not null default now()
);
create index on public.audit_log (business_id, created_at);
alter table public.audit_log enable row level security;
create policy audit_select on public.audit_log for select to authenticated
  using (app.is_salon_member(business_id));

create or replace function app.audit()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into audit_log (business_id, actor, action, entity, entity_id, detail)
  values (coalesce(new.business_id, old.business_id), auth.uid(), tg_op, tg_table_name,
          coalesce(new.id, old.id), to_jsonb(coalesce(new, old)));
  return coalesce(new, old);
end $$;
create trigger trg_audit_credit  after insert on public.credit_ledger      for each row execute function app.audit();
create trigger trg_audit_points  after insert on public.points_ledger      for each row execute function app.audit();
create trigger trg_audit_grants  after insert on public.reward_grants      for each row execute function app.audit();
create trigger trg_audit_refs    after update on public.referrals          for each row execute function app.audit();
create trigger trg_audit_retent  after update on public.retention_programs for each row execute function app.audit();
create trigger trg_audit_book    after update on public.booking_requests   for each row execute function app.audit();

-- 5) Upgraded sale trigger: earn + batch + retention + referral qualification
create or replace function app.on_sale_recorded()
returns trigger language plpgsql security definer set search_path = public as $$
declare lp record; rp record; refrow record; refprog record;
        v_pts integer; v_idx integer; v_count integer; v_earn_id uuid;
        w_start timestamptz; w_end timestamptz;
begin
  if new.client_id is not null then
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

    -- retention programs
    for rp in select * from retention_programs
        where business_id = new.business_id and active loop
      v_idx := floor(extract(epoch from (new.occurred_at - rp.starts_on::timestamptz))
                     / (rp.period_days * 86400));
      if v_idx >= 0 then
        w_start := rp.starts_on::timestamptz + make_interval(days => v_idx * rp.period_days);
        w_end   := w_start + make_interval(days => rp.period_days);
        select count(*) into v_count from sales s
          where s.business_id = new.business_id and s.client_id = new.client_id
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

    -- referral qualification: first qualifying sale of a referred client pays the referrer
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
  end if;
  return new;
end $$;

-- 6) Redeem drains batches oldest-first (ledger remains source of truth)
create or replace function public.redeem_points(p_business uuid, p_client uuid)
returns json language plpgsql security definer set search_path = public as $$
declare lp record; bal integer; v_need integer; v_take integer; bt record;
begin
  if not app.is_salon_member(p_business) then
    raise exception 'not a member of this business';
  end if;
  select * into lp from loyalty_programs where business_id = p_business and active limit 1;
  if not found then raise exception 'no active loyalty program'; end if;
  select coalesce(sum(points),0) into bal from points_ledger
    where business_id = p_business and client_id = p_client;
  if bal < lp.redeem_points then
    raise exception 'insufficient points: % < %', bal, lp.redeem_points;
  end if;
  insert into points_ledger (business_id, client_id, entry_type, points, reference)
  values (p_business, p_client, 'redeem', -lp.redeem_points, 'redeemed to credit');
  insert into credit_ledger (business_id, client_id, entry_type, amount_cents, reference)
  values (p_business, p_client, 'loyalty_earn', lp.reward_credit_cents, 'points redemption');
  v_need := lp.redeem_points;
  for bt in select id, remaining from points_batches
    where business_id = p_business and client_id = p_client and remaining > 0
    order by earned_at loop
    exit when v_need <= 0;
    v_take := least(bt.remaining, v_need);
    update points_batches set remaining = remaining - v_take where id = bt.id;
    v_need := v_need - v_take;
  end loop;
  return json_build_object('points_spent', lp.redeem_points,
                           'credit_cents', lp.reward_credit_cents);
end $$;

-- 7) Manual adjust (owner-only, audited, batch-aware)
create or replace function public.adjust_points(p_business uuid, p_client uuid,
  p_points integer, p_reason text)
returns integer language plpgsql security definer set search_path = public as $$
declare lp record; bal integer; v_need integer; v_take integer; bt record;
begin
  if not app.is_salon_owner(p_business) then
    raise exception 'owner role required for manual adjustments';
  end if;
  if p_points = 0 then raise exception 'adjustment cannot be zero'; end if;
  select coalesce(sum(points),0) into bal from points_ledger
    where business_id = p_business and client_id = p_client;
  if p_points < 0 and bal + p_points < 0 then
    raise exception 'adjustment would make balance negative (% + % < 0)', bal, p_points;
  end if;
  insert into points_ledger (business_id, client_id, entry_type, points, reference)
  values (p_business, p_client, 'adjust', p_points, coalesce(p_reason,'manual adjustment'));
  if p_points > 0 then
    select * into lp from loyalty_programs where business_id = p_business limit 1;
    insert into points_batches (business_id, client_id, earned, remaining, earned_at, expires_at)
    values (p_business, p_client, p_points, p_points, now(),
            case when lp.expiry_mode = 'fixed'
                 then now() + make_interval(days => lp.expiry_days) end);
  else
    v_need := -p_points;
    for bt in select id, remaining from points_batches
      where business_id = p_business and client_id = p_client and remaining > 0
      order by earned_at loop
      exit when v_need <= 0;
      v_take := least(bt.remaining, v_need);
      update points_batches set remaining = remaining - v_take where id = bt.id;
      v_need := v_need - v_take;
    end loop;
  end if;
  return bal + p_points;
end $$;
revoke execute on function public.adjust_points(uuid, uuid, integer, text) from public, anon;
grant execute on function public.adjust_points(uuid, uuid, integer, text) to authenticated;

-- 8) Expiry sweep
create or replace function app.run_points_expiry()
returns void language plpgsql security definer set search_path = public as $$
declare b record; c record; v_cut timestamptz;
begin
  for b in select business_id, expiry_mode, expiry_days from loyalty_programs
      where active and expiry_mode <> 'none' loop
    if b.expiry_mode = 'fixed' then
      for c in select client_id, sum(remaining) as tot from points_batches
          where business_id = b.business_id and remaining > 0
            and expires_at is not null and expires_at <= now()
          group by client_id loop
        insert into points_ledger (business_id, client_id, entry_type, points, reference)
        values (b.business_id, c.client_id, 'expire', -c.tot, 'expiry sweep (fixed-from-earn)');
        update points_batches set remaining = 0
          where business_id = b.business_id and client_id = c.client_id
            and remaining > 0 and expires_at is not null and expires_at <= now();
      end loop;
    else
      v_cut := now() - make_interval(days => b.expiry_days);
      for c in select client_id, sum(remaining) as tot from points_batches
          where business_id = b.business_id and remaining > 0
          group by client_id having max(earned_at) < v_cut loop
        insert into points_ledger (business_id, client_id, entry_type, points, reference)
        values (b.business_id, c.client_id, 'expire', -c.tot, 'expiry sweep (inactivity)');
        update points_batches set remaining = 0
          where business_id = b.business_id and client_id = c.client_id and remaining > 0;
      end loop;
    end if;
  end loop;
end $$;

-- member-callable on-demand sweep for one business (also lets the app self-heal)
create or replace function public.run_expiry_now(p_business uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not app.is_salon_member(p_business) then
    raise exception 'not a member of this business';
  end if;
  perform app.run_points_expiry();
end $$;
revoke execute on function public.run_expiry_now(uuid) from public, anon;
grant execute on function public.run_expiry_now(uuid) to authenticated;

-- daily schedule (03:00 SGT = 19:00 UTC); tolerate missing pg_cron
do $$
begin
  create extension if not exists pg_cron;
  perform cron.schedule('frenly-points-expiry','0 19 * * *','select app.run_points_expiry()');
exception when others then
  raise notice 'pg_cron scheduling skipped: %', sqlerrm;
end $$;

-- 9) All tenants get the referrals module
update public.businesses
  set enabled_modules = enabled_modules || array['referrals']
  where not ('referrals' = any(enabled_modules));