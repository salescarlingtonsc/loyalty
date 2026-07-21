-- FRENLY v37 - BRANCH OVERRIDE EDITOR RPCS
--
-- Local review candidate. This closes the v29 raw-DML gap for versioned branch
-- loyalty overrides. Retention program versioning remains a separate v37 slice
-- and is still not accepted for production.

begin;

drop policy if exists loyalty_branch_overrides_write on public.loyalty_branch_overrides;
revoke insert, update, delete, truncate on table public.loyalty_branch_overrides
  from public, anon, authenticated;

create or replace function public.save_loyalty_branch_override_draft(
  p_config_version uuid,
  p_branch uuid,
  p_override jsonb,
  p_expected_snapshot_hash text default null
)
returns json
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_header public.firm_config_versions%rowtype;
  v_hash text;
  v_active boolean;
  v_earn numeric;
  v_stamp integer;
  v_expiry_mode text;
  v_expiry_days integer;
begin
  if p_override is null or jsonb_typeof(p_override) <> 'object' then
    raise exception 'override must be a JSON object' using errcode = '22023';
  end if;
  if exists (
    select 1 from jsonb_object_keys(p_override) k
     where k not in ('active','earn_points_per_dollar','stamp_per_cents','expiry_mode','expiry_days')
  ) then
    raise exception 'branch override contains unsupported fields' using errcode = '22023';
  end if;

  select * into v_header
    from public.firm_config_versions
   where id = p_config_version
   for update;

  if not found or not app.is_salon_owner(v_header.business_id) then
    raise exception 'owner only' using errcode = '42501';
  end if;
  if v_header.status <> 'draft' then
    raise exception 'only a draft branch override may be edited' using errcode = '42501';
  end if;
  if p_expected_snapshot_hash is not null
     and v_header.snapshot_hash is distinct from p_expected_snapshot_hash then
    raise exception 'draft configuration changed; reload before saving'
      using errcode = '40001';
  end if;
  if not exists (
    select 1 from public.branches b
     where b.id = p_branch
       and b.business_id = v_header.business_id
  ) then
    raise exception 'branch does not belong to this business' using errcode = '42501';
  end if;

  v_active := case when p_override ? 'active' then (p_override->>'active')::boolean end;
  v_earn := case when p_override ? 'earn_points_per_dollar' then nullif(p_override->>'earn_points_per_dollar','')::numeric end;
  v_stamp := case when p_override ? 'stamp_per_cents' then nullif(p_override->>'stamp_per_cents','')::integer end;
  v_expiry_mode := case when p_override ? 'expiry_mode' then nullif(p_override->>'expiry_mode','') end;
  v_expiry_days := case when p_override ? 'expiry_days' then nullif(p_override->>'expiry_days','')::integer end;

  if v_earn is not null and v_earn < 0 then
    raise exception 'earn_points_per_dollar must be at least zero' using errcode = '22023';
  end if;
  if v_stamp is not null and v_stamp <= 0 then
    raise exception 'stamp_per_cents must be positive' using errcode = '22023';
  end if;
  if v_expiry_mode is not null and v_expiry_mode not in ('none','fixed','inactivity') then
    raise exception 'unsupported expiry_mode' using errcode = '22023';
  end if;
  if v_expiry_days is not null and v_expiry_days <= 0 then
    raise exception 'expiry_days must be positive' using errcode = '22023';
  end if;
  if v_active is null
     and v_earn is null
     and v_stamp is null
     and v_expiry_mode is null
     and v_expiry_days is null then
    raise exception 'use remove_loyalty_branch_override_draft to inherit every firm setting'
      using errcode = '22023';
  end if;

  insert into public.loyalty_branch_overrides (
    config_version_id, business_id, branch_id, active,
    earn_points_per_dollar, stamp_per_cents, expiry_mode, expiry_days
  ) values (
    p_config_version, v_header.business_id, p_branch, v_active,
    v_earn, v_stamp, v_expiry_mode, v_expiry_days
  )
  on conflict (config_version_id, branch_id) do update set
    active = excluded.active,
    earn_points_per_dollar = excluded.earn_points_per_dollar,
    stamp_per_cents = excluded.stamp_per_cents,
    expiry_mode = excluded.expiry_mode,
    expiry_days = excluded.expiry_days;

  perform app.refresh_loyalty_config_snapshot(p_config_version);
  select snapshot_hash into v_hash
    from public.firm_config_versions
   where id = p_config_version;

  return json_build_object(
    'config_version_id', p_config_version,
    'branch_id', p_branch,
    'status', 'draft',
    'snapshot_hash', v_hash
  );
end $$;

create or replace function public.remove_loyalty_branch_override_draft(
  p_config_version uuid,
  p_branch uuid,
  p_expected_snapshot_hash text default null
)
returns json
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_header public.firm_config_versions%rowtype;
  v_hash text;
begin
  select * into v_header
    from public.firm_config_versions
   where id = p_config_version
   for update;

  if not found or not app.is_salon_owner(v_header.business_id) then
    raise exception 'owner only' using errcode = '42501';
  end if;
  if v_header.status <> 'draft' then
    raise exception 'only a draft branch override may be edited' using errcode = '42501';
  end if;
  if p_expected_snapshot_hash is not null
     and v_header.snapshot_hash is distinct from p_expected_snapshot_hash then
    raise exception 'draft configuration changed; reload before saving'
      using errcode = '40001';
  end if;
  if not exists (
    select 1 from public.branches b
     where b.id = p_branch
       and b.business_id = v_header.business_id
  ) then
    raise exception 'branch does not belong to this business' using errcode = '42501';
  end if;

  delete from public.loyalty_branch_overrides
   where config_version_id = p_config_version
     and business_id = v_header.business_id
     and branch_id = p_branch;

  perform app.refresh_loyalty_config_snapshot(p_config_version);
  select snapshot_hash into v_hash
    from public.firm_config_versions
   where id = p_config_version;

  return json_build_object(
    'config_version_id', p_config_version,
    'branch_id', p_branch,
    'status', 'draft',
    'snapshot_hash', v_hash
  );
end $$;

revoke all on function public.save_loyalty_branch_override_draft(uuid,uuid,jsonb,text)
  from public, anon;
revoke all on function public.remove_loyalty_branch_override_draft(uuid,uuid,text)
  from public, anon;
grant execute on function public.save_loyalty_branch_override_draft(uuid,uuid,jsonb,text)
  to authenticated;
grant execute on function public.remove_loyalty_branch_override_draft(uuid,uuid,text)
  to authenticated;

commit;
