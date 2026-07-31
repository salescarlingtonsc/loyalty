-- NESTLY v123 — module/button readiness: atomic replay-safe bundle creation.
-- Forward-only local implementation. Do not apply remotely without release approval.

begin;

create table app.service_bundle_operations_v123 (
  business_id uuid not null references public.businesses(id) on delete cascade,
  actor uuid not null,
  idempotency_key text not null
    check (char_length(idempotency_key) between 1 and 160),
  request_hash text not null check (request_hash ~ '^[0-9a-f]{64}$'),
  bundle_id uuid not null references public.bundles(id) on delete cascade,
  response jsonb not null,
  created_at timestamptz not null default clock_timestamp(),
  primary key (business_id,actor,idempotency_key)
);

alter table app.service_bundle_operations_v123 enable row level security;
revoke all privileges on table app.service_bundle_operations_v123
  from public,anon,authenticated;

-- Retire the legacy two-request browser path. Catalogue reads remain available,
-- while the SECURITY DEFINER writer below is the only browser creation authority.
drop policy if exists bundles_all on public.bundles;
drop policy if exists bundle_items_all on public.bundle_items;
drop policy if exists bundles_member_read_v123 on public.bundles;
create policy bundles_member_read_v123 on public.bundles
  for select to authenticated
  using (app.can_module_read(business_id,'services'));

drop policy if exists bundle_items_member_read_v123 on public.bundle_items;
create policy bundle_items_member_read_v123 on public.bundle_items
  for select to authenticated
  using (
    exists (
      select 1 from public.bundles bundle
       where bundle.id=bundle_id
         and app.can_module_read(bundle.business_id,'services')
    )
  );

revoke insert,update,delete,truncate on table public.bundles
  from anon,authenticated;
revoke insert,update,delete,truncate on table public.bundle_items
  from anon,authenticated;
grant select on table public.bundles,public.bundle_items to authenticated;

create or replace function public.create_service_bundle_v123(
  p_business uuid,
  p_name text,
  p_price_cents integer,
  p_service_ids uuid[],
  p_idempotency_key text
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare
  v_actor uuid:=auth.uid();
  v_name text:=btrim(coalesce(p_name,''));
  v_service_ids uuid[];
  v_request_hash text;
  v_existing app.service_bundle_operations_v123%rowtype;
  v_bundle_id uuid;
  v_response jsonb;
begin
  if v_actor is null or p_business is null
     or not app.can_module_write(p_business,'services') then
    raise exception 'permission denied' using errcode='42501';
  end if;

  select array_agg(service_id order by service_id)
    into v_service_ids
    from (
      select distinct candidate as service_id
        from unnest(coalesce(p_service_ids,array[]::uuid[])) candidate
       where candidate is not null
    ) normalized;

  if char_length(v_name) not between 2 and 120
     or p_price_cents is null or p_price_cents not between 0 and 100000000
     or p_idempotency_key is null
     or char_length(p_idempotency_key) not between 1 and 160
     or cardinality(coalesce(v_service_ids,array[]::uuid[])) not between 2 and 50
     or cardinality(coalesce(p_service_ids,array[]::uuid[]))
        <> cardinality(coalesce(v_service_ids,array[]::uuid[])) then
    raise exception 'invalid service bundle' using errcode='22023';
  end if;

  v_request_hash:=app.v41_request_hash(jsonb_build_object(
    'business_id',p_business,
    'name',v_name,
    'price_cents',p_price_cents,
    'service_ids',to_jsonb(v_service_ids)
  )::text);

  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(
    'v123:bundle:'||p_business::text||':'||v_actor::text||':'||p_idempotency_key,
    123
  ));

  select * into v_existing
    from app.service_bundle_operations_v123 operation
   where operation.business_id=p_business
     and operation.actor=v_actor
     and operation.idempotency_key=p_idempotency_key;
  if found then
    if v_existing.request_hash<>v_request_hash then
      raise exception 'idempotency key reused with a different bundle'
        using errcode='22023';
    end if;
    return v_existing.response||jsonb_build_object('replayed',true);
  end if;

  -- Mutable catalogue state is checked only for a fresh write. A lost-response
  -- replay must remain observable even if a service was disabled afterward.
  if (
    select count(*)
      from public.services service
     where service.business_id=p_business
       and service.active
       and service.id=any(v_service_ids)
  ) <> cardinality(v_service_ids) then
    raise exception 'bundle services must be active in this business'
      using errcode='22023';
  end if;

  insert into public.bundles (business_id,name,price_cents)
  values (p_business,v_name,p_price_cents)
  returning id into v_bundle_id;

  insert into public.bundle_items (bundle_id,service_id)
  select v_bundle_id,service_id from unnest(v_service_ids) service_id;

  v_response:=jsonb_build_object(
    'status','created','bundle_id',v_bundle_id,'replayed',false
  );

  insert into app.service_bundle_operations_v123 (
    business_id,actor,idempotency_key,request_hash,bundle_id,response
  ) values (
    p_business,v_actor,p_idempotency_key,v_request_hash,v_bundle_id,v_response
  );

  insert into public.audit_log (
    business_id,actor,action,entity,entity_id,detail
  ) values (
    p_business,v_actor,'SERVICE_BUNDLE_CREATE','bundles',v_bundle_id,
    jsonb_build_object(
      'name',v_name,'price_cents',p_price_cents,
      'service_count',cardinality(v_service_ids)
    )
  );

  return v_response;
end
$$;

revoke all privileges on function public.create_service_bundle_v123(
  uuid,text,integer,uuid[],text
) from public,anon,authenticated;
grant execute on function public.create_service_bundle_v123(
  uuid,text,integer,uuid[],text
) to authenticated;

commit;
