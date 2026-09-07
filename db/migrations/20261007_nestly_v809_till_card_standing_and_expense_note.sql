/* nestly_v809 — the till reads one customer card, can re-read it without a phone number, and an
   expense note can actually be cleared.

   Three audit findings (F020, F057, F105), each proven read-only against production
   gadpooereceldfpfxsod on 2026-09-07, the write-shaped one as the real principal in a rolled-back
   probe.

   ---------------------------------------------------------------------------------------------
   F020 — the same customer reads two different stamp figures depending on how staff found them.

   v474 fixed "15 stamps vs 5 of 10" by adding a stamp_card object to public.lookup_client_by_phone
   and to nothing else. The two QR entry points that put the very same customer card on screen —
   public.staff_scan_member_qr_v327 and public.staff_scan_gift_qr_to_till_v666, both now built by
   app.v666_till_customer_card — never gained it, so app/app.js falls through to the raw points
   balance, which for a stamps firm is the POT. Owner rule (v473): staff read the CARD, never the
   pot.

   Proof, live, on the stamps tenant "Tea First Lah" (8ccace3a-9736-447e-bb1e-da842622592d):

     client Zephyr 021f3320-45fe-4c63-b5e4-27e018628149
       app.v666_till_customer_card -> points = 18, has 'stamp_card' key = FALSE
       app.stamp_progress_v323     -> slots 5, filled 3, net_stamps 18

     So the till header says "18 stamps" when the customer is scanned and "3 of 5" when the same
     customer is typed in by phone — on the same screen, for the same person. Catalogue check:
     lookup_client_by_phone has stamp_card, staff_scan_member_qr_v327 /
     staff_scan_gift_qr_to_till_v666 / app.v666_till_customer_card do not.

   THE FIX — one authority, not a second copy of the arithmetic. The stamp_card object moves out
   of lookup_client_by_phone into app.till_stamp_card_v809, and BOTH card builders call it. The
   payload is byte-identical to the one v474 shipped (same keys, same order, same clamping, same
   "stamps model with slots, else null" condition) and it is still computed by app.stamp_progress_v323,
   which remains the only stamp reader. Nothing computes stamps a second way.

   ---------------------------------------------------------------------------------------------
   F057 — the till header cannot refresh itself for a customer who has no phone number.

   refreshTillCustomerStandingV408 (the v408 fix for "when press redeem it must reduce the points
   immediately") re-reads the balance only through lookup_client_by_phone and bails when there is
   no phone. A customer who reached the till through a member QR or a gift QR carries
   phone = clients.phone_norm, which is NULL for anyone auto-provisioned by the member-QR scan
   (staff_scan_member_qr_v327 inserts business_id and full_name only), and the keypad's phone
   variable is empty on the scan path. After a manual redeem, a gift-QR redemption or a gift undo
   the header keeps the pre-redemption figure until the customer is found again.

   Proof, live: 23 of 70 public.clients rows have phone_norm IS NULL, so the refresh is already
   unreachable for a third of the estate's customers whenever they arrive by QR.

   THE FIX — public.till_customer_standing_v809(p_business, p_client): the same card, addressed by
   the identifier the till already holds. It is a NEW name rather than a parameter on
   lookup_client_by_phone, so no overload is created and PostgREST can never answer a
   named-argument call with PGRST203 (v410). Its gate is lookup_client_by_phone's gate, verbatim:
   app.has_perm(p_business,'create_sales') AND app.can_module_read(p_business,'clients'). It reads
   and writes nothing — it returns app.v666_till_customer_card, the object the scan already
   returned to this same caller.

   ---------------------------------------------------------------------------------------------
   F105 — "clear the note" and "leave the note alone" are the same call.

   public.update_expense_v285 resolves the note as
   `coalesce(nullif(btrim(coalesce(p_note,'')),''), expense.note)`. The dialog sends
   `p_note: note||null`, so an emptied field arrives as NULL, which the RPC reads as "unchanged".
   The toast says "Expense corrected" and the old note survives.

   Proof, live, rolled back, run as the real principal (`set local role authenticated` with the
   owner's JWT claims) on QA Test Cafe dcaaf5d6-3396-43b4-bff4-1cdd4df01cbf:

     note_before = [duplicate of invoice #204, TBD]
     update_expense_v285(..., p_note => null)
     note_after  = [duplicate of invoice #204, TBD]      <- the clear did nothing

   THE FIX — p_clear_note boolean default false, the same shape v807 used for p_clear_staff:

     p_clear_note = false -> note = coalesce(nullif(btrim(coalesce(p_note,'')),''), expense.note)
                             (v285, byte-for-byte)
     p_clear_note = true  -> note = null

   A note AND a clear together is a contradiction, not a precedence puzzle, so it is refused with
   22023 rather than resolved silently.

   WHY DROP AND RECREATE. CREATE OR REPLACE cannot add a parameter; it would leave the 5-argument
   function beside a 6-argument one and PostgREST answers a named-argument call matching two
   candidates with PGRST203 — which is how v410 blocked every promotion save. The old signature is
   dropped and the new one carries the default, so ONE function is in the catalogue and the
   5-argument call keeps exactly the behaviour it has today. Nothing else in the database calls it
   (checked against production: no other pg_proc body mentions update_expense_v285).

   NO PERMISSION CHANGE ANYWHERE. Every ACL below restates production verbatim: the three public
   RPCs are {postgres=X/postgres, authenticated=X/postgres, service_role=X/postgres} and the app
   helpers are postgres-only, reached only from SECURITY DEFINER functions postgres owns. The
   view_finance + expenses guard on the expense RPC, and the create_sales + clients guard on the
   card readers, are unchanged.

   Client: app/app.js reads the card's stamp_card on every till entry point, refreshes standing by
   client id when there is no phone, and sends p_clear_note when the note field was emptied.

   Rollback suite: db/tests/v809_till_card_standing_and_expense_note.sql */
begin;

-- =============================================================================================
-- F020 (1/3) — one authority for the stamp card the counter reads.
-- =============================================================================================
create or replace function app.till_stamp_card_v809(p_business uuid, p_client uuid)
returns json
language sql
stable
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $function$
  /* nestly_v809: lifted verbatim out of public.lookup_client_by_phone (v474) so the phone path and
     the two QR paths cannot answer "how far along is this card" differently. app.stamp_progress_v323
     stays the only stamp reader; this adds no second arithmetic. */
  select case when lp.loyalty_model = 'stamps' and coalesce(sp.slots, 0) > 0
    then json_build_object(
      'slots',   sp.slots,
      'filled',  least(greatest(coalesce(sp.filled, 0), 0), sp.slots),
      'carried', greatest(coalesce(sp.filled, 0) - sp.slots, 0),
      'ready',   sp.ready,
      'pot',     sp.net_stamps)
    else null end
    from app.stamp_progress_v323(p_business, p_client) sp
    left join lateral (
      select program.loyalty_model
        from public.loyalty_programs program
       where program.business_id = p_business and program.active
       limit 1) lp on true;
$function$;

revoke all on function app.till_stamp_card_v809(uuid, uuid) from public, anon, authenticated;

comment on function app.till_stamp_card_v809(uuid, uuid) is
  'nestly_v809 builds the till/customer stamp-card object (slots, filled, carried, ready, pot) from app.stamp_progress_v323, or NULL when the business is not on the stamps model. Extracted from lookup_client_by_phone (v474) so app.v666_till_customer_card serves the identical object to the member-QR and gift-QR paths — owner rule v473: staff read the CARD, never the pot.';

-- =============================================================================================
-- F020 (2/3) — the QR card carries the stamp card. Byte-for-byte v666 otherwise.
-- =============================================================================================
create or replace function app.v666_till_customer_card(p_business uuid, p_client uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $function$
declare
  v_client public.clients%rowtype;
  v_points integer;
  v_credit integer;
  v_visits integer;
  lp record;
begin
  select * into v_client from public.clients
   where id = p_client and business_id = p_business;
  if not found then
    return jsonb_build_object('status','invalid','message','This customer is not in this business.');
  end if;

  v_points := app.client_points_balance_v409(p_business, v_client.id);
  select coalesce(sum(amount_cents),0) into v_credit
    from public.credit_ledger where business_id=p_business and client_id=v_client.id;
  -- nestly_v677: net the reversals, so the card agrees with Customers and Reports.
  with visit_rows as (
    select s.id, s.reversal_of, s.occurred_at
      from public.sales s
     where s.business_id=p_business and s.client_id=v_client.id and s.counts_as_visit
  )
  select count(distinct app.ci_visit_day_v699(v.occurred_at)) into v_visits
    from visit_rows v
   where v.reversal_of is null
     and not exists (select 1 from visit_rows r where r.reversal_of = v.id);
  select * into lp from public.loyalty_programs
   where business_id=p_business and active limit 1;

  return jsonb_build_object(
    'status','found','client_id',v_client.id,'full_name',v_client.full_name,
    'phone',v_client.phone_norm,
    'points',v_points,'credit_cents',v_credit,'visits',v_visits,
    -- nestly_v809 (audit F020): the member-QR and gift-QR paths were the only till entry points
    -- with no stamp_card, so the header printed the POT for a scanned customer and "x of y" for
    -- the same customer typed in by phone. Same object, same authority, all three ways in.
    'stamp_card', app.till_stamp_card_v809(p_business, v_client.id),
    'redeem_points',lp.redeem_points,'reward_credit_cents',lp.reward_credit_cents,
    'can_redeem',(lp.redeem_points is not null and v_points>=lp.redeem_points),
    'points_to_next',greatest(coalesce(lp.redeem_points,0)-v_points,0),
    'member_since',v_client.created_at);
end
$function$;

revoke all on function app.v666_till_customer_card(uuid, uuid) from public, anon, authenticated;

-- =============================================================================================
-- F020 (3/3) — the phone path now asks the same authority. Same object as v474 shipped.
-- =============================================================================================
create or replace function public.lookup_client_by_phone(p_business uuid, p_phone text)
returns json
language plpgsql
stable
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $function$
declare
  v_norm text;
  c public.clients%rowtype;
  lp record;
  v_points integer;
  v_credit integer;
  v_visits integer;
begin
  if not app.has_perm(p_business, 'create_sales')
     or not app.can_module_read(p_business, 'clients') then
    raise exception 'clients read and create-sales authorization is required'
      using errcode = '42501';
  end if;
  v_norm := app.norm_phone(p_phone);
  if v_norm is null then
    return json_build_object('status','invalid',
      'message','Enter the customer''s 8-digit mobile number.');
  end if;
  select * into c from public.clients
   where business_id = p_business and phone_norm = v_norm;
  if not found then
    return json_build_object('status','not_found','phone',v_norm);
  end if;
  v_points := app.client_points_balance_v409(p_business, c.id);
  select coalesce(sum(amount_cents),0) into v_credit
    from public.credit_ledger where business_id=p_business and client_id=c.id;
  -- nestly_v677: net the reversals, so the till agrees with Customers and Reports.
  with visit_rows as (
    select s.id, s.reversal_of, s.occurred_at
      from public.sales s
     where s.business_id=p_business and s.client_id=c.id and s.counts_as_visit
  )
  select count(distinct app.ci_visit_day_v699(v.occurred_at)) into v_visits
    from visit_rows v
   where v.reversal_of is null
     and not exists (select 1 from visit_rows r where r.reversal_of = v.id);
  select * into lp from public.loyalty_programs
   where business_id=p_business and active limit 1;
  return json_build_object(
    'status','found','client_id',c.id,'full_name',c.full_name,'phone',c.phone_norm,
    'points',v_points,'credit_cents',v_credit,'visits',v_visits,
    -- nestly_v809 (audit F020): the v474 subquery that used to sit here now lives in
    -- app.till_stamp_card_v809, which app.v666_till_customer_card calls too. Same object.
    'stamp_card', app.till_stamp_card_v809(p_business, c.id),
    'redeem_points',lp.redeem_points,'reward_credit_cents',lp.reward_credit_cents,
    'can_redeem',(lp.redeem_points is not null and v_points>=lp.redeem_points),
    'points_to_next',greatest(coalesce(lp.redeem_points,0)-v_points,0),
    'member_since',c.created_at);
end
$function$;

/* ACL restated verbatim from production. */
revoke all on function public.lookup_client_by_phone(uuid, text) from public, anon;
grant execute on function public.lookup_client_by_phone(uuid, text) to authenticated, service_role;

-- =============================================================================================
-- F057 — the till can re-read a customer's standing without a phone number.
-- =============================================================================================
create or replace function public.till_customer_standing_v809(p_business uuid, p_client uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $function$
begin
  /* nestly_v809 (audit F057): lookup_client_by_phone's gate, verbatim — this is the same card for
     the same counter, addressed by the id the till already holds instead of by a phone number a
     scanned customer may not have. It reads; it writes nothing. */
  if not app.has_perm(p_business, 'create_sales')
     or not app.can_module_read(p_business, 'clients') then
    raise exception 'clients read and create-sales authorization is required'
      using errcode = '42501';
  end if;
  if p_client is null then
    return jsonb_build_object('status','invalid','message','This customer is not in this business.');
  end if;
  return app.v666_till_customer_card(p_business, p_client);
end
$function$;

/* ACL matches its sibling readers on production ({postgres,authenticated,service_role}). */
revoke all on function public.till_customer_standing_v809(uuid, uuid) from public, anon;
grant execute on function public.till_customer_standing_v809(uuid, uuid) to authenticated, service_role;

comment on function public.till_customer_standing_v809(uuid, uuid) is
  'nestly_v809 re-reads one customer''s till standing by client id, behind lookup_client_by_phone''s create_sales + clients-read gate. Exists because refreshTillCustomerStandingV408 could only re-read by phone, and a customer auto-provisioned by a member-QR scan has no phone_norm — so the till header stayed frozen at the pre-redemption figure after every redeem, gift scan and gift undo on the QR path.';

-- =============================================================================================
-- F105 — an expense note can be cleared, and "unchanged" still means unchanged.
-- =============================================================================================
drop function if exists public.update_expense_v285(uuid, uuid, integer, text, text);

create or replace function public.update_expense_v285(
  p_business uuid,
  p_expense uuid,
  p_amount_cents integer,
  p_category text,
  p_note text,
  p_clear_note boolean default false
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $function$
declare
  v_actor uuid := auth.uid();
  v_category text := nullif(btrim(coalesce(p_category, '')), '');
  v_note text := nullif(btrim(coalesce(p_note, '')), '');
  v_clear boolean := coalesce(p_clear_note, false);
  v_row public.expenses%rowtype;
begin
  if v_actor is null or p_business is null or p_expense is null
     or not app.has_perm(p_business, 'view_finance')
     or not app.can_module(p_business, 'expenses') then
    raise exception 'permission denied' using errcode = '42501';
  end if;
  if p_amount_cents is not null and p_amount_cents not between 1 and 100000000 then
    raise exception 'the amount is not a valid cost' using errcode = '22023';
  end if;
  if v_category is not null and char_length(v_category) not between 2 and 120 then
    raise exception 'a category is between 2 and 120 characters' using errcode = '22023';
  end if;
  if p_note is not null and char_length(p_note) > 500 then
    raise exception 'a note is limited to 500 characters' using errcode = '22023';
  end if;
  /* nestly_v809: writing a note AND asking to clear it is a contradiction, not a precedence
     puzzle. It is refused so a client bug can never silently keep a stale note. */
  if v_clear and v_note is not null then
    raise exception 'write a note or clear it, not both' using errcode = '22023';
  end if;

  select * into v_row
    from public.expenses expense
   where expense.id = p_expense and expense.business_id = p_business
     for update;
  if not found then
    raise exception 'expense not found' using errcode = '22023';
  end if;
  if v_row.voided_at is not null then
    raise exception 'a voided expense cannot be edited' using errcode = '22023';
  end if;

  update public.expenses expense
     set amount_cents = coalesce(p_amount_cents, expense.amount_cents),
         category = coalesce(v_category, expense.category),
         /* nestly_v809 (audit F105): NULL has always meant "unchanged" here, so emptying the Note
            field in "Correct this expense" silently kept the old note under a success toast.
            Clearing needs a word of its own. */
         note = case when v_clear then null else coalesce(v_note, expense.note) end
   where expense.id = p_expense and expense.business_id = p_business
  returning * into v_row;

  insert into public.audit_log (business_id, actor, action, entity, entity_id, detail)
  values (
    p_business, v_actor, 'EXPENSE_UPDATE', 'expenses', p_expense,
    jsonb_build_object('amount_cents', v_row.amount_cents, 'category', v_row.category)
  );

  return to_jsonb(v_row);
end;
$function$;

/* ACL restated verbatim from production, on the new exact overload. */
revoke all on function public.update_expense_v285(uuid, uuid, integer, text, text, boolean) from public, anon;
grant execute on function public.update_expense_v285(uuid, uuid, integer, text, text, boolean) to authenticated, service_role;

comment on function public.update_expense_v285(uuid, uuid, integer, text, text, boolean) is
  'nestly_v285/v809 corrects one expense''s amount, category and note. v809: p_clear_note = true empties the note, because p_note = NULL has always meant "unchanged" and there was therefore no way to clear a note at all. The two are mutually exclusive and passing both is refused.';

-- =============================================================================================
-- Prove the change took, in the same transaction that made it.
-- =============================================================================================
do $verify$
declare
  v_count integer;
  v_def text;
begin
  -- ---------------------------------------------------------------- one authority for the card
  select count(*) into v_count
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'app' and p.proname = 'till_stamp_card_v809';
  if v_count <> 1 then
    raise exception 'nestly_v809: the stamp-card authority is missing (% found)', v_count
      using errcode = 'XX001';
  end if;

  v_def := pg_get_functiondef('app.v666_till_customer_card(uuid,uuid)'::regprocedure);
  if position('''stamp_card'', app.till_stamp_card_v809(p_business, v_client.id)' in v_def) = 0 then
    raise exception 'nestly_v809: the QR customer card still has no stamp card, so the till would print the pot'
      using errcode = 'XX001';
  end if;

  v_def := pg_get_functiondef('public.lookup_client_by_phone(uuid,text)'::regprocedure);
  if position('''stamp_card'', app.till_stamp_card_v809(p_business, c.id)' in v_def) = 0 then
    raise exception 'nestly_v809: the phone path no longer uses the shared stamp-card authority'
      using errcode = 'XX001';
  end if;
  if position('app.has_perm(p_business, ''create_sales'')' in v_def) = 0 then
    raise exception 'nestly_v809: the phone lookup lost its create-sales guard' using errcode = 'XX001';
  end if;

  -- ---------------------------------------------------------------- the client-id standing read
  select count(*) into v_count
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'till_customer_standing_v809';
  if v_count <> 1 then
    raise exception 'nestly_v809: % overloads of the standing reader exist — PostgREST would answer a named-argument call with PGRST203', v_count
      using errcode = 'XX001';
  end if;
  v_def := pg_get_functiondef('public.till_customer_standing_v809(uuid,uuid)'::regprocedure);
  if position('app.has_perm(p_business, ''create_sales'')' in v_def) = 0
     or position('app.can_module_read(p_business, ''clients'')' in v_def) = 0 then
    raise exception 'nestly_v809: the standing reader is not behind the till gate' using errcode = 'XX001';
  end if;

  -- ---------------------------------------------------------------- the expense note
  select count(*) into v_count
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'update_expense_v285';
  if v_count <> 1 then
    raise exception 'nestly_v809: % overloads of update_expense_v285 exist — PostgREST would answer a named-argument call with PGRST203', v_count
      using errcode = 'XX001';
  end if;
  v_def := pg_get_functiondef(
    'public.update_expense_v285(uuid,uuid,integer,text,text,boolean)'::regprocedure);
  if position('p_clear_note boolean DEFAULT false' in v_def) = 0 then
    raise exception 'nestly_v809: the clear flag is not defaulted, so the five-argument call is no longer valid'
      using errcode = 'XX001';
  end if;
  if position('note = case when v_clear then null else coalesce(v_note, expense.note) end' in v_def) = 0 then
    raise exception 'nestly_v809: the expense note still cannot be cleared' using errcode = 'XX001';
  end if;
  if position('write a note or clear it, not both' in v_def) = 0 then
    raise exception 'nestly_v809: writing a note while clearing is no longer refused' using errcode = 'XX001';
  end if;
  if position('app.has_perm(p_business, ''view_finance'')' in v_def) = 0
     or position('app.can_module(p_business, ''expenses'')' in v_def) = 0 then
    raise exception 'nestly_v809: the finance guard on the expense correction was lost' using errcode = 'XX001';
  end if;

  -- ---------------------------------------------------------------- nothing became reachable
  if exists (select 1 from information_schema.routine_privileges
              where routine_schema = 'public'
                and routine_name in ('update_expense_v285','lookup_client_by_phone','till_customer_standing_v809')
                and grantee in ('anon','PUBLIC')) then
    raise exception 'nestly_v809: a till or expense RPC became anonymously reachable' using errcode = 'XX001';
  end if;
  if exists (select 1 from information_schema.routine_privileges
              where routine_schema = 'app'
                and routine_name in ('till_stamp_card_v809','v666_till_customer_card')
                and grantee in ('anon','PUBLIC','authenticated')) then
    raise exception 'nestly_v809: an app-schema card helper became directly reachable from a browser'
      using errcode = 'XX001';
  end if;
  for v_count in
    select 1 from (values ('update_expense_v285'),('lookup_client_by_phone'),('till_customer_standing_v809')) t(name)
     where not exists (select 1 from information_schema.routine_privileges
                        where routine_schema = 'public' and routine_name = t.name
                          and grantee = 'authenticated')
  loop
    raise exception 'nestly_v809: the browser lost execute on one of the till/expense RPCs'
      using errcode = 'XX001';
  end loop;
end
$verify$;

commit;
