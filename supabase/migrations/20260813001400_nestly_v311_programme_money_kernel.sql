-- NESTLY v311 — W5a THE MONEY WAVE, KERNEL: make "more than one accruing programme" safe.
--
-- Wave W5a of the four-programme independence plan
-- (docs/design/FOUR-PROGRAMME-INDEPENDENCE-PLAN.md §6; ledger PROGRAMME-INDEPENDENCE-001).
-- W1 built the read model (v307), W2 the derived spine (v308), W3 tagged the two money
-- tables (v309), W4a taught nine readers to speak per-programme while every spendable
-- balance stayed the business pot (v310). This is the wave that changes what a sale
-- WRITES, and it is the first one that can lose money if it is wrong.
--
-- NUMBERING. `nestly_v310` is a duplicated semantic label in production — BOTH
-- nestly_v310_programme_read_path (slot 20260813000600) and
-- nestly_v310_google_content_retention (slot 20260813001300) are applied, and neither
-- renumbers; the preflight binds the read-path suite BY NAME. v311 is the next free
-- semantic version and 20260813001400 the next free slot (both re-checked against
-- origin/main and the canonical plan at registration).
--
-- ---------------------------------------------------------------------------
-- WHAT CHANGES
-- ---------------------------------------------------------------------------
--
--  1. THE EARN LOOP. app.on_sale_recorded stops picking ONE engine with an if/elsif
--     (v37b:653-654) and loops over the business's ACTIVE ACCRUING spine rows (points,
--     stamps), exactly the shape the retention engine in the same function has had since
--     v37b:665-683. One sale at a points+stamps firm now legitimately produces one stamp
--     AND N points: two ledger rows and two batches with different programme_id. Owner
--     ruling 3 (plan:13-14) permits any subset of programmes to run simultaneously.
--
--  2. THE ANTI-DOUBLE-EARN CONSTRAINT FLIPS. `points_earn_once_per_sale (sale_id)`
--     (v2:70-71) is dropped and `points_earn_once_per_sale_per_programme
--     (sale_id, programme_id)` (v309:399-401) becomes authoritative, in the SAME
--     transaction as the removal of the v308 exclusive-accrual tripwire. V308 standing
--     invariant 3 and V309 standing invariant 1 both require exactly this pairing.
--
--  3. THE ARBITER IS NAMED. v37b:659's `on conflict do nothing returning id into v_earn_id`
--     is arbiter-less: it absorbs a conflict from ANY unique index on points_ledger. Ship
--     the loop with the old index still present and iteration 2 (stamps) conflicts on
--     sale_id alone, DO NOTHING swallows it, row_count is 0, and the stamps programme
--     silently never earns — forever, on every sale, with correct-looking totals that a
--     double-fire rehearsal cannot see. `on conflict (sale_id, programme_id) where
--     entry_type='earn' and sale_id is not null` can only ever absorb the intended
--     constraint AND fails at plan time if its index is absent, so the loop physically
--     cannot ship without the swap. Idempotency is read from `get diagnostics row_count`,
--     never from RETURNING INTO: in a loop that is a loop-carried variable governing a
--     money write, and its correctness must be stated, not implied.
--
--  4. programme_id IS NOT NULL on public.points_ledger and public.points_batches, and the
--     write guard grows two shape rules: no untagged points row, and no row tagged with
--     another tenant's programme (the FK references business_programmes(id) only — it does
--     not constrain the business). v309 shipped the columns nullable ON PURPOSE and said
--     W5 lands NOT NULL "after the tag has been observed on live traffic"; that observation
--     is on the record (V309 evidence:178-186 — a real sale through record_quick_sale
--     arrived tagged on both tables; committed state 39/37 rows, zero nulls).
--
--  5. THE TIER MULTIPLIER MOVES INSIDE THE POINTS BRANCH. Today v37b:655-656 sits outside
--     the model choice, so a Gold customer at a stamps firm earns MULTIPLIED STAMPS
--     (plan §1:55-57). And app.loyalty_tier_for — the earn multiplier, the fourth D1 twin
--     v310 deliberately left alone (v310:26-35) — gets the points-programme fuel filter,
--     written the only safe way: resolved into a variable with an explicit unfiltered
--     FALL-OPEN when the spine row is missing. Written inline as
--     `programme_id = (subselect)` a NULL zeroes every tier and therefore every multiplier,
--     silently changing what every sale earns.
--
--  6. NINE WRITE PATHS ARE PROGRAMME-SCOPED. Every function in public/app that writes
--     points_ledger or points_batches was enumerated live; the redeem paths, the expiry
--     sweep, the owner adjust, the fast correction and the redemption reversal all
--     assumed one pot. The sweep is the highest-severity miss: its inner batch loop has
--     no date condition in the `inactivity` branch (v20:1027), so a points inactivity
--     policy would zero a customer's STAMP CARD.
--
-- ---------------------------------------------------------------------------
-- WHAT DOES NOT CHANGE
-- ---------------------------------------------------------------------------
--
--  * No client change. app/app.js and app/index.html carry ZERO diff; no RPC signature
--    moves (adjust_points deliberately gains no parameter); the wizard stays single-choice
--    and the spine stays DERIVED. After the tripwire is dropped production still cannot
--    reach two accruing programmes through any UI path — business_programmes.active is
--    derived by the one-way v308 sync from loyalty_programs/businesses (v308:398-448),
--    loyalty_programs.loyalty_model is CHECK-constrained single-valued, and the W1 points
--    predicate is model-exclusive. The rehearsal FORCES the "both" shape with a direct
--    service_role UPDATE after the drop, and that state is not durable until W6 flips
--    authority. This is the strongest single argument that W5a is safe to apply.
--  * Every W4a read payload keeps its exact shape, including balance_scope='business_pot'.
--    Only W5b moves that VALUE, per firm.
--  * points_ledger stays append-only. This migration UPDATEs no ledger row, retags no
--    history, and does NOT re-open the v26 named-trigger disable (v26:185-188) that V309
--    standing invariant 2 requires to be said out loud. The pot machinery — which needs
--    none of it either — is W5b.
--
-- ---------------------------------------------------------------------------
-- OWNER DECISION D8 (answered, recommended option)
-- ---------------------------------------------------------------------------
-- Stamp batches are written with expires_at = NULL. v37b:661 wrote now()+expiry_days
-- whenever expiry_mode='fixed' REGARDLESS of model, and the sweep never touched it because
-- it gates on lp.kind='points' (v20:993). Once the sweep is programme-scoped that stored
-- date becomes real, and storing an expiry date nobody authored is a liability the product
-- cannot explain. Stamps get their own expiry policy at W6. Blast radius today: zero —
-- the only stamps firm (Hougang ABC) has expiry_mode='none' and active=false.
--
-- ---------------------------------------------------------------------------
-- LIVE-BODY DISCIPLINE
-- ---------------------------------------------------------------------------
-- Every function this migration re-states was reconstructed from its REAL repo lineage on
-- a throwaway PG17 cluster and its md5(prosrc) matched the value read from production on
-- 2026-08-13 BEFORE a line of this file was written. The pins in §0 are those values.
--
--   app.on_sale_recorded()                    21345c7f8a5d6d11174f3456ac6c709c  (5337)
--       = v37b:642-698 verbatim + v121:57's replace(). RE-STATED, not spliced: W5
--       restructures the whole earn block, and a replace() over a multi-statement region
--       is unreviewable.
--   app.loyalty_tier_for(uuid,uuid)           44c7a3dc7f07475ebc2d43e4e10ab24d  (1054)
--   app.loyalty_ledger_write_guard()          4112eb9fbf4dc4f7200af552067534f2  (4170)
--   app.run_points_expiry_for_business(uuid)  317f32e56b4fef8c61ca5ab280ad69e4  (2491)
--   app.run_points_expiry()                   4f1dbae90bd17ce70b1f3821b26f7d3d  (304)
--   public.adjust_points(uuid,uuid,int,text)  88dffb4a6c46383854ea0d60ee0747c6  (3521)
--   app.redeem_reward_core(7)                 4f53e97040298d0cedca749b8119df15  (10305)
--       = v34:508-605 + the v176b tier-gate patch. Its live body is reproduced by NO
--       repo file, so it is SPLICED, never re-stated — re-stating would silently revert
--       the reward tier gate.
--   app.redeem_points_v40_internal(3)         96a13b54f360296a484aed4812230104  (5999)
--   public.redeem_points(uuid,uuid)           21d498d866711c25b12b2aa24d79b0ad  (4132)
--   public.reverse_loyalty_redemption_v34_base ecd4fbd39c0bfc53afc929c91feba4a1 (7166)
--   public.correct_quick_sale_amount_v84       3061566c5196509fe84ef76da635556d (17263)
--       = v84:210-651 + v134:77-78's Nestly->Peekaa runtime copy rewrite (same length,
--       different bytes — the reason a length check alone is not a pin).
--   app.resolve_ledger_programme_v309(uuid)   04883a5b68de9f0f81e0145a8944e5ef  (398)
--   app.tag_ledger_programme_v309()           5406fc1c89e32c31794bbc9eacf111ed  (146)
--       pinned COMMENT-NORMALISED: production applies strip full-line comments, so the
--       live body is 146 bytes where the repo file's is 357. Normalised, they are
--       byte-identical, and the pin matches both a stripped and an unstripped predecessor.
--
-- Idempotence: every block detects its own post-state structurally (never by a comment,
-- which production strips) and skips. Re-running this migration is a no-op.
--
-- Lock order (V308 standing invariant 1): no path here takes a spine lock, and no path
-- edits loyalty_tiers rungs, so the DEFERRABLE INITIALLY DEFERRED tier sync (V308 SI-2)
-- never needs flushing. Stated so it can be asserted.

begin;

-- ---------------------------------------------------------------------------
-- 0. Fail-closed predecessor pins + pre-state assertions.
-- ---------------------------------------------------------------------------

do $v311_pins$
declare
  v_applied boolean;
  v_md5 text;
  v_norm text;
  v_sig text;
  v_expected text;
  v_nulls bigint;
  v_detected integer;
begin
  select position('for v_prog in' in p.prosrc) > 0 into v_applied
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'app' and p.proname = 'on_sale_recorded';
  if v_applied is null then
    raise exception 'v311: app.on_sale_recorded is missing';
  end if;
  if v_applied then
    raise notice 'v311 already applied (earn loop present); predecessor pins skipped';
    return;
  end if;

  -- The money kernel. One pin, one value: the live body carries ZERO full-line comments,
  -- so its raw and comment-normalised md5s are identical.
  select md5(p.prosrc) into strict v_md5
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'app' and p.proname = 'on_sale_recorded';
  if v_md5 <> '21345c7f8a5d6d11174f3456ac6c709c' then
    raise exception 'v311: unexpected app.on_sale_recorded predecessor md5=%', v_md5;
  end if;

  for v_sig, v_expected in
    select * from (values
      ('app.loyalty_tier_for(uuid,uuid)',                              '44c7a3dc7f07475ebc2d43e4e10ab24d'),
      ('app.loyalty_ledger_write_guard()',                             '4112eb9fbf4dc4f7200af552067534f2'),
      ('app.run_points_expiry_for_business(uuid)',                     '317f32e56b4fef8c61ca5ab280ad69e4'),
      ('app.run_points_expiry()',                                      '4f1dbae90bd17ce70b1f3821b26f7d3d'),
      ('public.adjust_points(uuid,uuid,integer,text)',                 '88dffb4a6c46383854ea0d60ee0747c6'),
      ('app.redeem_reward_core(uuid,uuid,uuid,text,uuid,uuid,uuid)',   '4f53e97040298d0cedca749b8119df15'),
      ('app.redeem_points_v40_internal(uuid,uuid,text)',               '96a13b54f360296a484aed4812230104'),
      ('public.redeem_points(uuid,uuid)',                              '21d498d866711c25b12b2aa24d79b0ad'),
      ('public.reverse_loyalty_redemption_v34_base(uuid,uuid,text,text)', 'ecd4fbd39c0bfc53afc929c91feba4a1'),
      ('public.correct_quick_sale_amount_v84(uuid,uuid,integer,text,text)', '3061566c5196509fe84ef76da635556d'),
      ('app.resolve_ledger_programme_v309(uuid)',                      '04883a5b68de9f0f81e0145a8944e5ef')
    ) pinned(signature, expected)
  loop
    if to_regprocedure(v_sig) is null then
      raise exception 'v311: pinned predecessor is missing: %', v_sig using errcode = '42883';
    end if;
    select md5(p.prosrc) into strict v_md5 from pg_proc p where p.oid = to_regprocedure(v_sig);
    if v_md5 <> v_expected then
      raise exception 'v311: unexpected predecessor md5 for % (expected %, got %)',
        v_sig, v_expected, v_md5;
    end if;
  end loop;

  -- Comment-normalised pin: production applies strip full-line comments.
  select md5(array_to_string(array(
           select line from regexp_split_to_table(p.prosrc, E'\n') line
            where btrim(line) not like '--%'), E'\n'))
    into strict v_norm
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'app' and p.proname = 'tag_ledger_programme_v309';
  if v_norm <> '5406fc1c89e32c31794bbc9eacf111ed' then
    raise exception 'v311: unexpected app.tag_ledger_programme_v309 normalised md5=%', v_norm;
  end if;

  -- Index + tripwire pre-state (v309:536-548 is the template).
  if not exists (
    select 1 from pg_index i join pg_class c on c.oid = i.indexrelid
     where c.relname = 'points_earn_once_per_sale' and i.indisunique and i.indisvalid
  ) then
    raise exception 'v311: the v2 points_earn_once_per_sale index is not in its expected pre-state';
  end if;
  if not exists (
    select 1 from pg_index i join pg_class c on c.oid = i.indexrelid
     where c.relname = 'points_earn_once_per_sale_per_programme' and i.indisunique and i.indisvalid
  ) then
    raise exception 'v311: the v309 per-programme index is missing; the swap has nothing to swap to';
  end if;
  if not exists (
    select 1 from pg_trigger t
     where t.tgrelid = 'public.business_programmes'::regclass
       and t.tgname = 'business_programmes_exclusive_accrual_v308'
  ) then
    raise exception 'v311: the v308 exclusive-accrual tripwire is already gone';
  end if;

  -- The loop's cardinality bound is STRUCTURAL: unique (business_id, kind) on the spine
  -- (v308:143) means the loop can never process a kind twice, hence never write more than
  -- two earn rows for one sale.
  if not exists (
    select 1 from pg_constraint
     where conrelid = 'public.business_programmes'::regclass
       and contype = 'u'
       and conkey = (
         select array_agg(a.attnum order by a.attname)
           from pg_attribute a
          where a.attrelid = 'public.business_programmes'::regclass
            and a.attname in ('business_id','kind'))
  ) then
    raise exception 'v311: business_programmes is missing unique (business_id, kind); the earn loop is unbounded';
  end if;

  -- NOT NULL is only defensible because the tag has been observed on live traffic.
  select count(*) into v_nulls from public.points_ledger where programme_id is null;
  if v_nulls <> 0 then
    raise exception 'v311: % points_ledger rows are still untagged; NOT NULL would fail', v_nulls;
  end if;
  select count(*) into v_nulls from public.points_batches where programme_id is null;
  if v_nulls <> 0 then
    raise exception 'v311: % points_batches rows are still untagged; NOT NULL would fail', v_nulls;
  end if;

  select count(*) into strict v_detected from app.detect_double_earn_v309();
  if v_detected <> 0 then
    raise exception 'v311: the double-earn detector is not empty (% rows) before the swap', v_detected;
  end if;
end
$v311_pins$;

-- ---------------------------------------------------------------------------
-- 1. THE SWAP. Old index out, tripwire out, columns NOT NULL — before the loop.
--
--    Ordering inside this transaction is load-bearing, not stylistic: the old index is
--    dropped BEFORE app.on_sale_recorded is replaced, so a loop naming the new arbiter can
--    never coexist for one statement with an index that would silently absorb its second
--    iteration. Nothing writes a spine row between the tripwire drop and the index drop.
-- ---------------------------------------------------------------------------

drop trigger if exists business_programmes_exclusive_accrual_v308 on public.business_programmes;
drop function if exists app.business_programmes_exclusive_accrual_v308();

drop index if exists public.points_earn_once_per_sale;

comment on index public.points_earn_once_per_sale_per_programme is
  'v311 W5a: THE anti-double-earn constraint. One earn row per (sale, programme) — the '
  'shape that exists only to permit two earn rows for one sale at a firm running points '
  'and stamps together. It replaced the v2 points_earn_once_per_sale (unique on sale_id '
  'alone) in the same transaction that removed the v308 exclusive-accrual tripwire, per '
  'V308 standing invariant 3 and V309 standing invariant 1. app.on_sale_recorded NAMES it '
  'as its ON CONFLICT arbiter, so the earn loop cannot be shipped without it.';

alter table public.points_ledger  alter column programme_id set not null;
alter table public.points_batches alter column programme_id set not null;

comment on column public.points_ledger.programme_id is
  'v309 W3 / v311 W5a: which programme this row belongs to (public.business_programmes). '
  'NOT NULL since v311. Supplied explicitly by app.on_sale_recorded''s earn loop and by '
  'every scoped write path; app.tag_ledger_programme_v309 remains as the BEFORE INSERT '
  'default for a writer nobody enumerated — it only ever fills a NULL and never overrides.';
comment on column public.points_batches.programme_id is
  'v309 W3 / v311 W5a: which programme this batch belongs to. NOT NULL since v311. Without '
  'it FEFO cannot be scoped per programme and redeem_reward_core''s batch proof (v34:571) '
  'has nothing to filter on.';

-- ---------------------------------------------------------------------------
-- 2. app.loyalty_tier_for — the D1 tier-fuel filter on the EARN MULTIPLIER.
--
--    v310 changed the three READ twins and asserted this one unchanged (v310:1211-1215)
--    because it is the multiplier, not a display metric. This is the wave allowed to move
--    it, and the fail-open branch is the highest-severity line in the whole design: a NULL
--    spine row must yield the UNFILTERED sum, never a zeroed tier.
--    Re-stated from v148:405-440; only the else branch moves.
-- ---------------------------------------------------------------------------

create or replace function app.loyalty_tier_for(p_business uuid,p_client uuid)
returns public.loyalty_tiers
language plpgsql
stable
security definer
set search_path to 'pg_catalog','public','app','pg_temp'
as $$
declare
  v_basis text;
  v_metric numeric;
  v_row public.loyalty_tiers%rowtype;
  v_points_programme uuid;
begin
  select tier_basis into v_basis
  from public.loyalty_programs
  where business_id=p_business;
  v_basis:=coalesce(v_basis,'visits');
  if v_basis='visits' then
    select count(*) into v_metric from public.sales
    where business_id=p_business and client_id=p_client and counts_as_visit;
  elsif v_basis='spend' then
    select coalesce(sum(amount_cents),0)/100.0 into v_metric from public.sales
    where business_id=p_business and client_id=p_client and counts_as_revenue;
  else
    select spine.id into v_points_programme
      from public.business_programmes spine
     where spine.business_id=p_business and spine.kind='points';
    if v_points_programme is null then
      select coalesce(sum(points),0) into v_metric from public.points_ledger
      where business_id=p_business and client_id=p_client and entry_type='earn';
    else
      select coalesce(sum(pl.points),0) into v_metric from public.points_ledger pl
      where pl.business_id=p_business and pl.client_id=p_client
        and pl.entry_type='earn' and pl.programme_id=v_points_programme;
    end if;
  end if;
  select * into v_row from public.loyalty_tiers
  where business_id=p_business
    and threshold<=v_metric
    and (effective_from is null or effective_from<=statement_timestamp())
    and (expires_at is null or expires_at>statement_timestamp())
  order by threshold desc,sort desc,id
  limit 1;
  return v_row;
end
$$;

revoke all privileges on function app.loyalty_tier_for(uuid,uuid) from public, anon, authenticated;

comment on function app.loyalty_tier_for(uuid,uuid) is
  'v148 tier resolver, v311 W5a: the points_earned basis is now fuelled by the POINTS '
  'programme''s earn rows only (owner decision D1 — points fuel tiers, stamps never do), '
  'joining the three read twins v310 moved. The spine row is resolved INTO A VARIABLE with '
  'an explicit unfiltered fallback: written inline as `programme_id = (subselect)` a NULL '
  'would make the predicate never true, zeroing every tier and therefore every earn '
  'multiplier — a silent change to what every sale earns. Recorded behaviour change: a '
  'tier_basis=''points_earned'' firm on loyalty_model=''stamps'' used to climb on stamps and '
  'now climbs on 0; zero live tenants are on that shape (all 10 live programmes are '
  'visits-basis) and W6 closes it with a silent points programme for tiers-only firms.';

-- ---------------------------------------------------------------------------
-- 3. app.loyalty_ledger_write_guard — the points_ledger shape rules.
--
--    v309:48-57 deliberately named trg_points_ledger_programme_tag_v309 so it sorts BEFORE
--    trg_points_ledger_write_guard, "so W5 can add a programme_id shape rule to the guard
--    without renaming a trigger on a money table". This is that rule, cashed in.
--    Re-stated from v84:120-205; the credit_ledger branch is byte-identical.
-- ---------------------------------------------------------------------------

create or replace function app.loyalty_ledger_write_guard()
returns trigger
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_token text;
  v_scope text;
begin
  if tg_table_name='points_ledger' then
    v_token:=nullif(current_setting('app.points_ledger_insert_id',true),'');
    v_scope:=nullif(current_setting('app.points_ledger_write_scope',true),'');
    if v_token is distinct from new.id::text or v_scope not in
       ('sale_trigger','redeem_points','adjust_points','points_expiry',
        'redemption_reversal','sale_amount_correction_v84') then
      raise exception 'points_ledger may only be appended by approved loyalty routes'
        using errcode='42501';
    end if;
    if (v_scope='sale_trigger'
          and (new.entry_type<>'earn' or new.points<=0 or new.sale_id is null))
       or (v_scope='redeem_points'
          and (new.entry_type<>'redeem' or new.points>=0 or new.sale_id is not null))
       or (v_scope='adjust_points'
          and (new.entry_type<>'adjust' or new.points=0 or new.sale_id is not null
               or new.actor is distinct from auth.uid()))
       or (v_scope='points_expiry'
          and (new.entry_type<>'expire' or new.points>=0 or new.sale_id is not null
               or new.actor is not null))
       or (v_scope='redemption_reversal'
          and (new.entry_type<>'adjust' or new.points<=0 or new.sale_id is not null
               or new.actor is distinct from auth.uid()))
       or (v_scope='sale_amount_correction_v84'
          and (new.entry_type<>'adjust' or new.points>=0 or new.sale_id is null
               or new.actor is distinct from auth.uid())) then
      raise exception 'points ledger entry does not match its internal route'
        using errcode='check_violation';
    end if;
    -- v311 W5a. The tag trigger fires first (v309:48-57), so by here programme_id is
    -- either what the writer supplied or the single-pot default; NULL means a writer the
    -- tag trigger does not cover on a table where it is now NOT NULL.
    if new.programme_id is null then
      raise exception 'points ledger entry has no programme'
        using errcode='check_violation';
    end if;
    -- The FK (points_ledger_programme_fk) references business_programmes(id) only; it does
    -- NOT constrain the business. v309 asserted zero cross-tenant tags once, at backfill.
    -- This makes it permanent, for one PK lookup per insert.
    if not exists (
      select 1 from public.business_programmes bp
       where bp.id=new.programme_id and bp.business_id=new.business_id
    ) then
      raise exception 'points ledger entry is tagged with another tenant''s programme'
        using errcode='42501';
    end if;
  elsif tg_table_name='credit_ledger' then
    v_token:=nullif(current_setting('app.credit_ledger_insert_id',true),'');
    v_scope:=nullif(current_setting('app.credit_ledger_write_scope',true),'');
    if v_token is distinct from new.id::text or v_scope not in
       ('sale_trigger','redeem_points','redeem_gift_card','enroll_membership',
        'membership_renewal','credit_tender','sale_reversal','redemption_reversal') then
      raise exception 'credit_ledger may only be appended by approved routes'
        using errcode='42501';
    end if;
    if (v_scope='sale_trigger'
          and (new.entry_type not in ('loyalty_earn','referral_reward')
               or new.amount_cents<=0 or new.sale_id is null))
       or (v_scope='redeem_points'
          and (new.entry_type<>'loyalty_earn' or new.amount_cents<=0
               or new.sale_id is not null or new.payment_id is not null
               or new.actor is distinct from auth.uid()))
       or (v_scope='redeem_gift_card'
          and (new.entry_type<>'gift_card_load' or new.amount_cents<=0
               or new.sale_id is not null or new.payment_id is not null
               or new.actor is distinct from auth.uid()))
       or (v_scope='enroll_membership'
          and (new.entry_type<>'membership_credit' or new.amount_cents<=0
               or new.sale_id is null or new.payment_id is not null
               or new.actor is distinct from auth.uid()))
       or (v_scope='membership_renewal'
          and (new.entry_type<>'membership_credit' or new.amount_cents<=0
               or new.sale_id is null or new.actor is not null))
       or (v_scope='credit_tender'
          and (new.entry_type<>'spend' or new.amount_cents>=0
               or new.sale_id is null or new.payment_id is null
               or new.actor is distinct from auth.uid()))
       or (v_scope='sale_reversal'
          and (new.entry_type<>'manual_adjust' or new.amount_cents=0
               or new.sale_id is null or new.actor is distinct from auth.uid()))
       or (v_scope='redemption_reversal'
          and (new.entry_type<>'manual_adjust' or new.amount_cents>=0
               or new.sale_id is not null or new.payment_id is not null
               or new.actor is distinct from auth.uid())) then
      raise exception 'credit ledger entry does not match its internal route'
        using errcode='check_violation';
    end if;
  else
    raise exception 'unexpected loyalty ledger table';
  end if;
  return new;
end
$$;

revoke all privileges on function app.loyalty_ledger_write_guard()
  from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 4. app.on_sale_recorded — THE EARN LOOP.
--
--    RE-STATED from the reconstructed lineage (v37b:642-698 + v121:57), which replays to
--    md5 21345c7f8a5d6d11174f3456ac6c709c. Exactly one region moves: live prosrc 17-25
--    (the if/elsif engine picker, the unconditional tier multiplier, the arbiter-less
--    insert and the untagged batch) becomes the loop. The v121 predicate at prosrc 7-14 is
--    kept VERBATIM — the whole loop lives inside it. v37b:665-696 (retention + referral)
--    is byte-identical, and the retention engine at :666-683 is the shape being copied:
--    versioned, per-row, looped per sale, per-programme-idempotent.
-- ---------------------------------------------------------------------------

create or replace function app.on_sale_recorded()
returns trigger language plpgsql security definer
set search_path to 'pg_catalog','public','app','pg_temp' as $$
declare lp record; rp record; refrow record; refprog record; v_tier public.loyalty_tiers%rowtype;
  v_pts integer; v_idx integer; v_count integer; v_earn_id uuid; v_credit_id uuid;
  w_start timestamptz; w_end timestamptz;
  v_prog record; v_rows integer; v_expires timestamptz; v_earn_rows integer; v_batch_rows integer;
begin
  if new.reversal_of is not null or new.client_id is null or not(new.earns_points or new.counts_as_visit) then return new; end if;
  if new.earns_points
     and exists(
       select 1
       from app.effective_platform_module_mode_v94(
         new.business_id,new.branch_id,'loyalty'
       ) effective
       where effective.mode='rw'
     ) then
    select * into lp from app.resolve_loyalty_branch_config(new.business_id,new.branch_id,new.config_version_id);
    if found and lp.active then
      for v_prog in
        select spine.id, spine.kind
          from public.business_programmes spine
         where spine.business_id=new.business_id
           and spine.active
           and spine.kind in ('points','stamps')
         order by spine.sort
      loop
        v_earn_id:=gen_random_uuid(); v_rows:=0; v_pts:=0; v_expires:=null;
        if v_prog.kind='stamps' then
          v_pts:=case when coalesce(lp.stamp_per_cents,0)>0 then floor(new.amount_cents::numeric/lp.stamp_per_cents) else 0 end;
        elsif v_prog.kind='points' and lp.kind='points' then
          v_pts:=floor((new.amount_cents/100.0)*lp.earn_points_per_dollar);
          select * into v_tier from app.loyalty_tier_for(new.business_id,new.client_id);
          if v_tier.id is not null and v_tier.points_multiplier>1 then v_pts:=floor(v_pts*v_tier.points_multiplier); end if;
          v_expires:=case when lp.expiry_mode='fixed' then now()+make_interval(days=>lp.expiry_days) end;
        else
          v_pts:=0;
        end if;
        if v_pts>0 then
          perform set_config('app.points_ledger_insert_id',v_earn_id::text,true); perform set_config('app.points_ledger_write_scope','sale_trigger',true);
          insert into public.points_ledger(id,business_id,client_id,entry_type,points,sale_id,reference,actor,programme_id)
          values(v_earn_id,new.business_id,new.client_id,'earn',v_pts,new.id,'auto-earn on sale',auth.uid(),v_prog.id)
          on conflict (sale_id,programme_id) where entry_type='earn' and sale_id is not null do nothing;
          get diagnostics v_rows=row_count;
          perform set_config('app.points_ledger_insert_id','',true); perform set_config('app.points_ledger_write_scope','',true);
          if v_rows=1 then
            insert into public.points_batches(business_id,client_id,earned,remaining,sale_id,earned_at,expires_at,programme_id)
            values(new.business_id,new.client_id,v_pts,v_pts,new.id,now(),v_expires,v_prog.id);
          end if;
        end if;
      end loop;
      select count(*) into v_earn_rows from public.points_ledger l where l.sale_id=new.id and l.entry_type='earn';
      select count(*) into v_batch_rows from public.points_batches b where b.sale_id=new.id;
      if v_earn_rows<>v_batch_rows then
        raise exception 'earn loop left ledger/batch parity broken for sale %',new.id using errcode='XX001';
      end if;
    end if;
  end if;
  if new.counts_as_visit then
    for rp in select * from public.retention_program_versions where business_id=new.business_id and config_version_id=new.config_version_id and active loop
      v_idx:=floor(extract(epoch from(new.occurred_at-rp.starts_on::timestamptz))/(rp.period_days*86400));
      if v_idx>=0 then
        w_start:=rp.starts_on::timestamptz+make_interval(days=>v_idx*rp.period_days); w_end:=w_start+make_interval(days=>rp.period_days);
        select count(*) into v_count from public.sales s where s.business_id=new.business_id and s.client_id=new.client_id and s.counts_as_visit and s.reversal_of is null and not exists(select 1 from public.sales r where r.business_id=s.business_id and r.reversal_of=s.id) and s.occurred_at>=w_start and s.occurred_at<w_end;
        if v_count>=rp.goal_visits then
          begin
            insert into public.reward_grants(business_id,program_id,client_id,period_index,reward_type,reward_value,reward_item,config_version_id,retention_program_version_id)
            values(new.business_id,rp.program_id,new.client_id,v_idx,rp.fulfillment_kind,coalesce(rp.discount_percent,rp.credit_cents,0),rp.manual_item,new.config_version_id,rp.id);
            if rp.fulfillment_kind='credit' and rp.credit_cents>0 then
              v_credit_id:=gen_random_uuid(); perform set_config('app.credit_ledger_insert_id',v_credit_id::text,true); perform set_config('app.credit_ledger_write_scope','sale_trigger',true);
              insert into public.credit_ledger(id,business_id,client_id,entry_type,amount_cents,reference,sale_id,actor) values(v_credit_id,new.business_id,new.client_id,'loyalty_earn',rp.credit_cents,'retention reward: '||rp.name,new.id,auth.uid());
              perform set_config('app.credit_ledger_insert_id','',true); perform set_config('app.credit_ledger_write_scope','',true);
            end if;
          exception when unique_violation then null; end;
        end if;
      end if;
    end loop;
    select r.* into refrow from public.referrals r where r.business_id=new.business_id and r.referred_client_id=new.client_id and r.status='pending' limit 1;
    if found then
      select * into refprog from public.referral_programs where business_id=new.business_id and enabled limit 1;
      if found and new.amount_cents>=coalesce(refprog.min_spend_cents,0) then
        update public.referrals set status='rewarded',qualified_at=now(),qualified_sale_id=new.id,reward_cents=refprog.reward_cents where id=refrow.id and status='pending';
        if found then
          v_credit_id:=gen_random_uuid(); perform set_config('app.credit_ledger_insert_id',v_credit_id::text,true); perform set_config('app.credit_ledger_write_scope','sale_trigger',true);
          insert into public.credit_ledger(id,business_id,client_id,entry_type,amount_cents,reference,sale_id,actor) values(v_credit_id,new.business_id,refrow.referrer_client_id,'referral_reward',refprog.reward_cents,'referral qualified: first visit completed',new.id,auth.uid());
          perform set_config('app.credit_ledger_insert_id','',true); perform set_config('app.credit_ledger_write_scope','',true);
        end if;
      end if;
    end if;
  end if;
  return new;
end $$;

revoke all on function app.on_sale_recorded() from public,anon,authenticated;

comment on function app.on_sale_recorded() is
  'v37b sale engine, v121 effective-loyalty boundary, v311 W5a earn LOOP. Loops over the '
  'business''s ACTIVE ACCRUING spine rows (points, stamps) in sort order, writes one earn '
  'row and one batch per programme, and takes its idempotency from get diagnostics '
  'row_count on an insert whose ON CONFLICT arbiter NAMES '
  'points_earn_once_per_sale_per_programme. programme_id is resolved INSIDE the trigger '
  'from public.business_programmes, which no browser role can write — never caller-'
  'supplied. The tier multiplier applies to the points branch only (owner decision D1). '
  'The loop is bounded at two iterations by unique (business_id, kind) on the spine, and '
  'the post-loop parity assertion turns a swallowed conflict from a silent desync into an '
  'XX001.';

-- ---------------------------------------------------------------------------
-- 5. THE SCOPED WRITE PATHS.
--
--    Complete live inventory of everything in public/app that writes points_ledger or
--    points_batches. Shipping the loop while any of these is unfiltered is a deliberately
--    shipped money bug, even where "unreachable today" — and unreachable-today is exactly
--    the claim that stops being true at W6.
-- ---------------------------------------------------------------------------

-- 5.1 app.run_points_expiry_for_business — the sweep. HIGHEST-SEVERITY MISS.
--     Its inner batch loop has NO date condition in the inactivity branch (v20:1027), so
--     an inactivity policy configured for the points programme would zero a customer's
--     STAMP CARD. It fails CLOSED, the opposite of the tier metric: a sweep that cannot
--     resolve a programme expires nothing, because expiring on a guess is theft.
--     Re-stated from v20:974-1049; four edits, marked. One further correction, not a
--     behaviour change: v20 shipped both sweep functions with `set search_path = public`,
--     which predates the v21 hardening. Re-stating that verbatim would silently DOWNGRADE
--     the applied catalog (and the phase0 hardening guard refuses it), so both are re-stated
--     on the canonical v21 path. Every relation the bodies touch is already schema-qualified
--     and gen_random_uuid() is a pg_catalog builtin, so resolution is unchanged.

create or replace function app.run_points_expiry_for_business(p_business uuid)
returns integer
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_client record;
  v_batch record;
  v_points_id uuid;
  v_expired integer := 0;
  v_points_programme uuid;
begin
  -- v311 (i): resolve once, fail CLOSED.
  select spine.id into v_points_programme
    from public.business_programmes spine
   where spine.business_id = p_business and spine.kind = 'points';
  if v_points_programme is null then
    return 0;
  end if;

  for v_client in
    select distinct pb.business_id, pb.client_id
      from public.points_batches pb
      join public.loyalty_programs lp on lp.business_id = pb.business_id
     where pb.business_id = p_business
       and pb.remaining > 0
       and pb.programme_id = v_points_programme            -- v311 (ii)
       and lp.active
       and lp.kind = 'points'
       and coalesce(lp.expiry_days, 0) > 0
       and (
         (lp.expiry_mode = 'fixed' and pb.expires_at <= now())
         or (
           lp.expiry_mode = 'inactivity'
           and not exists (
             select 1
               from public.points_ledger pl
              where pl.business_id = pb.business_id
                and pl.client_id = pb.client_id
                and pl.points > 0
                and pl.programme_id = pb.programme_id      -- v311 (iii)
                -- v311 (iii): a programme-pot transfer must not reset the inactivity
                -- clock. actor IS NULL on an 'adjust' row is provably unique to the W5b
                -- transfer scope: the write guard forces actor = auth.uid() on
                -- adjust_points, redemption_reversal and sale_amount_correction_v84.
                and not (pl.entry_type = 'adjust' and pl.actor is null)
                and pl.created_at > now() - make_interval(days => lp.expiry_days)
           )
         )
       )
  loop
    perform 1 from public.clients c
     where c.id = v_client.client_id
       and c.business_id = v_client.business_id
       for update;

    for v_batch in
      select pb.id, pb.remaining, pb.programme_id
        from public.points_batches pb
        join public.loyalty_programs lp on lp.business_id = pb.business_id
       where pb.business_id = v_client.business_id
         and pb.client_id = v_client.client_id
         and pb.remaining > 0
         and pb.programme_id = v_points_programme          -- v311 (ii)
         and lp.active
         and lp.kind = 'points'
         and coalesce(lp.expiry_days, 0) > 0
         and (
           (lp.expiry_mode = 'fixed' and pb.expires_at <= now())
           or lp.expiry_mode = 'inactivity'
         )
       order by pb.expires_at nulls last, pb.earned_at, pb.id
       for update of pb skip locked
    loop
      v_points_id := gen_random_uuid();
      perform set_config('app.points_ledger_insert_id', v_points_id::text, true);
      perform set_config('app.points_ledger_write_scope', 'points_expiry', true);
      insert into public.points_ledger (
        id, business_id, client_id, entry_type, points, reference, actor, programme_id
      ) values (
        v_points_id, v_client.business_id, v_client.client_id,
        'expire', -v_batch.remaining, 'points expiry batch ' || v_batch.id, null,
        v_batch.programme_id                                -- v311 (iv)
      );
      perform set_config('app.points_ledger_insert_id', '', true);
      perform set_config('app.points_ledger_write_scope', '', true);

      update public.points_batches set remaining = 0 where id = v_batch.id;
      v_expired := v_expired + v_batch.remaining;
    end loop;
  end loop;
  return v_expired;
end $$;

revoke execute on function app.run_points_expiry_for_business(uuid)
  from public, anon, authenticated;

comment on function app.run_points_expiry_for_business(uuid) is
  'v20 points expiry sweep, v311 W5a programme-scoped. Both the client selection and the '
  'inner batch loop are filtered to the POINTS programme''s batches, the inactivity clock '
  'is read per programme (excluding the W5b pot-transfer row, which would otherwise '
  'postpone every switched customer''s expiry), and the expire row is tagged with the '
  'batch''s programme. Fails CLOSED: no points spine row means expire nothing.';

-- 5.2 app.run_points_expiry — the daily driver (cron frenly-points-expiry :: 0 19 * * *).
--     Hygiene only after 5.1: a stamps-only firm''s sweep is already a no-op.

create or replace function app.run_points_expiry()
returns void
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $$
declare
  v_business uuid;
begin
  for v_business in
    select distinct lp.business_id
      from public.loyalty_programs lp
     where lp.active
       and lp.kind = 'points'
       and coalesce(lp.expiry_days, 0) > 0
       and exists (                                        -- v311
         select 1 from public.business_programmes spine
          where spine.business_id = lp.business_id
            and spine.kind = 'points'
            and spine.active
       )
  loop
    perform app.run_points_expiry_for_business(v_business);
  end loop;
end $$;

revoke execute on function app.run_points_expiry()
  from public, anon, authenticated;

-- 5.3 public.adjust_points — owner manual adjustment.
--     Re-stated from v173:55-171. The RPC gains NO parameter: a signature change is a
--     client change, and the wizard/UI must not move this wave. Owner adjustment of a
--     STAMP count is a W6 feature with its own UI.

create or replace function public.adjust_points(
  p_business uuid, p_client uuid, p_points integer, p_reason text
)
returns integer
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'app', 'pg_temp'
as $function$
declare
  v_actor uuid := auth.uid();
  v_staff uuid;
  v_balance integer;
  v_batch_balance integer;
  v_remaining integer;
  v_take integer;
  v_points_id uuid := gen_random_uuid();
  v_expiry timestamptz;
  v_batch record;
  lp public.loyalty_programs%rowtype;
  v_points_programme uuid;
begin
  if coalesce(p_points, 0) = 0 then
    raise exception 'points adjustment must be non-zero';
  end if;
  if p_reason is null or length(btrim(p_reason)) < 3 then
    raise exception 'points adjustment reason must be at least 3 characters';
  end if;

  select s.id into v_staff
    from public.staff s
   where s.business_id = p_business
     and s.user_id = v_actor
     and s.active
     and s.role = 'owner'
   order by s.created_at
   limit 1
   for update;
  if not found then
    raise exception 'only an active owner may adjust points'
      using errcode = '42501';
  end if;

  perform app.require_workspace_open_v173(p_business);

  perform 1 from public.clients c
   where c.id = p_client and c.business_id = p_business
   for update;
  if not found then
    raise exception 'client does not belong to this business';
  end if;

  -- v311 W5a: an owner points adjustment is a POINTS-programme fact. Fail closed.
  select spine.id into v_points_programme
    from public.business_programmes spine
   where spine.business_id = p_business and spine.kind = 'points';
  if v_points_programme is null then
    raise exception 'this business has no points programme to adjust'
      using errcode = 'check_violation';
  end if;

  select coalesce(sum(pl.points), 0)::integer into v_balance
    from public.points_ledger pl
   where pl.business_id = p_business and pl.client_id = p_client
     and pl.programme_id = v_points_programme;
  if p_points < 0 and v_balance + p_points < 0 then
    raise exception 'points adjustment would overdraw balance % by %', v_balance, -p_points;
  end if;

  if p_points < 0 then
    select coalesce(sum(pb.remaining), 0)::integer into v_batch_balance
      from public.points_batches pb
     where pb.business_id = p_business
       and pb.client_id = p_client
       and pb.programme_id = v_points_programme
       and pb.remaining > 0;
    if v_batch_balance < -p_points then
      raise exception 'points batches % cannot prove negative adjustment %',
        v_batch_balance, -p_points
        using errcode = 'check_violation';
    end if;

    v_remaining := -p_points;
    for v_batch in
      select pb.id, pb.remaining
        from public.points_batches pb
       where pb.business_id = p_business
         and pb.client_id = p_client
         and pb.programme_id = v_points_programme
         and pb.remaining > 0
       order by pb.expires_at nulls last, pb.earned_at, pb.id
       for update
    loop
      exit when v_remaining = 0;
      v_take := least(v_batch.remaining, v_remaining);
      update public.points_batches
         set remaining = remaining - v_take
       where id = v_batch.id;
      v_remaining := v_remaining - v_take;
    end loop;
  else
    select * into lp
      from public.loyalty_programs
     where business_id = p_business
       and active
       and kind = 'points'
     limit 1;
    v_expiry := case
      when found and lp.expiry_mode = 'fixed' and coalesce(lp.expiry_days, 0) > 0
        then now() + make_interval(days => lp.expiry_days)
      else null
    end;
    insert into public.points_batches (
      business_id, client_id, earned, remaining, earned_at, expires_at, programme_id
    ) values (
      p_business, p_client, p_points, p_points, now(), v_expiry, v_points_programme
    );
  end if;

  perform set_config('app.points_ledger_insert_id', v_points_id::text, true);
  perform set_config('app.points_ledger_write_scope', 'adjust_points', true);
  insert into public.points_ledger (
    id, business_id, client_id, entry_type, points, reference, actor, programme_id
  ) values (
    v_points_id, p_business, p_client, 'adjust', p_points, btrim(p_reason), v_actor,
    v_points_programme
  );
  perform set_config('app.points_ledger_insert_id', '', true);
  perform set_config('app.points_ledger_write_scope', '', true);

  return v_balance + p_points;
end $function$;

revoke all on function public.adjust_points(uuid,uuid,integer,text) from public,anon;
grant execute on function public.adjust_points(uuid,uuid,integer,text)
  to authenticated,service_role;

comment on function public.adjust_points(uuid,uuid,integer,text) is
  'v20/v173 owner points adjustment, v311 W5a programme-scoped. Balance, overdraw check, '
  'batch proof and FEFO drain are all restricted to the POINTS programme, and both the '
  'new batch and the ledger row are tagged with it — without this an owner granting 100 '
  'points would drain a customer''s STAMP batches to pay for a negative adjustment. The '
  'returned balance is now the points programme''s, identical to the business pot for '
  'every firm running one accruing programme.';

-- 5.4 app.redeem_reward_core — catalogue redemption. THE PROVEN CROSS-PROGRAMME
--     DOUBLE-SPEND: today a customer with 500 points and 0 stamps can redeem a stamp gift,
--     draining points batches to pay for it (v34:570-572, :583).
--
--     SPLICED, never re-stated: the live body is v34:508-605 PLUS the v176b tier-gate
--     patch, a combination no repo file reproduces. Re-stating from v34 would silently
--     revert the reward tier gate. Four comment-free needles, each count-asserted.
--
--     The asymmetry is deliberate: the reward's programme scopes the BATCH proof and the
--     FEFO drain, while the ledger balance check (v34:570) stays business-scoped. The two
--     are a conjunction, so filtering the batch side strictly tightens, and the unfiltered
--     ledger sum remains a valid SOLVENCY check throughout W5b's pot-migration window.
--     loyalty_rewards/loyalty_reward_versions have no programme_id (W6 adds it,
--     plan:112-116), so the programme is derived exactly as app.resolve_ledger_programme_v309
--     does — from the business's model.

do $v311_core$
declare
  v_def text;
  v_old text;
  v_new text;
  v_old_count integer;
  v_new_count integer;
  v_pairs text[][];
  i integer;
begin
  select pg_get_functiondef('app.redeem_reward_core(uuid,uuid,uuid,text,uuid,uuid,uuid)'::regprocedure)
    into strict v_def;
  if position('v_reward_programme' in v_def) > 0 then
    raise notice 'v311: app.redeem_reward_core already programme-scoped';
    return;
  end if;
  if position('v176_tier_gate_metric' in v_def) = 0 then
    raise exception 'v311: app.redeem_reward_core has lost its v176b tier gate; refusing to patch blind';
  end if;

  v_pairs := array[
    array[
      $needle$  v_usage integer; v_eligibility jsonb; v_result json;$needle$,
      $needle$  v_usage integer; v_eligibility jsonb; v_result json; v_reward_programme uuid;$needle$
    ],
    array[
      $needle$  select coalesce(sum(remaining),0)::integer into v_batch_balance from public.points_batches where business_id=p_business and client_id=p_client;$needle$,
      $needle$  v_reward_programme:=app.resolve_ledger_programme_v309(p_business);
  if v_reward_programme is null then raise exception 'reward programme is not resolvable for this business' using errcode='XX001'; end if;
  select coalesce(sum(remaining),0)::integer into v_batch_balance from public.points_batches where business_id=p_business and client_id=p_client and programme_id=v_reward_programme;$needle$
    ],
    array[
      $needle$  for v_batch in select id,remaining from public.points_batches where business_id=p_business and client_id=p_client and remaining>0 order by expires_at nulls last,earned_at,id for update loop$needle$,
      $needle$  for v_batch in select id,remaining from public.points_batches where business_id=p_business and client_id=p_client and remaining>0 and programme_id=v_reward_programme order by expires_at nulls last,earned_at,id for update loop$needle$
    ],
    array[
      $needle$  insert into public.points_ledger(id,business_id,client_id,entry_type,points,reference,actor) values(v_points_id,p_business,p_client,'redeem',-v_version.cost_points,'reward: '||v_version.customer_name,v_actor);$needle$,
      $needle$  insert into public.points_ledger(id,business_id,client_id,entry_type,points,reference,actor,programme_id) values(v_points_id,p_business,p_client,'redeem',-v_version.cost_points,'reward: '||v_version.customer_name,v_actor,v_reward_programme);$needle$
    ]
  ];

  for i in 1 .. array_length(v_pairs, 1) loop
    v_old := v_pairs[i][1];
    v_new := v_pairs[i][2];
    v_old_count := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
    v_new_count := (length(v_def) - length(replace(v_def, v_new, ''))) / length(v_new);
    if v_old_count <> 1 or v_new_count <> 0 then
      raise exception 'v311: redeem_reward_core needle % did not match exactly once (old=%, new=%)',
        i, v_old_count, v_new_count;
    end if;
    v_def := replace(v_def, v_old, v_new);
  end loop;

  execute v_def;

  select pg_get_functiondef('app.redeem_reward_core(uuid,uuid,uuid,text,uuid,uuid,uuid)'::regprocedure)
    into strict v_def;
  if position('v176_tier_gate_metric' in v_def) = 0
     or position('programme_id=v_reward_programme' in v_def) = 0
     or position($needle$actor,programme_id) values(v_points_id,p_business,p_client,'redeem'$needle$ in v_def) = 0 then
    raise exception 'v311: redeem_reward_core scoping did not land';
  end if;
end
$v311_core$;

revoke execute on function app.redeem_reward_core(uuid,uuid,uuid,text,uuid,uuid,uuid)
  from public, anon, authenticated;

-- 5.5 app.redeem_points_v40_internal — classic redemption. Reachable today through
--     public.redeem_points(uuid,uuid,text) (v41:1050-1067) and, in a browser session,
--     through public.merchant_scan_redemption_qr_v117 (v117:499). The function refuses
--     anything but loyalty_model='classic', so its programme is the points spine row.

do $v311_redeem3$
declare
  v_def text; v_old text; v_new text; v_o integer; v_n integer;
  v_pairs text[][]; i integer;
begin
  select pg_get_functiondef('app.redeem_points_v40_internal(uuid,uuid,text)'::regprocedure)
    into strict v_def;
  if position('v_points_programme' in v_def) > 0 then
    raise notice 'v311: app.redeem_points_v40_internal already programme-scoped';
    return;
  end if;

  v_pairs := array[
    array[
      $needle$  v_operation public.loyalty_operations%rowtype;
  v_rows integer;
  v_result json;$needle$,
      $needle$  v_operation public.loyalty_operations%rowtype;
  v_rows integer;
  v_result json;
  v_points_programme uuid;$needle$
    ],
    array[
      $needle$  select coalesce(sum(pb.remaining), 0)::integer into v_batch_balance
    from public.points_batches pb
   where pb.business_id = p_business and pb.client_id = p_client and pb.remaining > 0;$needle$,
      $needle$  v_points_programme := app.resolve_ledger_programme_v309(p_business);
  if v_points_programme is null then
    raise exception 'redemption programme is not resolvable for this business'
      using errcode = 'XX001';
  end if;
  select coalesce(sum(pb.remaining), 0)::integer into v_batch_balance
    from public.points_batches pb
   where pb.business_id = p_business and pb.client_id = p_client and pb.remaining > 0
     and pb.programme_id = v_points_programme;$needle$
    ],
    array[
      $needle$    select pb.id, pb.remaining from public.points_batches pb
     where pb.business_id = p_business and pb.client_id = p_client and pb.remaining > 0
     order by pb.expires_at nulls last, pb.earned_at, pb.id for update$needle$,
      $needle$    select pb.id, pb.remaining from public.points_batches pb
     where pb.business_id = p_business and pb.client_id = p_client and pb.remaining > 0
       and pb.programme_id = v_points_programme
     order by pb.expires_at nulls last, pb.earned_at, pb.id for update$needle$
    ],
    array[
      $needle$  insert into public.points_ledger
    (id, business_id, client_id, entry_type, points, reference, actor)
  values
    (v_points_id, p_business, p_client, 'redeem', -lp.redeem_points,
     'redeemed to credit', v_actor);$needle$,
      $needle$  insert into public.points_ledger
    (id, business_id, client_id, entry_type, points, reference, actor, programme_id)
  values
    (v_points_id, p_business, p_client, 'redeem', -lp.redeem_points,
     'redeemed to credit', v_actor, v_points_programme);$needle$
    ]
  ];

  for i in 1 .. array_length(v_pairs, 1) loop
    v_old := v_pairs[i][1]; v_new := v_pairs[i][2];
    v_o := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
    v_n := (length(v_def) - length(replace(v_def, v_new, ''))) / length(v_new);
    if v_o <> 1 or v_n <> 0 then
      raise exception 'v311: redeem_points_v40_internal needle % (old=%, new=%)', i, v_o, v_n;
    end if;
    v_def := replace(v_def, v_old, v_new);
  end loop;
  execute v_def;
end
$v311_redeem3$;

revoke all privileges on function app.redeem_points_v40_internal(uuid,uuid,text)
  from public, anon, authenticated;

-- 5.6 public.redeem_points(uuid,uuid) — the legacy two-argument overload. THE WRITER
--     NOBODY LISTED: not browser-reachable (ACL {postgres=X, service_role=X}), fully live,
--     and it writes money. Scoped rather than dropped — dropping a money function needs
--     its own evidence.

do $v311_redeem2$
declare
  v_def text; v_old text; v_new text; v_o integer; v_n integer;
  v_pairs text[][]; i integer;
begin
  select pg_get_functiondef('public.redeem_points(uuid,uuid)'::regprocedure) into strict v_def;
  if position('v_points_programme' in v_def) > 0 then
    raise notice 'v311: public.redeem_points(uuid,uuid) already programme-scoped';
    return;
  end if;

  v_pairs := array[
    array[
      $needle$  v_points_id uuid := gen_random_uuid();
  v_credit_id uuid := gen_random_uuid();
begin$needle$,
      $needle$  v_points_id uuid := gen_random_uuid();
  v_credit_id uuid := gen_random_uuid();
  v_points_programme uuid;
begin$needle$
    ],
    array[
      $needle$  select coalesce(sum(pb.remaining), 0)::integer into v_batch_balance
    from public.points_batches pb
   where pb.business_id = p_business
     and pb.client_id = p_client
     and pb.remaining > 0;$needle$,
      $needle$  v_points_programme := app.resolve_ledger_programme_v309(p_business);
  if v_points_programme is null then
    raise exception 'redemption programme is not resolvable for this business'
      using errcode = 'XX001';
  end if;
  select coalesce(sum(pb.remaining), 0)::integer into v_batch_balance
    from public.points_batches pb
   where pb.business_id = p_business
     and pb.client_id = p_client
     and pb.programme_id = v_points_programme
     and pb.remaining > 0;$needle$
    ],
    array[
      $needle$    select pb.id, pb.remaining
      from public.points_batches pb
     where pb.business_id = p_business
       and pb.client_id = p_client
       and pb.remaining > 0
     order by pb.expires_at nulls last, pb.earned_at, pb.id
     for update$needle$,
      $needle$    select pb.id, pb.remaining
      from public.points_batches pb
     where pb.business_id = p_business
       and pb.client_id = p_client
       and pb.programme_id = v_points_programme
       and pb.remaining > 0
     order by pb.expires_at nulls last, pb.earned_at, pb.id
     for update$needle$
    ],
    array[
      $needle$  insert into public.points_ledger
    (id, business_id, client_id, entry_type, points, reference, actor)
  values
    (v_points_id, p_business, p_client, 'redeem', -lp.redeem_points,
     'redeemed to credit', v_actor);$needle$,
      $needle$  insert into public.points_ledger
    (id, business_id, client_id, entry_type, points, reference, actor, programme_id)
  values
    (v_points_id, p_business, p_client, 'redeem', -lp.redeem_points,
     'redeemed to credit', v_actor, v_points_programme);$needle$
    ]
  ];

  for i in 1 .. array_length(v_pairs, 1) loop
    v_old := v_pairs[i][1]; v_new := v_pairs[i][2];
    v_o := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
    v_n := (length(v_def) - length(replace(v_def, v_new, ''))) / length(v_new);
    if v_o <> 1 or v_n <> 0 then
      raise exception 'v311: redeem_points(uuid,uuid) needle % (old=%, new=%)', i, v_o, v_n;
    end if;
    v_def := replace(v_def, v_old, v_new);
  end loop;
  execute v_def;
end
$v311_redeem2$;

revoke all privileges on function public.redeem_points(uuid,uuid) from public, anon, authenticated;

-- 5.7 public.reverse_loyalty_redemption_v34_base — redemption reversal.
--     Already programme-CORRECT on the batch side by construction: it restores `remaining`
--     into the exact drained batch ids (v34:649-656). What was missing is the tag on its
--     compensation row — batches restored into programme A while the compensating ledger
--     row lands in programme B would manufacture a permanent split pot BY THE SAFETY
--     MECHANISM. The programme is derived from the drained batches and asserted
--     single-valued; the v34:685-688 parity assertion gains its per-programme form.
--
--     THE ASSERT IS COUNTED, NOT INFERRED. `select distinct x into v` is not STRICT: on two
--     distinct programmes plpgsql keeps the FIRST row and discards the rest silently, so a
--     `v is null` test only catches the empty case and the cross-programme case — the one
--     this block exists to refuse — would restore batches in two programmes while writing
--     ONE compensation row tagged with whichever programme sorted first. That is reachable
--     the moment a pot migration has run: the drains of a single redemption can span a
--     fully-drained batch that kept the OLD tag (v312 retags OPEN batches only, by design)
--     and a retagged open batch. So the count is taken first and only 1 proceeds; the
--     subsequent SELECT ... INTO STRICT is the second lock on the same door.

do $v311_reverse$
declare
  v_def text; v_old text; v_new text; v_o integer; v_n integer;
  v_pairs text[][]; i integer;
begin
  select pg_get_functiondef('public.reverse_loyalty_redemption_v34_base(uuid,uuid,text,text)'::regprocedure)
    into strict v_def;
  if position('v_restore_programme' in v_def) > 0 then
    raise notice 'v311: reverse_loyalty_redemption_v34_base already programme-scoped';
    return;
  end if;

  v_pairs := array[
    array[
      $needle$  v_source_credit public.credit_ledger%rowtype; v_result jsonb; v_drain record;$needle$,
      $needle$  v_source_credit public.credit_ledger%rowtype; v_result jsonb; v_drain record;
  v_restore_programme uuid; v_restore_programmes integer;$needle$
    ],
    array[
      $needle$  insert into public.points_ledger(id,business_id,client_id,entry_type,points,reference,actor,config_version_id)
  values(v_points_id,p_business,v_redemption.client_id,'adjust',v_redemption.points_spent,'redemption reversal: '||p_redemption,v_actor,v_redemption.config_version_id);$needle$,
      $needle$  select count(distinct pb.programme_id) into v_restore_programmes
    from public.points_batches pb
   where pb.id in (select d.points_batch_id from public.loyalty_redemption_batch_drains d
                    where d.provenance_id=v_provenance.id);
  if v_restore_programmes<>1 then raise exception 'restored batches span more than one programme or none' using errcode='XX001'; end if;
  select distinct pb.programme_id into strict v_restore_programme
    from public.points_batches pb
   where pb.id in (select d.points_batch_id from public.loyalty_redemption_batch_drains d
                    where d.provenance_id=v_provenance.id);
  insert into public.points_ledger(id,business_id,client_id,entry_type,points,reference,actor,config_version_id,programme_id)
  values(v_points_id,p_business,v_redemption.client_id,'adjust',v_redemption.points_spent,'redemption reversal: '||p_redemption,v_actor,v_redemption.config_version_id,v_restore_programme);$needle$
    ],
    array[
      $needle$  if (select coalesce(sum(points),0) from public.points_ledger where business_id=p_business and client_id=v_redemption.client_id)
     <> (select coalesce(sum(remaining),0) from public.points_batches where business_id=p_business and client_id=v_redemption.client_id) then
    raise exception 'points ledger and points batch remaining invariant diverged';
  end if;$needle$,
      $needle$  if (select coalesce(sum(points),0) from public.points_ledger where business_id=p_business and client_id=v_redemption.client_id)
     <> (select coalesce(sum(remaining),0) from public.points_batches where business_id=p_business and client_id=v_redemption.client_id) then
    raise exception 'points ledger and points batch remaining invariant diverged';
  end if;
  if (select coalesce(sum(points),0) from public.points_ledger where business_id=p_business and client_id=v_redemption.client_id and programme_id=v_restore_programme)
     <> (select coalesce(sum(remaining),0) from public.points_batches where business_id=p_business and client_id=v_redemption.client_id and programme_id=v_restore_programme) then
    raise exception 'per-programme points ledger and batch remaining invariant diverged';
  end if;$needle$
    ]
  ];

  for i in 1 .. array_length(v_pairs, 1) loop
    v_old := v_pairs[i][1]; v_new := v_pairs[i][2];
    v_o := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
    v_n := (length(v_def) - length(replace(v_def, v_new, ''))) / length(v_new);
    if v_o <> 1 or v_n <> 0 then
      raise exception 'v311: reverse_loyalty_redemption_v34_base needle % (old=%, new=%)', i, v_o, v_n;
    end if;
    v_def := replace(v_def, v_old, v_new);
  end loop;
  execute v_def;
end
$v311_reverse$;

revoke all privileges on function public.reverse_loyalty_redemption_v34_base(uuid,uuid,text,text)
  from public, anon, authenticated;

-- 5.8 public.correct_quick_sale_amount_v84 — fast correction.
--     Its single-earn-row assumption (v84:408-413 "assumes ONE earn row per sale") dies the
--     moment the loop can write two. The compensation becomes a LOOP over the sale's earn
--     rows grouped by programme, one tagged compensation row each, each programme's batches
--     zeroed on its own pass. The single-valued result and audit columns get additive
--     per-programme companions (W4 rules R1-R3): points_removed stays the TOTAL and stays
--     byte-stable for existing clients.
--
--     The wholly-unspent test (v84:432-436) needs NO change and that is worth stating
--     ACCURATELY, because the reason is an invariant and not a constraint. It compares
--     sum(earned) with sum(remaining) over the SAME batch set. There is no
--     `remaining <= earned` CHECK on public.points_batches — the declared checks are
--     `earned > 0` and `remaining >= 0` (v2) — so the argument rests on the writers:
--     every path that moves `remaining` only ever LOWERS it (FEFO drain v20:932-934 and
--     v34:585, the expiry sweep v20:1044, v84:545-550), and the one path that raises it,
--     the reversal restore, is bounded row-by-row by `remaining+drained<=earned`
--     (v34:652-654). remaining <= earned therefore holds per row at all times, so
--     sum(earned)=sum(remaining) over a set forces per-row equality, which forces
--     per-programme equality. It is already the per-programme test — by construction of
--     the writers, which is why v311 changes none of them in that direction.
--
--     THE REPLAY BRANCH DOES change (v84:317-346). Its evidence check asserted a SINGLE
--     compensation row carrying `points = -points_removed`. points_removed is now the
--     cross-programme TOTAL while each row carries only its own programme's share, so on
--     a two-programme correction a routine retry with the same idempotency key would find
--     no such row and raise XX001 — turning an idempotent replay into a hard failure on
--     exactly the shape this wave introduces. The check now reads the ADDITIVE truth: the
--     SET named by points_compensation_ledger_ids must sum to -points_removed and agree
--     with points_removed_by_programme row for row. A correction written before v311 has
--     both columns NULL and keeps the legacy single-row test, so old audit rows replay
--     exactly as they always did.

alter table public.sale_amount_corrections_v84
  add column if not exists points_compensation_ledger_ids uuid[],
  add column if not exists points_removed_by_programme jsonb;

comment on column public.sale_amount_corrections_v84.points_compensation_ledger_ids is
  'v311 W5a: every compensation ledger row this correction wrote, one per programme that '
  'earned on the sale. points_compensation_ledger_id keeps the first, byte-stable for a '
  'single-programme sale.';
comment on column public.sale_amount_corrections_v84.points_removed_by_programme is
  'v311 W5a: {programme_id: points_removed}. points_removed keeps the total.';

do $v311_v84$
declare
  v_def text; v_old text; v_new text; v_o integer; v_n integer;
  v_pairs text[][]; i integer;
begin
  select pg_get_functiondef('public.correct_quick_sale_amount_v84(uuid,uuid,integer,text,text)'::regprocedure)
    into strict v_def;
  if position('v_points_removed_by_programme' in v_def) > 0 then
    raise notice 'v311: correct_quick_sale_amount_v84 already programme-scoped';
    return;
  end if;

  v_pairs := array[
    array[
      $needle$  v_points_compensation_id uuid;$needle$,
      $needle$  v_points_compensation_id uuid;
  v_earn_programme record;
  v_points_compensation_ids uuid[] := array[]::uuid[];
  v_points_removed_by_programme jsonb := '{}'::jsonb;$needle$
    ],
    -- THE IDEMPOTENT REPLAY'S EVIDENCE CHECK. Additive, per programme, fail-closed.
    -- coalesce(...,false) wraps the whole decision because every arm can go NULL (an empty
    -- uuid[] makes array_length NULL, a missing map key makes the cast NULL) and a NULL
    -- here would sail through `if ... then raise` as if the evidence were present.
    array[
      $needle$         v_existing.points_compensation_ledger_id is null
         or not exists (
           select 1
             from public.points_ledger compensation
            where compensation.id=v_existing.points_compensation_ledger_id
              and compensation.business_id=v_existing.business_id
              and compensation.client_id=(
                select original.client_id
                  from public.sales original
                 where original.id=v_existing.original_sale_id
                   and original.business_id=v_existing.business_id
              )
              and compensation.sale_id=v_existing.reversal_sale_id
              and compensation.entry_type='adjust'
              and compensation.points=-v_existing.points_removed
         )$needle$,
      $needle$         v_existing.points_compensation_ledger_id is null
         or not coalesce(case
              when v_existing.points_compensation_ledger_ids is null
               and v_existing.points_removed_by_programme is null
              then exists (
                select 1
                  from public.points_ledger compensation
                 where compensation.id=v_existing.points_compensation_ledger_id
                   and compensation.business_id=v_existing.business_id
                   and compensation.client_id=(
                     select original.client_id
                       from public.sales original
                      where original.id=v_existing.original_sale_id
                        and original.business_id=v_existing.business_id
                   )
                   and compensation.sale_id=v_existing.reversal_sale_id
                   and compensation.entry_type='adjust'
                   and compensation.points=-v_existing.points_removed
              )
              else (
                select jsonb_typeof(v_existing.points_removed_by_programme)='object'
                   and coalesce(array_length(v_existing.points_compensation_ledger_ids,1),0)>0
                   and count(*)=coalesce(array_length(v_existing.points_compensation_ledger_ids,1),0)
                   and coalesce(sum(compensation.points),0)=-v_existing.points_removed
                   and count(*) filter (
                         where (v_existing.points_removed_by_programme
                                  ->>compensation.programme_id::text)::integer
                               is distinct from -compensation.points)=0
                   and count(distinct compensation.programme_id)=(
                         select count(*)
                           from jsonb_object_keys(v_existing.points_removed_by_programme))
                  from public.points_ledger compensation
                 where compensation.id=any(v_existing.points_compensation_ledger_ids)
                   and compensation.business_id=v_existing.business_id
                   and compensation.client_id=(
                     select original.client_id
                       from public.sales original
                      where original.id=v_existing.original_sale_id
                        and original.business_id=v_existing.business_id
                   )
                   and compensation.sale_id=v_existing.reversal_sale_id
                   and compensation.entry_type='adjust'
              )
            end,false)$needle$
    ],
    array[
      $needle$    insert into public.points_ledger(
      id,business_id,client_id,entry_type,points,sale_id,reference,actor
    ) values (
      v_points_compensation_id,p_business,v_original.client_id,'adjust',
      -v_original_points,v_reversal_sale,
      'sale amount correction: remove original earn for sale '||v_original.id,
      v_actor
    );
    perform set_config('app.points_ledger_insert_id','',true);
    perform set_config('app.points_ledger_write_scope','',true);

    update public.points_batches batch
       set remaining=0
     where batch.business_id=p_business
       and batch.client_id=v_original.client_id
       and batch.sale_id=v_original.id
       and batch.remaining=batch.earned;$needle$,
      $needle$    null;
    for v_earn_programme in
      select ledger.programme_id as programme_id,
             coalesce(sum(ledger.points),0)::integer as points
        from public.points_ledger ledger
       where ledger.business_id=p_business
         and ledger.sale_id=v_original.id
         and ledger.entry_type='earn'
       group by ledger.programme_id
       order by ledger.programme_id
    loop
      if v_earn_programme.points<=0 then continue; end if;
      v_points_compensation_id:=gen_random_uuid();
      perform set_config(
        'app.points_ledger_insert_id',v_points_compensation_id::text,true
      );
      perform set_config(
        'app.points_ledger_write_scope','sale_amount_correction_v84',true
      );
      insert into public.points_ledger(
        id,business_id,client_id,entry_type,points,sale_id,reference,actor,programme_id
      ) values (
        v_points_compensation_id,p_business,v_original.client_id,'adjust',
        -v_earn_programme.points,v_reversal_sale,
        'sale amount correction: remove original earn for sale '||v_original.id,
        v_actor,v_earn_programme.programme_id
      );
      perform set_config('app.points_ledger_insert_id','',true);
      perform set_config('app.points_ledger_write_scope','',true);

      update public.points_batches batch
         set remaining=0
       where batch.business_id=p_business
         and batch.client_id=v_original.client_id
         and batch.sale_id=v_original.id
         and batch.programme_id=v_earn_programme.programme_id
         and batch.remaining=batch.earned;

      v_points_compensation_ids:=v_points_compensation_ids||v_points_compensation_id;
      v_points_removed_by_programme:=v_points_removed_by_programme
        ||jsonb_build_object(v_earn_programme.programme_id::text,v_earn_programme.points);
    end loop;
    v_points_compensation_id:=v_points_compensation_ids[1];$needle$
    ],
    array[
      $needle$      raise exception 'points ledger and batch cache diverged during sale correction'
        using errcode='XX001';
    end if;
  end if;$needle$,
      $needle$      raise exception 'points ledger and batch cache diverged during sale correction'
        using errcode='XX001';
    end if;
    if exists (
      select 1
        from (select ledger.programme_id,sum(ledger.points) as total
                from public.points_ledger ledger
               where ledger.business_id=p_business
                 and ledger.client_id=v_original.client_id
               group by ledger.programme_id) led
        full join (select batch.programme_id,sum(batch.remaining) as total
                     from public.points_batches batch
                    where batch.business_id=p_business
                      and batch.client_id=v_original.client_id
                    group by batch.programme_id) bat
          on bat.programme_id=led.programme_id
       where coalesce(led.total,0)<>coalesce(bat.total,0)
    ) then
      raise exception 'per-programme points ledger and batch cache diverged during sale correction'
        using errcode='XX001';
    end if;
  end if;$needle$
    ],
    array[
      $needle$    'points_compensation_ledger_id',v_points_compensation_id,
    'points_earned',v_points_earned,$needle$,
      $needle$    'points_compensation_ledger_id',v_points_compensation_id,
    'points_compensation_ledger_ids',to_jsonb(v_points_compensation_ids),
    'points_removed_by_programme',v_points_removed_by_programme,
    'points_earned',v_points_earned,$needle$
    ],
    array[
      $needle$    points_compensation_ledger_id,note,idempotency_key,request_payload,request_hash,result
  ) values ($needle$,
      $needle$    points_compensation_ledger_id,points_compensation_ledger_ids,
    points_removed_by_programme,note,idempotency_key,request_payload,request_hash,result
  ) values ($needle$
    ],
    array[
      $needle$    v_points_compensation_id,v_note,v_key,v_payload,v_hash,v_result$needle$,
      $needle$    v_points_compensation_id,v_points_compensation_ids,
    v_points_removed_by_programme,v_note,v_key,v_payload,v_hash,v_result$needle$
    ]
  ];

  for i in 1 .. array_length(v_pairs, 1) loop
    v_old := v_pairs[i][1]; v_new := v_pairs[i][2];
    v_o := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
    v_n := (length(v_def) - length(replace(v_def, v_new, ''))) / length(v_new);
    if v_o <> 1 or v_n <> 0 then
      raise exception 'v311: correct_quick_sale_amount_v84 needle % (old=%, new=%)', i, v_o, v_n;
    end if;
    v_def := replace(v_def, v_old, v_new);
  end loop;
  execute v_def;
end
$v311_v84$;

revoke all privileges on function public.correct_quick_sale_amount_v84(uuid,uuid,integer,text,text)
  from public, anon;

-- 5.9 public.customer_create_redemption_intent_v89 — affordability, no money.
--     W4a left it alone deliberately ("spend dispatch is W5"). Scoped now, or the customer
--     is offered an intent the counter will refuse. Same asymmetry as 5.4: the ledger sum
--     stays business-scoped, the BATCH sum gets the reward's programme.

do $v311_intent$
declare
  v_def text; v_old text; v_new text; v_o integer; v_n integer;
begin
  select pg_get_functiondef('public.customer_create_redemption_intent_v89(uuid,uuid,uuid,text)'::regprocedure)
    into strict v_def;
  if position('v_intent_programme' in v_def) > 0 then
    raise notice 'v311: customer_create_redemption_intent_v89 already programme-scoped';
    return;
  end if;

  v_old := $needle$  select coalesce(sum(remaining),0)::integer into v_batch_balance
    from public.points_batches
    where business_id=p_business and client_id=v_client and remaining>0;$needle$;
  v_new := $needle$  select coalesce(sum(remaining),0)::integer into v_batch_balance
    from public.points_batches
    where business_id=p_business and client_id=v_client and remaining>0
      and programme_id=app.resolve_ledger_programme_v309(p_business);$needle$;
  v_o := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if v_o <> 1 then
    raise exception 'v311: customer_create_redemption_intent_v89 batch-balance needle matched % times', v_o;
  end if;
  v_def := replace(v_def, v_old, v_new);

  v_old := $needle$  v_expires timestamptz:=now()+interval '5 minutes';v_response jsonb;$needle$;
  v_new := $needle$  v_expires timestamptz:=now()+interval '5 minutes';v_response jsonb;
  v_intent_programme uuid;$needle$;
  v_o := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if v_o <> 1 then
    raise exception 'v311: customer_create_redemption_intent_v89 declare needle matched % times', v_o;
  end if;
  v_def := replace(v_def, v_old, v_new);

  execute v_def;
end
$v311_intent$;

-- ---------------------------------------------------------------------------
-- 6. POST-ASSERTIONS. The v121 postcondition battery re-run verbatim, plus the swap's
--    post-state, plus both standing detectors empty, plus the ACL floor.
-- ---------------------------------------------------------------------------

do $v311_postcondition$
declare
  v_def text;
  v_detected integer;
  v_acl record;
begin
  -- v121:71-89, verbatim: the effective-loyalty boundary survived the re-state.
  select pg_get_functiondef('app.on_sale_recorded()'::regprocedure) into strict v_def;
  if position('app.effective_platform_module_mode_v94(' in v_def)=0
     or position('new.business_id,new.branch_id,''loyalty''' in v_def)=0
     or position('effective.mode=''rw''' in v_def)=0
     or position('insert into public.points_ledger' in v_def)=0
     or not exists(
       select 1
       from pg_trigger trigger_row
       where trigger_row.tgrelid='public.sales'::regclass
         and trigger_row.tgfoid='app.on_sale_recorded()'::regprocedure
         and not trigger_row.tgisinternal
     ) then
    raise exception 'v311: the v121 effective Loyalty sale-earn boundary is incomplete';
  end if;
  -- The loop's own non-negotiables.
  if position('on conflict (sale_id,programme_id) where entry_type=''earn'' and sale_id is not null do nothing' in v_def)=0
     or position('get diagnostics v_rows=row_count' in v_def)=0
     or position('earn loop left ledger/batch parity broken' in v_def)=0
     or position('from public.business_programmes spine' in v_def)=0 then
    raise exception 'v311: the earn loop did not land in its contracted shape';
  end if;
  -- The multiplier must sit INSIDE the points branch, i.e. after the kind test.
  if position('elsif v_prog.kind=''points''' in v_def) = 0
     or position('app.loyalty_tier_for' in v_def) < position('elsif v_prog.kind=''points''' in v_def) then
    raise exception 'v311: the tier multiplier is not scoped to the points branch';
  end if;

  -- The swap's post-state.
  if exists (select 1 from pg_class where relname='points_earn_once_per_sale' and relkind='i') then
    raise exception 'v311: the v2 points_earn_once_per_sale index survived the swap';
  end if;
  if not exists (
    select 1 from pg_index i join pg_class c on c.oid=i.indexrelid
     where c.relname='points_earn_once_per_sale_per_programme' and i.indisunique and i.indisvalid
  ) then
    raise exception 'v311: the per-programme index is not unique+valid after the swap';
  end if;
  if exists (
    select 1 from pg_trigger where tgrelid='public.business_programmes'::regclass
       and tgname='business_programmes_exclusive_accrual_v308'
  ) or to_regprocedure('app.business_programmes_exclusive_accrual_v308()') is not null then
    raise exception 'v311: the v308 tripwire survived';
  end if;
  if exists (
    select 1 from pg_attribute a
     where a.attrelid in ('public.points_ledger'::regclass,'public.points_batches'::regclass)
       and a.attname='programme_id' and not a.attnotnull
  ) then
    raise exception 'v311: programme_id is not NOT NULL on both money tables';
  end if;

  -- The BEFORE INSERT trigger order v309 fought for (V309 standing invariant 3) is intact,
  -- and the trigger inventory on points_ledger is unchanged.
  if (select string_agg(tgname, ',' order by tgname)
        from pg_trigger where tgrelid='public.points_ledger'::regclass and not tgisinternal)
     is distinct from
     'trg_audit_points,trg_points_ledger_append_only,trg_points_ledger_config_version,trg_points_ledger_programme_tag_v309,trg_points_ledger_write_guard'
  then
    raise exception 'v311: the points_ledger trigger inventory changed: %',
      (select string_agg(tgname, ',' order by tgname)
         from pg_trigger where tgrelid='public.points_ledger'::regclass and not tgisinternal);
  end if;

  -- Both standing detectors empty.
  select count(*) into strict v_detected from app.detect_double_earn_v309();
  if v_detected <> 0 then
    raise exception 'v311: the double-earn detector is not empty after the swap (% rows)', v_detected;
  end if;
  select count(*) into strict v_detected from app.detect_programme_pot_split_v310();
  if v_detected <> 0 then
    raise exception 'v311: the pot-split detector reports % businesses; W5b owns them', v_detected;
  end if;

  -- ACL floor on every function this wave touched (v37b:709, v121:61-62, v309:279-281).
  for v_acl in
    select signature from (values
      ('app.on_sale_recorded()'),
      ('app.loyalty_tier_for(uuid,uuid)'),
      ('app.loyalty_ledger_write_guard()'),
      ('app.run_points_expiry_for_business(uuid)'),
      ('app.run_points_expiry()'),
      ('app.redeem_reward_core(uuid,uuid,uuid,text,uuid,uuid,uuid)'),
      ('app.redeem_points_v40_internal(uuid,uuid,text)'),
      ('public.redeem_points(uuid,uuid)'),
      ('public.reverse_loyalty_redemption_v34_base(uuid,uuid,text,text)')
    ) touched(signature)
  loop
    if has_function_privilege('anon', v_acl.signature, 'execute')
       or has_function_privilege('authenticated', v_acl.signature, 'execute') then
      raise exception 'v311: % is still executable by a browser role', v_acl.signature;
    end if;
  end loop;
  if not has_function_privilege('authenticated', 'public.adjust_points(uuid,uuid,integer,text)', 'execute') then
    raise exception 'v311: public.adjust_points lost its authenticated grant';
  end if;
end
$v311_postcondition$;

commit;
