-- nestly_v310_programme_read_path
--
-- WAVE 4a of the four-programme independence plan
-- (docs/design/FOUR-PROGRAMME-INDEPENDENCE-PLAN.md §6, owner approval 2026-08-13).
--
-- WHAT THIS IS. The READ-PATH flip. W1 gave one reviewed answer to "is this programme running"
-- (app.business_programmes_v307), W2 projected it into a four-row spine per business
-- (public.business_programmes), W3 tagged every points_ledger / points_batches row with the
-- programme it belongs to. Nothing read any of that. This wave makes eleven server readers
-- programme-aware, and it is deliberately the SMALLEST change that can be true:
--
--   * IDENTITY is additive everywhere. Six payloads gain new keys — `programmes`,
--     `programmes_contract`, `programme`, `balance_scope`, `tier_fuel`, `pot_is_split`,
--     `points_outstanding_by_programme_tag` — and not one existing key is removed, renamed,
--     retyped or given a new meaning. /app-*.js is Cloudflare-pinned for roughly four hours
--     (scripts/quality/stamp-app-bundle.mjs:10-16) and the four chunks do not evict in a
--     guaranteed order, so for the whole window old-bundle x new-server and new-bundle x
--     old-server must BOTH be correct. Additive-only is what buys that.
--
--   * EXACTLY ONE BEHAVIOUR CHANGES: the tier-fuel metric. `tier_basis='points_earned'` firms
--     climb the ladder on lifetime points EARNED, and that sum was business-wide. It is now
--     scoped to the points programme's ledger rows. Four functions compute that same metric —
--     public.customer_get_effective_tier_v143, app.v176_tier_gate_metric (which decides
--     tier_requirement.met and the 'tier_locked' availability inside the reward catalog),
--     public.customer_get_business_presentation_v95, and app.loyalty_tier_for. THREE move here,
--     in one transaction, because if the ladder and the reward gate disagree a member is told
--     "you are Gold" beside a reward that says "reach Gold to unlock". The FOURTH,
--     app.loyalty_tier_for, is DELIBERATELY NOT TOUCHED: app.on_sale_recorded calls it, so it is
--     the earn MULTIPLIER, not a display metric, and changing it changes what a sale earns. Its
--     md5 is captured before this migration's first statement and asserted UNCHANGED after the
--     last one, so "we did not touch it" is a proof rather than a promise. W5 owns it
--     (plan §6 W5, "tier multiplier scoped to points"), with this file as its named target.
--     Zero live tenants can observe the divergence: all ten live programmes are on visits basis
--     (V306 evidence:43) and there are zero live tiers=true and zero live stamps=true tenants
--     (V307 evidence:52-57), so no production payload value moves today.
--
--   * NO READER COMPUTES A PER-PROGRAMME SPENDABLE BALANCE. See the currentness policy below.
--
-- ---------------------------------------------------------------------------------------------
-- THE CURRENTNESS POLICY (carried verbatim from V309 evidence:188-197, and DECIDED here)
-- ---------------------------------------------------------------------------------------------
-- "The tag follows the business's CURRENT model, so after a model switch the offsetting rows
-- history produces later (expiry sweeps, redemptions, adjustments - all sale_id IS NULL) land on
-- the NEW model's programme while the original earns keep the OLD tag: per-programme sums for a
-- switched firm can go negative on one side even though the single-pot balance is right. Inert in
-- W3 (nothing reads the tag) and invisible to the double-earn detector by design. W4 owns this:
-- whichever reader first sums per-programme balances must either migrate the pot at switch time
-- or read switched firms single-pot; the W4 brief must carry this paragraph."
--
-- Three candidates were considered. (c) a one-time retag of points_ledger is REJECTED: it is an
-- UPDATE of an append-only ledger (V309 standing invariant 2 requires that to be said out loud),
-- it would rewrite provenance from "whose money was this when it was written" to "whose money is
-- it now", and it has no beneficiary — zero production firms have a split pot. (b) computing
-- per-programme balances with a fold-back flag is REJECTED as the primary policy: it would change
-- the shape of thirteen more readers in this wave, each needing its own fold-back branch, i.e.
-- thirteen new places to show a switched firm a negative pot. The flag itself is kept, as the
-- guard. (a) IS ADOPTED:
--
--   1. No W4 reader computes a per-programme spendable balance. Every money number in every W4
--      payload stays sum(points) where business_id = ... [and client_id = ...], byte-identical.
--   2. Every per-programme object carries "balance_scope":"business_pot". W5's pot migration
--      flips that VALUE to "programme_pot" — a value change, not a shape change, so the client
--      never needs a second wave.
--   3. The tag is read here for exactly two non-balance purposes: identity (which programme a
--      card or section belongs to), sourced from the SPINE and never from the ledger; and the
--      tier-fuel metric, which is an entry_type='earn' lifetime sum and is STRUCTURALLY IMMUNE
--      to the gap — the gap is defined over offsetting rows (sale_id IS NULL: expire / redeem /
--      adjust), and an 'earn' row's tag is the model at the time of the sale, i.e. correct
--      provenance rather than stale state.
--   4. Analytics may show a per-tag breakdown, never as money-you-can-spend, and NEVER for a
--      split firm: §7/§8 suppress the array to NULL when app.programme_pot_is_split_v310 is true.
--      An owner is never shown a per-programme liability that can be wrong.
--
-- The standing detector app.detect_programme_pot_split_v310() reports any firm whose ledger spans
-- more than one programme OR carries a row that disagrees with the resolver's current answer, and
-- is asserted EMPTY at install. Note what this deliberately does NOT do: V309 migration assertion
-- (b) — every tag equals the resolver's current answer — is NOT carried forward as a migration
-- assertion (V309 standing invariant 4 says W5 breaks it on purpose). Here that disagreement is a
-- FINDING inside a detector, not a failure of the wave.
--
-- ---------------------------------------------------------------------------------------------
-- THE PREDECESSOR PINS, AND WHY THERE ARE TWO ACCEPTED VALUES FOR TWO OF THEM
-- ---------------------------------------------------------------------------------------------
-- Two of the readers this wave changes have a LIVE body that is not this repository's file:
-- public.customer_portal_capabilities is v231's file plus v306's needle patch, and
-- public.customer_get_reward_catalog is v176b's file plus v230's patch plus v241's reshape.
-- Replacing either from the repository file alone would silently revert v306 / v241. So every
-- function this migration re-states is pinned by md5(prosrc) BEFORE the first create-or-replace,
-- and the migration aborts if production has drifted.
--
-- Each pin accepts a set of at most two values, and the header says exactly what they are:
--   * the LIVE value recorded read-only against gadpooereceldfpfxsod on 2026-08-13 by the pinned
--     W4 design contract, and
--   * the CANONICAL-REPLAY value produced by applying this repository's own lineage to a clean
--     PostgreSQL 17 cluster (build order: v231 -> v306 for capabilities; v186 + v176b -> v230 ->
--     v241 for the tier reader, the gate metric and the catalog).
-- For app.v176_tier_gate_metric, public.customer_get_effective_tier_v143 and
-- public.customer_get_business_presentation_v95 the two values are IDENTICAL — the replay
-- reproduces production byte-for-byte, which is what makes the other pins interpretable.
-- For public.customer_portal_capabilities they differ ONLY by full-line comments (the Supabase
-- MCP apply strips them; the replay keeps them), and that claim is not asserted on trust: the
-- migration ALSO asserts a single-valued COMMENT-NORMALISED md5, which equals the recorded live
-- pin on production and on the replay alike. Two accepted raw values, one normalised value, one
-- reviewed body.
-- For public.customer_get_reward_catalog the live and replay values differ by MORE than comments,
-- and no repository lineage reproduces the live body. That function is therefore NEVER re-stated
-- here: it is SPLICED, comment-free needle, against whatever the live definition actually is —
-- the v241 / v273 technique, which is immune to a divergence it cannot see. Its md5 is asserted
-- only to record which predecessor was met, and the fail-closed guard is the needle count.
--
-- Techniques, stated once per function so a reviewer never has to infer them:
--   RE-STATED (full create-or-replace, md5-pinned): customer_portal_capabilities,
--     customer_get_effective_tier_v143, app.v176_tier_gate_metric.
--   SPLICED (pg_get_functiondef read + exact comment-free needle, count-asserted):
--     customer_get_reward_catalog, customer_get_business_presentation_v95,
--     app.v179_business_insights, app.v177_overview, business_programme_usage_v271,
--     customer_get_wallet, customer_get_loyalty_details.
--   UNTOUCHED, ASSERTED UNCHANGED: app.loyalty_tier_for.
-- create-or-replace preserves the owner and the ACL in every case (V306 evidence:95-96 proved
-- this for the capabilities function specifically), and the ACL floors are re-asserted at the end
-- anyway, so the guarantee travels with the file rather than with the database's history.
--
-- LOCK DIRECTION. Every reader here reads public.business_programmes inside a STABLE function and
-- takes no locks, so V308 standing invariant 1 (businesses row -> spine rows) is untouched — it
-- binds writers. V308 standing invariant 2 (the loyalty_tiers sync is a DEFERRABLE INITIALLY
-- DEFERRED constraint trigger that converges at COMMIT) means no reader may read the spine in the
-- same transaction that edited ladder rungs without an explicit `set constraints ... immediate`.
-- NO READER CHANGED HERE DOES THAT, and db/tests/v310_programme_read_path.sql flushes the queue
-- by name wherever it needs to assert mid-transaction.
--
-- THE FAIL-OPEN BRANCH IS THE MOST DANGEROUS LINE IN THE WAVE. The tier-fuel filter is written as
-- "resolve the spine id into a variable, and if it is NULL sum unfiltered". Written the obvious
-- way instead — `and programme_id = (select id from ... where kind='points')` — a NULL subselect
-- makes the predicate never true and silently drops EVERY customer at that firm to no tier. The
-- suite deletes the points spine row inside a rolled-back transaction and asserts the metric is
-- UNCHANGED, not zeroed.

begin;

-- ---------------------------------------------------------------------------
-- 0. Predecessor pins. Fail closed BEFORE anything is replaced.
-- ---------------------------------------------------------------------------

create temporary table v310_baseline(what text primary key, value text) on commit drop;

do $v310_pins$
declare
  v_caps_raw text;
  v_caps_norm text;
  v_catalog_raw text;
  v_tier_raw text;
  v_gate_raw text;
  v_presentation_raw text;
  v_tier_for_raw text;
begin
  -- Comment-normalised md5: full-line SQL comments removed, everything else byte-for-byte. This
  -- is the ONLY normalisation applied anywhere in this migration, and it exists solely to make
  -- the MCP-apply comment stripping visible instead of mysterious.
  select md5(p.prosrc),
         md5(coalesce((
           select string_agg(split.line, chr(10) order by split.ord)
             from regexp_split_to_table(p.prosrc, chr(10))
                  with ordinality as split(line, ord)
            where btrim(split.line) not like '--%'
         ), ''))
    into strict v_caps_raw, v_caps_norm
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'customer_portal_capabilities';
  select md5(p.prosrc) into strict v_catalog_raw
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'customer_get_reward_catalog';
  select md5(p.prosrc) into strict v_tier_raw
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'customer_get_effective_tier_v143';
  select md5(p.prosrc) into strict v_gate_raw
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'app' and p.proname = 'v176_tier_gate_metric';
  select md5(p.prosrc) into strict v_presentation_raw
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'customer_get_business_presentation_v95';
  select md5(p.prosrc) into strict v_tier_for_raw
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'app' and p.proname = 'loyalty_tier_for';

  -- Already applied? Say so plainly. Without this the md5 pin below would abort with an
  -- "unexpected predecessor" message, which is true but reads like production drift rather than
  -- like a re-run. This wave is a one-apply migration (three full re-statements and seven
  -- needle splices); the splices are individually idempotent, the re-statements are not
  -- meaningfully so, and re-running is a mistake rather than a no-op.
  if position('programmes_contract' in (
       select p.prosrc from pg_proc p join pg_namespace n on n.oid = p.pronamespace
        where n.nspname = 'public' and p.proname = 'customer_portal_capabilities')) > 0 then
    raise exception
      'v310 is already applied (customer_portal_capabilities already carries programmes_contract)'
      using errcode = '23514';
  end if;

  -- (a) capabilities: two accepted raw values, ONE normalised value.
  if v_caps_raw not in (
       '7dc51e85aad4ea3c28594b50b006b3a3',  -- LIVE (v231 + v306, comments stripped by MCP apply)
       '7d334151af57b8545980e06ab3143cf1'   -- CANONICAL REPLAY (same lineage, comments intact)
     ) then
    raise exception 'v310: unexpected customer_portal_capabilities predecessor md5=%', v_caps_raw
      using errcode = '23514';
  end if;
  if v_caps_norm <> '7dc51e85aad4ea3c28594b50b006b3a3' then
    raise exception
      'v310: customer_portal_capabilities is not the reviewed v231+v306 body (normalised md5=%)',
      v_caps_norm using errcode = '23514';
  end if;

  -- (b) catalog: recorded, not enforced as a single value — this function is SPLICED, and the
  --     needle count below is its fail-closed guard.
  if v_catalog_raw not in (
       'df46ae23771c790fb51ce068737cc986',  -- LIVE (v176b + v230 + v241)
       '72eab252281bf530347c59cf5a736d65'   -- CANONICAL REPLAY (same lineage)
     ) then
    raise notice
      'v310: customer_get_reward_catalog predecessor md5=% is neither the recorded live nor the '
      'canonical-replay value; the splice needle assertion is what decides whether it lands.',
      v_catalog_raw;
  end if;

  -- (c) the three twins that are re-stated or spliced with a proven byte-identical predecessor.
  if v_tier_raw <> '9ffe9a1829d02e68ad58d6f35f46decf' then
    raise exception 'v310: unexpected customer_get_effective_tier_v143 predecessor md5=%',
      v_tier_raw using errcode = '23514';
  end if;
  if v_gate_raw <> '64f323a77b799874dbdec6dd77f43899' then
    raise exception 'v310: unexpected app.v176_tier_gate_metric predecessor md5=%',
      v_gate_raw using errcode = '23514';
  end if;
  if v_presentation_raw <> '416e7710c4abd88fb9df9eb1f16c6298' then
    raise exception 'v310: unexpected customer_get_business_presentation_v95 predecessor md5=%',
      v_presentation_raw using errcode = '23514';
  end if;

  -- (d) the fourth twin. Recorded now, asserted unchanged at the end. No pin is hard-coded for
  --     it on purpose: the assertion is "this migration did not move it", which is true on any
  --     predecessor and cannot be satisfied by a lucky constant.
  insert into v310_baseline values ('loyalty_tier_for_md5', v_tier_for_raw);

  raise notice 'v310 predecessor pins met: capabilities raw=% norm=%, catalog raw=%, tier=%, '
    'gate=%, presentation=%, loyalty_tier_for baseline=%',
    v_caps_raw, v_caps_norm, v_catalog_raw, v_tier_raw, v_gate_raw, v_presentation_raw,
    v_tier_for_raw;
end
$v310_pins$;

-- ---------------------------------------------------------------------------
-- 1. The two new objects: the split guard and the standing detector.
-- ---------------------------------------------------------------------------

-- The boolean §7/§8 use to suppress a per-tag breakdown. One business, one question.
create or replace function app.programme_pot_is_split_v310(p_business uuid)
returns boolean
language sql
stable
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
  -- NULL-blind hardening (W4a verifier risk 2): count(distinct) ignores NULLs, so an
  -- untagged row would read as "not split" while the per-tag INNER JOIN aggregations
  -- silently dropped it. Unreachable barring a v309 tag-trigger bug — treated as split
  -- anyway so liability can never under-report silently.
  select (select count(distinct programme_id) > 1
                 or count(*) filter (where programme_id is null) > 0
            from public.points_ledger
           where business_id = $1)
$$;

revoke all privileges on function app.programme_pot_is_split_v310(uuid)
  from public, anon, authenticated;
grant execute on function app.programme_pot_is_split_v310(uuid) to service_role;

comment on function app.programme_pot_is_split_v310(uuid) is
  'v310 W4a: true when this business''s points_ledger rows span more than one programme. Under '
  'the W4 currentness policy a split pot means per-programme sums are provenance, not spendable '
  'money, so app.v179_business_insights and app.v177_overview suppress their per-tag breakdown '
  'to NULL — never a partial array — while this answers true.';

-- The standing detector. A row here is a FINDING, not a failure: it is W5's pot-migration
-- worklist and the production canary for a firm that switches loyalty_model between this apply
-- and that migration.
create or replace function app.detect_programme_pot_split_v310()
returns table (business_id uuid, business_name text, distinct_tags int,
               rows_off_current bigint, negative_tag_pots int)
language sql
stable
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
  select b.id, b.name,
         count(distinct pl.programme_id)::int,
         count(*) filter (
           where pl.programme_id is distinct from
                 app.resolve_ledger_programme_v309(pl.business_id)),
         (select count(*)::int from (
            select pl2.client_id, pl2.programme_id, sum(pl2.points) s
              from public.points_ledger pl2
             where pl2.business_id = b.id
             group by 1,2) g where g.s < 0)
    from public.points_ledger pl
    join public.businesses b on b.id = pl.business_id
   group by b.id, b.name
  having count(distinct pl.programme_id) > 1
      or count(*) filter (
           where pl.programme_id is distinct from
                 app.resolve_ledger_programme_v309(pl.business_id)) > 0;
$$;

revoke all privileges on function app.detect_programme_pot_split_v310()
  from public, anon, authenticated;
grant execute on function app.detect_programme_pot_split_v310() to service_role;

comment on function app.detect_programme_pot_split_v310() is
  'v310 W4a standing detector: businesses whose points_ledger spans more than one programme, or '
  'carries a row that disagrees with app.resolve_ledger_programme_v309''s current answer, with '
  'the count of (client, programme) pots that have gone negative. Asserted empty at install. '
  'Deliberately NOT the same thing as V309 migration assertion (b): a disagreement here is a '
  'finding to act on (W5''s pot-migration worklist), not a reason to refuse a migration — V309 '
  'standing invariant 4 says W5 breaks that equality on purpose.';

-- ---------------------------------------------------------------------------
-- 2. public.customer_portal_capabilities — RE-STATED. +programmes[4], +programmes_contract.
--     Every existing key keeps its exact v231/v306 value: the three booleans are hoisted into
--     variables computed by the IDENTICAL expressions, which is also what makes the binding
--     cross-check invariant (programmes[points].customer_visible === legacy rewards, and
--     programmes[tiers].customer_visible === legacy tiers) true BY CONSTRUCTION rather than by
--     a second, drift-prone computation.
-- ---------------------------------------------------------------------------

create or replace function public.customer_portal_capabilities(p_business_slug text)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $function$
declare
  v_context record;
  v_points_mode text;
  v_wallet boolean;
  v_rewards boolean;
  v_tiers boolean;
  v_programmes jsonb;
begin
  if auth.uid() is null then
    raise exception 'authenticated customer session required'
      using errcode='28000';
  end if;

  select *
    into v_context
    from app.v32_customer_wallet_context(p_business_slug)
   limit 1;
  if not found then
    raise exception 'verified customer link required'
      using errcode='42501';
  end if;

  select business.points_mode
    into v_points_mode
    from public.businesses business
   where business.id=v_context.business_id;

  v_wallet :=
    'loyalty'=any(v_context.enabled_modules)
    and exists(
      select 1
        from public.loyalty_programs program
       where program.business_id=v_context.business_id
         and program.active
    );

  -- v230: points that buy tier membership are not spendable. The capability says so, so the
  -- customer is never offered a redemption the v229 gate would refuse.
  v_rewards :=
    'loyalty'=any(v_context.enabled_modules)
    and coalesce(v_points_mode,'redeem') <> 'tiers'
    and exists(
      select 1
        from public.loyalty_programs program
       where program.business_id=v_context.business_id
         and program.active
         and (
           (
             program.loyalty_model='classic'
             and program.kind='points'
             and program.redeem_points>0
             and program.reward_credit_cents>0
           )
           or exists(
             select 1
               from public.loyalty_reward_versions reward_version
               join public.businesses business
                 on business.id=reward_version.business_id
                and business.active_config_version_id=
                  reward_version.config_version_id
              where reward_version.business_id=v_context.business_id
                and reward_version.active
           )
         )
    );

  -- v230/v306: the tier ladder belongs to a firm whose points are FOR membership ('tiers') or
  -- whose points do both ('both'), and only once it has tiers to climb. A firm that has not
  -- chosen yet keeps today's behaviour: tiers show if they exist, because nothing has been put
  -- away.
  v_tiers :=
    'loyalty'=any(v_context.enabled_modules)
    and coalesce(v_points_mode,'tiers') in ('tiers','both')
    and exists(
      select 1
        from public.loyalty_programs program
       where program.business_id=v_context.business_id
         and program.active
    )
    and exists(
      select 1
        from public.loyalty_tiers tier
       where tier.business_id=v_context.business_id
    );

  -- v310: the four-programme spine, in the spine's own `sort` order, ALWAYS four rows. `active`
  -- is READ from public.business_programmes and never recomputed here — one answer to "is this
  -- programme running", set in W1, projected in W2. running_since/paused_since are v308's
  -- never-cleared breadcrumbs, so running_since means "running since at least".
  -- customer_visible is presentation, not programme truth, and it is bound to the legacy
  -- capability for points and tiers so the two answers can never diverge during the CDN window.
  -- referral is bound to the spine ALONE: the referral card still renders exclusively from
  -- customer_get_referral_card_v300's {enabled:true}, so there is one truth for referral
  -- presentation, not two.
  select coalesce(jsonb_agg(jsonb_build_object(
           'kind', spine.kind,
           'active', spine.active,
           'customer_visible', case spine.kind
                                 when 'points' then v_rewards
                                 when 'tiers' then v_tiers
                                 when 'stamps' then (v_wallet and spine.active)
                                 else spine.active
                               end,
           'running_since', spine.activated_at,
           'paused_since', spine.deactivated_at,
           'balance_scope', 'business_pot'
         ) order by spine.sort), '[]'::jsonb)
    into v_programmes
    from public.business_programmes spine
   where spine.business_id=v_context.business_id;

  return jsonb_build_object(
    'wallet', v_wallet,
    'rewards', v_rewards,
    'tiers', v_tiers,
    'points_mode', v_points_mode,
    'activity',
      'loyalty'=any(v_context.enabled_modules)
      and exists(
        select 1
          from public.loyalty_programs program
         where program.business_id=v_context.business_id
           and program.active
      )
      and (
        exists(
          select 1
            from public.points_ledger ledger
           where ledger.business_id=v_context.business_id
             and ledger.client_id=v_context.client_id
        )
        or exists(
          select 1
            from public.loyalty_redemptions redemption
           where redemption.business_id=v_context.business_id
             and redemption.client_id=v_context.client_id
        )
        or exists(
          select 1
            from public.reward_grants grant_row
           where grant_row.business_id=v_context.business_id
             and grant_row.client_id=v_context.client_id
        )
      ),
    'appointments',
      'appointments'=any(v_context.enabled_modules)
      and exists(
        select 1
          from public.appointments appointment
         where appointment.business_id=v_context.business_id
           and appointment.client_id=v_context.client_id
      ),
    'booking_request',
      'bookings'=any(v_context.enabled_modules)
      and exists(
        select 1
          from public.services service
         where service.business_id=v_context.business_id
           and service.active
      ),
    'packages',
      'packages'=any(v_context.enabled_modules)
      and exists(
        select 1
          from public.client_packages customer_package
         where customer_package.business_id=v_context.business_id
           and customer_package.client_id=v_context.client_id
      ),
    'membership',
      'memberships'=any(v_context.enabled_modules)
      and exists(
        select 1
          from public.memberships membership
         where membership.business_id=v_context.business_id
           and membership.client_id=v_context.client_id
      ),
    'programmes_contract', 'v310',
    'programmes', v_programmes
  );
end
$function$;

comment on function public.customer_portal_capabilities(text) is
  'v310: adds programmes[4] (kind, active, customer_visible, running_since, paused_since, '
  'balance_scope=business_pot) read from the v308 spine, plus programmes_contract=''v310'' as the '
  'client''s gate. Every pre-v310 key is unchanged in shape and value. '
  'v306: tiers is true for points_mode ''tiers'' AND ''both''. v230/v231: rewards is false in '
  'tiers mode so the surface never offers a redemption the v229 gate refuses, and points_mode is '
  'reported so an absent section can be explained rather than silently dropped.';

revoke all on function public.customer_portal_capabilities(text) from public, anon;
grant execute on function public.customer_portal_capabilities(text) to authenticated;

-- ---------------------------------------------------------------------------
-- 3. public.customer_get_reward_catalog — SPLICED. +programmes[] grouping, +balance_scope.
--     The grouping is DERIVED: loyalty_rewards and loyalty_reward_versions carry no
--     programme_id (the plan adds it at W5/W6), and while a firm has exactly one accruing
--     programme every reward belongs to it — stamps when loyalty_model='stamps', points
--     otherwise, which is app.resolve_ledger_programme_v309's own rule. v_result is built ONCE
--     and referenced by both keys, so the flat and grouped views cannot drift. The client must
--     not assume length 1: W6 makes it 2+.
-- ---------------------------------------------------------------------------

do $v310_catalog$
declare
  v_def text;
  v_old text := $needle$  return jsonb_build_object(
    'rewards', coalesce(v_result, '[]'::jsonb),
    'points_mode', (select points_mode from public.businesses where id = v_context.business_id));$needle$;
  v_new text := $needle$  return jsonb_build_object(
    'rewards', coalesce(v_result, '[]'::jsonb),
    'points_mode', (select points_mode from public.businesses where id = v_context.business_id),
    'programmes_contract', 'v310',
    'balance_scope', 'business_pot',
    'programmes', jsonb_build_array(jsonb_build_object(
      'kind', case when exists (
                     select 1 from public.loyalty_programs programme_v310
                      where programme_v310.business_id = v_context.business_id
                        and programme_v310.loyalty_model = 'stamps')
                   then 'stamps' else 'points' end,
      'balance_scope', 'business_pot',
      'rewards', coalesce(v_result, '[]'::jsonb))));$needle$;
  v_count integer;
begin
  select pg_get_functiondef('public.customer_get_reward_catalog(text)'::regprocedure)
    into strict v_def;

  if position('programmes_contract' in v_def) > 0 then
    raise notice 'v310: customer_get_reward_catalog already carries programmes_contract';
    return;
  end if;

  v_count := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if v_count <> 1 then
    raise exception
      'v310: customer_get_reward_catalog v241 return needle occurrences=% (expected 1)', v_count
      using errcode = '23514';
  end if;
  -- The reviewed payload contract must still be there: a predecessor that lost the tier gate or
  -- the wallet context is not the function this wave reviewed.
  if position('app.v176_tier_gate_metric(' in v_def) = 0
     or position('app.v32_customer_wallet_context(' in v_def) = 0
     or position('insufficient_balance' in v_def) = 0 then
    raise exception
      'v310: customer_get_reward_catalog predecessor lost its reviewed payload contract'
      using errcode = '23514';
  end if;

  execute replace(v_def, v_old, v_new);

  select pg_get_functiondef('public.customer_get_reward_catalog(text)'::regprocedure)
    into strict v_def;
  if (length(v_def) - length(replace(v_def, v_new, ''))) / length(v_new) <> 1
     or position(v_old in v_def) <> 0 then
    raise exception 'v310: customer_get_reward_catalog splice did not land'
      using errcode = '23514';
  end if;
end
$v310_catalog$;

comment on function public.customer_get_reward_catalog(text) is
  'v310: adds programmes[] (one derived group in W4 — the firm''s single accruing programme) and '
  'balance_scope=business_pot beside the unchanged rewards[] and points_mode. The grouped and '
  'flat views are the SAME v_result aggregation, so they cannot drift. v241 shape, v230 mode, '
  'v176b tier gate all unchanged.';

-- ---------------------------------------------------------------------------
-- 4. public.customer_get_effective_tier_v143 — RE-STATED. D1: the tier-fuel filter, fail-OPEN.
-- ---------------------------------------------------------------------------

create or replace function public.customer_get_effective_tier_v143(p_business uuid)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public, app, pg_temp
as $$
declare
  v_identity uuid;
  v_client uuid;
  v_basis text;
  v_metric numeric:=0;
  v_points_programme uuid;
  v_current public.loyalty_tiers%rowtype;
  v_next public.loyalty_tiers%rowtype;
  v_progress numeric:=0;
  v_tiers jsonb;
begin
  if auth.uid() is null then
    raise exception 'authenticated customer session required' using errcode='28000';
  end if;
  v_identity:=app.v31_current_identity();
  select link.client_id into v_client
  from public.customer_links link
  where link.identity_id=v_identity
    and link.auth_user_id=auth.uid()
    and link.business_id=p_business
    and link.state='verified';
  if not found then
    raise exception 'verified customer link required' using errcode='42501';
  end if;
  if not app.business_module_enabled_at_v117(p_business,'loyalty',null)
     or not exists(
       select 1 from public.loyalty_programs
       where business_id=p_business and active
     ) then
    raise exception 'loyalty module is unavailable for this business' using errcode='42501';
  end if;

  select coalesce(tier_basis,'visits') into v_basis
  from public.loyalty_programs
  where business_id=p_business and active
  limit 1;
  if v_basis='spend' then
    select coalesce(sum(amount_cents),0)/100.0 into v_metric from public.sales
    where business_id=p_business and client_id=v_client and counts_as_revenue;
  elsif v_basis='points_earned' then
    -- v310 D1: tier fuel is the POINTS programme's lifetime earn, not the whole ledger's.
    -- Resolved into a variable and branched explicitly: written inline as
    -- `programme_id = (subselect)`, a NULL spine row would make the predicate never true and
    -- silently drop every customer at this firm to no tier. A missing spine row must never
    -- zero a tier, so the NULL branch falls back to the pre-v310 unfiltered sum.
    select spine.id into v_points_programme
    from public.business_programmes spine
    where spine.business_id=p_business and spine.kind='points';
    if v_points_programme is null then
      select coalesce(sum(points),0) into v_metric from public.points_ledger
      where business_id=p_business and client_id=v_client and entry_type='earn';
    else
      select coalesce(sum(ledger.points),0) into v_metric from public.points_ledger ledger
      where ledger.business_id=p_business and ledger.client_id=v_client
        and ledger.entry_type='earn' and ledger.programme_id=v_points_programme;
    end if;
  else
    select count(*) into v_metric from public.sales
    where business_id=p_business and client_id=v_client and counts_as_visit;
  end if;

  select * into v_current from public.loyalty_tiers
  where business_id=p_business
    and threshold<=v_metric
    and (effective_from is null or effective_from<=statement_timestamp())
    and (expires_at is null or expires_at>statement_timestamp())
  order by threshold desc,sort desc,id limit 1;
  select * into v_next from public.loyalty_tiers
  where business_id=p_business
    and threshold>coalesce(v_current.threshold,-1)
    and (effective_from is null or effective_from<=statement_timestamp())
    and (expires_at is null or expires_at>statement_timestamp())
  order by threshold,sort,id limit 1;
  if v_next.id is not null then
    v_progress:=greatest(0,least(100,round(
      (v_metric-coalesce(v_current.threshold,0))*100
      /nullif(v_next.threshold-coalesce(v_current.threshold,0),0),2
    )));
  elsif v_current.id is not null then
    v_progress:=100;
  end if;

  -- v186: the full ladder, lowest rung first, in the same effective window as current/next.
  select coalesce(jsonb_agg(jsonb_build_object(
    'id',ladder.id,
    'label',ladder.name,
    'threshold',ladder.threshold,
    'achieved',ladder.threshold<=v_metric,
    'current',ladder.id=v_current.id,
    'benefits',coalesce((
      select jsonb_agg(btrim(benefit) order by ordinal)
      from regexp_split_to_table(coalesce(ladder.perk_note,''),E'\\r?\\n')
        with ordinality as item(benefit,ordinal)
      where btrim(benefit)<>''
    ),'[]'::jsonb)
  ) order by ladder.threshold,ladder.sort,ladder.id),'[]'::jsonb) into v_tiers
  from public.loyalty_tiers ladder
  where ladder.business_id=p_business
    and (ladder.effective_from is null or ladder.effective_from<=statement_timestamp())
    and (ladder.expires_at is null or ladder.expires_at>statement_timestamp());

  return jsonb_build_object('tier',jsonb_build_object(
    'points_mode',(select points_mode from public.businesses where id=p_business),
    'label',v_current.name,
    'current',case when v_current.id is null then null else jsonb_build_object(
      'id',v_current.id,'label',v_current.name,'threshold',v_current.threshold,
      'metric',v_metric,'benefits',coalesce((
        select jsonb_agg(btrim(benefit) order by ordinal)
        from regexp_split_to_table(coalesce(v_current.perk_note,''),E'\\r?\\n')
          with ordinality as item(benefit,ordinal)
        where btrim(benefit)<>''
      ),'[]'::jsonb)
    ) end,
    'next',case when v_next.id is null then null else jsonb_build_object(
      'id',v_next.id,'label',v_next.name,'threshold',v_next.threshold,
      'benefits',coalesce((
        select jsonb_agg(btrim(benefit) order by ordinal)
        from regexp_split_to_table(coalesce(v_next.perk_note,''),E'\\r?\\n')
          with ordinality as item(benefit,ordinal)
        where btrim(benefit)<>''
      ),'[]'::jsonb)
    ) end,
    'tiers',v_tiers,
    'progress_percent',v_progress,'basis',v_basis,'metric',v_metric,
    'tier_fuel','points_programme_earn','balance_scope','business_pot'
  ));
end
$$;

comment on function public.customer_get_effective_tier_v143(uuid) is
  'v310 D1: on tier_basis=''points_earned'' the metric is the POINTS programme''s lifetime earn '
  '(v308 spine row), with an explicit fail-OPEN fallback to the unfiltered sum when that spine '
  'row is missing — a missing row must never zero a tier. Adds tier_fuel and balance_scope. '
  'v186 ladder, v230 points_mode and every other key unchanged.';

revoke all on function public.customer_get_effective_tier_v143(uuid) from public, anon;
grant execute on function public.customer_get_effective_tier_v143(uuid) to authenticated;
grant execute on function public.customer_get_effective_tier_v143(uuid) to service_role;

-- ---------------------------------------------------------------------------
-- 5. app.v176_tier_gate_metric — RE-STATED. THE IDENTICAL D1 CHANGE, SAME TRANSACTION.
--     This is what decides tier_requirement.met and the 'tier_locked' availability inside
--     customer_get_reward_catalog. If §4 moves and this does not, a member reads "you're Gold"
--     on the ladder and "reach Gold to unlock" on the reward.
-- ---------------------------------------------------------------------------

create or replace function app.v176_tier_gate_metric(p_business uuid, p_client uuid)
returns numeric
language plpgsql
stable
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare
  v_basis text;
  v_metric numeric := 0;
  v_points_programme uuid;
begin
  select coalesce(tier_basis,'visits') into v_basis
    from public.loyalty_programs
   where business_id = p_business and active
   limit 1;

  if v_basis = 'spend' then
    select coalesce(sum(amount_cents),0)/100.0 into v_metric
      from public.sales
     where business_id = p_business and client_id = p_client and counts_as_revenue;
  elsif v_basis = 'points_earned' then
    -- v310 D1, identical to public.customer_get_effective_tier_v143. Fail OPEN on a missing
    -- spine row: the reward gate must never tighten because a projection row went absent.
    select spine.id into v_points_programme
      from public.business_programmes spine
     where spine.business_id = p_business and spine.kind = 'points';
    if v_points_programme is null then
      select coalesce(sum(points),0) into v_metric
        from public.points_ledger
       where business_id = p_business and client_id = p_client and entry_type = 'earn';
    else
      select coalesce(sum(ledger.points),0) into v_metric
        from public.points_ledger ledger
       where ledger.business_id = p_business and ledger.client_id = p_client
         and ledger.entry_type = 'earn' and ledger.programme_id = v_points_programme;
    end if;
  else
    select count(*) into v_metric
      from public.sales
     where business_id = p_business and client_id = p_client and counts_as_visit;
  end if;
  return coalesce(v_metric,0);
end $$;

comment on function app.v176_tier_gate_metric(uuid,uuid) is
  'v310 D1 twin of public.customer_get_effective_tier_v143: points_earned fuel is scoped to the '
  'v308 points spine row, fail-OPEN when that row is missing. Changed in the SAME transaction as '
  'the ladder so the reward gate and the ladder can never disagree.';

revoke all on function app.v176_tier_gate_metric(uuid,uuid) from public, anon;

-- ---------------------------------------------------------------------------
-- 6. public.customer_get_business_presentation_v95 — SPLICED, metric branch ONLY.
--     The fourth reader of the same metric, and the easiest to miss. Its business-pot BALANCE
--     (v95:1651-1653) is deliberately untouched: policy rule 1 says money numbers do not move.
-- ---------------------------------------------------------------------------

do $v310_presentation$
declare
  v_def text;
  v_decl_old text := $needle$  v_metric numeric:=0;v_basis text;v_current public.loyalty_tiers%rowtype;$needle$;
  v_decl_new text := $needle$  v_metric numeric:=0;v_basis text;v_points_programme uuid;
  v_current public.loyalty_tiers%rowtype;$needle$;
  v_metric_old text := $needle$  elsif v_basis='points_earned' then
    select coalesce(sum(points),0) into v_metric from public.points_ledger
    where business_id=p_business and client_id=v_client and entry_type='earn';$needle$;
  v_metric_new text := $needle$  elsif v_basis='points_earned' then
    select spine.id into v_points_programme
    from public.business_programmes spine
    where spine.business_id=p_business and spine.kind='points';
    if v_points_programme is null then
      select coalesce(sum(points),0) into v_metric from public.points_ledger
      where business_id=p_business and client_id=v_client and entry_type='earn';
    else
      select coalesce(sum(ledger.points),0) into v_metric from public.points_ledger ledger
      where ledger.business_id=p_business and ledger.client_id=v_client
        and ledger.entry_type='earn' and ledger.programme_id=v_points_programme;
    end if;$needle$;
  v_count integer;
begin
  select pg_get_functiondef(
    'public.customer_get_business_presentation_v95(uuid,uuid,text)'::regprocedure
  ) into strict v_def;

  if position('v_points_programme' in v_def) > 0 then
    raise notice 'v310: customer_get_business_presentation_v95 already carries the D1 filter';
    return;
  end if;

  v_count := (length(v_def) - length(replace(v_def, v_decl_old, ''))) / length(v_decl_old);
  if v_count <> 1 then
    raise exception 'v310: presentation_v95 declare needle occurrences=% (expected 1)', v_count
      using errcode = '23514';
  end if;
  v_count := (length(v_def) - length(replace(v_def, v_metric_old, ''))) / length(v_metric_old);
  if v_count <> 1 then
    raise exception 'v310: presentation_v95 metric needle occurrences=% (expected 1)', v_count
      using errcode = '23514';
  end if;
  -- The BALANCE must survive untouched. Prove the line is there before and after.
  if position($balance$  select coalesce(sum(points),0)::integer into v_balance$balance$ in v_def) = 0 then
    raise exception 'v310: presentation_v95 lost its business-pot balance line'
      using errcode = '23514';
  end if;

  v_def := replace(v_def, v_decl_old, v_decl_new);
  v_def := replace(v_def, v_metric_old, v_metric_new);
  execute v_def;

  select pg_get_functiondef(
    'public.customer_get_business_presentation_v95(uuid,uuid,text)'::regprocedure
  ) into strict v_def;
  if position('v_points_programme' in v_def) = 0
     or position(v_metric_old in v_def) <> 0
     or position($balance$  select coalesce(sum(points),0)::integer into v_balance$balance$ in v_def) = 0 then
    raise exception 'v310: presentation_v95 splice did not land as specified'
      using errcode = '23514';
  end if;
end
$v310_presentation$;

comment on function public.customer_get_business_presentation_v95(uuid,uuid,text) is
  'v310 D1 twin: the points_earned tier metric is scoped to the v308 points spine row, fail-OPEN. '
  'The programme BALANCE stays the business pot, byte-identical to v95 — W4 policy rule 1.';

-- ---------------------------------------------------------------------------
-- 7. app.v179_business_insights — SPLICED. points_outstanding_total is BYTE-IDENTICAL.
-- ---------------------------------------------------------------------------

do $v310_insights$
declare
  v_def text;
  v_old text := $needle$      'points_outstanding_total', coalesce((
        select sum(points) from public.points_ledger where business_id = p_business
      ), 0)$needle$;
  v_new text := $needle$      'points_outstanding_total', coalesce((
        select sum(points) from public.points_ledger where business_id = p_business
      ), 0),
      'pot_is_split', app.programme_pot_is_split_v310(p_business),
      'by_programme_note',
        'ledger tag provenance, not a spendable pot (V309 currentness gap)',
      'points_outstanding_by_programme_tag', case
        when app.programme_pot_is_split_v310(p_business) then null
        else coalesce((
          select pg_catalog.jsonb_agg(
                   pg_catalog.jsonb_build_object('kind', spine.kind, 'points', tag.points)
                   order by spine.sort)
            from (
              select entry.programme_id, sum(entry.points) as points
                from public.points_ledger entry
               where entry.business_id = p_business
               group by entry.programme_id
            ) tag
            join public.business_programmes spine on spine.id = tag.programme_id
        ), '[]'::jsonb) end$needle$;
  v_count integer;
begin
  select pg_get_functiondef(
    'app.v179_business_insights(uuid,date,date,date,date)'::regprocedure
  ) into strict v_def;

  if position('points_outstanding_by_programme_tag' in v_def) > 0 then
    raise notice 'v310: v179_business_insights already carries the per-tag breakdown';
    return;
  end if;

  v_count := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if v_count <> 1 then
    raise exception 'v310: v179 outstanding needle occurrences=% (expected 1)', v_count
      using errcode = '23514';
  end if;

  execute replace(v_def, v_old, v_new);

  select pg_get_functiondef(
    'app.v179_business_insights(uuid,date,date,date,date)'::regprocedure
  ) into strict v_def;
  if position('points_outstanding_by_programme_tag' in v_def) = 0
     or position($total$'points_outstanding_total', coalesce($total$ in v_def) = 0 then
    raise exception 'v310: v179 splice did not land' using errcode = '23514';
  end if;
end
$v310_insights$;

-- ---------------------------------------------------------------------------
-- 8. app.v177_overview — SPLICED. outstanding.points is BYTE-IDENTICAL.
-- ---------------------------------------------------------------------------

do $v310_overview$
declare
  v_def text;
  v_old text := $needle$      'points', coalesce(
        (select sum(entry.points) from public.points_ledger entry
         where entry.business_id = p_business), 0
      ),$needle$;
  v_new text := $needle$      'points', coalesce(
        (select sum(entry.points) from public.points_ledger entry
         where entry.business_id = p_business), 0
      ),
      'pot_is_split', app.programme_pot_is_split_v310(p_business),
      'by_programme_note',
        'ledger tag provenance, not a spendable pot (V309 currentness gap)',
      'points_outstanding_by_programme_tag', case
        when app.programme_pot_is_split_v310(p_business) then null
        else coalesce((
          select jsonb_agg(jsonb_build_object('kind', spine.kind, 'points', tag.points)
                   order by spine.sort)
            from (
              select entry.programme_id, sum(entry.points) as points
                from public.points_ledger entry
               where entry.business_id = p_business
               group by entry.programme_id
            ) tag
            join public.business_programmes spine on spine.id = tag.programme_id
        ), '[]'::jsonb) end,$needle$;
  v_count integer;
begin
  select pg_get_functiondef('app.v177_overview(uuid,uuid)'::regprocedure) into strict v_def;

  if position('points_outstanding_by_programme_tag' in v_def) > 0 then
    raise notice 'v310: v177_overview already carries the per-tag breakdown';
    return;
  end if;

  v_count := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if v_count <> 1 then
    raise exception 'v310: v177 outstanding needle occurrences=% (expected 1)', v_count
      using errcode = '23514';
  end if;

  execute replace(v_def, v_old, v_new);

  select pg_get_functiondef('app.v177_overview(uuid,uuid)'::regprocedure) into strict v_def;
  if position('points_outstanding_by_programme_tag' in v_def) = 0 then
    raise exception 'v310: v177 splice did not land' using errcode = '23514';
  end if;
end
$v310_overview$;

-- ---------------------------------------------------------------------------
-- 9. public.business_programme_usage_v271 — SPLICED. The point-system earner count is scoped to
--     the points spine row (at a stamps tenant it was reporting stamp earners as POINT-SYSTEM
--     users), and a symmetric stamp_card block is added. Both are IDENTITY counts, not money.
--     'point_system' keeps its name, its type and its coalesce-to-0 doctrine.
-- ---------------------------------------------------------------------------

do $v310_usage$
declare
  v_def text;
  v_decl_old text := $needle$  v_point_customers int;$needle$;
  v_decl_new text := $needle$  v_point_customers int;
  v_points_programme_v310 uuid;
  v_stamps_programme_v310 uuid;
  v_stamp_customers_v310 int;$needle$;
  v_count_old text := $needle$  select count(distinct client_id)::int into v_point_customers
    from public.points_ledger
   where business_id = p_business
     and entry_type = 'earn'
     and client_id is not null;$needle$;
  v_count_new text := $needle$  select spine.id into v_points_programme_v310
    from public.business_programmes spine
   where spine.business_id = p_business and spine.kind = 'points';
  if v_points_programme_v310 is null then
    select count(distinct client_id)::int into v_point_customers
      from public.points_ledger
     where business_id = p_business
       and entry_type = 'earn'
       and client_id is not null;
  else
    select count(distinct ledger.client_id)::int into v_point_customers
      from public.points_ledger ledger
     where ledger.business_id = p_business
       and ledger.entry_type = 'earn'
       and ledger.client_id is not null
       and ledger.programme_id = v_points_programme_v310;
  end if;

  select spine.id into v_stamps_programme_v310
    from public.business_programmes spine
   where spine.business_id = p_business and spine.kind = 'stamps';
  if v_stamps_programme_v310 is not null then
    select count(distinct ledger.client_id)::int into v_stamp_customers_v310
      from public.points_ledger ledger
     where ledger.business_id = p_business
       and ledger.entry_type = 'earn'
       and ledger.client_id is not null
       and ledger.programme_id = v_stamps_programme_v310;
  end if;$needle$;
  v_payload_old text := $needle$    'point_system', jsonb_build_object('customers', coalesce(v_point_customers, 0)),$needle$;
  v_payload_new text := $needle$    'point_system', jsonb_build_object('customers', coalesce(v_point_customers, 0)),
    'stamp_card', jsonb_build_object('customers', case when exists(
                                       select 1 from public.loyalty_programs programme_v310
                                        where programme_v310.business_id = p_business
                                          and programme_v310.loyalty_model = 'stamps')
                                     then coalesce(v_stamp_customers_v310, 0) else null end),$needle$;
  v_count integer;
begin
  select pg_get_functiondef('public.business_programme_usage_v271(uuid)'::regprocedure)
    into strict v_def;

  if position('v310' in v_def) > 0 then
    raise notice 'v310: business_programme_usage_v271 already scoped';
    return;
  end if;

  v_count := (length(v_def) - length(replace(v_def, v_decl_old, ''))) / length(v_decl_old);
  if v_count <> 1 then
    raise exception 'v310: v271 declare needle occurrences=% (expected 1)', v_count
      using errcode = '23514';
  end if;
  v_count := (length(v_def) - length(replace(v_def, v_count_old, ''))) / length(v_count_old);
  if v_count <> 1 then
    raise exception 'v310: v271 point-count needle occurrences=% (expected 1)', v_count
      using errcode = '23514';
  end if;
  v_count := (length(v_def) - length(replace(v_def, v_payload_old, ''))) / length(v_payload_old);
  if v_count <> 1 then
    raise exception 'v310: v271 point_system payload needle occurrences=% (expected 1)', v_count
      using errcode = '23514';
  end if;
  -- v273's null-when-never-set-up rule must survive this splice untouched.
  if position('v273_exists' in v_def) = 0 then
    raise exception 'v310: v271 predecessor is missing the v273 existence rule'
      using errcode = '23514';
  end if;

  v_def := replace(v_def, v_decl_old, v_decl_new);
  v_def := replace(v_def, v_count_old, v_count_new);
  v_def := replace(v_def, v_payload_old, v_payload_new);
  execute v_def;

  select pg_get_functiondef('public.business_programme_usage_v271(uuid)'::regprocedure)
    into strict v_def;
  if position('stamp_card' in v_def) = 0
     or position('v273_exists' in v_def) = 0
     or position(v_count_old in v_def) <> 0 then
    raise exception 'v310: v271 splice did not land as specified' using errcode = '23514';
  end if;
end
$v310_usage$;

revoke all on function public.business_programme_usage_v271(uuid) from public, anon;
grant execute on function public.business_programme_usage_v271(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- 10. public.customer_get_wallet — SPLICED. IDENTITY ONLY. No number changes.
-- ---------------------------------------------------------------------------

do $v310_wallet$
declare
  v_def text;
  v_old text := $needle$            'credit_balance_cents', case when 'loyalty' = any(ctx.enabled_modules) and coalesce(lp.active, false)
                                         then coalesce(credit_balance.balance_cents, 0) else 0 end
          ),$needle$;
  v_new text := $needle$            'credit_balance_cents', case when 'loyalty' = any(ctx.enabled_modules) and coalesce(lp.active, false)
                                         then coalesce(credit_balance.balance_cents, 0) else 0 end
          ),
          'programme', jsonb_build_object(
            'kind', case when lp.loyalty_model = 'stamps' then 'stamps' else 'points' end,
            'active', coalesce((
              select spine.active from public.business_programmes spine
               where spine.business_id = ctx.business_id
                 and spine.kind = case when lp.loyalty_model = 'stamps'
                                       then 'stamps' else 'points' end), false),
            'balance_scope', 'business_pot'
          ),$needle$;
  v_count integer;
begin
  select pg_get_functiondef('public.customer_get_wallet()'::regprocedure) into strict v_def;

  if position($p$'programme', jsonb_build_object($p$ in v_def) > 0 then
    raise notice 'v310: customer_get_wallet already carries the programme identity block';
    return;
  end if;

  v_count := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if v_count <> 1 then
    raise exception 'v310: customer_get_wallet loyalty-block needle occurrences=% (expected 1)',
      v_count using errcode = '23514';
  end if;

  execute replace(v_def, v_old, v_new);

  select pg_get_functiondef('public.customer_get_wallet()'::regprocedure) into strict v_def;
  if position($p$'programme', jsonb_build_object($p$ in v_def) = 0
     or position($b$'balance', case when 'loyalty' = any(ctx.enabled_modules)$b$ in v_def) = 0 then
    raise exception 'v310: customer_get_wallet splice did not land' using errcode = '23514';
  end if;
end
$v310_wallet$;

-- ---------------------------------------------------------------------------
-- 11. public.customer_get_loyalty_details — SPLICED. IDENTITY ONLY. No number changes.
-- ---------------------------------------------------------------------------

do $v310_details$
declare
  v_def text;
  v_old text := $needle$    'unit',case when v_program.loyalty_model='stamps'
      then 'stamps' else 'points' end,$needle$;
  v_new text := $needle$    'unit',case when v_program.loyalty_model='stamps'
      then 'stamps' else 'points' end,
    'programme',pg_catalog.jsonb_build_object(
      'kind',case when v_program.loyalty_model='stamps' then 'stamps' else 'points' end,
      'active',coalesce((
        select spine.active from public.business_programmes spine
         where spine.business_id=v_context.business_id
           and spine.kind=case when v_program.loyalty_model='stamps'
                               then 'stamps' else 'points' end),false),
      'balance_scope','business_pot'),$needle$;
  v_count integer;
begin
  select pg_get_functiondef('public.customer_get_loyalty_details(text,jsonb)'::regprocedure)
    into strict v_def;

  if position($p$'programme',pg_catalog.jsonb_build_object($p$ in v_def) > 0 then
    raise notice 'v310: customer_get_loyalty_details already carries the programme identity block';
    return;
  end if;

  v_count := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if v_count <> 1 then
    raise exception
      'v310: customer_get_loyalty_details unit needle occurrences=% (expected 1)', v_count
      using errcode = '23514';
  end if;

  execute replace(v_def, v_old, v_new);

  select pg_get_functiondef('public.customer_get_loyalty_details(text,jsonb)'::regprocedure)
    into strict v_def;
  if position($p$'programme',pg_catalog.jsonb_build_object($p$ in v_def) = 0 then
    raise exception 'v310: customer_get_loyalty_details splice did not land'
      using errcode = '23514';
  end if;
end
$v310_details$;

-- ---------------------------------------------------------------------------
-- 12. Fail-closed post-conditions. Any one of these aborts the whole wave.
-- ---------------------------------------------------------------------------

do $v310_assertions$
declare
  v_tier_for_before text;
  v_tier_for_after text;
  v_detected bigint;
  v_spine_shape bigint;
  v_caps_src text;
  v_anon boolean;
  v_authenticated boolean;
  v_service boolean;
begin
  -- (a) THE FOURTH TWIN IS UNTOUCHED. app.on_sale_recorded calls app.loyalty_tier_for, so this
  --     is the assertion that this wave changed no earn behaviour. W5 owns it.
  select value into strict v_tier_for_before
    from v310_baseline where what = 'loyalty_tier_for_md5';
  select md5(p.prosrc) into strict v_tier_for_after
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'app' and p.proname = 'loyalty_tier_for';
  if v_tier_for_after <> v_tier_for_before then
    raise exception
      'v310 moved app.loyalty_tier_for (before=% after=%) — that is the EARN multiplier and is W5''s target',
      v_tier_for_before, v_tier_for_after using errcode = '23514';
  end if;

  -- (b) The standing detector must be clean the moment it ships. Fail closed.
  select count(*) into strict v_detected from app.detect_programme_pot_split_v310();
  if v_detected <> 0 then
    raise exception 'v310 pot-split detector is non-empty at install time: % business(es)',
      v_detected using errcode = '23514';
  end if;

  -- (c) programmes[] is ALWAYS four rows, so the client never has to handle a sparse array.
  --     The v308 backfill guarantees this; asserting it here is what makes the payload contract
  --     a fact rather than an inherited assumption.
  select count(*) into strict v_spine_shape
    from (
      select business.id
        from public.businesses business
        left join public.business_programmes spine on spine.business_id = business.id
       group by business.id
      having count(spine.id) <> 4
    ) sparse;
  if v_spine_shape <> 0 then
    raise exception 'v310: a business does not carry exactly four spine rows'
      using errcode = '23514';
  end if;

  -- (d) The binding cross-check invariant, asserted STRUCTURALLY: the capabilities payload must
  --     derive programmes[points].customer_visible from the same variable as the legacy `rewards`
  --     key, and programmes[tiers].customer_visible from the same variable as legacy `tiers`.
  --     Source-level because it is a by-construction guarantee; the behavioural proof (two real
  --     tenants, both directions) is db/tests/v310_programme_read_path.sql.
  select p.prosrc into strict v_caps_src
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'customer_portal_capabilities';
  if position($x$when 'points' then v_rewards$x$ in v_caps_src) = 0
     or position($x$when 'tiers' then v_tiers$x$ in v_caps_src) = 0
     or position($x$'rewards', v_rewards$x$ in v_caps_src) = 0
     or position($x$'tiers', v_tiers$x$ in v_caps_src) = 0
     or position($x$'programmes_contract', 'v310'$x$ in v_caps_src) = 0 then
    raise exception
      'v310: customer_portal_capabilities lost the programmes/legacy cross-check binding'
      using errcode = '23514';
  end if;

  -- (e) ACL floors. create-or-replace preserves grants, but a wave that touches eleven readers
  --     states its access rather than inheriting it.
  select has_function_privilege('anon', 'public.customer_portal_capabilities(text)', 'execute'),
         has_function_privilege('authenticated', 'public.customer_portal_capabilities(text)', 'execute')
    into strict v_anon, v_authenticated;
  if v_anon or not v_authenticated then
    raise exception 'v310: customer_portal_capabilities ACL floor broken (anon=% authenticated=%)',
      v_anon, v_authenticated using errcode = '42501';
  end if;
  select has_function_privilege('anon', 'public.customer_get_reward_catalog(text)', 'execute'),
         has_function_privilege('authenticated', 'public.customer_get_reward_catalog(text)', 'execute')
    into strict v_anon, v_authenticated;
  if v_anon or not v_authenticated then
    raise exception 'v310: customer_get_reward_catalog ACL floor broken (anon=% authenticated=%)',
      v_anon, v_authenticated using errcode = '42501';
  end if;
  select has_function_privilege('anon', 'app.detect_programme_pot_split_v310()', 'execute'),
         has_function_privilege('authenticated', 'app.detect_programme_pot_split_v310()', 'execute'),
         has_function_privilege('service_role', 'app.detect_programme_pot_split_v310()', 'execute')
    into strict v_anon, v_authenticated, v_service;
  if v_anon or v_authenticated or not v_service then
    raise exception
      'v310: detector ACL floor broken (anon=% authenticated=% service_role=%)',
      v_anon, v_authenticated, v_service using errcode = '42501';
  end if;
  select has_function_privilege('anon', 'app.programme_pot_is_split_v310(uuid)', 'execute'),
         has_function_privilege('authenticated', 'app.programme_pot_is_split_v310(uuid)', 'execute'),
         has_function_privilege('service_role', 'app.programme_pot_is_split_v310(uuid)', 'execute')
    into strict v_anon, v_authenticated, v_service;
  if v_anon or v_authenticated or not v_service then
    raise exception
      'v310: split-guard ACL floor broken (anon=% authenticated=% service_role=%)',
      v_anon, v_authenticated, v_service using errcode = '42501';
  end if;

  raise notice
    'v310 verified: app.loyalty_tier_for unchanged (md5 %), pot-split detector empty, every '
    'business carries four spine rows, capabilities cross-check bound by construction, ACL '
    'floors held.', v_tier_for_after;
end
$v310_assertions$;

commit;
