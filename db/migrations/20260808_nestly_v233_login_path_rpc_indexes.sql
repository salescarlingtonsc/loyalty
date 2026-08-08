-- Nestly v233 — the signed-in critical path stops asking the same question a thousand times.
--
-- Three RPCs fire on every authenticated page load and together own the top of
-- pg_stat_statements:
--
--   public.customer_get_actionable_wallet()   377ms mean over 309 calls  (116s total)
--   public.get_my_modules(uuid)               155ms and 230ms mean       (129s total)
--   public.get_my_personas()                   69ms mean over 1373 calls  (94s total)
--
-- None of that is data volume. Production today holds 10 businesses, 13 active
-- staff, 11 active branches, 38 sales and 38 points_ledger rows; every hot table
-- is a single 8kB page and every measured plan reported 100% shared *hits* with
-- zero reads. `explain (analyze, buffers)` on get_my_modules returned
-- `Result (actual time=667.279..667.280 rows=1) Buffers: shared hit=3724` — 3724
-- buffer touches to answer a question about ~20 rows. The cost is the *number of
-- statement executions*, not the cost of any one of them.
--
-- Two distinct defects produce it.
--
-- (1) COMBINATORIAL RE-ASKING. app.staff_module_perms_at_v115 resolves each module
--     key independently through staff_module_mode_at_or_any_v117 -> per active
--     branch -> staff_module_mode_v94, and each of those re-derives the *same*
--     invariants from scratch: is the workspace open, who is the actor, can the
--     actor see this branch, what does the platform override say. For the demo
--     tenant (21 modules x 2 branches) that is ~23 SPI executions per module,
--     ~480 per call. Measured: app.staff_module_perms_at_v115 = 324.8ms, of which
--     one app.staff_module_mode_at_or_any_v117 = 8.7ms and one
--     app.business_workspace_open_v94 = 0.36ms.
--
--     None of those invariants vary by module. The workspace flag is one boolean
--     per call, branch visibility is one boolean per branch, and the platform
--     override resolution is a plain lookup. Hoisting them and resolving all
--     modules in a single set-based pass turns ~480 statement executions into
--     roughly a dozen. Verified against production read-only, by running the
--     replacement body as a plain parameterised query and comparing to the live
--     function: 23/23 byte-identical jsonb across every real (staff user,
--     business, branch scope) case, 12 of them with an explicit non-null
--     p_branch. Mean 221.4ms -> 19.5ms (11.4x) on the null-branch form.
--
-- (2) THE SAME EXPENSIVE EXPRESSION EVALUATED FIVE TIMES OVER. In
--     customer_get_actionable_wallet the wallet card is produced by a LATERAL
--     subquery, then referenced twice in the projection and again inside five
--     ORDER BY keys. The planner flattens the LATERAL, so `base.card` is not a
--     stored value — it is a macro. The production plan makes this explicit; the
--     Sort Key alone contains ten separate app.c44_actionable_wallet_card(...)
--     invocations:
--
--       Aggregate (actual time=1034.117..1034.122 rows=1) Buffers: shared hit=4571
--         -> WindowAgg (actual time=964.711..1033.795 rows=3)
--              Sort Key: (((app.c44_actionable_wallet_card(...) || jsonb_build_object(
--                'business', (COALESCE((app.c44_actionable_wallet_card(...) -> 'business'),
--                '{}') || ...))) #>> '{action,sort_band}'))::integer, ... [x5 keys]
--              -> Hash Left Join (actual time=411.334..921.593 rows=3)
--                   -> Function Scan on v32_customer_wallet_context (actual time=136.337..136.341 rows=3)
--
--     Three cards. One card costs ~49ms to build (measured:
--     app.c45_base_actionable_wallet_card for all three businesses = 146.5ms).
--     Three cards should cost ~147ms; the join node spent 785ms. That is ~5.3x
--     redundant evaluation of an already-expensive function.
--
--     Materialising the cards behind an `as materialized` CTE fence forces one
--     evaluation per row and changes nothing else. Verified read-only against
--     production: `cards` and `truncated` compare exactly equal to the live
--     function's output, 1036.7ms -> 270.7ms (3.8x).
--
--     The same fan-out as (1) also sits inside app.v32_customer_wallet_context,
--     which calls app.business_module_enabled_at_v117 once per module per
--     business (Function Scan above: 136ms for 3 businesses). Set-based
--     resolution verified across all 6 real wallet customers: 6/6 identical,
--     59.9ms -> 5.5ms.
--
-- (3) public.get_my_modules and public.get_my_modules_at_v115 each call the module
--     resolver TWICE — once to derive `modules` and once for `module_perms` —
--     literally doubling the most expensive thing they do. Measured:
--     get_my_modules = 585.7ms against 324.8ms for one resolver call. Both are
--     rewritten to evaluate it once into a local variable. `modules` remains the
--     sorted key list of exactly that jsonb, so the payload is unchanged.
--
-- WHAT THIS MIGRATION DELIBERATELY DOES NOT DO
--
-- It does not add the indexes the performance advisor suggests for these tables.
-- The advisor reports 698 unindexed_foreign_keys; on the tables these three RPCs
-- touch (sales, points_ledger, points_batches, credit_ledger, customer_links,
-- client_packages, loyalty_redemptions, ...) every measured plan was already a
-- 100%-cached index or single-page scan. An index that a plan does not ask for is
-- write amplification with no read benefit, so none are proposed.
--
-- Exactly one index is proposed, and only because a plan node asked for it: the
-- driving query of get_my_personas filters public.staff on (user_id, active) with
-- no business_id, and production shows
--   Seq Scan on staff staff_row
--     Filter: (active AND (user_id = ...auth.uid()...))
--     Rows Removed by Filter: 12
-- The existing staff_salon_id_user_id_key is (business_id, user_id), so it cannot
-- serve a business-agnostic lookup. At 10 businesses the scan is free; at the
-- several hundred onboarding tenants this is sized for, get_my_personas is the
-- single most-called RPC on the login path (1373 calls) and would scan the whole
-- staff table every time.
--
-- SECURITY POSTURE IS UNCHANGED. Every function keeps its exact volatility,
-- SECURITY DEFINER marking and `set search_path`. The
-- "authenticated customer session required" guard in
-- customer_get_actionable_wallet, the platform_feature_enabled gates, the
-- app.can_see_branch branch-visibility check, the customer_links `state =
-- 'verified'` requirement and the identity `status = 'active'` requirement are
-- all preserved verbatim. app.can_see_branch is now evaluated once per branch
-- instead of once per (module, branch) — fewer calls, identical decisions, and it
-- still gates every branch scope before a mode can be granted.
--
-- IDEMPOTENCY. All function changes are `create or replace` and safe to re-run.
-- The index uses `if not exists`.
--
-- ============================================================================
-- PART 1 — INDEX.  MUST RUN OUTSIDE ANY TRANSACTION BLOCK.
--
-- CREATE INDEX CONCURRENTLY cannot run inside a transaction block. Do NOT wrap
-- this statement in begin/commit and do NOT paste it into the same transaction
-- as Part 2. Run Part 1 first, on its own, then run Part 2. If a CONCURRENTLY
-- build is interrupted it leaves an INVALID index behind: check with
--   select indexrelid::regclass from pg_index where not indisvalid;
-- and drop it before retrying.
-- ============================================================================

create index concurrently if not exists staff_user_active_idx
  on public.staff (user_id)
  where active;

comment on index public.staff_user_active_idx is
  'v233: get_my_personas resolves an actor''s memberships across all tenants and '
  'therefore filters staff on (user_id, active) with no business_id, which '
  'staff_salon_id_user_id_key (business_id, user_id) cannot serve. Production '
  'plan before this index: Seq Scan on staff, Rows Removed by Filter: 12. '
  'Write cost: one extra btree entry per staff insert and per update touching '
  'user_id or active — a rare, human-paced write path (invites, deactivations, '
  'seat changes), so amplification is negligible against 1373+ reads.';

-- ============================================================================
-- PART 2 — FUNCTIONS.  Transactional; run as one unit.
--
-- APPLIED to production 2026-08-08 as migration `nestly_v233_login_path_rpc_perf`
-- after owner approval. Post-apply verification: all five body_md5 changed;
-- prosecdef / provolatile / search_path / proacl byte-identical; the anon wallet
-- path still raises 28000; 4 real staff and 3 real wallet customers returned their
-- expected payloads. Steady state after: get_my_modules 18.6ms (was 155-230ms),
-- customer_get_actionable_wallet 55.4ms (was 377ms).
--
-- LATENT COUPLING, recorded by the v233 differential verification. The override
-- lookups below read platform_module_overrides_v94 through SCALAR SUBQUERIES,
-- whereas the bodies they replace used plpgsql `select ... into`. The two agree
-- only while at most one override row can exist per (business, branch_scope,
-- module_key) — which is guaranteed today by the unique partial indexes
-- platform_module_overrides_v94_branch_uk and _firm_uk. If either index is ever
-- dropped, a duplicate row makes permission resolution raise 21000 instead of
-- silently picking an arbitrary row. That is the safe direction (fail closed,
-- not fail open), but do not drop those indexes without revisiting this.
-- ============================================================================

begin;

-- ----------------------------------------------------------------------------
-- app.staff_module_perms_at_v115 — resolve every module in one pass.
--
-- The per-module recursion into staff_module_mode_at_or_any_v117 /
-- staff_module_mode_v94 / effective_platform_module_mode_v94 is replaced by the
-- same decision expressed relationally. The rules are reproduced exactly:
--
--   * workspace closed                       -> disabled  (business_workspace_open_v94)
--   * no active staff row for the actor      -> disabled  (cross join actor_staff)
--   * branch scope the actor cannot see      -> disabled  (can_see_branch)
--   * platform mode disabled                 -> disabled  (branch override, then
--                                                          firm override, then
--                                                          sector entitlement;
--                                                          customerintel always
--                                                          disabled)
--   * owner                                  -> the platform mode verbatim
--   * module_perms present                   -> module_perms->>key, else disabled
--   * modules null or key in modules         -> rw, else disabled
--   * either side read-only                  -> r, otherwise rw
--   * a module is granted if ANY visible scope grants it, rw winning over r
--
-- and so is the outer projection filter (owner-only modules; finance modules
-- gated on view_finance via app.role_perms).
--
-- Branch-scope selection matches staff_module_mode_at_or_any_v117 exactly: an
-- explicit p_branch is the only scope; otherwise every active branch; and if the
-- business has no active branch at all, the single null scope — which is the one
-- case where staff_module_mode_v94 skips its can_see_branch check, mirrored here
-- by the `branch_id is not null` guard.
--
-- Note the outer can_see_branch filter that at_or_any applies before calling
-- staff_module_mode_v94 is redundant with the check inside it: an invisible
-- branch either disappears from the candidate set or contributes 'disabled', and
-- both bool_or paths yield 'disabled'. It is retained here as `visible` rather
-- than dropped, so the check still runs — just once per branch.
-- ----------------------------------------------------------------------------
create or replace function app.staff_module_perms_at_v115(
  p_business uuid,
  p_branch uuid default null
)
returns jsonb
language sql
stable
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
  with actor_staff as (
    select staff_row.*
    from public.staff staff_row
    where staff_row.business_id=p_business
      and staff_row.user_id=auth.uid()
      and staff_row.active
    order by case when staff_row.role='owner' then 0 else 1 end,
      staff_row.created_at,staff_row.id
    limit 1
  ),
  workspace as (
    select app.business_workspace_open_v94(p_business) as is_open
  ),
  module_keys as (
    select unnest(coalesce(business.enabled_modules,'{}'::text[])) module_key
    from public.businesses business
    where business.id=p_business
    union
    select override_row.module_key
    from public.platform_module_overrides_v94 override_row
    where override_row.business_id=p_business
  ),
  -- One branch-visibility decision per branch, not per (module, branch).
  branch_scopes as (
    select p_branch as branch_id,
      app.can_see_branch(p_business,p_branch) as visible
    where p_branch is not null
    union all
    select branch.id, app.can_see_branch(p_business,branch.id)
    from public.branches branch
    where p_branch is null
      and branch.business_id=p_business
      and branch.active
    union all
    select null::uuid, true
    where p_branch is null
      and not exists(
        select 1 from public.branches branch
        where branch.business_id=p_business
          and branch.active
      )
  ),
  -- app.effective_platform_module_mode_v94, expressed as a lookup.
  scoped as (
    select module_keys.module_key, branch_scopes.branch_id, branch_scopes.visible,
      case when module_keys.module_key='customerintel' then 'disabled'
      else coalesce(
        (select override_row.mode
           from public.platform_module_overrides_v94 override_row
          where override_row.business_id=p_business
            and override_row.branch_scope=branch_scopes.branch_id
            and override_row.module_key=module_keys.module_key
            and override_row.mode<>'inherit'),
        (select override_row.mode
           from public.platform_module_overrides_v94 override_row
          where override_row.business_id=p_business
            and override_row.branch_scope is null
            and override_row.module_key=module_keys.module_key
            and override_row.mode<>'inherit'),
        (select case when module_keys.module_key=any(business.enabled_modules)
                  then 'rw' else 'disabled' end
           from public.businesses business
          where business.id=p_business)
      ) end as platform_mode
    from module_keys
    cross join branch_scopes
  ),
  -- app.staff_module_mode_v94, expressed as a case.
  scoped_modes as (
    select scoped.module_key,
      case
        when not coalesce(workspace.is_open,false) then 'disabled'
        when scoped.branch_id is not null
             and not coalesce(scoped.visible,false) then 'disabled'
        when coalesce(scoped.platform_mode,'disabled')='disabled' then 'disabled'
        when actor_staff.role='owner' then scoped.platform_mode
        when staff_mode.mode='disabled' then 'disabled'
        when scoped.platform_mode='r' or staff_mode.mode='r' then 'r'
        else 'rw'
      end as access_mode,
      actor_staff.role
    from scoped
    cross join workspace
    cross join actor_staff
    cross join lateral (
      select case
        when actor_staff.module_perms is not null
          then coalesce(actor_staff.module_perms->>scoped.module_key,'disabled')
        when actor_staff.modules is null
          or scoped.module_key=any(actor_staff.modules) then 'rw'
        else 'disabled'
      end as mode
    ) staff_mode
  ),
  -- app.staff_module_mode_at_or_any_v117's aggregate: rw beats r beats disabled.
  resolved as (
    select scoped_modes.module_key,
      case
        when bool_or(scoped_modes.access_mode='rw') then 'rw'
        when bool_or(scoped_modes.access_mode='r') then 'r'
        else 'disabled'
      end as access_mode,
      min(scoped_modes.role) as role
    from scoped_modes
    group by scoped_modes.module_key
  )
  select coalesce(
    jsonb_object_agg(resolved.module_key,resolved.access_mode)
      filter(where resolved.access_mode in ('r','rw')
        and (
          resolved.role='owner'
          or resolved.module_key not in ('branches','settings','setup')
        )
        and (
          resolved.module_key not in ('expenses','pnl')
          or 'view_finance'=any(app.role_perms(resolved.role))
        )
      ),
    '{}'::jsonb
  )
  from resolved
$$;

comment on function app.staff_module_perms_at_v115(uuid,uuid) is
  'v233: resolves every module key in one set-based pass instead of recursing '
  'per module into staff_module_mode_at_or_any_v117. Decision rules, branch '
  'visibility and the owner/finance projection filters are unchanged; only the '
  'number of statement executions is. Verified byte-identical across all 11 '
  'production (staff user, business) pairs, 221.4ms -> 19.5ms mean.';

-- ----------------------------------------------------------------------------
-- public.get_my_modules — stop resolving the module set twice.
--
-- `modules` was app.staff_modules(p_business), which is the sorted key list of
-- app.staff_module_perms(p_business), which is app.staff_module_perms_at_v115(
-- p_business, null) — the exact value already being computed for `module_perms`.
--
-- plpgsql, not sql, on purpose: a `language sql` body that referenced a single
-- resolver result twice would be inlined and the reference duplicated, which is
-- precisely the defect being fixed in customer_get_actionable_wallet below. A
-- local variable is unambiguous. Volatility, security and search_path are
-- unchanged, and the returned json keeps the same keys, types and ordering.
-- ----------------------------------------------------------------------------
create or replace function public.get_my_modules(p_business uuid)
returns json
language plpgsql
stable
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare
  v_perms jsonb;
begin
  v_perms := app.staff_module_perms_at_v115(p_business,null);
  return json_build_object(
    'modules', to_json(coalesce(
      (select array_agg(k order by k)
         from jsonb_object_keys(v_perms) as keys(k)),
      array[]::text[]
    )),
    'module_perms', v_perms,
    'role', (select s.role from public.staff s
              where s.business_id = p_business and s.user_id = auth.uid() and s.active
              order by case when s.role = 'owner' then 0 else 1 end, s.created_at limit 1),
    'is_super_admin', app.is_super_admin()
  );
end
$$;

comment on function public.get_my_modules(uuid) is
  'v233: resolves the module set once rather than twice (app.staff_modules and '
  'app.staff_module_perms both funnelled into staff_module_perms_at_v115). '
  'Payload unchanged. Measured 585.7ms against 324.8ms for a single resolver '
  'call before the v233 resolver rewrite.';

-- ----------------------------------------------------------------------------
-- public.get_my_modules_at_v115 — the same double resolution, same fix.
-- ----------------------------------------------------------------------------
create or replace function public.get_my_modules_at_v115(p_business uuid, p_branch uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare
  v_perms jsonb;
begin
  v_perms := app.staff_module_perms_at_v115(p_business,p_branch);
  return jsonb_build_object(
    'business_id',p_business,
    'branch_id',p_branch,
    'modules',coalesce((
      select jsonb_agg(entry.key order by entry.key)
      from jsonb_each_text(v_perms) entry
    ),'[]'::jsonb),
    'module_perms',v_perms,
    'role',(
      select staff_row.role
      from public.staff staff_row
      where staff_row.business_id=p_business
        and staff_row.user_id=auth.uid()
        and staff_row.active
      order by case when staff_row.role='owner' then 0 else 1 end,
        staff_row.created_at,staff_row.id
      limit 1
    ),
    'is_super_admin',app.is_super_admin()
  );
end
$$;

comment on function public.get_my_modules_at_v115(uuid,uuid) is
  'v233: single module-resolver evaluation; payload unchanged.';

-- ----------------------------------------------------------------------------
-- app.v32_customer_wallet_context — resolve module enablement set-based.
--
-- The per-row `array(... where app.business_module_enabled_at_v117(...))`
-- evaluated that function once per module per business, and each call re-walked
-- the branch list through effective_platform_module_mode_v94. The replacement
-- inlines the same decision: workspace open, and at least one branch scope whose
-- resolved platform mode is r or rw — active branches when the business has any,
-- otherwise the single null scope, exactly as business_module_enabled_at_v117
-- does. customerintel remains unconditionally disabled.
--
-- Every guard above the query is untouched: authenticated session required,
-- customer_wallet feature gate, active customer identity required, and the
-- verified-link / active-identity join conditions.
-- ----------------------------------------------------------------------------
create or replace function app.v32_customer_wallet_context(
  p_business_slug text default null
)
returns table(identity_id uuid, business_id uuid, client_id uuid,
  business_name text, business_slug text, business_industry text,
  business_currency text, enabled_modules text[])
language plpgsql
stable
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare
  v_actor uuid:=auth.uid();
  v_slug text:=nullif(lower(btrim(coalesce(p_business_slug,''))),'');
begin
  if v_actor is null then
    raise exception 'authenticated customer session required'
      using errcode='28000';
  end if;
  if not app.platform_feature_enabled('customer_wallet') then
    raise exception 'customer wallet is not enabled' using errcode='0A000';
  end if;
  perform 1
  from public.customer_identities identity
  where identity.auth_user_id=v_actor and identity.status='active';
  if not found then
    raise exception 'active customer identity required' using errcode='42501';
  end if;

  return query
  select identity.id,link.business_id,link.client_id,
    business.name,business.slug,business.industry,business.currency,
    coalesce((
      select array_agg(key.module_key order by key.module_key)
      from (
        select unnest(coalesce(business.enabled_modules,'{}'::text[])) module_key
        union
        select override_row.module_key
        from public.platform_module_overrides_v94 override_row
        where override_row.business_id=business.id
      ) key
      where app.business_workspace_open_v94(business.id)
        and exists(
          select 1
          from (
            select branch.id as branch_id
            from public.branches branch
            where branch.business_id=business.id and branch.active
            union all
            select null::uuid
            where not exists(
              select 1 from public.branches branch
              where branch.business_id=business.id and branch.active
            )
          ) scope
          where (case when key.module_key='customerintel' then 'disabled'
            else coalesce(
              (select override_row.mode
                 from public.platform_module_overrides_v94 override_row
                where override_row.business_id=business.id
                  and override_row.branch_scope=scope.branch_id
                  and override_row.module_key=key.module_key
                  and override_row.mode<>'inherit'),
              (select override_row.mode
                 from public.platform_module_overrides_v94 override_row
                where override_row.business_id=business.id
                  and override_row.branch_scope is null
                  and override_row.module_key=key.module_key
                  and override_row.mode<>'inherit'),
              (select case when key.module_key=any(inner_business.enabled_modules)
                        then 'rw' else 'disabled' end
                 from public.businesses inner_business
                where inner_business.id=business.id)
            ) end) in ('r','rw')
        )
    ),'{}'::text[])
  from public.customer_identities identity
  join public.customer_links link
    on link.identity_id=identity.id
   and link.auth_user_id=v_actor
   and link.state='verified'
  join public.businesses business on business.id=link.business_id
  where identity.auth_user_id=v_actor
    and identity.status='active'
    and (v_slug is null or business.slug=v_slug)
  order by business.slug,link.id;
end
$$;

comment on function app.v32_customer_wallet_context(text) is
  'v233: module enablement resolved set-based instead of one '
  'business_module_enabled_at_v117 call per module per business. Session, '
  'feature-flag and identity guards and the verified-link join are unchanged. '
  'Verified identical output for all 6 production wallet customers, '
  '59.9ms -> 5.5ms mean.';

-- ----------------------------------------------------------------------------
-- public.customer_get_actionable_wallet — build each card once.
--
-- The LATERAL producing `base.card` was flattened by the planner, so
-- app.c44_actionable_wallet_card was re-evaluated for every syntactic reference:
-- twice in the projection and again inside each of the five ORDER BY keys. Two
-- `as materialized` CTEs fence that off — the cards are built once, the sort keys
-- are extracted once from the built cards, and ranking and aggregation run over
-- stored values.
--
-- The 28000 "authenticated customer session required" guard, the
-- customer_actionable_wallet feature gate, the relationship-scoped logo join and
-- the 100-card bound with its 101st-row truncation probe are all preserved
-- exactly. Ordering is unchanged: sort_band, then deadline_at with nulls last,
-- then sort_units, then lower(name), then slug.
-- ----------------------------------------------------------------------------
create or replace function public.customer_get_actionable_wallet()
returns jsonb
language plpgsql
stable
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare
  v_as_of timestamptz := statement_timestamp();
  v_cards jsonb;
  v_truncated boolean := false;
begin
  if auth.uid() is null then
    raise exception 'authenticated customer session required' using errcode = '28000';
  end if;
  if not app.platform_feature_enabled('customer_actionable_wallet') then
    raise exception 'actionable customer wallet is not enabled' using errcode = '0A000';
  end if;

  -- Rank every verified relationship before the 100-card response bound. Logo
  -- media is joined to that same relationship context, never discovered from
  -- a caller-supplied business id or slug.
  with action_cards as materialized (
    select base.card || jsonb_build_object(
      'business',
      coalesce(base.card->'business', '{}'::jsonb)
        || jsonb_build_object(
          'logo_url', app.v95_public_media_url(logo.object_path)
        )
    ) as card
      from app.v32_customer_wallet_context(null) context
      cross join lateral (
        select app.c44_actionable_wallet_card(
          context.business_id, context.client_id, context.business_slug,
          context.business_name, context.business_industry,
          context.business_currency, context.enabled_modules, v_as_of
        ) as card
      ) base
      left join public.business_brand_presentation_v95 brand
        on brand.business_id = context.business_id
      left join public.business_media_assets_v95 logo
        on logo.id = brand.logo_asset_id
       and logo.business_id = context.business_id
       and logo.asset_kind = 'logo'
       and logo.customer_visible
  ),
  -- Extract the sort keys once from the built card, so the ORDER BY below
  -- cannot re-evaluate c44_actionable_wallet_card per key.
  keyed_cards as materialized (
    select action_cards.card,
      (action_cards.card#>>'{action,sort_band}')::integer as sort_band,
      nullif(action_cards.card#>>'{action,deadline_at}', '')::timestamptz as deadline_at,
      (action_cards.card#>>'{action,sort_units}')::integer as sort_units,
      lower(action_cards.card#>>'{business,name}') as business_name,
      action_cards.card#>>'{business,slug}' as business_slug
    from action_cards
  ),
  ranked as (
    select keyed_cards.card, row_number() over (
      order by keyed_cards.sort_band,
        keyed_cards.deadline_at nulls last,
        keyed_cards.sort_units,
        keyed_cards.business_name,
        keyed_cards.business_slug
    ) as action_rank
    from keyed_cards
  )
  select coalesce(jsonb_agg(ranked.card order by ranked.action_rank)
      filter (where ranked.action_rank <= 100), '[]'::jsonb),
    coalesce(bool_or(ranked.action_rank > 100), false)
    into v_cards, v_truncated
    from ranked
   where ranked.action_rank <= 101;

  return jsonb_build_object(
    'as_of', v_as_of,
    'cards', v_cards,
    'truncated', v_truncated
  );
end;
$$;

comment on function public.customer_get_actionable_wallet() is
  'v233: wallet cards are materialised once instead of being re-evaluated by '
  'every projection and ORDER BY reference (production plan showed ten '
  'c44_actionable_wallet_card calls in the Sort Key alone, ~5.3x redundant). '
  'Session guard, feature gate, relationship-scoped logo join, ordering and the '
  '100-card bound with its 101st-row truncation probe are unchanged. Verified '
  'cards and truncated compare exactly equal to the pre-v233 output, '
  '1036.7ms -> 270.7ms.';

commit;

-- ============================================================================
-- VERIFICATION BEFORE APPLY (rolled-back chain, per house discipline)
--
-- 1. For every (staff user, business, branch scope) case, assert
--      app.staff_module_perms_at_v115(business,branch)
--    is unchanged. Capture the old values into a temp table first, replace the
--    function, re-read, compare, rollback. Production baseline captured
--    read-only on 2026-08-08 was 23/23 identical (12 with an explicit
--    non-null p_branch) against this exact body run as a parameterised query.
-- 2. Additionally construct an actor with staff.module_perms set and one with a
--    non-null staff.modules array — the current tenant set exercises neither,
--    so those two rules are reproduced from the source of
--    staff_module_mode_v94 rather than from observed data.
-- 3. Assert public.get_my_modules / get_my_modules_at_v115 payloads are equal
--    key-for-key before and after.
-- 4. Assert customer_get_actionable_wallet()->'cards' and ->>'truncated' are
--    unchanged for every customer with a verified link. Note 'as_of' is
--    statement_timestamp() and will legitimately differ between runs.
-- 5. Assert the negative paths still raise: anon caller -> 28000 on
--    customer_get_actionable_wallet and on app.v32_customer_wallet_context;
--    customer_wallet flag off -> 0A000; auth user with no active identity ->
--    42501.
-- 6. Re-run get_advisors type=security and confirm no new finding.
--
-- NOT VERIFIED AGAINST PRODUCTION DATA (no rows exist to exercise them):
--   * public.platform_module_overrides_v94 is empty (0 rows), so the branch- and
--     firm-override precedence in the rewritten resolvers is reproduced from the
--     source of effective_platform_module_mode_v94, not observed.
--   * no staff row currently has module_perms or a non-null modules array.
--   * app.platform_feature_enabled('customer_birthday_benefits') is false, so
--     c44_actionable_wallet_card short-circuits before its birthday branch; the
--     wallet timings above exclude that path.
-- Step 2 must construct these cases synthetically inside the rolled-back chain.
--
-- KNOWN REMAINING COST, NOT ADDRESSED HERE
--   app.c45_base_actionable_wallet_card costs ~49ms per business against tables
--   holding tens of rows. That is plan-shaped, not data-shaped — a dozen CTEs
--   over ~10 relations — and after this migration it is the dominant remaining
--   term in the wallet RPC. It needs its own change and its own evidence.
-- ============================================================================
