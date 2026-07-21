-- FRENLY v34 - EXACT PACKAGE AND LOYALTY REVERSAL PROVENANCE
-- Local review candidate. Do not apply until the phase release gate is accepted.

begin;

-- Composite identities let every provenance edge prove tenant ownership structurally.
alter table public.client_packages
  add constraint client_packages_id_business_uk unique (id,business_id);
alter table public.loyalty_operations
  add constraint loyalty_operations_id_business_uk unique (id,business_id);
alter table public.loyalty_redemptions
  add constraint loyalty_redemptions_id_business_uk unique (id,business_id);
alter table public.points_ledger
  add constraint points_ledger_id_business_uk unique (id,business_id);
alter table public.points_batches
  add constraint points_batches_id_business_uk unique (id,business_id);

create table public.package_session_consumptions (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete restrict,
  client_package_id uuid not null,
  client_id uuid not null,
  sale_id uuid not null,
  actor uuid not null,
  idempotency_key text not null check (length(btrim(idempotency_key)) >= 8),
  request_payload jsonb not null check (jsonb_typeof(request_payload) = 'object'),
  request_hash text not null check (request_hash = md5(request_payload::text)),
  remaining_before integer not null check (remaining_before > 0),
  remaining_after integer not null check (remaining_after = remaining_before - 1),
  created_at timestamptz not null default now(),
  constraint package_session_consumptions_client_fk foreign key (client_id, business_id)
    references public.clients(id, business_id) on delete restrict,
  constraint package_session_consumptions_package_fk foreign key (client_package_id,business_id)
    references public.client_packages(id,business_id) on delete restrict,
  constraint package_session_consumptions_sale_fk foreign key (sale_id, business_id)
    references public.sales(id, business_id) on delete restrict,
  constraint package_session_consumptions_operation_uk unique (business_id, idempotency_key),
  constraint package_session_consumptions_id_business_uk unique (id,business_id),
  constraint package_session_consumptions_sale_uk unique (sale_id)
);

create table public.package_session_reversals (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete restrict,
  consumption_id uuid not null,
  original_sale_id uuid not null,
  reversal_sale_id uuid not null,
  actor uuid not null,
  idempotency_key text not null check (length(btrim(idempotency_key)) >= 8),
  request_payload jsonb not null check (jsonb_typeof(request_payload) = 'object'),
  request_hash text not null check (request_hash = md5(request_payload::text)),
  restored_sessions integer not null default 1 check (restored_sessions = 1),
  created_at timestamptz not null default now(),
  constraint package_session_reversals_original_fk foreign key (original_sale_id, business_id)
    references public.sales(id, business_id) on delete restrict,
  constraint package_session_reversals_consumption_fk foreign key (consumption_id,business_id)
    references public.package_session_consumptions(id,business_id) on delete restrict,
  constraint package_session_reversals_reversal_fk foreign key (reversal_sale_id, business_id)
    references public.sales(id, business_id) on delete restrict deferrable initially deferred,
  constraint package_session_reversals_consumption_uk unique (consumption_id),
  constraint package_session_reversals_original_sale_uk unique (original_sale_id),
  constraint package_session_reversals_reversal_sale_uk unique (reversal_sale_id),
  constraint package_session_reversals_operation_uk unique (business_id, idempotency_key)
);

create table public.loyalty_redemption_provenance (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete restrict,
  client_id uuid not null,
  operation_id uuid not null,
  redemption_id uuid not null,
  points_ledger_id uuid not null,
  credit_ledger_id uuid,
  config_version_id uuid not null,
  created_at timestamptz not null default now(),
  constraint loyalty_redemption_provenance_client_fk foreign key (client_id, business_id)
    references public.clients(id, business_id) on delete restrict,
  constraint loyalty_redemption_provenance_operation_fk foreign key (operation_id,business_id)
    references public.loyalty_operations(id,business_id) on delete restrict,
  constraint loyalty_redemption_provenance_redemption_fk foreign key (redemption_id,business_id)
    references public.loyalty_redemptions(id,business_id) on delete restrict,
  constraint loyalty_redemption_provenance_points_fk foreign key (points_ledger_id,business_id)
    references public.points_ledger(id,business_id) on delete restrict deferrable initially deferred,
  constraint loyalty_redemption_provenance_credit_fk foreign key (credit_ledger_id,business_id)
    references public.credit_ledger(id,business_id) on delete restrict deferrable initially deferred,
  constraint loyalty_redemption_provenance_config_fk foreign key (config_version_id,business_id)
    references public.firm_config_versions(id,business_id) on delete restrict,
  constraint loyalty_redemption_provenance_operation_uk unique (operation_id),
  constraint loyalty_redemption_provenance_id_business_uk unique (id,business_id),
  constraint loyalty_redemption_provenance_redemption_uk unique (redemption_id),
  constraint loyalty_redemption_provenance_points_uk unique (points_ledger_id),
  constraint loyalty_redemption_provenance_credit_uk unique (credit_ledger_id)
);

create table public.loyalty_redemption_batch_drains (
  id uuid primary key default gen_random_uuid(),
  provenance_id uuid not null,
  business_id uuid not null references public.businesses(id) on delete restrict,
  client_id uuid not null,
  redemption_id uuid not null,
  points_batch_id uuid not null,
  drained_points integer not null check (drained_points > 0),
  created_at timestamptz not null default now(),
  constraint loyalty_redemption_batch_drains_redemption_batch_uk
    unique (redemption_id, points_batch_id),
  constraint loyalty_redemption_batch_drains_client_fk foreign key (client_id,business_id)
    references public.clients(id,business_id) on delete restrict,
  constraint loyalty_redemption_batch_drains_provenance_fk foreign key (provenance_id,business_id)
    references public.loyalty_redemption_provenance(id,business_id) on delete restrict,
  constraint loyalty_redemption_batch_drains_redemption_fk foreign key (redemption_id,business_id)
    references public.loyalty_redemptions(id,business_id) on delete restrict,
  constraint loyalty_redemption_batch_drains_batch_fk foreign key (points_batch_id,business_id)
    references public.points_batches(id,business_id) on delete restrict
);

create table public.loyalty_redemption_reversals (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete restrict,
  redemption_id uuid not null,
  provenance_id uuid not null,
  client_id uuid not null,
  actor uuid not null,
  idempotency_key text not null check (length(btrim(idempotency_key)) >= 8),
  request_payload jsonb not null check (jsonb_typeof(request_payload) = 'object'),
  request_hash text not null check (request_hash = md5(request_payload::text)),
  restored_points_ledger_id uuid not null,
  reversed_credit_ledger_id uuid,
  result jsonb not null check (jsonb_typeof(result) = 'object'),
  created_at timestamptz not null default now(),
  constraint loyalty_redemption_reversals_redemption_uk unique (redemption_id),
  constraint loyalty_redemption_reversals_operation_uk unique (business_id, idempotency_key),
  constraint loyalty_redemption_reversals_client_fk foreign key (client_id,business_id)
    references public.clients(id,business_id) on delete restrict,
  constraint loyalty_redemption_reversals_redemption_fk foreign key (redemption_id,business_id)
    references public.loyalty_redemptions(id,business_id) on delete restrict,
  constraint loyalty_redemption_reversals_provenance_fk foreign key (provenance_id,business_id)
    references public.loyalty_redemption_provenance(id,business_id) on delete restrict,
  constraint loyalty_redemption_reversals_points_fk foreign key (restored_points_ledger_id,business_id)
    references public.points_ledger(id,business_id) on delete restrict,
  constraint loyalty_redemption_reversals_credit_fk foreign key (reversed_credit_ledger_id,business_id)
    references public.credit_ledger(id,business_id) on delete restrict
);

do $rls$
declare v_table text;
begin
  foreach v_table in array array[
    'package_session_consumptions', 'package_session_reversals',
    'loyalty_redemption_provenance', 'loyalty_redemption_batch_drains',
    'loyalty_redemption_reversals'
  ] loop
    execute format('alter table public.%I enable row level security', v_table);
    execute format('revoke all privileges on table public.%I from public, anon, authenticated', v_table);
  end loop;
end $rls$;

-- Kept explicit as well as catalog-looped so schema review tools can verify every evidence table.
alter table public.package_session_consumptions enable row level security;
alter table public.package_session_reversals enable row level security;
alter table public.loyalty_redemption_provenance enable row level security;
alter table public.loyalty_redemption_batch_drains enable row level security;
alter table public.loyalty_redemption_reversals enable row level security;
revoke all privileges on table public.package_session_consumptions from public, anon, authenticated;
revoke all privileges on table public.package_session_reversals from public, anon, authenticated;
revoke all privileges on table public.loyalty_redemption_provenance from public, anon, authenticated;
revoke all privileges on table public.loyalty_redemption_batch_drains from public, anon, authenticated;
revoke all privileges on table public.loyalty_redemption_reversals from public, anon, authenticated;

create or replace function app.v34_immutable_evidence_guard()
returns trigger language plpgsql security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
begin
  raise exception 'v34 financial provenance is append-only' using errcode = 'restrict_violation';
end $$;
revoke execute on function app.v34_immutable_evidence_guard() from public, anon, authenticated;

create trigger trg_package_session_consumptions_immutable before update or delete
  on public.package_session_consumptions for each row execute function app.v34_immutable_evidence_guard();
create trigger trg_package_session_reversals_immutable before update or delete
  on public.package_session_reversals for each row execute function app.v34_immutable_evidence_guard();
create trigger trg_loyalty_redemption_provenance_immutable before update or delete
  on public.loyalty_redemption_provenance for each row execute function app.v34_immutable_evidence_guard();
create trigger trg_loyalty_redemption_batch_drains_immutable before update or delete
  on public.loyalty_redemption_batch_drains for each row execute function app.v34_immutable_evidence_guard();
create trigger trg_loyalty_redemption_reversals_immutable before update or delete
  on public.loyalty_redemption_reversals for each row execute function app.v34_immutable_evidence_guard();

-- The browser must supply and retain this key until the request succeeds.
create or replace function public.use_package_session(
  p_business uuid, p_cp uuid, p_idempotency_key text
)
returns integer language plpgsql security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_cp public.client_packages%rowtype;
  v_plan public.package_plans%rowtype;
  v_existing public.package_session_consumptions%rowtype;
  v_actor uuid := auth.uid();
  v_staff uuid;
  v_branch uuid;
  v_sale_id uuid := gen_random_uuid();
  v_payload jsonb;
  v_request_hash text;
begin
  if p_idempotency_key is null or length(btrim(p_idempotency_key)) < 8 then
    raise exception 'idempotency key must contain at least 8 characters' using errcode = '22023';
  end if;
  if v_actor is null then raise exception 'authenticated staff required' using errcode = '42501'; end if;
  if not app.has_perm(p_business,'create_sales') then
    raise exception 'create_sales permission required' using errcode='42501';
  end if;
  select s.id into v_staff from public.staff s
   where s.business_id=p_business and s.user_id=v_actor and s.active
     and 'create_sales'=any(app.role_perms(s.role))
   order by case s.role when 'owner' then 0 when 'manager' then 1 else 2 end,s.created_at
   limit 1 for update;
  if not found then raise exception 'active staff authorization required' using errcode='42501'; end if;
  p_idempotency_key := btrim(p_idempotency_key);
  perform pg_advisory_xact_lock(hashtextextended(
    'v34:package-session:' || p_business::text || ':' || p_idempotency_key, 0
  ));
  v_payload := jsonb_build_object('business_id', p_business, 'client_package_id', p_cp);
  v_request_hash := md5(v_payload::text);

  select * into v_existing from public.package_session_consumptions
   where business_id = p_business and idempotency_key = p_idempotency_key;
  if found then
    if v_existing.actor is distinct from v_actor or v_existing.request_hash is distinct from v_request_hash then
      raise exception 'package session idempotency key conflicts with another request' using errcode = '23505';
    end if;
    return v_existing.remaining_after;
  end if;

  select * into v_cp from public.client_packages
   where id = p_cp and business_id = p_business for update;
  if not found then raise exception 'package not found'; end if;
  if v_cp.remaining <= 0 then raise exception 'no sessions remaining'; end if;
  select * into v_plan from public.package_plans
   where id = v_cp.plan_id and business_id = p_business for share;
  if not found then raise exception 'package plan not found in this business'; end if;
  select b.id into v_branch from public.branches b
   where b.business_id=p_business and b.active and app.can_see_branch(p_business,b.id)
     and (v_plan.service_id is null or not exists (
       select 1 from public.service_branches all_sb where all_sb.service_id=v_plan.service_id
     ) or exists (
       select 1 from public.service_branches allowed_sb
        where allowed_sb.service_id=v_plan.service_id and allowed_sb.branch_id=b.id
          and allowed_sb.business_id=p_business
     ))
   order by b.is_default desc,b.created_at,b.id limit 1;
  if not found then raise exception 'no active permitted branch can consume this package' using errcode='42501'; end if;

  update public.client_packages
     set remaining = remaining - 1,
         status = case when remaining - 1 = 0 then 'used_up' else 'active' end
   where id = v_cp.id and business_id = p_business and remaining > 0;
  if not found then raise exception 'package session was consumed concurrently' using errcode = '40001'; end if;

  -- This is the retention-visit record: amount_cents = 0 and no payment is created.
  insert into public.sales
    (id, business_id, client_id, kind, amount_cents, note, branch_id, staff_id)
  values (v_sale_id, p_business, v_cp.client_id, 'service', 0,
          'package session used: ' || v_plan.name, v_branch, v_staff);

  insert into public.package_session_consumptions
    (business_id, client_package_id, client_id, sale_id, actor, idempotency_key,
     request_payload, request_hash, remaining_before, remaining_after)
  values
    (p_business, v_cp.id, v_cp.client_id, v_sale_id, v_actor, p_idempotency_key,
     v_payload, v_request_hash, v_cp.remaining, v_cp.remaining - 1);
  return v_cp.remaining - 1;
end $$;

revoke all privileges on function public.use_package_session(uuid,uuid) from public, anon, authenticated;
revoke all privileges on function public.use_package_session(uuid,uuid,text) from public, anon;
grant execute on function public.use_package_session(uuid,uuid,text) to authenticated;

-- Permit a zero-dollar reversal row only when a package restoration evidence row already proves
-- the exact original and preallocated reversal IDs. The deferred FK closes the insertion cycle.
alter table public.sales
  drop constraint sales_reversal_metadata_check,
  drop constraint sales_amount_cents_check;
alter table public.sales
  add constraint sales_reversal_metadata_check check (
    (reversal_of is null and reversal_reason is null and reversal_actor is null and reversal_idempotency_key is null)
    or
    (reversal_of is not null and amount_cents <= 0 and appointment_id is null
     and reversal_actor is not null and reversal_idempotency_key is not null
     and length(btrim(coalesce(reversal_reason, ''))) >= 10)
  ),
  add constraint sales_amount_cents_check check (
    (reversal_of is null and amount_cents >= 0)
    or (reversal_of is not null and amount_cents <= 0)
  );

create or replace function app.enforce_sale_reversal_bounds()
returns trigger language plpgsql security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare o public.sales%rowtype; v_reversed integer;
begin
  if new.reversal_of is null then return new; end if;
  select * into o from public.sales
   where id = new.reversal_of and business_id = new.business_id;
  if not found then raise exception 'original sale not found for reversal %', new.id; end if;
  if o.reversal_of is not null then raise exception 'cannot reverse a reversal sale %', o.id; end if;
  if -new.amount_cents <> o.amount_cents then
    raise exception 'full reversal required: expected %, got %', o.amount_cents, -new.amount_cents;
  end if;
  if new.amount_cents = 0 and not exists (
    select 1 from public.package_session_reversals pr
     join public.package_session_consumptions pc on pc.id = pr.consumption_id
     where pr.business_id = new.business_id and pr.original_sale_id = o.id
       and pr.reversal_sale_id = new.id and pc.sale_id = o.id
  ) then
    raise exception 'zero-dollar reversal requires exact package session provenance' using errcode = '42501';
  end if;
  select coalesce(-sum(r.amount_cents),0)::integer into v_reversed
    from public.sales r where r.business_id=o.business_id and r.reversal_of=o.id;
  if v_reversed > o.amount_cents then raise exception 'reversal exceeds original sale'; end if;
  return new;
end $$;
revoke execute on function app.enforce_sale_reversal_bounds() from public, anon, authenticated;

alter function public.reverse_sale(uuid,uuid,text,text,text,text) rename to reverse_sale_v20_base;
revoke all privileges on function public.reverse_sale_v20_base(uuid,uuid,text,text,text,text)
  from public, anon, authenticated;

create or replace function public.reverse_sale(
  p_business uuid, p_sale uuid, p_reason text, p_idempotency_key text,
  p_reference text default null, p_restock_policy text default 'none'
)
returns json language plpgsql security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  o public.sales%rowtype;
  v_consumption public.package_session_consumptions%rowtype;
  v_existing public.package_session_reversals%rowtype;
  v_actor uuid := auth.uid();
  v_staff uuid;
  v_reversal_id uuid := gen_random_uuid();
  v_payload jsonb;
  v_request_hash text;
  v_result jsonb;
begin
  select * into o from public.sales where id=p_sale and business_id=p_business;
  if not found then raise exception 'sale not found in this business'; end if;
  if o.amount_cents > 0 then
    return public.reverse_sale_v20_base(p_business,p_sale,p_reason,p_idempotency_key,p_reference,p_restock_policy);
  end if;
  if o.amount_cents < 0 or o.reversal_of is not null then raise exception 'cannot reverse this sale'; end if;
  if p_idempotency_key is null or length(btrim(p_idempotency_key)) < 8 then
    raise exception 'idempotency key must contain at least 8 characters' using errcode='22023';
  end if;
  if p_reason is null or length(btrim(p_reason)) < 10 then raise exception 'reversal reason must contain at least 10 characters'; end if;
  if coalesce(p_restock_policy,'none') <> 'none' then raise exception 'package reversal does not restock inventory'; end if;
  if not app.has_perm(p_business,'refund_sales') then raise exception 'refund_sales permission required' using errcode='42501'; end if;
  if not app.can_see_branch(p_business,o.branch_id) then raise exception 'branch scope is not permitted' using errcode='42501'; end if;
  select s.id into v_staff from public.staff s
   where s.business_id=p_business and s.user_id=v_actor and s.active
     and 'refund_sales'=any(app.role_perms(s.role))
   order by case s.role when 'owner' then 0 when 'manager' then 1 else 2 end limit 1 for update;
  if not found then raise exception 'active staff authorization required' using errcode='42501'; end if;

  select * into o from public.sales where id=p_sale and business_id=p_business for update;
  if not app.has_perm(p_business,'refund_sales') or not app.can_see_branch(p_business,o.branch_id) then
    raise exception 'sale reversal authorization changed while locking' using errcode='42501';
  end if;
  select * into v_consumption from public.package_session_consumptions
   where business_id=p_business and sale_id=o.id for update;
  if not found then raise exception 'zero-dollar sale has no package session provenance'; end if;
  v_payload := jsonb_build_object('business_id',p_business,'sale_id',p_sale,'reason',btrim(p_reason),'actor',v_actor);
  v_request_hash := md5(v_payload::text);
  select * into v_existing from public.package_session_reversals where consumption_id=v_consumption.id;
  if found then
    if v_existing.idempotency_key is distinct from btrim(p_idempotency_key)
       or v_existing.request_hash is distinct from v_request_hash then
      raise exception 'package session already reversed by another immutable request' using errcode='23505';
    end if;
    return json_build_object('reversal_sale_id',v_existing.reversal_sale_id,'restored_sessions',1,
      'refunded_payment_cents',0,'no_money_refund',true,'replayed',true);
  end if;

  insert into public.package_session_reversals
    (business_id,consumption_id,original_sale_id,reversal_sale_id,actor,idempotency_key,
     request_payload,request_hash)
  values (p_business,v_consumption.id,o.id,v_reversal_id,v_actor,btrim(p_idempotency_key),v_payload,v_request_hash);
  update public.client_packages
     set remaining=remaining+1,status='active'
   where id=v_consumption.client_package_id and business_id=p_business;
  if not found then raise exception 'proven package no longer exists'; end if;

  perform set_config('app.sale_reversal_insert_id',v_reversal_id::text,true);
  perform set_config('app.sale_reversal_original_id',o.id::text,true);
  insert into public.sales
    (id,business_id,client_id,kind,amount_cents,occurred_at,note,branch_id,staff_id,
     reversal_of,reversal_reason,reversal_actor,reversal_idempotency_key)
  values
    (v_reversal_id,o.business_id,o.client_id,o.kind,0,now(),
     coalesce(nullif(btrim(p_reference),''),'package session reversal')||': '||left(btrim(p_reason),200),
     o.branch_id,o.staff_id,o.id,btrim(p_reason),v_actor,btrim(p_idempotency_key));
  perform set_config('app.sale_reversal_insert_id','',true);
  perform set_config('app.sale_reversal_original_id','',true);
  v_result := jsonb_build_object('reversal_sale_id',v_reversal_id,'restored_sessions',1,
    'refunded_payment_cents',0,'no_money_refund',true,'replayed',false);
  return v_result::json;
end $$;
revoke all privileges on function public.reverse_sale(uuid,uuid,text,text,text,text) from public, anon;
grant execute on function public.reverse_sale(uuid,uuid,text,text,text,text) to authenticated;

-- v34 adds one tightly-shaped compensation scope. It never creates a sale or payment row.
create or replace function app.loyalty_ledger_write_guard()
returns trigger language plpgsql security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare v_token text; v_scope text;
begin
  if tg_table_name='points_ledger' then
    v_token:=nullif(current_setting('app.points_ledger_insert_id',true),'');
    v_scope:=nullif(current_setting('app.points_ledger_write_scope',true),'');
    if v_token is distinct from new.id::text or v_scope not in
       ('sale_trigger','redeem_points','adjust_points','points_expiry','redemption_reversal') then
      raise exception 'points_ledger may only be appended by approved loyalty routes' using errcode='42501';
    end if;
    if (v_scope='sale_trigger' and (new.entry_type<>'earn' or new.points<=0 or new.sale_id is null))
       or (v_scope='redeem_points' and (new.entry_type<>'redeem' or new.points>=0 or new.sale_id is not null))
       or (v_scope='adjust_points' and (new.entry_type<>'adjust' or new.points=0 or new.sale_id is not null or new.actor is distinct from auth.uid()))
       or (v_scope='points_expiry' and (new.entry_type<>'expire' or new.points>=0 or new.sale_id is not null or new.actor is not null))
       or (v_scope='redemption_reversal' and (new.entry_type<>'adjust' or new.points<=0 or new.sale_id is not null or new.actor is distinct from auth.uid())) then
      raise exception 'points ledger entry does not match its internal route' using errcode='check_violation';
    end if;
  elsif tg_table_name='credit_ledger' then
    v_token:=nullif(current_setting('app.credit_ledger_insert_id',true),'');
    v_scope:=nullif(current_setting('app.credit_ledger_write_scope',true),'');
    if v_token is distinct from new.id::text or v_scope not in
       ('sale_trigger','redeem_points','redeem_gift_card','enroll_membership','membership_renewal','credit_tender','sale_reversal','redemption_reversal') then
      raise exception 'credit_ledger may only be appended by approved routes' using errcode='42501';
    end if;
    if (v_scope='sale_trigger' and (new.entry_type not in ('loyalty_earn','referral_reward') or new.amount_cents<=0 or new.sale_id is null))
       or (v_scope='redeem_points' and (new.entry_type<>'loyalty_earn' or new.amount_cents<=0 or new.sale_id is not null or new.payment_id is not null or new.actor is distinct from auth.uid()))
       or (v_scope='redeem_gift_card' and (new.entry_type<>'gift_card_load' or new.amount_cents<=0 or new.sale_id is not null or new.payment_id is not null or new.actor is distinct from auth.uid()))
       or (v_scope='enroll_membership' and (new.entry_type<>'membership_credit' or new.amount_cents<=0 or new.sale_id is null or new.payment_id is not null or new.actor is distinct from auth.uid()))
       or (v_scope='membership_renewal' and (new.entry_type<>'membership_credit' or new.amount_cents<=0 or new.sale_id is null or new.payment_id is not null or new.actor is not null))
       or (v_scope='credit_tender' and (new.entry_type<>'spend' or new.amount_cents>=0 or new.sale_id is null or new.payment_id is null or new.actor is distinct from auth.uid()))
       or (v_scope='sale_reversal' and (new.entry_type<>'manual_adjust' or new.amount_cents=0 or new.sale_id is null or new.actor is distinct from auth.uid()))
       or (v_scope='redemption_reversal' and (new.entry_type<>'manual_adjust' or new.amount_cents>=0 or new.sale_id is not null or new.payment_id is not null or new.actor is distinct from auth.uid())) then
      raise exception 'credit ledger entry does not match its internal route' using errcode='check_violation';
    end if;
  else raise exception 'unexpected loyalty ledger table';
  end if;
  return new;
end $$;
revoke execute on function app.loyalty_ledger_write_guard() from public, anon, authenticated;

-- Compensation rows inherit the reversed redemption's immutable configuration rather than the
-- currently active version. The one-transaction GUC is accepted only by this guarded route.
create or replace function app.stamp_config_version()
returns trigger language plpgsql security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_business uuid;
  v_version uuid;
  v_scope text;
  v_reversal_of uuid;
  v_sale_id uuid;
begin
  v_business:=new.business_id;
  perform 1 from public.businesses where id=v_business for share;
  -- NEW has a different composite type for every table using this trigger.
  -- Read table-specific keys through jsonb so missing fields remain NULL.
  if tg_table_name='sales' then
    v_reversal_of:=nullif(to_jsonb(new)->>'reversal_of','')::uuid;
  elsif tg_table_name in ('points_ledger','points_batches','credit_ledger') then
    v_sale_id:=nullif(to_jsonb(new)->>'sale_id','')::uuid;
  end if;
  if v_reversal_of is not null then
    select config_version_id into v_version from public.sales
     where id=v_reversal_of and business_id=v_business;
    if not found then raise exception 'reversal source sale not found'; end if;
  elsif v_sale_id is not null then
    select config_version_id into v_version from public.sales
     where id=v_sale_id and business_id=v_business;
    if not found then raise exception 'linked sale not found for config version'; end if;
  elsif tg_table_name in ('points_ledger','credit_ledger') then
    v_scope:=case when tg_table_name='points_ledger'
      then nullif(current_setting('app.points_ledger_write_scope',true),'')
      else nullif(current_setting('app.credit_ledger_write_scope',true),'') end;
    if v_scope='redemption_reversal' then
      v_version:=nullif(current_setting('app.redemption_reversal_config_version_id',true),'')::uuid;
      if v_version is null then raise exception 'redemption reversal config provenance is missing'; end if;
    else v_version:=app.active_config_version(v_business);
    end if;
  else v_version:=app.active_config_version(v_business);
  end if;
  if new.config_version_id is null then new.config_version_id:=v_version; end if;
  if new.config_version_id is distinct from v_version then
    raise exception 'event config version does not match its immutable source' using errcode='check_violation';
  end if;
  return new;
end $$;
revoke execute on function app.stamp_config_version() from public, anon, authenticated;

-- Replaces only the v27 catalog core. Every economic child ID and every FEFO drain is captured.
create or replace function app.redeem_reward_core(
  p_business uuid,p_client uuid,p_reward uuid,p_idempotency_key text,
  p_branch uuid default null,p_service uuid default null,p_product uuid default null
)
returns json language plpgsql security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  lp public.loyalty_programs%rowtype; v_reward public.loyalty_rewards%rowtype;
  v_version public.loyalty_reward_versions%rowtype; v_balance integer; v_batch_balance integer;
  v_remaining integer; v_take integer; v_batch record; v_actor uuid:=auth.uid(); v_staff uuid;
  v_points_id uuid:=gen_random_uuid(); v_credit_id uuid; v_operation_id uuid:=gen_random_uuid();
  v_redemption_id uuid:=gen_random_uuid(); v_provenance_id uuid:=gen_random_uuid();
  v_payload jsonb; v_operation public.loyalty_operations%rowtype; v_rows integer;
  v_usage integer; v_eligibility jsonb; v_result json;
begin
  if p_idempotency_key is null or length(btrim(p_idempotency_key))<8 then raise exception 'idempotency key must contain at least 8 characters' using errcode='22023'; end if;
  p_idempotency_key:=btrim(p_idempotency_key);
  if not app.has_perm(p_business,'create_sales') then raise exception 'not authorized' using errcode='42501'; end if;
  perform 1 from public.businesses where id=p_business for share;
  select s.id into v_staff from public.staff s where s.business_id=p_business and s.user_id=v_actor and s.active and 'create_sales'=any(app.role_perms(s.role)) limit 1 for update;
  if not found then raise exception 'active staff authorization required' using errcode='42501'; end if;
  perform 1 from public.clients c where c.id=p_client and c.business_id=p_business for update;
  if not found then raise exception 'client does not belong to this business'; end if;
  if p_branch is not null and not exists(select 1 from public.branches where id=p_branch and business_id=p_business) then raise exception 'branch does not belong to business'; end if;
  if not app.can_see_branch(p_business,p_branch) then
    raise exception 'redemption branch scope is not permitted' using errcode='42501';
  end if;
  if p_service is not null and not exists(select 1 from public.services where id=p_service and business_id=p_business) then raise exception 'service does not belong to business'; end if;
  if p_product is not null and not exists(select 1 from public.products where id=p_product and business_id=p_business) then raise exception 'product does not belong to business'; end if;
  v_payload:=jsonb_build_object('business_id',p_business,'client_id',p_client,'reward_id',p_reward,'branch_id',p_branch,'service_id',p_service,'product_id',p_product);
  perform set_config('app.loyalty_operation_insert_id',v_operation_id::text,true);
  insert into public.loyalty_operations(id,business_id,client_id,reward_id,operation_type,actor,idempotency_key,request_payload,request_hash)
  values(v_operation_id,p_business,p_client,p_reward,'redeem_reward',v_actor,p_idempotency_key,v_payload,md5(v_payload::text))
  on conflict(business_id,operation_type,idempotency_key) do nothing;
  get diagnostics v_rows=row_count; perform set_config('app.loyalty_operation_insert_id','',true);
  if v_rows=0 then
    select * into v_operation from public.loyalty_operations where business_id=p_business and operation_type='redeem_reward' and idempotency_key=p_idempotency_key for update;
    if v_operation.actor is distinct from v_actor or v_operation.request_hash is distinct from md5(v_payload::text) then raise exception 'idempotency conflict' using errcode='23505'; end if;
    if v_operation.status='completed' then return v_operation.result::json; end if;
    raise exception 'redemption already in progress' using errcode='55P03';
  end if;
  select * into lp from public.loyalty_programs where business_id=p_business and active limit 1;
  if not found or lp.loyalty_model not in('points_tiers','stamps') then raise exception 'catalog redemption is inactive'; end if;
  select * into v_reward from public.loyalty_rewards where id=p_reward and business_id=p_business;
  if not found then raise exception 'reward not found in this business'; end if;
  select rv.* into v_version from public.loyalty_reward_versions rv join public.businesses b on b.active_config_version_id=rv.config_version_id where rv.reward_id=p_reward and rv.business_id=p_business;
  if not found or not v_version.active then raise exception 'reward not found or inactive'; end if;
  if v_version.claim_available_from is not null and v_version.claim_available_from>now() then raise exception 'reward unavailable'; end if;
  if v_version.claim_available_until is not null and v_version.claim_available_until<=now() then raise exception 'reward expired'; end if;
  select jsonb_build_object(
    'branch_ids',coalesce((select jsonb_agg(branch_id order by branch_id) from public.loyalty_reward_branches where reward_version_id=v_version.id),'[]'::jsonb),
    'service_ids',coalesce((select jsonb_agg(service_id order by service_id) from public.loyalty_reward_services where reward_version_id=v_version.id),'[]'::jsonb),
    'product_ids',coalesce((select jsonb_agg(product_id order by product_id) from public.loyalty_reward_products where reward_version_id=v_version.id),'[]'::jsonb),
    'selected',jsonb_build_object('branch_id',p_branch,'service_id',p_service,'product_id',p_product)) into v_eligibility;
  if exists(select 1 from public.loyalty_reward_branches where reward_version_id=v_version.id) and not exists(select 1 from public.loyalty_reward_branches where reward_version_id=v_version.id and branch_id=p_branch) then raise exception 'reward not eligible at branch'; end if;
  if exists(select 1 from public.loyalty_reward_services where reward_version_id=v_version.id) and not exists(select 1 from public.loyalty_reward_services where reward_version_id=v_version.id and service_id=p_service) then raise exception 'reward not eligible for service'; end if;
  if exists(select 1 from public.loyalty_reward_products where reward_version_id=v_version.id) and not exists(select 1 from public.loyalty_reward_products where reward_version_id=v_version.id and product_id=p_product) then raise exception 'reward not eligible for product'; end if;
  select count(*)::integer into v_usage from public.loyalty_redemptions where business_id=p_business and client_id=p_client and reward_id=p_reward;
  if v_version.usage_limit is not null and v_usage>=v_version.usage_limit then
    raise exception 'reward usage limit reached' using errcode='check_violation';
  end if;
  select coalesce(sum(points),0)::integer into v_balance from public.points_ledger where business_id=p_business and client_id=p_client;
  select coalesce(sum(remaining),0)::integer into v_batch_balance from public.points_batches where business_id=p_business and client_id=p_client;
  if v_balance<v_version.cost_points or v_batch_balance<v_version.cost_points then raise exception 'insufficient proven points' using errcode='check_violation'; end if;
  insert into public.loyalty_redemptions(id,business_id,client_id,reward_id,reward_name,points_spent,credit_cents,actor,reward_version_id,reward_snapshot,eligibility_snapshot,fulfillment_kind,entitlement_expires_at,usage_number)
  values(v_redemption_id,p_business,p_client,p_reward,v_version.customer_name,v_version.cost_points,v_version.credit_cents,v_actor,v_version.id,
    to_jsonb(v_version)-'id'-'config_version_id'-'business_id'-'created_at',v_eligibility,v_version.fulfillment_kind,
    case when v_version.entitlement_expiry_days is null then null else now()+make_interval(days=>v_version.entitlement_expiry_days) end,v_usage+1);
  insert into public.loyalty_redemption_provenance
    (id,business_id,client_id,operation_id,redemption_id,points_ledger_id,credit_ledger_id,config_version_id)
  values(v_provenance_id,p_business,p_client,v_operation_id,v_redemption_id,v_points_id,
    case when v_version.credit_cents>0 then gen_random_uuid() end,v_version.config_version_id)
  returning credit_ledger_id into v_credit_id;
  v_remaining:=v_version.cost_points;
  for v_batch in select id,remaining from public.points_batches where business_id=p_business and client_id=p_client and remaining>0 order by expires_at nulls last,earned_at,id for update loop
    exit when v_remaining=0; v_take:=least(v_batch.remaining,v_remaining);
    update public.points_batches set remaining=remaining-v_take where id=v_batch.id;
    insert into public.loyalty_redemption_batch_drains
      (provenance_id,business_id,client_id,redemption_id,points_batch_id,drained_points)
    values(v_provenance_id,p_business,p_client,v_redemption_id,v_batch.id,v_take);
    v_remaining:=v_remaining-v_take;
  end loop;
  perform set_config('app.points_ledger_insert_id',v_points_id::text,true); perform set_config('app.points_ledger_write_scope','redeem_points',true);
  insert into public.points_ledger(id,business_id,client_id,entry_type,points,reference,actor) values(v_points_id,p_business,p_client,'redeem',-v_version.cost_points,'reward: '||v_version.customer_name,v_actor);
  perform set_config('app.points_ledger_insert_id','',true); perform set_config('app.points_ledger_write_scope','',true);
  if v_credit_id is not null then
    perform set_config('app.credit_ledger_insert_id',v_credit_id::text,true); perform set_config('app.credit_ledger_write_scope','redeem_points',true);
    insert into public.credit_ledger(id,business_id,client_id,entry_type,amount_cents,reference,actor) values(v_credit_id,p_business,p_client,'loyalty_earn',v_version.credit_cents,'loyalty reward: '||v_version.customer_name,v_actor);
    perform set_config('app.credit_ledger_insert_id','',true); perform set_config('app.credit_ledger_write_scope','',true);
  end if;
  v_result:=json_build_object('ok',true,'redemption_id',v_redemption_id,
    'reward_version_id',v_version.id,'reward',v_version.customer_name,
    'points_spent',v_version.cost_points,'credit_cents',v_version.credit_cents);
  perform set_config('app.loyalty_operation_complete_id',v_operation_id::text,true);
  update public.loyalty_operations set status='completed',result=v_result::jsonb,completed_at=now() where id=v_operation_id;
  perform set_config('app.loyalty_operation_complete_id','',true); return v_result;
end $$;
revoke execute on function app.redeem_reward_core(uuid,uuid,uuid,text,uuid,uuid,uuid) from public, anon, authenticated;

revoke all privileges on table public.loyalty_redemptions from public, anon, authenticated;
grant select on table public.loyalty_redemptions to authenticated;

create or replace function public.reverse_loyalty_redemption(
  p_business uuid,p_redemption uuid,p_reason text,p_idempotency_key text
)
returns json language plpgsql security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_redemption public.loyalty_redemptions%rowtype; v_provenance public.loyalty_redemption_provenance%rowtype;
  v_existing public.loyalty_redemption_reversals%rowtype; v_actor uuid:=auth.uid(); v_staff uuid;
  v_payload jsonb; v_request_hash text; v_points_id uuid:=gen_random_uuid(); v_credit_id uuid;
  v_source_credit public.credit_ledger%rowtype; v_result jsonb; v_drain record;
begin
  if p_idempotency_key is null or length(btrim(p_idempotency_key))<8 then raise exception 'idempotency key must contain at least 8 characters' using errcode='22023'; end if;
  if p_reason is null or length(btrim(p_reason))<10 then raise exception 'reason must contain at least 10 characters'; end if;
  if not app.has_perm(p_business,'refund_sales') then raise exception 'refund_sales permission required' using errcode='42501'; end if;
  select s.id into v_staff from public.staff s where s.business_id=p_business and s.user_id=v_actor and s.active and 'refund_sales'=any(app.role_perms(s.role)) limit 1 for update;
  if not found then raise exception 'active staff authorization required' using errcode='42501'; end if;
  select * into v_redemption from public.loyalty_redemptions where id=p_redemption and business_id=p_business for update;
  if not found then raise exception 'loyalty redemption not found in this business'; end if;
  v_payload:=jsonb_build_object('business_id',p_business,'redemption_id',p_redemption,'reason',btrim(p_reason),'actor',v_actor);
  v_request_hash:=md5(v_payload::text);
  select * into v_existing from public.loyalty_redemption_reversals where redemption_id=p_redemption;
  if found then
    if v_existing.idempotency_key is distinct from btrim(p_idempotency_key) or v_existing.request_hash is distinct from v_request_hash then raise exception 'redemption already reversed by another request' using errcode='23505'; end if;
    return (v_existing.result||jsonb_build_object('replayed',true))::json;
  end if;
  select * into v_provenance from public.loyalty_redemption_provenance where redemption_id=p_redemption and business_id=p_business for update;
  if not found then raise exception 'legacy or incomplete redemption has missing provenance evidence'; end if;
  if v_provenance.config_version_id is distinct from v_redemption.config_version_id then
    raise exception 'redemption configuration provenance is inconsistent';
  end if;
  perform 1 from public.points_ledger pl
   where pl.id=v_provenance.points_ledger_id and pl.business_id=p_business
     and pl.client_id=v_redemption.client_id and pl.points=-v_redemption.points_spent
     and pl.config_version_id=v_redemption.config_version_id for share;
  if not found then raise exception 'original points ledger provenance is incomplete'; end if;
  if not exists(select 1 from public.loyalty_redemption_batch_drains where provenance_id=v_provenance.id) then raise exception 'incomplete batch drain provenance evidence'; end if;
  if (select coalesce(sum(drained_points),0) from public.loyalty_redemption_batch_drains where provenance_id=v_provenance.id) <> v_redemption.points_spent then raise exception 'batch drain provenance is incomplete'; end if;
  for v_drain in select d.points_batch_id,d.drained_points from public.loyalty_redemption_batch_drains d
    where d.provenance_id=v_provenance.id and d.business_id=p_business
      and d.client_id=v_redemption.client_id order by d.id for update of d loop
    update public.points_batches set remaining=remaining+v_drain.drained_points
     where id=v_drain.points_batch_id and business_id=p_business and client_id=v_redemption.client_id
       and remaining+v_drain.drained_points<=earned;
    if not found then raise exception 'batch restoration would exceed immutable earned points'; end if;
  end loop;
  -- The compensation is a positive points adjustment, exactly equal to the proven drains.
  perform set_config('app.redemption_reversal_config_version_id',v_redemption.config_version_id::text,true);
  perform set_config('app.points_ledger_insert_id',v_points_id::text,true); perform set_config('app.points_ledger_write_scope','redemption_reversal',true);
  insert into public.points_ledger(id,business_id,client_id,entry_type,points,reference,actor,config_version_id)
  values(v_points_id,p_business,v_redemption.client_id,'adjust',v_redemption.points_spent,'redemption reversal: '||p_redemption,v_actor,v_redemption.config_version_id);
  perform set_config('app.points_ledger_insert_id','',true); perform set_config('app.points_ledger_write_scope','',true);
  if v_provenance.credit_ledger_id is not null then
    select * into v_source_credit from public.credit_ledger cl
     where cl.id=v_provenance.credit_ledger_id and cl.business_id=p_business
       and cl.client_id=v_redemption.client_id and cl.entry_type='loyalty_earn'
       and cl.amount_cents=v_redemption.credit_cents
       and cl.config_version_id=v_redemption.config_version_id for share;
    if not found then raise exception 'original credit ledger provenance is incomplete'; end if;
    if exists (
      select 1 from public.credit_ledger spend
       where spend.business_id=p_business and spend.client_id=v_redemption.client_id
         and spend.amount_cents<0 and spend.created_at>=v_source_credit.created_at
    ) then
      raise exception 'reward credit may have been spent; exact source credit is no longer reversible';
    end if;
    v_credit_id:=gen_random_uuid();
    perform set_config('app.credit_ledger_insert_id',v_credit_id::text,true); perform set_config('app.credit_ledger_write_scope','redemption_reversal',true);
    insert into public.credit_ledger(id,business_id,client_id,entry_type,amount_cents,reference,actor,idempotency_key,config_version_id)
    values(v_credit_id,p_business,v_redemption.client_id,'manual_adjust',-v_redemption.credit_cents,
      'loyalty redemption reversal of credit entry '||v_source_credit.id,v_actor,
      'v34:'||btrim(p_idempotency_key),v_redemption.config_version_id);
    perform set_config('app.credit_ledger_insert_id','',true); perform set_config('app.credit_ledger_write_scope','',true);
  end if;
  if (select coalesce(sum(points),0) from public.points_ledger where business_id=p_business and client_id=v_redemption.client_id)
     <> (select coalesce(sum(remaining),0) from public.points_batches where business_id=p_business and client_id=v_redemption.client_id) then
    raise exception 'points ledger and points batch remaining invariant diverged';
  end if;
  v_result:=jsonb_build_object('redemption_id',p_redemption,'restored_points',v_redemption.points_spent,'reversed_credit_cents',case when v_credit_id is null then 0 else v_redemption.credit_cents end,'replayed',false);
  insert into public.loyalty_redemption_reversals
    (business_id,redemption_id,provenance_id,client_id,actor,idempotency_key,request_payload,
     request_hash,restored_points_ledger_id,reversed_credit_ledger_id,result)
  values(p_business,p_redemption,v_provenance.id,v_redemption.client_id,v_actor,
    btrim(p_idempotency_key),v_payload,v_request_hash,v_points_id,v_credit_id,v_result);
  perform set_config('app.redemption_reversal_config_version_id','',true);
  return v_result::json;
end $$;
revoke all privileges on function public.reverse_loyalty_redemption(uuid,uuid,text,text) from public, anon;
grant execute on function public.reverse_loyalty_redemption(uuid,uuid,text,text) to authenticated;

commit;
