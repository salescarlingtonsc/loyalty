-- FRENLY v8 — customer self-service change requests + service→product consumption.
-- (target Supabase project kyzovonwnscrzmkvocid; migration name `frenly_v8_requests_consumption`)
--
-- Adds:
--   1. businesses.auto_approve_changes flag.
--   2. change_requests table (customer-initiated cancel/reschedule of a booked appt).
--   3. service_products bill-of-materials (which retail products a service consumes).
--   4. Anon portal RPCs list_my_appointments / request_change (phone-authenticated).
--   5. Owner/staff RPC decide_change (approve/decline pending requests).
--   6. Extends app.on_appointment_completed() to auto-deduct linked product stock
--      FEFO when a service appointment completes (in addition to the existing sale insert).
--
-- Style follows v2: plpgsql SECURITY DEFINER + `set search_path = public`; RPCs revoke
-- from public/anon then grant to intended roles; portal RPCs authenticate by phone match.

begin;

-- 1. Per-business toggle: auto-approve inbound change requests. -----------------------
alter table public.businesses
  add column auto_approve_changes boolean not null default false;

-- 2. change_requests: a customer's request to cancel or reschedule a booked appt. ------
create table public.change_requests (
  id             uuid primary key default gen_random_uuid(),
  business_id    uuid not null references public.businesses(id) on delete cascade,
  appointment_id uuid not null references public.appointments(id) on delete cascade,
  kind           text not null check (kind in ('cancel','reschedule')),
  proposed_at    timestamptz,                -- new start time (reschedule only)
  phone          text not null,              -- claimant phone (must match appt client)
  note           text,
  status         text not null default 'pending' check (status in ('pending','approved','declined')),
  decided_at     timestamptz,
  created_at     timestamptz not null default now()
);
create index on public.change_requests (business_id, status);

alter table public.change_requests enable row level security;

create policy change_requests_select on public.change_requests for select to authenticated
  using (app.is_salon_member(business_id));
create policy change_requests_update on public.change_requests for update to authenticated
  using (app.is_salon_member(business_id)) with check (app.is_salon_member(business_id));

create trigger trg_change_requests_audit
  after update on public.change_requests
  for each row execute function app.audit();

-- 3. service_products: bill-of-materials linking a service to the retail products -----
--    it consumes (e.g. a colour service uses 1 tube of dye).
create table public.service_products (
  service_id uuid not null references public.services(id) on delete cascade,
  product_id uuid not null references public.products(id) on delete cascade,
  qty        integer not null default 1 check (qty > 0),
  primary key (service_id, product_id)
);

alter table public.service_products enable row level security;

create policy service_products_all on public.service_products for all to authenticated
  using (exists (select 1 from public.services s
                 where s.id = service_id and app.is_salon_member(s.business_id)))
  with check (exists (select 1 from public.services s
                      where s.id = service_id and app.is_salon_member(s.business_id)));

-- 4. Portal RPC: list a customer's upcoming booked appointments (phone-matched). -------
create or replace function public.list_my_appointments(p_slug text, p_phone text)
returns json language plpgsql security definer set search_path = public as $$
declare v_biz uuid; v_result json;
begin
  select id into v_biz from businesses where slug = p_slug;
  if v_biz is null then raise exception 'business not found'; end if;

  select coalesce(json_agg(row_to_json(t) order by t.starts_at), '[]'::json) into v_result
  from (
    select a.id,
           a.starts_at,
           s.name as service_name,
           a.status
    from appointments a
    join clients c        on c.id = a.client_id
    left join services s  on s.id = a.service_id
    where a.business_id = v_biz
      and a.status = 'booked'
      and a.starts_at > now()
      and trim(c.phone) = trim(p_phone)
    order by a.starts_at
  ) t;

  return v_result;
end $$;
revoke execute on function public.list_my_appointments(text, text) from public;
grant execute on function public.list_my_appointments(text, text) to anon, authenticated;

-- 5. Portal RPC: a customer requests to cancel or reschedule an appointment. -----------
--    Authentication is the phone match against the appointment's client. When the
--    business has auto_approve_changes on, the change is executed immediately (same
--    logic decide_change applies on approve).
create or replace function public.request_change(
  p_slug text, p_appointment uuid, p_phone text,
  p_kind text, p_proposed timestamptz, p_note text)
returns json language plpgsql security definer set search_path = public as $$
declare
  v_biz    uuid;
  v_appt   record;
  v_phone  text;
  v_auto   boolean;
  v_status text := 'pending';
  v_id     uuid;
begin
  select id, auto_approve_changes into v_biz, v_auto from businesses where slug = p_slug;
  if v_biz is null then raise exception 'business not found'; end if;

  if p_kind not in ('cancel','reschedule') then
    raise exception 'invalid kind: %', p_kind;
  end if;
  if p_kind = 'reschedule' and (p_proposed is null or p_proposed <= now()) then
    raise exception 'reschedule requires a future proposed time';
  end if;

  select a.*, c.phone as client_phone into v_appt
  from appointments a
  join clients c on c.id = a.client_id
  where a.id = p_appointment and a.business_id = v_biz;

  if not found then raise exception 'appointment not found'; end if;
  if v_appt.status <> 'booked' then
    raise exception 'appointment is not booked';
  end if;
  if v_appt.client_phone is null or trim(v_appt.client_phone) <> trim(p_phone) then
    raise exception 'phone does not match this appointment';  -- auth failure
  end if;

  insert into change_requests (business_id, appointment_id, kind, proposed_at, phone, note, status)
  values (v_biz, p_appointment, p_kind, p_proposed, trim(p_phone), p_note, 'pending')
  returning id into v_id;

  if v_auto then
    -- Execute immediately, mirroring decide_change(approve). Guard on still-'booked'.
    if p_kind = 'cancel' then
      update appointments set status = 'cancelled'
        where id = p_appointment and status = 'booked';
    elsif p_kind = 'reschedule' then
      update appointments
        set starts_at = p_proposed,
            ends_at   = p_proposed + (ends_at - starts_at)
        where id = p_appointment and status = 'booked';
    end if;
    update change_requests set status = 'approved', decided_at = now() where id = v_id;
    v_status := 'approved';
  end if;

  return json_build_object('id', v_id, 'status', v_status);
end $$;
revoke execute on function public.request_change(text, uuid, text, text, timestamptz, text) from public;
grant execute on function public.request_change(text, uuid, text, text, timestamptz, text) to anon, authenticated;

-- 6. Staff RPC: approve or decline a pending change request. --------------------------
create or replace function public.decide_change(p_request uuid, p_approve boolean)
returns json language plpgsql security definer set search_path = public as $$
declare v_req record; v_status text;
begin
  select * into v_req from change_requests where id = p_request;
  if not found then raise exception 'change request not found'; end if;
  if not app.is_salon_member(v_req.business_id) then
    raise exception 'not a member of this business';
  end if;
  if v_req.status <> 'pending' then
    raise exception 'change request already decided: %', v_req.status;
  end if;

  if p_approve then
    if v_req.kind = 'cancel' then
      update appointments set status = 'cancelled'
        where id = v_req.appointment_id and status = 'booked';
    elsif v_req.kind = 'reschedule' then
      update appointments
        set starts_at = v_req.proposed_at,
            ends_at   = v_req.proposed_at + (ends_at - starts_at)
        where id = v_req.appointment_id and status = 'booked';
    end if;
    v_status := 'approved';
  else
    v_status := 'declined';
  end if;

  update change_requests set status = v_status, decided_at = now() where id = p_request;

  return json_build_object('id', p_request, 'status', v_status, 'kind', v_req.kind);
end $$;
revoke execute on function public.decide_change(uuid, boolean) from public, anon;
grant execute on function public.decide_change(uuid, boolean) to authenticated;

-- 7. Extend completion trigger: existing sale insert PLUS FEFO stock consumption. ------
--    Keeps the v6 sale-creation behaviour byte-for-byte in spirit, then deducts each
--    linked product's qty from stock_batches (earliest expiry first). Under-stock is
--    tolerated (deduct what exists, never below zero, never raise).
create or replace function app.on_appointment_completed()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  v_amount integer;
  sp       record;
  b        record;
  v_need   integer;
  v_take   integer;
begin
  if new.status = 'completed' and old.status is distinct from 'completed' then
    v_amount := coalesce(nullif(new.total_cents,0),
                         (select price_cents from services where id = new.service_id), 0);
    insert into sales (business_id, client_id, kind, amount_cents, appointment_id, note)
    values (new.business_id, new.client_id, 'service', v_amount, new.id, 'appointment completed')
    on conflict do nothing;

    -- FEFO stock consumption for the completed service's bill-of-materials.
    if new.service_id is not null then
      for sp in
        select product_id, qty from service_products where service_id = new.service_id
      loop
        v_need := sp.qty;
        for b in
          select id, qty from stock_batches
          where product_id = sp.product_id and qty > 0
          order by expires_on nulls last, received_on, id
        loop
          exit when v_need <= 0;
          v_take := least(b.qty, v_need);
          update stock_batches set qty = qty - v_take where id = b.id;
          v_need := v_need - v_take;
        end loop;
        -- If v_need > 0 here, stock was insufficient: we deducted all available and move on.
      end loop;
    end if;
  end if;
  return new;
end $$;

commit;

-- ------------------------------------------------------------------------------------
-- MANUAL TEST SCENARIOS
-- ------------------------------------------------------------------------------------
-- Scenario A — Phone-authenticated portal request, manual approval:
--   1. Business with auto_approve_changes = false; a client with phone '+6591234567'
--      and a future 'booked' appointment.
--   2. select public.list_my_appointments('<slug>', ' +6591234567 ');
--      -> returns a 1-element JSON array (trim tolerant), status 'booked'.
--   3. select public.request_change('<slug>', '<appt>', '+6591234567',
--                                    'reschedule', now() + interval '2 days', 'pls move');
--      -> {"id":..., "status":"pending"}; appointment start UNCHANGED.
--   4. As a staff member of the business:
--      select public.decide_change('<request>', true);
--      -> {"status":"approved","kind":"reschedule"}; appt starts_at shifted by 2 days,
--         ends_at preserves original duration; change_requests.decided_at set.
--
-- Scenario B — Auto-approve cancel + wrong-phone auth failure:
--   1. Set businesses.auto_approve_changes = true.
--   2. request_change(..., 'cancel', null, null) with the CORRECT phone
--      -> {"status":"approved"}; appointment.status becomes 'cancelled' immediately.
--   3. request_change(..., 'cancel', null, null) with a WRONG phone
--      -> raises 'phone does not match this appointment' (no row inserted, no change).
--
-- Scenario C — FEFO consumption on completion:
--   1. Service S linked via service_products to product P, qty 2.
--   2. Two stock_batches for P: batch1 qty 1 expires 2026-08-01, batch2 qty 5
--      expires 2026-12-01 (and/or a null-expiry batch received earlier).
--   3. Book an appointment for S, then update its status 'booked' -> 'completed'.
--      -> exactly one sale row (one_sale_per_appointment holds); batch1 drained to 0
--         first (earliest expiry), remaining 1 unit taken from batch2 (qty 5 -> 4).
--   4. Repeat with total linked qty exceeding available stock:
--      -> all available units deducted, no batch goes negative, no exception raised.
-- ------------------------------------------------------------------------------------
