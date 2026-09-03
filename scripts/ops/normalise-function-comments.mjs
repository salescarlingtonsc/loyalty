// gen-normalise.mjs — 2026-09-03. Production stored many function bodies WITHOUT comments (the
// older MCP apply path stripped them) while the rehearsal cluster stores them WITH comments. The
// CI wave's remaining migrations (v689 onward) anchor on, and round-trip against, the rehearsed
// text, so they refuse to run in production (fail-closed, as designed).
//
// This generator boots the same scratch cluster the harness uses, applies the chain EXACTLY up to
// the point production is at now (main's v672–v688 + v668/v669 + the CI wave's first thirteen,
// deploy version <= 20260920120000), extracts pg_get_functiondef for every function the
// remaining migrations touch, and writes normalise.sql: one guarded block per function that
//   * does nothing if production already holds the rehearsed text (whitespace-insensitive),
//   * re-emits the rehearsed text if production holds the same CODE with comments stripped,
//   * RAISES (stopping the whole file, nothing applied) on any other difference — real drift.
// Re-emitting a function with its own comments changes no behaviour and no ACL.
import path from 'node:path';
import { writeFileSync, rmSync } from 'node:fs';

const REPO = '/Users/cs/Downloads/loyalty-worktrees/wt-ci-proof';
const UPTO = process.env.NRM_UPTO || '20260920120000';
const OUT = '/private/tmp/claude-501/-Users-cs-Downloads-loyalty-main/b2eb2901-2f29-4ab9-8d07-185769b6d407/scratchpad/normalise.sql';
const TARGETS = `app.ci_access_gate_v667 app.ci_bucket_tz_v698 app.ci_capacity_v705 app.ci_customer_classes_v1 app.ci_envelope_v680 app.ci_exclusion_counts_v680 app.ci_floor_registry_v690 app.ci_loyalty_eligible_v683 app.ci_loyalty_outcomes_v683 app.ci_margin_guard_v705 app.ci_materiality_threshold_bps_v705 app.ci_metric_dictionary_v1 app.ci_period_validate_v726 app.ci_standard_incentive_cents_v718 app.ci_synthetic_scan_mixed_v744 app.ci_synthetic_scan_v743 app.ci_verdict_class_v696 app.ci_visit_day_v699 app.ci_visit_registry_v699 app.customer_cadence_batch_v1 app.customer_cadence_v1 app.discovery_dim_label_v691 app.get_growth_execution_result_at_v108 app.issue_bringback_for_business_v361 app.rate_block_floor_gated_v683 app.sales_operator_default_v683 app.segment_cadence_v695 app.service_cadence_v695 app.tier_resolve_v426 app.v109_sector_source_availability app.v176_evidence_pack app.v176_gated_evidence app.v176_sales_window app.v177_appointments app.v177_customers app.v177_overview app.v177_sales_window app.v179_business_insights app.v666_till_customer_card app.v695_sector_cadence_multiplier public.business_programme_usage_v386 public.customer_get_business_presentation_v95 public.get_attention_list_v548 public.get_campaign_results public.get_checkout_discount_report public.get_ci_acquisition_v1 public.get_ci_category_customers_v1 public.get_ci_category_mix_v1 public.get_ci_contactability_v1 public.get_ci_customer_records_v1 public.get_ci_daypart_v1 public.get_ci_demographic_cohort_v1 public.get_ci_demographic_preference_v1 public.get_ci_demographics_v1 public.get_ci_discount_dependency_v1 public.get_ci_discovery_v1 public.get_ci_engagement_v1 public.get_ci_funnel_conversion_v1 public.get_ci_funnel_v1 public.get_ci_loyalty_programmes_v1 public.get_ci_marketing_funnel_v1 public.get_ci_opportunities_v1 public.get_ci_rebooking_v1 public.get_ci_retention_windows_v1 public.get_ci_service_intelligence_v1 public.get_ci_shadow_reconciliation_v685 public.get_ci_staff_identity_v1 public.get_ci_staff_performance_v1 public.get_customer_identity_coverage_v111 public.get_customer_intelligence_v83 public.get_customer_lifecycle_v107 public.get_dashboard_summary public.get_dashboard_summary_v154 public.get_dashboard_summary_v155 public.get_legacy_value_inventory public.get_period_economics_v109 public.get_recovery_report_v550 public.get_reports_summary public.get_reports_summary_v94_base public.get_revenue_driver_decomposition_v109 public.get_revenue_summary public.get_studio_sales_baseline_v145 public.internal_claim_ai_firm_report_v176 public.lookup_client_by_phone public.platform_customer_account_opens_v175 public.platform_engagement_monthly_v255 public.platform_generate_improvement_report_v82 public.platform_generate_my_report_v89 public.platform_get_assigned_firm_report_v94 public.platform_get_catalogue_affinity_v94 public.platform_get_enterprise_hierarchy_v82 public.platform_list_enterprise_customers_v82 public.preview_campaign_audience_v155 public.refresh_growth_recommendation_v108 public.retention_lapsed_candidates_v244 public.set_actual_provider_v683 public.staff_customer_bucket_counts_v290 public.staff_list_customers_v129 public.staff_list_customers_v154 public.staff_list_customers_v155 public.staff_list_package_entitlements_v102 public.staff_list_returned_customers_v300 public.super_admin_list_businesses`.split(/\s+/);

// SQL-aware comment stripper: keeps string / dollar-quoted literals intact, drops -- and /* */.
function stripComments(sql) {
  let out = '', i = 0;
  const n = sql.length;
  while (i < n) {
    const c = sql[i], d = sql[i + 1];
    if (c === "'") { let j = i + 1; while (j < n) { if (sql[j] === "'") { if (sql[j + 1] === "'") { j += 2; continue; } break; } j++; } out += sql.slice(i, j + 1); i = j + 1; continue; }
    if (c === '$') { const m = /^\$[A-Za-z_][A-Za-z0-9_]*\$|^\$\$/.exec(sql.slice(i)); if (m) { const tag = m[0]; const end = sql.indexOf(tag, i + tag.length); if (end >= 0) { out += sql.slice(i, end + tag.length); i = end + tag.length; continue; } } }
    if (c === '-' && d === '-') { const e = sql.indexOf('\n', i); i = e < 0 ? n : e; continue; }
    if (c === '/' && d === '*') { let depth = 1, j = i + 2; while (j < n && depth) { if (sql[j] === '/' && sql[j + 1] === '*') { depth++; j += 2; } else if (sql[j] === '*' && sql[j + 1] === '/') { depth--; j += 2; } else j++; } i = j; continue; }
    out += c; i++;
  }
  return out;
}
// pg_get_functiondef wraps the body in $function$ … $function$; comments live INSIDE that wrapper,
// so strip the header and the body separately (nested dollar quotes / strings stay intact).
function stripDef(def) {
  const open = def.indexOf('AS $function$');
  const close = def.lastIndexOf('$function$');
  if (open < 0 || close <= open) return stripComments(def);
  const head = def.slice(0, open + 'AS $function$'.length);
  const body = def.slice(open + 'AS $function$'.length, close);
  return stripComments(head) + stripComments(body) + def.slice(close);
}
const nows = (s) => s.replace(/\s+/g, '');

const lib = await import(path.join(REPO, 'scripts/db-tests/lib.mjs'));
const { ScratchCluster, applyBootstrap, discoverPendingMigrations, requirePostgresBinaries, isolatedWorkdir, pickFreePort, SNAPSHOT_PATH, BASELINE_GRANTS_PATH } = lib;
requirePostgresBinaries();
const { dir: workDir, ephemeral } = isolatedWorkdir('peekaa-normalise');
const port = await pickFreePort();
const cluster = new ScratchCluster({ dataDir: path.join(workDir, 'data'), port, logFile: path.join(workDir, 'server.log') });
const DB = 'peekaa_prewave';
cluster.init({ fresh: true }); cluster.start();
let applied = 0, blocks = [], skippedMissing = [];
try {
  cluster.createDatabase(DB);
  await applyBootstrap(cluster, DB);
  await cluster.psqlFile(DB, SNAPSHOT_PATH);
  await cluster.psqlFile(DB, BASELINE_GRANTS_PATH);
  for (const m of discoverPendingMigrations()) {
    if (m.deployVersion && m.deployVersion > UPTO) break;
    await cluster.psqlFile(DB, m.path); applied++;
  }
  for (const fq of TARGETS) {
    const [schema, name] = fq.split('.');
    // One round trip per function: "<regprocedure signature>\x1f<definition>" per overload, joined by \x1e.
    const defs = cluster.scalar(DB, `select coalesce(string_agg(p.oid::regprocedure::text || chr(31) || pg_get_functiondef(p.oid), chr(30)), '') from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = '${schema}' and p.proname = '${name}'`);
    if (!defs) { skippedMissing.push(fq); continue; }
    for (const rec of defs.split('\x1e')) {
      const cut = rec.indexOf('\x1f');
      const argsig = rec.slice(0, cut).trim();
      const def = rec.slice(cut + 1);
      if (!argsig || !def.startsWith('CREATE OR REPLACE FUNCTION')) throw new Error(`could not split signature/body for ${fq}`);
      const full = nows(def), stripped = nows(stripDef(def));
      const tag = `$nrm${blocks.length}$`;
      blocks.push(`-- ${argsig}
do $blk$
declare v_prod text; v_full text := ${tag}${full}${tag}; v_stripped text := ${tag}${stripped}${tag}; v_p text; v_ps text;
begin
  select pg_get_functiondef(to_regprocedure(${tag}${argsig}${tag})) into v_prod;
  if v_prod is null then raise exception 'normalise: % is missing in production', ${tag}${argsig}${tag}; end if;
  v_p := regexp_replace(v_prod, '\\s+', '', 'g');
  v_ps := regexp_replace(pg_temp.nrm_strip_def(v_prod), '\\s+', '', 'g');
  if v_prod = ${tag}${def}${tag} then
    raise notice 'normalise: % already carries the rehearsed text', ${tag}${argsig}${tag};
  elsif v_ps = v_stripped then
    execute ${tag}${def}${tag};
    raise notice 'normalise: % re-emitted with its comments (code unchanged)', ${tag}${argsig}${tag};
  else
    raise exception 'normalise: % differs from the rehearsed body by more than comments -- real drift, stop', ${tag}${argsig}${tag};
  end if;
end $blk$;
`);
    }
  }
} finally {
  cluster.stop();
  if (ephemeral) rmSync(workDir, { recursive: true, force: true });
}
const header = `-- normalise.sql — generated ${new Date().toISOString()} from the rehearsal chain applied up to deploy ${UPTO} (${applied} migrations).
-- One transaction. Every block is guarded: it re-emits a function ONLY when production holds the same code
-- once BOTH sides are comment-stripped; any other difference raises and nothing is applied. See gen-normalise.mjs.
begin;

-- SQL-side comment stripper (same tokenizer as the generator's JS one): keeps '...' and $tag$...$tag$
-- literals intact, drops -- to end of line and /* ... */ (nested). Session-temporary.
create function pg_temp.nrm_strip(p text) returns text language plpgsql immutable as $strip$
declare
  i int := 1; n int := length(p); c text; d text; j int; tag text; e int; depth int; outv text := '';
  nxt int; parts text[] := '{}';
begin
  while i <= n loop
    -- jump to the next character that can start a literal or a comment; copy the run before it
    nxt := position('''' in substr(p, i));
    e := position('$' in substr(p, i)); if e > 0 and (nxt = 0 or e < nxt) then nxt := e; end if;
    e := position('--' in substr(p, i)); if e > 0 and (nxt = 0 or e < nxt) then nxt := e; end if;
    e := position('/*' in substr(p, i)); if e > 0 and (nxt = 0 or e < nxt) then nxt := e; end if;
    if nxt = 0 then parts := parts || substr(p, i); exit; end if;
    if nxt > 1 then parts := parts || substr(p, i, nxt - 1); i := i + nxt - 1; end if;
    c := substr(p, i, 1); d := substr(p, i + 1, 1);
    if c = '''' then
      j := i + 1;
      while j <= n loop
        if substr(p, j, 1) = '''' then
          if substr(p, j + 1, 1) = '''' then j := j + 2; continue; end if;
          exit;
        end if;
        j := j + 1;
      end loop;
      parts := parts || substr(p, i, j - i + 1); i := j + 1; continue;
    elsif c = '$' then
      tag := substring(substr(p, i) from '^\$[A-Za-z_][A-Za-z0-9_]*\$');
      if tag is null and d = '$' then tag := '$$'; end if;
      if tag is not null then
        e := position(tag in substr(p, i + length(tag)));
        if e > 0 then
          e := i + length(tag) + e - 1;   -- absolute position of the closing tag
          parts := parts || substr(p, i, e + length(tag) - i); i := e + length(tag); continue;
        end if;
      end if;
    elsif c = '-' and d = '-' then
      e := position(E'\n' in substr(p, i));
      if e = 0 then i := n + 1; else i := i + e - 1; end if;
      continue;
    elsif c = '/' and d = '*' then
      depth := 1; j := i + 2;
      while j <= n and depth > 0 loop
        if substr(p, j, 2) = '/*' then depth := depth + 1; j := j + 2;
        elsif substr(p, j, 2) = '*/' then depth := depth - 1; j := j + 2;
        else j := j + 1; end if;
      end loop;
      i := j; continue;
    end if;
    parts := parts || c; i := i + 1;
  end loop;
  return array_to_string(parts, '');
end $strip$;

-- pg_get_functiondef wraps the body in $function$; strip the header and the body separately.
create function pg_temp.nrm_strip_def(p text) returns text language plpgsql immutable as $sd$
declare o int; c int; h text; b text;
begin
  o := position('AS $function$' in p);
  c := length(p) - position(reverse('$function$') in reverse(p)) - length('$function$') + 2;   -- last occurrence, 1-based
  if o = 0 or c <= o then return pg_temp.nrm_strip(p); end if;
  h := substr(p, 1, o + length('AS $function$') - 1);
  b := substr(p, o + length('AS $function$'), c - (o + length('AS $function$')));
  return pg_temp.nrm_strip(h) || pg_temp.nrm_strip(b) || substr(p, c);
end $sd$;
`;
writeFileSync(OUT, header + blocks.join('\n') + '\ncommit;\n');
console.log(`applied ${applied} migrations; ${blocks.length} guarded blocks written to ${OUT}; not present pre-wave (skipped): ${skippedMissing.length}`);
console.log(skippedMissing.join(' '));
