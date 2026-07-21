

-- (#3) model selector: two valid strategies, default classic, existing firms -> classic.
alter table public.loyalty_programs drop constraint if exists loyalty_programs_loyalty_model_check;
alter table public.loyalty_programs
  alter column loyalty_model set default 'classic';
update public.loyalty_programs set loyalty_model = 'classic';
alter table public.loyalty_programs
  add constraint loyalty_programs_loyalty_model_check
  check (loyalty_model in ('classic','points_tiers'));
comment on column public.loyalty_programs.loyalty_model is
  'Firm-selected redeem strategy. classic = fixed points->credit via redeem_points (default, the '
  'current UI). points_tiers = owner-defined reward catalog via redeem_reward + tiers. One model '
  'active at a time so the points balance has a single redemption path.';

-- (#4) retire the dead earn knob (earn_points_per_dollar is the live one; 0 refs anywhere).
alter table public.loyalty_programs drop column if exists earn_rate_bps;

-- (#2) EARN applies the client's tier multiplier. Minimal diff of the live app.on_sale_recorded:
--      declare v_tier; after computing v_pts, multiply by the current tier's points_multiplier.
--      Tier is resolved by the firm's chosen tier_basis; no tiers configured => multiplier 1.
create or replace function app.on_sale_recorded()
returns trigger language plpgsql security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp' as $$
declare
  lp record;
  rp record;
  refrow record;
  refprog record;
  v_tier public.loyalty_tiers%rowtype;
  v_pts integer;
  v_idx integer;
  v_count integer;
  v_earn_id uuid;
  v_credit_id uuid;
  w_start timestamptz;
  w_end timestamptz;
begin
  if new.reversal_of is not null then
    return new;
  end if;

  if new.client_id is null then
    return new;
  end if;

  if not (new.earns_points or new.counts_as_visit) then
    return new;
  end if;

  if new.earns_points then
    select * into lp
      from public.loyalty_programs
     where business_id = new.business_id
       and active
     limit 1;
    if found and lp.kind = 'points' then
      v_pts := floor((new.amount_cents / 100.0) * lp.earn_points_per_dollar);
      -- v23g (#2): the firm's tier multiplier (owner-configured, >= 1) applies at earn time.
      -- The tier is the client's CURRENT tier under the firm's chosen tier_basis; this sale may
      -- itself lift the client into a higher tier, which then applies from the NEXT sale.
      select * into v_tier from app.loyalty_tier_for(new.business_id, new.client_id);
      if v_tier.id is not null and v_tier.points_multiplier > 1 then
        v_pts := floor(v_pts * v_tier.points_multiplier);
      end if;
      if v_pts > 0 then
        v_earn_id := gen_random_uuid();
        perform set_config('app.points_ledger_insert_id', v_earn_id::text, true);
        perform set_config('app.points_ledger_write_scope', 'sale_trigger', true);
        insert into public.points_ledger
          (id, business_id, client_id, entry_type, points, sale_id, reference, actor)
        values
          (v_earn_id, new.business_id, new.client_id, 'earn', v_pts, new.id,
           'auto-earn on sale', auth.uid())
        on conflict do nothing
        returning id into v_earn_id;
        perform set_config('app.points_ledger_insert_id', '', true);
        perform set_config('app.points_ledger_write_scope', '', true);
        if v_earn_id is not null then
          insert into public.points_batches (business_id, client_id, earned, remaining, sale_id, earned_at, expires_at)
          values (
            new.business_id,
            new.client_id,
            v_pts,
            v_pts,
            new.id,
            now(),
            case when lp.expiry_mode = 'fixed'
                 then now() + make_interval(days => lp.expiry_days)
            end
          );
        end if;
      end if;
    end if;
  end if;

  if new.counts_as_visit then
    for rp in
      select * from public.retention_programs
       where business_id = new.business_id
         and active
    loop
      v_idx := floor(extract(epoch from (new.occurred_at - rp.starts_on::timestamptz))
                     / (rp.period_days * 86400));
      if v_idx >= 0 then
        w_start := rp.starts_on::timestamptz + make_interval(days => v_idx * rp.period_days);
        w_end := w_start + make_interval(days => rp.period_days);
        select count(*) into v_count
          from public.sales s
         where s.business_id = new.business_id
           and s.client_id = new.client_id
           and s.counts_as_visit
           and s.reversal_of is null
           and not exists (
             select 1 from public.sales r
              where r.business_id = s.business_id
                and r.reversal_of = s.id
           )
           and s.occurred_at >= w_start
           and s.occurred_at < w_end;

        if v_count >= rp.goal_visits then
          begin
            insert into public.reward_grants (
              business_id, program_id, client_id, period_index,
              reward_type, reward_value, reward_item
            )
            values (
              new.business_id, rp.id, new.client_id, v_idx,
              rp.reward_type, rp.reward_value, rp.reward_item
            );
            if rp.reward_type = 'credit' and rp.reward_value > 0 then
              v_credit_id := gen_random_uuid();
              perform set_config('app.credit_ledger_insert_id', v_credit_id::text, true);
              perform set_config('app.credit_ledger_write_scope', 'sale_trigger', true);
              insert into public.credit_ledger
                (id, business_id, client_id, entry_type, amount_cents, reference, sale_id, actor)
              values (
                v_credit_id,
                new.business_id,
                new.client_id,
                'loyalty_earn',
                rp.reward_value::integer,
                'retention reward: ' || rp.name,
                new.id,
                auth.uid()
              );
              perform set_config('app.credit_ledger_insert_id', '', true);
              perform set_config('app.credit_ledger_write_scope', '', true);
            end if;
          exception when unique_violation then
            null;
          end;
        end if;
      end if;
    end loop;

    select r.* into refrow
      from public.referrals r
     where r.business_id = new.business_id
       and r.referred_client_id = new.client_id
       and r.status = 'pending'
     limit 1;
    if found then
      select * into refprog
        from public.referral_programs
       where business_id = new.business_id
         and enabled
       limit 1;
      if found and new.amount_cents >= coalesce(refprog.min_spend_cents, 0) then
        update public.referrals
           set status = 'rewarded',
               qualified_at = now(),
               qualified_sale_id = new.id,
               reward_cents = refprog.reward_cents
         where id = refrow.id
           and status = 'pending';
        if found then
          v_credit_id := gen_random_uuid();
          perform set_config('app.credit_ledger_insert_id', v_credit_id::text, true);
          perform set_config('app.credit_ledger_write_scope', 'sale_trigger', true);
          insert into public.credit_ledger
            (id, business_id, client_id, entry_type, amount_cents, reference, sale_id, actor)
          values (
            v_credit_id,
            new.business_id,
            refrow.referrer_client_id,
            'referral_reward',
            refprog.reward_cents,
            'referral qualified: first visit completed',
            new.id,
            auth.uid()
          );
          perform set_config('app.credit_ledger_insert_id', '', true);
          perform set_config('app.credit_ledger_write_scope', '', true);
        end if;
      end if;
    end if;
  end if;

  return new;
end $$;

-- (#3) redeem_points gates on model='classic'. Minimal diff of the live body: one explicit check
--      after the program row loads; everything else byte-identical.
create or replace function public.redeem_points(p_business uuid, p_client uuid)
returns json language plpgsql security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp' as $$
declare
  lp public.loyalty_programs%rowtype;
  bal integer;
  v_batch_balance integer;
  v_remaining integer;
  v_take integer;
  v_batch record;
  v_actor uuid := auth.uid();
  v_staff uuid;
  v_points_id uuid := gen_random_uuid();
  v_credit_id uuid := gen_random_uuid();
begin
  if not app.has_perm(p_business, 'create_sales') then
    raise exception 'you do not have permission to redeem points in this business (create_sales)'
      using errcode = '42501';
  end if;

  select s.id into v_staff
    from public.staff s
   where s.business_id = p_business
     and s.user_id = v_actor
     and s.active
     and 'create_sales' = any (app.role_perms(s.role))
   order by case s.role when 'owner' then 0 when 'manager' then 1 else 2 end, s.created_at
   limit 1
   for update;
  if not found or not app.has_perm(p_business, 'create_sales') then
    raise exception 'active staff authorization changed while redeeming points'
      using errcode = '42501';
  end if;

  perform 1
    from public.clients c
   where c.id = p_client
     and c.business_id = p_business
   for update;
  if not found then
    raise exception 'client does not belong to this business';
  end if;

  select * into lp
    from public.loyalty_programs
   where business_id = p_business
     and active
     and kind = 'points'
     and redeem_points > 0
     and reward_credit_cents > 0
   limit 1;
  if not found then
    raise exception 'no active redeemable points program with positive points and credit values';
  end if;
  -- v23g (#3): this firm may run the reward-catalog model instead.
  if lp.loyalty_model is distinct from 'classic' then
    raise exception 'this business redeems points through its reward catalog (points_tiers model) — use redeem_reward';
  end if;

  select coalesce(sum(pl.points), 0)::integer into bal
    from public.points_ledger pl
   where pl.business_id = p_business
     and pl.client_id = p_client;
  if bal < lp.redeem_points then
    raise exception 'insufficient points: % < %', bal, lp.redeem_points;
  end if;

  select coalesce(sum(pb.remaining), 0)::integer into v_batch_balance
    from public.points_batches pb
   where pb.business_id = p_business
     and pb.client_id = p_client
     and pb.remaining > 0;
  if v_batch_balance < lp.redeem_points then
    raise exception 'points batches % cannot prove redemption %',
      v_batch_balance, lp.redeem_points
      using errcode = 'check_violation';
  end if;

  v_remaining := lp.redeem_points;
  for v_batch in
    select pb.id, pb.remaining
      from public.points_batches pb
     where pb.business_id = p_business
       and pb.client_id = p_client
       and pb.remaining > 0
     order by pb.expires_at nulls last, pb.earned_at, pb.id
     for update
  loop
    exit when v_remaining = 0;
    v_take := least(v_batch.remaining, v_remaining);
    update public.points_batches
       set remaining = remaining - v_take
     where id = v_batch.id;
    v_remaining := v_remaining - v_take;
  end loop;

  perform set_config('app.points_ledger_insert_id', v_points_id::text, true);
  perform set_config('app.points_ledger_write_scope', 'redeem_points', true);
  insert into public.points_ledger
    (id, business_id, client_id, entry_type, points, reference, actor)
  values
    (v_points_id, p_business, p_client, 'redeem', -lp.redeem_points,
     'redeemed to credit', v_actor);
  perform set_config('app.points_ledger_insert_id', '', true);
  perform set_config('app.points_ledger_write_scope', '', true);

  perform set_config('app.credit_ledger_insert_id', v_credit_id::text, true);
  perform set_config('app.credit_ledger_write_scope', 'redeem_points', true);
  insert into public.credit_ledger
    (id, business_id, client_id, entry_type, amount_cents, reference, actor)
  values
    (v_credit_id, p_business, p_client, 'loyalty_earn', lp.reward_credit_cents,
     'points redemption', v_actor);
  perform set_config('app.credit_ledger_insert_id', '', true);
  perform set_config('app.credit_ledger_write_scope', '', true);

  return json_build_object(
    'points_spent', lp.redeem_points,
    'credit_cents', lp.reward_credit_cents
  );
end $$;

-- (#1 + #3) redeem_reward final body: model gate, staff/client locks (parity with redeem_points),
--           FEFO batch drain with batch-proof, sanctioned ledger routes.
create or replace function public.redeem_reward(p_business uuid, p_client uuid, p_reward uuid, p_idempotency_key text default null)
returns json language plpgsql security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp' as $$
declare
  lp public.loyalty_programs%rowtype;
  v_reward public.loyalty_rewards%rowtype;
  v_balance integer;
  v_batch_balance integer;
  v_remaining integer;
  v_take integer;
  v_batch record;
  v_actor uuid := auth.uid();
  v_staff uuid;
  v_points_id uuid := gen_random_uuid();
  v_credit_id uuid := gen_random_uuid();
begin
  if not app.has_perm(p_business, 'create_sales') then
    raise exception 'not authorized to redeem loyalty rewards' using errcode = '42501';
  end if;

  select s.id into v_staff
    from public.staff s
   where s.business_id = p_business
     and s.user_id = v_actor
     and s.active
     and 'create_sales' = any (app.role_perms(s.role))
   order by case s.role when 'owner' then 0 when 'manager' then 1 else 2 end, s.created_at
   limit 1
   for update;
  if not found then
    raise exception 'active staff authorization changed while redeeming' using errcode = '42501';
  end if;

  perform 1 from public.clients c where c.id = p_client and c.business_id = p_business for update;
  if not found then
    raise exception 'client does not belong to this business';
  end if;

  select * into lp from public.loyalty_programs where business_id = p_business and active limit 1;
  if not found then
    raise exception 'no active loyalty program';
  end if;
  if lp.loyalty_model is distinct from 'points_tiers' then
    raise exception 'this business uses fixed-value redemption (classic model) — use redeem_points';
  end if;

  select * into v_reward from public.loyalty_rewards where id = p_reward and business_id = p_business and active;
  if not found then raise exception 'reward not found or inactive'; end if;

  select coalesce(sum(points),0) into v_balance from public.points_ledger
    where business_id = p_business and client_id = p_client;
  if v_balance < v_reward.cost_points then
    raise exception 'insufficient points: % < %', v_balance, v_reward.cost_points using errcode = 'check_violation';
  end if;

  select coalesce(sum(pb.remaining),0)::integer into v_batch_balance
    from public.points_batches pb
   where pb.business_id = p_business and pb.client_id = p_client and pb.remaining > 0;
  if v_batch_balance < v_reward.cost_points then
    raise exception 'points batches % cannot prove redemption %', v_batch_balance, v_reward.cost_points
      using errcode = 'check_violation';
  end if;

  -- FEFO drain, identical ordering to redeem_points: soonest expiry, then oldest earn.
  v_remaining := v_reward.cost_points;
  for v_batch in
    select pb.id, pb.remaining
      from public.points_batches pb
     where pb.business_id = p_business and pb.client_id = p_client and pb.remaining > 0
     order by pb.expires_at nulls last, pb.earned_at, pb.id
     for update
  loop
    exit when v_remaining = 0;
    v_take := least(v_batch.remaining, v_remaining);
    update public.points_batches set remaining = remaining - v_take where id = v_batch.id;
    v_remaining := v_remaining - v_take;
  end loop;

  perform set_config('app.points_ledger_insert_id', v_points_id::text, true);
  perform set_config('app.points_ledger_write_scope', 'redeem_points', true);
  insert into public.points_ledger (id, business_id, client_id, entry_type, points, reference, actor)
    values (v_points_id, p_business, p_client, 'redeem', -v_reward.cost_points, 'reward: ' || v_reward.name, v_actor);
  perform set_config('app.points_ledger_insert_id', '', true);
  perform set_config('app.points_ledger_write_scope', '', true);

  if v_reward.credit_cents > 0 then
    perform set_config('app.credit_ledger_insert_id', v_credit_id::text, true);
    perform set_config('app.credit_ledger_write_scope', 'redeem_points', true);
    insert into public.credit_ledger (id, business_id, client_id, entry_type, amount_cents, reference, actor)
      values (v_credit_id, p_business, p_client, 'loyalty_earn', v_reward.credit_cents, 'loyalty reward: ' || v_reward.name, v_actor);
    perform set_config('app.credit_ledger_insert_id', '', true);
    perform set_config('app.credit_ledger_write_scope', '', true);
  end if;

  insert into public.loyalty_redemptions (business_id, client_id, reward_id, reward_name, points_spent, credit_cents, actor)
    values (p_business, p_client, v_reward.id, v_reward.name, v_reward.cost_points, v_reward.credit_cents, v_actor);

  return json_build_object('ok', true, 'reward', v_reward.name, 'points_spent', v_reward.cost_points, 'credit_cents', v_reward.credit_cents);
end $$;

-- ACLs: public-schema create-or-replace re-applies the anon default — re-revoke (v21 invariant).
revoke all on function public.redeem_points(uuid, uuid) from public, anon;
grant execute on function public.redeem_points(uuid, uuid) to authenticated;
revoke all on function public.redeem_reward(uuid, uuid, uuid, text) from public, anon;
grant execute on function public.redeem_reward(uuid, uuid, uuid, text) to authenticated;

