-- nestly_v998 acceptance — ⚖️ erasing a customer erases them from the booking records too.
--
-- Run:  supabase db query --linked -f db/tests/v998_erasure_reaches_the_booking_records.sql
-- Ends by raising V998_RESULT so nothing commits. PASS is an exception saying ALL PASS.
--
-- PROVEN RED FIRST against production, before the migration existed: erase_client_v290 anonymised
-- public.clients and left public.booking_requests untouched, so 17 rows still carried the real name,
-- phone and email of 5 people who had asked to be erased. This suite manufactures that exact
-- situation on a throwaway client and asserts the erasure now reaches it.
--
-- Everything is created inside the transaction and rolled back; no production row is read into the
-- assertions and none is written.

begin;

do $v998$
declare
  n integer := 0;
  v_biz uuid;
  v_owner uuid;
  v_client uuid;
  v_request uuid;
  v_name text;
  v_phone text;
  v_email text;
  v_notes text;
  v_wl_name text;
  v_wl_phone text;
  v_has_waitlist boolean;
begin
  -- ==========================================================================================
  -- 1 · A throwaway customer at a real tenant, with a booking request carrying their details.
  --     Run AS THE OWNER: erase_client_v290 is SECURITY DEFINER but gates on app.is_salon_owner,
  --     so calling it as the table owner would prove nothing about what a merchant can do.
  -- ==========================================================================================
  /* a tenant that actually accepts a customer-linked booking request. app.v89_customer_booking_gate
     refuses the insert outright unless business_customer_capabilities_v89.booking_enabled is true
     AND the bookings module is on, so picking any owner at random makes this suite fail for a
     reason that has nothing to do with erasure. */
  select s.business_id, s.user_id into v_biz, v_owner
    from public.staff s
   where s.role = 'owner' and s.active and s.user_id is not null
     and coalesce((select c.booking_enabled from public.business_customer_capabilities_v89 c
                    where c.business_id = s.business_id), false)
     and app.v89_business_module_enabled(s.business_id, 'bookings')
   limit 1;
  if v_biz is null then
    raise exception 'V998 INCONCLUSIVE: no tenant has an active owner login with customer booking enabled';
  end if;

  insert into public.clients(business_id, full_name, phone, email)
  values (v_biz, 'V998 Probe Person', '+65 8000 0998', 'v998probe@example.test')
  returning id into v_client;

  insert into public.booking_requests(business_id, customer_client_id, name, phone, email, notes, status)
  values (v_biz, v_client, 'V998 Probe Person', '+65 8000 0998', 'v998probe@example.test',
          'probe note that names the person', 'pending')
  returning id into v_request;

  select exists (select 1 from information_schema.columns
                  where table_schema='public' and table_name='waitlist' and column_name='client_id')
    into v_has_waitlist;
  if v_has_waitlist then
    begin
      insert into public.waitlist(business_id, client_id, name, phone)
      values (v_biz, v_client, 'V998 Probe Person', '+65 8000 0998');
    exception when others then
      v_has_waitlist := false;   /* the table has required columns this probe does not know; skip it */
    end;
  end if;
  n := n + 1;

  -- ==========================================================================================
  -- 2 · The details really are there before the erasure. Without this the suite could pass on a
  --     row that never held anything.
  -- ==========================================================================================
  select name, phone, email into v_name, v_phone, v_email
    from public.booking_requests where id = v_request;
  if v_name is distinct from 'V998 Probe Person' or v_phone is null or v_email is null then
    raise exception 'V998 ASSERT 2 FAILED: the probe booking request did not store the details to begin with';
  end if;
  n := n + 1;

  -- ==========================================================================================
  -- 3 · Erase, as the owner, through the real RPC.
  -- ==========================================================================================
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner::text, 'role', 'authenticated')::text, true);
  set local role authenticated;
  perform public.erase_client_v290(v_biz, v_client, 'V998 acceptance probe erasure', 'v998-probe-' || v_client::text);
  reset role;
  n := n + 1;

  -- ==========================================================================================
  -- 4 · THE DEFECT. The booking record must no longer name the person. This was red.
  -- ==========================================================================================
  select name, phone, email, notes into v_name, v_phone, v_email, v_notes
    from public.booking_requests where id = v_request;
  if v_name = 'V998 Probe Person' or v_phone is not null or v_email is not null then
    raise exception 'V998 ASSERT 4 FAILED: an erased customer is still named in booking_requests — name=%, phone=%, email=%',
      v_name, coalesce(v_phone,'<null>'), coalesce(v_email,'<null>');
  end if;
  if v_notes is not null then
    raise exception 'V998 ASSERT 4 FAILED: the booking note survived the erasure: %', v_notes;
  end if;
  n := n + 1;

  -- ==========================================================================================
  -- 5 · THE ROW SURVIVES. PDPA asks for the person to go, not for the shop's booking history to
  --     be rewritten. A fix that DELETED the row would pass assertion 4 and lose the business's
  --     own record — this is what tells the two apart.
  -- ==========================================================================================
  if not exists (select 1 from public.booking_requests where id = v_request) then
    raise exception 'V998 ASSERT 5 FAILED: the booking request row was deleted, not anonymised';
  end if;
  n := n + 1;

  -- ==========================================================================================
  -- 6 · The waitlist, where this tenant's schema allows a probe row.
  -- ==========================================================================================
  if v_has_waitlist then
    select name, phone into v_wl_name, v_wl_phone
      from public.waitlist where client_id = v_client and business_id = v_biz limit 1;
    if v_wl_name = 'V998 Probe Person' or v_wl_phone is not null then
      raise exception 'V998 ASSERT 6 FAILED: an erased customer is still named on the waitlist — name=%, phone=%',
        v_wl_name, coalesce(v_wl_phone,'<null>');
    end if;
    n := n + 1;
  end if;

  -- ==========================================================================================
  -- 7 · CONTROL — the clients row is still anonymised as v290 always did, so this migration has
  --     not traded one erasure for another.
  -- ==========================================================================================
  select full_name, phone, email into v_name, v_phone, v_email
    from public.clients where id = v_client;
  if v_name is distinct from 'Erased customer' or v_phone is not null or v_email is not null then
    raise exception 'V998 ASSERT 7 FAILED: the clients row is no longer being anonymised — name=%', v_name;
  end if;
  n := n + 1;

  raise exception 'V998_RESULT ALL PASS (% assertions)', n;
end
$v998$;

rollback;
