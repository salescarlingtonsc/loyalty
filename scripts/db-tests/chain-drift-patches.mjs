/**
 * Committed-chain drift patches.
 *
 * WHAT THIS IS: the canonical migration chain under supabase/migrations/ is supposed to be a
 * faithful, replayable record of the production catalog. It is not, in a small number of
 * places: a few files were reconstructed lossily and no longer apply to an empty database,
 * even though the object they create is present and correct in production. Nothing in the
 * repo executed the chain before this harness existed, so the drift was invisible.
 *
 * Each entry below rewrites ONE committed migration on the way into the scratch cluster so
 * the chain replays. Every patch must:
 *   1. name the migration it applies to,
 *   2. quote WHY (the production definition it is being reconciled with), and
 *   3. be an exact string replacement — if `find` is no longer present in the file, the
 *      harness FAILS instead of silently skipping. A patch that stops matching means the
 *      underlying file was fixed (delete the patch) or changed shape (re-derive it).
 *
 * These are replay-only. They never touch the committed migration and are never applied to
 * production. The fix for each is upstream: correct the committed migration so the patch can
 * be deleted. Until then the harness at least proves the rest of the chain is sound.
 */

export const CHAIN_DRIFT_PATCHES = [
  {
    migration: 'supabase/migrations/20260806125000_nestly_v182_birthday_month_and_tier_schedule.sql',
    reason:
      'app.c45_birthday_window(date,int,int,timestamptz,text): the committed file lost the '
      + '`as valid_from` / `as valid_until` aliases on the first UNION ALL branch, so the outer '
      + 'WHERE cannot resolve them and the file fails to apply with 42703. Production carries '
      + 'the aliases (verified 2026-08-22 against gadpooereceldfpfxsod via pg_get_functiondef); '
      + 'this restores exactly what production has.',
    find:
      "    select birthday_year,\n"
      + "      (date_trunc('month', observed_date::timestamp) at time zone 'Asia/Singapore'),\n"
      + "      ((date_trunc('month', observed_date::timestamp) + interval '1 month') at time zone 'Asia/Singapore')\n"
      + "      from candidates where coalesce(p_mode,'days') = 'month'",
    replace:
      "    select birthday_year,\n"
      + "      (date_trunc('month', observed_date::timestamp) at time zone 'Asia/Singapore') as valid_from,\n"
      + "      ((date_trunc('month', observed_date::timestamp) + interval '1 month') at time zone 'Asia/Singapore') as valid_until\n"
      + "      from candidates where coalesce(p_mode,'days') = 'month'",
  },
  {
    migration: 'supabase/migrations/20260807020000_nestly_v194_merge_contact_dedupe.sql',
    reason:
      'v194 patches public.platform_merge_prospects_v184 by exact-substring replacement on '
      + 'pg_get_functiondef, and raises "expected one contact-move block, found 0" when the '
      + 'substring is absent. The block it looks for uses the alias `e` on one line; the '
      + 'committed v185 that creates the function uses the alias `existing` across three '
      + 'lines. One of the two files was edited after the pair was applied to production. '
      + 'This rewrites only the SEARCH literal so it matches what the committed v185 actually '
      + 'produces — the replacement text, and therefore the resulting function, is untouched.',
    find:
      "  v_old := '  update public.sme_prospect_contacts\n"
      + "     set prospect_id=p_target,\n"
      + "         is_primary=case when exists(select 1 from public.sme_prospect_contacts e\n"
      + "           where e.prospect_id=p_target and e.is_primary) then false else is_primary end\n"
      + "   where prospect_id=p_source;",
    replace:
      "  v_old := '  update public.sme_prospect_contacts\n"
      + "     set prospect_id=p_target,\n"
      + "         is_primary=case when exists(\n"
      + "           select 1 from public.sme_prospect_contacts existing\n"
      + "            where existing.prospect_id=p_target and existing.is_primary\n"
      + "         ) then false else is_primary end\n"
      + "   where prospect_id=p_source;",
  },
  {
    migration: 'supabase/migrations/20260807235950_nestly_v234_advisor_hygiene.sql',
    reason:
      'CHAIN GAP, not a formatting drift: public.promotion_branch_scopes_v154 exists in '
      + 'production (5 columns, RLS on, 3 FKs, a unique key and a lookup index) but NO '
      + 'committed migration creates it — grep the chain and the only files that mention it '
      + 'are the ones that ALTER or read it (v183, v234, v412). The migration that created it '
      + 'was applied to production and never landed in the repo. v234 is the first file that '
      + 'touches it at DDL time, so the table is reconstructed here from the live definition '
      + '(read 2026-08-22 from gadpooereceldfpfxsod), minus the primary key that v234 itself '
      + 'adds on the very next line. The real fix is a back-fill migration in the chain.',
    prepend:
      "-- db-tests chain gap: reconstruct public.promotion_branch_scopes_v154 (see reason above).\n"
      + 'create table if not exists public.promotion_branch_scopes_v154 (\n'
      + '  promotion_id uuid not null references public.business_customer_content_v95(id) on delete cascade,\n'
      + '  business_id uuid not null references public.businesses(id) on delete cascade,\n'
      + '  branch_id uuid not null references public.branches(id) on delete restrict,\n'
      + '  created_at timestamptz not null default now(),\n'
      + '  created_by uuid,\n'
      + '  constraint promotion_branch_scopes_v154_unique unique (promotion_id, branch_id)\n'
      + ');\n'
      + 'alter table public.promotion_branch_scopes_v154 enable row level security;\n'
      + 'create index if not exists promotion_branch_scopes_v154_branch_idx\n'
      + '  on public.promotion_branch_scopes_v154 (business_id, branch_id, promotion_id);\n'
      + 'do $gap$ begin\n'
      + "  if not exists (select 1 from pg_policies where schemaname='public'\n"
      + "                  and tablename='promotion_branch_scopes_v154'\n"
      + "                  and policyname='promotion_branch_scopes_v154_staff_read') then\n"
      + '    create policy promotion_branch_scopes_v154_staff_read\n'
      + '      on public.promotion_branch_scopes_v154 for select\n'
      + '      using (app.is_salon_member(business_id) or app.is_super_admin());\n'
      + '  end if;\n'
      + 'end $gap$;\n',
  },
];

/**
 * Migrations whose failure during replay is tolerated.
 *
 * These are all the same shape: a migration that edits an existing PL/pgSQL body by exact
 * substring replacement (`pg_get_functiondef` → `replace` → `execute`) and raises when the
 * substring is absent. The substring is absent on a fresh replay because an EARLIER change to
 * the same function reached production but never landed in this repository — so the chain
 * builds a different starting text than the one the needle was written against.
 *
 * Tolerating one is only sound when EITHER a later committed migration re-creates the same
 * object from its full production text (`supersededBy` names it), OR the object is provably
 * outside what this harness tests and the divergence is written down (`scopeNote`). One of
 * the two is mandatory and enforced below — an entry with neither throws at import.
 *
 * tests/db-harness/baseline-fidelity.test.mjs independently checks the FINAL definitions
 * against digests captured from production, so a wrong judgement here surfaces as a failing
 * test rather than a quietly wrong baseline.
 */
export const TOLERATED_CHAIN_FAILURES = [
  {
    migration: 'supabase/migrations/20260809000500_nestly_v257_bundle_finalise_rehash.sql',
    expectError: 'needle not found',
    supersededBy:
      'supabase/migrations/20260820000001_nestly_v394_tier_lifecycle_checkout.sql (and v370 '
      + 'before it) re-create app.ps1c_plan_checkout and public.record_cart_sale in full from '
      + 'production pg_get_functiondef output — both files say so in their own headers.',
    reason:
      'v257 patches app.ps1c_plan_checkout expecting the declaration `v_bundle jsonb; '
      + 'v_bline jsonb;`. Nothing in the committed chain ever adds it: v204 creates the '
      + 'helper app.ps1c_bundle_lines_v204 but never wires it into the checkout kernel. The '
      + 'migration that taught ps1c_plan_checkout about bundles was applied to production and '
      + 'is MISSING from this repository. That is a chain-completeness defect worth fixing '
      + 'upstream; it does not change the final baseline because v370/v394 overwrite the '
      + 'whole function with production text.',
  },
  {
    migration: 'supabase/migrations/20260816000011_nestly_v362_bringback_till_surface.sql',
    expectError: 'entitlements return anchor not found',
    supersededBy:
      'supabase/migrations/20260821000011_nestly_v420_referral_free_gift.sql re-creates '
      + 'public.staff_get_customer_entitlements_v102 in full, and its return already carries '
      + "both 'bringback_offer' and 'referral_offer'. Confirmed in the built snapshot: the "
      + 'baseline function ends with all five keys, so v362\'s effect is present.',
    reason:
      'v362 splices the bring-back voucher into the till entitlements payload by matching the '
      + 'return statement. Its own comment records that the production return is "split across '
      + 'TWO lines (v215\'s own splice left it that way)" — i.e. the anchor was written against '
      + "production whitespace that the committed chain does not reproduce. Replay builds the "
      + 'single-line form and the anchor misses.',
  },
  {
    migration: 'supabase/migrations/20260814001200_nestly_v315_repair_dropped_lead_score_references.sql',
    expectError: 'drawer repair failed: unexpected shape',
    scopeNote:
      'PROSPECTING/CRM SURFACE ONLY — not Rewards, not loyalty, not checkout. The affected '
      + 'routines are public.platform_crm_prospecting_search_v297 / _detail_v297 / '
      + 'platform_crm_log_outreach_v297 / platform_crm_ingest_discovered_v297 and '
      + 'app.v310_purge_expired_google_content.',
    reason:
      'v315 removes lead-scoring references by array-slicing pg_get_functiondef line by line '
      + '(`parts[i+2] not like ...`). Line-offset surgery against production text is the most '
      + 'drift-sensitive form of patching in this chain and it misses on replay. CONSEQUENCE, '
      + 'stated plainly: in the baseline those five routines still mention lead_score while '
      + 'v313 has already dropped public.sme_lead_scores, so calling them in the baseline can '
      + 'fail in a way production does not. Nothing in db/tests/executed/ calls them. If a '
      + 'future suite needs the prospecting surface, this tolerance must be retired first.',
  },
  {
    migration: 'supabase/migrations/20260814001300_nestly_v316_repair_taxonomy_and_match_queue.sql',
    expectError: 'lead_score references still present in',
    scopeNote: 'Same prospecting/CRM surface as v315.',
    reason:
      'Direct consequence of the v315 tolerance above: v316 opens by asserting that v315 '
      + 'already removed every lead_score reference, and refuses when it has not. It carries '
      + 'no independent defect. Fixing v315 upstream makes this one apply again too.',
  },
];

for (const t of TOLERATED_CHAIN_FAILURES) {
  if (!t.supersededBy && !t.scopeNote) {
    throw new Error(
      `TOLERATED_CHAIN_FAILURES entry for ${t.migration} has neither supersededBy nor `
      + 'scopeNote. A tolerated failure without a stated consequence is a hidden one.'
    );
  }
}

/**
 * Files that are listed in the canonical manifest but are NOT migrations.
 *
 * The manifest is supposed to be the executable chain. These files say, in their own header,
 * that they are not — they are recovery snapshots kept so a destructive migration is
 * reversible — and they cannot execute in the position the manifest gives them, because the
 * migration that drops their target sorts earlier. Materialising a recovery artifact into
 * the executable order is a manifest defect; the harness skips them and says so.
 */
export const CHAIN_NON_MIGRATIONS = [
  {
    migration: 'supabase/migrations/20260814001050_nestly_v313_rollback_data_snapshot.sql',
    reason:
      'The file\'s own header reads "Not part of the migration chain — it is never executed '
      + 'automatically." It re-inserts the 11 pre-v311 rows of '
      + 'public.sme_data_quality_rule_versions, a table that '
      + '20260814001000_nestly_v313_conversion_first_prospecting.sql drops 50 seconds earlier '
      + 'in manifest order. Executing it always fails with 42P01. It belongs beside the '
      + 'rollback plans, not in supabase/migrations.',
  },
];

/**
 * Platform objects the hosted project provides before migration 1. db/tests/rehearsal/
 * bootstrap.sql stubs the schemas; these lines neutralise the CREATE EXTENSION statements
 * that would otherwise look for a binary that is not installed locally.
 */
const EXTENSION_STUBS = [
  /^CREATE EXTENSION IF NOT EXISTS "supabase_vault" WITH SCHEMA "vault";$/gim,
  /^create extension if not exists ["']?pg_cron["']?.*$/gim,
  /^create extension if not exists ["']?pg_net["']?.*$/gim,
];

/**
 * START-STATE BODY-HASH PINS.
 *
 * Dozens of migrations in this chain edit an existing PL/pgSQL body in place, and open by
 * pinning the body they are about to edit:
 *
 *     select md5(p.prosrc) into strict v_md5 ...;
 *     if v_md5 <> '094f7f8e2be24cea0a8d9d3e8fbacfdc' then raise exception '...'; end if;
 *
 * Each hash was read live from PRODUCTION when the migration was written. That makes the pin
 * an assertion about production's state at that moment, not about the repository's — so a
 * replay of the committed chain fails it whenever an earlier edit to the same body reached
 * production without landing here. On this chain that is common (see v257 and v322).
 *
 * The pins are therefore neutralised for replay: the 32-hex literal is swapped for NULL, so
 * every `<>` guard evaluates to NULL and never raises, and every `=` short-circuit evaluates
 * to NULL and never early-returns. Nothing else in the migration is touched — the edits it
 * performs still run, in order, against whatever body the chain actually built.
 *
 * This is deliberately narrow: it matches ONLY a comparison against a bare 32-hex literal.
 * It cannot touch data checks, row counts, or any guard that is not a body hash.
 *
 * The safety net is not this transform, it is tests/db-harness/baseline-fidelity.test.mjs,
 * which compares the FINAL definitions the baseline produces against digests captured from
 * production. Every migration where a pin was neutralised is recorded and printed, so the
 * blast radius is always visible rather than assumed.
 */
const BODY_HASH_PIN = /(<>|=)\s*'[0-9a-f]{32}'/g;

export function neutraliseBodyHashPins(sql) {
  let count = 0;
  const out = sql.replace(BODY_HASH_PIN, (_m, op) => { count += 1; return `${op} null`; });
  return { sql: out, count };
}

export function prepareMigrationSql(relPath, sql, notes = null) {
  let out = sql;
  for (const rx of EXTENSION_STUBS) out = out.replace(rx, '-- db-tests: platform extension stubbed by bootstrap');

  const pinned = neutraliseBodyHashPins(out);
  if (pinned.count) {
    out = pinned.sql;
    if (notes) notes.push({ migration: relPath, pinsNeutralised: pinned.count });
  }

  for (const patch of CHAIN_DRIFT_PATCHES) {
    if (patch.migration !== relPath) continue;

    /* A `prepend` runs before the migration's own first statement. Migrations in this chain
       open with `begin;`, so the prelude is spliced in after it rather than in front of it —
       otherwise the prelude would commit separately and a failed migration would leave it
       behind. */
    if (patch.prepend) {
      const m = /^\s*begin\s*;\s*$/im.exec(out);
      out = m
        ? out.slice(0, m.index + m[0].length) + '\n' + patch.prepend + out.slice(m.index + m[0].length)
        : patch.prepend + out;
    }
    /* `regexReplace` entries are [pattern, replacement, minMatches]. A pattern that matches
       fewer than minMatches times fails the run — same rule as `find`: a transform that has
       stopped applying must be re-derived, never silently skipped. */
    for (const [pattern, replacement, minMatches = 1] of patch.regexReplace || []) {
      const hits = (out.match(pattern) || []).length;
      if (hits < minMatches) {
        throw new Error(
          `chain drift patch for ${relPath}: pattern ${pattern} matched ${hits} time(s), `
          + `expected at least ${minMatches}.\n  reason on record: ${patch.reason}`
        );
      }
      out = out.replace(pattern, replacement);
    }
    if (!patch.find) continue;

    if (!out.includes(patch.find)) {
      throw new Error(
        `chain drift patch for ${relPath} no longer matches the file.\n`
        + `  reason on record: ${patch.reason}\n`
        + '  If the committed migration was fixed, delete this patch from '
        + 'scripts/db-tests/chain-drift-patches.mjs. Do not loosen the match.'
      );
    }
    out = out.replace(patch.find, patch.replace);
  }
  return out;
}
