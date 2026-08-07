-- Nestly v215 — welcome offer for first-time sign-ups.
--
-- Owner requirement, verbatim: "i need to enable new sign ups redeemption
-- (criteria set by boss): - example minimum spend $5 (get free xx product) -
-- redeem using qrcode for first time sign ups only. or no minimum spend and
-- free xx product".
--
-- Nothing in the platform issued anything at the moment a customer joined. The
-- join RPCs create the client, the consent row and the audit row, then return.
-- retention_programs cannot express this: it has goal_visits + period_days in
-- absolute calendar windows shared by every customer, with no per-customer
-- lifecycle predicate and no cap on grants per client, so goal_visits=1 would
-- pay out again every period rather than once, ever.
--
-- Shape chosen, and why:
--   * ONE configuration row per business. This is a single owner-set rule
--     ("criteria set by boss"), not a campaign library. A second welcome offer
--     would mean deciding which one a joiner gets — a question the owner did
--     not ask and cannot currently answer in the UI.
--   * The grant is a row per client with UNIQUE (business_id, client_id). That
--     unique index IS the "first time sign ups only" rule: it is enforced by
--     the database, not by a code path that can be reached twice.
--   * The grant snapshots the criteria in force when it was issued. If the
--     owner later raises the minimum spend or swaps the free item, customers
--     already holding the offer keep the deal they were promised.
--   * Redemption records a real $0 sale, exactly as a package session does
--     (use_package_session_v102). That keeps one visit trail and one revenue
--     truth: the free item is a visit worth nothing, never phantom revenue.

begin;

create table if not exists public.business_welcome_offers_v215(
  business_id uuid primary key references public.businesses(id) on delete cascade,
  active boolean not null default false,
  -- 0 = "no minimum spend and free xx product". Anything above it = "minimum
  -- spend $5 (get free xx product)". Both of the owner's two examples.
  min_spend_cents integer not null default 0,
  reward_catalog_kind text not null,
  reward_catalog_id uuid not null,
  reward_label text not null,
  -- null = the offer never lapses. A number = days from joining.
  expiry_days integer,
  version integer not null default 1,
  updated_by uuid,
  updated_at timestamptz not null default now(),
  constraint business_welcome_offers_v215_min_spend_check
    check (min_spend_cents between 0 and 100000000),
  constraint business_welcome_offers_v215_kind_check
    check (reward_catalog_kind in ('service','product')),
  constraint business_welcome_offers_v215_label_check
    check (length(btrim(reward_label)) between 1 and 120),
  constraint business_welcome_offers_v215_expiry_check
    check (expiry_days is null or expiry_days between 1 and 3650)
);

create table if not exists public.welcome_offer_grants_v215(
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  client_id uuid not null references public.clients(id) on delete cascade,
  -- Criteria snapshot, frozen at issue. See the header note.
  min_spend_cents integer not null,
  reward_catalog_kind text not null,
  reward_catalog_id uuid not null,
  reward_label text not null,
  status text not null default 'granted',
  granted_at timestamptz not null default now(),
  expires_at timestamptz,
  redeemed_at timestamptz,
  redeemed_sale_id uuid references public.sales(id) on delete set null,
  redeemed_by uuid,
  qualifying_sale_id uuid references public.sales(id) on delete set null,
  redeem_idempotency_key text,
  constraint welcome_offer_grants_v215_client_uk unique (business_id, client_id),
  constraint welcome_offer_grants_v215_kind_check
    check (reward_catalog_kind in ('service','product')),
  constraint welcome_offer_grants_v215_status_check
    check (status in ('granted','redeemed','expired')),
  constraint welcome_offer_grants_v215_min_spend_check
    check (min_spend_cents >= 0),
  -- A redeemed grant must carry its evidence; an unredeemed one must not
  -- pretend to. This is the row that proves a free item was authorised.
  constraint welcome_offer_grants_v215_redeem_shape
    check (
      (status = 'redeemed' and redeemed_at is not null and redeemed_sale_id is not null)
      or (status <> 'redeemed' and redeemed_at is null and redeemed_sale_id is null)
    )
);

create index if not exists welcome_offer_grants_v215_business_status_idx
  on public.welcome_offer_grants_v215(business_id, status);

alter table public.business_welcome_offers_v215 enable row level security;
alter table public.welcome_offer_grants_v215 enable row level security;

-- Browser-role ACL, stated rather than inherited. A session may READ these rows
-- (subject to the policies below); it may not write them by any route. Every
-- write is a SECURITY DEFINER RPC, so a stolen session cannot mint itself a free
-- item or mark one redeemed. anon has no business here at all.
revoke all on table public.business_welcome_offers_v215 from public, anon, authenticated;
revoke all on table public.welcome_offer_grants_v215 from public, anon, authenticated;
grant select on table public.business_welcome_offers_v215 to authenticated;
grant select on table public.welcome_offer_grants_v215 to authenticated;

-- Read is open to the staff who need it (the till reads a customer's grant, the
-- owner reads the configuration). There is deliberately NO insert/update/delete
-- policy on either table: every write goes through the SECURITY DEFINER RPCs
-- below, so a grant cannot be minted or marked redeemed from the browser.
drop policy if exists business_welcome_offers_v215_read on public.business_welcome_offers_v215;
create policy business_welcome_offers_v215_read on public.business_welcome_offers_v215
for select to authenticated using(
  app.is_super_admin()
  or app.can_module_read(business_id,'loyalty')
  or app.can_module_read(business_id,'till')
  or app.can_module_read(business_id,'sales')
);

drop policy if exists welcome_offer_grants_v215_read on public.welcome_offer_grants_v215;
create policy welcome_offer_grants_v215_read on public.welcome_offer_grants_v215
for select to authenticated using(
  app.is_super_admin()
  or app.can_module_read(business_id,'loyalty')
  or app.can_module_read(business_id,'till')
  or app.can_module_read(business_id,'sales')
);

-- ---------------------------------------------------------------------------
-- Issue. Called from the join paths; never from the browser.
-- ---------------------------------------------------------------------------
create or replace function app.issue_welcome_offer_v215(p_business uuid, p_client uuid)
returns uuid language plpgsql security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_offer public.business_welcome_offers_v215%rowtype;
  v_ok boolean;
  v_grant uuid;
begin
  if p_business is null or p_client is null then return null; end if;

  select * into v_offer
  from public.business_welcome_offers_v215
  where business_id = p_business;
  if not found or not v_offer.active then return null; end if;

  -- The reward must still be a real, active, sellable item. An offer pointing at
  -- a deleted or deactivated item would be issued and then refuse to redeem at
  -- the counter, in front of the customer. Withhold it instead.
  if v_offer.reward_catalog_kind = 'service' then
    select true into v_ok from public.services
    where id = v_offer.reward_catalog_id and business_id = p_business and active;
  else
    select true into v_ok from public.products
    where id = v_offer.reward_catalog_id and business_id = p_business and active;
  end if;
  if not coalesce(v_ok, false) then return null; end if;

  -- "first time sign ups only": a customer who has already transacted with this
  -- business is not a new sign-up, whatever route brought them to the join page.
  -- The UNIQUE (business_id, client_id) below is the second, harder guard.
  if exists(
    select 1 from public.sales
    where business_id = p_business and client_id = p_client and reversal_of is null
  ) then
    return null;
  end if;

  insert into public.welcome_offer_grants_v215(
    business_id, client_id, min_spend_cents,
    reward_catalog_kind, reward_catalog_id, reward_label, expires_at
  ) values (
    p_business, p_client, v_offer.min_spend_cents,
    v_offer.reward_catalog_kind, v_offer.reward_catalog_id, v_offer.reward_label,
    case when v_offer.expiry_days is null then null
         else now() + make_interval(days => v_offer.expiry_days) end
  )
  on conflict (business_id, client_id) do nothing
  returning id into v_grant;

  return v_grant;
end
$$;

revoke all on function app.issue_welcome_offer_v215(uuid,uuid) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Owner configuration.
-- ---------------------------------------------------------------------------
create or replace function public.business_set_welcome_offer_v215(
  p_business uuid,
  p_active boolean,
  p_min_spend_cents integer,
  p_reward_catalog_kind text,
  p_reward_catalog_id uuid,
  p_expiry_days integer default null)
returns jsonb language plpgsql security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_actor uuid := auth.uid();
  v_label text;
  v_row public.business_welcome_offers_v215%rowtype;
begin
  if v_actor is null then
    raise exception 'authenticated staff required' using errcode='42501';
  end if;
  if not (app.is_salon_owner(p_business) or app.can_module_write(p_business,'loyalty')) then
    raise exception 'welcome offer authorization required' using errcode='42501';
  end if;
  if p_reward_catalog_kind is null or p_reward_catalog_kind not in ('service','product') then
    raise exception 'reward_catalog_kind must be service or product' using errcode='22023';
  end if;
  if coalesce(p_min_spend_cents,0) < 0 or coalesce(p_min_spend_cents,0) > 100000000 then
    raise exception 'min_spend_cents out of range' using errcode='22023';
  end if;
  if p_expiry_days is not null and (p_expiry_days < 1 or p_expiry_days > 3650) then
    raise exception 'expiry_days must be between 1 and 3650' using errcode='22023';
  end if;

  -- The label is read from the catalogue, never from the caller: the free item
  -- named on the offer is the item that will actually be handed over.
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

  insert into public.business_welcome_offers_v215 as offer(
    business_id, active, min_spend_cents, reward_catalog_kind,
    reward_catalog_id, reward_label, expiry_days, updated_by, updated_at
  ) values (
    p_business, coalesce(p_active,false), coalesce(p_min_spend_cents,0),
    p_reward_catalog_kind, p_reward_catalog_id, v_label, p_expiry_days, v_actor, now()
  )
  on conflict (business_id) do update set
    active = excluded.active,
    min_spend_cents = excluded.min_spend_cents,
    reward_catalog_kind = excluded.reward_catalog_kind,
    reward_catalog_id = excluded.reward_catalog_id,
    reward_label = excluded.reward_label,
    expiry_days = excluded.expiry_days,
    version = offer.version + 1,
    updated_by = excluded.updated_by,
    updated_at = now()
  returning * into v_row;

  -- audit_log.entity is NOT NULL. Omitting it raises 23502 and rolls the whole save back,
  -- which is exactly how v213's sales-mix toggle silently failed for every business.
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
    'reward_label',v_row.reward_label,'expiry_days',v_row.expiry_days,
    'version',v_row.version);
end
$$;

revoke all on function public.business_set_welcome_offer_v215(uuid,boolean,integer,text,uuid,integer)
  from public, anon;
grant execute on function public.business_set_welcome_offer_v215(uuid,boolean,integer,text,uuid,integer)
  to authenticated;

create or replace function public.business_get_welcome_offer_v215(p_business uuid)
returns jsonb language plpgsql stable security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_row public.business_welcome_offers_v215%rowtype;
  v_granted int; v_redeemed int; v_item_ok boolean;
begin
  if auth.uid() is null then
    raise exception 'authenticated staff required' using errcode='42501';
  end if;
  if not (app.is_salon_owner(p_business)
          or app.can_module_read(p_business,'loyalty')
          or app.can_module_read(p_business,'till')) then
    raise exception 'welcome offer authorization required' using errcode='42501';
  end if;

  select count(*) filter (where status='granted'), count(*) filter (where status='redeemed')
    into v_granted, v_redeemed
  from public.welcome_offer_grants_v215 where business_id = p_business;

  select * into v_row from public.business_welcome_offers_v215 where business_id = p_business;
  if v_row.business_id is null then
    return jsonb_build_object('status','ok','configured',false,'active',false,
      'granted_count',coalesce(v_granted,0),'redeemed_count',coalesce(v_redeemed,0));
  end if;

  if v_row.reward_catalog_kind = 'service' then
    select true into v_item_ok from public.services
    where id = v_row.reward_catalog_id and business_id = p_business and active;
  else
    select true into v_item_ok from public.products
    where id = v_row.reward_catalog_id and business_id = p_business and active;
  end if;

  return jsonb_build_object(
    'status','ok','configured',true,'active',v_row.active,
    'min_spend_cents',v_row.min_spend_cents,
    'reward_catalog_kind',v_row.reward_catalog_kind,
    'reward_catalog_id',v_row.reward_catalog_id,
    'reward_label',v_row.reward_label,'expiry_days',v_row.expiry_days,
    'version',v_row.version,
    -- Surfaced so the owner is told when their own free item has been
    -- deactivated underneath the offer, instead of silently issuing nothing.
    'item_available',coalesce(v_item_ok,false),
    'granted_count',coalesce(v_granted,0),'redeemed_count',coalesce(v_redeemed,0));
end
$$;

revoke all on function public.business_get_welcome_offer_v215(uuid) from public, anon;
grant execute on function public.business_get_welcome_offer_v215(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- Redeem at the counter.
-- ---------------------------------------------------------------------------
create or replace function public.staff_redeem_welcome_offer_v215(
  p_business uuid, p_client uuid, p_branch uuid,
  p_qualifying_sale uuid, p_idempotency_key text)
returns jsonb language plpgsql security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_actor uuid := auth.uid();
  v_staff uuid;
  v_grant public.welcome_offer_grants_v215%rowtype;
  v_sale_id uuid := gen_random_uuid();
  v_spend bigint := 0;
  v_result jsonb;
begin
  p_idempotency_key := btrim(p_idempotency_key);
  if v_actor is null or p_idempotency_key is null or length(p_idempotency_key) < 8 then
    raise exception 'authenticated staff and valid idempotency key required' using errcode='22023';
  end if;
  if not app.has_perm(p_business,'create_sales')
     or not (app.can_module_write(p_business,'till')
             or app.can_module_write(p_business,'sales')) then
    raise exception 'welcome offer redemption authorization required' using errcode='42501';
  end if;

  select staff_row.id into v_staff
  from public.staff staff_row
  where staff_row.business_id = p_business
    and staff_row.user_id = v_actor
    and staff_row.active
    and 'create_sales' = any(app.role_perms(staff_row.role))
  order by case staff_row.role when 'owner' then 0 when 'manager' then 1 else 2 end,
           staff_row.created_at, staff_row.id
  limit 1;
  if v_staff is null then
    raise exception 'active staff authorization required' using errcode='42501';
  end if;

  perform pg_advisory_xact_lock(hashtextextended(
    'v215:welcome-offer:'||p_business::text||':'||p_idempotency_key, 0));

  select * into v_grant
  from public.welcome_offer_grants_v215
  where business_id = p_business and client_id = p_client
  for update;
  if not found then
    raise exception 'welcome_offer_not_found' using errcode='22023';
  end if;

  -- Replay of the same request returns the same receipt rather than a second
  -- free item. A double-tap at a busy counter must not cost the firm twice.
  if v_grant.status = 'redeemed' then
    if v_grant.redeem_idempotency_key is not distinct from p_idempotency_key then
      return jsonb_build_object('status','completed','replayed',true,
        'grant_id',v_grant.id,'sale_id',v_grant.redeemed_sale_id,
        'reward_label',v_grant.reward_label);
    end if;
    raise exception 'welcome_offer_already_redeemed' using errcode='22023';
  end if;
  if v_grant.status <> 'granted' then
    raise exception 'welcome_offer_not_redeemable' using errcode='22023';
  end if;
  if v_grant.expires_at is not null and v_grant.expires_at <= now() then
    update public.welcome_offer_grants_v215 set status='expired' where id = v_grant.id;
    raise exception 'welcome_offer_expired' using errcode='22023';
  end if;

  perform 1 from public.branches branch
  where branch.id = p_branch and branch.business_id = p_business and branch.active
    and app.can_see_branch(p_business, branch.id);
  if not found then
    raise exception 'welcome_offer_branch_not_permitted' using errcode='42501';
  end if;

  -- The minimum spend is proved against a real recorded sale for this customer,
  -- never against a number the till sends. Zero minimum needs no sale at all,
  -- which is the owner's second example ("no minimum spend and free xx product").
  if v_grant.min_spend_cents > 0 then
    if p_qualifying_sale is null then
      raise exception 'welcome_offer_requires_qualifying_sale' using errcode='22023';
    end if;
    select sale.amount_cents into v_spend
    from public.sales sale
    where sale.id = p_qualifying_sale
      and sale.business_id = p_business
      and sale.client_id = p_client
      and sale.reversal_of is null
      and not exists(select 1 from public.sales reversal
                     where reversal.reversal_of = sale.id)
    for share;
    if v_spend is null then
      raise exception 'welcome_offer_qualifying_sale_not_found' using errcode='22023';
    end if;
    if v_spend < v_grant.min_spend_cents then
      raise exception 'welcome_offer_min_spend_not_met' using errcode='22023';
    end if;
  end if;

  -- The free item is a $0 sale, exactly as a package session is: a real visit
  -- worth nothing. It must never look like revenue.
  insert into public.sales(id, business_id, client_id, kind, amount_cents, note, branch_id, staff_id)
  values (v_sale_id, p_business, p_client,
          case when v_grant.reward_catalog_kind = 'service' then 'service' else 'retail' end,
          0, 'welcome offer redeemed: '||v_grant.reward_label, p_branch, v_staff);

  update public.welcome_offer_grants_v215
  set status='redeemed', redeemed_at=now(), redeemed_sale_id=v_sale_id,
      redeemed_by=v_actor, qualifying_sale_id=p_qualifying_sale,
      redeem_idempotency_key=p_idempotency_key
  where id = v_grant.id;

  insert into public.audit_log(business_id, actor, action, entity, entity_id, detail)
  values (p_business, v_actor, 'WELCOME_OFFER_REDEEMED_V215',
          'welcome_offer_grants_v215', v_grant.id, jsonb_build_object(
    'grant_id', v_grant.id, 'client_id', p_client, 'branch_id', p_branch,
    'sale_id', v_sale_id, 'reward_label', v_grant.reward_label,
    'min_spend_cents', v_grant.min_spend_cents,
    'qualifying_sale_id', p_qualifying_sale, 'qualifying_amount_cents', v_spend));

  v_result := jsonb_build_object('status','completed','replayed',false,
    'grant_id',v_grant.id,'sale_id',v_sale_id,'reward_label',v_grant.reward_label,
    'reward_catalog_kind',v_grant.reward_catalog_kind);
  return v_result;
end
$$;

revoke all on function public.staff_redeem_welcome_offer_v215(uuid,uuid,uuid,uuid,text)
  from public, anon;
grant execute on function public.staff_redeem_welcome_offer_v215(uuid,uuid,uuid,uuid,text)
  to authenticated;

-- ---------------------------------------------------------------------------
-- Hooks. Both doors into a business issue the offer; the issuer is idempotent
-- and refuses anyone who has already transacted, so neither can double-issue.
-- Applied to the live definitions by string patch so the deployed functions
-- differ from their reviewed bodies only by these additions.
-- ---------------------------------------------------------------------------
do $hook$
declare d text; n text;
begin
  select pg_get_functiondef(p.oid) into d from pg_proc p join pg_namespace ns on ns.oid=p.pronamespace
  where ns.nspname='public' and p.proname='internal_public_join_v89';
  if position('issue_welcome_offer_v215' in d) = 0 then
    n := replace(d,
'      jsonb_build_object(''consent'',coalesce(p_consent,false)));
  end if;',
'      jsonb_build_object(''consent'',coalesce(p_consent,false)));
    -- v215: v_client is non-null ONLY when this insert actually created a client
    -- row (the on-conflict path returns null), so an existing customer re-entering
    -- their number never mints a second offer.
    perform app.issue_welcome_offer_v215(v_business,v_client);
  end if;');
    if n = d then raise exception 'v215 join hook anchor not found'; end if;
    execute n;
  end if;

  select pg_get_functiondef(p.oid) into d from pg_proc p join pg_namespace ns on ns.oid=p.pronamespace
  where ns.nspname='public' and p.proname='customer_join_business_from_qr_v89_base_v90';
  if position('issue_welcome_offer_v215' in d) = 0 then
    n := replace(d,
'    v_response:=jsonb_build_object(''outcome'',''linked'',''business_id'',
      v_qr.business_id,''link_id'',v_link,''replayed'',false);
    v_event:=''qr_join_linked'';',
'    perform app.issue_welcome_offer_v215(v_qr.business_id,v_client);
    v_response:=jsonb_build_object(''outcome'',''linked'',''business_id'',
      v_qr.business_id,''link_id'',v_link,''replayed'',false);
    v_event:=''qr_join_linked'';');
    if n = d then raise exception 'v215 claim hook anchor not found'; end if;
    execute n;
  end if;

  -- The till reads one entitlements payload for a looked-up customer; the welcome
  -- offer belongs in it beside packages and vouchers. An expired grant is withheld
  -- here rather than offered and then refused in front of the customer.
  select pg_get_functiondef(p.oid) into d from pg_proc p join pg_namespace ns on ns.oid=p.pronamespace
  where ns.nspname='public' and p.proname='staff_get_customer_entitlements_v102';
  if position('welcome_offer_grants_v215' in d) = 0 then
    n := replace(d, E'\ndeclare\n', E'\ndeclare\n  v_welcome jsonb;\n');
    if n = d then raise exception 'v215 entitlements declare anchor not found'; end if;
    d := n;
    n := replace(d,
      'return jsonb_build_object(''packages'',v_packages,''vouchers'',v_vouchers);',
      'select jsonb_build_object('
      ||'''grant_id'',grant_row.id,'
      ||'''reward_label'',grant_row.reward_label,'
      ||'''reward_catalog_kind'',grant_row.reward_catalog_kind,'
      ||'''reward_catalog_id'',grant_row.reward_catalog_id,'
      ||'''min_spend_cents'',grant_row.min_spend_cents,'
      ||'''expires_at'',grant_row.expires_at) into v_welcome '
      ||'from public.welcome_offer_grants_v215 grant_row '
      ||'where grant_row.business_id=p_business and grant_row.client_id=p_client '
      ||'and grant_row.status=''granted'' '
      ||'and (grant_row.expires_at is null or grant_row.expires_at>now()); '
      ||'return jsonb_build_object(''packages'',v_packages,''vouchers'',v_vouchers,''welcome_offer'',v_welcome);');
    if n = d then raise exception 'v215 entitlements return anchor not found'; end if;
    execute n;
  end if;

  -- Prove all three landed rather than trusting the replaces.
  if (select count(*) from pg_proc p join pg_namespace ns on ns.oid=p.pronamespace
      where ns.nspname='public'
        and p.proname in ('internal_public_join_v89','customer_join_business_from_qr_v89_base_v90')
        and position('issue_welcome_offer_v215' in pg_get_functiondef(p.oid)) > 0) <> 2 then
    raise exception 'v215 join hooks did not land on both paths';
  end if;
  if (select count(*) from pg_proc p join pg_namespace ns on ns.oid=p.pronamespace
      where ns.nspname='public' and p.proname='staff_get_customer_entitlements_v102'
        and position('welcome_offer_grants_v215' in pg_get_functiondef(p.oid)) > 0) <> 1 then
    raise exception 'v215 entitlements patch did not land';
  end if;
end $hook$;

commit;
