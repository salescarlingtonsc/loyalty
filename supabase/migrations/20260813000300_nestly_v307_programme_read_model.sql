-- nestly_v307_programme_read_model
--
-- WAVE 1 of the four-programme independence plan
-- (docs/design/FOUR-PROGRAMME-INDEPENDENCE-PLAN.md §6, owner approval 2026-08-13).
--
-- WHAT THIS IS. A read model and nothing else. It creates ONE stable function that answers,
-- for one business, "which of the four programmes is running right now?" — derived entirely
-- from the columns that already exist today (loyalty_programs.active / .loyalty_model,
-- businesses.points_mode, the presence of loyalty_tiers rows, referral_programs.enabled).
-- It creates no table, alters no table, adds no trigger, writes no row and changes no
-- existing object. Applying it and reverting it are both no-ops for every tenant.
--
-- WHY IT SHIPS ALONE, BEFORE THE SPINE. W2 introduces public.business_programmes — the real
-- four-row-per-business spine — and backfills it. That backfill reads FROM this function, and
-- every later wave (W3 ledger tag, W4 read-path flip, W5 write path) is diffed AGAINST this
-- function: for as long as legacy columns stay authoritative, spine truth and this function
-- must agree for every tenant, row for row. So these four predicates are the contract. They
-- are pinned here, in one place, reviewed once, rather than re-derived (and re-guessed) in
-- each wave's backfill SQL.
--
-- THE MIRROR CONTRACT. The points and tiers predicates mirror the live, v306-patched
-- public.customer_portal_capabilities byte-for-semantics, including its asymmetric NULL
-- coalesces — 'redeem' for the rewards/points gate, 'tiers' for the tier gate. That asymmetry
-- is not a typo being copied: v229 backfilled points_mode='redeem' for every firm that already
-- had a programme row, so NULL survives only where no programme was ever configured, and the
-- two defaults answer the two different questions that were asked of an unchosen firm. Mirror
-- means MIRROR: where the live capability is odd, this is odd in exactly the same way, because
-- a read model that quietly improves on the surface it is supposed to reproduce cannot be used
-- to prove a later wave changed nothing. The known oddity, asserted rather than hidden in
-- db/tests/v307_programme_read_model.sql, is a stamps firm with points_mode NULL and leftover
-- tier rows: it answers tiers=true. The tenant survey of 2026-08-13 found no such firm — the one
-- live stamps tenant carrying a leftover ladder sits on points_mode='redeem', which the coalesce
-- suppresses, so it answers stamps=true, tiers=false, correctly. That survey is a point-in-time
-- observation and must be repeated in the pre-apply rehearsal. The oddity is resolved at W2,
-- where the spine records what the owner actually switched on instead of inferring it.
--
-- THREE DELIBERATE DIVERGENCES from customer_portal_capabilities, all because the two functions
-- answer different questions:
--   1. NO module or link gating. customer_portal_capabilities is a per-CUSTOMER presentation
--      answer: it requires an authenticated session, a verified customer link, and
--      'loyalty' = any(enabled_modules) before it will admit a programme exists. This is
--      per-BUSINESS programme truth. A firm that has switched the loyalty module off still HAS
--      a running points programme whose ledger, liability and expiry sweep are all live; the
--      spine has to carry that row, and hiding it here would make the W2 backfill drop
--      programmes for every module-off tenant.
--   2. NO reward-catalogue-nonempty clause on points. The live 'rewards' capability additionally
--      requires a classic redeem pair or an active reward version, i.e. something to spend on.
--      An empty catalogue is a presentation concern — do not mount a shop with no shelves — not
--      a fact about whether the points programme is running. Points still accrue, still expire
--      and still count toward tiers with an empty catalogue.
--   3. points is MODEL-EXCLUSIVE here; the live 'rewards' capability is not. This predicate
--      requires loyalty_model in ('classic','points_tiers'), so a stamps firm answers
--      points=false, always. The live capability's reward-version branch is correlated to the
--      BUSINESS, not to the programme's model (v24 made redemption serve stamps too), so a
--      stamps firm with a published catalogue answers rewards=TRUE — its stamp catalogue is
--      spendable. Both answers are right for their own question: "can this customer redeem
--      something here" is true at that firm; "is a POINTS programme running there" is false —
--      the catalogue it redeems from is the stamp programme's. The spine must not grow a
--      phantom points row for every stamps tenant, so programme identity wins here.
-- Any FOURTH difference would be a defect. The rolled-back suite proves the mirror live, in one
-- transaction, for a classic-model firm across the whole points_mode vocabulary (divergence 3
-- keeps stamps-model firms out of the points-vs-rewards parity comparison by design).
--
-- SECURITY INVOKER, DELIBERATELY — AND THE HOUSE REVOKE ANYWAY. Invoker rights mean this
-- function can never launder a read past RLS for a caller that would not otherwise be allowed
-- to make it: called by a tenant session, RLS applies, and a prober gets four FALSE rows for a
-- business it cannot read — no oracle. But be precise about exposure rather than optimistic:
-- v19 granted USAGE on schema app to authenticated (20260718180602 frenly_v19:79), and a new
-- function's default ACL is EXECUTE TO PUBLIC, so without the revoke below any authenticated
-- JWT could call this directly over SQL. There is no PostgREST route (app is not an exposed
-- schema in supabase/config.toml) and the answer would be RLS-shaped anyway, but the house
-- convention — hundreds of `revoke all on function app.* from public, anon, authenticated`
-- precedents — exists so that nobody has to re-derive that argument per function. This
-- migration follows it. Intended callers are the W2 backfill, later-wave diffs, and definer
-- wrappers, all owner- or service-role-context. The canonical v21 search_path is pinned
-- because a stable function that resolves public tables should not depend on whatever the
-- caller left in its own path (it also keeps the SRF un-inlined, which makes the pinned row
-- order real rather than planner-dependent).
--
-- Consequence worth stating for the integrator: called by an ordinary tenant session, RLS
-- applies, so a caller who cannot see a business's rows gets four FALSE answers rather than an
-- error. Backfills and diffs must therefore run in a context that can see every tenant.

begin;

create or replace function app.business_programmes_v307(p_business uuid)
returns table(kind text, running boolean)
language sql
stable
security invoker
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
  with business_mode as (
    select (
      select business.points_mode
        from public.businesses business
       where business.id = p_business
    ) as points_mode
  ),
  programme_state as (
    select
      exists(
        select 1
          from public.loyalty_programs program
         where program.business_id = p_business
           and program.active
           and program.loyalty_model in ('classic','points_tiers')
      )
      -- Spelled <> 'tiers', byte-matching the live rewards gate, NOT in ('redeem','both'):
      -- the two are equivalent over today's vocabulary {null,redeem,tiers,both}, but the live
      -- spelling is closed under extension — a future mode value diverges silently under the
      -- in-list and this function is the artefact every later wave is diffed against.
      and coalesce(business_mode.points_mode,'redeem') <> 'tiers'
        as points_running,
      exists(
        select 1
          from public.loyalty_programs program
         where program.business_id = p_business
           and program.active
      )
      and coalesce(business_mode.points_mode,'tiers') in ('tiers','both')
      and exists(
        select 1
          from public.loyalty_tiers tier
         where tier.business_id = p_business
      )
        as tiers_running,
      exists(
        select 1
          from public.loyalty_programs program
         where program.business_id = p_business
           and program.active
           and program.loyalty_model = 'stamps'
      ) as stamps_running,
      exists(
        select 1
          from public.referral_programs referral_program
         where referral_program.business_id = p_business
           and referral_program.enabled
      ) as referral_running
    from business_mode
  )
  select
    programme.programme_kind,
    case programme.programme_kind
      when 'points' then programme_state.points_running
      when 'tiers' then programme_state.tiers_running
      when 'stamps' then programme_state.stamps_running
      when 'referral' then programme_state.referral_running
    end
  from programme_state
  cross join (values
    (1,'points'),
    (2,'tiers'),
    (3,'stamps'),
    (4,'referral')
  ) as programme(sort_order, programme_kind)
  order by programme.sort_order
$$;

revoke all on function app.business_programmes_v307(uuid) from public, anon, authenticated;
grant execute on function app.business_programmes_v307(uuid) to service_role;

comment on function app.business_programmes_v307(uuid) is
  'v307 W1 read model: the four programme flags (points, tiers, stamps, referral) derived from '
  'today''s legacy columns, zero writes. Mirrors the v306-patched customer_portal_capabilities '
  'points/tiers predicates including their asymmetric NULL coalesces, minus module/link gating '
  '(this is per-business programme truth, not per-customer presentation), minus the '
  'reward-catalogue-nonempty clause (an empty catalogue is presentation, not programme-off), '
  'and model-exclusive on points (a stamps firm answers points=false even though its stamp '
  'catalogue makes the live rewards capability true). Always returns exactly four rows in the '
  'pinned order, all false for an unknown business. The W2 spine backfills from this function '
  'and every later wave is diffed against it.';

commit;
