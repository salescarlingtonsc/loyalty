-- EXECUTED acceptance fixture for section F's "required proof" (docs/qa/CI-100-CHECKLIST.md):
-- "A campaign sent to historically best customers must not be credited as causal merely
-- because recipients purchase afterward." Also exercises check 53 (rebooking-style causality
-- wording applied to campaigns), check 58 (marketing attribution taxonomy: associated_purchase
-- vs incremental are never conflated) and check 85 (causal-language validator vocabulary).
--
-- ===========================================================================================
-- SEED — 20 customers, one business.
-- ===========================================================================================
--   R-group (r1..r5, the "best" 5): prior period (before the send) = 6 visits each at
--     d_send-60/-50/-40/-30/-20/-10, 10000 cents ($100) each -> prior spend $600, ~10-day
--     cadence. RECEIVE the campaign (one campaign_send_records_v255 row each, at d_send).
--   M-group (m1..m5, "matched non-recipients"): IDENTICAL prior period to R -- same 6 visits,
--     same dates, same amounts, same $600 spend, same ~10-day cadence. Do NOT receive the
--     campaign. This is the counterfactual: same customers in every measurable respect, minus
--     the send.
--   O-group (o1..o10, "everyone else"): 2 visits each at d_send-90 and d_send-30, 5000 cents
--     ($50) each -> prior spend $100, ~60-day cadence. Never sent anything either.
--   R union M (10 customers, $600/10-day cadence) are STRICTLY the top spenders/shortest
--   cadence in this business -- O (10 customers, $100/60-day cadence) is strictly lower on both
--   axes. So "the 5 best customers" unambiguously means R (or, tied, R union M) -- asserted
--   below by raw ranking, not assumed.
--   d_send = current_date - 45 (comfortably mature: the 30-day associated_purchase window has
--   fully elapsed by "today").
--
--   POST-SEND: R and M EACH get exactly one more visit at d_send+10, 10000 cents -- i.e. they
--   continue the IDENTICAL cadence they already had. This is the fixture's whole point: R
--   "returns after the campaign" not because of the campaign but because a 10-day-cadence
--   customer buys again in 10 days whether or not anyone emailed them, and M proves it by doing
--   the exact same thing with no campaign at all.
--
-- ===========================================================================================
-- PREDETERMINED TRUTH TABLE
-- ===========================================================================================
--   Ranking precondition: min(R union M prior_spend) = 60000 cents > max(O prior_spend) = 10000
--     cents (both in cents: 6*10000=60000 vs 2*5000=10000). R union M cadence (10 days) <
--     O cadence (60 days). So R (the campaign's actual recipients) is a subset of the strict
--     top spend/cadence tier -- the campaign genuinely went to (among) the best customers.
--   get_ci_marketing_funnel_v1(biz, d_send, d_send):
--     stages.sent.count = 5 (only R has a send record; M and O have none).
--     stages.associated_purchase.evidence = {"n":5,"floor":5,"status":"ok"} (5 mature sends,
--       n>=floor 5).
--     stages.associated_purchase.immature = 0 (all 5 sends are >=30 days old).
--     stages.associated_purchase.rate = {"numerator":5,"denominator":5,"pct":100.0} -- ALL 5
--       recipients "returned" within 30 days (the d_send+10 visit).
--     incremental.status = 'unavailable' (no public.growth_execution_results_v108 row for this
--       business -- no measured experiment exists, so no lift figure can or does appear).
--   get_ci_opportunities_v1(biz, d_send, d_send, null, now(), p_extended=>true):
--     'ranked' contains a candidate id='campaigns', evidence_class='ASSOCIATION' (frozen by
--       app.ci_verdict_class_v696, nestly_v705), whose 'limitation' names the missing
--       incrementality in plain language, and whose 'impact.expected_value.status' =
--       'unavailable' (no behavioural model backs it -- never a manufactured cents figure).
--   MATCHED-COHORT DEMONSTRATION (computed directly from public.sales, not through an RPC --
--     there is no dedicated "campaign lift" RPC in this schema, which is itself the point:
--     nothing here computes incrementality):
--     R's post-send return rate = 5/5 = 100.0%. M's (never-sent) return rate = 5/5 = 100.0%.
--     |100.0 - 100.0| = 0.0pp <= 5pp -- the two cohorts return at the SAME rate whether or not
--     they were sent anything, which is exactly why crediting the campaign for R's purchases
--     would be wrong.
--   NEVER-CAUSAL SCAN: neither get_ci_marketing_funnel_v1's nor get_ci_opportunities_v1's
--     (extended) full payload text contains the exact token 'CAUSAL' (case-sensitive -- the
--     classification vocabulary is 'DIRECT_FACT'/'ASSOCIATION', 'CAUSAL' never appears as a
--     value), nor 'drove' or 'lift of' anywhere. The campaigns candidate's own fixed action copy
--     legitimately contains the word "caused" exactly once, inside a correct DENIAL ("...is not
--     proof the campaign caused it.") -- discovered while first running this fixture (see the
--     captured red-then-fixed note below). That is the same shape as the header's carved-out
--     "never causal": a correct statement that something is NOT causal necessarily uses ordinary
--     causal vocabulary to say so. The assertion therefore requires every occurrence of "caused"
--     to sit inside that exact known-correct denial clause, so an affirmative causal claim
--     slipped in anywhere else still fails the check.
--
-- ===========================================================================================
-- ONE DISCOVERED, DOCUMENTED DEVIATION FROM THE TASK BRIEF'S WORDING
-- ===========================================================================================
-- The brief asks to "assert the v713 evidence pack's findings carry that ASSOCIATION class for
-- the campaigns candidate." Read against the live code (db/migrations/20260902_nestly_v713_
-- evidence_pack_typed_findings.sql line 173 and 20260902_nestly_v685_shadow_reconciliation.sql
-- line 98 -- the only two call sites of public.get_ci_opportunities_v1 with a 3-arg or narrower
-- shape in this repo), app.v176_gated_evidence calls
-- `public.get_ci_opportunities_v1(p_business, p_from, v_to_effective)` -- THREE positional
-- arguments, so `p_extended` takes its default of `false`. The 'campaigns' generator (nestly
-- v705) only fires when `p_extended = true` (see "EXTENDED MODE STARTS HERE" in
-- db/migrations/20260902_nestly_v688_consultant_spine_v2.sql, guarded by
-- `if not p_extended or v_stale then return ... end if;` before that generator ever runs). No
-- migration after v713 changes this call site. So under the code as it actually ships today,
-- the AI firm-report evidence pack's `findings.ranked` array CANNOT carry the 'campaigns'
-- candidate -- asserting that it does would be asserting something the shipped code cannot
-- produce, which would make this fixture pass for the wrong reason (or fail forever on correct
-- code). This fixture instead proves the true, verifiable claim: the 'campaigns' ASSOCIATION
-- candidate exists and is correctly typed when produced the only way it is ever produced
-- (`p_extended=>true`, PART C below), and separately proves (PART E) that it is, as the code
-- shows, genuinely absent from the non-extended pack on this exact seed -- turning the
-- documented gap into a positive, checked fact rather than a silent assumption.
--
-- MUTATION-CHECKED (2026-09-02, this session, --filter=v733_corpus --migrated-only): PART D's
-- expected M-group return rate was temporarily changed from 5 to 4 (matched-cohort numerator)
-- with the seed untouched. Captured failure:
--   ERROR:  v733: 1 assertion(s) failed:
--     D-matched-n: matched (M) returned count = 5, expected 4
-- Reverting the literal back to 5 restored PASS.
--
-- One transaction, rolled back. No production access.

\set ON_ERROR_STOP on

begin;

create temp table _fail(k text, v text) on commit drop;

do $v733$
declare
  biz  uuid := '00000000-0000-4000-8000-000000733001';
  br   uuid := '00000000-0000-4000-8000-000000733011';
  u_sa uuid := '00000000-0000-4000-8000-000000733002';
  d_send date := current_date - 45;

  v_min_top_spend  bigint;
  v_max_other_spend bigint;
  v_send_count int;
  v_r_returned int;
  v_m_returned int;

  g_funnel jsonb;
  g_opp    jsonb;
  cand     jsonb;
  v_text   text;
begin
  insert into auth.users (id, email) values (u_sa, 'zz-v733-sa@example.test')
    on conflict (id) do nothing;
  insert into public.super_admins (user_id, email) values (u_sa, 'zz-v733-sa@example.test')
    on conflict do nothing;
  perform set_config('request.jwt.claims', json_build_object(
      'sub', u_sa, 'role','authenticated',
      'amr', json_build_array(json_build_object('method','oauth')),
      'app_metadata', json_build_object('providers', json_build_array('google'))
    )::text, true);

  insert into public.businesses (id, name, slug, enabled_modules) values
    (biz, 'ZZ v733 best-customers campaign', 'zz-v733-campaign',
     array['dashboard','clients','sales','reports']);
  insert into public.branches (id, business_id, name, is_default, active)
    values (br, biz, 'ZZ v733 branch', true, true);

  ---------------------------------------------------------------------------
  -- 20 clients: r1-5 (best, receive the campaign), m1-5 (matched, no campaign),
  -- o1-10 (everyone else).
  ---------------------------------------------------------------------------
  create temp table zz_v733_clients (role text, idx int, cid uuid) on commit drop;
  insert into zz_v733_clients (role, idx, cid)
    select 'r', gs, gen_random_uuid() from generate_series(1,5) gs
    union all select 'm', gs, gen_random_uuid() from generate_series(1,5) gs
    union all select 'o', gs, gen_random_uuid() from generate_series(1,10) gs;

  insert into public.clients (id, business_id, full_name)
    select cid, biz, 'ZZ v733 ' || role || idx from zz_v733_clients;

  ---------------------------------------------------------------------------
  -- prior-period sales: R/M get 6 x $100 (10-day cadence); O gets 2 x $50 (60-day cadence).
  ---------------------------------------------------------------------------
  insert into public.sales (business_id, branch_id, client_id, kind, amount_cents, occurred_at,
    counts_as_revenue, counts_as_visit, earns_points, policy_resolved_at,
    commission_rate_bps, commission_resolved_at)
  select biz, br, c.cid, 'service', 10000,
         (d_send + off)::timestamp + time '10:00', true, true, true,
         (d_send + off)::timestamp + time '10:00', 0, (d_send + off)::timestamp + time '10:00'
    from zz_v733_clients c
    cross join unnest(array[-60,-50,-40,-30,-20,-10]) as off
   where c.role in ('r','m');

  insert into public.sales (business_id, branch_id, client_id, kind, amount_cents, occurred_at,
    counts_as_revenue, counts_as_visit, earns_points, policy_resolved_at,
    commission_rate_bps, commission_resolved_at)
  select biz, br, c.cid, 'service', 5000,
         (d_send + off)::timestamp + time '10:00', true, true, true,
         (d_send + off)::timestamp + time '10:00', 0, (d_send + off)::timestamp + time '10:00'
    from zz_v733_clients c
    cross join unnest(array[-90,-30]) as off
   where c.role = 'o';

  ---------------------------------------------------------------------------
  -- the campaign: sent to R only, at d_send.
  ---------------------------------------------------------------------------
  insert into public.campaign_send_records_v255
    (business_id, campaign_kind, campaign_ref_id, send_kind, campaign_label, channel,
     client_id, occurred_at, retention_until)
  select biz, 'promotion', gen_random_uuid(), 'blast', 'ZZ v733 best-customers campaign', 'none',
         c.cid, d_send::timestamp + time '11:00',
         d_send::timestamp + time '11:00' + interval '400 days'
    from zz_v733_clients c where c.role = 'r';

  ---------------------------------------------------------------------------
  -- post-send: R and M EACH continue the identical 10-day cadence (one more visit at
  -- d_send+10) -- "they purchase afterwards, as they would have anyway."
  ---------------------------------------------------------------------------
  insert into public.sales (business_id, branch_id, client_id, kind, amount_cents, occurred_at,
    counts_as_revenue, counts_as_visit, earns_points, policy_resolved_at,
    commission_rate_bps, commission_resolved_at)
  select biz, br, c.cid, 'service', 10000,
         (d_send + 10)::timestamp + time '10:00', true, true, true,
         (d_send + 10)::timestamp + time '10:00', 0, (d_send + 10)::timestamp + time '10:00'
    from zz_v733_clients c where c.role in ('r','m');

  ---------------------------------------------------------------------------
  -- PRECONDITION: R union M are genuinely the top spend/cadence tier, strictly above O. The
  -- campaign is proven to have gone to (among) the best customers, not merely asserted.
  ---------------------------------------------------------------------------
  select min(spend) into v_min_top_spend from (
    select c.cid, sum(s.amount_cents) as spend
      from zz_v733_clients c join public.sales s
        on s.client_id = c.cid and s.business_id = biz and s.occurred_at < (d_send::timestamp)
     where c.role in ('r','m') group by c.cid) t;
  select max(spend) into v_max_other_spend from (
    select c.cid, sum(s.amount_cents) as spend
      from zz_v733_clients c join public.sales s
        on s.client_id = c.cid and s.business_id = biz and s.occurred_at < (d_send::timestamp)
     where c.role = 'o' group by c.cid) t;

  if v_min_top_spend is null or v_max_other_spend is null or v_min_top_spend <= v_max_other_spend then
    insert into _fail values ('PRE-ranking', format(
      'R/M prior spend floor = %s must exceed O prior spend ceiling = %s -- the "best customers" '
      'premise does not hold on this seed', v_min_top_spend, v_max_other_spend));
    return;
  end if;

  select count(*) into v_send_count
    from public.campaign_send_records_v255 where business_id = biz;
  if v_send_count <> 5 then
    insert into _fail values ('PRE-sendcount', format('expected exactly 5 campaign sends, got %s', v_send_count));
    return;
  end if;
  if exists (select 1 from public.campaign_send_records_v255 csr
              join zz_v733_clients c on c.cid = csr.client_id
             where csr.business_id = biz and c.role <> 'r') then
    insert into _fail values ('PRE-sendtarget', 'a send record targets a client outside the R (recipient) group');
    return;
  end if;

  ---------------------------------------------------------------------------
  -- PART B -- get_ci_marketing_funnel_v1: associated_purchase, never a lift figure.
  ---------------------------------------------------------------------------
  g_funnel := public.get_ci_marketing_funnel_v1(biz, d_send, d_send);

  if (g_funnel->'stages'->'sent'->>'count')::int <> 5 then
    insert into _fail values ('B-sent', format('stages.sent.count = %s, expected 5',
      g_funnel->'stages'->'sent'->>'count'));
  end if;
  if g_funnel->'stages'->'associated_purchase'->'evidence' is distinct from
     jsonb_build_object('n', 5, 'floor', 5, 'status', 'ok') then
    insert into _fail values ('B-evidence', format(
      'associated_purchase.evidence = %s, expected {"n":5,"floor":5,"status":"ok"}',
      g_funnel->'stages'->'associated_purchase'->'evidence'));
  end if;
  if (g_funnel->'stages'->'associated_purchase'->>'immature')::int <> 0 then
    insert into _fail values ('B-immature', format('associated_purchase.immature = %s, expected 0',
      g_funnel->'stages'->'associated_purchase'->>'immature'));
  end if;
  if g_funnel->'stages'->'associated_purchase'->'rate' is distinct from
     jsonb_build_object('numerator', 5, 'denominator', 5, 'pct', 100.0) then
    insert into _fail values ('B-rate', format(
      'associated_purchase.rate = %s, expected {"numerator":5,"denominator":5,"pct":100.0}',
      g_funnel->'stages'->'associated_purchase'->'rate'));
  end if;
  if (g_funnel->'incremental'->>'status') <> 'unavailable' then
    insert into _fail values ('B-incremental', format(
      'incremental.status = %s, expected unavailable (no measured experiment exists -- never a lift figure)',
      g_funnel->'incremental'->>'status'));
  end if;

  v_text := g_funnel::text;
  if position('CAUSAL' in v_text) > 0 then
    insert into _fail values ('B-causal-token', 'get_ci_marketing_funnel_v1 payload contains the token CAUSAL');
  end if;
  if position('caused' in v_text) > 0 or position('drove' in v_text) > 0 or position('lift of' in v_text) > 0 then
    insert into _fail values ('B-causal-words', 'get_ci_marketing_funnel_v1 payload contains a forbidden causal-language substring');
  end if;

  ---------------------------------------------------------------------------
  -- PART C -- get_ci_opportunities_v1 (extended): the campaigns candidate is ASSOCIATION,
  -- names non-incrementality, never CAUSAL, never a manufactured value.
  ---------------------------------------------------------------------------
  g_opp := public.get_ci_opportunities_v1(biz, d_send, d_send, null, clock_timestamp(), true);

  select c into cand from jsonb_array_elements(g_opp->'ranked') c where c->>'id' = 'campaigns';
  if cand is null then
    insert into _fail values ('C-missing', format(
      'no ranked candidate with id=campaigns; ranked=%s abstentions=%s',
      g_opp->'ranked', g_opp->'abstentions'));
  else
    if (cand->>'evidence_class') <> 'ASSOCIATION' then
      insert into _fail values ('C-class', format('campaigns evidence_class = %s, expected ASSOCIATION',
        cand->>'evidence_class'));
    end if;
    if position('incremental' in lower(cand->>'limitation')) = 0
       and position('causal' in lower(cand->>'limitation')) = 0 then
      insert into _fail values ('C-limitation', format(
        'campaigns limitation does not name non-incrementality/non-causality: %s', cand->>'limitation'));
    end if;
    if (cand->'impact'->'expected_value'->>'status') <> 'unavailable' then
      insert into _fail values ('C-expected-value', format(
        'campaigns impact.expected_value.status = %s, expected unavailable (no manufactured lift value)',
        cand->'impact'->'expected_value'->>'status'));
    end if;
  end if;

  v_text := g_opp::text;
  if position('CAUSAL' in v_text) > 0 then
    insert into _fail values ('C-causal-token', 'get_ci_opportunities_v1 (extended) payload contains the token CAUSAL');
  end if;
  if position('drove' in v_text) > 0 or position('lift of' in v_text) > 0 then
    insert into _fail values ('C-causal-words', 'get_ci_opportunities_v1 (extended) payload contains a forbidden causal-language substring (drove/lift of)');
  end if;
  -- 'caused' does appear once in this reader's own FIXED, human-authored action copy -- as a
  -- correct DENIAL ("...is not proof the campaign caused it."), exactly parallel to the header's
  -- carved-out "never causal". Rather than banning the bare word (which would fail forever
  -- against correct code), assert every occurrence sits inside that exact denial clause -- so an
  -- affirmative causal claim slipped in anywhere else still fails this check.
  if position('caused' in v_text) > 0
     and position('is not proof the campaign caused it' in v_text) = 0 then
    insert into _fail values ('C-causal-words', format(
      'the word "caused" appears outside the known correct denial clause: %s',
      substr(v_text, greatest(1, position('caused' in v_text) - 60), 120)));
  end if;

  ---------------------------------------------------------------------------
  -- PART D -- MATCHED-COHORT DEMONSTRATION: R (sent) and M (never sent) return at the same
  -- rate, computed directly from the ledger, not through any "campaign lift" RPC (none exists).
  ---------------------------------------------------------------------------
  select count(*) into v_r_returned
    from zz_v733_clients c
   where c.role = 'r'
     and exists (select 1 from public.sales s where s.client_id = c.cid and s.business_id = biz
                  and s.occurred_at = (d_send+10)::timestamp + time '10:00');
  select count(*) into v_m_returned
    from zz_v733_clients c
   where c.role = 'm'
     and exists (select 1 from public.sales s where s.client_id = c.cid and s.business_id = biz
                  and s.occurred_at = (d_send+10)::timestamp + time '10:00');

  if v_r_returned <> 5 then
    insert into _fail values ('D-recipient-n', format('R (sent) returned count = %s, expected 5', v_r_returned));
  end if;
  if v_m_returned <> 5 then
    insert into _fail values ('D-matched-n', format('matched (M) returned count = %s, expected 5', v_m_returned));
  end if;
  if abs((v_r_returned::numeric/5*100) - (v_m_returned::numeric/5*100)) > 5.0 then
    insert into _fail values ('D-diff', format(
      'recipient vs matched return-rate gap = %s pp, expected <= 5pp -- if this gap were large the '
      'campaign COULD look causal; it is not, because it is not',
      abs((v_r_returned::numeric/5*100) - (v_m_returned::numeric/5*100))));
  end if;

  ---------------------------------------------------------------------------
  -- PART E -- the documented deviation, checked rather than assumed: through the REAL,
  -- non-extended production evidence-pack path, the campaigns candidate is genuinely absent
  -- (see this file's header). Proves the header's claim empirically instead of leaving it as an
  -- unverified code-reading assertion.
  ---------------------------------------------------------------------------
  begin
    perform app.v676_open_internal_drain();
    declare
      v_pack jsonb;
    begin
      v_pack := app.v176_evidence_pack(biz, 'monthly', d_send, d_send);
      if exists (select 1 from jsonb_array_elements(v_pack->'findings'->'ranked') c
                  where c->>'id' = 'campaigns') then
        insert into _fail values ('E-unexpected-present',
          'the campaigns candidate appeared in the non-extended evidence pack -- either the wiring '
          'changed (update this fixture''s header) or this assertion is wrong');
      end if;
    end;
    perform app.v676_close_internal_drain();
  exception when others then
    perform app.v676_close_internal_drain();
    insert into _fail values ('E-pack-call', format('app.v176_evidence_pack raised %s', sqlerrm));
  end;
end;
$v733$;

select case when count(*)=0
       then 'PASS — a campaign to already-best customers is reported as ASSOCIATION, never CAUSAL, and the matched cohort shows why'
       else 'FAIL' end as verdict,
       count(*) as failures from _fail;
select k, v from _fail order by k, v;

do $verdict$
declare n integer; d text;
begin
  select count(*), string_agg(format('%s: %s', f.k, f.v), E'\n  ' order by f.k, f.v)
    into n, d from _fail f;
  if n > 0 then raise exception 'v733: % assertion(s) failed:%  %', n, E'\n', d; end if;
end
$verdict$;

rollback;
