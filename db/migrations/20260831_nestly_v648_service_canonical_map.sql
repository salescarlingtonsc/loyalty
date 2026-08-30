-- NESTLY v648 — Phase C, C2: service → canonical-node mapping.
-- A service resolves to exactly one canonical node, mapped once with owner/manager
-- confirmation (DC-2 default accepted: services module write suffices; console corrections
-- are logged separately). The business's own service names are never changed. A mapping is
-- never silently invented: an unmapped service is a visible board row, not a guess.
-- History is append-only via trigger; the current-state row is what stamping reads.
begin;

create table public.service_canonical_map (
  business_id uuid not null references public.businesses(id) on delete cascade,
  service_id uuid not null,
  node_key text not null,
  version_no integer not null,
  method text not null check (method in ('suggested_confirmed','owner_chosen','console_corrected')),
  mapped_by uuid,
  mapped_at timestamptz not null default now(),
  primary key (business_id, service_id),
  foreign key (version_no, node_key) references public.taxonomy_nodes(version_no, node_key)
);
create table public.service_canonical_map_history (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null,
  service_id uuid not null,
  node_key text,
  version_no integer,
  method text,
  mapped_by uuid,
  changed_at timestamptz not null default now(),
  change_kind text not null check (change_kind in ('set','changed','removed'))
);
-- DC-1 shell: per-product mapping exists structurally; only F&B businesses are expected
-- to populate it. Everything else stamps the pack default at write time (v649).
create table public.product_canonical_map (
  business_id uuid not null references public.businesses(id) on delete cascade,
  product_id uuid not null,
  node_key text not null,
  version_no integer not null,
  mapped_by uuid,
  mapped_at timestamptz not null default now(),
  primary key (business_id, product_id),
  foreign key (version_no, node_key) references public.taxonomy_nodes(version_no, node_key)
);

alter table public.service_canonical_map enable row level security;
alter table public.service_canonical_map_history enable row level security;
alter table public.product_canonical_map enable row level security;
create policy service_map_member_read on public.service_canonical_map
  for select to authenticated using (app.is_salon_member(business_id) or app.is_super_admin());
create policy service_map_history_member_read on public.service_canonical_map_history
  for select to authenticated using (app.is_salon_member(business_id) or app.is_super_admin());
create policy product_map_member_read on public.product_canonical_map
  for select to authenticated using (app.is_salon_member(business_id) or app.is_super_admin());
revoke all on public.service_canonical_map, public.service_canonical_map_history, public.product_canonical_map from public, anon, authenticated;
grant select on public.service_canonical_map, public.service_canonical_map_history, public.product_canonical_map to authenticated;

create or replace function app.service_map_history_v648()
returns trigger language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
begin
  insert into public.service_canonical_map_history
    (business_id, service_id, node_key, version_no, method, mapped_by, change_kind)
  values (coalesce(new.business_id, old.business_id),
          coalesce(new.service_id, old.service_id),
          coalesce(new.node_key, old.node_key),
          coalesce(new.version_no, old.version_no),
          coalesce(new.method, old.method),
          coalesce(new.mapped_by, old.mapped_by),
          case tg_op when 'INSERT' then 'set' when 'UPDATE' then 'changed' else 'removed' end);
  return coalesce(new, old);
end;
$$;
create trigger trg_service_map_history
  after insert or update or delete on public.service_canonical_map
  for each row execute function app.service_map_history_v648();
create or replace function app.service_map_history_guard_v648()
returns trigger language plpgsql
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
begin
  raise exception 'service_canonical_map_history is append-only' using errcode = '42501';
end;
$$;
create trigger trg_service_map_history_append_only
  before update or delete on public.service_canonical_map_history
  for each row execute function app.service_map_history_guard_v648();

-- The business's pack, from its declared industry (the v75 fall-through convention).
create or replace function app.business_pack_v648(p_business uuid)
returns text
language sql stable
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
  select case coalesce((select b.industry from public.businesses b where b.id = p_business), 'other')
    when 'fnb' then 'fnb'
    when 'salon' then 'hair_salon'
    when 'facial' then 'beauty_wellness'
    when 'massage' then 'beauty_wellness'
    else 'generic' end;
$$;

-- Deterministic suggestion: longest keyword hit within the business's pack (falling back
-- to any pack), matched against the service name + legacy free-text category. No hit → null.
create or replace function app.suggest_canonical_node_v1(p_business uuid, p_service uuid)
returns text
language plpgsql
stable
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_text text;
  v_pack text := app.business_pack_v648(p_business);
  v_node text;
begin
  select lower(coalesce(s.name,'') || ' ' || coalesce(s.category,'')) into v_text
    from public.services s where s.id = p_service and s.business_id = p_business;
  if v_text is null then return null; end if;
  select k.node_key into v_node
    from public.taxonomy_keywords k
    join public.taxonomy_nodes n on n.version_no = 1 and n.node_key = k.node_key
   where position(k.keyword in v_text) > 0
   order by (n.pack = v_pack) desc, length(k.keyword) desc
   limit 1;
  return v_node;
end;
$$;
revoke all on function app.suggest_canonical_node_v1(uuid,uuid) from public, anon, authenticated;
grant execute on function app.suggest_canonical_node_v1(uuid,uuid) to service_role;

-- The confirm RPC (owner or manager with services write — DC-2 default).
create or replace function public.set_service_canonical_node_v1(
  p_business uuid, p_service uuid, p_node_key text)
returns json
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
begin
  if auth.uid() is null
     or not app.is_salon_member(p_business)
     or not app.can_module_write(p_business, 'services') then
    raise exception 'services write access is required' using errcode = '42501';
  end if;
  if not exists (select 1 from public.services s
                  where s.id = p_service and s.business_id = p_business) then
    raise exception 'service not found' using errcode = '22023';
  end if;
  if not exists (select 1 from public.taxonomy_nodes n
                  where n.version_no = 1 and n.node_key = p_node_key) then
    raise exception 'unknown taxonomy node %', p_node_key using errcode = '22023';
  end if;
  insert into public.service_canonical_map (business_id, service_id, node_key, version_no, method, mapped_by)
  values (p_business, p_service, p_node_key, 1, 'owner_chosen', auth.uid())
  on conflict (business_id, service_id) do update
    set node_key = excluded.node_key, version_no = excluded.version_no,
        method = 'owner_chosen', mapped_by = auth.uid(), mapped_at = now();
  return json_build_object('service_id', p_service, 'node_key', p_node_key);
end;
$$;
revoke all on function public.set_service_canonical_node_v1(uuid,uuid,text) from public, anon;
grant execute on function public.set_service_canonical_node_v1(uuid,uuid,text) to authenticated, service_role;

-- The mapping board: every active service, its current mapping, its suggestion, and pack.
create or replace function public.get_service_mapping_board_v1(p_business uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
begin
  if auth.uid() is null
     or not app.is_salon_member(p_business)
     or not app.can_module(p_business, 'services') then
    raise exception 'services access is required' using errcode = '42501';
  end if;
  return jsonb_build_object(
    'pack', app.business_pack_v648(p_business),
    'services', coalesce((
      select jsonb_agg(jsonb_build_object(
               'service_id', s.id, 'name', s.name, 'legacy_category', s.category,
               'active', s.active,
               'node_key', m.node_key, 'method', m.method,
               'suggested_node_key', app.suggest_canonical_node_v1(p_business, s.id))
             order by s.active desc, s.name)
        from public.services s
        left join public.service_canonical_map m
          on m.business_id = s.business_id and m.service_id = s.id
       where s.business_id = p_business), '[]'::jsonb),
    'nodes', (select jsonb_agg(jsonb_build_object(
                'node_key', n.node_key, 'pack', n.pack, 'level', n.level,
                'parent_key', n.parent_key, 'label', n.label) order by n.pack, n.level, n.node_key)
                from public.taxonomy_nodes n where n.version_no = 1));
end;
$$;
revoke all on function public.get_service_mapping_board_v1(uuid) from public, anon;
grant execute on function public.get_service_mapping_board_v1(uuid) to authenticated, service_role;

-- Logged console correction (super admin).
create or replace function public.platform_correct_service_mapping_v1(
  p_business uuid, p_service uuid, p_node_key text, p_reason text)
returns json
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
begin
  if not app.is_super_admin() then
    raise exception 'platform access required' using errcode = '42501';
  end if;
  if not exists (select 1 from public.taxonomy_nodes n
                  where n.version_no = 1 and n.node_key = p_node_key) then
    raise exception 'unknown taxonomy node %', p_node_key using errcode = '22023';
  end if;
  insert into public.service_canonical_map (business_id, service_id, node_key, version_no, method, mapped_by)
  values (p_business, p_service, p_node_key, 1, 'console_corrected', auth.uid())
  on conflict (business_id, service_id) do update
    set node_key = excluded.node_key, version_no = excluded.version_no,
        method = 'console_corrected', mapped_by = auth.uid(), mapped_at = now();
  insert into public.audit_log (business_id, actor, action, entity, entity_id, detail)
  values (p_business, auth.uid(), 'SERVICE_MAPPING_CORRECTED_V648', 'services', p_service,
          jsonb_build_object('node_key', p_node_key, 'reason', left(coalesce(p_reason,''), 200)));
  return json_build_object('service_id', p_service, 'node_key', p_node_key);
end;
$$;
revoke all on function public.platform_correct_service_mapping_v1(uuid,uuid,text,text) from public, anon;
grant execute on function public.platform_correct_service_mapping_v1(uuid,uuid,text,text) to authenticated, service_role;

commit;
