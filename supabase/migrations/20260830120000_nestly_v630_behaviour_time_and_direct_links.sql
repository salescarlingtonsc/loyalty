-- NESTLY v630 — Phase A, M3+M7 (A2 + A6): honest event time at the till, and the DIRECT
-- redemption→sale link. Combined into one migration because both widen record_cart_sale's
-- signature — dropping and recreating the same live function twice in a row is avoidable risk.
--
-- A2 (owner §2 time model): the three till writers accept an optional p_occurred_at,
-- server-clamped to [now()-48h, now()]. Default behaviour is byte-identical to today.
-- The idempotency payload gains an occurred_at key ONLY when the caller supplies one, so
-- replays of pre-v630 operations still hash identically (a new key on every payload would
-- make every historical replay raise a false conflict).
--
-- A6 (owner ruling D9): the canonical hard link is a separate append-only table,
-- public.redemption_sale_links_v630 — NOT columns on the redemption tables, because
-- loyalty_redemptions is unconditionally append-only (loyalty_redemption_immutable_guard)
-- and birthday redemptions only mutate under their own token. A row here asserts DIRECT
-- provenance: the redemption was attached to that checkout inside the same transaction,
-- witnessed by the pricing authority. The only writer is the kernel finaliser. Inferred
-- associations NEVER write here — they live in v635's association ledger.
begin;

-- ---------------------------------------------------------------------------
-- 1. The direct-link table.
-- ---------------------------------------------------------------------------
create table public.redemption_sale_links_v630 (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  client_id uuid,
  redemption_kind text not null check (redemption_kind in ('loyalty','birthday','promotion')),
  redemption_id uuid not null,
  sale_id uuid not null references public.sales(id),
  created_at timestamptz not null default now(),
  unique (redemption_kind, redemption_id)
);
alter table public.redemption_sale_links_v630 enable row level security;
create policy redemption_links_member_read on public.redemption_sale_links_v630
  for select to authenticated
  using (app.is_salon_member(business_id) or app.is_super_admin());
revoke all on public.redemption_sale_links_v630 from public, anon, authenticated;
grant select on public.redemption_sale_links_v630 to authenticated;

create or replace function app.redemption_sale_links_guard_v630()
returns trigger language plpgsql
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
begin
  raise exception 'redemption_sale_links_v630 is append-only' using errcode = '42501';
end;
$$;
create trigger trg_redemption_sale_links_append_only
  before update or delete on public.redemption_sale_links_v630
  for each row execute function app.redemption_sale_links_guard_v630();

-- ---------------------------------------------------------------------------
-- 2. The stamping helper (called only from the kernel finaliser, in the same
--    transaction as the sale). Validates ownership before linking; refuses a
--    second link for the same redemption via the unique constraint.
--    p_redemptions: jsonb array of {"kind": "loyalty"|"birthday"|"promotion", "id": uuid}.
-- ---------------------------------------------------------------------------
create or replace function app.stamp_direct_redemptions_v630(
  p_business uuid, p_client uuid, p_sale uuid, p_redemptions jsonb)
returns integer
language plpgsql
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_item jsonb;
  v_kind text;
  v_id uuid;
  v_owner uuid;
  v_stamped integer := 0;
begin
  if p_redemptions is null or jsonb_typeof(p_redemptions) <> 'array' then
    raise exception 'redemption attachments must be a json array' using errcode = '22023';
  end if;
  if jsonb_array_length(p_redemptions) > 20 then
    raise exception 'too many redemption attachments' using errcode = '22023';
  end if;
  for v_item in select * from jsonb_array_elements(p_redemptions) loop
    v_kind := v_item->>'kind';
    v_id := nullif(v_item->>'id','')::uuid;
    if v_kind not in ('loyalty','birthday','promotion') or v_id is null then
      raise exception 'unsupported redemption attachment %', v_item using errcode = '22023';
    end if;
    if v_kind = 'loyalty' then
      select r.client_id into v_owner from public.loyalty_redemptions r
       where r.id = v_id and r.business_id = p_business;
    elsif v_kind = 'birthday' then
      select r.client_id into v_owner from public.customer_birthday_redemptions r
       where r.id = v_id and r.business_id = p_business;
    else
      select r.client_id into v_owner from public.promotion_redemptions_v290 r
       where r.id = v_id and r.business_id = p_business;
    end if;
    if not found then
      raise exception 'redemption % % does not exist in this business', v_kind, v_id
        using errcode = '22023';
    end if;
    if v_owner is distinct from p_client then
      raise exception 'redemption % belongs to a different customer than this checkout', v_id
        using errcode = '42501';
    end if;
    insert into public.redemption_sale_links_v630
      (business_id, client_id, redemption_kind, redemption_id, sale_id)
    values (p_business, v_owner, v_kind, v_id, p_sale);
    v_stamped := v_stamped + 1;
  end loop;
  return v_stamped;
end;
$$;
revoke all on function app.stamp_direct_redemptions_v630(uuid,uuid,uuid,jsonb) from public, anon, authenticated;
grant execute on function app.stamp_direct_redemptions_v630(uuid,uuid,uuid,jsonb) to service_role;

-- ---------------------------------------------------------------------------
-- 3. record_quick_sale: byte-faithful re-emission of the live production body
--    (read 2026-08-30) with the p_occurred_at additions marked -- v630.
--    The old 9-arg signature is dropped in the same transaction so exactly one
--    overload exists afterwards (the PGRST203 twin-overload lesson).
-- ---------------------------------------------------------------------------
drop function public.record_quick_sale(uuid,integer,text,uuid,uuid,uuid,text,text,boolean);

CREATE OR REPLACE FUNCTION public.record_quick_sale(p_business uuid, p_amount_cents integer, p_method text, p_client uuid DEFAULT NULL::uuid, p_staff uuid DEFAULT NULL::uuid, p_branch uuid DEFAULT NULL::uuid, p_note text DEFAULT NULL::text, p_idempotency_key text DEFAULT NULL::text, p_paid boolean DEFAULT true, p_occurred_at timestamp with time zone DEFAULT NULL::timestamp with time zone)
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'app', 'pg_temp'
AS $function$
declare
  v_actor uuid := auth.uid();
  v_actor_staff uuid;
  v_branch uuid;
  v_method text := lower(nullif(btrim(p_method), ''));
  v_note text := nullif(btrim(p_note), '');
  v_key text := nullif(btrim(p_idempotency_key), '');
  v_paid boolean := coalesce(p_paid, true);
  v_operation_id uuid := gen_random_uuid();
  v_operation public.financial_operations%rowtype;
  v_payload jsonb;
  v_sale public.sales%rowtype;
  v_payment jsonb;
  v_result jsonb;
begin
  if v_key is null or length(v_key) < 8 then
    raise exception 'quick-sale idempotency key is required and must be at least 8 characters';
  end if;
  if coalesce(p_amount_cents, 0) <= 0 then
    raise exception 'a quick sale must have a positive amount';
  end if;
  -- v630: an explicitly-supplied event time must be recent past, never future.
  if p_occurred_at is not null
     and (p_occurred_at > clock_timestamp()
          or p_occurred_at < clock_timestamp() - interval '48 hours') then
    raise exception 'occurred_at must be within the last 48 hours and not in the future'
      using errcode = '22023';
  end if;
  if v_method not in ('cash', 'card', 'paynow', 'bank_transfer', 'other') then
    raise exception 'unsupported quick-sale payment method %', p_method;
  end if;
  if not app.has_perm(p_business, 'create_sales') then
    raise exception 'you do not have permission to record a sale in this business (create_sales)'
      using errcode = '42501';
  end if;

  v_branch := coalesce(p_branch, app.default_branch(p_business));
  if v_branch is null or not exists (
    select 1 from public.branches b
     where b.id = v_branch and b.business_id = p_business and b.active
  ) then
    raise exception 'quick-sale branch is missing, inactive, or belongs to another business';
  end if;
  if not app.can_see_branch(p_business, v_branch) then
    raise exception 'you are not permitted to record a quick sale for this branch scope'
      using errcode = '42501';
  end if;
  if p_client is not null and not exists (
    select 1 from public.clients c where c.id = p_client and c.business_id = p_business
  ) then
    raise exception 'quick-sale client does not belong to this business';
  end if;
  if p_staff is not null and not exists (
    select 1 from public.staff s
     where s.id = p_staff and s.business_id = p_business and s.active
  ) then
    raise exception 'quick-sale staff is inactive or does not belong to this business';
  end if;

  select s.id into v_actor_staff
    from public.staff s
   where s.business_id = p_business
     and s.user_id = v_actor
     and s.active
     and 'create_sales' = any (app.role_perms(s.role))
   order by case s.role when 'owner' then 0 when 'manager' then 1 else 2 end, s.created_at
   limit 1
   for update;
  if not found then
    raise exception 'active staff authorization is required to record a quick sale'
      using errcode = '42501';
  end if;
  perform 1 from public.branches b
   where b.id = v_branch and b.business_id = p_business and b.active
   for update;
  if not found then
    raise exception 'quick-sale branch changed while authorization was being locked';
  end if;
  if p_client is not null then
    perform 1 from public.clients c
     where c.id = p_client and c.business_id = p_business for update;
    if not found then
      raise exception 'quick-sale client changed while authorization was being locked';
    end if;
  end if;
  if p_staff is not null then
    perform 1 from public.staff s
     where s.id = p_staff and s.business_id = p_business and s.active for update;
    if not found then
      raise exception 'quick-sale staff changed while authorization was being locked';
    end if;
  end if;
  if not app.has_perm(p_business, 'create_sales')
     or not app.can_see_branch(p_business, v_branch) then
    raise exception 'quick-sale authorization changed while the operation was being locked'
      using errcode = '42501';
  end if;

  v_payload := jsonb_build_object(
    'business_id', p_business,
    'branch_id', v_branch,
    'client_id', p_client,
    'staff_id', p_staff,
    'actor', v_actor,
    'amount_cents', p_amount_cents,
    'method', v_method,
    'note', v_note,
    'paid', v_paid
  );
  -- v630: only an explicit event time joins the payload, so pre-v630 operations
  -- replay with an unchanged hash.
  if p_occurred_at is not null then
    v_payload := v_payload || jsonb_build_object('occurred_at', p_occurred_at);
  end if;

  select * into v_operation
    from public.financial_operations fo
   where fo.business_id = p_business
     and fo.operation_type = 'quick_sale'
     and fo.idempotency_key = v_key;
  if found then
    if (v_operation.branch_id, v_operation.actor, v_operation.request_payload,
        v_operation.request_hash)
       is distinct from
       (v_branch, v_actor, v_payload, md5(v_payload::text)) then
      raise exception 'quick-sale idempotency key conflicts with a different immutable request'
        using errcode = '23505';
    end if;
    if v_operation.status <> 'completed' or v_operation.sale_id is null
       or v_operation.result is null then
      raise exception 'quick-sale operation is reserved but incomplete'
        using errcode = '55000';
    end if;
    if not exists (
      select 1 from public.sales s
       where s.id = v_operation.sale_id
         and s.business_id = p_business
         and s.branch_id = v_branch
         and s.client_id is not distinct from p_client
         and s.staff_id is not distinct from p_staff
         and s.kind = 'quick_sale'
         and s.amount_cents = p_amount_cents
         and s.note is not distinct from v_note
    ) or (v_paid and not exists (
      select 1 from public.payments p
       where p.id = (v_operation.result->>'payment_id')::uuid
         and p.business_id = p_business
         and p.sale_id = v_operation.sale_id
         and p.method = v_method
         and p.kind = 'payment'
         and p.amount_cents = p_amount_cents
         and p.created_by = v_actor
    )) or (not v_paid and v_operation.result ? 'payment_id') then
      raise exception 'completed quick sale is missing exact sale/payment proof'
        using errcode = 'XX001';
    end if;
    return (v_operation.result || jsonb_build_object('replayed', true))::json;
  end if;

  perform set_config('app.financial_operation_insert_id', v_operation_id::text, true);
  insert into public.financial_operations(
    id, business_id, branch_id, sale_id, operation_type, actor,
    idempotency_key, request_payload, request_hash
  ) values (
    v_operation_id, p_business, v_branch, null, 'quick_sale', v_actor,
    v_key, v_payload, md5(v_payload::text)
  )
  on conflict (business_id, operation_type, idempotency_key) do nothing
  returning * into v_operation;
  perform set_config('app.financial_operation_insert_id', '', true);

  if v_operation.id is null then
    select * into v_operation from public.financial_operations fo
     where fo.business_id = p_business
       and fo.operation_type = 'quick_sale'
       and fo.idempotency_key = v_key;
    if not found
       or (v_operation.branch_id, v_operation.actor, v_operation.request_payload,
           v_operation.request_hash)
          is distinct from
          (v_branch, v_actor, v_payload, md5(v_payload::text)) then
      raise exception 'quick-sale idempotency reservation conflicts with a different immutable request'
        using errcode = '23505';
    end if;
    if v_operation.status = 'completed' and v_operation.result is not null then
      -- Re-enter the completed replay path so a concurrent winner receives the same exact
      -- sale/payment proof checks as a later replay, rather than trusting the parent alone.
      return public.record_quick_sale(
        p_business, p_amount_cents, v_method, p_client, p_staff, v_branch,
        v_note, v_key, v_paid, p_occurred_at
      );
    end if;
    raise exception 'quick-sale operation is already reserved but incomplete'
      using errcode = '55000';
  end if;

  insert into public.sales(
    business_id, client_id, kind, amount_cents, branch_id, staff_id, note, occurred_at
  ) values (
    p_business, p_client, 'quick_sale', p_amount_cents, v_branch, p_staff, v_note,
    coalesce(p_occurred_at, now())
  ) returning * into v_sale;

  if v_paid then
    v_payment := public.record_payment(
      p_business => p_business,
      p_method => v_method,
      p_amount_cents => p_amount_cents,
      p_sale => v_sale.id,
      p_client => p_client,
      p_staff => p_staff,
      p_kind => 'payment',
      p_branch => v_branch,
      p_reference => 'quick sale checkout',
      p_note => v_note,
      p_idempotency_key => 'v20:' || v_operation.id || ':payment'
    )::jsonb;
  end if;

  v_result := jsonb_build_object(
    'sale', to_jsonb(v_sale),
    'replayed', false,
    'operation_id', v_operation.id
  );
  if v_paid then
    v_result := v_result || jsonb_build_object(
      'payment', v_payment,
      'payment_id', v_payment->>'id'
    );
  else
    v_result := v_result || jsonb_build_object('payment', null);
  end if;

  perform set_config('app.financial_operation_complete_id', v_operation.id::text, true);
  update public.financial_operations
     set sale_id = v_sale.id,
         status = 'completed',
         result = v_result,
         completed_at = now()
   where id = v_operation.id and status = 'reserved';
  perform set_config('app.financial_operation_complete_id', '', true);
  if not found then
    raise exception 'failed to complete reserved quick-sale operation'
      using errcode = '55000';
  end if;

  return v_result::json;
end $function$;

revoke all on function public.record_quick_sale(uuid,integer,text,uuid,uuid,uuid,text,text,boolean,timestamptz) from public, anon;
grant execute on function public.record_quick_sale(uuid,integer,text,uuid,uuid,uuid,text,text,boolean,timestamptz) to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 4. record_sale_by_phone and record_cart_sale: widened in place from their
--    live definitions with single-occurrence anchors, old signatures dropped
--    in the same transaction.
-- ---------------------------------------------------------------------------
do $patch$
declare
  v_def text;
  v_anchor text;
  v_repl text;
begin
  -- --- record_sale_by_phone (9-arg) ------------------------------------------------
  select pg_get_functiondef(to_regprocedure(
    'public.record_sale_by_phone(uuid,text,integer,text,text,uuid,text,uuid,text)')) into v_def;
  if v_def is null then raise exception 'v630: record_sale_by_phone 9-arg not found'; end if;

  v_anchor := 'p_branch uuid, p_method text)';
  if (length(v_def) - length(replace(v_def, v_anchor, ''))) / length(v_anchor) <> 1 then
    raise exception 'v630: record_sale_by_phone signature anchor drifted';
  end if;
  v_def := replace(v_def, v_anchor,
    'p_branch uuid, p_method text, p_occurred_at timestamp with time zone DEFAULT NULL::timestamp with time zone)');

  v_anchor := 'p_branch=>p_branch,p_note=>v_note,p_idempotency_key=>btrim(p_idem),p_paid=>true';
  if (length(v_def) - length(replace(v_def, v_anchor, ''))) / length(v_anchor) <> 1 then
    raise exception 'v630: record_sale_by_phone delegate anchor drifted';
  end if;
  v_def := replace(v_def, v_anchor,
    'p_branch=>p_branch,p_note=>v_note,p_idempotency_key=>btrim(p_idem),p_occurred_at=>p_occurred_at,p_paid=>true');

  drop function public.record_sale_by_phone(uuid,text,integer,text,text,uuid,text,uuid,text);
  execute v_def;

  -- --- record_cart_sale (9-arg) ----------------------------------------------------
  select pg_get_functiondef(to_regprocedure(
    'public.record_cart_sale(uuid,uuid,uuid,uuid,text,text,jsonb,uuid,boolean)')) into v_def;
  if v_def is null then raise exception 'v630: record_cart_sale 9-arg not found'; end if;

  v_anchor := 'p_evaluation_id uuid, p_paid boolean DEFAULT true)';
  if (length(v_def) - length(replace(v_def, v_anchor, ''))) / length(v_anchor) <> 1 then
    raise exception 'v630: record_cart_sale signature anchor drifted';
  end if;
  v_def := replace(v_def, v_anchor,
    'p_evaluation_id uuid, p_paid boolean DEFAULT true, p_occurred_at timestamp with time zone DEFAULT NULL::timestamp with time zone, p_redemptions jsonb DEFAULT NULL::jsonb)');

  v_anchor := 'p_idempotency_key => v_key, p_paid => case when v_has_sv then false else v_paid end)';
  if (length(v_def) - length(replace(v_def, v_anchor, ''))) / length(v_anchor) <> 1 then
    raise exception 'v630: record_cart_sale delegate anchor drifted';
  end if;
  v_def := replace(v_def, v_anchor,
    'p_idempotency_key => v_key, p_occurred_at => p_occurred_at, p_paid => case when v_has_sv then false else v_paid end)');

  v_anchor := 'raise exception ''stale_evaluation: this idempotency key already produced a sale for a different token'' using errcode = ''P0001'';
  end if;';
  if (length(v_def) - length(replace(v_def, v_anchor, ''))) / length(v_anchor) <> 1 then
    raise exception 'v630: record_cart_sale stamping anchor drifted';
  end if;
  v_repl := v_anchor || '
  -- v630: DIRECT redemption→sale provenance, witnessed by this finaliser.
  if p_redemptions is not null then
    perform app.stamp_direct_redemptions_v630(p_business, v_eval.client_id, v_sale_id, p_redemptions);
  end if;';
  v_def := replace(v_def, v_anchor, v_repl);

  drop function public.record_cart_sale(uuid,uuid,uuid,uuid,text,text,jsonb,uuid,boolean);
  execute v_def;
end;
$patch$;

-- ACLs restated verbatim from live proacl:
revoke all on function public.record_sale_by_phone(uuid,text,integer,text,text,uuid,text,uuid,text,timestamptz) from public, anon;
grant execute on function public.record_sale_by_phone(uuid,text,integer,text,text,uuid,text,uuid,text,timestamptz) to authenticated, service_role;
revoke all on function public.record_cart_sale(uuid,uuid,uuid,uuid,text,text,jsonb,uuid,boolean,timestamptz,jsonb) from public, anon;
grant execute on function public.record_cart_sale(uuid,uuid,uuid,uuid,text,text,jsonb,uuid,boolean,timestamptz,jsonb) to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 5. Watermarks.
-- ---------------------------------------------------------------------------
insert into public.analytics_observation_watermarks (metric_key, observed_since, reason)
values
 ('behaviour_time_capture', now(),
  'till writers accept an explicit event time from v630; earlier sales carry insert time (till_recorded)'),
 ('redemption_direct_link', now(),
  'checkout-attached redemptions are hard-linked from v630; earlier redemptions have no provable sale linkage');

commit;
