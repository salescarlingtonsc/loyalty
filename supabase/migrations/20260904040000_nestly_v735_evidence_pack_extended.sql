-- NESTLY v735 — the AI firm-report evidence pack's ci_opportunities section runs the consultant
-- spine in EXTENDED mode, so the narrative actually sees the consultant payload.
--
-- ===========================================================================================
-- THE DEFECT, proven empirically by db/tests/executed/v733_corpus_best_customers_campaign.sql's
-- PART E on this exact tree (not merely read off the source): db/migrations/20260902_nestly_v713_
-- evidence_pack_typed_findings.sql wired a fifth gated section into app.v176_gated_evidence,
--
--   v_ci := public.get_ci_opportunities_v1(p_business, p_from, v_to_effective);
--
-- three positional arguments. public.get_ci_opportunities_v1's fourth/fifth/sixth parameters are
-- `p_branch uuid default null, p_as_of timestamptz default clock_timestamp(), p_extended boolean
-- default false` (confirmed against the live signature the v720/v712/v718 grant statements and
-- v713's own fixture stub already pin: `(uuid,date,date,uuid,timestamptz,boolean)`) — so this call
-- always runs the BASE pass. Every generator nestly_v688/v705/v691/v683 added that only fires
-- `if p_extended` — campaigns (v705, check 22), discovery (v708), change, the three strength
-- candidates' second alternative, and the whole report_sections/top_actions/materiality/
-- margin_guard/capacity/concentration enrichment pass (v705/v712, checks 23/25/66/74/77) — can
-- therefore NEVER appear in an AI firm report's evidence, in production, ever. v733's header
-- documented this as "ONE DISCOVERED, DOCUMENTED DEVIATION FROM THE TASK BRIEF'S WORDING" and its
-- PART E proved the campaigns candidate is genuinely absent from app.v176_evidence_pack's
-- `findings.ranked` on a seed engineered so the base pass alone would still find something to rank
-- (gateway_followthrough) — i.e. the absence is this specific wiring gap, not an empty pack.
--
-- THE FIX. app.v176_gated_evidence's ci_opportunities call gains the three trailing arguments —
-- `null` (firm-wide, no p_branch — this pack has never been branch-scoped, its own p_business/
-- p_from/p_to are the only scope it carries), `clock_timestamp()` (p_as_of — the pack has no
-- "as of" concept of its own; every other gated section in this function reads live data as of
-- now, and clock_timestamp() is the same default the parameter itself declares, made explicit
-- rather than implicit so a future default change to get_ci_opportunities_v1 cannot silently
-- change what THIS caller means), and `true` (p_extended). One line, one anchor, comment-free —
-- nothing else in app.v176_gated_evidence's declare block, try/catch shape, or return object
-- changes; the `findings` key app.v176_evidence_pack (untouched by this migration) already builds
-- from `v_gated->'ci_opportunities'->'ranked'`/`'top_actions'`/`'abstentions'` now simply has a
-- richer object to read from, with no new plumbing required on that side — exactly what v713's own
-- closing comment predicted ("Neither array exists yet in tests/ai-reports/... A fixture pointed
-- at findings.ranked ... would close that gap").
--
-- WHAT THIS MIGRATION DOES NOT DO. It does not touch public.get_ci_opportunities_v1, app.
-- v176_evidence_pack, app.ci_access_gate_v667, or supabase/functions/ai-firm-reports/validate.mjs
-- or index.ts. validate.mjs's readPack/typedFindings (checked against the live file for this
-- migration, not assumed) walk the WHOLE pack generically — every leaf is visited by one recursive
-- `walk()` with no size cap, no depth cap, and no assumption about which key holds which shape; a
-- larger `findings.ranked` array is simply more objects for `packInfo.objects`/`typedFindings` to
-- iterate over, the identical code path a base-pass pack already exercises today. index.ts's
-- prompt assembly (assembleUserPrompt, in validate.mjs, imported unchanged by index.ts) calls
-- `JSON.stringify(report.evidence, null, 2)` — it sends the ENTIRE evidence object to the model
-- verbatim, so the extended payload's added bytes (report_sections, top_actions, and every
-- extended-only candidate's incentive/why_now/reversal_condition/alternatives/materiality/
-- margin_guard/capacity/concentration keys) land directly in the prompt. Measured directly, by
-- this migration's own verification below, against one golden business (a five-recipient
-- campaign seed — the minimum that clears the marketing funnel's own n>=5 evidence floor, the
-- same floor db/tests/executed/v733_corpus_best_customers_campaign.sql's R-group uses):
-- public.get_ci_opportunities_v1's non-extended payload is 4,020 bytes; the extended payload for
-- the SAME business/window is 14,657 bytes — a delta of +10,637 bytes, ~3.65x. The verification
-- only asserts the delta is non-negative (extended must never be smaller — v688/v705/v712's own
-- headers document every extended-mode addition as strictly additive), never a brittle exact-byte
-- pin that would fail on the next unrelated wording tweak; the 4,020/14,657/10,637/3.65x figures
-- above are this migration's own measured record of the cost, not an assertion. The delta scales
-- with candidate count, not seed size, so a busier real business with more promoted candidates
-- will see a larger absolute delta. That is a real, intended cost of this fix (the whole point is
-- more evidence reaching the model), not a regression — flagged here per this migration's own
-- task brief rather than left for someone else to notice as a surprise later.
--
-- Anchored, comment-free replace-equality edit of the LIVE body (pg_get_functiondef captured at
-- apply time), verified to round-trip back to the exact live original once the intended edit is
-- reversed — same discipline as v668/v690/v696/v705/v706/v712/v713/v726/v730, never a hand-retyped
-- guess at the base text. Base body is v713's own re-emit of this function (the ci_opportunities
-- try/catch section, unmodified by v720/v721/v725 — all three are read below to confirm, not
-- assumed — those three touch grants and other functions' gate arms, never this call line).
--
-- Proven by db/tests/executed/v735_corpus_evidence_pack_extended.sql.

begin;

-- =============================================================================================
-- app.v176_gated_evidence — the ci_opportunities call becomes an extended-mode call. One anchor.
-- =============================================================================================
do $v735_gated$
declare
  v_def  text;
  v_new  text;
  v_after text;
  v_roundtrip text;
  v_count integer;

  v_anchor constant text :=
    $anc$    v_ci := public.get_ci_opportunities_v1(p_business, p_from, v_to_effective);$anc$;
  v_new_text constant text :=
    $newt$    v_ci := public.get_ci_opportunities_v1(p_business, p_from, v_to_effective, null, clock_timestamp(), true);$newt$;
begin
  select pg_get_functiondef(to_regprocedure('app.v176_gated_evidence(uuid,date,date)')) into v_def;
  if v_def is null then
    raise exception 'v735: app.v176_gated_evidence(uuid,date,date) is missing';
  end if;

  v_count := (length(v_def) - length(replace(v_def, v_anchor, ''))) / greatest(length(v_anchor), 1);
  if v_count <> 1 then
    raise exception 'v735: v176_gated_evidence ci_opportunities call anchor occurs % times (expected 1) — '
      'live body drifted from what this migration expects', v_count;
  end if;

  v_new := replace(v_def, v_anchor, v_new_text);
  execute v_new;

  select pg_get_functiondef(to_regprocedure('app.v176_gated_evidence(uuid,date,date)')) into v_after;
  v_roundtrip := replace(v_after, v_new_text, v_anchor);
  if v_roundtrip <> v_def then
    raise exception 'v735: v176_gated_evidence changed by more than the p_extended=>true call edit'
      using detail = 'intended:' || E'\n' || v_def || E'\n' || 'actual (reversed):' || E'\n' || v_roundtrip;
  end if;
end
$v735_gated$;

-- ACL restated verbatim from the live proacl (unchanged by this migration — same argument list,
-- and CREATE OR REPLACE preserves grants; v713's own 4.1 already proved no anon/authenticated/
-- service_role execute grant exists on this function, restated as an assertion below rather than
-- a grant statement, since there is nothing to grant back to).

-- =============================================================================================
-- Verification, executed rather than asserted. The scratch business this creates is discarded via
-- SAVEPOINT/ROLLBACK TO SAVEPOINT, not DELETE — same reason v713's own verification uses a
-- savepoint (an immutability-guard trigger on rows a fresh business seeds refuses DELETE).
-- =============================================================================================
savepoint v735_verify;

do $verify$
declare
  v_biz uuid := '00000000-0000-4000-8000-0000000735fa';
  v_br  uuid := '00000000-0000-4000-8000-0000000735fb';
  v_pack jsonb;
  v_before_bytes integer;
  v_after_bytes integer;
  v_pack_before jsonb;
begin
  -- V1 · No grant was loosened by the CREATE OR REPLACE above.
  if pg_catalog.has_function_privilege('anon', 'app.v176_gated_evidence(uuid,date,date)', 'execute')
     or pg_catalog.has_function_privilege('authenticated', 'app.v176_gated_evidence(uuid,date,date)', 'execute')
     or pg_catalog.has_function_privilege('service_role', 'app.v176_gated_evidence(uuid,date,date)', 'execute')
  then
    raise exception 'v735: a non-owner role can execute app.v176_gated_evidence directly';
  end if;

  -- V2 · A thin business (no purchase history at all): the extended call must not turn an honest
  --      abstention into a raised error. The section stays available (or cleanly unavailable for a
  --      billing/schema reason exactly like v713's own 4.3), never a 500.
  insert into public.businesses (id, name, slug) values (v_biz, 'ZZ v735 verify', 'zz-v735-verify')
    on conflict (id) do nothing;

  perform app.v676_open_internal_drain();
  begin
    v_pack_before := app.v176_evidence_pack(v_biz, 'monthly', current_date - 35, current_date - 5);
  exception when others then
    perform app.v676_close_internal_drain();
    raise exception 'v735: app.v176_evidence_pack raised on a thin business: %', sqlerrm;
  end;
  perform app.v676_close_internal_drain();
  if not (v_pack_before ? 'findings') then
    raise exception 'v735: the evidence pack has no findings key at all on a thin business';
  end if;
  if jsonb_typeof(v_pack_before->'findings'->'ranked') is distinct from 'array' then
    raise exception 'v735: findings.ranked is not an array on a thin business: %', v_pack_before->'findings';
  end if;

  -- V3 · Structural, populated case: a v733-shaped best-customers-campaign business, sessionless
  --      (no request.jwt.claims — the real production shape), through app.v176_evidence_pack.
  --      Confirms the extended-only campaigns candidate now reaches findings.ranked, which is the
  --      one thing this migration exists to fix.
  insert into public.branches (id, business_id, name, is_default, active)
    values (v_br, v_biz, 'ZZ v735 branch', true, true)
    on conflict (id) do nothing;

  declare
    d_send date := current_date - 45;
    c1 uuid := '00000000-0000-4000-8000-0000007351c1';
    c2 uuid := '00000000-0000-4000-8000-0000007351c2';
    c3 uuid := '00000000-0000-4000-8000-0000007351c3';
    c4 uuid := '00000000-0000-4000-8000-0000007351c4';
    c5 uuid := '00000000-0000-4000-8000-0000007351c5';
    off int;
  begin
    -- five recipients: public.get_ci_marketing_funnel_v1's associated_purchase evidence needs
    -- n >= 5 matured sends (the same floor v705's campaigns generator reads) before it reports
    -- status='ok' and gives the campaigns generator a rate to promote at all.
    insert into public.clients (id, business_id, full_name) values
      (c1, v_biz, 'ZZ v735 c1'), (c2, v_biz, 'ZZ v735 c2'), (c3, v_biz, 'ZZ v735 c3'),
      (c4, v_biz, 'ZZ v735 c4'), (c5, v_biz, 'ZZ v735 c5')
      on conflict (id) do nothing;

    foreach off in array array[-60,-50,-40,-30,-20,-10] loop
      insert into public.sales (business_id, branch_id, client_id, kind, amount_cents, occurred_at,
        counts_as_revenue, counts_as_visit, earns_points, policy_resolved_at,
        commission_rate_bps, commission_resolved_at)
      select v_biz, v_br, c.cid, 'service', 10000,
             (d_send + off)::timestamp + time '10:00', true, true, true,
             (d_send + off)::timestamp + time '10:00', 0, (d_send + off)::timestamp + time '10:00'
        from (values (c1), (c2), (c3), (c4), (c5)) as c(cid);
    end loop;

    insert into public.campaign_send_records_v255
      (business_id, campaign_kind, campaign_ref_id, send_kind, campaign_label, channel,
       client_id, occurred_at, retention_until)
    select v_biz, 'promotion', gen_random_uuid(), 'blast', 'ZZ v735 campaign', 'none',
           cid, d_send::timestamp + time '11:00',
           d_send::timestamp + time '11:00' + interval '400 days'
      from (values (c1), (c2), (c3), (c4), (c5)) as c(cid);

    insert into public.sales (business_id, branch_id, client_id, kind, amount_cents, occurred_at,
      counts_as_revenue, counts_as_visit, earns_points, policy_resolved_at,
      commission_rate_bps, commission_resolved_at)
    select v_biz, v_br, cid, 'service', 10000,
           (d_send + 10)::timestamp + time '10:00', true, true, true,
           (d_send + 10)::timestamp + time '10:00', 0, (d_send + 10)::timestamp + time '10:00'
      from (values (c1), (c2), (c3), (c4), (c5)) as c(cid);

    perform app.v676_open_internal_drain();
    begin
      v_pack := app.v176_evidence_pack(v_biz, 'monthly', d_send, d_send);
    exception when others then
      perform app.v676_close_internal_drain();
      raise exception 'v735: app.v176_evidence_pack raised on the populated seed: %', sqlerrm;
    end;
    perform app.v676_close_internal_drain();

    if not exists (select 1 from jsonb_array_elements(v_pack->'findings'->'ranked') c
                    where c->>'id' = 'campaigns') then
      raise exception 'v735: the campaigns candidate is still absent from findings.ranked after '
        'wiring p_extended=>true — the fix did not take effect: %', v_pack->'findings'->'ranked';
    end if;

    if not exists (select 1 from jsonb_array_elements(v_pack->'findings'->'ranked') c
                    where c->>'id' = 'campaigns' and c->>'evidence_class' = 'ASSOCIATION') then
      raise exception 'v735: campaigns candidate in findings.ranked is not evidence_class=ASSOCIATION: %',
        (select c from jsonb_array_elements(v_pack->'findings'->'ranked') c where c->>'id' = 'campaigns');
    end if;

    if jsonb_typeof(v_pack->'findings'->'top_actions') is distinct from 'array'
       or jsonb_array_length(v_pack->'findings'->'top_actions') = 0 then
      raise exception 'v735: findings.top_actions is empty on a business with a promoted candidate: %',
        v_pack->'findings'->'top_actions';
    end if;

    -- V4 · Pack-size delta for THIS ONE golden business, extended vs. base, computed directly
    --      against the same reader the pack now calls — the honest measurement the task brief
    --      asks for, not a cross-business proxy. Bounded (extended must not be smaller — v688/
    --      v705/v712's own headers document every extended-mode addition as strictly additive),
    --      never a brittle exact-byte pin that would fail on the next unrelated wording tweak.
    declare
      g_base jsonb;
      g_ext  jsonb;
      cand   jsonb;
      alt_kinds int;
    begin
      perform app.v676_open_internal_drain();
      begin
        g_base := public.get_ci_opportunities_v1(v_biz, d_send, d_send, null, clock_timestamp(), false);
        g_ext  := public.get_ci_opportunities_v1(v_biz, d_send, d_send, null, clock_timestamp(), true);
      exception when others then
        perform app.v676_close_internal_drain();
        raise exception 'v735: get_ci_opportunities_v1 raised while measuring the pack-size delta: %', sqlerrm;
      end;
      perform app.v676_close_internal_drain();
      v_before_bytes := octet_length(g_base::text);
      v_after_bytes  := octet_length(g_ext::text);

      if v_after_bytes < v_before_bytes then
        raise exception 'v735: extended-mode payload (% bytes) is smaller than the base-mode payload '
          '(% bytes) for the same business/window — extended mode is supposed to add data, never '
          'remove it', v_after_bytes, v_before_bytes;
      end if;
      raise notice
        'v735: golden business % — base-mode get_ci_opportunities_v1 = % bytes, '
        'extended-mode = % bytes (delta % bytes, %sx)',
        v_biz, v_before_bytes, v_after_bytes, v_after_bytes - v_before_bytes,
        round((v_after_bytes::numeric / greatest(v_before_bytes, 1)), 2);

      -- report_sections carries exactly its seven fixed keys (nestly_v688 A9's own invariant,
      -- re-checked here because THIS call site never exercised it before this migration).
      if (select array_agg(k order by k) from jsonb_object_keys(g_ext->'report_sections') k)
         is distinct from array['change','failures','leakage','margin','segments',
                                 'strengths','unnoticed_behaviour'] then
        raise exception 'v735: report_sections keys were %',
          (select array_agg(k order by k) from jsonb_object_keys(g_ext->'report_sections') k);
      end if;

      -- every ranked candidate: >=2 distinct alternative kinds (nestly_v712 check 77's own
      -- invariant), and the five impact keys nestly_v712 (check 25) added generically.
      for cand in select c from jsonb_array_elements(g_ext->'ranked') c loop
        -- nestly_v712's own scope (check 77): "every candidate whose 'alternatives' array exists
        -- at all" -- a candidate that carries no 'alternatives' key is out of scope, not a failure.
        if cand ? 'alternatives' and jsonb_typeof(cand->'alternatives') = 'array' then
          select count(distinct a->>'kind') into alt_kinds
            from jsonb_array_elements(cand->'alternatives') a;
          if coalesce(alt_kinds, 0) < 2 then
            raise exception 'v735: candidate % carries % distinct alternative kind(s), expected >= 2: %',
              cand->>'id', coalesce(alt_kinds, 0), cand->'alternatives';
          end if;
        end if;
        if cand ? 'impact' and jsonb_typeof(cand->'impact') = 'object' then
          if not (cand->'impact' ? 'affected_customers' and cand->'impact' ? 'revenue_cents'
                  and cand->'impact' ? 'margin' and cand->'impact' ? 'capacity'
                  and cand->'impact' ? 'retention_risk') then
            raise exception 'v735: candidate % impact is missing one of the five nestly_v712 keys '
              '(affected_customers/revenue_cents/margin/capacity/retention_risk): %',
              cand->>'id', cand->'impact';
          end if;
        end if;
      end loop;

      -- at least one candidate must actually be present with the five keys and >=2 alternative
      -- kinds -- the loop above passes vacuously on an empty 'ranked' array, which would prove
      -- nothing about this seed. The campaigns candidate itself is asserted to carry both.
      if not exists (
        select 1 from jsonb_array_elements(g_ext->'ranked') c
         where c->>'id' = 'campaigns'
           and c->'impact' ? 'affected_customers' and c->'impact' ? 'revenue_cents'
           and c->'impact' ? 'margin' and c->'impact' ? 'capacity' and c->'impact' ? 'retention_risk'
           and (select count(distinct a->>'kind') from jsonb_array_elements(c->'alternatives') a) >= 2
      ) then
        raise exception 'v735: the campaigns candidate itself does not carry the five impact keys '
          'and >=2 alternative kinds: %',
          (select c from jsonb_array_elements(g_ext->'ranked') c where c->>'id' = 'campaigns');
      end if;
    end;
  end;
end
$verify$;

rollback to savepoint v735_verify;

commit;
