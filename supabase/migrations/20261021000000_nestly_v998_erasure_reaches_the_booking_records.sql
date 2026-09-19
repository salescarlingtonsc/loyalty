-- nestly_v998 — erasing a customer erases them from the booking records too (2026-09-19).
--
-- ⚖️ PDPA. Found by the business-view sweep and confirmed against production.
--
-- public.erase_client_v290 anonymises public.clients: full_name becomes 'Erased customer', phone,
-- email, birth_date, gender, notes and referral_code are cleared, marketing_consent goes false, and
-- nestly_v473 unlinks the customer's own account. It has never touched public.booking_requests or
-- public.waitlist, and BOTH keep their own copy of the person's contact details -- denormalised on
-- purpose, because a booking request can exist before any client row does.
--
-- MEASURED ON PRODUCTION BEFORE THIS SHIPPED:
--     21 erasures recorded in client_erasures_v290
--     17 booking_requests rows still carrying a name, phone or email
--      5 distinct people, each of whom had asked to be erased
--      0 waitlist rows (same column shape, no data in that state today)
-- Those names and phone numbers render on the Bookings page. One of the recorded reasons is
-- "customer deleted their own Peekaa account".
--
-- I checked every table in `public` that carries BOTH a client reference and a personal-data column
-- (name / full_name / phone / email / contact_*), not just the two the sweep named:
--     booking_requests   name, email, phone
--     waitlist           name, phone
-- Those are the only two. Everything else reaches the person through clients.id and so was already
-- covered by the v290 anonymisation.
--
-- WHAT THIS CHANGES. The writer, and only the writer: from now on an erasure clears the person out
-- of both tables in the same transaction as the clients row, so nobody is ever left half-erased --
-- which is the property nestly_v473's own comment already claimed for the link unlinking.
--
-- THE ROW SURVIVES; THE PERSON DOES NOT. name becomes 'Erased customer' (matching what v290 already
-- writes to clients.full_name) and phone/email/notes are nulled. The booking_requests row is not
-- deleted: it is the shop's operational record that a booking happened, and removing it would
-- silently rewrite their own history and their reporting. PDPA asks for the personal data to go, not
-- for the business's books to change. notes is cleared on the same reasoning v290 already applies to
-- clients.notes -- it is customer-supplied free text and can carry anything.
--
-- THE 17 EXISTING ROWS ARE NOT TOUCHED BY THIS MIGRATION. Layer 8 of the bug-closure protocol:
-- close the writer, THEN backfill. The backfill is an irreversible destruction of production data
-- (deliberately -- a rollback table holding the recovered PII would itself defeat the erasure), so
-- it is a separate, explicitly approved step and not something a migration does on its way past.
--
-- Rollback suite: db/tests/v998_erasure_reaches_the_booking_records.sql

begin;

do $v998_assert$
declare v_body text := pg_get_functiondef('public.erase_client_v290(uuid,uuid,text,text)'::regprocedure);
begin
  if position('nestly_v998' in v_body) > 0 then
    raise exception 'v998: erase_client_v290 already carries v998';
  end if;
  if position('booking_requests' in v_body) > 0 then
    raise exception 'v998: erase_client_v290 already mentions booking_requests -- it has drifted';
  end if;
  /* the columns this migration writes must exist, or the erasure would start throwing */
  if not exists (select 1 from information_schema.columns
                  where table_schema='public' and table_name='booking_requests'
                    and column_name in ('name','phone','email','notes')
                  having count(*) = 4) then
    raise exception 'v998: booking_requests does not carry the four columns this erasure clears';
  end if;
  if not exists (select 1 from information_schema.columns
                  where table_schema='public' and table_name='waitlist'
                    and column_name in ('name','phone')
                  having count(*) = 2) then
    raise exception 'v998: waitlist does not carry name and phone';
  end if;
end
$v998_assert$;

CREATE OR REPLACE FUNCTION public.erase_client_v290(p_business uuid, p_client uuid, p_reason text, p_idem text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'app', 'pg_temp'
AS $function$
declare
  v_actor uuid := auth.uid();
  v_reason text := nullif(btrim(coalesce(p_reason,'')),'');
  v_key text := nullif(btrim(coalesce(p_idem,'')),'');
  v_client public.clients%rowtype;
  v_existing public.client_erasures_v290%rowtype;
  v_credit bigint := 0;
  v_bottles integer := 0;
  v_sv integer := 0;
  v_fields jsonb;
  v_id uuid;
  v_unlinked uuid[] := array[]::uuid[];
begin
  if v_actor is null or p_business is null or p_client is null
     or not app.is_salon_owner(p_business) then
    raise exception 'customer erasure requires the workspace owner' using errcode = '42501';
  end if;
  if v_reason is null or char_length(v_reason) not between 4 and 500 then
    raise exception 'an erasure reason of 4 to 500 characters is required' using errcode = '22023';
  end if;
  if v_key is null or char_length(v_key) not between 8 and 200 then
    raise exception 'an idempotency key of 8 to 200 characters is required' using errcode = '22023';
  end if;

  perform pg_advisory_xact_lock(
    hashtextextended(p_business::text||':client-erasure-v290:'||v_key,0));

  select * into v_existing from public.client_erasures_v290 record
   where record.business_id = p_business
     and (record.idempotency_key = v_key or record.client_id = p_client);
  if found then
    if v_existing.client_id is distinct from p_client
       or v_existing.idempotency_key is distinct from v_key then
      raise exception 'this customer or key was already used for a different erasure'
        using errcode = '23505';
    end if;
    -- nestly_v473: a replay REPAIRS. Every customer erased before this migration kept a verified
    -- link, and without this branch the only way to close one would be a hand-written UPDATE,
    -- which the immutability guard refuses anyway.
    v_unlinked := app.unlink_client_links_for_erasure_v473(p_business, p_client, v_actor);
    if cardinality(v_unlinked) > 0 then
      insert into public.audit_log(business_id, actor, action, entity, entity_id, detail)
      values (p_business, v_actor, 'CLIENT_ERASED_V290', 'clients', p_client,
        jsonb_build_object('erasure_id', v_existing.id, 'repaired_links', to_jsonb(v_unlinked),
          'note','links left verified by a pre-v473 erasure, closed on replay'));
    end if;
    return jsonb_build_object('status','duplicate_ignored','erasure_id',v_existing.id,
      'client_id',v_existing.client_id,'erased_at',v_existing.created_at,
      'unlinked_links',to_jsonb(v_unlinked));
  end if;

  select * into v_client from public.clients customer
   where customer.id = p_client and customer.business_id = p_business
   for update;
  if not found then
    raise exception 'customer not found in this business' using errcode = '22023';
  end if;

  -- Three refusals. Each is something the business still HOLDS that belongs to this person; the
  -- identity that names the owner of it cannot be removed while it is outstanding.
  select coalesce(sum(ledger.amount_cents),0)::bigint into v_credit
    from public.credit_ledger ledger
   where ledger.business_id = p_business and ledger.client_id = p_client;
  select count(*)::integer into v_bottles
    from public.bar_bottles bottle
   where bottle.business_id = p_business and bottle.client_id = p_client
     and bottle.status in ('stored','called','at_table','expired');
  -- Stored value blocks on PARTICIPATION, not on a computed balance: the lot/movement sign
  -- convention belongs to PS-2 and this function must never guess a balance in order to decide
  -- whether it is safe to erase somebody. It fails closed.
  select count(*)::integer into v_sv
    from public.sv_lots lot
    join public.sv_accounts account on account.id = lot.account_id
   where account.business_id = p_business and account.client_id = p_client;

  if v_credit > 0 or v_bottles > 0 or v_sv > 0 then
    -- Refused BEFORE the unlink, deliberately: a refusal must change nothing at all, and taking
    -- the business off someone's phone while still holding their credit would be the worst of
    -- both outcomes.
    return jsonb_build_object('status','refused','reason','holdings_outstanding',
      'credit_balance_cents',v_credit,'bottles_in_storage',v_bottles,
      'stored_value_lots',v_sv);
  end if;

  v_fields := jsonb_build_object(
    'full_name',v_client.full_name is not null,
    'phone',v_client.phone is not null,
    'email',v_client.email is not null,
    'birth_date',v_client.birth_date is not null,
    'gender',v_client.gender is not null,
    'notes',v_client.notes is not null,
    'tags',coalesce(cardinality(v_client.tags),0) > 0,
    'referral_code',v_client.referral_code is not null);

  -- Anonymised in place. phone_norm is a GENERATED column and clears itself with phone.
  update public.clients customer
     set full_name = 'Erased customer',
         phone = null,
         email = null,
         birth_date = null,
         gender = null,
         notes = null,
         tags = array[]::text[],
         referral_code = null,
         marketing_consent = false
   where customer.id = p_client and customer.business_id = p_business;

  -- nestly_v998: the same erasure, in the two OTHER tables that keep their own copy of the
  -- person's contact details. booking_requests and waitlist each carry name/phone (and
  -- booking_requests an email) captured at the time of the request, denormalised so a request
  -- can exist before a client row does. Anonymising public.clients never touched them, so an
  -- erased person's real name and phone stayed readable on the Bookings page -- measured on
  -- production before this shipped: 17 booking rows for 5 people who had asked to be erased.
  -- The row itself is kept: it is an operational record of a booking that happened, and deleting
  -- it would silently rewrite the shop's own history. Only the personal data goes.
  update public.booking_requests request
     set name = 'Erased customer',
         phone = null,
         email = null,
         notes = null
   where request.business_id = p_business
     and request.customer_client_id = p_client;

  update public.waitlist entry
     set name = 'Erased customer',
         phone = null
   where entry.business_id = p_business
     and entry.client_id = p_client;

  -- nestly_v473 (owner): and the business leaves their phone. Same transaction as the
  -- anonymisation, so a customer is never left half-erased.
  v_unlinked := app.unlink_client_links_for_erasure_v473(p_business, p_client, v_actor);

  insert into public.client_erasures_v290(
    business_id, client_id, actor, reason, idempotency_key, erased_fields
  ) values (
    p_business, p_client, v_actor, v_reason, v_key, v_fields
  ) returning id into v_id;

  insert into public.audit_log(business_id, actor, action, entity, entity_id, detail)
  values (
    p_business, v_actor, 'CLIENT_ERASED_V290', 'clients', p_client,
    -- The unlinked link ids ride the existing audit row rather than a customer-shaped row in
    -- customer_link_audit_events: that table's columns assume the CUSTOMER acted.
    jsonb_build_object('erasure_id',v_id,'reason',v_reason,'erased_fields',v_fields,
      'unlinked_links',to_jsonb(v_unlinked)));

  return jsonb_build_object('status','erased','erasure_id',v_id,'client_id',p_client,
    'erased_fields',v_fields,'unlinked_links',to_jsonb(v_unlinked));
end;
$function$;

-- Signature unchanged, so CREATE OR REPLACE preserved the grants; restated from the live proacl per
-- the repo's preflight rule, exactly as nestly_v473 restated them for the same function.
revoke all on function public.erase_client_v290(uuid,uuid,text,text) from public, anon;
grant execute on function public.erase_client_v290(uuid,uuid,text,text) to authenticated, service_role;

commit;
