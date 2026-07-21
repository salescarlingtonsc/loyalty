-- FRENLY v24a - IDEMPOTENT LOYALTY REDEMPTIONS
-- Local review candidate. Do not apply until the phase release gate is accepted.
--
-- A redemption is a financial operation: a lost HTTP response or double-click must not
-- spend points twice. Both redemption RPCs therefore reserve an immutable operation key
-- before touching batches or ledgers. An exact replay returns the first result; reuse for
-- another actor or request is rejected.

begin;

create table if not exists public.loyalty_operations (
  id uuid primary key,
  business_id uuid not null references public.businesses(id) on delete cascade,
  client_id uuid not null,
  reward_id uuid,
  operation_type text not null
    check (operation_type in ('redeem_points', 'redeem_reward')),
  actor uuid not null,
  idempotency_key text not null check (length(btrim(idempotency_key)) >= 8),
  request_payload jsonb not null check (jsonb_typeof(request_payload) = 'object'),
  request_hash text not null check (
    length(request_hash) = 32 and request_hash = md5(request_payload::text)
  ),
  status text not null default 'reserved' check (status in ('reserved', 'completed')),
  result jsonb,
  created_at timestamptz not null default now(),
  completed_at timestamptz,
  constraint loyalty_operations_client_fk foreign key (client_id, business_id)
    references public.clients(id, business_id) on delete no action,
  constraint loyalty_operations_reward_fk foreign key (reward_id)
    references public.loyalty_rewards(id) on delete no action,
  constraint loyalty_operations_idempotency_uk unique
    (business_id, operation_type, idempotency_key),
  constraint loyalty_operations_shape_check check (
    (operation_type = 'redeem_points' and reward_id is null)
    or (operation_type = 'redeem_reward' and reward_id is not null)
  ),
  constraint loyalty_operations_completion_check check (
    (status = 'reserved' and result is null and completed_at is null)
    or (status = 'completed' and result is not null and completed_at is not null)
  )
);

create index if not exists loyalty_operations_client_time_idx
  on public.loyalty_operations (business_id, client_id, created_at desc);

alter table public.loyalty_operations enable row level security;
drop policy if exists loyalty_operations_select on public.loyalty_operations;
create policy loyalty_operations_select
  on public.loyalty_operations for select to authenticated
  using (app.has_perm(business_id, 'view_finance'));

revoke all privileges on table public.loyalty_operations from public, anon, authenticated;
grant select on table public.loyalty_operations to authenticated;

create or replace function app.loyalty_operation_write_guard()
returns trigger
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_token text;
begin
  if tg_op = 'INSERT' then
    v_token := nullif(current_setting('app.loyalty_operation_insert_id', true), '');
    if v_token is distinct from new.id::text then
      raise exception 'loyalty operations may only be reserved by a loyalty RPC'
        using errcode = '42501';
    end if;
    return new;
  end if;

  if tg_op = 'DELETE' then
    raise exception 'loyalty_operations is append-only: DELETE is not permitted'
      using errcode = 'restrict_violation';
  end if;

  v_token := nullif(current_setting('app.loyalty_operation_complete_id', true), '');
  if v_token is distinct from old.id::text
     or old.status <> 'reserved'
     or new.status <> 'completed'
     or (new.id, new.business_id, new.client_id, new.reward_id, new.operation_type,
         new.actor, new.idempotency_key, new.request_payload, new.request_hash, new.created_at)
        is distinct from
        (old.id, old.business_id, old.client_id, old.reward_id, old.operation_type,
         old.actor, old.idempotency_key, old.request_payload, old.request_hash, old.created_at)
     or new.result is null
     or new.completed_at is null then
    raise exception 'loyalty operation % may only transition reserved -> completed', old.id
      using errcode = 'restrict_violation';
  end if;
  return new;
end $$;

revoke execute on function app.loyalty_operation_write_guard()
  from public, anon, authenticated;

drop trigger if exists trg_loyalty_operation_write_guard on public.loyalty_operations;
create trigger trg_loyalty_operation_write_guard
  before insert or update or delete on public.loyalty_operations
  for each row execute function app.loyalty_operation_write_guard();

-- New required-key overload. The legacy two-argument overload remains in the catalog so
-- migration application cannot break unknown dependencies, but loses application EXECUTE.
create or replace function public.redeem_points(
  p_business uuid,
  p_client uuid,
  p_idempotency_key text
)
returns json
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
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
  v_operation_id uuid := gen_random_uuid();
  v_payload jsonb;
  v_operation public.loyalty_operations%rowtype;
  v_rows integer;
  v_result json;
begin
  if p_idempotency_key is null or length(btrim(p_idempotency_key)) < 8 then
    raise exception 'idempotency key must contain at least 8 characters' using errcode = '22023';
  end if;
  p_idempotency_key := btrim(p_idempotency_key);
  if not app.has_perm(p_business, 'create_sales') then
    raise exception 'you do not have permission to redeem points in this business (create_sales)'
      using errcode = '42501';
  end if;
  perform 1 from public.businesses where id = p_business for share;

  select s.id into v_staff
    from public.staff s
   where s.business_id = p_business and s.user_id = v_actor and s.active
     and 'create_sales' = any (app.role_perms(s.role))
   order by case s.role when 'owner' then 0 when 'manager' then 1 else 2 end, s.created_at
   limit 1 for update;
  if not found or not app.has_perm(p_business, 'create_sales') then
    raise exception 'active staff authorization changed while redeeming points'
      using errcode = '42501';
  end if;

  perform 1 from public.clients c
   where c.id = p_client and c.business_id = p_business for update;
  if not found then raise exception 'client does not belong to this business'; end if;

  v_payload := jsonb_build_object('business_id', p_business, 'client_id', p_client);
  perform set_config('app.loyalty_operation_insert_id', v_operation_id::text, true);
  insert into public.loyalty_operations
    (id, business_id, client_id, operation_type, actor, idempotency_key,
     request_payload, request_hash)
  values
    (v_operation_id, p_business, p_client, 'redeem_points', v_actor,
     p_idempotency_key, v_payload, md5(v_payload::text))
  on conflict (business_id, operation_type, idempotency_key) do nothing;
  get diagnostics v_rows = row_count;
  perform set_config('app.loyalty_operation_insert_id', '', true);

  if v_rows = 0 then
    select * into v_operation from public.loyalty_operations
     where business_id = p_business and operation_type = 'redeem_points'
       and idempotency_key = p_idempotency_key
     for update;
    if v_operation.actor is distinct from v_actor
       or v_operation.request_payload is distinct from v_payload then
      raise exception 'idempotency key was already used for another redemption request'
        using errcode = '22023';
    end if;
    if v_operation.status = 'completed' then return v_operation.result::json; end if;
    raise exception 'matching redemption is still reserved; retry shortly' using errcode = '40001';
  end if;

  select * into lp from public.loyalty_programs
   where business_id = p_business and active and kind = 'points'
     and redeem_points > 0 and reward_credit_cents > 0 limit 1;
  if not found then
    raise exception 'no active redeemable points program with positive points and credit values';
  end if;
  if lp.loyalty_model is distinct from 'classic' then
    raise exception 'this business redeems points through its reward catalog; use redeem_reward';
  end if;

  select coalesce(sum(pl.points), 0)::integer into bal from public.points_ledger pl
   where pl.business_id = p_business and pl.client_id = p_client;
  if bal < lp.redeem_points then
    raise exception 'insufficient points: % < %', bal, lp.redeem_points;
  end if;
  select coalesce(sum(pb.remaining), 0)::integer into v_batch_balance
    from public.points_batches pb
   where pb.business_id = p_business and pb.client_id = p_client and pb.remaining > 0;
  if v_batch_balance < lp.redeem_points then
    raise exception 'points batches % cannot prove redemption %', v_batch_balance, lp.redeem_points
      using errcode = 'check_violation';
  end if;

  v_remaining := lp.redeem_points;
  for v_batch in
    select pb.id, pb.remaining from public.points_batches pb
     where pb.business_id = p_business and pb.client_id = p_client and pb.remaining > 0
     order by pb.expires_at nulls last, pb.earned_at, pb.id for update
  loop
    exit when v_remaining = 0;
    v_take := least(v_batch.remaining, v_remaining);
    update public.points_batches set remaining = remaining - v_take where id = v_batch.id;
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

  v_result := json_build_object(
    'points_spent', lp.redeem_points,
    'credit_cents', lp.reward_credit_cents
  );
  perform set_config('app.loyalty_operation_complete_id', v_operation_id::text, true);
  update public.loyalty_operations
     set status = 'completed', result = v_result::jsonb, completed_at = now()
   where id = v_operation_id;
  perform set_config('app.loyalty_operation_complete_id', '', true);
  return v_result;
end $$;

create or replace function public.redeem_reward(
  p_business uuid,
  p_client uuid,
  p_reward uuid,
  -- v23 created this argument with DEFAULT NULL. PostgreSQL will not remove an
  -- existing argument default through CREATE OR REPLACE FUNCTION, so retain
  -- the catalog-compatible default and enforce the key in the function body.
  p_idempotency_key text default null
)
returns json
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
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
  v_operation_id uuid := gen_random_uuid();
  v_payload jsonb;
  v_operation public.loyalty_operations%rowtype;
  v_rows integer;
  v_result json;
begin
  if p_idempotency_key is null or length(btrim(p_idempotency_key)) < 8 then
    raise exception 'idempotency key must contain at least 8 characters' using errcode = '22023';
  end if;
  p_idempotency_key := btrim(p_idempotency_key);
  if not app.has_perm(p_business, 'create_sales') then
    raise exception 'not authorized to redeem loyalty rewards' using errcode = '42501';
  end if;
  perform 1 from public.businesses where id = p_business for share;

  select s.id into v_staff from public.staff s
   where s.business_id = p_business and s.user_id = v_actor and s.active
     and 'create_sales' = any (app.role_perms(s.role))
   order by case s.role when 'owner' then 0 when 'manager' then 1 else 2 end, s.created_at
   limit 1 for update;
  if not found or not app.has_perm(p_business, 'create_sales') then
    raise exception 'active staff authorization changed while redeeming'
      using errcode = '42501';
  end if;

  perform 1 from public.clients c
   where c.id = p_client and c.business_id = p_business for update;
  if not found then raise exception 'client does not belong to this business'; end if;

  v_payload := jsonb_build_object(
    'business_id', p_business, 'client_id', p_client, 'reward_id', p_reward
  );
  perform set_config('app.loyalty_operation_insert_id', v_operation_id::text, true);
  insert into public.loyalty_operations
    (id, business_id, client_id, reward_id, operation_type, actor, idempotency_key,
     request_payload, request_hash)
  values
    (v_operation_id, p_business, p_client, p_reward, 'redeem_reward', v_actor,
     p_idempotency_key, v_payload, md5(v_payload::text))
  on conflict (business_id, operation_type, idempotency_key) do nothing;
  get diagnostics v_rows = row_count;
  perform set_config('app.loyalty_operation_insert_id', '', true);

  if v_rows = 0 then
    select * into v_operation from public.loyalty_operations
     where business_id = p_business and operation_type = 'redeem_reward'
       and idempotency_key = p_idempotency_key
     for update;
    if v_operation.actor is distinct from v_actor
       or v_operation.request_payload is distinct from v_payload then
      raise exception 'idempotency key was already used for another redemption request'
        using errcode = '22023';
    end if;
    if v_operation.status = 'completed' then return v_operation.result::json; end if;
    raise exception 'matching redemption is still reserved; retry shortly' using errcode = '40001';
  end if;

  select * into lp from public.loyalty_programs
   where business_id = p_business and active limit 1;
  if not found then raise exception 'no active loyalty program'; end if;
  if lp.loyalty_model not in ('points_tiers', 'stamps') then
    raise exception 'this business uses fixed-value redemption; use redeem_points';
  end if;

  select * into v_reward from public.loyalty_rewards
   where id = p_reward and business_id = p_business and active;
  if not found then raise exception 'reward not found or inactive'; end if;

  select coalesce(sum(points), 0) into v_balance from public.points_ledger
   where business_id = p_business and client_id = p_client;
  if v_balance < v_reward.cost_points then
    raise exception 'insufficient points: % < %', v_balance, v_reward.cost_points
      using errcode = 'check_violation';
  end if;
  select coalesce(sum(pb.remaining), 0)::integer into v_batch_balance
    from public.points_batches pb
   where pb.business_id = p_business and pb.client_id = p_client and pb.remaining > 0;
  if v_batch_balance < v_reward.cost_points then
    raise exception 'points batches % cannot prove redemption %', v_batch_balance, v_reward.cost_points
      using errcode = 'check_violation';
  end if;

  v_remaining := v_reward.cost_points;
  for v_batch in
    select pb.id, pb.remaining from public.points_batches pb
     where pb.business_id = p_business and pb.client_id = p_client and pb.remaining > 0
     order by pb.expires_at nulls last, pb.earned_at, pb.id for update
  loop
    exit when v_remaining = 0;
    v_take := least(v_batch.remaining, v_remaining);
    update public.points_batches set remaining = remaining - v_take where id = v_batch.id;
    v_remaining := v_remaining - v_take;
  end loop;

  perform set_config('app.points_ledger_insert_id', v_points_id::text, true);
  perform set_config('app.points_ledger_write_scope', 'redeem_points', true);
  insert into public.points_ledger
    (id, business_id, client_id, entry_type, points, reference, actor)
  values
    (v_points_id, p_business, p_client, 'redeem', -v_reward.cost_points,
     'reward: ' || v_reward.name, v_actor);
  perform set_config('app.points_ledger_insert_id', '', true);
  perform set_config('app.points_ledger_write_scope', '', true);

  if v_reward.credit_cents > 0 then
    perform set_config('app.credit_ledger_insert_id', v_credit_id::text, true);
    perform set_config('app.credit_ledger_write_scope', 'redeem_points', true);
    insert into public.credit_ledger
      (id, business_id, client_id, entry_type, amount_cents, reference, actor)
    values
      (v_credit_id, p_business, p_client, 'loyalty_earn', v_reward.credit_cents,
       'loyalty reward: ' || v_reward.name, v_actor);
    perform set_config('app.credit_ledger_insert_id', '', true);
    perform set_config('app.credit_ledger_write_scope', '', true);
  end if;

  insert into public.loyalty_redemptions
    (business_id, client_id, reward_id, reward_name, points_spent, credit_cents, actor)
  values
    (p_business, p_client, v_reward.id, v_reward.name, v_reward.cost_points,
     v_reward.credit_cents, v_actor);

  v_result := json_build_object(
    'ok', true,
    'reward', v_reward.name,
    'points_spent', v_reward.cost_points,
    'credit_cents', v_reward.credit_cents
  );
  perform set_config('app.loyalty_operation_complete_id', v_operation_id::text, true);
  update public.loyalty_operations
     set status = 'completed', result = v_result::jsonb, completed_at = now()
   where id = v_operation_id;
  perform set_config('app.loyalty_operation_complete_id', '', true);
  return v_result;
end $$;

-- Public functions are born PUBLIC-executable in existing projects unless explicitly revoked.
revoke all on function public.redeem_points(uuid, uuid) from public, anon, authenticated;
revoke all on function public.redeem_points(uuid, uuid, text) from public, anon;
grant execute on function public.redeem_points(uuid, uuid, text) to authenticated;
revoke all on function public.redeem_reward(uuid, uuid, uuid, text) from public, anon;
grant execute on function public.redeem_reward(uuid, uuid, uuid, text) to authenticated;

commit;
