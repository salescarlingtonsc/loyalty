-- FRENLY v10 — sale accounting semantics become per-business policy, not hardcoded rules.
-- Full rationale: db/migrations/20260717_frenly_v10_sale_policy.sql
-- Three orthogonal flags per business per kind: counts_as_revenue / counts_as_visit / earns_points.
-- Defaults reproduce live behaviour, EXCEPT package visit=false (kills 11-visits-per-10-session bug).

alter table public.sales drop constraint if exists sales_kind_check;
alter table public.sales add constraint sales_kind_check
  check (kind in ('service','retail','membership','quick_sale','gift_card','package'));

-- Backfill: QA-era package purchase mis-recorded as 'retail' by the pre-v10 sell_package.
-- Identified by note prefix; this is exactly the misclassification v10 exists to remove.
update public.sales set kind = 'package'
  where kind = 'retail' and note like 'package sold:%';

create table if not exists public.sale_policies (
  id                uuid primary key default gen_random_uuid(),
  business_id       uuid not null references public.businesses(id) on delete cascade,
  kind              text not null
                    check (kind in ('service','retail','quick_sale','membership','gift_card','package')),
  counts_as_revenue boolean,
  counts_as_visit   boolean,
  earns_points      boolean,
  note              text,
  updated_at        timestamptz not null default now(),
  created_at        timestamptz not null default now(),
  unique (business_id, kind)
);

alter table public.sale_policies enable row level security;

drop policy if exists sale_policies_all on public.sale_policies;
create policy sale_policies_all on public.sale_policies for all to authenticated
  using (app.is_salon_member(business_id))
  with check (app.is_salon_member(business_id));

revoke all on public.sale_policies from anon;
grant select, insert, update, delete on public.sale_policies to authenticated;

drop trigger if exists trg_sale_policies_audit on public.sale_policies;
create trigger trg_sale_policies_audit
  after insert or update or delete on public.sale_policies
  for each row execute function app.audit();

create or replace function app.sale_policy_defaults()
returns table (kind text, counts_as_revenue boolean, counts_as_visit boolean, earns_points boolean)
language sql immutable set search_path = public as $$
  select * from (values
    ('service'::text,    true,  true,  true),
    ('retail'::text,     true,  true,  true),
    ('quick_sale'::text, true,  true,  true),
    ('membership'::text, true,  false, false),
    ('gift_card'::text,  false, false, false),
    ('package'::text,    true,  false, true)
  ) as t(kind, counts_as_revenue, counts_as_visit, earns_points)
$$;

create or replace function app.sale_policy_set(p_business uuid)
returns table (kind text, counts_as_revenue boolean, counts_as_visit boolean, earns_points boolean)
language sql stable security definer set search_path = public as $$
  select d.kind,
         coalesce(o.counts_as_revenue, d.counts_as_revenue),
         coalesce(o.counts_as_visit,   d.counts_as_visit),
         coalesce(o.earns_points,      d.earns_points)
  from app.sale_policy_defaults() d
  left join public.sale_policies o
    on o.business_id = p_business and o.kind = d.kind
$$;

create or replace function app.sale_policy(p_business uuid, p_kind text)
returns table (kind text, counts_as_revenue boolean, counts_as_visit boolean, earns_points boolean)
language sql stable security definer set search_path = public as $$
  select s.kind, s.counts_as_revenue, s.counts_as_visit, s.earns_points
  from app.sale_policy_set(p_business) s where s.kind = p_kind
$$;

create or replace function app.on_sale_recorded()
returns trigger language plpgsql security definer set search_path = public as $$
declare lp record; rp record; refrow record; refprog record;
        v_pts integer; v_idx integer; v_count integer; v_earn_id uuid;
        w_start timestamptz; w_end timestamptz;
        v_known boolean; v_earns boolean; v_is_visit boolean; v_visit_kinds text[];
begin
  if new.client_id is null then
    return new;
  end if;

  select bool_or(s.kind = new.kind),
         bool_or(s.earns_points)    filter (where s.kind = new.kind),
         bool_or(s.counts_as_visit) filter (where s.kind = new.kind),
         coalesce(array_agg(s.kind) filter (where s.counts_as_visit), array[]::text[])
    into v_known, v_earns, v_is_visit, v_visit_kinds
    from app.sale_policy_set(new.business_id) s;

  if not coalesce(v_known, false) then
    return new;
  end if;
  if not (coalesce(v_earns, false) or coalesce(v_is_visit, false)) then
    return new;
  end if;

  if coalesce(v_earns, false) then
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
  end if;

  if coalesce(v_is_visit, false) then
    for rp in select * from retention_programs
        where business_id = new.business_id and active loop
      v_idx := floor(extract(epoch from (new.occurred_at - rp.starts_on::timestamptz))
                     / (rp.period_days * 86400));
      if v_idx >= 0 then
        w_start := rp.starts_on::timestamptz + make_interval(days => v_idx * rp.period_days);
        w_end   := w_start + make_interval(days => rp.period_days);
        select count(*) into v_count from sales s
          where s.business_id = new.business_id and s.client_id = new.client_id
            and s.kind = any(v_visit_kinds)
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
  end if;

  return new;
end $$;

create or replace function public.sell_package(p_business uuid, p_client uuid, p_plan uuid)
returns json language plpgsql security definer set search_path = public as $$
declare plan record; cp client_packages;
begin
  if not app.is_salon_member(p_business) then raise exception 'not a member of this business'; end if;
  select * into plan from package_plans where id = p_plan and business_id = p_business and active;
  if not found then raise exception 'package plan not found or inactive'; end if;
  insert into client_packages (business_id, client_id, plan_id, remaining)
  values (p_business, p_client, p_plan, plan.sessions)
  returning * into cp;
  insert into sales (business_id, client_id, kind, amount_cents, note)
  values (p_business, p_client, 'package', plan.price_cents, 'package sold: ' || plan.name);
  return row_to_json(cp);
end $$;
revoke execute on function public.sell_package(uuid, uuid, uuid) from public, anon;
grant execute on function public.sell_package(uuid, uuid, uuid) to authenticated;

create or replace function public.get_sale_policy(p_business uuid)
returns json language plpgsql security definer set search_path = public as $$
begin
  if not app.is_salon_member(p_business) then raise exception 'not a member of this business'; end if;
  return (select coalesce(json_agg(row_to_json(p) order by p.kind), '[]'::json)
          from app.sale_policy_set(p_business) p);
end $$;
revoke execute on function public.get_sale_policy(uuid) from public, anon;
grant execute on function public.get_sale_policy(uuid) to authenticated;

create or replace function public.set_sale_policy(
  p_business uuid, p_kind text,
  p_counts_as_revenue boolean, p_counts_as_visit boolean, p_earns_points boolean,
  p_note text default null)
returns json language plpgsql security definer set search_path = public as $$
declare v_row record;
begin
  if not app.is_salon_member(p_business) then raise exception 'not a member of this business'; end if;
  if not exists (select 1 from app.sale_policy_defaults() d where d.kind = p_kind) then
    raise exception 'unknown sale kind: %', p_kind;
  end if;
  insert into sale_policies (business_id, kind, counts_as_revenue, counts_as_visit,
                             earns_points, note)
  values (p_business, p_kind, p_counts_as_revenue, p_counts_as_visit, p_earns_points, p_note)
  on conflict (business_id, kind) do update
    set counts_as_revenue = excluded.counts_as_revenue,
        counts_as_visit   = excluded.counts_as_visit,
        earns_points      = excluded.earns_points,
        note              = excluded.note,
        updated_at        = now();
  select * into v_row from app.sale_policy(p_business, p_kind);
  return row_to_json(v_row);
end $$;
revoke execute on function public.set_sale_policy(uuid, text, boolean, boolean, boolean, text)
  from public, anon;
grant execute on function public.set_sale_policy(uuid, text, boolean, boolean, boolean, text)
  to authenticated;