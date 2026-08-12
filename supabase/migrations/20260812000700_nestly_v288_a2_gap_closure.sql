-- NESTLY v288 — AUDIT A2 GAP CLOSURE (bookings, bottles)
--
-- Three server truths behind the A2 audit of Appointments / Bookings / Waitlist / Bottles.
-- Everything else in A2 is client work; these three could not be closed in the browser.
--
--   1  A SEATED SECTOR CAN CONFIRM ITS OWN BOOKINGS  (audit A2, HIGH 1 — beachhead blocker)
--      staff_decide_booking_request_v73 requires 'bookings' rw for either decision and, for
--      'confirm', ALSO requires 'appointments' rw. That second requirement is unconditional, and
--      app.effective_platform_module_mode_v94 resolves an un-entitled module to 'disabled' by
--      SECTOR — so for industry='fnb' and industry='bar', whose module bundles do not contain
--      'appointments' at all, the requirement can never be satisfied by ANYONE, owner included.
--      A cafe or bar could therefore only ever DECLINE the requests its own public booking page
--      produced. That is the beachhead vertical.
--      The fix is the smallest one that keeps every existing refusal: the appointments boundary
--      is still demanded wherever the platform actually grants appointments (including when it
--      grants them read-only, which must still refuse), and is skipped only where the platform
--      has no appointments module to grant. Bookings rw is required first and unchanged, so the
--      decision is never unauthorised — it is authorised by the module the REQUEST lives in.
--      The appointment row it creates is written by a SECURITY DEFINER function against a table
--      with RLS enabled but not forced, exactly as it always was; nothing about the write path
--      changes, only which right authorises it.
--
--   2  A MIS-PARKED BOTTLE HAS AN HONEST EXIT  (audit A2, MEDIUM 14)
--      The only terminal control the Bottles screen offered was 'retrieved', which ASSERTS that
--      the customer walked out with the bottle. A wrong tag, a duplicate or a bottle thrown away
--      therefore had to be recorded as a physical event that did not happen — in an append-only
--      evidence log whose entire purpose is answering "what actually happened to my bottle".
--      remove_bottle_v288 writes status='removed' (already an accepted value on the table's own
--      status check) and its own 'status' event naming the actor. Deliberately a NEW function
--      rather than a widening of set_bottle_status_v275: that function's floor matrix
--      (app.bar_status_transition_allowed_v279) states that retrieved is a one-way door, and
--      that statement stays true. 'removed' is reachable from every state in which the bar still
--      physically holds the bottle — stored, called, at_table and expired.
--      NOT changed, because it needed no change: extend_bottle_v275 and set_bottle_expiry_v278
--      both already revive an 'expired' bottle to 'stored'. The audit's expired→stored path was
--      a client gap (the buttons were not drawn), not a server one.
--
--   3  THE BOTTLE CATALOGUE CAN BE CORRECTED  (audit A2, MEDIUM 15)
--      bar_save_bottle_product_v278 accepts p_name and p_price_cents but applies them ONLY on
--      insert; its update branch writes size_ml and silently drops the other two. A mistyped
--      name or price could be created and never corrected. bar_save_bottle_product_v288 applies
--      all three on update. A NEW NAME rather than a fifth argument or a changed body, for the
--      reason this module has now recorded three times: an overload differing only in arity is
--      what makes PostgREST's resolution ambiguous. v278 stays deployed and callable, and the
--      client keeps using it for the ADD path, so a deploy in flight cannot break.
--      A null p_name or p_price_cents still means "leave it alone", so the function cannot be
--      used to blank a name by omission.
--
-- Nothing here touches credit_ledger, points_ledger or sales. No VALUE_TABLE is written.

begin;

-- ---------------------------------------------------------------------------
-- 1. Booking confirmation: appointments authority only where appointments exist.
-- ---------------------------------------------------------------------------

-- True when the PLATFORM/sector grants this business any appointments access at all. It reads
-- the platform resolution, never the staff resolution: a salon employee who simply has not been
-- given the appointments module must still be refused, and would be by the require_ call below.
create or replace function app.business_has_appointments_module_v288(p_business uuid, p_branch uuid)
returns boolean
language plpgsql
stable
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare v_mode text;
begin
  select resolved.mode into v_mode
    from app.effective_platform_module_mode_v94(p_business, p_branch, 'appointments') resolved;
  return coalesce(v_mode, 'disabled') <> 'disabled';
end
$$;
revoke all on function app.business_has_appointments_module_v288(uuid, uuid) from public, anon, authenticated;

-- The v94 wrapper. Splice against the DEPLOYED definition, never a guessed one.
do $v288_decide_wrapper$
declare
  v_source text;
  v_hits integer;
  v_needle constant text :=
$needle$  if p_decision='confirm' then
    perform app.require_branch_module_v94(
      p_business,v_branch,'appointments','rw'
    );
  end if;$needle$;
  v_patch constant text :=
$needle$  if p_decision='confirm'
     and app.business_has_appointments_module_v288(p_business,v_branch) then
    perform app.require_branch_module_v94(
      p_business,v_branch,'appointments','rw'
    );
  end if;$needle$;
begin
  v_source := pg_get_functiondef(
    'public.staff_decide_booking_request_v73(uuid,uuid,text,uuid)'::regprocedure);
  if position('business_has_appointments_module_v288' in v_source) > 0 then
    raise notice 'v288: the booking-decision wrapper already carries the sector condition';
    return;
  end if;
  v_hits := (length(v_source) - length(replace(v_source, v_needle, ''))) / length(v_needle);
  if v_hits <> 1 then
    raise exception 'v288: expected exactly 1 appointments gate in the v73 wrapper, found %', v_hits;
  end if;
  execute replace(v_source, v_needle, v_patch);

  v_source := pg_get_functiondef(
    'public.staff_decide_booking_request_v73(uuid,uuid,text,uuid)'::regprocedure);
  if position('business_has_appointments_module_v288' in v_source) = 0
     or position($check$'bookings','rw'$check$ in v_source) = 0 then
    raise exception 'v288: the sector condition did not land, or the bookings gate was lost';
  end if;
  raise notice 'v288: booking confirmation now demands appointments only where the sector has them';
end
$v288_decide_wrapper$;

-- The base function carries the same unconditional gate.
do $v288_decide_base$
declare
  v_source text;
  v_hits integer;
  v_needle constant text :=
$needle$  -- Confirm always requires the appointments write boundary as well.
  if not app.can_module_write(p_business, 'appointments') then
    raise exception 'appointment write access is required' using errcode = '42501';
  end if;$needle$;
  v_patch constant text :=
$needle$  -- v288: confirm requires the appointments write boundary wherever the sector HAS an
  -- appointments module. In a bookings-only sector (fnb, bar) that module is disabled for
  -- everyone, so demanding it made confirmation impossible; the bookings boundary above is
  -- then the authority, and it has already been required.
  if app.business_has_appointments_module_v288(p_business, null)
     and not app.can_module_write(p_business, 'appointments') then
    raise exception 'appointment write access is required' using errcode = '42501';
  end if;$needle$;
begin
  v_source := pg_get_functiondef(
    'public.staff_decide_booking_request_v73_v94_base(uuid,uuid,text,uuid)'::regprocedure);
  if position('business_has_appointments_module_v288' in v_source) > 0 then
    raise notice 'v288: the booking-decision base already carries the sector condition';
    return;
  end if;
  v_hits := (length(v_source) - length(replace(v_source, v_needle, ''))) / length(v_needle);
  if v_hits <> 1 then
    raise exception 'v288: expected exactly 1 appointments gate in the v73 base, found %', v_hits;
  end if;
  execute replace(v_source, v_needle, v_patch);

  v_source := pg_get_functiondef(
    'public.staff_decide_booking_request_v73_v94_base(uuid,uuid,text,uuid)'::regprocedure);
  if position('business_has_appointments_module_v288' in v_source) = 0
     or position($check$can_module_write(p_business, 'bookings')$check$ in v_source) = 0 then
    raise exception 'v288: the sector condition did not land in the base, or the bookings gate was lost';
  end if;
  raise notice 'v288: the booking-decision base now demands appointments only where the sector has them';
end
$v288_decide_base$;

-- ---------------------------------------------------------------------------
-- 2. Bottles: the honest exit for a bottle that should never have been listed.
-- ---------------------------------------------------------------------------

create or replace function public.remove_bottle_v288(
  p_business uuid,
  p_bottle uuid,
  p_idempotency_key text
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_actor uuid := auth.uid();
  v_key text := nullif(btrim(coalesce(p_idempotency_key, '')), '');
  v_existing uuid;
  v_bottle public.bar_bottles%rowtype;
  v_before text;
begin
  -- The bar gate is FIRST, exactly as every other function in this module orders it.
  perform app.require_bar_business_v275(p_business);
  perform app.require_bar_staff_v275(p_business, true);
  if v_key is null then
    raise exception 'idempotency key required' using errcode = '22023';
  end if;

  v_existing := app.bar_bottle_replayed_v275(p_business, v_key);
  if v_existing is not null then
    select * into v_bottle from public.bar_bottles bottle where bottle.id = v_existing;
    return jsonb_build_object('status', 'duplicate_ignored',
      'bottle', app.bar_bottle_json_v275(v_bottle));
  end if;

  select * into v_bottle from public.bar_bottles bottle
   where bottle.id = p_bottle and bottle.business_id = p_business for update;
  if not found then
    raise exception 'bottle not found' using errcode = '22023';
  end if;
  -- Removable from every state in which the bar still physically holds the bottle. A bottle that
  -- has already ended — retrieved, finished, transferred, or removed once — is not re-ended.
  if v_bottle.status not in ('stored', 'called', 'at_table', 'expired') then
    raise exception 'this bottle is already closed' using errcode = '22023';
  end if;
  v_before := v_bottle.status;

  update public.bar_bottles bottle
     set status = 'removed', updated_at = now()
   where bottle.id = v_bottle.id
  returning * into v_bottle;

  insert into public.bar_bottle_events (business_id, bottle_id, kind, actor, idem_key, detail)
  values (p_business, v_bottle.id, 'status', v_actor, v_key,
    jsonb_build_object('from', v_before, 'to', 'removed', 'reason', 'removed_from_list'));

  return jsonb_build_object('status', 'ok', 'bottle', app.bar_bottle_json_v275(v_bottle));
end;
$$;

-- ---------------------------------------------------------------------------
-- 3. Bottles: the catalogue row can be corrected, not only re-sized.
-- ---------------------------------------------------------------------------

create or replace function public.bar_save_bottle_product_v288(
  p_business uuid,
  p_product uuid,
  p_name text,
  p_size_ml integer,
  p_price_cents integer
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_actor uuid := auth.uid();
  v_name text := nullif(btrim(coalesce(p_name, '')), '');
  v_updated uuid;
begin
  perform app.require_bar_business_v275(p_business);
  if v_actor is null then
    raise exception 'authenticated staff required' using errcode = '28000';
  end if;
  if not app.is_salon_owner(p_business) then
    raise exception 'only the owner can change the bottle catalogue' using errcode = '42501';
  end if;
  if p_size_ml is not null and (p_size_ml < 100 or p_size_ml > 5000) then
    raise exception 'a bottle is between 100ml and 5000ml' using errcode = '22023';
  end if;
  if v_name is not null and length(v_name) > 120 then
    raise exception 'a bottle name is limited to 120 characters' using errcode = '22023';
  end if;
  if p_price_cents is not null and (p_price_cents < 0 or p_price_cents > 2147483647) then
    raise exception 'the price is not a valid amount' using errcode = '22023';
  end if;

  if p_product is null then
    if v_name is null then
      raise exception 'name the bottle' using errcode = '22023';
    end if;
    if p_size_ml is null then
      raise exception 'a new bottle needs its size in millilitres' using errcode = '22023';
    end if;
    insert into public.products (business_id, name, retail_price_cents, size_ml, active)
    values (p_business, v_name, coalesce(p_price_cents, 0), p_size_ml, true);
  else
    -- A null name or price still means "leave it alone", so this cannot blank a name by
    -- omission; the size is genuinely nullable (clearing it means "not a bottle") and is
    -- therefore written unconditionally, exactly as v278 wrote it.
    update public.products product
       set size_ml = p_size_ml,
           name = coalesce(v_name, product.name),
           retail_price_cents = coalesce(p_price_cents, product.retail_price_cents)
     where product.id = p_product and product.business_id = p_business
    returning product.id into v_updated;
    if v_updated is null then
      raise exception 'product not found' using errcode = '22023';
    end if;
  end if;

  return public.bar_get_bottle_setup_v278(p_business);
end;
$$;

revoke all on function public.remove_bottle_v288(uuid, uuid, text) from public, anon, authenticated;
revoke all on function public.bar_save_bottle_product_v288(uuid, uuid, text, integer, integer) from public, anon, authenticated;

grant execute on function public.remove_bottle_v288(uuid, uuid, text) to authenticated;
grant execute on function public.bar_save_bottle_product_v288(uuid, uuid, text, integer, integer) to authenticated;

commit;
