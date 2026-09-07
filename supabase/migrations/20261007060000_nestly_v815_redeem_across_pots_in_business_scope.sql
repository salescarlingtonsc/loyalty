/* nestly_v815 — under business_pot scope a customer may SPEND the whole business pot.

   Owner ruling (2026-09-07). nestly_v804 taught the STAFF points readers to ask
   app.programme_balance_scope_v312 what a per-programme number MEANS for a firm right now, and
   nestly_v813 taught the CUSTOMER wallet readers the same. v813 deliberately EXEMPTED
   app.reward_availability_v432 from its estate gate, with this reason:

     "app.reward_availability_v432    the spendable-at-the-counter pot. app.redeem_reward_core
      deducts from the batches of the REWARD'S OWN programme, so widening this reader to every
      pot would advertise gifts the counter then refuses -- the one thing v432 exists to prevent
      (see its own nestly_v568 comment). Making redemption itself pot-scope-aware is a real
      question and an owner decision; it is not a reader fix and it is not this migration."

   The owner has now decided it. Under 'business_pot' the whole business pot is spendable, so the
   READER and the WRITER move together: availability judges affordability against the pot the
   scope defines, and redemption drains batches across every programme's batches for that
   business, oldest expiry first, then oldest earned. Under 'programme_pot' nothing changes.

   ============================================================================================
   PROVED ON PRODUCTION, read-only, inside a transaction that was rolled back (2026-09-07)
   ============================================================================================
   A scratch firm with a live points pot of 30 and a retired pot of 70, a 50-point gift on the
   live points programme, and the ONE row that puts production into business_pot scope -- a
   pending public.programme_pot_migrations row:

     BEFORE  programme_pot  scope=programme_pot wallet=30  availability(cost 50)=insufficient_balance
     AFTER   business_pot   scope=business_pot  wallet=100 availability(cost 50)=insufficient_balance
                                                            remaining_units=20

   The AFTER line is the defect this migration closes. app.c45_base_actionable_wallet_card, which
   v813 made scope-aware, tells the customer they hold 100 spendable points; the availability core
   still sums only the live pot's 30, refuses a gift costing 50, and tells them they need 20 MORE
   points while holding 100. The wallet and the counter disagree about the same customer's own
   spendable balance, in the direction that reads as "the shop is refusing points I can see".

   ============================================================================================
   WHAT THIS MIGRATION CHANGES -- three functions, eleven splices, one predicate
   ============================================================================================
   Every splice adds the SAME rule: "business_pot means every pot; programme_pot means this one."
   Nothing else moves. The v480 value-integrity fence, the advisory lock
   (app.acquire_loyalty_shared_v480), the idempotency key + loyalty_operations replay contract,
   the provenance row, the per-batch drain rows and both conservation fences are untouched, as
   are the append-only ledgers' write scopes (the app.points_ledger_write_scope /
   app.credit_ledger_write_scope GUCs and app.loyalty_ledger_write_guard's route list).

   app.reward_availability_v432   splices 1-3. A new `pot_scope` CTE, `materialized` so the
       tenant-wide scope aggregate runs ONCE and not per catalogue row (the v370 finding: slow
       RPCs were re-evaluated functions, not missing indexes). Its `pot` CTE reports
       least(ledger sum, unexpired batch remaining) and BOTH halves carry the rule -- fixing one
       alone would leave the other clamping the answer straight back to the live pot, which looks
       exactly like no fix at all.
       NOT changed: which rewards are OFFERED. The `rows.programme_active` filter and the v568
       survivor-arm predicate stay exactly as they are, so a gift on a retired programme is still
       not advertised. Only AFFORDABILITY widens. That keeps v432's own contract intact: it never
       lists a gift app.redeem_reward_core would refuse -- redeem_reward_core still raises
       'catalog redemption is inactive' for a non-stamps reward whose spine is switched off.

   app.redeem_reward_core        splices 4-8. `v_all_pots` is resolved ONCE, on the points path
       only, from app.programme_balance_scope_v312, and then gates three sites that today read
       `programme_id=v_reward_programme`: the pre-flight `v_batch_balance`, the FEFO drain loop
       (`order by expires_at nulls last, earned_at, id for update` -- unchanged, so a wider set is
       still walked oldest-expiry-first), and the post-drain "batch delta does not reconcile"
       fence, which must recompute over the same set it measured or it would fail on every
       cross-pot redemption. The drain loop still writes one
       public.loyalty_redemption_batch_drains row per batch it touches, carrying the same
       provenance_id -- the evidence shape is identical, there are simply more rows when the spend
       crosses a pot. The ledger check `v_balance` was ALREADY business-wide (no programme filter)
       and is left alone.

   public.reverse_loyalty_redemption_v34_base   splices 9-11, and this is the splice that makes
       the ruling safe rather than merely possible. The restore loop already keys on the DRAIN
       ROWS -- `for v_drain in select d.points_batch_id, d.drained_points ... where
       d.provenance_id=v_provenance.id order by d.id` -- so it reconstructs whatever it finds and
       needed no change. Two things around it were programme-bound and would have made a
       cross-pot redemption PERMANENTLY IRREVERSIBLE:

         (a) `if v_restore_programmes<>1 then raise exception 'restored batches span more than one
             programme or none'`. A cross-pot redemption drains two programmes by construction,
             so this guard would refuse every reversal of one. Its "or none" half is already dead
             -- an empty drain set is rejected four lines earlier by 'incomplete batch drain
             provenance evidence' -- so the guard is narrowed to `<1`, which is what it can still
             legitimately catch.
         (b) the compensating points_ledger row's programme was derived from the drained batches
             (`select distinct pb.programme_id into strict v_restore_programme`), which has no
             answer when they span two. It is now read from the ORIGINAL redemption's own ledger
             row via v_provenance.points_ledger_id -- a strictly better source, because it MIRRORS
             what redemption wrote instead of re-deriving it. Under programme_pot the two are the
             same value by construction (the drain loop filters on exactly the programme the
             ledger row is tagged with), so this is behaviour-preserving there.

       Redeem writes -cost on the reward's programme and reversal writes +cost on that same
       programme, while the batches are drained and restored one-for-one, so redeem-then-reverse
       nets to zero on every programme and on every batch.

   ============================================================================================
   A CONSEQUENCE THE OWNER SHOULD KNOW, stated rather than hidden
   ============================================================================================
   A cross-pot spend writes ONE ledger row, tagged to the reward's programme, while draining
   batches from two. Business-wide the ledger sum and the batch remaining still agree exactly --
   that is the invariant public.reverse_loyalty_redemption_v34_base checks and it is left in
   force. PER PROGRAMME they no longer agree, and app.programme_balance_scope_v312 treats a
   per-programme disagreement as a reason to answer 'business_pot'. So a firm that performs one
   cross-pot redemption stays in business_pot scope afterwards even once its pot migration is
   finished.

   That is self-consistent -- the scope that authorised spending across pots is the scope the
   firm keeps -- and it fails in the safe direction: the customer keeps seeing, and keeps being
   able to spend, every point they hold. It is NOT reverted by anything in this migration, and
   returning such a firm to programme_pot would require splitting the redemption ledger row per
   drained programme, which changes the provenance contract (one points_ledger_id per redemption)
   and is a separate, larger decision. Flagged, not silently taken.

   The per-programme half of the reversal's closing invariant is therefore run only when the
   drains sat in ONE programme -- where it still has teeth and still fires. The business-wide
   half runs unconditionally, exactly as today.

   ============================================================================================
   THE v813 EXEMPTION IS RETIRED HERE, not edited into an applied migration
   ============================================================================================
   v813's verify block exempted app.reward_availability_v432 from "every per-client points-pot
   reader must ask what the pot means". That exemption is now false. An applied migration is never
   edited, so the same estate scan is re-run below WITHOUT it: three exemptions remain
   (app.stamp_progress_v323 and app.stamp_reward_earned_at_v464, because a stamp card is one
   programme by construction, and app.tier_resolve_v426, because the tier metric is lifetime earn
   rather than the spendable pot), and app.reward_availability_v432 must now pass on its merits.

   No client change: the customer wallet and the staff till already read these servers' answers
   (balance from the v813 readers, availability and remaining_units from v432's projections), and
   no key, shape or type in any payload changes.

   Rollback suite: db/tests/v815_redeem_across_pots_in_business_scope.sql */
begin;

-- =============================================================================================
-- Extract-and-diff: patch the LIVE definition text, so a replay cannot silently overwrite a
-- newer body with an older transcription of it. Every anchor is comment-free -- the stored
-- definition carries inline comments that a migration pipeline may strip, and an anchor that
-- included one would match here and fail there. Every REPLACEMENT is comment-free for the same
-- reason: a later migration must be able to anchor on what this one leaves behind.
-- Each of the eleven anchors below was verified to occur EXACTLY ONCE in the live definition
-- on production (read-only, 2026-09-07) before this file was written; the loop re-checks.
-- =============================================================================================
do $v815_pots$
declare
  v_site record;
  v_def text;
  v_new text;
  v_hits integer;
  v_spliced integer := 0;
  k_avail text := 'app.reward_availability_v432(uuid,uuid,timestamp with time zone)';
  k_redeem text := 'app.redeem_reward_core(uuid,uuid,uuid,text,uuid,uuid,uuid)';
  k_reverse text := 'public.reverse_loyalty_redemption_v34_base(uuid,uuid,text,text)';
begin
  for v_site in
    select * from (values
      -- ---------------------------------------------------------------- app.reward_availability_v432
      -- One tenant-wide scope resolution for the whole catalogue projection, then both halves of
      -- the least(ledger, unexpired batches) pot.
      (1, k_avail,
       '  with business as (',
       '  with pot_scope as materialized ('                                       || chr(10) ||
       '    select app.programme_balance_scope_v312(p_business) as scope'         || chr(10) ||
       '  ), business as ('),
      (2, k_avail,
       'and pl.programme_id = (select id from points_spine)',
       'and ((select scope from pot_scope) <> ''programme_pot'''                  || chr(10) ||
       '               or pl.programme_id = (select id from points_spine))'),
      (3, k_avail,
       'and pb.programme_id = (select id from points_spine)',
       'and ((select scope from pot_scope) <> ''programme_pot'''                  || chr(10) ||
       '               or pb.programme_id = (select id from points_spine))'),

      -- ---------------------------------------------------------------------- app.redeem_reward_core
      (4, k_redeem,
       '  v_consumes boolean:=true; v_points_spent integer; v_cycle_id uuid; v_config_version uuid;',
       '  v_consumes boolean:=true; v_points_spent integer; v_cycle_id uuid; v_config_version uuid;'
                                                                                 || chr(10) ||
       '  v_all_pots boolean := false;'),
      -- Resolved once, on the points path only: a stamp claim consumes no batches at all.
      (5, k_redeem,
       '    v_points_spent:=v_version.cost_points;',
       '    v_all_pots := app.programme_balance_scope_v312(p_business) <> ''programme_pot'';'
                                                                                 || chr(10) ||
       '    v_points_spent:=v_version.cost_points;'),
      (6, k_redeem,
       'select coalesce(sum(remaining),0)::integer into v_batch_balance from public.points_batches'
       || ' where business_id=p_business and client_id=p_client and programme_id=v_reward_programme;',
       'select coalesce(sum(remaining),0)::integer into v_batch_balance from public.points_batches'
       || ' where business_id=p_business and client_id=p_client'
       || ' and (v_all_pots or programme_id=v_reward_programme);'),
      (7, k_redeem,
       'and remaining>0 and programme_id=v_reward_programme order by expires_at nulls last,earned_at,id for update loop',
       'and remaining>0 and (v_all_pots or programme_id=v_reward_programme) order by expires_at nulls last,earned_at,id for update loop'),
      -- The fence must recompute over the SAME set it measured, or it fires on every cross-pot spend.
      (8, k_redeem,
       'if (select coalesce(sum(remaining),0)::integer from public.points_batches'
       || ' where business_id=p_business and client_id=p_client and programme_id=v_reward_programme)'
       || ' <> v_batch_balance-v_version.cost_points then',
       'if (select coalesce(sum(remaining),0)::integer from public.points_batches'
       || ' where business_id=p_business and client_id=p_client'
       || ' and (v_all_pots or programme_id=v_reward_programme))'
       || ' <> v_batch_balance-v_version.cost_points then'),

      -- ------------------------------------------ public.reverse_loyalty_redemption_v34_base
      -- (a) the guard that would refuse every cross-pot reversal. "or none" is already dead --
      --     an empty drain set is rejected earlier by 'incomplete batch drain provenance
      --     evidence' -- so what remains is the half that can still legitimately fire.
      (9, k_reverse,
       'if v_restore_programmes<>1 then raise exception ''restored batches span more than one programme or none'' using errcode=''XX001''; end if;',
       'if v_restore_programmes<1 then raise exception ''restored batches span no programme'' using errcode=''XX001''; end if;'),
      -- (b) mirror the programme the ORIGINAL redemption's ledger row carries instead of
      --     re-deriving it from the drained batches, which has no answer across two pots.
      --     Under programme_pot these are the same value by construction.
      (10, k_reverse,
       '  select distinct pb.programme_id into strict v_restore_programme'        || chr(10) ||
       '    from public.points_batches pb'                                        || chr(10) ||
       '   where pb.id in (select d.points_batch_id from public.loyalty_redemption_batch_drains d'
                                                                                  || chr(10) ||
       '                    where d.provenance_id=v_provenance.id);',
       '  select pl2.programme_id into strict v_restore_programme'                || chr(10) ||
       '    from public.points_ledger pl2'                                        || chr(10) ||
       '   where pl2.id=v_provenance.points_ledger_id;'                           || chr(10) ||
       '  if v_restore_programme is null then raise exception ''original redemption ledger row carries no programme'' using errcode=''XX001''; end if;'),
      -- (c) the per-programme closing invariant keeps its teeth where it has meaning: a spend
      --     confined to one pot. A cross-pot spend writes one ledger row and drains two pots, so
      --     per-programme divergence is its DEFINED outcome (see the header). The business-wide
      --     half above runs unconditionally, exactly as today.
      (11, k_reverse,
       '  if (select coalesce(sum(points),0) from public.points_ledger where business_id=p_business and client_id=v_redemption.client_id and programme_id=v_restore_programme)',
       '  if v_restore_programmes = 1 and (select coalesce(sum(points),0) from public.points_ledger where business_id=p_business and client_id=v_redemption.client_id and programme_id=v_restore_programme)')
    ) as site(seq, fn, needle, replacement)
    order by 1
  loop
    v_def := pg_get_functiondef(v_site.fn::regprocedure);
    if position(v_site.replacement in v_def) > 0 then
      raise notice 'nestly_v815: splice % on % is already present, skipping', v_site.seq, v_site.fn;
      continue;
    end if;
    v_hits := (length(v_def) - length(replace(v_def, v_site.needle, '')))
              / nullif(length(v_site.needle), 0);
    if v_hits <> 1 then
      raise exception 'nestly_v815: splice % expected exactly one anchor in %, found %',
        v_site.seq, v_site.fn, v_hits using errcode = 'XX001';
    end if;
    v_new := replace(v_def, v_site.needle, v_site.replacement);
    if v_new = v_def then
      raise exception 'nestly_v815: splice % on % produced no change', v_site.seq, v_site.fn
        using errcode = 'XX001';
    end if;
    execute v_new;
    v_spliced := v_spliced + 1;
  end loop;
  raise notice 'nestly_v815: % splice(s) applied', v_spliced;
end
$v815_pots$;

-- ACLs restated. `create or replace` preserves them, which is precisely why they are restated:
-- the guarantee should be in the file, not in the reader's memory of what the catalog held.
-- The two app.* functions are internal -- reachable only through their public wrappers.
revoke all privileges on function
  app.reward_availability_v432(uuid,uuid,timestamp with time zone) from public, anon, authenticated;
revoke all privileges on function
  app.redeem_reward_core(uuid,uuid,uuid,text,uuid,uuid,uuid) from public, anon, authenticated;
revoke all privileges on function
  public.reverse_loyalty_redemption_v34_base(uuid,uuid,text,text) from public, anon;
grant execute on function public.reverse_loyalty_redemption_v34_base(uuid,uuid,text,text)
  to authenticated, service_role;

-- =============================================================================================
-- Prove it took, and re-run v813's estate scan WITHOUT the exemption this migration retires.
-- =============================================================================================
do $verify$
declare
  v_row record;
  v_missing text := '';
  v_avail text := pg_get_functiondef(
    'app.reward_availability_v432(uuid,uuid,timestamp with time zone)'::regprocedure);
  v_redeem text := pg_get_functiondef(
    'app.redeem_reward_core(uuid,uuid,uuid,text,uuid,uuid,uuid)'::regprocedure);
  v_reverse text := pg_get_functiondef(
    'public.reverse_loyalty_redemption_v34_base(uuid,uuid,text,text)'::regprocedure);
begin
  -- 1. v813's scan, minus app.reward_availability_v432. Same derivation from the catalog (STABLE,
  --    takes a client argument, aggregates a points sum, filters by programme); three exemptions
  --    remain, each for a stated reason, and anything NEW of this shape still fails here.
  for v_row in
    select n.nspname || '.' || p.proname as fn, pg_get_functiondef(p.oid) as def
      from pg_catalog.pg_proc p
      join pg_catalog.pg_namespace n on n.oid = p.pronamespace
     where n.nspname in ('public', 'app')
       and p.prokind in ('f', 'p')
       and p.provolatile = 's'
       and exists (select 1 from unnest(coalesce(p.proargnames, '{}')) a where a like 'p_client%')
       and pg_get_functiondef(p.oid) ~ 'sum\([[:space:]]*[a-z_]+\.(points|remaining)[[:space:]]*\)'
       and pg_get_functiondef(p.oid) like '%programme_id%'
       and n.nspname || '.' || p.proname not in (
             'app.stamp_progress_v323',         -- a stamp card is one programme by construction
             'app.stamp_reward_earned_at_v464', -- likewise
             'app.tier_resolve_v426'            -- lifetime earn, not the spendable pot
           )
  loop
    if position('programme_balance_scope_v312' in v_row.def) = 0 then
      v_missing := v_missing || ' ' || v_row.fn;
    end if;
  end loop;
  if v_missing <> '' then
    raise exception 'nestly_v815: per-client pot reader(s) still ignore the balance scope:%',
      v_missing using errcode = 'XX001';
  end if;

  -- 2. BOTH halves of the availability pot carry the rule. least(ledger, batches) makes a half
  --    fix look exactly like no fix.
  if (select count(*) from regexp_matches(v_avail,
        '\(select scope from pot_scope\) <> ''programme_pot''', 'g')) <> 2 then
    raise exception 'nestly_v815: the availability pot does not carry the scope rule on BOTH its '
      'ledger and batch filters' using errcode = 'XX001';
  end if;
  if position('materialized' in v_avail) = 0 then
    raise exception 'nestly_v815: the availability scope CTE is not materialized; the tenant-wide '
      'aggregate would be re-evaluated per catalogue row' using errcode = 'XX001';
  end if;
  -- The reader widened AFFORDABILITY only. Which gifts are offered is untouched.
  if position('where rows.programme_active' in v_avail) = 0
     or position('and live.programme_id = sc.programme_id' in v_avail) = 0 then
    raise exception 'nestly_v815: the availability core lost a programme-offer filter; only the '
      'pot may widen' using errcode = 'XX001';
  end if;

  -- 3. The writer agrees with the reader at all three sites, and the fence recomputes over the
  --    same set it measured.
  if (select count(*) from regexp_matches(v_redeem,
        '\(v_all_pots or programme_id=v_reward_programme\)', 'g')) <> 3 then
    raise exception 'nestly_v815: app.redeem_reward_core carries the pot rule at % site(s), not 3 '
      '(pre-flight balance, drain loop, reconcile fence)',
      (select count(*) from regexp_matches(v_redeem,
        '\(v_all_pots or programme_id=v_reward_programme\)', 'g')) using errcode = 'XX001';
  end if;
  if position('app.programme_balance_scope_v312(p_business) <> ''programme_pot''' in v_redeem) = 0 then
    raise exception 'nestly_v815: app.redeem_reward_core never resolves the balance scope'
      using errcode = 'XX001';
  end if;
  -- FEFO, the advisory lock, the idempotency contract and the two conservation fences stay.
  if position('order by expires_at nulls last,earned_at,id for update' in v_redeem) = 0
     or position('app.acquire_loyalty_shared_v480(p_business)' in v_redeem) = 0
     or position('reward drain provenance does not conserve value' in v_redeem) = 0
     or position('reward batch drain was incomplete' in v_redeem) = 0
     or position('app.points_ledger_write_scope'',''redeem_points''' in v_redeem) = 0 then
    raise exception 'nestly_v815: app.redeem_reward_core lost FEFO order, the v480 lock, a '
      'conservation fence or its ledger write scope' using errcode = 'XX001';
  end if;

  -- 4. A cross-pot redemption is reversible: the guard that refused it is gone, the compensating
  --    row mirrors the original ledger row, and the restore loop still keys on the drain rows.
  if position('restored batches span more than one programme or none' in v_reverse) > 0 then
    raise exception 'nestly_v815: the reversal still refuses drains that span more than one '
      'programme; a cross-pot redemption would be permanently irreversible' using errcode = 'XX001';
  end if;
  if position('where pl2.id=v_provenance.points_ledger_id' in v_reverse) = 0 then
    raise exception 'nestly_v815: the reversal does not take the compensating row''s programme '
      'from the original redemption ledger row' using errcode = 'XX001';
  end if;
  if position('from public.loyalty_redemption_batch_drains d' in v_reverse) = 0
     or position('where d.provenance_id=v_provenance.id and d.business_id=p_business' in v_reverse) = 0 then
    raise exception 'nestly_v815: the reversal no longer reconstructs from the drain rows'
      using errcode = 'XX001';
  end if;
  -- The business-wide invariant stays unconditional; only the per-programme half is gated.
  if position('points ledger and points batch remaining invariant diverged' in v_reverse) = 0
     or position('v_restore_programmes = 1 and (select coalesce(sum(points),0)' in v_reverse) = 0 then
    raise exception 'nestly_v815: the reversal lost its closing value invariant'
      using errcode = 'XX001';
  end if;
end
$verify$;

commit;
