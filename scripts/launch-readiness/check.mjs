#!/usr/bin/env node
import { createHash } from 'node:crypto';
import { existsSync, readFileSync, realpathSync, statSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
export const repoRoot = path.resolve(__dirname, '..', '..');
export const defaultManifestPath = 'docs/launch/launch-blockers.json';

const MANIFEST_VERSION = 'launch_readiness_manifest_v1';
const EVIDENCE_KIND = 'launch_readiness_evidence_v1';
const STATUSES = new Set(['BLOCKED', 'IMPLEMENTED', 'VERIFIED_STAGING', 'VERIFIED_PRODUCTION']);
const STAGES = new Set(['IMPLEMENTATION', 'STAGING', 'PRODUCTION']);
const SEVERITIES = new Set(['P0', 'P1', 'P2']);
const SHA256 = /^[a-f0-9]{64}$/;
const PROJECT_REF = /^[a-z0-9]{20}$/;
const ISO_TIME = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{3})?Z$/;
const BLOCKER_ID = /^P[0-2]-[A-Z0-9]+(?:-[A-Z0-9]+)*-\d{3}$/;
const UNSAFE_VALUE_PATTERNS = [
  { name: 'email address', pattern: /[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}/i },
  { name: 'Singapore phone number', pattern: /(?:\+65\s*)?[3689]\d{7}\b/ },
  { name: 'URL', pattern: /\bhttps?:\/\//i },
  { name: 'database URL', pattern: /\b(?:postgres|postgresql):\/\//i },
  { name: 'JWT-like token', pattern: /\beyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\b/ },
  { name: 'service-role secret', pattern: /\bservice_role\b/i },
  { name: 'private key', pattern: /-----BEGIN(?: [A-Z]+)? PRIVATE KEY-----/ }
];
const UNSAFE_KEY = /(?:^|_)(?:raw_?(?:email|phone|mobile|name|token|secret|password)|authorization|access_?token|refresh_?token|api_?key|private_?key)(?:$|_)/i;

function usage(exitCode = 2) {
  const message = [
    'Usage: node scripts/launch-readiness/check.mjs [--manifest <relative-path>] [--json]',
    '',
    'The gate is offline. It reads a manifest and hash-pinned, redacted local evidence only.',
    'It exits 1 whenever a P0 is not VERIFIED_PRODUCTION with valid evidence.'
  ].join('\n');
  (exitCode === 0 ? console.log : console.error)(message);
  return exitCode;
}

export function parseArgs(argv) {
  let manifestPath = defaultManifestPath;
  let json = false;

  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    if (arg === '--help' || arg === '-h') return { help: true };
    if (arg === '--json') {
      json = true;
      continue;
    }
    if (arg === '--manifest') {
      manifestPath = argv[index + 1];
      index += 1;
      if (!manifestPath) throw new Error('--manifest requires a path.');
      continue;
    }
    throw new Error(`Unknown argument: ${arg}`);
  }

  return { manifestPath, json };
}

function issue(code, message, blockerId = null) {
  return { code, message, blockerId };
}

function isPlainObject(value) {
  return Boolean(value) && typeof value === 'object' && !Array.isArray(value);
}

function hasOnlyKeys(value, allowed, location, issues) {
  if (!isPlainObject(value)) {
    issues.push(issue('INVALID_SHAPE', `${location} must be an object.`));
    return false;
  }
  for (const key of Object.keys(value)) {
    if (!allowed.has(key)) issues.push(issue('UNKNOWN_FIELD', `${location}.${key} is not allowed.`));
  }
  return true;
}

function nonEmptyString(value) {
  return typeof value === 'string' && value.trim().length > 0;
}

function assertSafeContent(value, location, issues) {
  if (Array.isArray(value)) {
    value.forEach((entry, index) => assertSafeContent(entry, `${location}[${index}]`, issues));
    return;
  }
  if (isPlainObject(value)) {
    for (const [key, entry] of Object.entries(value)) {
      if (UNSAFE_KEY.test(key)) {
        issues.push(issue('UNSAFE_FIELD', `${location}.${key} may carry PII or a secret.`));
      }
      assertSafeContent(entry, `${location}.${key}`, issues);
    }
    return;
  }
  if (typeof value !== 'string') return;
  for (const unsafe of UNSAFE_VALUE_PATTERNS) {
    if (unsafe.pattern.test(value)) {
      issues.push(issue('UNSAFE_CONTENT', `${location} contains a possible ${unsafe.name}.`));
    }
  }
}

function resolveInsideRoot(root, relativePath, label) {
  if (!nonEmptyString(relativePath) || path.isAbsolute(relativePath)) {
    throw new Error(`${label} must be a non-empty relative path.`);
  }
  const resolved = path.resolve(root, relativePath);
  const prefix = `${root}${path.sep}`;
  if (resolved !== root && !resolved.startsWith(prefix)) {
    throw new Error(`${label} must stay inside the repository root.`);
  }
  return resolved;
}

function sha256File(filePath) {
  return createHash('sha256').update(readFileSync(filePath)).digest('hex');
}

function parseJsonFile(filePath, label) {
  try {
    return JSON.parse(readFileSync(filePath, 'utf8'));
  } catch (error) {
    throw new Error(`${label} is not valid JSON: ${error.message}`);
  }
}

function expectedStageFor(status) {
  if (status === 'IMPLEMENTED') return 'IMPLEMENTATION';
  if (status === 'VERIFIED_STAGING') return 'STAGING';
  if (status === 'VERIFIED_PRODUCTION') return 'PRODUCTION';
  return null;
}

function validateVerification(verification, location, issues) {
  const allowed = new Set(['stage', 'method', 'successCriteria', 'evidenceRequirements']);
  if (!hasOnlyKeys(verification, allowed, location, issues)) return;
  if (!STAGES.has(verification.stage)) issues.push(issue('INVALID_STAGE', `${location}.stage must be IMPLEMENTATION, STAGING, or PRODUCTION.`));
  if (!nonEmptyString(verification.method)) issues.push(issue('INVALID_VERIFICATION', `${location}.method must be non-empty.`));
  for (const field of ['successCriteria', 'evidenceRequirements']) {
    if (!Array.isArray(verification[field]) || verification[field].length === 0 || !verification[field].every(nonEmptyString)) {
      issues.push(issue('INVALID_VERIFICATION', `${location}.${field} must be a non-empty string array.`));
    }
  }
}

function validateEvidenceArtifact({ evidenceRef, blocker, manifest, root, issues }) {
  const location = `blocker ${blocker.id}.evidence`;
  const allowed = new Set(['path', 'sha256']);
  if (!hasOnlyKeys(evidenceRef, allowed, location, issues)) return false;
  if (!nonEmptyString(evidenceRef.path) || !evidenceRef.path.startsWith(`${manifest.policy.evidenceRoot}/`)) {
    issues.push(issue('INVALID_EVIDENCE_PATH', `${location}.path must be under ${manifest.policy.evidenceRoot}/.`, blocker.id));
    return false;
  }
  if (!evidenceRef.path.endsWith('.json') || !SHA256.test(evidenceRef.sha256 || '')) {
    issues.push(issue('INVALID_EVIDENCE_REF', `${location} must specify a .json path and lowercase SHA-256.`, blocker.id));
    return false;
  }

  let evidencePath;
  try {
    evidencePath = resolveInsideRoot(root, evidenceRef.path, `${location}.path`);
  } catch (error) {
    issues.push(issue('INVALID_EVIDENCE_PATH', error.message, blocker.id));
    return false;
  }
  if (!existsSync(evidencePath)) {
    issues.push(issue('MISSING_EVIDENCE', `${location} file is missing: ${evidenceRef.path}.`, blocker.id));
    return false;
  }
  const info = statSync(evidencePath);
  if (!info.isFile()) {
    issues.push(issue('INVALID_EVIDENCE_FILE', `${location} is not a regular file.`, blocker.id));
    return false;
  }
  const actualHash = sha256File(evidencePath);
  if (actualHash !== evidenceRef.sha256) {
    issues.push(issue('EVIDENCE_HASH_MISMATCH', `${location} SHA-256 does not match ${evidenceRef.path}.`, blocker.id));
    return false;
  }

  let artifact;
  try {
    artifact = parseJsonFile(evidencePath, `${location} artifact`);
  } catch (error) {
    issues.push(issue('INVALID_EVIDENCE_JSON', error.message, blocker.id));
    return false;
  }
  const artifactAllowed = new Set(['kind', 'blockerId', 'stage', 'targetRef', 'capturedAt', 'result', 'checks', 'summary']);
  if (!hasOnlyKeys(artifact, artifactAllowed, `${location} artifact`, issues)) return false;
  assertSafeContent(artifact, `${location} artifact`, issues);
  if (artifact.kind !== manifest.policy.evidenceKind || artifact.kind !== EVIDENCE_KIND) {
    issues.push(issue('INVALID_EVIDENCE_KIND', `${location} artifact kind is invalid.`, blocker.id));
  }
  if (artifact.blockerId !== blocker.id) issues.push(issue('EVIDENCE_BLOCKER_MISMATCH', `${location} artifact belongs to another blocker.`, blocker.id));
  if (!STAGES.has(artifact.stage)) issues.push(issue('INVALID_EVIDENCE_STAGE', `${location} artifact stage is invalid.`, blocker.id));
  if (artifact.targetRef !== manifest.target.projectRef) issues.push(issue('EVIDENCE_TARGET_MISMATCH', `${location} artifact target reference does not match the manifest.`, blocker.id));
  if (!ISO_TIME.test(artifact.capturedAt || '') || Number.isNaN(Date.parse(artifact.capturedAt))) {
    issues.push(issue('INVALID_EVIDENCE_TIME', `${location} artifact capturedAt must be UTC ISO-8601.`, blocker.id));
  }
  if (artifact.result !== 'PASS') issues.push(issue('EVIDENCE_NOT_PASS', `${location} artifact result must be PASS.`, blocker.id));
  if (!isPlainObject(artifact.checks) || Object.keys(artifact.checks).length === 0 || !Object.values(artifact.checks).every((value) => value === true)) {
    issues.push(issue('INVALID_EVIDENCE_CHECKS', `${location} artifact checks must be a non-empty all-true object.`, blocker.id));
  }
  if (!nonEmptyString(artifact.summary)) issues.push(issue('INVALID_EVIDENCE_SUMMARY', `${location} artifact summary must be non-empty.`, blocker.id));
  return true;
}

export function validateManifest(manifest, { root = repoRoot, verifyEvidence = true } = {}) {
  const issues = [];
  const rootRealPath = realpathSync(root);
  const topAllowed = new Set(['schemaVersion', 'target', 'policy', 'blockers']);
  if (!hasOnlyKeys(manifest, topAllowed, 'manifest', issues)) return { issues, blockers: [] };
  assertSafeContent(manifest, 'manifest', issues);

  if (manifest.schemaVersion !== MANIFEST_VERSION) issues.push(issue('INVALID_VERSION', `manifest.schemaVersion must be ${MANIFEST_VERSION}.`));
  if (!hasOnlyKeys(manifest.target, new Set(['projectRef', 'market', 'environment']), 'manifest.target', issues)) return { issues, blockers: [] };
  if (!PROJECT_REF.test(manifest.target.projectRef || '')) issues.push(issue('INVALID_TARGET', 'manifest.target.projectRef must be a Supabase project reference.'));
  if (!nonEmptyString(manifest.target.market) || !nonEmptyString(manifest.target.environment)) issues.push(issue('INVALID_TARGET', 'manifest.target.market and environment must be non-empty.'));

  const policyAllowed = new Set(['p0ClosureStatus', 'evidenceRoot', 'evidenceKind']);
  if (!hasOnlyKeys(manifest.policy, policyAllowed, 'manifest.policy', issues)) return { issues, blockers: [] };
  if (manifest.policy.p0ClosureStatus !== 'VERIFIED_PRODUCTION') issues.push(issue('INVALID_POLICY', 'P0 closure status must be VERIFIED_PRODUCTION.'));
  if (!nonEmptyString(manifest.policy.evidenceRoot) || manifest.policy.evidenceRoot !== 'docs/launch/.evidence') {
    issues.push(issue('INVALID_POLICY', 'Evidence root must be docs/launch/.evidence.'));
  }
  if (manifest.policy.evidenceKind !== EVIDENCE_KIND) issues.push(issue('INVALID_POLICY', `Evidence kind must be ${EVIDENCE_KIND}.`));
  if (!Array.isArray(manifest.blockers) || manifest.blockers.length === 0) {
    issues.push(issue('INVALID_BLOCKERS', 'manifest.blockers must be a non-empty array.'));
    return { issues, blockers: [] };
  }

  const seen = new Set();
  const blockers = [];
  for (const blocker of manifest.blockers) {
    const blockerIssues = [];
    const allowed = new Set(['id', 'severity', 'title', 'status', 'owner', 'verification', 'evidence']);
    if (!hasOnlyKeys(blocker, allowed, 'blocker', blockerIssues)) {
      issues.push(...blockerIssues);
      continue;
    }
    if (!BLOCKER_ID.test(blocker.id || '')) blockerIssues.push(issue('INVALID_ID', 'Blocker id must use a stable P0/P1/P2 identifier.', blocker.id || null));
    if (seen.has(blocker.id)) blockerIssues.push(issue('DUPLICATE_ID', `Duplicate blocker id: ${blocker.id}.`, blocker.id));
    seen.add(blocker.id);
    if (!SEVERITIES.has(blocker.severity)) blockerIssues.push(issue('INVALID_SEVERITY', `Invalid severity for ${blocker.id}.`, blocker.id));
    if (!nonEmptyString(blocker.title) || !nonEmptyString(blocker.owner)) blockerIssues.push(issue('INVALID_BLOCKER', `${blocker.id} needs a title and owner.`, blocker.id));
    if (!STATUSES.has(blocker.status)) blockerIssues.push(issue('INVALID_STATUS', `${blocker.id} has an invalid status.`, blocker.id));
    validateVerification(blocker.verification, `blocker ${blocker.id}.verification`, blockerIssues);
    if (!Array.isArray(blocker.evidence)) blockerIssues.push(issue('INVALID_EVIDENCE', `${blocker.id}.evidence must be an array.`, blocker.id));

    const expectedStage = expectedStageFor(blocker.status);
    if (expectedStage && blocker.verification?.stage !== expectedStage) {
      blockerIssues.push(issue('STATUS_STAGE_MISMATCH', `${blocker.id} status ${blocker.status} requires ${expectedStage} verification.`, blocker.id));
    }
    if (blocker.status !== 'BLOCKED' && (!Array.isArray(blocker.evidence) || blocker.evidence.length === 0)) {
      blockerIssues.push(issue('MISSING_EVIDENCE', `${blocker.id} is not BLOCKED but has no evidence.`, blocker.id));
    }

    let evidenceValid = true;
    if (verifyEvidence && Array.isArray(blocker.evidence)) {
      for (const evidenceRef of blocker.evidence) {
        const before = blockerIssues.length;
        validateEvidenceArtifact({ evidenceRef, blocker, manifest, root: rootRealPath, issues: blockerIssues });
        if (blockerIssues.length > before) evidenceValid = false;
      }
    }
    const provenClosed = blocker.severity === 'P0'
      ? blocker.status === manifest.policy.p0ClosureStatus && evidenceValid && blockerIssues.length === 0
      : blocker.status === 'VERIFIED_PRODUCTION' && evidenceValid && blockerIssues.length === 0;
    blockers.push({ id: blocker.id, severity: blocker.severity, status: blocker.status, provenClosed, issues: blockerIssues });
    issues.push(...blockerIssues);
  }
  return { issues, blockers };
}

export function evaluateGate(manifest, options = {}) {
  const result = validateManifest(manifest, options);
  const p0 = result.blockers.filter((blocker) => blocker.severity === 'P0');
  const unprovenP0 = p0.filter((blocker) => !blocker.provenClosed);
  return {
    ok: result.issues.length === 0 && unprovenP0.length === 0,
    launchBlocked: result.issues.length > 0 || unprovenP0.length > 0,
    summary: {
      p0Total: p0.length,
      p0ProvenClosed: p0.length - unprovenP0.length,
      p0Blocked: unprovenP0.length,
      validationIssues: result.issues.length
    },
    blockers: result.blockers,
    issues: result.issues
  };
}

function renderHuman(result) {
  console.log(`Launch gate: ${result.ok ? 'PASS' : 'BLOCKED'}`);
  console.log(`P0 proven closed: ${result.summary.p0ProvenClosed}/${result.summary.p0Total}`);
  for (const blocker of result.blockers.filter((entry) => entry.severity === 'P0' && !entry.provenClosed)) {
    const reasons = blocker.issues.map((entry) => entry.code).join(', ') || `status ${blocker.status} is not VERIFIED_PRODUCTION`;
    console.log(`- ${blocker.id}: ${reasons}`);
  }
  if (result.issues.length > 0) console.log(`Manifest/evidence validation issues: ${result.issues.length}`);
}

export function runCli(argv = process.argv.slice(2), { root = repoRoot } = {}) {
  let args;
  try {
    args = parseArgs(argv);
    if (args.help) return usage(0);
    const manifestPath = resolveInsideRoot(root, args.manifestPath, 'Manifest path');
    const manifest = parseJsonFile(manifestPath, 'Manifest');
    const result = evaluateGate(manifest, { root, verifyEvidence: true });
    if (args.json) console.log(JSON.stringify(result, null, 2));
    else renderHuman(result);
    return result.ok ? 0 : 1;
  } catch (error) {
    console.error(`Launch gate validation error: ${error.message}`);
    return 2;
  }
}

if (process.argv[1] === __filename) process.exitCode = runCli();
