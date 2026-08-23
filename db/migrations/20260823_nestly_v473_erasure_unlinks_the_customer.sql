-- nestly_v473 — erasing a customer takes the business off that customer's phone.
--
-- OWNER, 2026-08-23, against a business-side profile headed "Erased customer":
--   "deleted customer in business view - customer end should not be able to see the business,
--    it must be removed, until the customer join the business again"
--
-- THE DEFECT. public.erase_client_v290 anonymises public.clients and records the erasure, and
-- never touches public.customer_links. Wallet visibility is decided in exactly one place —
-- app.v32_customer_wallet_context joins customer_links on state='verified' — and every customer
-- surface goes through it: customer_get_wallet, customer_get_actionable_wallet,
-- customer_get_business_summary, customer_list_programmes_v89, the in-app inbox, the business
-- directory, and promotion push targeting (app.enqueue_promotion_alert_v122). So an erased
-- customer kept full access to the business, its programmes and its notifications. The only thing
-- that changed was a name they could not see anyway.
--
-- Worse, the erase dialog already PROMISED this: "the customer's own app sign-in for this business
-- stops resolving to them" (app/app.js). The sentence was false. This makes it true.
--
-- PROOF IT IS LIVE, not theoretical: public.client_erasures_v290 holds exactly one row — client
-- 9acc0c04-14be-40b8-9473-b40ae5f95b40 at QA Kaya Toast, erased 2026-08-23 13:44:59Z — and its
-- link d45213ba-942e-4962-aee9-d1dd8ec01151 is still state='verified', unlinked_at null. That is
-- the owner's screenshot. Section 4 repairs it.
--
-- WHAT IS DELIBERATELY NOT DONE:
--   * No schema change. 'unlinked', unlinked_at and unlinked_by_auth_user_id already exist, and
--     customer_links_state_time_check already models exactly this shape. unlinked_by_auth_user_id
--     is an FK to auth.users and may legitimately hold the OWNER's uid, so a business-initiated
--     unlink needs no new column and no new state.
--   * public.customer_unlink_business_link is NOT reused. It resolves the caller's own identity
--     from auth.uid(), so under an owner's session it would resolve the OWNER — or throw. It is a
--     self-service route and stays one.
--   * The row is never deleted. app.v31_link_immutable_guard refuses DELETE outright ("customer
--     links are retained as relationship evidence") and that is right: the unlinked row is the
--     evidence that this relationship existed, which is exactly what an erasure audit needs.
--   * Nothing about the accounting record changes. sales, points_ledger, credit_ledger,
--     appointments, packages and memberships are all keyed (business_id, client_id) directly on
--     clients and are never read through customer_links — verified by scanning every function
--     whose body mentions the table. The banner's promise still holds.
--   * Rejoining needs no work at all. The unique indexes on customer_links are PARTIAL
--     (WHERE state='verified'), so an 'unlinked' row never blocks a new one; the QR doors insert a
--     fresh verified link. And because erasure nulls phone/email/phone_norm, no auto-match path
--     can re-attach the erased client — customer_sync_verified_relationships_v81 additionally
--     excludes any client with a prior link. So coming back is a deliberate act (scan the QR),
--     which is what the owner asked for, and it starts a clean record rather than resurrecting an
--     erased one.

begin;

-- ---------------------------------------------------------------------------------------------
-- 1. THE UNLINK, as its own function.
--
-- Extracted rather than inlined because erase_client_v290 has to call it from TWO places (see
-- section 3), and a transition this fiddly must not exist twice.
--
-- app.v31_link_immutable_guard is the reason it is fiddly. On UPDATE it raises 23000 unless
-- app.customer_link_transition_id equals the row's own id AND every other column is byte
-- identical AND the move is exactly verified -> unlinked with both unlink columns set. The GUC is
-- set transaction-local and cleared immediately after, the same discipline
-- customer_unlink_business_link uses. Note the guard checks the GUC, not the caller's role — it
-- was always capable of admitting a business-initiated unlink; only its error message said
-- otherwise, which section 2 corrects.
--
-- Idempotent by construction: `where state='verified'` matches nothing on a second pass.
-- ---------------------------------------------------------------------------------------------
create or replace function app.unlink_client_links_for_erasure_v473(
  p_business uuid, p_client uuid, p_actor uuid)
returns uuid[]
language plpgsql
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $function$
declare
  v_link record;
  v_ids uuid[] := array[]::uuid[];
begin
  if p_business is null or p_client is null or p_actor is null then
    return v_ids;
  end if;
  for v_link in
    select id from public.customer_links
     where business_id = p_business and client_id = p_client and state = 'verified'
     order by id
     for update
  loop
    perform set_config('app.customer_link_transition_id', v_link.id::text, true);
    -- state, unlinked_at and unlinked_by_auth_user_id must move in ONE statement or
    -- customer_links_state_time_check fires on the intermediate row.
    update public.customer_links
       set state = 'unlinked',
           unlinked_at = now(),
           unlinked_by_auth_user_id = p_actor,
           updated_at = now()
     where id = v_link.id;
    perform set_config('app.customer_link_transition_id', '', true);
    v_ids := v_ids || v_link.id;
  end loop;
  return v_ids;
end;
$function$;

revoke all on function app.unlink_client_links_for_erasure_v473(uuid,uuid,uuid) from public, anon, authenticated;

comment on function app.unlink_client_links_for_erasure_v473(uuid,uuid,uuid) is
  'nestly_v473. Moves this business''s verified customer_links for one client to ''unlinked'', so '
  'an erased customer stops seeing the business. Internal only — the caller is responsible for '
  'having proved owner authority. Idempotent. Never deletes: the unlinked row is the evidence '
  'that the relationship existed.';

-- ---------------------------------------------------------------------------------------------
-- 2. THE GUARD'S MESSAGE, corrected.
--
-- Behaviour is byte-identical; only the sentence changes. It said the transition may happen "through
-- the self-service route", which was never what the guard actually enforced — it enforces the GUC.
-- Leaving it would send the next reader looking for a bug in this migration.
-- ---------------------------------------------------------------------------------------------
create or replace function app.v31_link_immutable_guard()
returns trigger
language plpgsql
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $function$
declare
  v_insert_id text := nullif(current_setting('app.customer_link_insert_id', true), '');
  v_transition_id text := nullif(current_setting('app.customer_link_transition_id', true), '');
begin
  if tg_op = 'INSERT' then
    if v_insert_id is distinct from new.id::text or new.state <> 'verified' or new.verified_at is null then
      raise exception 'customer links may only be created by a verified claim route' using errcode = '42501';
    end if;
    return new;
  end if;
  if tg_op = 'DELETE' then
    raise exception 'customer links are retained as relationship evidence' using errcode = '23000';
  end if;
  if v_transition_id is distinct from old.id::text
     or old.state <> 'verified' or new.state <> 'unlinked'
     or (new.id, new.business_id, new.identity_id, new.auth_user_id, new.client_id,
         new.verification_method, new.verified_at, new.created_at)
        is distinct from
        (old.id, old.business_id, old.identity_id, old.auth_user_id, old.client_id,
         old.verification_method, old.verified_at, old.created_at)
     or new.unlinked_at is null or new.unlinked_by_auth_user_id is null then
    -- nestly_v473: the two routes are the customer's own (customer_unlink_business_link) and the
    -- owner's erasure (app.unlink_client_links_for_erasure_v473). Both announce themselves by
    -- setting app.customer_link_transition_id, which is what this guard actually checks.
    raise exception 'customer links may only transition verified -> unlinked through a route that declares the transition'
      using errcode = '23000';
  end if;
  return new;
end;
$function$;

-- ---------------------------------------------------------------------------------------------
-- 3. ERASE UNLINKS.
--
-- Two call sites, and the second one matters as much as the first.
--
-- The duplicate-ignored branch returns before any work, so an already-recorded erasure could
-- never be repaired by running erase again — every customer erased before today would have stayed
-- visible forever. Calling the unlink there too makes a replay a REPAIR: same idempotency key, same
-- answer, and any link left behind is closed. It is safe precisely because the unlink is
-- idempotent, so a replay against an already-unlinked customer still writes nothing.
-- ---------------------------------------------------------------------------------------------
create or replace function public.erase_client_v290(p_business uuid, p_client uuid, p_reason text, p_idem text)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $function$
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
    -- link, and without this branch the only way to close one would have been a hand-written
    -- UPDATE — which the immutability guard refuses anyway.
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

  -- nestly_v473 (owner): and the business leaves their phone. Same transaction as the
  -- anonymisation, so a customer is never left half-erased — either both happened or neither did.
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
    -- customer_link_audit_events: that table's columns (actor_auth_user_id, identity_id) assume the
    -- CUSTOMER acted, and an owner erasure is not that event.
    jsonb_build_object('erasure_id',v_id,'reason',v_reason,'erased_fields',v_fields,
      'unlinked_links',to_jsonb(v_unlinked)));

  return jsonb_build_object('status','erased','erasure_id',v_id,'client_id',p_client,
    'erased_fields',v_fields,'unlinked_links',to_jsonb(v_unlinked));
end;
$function$;

-- Signature unchanged, so CREATE OR REPLACE preserved the grants; restated from the live proacl
-- per the repo's preflight rule.
revoke all on function public.erase_client_v290(uuid,uuid,text,text) from public, anon;
grant execute on function public.erase_client_v290(uuid,uuid,text,text) to authenticated, service_role;

-- ---------------------------------------------------------------------------------------------
-- 4. THE ONE CUSTOMER ALREADY ERASED, REPAIRED.
--
-- Section 3 makes a replay repair, but a replay needs somebody to run it, and this person can see
-- a business that erased them right now. Closed here instead. It goes through the same function,
-- so it obeys the same guard and leaves the same evidence — never a hand-written UPDATE, which
-- the trigger would refuse anyway (23000).
--
-- The actor recorded is the owner who performed the original erasure, read from the erasure
-- record itself, so the audit trail names the person who actually decided this rather than
-- whoever happened to run the migration.
-- ---------------------------------------------------------------------------------------------
do $$
declare
  v_row record;
  v_ids uuid[];
  v_total integer := 0;
begin
  for v_row in
    select er.business_id, er.client_id, er.actor
      from public.client_erasures_v290 er
     where exists (
       select 1 from public.customer_links link
        where link.business_id = er.business_id
          and link.client_id = er.client_id
          and link.state = 'verified')
  loop
    v_ids := app.unlink_client_links_for_erasure_v473(v_row.business_id, v_row.client_id, v_row.actor);
    v_total := v_total + coalesce(cardinality(v_ids), 0);
    insert into public.audit_log(business_id, actor, action, entity, entity_id, detail)
    values (v_row.business_id, v_row.actor, 'CLIENT_ERASED_V290', 'clients', v_row.client_id,
      jsonb_build_object('repaired_links', to_jsonb(v_ids),
        'note','nestly_v473 backfill: erased before erasure unlinked, closed by the migration'));
  end loop;
  raise notice 'nestly_v473 repaired % customer link(s) left verified by a pre-v473 erasure', v_total;
end $$;

commit;
