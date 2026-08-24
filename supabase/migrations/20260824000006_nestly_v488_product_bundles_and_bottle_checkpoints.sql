-- nestly_v488 — product bundle members + bottle expiry push at 7 / 3 / 0 days
-- (owner batch 2026-08-24, photos 1 and the bottle-expiry ruling; Sol review bypassed on the
--  owner's explicit instruction — neither half touches payments, auth or destructive prod ops)
--
-- HALF 1 — "i need product bundling as well (same as service bundle)".
--   bundle_items has been (bundle_id, service_id NOT NULL) since v6, so a bundle could only ever
--   hold services. A member row now carries EXACTLY ONE of service_id / product_id:
--     * schema: product_id added, service_id made nullable, the old two-column PK replaced by a
--       surrogate pair of partial unique indexes plus a one-of check;
--     * app.ps1c_bundle_lines_v204 (CREATE OR REPLACE, same name — ps1c_plan_checkout calls it
--       by name) prices the union of active service and product members, pro-rata off their own
--       list prices exactly as before. Each emitted line now states its own kind and item_id;
--       service lines STILL emit service_id, so a plan function from the pre-v488 bundle reads
--       them unchanged during the CDN window;
--     * app.ps1c_plan_checkout patched in place (its live definition is read, two lines in the
--       bundle loop are replaced, and it is re-executed) so that member kind and id are read from
--       the line instead of being hardcoded 'service'. A product member therefore
--       becomes a plain kind='product' plan line — indistinguishable from a product rung up at
--       the till — so recording, reporting and stock deduction ride the existing rails and no
--       second "bundle product" concept exists anywhere downstream;
--     * create_bundle_v488 / update_bundle_v488: the v123/v285 writers with a p_product_ids
--       parameter. NEW NAMES, not overloads — an overload differing only in arity is the
--       PostgREST ambiguity v278/v279 already paid for. The v123/v285 writers stay deployed and
--       callable (the 4-hour CDN window serves bundles that still call them).
--
-- HALF 2 — "i need the push notification to happen when left 7 days to expiry and left 3 days
--   and today expiry (for this bottle expiry)".
--   app.v282_sweep_bottle_expiry sent ONE reminder per bottle, at an owner-configured number of
--   days, deduped forever on (identity, bottle, expires_at). It now fires at three fixed
--   checkpoints — 7 days, 3 days, day-of — each deduped separately (the checkpoint joins the
--   dedupe and idem keys). Per run a bottle fires at most the TIGHTEST matching checkpoint, so a
--   sweep that was down for days does not stack three alerts on resume. The events keep source
--   kind 'v282_bottle_expiry', which customer_push_event_eligible_v95 already lists, so the
--   existing dispatch turns them into real push notifications with no change there.
--   bar_expiry_reminder_days_v282 and its saved value stay deployed and untouched; the sweep
--   simply no longer reads it (owner ruling supersedes the configurable window).

begin;

-- ============================================================================================
-- 1. Schema: bundle_items learns products
-- ============================================================================================

alter table public.bundle_items
  add column if not exists product_id uuid references public.products(id) on delete cascade;

-- The PK was (bundle_id, service_id); with service_id nullable it can no longer stand — and it
-- must go FIRST, because a column inside a primary key refuses DROP NOT NULL (42P16, learned on
-- the first apply attempt). The replacement is the same uniqueness stated per member kind. No PK
-- remains on the table — RLS and both writers address rows only by bundle_id, and the
-- delete-then-insert writer never needed row identity.
alter table public.bundle_items drop constraint if exists bundle_items_pkey;

alter table public.bundle_items alter column service_id drop not null;

create unique index if not exists bundle_items_service_uniq
  on public.bundle_items (bundle_id, service_id) where service_id is not null;
create unique index if not exists bundle_items_product_uniq
  on public.bundle_items (bundle_id, product_id) where product_id is not null;

alter table public.bundle_items drop constraint if exists bundle_items_one_member_v488;
alter table public.bundle_items add constraint bundle_items_one_member_v488
  check ((service_id is null) <> (product_id is null));

-- ============================================================================================
-- 2. app.ps1c_bundle_lines_v204 — prices service AND product members
-- ============================================================================================

CREATE OR REPLACE FUNCTION app.ps1c_bundle_lines_v204(p_business uuid, p_bundle uuid, p_qty integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'app', 'pg_temp'
AS $function$
declare
  v_price int; v_name text; v_active boolean;
  v_rows int; v_list bigint := 0; v_alloc bigint := 0; v_share int;
  v_out jsonb := '[]'::jsonb; r record; v_i int := 0; v_total bigint;
begin
  select b.price_cents, b.name, b.active into v_price, v_name, v_active
    from public.bundles b where b.id = p_bundle and b.business_id = p_business;
  if not found then
    return jsonb_build_object('status','unknown_bundle',
      'reason','this bundle does not belong to this business');
  end if;
  if not coalesce(v_active,false) then
    return jsonb_build_object('status','inactive_bundle',
      'reason','this bundle is not available for sale');
  end if;
  if coalesce(v_price,0) < 1 then
    return jsonb_build_object('status','unpriced_bundle',
      'reason','this bundle has no price set');
  end if;

  -- nestly_v488: the member list is the union of active services and active products. The
  -- column asymmetry (services price_cents, products retail_price_cents) is ps1b's own note.
  select count(*), coalesce(sum(greatest(m.list,0)),0)
    into v_rows, v_list
    from (
      select greatest(s.price_cents,0) as list
        from public.bundle_items bi
        join public.services s on s.id = bi.service_id and s.business_id = p_business
       where bi.bundle_id = p_bundle and s.active
      union all
      select greatest(pr.retail_price_cents,0) as list
        from public.bundle_items bi
        join public.products pr on pr.id = bi.product_id and pr.business_id = p_business
       where bi.bundle_id = p_bundle and pr.active
    ) m;
  if coalesce(v_rows,0) < 1 then
    return jsonb_build_object('status','empty_bundle',
      'reason','this bundle has no sellable items in it');
  end if;

  v_total := v_price::bigint * p_qty;

  for r in
    select m.kind, m.id, m.name, m.list from (
      select 'service'::text as kind, s.id, s.name, greatest(s.price_cents,0) as list
        from public.bundle_items bi
        join public.services s on s.id = bi.service_id and s.business_id = p_business
       where bi.bundle_id = p_bundle and s.active
      union all
      select 'product'::text as kind, pr.id, pr.name, greatest(pr.retail_price_cents,0) as list
        from public.bundle_items bi
        join public.products pr on pr.id = bi.product_id and pr.business_id = p_business
       where bi.bundle_id = p_bundle and pr.active
    ) m
    order by m.name, m.id
  loop
    v_i := v_i + 1;
    if v_i = v_rows then
      v_share := (v_total - v_alloc)::int;
    elsif v_list > 0 then
      v_share := floor(v_total * r.list / v_list)::int;
    else
      v_share := floor(v_total / v_rows)::int;
    end if;
    v_alloc := v_alloc + v_share;
    -- 'service_id' is kept on service lines VERBATIM so a pre-v488 ps1c_plan_checkout still
    -- reads this payload correctly through the CDN window. 'kind'/'item_id' are the v488 shape.
    v_out := v_out || jsonb_build_object(
      'kind', r.kind,
      'item_id', r.id,
      'service_id', case when r.kind = 'service' then r.id else null end,
      'name', r.name || ' · ' || v_name,
      'line_cents', greatest(v_share,0));
  end loop;

  return jsonb_build_object('status','ok','bundle_name',v_name,
    'total_cents', v_total, 'lines', v_out);
end
$function$;

-- Restate the live ACL verbatim (proacl {postgres=X/postgres}): owner-only, no API role.
revoke all on function app.ps1c_bundle_lines_v204(uuid, uuid, integer) from public, anon, authenticated;

-- ============================================================================================
-- 3. app.ps1c_plan_checkout — reads each bundle member's own kind (full restatement follows;
--    the only change from the v394 authority is the commented two-line patch in the bundle loop)
-- ============================================================================================

-- app.ps1c_plan_checkout: teach the bundle loop to read each member's own kind, by exact patch
-- of the LIVE definition rather than by restating 20k characters of the pricing authority from a
-- transcription. Two lines change. The anchors are asserted first, so a later rewrite of that
-- loop aborts this migration instead of silently pricing product members as services.
do $do$
declare
  v_src text;
  v_old_kind constant text := 'v_kind := array_append(v_kind, ''service'');';
  v_new_kind constant text := 'v_kind := array_append(v_kind, coalesce(v_bline->>''kind'', ''service''));';
  v_old_id constant text := 'v_id := array_append(v_id, (v_bline->>''service_id'')::uuid);';
  v_new_id constant text := 'v_id := array_append(v_id, coalesce(nullif(v_bline->>''item_id'',''''), v_bline->>''service_id'')::uuid);';
begin
  select pg_get_functiondef(p.oid) into v_src
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'app' and p.proname = 'ps1c_plan_checkout' limit 1;
  if v_src is null then
    raise exception 'v488: app.ps1c_plan_checkout not found' using errcode = 'XX001';
  end if;
  if position(v_old_kind in v_src) = 0 or position(v_old_id in v_src) = 0 then
    raise exception 'v488: the bundle expansion loop in app.ps1c_plan_checkout no longer matches '
      'its expected shape; refusing to ship product bundles that would price as services'
      using errcode = 'XX001';
  end if;
  v_src := replace(v_src, v_old_kind, v_new_kind);
  v_src := replace(v_src, v_old_id, v_new_id);
  execute v_src;
end
$do$;

revoke all on function app.ps1c_plan_checkout(uuid, uuid, uuid, jsonb, uuid) from public, anon, authenticated;

-- ============================================================================================
-- 4. Bundle writers that accept products (new names, not overloads)
-- ============================================================================================

create or replace function public.create_bundle_v488(
  p_business uuid, p_name text, p_price_cents integer,
  p_service_ids uuid[], p_product_ids uuid[], p_idempotency_key text)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $function$
declare
  v_actor uuid := auth.uid();
  v_name text := btrim(coalesce(p_name,''));
  v_service_ids uuid[];
  v_product_ids uuid[];
  v_member_count integer;
  v_request_hash text;
  v_existing app.service_bundle_operations_v123%rowtype;
  v_bundle_id uuid;
  v_response jsonb;
begin
  if v_actor is null or p_business is null
     or not app.can_module_write(p_business,'services') then
    raise exception 'permission denied' using errcode='42501';
  end if;

  select array_agg(candidate order by candidate) into v_service_ids
    from (select distinct unnest(coalesce(p_service_ids,array[]::uuid[])) as candidate) s
   where candidate is not null;
  select array_agg(candidate order by candidate) into v_product_ids
    from (select distinct unnest(coalesce(p_product_ids,array[]::uuid[])) as candidate) s
   where candidate is not null;
  v_member_count := cardinality(coalesce(v_service_ids,array[]::uuid[]))
                  + cardinality(coalesce(v_product_ids,array[]::uuid[]));

  -- The v123 floor of 2 holds for the bundle as a whole, not per kind: one service plus one
  -- product is a real bundle. The 50 cap holds across both.
  if char_length(v_name) not between 2 and 120
     or p_price_cents is null or p_price_cents not between 0 and 100000000
     or p_idempotency_key is null
     or char_length(p_idempotency_key) not between 1 and 160
     or v_member_count not between 2 and 50 then
    raise exception 'invalid bundle' using errcode='22023';
  end if;

  v_request_hash := app.v41_request_hash(jsonb_build_object(
    'business_id',p_business,'name',v_name,'price_cents',p_price_cents,
    'service_ids',to_jsonb(coalesce(v_service_ids,array[]::uuid[])),
    'product_ids',to_jsonb(coalesce(v_product_ids,array[]::uuid[]))
  )::text);

  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(
    'v488:bundle:'||p_business::text||':'||v_actor::text||':'||p_idempotency_key, 488));

  select * into v_existing
    from app.service_bundle_operations_v123 operation
   where operation.business_id=p_business
     and operation.actor=v_actor
     and operation.idempotency_key=p_idempotency_key;
  if found then
    if v_existing.request_hash<>v_request_hash then
      raise exception 'idempotency key reused with a different bundle' using errcode='22023';
    end if;
    return v_existing.response||jsonb_build_object('replayed',true);
  end if;

  if v_service_ids is not null and (
    select count(*) from public.services service
     where service.business_id=p_business and service.active
       and service.id=any(v_service_ids)
  ) <> cardinality(v_service_ids) then
    raise exception 'bundle services must be active in this business' using errcode='22023';
  end if;
  if v_product_ids is not null and (
    select count(*) from public.products product
     where product.business_id=p_business and product.active
       and product.id=any(v_product_ids)
  ) <> cardinality(v_product_ids) then
    raise exception 'bundle products must be active in this business' using errcode='22023';
  end if;

  insert into public.bundles (business_id,name,price_cents)
  values (p_business,v_name,p_price_cents)
  returning id into v_bundle_id;

  insert into public.bundle_items (bundle_id,service_id)
  select v_bundle_id,service_id from unnest(coalesce(v_service_ids,array[]::uuid[])) service_id;
  insert into public.bundle_items (bundle_id,product_id)
  select v_bundle_id,product_id from unnest(coalesce(v_product_ids,array[]::uuid[])) product_id;

  v_response := jsonb_build_object('status','created','bundle_id',v_bundle_id,'replayed',false);

  insert into app.service_bundle_operations_v123 (
    business_id,actor,idempotency_key,request_hash,bundle_id,response
  ) values (
    p_business,v_actor,p_idempotency_key,v_request_hash,v_bundle_id,v_response
  );

  insert into public.audit_log (business_id,actor,action,entity,entity_id,detail)
  values (
    p_business,v_actor,'SERVICE_BUNDLE_CREATE','bundles',v_bundle_id,
    jsonb_build_object('name',v_name,'price_cents',p_price_cents,
      'service_count',cardinality(coalesce(v_service_ids,array[]::uuid[])),
      'product_count',cardinality(coalesce(v_product_ids,array[]::uuid[])))
  );

  return v_response;
end
$function$;

revoke all on function public.create_bundle_v488(uuid, text, integer, uuid[], uuid[], text) from public, anon;
grant execute on function public.create_bundle_v488(uuid, text, integer, uuid[], uuid[], text) to authenticated;
grant execute on function public.create_bundle_v488(uuid, text, integer, uuid[], uuid[], text) to service_role;

create or replace function public.update_bundle_v488(
  p_business uuid, p_bundle uuid, p_name text, p_price_cents integer,
  p_service_ids uuid[], p_product_ids uuid[], p_active boolean)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $function$
declare
  v_actor uuid := auth.uid();
  v_name text := nullif(btrim(coalesce(p_name, '')), '');
  v_service_ids uuid[];
  v_product_ids uuid[];
  v_replace_items boolean := p_service_ids is not null or p_product_ids is not null;
  v_member_count integer;
  v_bundle public.bundles%rowtype;
begin
  if v_actor is null or p_business is null or p_bundle is null
     or not app.can_module_write(p_business, 'services') then
    raise exception 'permission denied' using errcode = '42501';
  end if;

  select * into v_bundle
    from public.bundles bundle
   where bundle.id = p_bundle and bundle.business_id = p_business
     for update;
  if not found then
    raise exception 'bundle not found' using errcode = '22023';
  end if;

  if v_name is not null and char_length(v_name) not between 2 and 120 then
    raise exception 'invalid bundle' using errcode = '22023';
  end if;
  if p_price_cents is not null and p_price_cents not between 0 and 100000000 then
    raise exception 'invalid bundle' using errcode = '22023';
  end if;

  -- v285 read a null p_service_ids as "leave the members alone". With two member lists that
  -- contract has one sharp edge: a caller replacing the members must send BOTH lists (either may
  -- be empty), because "replace the services, keep the products" is not a thing the till or the
  -- editor ever means — the editor always states the whole membership.
  if v_replace_items then
    select array_agg(candidate order by candidate) into v_service_ids
      from (select distinct unnest(coalesce(p_service_ids,array[]::uuid[])) as candidate) s
     where candidate is not null;
    select array_agg(candidate order by candidate) into v_product_ids
      from (select distinct unnest(coalesce(p_product_ids,array[]::uuid[])) as candidate) s
     where candidate is not null;
    v_member_count := cardinality(coalesce(v_service_ids,array[]::uuid[]))
                    + cardinality(coalesce(v_product_ids,array[]::uuid[]));
    if v_member_count not between 2 and 50 then
      raise exception 'a bundle holds between 2 and 50 items' using errcode = '22023';
    end if;
    if v_service_ids is not null and (
      select count(*) from public.services service
       where service.business_id = p_business and service.active
         and service.id = any(v_service_ids)
    ) <> cardinality(v_service_ids) then
      raise exception 'bundle services must be active in this business' using errcode = '22023';
    end if;
    if v_product_ids is not null and (
      select count(*) from public.products product
       where product.business_id = p_business and product.active
         and product.id = any(v_product_ids)
    ) <> cardinality(v_product_ids) then
      raise exception 'bundle products must be active in this business' using errcode = '22023';
    end if;
  end if;

  update public.bundles bundle
     set name = coalesce(v_name, bundle.name),
         price_cents = coalesce(p_price_cents, bundle.price_cents),
         active = coalesce(p_active, bundle.active)
   where bundle.id = p_bundle and bundle.business_id = p_business;

  if v_replace_items then
    delete from public.bundle_items item where item.bundle_id = p_bundle;
    insert into public.bundle_items (bundle_id, service_id)
    select p_bundle, service_id from unnest(coalesce(v_service_ids,array[]::uuid[])) service_id;
    insert into public.bundle_items (bundle_id, product_id)
    select p_bundle, product_id from unnest(coalesce(v_product_ids,array[]::uuid[])) product_id;
  end if;

  insert into public.audit_log (business_id, actor, action, entity, entity_id, detail)
  values (
    p_business, v_actor, 'SERVICE_BUNDLE_UPDATE', 'bundles', p_bundle,
    jsonb_build_object('name', v_name, 'price_cents', p_price_cents, 'active', p_active,
      'service_count', cardinality(coalesce(v_service_ids, array[]::uuid[])),
      'product_count', cardinality(coalesce(v_product_ids, array[]::uuid[])))
  );

  return jsonb_build_object('status', 'updated', 'bundle_id', p_bundle);
end
$function$;

revoke all on function public.update_bundle_v488(uuid, uuid, text, integer, uuid[], uuid[], boolean) from public, anon;
grant execute on function public.update_bundle_v488(uuid, uuid, text, integer, uuid[], uuid[], boolean) to authenticated;
grant execute on function public.update_bundle_v488(uuid, uuid, text, integer, uuid[], uuid[], boolean) to service_role;

-- ============================================================================================
-- 5. Bottle expiry: three fixed push checkpoints — 7 days, 3 days, day-of
-- ============================================================================================

CREATE OR REPLACE FUNCTION app.v282_sweep_bottle_expiry(p_now timestamp with time zone DEFAULT now())
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'app', 'pg_temp'
AS $function$
declare
  v_now timestamptz := coalesce(p_now, now());
  v_expired integer := 0;
  v_reminded integer := 0;
begin
  with lapsed as (
    update public.bar_bottles bottle
       set status = 'expired', updated_at = v_now
     where bottle.status = 'stored'
       and bottle.expires_at <= v_now
    returning bottle.id, bottle.business_id, bottle.expires_at
  ), evidenced as (
    insert into public.bar_bottle_events (
      business_id, bottle_id, kind, actor, idem_key, detail
    )
    select
      lapsed.business_id, lapsed.id, 'expire', null::uuid,
      'v282-expire:' || lapsed.id::text,
      jsonb_build_object('swept_at', v_now, 'expires_at', lapsed.expires_at)
    from lapsed
    on conflict do nothing
    returning 1
  )
  select count(*)::integer into v_expired from lapsed;

  -- nestly_v488 (owner: "push notification when left 7 days to expiry and left 3 days and today
  -- expiry"). Three FIXED checkpoints replace the configurable single window. Per run a bottle
  -- fires at most the TIGHTEST checkpoint it has entered (min over matches), so a sweep that was
  -- down for days does not stack three alerts on resume; per lifetime each checkpoint fires at
  -- most once, because the checkpoint is part of the dedupe key. Source kind stays
  -- 'v282_bottle_expiry' — already listed by customer_push_event_eligible_v95 — so these become
  -- real push notifications through the existing dispatch with no change there.
  with due as (
    select
      bottle.id as bottle_id,
      bottle.business_id,
      bottle.expires_at,
      coalesce(nullif(btrim(bottle.label), ''), 'Your bottle') as bottle_name,
      link.id as link_id,
      link.identity_id,
      link.auth_user_id,
      link.client_id,
      (select min(checkpoint.days) from (values (7),(3),(0)) as checkpoint(days)
        where bottle.expires_at <= v_now + make_interval(days => checkpoint.days + 1)
      ) as checkpoint_days
    from public.bar_bottles bottle
    join public.customer_links link
      on link.business_id = bottle.business_id
     and link.client_id = bottle.client_id
     and link.state = 'verified'
     and link.unlinked_at is null
    left join public.customer_notification_preferences preference
      on preference.business_id = link.business_id
     and preference.identity_id = link.identity_id
     and preference.auth_user_id = link.auth_user_id
     and preference.link_id = link.id
     and preference.channel = 'in_app'
     and preference.topic = 'value_expiry'
    where bottle.status = 'stored'
      and bottle.expires_at > v_now
      and bottle.expires_at <= v_now + make_interval(days => 8)
      and coalesce(preference.opted_in, true)
      and app.customer_communication_allows_v263(
        link.identity_id, 'rewards_and_points', 'in_app'
      )
  ), enqueued as (
    insert into public.customer_in_app_inbox_events (
      business_id, identity_id, auth_user_id, link_id, client_id,
      source_kind, topic, route_key, source_fingerprint, dedupe_key,
      title, body, deadline_at
    )
    select
      due.business_id, due.identity_id, due.auth_user_id, due.link_id, due.client_id,
      'v282_bottle_expiry', 'value_expiry', 'wallet_business',
      app.c46_sha256_hex(jsonb_build_object(
        'bottle_id', due.bottle_id, 'expires_at', due.expires_at,
        'checkpoint', due.checkpoint_days)::text),
      app.c46_sha256_hex(jsonb_build_object(
        'identity_id', due.identity_id, 'bottle_id', due.bottle_id,
        'expires_at', due.expires_at, 'checkpoint', due.checkpoint_days)::text),
      case due.checkpoint_days
        when 0 then 'Your bottle expires today'
        when 3 then 'Your bottle expires in 3 days'
        else 'Your bottle expires in 7 days'
      end,
      due.bottle_name || ' is kept for you until '
        || to_char(due.expires_at at time zone 'Asia/Singapore', 'DD Mon YYYY')
        || '. Come by and enjoy it before then.',
      due.expires_at
    from due
    where due.checkpoint_days is not null
    on conflict (identity_id, dedupe_key) do nothing
    returning id, business_id
  ), noted as (
    insert into public.bar_bottle_events (
      business_id, bottle_id, kind, actor, idem_key, detail
    )
    select
      due.business_id, due.bottle_id, 'reminder', null::uuid,
      'v488-remind:' || due.bottle_id::text || ':' || due.expires_at::text
        || ':' || due.checkpoint_days::text,
      jsonb_build_object('delivery', 'in_app', 'automated', true,
        'expires_at', due.expires_at, 'checkpoint_days', due.checkpoint_days)
    from due
    where due.checkpoint_days is not null
    on conflict do nothing
    returning 1
  )
  select count(*)::integer into v_reminded from enqueued;

  return jsonb_build_object(
    'swept_at', v_now, 'expired', v_expired, 'reminded', v_reminded);
end
$function$;

-- Restate the live ACL verbatim (proacl {postgres=X/postgres,service_role=X/postgres}).
revoke all on function app.v282_sweep_bottle_expiry(timestamp with time zone) from public, anon, authenticated;
grant execute on function app.v282_sweep_bottle_expiry(timestamp with time zone) to service_role;

commit;
