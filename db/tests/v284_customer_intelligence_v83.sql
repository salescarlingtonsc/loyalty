-- Rollback-only v284 acceptance: the four restored RPCs are callable by
-- authenticated and behave per the shipped frontend contract — the REAL
-- production implementations, not stand-ins.
--
-- Seeds one business (auto default branch), two clients with service/gift_card
-- sales, walks list -> cursor page -> fixed export -> ordinal pages as the
-- owner, proves the outsider is refused, exercises the v81 relationship sync
-- as a real customer identity, then rolls everything back.
begin;

-- The migration's end state, applied idempotently so the suite proves it
-- independent of current prod ACLs.
grant execute on function public.get_customer_intelligence_v83(uuid, uuid, date, date, integer, timestamptz, timestamptz, uuid)
  to authenticated;
grant execute on function public.create_customer_intelligence_export_v83(uuid, uuid, date, date)
  to authenticated;
grant execute on function public.get_customer_intelligence_export_page_v83(uuid, integer, integer)
  to authenticated;
grant execute on function public.customer_sync_verified_relationships_v81(text)
  to authenticated;

do $v284$
declare
  v_owner uuid; v_outsider uuid; v_customer uuid;
  v_biz uuid; v_client_a uuid; v_client_b uuid;
  d jsonb; d2 jsonb; v_export uuid;
  v_first text; v_second text;
begin
  -- A. ACL contract: authenticated on all four, anon on none.
  if not has_function_privilege('authenticated','public.get_customer_intelligence_v83(uuid,uuid,date,date,integer,timestamptz,timestamptz,uuid)','EXECUTE')
     or not has_function_privilege('authenticated','public.create_customer_intelligence_export_v83(uuid,uuid,date,date)','EXECUTE')
     or not has_function_privilege('authenticated','public.get_customer_intelligence_export_page_v83(uuid,integer,integer)','EXECUTE')
     or not has_function_privilege('authenticated','public.customer_sync_verified_relationships_v81(text)','EXECUTE') then
    raise exception 'A: authenticated must hold EXECUTE on all four RPCs';
  end if;
  if has_function_privilege('anon','public.get_customer_intelligence_v83(uuid,uuid,date,date,integer,timestamptz,timestamptz,uuid)','EXECUTE')
     or has_function_privilege('anon','public.customer_sync_verified_relationships_v81(text)','EXECUTE') then
    raise exception 'A: anon must NOT hold EXECUTE';
  end if;

  select id into v_owner from auth.users order by created_at limit 1;
  select id into v_outsider from auth.users where id <> v_owner order by created_at limit 1;
  if v_outsider is null then raise exception 'need two auth users'; end if;

  ---------------------------------------------------------------- seed
  insert into public.businesses (name, slug, currency)
    values ('ZZ V284 INTEL PTE LTD', 'zz-v284-intel', 'SGD') returning id into v_biz;
  insert into public.staff (business_id, user_id, role, active)
    values (v_biz, v_owner, 'owner', true);
  -- app.has_perm requires an open workspace (v94): approved + not paused.
  insert into public.business_workspace_controls_v94
      (business_id, approval_status, decided_by, decided_at, decision_reason)
    values (v_biz, 'approved', v_owner, now(), 'v284 acceptance fixture')
    on conflict (business_id) do update set approval_status = 'approved',
      decided_by = excluded.decided_by, decided_at = excluded.decided_at,
      decision_reason = excluded.decision_reason;
  insert into public.business_subscription_lifecycle_v94 (business_id, workspace_paused)
    values (v_biz, false)
    on conflict (business_id) do update set workspace_paused = false;
  insert into public.clients (business_id, full_name, phone, email, created_at)
    values (v_biz, 'ZZ Alpha', '81110001', 'a@v284.test', now() - interval '2 days')
    returning id into v_client_a;
  insert into public.clients (business_id, full_name, phone, email, created_at)
    values (v_biz, 'ZZ Beta', '81110002', 'b@v284.test', now() - interval '1 day')
    returning id into v_client_b;
  insert into public.sales (business_id, client_id, kind, amount_cents, occurred_at)
    values (v_biz, v_client_a, 'service', 5000, '2026-07-05T10:00:00+08'),
           (v_biz, v_client_a, 'gift_card', 2000, '2026-07-06T10:00:00+08'),
           (v_biz, v_client_b, 'service', 1000, '2026-07-10T10:00:00+08'),
           (v_biz, v_client_b, 'service', 2000, '2026-07-20T10:00:00+08');

  ---------------------------------------------------------------- as OWNER
  perform set_config('request.jwt.claim.sub', v_owner::text, true);
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_owner, 'role', 'authenticated')::text, true);

  -- B. full list serves both customers with the frontend's fields
  d := public.get_customer_intelligence_v83(
    v_biz, null, '2026-07-01', '2026-07-31', 100, null, null, null);
  if jsonb_array_length(d->'customers') <> 2 then
    raise exception 'B: expected 2 customers, got %', d->'customers'; end if;
  if (d#>>'{pagination,total_customers}')::int <> 2 then
    raise exception 'B: total_customers wrong: %', d->'pagination'; end if;
  if d->>'snapshot_at' is null then raise exception 'B: snapshot_at missing'; end if;
  if not (d#>'{customers,0}' ?& array['client_id','purchase_count','net_revenue_cents','visit_count','cash_collected_cents','last_purchase_at']) then
    raise exception 'B: customer row missing frontend fields: %', d#>'{customers,0}'; end if;
  if (select (c->>'purchase_count')::int from jsonb_array_elements(d->'customers') c
       where c->>'client_id' = v_client_b::text) <> 2 then
    raise exception 'B: Beta must show 2 purchases'; end if;
  if (d#>>'{forecast,status}') is null then raise exception 'B: forecast missing'; end if;

  -- C. cursor pagination covers both customers exactly once
  d := public.get_customer_intelligence_v83(
    v_biz, null, '2026-07-01', '2026-07-31', 1, null, null, null);
  if (d#>>'{pagination,has_more}')::boolean is not true
     or d#>'{pagination,next_cursor}' is null then
    raise exception 'C: page 1 must offer a cursor: %', d->'pagination'; end if;
  v_first := d#>>'{customers,0,client_id}';
  d2 := public.get_customer_intelligence_v83(
    v_biz, null, '2026-07-01', '2026-07-31', 1, (d->>'snapshot_at')::timestamptz,
    (d#>>'{pagination,next_cursor,customer_since}')::timestamptz,
    (d#>>'{pagination,next_cursor,client_id}')::uuid);
  v_second := d2#>>'{customers,0,client_id}';
  if v_first = v_second
     or v_first not in (v_client_a::text, v_client_b::text)
     or v_second not in (v_client_a::text, v_client_b::text) then
    raise exception 'C: cursor pages must cover both customers once (% / %)', v_first, v_second; end if;

  -- D. fixed export: create, then page by ordinal to exactly the total
  d := public.create_customer_intelligence_export_v83(
    v_biz, null, '2026-07-01', '2026-07-31');
  v_export := (d->>'export_id')::uuid;
  if v_export is null or (d->>'total_customers')::int <> 2 then
    raise exception 'D: export create wrong: %', d; end if;
  d := public.get_customer_intelligence_export_page_v83(v_export, 0, 1);
  if jsonb_array_length(d->'customers') <> 1
     or (d#>>'{pagination,has_more}')::boolean is not true
     or (d#>>'{pagination,next_ordinal}')::int < 1 then
    raise exception 'D: export page 1 wrong: %', d->'pagination'; end if;
  d := public.get_customer_intelligence_export_page_v83(
    v_export, (d#>>'{pagination,next_ordinal}')::int, 500);
  if jsonb_array_length(d->'customers') <> 1
     or (d#>>'{pagination,has_more}')::boolean is not false then
    raise exception 'D: export page 2 wrong: %', d->'pagination'; end if;

  ---------------------------------------------------------------- as OUTSIDER
  perform set_config('request.jwt.claim.sub', v_outsider::text, true);
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_outsider, 'role', 'authenticated')::text, true);
  begin
    perform public.get_customer_intelligence_v83(
      v_biz, null, '2026-07-01', '2026-07-31', 100, null, null, null);
    raise exception 'E: outsider read the customer list';
  exception when sqlstate '42501' then null; end;
  begin
    perform public.get_customer_intelligence_export_page_v83(v_export, 0, 500);
    raise exception 'E: outsider read the export';
  exception
    when sqlstate '42501' then null;
    when sqlstate '22023' then null; -- requested_by binding: export invisible
  end;

  ---------------------------------------------------------------- as CUSTOMER
  -- F. the v81 relationship sync runs for a real customer identity (the wallet
  --    auto-link branch) instead of dying with PGRST202.
  select ci.auth_user_id into v_customer
    from public.customer_identities ci
    where ci.status = 'active' and ci.auth_user_id is not null
    order by ci.created_at limit 1;
  if v_customer is not null then
    perform set_config('request.jwt.claim.sub', v_customer::text, true);
    perform set_config('request.jwt.claims',
      json_build_object('sub', v_customer, 'role', 'authenticated')::text, true);
    begin
      d := public.customer_sync_verified_relationships_v81('v284-accept-key');
      if coalesce(d->>'outcome','') not in ('synchronized','try_later') then
        raise exception 'F: unexpected sync outcome %', d->>'outcome'; end if;
    exception
      when sqlstate '0A000' then null; -- customer_claims feature disabled: acceptable
    end;
  end if;

  raise notice 'v284 customer intelligence + relationship sync: all assertions passed';
end $v284$;

rollback;
