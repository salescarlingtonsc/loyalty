-- NESTLY v177 - READ-ONLY "VIEW AS FIRM" WORKSPACE MIRROR
--
-- Problem: a super admin (and the consultant assigned to a firm) can read
-- platform aggregates about a firm, but cannot see what the FIRM sees in its
-- own workspace. Support, onboarding review and sales demos all need that view.
--
-- Shape decision (owner/reviewer ruling, recorded so it is not re-litigated):
--   * NO session impersonation. The console never receives the firm's JWT and
--     never gets a write control. The mirror is a set of read-only snapshots
--     returned by ONE SECURITY DEFINER RPC, and every payload carries
--     `read_only: true` so a future caller cannot mistake it for a workspace
--     session.
--   * Authorization is deliberately narrower than the v176 report reader:
--     super admin, or the consultant this firm is assigned to
--     (app.v176_is_assigned_consultant, which wraps app.assigned_consultant_v94).
--     Everyone else gets 42501.
--   * PAUSED firms are viewable. Oversight of a paused firm is exactly when the
--     mirror matters, and reading never writes to the firm.
--   * DEMO firms are NOT excluded (unlike v176 AI reports, which spend money).
--     A demo firm's mirror is the thing a sales demo actually shows.
--   * Privacy: the operations sections never carry customer contact details.
--     `appointments` and `customers` expose an abbreviated label only (first
--     name + last initial, or a short id suffix when the record has no name),
--     and no key named `phone` or `email` appears anywhere in the payload.
--   * Cost: every list is hard-capped, every aggregate is business-scoped and
--     rides an existing business_id-leading index. Nothing here scans a table
--     without a business_id predicate.
--
-- Reuse: the overview KPIs reuse app.v176_sales_window verbatim for the
-- whole-firm case, so the mirror and the AI evidence pack can never disagree
-- about what revenue is. v176's helper is business-wide by construction, so a
-- branch-scoped variant lives here rather than changing v176's contract.

begin;

-- ---------------------------------------------------------------------------
-- 1. Authorization
-- ---------------------------------------------------------------------------

create or replace function app.v177_can_view_workspace(p_business uuid)
returns boolean
language sql
stable
security definer
set search_path = pg_catalog, public, app, pg_temp
as $$
  select auth.uid() is not null
    and (
      app.is_super_admin()
      or app.v176_is_assigned_consultant(p_business)
    )
$$;
revoke all privileges on function app.v177_can_view_workspace(uuid)
  from public, anon, authenticated, service_role;
grant execute on function app.v177_can_view_workspace(uuid) to authenticated;

comment on function app.v177_can_view_workspace(uuid) is
  'v177 workspace-mirror gate: super admin, or the consultant assigned to this firm. Reading is allowed for paused and demo firms.';

-- ---------------------------------------------------------------------------
-- 2. Privacy helper
--
-- The mirror shows the SHAPE of a firm''s operations, never its customer list.
-- A person is rendered as "Wei L." - enough to recognise a duplicate booking or
-- a same-day repeat, not enough to contact anybody. A record with no usable
-- name degrades to a four-character id suffix rather than to a blank.
-- ---------------------------------------------------------------------------

create or replace function app.v177_person_label(
  p_full_name text,
  p_id uuid
)
returns text
language plpgsql
immutable
set search_path = pg_catalog, public, app, pg_temp
as $$
declare
  v_parts text[];
  v_count integer;
begin
  v_parts := regexp_split_to_array(btrim(coalesce(p_full_name, '')), '\s+');
  v_parts := array_remove(v_parts, '');
  v_count := coalesce(array_length(v_parts, 1), 0);

  if v_count = 0 then
    return 'Guest ' || upper(right(coalesce(p_id::text, '0000'), 4));
  end if;
  if v_count = 1 then
    return v_parts[1];
  end if;
  return v_parts[1] || ' ' || upper(left(v_parts[v_count], 1)) || '.';
end
$$;
revoke all privileges on function app.v177_person_label(text, uuid)
  from public, anon, authenticated, service_role;

comment on function app.v177_person_label(text, uuid) is
  'v177 privacy helper: renders a person as "First L." for the read-only workspace mirror. Never returns a phone number or an email address.';

-- ---------------------------------------------------------------------------
-- 3. Branch-scoped sales window
--
-- Byte-for-byte the same revenue definition as app.v176_sales_window (the
-- v10.1 per-sale policy snapshot, reversal-aware, synthetic clients excluded
-- from the new-customer count) with one added branch predicate. The RPC calls
-- v176's function directly whenever no branch is selected, so the whole-firm
-- numbers are literally the AI evidence pack''s numbers.
-- ---------------------------------------------------------------------------

create or replace function app.v177_sales_window(
  p_business uuid,
  p_branch uuid,
  p_from date,
  p_to date
)
returns jsonb
language sql
stable
security definer
set search_path = pg_catalog, public, app, pg_temp
as $$
  with bounds as (
    select
      p_from::timestamp at time zone 'Asia/Singapore' as from_ts,
      (p_to + 1)::timestamp at time zone 'Asia/Singapore' as to_ts
  ), valid_sales as (
    select sale.id, sale.client_id, sale.amount_cents,
      coalesce(sale.counts_as_revenue, true) as counts_as_revenue,
      coalesce(sale.counts_as_visit, true) as counts_as_visit
    from public.sales sale, bounds
    where sale.business_id = p_business
      and sale.branch_id = p_branch
      and sale.reversal_of is null
      and sale.occurred_at >= bounds.from_ts
      and sale.occurred_at < bounds.to_ts
      and not exists(
        select 1 from public.sales reversal
        where reversal.business_id = sale.business_id
          and reversal.reversal_of = sale.id
      )
  ), first_purchase as (
    select sale.client_id,
      min((sale.occurred_at at time zone 'Asia/Singapore')::date) as first_date
    from public.sales sale
    join public.clients client
      on client.id = sale.client_id
     and client.business_id = sale.business_id
     and client.is_synthetic = false
    where sale.business_id = p_business
      and sale.branch_id = p_branch
      and sale.reversal_of is null
      and sale.client_id is not null
      and coalesce(sale.counts_as_visit, true)
      and not exists(
        select 1 from public.sales reversal
        where reversal.business_id = sale.business_id
          and reversal.reversal_of = sale.id
      )
    group by sale.client_id
  )
  select pg_catalog.jsonb_build_object(
    'from', p_from,
    'to', p_to,
    'currency', 'SGD',
    'net_revenue_cents', coalesce(
      (select sum(amount_cents) from valid_sales where counts_as_revenue), 0
    ),
    'revenue_transactions', (
      select count(*) from valid_sales where counts_as_revenue
    ),
    'visits', (select count(*) from valid_sales where counts_as_visit),
    'customers_served', (
      select count(distinct client_id)
      from valid_sales where client_id is not null
    ),
    'average_order_cents', coalesce(
      (select round(avg(amount_cents))::bigint
       from valid_sales where counts_as_revenue), 0
    ),
    'new_customers', (
      select count(*) from first_purchase
      where first_purchase.first_date between p_from and p_to
    )
  )
$$;
revoke all privileges on function app.v177_sales_window(uuid, uuid, date, date)
  from public, anon, authenticated, service_role;

comment on function app.v177_sales_window(uuid, uuid, date, date) is
  'v177 branch-scoped twin of app.v176_sales_window. Same revenue and visit definition, one extra branch predicate. NULL p_branch is not meaningful here - the caller uses v176_sales_window for the whole firm.';

-- ---------------------------------------------------------------------------
-- 4. Section builders
-- ---------------------------------------------------------------------------

create or replace function app.v177_overview(
  p_business uuid,
  p_branch uuid
)
returns jsonb
language plpgsql
stable
security definer
set search_path = pg_catalog, public, app, pg_temp
as $$
declare
  v_today date := (clock_timestamp() at time zone 'Asia/Singapore')::date;
  v_current_from date;
  v_prior_from date;
  v_prior_to date;
  v_current jsonb;
  v_prior jsonb;
  v_growth jsonb;
begin
  v_current_from := v_today - 29;
  v_prior_to := v_today - 30;
  v_prior_from := v_today - 59;

  if p_branch is null then
    v_current := app.v176_sales_window(p_business, v_current_from, v_today);
    v_prior := app.v176_sales_window(p_business, v_prior_from, v_prior_to);
  else
    v_current := app.v177_sales_window(p_business, p_branch, v_current_from, v_today);
    v_prior := app.v177_sales_window(p_business, p_branch, v_prior_from, v_prior_to);
  end if;

  v_growth := jsonb_build_object(
    'net_revenue_pct', case
      when coalesce((v_prior->>'net_revenue_cents')::numeric, 0) = 0 then null
      else round(
        ((v_current->>'net_revenue_cents')::numeric
          - (v_prior->>'net_revenue_cents')::numeric)
        * 100 / (v_prior->>'net_revenue_cents')::numeric, 1)
    end,
    'visits_delta',
      coalesce((v_current->>'visits')::bigint, 0)
      - coalesce((v_prior->>'visits')::bigint, 0),
    'new_customers_delta',
      coalesce((v_current->>'new_customers')::bigint, 0)
      - coalesce((v_prior->>'new_customers')::bigint, 0)
  );

  return jsonb_build_object(
    'window', jsonb_build_object(
      'current', jsonb_build_object('from', v_current_from, 'to', v_today),
      'prior', jsonb_build_object('from', v_prior_from, 'to', v_prior_to)
    ),
    'sales', jsonb_build_object(
      'current', v_current, 'prior', v_prior, 'growth', v_growth
    ),
    -- v175 account-open days carry no branch, so this block is always the
    -- whole firm. It is labelled as such rather than silently branch-filtered.
    'account_opens', jsonb_build_object(
      'scope', 'whole_firm',
      'current', app.v176_account_opens_window(p_business, v_current_from, v_today),
      'prior', app.v176_account_opens_window(p_business, v_prior_from, v_prior_to)
    ),
    'outstanding', jsonb_build_object(
      'scope', 'whole_firm',
      'points', coalesce(
        (select sum(entry.points) from public.points_ledger entry
         where entry.business_id = p_business), 0
      ),
      'credit_cents', coalesce(
        (select sum(entry.amount_cents) from public.credit_ledger entry
         where entry.business_id = p_business), 0
      )
    ),
    'counts', jsonb_build_object(
      'customers', (
        select count(*) from public.clients client
        where client.business_id = p_business
          and coalesce(client.is_synthetic, false) = false
      ),
      'active_staff', (
        select count(*) from public.staff member
        where member.business_id = p_business and member.active
      ),
      'active_branches', (
        select count(*) from public.branches branch
        where branch.business_id = p_business and branch.active
      )
    )
  );
end
$$;
revoke all privileges on function app.v177_overview(uuid, uuid)
  from public, anon, authenticated, service_role;

create or replace function app.v177_appointments(
  p_business uuid,
  p_branch uuid
)
returns jsonb
language sql
stable
security definer
set search_path = pg_catalog, public, app, pg_temp
as $$
  with bounds as (
    select
      (clock_timestamp() at time zone 'Asia/Singapore')::date as today
  ), window_bounds as (
    select
      bounds.today as from_date,
      bounds.today + 7 as to_date,
      bounds.today::timestamp at time zone 'Asia/Singapore' as from_ts,
      (bounds.today + 8)::timestamp at time zone 'Asia/Singapore' as to_ts
    from bounds
  ), matched as (
    select appointment.id, appointment.starts_at, appointment.ends_at,
      appointment.status, appointment.party_size, appointment.branch_id,
      appointment.service_id, appointment.staff_id, appointment.client_id
    from public.appointments appointment, window_bounds
    where appointment.business_id = p_business
      and appointment.starts_at >= window_bounds.from_ts
      and appointment.starts_at < window_bounds.to_ts
      and (p_branch is null or appointment.branch_id = p_branch)
  ), capped as (
    select * from matched order by starts_at asc, id asc limit 50
  )
  select pg_catalog.jsonb_build_object(
    'from', (select from_date from window_bounds),
    'to', (select to_date from window_bounds),
    'row_cap', 50,
    'total', (select count(*) from matched),
    'truncated', (select count(*) from matched) > 50,
    'ordering', 'soonest_first',
    'rows', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', capped.id,
        'starts_at', capped.starts_at,
        'ends_at', capped.ends_at,
        'status', capped.status,
        'party_size', capped.party_size,
        'branch_id', capped.branch_id,
        'branch_name', branch.name,
        'service_name', service.name,
        'staff_name', member.full_name,
        -- Abbreviated on purpose: the mirror shows the operations shape, and
        -- must never become a customer-contact export.
        'guest_label', app.v177_person_label(client.full_name, capped.client_id)
      ) order by capped.starts_at asc, capped.id asc)
      from capped
      left join public.branches branch
        on branch.id = capped.branch_id and branch.business_id = p_business
      left join public.services service
        on service.id = capped.service_id and service.business_id = p_business
      left join public.staff member
        on member.id = capped.staff_id and member.business_id = p_business
      left join public.clients client
        on client.id = capped.client_id and client.business_id = p_business
    ), '[]'::jsonb)
  )
$$;
revoke all privileges on function app.v177_appointments(uuid, uuid)
  from public, anon, authenticated, service_role;

create or replace function app.v177_customers(p_business uuid)
returns jsonb
language sql
stable
security definer
set search_path = pg_catalog, public, app, pg_temp
as $$
  with bounds as (
    select (clock_timestamp() at time zone 'Asia/Singapore')::date as today
  ), real_clients as (
    select client.id, client.full_name, client.created_at
    from public.clients client
    where client.business_id = p_business
      and coalesce(client.is_synthetic, false) = false
  ), recent as (
    select * from real_clients order by created_at desc, id desc limit 10
  )
  select pg_catalog.jsonb_build_object(
    'total', (select count(*) from real_clients),
    'joined_last_30_days', (
      select count(*) from real_clients, bounds
      where (real_clients.created_at at time zone 'Asia/Singapore')::date
        between bounds.today - 29 and bounds.today
    ),
    'joined_prior_30_days', (
      select count(*) from real_clients, bounds
      where (real_clients.created_at at time zone 'Asia/Singapore')::date
        between bounds.today - 59 and bounds.today - 30
    ),
    'row_cap', 10,
    -- Counts plus an abbreviated ten-row sample. No contact detail is
    -- selected at all, so none can leak through the mirror.
    'recent', coalesce((
      select jsonb_agg(jsonb_build_object(
        'label', app.v177_person_label(recent.full_name, recent.id),
        'joined_on', (recent.created_at at time zone 'Asia/Singapore')::date,
        'visit_count', (
          select count(*) from public.sales sale
          where sale.business_id = p_business
            and sale.client_id = recent.id
            and coalesce(sale.counts_as_visit, true)
            and sale.reversal_of is null
        )
      ) order by recent.created_at desc, recent.id desc)
      from recent
    ), '[]'::jsonb)
  )
$$;
revoke all privileges on function app.v177_customers(uuid)
  from public, anon, authenticated, service_role;

create or replace function app.v177_programmes(p_business uuid)
returns jsonb
language sql
stable
security definer
set search_path = pg_catalog, public, app, pg_temp
as $$
  select pg_catalog.jsonb_build_object(
    'loyalty', coalesce((
      select jsonb_build_object(
        'configured', true,
        'active', program.active,
        'loyalty_model', program.loyalty_model,
        'configuration_status', program.configuration_status,
        'earn_points_per_dollar', program.earn_points_per_dollar,
        'redeem_points', program.redeem_points,
        'reward_credit_cents', program.reward_credit_cents,
        'stamp_target', program.stamp_target,
        'stamp_per_cents', program.stamp_per_cents,
        'expiry_mode', program.expiry_mode,
        'expiry_days', program.expiry_days
      )
      from public.loyalty_programs program
      where program.business_id = p_business
      order by program.active desc, program.id
      limit 1
    ), jsonb_build_object('configured', false)),
    'rewards', jsonb_build_object(
      'active', (
        select count(*) from public.loyalty_rewards reward
        where reward.business_id = p_business and reward.active
      ),
      'total', (
        select count(*) from public.loyalty_rewards reward
        where reward.business_id = p_business
      )
    ),
    'tiers', (
      select count(*) from public.loyalty_tiers tier
      where tier.business_id = p_business
    ),
    'promotions', jsonb_build_object(
      'active_retention_programmes', (
        select count(*) from public.retention_programs program
        where program.business_id = p_business and program.active
      ),
      'total_retention_programmes', (
        select count(*) from public.retention_programs program
        where program.business_id = p_business
      ),
      'active_campaigns', (
        select count(*) from public.retention_campaigns campaign
        where campaign.business_id = p_business
          and campaign.status = 'active'
      )
    ),
    'referral', coalesce((
      select jsonb_build_object(
        'configured', true,
        'enabled', program.enabled,
        'reward_cents', program.reward_cents,
        'min_spend_cents', program.min_spend_cents
      )
      from public.referral_programs program
      where program.business_id = p_business
      order by program.created_at desc, program.id
      limit 1
    ), jsonb_build_object('configured', false))
  )
$$;
revoke all privileges on function app.v177_programmes(uuid)
  from public, anon, authenticated, service_role;

create or replace function app.v177_staff(
  p_business uuid,
  p_branch uuid
)
returns jsonb
language sql
stable
security definer
set search_path = pg_catalog, public, app, pg_temp
as $$
  with roster as (
    select member.id, member.full_name, member.role, member.title,
      member.active, member.user_id,
      (select count(*) from public.staff_branches assignment
       where assignment.staff_id = member.id
         and assignment.business_id = p_business) as branch_count
    from public.staff member
    where member.business_id = p_business
      and (
        p_branch is null
        or exists(
          select 1 from public.staff_branches assignment
          where assignment.staff_id = member.id
            and assignment.business_id = p_business
            and assignment.branch_id = p_branch
        )
        or not exists(
          select 1 from public.staff_branches assignment
          where assignment.staff_id = member.id
            and assignment.business_id = p_business
        )
      )
  ), capped as (
    select * from roster order by active desc, full_name asc, id asc limit 100
  )
  select pg_catalog.jsonb_build_object(
    'total', (select count(*) from roster),
    'active', (select count(*) from roster where active),
    'with_login', (select count(*) from roster where user_id is not null and active),
    'row_cap', 100,
    'truncated', (select count(*) from roster) > 100,
    -- Staff are business-internal records; full names are intentional here.
    -- Contact columns are still not selected.
    'rows', coalesce((
      select jsonb_agg(jsonb_build_object(
        'full_name', capped.full_name,
        'role', capped.role,
        'title', capped.title,
        'active', capped.active,
        'has_login', capped.user_id is not null,
        'branch_count', capped.branch_count
      ) order by capped.active desc, capped.full_name asc, capped.id asc)
      from capped
    ), '[]'::jsonb)
  )
$$;
revoke all privileges on function app.v177_staff(uuid, uuid)
  from public, anon, authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 5. The one public RPC
-- ---------------------------------------------------------------------------

create or replace function public.platform_workspace_mirror_v177(
  p_business uuid,
  p_branch uuid default null,
  p_section text default 'overview'
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = pg_catalog, public, app, pg_temp
as $$
declare
  v_section text := lower(btrim(coalesce(p_section, 'overview')));
  v_business public.businesses%rowtype;
  v_branch_name text;
  v_branches jsonb;
  v_workspace jsonb;
  v_data jsonb;
begin
  if p_business is null then
    raise exception 'business_required' using errcode = '22023';
  end if;
  if v_section not in ('overview','appointments','customers','programmes','staff') then
    raise exception 'unknown_section' using errcode = '22023';
  end if;
  if not app.v177_can_view_workspace(p_business) then
    raise exception 'workspace_mirror_not_permitted' using errcode = '42501';
  end if;

  select * into v_business from public.businesses where id = p_business;
  if not found then
    raise exception 'business_not_found' using errcode = '22023';
  end if;

  if p_branch is not null then
    select branch.name into v_branch_name
    from public.branches branch
    where branch.id = p_branch and branch.business_id = p_business;
    if v_branch_name is null then
      raise exception 'branch_not_in_business' using errcode = '22023';
    end if;
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
    'id', branch.id,
    'name', branch.name,
    'is_default', branch.is_default,
    'active', branch.active
  ) order by branch.is_default desc, branch.name asc, branch.id asc), '[]'::jsonb)
  into v_branches
  from public.branches branch
  where branch.business_id = p_business;

  select jsonb_build_object(
    'approval_status', coalesce(control.approval_status, 'pending'),
    'decided_at', control.decided_at,
    'lifecycle_state', coalesce(lifecycle.state, 'current'),
    'workspace_paused', coalesce(lifecycle.workspace_paused, false),
    'overdue_day', lifecycle.overdue_day,
    'paused_at', lifecycle.paused_at
  ) into v_workspace
  from (select 1) anchor
  left join public.business_workspace_controls_v94 control
    on control.business_id = p_business
  left join public.business_subscription_lifecycle_v94 lifecycle
    on lifecycle.business_id = p_business;

  if v_section = 'overview' then
    v_data := app.v177_overview(p_business, p_branch);
  elsif v_section = 'appointments' then
    v_data := app.v177_appointments(p_business, p_branch);
  elsif v_section = 'customers' then
    v_data := app.v177_customers(p_business);
  elsif v_section = 'programmes' then
    v_data := app.v177_programmes(p_business);
  else
    v_data := app.v177_staff(p_business, p_branch);
  end if;

  -- Every open of the mirror is on the record. One row per call is acceptable
  -- at this scale and keeps "who looked at this firm, and when" answerable.
  insert into public.audit_log(business_id, actor, action, entity, entity_id, detail)
  values(
    p_business, auth.uid(), 'WORKSPACE_MIRROR_VIEWED_V177', 'businesses', p_business,
    jsonb_build_object('section', v_section, 'branch', p_branch)
  );

  return jsonb_build_object(
    'contract_version', 'v177',
    'read_only', true,
    'generated_at', now(),
    'section', v_section,
    'business_id', v_business.id,
    'business_name', v_business.name,
    'industry', v_business.industry,
    'currency', coalesce(v_business.currency, 'SGD'),
    'is_demo', coalesce(v_business.is_demo, false),
    'workspace', v_workspace,
    'branches', v_branches,
    'branch_id', p_branch,
    'branch_name', v_branch_name,
    'data', v_data
  );
end
$$;
revoke all privileges on function public.platform_workspace_mirror_v177(
  uuid, uuid, text
) from public, anon, authenticated, service_role;
grant execute on function public.platform_workspace_mirror_v177(
  uuid, uuid, text
) to authenticated;

comment on function public.platform_workspace_mirror_v177(uuid, uuid, text) is
  'Read-only "view as firm" mirror for the platform console. Super admin or the assigned consultant only (42501 otherwise). Returns one section snapshot per call with read_only=true, never a write path and never customer contact details. Every call writes one WORKSPACE_MIRROR_VIEWED_V177 audit row.';

commit;
