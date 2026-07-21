-- FRENLY v24c - BACKEND IMPORT JOB FOUNDATION
-- Local review candidate. Do not apply until the phase release gate is accepted.
--
-- Replaces browser-side row inserts with an owner-authorized, retry-safe two-step flow:
-- stage and validate the whole batch, then commit it atomically. v24c supports the three
-- currently shipped import surfaces (customers, services, inventory/opening stock). The
-- generic job/row model is the contract for staff, branches and reservation capacity next.

begin;

create table if not exists public.import_jobs (
  id uuid primary key,
  business_id uuid not null references public.businesses(id) on delete cascade,
  entity_type text not null check (entity_type in (
    'customers', 'services', 'inventory', 'staff', 'branches', 'reservations'
  )),
  actor uuid not null,
  idempotency_key text not null check (length(btrim(idempotency_key)) >= 8),
  request_hash text not null check (length(request_hash) = 32),
  status text not null default 'staged' check (status in ('staged', 'completed')),
  total_rows integer not null check (total_rows between 1 and 500),
  valid_rows integer not null default 0 check (valid_rows >= 0),
  invalid_rows integer not null default 0 check (invalid_rows >= 0),
  result jsonb,
  created_at timestamptz not null default now(),
  completed_at timestamptz,
  constraint import_jobs_counts_check check (valid_rows + invalid_rows = total_rows),
  constraint import_jobs_completion_check check (
    (status = 'staged' and result is null and completed_at is null)
    or (status = 'completed' and result is not null and completed_at is not null)
  ),
  constraint import_jobs_idempotency_uk unique
    (business_id, entity_type, idempotency_key),
  constraint import_jobs_id_business_uk unique (id, business_id)
);

create table if not exists public.import_rows (
  id uuid primary key default gen_random_uuid(),
  job_id uuid not null,
  business_id uuid not null references public.businesses(id) on delete cascade,
  row_number integer not null check (row_number > 0),
  raw_data jsonb not null check (
    jsonb_typeof(raw_data) = 'object' and octet_length(raw_data::text) <= 32768
  ),
  normalized_data jsonb not null check (jsonb_typeof(normalized_data) = 'object'),
  errors text[] not null default '{}',
  committed_id uuid,
  created_at timestamptz not null default now(),
  constraint import_rows_job_business_fk foreign key (job_id, business_id)
    references public.import_jobs(id, business_id) on delete cascade,
  constraint import_rows_job_row_uk unique (job_id, row_number)
);

create index if not exists import_jobs_business_time_idx
  on public.import_jobs (business_id, created_at desc);
create index if not exists import_rows_job_idx
  on public.import_rows (job_id, row_number);

alter table public.import_jobs enable row level security;
alter table public.import_rows enable row level security;
drop policy if exists import_jobs_owner_read on public.import_jobs;
drop policy if exists import_jobs_sa_read on public.import_jobs;
drop policy if exists import_rows_owner_read on public.import_rows;
drop policy if exists import_rows_sa_read on public.import_rows;
create policy import_jobs_owner_read on public.import_jobs for select to authenticated
  using (app.is_salon_owner(business_id));
create policy import_jobs_sa_read on public.import_jobs for select to authenticated
  using (app.is_super_admin());
create policy import_rows_owner_read on public.import_rows for select to authenticated
  using (app.is_salon_owner(business_id));
create policy import_rows_sa_read on public.import_rows for select to authenticated
  using (app.is_super_admin());
revoke all privileges on table public.import_jobs from public, anon, authenticated;
revoke all privileges on table public.import_rows from public, anon, authenticated;
grant select on table public.import_jobs to authenticated;
grant select on table public.import_rows to authenticated;

create or replace function public.stage_import_rows(
  p_business uuid,
  p_entity text,
  p_rows jsonb,
  p_idempotency_key text
)
returns json
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_actor uuid := auth.uid();
  v_job_id uuid := gen_random_uuid();
  v_hash text;
  v_existing public.import_jobs%rowtype;
  v_raw jsonb;
  v_stored_raw jsonb;
  v_normalized jsonb;
  v_errors text[];
  v_row_number integer;
  v_total integer;
  v_valid integer := 0;
  v_invalid integer := 0;
  v_name text;
  v_phone text;
  v_phone_norm text;
  v_gender text;
  v_birth_date date;
  v_price bigint;
  v_duration bigint;
  v_qty bigint;
  v_pax bigint;
  v_sort bigint;
  v_role text;
  v_color text;
  v_timezone text;
  v_rows_inserted integer;
  v_error_preview json;
begin
  if not app.is_salon_owner(p_business) then
    raise exception 'only the business owner can stage imports' using errcode = '42501';
  end if;
  if p_entity not in (
    'customers', 'services', 'inventory', 'staff', 'branches', 'reservations'
  ) then
    raise exception 'unsupported import entity %', p_entity using errcode = '22023';
  end if;
  if p_idempotency_key is null or length(btrim(p_idempotency_key)) < 8 then
    raise exception 'idempotency key must contain at least 8 characters' using errcode = '22023';
  end if;
  if jsonb_typeof(p_rows) <> 'array' then
    raise exception 'import rows must be a JSON array' using errcode = '22023';
  end if;
  v_total := jsonb_array_length(p_rows);
  if v_total < 1 or v_total > 500 then
    raise exception 'an import must contain between 1 and 500 rows' using errcode = '22023';
  end if;
  p_idempotency_key := btrim(p_idempotency_key);
  v_hash := md5(p_rows::text);

  insert into public.import_jobs
    (id, business_id, entity_type, actor, idempotency_key, request_hash,
     total_rows, valid_rows, invalid_rows)
  values
    (v_job_id, p_business, p_entity, v_actor, p_idempotency_key, v_hash,
     v_total, 0, v_total)
  on conflict (business_id, entity_type, idempotency_key) do nothing;
  get diagnostics v_rows_inserted = row_count;

  if v_rows_inserted = 0 then
    select * into v_existing from public.import_jobs
     where business_id = p_business and entity_type = p_entity
       and idempotency_key = p_idempotency_key;
    if v_existing.actor is distinct from v_actor or v_existing.request_hash <> v_hash then
      raise exception 'idempotency key was already used for another import'
        using errcode = '22023';
    end if;
    select coalesce(json_agg(e order by e.row_number), '[]'::json) into v_error_preview
      from (
        select row_number, errors from public.import_rows
         where job_id = v_existing.id and cardinality(errors) > 0
         order by row_number limit 10
      ) e;
    return json_build_object(
      'job_id', v_existing.id, 'status', v_existing.status,
      'total', v_existing.total_rows, 'valid', v_existing.valid_rows,
      'invalid', v_existing.invalid_rows, 'errors', v_error_preview,
      'result', v_existing.result
    );
  end if;

  for v_raw, v_row_number in
    select value, ordinality::integer
      from jsonb_array_elements(p_rows) with ordinality
  loop
    v_errors := '{}';
    v_normalized := '{}'::jsonb;
    v_stored_raw := v_raw;
    if jsonb_typeof(v_raw) <> 'object' then
      v_errors := array_append(v_errors, 'row must be an object');
      v_stored_raw := jsonb_build_object('_invalid_value', v_raw);
    elsif octet_length(v_raw::text) > 32768 then
      v_errors := array_append(v_errors, 'row is too large');
      v_stored_raw := jsonb_build_object('_omitted', true);
    else
      v_name := btrim(coalesce(v_raw->>'full_name', v_raw->>'name', ''));
      if length(v_name) < 2 or length(v_name) > 160 then
        v_errors := array_append(v_errors, 'name must contain 2 to 160 characters');
      end if;

      if p_entity = 'customers' then
        v_phone := nullif(btrim(v_raw->>'phone'), '');
        v_gender := nullif(lower(btrim(v_raw->>'gender')), '');
        if v_gender is not null and v_gender not in ('female', 'male', 'other') then
          v_errors := array_append(v_errors, 'gender must be female, male or other');
        end if;
        v_birth_date := null;
        if nullif(btrim(v_raw->>'birth_date'), '') is not null then
          begin
            v_birth_date := (v_raw->>'birth_date')::date;
          exception when others then
            v_errors := array_append(v_errors, 'birth_date must be YYYY-MM-DD');
          end;
        end if;
        v_phone_norm := case when v_phone is null then null else app.norm_phone(v_phone) end;
        if v_phone is not null and v_phone_norm is null then
          v_errors := array_append(v_errors, 'phone number is invalid');
        elsif v_phone_norm is not null and exists (
          select 1 from public.clients
           where business_id = p_business and phone_norm = v_phone_norm
        ) then
          v_errors := array_append(v_errors, 'phone already belongs to a customer');
        end if;
        v_normalized := jsonb_strip_nulls(jsonb_build_object(
          'full_name', v_name, 'phone', v_phone,
          'email', nullif(btrim(v_raw->>'email'), ''), 'gender', v_gender,
          'birth_date', v_birth_date, 'notes', nullif(btrim(v_raw->>'notes'), '')
        ));
      elsif p_entity = 'services' then
        if coalesce(v_raw->>'price_cents', '') !~ '^[0-9]+$' then
          v_errors := array_append(v_errors, 'price must be zero or a positive whole number of cents');
          v_price := 0;
        else
          v_price := (v_raw->>'price_cents')::bigint;
          if v_price > 100000000 then v_errors := array_append(v_errors, 'price is too large'); end if;
        end if;
        if coalesce(v_raw->>'duration_min', '') !~ '^[0-9]+$' then
          v_errors := array_append(v_errors, 'duration must be a whole number of minutes');
          v_duration := 60;
        else
          v_duration := (v_raw->>'duration_min')::bigint;
          if v_duration < 1 or v_duration > 1440 then
            v_errors := array_append(v_errors, 'duration must be between 1 and 1440 minutes');
          end if;
        end if;
        v_normalized := jsonb_strip_nulls(jsonb_build_object(
          'name', v_name, 'price_cents', v_price, 'duration_min', v_duration,
          'category', nullif(btrim(v_raw->>'category'), ''),
          'description', nullif(btrim(v_raw->>'description'), '')
        ));
        if exists (
          select 1 from public.services s
           where s.business_id=p_business and lower(btrim(s.name))=lower(v_name)
             and s.price_cents=v_price and s.duration_min=v_duration
        ) then v_errors:=array_append(v_errors,'matching service already exists'); end if;
      elsif p_entity = 'inventory' then
        if coalesce(v_raw->>'retail_price_cents', '') !~ '^[0-9]+$' then
          v_errors := array_append(v_errors, 'retail price must be zero or a positive whole number of cents');
          v_price := 0;
        else
          v_price := (v_raw->>'retail_price_cents')::bigint;
          if v_price > 100000000 then v_errors := array_append(v_errors, 'retail price is too large'); end if;
        end if;
        if coalesce(v_raw->>'opening_qty', '0') !~ '^[0-9]+$' then
          v_errors := array_append(v_errors, 'opening quantity must be a positive whole number');
          v_qty := 0;
        else
          v_qty := coalesce((v_raw->>'opening_qty')::bigint, 0);
          if v_qty > 100000000 then v_errors := array_append(v_errors, 'opening quantity is too large'); end if;
        end if;
        if nullif(btrim(v_raw->>'sku'), '') is not null and exists (
          select 1 from public.products
           where business_id = p_business and sku = btrim(v_raw->>'sku')
        ) then
          v_errors := array_append(v_errors, 'SKU already exists');
        end if;
        v_normalized := jsonb_strip_nulls(jsonb_build_object(
          'name', v_name, 'sku', nullif(btrim(v_raw->>'sku'), ''),
          'retail_price_cents', v_price, 'opening_qty', v_qty
        ));
      elsif p_entity = 'staff' then
        v_role := coalesce(nullif(lower(btrim(v_raw->>'role')), ''), 'staff');
        v_color := coalesce(nullif(btrim(v_raw->>'calendar_color'), ''), '#7C9CBF');
        if v_role not in ('manager', 'staff', 'frontdesk', 'bookkeeper') then
          v_errors := array_append(v_errors, 'role must be manager, staff, frontdesk or bookkeeper');
        end if;
        if v_color !~ '^#[0-9A-Fa-f]{6}$' then
          v_errors := array_append(v_errors, 'calendar colour must be a 6-digit hex colour');
        end if;
        v_normalized := jsonb_strip_nulls(jsonb_build_object(
          'full_name', v_name, 'email', nullif(btrim(v_raw->>'email'), ''),
          'phone', nullif(btrim(v_raw->>'phone'), ''),
          'title', nullif(btrim(v_raw->>'title'), ''),
          'role', v_role, 'calendar_color', v_color
        ));
        if exists (
          select 1 from public.staff s where s.business_id=p_business and (
            (nullif(btrim(v_raw->>'email'),'') is not null
             and lower(btrim(s.email))=lower(btrim(v_raw->>'email')))
            or (nullif(regexp_replace(coalesce(v_raw->>'phone',''),'\D','','g'),'') is not null
                and regexp_replace(coalesce(s.phone,''),'\D','','g')=
                    regexp_replace(v_raw->>'phone','\D','','g'))
          )
        ) then v_errors:=array_append(v_errors,'staff email or phone already exists'); end if;
      elsif p_entity = 'branches' then
        v_timezone := coalesce(nullif(btrim(v_raw->>'timezone'), ''), 'Asia/Singapore');
        if not exists (select 1 from pg_timezone_names where name = v_timezone) then
          v_errors := array_append(v_errors, 'timezone is not recognised');
        end if;
        v_normalized := jsonb_strip_nulls(jsonb_build_object(
          'name', v_name, 'address', nullif(btrim(v_raw->>'address'), ''),
          'phone', nullif(btrim(v_raw->>'phone'), ''),
          'email', nullif(btrim(v_raw->>'email'), ''), 'timezone', v_timezone
        ));
        if exists (
          select 1 from public.branches b where b.business_id=p_business
           and lower(btrim(b.name))=lower(v_name)
           and lower(btrim(coalesce(b.address,'')))=
               lower(btrim(coalesce(v_raw->>'address','')))
        ) then v_errors:=array_append(v_errors,'matching branch already exists'); end if;
      else
        if coalesce(v_raw->>'quantity', '') !~ '^[0-9]+$' then
          v_errors := array_append(v_errors, 'quantity must be a positive whole number');
          v_qty := 1;
        else
          v_qty := (v_raw->>'quantity')::bigint;
          if v_qty < 1 or v_qty > 1000 then
            v_errors := array_append(v_errors, 'quantity must be between 1 and 1000');
          end if;
        end if;
        v_pax := null;
        if nullif(v_raw->>'pax', '') is not null then
          if (v_raw->>'pax') !~ '^[0-9]+$' then
            v_errors := array_append(v_errors, 'pax must be a positive whole number');
          else
            v_pax := (v_raw->>'pax')::bigint;
            if v_pax < 1 or v_pax > 1000 then
              v_errors := array_append(v_errors, 'pax must be between 1 and 1000');
            end if;
          end if;
        end if;
        if coalesce(v_raw->>'sort', '0') !~ '^-?[0-9]+$' then
          v_errors := array_append(v_errors, 'sort must be a whole number');
          v_sort := 0;
        else
          v_sort := coalesce((v_raw->>'sort')::bigint, 0);
        end if;
        v_normalized := jsonb_strip_nulls(jsonb_build_object(
          'name', v_name, 'pax', v_pax, 'quantity', v_qty, 'sort', v_sort
        ));
        if exists (
          select 1 from public.booking_tables t where t.business_id=p_business
           and lower(btrim(t.name))=lower(v_name)
           and t.pax is not distinct from v_pax::integer
        ) then v_errors:=array_append(v_errors,'matching reservation table already exists'); end if;
      end if;
    end if;

    insert into public.import_rows
      (job_id, business_id, row_number, raw_data, normalized_data, errors)
    values
      (v_job_id, p_business, v_row_number, v_stored_raw, v_normalized, v_errors);
    if cardinality(v_errors) = 0 then v_valid := v_valid + 1;
    else v_invalid := v_invalid + 1;
    end if;
  end loop;

  -- Identify duplicates inside this upload before commit, so the owner gets row-specific
  -- feedback instead of a generic unique-constraint failure after pressing Import.
  if p_entity = 'customers' then
    update public.import_rows current_row
       set errors = array_append(current_row.errors, 'phone is duplicated in this import')
     where current_row.job_id = v_job_id
       and nullif(current_row.normalized_data->>'phone', '') is not null
       and exists (
         select 1 from public.import_rows earlier
          where earlier.job_id = current_row.job_id
            and earlier.row_number < current_row.row_number
            and app.norm_phone(earlier.normalized_data->>'phone')
                = app.norm_phone(current_row.normalized_data->>'phone')
       );
  elsif p_entity = 'inventory' then
    update public.import_rows current_row
       set errors = array_append(current_row.errors, 'SKU is duplicated in this import')
     where current_row.job_id = v_job_id
       and nullif(current_row.normalized_data->>'sku', '') is not null
       and exists (
         select 1 from public.import_rows earlier
          where earlier.job_id = current_row.job_id
            and earlier.row_number < current_row.row_number
            and earlier.normalized_data->>'sku' = current_row.normalized_data->>'sku'
       );
  else
    update public.import_rows current_row
       set errors = array_append(current_row.errors, 'matching row is duplicated in this import')
     where current_row.job_id = v_job_id
       and exists (
         select 1 from public.import_rows earlier
          where earlier.job_id = current_row.job_id
            and earlier.row_number < current_row.row_number
            and earlier.normalized_data = current_row.normalized_data
       );
  end if;

  select count(*) filter (where cardinality(errors) = 0),
         count(*) filter (where cardinality(errors) > 0)
    into v_valid, v_invalid
    from public.import_rows where job_id = v_job_id;

  update public.import_jobs
     set valid_rows = v_valid, invalid_rows = v_invalid
   where id = v_job_id;
  select coalesce(json_agg(e order by e.row_number), '[]'::json) into v_error_preview
    from (
      select row_number, errors from public.import_rows
       where job_id = v_job_id and cardinality(errors) > 0
       order by row_number limit 10
    ) e;
  return json_build_object(
    'job_id', v_job_id, 'status', 'staged', 'total', v_total,
    'valid', v_valid, 'invalid', v_invalid, 'errors', v_error_preview
  );
end $$;

create or replace function public.commit_import_job(p_job uuid)
returns json
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_job public.import_jobs%rowtype;
  v_row public.import_rows%rowtype;
  v_id uuid;
  v_imported integer := 0;
  v_result json;
begin
  select * into v_job from public.import_jobs where id = p_job for update;
  if not found then raise exception 'import job not found'; end if;
  if not app.is_salon_owner(v_job.business_id) then
    raise exception 'only the business owner can commit imports' using errcode = '42501';
  end if;
  -- Serialize commits for one business/entity and recheck natural keys below. Staging previews
  -- remain concurrent, but two approved imports cannot both pass a stale duplicate check.
  perform pg_advisory_xact_lock(hashtextextended(
    'v24c:import:'||v_job.business_id::text||':'||v_job.entity_type,0
  ));
  if v_job.status = 'completed' then return v_job.result::json; end if;
  if v_job.invalid_rows > 0 then
    raise exception 'fix all invalid rows before importing' using errcode = 'check_violation';
  end if;

  for v_row in
    select * from public.import_rows
     where job_id = p_job and business_id = v_job.business_id
     order by row_number for update
  loop
    if v_job.entity_type='customers' and nullif(v_row.normalized_data->>'phone','') is not null
       and exists(select 1 from public.clients c where c.business_id=v_job.business_id
         and c.phone_norm=app.norm_phone(v_row.normalized_data->>'phone')) then
      raise exception 'customer now exists; restage the import for a fresh preview';
    elsif v_job.entity_type='services' and exists(
      select 1 from public.services s where s.business_id=v_job.business_id
       and lower(btrim(s.name))=lower(v_row.normalized_data->>'name')
       and s.price_cents=(v_row.normalized_data->>'price_cents')::integer
       and s.duration_min=(v_row.normalized_data->>'duration_min')::integer
    ) then raise exception 'service now exists; restage the import for a fresh preview';
    elsif v_job.entity_type='inventory' and nullif(v_row.normalized_data->>'sku','') is not null
       and exists(select 1 from public.products p where p.business_id=v_job.business_id
         and p.sku=v_row.normalized_data->>'sku') then
      raise exception 'product SKU now exists; restage the import for a fresh preview';
    elsif v_job.entity_type='staff' and exists(
      select 1 from public.staff s where s.business_id=v_job.business_id and (
        (v_row.normalized_data ? 'email' and lower(btrim(s.email))=lower(v_row.normalized_data->>'email'))
        or (v_row.normalized_data ? 'phone' and regexp_replace(coalesce(s.phone,''),'\D','','g')=
            regexp_replace(v_row.normalized_data->>'phone','\D','','g')))
    ) then raise exception 'staff now exists; restage the import for a fresh preview';
    elsif v_job.entity_type='branches' and exists(
      select 1 from public.branches b where b.business_id=v_job.business_id
       and lower(btrim(b.name))=lower(v_row.normalized_data->>'name')
       and lower(btrim(coalesce(b.address,'')))=lower(btrim(coalesce(v_row.normalized_data->>'address','')))
    ) then raise exception 'branch now exists; restage the import for a fresh preview';
    elsif v_job.entity_type='reservations' and exists(
      select 1 from public.booking_tables t where t.business_id=v_job.business_id
       and lower(btrim(t.name))=lower(v_row.normalized_data->>'name')
       and t.pax is not distinct from nullif(v_row.normalized_data->>'pax','')::integer
    ) then raise exception 'reservation table now exists; restage the import for a fresh preview';
    end if;
    if v_job.entity_type = 'customers' then
      insert into public.clients
        (business_id, full_name, phone, email, gender, birth_date, notes)
      values
        (v_job.business_id, v_row.normalized_data->>'full_name',
         v_row.normalized_data->>'phone', v_row.normalized_data->>'email',
         v_row.normalized_data->>'gender',
         (v_row.normalized_data->>'birth_date')::date,
         v_row.normalized_data->>'notes')
      returning id into v_id;
    elsif v_job.entity_type = 'services' then
      insert into public.services
        (business_id, name, price_cents, duration_min, category, description, active)
      values
        (v_job.business_id, v_row.normalized_data->>'name',
         (v_row.normalized_data->>'price_cents')::integer,
         (v_row.normalized_data->>'duration_min')::integer,
         v_row.normalized_data->>'category', v_row.normalized_data->>'description', true)
      returning id into v_id;
    elsif v_job.entity_type = 'inventory' then
      insert into public.products
        (business_id, name, sku, retail_price_cents, active)
      values
        (v_job.business_id, v_row.normalized_data->>'name',
         v_row.normalized_data->>'sku',
         (v_row.normalized_data->>'retail_price_cents')::integer, true)
      returning id into v_id;
      if coalesce((v_row.normalized_data->>'opening_qty')::integer, 0) > 0 then
        insert into public.stock_batches (product_id, qty)
        values (v_id, (v_row.normalized_data->>'opening_qty')::integer);
      end if;
    elsif v_job.entity_type = 'staff' then
      insert into public.staff
        (business_id, full_name, email, phone, title, role, calendar_color, active)
      values
        (v_job.business_id, v_row.normalized_data->>'full_name',
         v_row.normalized_data->>'email', v_row.normalized_data->>'phone',
         v_row.normalized_data->>'title', v_row.normalized_data->>'role',
         v_row.normalized_data->>'calendar_color', true)
      returning id into v_id;
    elsif v_job.entity_type = 'branches' then
      insert into public.branches
        (business_id, name, address, phone, email, timezone, active, is_default)
      values
        (v_job.business_id, v_row.normalized_data->>'name',
         v_row.normalized_data->>'address', v_row.normalized_data->>'phone',
         v_row.normalized_data->>'email', v_row.normalized_data->>'timezone', true, false)
      returning id into v_id;
    else
      insert into public.booking_tables
        (business_id, name, pax, quantity, sort, active)
      values
        (v_job.business_id, v_row.normalized_data->>'name',
         (v_row.normalized_data->>'pax')::integer,
         (v_row.normalized_data->>'quantity')::integer,
         (v_row.normalized_data->>'sort')::integer, true)
      returning id into v_id;
    end if;
    update public.import_rows set committed_id = v_id where id = v_row.id;
    v_imported := v_imported + 1;
  end loop;

  v_result := json_build_object(
    'job_id', p_job, 'entity', v_job.entity_type, 'imported', v_imported
  );
  update public.import_jobs
     set status = 'completed', result = v_result::jsonb, completed_at = now()
   where id = p_job;
  return v_result;
end $$;

revoke all on function public.stage_import_rows(uuid, text, jsonb, text) from public, anon;
grant execute on function public.stage_import_rows(uuid, text, jsonb, text) to authenticated;
revoke all on function public.commit_import_job(uuid) from public, anon;
grant execute on function public.commit_import_job(uuid) to authenticated;

commit;
