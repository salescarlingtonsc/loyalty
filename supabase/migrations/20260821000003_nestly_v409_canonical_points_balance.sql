-- ============================================================================
-- nestly_v409 — one canonical, programme-aware customer points balance
--
-- Owner, 2026-08-21: the till showed "Diamond · 855 pts" where the customer's own
-- app showed "97 points", for the same person on the same day.
--
-- MEASURED CAUSE. That customer holds two pots: the LIVE points pot (97) and a
-- dormant stamps pot (758) left by a points->stamps->points switch. 97+758 = 855.
-- Nothing is corrupted and nothing was lost -- the pot transfers net to zero and
-- the +758 is a real conversion. The till was adding two pots together and
-- labelling the total "pts".
--
-- WHY IT EXISTED. v312 introduced per-programme pots plus a safety switch,
-- app.programme_balance_scope_v312(business), which answers 'programme_pot' only
-- when every client's ledger pot equals their batch remaining, else 'business_pot'.
-- Readers were migrated to consult it ONE AT A TIME. v381 migrated the customer
-- profile and directory. Nine other live readers were never migrated and still
-- summed every pot. The defect is invisible until a tenant has a second non-empty
-- pot, which only a points<->stamps switch creates -- exactly as the owner suspected.
--
-- THE FIX IS A CONSOLIDATION, NOT NINE PATCHES. app.client_points_balance_v409 is
-- now the single answer to "what is this customer's points balance". It KEEPS the
-- v312 switch rather than bypassing it, so a tenant whose pots are not provably
-- consistent still reads the legacy total instead of a new, differently-wrong one.
--
-- DELIBERATELY NOT TOUCHED -- classified before modifying:
--   * sale-scoped sums (record_cart_sale, record_sale_by_phone's v_points_earned,
--     sell_package_v102's v_points_earned, get_pos_paynow_attempt_v142's
--     v_points_earned): "what this ONE sale earned". Correct as they are.
--   * period aggregates (get_reports_summary, get_dashboard_summary_v155):
--     business-wide totals over a window, not a customer balance.
--   * tier metrics (app.v176_tier_gate_metric, app.v365_client_tier,
--     app.customer_tier_json_v393): these measure LIFETIME EARNED, not a balance,
--     and v176 already carries both a scoped and a legacy branch.
--   * the redemption kernel (app.redeem_reward_core, redeem_points and internals).
--     redeem_reward_core gates on `unscoped_ledger >= cost AND scoped_batches >=
--     cost`; the SCOPED batch check binds, so nobody can overspend. Removing the
--     redundant weaker gate is a kernel change and deserves its own decision.
--   * dead readers with zero call sites (staff_list_customers_v129 / _v154,
--     customer_explore_businesses_v244, customer_list_business_directory_v242).
--   * customer_get_loyalty_details' transaction FEED, which LISTS ledger entries
--     rather than summing them -- scoping a history hides rows, a product decision
--     rather than a bug fix. Only its 'balance' field is migrated.
--
-- Every function below is reproduced from its OWN live definition
-- (pg_get_functiondef) with a single statement replaced, so nothing else about
-- any of them changes, and each ACL is restated from its live proacl.
-- ============================================================================

begin;

create or replace function app.client_points_balance_v409(p_business uuid, p_client uuid)
returns integer
language plpgsql
stable
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $fn$
declare
  v_scope text := app.programme_balance_scope_v312(p_business);
  v_live  uuid := app.live_balance_programme_v381(p_business);
  v_total integer;
begin
  -- The two resolvers are read into locals ON PURPOSE. Inlined into the WHERE
  -- clause they would be re-evaluated per row, and programme_balance_scope_v312
  -- aggregates the whole tenant's ledger and batches -- the v370 finding that slow
  -- RPCs were re-evaluated functions rather than missing indexes.
  select coalesce(sum(l.points),0)::integer into v_total
    from public.points_ledger l
   where l.business_id = p_business
     and l.client_id   = p_client
     and (v_scope <> 'programme_pot'
          or l.programme_id is not distinct from v_live);
  return coalesce(v_total,0);
end
$fn$;

comment on function app.client_points_balance_v409(uuid,uuid) is
  'v409: THE canonical customer points balance. Honours the v312 pot-safety switch and the '
  'v381 live-programme resolver. Every live current-balance reader delegates here; do not '
  'hand-write another sum over points_ledger for a customer balance.';

revoke all privileges on function app.client_points_balance_v409(uuid,uuid)
  from public, anon, authenticated;

-- ---------------------------------------------------------------- lookup_client_by_phone
CREATE OR REPLACE FUNCTION public.lookup_client_by_phone(p_business uuid, p_phone text)
 RETURNS json
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'app', 'pg_temp'
AS $function$
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
  select count(*) into v_visits
    from public.sales where business_id=p_business and client_id=c.id and counts_as_visit;
  select * into lp from public.loyalty_programs
   where business_id=p_business and active limit 1;
  return json_build_object(
    'status','found','client_id',c.id,'full_name',c.full_name,'phone',c.phone_norm,
    'points',v_points,'credit_cents',v_credit,'visits',v_visits,
    'redeem_points',lp.redeem_points,'reward_credit_cents',lp.reward_credit_cents,
    'can_redeem',(lp.redeem_points is not null and v_points>=lp.redeem_points),
    'points_to_next',greatest(coalesce(lp.redeem_points,0)-v_points,0),
    'member_since',c.created_at);
end
$function$;

revoke all privileges on function public.lookup_client_by_phone(uuid, text) from public, anon;
grant execute on function public.lookup_client_by_phone(uuid, text) to service_role;
grant execute on function public.lookup_client_by_phone(uuid, text) to authenticated;

-- ---------------------------------------------------------------- staff_scan_member_qr_v327
CREATE OR REPLACE FUNCTION public.staff_scan_member_qr_v327(p_business uuid, p_member_qr text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'app', 'pg_temp'
AS $function$
declare
  v_token text;
  v_hash text;
  v_identity public.customer_identities%rowtype;
  v_link public.customer_links%rowtype;
  v_client public.clients%rowtype;
  v_actor uuid := auth.uid();
  v_display_name text;
  v_link_id uuid;
  v_created boolean := false;
  v_points integer;
  v_credit integer;
  v_visits integer;
  lp record;
begin
  if not app.has_perm(p_business, 'create_sales')
     or not app.can_module_write(p_business, 'clients') then
    raise exception 'clients write and create-sales authorization is required'
      using errcode='42501';
  end if;

  v_token := btrim(coalesce(p_member_qr,''));
  if v_token like 'nestly:member:%' then
    v_token := substring(v_token from length('nestly:member:')+1);
  end if;
  if v_token !~ '^[0-9a-f]{64}$' then
    return jsonb_build_object('status','invalid','message','This QR is not a Peekaa member code.');
  end if;
  v_hash := app.v89_sha256(v_token);

  perform pg_advisory_xact_lock(hashtextextended('v327:scan:'||p_business::text||':'||v_hash,0));

  select * into v_identity from public.customer_identities
   where qr_token_hash = v_hash for share;
  if not found or v_identity.status <> 'active' then
    return jsonb_build_object('status','invalid','message','This member QR is no longer active.');
  end if;

  select * into v_link from public.customer_links
   where business_id=p_business and identity_id=v_identity.id and state='verified'
   order by created_at desc limit 1
   for update;

  if found then
    select * into v_client from public.clients where id=v_link.client_id and business_id=p_business;
  else
    select coalesce(nullif(btrim(u.raw_user_meta_data->>'full_name'),''), 'Peekaa Member')
      into v_display_name
      from auth.users u where u.id=v_identity.auth_user_id;

    insert into public.clients (business_id, full_name)
    values (p_business, v_display_name)
    returning * into v_client;

    v_link_id := gen_random_uuid();
    perform set_config('app.customer_link_insert_id', v_link_id::text, true);
    insert into public.customer_links (
      id, business_id, identity_id, auth_user_id, client_id, state,
      verification_method, verified_at
    ) values (
      v_link_id, p_business, v_identity.id, v_identity.auth_user_id, v_client.id, 'verified',
      'qr_scan', now()
    )
    returning * into v_link;
    perform set_config('app.customer_link_insert_id', '', true);
    v_created := true;

    insert into public.audit_log(business_id,actor,action,entity,entity_id,detail)
    values(p_business, v_actor, 'AUTO_PROVISION_CLIENT_FROM_MEMBER_QR_V327',
      'clients', v_client.id, jsonb_build_object('identity_id', v_identity.id, 'link_id', v_link.id));
  end if;

  v_points := app.client_points_balance_v409(p_business, v_client.id);
  select coalesce(sum(amount_cents),0) into v_credit
    from public.credit_ledger where business_id=p_business and client_id=v_client.id;
  select count(*) into v_visits
    from public.sales where business_id=p_business and client_id=v_client.id and counts_as_visit;
  select * into lp from public.loyalty_programs
   where business_id=p_business and active limit 1;

  return jsonb_build_object(
    'status','found','client_id',v_client.id,'full_name',v_client.full_name,
    'phone',v_client.phone_norm,
    'points',v_points,'credit_cents',v_credit,'visits',v_visits,
    'redeem_points',lp.redeem_points,'reward_credit_cents',lp.reward_credit_cents,
    'can_redeem',(lp.redeem_points is not null and v_points>=lp.redeem_points),
    'points_to_next',greatest(coalesce(lp.redeem_points,0)-v_points,0),
    'member_since',v_client.created_at,
    'newly_linked',v_created);
end $function$;

revoke all privileges on function public.staff_scan_member_qr_v327(uuid, text) from public, anon;
grant execute on function public.staff_scan_member_qr_v327(uuid, text) to service_role;
grant execute on function public.staff_scan_member_qr_v327(uuid, text) to authenticated;

-- ---------------------------------------------------------------- record_sale_by_phone
CREATE OR REPLACE FUNCTION public.record_sale_by_phone(p_business uuid, p_phone text, p_amount_cents integer, p_kind text, p_note text, p_staff uuid, p_idem text, p_branch uuid, p_method text)
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'app', 'pg_temp'
AS $function$
declare
  v_norm text;
  v_actor_staff uuid;
  v_client public.clients%rowtype;
  v_financial jsonb;
  v_sale_id uuid;
  v_payment_id uuid;
  v_points_earned integer;
  v_points_after integer;
  v_note text;
begin
  if not app.has_perm(p_business,'create_sales')
     or not app.can_module_read(p_business,'clients') then
    raise exception 'clients read and create-sales authorization is required' using errcode='42501';
  end if;
  select staff.id into v_actor_staff from public.staff staff
   where staff.business_id=p_business and staff.user_id=auth.uid() and staff.active limit 1;
  if not found then raise exception 'an active staff identity is required' using errcode='42501'; end if;
  if p_staff is not null and p_staff is distinct from v_actor_staff then
    raise exception 'sale staff attribution must match the authenticated staff identity'
      using errcode='42501';
  end if;
  if p_idem is null or char_length(btrim(p_idem)) not between 8 and 200 then
    raise exception 'an idempotency key of 8 to 200 characters is required' using errcode='22023';
  end if;
  if p_amount_cents is null or p_amount_cents<=0 then
    raise exception 'Enter the amount paid.' using errcode='22023';
  end if;
  if p_kind is distinct from 'quick_sale' then
    raise exception 'Quick earn only accepts quick-sale purchases' using errcode='22023';
  end if;
  if p_branch is null then
    raise exception 'Choose the branch where payment was received' using errcode='22023';
  end if;
  if lower(coalesce(btrim(p_method),'')) not in ('cash','card','paynow','other') then
    raise exception 'Choose Cash, Card, PayNow or Other' using errcode='22023';
  end if;
  if p_note is not null and char_length(p_note)>1000 then
    raise exception 'sale note is too long' using errcode='22023';
  end if;
  v_norm:=app.norm_phone(p_phone);
  if v_norm is null then raise exception 'Enter a valid 8-digit mobile number.' using errcode='22023'; end if;
  select * into v_client from public.clients
   where business_id=p_business and phone_norm=v_norm;
  if not found then raise exception 'No customer with that number. Add them first.' using errcode='22023'; end if;
  v_note:=coalesce(p_note,'till: '||v_norm);
  v_financial:=public.record_quick_sale(
    p_business=>p_business,p_amount_cents=>p_amount_cents,
    p_method=>lower(btrim(p_method)),p_client=>v_client.id,p_staff=>v_actor_staff,
    p_branch=>p_branch,p_note=>v_note,p_idempotency_key=>btrim(p_idem),p_paid=>true
  )::jsonb;
  v_sale_id:=nullif(v_financial #>> '{sale,id}','')::uuid;
  v_payment_id:=nullif(v_financial->>'payment_id','')::uuid;
  if v_sale_id is null or v_payment_id is null then
    raise exception 'Quick earn did not produce exact sale and payment proof' using errcode='XX001';
  end if;
  select coalesce(sum(points),0) into v_points_earned from public.points_ledger
   where business_id=p_business and client_id=v_client.id and sale_id=v_sale_id;
  v_points_after := app.client_points_balance_v409(p_business, v_client.id);
  return json_build_object(
    'status',case when coalesce((v_financial->>'replayed')::boolean,false)
                  then 'duplicate_ignored' else 'ok' end,
    'sale_id',v_sale_id,'payment_id',v_payment_id,'client_id',v_client.id,
    'full_name',v_client.full_name,'amount_cents',p_amount_cents,'kind','quick_sale',
    'branch_id',p_branch,'payment_method',lower(btrim(p_method)),
    'points_earned',case when coalesce((v_financial->>'replayed')::boolean,false)
                         then 0 else v_points_earned end,
    'points',v_points_after
  );
end
$function$;

revoke all privileges on function public.record_sale_by_phone(uuid, text, integer, text, text, uuid, text, uuid, text) from public, anon;
grant execute on function public.record_sale_by_phone(uuid, text, integer, text, text, uuid, text, uuid, text) to service_role;
grant execute on function public.record_sale_by_phone(uuid, text, integer, text, text, uuid, text, uuid, text) to authenticated;

-- ---------------------------------------------------------------- sell_package_v102
CREATE OR REPLACE FUNCTION public.sell_package_v102(p_business uuid, p_client uuid, p_plan uuid, p_branch uuid, p_idempotency_key uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'app', 'pg_temp'
AS $function$
declare
  v_actor uuid := auth.uid();
  v_staff uuid;
  v_plan public.package_plans%rowtype;
  v_service public.services%rowtype;
  v_existing public.sale_intent_operations%rowtype;
  v_client_package_id uuid := gen_random_uuid();
  v_sale_id uuid := gen_random_uuid();
  v_payload jsonb;
  v_hash text;
  v_points_earned bigint;
  v_points_total bigint;
  v_result jsonb;
begin
  if v_actor is null or p_idempotency_key is null then
    raise exception 'authenticated staff and idempotency key required'
      using errcode='42501';
  end if;
  if not app.has_perm(p_business,'create_sales')
     or not (
       app.can_module_write(p_business,'till')
       or app.can_module_write(p_business,'sales')
       or app.can_module_write(p_business,'packages')
     ) then
    raise exception 'package checkout authorization required' using errcode='42501';
  end if;
  select staff_row.id into v_staff
  from public.staff staff_row
  where staff_row.business_id=p_business
    and staff_row.user_id=v_actor
    and staff_row.active
    and 'create_sales'=any(app.role_perms(staff_row.role))
  order by case staff_row.role when 'owner' then 0 when 'manager' then 1 else 2 end,
           staff_row.created_at,staff_row.id
  limit 1
  for update;
  if not found then
    raise exception 'active staff authorization required' using errcode='42501';
  end if;
  if p_client is null or not exists(
    select 1 from public.clients client
    where client.id=p_client and client.business_id=p_business
  ) then
    raise exception 'package_sale_client_invalid' using errcode='22023';
  end if;

  v_payload:=jsonb_build_object(
    'branch_id',p_branch,
    'business_id',p_business,
    'client_id',p_client,
    'plan_id',p_plan
  );
  v_hash:=app.v41_request_hash(v_payload::text);
  perform pg_advisory_xact_lock(hashtextextended(
    'v102:package-sale:'||p_business::text||':'||p_idempotency_key::text,0
  ));

  select * into v_existing
  from public.sale_intent_operations operation
  where operation.business_id=p_business
    and operation.idempotency_key=p_idempotency_key
  for update;
  if found then
    if v_existing.actor is distinct from v_actor
       or v_existing.operation_type<>'package_sale'
       or v_existing.request_hash<>v_hash then
      raise exception 'package sale idempotency key conflict' using errcode='23505';
    end if;
    return v_existing.result;
  end if;

  select * into v_plan
  from public.package_plans plan
  where plan.id=p_plan and plan.business_id=p_business and plan.active
  for share;
  if not found then
    raise exception 'package_plan_not_found_or_inactive' using errcode='22023';
  end if;
  if v_plan.service_id is not null then
    select * into v_service
    from public.services service
    where service.id=v_plan.service_id and service.business_id=p_business;
    if not found then
      raise exception 'package_service_not_found' using errcode='22023';
    end if;
  end if;
  perform 1
  from public.branches branch
  where branch.id=p_branch and branch.business_id=p_business and branch.active
    and app.can_see_branch(p_business,branch.id)
    and (
      v_plan.service_id is null
      or not exists(
        select 1 from public.service_branches any_branch
        where any_branch.business_id=p_business
          and any_branch.service_id=v_plan.service_id
      )
      or exists(
        select 1 from public.service_branches allowed
        where allowed.business_id=p_business
          and allowed.service_id=v_plan.service_id
          and allowed.branch_id=branch.id
      )
    )
  for share;
  if not found then
    raise exception 'package_branch_not_permitted' using errcode='42501';
  end if;

  insert into public.client_packages(
    id,business_id,client_id,plan_id,remaining,
    plan_name_snapshot,plan_version_snapshot,sessions_snapshot,
    price_cents_snapshot,service_id_snapshot,service_name_snapshot,
    service_variant_snapshot,service_duration_min_snapshot,
    list_unit_cents_snapshot,list_value_cents_snapshot
  ) values(
    v_client_package_id,p_business,p_client,v_plan.id,v_plan.sessions,
    v_plan.name,v_plan.version_no,v_plan.sessions,v_plan.price_cents::bigint,
    v_plan.service_id,case when v_plan.service_id is null then null else v_service.name end,
    case when v_plan.service_id is null then null else v_service.variant_label end,
    case when v_plan.service_id is null then null else v_service.duration_min end,
    v_plan.list_unit_cents_snapshot,v_plan.list_value_cents_snapshot
  );
  insert into public.sales(
    id,business_id,client_id,kind,amount_cents,note,branch_id,staff_id
  ) values(
    v_sale_id,p_business,p_client,'package',v_plan.price_cents,
    'package sold: '||v_plan.name,p_branch,v_staff
  );

  select coalesce(sum(ledger.points),0)::bigint into v_points_earned
  from public.points_ledger ledger
  where ledger.business_id=p_business
    and ledger.client_id=p_client
    and ledger.sale_id=v_sale_id;
  v_points_total := app.client_points_balance_v409(p_business, p_client)::bigint;

  v_result:=jsonb_build_object(
    'status','completed',
    'replayed',false,
    'client_package_id',v_client_package_id,
    'sale_id',v_sale_id,
    'plan_id',v_plan.id,
    'plan_version',v_plan.version_no,
    'branch_id',p_branch,
    'price_cents',v_plan.price_cents::bigint,
    'sessions',v_plan.sessions,
    'remaining',v_plan.sessions,
    'points_earned',v_points_earned,
    'points_total',v_points_total
  );
  insert into public.sale_intent_operations(
    business_id,actor,operation_type,idempotency_key,request_hash,
    status,client_id,result
  ) values(
    p_business,v_actor,'package_sale',p_idempotency_key,v_hash,
    'completed',p_client,v_result
  );
  return v_result;
end
$function$;

revoke all privileges on function public.sell_package_v102(uuid, uuid, uuid, uuid, uuid) from public, anon;
grant execute on function public.sell_package_v102(uuid, uuid, uuid, uuid, uuid) to service_role;
grant execute on function public.sell_package_v102(uuid, uuid, uuid, uuid, uuid) to authenticated;

-- ---------------------------------------------------------------- use_package_session_v102
CREATE OR REPLACE FUNCTION public.use_package_session_v102(p_business uuid, p_client_package uuid, p_branch uuid, p_idempotency_key text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'app', 'pg_temp'
AS $function$
declare
  v_actor uuid:=auth.uid();
  v_staff uuid;
  v_package public.client_packages%rowtype;
  v_existing public.package_session_consumptions%rowtype;
  v_consumption_id uuid:=gen_random_uuid();
  v_sale_id uuid:=gen_random_uuid();
  v_payload jsonb;
  v_hash text;
  v_points_total bigint;
  v_result jsonb;
begin
  p_idempotency_key:=btrim(p_idempotency_key);
  if v_actor is null or p_idempotency_key is null
     or length(p_idempotency_key)<8 then
    raise exception 'authenticated staff and valid idempotency key required'
      using errcode='22023';
  end if;
  if not app.has_perm(p_business,'create_sales')
     or not (
       app.can_module_write(p_business,'till')
       or app.can_module_write(p_business,'sales')
       or app.can_module_write(p_business,'packages')
     ) then
    raise exception 'package session authorization required' using errcode='42501';
  end if;
  select staff_row.id into v_staff
  from public.staff staff_row
  where staff_row.business_id=p_business
    and staff_row.user_id=v_actor
    and staff_row.active
    and 'create_sales'=any(app.role_perms(staff_row.role))
  order by case staff_row.role when 'owner' then 0 when 'manager' then 1 else 2 end,
           staff_row.created_at,staff_row.id
  limit 1
  for update;
  if not found then
    raise exception 'active staff authorization required' using errcode='42501';
  end if;

  v_payload:=jsonb_build_object(
    'branch_id',p_branch,
    'business_id',p_business,
    'client_package_id',p_client_package
  );
  v_hash:=md5(v_payload::text);
  perform pg_advisory_xact_lock(hashtextextended(
    'v102:package-session:'||p_business::text||':'||p_idempotency_key,0
  ));
  select * into v_existing
  from public.package_session_consumptions consumption
  where consumption.business_id=p_business
    and consumption.idempotency_key=p_idempotency_key;
  if found then
    if v_existing.actor is distinct from v_actor
       or v_existing.request_hash<>v_hash
       or v_existing.result is null then
      raise exception 'package session idempotency key conflict' using errcode='23505';
    end if;
    return v_existing.result;
  end if;

  select * into v_package
  from public.client_packages customer_package
  where customer_package.id=p_client_package
    and customer_package.business_id=p_business
  for update;
  if not found then
    raise exception 'client_package_not_found' using errcode='22023';
  end if;
  if v_package.status<>'active' or v_package.remaining<=0 then
    raise exception 'package_has_no_sessions' using errcode='22023';
  end if;
  perform 1
  from public.branches branch
  where branch.id=p_branch and branch.business_id=p_business and branch.active
    and app.can_see_branch(p_business,branch.id)
    and (
      v_package.service_id_snapshot is null
      or not exists(
        select 1 from public.service_branches any_branch
        where any_branch.business_id=p_business
          and any_branch.service_id=v_package.service_id_snapshot
      )
      or exists(
        select 1 from public.service_branches allowed
        where allowed.business_id=p_business
          and allowed.service_id=v_package.service_id_snapshot
          and allowed.branch_id=branch.id
      )
    )
  for share;
  if not found then
    raise exception 'package_branch_not_permitted' using errcode='42501';
  end if;

  update public.client_packages
  set remaining=remaining-1,
      status=case when remaining-1=0 then 'used_up' else 'active' end
  where id=v_package.id and business_id=p_business and remaining>0;
  if not found then
    raise exception 'package_session_concurrent_use' using errcode='40001';
  end if;
  insert into public.sales(
    id,business_id,client_id,kind,amount_cents,note,branch_id,staff_id
  ) values(
    v_sale_id,p_business,v_package.client_id,'service',0,
    'package session used: '||v_package.plan_name_snapshot,p_branch,v_staff
  );
  v_points_total := app.client_points_balance_v409(p_business, v_package.client_id)::bigint;
  v_result:=jsonb_build_object(
    'status','completed',
    'replayed',false,
    'consumption_id',v_consumption_id,
    'sale_id',v_sale_id,
    'client_package_id',v_package.id,
    'client_id',v_package.client_id,
    'branch_id',p_branch,
    'remaining_before',v_package.remaining,
    'remaining_after',v_package.remaining-1,
    'points_earned',0,
    'points_total',v_points_total
  );
  insert into public.package_session_consumptions(
    id,business_id,client_package_id,client_id,sale_id,actor,
    idempotency_key,request_payload,request_hash,
    remaining_before,remaining_after,result
  ) values(
    v_consumption_id,p_business,v_package.id,v_package.client_id,v_sale_id,v_actor,
    p_idempotency_key,v_payload,v_hash,
    v_package.remaining,v_package.remaining-1,v_result
  );
  return v_result;
end
$function$;

revoke all privileges on function public.use_package_session_v102(uuid, uuid, uuid, text) from public, anon;
grant execute on function public.use_package_session_v102(uuid, uuid, uuid, text) to service_role;
grant execute on function public.use_package_session_v102(uuid, uuid, uuid, text) to authenticated;

-- ---------------------------------------------------------------- get_pos_paynow_attempt_v142
CREATE OR REPLACE FUNCTION public.get_pos_paynow_attempt_v142(p_attempt uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'app', 'pg_temp'
AS $function$
declare v_attempt public.pos_payment_attempts_v142%rowtype;
        v_eval public.checkout_evaluations%rowtype;
        v_client_name text; v_business_name text; v_branch_name text;
        v_points_earned int := 0; v_points_total int := 0; v_items jsonb := '[]'::jsonb;
begin
  select * into v_attempt from public.pos_payment_attempts_v142 where id=p_attempt;
  if not found or auth.uid() is null or not exists (
    select 1 from public.staff s where s.business_id=v_attempt.business_id
     and s.user_id=auth.uid() and s.active
  ) or not app.can_module_read_at_v94(v_attempt.business_id,v_attempt.branch_id,'clients')
    or not (app.can_module_read_at_v94(v_attempt.business_id,v_attempt.branch_id,'till')
         or app.can_module_read_at_v94(v_attempt.business_id,v_attempt.branch_id,'sales'))
  then raise exception 'payment attempt access denied' using errcode='42501'; end if;
  select * into v_eval from public.checkout_evaluations where id=v_attempt.evaluation_id;
  select full_name into v_client_name from public.clients where id=v_attempt.client_id;
  select name into v_business_name from public.businesses where id=v_attempt.business_id;
  select name into v_branch_name from public.branches where id=v_attempt.branch_id;
  if v_attempt.sale_id is not null then
    select coalesce(sum(points),0)::int into v_points_earned from public.points_ledger
     where business_id=v_attempt.business_id and sale_id=v_attempt.sale_id and entry_type='earn';
    v_points_total := app.client_points_balance_v409(v_attempt.business_id, v_attempt.client_id);
    select coalesce(jsonb_agg(jsonb_build_object('description',description,'qty',qty,
      'line_cents',line_cents,'item_type',item_type) order by created_at,id),'[]'::jsonb)
      into v_items from public.sale_items where business_id=v_attempt.business_id and sale_id=v_attempt.sale_id;
  end if;
  return jsonb_build_object('attempt_id',v_attempt.id,'business_id',v_attempt.business_id,
    'branch_id',v_attempt.branch_id,'amount_cents',v_attempt.amount_cents,'currency',v_attempt.currency,
    'status',case when v_attempt.status in ('prepared','awaiting_payment','processing')
                    and v_attempt.expires_at<=now() then 'expired' else v_attempt.status end,
    'sale_id',v_attempt.sale_id,'payment_reference',v_attempt.payment_reference,
    'provider_refund_id',v_attempt.provider_refund_id,
    'refund_failure_reason',v_attempt.refund_failure_reason,
    'paid_at',v_attempt.paid_at,'expires_at',v_attempt.expires_at,'updated_at',v_attempt.updated_at,
    'customer_name',v_client_name,'business_name',v_business_name,'branch_name',v_branch_name,
    'subtotal_cents',v_eval.subtotal_cents,'discount_total_cents',v_eval.discount_total_cents,
    'gst_cents',v_eval.gst_cents,'server_lines',v_eval.server_lines,'applied_effects',v_eval.applied_effects,
    'points_earned',v_points_earned,'points_total',v_points_total,'items',v_items);
end $function$;

revoke all privileges on function public.get_pos_paynow_attempt_v142(uuid) from public, anon;
grant execute on function public.get_pos_paynow_attempt_v142(uuid) to service_role;
grant execute on function public.get_pos_paynow_attempt_v142(uuid) to authenticated;

-- ---------------------------------------------------------------- customer_create_redemption_intent_v89
CREATE OR REPLACE FUNCTION public.customer_create_redemption_intent_v89(p_business uuid, p_reward uuid, p_idempotency_key uuid, p_redemption_kind text DEFAULT 'catalog_reward'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'app', 'extensions', 'pg_temp'
AS $function$
declare
  v_identity uuid;v_client uuid;v_reward public.loyalty_rewards%rowtype;
  v_program public.loyalty_programs%rowtype;
  v_reward_version public.loyalty_reward_versions%rowtype;
  v_existing public.customer_redemption_intents_v89%rowtype;
  v_token text;v_hash text;v_request_hash text;
  v_quote jsonb;
  v_balance integer;v_batch_balance integer;v_cost_points integer;
  v_kind text:=lower(btrim(coalesce(p_redemption_kind,'')));
  v_intent uuid:=gen_random_uuid();
  v_expires timestamptz:=now()+interval '5 minutes';v_response jsonb;
  v_intent_programme uuid;
  v_intent_programme_kind text;
  v_stamp_filled integer;
  v_stamp_cycle integer;
begin
  if p_idempotency_key is null then
    raise exception 'idempotency key is required' using errcode='22023';
  end if;
  if v_kind not in ('classic_points','catalog_reward') then
    raise exception 'unsupported redemption kind' using errcode='22023';
  end if;
  if (v_kind='classic_points' and p_reward is not null)
     or (v_kind='catalog_reward' and p_reward is null) then
    raise exception 'redemption kind and reward do not match' using errcode='22023';
  end if;
  if not app.platform_feature_enabled('customer_qr_redemption') then
    raise exception 'customer QR redemption is unavailable' using errcode='0A000';
  end if;
  -- v229: this firm uses points for tier membership, not redemption. Refused here, before
  -- identity resolution, so the rule holds for every caller.
  if not exists(select 1 from public.business_programmes spine
             where spine.business_id=p_business and spine.active
               and spine.kind in ('points','stamps')) then
    raise exception 'this business is not running a programme you can redeem from'
      using errcode='0A000';
  end if;
  v_identity:=app.v31_current_identity();
  v_request_hash:=app.v89_sha256(p_business::text||':'||v_kind||':'||
    coalesce(p_reward::text,'classic'));
  perform pg_advisory_xact_lock(hashtextextended(
    'v89:redemption-intent:'||v_identity::text||':'||p_idempotency_key::text,0));
  select * into v_existing from public.customer_redemption_intents_v89 intent
  where intent.identity_id=v_identity and intent.idempotency_key=p_idempotency_key
  for update;
  if found then
    if v_existing.request_hash<>v_request_hash then
      raise exception 'idempotency key conflicts with another redemption intent'
        using errcode='23505';
    end if;
    return jsonb_build_object('intent_id',v_existing.id,'status',v_existing.status,
      'redemption_kind',v_existing.redemption_kind,
      'qr_token',app.v89_redemption_token(v_identity,p_business,
        v_existing.redemption_kind,v_existing.reward_id,p_idempotency_key),
      'expires_at',v_existing.expires_at,'replayed',true);
  end if;
  if not coalesce((select capability.redemption_enabled
    from public.business_customer_capabilities_v89 capability
    where capability.business_id=p_business),false)
     or not app.v89_business_module_enabled(p_business,'loyalty') then
    raise exception 'customer redemption is disabled for this business'
      using errcode='42501';
  end if;
  select link.client_id into v_client from public.customer_links link
  where link.identity_id=v_identity and link.auth_user_id=auth.uid()
    and link.business_id=p_business and link.state='verified' for share;
  if not found then raise exception 'verified customer link required' using errcode='42501';end if;
  select * into v_program from public.loyalty_programs program
  where program.business_id=p_business and program.active order by program.id limit 1;
  if not found then raise exception 'loyalty redemption is unavailable' using errcode='22023';end if;
  if v_kind='classic_points' then
    if v_program.kind<>'points' or v_program.loyalty_model<>'classic'
       or v_program.redeem_points<=0 or v_program.reward_credit_cents<=0 then
      raise exception 'classic points redemption is unavailable' using errcode='22023';
    end if;
    v_cost_points:=v_program.redeem_points;
    v_quote:=jsonb_build_object(
      'program_id',v_program.id,
      'config_version_id',v_program.current_config_version_id,
      'loyalty_model',v_program.loyalty_model,'kind',v_program.kind,
      'points_spent',v_program.redeem_points,
      'credit_cents',v_program.reward_credit_cents);
  else
    if not exists(select 1 from public.business_programmes spine
                   where spine.business_id=p_business and spine.active
                     and spine.kind in ('points','stamps')) then
      raise exception 'catalog redemption is unavailable' using errcode='22023';
    end if;
    select * into v_reward from public.loyalty_rewards reward
    where reward.id=p_reward and reward.business_id=p_business and reward.active and not reward.paused;
    if not found then
      raise exception 'reward is unavailable' using errcode='22023';
    end if;
    select reward_version.* into v_reward_version
    from public.loyalty_reward_versions reward_version
    join public.businesses business on business.id=reward_version.business_id
    where reward_version.reward_id=p_reward
      and reward_version.business_id=p_business
      and reward_version.config_version_id=business.active_config_version_id
      and reward_version.active;
    if not found
       or (v_reward_version.claim_available_from is not null
         and v_reward_version.claim_available_from>now())
       or (v_reward_version.claim_available_until is not null
         and v_reward_version.claim_available_until<=now()) then
      raise exception 'reward is unavailable' using errcode='22023';
    end if;
    if exists(select 1 from public.loyalty_reward_branches restriction
         where restriction.reward_version_id=v_reward_version.id)
       or exists(select 1 from public.loyalty_reward_services restriction
         where restriction.reward_version_id=v_reward_version.id)
       or exists(select 1 from public.loyalty_reward_products restriction
         where restriction.reward_version_id=v_reward_version.id) then
      raise exception 'context-restricted rewards require staff-assisted redemption'
        using errcode='22023';
    end if;
    if v_reward_version.usage_limit is not null and (
      select count(*) from public.loyalty_redemptions redemption
      where redemption.business_id=p_business
        and redemption.client_id=v_client and redemption.reward_id=p_reward
    )>=v_reward_version.usage_limit then
      raise exception 'reward usage limit reached' using errcode='23514';
    end if;
    v_cost_points:=v_reward_version.cost_points;
    v_quote:=jsonb_build_object(
      'program_id',v_program.id,
      'config_version_id',v_reward_version.config_version_id,
      'reward_version_id',v_reward_version.id,'reward_id',p_reward,
      'points_spent',v_reward_version.cost_points,
      'credit_cents',v_reward_version.credit_cents,
      'fulfillment_kind',v_reward_version.fulfillment_kind,
      'claim_available_from',v_reward_version.claim_available_from,
      'claim_available_until',v_reward_version.claim_available_until,
      'usage_limit',v_reward_version.usage_limit,
      'active',v_reward_version.active);
  end if;
  v_intent_programme:=case when v_kind='catalog_reward' then v_reward_version.programme_id
    else (select spine.id from public.business_programmes spine
           where spine.business_id=p_business and spine.kind='points') end;
  if v_intent_programme is null then
    raise exception 'redemption programme is not resolvable for this business' using errcode='XX001';
  end if;
  if not exists(select 1 from public.business_programmes spine
                 where spine.id=v_intent_programme and spine.active) then
    raise exception 'this reward''s programme is not running right now' using errcode='0A000';
  end if;
  select spine.kind into v_intent_programme_kind from public.business_programmes spine
   where spine.id=v_intent_programme;
  if v_intent_programme_kind='stamps' then
    select sp.filled,sp.cycle_index into v_stamp_filled,v_stamp_cycle
      from app.stamp_progress_v323(p_business,v_client) sp;
    if not found then
      raise exception 'this business is not running a stamp card' using errcode='23514';
    end if;
    if coalesce(v_stamp_filled,0)<v_cost_points then
      raise exception 'not enough stamps yet' using errcode='23514';
    end if;
    if exists(select 1 from public.stamp_milestone_claims claim
               where claim.business_id=p_business and claim.client_id=v_client
                 and claim.programme_id=v_intent_programme
                 and claim.cycle_index=v_stamp_cycle
                 and (claim.slot_position=v_cost_points or claim.reward_id=p_reward)) then
      raise exception 'this stamp gift has already been claimed on this card' using errcode='23514';
    end if;
  else
  v_balance := app.client_points_balance_v409(p_business, v_client);
  select coalesce(sum(remaining),0)::integer into v_batch_balance
    from public.points_batches
    where business_id=p_business and client_id=v_client and remaining>0
      and programme_id=v_intent_programme;
  if least(v_balance,v_batch_balance)<v_cost_points then
    raise exception 'insufficient points' using errcode='23514';
  end if;
  end if;
  v_token:=app.v89_redemption_token(
    v_identity,p_business,v_kind,p_reward,p_idempotency_key);
  v_hash:=app.v89_sha256(v_token);
  insert into public.customer_redemption_intents_v89(
    id,business_id,identity_id,auth_user_id,client_id,redemption_kind,reward_id,
    quoted_program_id,quoted_config_version_id,quoted_reward_version_id,
    quoted_points_spent,quoted_credit_cents,quoted_terms,
    token_hash,idempotency_key,request_hash,expires_at
  ) values(
    v_intent,p_business,v_identity,auth.uid(),v_client,v_kind,p_reward,
    v_program.id,
    case when v_kind='catalog_reward' then v_reward_version.config_version_id
      else v_program.current_config_version_id end,
    case when v_kind='catalog_reward' then v_reward_version.id else null end,
    v_cost_points,
    case when v_kind='catalog_reward' then v_reward_version.credit_cents
      else v_program.reward_credit_cents end,
    v_quote,
    v_hash,p_idempotency_key,v_request_hash,v_expires
  );
  insert into public.customer_redemption_events_v89(
    intent_id,business_id,actor,event_type,idempotency_key,detail
  ) values(
    v_intent,p_business,auth.uid(),'intent_created',p_idempotency_key,
    jsonb_build_object('redemption_kind',v_kind,'reward_id',p_reward,
      'expires_at',v_expires)
  );
  v_response:=jsonb_build_object('intent_id',v_intent,'status','pending',
    'redemption_kind',v_kind,'qr_token',v_token,'expires_at',v_expires,
    'replayed',false);
  return v_response;
end
$function$;

revoke all privileges on function public.customer_create_redemption_intent_v89(uuid, uuid, uuid, text) from public, anon;
grant execute on function public.customer_create_redemption_intent_v89(uuid, uuid, uuid, text) to service_role;
grant execute on function public.customer_create_redemption_intent_v89(uuid, uuid, uuid, text) to authenticated;

-- ---------------------------------------------------------------- customer_get_loyalty_details
CREATE OR REPLACE FUNCTION public.customer_get_loyalty_details(p_business_slug text, p_cursor jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'app', 'pg_temp'
AS $function$
declare
  v_context record;
  v_program public.loyalty_programs%rowtype;
  v_cursor jsonb:=coalesce(p_cursor,'{}'::jsonb);
  v_limit integer:=20;
  v_before_at timestamptz;
  v_before_id uuid;
  v_result jsonb;
begin
  if auth.uid() is null then
    raise exception 'authenticated customer session required'
      using errcode='28000';
  end if;
  if pg_catalog.jsonb_typeof(v_cursor)<>'object'
     or exists(
       select 1
       from pg_catalog.jsonb_object_keys(v_cursor) as keys(key)
       where keys.key not in ('limit','before_at','before_id')
     ) then
    raise exception 'invalid loyalty activity cursor' using errcode='22023';
  end if;
  begin
    v_limit:=least(
      greatest(coalesce((v_cursor->>'limit')::integer,20),1),50
    );
    v_before_at:=nullif(v_cursor->>'before_at','')::timestamptz;
    v_before_id:=nullif(v_cursor->>'before_id','')::uuid;
  exception when others then
    raise exception 'invalid loyalty activity cursor' using errcode='22023';
  end;
  if (v_before_at is null)<>(v_before_id is null) then
    raise exception 'loyalty activity cursor is incomplete'
      using errcode='22023';
  end if;

  select * into v_context
  from app.v32_customer_wallet_context(p_business_slug)
  limit 1;
  if not found then
    raise exception 'verified customer link required' using errcode='42501';
  end if;
  if not ('loyalty'=any(v_context.enabled_modules)) then
    raise exception 'loyalty module is unavailable for this business'
      using errcode='42501';
  end if;
  select * into v_program
  from public.loyalty_programs program
  where program.business_id=v_context.business_id
    and program.active
  limit 1;
  if not found then
    raise exception 'loyalty module is unavailable for this business'
      using errcode='42501';
  end if;

  with activity as (
    select
      ledger.id,
      ledger.created_at as event_at,
      ledger.entry_type as event_type,
      ledger.points::integer as points_delta,
      case ledger.entry_type
        when 'earn' then 'Points earned'
        when 'expire' then 'Points expired'
        when 'adjust' then 'Balance adjustment'
        else 'Loyalty activity'
      end as title,
      null::text as detail,
      null::text as status,
      null::timestamptz as entitlement_expires_at,
      false as is_campaign_entitlement,
      null::text as entitlement_status,
      null::text as fulfillment_status,
      null::text as redemption_mode,
      null::boolean as economic_value_posted,
      null::text as fulfillment_kind,
      null::text as reward_label,
      false as reward_value_hidden,
      null::text as display_label,
      null::bigint as display_amount_cents
    from public.points_ledger ledger
    where ledger.business_id=v_context.business_id
      and ledger.client_id=v_context.client_id
      and ledger.entry_type in ('earn','expire','adjust')
    union all
    select
      redemption.id,
      redemption.redeemed_at,
      'reward_claimed',
      -redemption.points_spent,
      redemption.reward_name,
      null::text,
      case when reversal.id is null then 'claimed' else 'reversed' end,
      redemption.entitlement_expires_at,
      false,null::text,null::text,null::text,null::boolean,
      null::text,redemption.reward_name,false,redemption.reward_name,
      null::bigint
    from public.loyalty_redemptions redemption
    left join public.loyalty_redemption_reversals reversal
      on reversal.business_id=redemption.business_id
     and reversal.redemption_id=redemption.id
    where redemption.business_id=v_context.business_id
      and redemption.client_id=v_context.client_id
    union all
    select
      reward.id,
      reward.granted_at,
      case when reward.campaign_id is not null
        then 'campaign_offer_entitlement'
        else 'retention_reward'
      end,
      0,
      case when reward.campaign_id is not null
        then 'Offer awaiting merchant fulfilment'
        else coalesce(
          nullif(btrim(reward.reward_label),''),'Reward earned'
        )
      end,
      case when reward.campaign_id is not null
        then 'No wallet value has been posted. Ask the business to fulfil this offer.'
        else null::text
      end,
      case
        when reward.campaign_id is not null and reward.status='expired'
          then 'expired_unfulfilled'
        when reward.campaign_id is not null
          then 'merchant_fulfilment_pending'
        else reward.status
      end,
      null::timestamptz,
      reward.campaign_id is not null,
      reward.status,
      case
        when reward.campaign_id is not null and reward.status='expired'
          then 'expired_unfulfilled'
        when reward.campaign_id is not null
          then 'merchant_fulfilment_pending'
        else reward.status
      end,
      case when reward.campaign_id is not null
        then 'merchant_fulfilment_pending'
        else null::text
      end,
      case when reward.campaign_id is not null then false else null::boolean end,
      reward.fulfillment_kind,
      reward.reward_label,
      reward.campaign_id is not null,
      case when reward.campaign_id is not null
        then 'Offer awaiting merchant fulfilment'
        else coalesce(nullif(btrim(reward.reward_label),''),'Reward')
      end,
      case
        when reward.campaign_id is null
         and reward.fulfillment_kind='credit'
          then reward.reward_value::bigint
        else null::bigint
      end
    from public.reward_grants reward
    where reward.business_id=v_context.business_id
      and reward.client_id=v_context.client_id
  ), eligible as (
    select *
    from activity
    where v_before_at is null
       or (event_at,id)<(v_before_at,v_before_id)
    order by event_at desc,id desc
    limit v_limit+1
  ), visible as (
    select * from eligible order by event_at desc,id desc limit v_limit
  )
  select pg_catalog.jsonb_build_object(
    'model',v_program.loyalty_model,
    'unit',case when v_program.loyalty_model='stamps'
      then 'stamps' else 'points' end,
    'programme',pg_catalog.jsonb_build_object(
      'kind',case when v_program.loyalty_model='stamps' then 'stamps' else 'points' end,
      'active',coalesce((
        select spine.active from public.business_programmes spine
         where spine.business_id=v_context.business_id
           and spine.kind=case when v_program.loyalty_model='stamps'
                               then 'stamps' else 'points' end),false),
      'balance_scope',app.programme_balance_scope_v312(v_context.business_id)),
    'balance',app.client_points_balance_v409(v_context.business_id,v_context.client_id),
    'expiry',pg_catalog.jsonb_build_object(
      'expiring_next_30_days',coalesce((
        select sum(batch.remaining)::integer
        from public.points_batches batch
        where batch.business_id=v_context.business_id
          and batch.client_id=v_context.client_id
          and batch.remaining>0
          and batch.expires_at>now()
          and batch.expires_at<=now()+interval '30 days'
      ),0),
      'next_expiry_at',(
        select min(batch.expires_at)
        from public.points_batches batch
        where batch.business_id=v_context.business_id
          and batch.client_id=v_context.client_id
          and batch.remaining>0
          and batch.expires_at>now()
      )
    ),
    'items',coalesce((
      select pg_catalog.jsonb_agg(
        pg_catalog.jsonb_build_object(
          'event_at',event_at,
          'event_type',event_type,
          'points_delta',points_delta,
          'title',title,
          'detail',detail,
          'status',status,
          'entitlement_expires_at',entitlement_expires_at,
          'is_campaign_entitlement',is_campaign_entitlement,
          'entitlement_status',entitlement_status,
          'fulfillment_status',fulfillment_status,
          'redemption_mode',redemption_mode,
          'economic_value_posted',economic_value_posted,
          'fulfillment_kind',fulfillment_kind,
          'reward_label',reward_label,
          'reward_value_hidden',reward_value_hidden,
          'display_label',display_label,
          'display_amount_cents',display_amount_cents
        )
        order by event_at desc,id desc
      )
      from visible
    ),'[]'::jsonb),
    'next_cursor',case
      when (select count(*) from eligible)>v_limit then (
        select pg_catalog.jsonb_build_object(
          'before_at',event_at,'before_id',id,'limit',v_limit
        )
        from visible order by event_at,id limit 1
      )
      else null
    end
  ) into v_result;
  return v_result;
end
$function$;

revoke all privileges on function public.customer_get_loyalty_details(text, jsonb) from public, anon;
grant execute on function public.customer_get_loyalty_details(text, jsonb) to authenticated;

-- ---------------------------------------------------------------- customer_list_programmes_v89
CREATE OR REPLACE FUNCTION public.customer_list_programmes_v89()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'app', 'pg_temp'
AS $function$
declare v_identity uuid;v_result jsonb;
begin
  v_identity:=app.v31_current_identity();
  select jsonb_build_object(
    'programmes',coalesce(jsonb_agg(jsonb_build_object(
      'business',jsonb_build_object(
        'id',row_data.business_id,'slug',row_data.slug,'name',row_data.name,
        'industry',row_data.industry,'currency',row_data.currency),
      'capabilities',jsonb_build_object(
        'booking_enabled',row_data.booking_enabled,
        'redemption_enabled',row_data.redemption_enabled,
        'appointment_changes_enabled',row_data.appointment_changes_enabled),
      'loyalty',jsonb_build_object(
        'balance',row_data.points_balance,'unit',row_data.unit),
      'upcoming_appointments',jsonb_build_object('count',row_data.upcoming_count)
    ) order by lower(row_data.name),row_data.business_id),'[]'::jsonb),
    'truncated',false
  ) into v_result
  from (
    select business.id business_id,business.slug,business.name,business.industry,
      business.currency,
      coalesce(capability.booking_enabled,false)
      and app.v89_business_module_enabled(business.id,'bookings') and exists(
        select 1 from public.services service
        where service.business_id=business.id and service.active
          and service.show_on_booking_page
      ) booking_enabled,
      coalesce(capability.redemption_enabled,false)
        and app.v89_business_module_enabled(business.id,'loyalty')
        and program.id is not null redemption_enabled,
      coalesce(capability.appointment_changes_enabled,false)
        and app.v89_business_module_enabled(business.id,'appointments')
        appointment_changes_enabled,
      app.client_points_balance_v409(link.business_id,link.client_id) points_balance,
      case when program.loyalty_model='stamps' then 'stamps' else 'points' end unit,
      (select count(*)::integer from public.appointments appointment
        where appointment.business_id=link.business_id
          and appointment.client_id=link.client_id
          and appointment.status='booked' and appointment.starts_at>=now()) upcoming_count
    from public.customer_links link
    join public.customer_identities identity
      on identity.id=link.identity_id and identity.auth_user_id=link.auth_user_id
    join public.businesses business on business.id=link.business_id
    left join public.business_customer_capabilities_v89 capability
      on capability.business_id=business.id
    left join lateral(
      select programme.id,programme.loyalty_model
      from public.loyalty_programs programme
      where programme.business_id=business.id and programme.active
      order by (programme.current_config_version_id is not null) desc,
        programme.id
      limit 1
    ) program on true
    where link.identity_id=v_identity and link.auth_user_id=auth.uid()
      and link.state='verified' and identity.status='active'
  ) row_data;
  return v_result;
end
$function$;

revoke all privileges on function public.customer_list_programmes_v89() from public, anon;
grant execute on function public.customer_list_programmes_v89() to service_role;
grant execute on function public.customer_list_programmes_v89() to authenticated;

commit;
