-- FRENLY v36 - SAFE DRAFT REWARD EDITOR
--
-- Local review candidate. This does not apply production migrations. It closes
-- the v25-v35 review finding where draft reward-version rows were visible but
-- their branch/service/product eligibility children were active-only, allowing
-- the browser to accidentally replace a restricted reward with unrestricted
-- eligibility.

begin;

drop policy if exists loyalty_reward_versions_read on public.loyalty_reward_versions;
create policy loyalty_reward_versions_read on public.loyalty_reward_versions
  for select to authenticated
  using (
    app.is_salon_member(business_id)
    and exists (
      select 1
        from public.businesses b
       where b.id = loyalty_reward_versions.business_id
         and b.active_config_version_id = loyalty_reward_versions.config_version_id
    )
  );

create or replace function public.get_loyalty_reward_draft(p_config_version uuid)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_header public.firm_config_versions%rowtype;
  v_payload jsonb;
begin
  select * into v_header
    from public.firm_config_versions
   where id = p_config_version
   for share;

  if not found or not app.is_salon_owner(v_header.business_id) then
    raise exception 'owner only' using errcode = '42501';
  end if;
  if v_header.status <> 'draft' then
    raise exception 'only draft reward configurations can be read through this endpoint'
      using errcode = '42501';
  end if;

  perform 1
    from public.businesses
   where id = v_header.business_id
   for share;

  select jsonb_build_object(
    'config_version_id', v_header.id,
    'business_id', v_header.business_id,
    'version_no', v_header.version_no,
    'status', v_header.status,
    'source', v_header.source,
    'snapshot_hash', v_header.snapshot_hash,
    'program', (
      select jsonb_build_object(
        'config_version_id', lp.config_version_id,
        'business_id', lp.business_id,
        'kind', lp.kind,
        'loyalty_model', lp.loyalty_model,
        'active', lp.active,
        'earn_points_per_dollar', lp.earn_points_per_dollar,
        'redeem_points', lp.redeem_points,
        'reward_credit_cents', lp.reward_credit_cents,
        'stamp_target', lp.stamp_target,
        'stamp_per_cents', lp.stamp_per_cents,
        'tier_basis', lp.tier_basis,
        'expiry_mode', lp.expiry_mode,
        'expiry_days', lp.expiry_days,
        'configuration_status', 'draft'
      )
        from public.loyalty_program_versions lp
       where lp.config_version_id = v_header.id
         and lp.business_id = v_header.business_id
    ),
    'tiers', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', tv.id,
        'tier_id', tv.tier_id,
        'config_version_id', tv.config_version_id,
        'business_id', tv.business_id,
        'name', tv.name,
        'threshold', tv.threshold,
        'points_multiplier', tv.points_multiplier,
        'perk_note', tv.perk_note,
        'sort', tv.sort,
        'active', tv.active,
        'created_at', tv.created_at
      ) order by tv.threshold, tv.sort, tv.tier_id)
        from public.loyalty_tier_versions tv
       where tv.config_version_id = v_header.id
         and tv.business_id = v_header.business_id
    ), '[]'::jsonb),
    'rewards', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', rv.reward_id,
        'reward_id', rv.reward_id,
        'reward_version_id', rv.id,
        'business_id', rv.business_id,
        'config_version_id', rv.config_version_id,
        'name', rv.internal_name,
        'internal_name', rv.internal_name,
        'customer_name', rv.customer_name,
        'description', rv.description,
        'fulfillment_kind', rv.fulfillment_kind,
        'taxonomy_label', rv.taxonomy_label,
        'cost_points', rv.cost_points,
        'credit_cents', rv.credit_cents,
        'estimated_cost_cents', rv.estimated_cost_cents,
        'active', rv.active,
        'sort', rv.sort,
        'claim_available_from', rv.claim_available_from,
        'claim_available_until', rv.claim_available_until,
        'entitlement_expiry_days', rv.entitlement_expiry_days,
        'instructions', rv.instructions,
        'terms', rv.terms,
        'image_ref', rv.image_ref,
        'usage_limit', rv.usage_limit,
        'created_at', rv.created_at,
        'eligibility', jsonb_build_object(
          'branches', coalesce((
            select jsonb_agg(e.branch_id order by e.branch_id)
              from public.loyalty_reward_branches e
             where e.reward_version_id = rv.id
               and e.reward_id = rv.reward_id
               and e.business_id = rv.business_id
          ), '[]'::jsonb),
          'services', coalesce((
            select jsonb_agg(e.service_id order by e.service_id)
              from public.loyalty_reward_services e
             where e.reward_version_id = rv.id
               and e.reward_id = rv.reward_id
               and e.business_id = rv.business_id
          ), '[]'::jsonb),
          'products', coalesce((
            select jsonb_agg(e.product_id order by e.product_id)
              from public.loyalty_reward_products e
             where e.reward_version_id = rv.id
               and e.reward_id = rv.reward_id
               and e.business_id = rv.business_id
          ), '[]'::jsonb)
        )
      ) order by rv.sort, rv.created_at, rv.reward_id)
        from public.loyalty_reward_versions rv
       where rv.config_version_id = v_header.id
         and rv.business_id = v_header.business_id
    ), '[]'::jsonb)
  ) into v_payload;

  return v_payload;
end $$;

revoke all on function public.get_loyalty_reward_draft(uuid) from public, anon;
grant execute on function public.get_loyalty_reward_draft(uuid) to authenticated;

drop function public.save_loyalty_config_draft(uuid,jsonb);

create or replace function public.save_loyalty_config_draft(
  p_version uuid,
  p_config jsonb,
  p_expected_snapshot_hash text
)
returns json
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_header public.firm_config_versions%rowtype;
  v_typed public.loyalty_program_versions%rowtype;
  v_hash text;
  v_tier jsonb;
  v_tier_id uuid;
begin
  select * into v_header
    from public.firm_config_versions
   where id = p_version
   for update;

  if not found or not app.is_salon_owner(v_header.business_id) then
    raise exception 'owner only' using errcode = '42501';
  end if;
  if v_header.status <> 'draft' then
    raise exception 'only a draft may be edited';
  end if;
  if p_expected_snapshot_hash is not null
     and v_header.snapshot_hash is distinct from p_expected_snapshot_hash then
    raise exception 'draft configuration changed; reload before saving'
      using errcode = '40001';
  end if;

  select * into v_typed
    from public.loyalty_program_versions
   where config_version_id = p_version;

  update public.loyalty_program_versions set
    kind = coalesce(p_config->>'kind', v_typed.kind),
    loyalty_model = coalesce(p_config->>'loyalty_model', v_typed.loyalty_model),
    active = coalesce((p_config->>'active')::boolean, v_typed.active),
    earn_points_per_dollar = coalesce((p_config->>'earn_points_per_dollar')::numeric, v_typed.earn_points_per_dollar),
    redeem_points = coalesce((p_config->>'redeem_points')::integer, v_typed.redeem_points),
    reward_credit_cents = coalesce((p_config->>'reward_credit_cents')::integer, v_typed.reward_credit_cents),
    stamp_target = case when p_config ? 'stamp_target' then (p_config->>'stamp_target')::integer else v_typed.stamp_target end,
    stamp_per_cents = case when p_config ? 'stamp_per_cents' then (p_config->>'stamp_per_cents')::integer else v_typed.stamp_per_cents end,
    tier_basis = coalesce(p_config->>'tier_basis', v_typed.tier_basis),
    expiry_mode = coalesce(p_config->>'expiry_mode', v_typed.expiry_mode),
    expiry_days = case when p_config ? 'expiry_days' then (p_config->>'expiry_days')::integer else v_typed.expiry_days end
   where config_version_id = p_version;

  if p_config ? 'reward' then
    if jsonb_typeof(p_config->'reward') <> 'object' then
      raise exception 'reward must be a JSON object' using errcode = '22023';
    end if;
    perform public.save_loyalty_reward_draft(
      p_version,
      nullif(p_config->'reward'->>'id', '')::uuid,
      p_config->'reward',
      jsonb_build_object(
        'branches', coalesce(p_config->'reward_branch_ids', '[]'::jsonb),
        'services', coalesce(p_config->'reward_service_ids', '[]'::jsonb),
        'products', coalesce(p_config->'reward_product_ids', '[]'::jsonb)
      )
    );
  elsif p_config ? 'reward_branch_ids' or p_config ? 'reward_service_ids' or p_config ? 'reward_product_ids' then
    raise exception 'eligibility requires a reward envelope' using errcode = '22023';
  end if;

  if p_config ? 'tier' then
    v_tier := p_config->'tier';
    if jsonb_typeof(v_tier) <> 'object' then
      raise exception 'tier must be an object' using errcode = '22023';
    end if;
    if exists (
      select 1 from jsonb_object_keys(v_tier) k
       where k not in ('id','name','threshold','points_multiplier','perk_note','sort','active')
    ) then
      raise exception 'tier contains unsupported fields' using errcode = '22023';
    end if;
    v_tier_id := coalesce(nullif(v_tier->>'id', '')::uuid, gen_random_uuid());
    if nullif(btrim(v_tier->>'name'), '') is null
       or coalesce((v_tier->>'threshold')::integer, -1) < 0
       or coalesce((v_tier->>'points_multiplier')::numeric, 0) < 1 then
      raise exception 'tier requires a name, non-negative threshold and multiplier of at least 1'
        using errcode = '22023';
    end if;
    insert into public.loyalty_tier_versions
      (tier_id, config_version_id, business_id, name, threshold, points_multiplier, perk_note, sort, active)
    values (
      v_tier_id, p_version, v_header.business_id, btrim(v_tier->>'name'),
      (v_tier->>'threshold')::integer, (v_tier->>'points_multiplier')::numeric,
      nullif(btrim(v_tier->>'perk_note'), ''), coalesce((v_tier->>'sort')::integer, 0),
      coalesce((v_tier->>'active')::boolean, true)
    )
    on conflict (tier_id, config_version_id) do update set
      name = excluded.name,
      threshold = excluded.threshold,
      points_multiplier = excluded.points_multiplier,
      perk_note = excluded.perk_note,
      sort = excluded.sort,
      active = excluded.active;
  end if;

  perform app.refresh_loyalty_config_snapshot(p_version);
  select snapshot_hash into v_hash
    from public.firm_config_versions
   where id = p_version;

  return json_build_object('version_id', p_version, 'status', 'draft', 'snapshot_hash', v_hash);
end $$;

revoke all on function public.save_loyalty_config_draft(uuid,jsonb,text) from public, anon;
grant execute on function public.save_loyalty_config_draft(uuid,jsonb,text) to authenticated;

-- Internal compatibility only for older SECURITY DEFINER code paths in this
-- local phase, notably v35's recommendation generator. Browser roles must not
-- be able to execute this stale-hash bypass directly.
create or replace function public.save_loyalty_config_draft(p_version uuid, p_config jsonb)
returns json
language sql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$ select public.save_loyalty_config_draft(p_version, p_config, null::text) $$;

revoke all on function public.save_loyalty_config_draft(uuid,jsonb)
  from public, anon, authenticated;

commit;
