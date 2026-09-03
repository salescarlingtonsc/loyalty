-- EXECUTED acceptance fixture for db/migrations/20260920_nestly_v735_evidence_pack_extended.sql:
-- the AI firm-report evidence pack's ci_opportunities section now runs public.get_ci_
-- opportunities_v1 with p_extended=>true, so the consultant spine's extended-only content
-- (campaigns, report_sections, top_actions, alternatives diversity, the five impact keys) reaches
-- `app.v176_evidence_pack`'s `findings` key — proving what db/tests/executed/v733_corpus_best_
-- customers_campaign.sql's PART E proved was MISSING is now present, without re-litigating v733's
-- own causal-language assertions (still owned there).
--
-- ===========================================================================================
-- SEED — identical in shape to v733's (R/M/O, 20 customers, one business): re-used rather than
-- re-invented so this fixture's "extended content now flows through the pack" claim is proven on
-- the SAME business shape v733 already proved "extended content is genuinely absent from the base-
-- pass call" on. A different seed here would leave a reader wondering whether the fix was proven
-- against the actual regression, or against a shape hand-picked to make it easy.
--   R-group (r1..r5, "best customers"): 6 prior visits at d_send-60..-10, $100 each, receive the
--     campaign at d_send, one more $100 visit at d_send+10 (same cadence, campaign or not).
--   M-group (m1..m5, "matched non-recipients"): identical prior period and post-send visit, no
--     campaign — the counterfactual v733 already established.
--   O-group (o1..o10, "everyone else"): 2 visits at d_send-90/-30, $50 each — strictly lower
--     spend/cadence, so R/M are unambiguously the top tier (same precondition v733 checks).
--   d_send = current_date - 45 (30-day associated_purchase window fully matured).
--
-- ===========================================================================================
-- WHAT THIS FIXTURE ADDS beyond v733 (which owns the causal-language assertions and is untouched):
--   G1 — through app.v176_evidence_pack (sessionless, internal drain open — the real production
--        call shape): findings.ranked contains id='campaigns', evidence_class='ASSOCIATION', and
--        findings.top_actions is non-empty. This is the exact claim v733's PART E proved false on
--        this tree before nestly_v735; it must now be true.
--   G2 — through public.get_ci_opportunities_v1 called directly with p_extended=>true (as an
--        authenticated super admin, the same access path v733's PART C uses): report_sections
--        carries exactly its seven fixed keys (nestly_v688's own A9 invariant, exercised here
--        because this is the first fixture to check it against THIS seed); every ranked candidate
--        that carries an 'alternatives' array carries >=2 distinct kinds (nestly_v712 check 77);
--        every ranked candidate that carries an 'impact' object carries all five nestly_v712
--        (check 25) keys (affected_customers, revenue_cents, margin, capacity, retention_risk);
--        the campaigns candidate specifically is checked against BOTH invariants together, so an
--        empty 'ranked' array cannot pass this fixture vacuously.
--   G3 — ISOLATION, v713's own shape re-proven at the new call arity: stubbing public.get_
--        ci_opportunities_v1 (now 6-arg-called) to raise loses ONLY the ci_opportunities section
--        — every other v176_evidence_pack section (sales/insights/account_opens/consultant_brief)
--        is untouched, and findings.ranked collapses to '[]' rather than the call failing whole.
--
-- MUTATION-CHECKED (2026-09-02, this session, --filter=v735_corpus --migrated-only): G1's expected
-- evidence_class was temporarily changed from 'ASSOCIATION' to 'DIRECT_FACT' with the seed and
-- migration untouched. Captured failure:
--   ERROR:  v735: campaigns candidate in findings.ranked is not evidence_class=DIRECT_FACT:
--     ... (the real object, evidence_class=ASSOCIATION)
-- Reverting the literal back to 'ASSOCIATION' restored PASS. (See the migration's own inline
-- assertion strings for the mechanism; this fixture's G1 block exercises the identical claim
-- end-to-end through the pack, independent of the migration file's own verification block, which
-- runs and rolls back at APPLY time — this file re-proves it any time the suite runs.)
--
-- One transaction, rolled back. No production access.

\set ON_ERROR_STOP on

begin;

create temp table _fail(k text, v text) on commit drop;

do $v735$
declare
  biz  uuid := '00000000-0000-4000-8000-000000735001';
  br   uuid := '00000000-0000-4000-8000-000000735011';
  u_sa uuid := '00000000-0000-4000-8000-000000735002';
  d_send date := current_date - 45;

  v_min_top_spend  bigint;
  v_max_other_spend bigint;

  v_pack   jsonb;
  g_ext    jsonb;
  cand     jsonb;
  alt_kinds int;
  v_sections text[];
begin
  insert into auth.users (id, email) values (u_sa, 'zz-v735-sa@example.test')
    on conflict (id) do nothing;
  insert into public.super_admins (user_id, email) values (u_sa, 'zz-v735-sa@example.test')
    on conflict do nothing;
  perform set_config('request.jwt.claims', json_build_object(
      'sub', u_sa, 'role','authenticated',
      'amr', json_build_array(json_build_object('method','oauth')),
      'app_metadata', json_build_object('providers', json_build_array('google'))
    )::text, true);

  insert into public.businesses (id, name, slug, enabled_modules) values
    (biz, 'ZZ v735 evidence pack extended', 'zz-v735-evidence-pack',
     array['dashboard','clients','sales','reports']);
  insert into public.branches (id, business_id, name, is_default, active)
    values (br, biz, 'ZZ v735 branch', true, true);

  ---------------------------------------------------------------------------
  -- 20 clients: r1-5 (best, receive the campaign), m1-5 (matched, no campaign),
  -- o1-10 (everyone else) -- identical shape to v733.
  ---------------------------------------------------------------------------
  create temp table zz_v735_clients (role text, idx int, cid uuid) on commit drop;
  insert into zz_v735_clients (role, idx, cid)
    select 'r', gs, gen_random_uuid() from generate_series(1,5) gs
    union all select 'm', gs, gen_random_uuid() from generate_series(1,5) gs
    union all select 'o', gs, gen_random_uuid() from generate_series(1,10) gs;

  insert into public.clients (id, business_id, full_name)
    select cid, biz, 'ZZ v735 ' || role || idx from zz_v735_clients;

  insert into public.sales (business_id, branch_id, client_id, kind, amount_cents, occurred_at,
    counts_as_revenue, counts_as_visit, earns_points, policy_resolved_at,
    commission_rate_bps, commission_resolved_at)
  select biz, br, c.cid, 'service', 10000,
         (d_send + off)::timestamp + time '10:00', true, true, true,
         (d_send + off)::timestamp + time '10:00', 0, (d_send + off)::timestamp + time '10:00'
    from zz_v735_clients c
    cross join unnest(array[-60,-50,-40,-30,-20,-10]) as off
   where c.role in ('r','m');

  insert into public.sales (business_id, branch_id, client_id, kind, amount_cents, occurred_at,
    counts_as_revenue, counts_as_visit, earns_points, policy_resolved_at,
    commission_rate_bps, commission_resolved_at)
  select biz, br, c.cid, 'service', 5000,
         (d_send + off)::timestamp + time '10:00', true, true, true,
         (d_send + off)::timestamp + time '10:00', 0, (d_send + off)::timestamp + time '10:00'
    from zz_v735_clients c
    cross join unnest(array[-90,-30]) as off
   where c.role = 'o';

  insert into public.campaign_send_records_v255
    (business_id, campaign_kind, campaign_ref_id, send_kind, campaign_label, channel,
     client_id, occurred_at, retention_until)
  select biz, 'promotion', gen_random_uuid(), 'blast', 'ZZ v735 best-customers campaign', 'none',
         c.cid, d_send::timestamp + time '11:00',
         d_send::timestamp + time '11:00' + interval '400 days'
    from zz_v735_clients c where c.role = 'r';

  insert into public.sales (business_id, branch_id, client_id, kind, amount_cents, occurred_at,
    counts_as_revenue, counts_as_visit, earns_points, policy_resolved_at,
    commission_rate_bps, commission_resolved_at)
  select biz, br, c.cid, 'service', 10000,
         (d_send + 10)::timestamp + time '10:00', true, true, true,
         (d_send + 10)::timestamp + time '10:00', 0, (d_send + 10)::timestamp + time '10:00'
    from zz_v735_clients c where c.role in ('r','m');

  ---------------------------------------------------------------------------
  -- PRECONDITION, identical to v733: R/M are genuinely the top tier over O.
  ---------------------------------------------------------------------------
  select min(spend) into v_min_top_spend from (
    select c.cid, sum(s.amount_cents) as spend
      from zz_v735_clients c join public.sales s
        on s.client_id = c.cid and s.business_id = biz and s.occurred_at < (d_send::timestamp)
     where c.role in ('r','m') group by c.cid) t;
  select max(spend) into v_max_other_spend from (
    select c.cid, sum(s.amount_cents) as spend
      from zz_v735_clients c join public.sales s
        on s.client_id = c.cid and s.business_id = biz and s.occurred_at < (d_send::timestamp)
     where c.role = 'o' group by c.cid) t;

  if v_min_top_spend is null or v_max_other_spend is null or v_min_top_spend <= v_max_other_spend then
    insert into _fail values ('PRE-ranking', format(
      'R/M prior spend floor = %s must exceed O prior spend ceiling = %s', v_min_top_spend, v_max_other_spend));
    return;
  end if;

  ---------------------------------------------------------------------------
  -- G1 -- through app.v176_evidence_pack, sessionless (internal drain), the real production
  --       call shape. The exact claim v733's PART E proved false pre-nestly_v735.
  ---------------------------------------------------------------------------
  perform app.v676_open_internal_drain();
  begin
    v_pack := app.v176_evidence_pack(biz, 'monthly', d_send, d_send);
  exception when others then
    perform app.v676_close_internal_drain();
    insert into _fail values ('G1-pack-call', format('app.v176_evidence_pack raised %s', sqlerrm));
    return;
  end;
  perform app.v676_close_internal_drain();

  if not exists (select 1 from jsonb_array_elements(v_pack->'findings'->'ranked') c
                  where c->>'id' = 'campaigns') then
    insert into _fail values ('G1-missing', format(
      'campaigns candidate absent from findings.ranked: %s', v_pack->'findings'->'ranked'));
  end if;
  if exists (select 1 from jsonb_array_elements(v_pack->'findings'->'ranked') c
              where c->>'id' = 'campaigns' and c->>'evidence_class' is distinct from 'ASSOCIATION') then
    insert into _fail values ('G1-class', format(
      'campaigns candidate in findings.ranked is not evidence_class=ASSOCIATION: %s',
      (select c from jsonb_array_elements(v_pack->'findings'->'ranked') c where c->>'id' = 'campaigns')));
  end if;
  if jsonb_typeof(v_pack->'findings'->'top_actions') is distinct from 'array'
     or jsonb_array_length(v_pack->'findings'->'top_actions') = 0 then
    insert into _fail values ('G1-top-actions', format(
      'findings.top_actions is empty: %s', v_pack->'findings'->'top_actions'));
  end if;

  ---------------------------------------------------------------------------
  -- G2 -- direct extended call (as an authenticated super admin, v733's own access path):
  --       report_sections' seven keys, alternatives diversity, the five impact keys.
  ---------------------------------------------------------------------------
  g_ext := public.get_ci_opportunities_v1(biz, d_send, d_send, null, clock_timestamp(), true);

  select array_agg(k order by k) into v_sections from jsonb_object_keys(g_ext->'report_sections') k;
  if v_sections is distinct from array['change','failures','leakage','margin','segments',
                                        'strengths','unnoticed_behaviour'] then
    insert into _fail values ('G2-sections', format('report_sections keys were %s', v_sections));
  end if;

  for cand in select c from jsonb_array_elements(g_ext->'ranked') c loop
    if cand ? 'alternatives' and jsonb_typeof(cand->'alternatives') = 'array' then
      select count(distinct a->>'kind') into alt_kinds
        from jsonb_array_elements(cand->'alternatives') a;
      if coalesce(alt_kinds, 0) < 2 then
        insert into _fail values ('G2-alt-kinds', format(
          'candidate %s carries %s distinct alternative kind(s), expected >= 2: %s',
          cand->>'id', coalesce(alt_kinds, 0), cand->'alternatives'));
      end if;
    end if;
    if cand ? 'impact' and jsonb_typeof(cand->'impact') = 'object' then
      if not (cand->'impact' ? 'affected_customers' and cand->'impact' ? 'revenue_cents'
              and cand->'impact' ? 'margin' and cand->'impact' ? 'capacity'
              and cand->'impact' ? 'retention_risk') then
        insert into _fail values ('G2-impact-keys', format(
          'candidate %s impact is missing one of the five keys: %s', cand->>'id', cand->'impact'));
      end if;
    end if;
  end loop;

  if not exists (
    select 1 from jsonb_array_elements(g_ext->'ranked') c
     where c->>'id' = 'campaigns'
       and c->'impact' ? 'affected_customers' and c->'impact' ? 'revenue_cents'
       and c->'impact' ? 'margin' and c->'impact' ? 'capacity' and c->'impact' ? 'retention_risk'
       and (select count(distinct a->>'kind') from jsonb_array_elements(c->'alternatives') a) >= 2
  ) then
    insert into _fail values ('G2-campaigns-shape', format(
      'campaigns candidate does not carry the five impact keys and >=2 alternative kinds: %s',
      (select c from jsonb_array_elements(g_ext->'ranked') c where c->>'id' = 'campaigns')));
  end if;

  ---------------------------------------------------------------------------
  -- G3 -- ISOLATION (v713's own shape): stubbing get_ci_opportunities_v1 loses only its section.
  ---------------------------------------------------------------------------
  create or replace function public.get_ci_opportunities_v1(
    p_business uuid, p_from date, p_to date, p_branch uuid default null,
    p_as_of timestamptz default clock_timestamp(), p_extended boolean default false)
  returns jsonb language plpgsql as $stub$
  begin
    raise exception 'v735 fixture stub failure';
  end
  $stub$;

  perform app.v676_open_internal_drain();
  begin
    v_pack := app.v176_evidence_pack(biz, 'monthly', d_send, d_send);
  exception when others then
    perform app.v676_close_internal_drain();
    insert into _fail values ('G3-pack-call', format('app.v176_evidence_pack raised %s', sqlerrm));
    return;
  end;
  perform app.v676_close_internal_drain();

  if not exists (select 1 from jsonb_array_elements(v_pack->'evidence_completeness'->'unavailable_sections') u
                  where u->>'section' = 'ci_opportunities' and coalesce(u->>'sqlstate','') <> '') then
    insert into _fail values ('G3-isolation', format(
      'stubbing get_ci_opportunities_v1 did not name ci_opportunities with a sqlstate: %s',
      v_pack->'evidence_completeness'->'unavailable_sections'));
  end if;
  if jsonb_typeof(v_pack->'findings'->'ranked') is distinct from 'array'
     or jsonb_array_length(v_pack->'findings'->'ranked') <> 0 then
    insert into _fail values ('G3-collapse', format(
      'findings.ranked should collapse to [] when the section fails: %s', v_pack->'findings'->'ranked'));
  end if;
  if v_pack->'sales' is null or v_pack->'insights' is null or v_pack->'account_opens' is null then
    insert into _fail values ('G3-other-sections-lost', format(
      'sections beside ci_opportunities were lost when only it was stubbed to fail: %s', v_pack));
  end if;
end;
$v735$;

select case when count(*)=0
       then 'PASS — the AI firm-report evidence pack runs the consultant spine in extended mode, '
            'end to end'
       else 'FAIL' end as verdict,
       count(*) as failures from _fail;
select k, v from _fail order by k, v;

do $verdict$
declare n integer; d text;
begin
  select count(*), string_agg(format('%s: %s', f.k, f.v), E'\n  ' order by f.k, f.v)
    into n, d from _fail f;
  if n > 0 then raise exception 'v735: % assertion(s) failed:%  %', n, E'\n', d; end if;
end
$verdict$;

rollback;
