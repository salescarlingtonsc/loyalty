/* nestly_v813 — the customer's wallet and the staff's screen read the same pot.

   Raised by the nestly_v804 builder, who fixed the five STAFF-side instances of the inverted
   pot predicate and deliberately left the customer side alone with this note:

     "Two things deliberately NOT touched. app.c45_base_actionable_wallet_card and the other
      customer-side wallet readers filter on app.live_balance_programme_v381 alone and never
      consult the scope at all; that is a different shape with its own history and it is not
      this finding."

   It is this finding. After v804 the staff readers ask app.programme_balance_scope_v312 what a
   per-programme number MEANS for this firm right now — 'business_pot' sums every pot,
   'programme_pot' sums the live one — and the customer readers do not ask at all. Under
   'business_pot' the two answers differ, and they differ about the same customer's own points.

   ============================================================================================
   PROVED ON PRODUCTION, read-only, inside a transaction that was rolled back (2026-09-07)
   ============================================================================================
   Tenant "QA Kopi Lab (Bedok)" 8ad4a375-…, customer 05ca41be-…, whose ledger legitimately spans
   two pots: 15 on the live stamps programme and 116 left on the retired points programme.

     BEFORE  [programme_pot] staff_v409=15  | c45=15 | v384=15  balance_scope=programme_pot
     AFTER   [business_pot]  staff_v409=131 | c45=15 | v384=15  balance_scope=programme_pot

   The only thing that changed between the two lines is one pending row in
   public.programme_pot_migrations — exactly the state production enters when a pot migration is
   queued, and the state app.programme_balance_scope_v312 also falls back to whenever a
   (client, programme) pot's ledger sum and batch remaining disagree. In it, the Customers
   directory and the customer profile say 131 while the customer's own wallet says 15, and the
   wallet additionally reports 'balance_scope':'programme_pot' — a hardcoded literal that
   contradicts the server's own answer for that firm at that moment. 116 points that staff can
   see and the customer cannot is not a rounding difference; it reads to the customer as points
   taken away, and to the counter as a customer lying about their balance.

   ============================================================================================
   WHAT THIS MIGRATION CHANGES — three functions, seven splices
   ============================================================================================
   app.c45_base_actionable_wallet_card   the actionable wallet card (app.c44_actionable_wallet_card
       wraps it). Its `ledger_balance` and `unexpired_batches` CTEs both filtered
       `programme_id is not distinct from app.live_balance_programme_v381(...)` with no scope
       question. Both now carry the same rule the staff readers carry:
       (scope <> 'programme_pot' or programme_id is not distinct from live). BOTH sites matter:
       the card reports least(ledger, unexpired batches), so fixing one alone would leave the
       other clamping the answer back down to the live pot.

   app.customer_live_loyalty_v384        the balance behind public.customer_get_wallet() and
       public.customer_get_business_summary. Same two sites (it spells the filter `= s.programme_id`
       against its own spine selection rather than calling v381 — the same fact, differently
       written, which is why an estate scan keyed only on v381 would have missed it). Plus the
       hardcoded 'balance_scope':'programme_pot' in its `programme` object, replaced by the
       server's real answer.

   public.customer_portal_capabilities   carried the same hardcoded literal per programme spine.
       Replaced by the real scope, computed ONCE into a local rather than inlined per spine row —
       app.programme_balance_scope_v312 aggregates the whole tenant's ledger and batches, and the
       v370 finding was that slow RPCs were re-evaluated functions, not missing indexes.

   The literal is the last of its kind: after this migration no function in `public` or `app`
   reports a balance_scope that is not app.programme_balance_scope_v312's answer, and the
   verify block below asserts that estate-wide rather than for a named list.
   app.programme_balance_scope_v312's own comment always intended this — "read by the five W4a
   customer readers in place of the literal they shipped, so the flip is a VALUE change on a key
   the client already reads". public.customer_get_loyalty_details, public.customer_get_reward_catalog
   and public.customer_get_effective_tier_v143 already do; these three were the stragglers.

   ============================================================================================
   WHAT THIS MIGRATION DELIBERATELY DOES NOT CHANGE (and why), with the estate scan that proves
   the list is complete rather than convenient
   ============================================================================================
   A read-only scan of production on 2026-09-07 for STABLE functions in `public`/`app` that take
   a client argument and aggregate sum(x.points) / sum(x.remaining) with a programme filter finds
   eight. Four now carry the scope (client_points_balance_v409, staff_get_customer_actionable_
   loyalty_v145 after v804, and the two corrected here). The other four are exempted in the
   verify block, each for a stated reason, and any NEW function of that shape fails the gate:

     app.reward_availability_v432    the spendable-at-the-counter pot. app.redeem_reward_core
       deducts from the batches of the REWARD'S OWN programme, so widening this reader to every
       pot would advertise gifts the counter then refuses — the one thing v432 exists to prevent
       (see its own nestly_v568 comment). Making redemption itself pot-scope-aware is a real
       question and an owner decision; it is not a reader fix and it is not this migration.
     app.stamp_progress_v323
     app.stamp_reward_earned_at_v464 a stamp card is per-programme by construction: one card, one
       cycle, one spine. Pot scope is a points concept; there is no "sum every stamp card".
     app.tier_resolve_v426           the tier metric is lifetime EARN, not the spendable pot, and
       it already chooses business-wide or programme-scoped from the tier basis.

   Volatile functions are out by construction (public.adjust_points, public.redeem_points,
   app.redeem_points_v40_internal): they are writers, and what a writer may spend across pots is
   the same owner question as v432.

   Also untouched, and NOT of this class: app.v177_overview, app.v179_business_insights,
   public.get_dashboard_summary_v155 and public.get_reports_summary reference v381 but report
   FIRM-WIDE figures per programme, deliberately listing the other pots separately rather than
   totalling them ("one programme per figure, each with its unit, no total"); and
   app.tier_observe_v1 uses v381 only as the programme label it stamps on a tier-state row.
   None of them answers "what is this customer's balance", which is the fact this migration is
   about.

   Rollback suite: db/tests/v813_wallet_readers_pot_scope.sql */
begin;

-- =============================================================================================
-- Extract-and-diff: patch the LIVE definition text, so a replay cannot silently overwrite a
-- newer body with an older transcription of it. Every anchor is comment-free — the stored
-- definition carries inline comments that a migration pipeline may strip, and an anchor that
-- included one would match here and fail there.
-- =============================================================================================
do $v813_wallet$
declare
  v_site record;
  v_def text;
  v_new text;
  v_hits integer;
  v_spliced integer := 0;
begin
  for v_site in
    select * from (values
      -- app.c45_base_actionable_wallet_card: one pot resolver for the whole card, then the two
      -- balance filters. `materialized` so the tenant-wide scope aggregate runs once, not per row.
      (1, 'app.c45_base_actionable_wallet_card(uuid,uuid,text,text,text,text,text[],timestamp with time zone)',
       '  with spine as (',
       '  with pot as materialized ('                                           || chr(10) ||
       '    select app.programme_balance_scope_v312(p_business_id) as scope,'   || chr(10) ||
       '           app.live_balance_programme_v381(p_business_id) as live'      || chr(10) ||
       '  ), spine as ('),
      (2, 'app.c45_base_actionable_wallet_card(uuid,uuid,text,text,text,text,text[],timestamp with time zone)',
       'and pl.programme_id is not distinct from app.live_balance_programme_v381(p_business_id)',
       'and ((select scope from pot) <> ''programme_pot'''                      || chr(10) ||
       '            or pl.programme_id is not distinct from (select live from pot))'),
      (3, 'app.c45_base_actionable_wallet_card(uuid,uuid,text,text,text,text,text[],timestamp with time zone)',
       'and pb.programme_id is not distinct from app.live_balance_programme_v381(p_business_id)',
       'and ((select scope from pot) <> ''programme_pot'''                      || chr(10) ||
       '            or pb.programme_id is not distinct from (select live from pot))'),

      -- app.customer_live_loyalty_v384: same rule, spelled against its own spine selection.
      (4, 'app.customer_live_loyalty_v384(uuid,uuid,text[],timestamp with time zone)',
       '  with live as (',
       '  with pot as materialized ('                                           || chr(10) ||
       '    select app.programme_balance_scope_v312(p_business_id) as scope'    || chr(10) ||
       '  ), live as ('),
      (5, 'app.customer_live_loyalty_v384(uuid,uuid,text[],timestamp with time zone)',
       'and pl.programme_id = s.programme_id',
       'and ((select scope from pot) <> ''programme_pot'' or pl.programme_id = s.programme_id)'),
      (6, 'app.customer_live_loyalty_v384(uuid,uuid,text[],timestamp with time zone)',
       'and pb.programme_id = s.programme_id',
       'and ((select scope from pot) <> ''programme_pot'' or pb.programme_id = s.programme_id)'),
      (7, 'app.customer_live_loyalty_v384(uuid,uuid,text[],timestamp with time zone)',
       '''balance_scope'', ''programme_pot''',
       '''balance_scope'', (select scope from pot)'),

      -- public.customer_portal_capabilities: the same literal, once per spine row. Resolve once.
      (8, 'public.customer_portal_capabilities(text)',
       '  v_programmes jsonb;',
       '  v_programmes jsonb;'                                                  || chr(10) ||
       '  v_balance_scope text;'),
      (9, 'public.customer_portal_capabilities(text)',
       '    else null end;',
       '    else null end;'                                                     || chr(10) ||
       '  v_balance_scope := app.programme_balance_scope_v312(v_context.business_id);'),
      (10, 'public.customer_portal_capabilities(text)',
       '''balance_scope'', ''programme_pot'',',
       '''balance_scope'', v_balance_scope,')
    ) as site(seq, fn, needle, replacement)
    order by 1
  loop
    v_def := pg_get_functiondef(v_site.fn::regprocedure);
    if position(v_site.replacement in v_def) > 0 then
      raise notice 'nestly_v813: splice % on % is already present, skipping', v_site.seq, v_site.fn;
      continue;
    end if;
    v_hits := (length(v_def) - length(replace(v_def, v_site.needle, '')))
              / nullif(length(v_site.needle), 0);
    if v_hits <> 1 then
      raise exception 'nestly_v813: splice % expected exactly one anchor in %, found %',
        v_site.seq, v_site.fn, v_hits using errcode = 'XX001';
    end if;
    v_new := replace(v_def, v_site.needle, v_site.replacement);
    if v_new = v_def then
      raise exception 'nestly_v813: splice % on % produced no change', v_site.seq, v_site.fn
        using errcode = 'XX001';
    end if;
    execute v_new;
    v_spliced := v_spliced + 1;
  end loop;
  raise notice 'nestly_v813: % splice(s) applied', v_spliced;
end
$v813_wallet$;

-- ACLs restated. `create or replace` preserves them, which is precisely why they are restated:
-- the guarantee should be in the file, not in the reader's memory of what the catalog held.
-- The two app.* readers are internal — reachable only through their public wrappers, never
-- directly from PostgREST.
revoke all privileges on function
  app.c45_base_actionable_wallet_card(uuid,uuid,text,text,text,text,text[],timestamp with time zone)
  from public, anon, authenticated;
revoke all privileges on function
  app.customer_live_loyalty_v384(uuid,uuid,text[],timestamp with time zone)
  from public, anon, authenticated;
revoke all privileges on function public.customer_portal_capabilities(text) from public, anon;
grant execute on function public.customer_portal_capabilities(text)
  to authenticated, service_role;

-- =============================================================================================
-- Prove it took, and prove the class is closed — by scanning the estate, not a list of names.
-- =============================================================================================
do $verify$
declare
  v_row record;
  v_missing text := '';
  v_literal text := '';
begin
  -- 1. Every per-client points-pot READER must ask what the pot means. "Per-client pot reader" is
  --    derived from the catalog: STABLE (writers are a separate, owner-level question), takes a
  --    client argument, aggregates a points sum, and filters by programme. The four exemptions
  --    are named WITH their reason in the header; anything new of this shape fails here.
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
             'app.reward_availability_v432',    -- spendable at the counter; the writer is pot-bound
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
    raise exception 'nestly_v813: per-client pot reader(s) still ignore the balance scope:%',
      v_missing using errcode = 'XX001';
  end if;

  -- 2. No surface may report a balance_scope the server did not answer. The two hardcoded
  --    literals were the whole reason a customer could be told 'programme_pot' by a firm the
  --    server had already moved to 'business_pot'.
  for v_row in
    select n.nspname || '.' || p.proname as fn, pg_get_functiondef(p.oid) as def
      from pg_catalog.pg_proc p
      join pg_catalog.pg_namespace n on n.oid = p.pronamespace
     where n.nspname in ('public', 'app')
       and p.prokind in ('f', 'p')
  loop
    if position('''balance_scope'', ''programme_pot''' in v_row.def) > 0
       or position('''balance_scope'',''programme_pot''' in v_row.def) > 0 then
      v_literal := v_literal || ' ' || v_row.fn;
    end if;
  end loop;
  if v_literal <> '' then
    raise exception 'nestly_v813: hardcoded balance_scope literal(s) remain:%', v_literal
      using errcode = 'XX001';
  end if;

  -- 3. The splices took, in the transaction that made them: both balance filters in each of the
  --    two wallet readers, not just the first one. least(ledger, batches) makes a half fix look
  --    exactly like no fix.
  if (select count(*) from regexp_matches(
        pg_get_functiondef(('app.c45_base_actionable_wallet_card(uuid,uuid,text,text,text,text,'
          || 'text[],timestamp with time zone)')::regprocedure),
        '\(select scope from pot\) <> ''programme_pot''', 'g')) <> 2 then
    raise exception 'nestly_v813: the wallet card does not carry the scope rule on BOTH its '
      'ledger and batch filters' using errcode = 'XX001';
  end if;
  if (select count(*) from regexp_matches(
        pg_get_functiondef(
          'app.customer_live_loyalty_v384(uuid,uuid,text[],timestamp with time zone)'::regprocedure),
        '\(select scope from pot\) <> ''programme_pot''', 'g')) <> 2 then
    raise exception 'nestly_v813: customer_live_loyalty_v384 does not carry the scope rule on '
      'BOTH its ledger and batch filters' using errcode = 'XX001';
  end if;
end
$verify$;

commit;
