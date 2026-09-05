import assert from 'node:assert/strict';
import { existsSync } from 'node:fs';
import { readdir, readFile, stat } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
export const repoRoot = path.resolve(__dirname, '..', '..');

const deployableExtensions = new Set(['.html', '.js', '.css', '.mjs']);
const requiredEntryFiles = ['app/index.html', 'app/join.html'];
const supabaseRefPattern = /https:\/\/([a-z0-9]{20})\.supabase\.co\b/g;
const singaporeSupabaseRef = 'gadpooereceldfpfxsod';
const singaporeSupabaseUrl = `https://${singaporeSupabaseRef}.supabase.co`;
const singaporeSupabaseWsUrl = `wss://${singaporeSupabaseRef}.supabase.co`;
const singaporePublishableKey = 'sb_publishable_wDf8p9RghbpM2t7_PfBWKQ_YhYhNEAI';
const oldSupabaseRef = 'kyzovonwnscrzmkvocid';
const oldSupabaseUrl = `https://${oldSupabaseRef}.supabase.co`;
const oldSupabaseWsUrl = `wss://${oldSupabaseRef}.supabase.co`;
const oldPublishableKey = 'sb_publishable_hOMgvuulHY0iSs7nmbqt3Q_RD0df_p7';
const cdnHosts = new Set([
  'cdn.jsdelivr.net',
  'cdnjs.cloudflare.com',
  'cdn.sheetjs.com',
  'unpkg.com',
  'esm.sh',
  'cdn.skypack.dev'
]);
const expectedScriptIntegrity = new Map([
  [
    'https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2.110.7/dist/umd/supabase.min.js',
    'sha384-BmlQlKlDvXvKoxkn5OQuUo/aJQCTXeB+Kls6EccBmG4Kf8AXvp89RtO9MtPxP/r5'
  ],
  [
    'https://cdn.jsdelivr.net/npm/chart.js@4.4.3/dist/chart.umd.min.js',
    'sha384-JUh163oCRItcbPme8pYnROHQMC6fNKTBWtRG3I3I0erJkzNgL7uxKlNwcrcFKeqF'
  ],
  [
    'https://cdnjs.cloudflare.com/ajax/libs/qrcodejs/1.0.0/qrcode.min.js',
    'sha384-3zSEDfvllQohrq0PHL1fOXJuC/jSOO34H46t6UQfobFOmxE5BpjjaIJY5F2/bMnU'
  ],
  [
    'https://cdn.jsdelivr.net/npm/jsqr@1.4.0/dist/jsQR.js',
    'sha384-b5Ya4Bq3qCyz39m2ISh+4DxjAIljdeFwK/BsXLuj9gugaNwAcj/ia15fxNZL9Nlx'
  ],
  [
    'https://cdn.sheetjs.com/xlsx-0.20.3/package/dist/xlsx.full.min.js',
    'sha384-EnyY0/GSHQGSxSgMwaIPzSESbqoOLSexfnSMN2AP+39Ckmn92stwABZynq1JyzdT'
  ]
]);

function rel(root, absPath) {
  return path.relative(root, absPath).split(path.sep).join('/');
}

function lineForOffset(source, offset) {
  return source.slice(0, offset).split('\n').length;
}

async function readText(root, relativePath) {
  return readFile(path.join(root, relativePath), 'utf8');
}

async function listFiles(dir) {
  const entries = await readdir(dir, { withFileTypes: true });
  const files = [];
  for (const entry of entries) {
    const absPath = path.join(dir, entry.name);
    if (entry.isDirectory()) {
      files.push(...await listFiles(absPath));
    } else if (entry.isFile()) {
      files.push(absPath);
    }
  }
  return files;
}

async function deployableAppFiles(root) {
  const appDir = path.join(root, 'app');
  const files = await listFiles(appDir);
  return files.filter((file) => deployableExtensions.has(path.extname(file)));
}

function assertTagContains(source, pattern, message) {
  assert.match(source, pattern, message);
}

/* A <link rel=preconnect|dns-prefetch> names an ORIGIN to warm; it fetches no code and can carry
   no version, so it is not a dependency url. Everything else that names a CDN still must pin an
   exact version. */
const CONNECTION_HINT_PATTERN = /<link\b[^>]*\brel=["'](?:preconnect|dns-prefetch)["'][^>]*>/gi;
function connectionHintRanges(source) {
  const ranges = [];
  let match;
  CONNECTION_HINT_PATTERN.lastIndex = 0;
  while ((match = CONNECTION_HINT_PATTERN.exec(source))) {
    ranges.push([match.index, match.index + match[0].length]);
  }
  return ranges;
}

function extractAttributeUrls(source) {
  const urls = [];
  const hints = connectionHintRanges(source);
  const attrPattern = /\b(?:src|href)=["']([^"']+)["']/g;
  let match;
  while ((match = attrPattern.exec(source))) {
    if (hints.some(([start, end]) => match.index >= start && match.index < end)) continue;
    try {
      const parsed = new URL(match[1]);
      urls.push({
        href: match[1],
        host: parsed.host,
        pathname: parsed.pathname,
        line: lineForOffset(source, match.index)
      });
    } catch {
      // Relative links are handled by the browser from the same origin.
    }
  }
  return urls;
}

function parseAttributes(tag) {
  const attrs = new Map();
  const attrPattern = /([^\s=/>]+)(?:\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'=<>`]+)))?/g;
  let match;
  while ((match = attrPattern.exec(tag))) {
    const name = match[1].toLowerCase();
    if (name === 'script') continue;
    attrs.set(name, match[2] ?? match[3] ?? match[4] ?? '');
  }
  return attrs;
}

function extractScriptTags(source) {
  const scripts = [];
  const scriptPattern = /<script\b[^>]*\bsrc=["'][^"']+["'][^>]*>/gi;
  let match;
  while ((match = scriptPattern.exec(source))) {
    scripts.push({
      attrs: parseAttributes(match[0]),
      line: lineForOffset(source, match.index)
    });
  }
  return scripts;
}

function isExactSemver(version) {
  return /^\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.-]+)?$/.test(version);
}

function cdnVersionFor(url) {
  if (url.host === 'cdn.jsdelivr.net' && url.pathname.startsWith('/npm/')) {
    const packagePath = url.pathname.slice('/npm/'.length);
    const atIndex = packagePath.startsWith('@')
      ? packagePath.indexOf('@', 1)
      : packagePath.indexOf('@');
    if (atIndex === -1) return null;
    return packagePath.slice(atIndex + 1).split('/')[0] || null;
  }

  if (url.host === 'cdnjs.cloudflare.com' && url.pathname.startsWith('/ajax/libs/')) {
    const parts = url.pathname.split('/').filter(Boolean);
    return parts[3] || null;
  }

  if (url.host === 'cdn.sheetjs.com') {
    return /^\/xlsx-(\d+\.\d+\.\d+)\//.exec(url.pathname)?.[1] ?? null;
  }

  if (url.host === 'unpkg.com') {
    const packagePath = url.pathname.slice(1);
    const atIndex = packagePath.startsWith('@')
      ? packagePath.indexOf('@', 1)
      : packagePath.indexOf('@');
    if (atIndex === -1) return null;
    return packagePath.slice(atIndex + 1).split('/')[0] || null;
  }

  if (url.host === 'esm.sh' || url.host === 'cdn.skypack.dev') {
    const packagePath = url.pathname.slice(1);
    const atIndex = packagePath.startsWith('@')
      ? packagePath.indexOf('@', 1)
      : packagePath.indexOf('@');
    if (atIndex === -1) return null;
    return packagePath.slice(atIndex + 1).split('/')[0] || null;
  }

  return null;
}

function headerMap(vercelConfig) {
  const allPathHeaders = vercelConfig.headers?.find((entry) => entry.source === '/(.*)');
  assert.ok(allPathHeaders, 'vercel.json must attach security headers to source "/(.*)".');
  return new Map(allPathHeaders.headers.map((header) => [header.key.toLowerCase(), header.value]));
}

function cspDirectives(csp) {
  const directives = new Map();
  for (const rawDirective of csp.split(';')) {
    const trimmed = rawDirective.trim();
    if (!trimmed) continue;
    const [name, ...values] = trimmed.split(/\s+/);
    directives.set(name, values);
  }
  return directives;
}

function expectDirectiveValues(directives, name, values) {
  const actual = directives.get(name);
  assert.ok(actual, `CSP must include ${name}.`);
  for (const value of values) {
    assert.ok(actual.includes(value), `CSP ${name} must include ${value}.`);
  }
}

export async function checkStaticEntryFiles(root = repoRoot) {
  for (const entry of requiredEntryFiles) {
    const absPath = path.join(root, entry);
    assert.ok(existsSync(absPath), `Missing static entry file: ${entry}`);
    const info = await stat(absPath);
    assert.ok(info.isFile(), `Static entry is not a file: ${entry}`);
    assert.ok(info.size > 0, `Static entry is empty: ${entry}`);
  }

  // Vercel Root Directory is `app`; the effective config must live at app/vercel.json and must
  // not re-point outputDirectory (a repo-root vercel.json is outside the project root and ignored).
  assert.ok(!existsSync(path.join(root, 'vercel.json')),
    'vercel.json must not exist at the repo root: the Vercel Root Directory is app, so a root file is silently ignored.');
  const vercelConfig = JSON.parse(await readText(root, 'app/vercel.json'));
  assert.equal(vercelConfig.outputDirectory, undefined,
    'app/vercel.json must not set outputDirectory: the Vercel Root Directory is already app.');
}

export async function checkSupabaseProjectReferences(
  root = repoRoot,
  expectedRef = process.env.EXPECTED_SUPABASE_PROJECT_REF || null
) {
  // The substantive check below — that no deployable file mixes Supabase project refs — must run
  // on every plain `node --test`. It previously sat behind an env var that nothing sets, so the
  // assertion failed before reaching the scan and the mixed-ref guard never actually ran.
  // An explicitly-set EXPECTED_SUPABASE_PROJECT_REF is still honoured, so a cutover run that
  // names the wrong project still fails loudly.
  if (expectedRef !== null) {
    assert.equal(
      expectedRef,
      singaporeSupabaseRef,
      `EXPECTED_SUPABASE_PROJECT_REF must be ${singaporeSupabaseRef} for cutover validation.`
    );
  }
  const effectiveRef = expectedRef ?? singaporeSupabaseRef;

  const refs = new Map();
  for (const file of await deployableAppFiles(root)) {
    const source = await readFile(file, 'utf8');
    let match;
    while ((match = supabaseRefPattern.exec(source))) {
      const ref = match[1];
      const locations = refs.get(ref) || [];
      locations.push(`${rel(root, file)}:${lineForOffset(source, match.index)}`);
      refs.set(ref, locations);
    }
  }

  assert.ok(refs.size > 0, 'No Supabase project URL found in deployable app files.');

  assert.match(
    effectiveRef,
    /^[a-z0-9]{20}$/,
    'EXPECTED_SUPABASE_PROJECT_REF must be a 20-character Supabase project ref.'
  );
  const unknownRefs = [...refs.keys()].filter((ref) => ref !== effectiveRef);
  assert.deepEqual(
    unknownRefs,
    [],
    `Deployable app files contain stale/unknown Supabase refs. Expected only ${effectiveRef}; found ${unknownRefs.join(', ')}.`
  );

  assert.equal(
    refs.size,
    1,
    `Deployable app files must not mix Supabase project refs. Found: ${[...refs.keys()].join(', ')}.`
  );
}

export async function checkSupabaseClientContract(root = repoRoot) {
  const productionConfig = JSON.parse(await readText(root, 'config/runtime/production.json'));
  assert.deepEqual(Object.keys(productionConfig).sort(), [
    'customerPhoneOtpEnabled', 'environment', 'projectRef', 'schemaVersion',
    'supabasePublishableKey', 'supabaseUrl', 'webPushPublicKey'
  ]);
  assert.equal(productionConfig.schemaVersion, 2);
  assert.equal(productionConfig.environment, 'production');
  assert.equal(productionConfig.projectRef, singaporeSupabaseRef);
  assert.equal(productionConfig.supabaseUrl, singaporeSupabaseUrl);
  assert.equal(productionConfig.supabasePublishableKey, singaporePublishableKey);
  assert.equal(productionConfig.customerPhoneOtpEnabled, true);
  assert.equal(typeof productionConfig.webPushPublicKey, 'string');

  const runtimeArtifact = await readText(root, 'app/runtime-config.js');
  assert.match(runtimeArtifact, /window\.__FRENLY_RUNTIME_CONFIG__\s*=\s*Object\.freeze\(/);
  assert.ok(runtimeArtifact.includes(JSON.stringify(singaporeSupabaseUrl)),
    'Generated runtime config must use the production Supabase URL.');
  assert.ok(runtimeArtifact.includes(JSON.stringify(singaporePublishableKey)),
    'Generated runtime config must use the production publishable key.');
  assert.doesNotMatch(runtimeArtifact, /sb_secret_|service_role/i,
    'Generated browser runtime config must never contain a secret/service-role credential.');

  // The app client is now two files: app/index.html carries the blocking config
  // tags and markup, app/app.js carries the bootstrap. Scan the pair as one
  // client so every contract below still covers the whole surface.
  const clientFiles = [['app/index.html', 'app/app.js'], ['app/join.html']];
  for (const parts of clientFiles) {
    const file = parts.join(' + ');
    const source = (await Promise.all(parts.map((part) => readText(root, part)))).join('\n');
    assert.match(
      source,
      /<script src="\/runtime-config\.js\?v=2"><\/script>[\s\S]*?<script src="\/runtime-config-loader\.js\?v=2"><\/script>/,
      `${file} must load explicit runtime config before the shared validator.`
    );
    assert.match(
      source,
      /window\.FrenlyRuntimeConfig\.require\(window\)/,
      `${file} must validate runtime config before creating a client.`
    );
    assert.match(source, /const SB_URL=RUNTIME_CONFIG\.supabaseUrl;/,
      `${file} must source its Supabase URL from validated runtime config.`);
    assert.match(source, /const SB_KEY=RUNTIME_CONFIG\.supabasePublishableKey;/,
      `${file} must source its browser key from validated runtime config.`);
    assert.doesNotMatch(source, supabaseRefPattern, `${file} must not hardcode a Supabase project URL.`);
    assert.doesNotMatch(source, /sb_(?:publishable|secret)_/,
      `${file} must not hardcode any Supabase API key.`);
    assert.doesNotMatch(source, new RegExp(oldSupabaseUrl.replaceAll('.', '\\.')), `${file} must not contain the old Supabase URL.`);
    assert.doesNotMatch(source, new RegExp(oldPublishableKey), `${file} must not contain the old publishable key.`);
  }
}

export async function checkCdnDependencyPins(root = repoRoot) {
  const failures = [];
  for (const file of await deployableAppFiles(root)) {
    const source = await readFile(file, 'utf8');
    for (const url of extractAttributeUrls(source).filter((candidate) => cdnHosts.has(candidate.host))) {
      const version = cdnVersionFor(url);
      if (!version || !isExactSemver(version)) {
        failures.push(`${rel(root, file)}:${url.line} ${url.href}`);
      }
    }
  }

  assert.deepEqual(
    failures,
    [],
    `CDN dependency URLs must be pinned to exact semver versions:\n${failures.join('\n')}`
  );
}

export async function checkCdnScriptIntegrity(root = repoRoot) {
  const failures = [];
  for (const file of await deployableAppFiles(root)) {
    const source = await readFile(file, 'utf8');
    for (const script of extractScriptTags(source)) {
      const src = script.attrs.get('src');
      if (!src) continue;
      let parsed;
      try {
        parsed = new URL(src);
      } catch {
        continue;
      }
      if (!cdnHosts.has(parsed.host)) continue;

      const expectedIntegrity = expectedScriptIntegrity.get(src);
      if (!expectedIntegrity) {
        failures.push(`${rel(root, file)}:${script.line} ${src} is missing from the expected SRI allowlist`);
        continue;
      }
      if (script.attrs.get('integrity') !== expectedIntegrity) {
        failures.push(`${rel(root, file)}:${script.line} ${src} has missing/mismatched integrity`);
      }
      if (script.attrs.get('crossorigin') !== 'anonymous') {
        failures.push(`${rel(root, file)}:${script.line} ${src} must use crossorigin="anonymous"`);
      }
    }
  }

  assert.deepEqual(
    failures,
    [],
    `CDN script tags must carry deterministic SRI metadata:\n${failures.join('\n')}`
  );
}

export async function checkPublicPageForms(root = repoRoot) {
  const join = await readText(root, 'app/join.html');
  assertTagContains(join, /<form\b[^>]*id=["']joinForm["'][^>]*novalidate[^>]*>/, 'join page must retain the public join form.');
  assertTagContains(join, /<input\b[^>]*id=["']f_name["'][^>]*autocomplete=["']name["'][^>]*>/, 'join page must retain the name input.');
  assertTagContains(join, /<input\b[^>]*id=["']f_phone["'][^>]*inputmode=["']numeric["'][^>]*maxlength=["']8["'][^>]*autocomplete=["']tel["'][^>]*>/, 'join page must retain the Singapore mobile input.');
  assertTagContains(join, /<input\b[^>]*id=["']f_email["'][^>]*type=["']email["'][^>]*autocomplete=["']email["'][^>]*>/, 'join page must retain the optional email input.');
  const consentTag = join.match(/<input\b[^>]*id=["']f_consent["'][^>]*>/)?.[0] || '';
  assert.ok(consentTag, 'join page must retain the PDPA marketing consent checkbox.');
  assert.doesNotMatch(consentTag, /\bchecked\b/i, 'PDPA marketing consent checkbox must not be pre-checked.');
  assertTagContains(join, /<button\b[^>]*id=["']submitBtn["'][^>]*type=["']submit["'][^>]*disabled[^>]*>/, 'join page must retain a disabled-by-default submit button.');
  // V292 retarget (audit G9): this pin used to name /^[3689]\d{7}$/, the GATEWAY's rule, which
  // also admits 3xx VoIP and 6xx fixed-line numbers. The field is labelled "Mobile number" and
  // the customer app matches members on /^[89]\d{7}$/, so a landline joiner became a member the
  // wallet could never find. The pin now names the tighter CLIENT rule; the gateway is unchanged
  // and stays the more permissive of the two, which is the correct direction for a client guard.
  assertTagContains(join, /\^\[89\]\\d\{7\}\$/, 'join page must retain Singapore mobile-number validation.');

  // App templates and controls now live in app/app.js; scan it together with the
  // shell markup so the required-control contract still covers the whole page.
  const index = (await readText(root, 'app/index.html')) + '\n' + (await readText(root, 'app/app.js'));
  assertTagContains(index, /<input\b[^>]*id=["']em["'][^>]*type=["']email["'][^>]*>/, 'app auth page must retain email input.');
  assertTagContains(
    index,
    /passwordControlHtml\(['"]pw['"]\s*,/,
    'app auth page must retain the reusable password input.'
  );
  assertTagContains(
    index,
    /function\s+passwordControlHtml[\s\S]*?`type=["']password["']`/,
    'reusable password controls must render password inputs by default.'
  );
  assertTagContains(index, /<button\b[^>]*id=["']go["'][^>]*>/, 'app auth page must retain sign-in/sign-up button.');
  assertTagContains(index, /<button\b[^>]*id=["']businessApplicationSubmit["'][^>]*>/,
    'public business signup must retain the owner-account creation control.');
  assertTagContains(index, /<button\b[^>]*id=["']startSelfServe["'][^>]*>/,
    'confirmed owners without a workspace must retain the server-priced Stripe setup control.');
  assert.doesNotMatch(index, /id=["']mk["']/,
    'the legacy authenticated self-service workspace creation button must stay retired.');
}

function parseMigrationFilename(fileName) {
  const match = fileName.match(/^(?<prefix>\d{8}(?:\d{6})?)_(?<slug>[a-z0-9_]+)\.(?<ext>sql|note\.md)$/);
  assert.ok(match, `Migration filename has an unsupported format: ${fileName}`);

  const datePart = match.groups.prefix.slice(0, 8);
  const year = Number(datePart.slice(0, 4));
  const month = Number(datePart.slice(4, 6));
  const day = Number(datePart.slice(6, 8));
  const date = new Date(Date.UTC(year, month - 1, day));
  assert.equal(date.getUTCFullYear(), year, `Migration filename has invalid year: ${fileName}`);
  assert.equal(date.getUTCMonth(), month - 1, `Migration filename has invalid month: ${fileName}`);
  assert.equal(date.getUTCDate(), day, `Migration filename has invalid day: ${fileName}`);

  const version = match.groups.slug.match(/\b(?:frenly|nestly)_v(?<major>\d+)(?:(?<letter>[a-z])|_(?<minor>\d+))?/);
  const semantic = version
    ? {
        major: Number(version.groups.major),
        variant: version.groups.minor
          ? Number(version.groups.minor)
          : version.groups.letter
            ? version.groups.letter.charCodeAt(0) - 96
            : 0
      }
    : { major: 0, variant: 0 };

  return {
    fileName,
    dateNumber: Number(datePart),
    semantic,
    extension: match.groups.ext
  };
}

// Normally a higher semantic version was also written later, so file dates rise monotonically
// alongside it. nestly_v590-v592 break that pattern on purpose: they are VERBATIM source-recovery
// mirrors of production migrations that were actually applied on 2026-08-28 (drift closure,
// recovered and committed to source on 2026-08-29 -- see
// docs/qa/SECURITY-CRON-FOLLOWUP-2026-08-29.md section 2), while v586-v589 carry the later
// 2026-08-29 authoring date from an unrelated, higher-numbered-later-in-time workstream. Their
// real production dates cannot be changed without breaking the "mirror the applied migration
// exactly" guarantee this recovery exists to provide, so the one resulting adjacent regression is
// recorded here rather than silenced generally.
const KNOWN_DATE_ORDER_REGRESSIONS = new Set([
  // localeCompare's tie-break within the same (major, variant) semantic pair sorts the "_fn"
  // filename ahead of its plainer sibling, so the actual reported transition lands here rather
  // than on the alphabetically-simpler v590 name.
  '20260829_nestly_v589_referral_switch_is_one_switch.sql -> 20260828_nestly_v590_cron_run_history_retention_fn.sql',
  // 2026-09-03 merge: the Customer Intelligence proof wave (v672-v744, dated 20260920 so the local
  // harness and the deploy slots 20260920000000-20260922110000 agree) is a semantic-number twin of
  // main's v672-v688 audit waves (dated 20260902, already applied to production). Semantic order
  // therefore alternates between the two dates fourteen times; each pair is a parallel-session
  // twin, not a real ordering regression. Deploy order is unambiguous (the canonical plan).
  '20260920_nestly_v672_statistical_authority.sql -> 20260902_nestly_v673_staff_insert_owner_only.sql',
  '20260920_nestly_v673_retention_funnels.sql -> 20260902_nestly_v674_birthday_gift_type_change.sql',
  '20260920_nestly_v674_demographic_intelligence.sql -> 20260902_nestly_v675_stale_stamp_draft_superseded.sql',
  '20260920_nestly_v675_behaviour_service_package.sql -> 20260902_nestly_v676_gift_intent_reopen.sql',
  '20260920_nestly_v676_internal_drain_authority.sql -> 20260902_nestly_v677_reversal_is_not_a_visit.sql',
  '20260920_nestly_v678_consultant_spine.sql -> 20260902_nestly_v679_tier_edits_survive_publish.sql',
  '20260920_nestly_v680_ci_envelope.sql -> 20260902_nestly_v681_free_gift_confirm_at_scan.sql',
  '20260920_nestly_v681_return_probability.sql -> 20260902_nestly_v682_custom_perk_is_not_a_free_gift.sql',
  '20260920_nestly_v682_golden_corpus.sql -> 20260902_nestly_v683_referral_new_customers_only.sql',
  '20260920_nestly_v683_staff_rebooking_loyalty_discount.sql -> 20260902_nestly_v684_delete_retired_offer.sql',
  '20260920_nestly_v684_metric_dictionary.sql -> 20260902_nestly_v685_singapore_day_authority.sql',
  '20260920_nestly_v685_shadow_reconciliation.sql -> 20260902_nestly_v686_service_delete_owner_only_rpc.sql',
  '20260920_nestly_v686_discovery_scan.sql -> 20260902_nestly_v687_staff_self_profile.sql',
  '20260920_nestly_v687_revenue_truth_synthetic_exclusion.sql -> 20260902_nestly_v688_support_mark_read.sql',
  // nestly_v753 (owner ruling 2026-09-04, the birthday-window batch): deliberately deployed
  // between v748 and v749 (canonical plan slot 20260923030000), so its file date (20260923)
  // sits one day before v749's (20260924) even though v753 is the higher semantic number.
  '20260924_nestly_v749_customer_self_service_account_deletion.sql -> 20260923_nestly_v753_birthday_reaches_new_signups.sql',
  // 2026-09-05 rebase onto main 1568b344: this session's Owner-brief wave (nestly_v772
  // owner_brief_readers + nestly_v775) was written and applied to production on 20261003, at
  // deploy slots 20261003010000/20261003020000, while a parallel session's nestly_v772
  // branch_copy_without_staff (20261004) and nestly_v773 (20261005) landed on main first. Both
  // sides are already applied to production, so neither file may be re-dated. Semantic order
  // therefore steps from main's v773 (20261005) back to this session's v775 (20261003) — a
  // parallel-session twin, not a real ordering regression. Deploy order is unambiguous and
  // strictly monotonic in both plans: …003010000 and …003020000 precede …004000000/…005000000.
  '20261005_nestly_v773_rewards_same_at_every_branch.sql -> 20261003_nestly_v775_visit_rhythm_current_totals.sql'
]);

export async function checkMigrationFilenameSanity(root = repoRoot) {
  const migrationsDir = path.join(root, 'db', 'migrations');
  const files = (await readdir(migrationsDir))
    .filter((file) => file.endsWith('.sql') || file.endsWith('.note.md'))
    .sort();
  assert.ok(files.length > 0, 'db/migrations must contain migration files.');
  assert.equal(new Set(files).size, files.length, 'Migration filenames must be unique.');

  const parsed = files.map(parseMigrationFilename);
  const migrationIdentities = new Set(parsed.map(({ fileName }) => fileName));
  assert.equal(
    migrationIdentities.size,
    parsed.length,
    'Migration identities must be unique even when multiple migrations share a semantic release label.'
  );

  const orderedBySemantic = [...parsed].sort((a, b) => {
    if (a.semantic.major !== b.semantic.major) return a.semantic.major - b.semantic.major;
    if (a.semantic.variant !== b.semantic.variant) return a.semantic.variant - b.semantic.variant;
    return a.fileName.localeCompare(b.fileName);
  });

  for (let index = 1; index < orderedBySemantic.length; index += 1) {
    const prior = orderedBySemantic[index - 1];
    const current = orderedBySemantic[index];
    if (current.dateNumber >= prior.dateNumber) continue;
    assert.ok(
      KNOWN_DATE_ORDER_REGRESSIONS.has(`${prior.fileName} -> ${current.fileName}`),
      `Migration date order regresses from ${prior.fileName} to ${current.fileName}.`
    );
  }
}

export async function checkVercelSecurityHeaders(root = repoRoot) {
  const vercelConfig = JSON.parse(await readText(root, 'app/vercel.json'));
  const headers = headerMap(vercelConfig);

  const csp = headers.get('content-security-policy');
  assert.ok(csp, 'Vercel headers must include Content-Security-Policy.');
  const directives = cspDirectives(csp);
  expectDirectiveValues(directives, 'default-src', ["'self'"]);
  expectDirectiveValues(directives, 'base-uri', ["'self'"]);
  expectDirectiveValues(directives, 'object-src', ["'none'"]);
  expectDirectiveValues(directives, 'frame-ancestors', ["'none'"]);
  expectDirectiveValues(directives, 'form-action', ["'self'"]);
  /* Cloudflare Web Analytics is enabled on the zone and injects its beacon into
     every response; without these two hosts the browser logs a CSP violation on
     every page view. Analytics-only: no other third-party scripts are admitted. */
  expectDirectiveValues(directives, 'script-src', ["'self'", "'unsafe-inline'", 'https://cdn.jsdelivr.net', 'https://cdnjs.cloudflare.com', 'https://cdn.sheetjs.com', 'https://challenges.cloudflare.com', 'https://static.cloudflareinsights.com']);
  expectDirectiveValues(directives, 'frame-src', ['https://challenges.cloudflare.com']);
  expectDirectiveValues(directives, 'style-src', ["'self'", "'unsafe-inline'", 'https://fonts.googleapis.com']);
  expectDirectiveValues(directives, 'font-src', ["'self'", 'https://fonts.gstatic.com', 'data:']);
  expectDirectiveValues(directives, 'img-src', ["'self'", 'data:', 'blob:', 'https://gadpooereceldfpfxsod.supabase.co']);
  expectDirectiveValues(directives, 'connect-src', [
    "'self'",
    singaporeSupabaseUrl,
    singaporeSupabaseWsUrl,
    'https://challenges.cloudflare.com',
    'https://cloudflareinsights.com',
    'https://static.cloudflareinsights.com'
  ]);
  assert.deepEqual(
    directives.get('connect-src'),
    ["'self'", singaporeSupabaseUrl, singaporeSupabaseWsUrl, 'https://challenges.cloudflare.com', 'https://cloudflareinsights.com', 'https://static.cloudflareinsights.com'],
    'CSP connect-src must be restricted to self, the Singapore Supabase HTTPS/WSS origins, Cloudflare Turnstile, and Cloudflare Web Analytics.'
  );
  assert.ok(!csp.includes(oldSupabaseUrl), 'CSP must not include the old Supabase HTTPS origin.');
  assert.ok(!csp.includes(oldSupabaseWsUrl), 'CSP must not include the old Supabase WSS origin.');
  assert.ok(directives.has('upgrade-insecure-requests'), 'CSP must include upgrade-insecure-requests.');

  const hsts = headers.get('strict-transport-security') || '';
  const maxAge = Number(hsts.match(/\bmax-age=(\d+)/)?.[1] || 0);
  assert.ok(maxAge >= 31536000, 'Strict-Transport-Security max-age must be at least one year.');
  assert.match(hsts, /\bincludeSubDomains\b/, 'Strict-Transport-Security must include subdomains.');

  assert.equal(headers.get('x-content-type-options'), 'nosniff', 'X-Content-Type-Options must be nosniff.');
  assert.equal(headers.get('x-frame-options'), 'DENY', 'X-Frame-Options must deny framing.');
  assert.equal(
    headers.get('x-permitted-cross-domain-policies'),
    'none',
    'Legacy cross-domain policy discovery must be disabled.'
  );
  assert.equal(headers.get('referrer-policy'), 'strict-origin-when-cross-origin', 'Referrer-Policy must be strict-origin-when-cross-origin.');
  const permissions = headers.get('permissions-policy') || '';
  for (const policy of ['camera=(self)', 'microphone=()', 'geolocation=()', 'payment=()', 'usb=()', 'clipboard-write=(self)']) {
    assert.ok(permissions.includes(policy), `Permissions-Policy must include ${policy}.`);
  }
}

export async function runAllChecks(root = repoRoot) {
  await checkStaticEntryFiles(root);
  await checkSupabaseProjectReferences(root);
  await checkSupabaseClientContract(root);
  await checkCdnDependencyPins(root);
  await checkCdnScriptIntegrity(root);
  await checkPublicPageForms(root);
  await checkMigrationFilenameSanity(root);
  await checkVercelSecurityHeaders(root);
}

if (process.argv[1] === __filename) {
  try {
    await runAllChecks();
    console.log('Static production baseline checks passed.');
  } catch (error) {
    console.error(error.message);
    process.exitCode = 1;
  }
}
