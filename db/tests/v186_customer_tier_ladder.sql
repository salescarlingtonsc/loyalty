-- v186 rolled-back verification — the customer tier ladder.
--
-- Run against production. Every mutation is inside the transaction and the file ends in
-- `rollback;`. Assertions:
--   1. the ladder lists every effective tier, lowest rung first, scoped to the tenant;
--   2. `current` is the server's own placement and exactly one rung carries it;
--   3. `achieved` follows the customer's real metric;
--   4. a tier outside its effective window never appears;
--   5. the pre-v186 contract (current / next / progress_percent / basis / metric) is intact.
--
-- The function reads auth.uid(), so this drives it as the customer by setting the request JWT
-- claims for the transaction — the same path PostgREST uses.

begin;

do $test$
declare
  v_biz uuid;
  v_user uuid;
  v_out jsonb;
  v_tiers jsonb;
  v_expected integer;
  v_tier uuid := gen_random_uuid();
  v_config uuid;
begin
  select link.business_id, link.auth_user_id into v_biz, v_user
    from public.customer_links link
    join public.loyalty_programs program
      on program.business_id = link.business_id and program.active
    join public.loyalty_tiers tier on tier.business_id = link.business_id
   where link.state = 'verified' and link.auth_user_id is not null
   group by link.business_id, link.auth_user_id
  having count(distinct tier.id) >= 2
   limit 1;
  if v_biz is null then
    raise notice 'v186: no verified customer on a multi-tier programme; skipping';
    return;
  end if;

  -- Read the expectation with the definer's visibility BEFORE dropping to the customer role:
  -- loyalty_tiers is RLS-protected, so the same count as `authenticated` would read zero and the
  -- comparison would pass for the wrong reason.
  select count(*) into v_expected from public.loyalty_tiers t
   where t.business_id = v_biz
     and (t.effective_from is null or t.effective_from <= statement_timestamp())
     and (t.expires_at is null or t.expires_at > statement_timestamp());

  perform set_config('request.jwt.claims',
    json_build_object('sub', v_user::text, 'role', 'authenticated')::text, true);
  perform set_config('role', 'authenticated', true);
  v_out := public.customer_get_effective_tier_v143(v_biz);
  v_tiers := v_out #> '{tier,tiers}';
  perform set_config('role', 'postgres', true);

  -- 1. every effective tier, lowest rung first
  assert jsonb_typeof(v_tiers) = 'array', 'tiers must be an array';
  assert jsonb_array_length(v_tiers) = v_expected,
    format('ladder %s must equal effective tiers %s', jsonb_array_length(v_tiers), v_expected);
  assert (select bool_and(current_value >= previous_value) from (
      select (rung->>'threshold')::numeric current_value,
             lag((rung->>'threshold')::numeric) over (order by ordinality) previous_value
        from jsonb_array_elements(v_tiers) with ordinality item(rung, ordinality)) ordered
      where previous_value is not null), 'the ladder must run lowest rung first';

  -- 2. exactly one current rung, and it is the one the function itself resolved
  assert (select count(*) from jsonb_array_elements(v_tiers) rung
           where (rung->>'current')::boolean) <= 1,
    'at most one rung may be the customer''s own tier';
  if v_out #>> '{tier,current,id}' is not null then
    assert (select count(*) from jsonb_array_elements(v_tiers) rung
             where (rung->>'current')::boolean
               and rung->>'id' = v_out #>> '{tier,current,id}') = 1,
      'the current flag must match the tier the function resolved';
  end if;

  -- 3. achieved follows the real metric, and every rung carries its own benefits
  assert (select bool_and(((rung->>'threshold')::numeric <= (v_out #>> '{tier,metric}')::numeric)
                          = (rung->>'achieved')::boolean)
            from jsonb_array_elements(v_tiers) rung),
    'achieved must be threshold <= metric, never a client guess';
  assert (select bool_and(jsonb_typeof(rung->'benefits') = 'array')
            from jsonb_array_elements(v_tiers) rung),
    'every rung must carry its own benefits array';

  -- 4. a tier scheduled for the future is not offered. loyalty_tiers.effective_from is PROJECTED
  -- from the active config version by app.v143_project_tier_window, so the fixture has to create
  -- the version row — writing the column directly is silently overwritten.
  select active_config_version_id into v_config from public.businesses where id = v_biz;
  insert into public.loyalty_tier_versions
    (tier_id, config_version_id, business_id, name, threshold, points_multiplier, perk_note, sort,
     active, effective_from)
  values (v_tier, v_config, v_biz, 'v186 future tier', 999999, 1, 'Not yet', 99, true,
          statement_timestamp() + interval '30 days');
  insert into public.loyalty_tiers (id, business_id, name, threshold, sort, perk_note)
  values (v_tier, v_biz, 'v186 future tier', 999999, 99, 'Not yet');
  assert (select effective_from from public.loyalty_tiers where id = v_tier) > statement_timestamp(),
    'the window trigger must have projected the future date';
  perform set_config('role', 'authenticated', true);
  assert (select count(*) from jsonb_array_elements(
            public.customer_get_effective_tier_v143(v_biz) #> '{tier,tiers}') rung
           where rung->>'label' = 'v186 future tier') = 0,
    'a tier scheduled for the future must not appear in the ladder';
  perform set_config('role', 'postgres', true);

  -- 5. the pre-v186 contract is intact
  assert v_out #> '{tier}' ? 'progress_percent';
  assert v_out #> '{tier}' ? 'basis';
  assert v_out #> '{tier}' ? 'metric';
  assert v_out #> '{tier}' ? 'next';
  assert v_out #> '{tier}' ? 'label';

  raise notice 'v186 verification passed: % rungs', jsonb_array_length(v_tiers);
end $test$;

rollback;
