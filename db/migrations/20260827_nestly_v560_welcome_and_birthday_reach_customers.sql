-- nestly_v560 -- the welcome offer and the birthday treat reach the customers who already exist.
--
-- Two owner reports, 2026-08-27, both the same shape: the BUSINESS page says a programme is on
-- while the CUSTOMER who should benefit sees nothing.
--
-- (1) WELCOME OFFER (owner, photo 1: Jeffrey, "Member since 25 Aug", 0 visits, the 360 reading
--     "Welcome offer -- Kaya Toast Set free once they spend SGD 5.00 -- On", his app empty).
--     app.issue_welcome_offer_v215 runs at JOIN time only, so a customer who signed up BEFORE
--     the owner configured the offer never received a grant -- QA Kopi Lab configured its offer
--     on 2026-08-27 08:50 and has zero grants, because all its customers pre-date it. The
--     customer surfaces need no change at all: the "Given to you" card (min-spend line
--     included), the v515 "Show QR at counter" flow, and the min-spend enforcement at
--     redemption (welcome_offer_requires_qualifying_sale, sale >= floor) all already exist --
--     they just had no row to show. business_set_welcome_offer_v215 now issues the grant to
--     every existing zero-sale client when the offer is saved ACTIVE (the same eligibility the
--     join-time issuer enforces, one client at a time), and the backfill below does the same
--     one-time pass for the businesses whose offers are already live.
--
-- (2) BIRTHDAY TREAT (owner: "birthday treat is also not shown to customers ... it must be
--     shown"). Both birthday readers joined
--         loyalty_program_versions lpv on ... and lpv.active
--     -- the accruing programme's VERSION flag, the very column nestly_v559 identified as a
--     stale draft snapshot (false on KKY demo and every tenant seeded that way). The birthday
--     benefit is its own programme (owner ruling V358: its own tile beside Points/Tiers/Stamps),
--     so hiding it behind the points programme's stale flag was wrong twice over: it blanked
--     birthday for the v559-class tenants, and it would blank it for any firm that runs ONLY a
--     birthday gift. The join is gone from both; birthday_program_versions.active and the
--     loyalty module gate remain the whole entitlement.
--
-- ROLLBACK: db/tests/v560_welcome_and_birthday_reach_customers.sql

begin;

CREATE OR REPLACE FUNCTION app.c45_customer_birthday_benefit_for_context(p_business_id uuid, p_client_id uuid, p_identity_id uuid, p_birth_date date, p_as_of timestamp with time zone)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'app', 'pg_temp'
AS $function$
declare
  v_entitlement public.customer_birthday_entitlements%rowtype;
  v_program public.birthday_program_versions%rowtype;
  v_window record;
  v_opted_in boolean := false;
begin
  -- A current immutable promise wins even if the active programme has since
  -- changed. Its effective state is derived from the half-open validity range.
  select * into v_entitlement
    from public.customer_birthday_entitlements e
   where e.business_id = p_business_id and e.client_id = p_client_id
     and e.identity_id = p_identity_id and e.valid_until > p_as_of
   order by e.valid_until desc, e.activated_at desc
   limit 1;
  if found then
    -- An existing promise remains visible after opt-out until it expires or is
    -- reversed; participation only gates NEW activation.
    return app.c45_safe_birthday_entitlement(v_entitlement, p_as_of);
  end if;
  select coalesce(p.opted_in, false) into v_opted_in
    from (select 1) one
    left join public.customer_birthday_participation p on p.identity_id = p_identity_id;
  select bpv.* into v_program
    from public.businesses b
    -- nestly_v560: the join on loyalty_program_versions.active is GONE. That flag is the
    -- accruing programme's stale draft snapshot (see nestly_v559) and the birthday benefit is
    -- its own programme — an owner who publishes only a birthday gift, or whose version rows
    -- carry active=false, still owes their customers the treat. bpv.active + the loyalty
    -- module gate below are the whole entitlement.
    join public.birthday_program_versions bpv
      on bpv.config_version_id = b.active_config_version_id
     and bpv.business_id = b.id and bpv.active
   where b.id = p_business_id
     and 'loyalty' = any(coalesce(b.enabled_modules, '{}'::text[]))
   order by bpv.sort, bpv.program_id
   limit 1;
  if found then
    select * into v_window
      from app.c45_birthday_window(p_birth_date, v_program.window_days_before,
        v_program.window_days_after, p_as_of, v_program.window_mode);
    if found then
      -- Once the current SG birthday window is known, the matching immutable
      -- promise must be projected even when its end instant has elapsed. This
      -- produces effective `expired` without a write inside a failing action.
      select * into v_entitlement
        from public.customer_birthday_entitlements e
       where e.business_id = p_business_id and e.client_id = p_client_id
         and e.identity_id = p_identity_id and e.birthday_year = v_window.birthday_year
       order by e.activated_at desc
       limit 1;
      if found then return app.c45_safe_birthday_entitlement(v_entitlement, p_as_of); end if;
      if coalesce(v_opted_in, false) then
        return jsonb_build_object(
          'label', v_program.customer_label,
          'description', v_program.customer_description,
          'terms', v_program.customer_terms,
          'kind', v_program.fulfillment_kind,
          'display', case when v_program.fulfillment_kind = 'discount_pct'
            then trim(to_char(v_program.discount_percent, 'FM990D00')) || '% off'
            else v_program.manual_item end,
          'status', 'ready_to_activate',
          'validity', jsonb_build_object('available_from', v_window.valid_from, 'available_until', v_window.valid_until),
          'cta', 'activate'
        );
      end if;
    end if;
  end if;
  -- Outside the current birthday window, retain the most recent immutable
  -- promise as customer history. `c45_safe_birthday_entitlement` derives an
  -- effective expired state from valid_until; no failed redemption writes it.
  select * into v_entitlement
    from public.customer_birthday_entitlements e
   where e.business_id = p_business_id and e.client_id = p_client_id
     and e.identity_id = p_identity_id
   order by e.birthday_year desc, e.valid_until desc, e.activated_at desc
   limit 1;
  if found then return app.c45_safe_birthday_entitlement(v_entitlement, p_as_of); end if;
  return null;
end $function$;

CREATE OR REPLACE FUNCTION public.customer_activate_birthday_benefit(p_business_slug text, p_idempotency_key uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'app', 'pg_temp'
AS $function$
declare
  v_context record; v_as_of timestamptz:=statement_timestamp(); v_program public.birthday_program_versions%rowtype;
  v_window record; v_entitlement public.customer_birthday_entitlements%rowtype;
  v_op public.customer_birthday_activation_operations%rowtype; v_request_hash text;
begin
  select * into v_context from app.c45_customer_birthday_context(p_business_slug) limit 1;
  if p_idempotency_key is null then raise exception 'birthday benefits are unavailable' using errcode='22023'; end if;
  v_request_hash:=app.c45_hash(jsonb_build_object('business_slug',lower(btrim(p_business_slug)))::text);
  select * into v_op from public.customer_birthday_activation_operations
   where identity_id=v_context.identity_id and business_id=v_context.business_id and idempotency_key=p_idempotency_key for share;
  if found then
    if v_op.request_hash is distinct from v_request_hash then raise exception 'birthday activation conflicts with an existing operation' using errcode='40001'; end if;
    select * into v_entitlement from public.customer_birthday_entitlements where id=v_op.entitlement_id;
    return app.c45_safe_birthday_entitlement(v_entitlement,v_as_of);
  end if;
  if not exists(select 1 from public.customer_birthday_participation p where p.identity_id=v_context.identity_id and p.auth_user_id=auth.uid() and p.opted_in) then
    raise exception 'birthday benefits are unavailable' using errcode='42501';
  end if;
  select bpv.* into v_program from public.businesses b
   -- nestly_v560: the loyalty_program_versions.active join is gone (see the context reader).
   join public.birthday_program_versions bpv on bpv.config_version_id=b.active_config_version_id and bpv.business_id=b.id and bpv.active
   where b.id=v_context.business_id and 'loyalty'=any(coalesce(b.enabled_modules,'{}'::text[]))
   order by bpv.sort,bpv.program_id limit 1 for update of bpv;
  if not found then raise exception 'birthday benefits are unavailable' using errcode='42501'; end if;
  -- nestly_v424: the fifth argument. Without it this call is the 4-argument overload, which knows
  -- only about window_days_before/after, and a month-mode programme silently enforced one day.
  select * into v_window from app.c45_birthday_window(v_context.birth_date,v_program.window_days_before,v_program.window_days_after,v_as_of,v_program.window_mode);
  if not found then raise exception 'birthday benefits are unavailable' using errcode='42501'; end if;
  select * into v_entitlement from public.customer_birthday_entitlements
   where business_id=v_context.business_id and client_id=v_context.client_id and birthday_year=v_window.birthday_year for update;
  if found then
    insert into public.customer_birthday_activation_operations(identity_id,business_id,client_id,idempotency_key,request_hash,entitlement_id)
    values(v_context.identity_id,v_context.business_id,v_context.client_id,p_idempotency_key,v_request_hash,v_entitlement.id);
    return app.c45_safe_birthday_entitlement(v_entitlement,v_as_of);
  end if;
  insert into public.customer_birthday_entitlements(
    business_id,client_id,identity_id,config_version_id,birthday_program_version_id,birthday_year,
    status,valid_from,valid_until,benefit_snapshot
  ) values(
    v_context.business_id,v_context.client_id,v_context.identity_id,v_program.config_version_id,v_program.id,v_window.birthday_year,
    'available',v_window.valid_from,v_window.valid_until,app.c45_benefit_snapshot(v_program)
  ) returning * into v_entitlement;
  insert into public.customer_birthday_activation_operations(identity_id,business_id,client_id,idempotency_key,request_hash,entitlement_id)
  values(v_context.identity_id,v_context.business_id,v_context.client_id,p_idempotency_key,v_request_hash,v_entitlement.id);
  insert into public.audit_log(business_id,actor,action,entity,entity_id,detail)
  values(v_context.business_id,auth.uid(),'ACTIVATE_BIRTHDAY_BENEFIT','customer_birthday_entitlements',v_entitlement.id,jsonb_build_object('status','available'));
  return app.c45_safe_birthday_entitlement(v_entitlement,v_as_of);
exception when unique_violation then
  -- The per-customer/year uniqueness is the re-publish and concurrent-activate
  -- backstop. A caller retries through the same idempotency key for the exact
  -- immutable promise; changed inputs fail through the hash check above.
  select * into v_entitlement from public.customer_birthday_entitlements
   where business_id=v_context.business_id and client_id=v_context.client_id and birthday_year=v_window.birthday_year;
  if v_entitlement.id is null then raise; end if;
  insert into public.customer_birthday_activation_operations(identity_id,business_id,client_id,idempotency_key,request_hash,entitlement_id)
  values(v_context.identity_id,v_context.business_id,v_context.client_id,p_idempotency_key,v_request_hash,v_entitlement.id)
  on conflict (identity_id,business_id,idempotency_key) do nothing;
  return app.c45_safe_birthday_entitlement(v_entitlement,v_as_of);
end $function$;

CREATE OR REPLACE FUNCTION public.business_set_welcome_offer_v215(p_business uuid, p_active boolean, p_min_spend_cents integer, p_reward_catalog_kind text, p_reward_catalog_id uuid, p_expiry_days integer DEFAULT NULL::integer, p_custom_label text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'app', 'pg_temp'
AS $function$
declare
  v_actor uuid := auth.uid();
  v_label text;
  v_custom text := nullif(btrim(coalesce(p_custom_label,'')),'');
  v_row public.business_welcome_offers_v215%rowtype;
  v_backfilled integer := 0;
begin
  if v_actor is null then
    raise exception 'authenticated staff required' using errcode='42501';
  end if;
  if not app.is_salon_owner(p_business) then
    raise exception 'welcome offer authorization required' using errcode='42501';
  end if;
  if p_reward_catalog_kind is null or p_reward_catalog_kind not in ('service','product','custom') then
    raise exception 'reward_catalog_kind must be service, product or custom' using errcode='22023';
  end if;
  if coalesce(p_min_spend_cents,0) < 0 or coalesce(p_min_spend_cents,0) > 100000000 then
    raise exception 'min_spend_cents out of range' using errcode='22023';
  end if;
  if p_expiry_days is not null and (p_expiry_days < 1 or p_expiry_days > 3650) then
    raise exception 'expiry_days must be between 1 and 3650' using errcode='22023';
  end if;

  if p_reward_catalog_kind = 'custom' then
    if v_custom is null or char_length(v_custom) > 120 then
      raise exception 'welcome_offer_custom_label_required' using errcode='22023';
    end if;
    v_label := v_custom;
  else
    if p_reward_catalog_kind = 'service' then
      select name into v_label from public.services
      where id = p_reward_catalog_id and business_id = p_business and active;
    else
      select name into v_label from public.products
      where id = p_reward_catalog_id and business_id = p_business and active;
    end if;
    if v_label is null then
      raise exception 'welcome_offer_item_unavailable' using errcode='22023';
    end if;
  end if;

  insert into public.business_welcome_offers_v215 as offer(
    business_id, active, min_spend_cents, reward_catalog_kind,
    reward_catalog_id, custom_label, reward_label, expiry_days, updated_by, updated_at
  ) values (
    p_business, coalesce(p_active,false), coalesce(p_min_spend_cents,0),
    p_reward_catalog_kind, case when p_reward_catalog_kind='custom' then null else p_reward_catalog_id end,
    v_custom, v_label, p_expiry_days, v_actor, now()
  )
  on conflict (business_id) do update set
    active = excluded.active,
    min_spend_cents = excluded.min_spend_cents,
    reward_catalog_kind = excluded.reward_catalog_kind,
    reward_catalog_id = excluded.reward_catalog_id,
    custom_label = excluded.custom_label,
    reward_label = excluded.reward_label,
    expiry_days = excluded.expiry_days,
    version = offer.version + 1,
    updated_by = excluded.updated_by,
    updated_at = now()
  returning * into v_row;

  -- nestly_v560 (owner, photo 1: the customer 360 read "Welcome offer ... On" on a zero-sale
  -- customer while that customer's own app showed nothing). Grants were only ever issued at
  -- JOIN time (app.issue_welcome_offer_v215), so a customer who signed up before the owner
  -- configured the offer never got one — and the promise the business page displayed did not
  -- exist anywhere the customer, the wallet reader or the QR path could see. An ACTIVE save now
  -- issues the grant to every existing client of this business who has never made a
  -- (non-reversed) purchase — the same eligibility issue_welcome_offer_v215 enforces one client
  -- at a time. on conflict do nothing: a client already holding a grant keeps THEIRS, on its
  -- original terms and clock. Deactivating grants nothing and revokes nothing.
  if v_row.active then
    with granted as (
      insert into public.welcome_offer_grants_v215(
        business_id, client_id, min_spend_cents,
        reward_catalog_kind, reward_catalog_id, reward_label, expires_at
      )
      select p_business, c.id, v_row.min_spend_cents,
             v_row.reward_catalog_kind, v_row.reward_catalog_id, v_row.reward_label,
             case when v_row.expiry_days is null then null
                  else now() + make_interval(days => v_row.expiry_days) end
        from public.clients c
       where c.business_id = p_business
         and not exists (
           select 1 from public.sales s
            where s.business_id = p_business and s.client_id = c.id
              and s.reversal_of is null
         )
      on conflict (business_id, client_id) do nothing
      returning 1
    )
    select count(*) into v_backfilled from granted;
    if coalesce(v_backfilled, 0) > 0 then
      insert into public.audit_log(business_id, actor, action, entity, entity_id, detail)
      values (p_business, v_actor, 'WELCOME_OFFER_GRANTED_TO_EXISTING_V560',
              'welcome_offer_grants_v215', p_business, jsonb_build_object(
        'granted_count', v_backfilled, 'reward_label', v_row.reward_label,
        'min_spend_cents', v_row.min_spend_cents));
    end if;
  end if;

  insert into public.audit_log(business_id, actor, action, entity, entity_id, detail)
  values (p_business, v_actor, 'WELCOME_OFFER_SET_V215',
          'business_welcome_offers_v215', p_business, jsonb_build_object(
    'active', v_row.active, 'min_spend_cents', v_row.min_spend_cents,
    'reward_catalog_kind', v_row.reward_catalog_kind,
    'reward_catalog_id', v_row.reward_catalog_id,
    'reward_label', v_row.reward_label, 'expiry_days', v_row.expiry_days,
    'version', v_row.version));

  return jsonb_build_object(
    'status','ok','active',v_row.active,'min_spend_cents',v_row.min_spend_cents,
    'reward_catalog_kind',v_row.reward_catalog_kind,
    'reward_catalog_id',v_row.reward_catalog_id,
    'custom_label',v_row.custom_label,
    'reward_label',v_row.reward_label,'expiry_days',v_row.expiry_days,
    'version',v_row.version);
end
$function$;

-- ACLs restated verbatim from the live proacl of each function (none had anon/public):
revoke all on function app.c45_customer_birthday_benefit_for_context(uuid, uuid, uuid, date, timestamptz) from public, anon, authenticated;
revoke all on function public.customer_activate_birthday_benefit(text, uuid) from public, anon;
grant execute on function public.customer_activate_birthday_benefit(text, uuid) to authenticated, service_role;
revoke all on function public.business_set_welcome_offer_v215(uuid, boolean, integer, text, uuid, integer, text) from public, anon;
grant execute on function public.business_set_welcome_offer_v215(uuid, boolean, integer, text, uuid, integer, text) to authenticated, service_role;

-- ============ BACKFILL: businesses whose welcome offer is ALREADY active ======================
-- The same statement the writer now runs on save, once, for the offers configured before it
-- existed. Grants land with each offer's own terms; clients holding a grant keep theirs.
do $backfill$
declare r record; v_count integer;
begin
  for r in select * from public.business_welcome_offers_v215 offer where offer.active loop
    with granted as (
      insert into public.welcome_offer_grants_v215(
        business_id, client_id, min_spend_cents,
        reward_catalog_kind, reward_catalog_id, reward_label, expires_at
      )
      select r.business_id, c.id, r.min_spend_cents,
             r.reward_catalog_kind, r.reward_catalog_id, r.reward_label,
             case when r.expiry_days is null then null
                  else now() + make_interval(days => r.expiry_days) end
        from public.clients c
       where c.business_id = r.business_id
         and not exists (
           select 1 from public.sales s
            where s.business_id = r.business_id and s.client_id = c.id
              and s.reversal_of is null
         )
      on conflict (business_id, client_id) do nothing
      returning 1
    )
    select count(*) into v_count from granted;
    if coalesce(v_count, 0) > 0 then
      insert into public.audit_log(business_id, actor, action, entity, entity_id, detail)
      values (r.business_id, null, 'WELCOME_OFFER_GRANTED_TO_EXISTING_V560',
              'welcome_offer_grants_v215', r.business_id, jsonb_build_object(
        'granted_count', v_count, 'reward_label', r.reward_label,
        'min_spend_cents', r.min_spend_cents, 'source', 'nestly_v560_backfill'));
    end if;
  end loop;
end
$backfill$;

commit;
