alter table public.sales
  add column if not exists counts_as_revenue  boolean,
  add column if not exists counts_as_visit    boolean,
  add column if not exists earns_points       boolean,
  add column if not exists policy_resolved_at timestamptz;
comment on column public.sales.counts_as_revenue is
  'IMMUTABLE SNAPSHOT of sale_policies as resolved when this sale was RECORDED. Historical '
  'reporting MUST read this column, never app.sale_policy(). Changed only by '
  'public.reclassify_sale_policy() (audited, owner-only).';
comment on column public.sales.counts_as_visit is
  'Immutable snapshot — see counts_as_revenue. NEVER changeable after insert: the loyalty '
  'ledgers (reward_grants, referrals, credit_ledger) were written against this value.';
comment on column public.sales.earns_points is
  'Immutable snapshot — see counts_as_revenue. NEVER changeable after insert: points_ledger '
  'and points_batches were written against this value.';
comment on column public.sales.policy_resolved_at is
  'When the snapshot was taken (insert time). Backfilled rows carry created_at.';
update public.sales s set
  counts_as_revenue  = (select d.counts_as_revenue from app.sale_policy(s.business_id, s.kind) d),
  counts_as_visit    = (select d.counts_as_visit   from app.sale_policy(s.business_id, s.kind) d),
  earns_points       = (select d.earns_points      from app.sale_policy(s.business_id, s.kind) d),
  policy_resolved_at = s.created_at
where counts_as_revenue is null;
alter table public.sales
  alter column counts_as_revenue  set not null,
  alter column counts_as_visit    set not null,
  alter column earns_points       set not null,
  alter column policy_resolved_at set not null;
create index if not exists sales_visit_window_idx
  on public.sales (business_id, client_id, occurred_at)
  where counts_as_visit;
create or replace function app.role_perms(p_role text)
returns text[] language sql immutable as $$
  select case p_role
    when 'owner' then array['view_sales','create_sales','refund_sales',
                            'reclassify_sales','view_finance','manage_sale_policy']
    when 'manager' then array['view_sales','create_sales','refund_sales','view_finance']
    when 'stylist' then array['view_sales','create_sales']
    when 'frontdesk' then array['view_sales','create_sales']
    else array[]::text[]
  end
$$;
create or replace function app.has_perm(p_business uuid, p_perm text)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.staff s
    where s.business_id = p_business
      and s.user_id = auth.uid()          -- NULL user_id (v11a rota staff) => never matches
      and p_perm = any (app.role_perms(s.role))
  )
$$;
drop policy if exists sales_all on public.sales;
create policy sales_select on public.sales for select to authenticated
  using (app.has_perm(business_id, 'view_sales'));
create policy sales_insert on public.sales for insert to authenticated
  with check (app.has_perm(business_id, 'create_sales'));
revoke update, delete, truncate on public.sales from authenticated, anon;
create or replace function app.begin_sales_backfill(p_migration text, p_reason text)
returns void language plpgsql set search_path = public as $$
begin
  if p_migration is null or length(btrim(p_migration)) < 3 then
    raise exception 'begin_sales_backfill requires the migration name that is opening the window';
  end if;
  if p_reason is null or length(btrim(p_reason)) < 10 then
    raise exception 'begin_sales_backfill requires a reason of at least 10 characters';
  end if;
  insert into audit_log (business_id, actor, action, entity, entity_id, detail)
  values (null, auth.uid(), 'SALES_BACKFILL_WINDOW_OPEN', 'sales', null,
          jsonb_build_object('migration', btrim(p_migration),
                             'reason',    btrim(p_reason),
                             'db_user',   current_user,
                             'opened_at', now(),
                             'scope', 'columns added after v10.1 only; all v10.1-era columns '
                                      'incl. the policy snapshot remain frozen'));
  perform set_config('app.sales_backfill', btrim(p_migration), true);   -- true = txn-local
end $$;
revoke execute on function app.begin_sales_backfill(text, text) from public, anon, authenticated;
create or replace function app.end_sales_backfill()
returns void language plpgsql set search_path = public as $$
begin
  insert into audit_log (business_id, actor, action, entity, entity_id, detail)
  values (null, auth.uid(), 'SALES_BACKFILL_WINDOW_CLOSE', 'sales', null,
          jsonb_build_object('migration', nullif(current_setting('app.sales_backfill', true), ''),
                             'db_user', current_user, 'closed_at', now()));
  perform set_config('app.sales_backfill', '', true);
end $$;
revoke execute on function app.end_sales_backfill() from public, anon, authenticated;
create or replace function app.sales_immutable_guard()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_reclassify text; v_backfill text;
begin
  if tg_op = 'DELETE' then
    raise exception 'sales is append-only: DELETE is not permitted (sale %). There is no '
                    'reversal path in this schema yet — refunds/reversals are deferred to '
                    'v11b.', old.id
      using errcode = 'restrict_violation';
  end if;
  v_reclassify := nullif(current_setting('app.reclassify_sale', true), '');
  v_backfill   := nullif(current_setting('app.sales_backfill',  true), '');
  if v_reclassify is not null and v_reclassify = old.id::text then
    if (new.id, new.business_id, new.client_id, new.kind, new.amount_cents, new.occurred_at,
        new.created_at, new.note, new.appointment_id, new.product_id, new.qty,
        new.counts_as_visit, new.earns_points, new.policy_resolved_at)
       is distinct from
       (old.id, old.business_id, old.client_id, old.kind, old.amount_cents, old.occurred_at,
        old.created_at, old.note, old.appointment_id, old.product_id, old.qty,
        old.counts_as_visit, old.earns_points, old.policy_resolved_at)
    then
      raise exception 'reclassification of sale % may change counts_as_revenue and nothing '
                      'else', old.id
        using errcode = 'restrict_violation';
    end if;
    return new;
  end if;
  if v_backfill is not null then
    if (new.id, new.business_id, new.client_id, new.kind, new.amount_cents, new.occurred_at,
        new.created_at, new.note, new.appointment_id, new.product_id, new.qty,
        new.counts_as_revenue, new.counts_as_visit, new.earns_points, new.policy_resolved_at)
       is distinct from
       (old.id, old.business_id, old.client_id, old.kind, old.amount_cents, old.occurred_at,
        old.created_at, old.note, old.appointment_id, old.product_id, old.qty,
        old.counts_as_revenue, old.counts_as_visit, old.earns_points, old.policy_resolved_at)
    then
      raise exception 'backfill window "%" may only populate columns added after v10.1; it '
                      'may not change any economic fact or the policy snapshot of sale %',
                      v_backfill, old.id
        using errcode = 'restrict_violation';
    end if;
    return new;
  end if;
  raise exception 'sales is append-only: UPDATE is not permitted (sale %). Use '
                  'public.reclassify_sale_policy() for an audited revenue restatement, or '
                  'app.begin_sales_backfill() from a migration to populate a new column.',
                  old.id
    using errcode = 'restrict_violation';
end $$;
drop trigger if exists trg_sales_immutable_guard on public.sales;
create trigger trg_sales_immutable_guard
  before update or delete on public.sales
  for each row execute function app.sales_immutable_guard();
create or replace function app.on_sale_policy_snapshot()
returns trigger language plpgsql security definer set search_path = public as $$
declare p record;
begin
  select * into p from app.sale_policy(new.business_id, new.kind);
  if not found then
    new.counts_as_revenue := false;
    new.counts_as_visit   := false;
    new.earns_points      := false;
  else
    new.counts_as_revenue := p.counts_as_revenue;
    new.counts_as_visit   := p.counts_as_visit;
    new.earns_points      := p.earns_points;
  end if;
  new.policy_resolved_at := now();
  return new;
end $$;
drop trigger if exists trg_sale_policy_snapshot on public.sales;
create trigger trg_sale_policy_snapshot
  before insert on public.sales
  for each row execute function app.on_sale_policy_snapshot();
create or replace function app.on_sale_recorded()
returns trigger language plpgsql security definer set search_path = public as $$
declare lp record; rp record; refrow record; refprog record;
        v_pts integer; v_idx integer; v_count integer; v_earn_id uuid;
        w_start timestamptz; w_end timestamptz;
begin
  if new.client_id is null then
    return new;
  end if;
  if not (new.earns_points or new.counts_as_visit) then
    return new;
  end if;
  if new.earns_points then
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
  if new.counts_as_visit then
    for rp in select * from retention_programs
        where business_id = new.business_id and active loop
      v_idx := floor(extract(epoch from (new.occurred_at - rp.starts_on::timestamptz))
                     / (rp.period_days * 86400));
      if v_idx >= 0 then
        w_start := rp.starts_on::timestamptz + make_interval(days => v_idx * rp.period_days);
        w_end   := w_start + make_interval(days => rp.period_days);
        select count(*) into v_count from sales s
          where s.business_id = new.business_id and s.client_id = new.client_id
            and s.counts_as_visit
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
create or replace function public.set_sale_policy(
  p_business          uuid,
  p_kind              text,
  p_counts_as_revenue boolean,
  p_counts_as_visit   boolean,
  p_earns_points      boolean,
  p_note              text default null)
returns json language plpgsql security definer set search_path = public as $$
declare v_row record;
begin
  if not app.has_perm(p_business, 'manage_sale_policy') then
    raise exception 'only an owner may change sale accounting policy';
  end if;
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
create or replace function public.reclassify_sale_policy(
  p_sale              uuid,
  p_counts_as_revenue boolean,
  p_reason            text)
returns json language plpgsql security definer set search_path = public as $$
declare o sales; n sales;
begin
  if p_counts_as_revenue is null then
    raise exception 'p_counts_as_revenue is required (it is the only flag this RPC may change)';
  end if;
  if p_reason is null or length(btrim(p_reason)) < 10 then
    raise exception 'a reason of at least 10 characters is required to reclassify a historical sale';
  end if;
  select * into o from sales where id = p_sale;
  if not found then raise exception 'sale not found'; end if;
  if not app.has_perm(o.business_id, 'reclassify_sales') then
    raise exception 'only an owner may reclassify a historical sale';
  end if;
  if o.counts_as_revenue = p_counts_as_revenue then
    raise exception 'sale % already has counts_as_revenue = %; nothing to restate',
                    p_sale, p_counts_as_revenue;
  end if;
  perform set_config('app.reclassify_sale', p_sale::text, true);   -- true = transaction-local
  update sales set counts_as_revenue = p_counts_as_revenue where id = p_sale
  returning * into n;
  perform set_config('app.reclassify_sale', '', true);             -- close the window immediately
  insert into audit_log (business_id, actor, action, entity, entity_id, detail)
  values (o.business_id, auth.uid(), 'RECLASSIFY', 'sales', o.id,
          jsonb_build_object(
            'reason', p_reason,
            'occurred_at', o.occurred_at,
            'kind', o.kind,
            'amount_cents', o.amount_cents,
            'before', jsonb_build_object('counts_as_revenue', o.counts_as_revenue),
            'after',  jsonb_build_object('counts_as_revenue', n.counts_as_revenue),
            'frozen', jsonb_build_object('counts_as_visit', o.counts_as_visit,
                                         'earns_points',    o.earns_points),
            'note', 'revenue reclassification only. counts_as_visit and earns_points are '
                    'immutable because points_ledger / points_batches / reward_grants / '
                    'referrals / credit_ledger were written against them. No loyalty side '
                    'effect was re-run and none was reversed.'));
  return row_to_json(n);
end $$;
revoke execute on function public.reclassify_sale_policy(uuid, boolean, text) from public, anon;
grant execute on function public.reclassify_sale_policy(uuid, boolean, text) to authenticated;
drop function if exists public.reclassify_sale_policy(uuid, boolean, boolean, boolean, text);
drop function if exists public.reverse_sale(uuid, text);