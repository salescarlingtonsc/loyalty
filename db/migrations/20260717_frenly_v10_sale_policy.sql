-- FRENLY v10 — sale accounting semantics become per-business policy, not hardcoded rules.
-- (target Supabase project kyzovonwnscrzmkvocid; migration name `frenly_v10_sale_policy`)
--
-- THE DIRECTIVE
--   "we just need to build the foundation (building legos) for the firms. they will decide
--    what is best for their business. ensure we have the foundation for them if they need it."
--
--   v9 fixed the gift-card bug by HARDCODING a second exception into the loyalty trigger
--   (`kind in ('membership','gift_card')`). That worked, but it is the wrong shape: every
--   future disagreement about what a sale kind MEANS becomes another product-level ruling
--   baked into a trigger. public.sell_package has the identical shape as the gift-card bug
--   (books kind='retail' revenue upfront, earns points on the full package price, AND counts
--   as a retention visit at purchase — so a 10-session package registers 11 visits), and
--   there is no single correct answer: a café may legitimately want revenue upfront, an
--   accountant-minded salon may want it deferred. So we stop ruling and start configuring.
--
-- THE MODEL — three orthogonal booleans, per business, per sale kind:
--   counts_as_revenue — does this sale belong in the revenue total?      (read by the UI)
--   counts_as_visit   — does it advance a retention-program goal?        (read by the trigger)
--   earns_points      — does it earn loyalty points?                     (read by the trigger)
--   They are genuinely independent: "package earns points but is not a visit" is expressible,
--   and is in fact the default (see below).
--
-- DEFAULTS (app.sale_policy_defaults) — reproduce today's live behaviour on day one for the
-- one existing business and every new one, with ONE deliberate exception:
--   kind        revenue  visit  points
--   service        Y       Y       Y
--   retail         Y       Y       Y
--   quick_sale     Y       Y       Y
--   membership     Y       N       N     (membership IS revenue — Reports already presents it
--                                          as "Membership revenue"; only points/visits were
--                                          ever excluded. Matches live v5/v9 behaviour.)
--   gift_card      N       N       N     (exactly v9.)
--   package        Y       N       Y     (NEW KIND. Keeps the revenue-upfront behaviour the UI
--                                          copy already promises and keeps points-on-purchase —
--                                          i.e. today's kind='retail' semantics — but sets
--                                          visit = N, which kills the 11-visits-for-a-10-session
--                                          -package bug. This is the ONE knowing default-
--                                          behaviour change: buying a thing is not a visit under
--                                          any coherent policy. A firm that disagrees can flip
--                                          it back with one row.)
--
-- STORAGE — table public.sale_policies keyed (business_id, kind), NOT a JSONB column on
-- businesses. Reasons:
--   * The trigger reads this on EVERY sale insert. A keyed table with a unique index is one
--     index probe; a JSONB blob would be read as a whole-row fetch of `businesses` and then
--     parsed/defaulted in plpgsql on every insert, with no constraint enforcement.
--   * CHECK constraints enforce the legal kind set at write time. JSONB would accept
--     {"packge": {...}} silently — a typo'd key would fall back to defaults forever with no
--     error, which is exactly the class of silent-wrongness this migration exists to remove.
--   * A row is a natural audit_log unit; app.audit() records exactly which kind's policy
--     changed and to what. A JSONB update audits the whole blob.
--   * Overrides are sparse (most firms will never write one) and RLS/grants match the rest of
--     the schema (loyalty_programs / retention_programs / package_plans are all per-business
--     config tables with an `_all` policy on app.is_salon_member).
--
-- RESOLUTION — NO BACKFILL. A business with zero sale_policies rows resolves to the defaults
-- above; an override row may set any subset of the three flags and leave the rest NULL to
-- keep inheriting the product default (hence the nullable columns). app.sale_policy_set()
-- is the single resolution point: defaults LEFT JOIN overrides, coalesce per column. There is
-- exactly one place that knows what a default is.
--
-- Style follows v2/v8/v9: plpgsql SECURITY DEFINER + `set search_path = public`; RPCs revoke
-- from public/anon then grant to intended roles.
--
-- SAFETY: public.sales is empty (0 rows, re-verified pre-flight) and there is 1 businesses
-- row. The kind check constraint is dropped/recreated with no backfill or validation risk.

begin;

-- 1. New sale kind 'package'. ----------------------------------------------------------
--    Previously package purchases masqueraded as 'retail'. They now have their own kind so
--    a policy can address them at all. Safe to drop/recreate unvalidated: the table is empty.
alter table public.sales
  drop constraint if exists sales_kind_check;
alter table public.sales
  add constraint sales_kind_check
  check (kind in ('service','retail','membership','quick_sale','gift_card','package'));

-- 2. Policy overrides table. -----------------------------------------------------------
--    Sparse: absent row = all defaults; NULL column = that flag inherits the default.
--    Surrogate `id` exists solely because app.audit() dereferences new.id/old.id.
create table public.sale_policies (
  id                uuid primary key default gen_random_uuid(),
  business_id       uuid not null references public.businesses(id) on delete cascade,
  kind              text not null
                    check (kind in ('service','retail','quick_sale','membership','gift_card','package')),
  counts_as_revenue boolean,   -- null = inherit product default
  counts_as_visit   boolean,   -- null = inherit product default
  earns_points      boolean,   -- null = inherit product default
  note              text,      -- why this firm deviates; shown back to the owner
  updated_at        timestamptz not null default now(),
  created_at        timestamptz not null default now(),
  unique (business_id, kind)
);

alter table public.sale_policies enable row level security;

create policy sale_policies_all on public.sale_policies for all to authenticated
  using (app.is_salon_member(business_id))
  with check (app.is_salon_member(business_id));

revoke all on public.sale_policies from anon;
grant select, insert, update, delete on public.sale_policies to authenticated;

create trigger trg_sale_policies_audit
  after insert or update or delete on public.sale_policies
  for each row execute function app.audit();

-- 3. The defaults. THE single source of truth for "what does a kind mean by default". ---
create or replace function app.sale_policy_defaults()
returns table (kind text, counts_as_revenue boolean, counts_as_visit boolean, earns_points boolean)
language sql immutable set search_path = public as $$
  select * from (values
    ('service'::text,    true,  true,  true),
    ('retail'::text,     true,  true,  true),
    ('quick_sale'::text, true,  true,  true),
    ('membership'::text, true,  false, false),
    ('gift_card'::text,  false, false, false),
    ('package'::text,    true,  false, true)
  ) as t(kind, counts_as_revenue, counts_as_visit, earns_points)
$$;

-- 4. Resolution: defaults, overridden per-column where the business said so. ------------
--    Always returns exactly one row per known kind, for ANY business, including one with
--    zero override rows (left join on a 6-row constant + a unique-index probe).
create or replace function app.sale_policy_set(p_business uuid)
returns table (kind text, counts_as_revenue boolean, counts_as_visit boolean, earns_points boolean)
language sql stable security definer set search_path = public as $$
  select d.kind,
         coalesce(o.counts_as_revenue, d.counts_as_revenue),
         coalesce(o.counts_as_visit,   d.counts_as_visit),
         coalesce(o.earns_points,      d.earns_points)
  from app.sale_policy_defaults() d
  left join public.sale_policies o
    on o.business_id = p_business
   and o.kind = d.kind
$$;

--    Single-kind convenience wrapper (0 rows for a kind with no defined semantics).
create or replace function app.sale_policy(p_business uuid, p_kind text)
returns table (kind text, counts_as_revenue boolean, counts_as_visit boolean, earns_points boolean)
language sql stable security definer set search_path = public as $$
  select s.kind, s.counts_as_revenue, s.counts_as_visit, s.earns_points
  from app.sale_policy_set(p_business) s
  where s.kind = p_kind
$$;

-- 5. The trigger now ASKS instead of ASSUMING. -----------------------------------------
--    Changes vs the live v9 definition, and nothing else:
--      (a) the early-return guard: `new.kind in ('membership','gift_card')` becomes "this
--          kind neither earns points nor counts as a visit for THIS business";
--      (b) the points block is gated on earns_points (was: implied by the guard);
--      (c) the retention loop + referral block are gated on counts_as_visit;
--      (d) THE SUBTLE ONE — the retention visit-count window's `s.kind not in
--          ('membership','gift_card')` over HISTORICAL rows becomes `s.kind = any(...)`,
--          where the array is the set of kinds that count as a visit FOR THIS BUSINESS.
--          Each historical row is judged by its OWN kind's policy, which is what
--          "count the visits in this window" has always meant. A blocklist could not
--          express this once the list became per-tenant.
--    Preserved byte-for-byte in spirit: the points math, the points_batches `fixed`
--    expiry_mode logic, the retention loop's unique_violation swallow, the referral
--    qualification block (including its `found` re-check and min_spend_cents comparison).
--
--    POLICY READ COST: exactly ONE call to app.sale_policy_set per sale insert — the
--    aggregate below extracts this row's flags AND the visit-kind array in one pass over
--    the 6-row resolved set. That is one 6-row constant scan + one unique-index probe per
--    insert, before any of the work the trigger already did. Negligible next to the
--    points_ledger insert and the retention loop this trigger already performs.
--
--    Referral qualification is deliberately tied to counts_as_visit: the referral concept
--    is "reward on qualified FIRST VISIT" (its own credit_ledger reference string says so),
--    so a kind that is not a visit cannot be that first visit. Under the defaults this
--    reproduces live behaviour for membership and gift_card exactly. It DOES change
--    behaviour for packages — see the DEFAULT CHANGES note at the bottom.
create or replace function app.on_sale_recorded()
returns trigger language plpgsql security definer set search_path = public as $$
declare lp record; rp record; refrow record; refprog record;
        v_pts integer; v_idx integer; v_count integer; v_earn_id uuid;
        w_start timestamptz; w_end timestamptz;
        v_known boolean; v_earns boolean; v_is_visit boolean; v_visit_kinds text[];
begin
  if new.client_id is null then
    return new;
  end if;

  -- One policy read. This row's flags + the business's visit-kind set, in a single pass.
  select bool_or(s.kind = new.kind),
         bool_or(s.earns_points)    filter (where s.kind = new.kind),
         bool_or(s.counts_as_visit) filter (where s.kind = new.kind),
         coalesce(array_agg(s.kind) filter (where s.counts_as_visit), array[]::text[])
    into v_known, v_earns, v_is_visit, v_visit_kinds
    from app.sale_policy_set(new.business_id) s;

  -- A kind with no defined semantics is inert (cannot happen while sales_kind_check and
  -- app.sale_policy_defaults() agree; this is the fail-closed guard if they ever drift).
  if not coalesce(v_known, false) then
    return new;
  end if;
  -- The v9 guard, generalised: nothing to earn, nothing to count -> nothing to do.
  if not (coalesce(v_earns, false) or coalesce(v_is_visit, false)) then
    return new;
  end if;

  if coalesce(v_earns, false) then
    select * into lp from loyalty_programs
      where business_id = new.business_id and active limit 1;
    if found and lp.kind = 'points' then
      v_pts := floor((new.amount_cents / 100.0) * lp.earn_points_per_dollar);
      if v_pts > 0 then
        insert into points_ledger (business_id, client_id, entry_type, points, sale_id, reference)
        values (new.business_id, new.client_id, 'earn', v_pts, new.id, 'auto-earn on sale')
        on conflict do nothing
        returning id into v_earn_id;
        if v_earn_id is not null then
          insert into points_batches (business_id, client_id, earned, remaining, sale_id, earned_at, expires_at)
          values (new.business_id, new.client_id, v_pts, v_pts, new.id, now(),
                  case when lp.expiry_mode = 'fixed'
                       then now() + make_interval(days => lp.expiry_days) end);
        end if;
      end if;
    end if;
  end if;

  if coalesce(v_is_visit, false) then
    for rp in select * from retention_programs
        where business_id = new.business_id and active loop
      v_idx := floor(extract(epoch from (new.occurred_at - rp.starts_on::timestamptz))
                     / (rp.period_days * 86400));
      if v_idx >= 0 then
        w_start := rp.starts_on::timestamptz + make_interval(days => v_idx * rp.period_days);
        w_end   := w_start + make_interval(days => rp.period_days);
        -- Historical rows are filtered by EACH ROW'S OWN kind's counts_as_visit policy.
        select count(*) into v_count from sales s
          where s.business_id = new.business_id and s.client_id = new.client_id
            and s.kind = any(v_visit_kinds)
            and s.occurred_at >= w_start and s.occurred_at < w_end;
        if v_count >= rp.goal_visits then
          begin
            insert into reward_grants (business_id, program_id, client_id, period_index,
                                       reward_type, reward_value, reward_item)
            values (new.business_id, rp.id, new.client_id, v_idx,
                    rp.reward_type, rp.reward_value, rp.reward_item);
            if rp.reward_type = 'credit' and rp.reward_value > 0 then
              insert into credit_ledger (business_id, client_id, entry_type, amount_cents, reference)
              values (new.business_id, new.client_id, 'loyalty_earn',
                      rp.reward_value::integer, 'retention reward: ' || rp.name);
            end if;
          exception when unique_violation then null;
          end;
        end if;
      end if;
    end loop;

    select r.* into refrow from referrals r
      where r.business_id = new.business_id and r.referred_client_id = new.client_id
        and r.status = 'pending' limit 1;
    if found then
      select * into refprog from referral_programs
        where business_id = new.business_id and enabled limit 1;
      if found and new.amount_cents >= coalesce(refprog.min_spend_cents, 0) then
        update referrals set status = 'rewarded', qualified_at = now(),
               reward_cents = refprog.reward_cents
          where id = refrow.id and status = 'pending';
        if found then
          insert into credit_ledger (business_id, client_id, entry_type, amount_cents, reference)
          values (new.business_id, refrow.referrer_client_id, 'referral_reward',
                  refprog.reward_cents, 'referral qualified: first visit completed');
        end if;
      end if;
    end if;
  end if;

  return new;
end $$;

-- 6. sell_package: stop masquerading as retail. ----------------------------------------
--    ONLY the sales insert's `kind` changes ('retail' -> 'package'). The is_salon_member
--    guard, the plan lookup, the client_packages insert and the row_to_json(cp) return
--    shape are preserved byte-for-byte — the UI depends on that shape.
--    NOT CHANGED: public.use_package_session. Its $0 kind='service' row is a genuine visit
--    (the customer actually showed up) and must stay one; $0 earns floor(0 * rate) = 0
--    points, so the points block is a no-op for it exactly as today.
create or replace function public.sell_package(p_business uuid, p_client uuid, p_plan uuid)
returns json language plpgsql security definer set search_path = public as $$
declare plan record; cp client_packages;
begin
  if not app.is_salon_member(p_business) then raise exception 'not a member of this business'; end if;
  select * into plan from package_plans where id = p_plan and business_id = p_business and active;
  if not found then raise exception 'package plan not found or inactive'; end if;
  insert into client_packages (business_id, client_id, plan_id, remaining)
  values (p_business, p_client, p_plan, plan.sessions)
  returning * into cp;
  -- was 'retail' (v6) -> prepaid sessions are their own thing; what a package MEANS for
  -- revenue/visits/points is now sale_policies, not this line.
  insert into sales (business_id, client_id, kind, amount_cents, note)
  values (p_business, p_client, 'package', plan.price_cents, 'package sold: ' || plan.name);
  return row_to_json(cp);
end $$;
revoke execute on function public.sell_package(uuid, uuid, uuid) from public, anon;
grant execute on function public.sell_package(uuid, uuid, uuid) to authenticated;

-- 7. What the UI reads instead of re-hardcoding `kind !== 'gift_card'`. -----------------
--    An RPC rather than a view, deliberately: a security_invoker view would have to call
--    app.sale_policy_set() as the `authenticated` role, and `authenticated` does NOT have
--    USAGE on schema app (verified) — that is load-bearing (it is what stops any logged-in
--    user calling app.run_membership_renewals()). Making the view work would mean either
--    granting schema app usage (widens the internal surface) or duplicating the defaults
--    VALUES list in public (drift risk — the exact bug class this migration removes).
--    A SECURITY DEFINER RPC crosses the boundary once, safely, with an explicit tenant check.
--
--    Returns one object per kind:
--      [{"kind":"gift_card","counts_as_revenue":false,"counts_as_visit":false,
--        "earns_points":false}, ...] — six rows, ordered by kind, always complete.
create or replace function public.get_sale_policy(p_business uuid)
returns json language plpgsql security definer set search_path = public as $$
begin
  if not app.is_salon_member(p_business) then raise exception 'not a member of this business'; end if;
  return (select coalesce(json_agg(row_to_json(p) order by p.kind), '[]'::json)
          from app.sale_policy_set(p_business) p);
end $$;
revoke execute on function public.get_sale_policy(uuid) from public, anon;
grant execute on function public.get_sale_policy(uuid) to authenticated;

-- 8. Owner-facing setter. --------------------------------------------------------------
--    The table is directly writable under RLS, but a null-tolerant upsert keyed on
--    (business_id, kind) is fiddly from PostgREST and easy to get wrong; this validates the
--    kind, enforces the tenant check, keeps updated_at honest, and leaves NULL meaning
--    "inherit the default" intact. Returns the RESOLVED policy for that kind so the caller
--    sees what it actually gets, not what it asked for.
create or replace function public.set_sale_policy(
  p_business uuid, p_kind text,
  p_counts_as_revenue boolean, p_counts_as_visit boolean, p_earns_points boolean,
  p_note text default null)
returns json language plpgsql security definer set search_path = public as $$
declare v_row record;
begin
  if not app.is_salon_member(p_business) then raise exception 'not a member of this business'; end if;
  if not exists (select 1 from app.sale_policy_defaults() d where d.kind = p_kind) then
    raise exception 'unknown sale kind: %', p_kind;
  end if;

  insert into sale_policies (business_id, kind, counts_as_revenue, counts_as_visit,
                             earns_points, note)
  values (p_business, p_kind, p_counts_as_revenue, p_counts_as_visit, p_earns_points, p_note)
  on conflict (business_id, kind) do update
    set counts_as_revenue = excluded.counts_as_revenue,
        counts_as_visit   = excluded.counts_as_visit,
        earns_points      = excluded.earns_points,
        note              = excluded.note,
        updated_at        = now();

  select * into v_row from app.sale_policy(p_business, p_kind);
  return row_to_json(v_row);
end $$;
revoke execute on function public.set_sale_policy(uuid, text, boolean, boolean, boolean, text)
  from public, anon;
grant execute on function public.set_sale_policy(uuid, text, boolean, boolean, boolean, text)
  to authenticated;

commit;

-- ------------------------------------------------------------------------------------
-- DEFAULT BEHAVIOUR CHANGES (the complete list — everything else is byte-identical)
-- ------------------------------------------------------------------------------------
-- Only package purchases change, and only because they now have their own kind:
--   1. A package purchase no longer counts as a retention visit (the 11-visits-for-a-
--      10-session-package bug). Intended; flagged by the orchestrator as the one knowing
--      change.
--   2. CONSEQUENCE, NOT SEPARATELY DECIDED: a package purchase no longer QUALIFIES A
--      REFERRAL, because referral qualification is tied to counts_as_visit (a referral
--      rewards a qualified first VISIT). Today, as kind='retail', a package purchase does
--      qualify one. If the owner wants a package purchase to qualify a referral while not
--      counting toward a retention goal, that needs a FOURTH boolean (`qualifies_referral`)
--      — cheap to add later, and the shape of this migration makes it a one-column change.
--      Not added now: no evidence anyone wants those two to differ, and three flags was the
--      pinned contract.
--   3. Package revenue and points are UNCHANGED by default (revenue Y, points Y) — same as
--      the kind='retail' behaviour the UI copy promises ("revenue upfront").
-- Membership, gift_card, service, retail and quick_sale behave exactly as they do live.
--
-- ------------------------------------------------------------------------------------
-- UI NOTE (out of scope — app/index.html is owned elsewhere)
-- ------------------------------------------------------------------------------------
-- Revenue is still computed client-side. After this lands the UI should call
--   supabase.rpc('get_sale_policy', { p_business: bizId })
-- once per business load, build kind -> flags, and:
--   * revenue KPI + "Revenue by type" total: sum only kinds with counts_as_revenue
--     (replaces the v9 hardcoded `kind !== 'gift_card'`; 'package' arrives as revenue by
--     default, so the total is unchanged for a firm that changes nothing);
--   * Visits KPI: count only kinds with counts_as_visit (this also finally fixes the
--     pre-existing v5 bug where 'membership' rows inflate the visit count);
--   * kinds with counts_as_revenue = false are shown as "cash collected, not revenue"
--     OUTSIDE the revenue total (today: gift_card; tomorrow: package, if a firm defers it);
--   * a Settings surface writing set_sale_policy() is what turns this into a lego for the
--     firm rather than a hidden table.
--
-- ------------------------------------------------------------------------------------
-- MANUAL TEST SCENARIOS
-- ------------------------------------------------------------------------------------
-- Scenario A — Zero policy rows must reproduce live behaviour (the core regression test):
--   1. The existing business (which has NO sale_policies rows) + active points
--      loyalty_program (earn_points_per_dollar = 1, expiry_mode='fixed', expiry_days=365)
--      + client C.
--   2. select * from app.sale_policy_set('<biz>') order by kind;
--      -> exactly 6 rows matching the DEFAULTS table in the header. No NULLs.
--   3. insert into sales(business_id, client_id, kind, amount_cents)
--        values ('<biz>','<C>','service', 5000);
--      -> 50 points in points_ledger + one points_batches row with expires_at = now()+365d.
--   4. select public.issue_gift_card('<biz>', 2500, '<C>', null);
--      -> kind='gift_card' sale row; points_ledger/points_batches UNCHANGED (v9 intact).
--   5. select public.enroll_membership('<biz>','<C>','<plan>');
--      -> kind='membership' sale row; points_ledger/points_batches UNCHANGED (v5 intact).
--
-- Scenario B — Package purchase: revenue + points, but NOT a visit (the fix):
--   1. package_plans row: sessions = 10, price_cents = 20000.
--   2. select public.sell_package('<biz>','<C>','<plan>');
--      -> sales row kind = 'package' (NOT 'retail'), amount_cents = 20000;
--         points_ledger gains 200 points (earns_points default = true, unchanged);
--         get_sale_policy shows package counts_as_revenue = true (revenue unchanged).
--   3. Active retention_program: goal_visits = 10, period_days = 365, starts_on = today.
--      Call use_package_session 10 times.
--      -> exactly 10 sales rows kind='service' amount 0, and the visit count reaches 10
--         (not 11) -> exactly ONE reward_grants row, granted on the 10th SESSION, not on
--         the 9th. Pre-fix the purchase itself was visit #1 and the reward fired one
--         session early.
--
-- Scenario C — THE HISTORICAL-ROWS FILTER (most likely to be silently wrong):
--   1. Active retention_program: goal_visits = 2, period_days = 30, starts_on = today,
--      reward_type='credit', reward_value = 1000.
--   2. sell_package (kind='package') for C, then ONE kind='service' sale for C.
--      -> NO reward_grants row. The package row is in the window but is not a visit kind,
--         so the count is 1, not 2. (Pre-fix: 2 -> wrongly granted.)
--   3. A SECOND kind='service' sale.
--      -> now exactly one reward_grants row + one 1000-cent 'loyalty_earn' credit row.
--         Proves the historical package row stays invisible when a later sale recounts
--         the window.
--   4. Now: select public.set_sale_policy('<biz>','package', true, TRUE, true, 'we count it');
--      Repeat 1-2 with a fresh client D and a fresh period.
--      -> the reward now fires on the FIRST service sale after the package, because the
--         historical package row is NOW a visit for this business. This is the assertion
--         that the window filters by each row's own kind's CURRENT policy, not by a
--         hardcoded list — flip one row, historical rows are re-judged.
--
-- Scenario D — Orthogonality (all three flags independent):
--   1. select public.set_sale_policy('<biz>','package', false, false, true, 'defer revenue');
--      -> {"kind":"package","counts_as_revenue":false,"counts_as_visit":false,
--          "earns_points":true}. sell_package still earns points; get_sale_policy reports
--          package as non-revenue so the UI drops it out of the total.
--   2. select public.set_sale_policy('<biz>','gift_card', false, false, TRUE, 'we reward buyers');
--      -> a gift card purchase NOW earns points (the v9 hardcode could not express this)
--         but still is not revenue and still is not a visit, and still does not qualify a
--         referral. Proves the early-return guard is (earns OR visit), not either alone.
--   3. select public.set_sale_policy('<biz>','service', true, false, true, 'no retention');
--      -> service sales still earn points; retention loop never runs for them; a pending
--         referral is NOT qualified by a service sale. (Confirms referral is bound to
--         counts_as_visit — see DEFAULT BEHAVIOUR CHANGES #2.)
--
-- Scenario E — Partial override / NULL inheritance:
--   1. insert into sale_policies (business_id, kind, counts_as_visit)
--        values ('<biz>','membership', true);        -- revenue + points columns left NULL
--   2. select * from app.sale_policy('<biz>','membership');
--      -> counts_as_visit = true (override), counts_as_revenue = true and earns_points =
--         false (both INHERITED from the defaults, not nulled out).
--   3. enroll_membership -> the membership sale now advances a retention goal but still
--      earns no points. One flag moved; the others did not.
--
-- Scenario F — Tenant isolation + grants:
--   1. As a user who is NOT a member: select public.get_sale_policy('<biz>');
--      -> raises 'not a member of this business'. Same for set_sale_policy.
--   2. As anon (publishable key): both RPCs -> permission denied; select on sale_policies
--      -> permission denied (revoked; the portal has no business reading firm accounting).
--   3. Member of business X: select * from sale_policies; -> only X's rows (RLS).
--   4. Any override row for business X leaves business Y resolving to pure defaults.
--
-- Scenario G — Constraints + drift guard:
--   1. insert into sales(...) values ('<biz>', null, 'package', 100);  -> accepted.
--   2. insert into sales(...) values ('<biz>', null, 'packages', 100); -> rejected by
--      sales_kind_check.
--   3. select public.set_sale_policy('<biz>','bundle', true, true, true, null);
--      -> raises 'unknown sale kind: bundle'.
--   4. insert into sale_policies (business_id, kind) values ('<biz>','service');
--      then a second identical insert -> rejected by unique (business_id, kind).
--   5. select array_agg(kind order by kind) from app.sale_policy_defaults();
--      vs the sales_kind_check constraint definition -> the two sets must be IDENTICAL.
--      If they ever drift, on_sale_recorded()'s `v_known` guard makes the orphaned kind
--      inert (no points, no visits) rather than silently defaulting it to "everything".
-- ------------------------------------------------------------------------------------
